-- Agri market pipeline SQL contract.
-- Run this against sqldb-agri-market using an Entra-authenticated SQL admin.

IF OBJECT_ID(N'dbo.stg_market_prices', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.stg_market_prices (
        id BIGINT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_stg_market_prices PRIMARY KEY,
        ingested_at_utc DATETIME2(7) NOT NULL,
        source_endpoint NVARCHAR(500) NOT NULL,
        base_currency VARCHAR(10) NOT NULL,
        target_currency VARCHAR(10) NOT NULL,
        exchange_rate DECIMAL(18, 6) NOT NULL,
        created_at_utc DATETIME2(7) NOT NULL CONSTRAINT DF_stg_market_prices_created DEFAULT SYSUTCDATETIME()
    );
END;
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'dbo.stg_market_prices')
      AND name = N'UX_stg_market_prices_identity'
)
BEGIN
    CREATE UNIQUE NONCLUSTERED INDEX UX_stg_market_prices_identity
    ON dbo.stg_market_prices (ingested_at_utc, base_currency, target_currency);
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_stage_market_prices
    @json_payload NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF ISJSON(@json_payload) <> 1
        THROW 51000, 'Payload is not valid JSON.', 1;

    DECLARE @ingested_at DATETIME2(7) = TRY_CONVERT(
        DATETIME2(7), JSON_VALUE(@json_payload, '$.ingestion_metadata.ingested_at_utc')
    );
    DECLARE @source_endpoint NVARCHAR(500) = JSON_VALUE(
        @json_payload, '$.ingestion_metadata.source_endpoint'
    );
    DECLARE @base_currency VARCHAR(10) = COALESCE(
        JSON_VALUE(@json_payload, '$.payload.base_code'), 'USD'
    );

    IF @ingested_at IS NULL OR @source_endpoint IS NULL
        THROW 51001, 'Payload is missing ingestion metadata.', 1;

    BEGIN TRANSACTION;

    MERGE dbo.stg_market_prices WITH (HOLDLOCK) AS target
    USING (
        SELECT
            @ingested_at AS ingested_at_utc,
            @source_endpoint AS source_endpoint,
            @base_currency COLLATE DATABASE_DEFAULT AS base_currency,
            CONVERT(VARCHAR(10), [key]) COLLATE DATABASE_DEFAULT AS target_currency,
            TRY_CONVERT(DECIMAL(18, 6), [value]) AS exchange_rate
        FROM OPENJSON(@json_payload, '$.payload.rates')
        WHERE TRY_CONVERT(DECIMAL(18, 6), [value]) IS NOT NULL
    ) AS source
     ON target.ingested_at_utc = source.ingested_at_utc
         AND target.base_currency = source.base_currency COLLATE DATABASE_DEFAULT
         AND target.target_currency = source.target_currency COLLATE DATABASE_DEFAULT
    WHEN MATCHED THEN UPDATE SET
        target.exchange_rate = source.exchange_rate,
        target.source_endpoint = source.source_endpoint,
        target.created_at_utc = SYSUTCDATETIME()
    WHEN NOT MATCHED BY TARGET THEN INSERT (
        ingested_at_utc, source_endpoint, base_currency, target_currency, exchange_rate
    ) VALUES (
        source.ingested_at_utc, source.source_endpoint, source.base_currency,
        source.target_currency, source.exchange_rate
    );

    COMMIT TRANSACTION;
END;
GO

-- Run once as the Microsoft Entra SQL administrator after the Function exists.
-- This grants the Function identity only the staging permissions it needs.
-- Replace the name with the Terraform output `function_app_name` if it changes.
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'func-agri-v1a564')
    CREATE USER [func-agri-v1a564] FROM EXTERNAL PROVIDER;
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.database_role_members drm
    JOIN sys.database_principals role_principal ON role_principal.principal_id = drm.role_principal_id
    JOIN sys.database_principals member_principal ON member_principal.principal_id = drm.member_principal_id
    WHERE role_principal.name = N'db_datareader' AND member_principal.name = N'func-agri-v1a564'
)
    ALTER ROLE db_datareader ADD MEMBER [func-agri-v1a564];

