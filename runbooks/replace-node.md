# Replace a failed data node

Automation: `terraform apply` (same hostname), then `ansible/playbooks/replace_node.yml -e node=<host>`, then `scripts/migrate.sh` from the pipeline.

## Procedure

1. Terraform replaces the instance with the same hostname and macros; Ansible applies the role.
2. If the old replica's metadata remains in Keeper, run `SYSTEM DROP REPLICA 'ch-s05-r2' FROM ZKPATH '/clickhouse/tables/05/analytics/events_local'` from a healthy node.
3. Create tables from Git migrations; replication fetches all parts from the peer automatically.
4. Track `system.replication_queue` until empty; expect about 5-6 hours for 19 TB. Add the node back to chproxy only when `absolute_delay < 60`.
