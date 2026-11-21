-- 00_create_schemas.sql : three-layer architecture
DROP SCHEMA IF EXISTS project_reporting CASCADE;
DROP SCHEMA IF EXISTS project_dw        CASCADE;
DROP SCHEMA IF EXISTS project_staging   CASCADE;

CREATE SCHEMA project_staging;
CREATE SCHEMA project_dw;
CREATE SCHEMA project_reporting;

COMMENT ON SCHEMA project_staging   IS 'Landing (raw_*) and cleaned (stg_*) copies of the source files.';
COMMENT ON SCHEMA project_dw        IS 'Dimensional model: 12 dimensions + 4 fact tables with surrogate keys.';
COMMENT ON SCHEMA project_reporting IS 'Business-facing views answering Q1-Q12 and the KPIs.';