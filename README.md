# One-click DSMR Reader updates from Home Assistant

Update [DSMR Reader](https://github.com/dsmrreader/dsmr-reader) (the [xirixiz/dsmr-reader-docker](https://github.com/xirixiz/dsmr-reader-docker) image) running in Docker on a NAS with a single tap on a Home Assistant dashboard card, safely.

Every update:

1. makes a `pg_dump` of the database and checks it is complete before anything else happens
2. backs up `docker-compose.yml`
3. pulls only the DSMR Reader image (your PostgreSQL image is left alone)
4. restarts the stack with `docker compose down` / `up -d` (never `down -v`)
5. waits until DSMR Reader has stored a **new telegram** after the restart and the web UI answers
6. only then prunes the old image, so a rollback stays possible if something goes wrong

Home Assistant shows the current and latest version, an UPDATE and a REFRESH button, and sends a notification when an update fails or when no fresh readings arrive afterwards.

The full story behind this setup, including the things that went wrong along the way, is on my blog: [One-Click DSMR Reader Update on QNAP from Home Assistant](https://rutg3r.com/dsmr-reader-update-home-assistant-qnap/).

## How it fits together

```
Home Assistant card ──UPDATE──> script.proxmox_update_dsmr
        ▲                              │ shell_command (SSH)
        │ MQTT dsmr/ha-update/*        ▼
        └──────────────────── Proxmox /opt/scripts/update-dsmr.sh
                                       │ SSH
                                       ▼
                              NAS: docker compose (dsmr + dsmrdb)
```

* The scripts run on a Linux host that Home Assistant can reach over SSH (in my case the Proxmox host). That host connects to the NAS over SSH.
* `dsmr-update-check.sh` compares the image digest of the running container with the `latest` tag in the registry and publishes the result to MQTT. It runs from cron and from the REFRESH button.
* `update-dsmr.sh` does the actual update and publishes its progress as JSON to `dsmr/ha-update/update_status`.

## Repository layout

| Path | What it is |
|---|---|
| `proxmox/dsmr-common.sh` | Shared helpers: SSH to the NAS, MQTT publish, registry digest and version lookup |
| `proxmox/dsmr-update-check.sh` | Checks for a new image, publishes `update_available`, `current_version`, `latest_version`, `last_check` |
| `proxmox/update-dsmr.sh` | Backup, pull, restart, verify, cleanup |
| `proxmox/dsmr-update.conf.example` | All settings in one place |
| `homeassistant/mqtt_sensors.yaml` | The five MQTT sensors |
| `homeassistant/shell_commands.yaml` | `proxmox_check_dsmr` and `proxmox_update_dsmr` |
| `homeassistant/input_boolean.yaml` | `input_boolean.dsmr_update_running` |
| `homeassistant/script_proxmox_update_dsmr.yaml` | The script behind the UPDATE button |
| `homeassistant/dashboard/button_card_templates.yaml` | `update_panel`, `pill_button` and `app_update` button-card templates |
| `homeassistant/dashboard/dsmr_card.yaml` | The DSMR Reader card |
| `qnap/docker-compose.example.yml` | Example stack, including the mount for DSMR Reader's own backups |

## Requirements

* DSMR Reader + PostgreSQL in Docker Compose on a NAS (written for QNAP Container Station, should work on any Docker host with `sh`)
* A Linux host for the scripts with `bash`, `curl`, `jq`, `mosquitto-clients` and `flock` (plus `sshpass` if you use a password instead of an SSH key)
* Home Assistant with MQTT and the custom [button-card](https://github.com/custom-cards/button-card)

Check the tools on the script host:

```bash
for c in curl jq mosquitto_pub sshpass flock; do command -v $c >/dev/null && echo "OK       $c" || echo "MISSING  $c"; done
apt install -y curl jq mosquitto-clients sshpass
```

## Installation

### 1. Scripts

```bash
mkdir -p /opt/scripts
cp proxmox/*.sh /opt/scripts/
cp proxmox/dsmr-update.conf.example /opt/scripts/dsmr-update.conf
chmod +x /opt/scripts/dsmr-*.sh /opt/scripts/update-dsmr.sh
chmod 600 /opt/scripts/dsmr-update.conf
nano /opt/scripts/dsmr-update.conf
```

Set at least the NAS host and user, `COMPOSE_DIR`, `DSMR_SERVICE` and the MQTT broker. `DSMR_SERVICE` is the compose **service** name, which is not always the container name. Look at the SERVICE column of `docker compose ps` in the compose folder on the NAS.

Test the SSH connection and Docker access from the script host:

```bash
source /opt/scripts/dsmr-common.sh
qnap_run 'id; $DC ps'
```

Then run the first check:

```bash
/opt/scripts/dsmr-update-check.sh
```

It should end with a line like `image=ghcr.io/xirixiz/dsmr-reader-docker:latest current=6.2.0 latest=6.2.2 update_available=true`.

Add the check to cron (`crontab -e`):

```
17 */6 * * * /opt/scripts/dsmr-update-check.sh >>/var/log/dsmr-update-check.log 2>&1
```

### 2. Home Assistant

1. Add the sensors from `homeassistant/mqtt_sensors.yaml` to the `sensor:` list of your MQTT configuration and reload MQTT.
2. Add the shell commands from `homeassistant/shell_commands.yaml` (change the key path and IP) and restart Home Assistant.
3. Create `input_boolean.dsmr_update_running` (UI helper or `homeassistant/input_boolean.yaml`).
4. Create the script from `homeassistant/script_proxmox_update_dsmr.yaml`.
5. Add the templates from `homeassistant/dashboard/button_card_templates.yaml` to your dashboard's raw configuration, then add the card from `homeassistant/dashboard/dsmr_card.yaml`.

Click REFRESH on the card. The versions should appear within a few seconds.

### 3. First update

Watch the log on the script host while you press UPDATE:

```bash
tail -f /var/log/update-dsmr.log
```

## DSMR Reader's own backups

DSMR Reader has a built-in daily backup that writes to `/app/backups` inside the container. In the xirixiz image that folder does not exist and the application runs as the user `app` (uid 1000), which cannot create it in the root-owned `/app`. You'll see this in the container log:

```
(PermissionError) dsmr_backup.services.backup.run errored: [Errno 13] Permission denied: '/app/backups'
```

Fix it with a bind mount to a folder on the NAS (see `qnap/docker-compose.example.yml`) and give it to the container user once:

```bash
docker compose up -d dsmr
docker exec -u 0 dsmr chown -R app:app /app/backups
docker exec -u app dsmr sh -c 'touch /app/backups/.t && rm /app/backups/.t && echo "WRITE OK"'
```

Running `chown` through `docker exec -u 0` also works when your SSH user on the NAS is not root. Leave the storage folder in DSMR Reader's backup configuration at the default `backups/`.

Keep the pre-update dumps (`BACKUP_DIR`) in a different folder than `/app/backups`: that folder belongs to uid 1000, and the SSH user of the scripts needs to write and clean up its own files.

## Troubleshooting

| Symptom | Cause |
|---|---|
| `container for service dsmr-reader not found` | `DSMR_SERVICE` doesn't match the compose service name |
| REFRESH does nothing, `/bin/sh: can't open ...` | A placeholder like `<proxmox-ip>` is still in the shell command. Call the shell_command with a response to see stderr |
| `Invalid config for 'binary_sensor' ... got 'timestamp'` | The MQTT sensors were added under `binary_sensor:` instead of `sensor:` |
| `latest_version` shows a date instead of a version | The registry lookup failed and the script fell back to the GitHub release tag. Run the check by hand and look at the error |
| Update reports `failed` after 5 minutes | No new telegram after the restart, or the web UI didn't answer on `DSMR_URL`. The old image is kept; the message contains the rollback command |
| `docker-compose.yml` edit by script does nothing | The file has Windows line endings (`cat -A` shows `^M$`). Convert with `sed -i 's/\r$//' docker-compose.yml` |

## Notes

* The verification compares the timestamp of the newest reading with the restart time. That timestamp comes from the smart meter's own clock, which can be off by a minute. Home Assistant's own check on `sensor.dsmr_reading_timestamp` covers that.
* The scripts never run `docker compose down -v`.
* Use at your own risk, and keep a backup of your DSMR database somewhere other than the NAS too.

## License

MIT
