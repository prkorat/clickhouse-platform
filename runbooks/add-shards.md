# Add shards (capacity)

Change `shard_count` in `terraform/envs/<env>/variables.tf` and `ch_shard_count` in the inventory, regenerate `hosts.yml`, apply Terraform, run `site.yml`, then `scripts/migrate.sh` (ON CLUSTER DDL creates tables on the new shards).

## Procedure

1. Add the new shards to `remote_servers` with a higher `<weight>` (for example 3 versus 1) so new inserts favor them, which avoids moving existing data.
2. Return weights to 1 once disk usage is level across shards (TTL expiry does the rebalancing over the 30/90-day tiers).
3. If co-location by `customer_id` must be preserved, re-shard instead: create a new table on the new layout and backfill with `INSERT INTO ... SELECT` per partition.
