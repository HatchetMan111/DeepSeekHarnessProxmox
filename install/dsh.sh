#!/usr/bin/env bash
# ============================================================================
#  DeepSeek Harness (dsh) – Proxmox LXC Installer
#  Stil: Proxmox VE Community Scripts – läuft auf dem Proxmox-Host (PVE 8.x)
#
#  Einzeiler:
#    bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/DeepSeekHarnessProxmox/main/install/dsh.sh)"
#
#  Mit eigener CT-ID / angepassten Ressourcen (Umgebungsvariablen):
#    CTID=150 CORES=4 MEM_MB=4096 bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/DeepSeekHarnessProxmox/main/install/dsh.sh)"
#
#  Existiert die CT-ID bereits, wird das Script im Update-Modus ausgeführt.
# ============================================================================

# -E: ERR-Trap auch in Funktionen/Subshells | -e: bei Fehler abbrechen
# -u: ungesetzte Variablen sind Fehler      | -o pipefail: Pipeline-Fehler zählen
set -Eeuo pipefail

# ───────────────────────────── Variablen ────────────────────────────────────
REPO_USER="HatchetMan111"
REPO_NAME="DeepSeekHarnessProxmox"
BRANCH="main"
RAW_BASE="https://raw.githubusercontent.com/${REPO_USER}/${REPO_NAME}/${BRANCH}"

APP="dsh"
APP_NAME="DeepSeek Harness"

CTID="${CTID:-}"                    # leer → automatisch die nächste freie ID
HOST_NAME="${HOST_NAME:-DeepSeekHarness}"   # Hostname des Containers
STORAGE="${STORAGE:-auto}"          # "auto" → erste aktive Storage mit rootdir
VZTMP_STORAGE="${VZTMP_STORAGE:-local}"   # Storage für das Debian-Template
NET_BRIDGE="${NET_BRIDGE:-vmbr0}"

PCT_OSVERSION="${PCT_OSVERSION:-12}"
CORES="${CORES:-2}"
MEM_MB="${MEM_MB:-4096}"            # npm/dsh + Agent-Sessions brauchen Luft
SWAP_MB="${SWAP_MB:-1024}"
DISK_GB="${DISK_GB:-16}"

PUBLIC_PORT="${PUBLIC_PORT:-8080}"  # extern erreichbarer Port (nginx)
DSH_PORT="${DSH_PORT:-3080}"        # interner dsh-Port (nur 127.0.0.1)
DSH_VERSION="${DSH_VERSION:-0.2.1-rc.2}"  # getestet; "latest" für Auto-Update

INNER_FILE="dsh-inner.sh"
INNER_URL="${INNER_URL:-${RAW_BASE}/install/${INNER_FILE}}"
HOST_LOG="/tmp/${APP}-install-$(date +%Y%m%d-%H%M%S).log"

# DeepSeek-API-Key: optional per Umgebungsvariable setzen (Automatisierung),
# sonst wird bei interaktivem Lauf danach gefragt. Leer = überspringen
# (Key kann jederzeit in der Web UI unter Settings → Models eingetragen werden).
DEEPSEEK_API_KEY="${DEEPSEEK_API_KEY:-}"
KEY_FILE_HOST=""
cleanup() { if [[ -n "${KEY_FILE_HOST:-}" ]]; then rm -f "$KEY_FILE_HOST"; fi; }
trap cleanup EXIT

# ───────────────────────────── Ausgabe-Helfer ───────────────────────────────
YW='\033[33m'; GN='\033[1;92m'; RD='\033[01;31m'; BL='\033[36m'; CL='\033[m'
CM="${GN}✔${CL}"; CROSS="${RD}✘${CL}"; INFO="${BL}ℹ${CL}"
msg_info()  { echo -e " ${INFO} ${1}"; }
msg_ok()    { echo -e " ${CM} ${1}"; }
msg_fatal() { echo -e " ${CROSS} ${1}" >&2; exit 1; }

[[ "$DSH_VERSION" =~ ^[A-Za-z0-9._-]+$ ]] \
  || msg_fatal "DSH_VERSION enthält unerwartete Zeichen (erlaubt: [A-Za-z0-9._-])."

