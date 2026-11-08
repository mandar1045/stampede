-- Fills the database with a realistic amount of chat history, fast.
--
--     psql "$DATABASE_URL" -v users=1000000 -v rooms=10000 -v messages=100000000 -f priv/repo/seed.sql
--
-- The message indexes are dropped while loading and built again afterwards, which
-- is how you'd load this much data.
\timing on
TRUNCATE room_reads, messages, rooms, users RESTART IDENTITY CASCADE;

INSERT INTO users (name) SELECT 'user ' || i FROM generate_series(1, :users) i;
INSERT INTO rooms (name) SELECT 'room ' || i FROM generate_series(1, :rooms) i;

DROP INDEX IF EXISTS messages_room_id_id_index;
DROP INDEX IF EXISTS messages_user_id_index;
ALTER TABLE messages DROP CONSTRAINT IF EXISTS messages_room_id_fkey;
ALTER TABLE messages DROP CONSTRAINT IF EXISTS messages_user_id_fkey;

INSERT INTO messages (room_id, user_id, body, inserted_at)
SELECT 1 + (random() * (:rooms - 1))::int,
       1 + (random() * (:users - 1))::int,
       'Message ' || i || ': ' || md5(i::text) || ' ' || left(md5((i * 7)::text), 16),
       now() - make_interval(secs => (:messages - i))
FROM generate_series(1, :messages) i;

CREATE INDEX messages_room_id_id_index ON messages (room_id, id);
CREATE INDEX messages_user_id_index ON messages (user_id);
ALTER TABLE messages ADD CONSTRAINT messages_room_id_fkey FOREIGN KEY (room_id) REFERENCES rooms (id) NOT VALID;
ALTER TABLE messages ADD CONSTRAINT messages_user_id_fkey FOREIGN KEY (user_id) REFERENCES users (id) NOT VALID;
VACUUM ANALYZE;

SELECT count(*) AS messages, pg_size_pretty(pg_total_relation_size('messages')) AS size FROM messages;
