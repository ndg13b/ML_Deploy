-- =====================================================================
-- 04_deploy_scoring.sql — put the registered model to work.
-- Run after notebooks/02_train_and_register.ipynb has registered
-- WC_ML.MODELS.WC_LITIGATION_XGB and set its default version.
-- =====================================================================
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WC_ML_WH;

-- ---------------------------------------------------------------------
-- A) Ad-hoc inference straight from SQL, using the model's DEFAULT version.
--    Syntax: <model name>!<method>(...). Arguments must be in the same order as the
--    model signature: numeric features first, then categorical (FEATURES in the notebook).
--    PRED is an object holding one probability per class. The notebook's
--    mv.show_functions() output lists the key names (class 1 = litigated).
--
--    To call one specific version instead of the default:
--      WITH mv AS MODEL WC_ML.MODELS.WC_LITIGATION_XGB VERSION V_20261014_120000
--      SELECT mv!PREDICT_PROBA(...) FROM ...;
-- ---------------------------------------------------------------------
SELECT
  f.CLAIM_IDENTIFIER,
  f.IS_LITIGATED,
  WC_ML.MODELS.WC_LITIGATION_XGB!PREDICT_PROBA(
    f.AGE_AT_INJURY, f.REPORT_LAG_DAYS, f.ACCIDENT_MONTH, f.ACCIDENT_DOW,
    f.GENDER, f.CARRIER_TYPE, f.DISTRICT_NAME, f.COUNTY_OF_INJURY, f.MEDICAL_FEE_REGION,
    f.INDUSTRY_CODE, f.WCIO_CAUSE_CODE, f.WCIO_NATURE_CODE, f.WCIO_BODY_CODE, f.COVID_19_INDICATOR
  ) AS PRED
FROM WC_ML.ANALYTICS.CLAIM_FEATURES f
WHERE f.ASSEMBLY_YEAR = 2023
LIMIT 20;

-- ---------------------------------------------------------------------
-- B) Batch scoring: a table of predictions plus a procedure that scores
--    any claim not yet scored. "New" claims = assembled in 2023 or later,
--    which the model never saw (training used 2017–2022).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS WC_ML.SCORING.CLAIM_LITIGATION_SCORES (
  CLAIM_IDENTIFIER  STRING,
  ASSEMBLY_DT       DATE,
  LITIGATION_PROB   FLOAT,
  MODEL_VERSION     STRING,
  SCORED_AT         TIMESTAMP_NTZ
);

CREATE OR REPLACE PROCEDURE WC_ML.SCORING.SCORE_NEW_CLAIMS(MIN_ASSEMBLY_YEAR NUMBER)
  RETURNS STRING
  LANGUAGE PYTHON
  RUNTIME_VERSION = '3.11'
  PACKAGES = ('snowflake-snowpark-python', 'snowflake-ml-python')
  HANDLER = 'run'
AS
$$
from snowflake.ml.registry import Registry
from snowflake.snowpark import functions as F

SCORES = "WC_ML.SCORING.CLAIM_LITIGATION_SCORES"


def run(session, min_assembly_year):
    reg = Registry(session=session, database_name="WC_ML", schema_name="MODELS")
    mv = reg.get_model("WC_LITIGATION_XGB").default

    already_scored = session.table(SCORES).select("CLAIM_IDENTIFIER")
    new_claims = (
        session.table("WC_ML.ANALYTICS.CLAIM_FEATURES")
        .filter(F.col("ASSEMBLY_YEAR") >= min_assembly_year)
        .join(already_scored, on="CLAIM_IDENTIFIER", how="leftanti")
    )
    n = new_claims.count()
    if n == 0:
        return "No new claims to score."

    preds = mv.run(new_claims, function_name="predict_proba")
    # Probability of class 1 (litigated) is the last predict_proba output column.
    prob_col = [c for c in preds.columns if "output_feature" in c.lower() or "predict_proba" in c.lower()][-1]

    (
        preds.select(
            F.col("CLAIM_IDENTIFIER"),
            F.col("ASSEMBLY_DT"),
            F.col(prob_col).cast("FLOAT").alias("LITIGATION_PROB"),
            F.lit(mv.version_name).alias("MODEL_VERSION"),
            F.current_timestamp().cast("TIMESTAMP_NTZ").alias("SCORED_AT"),
        )
        .write.mode("append")
        .save_as_table(SCORES, column_order="name")
    )
    return f"Scored {n} claims with model version {mv.version_name}."
$$;

-- Run it once by hand.
CALL WC_ML.SCORING.SCORE_NEW_CLAIMS(2023);

SELECT * FROM WC_ML.SCORING.CLAIM_LITIGATION_SCORES ORDER BY LITIGATION_PROB DESC LIMIT 25;

-- ---------------------------------------------------------------------
-- C) Schedule it. The task is created SUSPENDED so it costs nothing until you
--    choose to RESUME it. Each run uses the warehouse for about a minute.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TASK WC_ML.SCORING.SCORE_NEW_CLAIMS_DAILY
  WAREHOUSE = WC_ML_WH
  SCHEDULE = 'USING CRON 0 6 * * * America/New_York'
AS
  CALL WC_ML.SCORING.SCORE_NEW_CLAIMS(2023);

-- ALTER TASK WC_ML.SCORING.SCORE_NEW_CLAIMS_DAILY RESUME;   -- turn on
-- ALTER TASK WC_ML.SCORING.SCORE_NEW_CLAIMS_DAILY SUSPEND;  -- turn off
-- EXECUTE TASK WC_ML.SCORING.SCORE_NEW_CLAIMS_DAILY;        -- run once now

-- ---------------------------------------------------------------------
-- D) Monitoring: once outcomes are known, compare predictions with reality.
-- ---------------------------------------------------------------------
WITH scored AS (
  SELECT
    NTILE(10) OVER (ORDER BY s.LITIGATION_PROB DESC) AS RISK_DECILE,
    s.LITIGATION_PROB,
    f.IS_LITIGATED
  FROM WC_ML.SCORING.CLAIM_LITIGATION_SCORES s
  JOIN WC_ML.ANALYTICS.CLAIM_FEATURES f USING (CLAIM_IDENTIFIER)
)
SELECT
  RISK_DECILE,
  COUNT(*) AS N,
  ROUND(AVG(LITIGATION_PROB), 3) AS AVG_PREDICTED,
  ROUND(AVG(IS_LITIGATED), 3)    AS ACTUAL_RATE
FROM scored
GROUP BY 1 ORDER BY 1;
