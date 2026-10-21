#!/usr/bin/env bash
# ============================================================================
#  DeepSeek Harness (dsh) – Installation INNERHALB des LXC-Containers
#  Wird vom Outer-Script (install/dsh.sh) auf dem Proxmox-Host geladen und via
#  'pct exec' ausgeführt. Kann zu Debugging-Zwecken auch manuell im CT laufen:
#
#    DSH_API_KEY_FILE=/tmp/.dsh-apikey bash -x /tmp/dsh-inner.sh [PUBLIC_PORT] [DSH_PORT]
#
#  Aufruf: bash dsh-inner.sh [PUBLIC_PORT=8080] [DSH_PORT=3080]
# ============================================================================

set -Eeuo pipefail

PUBLIC_PORT="${1:-8080}"   # extern, gebunden an 0.0.0.0 durch nginx
DSH_PORT="${2:-3080}"      # intern, nur auf 127.0.0.1 (dsh unterstützt kein 0.0.0.0)
DSH_VERSION="${DSH_VERSION:-0.2.1-rc.2}"   # getestete Version; latest = immer updaten

APP="dsh"
APP_NAME="DeepSeek Harness"
DSH_USER="dsh"
DSH_HOME="/var/lib/dsh"
DSH_WORKDIR="/opt/dsh"
NODE_MAJOR_REQUIRED=20

API_KEY_FILE="${DSH_API_KEY_FILE:-}"
API_KEY=""
if [[ -n "$API_KEY_FILE" && -f "$API_KEY_FILE" ]]; then
  API_KEY="$(cat "$API_KEY_FILE")"
  API_KEY="${API_KEY//[[:space:]]/}"
  rm -f "$API_KEY_FILE"
fi

JAR=""
IDX_HTML=""
cleanup() {
  [[ -n "$API_KEY_FILE" ]] && rm -f "$API_KEY_FILE"
  [[ -n "$JAR" ]] && rm -f "$JAR"
  [[ -n "$IDX_HTML" ]] && rm -f "$IDX_HTML"
  return 0
}
trap cleanup EXIT

# ───────────────────────────── Ausgabe-Helfer ───────────────────────────────
YW='\033[33m'; GN='\033[1;92m'; RD='\033[01;31m'; BL='\033[36m'; CL='\033[m'
CM="${GN}✔${CL}"; CROSS="${RD}✘${CL}"; INFO="${BL}ℹ${CL}"
msg_info()  { echo -e " ${INFO} ${1}"; }
msg_ok()    { echo -e " ${CM} ${1}"; }
msg_warn()  { echo -e " ${YW}⚠${CL} ${1}"; }
msg_fatal() { echo -e " ${CROSS} ${1}" >&2; exit 1; }

# ───────────────────── Vollständige Fehlermeldungskette ─────────────────────
on_error() {
  local ec="$1" ln="$2" cmd="$3"
  echo "" >&2
  echo -e "${RD}━━━━━━━━ FEHLERKETTE (im Container) ━━━━━━━━${CL}" >&2
  echo -e " Exit-Code : ${ec}" >&2
  echo -e " Zeile     : ${ln}" >&2
  echo -e " Befehl    : ${cmd}" >&2
  if systemctl list-unit-files 2>/dev/null | grep -q "^${APP}.service"; then
    echo -e "${RD}── systemctl status ${APP} ──${CL}" >&2
    systemctl status "${APP}" --no-pager -l 2>&1 | tail -n 25 >&2 || true
    echo -e "${RD}── journalctl -u ${APP} (letzte 40 Zeilen) ──${CL}" >&2
    journalctl -u "${APP}" -n 40 --no-pager 2>&1 >&2 || true
  fi
  if [[ -f /var/log/nginx/error.log ]]; then
    echo -e "${RD}── /var/log/nginx/error.log (letzte 15 Zeilen) ──${CL}" >&2
    tail -n 15 /var/log/nginx/error.log >&2 || true
  fi
  echo -e "${YW} Debug: DSH_API_KEY_FILE=... bash -x /tmp/dsh-inner.sh ${PUBLIC_PORT} ${DSH_PORT}${CL}" >&2
  echo -e "${RD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}" >&2
  exit "$ec"
}
trap 'on_error $? $LINENO "$BASH_COMMAND"' ERR

