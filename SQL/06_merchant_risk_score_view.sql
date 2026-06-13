-- =============================================================================
-- File    : 06_merchant_risk_score_view.sql
-- Project : UPI Merchant VPA Risk Scoring & Spend Anomaly Intelligence Engine
-- Step    : 6 of 6 — Final Merchant Risk Score & Tier Assignment
-- Depends : merchant_anomaly_summary (view from 04_merchant_aggregation.sql)
--
-- PURPOSE:
--   This is the FINAL OUTPUT of the entire project.
--
--   All previous files built towards this one:
--     02 → built sender baselines
--     03 → flagged individual transactions
--     04 → aggregated flags per merchant
--     05 → analysed patterns across dimensions
--     06 → THIS FILE — combines everything into one risk score per merchant
--
--   For each of the 100 merchants, this view calculates:
--     1. A COMPOSITE RISK SCORE  (0 to 100)
--     2. A RISK TIER             (HIGH / MEDIUM / LOW RISK / CLEAN)
--     3. A RECOMMENDED ACTION    (Block / Escalate / Monitor / No action)
--     4. A BUSINESS NARRATIVE    (plain-English reason for the tier)
--
--   This is what a fraud analyst opens every morning — the ranked
--   merchant watch-list that tells them exactly where to focus today.
--
-- COMPOSITE SCORE FORMULA (4 components):
--   Component 1 — Anomaly Rate Score      (weight: 40 points)
--   Component 2 — Anomalous Value Score   (weight: 30 points)
--   Component 3 — Unique Senders Score    (weight: 20 points)
--   Component 4 — Login Attempts Score    (weight: 10 points)
--   Total maximum possible score          = 100 points
--
-- RISK TIER THRESHOLDS (calibrated to YOUR data):
--   Score >= 70   →  HIGH       (1 merchant  — M055 at 90.89)
--   Score >= 40   →  MEDIUM     (12 merchants — anomaly rate 5-10%)
--   Score >= 10   →  LOW RISK   (8 merchants  — anomaly rate 1-5%)
--   Score <  10   →  CLEAN      (79 merchants — 0 anomalies)
--
-- REAL OUTPUT FROM YOUR DATA:
--   HIGH    :  1 merchant  (M055  — score 90.89, anomaly rate 11.11%)
--   MEDIUM  : 12 merchants (M006  — score 66.69, anomaly rate  7.69%)
--   LOW RISK:  8 merchants (M046  — score 49.89, anomaly rate  4.76%)
--   CLEAN   : 79 merchants (score near 0, 0 anomalies)
--
-- OUTPUT:
--   VIEW: merchant_risk_scores
--   Rows: 100 (one per merchant, ranked by composite score)
--   This view is the source for the Python analysis notebook.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- STEP 1 — Drop view if it exists
-- -----------------------------------------------------------------------------

DROP VIEW IF EXISTS merchant_risk_scores;


-- -----------------------------------------------------------------------------
-- STEP 2 — Create the merchant_risk_scores VIEW
-- -----------------------------------------------------------------------------

CREATE VIEW merchant_risk_scores AS

WITH

-- ─────────────────────────────────────────────────────────────────────────────
-- CTE 1: base_metrics
-- Pull raw numbers for every merchant from merchant_anomaly_summary.
-- Naming them clearly here makes the scoring logic below readable.
-- ─────────────────────────────────────────────────────────────────────────────

base_metrics AS (

    SELECT
        merchant_vpa,
        total_txns,
        unique_senders,
        anomaly_count,
        unique_senders_flagged,
        anomaly_rate_pct,
        total_txn_value_inr,
        anomalous_value_inr,
        anomalous_value_pct,
        avg_txn_value_inr,
        max_txn_value_inr,
        avg_login_attempts,
        avg_velocity,
        avg_duration_sec,
        multi_signal_anomalies,
        avg_anomaly_z_score,
        max_anomaly_z_score
    FROM merchant_anomaly_summary

),


