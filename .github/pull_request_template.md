## What and why

<!-- One paragraph. Link the ticket. -->

## Type

- [ ] Schema migration (`clickhouse/migrations/`)
- [ ] Access model: roles, grants, profiles, quotas, row policies (`clickhouse/access/`)
- [ ] ClickHouse server config (`clickhouse/config.d/`, Ansible templates)
- [ ] Infrastructure (Terraform)
- [ ] Monitoring / runbooks
- [ ] CI/CD

## Checklist

- [ ] `make test` passes locally (or explain why it does not apply)
- [ ] Migrations: new file only (never edit an applied one); every DDL has `ON CLUSTER '{cluster}'` and `IF [NOT] EXISTS`
- [ ] New tables: `<name>_local` + `<name>` Distributed; TTL and `storage_policy` set; no PII outside the `pii` database
- [ ] Access: grants added for both `<table>` and `<table>_local`; removed grants have a matching line in `090_revokes.sql`
- [ ] Config needs a restart? Say so: it ships through the rolling-upgrade workflow, not the normal deploy
- [ ] Runbook updated if an alert, threshold or procedure changed

## Rollout and rollback

<!-- How it reaches prod (normal deploy / rolling restart) and how to undo it. Migrations are forward-only:
     the rollback for a schema change is a new migration. -->
