# Portfolio 2: Query processing and optimisation

## Objective

This portfolio grows the Proclus database from Portfolio 1 to about a million ledger rows. It then measures eight queries behind real wallet operations before and after tuning. It shows the execution plans, the indexes and statistics that changed them, the cost of those indexes in disk space and insert speed, and one slow query rewritten.

## Environment

- PostgreSQL 18.6, local Windows install, `localhost:5432`, database `proclus`, user `postgres`. Install and connection steps are in [SETUP.md](../SETUP.md).
- Default server settings: `shared_buffers` 160 MB, `work_mem` 4 MB, up to 2 parallel workers per query.
- `psql` runs the scripts and writes the plan files. The session time zone is `Africa/Lagos`, so months and dates are Lagos dates.
- The tables are the eight from Portfolio 1, with the same names and constraints.

## How to run

1. Start PostgreSQL and load `PGPASSWORD` from `.env` as described in SETUP.md.
2. From the repo root, run the scripts in this order:

   ```
   psql -w -U postgres -h localhost -p 5432 -d proclus -v ON_ERROR_STOP=1 -f portfolio-2-query-optimisation/sql/01_seed_large.sql
   psql -w -U postgres -h localhost -p 5432 -d proclus -v ON_ERROR_STOP=1 -v plan_dir=portfolio-2-query-optimisation/plans/before -f portfolio-2-query-optimisation/sql/02_queries.sql
   psql -w -U postgres -h localhost -p 5432 -d proclus -v ON_ERROR_STOP=1 -f portfolio-2-query-optimisation/sql/03_indexes.sql
   psql -w -U postgres -h localhost -p 5432 -d proclus -v ON_ERROR_STOP=1 -v plan_dir=portfolio-2-query-optimisation/plans/after -f portfolio-2-query-optimisation/sql/02_queries.sql
   ```

`02_queries.sql` runs twice. The `plan_dir` variable tells it where to save the plans, and the script stops with an error if it is missing.

Every script can be run again at any time:

- `01` runs the Portfolio 1 schema and sample-data scripts first, so it always starts from the same empty schema with no Portfolio 2 indexes. `setseed(0.8103)` makes it build the same rows every time. It takes two to three minutes.
- `02` changes no data. Its helper tables live in the session's temporary schema.
- `03` drops and rebuilds its four indexes and its statistics object. The insert test works on a scratch copy of the ledger, which is dropped at the end. It takes about three minutes.

## What I did

1. Grew the database with `generate_series` in [sql/01_seed_large.sql](sql/01_seed_large.sql). Before it commits, it runs three audits: every wallet balance equals its ledger total, every transfer matches its ledger rows, and no wallet's running balance ever drops below zero. It then runs `VACUUM (ANALYZE)`. The 25 Portfolio 1 sample wallets are never touched, so the Portfolio 1 evidence stays true.
2. Wrote eight queries for real Proclus operations, plus a first, slow version of Q5, in [sql/02_queries.sql](sql/02_queries.sql). Each query prints its result, then runs `EXPLAIN (ANALYZE, BUFFERS)` five times. The median run's plan is saved to a text file, and a timing table lists all five runs. The queries use fixed dates, because the data ends on 8 October 2026.
3. Saved the plans before tuning in [plans/before/](plans/before/).
4. Added four indexes in [sql/03_indexes.sql](sql/03_indexes.sql), with `VACUUM (ANALYZE)` afterwards. It also adds extended statistics for Q2 and times Q2 with and without them. Finally it measures each index's size with `pg_relation_size` and times 100,000-row inserts into a copy of the ledger with and without the new indexes.
5. Re-ran the queries into [plans/after/](plans/after/).
6. Rewrote the slow running-balance query, Q5a (a correlated subquery), as Q5b (a window function). The script checks that both return the same 29 rows.
7. Wrote up the timings, plan changes, costs and limits in [results/performance.md](results/performance.md).
8. Saved the terminal output of every run in [logs/](logs/).

