# Normalisation

This document shows how the Proclus schema was reached. It starts from one flat, unnormalised record, lists the functional dependencies, and walks the record through first, second and third normal form. It then checks every final table against Boyce-Codd normal form (BCNF) and names the one deliberate denormalisation.

Notation: `X → Y` means "X functionally determines Y". Any two rows that agree on X must agree on Y. A **candidate key** is a minimal set of attributes that determines every other attribute in the table. A **prime** attribute is part of some candidate key.

## 1. Starting point: one flat record (UNF)

Imagine Proclus before it had a database. The operations team exports one spreadsheet row per wallet. The row carries the owner's details, a single cell listing their KYC documents, and the wallet's statement lines as repeating columns.

```
WalletStatementExport(
    wallet_number, wallet_type, balance,
    customer_name, email, phone_number, kyc_tier,
    kyc_documents,                                   -- a list in one cell
    { line_no, txn_date, reference, txn_type, dr_cr, amount,
      merchant_cac, merchant_name, merchant_category,
      counterparty_wallet, counterparty_name } )     -- repeating group
```

Two rows of the export, using the real sample data for Chinedu Okafor and Ngozi Eze:

| wallet_number | wallet_type | balance | customer_name | email | phone_number | kyc_tier | kyc_documents | statement lines |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 5012748390 | main | 102549.50 | Chinedu Okafor | chinedu.okafor@example.com | +2348031000001 | 3 | BVN 22140583921 (verified); NIN 40817263950 (verified); utility bill EKEDC-0816-44721 (verified) | 1, 2026-08-02, TXN2608020001, funding, CR, 150000.00<br>2, 2026-08-09, TXN2608090002, merchant_payment, DR, 18450.50, RC1482736, Lekki Fresh Mart, groceries<br>3, 2026-08-15, TXN2608150001, transfer_out, DR, 20000.00, to 5049320581 Ngozi Eze |
| 5049320581 | main | 45000.00 | Ngozi Eze | ngozi.eze@example.com | +2348091000004 | 2 | NIN 51263870412 (verified) | 1, 2026-08-05, TXN2608050001, funding, CR, 25000.00<br>2, 2026-08-15, TXN2608150002, transfer_in, CR, 20000.00, from 5012748390 Chinedu Okafor |

This layout has the three classic anomalies:

- **Update anomaly.** Chinedu's phone number sits on his main wallet row and again on his savings wallet row. Lekki Fresh Mart's name sits on every line that paid it. Changing one copy leaves the others wrong.
- **Insertion anomaly.** A merchant cannot be recorded until someone pays it, and a customer cannot be recorded until a wallet exists. A transfer that fails writes no statement line, so the failure leaves no trace.
- **Deletion anomaly.** Removing the only payment to Marina Screens Cinema would also remove the only record that the merchant exists.

## 2. Functional dependencies

These dependencies come from the business rules in [case-study.md](case-study.md), not from the sample rows alone. A dependency must hold for every legal set of data, not just the rows we happen to have.

| # | Dependency | Business reason |
| --- | --- | --- |
| FD1 | `wallet_number → wallet_type, balance, email` | A wallet number identifies one wallet, owned by one customer |
| FD2 | `email → customer_name, phone_number, kyc_tier` | An email identifies one customer |
| FD3 | `phone_number → email` | A phone number also identifies one customer |
| FD4 | `{email, wallet_type} → wallet_number` | A customer has at most one wallet of each type |
| FD5 | `{wallet_number, line_no} → reference` | A line number identifies a line within one wallet's statement |
| FD6 | `reference → wallet_number, line_no, txn_date, txn_type, amount, merchant_cac, counterparty_wallet` | A reference identifies one ledger line |
| FD7 | `txn_type → dr_cr` | funding, transfer_in and reversal are always credits; transfer_out and merchant_payment are always debits |
| FD8 | `merchant_cac → merchant_name, merchant_category` | A CAC registration number identifies one merchant |
| FD9 | `counterparty_wallet → counterparty_name` | The other wallet has one owner, whose name is fixed by FD1 and FD2 |
| FD10 | `{document_type, document_number} → email, document_status` | One real-world document belongs to one customer |

Dependencies that look plausible but do **not** hold:

- `email ↛ wallet_number`, because a customer can own a main and a savings wallet.
- `merchant_name ↛ merchant_category`, because two separate businesses can trade under the same name. The CAC number is the identifier.
- `document_number ↛ document_type`, because a BVN and a NIN are both 11 digits. Only the pair is unique.

## 3. First normal form (1NF)

1NF needs atomic values, no repeating groups, and a key.

1. `customer_name` is a composite value. It is split into `first_name` and `last_name`.
2. `kyc_documents` holds a list in one cell. It moves to its own relation, with one row per document:

   `KycDocument(document_type, document_number, email, document_status)`, key {`document_type`, `document_number`} by FD10.

3. The repeating statement lines are flattened to one row per line. The wallet and customer columns are copied onto every line:

   `StatementLine1NF(wallet_number, line_no, wallet_type, balance, first_name, last_name, email, phone_number, kyc_tier, reference, txn_date, txn_type, dr_cr, amount, merchant_cac, merchant_name, merchant_category, counterparty_wallet, counterparty_name)`

   Candidate keys: {`wallet_number`, `line_no`} and {`reference`}. The primary key is {`wallet_number`, `line_no`}.

Part of `StatementLine1NF` after flattening, with some columns left out for width:

| wallet_number | line_no | email | kyc_tier | reference | txn_type | dr_cr | amount | merchant_cac | merchant_name | counterparty_wallet | counterparty_name |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 5012748390 | 1 | chinedu.okafor@example.com | 3 | TXN2608020001 | funding | CR | 150000.00 | | | | |
| 5012748390 | 2 | chinedu.okafor@example.com | 3 | TXN2608090002 | merchant_payment | DR | 18450.50 | RC1482736 | Lekki Fresh Mart | | |
| 5012748390 | 3 | chinedu.okafor@example.com | 3 | TXN2608150001 | transfer_out | DR | 20000.00 | | | 5049320581 | Ngozi Eze |
| 5049320581 | 1 | ngozi.eze@example.com | 2 | TXN2608050001 | funding | CR | 25000.00 | | | | |
| 5049320581 | 2 | ngozi.eze@example.com | 2 | TXN2608150002 | transfer_in | CR | 20000.00 | | | 5012748390 | Chinedu Okafor |

The table is now in 1NF, but the repetition is plain to see. Chinedu's email and tier appear on every one of his lines.

## 4. Second normal form (2NF)

2NF needs 1NF, and no non-prime attribute may depend on only part of a composite candidate key.

**The violation is FD1.** The key {`wallet_number`, `line_no`} is composite. `wallet_type`, `balance` and `email` depend on `wallet_number` alone, which is half of the key. Through FD2, so do `first_name`, `last_name`, `phone_number` and `kyc_tier`. Every line of a statement repeats them. That repetition is the update anomaly from section 1.

The other candidate key, {`reference`}, is a single attribute, so nothing can depend on part of it.

**Fix.** Move the wallet facts into their own relation, keyed by the attribute they depend on:

- `Wallet2NF(wallet_number, wallet_type, balance, email, first_name, last_name, phone_number, kyc_tier)`, key {`wallet_number`}
- `StatementLine2NF(wallet_number, line_no, reference, txn_date, txn_type, dr_cr, amount, merchant_cac, merchant_name, merchant_category, counterparty_wallet, counterparty_name)`, keys {`wallet_number`, `line_no`} and {`reference`}

