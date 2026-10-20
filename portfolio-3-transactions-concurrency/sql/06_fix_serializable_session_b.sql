-- =====================================================================
-- Portfolio 3: Transactions and concurrency
-- 06_fix_serializable_session_b.sql  Fix 3 for the lost update: run the
--                                    same read-then-write code under
--                                    SERIALIZABLE and retry on a
--                                    serialization failure. Session B.
--                                    Session A is 06_fix_serializable_session_a.sql,
--                                    which describes the timeline.
--
-- Run both sessions together from the repo root (see README):
--   .\portfolio-3-transactions-concurrency\run_two_sessions.ps1 06_fix_serializable
--
-- Session B: NGN 80,000.00 from wallet 5 to wallet 14, the same code as in
-- 03_lost_update_session_b.sql but under SERIALIZABLE, with one retry.
-- An application would retry in a loop; psql has no loops, so the retry is
-- written out once and runs only if the first attempt failed with
-- SQLSTATE 40001 (serialization failure).
-- =====================================================================

\set session session_b
\ir two_session_clock.sql

-- From here on, psql prints each statement before its result.
\set ECHO queries

\echo
\echo '=== Session B: NGN 80,000.00 from wallet 5 to wallet 14, under SERIALIZABLE ==='
\echo '--- Attempt 1 ---'

SELECT pg_temp.step(2);

BEGIN ISOLATION LEVEL SERIALIZABLE;

SHOW transaction_isolation;

-- B's snapshot is taken here. Session A has not changed wallet 5 yet.
SELECT balance FROM wallets WHERE wallet_id = 5 \gset b_
\echo 'Session B read the balance of wallet 5:' :b_balance

SELECT pg_temp.step(5);

-- Session A changed wallet 5 and committed at t+4, after B's snapshot.
-- Writing over that change would lose A's debit, so PostgreSQL refuses.
-- The error is expected: let psql carry on, then switch the safety catch
-- back on.
\set ON_ERROR_STOP off

UPDATE wallets SET balance = :b_balance - 80000.00
WHERE wallet_id = 5
RETURNING wallet_id, balance;

-- The transaction is now aborted; the application rolls it back.
ROLLBACK;

\set ON_ERROR_STOP on

-- psql keeps the code of the last error. 40001 means "serialization
-- failure: try again"; any other error would not be retried.
SELECT :'LAST_ERROR_SQLSTATE' = '40001' AS retry \gset

\if :retry
    \echo '--- Attempt 2: SQLSTATE 40001, so run the whole transaction again ---'

    SELECT pg_temp.clock();

    BEGIN ISOLATION LEVEL SERIALIZABLE;

    -- A new transaction, so a new snapshot: it sees A's committed balance.
    SELECT balance FROM wallets WHERE wallet_id = 5 \gset b_
    \echo 'Session B read the balance of wallet 5:' :b_balance

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
\else
    \echo 'Attempt 1 did not end in a serialization failure, so it is not retried. This demo expects one: check that both sessions ran to the timeline.'
\endif

-- Session A checks the result at t+6.
