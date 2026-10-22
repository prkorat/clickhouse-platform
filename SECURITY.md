# Security

## Reporting

Report suspected vulnerabilities, leaked credentials or unexpected data access to the Security team privately (security on-call / `#security-incidents`). Don't open a public issue. If a secret was committed, rotate it immediately (Vault / Secrets Manager), then tell Security.

## Controls this repository enforces

| Control | Where |
| --- | --- |
| No plaintext listeners (8123, 9000, 9009, 9181, 9004, 9005) and mutual TLS everywhere | `clickhouse/config.d/10-network-tls.xml`, `policies/clickhouse/network_tls.rego` |
| Default-deny row access, grants required for `system` tables | `clickhouse/config.d/20-access.xml`, `policies/clickhouse/access.rego` |
| Least-privilege roles, column grants, masked views, tenant row policies | `clickhouse/access/`, `clickhouse/migrations/V007__*.sql` |
| Per-class resource limits and quotas | `clickhouse/access/040_*.sql`, `050_*.sql`, `030_workloads.sql` |
| Audit logs on cluster (30-90 days) and exported to an immutable archive | `clickhouse/config.d/40-logs.xml` |
| PII redaction in logs | `clickhouse/config.d/60-query-masking.xml` |
| Encrypted disks (AES-256), SSE-KMS with CMKs, key rotation | `ansible/roles/clickhouse_server/templates/30-storage.xml.j2`, `terraform/modules/kms`, `ansible/playbooks/rotate_disk_key.yml` |
| No SSH, IMDSv2 only, SG-to-SG rules only, no 0.0.0.0/0 | `terraform/modules/*`, `policies/terraform/guardrails.rego` |
| Immutable backups in a separate account | `terraform/modules/backup_vault`, `terraform/envs/backup-account` |
| Secrets never in Git: Vault Agent renders them to tmpfs at boot | `ansible/roles/vault_agent` |
| Secret scanning, IaC scanning, two-person review | `.pre-commit-config.yaml`, `.github/workflows/pr.yml`, `.github/CODEOWNERS` |

The integration tests (`tests/run.sh`) assert these behaviours against a real cluster on every PR. If you change a control, change its test.
