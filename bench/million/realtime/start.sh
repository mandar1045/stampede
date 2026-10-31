#!/usr/bin/env bash
# Starts the official Supabase Realtime release and its Postgres on this
# machine, in Docker, as its own compose.yml does. Only limits that stop a test
# from reaching the server's capacity are raised: the per-tenant limits, which
# protect a shared service, and the connection limit. Nothing is tuned.
#
# Needs API_JWT_SECRET, METRICS_JWT_SECRET and DASHBOARD_PASSWORD. Set NODE_IP
# and RELEASE_COOKIE to reach it with --probe.
set -euo pipefail

version=${REALTIME_VERSION:-v2.150.2}
postgres=${POSTGRES_IMAGE:-supabase/postgres:17.11.0.007}
port=${PORT:-4000}
pg_port=${PG_PORT:-5432}

docker rm -f realtime realtime-db > /dev/null 2>&1 || true

init=$(mktemp -d)
for file in za-permit-supabase-admin.sh zb-supabase-schema.sql zc-template1-orioledb.sql; do
  curl -fsSLo "$init/$file" "https://raw.githubusercontent.com/supabase/realtime/$version/dev/postgres/$file"
done
chmod -R a+rX "$init"
chmod a+x "$init/za-permit-supabase-admin.sh"

docker run -d --name realtime-db --network host \
  -e POSTGRES_HOST=/var/run/postgresql -e POSTGRES_PASSWORD=postgres \
  -v "$init/za-permit-supabase-admin.sh:/docker-entrypoint-initdb.d/za-permit-supabase-admin.sh" \
  -v "$init/zb-supabase-schema.sql:/docker-entrypoint-initdb.d/zb-supabase-schema.sql" \
  -v "$init/zc-template1-orioledb.sql:/docker-entrypoint-initdb.d/zc-template1-orioledb.sql" \
  "$postgres" postgres -c config_file=/etc/postgresql/postgresql.conf -c "port=$pg_port" > /dev/null

# Postgres restarts once while it initialises, so wait for the schema too.
for _ in $(seq 90); do
  if docker exec realtime-db psql -h 127.0.0.1 -p "$pg_port" -U supabase_admin -d postgres -Atc \
    "select 1 from pg_namespace where nspname = '_realtime'" 2>/dev/null | grep -q 1; then
    break
  fi
  sleep 1
done

docker run -d --name realtime --network host --ulimit nofile=1048576:1048576 \
  -e API_JWT_SECRET -e METRICS_JWT_SECRET -e DASHBOARD_PASSWORD \
  -e DASHBOARD_USER=realtime \
  -e APP_NAME=realtime -e NODE_NAME=realtime \
  -e DB_HOST=127.0.0.1 -e "DB_PORT=$pg_port" -e DB_NAME=postgres \
  -e DB_USER=supabase_admin -e DB_PASSWORD=postgres \
  -e "DB_AFTER_CONNECT_QUERY=SET search_path TO _realtime" \
  -e DB_ENC_KEY=1234567890123456 -e DB_ENC_KEY_GCM=12345678901234567890123456789012 \
  -e DB_ENC_WRITE_GCM=true -e "DNS_NODES=''" \
  -e "ELIXIR_ERL_OPTIONS=+hmax 1000000000" -e "ERL_AFLAGS=-proto_dist inet_tcp" \
  -e GEN_RPC_TCP_CLIENT_PORT=5469 -e GEN_RPC_TCP_SERVER_PORT=5369 \
  -e "PORT=$port" -e REGION=us-east-1 -e RLIMIT_NOFILE=1000000 -e RUN_JANITOR=true \
  -e "SECRET_KEY_BASE=$(head -c 48 /dev/urandom | base64 -w0)" \
  -e SEED_SELF_HOST=true -e SLOT_NAME_SUFFIX=bench \
  -e MAX_CONNECTIONS=1000000 \
  -e TENANT_MAX_CONCURRENT_USERS=1000000 -e TENANT_MAX_EVENTS_PER_SECOND=10000000 \
  -e TENANT_MAX_JOINS_PER_SECOND=100000 -e TENANT_MAX_BYTES_PER_SECOND=2000000000 \
  ${NODE_IP:+-e "POD_IP=$NODE_IP"} ${RELEASE_COOKIE:+-e RELEASE_COOKIE} \
  "supabase/realtime:$version" > /dev/null

for _ in $(seq 90); do
  if curl -fsS -o /dev/null "http://127.0.0.1:$port/healthcheck" 2>/dev/null; then
    echo "Realtime $version is up on port $port"
    exit 0
  fi
  sleep 1
done
echo "Realtime didn't start:"
docker logs --tail 30 realtime
exit 1
