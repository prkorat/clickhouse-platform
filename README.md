# clickhouse-platform

Infrastructure, configuration, access model and schema for the enterprise ClickHouse analytics platform. Everything that reaches a ClickHouse environment comes from this repository through CI. Nobody applies changes by hand.

**Design reference:** [docs/design/platform-architecture-security-design.md](docs/design/platform-architecture-security-design.md) (architecture, security framework, DR plan, compliance mapping). **Developer rules:** [docs/best-practices.md](docs/best-practices.md). The design doc's section numbers appear in comments throughout the code.

```
Clients ──PrivateLink──▶ chproxy ──mTLS 9440/8443──▶ 12 shards × 2 replicas (3 AZs) ──TLS 9281──▶ Keeper ×3
Kafka ──Kafka Connect (exactly-once)──▶ raw.events ─MV─▶ analytics.events ─MV─▶ curated.events ─MV─▶ marts.*
Tiers: NVMe (30 d) ──TTL──▶ gp3 (90 d) ──TTL──▶ S3 SSE-KMS (2 y)      DR: us-west-2 via MirrorMaker 2
Backups: BACKUP ON CLUSTER ──▶ separate AWS account, S3 Object Lock (35 d), cross-region copy
```

## Quick start (local cluster)

Requirements: Docker with Compose v2, GNU Make, Bash (on Windows use WSL2 or Git Bash).

```bash
make up          # 2 shards x 2 replicas + 3 Keeper, same macros/policies/access model as prod
make db-init     # apply clickhouse/access (roles, grants, profiles, quotas, row policies) then migrations
make seed        # 10k sample events + PII rows + tenant mapping
make test        # fresh cluster + all of the above + security/data-flow assertions (what CI runs)

make client                                   # clickhouse-client as admin
make client CH_USER=dev_analyst CH_PASSWORD=dev   # see exactly what a BI analyst sees
```

Local ports bind to `127.0.0.1` only: HTTP `8123-8126`, native `9000-9003` (one per node). Local users: `admin/admin`, plus one per role with password `dev` (`dev_engineer`, `dev_etl`, `dev_analyst`, `dev_api`, `dev_auditor`).

## Repository layout

| Path | What lives there | Applied by |
| --- | --- | --- |
| `clickhouse/config.d/` | Static server config: TLS-only listeners, LDAP, access defaults, limits, log tables, PII masking in logs | Ansible (copied verbatim, policy-checked in CI) |
| `clickhouse/users.d/` | Logging defaults, `default` user lockdown | Ansible |
| `clickhouse/access/` | RBAC as code: roles, grants, workloads, settings profiles, quotas, row policies; `env/<env>/` users | `scripts/apply-access.sh` |
| `clickhouse/migrations/` | Forward-only schema migrations `V<NNN>__name.sql` | `scripts/migrate.sh` |
| `terraform/modules/` | security_groups, kms, clickhouse_nodes (data + Keeper), s3_tiers, backup_vault | Terraform |
| `terraform/envs/` | `prod-use1`, `dr-usw2`, `staging`, `backup-account` | CI with GitHub OIDC |
| `ansible/` | Roles: `os_hardening`, `clickhouse_server`, `clickhouse_keeper`, `vault_agent`, `otel_collector`; playbooks: `site`, `rolling_upgrade`, `replace_node`, `rotate_disk_key` | CI runner in the VPC, over SSM |
| `policies/` | OPA/Conftest rules for ClickHouse XML and Terraform plans, with unit tests | CI |
| `monitoring/` | Prometheus alert rules, Alertmanager routing, SQL-exporter queries, Grafana dashboards | ArgoCD |
| `argocd/` | GitOps apps for monitoring, chproxy, Kafka Connect | ArgoCD |
| `runbooks/` | On-call procedures, one per alert family | Humans |
| `local/` | Docker Compose dev cluster (local-only config, never deployed) | `make up` |
| `tests/` | Seed data and integration tests for the security model | `make test`, CI |
| `docs/` | Design document, ADRs | |

## How changes flow

1. Branch, change, `make test`, open a PR. CODEOWNERS adds the right reviewers (Security for access, config and policies).
2. **PR checks** (`.github/workflows/pr.yml`): gitleaks, Conftest on ClickHouse XML, OPA unit tests, `terraform fmt/validate`, Checkov + Trivy, ansible-lint, shellcheck, append-only migration guard, the full local-cluster integration test, and a production `terraform plan` checked against policy.
3. **Merge to `main`** (`.github/workflows/deploy.yml`): staging, then production behind a protected environment (required reviewers), then DR. Each environment runs Terraform, then Ansible (no restarts), then the access model, then migrations.
4. **Restarts and version upgrades** run separately: dispatch `deploy` with `rolling_target=replica_r2`, then `replica_r1` 24 h later, then `keeper`.
5. **Nightly drift** (`.github/workflows/drift.yml`): Terraform plan, Ansible `--check`, RBAC diff. Any drift opens an issue.

See [CONTRIBUTING.md](CONTRIBUTING.md) for the developer workflow (adding tables, grants and alerts).

## Before first production use

The framework encodes the design, but a few items depend on your environment and must be finished or verified in staging first:

- [ ] Replace placeholder account ids, ARNs, CIDRs, hostnames and `example-org` in `terraform/envs/*/terraform.tfvars`, `ansible/inventories/*/group_vars`, workflows and CODEOWNERS.
- [ ] Build the hardened AMI (Packer, CIS Level 1). Terraform expects its id.
- [ ] Vault: PKI roles `pki_int_clickhouse/issue/ch-server` and `ch-client`, AWS auth role per environment, and the KV secret `secret/clickhouse/<env>` (`cluster_secret`, `interserver_password`, `keeper_identity`, `disk_key_<n>`, `regulated_key_1`).
- [ ] Verify in staging that the `governance.user_tenants_dict` local source works when `tcp_port` is disabled (it authenticates as `svc_dict_reader`, `HOST LOCAL`). If it fails, switch the source to a named collection over 9440 with a client certificate.
- [ ] Define `svc_chproxy_bi` / `svc_chproxy_api` (alternating-password rotation) and finish the chproxy, Kafka Connect and monitoring manifests in `argocd/manifests/`.
- [ ] Self-hosted GitHub runner `clickhouse-ops` inside the VPC (SSM + PrivateLink access), and the `production` environment with required reviewers.
- [ ] Set up the break-glass users (`admin_breakglass_*`) out of band from Vault. They are deliberately not in Git.

## Support

- Platform on-call: `#data-platform` · runbooks in [runbooks/](runbooks/)
- Access requests: open an "Access request" issue (roles are granted through AD groups `CH-Prod-<role>`)
- Security issues: see [SECURITY.md](SECURITY.md)
