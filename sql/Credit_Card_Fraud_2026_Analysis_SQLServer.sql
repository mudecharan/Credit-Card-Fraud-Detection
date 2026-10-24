-- ============================================================================
-- Credit Card Fraud Detection 2026 — T-SQL Deep Analysis Project
-- ============================================================================
-- Project   : Credit Card Fraud Detection 2026 (Kaggle)
-- Dataset   : mohankrishnathalla/credit-card-fraud-detection-2026
-- Rows      : 100,000 transactions × 43 features
-- Date range: 2026-01-01 → 2026-12-31 (full calendar year)
-- Target    : is_fraud (binary 0/1) + fraud_type (5-class)
-- Currency  : USD ($)
-- Author    : Senior Data Analyst & BI Architect
-- Created   : 2026-10-17
-- SQL Server: 2016+ and Azure SQL Database compatible
--
-- File structure: 13 sections, 17 views, 4 stored procedures, all idempotent
--   1. Database & schema creation
--   2. Table definitions (FactTransactions + dim tables)
--   3. Performance indexes (clustered, non-clustered, filtered, covering)
--   4. Bulk-load stub (BCP / INSERT from staging)
--   5. Data-quality check views (row count, nulls, dupes, FK integrity)
--   6. Core KPI computation view (single-row dashboard)
--   7. Core performance analysis views (monthly trend, channel share, top-N)
--   8. Comparative analysis views (segment × fraud rate, WoW, MoM, YoY)
--   9. Time-series & trend views (7d/30d MA, DoD growth via window functions)
--  10. Fraud & risk analysis views (by category, country, channel, device, hour)
--  11. RFM segmentation view (NTILE(5) quintile scoring, 9-segment mapping)
--  12. Cohort retention views (DATEDIFF-based cohort index, retention matrix)
--  13. Anomaly detection & KPI status flag views (Z-score, Red/Yellow/Green)
--  14. Stored procedures (ExecutiveKPIDashboard, RFMReport, AnomalyAlerts,
--      FraudSegmentReport) + 12 ready-to-run usage examples
--
-- Idempotency: every statement is re-runnable. Use CREATE OR ALTER for views
-- and procedures, IF NOT EXISTS guards for tables and indexes.
-- ============================================================================


-- ============================================================================
-- Section 1: Database & Schema Creation
-- ============================================================================
IF DB_ID('CreditCardFraud2026DB') IS NULL
    CREATE DATABASE CreditCardFraud2026DB;
GO

USE CreditCardFraud2026DB;
GO

-- Schemas: dim (dimensional), fact (transactions), analytics (views), reporting (procs)
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'dim')
    EXEC('CREATE SCHEMA dim');
GO

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'fact')
    EXEC('CREATE SCHEMA fact');
GO

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'analytics')
    EXEC('CREATE SCHEMA analytics');
GO

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'reporting')
    EXEC('CREATE SCHEMA reporting');
GO


-- ============================================================================
-- Section 2: Table Definitions
-- ============================================================================

-- ---------- DimDate (generated, full year 2026) ----------
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'DimDate' AND schema_id = SCHEMA_ID('dim'))
CREATE TABLE dim.DimDate (
    date_key          INT           NOT NULL,        -- YYYYMMDD
    [date]            DATE          NOT NULL,
    [year]            SMALLINT      NOT NULL,
    [quarter]         TINYINT       NOT NULL,
    [month]           TINYINT       NOT NULL,
    month_name        NVARCHAR(20)  NOT NULL,
    [day_of_month]    TINYINT       NOT NULL,
    [day_of_week]     TINYINT       NOT NULL,         -- 1=Sun..7=Sat
    day_name          NVARCHAR(20)  NOT NULL,
    is_weekend        BIT           NOT NULL,
    CONSTRAINT PK_DimDate PRIMARY KEY CLUSTERED (date_key),
    CONSTRAINT CK_DimDate_Year CHECK ([year] BETWEEN 2020 AND 2030),
    CONSTRAINT CK_DimDate_Quarter CHECK ([quarter] BETWEEN 1 AND 4)
);
GO

-- Populate DimDate for full year 2026 using recursive CTE
IF NOT EXISTS (SELECT 1 FROM dim.DimDate WHERE [year] = 2026)
BEGIN
    DECLARE @Start DATE = '2026-01-01', @End DATE = '2026-12-31';
    -- Inline date dimension fill
    WITH DateCTE AS (
        SELECT @Start AS d
        UNION ALL
        SELECT DATEADD(DAY, 1, d) FROM DateCTE WHERE d < @End
    )
    INSERT INTO dim.DimDate (date_key, [date], [year], [quarter], [month], month_name,
                              [day_of_month], [day_of_week], day_name, is_weekend)
    SELECT
        CONVERT(INT, CONVERT(CHAR(8), d, 112))         AS date_key,
        d                                                AS [date],
        YEAR(d)                                          AS [year],
        DATEPART(QUARTER, d)                             AS [quarter],
        MONTH(d)                                         AS [month],
        DATENAME(MONTH, d)                               AS month_name,
        DAY(d)                                           AS [day_of_month],
        DATEPART(WEEKDAY, d)                             AS [day_of_week],
        DATENAME(WEEKDAY, d)                             AS day_name,
        CASE WHEN DATEPART(WEEKDAY, d) IN (1, 7) THEN 1 ELSE 0 END AS is_weekend
    FROM DateCTE
    OPTION (MAXRECURSION 0);
END
GO


-- ---------- DimCustomer ----------
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'DimCustomer' AND schema_id = SCHEMA_ID('dim'))
CREATE TABLE dim.DimCustomer (
    customer_id        NVARCHAR(20)  NOT NULL,        -- 'CUS-xxxxxxxx'
    card_id            NVARCHAR(20)  NOT NULL,        -- 'CRD-xxxxxxxx'
    customer_age       TINYINT       NULL,
    age_group          AS
        CASE
            WHEN customer_age < 25 THEN '18-24'
            WHEN customer_age < 35 THEN '25-34'
            WHEN customer_age < 45 THEN '35-44'
            WHEN customer_age < 55 THEN '45-54'
            WHEN customer_age < 65 THEN '55-64'
            ELSE '65+'
        END PERSISTED,
    customer_gender    NVARCHAR(10)  NULL,            -- Male/Female/Other
    customer_state     VARCHAR(2)    NULL,            -- US state code
    account_age_days   INT           NULL,
    account_age_group  AS
        CASE
            WHEN account_age_days < 30   THEN '<30d'
            WHEN account_age_days < 90   THEN '30-90d'
            WHEN account_age_days < 365  THEN '90d-1y'
            WHEN account_age_days < 1095 THEN '1-3y'
            ELSE '3y+'
        END PERSISTED,
    credit_limit       DECIMAL(18,2) NULL,
    credit_score       SMALLINT      NULL,
    credit_band        AS
        CASE
            WHEN credit_score < 580 THEN 'Poor'
            WHEN credit_score < 670 THEN 'Fair'
            WHEN credit_score < 740 THEN 'Good'
            WHEN credit_score < 800 THEN 'Very Good'
            ELSE 'Excellent'
        END PERSISTED,
    num_cards_held     TINYINT       NULL,
    email_domain       NVARCHAR(20)  NULL,
    is_active          BIT           NOT NULL DEFAULT 1,
    first_seen_date    DATE          NULL,
    CONSTRAINT PK_DimCustomer PRIMARY KEY CLUSTERED (customer_id),
    CONSTRAINT CK_DimCustomer_Age CHECK (customer_age IS NULL OR customer_age BETWEEN 18 AND 120),
    CONSTRAINT CK_DimCustomer_CreditScore CHECK (credit_score IS NULL OR credit_score BETWEEN 300 AND 850)
);
GO


