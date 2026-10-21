# Portfolio 3: Transactions and concurrency

> In progress. Done: commit/rollback, savepoints, and the lost update with its three fixes. Still to come: the non-repeatable read, the deadlock, and the screenshots.

## Objective

This portfolio shows how PostgreSQL keeps Proclus wallet balances correct when a transfer fails part-way, and when two sessions change the same wallet at the same time. Each scenario has a script per session, the captured output, and an explanation of what happened and why.

## Environment

- PostgreSQL 18.6, local Windows install, `localhost:5432`, database `proclus`, user `postgres`. Install and connection steps are in [SETUP.md](../SETUP.md).
- Default isolation level READ COMMITTED, unless a script sets another.
- `psql` runs the scripts. The tables are the eight from Portfolio 1, with the same names and constraints.

## How to run

1. Start PostgreSQL and load `PGPASSWORD` from `.env` as described in SETUP.md.
2. From the repo root, run the scripts in this order:

   ```
   psql -X -w -U postgres -h localhost -p 5432 -d proclus -v ON_ERROR_STOP=1 -f portfolio-3-transactions-concurrency/sql/01_commit_rollback.sql
   psql -X -w -U postgres -h localhost -p 5432 -d proclus -v ON_ERROR_STOP=1 -f portfolio-3-transactions-concurrency/sql/02_savepoints.sql
   ```

Every script starts by running the Portfolio 1 schema and sample-data scripts, so the 25 sample wallets always start from the same balances and every run prints the same output. This removes the large Portfolio 2 data set; `portfolio-2-query-optimisation/sql/01_seed_large.sql` rebuilds it.

Some statements in these scripts fail on purpose. The scripts switch `ON_ERROR_STOP` off just before them and back on straight after, so an unexpected error anywhere else still stops the run.

3. Run the two-session scenarios from the repo root in Windows PowerShell, one at a time:

   ```
   .\portfolio-3-transactions-concurrency\run_two_sessions.ps1 03_lost_update
   .\portfolio-3-transactions-concurrency\run_two_sessions.ps1 04_fix_for_update
   .\portfolio-3-transactions-concurrency\run_two_sessions.ps1 05_fix_atomic_update
   .\portfolio-3-transactions-concurrency\run_two_sessions.ps1 06_fix_serializable
   ```

   Each scenario has two scripts, `sql/<scenario>_session_a.sql` and `sql/<scenario>_session_b.sql`. [run_two_sessions.ps1](run_two_sessions.ps1) starts them together as two separate `psql` processes, so they are two real database sessions. It writes their output to `logs/<scenario>_session_a_output.txt` and `logs/<scenario>_session_b_output.txt`, and reads `PGPASSWORD` from `.env` if it is not already set. Add `-Show` to open the two sessions in two console windows side by side instead; nothing is written to `logs/` then.

The two sessions are kept in step by the clock. The runner asks PostgreSQL for a start time six seconds ahead and passes it to both sessions. [sql/two_session_clock.sql](sql/two_session_clock.sql), which every session script includes, makes step *n* wait until the start time plus *n* seconds and print when it ran, for example `step 3: session_a at t+3.0 s`. When a session is held up by a lock, its next printed time shows how long it waited. Session A rebuilds the Portfolio 1 sample data before the start time, so each scenario begins from the same balances.

## What I did

