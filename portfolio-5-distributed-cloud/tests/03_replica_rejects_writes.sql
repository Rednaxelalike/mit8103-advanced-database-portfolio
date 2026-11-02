-- =====================================================================
-- Portfolio 5: Distributed and cloud database
-- 03_replica_rejects_writes.sql  The port-5433 replica answers reads but
--                                refuses every kind of write.
--
-- Needs the replica built and started as in setup-replica.md.
-- Run from the repo root (see SETUP.md for loading PGPASSWORD). Note the
-- port: this script runs on the replica only.
--   psql -X -w -U postgres -h localhost -p 5433 -d proclus
--        -f portfolio-5-distributed-cloud/tests/03_replica_rejects_writes.sql
--
-- Changes nothing, so it can be run at any time. Each write below fails
-- on purpose, so ON_ERROR_STOP stays off; after each one the script
-- prints the SQLSTATE psql recorded. 25006 is read_only_sql_transaction;
-- 3.7 gets 0A000 instead.
-- (Portfolio 1 used pg_temp.expect_error for this, but the replica cannot
-- create even a temporary function.)
-- =====================================================================

\set ON_ERROR_STOP off
\set ECHO queries

\echo
\echo '=== Which server is this? ==='
\echo

SELECT inet_server_port() AS port, pg_is_in_recovery() AS in_recovery,
       current_setting('transaction_read_only') AS transaction_read_only;

\echo
\echo '=== Reads work: Chinedu Okafor''s wallet and row counts ==='
\echo

SELECT inet_server_port() AS port, w.wallet_id,
       c.first_name || ' ' || c.last_name AS owner, w.balance
FROM wallets w JOIN customers c USING (customer_id)
WHERE w.wallet_id = 1;

SELECT inet_server_port() AS port,
       (SELECT count(*) FROM transactions)  AS ledger_rows,
       (SELECT count(*) FROM beneficiaries) AS beneficiaries;

\echo
\echo '=== Writes are refused ==='
\echo

\echo '--- 3.1 UPDATE a balance'
UPDATE wallets SET balance = balance + 1000.00 WHERE wallet_id = 1;
\echo 'SQLSTATE:' :LAST_ERROR_SQLSTATE

\echo '--- 3.2 INSERT a ledger row'
INSERT INTO transactions (reference, wallet_id, transaction_type, amount, narration)
VALUES ('TXN2611029999', 1, 'funding', 1000.00, 'Written to the replica');
\echo 'SQLSTATE:' :LAST_ERROR_SQLSTATE

\echo '--- 3.3 DELETE a saved beneficiary'
DELETE FROM beneficiaries WHERE beneficiary_id = 1;
\echo 'SQLSTATE:' :LAST_ERROR_SQLSTATE

\echo '--- 3.4 Lock a wallet row, as the Portfolio 3 fix does before a transfer'
SELECT wallet_id, balance FROM wallets WHERE wallet_id = 1 FOR UPDATE;
\echo 'SQLSTATE:' :LAST_ERROR_SQLSTATE

\echo '--- 3.5 Take the next ledger id from its sequence'
SELECT nextval(pg_get_serial_sequence('transactions', 'transaction_id'));
\echo 'SQLSTATE:' :LAST_ERROR_SQLSTATE

\echo '--- 3.6 CREATE a table'
CREATE TABLE replica_scratch (id int);
\echo 'SQLSTATE:' :LAST_ERROR_SQLSTATE

\echo '--- 3.7 Ask for a read-write transaction'
-- Refused with 0A000 (feature_not_supported): a standby cannot run
-- read-write transactions at all, so no transaction is opened.
BEGIN READ WRITE;
\echo 'SQLSTATE:' :LAST_ERROR_SQLSTATE

\echo '--- 3.8 Switch the session to read-write'
SET default_transaction_read_only = off;
UPDATE wallets SET balance = balance + 1000.00 WHERE wallet_id = 1;
\echo 'SQLSTATE:' :LAST_ERROR_SQLSTATE

\echo
\echo '=== Nothing changed ==='
\echo

-- The same balance and counts as before the attempts.
SELECT inet_server_port() AS port, wallet_id, balance FROM wallets WHERE wallet_id = 1;

SELECT inet_server_port() AS port,
       (SELECT count(*) FROM transactions)  AS ledger_rows,
       (SELECT count(*) FROM beneficiaries) AS beneficiaries,
       to_regclass('replica_scratch') AS replica_scratch_table;
