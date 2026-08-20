/* =============================================================================
   03_analysis_queries.sql
   -----------------------------------------------------------------------------
   Eight core analytical queries against the star schema. Each answers one
   question a revenue-cycle stakeholder would actually ask. Note that
   claim_status here has FOUR values (Paid, Denied, Pending, Voided) - most
   denial-rate queries below deliberately use total claim count as the
   denominator (not just Paid+Denied), since Pending/Voided claims are real
   claims too and excluding them would inflate the apparent denial rate.
   ============================================================================= */

USE ClaimsDenialAnalytics;
GO

/* -----------------------------------------------------------------------------
   Q1. Denial RATE by payer (not raw count)
   Why rate, not count: the payer sending the most claims will always have
   the most denials in absolute terms. Rate is what's actually actionable.
   ----------------------------------------------------------------------------- */
SELECT
    p.payer_name,
    p.payer_type,
    COUNT(*)                                                    AS total_claims,
    SUM(f.is_denied)                                            AS denied_claims,
    CAST(SUM(f.is_denied) * 100.0 / COUNT(*) AS DECIMAL(5,2))   AS denial_rate_pct
FROM dbo.fact_claims AS f
JOIN dbo.dim_payer AS p ON p.payer_id = f.payer_id
GROUP BY p.payer_name, p.payer_type
ORDER BY denial_rate_pct DESC;
GO

/* -----------------------------------------------------------------------------
   Q2. Denial reason breakdown BY payer
   Answers "why" a given payer denies claims, not just "how often."
   ----------------------------------------------------------------------------- */
SELECT
    p.payer_name,
    dr.denial_code,
    dr.denial_category,
    COUNT(*)                                                              AS denial_count,
    CAST(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (PARTITION BY p.payer_name)
        AS DECIMAL(5,2))                                                  AS pct_of_payers_denials
FROM dbo.fact_claims AS f
JOIN dbo.dim_payer AS p          ON p.payer_id = f.payer_id
JOIN dbo.dim_denial_reason AS dr ON dr.denial_code = f.denial_code
WHERE f.is_denied = 1
GROUP BY p.payer_name, dr.denial_code, dr.denial_category
ORDER BY p.payer_name, denial_count DESC;
GO

/* -----------------------------------------------------------------------------
   Q3. Dollar impact by denial CATEGORY
   Denial rate tells you frequency; dollar impact tells you what to fix
   first if you can only fix one thing. In this dataset, Prior Auth denials
   carry the single largest total dollar impact even though Coding denials
   are more numerous - a classic "fix the expensive problem, not just the
   frequent one" finding.
   ----------------------------------------------------------------------------- */
SELECT
    dr.denial_category,
    COUNT(*)                                                       AS denial_count,
    SUM(f.billed_amount)                                           AS total_billed_denied,
    CAST(AVG(f.billed_amount) AS DECIMAL(10,2))                    AS avg_billed_per_denial,
    CAST(SUM(f.billed_amount) * 100.0
        / SUM(SUM(f.billed_amount)) OVER () AS DECIMAL(5,2))       AS pct_of_total_denied_dollars
FROM dbo.fact_claims AS f
JOIN dbo.dim_denial_reason AS dr ON dr.denial_code = f.denial_code
WHERE f.is_denied = 1
GROUP BY dr.denial_category
ORDER BY total_billed_denied DESC;
GO

/* -----------------------------------------------------------------------------
   Q4. Denial rate trend over time (monthly)
   The line chart this feeds is the standard "is it getting better or
   worse" view a revenue-cycle director would open first.
   ----------------------------------------------------------------------------- */
SELECT
    d.[year],
    d.[month],
    d.month_name,
    COUNT(*)                                                    AS total_claims,
    SUM(f.is_denied)                                            AS denied_claims,
    CAST(SUM(f.is_denied) * 100.0 / COUNT(*) AS DECIMAL(5,2))   AS denial_rate_pct
FROM dbo.fact_claims AS f
JOIN dbo.dim_date AS d ON d.date_key = f.service_date
GROUP BY d.[year], d.[month], d.month_name
ORDER BY d.[year], d.[month];
GO