export DEBIAN_FRONTEND=noninteractive

echo -e "${GN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}"
echo -e "${GN} ${APP_NAME} – Installation im Container${CL}"
echo -e "${GN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}"

# ───────────────────────── 1. Systempakete ──────────────────────────────────
msg_info "System wird aktualisiert und Pakete werden installiert"
apt-get update -qq
apt-get install -y -qq \
  curl wget git ca-certificates gnupg openssl \
  nginx bubblewrap >/dev/null
msg_ok "nginx, bubblewrap & Basis-Pakete installiert"

# Firewall (falls aktiv – Standard-LXC hat keine): Port freigeben
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow "${PUBLIC_PORT}/tcp" >/dev/null
  msg_ok "UFW: Port ${PUBLIC_PORT}/tcp erlaubt"
fi

# ───────────────────────── 2. Node.js (>= 20, Ziel 22 LTS) ──────────────────
NODE_MAJOR="$(node -v 2>/dev/null | sed 's/^v\([0-9]*\).*/\1/' || echo 0)"
if [[ "${NODE_MAJOR:-0}" -lt "$NODE_MAJOR_REQUIRED" ]]; then
  msg_info "Node.js ${NODE_MAJOR_REQUIRED}+ nicht gefunden (vorhanden: v${NODE_MAJOR:-0}) → NodeSource-Setup"
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash - >/dev/null
  apt-get install -y -qq nodejs >/dev/null
fi
msg_ok "Node.js $(node -v), npm v$(npm -v)"

# ───────────────────── 3. Benutzer & Verzeichnisse ──────────────────────────
msg_info "Benutzer und Verzeichnisse werden angelegt"
if ! id -u "$DSH_USER" >/dev/null 2>&1; then
  useradd --system --home-dir "$DSH_HOME" --create-home --shell /usr/sbin/nologin "$DSH_USER"
fi
mkdir -p "$DSH_WORKDIR" "$DSH_HOME"
chown -R "${DSH_USER}:${DSH_USER}" "$DSH_WORKDIR" "$DSH_HOME"
chmod 750 "$DSH_HOME"
msg_ok "Benutzer '${DSH_USER}' · Home ${DSH_HOME} · Arbeitsverzeichnis ${DSH_WORKDIR}"

# ───────────────────────── 4. dsh installieren/aktualisieren ────────────────
INSTALLED_DSH_VERSION="$(dsh --version 2>/dev/null || true)"
if [[ "$DSH_VERSION" == "latest" || "$INSTALLED_DSH_VERSION" != "$DSH_VERSION" ]]; then
  msg_info "@deepseek-ai/dsh@${DSH_VERSION} wird installiert (kann einige Minuten dauern)"
  npm install -g "@deepseek-ai/dsh@${DSH_VERSION}" --no-audit --no-fund --loglevel=error
else
  msg_ok "dsh ${INSTALLED_DSH_VERSION} bereits installiert – npm-Installation übersprungen"
fi
command -v dsh >/dev/null || msg_fatal "'dsh' nach npm-Installation nicht im PATH."
msg_ok "dsh $(dsh --version 2>/dev/null || echo '?') installiert ($(command -v dsh))"

