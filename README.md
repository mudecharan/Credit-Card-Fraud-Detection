# Credit Card Fraud Detection (2026) — Analytics & Risk Intelligence

End-to-end fraud analytics project on 100,000 credit card transactions across 8,000 customers, 3,000 merchants, and 20 countries (Jan–Dec 2026). Combines EDA, statistical testing, RFM segmentation, risk signal engineering, and BI-ready outputs (SQL Server, Power BI DAX, CSV extracts, charts) to surface fraud drivers and actionable loss-avoidance recommendations.

## Project Snapshot

| Metric | Value |
|---|---|
| Transactions analyzed | 100,000 |
| Features | 52 |
| Fraud transactions | 2,055 (2.06% fraud rate) |
| Total transaction volume | $12.69M |
| Total fraud loss | $279.8K (2.21% loss rate) |
| Avg fraud amount | $169.93 vs $125.97 legit |
| Customers / Cards / Merchants | 8,000 / 8,000 / 3,000 |
| Merchant categories / Countries | 15 / 20 |
| Fraud types | 5 |

## Key Findings

- **Off-hours risk:** Fraud rate peaks 7–11% between 00:00–04:00 vs ~2% baseline.
- **Channel & device:** Card-not-present/online channels show significantly higher fraud (χ² p ≈ 6.5e-126).
- **Amount signal:** Fraudulent transactions average $169.93 vs $125.97 legitimate (Welch t-test p ≈ 2.6e-9).
- **RFM segmentation:** 8,000 customers into 10 RFM tiers; Loyal/Champions hold largest fraud counts.
- **Composite risk signals & driver tiers** for prioritized case review; daily anomaly detection flags outlier days.

## Deliverables

- `Credit Card Fraud Detection.ipynb` — EDA, feature engineering, statistical tests, segmentation.
- `charts/` — 22 publication-ready visualizations.
- `sql/Credit_Card_Fraud_2026_Analysis_SQLServer.sql` — SQL Server analysis.
- `dax/Credit_Card_Fraud_2026_Analysis_DAX_Measures.txt` — Power BI DAX measures.
- `Data/csv/` — exported analytics tables.
- `kpi/` — headline KPIs and analysis summary (JSON).

## Tech Stack

Python, Pandas, NumPy, SciPy, Matplotlib/Seaborn, SQL Server, Power BI (DAX).

## How to Run

1. `pip install pandas numpy scipy matplotlib seaborn jupyter`
2. Run all cells in the notebook; outputs written to `charts/`, `Data/csv/`, `kpi/`.
3. (Optional) Load SQL script into SQL Server; import DAX measures into Power BI.

## Recommendations

Six prioritized rules (R1–R6) targeting ~$50K+ annualized loss avoidance: block off-hours high-risk transactions, tighten velocity thresholds, category-aware amount limits, seasonal Q4 velocity tightening.

## License

MIT
