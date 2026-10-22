#!/usr/bin/env bash
# Nightly RBAC drift report (design doc Section 6.2): what exists in the cluster that Git does not define.
# Exit 0 = no drift, 2 = drift found (the drift workflow opens an issue and pages nobody).
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

ENV="${ENV:?set ENV}"
ACCESS_DIR="${REPO_ROOT}/clickhouse/access"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# Names Git declares (roles, users, profiles, quotas, row policies).
cat "${ACCESS_DIR}"/*.sql "${ACCESS_DIR}/env/${ENV}"/*.sql \
  | grep -oiE 'CREATE (ROLE|USER|SETTINGS PROFILE|QUOTA|ROW POLICY)( IF NOT EXISTS| OR REPLACE)? [a-z0-9_]+' \
  | awk '{print tolower($NF)}' | sort -u > "$tmp/git"

# Names the cluster has, excluding LDAP-authenticated humans (they come from AD groups) and built-ins.
ch_query "
  SELECT name FROM system.roles
  UNION ALL SELECT name FROM system.users WHERE storage != 'ldap' AND name != 'default'
  UNION ALL SELECT name FROM system.settings_profiles WHERE storage != 'users_xml'
  UNION ALL SELECT name FROM system.quotas WHERE storage != 'users_xml'
  UNION ALL SELECT short_name FROM system.row_policies" | sort -u > "$tmp/cluster"

extra="$(comm -13 "$tmp/git" "$tmp/cluster")"
missing="$(comm -23 "$tmp/git" "$tmp/cluster")"

# Full grant snapshot for the audit trail (Section 4.9: role assignment diffs).
ch_query "SHOW ACCESS" > "${SNAPSHOT_FILE:-$tmp/show_access.sql}"

if [ -z "$extra" ] && [ -z "$missing" ]; then
  log "no RBAC drift in ${ENV}"
  exit 0
fi
[ -n "$extra" ]   && { echo "## In cluster, not in Git (created out of band):"; echo "$extra"; }
[ -n "$missing" ] && { echo "## In Git, not in cluster (not yet applied):";   echo "$missing"; }
exit 2
