/* =============================================================================
   00_create_database_and_schema.sql
   -----------------------------------------------------------------------------
   Creates the ClaimsDenialAnalytics database and a star schema sized to
   match the provided source files exactly:

       dim_cpt.csv, dim_date.csv, dim_denial_reason.csv,
       dim_payer.csv, dim_provider.csv, raw_claims.csv

   fact_claims uses the NATURAL keys already present in the source files
   (payer_id, provider_id, cpt_code, denial_code) as its foreign keys rather
   than manufacturing new surrogate keys - the source dimensions already
   have stable, unique identifiers, so adding another layer of surrogate
   keys would just be extra complexity with no benefit here.
   ============================================================================= */

IF DB_ID('ClaimsDenialAnalytics') IS NULL
BEGIN
    CREATE DATABASE ClaimsDenialAnalytics;
END
GO

USE ClaimsDenialAnalytics;
GO

IF OBJECT_ID('dbo.fact_claims', 'U') IS NOT NULL DROP TABLE dbo.fact_claims;
IF OBJECT_ID('dbo.dim_date', 'U') IS NOT NULL DROP TABLE dbo.dim_date;
IF OBJECT_ID('dbo.dim_payer', 'U') IS NOT NULL DROP TABLE dbo.dim_payer;
IF OBJECT_ID('dbo.dim_provider', 'U') IS NOT NULL DROP TABLE dbo.dim_provider;
IF OBJECT_ID('dbo.dim_cpt', 'U') IS NOT NULL DROP TABLE dbo.dim_cpt;
IF OBJECT_ID('dbo.dim_denial_reason', 'U') IS NOT NULL DROP TABLE dbo.dim_denial_reason;
GO

/* =============================================================================
   DIMENSION TABLES - column names/types mirror the source CSVs 1:1
   ============================================================================= */

CREATE TABLE dbo.dim_date (
    date_key        DATE            NOT NULL PRIMARY KEY,
    [day]           TINYINT         NOT NULL,
    [month]         TINYINT         NOT NULL,
    month_name      VARCHAR(10)     NOT NULL,
    [quarter]       TINYINT         NOT NULL,
    [year]          SMALLINT        NOT NULL,
    weekday_name    VARCHAR(10)     NOT NULL,
    is_weekend      BIT             NOT NULL
);
GO

CREATE TABLE dbo.dim_payer (
    payer_id        INT             NOT NULL PRIMARY KEY,
    payer_name      VARCHAR(100)    NOT NULL,
    payer_type      VARCHAR(30)     NOT NULL
);
GO

CREATE TABLE dbo.dim_provider (
    provider_id     INT             NOT NULL PRIMARY KEY,
    provider_name   VARCHAR(100)    NOT NULL,
    specialty       VARCHAR(50)     NOT NULL,
    department      VARCHAR(50)     NOT NULL
);
GO

CREATE TABLE dbo.dim_cpt (
    cpt_code        VARCHAR(10)     NOT NULL PRIMARY KEY,
    [description]   VARCHAR(150)    NOT NULL,
    category        VARCHAR(30)     NOT NULL
);
GO

CREATE TABLE dbo.dim_denial_reason (
    denial_id           INT             NOT NULL PRIMARY KEY,
    denial_code          VARCHAR(10)     NOT NULL UNIQUE,
    denial_category       VARCHAR(30)     NOT NULL,
    denial_description     VARCHAR(150)    NOT NULL
);

-- Sentinel row so fact_claims.denial_code can be NOT NULL even for
-- non-denied claims - keeps every join to dim_denial_reason an INNER JOIN.
INSERT INTO dbo.dim_denial_reason (denial_id, denial_code, denial_category, denial_description)
VALUES (0, 'NONE', 'Not Denied', 'Claim was not denied');
GO

/* =============================================================================
   FACT TABLE
   ============================================================================= */

CREATE TABLE dbo.fact_claims (
    claim_key         INT IDENTITY(1,1)  NOT NULL PRIMARY KEY,
    claim_id          VARCHAR(15)        NOT NULL UNIQUE,
    patient_id        VARCHAR(15)        NOT NULL,
    provider_id       INT                NOT NULL,
    payer_id          INT                NOT NULL,
    cpt_code          VARCHAR(10)        NOT NULL,
    denial_code       VARCHAR(10)        NOT NULL,   -- 'NONE' = not denied
    service_date      DATE               NOT NULL,
    submitted_date    DATE               NOT NULL,
    paid_date         DATE               NULL,        -- NULL until a claim is actually paid
    billed_amount     DECIMAL(10,2)      NOT NULL,
    allowed_amount    DECIMAL(10,2)      NOT NULL,     -- 0 until adjudicated/allowed
    paid_amount       DECIMAL(10,2)      NOT NULL,     -- 0 until paid
    claim_status      VARCHAR(10)        NOT NULL,     -- Paid / Denied / Pending / Voided
    is_denied         BIT                NOT NULL,

    CONSTRAINT FK_fact_claims_provider FOREIGN KEY (provider_id)  REFERENCES dbo.dim_provider(provider_id),
    CONSTRAINT FK_fact_claims_payer    FOREIGN KEY (payer_id)     REFERENCES dbo.dim_payer(payer_id),
    CONSTRAINT FK_fact_claims_cpt      FOREIGN KEY (cpt_code)     REFERENCES dbo.dim_cpt(cpt_code),
    CONSTRAINT FK_fact_claims_denial   FOREIGN KEY (denial_code)  REFERENCES dbo.dim_denial_reason(denial_code),
    CONSTRAINT FK_fact_claims_date     FOREIGN KEY (service_date) REFERENCES dbo.dim_date(date_key)
);
GO

CREATE INDEX IX_fact_claims_payer_denied  ON dbo.fact_claims (payer_id, is_denied);
CREATE INDEX IX_fact_claims_service_date  ON dbo.fact_claims (service_date);
CREATE INDEX IX_fact_claims_denial_code   ON dbo.fact_claims (denial_code);
GO

PRINT 'Schema created successfully.';
