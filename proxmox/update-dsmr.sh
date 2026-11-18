#!/usr/bin/env bash
# /opt/scripts/update-dsmr.sh
# Updates DSMR Reader (Container Station on the QNAP) and verifies it afterwards.
#   1. pg_dump backup of the database to $BACKUP_DIR (verified, gzipped, last $BACKUP_KEEP kept)
#   2. backup of docker-compose.yml (next to it + a copy in $BACKUP_DIR)
#   3. docker compose pull ($PULL_SERVICES)
#   4. docker compose down + up -d          (NEVER down -v: that wipes the DB volume)
#   5. verify: container running, migrations without errors, a NEW telegram stored
#      after the restart, web UI answering. Only then: docker image prune -f
# Progress/result -> MQTT $MQTT_BASE/update_status (JSON), log -> /var/log/update-dsmr.log
# Usage: update-dsmr.sh [--force]   (--force restarts even if no new image was pulled)
set -uo pipefail
source "$(dirname "$(readlink -f "$0")")/dsmr-common.sh"
SELF_DIR=$(dirname "$(readlink -f "$0")")
FORCE=0; [[ ${1:-} == --force ]] && FORCE=1

LOG=/var/log/update-dsmr.log
exec >>"$LOG" 2>&1
exec 9>/run/lock/update-dsmr.lock
flock -n 9 || { log "Another DSMR update is running, exiting."; exit 0; }

# shellcheck disable=SC2034  # used by qnap_run in dsmr-common.sh
STAMP=$(date +%Y%m%d_%H%M%S)
log "===== DSMR update started ====="
publish_status running "Update started"

fail() {
  log "FAILED: $1"
  publish_status failed "$1" --arg backup "${BACKUP:-}"
  "$SELF_DIR/dsmr-update-check.sh" || true
  log "===== DSMR update finished with errors ====="
  exit 1
}

# --- 1+2. Backups -----------------------------------------------------------------
publish_status running "Backing up database"
out=$(qnap_run "$(cat <<'R'
mkdir -p "$BDIR" || { echo "ERR cannot create $BDIR"; exit 1; }
f="$BDIR/dsmr_backup_$STAMP.sql"
if ! docker exec "$DBC" pg_dump -U "$DBU" "$DBN" > "$f" 2>"$f.err"; then
  echo "ERR pg_dump failed: $(head -c 300 "$f.err")"; rm -f "$f" "$f.err"; exit 1
fi
rm -f "$f.err"
tail -c 400 "$f" | grep -q 'PostgreSQL database dump complete' || { echo "ERR dump incomplete"; exit 1; }
gzip -f "$f" || { echo "ERR gzip failed"; exit 1; }
cp docker-compose.yml docker-compose.yml.bak || { echo "ERR compose backup failed"; exit 1; }
cp docker-compose.yml "$BDIR/docker-compose_$STAMP.yml"
n=0
for old in $(ls -1t "$BDIR"/dsmr_backup_*.sql.gz 2>/dev/null); do
  n=$((n+1)); [ "$n" -gt "$KEEP" ] && rm -f "$old"
done
echo "backup=$(cd "$(dirname "$f")" && pwd)/$(basename "$f").gz"
echo "size_kb=$(du -k "$f.gz" | cut -f1)"
R
)")
rc=$?; echo "$out"
BACKUP=$(kv backup "$out")
(( rc == 0 )) && [[ -n $BACKUP ]] || fail "Backup failed: $(grep -m1 '^ERR' <<<"$out" || echo "SSH rc=$rc")"
log "Backup OK: $BACKUP ($(kv size_kb "$out") KB)"

# --- 3. Pull ------------------------------------------------------------------------
publish_status running "Pulling new image" --arg backup "$BACKUP"
out=$(qnap_run "$(cat <<'R'
cid=$($DC ps -q "$DSVC" | head -n1)
[ -n "$cid" ] || { echo "ERR container for $DSVC not found"; exit 1; }
img=$(docker inspect -f '{{.Config.Image}}' "$cid")
echo "img=$img"
echo "old=$(docker inspect -f '{{.Image}}' "$cid")"
$DC pull $PULL 2>&1 | tail -n 20 | sed 's/^/pull: /'
echo "new=$(docker image inspect -f '{{.Id}}' "$img")"
R
)")
rc=$?; echo "$out"
IMG=$(kv img "$out"); OLD=$(kv old "$out"); NEW=$(kv new "$out")
(( rc == 0 )) && [[ -n $NEW ]] || fail "Pull failed: $(grep -m1 '^ERR' <<<"$out" || echo "SSH rc=$rc")"

