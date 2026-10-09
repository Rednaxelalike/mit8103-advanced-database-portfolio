# Case study: Proclus, a simulated Lagos digital wallet

Proclus is the single case study used in all five portfolios. It is a fictional organisation, so no real company's data is used or misrepresented.

## Case study statement

| Element | Proclus |
| --- | --- |
| 1. Organisation name or scenario | Proclus, a simulated digital wallet based in Lagos, Nigeria. |
| 2. Nature of the business | A mobile wallet that lets customers hold naira, pay merchants and send money to other wallets. |
| 3. Users of the database | Customers, merchants, customer-support staff, compliance officers and administrators. |
| 4. Major data stored | Customers and their KYC documents, wallets and balances, transactions and transfers, merchants, saved beneficiaries, and an audit log. |
| 5. Key operations | Open a wallet, verify KYC, fund a wallet, transfer between wallets, pay a merchant, reverse a failed transfer, generate a statement, audit balances. |

## Business rules

These rules come from how a Nigerian wallet works. Each one is enforced by a key or constraint in [sql/01_schema.sql](sql/01_schema.sql), unless the rule says otherwise.

1. A customer registers with a name, email, Nigerian mobile number and date of birth. No two customers share an email or a phone number.
2. Customers sit on a KYC tier, following the Central Bank of Nigeria's tiered approach. Tier 1 needs only a phone number and name. Tier 2 needs a verified BVN or NIN. Tier 3 also needs a verified photo ID or NIN and a utility bill as proof of address.
3. A KYC document is either waiting for review or reviewed by a named compliance officer at a recorded time. The same BVN, NIN or ID number cannot belong to two customers.
4. Each customer has one main wallet and may open one savings wallet. Every wallet has a unique 10-digit wallet number.
5. A wallet balance can never go below zero. Proclus offers no overdraft.
6. Every movement of money is one row in the ledger, with a positive amount. Its type says whether it is a credit or a debit.
7. A transfer moves money between two different wallets. It is pending, completed, failed or reversed, and a failed or reversed transfer records the reason.
8. A merchant payment debits the customer's wallet and names the merchant paid.
9. Customers can save other wallets as beneficiaries, each wallet once and each nickname once.
10. Decisions made by staff or by the system are written to an append-only audit log.
11. Financial records are never deleted. Customers, wallets and merchants are closed or suspended through their status.

**Assumptions and scope.** All money is in naira (NGN). Card and bank-transfer funding arrive from outside Proclus, so only the resulting ledger row is stored. Merchant settlement and staff accounts also live outside this database. The rule that a customer must be 18 or over is checked by the onboarding operation, because a CHECK constraint cannot compare against today's date.

## Entities and attributes

The full column list, data types and constraints are in [sql/01_schema.sql](sql/01_schema.sql) and on the ERD.

| Entity (table) | What one row is | Key attributes |
| --- | --- | --- |
| `customers` | A person who holds Proclus wallets | `customer_id` (PK); `email`, `phone_number` (candidate keys); `kyc_tier`, `status` |
| `kyc_documents` | One identity or address document submitted by a customer | `document_id` (PK); (`document_type`, `document_number`) (candidate key); review status, reviewer, review time |
| `wallets` | One naira wallet | `wallet_id` (PK); `wallet_number` and (`customer_id`, `wallet_type`) (candidate keys); `balance`, `status` |
| `merchants` | A business that accepts wallet payments | `merchant_id` (PK); `cac_number`, `email` (candidate keys); `category` |
| `transfers` | One request to move money between two wallets | `transfer_id` (PK); `reference` (candidate key); sender, receiver, `amount`, `status` |
| `transactions` | One ledger row: money moving on one wallet | `transaction_id` (PK); `reference` (candidate key); `wallet_id`, `transaction_type`, `amount`, `status` |
| `beneficiaries` | A wallet one customer has saved | `beneficiary_id` (PK); (`customer_id`, `wallet_id`) and (`customer_id`, `nickname`) (candidate keys) |
| `audit_log` | One staff or system decision | `audit_id` (PK); `entity_type` + `entity_id`, `action`, `actor_type` + `actor_ref` |

## Relationships and cardinalities

| Relationship | Cardinality | Implemented by | ON DELETE |
| --- | --- | --- | --- |
| A customer submits KYC documents | one customer to zero or many documents | `kyc_documents.customer_id` NOT NULL | CASCADE |
| A customer owns wallets | one customer to zero, one or two wallets (one main, at most one savings) | `wallets.customer_id` NOT NULL, plus UNIQUE (`customer_id`, `wallet_type`) | RESTRICT |
| A customer saves beneficiaries | one customer to zero or many beneficiaries | `beneficiaries.customer_id` NOT NULL | CASCADE |
| A wallet is saved as a beneficiary | one wallet to zero or many beneficiaries | `beneficiaries.wallet_id` NOT NULL | CASCADE |
| A wallet sends transfers | one wallet to zero or many transfers | `transfers.sender_wallet_id` NOT NULL | RESTRICT |
| A wallet receives transfers | one wallet to zero or many transfers | `transfers.receiver_wallet_id` NOT NULL | RESTRICT |
| A wallet has ledger rows | one wallet to zero or many transactions | `transactions.wallet_id` NOT NULL | RESTRICT |
| A transfer has ledger legs | one transfer to zero to three transactions; a transaction belongs to zero or one transfer | `transactions.transfer_id` nullable, plus UNIQUE (`transfer_id`, `transaction_type`) | RESTRICT |
| A merchant is paid by ledger rows | one merchant to zero or many transactions; a transaction names zero or one merchant | `transactions.merchant_id` nullable | RESTRICT |

`beneficiaries` resolves a many-to-many relationship: a customer can save many wallets, and a wallet can be saved by many customers.

A transfer has no ledger rows while pending or after failing, because no money moved. A completed transfer has two: a debit on the sender and a credit on the receiver. A reversed transfer has two: the debit, and a reversal credit that returns the money to the sender.

`audit_log` has no foreign keys. Its `entity_type` and `entity_id` point at a different table depending on the entry, and an audit entry must outlive the row it describes.

The diagram is [erd/erd.png](erd/erd.png). Its editable source is [erd/erd.drawio](erd/erd.drawio), which opens in draw.io desktop or at app.diagrams.net.
