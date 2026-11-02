# Portfolio 5: Distributed and cloud database exercise

> In progress. Done on 2 November: the local streaming replica and tests 01-04. Still to come: the failover drill, the Atlas replica-set evidence, the discussion and screenshots.

## Objective

This portfolio replicates the Proclus database: a local PostgreSQL primary streams every change to a read replica that can serve customer statements, while balances are always read from the primary. It measures what the replica costs and risks (replication lag, stale reads, failover), and compares it with the three-member replica set behind the MongoDB Atlas cluster from Portfolio 4.

## Environment

- **Primary:** PostgreSQL 18.6 on `localhost:5432`, the Windows service `postgresql-x64-18` used by Portfolios 1-3, database `proclus`.
- **Replica:** a second PostgreSQL 18.6 instance on `localhost:5433`, built from the primary with `pg_basebackup -R` into `C:\Users\USER\pg18-replica-5433` (outside the repo) and started with `pg_ctl`. It streams WAL as the role `replicator` through the replication slot `replica_5433`, asynchronously. Every step is in [setup-replica.md](setup-replica.md).
- **Connecting:** `psql -X -w -U postgres -h localhost -p 5432 -d proclus` for the primary, `-p 5433` for the replica, with `PGPASSWORD` loaded from `.env` (see [SETUP.md](../SETUP.md)). The replica is a copy of the whole primary, so the same `postgres` password works on both.

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

## What I did

1. **Prepared the primary.** It needed no `postgresql.conf` changes: the installer's defaults (`wal_level = replica`, `max_wal_senders = 10`, `max_replication_slots = 10`) already allow streaming replication. I created a dedicated role, `replicator`, with only the `REPLICATION` attribute ([config/primary_replication_role.sql](config/primary_replication_role.sql)). I then narrowed the three `replication` lines of `pg_hba.conf` from any role to `replicator` ([config/primary_pg_hba.conf.diff](config/primary_pg_hba.conf.diff)), and reloaded the configuration without a restart.
2. **Built the replica** with `pg_basebackup -R -C -S replica_5433 -X stream`. It copied 34,760 kB in 10.7 s, wrote `standby.signal` and `primary_conninfo`, and created the replication slot. I changed the copy's port to 5433 and named it `replica_5433` ([config/replica_postgresql.conf.diff](config/replica_postgresql.conf.diff)), then started it with `pg_ctl`. The replica's password stays in `pgpass.conf`. The generated [config/replica_postgresql.auto.conf](config/replica_postgresql.auto.conf) names that file instead of holding the password.
3. **Checked the connection from both ends** with [tests/01_replication_status.sql](tests/01_replication_status.sql). It shows the primary's settings, `pg_stat_replication` and the slot, then the replica's `pg_is_in_recovery()`, `pg_stat_wal_receiver` and replay position, and the row counts on each server.
4. **Showed a write on the primary reaching the replica** with [tests/02_write_on_primary.sql](tests/02_write_on_primary.sql).
   - Chinedu Okafor funds wallet 1 with ₦50,000 on the primary. The script waits until the replica has replayed past the commit's WAL position, then reads the wallet's November statement from the replica.
   - Part 2 pauses replay on the replica with `pg_wal_replay_pause()`, to stand in for a replica that has fallen behind. Chinedu then pays Lekki Fresh Mart ₦18,000 on the primary. The replica, still paused, returns the old balance and a statement without the payment. After `pg_wal_replay_resume()` both servers agree again, and the balance audit passes on the replica.
5. **Showed that the replica refuses writes** with [tests/03_replica_rejects_writes.sql](tests/03_replica_rejects_writes.sql). It tries eight kinds of write, from an `UPDATE` of a balance to `BEGIN READ WRITE`, and prints the SQLSTATE for each.
6. **Measured replication lag** with [tests/04_replication_lag.sql](tests/04_replication_lag.sql), run by [tests/04_replication_lag.ps1](tests/04_replication_lag.ps1). First it reads `pg_stat_replication` with the primary idle. Then it samples the view every half second while Portfolio 2's seed loads about a million ledger rows in one transaction, and keeps going until the replica has replayed everything the load wrote. Finally it compares the row counts on both servers.

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

## Challenges and decisions

- **A second instance, not a container.** Docker was dropped in Phase 0, so the replica is a second data folder run by the same PostgreSQL 18.6 binaries with `pg_ctl`. It runs under my own account, not as a Windows service, so it has to be started again after a reboot (setup-replica.md, "Day to day").
- **A dedicated replication role.** The installer's `pg_hba.conf` already allowed replication from localhost for any role with the replication privilege, including `postgres`. I created `replicator` with only that privilege and narrowed the three rules to it, so the password the replica stores is not the superuser's. I also kept the password out of the replica's config files: `pg_basebackup` was run with the password in `pgpass.conf`, so the generated `primary_conninfo` names the file instead.
- **A replication slot, and its cost.** With the slot, the primary keeps any WAL the replica has not confirmed, so a replica that was stopped can catch up instead of needing a new base backup. The risk is the opposite: a replica left stopped makes WAL pile up on the primary. setup-replica.md shows how to check the retained size, and says to drop the slot whenever the replica is removed.
- **Demonstrating a stale read on purpose.** On a quiet laptop the replica applies a commit within a few milliseconds, so a stale read cannot be caught by timing alone. Pausing replay makes the replica behind on every run, and `pg_last_wal_receive_lsn()` against `pg_last_wal_replay_lsn()` shows that the WAL had arrived but was not yet applied.
- **Testing errors on a read-only server.** Portfolio 1's constraint tests used `pg_temp.expect_error`, but a standby cannot create even a temporary function. Test 03 runs each write with `ON_ERROR_STOP` off and prints psql's `LAST_ERROR_SQLSTATE` after it. `BEGIN READ WRITE` turned out to fail with a different code (0A000, feature not supported) from all the others (25006).
- **A 10-second stall on the replica.** The first full run of 02 failed: the replica did not reach the funding's commit within the 10 s the script allowed. That run started right after the first lag test, so the rebuild began by dropping Portfolio 2's large tables, while the replica was in the middle of a restartpoint (its version of a checkpoint). The next lag run's first sample showed `replay_lag` of 10.2 s with 0 bytes behind: the replica had fallen about 10 s behind and then caught up. I could not reproduce it: the same rebuild, run straight afterwards, replayed in 2 ms. I raised the wait to 60 s and made the script print how long it actually waited, so a slow replica shows up in the log instead of failing the test.
- **Two sessions for the lag test.** Lag only appears while the primary is writing, and one psql session cannot load data and sample the lag at the same time. As in Portfolio 3, a PowerShell runner starts two psql processes. The load connects with `application_name = p5_lag_load`, which is how the sampler knows when it starts and ends. The runner is the one non-SQL file in `tests/`.
- **Portfolio 2's seed as the load.** I used Portfolio 2's seed rather than an artificial write loop. It is a real Proclus batch job (about a million ledger rows in one transaction), it was already tested, and it leaves both servers with the large data set, ready for the failover drill.