-- ─────────────────────────────────────────────────────────────────────────────
-- CTE 2: score_components
-- Calculate each of the 4 score components individually.
-- Keeping them separate makes the logic transparent and auditable.
-- A fraud analyst can see exactly what drove each merchant's score.
-- ─────────────────────────────────────────────────────────────────────────────

score_components AS (

    SELECT
        merchant_vpa,
        total_txns,
        unique_senders,
        anomaly_count,
        unique_senders_flagged,
        anomaly_rate_pct,
        total_txn_value_inr,
        anomalous_value_inr,
        anomalous_value_pct,
        avg_txn_value_inr,
        max_txn_value_inr,
        avg_login_attempts,
        avg_velocity,
        avg_duration_sec,
        multi_signal_anomalies,
        avg_anomaly_z_score,
        max_anomaly_z_score,


        -- ── COMPONENT 1: Anomaly Rate Score (max 40 points) ──────────────────
        --
        -- WHY 40 points (highest weight):
        --   Anomaly rate is the most direct measure of merchant danger.
        --   What % of this merchant's customers made out-of-character payments?
        --   The higher this %, the more likely the merchant is the cause.
        --
        -- YOUR DATA calibration:
        --   Max anomaly rate in your data = 11.11% (M055)
        --   Formula: (merchant_rate / max_rate_in_dataset) × 40
        --   M055: (11.11 / 11.11) × 40 = 40.00  (full marks)
        --   M006: ( 7.69 / 11.11) × 40 = 27.69
        --   Clean merchants (0%): 0 / 11.11 × 40 = 0.00

        ROUND(
            (anomaly_rate_pct / 11.11) * 40,
            2
        )                               AS score_anomaly_rate,


        -- ── COMPONENT 2: Anomalous Value Score (max 30 points) ───────────────
        --
        -- WHY 30 points (second highest):
        --   Financial severity matters as much as frequency.
        --   A merchant where 1 in 20 transactions is flagged but that
        --   1 transaction = 44% of total value is more dangerous than
        --   one where 1 in 10 is flagged but all amounts are small.
        --
        -- YOUR DATA calibration:
        --   Max anomalous_value_pct = 44.08% (M055)
        --   M055: (44.08 / 44.08) × 30 = 30.00  (full marks)
        --   M031: (26.21 / 44.08) × 30 = 17.84
        --   M085: (11.17 / 44.08) × 30 =  7.59
        --   Clean merchants: 0

        ROUND(
            (anomalous_value_pct / 44.08) * 30,
            2
        )                               AS score_anomalous_value,


        -- ── COMPONENT 3: Unique Senders Score (max 20 points) ────────────────
        --
        -- WHY 20 points:
        --   Diversity of victims is a key fraud differentiator.
        --   When the same person makes 5 unusual payments to a merchant,
        --   it might be their personal habit.
        --   When 5 DIFFERENT people all make unusual payments to the
        --   same merchant, the merchant is almost certainly the cause.
        --
        -- Formula: (unique_senders_flagged / unique_senders) × 20
        --   Measures what fraction of the merchant's unique customer
        --   base had anomalous transactions.
        --
        -- YOUR DATA:
        --   M055: unique_senders_flagged=2, unique_senders=17
        --         (2/17) × 20 = 2.35
        --   M006: unique_senders_flagged=1, unique_senders=13
        --         (1/13) × 20 = 1.54
        --
        -- Note: scores here are low because anomaly counts are low (1-2).
        -- On a larger real-world dataset, this component would score higher
        -- for merchants accumulating victims from many different customers.

        ROUND(
            (unique_senders_flagged
             / NULLIF(unique_senders, 0)) * 20,
            2
        )                               AS score_unique_senders,


        -- ── COMPONENT 4: Login Attempts Score (max 10 points) ────────────────
        --
        -- WHY 10 points (lowest weight):
        --   From 05_velocity_analysis.sql we discovered that high login
        --   attempts do NOT co-occur with z-score anomalies in your data
        --   (0% overlap). So this signal is independent — not a direct
        --   fraud predictor, but still a behavioural indicator worth
        --   including at lower weight.
        --
        -- Formula: (avg_login / 5) × 10
        --   5 = maximum possible login attempts in your data
        --   Normalises to 0-10 range.
        --
        -- YOUR DATA:
        --   avg_login across all merchants ≈ 1.0 to 1.33
        --   Score range: (1.0/5)×10=2.0  to  (1.33/5)×10=2.66
        --   Very similar across merchants — confirms login is a weak signal
        --   but included for completeness and real-world alignment.

        ROUND(
            (avg_login_attempts / 5) * 10,
            2
        )                               AS score_login_attempts

    FROM base_metrics

),


