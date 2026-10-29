#!/usr/bin/env bash
# Runs a scenario from the loaders against the server and downloads what it
# measured to ../results.
#
#     ./run.sh channels 1000000 600 300    # scenario, VUs, ramp and hold in seconds
#
# Anything after the hold goes to mix stampede.run, and PAUSE and STEP_RAMP
# (see load/lib/load.ex) are passed on to the loaders:
#
#     PAUSE=120-240 STEP_RAMP=100 ./run.sh channels 0 0 0 --find-limit \
#       --start 100000 --step 100000 --up-to 800000 --hold 60s
set -euo pipefail
source "$(dirname "$0")/config.sh"

scenario=${1:?usage: ./run.sh channels|live VUS RAMP HOLD}
vus=${2:-1000}
ramp=${3:-60}
hold=${4:-60}
stampede_args=("${@:5}")
load_env="PAUSE=${PAUSE:-30-60} ${STEP_RAMP:+STEP_RAMP=$STEP_RAMP}"
name="$(date -u +%Y%m%d-%H%M)-$scenario-$vus"
mkdir -p "$RESULTS/$name"

read -r _ _ server_public server_private _ < <(nodes server)
mapfile -t loaders < <(nodes loader)
[ -f "$STATE/cookie" ] || head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' > "$STATE/cookie"
cookie=$(cat "$STATE/cookie")
# Without busy waiting, the CPU the machines report is the work they did:
# idle schedulers otherwise spin, which shows up as CPU use.
no_spin="+sbwt none +sbwtdcpu none +sbwtdio none"
erl_flags="+P 10000000 $no_spin -kernel inet_dist_listen_min 9100 inet_dist_listen_max 9110"

# Stops what an earlier run left on a machine. This is a command of its own,
# with brackets in the patterns, so pkill can't match the shell running it.
stop_old() {
  on "$1" "pkill -f '[m]onitor.sh'; pkill -f '[m]ix run --no-halt'; pkill -f '[s]tampede.run'; pkill -f '[p]hx.server'; sleep 2; true"
}

start_monitor() {
  on "$1" 'setsid nohup stampede/bench/million/aws/monitor.sh > monitor.csv 2>&1 < /dev/null &'
}

# A fresh app for every run, so its memory is measured from the start.
echo "Starting the app on $server_private"
stop_old "$server_public"
start_monitor "$server_public"
secret=$(head -c 64 /dev/urandom | base64 -w0)
on "$server_public" "cd stampede/bench/million/app || exit 1; MIX_ENV=prod PHX_SERVER=true PORT=4000 \
  PHX_HOST=$server_private LOG_LEVEL=warning SECRET_KEY_BASE=$secret ELIXIR_ERL_OPTIONS='+P 10000000 $no_spin' \
  setsid nohup mix phx.server > ~/server.log 2>&1 < /dev/null &"
for _ in $(seq 60); do
  on "$server_public" 'ss -ltn | grep -q ":4000 "' && break
  sleep 2
done
if ! on "$server_public" 'ss -ltn | grep -q ":4000 "'; then
  echo "The app didn't start:"
  on "$server_public" 'tail -20 server.log'
  exit 1
fi

# Every loader but the first runs a node that waits for VUs, connecting from
# its own extra addresses. The first runs the test.
workers=()
for loader in "${loaders[@]:1}"; do
  read -r _ _ public private extra <<< "$loader"
  workers+=("load@$private")
  stop_old "$public"
  start_monitor "$public"
  on "$public" "cd stampede/bench/million/load || exit 1; $load_env SOURCE_IPS=$extra SERVER=$server_private:4000 \
      setsid nohup elixir --name load@$private --cookie $cookie --erl '$erl_flags' -S mix run --no-halt \
      > ~/worker.log 2>&1 < /dev/null &"
done
sleep 15

read -r _ _ public private extra <<< "${loaders[0]}"
nodes_flag=$(IFS=,; echo "${workers[*]}")
echo "Running $scenario: $vus VUs, ${ramp}s ramp, ${hold}s hold, from ${#loaders[@]} loaders"
stop_old "$public"
start_monitor "$public"
on "$public" "rm -f run.log results.json report.html
  cd stampede/bench/million/load || exit 1; $load_env SOURCE_IPS=$extra SERVER=$server_private:4000 VUS=$vus RAMP=$ramp HOLD=$hold \
    setsid nohup elixir --name load@$private --cookie $cookie --erl '$erl_flags' \
    -S mix stampede.run loadtest/$scenario.exs ${nodes_flag:+--nodes $nodes_flag} \
    ${stampede_args[*]} --out ~/results.json --html ~/report.html > ~/run.log 2>&1 < /dev/null &"

# Follows the run, a line every 30 seconds, until its summary is printed.
sleep 20
while on "$public" 'pgrep -f "[s]tampede.run" > /dev/null'; do
  on "$public" 'tail -1 run.log'
  sleep 30
done
on "$public" 'cat run.log' > "$RESULTS/$name/run.log"
tail -20 "$RESULTS/$name/run.log"

scp -q "${SSH_OPTS[@]}" "ubuntu@$public:results.json" "ubuntu@$public:report.html" "$RESULTS/$name/" || true
on "$server_public" 'cat monitor.csv' > "$RESULTS/$name/server-monitor.csv"
on "$server_public" 'tail -100 server.log' > "$RESULTS/$name/server.log"
for loader in "${loaders[@]}"; do
  read -r _ _ public private _ <<< "$loader"
  on "$public" 'cat monitor.csv' > "$RESULTS/$name/loader-$private-monitor.csv"
  stop_old "$public"
done
stop_old "$server_public"
echo "Results in $RESULTS/$name"
