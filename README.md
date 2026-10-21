# DeepSeek Harness – Proxmox LXC Installer

[DeepSeek Harness (`dsh`)](https://github.com/deepseek-ai/deepseek-harness) – der Open-Source-Agent-Harness
(„Everything is a Plugin") mit Web UI – als **LXC-Container auf Proxmox VE**, installierbar mit einem
Einzeiler im Stil der [Proxmox VE Community Scripts](https://community-scripts.github.io/ProxmoxVE).

- Vollständig lokal: Agent, Sessions und Credentials bleiben im Container (Telemetrie ist default-off)
- Web UI unter `http://<CT-IP>:8080` – Login per Token-Link, danach 30 Tage Cookie
- DeepSeek-API-Key kann **direkt bei der Installation** hinterlegt werden
- Reboot-sicher durch systemd (`Restart=always`) + `onboot=1`
- Idempotent: erneutes Ausführen = Update

---

## Der Einzeiler

Auf der **Proxmox-Host-Shell** (root) ausführen:

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/DeepSeekHarnessProxmox/main/install/dsh.sh)"
```

Mit eigener CT-ID bzw. angepassten Ressourcen:

```bash
CTID=150 CORES=4 MEM_MB=4096 DISK_GB=16 \
  bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/DeepSeekHarnessProxmox/main/install/dsh.sh)"
```

### Variablen (alle optional)

| Variable        | Standard          | Bedeutung                                        |
|-----------------|-------------------|--------------------------------------------------|
| `CTID`          | nächste freie     | Proxmox-Container-ID                             |
| `HOST_NAME`     | `DeepSeekHarness` | Hostname des Containers                          |
| `CORES`         | `2`               | vCPUs                                            |
| `MEM_MB`        | `4096`            | RAM in MB                                        |
| `SWAP_MB`       | `1024`            | Swap                                             |
| `DISK_GB`       | `16`              | Rootfs-Größe                                     |
| `STORAGE`       | `auto`            | Storage fürs Rootfs (`auto` = erste aktive)      |
| `VZTMP_STORAGE` | `local`           | Storage für das Debian-Template                  |
| `NET_BRIDGE`    | `vmbr0`           | Netzwerk-Bridge                                  |
| `PUBLIC_PORT`   | `8080`            | Externer Port der Web UI                         |
| `DSH_PORT`      | `3080`            | Interner dsh-Port (nur localhost)                |
| `DSH_VERSION`   | `0.2.1-rc.2`      | Getestete dsh-Version (`latest` = immer updaten) |

### API-Key direkt bei der Installation

Der Installer fragt bei interaktivem Lauf **optional nach dem DeepSeek-API-Key** und
hinterlegt ihn direkt im Container (`/var/lib/dsh/.credentials.yaml`, Modus 600).
Die Web UI zeigt den Provider dann sofort als konfiguriert – ganz ohne Settings-Eingabe.
Nur mit Enter bestätigen = überspringen.

Die Abfrage funktioniert auch bei `curl ... | bash`, weil sie über `/dev/tty` liest.
Für Automatisierung/Unattended per Umgebungsvariable:

```bash
DEEPSEEK_API_KEY=sk-... bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/DeepSeekHarnessProxmox/main/install/dsh.sh)"
```

Der Key wird **nicht** als Kommandozeilenargument übergeben, sondern per Datei in den
Container gepusht und dort sofort gelöscht. Nach der Installation prüft der Installer
per RPC (`credentials/describe` → `configured: true`) und – wenn das Internet es zulässt –
zusätzlich nicht-fatal gegen `https://api.deepseek.com/models`.

---

## Was das Script macht

1. Legt einen **unprivilegierten Debian-12-LXC** an (Hostname standardmäßig `DeepSeekHarness`,
   `nesting=1` für die bwrap-Sandbox von dsh, `onboot=1`, DHCP an `vmbr0`) – existiert die
   CT-ID schon, wird stattdessen **aktualisiert**
2. Installiert im CT: nginx, bubblewrap, **Node.js ≥ 20 (standardmäßig 22 LTS)** und das npm-Paket
   `@deepseek-ai/dsh` in der getesteten Version
