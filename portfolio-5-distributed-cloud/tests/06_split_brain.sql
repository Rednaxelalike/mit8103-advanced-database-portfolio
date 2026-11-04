-- =====================================================================
-- Portfolio 5: Distributed and cloud database
-- 06_split_brain.sql  After the failover drill: what happens if the old
--                     primary simply comes back.
--
-- Run after tests/05_failover.ps1, once the Windows service
-- postgresql-x64-18 has been started again ("After the failover drill",
-- step 1, in setup-replica.md), while port 5433 is still the promoted
-- primary:
--   psql -X -w -U postgres -h localhost -p 5432 -d proclus -v ON_ERROR_STOP=1
--        -f portfolio-5-distributed-cloud/tests/06_split_brain.sql
--
-- Only reads. The old primary restarts on its own, runs crash recovery
-- and accepts writes again. Nothing tells it that port 5433 was promoted,
-- so Proclus now has two primaries that disagree.
-- =====================================================================

\set ECHO queries

\echo
\echo '=== Port 5432: the old primary, restarted ==='
\echo

-- Not in recovery: it accepts writes, on timeline 1.
SELECT inet_server_port() AS port, pg_is_in_recovery() AS in_recovery,
       substr(pg_walfile_name(pg_current_wal_lsn()), 1, 8) AS timeline,
       pg_postmaster_start_time() AS started;

-- It has the transfer it committed before the crash, but not the refund
-- written on port 5433 after the promotion.
SELECT inet_server_port() AS port, reference, sender_wallet_id, receiver_wallet_id, amount, narration
FROM transfers
WHERE reference IN ('TRF2611040001', 'TRF2611040002')
ORDER BY reference;

SELECT inet_server_port() AS port, wallet_id, balance
FROM wallets
WHERE wallet_id IN (5, 9)
ORDER BY wallet_id;

-- The slot is still there but nothing uses it: port 5433 no longer
-- follows this server, and the slot now keeps WAL here for no one.
SELECT inet_server_port() AS port, slot_name, active, restart_lsn
FROM pg_replication_slots;

\echo
\echo '=== Port 5433: the promoted replica ==='
\echo

\connect proclus postgres localhost 5433

SELECT inet_server_port() AS port, pg_is_in_recovery() AS in_recovery,
       substr(pg_walfile_name(pg_current_wal_lsn()), 1, 8) AS timeline;

SELECT inet_server_port() AS port, reference, sender_wallet_id, receiver_wallet_id, amount, narration
FROM transfers
WHERE reference IN ('TRF2611040001', 'TRF2611040002')
ORDER BY reference;

SELECT inet_server_port() AS port, wallet_id, balance
FROM wallets
WHERE wallet_id IN (5, 9)
ORDER BY wallet_id;

-- Both servers would accept the next transfer, each with its own balance
-- and its own next transfer_id: a split brain. Tunde Bakare (wallet 9)
-- holds NGN 305,000.00 on one and NGN 290,000.00 on the other.
