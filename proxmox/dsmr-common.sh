#!/usr/bin/env bash
# /opt/scripts/dsmr-common.sh — shared helpers, sourced by
#   dsmr-update-check.sh and update-dsmr.sh

CONF=${DSMR_CONF:-/opt/scripts/dsmr-update.conf}
[[ -r $CONF ]] || { echo "Missing config $CONF" >&2; exit 1; }
# shellcheck source=/dev/null
source "$CONF"

log() { echo "$(date '+%F %T') $*"; }

# Run a command on the QNAP over SSH (key or sshpass).
qnap_ssh() {
  local opts=(-o ConnectTimeout=10 -o ServerAliveInterval=15 -o StrictHostKeyChecking=accept-new)
  [[ -n ${QNAP_KEY:-} ]] && opts+=(-i "$QNAP_KEY")
  if [[ -n ${QNAP_PASS:-} ]]; then
    SSHPASS=$QNAP_PASS sshpass -e ssh "${opts[@]}" \
      -o PreferredAuthentications=password,keyboard-interactive "$QNAP_USER@$QNAP_HOST" "$@"
  else
    ssh "${opts[@]}" -o BatchMode=yes "$QNAP_USER@$QNAP_HOST" "$@"
  fi
}

# Run a POSIX sh snippet on the QNAP inside $COMPOSE_DIR.
# Available remotely: $DC (compose command), $DSVC, $DBC, $DBU, $DBN, $APPDIR,
# $STAMP, $KEEP, $PULL. Snippet is passed verbatim (no local expansion).
qnap_run() {
  qnap_ssh 'sh -s' <<EOF
export PATH="\$PATH:/share/CACHEDEV1_DATA/.qpkg/container-station/bin:/usr/local/bin:/opt/bin"
cd '$COMPOSE_DIR' || { echo "ERR cannot cd to $COMPOSE_DIR"; exit 1; }
if docker compose version >/dev/null 2>&1; then DC='docker compose'; else DC='docker-compose'; fi
DSVC='$DSMR_SERVICE'; DBC='$DB_CONTAINER'; DBU='$DB_USER'; DBN='$DB_NAME'
BDIR='${BACKUP_DIR:-backups}'; APPDIR='${DSMR_APP_DIR:-/app}'; STAMP='${STAMP:-}'; KEEP='${BACKUP_KEEP:-5}'; PULL='${PULL_SERVICES:-$DSMR_SERVICE}'
$1
EOF
}

# Retained MQTT publish: mqtt_pub <subtopic> <payload>
mqtt_pub() {
  local a=(-h "$MQTT_HOST" -p "${MQTT_PORT:-1883}" -r -t "$MQTT_BASE/$1" -m "$2")
  [[ -n ${MQTT_USER:-} ]] && a+=(-u "$MQTT_USER" -P "$MQTT_PASS")
  mosquitto_pub "${a[@]}" || log "WARN mqtt publish to $MQTT_BASE/$1 failed"
}

# publish_status <state> <message> [extra jq args...]  -> $MQTT_BASE/update_status (JSON)
publish_status() {
  local state=$1 msg=$2; shift 2
  mqtt_pub update_status "$(jq -cn --arg state "$state" --arg message "$msg" \
    --arg finished "$(date -Iseconds)" "$@" '$ARGS.named')"
}

# Pick "key=value" out of remote output: kv <key> <text>
kv() { sed -n "s/^$1=//p" <<<"$2" | head -n1; }

# Digest of image:tag in its registry (Docker Hub, ghcr.io, ...), anonymous pull token.
# Sets REMOTE_DIGEST (+ REG/REPO/TAG/REG_TOKEN). Call directly, NOT in \$(...).
remote_digest() {
  local ref=$1 name=$1 tag=latest reg repo first url hdr auth realm service scope token
  local accept='application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.manifest.v1+json'
  if [[ ${ref##*/} == *:* ]]; then tag=${ref##*:}; name=${ref%:*}; fi
  first=${name%%/*}
  if [[ $name == */* && ( $first == *.* || $first == *:* || $first == localhost ) ]]; then
    reg=$first; repo=${name#*/}
  else
    reg=registry-1.docker.io; repo=$name; [[ $repo == */* ]] || repo=library/$repo
  fi
  [[ $reg == docker.io ]] && reg=registry-1.docker.io
  REG=$reg; REPO=$repo; TAG=$tag; REG_TOKEN=""; REMOTE_DIGEST=""   # kept for remote_version
  url="https://$reg/v2/$repo/manifests/$tag"
  hdr=$(curl -sSI -m 20 -H "Accept: $accept" "$url") || return 1
  auth=$(grep -i '^www-authenticate:' <<<"$hdr" | tr -d '\r')
  if [[ -n $auth ]]; then
    realm=$(sed -n 's/.*realm="\([^"]*\)".*/\1/p' <<<"$auth")
    service=$(sed -n 's/.*service="\([^"]*\)".*/\1/p' <<<"$auth")
    scope=$(sed -n 's/.*scope="\([^"]*\)".*/\1/p' <<<"$auth")
    token=$(curl -sS -m 20 -G "$realm" --data-urlencode "service=$service" \
      --data-urlencode "scope=${scope:-repository:$repo:pull}" | jq -r '.token // .access_token // empty')
    [[ -n $token ]] || return 1
    REG_TOKEN=$token
    hdr=$(curl -sSI -m 20 -H "Accept: $accept" -H "Authorization: Bearer $token" "$url") || return 1
  fi
  REMOTE_DIGEST=$(grep -i '^docker-content-digest:' <<<"$hdr" | awk '{print $2}' | tr -d '\r')
  [[ -n $REMOTE_DIGEST ]]
}

# GET from the registry of the last remote_digest call: registry_get <path> <accept>
registry_get() {
  local h=(-H "Accept: $2")
  [[ -n ${REG_TOKEN:-} ]] && h+=(-H "Authorization: Bearer $REG_TOKEN")
  curl -sSL -m 30 "${h[@]}" "https://$REG/v2/$REPO/$1"
}

# org.opencontainers.image.version label of the newest image in the registry.
# Call after remote_digest. Usage: remote_version <arch, e.g. amd64>
remote_version() {
  local arch=${1:-amd64} m d cfg
  local idx='application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json'
  local man='application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json'
  m=$(registry_get "manifests/$TAG" "$idx") || return 1
  if jq -e '.manifests' <<<"$m" >/dev/null 2>&1; then
    d=$(jq -r --arg a "$arch" '[.manifests[] | select(.platform.os=="linux" and .platform.architecture==$a)][0].digest // empty' <<<"$m")
    [[ -n $d ]] || return 1
    m=$(registry_get "manifests/$d" "$man") || return 1
  fi
  cfg=$(jq -r '.config.digest // empty' <<<"$m")
  [[ -n $cfg ]] || return 1
  registry_get "blobs/$cfg" '*/*' | jq -r '.config.Labels["org.opencontainers.image.version"] // empty'
}
