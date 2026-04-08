#!/bin/bash

# Configuration
CONTAINER_NAME="infiot_spoke"
LOG_FILE="/var/log/sse_monitor.log"
STABILIZATION_TIME=30  # Seconds to wait after restart for FRR to stabilize
ADVERTISE_FILE=/root/sse_monitor/frrcmds-advertise-default.json
RETRACT_FILE=/root/sse_monitor/frrcmds-retract-default.json
BLOCK_REDIST_FILE=/root/sse_monitor/frrcmds-block-default-redistribute.json

# Initialize tracking variables
last_start_time=""
retracted=1  # 0 = Advertised, 1 = Retracted (start retracted to force initial advertise)

echo "$(date) Process $$: Starting SSE Monitor for $CONTAINER_NAME..." >> $LOG_FILE

while true
do
  # --------------------------------
  # STEP 1: Check Container Status & Timestamp
  # --------------------------------

  current_start_time=$(docker inspect --format='{{.State.StartedAt}}' $CONTAINER_NAME 2>/dev/null)

  # If empty, the container is down. Wait and retry.
  if [ -z "$current_start_time" ]; then
    echo "$(date) Container $CONTAINER_NAME not found/down. Waiting..." >> $LOG_FILE
    sleep 10
    continue
  fi

  # --------------------------------
  # STEP 2: Detect Restart & Stabilize
  # --------------------------------

  if [ "$current_start_time" != "$last_start_time" ]; then
    if [ -n "$last_start_time" ]; then
      echo "$(date) RESTART DETECTED (New Start Time: $current_start_time)." >> $LOG_FILE
    fi

    echo "$(date) Waiting ${STABILIZATION_TIME}s for BGP/FRR to stabilize..." >> $LOG_FILE

    # This sleep is CRITICAL. It lets FRR finish loading its default config.
    sleep $STABILIZATION_TIME

    # Block redistributed 0.0.0.0/0 from leaking to TGW peers via set-med-peer.
    # default-originate is independent of outbound route-map deny rules.
    if [ -f "$BLOCK_REDIST_FILE" ]; then
      echo "$(date) Applying route-map deny for redistributed default route..." >> $LOG_FILE
      docker cp $BLOCK_REDIST_FILE $CONTAINER_NAME:/tmp/frrcmds-block-default-redistribute.json
      if docker exec $CONTAINER_NAME /opt/infiot/bin/gencfg -run-frr-cmds /tmp/frrcmds-block-default-redistribute.json >> $LOG_FILE 2>&1; then
        echo "$(date) SUCCESS: Redistributed default route blocked in set-med-peer." >> $LOG_FILE
      else
        echo "$(date) ERROR: Failed to apply redistribute block rule." >> $LOG_FILE
      fi
    fi

    # Start in retracted state so the monitor always pushes the advertise config
    # when tunnels are up. This handles both fresh boots and container restarts.
    retracted=1

    # Update the last known start time so we don't trigger this block again.
    last_start_time="$current_start_time"

    echo "$(date) Stabilization complete. Checking tunnels now." >> $LOG_FILE
  fi

  # --------------------------------
  # STEP 3: Monitor Tunnels & Manage Route
  # --------------------------------

  # Get tunnel count safely
  sse_tunnel_count=$(docker exec $CONTAINER_NAME ikectl show sa 2>/dev/null | grep ESTABLISHED | grep "IPV4/163" | wc -l)

  # Safety check: if variable is empty, treat as 0
  if [ -z "$sse_tunnel_count" ]; then sse_tunnel_count=0; fi

  echo "$(date) Tunnel Count=$sse_tunnel_count" >> $LOG_FILE

  if [ "$sse_tunnel_count" -eq 0 ]; then
    # --- SCENARIO: TUNNELS DOWN ---

    # If tunnels are down and we haven't retracted yet, DO IT.
    if [ "$retracted" -eq 0 ]; then
      echo "$(date) ACTION: Tunnels Down. Retracting default route..." >> $LOG_FILE

      # Copy config into container and run
      docker cp $RETRACT_FILE $CONTAINER_NAME:/tmp/frrcmds-retract-default.json
      if docker exec $CONTAINER_NAME /opt/infiot/bin/gencfg -run-frr-cmds /tmp/frrcmds-retract-default.json >> $LOG_FILE 2>&1; then
        retracted=1
        echo "$(date) SUCCESS: Route Retracted." >> $LOG_FILE
      else
        echo "$(date) ERROR: Failed to retract route (Command failed)." >> $LOG_FILE
      fi
    else
      echo "$(date) Route already retracted. No action." >> $LOG_FILE
    fi

  else

    # --- SCENARIO: TUNNELS UP ---

    # If tunnels are up and we previously retracted, RE-ADVERTISE.
    if [ "$retracted" -eq 1 ]; then
      echo "$(date) ACTION: Tunnels Up. Re-advertising default route..." >> $LOG_FILE

      docker cp $ADVERTISE_FILE $CONTAINER_NAME:/tmp/frrcmds-advertise-default.json
      if docker exec $CONTAINER_NAME /opt/infiot/bin/gencfg -run-frr-cmds /tmp/frrcmds-advertise-default.json >> $LOG_FILE 2>&1; then
        retracted=0
        echo "$(date) SUCCESS: Route Advertised." >> $LOG_FILE
      else
        echo "$(date) ERROR: Failed to advertise route." >> $LOG_FILE
      fi
    fi

  fi

  sleep 10

done

# End Of Script #