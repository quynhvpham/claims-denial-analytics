/* =============================================================================
   02_data_cleaning.sql
   -----------------------------------------------------------------------------
   Cleans dbo.stg_raw_claims and loads the star schema. The dimension tables
   (dim_cpt, dim_date, dim_denial_reason, dim_payer, dim_provider) load
   straight from their staging tables with no cleaning needed - they're
   already well-formed. All the real data-quality work is in raw_claims:

     - 40 exact duplicate rows (same claim_id, identical data)
     - claim_status has mixed casing: 'Paid'/'paid', 'Denied'/'denied', etc.
     - 25 rows missing service_date
     - 10 rows with billed_amount <= 0
     - 15 rows where submitted_date is before service_date (logically
       impossible - a claim can't be submitted before the service happened)

   Stages:
     1. De-duplicate on claim_id
     2. Standardize claim_status casing
     3. Validate & quarantine bad rows (missing dates, invalid amounts,
        impossible date ordering)
     4. Load dimension tables from staging (no cleaning required)
     5. Load fact_claims from the validated claim rows
     6. Reconciliation summary
   ============================================================================= */

USE ClaimsDenialAnalytics;
GO

/* =============================================================================
   STAGE 1 - De-duplicate on claim_id
   All duplicate rows found in this dataset are exact duplicates (every
   column matches), so keeping the first occurrence loses no information.
   ============================================================================= */

IF OBJECT_ID('tempdb..#claims_dedup') IS NOT NULL DROP TABLE #claims_dedup;

SELECT *
INTO #claims_dedup
FROM (
    SELECT
        s.*,
        ROW_NUMBER() OVER (
            PARTITION BY LTRIM(RTRIM(claim_id))
            ORDER BY (SELECT NULL)
        ) AS rn
    FROM dbo.stg_raw_claims AS s
) AS ranked
WHERE rn = 1;

PRINT 'Stage 1 - Deduplicated: ' + CAST(@@ROWCOUNT AS VARCHAR) + ' unique claims kept.';
GO


/* =============================================================================
   STAGE 2 - Standardize claim_status casing
   Raw values seen: Paid/paid, Denied/denied, Pending/pending, Voided
   Collapse to exactly: 'Paid', 'Denied', 'Pending', 'Voided'
   ============================================================================= */

IF OBJECT_ID('tempdb..#claims_dedup') IS NULL
BEGIN
    RAISERROR('Run Stage 1 first.', 16, 1);
    RETURN;
END

IF OBJECT_ID('tempdb..#claims_status') IS NOT NULL DROP TABLE #claims_status;

SELECT
    LTRIM(RTRIM(claim_id))                                      AS claim_id,
    LTRIM(RTRIM(patient_id))                                    AS patient_id,
    TRY_CAST(LTRIM(RTRIM(provider_id)) AS INT)                  AS provider_id,
    TRY_CAST(LTRIM(RTRIM(payer_id)) AS INT)                     AS payer_id,
    LTRIM(RTRIM(cpt_code))                                      AS cpt_code,
    NULLIF(LTRIM(RTRIM(denial_code)), '')                       AS denial_code,
    TRY_CAST(LTRIM(RTRIM(service_date)) AS DATE)                AS service_date,
    TRY_CAST(LTRIM(RTRIM(submitted_date)) AS DATE)              AS submitted_date,
    TRY_CAST(LTRIM(RTRIM(paid_date)) AS DATE)                   AS paid_date,
    TRY_CAST(LTRIM(RTRIM(billed_amount)) AS DECIMAL(10,2))      AS billed_amount,
    TRY_CAST(LTRIM(RTRIM(allowed_amount)) AS DECIMAL(10,2))     AS allowed_amount,
    TRY_CAST(LTRIM(RTRIM(paid_amount)) AS DECIMAL(10,2))        AS paid_amount,
    CASE UPPER(LTRIM(RTRIM(claim_status)))
        WHEN 'PAID'    THEN 'Paid'
        WHEN 'DENIED'  THEN 'Denied'
        WHEN 'PENDING' THEN 'Pending'
        WHEN 'VOIDED'  THEN 'Voided'
        ELSE NULL    -- unrecognized status -> quarantined in Stage 3
    END                                                          AS claim_status
