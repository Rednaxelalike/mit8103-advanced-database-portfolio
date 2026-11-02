-- =====================================================================
-- Portfolio 5: Distributed and cloud database
-- 02_write_on_primary.sql  A write on the primary appears on the replica,
--                          and a read from a replica that is behind
--                          returns an old balance.
--
-- Needs the replica built and started as in setup-replica.md.
-- Run from the repo root (see SETUP.md for loading PGPASSWORD):
--   psql -X -w -U postgres -h localhost -p 5432 -d proclus -v ON_ERROR_STOP=1
--        -f portfolio-5-distributed-cloud/tests/02_write_on_primary.sql
--
-- Re-runnable: it starts by running the Portfolio 1 schema and sample data
-- scripts on the primary, which drop and rebuild all eight tables. The
-- replica cannot run them itself; it receives the rebuild as WAL like any
-- other change. This removes the large Portfolio 2 data set from both.
--
-- The script switches server with \connect: port 5432 is the primary,
-- port 5433 the replica. Every query prints inet_server_port().
--
-- Part 1: Chinedu Okafor funds wallet 1 on the primary; the funding then
--         shows on the wallet's statement read from the replica.
-- Part 2: replay on the replica is paused, as if it had fallen behind.
--         A merchant payment on the primary is then missing from the
--         replica, which still shows the old balance. This is why Proclus
--         reads statements from the replica but balances from the primary.
-- =====================================================================

\ir ../../portfolio-1-database-design/sql/01_schema.sql
\ir ../../portfolio-1-database-design/sql/02_sample_data.sql

\set ECHO queries

\echo
\echo '=== Part 1: a funding on the primary appears on the replica ==='
\echo 'Chinedu Okafor (wallet 1) tops up NGN 50,000.00 by bank transfer.'
\echo

SELECT inet_server_port() AS port, w.wallet_id,
       c.first_name || ' ' || c.last_name AS owner, w.balance
FROM wallets w JOIN customers c USING (customer_id)
WHERE w.wallet_id = 1;

BEGIN;

INSERT INTO transactions (reference, wallet_id, transaction_type, amount, narration)
VALUES ('TXN2611020001', 1, 'funding', 50000.00, 'Bank transfer top-up')
RETURNING transaction_id, reference, transaction_type, amount;

UPDATE wallets SET balance = balance + 50000.00
WHERE wallet_id = 1
RETURNING wallet_id, balance;

COMMIT;

-- The WAL position just after the COMMIT. Once the replica has replayed
-- up to here, the funding is visible there. It is kept in a psql variable
-- and passed to the replica through a session setting.
SELECT inet_server_port() AS port, pg_current_wal_lsn() AS commit_lsn \gset
\echo 'Primary WAL position after the commit:' :commit_lsn

\connect proclus postgres localhost 5433

SELECT set_config('p5.target_lsn', :'commit_lsn', false) AS target_lsn;

-- Wait (at most 60 s) until the replica has replayed the commit, and print
-- how long that took. The reconnection above already takes a few
-- milliseconds, so the wait is usually close to zero. It is longer when
-- the replica is still replaying the rebuild: dropping Portfolio 2's large
-- tables once held replay up for about 10 s. 04_replication_lag.sql
-- measures the lag properly.
DO $$
DECLARE
    started timestamptz := clock_timestamp();
BEGIN
    WHILE pg_last_wal_replay_lsn() < current_setting('p5.target_lsn')::pg_lsn LOOP
        IF clock_timestamp() - started > interval '60 seconds' THEN
            RAISE EXCEPTION 'replica did not reach % within 60 s', current_setting('p5.target_lsn');
        END IF;
        PERFORM pg_sleep(0.005);
    END LOOP;
    RAISE NOTICE 'replica had replayed the commit after waiting % ms',
        round(extract(epoch FROM clock_timestamp() - started) * 1000, 1);
END
$$;

SELECT inet_server_port() AS port, pg_last_wal_replay_lsn() AS replayed_lsn,
       pg_last_wal_replay_lsn() >= current_setting('p5.target_lsn')::pg_lsn AS commit_replayed,
       pg_last_xact_replay_timestamp() AS commit_time_on_primary;

-- Chinedu's statement for November, read from the replica: the funding is
-- there, with the same transaction_id the primary gave it.
SELECT inet_server_port() AS port, transaction_id, reference, transaction_type, amount,
       narration, created_at
FROM transactions
WHERE wallet_id = 1 AND created_at >= '2026-11-01'
ORDER BY created_at, transaction_id;

SELECT inet_server_port() AS port, wallet_id, balance FROM wallets WHERE wallet_id = 1;

\echo
\echo '=== Part 2: a replica that is behind returns the old balance ==='
\echo

