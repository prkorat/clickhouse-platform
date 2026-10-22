# Contributing

Read [docs/best-practices.md](docs/best-practices.md) first: reviewers apply it to every PR.

## Setup

```bash
pip install pre-commit && pre-commit install   # gitleaks, terraform fmt, shellcheck, YAML/XML checks on commit
make up && make db-init && make seed            # local cluster with sample data
```

Optional tools for running CI checks locally: `terraform` 1.9+, `conftest` 0.56+, `ansible-lint`, `shellcheck`. `make lint` and `make policy-test` run them.

## Add a table

1. `make migration NAME=create_orders`. This creates the next `clickhouse/migrations/V<NNN>__create_orders.sql` from a template with the reviewer checklist.
2. Write the DDL. The rules (CI enforces the first two):
   - Every DDL statement has `ON CLUSTER '{cluster}'` and `IF NOT EXISTS` / `IF EXISTS`.
   - Never edit or rename a migration after it has been merged. Write a new one.
   - Sharded data: `<name>_local` (`ReplicatedMergeTree('/clickhouse/tables/{shard}/{database}/{table}', '{replica}')`) plus `<name>` (`Distributed('{cluster}', db, <name>_local, cityHash64(customer_id))`). Use the same sharding key as the tables you join with.
   - Small reference tables on every node: path `'/clickhouse/tables/all/{database}/{table}'`, no Distributed table.
   - `PARTITION BY` daily or monthly, never finer. `ORDER BY` starts with the column most queries filter on.
   - Set TTL and `storage_policy = 'tiered'`. Use `'tiered_regulated'` for PII, PCI or PHI.
   - Natural identifiers (email, phone, name, IP) go only in the `pii` database. Facts carry `customer_id`.
3. Add grants in `clickhouse/access/020_grants.sql` for **both** `<name>` and `<name>_local`. The shard-side query runs as the original user.
4. If the table has a row policy, add an `allow_all` policy for engineering roles too. The cluster is default-deny (`users_without_row_policies_can_read_rows = false`).
5. `make reset && make test`, then check it as the target role: `make client CH_USER=dev_analyst CH_PASSWORD=dev`.

## Change access (roles, grants, quotas, profiles)

- Everything is in `clickhouse/access/`. Files are applied in name order on every deploy and must stay idempotent (`IF NOT EXISTS`, `OR REPLACE`, `GRANT`).
- Removing a `GRANT` line does not revoke it. Add the `REVOKE` to `090_revokes.sql`.
- People never get grants directly. They get roles through AD groups (`CH-Prod-<role>`), so don't add human users here.
- Raising a limit in `040_settings_profiles.sql` or `050_quotas.sql` needs a reason in the PR (which workload, what evidence).

## Change server configuration

- Static XML in `clickhouse/config.d/` is checked by `policies/clickhouse/*.rego`. Plaintext ports, a relaxed `verificationMode`, literal passwords and an allow-by-default row policy setting all fail CI.
- Per-node or per-environment values go in the Ansible templates (`ansible/roles/clickhouse_server/templates/`).
- Most settings hot-reload. Listener, storage and package changes need a restart, so mention it in the PR. It ships through the rolling-upgrade workflow.

## Add an alert

Add the rule to `monitoring/alerts/clickhouse.rules.yaml` with `severity`, `team` and a `runbook` annotation that points to a real section in `runbooks/`. An alert without a runbook will not be approved.

## Commit and PR conventions

- Small PRs, one concern each (a migration and its grants belong together).
- Commit messages: imperative mood, with the reason (`Add orders table for checkout analytics`).
- Fill in the PR template's rollout and rollback section.

## Never commit

Credentials, certificates, private keys, `terraform.tfvars`, real customer data or query results. gitleaks blocks most of these. If one gets through, rotate the secret first, then clean the history.
