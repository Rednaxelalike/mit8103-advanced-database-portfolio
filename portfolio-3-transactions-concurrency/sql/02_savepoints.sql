-- =====================================================================
-- Portfolio 3: Transactions and concurrency
-- 02_savepoints.sql  A batch of three payments in one transaction. The
--                    second payment fails; the transaction rolls back to
--                    a savepoint, records the failure, and commits the
--                    rest.
--
-- Run from the repo root (see SETUP.md for loading PGPASSWORD):
--   psql -X -w -U postgres -h localhost -p 5432 -d proclus -v ON_ERROR_STOP=1
--        -f portfolio-3-transactions-concurrency/sql/02_savepoints.sql
--
-- Re-runnable: like 01_commit_rollback.sql, it starts by rebuilding the
-- Portfolio 1 schema and sample data, so it does not depend on 01.
--
-- Why a savepoint: in 01_commit_rollback.sql one error aborted the whole
-- transaction, and ROLLBACK threw away everything since BEGIN. In a batch
-- that is too much. A SAVEPOINT marks a point inside the transaction;
-- ROLLBACK TO SAVEPOINT undoes only the work done after that mark, clears
-- the error, and lets the transaction carry on. Nothing is visible to
-- other sessions until the final COMMIT.
--
-- Scenario: Segun Afolabi (wallet 17, NGN 225,000.00) sends October
-- allowances in one batch:
--   payment 1  NGN 100,000.00 to Chiamaka Obi    (wallet 10)  succeeds
--   payment 2  NGN 150,000.00 to Hauwa Ibrahim   (wallet 14)  fails: only 125,000.00 left
--   payment 3  NGN  50,000.00 to Folake Akinwale (wallet 20)  succeeds
-- =====================================================================

\ir ../../portfolio-1-database-design/sql/01_schema.sql
\ir ../../portfolio-1-database-design/sql/02_sample_data.sql

-- From here on, psql prints each statement before its result.
\set ECHO queries

\echo
\echo '=== Before the batch ==='

SELECT w.wallet_id, c.first_name || ' ' || c.last_name AS owner, w.balance
FROM wallets w JOIN customers c USING (customer_id)
WHERE w.wallet_id IN (17, 10, 14, 20)
ORDER BY w.balance DESC, w.wallet_id;

BEGIN;

\echo
\echo '=== Payment 1: NGN 100,000.00 from wallet 17 to wallet 10 ==='

INSERT INTO transfers (reference, sender_wallet_id, receiver_wallet_id, amount,
                       narration, status, processed_at)
VALUES ('TRF2610190001', 17, 10, 100000.00, 'October allowance', 'completed', now())
RETURNING transfer_id, reference, status;

UPDATE wallets SET balance = balance - 100000.00
WHERE wallet_id = 17
RETURNING wallet_id, balance;

UPDATE wallets SET balance = balance + 100000.00
WHERE wallet_id = 10
RETURNING wallet_id, balance;

INSERT INTO transactions (reference, wallet_id, transaction_type, amount, transfer_id, narration)
SELECT v.reference, v.wallet_id, v.transaction_type, 100000.00, t.transfer_id, 'October allowance'
FROM transfers t
CROSS JOIN (VALUES ('TXN2610190001', 17, 'transfer_out'),
                   ('TXN2610190002', 10, 'transfer_in')) AS v (reference, wallet_id, transaction_type)
WHERE t.reference = 'TRF2610190001'
RETURNING transaction_id, reference, wallet_id, transaction_type, amount;

\echo
\echo '=== Payment 2: NGN 150,000.00 from wallet 17 to wallet 14 ==='

-- Mark the point to come back to if this payment fails. Payment 1 is
-- before the mark, so it is safe.
SAVEPOINT before_payment_2;

-- The next statement fails on purpose. Let psql carry on after the error,
-- then switch the safety catch back on.
\set ON_ERROR_STOP off

INSERT INTO transfers (reference, sender_wallet_id, receiver_wallet_id, amount,
                       narration, status, processed_at)
VALUES ('TRF2610190002', 17, 14, 150000.00, 'October allowance', 'completed', now())
RETURNING transfer_id, reference, status;

