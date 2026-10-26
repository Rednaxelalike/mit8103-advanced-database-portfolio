-- =====================================================================
-- Portfolio 4: NoSQL and advanced data models
-- 00_export_p1_documents.sql  Turns the Portfolio 1 sample data into the
--                             MongoDB documents of the Proclus model, one
--                             JSON file per collection in model/documents/.
--
-- Run from the repo root (see SETUP.md for loading PGPASSWORD):
--   psql -X -w -U postgres -h localhost -p 5432 -d proclus -v ON_ERROR_STOP=1
--        -f portfolio-4-nosql/scripts/00_export_p1_documents.sql
--
-- Re-runnable: it starts by running the Portfolio 1 schema and sample data
-- scripts, so the documents always come from the same 20 customers, 25
-- wallets, 12 transfers and 47 ledger rows as every other portfolio.
-- The JSON files are committed, so 01_seed.js does not need PostgreSQL.
--
-- How the eight tables become six collections
--   customers     <- customers, with kyc_documents and beneficiaries
--                    embedded as arrays (owned by the customer, bounded,
--                    and read together with the profile)
--   wallets       <- wallets (own collection: the balance changes on every
--                    payment and is the field Portfolio 3 protects)
--   merchants     <- merchants
--   transfers     <- transfers
--   transactions  <- transactions (referenced, never embedded: the ledger
--                    grows without limit). Each type carries only its own
--                    fields: transfer legs and reversals a transfer
--                    sub-document, merchant payments a merchant snapshot.
--   audit_log     <- audit_log
--
-- Format: MongoDB Extended JSON, one document per line. Money is
-- {"$numberDecimal": "..."} (Decimal128, never a binary double, for the
-- same reason Portfolio 1 uses NUMERIC), times are {"$date": "...Z"} in
-- UTC, and dates without a time are midnight UTC. A column that is NULL
-- is left out of the document instead of being stored as null.
-- The primary key of each table becomes _id; every other column keeps
-- its Portfolio 1 name.
-- =====================================================================

\ir ../../portfolio-1-database-design/sql/01_schema.sql
\ir ../../portfolio-1-database-design/sql/02_sample_data.sql

