# Performance results

This document compares the eight Portfolio 2 queries before and after the tuning in [`03_indexes.sql`](../sql/03_indexes.sql): four indexes plus one set of extended statistics for Q2. For each query it gives the median time, the plan node that changed, and why. It then shows what the indexes cost in disk space and write speed, and ends with the limits of these measurements.

Every number here comes from the files in this folder: the plans in [`plans/before/`](../plans/before/) and [`plans/after/`](../plans/after/), and the logs in [`logs/`](../logs/).

## 1. How the measurements were taken

| Item | Value |
| --- | --- |
| Server | PostgreSQL 18.6 on a Windows 11 laptop, default settings: `shared_buffers` 160 MB, `work_mem` 4 MB, up to 2 parallel workers per query |
| Data | Output of [`01_seed_large.sql`](../sql/01_seed_large.sql): 50,020 customers, 58,583 wallets, 500 merchants, 199,051 transfers, 1,040,093 ledger rows (1 Oct 2025 to 8 Oct 2026). Fixed random seed, so every run builds the same data |
| Ledger size | `transactions` table 134 MB |
| Timing | `Execution Time` from `EXPLAIN (ANALYZE, BUFFERS)`: time the server spent running the query, not counting the time to send rows to the client |
| Repeats | Each query ran 5 times in a row; the median is reported and the plan file holds the median run's plan |
| Before | Straight after the seed: only the primary keys, unique keys and Portfolio 1 indexes |
| After | After `03_indexes.sql`: the four indexes, `VACUUM (ANALYZE)`, and the extended statistics for Q2 |

**Same answers before and after.** The two output logs ([before](../logs/02_queries_before_output.txt), [after](../logs/02_queries_after_output.txt)) differ only in the timing table: every query returned the same rows. Tuning changes how PostgreSQL finds the rows, never which rows are correct.

## 2. Summary

| Query | Operation | Before (ms) | After (ms) | Change | Plan change | What made the difference |
| --- | --- | ---: | ---: | ---: | --- | --- |
| Q1 | Wallet statement, one wallet, one month | 164.247 | 0.077 | about 2,100x faster | Parallel Seq Scan to Index Scan | composite index `(wallet_id, created_at)` |
| Q2 | Monthly totals by type, Jul-Sep | 1,669.330 | 433.441 | 3.9x faster | Sort on disk + GroupAggregate to in-memory Partial HashAggregate | extended statistics on `(month, transaction_type)` |
| Q3 | Top 10 merchants, last 30 days | 168.005 | 126.194 | 1.3x faster | Parallel Seq Scan to Parallel Index Only Scan | covering index `(created_at) INCLUDE (...)` |
| Q4 | Inactive customers (`NOT EXISTS`) | 420.705 | 486.808 | none (16% slower, see Q4) | no change | nothing |
| Q5a | Running balance, correlated subquery | 8,248.650 | 6.872 | about 1,200x faster | Seq Scan inside the subplan (29 times) to Index Scan | composite index `(wallet_id, created_at)` |
| Q5b | Running balance, window function | 166.973 | 0.723 | about 230x faster | Parallel Seq Scan to Index Scan | composite index `(wallet_id, created_at)` |
| Q6 | Large-transfer check (CTE) | 105.672 | 98.484 | none (7%, run-to-run noise) | no change | nothing |
| Q7 | Held-transfer review queue | 67.599 | 0.338 | about 200x faster | Parallel Seq Scan + Sort to Index Scan, no Sort | partial index `(created_at) WHERE status = 'pending'` |
| Q8 | Customer look-up by email, any case | 51.952 | 0.035 | about 1,500x faster | Seq Scan to Index Scan | expression index `(lower(email))`, unique |

Pages touched (shared buffers hit + read) tell the same story without depending on the laptop's speed:

| Query | Pages before | Pages after |
| --- | ---: | ---: |
| Q1 | 17,135 | 32 |
| Q2 | 17,135 (+ 2,122 temporary pages written to and read back from disk) | 17,167 (no temporary pages) |
| Q3 | 17,175 | 1,783 |
| Q4 | 21,724 | 21,724 |
| Q5a | 514,142 | 4,991 |
| Q5b | 17,227 | 192 |
| Q6 | 8,065 | 8,065 |
| Q7 | 3,323 | 165 |
| Q8 | 757 | 4 |

## 3. Query by query

### Q1. Wallet statement (composite B-tree)

**Before:** a Parallel Seq Scan read the whole ledger, 17,135 pages, and threw away 1,040,064 rows to keep the 29 that belong to wallet 6645 in September.
**After:** an Index Scan on `transactions_wallet_id_created_at_idx` jumps straight to wallet 6645 and reads only its September entries, 32 pages.
**Why:** the query asks for one `wallet_id` (equality) and a range of `created_at`, which is exactly the order of the index columns. All of the wallet's entries sit side by side in the index, already in time order. The plan shows an Incremental Sort with `Presorted Key: created_at`: the rows arrive sorted by time and only need a tie-break on `transaction_id`, which costs almost nothing for 29 rows. This is the operation customers run most often, so it is the index that matters most.

