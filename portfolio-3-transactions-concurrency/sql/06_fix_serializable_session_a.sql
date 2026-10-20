-- =====================================================================
-- Portfolio 3: Transactions and concurrency
-- 06_fix_serializable_session_a.sql  Fix 3 for the lost update: run the
--                                    same read-then-write code under
--                                    SERIALIZABLE and retry on a
--                                    serialization failure. Session A.
--                                    Session B is 06_fix_serializable_session_b.sql.
--
-- Run both sessions together from the repo root (see README):
--   .\portfolio-3-transactions-concurrency\run_two_sessions.ps1 06_fix_serializable
--
-- Same scenario, amounts, timeline and application code as 03_lost_update:
-- read the balance, work out the new one, write it back. The one change is
-- BEGIN ISOLATION LEVEL SERIALIZABLE. Each transaction then works from one
-- snapshot taken at its first statement. When session B tries to update a
-- row that session A changed and committed after B's snapshot was taken,
-- PostgreSQL refuses with a serialization failure (SQLSTATE 40001) instead
-- of letting B overwrite A's change. B rolls back and runs the whole
-- transaction again; the retry starts a new snapshot and sees A's balance.
-- (REPEATABLE READ gives the same error in this case.)
--
-- Timeline (seconds after the shared start time):
--   t+1  A  BEGIN SERIALIZABLE; reads 300,000.00
--   t+2  B  BEGIN SERIALIZABLE; reads 300,000.00
--   t+3  A  writes 300,000.00 - 120,000.00 = 180,000.00, records the transfer
--   t+4  A  COMMIT
--   t+5  B  tries to write 220,000.00: serialization failure, ROLLBACK;
--          retries: reads 180,000.00, writes 100,000.00, records the transfer, COMMIT
--   t+6  A  checks the result
-- =====================================================================

\ir ../../portfolio-1-database-design/sql/01_schema.sql
\ir ../../portfolio-1-database-design/sql/02_sample_data.sql

\set session session_a
\ir two_session_clock.sql

-- From here on, psql prints each statement before its result.
\set ECHO queries

\echo
\echo '=== Session A: NGN 120,000.00 from wallet 5 to wallet 10, under SERIALIZABLE ==='

SELECT pg_temp.step(1);

-- The only change from 03: the isolation level.
BEGIN ISOLATION LEVEL SERIALIZABLE;

SHOW transaction_isolation;

-- The snapshot is taken here, at the transaction's first query.
SELECT balance FROM wallets WHERE wallet_id = 5 \gset a_
\echo 'Session A read the balance of wallet 5:' :a_balance

SELECT pg_temp.step(3);

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

-- Session A updated wallet 5 first, so its COMMIT succeeds.
COMMIT;

-- Session B fails, retries and commits at t+5. Look at the result after that.
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
