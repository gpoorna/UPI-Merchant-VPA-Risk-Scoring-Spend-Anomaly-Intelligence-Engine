-- =============================================================================
-- File    : 03_anomaly_flag.sql
-- Project : UPI Merchant VPA Risk Scoring & Spend Anomaly Intelligence Engine
-- Step    : 3 of 6 — Flag Anomalous Transactions (Layer 1)
-- Depends : upi_transactions (table) + sender_spend_profile (view)
--
-- PURPOSE:
--   This is the core fraud detection layer of the entire project.
--
--   For every Debit transaction, this file compares the transaction amount
--   against that sender's personal baseline (from sender_spend_profile)
--   and calculates a Z-SCORE.
--
--   The Z-score answers: "How far is this transaction from this sender's
--   normal spending — measured in standard deviations?"
--
--   Z-score formula:
--     z = (transaction_amount - sender_avg) / sender_std
--
--   Decision rule:
--     |z| > 2.0  →  is_anomaly = 1  (flagged — top 2.5% of sender's history)
--     |z| ≤ 2.0  →  is_anomaly = 0  (normal)
--
-- REAL NUMBERS FROM MY DATA:
--   Total Debit transactions   : 1,944
--   Anomalies flagged          : 19  (1.0% anomaly rate)
--   All z-scores fall in range : -2 to +3
--   Highest z-score seen       : 2.50 (AC00267 → M062, ₹796.30)
--
-- SPECIAL CASES HANDLED:
--   1. Senders with NULL std (48 senders, 1 transaction each)
--      → Fallback threshold: ₹880.05 (dataset avg + 2×dataset std)
--   2. Credit transactions → excluded from anomaly flagging entirely
--   3. Zero std edge case → protected with NULLIF()
--
-- OUTPUT:
--   VIEW: flagged_transactions
--   Rows: 1,944 (Debit transactions only)
--   Key new columns: z_score, is_anomaly, anomaly_reason, risk_signal_count
--
-- RUN AFTER: 02_sender_spend_profile.sql
-- =============================================================================


-- -----------------------------------------------------------------------------
-- STEP 1 — Drop view if it exists (safe to re-run)
-- -----------------------------------------------------------------------------

DROP VIEW IF EXISTS flagged_transactions;


-- -----------------------------------------------------------------------------
-- STEP 2 — Create the flagged_transactions VIEW
-- -----------------------------------------------------------------------------

CREATE VIEW flagged_transactions AS

SELECT

    -- ── TRANSACTION IDENTITY ─────────────────────────────────────────────────

    t.transaction_id,
    t.upi_sender_id,
    t.merchant_vpa,
    t.txn_amount_inr,
    t.txn_timestamp,
    t.txn_type,
    t.city,
    t.txn_channel,
    t.device_id,
    t.login_attempts,
    t.txn_duration_sec,
    t.txn_velocity_1hr,
    t.customer_age,
    t.customer_occupation,


    -- ── SENDER BASELINE (pulled from sender_spend_profile view) ──────────────

    s.avg_debit_amount,
    -- The sender's normal average spend.
    -- Used as the centre point of the z-score calculation.
    -- Example: AC00267 avg = ₹212.46

    s.std_debit_amount,
    -- The sender's spend variability.
    -- Example: AC00267 std = ₹233.28
    -- NULL for 48 single-transaction senders — handled below.

    s.upper_normal_limit,
    -- avg + 2×std — the sender's personal fraud boundary.
    -- Example: AC00267 upper limit = ₹212.46 + (2 × ₹233.28) = ₹679.02
    -- Any payment above this is in the top 2.5% for that sender.

    s.total_txns           AS sender_total_txns,
    s.baseline_quality,
    -- 'Reliable' / 'Low sample' / 'Single transaction'
    -- Tells us how much to trust this sender's baseline.


    -- ── Z-SCORE CALCULATION ───────────────────────────────────────────────────
    --
    -- Z-score = (transaction_amount - sender_avg) / sender_std
    --
    -- What z-score values mean:
    --   z = 0.0   → transaction is exactly at sender's average (perfectly normal)
    --   z = 1.0   → 1 std above average (slightly high, still normal)
    --   z = 2.0   → 2 std above average (boundary — top 2.5%)
    --   z = 2.50  → your highest z-score (AC00267, ₹796.30 vs avg ₹212.46)
    --   z = -1.0  → 1 std below average (slightly low, still normal)
    --   z < -2.0  → unusually small payment (0 cases in your data)
    --
    -- NULLIF(s.std_debit_amount, 0):
    --   Protects against division by zero.
    --   If std = 0 (all payments identical), NULLIF returns NULL
    --   instead of causing a division-by-zero error.
    --   When std IS NULL (single-transaction senders), z-score = NULL.

    ROUND(
        (t.txn_amount_inr - s.avg_debit_amount)
        / NULLIF(s.std_debit_amount, 0),
        2
    )                                       AS z_score,


    -- ── PRIMARY ANOMALY FLAG (z-score based) ──────────────────────────────────
    --
    -- Rule: if |z_score| > 2.0 → flag as anomaly
    --
    -- ABS() takes the absolute value — catches both:
    --   Unusually HIGH payments (z > +2.0) → most common fraud signal
    --   Unusually LOW  payments (z < -2.0) → rare but possible (e.g. test txns)
    --
    -- Your data results:
    --   19 transactions flagged out of 1,944 Debit transactions = 1.0%
    --   All flags are z > +2.0 (no unusually low payments flagged)
    --   0 transactions have z < -2.0
    --
    -- For senders with NULL std (48 senders):
    --   z_score = NULL → ABS(NULL) = NULL → NULL > 2 = NULL (not flagged by z)
    --   These are handled by the fallback rule in is_anomaly_final below.

    CASE
        WHEN ABS(
            (t.txn_amount_inr - s.avg_debit_amount)
            / NULLIF(s.std_debit_amount, 0)
        ) > 2.0
        THEN 1
        ELSE 0
    END                                     AS is_anomaly,


    -- ── FALLBACK ANOMALY FLAG (for NULL std senders) ──────────────────────────
    --
    -- For the 48 senders with only 1 transaction, std is NULL.
    -- We cannot calculate a personal z-score for them.
    -- Instead: compare against the DATASET-WIDE threshold.
    --
    -- Dataset-wide fallback threshold:
    --   Dataset avg = ₹294.99
    --   Dataset std = ₹292.53
    --   Fallback upper limit = ₹294.99 + (2 × ₹292.53) = ₹880.05
    --
    -- So for single-transaction senders:
    --   If their payment > ₹880.05 → flag as anomaly
    --   Otherwise → normal
    --
    -- This is a conservative but fair approach — we do not ignore these
    -- senders just because they have limited history.

    CASE
        WHEN s.std_debit_amount IS NULL
             AND t.txn_amount_inr > 880.05
        THEN 1
        ELSE 0
    END                                     AS is_anomaly_fallback,


    -- ── COMBINED FINAL ANOMALY FLAG ────────────────────────────────────────────
    --
    -- A transaction is flagged if EITHER:
    --   (A) z-score rule fires (is_anomaly = 1), OR
    --   (B) fallback rule fires (is_anomaly_fallback = 1)
    --
    -- GREATEST(a, b) returns the larger of two values.
    -- Since both flags are 0 or 1:
    --   GREATEST(0, 0) = 0  → not flagged
    --   GREATEST(1, 0) = 1  → flagged by z-score
    --   GREATEST(0, 1) = 1  → flagged by fallback
    --   GREATEST(1, 1) = 1  → flagged by both

    GREATEST(
        CASE
            WHEN ABS(
                (t.txn_amount_inr - s.avg_debit_amount)
                / NULLIF(s.std_debit_amount, 0)
            ) > 2.0
            THEN 1 ELSE 0
        END,
        CASE
            WHEN s.std_debit_amount IS NULL
                 AND t.txn_amount_inr > 880.05
            THEN 1 ELSE 0
        END
    )                                       AS is_anomaly_final,


    -- ── ANOMALY REASON (human-readable explanation) ────────────────────────────
    --
    -- Tells the fraud analyst WHY this transaction was flagged.
    -- This is what appears in the final risk report — not just a 0/1 flag
    -- but a plain-English reason that makes the report self-explanatory.

    CASE
        WHEN ABS(
            (t.txn_amount_inr - s.avg_debit_amount)
            / NULLIF(s.std_debit_amount, 0)
        ) > 2.0
        THEN CONCAT(
                'Amount ₹', t.txn_amount_inr,
                ' is z=',
                ROUND(
                    (t.txn_amount_inr - s.avg_debit_amount)
                    / NULLIF(s.std_debit_amount, 0), 2
                ),
                ' std above sender avg ₹', s.avg_debit_amount
             )
        WHEN s.std_debit_amount IS NULL
             AND t.txn_amount_inr > 880.05
        THEN CONCAT(
                'Single-txn sender. Amount ₹',
                t.txn_amount_inr,
                ' exceeds dataset fallback threshold ₹880.05'
             )
        ELSE 'Normal'
    END                                     AS anomaly_reason,


    -- ── SUPPORTING FRAUD SIGNALS ──────────────────────────────────────────────
    -- These are NOT the primary anomaly flag.
    -- They are additional signals that STRENGTHEN the case when is_anomaly = 1.
    -- A transaction flagged by z-score AND showing high velocity AND
    -- high login attempts is far more suspicious than z-score alone.

    CASE WHEN t.txn_velocity_1hr >= 3
         THEN 1 ELSE 0
    END                                     AS high_velocity_flag,
    -- 1 = sender made 3+ payments in the hour before this one
    -- Your data: transactions with velocity ≥ 3 are high-risk candidates

    CASE WHEN t.login_attempts >= 3
         THEN 1 ELSE 0
    END                                     AS high_login_flag,
    -- 1 = sender needed 3+ login attempts before this transaction
    -- Legitimate users rarely need more than 1-2 attempts

    CASE WHEN t.txn_duration_sec <= 15
         THEN 1 ELSE 0
    END                                     AS fast_txn_flag,
    -- 1 = transaction completed in ≤ 15 seconds
    -- Extremely fast transactions can indicate automated fraud tools
    -- Normal human transactions take 20-120 seconds


    -- ── TOTAL RISK SIGNAL COUNT ───────────────────────────────────────────────
    --
    -- Adds up how many fraud signals fired for this transaction.
    -- Range: 0 to 4
    --
    -- 0 → completely normal transaction
    -- 1 → one mild signal (monitor)
    -- 2 → two signals firing together (investigate)
    -- 3 → three signals (high priority)
    -- 4 → all four signals (immediate escalation)
    --
    -- Example — the strongest fraud case in your data:
    --   AC00267 → M062, ₹796.30
    --   is_anomaly_final = 1  (z=2.50) → signal 1
    --   high_velocity_flag   → depends on their velocity
    --   high_login_flag      → depends on their login attempts
    --   fast_txn_flag        → depends on duration
    --   Total signal count tells analyst exactly how many red flags fired

    (
        GREATEST(
            CASE WHEN ABS(
                (t.txn_amount_inr - s.avg_debit_amount)
                / NULLIF(s.std_debit_amount, 0)
            ) > 2.0 THEN 1 ELSE 0 END,
            CASE WHEN s.std_debit_amount IS NULL
                      AND t.txn_amount_inr > 880.05
                 THEN 1 ELSE 0 END
        )
        +
        CASE WHEN t.txn_velocity_1hr >= 3 THEN 1 ELSE 0 END
        +
        CASE WHEN t.login_attempts    >= 3 THEN 1 ELSE 0 END
        +
        CASE WHEN t.txn_duration_sec  <= 15 THEN 1 ELSE 0 END
    )                                       AS risk_signal_count

FROM upi_transactions t

-- ── JOIN to sender_spend_profile ─────────────────────────────────────────────
-- Each transaction row (t) is matched to its sender's baseline (s)
-- using upi_sender_id as the join key.
--
-- LEFT JOIN is used (not INNER JOIN) so that even if a sender somehow
-- has no profile entry, their transactions still appear in the output
-- (with NULL baseline values) rather than being silently dropped.

LEFT JOIN sender_spend_profile s
       ON t.upi_sender_id = s.upi_sender_id

-- ── FILTER: Debit transactions only ──────────────────────────────────────────
-- Credit transactions (incoming money) are excluded.
-- A sender cannot "anomalously receive" money in this context.
-- Your data: 1,944 Debit / 568 Credit → this view has 1,944 rows.

WHERE t.txn_type = 'Debit';


-- =============================================================================
-- VERIFICATION QUERIES
-- Run these one by one after creating the view.
-- =============================================================================

-- ── Verify 1: Total rows (expect 1,944 — Debit transactions only) ─────────
SELECT COUNT(*) AS total_debit_txns
FROM   flagged_transactions;

-- ── Verify 2: How many transactions were flagged? ─────────────────────────
SELECT
    SUM(is_anomaly_final)                           AS total_flagged,
    COUNT(*)                                        AS total_txns,
    ROUND(SUM(is_anomaly_final) * 100.0
          / COUNT(*), 2)                            AS anomaly_rate_pct
FROM flagged_transactions;
-- Expected: ~19 flagged, 1.0% anomaly rate

-- ── Verify 3: View all flagged transactions with their z-scores ───────────
SELECT
    transaction_id,
    upi_sender_id,
    merchant_vpa,
    txn_amount_inr,
    avg_debit_amount,
    std_debit_amount,
    z_score,
    is_anomaly_final,
    anomaly_reason,
    risk_signal_count
FROM   flagged_transactions
WHERE  is_anomaly_final = 1
ORDER BY z_score DESC;
-- Expected: 19 rows — sorted by most anomalous first

-- ── Verify 4: Z-score distribution across all 1,944 transactions ──────────
SELECT
    CASE
        WHEN z_score IS NULL    THEN 'NULL (single-txn sender)'
        WHEN z_score  > 2.0     THEN 'Above +2 (anomaly)'
        WHEN z_score  > 1.0     THEN '+1 to +2 (elevated)'
        WHEN z_score  > 0       THEN '0 to +1 (normal-high)'
        WHEN z_score  > -1.0    THEN '-1 to 0 (normal-low)'
        ELSE                         'Below -1 (low spend)'
    END                         AS z_score_band,
    COUNT(*)                    AS txn_count,
    ROUND(COUNT(*) * 100.0
          / SUM(COUNT(*)) OVER(), 1) AS pct
FROM  flagged_transactions
GROUP BY z_score_band
ORDER BY MIN(z_score) DESC;

-- ── Verify 5: Multi-signal transactions (most dangerous) ──────────────────
SELECT
    transaction_id,
    upi_sender_id,
    merchant_vpa,
    txn_amount_inr,
    z_score,
    is_anomaly_final,
    high_velocity_flag,
    high_login_flag,
    fast_txn_flag,
    risk_signal_count,
    anomaly_reason
FROM   flagged_transactions
WHERE  risk_signal_count >= 2
ORDER BY risk_signal_count DESC, z_score DESC;
-- Transactions where multiple fraud signals fire together
-- These are the highest priority cases for manual review

-- ── Verify 6: Fallback-flagged transactions (NULL std senders) ────────────
SELECT
    transaction_id,
    upi_sender_id,
    merchant_vpa,
    txn_amount_inr,
    avg_debit_amount,
    std_debit_amount,
    baseline_quality,
    is_anomaly_fallback,
    is_anomaly_final,
    anomaly_reason
FROM   flagged_transactions
WHERE  is_anomaly_fallback = 1;
-- Shows which single-transaction senders were caught by the fallback rule
