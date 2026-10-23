-- =====================================================================
-- Portfolio 3: Transactions and concurrency
-- 08_deadlock_session_a.sql  A deadlock from two opposite transfers.
--                            Session A. Session B is 08_deadlock_session_b.sql.
--
-- Run both sessions together from the repo root (see README):
--   .\portfolio-3-transactions-concurrency\run_two_sessions.ps1 08_deadlock
--
-- Scenario: at the same moment, Ibrahim Musa (wallet 5, NGN 300,000.00)
-- pays Tunde Bakare (wallet 9, NGN 265,000.00) NGN 50,000.00 for a
-- generator repair (session A), and Tunde refunds Ibrahim NGN 30,000.00
-- for an earlier overpayment (session B). Both sessions run the same
-- transfer code, the atomic UPDATE from 05: debit the sender, record the
-- transfer, credit the receiver, add the ledger rows. Each UPDATE locks
-- its wallet row until the end of the transaction, so A locks 5 then 9,
-- and B locks 9 then 5: the opposite order.
--
-- Timeline (seconds after the shared start time):
--   t+1  A  BEGIN; debits wallet 5 (locks it); records transfer 1
--   t+2  B  BEGIN; debits wallet 9 (locks it); records transfer 2
--   t+3  A  credits wallet 9: waits for B
--   t+4  B  shows A waiting for B
--   t+5  B  credits wallet 5: waits for A. Each now waits for the other.
--   t+6  B  after deadlock_timeout (1 s) PostgreSQL finds the cycle and
--          aborts B with "deadlock detected"; B rolls back
--          A  gets wallet 9 the moment B's locks are released, COMMIT
--   t+7  A  checks the result
--
-- Process and transaction ids change on every run; everything else in
-- the output stays the same.
-- =====================================================================

\ir ../../portfolio-1-database-design/sql/01_schema.sql
\ir ../../portfolio-1-database-design/sql/02_sample_data.sql

\set session session_a
\ir two_session_clock.sql

-- From here on, psql prints each statement before its result.
\set ECHO queries

\echo
\echo '=== Session A: NGN 50,000.00 from wallet 5 to wallet 9 ==='

SELECT pg_temp.step(1);

BEGIN;

-- Debit the sender. This locks wallet 5 until COMMIT.
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

-- The ids that PostgreSQL's deadlock message will use for this session.
SELECT pg_backend_pid() AS session_a_pid, pg_current_xact_id() AS session_a_xid;

INSERT INTO transfers (reference, sender_wallet_id, receiver_wallet_id, amount,
                       narration, status, processed_at)
VALUES ('TRF2610230001', 5, 9, 50000.00, 'Generator repair', 'completed', now())
RETURNING transfer_id, reference, status;

SELECT pg_temp.step(3);

-- Credit the receiver. Session B debited wallet 9 at t+2 and holds its
-- row lock, so this UPDATE waits.
UPDATE wallets SET balance = balance + 50000.00
WHERE wallet_id = 9
RETURNING wallet_id, balance;

-- The wait ends when PostgreSQL aborts session B and its locks go.
SELECT pg_temp.clock();

INSERT INTO transactions (reference, wallet_id, transaction_type, amount, transfer_id, narration)
SELECT v.reference, v.wallet_id, v.transaction_type, 50000.00, t.transfer_id, 'Generator repair'
FROM transfers t
CROSS JOIN (VALUES ('TXN2610230001', 5, 'transfer_out'),
                   ('TXN2610230002', 9, 'transfer_in')) AS v (reference, wallet_id, transaction_type)
WHERE t.reference = 'TRF2610230001'
RETURNING transaction_id, reference, wallet_id, transaction_type, amount;

COMMIT;

SELECT pg_temp.step(7);

\echo
\echo '=== Result after session A committed and session B was rolled back ==='

-- Session A's transfer went through: wallet 5 300,000.00 - 50,000.00 =
-- 250,000.00, wallet 9 265,000.00 + 50,000.00 = 315,000.00. Session B's
-- refund was undone completely.
SELECT w.wallet_id, c.first_name || ' ' || c.last_name AS owner, w.balance
FROM wallets w JOIN customers c USING (customer_id)
WHERE w.wallet_id IN (5, 9)
ORDER BY w.wallet_id;

-- Only session A's transfer exists, with its two ledger rows.
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