# ───────────────────── Vollständige Fehlermeldungskette ─────────────────────
on_error() {
  local ec="$1" ln="$2" cmd="$3"
  echo "" >&2
  echo -e "${RD}━━━━━━━━ FEHLERKETTE ━━━━━━━━${CL}" >&2
  echo -e " Exit-Code : ${ec}" >&2
  echo -e " Zeile     : ${ln}" >&2
  echo -e " Befehl    : ${cmd}" >&2
  if [[ -s "$HOST_LOG" ]]; then
    echo -e "${RD}── letzte 40 Zeilen des Installationslogs (${HOST_LOG}) ──${CL}" >&2
    tail -n 40 "$HOST_LOG" >&2 || true
  fi
  echo -e "${YW} Debug-Tipps:${CL}" >&2
  echo -e "  • Kompletten Ablauf verfolgen : bash -x <(wget -qLO - ${RAW_BASE}/install/dsh.sh)" >&2
  echo -e "  · Im Container nachschauen   : pct enter <CTID>  →  Log: journalctl -u ${APP} -e" >&2
  echo -e "${RD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}" >&2
  exit "$ec"
}
trap 'on_error $? $LINENO "$BASH_COMMAND"' ERR

# ───────────────────────── 1. Host-Voraussetzungen ──────────────────────────
[[ $EUID -eq 0 ]] || msg_fatal "Bitte als root ausführen (z. B. via 'bash -c \"\$(wget ...)\"' auf der PVE-Shell)."
command -v pct   >/dev/null || msg_fatal "'pct' nicht gefunden – bitte auf einem Proxmox-VE-Host ausführen."
command -v pveam >/dev/null || msg_fatal "'pveam' nicht gefunden – bitte auf einem Proxmox-VE-Host ausführen."

echo -e "${GN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}"
echo -e "${GN} ${APP_NAME} – LXC Installer (Community-Scripts-Stil)${CL}"
echo -e "${GN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}"

# ─────────────────── Optional: DeepSeek-API-Key beschaffen ──────────────────
if [[ -z "$DEEPSEEK_API_KEY" ]]; then
  # Auch bei "curl | bash" funktioniert die Abfrage über das Terminal.
  TTY_IN=""
  if [[ -t 0 ]]; then
    TTY_IN="/dev/stdin"
  elif (exec 3</dev/tty) 2>/dev/null; then
    TTY_IN="/dev/tty"
  fi
  if [[ -n "$TTY_IN" ]]; then
    echo ""
    echo -e " ${YW}Optional: DeepSeek-API-Key hinterlegen${CL}"
    echo -e " Der Key wird nur lokal im Container gespeichert (${YW}/var/lib/dsh/.credentials.yaml${CL}, Modus 600)."
    echo -e " Überspringen mit Enter – konfigurierbar jederzeit in der Web UI (Settings → Models)."
    if ! read -rs -p " API-Key [Enter = überspringen]: " DEEPSEEK_API_KEY < "$TTY_IN"; then
      DEEPSEEK_API_KEY=""
    fi
    echo ""
  else
    msg_info "Kein Terminal für die Key-Abfrage – übersprungen (später in Settings → Models)."
  fi
fi
DEEPSEEK_API_KEY="${DEEPSEEK_API_KEY//[[:space:]]/}"
DEEPSEEK_API_KEY="${DEEPSEEK_API_KEY#Bearer }"
if [[ -n "$DEEPSEEK_API_KEY" ]]; then
  if [[ ! "$DEEPSEEK_API_KEY" =~ ^[A-Za-z0-9_.-]{20,}$ ]]; then
    msg_fatal "API-Key hat unerwartetes Format (mind. 20 Zeichen aus [A-Za-z0-9_.-] erwartet)."
  fi
  KEY_FILE_HOST="$(mktemp /tmp/.dsh-apikey.XXXXXX)"
  printf '%s' "$DEEPSEEK_API_KEY" > "$KEY_FILE_HOST"
  chmod 600 "$KEY_FILE_HOST"
fi

# ───────────────────────────── 2. CT-ID wählen ──────────────────────────────
if [[ -z "$CTID" ]]; then
  CTID="$(pvesh get /cluster/nextid)"
  msg_info "Keine CT-ID angegeben – verwende nächste freie ID: ${CTID}"
fi
if pct status "$CTID" >/dev/null 2>&1; then
  UPDATE_MODE=1
  msg_info "CT ${CTID} existiert bereits → Update-Modus (idempotente Neuinstallation)"
else
  UPDATE_MODE=0
fi

