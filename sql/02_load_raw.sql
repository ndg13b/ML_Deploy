-- =====================================================================
-- 02_load_raw.sql — load the uploaded Parquet files into a raw table.
-- Run after uploading data/ny_wcb/*.parquet to @WC_ML.RAW.WCB_STAGE.
-- =====================================================================
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WC_ML_WH;

-- Check the upload: expect one row per part-XXXX.parquet file.
LIST @WC_ML.RAW.WCB_STAGE;

CREATE FILE FORMAT IF NOT EXISTS WC_ML.RAW.PARQUET_FMT TYPE = PARQUET;

-- Build the table from the files' own schema (every column is text by design).
CREATE OR REPLACE TABLE WC_ML.RAW.NY_WCB_CLAIMS
  USING TEMPLATE (
    SELECT ARRAY_AGG(OBJECT_CONSTRUCT(*)) WITHIN GROUP (ORDER BY ORDER_ID)
    FROM TABLE(INFER_SCHEMA(
      LOCATION    => '@WC_ML.RAW.WCB_STAGE',
      FILE_FORMAT => 'WC_ML.RAW.PARQUET_FMT'
    ))
  );

COPY INTO WC_ML.RAW.NY_WCB_CLAIMS
  FROM @WC_ML.RAW.WCB_STAGE
  FILE_FORMAT = (FORMAT_NAME = 'WC_ML.RAW.PARQUET_FMT')
  MATCH_BY_COLUMN_NAME = CASE_SENSITIVE;

-- Sanity checks
SELECT COUNT(*) AS N_CLAIMS FROM WC_ML.RAW.NY_WCB_CLAIMS;
SELECT ATTORNEY_REPRESENTATIVE, COUNT(*) FROM WC_ML.RAW.NY_WCB_CLAIMS GROUP BY 1 ORDER BY 2 DESC;
DESCRIBE TABLE WC_ML.RAW.NY_WCB_CLAIMS;
