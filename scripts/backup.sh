#!/usr/bin/env bash
# Native BACKUP ON CLUSTER to the backup account (design doc Section 7.1).
#
#   BACKUP_KIND=full|incremental BACKUP_BUCKET_URL=https://ch-backup-prod-use1.s3.us-east-1.amazonaws.com/prod/daily \
#     scripts/backup.sh
#
# Prefixes match the bucket lifecycle (terraform/modules/backup_vault): prod/daily/ expires after the
# 35-day lock; the first full of each month is also written to prod/monthly/ and kept 12 months.
#
# Full weekly (Sunday 01:00 UTC) starts a new chain; incrementals daily on top of the previous backup.
# Credentials come from the instance role. Object Lock on the bucket makes every backup immutable for 35 days.
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

KIND="${BACKUP_KIND:?full or incremental}"
BUCKET="${BACKUP_BUCKET_URL:?}"
DATABASES="${BACKUP_DATABASES:-DATABASE analytics, DATABASE curated, DATABASE marts, DATABASE pii, DATABASE governance}"
ID="${KIND}-$(date -u +%Y-%m-%dT%H%M)"
TARGET="${BUCKET}/${ID}/"

settings=""
base=""
if [ "$KIND" = "incremental" ]; then
  base="$(ch_query "SELECT backup_url FROM governance.backup_catalog
                    WHERE status = 'BACKUP_CREATED' ORDER BY started_at DESC LIMIT 1")"
  [ -n "$base" ] || fail "no successful previous backup to use as base; run a full backup first"
  settings="SETTINGS base_backup = S3('${base}')"
fi

log "backup ${ID} -> ${TARGET} (base: ${base:-none})"
started="$(date -u '+%F %T')"
status="$(ch_query "BACKUP ${DATABASES} ON CLUSTER '{cluster}' TO S3('${TARGET}') ${settings}" | cut -f2)"

ch_query "INSERT INTO governance.backup_catalog (backup_id, backup_url, backup_kind, base_backup, started_at, finished_at, status)
          VALUES ('${ID}', '${TARGET}', '${KIND}', '${base}', '${started}', now(), '${status}')" >/dev/null

[ "$status" = "BACKUP_CREATED" ] || fail "backup ${ID} finished with status ${status}"
log "backup ${ID} complete"
