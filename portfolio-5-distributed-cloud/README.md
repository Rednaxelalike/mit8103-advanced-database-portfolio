# Portfolio 5: Distributed and cloud database exercise

## Objective

This portfolio replicates the Proclus database: a local PostgreSQL primary streams every change to a read replica that can serve customer statements, while balances are always read from the primary. It measures what the replica costs and risks (replication lag, stale reads, failover), and compares it with the three-member replica set behind the MongoDB Atlas cluster from Portfolio 4.

## Environment

- **Primary:** PostgreSQL 18.6 on `localhost:5432`, the Windows service `postgresql-x64-18` used by Portfolios 1-3, database `proclus`.
- **Replica:** a second PostgreSQL 18.6 instance on `localhost:5433`, built from the primary with `pg_basebackup -R` into `C:\Users\USER\pg18-replica-5433` (outside the repo) and started with `pg_ctl`. It streams WAL as the role `replicator` through the replication slot `replica_5433`, asynchronously. Every step is in [setup-replica.md](setup-replica.md).
- **Connecting:** `psql -X -w -U postgres -h localhost -p 5432 -d proclus` for the primary, `-p 5433` for the replica, with `PGPASSWORD` loaded from `.env` (see [SETUP.md](../SETUP.md)). The replica is a copy of the whole primary, so the same `postgres` password works on both.
- **Cloud:** the MongoDB Atlas M0 cluster `proclus-cluster` from Portfolio 4, MongoDB 8.0.36. It is the three-member replica set `atlas-100ow8-shard-0` on AWS, region `AF_SOUTH_1` (Cape Town). The scripts connect with `mongosh` 2.12.0 and `MONGODB_URI` from `.env`.

## How to run

1. Build and start the replica by following [setup-replica.md](setup-replica.md), Steps 1-8. Load `PGPASSWORD` from `.env` as described in SETUP.md.
2. From the repo root, run the tests in order:

   ```
   psql -X -w -U postgres -h localhost -p 5432 -d proclus -v ON_ERROR_STOP=1 -f portfolio-5-distributed-cloud/tests/01_replication_status.sql
   psql -X -w -U postgres -h localhost -p 5432 -d proclus -v ON_ERROR_STOP=1 -f portfolio-5-distributed-cloud/tests/02_write_on_primary.sql
   psql -X -w -U postgres -h localhost -p 5433 -d proclus -f portfolio-5-distributed-cloud/tests/03_replica_rejects_writes.sql
   .\portfolio-5-distributed-cloud\tests\04_replication_lag.ps1
   ```

   - `01` only reads, so it can be run at any time.
   - `02` rebuilds the Portfolio 1 sample data on the primary first, so it can be run again at any time. It switches between the two servers with `\connect`.
   - `03` runs on the replica (note `-p 5433`) and leaves `ON_ERROR_STOP` off, because every write in it fails on purpose.
   - `04` is a PowerShell runner. It runs Portfolio 2's `01_seed_large.sql` on the primary as the load, and `tests/04_replication_lag.sql` alongside it as the sampler. It takes about three minutes, and it leaves the million-row Portfolio 2 data set on both servers.

3. Run the failover drill, then look at the split brain it leaves:

   ```
   .\portfolio-5-distributed-cloud\tests\05_failover.ps1
   psql -X -w -U postgres -h localhost -p 5432 -d proclus -v ON_ERROR_STOP=1 -f portfolio-5-distributed-cloud/tests/06_split_brain.sql
   ```

   - `05` runs the three `05_failover_*.sql` stages around two commands: `pg_ctl stop -m immediate` on the primary, which Windows runs as administrator after a UAC prompt, and `pg_ctl promote` on the replica. Stage 1 rebuilds the Portfolio 1 sample data first. The drill ends with port 5432 stopped and port 5433 a primary.
   - Before `06`, start the primary's service again: step 1 of "After the failover drill" in setup-replica.md. Afterwards, rebuild the replica (step 3 there).

4. Collect the Atlas evidence. Load `MONGODB_URI` from `.env` (SETUP.md) and make sure your current IP is on the Atlas Network Access list:

   ```
   mongosh "$MONGODB_URI" --quiet --file portfolio-5-distributed-cloud/tests/07_atlas_replica_set.js
   ```

   It works on whichever Portfolio 4 data is on Atlas, and first removes what a previous run added, so it can be run again at any time. It ends with `All checks passed.` and exit code 0, or exits with code 1 if any check fails.

## What I did

1. **Prepared the primary.** It needed no `postgresql.conf` changes: the installer's defaults (`wal_level = replica`, `max_wal_senders = 10`, `max_replication_slots = 10`) already allow streaming replication. I created a dedicated role, `replicator`, with only the `REPLICATION` attribute ([config/primary_replication_role.sql](config/primary_replication_role.sql)). I then narrowed the three `replication` lines of `pg_hba.conf` from any role to `replicator` ([config/primary_pg_hba.conf.diff](config/primary_pg_hba.conf.diff)), and reloaded the configuration without a restart.
2. **Built the replica** with `pg_basebackup -R -C -S replica_5433 -X stream`. It copied 34,760 kB in 10.7 s, wrote `standby.signal` and `primary_conninfo`, and created the replication slot. I changed the copy's port to 5433 and named it `replica_5433` ([config/replica_postgresql.conf.diff](config/replica_postgresql.conf.diff)), then started it with `pg_ctl`. The replica's password stays in `pgpass.conf`. The generated [config/replica_postgresql.auto.conf](config/replica_postgresql.auto.conf) names that file instead of holding the password.
3. **Checked the connection from both ends** with [tests/01_replication_status.sql](tests/01_replication_status.sql). It shows the primary's settings, `pg_stat_replication` and the slot, then the replica's `pg_is_in_recovery()`, `pg_stat_wal_receiver` and replay position, and the row counts on each server.
4. **Showed a write on the primary reaching the replica** with [tests/02_write_on_primary.sql](tests/02_write_on_primary.sql).
   - Chinedu Okafor funds wallet 1 with ₦50,000 on the primary. The script waits until the replica has replayed past the commit's WAL position, then reads the wallet's November statement from the replica.
   - Part 2 pauses replay on the replica with `pg_wal_replay_pause()`, to stand in for a replica that has fallen behind. Chinedu then pays Lekki Fresh Mart ₦18,000 on the primary. The replica, still paused, returns the old balance and a statement without the payment. After `pg_wal_replay_resume()` both servers agree again, and the balance audit passes on the replica.
