# Power BI: DAX Measures

Connect Power BI Desktop to SQL Server (`Get Data -> SQL Server`), pointing
at `ClaimsDenialAnalytics`. Import the star schema tables (`fact_claims`,
`dim_date`, `dim_payer`, `dim_provider`, `dim_cpt`, `dim_denial_reason`) -
**not** `stg_dim_*`, `stg_raw_claims`, or `rejected_claims_log`, which are
staging/audit tables, not part of the analytical model.

## Model relationships

Verify each is a **single-direction, one-to-many** relationship
(dimension "1" side -> fact "many" side). These join on natural keys, not
manufactured surrogate keys, since the source dimensions already had
stable unique identifiers:

| From (dimension)                | To (fact)                     |
|-----------------------------------|--------------------------------|
| dim_date[date_key]                | fact_claims[service_date]     |
| dim_payer[payer_id]               | fact_claims[payer_id]         |
| dim_provider[provider_id]         | fact_claims[provider_id]      |
| dim_cpt[cpt_code]                 | fact_claims[cpt_code]         |
| dim_denial_reason[denial_code]    | fact_claims[denial_code]      |

Mark `dim_date` as a **Date table** (Table tools -> Mark as date table ->
`date_key` column) so time intelligence functions work correctly.

## Core measures

Create these in a dedicated measure table (New Table -> name it
`_Measures`) rather than scattering them across `fact_claims`.

```dax
Total Claims =
COUNTROWS ( fact_claims )
```

```dax
Denied Claims =
CALCULATE (
    COUNTROWS ( fact_claims ),
    fact_claims[is_denied] = 1
)
```

```dax
Denial Rate % =
DIVIDE ( [Denied Claims], [Total Claims], 0 )
```

```dax
Paid Claims =
CALCULATE (
    COUNTROWS ( fact_claims ),
    fact_claims[claim_status] = "Paid"
)
```

```dax
Pending Claims =
CALCULATE (
    COUNTROWS ( fact_claims ),
    fact_claims[claim_status] = "Pending"
)
```

```dax
Total Billed =
SUM ( fact_claims[billed_amount] )
```

```dax
Total Denied Billed $ =
CALCULATE (
    SUM ( fact_claims[billed_amount] ),
    fact_claims[is_denied] = 1
)
```

```dax
Total Paid =
SUM ( fact_claims[paid_amount] )
```

```dax
Avg Days to Payment =
-- Only meaningful for Paid claims - Denied/Pending/Voided claims have no
-- paid_date, so AVERAGEX naturally excludes them via the FILTER.
AVERAGEX (
    FILTER ( fact_claims, fact_claims[claim_status] = "Paid" ),
    DATEDIFF ( fact_claims[submitted_date], fact_claims[paid_date], DAY )
)
```

```dax
Denial Rate % (Prior Period) =
CALCULATE (
    [Denial Rate %],
    DATEADD ( dim_date[date_key], -1, MONTH )
)
```

```dax
Denial Rate % MoM Change =
[Denial Rate %] - [Denial Rate % (Prior Period)]
```

```dax
% of Total Denied Dollars =
DIVIDE (
    [Total Denied Billed $],
    CALCULATE ( [Total Denied Billed $], ALL ( dim_denial_reason ) ),
    0
)
```

```dax
Provider Denial Rate (Min Volume) =
-- Returns BLANK for providers under the reliability threshold, so a
-- low-volume provider doesn't visually rank alongside high-volume ones.
VAR ClaimCount = [Total Claims]
RETURN
    IF ( ClaimCount >= 50, [Denial Rate %], BLANK () )
```

## Notes on matching the SQL results

Every measure above should reconcile to a query in
`sql/03_analysis_queries.sql`:

- `Denial Rate %` sliced by `dim_payer[payer_name]` -> Q1 (Texas Medicaid
  comes out highest in the source data - roughly double Aetna's rate)
- `Denied Claims` sliced by `dim_denial_reason[denial_code]` and
  `dim_payer[payer_name]` -> Q2
- `Total Denied Billed $` sliced by `dim_denial_reason[denial_category]` -> Q3
  (Prior Auth denials carry the largest total dollar impact in this
  dataset, even though Coding denials are more numerous - a "fix the
  expensive problem, not just the frequent one" story)
- `Denial Rate %` sliced by `dim_date[month_name]` on a line chart -> Q4
- `Provider Denial Rate (Min Volume)` sliced by `dim_provider[provider_name]` -> Q5
- `Avg Days to Payment` sliced by `dim_payer[payer_name]` -> Q7

If a Power BI card and the matching SQL query disagree, treat it as a bug
to find - usually a relationship's cross-filter direction, or a slicer
implicitly filtering something it shouldn't (e.g. an "is_denied = 1" visual
filter accidentally applied to a card that should count all claims).

## Suggested pages

1. **Executive Summary** - KPI cards (Total Claims, Denial Rate %, Total
   Denied Billed $), denial rate trend line by month, denial rate by payer
   bar chart.
2. **Denial Root Cause** - denial category breakdown by count and by
   dollar impact, sliced by payer; the payer x top-category table from Q8.
3. **Provider & Procedure Detail** - denial rate by provider (volume-
   filtered), denial rate by CPT code, payment-aging bucket breakdown.

## Suggested slicers

`dim_date[year]`, `dim_payer[payer_type]`, `dim_denial_reason[denial_category]`,
`fact_claims[claim_status]`
