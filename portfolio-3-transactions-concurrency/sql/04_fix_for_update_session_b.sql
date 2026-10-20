-- =====================================================================
-- Portfolio 3: Transactions and concurrency
-- 04_fix_for_update_session_b.sql  Fix 1 for the lost update: lock the
--                                  row when reading it. Session B.
--                                  Session A is 04_fix_for_update_session_a.sql,
--                                  which describes the timeline.
--
-- Run both sessions together from the repo root (see README):
--   .\portfolio-3-transactions-concurrency\run_two_sessions.ps1 04_fix_for_update
--
-- Session B: NGN 80,000.00 from wallet 5 to wallet 14, the same code as in
-- 03_lost_update_session_b.sql plus FOR UPDATE on the read.
-- =====================================================================

\set session session_b
\ir two_session_clock.sql

-- From here on, psql prints each statement before its result.
\set ECHO queries

\echo
\echo '=== Session B: NGN 80,000.00 from wallet 5 to wallet 14, reading with FOR UPDATE ==='

SHOW transaction_isolation;

SELECT pg_temp.step(2);

BEGIN;

-- Session A holds the row lock on wallet 5, so this read waits until A
-- commits at t+4. It then returns the balance A committed, not 300,000.00.
SELECT balance FROM wallets WHERE wallet_id = 5 FOR UPDATE \gset b_
SELECT pg_temp.clock();
\echo 'Session B read (and locked) the balance of wallet 5:' :b_balance

SELECT pg_temp.step(5);

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
