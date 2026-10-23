-- =====================================================================
-- Portfolio 3: Transactions and concurrency
-- 09_fix_lock_order_session_b.sql  Fix for the deadlock: every transfer
--                                  locks the lower wallet id first.
--                                  Session B. Session A is 09_fix_lock_order_session_a.sql,
--                                  which describes the timeline.
--
-- Run both sessions together from the repo root (see README):
--   .\portfolio-3-transactions-concurrency\run_two_sessions.ps1 09_fix_lock_order
--
-- Session B: Tunde Bakare refunds Ibrahim Musa NGN 30,000.00, from wallet
-- 9 to wallet 5. Its sender has the higher id, but it still locks wallet
-- 5 first, because the lock statement orders by wallet id, not by sender.
-- =====================================================================

\set session session_b
\ir two_session_clock.sql

-- From here on, psql prints each statement before its result.
\set ECHO queries

\echo
\echo '=== Session B: NGN 30,000.00 from wallet 9 to wallet 5, locking wallets in id order ==='

SELECT pg_temp.step(2);

BEGIN;

-- Session A holds both wallets, so this waits at wallet 5, before it has
-- locked anything.
SELECT wallet_id, balance FROM wallets
WHERE wallet_id IN (5, 9)
ORDER BY wallet_id
FOR UPDATE;

-- Returns when session A commits at t+4, with A's committed balances.
SELECT pg_temp.clock();

SELECT pg_temp.step(5);

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

INSERT INTO transfers (reference, sender_wallet_id, receiver_wallet_id, amount,
                       narration, status, processed_at)
VALUES ('TRF2610230002', 9, 5, 30000.00, 'Overpayment refund', 'completed', now())
RETURNING transfer_id, reference, status;

-- The credit that deadlocked in 08. This session already holds wallet
-- 5's lock, so it goes straight through.
UPDATE wallets SET balance = balance + 30000.00
WHERE wallet_id = 5
RETURNING wallet_id, balance;

INSERT INTO transactions (reference, wallet_id, transaction_type, amount, transfer_id, narration)
SELECT v.reference, v.wallet_id, v.transaction_type, 30000.00, t.transfer_id, 'Overpayment refund'
FROM transfers t
CROSS JOIN (VALUES ('TXN2610230003', 9, 'transfer_out'),
                   ('TXN2610230004', 5, 'transfer_in')) AS v (reference, wallet_id, transaction_type)
WHERE t.reference = 'TRF2610230002'
RETURNING transaction_id, reference, wallet_id, transaction_type, amount;

COMMIT;

-- Session A checks the result at t+6.
