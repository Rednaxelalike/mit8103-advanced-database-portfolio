-- =====================================================================
-- Portfolio 3: Transactions and concurrency
-- 03_lost_update_session_b.sql  Session B of the lost update.
--                               Session A is 03_lost_update_session_a.sql,
--                               which describes the scenario and timeline.
--
-- Run both sessions together from the repo root (see README):
--   .\portfolio-3-transactions-concurrency\run_two_sessions.ps1 03_lost_update
--
-- Session B: Ibrahim Musa sends NGN 80,000.00 from wallet 5 to Hauwa
-- Ibrahim (wallet 14), using the same read-then-write code as session A.
-- =====================================================================

\set session session_b
\ir two_session_clock.sql

-- From here on, psql prints each statement before its result.
\set ECHO queries

\echo
\echo '=== Session B: NGN 80,000.00 from wallet 5 to wallet 14 ==='

SHOW transaction_isolation;

SELECT pg_temp.step(2);

BEGIN;

-- Session A has read the balance but not changed it yet.
SELECT balance FROM wallets WHERE wallet_id = 5 \gset b_
\echo 'Session B read the balance of wallet 5:' :b_balance

SELECT pg_temp.step(5);

-- By now session A has committed wallet 5 at 180,000.00. Under READ
-- COMMITTED a new SELECT would see that, but the application does not read
-- again: it writes back the balance it worked out from its read at t+2.
-- Nothing blocks it, because session A's row lock ended with its COMMIT.
UPDATE wallets SET balance = :b_balance - 80000.00
WHERE wallet_id = 5
RETURNING wallet_id, balance;

INSERT INTO transfers (reference, sender_wallet_id, receiver_wallet_id, amount,
                       narration, status, processed_at)
VALUES ('TRF2610200002', 5, 14, 80000.00, 'Shop stock', 'completed', now())
RETURNING transfer_id, reference, status;

UPDATE wallets SET balance = balance + 80000.00
WHERE wallet_id = 14
RETURNING wallet_id, balance;

INSERT INTO transactions (reference, wallet_id, transaction_type, amount, transfer_id, narration)
SELECT v.reference, v.wallet_id, v.transaction_type, 80000.00, t.transfer_id, 'Shop stock'
FROM transfers t
CROSS JOIN (VALUES ('TXN2610200003', 5, 'transfer_out'),
                   ('TXN2610200004', 14, 'transfer_in')) AS v (reference, wallet_id, transaction_type)
WHERE t.reference = 'TRF2610200002'
RETURNING transaction_id, reference, wallet_id, transaction_type, amount;

COMMIT;

-- Session A checks the result at t+6.
