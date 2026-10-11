-- =====================================================================
-- Portfolio 2: Query processing and optimisation
-- 02_queries.sql  Eight queries behind real Proclus operations, plus a
--                 first, slow version of one of them (Q5a). For each
--                 query it prints the result, then runs
--                 EXPLAIN (ANALYZE, BUFFERS) five times and saves the plan
--                 of the median run to a text file.
--
-- Run from the repo root, naming the folder the plans go to.
--   Before the indexes, straight after 01_seed_large.sql:
--     psql -w -U postgres -h localhost -p 5432 -d proclus -v ON_ERROR_STOP=1
--          -v plan_dir=portfolio-2-query-optimisation/plans/before
--          -f portfolio-2-query-optimisation/sql/02_queries.sql
--   After 03_indexes.sql: the same command with plans/after.
--
-- Re-runnable and read-only: it changes no data. Its helper tables and
-- function live in the session's temporary schema and vanish when the
-- session ends.
--
-- Fixed dates: the data ends on 8 October 2026, so "today" is
-- 9 October 2026 00:00 Lagos time in every query. now() would give a
-- different answer depending on the day the script is run.
--
-- Timing: EXPLAIN ANALYZE runs the query for real and reports how long
-- the server spent executing it ("Execution Time"), without the time to
-- send rows to the client. The first run may read pages from disk while
-- later runs find them in memory, so every query runs five times; the
-- median is reported and the plan saved is the median run's.
-- =====================================================================

\if :{?plan_dir}
\else
    \echo 'Name the folder for the plans, for example:'
    \echo '  -v plan_dir=portfolio-2-query-optimisation/plans/before'
    DO $$ BEGIN RAISE EXCEPTION 'psql variable plan_dir is not set'; END $$;
\endif

-- Months and "today" are Lagos dates.
SET TIME ZONE 'Africa/Lagos';

-- ---------------------------------------------------------------------
-- Helpers. p2_queries holds each query's text once, so the result and
-- the timed plans always come from exactly the same SQL. p2_timings
-- keeps every run's times and plan.
-- ---------------------------------------------------------------------
-- The drop only matters when the script is run twice in one session
-- (e.g. in pgAdmin). On a fresh session the temporary schema does not
-- exist yet and PostgreSQL says so in a notice; hide that notice.
SET client_min_messages = warning;
DROP TABLE IF EXISTS pg_temp.p2_queries, pg_temp.p2_timings;
RESET client_min_messages;

CREATE TEMP TABLE p2_queries (
    label  text PRIMARY KEY,   -- Q1 ... Q8, with Q5a and Q5b
    qname  text NOT NULL,      -- also the plan file name
    title  text NOT NULL,
    sql    text NOT NULL
);

CREATE TEMP TABLE p2_timings (
    label         text,
    run           int,
    execution_ms  numeric,
    planning_ms   numeric,
    plan          text,
    PRIMARY KEY (label, run)
);

-- Runs one stored query p_runs times under EXPLAIN (ANALYZE, BUFFERS),
-- records each run, and returns the text for its plan file: the query,
-- the time of every run, the median, then the median run's full plan.
CREATE OR REPLACE FUNCTION pg_temp.explain_runs(p_label text, p_runs int DEFAULT 5)
RETURNS SETOF text
LANGUAGE plpgsql AS $$
DECLARE
    q          p2_queries%ROWTYPE;
    plan_line  text;
    plan_text  text;
    exec_ms    numeric;
    plan_ms    numeric;
    median     p2_timings%ROWTYPE;
