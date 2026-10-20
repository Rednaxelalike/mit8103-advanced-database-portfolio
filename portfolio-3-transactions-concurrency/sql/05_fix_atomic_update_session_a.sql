-- =====================================================================
-- Portfolio 3: Transactions and concurrency
-- 05_fix_atomic_update_session_a.sql  Fix 2 for the lost update: one
--                                     atomic UPDATE instead of read, then
--                                     write. Session A.
--                                     Session B is 05_fix_atomic_update_session_b.sql.
--
-- Run both sessions together from the repo root (see README):
--   .\portfolio-3-transactions-concurrency\run_two_sessions.ps1 05_fix_atomic_update
--
-- Same scenario and amounts as 03_lost_update, still under READ COMMITTED.
-- The application no longer reads the balance and works out the new one.
-- It asks the database to do both in one statement:
--   UPDATE wallets SET balance = balance - x
--   WHERE wallet_id = 5 AND balance >= x
-- "balance - x" uses the row as it is when the UPDATE runs, not a value
-- read earlier. If another session is changing the row, the UPDATE waits
-- for it, then re-checks the WHERE clause against the new version.
-- "balance >= x" is the funds check: if there is not enough money, no row
-- matches, the UPDATE changes 0 rows, and the application cancels the
-- transfer.
--
-- Timeline (seconds after the shared start time):
--   t+1  A  BEGIN; UPDATE ... balance - 120,000.00 (180,000.00), records the transfer
--   t+2  B  BEGIN; UPDATE ... balance - 80,000.00 waits for A's row lock
--   t+3  A  shows B waiting
--   t+4  A  COMMIT; B's UPDATE re-checks the row and gives 100,000.00
--   t+5  B  records the transfer, COMMIT
--   t+6  B  tries a third transfer of 150,000.00: UPDATE 0, cancelled
--   t+7  A  checks the result
-- =====================================================================

\ir ../../portfolio-1-database-design/sql/01_schema.sql
\ir ../../portfolio-1-database-design/sql/02_sample_data.sql

\set session session_a
\ir two_session_clock.sql

-- From here on, psql prints each statement before its result.
\set ECHO queries

\echo
\echo '=== Session A: NGN 120,000.00 from wallet 5 to wallet 10, one atomic UPDATE ==='

SHOW transaction_isolation;

SELECT pg_temp.step(1);

BEGIN;

-- Debit and funds check in one statement. No earlier read is needed.
UPDATE wallets SET balance = balance - 120000.00
WHERE wallet_id = 5 AND balance >= 120000.00
RETURNING wallet_id, balance;

-- The application looks at how many rows the UPDATE changed:
-- 1 means the money was there and has been taken; 0 means it was not.
SELECT :ROW_COUNT = 1 AS debited \gset

\if :debited
    INSERT INTO transfers (reference, sender_wallet_id, receiver_wallet_id, amount,
                           narration, status, processed_at)
    VALUES ('TRF2610200001', 5, 10, 120000.00, 'House rent', 'completed', now())
    RETURNING transfer_id, reference, status;

    UPDATE wallets SET balance = balance + 120000.00
    WHERE wallet_id = 10
    RETURNING wallet_id, balance;

    INSERT INTO transactions (reference, wallet_id, transaction_type, amount, transfer_id, narration)
    SELECT v.reference, v.wallet_id, v.transaction_type, 120000.00, t.transfer_id, 'House rent'
    FROM transfers t
    CROSS JOIN (VALUES ('TXN2610200001', 5, 'transfer_out'),
                       ('TXN2610200002', 10, 'transfer_in')) AS v (reference, wallet_id, transaction_type)
    WHERE t.reference = 'TRF2610200001'
    RETURNING transaction_id, reference, wallet_id, transaction_type, amount;
\else
    \echo 'Not enough money in wallet 5: nothing was debited, so the transfer is cancelled.'
    ROLLBACK;
\endif

SELECT pg_temp.step(3);

-- Session B's UPDATE of wallet 5 at t+2 is waiting for this transaction.
SELECT w.application_name AS waiting_session, w.state,
       w.wait_event_type, w.wait_event,
       b.application_name AS blocked_by,
       btrim(regexp_replace(w.query, '\s+', ' ', 'g')) AS waiting_statement
FROM pg_stat_activity w
JOIN pg_stat_activity b ON b.pid = ANY (pg_blocking_pids(w.pid))
WHERE w.datname = current_database();

SELECT pg_temp.step(4);

-- COMMIT releases the row lock. Session B's UPDATE then runs against the
-- committed row (180,000.00).
COMMIT;

-- Session B commits at t+5 and tries a third transfer at t+6.
SELECT pg_temp.step(7);

\echo
\echo '=== Result after both sessions have finished ==='

-- Wallet 5 should hold 300,000.00 - 120,000.00 - 80,000.00 = 100,000.00,
-- and the third transfer (to wallet 20) should not have happened.
SELECT w.wallet_id, c.first_name || ' ' || c.last_name AS owner, w.balance
FROM wallets w JOIN customers c USING (customer_id)
WHERE w.wallet_id IN (5, 10, 14, 20)
ORDER BY w.wallet_id;

-- Two transfers are recorded as completed, each with its two ledger rows.
-- The cancelled third transfer left no row.
SELECT t.transfer_id, t.reference, t.sender_wallet_id AS sender,
       t.receiver_wallet_id AS receiver, t.amount, t.status,
       count(x.transaction_id) AS ledger_rows
FROM transfers t LEFT JOIN transactions x USING (transfer_id)
WHERE t.reference IN ('TRF2610200001', 'TRF2610200002', 'TRF2610200003')
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