IF NOT EXISTS (
    SELECT 1 FROM sys.database_role_members drm
    JOIN sys.database_principals role_principal ON role_principal.principal_id = drm.role_principal_id
    JOIN sys.database_principals member_principal ON member_principal.principal_id = drm.member_principal_id
    WHERE role_principal.name = N'db_datawriter' AND member_principal.name = N'func-agri-v1a564'
)
    ALTER ROLE db_datawriter ADD MEMBER [func-agri-v1a564];

GRANT EXECUTE ON OBJECT::dbo.sp_stage_market_prices TO [func-agri-v1a564];
GO

CREATE OR ALTER VIEW dbo.vw_market_price_analytics
AS
WITH daily_rates AS (
    SELECT
        CAST(ingested_at_utc AS date) AS rate_date,
        base_currency,
        target_currency,
        AVG(exchange_rate) AS daily_avg_rate,
        MIN(exchange_rate) AS daily_min_rate,
        MAX(exchange_rate) AS daily_max_rate,
        COUNT_BIG(*) AS total_ingestions
    FROM dbo.stg_market_prices
    GROUP BY CAST(ingested_at_utc AS date), base_currency, target_currency
), lagged_rates AS (
    SELECT *, LAG(daily_avg_rate) OVER (
        PARTITION BY base_currency, target_currency ORDER BY rate_date
    ) AS prev_day_avg_rate
    FROM daily_rates
)
SELECT
    rate_date, base_currency, target_currency,
    ROUND(daily_avg_rate, 6) AS daily_avg_rate,
    ROUND(daily_min_rate, 6) AS daily_min_rate,
    ROUND(daily_max_rate, 6) AS daily_max_rate,
    ROUND(prev_day_avg_rate, 6) AS prev_day_avg_rate,
    CASE WHEN prev_day_avg_rate IS NULL OR prev_day_avg_rate = 0 THEN NULL
         ELSE ROUND((daily_avg_rate - prev_day_avg_rate) / prev_day_avg_rate * 100.0, 4)
    END AS daily_pct_change,
    ROUND(AVG(daily_avg_rate) OVER (
        PARTITION BY base_currency, target_currency ORDER BY rate_date
        ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
    ), 6) AS ma_7_day,
    ROUND(AVG(daily_avg_rate) OVER (
        PARTITION BY base_currency, target_currency ORDER BY rate_date
        ROWS BETWEEN 29 PRECEDING AND CURRENT ROW
    ), 6) AS ma_30_day,
    total_ingestions
FROM lagged_rates;
GO

