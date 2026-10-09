-- =====================================================================
-- Portfolio 1: Database design and modelling
-- 03_constraint_tests.sql  Proves that every rule in 01_schema.sql rejects
-- the bad data it was written to stop.
--
-- Run after 01_schema.sql and 02_sample_data.sql, from the repo root:
--   psql -w -U postgres -h localhost -p 5432 -d proclus -v ON_ERROR_STOP=1
--        -f portfolio-1-database-design/sql/03_constraint_tests.sql
--
-- Re-runnable and leaves the data unchanged: every bad statement is rolled
-- back, and Part 2 runs inside a transaction that ends in ROLLBACK.
--
-- How a test works. Each row in Part 1 holds one bad statement and the
-- SQLSTATE error code it must fail with:
--   23514 check_violation        23505 unique_violation
--   23503 foreign_key_violation  23502 not_null_violation
--   23001 restrict_violation     22003 numeric_value_out_of_range
-- An ON DELETE RESTRICT breach is reported as 23001, not 23503: PostgreSQL
-- uses 23503 only for the default NO ACTION rule.
-- pg_temp.expect_error() runs the statement. If PostgreSQL rejects it with
-- the expected code, the function returns PostgreSQL's own error message,
-- which is printed next to the test. If the statement is accepted, or fails
-- for a different reason, the function raises an error and the script stops.
-- So a complete result table means every test passed.
-- =====================================================================

-- A temporary function: it lives only for this session (schema pg_temp).
-- OR REPLACE lets the script run twice in one session, e.g. in pgAdmin.
CREATE OR REPLACE FUNCTION pg_temp.expect_error(stmt text, expected_sqlstate text)
RETURNS text
LANGUAGE plpgsql
AS $$
BEGIN
    EXECUTE stmt;
    -- Reaching this line means the bad statement was accepted.
    RAISE EXCEPTION 'TEST FAILED, statement was accepted: %', stmt;
EXCEPTION
    WHEN OTHERS THEN
        -- Any error lands here, and the block's changes are rolled back.
        IF SQLSTATE = expected_sqlstate THEN
            RETURN SQLERRM;
        END IF;
        RAISE;   -- wrong error, or the 'accepted' failure above: stop the script
END
$$;

-- ---------------------------------------------------------------------
-- Part 1: bad inserts, updates and deletes that must be rejected.
-- ---------------------------------------------------------------------
SELECT t.test,
       t.rule,
       t.expected,
       pg_temp.expect_error(t.stmt, t.sqlstate) AS database_message
