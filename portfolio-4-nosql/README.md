# Portfolio 4: NoSQL and advanced data models

## Objective

This portfolio models Proclus a second time, as a MongoDB document database on Atlas, using the same entities and sample data as Portfolio 1. It argues, with Proclus's own data, where a document model fits better than the relational one and where it fits worse.

## Environment

- MongoDB Atlas M0 free cluster `proclus-cluster`, a three-member replica set on AWS. The seed log (30 October) was captured on MongoDB 8.0.34. Atlas then upgraded the cluster to 8.0.36, which ran scripts 02-04 on 31 October. Each log's header names the version it ran on. Database `proclus`. The connection string is `MONGODB_URI` in `.env`; see [SETUP.md](../SETUP.md).
- `mongosh` 2.12.0 runs the scripts. The screenshots are its console output, captured on 1 November against MongoDB 8.0.36.
- PostgreSQL 18.6 on `localhost:5432` is used only by `00_export_p1_documents.sql`, which builds the documents from the Portfolio 1 tables.

## How to run

1. Load `PGPASSWORD` from `.env` as described in SETUP.md. Then, from the repo root, rebuild the documents from Portfolio 1 (optional, because the JSON files are committed):

   ```
   psql -X -w -U postgres -h localhost -p 5432 -d proclus -v ON_ERROR_STOP=1 -f portfolio-4-nosql/scripts/00_export_p1_documents.sql
   ```

   It runs the Portfolio 1 schema and sample-data scripts first, then writes one Extended JSON file per collection to [model/documents/](model/documents/).
2. Load `MONGODB_URI` from `.env` (SETUP.md), make sure your current IP is on the Atlas Network Access list, and build the database:

   ```
   mongosh "$MONGODB_URI" --quiet --file portfolio-4-nosql/scripts/01_seed.js
   ```

   It drops and recreates the six collections, so it can be run again at any time. It ends with `All checks passed.` and exit code 0, or exits with code 1 if any check fails.
3. Run the key operations, then the index measurements:

   ```
   mongosh "$MONGODB_URI" --quiet --file portfolio-4-nosql/scripts/02_crud.js
   mongosh "$MONGODB_URI" --quiet --file portfolio-4-nosql/scripts/03_indexes.js
   ```

   Each one runs `01_seed.js` first, so they can be run in any order and as often as needed. Each ends the same way as the seed script. `03_indexes.js` takes about four minutes, most of it spent sending about 295,000 documents to Atlas, and it leaves the larger data in place.
4. Run the aggregations, straight after `03_indexes.js`:

   ```
   mongosh "$MONGODB_URI" --quiet --file portfolio-4-nosql/scripts/04_aggregations.js
   ```

   It only reads, so it can be run any number of times. It stops with exit code 1 if the larger data from `03_indexes.js` is not there.

## What I did

1. **Mapped the eight tables to six collections**, deciding for each relationship whether to embed or reference (table below).
2. **Exported the Portfolio 1 sample data as documents** with [scripts/00_export_p1_documents.sql](scripts/00_export_p1_documents.sql). Each document is built in SQL with `json_build_object` and `json_agg`. Embedded arrays come from correlated subqueries, and `json_strip_nulls` drops NULL columns. The result is 20 customers (with 31 KYC documents and 18 beneficiaries inside them), 25 wallets, 12 merchants, 12 transfers, 47 ledger entries and 37 audit entries.
3. **Wrote a `$jsonSchema` validator per collection** in [model/validators.json](model/validators.json). Each one mirrors the Portfolio 1 constraints that a single document can check (details under Analysis).
4. **Seeded Atlas and tested the rules** with [scripts/01_seed.js](scripts/01_seed.js):
   - It creates each collection with its validator, set to check every insert and update and to reject failures (`validationLevel: "strict"`, `validationAction: "error"`).
   - It creates ten unique indexes, one for each Portfolio 1 `UNIQUE` constraint that MongoDB can enforce, with the same names. The email index is case-insensitive (collation strength 2), like Portfolio 2's unique index on `lower(email)`.
   - It loads the 153 documents and checks the counts.
   - It runs Portfolio 1's two integrity audits again, as aggregation pipelines: every balance must equal its completed ledger total, and every transfer leg must match its transfer.
   - It runs 27 tests and then repeats the counts and audits, to show the tests left the data as it was loaded.