3. Startet `dsh web --no-open` als Service-Benutzer `dsh` **nur auf 127.0.0.1:3080**.
   nginx stellt die Web UI auf `0.0.0.0:8080` bereit und reicht **Host, Origin, Cookies
   und WebSockets unverändert** durch – die Authentifizierung bleibt vollständig bei dsh
4. Aktiviert systemd-Services mit `enable` + `Restart=always` + `After=network-online.target`
5. Verifiziert sich selbst:
   - Token-Exchange (`303`) und Login-Cookie (`200`)
   - `randomUUID`-Polyfill für HTTP-Zugriff ohne HTTPS
   - fremder `Origin` → `403`, unauthentifizierte API → `401`
   - optional: API-Key via `credentials/describe` als `configured: true`
6. Gibt am Ende den **Token-Link** aus, mit dem die Web UI sofort nutzbar ist

Root-Passwort des neuen Containers liegt nach dem ersten Lauf in `/root/dsh-ct<CTID>.credentials`.

---

## Nach der Installation

1. Den **Token-Link** aus der Abschlussausgabe öffnen, z. B.
   `http://192.168.1.50:8080/?token=...`
2. Danach ist man eingeloggt; das Cookie gilt **30 Tage**. Die normale URL
   `http://<CT-IP>:8080` funktioniert anschließend ohne Token.