The split is lossless. The shared attribute `wallet_number` is a key of `Wallet2NF`, so joining the two relations on it gives back exactly the 1NF rows (Heath's theorem).

## 5. Third normal form (3NF)

3NF needs 2NF, and no non-prime attribute may depend on a key through another non-key attribute. Formally, for every dependency `X → A`, either X is a superkey or A is prime.

Four transitive dependencies remain.

| Relation | Transitive chain | Why it is a problem | Fix |
| --- | --- | --- | --- |
| `Wallet2NF` | `wallet_number → email → first_name, last_name, phone_number, kyc_tier` | `email` is not a key here, because Chinedu has two wallets. His details are stored once per wallet. | New relation `Customer(email, first_name, last_name, phone_number, kyc_tier)`. `Wallet` keeps `email` as a foreign key. |
| `StatementLine2NF` | `reference → merchant_cac → merchant_name, merchant_category` | The merchant's name is repeated on every payment line, and a merchant cannot exist without a payment. | New relation `Merchant(merchant_cac, merchant_name, merchant_category)`. |
| `StatementLine2NF` | `reference → txn_type → dr_cr` | `dr_cr` is fully fixed by the type. A line saying `funding, DR` would be a contradiction the table allows. | Drop `dr_cr`. The direction is derived from `transaction_type` wherever it is needed, and a CHECK constraint limits the type to five values. A five-row lookup table would also be 3NF; dropping the column is simpler because the rule never changes. |
| `StatementLine2NF` | `reference → counterparty_wallet → counterparty_name` | The name is a copy of data already reachable through `Wallet` and `Customer`. | Drop `counterparty_name`. |

The result is in 3NF:

- `Customer(email, first_name, last_name, phone_number, kyc_tier)`, keys {`email`}, {`phone_number`}
- `Wallet(wallet_number, email, wallet_type, balance)`, keys {`wallet_number`}, {`email`, `wallet_type`}
- `Merchant(merchant_cac, merchant_name, merchant_category)`, key {`merchant_cac`}
- `KycDocument(document_type, document_number, email, document_status)`, key {`document_type`, `document_number`}
- `StatementLine(wallet_number, line_no, reference, txn_date, txn_type, amount, merchant_cac, counterparty_wallet)`, keys {`wallet_number`, `line_no`}, {`reference`}

### Two modelling corrections the normal forms do not catch

Normal forms only see dependencies inside one table. Two problems remain that need a change to the model itself.

1. **The transfer is a missing entity.** Lines TXN2608150001 and TXN2608150002 describe one event, Chinedu's NGN 20,000 to Ngozi. Each line stores the amount and the other wallet, so the event is recorded twice. A failed transfer, such as Ngozi's NGN 50,000 attempt on 2 October, writes no line at all, so its outcome and reason have nowhere to go. Making the transfer its own entity fixes both: `Transfer(reference, sender_wallet, receiver_wallet, amount, status, failure_reason, created_at, processed_at)`. Each ledger line now points at its transfer instead of storing a counterparty.
2. **`line_no` is a display number, not data.** It changes meaning whenever lines are filtered or reordered, and it can be generated when a statement is printed. Portfolio 2 does this with `ROW_NUMBER()`. The ledger is identified by `reference` instead.

Two more relations come from business rules rather than from the export: saved beneficiaries and the audit log.

### Surrogate keys

The final step gives each table a `BIGINT` identity column as its primary key, for example `customer_id` instead of `email`. Natural identifiers can change: a customer may update their email, and that change would otherwise ripple through every wallet and beneficiary that refers to them. Every natural key stays as a UNIQUE constraint, so it is still a candidate key. Adding a surrogate key therefore leaves the normal form unchanged.

| 3NF relation | Table in [sql/01_schema.sql](sql/01_schema.sql) |
| --- | --- |
| Customer | `customers` |
| Wallet | `wallets` |
| Merchant | `merchants` |
| KycDocument | `kyc_documents` |
| Transfer | `transfers` |
| StatementLine | `transactions` (the ledger) |
| from business rules | `beneficiaries`, `audit_log` |

## 6. BCNF check

BCNF is stricter than 3NF. For every non-trivial dependency `X → Y`, X must be a superkey. 3NF still allows `X → A` when A is prime. The two forms only differ when a table has overlapping composite candidate keys, so those tables get the closest look.

| Table | Candidate keys | Non-trivial dependencies | BCNF? |
| --- | --- | --- | --- |
| `customers` | {customer_id}, {email}, {phone_number} | Each key determines the whole row | Yes |
| `merchants` | {merchant_id}, {cac_number}, {email} | Each key determines the whole row | Yes |
| `kyc_documents` | {document_id}, {document_type, document_number} | Each key determines the whole row | Yes |
| `wallets` | {wallet_id}, {wallet_number}, {customer_id, wallet_type} | Each key determines the whole row | Yes |
| `transfers` | {transfer_id}, {reference} | Each key determines the whole row | Yes |
| `transactions` | {transaction_id}, {reference}; {transfer_id, transaction_type} for transfer legs | Each key determines the whole row. `transaction_type → direction` no longer exists because direction is not stored. | Yes |
| `beneficiaries` | {beneficiary_id}, {customer_id, wallet_id}, {customer_id, nickname} | {customer_id, wallet_id} → nickname; {customer_id, nickname} → wallet_id. Both left sides are keys. | Yes |
| `audit_log` | {audit_id} | audit_id determines the whole row | Yes, after a design change (below) |

**The `beneficiaries` table is the one to watch.** Its two composite keys overlap on `customer_id`, which is exactly where 3NF and BCNF can part ways. Suppose Proclus required a nickname to be the wallet owner's name. Then `wallet_id → nickname` would hold. `wallet_id` is not a superkey, so the table would break BCNF. It would still pass 3NF, because `nickname` is prime. Proclus lets customers choose any nickname, so that dependency does not hold and the table is in BCNF.

**The `audit_log` table failed 3NF in my first draft.** Its actions were named per entity, such as `kyc_verified` and `transfer_failed`. That made `action → entity_type` hold: every `kyc_verified` row was about a KYC document. The chain `audit_id → action → entity_type` is transitive. I changed the actions to plain verbs that several entity types share: `status_changed`, `verified`, `rejected`, `held`, `failed`, `reversed`, `audited`. The sample data uses `failed` for both a transfer and a card top-up transaction, and `status_changed` for both a customer and a wallet, so action no longer determines entity type.

**Two more dependencies were checked and rejected in `audit_log`.**

- `actor_ref → actor_type` does not hold as a rule. Customer ids, staff usernames and system component names come from three separate namespaces, and the same text could appear in two of them. The pair (`actor_type`, `actor_ref`) names the actor.
- `entity_id` alone is not unique either. Wallet 12 and transfer 12 both exist. The pair (`entity_type`, `entity_id`) names the row.

**Conclusion: every table is in BCNF.**

## 7. Deliberate denormalisation: the stored wallet balance

`wallets.balance` can be derived. It equals the completed credits minus the completed debits for that wallet in `transactions`. Storing it duplicates information, so it is a deliberate denormalisation. Normal forms do not flag it, because inside `wallets` the balance depends only on the key. The duplication sits between two tables, which is why it needs its own check.

**Why it is stored.**

1. **Speed.** Checking a balance before a payment reads one row by primary key. Deriving it would sum every ledger row for the wallet, and the ledger only grows. Portfolio 2 loads close to a million rows.
2. **Overdraft protection in the database itself.** `CHECK (balance >= 0)` works only on a stored value. With it, a single `UPDATE wallets SET balance = balance - x WHERE wallet_id = ... AND balance >= x` both checks and debits in one step. Test T01 in [sql/03_constraint_tests.sql](sql/03_constraint_tests.sql) shows the database refusing an overdraft.

**The cost.** There are two copies of the truth. If a ledger row is written without the matching balance change, or the other way round, they drift apart. This is the update anomaly that normalisation normally prevents.

**How it is kept correct.**

- The balance changes only inside the same database transaction that writes the ledger row, so both commit or neither does. Portfolio 3 builds and tests this, including two transfers racing on one wallet.
- Nothing else is allowed to update `balance`.
- A balance audit recomputes every balance from the ledger and compares. [sql/02_sample_data.sql](sql/02_sample_data.sql) runs it before committing and aborts the load on any mismatch. Proclus would run the same check nightly and record it in `audit_log` with the action `audited`.

**A smaller, related duplication.** Each ledger row of a transfer repeats the transfer's amount and its own wallet. This keeps a wallet statement readable from `transactions` alone, without a join to `transfers`. The same load script checks that every transfer leg matches its transfer.

**What is not a denormalisation.** `customers.kyc_tier` looks derivable from verified documents, but it is not. It records a compliance officer's decision. A document can be verified without the tier changing, for example while the utility bill is still under review.

## References

- Codd, E. F. (1972). Further normalization of the data base relational model. In R. Rustin (Ed.), *Data Base Systems* (pp. 33-64). Prentice-Hall.
- Elmasri, R. and Navathe, S. B. (2016). *Fundamentals of Database Systems* (7th ed.). Pearson. Chapters 14 and 15.
- Silberschatz, A., Korth, H. F. and Sudarshan, S. (2020). *Database System Concepts* (7th ed.). McGraw-Hill. Chapter 7.
- PostgreSQL Global Development Group. *PostgreSQL 18 Documentation*, section 5.5 "Constraints". https://www.postgresql.org/docs/18/ddl-constraints.html