5. **Ran the key operations** of the Portfolio 1 case study with [scripts/02_crud.js](scripts/02_crud.js), for one new customer, Adaobi Chukwu (customer 21). Every time is fixed on 31 October 2026, so two runs print the same output.
   - **Create:** the application refuses a 16-year-old before writing anything, because no validator can compare a date with today. Then one `insertOne` creates Adaobi with her submitted BVN embedded, and a second creates her main wallet 26.
   - **Read:** Ibrahim Musa's profile, KYC documents and beneficiaries come back from one `findOne`. His wallets are referenced, so they need a second query.
   - **Update:** compliance verifies the BVN, and her tier goes from 1 to 2 in one `updateOne` (positional `$`). Funding her wallet with ₦80,000 is a multi-document transaction: the `$inc` and the ledger entry commit together. Saving Ngozi's wallet as a beneficiary uses the guarded `$push` from seed test 5.27, so saving it a second time matches nothing.
   - **Transfers:** each transfer is one multi-document transaction over four documents in three collections. The debit's filter includes `balance: {$gte: amount}`, and the credit's filter includes `status: "active"`. ₦25,000 to wallet 4 commits. ₦100,000 is refused, because the debit matches nothing. ₦5,000 to wallet 18 (frozen by compliance in Portfolio 1) is debited inside the transaction; then the credit matches nothing, and the transaction is aborted. Each failure is then recorded as a failed transfer with an audit entry, as in Portfolio 1.
   - **Merchant payment:** ₦12,450 at Lekki Fresh Mart, with the merchant snapshot in the ledger entry.
   - **Statement:** wallet 26's entries for October 2026, sorted by time. A running balance is printed beside them and ends at the stored balance, ₦42,550.00.
   - **Delete:** a `$pull` removes the beneficiary. An application-side check refuses to delete wallet 26, because 3 ledger entries point at it. A savings wallet opened by mistake is closed through its status instead of being deleted (case study rule 11).
   - It ends with the counts (3 new transfers, 4 new ledger entries, 4 new audit entries) and both integrity audits passing.
6. **Measured indexes on a larger ledger** with [scripts/03_indexes.js](scripts/03_indexes.js). From a fixed random seed (8103), the script generates 5,000 more customers with main wallets, 57,287 transfers and 227,848 more ledger entries. They run from 1 October 2025 to 8 October 2026, the same period as Portfolio 2. The generator tracks every balance as it goes, so no wallet goes below zero, and both audits still pass on 227,895 entries. Then it measures two Portfolio 2 operations with `explain("executionStats")`, five runs each, and reports the median server time:
   - **Q1, statement:** wallet 2026's entries for September 2026, sorted by time (Portfolio 2's Q1).
   - **Q2, monthly totals:** an aggregation pipeline asking the same question as Portfolio 2's Q2. It has three stages: `$match` on status and July to September; `$group` by month (`$dateTrunc` in `Africa/Lagos`) and by type; `$sort`.

   It then creates three compound indexes and measures again: `{wallet_id, created_at}` for Q1; `{status, created_at}` and a covering `{status, created_at, transaction_type, amount}` for Q2. Hints force each Q2 index in turn, so the two can be compared. The script was run twice, and only the timings and the on-disk sizes changed.

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