| Query | Operation | SQL feature |
| --- | --- | --- |
| Q1 | Statement for wallet 6645, September 2026 | date-range filter, `ORDER BY` |
| Q2 | Monthly totals by transaction type, July to September | `date_trunc`, `GROUP BY` |
| Q3 | Top 10 merchants by money received, 9 September to 8 October 2026 | join, aggregate, `LIMIT` |
| Q4 | Active customers with no activity in the 90 days to 8 October 2026, top 20 by balance | `NOT EXISTS` |
| Q5a | Running balance on the Q1 statement | correlated subquery (the slow version) |
| Q5b | The same running balance | window function `sum(...) OVER (...)` |
| Q6 | Top 20 senders of large transfers (NGN 200,000 or more) in the 30 days to 8 October 2026, flagged by KYC tier | CTE |
| Q7 | The 25 oldest pending transfers awaiting review | filter on status, `LIMIT` |
| Q8 | Customer log-in look-up by email, any case | `lower(email)` |

| Table | Rows after the seed |
| --- | ---: |
| customers | 50,020 |
| wallets | 58,583 |
| merchants | 500 |
| transfers | 199,051 |
| transactions (ledger) | 1,040,093 |

The ledger covers 1 October 2025 to 8 October 2026 and takes 134 MB on disk. KYC documents, beneficiaries and the audit log keep their Portfolio 1 sample rows, because no query reads them.

## Evidence

| Evidence | File | What it shows |
| --- | --- | --- |
| Seed log | [logs/01_seed_large_output.txt](logs/01_seed_large_output.txt) | The row count of every table, ledger totals by type and status, the date range, the busiest day (6,941 rows) and the table sizes. All three audits pass before the data is committed: 58,583 balances, 391,880 transfer ledger rows, and no wallet ever below zero. |
| Query results, before | [logs/02_queries_before_output.txt](logs/02_queries_before_output.txt) | The result of each query (Q1 to Q8, with Q5a and Q5b), the check that Q5a and Q5b agree, and all five timings of each query. |
| Query results, after | [logs/02_queries_after_output.txt](logs/02_queries_after_output.txt) | The same results as before, row for row. Only the timing table differs. |
| Plans before tuning | [plans/before/](plans/before/) | One `EXPLAIN (ANALYZE, BUFFERS)` file per query, plus `timings.txt`. Most plans read the whole ledger with a sequential scan. |
| Plans after tuning | [plans/after/](plans/after/) | The same nine files after the indexes and statistics. Each shows which scan or aggregate the planner now chose. |
| Index log | [logs/03_indexes_output.txt](logs/03_indexes_output.txt) | The four index builds and their sizes. Q2 is timed with and without the extended statistics. The 100,000-row insert test is run five times each way, and the real ledger is unchanged at the end. |
| Performance write-up | [results/performance.md](results/performance.md) | The before and after median for every query, the plan node that changed and why, pages touched, index costs, a keep-or-drop verdict for each change, and the limits of the measurements. |

## Analysis

Medians of five runs, in milliseconds. The full table, with pages touched, is in [results/performance.md](results/performance.md).

| Query | Before | After | Plan change |
| --- | ---: | ---: | --- |
| Q1 | 164.247 | 0.077 | Parallel Seq Scan to Index Scan on `(wallet_id, created_at)` |
| Q2 | 1,669.330 | 433.441 | Sort on disk + GroupAggregate to in-memory Partial HashAggregate |
| Q3 | 168.005 | 126.194 | Parallel Seq Scan to Parallel Index Only Scan on the covering index |
| Q4 | 420.705 | 486.808 | none |
| Q5a | 8,248.650 | 6.872 | Seq Scan in each of 29 subplan loops to Index Scan |
| Q5b | 166.973 | 0.723 | Parallel Seq Scan to Index Scan on `(wallet_id, created_at)` |
| Q6 | 105.672 | 98.484 | none |
| Q7 | 67.599 | 0.338 | Parallel Seq Scan + Sort to Index Scan on the partial index, with no Sort |
| Q8 | 51.952 | 0.035 | Seq Scan to Index Scan on `lower(email)` |

**An index helps when the query matches the index's column order and picks out few rows.** Q1 asks for one wallet and a date range, which is exactly the order of the composite index `(wallet_id, created_at)`. Pages read fell from 17,135 to 32. Q7's partial index holds only the 135 pending transfers, already sorted by time, so PostgreSQL reads the first 25 entries and stops. The index is 16 kB.

**Q2's problem was a wrong cardinality estimate, not slow reading.** The planner expected 452,532 groups for month by type, because it keeps no statistics on `date_trunc('month', created_at)`. The real answer is 15. Expecting so many groups, it sorted half a million rows on disk. The covering index halved the time but left the disk sort in place. Extended statistics on the exact `GROUP BY` expression brought the estimate down to 59, and the planner switched to a small in-memory hash aggregate. After that, Q2 no longer used the covering index at all.

