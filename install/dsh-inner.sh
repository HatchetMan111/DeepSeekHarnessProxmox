#!/usr/bin/env bash
# ============================================================================
#  DeepSeek Harness (dsh) – Installation INNERHALB des LXC-Containers
#  Wird vom Outer-Script (install/dsh.sh) auf dem Proxmox-Host geladen und via
#  'pct exec' ausgeführt. Kann zu Debugging-Zwecken auch manuell im CT laufen:
#
#    bash -x /tmp/dsh-inner.sh [PUBLIC_PORT] [DSH_PORT]
#
#  Aufruf: bash dsh-inner.sh [PUBLIC_PORT=8080] [DSH_PORT=3080]
# ============================================================================

set -Eeuo pipefail

PUBLIC_PORT="${1:-8080}"   # extern, gebunden an 0.0.0.0 durch nginx
DSH_PORT="${2:-3080}"      # intern, nur auf 127.0.0.1 (dsh unterstützt kein 0.0.0.0)

APP="dsh"
APP_NAME="DeepSeek Harness"
DSH_USER="dsh"
DSH_HOME="/var/lib/dsh"
DSH_WORKDIR="/opt/dsh"
NODE_MAJOR_REQUIRED=20

# ───────────────────────────── Ausgabe-Helfer ───────────────────────────────
YW='\033[33m'; GN='\033[1;92m'; RD='\033[01;31m'; BL='\033[36m'; CL='\033[m'
CM="${GN}✔${CL}"; CROSS="${RD}✘${CL}"; INFO="${BL}ℹ${CL}"
msg_info()  { echo -e " ${INFO} ${1}"; }
msg_ok()    { echo -e " ${CM} ${1}"; }
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
  echo -e "${YW} Debug: bash -x /tmp/${APP}-inner.sh ${PUBLIC_PORT} ${DSH_PORT}${CL}" >&2
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
msg_info "@deepseek-ai/dsh wird global installiert (idempotent = gleichzeitig Update)"
npm install -g @deepseek-ai/dsh --silent
command -v dsh >/dev/null || msg_fatal "'dsh' nach npm-Installation nicht im PATH."
msg_ok "dsh $(dsh --version 2>/dev/null || echo '?') installiert ($(command -v dsh))"

# ───────────────────── 5. Start-Wrapper (trusted hosts) ─────────────────────
# dsh bindet bewusst nur auf 127.0.0.1 und prüft /api-Aufrufe gegen eine
# Trust-Liste ('browser-trust fence'). Der Wrapper trägt die aktuelle
# Container-IP zur Laufzeit in die Trust-Liste ein.
msg_info "Start-Wrapper wird erstellt (/usr/local/bin/dsh-start.sh)"
cat > /usr/local/bin/dsh-start.sh << 'WRAPPER'
#!/usr/bin/env bash
set -euo pipefail

DSH_BIN="$(command -v dsh)"
HOSTN="$(hostname -f 2>/dev/null || hostname)"

ARGS=(web --no-open
      --host 127.0.0.1
      --port "${DSH_PORT:-3080}")

