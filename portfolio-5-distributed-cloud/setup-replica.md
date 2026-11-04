# Setting up the port-5433 streaming replica

This page records every step used on 2 November 2026 to give the Proclus primary (PostgreSQL 18.6 on `localhost:5432`) a streaming read replica on `localhost:5433`, on the same laptop. Following it from the top rebuilds the replica from nothing. Commands are for PowerShell, run from the repo root.

| | Primary | Replica |
| --- | --- | --- |
| Port | 5432 | 5433 |
| Data folder | `C:\Program Files\PostgreSQL\18\data` (installer default) | `C:\Users\USER\pg18-replica-5433` (outside the repo) |
| Runs as | Windows service `postgresql-x64-18`, starts with Windows | a process started with `pg_ctl` under your own account |
| Role | accepts reads and writes | `pg_is_in_recovery() = t`: replays the primary's WAL and accepts reads only |
| Server log | `...\18\data\log\` | `C:\Users\USER\pg18-replica-5433\log\` (startup messages in `C:\Users\USER\pg18-replica-5433.log`) |

Both use the same PostgreSQL 18.6 binaries in `C:\Program Files\PostgreSQL\18\bin` (already on `PATH`). The files changed or generated are kept in [config/](config/).

## How it works

`pg_basebackup` copies the primary's whole data folder while the primary keeps running, and streams the WAL written during the copy so the copy is consistent. With `-R` it also writes `standby.signal` and the connection details (`primary_conninfo`) into the copy. When the copy is started, `standby.signal` makes it start as a standby: a WAL receiver process connects back to the primary as the `replicator` role, receives every new WAL record, and the startup process replays the records. The replica is therefore a byte-for-byte physical copy of the whole cluster, and it stays read-only for as long as it is in recovery.

The replica is **asynchronous**: the primary's `synchronous_standby_names` is empty, so a commit on the primary returns as soon as the primary has flushed its own WAL, without waiting for the replica.

## Before you start

1. PostgreSQL 18.6 is running on port 5432 and `PGPASSWORD` is loaded from `.env` (see [SETUP.md](../SETUP.md)):

   ```
   $env:PGPASSWORD = (Get-Content .env | Where-Object { $_ -like 'PGPASSWORD=*' }) -replace '^PGPASSWORD=',''
   ```

2. Check the primary's replication settings. The installer defaults are already enough, so **the primary's `postgresql.conf` is not changed**:

   ```
   psql -X -w -U postgres -h localhost -p 5432 -d postgres -c "SELECT name, setting FROM pg_settings WHERE name IN ('wal_level','max_wal_senders','max_replication_slots','listen_addresses');"
   ```

   Expected: `wal_level = replica` (enough WAL for a standby to replay), `max_wal_senders = 10`, `max_replication_slots = 10`, `listen_addresses = *`.

3. Port 5433 is free: `Get-NetTCPConnection -LocalPort 5433` returns nothing.

## Step 1: a password for the replication role

Add two lines to `.env` (git-ignored) with a long random password, then load it:

```
PGREPLICATION_USER=replicator
PGREPLICATION_PASSWORD=<random password>
```

```
$env:PGREPLICATION_PASSWORD = (Get-Content .env | Where-Object { $_ -like 'PGREPLICATION_PASSWORD=*' }) -replace '^PGREPLICATION_PASSWORD=',''
```

`.env.example` lists both names with placeholder values.

## Step 2: create the `replicator` role on the primary

```
psql -X -w -U postgres -h localhost -p 5432 -d postgres -v ON_ERROR_STOP=1 -v replication_password="$env:PGREPLICATION_PASSWORD" -f portfolio-5-distributed-cloud/config/primary_replication_role.sql
```

[config/primary_replication_role.sql](config/primary_replication_role.sql) creates the role `WITH LOGIN REPLICATION` if it is missing and sets its password. Expected last line: `replicator | f | t | t | t` (not a superuser, may replicate, may log in, password stored as SCRAM-SHA-256). The replica connects as this role instead of `postgres`, so the password stored for it can stream WAL but is not a superuser password.

## Step 3: allow only `replicator` to stream (primary's `pg_hba.conf`)

The installer's `pg_hba.conf` already accepts replication connections from localhost, but from **any** role with the replication privilege (including `postgres`). In the three `replication` lines at the end of `C:\Program Files\PostgreSQL\18\data\pg_hba.conf`, change the user column from `all` to `replicator`. The change is in [config/primary_pg_hba.conf.diff](config/primary_pg_hba.conf.diff):

```
local   replication     replicator                              scram-sha-256
host    replication     replicator      127.0.0.1/32            scram-sha-256
host    replication     replicator      ::1/128                 scram-sha-256
```

`pg_hba.conf` is re-read on reload, so no restart (and no administrator rights) is needed. Reload and check the rules the server now uses:

```
psql -X -w -U postgres -h localhost -p 5432 -d postgres -c "SELECT pg_reload_conf();" -c "SELECT line_number, type, database, user_name, address, auth_method, error FROM pg_hba_file_rules WHERE 'replication' = ANY (database);"
```

Expected: three rows with `user_name = {replicator}` and an empty `error` column. (Your Windows account had full control of the data folder on this laptop; if yours does not, edit the file from an editor run as administrator.)

## Step 4: store the password where the replica can find it

The replica's WAL receiver runs under your Windows account and reads libpq's password file, so the password never needs to be written into the replica's configuration:

```
New-Item -ItemType Directory -Force "$env:APPDATA\postgresql" | Out-Null
Set-Content -Path "$env:APPDATA\postgresql\pgpass.conf" -Value "localhost:5432:replication:replicator:$env:PGREPLICATION_PASSWORD" -Encoding ascii
```

The database field `replication` matches streaming-replication connections only. Check:

```
Remove-Item Env:PGPASSWORD
psql -X -w -h localhost -p 5432 -U replicator -d "dbname=replication replication=true" -c "IDENTIFY_SYSTEM;"
```

Expected: one row with the system identifier, timeline 1 and the current WAL position.

**Keep `PGPASSWORD` unset for Steps 5 to 7.** libpq uses the `PGPASSWORD` environment variable before it looks in `pgpass.conf`. A `pg_basebackup` run from a shell that holds the `postgres` password would send that password for `replicator` and fail. A replica started from such a shell is worse: it inherits the variable and keeps retrying with the wrong password, logging `password authentication failed for user "replicator"` every 5 seconds. Load `PGPASSWORD` again at Step 8.

## Step 5: copy the primary with `pg_basebackup`

```
pg_basebackup -h localhost -p 5432 -U replicator -w -D C:\Users\USER\pg18-replica-5433 -R -C -S replica_5433 -X stream -c fast -P -v
```

| Option | What it does |
| --- | --- |
| `-U replicator -w` | connect as `replicator`, password from `pgpass.conf`, never prompt |
| `-D C:\Users\USER\pg18-replica-5433` | the new data folder; it must not exist yet, and it stays outside the repo |
| `-R` | write `standby.signal` and `primary_conninfo` into the copy, so it starts as a standby |
| `-C -S replica_5433` | create a physical replication slot named `replica_5433` on the primary and record it in the copy as `primary_slot_name` |
| `-X stream` | stream the WAL written during the copy alongside it, so the copy is consistent |
| `-c fast` | ask the primary for an immediate checkpoint instead of waiting for the next one |
| `-P -v` | show progress and each stage |

On 2 November it copied 34,760 kB (the Portfolio 1 sample database) in 10.7 s and ended with `base backup completed`.

The generated `postgresql.auto.conf` is kept as [config/replica_postgresql.auto.conf](config/replica_postgresql.auto.conf). It names the `passfile`, not the password.

**About the slot.** While `replica_5433` exists, the primary keeps every WAL file the replica has not yet confirmed, even if the replica is stopped. That is what lets a replica that was down catch up instead of needing a new base backup. The cost: if the replica stays down, WAL piles up in the primary's `pg_wal` folder until the disk fills. Check how much it is holding back with:

```
psql -X -w -U postgres -h localhost -p 5432 -d postgres -c "SELECT slot_name, active, wal_status, pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained FROM pg_replication_slots;"
```

and drop the slot (`SELECT pg_drop_replication_slot('replica_5433');`) whenever the replica is removed.

## Step 6: give the copy its own port

The copy has the primary's `postgresql.conf`, so it would try to use port 5432. Edit `C:\Users\USER\pg18-replica-5433\postgresql.conf` ([config/replica_postgresql.conf.diff](config/replica_postgresql.conf.diff)):

```
port = 5433
cluster_name = 'replica_5433'
```

`cluster_name` is sent as the connection's `application_name`, so the replica appears as `replica_5433` in the primary's `pg_stat_replication`.

The copy also contains the primary's server logs from `data\log\`. They were deleted from the replica's `log` folder so its log starts clean (`Remove-Item C:\Users\USER\pg18-replica-5433\log\*`).

## Step 7: start the replica

From a shell without `PGPASSWORD` (see Step 4):

```
Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
pg_ctl -D C:\Users\USER\pg18-replica-5433 -l C:\Users\USER\pg18-replica-5433.log -w -t 60 start
```

The replica's server log (in `C:\Users\USER\pg18-replica-5433\log\`) should show, in order:

```
entering standby mode
consistent recovery state reached at 2/2A000158
database system is ready to accept read-only connections
started streaming WAL from primary at 2/2B000000 on timeline 1
```

## Step 8: check it

Load `PGPASSWORD` again (see "Before you start"), then:

```
psql -X -w -U postgres -h localhost -p 5432 -d proclus -v ON_ERROR_STOP=1 -f portfolio-5-distributed-cloud/tests/01_replication_status.sql
```

On the primary, `pg_stat_replication` shows `replica_5433 | streaming | async` and the slot is `active = t`. On the replica, `pg_is_in_recovery()` is `t`, `pg_stat_wal_receiver` shows `streaming` from `localhost:5432`, and the row counts equal the primary's. The other tests are listed in the [README](README.md).

## Day to day

The replica is not a Windows service, so it does not start with Windows. After a restart or sign-out, start it again with the Step 7 commands (`PGPASSWORD` unset); it reconnects and catches up from the slot. Other commands:

```
pg_ctl -D C:\Users\USER\pg18-replica-5433 status
pg_ctl -D C:\Users\USER\pg18-replica-5433 -m fast stop
```

If `tests/02_write_on_primary.sql` is interrupted in Part 2, replay can be left paused. Resume it with:

```
psql -X -w -U postgres -h localhost -p 5433 -d postgres -c "SELECT pg_wal_replay_resume();"
```

## Rebuilding the replica from nothing

```
pg_ctl -D C:\Users\USER\pg18-replica-5433 -m fast stop
Remove-Item -Recurse -Force C:\Users\USER\pg18-replica-5433
psql -X -w -U postgres -h localhost -p 5432 -d postgres -c "SELECT pg_drop_replication_slot('replica_5433');"
```

Then repeat Steps 5 to 8. Steps 1 to 4 only need repeating if the role, `pg_hba.conf` or `pgpass.conf` were changed.

## After the failover drill

`tests/05_failover.ps1` crashes the primary and promotes the replica, so it ends with port 5432 stopped and port 5433 a stand-alone primary on timeline 2. These steps return to the normal layout: port 5432 the primary, port 5433 its replica. They were run twice on 4 November.

1. **Start the primary's service again.** Stopping and starting a Windows service needs administrator rights, so run this from a PowerShell window opened with "Run as administrator", or accept the UAC prompt:

   ```
   Start-Process powershell.exe -ArgumentList '-NoProfile','-Command','Start-Service postgresql-x64-18' -Verb RunAs -Wait
   ```

   The server runs crash recovery (it was stopped with `-m immediate`) and comes back as a primary on timeline 1.

2. **See the split brain** (optional, only reads), while both servers are up:

   ```
   psql -X -w -U postgres -h localhost -p 5432 -d proclus -v ON_ERROR_STOP=1 -f portfolio-5-distributed-cloud/tests/06_split_brain.sql
   ```

3. **Rebuild the replica from port 5432** with the commands under "Rebuilding the replica from nothing" above, then Steps 5 to 8. This throws away port 5433's timeline 2, including the refund written there during the drill.

That choice suits a lab where port 5432 is the server every other script uses. In production the promoted server would stay the primary, because it holds the newest data, and the old primary would be turned into its replica instead. That can be done with a fresh `pg_basebackup` or, faster, with `pg_rewind`, which rewinds only the blocks that diverged. `pg_rewind` needs data checksums or `wal_log_hints`; this cluster has `data_checksums = on`.
