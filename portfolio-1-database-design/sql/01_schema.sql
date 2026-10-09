-- =====================================================================
-- Portfolio 1: Database design and modelling
-- 01_schema.sql  Builds the Proclus wallet schema from scratch.
--
-- Run from the repo root (see SETUP.md for loading PGPASSWORD):
--   psql -w -U postgres -h localhost -p 5432 -d proclus -v ON_ERROR_STOP=1
--        -f portfolio-1-database-design/sql/01_schema.sql
--
-- Re-runnable: the eight tables are dropped first, so every run starts
-- from an empty schema. All data is lost on a re-run.
--
-- Conventions used in every table
--   * Surrogate keys are BIGINT identity columns (GENERATED ALWAYS, so the
--     application cannot invent its own ids). Natural keys such as email,
--     wallet number and reference are kept as UNIQUE candidate keys.
--   * Money is NUMERIC(14,2): exact decimal, two kobo places, up to
--     NGN 999,999,999,999.99. Never float, which cannot store 0.10 exactly.
--   * Every point in time is TIMESTAMPTZ, so Lagos time (+01) and UTC never
--     get mixed up.
--   * Fixed value sets use named CHECK constraints rather than ENUM types,
--     so the error message names the rule that was broken and the set can
--     be changed with ALTER TABLE.
--   * No secondary indexes yet. Only the indexes behind PRIMARY KEY and
--     UNIQUE exist; Portfolio 2 adds and measures the others.
-- =====================================================================

BEGIN;

DROP TABLE IF EXISTS audit_log, beneficiaries, transactions, transfers,
                     kyc_documents, wallets, merchants, customers CASCADE;

