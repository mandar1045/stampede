#!/usr/bin/env bash
# Lists the benchmark machines that exist, and how long they have been up.
set -euo pipefail
source "$(dirname "$0")/config.sh"

aws ec2 describe-instances --filters "Name=tag:Project,Values=$TAG" \
  Name=instance-state-name,Values=pending,running,stopping,stopped \
  --query 'Reservations[].Instances[].[InstanceId, InstanceType, State.Name, LaunchTime, PublicIpAddress]' \
  --output text | while read -r id type state launched ip; do
  minutes=$((($(date +%s) - $(date -d "$launched" +%s)) / 60))
  echo "$id  $type  $state  up ${minutes}m  $ip"
done
