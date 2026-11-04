-- =====================================================================
-- Portfolio 5: Distributed and cloud database
-- 05_failover_2_standby_alone.sql  Failover drill, stage 2 of 3: the
--                                  primary has failed and the replica has
--                                  not been promoted yet.
--
-- Run by tests/05_failover.ps1 after it has stopped the primary; on its own:
--   psql -X -w -U postgres -h localhost -p 5433 -d proclus
--        -f portfolio-5-distributed-cloud/tests/05_failover_2_standby_alone.sql
--
-- ON_ERROR_STOP stays off: the write at the end fails on purpose.
-- =====================================================================

\set ON_ERROR_STOP off
\set ECHO queries

\echo
\echo '=== The replica (port 5433) with the primary down ==='
\echo

-- Still a standby. The WAL receiver has lost its connection, so
-- pg_stat_wal_receiver has no row, but everything received before the
-- failure is applied.
SELECT inet_server_port() AS port, pg_is_in_recovery() AS in_recovery,
       pg_last_wal_receive_lsn() AS received_lsn,
       pg_last_wal_replay_lsn()  AS replayed_lsn,
       pg_last_xact_replay_timestamp() AS last_replayed_commit;

SELECT count(*) AS wal_receivers_connected FROM pg_stat_wal_receiver;

-- Reads still work: statements can still be served during the outage.
SELECT inet_server_port() AS port, transaction_id, reference, transaction_type, amount, narration
FROM transactions
WHERE wallet_id = 9 AND created_at >= '2026-11-01'
ORDER BY created_at, transaction_id;

-- Writes do not: until someone promotes the replica, Proclus cannot fund
-- a wallet, move money or take a payment.
\echo '--- A transfer attempted on the standby'
UPDATE wallets SET balance = balance - 15000.00 WHERE wallet_id = 9 AND balance >= 15000.00;
\echo 'SQLSTATE:' :LAST_ERROR_SQLSTATE
