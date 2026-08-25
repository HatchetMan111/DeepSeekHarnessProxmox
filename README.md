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
| `CORES`         | `2`        | vCPUs                                            |
| `MEM_MB`        | `2048`     | RAM in MB                                        |
| `SWAP_MB`       | `512`      | Swap                                             |
| `DISK_GB`       | `8`        | Rootfs-Größe                                     |
| `STORAGE`       | `auto`     | Storage fürs Rootfs (`auto` = erste aktive)      |
| `VZTMP_STORAGE` | `local`    | Storage für das Debian-Template                  |
| `NET_BRIDGE`    | `vmbr0`    | Netzwerk-Bridge                                  |
| `PUBLIC_PORT`   | `8080`     | Externer Port der Web UI                         |
| `DSH_PORT`      | `3080`     | Interner dsh-Port (nur localhost)                |

### Was das Script macht

1. Legt einen **unprivilegierten Debian-12-LXC** an (`nesting=1` für die bwrap-Sandbox von dsh,
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
2. **Settings → Models**: DeepSeek-API-Key hinterlegen ([platform.deepseek.com](https://platform.deepseek.com)) –
   wird lokal in `$DSH_HOME/.credentials.yaml` gespeichert; alternativ funktionieren auch eigene
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
| Service down | `pct exec <CTID> -- journalctl -u dsh -e` |
| Proxy-Fehler | `pct exec <CTID> -- tail -n50 /var/log/nginx/error.log` |
| Alles verfolgen | Einzeiler mit Debug-Ausgabe: `bash -x <(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/DeepSeekHarnessProxmox/main/install/dsh.sh)` |

Hinweis zur Erreichbarkeit: `dsh web` lauscht absichtlich nur auf `127.0.0.1`; deshalb läuft vor
ihm ein nginx. Greifst du über eine neue Adresse (z. B. geänderte CT-IP oder DNS-Name) zu und die
UI lädt, aber API-Calls scheitern, ergänze die Autorität in `/usr/local/bin/dsh-start.sh`
(`--trusted-host "<host>:8080"`) und starte neu: `systemctl restart dsh`.

## Screenshots

<!-- Platzhalter -->
![Web UI](docs/screenshot-webui.png)

## Lizenz

MIT – siehe [LICENSE](LICENSE). DeepSeek Harness selbst: MIT
([Upstream-Repo](https://github.com/deepseek-ai/deepseek-harness)).
