#!/usr/bin/env bash
# Starts the server and the loaders. Each machine destroys itself after
# LIFETIME_MINUTES (see node-init.sh), and an EventBridge schedule terminates
# them all 5 minutes later, in case a machine can't. ./down.sh ends it all
# earlier.
set -euo pipefail
source "$(dirname "$0")/config.sh"
mkdir -p "$STATE"

account=$(aws sts get-caller-identity --query Account --output text)
operator_ip=$(curl -fsS https://checkip.amazonaws.com)
vpc=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)
vpc_cidr=$(aws ec2 describe-vpcs --vpc-ids "$vpc" --query 'Vpcs[0].CidrBlock' --output text)
subnet=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$vpc" "Name=availability-zone,Values=$ZONE" \
  Name=default-for-az,Values=true --query 'Subnets[0].SubnetId' --output text)
ami=$(aws ec2 describe-images --owners 099720109477 \
  --filters 'Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-arm64-server-*' Name=state,Values=available \
  --query 'sort_by(Images, &CreationDate)[-1].ImageId' --output text)
echo "Ubuntu 24.04 image $ami, subnet $subnet ($ZONE), operator $operator_ip"

if [ ! -f "$STATE/key" ]; then ssh-keygen -q -t ed25519 -N "" -C "$TAG" -f "$STATE/key"; fi
if ! aws ec2 describe-key-pairs --key-names "$TAG" > /dev/null 2>&1; then
  aws ec2 import-key-pair --key-name "$TAG" --public-key-material "fileb://$STATE/key.pub" \
    --tag-specifications "ResourceType=key-pair,Tags=[{Key=Project,Value=$TAG}]" > /dev/null
fi

# All TCP is open so that AWS doesn't track connections. node-init.sh closes
# SSH and Erlang distribution with a firewall on each machine.
sg=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=$TAG" "Name=vpc-id,Values=$vpc" \
  --query 'SecurityGroups[0].GroupId' --output text)
if [ "$sg" = "None" ]; then
  sg=$(aws ec2 create-security-group --group-name "$TAG" --vpc-id "$vpc" \
    --description "Stampede million-connection benchmark" \
    --tag-specifications "ResourceType=security-group,Tags=[{Key=Project,Value=$TAG}]" \
    --query GroupId --output text)
  aws ec2 authorize-security-group-ingress --group-id "$sg" \
    --ip-permissions 'IpProtocol=tcp,FromPort=0,ToPort=65535,IpRanges=[{CidrIp=0.0.0.0/0}]' > /dev/null
fi

sed -e "s|__LIFETIME__|$LIFETIME_MINUTES|" -e "s|__OPERATOR_IP__|$operator_ip|" \
  -e "s|__VPC_CIDR__|$vpc_cidr|" -e "s|__OTP__|$OTP_VERSION|" -e "s|__ELIXIR__|$ELIXIR_VERSION|" \
  "$HERE/node-init.sh" > "$STATE/user-data.sh"

launched=()
# If anything below fails, nothing is left running.
trap 'if [ ${#launched[@]} -gt 0 ]; then echo "Failed, terminating ${launched[*]}"; aws ec2 terminate-instances --instance-ids "${launched[@]}" > /dev/null; fi' ERR

launch() {
  local role=$1 type=$2 count=$3 extra_ips=$4 credits=() network
  network="DeviceIndex=0,SubnetId=$subnet,Groups=$sg,AssociatePublicIpAddress=true"
  if [ "$extra_ips" -gt 0 ]; then network+=",SecondaryPrivateIpAddressCount=$extra_ips"; fi
  # Burstable types could otherwise bill for extra CPU credits.
  case $type in t*) credits=(--credit-specification CpuCredits=standard) ;; esac
  aws ec2 run-instances --image-id "$ami" --instance-type "$type" --count "$count" \
    --key-name "$TAG" --user-data "file://$STATE/user-data.sh" \
    --instance-initiated-shutdown-behavior terminate "${credits[@]}" \
    --metadata-options HttpTokens=required,HttpEndpoint=enabled \
    --network-interfaces "$network" \
    --block-device-mappings 'DeviceName=/dev/sda1,Ebs={VolumeSize=20,VolumeType=gp3,DeleteOnTermination=true}' \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Project,Value=$TAG},{Key=Name,Value=$TAG-$role},{Key=Role,Value=$role}]" \
    "ResourceType=volume,Tags=[{Key=Project,Value=$TAG}]" \
    --query 'Instances[].InstanceId' --output text
}

server=$(launch server "$SERVER_TYPE" 1 0)
launched+=($server)
loaders=$(launch loader "$LOADER_TYPE" "$LOADERS" "$SOURCE_IPS")
launched+=($loaders)
echo "Launched server $server and loaders $loaders"

# The second kill switch, run by AWS rather than the machines.
at=$(date -u -d "+$((LIFETIME_MINUTES + 5)) minutes" +%Y-%m-%dT%H:%M:%S)
target=$(python3 -c 'import json, sys
print(json.dumps({"Arn": "arn:aws:scheduler:::aws-sdk:ec2:terminateInstances", "RoleArn": sys.argv[1],
                  "Input": json.dumps({"InstanceIds": sys.argv[2:]})}))' \
  "arn:aws:iam::$account:role/$TAG-terminator" "${launched[@]}")
aws scheduler create-schedule --name "$TAG-kill-$(date +%s)" --schedule-expression "at($at)" \
  --schedule-expression-timezone UTC --flexible-time-window Mode=OFF \
  --action-after-completion DELETE --target "$target" > /dev/null
echo "Everything is terminated at $at UTC at the latest"

aws ec2 wait instance-running --instance-ids "${launched[@]}"
aws ec2 describe-instances --instance-ids "${launched[@]}" --output text \
  --query 'Reservations[].Instances[].[InstanceId, Tags[?Key==`Role`]|[0].Value, PublicIpAddress, PrivateIpAddress, join(`,`, NetworkInterfaces[0].PrivateIpAddresses[?Primary==`false`].PrivateIpAddress)]' |
  sort -k2,2r > "$STATE/nodes"
trap - ERR

echo "Waiting for the machines to install Erlang and Elixir..."
for public in $(nodes | awk '{print $3}'); do
  until on "$public" 'test -f /var/lib/stampede-ready' 2> /dev/null; do sleep 10; done
  echo "  $public ready"
done
nodes
