-- =====================================================================
-- Portfolio 3: Transactions and concurrency
-- 09_fix_lock_order_session_a.sql  Fix for the deadlock: every transfer
--                                  locks the lower wallet id first.
--                                  Session A. Session B is 09_fix_lock_order_session_b.sql.
--
-- Run both sessions together from the repo root (see README):
--   .\portfolio-3-transactions-concurrency\run_two_sessions.ps1 09_fix_lock_order
--
-- Same scenario, amounts and timing as 08_deadlock: Ibrahim Musa (wallet
-- 5) pays Tunde Bakare (wallet 9) NGN 50,000.00 in session A while Tunde
-- refunds Ibrahim NGN 30,000.00 in session B. The one change is a first
-- statement in every transfer that locks both wallets in wallet id order:
--   SELECT ... WHERE wallet_id IN (sender, receiver) ORDER BY wallet_id FOR UPDATE
-- Both sessions now take wallet 5 before wallet 9. Whichever comes second
-- waits at its first lock while holding nothing, so no cycle can form.
--
-- Timeline (seconds after the shared start time):
--   t+1  A  BEGIN; locks wallets 5 and 9; debits wallet 5, records transfer 1
--   t+2  B  BEGIN; tries to lock wallet 5 first: waits for A, holding nothing
--   t+3  A  credits wallet 9 without waiting; shows B waiting
--   t+4  A  COMMIT; B gets both locks
--   t+5  B  debits wallet 9, records transfer 2, credits wallet 5, COMMIT
--   t+6  A  checks the result
-- =====================================================================

\ir ../../portfolio-1-database-design/sql/01_schema.sql
\ir ../../portfolio-1-database-design/sql/02_sample_data.sql

\set session session_a
\ir two_session_clock.sql

-- From here on, psql prints each statement before its result.
\set ECHO queries

\echo
\echo '=== Session A: NGN 50,000.00 from wallet 5 to wallet 9, locking wallets in id order ==='

SELECT pg_temp.step(1);

BEGIN;

-- The only change from 08: lock both wallets first, lower id first.
-- ORDER BY runs before FOR UPDATE, so the rows are locked in this order.
SELECT wallet_id, balance FROM wallets
WHERE wallet_id IN (5, 9)
ORDER BY wallet_id
FOR UPDATE;

-- The rest is the transfer code from 08, unchanged.
UPDATE wallets SET balance = balance - 50000.00
WHERE wallet_id = 5 AND balance >= 50000.00
RETURNING wallet_id, balance;

SELECT :ROW_COUNT = 1 AS debited \gset
\if :debited
\else
    \echo 'Not enough money in wallet 5: nothing was debited, so the transfer is cancelled.'
    ROLLBACK;
    \quit
\endif

INSERT INTO transfers (reference, sender_wallet_id, receiver_wallet_id, amount,
                       narration, status, processed_at)
VALUES ('TRF2610230001', 5, 9, 50000.00, 'Generator repair', 'completed', now())
RETURNING transfer_id, reference, status;

SELECT pg_temp.step(3);

-- Session B tried to lock the two wallets at t+2 and is waiting for
-- wallet 5, so it holds no lock on wallet 9. This credit, which waited
-- in 08, does not wait: the clock after it still shows t+3.0.
UPDATE wallets SET balance = balance + 50000.00
WHERE wallet_id = 9
RETURNING wallet_id, balance;

SELECT pg_temp.clock();

-- Session B is still waiting, for session A, on its lock statement.
SELECT w.application_name AS waiting_session, w.state,
       w.wait_event_type, w.wait_event,
       b.application_name AS blocked_by,
       btrim(regexp_replace(w.query, '\s+', ' ', 'g')) AS waiting_statement
FROM pg_stat_activity w
JOIN pg_stat_activity b ON b.pid = ANY (pg_blocking_pids(w.pid))
WHERE w.datname = current_database();

INSERT INTO transactions (reference, wallet_id, transaction_type, amount, transfer_id, narration)
SELECT v.reference, v.wallet_id, v.transaction_type, 50000.00, t.transfer_id, 'Generator repair'
FROM transfers t
CROSS JOIN (VALUES ('TXN2610230001', 5, 'transfer_out'),
                   ('TXN2610230002', 9, 'transfer_in')) AS v (reference, wallet_id, transaction_type)
WHERE t.reference = 'TRF2610230001'
RETURNING transaction_id, reference, wallet_id, transaction_type, amount;

SELECT pg_temp.step(4);

-- COMMIT releases both locks, and session B's lock statement goes ahead.
COMMIT;

-- Session B commits at t+5. Look at the result after that.
SELECT pg_temp.step(6);

\echo
\echo '=== Result after both sessions have committed ==='

-- Wallet 5: 300,000.00 - 50,000.00 + 30,000.00 = 280,000.00.
-- Wallet 9: 265,000.00 + 50,000.00 - 30,000.00 = 285,000.00.
SELECT w.wallet_id, c.first_name || ' ' || c.last_name AS owner, w.balance
FROM wallets w JOIN customers c USING (customer_id)
WHERE w.wallet_id IN (5, 9)
ORDER BY w.wallet_id;

-- Both transfers are recorded as completed, each with its two ledger rows.
SELECT t.transfer_id, t.reference, t.sender_wallet_id AS sender,
       t.receiver_wallet_id AS receiver, t.amount, t.status,
       count(x.transaction_id) AS ledger_rows
FROM transfers t LEFT JOIN transactions x USING (transfer_id)
WHERE t.reference IN ('TRF2610230001', 'TRF2610230002')
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
