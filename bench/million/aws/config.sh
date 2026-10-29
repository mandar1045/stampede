# Settings for the AWS scripts, sourced by each of them. Any of them can be
# overridden from the environment, such as LOADERS=2 ./up.sh.

REGION=${REGION:-ap-south-1}
ZONE=${ZONE:-ap-south-1a}
SERVER_TYPE=${SERVER_TYPE:-r7g.8xlarge}
LOADER_TYPE=${LOADER_TYPE:-r7g.xlarge}
LOADERS=${LOADERS:-4}
# Extra private addresses per loader. One address gets about 64,000 ports to
# the server, so 250,000 connections need at least four.
SOURCE_IPS=${SOURCE_IPS:-10}
# Every machine destroys itself after this long, whatever else happens.
LIFETIME_MINUTES=${LIFETIME_MINUTES:-240}
OTP_VERSION=${OTP_VERSION:-29.1.2}
ELIXIR_VERSION=${ELIXIR_VERSION:-1.20.2}

TAG=stampede-bench
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
STATE=${STATE:-$HERE/.state}
RESULTS=${RESULTS:-$HERE/../results}

export AWS_REGION=$REGION AWS_DEFAULT_REGION=$REGION AWS_PAGER=""

SSH_OPTS=(-i "$STATE/key" -o StrictHostKeyChecking=accept-new
  -o UserKnownHostsFile="$STATE/known_hosts" -o ConnectTimeout=10
  -o ServerAliveInterval=30 -o LogLevel=ERROR)

# Runs a command on a machine, in a login shell so that Erlang is on the PATH.
on() {
  local ip=$1
  shift
  ssh "${SSH_OPTS[@]}" "ubuntu@$ip" "bash -lc $(printf '%q' "$*")"
}

# Prints the machines from $STATE/nodes, written by up.sh:
# id, role, public IP, private IP, extra private IPs (comma-separated).
nodes() {
  if [ -n "${1:-}" ]; then
    awk -v role="$1" '$2 == role' "$STATE/nodes"
  else
    cat "$STATE/nodes"
  fi
}