**Low selectivity defeats indexes.** Q4 needs every ledger row since 11 July, which is about half the table. Half a million index look-ups would cost more than one pass through the table, so the planner kept the sequential scan even with the composite index available. Q4 was 16% slower afterwards. The most likely cause is that the new indexes (102 MB on the ledger) now compete with the ledger itself for the 160 MB buffer cache. Q6 filters `transfers` on amount and date, and none of the four indexes covers those columns, so its plan did not change.

**Rewriting a query and indexing are separate fixes.** Before any index, the window-function rewrite (Q5b) was 49 times faster than the correlated subquery (Q5a). The subquery had scanned the whole ledger once for each of the 29 statement rows, about 30 million rows in all. The index then helped both versions, but Q5a still reads the wallet's history 29 times, so Q5b stays about 9.5 times faster.

**The indexes have a real cost.** The ledger's indexes doubled from 101 MB to 203 MB, so the ledger now has more index than table. The covering index alone is 71 MB, 53% of the table. Inserting 100,000 ledger rows took 32.3% longer with the two new ledger indexes, and an earlier run measured 40.3%. Every Proclus transfer writes two ledger rows, so it pays this cost on every money movement. My verdict is to keep the composite, partial and expression indexes and the extended statistics. The covering index should be dropped on the primary, because its only remaining user is a back-office report (Q3), and that report could run on a read replica (Portfolio 5).

## Challenges and decisions

- **The first seed run failed on a duplicate reference number.** Each wallet's activity had been spread over its own lifetime, so late joiners had a year's activity squeezed into a few days. The busiest day overflowed the 4-digit daily counter in the reference, and `to_char` printed `####`. I changed the model so every wallet is equally active per day while in use, and the busiest day now has 6,941 rows.
- **The first insert test changed the real ledger.** It inserted into the ledger and rolled back. The dead rows made later runs slower and grew the ledger's own indexes. The test now runs on a scratch copy of the ledger, with `VACUUM` and `CHECKPOINT` before each of five runs per side, so the real ledger keeps its seed sizes.
- **Extended statistics only work on the exact expression.** My first statistics object used `date_trunc('month', created_at, 'Africa/Lagos')`, which differs from the query's expression, and the estimate did not move. Defining it on Q2's own `(date_trunc('month', created_at))::date` fixed the estimate.
- **The timings vary between runs.** Two runs of `03_indexes.sql` on different days gave insert slowdowns of 40.3% and 32.3%, and Q3 timed 101 ms and 126 ms on the same plan. `performance.md` reports both figures instead of picking one. The page counts do not depend on the machine's speed, so they are given alongside the times.
- **Fixed dates instead of `now()`.** The data ends on 8 October 2026, so the queries treat 9 October 2026 00:00 Lagos time as "today". This keeps every run's results the same, whatever day it is run.
- **No index for Q4 or Q6.** Both are explained in `performance.md`, with the fix I would try for each (a `last_activity_at` column on wallets, and an index on `transfers (created_at)`). I did not build them: the first is a schema change, and the second targets a query that runs rarely.
- **The expression index is UNIQUE.** This closes the gap noted in Portfolio 1: `Ada@example.com` and `ada@example.com` can no longer belong to two customers.
- **Plain `CREATE INDEX`, not `CONCURRENTLY`.** Nothing else writes to this database, so a plain build is fine here. On a live wallet I would use `CREATE INDEX CONCURRENTLY`, so the build does not block transfers.
- **A `logs/` folder was added** to keep the captured terminal output as text, as the working rules ask. The guide's folder list for Portfolio 2 does not name one.

## References

- PostgreSQL Global Development Group. *PostgreSQL 18 Documentation*: chapter 11 "Indexes" (sections 11.3 multicolumn, 11.7 expression, 11.8 partial and 11.9 index-only scans and covering indexes), chapter 14 "Performance Tips" (sections 14.1 `EXPLAIN` and 14.2 statistics used by the planner, including extended statistics), `CREATE STATISTICS`, and section 3.5 "Window Functions". https://www.postgresql.org/docs/18/
- Elmasri, R. and Navathe, S. B. (2016). *Fundamentals of Database Systems* (7th ed.). Pearson. Chapters on query processing and optimisation.
- Silberschatz, A., Korth, H. F. and Sudarshan, S. (2020). *Database System Concepts* (7th ed.). McGraw-Hill. Chapters on indexing, query processing and query optimisation.