7. **Answered Portfolio 2's reporting questions with aggregation pipelines** in [scripts/04_aggregations.js](scripts/04_aggregations.js), on the larger data from step 6. Each prints its result, then its plan, the keys and documents it examined and its server time:
   - **A1, monthly totals (Q2):** the same pipeline as step 6, with its 13 rows. A check confirms that September's transfers out equal transfers in plus the one reversal.
   - **A2, top merchants (Q3):** grouped on the merchant snapshot, with no join. A second version groups on `merchant_id` and adds the current names with `$lookup`; it returns the same 10 rows.
   - **A3, inactive customers (Q4):** `NOT EXISTS` written as a nested `$lookup` (customers to wallets to at most one recent entry), followed by a `$match` on empty results. One row is cross-checked with a plain count.
   - **A4, running balance (Q5b):** `$setWindowFields` over wallet 2026's completed entries, cut to September afterwards, as Portfolio 2 does. The balance after the wallet's last entry equals its stored balance.
   - **A5, KYC fields by type:** unwinds the embedded KYC documents and counts which fields each type carries, so the claim that the fields vary is backed by the data.
8. **Compared the two models** in [comparison.md](comparison.md): the same queries in SQL and in MongoDB, what each makes easier or harder for Proclus, and when I would use each.

## Evidence