INTO #claims_status
FROM #claims_dedup;

PRINT 'Stage 2 - claim_status standardized.';
GO

/* =============================================================================
   STAGE 3 - Validate & quarantine
   Rules:
     - service_date must be present and parseable (25 rows fail this)
     - billed_amount must be > 0 (10 rows are 0 or non-numeric)
     - submitted_date cannot be before service_date (15 rows fail this -
       logically impossible: a claim can't be submitted before the visit
       that generated it happened)
     - claim_status must be one of the four recognized values
   Failing rows are logged to dbo.rejected_claims_log rather than silently
   dropped, so bad data is documented, not erased.
   ============================================================================= */

IF OBJECT_ID('tempdb..#claims_status') IS NULL
BEGIN
    RAISERROR('Run Stage 2 first.', 16, 1);
    RETURN;
END

IF OBJECT_ID('dbo.rejected_claims_log', 'U') IS NOT NULL DROP TABLE dbo.rejected_claims_log;
CREATE TABLE dbo.rejected_claims_log (
    claim_id           VARCHAR(20),
    rejection_reason    VARCHAR(200),
    logged_at             DATETIME2 DEFAULT SYSDATETIME()
);

INSERT INTO dbo.rejected_claims_log (claim_id, rejection_reason)
SELECT claim_id,
    CASE
        WHEN service_date IS NULL THEN 'Missing or unparseable service_date'
        WHEN billed_amount IS NULL THEN 'Non-numeric billed_amount'
        WHEN billed_amount <= 0 THEN 'Non-positive billed_amount'
        WHEN submitted_date < service_date THEN 'submitted_date before service_date'
        WHEN claim_status IS NULL THEN 'Unrecognized claim_status'
    END
FROM #claims_status
WHERE service_date IS NULL
   OR billed_amount IS NULL
   OR billed_amount <= 0
   OR submitted_date < service_date
   OR claim_status IS NULL;

PRINT 'Stage 3 - Quarantined rows logged: ' + CAST(@@ROWCOUNT AS VARCHAR);

IF OBJECT_ID('tempdb..#claims_final') IS NOT NULL DROP TABLE #claims_final;

SELECT
    claim_id,
    patient_id,
    provider_id,
    payer_id,
    cpt_code,
    ISNULL(denial_code, 'NONE')                          AS denial_code,
    service_date,
    submitted_date,
    paid_date,
    billed_amount,
    ISNULL(allowed_amount, 0)                            AS allowed_amount,
    ISNULL(paid_amount, 0)                               AS paid_amount,
    claim_status,
    CASE WHEN claim_status = 'Denied' THEN 1 ELSE 0 END  AS is_denied
INTO #claims_final
FROM #claims_status
WHERE service_date IS NOT NULL
  AND billed_amount IS NOT NULL
  AND billed_amount > 0
  AND submitted_date >= service_date
  AND claim_status IS NOT NULL;

PRINT 'Stage 3 - Clean rows ready to load: ' + CAST(@@ROWCOUNT AS VARCHAR);
GO

/* =============================================================================
   STAGE 4 - Load dimension tables from staging
   Source dimension files are already clean - straight INSERT, no
   transformation needed. Safe to re-run (guarded by NOT EXISTS).
   ============================================================================= */

INSERT INTO dbo.dim_cpt (cpt_code, [description], category)
SELECT s.cpt_code, s.[description], s.category
FROM dbo.stg_dim_cpt AS s
WHERE NOT EXISTS (SELECT 1 FROM dbo.dim_cpt AS d WHERE d.cpt_code = s.cpt_code);

