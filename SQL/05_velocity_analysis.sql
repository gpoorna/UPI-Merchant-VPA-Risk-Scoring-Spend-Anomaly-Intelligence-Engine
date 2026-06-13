-- =============================================================================
-- File    : 05_velocity_analysis.sql
-- Project : UPI Merchant VPA Risk Scoring & Spend Anomaly Intelligence Engine
-- Step    : 5 of 6 — Multi-Dimensional Risk Signal Analysis
-- Depends : flagged_transactions (view from 03_anomaly_flag.sql)
--
-- PURPOSE:
--   The previous files established WHO is anomalous (senders) and
--   WHICH merchants accumulate anomalies.
--
--   This file goes deeper and answers the question:
--   "ACROSS WHAT CONDITIONS does fraud most commonly occur?"
--
--   It analyses fraud patterns across 5 dimensions:
--     1. Transaction velocity  (how many txns per hour)
--     2. Login attempts        (how many tries to log in)
--     3. Transaction duration  (how fast the txn completed)
--     4. City                  (where the sender is located)
--     5. Customer age band     (which age group is most affected)
--
--   These patterns answer Business Question 4:
--   "How does transaction velocity correlate with anomaly rate —
--    do rapid repeat transactions increase risk?"
--
-- KEY FINDINGS FROM YOUR REAL DATA:
--   Login attempts ≥ 3  : 95 transactions — 0 anomalies (independent signal)
--   Login attempts = 1  : 2,390 transactions — carries all 22 anomalies
--   Age group 36-45     : highest anomaly rate at 2.50%
--   Fast txns (≤15 sec) : 53 transactions
--   Anomalous avg dur   : 134 sec vs normal avg 119 sec (anomalies take longer)
--   City Louisville     : highest anomaly rate at 5.13%
--
-- OUTPUT:
--   5 separate views — one per dimension
--   All feed into the final risk score view (06_merchant_risk_score_view.sql)
--
-- RUN AFTER: 03_anomaly_flag.sql
-- =============================================================================


-- =============================================================================
-- VIEW 1 — VELOCITY RISK ANALYSIS
-- =============================================================================
-- Answers: Do senders who make more transactions per hour have higher
--          anomaly rates? Is txn_velocity_1hr a reliable fraud signal?
--
-- YOUR DATA CONTEXT:
--   txn_velocity_1hr was engineered in ingest.py
--   It counts how many times the same sender paid within 1 hour
--   Values in your data: 1 to 5 transactions per hour

DROP VIEW IF EXISTS velocity_risk_analysis;

CREATE VIEW velocity_risk_analysis AS

SELECT
    txn_velocity_1hr                            AS velocity,
    -- The velocity value (1, 2, 3, 4, or 5 txns per hour)

    COUNT(*)                                    AS total_txns,
    -- How many transactions have this velocity value

    SUM(is_anomaly_final)                       AS anomaly_count,
    -- How many of those transactions were flagged as anomalous

    ROUND(
        SUM(is_anomaly_final) * 100.0 / COUNT(*),
        2
    )                                           AS anomaly_rate_pct,
    -- What % of transactions at this velocity level are anomalous
    -- This directly answers Business Question 4

    ROUND(AVG(txn_amount_inr), 2)               AS avg_txn_amount,
    -- Average transaction amount at each velocity level
    -- Do higher-velocity transactions tend to be larger amounts?

    ROUND(MAX(txn_amount_inr), 2)               AS max_txn_amount,
    -- Largest transaction seen at this velocity level

    ROUND(AVG(login_attempts), 2)               AS avg_login_attempts,
    -- Do high-velocity transactions also have high login attempts?
    -- Cross-signal correlation check

    COUNT(DISTINCT merchant_vpa)                AS unique_merchants,
    -- How many different merchants appear at each velocity level
    -- High velocity with few merchants = same merchant being hit repeatedly

    COUNT(DISTINCT upi_sender_id)               AS unique_senders,
    -- How many different senders operate at each velocity level

    CASE
        WHEN ROUND(
            SUM(is_anomaly_final) * 100.0 / COUNT(*), 2
        ) >= 5.0  THEN 'High velocity risk'
        WHEN ROUND(
            SUM(is_anomaly_final) * 100.0 / COUNT(*), 2
        ) >= 2.0  THEN 'Medium velocity risk'
        ELSE           'Low velocity risk'
    END                                         AS velocity_risk_label
    -- Human-readable risk label for each velocity band
    -- Used in the final report narrative