| Evidence | File | What it shows |
| --- | --- | --- |
| Export log | [logs/00_export_p1_documents_output.txt](logs/00_export_p1_documents_output.txt) | The Portfolio 1 rebuild (balance and transfer audits pass), then one row per collection: 20 customers with 31 embedded KYC documents and 18 embedded beneficiaries, 25 wallets, 12 merchants, 12 transfers, 47 transactions and 37 audit entries. |
| Sample documents | [model/documents/](model/documents/) | One Extended JSON file per collection, one document per line. For example, customer 5 carries three KYC documents and one beneficiary; ledger entry 8 is a merchant payment with a `merchant` snapshot and no `transfer`. |
| Validators | [model/validators.json](model/validators.json) | One `$jsonSchema` per collection, plus an `$expr` rule on `transfers`. |
| Seed log | [logs/01_seed_output.txt](logs/01_seed_output.txt) | The six collections and ten unique indexes created, then 153 documents loaded and the balance and transfer audits passing (0 of 25 wallets and 0 of 18 transfer legs differ). Tests 5.1-5.15 are rejected by the validators (121) and 5.16-5.23 by the unique indexes (11000), and each line names the rule or index that stopped it. Tests 5.24-5.26 are accepted, which shows what MongoDB does not check. The script was run twice and both outputs were identical. |
| CRUD log | [logs/02_crud_output.txt](logs/02_crud_output.txt) | The seed output, then each key operation for customer 21. Points to look at: the BVN is verified and the tier raised by one write. Inside the transfer's transaction the debited wallet already reads ₦55,000, while a read outside it still returns ₦80,000. The two aborted transfers leave both balances unchanged. The October statement ends at ₦42,550.00. Deleting wallet 26 is refused, and both audits pass at the end. |
| Index log | [logs/03_indexes_output.txt](logs/03_indexes_output.txt) | 227,895 ledger entries by type. For each query: the winning plan, keys and documents examined, and five timings, before and after the indexes. The Q2 result (13 rows, the same before and after), the index sizes, and both audits passing on 5,025 wallets and 114,592 transfer legs. |
| Aggregations log | [logs/04_aggregations_output.txt](logs/04_aggregations_output.txt) | The five pipelines' results with their plans. A1 is answered from the covering index (0 documents examined). A2's snapshot and `$lookup` versions agree. A3 finds 2 inactive customers, after 10,043 keys and documents examined inside its `$lookup`. A4's running balance ends at wallet 2026's stored ₦807,992.00. A5 shows that only the 3 passports and driving licences carry an expiry date. Two runs differed only in timings. |
| Comparison | [comparison.md](comparison.md) | Q2 side by side in SQL and as a pipeline; a table of the other operations in both databases; what gets easier and harder, with figures from these logs and from Portfolio 2's plans; a recommendation for Proclus. |
| Screenshot | [screenshots/p4-01-seed-validators-indexes.png](screenshots/p4-01-seed-validators-indexes.png) | The `mongosh` console for `01_seed.js` on Atlas (MongoDB 8.0.36), sections 1-4. It shows the six collections created with validators, the ten unique indexes named after their Portfolio 1 constraints, and the 153 documents loaded. Every count, plus the balance and transfer audits, prints `ok`. |
| Screenshot | [screenshots/p4-02-validator-and-unique-tests.png](screenshots/p4-02-validator-and-unique-tests.png) | The 27 seed tests. 5.1-5.15 are rejected with 121 `DocumentValidationFailure`, and each names the rule that failed (for example, the overdraft in 5.3 fails `balance > minimum`). 5.16-5.23 are rejected with 11000 `DuplicateKey`, and each names its index. 5.24-5.26 are accepted, which shows the missing foreign key and RESTRICT checks. The audits still pass afterwards. |
| Screenshot | [screenshots/p4-03-crud-create-read-update.png](screenshots/p4-03-crud-create-read-update.png) | `02_crud.js` sections 1-3. An under-18 registration is refused, and customer 21 and wallet 26 are inserted. One `findOne` returns Ibrahim Musa's profile with his KYC documents and beneficiary embedded, while his wallets need a second query. One update verifies the BVN and raises the KYC tier. A second save of the same beneficiary matches nothing. |
| Screenshot | [screenshots/p4-04-crud-transactions-delete.png](screenshots/p4-04-crud-transactions-delete.png) | `02_crud.js` sections 4-7. Inside the transfer's transaction, wallet 26 already reads ₦55,000, while a read outside it still returns ₦80,000. The insufficient-funds transfer and the transfer to frozen wallet 18 are both aborted, with the balances unchanged. The October statement ends at ₦42,550.00, deleting wallet 26 is refused, and the audits pass. |
| Screenshot | [screenshots/p4-05-explain-before-indexes.png](screenshots/p4-05-explain-before-indexes.png) | `03_indexes.js` sections 1-2: the 227,895 generated ledger entries by type. Before the indexes, Q1 is `SORT <- COLLSCAN` and Q2 is `GROUP <- COLLSCAN`, and both examine all 227,895 documents. The 13-row Q2 result follows. This run is newer than the log, so its timings differ (Q1 median 1,302 ms, Q2 2,694 ms). |
| Screenshot | [screenshots/p4-06-explain-after-indexes.png](screenshots/p4-06-explain-after-indexes.png) | `03_indexes.js` sections 3-5, the three compound indexes. After them, Q1 is `FETCH <- IXSCAN` with 4 keys and 4 documents examined in 0 ms. Q2 is `PROJECTION_COVERED` with 0 documents examined; the hinted `{status, created_at}` plan fetches all 70,942. The screenshot also shows the summary table, the index sizes and both audits on the larger data. |
| Screenshot | [screenshots/p4-07-aggregations.png](screenshots/p4-07-aggregations.png) | The whole `04_aggregations.js` run, A1-A5, each with its plan. A1 is covered (0 documents examined), A2's snapshot and `$lookup` versions agree, A3 finds customers 14 and 20, A4's running balance ends at the stored ₦807,992.00, and A5 shows that only passports and driving licences carry an expiry date. Only the timings differ from the log. |

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

Uniqueness (email, wallet number, reference) needs unique indexes, which the seed script creates. The rest has to be done by the application, or checked afterwards with an aggregation. That is the main thing Proclus gives up compared with PostgreSQL.

### What the seed tests show

The 23 rejections show that one document can carry most of Portfolio 1's rules. Test 5.3 matters most for a wallet: a `$inc` that would take wallet 2 from ₦23,500 to −₦26,500 is refused by the validator's `minimum: 0`, just as Portfolio 1's `CHECK (balance >= 0)` refused it. Tests 5.10-5.12 show the varying KYC fields are still checked: each type and review state has its own rule, and the error names the rule by its description.

