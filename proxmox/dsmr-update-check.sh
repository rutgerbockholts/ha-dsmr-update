#!/usr/bin/env bash
# /opt/scripts/dsmr-update-check.sh
# Checks whether a newer DSMR Reader image exists than the one the running
# container uses, and publishes the result (retained) to MQTT for Home Assistant:
#   $MQTT_BASE/update_available  true|false|unknown
#   $MQTT_BASE/current_version   $MQTT_BASE/latest_version   $MQTT_BASE/last_check
# Cron example:  17 */6 * * * /opt/scripts/dsmr-update-check.sh >>/var/log/dsmr-update-check.log 2>&1
set -uo pipefail
source "$(dirname "$(readlink -f "$0")")/dsmr-common.sh"

info=$(qnap_run "$(cat <<'R'
cid=$($DC ps -q "$DSVC" 2>/dev/null | head -n1)
[ -n "$cid" ] || { echo "error=container for service $DSVC not found"; exit 0; }
iid=$(docker inspect -f '{{.Image}}' "$cid")
echo "state=$(docker inspect -f '{{.State.Status}}' "$cid")"
echo "image=$(docker inspect -f '{{.Config.Image}}' "$cid")"
echo "digests=$(docker image inspect -f '{{join .RepoDigests " "}}' "$iid")"
echo "arch=$(docker image inspect -f '{{.Architecture}}' "$iid")"
echo "version=$(docker image inspect -f '{{index .Config.Labels "org.opencontainers.image.version"}}' "$iid" 2>/dev/null)"
echo "source=$(docker image inspect -f '{{index .Config.Labels "org.opencontainers.image.source"}}' "$iid" 2>/dev/null)"
R
)")
rc=$?
now=$(date -Iseconds)
err=$(kv error "$info")
if (( rc != 0 )) || [[ -n $err ]]; then
  log "Check failed (rc=$rc): ${err:-SSH to $QNAP_HOST failed}"
  mqtt_pub update_available unknown
  mqtt_pub last_check "$now"
  exit 1
fi

image=$(kv image "$info"); digests=$(kv digests "$info")
current=$(kv version "$info"); source_url=$(kv source "$info")
[[ $current == "<no value>" || -z $current ]] && current=${digests##*@sha256:} && current=${current:0:12}
[[ $source_url == "<no value>" ]] && source_url=""

remote_digest "$image"; remote=${REMOTE_DIGEST:-}
if [[ -z $remote ]]; then
  log "Could not read registry digest for $image"
  mqtt_pub update_available unknown
  mqtt_pub current_version "$current"
  mqtt_pub last_check "$now"
  exit 1
fi

if [[ " $digests " == *"@$remote "* ]]; then
  avail=false; latest=$current
else
  avail=true; latest="new image"
  rv=$(remote_version "$(kv arch "$info")")
  if [[ -n $rv ]]; then
    latest=$rv
    # same version number but a rebuilt image: make that visible on the card
    [[ $rv == "$current" ]] && latest="$rv (rebuild)"
  elif [[ $source_url =~ github\.com/([^/]+/[^/.]+) ]]; then
    tag=$(curl -sS -m 20 "https://api.github.com/repos/${BASH_REMATCH[1]}/releases/latest" | jq -r '.tag_name // empty')
    [[ -n $tag ]] && latest=$tag
  fi
fi

mqtt_pub update_available "$avail"
mqtt_pub current_version "$current"
mqtt_pub latest_version "$latest"
mqtt_pub last_check "$now"
log "image=$image current=$current latest=$latest update_available=$avail"
