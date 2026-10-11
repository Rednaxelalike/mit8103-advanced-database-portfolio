-- =====================================================================
-- Portfolio 2: Query processing and optimisation
-- 01_seed_large.sql  Rebuilds the Proclus database and grows it to about
--                    a million ledger rows, so that indexes make a
--                    measurable difference.
--
-- Run from the repo root (see SETUP.md for loading PGPASSWORD):
--   psql -w -U postgres -h localhost -p 5432 -d proclus -v ON_ERROR_STOP=1
--        -f portfolio-2-query-optimisation/sql/01_seed_large.sql
--
-- Re-runnable: it starts by running the Portfolio 1 schema and sample data
-- scripts, which drop and rebuild all eight tables. Every run therefore
-- starts from the same empty schema with no Portfolio 2 indexes, and
-- setseed() makes the random numbers, and so the rows, the same each time.
-- It takes two to three minutes; most of it is the final ledger insert,
-- which checks three foreign keys and two unique keys on every row.
--
-- What it adds to the Portfolio 1 sample, which it leaves untouched:
--   * 50,000 customers who joined between October 2025 and September 2026
--   * a main wallet for each, and a savings wallet for about one in six
--   * 488 merchants (500 with the sample's 12)
--   * about 199,000 transfers and 420,000 merchant payments
--   * about 1,040,000 ledger rows in all, from 1 October 2025 to
--     8 October 2026
-- Only the five tables the Portfolio 2 queries read are grown. KYC
-- documents, beneficiaries and the audit log keep their sample rows.
--
-- The generated activity never touches the 25 sample wallets, so every
-- balance and screenshot from Portfolio 1 stays true.
--
-- No secondary indexes are created here. The plans in plans/before/ are
-- taken on exactly this state; 03_indexes.sql adds the indexes.
-- =====================================================================

\ir ../../portfolio-1-database-design/sql/01_schema.sql
\ir ../../portfolio-1-database-design/sql/02_sample_data.sql

\echo
\echo '=== Portfolio 2: generating the large data set ==='
\timing on

-- How many random draws each kind of activity starts from. Draws that
-- fall outside a wallet's active days are dropped (see section 4), so
-- fewer rows than this are kept.
\set funding_draws  400000
\set payment_draws  1080000
\set transfer_draws 665000

-- Dates in references and the Lagos business day depend on the session
-- time zone, so fix it rather than rely on the server default.
SET TIME ZONE 'Africa/Lagos';

BEGIN;

-- More sort memory for this load only (the window functions below sort
-- about a million rows). SET LOCAL ends with the transaction, so the
-- queries in 02_queries.sql still run with the server default.
SET LOCAL work_mem = '256MB';

-- Fix the random number generator, so every run produces the same rows.
SELECT setseed(0.8103);

-- ---------------------------------------------------------------------
-- 1. Customers: 50,000, signing up between 1 October 2025 and
--    30 September 2026, between 06:00 and 23:00 Lagos time.
--    Ids follow sign-up time, because rows are inserted in that order.
-- ---------------------------------------------------------------------
WITH names AS (
    SELECT ARRAY['Adebayo', 'Adewale', 'Aminu', 'Ayodele', 'Babatunde', 'Blessing', 'Bolanle',
                 'Chidi', 'Chidinma', 'Chinedu', 'Chioma', 'Damilola', 'Ebuka', 'Efe', 'Emeka',
                 'Ese', 'Esther', 'Fatima', 'Femi', 'Folasade', 'Funke', 'Gbenga', 'Habiba',
                 'Halima', 'Ibukun', 'Ifeoma', 'Ikechukwu', 'Joy', 'Jumoke', 'Kayode', 'Kemi',
                 'Kunle', 'Ladi', 'Musa', 'Nkechi', 'Nneka', 'Obinna', 'Olamide', 'Olumide',
                 'Onyeka', 'Rasheed', 'Sadiq', 'Sola', 'Tobi', 'Tolani', 'Uchenna', 'Usman',
                 'Yemisi', 'Zainab', 'Zubairu'] AS first_names,
           ARRAY['Abiodun', 'Adeleke', 'Adeyemi', 'Afolabi', 'Ajayi', 'Akande', 'Akinola', 'Aliyu',
                 'Anyanwu', 'Balogun', 'Bello', 'Chukwu', 'Danladi', 'Ekwueme', 'Eze', 'Ezenwa',
                 'Fashola', 'Garba', 'Ibekwe', 'Idowu', 'Igwe', 'Ilori', 'Kalu', 'Lawal',
                 'Mohammed', 'Nnadi', 'Nwachukwu', 'Obi', 'Odukoya', 'Ogbu', 'Ogunbiyi', 'Okafor',
                 'Okeke', 'Okon', 'Olaniyan', 'Olawale', 'Onuoha', 'Opara', 'Oyelaran', 'Salami',
                 'Sanusi', 'Shittu', 'Suleiman', 'Taiwo', 'Udeh', 'Umar', 'Uzor', 'Yakubu',
                 'Yusuf', 'Zakari'] AS last_names,
           -- Mobile network prefixes that pass customers_phone_format.
           ARRAY['803', '806', '813', '816', '810', '814', '703', '706', '708', '701',
                 '903', '906', '905', '902', '909', '802', '808', '812', '907', '901'] AS prefixes
),
draws AS MATERIALIZED (
    SELECT n, random() AS u_first, random() AS u_last, random() AS u_prefix, random() AS u_case,
           random() AS u_dob, random() AS u_tier, random() AS u_status,
           random() AS u_day, random() AS u_time
    FROM generate_series(1, 50000) AS n
),
people AS (
    SELECT d.*,
           nm.first_names[1 + floor(d.u_first * 50)::int] AS first_name,
           nm.last_names[1 + floor(d.u_last * 50)::int]   AS last_name,
           nm.prefixes[1 + floor(d.u_prefix * 20)::int]   AS prefix,
           TIMESTAMPTZ '2025-10-01 06:00+01'
               + floor(d.u_day * 365)::int * interval '1 day'
               + d.u_time * interval '17 hours'           AS joined_at
    FROM draws d CROSS JOIN names nm
)
INSERT INTO customers (first_name, last_name, email, phone_number, date_of_birth,
                       kyc_tier, status, created_at)
SELECT first_name,
       last_name,
       -- The number n keeps every email unique. About a quarter of customers
       -- typed theirs with capitals, which is why a support look-up has to
       -- ignore case (query 8 and the lower(email) index).
       CASE WHEN u_case < 0.25 THEN initcap(first_name || '.' || last_name)
            ELSE lower(first_name || '.' || last_name) END || n || '@example.com',
       -- The 7 digits after the prefix are n, so phone numbers are unique and
       -- stay below the sample's 1000001-1000020.
       '+234' || prefix || lpad(n::text, 7, '0'),
       -- Born 1966-2005, so every customer was at least 18 at sign-up.
       DATE '1966-01-01' + floor(u_dob * 14600)::int,
       CASE WHEN u_tier < 0.35 THEN 1 WHEN u_tier < 0.80 THEN 2 ELSE 3 END,
       CASE WHEN u_status < 0.01 THEN 'suspended' ELSE 'active' END,
       joined_at
FROM people
ORDER BY joined_at, n;

-- ---------------------------------------------------------------------
-- 2. Merchants: 488 more, joining between September 2025 and June 2026.
--    Names are a Lagos area plus a word that fits the category, built in
--    order within each category so no name repeats (and none equals a
--    sample merchant, whose email would then clash).
-- ---------------------------------------------------------------------
WITH words AS (
    SELECT ARRAY['Ikeja', 'Yaba', 'Surulere', 'Lekki', 'Ajah', 'Ikorodu', 'Festac', 'Gbagada',
                 'Ogba', 'Magodo', 'Maryland', 'Oshodi', 'Apapa', 'Agege', 'Ojota', 'Ketu',
                 'Mushin', 'Ilupeju', 'Sangotedo', 'Victoria Island', 'Ikoyi', 'Ebute Metta',
                 'Isolo', 'Egbeda', 'Badagry'] AS areas
),
nouns (category, nouns) AS (
    VALUES ('groceries',     ARRAY['Supermarket', 'Provisions', 'Foods', 'Mini Mart']),
           ('restaurant',    ARRAY['Kitchen', 'Buka', 'Grill House', 'Eatery']),
           ('transport',     ARRAY['Rides', 'Logistics', 'Shuttle', 'Cab Services']),
           ('utilities',     ARRAY['Electricity Vendor', 'Water Services', 'Gas Refill', 'Cable TV Payments']),
           ('airtime_data',  ARRAY['Telecom Shop', 'Recharge Point', 'Airtime Plaza', 'Data Store']),
           ('fashion',       ARRAY['Boutique', 'Tailoring', 'Fashion House', 'Shoe Palace']),
           ('pharmacy',      ARRAY['Pharmacy', 'Chemists', 'Health Store', 'Medical Supplies']),
           ('education',     ARRAY['Academy', 'Tutors', 'College', 'School Supplies']),
           ('entertainment', ARRAY['Cinema', 'Lounge', 'Game Centre', 'Event Centre']),
           ('electronics',   ARRAY['Electronics', 'Phone Plaza', 'Computer Shop', 'Appliances'])
),
draws AS MATERIALIZED (
    SELECT n, random() AS u_category, random() AS u_cac, random() AS u_status, random() AS u_day
    FROM generate_series(1, 488) AS n
),
typed AS (
    SELECT d.*,
           CASE WHEN u_category < 0.20 THEN 'groceries'
                WHEN u_category < 0.38 THEN 'restaurant'
                WHEN u_category < 0.50 THEN 'transport'
                WHEN u_category < 0.58 THEN 'utilities'
                WHEN u_category < 0.68 THEN 'airtime_data'
                WHEN u_category < 0.78 THEN 'fashion'
                WHEN u_category < 0.86 THEN 'pharmacy'
                WHEN u_category < 0.90 THEN 'education'
                WHEN u_category < 0.96 THEN 'entertainment'
                ELSE 'electronics' END AS category
    FROM draws d
),
named AS (
    SELECT t.*,
           -- k counts merchants within the category: 25 areas x 4 words
           -- give 100 distinct names, and a number is added after that.
           row_number() OVER (PARTITION BY t.category ORDER BY t.n) - 1 AS k
    FROM typed t
),
built AS (
    SELECT nd.*,
           w.areas[1 + (nd.k % 25)::int] || ' ' || ns.nouns[1 + ((nd.k / 25) % 4)::int]
               || CASE WHEN nd.k >= 100 THEN ' ' || (nd.k / 100 + 1) ELSE '' END AS business_name
    FROM named nd
    JOIN nouns ns USING (category)
    CROSS JOIN words w
)
INSERT INTO merchants (business_name, cac_number, category, email, status, created_at)
SELECT business_name,
       -- 7 digits from 8000001 up: unique, and clear of the sample's numbers.
       CASE WHEN u_cac < 0.6 THEN 'RC' ELSE 'BN' END || (8000000 + n),
       category,
       'payments@' || lower(regexp_replace(business_name, '[^A-Za-z0-9]', '', 'g')) || '.example.com',
       CASE WHEN u_status < 0.02 THEN 'suspended' ELSE 'active' END,
       TIMESTAMPTZ '2025-09-01 09:00+01' + floor(u_day * 300)::int * interval '1 day'
FROM built
ORDER BY 6, n;

-- ---------------------------------------------------------------------
-- 3. Wallets: a main wallet for every new customer, opened two minutes
--    after sign-up (as in the sample), and a savings wallet for about one
--    customer in five, opened 1-120 days later. Suspended customers'
--    wallets are frozen. Wallet numbers start with 5 (main) or 6 (savings)
--    followed by the customer id; the sample's numbers are all higher.
-- ---------------------------------------------------------------------
WITH draws AS MATERIALIZED (
    SELECT customer_id, status, created_at, random() AS u_has_savings, random() AS u_when
    FROM customers
    WHERE customer_id > 20
    ORDER BY customer_id
)
INSERT INTO wallets (customer_id, wallet_number, wallet_type, balance, status, created_at)
SELECT customer_id, wallet_number, wallet_type, 0.00, status, opened_at
FROM (
    SELECT customer_id,
           '5' || lpad(customer_id::text, 9, '0') AS wallet_number,
           'main' AS wallet_type,
           CASE WHEN status = 'suspended' THEN 'frozen' ELSE 'active' END AS status,
           created_at + interval '2 minutes' AS opened_at
    FROM draws
    UNION ALL
    SELECT customer_id,
           '6' || lpad(customer_id::text, 9, '0'),
           'savings',
           'active',
           created_at + interval '1 day' + u_when * interval '119 days'
    FROM draws
    WHERE u_has_savings < 0.20
      AND created_at + interval '1 day' + u_when * interval '119 days' < TIMESTAMPTZ '2026-10-05 00:00+01'
) w
ORDER BY opened_at, wallet_number;

-- ---------------------------------------------------------------------
-- 4. Who is active, and how busy. Working tables (dropped at COMMIT):
--    seed_wallets has one row per new main wallet, with its savings
--    wallet, the window in which it is active, and a random rank rn.
--    Wallets are later picked as rn = 1 + floor(N * u^1.5), so a low rank
--    means a busy customer (a few hundred rows a year) and a high rank a
--    quiet one (a handful), as in a real wallet.
--    Each draw also picks a moment up to 373 days after the wallet opened
--    (the length of the data). Draws that land after the customer's last
--    active day are dropped. Every wallet therefore has the same rate of
--    activity per day while in use: a customer who joined in September
--    has a few weeks of rows, not a year's worth squeezed into them.
--    About 12% of customers who joined before May 2026 stopped using
--    Proclus between one month after joining and the end of June 2026;
--    they are the "inactive customers" query 4 looks for.
-- ---------------------------------------------------------------------
CREATE TEMP TABLE seed_wallets ON COMMIT DROP AS
WITH draws AS MATERIALIZED (
    SELECT w.wallet_id, w.customer_id, w.status, w.created_at AS opened_at,
           random() AS u_churn, random() AS u_until, random() AS u_rank
    FROM wallets w
    WHERE w.wallet_type = 'main' AND w.wallet_id > 25
    ORDER BY w.wallet_id
)
SELECT d.wallet_id,
       d.customer_id,
       d.opened_at,
       CASE WHEN (d.u_churn < 0.12 OR d.status = 'frozen')
                 AND d.opened_at < TIMESTAMPTZ '2026-05-01 00:00+01'
            THEN d.opened_at + interval '30 days'
                 + d.u_until * (TIMESTAMPTZ '2026-06-30 23:00+01' - d.opened_at - interval '30 days')
            ELSE TIMESTAMPTZ '2026-10-08 23:00+01' END AS active_until,
       s.wallet_id  AS savings_wallet_id,
       s.created_at AS savings_opened_at,
       row_number() OVER (ORDER BY d.u_rank)::int AS rn
FROM draws d
LEFT JOIN wallets s ON s.customer_id = d.customer_id AND s.wallet_type = 'savings';

-- Active merchants, ranked the same way (u^2.5: a few very popular ones).
CREATE TEMP TABLE seed_merchants ON COMMIT DROP AS
SELECT merchant_id, category, created_at,
       row_number() OVER (ORDER BY u_rank)::int AS rn
FROM (SELECT merchant_id, category, created_at, random() AS u_rank
      FROM merchants
      WHERE status = 'active'
      ORDER BY merchant_id) m;

-- Spending range and narration for each merchant category, in naira.
CREATE TEMP TABLE category_spend (category, min_amount, max_amount, kobo, narration) ON COMMIT DROP AS
VALUES ('groceries',      1500,  60000, true,  'Groceries'),
       ('restaurant',     1500,  25000, true,  'Food and drinks'),
       ('transport',       500,  12000, false, 'Ride'),
       ('utilities',      3000,  50000, false, 'Prepaid electricity token'),
       ('airtime_data',    100,  15000, false, 'Airtime and data'),
       ('fashion',        5000, 150000, false, 'Clothing'),
       ('pharmacy',       1000,  40000, true,  'Pharmacy'),
       ('education',     20000, 450000, false, 'School fees'),
       ('entertainment',  2000,  30000, false, 'Cinema and events'),
       ('electronics',   15000, 900000, false, 'Electronics');

-- Temporary tables get no statistics until analysed. Without them the
-- planner guesses their size and can pick a nested-loop join that takes
-- minutes on the draws below.
ANALYZE seed_wallets, seed_merchants, category_spend;

-- Every generated ledger row is staged here first, so the balances can
-- be checked before anything reaches the real ledger. leg orders rows
-- that share a time: 0 = funding or payment, 1 = transfer_out,
-- 2 = transfer_in, 3 = reversal.
CREATE TEMP TABLE seed_ledger (
    wallet_id         BIGINT,
    transaction_type  VARCHAR(20),
    amount            NUMERIC(14,2),
    status            VARCHAR(10),
    transfer_ref      VARCHAR(20),
    merchant_id       BIGINT,
    narration         VARCHAR(100),
    created_at        TIMESTAMPTZ,
    leg               SMALLINT
) ON COMMIT DROP;

-- ---------------------------------------------------------------------
-- 5. Funding: top-ups into main wallets, NGN 1,000-300,000 in steps of
--    500, mostly small. One in five is a card top-up; 4% of card top-ups
--    are declined (failed), and card top-ups in the last two hours of the
--    data are still pending. Neither counts towards a balance.
-- ---------------------------------------------------------------------
WITH draws AS MATERIALIZED (
    SELECT n,
           1 + floor((SELECT count(*) FROM seed_wallets) * power(random(), 1.5))::int AS rn,
           random() AS u_time, random() AS u_amount, random() AS u_card, random() AS u_fail
    FROM generate_series(1, :funding_draws) AS n
),
timed AS (
    SELECT d.*, w.wallet_id, w.active_until,
           w.opened_at + interval '1 hour' + d.u_time * interval '373 days' AS at
    FROM draws d
    JOIN seed_wallets w USING (rn)
)
INSERT INTO seed_ledger (wallet_id, transaction_type, amount, status, narration, created_at, leg)
SELECT wallet_id,
       'funding',
       round((1000 + power(u_amount, 2) * 299000) / 500) * 500,
       CASE WHEN u_card >= 0.20                                  THEN 'completed'
            WHEN at >= TIMESTAMPTZ '2026-10-08 21:00+01'         THEN 'pending'
            WHEN u_fail < 0.04                                   THEN 'failed'
            ELSE 'completed' END,
       CASE WHEN u_card >= 0.20                                  THEN 'Bank transfer top-up'
            WHEN at >= TIMESTAMPTZ '2026-10-08 21:00+01'         THEN 'Card top-up: awaiting confirmation'
            WHEN u_fail < 0.04                                   THEN 'Card top-up: card declined'
            ELSE 'Card top-up' END,
       at,
       0
FROM timed
WHERE at < active_until
ORDER BY n;

-- ---------------------------------------------------------------------
-- 6. Merchant payments from main wallets to active merchants, within the
--    category's range and skewed towards small amounts. A payment can
--    only happen once both the wallet and the merchant exist, and before
--    the customer went quiet. 0.4% are declined (failed).
-- ---------------------------------------------------------------------
WITH draws AS MATERIALIZED (
    SELECT n,
           1 + floor((SELECT count(*) FROM seed_wallets)   * power(random(), 1.5))::int AS wallet_rn,
           1 + floor((SELECT count(*) FROM seed_merchants) * power(random(), 2.5))::int AS merchant_rn,
           random() AS u_time, random() AS u_amount, random() AS u_fail
    FROM generate_series(1, :payment_draws) AS n
),
windowed AS (
    SELECT d.*, w.wallet_id, w.active_until, m.merchant_id, m.category,
           greatest(w.opened_at, m.created_at) + interval '1 hour'
               + d.u_time * interval '373 days' AS at
    FROM draws d
    JOIN seed_wallets w   ON w.rn = d.wallet_rn
    JOIN seed_merchants m ON m.rn = d.merchant_rn
)
INSERT INTO seed_ledger (wallet_id, transaction_type, amount, status, merchant_id, narration, created_at, leg)
SELECT x.wallet_id,
       'merchant_payment',
       round((c.min_amount + power(x.u_amount, 3) * (c.max_amount - c.min_amount))::numeric,
             CASE WHEN c.kobo THEN 2 ELSE -1 END),
       CASE WHEN x.u_fail < 0.004 THEN 'failed' ELSE 'completed' END,
       x.merchant_id,
       c.narration,
       x.at,
       0
FROM windowed x
JOIN category_spend c USING (category)
WHERE x.at < x.active_until
ORDER BY x.n;

-- ---------------------------------------------------------------------
-- 7. Transfers. Senders are picked by busyness, receivers evenly. One in
--    ten transfers from a customer with a savings wallet goes to it
--    ("Move to savings"). A transfer can only happen while both wallets
--    are open and in use.
--    Amounts: 97% are NGN 500-100,000 in steps of 100; 3% are large,
--    NGN 250,000-2,500,000. Large transfers are held for compliance
--    review: those made since 6 October are still pending (the queue
--    query 7 reads), older ones were approved 2-30 hours later.
--    Of the rest, 1.5% failed before any money moved and 0.5% were
--    reversed (sender debited, credit timed out, money returned).
-- ---------------------------------------------------------------------
CREATE TEMP TABLE seed_transfers ON COMMIT DROP AS
WITH draws AS MATERIALIZED (
    SELECT n,
           1 + floor((SELECT count(*) FROM seed_wallets) * power(random(), 1.5))::int AS sender_rn,
           1 + floor((SELECT count(*) FROM seed_wallets) * random())::int             AS receiver_rn,
           random() AS u_savings, random() AS u_time, random() AS u_large, random() AS u_amount,
           random() AS u_status, random() AS u_reason, random() AS u_narration, random() AS u_delay
    FROM generate_series(1, :transfer_draws) AS n
),
paired AS (
    SELECT d.*,
           s.wallet_id AS sender_wallet_id,
           s.opened_at AS sender_opened_at,
           s.active_until AS sender_until,
           (d.u_savings < 0.10 AND s.savings_wallet_id IS NOT NULL) AS to_savings,
           CASE WHEN d.u_savings < 0.10 AND s.savings_wallet_id IS NOT NULL
                THEN s.savings_wallet_id ELSE r.wallet_id END AS receiver_wallet_id,
           CASE WHEN d.u_savings < 0.10 AND s.savings_wallet_id IS NOT NULL
                THEN s.savings_opened_at ELSE r.opened_at END AS receiver_opened_at,
           CASE WHEN d.u_savings < 0.10 AND s.savings_wallet_id IS NOT NULL
                THEN s.active_until ELSE r.active_until END AS receiver_until
    FROM draws d
    JOIN seed_wallets s ON s.rn = d.sender_rn
    JOIN seed_wallets r ON r.rn = d.receiver_rn
),
windowed AS (
    SELECT p.*,
           greatest(p.sender_opened_at, p.receiver_opened_at) + interval '1 hour' AS earliest,
           least(p.sender_until, p.receiver_until) AS latest
    FROM paired p
    WHERE p.sender_wallet_id <> p.receiver_wallet_id
),
timed AS (
    SELECT w.*,
           w.earliest + w.u_time * interval '373 days' AS made_at,
           w.u_large < 0.03 AS is_large
    FROM windowed w
    WHERE w.earliest + w.u_time * interval '373 days' < w.latest
),
decided AS (
    SELECT t.*,
           CASE WHEN t.is_large AND t.made_at >= TIMESTAMPTZ '2026-10-06 00:00+01' THEN 'pending'
                WHEN t.u_status < 0.015 THEN 'failed'
                WHEN t.u_status < 0.020 THEN 'reversed'
                ELSE 'completed' END AS status
    FROM timed t
)
SELECT n AS ord,
       sender_wallet_id,
       receiver_wallet_id,
       CASE WHEN is_large THEN round((250000 + power(u_amount, 2) * 2250000) / 1000) * 1000
            ELSE round((500 + power(u_amount, 2.5) * 99500) / 100) * 100 END::numeric(14,2) AS amount,
       CASE WHEN to_savings THEN 'Move to savings'
            ELSE (ARRAY['Rent contribution', 'School fees', 'Family support', 'Upkeep',
                        'Business supplies', 'Thank you', 'Ajo contribution', 'Aso-ebi contribution',
                        'Loan repayment', 'Birthday gift', 'Transport', 'Lunch money',
                        'Shared bill', 'For the event'])[1 + floor(u_narration * 14)::int]
       END::varchar(100) AS narration,
       status::varchar(10) AS status,
       CASE status
            WHEN 'failed'   THEN CASE WHEN u_reason < 0.7 THEN 'Insufficient funds'
                                      ELSE 'Transaction PIN entered incorrectly three times' END
            WHEN 'reversed' THEN 'Credit to receiver wallet timed out; funds returned to sender'
       END::varchar(200) AS failure_reason,
       made_at AS created_at,
       CASE status
            WHEN 'pending'  THEN NULL
            WHEN 'failed'   THEN made_at + (5 + u_delay * 55) * interval '1 second'
            WHEN 'reversed' THEN made_at + (3 + u_delay * 7) * interval '1 minute'
            ELSE CASE WHEN is_large THEN made_at + (2 + u_delay * 28) * interval '1 hour'
                      ELSE made_at END
       END AS processed_at,
       -- The sample's reference pattern: TRF, the Lagos date, then the
       -- day's 4-digit number, continuing after the sample's own numbers.
       ('TRF' || to_char(made_at, 'YYMMDD')
              || to_char(row_number() OVER (PARTITION BY made_at::date ORDER BY made_at, n)
                         + coalesce(p.last_number, 0), 'FM0000'))::varchar(20) AS reference
FROM decided
LEFT JOIN (SELECT created_at::date AS day, max(right(reference, 4)::int) AS last_number
           FROM transfers GROUP BY 1) p
       ON p.day = decided.made_at::date;

INSERT INTO transfers (reference, sender_wallet_id, receiver_wallet_id, amount, narration,
                       status, failure_reason, created_at, processed_at)
SELECT reference, sender_wallet_id, receiver_wallet_id, amount, narration,
       status, failure_reason, created_at, processed_at
FROM seed_transfers
ORDER BY created_at, ord;

-- Ledger rows for the transfers, as in the sample: a completed transfer
-- has a debit and a credit at the time it was processed; a reversed one
-- has the debit when it was made and the reversal when it was processed;
-- failed and pending transfers have no ledger rows (no money moved).
INSERT INTO seed_ledger (wallet_id, transaction_type, amount, status, transfer_ref, narration, created_at, leg)
SELECT sender_wallet_id, 'transfer_out', amount, 'completed', reference, narration,
       CASE WHEN status = 'completed' THEN processed_at ELSE created_at END, 1
FROM seed_transfers WHERE status IN ('completed', 'reversed')
UNION ALL
SELECT receiver_wallet_id, 'transfer_in', amount, 'completed', reference, narration, processed_at, 2
FROM seed_transfers WHERE status = 'completed'
UNION ALL
SELECT sender_wallet_id, 'reversal', amount, 'completed', reference, 'Reversal: ' || narration, processed_at, 3
FROM seed_transfers WHERE status = 'reversed';

-- ---------------------------------------------------------------------
-- 8. Opening top-ups. The draws above are random, so some wallets would
--    spend money before it arrived. For every wallet whose running balance
--    would dip below zero, add one bank top-up 30 minutes after it opened
--    (before any other activity), large enough to keep the balance at
--    NGN 5,000 or more at its lowest point. Adding a credit at the start
--    raises every later running balance by the same amount, so after this
--    no wallet is ever overdrawn.
-- ---------------------------------------------------------------------
INSERT INTO seed_ledger (wallet_id, transaction_type, amount, status, narration, created_at, leg)
SELECT low.wallet_id,
       'funding',
       ceil((5000 - low.lowest_balance) / 1000) * 1000,
       'completed',
       'Bank transfer top-up',
       opened.opened_at + interval '30 minutes',
       0
FROM (
    SELECT wallet_id, min(running_balance) AS lowest_balance
    FROM (
        SELECT wallet_id,
               sum(CASE WHEN transaction_type IN ('funding', 'transfer_in', 'reversal')
                        THEN amount ELSE -amount END)
                   OVER (PARTITION BY wallet_id ORDER BY created_at, leg
                         ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS running_balance
        FROM seed_ledger
        WHERE status = 'completed'
    ) r
    GROUP BY wallet_id
    HAVING min(running_balance) < 0
) low
JOIN (SELECT wallet_id, opened_at FROM seed_wallets
      UNION ALL
      SELECT savings_wallet_id, savings_opened_at FROM seed_wallets WHERE savings_wallet_id IS NOT NULL
     ) opened USING (wallet_id)
ORDER BY low.wallet_id;

-- ---------------------------------------------------------------------
-- 9. Move the staged rows into the real ledger, in time order, so
--    transaction_id follows time as it does in the sample. References:
--    TXN, the Lagos date, then the day's 4-digit number after the
--    sample's own.
-- ---------------------------------------------------------------------
ANALYZE seed_ledger;

INSERT INTO transactions (reference, wallet_id, transaction_type, amount, status,
                          transfer_id, merchant_id, narration, created_at)
SELECT 'TXN' || to_char(l.created_at, 'YYMMDD')
             || to_char(row_number() OVER (PARTITION BY l.created_at::date
                                           ORDER BY l.created_at, l.leg, l.wallet_id)
                        + coalesce(p.last_number, 0), 'FM0000'),
       l.wallet_id, l.transaction_type, l.amount, l.status,
       t.transfer_id, l.merchant_id, l.narration, l.created_at
FROM seed_ledger l
LEFT JOIN transfers t ON t.reference = l.transfer_ref
LEFT JOIN (SELECT created_at::date AS day, max(right(reference, 4)::int) AS last_number
           FROM transactions GROUP BY 1) p
       ON p.day = l.created_at::date
ORDER BY l.created_at, l.leg, l.wallet_id;

-- ---------------------------------------------------------------------
-- 10. Set each new wallet's stored balance from its completed ledger rows
--     (the deliberate denormalisation from Portfolio 1).
-- ---------------------------------------------------------------------
UPDATE wallets w
SET balance = l.ledger_balance
FROM (
    SELECT wallet_id,
           sum(CASE WHEN transaction_type IN ('funding', 'transfer_in', 'reversal')
                    THEN amount ELSE -amount END) AS ledger_balance
    FROM transactions
    WHERE status = 'completed' AND wallet_id > 25
    GROUP BY wallet_id
) l
WHERE w.wallet_id = l.wallet_id;

-- ---------------------------------------------------------------------
-- 11. Integrity audit before COMMIT, the same checks as Portfolio 1 plus
--     one more. Any failure aborts the script and nothing is kept.
--     1. Every stored balance equals completed credits minus debits.
--     2. Every transfer ledger row matches its transfer's amount and wallet.
--     3. No wallet's running balance ever went below zero, replaying the
--        whole ledger in time order.
--     4. No sample wallet gained any rows (it still has its 47 rows).
-- ---------------------------------------------------------------------
DO $$
DECLARE
    balance_mismatches integer;
    leg_mismatches     integer;
    overdrawn_wallets  integer;
    sample_rows        integer;
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

    SELECT count(DISTINCT wallet_id) INTO overdrawn_wallets
    FROM (
        SELECT wallet_id,
               sum(CASE WHEN transaction_type IN ('funding', 'transfer_in', 'reversal')
                        THEN amount ELSE -amount END)
                   OVER (PARTITION BY wallet_id ORDER BY created_at, transaction_id) AS running_balance
        FROM transactions
        WHERE status = 'completed'
    ) r
    WHERE running_balance < 0;

    SELECT count(*) INTO sample_rows FROM transactions WHERE wallet_id <= 25;

    IF balance_mismatches > 0 THEN
        RAISE EXCEPTION 'Balance audit failed: % wallet(s) differ from the ledger', balance_mismatches;
    END IF;
    IF leg_mismatches > 0 THEN
        RAISE EXCEPTION 'Transfer audit failed: % ledger row(s) disagree with their transfer', leg_mismatches;
    END IF;
    IF overdrawn_wallets > 0 THEN
        RAISE EXCEPTION 'Running balance audit failed: % wallet(s) dip below zero', overdrawn_wallets;
    END IF;
    IF sample_rows <> 47 THEN
        RAISE EXCEPTION 'Sample wallets changed: % ledger rows instead of 47', sample_rows;
    END IF;
    RAISE NOTICE 'Balance audit passed: all % wallet balances equal their ledger totals',
                 (SELECT count(*) FROM wallets);
    RAISE NOTICE 'Transfer audit passed: all % transfer ledger rows match their transfer',
                 (SELECT count(*) FROM transactions WHERE transfer_id IS NOT NULL);
    RAISE NOTICE 'Running balance audit passed: no wallet is ever below zero';
    RAISE NOTICE 'Sample wallets unchanged: still 47 ledger rows on wallets 1-25';
END
$$;

COMMIT;

-- ---------------------------------------------------------------------
-- 12. VACUUM ANALYZE outside the transaction:
--     * ANALYZE refreshes the planner's statistics (row counts, value
--       distributions). Without it the planner would still plan for the
--       47-row sample table.
--     * VACUUM marks the freshly loaded pages all-visible, which an
--       index-only scan needs to skip reading the table.
-- ---------------------------------------------------------------------
VACUUM (ANALYZE) customers, merchants, wallets, transfers, transactions;

\timing off

\echo
\echo '=== Rows per table ==='
-- pos keeps the listing order: on tables this size PostgreSQL may count
-- them in parallel and return the UNION ALL branches in any order.
SELECT table_name, row_count
FROM (          SELECT 1 AS pos, 'customers' AS table_name, count(*) AS row_count FROM customers
      UNION ALL SELECT 2, 'merchants', count(*) FROM merchants
      UNION ALL SELECT 3, 'kyc_documents', count(*) FROM kyc_documents
      UNION ALL SELECT 4, 'wallets', count(*) FROM wallets
      UNION ALL SELECT 5, 'transfers', count(*) FROM transfers
      UNION ALL SELECT 6, 'transactions', count(*) FROM transactions
      UNION ALL SELECT 7, 'beneficiaries', count(*) FROM beneficiaries
      UNION ALL SELECT 8, 'audit_log', count(*) FROM audit_log) t
ORDER BY pos;

\echo '=== Ledger rows by type and status ==='
SELECT transaction_type, status, count(*) AS row_count, sum(amount) AS total_ngn
FROM transactions
GROUP BY transaction_type, status
ORDER BY transaction_type, status;

\echo '=== Transfers by status ==='
SELECT status, count(*) AS transfer_count, sum(amount) AS total_ngn
FROM transfers
GROUP BY status
ORDER BY status;

\echo '=== Ledger date range and busiest day ==='
SELECT min(created_at) AS first_row, max(created_at) AS last_row,
       (SELECT max(day_count) FROM (SELECT count(*) AS day_count FROM transactions
                                    GROUP BY created_at::date) d) AS busiest_day_rows
FROM transactions;

\echo '=== Table sizes (table + its indexes) ==='
SELECT relname AS table_name,
       pg_size_pretty(pg_table_size(oid))   AS table_size,
       pg_size_pretty(pg_indexes_size(oid)) AS index_size
FROM pg_class
WHERE relname IN ('customers', 'merchants', 'wallets', 'transfers', 'transactions')
ORDER BY pg_table_size(oid) DESC;
