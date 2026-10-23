-- =====================================================================
-- Portfolio 3: Transactions and concurrency
-- 08_deadlock_session_b.sql  A deadlock from two opposite transfers.
--                            Session B. Session A is 08_deadlock_session_a.sql,
--                            which describes the timeline.
--
-- Run both sessions together from the repo root (see README):
--   .\portfolio-3-transactions-concurrency\run_two_sessions.ps1 08_deadlock
--
-- Session B: Tunde Bakare refunds Ibrahim Musa NGN 30,000.00, from wallet
-- 9 to wallet 5, with the same transfer code as session A. It locks
-- wallet 9 first and wallet 5 second, the opposite order to A.
-- =====================================================================

\set session session_b
\ir two_session_clock.sql

-- From here on, psql prints each statement before its result.
\set ECHO queries

\echo
\echo '=== Session B: NGN 30,000.00 from wallet 9 to wallet 5 ==='

-- How long a session waits for a lock before PostgreSQL checks for a
-- deadlock (the default).
SHOW deadlock_timeout;

SELECT pg_temp.step(2);

BEGIN;

-- Debit the sender. This locks wallet 9 until COMMIT or ROLLBACK.
UPDATE wallets SET balance = balance - 30000.00
WHERE wallet_id = 9 AND balance >= 30000.00
RETURNING wallet_id, balance;

SELECT :ROW_COUNT = 1 AS debited \gset
\if :debited
\else
    \echo 'Not enough money in wallet 9: nothing was debited, so the transfer is cancelled.'
    ROLLBACK;
    \quit
\endif

SELECT pg_backend_pid() AS session_b_pid, pg_current_xact_id() AS session_b_xid;

INSERT INTO transfers (reference, sender_wallet_id, receiver_wallet_id, amount,
                       narration, status, processed_at)
VALUES ('TRF2610230002', 9, 5, 30000.00, 'Overpayment refund', 'completed', now())
RETURNING transfer_id, reference, status;

SELECT pg_temp.step(4);

-- Session A tried to credit wallet 9 at t+3 and is waiting for this
-- session's lock.
SELECT w.application_name AS waiting_session, w.state,
       w.wait_event_type, w.wait_event,
       b.application_name AS blocked_by,
       btrim(regexp_replace(w.query, '\s+', ' ', 'g')) AS waiting_statement
FROM pg_stat_activity w
JOIN pg_stat_activity b ON b.pid = ANY (pg_blocking_pids(w.pid))
WHERE w.datname = current_database();

SELECT pg_temp.step(5);

-- Credit the receiver. Session A holds wallet 5's lock and is itself
-- waiting for this session, so neither can ever go on. After
-- deadlock_timeout this session checks the lock waits, finds the cycle,
-- and PostgreSQL aborts it. The error is expected: let psql carry on, then
-- switch the safety catch back on.
\set ON_ERROR_STOP off

UPDATE wallets SET balance = balance + 30000.00
WHERE wallet_id = 5
RETURNING wallet_id, balance;

-- The whole transaction is aborted; the application rolls it back. This
-- also releases the lock on wallet 9, so session A can go on.
ROLLBACK;

\set ON_ERROR_STOP on

SELECT pg_temp.clock();

-- 40P01 is "deadlock detected". Like 40001, it means the transaction did
-- nothing and can safely be run again.
SELECT :'LAST_ERROR_SQLSTATE' AS sqlstate, :'LAST_ERROR_SQLSTATE' = '40P01' AS deadlock_victim \gset
\if :deadlock_victim
    \echo 'Session B was chosen as the deadlock victim and rolled back: the refund was not made. The application would have to send it again.'
\else
    \echo 'The credit did not end in a deadlock. This demo expects one: check that both sessions ran to the timeline.'
\endif

-- Session A checks the result at t+7.
