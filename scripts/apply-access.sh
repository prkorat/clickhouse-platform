#!/usr/bin/env bash
# Apply RBAC-as-code: roles, grants, workloads, profiles, quotas, row policies, users.
#
#   ENV=local|staging|prod scripts/apply-access.sh
#
# Shared files (clickhouse/access/*.sql) run first, then clickhouse/access/env/$ENV/*.sql.
# Every statement is idempotent (IF NOT EXISTS / OR REPLACE / GRANT), so this runs on every deploy.
# Run BEFORE migrations: definer views need their definer user to exist.
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

ENV="${ENV:?set ENV to local, staging or prod}"
ACCESS_DIR="${REPO_ROOT}/clickhouse/access"
[ -d "${ACCESS_DIR}/env/${ENV}" ] || fail "no access directory for ENV=${ENV}"

for f in "${ACCESS_DIR}"/*.sql "${ACCESS_DIR}/env/${ENV}"/*.sql; do
  log "access: ${f#"${REPO_ROOT}/"}"
  ch_exec < "$f"
done
log "access model applied for ${ENV}"
