-- =====================================================================
-- Portfolio 1: Database design and modelling
-- 02_sample_data.sql  Loads realistic sample data for Proclus.
--
-- Run after 01_schema.sql, from the repo root:
--   psql -w -U postgres -h localhost -p 5432 -d proclus -v ON_ERROR_STOP=1
--        -f portfolio-1-database-design/sql/02_sample_data.sql
--
-- Re-runnable: every table is emptied first and its identity counter reset.
-- All rows are fictional. Names are common Nigerian names, emails use the
-- reserved example.com domain, and amounts are in naira (NGN).
-- Times are Lagos time (+01), from August to 8 October 2026.
--
-- Ids are given explicitly (OVERRIDING SYSTEM VALUE) for the tables that
-- other rows point at, so the foreign keys below are easy to read. The
-- identity counters are moved past those ids at the end, so new rows in
-- later portfolios get fresh ids.
--
-- wallets.balance is the deliberate denormalisation. Each value below
-- equals the completed credits minus completed debits for that wallet in
-- the transactions block; the balance audit at the end of the script
-- proves it and stops the script if any wallet disagrees.
-- =====================================================================

BEGIN;

TRUNCATE audit_log, beneficiaries, transactions, transfers,
         kyc_documents, wallets, merchants, customers RESTART IDENTITY;

-- 20 customers: tiers 1 to 3, one suspended (customer 18).
INSERT INTO customers (customer_id, first_name, last_name, email, phone_number,
                       date_of_birth, kyc_tier, status, created_at)
OVERRIDING SYSTEM VALUE VALUES
    ( 1, 'Chinedu', 'Okafor', 'chinedu.okafor@example.com', '+2348031000001', '1990-03-14', 3, 'active', '2026-08-01 09:12+01'),
    ( 2, 'Aisha', 'Bello', 'aisha.bello@example.com', '+2348051000002', '1994-07-22', 2, 'active', '2026-08-02 10:40+01'),
    ( 3, 'Oluwaseun', 'Adeyemi', 'seun.adeyemi@example.com', '+2347061000003', '1988-11-05', 3, 'active', '2026-08-03 08:05+01'),
    ( 4, 'Ngozi', 'Eze', 'ngozi.eze@example.com', '+2348091000004', '1996-01-30', 2, 'active', '2026-08-04 13:22+01'),
    ( 5, 'Ibrahim', 'Musa', 'ibrahim.musa@example.com', '+2349031000005', '1985-09-18', 3, 'active', '2026-08-05 11:47+01'),
    ( 6, 'Funmilayo', 'Adebayo', 'funmi.adebayo@example.com', '+2348131000006', '1999-04-02', 1, 'active', '2026-08-06 19:03+01'),
    ( 7, 'Emeka', 'Nwosu', 'emeka.nwosu@example.com', '+2348161000007', '1992-12-11', 2, 'active', '2026-08-07 07:58+01'),
    ( 8, 'Zainab', 'Abubakar', 'zainab.abubakar@example.com', '+2347031000008', '1997-06-25', 2, 'active', '2026-08-08 15:31+01'),
    ( 9, 'Tunde', 'Bakare', 'tunde.bakare@example.com', '+2348021000009', '1979-02-08', 3, 'active', '2026-08-09 09:44+01'),
    (10, 'Chiamaka', 'Obi', 'chiamaka.obi@example.com', '+2349061000010', '2001-10-17', 1, 'active', '2026-08-10 21:16+01'),
    (11, 'Yusuf', 'Danjuma', 'yusuf.danjuma@example.com', '+2348101000011', '1991-05-29', 2, 'active', '2026-08-11 12:09+01'),
    (12, 'Temitope', 'Ogunleye', 'temi.ogunleye@example.com', '+2347081000012', '1995-08-13', 2, 'active', '2026-08-12 16:50+01'),
    (13, 'Ifeanyi', 'Okonkwo', 'ifeanyi.okonkwo@example.com', '+2348061000013', '1987-03-03', 3, 'active', '2026-08-13 10:27+01'),
    (14, 'Hauwa', 'Ibrahim', 'hauwa.ibrahim@example.com', '+2349011000014', '2000-11-21', 1, 'active', '2026-08-14 18:35+01'),
    (15, 'Babajide', 'Olatunji', 'jide.olatunji@example.com', '+2348171000015', '1993-02-14', 2, 'active', '2026-08-15 08:18+01'),
    (16, 'Amarachi', 'Nnamdi', 'amara.nnamdi@example.com', '+2347011000016', '1998-09-09', 2, 'active', '2026-08-16 14:02+01'),
    (17, 'Segun', 'Afolabi', 'segun.afolabi@example.com', '+2348111000017', '1983-07-07', 3, 'active', '2026-08-17 09:36+01'),
    (18, 'Halima', 'Sani', 'halima.sani@example.com', '+2349051000018', '1999-12-31', 1, 'suspended', '2026-08-18 20:44+01'),
    (19, 'Kelechi', 'Uche', 'kelechi.uche@example.com', '+2348141000019', '1994-04-19', 2, 'active', '2026-08-19 11:13+01'),
    (20, 'Folake', 'Akinwale', 'folake.akinwale@example.com', '+2347051000020', '2002-06-06', 1, 'active', '2026-08-20 17:29+01');