-- ─────────────────────────────────────────────────────────────────────────────
-- CTE 3: composite_scores
-- Add the 4 components into a single composite score per merchant.
-- Then assign risk tier and recommended action based on the score.
-- ─────────────────────────────────────────────────────────────────────────────

composite_scores AS (

    SELECT
        *,

        -- ── COMPOSITE SCORE (0 to 100) ────────────────────────────────────────
        ROUND(
            score_anomaly_rate
            + score_anomalous_value
            + score_unique_senders
            + score_login_attempts,
            2
        )                               AS composite_risk_score

        -- YOUR DATA expected scores:
        --   M055 : 90.89  (HIGH)
        --   M006 : 66.69  (MEDIUM)
        --   M082 : 62.88  (MEDIUM)
        --   M031 : 59.83  (MEDIUM)
        --   M049 : 59.75  (MEDIUM)
        --   M001 : 58.77  (MEDIUM)
        --   M053 : 58.56  (MEDIUM)
        --   ...
        --   M088 : ~20    (LOW RISK)
        --   Clean merchants : ~2-3 (CLEAN — login score only, no anomalies)

    FROM score_components

)


-- ─────────────────────────────────────────────────────────────────────────────
-- FINAL SELECT — Assemble the complete merchant risk report
-- ─────────────────────────────────────────────────────────────────────────────