# Autoritäten für den browser-trust fence von dsh. WICHTIG: bewusst OHNE Port
# angeben – ein port-loser Eintrag matcht den Hostnamen auf jedem Port (die von
# dsh selbst für LAN-IP-Zugriff vorgesehene Form), und der Fence vergleicht die
# Origin des Browsers gegen den vollen Host:-Header inkl. Port.
# Nur IPv4-Literale aufnehmen (IPv6 mit ':' würde den WHATWG-Parse-Check von
# dsh beim Boot hart scheitern lassen).
for addr in $(hostname -I 2>/dev/null); do
  [[ "${addr}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && ARGS+=(--trusted-host "${addr}")
done
ARGS+=("--trusted-host" "localhost")
ARGS+=("--trusted-host" "127.0.0.1")
ARGS+=("--trusted-host" "${HOSTN}")

exec "${DSH_BIN}" "${ARGS[@]}"
WRAPPER
chmod 755 /usr/local/bin/dsh-start.sh
msg_ok "Wrapper erstellt"

# ───────────────────────── 6. Reverse Proxy (nginx) ─────────────────────────
# Notwendig, weil 'dsh web' absichtlich kein --host 0.0.0.0 unterstützt.

# 6a. Origin-Allowliste (Schutz gegen DNS-Rebinding/Cross-Site): dsh pinnt die
#     Konfigurations-Ebene (Settings/Credentials/Presets/Workspace-Wahl) hart
#     auf Loopback-Same-Origin. Der /api/-Proxy-Block unten stellt Requests
#     deshalb aus Sicht von dsh als lokal dar – der eigentliche Schutz passiert
#     HIER in nginx: nur Origins dieser Maschine werden akzeptiert.
#     Das Mapping wird bei jedem Service-Start neu gerendert (IP-Wechsel).
msg_info "Origin-Renderer wird erstellt (/usr/local/bin/dsh-render-origin-map.sh)"
cat > /usr/local/bin/dsh-render-origin-map.sh << 'RENDER'
#!/usr/bin/env bash
set -euo pipefail
OUT="/etc/nginx/conf.d/dsh-origin.conf"
HOSTN="$(hostname -f 2>/dev/null || hostname)"
HOSTN_RX="$(printf '%s' "${HOSTN}" | sed 's/[^a-zA-Z0-9.-]/./g')"
{
  echo "# Automatisch erzeugt – nicht manuell editieren (wird bei jedem Start neu geschrieben)."
  echo 'map $http_origin $dsh_origin_ok {'
  echo '    default 0;'
  echo '    ""      1;'
  echo '    "~^https?://(localhost|127\.0\.0\.1)(:[0-9]+)?$" 1;'
  for addr in $(hostname -I 2>/dev/null); do
    if [[ "${addr}" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
      printf '    "~^https?://%s.%s.%s.%s(:[0-9]+)?$" 1;\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}"
    fi
  done
  printf '    "~^https?://%s(:[0-9]+)?$" 1;\n' "${HOSTN_RX}"
  echo '}'
} > "${OUT}"
nginx -t -q
systemctl try-reload-or-restart nginx >/dev/null 2>&1 || true
RENDER
chmod 755 /usr/local/bin/dsh-render-origin-map.sh
PUBLIC_PORT="$PUBLIC_PORT" DSH_PORT="$DSH_PORT" /usr/local/bin/dsh-render-origin-map.sh
msg_ok "Origin-Allowliste gerendert (/etc/nginx/conf.d/dsh-origin.conf)"

# 6b. Server-Block
msg_info "nginx als Reverse Proxy (0.0.0.0:${PUBLIC_PORT} → 127.0.0.1:${DSH_PORT})"
cat > /etc/nginx/sites-available/dsh.conf << 'NGINX'
server {
    listen 0.0.0.0:__PUBLIC_PORT__;
    listen [::]:__PUBLIC_PORT__;
    server_name _;
    client_max_body_size 64m;

    # Privilegierte API-Ebene: dsh erlaubt Settings/Credentials/Presets nur
    # aus Loopback-Same-Origin ("configuration plane"). Der Proxy trägt die
    # Anfrage daher als Loopback an dsh heran; der echte Schutz ist der
    # Origin-Filter ($dsh_origin_ok) oben aus dsh-origin.conf.
    location /api/ {
        if ($dsh_origin_ok = 0) { return 403; }
        proxy_pass http://127.0.0.1:__DSH_PORT__;
        proxy_http_version 1.1;
        proxy_set_header Host 127.0.0.1:__DSH_PORT__;
        proxy_set_header Origin "";
        proxy_set_header Sec-Fetch-Site "";
        proxy_set_header Sec-Fetch-Mode "";
        proxy_set_header Sec-Fetch-Dest "";
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header X-Real-IP $remote_addr;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
        proxy_buffering off;
        client_max_body_size 320m;
    }

    location / {
        # dsh ruft crypto.randomUUID() im Browser auf – diese API existiert nur
        # in Secure Contexts (HTTPS/localhost). Beim Zugriff ueber
        # http://<CT-IP> fehlt sie, deshalb wird ein Polyfill vor allen
        # App-Scripts in den <head> jeder HTML-Antwort injiziert.
        proxy_set_header Accept-Encoding "";
        sub_filter '</head>' '<script>(function(){if(typeof crypto==="object"&&crypto&&typeof crypto.randomUUID!=="function"){var f=function(){var b=new Uint8Array(16),i,j,h=[];if(typeof crypto.getRandomValues==="function"){crypto.getRandomValues(b);}else{for(i=0;i<16;i++){b[i]=Math.floor(Math.random()*256);}}b[6]=(b[6]&15)|64;b[8]=(b[8]&63)|128;for(j=0;j<16;j++){h.push((b[j]+256).toString(16).slice(1));}return h.slice(0,4).join("")+"-"+h.slice(4,6).join("")+"-"+h.slice(6,8).join("")+"-"+h.slice(8,10).join("")+"-"+h.slice(10,16).join("");};try{Object.defineProperty(crypto,"randomUUID",{value:f,configurable:true});}catch(e){crypto.randomUUID=f;}}})();</script></head>';
        sub_filter_once on;

        proxy_pass http://127.0.0.1:__DSH_PORT__;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $http_host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
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

[Service]
Type=simple
User=${DSH_USER}
Group=${DSH_USER}
WorkingDirectory=${DSH_WORKDIR}
Environment=DSH_HOME=${DSH_HOME}
Environment=DSH_PORT=${DSH_PORT}
Environment=PUBLIC_PORT=${PUBLIC_PORT}
# '+'-Präfix: Renderer braucht Root-Rechte für /etc/nginx (User=dsh gilt sonst
# auch für ExecStartPre) und schreibt nur die deterministische Origin-Map.
ExecStartPre=+/usr/local/bin/dsh-render-origin-map.sh
ExecStart=/usr/local/bin/dsh-start.sh
Restart=always
RestartSec=5
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable nginx "$APP" >/dev/null 2>&1
systemctl restart nginx
systemctl restart "$APP"
msg_ok "Services aktiviert (enable + restart)"

# ───────────────────────── 8. Verifikation ──────────────────────────────────
sleep 3
if ! systemctl is-active --quiet "$APP"; then
  msg_fatal "Service '${APP}' läuft nicht – Logausgabe siehe oben (Fehlerkette)."
fi
msg_ok "Service '${APP}' ist aktiv"

msg_info "Warte auf Web UI (erste Inbetriebnahme kann ~1 Minute dauern)"
HTTP_OK=0
for _ in $(seq 1 60); do
  if curl -fsS -o /dev/null "http://127.0.0.1:${PUBLIC_PORT}"; then HTTP_OK=1; break; fi
  sleep 2
done
if [[ "$HTTP_OK" -ne 1 ]]; then
  journalctl -u "$APP" -n 50 --no-pager || true
  msg_fatal "Web UI antwortet nicht auf Port ${PUBLIC_PORT} – Logs siehe oben."
fi
msg_ok "Web UI antwortet auf http://localhost:${PUBLIC_PORT}"

if curl -fsS "http://127.0.0.1:${PUBLIC_PORT}" | grep -q "randomUUID"; then
  msg_ok "randomUUID-Polyfill wird ausgeliefert (Fix für http-Zugriff ohne HTTPS)"
else
  msg_fatal "Polyfill fehlt in der HTML-Antwort – nginx sub_filter prüfen."
fi

# Privilegierte API-Ebene: Loopback-Masquerade muss greifen (kein 403),
# fremde Origins müssen weiter geblockt bleiben (403 durch unseren Fence).
CT_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
PRIV_CODE=$(curl -sS -o /dev/null -w "%{http_code}" \
  -H "Host: ${CT_IP}:${PUBLIC_PORT}" \
  -H "Origin: http://${CT_IP}:${PUBLIC_PORT}" \
  -H "Sec-Fetch-Site: same-origin" \
  "http://127.0.0.1:${PUBLIC_PORT}/api/settings.describe" || true)
if [[ "$PRIV_CODE" == "403" ]]; then
  journalctl -u nginx -n 20 --no-pager || true
  msg_fatal "Privilegierte API liefert 403 – Loopback-Masquerade/Origin-Map prüfen."
fi
msg_ok "Privilegierte API erreichbar (settings.describe → HTTP ${PRIV_CODE}, erwartet ≠ 403)"

EVIL_CODE=$(curl -sS -o /dev/null -w "%{http_code}" \
  -H "Host: ${CT_IP}:${PUBLIC_PORT}" \
  -H "Origin: http://boeser-server.example" \
  "http://127.0.0.1:${PUBLIC_PORT}/api/settings.describe" || true)
if [[ "$EVIL_CODE" != "403" ]]; then
  msg_fatal "Fremder Origin wurde NICHT blockiert (HTTP ${EVIL_CODE}) – Origin-Filter prüfen!"
fi
msg_ok "Fremder Origin korrekt blockiert (HTTP 403)"

LISTEN_OK=$(ss -tln 2>/dev/null | awk '{print $4}' | grep -E ":(${PUBLIC_PORT}|${DSH_PORT})$" | sort -u || true)
msg_ok "Lauschende Sockets: ${LISTEN_OK//$'\n'/ · }"

# ──────────────────────────── Abschlussbox ──────────────────────────────────
echo ""
echo -e "${GN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}"
echo -e "${GN} ${APP_NAME} ist bereit!${CL}"
echo -e "${GN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}"
echo -e " ${YW}URL:${CL}         http://${CT_IP:-<CT-IP>}:${PUBLIC_PORT}"
echo -e " ${YW}Nächster Schritt:${CL} Settings → Models → DeepSeek-API-Key"
echo -e " ${YW}Logs:${CL}        journalctl -u ${APP} -e · /var/log/nginx/"
echo -e "${GN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}"