### Q2. Monthly totals (covering index, then extended statistics)

Q2 needed two steps. [`logs/03_indexes_output.txt`](../logs/03_indexes_output.txt) times it after each one, five runs each:

| State | Median (ms) | Plan |
| --- | ---: | --- |
| Before (no new indexes) | 1,669.330 | Seq Scan, Sort on disk (external merge, 16,976 kB), GroupAggregate |
| Covering index only | 825.088 | Index Only Scan, the same Sort on disk, GroupAggregate |
| Covering index + extended statistics | 450.490 | Parallel Seq Scan, Partial HashAggregate in memory, no disk |
| Final "after" run of `02_queries.sql` | 433.441 | as above |

**Step 1, the covering index.** The Seq Scan became an Index Only Scan on `transactions_created_at_covering_idx` with `Heap Fetches: 0`. Every column Q2 reads (`created_at`, `transaction_type`, `status`, `amount`) is stored in the index, so the table is never visited, and pages read fell from 17,135 to 4,447. The time roughly halved. But the slowest part stayed: a sort of 508,955 rows that did not fit in memory and spilled to disk.

**Why it spilled.** The planner estimated **452,532 groups** for month x transaction type; the real number is **15**. PostgreSQL keeps statistics on columns, not on `date_trunc('month', created_at)`, so it could not know how few months there are. Expecting that many groups, it judged an in-memory hash table too big for `work_mem` (4 MB) and sorted everything on disk instead. The index made reading faster but did nothing for this wrong **cardinality estimate**.

**Step 2, extended statistics.** `CREATE STATISTICS transactions_month_type_stats (ndistinct) ON ((date_trunc('month', created_at))::date), transaction_type FROM transactions`, then `ANALYZE`. This asks ANALYZE to count the distinct values of exactly the expression Q2 groups by. It counted **59** distinct (month, type) pairs across the whole ledger: 13 months times the transaction types. The estimate for Q2's three months became `rows=59` against 15 actual, close enough for the planner to choose a hash aggregate. Each parallel worker now sums its share of the rows in a 32 kB hash table, and only 45 partial rows are combined at the end. No sort on disk, no temporary pages.

**A surprise: Q2 no longer uses the covering index.** With the hash aggregate, the planner found a Parallel Seq Scan of the whole table (three processes sharing the work) cheaper than a single-process Index Only Scan of the three months. Pages touched went back up to 17,167, but the work is split three ways and the disk sort is gone, so the query is still 3.9x faster than before. The lesson is that Q2's real problem was a bad estimate, not slow reading. Statistics fixed it at no storage cost, and the index turned out to be the wrong tool for this query.

### Q3. Top merchants (covering index)

**Before:** Parallel Seq Scan of the ledger, 17,175 pages, 962,193 rows filtered out.
**After:** a Parallel Index Only Scan on the covering index, reading only the 30-day slice of the index: 1,783 pages, no table visits (`Heap Fetches: 0`).
**Why only 1.3x:** the index key is `created_at`, so it narrows the search to the date range, but within those 30 days it still reads every type of row and filters out 117,408 that are not completed merchant payments. The rest of the plan (hash join to 500 merchants, aggregate, top-10 sort) is unchanged. The scan itself now takes about 30 ms per process, but the Gather Merge node only receives its first row at 117 ms. The likely reason is the cost of starting the two parallel worker processes, which is high on Windows. I did not measure this separately. Q3 timed 101 ms on an earlier run of the same plan (commit a978694), so its speed-up is somewhere between 1.3x and 1.7x.

### Q4. Inactive customers: no index helps

**Plan:** identical before and after: a Parallel Seq Scan of the ledger, hashed against wallets, then a Parallel Hash Right Anti Join to customers (the `NOT EXISTS`). Total pages touched are identical too (21,724).
**Why no index helps:** the `NOT EXISTS` needs every ledger row since 11 July. That is 518,736 of 1,040,093 rows, **about half the table**. With **selectivity** that low, an index would mean half a million separate look-ups jumping around the table, which costs more than reading the table once from start to finish. The planner had the composite `(wallet_id, created_at)` index available and chose not to use it.
**Why it got slower:** the pages read are the same, but where they came from differs. Before, 3,198 of the 21,724 pages came from outside PostgreSQL's buffer cache; after, 14,004 did. The new indexes (102 MB on the ledger alone) compete with the ledger (134 MB) for a 160 MB cache, so most likely more ledger pages had been pushed out by the time Q4 ran. This is a side effect of the indexes, not a change in Q4's plan, and it is a small, real cost of adding them.
**What would help instead (not tested):** store a `last_activity_at` on each wallet, updated by the transfer code, so the question becomes a filter on 58,583 wallets rather than a search of a million ledger rows. That is a schema change, so it is left out of Portfolio 2.

