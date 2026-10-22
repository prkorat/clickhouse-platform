# Keeper quorum loss

Alerts: `KeeperQuorumDegraded`, `ClickHouseReadonlyReplica`, `KeeperLatencyHigh`.

## Procedure

**Symptoms:** `ReadonlyReplica > 0` on many nodes; inserts fail with `TABLE_IS_READ_ONLY` or Keeper session errors; SELECTs still work.

1. Check each Keeper: `echo mntr | openssl s_client -quiet -connect keeper-N.ch.prod.internal:9281 -cert ... -key ...` and confirm `zk_server_state`. Check disk space and log-volume latency first; a full snapshot disk is the most common cause.
2. **One node down, quorum intact:** no client impact. Replace the node; it rejoins and syncs from the leader.
3. **Two nodes down but recoverable** (process crash, disk full): fix the cause and restart them. Quorum returns and replicas leave read-only within seconds; ingest backs up in Kafka and then drains.
4. **Two nodes permanently lost:** on the survivor, stop Keeper and restart it once with `clickhouse-keeper --force-recovery`. Provision two new nodes with the same `raft_configuration`, start them, and confirm `zk_synced_followers = 2`.
5. **All Keeper data lost:** start a fresh 3-node Keeper, then on one replica per shard run `SYSTEM RESTORE REPLICA analytics.events_local` for every replicated table. ClickHouse rebuilds the Keeper metadata from local parts; the second replica re-attaches with the same command.
6. **Verify:** `SELECT count() FROM clusterAllReplicas('prod', system.replicas) WHERE is_readonly` returns 0, then Kafka lag drains below 5 minutes.
7. **Post-incident:** record time-to-quorum; any recovery over 30 minutes becomes a problem ticket.
