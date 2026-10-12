-- =====================================================================
-- Portfolio 2: Query processing and optimisation
-- 03_indexes.sql  Adds four indexes, each aimed at queries in
--                 02_queries.sql, refreshes the planner's statistics,
--                 adds extended statistics for Q2's grouping, and
--                 measures what the indexes cost: disk space, and slower
--                 bulk inserts into the ledger.
--
-- Run from the repo root after 01_seed_large.sql and the "before" run
-- of 02_queries.sql:
--   psql -w -U postgres -h localhost -p 5432 -d proclus -v ON_ERROR_STOP=1
--        -f portfolio-2-query-optimisation/sql/03_indexes.sql
-- Then run 02_queries.sql again with -v plan_dir=.../plans/after.
--
-- Re-runnable: the four indexes and the statistics object are dropped
-- first and built again, and
-- the insert test works on a scratch copy of the ledger that is dropped
-- at the end. No data changes. It takes about three minutes, most of it
-- the insert test.
--
-- The four indexes:
--   1. transactions (wallet_id, created_at)     composite B-tree: Q1, Q5a, Q5b
--   2. transfers (created_at) WHERE pending     partial index:    Q7
--   3. transactions (created_at) INCLUDE (...)  covering index:   Q2, Q3
--   4. customers (lower(email)), UNIQUE         expression index: Q8
-- Plus one extended-statistics object (step 5), for Q2's group estimate.
-- Q4 and Q6 get no index of their own; results/performance.md explains
-- what happened to their plans.
--
-- On a live wallet these would be built with CREATE INDEX CONCURRENTLY,
-- which takes longer but does not block transfers while it runs. Nothing
-- else writes to this database, so a plain build is used here.
-- =====================================================================

SET TIME ZONE 'Africa/Lagos';

DROP INDEX IF EXISTS transactions_wallet_id_created_at_idx,
                     transfers_pending_created_at_idx,
                     transactions_created_at_covering_idx,
                     customers_lower_email_key;
DROP STATISTICS IF EXISTS transactions_month_type_stats;

\echo
\echo '=== Ledger indexes before Portfolio 2 (primary key and unique keys only) ==='
SELECT indexname,
       pg_size_pretty(pg_relation_size(format('%I.%I', schemaname, indexname)::regclass)) AS index_size
FROM pg_indexes
WHERE tablename = 'transactions'
ORDER BY indexname;

-- ---------------------------------------------------------------------
-- 1. Composite B-tree for the wallet statement (Q1) and running balance
--    (Q5a, Q5b): "rows of one wallet in a time range".
--    Column order matters. wallet_id comes first because the queries ask
--    for one value of it (equality); created_at second because they ask
--    for a range. Inside the index all entries of wallet 6645 are then
--    side by side, already in time order, so a statement is one short
--    read of neighbouring entries and needs no sort. The other order,
--    (created_at, wallet_id), would put a month of every wallet's rows
--    between the first and last entry the query needs.
-- ---------------------------------------------------------------------
\echo '=== Building the four indexes ==='
\timing on
CREATE INDEX transactions_wallet_id_created_at_idx
    ON transactions (wallet_id, created_at);
\timing off

-- ---------------------------------------------------------------------
-- 2. Partial index for the held-transfer queue (Q7).
--    Only rows matching the WHERE clause are indexed: about 135 pending
--    transfers out of 199,051. The index stays tiny, costs almost nothing
--    to maintain (only inserts and status changes of pending transfers
--    touch it), and holds the queue already in created_at order. The
--    planner can use it only for queries whose WHERE includes
--    status = 'pending'.
-- ---------------------------------------------------------------------
\timing on
CREATE INDEX transfers_pending_created_at_idx
    ON transfers (created_at)
    WHERE status = 'pending';
\timing off

-- ---------------------------------------------------------------------
-- 3. Covering index for the date-range reports: monthly totals (Q2) and
--    top merchants (Q3).
--    The key is created_at, so a date range is one contiguous part of
--    the index. INCLUDE stores four more columns in the index's leaf
--    entries without making them part of the key: they cannot be
--    searched on, but every column Q2 and Q3 read from transactions is
--    then in the index, so PostgreSQL can answer from the index alone
--    (an Index Only Scan) without visiting the table. That works only
--    for pages VACUUM has marked all-visible, which 01_seed_large.sql
--    and the VACUUM below take care of.
-- ---------------------------------------------------------------------
\timing on
CREATE INDEX transactions_created_at_covering_idx
    ON transactions (created_at)
    INCLUDE (transaction_type, status, merchant_id, amount);
