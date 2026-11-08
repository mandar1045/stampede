#!/usr/bin/env bash
# Runs on the database machine during a run-chat.sh run. Every 10 seconds:
# Postgres's own counters (time, connections, commits, rows inserted, fetched
# and updated, blocks read from disk and found in cache), then a "waits" line
# for each thing active sessions were waiting on.
while :; do
  sudo docker exec chat-db psql -U postgres -d chat -At \
    -c "select now(), numbackends, xact_commit, tup_inserted, tup_fetched, tup_updated, blks_read, blks_hit from pg_stat_database where datname = 'chat'" \
    -c "select 'waits', coalesce(wait_event, 'running'), count(*) from pg_stat_activity where datname = 'chat' and state = 'active' group by 2"
  sleep 10
done
