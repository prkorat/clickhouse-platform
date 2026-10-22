# 0003. Masked DEFINER views instead of masking policies

- Status: Accepted
- Date: 2026-10-22

## Context

BI users need customer attributes without seeing raw PII. `CREATE MASKING POLICY` exists only in ClickHouse Cloud (25.12+).

## Decision

PII lives only in the `pii` database. BI reads `curated.v_customers_masked`, a `SQL SECURITY DEFINER` view owned by the non-login user `svc_view_owner`. Column grants restrict facts; `query_masking_rules` keep PII literals out of logs.

## Consequences

Every new masked attribute is a view change (migration). Tests in `tests/run.sh` assert analysts cannot read `pii.*` and that masking holds.

## Alternatives considered

- **Masking policies:** not available self-managed.
- **Masking in the BI tool:** bypassed by any direct client connection.
