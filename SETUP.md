# Setup

Everything in this portfolio runs on two databases: PostgreSQL installed directly on the laptop (Portfolios 1, 2, 3 and 5) and a MongoDB Atlas free cluster in the cloud (Portfolio 4, plus the replica-set evidence in Portfolio 5). Docker is not used: the concurrency demos only need two `psql` windows, and the Phase 5 replica is a second PostgreSQL instance on another port.

## Versions

| Component | Version | Where it runs |
| --- | --- | --- |
| PostgreSQL primary | 18.x (fill in the exact number from `psql --version` after installing) | `localhost:5432` |
| PostgreSQL replica (Portfolio 5 only) | same binaries, second data folder | `localhost:5433` |
| pgAdmin 4 | bundled with the PostgreSQL installer | local |
| `psql`, `pg_ctl`, `pg_basebackup` | bundled with the PostgreSQL installer | local |
| MongoDB Atlas | M0 free cluster, three-member replica set | cloud |
| MongoDB Compass | 1.52.0 | local |
| `mongosh` | fill in from `mongosh --version` after installing | local |
| DBeaver Community (optional) | 26.2.0 | local |
| Git | 2.55.0 | local |

## PostgreSQL (local, port 5432)

1. Download the Windows installer from https://www.postgresql.org/download/windows/ (it links to the EDB installer) and run it.
2. Install the components **PostgreSQL Server**, **pgAdmin 4** and **Command Line Tools**. Stack Builder is not needed.
3. Keep the default data directory, set a password for the `postgres` superuser and write it down, keep port **5432** and the default locale.
4. Add the `bin` folder to your `PATH` so the tools work from any terminal, for example `C:\Program Files\PostgreSQL\18\bin`. Open a new terminal afterwards.
5. Check it works:

   ```
   psql --version
   psql -U postgres -h localhost -p 5432 -c "SELECT version();"
   ```

6. Create the portfolio database once. All scripts run against it as the `postgres` user:

   ```
   psql -U postgres -h localhost -p 5432 -c "CREATE DATABASE proclus;"
   ```

7. In pgAdmin, register the server as `Proclus local` with host `localhost`, port `5432`, user `postgres`. pgAdmin is used for readable screenshots of queries, results and plans.

## MongoDB Atlas (cloud)

1. Sign in at https://cloud.mongodb.com and create a free **M0** cluster. Name it `proclus-cluster` and choose the region nearest Lagos.
2. **Database Access** → Add New Database User → authentication by password → role *Read and write to any database*. Write the password down.
3. **Network Access** → Add IP Address → *Add Current IP Address*. Re-add it whenever your internet connection's IP changes.
4. **Connect** → *Drivers* (or *Shell*) → copy the connection string. It looks like `mongodb+srv://<db_user>:<db_password>@proclus-cluster.xxxxx.mongodb.net/`. Put it in `.env` as `MONGODB_URI`, with `/proclus` as the database name at the end.
5. Open MongoDB Compass (already installed) and connect with the same string. The **Databases** view and the cluster's replica-set members are the Portfolio 4 and 5 screenshots.
6. Install `mongosh` so the scripts can run from the terminal:

   ```
   winget install MongoDB.Shell
   mongosh --version
   ```

## Ports

| Port | Service |
| --- | --- |
| 5432 | PostgreSQL primary (Portfolios 1, 2, 3 and 5) |
| 5433 | PostgreSQL streaming replica (Portfolio 5; created in Phase 5, see `portfolio-5-distributed-cloud/setup-replica.md`) |
| 27017 over `mongodb+srv` | MongoDB Atlas cluster (Portfolio 4 and 5) |

## Secrets

Copy `.env.example` to `.env` and fill in the PostgreSQL password and the Atlas connection string. `.env` is listed in `.gitignore` and is never committed. The scripts never embed passwords; pass them through `.env` or type them when prompted.

## Running the scripts

Each portfolio's README lists its scripts in order. From the repo root:

```
psql -U postgres -h localhost -p 5432 -d proclus -f portfolio-1-database-design/sql/01_schema.sql
```

For Atlas, run a script with `mongosh` against the connection string from `.env`:

```
mongosh "mongodb+srv://<db_user>:<db_password>@proclus-cluster.xxxxx.mongodb.net/proclus" --file portfolio-4-nosql/scripts/01_seed.js
```

Phase 0 is done when `psql` and pgAdmin both connect to the `proclus` database on port 5432, and Compass connects to the Atlas cluster.
