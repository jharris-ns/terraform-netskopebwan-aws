#!/bin/bash
LOG_FILE=/var/log/sse_monitor.log
CONTAINER_NAME=infiot_spoke
STABILIZATION_TIME=30
POLL_INTERVAL=10
ADVERTISE_FILE=/root/sse_monitor/frrcmds-advertise-default.json
RETRACT_FILE=/root/sse_monitor/frrcmds-retract-default.json

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> $LOG_FILE; }

apply_frr_config() {
  local f=$1 a=$2
  [ ! -f "$f" ] && log "ERROR: $f not found" && return 1
  log "Applying FRR config: $a"
  docker cp "$f" "$CONTAINER_NAME:/tmp/frrcmds.json"
  docker exec "$CONTAINER_NAME" /opt/infiot/scripts/ikectl frrcmds /tmp/frrcmds.json >> $LOG_FILE 2>&1
  local rc=$?; [ $rc -eq 0 ] && log "OK: $a" || log "FAIL(rc=$rc): $a"; return $rc
}

check_tunnels() {
  local s; s=$(docker exec $CONTAINER_NAME /opt/infiot/scripts/ikectl status 2>/dev/null) || return 1
  echo "$s" | grep -q 'ESTABLISHED' && return 0 || return 1
}

wait_for_container() {
  while true; do
    local r=$(docker inspect -f '{{.State.Running}}' $CONTAINER_NAME 2>/dev/null || echo false)
    [ "$r" = "true" ] && log "Container running" && return 0
    log "Waiting for container..."; sleep $POLL_INTERVAL
  done
}

log "SSE Monitor starting..."; STATE=unknown
wait_for_container; log "Stabilizing ${STABILIZATION_TIME}s..."; sleep $STABILIZATION_TIME
while true; do
  r=$(docker inspect -f '{{.State.Running}}' $CONTAINER_NAME 2>/dev/null || echo false)
  if [ "$r" != "true" ]; then
    [ "$STATE" != retracted ] && apply_frr_config $RETRACT_FILE retract && STATE=retracted
    wait_for_container; sleep $STABILIZATION_TIME; continue
  fi
  if check_tunnels; then
    [ "$STATE" != advertised ] && log "Tunnels UP" && apply_frr_config $ADVERTISE_FILE advertise && STATE=advertised
  else
    [ "$STATE" != retracted ] && log "Tunnels DOWN" && apply_frr_config $RETRACT_FILE retract && STATE=retracted
  fi
  sleep $POLL_INTERVAL
done
