# ClickHouse best practices

These are the rules reviewers apply to every PR in this repository. Each one says what to do, why, and what happens if you don't. They are written for this platform (12 shards x 2 replicas, tiered storage, default-deny access), not for ClickHouse in general.

## 1. Schema design

| Do | Why | If you don't |
| --- | --- | --- |
| Put the most-filtered, lowest-cardinality columns first in `ORDER BY`, e.g. `(customer_id, event_type, event_time)` | The primary index is sparse (one mark per 8,192 rows); only a prefix of `ORDER BY` can skip granules | Every query scans the full partition; latency grows with data volume |
| `PARTITION BY` day or month only (`toYYYYMMDD`, `toYYYYMM`) | Partitions are a management unit (TTL, drops, moves), not an index | Thousands of partitions mean too many parts, slow merges, rejected inserts |
| Aim for 10-1,000 partitions per table in total | Keeps part counts and Keeper metadata bounded | Keeper znode growth, slow startup, `TOO_MANY_PARTS` |
| Use the smallest correct type: `UInt32` not `Int64`, `Date` not `DateTime` when time is irrelevant, `Decimal` for money | Less disk, less memory, faster scans | 2-4x storage and RAM for nothing |
| Wrap repetitive strings in `LowCardinality(String)` (fewer than ~10k distinct values) | Dictionary-encoded; much faster GROUP BY and filters | Large string columns dominate scan cost |
| Avoid `Nullable` unless NULL means something different from a default | `Nullable` adds a separate mask column and blocks some optimizations | Slower queries, extra storage |
| Set codecs on big columns: `Delta, ZSTD(1)` for timestamps and counters, `ZSTD(3)` for large text | Better compression than the LZ4 default | Higher storage cost on every tier |
| Always create `<name>_local` (Replicated*MergeTree) plus `<name>` (Distributed) | Replication gives HA; Distributed fans queries out to all shards | Data on one shard only, or no replica |
| Use the same sharding key, `cityHash64(customer_id)`, as the tables you join with | Co-located joins run locally on each shard | Cross-shard joins need `GLOBAL` and move data over the network |
| Set TTL and `storage_policy` on every fact table | Data moves NVMe → gp3 → S3 and is deleted on time (GDPR storage limitation) | Hot disks fill up; data is kept forever |
| Keep natural identifiers (email, phone, name, IP) only in the `pii` database | Erasure and masking touch one table | A GDPR erasure becomes a petabyte-scale rewrite |

## 2. Ingestion

- **Batch inserts: at least 100k rows or 1 second of data per insert**, or use `async_insert = 1` with `wait_for_async_insert = 1` for chatty clients. Each insert creates a part, and too many small parts cause `TOO_MANY_PARTS` and rejected inserts.
- **One insert should touch few partitions.** The profile enforces `max_partitions_per_insert_block` (100 for ETL, 10 for services). Sort or split batches by date before inserting.
- **Insert into the Distributed table** only for small volumes. High-throughput pipelines (Kafka Connect) write to `_local` tables with client-side sharding, or into the Distributed table with `distributed_foreground_insert = 1` when you need confirmation.
- **Make inserts idempotent.** Replicated tables deduplicate identical blocks, so retry the *same* batch after a timeout. For custom batching, set `insert_deduplication_token`.
- **Never insert into `curated.*`, `marts.*` or `analytics.*` directly** when a materialized view feeds them. Insert into the source (`raw.*`) so every downstream table stays consistent.
- **Transform in materialized views**, not in the client. They run on each shard on insert and keep marts incremental.

## 3. Writing queries

| Do | Why |
| --- | --- |
| Filter on the `ORDER BY` prefix and the partition key (`customer_id = ...`, `event_time >= ...`) | Lets ClickHouse skip granules and whole partitions |
| Select only the columns you need. Never `SELECT *` in application code | Columnar storage reads only requested columns, and BI roles are column-granted anyway |
| Use query parameters (`{customer_id:UInt64}`) from client libraries, never string concatenation | Prevents SQL injection, which the threat model rates High |
| Put the **smaller** table on the **right** side of a `JOIN` | The right side is loaded into memory as a hash table |
| Prefer dictionaries (`dictGet`) over joins for dimension lookups | In-memory and constant-time; no join memory |
| Use `GLOBAL IN` / `GLOBAL JOIN` only when the subquery result is small and must be shared across shards | Without `GLOBAL` each shard re-runs the subquery; with it the result is broadcast |
| Use `uniq` / `quantile` (approximate) unless exact numbers are required | 10-100x less memory than `uniqExact` / `quantileExact` |
| Query `marts.*` for dashboards, not raw facts | Pre-aggregated; the BI profile has a 300 s / 10 GB limit |
| Avoid `FINAL` on large tables in hot paths. If you need it, filter tightly first | `FINAL` merges at read time and is single-threaded per part range |
| Add `LIMIT` to exploratory queries | Result limits throw (`result_overflow_mode = 'throw'`) rather than truncate |

Check a query before shipping it:

