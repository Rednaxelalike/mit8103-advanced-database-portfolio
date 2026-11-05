# MIT 8103 Advanced Database Systems: practical portfolio

- **Student:** Ogunyemi Alexander Babalola (Student ID: 301920649)
- **Course:** MIT 8103 Advanced Database Systems, MIVA Open University, 2026/2027 first-semester continuous assessment
- **Case study:** Proclus, a simulated Lagos-based digital wallet

## Case study

Proclus is a simulated mobile wallet based in Lagos. Customers hold naira, pay merchants and send money to other wallets. The database serves customers, merchants, customer-support staff, compliance officers and administrators. It stores customers and their KYC documents, wallets and balances, transactions and transfers, merchants, saved beneficiaries and an audit log. Its key operations are: open a wallet, verify KYC, fund a wallet, transfer between wallets, pay a merchant, reverse a failed transfer, generate a statement and audit balances. The same organisation, entities and names are used in all five portfolios.

## Tech stack

| Tool | Used for |
| --- | --- |
| PostgreSQL 18.6 (Windows installer, with `psql`) | Portfolios 1, 2, 3 and 5, local primary on port 5432, database `proclus` |
| Second PostgreSQL 18.6 instance on port 5433 | Portfolio 5 streaming replica and failover drill |
| MongoDB Atlas free (M0) cluster, MongoDB 8.0.36, with `mongosh` 2.12.0 | Portfolio 4, and the cloud replica-set evidence in Portfolio 5 |
| Windows PowerShell | The runners that start two `psql` sessions at once (Portfolios 3 and 5) |
| draw.io desktop | The Portfolio 1 ER diagram (`.drawio` source and PNG) |
| Git and GitHub (private repo) | Progressive commit history as evidence |

## Portfolios

| # | Folder | Activity | Status |
| --- | --- | --- | --- |
| 1 | [portfolio-1-database-design](portfolio-1-database-design/) | Database design and modelling | Done: schema, sample data, constraint tests, ERD, normalisation and screenshots |
| 2 | [portfolio-2-query-optimisation](portfolio-2-query-optimisation/) | Query processing and optimisation | Done: million-row seed, eight queries, before and after plans, indexes with their costs, performance write-up and screenshots |
| 3 | [portfolio-3-transactions-concurrency](portfolio-3-transactions-concurrency/) | Transactions and concurrency | Done: commit/rollback, savepoints, the lost update with its three fixes, the non-repeatable read, the deadlock with its fix, and side-by-side screenshots |
| 4 | [portfolio-4-nosql](portfolio-4-nosql/) | NoSQL and advanced data models | Done: document model with validators, seed tests, CRUD with multi-document transactions, indexes with explain before and after, aggregations, comparison with PostgreSQL, and screenshots |
| 5 | [portfolio-5-distributed-cloud](portfolio-5-distributed-cloud/) | Distributed and cloud database exercise | Done: streaming replica on port 5433 with status, write, read-only and lag tests; failover drill with the split brain it leaves; Atlas replica set with majority write and secondary read; discussion of synchronous replication, CAP/PACELC, sharding and managed cloud hosting; and screenshots |

## Quick start

1. Install PostgreSQL and connect to the Atlas cluster as described in [SETUP.md](SETUP.md).
2. Copy `.env.example` to `.env` and fill in the PostgreSQL password and the Atlas connection string. `.env` is never committed.
3. Create the `proclus` database (see SETUP.md), then run each portfolio's scripts in numbered order, following the "How to run" section of that portfolio's README. All commands run from the repo root.
4. Run the portfolios in order, 1 to 5:
   - **Portfolio 1:** `sql/01_schema.sql`, `02_sample_data.sql`, `03_constraint_tests.sql`.
   - **Portfolio 2:** `sql/01_seed_large.sql`, then `02_queries.sql` (plans before), `03_indexes.sql`, and `02_queries.sql` again (plans after). The seed takes two to three minutes.
   - **Portfolio 3:** `sql/01_commit_rollback.sql` and `02_savepoints.sql`, then the seven two-session scenarios with `run_two_sessions.ps1`.
   - **Portfolio 4:** on Atlas with `mongosh`: `scripts/01_seed.js`, `02_crud.js`, `03_indexes.js` (about four minutes), then `04_aggregations.js`.
   - **Portfolio 5:** build the port-5433 replica with `setup-replica.md`, then `tests/01` to `04`, the failover drill `05_failover.ps1` and `06_split_brain.sql`, rebuild the replica, and finally `07_atlas_replica_set.js` on Atlas.

Every script starts from a known state (Portfolios 2, 3 and 5 rebuild the Portfolio 1 data first; Portfolio 4 re-seeds Atlas), so each one can be run again on its own.

## Where the evidence is

Each portfolio folder has the same layout: a `README.md` with Objective, Environment, How to run, What I did, Evidence, Analysis and Challenges; the scripts (`sql/`, `scripts/` or `tests/`); the captured terminal output in `logs/` (and query plans in Portfolio 2's `plans/`); and `screenshots/`, named `p<N>-<order>-<content>.png`. Each README's Evidence table links every log and screenshot with a sentence on what it shows. Portfolio 1's `case-study.md`, `erd/` and `normalisation.md`, Portfolio 2's `results/performance.md`, Portfolio 4's `comparison.md` and Portfolio 5's `setup-replica.md` and `config/` hold the longer write-ups.

## References

Each portfolio README lists the sources it used. Together:

- PostgreSQL Global Development Group. *PostgreSQL 18 Documentation*: constraints, identity columns and numeric types (Portfolio 1); indexes, `EXPLAIN`, planner statistics and window functions (Portfolio 2); concurrency control, MVCC, transaction isolation and explicit locking (Portfolio 3); high availability and replication, `pg_basebackup`, `pg_ctl`, `pg_rewind` and the replication settings and views (Portfolio 5). https://www.postgresql.org/docs/18/
- MongoDB, Inc. *MongoDB Manual* (version 8.0): data modeling, schema validation, indexes, transactions, aggregation and explain (Portfolio 4); replication, write concern, read preference, read concern and causal consistency (Portfolio 5). https://www.mongodb.com/docs/manual/
- MongoDB, Inc. *MongoDB Atlas Documentation* and *mongosh Documentation*. https://www.mongodb.com/docs/atlas/ and https://www.mongodb.com/docs/mongodb-shell/
- Elmasri, R. and Navathe, S. B. (2016). *Fundamentals of Database Systems* (7th ed.). Pearson.
- Silberschatz, A., Korth, H. F. and Sudarshan, S. (2020). *Database System Concepts* (7th ed.). McGraw-Hill.
- Codd, E. F. (1972). Further normalization of the data base relational model. In R. Rustin (Ed.), *Data Base Systems* (pp. 33-64). Prentice-Hall.
- Brewer, E. A. (2000). Towards robust distributed systems. Keynote at the *19th ACM Symposium on Principles of Distributed Computing (PODC)*, Portland, Oregon.
- Gilbert, S. and Lynch, N. (2002). Brewer's conjecture and the feasibility of consistent, available, partition-tolerant web services. *ACM SIGACT News*, 33(2), 51-59.
- Abadi, D. J. (2012). Consistency tradeoffs in modern distributed database system design: CAP is only part of the story. *Computer*, 45(2), 37-42.
- Central Bank of Nigeria (2013). *Circular on the Three-Tiered Know-Your-Customer (KYC) Requirements*.
- JGraph Ltd. *draw.io desktop*. https://github.com/jgraph/drawio-desktop
