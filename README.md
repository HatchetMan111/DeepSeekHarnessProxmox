# DeepSeek Harness – Proxmox LXC Installer

[DeepSeek Harness (`dsh`)](https://github.com/deepseek-ai/deepseek-harness) – der Open-Source-Agent-Harness
(„Everything is a Plugin") mit Web UI – als **LXC-Container auf Proxmox VE**, installierbar mit einem
Einzeiler im Stil der [Proxmox VE Community Scripts](https://community-scripts.github.io/ProxmoxVE).

- Vollständig lokal: Agent, Sessions und Credentials bleiben im Container (Telemetrie ist default-off)
- Web UI unter `http://<CT-IP>:8080`
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

| Variable        | Standard   | Bedeutung                                        |
|-----------------|------------|--------------------------------------------------|
| `CTID`          | nächste freie | Proxmox-Container-ID                          |
| `HOST_NAME`     | `DeepSeekHarness` | Hostname des Containers                   |
| `CORES`         | `2`        | vCPUs                                            |
| `MEM_MB`        | `2048`     | RAM in MB                                        |
| `SWAP_MB`       | `512`      | Swap                                             |
| `DISK_GB`       | `8`        | Rootfs-Größe                                     |
| `STORAGE`       | `auto`     | Storage fürs Rootfs (`auto` = erste aktive)      |
| `VZTMP_STORAGE` | `local`    | Storage für das Debian-Template                  |
| `NET_BRIDGE`    | `vmbr0`    | Netzwerk-Bridge                                  |
| `PUBLIC_PORT`   | `8080`     | Externer Port der Web UI                         |
| `DSH_PORT`      | `3080`     | Interner dsh-Port (nur localhost)                |

### API-Key direkt bei der Installation

Der Installer fragt bei interaktivem Lauf **optional nach dem DeepSeek-API-Key** und
hinterlegt ihn direkt im Container (`/var/lib/dsh/.credentials.yaml`, Modus 600) –
die Web UI zeigt den Provider dann sofort als konfiguriert, ganz ohne Settings-Eingabe.
Nur mit Enter bestätigen = überspringen.

Für Automatisierung/Unattended per Umgebungsvariable:

```bash
DEEPSEEK_API_KEY=sk-... bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/DeepSeekHarnessProxmox/main/install/dsh.sh)"
```

Nach der Installation prüft der Installer selbst per RPC
(`credentials.describe` → `configured: true`), dass der Key aktiv ist.

### Was das Script macht

1. Legt einen **unprivilegierten Debian-12-LXC** an (Hostname standardmäßig `DeepSeekHarness`,
   `nesting=1` für die bwrap-Sandbox von dsh,
   `onboot=1`, DHCP an `vmbr0`) – existiert die CT-ID schon, wird stattdessen **aktualisiert**
2. Installiert im CT: nginx, bubblewrap, **Node.js 22 LTS** und das npm-Paket `@deepseek-ai/dsh`
3. Startet `dsh web --no-open` als Service-Benutzer `dsh` **nur auf 127.0.0.1:3080**
   (dsh unterstützt bewusst kein `0.0.0.0`) → ein lokaler **nginx-Reverse-Proxy** stellt die
   Web UI auf `0.0.0.0:8080` bereit (inkl. WebSocket-/SSE-Support)
4. Aktiviert systemd-Services mit `enable` + `Restart=always` + `After=network-online.target`
5. Verifiziert sich selbst: `systemctl is-active`, HTTP-Check auf `localhost:8080`,
   Socket-Check – dann Ausgabe der finalen URL inkl. Container-IP

Root-Passwort des neuen Containers liegt nach dem ersten Lauf in `/root/dsh-ct<CTID>.credentials`.

## Nach der Installation

1. `http://<CT-IP>:8080` öffnen
2. **Workspace wählen** (z. B. `/opt/dsh`) – Session-Composer braucht einen Workspace
3. API-Key: bei Installer-Eingabe bereits hinterlegt (s. o.); sonst nachträglich unter
   **Settings → Models** ([platform.deepseek.com](https://platform.deepseek.com)) –
   wird lokal in `/var/lib/dsh/.credentials.yaml` gespeichert; alternativ funktionieren auch eigene
   OpenAI-kompatible Endpunkte (siehe dsh-Doku)
3. **Choose workspace**: Arbeitsverzeichnis wählen (Default-Workspace-Root im Container: `/opt/dsh`)

## Update

Einfach den **Einzeiler erneut ausführen** – er ist idempotent und aktualisiert
Node-Pakete, Konfigurationen und Services. Oder nur die App im CT aktualisieren:

```bash
pct exec <CTID> -- bash -c "npm install -g @deepseek-ai/dsh && systemctl restart dsh"
```

## Deinstallation

```bash
pct stop <CTID> && pct destroy <CTID>        # Container inkl. Daten entfernen
rm -f /root/dsh-ct<CTID>.credentials         # Login-Notiz auf dem Host
```

Mehr passiert nicht – der Host bleibt unverändert.

## Reboot-Verhalten / dokumentierter Testablauf

Container (`onboot: 1`), `dsh.service` und `nginx.service` starten automatisch. Testablauf:

```bash
pct reboot <CTID>
sleep 30
pct exec <CTID> -- systemctl is-active dsh nginx   # → active / active
pct exec <CTID> -- curl -fsSI http://localhost:8080 | head -n1   # → HTTP/1.1 200 OK
# danach http://<CT-IP>:8080 im Browser prüfen
```

Erwartung nach Neustart: beide Services `active`, HTTP 200, Web UI erreichbar.

## Troubleshooting

| Symptom | Wo schauen |
|---|---|
| Installer bricht ab | Komplette Fehlerkette wird ausgegeben (Exit-Code, Zeile, Befehl, Log-Tail); Host-Log: `/tmp/dsh-install-*.log` |
| `crypto.randomUUID is not a function` (z. B. „Could not load agent presets") | Behoben durch den Installer: nginx injiziert ein Polyfill in die Web-UI-HTML (die API existiert im Browser nur unter HTTPS/localhost). Prüfen: `curl -s http://localhost:8080 \| grep -c randomUUID` → muss ≥ 1 sein; danach Browser-Cache leeren (Strg+Umschalt+R) |
| `HTTP 403` bei API-Calls (z. B. „transport failure for /api/...: HTTP 403") | Behoben durch den Installer: nginx reicht den vollen `Host`-Header durch (`$http_host`) und der Start-Wrapper trägt alle IPv4-Adressen **port-los** als `--trusted-host` ein (dsh-Fence verlangt sonst exakte `host:port`-Matches). Prüfen: `pct exec <CTID> -- ps auxw \| grep 'dsh web'` zeigt die Flags; nach Installer-Rerun Browser-Cache leeren |
| „settings are unavailable in this browser" / Models-Auswahl lädt nicht | Behoben durch den Installer: dsh pinnt die Konfigurations-Ebene (Settings/Credentials/Presets/Workspace-Wahl) hart auf Loopback – der `/api/`-Proxy-Block stellt Requests deshalb aus Sicht von dsh lokal dar. Prüfen: `curl -s -o /dev/null -w '%{http_code}' -X POST -H "Host: $(hostname -I\|awk '{print $1}'):8080" -H "Origin: http://$(hostname -I\|awk '{print $1}'):8080" http://localhost:8080/api/settings.describe` → muss `200` sein |
| Service down | `pct exec <CTID> -- journalctl -u dsh -e` |
| Proxy-Fehler | `pct exec <CTID> -- tail -n50 /var/log/nginx/error.log` |
| Alles verfolgen | Einzeiler mit Debug-Ausgabe: `bash -x <(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/DeepSeekHarnessProxmox/main/install/dsh.sh)` |

Sauberere Alternative zum Polyfill (echter Secure Context): selbstsigniertes HTTPS aktivieren –

```bash
pct exec <CTID> -- bash -c "openssl req -x509 -nodes -newkey rsa:2048 -days 825 \
  -keyout /etc/nginx/ssl-dsh.key -out /etc/nginx/ssl-dsh.crt \
  -subj '/CN=DeepSeekHarness' && sed -i 's/listen 0.0.0.0:8080;/listen 0.0.0.0:8080 ssl;/; s/listen \[::\]:8080;/listen [::]:8080 ssl;/; s|proxy_pass http://127.0.0.1:3080;|ssl_certificate /etc/nginx/ssl-dsh.crt; ssl_certificate_key /etc/nginx/ssl-dsh.key;\n  proxy_pass http://127.0.0.1:3080;|' /etc/nginx/sites-available/dsh.conf && nginx -t && systemctl restart nginx"
# dann https://<CT-IP>:8080 (Browser-Warnung wegen selbstsigniertem Zertifikat bestätigen)
```

Container umbenennen (nur bei bereits bestehenden Installationen nötig – Neuinstallationen
heißen automatisch `DeepSeekHarness`):

```bash
pct set <CTID> --hostname DeepSeekHarness && pct reboot <CTID>
```

Hinweis zur Erreichbarkeit: `dsh web` lauscht absichtlich nur auf `127.0.0.1`; deshalb läuft vor
ihm ein nginx. Greifst du über eine neue Adresse (z. B. geänderte CT-IP oder DNS-Name) zu und die
UI lädt, aber API-Calls scheitern, ergänze die Autorität in `/usr/local/bin/dsh-start.sh`
(`--trusted-host "<host>:8080"`) und starte neu: `systemctl restart dsh`.

## Screenshots

<!-- Platzhalter -->
![Web UI](docs/screenshot-webui.png)

## Sicherheit / Netzwerkfreigabe

dsh ist als *lokale* Einzelbenutzer-App konzipiert: die Konfigurations-Ebene
(Settings, Credentials, Presets, Workspace-Wahl) darf nur vom selben Rechner
(Loopback) kommen – als Schutz gegen DNS-Rebinding/Cross-Site-Angriffe aus dem
Browser, **nicht** als Authentifizierung. Da der Container per Definition remote
genutzt wird, stellt der Installer diese Ebene über den `/api/`-Proxy-Block
bereit. Der Schutz wird dabei nicht einfach abgeschaltet, sondern in nginx
verlagert: Nur Anfragen mit `Origin` dieser Maschine (Container-IP, localhost,
Hostname – siehe `/etc/nginx/conf.d/dsh-origin.conf`, wird bei jedem
Service-Start neu gerendert) werden akzeptiert; alles andere → 403.

Konsequenzen:

- **Vertrauenswürdiges Heim-LAN voraussetzen**: Wer im LAN ist, kann ohnehin
  den Agent steuern (Kommandos ausführen); die Settings-Ebene ändert daran
  nichts Grundsätzliches – aber es gibt kein Login/Passwort für die Web UI.
- Fremde Netze/Gast-WLANs: Container nicht freigeben (PVE-Firewall oder UFW).
- Zur Rücksetzung des Upstream-Standarts: `location /api/ { … }`-Block in
  `/etc/nginx/sites-available/dsh.conf` entfernen und `nginx -s reload`.

## Lizenz

MIT – siehe [LICENSE](LICENSE). DeepSeek Harness selbst: MIT
([Upstream-Repo](https://github.com/deepseek-ai/deepseek-harness)).
