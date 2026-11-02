-- =====================================================================
-- Portfolio 5: Distributed and cloud database
-- 01_replication_status.sql  Shows that the port-5433 replica is connected
--                            to the port-5432 primary and streaming WAL,
--                            seen from both ends.
--
-- Needs the replica built and started as in setup-replica.md.
-- Run from the repo root (see SETUP.md for loading PGPASSWORD):
--   psql -X -w -U postgres -h localhost -p 5432 -d proclus -v ON_ERROR_STOP=1
--        -f portfolio-5-distributed-cloud/tests/01_replication_status.sql
--
-- Read-only: it changes nothing on either server, so it can be run at any
-- time. Every query prints inet_server_port(), so each result shows which
-- server answered it.
-- =====================================================================

\set ECHO queries

\echo
\echo '=== Part 1: the primary (port 5432) ==='
\echo

-- The settings streaming replication depends on. wal_level = replica makes
-- the primary write enough WAL for a standby to replay; max_wal_senders
-- allows the connection; an empty synchronous_standby_names means commits
-- do not wait for the replica (asynchronous replication).
SELECT inet_server_port() AS port, pg_is_in_recovery() AS in_recovery,
       current_setting('wal_level')                 AS wal_level,
       current_setting('max_wal_senders')           AS max_wal_senders,
       current_setting('synchronous_commit')        AS synchronous_commit,
       current_setting('synchronous_standby_names') AS synchronous_standby_names;

-- One row per connected standby. state = streaming means the replica has
-- caught up with the backlog and now receives WAL as it is written;
-- sync_state = async means the primary does not wait for it.
SELECT inet_server_port() AS port, pid, usename, application_name, client_addr,
       state, sync_state, backend_start
FROM pg_stat_replication;

-- How far the replica has got, as WAL positions (LSNs) and as bytes behind
-- the primary's current position. sent = sent by the primary; write/flush =
-- written / flushed to disk by the replica; replay = applied, so visible to
-- queries there. The *_lag columns are NULL once the replica has been idle
-- and fully caught up.
SELECT inet_server_port() AS port,
       pg_current_wal_lsn() AS primary_lsn, sent_lsn, write_lsn, flush_lsn, replay_lsn,
       pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS replay_bytes_behind,
       write_lag, flush_lag, replay_lag
FROM pg_stat_replication;

-- The slot created by pg_basebackup -C -S. While it exists the primary
-- keeps every WAL file the replica has not yet confirmed, even if the
-- replica is down; active = t means the replica is using it now.
SELECT inet_server_port() AS port, slot_name, slot_type, active, active_pid,
       restart_lsn, wal_status
FROM pg_replication_slots;

-- Row counts on the primary, to compare with the same query on the replica.
SELECT inet_server_port() AS port,
       (SELECT count(*) FROM customers)    AS customers,
       (SELECT count(*) FROM wallets)      AS wallets,
       (SELECT count(*) FROM transfers)    AS transfers,
       (SELECT count(*) FROM transactions) AS ledger_rows;

\echo
\echo '=== Part 2: the replica (port 5433) ==='
\echo

\connect proclus postgres localhost 5433

-- pg_is_in_recovery() = t: the server is a standby, replaying WAL it
-- receives instead of accepting its own writes. hot_standby = on lets it
-- answer queries meanwhile, and every transaction it runs is read-only
-- (transaction_read_only = on, although the default setting says off).
SELECT inet_server_port() AS port, pg_is_in_recovery() AS in_recovery,
       current_setting('cluster_name')          AS cluster_name,
       current_setting('hot_standby')           AS hot_standby,
       current_setting('transaction_read_only') AS transaction_read_only,
       current_setting('primary_slot_name')     AS primary_slot_name;

-- The WAL receiver: the process that holds the connection to the primary.
SELECT inet_server_port() AS port, pid, status, sender_host, sender_port, slot_name,
       received_tli, written_lsn, flushed_lsn, last_msg_receipt_time
FROM pg_stat_wal_receiver;

-- What the replica has received and applied, and the commit time (on the
-- primary) of the last transaction it replayed.
SELECT inet_server_port() AS port,
       pg_last_wal_receive_lsn() AS received_lsn,
       pg_last_wal_replay_lsn()  AS replayed_lsn,
       pg_last_xact_replay_timestamp() AS last_replayed_commit,
       pg_get_wal_replay_pause_state() AS replay_state;

-- The same row counts as on the primary, read from the replica.
SELECT inet_server_port() AS port,
       (SELECT count(*) FROM customers)    AS customers,
       (SELECT count(*) FROM wallets)      AS wallets,
       (SELECT count(*) FROM transfers)    AS transfers,
       (SELECT count(*) FROM transactions) AS ledger_rows;
