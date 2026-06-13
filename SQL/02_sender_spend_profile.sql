-- =============================================================================
-- File    : 02_sender_spend_profile.sql
-- Project : UPI Merchant VPA Risk Scoring & Spend Anomaly Intelligence Engine
-- Step    : 2 of 6 — Build Sender Spend Profile (Baseline)
-- Depends : upi_transactions table (created by ingest.py)
--
-- PURPOSE:
--   Before you can call any transaction "anomalous", you first need to
--   know what is NORMAL for each sender.
--
--   This file creates a VIEW called sender_spend_profile that answers:
--   "For each sender, what is their typical spending pattern?"
--
--   Every sender gets their own personal baseline:
--     → How many transactions have they made?
--     → What is their average transaction amount?
--     → How much do their amounts vary? (standard deviation)
--     → What is their lowest and highest transaction?
--     → What is their typical login attempt count?
--     → What is their typical transaction velocity?
--
--   The next SQL file (03_anomaly_flag.sql) uses this baseline to
--   compare each NEW transaction against the sender's own history
--   and decide: normal or anomalous?
--
-- OUTPUT:
--   VIEW: sender_spend_profile
--   Rows: one row per unique upi_sender_id (495 senders)
--
-- RUN THIS IN:
--   MySQL Workbench → open this file → click Execute (lightning bolt)
--   OR run from Python: pd.read_sql("SELECT * FROM sender_spend_profile", engine)
-- =============================================================================


-- -----------------------------------------------------------------------------
-- STEP 1 — Drop the view if it already exists
-- -----------------------------------------------------------------------------
-- WHY: If you re-run this file after making changes, MySQL will throw an error
--      saying "view already exists". DROP VIEW IF EXISTS prevents that.
--      It is safe — if the view does not exist yet, this line does nothing.

DROP VIEW IF EXISTS sender_spend_profile;


-- -----------------------------------------------------------------------------
-- STEP 2 — Create the sender_spend_profile VIEW
-- -----------------------------------------------------------------------------

CREATE VIEW sender_spend_profile AS

SELECT

    -- ── IDENTITY ──────────────────────────────────────────────────────────────

    upi_sender_id,
    -- The sender's unique ID (e.g. AC00128).
    -- This is the GROUP BY key — every calculation below is
    -- computed separately for EACH sender.


    -- ── TRANSACTION VOLUME ────────────────────────────────────────────────────

    COUNT(*)                            AS total_txns,
    -- How many transactions this sender has made in total.
    -- AC00128 → 5 transactions
    -- AC00004 → 9 transactions
    -- Used to judge reliability of the baseline:
    -- a sender with 2 transactions has a less reliable baseline
    -- than one with 20 transactions.

    SUM(CASE WHEN txn_type = 'Debit'
             THEN 1 ELSE 0 END)         AS debit_txns,
    -- Count of OUTGOING payments only.
    -- WHY: Only Debit transactions represent money going OUT to a merchant.
    --      Credit transactions are incoming money — the sender cannot
    --      "anomalously" receive money. We track debits separately
    --      because the anomaly detection in the next file only flags
    --      Debit transactions.


    -- ── AMOUNT STATISTICS (DEBIT ONLY) ────────────────────────────────────────
    -- All amount stats below are calculated on Debit transactions only.
    -- This gives a cleaner baseline — we want to know "how much does
    -- this person normally SPEND", not "how much do they receive".

    ROUND(
        AVG(CASE WHEN txn_type = 'Debit'
                 THEN txn_amount_inr END), 2
    )                                   AS avg_debit_amount,
    -- The sender's AVERAGE outgoing payment amount.
    -- This is the centre of their normal range.
    -- AC00128 avg = ₹250 → anything near ₹250 is normal for them
    -- AC00010 avg = ₹395 → anything near ₹395 is normal for them
    -- The z-score in the next file uses this as the reference point.

    ROUND(
        STD(CASE WHEN txn_type = 'Debit'
                 THEN txn_amount_inr END), 2
    )                                   AS std_debit_amount,
    -- The STANDARD DEVIATION of the sender's outgoing amounts.
    -- This measures how much their spending varies.
    --
    -- Low std  (e.g. ₹30)  → sender always pays similar amounts
    --                          → even ₹500 would look very suspicious
    -- High std (e.g. ₹400) → sender's amounts vary a lot
    --                          → ₹500 might be normal for them
    --
    -- IMPORTANT: If a sender has only 1 Debit transaction, STD = NULL.
    -- The next file handles this with NULLIF() to avoid division by zero.
    -- Your data has 24 such senders — they are kept but treated carefully.

    ROUND(
        MIN(CASE WHEN txn_type = 'Debit'
                 THEN txn_amount_inr END), 2
    )                                   AS min_debit_amount,
    -- The smallest outgoing payment this sender has ever made.
    -- Useful for context — if someone's min is ₹7, they do micro-payments.

    ROUND(
        MAX(CASE WHEN txn_type = 'Debit'
                 THEN txn_amount_inr END), 2
    )                                   AS max_debit_amount,
    -- The largest outgoing payment this sender has ever made.
    -- If max is ₹650 normally, a new ₹8,500 payment is clearly suspicious.

    ROUND(
        AVG(CASE WHEN txn_type = 'Debit'
                 THEN txn_amount_inr END)
        + (2 * STD(CASE WHEN txn_type = 'Debit'
                        THEN txn_amount_inr END)), 2
    )                                   AS upper_normal_limit,
    -- The UPPER BOUNDARY of what is considered normal for this sender.
    -- Formula: avg + (2 × std)
    --
    -- This comes from statistics — in a normal distribution,
    -- 95% of values fall within 2 standard deviations of the mean.
    -- Anything ABOVE this limit is in the top 2.5% — unusual enough to flag.
    --
    -- Example for AC00128:
    --   avg_debit_amount = ₹250
    --   std_debit_amount = ₹72
    --   upper_normal_limit = 250 + (2 × 72) = ₹394
    --   → Any payment above ₹394 is unusual for AC00128
    --   → The ₹8,500 payment to fastdeal_shop is 23× above the limit
    --
    -- NULL if sender has only 1 transaction (no std available).


    -- ── BEHAVIOUR SIGNALS ─────────────────────────────────────────────────────

    ROUND(AVG(login_attempts), 2)       AS avg_login_attempts,
    -- Average number of login attempts before completing a transaction.
    -- Normal users: 1.0 to 1.5
    -- Suspicious pattern: consistently 3+ login attempts
    -- This signal combines with high amounts in the anomaly layer.

    ROUND(AVG(txn_velocity_1hr), 2)     AS avg_velocity,
    -- The sender's typical transaction velocity per hour.
    -- Normal users: 1.0 to 1.5 transactions per hour on average
    -- High-velocity senders: 3.0+ on average
    -- Used to establish whether high velocity is normal for this specific sender
    -- or if it is a new/unusual pattern.

    ROUND(AVG(txn_duration_sec), 2)     AS avg_duration_sec,
    -- Average time the sender takes to complete a transaction (in seconds).
    -- Very fast transactions (< 15 seconds) can indicate automated fraud tools.
    -- Very slow transactions (> 250 seconds) can indicate hesitation or
    -- social engineering in progress.


    -- ── RELIABILITY FLAG ──────────────────────────────────────────────────────

    CASE
        WHEN COUNT(*) >= 5 THEN 'Reliable'
        WHEN COUNT(*) >= 2 THEN 'Low sample'
        ELSE                    'Single transaction'
    END                                 AS baseline_quality
    -- How trustworthy is this sender's baseline?
    --
    -- Reliable          (5+ transactions) → std is meaningful, baseline is solid
    -- Low sample        (2-4 transactions) → baseline exists but less precise
    -- Single transaction (1 transaction)  → no std possible, handle with care
    --
    -- The anomaly flag in the next file uses this to apply
    -- different thresholds for low-sample senders.