### Q5a and Q5b. Running balance: the rewrite

Q5a is the first, slow way to write the query: for each of the 29 statement rows, a **correlated subquery** adds up every earlier row of the same wallet. Q5b is the rewrite: one pass over the wallet's rows with `sum(...) OVER (ORDER BY created_at, transaction_id)`, a **window function**. A check in the log confirms they return the same 29 rows with the same balances (`rows_that_differ = 0`).

| | Q5a correlated | Q5b window | Rewrite speed-up |
| --- | ---: | ---: | ---: |
| Before indexes | 8,248.650 ms | 166.973 ms | 49x |
| After indexes | 6.872 ms | 0.723 ms | 9.5x |

**Q5a before:** the plan's `SubPlan 1` ran `loops=29`, and each loop was a full Seq Scan of the ledger (1,039,925 rows filtered out each time). That is about **30 million rows examined** and 514,142 pages touched to print 29 lines.
**Q5a after:** the composite index makes each subplan loop an Index Scan on one wallet (`Index Cond: wallet_id = t.wallet_id AND created_at <= t.created_at`), about 0.23 ms per loop. The index rescues the bad query, but it still reads the wallet's history 29 times over (4,991 pages).
**Q5b:** reads the wallet's 189 completed rows once (192 pages after indexing), keeps a running total, then filters to September. It has to read the rows before September too, because the balance on 1 September depends on them. That is why its `Index Cond` is only `wallet_id = 6645`.
**Lesson:** rewriting the query and indexing are separate fixes and both pay off. The rewrite alone gave 49x with no new index; the index alone gave about 1,200x; together, 8,249 ms became 0.72 ms. On a busier wallet the gap grows: the correlated version re-reads the wallet's history once for every statement row, while the window version reads it once.

### Q6. Large-transfer check (CTE): no index aimed at it