-- 12 merchants across Lagos; one suspended (merchant 12).
INSERT INTO merchants (merchant_id, business_name, cac_number, category, email, status, created_at)
OVERRIDING SYSTEM VALUE VALUES
    ( 1, 'Lekki Fresh Mart', 'RC1482736', 'groceries', 'payments@lekkifreshmart.example.com', 'active', '2026-07-02 10:00+01'),
    ( 2, 'Mama Tolu Kitchen', 'BN2390417', 'restaurant', 'hello@mamatolukitchen.example.com', 'active', '2026-07-03 11:30+01'),
    ( 3, 'Yaba Suya Spot', 'BN3017728', 'restaurant', 'orders@yabasuyaspot.example.com', 'active', '2026-07-05 16:45+01'),
    ( 4, 'Eko Power Vending', 'RC1739025', 'utilities', 'billing@ekopowervending.example.com', 'active', '2026-07-06 09:15+01'),
    ( 5, 'Danfo Express Rides', 'RC1620374', 'transport', 'rides@danfoexpress.example.com', 'active', '2026-07-08 07:20+01'),
    ( 6, 'Ojota Data Hub', 'BN2844105', 'airtime_data', 'sales@ojotadatahub.example.com', 'active', '2026-07-09 13:05+01'),
    ( 7, 'Balogun Fabrics House', 'BN1975360', 'fashion', 'shop@balogunfabrics.example.com', 'active', '2026-07-11 12:40+01'),
    ( 8, 'Ikeja Wellness Pharmacy', 'RC1556089', 'pharmacy', 'care@ikejawellness.example.com', 'active', '2026-07-14 08:55+01'),
    ( 9, 'Festac Learning Centre', 'RC1398412', 'education', 'admissions@festaclearning.example.com', 'active', '2026-07-16 10:10+01'),
    (10, 'Computer Village Gadgets', 'RC1802263', 'electronics', 'sales@cvgadgets.example.com', 'active', '2026-07-18 14:25+01'),
    (11, 'Marina Screens Cinema', 'RC1914470', 'entertainment', 'tickets@marinascreens.example.com', 'active', '2026-07-21 18:00+01'),
    (12, 'Agege Bread Bakery', 'BN3120956', 'groceries', 'orders@agegebread.example.com', 'suspended', '2026-07-23 06:30+01');

-- 31 KYC documents. Tier 2 customers have a verified BVN or NIN; tier 3 customers
-- also have a verified photo ID or NIN and a utility bill. Two are still waiting
-- for review and two were rejected.
INSERT INTO kyc_documents (document_id, customer_id, document_type, document_number, expiry_date,
                           status, submitted_at, reviewed_at, reviewed_by)