\timing off

-- ---------------------------------------------------------------------
-- 4. Expression index for the case-insensitive email look-up (Q8).
--    The index stores lower(email), so it matches a WHERE clause written
--    on exactly that expression. The existing customers_email_key index
--    on email itself cannot help: lower(email) is a different value.
--    Made UNIQUE, it also closes the gap noted in Portfolio 1:
--    Ada@example.com and ada@example.com can no longer belong to two
--    customers.
-- ---------------------------------------------------------------------
\timing on
CREATE UNIQUE INDEX customers_lower_email_key
    ON customers (lower(email));
\timing off

-- ---------------------------------------------------------------------
-- Refresh the planner's statistics, as the guide asks after adding
-- indexes. ANALYZE also collects statistics on the indexed expression
-- lower(email), which the planner uses to estimate how many customers
-- match a given email. VACUUM keeps the visibility map current for
-- index-only scans.
-- ---------------------------------------------------------------------
VACUUM (ANALYZE) transactions, transfers, customers;

-- =====================================================================
-- 5. Extended statistics for the monthly totals (Q2).
--    The "before" plan of Q2 showed the planner expecting 452,532 groups
--    for month x transaction type when there are 15. PostgreSQL keeps
--    statistics on columns, not on date_trunc('month', created_at), so
--    it has to guess how many distinct months there are, and it guesses
--    high. Expecting that many groups, it sorts half a million rows on
--    disk instead of using a small in-memory hash table.
--    CREATE STATISTICS ... (ndistinct) tells ANALYZE to count the
--    distinct values of exactly the expression Q2 groups by, together
--    with transaction_type. It is not an index: it takes no space in the
--    table's pages and adds no work to inserts, only a little to ANALYZE.
--    The expression must match Q2's GROUP BY exactly, including the
--    ::date cast, or the planner will not use the statistics.
--
--    Q2 runs five times with the indexes alone, then five times with the
--    statistics added, so the log shows what each fix contributes. The
--    query text is the same as in 02_queries.sql.
-- =====================================================================

-- Runs p_sql p_runs times under EXPLAIN (ANALYZE, BUFFERS) and returns
-- the time of every run, the median, and the median run's plan.
CREATE OR REPLACE FUNCTION pg_temp.median_plan(p_sql text, p_runs int DEFAULT 5)
RETURNS SETOF text
LANGUAGE plpgsql AS $$
DECLARE
    plan_line  text;
    plan_text  text;
    exec_ms    numeric;
    times      numeric[] := '{}';
    plans      text[]    := '{}';
    median_run int;
BEGIN
    FOR run IN 1 .. p_runs LOOP
        plan_text := '';
        FOR plan_line IN EXECUTE 'EXPLAIN (ANALYZE, BUFFERS) ' || p_sql LOOP
            plan_text := plan_text || plan_line || E'\n';
            IF plan_line LIKE 'Execution Time:%' THEN
                exec_ms := substring(plan_line FROM '([0-9.]+) ms')::numeric;
            END IF;
        END LOOP;
        times := times || exec_ms;
        plans := plans || plan_text;
    END LOOP;

    -- The median run is the middle one when the runs are sorted by time.
    SELECT r INTO median_run
    FROM unnest(times) WITH ORDINALITY AS u(ms, r)
    ORDER BY ms, r
    OFFSET (p_runs - 1) / 2
    LIMIT 1;

    RETURN NEXT format('Execution time of %s runs (ms): %s', p_runs, array_to_string(times, ', '));
    RETURN NEXT format('Median: %s ms (run %s). The plan of that run follows.',
                       times[median_run], median_run);
    RETURN NEXT '';
    RETURN QUERY SELECT line
                 FROM regexp_split_to_table(rtrim(plans[median_run], E'\n'), E'\n') AS line;
END
$$;

\set q2_sql 'SELECT date_trunc(''month'', created_at)::date AS month, transaction_type, count(*) AS row_count, sum(amount) AS total_ngn FROM transactions WHERE status = ''completed'' AND created_at >= ''2026-07-01 00:00+01'' AND created_at < ''2026-10-01 00:00+01'' GROUP BY 1, 2 ORDER BY 1, 2'

