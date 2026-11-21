# food-delivery-data-warehouse

DL3004 Final Project - Eman Faisal (24L-2514), Mahnoor Fatima (24L-2533)

Implements the Phase 1 design (4 fact tables, 12 dimensions, SCD Type 2 on customer & restaurant) in **PostgreSQL**:

```
Source files -> project_staging (raw_* , stg_*) -> project_dw (dims + facts) -> project_reporting (Q1-Q12 views)
```

## 1. Data sources (Option A: public datasets)
| Dataset | Type | Used for |
|---|---|---|
| Kaggle "Food Delivery Dataset" (`data/raw/zomato_delivery_raw.csv`, 45,584 orders) | **public, real** | order ids, couriers, restaurants, coordinates, order/pick-up times, transit minutes, vehicle & city |
| Kaggle "Indian Food 101" (`data/raw/indian_food_101.csv`, 255 dishes) | **public, real** | dim_menu_item |
| CRM / RPP / DISP / OMS / MKT extracts (`data/source_extracts/`) | **simulated** (seed 42) | customers, order lines, payments, promotions, cancellations, restaurant attributes, availability |

No public dataset contains customers, payments, promotions or cancellations, so those source systems are simulated on top of the real orders
(`etl/generate_source_extracts.py`). Be transparent about this in your submission. Real vs simulated is documented in the Data Cleaning Report.
Assumption: `Time_taken (min)` = pick-up -> delivery time (evidence: rule Z17).

## 2. Setup in pgAdmin (step by step)
1. Install PostgreSQL 14+ and pgAdmin 4. Install Python 3.10+.
2. In pgAdmin: right-click **Databases -> Create -> Database...**, name it `swiftbite_dw`, Save.
3. (Optional) check the empty DB: right-click `swiftbite_dw` -> **Query Tool**.
4. In a terminal inside this folder:
   ```
   pip install -r requirements.txt
   set PGUSER=postgres  & set PGPASSWORD=<your password>  & set PGHOST=localhost & set PGPORT=5432 & set PGDATABASE=swiftbite_dw   (Windows cmd)
   export PGUSER=postgres PGPASSWORD=<your password> PGDATABASE=swiftbite_dw                                                          (macOS/Linux)
   ```
   (or edit the defaults in `config.py`).
5. Run the whole pipeline (about 2-5 minutes):
   ```
   python run_pipeline.py --reports
   ```
   This creates the three schemas, loads and cleans the data, builds dimensions + facts, the reporting views, runs the DQ checks and writes
   `reports/Data_Cleaning_Report.pdf` and `reports/Data_Quality_Report.pdf`.
   Use `--reuse-extracts` to skip regenerating the simulated CSVs.
6. In pgAdmin right-click **Schemas -> Refresh** under `swiftbite_dw`. You will see `project_staging`, `project_dw`, `project_reporting`.
7. Explore in the Query Tool, e.g.
   ```sql
   SELECT * FROM project_reporting.kpi_summary;
   SELECT * FROM project_reporting.q01_monthly_sales_trend;
   SELECT status, count(*) FROM project_dw.dq_result GROUP BY 1;          -- PASS / FAIL / INFO
   SELECT * FROM project_dw.dq_result WHERE status = 'FAIL';
   ```
8. ERD screenshot: pgAdmin -> right-click `project_dw` -> **ERD For Schema**.

Running scripts manually (instead of Python) is possible for the pure-SQL steps in order `00 -> 12`, but the CSV loads (COPY) and the
simulator are done by `run_pipeline.py`, so use the Python runner.

## 3. Phase 2 deliverables -> files
| Deliverable | File(s) |
|---|---|
| PostgreSQL database SQL scripts | `sql/00` ... `sql/12` |
| Staging schema SQL | `sql/01_staging_ddl.sql` |
| DW schema SQL | `sql/04_dw_ddl.sql` |
| ETL scripts (SQL/Python) | `run_pipeline.py`, `etl/*.py`, `sql/02`, `sql/03` |
| Data cleaning report (PDF) | `reports/Data_Cleaning_Report.pdf` (generated) |
| Dimension load scripts | `sql/05_load_dim_static.sql`, `06_load_dim_type1.sql`, `07_load_dim_scd2.sql` |
| Fact load scripts | `sql/08`, `09`, `10` |
| Data quality report (PDF) | `reports/Data_Quality_Report.pdf` (generated) |
| GitHub repository | `git init && git add . && git commit -m "Phase 2" && git remote add origin <url> && git push -u origin main` |

## 4. Marking-scheme map (40 marks)
* **Database implementation (10):** `04_dw_ddl.sql` - PK/FK/UNIQUE constraints, audit columns, indexes, 3 schemas.
* **ETL pipeline (15):** `run_pipeline.py`; raw -> stg cleaning (02, 03), dimension + fact loads, SCD1/SCD2, accumulating-snapshot upsert, periodic snapshot, factless fact, cleaning log.
* **Surrogate keys (5):** IDENTITY keys; business key -> surrogate key mapping in 05-10 (SCD2 picks the version valid on the order date); -1 Unknown / 0 No-promotion members.
* **Data quality (10):** `12_data_quality_checks.sql` (completeness, integrity, grain, reconciliation, business rules) -> `dq_result`.

## 5. Design notes / deviations from Phase 1 (state these in your report)
* TINYINT -> SMALLINT (PostgreSQL). Audit columns `etl_batch_id`, `etl_load_ts` added (BRD "Auditability").
* Vehicle type domain follows the data: Motorbike, Scooter, EV Scooter, Bicycle (Phase 1 listed "Car", absent in the public data).
* Restaurant `contract_status` is always Active (every restaurant has orders on all days); tier/price/commission changes drive the Type 2 history (3 monthly snapshots).
* Orders after midnight keep the date of their timestamp; snapshot days = days present in the extract (11 calendar days are missing from the public file).
* Snapshot counts are by order placed date.
* 50 restaurants have only zero coordinates in the public file -> their zones are the Unknown member (-1).
* Holiday list (`data/reference/ref_holiday.csv`) is a hand-typed reference of Indian public holidays - verify before relying on it.an public holidays - verify before relying on it.
