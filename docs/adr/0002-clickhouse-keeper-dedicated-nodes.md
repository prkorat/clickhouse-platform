# 0002. Dedicated 3-node ClickHouse Keeper

- Status: Accepted
- Date: 2026-10-22

## Context

Replication and ON CLUSTER DDL depend on a coordination quorum. Losing it makes every replicated table read-only.

## Decision

ClickHouse Keeper (not ZooKeeper), 3 dedicated `m7i.2xlarge` nodes, one per AZ, TLS on client (9281) and Raft (9234) ports, digest ACLs, dedicated gp3 log volume.

## Consequences

Survives one node or one AZ. Two-node loss requires `--force-recovery` (runbooks/keeper-quorum-loss.md). Keeper is upgraded last in every rolling upgrade.

## Alternatives considered

- **ZooKeeper:** JVM tuning and a second technology to operate; Keeper is wire-compatible and is the ClickHouse default.
- **Co-located Keeper on data nodes:** merges and heavy queries starve Keeper of CPU and fsync bandwidth, causing session expiry and read-only replicas.
- **5 Keeper nodes:** tolerates two failures but only 3 AZs exist, so an AZ loss could still take two; adds write latency.