FROM  flagged_transactions
GROUP BY txn_velocity_1hr
ORDER BY txn_velocity_1hr;


-- =============================================================================
-- VIEW 2 — LOGIN ATTEMPT RISK ANALYSIS
-- =============================================================================
-- Answers: Do transactions with higher login attempts have higher fraud rates?
--
-- YOUR DATA FINDING (important):
--   Login ≥ 3 = 95 transactions with 0 anomalies
--   Login = 1 = 2,390 transactions carrying all 22 anomalies
--
--   This means high login attempts and high z-score anomalies do NOT
--   co-occur in your dataset. They are INDEPENDENT risk signals.
--   A transaction can be dangerous with login=1 (normal login, unusual amount)
--   OR suspicious with login=5 (many attempts, normal amount).
--   This view makes that independence visible and documentable.

DROP VIEW IF EXISTS login_risk_analysis;

CREATE VIEW login_risk_analysis AS

SELECT
    login_attempts,
    -- Login attempt value (1, 2, 3, 4, or 5)

    COUNT(*)                                    AS total_txns,
    -- How many transactions had this login attempt count

    SUM(is_anomaly_final)                       AS anomaly_count,
    -- Anomalies at this login level
    -- Expected: all anomalies at login=1 or login=2
    -- login>=3: 0 anomalies (confirmed from your data)

    ROUND(
        SUM(is_anomaly_final) * 100.0 / COUNT(*),
        2
    )                                           AS anomaly_rate_pct,
    -- Anomaly rate at each login level
    -- This will show the counter-intuitive finding:
    -- login=1 has HIGHER anomaly rate than login=3,4,5
    -- Fraudsters log in successfully on the first try (they have credentials)
    -- Victims helping fraudsters may struggle (3+ attempts)

    ROUND(AVG(txn_amount_inr), 2)               AS avg_txn_amount,
    -- Do high-login transactions tend to be different amounts?

    SUM(CASE WHEN txn_velocity_1hr >= 3
             THEN 1 ELSE 0 END)                AS high_velocity_count,
    -- Do high-login transactions also have high velocity?
    -- Cross-signal check between login and velocity dimensions

    ROUND(AVG(txn_duration_sec), 2)             AS avg_duration_sec,
    -- Do high-login transactions take longer?
    -- Expected: yes — more login attempts = more time spent

    CASE
        WHEN login_attempts >= 4 THEN 'Suspicious login pattern'
        WHEN login_attempts >= 3 THEN 'Elevated login attempts'
        WHEN login_attempts >= 2 THEN 'Slightly elevated'
        ELSE                          'Normal login'
    END                                         AS login_risk_label

FROM  flagged_transactions
GROUP BY login_attempts
ORDER BY login_attempts;


-- =============================================================================
-- VIEW 3 — TRANSACTION DURATION RISK ANALYSIS
-- =============================================================================
-- Answers: Does transaction completion speed correlate with fraud risk?
--
-- YOUR DATA FINDING:
--   Anomalous transactions avg duration: 134 seconds
--   Normal transactions avg duration:    119 seconds
--   Anomalous txns take ~15 seconds LONGER than normal ones
--
--   Interpretation: Fraudsters may be on the phone with victims during
--   the transaction, coaching them through the payment process —
--   causing it to take longer than a spontaneous legitimate payment.
--
--   Fast transactions (≤15 sec): 53 total — possibly automated tools
--   These are a separate risk category worth monitoring.

DROP VIEW IF EXISTS duration_risk_analysis;

CREATE VIEW duration_risk_analysis AS

