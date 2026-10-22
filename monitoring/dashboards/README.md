# Grafana dashboards

Dashboards are provisioned by ArgoCD (`argocd/applications/monitoring.yaml`) from JSON in this folder. Build each dashboard in Grafana, export JSON (Share > Export > "Export for sharing externally"), and commit it here.

| File | Audience | Panels (design doc Section 6.1) |
| --- | --- | --- |
| `cluster-overview.json` | On-call | SLO burn rate; nodes up by AZ; read-only replicas; max replication delay; queries/s and failed %; memory per node; hot disk free per node |
| `ingestion.json` | Data engineering | Rows/s and bytes/s by table; Kafka lag per connector; insert latency p95; parts per partition (top 10); delayed/rejected inserts; distributed queue |
| `query-performance.json` | DBRE, BI owners | p50/p95/p99 by user class; concurrent queries vs limit; top 20 queries by read bytes and memory; quota consumption by user; workload CPU share |
| `keeper.json` | DBRE | Leader and followers; avg/max latency; outstanding requests; znode count and data size; snapshot age; log disk latency |
| `storage-tiers.json` | Capacity, FinOps | Bytes per volume (hot/warm/cold) per shard; TTL move backlog; S3 requests/s and cache hit rate; 90-day growth projection |
| `security.json` | Security operations | Logins success/failure by source; `ACCESS_DENIED` rate; grants and DDL timeline; export-pattern queries; break-glass usage |

`cluster-overview.json` is included as a starting point.