\pset format unaligned
\pset tuples_only on
\echo
\echo '=== Q2 with the new indexes, before the extended statistics ==='
SELECT pg_temp.median_plan(:'q2_sql');

CREATE STATISTICS transactions_month_type_stats (ndistinct)
    ON ((date_trunc('month', created_at))::date), transaction_type
    FROM transactions;
ANALYZE transactions;

\echo
\echo '=== Q2 with the new indexes and the extended statistics ==='
SELECT pg_temp.median_plan(:'q2_sql');
\pset tuples_only off
\pset format aligned

\echo
\echo '=== What ANALYZE counted: distinct (month, type) pairs in the sample ==='
SELECT statistics_name, n_distinct
FROM pg_stats_ext
WHERE statistics_name = 'transactions_month_type_stats';

-- =====================================================================
-- Cost 1: disk space.
-- =====================================================================
\echo '=== Size of each new index next to its table ==='
SELECT i.relname AS index_name,
       t.relname AS table_name,
       pg_size_pretty(pg_relation_size(i.oid)) AS index_size,
       pg_size_pretty(pg_relation_size(t.oid)) AS table_size,
       round(100.0 * pg_relation_size(i.oid) / pg_relation_size(t.oid), 1) AS index_as_pct_of_table
FROM pg_index x
JOIN pg_class i ON i.oid = x.indexrelid
JOIN pg_class t ON t.oid = x.indrelid
WHERE i.relname IN ('transactions_wallet_id_created_at_idx', 'transfers_pending_created_at_idx',
                    'transactions_created_at_covering_idx', 'customers_lower_email_key')
ORDER BY pg_relation_size(i.oid) DESC;

\echo '=== All indexes on the ledger now ==='
SELECT indexname,
       pg_size_pretty(pg_relation_size(format('%I.%I', schemaname, indexname)::regclass)) AS index_size
FROM pg_indexes
WHERE tablename = 'transactions'
ORDER BY indexname;

-- =====================================================================
-- Cost 2: slower inserts.
-- Every index on a table is updated on every insert, so each new index
-- makes writes slower. The two new ledger indexes are the ones that
-- matter here: the ledger takes a row for every money movement.
--
-- The test runs on a scratch copy of the ledger (p2_insert_test), so it
-- never touches the real table: same 1,040,093 rows, same primary key
-- and unique keys. Each run inserts 100,000 funding rows, times the
-- insert, then undoes it (raising an error inside BEGIN ... EXCEPTION
-- rolls back everything done in that block). Five runs without the two
-- new indexes, then the same two indexes are added to the copy and
-- five runs with them.
-- A rolled-back row still occupies space until VACUUM clears it, and a
-- checkpoint (PostgreSQL flushing changed pages to disk) can start in
-- the middle of a run. So VACUUM and CHECKPOINT run before every timed
-- insert, and the median of the five runs is reported.
-- =====================================================================
DROP TABLE IF EXISTS p2_insert_test;

\echo '=== Insert test: copying the ledger ==='
\timing on
CREATE TABLE p2_insert_test AS
SELECT * FROM transactions;

ALTER TABLE p2_insert_test
    ADD PRIMARY KEY (transaction_id),
    ADD UNIQUE (reference),
    ADD UNIQUE (transfer_id, transaction_type);
\timing off

-- The table of results lives in the session's temporary schema. On a
-- fresh session that schema does not exist yet and PostgreSQL says so in
-- a notice when asked to drop from it; hide that notice.
SET client_min_messages = warning;
DROP TABLE IF EXISTS pg_temp.p2_insert_cost;
RESET client_min_messages;
CREATE TEMP TABLE p2_insert_cost (
    indexes     text,
    run         int,
    row_count   int,
    elapsed_ms  numeric
);

-- One timed, rolled-back insert of p_rows rows. Returns the time in ms.
-- Wallet ids are spread over all 58,558 generated wallets, as real
-- top-ups would be, so the inserts land all over the wallet index.
CREATE OR REPLACE FUNCTION pg_temp.timed_bulk_insert(p_indexes text, p_run int,
                                                     p_rows int DEFAULT 100000)
