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

INSTALL_FILEBROWSER="${INSTALL_FILEBROWSER:-1}"
FILEBROWSER_PORT="${FILEBROWSER_PORT:-8081}"
FILEBROWSER_USER="${FILEBROWSER_USER:-admin}"
FILEBROWSER_PASSWORD="${FILEBROWSER_PASSWORD:-admin}"
FILEBROWSER_ROOT="${FILEBROWSER_ROOT:-/opt/dsh}"
FILEBROWSER_VERSION="${FILEBROWSER_VERSION:-2.63.23}"

# pnpm wird vom dsh-Plugin-Manager als eigener Prozess aufgerufen
# ('pnpm view' / 'pnpm add'). Ohne pnpm scheitern Plugin-Suche und -Installation
# mit "spawn pnpm ENOENT" bzw. "pnpm was not found".
PNPM_VERSION="${PNPM_VERSION:-12.15.0}"

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
FB_TMP=""
FB_PID=""
FB_SETUP_LOG=""
FB_NEW_DB=0
cleanup() {
  [[ -n "$API_KEY_FILE" ]] && rm -f "$API_KEY_FILE"
  [[ -n "$JAR" ]] && rm -f "$JAR"
  [[ -n "$IDX_HTML" ]] && rm -f "$IDX_HTML"
  [[ -n "$FB_TMP" ]] && rm -rf "$FB_TMP"
  [[ -n "$FB_SETUP_LOG" ]] && rm -f "$FB_SETUP_LOG"
  [[ -n "$FB_PID" ]] && kill "$FB_PID" 2>/dev/null
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

case "$INSTALL_FILEBROWSER" in
  0|1) ;;
  *) msg_fatal "INSTALL_FILEBROWSER muss 0 oder 1 sein." ;;