-- ---------- DimMerchant ----------
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'DimMerchant' AND schema_id = SCHEMA_ID('dim'))
CREATE TABLE dim.DimMerchant (
    merchant_id          NVARCHAR(20)  NOT NULL,
    merchant_category    NVARCHAR(50)  NOT NULL,
    merchant_country     NVARCHAR(50)  NOT NULL,
    is_high_risk_country BIT           NOT NULL,
    country_risk_tier    AS
        CASE
            WHEN merchant_country IN ('Romania','Russia','Nigeria','China') THEN 'Tier-A (High Risk)'
            WHEN merchant_country IN ('Mexico','Brazil','India','South Africa','UAE') THEN 'Tier-B (Medium Risk)'
            ELSE 'Tier-C (Low Risk)'
        END PERSISTED,
    region               AS
        CASE
            WHEN merchant_country IN ('USA','Canada','Mexico','Brazil') THEN 'Americas'
            WHEN merchant_country IN ('UK','Germany','France','Italy','Spain','Netherlands','Romania','Russia') THEN 'Europe'
            WHEN merchant_country IN ('India','China','Japan','South Korea','UAE') THEN 'Asia'
            WHEN merchant_country IN ('Australia','South Africa') THEN 'APAC'
            ELSE 'Other'
        END PERSISTED,
    CONSTRAINT PK_DimMerchant PRIMARY KEY CLUSTERED (merchant_id)
);
GO


-- ---------- FactTransactions (the core fact table) ----------
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'FactTransactions' AND schema_id = SCHEMA_ID('fact'))
CREATE TABLE fact.FactTransactions (
    transaction_id              NVARCHAR(20)  NOT NULL,    -- 'TXN-xxxxxxxx'
    customer_id                 NVARCHAR(20)  NOT NULL,
    merchant_id                 NVARCHAR(20)  NOT NULL,
    transaction_datetime       DATETIME2(0)  NOT NULL,
    transaction_date           AS CAST(transaction_datetime AS DATE) PERSISTED,
    transaction_hour           TINYINT       NOT NULL,        -- 0-23
    transaction_day_of_week    NVARCHAR(10)  NOT NULL,        -- Monday..Sunday
    is_weekend                 BIT           NOT NULL,
    transaction_amount         DECIMAL(18,2) NOT NULL,
    merchant_category          NVARCHAR(50)  NOT NULL,
    merchant_country           NVARCHAR(50)  NOT NULL,
    transaction_channel        NVARCHAR(20)  NOT NULL,        -- Online/Mobile App/In-store/ATM
    device_type                NVARCHAR(20)  NOT NULL,        -- Mobile/Desktop/POS/ATM
    browser                    NVARCHAR(20)  NULL,
    card_present               BIT           NOT NULL,
    used_chip                  BIT           NOT NULL,
    used_pin                   BIT           NOT NULL,
    international_transaction  BIT           NOT NULL,
    high_risk_country          BIT           NOT NULL,
    amount_vs_avg_ratio        DECIMAL(18,4) NULL,
    distance_from_home_km      DECIMAL(18,2) NULL,
    distance_from_last_tx_km   DECIMAL(18,2) NULL,
    transactions_last_1h        INT           NOT NULL,
    transactions_last_24h      INT           NOT NULL,
    transactions_last_7d       INT           NOT NULL,
    amount_last_1h             DECIMAL(18,2) NULL,
    amount_last_24h            DECIMAL(18,2) NULL,
    days_since_last_transaction DECIMAL(18,2) NULL,
    avg_transaction_amount_30d DECIMAL(18,2) NULL,
    std_transaction_amount_30d DECIMAL(18,2) NULL,
    num_declined_last_30d      INT           NOT NULL,
    num_chargebacks_ever       INT           NOT NULL,
    is_fraud                   BIT           NOT NULL,
    fraud_type                 NVARCHAR(30)  NOT NULL,        -- Legitimate/CNP/ATO/Synthetic/Card-Present
    fraud_amount_lost         DECIMAL(18,2) NOT NULL,
    amount_band               AS
        CASE
            WHEN transaction_amount < 25         THEN '$0-25'
            WHEN transaction_amount < 75         THEN '$25-75'
            WHEN transaction_amount < 200        THEN '$75-200'
            WHEN transaction_amount < 500        THEN '$200-500'
            WHEN transaction_amount < 1500       THEN '$500-1500'
            ELSE '$1500+'
        END PERSISTED,
    velocity_24h_band         AS
        CASE
            WHEN transactions_last_24h = 0       THEN '0'
            WHEN transactions_last_24h = 1       THEN '1'
            WHEN transactions_last_24h = 2       THEN '2'
            WHEN transactions_last_24h = 3       THEN '3'
            WHEN transactions_last_24h <= 5      THEN '4-5'
            WHEN transactions_last_24h <= 7      THEN '6-7'
            WHEN transactions_last_24h <= 10     THEN '8-10'
            ELSE '11+'
        END PERSISTED,
    time_of_day_window         AS
        CASE
            WHEN transaction_hour BETWEEN 0 AND 5  THEN 'Overnight (00-05)'
            WHEN transaction_hour BETWEEN 6 AND 11 THEN 'Morning (06-11)'
            WHEN transaction_hour BETWEEN 12 AND 17 THEN 'Afternoon (12-17)'
            ELSE 'Evening (18-23)'
        END PERSISTED,
    is_amount_anomaly          AS
        CASE WHEN amount_vs_avg_ratio > 5 THEN 1 ELSE 0 END PERSISTED,
    is_new_account             AS
        CASE
            WHEN EXISTS (SELECT 1 FROM dim.DimCustomer c
                         WHERE c.customer_id = fact.FactTransactions.customer_id
                         AND c.account_age_days < 30) THEN 1
            ELSE 0
        END PERSISTED,
    CONSTRAINT PK_FactTransactions PRIMARY KEY CLUSTERED (transaction_id),
    CONSTRAINT CK_FactTxn_Amount CHECK (transaction_amount > 0),
    CONSTRAINT CK_FactTxn_Hour   CHECK (transaction_hour BETWEEN 0 AND 23),
    CONSTRAINT CK_FactTxn_FraudType CHECK (fraud_type IN
        ('Legitimate','Card-Not-Present','Account-Takeover','Synthetic-Identity','Card-Present')),
    CONSTRAINT FK_FactTxn_Customer FOREIGN KEY (customer_id)
        REFERENCES dim.DimCustomer(customer_id),
    CONSTRAINT FK_FactTxn_Merchant FOREIGN KEY (merchant_id)
        REFERENCES dim.DimMerchant(merchant_id)
);
GO


-- ============================================================================
-- Section 3: Performance Indexes
-- ============================================================================
-- Non-clustered on transaction_date for time-series queries
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_FactTxn_Date')
CREATE NONCLUSTERED INDEX IX_FactTxn_Date
    ON fact.FactTransactions(transaction_date)
    INCLUDE (transaction_amount, is_fraud);
GO

-- Non-clustered on customer_id for JOIN performance
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_FactTxn_Customer')
CREATE NONCLUSTERED INDEX IX_FactTxn_Customer
    ON fact.FactTransactions(customer_id)
    INCLUDE (transaction_amount, transaction_date, is_fraud);
GO

-- Non-clustered on merchant_id
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_FactTxn_Merchant')
CREATE NONCLUSTERED INDEX IX_FactTxn_Merchant
    ON fact.FactTransactions(merchant_id)
    INCLUDE (transaction_amount, transaction_date, is_fraud);
GO

-- Composite index on (is_fraud, transaction_date) for fraud-only queries
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_FactTxn_FraudDate')
CREATE NONCLUSTERED INDEX IX_FactTxn_FraudDate
    ON fact.FactTransactions(is_fraud, transaction_date)
    INCLUDE (transaction_amount, customer_id, merchant_id, fraud_type, fraud_amount_lost);
GO

-- Filtered index: only fraudulent transactions (small but frequently queried)
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_FactTxn_FraudOnly')
CREATE NONCLUSTERED INDEX IX_FactTxn_FraudOnly
    ON fact.FactTransactions(transaction_date)
    INCLUDE (transaction_amount, customer_id, merchant_id, fraud_type, fraud_amount_lost)
    WHERE is_fraud = 1;
GO

-- Index on merchant_category for segment analysis
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_FactTxn_Category')
CREATE NONCLUSTERED INDEX IX_FactTxn_Category
    ON fact.FactTransactions(merchant_category)
    INCLUDE (transaction_amount, is_fraud, fraud_amount_lost);