**Plan:** identical before and after (Parallel Seq Scan on `transfers`, group by sender, hash join to wallets, nested loop to customers), with the same 8,065 pages. The 7% difference (105.7 to 98.5 ms) is run-to-run noise, not an improvement.
**Why:** the CTE filters `transfers` on `amount >= 200000` and a 30-day `created_at` range. None of the four indexes is on `transfers(amount)` or `transfers(created_at)`, and the only new `transfers` index (Q7's) covers pending rows only. Q6 is included because the guide asks for one CTE query. Since PostgreSQL 12 a simple CTE like this one is folded into the main query rather than run separately, and the plan confirms it: no CTE Scan node, just a Subquery Scan over the aggregate.
**What would help (not tested):** an index on `transfers (created_at)` would narrow the scan to the last 30 days, roughly a twelfth of the year's transfers. The scan itself averages only 29 ms per process here, so the gain would be modest; as with Q3, much of the time goes before the first row reaches Gather Merge (73 ms).

### Q7. Held-transfer queue (partial index)

**Before:** a Parallel Seq Scan of all 199,051 transfers to find the 135 pending ones, then a Sort by `created_at`, then the top 25. 3,323 pages.
**After:** an Index Scan on `transfers_pending_created_at_idx`. The plan has **no Index Cond and no Sort node**: the index holds only pending transfers (its `WHERE status = 'pending'` matches the query's), already in `created_at` order, so PostgreSQL reads the first 25 entries and stops. 15 pages for the index scan, 165 in total with the wallet and customer look-ups.
**Why it is cheap:** the index is 16 kB because it indexes only 135 rows. Inserts of completed or failed transfers never touch it.

### Q8. Email look-up ignoring case (expression index)

**Before:** a Seq Scan of all 50,020 customers, computing `lower(email)` for each one, 757 pages. The existing `customers_email_key` index could not help: it stores `email`, and `lower(email)` is a different value.
**After:** an Index Scan on `customers_lower_email_key`, 4 pages.
**The estimate improved too:** before, the planner guessed `rows=250` (its default 0.5% guess for an expression it has no statistics on); after `ANALYZE`, which collects statistics on indexed expressions, and with the index being UNIQUE, it expects `rows=1`, which is right.
**A second benefit:** because the index is UNIQUE, it also enforces that `Ada@example.com` and `ada@example.com` cannot belong to two customers, the gap noted in Portfolio 1.

## 4. What the tuning costs

### Disk space

From [`logs/03_indexes_output.txt`](../logs/03_indexes_output.txt):

| Index | Table | Index size | Table size | Index as % of table | Build time |
| --- | --- | ---: | ---: | ---: | ---: |
| `transactions_created_at_covering_idx` | transactions | 71 MB | 134 MB | 52.9% | 2,641 ms |
| `transactions_wallet_id_created_at_idx` | transactions | 31 MB | 134 MB | 23.4% | 1,573 ms |
| `customers_lower_email_key` | customers | 2,528 kB | 6,056 kB | 41.7% | 471 ms |
| `transfers_pending_created_at_idx` | transfers | 16 kB | 24 MB | 0.1% | 214 ms |

The ledger's indexes went from 101 MB (primary key and two unique keys) to 203 MB. **The ledger now has more index than table.** The covering index is the largest because `INCLUDE` copies four columns into every entry; that is what makes the index-only scans possible, and it is also what makes it big.

The extended statistics take no space in the table or its indexes: they are a small entry in the system catalogue, refreshed by every `ANALYZE`.

### Slower inserts

Every index on a table is updated on every insert. The test in `03_indexes.sql` inserted 100,000 ledger rows into a scratch copy of the ledger (same 1,040,093 rows, same existing keys), five times without and five times with the two new ledger indexes, each insert rolled back and followed by `VACUUM` and `CHECKPOINT`:

| Indexes on the copy | Runs (ms) | Median (ms) |
| --- | --- | ---: |
| Existing keys only | 2,574.0, 3,074.3, 3,259.2, 2,601.3, 2,086.2 | 2,601.3 |
| Existing keys + the two new ledger indexes | 3,661.5, 3,327.7, 3,251.6, 3,440.7, 3,483.0 | 3,440.7 |

**Inserts became 32.3% slower**, from about 26 to 34 microseconds per row. An earlier run of the same test (commit a978694) gave 40.3% (3,666 to 5,145 ms), with tighter runs. So the honest summary is "about a third to two-fifths slower". The test added both indexes together, so it does not show how the slowdown splits between them. For Proclus every transfer writes two ledger rows, so this is paid on every money movement. The two smaller indexes are on tables that are written far less often (`customers`), or are only touched by pending transfers (the partial index). The extended statistics add nothing to inserts.

## 5. Was each change worth it?

| Change | Gain | Cost | Verdict |
| --- | --- | --- | --- |
| Composite `(wallet_id, created_at)` | Statement from 164 ms to 0.08 ms; running balance from 8,249 to 6.9 ms (Q5a) and 167 to 0.72 ms (Q5b) | 31 MB, part of the insert slowdown | **Keep.** Statements and balances are what customers open every day |
| Partial, pending transfers | Review queue from 68 ms to 0.34 ms | 16 kB, almost no write cost | **Keep.** Nearly free |
| Expression `lower(email)`, unique | Log-in look-up from 52 ms to 0.04 ms, plus case-insensitive uniqueness | 2.5 MB; customers are rarely written | **Keep.** It also fixes a data-quality gap |
| Extended statistics on (month, type) | Q2 from 825 ms (with the index) to about 440 ms, no disk sort | None on storage or inserts; a little extra `ANALYZE` work | **Keep.** The cheapest fix in the portfolio |
| Covering `(created_at) INCLUDE (...)` | Q3 1.3x to 1.7x; Q2 no longer uses it | 71 MB, the largest; part of the insert slowdown; more pressure on the cache (see Q4) | **Drop it on the primary.** Its one remaining user is a back-office report run a few times a day, while every transfer pays for it. On a real system I would run reports on a read replica (Portfolio 5) and keep the primary for transfers |

## 6. Limits of these measurements

- **One laptop.** The numbers are for this machine with other programs running. The ratios and page counts matter more than the exact milliseconds. Two runs of `03_indexes.sql` on different days gave insert slowdowns of 40.3% and 32.3%, and Q3 timed 101 ms and 126 ms on the same plan.
- **Cache state.** The first of the five runs often reads pages from disk and the later ones find them in memory (Q3 before: 574 ms on run 1, 152 to 186 ms on the other four). The median smooths this but does not remove it, and Q4 shows the cache can shift between the before and after runs.
- **`EXPLAIN ANALYZE` adds its own overhead** of timing each plan node, and leaves out the time to send rows to the client. Both affect before and after equally.
- **Fixed data.** One seed, and one wallet (6645, 189 completed rows) for Q1 and Q5. A busier wallet (the largest has 838 rows) would widen the gap between Q5a and Q5b.
- **No concurrent load.** Nothing else wrote to the database during the runs, so the cost of the indexes under real transfer traffic, or of `CREATE INDEX` blocking writes, was not measured. On a live system these would be built with `CREATE INDEX CONCURRENTLY`.

## 7. Next steps not taken

- **Q4:** a `last_activity_at` column on wallets (a schema change).
- **Q6:** an index on `transfers (created_at)` if the large-transfer check became frequent.
- **Covering index:** drop it and re-measure Q3, to confirm what the primary saves on inserts without it.
