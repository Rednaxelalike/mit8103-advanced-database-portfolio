-- =====================================================================
-- Portfolio 3: Transactions and concurrency
-- 07_nonrepeatable_read_session_b.sql  A non-repeatable read under READ
--                                      COMMITTED, and the same steps under
--                                      REPEATABLE READ. Session B.
--                                      Session A is 07_nonrepeatable_read_session_a.sql,
--                                      which describes the timeline.
--
-- Run both sessions together from the repo root (see README):
--   .\portfolio-3-transactions-concurrency\run_two_sessions.ps1 07_nonrepeatable_read
--
-- Session B: Ibrahim Musa's two transfers from wallet 5, written with the
-- atomic UPDATE from 05. Each one commits while session A's statement
-- transaction is still open.
-- =====================================================================

\set session session_b
\ir two_session_clock.sql

-- From here on, psql prints each statement before its result.
\set ECHO queries

\echo
\echo '=== Session B: NGN 120,000.00 from wallet 5 to wallet 10, during part 1 ==='

SELECT pg_temp.step(2);

BEGIN;

-- Session A has read wallet 5 and its transaction is still open. A read
-- takes no row lock, so this UPDATE does not wait for it: the clock
-- after it shows t+2.1 (this session's first use of the table), well
-- before A's transaction ends at t+3.
UPDATE wallets SET balance = balance - 120000.00
WHERE wallet_id = 5 AND balance >= 120000.00
RETURNING wallet_id, balance;

SELECT :ROW_COUNT = 1 AS debited \gset
SELECT pg_temp.clock();

\if :debited
    -- This transaction's id: the xmin of the row version it just wrote.
    SELECT pg_current_xact_id() AS session_b_xid;

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

    COMMIT;
\else
    \echo 'Not enough money in wallet 5: nothing was debited, so the transfer is cancelled.'
    ROLLBACK;
\endif

\echo
\echo '=== Session B: NGN 80,000.00 from wallet 5 to wallet 14, during part 2 ==='

SELECT pg_temp.step(5);

BEGIN;

UPDATE wallets SET balance = balance - 80000.00
WHERE wallet_id = 5 AND balance >= 80000.00
RETURNING wallet_id, balance;

SELECT :ROW_COUNT = 1 AS debited \gset
SELECT pg_temp.clock();

\if :debited
    SELECT pg_current_xact_id() AS session_b_xid;

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
    \echo 'Not enough money in wallet 5: nothing was debited, so the transfer is cancelled.'
    ROLLBACK;
\endif

-- Session A reads wallet 5 again at t+6 and checks the result.
