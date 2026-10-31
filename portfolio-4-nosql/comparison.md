# Relational and document models for Proclus

Portfolio 1 models Proclus in PostgreSQL. This portfolio models it again in MongoDB, with the same entities, ids and sample data. This file compares the two on the same operations, using the evidence in [logs/](logs/) and in Portfolio 2's `plans/`.

The two ledgers differ in size and machine, so their times do not compare directly. Portfolio 2 has 1,040,093 ledger rows in PostgreSQL 18.6 on this laptop. Portfolio 4 has 227,895 ledger entries on a shared Atlas M0 server. What does compare is how each database answers the question: the plan, what it has to read, and how much code the answer takes.

## The same query in SQL and in MongoDB

### Monthly totals by type (Portfolio 2 Q2, here A1)

```sql
SELECT date_trunc('month', created_at)::date AS month,
       transaction_type,
       count(*)    AS row_count,
       sum(amount) AS total_ngn
FROM transactions
WHERE status = 'completed'
  AND created_at >= '2026-07-01 00:00+01'
  AND created_at <  '2026-10-01 00:00+01'
GROUP BY 1, 2
ORDER BY 1, 2;
```

```js
db.transactions.aggregate([
  { $match: { status: 'completed',
              created_at: { $gte: ISODate('2026-07-01T00:00:00+01:00'), $lt: ISODate('2026-10-01T00:00:00+01:00') } } },
  { $group: { _id: { month: { $dateTrunc: { date: '$created_at', unit: 'month', timezone: 'Africa/Lagos' } },
                     type: '$transaction_type' },
              row_count: { $sum: 1 }, total_ngn: { $sum: '$amount' } } },
  { $sort: { '_id.month': 1, '_id.type': 1 } }
])
```

Each SQL clause has a pipeline stage: `WHERE` is `$match`, `GROUP BY` with its aggregates is `$group`, and `ORDER BY` is `$sort`. For a single collection the two are about as easy as each other.

Both databases improved Q2 the same way: an index or statistics that let them read less. PostgreSQL went from 1,669 ms to 433 ms, once extended statistics fixed the group estimate and the sort stopped spilling to disk. MongoDB went from 3,219 ms to 176 ms with a covering index that reads no documents (`PROJECTION_COVERED`, 0 documents examined). The month must be truncated in Lagos time in both: `date_trunc` uses the session's time zone (`Africa/Lagos`), and `$dateTrunc` is given `timezone: 'Africa/Lagos'` explicitly. Without it, entries from 00:00 to 00:59 on the 1st would fall in the previous month.

### The other Portfolio 2 questions

| Operation | PostgreSQL (Portfolio 2) | MongoDB (this portfolio) | Which is easier |
| --- | --- | --- | --- |
| Customer profile with KYC documents and beneficiaries | Three tables joined, or three queries | One `findOne` on `customers` ([02_crud.js](scripts/02_crud.js) section 2) | MongoDB |
| Wallet statement (Q1) | Index Scan on `(wallet_id, created_at)`; 164 ms to 0.077 ms | `IXSCAN` on `{wallet_id, created_at}`, no `SORT`; 4 keys and 4 documents ([03_indexes.js](scripts/03_indexes.js)) | Same: one index, the same idea |
| Top merchants, last 30 days (Q3) | `JOIN merchants`, then `GROUP BY` | `$group` on the merchant snapshot in each payment, no join (A2). A `$lookup` version returns the same rows | MongoDB, because the snapshot was stored at write time |
| Inactive customers (Q4) | `NOT EXISTS`, run as a Hash Right Anti Join over 50,020 customers in 487 ms | Nested `$lookup` (customers to wallets to transactions), then `$match` on empty results (A3): 1.4 s and 3.7 s over 5,020 customers | PostgreSQL |
| Running balance (Q5b) | `sum(...) OVER (ORDER BY created_at, transaction_id ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)` | `$setWindowFields` with `window: { documents: ['unbounded', 'current'] }` (A4); ends at the stored balance | Same: a window function in both |
| Audit balances against the ledger | One `GROUP BY` joined to `wallets` | `$lookup` per wallet with a sub-pipeline (`balanceMismatches()` in [01_seed.js](scripts/01_seed.js)) | PostgreSQL |