GO

-- Index on merchant_country for geographic analysis
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_FactTxn_Country')
CREATE NONCLUSTERED INDEX IX_FactTxn_Country
    ON fact.FactTransactions(merchant_country)
    INCLUDE (transaction_amount, is_fraud, fraud_amount_lost, high_risk_country);
GO

-- Index on transaction_channel for channel analysis
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_FactTxn_Channel')
CREATE NONCLUSTERED INDEX IX_FactTxn_Channel
    ON fact.FactTransactions(transaction_channel, device_type)
    INCLUDE (transaction_amount, is_fraud, fraud_amount_lost);
GO

-- Index on transaction_hour for hourly analysis
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_FactTxn_Hour')
CREATE NONCLUSTERED INDEX IX_FactTxn_Hour
    ON fact.FactTransactions(transaction_hour)
    INCLUDE (transaction_amount, is_fraud);
GO

-- DimCustomer indexes
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DimCustomer_State')
CREATE NONCLUSTERED INDEX IX_DimCustomer_State
    ON dim.DimCustomer(customer_state)
    INCLUDE (customer_id, customer_age, credit_score);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DimCustomer_CreditBand')
CREATE NONCLUSTERED INDEX IX_DimCustomer_CreditBand
    ON dim.DimCustomer(credit_band)
    INCLUDE (customer_id, credit_score, account_age_days);
GO


-- ============================================================================
-- Section 4: Bulk-Load Stub (BCP / INSERT from staging)
-- ============================================================================
-- Note: The user is expected to load the CSV via BCP, OPENROWSET, or a
-- staging-table INSERT. This section provides a template.

/*
-- Method 1: BCP from CSV
bcp CreditCardFraud2026DB.fact.FactTransactions IN "my-project/data/credit_card_fraud_detection_2026.csv"
   -c -t"," -r"\\n" -U <user> -P <password> -S <server>

-- Method 2: BULK INSERT from staging
BULK INSERT fact.FactTransactions
FROM 'my-project/data/credit_card_fraud_detection_2026.csv'
WITH (
    FORMAT = 'CSV',
    FIELDQUOTE = '"',
    FIRSTROW = 2,
    TABLOCK,
    ROWS_PER_BATCH = 10000
);

-- Method 3: INSERT from staging table (after Python pandas load)
INSERT INTO fact.FactTransactions (transaction_id, customer_id, merchant_id, ...)
SELECT ... FROM staging.FraudCSV;
*/
GO


-- ============================================================================
-- Section 5: Data Quality Check Views
-- ============================================================================
CREATE OR ALTER VIEW analytics.vw_DataQuality_RowCounts
AS
SELECT 'FactTransactions' AS table_name, COUNT(*) AS row_count FROM fact.FactTransactions
UNION ALL
SELECT 'DimCustomer',     COUNT(*) FROM dim.DimCustomer
UNION ALL
SELECT 'DimMerchant',     COUNT(*) FROM dim.DimMerchant
UNION ALL
SELECT 'DimDate (2026)',  COUNT(*) FROM dim.DimDate WHERE [year] = 2026;
GO