5. **Showed that the replica refuses writes** with [tests/03_replica_rejects_writes.sql](tests/03_replica_rejects_writes.sql). It tries eight kinds of write, from an `UPDATE` of a balance to `BEGIN READ WRITE`, and prints the SQLSTATE for each.
6. **Measured replication lag** with [tests/04_replication_lag.sql](tests/04_replication_lag.sql), run by [tests/04_replication_lag.ps1](tests/04_replication_lag.ps1). First it reads `pg_stat_replication` with the primary idle. Then it samples the view every half second while Portfolio 2's seed loads about a million ledger rows in one transaction, and keeps going until the replica has replayed everything the load wrote. Finally it compares the row counts on both servers.
7. **Ran a failover drill** with [tests/05_failover.ps1](tests/05_failover.ps1):
   - **Stage 1** ([05_failover_1_primary.sql](tests/05_failover_1_primary.sql)): Ibrahim Musa (wallet 5) sends Tunde Bakare (wallet 9) ₦40,000 on the primary, and the script waits until the replica has replayed it.
   - **The crash:** the primary is stopped with `pg_ctl stop -m immediate`, which ends it without a shutdown checkpoint, like a power cut.
   - **Stage 2** ([05_failover_2_standby_alone.sql](tests/05_failover_2_standby_alone.sql)): the replica alone. It still answers reads, but refuses a transfer.
   - **The promotion:** `pg_ctl promote` on port 5433.
   - **Stage 3** ([05_failover_3_promoted.sql](tests/05_failover_3_promoted.sql)): the promoted server is on timeline 2 and still holds the ₦40,000 transfer. Tunde refunds Ibrahim ₦15,000, and the balance audit passes. The runner times each step and copies the replica's own log lines for the promotion into the evidence log.
8. **Brought the old primary back** with its Windows service, and ran [tests/06_split_brain.sql](tests/06_split_brain.sql) while port 5433 was still promoted. Both servers accepted writes and disagreed about wallet 9. I then rebuilt the replica from port 5432 ("After the failover drill" in setup-replica.md). The drill and the rebuild were each run twice on 4 November and once more on 5 November for the screenshots; the logs come from the 5 November run.
9. **Collected the cloud evidence on Atlas** with [tests/07_atlas_replica_set.js](tests/07_atlas_replica_set.js):
   - It lists the replica set's members with `hello` and `rs.status()`, then connects to each member directly to show its role. A write sent straight to a secondary is refused.
   - It repeats the local test 02 on Atlas: Chinedu Okafor funds wallet 1 with ₦50,000 as a multi-document transaction committed with `w: "majority"`.
   - It writes two audit entries, one with `w: 3` and one with `w: 4`.
   - It reads the balance from the primary, and the November statement from a secondary with `readConcern: "majority"` in a causally consistent session.
10. **Wrote the discussion** at the end of the Analysis: synchronous against asynchronous replication for money, CAP and PACELC for Proclus, a sharding plan by `customer_id` with the Portfolio 2 queries sorted into single-shard and cross-shard, and how a managed cloud database would host it. Each part draws on the numbers from tests 02-07.

## Evidence