1. Wrote a transfer as one transaction in [sql/01_commit_rollback.sql](sql/01_commit_rollback.sql). A transfer writes a `transfers` row, debits the sender, credits the receiver and adds two ledger rows. Part 1 sends NGN 25,000.00 from wallet 3 to wallet 6 and commits. Part 2 tries to send NGN 50,000.00 from wallet 2, which holds NGN 23,500.00. The credit to wallet 7 is applied first, on purpose, so there is something to undo. The debit then breaks the `wallets_balance_non_negative` CHECK, and `ROLLBACK` undoes everything.
2. Wrote a batch of three payments in one transaction in [sql/02_savepoints.sql](sql/02_savepoints.sql). Wallet 17 (NGN 225,000.00) pays NGN 100,000.00, then NGN 150,000.00, then NGN 50,000.00. The second payment fails for lack of funds. `ROLLBACK TO SAVEPOINT` undoes only that payment, the failure is recorded as a `failed` transfer with an audit-log entry, the third payment goes through, and one `COMMIT` keeps it all.
3. Ended both scripts with the balance audit from Portfolio 1: every stored balance must equal its ledger total.
4. Ran each script twice in a row. Both runs gave identical output. Saved the output in [logs/](logs/).
5. Set up one scenario for all the two-session scripts. Ibrahim Musa (wallet 5) holds NGN 300,000.00 and sends two transfers at almost the same moment, one from his phone and one from the web. Session A sends NGN 120,000.00 to Chiamaka Obi (wallet 10), and session B sends NGN 80,000.00 to Hauwa Ibrahim (wallet 14). He should be left with NGN 100,000.00. Wrote [run_two_sessions.ps1](run_two_sessions.ps1) and [sql/two_session_clock.sql](sql/two_session_clock.sql) to run each pair of sessions on a fixed timeline.
6. Showed the lost update in [sql/03_lost_update_session_a.sql](sql/03_lost_update_session_a.sql) and [sql/03_lost_update_session_b.sql](sql/03_lost_update_session_b.sql), under READ COMMITTED. Both sessions run the same application code: read the balance, work out the new balance, write that number back. A reads 300,000.00 at t+1 and B reads 300,000.00 at t+2. A writes 180,000.00 at t+3 and commits at t+4. B writes 300,000.00 − 80,000.00 = 220,000.00 at t+5 and commits.
7. Fix 1, a row lock on the read, in [sql/04_fix_for_update_session_a.sql](sql/04_fix_for_update_session_a.sql) and [sql/04_fix_for_update_session_b.sql](sql/04_fix_for_update_session_b.sql). The only change from `03` is `FOR UPDATE` on the `SELECT`. B's read at t+2 has to wait for A's lock. At t+3, while B waits, A queries `pg_stat_activity` with `pg_blocking_pids()` and `pg_locks` to show who is waiting and for whom.
8. Fix 2, one atomic `UPDATE`, in [sql/05_fix_atomic_update_session_a.sql](sql/05_fix_atomic_update_session_a.sql) and [sql/05_fix_atomic_update_session_b.sql](sql/05_fix_atomic_update_session_b.sql). The application no longer reads the balance first. It runs `UPDATE wallets SET balance = balance - x WHERE wallet_id = 5 AND balance >= x` and checks how many rows changed (psql's `:ROW_COUNT`). One row means the money has been taken; no rows means there was not enough, and the transfer is rolled back. B then tries a third transfer of NGN 150,000.00 to Folake Akinwale (wallet 20), which the remaining balance cannot cover.
9. Fix 3, SERIALIZABLE with a retry, in [sql/06_fix_serializable_session_a.sql](sql/06_fix_serializable_session_a.sql) and [sql/06_fix_serializable_session_b.sql](sql/06_fix_serializable_session_b.sql). The code is the same read-then-write as `03`, but each transaction starts with `BEGIN ISOLATION LEVEL SERIALIZABLE`. B's write fails with a serialization error. B rolls back, checks that the error code (psql's `LAST_ERROR_SQLSTATE`) is `40001`, and runs the whole transaction again once.
10. Ended every scenario with session A showing wallets 5, 10 and 14, the two transfers with their ledger rows, and the balance audit, this time also listing any wallet that fails it. Ran each pair twice; both runs gave identical output.

## Evidence

