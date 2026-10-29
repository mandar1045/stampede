#!/bin/bash
# Prints a line every 10 seconds about this machine, as CSV. run.sh starts it
# on every machine and collects the output.
iface=$(ip route show default | awk '{print $5; exit}')
echo "time,cpu_busy_pct,mem_used_mb,beam_rss_mb,tcp_established,conntrack_allowance_exceeded"
read -ra prev < <(head -1 /proc/stat)
while true; do
  sleep 10
  read -ra cur < <(head -1 /proc/stat)
  total=0
  for i in 1 2 3 4 5 6 7 8; do total=$((total + cur[i] - prev[i])); done
  idle=$((cur[4] + cur[5] - prev[4] - prev[5]))
  busy=$((total > 0 ? 100 * (total - idle) / total : 0))
  prev=("${cur[@]}")
  mem=$(free -m | awk '/^Mem:/ {print $3}')
  rss=$(ps -C beam.smp -o rss= | awk '{s += $1} END {print int(s / 1024)}')
  estab=$(ss -s | sed -n 's/^TCP:.*estab \([0-9]*\).*/\1/p')
  dropped=$(ethtool -S "$iface" 2>/dev/null | awk '/conntrack_allowance_exceeded/ {print $2}')
  echo "$(date -u +%H:%M:%S),$busy,$mem,$rss,$estab,${dropped:-n/a}"
done