FROM upi_transactions

GROUP BY upi_sender_id;
-- GROUP BY ensures every calculation above is computed
-- SEPARATELY for each unique sender — not across all 2,512 rows.
-- Result: one row per sender = 495 rows in this view.


-- =============================================================================
-- VERIFICATION QUERIES
-- Run these after creating the view to confirm it works correctly.
-- =============================================================================

-- ── Verify 1: Check the view was created and has 495 rows ───────────────────
SELECT COUNT(*) AS total_senders
FROM   sender_spend_profile;
-- Expected: 495

-- ── Verify 2: Check the full structure — first 10 senders ───────────────────
SELECT *
FROM   sender_spend_profile
LIMIT  10;

-- ── Verify 3: Check senders with NULL std (single transaction senders) ───────
SELECT   upi_sender_id,
         total_txns,
         debit_txns,
         avg_debit_amount,
         std_debit_amount,      -- will be NULL for single-transaction senders
         upper_normal_limit,    -- will be NULL for single-transaction senders
         baseline_quality
FROM     sender_spend_profile
WHERE    std_debit_amount IS NULL
ORDER BY total_txns DESC;
-- Expected: 24 rows (the 24 senders with only 1 transaction)

-- ── Verify 4: Top 10 senders with highest average spend ─────────────────────
SELECT   upi_sender_id,
         total_txns,
         avg_debit_amount,
         std_debit_amount,
         upper_normal_limit,
         max_debit_amount,
         baseline_quality
FROM     sender_spend_profile
ORDER BY avg_debit_amount DESC
LIMIT    10;
-- These high-average senders are less likely to flag anomalies
-- because their normal range is already high.

-- ── Verify 5: Senders whose max already exceeds their upper normal limit ──────
-- These are senders who already have at least one unusual transaction
-- in their own history — their baseline is naturally wide.
SELECT   upi_sender_id,
         avg_debit_amount,
         std_debit_amount,
         upper_normal_limit,
         max_debit_amount,
         ROUND(max_debit_amount - upper_normal_limit, 2) AS excess_above_limit
FROM     sender_spend_profile
WHERE    max_debit_amount > upper_normal_limit
AND      upper_normal_limit IS NOT NULL
ORDER BY excess_above_limit DESC
LIMIT    10;
-- These senders are the most interesting ones —
-- they have already made at least one payment beyond their own normal limit.
-- Their excess_above_limit amount previews what anomaly scores will look like.
