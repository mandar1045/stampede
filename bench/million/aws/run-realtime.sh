#!/usr/bin/env bash
# Runs the official Supabase Realtime release on the server, load tests it from
# the loaders, and keeps the proof as it goes: Stampede's dashboard, Realtime's
# LiveDashboard, a real realtime-js client in Firefox, Realtime's own /metrics
# in Grafana, socket counts from the kernel, and a recording of the terminal.
# Videos go in drafts/proof, since they're too big for the repository.
#
#     PAUSE=30-60 STEP_RAMP=60 ./run-realtime.sh --find-limit --start 10000 \
#       --step 10000 --up-to 120000 --hold 60s
#
# Anything given goes to mix stampede.run. PROOF_SECONDS is how long to record,
# 1500 by default. Everything ends up in ../results.
set -euo pipefail
source "$(dirname "$0")/config.sh"

proof_seconds=${PROOF_SECONDS:-1500}
name="$(date -u +%Y%m%d-%H%M)-realtime"
out="$RESULTS/$name"
proof_out="$HERE/../../../drafts/proof/$name"
mkdir -p "$out" "$proof_out"

read -r _ _ server_public server_private _ < <(nodes server)
mapfile -t loaders < <(nodes loader)
[ -f "$STATE/cookie" ] || head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' > "$STATE/cookie"
cookie=$(cat "$STATE/cookie")
vpc_cidr=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].CidrBlock' --output text)

# Secrets live for this run only, and never go in the results.
api_secret=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
metrics_secret=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
dashboard_password=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')
jwt() {
  python3 -c '
import base64, hashlib, hmac, json, sys, time
b64 = lambda b: base64.urlsafe_b64encode(b).rstrip(b"=").decode()
head = b64(json.dumps({"alg": "HS256", "typ": "JWT"}).encode())
body = b64(json.dumps({"role": sys.argv[2], "iss": "stampede", "exp": int(time.time()) + 21600}).encode())
print(head + "." + body + "." + b64(hmac.new(sys.argv[1].encode(), (head + "." + body).encode(), hashlib.sha256).digest()))
' "$1" "$2"
}
anon_token=$(jwt "$api_secret" anon)
metrics_token=$(jwt "$metrics_secret" metrics)

# Realtime's ports stay inside the network. Postgres has a throwaway password
# and the security group lets all TCP in, so this firewall is what protects them.
# It goes after the rule that accepts loopback, which Realtime uses for Postgres.
on "$server_public" "sudo iptables -C INPUT -p tcp -m multiport --dports 4000,5432,5369,5469 ! -s $vpc_cidr -j DROP 2>/dev/null ||
  sudo iptables -A INPUT -p tcp -m multiport --dports 4000,5432,5369,5469 ! -s $vpc_cidr -j DROP
  command -v docker > /dev/null || { sudo apt-get -o DPkg::Lock::Timeout=180 update -qq > /dev/null
    sudo DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=180 install -y -qq docker.io > /dev/null; }"

echo "Starting Realtime on $server_private"
on "$server_public" "pkill -f '[m]onitor.sh'; true"
on "$server_public" "cd stampede/bench/million/realtime || exit 1
  sudo API_JWT_SECRET=$api_secret METRICS_JWT_SECRET=$metrics_secret DASHBOARD_PASSWORD=$dashboard_password \
    NODE_IP=$server_private RELEASE_COOKIE=$cookie ./start.sh"
on "$server_public" 'setsid nohup stampede/bench/million/aws/monitor.sh > monitor.csv 2>&1 < /dev/null &'
on "$server_public" "setsid nohup bash -c 'while :; do date -u +%FT%TZ; ss -s | sed -n 1,2p; free -m | sed -n 2p
  sudo docker stats --no-stream --format \"{{.Name}} {{.CPUPerc}} {{.MemUsage}}\"; echo; sleep 10; done' > sockets.log 2>&1 < /dev/null &"

