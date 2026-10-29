#!/usr/bin/env bash
# Terminates every benchmark machine and deletes what up.sh created.
set -euo pipefail
source "$(dirname "$0")/config.sh"

read -ra ids < <(aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=$TAG" Name=instance-state-name,Values=pending,running,stopping,stopped \
  --query 'Reservations[].Instances[].InstanceId' --output text)
if [ ${#ids[@]} -gt 0 ]; then
  echo "Terminating ${ids[*]}"
  aws ec2 terminate-instances --instance-ids "${ids[@]}" > /dev/null
  aws ec2 wait instance-terminated --instance-ids "${ids[@]}"
fi

for schedule in $(aws scheduler list-schedules --name-prefix "$TAG-kill" --query 'Schedules[].Name' --output text); do
  aws scheduler delete-schedule --name "$schedule"
done
sg=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=$TAG" --query 'SecurityGroups[0].GroupId' --output text)
[ "$sg" = "None" ] || aws ec2 delete-security-group --group-id "$sg" > /dev/null
aws ec2 delete-key-pair --key-name "$TAG" > /dev/null
rm -f "$STATE/nodes" "$STATE/known_hosts"

left=$(aws ec2 describe-volumes --filters "Name=tag:Project,Values=$TAG" --query 'length(Volumes)' --output text)
echo "Done. Volumes left: $left"
