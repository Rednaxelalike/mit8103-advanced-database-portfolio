# Portfolio 4: NoSQL and advanced data models

> In progress. Done: the document model, its sample documents and the `$jsonSchema` validators. Still to come: the seed and CRUD scripts, indexes with `explain`, the monthly-totals aggregation, `comparison.md` and screenshots.

## Objective

This portfolio models Proclus a second time, as a MongoDB document database on Atlas, using the same entities and sample data as Portfolio 1. It argues, with Proclus's own data, where a document model fits better than the relational one and where it fits worse.

## Environment

- MongoDB Atlas M0 free cluster `proclus-cluster`, MongoDB 8.0.34, a three-member replica set on AWS. Database `proclus`. The connection string is `MONGODB_URI` in `.env`; see [SETUP.md](../SETUP.md).
- `mongosh` 2.12.0 runs the scripts, and MongoDB Compass 1.52.0 is used for the screenshots.
- PostgreSQL 18.6 on `localhost:5432` is used only by `00_export_p1_documents.sql`, which builds the documents from the Portfolio 1 tables.

## How to run

1. Load `PGPASSWORD` from `.env` as described in SETUP.md. Then, from the repo root, rebuild the documents from Portfolio 1 (optional, because the JSON files are committed):

   ```
   psql -X -w -U postgres -h localhost -p 5432 -d proclus -v ON_ERROR_STOP=1 -f portfolio-4-nosql/scripts/00_export_p1_documents.sql
   ```

   It runs the Portfolio 1 schema and sample-data scripts first, then writes one Extended JSON file per collection to [model/documents/](model/documents/).

## What I did

1. **Mapped the eight tables to six collections**, deciding for each relationship whether to embed or reference (table below).
2. **Exported the Portfolio 1 sample data as documents** with [scripts/00_export_p1_documents.sql](scripts/00_export_p1_documents.sql). Each document is built in SQL with `json_build_object` and `json_agg`. Embedded arrays come from correlated subqueries, and `json_strip_nulls` drops NULL columns. The result is 20 customers (with 31 KYC documents and 18 beneficiaries inside them), 25 wallets, 12 merchants, 12 transfers, 47 ledger entries and 37 audit entries.
3. **Wrote a `$jsonSchema` validator per collection** in [model/validators.json](model/validators.json). Each one mirrors the Portfolio 1 constraints that a single document can check (details under Analysis).

| Portfolio 1 relationship | In MongoDB | Why |
| --- | --- | --- |
| customer 1 : N kyc_documents | **Embedded** array in `customers` | The documents belong to the customer, are few (at most 3 in the sample data), are read with the profile at every KYC check, and are deleted with the customer (the `ON DELETE CASCADE` of Portfolio 1). Their fields vary by type and review state: only passports and driving licences have `expiry_date`, and only reviewed documents have `reviewed_at` and `reviewed_by`. |
| customer 1 : N beneficiaries | **Embedded** array in `customers` | A short list that the owner reads every time they start a transfer, and that means nothing without its owner. The saved destination stays a reference (`wallet_id`), because the wallet belongs to someone else. |
| customer 1 : N wallets | **Referenced** (`wallets.customer_id`) | The balance is written on every payment and is what Portfolio 3 had to protect. In its own small document, a conditional `$inc` updates it atomically without rewriting the profile. Transfers and ledger entries also point at wallets, not at customers. |
| wallet 1 : N transactions | **Referenced** (`transactions.wallet_id`) | The ledger grows without limit (about 18 entries per wallet at the median in Portfolio 2, up to 838), and a MongoDB document is capped at 16 MB. A statement reads a date range, not the whole history. |
| transfer 1 : N transactions | **Referenced**, plus a copy of `{transfer_id, reference}` in each leg | A transfer has at most three legs, but each leg is also an entry on its wallet's statement, so it lives with the ledger. The reference never changes, so copying it is safe. |
| merchant 1 : N transactions | **Referenced**, plus a snapshot `{merchant_id, business_name, category}` in each merchant payment | A statement line shows the merchant's name as it was at the time of payment, so it is printed without a `$lookup`, and the top-merchants report can group by category directly. If a merchant renames, old entries keep the old name, which is correct for a statement. |
| audit_log | Own collection | Append-only, and it points at different collections depending on `entity_type`, as in Portfolio 1. |