# Everything the recordings look at, over SSH, so no port is opened to the world.
read -r _ _ first_public _ _ <<< "${loaders[0]}"
ssh "${SSH_OPTS[@]}" -f -N -L 14000:127.0.0.1:4000 "ubuntu@$server_public"
ssh "${SSH_OPTS[@]}" -f -N -L 14040:127.0.0.1:4040 "ubuntu@$first_public"
stop_tunnels() {
  pkill -f '[s]sh.*-L 140[04]0:127.0.0.1' || true
  docker rm -f stampede-prometheus stampede-grafana > /dev/null 2>&1 || true
  rm -rf "$STATE/prometheus"
}
trap stop_tunnels EXIT

# Prometheus reads Realtime's own numbers, on this machine so that it adds no
# load there, every 30 seconds as Realtime's docs advise, since /metrics is
# expensive to produce.
mkdir -p "$STATE/prometheus"
printf '%s' "$metrics_token" > "$STATE/prometheus/token"
cat > "$STATE/prometheus/prometheus.yml" <<YAML
global:
  scrape_interval: 30s
scrape_configs:
  - job_name: realtime
    authorization:
      credentials_file: /config/token
    static_configs:
      - targets: ["localhost:14000"]
YAML
chmod -R a+rX "$STATE/prometheus"
docker rm -f stampede-prometheus stampede-grafana > /dev/null 2>&1 || true
docker run -d --name stampede-prometheus --network host -v "$STATE/prometheus:/config:ro" \
  prom/prometheus:v3.5.0 --config.file=/config/prometheus.yml > /dev/null
docker run -d --name stampede-grafana --network host -e GF_AUTH_ANONYMOUS_ENABLED=true \
  -e GF_AUTH_ANONYMOUS_ORG_ROLE=Admin -e GF_AUTH_DISABLE_LOGIN_FORM=true -e GF_USERS_DEFAULT_THEME=light \
  -v "$HERE/../proof/grafana:/etc/grafana/provisioning:ro" grafana/grafana:12.2.0 > /dev/null

# Realtime reads the tenant from the host.
for loader in "${loaders[@]}"; do
  read -r _ _ public _ _ <<< "$loader"
  on "$public" "pkill -f '[m]onitor.sh'; pkill -f '[m]ix run --no-halt'; pkill -f '[s]tampede.run'; sleep 2
    grep -q realtime-dev.bench /etc/hosts || echo '$server_private realtime-dev.bench' | sudo tee -a /etc/hosts > /dev/null"
  on "$public" 'setsid nohup stampede/bench/million/aws/monitor.sh > monitor.csv 2>&1 < /dev/null &'
done

load_env="PAUSE=${PAUSE:-30-60} ${STEP_RAMP:+STEP_RAMP=$STEP_RAMP} VUS=${VUS:-1000} RAMP=${RAMP:-60} HOLD=${HOLD:-60} \
  JWT_SECRET=$api_secret SERVER=realtime-dev.bench:4000"
no_spin="+sbwt none +sbwtdcpu none +sbwtdio none"
erl_flags="+P 10000000 $no_spin -kernel inet_dist_listen_min 9100 inet_dist_listen_max 9110"

workers=()
for loader in "${loaders[@]:1}"; do
  read -r _ _ public private extra <<< "$loader"
  workers+=("load@$private")
  on "$public" "cd stampede/bench/million/load || exit 1; $load_env SOURCE_IPS=$extra \
    setsid nohup elixir --name load@$private --cookie $cookie --erl '$erl_flags' -S mix run --no-halt \
    > ~/worker.log 2>&1 < /dev/null &"
done
sleep 15

read -r _ _ public private extra <<< "${loaders[0]}"
nodes_flag=$(IFS=,; echo "${workers[*]}")
on "$public" "rm -f run.log results.json report.html
  cd stampede/bench/million/load || exit 1; $load_env SOURCE_IPS=$extra \
    setsid nohup elixir --name load@$private --cookie $cookie --erl '$erl_flags' \
    -S mix stampede.run loadtest/realtime.exs --nodes $nodes_flag --dashboard $* \
    --out ~/results.json --html ~/report.html > ~/run.log 2>&1 < /dev/null &"

