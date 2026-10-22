# Region failover to us-west-2

DR capacity: `terraform/envs/dr-usw2` (`replicas_per_shard = 1`; raise to 2 during failover). Degraded quota: `quota_bi_degraded` in `clickhouse/access/050_quotas.sql`:

```sql
ALTER QUOTA quota_bi_degraded TO role_bi_analyst;
ALTER QUOTA quota_bi TO NONE;   -- revert both after failback
```

## Procedure

1. **Declare** (incident commander + data platform owner): the primary region has been unavailable or degraded for over 30 minutes with no ETA.
2. **Freeze writes** to the primary if any part is still reachable (stop Kafka Connect in us-east-1) to avoid split ingestion.
3. **Confirm DR currency:** DR consumer lag below 5 minutes; record the last offsets applied per topic.
4. **Switch traffic:** point the Route 53 private record `clickhouse.prod.internal` at the DR chproxy NLB (TTL 60 s) and switch PrivateLink consumers to the DR endpoint service.
5. **Protect capacity:** DR runs one replica per shard, so apply the stricter BI quotas (`quota_bi_degraded`) and suspend ad-hoc workloads. Add a second replica per shard (Terraform `replicas_per_shard = 2`, about 6 h to sync).
6. **Validate:** synthetic checks green, row counts for the last hour match the Kafka offsets, top 10 dashboards load.
7. **Fail back** later: rebuild or resync us-east-1 as the standby from the DR region (MirrorMaker in reverse), then repeat this runbook in the opposite direction in a planned window.
