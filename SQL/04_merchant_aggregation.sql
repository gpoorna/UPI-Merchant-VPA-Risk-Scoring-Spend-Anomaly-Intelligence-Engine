-- =============================================================================
-- File    : 04_merchant_aggregation.sql
-- Project : UPI Merchant VPA Risk Scoring & Spend Anomaly Intelligence Engine
-- Step    : 4 of 6 — Merchant-Level Anomaly Aggregation (Layer 2 begins)
-- Depends : flagged_transactions (view from 03_anomaly_flag.sql)
--
-- PURPOSE:
--   Layer 1 (03_anomaly_flag.sql) answered:
--   "Is this individual transaction suspicious?"
--
--   Layer 2 (this file) answers:
--   "Which merchants are consistently linked to suspicious transactions?"
--
--   This is the shift from TRANSACTION-level thinking to MERCHANT-level
--   thinking — the core insight of the entire project.
--
--   This view takes the 19 anomaly flags spread across 1,944 transactions
--   and GROUP BY merchant_vpa to see which merchants accumulate the most
--   fraud signals.
--
-- REAL NUMBERS FROM MY DATA:
--   Total unique merchants           : 100
--   Merchants with 0 anomalies       : 79  (clean)
--   Merchants with 1+ anomalies      : 21  (need monitoring)
--   Highest anomaly rate             : 11.11% (M055 — 2 out of 18 txns)
--   Total anomalous value exposure   : ₹23,577.50
--   Anomalous value as % of total    : 4.11%
--
-- OUTPUT:
--   VIEW: merchant_anomaly_summary
--   Rows: 100 (one row per merchant)
--   Key columns: anomaly_count, anomaly_rate_pct, anomalous_value_inr,
--                unique_senders_flagged, multi_signal_count
--
-- RUN AFTER: 03_anomaly_flag.sql
-- =============================================================================


-- -----------------------------------------------------------------------------
-- STEP 1 — Drop view if it exists
-- -----------------------------------------------------------------------------

DROP VIEW IF EXISTS merchant_anomaly_summary;


-- -----------------------------------------------------------------------------
-- STEP 2 — Create the merchant_anomaly_summary VIEW
-- -----------------------------------------------------------------------------

CREATE VIEW merchant_anomaly_summary AS

