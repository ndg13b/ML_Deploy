-- =====================================================================
-- 01b_notebook_role.sql — a working role for Snowflake Notebooks.
-- Run once as ACCOUNTADMIN, after 01_setup.sql.
--
-- Notebooks in Workspaces run on Container Runtime, and Snowflake refuses
-- to run notebooks created or owned by ACCOUNTADMIN, ORGADMIN or
-- SECURITYADMIN. So the notebooks run as WC_ML_ROLE instead.
-- =====================================================================
USE ROLE ACCOUNTADMIN;

CREATE ROLE IF NOT EXISTS WC_ML_ROLE;

-- Give the role to you, and to SYSADMIN so admin roles can still see what it creates
-- (SYSADMIN rolls up to ACCOUNTADMIN, so the deploy SQL can use the registered model).
-- The double quotes make the name match exactly. Without them IDENTIFIER uppercases it,
-- which fails for user names stored in lowercase (common for trial sign-ups).
SET MY_USER = '"' || CURRENT_USER() || '"';
GRANT ROLE WC_ML_ROLE TO USER IDENTIFIER($MY_USER);
GRANT ROLE WC_ML_ROLE TO ROLE SYSADMIN;

-- Query warehouse: SQL and Snowpark queries from the notebook run here.
GRANT USAGE, OPERATE, MONITOR ON WAREHOUSE WC_ML_WH TO ROLE WC_ML_ROLE;

-- Read access to the data, including objects created later.
GRANT USAGE ON DATABASE WC_ML TO ROLE WC_ML_ROLE;
GRANT USAGE ON ALL SCHEMAS IN DATABASE WC_ML TO ROLE WC_ML_ROLE;
GRANT SELECT ON ALL TABLES IN DATABASE WC_ML TO ROLE WC_ML_ROLE;
GRANT SELECT ON ALL VIEWS IN DATABASE WC_ML TO ROLE WC_ML_ROLE;
GRANT SELECT ON FUTURE TABLES IN DATABASE WC_ML TO ROLE WC_ML_ROLE;
GRANT SELECT ON FUTURE VIEWS IN DATABASE WC_ML TO ROLE WC_ML_ROLE;

-- Model Registry: the training notebook creates the model in WC_ML.MODELS.
GRANT CREATE MODEL, CREATE STAGE, CREATE TABLE, CREATE FUNCTION ON SCHEMA WC_ML.MODELS TO ROLE WC_ML_ROLE;

-- Notebook compute: every account has a system CPU pool that PUBLIC can use by default.
-- If "Create service" later says the role can't use the pool, run this line:
-- GRANT USAGE ON COMPUTE POOL SYSTEM_COMPUTE_POOL_CPU TO ROLE WC_ML_ROLE;
SHOW COMPUTE POOLS;

-- Check the result
SHOW GRANTS TO ROLE WC_ML_ROLE;