# ────────────────────── 3. Container erzeugen (nur neu) ─────────────────────
if [[ "$UPDATE_MODE" -eq 0 ]]; then
  msg_info "Storage wird ermittelt"
  if [[ "$STORAGE" == "auto" ]]; then
    STORAGE="$(pvesm status -content rootdir | awk 'NR>1 && $0 ~ /active/ {print $1; exit}')"
  fi
  [[ -n "$STORAGE" ]] || msg_fatal "Keine aktive Storage mit Inhaltstyp 'rootdir' gefunden. STORAGE=<name> setzen."
  pvesm status -content vztmpl | awk 'NR>1 {print $1}' | grep -qx "$VZTMP_STORAGE" \
    || msg_fatal "Storage '${VZTMP_STORAGE}' unterstützt keine Container-Templates (vztmpl). VZTMP_STORAGE=<name> setzen."
  msg_ok "Rootfs-Storage: ${STORAGE}"

  msg_info "Debian-${PCT_OSVERSION}-Template wird gesucht"
  pveam update >/dev/null
  TEMPLATE="$(pveam available --section system \
              | grep "debian-${PCT_OSVERSION}-standard" | awk '{print $NF}' | sort -r | head -n1)"
  [[ -n "$TEMPLATE" ]] || msg_fatal "Kein debian-${PCT_OSVERSION}-standard-Template gefunden."
  if ! pveam list "$VZTMP_STORAGE" | grep -q "$TEMPLATE"; then
    pveam download "$VZTMP_STORAGE" "$TEMPLATE" >/dev/null
  fi
  msg_ok "Template: ${TEMPLATE}"

  ROOT_PW="$(openssl rand -base64 15)"
  msg_info "LXC-Container ${CTID} wird erstellt (${CORES} vCPU / ${MEM_MB} MB RAM / ${DISK_GB} GB)"
  pct create "$CTID" "${VZTMP_STORAGE}:vztmpl/${TEMPLATE}" \
    --hostname "$HOST_NAME" \
    --cores "$CORES" \
    --memory "$MEM_MB" \
    --swap "$SWAP_MB" \
    --rootfs "${STORAGE}:${DISK_GB}" \
    --net0 "name=eth0,bridge=${NET_BRIDGE},ip=dhcp" \
    --features nesting=1 \
    --unprivileged 1 \
    --onboot 1 \
    --start 1 \
    --password "$ROOT_PW" \
    --description "DeepSeek Harness Web UI – http://<IP>:${PUBLIC_PORT}<br>Installiert am $(date '+%Y-%m-%d %H:%M')" \
    >/dev/null
  printf '%s\n' "CT ${CTID} (${APP_NAME}) – Root-Passwort: ${ROOT_PW}" > "/root/${APP}-ct${CTID}.credentials"
  chmod 600 "/root/${APP}-ct${CTID}.credentials"
  msg_ok "Container erstellt – onboot aktiv, Root-PW in /root/${APP}-ct${CTID}.credentials"
else
  msg_info "Container wird gestartet (falls gestoppt)"
  pct start "$CTID" 2>/dev/null || true
  # Auch bei bestehenden CTs Reboot-Sicherheit erzwingen.
  pct set "$CTID" --onboot 1 >/dev/null
fi

# ─────────────── 4. Auf Netzwerk im Container warten ────────────────────────
msg_info "Warte auf Netzwerk im Container"
NET_OK=0
for _ in $(seq 1 30); do
  if pct exec "$CTID" -- getent hosts deb.debian.org >/dev/null 2>&1; then NET_OK=1; break; fi
  sleep 2
done
[[ "$NET_OK" -eq 1 ]] || msg_fatal "Container ${CTID} hat kein Netzwerk (DNS/Route prüfen: pct exec ${CTID} -- ip a)."
msg_ok "Netzwerk bereit"

# ───────────── 5. Bootstrap (wget/ca-certs) + Inner-Script laden ────────────
msg_info "Bootstrap-Pakete im Container"
pct exec "$CTID" -- bash -c \
  "export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get install -y -qq ca-certificates wget >/dev/null"

msg_info "Lade Installations-Script: ${INNER_URL}"
pct exec "$CTID" -- wget -qO "/tmp/${INNER_FILE}" "${INNER_URL}"

