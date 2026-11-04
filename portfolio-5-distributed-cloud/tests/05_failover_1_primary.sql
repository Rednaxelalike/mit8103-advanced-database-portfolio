-- =====================================================================
-- Portfolio 5: Distributed and cloud database
-- 05_failover_1_primary.sql  Failover drill, stage 1 of 3: the last
--                            transfer the primary commits before it fails.
--
-- Run by tests/05_failover.ps1 (see that file and the README); on its own:
--   psql -X -w -U postgres -h localhost -p 5432 -d proclus -v ON_ERROR_STOP=1
--        -f portfolio-5-distributed-cloud/tests/05_failover_1_primary.sql
--
-- Ibrahim Musa (wallet 5) sends NGN 40,000.00 to Tunde Bakare (wallet 9)
-- on the primary. The script then waits until the replica has replayed
-- the transfer, so the drill starts from a known point: this is the last
-- write before the primary goes down, and the question afterwards is
-- whether the promoted replica still has it.
--
-- Re-runnable once the replica has been rebuilt after a drill: it starts
-- by running the Portfolio 1 schema and sample data scripts on the
-- primary, as 02_write_on_primary.sql does, so wallets 5 and 9 always
-- start at NGN 300,000.00 and NGN 265,000.00 and the references are free.
-- This removes the large Portfolio 2 data set from both servers.
-- =====================================================================

\ir ../../portfolio-1-database-design/sql/01_schema.sql
\ir ../../portfolio-1-database-design/sql/02_sample_data.sql

\set ECHO queries

\echo
\echo '=== The primary (port 5432) before the failure ==='
\echo

SELECT inet_server_port() AS port, pg_is_in_recovery() AS in_recovery,
       substr(pg_walfile_name(pg_current_wal_lsn()), 1, 8) AS timeline;

SELECT inet_server_port() AS port, application_name, state, sync_state,
       pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS replay_bytes_behind
FROM pg_stat_replication;

SELECT inet_server_port() AS port, w.wallet_id,
       c.first_name || ' ' || c.last_name AS owner, w.balance
FROM wallets w JOIN customers c USING (customer_id)
WHERE w.wallet_id IN (5, 9)
ORDER BY w.wallet_id;

\echo
\echo 'Ibrahim Musa (wallet 5) sends NGN 40,000.00 to Tunde Bakare (wallet 9).'
\echo

-- The atomic UPDATE with a balance check, the fix Portfolio 3 chose for a
-- wallet, then the transfer and its two ledger legs, in one transaction.
BEGIN;

UPDATE wallets SET balance = balance - 40000.00
WHERE wallet_id = 5 AND balance >= 40000.00
RETURNING wallet_id, balance;

UPDATE wallets SET balance = balance + 40000.00
WHERE wallet_id = 9
RETURNING wallet_id, balance;

INSERT INTO transfers (reference, sender_wallet_id, receiver_wallet_id, amount,
                       narration, status, processed_at)
VALUES ('TRF2611040001', 5, 9, 40000.00, 'Generator repair', 'completed', now())
RETURNING transfer_id, reference, status;

INSERT INTO transactions (reference, wallet_id, transaction_type, amount, transfer_id, narration)
SELECT v.reference, v.wallet_id, v.transaction_type, 40000.00, t.transfer_id, 'Generator repair'
FROM transfers t
CROSS JOIN (VALUES ('TXN2611040001', 5, 'transfer_out'),
                   ('TXN2611040002', 9, 'transfer_in')) AS v (reference, wallet_id, transaction_type)
WHERE t.reference = 'TRF2611040001'
RETURNING transaction_id, reference, wallet_id, transaction_type, amount;

COMMIT;

SELECT inet_server_port() AS port, pg_current_wal_lsn() AS commit_lsn \gset
\echo 'Primary WAL position after the commit:' :commit_lsn

\connect proclus postgres localhost 5433

SELECT set_config('p5.target_lsn', :'commit_lsn', false) AS target_lsn;

-- Wait (at most 60 s) until the replica has replayed the transfer.
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
    RAISE NOTICE 'replica had replayed the transfer after waiting % ms',
        round(extract(epoch FROM clock_timestamp() - started) * 1000, 1);
END
$$;

-- The replica already holds the transfer and both new balances.
SELECT inet_server_port() AS port, pg_is_in_recovery() AS in_recovery,
       reference, sender_wallet_id, receiver_wallet_id, amount, status
FROM transfers
WHERE reference = 'TRF2611040001';

SELECT inet_server_port() AS port, wallet_id, balance
FROM wallets
WHERE wallet_id IN (5, 9)
ORDER BY wallet_id;
