# Portfolio 3: Transactions and concurrency

> In progress. Done: commit/rollback and savepoints. Still to come: the two-session scenarios (lost update and its three fixes, non-repeatable read, deadlock) and the screenshots.

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

## What I did

1. Wrote a transfer as one transaction in [sql/01_commit_rollback.sql](sql/01_commit_rollback.sql). A transfer writes a `transfers` row, debits the sender, credits the receiver and adds two ledger rows. Part 1 sends NGN 25,000.00 from wallet 3 to wallet 6 and commits. Part 2 tries to send NGN 50,000.00 from wallet 2, which holds NGN 23,500.00. The credit to wallet 7 is applied first, on purpose, so there is something to undo. The debit then breaks the `wallets_balance_non_negative` CHECK, and `ROLLBACK` undoes everything.
2. Wrote a batch of three payments in one transaction in [sql/02_savepoints.sql](sql/02_savepoints.sql). Wallet 17 (NGN 225,000.00) pays NGN 100,000.00, then NGN 150,000.00, then NGN 50,000.00. The second payment fails for lack of funds. `ROLLBACK TO SAVEPOINT` undoes only that payment, the failure is recorded as a `failed` transfer with an audit-log entry, the third payment goes through, and one `COMMIT` keeps it all.
3. Ended both scripts with the balance audit from Portfolio 1: every stored balance must equal its ledger total.
4. Ran each script twice in a row. Both runs gave identical output. Saved the output in [logs/](logs/).

## Evidence

| Evidence | File | What it shows |
| --- | --- | --- |
| Commit and rollback log | [logs/01_commit_rollback_output.txt](logs/01_commit_rollback_output.txt) | Part 1: wallet 3 goes from 146,800.00 to 121,800.00 and wallet 6 from 0.00 to 25,000.00, with both ledger legs. Part 2: wallet 7 shows 115,000.00 inside the transaction. The debit fails with `violates check constraint "wallets_balance_non_negative"`, and the next read is refused (`current transaction is aborted`). After `ROLLBACK`, wallets 2 and 7 are back at 23,500.00 and 65,000.00, and there are still 13 transfers and 49 ledger rows. The audit finds 0 mismatches in 25 wallets. |
| Savepoint log | [logs/02_savepoints_output.txt](logs/02_savepoints_output.txt) | Payment 2 fails on the same CHECK. After `ROLLBACK TO SAVEPOINT before_payment_2` the same read works again and shows 125,000.00, so payment 1 survived. After `COMMIT`, wallet 17 holds 75,000.00, wallets 10 and 20 hold 100,000.00 and 50,000.00, and wallet 14 is unchanged. There are two completed transfers with two ledger rows each, and one failed transfer with none. The audit finds 0 mismatches. |

## Analysis

**A transaction is all or nothing (atomicity).** In Part 2 of `01`, wallet 7 had already been credited when the debit failed. Without a transaction, that credit would stay and NGN 50,000.00 would appear from nowhere. `ROLLBACK` removed the credit and the half-written transfer row together, and the balance audit still matches the ledger.

**After an error, PostgreSQL refuses the rest of the transaction.** Once a statement fails, every later statement in the same transaction is rejected until `ROLLBACK`, even a plain `SELECT`. This stops an application from carrying on as if the failed step had worked.

**A savepoint limits how much is undone.** In `02`, a plain `ROLLBACK` would have thrown away payment 1 as well. `ROLLBACK TO SAVEPOINT` undid only the work after the mark and cleared the error, so the batch could record the failure and go on. Other sessions saw nothing until the final `COMMIT`, and then saw all of it at once.

**Rolled-back work still uses up ids.** The rolled-back transfer in `01` took `transfer_id` 14, and the failed payment in `02` was given 15, not 14. Sequences never go backwards, even on rollback, because giving a number back would make concurrent sessions wait for each other. Gaps in ids are therefore normal. The transfer `reference` is the business key, and it was free to use again because the rolled-back row never existed.

## Challenges and decisions

- **Where the scripts start.** The database held the million-row Portfolio 2 data, and committed transfers would change the sample wallets on every run. I chose to rebuild the Portfolio 1 sample at the start of each script, as Portfolio 2's seed does, so each run starts from known balances and gives the same output. The large data set can be rebuilt with Portfolio 2's seed script.
- **Showing the error, not hiding it.** Portfolio 1's constraint tests caught each error inside a helper function. Here the point is to see the transaction fail, so the scripts let `psql` print the real error, with `ON_ERROR_STOP` switched off only around the statements that are meant to fail.
- **Transfers written as completed in one step.** A transfer row is inserted with status `completed` inside the same transaction that moves the money. No other session can see it before `COMMIT`, so it can never be seen as completed while the money has not moved.