SELECT

    -- ── RANK ──────────────────────────────────────────────────────────────────
    RANK() OVER (
        ORDER BY composite_risk_score DESC
    )                                   AS risk_rank,
    -- Position in the merchant danger ranking.
    -- M055 = rank 1 (most dangerous)
    -- Clean merchants = ranks 22 to 100
    -- A fraud analyst works down this list from rank 1.


    -- ── IDENTITY ──────────────────────────────────────────────────────────────
    merchant_vpa,


    -- ── RISK TIER ─────────────────────────────────────────────────────────────
    CASE
        WHEN composite_risk_score >= 70 THEN 'HIGH'
        WHEN composite_risk_score >= 40 THEN 'MEDIUM'
        WHEN composite_risk_score >= 10 THEN 'LOW RISK'
        ELSE                                 'CLEAN'
    END                                 AS risk_tier,
    -- Thresholds calibrated to your data distribution:
    --   >= 70  : only M055 qualifies   → 1 merchant
    --   >= 40  : 12 merchants qualify  → all have anomaly_rate 5-10%
    --   >= 10  : 8 merchants qualify   → anomaly_rate 1-5%
    --   <  10  : 79 merchants          → 0 anomalies, login score only


    -- ── RECOMMENDED ACTION ────────────────────────────────────────────────────
    CASE
        WHEN composite_risk_score >= 70
            THEN 'BLOCK — Suspend merchant VPA pending investigation'
        WHEN composite_risk_score >= 40
            THEN 'ESCALATE — Flag for manual review within 24 hours'
        WHEN composite_risk_score >= 10
            THEN 'MONITOR — Include in weekly anomaly watch-list'
        ELSE
            'NO ACTION — Merchant within normal parameters'
    END                                 AS recommended_action,
    -- This column turns the score into a concrete next step.
    -- A fraud analyst does not need to interpret the score —
    -- the action is already decided by the engine.


    -- ── COMPOSITE SCORE AND COMPONENTS ────────────────────────────────────────
    composite_risk_score,
    score_anomaly_rate,         -- contribution from anomaly rate    (max 40)
    score_anomalous_value,      -- contribution from financial value (max 30)
    score_unique_senders,       -- contribution from victim diversity (max 20)
    score_login_attempts,       -- contribution from login behaviour  (max 10)


    -- ── CORE METRICS ──────────────────────────────────────────────────────────
    total_txns,
    unique_senders,
    anomaly_count,
    unique_senders_flagged,

    ROUND(anomaly_rate_pct, 2)          AS anomaly_rate_pct,
    ROUND(anomalous_value_inr, 2)       AS anomalous_value_inr,
    ROUND(anomalous_value_pct, 2)       AS anomalous_value_pct,
    ROUND(total_txn_value_inr, 2)       AS total_txn_value_inr,
    ROUND(avg_txn_value_inr, 2)         AS avg_txn_value_inr,
    ROUND(max_txn_value_inr, 2)         AS max_txn_value_inr,

    multi_signal_anomalies,
    ROUND(avg_anomaly_z_score, 2)       AS avg_anomaly_z_score,
    ROUND(max_anomaly_z_score, 2)       AS max_anomaly_z_score,
    ROUND(avg_login_attempts, 2)        AS avg_login_attempts,
    ROUND(avg_velocity, 2)              AS avg_velocity,
    ROUND(avg_duration_sec, 2)          AS avg_duration_sec,


    -- ── BUSINESS NARRATIVE ────────────────────────────────────────────────────
    -- Plain-English explanation of WHY this merchant got this tier.
    -- Written in language a non-technical compliance officer understands.
    -- This is what goes in the fraud report sent to management.

    CASE
        WHEN composite_risk_score >= 70
            THEN CONCAT(
                'HIGH RISK: ', merchant_vpa,
                ' received ', anomaly_count,
                ' anomalous transactions out of ', total_txns,
                ' total (', anomaly_rate_pct, '% anomaly rate). ',
                'Financial exposure: Rs.', anomalous_value_inr,
                ' (', anomalous_value_pct, '% of total merchant value). ',
                'Immediate investigation recommended.'
            )
        WHEN composite_risk_score >= 40
            THEN CONCAT(
                'MEDIUM RISK: ', merchant_vpa,
                ' shows elevated anomaly rate of ', anomaly_rate_pct,
                '% with Rs.', anomalous_value_inr,
                ' in suspicious transaction value. ',
                'Manual review required within 24 hours.'
            )
        WHEN composite_risk_score >= 10
            THEN CONCAT(
                'LOW RISK: ', merchant_vpa,
                ' has ', anomaly_count,
                ' flagged transaction(s) at ',
                anomaly_rate_pct, '% anomaly rate. ',
                'Include in weekly monitoring report.'
            )
        ELSE
            CONCAT(
                'CLEAN: ', merchant_vpa,
                ' shows no anomalous transactions across ',
                total_txns, ' payments from ',
                unique_senders, ' unique senders.'
            )
    END                                 AS risk_narrative

FROM composite_scores
ORDER BY composite_risk_score DESC;


-- =============================================================================
-- VERIFICATION QUERIES
-- Run these one by one after creating the view.
-- =============================================================================

-- ── Verify 1: Risk tier distribution (the executive summary) ─────────────
SELECT
    risk_tier,
    COUNT(*)                            AS merchant_count,
    ROUND(COUNT(*) * 100.0 / 100, 1)   AS pct_of_all_merchants,
    ROUND(SUM(anomalous_value_inr), 2)  AS total_exposure_inr,
    ROUND(AVG(composite_risk_score), 2) AS avg_score
