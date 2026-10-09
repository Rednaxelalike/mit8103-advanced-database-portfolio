# Portfolio 1: Database design and modelling

## Objective

This portfolio designs the relational database behind Proclus, a simulated Lagos digital wallet, and builds it in PostgreSQL. It shows an ER model with cardinalities, a schema with deliberate keys and constraints, normalisation to BCNF, and tests proving that every constraint rejects the bad data it was written to stop.

## Environment

- PostgreSQL 18.6, local Windows install, `localhost:5432`, database `proclus`, user `postgres`. Install and connection steps are in [SETUP.md](../SETUP.md).
- `psql` runs the scripts. The screenshots show `psql` in a Windows console; the title bar names the database and server.
- draw.io desktop 32.4.1 draws the ERD. The `.drawio` file also opens at app.diagrams.net.

## How to run

1. Start PostgreSQL and load `PGPASSWORD` from `.env` as described in SETUP.md.
2. From the repo root, run the scripts in order:

   ```
   psql -w -U postgres -h localhost -p 5432 -d proclus -v ON_ERROR_STOP=1 -f portfolio-1-database-design/sql/01_schema.sql
   psql -w -U postgres -h localhost -p 5432 -d proclus -v ON_ERROR_STOP=1 -f portfolio-1-database-design/sql/02_sample_data.sql
   psql -w -U postgres -h localhost -p 5432 -d proclus -v ON_ERROR_STOP=1 -f portfolio-1-database-design/sql/03_constraint_tests.sql
   ```

Every script can be run again at any time. `01` drops and recreates the eight tables, `02` empties them and reloads, and `03` changes nothing.

## What I did

1. Wrote the case study statement with its five required elements, the business rules, the entities and the relationships with their cardinalities: [case-study.md](case-study.md).
2. Drew a crow's-foot ERD of all eight tables, with keys, types, nullability, and each relationship's `ON DELETE` rule: [erd/erd.png](erd/erd.png), editable source [erd/erd.drawio](erd/erd.drawio).
3. Built the schema in [sql/01_schema.sql](sql/01_schema.sql), with these design choices:
   - BIGINT identity primary keys, with natural keys kept as UNIQUE candidate keys.
   - Foreign keys with a chosen `ON DELETE` rule each.
   - `NOT NULL` and named `CHECK` constraints for amounts, the balance, value sets, formats and status consistency.
   - `NUMERIC(14,2)` for money, `TIMESTAMPTZ` for times, and defaults for status and timestamps.
4. Normalised the design from one flat export through 1NF, 2NF and 3NF, then checked every table for BCNF, in [normalisation.md](normalisation.md). The stored wallet balance is named as a deliberate denormalisation and justified there.
5. Loaded fictional sample data in [sql/02_sample_data.sql](sql/02_sample_data.sql), using Nigerian names and naira amounts from August to October 2026. Before it commits, the script audits every wallet balance against the ledger and every transfer against its ledger rows. Any mismatch aborts the load.
6. Wrote 29 constraint tests plus a cascade check in [sql/03_constraint_tests.sql](sql/03_constraint_tests.sql). Each test names the error code it expects, and the script stops if a bad statement is ever accepted.
7. Saved the terminal output of all three scripts in [logs/](logs/).

| Table | Rows |
| --- | --- |
| customers | 20 |
| merchants | 12 |
| kyc_documents | 31 |
| wallets | 25 |
| transfers | 12 |
| transactions | 47 |
| beneficiaries | 18 |
| audit_log | 37 |

## Evidence

| Evidence | File | What it shows |
| --- | --- | --- |
| ER diagram | [erd/erd.png](erd/erd.png) | All eight entities with attributes, keys and crow's-foot cardinalities. Each relationship is labelled with its `ON DELETE` rule. |
| Schema build log | [logs/01_schema_output.txt](logs/01_schema_output.txt) | The schema builds from scratch with no errors: eight tables, all constraints, in one transaction. |
| Sample data log | [logs/02_sample_data_output.txt](logs/02_sample_data_output.txt) | The load commits only after both audits pass. All 25 balances equal their ledger totals, and all 18 transfer legs match their transfers. |
| Constraint test log | [logs/03_constraint_tests_output.txt](logs/03_constraint_tests_output.txt) | All 29 bad statements are rejected with the expected error and constraint name. The cascade check removes a deleted customer's KYC document and beneficiary. The data is unchanged afterwards. |
| Screenshot | [screenshots/p1-01-tables-created.png](screenshots/p1-01-tables-created.png) | `01_schema.sql` run from scratch: eight `CREATE TABLE` statements and `COMMIT`, with no errors. `\dt+` then lists the eight tables with the descriptions stored by `COMMENT ON TABLE`. |
| Screenshot | [screenshots/p1-02-sample-data-loaded.png](screenshots/p1-02-sample-data-loaded.png) | `02_sample_data.sql` loading the sample rows. The balance and transfer audits pass before `COMMIT`, and the final table gives the row count of each table. |
| Screenshot | [screenshots/p1-03-constraint-tests.png](screenshots/p1-03-constraint-tests.png) | `03_constraint_tests.sql`: all 29 bad statements rejected, each next to PostgreSQL's own error naming the constraint. Below them, the cascade check removes the KYC document and beneficiary of a deleted customer, and the data is unchanged at the end. |
| Screenshot | [screenshots/p1-04-overdraft-rejected.png](screenshots/p1-04-overdraft-rejected.png) | Wallet 2 holds NGN 23,500.00. A direct debit of NGN 50,000.00 is refused by `wallets_balance_non_negative`; the failing row shows the balance would have been -26,500.00. The balance is unchanged afterwards. |
| Screenshot | [screenshots/p1-05-restrict-delete-rejected.png](screenshots/p1-05-restrict-delete-rejected.png) | Customer 1 owns wallets 1 and 21. Deleting the customer is refused by the `ON DELETE RESTRICT` rule on `wallets_customer_fk`, and the customer still exists afterwards. |