-- ---------------------------------------------------------------------
-- customers: people who hold Proclus wallets.
-- kyc_tier follows the Central Bank of Nigeria tiered KYC idea:
-- 1 = phone and name only, 2 = BVN or NIN verified, 3 = ID and address verified.
-- ---------------------------------------------------------------------
CREATE TABLE customers (
    customer_id    BIGINT       GENERATED ALWAYS AS IDENTITY,
    first_name     VARCHAR(50)  NOT NULL,
    last_name      VARCHAR(50)  NOT NULL,
    email          VARCHAR(254) NOT NULL,
    phone_number   VARCHAR(14)  NOT NULL,
    date_of_birth  DATE         NOT NULL,
    kyc_tier       SMALLINT     NOT NULL DEFAULT 1,
    status         VARCHAR(10)  NOT NULL DEFAULT 'active',
    created_at     TIMESTAMPTZ  NOT NULL DEFAULT now(),

    CONSTRAINT customers_pkey              PRIMARY KEY (customer_id),
    CONSTRAINT customers_email_key         UNIQUE (email),
    CONSTRAINT customers_phone_number_key  UNIQUE (phone_number),
    CONSTRAINT customers_email_format      CHECK (email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
    -- Nigerian mobile number in international form: +234 then 70x/80x/81x/90x/91x and 8 digits.
    CONSTRAINT customers_phone_format      CHECK (phone_number ~ '^\+234[789][01][0-9]{8}$'),
    -- A CHECK cannot use CURRENT_DATE (PostgreSQL treats CHECK expressions as
    -- immutable), so the 18+ rule lives in the onboarding operation; the
    -- database only rejects impossible dates.
    CONSTRAINT customers_date_of_birth_min CHECK (date_of_birth >= DATE '1900-01-01'),
    CONSTRAINT customers_kyc_tier_valid    CHECK (kyc_tier BETWEEN 1 AND 3),
    CONSTRAINT customers_status_valid      CHECK (status IN ('active', 'suspended', 'closed'))
);

-- ---------------------------------------------------------------------
-- merchants: businesses that customers pay from their wallets.
-- cac_number is the Corporate Affairs Commission registration number
-- (RC for companies, BN for business names).
-- ---------------------------------------------------------------------
CREATE TABLE merchants (
    merchant_id    BIGINT       GENERATED ALWAYS AS IDENTITY,
    business_name  VARCHAR(100) NOT NULL,
    cac_number     VARCHAR(10)  NOT NULL,
    category       VARCHAR(20)  NOT NULL,
    email          VARCHAR(254) NOT NULL,
    status         VARCHAR(10)  NOT NULL DEFAULT 'active',
    created_at     TIMESTAMPTZ  NOT NULL DEFAULT now(),

    CONSTRAINT merchants_pkey            PRIMARY KEY (merchant_id),
    CONSTRAINT merchants_cac_number_key  UNIQUE (cac_number),
    CONSTRAINT merchants_email_key       UNIQUE (email),
    CONSTRAINT merchants_cac_format      CHECK (cac_number ~ '^(RC|BN)[0-9]{5,8}$'),
    CONSTRAINT merchants_email_format    CHECK (email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
    CONSTRAINT merchants_category_valid  CHECK (category IN ('groceries', 'restaurant', 'transport',
                                                             'utilities', 'airtime_data', 'fashion',
                                                             'pharmacy', 'education', 'entertainment',
                                                             'electronics')),
    CONSTRAINT merchants_status_valid    CHECK (status IN ('active', 'suspended'))
);

-- ---------------------------------------------------------------------
-- kyc_documents: identity and address documents a customer submits.
-- One row per real-world document, so the same BVN or NIN can never be
-- attached to two customers.
-- ON DELETE CASCADE: the documents belong to the customer. A customer row
-- can only be deleted when no wallet exists (wallets use RESTRICT), e.g. an
-- abandoned sign-up or an erasure request, and then the documents must go too.
-- ---------------------------------------------------------------------
CREATE TABLE kyc_documents (
    document_id      BIGINT      GENERATED ALWAYS AS IDENTITY,
    customer_id      BIGINT      NOT NULL,
    document_type    VARCHAR(20) NOT NULL,
    document_number  VARCHAR(20) NOT NULL,
    expiry_date      DATE,
    status           VARCHAR(10) NOT NULL DEFAULT 'submitted',
    submitted_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    reviewed_at      TIMESTAMPTZ,
    -- Username of the compliance officer. Staff accounts live in the Proclus
    -- staff directory, outside this database, so this is not a foreign key.
    reviewed_by      VARCHAR(50),

    CONSTRAINT kyc_documents_pkey         PRIMARY KEY (document_id),
    CONSTRAINT kyc_documents_number_key   UNIQUE (document_type, document_number),
    CONSTRAINT kyc_documents_customer_fk  FOREIGN KEY (customer_id)
        REFERENCES customers (customer_id) ON DELETE CASCADE,
    CONSTRAINT kyc_documents_type_valid   CHECK (document_type IN ('bvn', 'nin', 'passport',
                                                                   'drivers_licence', 'voters_card',
                                                                   'utility_bill')),
    CONSTRAINT kyc_documents_status_valid CHECK (status IN ('submitted', 'verified', 'rejected')),
    -- BVN (Bank Verification Number) and NIN (National Identification Number) are both 11 digits.
    CONSTRAINT kyc_documents_bvn_nin_format CHECK (document_type NOT IN ('bvn', 'nin')
                                                   OR document_number ~ '^[0-9]{11}$'),
    -- Only passports and driving licences carry an expiry date.
    CONSTRAINT kyc_documents_expiry_only_for_expiring_ids
        CHECK (expiry_date IS NULL OR document_type IN ('passport', 'drivers_licence')),
    -- A document is either waiting for review (no reviewer, no review time)
    -- or reviewed (both recorded). Nothing in between.
    CONSTRAINT kyc_documents_review_recorded
        CHECK ((status = 'submitted') = (reviewed_at IS NULL)
               AND (reviewed_at IS NULL) = (reviewed_by IS NULL)),
    CONSTRAINT kyc_documents_review_after_submit
        CHECK (reviewed_at IS NULL OR reviewed_at >= submitted_at)
);

-- ---------------------------------------------------------------------
-- wallets: naira wallets. A customer has a main wallet and may open one
-- savings wallet, so (customer_id, wallet_type) is a second candidate key.
--
-- balance is a DELIBERATE DENORMALISATION: it can be derived from the
-- completed rows in transactions. It is stored so that a balance check is
-- one row read, and so the CHECK (balance >= 0) below stops an overdraft
-- inside the database itself. Portfolio 3 keeps it correct under
-- concurrency; 02_sample_data.sql ends with a balance audit against the ledger.
--
-- ON DELETE RESTRICT: a customer who owns a wallet cannot be deleted.
-- Financial records must outlive the customer relationship, so accounts
-- are closed with status = 'closed', never deleted.
-- ---------------------------------------------------------------------
CREATE TABLE wallets (
    wallet_id      BIGINT        GENERATED ALWAYS AS IDENTITY,
    customer_id    BIGINT        NOT NULL,
    wallet_number  CHAR(10)      NOT NULL,
    wallet_type    VARCHAR(10)   NOT NULL DEFAULT 'main',
    balance        NUMERIC(14,2) NOT NULL DEFAULT 0.00,
    status         VARCHAR(10)   NOT NULL DEFAULT 'active',
    created_at     TIMESTAMPTZ   NOT NULL DEFAULT now(),

    CONSTRAINT wallets_pkey                 PRIMARY KEY (wallet_id),
    CONSTRAINT wallets_wallet_number_key    UNIQUE (wallet_number),
    CONSTRAINT wallets_one_per_type_key     UNIQUE (customer_id, wallet_type),
    CONSTRAINT wallets_customer_fk          FOREIGN KEY (customer_id)
        REFERENCES customers (customer_id) ON DELETE RESTRICT,
    -- 10-digit number, the same length as a Nigerian bank account number (NUBAN).
    CONSTRAINT wallets_wallet_number_format CHECK (wallet_number ~ '^[0-9]{10}$'),
    CONSTRAINT wallets_wallet_type_valid    CHECK (wallet_type IN ('main', 'savings')),
    CONSTRAINT wallets_balance_non_negative CHECK (balance >= 0),
    CONSTRAINT wallets_status_valid         CHECK (status IN ('active', 'frozen', 'closed'))
);

-- ---------------------------------------------------------------------
-- transfers: a request to move money from one wallet to another.
--   pending   : created and held for review; no money has moved yet
--   completed : sender debited and receiver credited (two ledger rows)
--   failed    : rejected before any money moved (no ledger rows)
--   reversed  : sender was debited, the credit could not be applied, and
--               the money was returned with a 'reversal' ledger row
-- ON DELETE RESTRICT on both wallets: a wallet with transfer history
-- cannot be deleted.
-- ---------------------------------------------------------------------
CREATE TABLE transfers (
    transfer_id         BIGINT        GENERATED ALWAYS AS IDENTITY,
    reference           VARCHAR(20)   NOT NULL,
    sender_wallet_id    BIGINT        NOT NULL,
    receiver_wallet_id  BIGINT        NOT NULL,
    amount              NUMERIC(14,2) NOT NULL,
    narration           VARCHAR(100),
    status              VARCHAR(10)   NOT NULL DEFAULT 'pending',
    failure_reason      VARCHAR(200),
    created_at          TIMESTAMPTZ   NOT NULL DEFAULT now(),
    processed_at        TIMESTAMPTZ,

    CONSTRAINT transfers_pkey              PRIMARY KEY (transfer_id),
    CONSTRAINT transfers_reference_key     UNIQUE (reference),
    CONSTRAINT transfers_sender_fk         FOREIGN KEY (sender_wallet_id)
        REFERENCES wallets (wallet_id) ON DELETE RESTRICT,
    CONSTRAINT transfers_receiver_fk       FOREIGN KEY (receiver_wallet_id)
        REFERENCES wallets (wallet_id) ON DELETE RESTRICT,
    CONSTRAINT transfers_amount_positive   CHECK (amount > 0),
    CONSTRAINT transfers_different_wallets CHECK (sender_wallet_id <> receiver_wallet_id),
    CONSTRAINT transfers_status_valid      CHECK (status IN ('pending', 'completed', 'failed', 'reversed')),
    -- A failed or reversed transfer must say why; any other must not.
    CONSTRAINT transfers_failure_reason_required
        CHECK ((status IN ('failed', 'reversed')) = (failure_reason IS NOT NULL)),
    -- processed_at is set exactly when the transfer leaves 'pending'.
    CONSTRAINT transfers_processed_at_matches_status
        CHECK ((status = 'pending') = (processed_at IS NULL)),
    CONSTRAINT transfers_processed_after_created
        CHECK (processed_at IS NULL OR processed_at >= created_at)
);

-- ---------------------------------------------------------------------
-- transactions: the ledger. One row per movement of money on one wallet.
-- amount is always positive; the direction follows from transaction_type
-- (funding, transfer_in and reversal are credits; transfer_out and
-- merchant_payment are debits). Direction is not stored, because
-- transaction_type -> direction would be a transitive dependency.
-- Only 'completed' rows count towards a balance.
--
-- ON DELETE RESTRICT on all three foreign keys: ledger rows are never
-- removed, so nothing they point at can be deleted either.
-- ---------------------------------------------------------------------
CREATE TABLE transactions (
    transaction_id    BIGINT        GENERATED ALWAYS AS IDENTITY,
    reference         VARCHAR(20)   NOT NULL,
    wallet_id         BIGINT        NOT NULL,
    transaction_type  VARCHAR(20)   NOT NULL,
    amount            NUMERIC(14,2) NOT NULL,
    status            VARCHAR(10)   NOT NULL DEFAULT 'completed',
    transfer_id       BIGINT,
    merchant_id       BIGINT,
    narration         VARCHAR(100),
    created_at        TIMESTAMPTZ   NOT NULL DEFAULT now(),

    CONSTRAINT transactions_pkey                 PRIMARY KEY (transaction_id),
    CONSTRAINT transactions_reference_key        UNIQUE (reference),
    -- At most one debit, one credit and one reversal per transfer.
    -- (NULLs are distinct, so rows without a transfer are unaffected.)
    CONSTRAINT transactions_one_leg_per_type_key UNIQUE (transfer_id, transaction_type),
    CONSTRAINT transactions_wallet_fk            FOREIGN KEY (wallet_id)
        REFERENCES wallets (wallet_id) ON DELETE RESTRICT,
    CONSTRAINT transactions_transfer_fk          FOREIGN KEY (transfer_id)
        REFERENCES transfers (transfer_id) ON DELETE RESTRICT,
    CONSTRAINT transactions_merchant_fk          FOREIGN KEY (merchant_id)
        REFERENCES merchants (merchant_id) ON DELETE RESTRICT,
    CONSTRAINT transactions_amount_positive      CHECK (amount > 0),
    CONSTRAINT transactions_type_valid           CHECK (transaction_type IN ('funding', 'transfer_out',
                                                                             'transfer_in', 'merchant_payment',
                                                                             'reversal')),
    CONSTRAINT transactions_status_valid         CHECK (status IN ('pending', 'completed', 'failed')),
    -- Transfer legs and reversals must point at their transfer; nothing else may.
    CONSTRAINT transactions_transfer_link
        CHECK ((transaction_type IN ('transfer_out', 'transfer_in', 'reversal')) = (transfer_id IS NOT NULL)),
    -- Merchant payments must name the merchant; nothing else may.
    CONSTRAINT transactions_merchant_link
        CHECK ((transaction_type = 'merchant_payment') = (merchant_id IS NOT NULL))
);

-- ---------------------------------------------------------------------
-- beneficiaries: wallets a customer has saved for quick transfers.
-- An associative entity between customers (the owner) and wallets (the
-- saved destination). It is a shortcut only: transfers store the receiver
-- wallet directly, not the beneficiary.
-- ON DELETE CASCADE on both sides: a saved shortcut means nothing once
-- either its owner or its destination wallet no longer exists.
-- ---------------------------------------------------------------------
CREATE TABLE beneficiaries (
    beneficiary_id  BIGINT      GENERATED ALWAYS AS IDENTITY,
    customer_id     BIGINT      NOT NULL,
    wallet_id       BIGINT      NOT NULL,
    nickname        VARCHAR(50) NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT beneficiaries_pkey            PRIMARY KEY (beneficiary_id),
    CONSTRAINT beneficiaries_wallet_once_key UNIQUE (customer_id, wallet_id),
    CONSTRAINT beneficiaries_nickname_key    UNIQUE (customer_id, nickname),
    CONSTRAINT beneficiaries_customer_fk     FOREIGN KEY (customer_id)
        REFERENCES customers (customer_id) ON DELETE CASCADE,
    CONSTRAINT beneficiaries_wallet_fk       FOREIGN KEY (wallet_id)
        REFERENCES wallets (wallet_id) ON DELETE CASCADE
);

-- ---------------------------------------------------------------------
-- audit_log: append-only record of decisions made by staff or by the
-- system (KYC reviews, status changes, failed, held and reversed
-- transfers, balance audits). Money movements themselves are already
-- recorded in transactions.
-- No foreign keys, on purpose: entity_id points at a different table
-- depending on entity_type, and an audit row must survive even if the row
-- it describes is later removed. entity_id is empty only for a balance
-- audit, which covers every wallet at once.
-- The pair (entity_type, entity_id) names the row, and the pair
-- (actor_type, actor_ref) names who acted: an id or username is only
-- unique inside its own table or namespace. action is a plain verb that
-- several entity types share, so action does not determine entity_type
-- (that dependency would break 3NF).
-- ---------------------------------------------------------------------
CREATE TABLE audit_log (
    audit_id     BIGINT       GENERATED ALWAYS AS IDENTITY,
    entity_type  VARCHAR(20)  NOT NULL,
    entity_id    BIGINT,
    action       VARCHAR(30)  NOT NULL,
    actor_type   VARCHAR(10)  NOT NULL,
    actor_ref    VARCHAR(50)  NOT NULL,
    details      VARCHAR(255),
    created_at   TIMESTAMPTZ  NOT NULL DEFAULT now(),

    CONSTRAINT audit_log_pkey              PRIMARY KEY (audit_id),
    CONSTRAINT audit_log_entity_type_valid CHECK (entity_type IN ('customer', 'kyc_document', 'wallet',
                                                                  'transfer', 'transaction', 'merchant',
                                                                  'beneficiary')),
    CONSTRAINT audit_log_action_valid      CHECK (action IN ('status_changed', 'verified', 'rejected',
                                                             'held', 'failed', 'reversed', 'audited')),
    CONSTRAINT audit_log_actor_type_valid  CHECK (actor_type IN ('customer', 'staff', 'system')),
    CONSTRAINT audit_log_entity_id_required CHECK (entity_id IS NOT NULL OR action = 'audited')
);

-- Comments show up in pgAdmin and in the output of psql's \d+ command.
COMMENT ON TABLE  customers     IS 'People who hold Proclus wallets.';
COMMENT ON TABLE  merchants     IS 'Businesses that customers pay from their wallets.';
COMMENT ON TABLE  kyc_documents IS 'Identity and address documents submitted for KYC verification.';
COMMENT ON TABLE  wallets       IS 'Naira wallets; one main and at most one savings wallet per customer.';
COMMENT ON TABLE  transfers     IS 'Wallet-to-wallet transfer requests and their outcome.';
COMMENT ON TABLE  transactions  IS 'Ledger: one row per money movement on one wallet.';
COMMENT ON TABLE  beneficiaries IS 'Wallets a customer has saved for quick transfers.';
COMMENT ON TABLE  audit_log     IS 'Append-only log of staff and system decisions.';
COMMENT ON COLUMN wallets.balance IS
    'Deliberate denormalisation: equals completed credits minus completed debits in transactions.';
COMMENT ON COLUMN transactions.amount IS
    'Always positive. Direction comes from transaction_type.';
COMMENT ON COLUMN customers.kyc_tier IS
    '1 = phone and name, 2 = BVN or NIN verified, 3 = ID and address verified.';

COMMIT;
