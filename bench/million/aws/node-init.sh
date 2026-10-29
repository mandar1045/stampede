#!/bin/bash
# Runs once, as root, when a benchmark machine boots. up.sh fills in the
# __PLACEHOLDERS__ and passes it as user data.
set -euxo pipefail

# Kill switch: the machine shuts down at the end of its lifetime, and since
# up.sh launches it with the "terminate" shutdown behaviour, that destroys it.
shutdown -h +__LIFETIME__ "stampede-bench: lifetime is over"

# The security group lets all TCP in, which is what stops AWS from tracking
# connections (and capping how many there can be). This firewall closes what
# must stay private instead, without tracking anything: SSH to everyone but
# the operator, and Erlang distribution to everything outside the VPC.
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -p tcp --dport 22 -s __OPERATOR_IP__ -j ACCEPT
iptables -A INPUT -p tcp --dport 22 -s __VPC_CIDR__ -j ACCEPT
iptables -A INPUT -p tcp --dport 22 -j DROP
iptables -A INPUT -p tcp -m multiport --dports 4369,9100:9110 ! -s __VPC_CIDR__ -j DROP

# Room for a million connections.
cat > /etc/sysctl.d/90-stampede.conf <<'CONF'
fs.file-max = 10000000
fs.nr_open = 10000000
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.ip_local_reserved_ports = 4369,9100-9110
net.ipv4.tcp_tw_reuse = 1
CONF
sysctl --system
cat > /etc/security/limits.d/90-stampede.conf <<'CONF'
* soft nofile 4000000
* hard nofile 4000000
CONF

# Every private address AWS gave this machine, so connections can come from
# all of them.
token=$(curl -fsS -X PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
meta() { curl -fsS -H "X-aws-ec2-metadata-token: $token" "http://169.254.169.254/latest/meta-data/$1"; }
mac=$(meta mac)
primary=$(meta local-ipv4)
iface=$(ip route show default | awk '{print $5; exit}')
prefix=$(meta "network/interfaces/macs/$mac/subnet-ipv4-cidr-block" | cut -d/ -f2)
for address in $(meta "network/interfaces/macs/$mac/local-ipv4s"); do
  [ "$address" = "$primary" ] || ip addr replace "$address/$prefix" dev "$iface"
done

# Erlang/OTP, prebuilt for Ubuntu 24.04 on Arm by Hex, and Elixir.
mkdir -p /opt/otp /opt/elixir
curl -fsSL "https://builds.hex.pm/builds/otp/arm64/ubuntu-24.04/OTP-__OTP__.tar.gz" |
  tar xz -C /opt/otp --strip-components=1
/opt/otp/Install -minimal /opt/otp
otp_major=$(echo __OTP__ | cut -d. -f1)
curl -fsSLo /tmp/elixir.zip "https://github.com/elixir-lang/elixir/releases/download/v__ELIXIR__/elixir-otp-$otp_major.zip"
python3 -m zipfile -e /tmp/elixir.zip /opt/elixir
chmod +x /opt/elixir/bin/*
echo 'export PATH=/opt/otp/bin:/opt/elixir/bin:$PATH' > /etc/profile.d/stampede.sh

touch /var/lib/stampede-ready
