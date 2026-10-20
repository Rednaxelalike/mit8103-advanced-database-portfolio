-- =====================================================================
-- Portfolio 3: Transactions and concurrency
-- 05_fix_atomic_update_session_b.sql  Fix 2 for the lost update: one
--                                     atomic UPDATE instead of read, then
--                                     write. Session B.
--                                     Session A is 05_fix_atomic_update_session_a.sql,
--                                     which describes the timeline.
--
-- Run both sessions together from the repo root (see README):
--   .\portfolio-3-transactions-concurrency\run_two_sessions.ps1 05_fix_atomic_update
--
-- Session B: NGN 80,000.00 from wallet 5 to wallet 14 with the atomic
-- UPDATE, then a third transfer of NGN 150,000.00 to Folake Akinwale
-- (wallet 20), which wallet 5 can no longer cover.
-- =====================================================================

\set session session_b
\ir two_session_clock.sql

-- From here on, psql prints each statement before its result.
\set ECHO queries

\echo
\echo '=== Session B: NGN 80,000.00 from wallet 5 to wallet 14, one atomic UPDATE ==='

SHOW transaction_isolation;

SELECT pg_temp.step(2);

BEGIN;

-- Session A has already debited wallet 5 but not committed, so this
-- UPDATE waits. When A commits at t+4, PostgreSQL re-reads the row,
-- re-checks "balance >= 80000.00" against 180,000.00, and subtracts from
-- that.
UPDATE wallets SET balance = balance - 80000.00
WHERE wallet_id = 5 AND balance >= 80000.00
RETURNING wallet_id, balance;

SELECT :ROW_COUNT = 1 AS debited \gset
SELECT pg_temp.clock();

\if :debited
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
\else
    \echo 'Not enough money in wallet 5: nothing was debited, so the transfer is cancelled.'
    ROLLBACK;
\endif

SELECT pg_temp.step(5);

COMMIT;

\echo
\echo '=== Session B: a third transfer, NGN 150,000.00 to wallet 20, more than is left ==='

SELECT pg_temp.step(6);

BEGIN;

-- Wallet 5 now holds 100,000.00, so "balance >= 150000.00" is false: the
-- UPDATE matches no row and reports UPDATE 0. No error is raised and the
-- CHECK constraint never comes into play, because nothing was written.
UPDATE wallets SET balance = balance - 150000.00
WHERE wallet_id = 5 AND balance >= 150000.00
RETURNING wallet_id, balance;

SELECT :ROW_COUNT = 1 AS debited \gset

\if :debited
    INSERT INTO transfers (reference, sender_wallet_id, receiver_wallet_id, amount,
                           narration, status, processed_at)
    VALUES ('TRF2610200003', 5, 20, 150000.00, 'Car deposit', 'completed', now())
    RETURNING transfer_id, reference, status;

    UPDATE wallets SET balance = balance + 150000.00
    WHERE wallet_id = 20
    RETURNING wallet_id, balance;

    INSERT INTO transactions (reference, wallet_id, transaction_type, amount, transfer_id, narration)
    SELECT v.reference, v.wallet_id, v.transaction_type, 150000.00, t.transfer_id, 'Car deposit'
    FROM transfers t
    CROSS JOIN (VALUES ('TXN2610200005', 5, 'transfer_out'),
                       ('TXN2610200006', 20, 'transfer_in')) AS v (reference, wallet_id, transaction_type)
    WHERE t.reference = 'TRF2610200003'
    RETURNING transaction_id, reference, wallet_id, transaction_type, amount;

    COMMIT;
\else
    \echo 'Not enough money in wallet 5: nothing was debited, so the transfer is cancelled.'
    ROLLBACK;
\endif

-- Session A checks the result at t+7.
