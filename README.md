# UPI-Merchant-VPA-Risk-Scoring-Spend-Anomaly-Intelligence-Engine
Built a UPI Merchant VPA Risk Scoring &amp; Spend Anomaly Intelligence Engine to identify high-risk merchants linked to fraud complaints. The project aggregates transaction patterns, detects anomalies, and enables proactive fraud monitoring beyond individual transaction-level analysis.

## Business Problem

India processes over **14 billion UPI transactions per month**. While individual transaction fraud gets flagged by banks, a deeper and largely unsolved problem exists at the **merchant VPA (Virtual Payment Address) level** — certain merchants consistently appear in the transaction history of users who later raise fraud complaints, but no systematic merchant-level risk score exists to catch this pattern early.

The **Risk & Compliance team** at a UPI payment gateway currently reviews fraud complaints one transaction at a time. There is no aggregated view that answers:

> *"Which merchant VPAs are accumulating the most anomalous transactions — and how risky is each one?"*

This project solves that problem by building a **two-layer analytics engine**:

| Layer | What it does | Output |
|---|---|---|
| **Layer 1 — Transaction Anomaly** | Flags individual transactions that deviate from the sender's historical spend pattern | `is_anomaly` flag per transaction |
| **Layer 2 — Merchant Risk Scoring** | Aggregates anomaly signals per merchant VPA and computes a risk tier | `risk_tier` (Low / Medium / High) per merchant |

---

## Business Questions This Project Answers

The entire project is structured around **5 core business questions**. Every SQL query and Python script maps back to one of these questions.

**Q1. Which merchant VPAs are linked to the highest volume of anomalous transactions?**
> Identifies the top merchants by anomaly count — the morning watch-list for a fraud analyst.

**Q2. Is the spend pattern for a given transaction normal for that sender — or is it an outlier?**
> Flags transactions where the amount deviates significantly from the sender's own historical average, using statistical thresholds.

**Q3. Which merchant categories carry the highest financial risk exposure?**
> Aggregates total anomalous transaction value by merchant category to identify which categories need tighter monitoring rules.

**Q4. How does transaction velocity correlate with anomaly rate — do rapid repeat transactions increase risk?**
> Calculates transactions per sender per hour and examines whether high-velocity senders have higher fraud rates.

**Q5. What is the overall merchant risk tier — and which merchants should be escalated for manual review?**
> Final output: a ranked merchant risk score table with Low / Medium / High tiers based on anomaly rate and transaction value exposure.
