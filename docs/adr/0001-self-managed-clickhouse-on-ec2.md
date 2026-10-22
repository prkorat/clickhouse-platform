# 0001. Self-managed ClickHouse OSS on EC2, 12 shards x 2 replicas

- Status: Accepted
- Date: 2026-10-22
- Deciders: Data platform lead, DBRE, Security architect

## Context

About 20 TB/day raw (2.5 TB compressed), 2 years retention (~1.8 PB compressed), 300 concurrent queries at peak, 99.95% availability, RPO 15 min / RTO 4 h, data residency and customer-managed-key requirements (design doc Section 0).

## Decision

Run ClickHouse OSS 25.x LTS on `i4i.16xlarge` (instance-store NVMe hot tier) in 3 AZs: 12 shards x 2 replicas, replicas of a shard in different AZs, `ReplicatedMergeTree` + `Distributed` sharded by `cityHash64(customer_id)`. Warm tier on gp3, cold tier on S3 via TTL moves.

## Consequences

- We own patching, upgrades, Keeper and backups: rolling-upgrade, replace-node and restore runbooks are mandatory.
- Instance store is lost on stop: replicas are the durability mechanism for the hot tier; never stop two replicas of a shard.
- Full control of encryption (encrypted disks, CMKs) and network (no public endpoints).

## Alternatives considered

- **ClickHouse Cloud:** less operational load and native masking/JWT, but customer-managed keys, private-only networking and residency controls required Enterprise tier and a separate security review; revisit yearly.
- **Kubernetes (Altinity operator):** same topology; rejected for now because the team's on-call has no EKS stateful experience and instance-store NVMe on EKS adds failure modes.
- **3 replicas per shard:** needed for 99.99%; 50% more NVMe cost for an SLO we do not need.
