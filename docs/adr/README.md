# Architecture Decision Records

One file per decision that is expensive to reverse. Copy `0000-template.md`, take the next number, open a PR.
Status moves Proposed -> Accepted -> (Superseded by NNNN). Never edit an accepted ADR's decision; supersede it.

| ADR | Decision | Status |
| --- | --- | --- |
| [0001](0001-self-managed-clickhouse-on-ec2.md) | Self-managed ClickHouse OSS on EC2, 12 shards x 2 replicas | Accepted |
| [0002](0002-clickhouse-keeper-dedicated-nodes.md) | Dedicated 3-node ClickHouse Keeper | Accepted |
| [0003](0003-masked-views-for-pii.md) | Masked DEFINER views instead of masking policies | Accepted |
| [0004](0004-forward-only-migrations.md) | Forward-only, append-only SQL migrations applied by CI | Accepted |