# ───────────────── 4b. API-Key vorab hinterlegen (optional) ─────────────────
# Format exakt nach dsh-credentials-local: version: 1 + refs-Mapping.
# Damit funktioniert Settings → Models ohne manuelle Eingabe in der Web UI.
if [[ -n "${API_KEY}" ]]; then
  if [[ ! "${API_KEY}" =~ ^[A-Za-z0-9_.-]{20,}$ ]]; then
    msg_fatal "API-Key hat unerwartetes Format (erwartet: mind. 20 Zeichen aus [A-Za-z0-9_.-]). Abbruch, nichts verstümmelt."
  fi
  CRED_FILE="${DSH_HOME}/.credentials.yaml"
  if [[ ! -f "${CRED_FILE}" ]]; then
    printf 'version: 1\nrefs:\n  DEEPSEEK_API_KEY: %s\n' "${API_KEY}" > "${CRED_FILE}"
  elif ! DSH_NEW_KEY="${API_KEY}" node -e '
    const fs = require("fs");
    const file = process.argv[1];
    const key = process.env.DSH_NEW_KEY;
    let text = fs.readFileSync(file, "utf8");
    if (/^  DEEPSEEK_API_KEY:/m.test(text)) {
      text = text.replace(/^  DEEPSEEK_API_KEY:.*$/m, "  DEEPSEEK_API_KEY: " + key);
    } else if (/^refs:[ \t]*\{[ \t]*\}[ \t]*$/m.test(text)) {
      text = text.replace(/^refs:[ \t]*\{[ \t]*\}[ \t]*$/m, "refs:\n  DEEPSEEK_API_KEY: " + key);
    } else if (/^refs:[ \t]*$/m.test(text)) {
      text = text.replace(/^refs:[ \t]*$/m, "refs:\n  DEEPSEEK_API_KEY: " + key);
    } else {
      process.exit(2);
    }
    fs.writeFileSync(file, text, { mode: 0o600 });
  ' "${CRED_FILE}"; then
    msg_fatal "${CRED_FILE} existiert in unbekanntem Format – bitte manuell prüfen."
  fi
  chown "${DSH_USER}:${DSH_USER}" "${CRED_FILE}"
  chmod 600 "${CRED_FILE}"
  msg_ok "DeepSeek-API-Key hinterlegt (${CRED_FILE}, Modus 600)"
fi

# ───────────────────── 5. Start-Wrapper (trusted hosts) ─────────────────────
# dsh bindet bewusst nur auf 127.0.0.1. Der Wrapper trägt die aktuelle
# Container-IP als öffentliche URL und als vertrauenswürdige Autorität ein.
# Wichtig: nginx reicht Host und Origin unverändert durch – dsh prüft beides
# selbst und bindet das Login-Cookie an genau diese Autorität.
msg_info "Start-Wrapper wird erstellt (/usr/local/bin/dsh-start.sh)"
cat > /usr/local/bin/dsh-start.sh << 'WRAPPER'
#!/usr/bin/env bash
set -euo pipefail

DSH_BIN="$(command -v dsh)"
HOSTN="$(hostname -f 2>/dev/null || true)"
[[ -n "$HOSTN" ]] || HOSTN="$(hostname)"
PUBLIC_PORT="${PUBLIC_PORT:-8080}"
DSH_PORT="${DSH_PORT:-3080}"

# Auf die erste IPv4-Adresse warten (DHCP kann beim Boot kurz brauchen).
IP=""
for _ in $(seq 1 30); do
  IP="$(hostname -I 2>/dev/null | tr ' ' '\n' \
        | grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' \
        | grep -v '^127\.' | head -n1 || true)"
  [[ -n "$IP" ]] && break
  sleep 1
done

ARGS=(web --no-open
      --host 127.0.0.1
      --port "${DSH_PORT}")

# Port-lose Einträge matchen jeden Port – die von dsh vorgesehene Form für
# LAN-Zugriff über einen Reverse Proxy.
if [[ -n "$IP" ]]; then
  ARGS+=(--public-url "http://${IP}:${PUBLIC_PORT}")
  ARGS+=(--trusted-host "${IP}")
fi
ARGS+=(--trusted-host "localhost")
ARGS+=(--trusted-host "127.0.0.1")
ARGS+=(--trusted-host "${HOSTN}")

exec "${DSH_BIN}" "${ARGS[@]}"
WRAPPER
chmod 755 /usr/local/bin/dsh-start.sh
msg_ok "Wrapper erstellt"

# ───────────────────── 5b. Token-Link-Helfer (dsh-url) ──────────────────────
# dsh erzeugt bei jedem Start einen neuen Login-Token. Der Helfer liest den
# aktuellen Token-Link aus dem Journal – so kommt man auch nach einem Reboot
# oder in einem neuen Browser wieder in die Web UI.
msg_info "Token-Helfer wird erstellt (/usr/local/bin/dsh-url)"
cat > /usr/local/bin/dsh-url << 'DSHURL'
#!/usr/bin/env bash
set -euo pipefail

SINCE="${1:-}"
ARGS=(-u dsh -b --no-pager -o cat)
[[ -n "$SINCE" ]] && ARGS+=(--since "$SINCE")