-- Wallet 17 has 125,000.00 left after payment 1, so this debit would leave
-- it at -25,000.00. The CHECK constraint wallets_balance_non_negative
-- rejects it and the transaction enters the failed state.
UPDATE wallets SET balance = balance - 150000.00
WHERE wallet_id = 17
RETURNING wallet_id, balance;

-- Still in the failed state: even a read is refused.
SELECT balance FROM wallets WHERE wallet_id = 17;

-- Undo only the work after the savepoint: the transfers row for payment 2.
-- Payment 1 stays, and the transaction is usable again.
ROLLBACK TO SAVEPOINT before_payment_2;

\set ON_ERROR_STOP on

-- The same read now works, and shows payment 1 is still in place.
SELECT balance FROM wallets WHERE wallet_id = 17;

-- Record the failure, as Proclus does for every rejected transfer (compare
-- transfer 10 in the sample data). The rolled-back insert left no row
-- behind, so the same reference is free to use again. No money moves, so
-- there are no ledger rows.
INSERT INTO transfers (reference, sender_wallet_id, receiver_wallet_id, amount,
                       narration, status, failure_reason, processed_at)
VALUES ('TRF2610190002', 17, 14, 150000.00, 'October allowance', 'failed',
        'Insufficient funds', now())
RETURNING transfer_id, reference, status, failure_reason;

INSERT INTO audit_log (entity_type, entity_id, action, actor_type, actor_ref, details)
SELECT 'transfer', transfer_id, 'failed', 'system', 'transfer-engine',
       'Insufficient funds: balance NGN 125000.00, requested NGN 150000.00'
FROM transfers
WHERE reference = 'TRF2610190002'
RETURNING audit_id, entity_type, entity_id, action, details;

\echo
\echo '=== Payment 3: NGN 50,000.00 from wallet 17 to wallet 20 ==='

SAVEPOINT before_payment_3;

INSERT INTO transfers (reference, sender_wallet_id, receiver_wallet_id, amount,
                       narration, status, processed_at)
VALUES ('TRF2610190003', 17, 20, 50000.00, 'October allowance', 'completed', now())
RETURNING transfer_id, reference, status;

UPDATE wallets SET balance = balance - 50000.00
WHERE wallet_id = 17
RETURNING wallet_id, balance;

UPDATE wallets SET balance = balance + 50000.00
WHERE wallet_id = 20
RETURNING wallet_id, balance;

INSERT INTO transactions (reference, wallet_id, transaction_type, amount, transfer_id, narration)
SELECT v.reference, v.wallet_id, v.transaction_type, 50000.00, t.transfer_id, 'October allowance'
FROM transfers t
CROSS JOIN (VALUES ('TXN2610190003', 17, 'transfer_out'),
                   ('TXN2610190004', 20, 'transfer_in')) AS v (reference, wallet_id, transaction_type)
WHERE t.reference = 'TRF2610190003'
RETURNING transaction_id, reference, wallet_id, transaction_type, amount;

-- Payment 3 went through, so its savepoint is no longer needed.
RELEASE SAVEPOINT before_payment_3;

-- One COMMIT makes payments 1 and 3 and the failure record permanent
-- together.
COMMIT;

\echo
\echo '=== After COMMIT ==='

-- Wallet 17: 225,000 - 100,000 - 50,000 = 75,000. Wallet 14 is unchanged.
SELECT wallet_id, balance FROM wallets
WHERE wallet_id IN (17, 10, 14, 20)
ORDER BY wallet_id;

-- The batch: two completed transfers with two ledger rows each, and one
-- failed transfer with none. Payment 2's first insert used up an id before
-- it was rolled back (sequences never go backwards), so the failure record
-- has the next id.
SELECT t.transfer_id, t.reference, t.receiver_wallet_id, t.amount, t.status,
       t.failure_reason, count(x.transaction_id) AS ledger_rows
FROM transfers t
LEFT JOIN transactions x USING (transfer_id)
WHERE t.reference LIKE 'TRF261019%'
GROUP BY t.transfer_id
ORDER BY t.transfer_id;

\echo
\echo '=== Balance audit: every stored balance still equals its ledger total ==='

-- The same check as at the end of 02_sample_data.sql: completed credits
-- minus completed debits, compared with wallets.balance.
SELECT count(*) AS wallets_checked,
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