SELECT

    -- ── IDENTITY ──────────────────────────────────────────────────────────────

    merchant_vpa,
    -- The merchant's Virtual Payment Address.
    -- This is the GROUP BY key — every calculation below is computed
    -- separately for EACH merchant.
    -- Example: M055, M006, M082 etc.


    -- ── TRANSACTION VOLUME ────────────────────────────────────────────────────

    COUNT(*)                                AS total_txns,
    -- Total Debit transactions received by this merchant.
    -- Your data: range is 9 to 29 transactions per merchant.
    -- Average: ~19 transactions per merchant.
    -- M055 received 18 transactions.

    COUNT(DISTINCT upi_sender_id)           AS unique_senders,
    -- How many different senders paid this merchant.
    -- Your data: every merchant has a different sender for almost every txn.
    -- Minimum unique senders: 9, Maximum: 28.
    --
    -- WHY THIS MATTERS:
    -- If 5 different people (not the same person) all have anomalous
    -- payments to the same merchant — that is a much stronger signal
    -- than 1 person making 5 anomalous payments.
    -- Different victims = pattern, not coincidence.


    -- ── ANOMALY COUNTS ────────────────────────────────────────────────────────

    SUM(is_anomaly_final)                   AS anomaly_count,
    -- Total number of flagged transactions linked to this merchant.
    -- M055: 2 anomalies (highest in your data)
    -- M006, M082, M053... : 1 anomaly each
    -- 79 merchants: 0 anomalies

    COUNT(DISTINCT CASE
        WHEN is_anomaly_final = 1
        THEN upi_sender_id
    END)                                    AS unique_senders_flagged,
    -- How many DIFFERENT senders had anomalous transactions at this merchant.
    --
    -- This is more powerful than anomaly_count alone.
    -- Example:
    --   Merchant A: 3 anomalies — all from the SAME sender
    --     → possibly one person's unusual behaviour
    --   Merchant B: 3 anomalies — from 3 DIFFERENT senders
    --     → three separate victims → much stronger fraud signal
    --
    -- Your data: since most merchants have 1 anomaly each,
    -- unique_senders_flagged will mostly equal anomaly_count.
    -- M055 (2 anomalies) is the key one to watch.


    -- ── ANOMALY RATE ──────────────────────────────────────────────────────────

    ROUND(
        SUM(is_anomaly_final) * 100.0 / COUNT(*),
        2
    )                                       AS anomaly_rate_pct,
    -- What % of this merchant's transactions were flagged.
    --
    -- Formula: (flagged txns / total txns) × 100
    --
    -- M055: (2 / 18) × 100 = 11.11%  ← highest in your data
    -- M006: (1 / 13) × 100 =  7.69%
    -- M082: (1 / 14) × 100 =  7.14%
    -- Most merchants: 0.00%
    --
    -- This is the PRIMARY ranking metric for merchant risk scoring.
    -- The higher this number, the more dangerous the merchant.


    -- ── FINANCIAL EXPOSURE ────────────────────────────────────────────────────

    ROUND(SUM(txn_amount_inr), 2)           AS total_txn_value_inr,
    -- Total rupee value of ALL transactions at this merchant.
    -- Gives a sense of the merchant's transaction scale.

    ROUND(
        SUM(CASE WHEN is_anomaly_final = 1
                 THEN txn_amount_inr
                 ELSE 0 END),
        2
    )                                       AS anomalous_value_inr,
    -- Total rupee value of ONLY the flagged transactions.
    -- This is the financial exposure — how much money is at risk.
    --
    -- M055: ₹2,114.95 at risk
    -- M082: ₹1,431.30 at risk
    -- M049: ₹1,647.74 at risk
    --
    -- A merchant with anomaly_rate = 5% but anomalous_value = ₹50,000
    -- is more dangerous than one with 8% rate but only ₹500 at risk.
    -- This column captures the financial severity, not just frequency.

    ROUND(
        SUM(CASE WHEN is_anomaly_final = 1
                 THEN txn_amount_inr
                 ELSE 0 END)
        * 100.0 / NULLIF(SUM(txn_amount_inr), 0),
        2
    )                                       AS anomalous_value_pct,
    -- Anomalous transactions as % of total transaction value at this merchant.
    -- A different angle from anomaly_rate_pct (which is count-based).
    -- This is value-based.
    --
    -- Example:
    --   Merchant has 20 txns, 1 flagged
    --   anomaly_rate_pct = 5% (count-based)
    --   But if that 1 flagged txn = ₹8,500 out of ₹9,000 total
    --   anomalous_value_pct = 94% (value-based)
    --   The value-based view shows the true financial danger.

    ROUND(AVG(txn_amount_inr), 2)           AS avg_txn_value_inr,
    -- Average transaction value at this merchant across all customers.
    -- Helps detect merchants that consistently attract high-value payments —
    -- a characteristic of fake merchant scams.

    ROUND(MAX(txn_amount_inr), 2)           AS max_txn_value_inr,
    -- Largest single transaction at this merchant.
    -- A very high max vs a low average = strong anomaly signal.
    -- Example: avg ₹266 but max ₹2,114 → suspicious spread.


    -- ── BEHAVIOURAL SIGNALS ───────────────────────────────────────────────────

    ROUND(AVG(login_attempts), 2)           AS avg_login_attempts,
    -- Average login attempts across all customers paying this merchant.
    -- Baseline for the whole dataset is ~1.5 attempts.
    -- A merchant where customers average 3+ login attempts = suspicious.
    -- Could mean: social engineering keeping victims on the phone
    -- while they struggle to log in and make payment.

    ROUND(AVG(txn_velocity_1hr), 2)         AS avg_velocity,
    -- Average transaction velocity of customers paying this merchant.
    -- High avg velocity = customers often make multiple payments in one hour
    -- before reaching this merchant = possible targeted fraud pattern.

    ROUND(AVG(txn_duration_sec), 2)         AS avg_duration_sec,
    -- Average time to complete transactions at this merchant.
    -- Very fast avg (<20 sec) = possible automated payments.
    -- Very slow avg (>200 sec) = customers hesitating (social engineering?).


    -- ── MULTI-SIGNAL STRENGTH ─────────────────────────────────────────────────

    SUM(CASE WHEN is_anomaly_final = 1
             AND  risk_signal_count >= 2
             THEN 1 ELSE 0 END)             AS multi_signal_anomalies,
    -- Count of flagged transactions at this merchant where
    -- 2 or more fraud signals fired simultaneously.
    --
    -- A merchant linked to multi-signal anomalies is far more
    -- dangerous than one with single-signal flags.
    --
    -- Example:
    --   Single-signal anomaly: high z-score only → could be legitimate
    --   Multi-signal anomaly:  high z-score + high velocity + high login
    --                          → multiple independent red flags = strong fraud

    ROUND(AVG(
        CASE WHEN is_anomaly_final = 1
             THEN z_score END
    ), 2)                                   AS avg_anomaly_z_score,
    -- Average z-score of the flagged transactions at this merchant.
    -- Shows how EXTREME the anomalies are, not just how many.
    --
    -- Merchant A: 1 anomaly with z=2.1 → mildly unusual
    -- Merchant B: 1 anomaly with z=8.5 → extremely unusual
    -- Same anomaly_count, very different danger level.

    ROUND(MAX(
        CASE WHEN is_anomaly_final = 1
             THEN z_score END
    ), 2)                                   AS max_anomaly_z_score
    -- The single most extreme anomaly z-score at this merchant.
    -- The worst case transaction linked to this merchant.
    -- Higher = more suspicious.

