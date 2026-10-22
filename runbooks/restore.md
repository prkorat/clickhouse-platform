# Restore after accidental drop, corruption or ransomware

Backups: `scripts/backup.sh`, catalog `governance.backup_catalog`. RPO/RTO per scenario: design doc Section 7.2.

## Procedure

1. **Contain:** for suspected compromise, disable the actor in AD (or `DROP USER` for SQL users), rotate the cluster secret and break-glass passwords, and preserve `query_log` and CloudTrail evidence.
2. **Pick the recovery point** from `governance.backup_catalog`: the last backup before the incident's first harmful query (found in `query_log`).
3. **Restore into a side table or a clean cluster**, never over live data first: `RESTORE TABLE ... AS ..._restored`.
4. **Replay** Kafka from the offsets stored with that backup up to the incident time. For corruption caused by a bad deploy that is already fixed, replay up to now.
5. **Validate** counts and checksums against the source, then swap with `EXCHANGE TABLES analytics.events_local AND analytics.events_local_restored ON CLUSTER prod`.
6. **Re-apply** the GDPR suppression list and confirm row policies and grants are unchanged (`SHOW ACCESS` diff against Git).