OVERRIDING SYSTEM VALUE VALUES
    ( 1,  1, 'bvn', '22140583921', NULL, 'verified', '2026-08-01 09:20+01', '2026-08-01 14:05+01', 'compliance.adaeze'),
    ( 2,  1, 'nin', '40817263950', NULL, 'verified', '2026-08-01 09:24+01', '2026-08-01 14:08+01', 'compliance.adaeze'),
    ( 3,  1, 'utility_bill', 'EKEDC-0816-44721', NULL, 'verified', '2026-08-02 08:10+01', '2026-08-02 11:40+01', 'compliance.olumide'),
    ( 4,  2, 'bvn', '22371940586', NULL, 'verified', '2026-08-02 10:48+01', '2026-08-02 15:12+01', 'compliance.olumide'),
    ( 5,  3, 'bvn', '22508314769', NULL, 'verified', '2026-08-03 08:12+01', '2026-08-03 10:30+01', 'compliance.fatima'),
    ( 6,  3, 'passport', 'B03918274', '2031-05-10', 'verified', '2026-08-03 08:15+01', '2026-08-03 10:34+01', 'compliance.fatima'),
    ( 7,  3, 'utility_bill', 'IKEDC-0803-91853', NULL, 'verified', '2026-08-03 08:19+01', '2026-08-03 10:41+01', 'compliance.fatima'),
    ( 8,  4, 'nin', '51263870412', NULL, 'verified', '2026-08-04 13:30+01', '2026-08-04 16:55+01', 'compliance.adaeze'),
    ( 9,  5, 'bvn', '22619047385', NULL, 'verified', '2026-08-05 11:52+01', '2026-08-05 15:20+01', 'compliance.olumide'),
    (10,  5, 'drivers_licence', 'LAG58302AB41', '2028-09-17', 'verified', '2026-08-05 11:56+01', '2026-08-05 15:26+01', 'compliance.olumide'),
    (11,  5, 'utility_bill', 'EKEDC-0805-17364', NULL, 'verified', '2026-08-05 12:01+01', '2026-08-05 15:31+01', 'compliance.olumide'),
    (12,  6, 'bvn', '22730581946', NULL, 'submitted', '2026-10-06 19:20+01', NULL, NULL),
    (13,  7, 'bvn', '22846192730', NULL, 'verified', '2026-08-07 08:04+01', '2026-08-07 12:16+01', 'compliance.fatima'),
    (14,  7, 'utility_bill', 'IKEDC-0807-53018', NULL, 'rejected', '2026-08-07 08:09+01', '2026-08-07 12:21+01', 'compliance.fatima'),
    (15,  8, 'nin', '62917305841', NULL, 'verified', '2026-08-08 15:40+01', '2026-08-09 09:05+01', 'compliance.adaeze'),
    (16,  9, 'bvn', '22953817604', NULL, 'verified', '2026-08-09 09:50+01', '2026-08-09 13:02+01', 'compliance.olumide'),
    (17,  9, 'voters_card', '90F5B04A7C29475830', NULL, 'verified', '2026-08-09 09:53+01', '2026-08-09 13:07+01', 'compliance.olumide'),
    (18,  9, 'utility_bill', 'EKEDC-0809-60295', NULL, 'verified', '2026-08-09 09:58+01', '2026-08-09 13:11+01', 'compliance.olumide'),
    (19, 11, 'bvn', '22164930278', NULL, 'verified', '2026-08-11 12:15+01', '2026-08-11 16:44+01', 'compliance.fatima'),
    (20, 12, 'bvn', '22285716039', NULL, 'verified', '2026-08-12 16:58+01', '2026-08-13 09:10+01', 'compliance.adaeze'),
    (21, 12, 'nin', '73048296157', NULL, 'submitted', '2026-10-07 18:22+01', NULL, NULL),
    (22, 13, 'bvn', '22397405182', NULL, 'verified', '2026-08-13 10:33+01', '2026-08-13 14:18+01', 'compliance.olumide'),
    (23, 13, 'nin', '84159307264', NULL, 'verified', '2026-08-13 10:36+01', '2026-08-13 14:21+01', 'compliance.olumide'),
    (24, 13, 'utility_bill', 'IKEDC-0813-28476', NULL, 'verified', '2026-08-13 10:41+01', '2026-08-13 14:26+01', 'compliance.olumide'),
    (25, 14, 'nin', '95260418373', NULL, 'rejected', '2026-08-14 18:41+01', '2026-08-15 10:02+01', 'compliance.fatima'),
    (26, 15, 'bvn', '22418562093', NULL, 'verified', '2026-08-15 08:25+01', '2026-08-15 12:47+01', 'compliance.adaeze'),
    (27, 16, 'nin', '16371529480', NULL, 'verified', '2026-08-16 14:10+01', '2026-08-16 17:35+01', 'compliance.fatima'),
    (28, 17, 'bvn', '22529673014', NULL, 'verified', '2026-08-17 09:41+01', '2026-08-17 13:58+01', 'compliance.olumide'),
    (29, 17, 'passport', 'A07264519', '2029-03-01', 'verified', '2026-08-17 09:45+01', '2026-08-17 14:02+01', 'compliance.olumide'),
    (30, 17, 'utility_bill', 'EKEDC-0817-39507', NULL, 'verified', '2026-08-17 09:50+01', '2026-08-17 14:06+01', 'compliance.olumide'),
    (31, 19, 'bvn', '22630784125', NULL, 'verified', '2026-08-19 11:20+01', '2026-08-19 15:33+01', 'compliance.adaeze');