esac
if [[ "$INSTALL_FILEBROWSER" == "1" ]]; then
  if [[ ! "$FILEBROWSER_PORT" =~ ^[0-9]+$ ]] \
    || (( FILEBROWSER_PORT < 1 || FILEBROWSER_PORT > 65535 )); then
    msg_fatal "FILEBROWSER_PORT muss eine Portnummer (1-65535) sein."
  fi
  [[ "$FILEBROWSER_USER" =~ ^[A-Za-z0-9._-]{1,32}$ ]] \
    || msg_fatal "FILEBROWSER_USER: erlaubt sind 1-32 Zeichen aus [A-Za-z0-9._-]."
  [[ "$FILEBROWSER_PASSWORD" =~ ^[A-Za-z0-9._!@#%^\&*+=-]{1,64}$ ]] \
    || msg_fatal "FILEBROWSER_PASSWORD: erlaubt sind 1-64 Zeichen aus [A-Za-z0-9._!@#%^&*+=-]."
  [[ "$FILEBROWSER_ROOT" =~ ^/[A-Za-z0-9._/-]+$ ]] \
    || msg_fatal "FILEBROWSER_ROOT muss ein absoluter Pfad ohne Leerzeichen/Sonderzeichen sein."
  [[ "$FILEBROWSER_VERSION" =~ ^[A-Za-z0-9._-]+$ ]] \
    || msg_fatal "FILEBROWSER_VERSION enthält unerwartete Zeichen."
  FILEBROWSER_VERSION="${FILEBROWSER_VERSION#v}"
fi

[[ "$PNPM_VERSION" =~ ^[A-Za-z0-9._-]+$ ]] \
  || msg_fatal "PNPM_VERSION enthält unerwartete Zeichen (erlaubt: [A-Za-z0-9._-])."
PNPM_VERSION="${PNPM_VERSION#v}"
[[ -n "$PNPM_VERSION" ]] || msg_fatal "PNPM_VERSION darf nicht leer sein."

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

# ─────────────── 3b. pnpm – Pflicht für den dsh-Plugin-Manager ──────────────
# Der Plugin-Manager startet 'pnpm view' bzw. 'pnpm add' als eigenen Prozess.
# Fehlt die Binärdatei, brechen Plugin-Suche und -Installation mit
# "spawn pnpm ENOENT" ab – deshalb wird pnpm hier immer sichergestellt.
PNPM_HAVE="$(pnpm --version 2>/dev/null || true)"
if [[ -z "$PNPM_HAVE" || "$PNPM_VERSION" == "latest" || "$PNPM_HAVE" != "$PNPM_VERSION" ]]; then
  msg_info "pnpm ${PNPM_VERSION} wird installiert (dsh-Plugin-Manager)"
  npm install -g "pnpm@${PNPM_VERSION}" --no-audit --no-fund --loglevel=error
  hash -r 2>/dev/null || true
  PNPM_HAVE="$(pnpm --version 2>/dev/null || true)"
  [[ -n "$PNPM_HAVE" ]] || msg_fatal "pnpm konnte nicht installiert werden (npm-Ausgabe oben prüfen)."
  msg_ok "pnpm ${PNPM_HAVE} installiert ($(command -v pnpm))"
else
  msg_ok "pnpm ${PNPM_HAVE} bereits installiert"
fi

# npm kann global in ein Prefix installieren, das nicht im PATH liegt.
NPM_GLOBAL_BIN="$(npm prefix -g 2>/dev/null || echo /usr)/bin"
if ! command -v pnpm >/dev/null 2>&1 && [[ -x "${NPM_GLOBAL_BIN}/pnpm" ]]; then
  ln -sfn "${NPM_GLOBAL_BIN}/pnpm" /usr/local/bin/pnpm
  hash -r 2>/dev/null || true
fi
command -v pnpm >/dev/null 2>&1 \
  || msg_fatal "pnpm ist nicht im PATH – Plugin-Manager würde mit ENOENT scheitern."

# Der Service läuft als Benutzer 'dsh'; genau dieser Benutzer muss pnpm aufrufen
# können (PATH, Leserechte, HOME für den pnpm-Store).
if command -v runuser >/dev/null 2>&1; then
  runuser -u "$DSH_USER" -- env HOME="$DSH_HOME" PATH="$PATH" pnpm --version >/dev/null 2>&1 \
    || msg_fatal "Benutzer '${DSH_USER}' kann pnpm nicht ausführen – Rechte/PATH prüfen."
fi
msg_ok "pnpm ist für den Plugin-Manager bereit (auch als Benutzer '${DSH_USER}')"

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

# ───────────────────────── 6b. FileBrowser (optional) ───────────────────────
# Zugriff auf den dsh-Workspace über eine Weboberfläche. Standard-Login ist
# admin/admin (per FILEBROWSER_USER/PASSWORD überschreibbar). FileBrowser
# läuft als dsh-Benutzer und sieht nur FILEBROWSER_ROOT, nicht /var/lib/dsh.
if [[ "$INSTALL_FILEBROWSER" == "1" ]]; then
  msg_info "FileBrowser wird installiert (Dateizugriff auf ${FILEBROWSER_ROOT})"

  FB_ARCH="$(dpkg --print-architecture)"
  case "$FB_ARCH" in
    amd64|arm64) ;;
    i386)  FB_ARCH="386" ;;
    armhf) FB_ARCH="armv7" ;;
    *) msg_fatal "FileBrowser: Architektur '${FB_ARCH}' wird nicht unterstützt." ;;
  esac

  FB_TMP="$(mktemp -d)"
  if [[ "$FILEBROWSER_VERSION" == "latest" ]]; then
    FB_URL="https://github.com/filebrowser/filebrowser/releases/latest/download/linux-${FB_ARCH}-filebrowser.tar.gz"
  else
    FB_URL="https://github.com/filebrowser/filebrowser/releases/download/v${FILEBROWSER_VERSION}/linux-${FB_ARCH}-filebrowser.tar.gz"
  fi
  msg_info "Lade FileBrowser ${FILEBROWSER_VERSION} (${FB_ARCH})"
  curl -fsSL --retry 3 --connect-timeout 15 -o "${FB_TMP}/fb.tar.gz" "$FB_URL"
  tar -xzf "${FB_TMP}/fb.tar.gz" -C "$FB_TMP" filebrowser
  install -m 755 "${FB_TMP}/filebrowser" /usr/local/bin/filebrowser
  rm -rf "$FB_TMP"
  FB_TMP=""
  msg_ok "FileBrowser $(/usr/local/bin/filebrowser version 2>/dev/null | head -n1)"

  if [[ ! -d "$FILEBROWSER_ROOT" ]]; then
    mkdir -p "$FILEBROWSER_ROOT"
    chown "${DSH_USER}:${DSH_USER}" "$FILEBROWSER_ROOT"
  fi

  FB_DB="${DSH_HOME}/filebrowser.db"

  # Laufenden Dienst anhalten: Setup und Reparatur schreiben exklusiv in die DB.
  systemctl stop filebrowser >/dev/null 2>&1 || true

  # Eine vorhandene DB kann von einem abgebrochenen Setup unvollständig sein
  # (Bolt-Datei ohne Settings → "the resource does not exist" beim Start).
  # 'config cat' liest die Settings und erkennt solche Dateien zuverlässig.
  FB_DB_OK=0
  if [[ -s "$FB_DB" ]] \
    && /usr/local/bin/filebrowser config cat -d "$FB_DB" >/dev/null 2>&1; then
    FB_DB_OK=1
  fi
  if [[ -s "$FB_DB" && "$FB_DB_OK" != "1" ]]; then
    FB_DB_BROKEN="${FB_DB}.broken-$(date +%Y%m%d-%H%M%S)"
    mv "$FB_DB" "$FB_DB_BROKEN"
    msg_warn "Unvollständige FileBrowser-Datenbank gesichert (${FB_DB_BROKEN}) – wird neu angelegt"
  fi

  if [[ "$FB_DB_OK" != "1" ]]; then
    FB_NEW_DB=1
    msg_info "FileBrowser-Admin '${FILEBROWSER_USER}' wird angelegt"
    # Quick-Setup mit bcrypt-Hash: umgeht die Passwort-Stärkeprüfung, damit
    # der gewünschte Login (standardmäßig admin/admin) exakt funktioniert.
    FB_HASH="$(/usr/local/bin/filebrowser hash "$FILEBROWSER_PASSWORD")"
    FB_SETUP_LOG="$(mktemp)"
    FB_PASSWORD="$FB_HASH" /usr/local/bin/filebrowser \
      -d "$FB_DB" --username "$FILEBROWSER_USER" \
      --address 127.0.0.1 --port "$FILEBROWSER_PORT" --root "$FILEBROWSER_ROOT" \
      >"$FB_SETUP_LOG" 2>&1 &
    FB_PID=$!

    # Nicht nach festen 5 s abbrechen (das hinterlässt genau die halbe DB),
    # sondern auf die erste fertige Servermeldung warten: "Listening on"
    # erscheint erst nach Quick-Setup und erfolgreichem Settings-Laden.
    FB_READY=0
    for _ in $(seq 1 150); do   # max. 30 s
      if grep -q "Listening on" "$FB_SETUP_LOG" 2>/dev/null; then
        FB_READY=1
        break
      fi
      kill -0 "$FB_PID" 2>/dev/null || break
      sleep 0.2
    done

    # Setup-Server kontrolliert beenden (SIGTERM, dann SIGKILL als Fallback).
    if kill -0 "$FB_PID" 2>/dev/null; then
      kill "$FB_PID" 2>/dev/null || true
      for _ in $(seq 1 25); do
        kill -0 "$FB_PID" 2>/dev/null || break
        sleep 0.2
      done
      kill -9 "$FB_PID" 2>/dev/null || true
    fi
    wait "$FB_PID" 2>/dev/null || true
    FB_PID=""

    # Doppelte Absicherung: DB muss nach dem Setup lesbare Settings enthalten.
    if [[ "$FB_READY" != "1" ]] \
      || ! /usr/local/bin/filebrowser config cat -d "$FB_DB" >/dev/null 2>&1; then
      cat "$FB_SETUP_LOG" >&2 || true
      rm -f "$FB_SETUP_LOG" "$FB_DB"
      FB_SETUP_LOG=""
      msg_fatal "FileBrowser-Initialisierung fehlgeschlagen (Details im Log oben)."
    fi
    rm -f "$FB_SETUP_LOG"
    FB_SETUP_LOG=""
    msg_ok "FileBrowser-Login: ${FILEBROWSER_USER} / ${FILEBROWSER_PASSWORD}"
  else
    msg_ok "FileBrowser-Datenbank vorhanden – Login bleibt unverändert"
  fi
  chown "${DSH_USER}:${DSH_USER}" "$FB_DB"
  chmod 600 "$FB_DB"

  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "${FILEBROWSER_PORT}/tcp" >/dev/null
    msg_ok "UFW: Port ${FILEBROWSER_PORT}/tcp erlaubt"
  fi

  cat > /etc/systemd/system/filebrowser.service << UNIT