/* -----------------------------------------------------------------------------
   Q5. Provider-level denial rate (with volume threshold)
   Filters out providers with too few claims to draw a reliable conclusion
   from - a provider with 5 claims and 2 denials is not meaningfully "40%."
   ----------------------------------------------------------------------------- */
SELECT
    pr.provider_name,
    pr.specialty,
    COUNT(*)                                                    AS total_claims,
    SUM(f.is_denied)                                            AS denied_claims,
    CAST(SUM(f.is_denied) * 100.0 / COUNT(*) AS DECIMAL(5,2))   AS denial_rate_pct
FROM dbo.fact_claims AS f
JOIN dbo.dim_provider AS pr ON pr.provider_id = f.provider_id
GROUP BY pr.provider_name, pr.specialty
HAVING COUNT(*) >= 50            -- minimum volume for a reliable rate
ORDER BY denial_rate_pct DESC;
GO

/* -----------------------------------------------------------------------------
   Q6. Top CPT/procedure codes by denial rate
   Identifies which specific services are most likely to get denied -
   actionable for pre-submission claim-scrubbing rules.
   ----------------------------------------------------------------------------- */
SELECT
    c.cpt_code,
    c.[description],
    c.category,
    COUNT(*)                                                    AS total_claims,
    SUM(f.is_denied)                                            AS denied_claims,
    CAST(SUM(f.is_denied) * 100.0 / COUNT(*) AS DECIMAL(5,2))   AS denial_rate_pct
FROM dbo.fact_claims AS f
JOIN dbo.dim_cpt AS c ON c.cpt_code = f.cpt_code
GROUP BY c.cpt_code, c.[description], c.category
ORDER BY denial_rate_pct DESC;
GO

/* -----------------------------------------------------------------------------
   Q7. Claim status mix and days-to-payment aging (Paid claims only)
   days_to_payment = submitted_date -> paid_date. Only meaningful for Paid
   claims, since Denied/Pending/Voided claims have no paid_date - this is
   the standard "how long does it take to get paid once submitted" metric.
   ----------------------------------------------------------------------------- */
SELECT
    CASE
        WHEN DATEDIFF(DAY, f.submitted_date, f.paid_date) <= 14 THEN '0-14 days'
        WHEN DATEDIFF(DAY, f.submitted_date, f.paid_date) <= 30 THEN '15-30 days'
        WHEN DATEDIFF(DAY, f.submitted_date, f.paid_date) <= 45 THEN '31-45 days'
        ELSE '46+ days'
    END                                                          AS payment_aging_bucket,
    COUNT(*)                                                     AS claim_count,
    SUM(f.paid_amount)                                           AS total_paid
FROM dbo.fact_claims AS f
WHERE f.claim_status = 'Paid'
GROUP BY
    CASE
        WHEN DATEDIFF(DAY, f.submitted_date, f.paid_date) <= 14 THEN '0-14 days'
        WHEN DATEDIFF(DAY, f.submitted_date, f.paid_date) <= 30 THEN '15-30 days'
        WHEN DATEDIFF(DAY, f.submitted_date, f.paid_date) <= 45 THEN '31-45 days'
        ELSE '46+ days'
    END
ORDER BY
    CASE payment_aging_bucket
        WHEN '0-14 days'  THEN 1
        WHEN '15-30 days' THEN 2
        WHEN '31-45 days' THEN 3
        ELSE 4
    END;
GO

/* -----------------------------------------------------------------------------
   Q8. Payer x Denial-Category matrix, ranked
   The single table that answers "if I could only send one email to one
   payer's contact about one issue, which payer and which issue?"
   ----------------------------------------------------------------------------- */
WITH payer_category_counts AS (
    SELECT
        p.payer_name,
        dr.denial_category,
        COUNT(*) AS denial_count,
        RANK() OVER (PARTITION BY p.payer_name ORDER BY COUNT(*) DESC) AS category_rank
    FROM dbo.fact_claims AS f
    JOIN dbo.dim_payer AS p          ON p.payer_id = f.payer_id
    JOIN dbo.dim_denial_reason AS dr ON dr.denial_code = f.denial_code
    WHERE f.is_denied = 1
    GROUP BY p.payer_name, dr.denial_category
)
SELECT payer_name, denial_category AS top_denial_category, denial_count
FROM payer_category_counts
WHERE category_rank = 1
ORDER BY denial_count DESC;
GO
