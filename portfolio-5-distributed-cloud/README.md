# Portfolio 5: Distributed and cloud database exercise

> In progress. Done: the local streaming replica and tests 01-04 (2 November), the failover drill, the split-brain check and the Atlas replica-set evidence (4 November). Still to come: the discussion and screenshots.

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

## Evidence

| Evidence | File | What it shows |
| --- | --- | --- |
| Setup notes | [setup-replica.md](setup-replica.md) | Every command used to build the replica, the expected output of each step, how to start, stop and rebuild it, and what the replication slot costs. |
| Configuration | [config/](config/) | The role script; the `pg_hba.conf` change on the primary as a diff; the replica's `postgresql.conf` changes as a diff; the `postgresql.auto.conf` that `pg_basebackup -R` generated. |
| Status log | [logs/01_replication_status_output.txt](logs/01_replication_status_output.txt) | The primary: `wal_level = replica` and an empty `synchronous_standby_names`. One standby, `replicator` from `::1` as `replica_5433`, is `streaming` and `async`, 0 bytes behind, and the slot is `active`. The replica: `in_recovery = t`, `transaction_read_only = on`, and the WAL receiver is `streaming` from `localhost:5432` through slot `replica_5433`. Both servers count 20 customers, 25 wallets, 12 transfers and 47 ledger rows. |
| Write log | [logs/02_write_on_primary_output.txt](logs/02_write_on_primary_output.txt) | The funding commits on the primary at WAL position `2/80BC4520`. The replica had replayed it after a 1.3 ms wait and lists ledger row 48 with the same id. With replay paused, the payment's WAL has arrived on the replica (received `2/80BC4888`) but is not applied (replayed `2/80BC4520`, 872 bytes behind). The primary answers ₦134,549.50 and the replica ₦152,549.50. After resuming, the replica applies the payment within 1.0 ms, shows both rows, and its balance audit finds 0 mismatches in 25 wallets. |
| Read-only log | [logs/03_replica_rejects_writes_output.txt](logs/03_replica_rejects_writes_output.txt) | Reads work on port 5433. `UPDATE`, `INSERT`, `DELETE`, `SELECT ... FOR UPDATE`, `nextval()`, `CREATE TABLE`, and an `UPDATE` after `SET default_transaction_read_only = off` all fail with 25006, "cannot execute ... in a read-only transaction". `BEGIN READ WRITE` fails with 0A000, "cannot set transaction read-write mode during recovery". The balance and row counts are unchanged afterwards. |
| Lag log | [logs/04_replication_lag_output.txt](logs/04_replication_lag_output.txt) | Idle: 0 bytes behind, with write and flush lag of 0.3 ms. During the load, in 10-second windows: the WAL written, the worst bytes behind and the worst write, flush and replay lag, next to the statement the load was running. The summary row: 292 samples over the 148.1 s load, which wrote 601 MB of WAL; at most 4,096 kB behind (331 kB on average); replay lag at most 330 ms (106 ms on average); caught up 2 ms after the load's session ended. Both servers then hold 50,020 customers, 58,583 wallets, 199,051 transfers and 1,040,093 ledger rows. |
| Load log | [logs/04_load_seed_large_output.txt](logs/04_load_seed_large_output.txt) | The load itself: Portfolio 2's seed output, ending with its four audits passing and the table sizes. |
| Failover log | [logs/05_failover_output.txt](logs/05_failover_output.txt) | Timestamped steps. Stage 1: the ₦40,000 transfer commits on the primary (timeline `00000001`) and is replayed on the replica within 15.8 ms. The primary is stopped at 08:08:36.865, the service shows `Stopped`, and a connection to 5432 is refused. Stage 2: the replica has received and replayed the same position, has no WAL receiver connected, still lists Tunde's transfer, and refuses the refund with 25006. `pg_ctl promote` takes 0.4 s, and the replica's log shows `received promote request`, `selected new timeline ID: 2`, `database system is ready to accept connections`. Stage 3: `in_recovery = f`, timeline `00000002`, the ₦40,000 transfer is there, the refund commits (wallet 5 ₦275,000, wallet 9 ₦290,000), there are 0 replicas, and 0 of 25 balances mismatch. Writes were impossible for 5.0 s. |
| Split-brain log | [logs/06_split_brain_output.txt](logs/06_split_brain_output.txt) | After its service restarts, port 5432 is a primary again on timeline 1. It has the ₦40,000 transfer but not the refund: wallet 9 is ₦305,000, and its slot is inactive. Port 5433 is also a primary, on timeline 2, with the refund: wallet 9 is ₦290,000. Two servers each accepting writes, with different balances. |
| Atlas log | [logs/07_atlas_replica_set_output.txt](logs/07_atlas_replica_set_output.txt) | Replica set `atlas-100ow8-shard-0` on AWS `AF_SOUTH_1`. `rs.status()` lists three healthy members: `shard-00-02` PRIMARY, and `shard-00-00` and `shard-00-01` SECONDARY, both syncing from the primary, 1 s behind it at one-second resolution. Connected directly, only `shard-00-02` reports `isWritablePrimary true`, and a write sent to `shard-00-00` is refused with `NotWritablePrimary` (10107). The funding commits with `w: "majority"` as ledger entry 227896. `w: 3` is acknowledged. `w: 4` fails with `UnsatisfiableWriteConcern` (100), "Not enough data-bearing nodes", yet the entry is stored. The balance, ₦152,549.50, is read from the primary. The statement, read from secondary `shard-00-00`, includes the funding. All 11 checks pass. The log comes from a second run, which first removed the first run's funding and audit entries. |

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
