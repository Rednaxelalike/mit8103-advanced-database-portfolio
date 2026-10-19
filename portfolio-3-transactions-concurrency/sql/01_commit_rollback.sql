-- =====================================================================
-- Portfolio 3: Transactions and concurrency
-- 01_commit_rollback.sql  A wallet transfer as one transaction: one that
--                         commits, and one that fails for lack of funds
--                         and rolls back with every balance unchanged.
--
-- Run from the repo root (see SETUP.md for loading PGPASSWORD):
--   psql -X -w -U postgres -h localhost -p 5432 -d proclus -v ON_ERROR_STOP=1
--        -f portfolio-3-transactions-concurrency/sql/01_commit_rollback.sql
--
-- Re-runnable: it starts by running the Portfolio 1 schema and sample data
-- scripts, which drop and rebuild all eight tables, so the 25 sample
-- wallets always start from the same balances. This removes the large
-- Portfolio 2 data set; 01_seed_large.sql rebuilds it.
--
-- A transfer writes rows in three tables, and they must all change
-- together or not at all:
--   1. a transfers row          (the request and its outcome)
--   2. the sender's balance     (debit)
--   3. the receiver's balance   (credit)
--   4. two ledger rows          (transfer_out and transfer_in)
-- If the database stopped after step 2, money would leave one wallet and
-- arrive nowhere. Wrapping the steps in BEGIN ... COMMIT makes them atomic:
-- other sessions see either none of the changes or all of them.
-- =====================================================================

\ir ../../portfolio-1-database-design/sql/01_schema.sql
\ir ../../portfolio-1-database-design/sql/02_sample_data.sql

-- From here on, psql prints each statement before its result.
\set ECHO queries

\echo
\echo '=== Part 1: a transfer that commits ==='
\echo 'Oluwaseun Adeyemi (wallet 3) sends NGN 25,000.00 to Funmilayo Adebayo (wallet 6).'
\echo

SELECT w.wallet_id, c.first_name || ' ' || c.last_name AS owner, w.balance
FROM wallets w JOIN customers c USING (customer_id)
WHERE w.wallet_id IN (3, 6)
ORDER BY w.wallet_id;

BEGIN;

-- The transfer is written as completed straight away: no other session can
-- see it until COMMIT, and by then the money has moved. now() is fixed for
-- the whole transaction, so created_at and processed_at are equal.
INSERT INTO transfers (reference, sender_wallet_id, receiver_wallet_id, amount,
                       narration, status, processed_at)
VALUES ('TRF2610190001', 3, 6, 25000.00, 'Rent share', 'completed', now())
RETURNING transfer_id, reference, status;

UPDATE wallets SET balance = balance - 25000.00
WHERE wallet_id = 3
RETURNING wallet_id, balance;

UPDATE wallets SET balance = balance + 25000.00
WHERE wallet_id = 6
RETURNING wallet_id, balance;

INSERT INTO transactions (reference, wallet_id, transaction_type, amount, transfer_id, narration)
SELECT v.reference, v.wallet_id, v.transaction_type, 25000.00, t.transfer_id, 'Rent share'
FROM transfers t
CROSS JOIN (VALUES ('TXN2610190001', 3, 'transfer_out'),
                   ('TXN2610190002', 6, 'transfer_in')) AS v (reference, wallet_id, transaction_type)
WHERE t.reference = 'TRF2610190001'
RETURNING transaction_id, reference, wallet_id, transaction_type, amount;

COMMIT;

-- After COMMIT: wallet 3 is down by 25,000, wallet 6 is up by 25,000, and
-- the transfer has both ledger legs.
SELECT wallet_id, balance FROM wallets WHERE wallet_id IN (3, 6) ORDER BY wallet_id;

SELECT t.reference AS transfer, t.status, x.reference AS ledger_row, x.wallet_id,
       x.transaction_type, x.amount
FROM transfers t JOIN transactions x USING (transfer_id)
WHERE t.reference = 'TRF2610190001'
ORDER BY x.transaction_id;

\echo
\echo '=== Part 2: a transfer that fails and rolls back ==='
\echo 'Aisha Bello (wallet 2, balance NGN 23,500.00) tries to send NGN 50,000.00 to Emeka Nwosu (wallet 7).'
\echo

-- Snapshot before: the two balances and the row counts, to compare afterwards.
SELECT wallet_id, balance FROM wallets WHERE wallet_id IN (2, 7) ORDER BY wallet_id;

SELECT (SELECT count(*) FROM transfers)    AS transfers,
       (SELECT count(*) FROM transactions) AS ledger_rows;

-- The next statements fail on purpose. Let psql carry on after an error so
-- the rollback can be shown, then switch the safety catch back on.
\set ON_ERROR_STOP off

BEGIN;

INSERT INTO transfers (reference, sender_wallet_id, receiver_wallet_id, amount,
                       narration, status, processed_at)
VALUES ('TRF2610190002', 2, 7, 50000.00, 'School fees', 'completed', now())
RETURNING transfer_id, reference, status;

-- The credit is applied first here, on purpose, so that the transaction has
-- already changed something by the time it fails. Wallet 7 shows 115,000.00,
-- but only inside this transaction.
UPDATE wallets SET balance = balance + 50000.00
WHERE wallet_id = 7
RETURNING wallet_id, balance;

-- The debit would leave wallet 2 at -26,500.00. The CHECK constraint
-- wallets_balance_non_negative from Portfolio 1 rejects it.
UPDATE wallets SET balance = balance - 50000.00
WHERE wallet_id = 2
RETURNING wallet_id, balance;

-- After an error PostgreSQL marks the whole transaction as failed: every
-- further statement is refused until the transaction ends. Even a read.
SELECT balance FROM wallets WHERE wallet_id = 7;

-- ROLLBACK undoes everything since BEGIN: the transfers row and the credit.
-- (COMMIT would do the same here: on a failed transaction PostgreSQL
-- answers COMMIT with ROLLBACK.)
ROLLBACK;

\set ON_ERROR_STOP on

-- After ROLLBACK: both balances and both row counts are exactly as they
-- were before Part 2, and the transfer reference was never stored.
SELECT wallet_id, balance FROM wallets WHERE wallet_id IN (2, 7) ORDER BY wallet_id;

SELECT (SELECT count(*) FROM transfers)    AS transfers,
       (SELECT count(*) FROM transactions) AS ledger_rows,
       (SELECT count(*) FROM transfers WHERE reference = 'TRF2610190002') AS failed_transfer_rows;

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