| Evidence | File | What it shows |
| --- | --- | --- |
| Setup notes | [setup-replica.md](setup-replica.md) | Every command used to build the replica, the expected output of each step, how to start, stop and rebuild it, and what the replication slot costs. |
| Configuration | [config/](config/) | The role script; the `pg_hba.conf` change on the primary as a diff; the replica's `postgresql.conf` changes as a diff; the `postgresql.auto.conf` that `pg_basebackup -R` generated. |
| Status log | [logs/01_replication_status_output.txt](logs/01_replication_status_output.txt) | The primary: `wal_level = replica` and an empty `synchronous_standby_names`. One standby, `replicator` from `::1` as `replica_5433`, is `streaming` and `async`, 0 bytes behind, and the slot is `active`. The replica: `in_recovery = t`, `transaction_read_only = on`, and the WAL receiver is `streaming` from `localhost:5432` through slot `replica_5433`. Both servers count 20 customers, 25 wallets, 12 transfers and 49 ledger rows. The log was taken after test 02, whose funding and payment add two ledger rows to Portfolio 1's 47. |
| Write log | [logs/02_write_on_primary_output.txt](logs/02_write_on_primary_output.txt) | The funding commits on the primary at WAL position `2/80BC4520`. The replica had replayed it after a 1.3 ms wait and lists ledger row 48 with the same id. With replay paused, the payment's WAL has arrived on the replica (received `2/80BC4888`) but is not applied (replayed `2/80BC4520`, 872 bytes behind). The primary answers ₦134,549.50 and the replica ₦152,549.50. After resuming, the replica applies the payment within 1.0 ms, shows both rows, and its balance audit finds 0 mismatches in 25 wallets. |
| Read-only log | [logs/03_replica_rejects_writes_output.txt](logs/03_replica_rejects_writes_output.txt) | Reads work on port 5433. `UPDATE`, `INSERT`, `DELETE`, `SELECT ... FOR UPDATE`, `nextval()`, `CREATE TABLE`, and an `UPDATE` after `SET default_transaction_read_only = off` all fail with 25006, "cannot execute ... in a read-only transaction". `BEGIN READ WRITE` fails with 0A000, "cannot set transaction read-write mode during recovery". The balance and row counts are unchanged afterwards. |
| Lag log | [logs/04_replication_lag_output.txt](logs/04_replication_lag_output.txt) | Idle: 0 bytes behind, with write and flush lag of 0.3 ms. During the load, in 10-second windows: the WAL written, the worst bytes behind and the worst write, flush and replay lag, next to the statement the load was running. The summary row: 292 samples over the 148.1 s load, which wrote 601 MB of WAL; at most 4,096 kB behind (331 kB on average); replay lag at most 330 ms (106 ms on average); caught up 2 ms after the load's session ended. Both servers then hold 50,020 customers, 58,583 wallets, 199,051 transfers and 1,040,093 ledger rows. |
| Load log | [logs/04_load_seed_large_output.txt](logs/04_load_seed_large_output.txt) | The load itself: Portfolio 2's seed output, ending with its four audits passing and the table sizes. |
| Failover log | [logs/05_failover_output.txt](logs/05_failover_output.txt) | Timestamped steps. Stage 1: the ₦40,000 transfer commits on the primary (timeline `00000001`) and is replayed on the replica within 15.8 ms. The primary is stopped at 08:08:36.865, the service shows `Stopped`, and a connection to 5432 is refused. Stage 2: the replica has received and replayed the same position, has no WAL receiver connected, still lists Tunde's transfer, and refuses the refund with 25006. `pg_ctl promote` takes 0.4 s, and the replica's log shows `received promote request`, `selected new timeline ID: 2`, `database system is ready to accept connections`. Stage 3: `in_recovery = f`, timeline `00000002`, the ₦40,000 transfer is there, the refund commits (wallet 5 ₦275,000, wallet 9 ₦290,000), there are 0 replicas, and 0 of 25 balances mismatch. Writes were impossible for 5.0 s. |
| Split-brain log | [logs/06_split_brain_output.txt](logs/06_split_brain_output.txt) | After its service restarts, port 5432 is a primary again on timeline 1. It has the ₦40,000 transfer but not the refund: wallet 9 is ₦305,000, and its slot is inactive. Port 5433 is also a primary, on timeline 2, with the refund: wallet 9 is ₦290,000. Two servers each accepting writes, with different balances. |
| Atlas log | [logs/07_atlas_replica_set_output.txt](logs/07_atlas_replica_set_output.txt) | Replica set `atlas-100ow8-shard-0` on AWS `AF_SOUTH_1`. `rs.status()` lists three healthy members: `shard-00-02` PRIMARY, and `shard-00-00` and `shard-00-01` SECONDARY, both syncing from the primary, 1 s behind it at one-second resolution. Connected directly, only `shard-00-02` reports `isWritablePrimary true`, and a write sent to `shard-00-00` is refused with `NotWritablePrimary` (10107). The funding commits with `w: "majority"` as ledger entry 227896. `w: 3` is acknowledged. `w: 4` fails with `UnsatisfiableWriteConcern` (100), "Not enough data-bearing nodes", yet the entry is stored. The balance, ₦152,549.50, is read from the primary. The statement, read from secondary `shard-00-00`, includes the funding. All 11 checks pass. The log comes from a second run, which first removed the first run's funding and audit entries. |
| Screenshot | [screenshots/p5-01-replication-status.png](screenshots/p5-01-replication-status.png) | Test 01 in a psql console, run on 5 November after the Portfolio 1 data had been rebuilt. Port 5432 shows the standby `replica_5433` as `streaming` and `async`, 0 bytes behind, with an active slot. Port 5433 shows `in_recovery = t`, `transaction_read_only = on` and a WAL receiver `streaming` from port 5432. Both count 20 / 25 / 12 / 47 rows: Portfolio 1's data, freshly rebuilt, where the log (taken after test 02) counts 49 ledger rows. Otherwise it matches the log apart from LSNs, pids, times and lag values. |
| Screenshot | [screenshots/p5-02-write-on-primary.png](screenshots/p5-02-write-on-primary.png) | Test 02 in a psql console. Part 1: the funding reaches the replica (this run waited 18.0 ms) and wallet 1 reads ₦152,549.50 there. Part 2: with replay `paused`, the primary has ₦134,549.50 after the ₦18,000 payment while the replica still returns ₦152,549.50; once replay resumes, the replica applies the payment and agrees. Same values as the log; only LSNs, wait times and bytes behind differ. |
| Screenshot | [screenshots/p5-03-replica-rejects-writes.png](screenshots/p5-03-replica-rejects-writes.png) | Test 03 in a psql console on port 5433. Every write, from `UPDATE` to `CREATE TABLE`, fails with `cannot execute ... in a read-only transaction`, `BEGIN READ WRITE` fails with `cannot set transaction read-write mode during recovery`, and the counts are unchanged afterwards. Identical to the log. |
| Screenshot | [screenshots/p5-04-replication-lag.png](screenshots/p5-04-replication-lag.png) | The lag test as two psql consoles side by side: the sampler (left) and Portfolio 2's seed as the load (right), started in that order with the same commands as the runner. This is a separate run on 5 November, not the logged one: 737 MB of WAL in 190.6 s, peak 17,451 kB behind, peak replay lag 508 ms, caught up 512 ms after the load ended. It lands within the range of the earlier runs, and both servers end with the same 1,040,093 ledger rows. |
| Screenshot | [screenshots/p5-05-failover-drill.png](screenshots/p5-05-failover-drill.png) | The console of `tests/05_failover.ps1` during the 5 November drill, the run that wrote the log. Its timestamped steps: the primary crashed at 08:08:36.865, the service `Stopped`, `pg_ctl promote` took 398 ms, the replica's own log lines (the WAL stream lost, `received promote request`, `selected new timeline ID: 2`), and the summary: writes impossible for 5.0 s. The psql output of each stage is in the log. |
| Screenshot | [screenshots/p5-06-split-brain.png](screenshots/p5-06-split-brain.png) | Test 06 in a psql console, right after the drill above. Port 5432 is a primary on timeline `00000001` with wallet 9 at ₦305,000, and port 5433 is a primary on timeline `00000002` with the refund and wallet 9 at ₦290,000. The log was taken from the same state immediately afterwards. |
| Screenshot | [screenshots/p5-07-atlas-replica-set.png](screenshots/p5-07-atlas-replica-set.png) | Test 07 in a mongosh console on 5 November. It shows the three members (one PRIMARY, two SECONDARY, all healthy), the write refused by a secondary, the funding committed with `w: "majority"`, `w: 3` and `w: 4`, the balance read from the primary and the statement from a secondary. All checks pass. This run read the statement from the other secondary (`shard-00-01`), and one secondary was 2 s behind; `readPref('secondary')` may pick either secondary, so the log's `shard-00-00` and this are both expected. |