CREATE OR ALTER VIEW analytics.vw_DataQuality_NullCounts
AS
-- Per-column null counts for the fact table (only columns with nulls > 0)
SELECT 'FactTransactions' AS table_name, 'browser' AS column_name,
       SUM(CASE WHEN browser IS NULL THEN 1 ELSE 0 END) AS null_count,
       COUNT(*) AS total_count,
       CAST(100.0 * SUM(CASE WHEN browser IS NULL THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS null_pct
FROM fact.FactTransactions
UNION ALL
SELECT 'FactTransactions', 'distance_from_last_tx_km',
       SUM(CASE WHEN distance_from_last_tx_km IS NULL THEN 1 ELSE 0 END),
       COUNT(*),
       CAST(100.0 * SUM(CASE WHEN distance_from_last_tx_km IS NULL THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2))
FROM fact.FactTransactions
UNION ALL
-- DimCustomer nulls
SELECT 'DimCustomer', 'customer_gender',
       SUM(CASE WHEN customer_gender IS NULL THEN 1 ELSE 0 END),
       COUNT(*),
       CAST(100.0 * SUM(CASE WHEN customer_gender IS NULL THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2))
FROM dim.DimCustomer;
GO


CREATE OR ALTER VIEW analytics.vw_DataQuality_Duplicates
AS
SELECT 'FactTransactions' AS table_name, 'transaction_id' AS column_name,
       COUNT(*) - COUNT(DISTINCT transaction_id) AS duplicate_count
FROM fact.FactTransactions
UNION ALL
SELECT 'DimCustomer', 'customer_id',
       COUNT(*) - COUNT(DISTINCT customer_id)
FROM dim.DimCustomer
UNION ALL
SELECT 'DimMerchant', 'merchant_id',
       COUNT(*) - COUNT(DISTINCT merchant_id)
FROM dim.DimMerchant;
GO


CREATE OR ALTER VIEW analytics.vw_DataQuality_FKIntegrity
AS
-- Check every fact row's customer_id and merchant_id exists in the dim tables
SELECT 'FactTransactions.customer_id -> DimCustomer.customer_id' AS fk_relationship,
       SUM(CASE WHEN c.customer_id IS NULL THEN 1 ELSE 0 END) AS orphan_count,
       COUNT(*) AS total_fact_rows,
       CAST(100.0 * SUM(CASE WHEN c.customer_id IS NULL THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS orphan_pct
FROM fact.FactTransactions t
LEFT JOIN dim.DimCustomer c ON t.customer_id = c.customer_id
UNION ALL
SELECT 'FactTransactions.merchant_id -> DimMerchant.merchant_id',
       SUM(CASE WHEN m.merchant_id IS NULL THEN 1 ELSE 0 END),
       COUNT(*),
       CAST(100.0 * SUM(CASE WHEN m.merchant_id IS NULL THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2))
FROM fact.FactTransactions t
LEFT JOIN dim.DimMerchant m ON t.merchant_id = m.merchant_id;
GO


-- ============================================================================
-- Section 6: Core KPI Computation View (single-row executive dashboard)
-- ============================================================================
CREATE OR ALTER VIEW analytics.vw_CoreKPIs
AS
SELECT
    COUNT(*)                                                                AS total_transactions,
    SUM(transaction_amount)                                                 AS total_volume_usd,
    AVG(transaction_amount)                                                 AS avg_txn_amount,
    SUM(CASE WHEN is_fraud = 1 THEN 1 ELSE 0 END)                           AS fraud_count,
    SUM(CASE WHEN is_fraud = 0 THEN 1 ELSE 0 END)                           AS legitimate_count,
    CAST(100.0 * SUM(CASE WHEN is_fraud = 1 THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(6,3))  AS fraud_rate_pct,
    SUM(fraud_amount_lost)                                                   AS total_fraud_loss_usd,
    CAST(100.0 * SUM(fraud_amount_lost) / NULLIF(SUM(transaction_amount),0) AS DECIMAL(6,3)) AS loss_to_volume_pct,
    AVG(CASE WHEN is_fraud = 1 THEN fraud_amount_lost END)                   AS avg_fraud_loss_per_case,
    AVG(CASE WHEN is_fraud = 1 THEN transaction_amount END)                 AS avg_fraud_amount,
    AVG(CASE WHEN is_fraud = 0 THEN transaction_amount END)                 AS avg_legitimate_amount,
    COUNT(DISTINCT customer_id)                                             AS unique_customers,
    COUNT(DISTINCT merchant_id)                                             AS unique_merchants,
    COUNT(DISTINCT merchant_category)                                       AS n_merchant_categories,
    COUNT(DISTINCT merchant_country)                                        AS n_merchant_countries,
    COUNT(DISTINCT transaction_channel)                                      AS n_channels,
    MIN(transaction_date)                                                    AS date_min,
    MAX(transaction_date)                                                    AS date_max,
    DATEDIFF(DAY, MIN(transaction_date), MAX(transaction_date)) + 1         AS active_days
FROM fact.FactTransactions;
GO


-- ============================================================================
-- Section 7: Core Performance Analysis Views
-- ============================================================================
CREATE OR ALTER VIEW analytics.vw_MonthlyTrend
AS
SELECT
    FORMAT(t.transaction_date, 'yyyy-MM')                              AS year_month,
    YEAR(t.transaction_date)                                            AS [year],
    MONTH(t.transaction_date)                                           AS [month],
    DATENAME(MONTH, t.transaction_date)                                 AS month_name,
    COUNT(*)                                                            AS transaction_count,
    SUM(t.transaction_amount)                                           AS total_volume_usd,
    AVG(t.transaction_amount)                                           AS avg_amount,
    SUM(CASE WHEN t.is_fraud = 1 THEN 1 ELSE 0 END)                    AS fraud_count,
    CAST(100.0 * SUM(CASE WHEN t.is_fraud = 1 THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(6,3)) AS fraud_rate_pct,
    SUM(t.fraud_amount_lost)                                            AS fraud_loss_usd
FROM fact.FactTransactions t
GROUP BY FORMAT(t.transaction_date, 'yyyy-MM'),
         YEAR(t.transaction_date),
         MONTH(t.transaction_date),
         DATENAME(MONTH, t.transaction_date);
GO


CREATE OR ALTER VIEW analytics.vw_ChannelShare
AS
SELECT
    t.transaction_channel,
    COUNT(*)                                                            AS txn_count,
    SUM(t.transaction_amount)                                           AS total_volume_usd,
    CAST(100.0 * SUM(t.transaction_amount) / SUM(SUM(t.transaction_amount)) OVER () AS DECIMAL(6,3)) AS volume_share_pct,
    SUM(CASE WHEN t.is_fraud = 1 THEN 1 ELSE 0 END)                    AS fraud_count,
    CAST(100.0 * SUM(CASE WHEN t.is_fraud = 1 THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(6,3)) AS fraud_rate_pct
FROM fact.FactTransactions t
GROUP BY t.transaction_channel;
GO


CREATE OR ALTER VIEW analytics.vw_TopMerchantsByVolume
AS
SELECT TOP 20
    t.merchant_id,
    m.merchant_category,
    m.merchant_country,
    COUNT(*)                                                            AS txn_count,
    SUM(t.transaction_amount)                                           AS total_volume_usd,
    AVG(t.transaction_amount)                                           AS avg_amount,
    CAST(100.0 * SUM(t.transaction_amount) / SUM(SUM(t.transaction_amount)) OVER () AS DECIMAL(6,3)) AS volume_share_pct
FROM fact.FactTransactions t
JOIN dim.DimMerchant m ON t.merchant_id = m.merchant_id
GROUP BY t.merchant_id, m.merchant_category, m.merchant_country
ORDER BY total_volume_usd DESC;
GO


CREATE OR ALTER VIEW analytics.vw_FraudTypeBreakdown
AS
SELECT
    t.fraud_type,
    COUNT(*)                                                            AS txn_count,
    CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS DECIMAL(6,3))      AS share_of_all_pct,
    SUM(CASE WHEN t.is_fraud = 1 THEN 1 ELSE 0 END)                    AS fraud_count,
    SUM(t.fraud_amount_lost)                                            AS total_loss_usd,
    AVG(t.fraud_amount_lost)                                           AS avg_loss_per_case
FROM fact.FactTransactions t
GROUP BY t.fraud_type;
GO


-- ============================================================================
-- Section 8: Comparative Analysis Views (segment × fraud rate)
-- ============================================================================
CREATE OR ALTER VIEW analytics.vw_FraudByMerchantCategory
AS
SELECT TOP 20
    t.merchant_category,
    COUNT(*)                                                            AS txn_count,
    SUM(CASE WHEN t.is_fraud = 1 THEN 1 ELSE 0 END)                    AS fraud_count,
    CAST(100.0 * SUM(CASE WHEN t.is_fraud = 1 THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(6,3)) AS fraud_rate_pct,
    SUM(CASE WHEN t.is_fraud = 1 THEN t.fraud_amount_lost ELSE 0 END)  AS fraud_loss_usd,
    AVG(CASE WHEN t.is_fraud = 1 THEN t.transaction_amount END)        AS avg_fraud_amount,
    AVG(CASE WHEN t.is_fraud = 0 THEN t.transaction_amount END)        AS avg_legit_amount
FROM fact.FactTransactions t
GROUP BY t.merchant_category
HAVING COUNT(*) > 500  -- minimum sample for statistical significance
ORDER BY fraud_rate_pct DESC;
GO


CREATE OR ALTER VIEW analytics.vw_FraudByCountry
AS
SELECT
    t.merchant_country,
    t.high_risk_country                                                AS is_high_risk_country,
    COUNT(*)                                                           AS txn_count,
    SUM(CASE WHEN t.is_fraud = 1 THEN 1 ELSE 0 END)                   AS fraud_count,
    CAST(100.0 * SUM(CASE WHEN t.is_fraud = 1 THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(6,3)) AS fraud_rate_pct,
    SUM(t.fraud_amount_lost)                                           AS fraud_loss_usd
FROM fact.FactTransactions t
GROUP BY t.merchant_country, t.high_risk_country
ORDER BY fraud_rate_pct DESC;
GO


CREATE OR ALTER VIEW analytics.vw_FraudByChannelDevice
AS
SELECT
    t.transaction_channel,
    t.device_type,
    COUNT(*)                                                           AS txn_count,
    SUM(CASE WHEN t.is_fraud = 1 THEN 1 ELSE 0 END)                   AS fraud_count,
    CAST(100.0 * SUM(CASE WHEN t.is_fraud = 1 THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(6,3)) AS fraud_rate_pct,
    SUM(t.fraud_amount_lost)                                           AS fraud_loss_usd
FROM fact.FactTransactions t
GROUP BY t.transaction_channel, t.device_type
ORDER BY fraud_rate_pct DESC;
GO


CREATE OR ALTER VIEW analytics.vw_FraudByHour
AS
SELECT
    t.transaction_hour,
    t.time_of_day_window,
    COUNT(*)                                                           AS txn_count,
    SUM(CASE WHEN t.is_fraud = 1 THEN 1 ELSE 0 END)                   AS fraud_count,
    CAST(100.0 * SUM(CASE WHEN t.is_fraud = 1 THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(6,3)) AS fraud_rate_pct,
    AVG(t.transaction_amount)                                           AS avg_amount
FROM fact.FactTransactions t
GROUP BY t.transaction_hour, t.time_of_day_window
ORDER BY t.transaction_hour;
GO


CREATE OR ALTER VIEW analytics.vw_FraudByDOW
AS
SELECT
    t.transaction_day_of_week                                          AS day_of_week,
    t.is_weekend,
    COUNT(*)                                                           AS txn_count,
    SUM(CASE WHEN t.is_fraud = 1 THEN 1 ELSE 0 END)                   AS fraud_count,
    CAST(100.0 * SUM(CASE WHEN t.is_fraud = 1 THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(6,3)) AS fraud_rate_pct
FROM fact.FactTransactions t
GROUP BY t.transaction_day_of_week, t.is_weekend
ORDER BY
    CASE t.transaction_day_of_week
        WHEN 'Monday' THEN 1 WHEN 'Tuesday' THEN 2 WHEN 'Wednesday' THEN 3
        WHEN 'Thursday' THEN 4 WHEN 'Friday' THEN 5 WHEN 'Saturday' THEN 6
        WHEN 'Sunday' THEN 7
    END;
GO


CREATE OR ALTER VIEW analytics.vw_FraudByRiskFlag
AS
-- Unpivot the binary risk flags into a long-format table for charting
SELECT flag_name, flag_value, txn_count, fraud_count, fraud_rate_pct
FROM (
    SELECT
        'international_transaction' AS flag_name,
        CAST(international_transaction AS VARCHAR(3)) AS flag_value,
        COUNT(*) AS txn_count,
        SUM(CASE WHEN is_fraud = 1 THEN 1 ELSE 0 END) AS fraud_count,
        CAST(100.0 * SUM(CASE WHEN is_fraud = 1 THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(6,3)) AS fraud_rate_pct
    FROM fact.FactTransactions
    GROUP BY international_transaction
    UNION ALL
    SELECT 'high_risk_country', CAST(high_risk_country AS VARCHAR(3)),
           COUNT(*), SUM(CASE WHEN is_fraud = 1 THEN 1 ELSE 0 END),
           CAST(100.0 * SUM(CASE WHEN is_fraud = 1 THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(6,3))
    FROM fact.FactTransactions GROUP BY high_risk_country
    UNION ALL
    SELECT 'used_chip', CAST(used_chip AS VARCHAR(3)),
           COUNT(*), SUM(CASE WHEN is_fraud = 1 THEN 1 ELSE 0 END),
           CAST(100.0 * SUM(CASE WHEN is_fraud = 1 THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(6,3))
    FROM fact.FactTransactions GROUP BY used_chip
    UNION ALL
    SELECT 'used_pin', CAST(used_pin AS VARCHAR(3)),
           COUNT(*), SUM(CASE WHEN is_fraud = 1 THEN 1 ELSE 0 END),
           CAST(100.0 * SUM(CASE WHEN is_fraud = 1 THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(6,3))
    FROM fact.FactTransactions GROUP BY used_pin
    UNION ALL
    SELECT 'card_present', CAST(card_present AS VARCHAR(3)),
           COUNT(*), SUM(CASE WHEN is_fraud = 1 THEN 1 ELSE 0 END),
           CAST(100.0 * SUM(CASE WHEN is_fraud = 1 THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(6,3))
    FROM fact.FactTransactions GROUP BY card_present
    UNION ALL
    SELECT 'is_weekend', CAST(is_weekend AS VARCHAR(3)),
           COUNT(*), SUM(CASE WHEN is_fraud = 1 THEN 1 ELSE 0 END),
           CAST(100.0 * SUM(CASE WHEN is_fraud = 1 THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(6,3))
    FROM fact.FactTransactions GROUP BY is_weekend
) x;
GO


CREATE OR ALTER VIEW analytics.vw_FraudTypeByChannel
AS
-- Stacked-bar source: fraud type mix within each channel
SELECT
    t.transaction_channel,
    t.fraud_type,
    COUNT(*)                                                           AS txn_count,
    CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY t.transaction_channel) AS DECIMAL(6,3)) AS pct_of_channel
FROM fact.FactTransactions t
GROUP BY t.transaction_channel, t.fraud_type;
GO


-- ============================================================================
-- Section 9: Time Series & Trend Views (with Window Functions)
-- ============================================================================
CREATE OR ALTER VIEW analytics.vw_DailyRollingAverages
AS
WITH DailyTotals AS (
    SELECT
        transaction_date,
        SUM(transaction_amount)  AS daily_volume,
        COUNT(*)                  AS daily_count,
        SUM(CASE WHEN is_fraud = 1 THEN 1 ELSE 0 END) AS daily_fraud_count
    FROM fact.FactTransactions
    GROUP BY transaction_date
)
SELECT
    transaction_date,
    daily_volume,
    daily_count,
    daily_fraud_count,
    -- 7-day trailing moving average using window function with explicit frame
    AVG(daily_volume) OVER (
        ORDER BY transaction_date
        ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
    ) AS ma_7d_volume,
    -- 30-day trailing moving average
    AVG(daily_volume) OVER (
        ORDER BY transaction_date
        ROWS BETWEEN 29 PRECEDING AND CURRENT ROW
    ) AS ma_30d_volume,
    -- 7-day fraud-rate moving average
    CAST(100.0 * AVG(daily_fraud_count) OVER (
        ORDER BY transaction_date
        ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
    ) / NULLIF(AVG(daily_count) OVER (
        ORDER BY transaction_date
        ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
    ), 0) AS DECIMAL(6,3)) AS ma_7d_fraud_rate_pct,
    -- Day-over-day volume growth %
    LAG(daily_volume) OVER (ORDER BY transaction_date) AS prev_day_volume,
    CAST(
        100.0 * (daily_volume - LAG(daily_volume) OVER (ORDER BY transaction_date))
        / NULLIF(LAG(daily_volume) OVER (ORDER BY transaction_date), 0)
        AS DECIMAL(10,3)
    ) AS dod_growth_pct
FROM DailyTotals;
GO


CREATE OR ALTER VIEW analytics.vw_MonthlyGrowth
AS
-- Month-over-month growth using LAG with partition by year
WITH MonthlyTotals AS (
    SELECT
        YEAR(transaction_date)  AS [year],
        MONTH(transaction_date) AS [month],
        SUM(transaction_amount)  AS monthly_volume,
        COUNT(*)                  AS txn_count,
        SUM(CASE WHEN is_fraud = 1 THEN 1 ELSE 0 END) AS fraud_count
    FROM fact.FactTransactions
    GROUP BY YEAR(transaction_date), MONTH(transaction_date)
)
SELECT
    [year],
    [month],
    monthly_volume,
    txn_count,
    fraud_count,
    LAG(monthly_volume) OVER (ORDER BY [year], [month]) AS prev_month_volume,
    CAST(
        100.0 * (monthly_volume - LAG(monthly_volume) OVER (ORDER BY [year], [month]))
        / NULLIF(LAG(monthly_volume) OVER (ORDER BY [year], [month]), 0)
        AS DECIMAL(10,3)
    ) AS mom_growth_pct,
    LAG(fraud_count) OVER (ORDER BY [year], [month]) AS prev_month_fraud_count,
    CAST(
        100.0 * (fraud_count - LAG(fraud_count) OVER (ORDER BY [year], [month]))
        / NULLIF(LAG(fraud_count) OVER (ORDER BY [year], [month]), 0)
        AS DECIMAL(10,3)
    ) AS mom_fraud_growth_pct
FROM MonthlyTotals;
GO


-- ============================================================================
-- Section 10: Fraud & Risk Analysis Views
-- ============================================================================
CREATE OR ALTER VIEW analytics.vw_FraudByCompositeSignal
AS
-- Composite risk signals — fraud rate when each signal is triggered
SELECT 'amount > 5x avg' AS signal_name,
       COUNT(*) AS n,
       SUM(CASE WHEN is_fraud = 1 THEN 1 ELSE 0 END) AS frauds,
       CAST(100.0 * SUM(CASE WHEN is_fraud = 1 THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(6,3)) AS fraud_rate_pct
FROM fact.FactTransactions WHERE amount_vs_avg_ratio > 5
UNION ALL
SELECT 'account < 30 days',
       COUNT(*), SUM(CASE WHEN is_fraud = 1 THEN 1 ELSE 0 END),
       CAST(100.0 * SUM(CASE WHEN is_fraud = 1 THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(6,3))
FROM fact.FactTransactions t
JOIN dim.DimCustomer c ON t.customer_id = c.customer_id
WHERE c.account_age_days < 30
UNION ALL
SELECT 'declined in last 30d',
       COUNT(*), SUM(CASE WHEN is_fraud = 1 THEN 1 ELSE 0 END),
       CAST(100.0 * SUM(CASE WHEN is_fraud = 1 THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(6,3))
FROM fact.FactTransactions WHERE num_declined_last_30d > 0
UNION ALL
SELECT 'chargeback ever',
       COUNT(*), SUM(CASE WHEN is_fraud = 1 THEN 1 ELSE 0 END),
       CAST(100.0 * SUM(CASE WHEN is_fraud = 1 THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(6,3))
FROM fact.FactTransactions WHERE num_chargebacks_ever > 0
UNION ALL
SELECT 'high_risk_country',
       COUNT(*), SUM(CASE WHEN is_fraud = 1 THEN 1 ELSE 0 END),
       CAST(100.0 * SUM(CASE WHEN is_fraud = 1 THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(6,3))
FROM fact.FactTransactions WHERE high_risk_country = 1
UNION ALL
SELECT 'international',
       COUNT(*), SUM(CASE WHEN is_fraud = 1 THEN 1 ELSE 0 END),
       CAST(100.0 * SUM(CASE WHEN is_fraud = 1 THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(6,3))
FROM fact.FactTransactions WHERE international_transaction = 1
UNION ALL
SELECT 'overnight (00-05)',
       COUNT(*), SUM(CASE WHEN is_fraud = 1 THEN 1 ELSE 0 END),
       CAST(100.0 * SUM(CASE WHEN is_fraud = 1 THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(6,3))
FROM fact.FactTransactions WHERE transaction_hour BETWEEN 0 AND 5
UNION ALL
SELECT 'online channel',
       COUNT(*), SUM(CASE WHEN is_fraud = 1 THEN 1 ELSE 0 END),
       CAST(100.0 * SUM(CASE WHEN is_fraud = 1 THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(6,3))
FROM fact.FactTransactions WHERE transaction_channel = 'Online';
GO


CREATE OR ALTER VIEW analytics.vw_FraudLossByFraudType
AS
SELECT
    fraud_type,
    COUNT(*) AS n_cases,
    SUM(fraud_amount_lost) AS total_loss_usd,
    AVG(fraud_amount_lost)  AS avg_loss_per_case,
    CAST(100.0 * SUM(fraud_amount_lost) / SUM(SUM(fraud_amount_lost)) OVER () AS DECIMAL(6,3)) AS share_of_total_loss_pct
FROM fact.FactTransactions
WHERE is_fraud = 1
GROUP BY fraud_type
ORDER BY total_loss_usd DESC;
GO


CREATE OR ALTER VIEW analytics.vw_TopRiskCustomers
AS
-- Top 100 customers by total fraud loss — for manual review
SELECT TOP 100
    t.customer_id,
    c.customer_age,
    c.customer_gender,
    c.customer_state,
    c.credit_band,
    c.account_age_days,
    COUNT(*) AS total_txns,
    SUM(CASE WHEN t.is_fraud = 1 THEN 1 ELSE 0 END) AS fraud_count,
    SUM(t.fraud_amount_lost) AS total_fraud_loss,
    SUM(t.transaction_amount) AS total_volume
FROM fact.FactTransactions t
JOIN dim.DimCustomer c ON t.customer_id = c.customer_id
GROUP BY t.customer_id, c.customer_age, c.customer_gender, c.customer_state,
         c.credit_band, c.account_age_days
HAVING SUM(CASE WHEN t.is_fraud = 1 THEN 1 ELSE 0 END) > 0
ORDER BY total_fraud_loss DESC;
GO


-- ============================================================================
-- Section 11: RFM Segmentation View (NTILE quintile scoring)
-- ============================================================================
CREATE OR ALTER VIEW analytics.vw_RFM_Segmentation
AS
WITH CustomerMetrics AS (
    SELECT
        t.customer_id,
        -- Recency: days since last transaction (smaller = more recent)
        DATEDIFF(DAY, MAX(t.transaction_date), (SELECT MAX(transaction_date) FROM fact.FactTransactions)) AS recency_days,
        -- Frequency: count of transactions
        COUNT(*) AS frequency,
        -- Monetary: total spend
        SUM(t.transaction_amount) AS monetary,
        SUM(CASE WHEN t.is_fraud = 1 THEN 1 ELSE 0 END) AS fraud_count
    FROM fact.FactTransactions t
    GROUP BY t.customer_id
),
Scored AS (
    SELECT
        customer_id, recency_days, frequency, monetary, fraud_count,
        -- Recency score (5 = most recent / lowest days). NTILE orders ASC
        -- so 1 = lowest days; we invert via (6 - NTILE) so 5 = lowest days.
        NTILE(5) OVER (ORDER BY recency_days ASC) AS r_score_raw,
        NTILE(5) OVER (ORDER BY frequency DESC)   AS f_score_raw,
        NTILE(5) OVER (ORDER BY monetary DESC)    AS m_score_raw
    FROM CustomerMetrics
),
Inverted AS (
    SELECT
        customer_id, recency_days, frequency, monetary, fraud_count,
        6 - r_score_raw AS r_score,
        f_score_raw    AS f_score,
        m_score_raw    AS m_score
    FROM Scored
)
SELECT
    customer_id,
    recency_days,
    frequency,
    monetary,
    fraud_count,
    r_score,
    f_score,
    m_score,
    CONCAT(r_score, f_score, m_score) AS rfm_score,
    -- 9-segment mapping
    CASE
        WHEN r_score >= 4 AND f_score >= 4 AND m_score >= 4 THEN 'Champions'
        WHEN r_score >= 3 AND f_score >= 3 AND m_score >= 3 THEN 'Loyal Customers'
        WHEN r_score >= 4 AND f_score <= 2                  THEN 'New Customers'
        WHEN r_score >= 3 AND f_score >= 3 AND m_score <= 2 THEN 'Potential Loyalists'
        WHEN r_score <= 2 AND f_score >= 4 AND m_score >= 3 THEN 'At Risk'
        WHEN r_score <= 2 AND f_score <= 2                  THEN 'Hibernating'
        WHEN r_score <= 1 AND f_score >= 3                  THEN 'Lost'
        WHEN m_score >= 4 AND f_score <= 2                  THEN 'Promising'
        ELSE 'Need Attention'
    END AS rfm_segment
FROM Inverted;
GO


CREATE OR ALTER VIEW analytics.vw_RFM_SegmentSummary
AS
SELECT
    rfm_segment,
    COUNT(*)                                                          AS customer_count,
    CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS DECIMAL(6,3))    AS segment_share_pct,
    AVG(monetary)                                                    AS avg_monetary,
    AVG(recency_days)                                                AS avg_recency_days,
    AVG(frequency)                                                   AS avg_frequency,
    SUM(fraud_count)                                                 AS total_frauds_in_segment
FROM analytics.vw_RFM_Segmentation
GROUP BY rfm_segment
ORDER BY customer_count DESC;
GO


-- ============================================================================
-- Section 12: Cohort Retention Views (DATEDIFF for cohort index)
-- ============================================================================
CREATE OR ALTER VIEW analytics.vw_Cohort_Retention
AS
WITH CustomerFirstTxn AS (
    SELECT
        customer_id,
        MIN(transaction_date) AS first_txn_date,
        FORMAT(MIN(transaction_date), 'yyyy-MM') AS cohort_month
    FROM fact.FactTransactions
    GROUP BY customer_id
),
CohortActivity AS (
    SELECT
        c.customer_id,
        c.cohort_month,
        FORMAT(t.transaction_date, 'yyyy-MM') AS activity_month,
        DATEDIFF(MONTH, c.first_txn_date, t.transaction_date) AS cohort_index
    FROM CustomerFirstTxn c
    JOIN fact.FactTransactions t ON c.customer_id = t.customer_id
)
SELECT
    cohort_month,
    cohort_index,
    COUNT(DISTINCT customer_id) AS active_customers
FROM CohortActivity
GROUP BY cohort_month, cohort_index;
GO


CREATE OR ALTER VIEW analytics.vw_Cohort_RetentionMatrix
AS
WITH CohortSizes AS (
    SELECT cohort_month, COUNT(DISTINCT customer_id) AS cohort_size
    FROM analytics.vw_Cohort_Retention
    WHERE cohort_index = 0
    GROUP BY cohort_month
),
Retention AS (
    SELECT
        r.cohort_month,
        r.cohort_index,
        r.active_customers,
        cs.cohort_size,
        CAST(100.0 * r.active_customers / cs.cohort_size AS DECIMAL(6,3)) AS retention_pct
    FROM analytics.vw_Cohort_Retention r
    JOIN CohortSizes cs ON r.cohort_month = cs.cohort_month
)
SELECT * FROM Retention
ORDER BY cohort_month, cohort_index;
GO


-- ============================================================================
-- Section 13: Anomaly Detection & KPI Status Flags
-- ============================================================================
CREATE OR ALTER VIEW analytics.vw_DailyAnomaly_ZScore
AS
WITH DailyTotals AS (
    SELECT
        transaction_date,
        SUM(transaction_amount)  AS daily_volume,
        COUNT(*)                  AS daily_count,
        SUM(CASE WHEN is_fraud = 1 THEN 1 ELSE 0 END) AS fraud_count
    FROM fact.FactTransactions
    GROUP BY transaction_date
),
Stats AS (
    SELECT
        AVG(daily_volume) AS mean_volume,
        STDEV(daily_volume) AS std_volume,
        AVG(fraud_count * 1.0 / NULLIF(daily_count, 0)) AS mean_fraud_rate,
        STDEV(fraud_count * 1.0 / NULLIF(daily_count, 0)) AS std_fraud_rate
    FROM DailyTotals
)
SELECT
    d.transaction_date,
    d.daily_volume,
    d.daily_count,
    d.fraud_count,
    s.mean_volume,
    s.std_volume,
    CAST((d.daily_volume - s.mean_volume) / NULLIF(s.std_volume, 0) AS DECIMAL(10,4)) AS volume_z_score,
    CASE
        WHEN ABS((d.daily_volume - s.mean_volume) / NULLIF(s.std_volume, 0)) > 2.5 THEN 1
        ELSE 0
    END AS is_volume_anomaly,
    CAST(100.0 * d.fraud_count / NULLIF(d.daily_count, 0) AS DECIMAL(6,3)) AS daily_fraud_rate_pct,
    s.mean_fraud_rate * 100 AS mean_fraud_rate_pct,
    CAST((d.fraud_count * 1.0 / NULLIF(d.daily_count, 0) - s.mean_fraud_rate)
         / NULLIF(s.std_fraud_rate, 0) AS DECIMAL(10,4)) AS fraud_rate_z_score,
    CASE
        WHEN ABS((d.fraud_count * 1.0 / NULLIF(d.daily_count, 0) - s.mean_fraud_rate)
                 / NULLIF(s.std_fraud_rate, 0)) > 2.5 THEN 1
        ELSE 0
    END AS is_fraud_rate_anomaly
FROM DailyTotals d
CROSS JOIN Stats s;
GO


CREATE OR ALTER VIEW analytics.vw_KPI_StatusFlags
AS
-- Single-row dashboard with Red/Yellow/Green status flags per domain benchmark
SELECT
    -- Fraud rate status (banking benchmark: ≤0.5% Green, ≤1.0% Yellow, >1.0% Red)
    CAST(100.0 * SUM(CASE WHEN is_fraud = 1 THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(6,3)) AS fraud_rate_pct,
    CASE
        WHEN 100.0 * SUM(CASE WHEN is_fraud = 1 THEN 1 ELSE 0 END) / COUNT(*) <= 0.5 THEN 'GREEN'
        WHEN 100.0 * SUM(CASE WHEN is_fraud = 1 THEN 1 ELSE 0 END) / COUNT(*) <= 1.0 THEN 'YELLOW'
        ELSE 'RED'
    END AS fraud_rate_status,
    -- Loss-to-volume ratio status (≤0.5% Green, ≤1% Yellow, >1% Red)
    CAST(100.0 * SUM(fraud_amount_lost) / NULLIF(SUM(transaction_amount), 0) AS DECIMAL(6,3)) AS loss_to_volume_pct,
    CASE
        WHEN 100.0 * SUM(fraud_amount_lost) / NULLIF(SUM(transaction_amount), 0) <= 0.5 THEN 'GREEN'
        WHEN 100.0 * SUM(fraud_amount_lost) / NULLIF(SUM(transaction_amount), 0) <= 1.0 THEN 'YELLOW'
        ELSE 'RED'
    END AS loss_to_volume_status,
    -- Average fraud loss per case (≤$50 Green, ≤$150 Yellow, >$150 Red)
    AVG(CASE WHEN is_fraud = 1 THEN fraud_amount_lost END) AS avg_fraud_loss_per_case,
    CASE
        WHEN AVG(CASE WHEN is_fraud = 1 THEN fraud_amount_lost END) <= 50  THEN 'GREEN'
        WHEN AVG(CASE WHEN is_fraud = 1 THEN fraud_amount_lost END) <= 150 THEN 'YELLOW'
        ELSE 'RED'
    END AS avg_loss_status,
    -- Active customer % (≥80% Green, ≥60% Yellow, else Red)
    CAST(100.0 * COUNT(DISTINCT customer_id) /
         NULLIF((SELECT COUNT(*) FROM dim.DimCustomer), 0) AS DECIMAL(6,3)) AS active_customer_pct,
    CASE
        WHEN 100.0 * COUNT(DISTINCT customer_id) /
             NULLIF((SELECT COUNT(*) FROM dim.DimCustomer), 0) >= 80 THEN 'GREEN'
        WHEN 100.0 * COUNT(DISTINCT customer_id) /
             NULLIF((SELECT COUNT(*) FROM dim.DimCustomer), 0) >= 60 THEN 'YELLOW'
        ELSE 'RED'
    END AS active_customer_status
FROM fact.FactTransactions;
GO


-- ============================================================================
-- Section 14: Stored Procedures & Usage Examples
-- ============================================================================

-- ---------- Procedure 1: Executive KPI Dashboard (with date-range filter) ----------
CREATE OR ALTER PROCEDURE reporting.usp_ExecutiveKPIDashboard
    @StartDate DATE = NULL,
    @EndDate   DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @StartDate = ISNULL(@StartDate, (SELECT MIN(transaction_date) FROM fact.FactTransactions));
    SET @EndDate   = ISNULL(@EndDate,   (SELECT MAX(transaction_date) FROM fact.FactTransactions));

    SELECT
        @StartDate AS period_start,
        @EndDate   AS period_end,
        COUNT(*)   AS total_transactions,
        SUM(transaction_amount) AS total_volume_usd,
        AVG(transaction_amount) AS avg_amount,
        SUM(CASE WHEN is_fraud = 1 THEN 1 ELSE 0 END) AS fraud_count,
        CAST(100.0 * SUM(CASE WHEN is_fraud = 1 THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(6,3)) AS fraud_rate_pct,
        SUM(fraud_amount_lost) AS total_fraud_loss_usd,
        CAST(100.0 * SUM(fraud_amount_lost) / NULLIF(SUM(transaction_amount), 0) AS DECIMAL(6,3)) AS loss_to_volume_pct,
        AVG(CASE WHEN is_fraud = 1 THEN fraud_amount_lost END) AS avg_fraud_loss_per_case,
        AVG(CASE WHEN is_fraud = 1 THEN transaction_amount END) AS avg_fraud_amount,
        AVG(CASE WHEN is_fraud = 0 THEN transaction_amount END) AS avg_legitimate_amount,
        COUNT(DISTINCT customer_id) AS unique_customers,
        COUNT(DISTINCT merchant_id) AS unique_merchants
    FROM fact.FactTransactions
    WHERE transaction_date BETWEEN @StartDate AND @EndDate;
END;
GO


-- ---------- Procedure 2: RFM Report ----------
CREATE OR ALTER PROCEDURE reporting.usp_RFMReport
AS
BEGIN
    SET NOCOUNT ON;
    SELECT rfm_segment, customer_count, segment_share_pct,
           avg_monetary, avg_recency_days, avg_frequency, total_frauds_in_segment
    FROM analytics.vw_RFM_SegmentSummary
    ORDER BY customer_count DESC;
END;
GO


-- ---------- Procedure 3: Anomaly Alerts (with configurable threshold) ----------
CREATE OR ALTER PROCEDURE reporting.usp_AnomalyAlerts
    @Threshold FLOAT = 2.5
AS
BEGIN
    SET NOCOUNT ON;
    SELECT
        transaction_date,
        daily_volume,
        daily_count,
        fraud_count,
        daily_fraud_rate_pct,
        volume_z_score,
        fraud_rate_z_score,
        CASE
            WHEN volume_z_score  >  @Threshold THEN 'VOLUME_SPIKE'
            WHEN volume_z_score  < -@Threshold THEN 'VOLUME_DROP'
            WHEN fraud_rate_z_score > @Threshold THEN 'FRAUD_RATE_SPIKE'
            ELSE 'NORMAL'
        END AS alert_type
    FROM analytics.vw_DailyAnomaly_ZScore
    WHERE ABS(volume_z_score) > @Threshold
       OR ABS(fraud_rate_z_score) > @Threshold
    ORDER BY
        CASE WHEN ABS(volume_z_score) > ABS(fraud_rate_z_score)
             THEN ABS(volume_z_score)
             ELSE ABS(fraud_rate_z_score)
        END DESC;
END;
GO


-- ---------- Procedure 4: Fraud Segment Report (multi-result) ----------
CREATE OR ALTER PROCEDURE reporting.usp_FraudSegmentReport
    @StartDate DATE = NULL,
    @EndDate   DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @StartDate = ISNULL(@StartDate, (SELECT MIN(transaction_date) FROM fact.FactTransactions));
    SET @EndDate   = ISNULL(@EndDate,   (SELECT MAX(transaction_date) FROM fact.FactTransactions));

    -- Result set 1: fraud by category
    SELECT 'fraud_by_category' AS report_section, merchant_category AS segment,
           COUNT(*) AS n, SUM(CASE WHEN is_fraud = 1 THEN 1 ELSE 0 END) AS frauds,
           CAST(100.0 * SUM(CASE WHEN is_fraud = 1 THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(6,3)) AS fraud_rate_pct,
           SUM(fraud_amount_lost) AS fraud_loss
    FROM fact.FactTransactions
    WHERE transaction_date BETWEEN @StartDate AND @EndDate
    GROUP BY merchant_category
    ORDER BY fraud_rate_pct DESC;

    -- Result set 2: fraud by channel
    SELECT 'fraud_by_channel' AS report_section, transaction_channel AS segment,
           COUNT(*) AS n, SUM(CASE WHEN is_fraud = 1 THEN 1 ELSE 0 END) AS frauds,
           CAST(100.0 * SUM(CASE WHEN is_fraud = 1 THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(6,3)) AS fraud_rate_pct,
           SUM(fraud_amount_lost) AS fraud_loss
    FROM fact.FactTransactions
    WHERE transaction_date BETWEEN @StartDate AND @EndDate
    GROUP BY transaction_channel
    ORDER BY fraud_rate_pct DESC;

    -- Result set 3: fraud by country (top 10)
    SELECT TOP 10 'fraud_by_country' AS report_section, merchant_country AS segment,
           COUNT(*) AS n, SUM(CASE WHEN is_fraud = 1 THEN 1 ELSE 0 END) AS frauds,
           CAST(100.0 * SUM(CASE WHEN is_fraud = 1 THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(6,3)) AS fraud_rate_pct,
           SUM(fraud_amount_lost) AS fraud_loss
    FROM fact.FactTransactions
    WHERE transaction_date BETWEEN @StartDate AND @EndDate
    GROUP BY merchant_country
    ORDER BY fraud_rate_pct DESC;

    -- Result set 4: fraud by hour
    SELECT 'fraud_by_hour' AS report_section, CAST(transaction_hour AS VARCHAR(5)) AS segment,
           COUNT(*) AS n, SUM(CASE WHEN is_fraud = 1 THEN 1 ELSE 0 END) AS frauds,
           CAST(100.0 * SUM(CASE WHEN is_fraud = 1 THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(6,3)) AS fraud_rate_pct,
           SUM(fraud_amount_lost) AS fraud_loss
    FROM fact.FactTransactions
    WHERE transaction_date BETWEEN @StartDate AND @EndDate
    GROUP BY transaction_hour
    ORDER BY transaction_hour;
END;
GO


-- ============================================================================
-- Section 15: Usage Examples (12 ready-to-run queries)
-- ============================================================================
/*
-- 1. Executive KPI dashboard (full year)
EXEC reporting.usp_ExecutiveKPIDashboard;

-- 2. Executive KPI dashboard for H1 2026
EXEC reporting.usp_ExecutiveKPIDashboard @StartDate = '2026-01-01', @EndDate = '2026-06-30';

-- 3. Core KPIs (single-row view)
SELECT * FROM analytics.vw_CoreKPIs;

-- 4. Monthly trend
SELECT * FROM analytics.vw_MonthlyTrend ORDER BY year_month;

-- 5. Channel share (for donut chart)
SELECT * FROM analytics.vw_ChannelShare ORDER BY volume_share_pct DESC;

-- 6. Top 20 merchants by volume
SELECT * FROM analytics.vw_TopMerchantsByVolume;

-- 7. Fraud type breakdown
SELECT * FROM analytics.vw_FraudTypeBreakdown ORDER BY total_loss_usd DESC;

-- 8. Fraud by merchant category (top 20)
SELECT * FROM analytics.vw_FraudByMerchantCategory;

-- 9. Fraud by country (sorted by rate)
SELECT * FROM analytics.vw_FraudByCountry;

-- 10. Fraud by hour (for hourly pattern chart)
SELECT * FROM analytics.vw_FraudByHour ORDER BY transaction_hour;

-- 11. Composite risk signals (multi-signal fraud-rate lift)
SELECT * FROM analytics.vw_FraudByCompositeSignal ORDER BY fraud_rate_pct DESC;

-- 12. RFM segment summary
EXEC reporting.usp_RFMReport;

-- 13. Cohort retention matrix
SELECT * FROM analytics.vw_Cohort_RetentionMatrix ORDER BY cohort_month, cohort_index;

-- 14. Daily anomalies with default threshold (|z| > 2.5)
EXEC reporting.usp_AnomalyAlerts;

-- 15. Daily anomalies with custom threshold (|z| > 3.0)
EXEC reporting.usp_AnomalyAlerts @Threshold = 3.0;

-- 16. Monthly growth (MoM %)
SELECT * FROM analytics.vw_MonthlyGrowth ORDER BY [year], [month];

-- 17. Daily rolling averages (7d & 30d MA)
SELECT * FROM analytics.vw_DailyRollingAverages ORDER BY transaction_date;

-- 18. KPI status flags (Red/Yellow/Green dashboard)
SELECT * FROM analytics.vw_KPI_StatusFlags;

-- 19. Multi-result fraud segment report
EXEC reporting.usp_FraudSegmentReport @StartDate = '2026-10-01', @EndDate = '2026-12-31';

-- 20. Top 100 risk customers
SELECT * FROM analytics.vw_TopRiskCustomers;

-- 21. Data quality: row counts
SELECT * FROM analytics.vw_DataQuality_RowCounts;

-- 22. Data quality: null counts
SELECT * FROM analytics.vw_DataQuality_NullCounts;

-- 23. Data quality: duplicates
SELECT * FROM analytics.vw_DataQuality_Duplicates;

-- 24. Data quality: FK integrity
SELECT * FROM analytics.vw_DataQuality_FKIntegrity;
*/
GO

-- ============================================================================
-- End of T-SQL Script
-- ============================================================================
-- T-SQL feature coverage demonstrated in this script:
--   [x] CREATE OR ALTER VIEW / PROCEDURE (idempotent)
--   [x] IF NOT EXISTS guards for tables, indexes, schemas
--   [x] Computed columns (PERSISTED) for derived dimensions
--   [x] CHECK constraints for range validation
--   [x] FOREIGN KEY constraints for referential integrity
--   [x] Clustered + non-clustered + filtered + covering (INCLUDE) indexes
--   [x] Recursive CTE for date dimension population (MAXRECURSION 0)
--   [x] CTE chaining (CustomerMetrics -> Scored -> Inverted in RFM)
--   [x] Window functions: LAG, AVG OVER (ROWS BETWEEN), NTILE, SUM OVER()
--   [x] Conditional aggregation: SUM(CASE WHEN is_fraud = 1 THEN ... END)
--   [x] GROUP BY HAVING for statistical-significance filtering
--   [x] CAST with NULLIF for divide-by-zero protection
--   [x] CASE in ORDER BY for custom sort order
--   [x] TOP N for ranking
--   [x] Stored procedures with default parameters and ISNULL fallback
--   [x] Multi-result-set stored procedure (usp_FraudSegmentReport)
--   [x] DATEDIFF for cohort index calculation
--   [x] FORMAT() for date formatting
--   [x] DATENAME / DATEPART for temporal decomposition
--   [x] PIVOT-like patterns via GROUP BY
-- ============================================================================