BEGIN
    SELECT * INTO STRICT q FROM p2_queries WHERE label = p_label;
    DELETE FROM p2_timings WHERE label = p_label;

    FOR run IN 1 .. p_runs LOOP
        plan_text := '';
        FOR plan_line IN EXECUTE 'EXPLAIN (ANALYZE, BUFFERS) ' || q.sql LOOP
            plan_text := plan_text || plan_line || E'\n';
            IF plan_line LIKE 'Execution Time:%' THEN
                exec_ms := substring(plan_line FROM '([0-9.]+) ms')::numeric;
            ELSIF plan_line LIKE 'Planning Time:%' THEN
                plan_ms := substring(plan_line FROM '([0-9.]+) ms')::numeric;
            END IF;
        END LOOP;
        INSERT INTO p2_timings VALUES (p_label, run, exec_ms, plan_ms, plan_text);
    END LOOP;

    -- The median run is the middle one when the runs are sorted by time.
    SELECT * INTO median
    FROM p2_timings
    WHERE label = p_label
    ORDER BY execution_ms, run
    OFFSET (p_runs - 1) / 2
    LIMIT 1;

    RETURN NEXT format('%s. %s', q.label, q.title);
    RETURN NEXT '';
    RETURN NEXT 'Query:';
    RETURN QUERY SELECT '    ' || line
                 FROM regexp_split_to_table(trim(BOTH E'\n' FROM q.sql), E'\n') AS line;
    RETURN NEXT '';
    RETURN NEXT format('Execution time of %s runs (ms): %s', p_runs,
                       (SELECT string_agg(execution_ms::text, ', ' ORDER BY run)
                        FROM p2_timings WHERE label = p_label));
    RETURN NEXT format('Median: %s ms (run %s). The plan of that run follows.',
                       median.execution_ms, median.run);
    RETURN NEXT '';
    RETURN QUERY SELECT line
                 FROM regexp_split_to_table(rtrim(median.plan, E'\n'), E'\n') AS line;
END
$$;

-- ---------------------------------------------------------------------
-- Q1. Wallet statement for a date range ("generate a statement").
-- Every ledger row on one wallet in one month, oldest first, with its
-- direction. Wallet 6645 is customer Femi Udeh's main wallet: 189 rows
-- since November 2025, 29 of them in September 2026. Out of about
-- 1,040,000 ledger rows, the query needs 29.
-- ---------------------------------------------------------------------
INSERT INTO p2_queries VALUES ('Q1', 'q1_wallet_statement',
'Wallet statement: wallet 6645, September 2026', $q$
SELECT t.created_at, t.reference, t.transaction_type,
       CASE WHEN t.transaction_type IN ('funding', 'transfer_in', 'reversal')
            THEN 'credit' ELSE 'debit' END AS direction,
       t.amount, t.status, t.narration
FROM transactions t
WHERE t.wallet_id = 6645
  AND t.created_at >= '2026-09-01 00:00+01'
  AND t.created_at <  '2026-10-01 00:00+01'
ORDER BY t.created_at, t.transaction_id
$q$);

-- ---------------------------------------------------------------------
-- Q2. Monthly totals by type (finance report).
-- Money moved through Proclus in each month of the third quarter of
-- 2026, by transaction type. Only completed rows count. date_trunc cuts
-- each time down to the first instant of its month (Lagos time).
-- ---------------------------------------------------------------------
INSERT INTO p2_queries VALUES ('Q2', 'q2_monthly_totals',
'Monthly totals by transaction type: July to September 2026', $q$
SELECT date_trunc('month', created_at)::date AS month,
       transaction_type,
       count(*)    AS row_count,
       sum(amount) AS total_ngn
FROM transactions
WHERE status = 'completed'
  AND created_at >= '2026-07-01 00:00+01'
  AND created_at <  '2026-10-01 00:00+01'
GROUP BY 1, 2
ORDER BY 1, 2
$q$);

-- ---------------------------------------------------------------------
-- Q3. Top merchants (partnerships team).
-- The ten merchants that took the most money in the last 30 days: a
-- join, an aggregate and LIMIT. Grouping by merchant_id alone is
-- allowed because it is the primary key: business_name and category
-- depend on it functionally, and PostgreSQL recognises that.
-- ---------------------------------------------------------------------
INSERT INTO p2_queries VALUES ('Q3', 'q3_top_merchants',
'Top 10 merchants by money received: 9 September to 8 October 2026', $q$
SELECT m.merchant_id, m.business_name, m.category,
       count(*)      AS payments,
       sum(t.amount) AS total_ngn
FROM transactions t
JOIN merchants m ON m.merchant_id = t.merchant_id
WHERE t.transaction_type = 'merchant_payment'
  AND t.status = 'completed'
  AND t.created_at >= '2026-09-09 00:00+01'
  AND t.created_at <  '2026-10-09 00:00+01'
GROUP BY m.merchant_id
ORDER BY total_ngn DESC
LIMIT 10
$q$);