FROM (VALUES
    -- CHECK constraints: amounts, balances and fixed value sets
    ('T01', 'A wallet balance can never go below zero (overdraft)', 'check_violation', '23514',
     $$UPDATE wallets SET balance = balance - 50000.00 WHERE wallet_id = 2$$),
    ('T02', 'A ledger amount must be greater than zero', 'check_violation', '23514',
     $$INSERT INTO transactions (reference, wallet_id, transaction_type, amount)
       VALUES ('TEST02', 1, 'funding', 0.00)$$),
    ('T03', 'A transfer amount must be greater than zero', 'check_violation', '23514',
     $$INSERT INTO transfers (reference, sender_wallet_id, receiver_wallet_id, amount)
       VALUES ('TEST03', 1, 2, -500.00)$$),
    ('T04', 'A wallet cannot transfer to itself', 'check_violation', '23514',
     $$INSERT INTO transfers (reference, sender_wallet_id, receiver_wallet_id, amount)
       VALUES ('TEST04', 3, 3, 1000.00)$$),
    ('T05', 'Wallet status must be active, frozen or closed', 'check_violation', '23514',
     $$UPDATE wallets SET status = 'deleted' WHERE wallet_id = 5$$),
    ('T06', 'Transaction type must be one of the five ledger types', 'check_violation', '23514',
     $$INSERT INTO transactions (reference, wallet_id, transaction_type, amount)
       VALUES ('TEST06', 1, 'withdrawal', 1000.00)$$),
    ('T07', 'A merchant payment must name its merchant', 'check_violation', '23514',
     $$INSERT INTO transactions (reference, wallet_id, transaction_type, amount)
       VALUES ('TEST07', 1, 'merchant_payment', 2500.00)$$),
    ('T08', 'A transfer leg must point at its transfer', 'check_violation', '23514',
     $$INSERT INTO transactions (reference, wallet_id, transaction_type, amount)
       VALUES ('TEST08', 1, 'transfer_out', 2500.00)$$),
    ('T09', 'A failed transfer must record why it failed', 'check_violation', '23514',
     $$INSERT INTO transfers (reference, sender_wallet_id, receiver_wallet_id, amount, status, processed_at)
       VALUES ('TEST09', 1, 2, 1000.00, 'failed', now())$$),
    ('T10', 'A transfer cannot be processed before it was created', 'check_violation', '23514',
     $$INSERT INTO transfers (reference, sender_wallet_id, receiver_wallet_id, amount, status,
                              created_at, processed_at)
       VALUES ('TEST10', 1, 2, 1000.00, 'completed', '2026-10-09 10:00+01', '2026-10-09 09:00+01')$$),
    ('T11', 'A verified KYC document must record who reviewed it and when', 'check_violation', '23514',
     $$INSERT INTO kyc_documents (customer_id, document_type, document_number, status)
       VALUES (10, 'nin', '12345678901', 'verified')$$),
    ('T12', 'A BVN must be exactly 11 digits', 'check_violation', '23514',
     $$INSERT INTO kyc_documents (customer_id, document_type, document_number)
       VALUES (10, 'bvn', '2214-0583')$$),
    ('T13', 'KYC tier must be 1, 2 or 3', 'check_violation', '23514',
     $$UPDATE customers SET kyc_tier = 4 WHERE customer_id = 1$$),
    ('T14', 'A phone number must be in +234 international form', 'check_violation', '23514',
     $$INSERT INTO customers (first_name, last_name, email, phone_number, date_of_birth)
       VALUES ('Bisi', 'Test', 'bisi.test@example.com', '08031234567', '1995-01-01')$$),
    ('T15', 'An audit entry must name its row, unless it is a balance audit', 'check_violation', '23514',
     $$INSERT INTO audit_log (entity_type, action, actor_type, actor_ref)
       VALUES ('wallet', 'status_changed', 'staff', 'compliance.fatima')$$),
    -- NUMERIC(14,2): at most 12 digits before the decimal point
    ('T16', 'Money above NGN 999,999,999,999.99 does not fit NUMERIC(14,2)', 'numeric_value_out_of_range', '22003',
     $$INSERT INTO transactions (reference, wallet_id, transaction_type, amount)
       VALUES ('TEST16', 1, 'funding', 1000000000000.00)$$),
    -- UNIQUE constraints: candidate keys
    ('T17', 'Two customers cannot share an email', 'unique_violation', '23505',
     $$INSERT INTO customers (first_name, last_name, email, phone_number, date_of_birth)
       VALUES ('Bisi', 'Test', 'chinedu.okafor@example.com', '+2348039999999', '1995-01-01')$$),
    ('T18', 'Two customers cannot share a phone number', 'unique_violation', '23505',
     $$INSERT INTO customers (first_name, last_name, email, phone_number, date_of_birth)
       VALUES ('Bisi', 'Test', 'bisi.test@example.com', '+2348031000001', '1995-01-01')$$),
    ('T19', 'A customer cannot open a second main wallet', 'unique_violation', '23505',
     $$INSERT INTO wallets (customer_id, wallet_number, wallet_type)
       VALUES (2, '5999999999', 'main')$$),
    ('T20', 'Two wallets cannot share a wallet number', 'unique_violation', '23505',
     $$INSERT INTO wallets (customer_id, wallet_number, wallet_type)
       VALUES (2, '5012748390', 'savings')$$),
    ('T21', 'A BVN already on file cannot be registered to another customer', 'unique_violation', '23505',
     $$INSERT INTO kyc_documents (customer_id, document_type, document_number)
       VALUES (10, 'bvn', '22140583921')$$),
    ('T22', 'A customer cannot save the same beneficiary wallet twice', 'unique_violation', '23505',
     $$INSERT INTO beneficiaries (customer_id, wallet_id, nickname)
       VALUES (1, 4, 'Ngozi again')$$),
    ('T23', 'A ledger reference cannot be used twice (no double posting)', 'unique_violation', '23505',
     $$INSERT INTO transactions (reference, wallet_id, transaction_type, amount)
       VALUES ('TXN2608020001', 1, 'funding', 150000.00)$$),
    -- NOT NULL
    ('T24', 'A customer must have a last name', 'not_null_violation', '23502',
     $$INSERT INTO customers (first_name, email, phone_number, date_of_birth)
       VALUES ('Bisi', 'bisi.test@example.com', '+2348039999998', '1995-01-01')$$),
    -- FOREIGN KEY: references must exist
    ('T25', 'A wallet must belong to an existing customer', 'foreign_key_violation', '23503',
     $$INSERT INTO wallets (customer_id, wallet_number) VALUES (9999, '5999999998')$$),
    ('T26', 'A merchant payment must point at an existing merchant', 'foreign_key_violation', '23503',
     $$INSERT INTO transactions (reference, wallet_id, transaction_type, amount, merchant_id)
       VALUES ('TEST26', 1, 'merchant_payment', 500.00, 999)$$),
    -- ON DELETE RESTRICT: history cannot be deleted from under the ledger
    ('T27', 'ON DELETE RESTRICT: a customer who owns a wallet cannot be deleted', 'restrict_violation', '23001',
     $$DELETE FROM customers WHERE customer_id = 1$$),
    ('T28', 'ON DELETE RESTRICT: a wallet with transfers and ledger rows cannot be deleted', 'restrict_violation', '23001',
     $$DELETE FROM wallets WHERE wallet_id = 1$$),
    ('T29', 'ON DELETE RESTRICT: a merchant with payments cannot be deleted', 'restrict_violation', '23001',
     $$DELETE FROM merchants WHERE merchant_id = 1$$)
) AS t(test, rule, expected, sqlstate, stmt)
ORDER BY t.test;

