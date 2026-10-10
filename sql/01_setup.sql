-- =====================================================================
-- 01_setup.sql — one-time account setup.
-- Run in a Snowsight SQL worksheet as ACCOUNTADMIN (trial users have this role).
-- =====================================================================
USE ROLE ACCOUNTADMIN;

-- Cost guardrail: notify at 75% of 40 credits, suspend the warehouse at 100%.
-- A $400 trial is roughly 100–130 credits depending on edition and region,
-- so this keeps most of the trial in reserve. Raise CREDIT_QUOTA if you need more.
CREATE OR REPLACE RESOURCE MONITOR WC_ML_MONITOR
  WITH CREDIT_QUOTA = 40
       FREQUENCY = MONTHLY
       START_TIMESTAMP = IMMEDIATELY
  TRIGGERS ON 75 PERCENT DO NOTIFY
           ON 100 PERCENT DO SUSPEND
           ON 110 PERCENT DO SUSPEND_IMMEDIATE;

-- X-Small = 1 credit/hour, billed per second while running. Suspends after 60s idle.
CREATE WAREHOUSE IF NOT EXISTS WC_ML_WH
  WAREHOUSE_SIZE = 'XSMALL'
  AUTO_SUSPEND = 60
  AUTO_RESUME = TRUE
  INITIALLY_SUSPENDED = TRUE;
ALTER WAREHOUSE WC_ML_WH SET RESOURCE_MONITOR = WC_ML_MONITOR;

CREATE DATABASE IF NOT EXISTS WC_ML;
CREATE SCHEMA IF NOT EXISTS WC_ML.RAW;        -- data exactly as downloaded
CREATE SCHEMA IF NOT EXISTS WC_ML.ANALYTICS;  -- cleaned feature view
CREATE SCHEMA IF NOT EXISTS WC_ML.MODELS;     -- Model Registry lives here
CREATE SCHEMA IF NOT EXISTS WC_ML.SCORING;    -- deployed predictions + scoring task
CREATE SCHEMA IF NOT EXISTS WC_ML.NOTEBOOKS;  -- Snowflake Notebooks

-- Internal stage for the Parquet files from scripts/download_ny_wcb.py.
-- DIRECTORY lets you browse and upload files from the Snowsight UI.
CREATE STAGE IF NOT EXISTS WC_ML.RAW.WCB_STAGE
  DIRECTORY = (ENABLE = TRUE)
  ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE');

USE WAREHOUSE WC_ML_WH;
USE DATABASE WC_ML;