The primary key of every table becomes `_id` with the same number, and every other field keeps its Portfolio 1 name. So `wallets` `_id: 5` is Ibrahim Musa's wallet in both databases.

Money is stored as `Decimal128` (`NumberDecimal("300000.00")`), never as a double, for the same reason Portfolio 1 uses `NUMERIC(14,2)`. Times are UTC `Date`s; Lagos is UTC+1, so `2026-08-01 09:12+01` becomes `2026-08-01T08:12:00Z`.

## Evidence

| Evidence | File | What it shows |
| --- | --- | --- |
| Export log | [logs/00_export_p1_documents_output.txt](logs/00_export_p1_documents_output.txt) | The Portfolio 1 rebuild (balance and transfer audits pass), then one row per collection: 20 customers with 31 embedded KYC documents and 18 embedded beneficiaries, 25 wallets, 12 merchants, 12 transfers, 47 transactions and 37 audit entries. |
| Sample documents | [model/documents/](model/documents/) | One Extended JSON file per collection, one document per line. For example, customer 5 carries three KYC documents and one beneficiary; ledger entry 8 is a merchant payment with a `merchant` snapshot and no `transfer`. |
| Validators | [model/validators.json](model/validators.json) | One `$jsonSchema` per collection, plus an `$expr` rule on `transfers`. |

## Analysis

### What the validators can and cannot enforce

A `$jsonSchema` validator checks one document at a time when it is inserted or updated. It covers most of the Portfolio 1 `CHECK` constraints:
- **Types:** `Decimal128` for money, `date` for times.
- **Value sets:** `enum`s for status, type, tier and category.
- **Formats:** `pattern`s for email, phone, CAC number and wallet number.
- **Non-negative and positive amounts.**
- **No extra fields:** `additionalProperties: false`.

Rules that depend on another field use `oneOf` and `anyOf`:
- A transfer leg must carry `transfer` and no `merchant`.
- A failed transfer must have a `failure_reason`.
- A BVN or NIN must have 11 digits.
- Only passports and licences may have an expiry date.

Two rules compare two fields of the same document, which `$jsonSchema` cannot do, so `transfers` adds an `$expr` rule: sender is not the receiver, and `processed_at` is not before `created_at`.

What a validator cannot do is look at another document:
- There are no foreign keys, so nothing stops a ledger entry from pointing at wallet 999.
- There is no `ON DELETE RESTRICT`.
- There is no check that a balance equals its ledger total.

Uniqueness (email, wallet number, reference) needs unique indexes, which the seed script will create. The rest has to be done by the application, or checked afterwards with an aggregation. That is the main thing Proclus gives up compared with PostgreSQL.

## Challenges and decisions

- **Building the documents from Portfolio 1 instead of retyping them.** Copying 153 rows into a mongosh script by hand would risk small differences from Portfolio 1. The export builds every document from the Portfolio 1 tables in SQL, so both databases hold the same ids, names and amounts. The script is a `.sql` file in `scripts/`, next to the mongosh scripts, which the guide's folder list does not mention.
- **Leaving NULLs out.** A NULL column becomes an absent field (`json_strip_nulls`), not `null`. The validators can then say "this field exists only when ...", which is how the varying KYC and ledger fields are described.
- **Key order.** PostgreSQL's `jsonb` sorts object keys, so `jsonb_pretty` would put `_id` in the middle of each document. The export uses `json`, which keeps the order written, at the cost of one document per line instead of pretty-printing.
