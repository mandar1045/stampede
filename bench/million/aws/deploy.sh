#!/usr/bin/env bash
# Copies Stampede and the benchmark to every machine and compiles them.
set -euo pipefail
source "$(dirname "$0")/config.sh"

tar czf "$STATE/code.tar.gz" -C "$HERE/../../.." --exclude=_build --exclude=deps --exclude=.state \
  mix.exs mix.lock lib bench/million/app bench/million/load bench/million/realtime bench/million/aws/monitor.sh

deploy() {
  local role=$1 public=$2
  scp -q "${SSH_OPTS[@]}" "$STATE/code.tar.gz" "ubuntu@$public:code.tar.gz"
  on "$public" 'rm -rf stampede && mkdir stampede && tar xzf code.tar.gz -C stampede &&
    mix local.hex --force > /dev/null && mix local.rebar --force > /dev/null'
  if [ "$role" = server ]; then
    on "$public" 'cd stampede/bench/million/app && MIX_ENV=prod mix deps.get --only prod > /dev/null && MIX_ENV=prod mix compile' > /dev/null
  else
    on "$public" 'cd stampede/bench/million/load && mix deps.get > /dev/null && mix compile' > /dev/null
  fi
  echo "  $role $public compiled"
}

# All machines at once. The loop reads from a process substitution, not a
# pipe, so that it runs in this shell and `wait` waits for every deploy.
pids=()
while read -r _id role public _private _extra; do
  deploy "$role" "$public" &
  pids+=($!)
done < <(nodes)
for pid in "${pids[@]}"; do wait "$pid"; done