-- ---------------------------------------------------------------------
-- Q4. Inactive customers (re-engagement campaign).
-- Active customers with no ledger row on any of their wallets in the
-- last 90 days (since 11 July 2026), largest balances first, so the team
-- calls the customers with the most money sitting idle. NOT EXISTS is an
-- anti-join: keep a customer only if the subquery finds nothing.
-- ---------------------------------------------------------------------
INSERT INTO p2_queries VALUES ('Q4', 'q4_inactive_customers',
'Inactive customers: no activity in the 90 days to 8 October 2026, top 20 by balance', $q$
SELECT c.customer_id, c.first_name, c.last_name, c.email, c.kyc_tier,
       sum(w.balance) AS balance_held
FROM customers c
JOIN wallets w ON w.customer_id = c.customer_id
WHERE c.status = 'active'
  AND NOT EXISTS (
        SELECT 1
        FROM wallets w2
        JOIN transactions t ON t.wallet_id = w2.wallet_id
        WHERE w2.customer_id = c.customer_id
          AND t.created_at >= '2026-07-11 00:00+01')
GROUP BY c.customer_id
ORDER BY balance_held DESC, c.customer_id
LIMIT 20
$q$);

-- ---------------------------------------------------------------------
-- Q5. Running balance on a statement: the balance after every completed
-- row of wallet 6645 in September 2026. The balance after a row depends
-- on every earlier row, back to the wallet's first, not just the month.
--
-- Q5a is the straightforward first version: a correlated subquery that,
-- for each of the 29 rows, adds up every earlier completed row again.
-- Q5b is the rewrite: one pass over the wallet's rows with a window
-- function (sum ... OVER), then the outer query keeps September. Both
-- return the same rows; results/performance.md compares them.
-- ---------------------------------------------------------------------
INSERT INTO p2_queries VALUES ('Q5a', 'q5a_running_balance_correlated',
'Running balance, first version (correlated subquery): wallet 6645, September 2026', $q$
SELECT t.created_at, t.reference, t.transaction_type, t.amount,
       (SELECT sum(CASE WHEN e.transaction_type IN ('funding', 'transfer_in', 'reversal')
                        THEN e.amount ELSE -e.amount END)
        FROM transactions e
        WHERE e.wallet_id = t.wallet_id
          AND e.status = 'completed'
          AND (e.created_at, e.transaction_id) <= (t.created_at, t.transaction_id)
       ) AS balance_after
FROM transactions t
WHERE t.wallet_id = 6645
  AND t.status = 'completed'
  AND t.created_at >= '2026-09-01 00:00+01'
  AND t.created_at <  '2026-10-01 00:00+01'
ORDER BY t.created_at, t.transaction_id
$q$);

