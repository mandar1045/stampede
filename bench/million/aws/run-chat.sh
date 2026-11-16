#!/usr/bin/env bash
# Load tests the chat app with a real Postgres on its own machine, full of chat
# history, and keeps Postgres's own numbers from before, during and after.
#
#     PROOF=1 STEP_RAMP=120 ./run-chat.sh --find-limit --start 50000 --step 50000 --up-to 600000 --hold 60s
#
# Postgres is the official postgres:17 image with its default settings, and the
# app keeps Ecto's default pool of 10. USERS, ROOMS and MESSAGES set how much is
# seeded, and SEED=0 skips seeding a database that's already full.
#
# POOL_SIZE sets the app's pool, and PG_CONF gives Postgres settings, such as
#
#     SEED=0 POOL_SIZE=32 PG_CONF="-c shared_buffers=16GB -c random_page_cost=1.1" ./run-chat.sh ...
#
# A different PG_CONF than the running Postgres's starts it again with the
# same data, so the messages don't have to be seeded again.
#
# FANOUT picks how a message reaches its room, broadcast (the default), ids or
# batch, with FANOUT_WINDOW for batch, see Chat.Fanout.
set -euo pipefail
source "$(dirname "$0")/config.sh"

USERS=${USERS:-1000000}
ROOMS=${ROOMS:-10000}
MESSAGES=${MESSAGES:-100000000}
POOL_SIZE=${POOL_SIZE:-10}
PG_CONF=${PG_CONF:-}
FANOUT=${FANOUT:-broadcast}
FANOUT_WINDOW=${FANOUT_WINDOW:-500}

read -r _ _ server_public server_private _ < <(nodes server)
read -r _ _ db_public db_private _ < <(nodes db)
[ -f "$STATE/db-password" ] || head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' > "$STATE/db-password"
password=$(cat "$STATE/db-password")
url="ecto://postgres:$password@$db_private:5432/chat"
psql() { on "$db_public" "sudo docker exec -i chat-db psql -U postgres -d chat -At $*"; }

echo "Starting Postgres on $db_private"
on "$db_public" "command -v docker > /dev/null || { sudo apt-get -o DPkg::Lock::Timeout=180 update -qq > /dev/null
    sudo DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=180 install -y -qq docker.io > /dev/null; }
  current=\$(sudo docker inspect -f '{{index .Config.Labels \"stampede.conf\"}}' chat-db 2> /dev/null || echo none)
  if [ \"\$current\" != '$PG_CONF' ]; then
    sudo docker rm -f chat-db > /dev/null 2>&1 || true
    sudo docker run -d --name chat-db --network host --shm-size=1g --label stampede.conf='$PG_CONF' \
      -e POSTGRES_PASSWORD=$password -v /var/lib/chat-db:/var/lib/postgresql/data postgres:17 $PG_CONF > /dev/null
  fi
  until sudo docker exec chat-db pg_isready -U postgres > /dev/null 2>&1; do sleep 1; done"

echo "Creating the tables"
on "$server_public" "cd stampede/bench/million/chat && MIX_ENV=prod DATABASE_URL='$url' SECRET_KEY_BASE=unused-for-migrations-$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n') \
  mix do ecto.create + ecto.migrate 2>&1 | tail -2"

if [ "${SEED:-1}" = 1 ]; then
  echo "Seeding $USERS users, $ROOMS rooms and $MESSAGES messages (this takes a while)"
  scp -q "${SSH_OPTS[@]}" "$HERE/../chat/priv/repo/seed.sql" "ubuntu@$db_public:seed.sql"
  on "$db_public" "sudo docker exec -i chat-db psql -U postgres -d chat -v users=$USERS -v rooms=$ROOMS -v messages=$MESSAGES < seed.sql > seed.log 2>&1; tail -4 seed.log"
fi

stats="select now(), numbackends, xact_commit, tup_inserted, tup_fetched, tup_updated, blks_read, blks_hit from pg_stat_database where datname = 'chat'"
size="select count(*), pg_size_pretty(pg_database_size('chat')), pg_size_pretty(pg_total_relation_size('messages')) from messages"
settings="select name, current_setting(name) from pg_settings where name in ('shared_buffers', 'effective_cache_size', 'work_mem', 'random_page_cost', 'max_wal_size', 'max_connections', 'synchronous_commit', 'wal_level') order by name"

# The run's own name, so Postgres's numbers land next to everything else.
before=$(mktemp)
{ echo "# the app's pool: $POOL_SIZE, fan-out: $FANOUT$([ "$FANOUT" = batch ] && echo " every ${FANOUT_WINDOW}ms")"
  echo "# Postgres settings: ${PG_CONF:-none, the defaults of the image}"; psql -c "\"$settings\""
  echo "# before the run: messages, database size, messages table size"; psql -c "\"$size\""
  echo "# pg_stat_database: time, connections, commits, rows inserted, fetched, updated, blocks read, blocks from cache"; psql -c "\"$stats\""; } > "$before"
# A script of its own, as the query's quotes don't survive being nested in ssh.
scp -q "${SSH_OPTS[@]}" "$HERE/db-stats.sh" "ubuntu@$db_public:db-stats.sh"
on "$db_public" "setsid nohup bash db-stats.sh > db-stats.log 2>&1 < /dev/null &"

APP=chat APP_ENV="DATABASE_URL='$url' POOL_SIZE=$POOL_SIZE FANOUT=$FANOUT FANOUT_WINDOW=$FANOUT_WINDOW" \
  LOAD_ENV="USERS=$USERS ROOMS=$ROOMS FANOUT=$FANOUT" \
  "$HERE/run.sh" chat_db 0 0 0 "$@"

out=$(ls -dt "$RESULTS"/*-chat_db-0 | head -1)
on "$db_public" "pkill -f '[d]b-stats[.]sh'; true"
mv "$before" "$out/db-before.txt"
{ echo "# after the run: messages, database size, messages table size"; psql -c "\"$size\""
  echo "# pg_stat_database: time, connections, commits, rows inserted, fetched, updated, blocks read, blocks from cache"; psql -c "\"$stats\""; } > "$out/db-after.txt"
on "$db_public" 'cat db-stats.log' > "$out/db-stats.log"
on "$db_public" 'cat seed.log 2>/dev/null' > "$out/db-seed.log" || true
on "$db_public" 'sudo docker logs --tail 200 chat-db 2>&1' > "$out/postgres.log"
grep -l "$password" "$out"/* 2>/dev/null && echo "WARNING: the database password is in a result file" || true
echo "Postgres numbers in $out"
