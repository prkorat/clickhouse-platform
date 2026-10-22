#!/usr/bin/env bash
# Forward-only schema migrations (design doc Section 6.2).
#
#   scripts/migrate.sh            apply pending migrations
#   scripts/migrate.sh status     list applied / pending
#
# Rules:
#   * Files are clickhouse/migrations/V<NNN>__<description>.sql, applied in version order.
#   * Every DDL statement uses ON CLUSTER '{cluster}' and IF NOT EXISTS, so a re-run is harmless.
#   * Never edit an applied file: the checksum check fails the pipeline. Write a new version instead.
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

MIGRATIONS_DIR="${REPO_ROOT}/clickhouse/migrations"
CMD="${1:-apply}"

bootstrap() {
  ch_exec <<'SQL'
CREATE DATABASE IF NOT EXISTS governance ON CLUSTER '{cluster}';
CREATE TABLE IF NOT EXISTS governance.schema_migrations ON CLUSTER '{cluster}'
(
  version     UInt32,
  name        String,
  checksum    FixedString(64),
  applied_by  String DEFAULT currentUser(),
  applied_at  DateTime DEFAULT now(),
  git_sha     String
)
ENGINE = ReplicatedReplacingMergeTree('/clickhouse/tables/all/{database}/{table}', '{replica}', applied_at)
ORDER BY version;
SQL
}

applied_checksum() {
  ch_query "SELECT checksum FROM governance.schema_migrations FINAL WHERE version = $1"
}

bootstrap

shopt -s nullglob
files=("${MIGRATIONS_DIR}"/V*__*.sql)
[ ${#files[@]} -gt 0 ] || fail "no migrations in ${MIGRATIONS_DIR}"

pending=0
for f in $(printf '%s\n' "${files[@]}" | sort -V); do
  base="$(basename "$f")"
  version="$(echo "$base" | sed -E 's/^V0*([0-9]+)__.*/\1/')"
  sum="$(sha256sum "$f" | cut -d' ' -f1)"
  existing="$(applied_checksum "$version")"

  if [ -n "$existing" ]; then
    [ "$existing" = "$sum" ] || fail "${base} was modified after it was applied (checksum mismatch). Add a new migration instead."
    [ "$CMD" = "status" ] && echo "applied  ${base}"
    continue
  fi

  pending=$((pending + 1))
  if [ "$CMD" = "status" ]; then
    echo "PENDING  ${base}"
    continue
  fi

  log "applying ${base}"
  ch_exec < "$f"
  ch_query "INSERT INTO governance.schema_migrations (version, name, checksum, git_sha)
            VALUES (${version}, '${base}', '${sum}', '${GIT_SHA:-$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)}')" >/dev/null
done

[ "$CMD" = "status" ] || log "done (${pending} applied)"
