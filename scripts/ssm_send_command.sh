#!/bin/bash
# Shared SSM command sender: poll for readiness, send command, poll for completion.
# Usage: ssm_send_command.sh <region> <instance_id> <document_name> <parameters_json> <comment>
set -euo pipefail

REGION="$1"
INSTANCE_ID="$2"
DOCUMENT_NAME="$3"
PARAMETERS="$4"
COMMENT="$5"

# Poll for SSM readiness (up to 5 minutes, 10s intervals)
MAX_ATTEMPTS=30
ATTEMPT=0
STATUS="None"
while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
  STATUS=$(aws ssm describe-instance-information \
    --region "$REGION" \
    --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
    --query "InstanceInformationList[0].PingStatus" \
    --output text 2>/dev/null || echo "None")
  [ "$STATUS" = "Online" ] && break
  ATTEMPT=$((ATTEMPT + 1))
  sleep 10
done
[ "$STATUS" != "Online" ] && echo "SSM agent not ready on $INSTANCE_ID" && exit 1

# Send SSM command
COMMAND_ID=$(aws ssm send-command \
  --region "$REGION" \
  --instance-ids "$INSTANCE_ID" \
  --document-name "$DOCUMENT_NAME" \
  --parameters "$PARAMETERS" \
  --comment "$COMMENT" \
  --query "Command.CommandId" \
  --output text)

# Poll for completion
while true; do
  CMD_STATUS=$(aws ssm get-command-invocation \
    --region "$REGION" \
    --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID" \
    --query Status --output text 2>/dev/null || echo "InProgress")
  case "$CMD_STATUS" in
    Success) echo "$COMMENT — succeeded"; break ;;
    Failed|Cancelled|TimedOut) echo "$COMMENT — failed ($CMD_STATUS)"; exit 1 ;;
    *) sleep 5 ;;
  esac
done