The three accepted writes are the cost of the model:
- **5.24 (no foreign key):** a ledger entry for wallet 999 is stored without complaint.
- **5.25 (no `ON DELETE RESTRICT`):** wallet 5 can be deleted while 3 ledger entries still point at it. Portfolio 1 refused this delete with error 23001.
- **5.26 (embedded duplicates):** a unique index compares different documents, never two elements of one array. So customer 6 can save wallet 10 twice. Portfolio 1's `beneficiaries_wallet_once_key` would have stopped it.

For 5.26, test 5.27 shows the application-side fix: the "not saved yet" check goes into the update's filter (`"beneficiaries.wallet_id": {$ne: 10}`). A single-document update is atomic, so the check and the write cannot be separated, and the duplicate is not added (matched 0). For 5.24 and 5.25 there is no such shortcut. The application must check the other collection, or run the audit pipelines afterwards, as section 4 of the script does.

### Multi-document transactions in the CRUD script

A transfer changes two wallets and adds a transfer and two ledger legs. In this model those are four documents in three collections, so only a multi-document transaction can keep them together. The script starts one with `readConcern: "snapshot"` and `writeConcern: {w: "majority"}`. With a majority write concern, the commit is acknowledged only once most of the three Atlas replica-set members have it.

The log shows the transaction behaving like Portfolio 3's transactions:
- **Isolation:** inside the transaction the debited wallet reads ₦55,000. At the same moment, a read outside it still returns ₦80,000, so no other session sees uncommitted data.
- **Atomicity:** in the transfer to the frozen wallet, the debit had already succeeded inside the transaction. After `abortTransaction` the sender's balance is ₦55,000 again, as if the debit never happened.
- **No overdraft:** the check is in the debit's filter (`balance: {$gte: amount}`), like Portfolio 3's atomic `UPDATE ... WHERE balance >= x`. The validator's `minimum: 0` (seed test 5.3) is a second line of defence.

Some writes need no transaction. Verifying the BVN and raising the tier are two changes to one customer document, and a single-document write is always atomic; in Portfolio 1 the same change touches two tables. This is where the document model saves work: data that is read together and changed together lives in one document.

The cost is that money still moves across documents, so every transfer pays for a transaction that spans the replica set. Transactions also have limits. By default one must finish within 60 seconds. A write conflict aborts it with a `TransientTransactionError`, which the application must retry, like the SERIALIZABLE retry in Portfolio 3. PostgreSQL gives the same guarantees to every statement without extra code.

### Indexes and `explain`