sleep 20
proof="$HERE/../proof"
query="url=ws%3A%2F%2Frealtime-dev.localhost%3A14000%2Fsocket&key=$anon_token&channel=load-1"
recorders=()
record() {
  "$proof/record.py" "$1" "$proof_out/$2" "$proof_seconds" --port "$3" --every 2 &
  recorders+=($!)
}
record "http://127.0.0.1:14040" stampede-dashboard 2841
record "http://realtime:$dashboard_password@127.0.0.1:14000/admin/dashboard/home?refresh=5" livedashboard 2842
record "file://$(cd "$proof" && pwd)/client.html?$query" real-client 2843
record "http://127.0.0.1:3000/d/realtime/realtime?kiosk&from=now-30m&to=now&theme=light" grafana 2844

# A real recording of the terminal, to replay with scriptreplay.
follow='tail -n +1 -F run.log & tailing=$!
  while pgrep -f "[s]tampede.run" > /dev/null; do sleep 5; done
  sleep 3; kill $tailing'
script -q -T "$proof_out/terminal.timing" -c "$(printf '%q ' ssh "${SSH_OPTS[@]}" "ubuntu@$public" "$follow")" \
  "$proof_out/terminal.typescript" > /dev/null
kill -TERM "${recorders[@]}" || true
wait "${recorders[@]}" || true

# Realtime's own numbers for the whole run, as Prometheus scraped them.
python3 - "$proof_out/realtime-metrics.json" <<'PY'
import json, sys, time, urllib.parse, urllib.request

end = time.time()
series = {}
for name in ["realtime_connections_global_connected", "phoenix_connections_total", "beam_stats_process_count",
             "beam_stats_port_count", "beam_stats_run_queue_count", "osmon_cpu_util", "osmon_ram_usage",
             "realtime_channel_global_events", "realtime_channel_global_output_bytes"]:
    query = urllib.parse.urlencode({"query": name, "start": end - 7200, "end": end, "step": 30})
    series[name] = json.load(urllib.request.urlopen("http://127.0.0.1:9090/api/v1/query_range?" + query))["data"]["result"]
json.dump(series, open(sys.argv[1], "w"), indent=1)
PY

on "$public" 'cat run.log' > "$out/run.log"
scp -q "${SSH_OPTS[@]}" "ubuntu@$public:results.json" "ubuntu@$public:report.html" "$out/" || true
on "$server_public" 'cat monitor.csv' > "$out/server-monitor.csv"
on "$server_public" 'cat sockets.log' > "$proof_out/sockets.log"
# All of it, since this is what shows when the server had errors. Clients send
# their tokens, which Realtime logs when a process crashes.
on "$server_public" 'sudo docker logs realtime 2>&1' | sed -E 's/eyJ[A-Za-z0-9_.-]+/<token>/g' > "$out/realtime.log"
for loader in "${loaders[@]}"; do
  read -r _ _ loader_public loader_private _ <<< "$loader"
  on "$loader_public" 'cat monitor.csv' > "$out/loader-$loader_private-monitor.csv"
  on "$loader_public" "pkill -f '[m]onitor.sh'; pkill -f '[m]ix run --no-halt'; pkill -f '[s]tampede.run'; true"
done
on "$server_public" "pkill -f '[m]onitor.sh'; pkill -f '[w]hile :; do date'; true"

# What the machines were, without the account id.
aws ec2 describe-instances --filters "Name=tag:Project,Values=$TAG" Name=instance-state-name,Values=running \
  --query 'Reservations[].Instances[].{id:InstanceId,type:InstanceType,zone:Placement.AvailabilityZone,started:LaunchTime,arch:Architecture}' \
  --output json > "$proof_out/machines.json"
cp "$proof_out/sockets.log" "$proof_out/realtime-metrics.json" "$proof_out/machines.json" "$out/"
tail -20 "$out/run.log"
echo "Results in $out, videos in $proof_out"
