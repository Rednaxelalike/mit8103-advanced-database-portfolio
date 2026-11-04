-- =====================================================================
-- Portfolio 5: Distributed and cloud database
-- 05_failover_3_promoted.sql  Failover drill, stage 3 of 3: the replica
--                             has been promoted with pg_ctl promote and
--                             takes writes as the new primary.
--
-- Run by tests/05_failover.ps1 after the promotion; on its own:
--   psql -X -w -U postgres -h localhost -p 5433 -d proclus -v ON_ERROR_STOP=1
--        -f portfolio-5-distributed-cloud/tests/05_failover_3_promoted.sql
-- =====================================================================

\set ECHO queries

\echo
\echo '=== Port 5433 after pg_ctl promote ==='
\echo

-- No longer in recovery, and on a new timeline. Promotion starts timeline
-- 2, so WAL written from now on can never be confused with WAL the old
-- primary wrote on timeline 1. The first eight characters of a WAL file
-- name are its timeline.
SELECT inet_server_port() AS port, pg_is_in_recovery() AS in_recovery,
       current_setting('transaction_read_only') AS transaction_read_only,
       substr(pg_walfile_name(pg_current_wal_lsn()), 1, 8) AS timeline;

-- Nothing was lost: the last transfer the old primary committed is here.
SELECT inet_server_port() AS port, reference, sender_wallet_id, receiver_wallet_id,
       amount, status
FROM transfers
WHERE reference = 'TRF2611040001';

SELECT inet_server_port() AS port, wallet_id, balance
FROM wallets
WHERE wallet_id IN (5, 9)
ORDER BY wallet_id;

\echo
\echo 'Tunde Bakare (wallet 9) sends NGN 15,000.00 back to Ibrahim Musa (wallet 5), on the new primary.'
\echo

BEGIN;

UPDATE wallets SET balance = balance - 15000.00
WHERE wallet_id = 9 AND balance >= 15000.00
RETURNING wallet_id, balance;

UPDATE wallets SET balance = balance + 15000.00
WHERE wallet_id = 5
RETURNING wallet_id, balance;

INSERT INTO transfers (reference, sender_wallet_id, receiver_wallet_id, amount,
                       narration, status, processed_at)
VALUES ('TRF2611040002', 9, 5, 15000.00, 'Refund for extra diesel', 'completed', now())
RETURNING transfer_id, reference, status;

INSERT INTO transactions (reference, wallet_id, transaction_type, amount, transfer_id, narration)
SELECT v.reference, v.wallet_id, v.transaction_type, 15000.00, t.transfer_id, 'Refund for extra diesel'
FROM transfers t
CROSS JOIN (VALUES ('TXN2611040003', 9, 'transfer_out'),
                   ('TXN2611040004', 5, 'transfer_in')) AS v (reference, wallet_id, transaction_type)
WHERE t.reference = 'TRF2611040002'
RETURNING transaction_id, reference, wallet_id, transaction_type, amount;

COMMIT;

SELECT inet_server_port() AS port, wallet_id, balance
FROM wallets
WHERE wallet_id IN (5, 9)
ORDER BY wallet_id;

-- The new primary has no replica of its own: until one is rebuilt, a
-- second failure would lose everything written since the promotion.
SELECT count(*) AS replicas_connected FROM pg_stat_replication;

\echo
\echo '=== Balance audit on the new primary: every stored balance equals its ledger total ==='

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