-- 25 wallets: a main wallet for every customer (wallet_id = customer_id for
-- wallets 1-20) and savings wallets 21-25. Wallet 18 is frozen.
-- Balances are the ledger totals of the transactions inserted below.
INSERT INTO wallets (wallet_id, customer_id, wallet_number, wallet_type, balance, status, created_at)
OVERRIDING SYSTEM VALUE VALUES
    ( 1,  1, '5012748390', 'main',     102549.50, 'active', '2026-08-01 09:14+01'),
    ( 2,  2, '5026193047', 'main',      23500.00, 'active', '2026-08-02 10:42+01'),
    ( 3,  3, '5031857264', 'main',     146800.00, 'active', '2026-08-03 08:07+01'),
    ( 4,  4, '5049320581', 'main',      45000.00, 'active', '2026-08-04 13:24+01'),
    ( 5,  5, '5053716928', 'main',     300000.00, 'active', '2026-08-05 11:49+01'),
    ( 6,  6, '5068241095', 'main',          0.00, 'active', '2026-08-06 19:05+01'),
    ( 7,  7, '5074592316', 'main',      65000.00, 'active', '2026-08-07 08:00+01'),
    ( 8,  8, '5085013742', 'main',      50000.00, 'active', '2026-08-08 15:33+01'),
    ( 9,  9, '5091648257', 'main',     265000.00, 'active', '2026-08-09 09:46+01'),
    (10, 10, '5103927485', 'main',          0.00, 'active', '2026-08-10 21:18+01'),
    (11, 11, '5117460293', 'main',      63000.00, 'active', '2026-08-11 12:11+01'),
    (12, 12, '5120835649', 'main',      38000.00, 'active', '2026-08-12 16:52+01'),
    (13, 13, '5138571206', 'main',     137249.75, 'active', '2026-08-13 10:29+01'),
    (14, 14, '5142096837', 'main',          0.00, 'active', '2026-08-14 18:37+01'),
    (15, 15, '5156382910', 'main',      80000.00, 'active', '2026-08-15 08:20+01'),
    (16, 16, '5167024583', 'main',      25200.00, 'active', '2026-08-16 14:04+01'),
    (17, 17, '5179351648', 'main',     225000.00, 'active', '2026-08-17 09:38+01'),
    (18, 18, '5184627039', 'main',          0.00, 'frozen', '2026-08-18 20:46+01'),
    (19, 19, '5190736452', 'main',      34700.00, 'active', '2026-08-19 11:15+01'),
    (20, 20, '5203485917', 'main',          0.00, 'active', '2026-08-20 17:31+01'),
    (21,  1, '6012748391', 'savings',       0.00, 'active', '2026-09-15 20:10+01'),
    (22,  3, '6031857265', 'savings',  100000.00, 'active', '2026-09-01 07:55+01'),
    (23,  5, '6053716929', 'savings',       0.00, 'active', '2026-09-12 12:30+01'),
    (24,  9, '6091648258', 'savings',       0.00, 'active', '2026-09-18 09:05+01'),
    (25, 13, '6138571207', 'savings',   50000.00, 'active', '2026-09-03 18:20+01');

-- 12 transfers: 8 completed, 1 reversed, 2 failed (no money moved), 1 pending
-- (a large transfer held for compliance review, no money moved yet).
INSERT INTO transfers (transfer_id, reference, sender_wallet_id, receiver_wallet_id, amount,
                       narration, status, failure_reason, created_at, processed_at)
OVERRIDING SYSTEM VALUE VALUES
    ( 1, 'TRF2608150001',  1,  4,  20000.00, 'Birthday gift', 'completed', NULL, '2026-08-15 18:02+01', '2026-08-15 18:02+01'),
    ( 2, 'TRF2608210001',  9, 11,  30000.00, 'Rent contribution', 'completed', NULL, '2026-08-21 08:47+01', '2026-08-21 08:47+01'),
    ( 3, 'TRF2608280001',  5,  8,  15000.00, 'For the event', 'completed', NULL, '2026-08-28 14:15+01', '2026-08-28 14:15+01'),
    ( 4, 'TRF2609010001',  3, 22, 100000.00, 'Move to savings', 'completed', NULL, '2026-09-01 08:00+01', '2026-09-01 08:00+01'),
    ( 5, 'TRF2609030001', 13, 25,  50000.00, 'Move to savings', 'completed', NULL, '2026-09-03 18:25+01', '2026-09-03 18:25+01'),
    ( 6, 'TRF2609080001', 17, 15,  25000.00, 'Loan repayment', 'completed', NULL, '2026-09-08 10:12+01', '2026-09-08 10:12+01'),
    ( 7, 'TRF2609140001',  2,  7,  10000.00, 'Lunch money', 'completed', NULL, '2026-09-14 12:31+01', '2026-09-14 12:31+01'),
    ( 8, 'TRF2609220001', 11, 19,  12000.00, 'Aso-ebi contribution', 'completed', NULL, '2026-09-22 19:40+01', '2026-09-22 19:40+01'),
    ( 9, 'TRF2609290001', 12, 18,   8000.00, 'Thank you', 'reversed', 'Receiver wallet frozen by compliance; funds returned to sender', '2026-09-29 09:58+01', '2026-09-29 10:03+01'),
    (10, 'TRF2610020001',  4, 16,  50000.00, 'School fees share', 'failed', 'Insufficient funds', '2026-10-02 07:45+01', '2026-10-02 07:45+01'),
    (11, 'TRF2610050001', 15, 20,   5000.00, 'Transport', 'failed', 'Transaction PIN entered incorrectly three times', '2026-10-05 16:20+01', '2026-10-05 16:21+01'),
    (12, 'TRF2610080001',  9,  1, 250000.00, 'Business supplies', 'pending', NULL, '2026-10-08 11:05+01', NULL);