3. **Workspace wählen** (im Container z. B. `/opt/dsh`)
4. Ohne Key bei der Installation: **Settings → Models** → DeepSeek-API-Key eintragen
   ([platform.deepseek.com](https://platform.deepseek.com))

### Login / Token erneut holen

`dsh` erzeugt bei **jedem Start** einen neuen Launch-Token. Ein neuer Browser (oder ein
abgelaufenes Cookie) braucht deshalb einen frischen Token-Link:

```bash
pct exec <CTID> -- /usr/local/bin/dsh-url
```

Der Befehl liest den aktuellen Link aus dem Journal. Der Link ist ein Bearer-Login –
nicht öffentlich posten. `dsh-url` ist im Container nur für root ausführbar.

---

## Update

Einfach den **Einzeiler erneut ausführen** – er ist idempotent und aktualisiert
Konfiguration, Services und (je nach `DSH_VERSION`) die App. Oder nur die App im CT:

```bash
pct exec <CTID> -- bash -c \
  "npm install -g @deepseek-ai/dsh@0.2.1-rc.2 && systemctl restart dsh"
```

Nach einem Update/Neustart bleibt ein bestehendes Browser-Cookie gültig. Ein **neuer**
Browser braucht wieder `dsh-url`. Ressourcen eines bestehenden Containers werden nicht
automatisch vergrößert – dafür `pct set <CTID> --memory ... --rootfs ...` nutzen.

### IP-Adresse geändert?

Der Start-Wrapper liest die Container-IP bei jedem Service-Start neu. Nach einer
DHCP-Änderung deshalb einmal neu starten:

```bash
pct exec <CTID> -- systemctl restart dsh
pct exec <CTID> -- /usr/local/bin/dsh-url
```

Das alte Cookie gilt für die alte IP; für die neue IP braucht man den neuen Token-Link.

---

## Reboot-Verhalten / dokumentierter Testablauf

Container (`onboot: 1`), `dsh.service` und `nginx.service` starten automatisch. Testablauf:

```bash
pct reboot <CTID>
sleep 30
pct exec <CTID> -- systemctl is-active dsh nginx       # → active / active
pct exec <CTID> -- curl -fsS -o /dev/null -w '%{http_code}\n' http://localhost:8080/  # → 401 (ohne Cookie)
pct exec <CTID> -- /usr/local/bin/dsh-url           # → Token-Link für den Browser
```

Erwartung nach Neustart: beide Services `active`, Web UI antwortet (401 ohne Login),
Token-Link über `dsh-url` abrufbar. Ein bereits eingeloggter Browser funktioniert direkt weiter.

---

## Troubleshooting

| Symptom | Wo schauen |
|---|---|
| `pct exec ... dsh-url`: `command not found` | `pct exec <CTID> -- /usr/local/bin/dsh-url` nutzen – `pct exec` hat `/usr/local/bin` nicht immer im PATH. |
| Abschlussbox zeigt keinen Token-Link | Im Host-Log nachsehen: `grep -oE 'https?://[^ ]+\?token=[A-Za-z0-9_-]+' /tmp/dsh-install-*.log \| tail -n1` |
| `401 Unauthorized` in der Web UI | Normale URL ohne Login geöffnet. Token-Link nutzen: `pct exec <CTID> -- /usr/local/bin/dsh-url`. Danach ist 30 Tage Cookie-Login. |
| Neuer Browser / Cookie abgelaufen | `pct exec <CTID> -- /usr/local/bin/dsh-url` – der Token ändert sich bei jedem dsh-Start. |
| Installer bricht ab | Komplette Fehlerkette wird ausgegeben (Exit-Code, Zeile, Befehl, Log-Tail); Host-Log: `/tmp/dsh-install-*.log` |
| `crypto.randomUUID is not a function` (z. B. „Could not load agent presets") | nginx injiziert ein Polyfill in die Web-UI-HTML (die API existiert im Browser nur unter HTTPS/localhost). Prüfen: `curl -s http://localhost:8080 \| grep -c randomUUID` → muss ≥ 1 sein; danach Browser-Cache leeren (Strg+Umschalt+F5) |
| `HTTP 403` bei API-Calls | dsh blockiert fremde `Host`/`Origin`-Kombinationen. Zugriff über die CT-IP oder den Hostnamen; nach IP-Wechsel `systemctl restart dsh`. Prüfen: `journalctl -u dsh -e` |
| `settings are unavailable` / Models-Auswahl lädt nicht | Meist ein 401 (Token/Cookie) oder 403 (Origin). Erst `dsh-url` im selben Browser öffnen, dann Settings erneut laden. |
| API-Key wird nicht erkannt | `pct exec <CTID> -- ls -l /var/lib/dsh/.credentials.yaml` (muss `600 dsh dsh` sein) und `journalctl -u dsh -e`. Key notfalls in **Settings → Models** neu speichern. |
| Service down | `pct exec <CTID> -- journalctl -u dsh -e` |
| Proxy-Fehler | `pct exec <CTID> -- tail -n50 /var/log/nginx/error.log` |
| Alles verfolgen | Einzeiler mit Debug-Ausgabe: `bash -x <(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/DeepSeekHarnessProxmox/main/install/dsh.sh)` |

Container umbenennen (nur bei bereits bestehenden Installationen nötig – Neuinstallationen
heißen automatisch `DeepSeekHarness`):

```bash
pct set <CTID> --hostname DeepSeekHarness && pct reboot <CTID>
```

---

## Sicherheit / Netzwerkfreigabe

dsh ist als *lokale* Einzelbenutzer-App konzipiert und bringt echten Schutz mit:

- Jeder Prozessstart erzeugt einen **Launch-Token**; der Token-Link setzt ein signiertes,
  authority-gebundenes **HttpOnly-Cookie** (`SameSite=Strict`, 30 Tage).
- Jede API- und WebSocket-Anfrage braucht dieses Cookie; ohne Cookie → `401`.
- `Host`/`Origin` werden gegen eine Trust-Liste geprüft (Schutz gegen DNS-Rebinding und
  Cross-Site-Anfragen); fremde Origins → `403`.
- nginx schaltet diesen Schutz **nicht** ab, sondern reicht alles unverändert an dsh durch.

Konsequenzen:

- **Vertrauenswürdiges Heim-LAN voraussetzen**: Wer den Token-Link hat, kann den Agent
  steuern (Kommandos ausführen). Es gibt kein separates Login/Passwort.
- Token-Link wie ein Passwort behandeln; `dsh-url` gibt ihn nur an root aus.
- Fremde Netze/Gast-WLANs: Container nicht freigeben (PVE-Firewall oder UFW).
- Für Zugriff aus unsicheren Netzen: VPN davor. HTTPS kann zusätzlich an nginx terminiert
  werden; dsh selbst sieht dann weiterhin HTTP und setzt kein `Secure`-Flag am Cookie.

---

## Lizenz

MIT – siehe [LICENSE](LICENSE). DeepSeek Harness selbst: MIT
([Upstream-Repo](https://github.com/deepseek-ai/deepseek-harness)).