CREATE OR ALTER VIEW dbo.vw_powerbi_forex_analytics
AS
WITH daily AS (
    SELECT
        CAST(ingested_at_utc AS date) AS rate_date,
        base_currency,
        target_currency,
        CONCAT(base_currency, '/', target_currency) AS currency_pair,
        AVG(exchange_rate) AS daily_close,
        MAX(exchange_rate) AS daily_high,
        MIN(exchange_rate) AS daily_low,
        COUNT_BIG(*) AS intra_day_samples
    FROM dbo.stg_market_prices
    GROUP BY CAST(ingested_at_utc AS date), base_currency, target_currency
), metrics AS (
    SELECT *,
        LAG(daily_close) OVER (
            PARTITION BY base_currency, target_currency ORDER BY rate_date
        ) AS prev_close,
        AVG(daily_close) OVER (
            PARTITION BY base_currency, target_currency ORDER BY rate_date
            ROWS BETWEEN 19 PRECEDING AND CURRENT ROW
        ) AS ma_20,
        AVG(daily_close) OVER (
            PARTITION BY base_currency, target_currency ORDER BY rate_date
            ROWS BETWEEN 49 PRECEDING AND CURRENT ROW
        ) AS ma_50,
        STDEV(daily_close) OVER (
            PARTITION BY base_currency, target_currency ORDER BY rate_date
            ROWS BETWEEN 19 PRECEDING AND CURRENT ROW
        ) AS stdev_20
    FROM daily
), signals AS (
    SELECT *,
        LAG(ma_20) OVER (PARTITION BY base_currency, target_currency ORDER BY rate_date) AS prev_ma_20,
        LAG(ma_50) OVER (PARTITION BY base_currency, target_currency ORDER BY rate_date) AS prev_ma_50
    FROM metrics
)
SELECT
    rate_date, base_currency, target_currency, currency_pair,
    ROUND(daily_close, 6) AS daily_close,
    ROUND(daily_high, 6) AS daily_high,
    ROUND(daily_low, 6) AS daily_low,
    ROUND(CASE WHEN prev_close IS NULL OR prev_close = 0 THEN 0
               ELSE (daily_close - prev_close) / prev_close * 100.0 END, 4) AS daily_return_pct,
    ROUND(ma_20, 6) AS ma_20,
    ROUND(ma_50, 6) AS ma_50,
    CASE WHEN ma_20 > ma_50 AND prev_ma_20 <= prev_ma_50 THEN 'Bullish Crossover'
         WHEN ma_20 < ma_50 AND prev_ma_20 >= prev_ma_50 THEN 'Bearish Crossover'
         WHEN ma_20 > ma_50 THEN 'Bullish Trend'
         WHEN ma_20 < ma_50 THEN 'Bearish Trend'
         ELSE 'Neutral' END AS trend_signal,
    ROUND(ma_20 + 2 * COALESCE(stdev_20, 0), 6) AS bollinger_upper,
    ROUND(ma_20 - 2 * COALESCE(stdev_20, 0), 6) AS bollinger_lower,
    ROUND(CASE WHEN COALESCE(stdev_20, 0) = 0 THEN 0
               ELSE (daily_close - ma_20) / stdev_20 END, 2) AS price_z_score,
    ROUND(CASE WHEN COALESCE(ma_20, 0) = 0 THEN 0
               ELSE stdev_20 / ma_20 * SQRT(365) * 100 END, 2) AS annualized_volatility_pct,
    ROUND(CASE WHEN daily_low = 0 THEN 0
               ELSE (daily_high - daily_low) / daily_low * 100 END, 4) AS intraday_range_pct,
    intra_day_samples
FROM signals;
GO

-- NBS-aligned reporting surface. Load official NBS observations into this table
-- with the source URL and publication date before presenting them as current data.
IF OBJECT_ID(N'dbo.nbs_agrofood_prices', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.nbs_agrofood_prices (
        observation_date DATE NOT NULL,
        state_name NVARCHAR(100) NULL,
        commodity_name NVARCHAR(150) NOT NULL,
        price_ngn DECIMAL(18, 2) NOT NULL,
        unit_name NVARCHAR(50) NOT NULL,
        source_name NVARCHAR(100) NOT NULL DEFAULT N'NBS',
        source_url NVARCHAR(500) NULL,
        loaded_at_utc DATETIME2(7) NOT NULL DEFAULT SYSUTCDATETIME()
    );
END;
GO

CREATE OR ALTER VIEW dbo.vw_nigeria_top10_agrofoods
AS
WITH latest AS (
    SELECT *, ROW_NUMBER() OVER (
        PARTITION BY commodity_name ORDER BY observation_date DESC, loaded_at_utc DESC
    ) AS latest_row
    FROM dbo.nbs_agrofood_prices
)
SELECT TOP (10)
    commodity_name,
    price_ngn,
    unit_name,
    observation_date,
    state_name,
    source_name,
    source_url
FROM latest
WHERE latest_row = 1
ORDER BY price_ngn DESC, commodity_name;
GO