[Unit]
Description=FileBrowser – Dateizugriff auf ${FILEBROWSER_ROOT}
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=${DSH_USER}
Group=${DSH_USER}
Environment=HOME=${DSH_HOME}
ExecStart=/usr/local/bin/filebrowser -d ${FB_DB} --address 0.0.0.0 --port ${FILEBROWSER_PORT} --root ${FILEBROWSER_ROOT}
Restart=always
RestartSec=5
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
UNIT
  msg_ok "FileBrowser-Service geschrieben (Port ${FILEBROWSER_PORT})"
else
  # Deaktivieren, aber Daten (DB) und Binary bewusst nicht löschen.
  if [[ -f /etc/systemd/system/filebrowser.service ]]; then
    systemctl disable --now filebrowser >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/filebrowser.service
    systemctl daemon-reload
    msg_ok "FileBrowser deaktiviert (Daten bleiben in ${DSH_HOME} erhalten)"
  fi
fi

# ───────────────────────── 7. systemd-Unit ──────────────────────────────────
msg_info "systemd-Unit wird geschrieben (/etc/systemd/system/${APP}.service)"
# pnpm liegt je nach npm-Prefix in /usr/bin oder einem eigenen Verzeichnis.
# Der PATH im Service stellt sicher, dass der Plugin-Manager pnpm findet.
SERVICE_PATH="${NPM_GLOBAL_BIN}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
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
Environment=PATH=${SERVICE_PATH}
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
if [[ "$INSTALL_FILEBROWSER" == "1" ]]; then
  systemctl enable filebrowser >/dev/null 2>&1