-- 47 ledger rows in time order: funding, merchant payments, both legs of every
-- completed transfer, the debit and reversal of transfer 9, one failed and one
-- pending card top-up. transaction_id is generated, so it follows time order.
INSERT INTO transactions (reference, wallet_id, transaction_type, amount, status,
                          transfer_id, merchant_id, narration, created_at)
VALUES
    ('TXN2608020001',  1, 'funding',          150000.00, 'completed', NULL, NULL, 'Bank transfer top-up', '2026-08-02 08:30+01'),
    ('TXN2608030001',  2, 'funding',           40000.00, 'completed', NULL, NULL, 'Bank transfer top-up', '2026-08-03 09:15+01'),
    ('TXN2608040001',  3, 'funding',          250000.00, 'completed', NULL, NULL, 'Bank transfer top-up', '2026-08-04 07:50+01'),
    ('TXN2608050001',  4, 'funding',           25000.00, 'completed', NULL, NULL, 'Bank transfer top-up', '2026-08-05 18:05+01'),
    ('TXN2608060001',  5, 'funding',          500000.00, 'completed', NULL, NULL, 'Bank transfer top-up', '2026-08-06 10:20+01'),
    ('TXN2608080001',  7, 'funding',           60000.00, 'completed', NULL, NULL, 'Bank transfer top-up', '2026-08-08 12:45+01'),
    ('TXN2608090001',  8, 'funding',           35000.00, 'completed', NULL, NULL, 'Bank transfer top-up', '2026-08-09 16:10+01'),
    ('TXN2608090002',  1, 'merchant_payment',  18450.50, 'completed', NULL,    1, 'Weekly groceries', '2026-08-09 17:20+01'),
    ('TXN2608100001',  9, 'funding',          320000.00, 'completed', NULL, NULL, 'Bank transfer top-up', '2026-08-10 08:35+01'),
    ('TXN2608110001',  2, 'merchant_payment',   6500.00, 'completed', NULL,    3, 'Suya and drinks', '2026-08-11 20:05+01'),
    ('TXN2608120001', 11, 'funding',           45000.00, 'completed', NULL, NULL, 'Bank transfer top-up', '2026-08-12 13:55+01'),
    ('TXN2608130001', 12, 'funding',           80000.00, 'completed', NULL, NULL, 'Bank transfer top-up', '2026-08-13 17:25+01'),
    ('TXN2608140001',  3, 'merchant_payment',   3200.00, 'completed', NULL,    5, 'Ride to Victoria Island', '2026-08-14 07:40+01'),
    ('TXN2608140002', 13, 'funding',          200000.00, 'completed', NULL, NULL, 'Bank transfer top-up', '2026-08-14 09:40+01'),
    ('TXN2608150001',  1, 'transfer_out',      20000.00, 'completed',    1, NULL, 'Birthday gift', '2026-08-15 18:02+01'),
    ('TXN2608150002',  4, 'transfer_in',       20000.00, 'completed',    1, NULL, 'Birthday gift', '2026-08-15 18:02+01'),
    ('TXN2608160001', 15, 'funding',           55000.00, 'completed', NULL, NULL, 'Bank transfer top-up', '2026-08-16 07:15+01'),
    ('TXN2608170001', 16, 'funding',           30000.00, 'completed', NULL, NULL, 'Bank transfer top-up', '2026-08-17 19:30+01'),
    ('TXN2608180001', 17, 'funding',          400000.00, 'completed', NULL, NULL, 'Bank transfer top-up', '2026-08-18 11:05+01'),
    ('TXN2608200001',  5, 'merchant_payment', 185000.00, 'completed', NULL,   10, 'Laptop', '2026-08-20 13:10+01'),
    ('TXN2608200002', 19, 'funding',           50000.00, 'completed', NULL, NULL, 'Bank transfer top-up', '2026-08-20 15:50+01'),
    ('TXN2608210001',  9, 'transfer_out',      30000.00, 'completed',    2, NULL, 'Rent contribution', '2026-08-21 08:47+01'),
    ('TXN2608210002', 11, 'transfer_in',       30000.00, 'completed',    2, NULL, 'Rent contribution', '2026-08-21 08:47+01'),
    ('TXN2608220001',  9, 'merchant_payment',  25000.00, 'completed', NULL,    4, 'Prepaid electricity token', '2026-08-22 09:30+01'),
    ('TXN2608250001',  7, 'merchant_payment',   5000.00, 'completed', NULL,    6, 'Monthly data bundle', '2026-08-25 08:15+01'),
    ('TXN2608280001',  5, 'transfer_out',      15000.00, 'completed',    3, NULL, 'For the event', '2026-08-28 14:15+01'),
    ('TXN2608280002',  8, 'transfer_in',       15000.00, 'completed',    3, NULL, 'For the event', '2026-08-28 14:15+01'),
    ('TXN2609010001',  3, 'transfer_out',     100000.00, 'completed',    4, NULL, 'Move to savings', '2026-09-01 08:00+01'),
    ('TXN2609010002', 22, 'transfer_in',      100000.00, 'completed',    4, NULL, 'Move to savings', '2026-09-01 08:00+01'),
    ('TXN2609020001', 12, 'merchant_payment',  42000.00, 'completed', NULL,    7, 'Ankara fabric', '2026-09-02 15:45+01'),
    ('TXN2609030001', 13, 'transfer_out',      50000.00, 'completed',    5, NULL, 'Move to savings', '2026-09-03 18:25+01'),
    ('TXN2609030002', 25, 'transfer_in',       50000.00, 'completed',    5, NULL, 'Move to savings', '2026-09-03 18:25+01'),
    ('TXN2609050001', 13, 'merchant_payment',  12750.25, 'completed', NULL,    8, 'Prescription', '2026-09-05 11:20+01'),
    ('TXN2609080001', 17, 'transfer_out',      25000.00, 'completed',    6, NULL, 'Loan repayment', '2026-09-08 10:12+01'),
    ('TXN2609080002', 15, 'transfer_in',       25000.00, 'completed',    6, NULL, 'Loan repayment', '2026-09-08 10:12+01'),
    ('TXN2609100001', 17, 'merchant_payment', 150000.00, 'completed', NULL,    9, 'Coding bootcamp fees', '2026-09-10 10:00+01'),
    ('TXN2609140001',  2, 'transfer_out',      10000.00, 'completed',    7, NULL, 'Lunch money', '2026-09-14 12:31+01'),
    ('TXN2609140002',  7, 'transfer_in',       10000.00, 'completed',    7, NULL, 'Lunch money', '2026-09-14 12:31+01'),
    ('TXN2609190001',  1, 'merchant_payment',   9000.00, 'completed', NULL,   11, 'Cinema tickets', '2026-09-19 18:35+01'),
    ('TXN2609220001', 11, 'transfer_out',      12000.00, 'completed',    8, NULL, 'Aso-ebi contribution', '2026-09-22 19:40+01'),
    ('TXN2609220002', 19, 'transfer_in',       12000.00, 'completed',    8, NULL, 'Aso-ebi contribution', '2026-09-22 19:40+01'),
    ('TXN2609260001', 16, 'merchant_payment',   4800.00, 'completed', NULL,    2, 'Lunch', '2026-09-26 13:25+01'),
    ('TXN2609290001', 12, 'transfer_out',       8000.00, 'completed',    9, NULL, 'Thank you', '2026-09-29 09:58+01'),
    ('TXN2609290002', 12, 'reversal',           8000.00, 'completed',    9, NULL, 'Reversal: Thank you', '2026-09-29 10:03+01'),
    ('TXN2610030001', 19, 'merchant_payment',  27300.00, 'completed', NULL,    1, 'Groceries', '2026-10-03 16:40+01'),
    ('TXN2610070001', 10, 'funding',           15000.00, 'failed',    NULL, NULL, 'Card top-up: card declined', '2026-10-07 21:10+01'),
    ('TXN2610080001',  6, 'funding',           20000.00, 'pending',   NULL, NULL, 'Card top-up: awaiting confirmation', '2026-10-08 19:42+01');