| Evidence | File | What it shows |
| --- | --- | --- |
| Commit and rollback log | [logs/01_commit_rollback_output.txt](logs/01_commit_rollback_output.txt) | Part 1: wallet 3 goes from 146,800.00 to 121,800.00 and wallet 6 from 0.00 to 25,000.00, with both ledger legs. Part 2: wallet 7 shows 115,000.00 inside the transaction. The debit fails with `violates check constraint "wallets_balance_non_negative"`, and the next read is refused (`current transaction is aborted`). After `ROLLBACK`, wallets 2 and 7 are back at 23,500.00 and 65,000.00, and there are still 13 transfers and 49 ledger rows. The audit finds 0 mismatches in 25 wallets. |
| Savepoint log | [logs/02_savepoints_output.txt](logs/02_savepoints_output.txt) | Payment 2 fails on the same CHECK. After `ROLLBACK TO SAVEPOINT before_payment_2` the same read works again and shows 125,000.00, so payment 1 survived. After `COMMIT`, wallet 17 holds 75,000.00, wallets 10 and 20 hold 100,000.00 and 50,000.00, and wallet 14 is unchanged. There are two completed transfers with two ledger rows each, and one failed transfer with none. The audit finds 0 mismatches. |
| Lost update logs | [logs/03_lost_update_session_a_output.txt](logs/03_lost_update_session_a_output.txt), [logs/03_lost_update_session_b_output.txt](logs/03_lost_update_session_b_output.txt) | Both sessions read 300000.00. A writes 180,000.00 and commits at t+4. B's echoed statement shows the stale value it writes back: `UPDATE wallets SET balance = 300000.00 - 80000.00`, giving 220,000.00. Afterwards wallet 5 holds 220,000.00 although both transfers are `completed` with two ledger rows each, and wallets 10 and 14 were credited 120,000.00 and 80,000.00. The audit finds 1 mismatch: wallet 5, stored 220,000.00, ledger 100,000.00, difference 120,000.00. |
| FOR UPDATE logs | [logs/04_fix_for_update_session_a_output.txt](logs/04_fix_for_update_session_a_output.txt), [logs/04_fix_for_update_session_b_output.txt](logs/04_fix_for_update_session_b_output.txt) | At t+3, `pg_stat_activity` shows `session_b` waiting (`Lock` / `transactionid`), blocked by `session_a`, on `SELECT balance FROM wallets WHERE wallet_id = 5 FOR UPDATE`. `pg_locks` shows B holding the row's `tuple` lock and waiting for a `ShareLock` on A's transaction id (`granted = f`). B's read returns at t+4.0, the moment A commits, with 180000.00, and B writes 100,000.00. The audit finds 0 mismatches. |
| Atomic UPDATE logs | [logs/05_fix_atomic_update_session_a_output.txt](logs/05_fix_atomic_update_session_a_output.txt), [logs/05_fix_atomic_update_session_b_output.txt](logs/05_fix_atomic_update_session_b_output.txt) | At t+3, `pg_stat_activity` shows B's `UPDATE ... balance - 80000.00 WHERE wallet_id = 5 AND balance >= 80000.00` waiting for `session_a`. It finishes at t+4.0 with `UPDATE 1` and 100,000.00. The third transfer of 150,000.00 gives `UPDATE 0`, prints the cancel message and rolls back. Wallet 5 ends at 100,000.00 and wallet 20 stays at 0.00. Only the two transfers exist, and the audit finds 0 mismatches. |
| SERIALIZABLE logs | [logs/06_fix_serializable_session_a_output.txt](logs/06_fix_serializable_session_a_output.txt), [logs/06_fix_serializable_session_b_output.txt](logs/06_fix_serializable_session_b_output.txt) | Both sessions show `serializable` and read 300000.00. A commits at t+4. At t+5, B's write fails with `ERROR:  could not serialize access due to concurrent update`. B rolls back, sees SQLSTATE `40001`, and starts attempt 2 at t+5.0. The new transaction reads 180000.00 and writes 100,000.00. The audit finds 0 mismatches. |

## Analysis

**A transaction is all or nothing (atomicity).** In Part 2 of `01`, wallet 7 had already been credited when the debit failed. Without a transaction, that credit would stay and NGN 50,000.00 would appear from nowhere. `ROLLBACK` removed the credit and the half-written transfer row together, and the balance audit still matches the ledger.

**After an error, PostgreSQL refuses the rest of the transaction.** Once a statement fails, every later statement in the same transaction is rejected until `ROLLBACK`, even a plain `SELECT`. This stops an application from carrying on as if the failed step had worked.

**A savepoint limits how much is undone.** In `02`, a plain `ROLLBACK` would have thrown away payment 1 as well. `ROLLBACK TO SAVEPOINT` undid only the work after the mark and cleared the error, so the batch could record the failure and go on. Other sessions saw nothing until the final `COMMIT`, and then saw all of it at once.

**Rolled-back work still uses up ids.** The rolled-back transfer in `01` took `transfer_id` 14, and the failed payment in `02` was given 15, not 14. Sequences never go backwards, even on rollback, because giving a number back would make concurrent sessions wait for each other. Gaps in ids are therefore normal. The transfer `reference` is the business key, and it was free to use again because the rolled-back row never existed.

**What the lost update lost.** Session A's debit of NGN 120,000.00 disappeared from wallet 5. Everything else was recorded: both transfers are `completed`, the ledger has all four rows, and wallets 10 and 14 received their money. Only the stored balance is wrong. Ibrahim paid out NGN 200,000.00 but was charged only NGN 80,000.00, so Proclus is NGN 120,000.00 short. This is the stored balance that Portfolio 1's normalisation kept on purpose, and the balance audit against the ledger is what caught the error.

**Why READ COMMITTED allowed it.** Under READ COMMITTED each statement sees the data committed before it started. B's `UPDATE` at t+5 did run against A's committed 180,000.00, but it did not use it. The new balance was worked out in the application from B's read at t+2 and sent as a fixed number (`300000.00 - 80000.00`). PostgreSQL has nothing to compare it with, so it overwrites A's change without an error. Even if B had written while A was still open, B would only have waited for A's commit and then written the same number. The fault is the read-then-write pattern: the read and the write are separate statements, and the database does not know that one depends on the other.

**Fix 1: `FOR UPDATE` makes the second reader wait.** `SELECT ... FOR UPDATE` locks the row until the transaction ends. B's read waited from t+2 to t+4.0 and then returned A's committed balance, so B worked from 180,000.00. `pg_locks` shows how PostgreSQL does this. Row locks are not kept in the lock table; they are written on the row itself. A waiting session therefore takes the row's `tuple` lock to hold its place in the queue, and then waits for a `ShareLock` on the other transaction's id, which is only released when that transaction ends.

