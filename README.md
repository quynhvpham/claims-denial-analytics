# Insurance Claims Denial Analytics (SQL Server + Power BI)

An end-to-end healthcare revenue-cycle analytics project: a real-world-style
medical billing claims export gets cleaned through a T-SQL pipeline into a
star schema, then analyzed to answer a real revenue-cycle question —
**which payers deny the most claims, why, and what does it cost?**

Built to mirror actual professional experience in insurance claims
processing, revenue cycle management (RCM), and denial root-cause analysis.

## The question this project answers

> Which payers are denying claims at an elevated rate, what's actually
> driving those denials, and where's the dollar impact concentrated?

The answer isn't "Payer X sends the most claims" (a volume artifact) — it's
**denial rate**, broken down **by reason code**, weighted **by dollar
impact**.

## Key findings (from the source data)

- **Texas Medicaid has the highest denial rate at ~23.8%** — roughly triple
  Aetna's rate (~7.9%) and well above the portfolio average (~15%).
- Across all payers, **Prior Auth denials carry the largest total dollar
  impact** (~$1.15M billed), even though **Coding denials are more
  numerous**. That's a "fix the expensive problem, not just the frequent
  one" finding — a pre-authorization workflow fix would move more dollars
  than a coding-focused fix, despite coding errors happening more often.
- **Medical Necessity denials have the second-highest average dollar value
  per denial** (~$3,194), consistent with medical-necessity denials
  concentrating on higher-cost procedures rather than routine visits.

## Tech stack

- **SQL Server** (T-SQL) — schema design, data cleaning, analysis
- **Power BI** — dashboard and DAX measures

No Python or other language is used anywhere in this pipeline — data
loading, cleaning, and analysis are done entirely in T-SQL, which is
deliberate: it's the skill this project is meant to demonstrate.

## Data

Six source files (already provided, not generated):

| File                     | Role                                             |
|----------------------------|---------------------------------------------------|
| `raw_claims.csv`           | ~9,040 claim records — the file with real data-quality issues |
| `dim_payer.csv`             | 5 payers (Aetna, UnitedHealthcare, Medicare, Texas Medicaid, Cigna) |
| `dim_provider.csv`           | 10 providers across specialties/departments      |
| `dim_cpt.csv`                  | 12 CPT procedure codes                            |
| `dim_denial_reason.csv`          | 6 CARC denial reason codes with categories        |
| `dim_date.csv`                    | Full calendar date dimension (2024–2025)          |

### Data quality issues found in `raw_claims.csv`

These are the actual issues in the source file — not synthetic examples —
and the cleaning pipeline is built specifically to handle them:

| Issue                                          | Rows affected |
|--------------------------------------------------|----------------|
| Exact duplicate rows (same `claim_id`)              | 40             |
| Mixed casing in `claim_status` (`Paid`/`paid`, etc.) | ~30            |
| Missing `service_date`                                | 25             |
| `billed_amount` ≤ 0                                     | 10             |
| `submitted_date` before `service_date` (logically invalid) | 15         |

After deduplication, 9,000 distinct claims remain; 50 fail validation and
are quarantined (logged, not dropped); **8,950 claims load into the fact
table.**

Note: nulls in `allowed_amount`, `paid_amount`, and `paid_date` are **not**
data quality issues — they're expected for Denied/Pending/Voided claims,
which by definition haven't been paid. The cleaning pipeline treats those
as legitimate business states, not errors to quarantine.

## Project structure

```
claims-project/
├── README.md                              <- you are here
├── data/                                  <- the six source CSVs
│   ├── raw_claims.csv
│   ├── dim_payer.csv
│   ├── dim_provider.csv
│   ├── dim_cpt.csv
│   ├── dim_denial_reason.csv
│   └── dim_date.csv
├── sql/
│   ├── 00_create_database_and_schema.sql  <- star schema DDL
│   ├── 01_staging_and_load.sql            <- staging tables + CSV load
│   ├── 02_data_cleaning.sql               <- 6-stage cleaning pipeline
│   └── 03_analysis_queries.sql            <- 8 core analytical queries
└── powerbi/
    └── DAX_measures.md                    <- model relationships + DAX measures
```

## Setup — run in this order

### 1. Prerequisites
- SQL Server (Developer or Express edition is fine) + SQL Server Management
  Studio (SSMS) or Azure Data Studio
- Power BI Desktop (optional, for the dashboard layer)

### 2. Create the database and schema
In SSMS, open and execute `sql/00_create_database_and_schema.sql`. This
creates the `ClaimsDenialAnalytics` database and the empty star schema
(with a seeded "NONE" row in `dim_denial_reason` for non-denied claims).

### 3. Load the raw data into staging
Copy all six CSVs to a path the SQL Server *service account* can read
(e.g. `C:\data\` on the server itself). Open `sql/01_staging_and_load.sql`,
**update the six file paths** in the `BULK INSERT` statements to match, and
execute. If `BULK INSERT` can't reach the files (common with cloud-hosted
or managed SQL Server), use the SSMS **Import Flat File** wizard instead —
instructions are in the comments of that script.

### 4. Run the cleaning pipeline
Open `sql/02_data_cleaning.sql` and execute it top to bottom (or stage by
stage, to inspect intermediate `#temp` tables while developing). This
de-duplicates, standardizes `claim_status`, validates dates and dollar
amounts, loads all five dimension tables, and loads `fact_claims`. Rows
that fail validation are logged to `dbo.rejected_claims_log` — nothing is
silently dropped. The final query reconciles raw row counts against
loaded + quarantined rows (should always balance to zero unaccounted-for).

### 5. Run the analysis
Open `sql/03_analysis_queries.sql` and run any/all of the 8 queries. Each
has a comment explaining the business question it answers.

### 6. Connect Power BI
Open Power BI Desktop -> **Get Data** -> **SQL Server** -> point at your
server and the `ClaimsDenialAnalytics` database. Import the dimension and
fact tables (not the staging/log tables). Follow `powerbi/DAX_measures.md`
for relationship setup and the core DAX measures, then build visuals.

## What this project demonstrates

- **Data modeling**: a star schema built on the source files' existing
  natural keys (`payer_id`, `provider_id`, `cpt_code`, `denial_code`)
  rather than manufacturing unnecessary surrogate keys, plus a sentinel
  dimension row so every fact-to-dimension join stays a simple INNER JOIN
- **Data cleaning**: a staged, auditable T-SQL pipeline — deduplication,
  text standardization, type validation, and a quarantine log for bad
  rows, with a reconciliation query proving nothing was silently dropped
- **SQL proficiency**: window functions (`ROW_NUMBER`, `RANK`, analytic
  `OVER (PARTITION BY ...)`), CTEs, `TRY_CAST` for safe type coercion, and
  query design that normalizes by rate rather than raw count
- **Analytical judgment**: distinguishing volume from rate, frequency from
  dollar impact, correctly handling nulls that represent legitimate
  business states (unpaid claims) vs. nulls that represent real data
  errors, and enforcing a minimum sample size before reporting a rate as
  reliable
- **BI/dashboard skills**: a proper star-schema Power BI model with DAX
  measures that reconcile to the underlying SQL

## Possible extensions

- Predictive model for denial likelihood per claim
- Days-in-A/R analysis extended to Pending claims (not just Paid)
- Row-level security in Power BI to simulate per-payer-team access
