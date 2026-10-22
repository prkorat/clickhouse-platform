# Too many parts / delayed inserts

Alerts: `ClickHouseTooManyParts*`, `ClickHouseRejectedInserts`, `ClickHouseDistributedQueueBacklog`.

## Procedure

1. Find the writer: `SELECT table, user, count() FROM system.part_log WHERE event_type = 'NewPart' AND event_time > now() - INTERVAL 10 MINUTE GROUP BY ALL ORDER BY 3 DESC`.
2. Fix the cause: batch size below 100k rows, too many partitions per insert, or `async_insert = 0` on a chatty client.
3. As a temporary measure, raise background merge pool threads on affected nodes; never raise `parts_to_throw_insert` as a fix.
