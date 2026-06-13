-- =============================================================================
-- File    : 01_schema.sql
-- Project : UPI Merchant VPA Risk Scoring & Spend Anomaly Intelligence Engine
-- Author  : G Poorna Chandra Rao
-- Date    : 16-05-2026
--
-- PURPOSE:
--   This file defines the base table structure for the project.
--   It creates the upi_transactions table in the upi_project database.
--
--   This table is the SINGLE SOURCE OF TRUTH for the entire project.
--   All 9 views built in subsequent SQL files query this table directly
--   or query views that trace back to this table.
--
-- HOW TO USE:
--   Step 1 → Run this file in MySQL Workbench to create the schema
--   Step 2 → Run ingest.py to load data into upi_transactions
--   Step 3 → Run SQL files 02 through 06 to build the views
--
-- TABLE ORIGIN:
--   Dataset  : Bank Transaction Dataset for Fraud Detection (Kaggle)
--   Source   : kaggle.com/datasets/valakhorasani/bank-transaction-dataset
--   Rows     : 2,512 transactions
--   Columns  : 16 original + 1 engineered (txn_velocity_1hr)
--
-- COLUMN RELABELLING (original → UPI terminology):
--   TransactionID           → transaction_id
--   AccountID               → upi_sender_id
--   TransactionAmount       → txn_amount_inr
--   TransactionDate         → txn_timestamp
--   TransactionType         → txn_type
--   Location                → city
--   DeviceID                → device_id
--   IP Address              → ip_address
--   MerchantID              → merchant_vpa
--   Channel                 → txn_channel
--   CustomerAge             → customer_age
--   CustomerOccupation      → customer_occupation
--   TransactionDuration     → txn_duration_sec
--   LoginAttempts           → login_attempts
--   AccountBalance          → account_balance_inr
--   PreviousTransactionDate → prev_txn_timestamp (FLAGGED — not used)
--   [engineered]            → txn_velocity_1hr
-- =============================================================================


-- -----------------------------------------------------------------------------
-- STEP 1 — Create the database if it does not exist
-- -----------------------------------------------------------------------------

CREATE DATABASE IF NOT EXISTS upi_project;

USE upi_project;


-- -----------------------------------------------------------------------------
-- STEP 2 — Drop the table if it already exists (safe re-run)
-- -----------------------------------------------------------------------------
-- WARNING: This will delete all existing data in upi_transactions.
-- Only run this if you want to rebuild the table from scratch.
-- After running this file, run ingest.py to reload the data.

DROP TABLE IF EXISTS upi_transactions;


-- -----------------------------------------------------------------------------
-- STEP 3 — Create the upi_transactions table
-- -----------------------------------------------------------------------------