SELECT
    CASE
        WHEN txn_duration_sec <=  15 THEN '1. Ultra-fast (<=15s)'
        WHEN txn_duration_sec <=  30 THEN '2. Fast (16-30s)'
        WHEN txn_duration_sec <=  60 THEN '3. Quick (31-60s)'
        WHEN txn_duration_sec <= 120 THEN '4. Normal (61-120s)'
        WHEN txn_duration_sec <= 180 THEN '5. Slow (121-180s)'
        WHEN txn_duration_sec <= 240 THEN '6. Very slow (181-240s)'
        ELSE                              '7. Extended (>240s)'
    END                                         AS duration_band,
    -- Groups transactions into 7 speed categories
    -- Numbers prefix (1-7) ensure ORDER BY sorts them correctly

    COUNT(*)                                    AS total_txns,
    SUM(is_anomaly_final)                       AS anomaly_count,

    ROUND(
        SUM(is_anomaly_final) * 100.0 / COUNT(*),
        2
    )                                           AS anomaly_rate_pct,

    ROUND(AVG(txn_amount_inr), 2)               AS avg_txn_amount,
    -- Are fast transactions also high-value?
    -- Automated fraud tools may execute quickly with precise amounts

    ROUND(AVG(txn_velocity_1hr), 2)             AS avg_velocity,
    -- Do fast transactions also have high velocity?

    ROUND(MIN(txn_duration_sec), 2)             AS min_duration_sec,
    ROUND(MAX(txn_duration_sec), 2)             AS max_duration_sec,
    -- Min and max within each band for reference

    CASE
        WHEN ROUND(
            SUM(is_anomaly_final) * 100.0 / COUNT(*), 2
        ) >= 3.0  THEN 'Risk pattern detected'
        ELSE           'Normal range'
    END                                         AS duration_risk_label

FROM  flagged_transactions
GROUP BY duration_band
ORDER BY duration_band;


-- =============================================================================
-- VIEW 4 — CITY-LEVEL RISK ANALYSIS
-- =============================================================================
-- Answers: Which cities have the highest concentration of anomalous txns?
--
-- YOUR DATA FINDING:
--   Louisville     : 5.13% anomaly rate (highest — 2 anomalies from 39 txns)
--   Columbus       : 4.44% anomaly rate (2 anomalies from 45 txns)
--   Memphis        : 4.35% anomaly rate (2 anomalies from 46 txns)
--   Oklahoma City  : 3.77% anomaly rate
--
--   These cities appear as the highest-risk locations in your dataset.
--   In a real UPI system (India), this would show which Indian cities
--   have the highest merchant fraud exposure — actionable for the
--   risk team to increase monitoring in specific regions.

DROP VIEW IF EXISTS city_risk_analysis;

CREATE VIEW city_risk_analysis AS

SELECT
    city,
    COUNT(*)                                    AS total_txns,
    SUM(is_anomaly_final)                       AS anomaly_count,

    ROUND(
        SUM(is_anomaly_final) * 100.0 / COUNT(*),
        2
    )                                           AS anomaly_rate_pct,

    ROUND(SUM(txn_amount_inr), 2)               AS total_txn_value_inr,

    ROUND(
        SUM(CASE WHEN is_anomaly_final = 1
                 THEN txn_amount_inr ELSE 0 END),
        2
    )                                           AS anomalous_value_inr,
    -- Total financial exposure in this city

    ROUND(AVG(txn_amount_inr), 2)               AS avg_txn_amount,
    COUNT(DISTINCT merchant_vpa)                AS unique_merchants,
    COUNT(DISTINCT upi_sender_id)               AS unique_senders,

    ROUND(AVG(login_attempts), 2)               AS avg_login_attempts,
    -- Cities with higher avg login = more account access difficulty there

    CASE
        WHEN SUM(is_anomaly_final) = 0          THEN 'Clean'
        WHEN ROUND(SUM(is_anomaly_final) * 100.0
             / COUNT(*), 2) >= 4.0              THEN 'High risk city'
        WHEN ROUND(SUM(is_anomaly_final) * 100.0
             / COUNT(*), 2) >= 2.0              THEN 'Medium risk city'
        ELSE                                         'Low risk city'
    END                                         AS city_risk_label