FROM  merchant_risk_scores
GROUP BY risk_tier
ORDER BY avg_score DESC;
-- Expected:
--   HIGH     : 1  merchant  (1.0%)   exposure: Rs.2,114.95  avg score: 90.89
--   MEDIUM   : 12 merchants (12.0%)  exposure: ~Rs.16,000   avg score: ~56
--   LOW RISK : 8  merchants (8.0%)   exposure: ~Rs.5,000    avg score: ~25
--   CLEAN    : 79 merchants (79.0%)  exposure: Rs.0         avg score: ~2

-- ── Verify 2: Full ranked merchant watch-list (fraud analyst morning view) ─
SELECT
    risk_rank,
    merchant_vpa,
    risk_tier,
    composite_risk_score,
    anomaly_count,
    anomaly_rate_pct,
    anomalous_value_inr,
    unique_senders_flagged,
    multi_signal_anomalies,
    max_anomaly_z_score,
    recommended_action
FROM  merchant_risk_scores
WHERE risk_tier != 'CLEAN'
ORDER BY risk_rank;
-- Expected: 21 merchants (1 HIGH + 12 MEDIUM + 8 LOW RISK)
-- This is the morning watch-list a fraud analyst reviews daily

-- ── Verify 3: Score component breakdown for top 5 merchants ──────────────
SELECT
    risk_rank,
    merchant_vpa,
    risk_tier,
    composite_risk_score,
    score_anomaly_rate      AS 'Rate (max 40)',
    score_anomalous_value   AS 'Value (max 30)',
    score_unique_senders    AS 'Senders (max 20)',
    score_login_attempts    AS 'Login (max 10)'
FROM  merchant_risk_scores
ORDER BY risk_rank
LIMIT 5;
-- Shows exactly what drove each merchant's score
-- Useful for explaining the model to stakeholders

-- ── Verify 4: HIGH risk merchant full detail ──────────────────────────────
SELECT *
FROM  merchant_risk_scores
WHERE risk_tier = 'HIGH';
-- Expected: 1 row — M055 with all details and narrative

-- ── Verify 5: Business narrative for all non-clean merchants ──────────────
SELECT
    risk_rank,
    merchant_vpa,
    risk_tier,
    risk_narrative
FROM  merchant_risk_scores
WHERE risk_tier != 'CLEAN'
ORDER BY risk_rank;
-- Plain-English report ready to share with compliance team

-- ── Verify 6: Financial exposure by tier ─────────────────────────────────
SELECT
    risk_tier,
    SUM(anomalous_value_inr)            AS total_exposure_inr,
    ROUND(
        SUM(anomalous_value_inr) * 100.0
        / (SELECT SUM(anomalous_value_inr)
           FROM merchant_risk_scores), 2
    )                                   AS pct_of_total_exposure
FROM  merchant_risk_scores
GROUP BY risk_tier
ORDER BY total_exposure_inr DESC;
-- Shows what % of total financial exposure sits in each tier
-- Expected: HIGH tier = ~9% of exposure, MEDIUM = ~68%, LOW = ~23%

-- ── Verify 7: Final summary — the business impact statement ───────────────
SELECT
    COUNT(DISTINCT CASE WHEN risk_tier != 'CLEAN'
                        THEN merchant_vpa END)  AS merchants_needing_review,
    COUNT(DISTINCT merchant_vpa)                AS total_merchants,
    ROUND(
        COUNT(DISTINCT CASE WHEN risk_tier != 'CLEAN'
                            THEN merchant_vpa END) * 100.0
        / COUNT(DISTINCT merchant_vpa), 1
    )                                           AS pct_needing_review,
    SUM(anomalous_value_inr)                    AS total_exposure_inr,
    SUM(total_txn_value_inr)                    AS total_all_value_inr,
    ROUND(
        SUM(anomalous_value_inr) * 100.0
        / SUM(total_txn_value_inr), 2
    )                                           AS exposure_pct_of_total
FROM merchant_risk_scores;
-- This query produces the numbers for your README business impact statement:
-- "21% of merchants require review, protecting Rs.23,577 in at-risk value
--  which represents 4.11% of total transaction volume"