-- 18 saved beneficiaries.
INSERT INTO beneficiaries (customer_id, wallet_id, nickname, created_at)
VALUES
    ( 1,  4, 'Ngozi', '2026-08-15 17:58+01'),
    ( 1,  3, 'Seun', '2026-08-20 10:15+01'),
    ( 9, 11, 'Yusuf rent', '2026-08-21 08:44+01'),
    ( 9,  1, 'Chinedu', '2026-10-08 11:01+01'),
    ( 5,  8, 'Zainab', '2026-08-28 14:11+01'),
    (17, 15, 'Jide', '2026-09-08 10:08+01'),
    ( 2,  7, 'Emeka office', '2026-09-14 12:28+01'),
    (11, 19, 'Kelechi aso-ebi', '2026-09-22 19:36+01'),
    (12, 18, 'Halima', '2026-09-29 09:55+01'),
    ( 4, 16, 'Amara', '2026-10-02 07:42+01'),
    (15, 20, 'Folake', '2026-10-05 16:17+01'),
    ( 7,  2, 'Aisha', '2026-09-14 12:40+01'),
    (13, 12, 'Temi', '2026-09-20 09:30+01'),
    (16,  4, 'Ngozi Eze', '2026-09-01 18:12+01'),
    (19, 11, 'Yusuf', '2026-09-23 07:50+01'),
    ( 8,  5, 'Alhaji Ibrahim', '2026-08-29 08:20+01'),
    ( 6, 10, 'Chi', '2026-08-25 21:05+01'),
    (10,  6, 'Funmi', '2026-08-26 10:40+01');