-- Pause replay on the replica. It keeps receiving WAL from the primary but
-- stops applying it, which is what a replica under heavy load or after a
-- network delay looks like to a reader. Wait until the pause has started.
SELECT inet_server_port() AS port, pg_wal_replay_pause();

DO $$
DECLARE
    started timestamptz := clock_timestamp();
BEGIN
    WHILE pg_get_wal_replay_pause_state() <> 'paused' LOOP
        IF clock_timestamp() - started > interval '10 seconds' THEN
            RAISE EXCEPTION 'replay did not pause within 10 s';
        END IF;
        PERFORM pg_sleep(0.005);
    END LOOP;
END
$$;

SELECT inet_server_port() AS port, pg_get_wal_replay_pause_state() AS replay_state;

\echo 'Chinedu pays NGN 18,000.00 at Lekki Fresh Mart (merchant 1), on the primary.'

\connect proclus postgres localhost 5432

BEGIN;

INSERT INTO transactions (reference, wallet_id, transaction_type, amount, merchant_id, narration)
VALUES ('TXN2611020002', 1, 'merchant_payment', 18000.00, 1, 'Weekly groceries')
RETURNING transaction_id, reference, transaction_type, amount;

UPDATE wallets SET balance = balance - 18000.00
WHERE wallet_id = 1
RETURNING wallet_id, balance;

COMMIT;

SELECT inet_server_port() AS port, pg_current_wal_lsn() AS commit_lsn \gset
\echo 'Primary WAL position after the commit:' :commit_lsn

-- The primary's answer: NGN 134,549.50.
SELECT inet_server_port() AS port, wallet_id, balance FROM wallets WHERE wallet_id = 1;

\connect proclus postgres localhost 5433

SELECT set_config('p5.target_lsn', :'commit_lsn', false) AS target_lsn;

-- Give the WAL time to arrive. The replica has received the payment
-- (received_lsn has passed the commit) but has not applied it.
SELECT pg_sleep(1);

SELECT inet_server_port() AS port, pg_get_wal_replay_pause_state() AS replay_state,
       pg_last_wal_receive_lsn() AS received_lsn,
       pg_last_wal_replay_lsn()  AS replayed_lsn,
       pg_wal_lsn_diff(current_setting('p5.target_lsn')::pg_lsn,
                       pg_last_wal_replay_lsn()) AS replay_bytes_behind;

-- The replica's answer: still NGN 152,549.50, and the payment is missing
-- from the statement. A customer shown this balance could try to spend
-- NGN 18,000.00 that has already gone.
SELECT inet_server_port() AS port, wallet_id, balance FROM wallets WHERE wallet_id = 1;

SELECT inet_server_port() AS port, transaction_id, reference, transaction_type, amount,
       narration, created_at
FROM transactions
WHERE wallet_id = 1 AND created_at >= '2026-11-01'
ORDER BY created_at, transaction_id;

-- Resume replay and wait until the payment has been applied.
SELECT inet_server_port() AS port, pg_wal_replay_resume();

DO $$
DECLARE
    started timestamptz := clock_timestamp();
BEGIN
    WHILE pg_last_wal_replay_lsn() < current_setting('p5.target_lsn')::pg_lsn LOOP
        IF clock_timestamp() - started > interval '60 seconds' THEN
            RAISE EXCEPTION 'replica did not reach % within 60 s', current_setting('p5.target_lsn');
        END IF;
        PERFORM pg_sleep(0.005);
    END LOOP;
    RAISE NOTICE 'replica applied the payment % ms after replay resumed',
        round(extract(epoch FROM clock_timestamp() - started) * 1000, 1);
END
$$;

-- Caught up: the same balance and statement as the primary.
SELECT inet_server_port() AS port, pg_get_wal_replay_pause_state() AS replay_state,
       pg_last_wal_replay_lsn() AS replayed_lsn;

SELECT inet_server_port() AS port, wallet_id, balance FROM wallets WHERE wallet_id = 1;

SELECT inet_server_port() AS port, transaction_id, reference, transaction_type, amount,
       narration, created_at
FROM transactions
WHERE wallet_id = 1 AND created_at >= '2026-11-01'
ORDER BY created_at, transaction_id;

\echo
\echo '=== Balance audit on the replica: every stored balance equals its ledger total ==='

-- The audit from 02_sample_data.sql, run on the replica: it is a full,
-- consistent copy, so the two writes above balance there too.
SELECT inet_server_port() AS port, count(*) AS wallets_checked,
       count(*) FILTER (WHERE w.balance <> coalesce(l.ledger_balance, 0)) AS mismatches
FROM wallets w
LEFT JOIN (
    SELECT wallet_id,
           sum(CASE WHEN transaction_type IN ('funding', 'transfer_in', 'reversal')
                    THEN amount ELSE -amount END) AS ledger_balance
    FROM transactions
    WHERE status = 'completed'
    GROUP BY wallet_id
) l USING (wallet_id);