| Query | Before: plan | Before: keys / docs examined | Before: median | After: plan | After: keys / docs examined | After: median |
| --- | --- | --- | --- | --- | --- | --- |
| Q1 statement, wallet 2026, September | `SORT <- COLLSCAN` | 0 / 227,895 | 1,142 ms | `FETCH <- IXSCAN` on `{wallet_id, created_at}` | 4 / 4 | 0 ms |
| Q2 monthly totals, `{status, created_at}` (hinted) | `GROUP <- COLLSCAN` | 0 / 227,895 | 3,219 ms | `GROUP <- FETCH <- IXSCAN` | 70,942 / 70,942 | 227 ms |
| Q2 monthly totals, covering index (planner's choice) | `GROUP <- COLLSCAN` | 0 / 227,895 | 3,219 ms | `GROUP <- PROJECTION_COVERED <- IXSCAN` | 70,942 / 0 | 176 ms |

The times are from the second run, which is the one in the log. Atlas M0 is a shared server, so times move between runs. In the first run, Q1 before took 1,353 ms and Q2 before took 3,201 ms, and one Q2 "before" run took only 501 ms because the data was already in memory. The keys and documents examined were the same in both runs, so they are the stronger evidence.

- **Q1** gives the clearest result. Without an index, MongoDB reads all 227,895 entries to find 4, then sorts them in memory. The index `{wallet_id: 1, created_at: 1}` has the equality field first and the range field second. So the scan lands on wallet 2026's September entries, already in date order: 4 keys, 4 documents and no `SORT` stage. It is the same index and the same plan change as Portfolio 2's Q1, which went from 164 ms to 0.047 ms.
- **Q2** follows the ESR rule (equality, sort, range): `status` (equality) comes before `created_at` (range). The index narrows the scan from 227,895 documents to the 70,942 completed entries of July to September, 31% of the collection. With the plain index, each of those 70,942 documents is still fetched. With the covering index, `$group` reads `transaction_type` and `amount` straight from the index keys: the plan shows `PROJECTION_COVERED` and 0 documents examined. This is the MongoDB version of Portfolio 2's `INCLUDE` index, and the planner chooses it without a hint.
- **Covering is worth little here.** The covering index saves 70,942 document reads but only 30 to 115 ms across the two runs, because a dataset this small is already in memory. Q2 still reads a third of the index entries. Portfolio 2 reached the same verdict on its covering index.
- **Cost:** the three new indexes take 2.7, 2.4 and 6.9 MB, next to 11.3 MB of compressed data, and every ledger insert must now update three more indexes. `{status, created_at}` is a prefix of the covering index, so it is redundant: it is there only for the comparison, and Proclus would keep one or the other. Sizes on disk change a little between runs (6.4 to 7.3 MB for `_id_`), because the collection is rebuilt and compressed afresh each time.

### What the aggregations show

- **Single-collection reports translate directly.** A1, A2 and A4 map clause for clause onto Portfolio 2's SQL. `$setWindowFields` is the window function, and the indexes from step 6 serve them as Portfolio 2's indexes served the SQL. A4 still shows a `SORT` stage on 34 entries: the window sorts on `created_at` and then `_id` to break ties, as Portfolio 2 sorts on `created_at` and `transaction_id`, and the index only covers `created_at`.
- **The snapshot makes the top-merchants report join-free.** Grouping on the merchant snapshot gives the same result as `$lookup`, because no merchant has been renamed. If one were, the snapshot would show the name each payment was made to, and the `$lookup` would show today's name.
- **The anti-join is where MongoDB struggles.** A3 took 1.4 s on one run and 3.7 s on the other, for 5,020 customers. Its `$lookup` runs a look-up for every customer's wallets and every wallet's recent entries, 10,043 in all. Portfolio 2's Q4 answered the same question for 50,020 customers in 487 ms with a single Hash Right Anti Join. The 2 customers it finds are Portfolio 1 customers 14 and 20, whose wallets have no ledger entries since 11 July. Every generated wallet has recent entries.
- **The varying KYC fields are real.** A5 counts them: of 31 KYC documents, only passports and driving licences carry an expiry date, and the 2 documents still waiting for review carry no review fields. Every generated customer is tier 1 with no documents, so tiers 2 and 3 average 1.22 and 3.00 documents. [comparison.md](comparison.md) uses these figures to argue where the document model fits.

## Challenges and decisions

- **Building the documents from Portfolio 1 instead of retyping them.** Copying 153 rows into a mongosh script by hand would risk small differences from Portfolio 1. The export builds every document from the Portfolio 1 tables in SQL, so both databases hold the same ids, names and amounts. The script is a `.sql` file in `scripts/`, next to the mongosh scripts, which the guide's folder list does not mention.
- **Leaving NULLs out.** A NULL column becomes an absent field (`json_strip_nulls`), not `null`. The validators can then say "this field exists only when ...", which is how the varying KYC and ledger fields are described.
- **Key order.** PostgreSQL's `jsonb` sorts object keys, so `jsonb_pretty` would put `_id` in the middle of each document. The export uses `json`, which keeps the order written, at the cost of one document per line instead of pretty-printing.
- **Unique indexes on embedded KYC documents.** Three customers have no KYC documents yet. So the unique index on `kyc_documents.(document_type, document_number)` is partial: it covers only customers that have at least one document. The index on transfer legs is partial for the same reason: it covers only ledger entries that belong to a transfer. This matches Portfolio 1, where rows with a NULL `transfer_id` never clash.
- **Making each test fail for one reason only.** The first test copies all clashed with an existing document on some other unique key. For example, a copied wallet for customer 6 was a second `main` wallet. So a test could have failed on a different rule from the one it was meant to test. Each base copy is now a valid document that clashes with nothing (customer 6's `savings` wallet, a customer with no KYC documents), and each test changes one field. The log prints the rule or index that rejected it, so the reason can be checked.
- **Ids for new documents.** Portfolio 1 gets its ids from identity columns, and MongoDB has nothing like them. The CRUD script takes the highest stored `_id` plus one, which is safe only because one script writes at a time. Its comment says that a real application would use ObjectIds, or a counter document updated with `$inc`, so that two writers could never take the same number.
- **Re-runnable scripts with fixed output.** `02_crud.js` and `03_indexes.js` load `01_seed.js` first, just as every Portfolio 3 script rebuilds the Portfolio 1 data, so each starts from the same 153 documents. `02_crud.js` uses fixed times and `03_indexes.js` a seeded random number generator, so reruns differ only in timings.
- **Generating 228,000 entries that still pass the audits.** Random ledger entries would break the balance audit. The generator tracks every wallet's balance as it goes, in kobo as whole numbers. It tops a wallet up when it falls under ₦5,000, never sends more than the balance, and writes the wallets last, with the balances the ledger arrived at. Both audits pass on the larger data, as Portfolio 2's four audits did after its seed.
- **Atlas free-tier limits.** M0 has 512 MB of storage and shares its server with other clusters. The generated data is about 11 MB compressed, plus indexes. Timings move between runs, so the analysis relies on keys and documents examined, which do not.
- **Aggregations on the larger data only.** `04_aggregations.js` needs the 227,895 entries from `03_indexes.js`, and reloading them takes four minutes. So instead of rerunning `03` first, it checks that the data is there and stops with a message if it is not. Because it only reads, it can be run any number of times.
- **Atlas upgraded the cluster during the week.** The seed log of 30 October shows MongoDB 8.0.34, and the runs on 31 October printed 8.0.36. Atlas applies patch upgrades to M0 clusters itself. I first copied 8.0.34 into the headers of the 02 and 03 logs, then corrected them to the version the server printed. The Environment section records both versions.
- **Error details.** `$jsonSchema` errors return a nested `errInfo`. A small function in the script follows it to the rule that failed and prints the rule's `description` from validators.json. The transfer validator combines `$jsonSchema` and `$expr`, so its errors start with an extra `$and` level, which the function skips.

## References

- MongoDB, Inc. *MongoDB Manual* (version 8.0): data modeling (embedding and referencing), schema validation with `$jsonSchema`, indexes (unique, partial and collation options), transactions, the aggregation pipeline (`$lookup`, `$setWindowFields`, `$dateTrunc`), explain results, and BSON types (Decimal128). https://www.mongodb.com/docs/manual/
- MongoDB, Inc. *MongoDB Atlas Documentation* and *mongosh Documentation*. https://www.mongodb.com/docs/atlas/ and https://www.mongodb.com/docs/mongodb-shell/
- Elmasri, R. and Navathe, S. B. (2016). *Fundamentals of Database Systems* (7th ed.). Pearson. Chapter on NoSQL databases and big data storage systems.
- Central Bank of Nigeria (2013). *Circular on the Three-Tiered Know-Your-Customer (KYC) Requirements*. Used for the tier 1 to 3 model, as in Portfolio 1.