INSERT INTO p2_queries VALUES ('Q5b', 'q5b_running_balance_window',
'Running balance, rewritten (window function): wallet 6645, September 2026', $q$
SELECT created_at, reference, transaction_type, amount, balance_after
FROM (
    SELECT t.created_at, t.transaction_id, t.reference, t.transaction_type, t.amount,
           sum(CASE WHEN t.transaction_type IN ('funding', 'transfer_in', 'reversal')
                    THEN t.amount ELSE -t.amount END)
               OVER (ORDER BY t.created_at, t.transaction_id
                     ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS balance_after
    FROM transactions t
    WHERE t.wallet_id = 6645
      AND t.status = 'completed'
) s
WHERE created_at >= '2026-09-01 00:00+01'
  AND created_at <  '2026-10-01 00:00+01'
ORDER BY created_at, transaction_id
$q$);

-- ---------------------------------------------------------------------
-- Q6. Large-transfer check (compliance), written with CTEs.
-- Step 1 picks transfers of NGN 200,000 or more in the last 30 days that
-- went through or are still held; step 2 totals them per sending wallet;
-- the final step names the customer and flags those below KYC tier 3,
-- whose limits should not allow transfers this size.
-- ---------------------------------------------------------------------
INSERT INTO p2_queries VALUES ('Q6', 'q6_large_transfer_check',
'Large-transfer check (CTE): senders of NGN 200,000+ in the 30 days to 8 October 2026, top 20', $q$
WITH large_transfers AS (
    SELECT sender_wallet_id, amount, status
    FROM transfers
    WHERE amount >= 200000
      AND status IN ('completed', 'pending')
      AND created_at >= '2026-09-09 00:00+01'
      AND created_at <  '2026-10-09 00:00+01'
),
by_sender AS (
    SELECT sender_wallet_id,
           count(*)                                   AS large_count,
           sum(amount)                                AS large_total_ngn,
           count(*) FILTER (WHERE status = 'pending') AS still_held
    FROM large_transfers
    GROUP BY sender_wallet_id
)
SELECT c.customer_id, c.first_name, c.last_name, c.kyc_tier, w.wallet_number,
       b.large_count, b.large_total_ngn, b.still_held,
       CASE WHEN c.kyc_tier < 3 THEN 'check: KYC tier ' || c.kyc_tier ELSE 'ok' END AS flag
FROM by_sender b
JOIN wallets w   ON w.wallet_id = b.sender_wallet_id
JOIN customers c ON c.customer_id = w.customer_id
ORDER BY b.large_total_ngn DESC, c.customer_id
LIMIT 20
$q$);

-- ---------------------------------------------------------------------
-- Q7. Held-transfer review queue (compliance).
-- The 25 transfers that have waited longest for review, oldest first,
-- with the sender and how many hours each has waited. About 135 of the
-- 199,051 transfers are pending.
-- ---------------------------------------------------------------------
INSERT INTO p2_queries VALUES ('Q7', 'q7_held_transfer_queue',
'Held-transfer review queue: the 25 oldest pending transfers', $q$
SELECT t.transfer_id, t.reference, t.created_at, t.amount,
       c.first_name || ' ' || c.last_name AS sender, c.kyc_tier,
       round(extract(epoch FROM TIMESTAMPTZ '2026-10-09 00:00+01' - t.created_at) / 3600, 1)
           AS hours_waiting
FROM transfers t
JOIN wallets w   ON w.wallet_id = t.sender_wallet_id
JOIN customers c ON c.customer_id = w.customer_id
WHERE t.status = 'pending'
ORDER BY t.created_at
LIMIT 25
$q$);

-- ---------------------------------------------------------------------
-- Q8. Customer look-up by email, ignoring case (customer support).
-- The customer signed up as Zainab.Mohammed10549@example.com but types
-- it in lower case when calling support. A plain email = '...' would not
-- find her, so the look-up compares lower(email).
-- ---------------------------------------------------------------------
INSERT INTO p2_queries VALUES ('Q8', 'q8_email_lookup',
'Customer look-up by email, ignoring case', $q$
SELECT customer_id, first_name, last_name, email, phone_number, kyc_tier, status
FROM customers
WHERE lower(email) = lower('zainab.mohammed10549@example.com')
$q$);

-- =====================================================================
-- Run every query: print its result here, then write its plan file.
-- \gexec runs the stored SQL as a query. For the plan file, \t and \a
-- switch to bare text (no headers or borders) and \o sends the output
-- to the file.
-- =====================================================================

\echo
\echo '=== Q1. Wallet statement ==='
SELECT sql FROM p2_queries WHERE label = 'Q1' \gexec
\t on
\a
\o :plan_dir/q1_wallet_statement.txt
SELECT pg_temp.explain_runs('Q1');
\o
\a
\t off

\echo '=== Q2. Monthly totals by type ==='
SELECT sql FROM p2_queries WHERE label = 'Q2' \gexec
\t on
\a
\o :plan_dir/q2_monthly_totals.txt
SELECT pg_temp.explain_runs('Q2');
\o
\a
\t off

\echo '=== Q3. Top merchants ==='
SELECT sql FROM p2_queries WHERE label = 'Q3' \gexec
\t on
\a
\o :plan_dir/q3_top_merchants.txt
SELECT pg_temp.explain_runs('Q3');
\o
\a
\t off

\echo '=== Q4. Inactive customers ==='
SELECT sql FROM p2_queries WHERE label = 'Q4' \gexec
\t on
\a
\o :plan_dir/q4_inactive_customers.txt
SELECT pg_temp.explain_runs('Q4');
\o
\a
\t off

\echo '=== Q5a. Running balance, correlated subquery ==='
SELECT sql FROM p2_queries WHERE label = 'Q5a' \gexec
\t on
\a
\o :plan_dir/q5a_running_balance_correlated.txt
SELECT pg_temp.explain_runs('Q5a');
\o
\a
\t off

\echo '=== Q5b. Running balance, window function ==='
SELECT sql FROM p2_queries WHERE label = 'Q5b' \gexec
\t on
\a
\o :plan_dir/q5b_running_balance_window.txt
SELECT pg_temp.explain_runs('Q5b');
\o
\a
\t off

\echo '=== Q6. Large-transfer check ==='
SELECT sql FROM p2_queries WHERE label = 'Q6' \gexec
\t on
\a
\o :plan_dir/q6_large_transfer_check.txt
SELECT pg_temp.explain_runs('Q6');
\o
\a
\t off

\echo '=== Q7. Held-transfer review queue ==='
SELECT sql FROM p2_queries WHERE label = 'Q7' \gexec
\t on
\a
\o :plan_dir/q7_held_transfer_queue.txt
SELECT pg_temp.explain_runs('Q7');
\o
\a
\t off

\echo '=== Q8. Customer look-up by email ==='
SELECT sql FROM p2_queries WHERE label = 'Q8' \gexec
\t on
\a
\o :plan_dir/q8_email_lookup.txt
SELECT pg_temp.explain_runs('Q8');
\o
\a
\t off

-- ---------------------------------------------------------------------
-- Check that the rewrite returns exactly what the first version did:
-- the same 29 rows with the same running balances.
-- ---------------------------------------------------------------------
\echo '=== Q5a and Q5b return the same rows ==='
SELECT format('SELECT (SELECT count(*) FROM (%1$s) a) AS q5a_rows,
                      (SELECT count(*) FROM (%2$s) b) AS q5b_rows,
                      (SELECT count(*) FROM (((%1$s) EXCEPT ALL (%2$s))
                                              UNION ALL
                                              ((%2$s) EXCEPT ALL (%1$s))) d) AS rows_that_differ',
              (SELECT sql FROM p2_queries WHERE label = 'Q5a'),
              (SELECT sql FROM p2_queries WHERE label = 'Q5b')) \gexec

-- ---------------------------------------------------------------------
-- Summary: median and range of the five runs of every query, printed
-- here and saved next to the plans as timings.txt.
-- ---------------------------------------------------------------------
\echo '=== Execution time of each query, 5 runs (ms) ==='
SELECT q.label, q.qname,
       (SELECT execution_ms FROM p2_timings t WHERE t.label = q.label
        ORDER BY execution_ms, run OFFSET 2 LIMIT 1)                    AS median_ms,
       min(t.execution_ms)                                              AS fastest_ms,
       max(t.execution_ms)                                              AS slowest_ms,
       string_agg(t.execution_ms::text, ', ' ORDER BY t.run)            AS all_runs_ms
FROM p2_queries q
JOIN p2_timings t USING (label)
GROUP BY q.label, q.qname
ORDER BY q.label;
-- \g with an empty query buffer runs the last query again, this time
-- into the file.
\g :plan_dir/timings.txt