FROM flagged_transactions
-- flagged_transactions already contains only Debit transactions
-- (filtered in 03_anomaly_flag.sql WHERE txn_type = 'Debit')

GROUP BY merchant_vpa;
-- One row per merchant — all calculations above are computed
-- independently for each merchant_vpa value.


-- =============================================================================
-- VERIFICATION QUERIES
-- Run these one by one after creating the view.
-- =============================================================================

-- ── Verify 1: Total merchants (expect 100) ────────────────────────────────
SELECT COUNT(*) AS total_merchants
FROM   merchant_anomaly_summary;

-- ── Verify 2: Merchants split by anomaly status ───────────────────────────
SELECT
    CASE WHEN anomaly_count = 0 THEN 'Clean (0 anomalies)'
         WHEN anomaly_count = 1 THEN 'Low (1 anomaly)'
         WHEN anomaly_count = 2 THEN 'Medium (2 anomalies)'
         ELSE                        'High (3+ anomalies)'
    END                     AS anomaly_status,
    COUNT(*)                AS merchant_count
FROM   merchant_anomaly_summary
GROUP BY anomaly_status
ORDER BY merchant_count DESC;
-- Expected:
--   Clean     : 79 merchants
--   Low       : 20 merchants
--   Medium    :  1 merchant (M055)

-- ── Verify 3: Top 10 merchants ranked by anomaly rate ─────────────────────
SELECT
    merchant_vpa,
    total_txns,
    unique_senders,
    anomaly_count,
    unique_senders_flagged,
    anomaly_rate_pct,
    anomalous_value_inr,
    anomalous_value_pct,
    avg_login_attempts,
    avg_velocity,
    multi_signal_anomalies,
    avg_anomaly_z_score,
    max_anomaly_z_score
FROM   merchant_anomaly_summary
WHERE  anomaly_count > 0
ORDER BY anomaly_rate_pct DESC, anomalous_value_inr DESC
LIMIT  10;
-- Expected top: M055 (11.11%), M006 (7.69%), M082 (7.14%)

-- ── Verify 4: Financial exposure summary ─────────────────────────────────
SELECT
    COUNT(*)                        AS total_merchants,
    SUM(total_txn_value_inr)        AS total_all_value,
    SUM(anomalous_value_inr)        AS total_at_risk_value,
    ROUND(
        SUM(anomalous_value_inr) * 100.0
        / SUM(total_txn_value_inr), 2
    )                               AS pct_value_at_risk
FROM merchant_anomaly_summary;
-- Expected: ₹23,577.50 at risk = 4.11% of ₹573,463 total

-- ── Verify 5: Clean merchants (0 anomalies) — confirm majority are clean ──
SELECT COUNT(*) AS clean_merchants
FROM   merchant_anomaly_summary
WHERE  anomaly_count = 0;
-- Expected: 79 out of 100

-- ── Verify 6: The full picture — all 21 merchants with anomalies ──────────
SELECT
    merchant_vpa,
    total_txns,
    anomaly_count,
    anomaly_rate_pct,
    anomalous_value_inr,
    unique_senders_flagged,
    multi_signal_anomalies,
    max_anomaly_z_score
FROM   merchant_anomaly_summary
WHERE  anomaly_count > 0
ORDER BY anomaly_rate_pct DESC;
-- This is the watch-list — 21 merchants that need monitoring