if [[ $NEW == "$OLD" && $FORCE -eq 0 ]]; then
  log "No new image pulled ($IMG) - nothing to restart."
  publish_status ok "Already up to date, no restart needed" --arg backup "$BACKUP"
  "$SELF_DIR/dsmr-update-check.sh"
  log "===== DSMR update finished (no change) ====="
  exit 0
fi
log "New image: ${OLD:7:12} -> ${NEW:7:12}"

# --- 4. Restart stack -----------------------------------------------------------------
publish_status running "Restarting containers" --arg backup "$BACKUP"
RESTART=$(date +%s)
out=$(qnap_run "$(cat <<'R'
$DC down 2>&1 | sed 's/^/down: /'
o=$($DC up -d 2>&1); r=$?
echo "$o" | sed 's/^/up: /'
echo "rc_up=$r"
R
)")
echo "$out"
[[ $(kv rc_up "$out") == 0 ]] || fail "docker compose up -d failed. Rollback: docker tag $OLD $IMG && docker compose up -d"

# --- 5. Verify --------------------------------------------------------------------------
publish_status running "Waiting for migrations and a new telegram" --arg backup "$BACKUP"
deadline=$((RESTART + ${VERIFY_TIMEOUT:-300}))
ok=0; last=""; state=""; http="skipped"
while (( $(date +%s) < deadline )); do
  sleep 15
  out=$(qnap_run "$(cat <<'R'
cid=$($DC ps -q "$DSVC" | head -n1)
echo "state=$(docker inspect -f '{{.State.Status}}' "$cid" 2>/dev/null)"
echo "restarts=$(docker inspect -f '{{.RestartCount}}' "$cid" 2>/dev/null)"
echo "last=$(docker exec -w "$APPDIR" "$cid" python3 manage.py shell -c "from dsmr_datalogger.models.reading import DsmrReading as R; r=R.objects.order_by('-timestamp').first(); print(r.timestamp.isoformat() if r else '')" 2>/dev/null | tail -n1)"
R
)")
  state=$(kv state "$out"); last=$(kv last "$out")
  last_s=$(date -d "$last" +%s 2>/dev/null || echo 0)
  log "verify: state=$state restarts=$(kv restarts "$out") last_reading=${last:-none}"
  [[ $state == running ]] || continue
  (( last_s > RESTART )) || continue
  if [[ -n ${DSMR_URL:-} ]]; then
    http=$(curl -s -o /dev/null -m 10 -w '%{http_code}' "$DSMR_URL")
    [[ $http =~ ^(200|301|302)$ ]] || { log "verify: web UI returned $http"; continue; }
  fi
  ok=1; break
done

if (( ok == 0 )); then
  fail "No healthy DSMR Reader within ${VERIFY_TIMEOUT:-300}s (state=${state:-?}, last reading=${last:-none}, http=$http). Old image kept for rollback: docker tag $OLD $IMG && docker compose up -d. DB backup: $BACKUP"
fi

# Migration / error scan of the log since the restart
out=$(qnap_run "$(cat <<'R'
$DC logs --no-color --since 15m "$DSVC" 2>&1 | grep -E 'Applying |Traceback|ERROR|CRITICAL|django\.db\.utils' | tail -n 30
R
)")
echo "$out" | sed 's/^/log: /'
errors=$(grep -cE 'Traceback|ERROR|CRITICAL|django\.db\.utils' <<<"$out" || true)
migr=$(grep -c 'Applying ' <<<"$out" || true)

# --- Cleanup (only after a verified start, so the old image stays available until now) ---
qnap_run 'docker image prune -f 2>&1 | tail -n 1' | sed 's/^/prune: /'

msg="Updated, new telegram at $(date -d "$last" '+%H:%M:%S'), $migr migration(s) applied"
(( errors > 0 )) && msg="$msg, $errors error line(s) in log - check /var/log/update-dsmr.log"
publish_status ok "$msg" --arg backup "$BACKUP" --arg last_reading "$last" \
  --arg migrations "$migr" --arg log_errors "$errors"
"$SELF_DIR/dsmr-update-check.sh"
log "$msg"
log "===== DSMR update finished ====="