-- Extended JSON helpers, dropped with the session.
CREATE FUNCTION pg_temp.ej_time(t timestamptz) RETURNS json LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN t IS NOT NULL
                THEN json_build_object('$date', to_char(t AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'))
           END
$$;
CREATE FUNCTION pg_temp.ej_date(d date) RETURNS json LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN d IS NOT NULL
                THEN json_build_object('$date', to_char(d, 'YYYY-MM-DD"T00:00:00.000Z"'))
           END
$$;
CREATE FUNCTION pg_temp.ej_money(m numeric) RETURNS json LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN m IS NOT NULL THEN json_build_object('$numberDecimal', m::text) END
$$;

-- Bare output: no headers, no row counts, nothing but the JSON.
\pset format unaligned
\pset tuples_only on

-- customers: the profile with its KYC documents and saved beneficiaries.
\o portfolio-4-nosql/model/documents/customers.json
SELECT '[' || string_agg(doc::text, E',\n' ORDER BY customer_id) || ']'
FROM (
    SELECT c.customer_id,
           json_strip_nulls(json_build_object(
               '_id', c.customer_id,
               'first_name', c.first_name,
               'last_name', c.last_name,
               'email', c.email,
               'phone_number', c.phone_number,
               'date_of_birth', pg_temp.ej_date(c.date_of_birth),
               'kyc_tier', c.kyc_tier,
               'status', c.status,
               'created_at', pg_temp.ej_time(c.created_at),
               'kyc_documents', coalesce((
                   SELECT json_agg(json_build_object(
                              'document_id', k.document_id,
                              'document_type', k.document_type,
                              'document_number', k.document_number,
                              'expiry_date', pg_temp.ej_date(k.expiry_date),
                              'status', k.status,
                              'submitted_at', pg_temp.ej_time(k.submitted_at),
                              'reviewed_at', pg_temp.ej_time(k.reviewed_at),
                              'reviewed_by', k.reviewed_by) ORDER BY k.document_id)
                   FROM kyc_documents k WHERE k.customer_id = c.customer_id), '[]'),
               'beneficiaries', coalesce((
                   SELECT json_agg(json_build_object(
                              'beneficiary_id', b.beneficiary_id,
                              'wallet_id', b.wallet_id,
                              'nickname', b.nickname,
                              'created_at', pg_temp.ej_time(b.created_at)) ORDER BY b.beneficiary_id)
                   FROM beneficiaries b WHERE b.customer_id = c.customer_id), '[]')
           )) AS doc
    FROM customers c
) d;

\o portfolio-4-nosql/model/documents/wallets.json
SELECT '[' || string_agg(json_strip_nulls(json_build_object(
           '_id', wallet_id,
           'customer_id', customer_id,
           'wallet_number', wallet_number,
           'wallet_type', wallet_type,
           'balance', pg_temp.ej_money(balance),
           'status', status,
           'created_at', pg_temp.ej_time(created_at)))::text, E',\n' ORDER BY wallet_id) || ']'
FROM wallets;

\o portfolio-4-nosql/model/documents/merchants.json
SELECT '[' || string_agg(json_strip_nulls(json_build_object(
           '_id', merchant_id,
           'business_name', business_name,
           'cac_number', cac_number,
           'category', category,
           'email', email,
           'status', status,
           'created_at', pg_temp.ej_time(created_at)))::text, E',\n' ORDER BY merchant_id) || ']'
FROM merchants;

\o portfolio-4-nosql/model/documents/transfers.json
SELECT '[' || string_agg(json_strip_nulls(json_build_object(
           '_id', transfer_id,
           'reference', reference,
           'sender_wallet_id', sender_wallet_id,
           'receiver_wallet_id', receiver_wallet_id,
           'amount', pg_temp.ej_money(amount),
           'narration', narration,
           'status', status,
           'failure_reason', failure_reason,
           'created_at', pg_temp.ej_time(created_at),
           'processed_at', pg_temp.ej_time(processed_at)))::text, E',\n' ORDER BY transfer_id) || ']'
FROM transfers;

-- transactions: the ledger. The transfer and merchant sub-documents are
-- copies of fields that never change after the row is written (a transfer
-- reference; a merchant's name and category at the time of payment), so a
-- statement can be printed without a $lookup.
\o portfolio-4-nosql/model/documents/transactions.json
SELECT '[' || string_agg(json_strip_nulls(json_build_object(
           '_id', t.transaction_id,
           'reference', t.reference,
           'wallet_id', t.wallet_id,
           'transaction_type', t.transaction_type,
           'amount', pg_temp.ej_money(t.amount),
           'status', t.status,
           'transfer', CASE WHEN t.transfer_id IS NOT NULL
                            THEN json_build_object('transfer_id', tr.transfer_id, 'reference', tr.reference) END,
           'merchant', CASE WHEN t.merchant_id IS NOT NULL
                            THEN json_build_object('merchant_id', m.merchant_id,
                                                   'business_name', m.business_name,
                                                   'category', m.category) END,
           'narration', t.narration,
           'created_at', pg_temp.ej_time(t.created_at)))::text, E',\n' ORDER BY t.transaction_id) || ']'
FROM transactions t
LEFT JOIN transfers tr USING (transfer_id)
LEFT JOIN merchants m USING (merchant_id);

\o portfolio-4-nosql/model/documents/audit_log.json
SELECT '[' || string_agg(json_strip_nulls(json_build_object(
           '_id', audit_id,
           'entity_type', entity_type,
           'entity_id', entity_id,
           'action', action,
           'actor_type', actor_type,
           'actor_ref', actor_ref,
           'details', details,
           'created_at', pg_temp.ej_time(created_at)))::text, E',\n' ORDER BY audit_id) || ']'
FROM audit_log;

\o
\pset format aligned
\pset tuples_only off

-- What was exported: one row per collection.
SELECT 'customers' AS collection, count(*) AS documents,
       (SELECT count(*) FROM kyc_documents) AS embedded_kyc_documents,
       (SELECT count(*) FROM beneficiaries) AS embedded_beneficiaries
FROM customers
UNION ALL SELECT 'wallets', count(*), NULL, NULL FROM wallets
UNION ALL SELECT 'merchants', count(*), NULL, NULL FROM merchants
UNION ALL SELECT 'transfers', count(*), NULL, NULL FROM transfers
UNION ALL SELECT 'transactions', count(*), NULL, NULL FROM transactions
UNION ALL SELECT 'audit_log', count(*), NULL, NULL FROM audit_log;
