# Setup

Everything in this portfolio runs on two databases: PostgreSQL installed directly on the laptop (Portfolios 1, 2, 3 and 5) and a MongoDB Atlas free cluster in the cloud (Portfolio 4, plus the replica-set evidence in Portfolio 5). Docker is not used: the concurrency demos only need two `psql` windows, and the Phase 5 replica is a second PostgreSQL instance on another port.

## Versions

| Component | Version | Where it runs |
| --- | --- | --- |
| PostgreSQL primary | 18.6 (EDB installer 18.6-5, installed unattended through winget on 2026-10-07) | `localhost:5432`, Windows service `postgresql-x64-18`, data in `C:\Program Files\PostgreSQL\18\data` |
| PostgreSQL replica (Portfolio 5 only) | same binaries, second data folder | `localhost:5433` |
| pgAdmin 4 | 9.18, bundled with the PostgreSQL installer | local |
| `psql`, `pg_ctl`, `pg_basebackup` | bundled with the PostgreSQL installer, in `C:\Program Files\PostgreSQL\18\bin` | local |
| MongoDB Atlas | M0 free cluster `proclus-cluster`, MongoDB 8.0.34, three-member replica set (AWS, one region) | cloud |
| MongoDB Compass | 1.52.0 | local |
| `mongosh` | 2.12.0 (per-user install at `%LOCALAPPDATA%\Programs\mongosh`) | local |
| DBeaver Community (optional) | 26.2.0 | local |
| Git | 2.55.0 | local |

## PostgreSQL (local, port 5432)

Either path gives the same software: the EDB installer from postgresql.org, run by hand or driven unattended by winget.

**By hand.** Download the Windows installer from https://www.postgresql.org/download/windows/ and run it. Choose the components **PostgreSQL Server**, **pgAdmin 4** and **Command Line Tools** (Stack Builder is not needed), keep the default install and data directories, set a password for the `postgres` superuser and write it down, keep port **5432** and the default locale.

**Unattended (what was used on this laptop).** From PowerShell, with the password you want in place of `<password>` (letters and digits only; the installer fails silently on `"`, `<` or `>`). The command runs the same EDB installer with no wizard; Windows shows one UAC prompt.

```
winget install --id PostgreSQL.PostgreSQL.18 --exact --source winget --accept-package-agreements --accept-source-agreements --disable-interactivity --override '--mode unattended --unattendedmodeui none --superpassword <password> --serverport 5432 --disable-components stackbuilder'
```

Note the single quotes around the `--override` string. A plain `winget install PostgreSQL.PostgreSQL.18` without `--override` sets the superuser password to `postgres`. The installer writes its log to `%TEMP%\install-postgresql.log`, which contains the password, so delete it after a successful install.

After installing, whichever way:

1. The installer does not touch `PATH`. Add the `bin` folder to your user `PATH`, then open a new terminal:

   ```
   [Environment]::SetEnvironmentVariable('Path', [Environment]::GetEnvironmentVariable('Path','User') + ';C:\Program Files\PostgreSQL\18\bin', 'User')
   ```

2. Check it works. `psql` prompts for the password; to run without a prompt set `PGPASSWORD` first (single quotes in PowerShell) and add `-w` so a wrong password fails instead of hanging:

   ```
   psql --version
   Get-Service postgresql-x64-18
   $env:PGPASSWORD = '<password>'
   psql -w -U postgres -h localhost -p 5432 -c "SELECT version();"
   ```

3. Create the portfolio database once. All scripts run against it as the `postgres` user:

   ```
   psql -w -U postgres -h localhost -p 5432 -c "CREATE DATABASE proclus;"
   ```

4. Open pgAdmin 4 (Start menu). It asks for a master password on first launch; set one. Then register the server as `Proclus local` with host `localhost`, port `5432`, user `postgres` and the password from `.env`. pgAdmin is used for readable screenshots of queries, results and plans.

## MongoDB Atlas (cloud)

1. Sign in at https://cloud.mongodb.com and create a free **M0** cluster. Name it `proclus-cluster` and choose the region nearest Lagos.
2. **Database Access** → Add New Database User → authentication by password → role *Read and write to any database*. Write the password down. If it contains any of `$ : / ? # [ ] @`, percent-encode it in the connection string.
3. **Network Access** → Add IP Address → *Add Current IP Address*. Re-add it whenever your internet connection's IP changes.
4. **Connect** → *Drivers* (or *Shell*) → copy the connection string. It looks like `mongodb+srv://<db_user>:<db_password>@proclus-cluster.xxxxx.mongodb.net/`. Put it in `.env` as `MONGODB_URI`, with `/proclus` as the database name at the end.
5. Open MongoDB Compass (already installed) and connect with the same string; save the connection. The **Databases** view and the cluster's replica-set members are the Portfolio 4 and 5 screenshots.
6. `mongosh` runs the scripts from the terminal. It was installed per user, with no UAC prompt, by:

   ```
   winget install --id MongoDB.Shell --exact --accept-source-agreements --accept-package-agreements --disable-interactivity
   ```

   Open a new terminal before `mongosh --version` works.

## Ports

| Port | Service |
| --- | --- |
| 5432 | PostgreSQL primary (Portfolios 1, 2, 3 and 5) |
| 5433 | PostgreSQL streaming replica (Portfolio 5; created in Phase 5, see `portfolio-5-distributed-cloud/setup-replica.md`) |
| outbound 27017 to `*.mongodb.net` | MongoDB Atlas cluster (Portfolio 4 and 5); the `mongodb+srv` string resolves the hosts through DNS |

## Secrets

Copy `.env.example` to `.env` and fill in the PostgreSQL password and the Atlas connection string. `.env` is listed in `.gitignore` and is never committed. The scripts never embed passwords.

Load a value from `.env` into the current shell without a parser (the Atlas string may contain `&`, which breaks `source .env` in Git Bash):

```
# PowerShell
$env:PGPASSWORD  = (Get-Content .env | Where-Object { $_ -like 'PGPASSWORD=*' })  -replace '^PGPASSWORD=',''
$env:MONGODB_URI = (Get-Content .env | Where-Object { $_ -like 'MONGODB_URI=*' }) -replace '^MONGODB_URI=',''

# Git Bash
export PGPASSWORD="$(grep '^PGPASSWORD=' .env | cut -d= -f2-)"
export MONGODB_URI="$(grep '^MONGODB_URI=' .env | cut -d= -f2-)"
```

## Running the scripts

Each portfolio's README lists its scripts in order. From the repo root, with `PGPASSWORD` loaded as above:

```
psql -w -U postgres -h localhost -p 5432 -d proclus -f portfolio-1-database-design/sql/01_schema.sql
```

For Atlas, run a script with `mongosh` against the connection string loaded from `.env`:

```
# PowerShell
mongosh "$env:MONGODB_URI" --file portfolio-4-nosql/scripts/01_seed.js

# Git Bash
mongosh "$MONGODB_URI" --file portfolio-4-nosql/scripts/01_seed.js
```

Phase 0 is done when `psql` and pgAdmin both connect to the `proclus` database on port 5432, and Compass connects to the Atlas cluster.