URL="$(journalctl "${ARGS[@]}" 2>/dev/null \
  | grep -oE 'https?://[^[:space:]]+\?token=[A-Za-z0-9_-]+' \
  | tail -n1 || true)"

if [[ -z "$URL" ]]; then
  echo "Kein Token-Link gefunden. Läuft der Service? journalctl -u dsh -b -e" >&2
  exit 1
fi
printf '%s\n' "$URL"
DSHURL
chmod 700 /usr/local/bin/dsh-url
msg_ok "Token-Helfer erstellt (Aufruf: dsh-url)"

# ───────────────────────── 6. Reverse Proxy (nginx) ─────────────────────────
# Notwendig, weil 'dsh web' absichtlich kein --host 0.0.0.0 unterstützt.
# nginx ist ein reiner Proxy: Host, Origin, Cookies und WebSockets werden
# unverändert durchgereicht. Der Auth-Schutz (Launch-Token + Cookie) und der
# Host/Origin-Fence bleiben vollständig bei dsh.
rm -f /usr/local/bin/dsh-render-origin-map.sh /etc/nginx/conf.d/dsh-origin.conf

msg_info "nginx Upgrade-Map wird erstellt"
cat > /etc/nginx/conf.d/dsh-upgrade.conf << 'UPGRADE'
map $http_upgrade $dsh_connection_upgrade {
    default upgrade;
    ''      close;
}
UPGRADE

msg_info "nginx als Reverse Proxy (0.0.0.0:${PUBLIC_PORT} → 127.0.0.1:${DSH_PORT})"
cat > /etc/nginx/sites-available/dsh.conf << 'NGINX'
server {
    listen 0.0.0.0:__PUBLIC_PORT__;
    listen [::]:__PUBLIC_PORT__;
    server_name _;
    client_max_body_size 320m;

    location / {
        # dsh ruft crypto.randomUUID() im Browser auf – diese API existiert nur
        # in Secure Contexts (HTTPS/localhost). Beim Zugriff ueber
        # http://<CT-IP> fehlt sie, deshalb wird ein Polyfill vor allen
        # App-Scripts in den <head> jeder HTML-Antwort injiziert.
        proxy_set_header Accept-Encoding "";
        sub_filter '<head>' '<head><script>(function(){if(typeof crypto==="object"&&crypto&&typeof crypto.randomUUID!=="function"){var f=function(){var b=new Uint8Array(16),i,j,h=[];if(typeof crypto.getRandomValues==="function"){crypto.getRandomValues(b);}else{for(i=0;i<16;i++){b[i]=Math.floor(Math.random()*256);}}b[6]=(b[6]&15)|64;b[8]=(b[8]&63)|128;for(j=0;j<16;j++){h.push((b[j]+256).toString(16).slice(1));}return h.slice(0,4).join("")+"-"+h.slice(4,6).join("")+"-"+h.slice(6,8).join("")+"-"+h.slice(8,10).join("")+"-"+h.slice(10,16).join("");};try{Object.defineProperty(crypto,"randomUUID",{value:f,configurable:true});}catch(e){crypto.randomUUID=f;}}})();</script>';
        sub_filter_once on;

        proxy_pass http://127.0.0.1:__DSH_PORT__;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $dsh_connection_upgrade;
        proxy_set_header Host $http_host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
        proxy_buffering off;
    }
}
NGINX
sed -i "s/__PUBLIC_PORT__/${PUBLIC_PORT}/g; s/__DSH_PORT__/${DSH_PORT}/g" /etc/nginx/sites-available/dsh.conf
ln -sfn /etc/nginx/sites-available/dsh.conf /etc/nginx/sites-enabled/dsh.conf
rm -f /etc/nginx/sites-enabled/default
nginx -t
msg_ok "nginx-Konfiguration gültig"

