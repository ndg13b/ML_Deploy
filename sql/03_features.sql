-- =====================================================================
-- 03_features.sql — one feature view shared by training AND scoring.
--
-- Keeping the feature logic in one SQL view means the deployed model
-- sees exactly the same transformations it was trained on.
--
-- LEAKAGE RULE: only use information known when the claim is first
-- assembled. Fields that come later in the claim's life are deliberately
-- left out, because they are partly caused by attorney involvement:
--   Claim Injury Type, Current Claim Status, Highest Process,
--   C-3 Date, First Hearing Date, Controverted Date, IME-4 Count,
--   Alternative Dispute Resolution, Agreement Reached, WCB Decision,
--   Average Weekly Wage (often established later, at hearings).
-- =====================================================================
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WC_ML_WH;

CREATE OR REPLACE VIEW WC_ML.ANALYTICS.CLAIM_FEATURES AS
WITH base AS (
  SELECT
    CLAIM_IDENTIFIER,
    -- TRY_ conversion functions only accept text, so each input is wrapped in TO_VARCHAR.
    -- This also keeps the view working if a raw column was loaded as a DATE or NUMBER.
    TRY_TO_DATE(LEFT(TO_VARCHAR(ACCIDENT_DATE), 10)) AS ACCIDENT_DT,
    TRY_TO_DATE(LEFT(TO_VARCHAR(ASSEMBLY_DATE), 10)) AS ASSEMBLY_DT,
    TRY_TO_DOUBLE(TO_VARCHAR(AGE_AT_INJURY))         AS AGE_RAW,
    ATTORNEY_REPRESENTATIVE,
    GENDER,
    CARRIER_TYPE,
    DISTRICT_NAME,
    COUNTY_OF_INJURY,
    MEDICAL_FEE_REGION,
    INDUSTRY_CODE,
    WCIO_CAUSE_OF_INJURY_CODE,
    WCIO_NATURE_OF_INJURY_CODE,
    WCIO_PART_OF_BODY_CODE,
    COVID_19_INDICATOR
  FROM WC_ML.RAW.NY_WCB_CLAIMS
)
SELECT
  -- identifiers / split keys (not model inputs)
  CLAIM_IDENTIFIER,
  ASSEMBLY_DT,
  YEAR(ASSEMBLY_DT) AS ASSEMBLY_YEAR,

  -- label: 1 if the claimant has an attorney or representative
  IFF(UPPER(TRIM(ATTORNEY_REPRESENTATIVE)) IN ('Y', 'YES', 'TRUE', '1'), 1, 0) AS IS_LITIGATED,

  -- numeric features (FLOAT so missing values become NaN for XGBoost)
  IFF(AGE_RAW BETWEEN 14 AND 90, AGE_RAW, NULL)::FLOAT AS AGE_AT_INJURY,
  IFF(DATEDIFF('day', ACCIDENT_DT, ASSEMBLY_DT) BETWEEN 0 AND 3650,
      DATEDIFF('day', ACCIDENT_DT, ASSEMBLY_DT), NULL)::FLOAT AS REPORT_LAG_DAYS,
  MONTH(ACCIDENT_DT)::FLOAT     AS ACCIDENT_MONTH,
  DAYOFWEEKISO(ACCIDENT_DT)::FLOAT AS ACCIDENT_DOW,

  -- categorical features (never NULL, so one-hot encoding is predictable)
  COALESCE(NULLIF(TRIM(GENDER), ''), 'UNKNOWN')             AS GENDER,
  COALESCE(NULLIF(TRIM(CARRIER_TYPE), ''), 'UNKNOWN')       AS CARRIER_TYPE,
  COALESCE(NULLIF(TRIM(DISTRICT_NAME), ''), 'UNKNOWN')      AS DISTRICT_NAME,
  COALESCE(NULLIF(TRIM(COUNTY_OF_INJURY), ''), 'UNKNOWN')   AS COUNTY_OF_INJURY,
  COALESCE(NULLIF(TRIM(MEDICAL_FEE_REGION), ''), 'UNKNOWN') AS MEDICAL_FEE_REGION,
  COALESCE(NULLIF(TRIM(INDUSTRY_CODE), ''), 'UNKNOWN')      AS INDUSTRY_CODE,
  -- codes can arrive as '97' or '97.0'; normalize to whole-number text.
  -- TRY_TO_DOUBLE parses the text, then a plain ::NUMBER cast drops the '.0'
  -- (TRY_TO_NUMBER can't be used here: it rejects FLOAT input).
  COALESCE(TO_VARCHAR(TRY_TO_DOUBLE(TO_VARCHAR(WCIO_CAUSE_OF_INJURY_CODE))::NUMBER(38, 0)), 'UNKNOWN')  AS WCIO_CAUSE_CODE,
  COALESCE(TO_VARCHAR(TRY_TO_DOUBLE(TO_VARCHAR(WCIO_NATURE_OF_INJURY_CODE))::NUMBER(38, 0)), 'UNKNOWN') AS WCIO_NATURE_CODE,
  COALESCE(TO_VARCHAR(TRY_TO_DOUBLE(TO_VARCHAR(WCIO_PART_OF_BODY_CODE))::NUMBER(38, 0)), 'UNKNOWN')     AS WCIO_BODY_CODE,
  COALESCE(NULLIF(TRIM(COVID_19_INDICATOR), ''), 'UNKNOWN') AS COVID_19_INDICATOR
FROM base
WHERE ASSEMBLY_DT IS NOT NULL;

-- Litigation rate by year: later years will look lower because attorneys
-- can join a claim years after it opens (the label is "immature").
SELECT ASSEMBLY_YEAR, COUNT(*) AS N, ROUND(AVG(IS_LITIGATED), 4) AS LITIGATION_RATE
FROM WC_ML.ANALYTICS.CLAIM_FEATURES
GROUP BY 1 ORDER BY 1;
