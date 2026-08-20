/* =============================================================================
   01_staging_and_load.sql
   -----------------------------------------------------------------------------
   Loads all six source CSVs into staging tables. Dimension files
   (dim_cpt, dim_date, dim_denial_reason, dim_payer, dim_provider) are
   already clean, so they get typed staging tables and load straight
   through. raw_claims.csv is the one with real data-quality issues, so it
   loads into an all-VARCHAR staging table - validation happens deliberately
   in 02_data_cleaning.sql, not silently during the load.

   Before running: copy all six CSVs to a path the SQL Server SERVICE
   ACCOUNT can read (e.g. C:\data\ on the server itself), then update the
   file paths below to match.
   ============================================================================= */

USE ClaimsDenialAnalytics;
GO

/* =============================================================================
   Dimension staging tables (typed - source files are already clean)
   ============================================================================= */

IF OBJECT_ID('dbo.stg_dim_cpt', 'U') IS NOT NULL DROP TABLE dbo.stg_dim_cpt;
CREATE TABLE dbo.stg_dim_cpt (
    cpt_code        VARCHAR(10),
    [description]   VARCHAR(250),
    category        VARCHAR(30)
);


IF OBJECT_ID('dbo.stg_dim_date', 'U') IS NOT NULL DROP TABLE dbo.stg_dim_date;
CREATE TABLE dbo.stg_dim_date (
    date_key        DATE,
    [day]           TINYINT,
    [month]         TINYINT,
    month_name      VARCHAR(10),
    [quarter]       TINYINT,
    [year]          SMALLINT,
    weekday_name    VARCHAR(10),
    is_weekend      VARCHAR(5)     -- 'True'/'False' text -> converted to BIT on load into dim_date
);

IF OBJECT_ID('dbo.stg_dim_denial_reason', 'U') IS NOT NULL DROP TABLE dbo.stg_dim_denial_reason;
CREATE TABLE dbo.stg_dim_denial_reason (
    denial_id            INT,
    denial_code           VARCHAR(10),
    denial_category        VARCHAR(30),
    denial_description       VARCHAR(150)
);

IF OBJECT_ID('dbo.stg_dim_payer', 'U') IS NOT NULL DROP TABLE dbo.stg_dim_payer;
CREATE TABLE dbo.stg_dim_payer (
    payer_id        INT,
    payer_name      VARCHAR(100),
    payer_type      VARCHAR(30)
);

IF OBJECT_ID('dbo.stg_dim_provider', 'U') IS NOT NULL DROP TABLE dbo.stg_dim_provider;
CREATE TABLE dbo.stg_dim_provider (
    provider_id     INT,
    provider_name   VARCHAR(100),
    specialty       VARCHAR(50),
    department      VARCHAR(50)
);
GO

/* =============================================================================
   raw_claims staging table (all VARCHAR - deliberately untyped)
   ============================================================================= */

IF OBJECT_ID('dbo.stg_raw_claims', 'U') IS NOT NULL DROP TABLE dbo.stg_raw_claims;
CREATE TABLE dbo.stg_raw_claims (
    claim_id          VARCHAR(20),
    patient_id        VARCHAR(20),
    provider_id       VARCHAR(20),
    payer_id          VARCHAR(20),
    cpt_code          VARCHAR(20),
    denial_code       VARCHAR(20),
    service_date      VARCHAR(20),
    submitted_date    VARCHAR(20),
    paid_date         VARCHAR(20),
    billed_amount     VARCHAR(20),
    allowed_amount    VARCHAR(20),
    paid_amount       VARCHAR(20),
    claim_status      VARCHAR(20)
);
GO

BULK INSERT dbo.stg_dim_cpt
FROM 'D:\Claim_denial_analyst_project\data\dim_cpt.csv'
WITH (
    FIRSTROW = 2,
    FORMAT ='CSV',
    FIELDQUOTE = '"',
    FIELDTERMINATOR = ',',
    ROWTERMINATOR = '0x0a',
    CODEPAGE = '65001',
    TABLOCK
);

BULK INSERT dbo.stg_dim_date
FROM 'D:\Claim_denial_analyst_project\data\dim_date.csv'
WITH (FIRSTROW = 2,FIELDQUOTE ='"',FIELDTERMINATOR =',',ROWTERMINATOR ='0x0a', CODEPAGE = '65001', TABLOCK);


BULK INSERT dbo.stg_dim_denial_reason
FROM 'D:\Claim_denial_analyst_project\data\dim_denial_reason.csv'
WITH (FIRSTROW = 2,FIELDQUOTE ='"',FIELDTERMINATOR =',',ROWTERMINATOR ='0x0a', CODEPAGE = '65001', TABLOCK);

BULK INSERT dbo.stg_dim_payer
FROM 'D:\Claim_denial_analyst_project\data\dim_payer.csv'
WITH (FIRSTROW = 2, FIELDQUOTE ='"',FIELDTERMINATOR =',',ROWTERMINATOR ='0x0a', CODEPAGE = '65001', TABLOCK);

BULK INSERT dbo.stg_dim_provider
FROM 'D:\Claim_denial_analyst_project\data\dim_provider.csv'
WITH (FIRSTROW = 2, FIELDQUOTE ='"',FIELDTERMINATOR =',',ROWTERMINATOR ='0x0a', CODEPAGE = '65001', TABLOCK);

BULK INSERT dbo.stg_raw_claims
FROM 'D:\Claim_denial_analyst_project\data\raw_claims.csv'
WITH (FIRSTROW = 2, FIELDQUOTE ='"',FIELDTERMINATOR =',',ROWTERMINATOR ='0x0a', CODEPAGE = '65001', TABLOCK);
GO


SELECT 'stg_dim_cpt' AS tbl, COUNT(*) AS rows_loaded FROM dbo.stg_dim_cpt
UNION ALL SELECT 'stg_dim_date', COUNT(*) FROM dbo.stg_dim_date
UNION ALL SELECT 'stg_dim_denial_reason', COUNT(*) FROM dbo.stg_dim_denial_reason
UNION ALL SELECT 'stg_dim_payer', COUNT(*) FROM dbo.stg_dim_payer
UNION ALL SELECT 'stg_dim_provider', COUNT(*) FROM dbo.stg_dim_provider
UNION ALL SELECT 'stg_raw_claims', COUNT(*) FROM dbo.stg_raw_claims;
GO