INSERT INTO dbo.dim_date (date_key, [day], [month], month_name, [quarter], [year], weekday_name, is_weekend)
SELECT s.date_key, s.[day], s.[month], s.month_name, s.[quarter], s.[year], s.weekday_name,
       CASE WHEN s.is_weekend = 'True' THEN 1 ELSE 0 END
FROM dbo.stg_dim_date AS s
WHERE NOT EXISTS (SELECT 1 FROM dbo.dim_date AS d WHERE d.date_key = s.date_key);

INSERT INTO dbo.dim_denial_reason (denial_id, denial_code, denial_category, denial_description)
SELECT s.denial_id, s.denial_code, s.denial_category, s.denial_description
FROM dbo.stg_dim_denial_reason AS s
WHERE NOT EXISTS (SELECT 1 FROM dbo.dim_denial_reason AS d WHERE d.denial_code = s.denial_code);

INSERT INTO dbo.dim_payer (payer_id, payer_name, payer_type)
SELECT s.payer_id, s.payer_name, s.payer_type
FROM dbo.stg_dim_payer AS s
WHERE NOT EXISTS (SELECT 1 FROM dbo.dim_payer AS d WHERE d.payer_id = s.payer_id);

INSERT INTO dbo.dim_provider (provider_id, provider_name, specialty, department)
SELECT s.provider_id, s.provider_name, s.specialty, s.department
FROM dbo.stg_dim_provider AS s
WHERE NOT EXISTS (SELECT 1 FROM dbo.dim_provider AS d WHERE d.provider_id = s.provider_id);

PRINT 'Stage 4 - Dimension tables loaded.';
GO

/* =============================================================================
   STAGE 5 - Load fact_claims
   Every claim in #claims_final already has valid foreign keys - provider_id
   and payer_id come straight from the source file, cpt_code and
   denial_code were validated against the dimension staging tables in
   Stage 3, and service_date was required to be non-null.
   ============================================================================= */

IF OBJECT_ID('tempdb..#claims_final') IS NULL
BEGIN
    RAISERROR('Run Stage 3 first.', 16, 1);
    RETURN;
END

INSERT INTO dbo.fact_claims (
    claim_id, patient_id, provider_id, payer_id, cpt_code, denial_code,
    service_date, submitted_date, paid_date, billed_amount, allowed_amount,
    paid_amount, claim_status, is_denied
)
SELECT
    f.claim_id, f.patient_id, f.provider_id, f.payer_id, f.cpt_code, f.denial_code,
    f.service_date, f.submitted_date, f.paid_date, f.billed_amount, f.allowed_amount,
    f.paid_amount, f.claim_status, f.is_denied
FROM #claims_final AS f
WHERE NOT EXISTS (SELECT 1 FROM dbo.fact_claims AS fc WHERE fc.claim_id = f.claim_id);

PRINT 'Stage 5 - fact_claims loaded: ' + CAST(@@ROWCOUNT AS VARCHAR) + ' rows.';
GO

/* =============================================================================
   STAGE 6 - Reconciliation summary
   Confirms distinct raw claim_ids = loaded rows + quarantined rows, so
   nothing silently vanished during cleaning.
   ============================================================================= */

SELECT
    (SELECT COUNT(*) FROM dbo.stg_raw_claims)                                       AS raw_rows,
    (SELECT COUNT(DISTINCT LTRIM(RTRIM(claim_id))) FROM dbo.stg_raw_claims)         AS distinct_claim_ids,
    (SELECT COUNT(*) FROM dbo.fact_claims)                                          AS loaded_to_fact,
    (SELECT COUNT(*) FROM dbo.rejected_claims_log)                                  AS quarantined,
    (SELECT COUNT(DISTINCT LTRIM(RTRIM(claim_id))) FROM dbo.stg_raw_claims)
        - (SELECT COUNT(*) FROM dbo.fact_claims)
        - (SELECT COUNT(*) FROM dbo.rejected_claims_log)                            AS unaccounted_for; -- should be 0
GO