## Analysis

**Each foreign key has the `ON DELETE` rule its data needs.**

- **RESTRICT protects financial history.** It applies to wallets under customers, to transfers and ledger rows under wallets, and to ledger rows under transfers and merchants. Money records must outlive the customer relationship, so accounts are closed through `status` instead of deleted. Tests T27 to T29 show these deletes rejected.
- **CASCADE covers data that belongs to its parent and means nothing alone.** It applies to KYC documents and saved beneficiaries. A customer row can only be deleted when no wallet exists, for example an abandoned sign-up. Their documents and shortcuts should then go too. Part 2 of the test script shows this happening.
- **The audit log has no foreign keys at all.** Its rows must survive even if the row they describe is removed.

**Money is `NUMERIC(14,2)`, never `FLOAT`.** A binary float cannot store 0.10 exactly, so kobo amounts drift when summed. `NUMERIC` is exact decimal. Test T16 shows that an amount too large for the column is rejected, not silently rounded.

**Constraints carry the business rules, and their names make errors readable.** A ledger row must name a merchant if and only if it is a merchant payment (`transactions_merchant_link`). It must name a transfer if and only if it is a transfer leg or reversal (`transactions_transfer_link`). A KYC document is either unreviewed, or reviewed with both reviewer and time recorded. Fixed value sets use `CHECK` instead of `ENUM` types, so the error names the rule broken and a value can be added with `ALTER TABLE`.

**The design is in BCNF.** The closest call is `beneficiaries`, which has two overlapping composite keys. The full argument is in [normalisation.md](normalisation.md). The one deliberate redundancy is the stored `wallets.balance`. It is kept because a balance check is one row read, and because `CHECK (balance >= 0)` lets the database itself refuse an overdraft (test T01). The balance audit in `02_sample_data.sql` keeps it honest, and Portfolio 3 protects it under concurrent transfers.

**Two behaviours of PostgreSQL 18 showed up in testing.**

- An `ON DELETE RESTRICT` breach is reported as SQLSTATE `23001 restrict_violation`, with the message "violates RESTRICT setting of foreign key constraint". The default `NO ACTION` rule reports `23503 foreign_key_violation`. I first expected `23503` for all foreign-key errors, and the test harness caught the difference.
- Rejected inserts still use up identity values. After the test script ran twice, the customer id counter stood at 30, although the highest stored id is 20. Gaps in surrogate keys are normal and harmless. The ids carry no meaning, which is one reason natural keys stay separate.

## Challenges and decisions

- **`audit_log` failed 3NF in my first draft.** Actions such as `kyc_verified` always went with one entity type, so `action → entity_type` held. I changed the actions to plain verbs shared across entity types, and the sample data now proves the dependency does not hold. Details are in section 6 of [normalisation.md](normalisation.md).
- **No staff table.** Compliance officers and support staff are database users, but their accounts live in the Proclus staff directory, outside this database. `kyc_documents.reviewed_by` and `audit_log.actor_ref` store the staff username as it was at the time. A staff table could be added later without changing the other tables.
- **The 18+ age rule is not a constraint.** PostgreSQL treats `CHECK` expressions as immutable, so a check against `CURRENT_DATE` would not be re-evaluated as time passes. The onboarding operation enforces the age rule. The database only rejects impossible birth dates.
- **Email uniqueness is case-sensitive.** `UNIQUE (email)` treats `Ada@example.com` and `ada@example.com` as different values. Portfolio 2 plans an expression index on `lower(email)` for look-ups. A unique version of that index would close the gap.
- **Utility bills are keyed by the bill's own reference number,** so the `(document_type, document_number)` key holds for them too. Two people in one house each submit their own bill.
- **Sample data consistency.** The 47 ledger rows were planned as dated events and replayed in order to get each wallet's balance. The script then re-checks every balance inside the database before committing, so the data cannot be loaded in an inconsistent state.
- **A `logs/` folder was added** to keep the captured terminal output as text, as the working rules ask. The guide's folder list for Portfolio 1 does not name one.
- **draw.io desktop was installed** with `winget install --id JGraph.Draw --scope user`, so the PNG is exported from the committed `.drawio` source and the two always match.

## References

- PostgreSQL Global Development Group. *PostgreSQL 18 Documentation*: section 5.5 "Constraints", section 5.3 "Identity Columns", section 8.1 "Numeric Types", and Appendix A "PostgreSQL Error Codes". https://www.postgresql.org/docs/18/
- Elmasri, R. and Navathe, S. B. (2016). *Fundamentals of Database Systems* (7th ed.). Pearson.
- Silberschatz, A., Korth, H. F. and Sudarshan, S. (2020). *Database System Concepts* (7th ed.). McGraw-Hill.
- Central Bank of Nigeria (2013). *Circular on the Three-Tiered Know-Your-Customer (KYC) Requirements*. Used for the tier 1 to 3 model.
- JGraph Ltd. *draw.io desktop*. https://github.com/jgraph/drawio-desktop