**Fix 2: an atomic `UPDATE` reads and writes in one step.** `balance = balance - x` is worked out from the row as the `UPDATE` changes it, not from a value read earlier. B's `UPDATE` also waited for A's row lock. When A committed, PostgreSQL re-read the new version of the row, checked the `WHERE` clause again against 180,000.00, and subtracted from that. The `balance >= x` condition is the funds check. In the third transfer it matched no row, so nothing was written, no error was raised, and the application saw `UPDATE 0` and cancelled. The `wallets_balance_non_negative` CHECK is still there as a last line of defence, but it is never reached.

**Fix 3: SERIALIZABLE turns the conflict into an error.** Under REPEATABLE READ and SERIALIZABLE, a transaction works from one snapshot taken at its first query. When B tried to update a row that A had changed and committed after B's snapshot, PostgreSQL refused with SQLSTATE 40001 instead of letting B overwrite it. Nothing waited in advance; the conflict was found at B's write. The cost moves to the application, which must roll back and run the whole transaction again. Running only the failed statement again would not help, because the value it writes came from the old read. The retry is a new transaction with a new snapshot, so it saw 180,000.00.

**Which fix suits a wallet.**

| Fix | Second session | Lock held | Application must | Best for |
| --- | --- | --- | --- | --- |
| `SELECT ... FOR UPDATE` | waits, then reads the new balance | from the read until `COMMIT` | remember `FOR UPDATE` on every read it will write from | read, check (limits, fraud rules), then write |
| Atomic `UPDATE ... WHERE balance >= x` | waits, then re-checks the row | from the `UPDATE` until `COMMIT` | check the row count | a simple debit |
| SERIALIZABLE + retry | fails with 40001 | none in advance | retry the whole transaction | complex transactions over many rows |

For a Proclus transfer, the atomic `UPDATE` suits best. The debit and the funds check are one statement, so no application code can get between them, and the lock is held for the shortest time. An insufficient-funds transfer ends with a clean `UPDATE 0` instead of an error. `FOR UPDATE` is the choice when the application must look at the balance before deciding, for example to apply a daily limit. SERIALIZABLE protects code that nobody remembered to lock, but every caller then needs retry logic, and retries add work when many people pay from the same wallet at once.

## Challenges and decisions

- **Where the scripts start.** The database held the million-row Portfolio 2 data, and committed transfers would change the sample wallets on every run. I chose to rebuild the Portfolio 1 sample at the start of each script, as Portfolio 2's seed does, so each run starts from known balances and gives the same output. The large data set can be rebuilt with Portfolio 2's seed script.
- **Showing the error, not hiding it.** Portfolio 1's constraint tests caught each error inside a helper function. Here the point is to see the transaction fail, so the scripts let `psql` print the real error, with `ON_ERROR_STOP` switched off only around the statements that are meant to fail.
- **Transfers written as completed in one step.** A transfer row is inserted with status `completed` inside the same transaction that moves the money. No other session can see it before `COMMIT`, so it can never be seen as completed while the money has not moved.
- **Running two sessions the same way every time.** The guide asks for two `psql` sessions side by side. Typing into two windows by hand is slow, and the timing, and so the output, changes on every run. I wrote [run_two_sessions.ps1](run_two_sessions.ps1) to start both sessions with one shared start time from the server, and [sql/two_session_clock.sql](sql/two_session_clock.sql) to make each step wait for its second. Every pair then ran twice with identical output, and `-Show` still opens the two sessions side by side for the screenshots. The runner is an extra file next to `sql/` that the guide's folder list does not name. The first run failed because Windows PowerShell 5.1 dropped the double quotes inside the query that builds the start time. I built the timestamp without them.
- **Showing the wait, not only describing it.** Saying that B waits is not evidence. Session A queries `pg_stat_activity`, `pg_blocking_pids()` and `pg_locks` while B is blocked, and names the sessions by `application_name` because process ids change on every run. B prints the time when its blocked statement returns, so the log shows the wait from t+2 to t+4.0.
- **SERIALIZABLE or REPEATABLE READ for fix 3.** The guide allows either. I used SERIALIZABLE, the level the guide's summary names. I checked on a throwaway table that REPEATABLE READ gives the same `could not serialize access due to concurrent update` here, because both levels refuse to overwrite a row changed after the snapshot.
- **A retry without a loop.** An application would retry in a loop, but `psql` scripts have no loops. The retry is written out once and runs only if `LAST_ERROR_SQLSTATE` is `40001`, so any other error is not retried.