RETURNS numeric
LANGUAGE plpgsql AS $$
DECLARE
    started   timestamptz;
    finished  timestamptz;
    elapsed   numeric;
BEGIN
    BEGIN
        started := clock_timestamp();
        INSERT INTO p2_insert_test (transaction_id, reference, wallet_id, transaction_type,
                                    amount, status, narration, created_at)
        SELECT 2000000 + n,
               'TEST' || lpad(n::text, 9, '0'),
               26 + (n * 7919) % 58558,
               'funding',
               1000.00,
               'completed',
               'Bulk insert cost test',
               TIMESTAMPTZ '2026-10-09 00:00+01' + n * interval '1 second'
        FROM generate_series(1, p_rows) AS n;
        finished := clock_timestamp();
        RAISE EXCEPTION 'undo the test insert';
    EXCEPTION
        WHEN raise_exception THEN
            -- The insert is already rolled back here; only the time is kept.
            elapsed := round(extract(epoch FROM finished - started) * 1000, 1);
            INSERT INTO p2_insert_cost VALUES (p_indexes, p_run, p_rows, elapsed);
    END;
    RETURN elapsed;
END
$$;

\echo '=== Insert test without the new indexes (ms per run) ==='
VACUUM (ANALYZE) p2_insert_test;
CHECKPOINT;
SELECT pg_temp.timed_bulk_insert('without new indexes', 1) AS run_1_ms;
VACUUM p2_insert_test;
CHECKPOINT;
SELECT pg_temp.timed_bulk_insert('without new indexes', 2) AS run_2_ms;
VACUUM p2_insert_test;
CHECKPOINT;
SELECT pg_temp.timed_bulk_insert('without new indexes', 3) AS run_3_ms;
VACUUM p2_insert_test;
CHECKPOINT;
SELECT pg_temp.timed_bulk_insert('without new indexes', 4) AS run_4_ms;
VACUUM p2_insert_test;
CHECKPOINT;
SELECT pg_temp.timed_bulk_insert('without new indexes', 5) AS run_5_ms;

\echo '=== Insert test: adding the two new ledger indexes to the copy ==='
VACUUM p2_insert_test;
CREATE INDEX ON p2_insert_test (wallet_id, created_at);
CREATE INDEX ON p2_insert_test (created_at) INCLUDE (transaction_type, status, merchant_id, amount);

\echo '=== Insert test with the new indexes (ms per run) ==='
VACUUM (ANALYZE) p2_insert_test;
CHECKPOINT;
SELECT pg_temp.timed_bulk_insert('with new indexes', 1) AS run_1_ms;
VACUUM p2_insert_test;
CHECKPOINT;
SELECT pg_temp.timed_bulk_insert('with new indexes', 2) AS run_2_ms;
VACUUM p2_insert_test;
CHECKPOINT;
SELECT pg_temp.timed_bulk_insert('with new indexes', 3) AS run_3_ms;
VACUUM p2_insert_test;
CHECKPOINT;
SELECT pg_temp.timed_bulk_insert('with new indexes', 4) AS run_4_ms;
VACUUM p2_insert_test;
CHECKPOINT;
SELECT pg_temp.timed_bulk_insert('with new indexes', 5) AS run_5_ms;

DROP TABLE p2_insert_test;

\echo '=== Time to insert 100,000 ledger rows (5 runs each, ms) ==='
SELECT indexes,
       string_agg(elapsed_ms::text, ', ' ORDER BY run)          AS runs_ms,
       percentile_disc(0.5) WITHIN GROUP (ORDER BY elapsed_ms)  AS median_ms
FROM p2_insert_cost
GROUP BY indexes
ORDER BY median_ms;

\echo '=== Slowdown from the two new ledger indexes (medians) ==='
SELECT round(100.0 * (w.median_ms - wo.median_ms) / wo.median_ms, 1) AS pct_slower
FROM (SELECT percentile_disc(0.5) WITHIN GROUP (ORDER BY elapsed_ms) AS median_ms
      FROM p2_insert_cost WHERE indexes = 'with new indexes') w,
     (SELECT percentile_disc(0.5) WITHIN GROUP (ORDER BY elapsed_ms) AS median_ms
      FROM p2_insert_cost WHERE indexes = 'without new indexes') wo;

\echo '=== The real ledger is unchanged ==='
SELECT count(*) AS ledger_rows FROM transactions;
