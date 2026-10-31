#!/usr/bin/env bash
# Runs the chat scenario from the loader against Ollama on the server, and
# downloads what it measured to ../results. Anything given goes to
# mix stampede.run. MODEL, PAUSE and STEP_RAMP are passed on to the scenario.
#
#     PAUSE=5-10 STEP_RAMP=5 ./run-llm.sh --find-limit --start 2 --step 2 --up-to 40 --hold 60s
set -euo pipefail
source "$(dirname "$0")/config.sh"

model=${MODEL:-qwen2.5:0.5b}
name="$(date -u +%Y%m%d-%H%M)-chat-${model//[:\/]/-}"
mkdir -p "$RESULTS/$name"
load_env="MODEL=$model PAUSE=${PAUSE:-5-10} ${STEP_RAMP:+STEP_RAMP=$STEP_RAMP}"

read -r _ _ server_public server_private _ < <(nodes server)
read -r _ _ public _ _ < <(nodes loader)

stop_old() { on "$1" "pkill -f '[m]onitor.sh'; pkill -f '[s]tampede.run'; sleep 1; true"; }
start_monitor() { on "$1" 'setsid nohup stampede/bench/million/aws/monitor.sh > monitor.csv 2>&1 < /dev/null &'; }

for host in "$server_public" "$public"; do
  stop_old "$host"
  start_monitor "$host"
done

on "$public" "rm -f run.log results.json report.html
  cd stampede/bench/million/load || exit 1; $load_env SERVER=$server_private:11434 \
    setsid nohup mix stampede.run loadtest/chat.exs $* \
    --out ~/results.json --html ~/report.html > ~/run.log 2>&1 < /dev/null &"

sleep 10
while on "$public" 'pgrep -f "[s]tampede.run" > /dev/null'; do
  on "$public" 'tail -1 run.log'
  sleep 30
done

on "$public" 'cat run.log' > "$RESULTS/$name/run.log"
scp -q "${SSH_OPTS[@]}" "ubuntu@$public:results.json" "ubuntu@$public:report.html" "$RESULTS/$name/" || true
on "$server_public" 'cat monitor.csv' > "$RESULTS/$name/server-monitor.csv"
on "$public" 'cat monitor.csv' > "$RESULTS/$name/loader-monitor.csv"
tail -25 "$RESULTS/$name/run.log"
echo "Results in $RESULTS/$name"