CREATE TABLE upi_transactions (

    -- ── PRIMARY KEY ───────────────────────────────────────────────────────────
    transaction_id          VARCHAR(20)     NOT NULL,
    -- Unique identifier for every transaction.
    -- Format in dataset: TX000001, TX000002 ... TX002512
    -- PRIMARY KEY ensures no two transactions share the same ID.
    -- This is the audit trail column — fraud analysts reference this
    -- ID when escalating a specific transaction for investigation.

    -- ── SENDER INFORMATION ────────────────────────────────────────────────────
    upi_sender_id           VARCHAR(20)     NOT NULL,
    -- The person who sent the UPI payment.
    -- Format: AC00001 to AC00495 (495 unique senders in dataset)
    -- Used in sender_spend_profile view to build each sender's
    -- personal spending baseline for anomaly detection.

    -- ── TRANSACTION DETAILS ───────────────────────────────────────────────────
    txn_amount_inr          DECIMAL(12,2)   NOT NULL,
    -- The payment amount in Indian Rupees.
    -- Range in dataset: Rs.0.26 to Rs.1,919.11
    -- DECIMAL(12,2) stores exactly 2 decimal places — no rounding errors.
    -- This is the PRIMARY input to the z-score anomaly detection formula.

    txn_timestamp           DATETIME        NOT NULL,
    -- When the transaction occurred.
    -- Format: YYYY-MM-DD HH:MM:SS
    -- Range in dataset: 2023-01-02 to 2024-01-01
    -- Used for: date-range analysis, velocity window calculation,
    -- temporal fraud pattern detection.

    txn_type                VARCHAR(20)     NOT NULL,
    -- Whether money went OUT (Debit) or came IN (Credit).
    -- Values: 'Debit' (1,944 rows) or 'Credit' (568 rows)
    -- CRITICAL: Layer 1 anomaly detection only flags Debit transactions.
    -- Credit = incoming money, cannot be "anomalously received" in this context.

    -- ── LOCATION & DEVICE ─────────────────────────────────────────────────────
    city                    VARCHAR(100)    NOT NULL,
    -- City where the transaction originated.
    -- 43 unique cities in dataset.
    -- Used in city_risk_analysis view to identify high-risk locations.

    device_id               VARCHAR(20)     NOT NULL,
    -- Device used to make the payment.
    -- Fraud signal: same device_id appearing across multiple different
    -- upi_sender_ids suggests account takeover or shared fraud device.

    ip_address              VARCHAR(50)     NOT NULL,
    -- Network address of the device at time of transaction.
    -- Fraud signal: same IP across multiple unrelated senders = proxy/VPN fraud.
    -- Format validated in ingest.py: all follow x.x.x.x pattern.

    -- ── MERCHANT INFORMATION ──────────────────────────────────────────────────
    merchant_vpa            VARCHAR(20)     NOT NULL,
    -- The merchant's Virtual Payment Address — who received the money.
    -- 100 unique merchants in dataset (M001 to M100).
    -- This is the CORE column of the entire project.
    -- All merchant risk scoring, anomaly aggregation, and risk tiers
    -- are computed by grouping on this column.

    -- ── TRANSACTION CHANNEL ───────────────────────────────────────────────────
    txn_channel             VARCHAR(20)     NOT NULL,
    -- How the transaction was initiated.
    -- Values: 'ATM', 'Online', 'Branch'
    -- Used in channel-level fraud pattern analysis.

    -- ── CUSTOMER DEMOGRAPHICS ─────────────────────────────────────────────────
    customer_age            SMALLINT        NOT NULL,
    -- Age of the sender in years.
    -- Range in dataset: 18 to 80 (all valid UPI user ages).
    -- Used in age_risk_analysis view.
    -- Finding: 36-45 age group has highest anomaly rate (2.50%).

    customer_occupation     VARCHAR(50)     NOT NULL,
    -- Occupation of the sender.
    -- Values: 'Doctor', 'Student', 'Retired', 'Engineer'
    -- Demographic signal for fraud pattern segmentation.

    -- ── BEHAVIOURAL SIGNALS ───────────────────────────────────────────────────
    txn_duration_sec        INTEGER         NOT NULL,
    -- How long the transaction took to complete, in seconds.
    -- Range: 10 to 300 seconds.
    -- Fraud signal: very fast (<15 sec) = possible automated fraud tool.
    -- Finding: anomalous transactions average 15 sec longer than normal ones.

    login_attempts          SMALLINT        NOT NULL,
    -- Number of login attempts before the transaction was completed.
    -- Range: 1 to 5.
    -- Counterintuitive finding from analysis:
    -- login >= 3 has ZERO anomalies — fraudsters log in on first try
    -- (they have valid credentials). High login = confused legitimate user.

    account_balance_inr     DECIMAL(15,2)   NOT NULL,
    -- Account balance after the transaction completed.
    -- Range: Rs.101.25 to Rs.14,977.99
    -- Supporting signal: very low balance after a high-value transaction
    -- = possible account draining pattern.

    -- ── FLAGGED COLUMN — NOT USED IN ANALYSIS ─────────────────────────────────
    prev_txn_timestamp      DATETIME,
    -- The sender's previous transaction date BEFORE this one.
    -- FLAGGED AS UNUSABLE: all 2,512 rows have this date in 2024
    -- while txn_timestamp is in 2023 — logically impossible.
    -- Root cause: data generation artifact, not real historical data.
    -- Stored in table for completeness but EXCLUDED from all views and analysis.
    -- Documented in: ingest.py Section 5 Check 7 and Section 7 Clean 6.

    -- ── ENGINEERED FEATURE ────────────────────────────────────────────────────
    txn_velocity_1hr        SMALLINT        NOT NULL DEFAULT 0,
    -- NOT from original dataset — calculated in ingest.py Section 8.
    -- Counts how many transactions the same upi_sender_id made
    -- within the 1-hour window BEFORE this transaction.
    -- Range: 1 (normal) to 5 (high velocity).
    -- Fraud logic: high velocity + high amount + same merchant = strong fraud signal.
    -- Replaces prev_txn_timestamp as the time-based behavioural signal.


    -- ── CONSTRAINTS ───────────────────────────────────────────────────────────
    PRIMARY KEY (transaction_id)
    -- Enforces uniqueness on transaction_id.
    -- MySQL automatically creates an index on the Primary Key
    -- making single-transaction lookups instant.

) ENGINE=InnoDB
  DEFAULT CHARSET=utf8mb4
  COLLATE=utf8mb4_unicode_ci
  COMMENT='Core UPI transaction table. Source: Kaggle bank transaction dataset relabelled to UPI terminology. Loaded by ingest.py.';


-- -----------------------------------------------------------------------------
-- STEP 4 — Create indexes for query performance
-- -----------------------------------------------------------------------------
-- These indexes are created AFTER the table definition.
-- They speed up the GROUP BY and WHERE clauses in all downstream views.

-- Index on merchant_vpa
-- Powers: GROUP BY merchant_vpa in views 04 and 06
-- Every merchant-level aggregation query uses this index.
CREATE INDEX idx_merchant_vpa
ON upi_transactions (merchant_vpa);

-- Index on upi_sender_id
-- Powers: GROUP BY upi_sender_id in view 02 (sender_spend_profile)
-- Every sender baseline calculation uses this index.
CREATE INDEX idx_sender
ON upi_transactions (upi_sender_id);

-- Index on txn_timestamp
-- Powers: date-range WHERE clauses and ORDER BY timestamp queries
-- Used in velocity analysis and temporal pattern detection.
CREATE INDEX idx_timestamp
ON upi_transactions (txn_timestamp);

-- Index on txn_type
-- Powers: WHERE txn_type = 'Debit' filter in view 03 (flagged_transactions)
-- Separates Debit from Credit transactions efficiently.
CREATE INDEX idx_txn_type
ON upi_transactions (txn_type);


-- -----------------------------------------------------------------------------
-- STEP 5 — Verify table was created correctly
-- -----------------------------------------------------------------------------

-- Check table structure
DESCRIBE upi_transactions;

-- Check indexes created
SHOW INDEX FROM upi_transactions;

-- Confirm table exists in the database
SELECT  table_name,
        table_type,
        engine,
        table_comment
FROM    information_schema.tables
WHERE   table_schema = 'upi_project'
AND     table_name   = 'upi_transactions';

-- =============================================================================
-- NEXT STEP:
--   Run ingest.py to load 2,512 rows into this table.
--   Then run 02_sender_spend_profile.sql to build the first view.
-- =============================================================================