-- 37 audit entries: KYC reviews, the suspension of customer 18, transfer
-- outcomes, a declined card top-up and a nightly balance audit (entity_id NULL:
-- it covers every wallet).
INSERT INTO audit_log (entity_type, entity_id, action, actor_type, actor_ref, details, created_at)
VALUES
    ('kyc_document',    1, 'verified', 'staff', 'compliance.adaeze', 'bvn verified for customer 1', '2026-08-01 14:05+01'),
    ('kyc_document',    2, 'verified', 'staff', 'compliance.adaeze', 'nin verified for customer 1', '2026-08-01 14:08+01'),
    ('kyc_document',    3, 'verified', 'staff', 'compliance.olumide', 'utility_bill verified for customer 1', '2026-08-02 11:40+01'),
    ('kyc_document',    4, 'verified', 'staff', 'compliance.olumide', 'bvn verified for customer 2', '2026-08-02 15:12+01'),
    ('kyc_document',    5, 'verified', 'staff', 'compliance.fatima', 'bvn verified for customer 3', '2026-08-03 10:30+01'),
    ('kyc_document',    6, 'verified', 'staff', 'compliance.fatima', 'passport verified for customer 3', '2026-08-03 10:34+01'),
    ('kyc_document',    7, 'verified', 'staff', 'compliance.fatima', 'utility_bill verified for customer 3', '2026-08-03 10:41+01'),
    ('kyc_document',    8, 'verified', 'staff', 'compliance.adaeze', 'nin verified for customer 4', '2026-08-04 16:55+01'),
    ('kyc_document',    9, 'verified', 'staff', 'compliance.olumide', 'bvn verified for customer 5', '2026-08-05 15:20+01'),
    ('kyc_document',   10, 'verified', 'staff', 'compliance.olumide', 'drivers_licence verified for customer 5', '2026-08-05 15:26+01'),
    ('kyc_document',   11, 'verified', 'staff', 'compliance.olumide', 'utility_bill verified for customer 5', '2026-08-05 15:31+01'),
    ('kyc_document',   13, 'verified', 'staff', 'compliance.fatima', 'bvn verified for customer 7', '2026-08-07 12:16+01'),
    ('kyc_document',   14, 'rejected', 'staff', 'compliance.fatima', 'Utility bill rejected: image unreadable', '2026-08-07 12:21+01'),
    ('kyc_document',   15, 'verified', 'staff', 'compliance.adaeze', 'nin verified for customer 8', '2026-08-09 09:05+01'),
    ('kyc_document',   16, 'verified', 'staff', 'compliance.olumide', 'bvn verified for customer 9', '2026-08-09 13:02+01'),
    ('kyc_document',   17, 'verified', 'staff', 'compliance.olumide', 'voters_card verified for customer 9', '2026-08-09 13:07+01'),
    ('kyc_document',   18, 'verified', 'staff', 'compliance.olumide', 'utility_bill verified for customer 9', '2026-08-09 13:11+01'),
    ('kyc_document',   19, 'verified', 'staff', 'compliance.fatima', 'bvn verified for customer 11', '2026-08-11 16:44+01'),
    ('kyc_document',   20, 'verified', 'staff', 'compliance.adaeze', 'bvn verified for customer 12', '2026-08-13 09:10+01'),
    ('kyc_document',   22, 'verified', 'staff', 'compliance.olumide', 'bvn verified for customer 13', '2026-08-13 14:18+01'),
    ('kyc_document',   23, 'verified', 'staff', 'compliance.olumide', 'nin verified for customer 13', '2026-08-13 14:21+01'),
    ('kyc_document',   24, 'verified', 'staff', 'compliance.olumide', 'utility_bill verified for customer 13', '2026-08-13 14:26+01'),
    ('kyc_document',   25, 'rejected', 'staff', 'compliance.fatima', 'NIN rejected: name does not match NIMC record', '2026-08-15 10:02+01'),
    ('kyc_document',   26, 'verified', 'staff', 'compliance.adaeze', 'bvn verified for customer 15', '2026-08-15 12:47+01'),
    ('kyc_document',   27, 'verified', 'staff', 'compliance.fatima', 'nin verified for customer 16', '2026-08-16 17:35+01'),
    ('kyc_document',   28, 'verified', 'staff', 'compliance.olumide', 'bvn verified for customer 17', '2026-08-17 13:58+01'),
    ('kyc_document',   29, 'verified', 'staff', 'compliance.olumide', 'passport verified for customer 17', '2026-08-17 14:02+01'),
    ('kyc_document',   30, 'verified', 'staff', 'compliance.olumide', 'utility_bill verified for customer 17', '2026-08-17 14:06+01'),
    ('kyc_document',   31, 'verified', 'staff', 'compliance.adaeze', 'bvn verified for customer 19', '2026-08-19 15:33+01'),
    ('customer',   18, 'status_changed', 'staff', 'compliance.fatima', 'active -> suspended: suspected account takeover', '2026-09-20 14:30+01'),
    ('wallet',   18, 'status_changed', 'staff', 'compliance.fatima', 'active -> frozen: customer suspended', '2026-09-20 14:31+01'),
    ('transfer',    9, 'reversed', 'system', 'transfer-engine', 'Receiver wallet frozen; NGN 8000.00 returned to wallet 12', '2026-09-29 10:03+01'),
    ('wallet', NULL, 'audited', 'system', 'nightly-audit', 'Nightly balance audit: 25 wallets checked, 0 mismatches', '2026-10-01 02:00+01'),
    ('transfer',   10, 'failed', 'system', 'transfer-engine', 'Insufficient funds: balance NGN 45000.00, requested NGN 50000.00', '2026-10-02 07:45+01'),
    ('transfer',   11, 'failed', 'system', 'transfer-engine', 'Transaction PIN entered incorrectly three times', '2026-10-05 16:21+01'),
    ('transaction',   46, 'failed', 'system', 'card-gateway', 'Card top-up declined by the issuing bank', '2026-10-07 21:10+01'),
    ('transfer',   12, 'held', 'system', 'transfer-engine', 'Held for compliance review: amount above NGN 200000.00 large-transfer threshold', '2026-10-08 11:05+01');

