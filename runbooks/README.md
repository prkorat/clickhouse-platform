# Runbooks

Every alert in `monitoring/alerts/clickhouse.rules.yaml` links to one of these. If you get paged and the runbook is wrong or missing a step, fix it in the same week (PR to this folder).

| Runbook | When |
| --- | --- |
| [rolling-upgrade.md](rolling-upgrade.md) | Version bump, config change that needs a restart |
| [replace-node.md](replace-node.md) | Instance or disk failure, `ClickHouseNodeDown` that does not recover |
| [add-shards.md](add-shards.md) | Capacity: hot disk trending above 70% |
| [too-many-parts.md](too-many-parts.md) | `ClickHouseTooManyParts*`, `ClickHouseRejectedInserts`, distributed queue backlog |
| [stuck-mutation.md](stuck-mutation.md) | `ClickHouseStuckMutation`, runaway queries |
| [keeper-quorum-loss.md](keeper-quorum-loss.md) | `KeeperQuorumDegraded`, `ClickHouseReadonlyReplica` |
| [region-failover.md](region-failover.md) | Primary region unavailable for more than 30 min |
| [restore.md](restore.md) | Accidental drop, corruption, ransomware |

All SQL below runs as a DBA (`role_dba`) through chproxy unless stated otherwise.

## Triage

1. Scope it: one node, one shard, or everything? `SELECT hostName(), uptime() FROM clusterAllReplicas('prod', system.one)`.
2. Errors right now: `SELECT exception_code, count() FROM clusterAllReplicas('prod', system.query_log) WHERE type != 'QueryFinish' AND event_time > now() - INTERVAL 10 MINUTE GROUP BY 1 ORDER BY 2 DESC`.
3. Keeper healthy? If many replicas are read-only, go to [keeper-quorum-loss.md](keeper-quorum-loss.md).
4. Was there a deploy? Check the last `deploy` workflow run and `governance.schema_migrations`.

## Replication lag

```sql
SELECT database, table, replica_name, absolute_delay, queue_size, inserts_in_queue, merges_in_queue, last_queue_update_exception
FROM clusterAllReplicas('prod', system.replicas) WHERE absolute_delay > 60 ORDER BY absolute_delay DESC;

SELECT type, count(), any(last_exception) FROM system.replication_queue GROUP BY type;
```

Common causes: a lagging node fetching after a restart (wait), network limits on interserver 9010, or a failing part fetch (`last_exception`). `SYSTEM RESTART REPLICA db.table` resets a stuck queue.

## Ingestion lag

Kafka Connect consumer lag above 15 minutes puts the 15-minute RPO at risk. Check connector task status in Kafka Connect, then [too-many-parts.md](too-many-parts.md) (ClickHouse back-pressure is the most common cause), then the `etl` quota (`SELECT * FROM system.quotas_usage`).

## Memory

```sql
SELECT query_id, user, formatReadableSize(memory_usage), elapsed, left(query, 120)
FROM clusterAllReplicas('prod', system.processes) ORDER BY memory_usage DESC LIMIT 10;
```

Kill the offender (`KILL QUERY WHERE query_id = '...'`) and fix its settings profile in `clickhouse/access/040_settings_profiles.sql`.

## Concurrency

Near `max_concurrent_queries` (400): find the user flooding (`SELECT user, count() FROM clusterAllReplicas('prod', system.processes) GROUP BY user ORDER BY 2 DESC`). Lower its `max_concurrent_queries_for_user` or quota in Git; chproxy per-user limits apply first.

## Disk

Hot volume below 15% free: check TTL moves are running (`SELECT * FROM system.moves`) and the policy `move_factor`. Short-term: `ALTER TABLE ... MOVE PARTITION ... TO VOLUME 'warm'` for the oldest hot partitions. Long-term: [add-shards.md](add-shards.md).

## TLS

Certificates are 30-day (servers) and renewed by Vault Agent. If expiry is under 3 days, renewal is failing: `systemctl status vault-agent` and `journalctl -u vault-agent` on the node (via SSM). Check Vault PKI role and the node's AWS auth role.

## Break-glass

Any `admin_breakglass_*` login pages Security. If it was not an approved incident action, treat it as a compromise: disable the user (`ALTER USER admin_breakglass_1 HOST NONE`), rotate its password in Vault, and preserve `system.session_log` and `system.query_log`.
