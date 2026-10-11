# Workers' Comp Litigation Model in Snowflake

An end-to-end data science project: predict, **at claim intake**, whether a workers' compensation claim
will get an attorney or representative. Then train, register and deploy the model **inside Snowflake**.
Everything runs on a Snowflake free trial.

- **Data:** NY Workers' Compensation Board (WCB), [Assembled Workers' Compensation Claims: Beginning 2000](https://data.ny.gov/d/jshw-gkgu) (public, openly licensed)
- **Target:** `IS_LITIGATED` = 1 when the claim's *Attorney/Representative* flag is `Y`
- **Model:** XGBoost in a scikit-learn pipeline, compared against a logistic regression baseline
- **Deployment:** Snowflake Model Registry, callable from SQL and Python, with a scheduled batch-scoring Task

```
 data.ny.gov ──(your laptop)──► Parquet ──► @WCB_STAGE ──► RAW.NY_WCB_CLAIMS
                                                             │
                                          ANALYTICS.CLAIM_FEATURES (one view for training AND scoring)
                                                  │                         │
                                   Notebook: train + evaluate        SCORING.SCORE_NEW_CLAIMS() ◄── daily TASK
                                                  │                         │
                                   MODELS.WC_LITIGATION_XGB ───────►  SCORING.CLAIM_LITIGATION_SCORES
                                       (Model Registry)
```

## Repository layout

| Path | What it does |
|---|---|
| `sql/01_setup.sql` | Warehouse, database, schemas, stage and a **resource monitor** (credit cap) |
| `sql/01b_notebook_role.sql` | `WC_ML_ROLE`, the non-admin role the notebooks run as |
| `scripts/download_ny_wcb.py` | Downloads claims for chosen years from data.ny.gov into Parquet files |
| `sql/02_load_raw.sql` | Loads the Parquet files into `WC_ML.RAW.NY_WCB_CLAIMS` |
| `sql/03_features.sql` | Feature view. All cleaning and leakage rules live here |
| `notebooks/01_explore_claims.ipynb` | Exploratory data analysis (EDA) |
| `notebooks/02_train_and_register.ipynb` | Time-based split, baseline + XGBoost, evaluation, Model Registry |
| `deploy/04_deploy_scoring.sql` | SQL inference, batch scoring procedure, scheduled Task, monitoring query |
| `tests/` | Unit tests for the download script |

## Step by step

### 1. Create a Snowflake trial account
1. Sign up at <https://signup.snowflake.com>. The trial lasts **30 days** and includes **$400 in credits**.
2. Choose **Enterprise** edition (the trial costs nothing either way, and some ML features need Enterprise).
   Pick a major region such as AWS US East or US West.
3. Python packages come from Snowflake's Anaconda channel. If a notebook complains about Anaconda terms,
   go to **Admin → Terms** in Snowsight (the Snowflake web interface) and accept them.

> Tip: do steps 2–3 (downloading the data) **before** signing up so your 30 days aren't spent waiting.

### 2. Download the data (on your computer)
```bash
python -m venv .venv && source .venv/bin/activate     # Windows: .venv\Scripts\activate
pip install -r requirements.txt
python scripts/download_ny_wcb.py --start-year 2017 --end-year 2023
```
This writes `data/ny_wcb/part-XXXX.parquet` files of 50,000 claims each. The `data/` folder is git-ignored.
If the script warns about missing columns, the dataset's column names have changed. Update the
matching names in `sql/03_features.sql`.

Optional: a free [Socrata app token](https://data.ny.gov/profile/edit/developer_settings) in the
`SOCRATA_APP_TOKEN` environment variable makes throttling less likely.

### 3. Set up Snowflake and load the data
1. In Snowsight open **Projects → Worksheets → + SQL worksheet**, paste `sql/01_setup.sql`, and run all.
2. Upload the Parquet files: **Data → Databases → WC_ML → RAW → Stages → WCB_STAGE → + Files**, then select every
   file in `data/ny_wcb/`.
   *(Command-line alternative with the [Snowflake CLI](https://docs.snowflake.com/en/developer-guide/snowflake-cli/index):
   `snow stage copy "data/ny_wcb/*.parquet" @WC_ML.RAW.WCB_STAGE`)*
3. Run `sql/02_load_raw.sql`, then `sql/03_features.sql`, in a worksheet.
4. Run `sql/01b_notebook_role.sql`. It creates `WC_ML_ROLE`, which the notebooks run as.

### 4. Explore and train in Snowflake Notebooks (Workspaces)
Notebooks live in **Workspaces** and run on *Container Runtime*. Python runs on a small personal machine
Snowflake calls a **notebook service**, and SQL runs on your warehouse.
Snowflake won't run notebooks owned by ACCOUNTADMIN, so switch roles first.

1. **Switch role:** click your name (bottom left) → **Switch role** → `WC_ML_ROLE`.
2. **Add the notebooks:** **Projects → Workspaces**, then **+ Add new → Upload files** (or drag the files into
   the file panel). Upload both `.ipynb` files from `notebooks/`.
3. **Connect compute:** open `01_explore_claims.ipynb` and click **Connect**. The **Connect your notebook**
   dialog opens.
   - Service name, Artifact repositories (`SNOWFLAKE.SNOWPARK.PYPI_SHARED_REPOSITORY`) and the
     CPU / Python 3.12 runtime on `SYSTEM_COMPUTE_POOL_CPU`: keep the defaults
   - Enable distributed compute: leave it off
   - **Service settings → idle timeout: change it from the 24-hour default to about 1 hour.** The service bills
     while it runs, and the resource monitor doesn't cover it.
   - There's no warehouse field here. The notebooks switch to `WC_ML_WH` in their first cell.

   Click **Create and connect**. Both notebooks can share this one service.
4. **Run** `01_explore_claims`, then `02_train_and_register`. The first cell of each should show `WC_ML_ROLE`
   and `WC_ML_WH`. `snowflake-ml-python`, `scikit-learn` and `xgboost` come preinstalled, and the training
   notebook prints their versions. The training notebook registers `WC_ML.MODELS.WC_LITIGATION_XGB`.
5. **When you're done,** suspend the service from the **Connect** menu, or let the idle timeout stop it.

### 5. Deploy
Run `deploy/04_deploy_scoring.sql` in a worksheet, one section at a time. It covers:
- **A.** Calling the model from SQL: `WITH mv AS MODEL ... SELECT mv!PREDICT_PROBA(...)`
- **B.** A stored procedure that scores every claim not yet scored and writes `SCORING.CLAIM_LITIGATION_SCORES`
- **C.** A daily **Task**. It's created *suspended*, so it uses no credits until you `RESUME` it.
- **D.** A decile table comparing predicted and actual litigation rates for monitoring

## Modeling choices worth knowing

- **Leakage:** only intake-time information is used. Hearing dates, IME-4 (Independent Medical Examination)
  counts, claim status, *Claim Injury Type*, *Average Weekly Wage* and similar fields come later, often
  *because* an attorney is involved. Including them would look great in testing and fail in production.
  `sql/03_features.sql` lists the excluded fields.
- **Label maturity:** attorneys can join a claim years after it opens, so recent claims look less litigated.
  Training uses claims assembled 2017–2020, validation 2021 and test 2022. Claims from 2023 on act as
  "new" claims for the deployed scorer.
- **Time-based split** instead of a random one, so the test year imitates scoring future claims.
- **Metrics:** ROC-AUC (receiver operating characteristic, area under the curve), PR-AUC
  (precision-recall area under the curve), Brier score (probability accuracy) and lift by risk decile.
  The decile view is the most practical one for claims triage.

## Keeping costs down
- The warehouse is X-Small (1 credit per hour, billed per second) and suspends after 60 idle seconds.
- `WC_ML_MONITOR` notifies at 30 credits and suspends the warehouse at 40.
- Resource monitors only watch **warehouses**. The notebook service runs on a compute pool, which the monitor
  doesn't cover, so keep its idle timeout short and suspend it when you finish.
- Use **Admin → Cost Management** in Snowsight to see what you've spent.

## Run the local tests
```bash
pytest -q
```

## Next: the Kaggle "Actuarial Loss Prediction" data
A planned second model predicts **ultimate incurred claim cost** from about 90,000 synthetic workers' comp
claims, including a free-text claim description. The competition closed in 2021, but you can still
download the data after joining it on Kaggle and accepting its rules. Its license doesn't allow
committing the data here, so it will use the same local-download pattern, and the data stays git-ignored.