```sql
EXPLAIN indexes = 1 SELECT ...;            -- are granules skipped? (look at "Granules: x/y")
EXPLAIN PIPELINE SELECT ...;               -- parallelism

-- After running: real cost from the log
SELECT query_duration_ms, read_rows, formatReadableSize(read_bytes), formatReadableSize(memory_usage)
FROM system.query_log WHERE query_id = '<id>' AND type = 'QueryFinish';
```

## 4. Updates and deletes

- **Model changes as inserts.** Use `ReplacingMergeTree(version)` for "latest state" tables and `AggregatingMergeTree` for rollups. ClickHouse is append-optimized.
- **Avoid `ALTER TABLE ... UPDATE / DELETE` (mutations)** except for rare corrections and GDPR erasure. A mutation rewrites every affected part on every replica.
- **Lightweight `DELETE FROM`** only masks rows until the next merge. It is not physical erasure, so GDPR erasure uses the mutation path (`runbooks`, design doc Section 4.7).
- **Bulk expiry = `DROP PARTITION`** or TTL, never row deletes.
- **Never run `OPTIMIZE ... FINAL` on large tables** outside a maintenance window. It rewrites the whole partition.

## 5. Security

- **Least privilege through roles.** People get access only through AD groups (`CH-Prod-<role>`). No direct grants to humans and no shared accounts.
- **Services use mTLS client certificates** from Vault (CN = ClickHouse user). Never put a password in code, config, CI variables or notebooks.
- **Grant on both `<table>` and `<table>_local`**, plus a matching `allow_all` row policy for engineering roles when a table has a row policy (the cluster is default-deny).
- **Application users get no table functions** (`s3`, `url`, `remote`, `file`). These are the main exfiltration and SSRF path.
- **Don't put PII in query text.** Literals are masked in logs, but parameterized queries keep them out entirely.
- **Removing a grant needs an explicit `REVOKE`** in `090_revokes.sql`. Deleting the `GRANT` line does nothing.
- **Never weaken a control to unblock yourself** (plaintext port, `verificationMode`, row-policy default). CI blocks it; ask the platform team instead.

## 6. Change management

- **Everything through Git.** No DDL or grants by hand in any shared environment. Nightly drift detection reports manual changes.
- **Migrations are forward-only and immutable.** Every DDL statement has `ON CLUSTER '{cluster}'` and `IF [NOT] EXISTS`. A rollback is a new migration.
- **Backfills and heavy rewrites are jobs, not migrations.** Run them per partition, during low load, with progress tracked.
- **Breaking schema changes take two steps:** add the new column or table and dual-write, migrate readers, then remove the old one in a later release.
- **Changes that need a restart** (listeners, storage, versions) ship through the rolling-upgrade workflow: `replica_r2` first, then `replica_r1` 24 h later, Keeper last.
- **Keep PRs small, one concern each,** and test with `make test` before review.

## 7. Operations

- **Never take both replicas of a shard down at once.** Instance-store NVMe is wiped on stop, so the peer replica is the only copy of hot data.
- **Kill a runaway query, then fix its profile in Git.** `KILL QUERY` is not a fix.
- **Never raise `parts_to_throw_insert`** to get past `TOO_MANY_PARTS`. Fix the batch size.
- **Restore into a side table first** (`RESTORE ... AS ..._restored`), validate, then `EXCHANGE TABLES`. Never restore over live data.
- **Every alert has a runbook.** If you change a threshold or procedure, update `runbooks/` in the same PR.

## 8. Anti-patterns we reject in review

| Anti-pattern | Instead |
| --- | --- |
| `PARTITION BY toStartOfHour(...)` or by a high-cardinality id | Daily or monthly partitions; put the id in `ORDER BY` |
| Single-row inserts in a loop | Batch, or `async_insert` |
| `SELECT *` from a fact table in app code | Named columns |
| String-concatenated SQL | Query parameters |
| `JOIN` with a large table on the right | Swap sides, use a dictionary, or pre-aggregate |
| `ALTER ... UPDATE` for routine state changes | `ReplacingMergeTree` with a version column |
| PII columns in `analytics` or `curated` | `pii` database plus a masked view |
| Editing a merged migration | New migration |
| Grants to individual users | Role + AD group |
| Plain `MergeTree` in a shared environment | `ReplicatedMergeTree` + Distributed |

## 9. Reviewer checklist

- [ ] `ORDER BY` matches the main query filters; partitioning is daily or monthly
- [ ] Types are minimal; `LowCardinality` and codecs are used where they help
- [ ] `_local` + Distributed tables, same sharding key as related tables
- [ ] TTL and `storage_policy` set; PII only in `pii`
- [ ] DDL has `ON CLUSTER '{cluster}'` and `IF [NOT] EXISTS`; no edits to merged migrations
- [ ] Grants on both tables; row policy has its `allow_all` companion; revokes are explicit
- [ ] Queries are parameterized, select named columns, and keep the small table on the right of joins
- [ ] `make test` passes; a runbook is updated if alerts or procedures changed