# ───────────────────────── 7. systemd-Unit ──────────────────────────────────
msg_info "systemd-Unit wird geschrieben (/etc/systemd/system/${APP}.service)"
cat > "/etc/systemd/system/${APP}.service" << UNIT
[Unit]
Description=${APP_NAME} Web UI (dsh)
Documentation=https://github.com/deepseek-ai/deepseek-harness
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=${DSH_USER}
Group=${DSH_USER}
WorkingDirectory=${DSH_WORKDIR}
Environment=HOME=${DSH_HOME}
Environment=DSH_HOME=${DSH_HOME}
Environment=DSH_PORT=${DSH_PORT}
Environment=PUBLIC_PORT=${PUBLIC_PORT}
ExecStart=/usr/local/bin/dsh-start.sh
Restart=always
RestartSec=5
TimeoutStartSec=180
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable nginx "$APP" >/dev/null 2>&1
systemctl restart nginx
# Zeitstempel vor dem Start: verhindert, dass die Verifikation den Token
# eines vorherigen dsh-Prozesses aus dem selben Boot erwischt.
START_TS="$(date '+%Y-%m-%d %H:%M:%S')"
systemctl restart "$APP"
msg_ok "Services aktiviert (enable + restart)"

# ───────────────────────── 8. Verifikation ──────────────────────────────────
sleep 3
if ! systemctl is-active --quiet "$APP"; then
  msg_fatal "Service '${APP}' läuft nicht – Logausgabe siehe oben (Fehlerkette)."
fi
msg_ok "Service '${APP}' ist aktiv"

CT_IP="$(hostname -I 2>/dev/null | tr ' ' '\n' \
  | grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' \
  | grep -v '^127\.' | head -n1 || true)"
[[ -n "$CT_IP" ]] || msg_fatal "Keine IPv4-Adresse im Container gefunden."

msg_info "Warte auf Token-Link und Web UI (erste Inbetriebnahme kann ~1 Minute dauern)"
WEB_URL=""
for _ in $(seq 1 90); do
  WEB_URL="$(/usr/local/bin/dsh-url "$START_TS" 2>/dev/null || true)"
  [[ -n "$WEB_URL" ]] && break
  sleep 2
done
if [[ -z "$WEB_URL" ]]; then
  journalctl -u "$APP" -n 50 --no-pager || true
  msg_fatal "Kein Token-Link im Journal – Web UI/Service-Logs prüfen."
fi
msg_ok "Token-Link erzeugt"

JAR="$(mktemp)"
IDX_HTML="$(mktemp)"
ROOT_URL="${WEB_URL%%\?*}"

EXCHANGE_CODE="$(curl -sS -c "$JAR" -o /dev/null -w '%{http_code}' "$WEB_URL" || true)"
if [[ "$EXCHANGE_CODE" != "200" && "$EXCHANGE_CODE" != "302" && "$EXCHANGE_CODE" != "303" ]]; then
  msg_fatal "Token-Exchange fehlgeschlagen (HTTP ${EXCHANGE_CODE}) – dsh-Auth/Proxy prüfen."
fi

INDEX_CODE="$(curl -sS -b "$JAR" -o "$IDX_HTML" -w '%{http_code}' "$ROOT_URL" || true)"
[[ "$INDEX_CODE" == "200" ]] || msg_fatal "Web UI antwortet mit Cookie nicht (HTTP ${INDEX_CODE})."
msg_ok "Web UI erreichbar und Login-Cookie gültig (HTTP 200)"

if grep -q "randomUUID" "$IDX_HTML"; then
  msg_ok "randomUUID-Polyfill wird ausgeliefert (Fix für http-Zugriff ohne HTTPS)"
else
  msg_fatal "Polyfill fehlt in der HTML-Antwort – nginx sub_filter prüfen."
fi

# Host/Origin-Fence von dsh: trusted Host + fremder Origin muss 403 liefern.
EVIL_CODE="$(curl -sS -o /dev/null -w '%{http_code}' \
  -H "Host: ${CT_IP}:${PUBLIC_PORT}" \
  -H "Origin: http://boeser-server.example" \
  -H "Content-Type: application/json" -d '{}' \
  "http://127.0.0.1:${PUBLIC_PORT}/api/credentials/describe" || true)"
if [[ "$EVIL_CODE" != "403" ]]; then
  msg_fatal "Fremder Origin wurde NICHT blockiert (HTTP ${EVIL_CODE}) – Host/Origin-Fence prüfen!"
fi
msg_ok "Fremder Origin korrekt blockiert (HTTP 403)"