FROM  flagged_transactions
GROUP BY city
ORDER BY anomaly_rate_pct DESC;


-- =============================================================================
-- VIEW 5 — AGE BAND RISK ANALYSIS
-- =============================================================================
-- Answers: Which customer age groups are most vulnerable to UPI fraud?
--
-- YOUR DATA FINDING:
--   Age 36-45 : 2.50% anomaly rate (highest — 6 anomalies from 240 txns)
--   Age 26-35 : 1.28% anomaly rate
--   Age 18-25 : 1.06% anomaly rate
--   Age 55+   : 0.80% anomaly rate
--   Age 46-55 : 0.63% anomaly rate (lowest — most cautious group)
--
--   Counter-intuitive finding: 36-45 age group (working professionals)
--   are MORE vulnerable than seniors (55+).
--   Possible reason: Working professionals make more high-value purchases
--   online and are more likely to encounter fake merchant scams.

DROP VIEW IF EXISTS age_risk_analysis;

CREATE VIEW age_risk_analysis AS

SELECT
    CASE
        WHEN customer_age BETWEEN 18 AND 25 THEN '1. 18-25 (Young adults)'
        WHEN customer_age BETWEEN 26 AND 35 THEN '2. 26-35 (Early career)'
        WHEN customer_age BETWEEN 36 AND 45 THEN '3. 36-45 (Mid career)'
        WHEN customer_age BETWEEN 46 AND 55 THEN '4. 46-55 (Senior career)'
        ELSE                                     '5. 55+   (Pre/Post retire)'
    END                                         AS age_band,
    -- 5 age groups with numbered prefix for correct sorting

    COUNT(*)                                    AS total_txns,
    SUM(is_anomaly_final)                       AS anomaly_count,

    ROUND(
        SUM(is_anomaly_final) * 100.0 / COUNT(*),
        2
    )                                           AS anomaly_rate_pct,

    ROUND(AVG(txn_amount_inr), 2)               AS avg_txn_amount,
    -- Do different age groups spend differently?
    -- Your data: 18-25 avg ₹309 vs 46-55 avg ₹266

    ROUND(
        SUM(CASE WHEN is_anomaly_final = 1
                 THEN txn_amount_inr ELSE 0 END),
        2
    )                                           AS anomalous_value_inr,
    -- Total financial exposure per age group

    ROUND(AVG(login_attempts), 2)               AS avg_login_attempts,
    -- Do older customers struggle more with login?

    ROUND(AVG(txn_velocity_1hr), 2)             AS avg_velocity,

    CASE
        WHEN ROUND(
            SUM(is_anomaly_final) * 100.0 / COUNT(*), 2
        ) >= 2.0  THEN 'High vulnerability group'
        WHEN ROUND(
            SUM(is_anomaly_final) * 100.0 / COUNT(*), 2
        ) >= 1.0  THEN 'Medium vulnerability group'
        ELSE           'Low vulnerability group'
    END                                         AS vulnerability_label
    -- Risk label per age group
    -- Used in business narrative: "36-45 age group is the
    -- highest vulnerability segment — 2.5× the rate of 46-55 group"

FROM  flagged_transactions
GROUP BY age_band
ORDER BY age_band;


-- =============================================================================
-- VERIFICATION QUERIES — Run these after all 5 views are created
-- =============================================================================

-- ── Verify 1: Confirm all 5 views exist ───────────────────────────────────
SELECT table_name AS view_name
FROM   information_schema.views
WHERE  table_schema = 'upi_project'
ORDER BY table_name;
-- Expected: 5 velocity analysis views + 2 from previous steps = 7 total

-- ── Verify 2: Velocity risk — does higher velocity = higher anomaly rate? ─
SELECT
    velocity,
    total_txns,
    anomaly_count,
    anomaly_rate_pct,
    avg_txn_amount,
    velocity_risk_label
