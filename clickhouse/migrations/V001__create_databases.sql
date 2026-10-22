-- Database layout (design doc Section 4.7).
--   raw        landing tables, written by Kafka Connect / batch loaders, ETL-only
--   staging    transformation scratch space
--   analytics  conformed facts and dimensions (no direct PII; pseudonymous customer_id only)
--   curated    BI-facing facts, row policies + column grants, masked views
--   marts      aggregates for dashboards and APIs
--   support    tenant-scoped views for the support team
--   pii        the only place natural identifiers live; erasure touches only this database
--   governance tenant mapping, erasure requests, backup catalog, schema_migrations

CREATE DATABASE IF NOT EXISTS raw        ON CLUSTER '{cluster}';
CREATE DATABASE IF NOT EXISTS staging    ON CLUSTER '{cluster}';
CREATE DATABASE IF NOT EXISTS analytics  ON CLUSTER '{cluster}';
CREATE DATABASE IF NOT EXISTS curated    ON CLUSTER '{cluster}';
CREATE DATABASE IF NOT EXISTS marts      ON CLUSTER '{cluster}';
CREATE DATABASE IF NOT EXISTS support    ON CLUSTER '{cluster}';
CREATE DATABASE IF NOT EXISTS pii        ON CLUSTER '{cluster}';
CREATE DATABASE IF NOT EXISTS governance ON CLUSTER '{cluster}';