-- Move each identity counter past the explicit ids, so the next generated
-- id does not collide with a sample row.
-- One row of output: the last id now used in each table.
SELECT setval(pg_get_serial_sequence('customers', 'customer_id'),
              (SELECT max(customer_id) FROM customers))      AS customers,
       setval(pg_get_serial_sequence('merchants', 'merchant_id'),
              (SELECT max(merchant_id) FROM merchants))      AS merchants,
       setval(pg_get_serial_sequence('kyc_documents', 'document_id'),
              (SELECT max(document_id) FROM kyc_documents))  AS kyc_documents,
       setval(pg_get_serial_sequence('wallets', 'wallet_id'),
              (SELECT max(wallet_id) FROM wallets))          AS wallets,
       setval(pg_get_serial_sequence('transfers', 'transfer_id'),
              (SELECT max(transfer_id) FROM transfers))      AS transfers;

-- Integrity audit, run before COMMIT. Any failure aborts the script and the
-- whole load rolls back.
-- 1. Balance audit ("audit balances" operation): the stored balance must
--    equal completed credits minus completed debits.
-- 2. Transfer legs: every ledger row of a transfer must carry the transfer's
--    amount and the right wallet (sender for transfer_out and reversal,
--    receiver for transfer_in). The ledger repeats these values on purpose,
--    so this check is what keeps the copies honest.
DO $$
DECLARE
    balance_mismatches integer;
    leg_mismatches     integer;
BEGIN
    SELECT count(*) INTO balance_mismatches
    FROM wallets w
    LEFT JOIN (
        SELECT wallet_id,
               sum(CASE WHEN transaction_type IN ('funding', 'transfer_in', 'reversal')
                        THEN amount ELSE -amount END) AS ledger_balance
        FROM transactions
        WHERE status = 'completed'
        GROUP BY wallet_id
    ) l USING (wallet_id)
    WHERE w.balance <> coalesce(l.ledger_balance, 0);

    SELECT count(*) INTO leg_mismatches
    FROM transactions t
    JOIN transfers tr USING (transfer_id)
    WHERE t.amount <> tr.amount
       OR t.wallet_id <> CASE WHEN t.transaction_type = 'transfer_in'
                              THEN tr.receiver_wallet_id ELSE tr.sender_wallet_id END;

    IF balance_mismatches > 0 THEN
        RAISE EXCEPTION 'Balance audit failed: % wallet(s) differ from the ledger', balance_mismatches;
    END IF;
    IF leg_mismatches > 0 THEN
        RAISE EXCEPTION 'Transfer audit failed: % ledger row(s) disagree with their transfer', leg_mismatches;
    END IF;
    RAISE NOTICE 'Balance audit passed: all % wallet balances equal their ledger totals',
                 (SELECT count(*) FROM wallets);
    RAISE NOTICE 'Transfer audit passed: all % transfer ledger rows match their transfer',
                 (SELECT count(*) FROM transactions WHERE transfer_id IS NOT NULL);
END
$$;

COMMIT;

-- Row counts per table.
SELECT 'customers' AS table_name, count(*) AS row_count FROM customers
UNION ALL SELECT 'merchants', count(*) FROM merchants
UNION ALL SELECT 'kyc_documents', count(*) FROM kyc_documents
UNION ALL SELECT 'wallets', count(*) FROM wallets
UNION ALL SELECT 'transfers', count(*) FROM transfers
UNION ALL SELECT 'transactions', count(*) FROM transactions
UNION ALL SELECT 'beneficiaries', count(*) FROM beneficiaries
UNION ALL SELECT 'audit_log', count(*) FROM audit_log;
