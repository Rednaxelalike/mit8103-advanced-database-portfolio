-- =====================================================================
-- Portfolio 3: Transactions and concurrency
-- 04_fix_for_update_session_a.sql  Fix 1 for the lost update: lock the
--                                  row when reading it. Session A.
--                                  Session B is 04_fix_for_update_session_b.sql.
--
-- Run both sessions together from the repo root (see README):
--   .\portfolio-3-transactions-concurrency\run_two_sessions.ps1 04_fix_for_update
--
-- Same scenario, amounts and application code as 03_lost_update: wallet 5
-- (NGN 300,000.00) sends 120,000.00 to wallet 10 (session A) and 80,000.00
-- to wallet 14 (session B), still under READ COMMITTED. The one change is
-- FOR UPDATE on the read. It takes a row lock on wallet 5 that lasts until
-- the end of the transaction, so the second session's read has to wait,
-- and when it gets the row it sees the balance session A committed.
--
-- Timeline (seconds after the shared start time):
--   t+1  A  BEGIN; SELECT ... FOR UPDATE reads 300,000.00 and locks the row
--   t+2  B  BEGIN; SELECT ... FOR UPDATE waits for A's lock
--   t+3  A  shows B waiting; writes 180,000.00, records the transfer
--   t+4  A  COMMIT; B's read now returns 180,000.00
--   t+5  B  writes 180,000.00 - 80,000.00 = 100,000.00, records the transfer, COMMIT
--   t+6  A  checks the result
-- =====================================================================

\ir ../../portfolio-1-database-design/sql/01_schema.sql
\ir ../../portfolio-1-database-design/sql/02_sample_data.sql

\set session session_a
\ir two_session_clock.sql

-- From here on, psql prints each statement before its result.
\set ECHO queries

\echo
\echo '=== Session A: NGN 120,000.00 from wallet 5 to wallet 10, reading with FOR UPDATE ==='

SHOW transaction_isolation;

SELECT pg_temp.step(1);

BEGIN;

-- The only change from 03: FOR UPDATE locks wallet 5 until COMMIT.
SELECT balance FROM wallets WHERE wallet_id = 5 FOR UPDATE \gset a_
\echo 'Session A read (and locked) the balance of wallet 5:' :a_balance

SELECT pg_temp.step(3);

-- Session B tried to read wallet 5 with FOR UPDATE at t+2 and is waiting.
-- pg_stat_activity shows who waits, on what, and behind whom; the
-- sessions are named by application_name because process ids change on
-- every run.
SELECT w.application_name AS waiting_session, w.state,
       w.wait_event_type, w.wait_event,
       b.application_name AS blocked_by,
       btrim(regexp_replace(w.query, '\s+', ' ', 'g')) AS waiting_statement
FROM pg_stat_activity w
JOIN pg_stat_activity b ON b.pid = ANY (pg_blocking_pids(w.pid))
WHERE w.datname = current_database();

-- The same wait in pg_locks: B holds the row's tuple lock and waits
-- (granted = f) for A's transaction id to finish.
SELECT a.application_name, l.locktype, l.mode, l.granted
FROM pg_locks l JOIN pg_stat_activity a USING (pid)
WHERE a.application_name IN ('session_a', 'session_b')
  AND (l.locktype IN ('tuple', 'transactionid') OR l.relation = 'wallets'::regclass)
ORDER BY a.application_name, l.locktype, l.mode;

UPDATE wallets SET balance = :a_balance - 120000.00
WHERE wallet_id = 5
RETURNING wallet_id, balance;

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

SELECT pg_temp.step(4);

-- COMMIT releases the lock, and session B's read goes ahead.
COMMIT;

-- Session B commits at t+5. Look at the result after that.
SELECT pg_temp.step(6);

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