FROM  velocity_risk_analysis
ORDER BY velocity;

-- ── Verify 3: Login risk — confirm the independence finding ───────────────
SELECT
    login_attempts,
    total_txns,
    anomaly_count,
    anomaly_rate_pct,
    avg_duration_sec,
    login_risk_label
FROM  login_risk_analysis
ORDER BY login_attempts;
-- Expected: login >= 3 shows 0 anomaly_count
-- This is the counter-intuitive finding to highlight in your report

-- ── Verify 4: Duration risk — which speed band has highest anomaly rate? ──
SELECT
    duration_band,
    total_txns,
    anomaly_count,
    anomaly_rate_pct,
    avg_txn_amount,
    duration_risk_label
FROM  duration_risk_analysis
ORDER BY duration_band;

-- ── Verify 5: Top 10 cities by anomaly rate ───────────────────────────────
SELECT
    city,
    total_txns,
    anomaly_count,
    anomaly_rate_pct,
    anomalous_value_inr,
    city_risk_label
FROM  city_risk_analysis
WHERE anomaly_count > 0
ORDER BY anomaly_rate_pct DESC
LIMIT 10;
-- Expected top: Louisville (5.13%), Columbus (4.44%), Memphis (4.35%)

-- ── Verify 6: Age vulnerability ranking ──────────────────────────────────
SELECT
    age_band,
    total_txns,
    anomaly_count,
    anomaly_rate_pct,
    avg_txn_amount,
    anomalous_value_inr,
    vulnerability_label
FROM  age_risk_analysis
ORDER BY age_band;
-- Expected: 36-45 group shows highest anomaly rate at 2.50%

-- ── Verify 7: Cross-signal summary (the key business insight table) ───────
SELECT
    'Velocity >= 3'         AS signal,
    SUM(CASE WHEN txn_velocity_1hr >= 3 THEN 1 ELSE 0 END) AS total_with_signal,
    SUM(CASE WHEN txn_velocity_1hr >= 3
             AND is_anomaly_final = 1 THEN 1 ELSE 0 END)   AS also_anomalous,
    ROUND(
        SUM(CASE WHEN txn_velocity_1hr >= 3
                 AND is_anomaly_final = 1 THEN 1 ELSE 0 END) * 100.0
        / NULLIF(SUM(CASE WHEN txn_velocity_1hr >= 3
                          THEN 1 ELSE 0 END), 0), 2
    )                                                       AS overlap_pct
FROM flagged_transactions

UNION ALL

SELECT
    'Login >= 3'            AS signal,
    SUM(CASE WHEN login_attempts >= 3 THEN 1 ELSE 0 END),
    SUM(CASE WHEN login_attempts >= 3
             AND is_anomaly_final = 1 THEN 1 ELSE 0 END),
    ROUND(
        SUM(CASE WHEN login_attempts >= 3
                 AND is_anomaly_final = 1 THEN 1 ELSE 0 END) * 100.0
        / NULLIF(SUM(CASE WHEN login_attempts >= 3
                          THEN 1 ELSE 0 END), 0), 2
    )
FROM flagged_transactions

UNION ALL

SELECT
    'Duration <= 15s'       AS signal,
    SUM(CASE WHEN txn_duration_sec <= 15 THEN 1 ELSE 0 END),
    SUM(CASE WHEN txn_duration_sec <= 15
             AND is_anomaly_final = 1 THEN 1 ELSE 0 END),
    ROUND(
        SUM(CASE WHEN txn_duration_sec <= 15
                 AND is_anomaly_final = 1 THEN 1 ELSE 0 END) * 100.0
        / NULLIF(SUM(CASE WHEN txn_duration_sec <= 15
                          THEN 1 ELSE 0 END), 0), 2
    )
FROM flagged_transactions;
-- This cross-signal table is the key analytical finding of this file.
-- It shows which signals overlap with anomalies and which are independent.
-- Use this in your README and notebook narrative.