# Ohne Login-Cookie muss die API 401 liefern (Token-Auth aktiv).
NOAUTH_CODE="$(curl -sS -o /dev/null -w '%{http_code}' \
  -H "Host: ${CT_IP}:${PUBLIC_PORT}" \
  -H "Origin: http://${CT_IP}:${PUBLIC_PORT}" \
  -H "Content-Type: application/json" -d '{}' \
  "http://127.0.0.1:${PUBLIC_PORT}/api/credentials/describe" || true)"
if [[ "$NOAUTH_CODE" != "401" ]]; then
  msg_fatal "Unauthentifizierte API liefert HTTP ${NOAUTH_CODE} (erwartet 401) – Token-Auth prüfen."
fi
msg_ok "Unauthentifizierter API-Zugriff korrekt blockiert (HTTP 401)"

# API-Key-Nachweis über den echten RPC-Weg (gleicher Call wie im Web UI).
if [[ -n "${API_KEY}" ]]; then
  CRED_STATE="$(curl -sS -b "$JAR" \
    -H "Content-Type: application/json" \
    -d '{"type":"client-request","rpcId":"installer","method":"credentials/describe","payload":{"args":{"refs":["DEEPSEEK_API_KEY"]}}}' \
    "${ROOT_URL}api/credentials/describe" || true)"
  if grep -Eq '"configured"[[:space:]]*:[[:space:]]*true' <<< "$CRED_STATE"; then
    msg_ok "DEEPSEEK_API_KEY ist aktiv (credentials/describe → configured:true, source:file)"
  else
    journalctl -u "$APP" -n 20 --no-pager || true
    msg_fatal "API-Key nicht erkannt – .credentials.yaml/Service-Logs prüfen."
  fi

  # Optionaler, nicht-fatale Online-Check: fängt Tippfehler sofort ab.
  KEY_HTTP="$(curl -sS --max-time 15 -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer ${API_KEY}" \
    https://api.deepseek.com/models || true)"
  if [[ "$KEY_HTTP" == "200" ]]; then
    msg_ok "DeepSeek akzeptiert den API-Key (GET /models → 200)"
  elif [[ "$KEY_HTTP" == "401" || "$KEY_HTTP" == "403" ]]; then
    msg_warn "DeepSeek lehnt den API-Key ab (HTTP ${KEY_HTTP}) – bitte in Settings → Models prüfen."
  elif [[ -n "$KEY_HTTP" && "$KEY_HTTP" != "000" ]]; then
    msg_warn "Online-Prüfung des API-Keys lieferte HTTP ${KEY_HTTP} – Installation läuft trotzdem weiter."
  else
    msg_warn "Online-Prüfung des API-Keys nicht möglich (Netzwerk/Timeout) – Installation läuft weiter."
  fi
fi

if command -v ss >/dev/null 2>&1; then
  LISTEN_OK="$(ss -tln 2>/dev/null | awk '{print $4}' \
    | grep -E ":(${PUBLIC_PORT}|${DSH_PORT})$" | sort -u || true)"
  msg_ok "Lauschende Sockets: ${LISTEN_OK//$'\n'/ · }"
fi

# ──────────────────────────── Abschlussbox ──────────────────────────────────
echo ""
echo -e "${GN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}"
echo -e "${GN} ${APP_NAME} ist bereit!${CL}"
echo -e "${GN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}"
echo -e " ${YW}Web UI:${CL}      ${ROOT_URL}"
echo -e " ${YW}Jetzt öffnen:${CL} ${WEB_URL}"
echo -e "                  (Einmal-Login; danach gilt das Cookie 30 Tage)"
echo -e " ${YW}Neuer Login:${CL} im Container: ${BL}dsh-url${CL}"
if [[ -n "${API_KEY}" ]]; then
  echo -e " ${YW}API-Key:${CL}     hinterlegt und aktiv – Models-Auswahl sofort nutzbar"
else
  echo -e " ${YW}Falls nötig:${CL}   Settings → Models → DeepSeek-API-Key"
fi
echo -e " ${YW}Logs:${CL}        journalctl -u ${APP} -e · /var/log/nginx/"
echo -e "${GN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}"