-- ---------------------------------------------------------------------
-- Part 2: ON DELETE CASCADE removes what a customer owns.
-- A new customer with no wallet, one KYC document and one saved
-- beneficiary is created and deleted inside a transaction, then the
-- transaction is rolled back so the sample data is unchanged.
-- ---------------------------------------------------------------------
BEGIN;

INSERT INTO customers (first_name, last_name, email, phone_number, date_of_birth)
VALUES ('Adaobi', 'Test', 'adaobi.test@example.com', '+2348039999997', '1998-02-02');

INSERT INTO kyc_documents (customer_id, document_type, document_number)
SELECT customer_id, 'nin', '99999999999' FROM customers WHERE email = 'adaobi.test@example.com';

INSERT INTO beneficiaries (customer_id, wallet_id, nickname)
SELECT customer_id, 1, 'Chinedu (cascade test)' FROM customers WHERE email = 'adaobi.test@example.com';

SELECT 'before delete' AS moment,
       (SELECT count(*) FROM kyc_documents WHERE document_number = '99999999999')        AS kyc_documents,
       (SELECT count(*) FROM beneficiaries WHERE nickname = 'Chinedu (cascade test)')    AS beneficiaries;

DELETE FROM customers WHERE email = 'adaobi.test@example.com';

SELECT 'after delete' AS moment,
       (SELECT count(*) FROM kyc_documents WHERE document_number = '99999999999')        AS kyc_documents,
       (SELECT count(*) FROM beneficiaries WHERE nickname = 'Chinedu (cascade test)')    AS beneficiaries;

ROLLBACK;

-- ---------------------------------------------------------------------
-- Part 3: the sample data is exactly as 02_sample_data.sql left it.
-- ---------------------------------------------------------------------
DO $$
BEGIN
    IF (SELECT count(*) FROM customers)     <> 20
    OR (SELECT count(*) FROM merchants)     <> 12
    OR (SELECT count(*) FROM kyc_documents) <> 31
    OR (SELECT count(*) FROM wallets)       <> 25
    OR (SELECT count(*) FROM transfers)     <> 12
    OR (SELECT count(*) FROM transactions)  <> 47
    OR (SELECT count(*) FROM beneficiaries) <> 18
    OR (SELECT count(*) FROM audit_log)     <> 37
    OR (SELECT balance FROM wallets WHERE wallet_id = 2) <> 23500.00
    THEN
        RAISE EXCEPTION 'Sample data changed during the tests';
    END IF;
    RAISE NOTICE 'Sample data unchanged: no rejected statement left anything behind';
END
$$;