# API-Key (falls gesetzt) ohne Prozesslisten-Exposition in den CT pushen.
# Das Inner-Script liest die Datei und löscht sie sofort wieder.
KEY_FILE_CT=""
if [[ -n "${DEEPSEEK_API_KEY:-}" && -f "${KEY_FILE_HOST:-}" ]]; then
  KEY_FILE_CT="/tmp/.dsh-apikey"
  pct push "$CTID" "$KEY_FILE_HOST" "$KEY_FILE_CT" >/dev/null
  pct exec "$CTID" -- chmod 600 "$KEY_FILE_CT"
  rm -f "$KEY_FILE_HOST"
  KEY_FILE_HOST=""
else
  # Keine Altlasten von abgebrochenen Läufen im Container.
  pct exec "$CTID" -- rm -f /tmp/.dsh-apikey
fi

# ──────────────── 6. Installation im Container ausführen ────────────────────
# Vollständige Ausgabe (stdout+stderr) parallel ins Host-Log schreiben;
# pipefail stellt sicher, dass ein Fehler des Inner-Scripts hier ankommt.
set -o pipefail
msg_info "Installiere ${APP_NAME} im Container (Log: ${HOST_LOG})"
if [[ -n "$KEY_FILE_CT" ]]; then
  pct exec "$CTID" -- env \
    "DSH_API_KEY_FILE=${KEY_FILE_CT}" \
    "DSH_VERSION=${DSH_VERSION}" \
    bash "/tmp/${INNER_FILE}" "$PUBLIC_PORT" "$DSH_PORT" 2>&1 | tee "$HOST_LOG"
else
  pct exec "$CTID" -- env \
    "DSH_VERSION=${DSH_VERSION}" \
    bash "/tmp/${INNER_FILE}" "$PUBLIC_PORT" "$DSH_PORT" 2>&1 | tee "$HOST_LOG"
fi

# ──────────────────────────── 7. Abschlussbox ───────────────────────────────
CT_IP="$(pct exec "$CTID" -- hostname -I | tr ' ' '\n' \
  | grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' | grep -v '^127\.' | head -n1 || true)"
# Absoluter Pfad: 'pct exec' hat nicht immer /usr/local/bin im PATH.
WEB_URL="$(pct exec "$CTID" -- /usr/local/bin/dsh-url 2>/dev/null || true)"
# Fallback: der Token-Link steht auch in der Installationsausgabe auf dem Host.
if [[ -z "$WEB_URL" ]]; then
  WEB_URL="$(grep -oE 'https?://[^[:space:]]+\?token=[A-Za-z0-9_-]+' "$HOST_LOG" 2>/dev/null | tail -n1 || true)"
fi

echo ""
echo -e "${GN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}"
echo -e "${GN} ${APP_NAME} erfolgreich installiert!${CL}"
echo -e "${GN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}"
echo -e " ${YW}Web UI:${CL}      http://${CT_IP}:${PUBLIC_PORT}"
if [[ -n "$WEB_URL" ]]; then
  echo -e " ${YW}Jetzt öffnen:${CL} ${WEB_URL}"
else
  echo -e " ${YW}Jetzt öffnen:${CL} pct exec ${CTID} -- /usr/local/bin/dsh-url"
fi
echo -e "                  ${BL}URL mit ?token=... öffnen – ohne Token erscheint 'authentication required'.${CL}"
echo -e "                  Einmal-Login; danach gilt das Cookie 30 Tage."
echo -e " ${YW}Neuer Login:${CL} pct exec ${CTID} -- /usr/local/bin/dsh-url"
echo -e " ${YW}Container:${CL}  CTID ${CTID} (autostart aktiv, reboot-sicher)"
echo -e " ${YW}Services:${CL}   systemctl status ${APP}  ·  systemctl status nginx  (im CT)"
echo -e " ${YW}Logs:${CL}       journalctl -u ${APP} -e (im CT) · ${HOST_LOG} (Host)"
if [[ "$UPDATE_MODE" -eq 0 ]]; then
  echo -e " ${YW}Login-Daten:${CL} /root/${APP}-ct${CTID}.credentials"
fi
echo -e ""
if [[ -n "${DEEPSEEK_API_KEY:-}" ]]; then
  echo -e " ${YW}API-Key:${CL}     hinterlegt (Settings → Models zeigt ihn als konfiguriert)"
else
  echo -e " ${YW}Falls nötig:${CL}   Web UI → Settings → Models → DeepSeek-API-Key"
fi
echo -e " Erste Session: Workspace wählen (z. B. /opt/dsh), dann loslegen."
echo -e " Update = Einzeiler einfach erneut ausführen (idempotent)."
echo -e "${GN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}"
