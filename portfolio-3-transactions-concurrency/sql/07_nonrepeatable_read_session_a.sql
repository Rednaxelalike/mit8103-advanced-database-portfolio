-- =====================================================================
-- Portfolio 3: Transactions and concurrency
-- 07_nonrepeatable_read_session_a.sql  A non-repeatable read under READ
--                                      COMMITTED, and the same steps under
--                                      REPEATABLE READ. Session A.
--                                      Session B is 07_nonrepeatable_read_session_b.sql.
--
-- Run both sessions together from the repo root (see README):
--   .\portfolio-3-transactions-concurrency\run_two_sessions.ps1 07_nonrepeatable_read
--
-- Scenario: session A is the job that builds Ibrahim Musa's statement for
-- wallet 5. It reads the balance once for the top of the statement and
-- again for the summary at the bottom, inside one transaction. Session B
-- is Ibrahim's two transfers from 03 (NGN 120,000.00 to wallet 10, then
-- NGN 80,000.00 to wallet 14), now written with the atomic UPDATE from 05.
-- Each B transfer commits between A's two reads.
--
-- A selects xmin with the balance: the id of the transaction that wrote
-- that version of the row. B prints its own transaction id, so the log
-- shows whose version each read returned. Transaction ids change on every
-- run; everything else in the output stays the same.
--
-- Timeline (seconds after the shared start time):
--   Part 1, READ COMMITTED
--   t+1  A  BEGIN; first read: 300,000.00
--   t+2  B  120,000.00 to wallet 10, COMMIT (does not wait for A)
--   t+3  A  second read in the same transaction: 180,000.00; COMMIT
--   Part 2, REPEATABLE READ
--   t+4  A  BEGIN ISOLATION LEVEL REPEATABLE READ; first read: 180,000.00
--   t+5  B  80,000.00 to wallet 14, COMMIT (does not wait for A)
--   t+6  A  second read in the same transaction: still 180,000.00; COMMIT;
--          a read after COMMIT: 100,000.00; checks the result
-- =====================================================================

\ir ../../portfolio-1-database-design/sql/01_schema.sql
\ir ../../portfolio-1-database-design/sql/02_sample_data.sql

\set session session_a
\ir two_session_clock.sql

-- From here on, psql prints each statement before its result.
\set ECHO queries

\echo
\echo '=== Session A, part 1: statement for wallet 5 under READ COMMITTED ==='

SELECT pg_temp.step(1);

BEGIN;

SHOW transaction_isolation;

-- First read, for the top of the statement.
SELECT wallet_id, balance, xmin FROM wallets WHERE wallet_id = 5;

-- Session B debits wallet 5 and commits at t+2.
SELECT pg_temp.step(3);

-- Second read, for the summary: the same query in the same transaction.
-- Under READ COMMITTED every statement sees what was committed before it
-- started, so this one sees B's new row version.
SELECT wallet_id, balance, xmin FROM wallets WHERE wallet_id = 5;

COMMIT;

\echo
\echo '=== Session A, part 2: the same statement under REPEATABLE READ ==='

SELECT pg_temp.step(4);

BEGIN ISOLATION LEVEL REPEATABLE READ;

SHOW transaction_isolation;

-- First read. The transaction's snapshot is taken at this first query,
-- not at BEGIN, and every later query in the transaction uses it.
SELECT wallet_id, balance, xmin FROM wallets WHERE wallet_id = 5;

-- Session B debits wallet 5 again and commits at t+5.
SELECT pg_temp.step(6);

-- Second read: B's new version is committed, but it is newer than this
-- transaction's snapshot, so A still sees the version it read at t+4.
SELECT wallet_id, balance, xmin FROM wallets WHERE wallet_id = 5;

COMMIT;

-- A new transaction, so a new snapshot: now B's version is visible.
SELECT wallet_id, balance, xmin FROM wallets WHERE wallet_id = 5;

\echo
\echo '=== Result after both sessions have committed ==='

-- Wallet 5 should hold 300,000.00 - 120,000.00 - 80,000.00 = 100,000.00.
SELECT w.wallet_id, c.first_name || ' ' || c.last_name AS owner, w.balance
FROM wallets w JOIN customers c USING (customer_id)
WHERE w.wallet_id IN (5, 10, 14)
ORDER BY w.wallet_id;

-- Both transfers are recorded as completed, each with its two ledger rows.
SELECT t.transfer_id, t.reference, t.sender_wallet_id AS sender,
       t.receiver_wallet_id AS receiver, t.amount, t.status,
       count(x.transaction_id) AS ledger_rows
FROM transfers t LEFT JOIN transactions x USING (transfer_id)
WHERE t.reference IN ('TRF2610200001', 'TRF2610200002')
GROUP BY t.transfer_id
ORDER BY t.transfer_id;

\echo
\echo '=== Balance audit: stored balance against the ledger ==='

-- The audit from 02_sample_data.sql, plus a list of the wallets that fail.
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

SELECT w.wallet_id, w.balance AS stored_balance,
       coalesce(l.ledger_balance, 0) AS ledger_balance,
       w.balance - coalesce(l.ledger_balance, 0) AS difference
FROM wallets w
LEFT JOIN (
    SELECT wallet_id,
           sum(CASE WHEN transaction_type IN ('funding', 'transfer_in', 'reversal')
                    THEN amount ELSE -amount END) AS ledger_balance
    FROM transactions
    WHERE status = 'completed'
    GROUP BY wallet_id
) l USING (wallet_id)
WHERE w.balance <> coalesce(l.ledger_balance, 0)
ORDER BY w.wallet_id;