fi
systemctl restart nginx
# Zeitstempel vor dem Start: verhindert, dass die Verifikation den Token
# eines vorherigen dsh-Prozesses aus dem selben Boot erwischt.
START_TS="$(date '+%Y-%m-%d %H:%M:%S')"
systemctl restart "$APP"
if [[ "$INSTALL_FILEBROWSER" == "1" ]]; then
  systemctl restart filebrowser
fi
msg_ok "Services aktiviert (enable + restart)"

# ───────────────────────── 8. Verifikation ──────────────────────────────────
sleep 3
if ! systemctl is-active --quiet "$APP"; then
  msg_fatal "Service '${APP}' läuft nicht – Logausgabe siehe oben (Fehlerkette)."
fi
msg_ok "Service '${APP}' ist aktiv"

if [[ "$INSTALL_FILEBROWSER" == "1" ]]; then
  if ! systemctl is-active --quiet filebrowser; then
    journalctl -u filebrowser -n 50 --no-pager || true
    msg_fatal "Service 'filebrowser' läuft nicht – Logausgabe siehe oben."
  fi
  FB_CODE="$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' \
    "http://127.0.0.1:${FILEBROWSER_PORT}/" || true)"
  if [[ "$FB_CODE" != "200" ]]; then
    journalctl -u filebrowser -n 50 --no-pager || true
    msg_fatal "FileBrowser antwortet nicht (HTTP ${FB_CODE}) – Service/Port prüfen."
  fi
  msg_ok "FileBrowser erreichbar (HTTP 200, Port ${FILEBROWSER_PORT})"

  if [[ "$FB_NEW_DB" == "1" ]]; then
    FB_LOGIN_CODE="$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' \
      -H "Content-Type: application/json" \
      -d "{\"username\":\"${FILEBROWSER_USER}\",\"password\":\"${FILEBROWSER_PASSWORD}\"}" \
      "http://127.0.0.1:${FILEBROWSER_PORT}/api/login" || true)"
    if [[ "$FB_LOGIN_CODE" != "200" ]]; then
      msg_fatal "FileBrowser-Login '${FILEBROWSER_USER}' fehlgeschlagen (HTTP ${FB_LOGIN_CODE})."
    fi
    msg_ok "FileBrowser-Login '${FILEBROWSER_USER}' funktioniert (HTTP 200)"
  fi
fi

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
  LISTEN_PORTS="${PUBLIC_PORT}|${DSH_PORT}"
  if [[ "$INSTALL_FILEBROWSER" == "1" ]]; then
    LISTEN_PORTS+="|${FILEBROWSER_PORT}"
  fi
  LISTEN_OK="$(ss -tln 2>/dev/null | awk '{print $4}' \
    | grep -E ":(${LISTEN_PORTS})$" | sort -u || true)"
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
echo -e " ${YW}pnpm:${CL}        ${PNPM_HAVE} (Plugin-Manager bereit)"
if [[ "$INSTALL_FILEBROWSER" == "1" ]]; then
  echo -e " ${YW}FileBrowser:${CL} http://${CT_IP}:${FILEBROWSER_PORT}"
  echo -e " ${YW}FB-IP:${CL}       ${CT_IP}"
  echo -e " ${YW}FB-Port:${CL}     ${FILEBROWSER_PORT}"
  if [[ "$FB_NEW_DB" == "1" ]]; then
    echo -e " ${YW}FB-Login:${CL}    ${FILEBROWSER_USER} / ${FILEBROWSER_PASSWORD}"
  else
    echo -e " ${YW}FB-Login:${CL}    ${FILEBROWSER_USER} / ${FILEBROWSER_PASSWORD}  (Initial-Login, ggf. geändert)"
  fi
  echo -e " ${YW}FB-Root:${CL}     ${FILEBROWSER_ROOT}"
  if [[ "$FILEBROWSER_PASSWORD" == "admin" && "$FB_NEW_DB" == "1" ]]; then
    echo -e "                  ${RD}Bitte admin/admin ändern und nicht ins Internet stellen.${CL}"
  fi
fi
if [[ -n "${API_KEY}" ]]; then
  echo -e " ${YW}API-Key:${CL}     hinterlegt und aktiv – Models-Auswahl sofort nutzbar"
else
  echo -e " ${YW}Falls nötig:${CL}   Settings → Models → DeepSeek-API-Key"
fi
echo -e " ${YW}Logs:${CL}        journalctl -u ${APP} -e · /var/log/nginx/"
echo -e "${GN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}"