## Analysis

### What the replica is, and what it is not

The replica is a physical copy of the whole primary cluster, kept current by replaying the primary's WAL record by record. Every table, index and row matches the primary's (01, 04), including identity values: the funding is ledger row 48 on both servers (02). It does not run SQL itself. Even the `DROP TABLE` and `CREATE TABLE` statements of the Portfolio 1 rebuild in 02 reach it only as WAL.

Replication is **asynchronous** (`sync_state = async`, empty `synchronous_standby_names`). A commit on the primary returns as soon as the primary's own WAL is on disk. The replica receives the change a moment later. If the primary's disk were lost in that moment, the last committed transactions would be lost with it. The failover drill and the discussion return to this.

### Why statements can come from the replica but balances cannot

The replica serves reads, and every kind of write is refused (03). That includes `SELECT ... FOR UPDATE`, the row lock that Portfolio 3 used to fix the lost update. So every transfer, payment and balance check has to run on the primary. That alone does not settle where a *displayed* balance should be read from.

Part 2 of 02 settles it. With replay paused, the replica had already **received** the payment's WAL but had not **applied** it, so it answered ₦152,549.50 where the primary answered ₦134,549.50. Pausing only makes the situation reliable to reproduce. Under load the replica really is behind by up to megabytes of WAL (04). A customer who checked their balance on the replica could see money they had already spent, and a statement could be missing a payment the customer has just made. So for Proclus:

- **Statements and history** (Portfolio 2's Q1 statement query, monthly totals, merchant reports) can be read from the replica. These are large, read-only scans, and moving them off the primary leaves it free for transfers. A statement a fraction of a second out of date is acceptable, and it is internally consistent: replay applies whole transactions, so the funding row and the new balance appear together, never one without the other.
- **Balances, and any read that leads to a write** (the balance check before a transfer, a KYC tier check before a limit is raised) go to the primary.

### How far behind the replica gets

| Measure (from the final run of 04) | Primary idle | During the 148 s load (601 MB of WAL) |
| --- | --- | --- |
| WAL not yet replayed on the replica | 0 bytes | at most 4,096 kB; 331 kB on average |
| `write_lag` / `flush_lag` | 0.3 ms | at most 122 ms |
| `replay_lag` | 1.13 s (an old value, see below) | at most 330 ms; 106 ms on average |
| Time to catch up after the load ended | | 2 ms |

Two earlier runs of the same test, on the same day, peaked at 17,111 kB and 21,417 kB behind, with replay lag of 0.63 s and 1.49 s. Their worst windows came during the bulk insert of the ledger rows and during the seed's closing `VACUUM (ANALYZE)`. Even then, the replica kept within about one to two seconds of the primary on a single laptop, and it caught up within milliseconds of the load ending.

How to read the columns:

- **Bytes behind** is the most direct measure: WAL the primary has written that the replica has not yet applied. It was 0 in most quiet windows.
- **`write_lag` and `flush_lag`** fell to 1-6 ms in quiet windows. That is the time for WAL to reach the replica's disk.
- **`replay_lag`** stayed at about 210-235 ms in most windows where the replica was only a few kB behind. The primary can only learn that WAL was *applied* from the replica's next status message, so I read this column as an upper bound and rely on bytes behind instead.
- **The idle `replay_lag` of 1.13 s, with 0 bytes behind, is not current lag.** The PostgreSQL documentation explains that once a standby has caught up and is idle, the last measured lag keeps being shown for a while before the column turns NULL. In test 01, run after a longer idle spell, all three columns were NULL.

### The failover drill

**What was lost.** Nothing, this time. The replica had replayed the ₦40,000 transfer 15.8 ms after it committed, and in stage 2 its received and replayed positions were the same. So when it was promoted it held every transaction the old primary had committed. Asynchronous replication does not promise this. A commit on the primary is final as soon as the primary's own disk has it. Anything still in the gap that test 04 measured (up to 4-21 MB of WAL during a heavy load) is gone if the primary's disk is lost with it. For a wallet, those are transfers the customer was told had succeeded. Synchronous replication (`synchronous_standby_names`) closes the gap: each commit then waits until a standby has the WAL too. The cost is a slower commit, and with a single standby, no commits at all while that standby is down. The discussion section weighs this for Proclus.

**How long writes stopped.** 5.0 s, from the crash at 08:08:36.9 to the end of `pg_ctl promote` at 08:08:41.9. The promotion itself took 0.4 s. Most of the rest was the script checking that port 5432 really was down: a refused connection on Windows takes about two seconds per address, and `localhost` has two (`::1` and `127.0.0.1`). Throughout the outage the replica kept serving statements (stage 2). Only writes stopped. In a real deployment a person or a failover manager has to notice the failure and decide to promote, and that usually takes far longer than the promotion.

**Why the timeline changes.** Promotion starts timeline 2. From that point every WAL file the new primary writes is named `00000002...`, and a `.history` file records where timeline 1 ended. So WAL from the old primary can never be mistaken for the new primary's. That separation is what makes the next problem visible instead of silent.

**Split brain.** Nothing stops the old primary from coming back. When its service was started again (test 06), it ran crash recovery and accepted writes on timeline 1, while port 5433 accepted writes on timeline 2. Tunde Bakare had ₦305,000 on one server and ₦290,000 on the other, and each server would have accepted the next transfer against its own balance. Neither ledger is wrong on its own, and nothing could merge them automatically afterwards. Two rules prevent this:

- **Fencing.** The old primary must be kept down, or kept out of reach of the application, before the replica is promoted. Real failover managers do this with a lock in a consensus store, or by cutting the old server's network or power.
- **Rejoin as a replica.** A failed primary never returns as a primary. It comes back as a replica of the new one, rebuilt with `pg_basebackup` or rewound with `pg_rewind`.

For this lab I did the reverse and kept port 5432, which every other script uses, so the drill's timeline 2 (the refund) was discarded. setup-replica.md records both routes.

**A gap in the ids.** The ₦40,000 transfer was `transfer_id` 13. The refund on the promoted server was 46, not 14, and its ledger rows jumped from 49 to 67 and 68. PostgreSQL writes a sequence's progress to WAL 32 values at a time, so the replica only knew that ids up to the end of the last batch might have been handed out. To be safe, the new primary carried on after that batch. Ids from an identity column are unique, but they are not gap-free, and a failover is one of the things that makes gaps. Proclus's references (`TRF...`, `TXN...`) and the ledger order by `created_at` do not rely on gap-free ids.

**What the drill leaves exposed.** For the time between the promotion and the rebuild, Proclus ran on one server with no replica (`replicas_connected = 0` in stage 3). A second failure in that window would lose everything written since the first.

### The Atlas replica set

The Atlas cluster behind Portfolio 4 has had this set-up all along, managed by MongoDB: three data-bearing members on AWS in Cape Town, one primary and two secondaries, each copying the primary's oplog (`syncing from shard-00-02`). It differs from the local pair in three ways that matter for Proclus.

- **Durability is chosen per write.** PostgreSQL's choice is made for the whole server in `synchronous_standby_names`. MongoDB's is made per write, through its write concern.
  - `w: "majority"` returned only once two of the three members had the funding. Whichever secondary would be elected if the primary failed is guaranteed to hold it. This is what the local asynchronous replica could not promise, and what money movements need.
  - `w: 3` waits for every member. It is stronger, but a single slow or failed secondary then stalls every such write.
  - `w: 4` cannot be met with three data-bearing members, so the server says so: `UnsatisfiableWriteConcern`. The entry was stored on the primary anyway. A write-concern error reports that the acknowledgement failed; it does not undo the write. An application that simply retried would record the entry twice, so retries need an idempotent key, such as Proclus's unique `reference`.
- **Reads choose their member.** `readPref('secondary')` sent the statement to `shard-00-00`, while the balance came from the primary. This is the local rule (statements from the replica, balances from the primary) applied per query instead of per connection string. A secondary can still be behind; `rs.status()` showed both about one second behind the primary. Reading the statement with `readConcern: "majority"`, in the same causally consistent session as the funding, made the secondary wait until it had applied that session's own write. So the customer's statement could not miss the top-up they had just made. The local replica offers no such guarantee; test 02 had to wait on WAL positions by hand.
- **Failover is automatic.** If the primary stopped answering, the two secondaries would elect a new primary between themselves, with no `pg_ctl promote` and no person deciding. A majority is needed to elect, so a member cut off on its own cannot become a second primary: the split brain of test 06 cannot happen. The free M0 tier does not let me trigger a failover or add shards, so that part rests on the local drill and the discussion.

### Synchronous or asynchronous replication for money

With asynchronous replication, the primary tells the customer "transfer successful" before the replica has the transfer. If the primary is lost in that gap and the replica is promoted, the transfer is gone, although the customer saw it succeed. The sender may then spend the money again, and the receiver never gets it. The size of the gap is what this portfolio measured. In the failover drill it was 15.8 ms, so nothing was lost. During the load in test 04, the replica was up to 4,096 kB of WAL behind in replay (17,111 kB and 21,417 kB in the earlier runs), and WAL took up to 122 ms to reach its disk. A crash at those moments would lose whatever had not yet reached the replica.

PostgreSQL can make the commit wait. With `synchronous_standby_names = 'replica_5433'`, a commit returns only once the standby has the WAL, at the level chosen by `synchronous_commit`:

| `synchronous_commit` | The commit waits until the WAL is | What it protects against |
| --- | --- | --- |
| `local` | on the primary's disk only | A primary crash, but not losing the primary's disk |
| `remote_write` | handed to the standby's operating system | A primary loss, unless the standby's machine also crashes |
| `on` | on the standby's disk | Losing either server |
| `remote_apply` | applied on the standby | The same, and a read on the standby right after the commit sees it |

The cost is paid on every commit: one round trip to the standby. On one laptop that is almost nothing, but between data centres it is added to every transfer. The bigger cost is availability. With one synchronous standby, if the standby stops, every commit on the primary waits until it returns or someone changes the setting. Synchronous replication with a single standby turns a replica failure into an outage.

For Proclus I would use synchronous replication for money, with two standbys and a quorum: `synchronous_standby_names = 'ANY 1 (replica_a, replica_b)'` and `synchronous_commit = on`. A commit then waits for either standby, so one slow or failed standby does not stop transfers. Any committed transfer is on at least two servers. This is the same rule as Atlas's `w: "majority"`: two of three. `remote_apply` is not needed, because balances are read from the primary anyway. Statements can stay on an ordinary asynchronous replica. `synchronous_commit` can also be set per transaction (`SET LOCAL synchronous_commit = local`), which suits batch jobs that can simply be run again, such as Portfolio 2's seed. Ordinary Proclus writes (transfers, payments, KYC changes, audit entries) keep the synchronous default.

### CAP and PACELC for Proclus

CAP is about a network partition: when servers cannot reach each other, a system must either refuse some requests (consistency) or answer them and risk different servers giving different answers (availability). Proclus does not need one answer for everything:

- **Balances and transfers choose consistency.** A wallet must never be debited on two servers at once. Test 06 showed what happens when both sides stay available: port 5432 said Tunde's wallet held ₦305,000 and port 5433 said ₦290,000, with no automatic way to merge them. A refused transfer can be retried, but a double spend means money that has to be recovered from a customer. So during a partition, the side without the primary must refuse transfers. This is what Atlas does: a member cut off on its own cannot get a majority and so cannot become primary.
- **Statements and history choose availability.** The replica keeps answering if it loses the primary. The statement may be a few seconds old, which is acceptable if the screen shows the time it is "as at".

PACELC adds the normal case: **else**, with no partition, the trade-off is between latency and consistency. The tests measured both sides of that:

| Choice | Example from this portfolio | Latency | Consistency |
| --- | --- | --- | --- |
| Read the primary | Balances (02, 07) | One server, no waiting | Always current |
| Read the async replica | Statement in 02, part 2 | No extra wait | Can be stale: ₦152,549.50 against ₦134,549.50 |
| Atlas secondary, `readConcern: "majority"` in a causal session | Statement in 07 | Waits for the secondary to catch up | Sees the session's own funding |
| Async commit | Local primary today | Commit returns at once | Can lose the newest transfers in a failover |
| Majority commit | Atlas funding in 07 | Waits for a second member | Survives losing any one member |

In PACELC terms, Proclus should be PC/EC for money: refuse during a partition, and pay the commit wait the rest of the time. It can be PA/EL for statements. The design keeps both by sending each read to the right server, not by picking one setting for the whole database.

### A sharding plan by customer ID

One server holds Portfolio 2's million ledger rows easily, so this is a plan for growth, not something Proclus needs today. The shard key would be `customer_id`, hashed so that new customers spread across all shards instead of filling the newest one. Everything that belongs to one customer lives on that customer's shard:

| Table | Where it lives | Change needed |
| --- | --- | --- |
| `customers`, `kyc_documents`, `beneficiaries`, `wallets` | The customer's shard | None: each already carries `customer_id` |
| `transactions` | The wallet owner's shard | Add `customer_id`, copied from the wallet, so that the ledger can be routed without a join |
| `transfers` | The sender's shard | Its credit leg in `transactions` lives on the receiver's shard |
| `merchants` | A copy on every shard | Small (500 rows in Portfolio 2) and rarely changed, so merchant payments stay on one shard |
| `audit_log` | The shard of the customer it concerns | Staff actions on a merchant go to a small central log |

The Portfolio 2 queries then fall into three groups:

- **One shard.** Q1 (statement) and Q5 (running balance) read one wallet. So do the balance check, KYC verification, saving a beneficiary, funding a wallet and paying a merchant. These are most of the traffic, and they scale with the number of shards.
- **Every shard, then merged.** Q2 (monthly totals): each shard sums its own rows and a coordinator adds the partial sums. Q4 (inactive customers), Q6 (large senders) and Q7 (pending queue): each customer lives on one shard, so each shard can return its own top 20 or 25 and the coordinator takes the best of those. Q3 (top merchants) is the trap. A merchant is paid by customers on every shard, so a merchant who is 11th on every shard can be 1st overall. Each shard must return its total for every merchant, and only the coordinator applies `LIMIT 10`.
- **Not routable.** Q8, the log-in look-up by email, has no `customer_id`, so it would have to ask every shard. Login is too frequent for that, so it needs a small global table from `lower(email)` (and phone number) to `customer_id`.

What sharding breaks:

- **Transfers between shards.** With 4 shards, two random customers are on different shards 3 times in 4. Debiting one shard and crediting another is no longer one PostgreSQL transaction. Two-phase commit (`PREPARE TRANSACTION`) can make it atomic, but a coordinator that fails between the two phases leaves both wallets locked. The other way uses the statuses the schema already has. Debit the sender and record the transfer as `pending` on the sender's shard. Credit the receiver on the other shard, keyed by the transfer's unique `reference` so a retry cannot credit twice. Then mark it `completed`, or credit the sender back and mark it `reversed` with a `failure_reason`. This is the case study's "reverse a failed transfer" operation, and Portfolio 2's Q7 queue is where stuck ones would show.
- **Constraints across shards.** A `UNIQUE` index only checks its own shard, so unique email, phone number, BVN or NIN, `wallet_number` and `reference` all need the global look-up table or values that include the shard. The foreign keys from `transfers.receiver_wallet_id` and `beneficiaries.wallet_id` to another customer's wallet cannot be checked by the database, so the application must check them.
- **Ids.** Each shard's identity columns would hand out the same numbers. Ids need a range per shard, or a shard number built into the id.

### Hosting Proclus on a managed cloud database

A managed PostgreSQL service (for example Amazon RDS for PostgreSQL, Azure Database for PostgreSQL or Google Cloud SQL), or Atlas on the MongoDB side, does most of what I did by hand:

| What I did by hand | What the managed service does |
| --- | --- |
| Created `replicator`, edited `pg_hba.conf`, ran `pg_basebackup -R` with a slot | Adds a read replica on request |
| Chose async, and would set `synchronous_standby_names` for money | Offers a high-availability standby in another availability zone, kept in sync, and separate async read replicas |
| Crashed the primary, ran `pg_ctl promote`, and had to keep the old primary down myself (06) | Detects the failure, promotes the standby, moves the database's address to it and replaces the old server, so the application reconnects to the same name |
| Rebuilt the replica after the drill | Rebuilds standbys and replicas itself |
| Had no backups beyond the replica | Takes automated backups with point-in-time recovery, which the replica cannot give: a mistaken `DELETE` is replayed on every replica |

For Proclus I would run:

- **A primary with a synchronous standby in a second availability zone.** Transfers, payments, balances and KYC changes go here.
- **One or two async read replicas.** Statements, monthly reports and the compliance queries (Portfolio 2's Q2, Q3 and Q6) go here, through the replicas' own address. The service publishes replica lag as a metric. If it passes a few seconds, the application sends statements to the primary, or labels them with their "as at" time.
- **A replica in a second region**, for disaster recovery if the whole region fails. It is asynchronous, so a regional failover could lose the last few seconds of transfers. That should be a written decision, not a surprise.
- **The application in the same region as the database.** Every synchronous commit pays the round trip to the standby, so the application should not add a long trip on top. The Atlas cluster is in Cape Town (`AF_SOUTH_1`). Nigerian rules on where customers' financial and personal data may be stored would have to be checked with the compliance officers before choosing a region.

What a managed service takes away: there is no superuser, no `pg_hba.conf` and no `pg_ctl`. Access is set through the provider's network rules and parameter settings, and a failover is tested with the provider's "fail over" action rather than by crashing the server. A standby and each replica are full servers, paid for even though the standby serves no reads. When Proclus outgrows one primary, the same route continues: a managed distributed PostgreSQL service, or a sharded Atlas cluster (dedicated tiers only; M0 cannot shard), using the plan above.

## Challenges and decisions

- **A second instance, not a container.** Docker was dropped in Phase 0, so the replica is a second data folder run by the same PostgreSQL 18.6 binaries with `pg_ctl`. It runs under my own account, not as a Windows service, so it has to be started again after a reboot (setup-replica.md, "Day to day").
- **A dedicated replication role.** The installer's `pg_hba.conf` already allowed replication from localhost for any role with the replication privilege, including `postgres`. I created `replicator` with only that privilege and narrowed the three rules to it, so the password the replica stores is not the superuser's. I also kept the password out of the replica's config files: `pg_basebackup` was run with the password in `pgpass.conf`, so the generated `primary_conninfo` names the file instead.
- **A replication slot, and its cost.** With the slot, the primary keeps any WAL the replica has not confirmed, so a replica that was stopped can catch up instead of needing a new base backup. The risk is the opposite: a replica left stopped makes WAL pile up on the primary. setup-replica.md shows how to check the retained size, and says to drop the slot whenever the replica is removed.
- **Demonstrating a stale read on purpose.** On a quiet laptop the replica applies a commit within a few milliseconds, so a stale read cannot be caught by timing alone. Pausing replay makes the replica behind on every run, and `pg_last_wal_receive_lsn()` against `pg_last_wal_replay_lsn()` shows that the WAL had arrived but was not yet applied.
- **Testing errors on a read-only server.** Portfolio 1's constraint tests used `pg_temp.expect_error`, but a standby cannot create even a temporary function. Test 03 runs each write with `ON_ERROR_STOP` off and prints psql's `LAST_ERROR_SQLSTATE` after it. `BEGIN READ WRITE` turned out to fail with a different code (0A000, feature not supported) from all the others (25006).
- **A 10-second stall on the replica.** The first full run of 02 failed: the replica did not reach the funding's commit within the 10 s the script allowed. That run started right after the first lag test, so the rebuild began by dropping Portfolio 2's large tables, while the replica was in the middle of a restartpoint (its version of a checkpoint). The next lag run's first sample showed `replay_lag` of 10.2 s with 0 bytes behind: the replica had fallen about 10 s behind and then caught up. I could not reproduce it: the same rebuild, run straight afterwards, replayed in 2 ms. I raised the wait to 60 s and made the script print how long it actually waited, so a slow replica shows up in the log instead of failing the test.
- **Two sessions for the lag test.** Lag only appears while the primary is writing, and one psql session cannot load data and sample the lag at the same time. As in Portfolio 3, a PowerShell runner starts two psql processes. The load connects with `application_name = p5_lag_load`, which is how the sampler knows when it starts and ends. The runner is the one non-SQL file in `tests/`.
- **Portfolio 2's seed as the load.** I used Portfolio 2's seed rather than an artificial write loop. It is a real Proclus batch job (about a million ledger rows in one transaction), it was already tested, and it leaves both servers with the large data set, ready for the failover drill.
- **A replica that could not log in.** On 4 November the replica would not reconnect after the laptop restarted. Every 5 seconds it logged `password authentication failed for user "replicator"`, although `pgpass.conf` held the right password. I had started it from a shell where `PGPASSWORD` held the `postgres` password. The replica inherits its environment, and libpq uses that variable before `pgpass.conf`. I restarted the replica from a shell without the variable, and setup-replica.md now says to keep it unset for Steps 5 to 7.
- **Crashing a Windows service.** The primary runs as the service `postgresql-x64-18` under NetworkService, and my account may not stop it without administrator rights. The runner starts `pg_ctl stop -m immediate` with `-Verb RunAs`, so Windows asks once through UAC. I chose `-m immediate` over `Stop-Service` because a clean shutdown sends the replica every last WAL record before stopping, which would hide what a real crash risks.
- **Timing the outage honestly.** The first drill reported 10.5 s without writes, but that included the seconds the UAC prompt waited for my click. The runner now takes the crash time when the elevated `pg_ctl` returns. I rebuilt the replica and ran the drill again: 5.0 s. A third run on 5 November, for the screenshot, gave 5.0 s again; the log is from that run.
- **Getting back to normal.** After the drill there were two ways back: keep port 5433 as the primary and rewind port 5432 into its replica, or restart port 5432 and rebuild port 5433. The first is the production answer. I chose the second because every portfolio's scripts use port 5432 and the guide only asks for the drill itself. The cost is that the refund written on timeline 2 was discarded, which test 06 records first.
- **What the free Atlas tier allows.** I first probed the M0 cluster from a scratch script. `rs.status()`, `hello` and direct connections to each member work. `rs.conf()` and the replication details in the `local` database are refused (`Unauthorized`), and the free tier offers no failover test or sharding. So the evidence uses what M0 allows: member states and optimes from `rs.status()`, each member's own `hello`, and `explain().serverInfo.host` to show which member answered a read.
- **Writing to Portfolio 4's data.** The Atlas test adds a real funding, like the local test 02, rather than writing to a scratch collection. Running Portfolio 4's seed first would have wiped the larger data that its `04_aggregations.js` needs. Instead the script removes its own funding and audit entries from any earlier run, in one transaction, so every run starts from the same balance and Portfolio 4's other documents are untouched.
- **Proving which member answered.** A read with `readPref('secondary')` does not say where it went. Its `explain()` does, in `serverInfo.host`, which the script compares with the members' states from `rs.status()`.

## References

- PostgreSQL Global Development Group. *PostgreSQL 18 Documentation*: chapter "High Availability, Load Balancing, and Replication" (log-shipping standby servers, streaming replication, replication slots, synchronous replication, failover, hot standby), the `pg_basebackup`, `pg_ctl` and `pg_rewind` reference pages, the replication and write-ahead log server settings (`synchronous_standby_names`, `synchronous_commit`), the `pg_stat_replication` and `pg_stat_wal_receiver` views, and the recovery control functions (`pg_wal_replay_pause`). https://www.postgresql.org/docs/18/high-availability.html
- MongoDB, Inc. *MongoDB Manual* (version 8.0): replication, write concern, read preference, read concern and causal consistency. https://www.mongodb.com/docs/manual/replication/
- MongoDB, Inc. *MongoDB Atlas Documentation*: free cluster (M0) limits. https://www.mongodb.com/docs/atlas/
- Brewer, E. A. (2000). Towards robust distributed systems. Keynote at the *19th ACM Symposium on Principles of Distributed Computing (PODC)*, Portland, Oregon.
- Gilbert, S. and Lynch, N. (2002). Brewer's conjecture and the feasibility of consistent, available, partition-tolerant web services. *ACM SIGACT News*, 33(2), 51-59.
- Abadi, D. J. (2012). Consistency tradeoffs in modern distributed database system design: CAP is only part of the story. *Computer*, 45(2), 37-42.
- Elmasri, R. and Navathe, S. B. (2016). *Fundamentals of Database Systems* (7th ed.). Pearson. Chapter on distributed database concepts.
- Silberschatz, A., Korth, H. F. and Sudarshan, S. (2020). *Database System Concepts* (7th ed.). McGraw-Hill. Chapters on parallel and distributed storage and distributed transaction processing.
