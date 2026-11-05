# MIT 8103 Advanced Database Systems: practical portfolio

- **Student:** Ogunyemi Alexander Babalola (Student ID: 301920649)
- **Course:** MIT 8103 Advanced Database Systems, MIVA Open University, 2026/2027 first-semester continuous assessment
- **Case study:** Proclus, a simulated Lagos-based digital wallet

## Case study

Proclus is a simulated mobile wallet based in Lagos. Customers hold naira, pay merchants and send money to other wallets. The database serves customers, merchants, customer-support staff, compliance officers and administrators. It stores customers and their KYC documents, wallets and balances, transactions and transfers, merchants, saved beneficiaries and an audit log. Its key operations are: open a wallet, verify KYC, fund a wallet, transfer between wallets, pay a merchant, reverse a failed transfer, generate a statement and audit balances. The same organisation, entities and names are used in all five portfolios.

## Tech stack

| Tool | Used for |
| --- | --- |
| PostgreSQL (Windows installer, with pgAdmin and `psql`) | Portfolios 1, 2, 3 and 5, local primary on port 5432 |
| Second PostgreSQL instance on port 5433 | Portfolio 5 streaming replica and failover drill |
| MongoDB Atlas free cluster, with Compass and `mongosh` | Portfolio 4, and the cloud replica-set evidence in Portfolio 5 |
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
3. Create the `proclus` database (see SETUP.md), then run each portfolio's scripts in numbered order, following the "How to run" section of that portfolio's README.

## References

- PostgreSQL Global Development Group. *PostgreSQL Documentation*. https://www.postgresql.org/docs/
- MongoDB, Inc. *MongoDB Manual* and *MongoDB Atlas Documentation*. https://www.mongodb.com/docs/

Further references are added as each portfolio uses them.
