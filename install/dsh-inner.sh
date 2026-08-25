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
IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
HOSTN="$(hostname -f 2>/dev/null || hostname)"

ARGS=(web --no-open
      --host 127.0.0.1
      --port "${DSH_PORT:-3080}")

# Autoritäten, unter denen das Web UI den Browser akzeptiert
[[ -n "${IP}" ]] && ARGS+=(--trusted-host "${IP}:${PUBLIC_PORT:-8080}")
ARGS+=("--trusted-host" "localhost:${PUBLIC_PORT:-8080}")
ARGS+=("--trusted-host" "127.0.0.1:${PUBLIC_PORT:-8080}")
ARGS+=("--trusted-host" "${HOSTN}:${PUBLIC_PORT:-8080}")

exec "${DSH_BIN}" "${ARGS[@]}"
WRAPPER
chmod 755 /usr/local/bin/dsh-start.sh
msg_ok "Wrapper erstellt"

# ───────────────────────── 6. Reverse Proxy (nginx) ─────────────────────────
# Notwendig, weil 'dsh web' absichtlich kein --host 0.0.0.0 unterstützt.
msg_info "nginx als Reverse Proxy (0.0.0.0:${PUBLIC_PORT} → 127.0.0.1:${DSH_PORT})"
cat > /etc/nginx/sites-available/dsh.conf << 'NGINX'
server {
    listen 0.0.0.0:__PUBLIC_PORT__;
    listen [::]:__PUBLIC_PORT__;
    server_name _;
    client_max_body_size 64m;

    location / {
        proxy_pass http://127.0.0.1:__DSH_PORT__;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
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

LISTEN_OK=$(ss -tln 2>/dev/null | awk '{print $4}' | grep -E ":(${PUBLIC_PORT}|${DSH_PORT})$" | sort -u || true)
msg_ok "Lauschende Sockets: ${LISTEN_OK//$'\n'/ · }"

# ──────────────────────────── Abschlussbox ──────────────────────────────────
CT_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
echo ""
echo -e "${GN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}"
echo -e "${GN} ${APP_NAME} ist bereit!${CL}"
echo -e "${GN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}"
echo -e " ${YW}URL:${CL}         http://${CT_IP:-<CT-IP>}:${PUBLIC_PORT}"
echo -e " ${YW}Nächster Schritt:${CL} Settings → Models → DeepSeek-API-Key"
echo -e " ${YW}Logs:${CL}        journalctl -u ${APP} -e · /var/log/nginx/"
echo -e "${GN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}"
