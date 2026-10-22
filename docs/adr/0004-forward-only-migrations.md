# 0004. Forward-only, append-only SQL migrations applied by CI

- Status: Accepted
- Date: 2026-10-22

## Context

Schema and access changes on a petabyte cluster must be reviewed, reproducible and auditable. Down-migrations of ClickHouse DDL are rarely safe (dropped columns cannot be restored).

## Decision

Plain SQL files `clickhouse/migrations/V<NNN>__<name>.sql`, applied in order by `scripts/migrate.sh` as `svc_ci_deployer`, recorded with a SHA-256 checksum in `governance.schema_migrations`. Applied files are immutable (CI `migration-guard` + checksum check). Every statement is `ON CLUSTER '{cluster}'` and idempotent. Rollback = a new migration.

## Consequences

No ORM or migration framework dependency; developers write ClickHouse SQL directly. Long-running operations (backfills, heavy `ALTER ... UPDATE`) do not belong in migrations: run them as tracked jobs.

## Alternatives considered

- **Flyway / Liquibase / golang-migrate:** limited ClickHouse ON CLUSTER and macro support; one more JVM/binary in the pipeline.
- **Manual DDL by DBAs:** no review trail, drift between environments.