## What gets easier with documents

- **Data that is read together is stored together.** A KYC check reads the customer, their documents and their beneficiaries. In MongoDB that is one document and one read. It is also one atomic write: verifying the BVN and raising the tier from 1 to 2 is a single `updateOne` in [02_crud.js](scripts/02_crud.js), with no transaction, where Portfolio 1 changes two tables.
- **Fields that vary by type.** The data shows how much they vary (A5 in [logs/04_aggregations_output.txt](logs/04_aggregations_output.txt)). Of 31 KYC documents, only the 3 passports and driving licences carry `expiry_date`, and submitted documents carry no `reviewed_at` or `reviewed_by`. In the ledger, 73,547 of 227,895 entries carry a `merchant` object, 114,592 carry a `transfer` object, and funding entries carry neither. Portfolio 1 needs nullable columns and `CHECK` constraints for this. Here an absent field is simply absent, and the validator's `oneOf` rules still check that each type has the right fields (seed tests 5.8-5.12).
- **Reports that avoid joins.** The merchant snapshot lets the top-merchants report and every statement line print the merchant's name without a join. Because it records the name at the time of payment, old statements stay correct if a merchant renames.
- **Scaling out.** Each customer document is self-contained, so the customers collection could be sharded by `_id` (customer id) without splitting a profile. Portfolio 5 takes this further.

## What gets harder

- **Joins.** `$lookup` works, but a nested anti-join is slow and long to write. A3 runs its inner look-ups one customer and one wallet at a time (10,043 index keys and documents examined) and took 1.4 to 3.7 s for 5,020 customers. PostgreSQL ran Q4's `NOT EXISTS` as one hash anti-join over ten times as many customers in under half a second. Reports that cut across entities are where a relational database is strongest.
- **Integrity across documents.** There are no foreign keys and no `ON DELETE RESTRICT`. Seed tests 5.24 and 5.25 show a ledger entry for wallet 999 accepted, and wallet 5 deleted while 3 entries still pointed at it. [02_crud.js](scripts/02_crud.js) has to check the ledger itself before any delete. A unique index cannot see duplicates inside one array (test 5.26), so the beneficiary check must go into the update's filter. Portfolio 1 gets all of this from the schema.
- **Multi-document transactions.** Money moves between two wallets, and every transfer writes four documents in three collections. That needs a multi-document transaction on the replica set. It must finish within 60 seconds by default, and the application must retry it on a `TransientTransactionError`. Both are code that PostgreSQL does not need.
- **Ids, and data copied into several documents.** There is no identity column, so new ids need ObjectIds or a counter document. A snapshot is a copy: if Proclus ever needed current merchant names on old payments, every copy would have to be updated, or the report would need a `$lookup` again.

## When I would use each for Proclus

Money belongs in PostgreSQL. Wallets, transfers and the ledger need constraints between rows: the balance must never be negative, every transfer leg must match its transfer, and a wallet with history cannot be deleted. They also need transactions on every write and reports that join freely. PostgreSQL gives all of this in the schema, and Portfolio 3 showed it holding under concurrent sessions. In MongoDB the same rules become application code and after-the-fact audits.

The customer profile is the part that fits documents. KYC documents vary by type, are few, are read with the profile and belong to the customer. A customer-onboarding service could keep profiles and KYC documents in MongoDB and pass the customer id to the ledger in PostgreSQL. So could an activity feed built from ledger events, which grows without limit and is only ever appended to and read back in order.

If Proclus can run only one database, it should be PostgreSQL. It can store the varying KYC fields in a `jsonb` column next to the relational ledger, and get most of the document model's flexibility while keeping the ledger's guarantees. MongoDB is the better choice if the product turns into mostly profile and content data at very large scale, where sharding by customer matters more than joins across customers.
