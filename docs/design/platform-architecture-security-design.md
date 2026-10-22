# Enterprise ClickHouse Platform: Architecture & Security Design

Oct 22, 2026 · @Prashant

## 0. Design baseline

The request left every environment field blank, so this design commits to one concrete reference environment. Every number below (shard count, instance types, thresholds, RPO math) follows from these values. If a value differs, change it here first and re-derive the dependent sizing in Section 3.

| Parameter | Assumed value | What changes if it differs |
| --- | --- | --- |
| Deployment platform | AWS, self-managed ClickHouse OSS 25.x LTS on EC2; primary us-east-1 (3 AZs), DR us-west-2 | Azure/GCP: swap instance families and KMS/Secrets services, topology unchanged. Kubernetes: use the Altinity ClickHouse Operator, same shard and replica layout |
| Cluster topology | 12 shards x 2 replicas (24 data nodes) + 3 dedicated Keeper nodes | Shard count scales linearly with hot data per shard (target 6-8 TB compressed hot per shard) |
| Daily ingestion | 20 TB/day raw, about 2.5 TB/day compressed (8:1, typical for event data with LZ4/ZSTD) | Re-derive hot-tier NVMe and shard count |
| Retention | 30 days hot (NVMe), 31-90 days warm (EBS gp3), 91 days to 2 years cold (S3) | Cold-tier S3 cost scales linearly |
| Storage growth | about 0.9 PB/year compressed, per replica copy | Revisit shard count every 6 months |
| Data sources | Kafka (primary), Debezium CDC via Kafka, S3 batch files, application HTTP inserts | Direct DB pulls add a staging layer |
| Query concurrency | 300 concurrent queries at peak (BI-heavy), about 50 sustained ETL inserts | Above 500: add a replica per shard rather than more shards |
| Availability | 99.95% (about 4.4 hours of unplanned downtime a year) | 99.99%: 3 replicas per shard and active-active regions |
| Compliance | SOC 2 Type II, GDPR, ISO 27001 in scope; HIPAA and PCI-DSS only for isolated, tagged datasets | Full PCI scope: a separate cluster for cardholder data |
| Identity provider | Microsoft Entra ID (Azure AD) for humans; on-premises Active Directory reached over LDAPS | Okta: same LDAP/SAML pattern via Okta LDAP Interface |
| Backup retention | 35 days daily, plus 12 monthly backups in a separate account | Longer retention adds S3 cost only |
| Recovery objectives | RPO 15 minutes, RTO 4 hours | RPO below 1 minute: active-active dual-region ingest |

The repository is empty today (an `infra/` folder only), so the readiness score in Section 10 rates the design as written, not a running system.

## 1. Executive summary

The platform is a 12-shard, 2-replica ClickHouse cluster in three AWS Availability Zones. It has a dedicated 3-node Keeper quorum and a warm-standby DR cluster in a second region. Together these meet 99.95% availability, RPO 15 minutes and RTO 4 hours for about 1.8 PB of compressed data over two years.

**Key decisions**

| Decision | Choice | Why |
| --- | --- | --- |
| Topology | 12 shards x 2 replicas, replicas of a shard in different AZs | Survives a full AZ loss with no data loss; 2 replicas, not 3, keeps NVMe cost down at 99.95% |
| Coordination | ClickHouse Keeper, 3 dedicated nodes, one per AZ | Quorum survives one AZ; isolated from merge and query load that starves co-located Keeper |
| Storage | NVMe (30 days) to EBS gp3 (to 90 days) to S3 (to 2 years) via TTL moves | Recent data, which most queries hit, stays on the fastest disk. About 85% of bytes go to S3 at roughly a quarter of the gp3 price |
| DR | Active-passive: DR region consumes the same Kafka topics via MirrorMaker 2 | RPO set by mirror lag (typically seconds), not backup interval |
| Identity | Entra ID for people (via LDAPS to AD / Entra Domain Services), mTLS certificates for services | No static passwords for services; group membership drives ClickHouse roles |
| Encryption | TLS 1.2+ with mutual TLS on every port; AES-256 encrypted local disks; S3 SSE-KMS with customer-managed keys | Meets SOC 2 CC6.1/CC6.7, PCI-DSS Req. 3 and 4, HIPAA 164.312 |
| Governance | Settings profiles + quotas + workload scheduling per user class; row policies and secure views for PII | Stops one BI dashboard from taking memory needed by ingestion |
| Delivery | Terraform + Ansible from Git, GitHub Actions with policy gates, nightly drift detection | Every change reviewed, reproducible and audited |

**Top risks and their controls**

1. **Keeper quorum loss** stops all inserts and DDL cluster-wide. Control: dedicated nodes across 3 AZs, fast disks, alerting on latency and session churn, tested quorum-recovery runbook.
2. **Too many parts** from small or badly partitioned inserts. Control: async inserts or Kafka batching of at least 100k rows, `max_partitions_per_insert_block`, alerting on parts per partition.
3. **Data exfiltration by a valid user.** Control: result-size limits per role, no `FILE`/`URL`/`S3` table functions for analysts, query and export audit to an immutable SIEM.
4. **Ransomware or a malicious admin** deleting data and backups. Control: backups in a separate AWS account with S3 Object Lock (compliance mode), break-glass admin only, dual approval for `DROP`.

**Maturity:** the design scores 8.2/10 when fully implemented. The current state is 1/10 because nothing is deployed yet. Section 10 lists the gaps and remediation order.

## 2. Architecture diagrams

Clients reach ClickHouse only through chproxy behind an internal NLB. Kafka feeds the primary through a sink and the DR region through MirrorMaker 2. Backups leave the production account entirely.

> **Diagram:** Platform topology (primary region with 3 AZs, DR region and backup account). See the interactive version in the [online doc](https://claude.ai/artifact/4wvbBuBVziWcs9WFwGmimN), or the ASCII diagrams below.

Solid two-way arrows are replica fetches (port 9010) between AZs; each shard's two replicas sit in different AZs. Dashed accent lines are Keeper Raft traffic (port 9234), one Keeper per AZ, so quorum survives any one AZ.

**Network zones and allowed flows (ASCII)**

```text
                       +-------------------------- analytics-prod account ---------------------------+
 Corporate users       |  VPC 10.40.0.0/16  (no IGW route in data plane)                              |
  (Entra MFA)          |                                                                              |
      |  Client VPN    |  +-- vpn subnet --+    8443/9440   +-- proxy subnets --+                     |
      +--------------->|  | Client VPN ENI |--------------->| chproxy x3 (NLB)  |                     |
                       |  +----------------+                +---------+---------+                     |
 Consumer VPCs         |                                         | 8443/9440 mTLS                     |
  (BI SaaS, apps) -----|--- PrivateLink endpoint service --------+                                    |
                       |                                         v                                    |
 Kafka Connect ------->|  9440 mTLS                 +---------- data subnets x3 ----------+           |
  (sink workers)       |--------------------------->| ClickHouse 24 nodes                 |           |
                       |                            |  9010 <-> 9010 replica fetch        |           |
                       |                            |  9440 <-> 9440 distributed queries  |           |
                       |                            +---------+-------------------+-------+           |
                       |                                 9281 | mTLS              | 9363              |
                       |                            +---------v--------+   +------v--------+          |
                       |                            | Keeper x3 (9234) |   | Prometheus    |          |
                       |                            +------------------+   +---------------+          |
                       |  endpoints subnets: S3 (gateway), KMS, Secrets Manager, STS, SSM, Logs     |
                       |  egress: NAT -> Network Firewall (FQDN allowlist) -> internet               |
                       +------------------------------------------------------------------------------+
```

**Data lifecycle (ASCII)**

```text
 Sources                Ingest                  Primary cluster (per shard)                  Protection
 --------               ------                  ---------------------------                  ----------
 Apps   -\                                       day 0-30    NVMe hot   (encrypted disk)
 CDC    --+--> Kafka --> Kafka Connect sink -->  day 31-90   gp3 warm   (encrypted disk)   -->  daily BACKUP to S3
 S3     --+    (7 days)  (exactly-once,          day 91-730  S3 cold    (SSE-KMS CMK)            (backup account,
 Logs   -/       |        100k+ row batches)     day 730     TTL DELETE                           Object Lock 35 d)
                 |                                                                                      |
                 +--> MirrorMaker 2 --> Kafka (us-west-2) --> DR cluster (12 x 1) <-- CRR copy -------+
```

## 3. Infrastructure design

The primary cluster is 24 storage-dense data nodes and 3 Keeper nodes in us-east-1. Each shard's two replicas sit in different AZs, and each Keeper node in its own AZ. A smaller DR cluster in us-west-2 consumes the same mirrored Kafka streams.

### 3.1 Cluster topology

| Area | Recommendation | Why required | Risk if omitted |
| --- | --- | --- | --- |
| Sharding key | `cityHash64(customer_id)` on the Distributed table; local tables `ReplicatedMergeTree`, `PARTITION BY toYYYYMMDD(event_time)`, `ORDER BY (customer_id, event_type, event_time)` | Puts a customer's rows on one shard, so per-customer aggregations and joins run locally with `distributed_group_by_no_merge` / `prefer_localhost_replica` | Random sharding forces cross-shard shuffles on every GROUP BY customer, multiplying network and memory |
| Skew control | Track rows per shard daily; whales (customers above 5% of volume) get a composite key `cityHash64(customer_id, toStartOfHour(event_time))` | Prevents one shard filling first | One hot shard sets the whole cluster's capacity ceiling |
| Ingestion path | Kafka Connect ClickHouse Sink (exactly-once mode) writing to the Distributed table with `internal_replication = true` and `distributed_foreground_insert = 1` | Deterministic sharding, batches of 100k-1M rows, offset tracking | The Kafka table engine on every node shards by partition assignment, not key, and breaks co-location |
| Replication | 2 replicas per shard, replica A in us-east-1a/1b/1c round robin, replica B in a different AZ | Survives any single AZ loss with zero data loss | Both replicas in one AZ means an AZ outage makes the shard unavailable |
| Keeper | 3 dedicated nodes, one per AZ, Raft over TLS (port 9234), clients on 9281 | Quorum (2 of 3) survives one AZ | Co-located Keeper starves under merges; session expiry makes tables read-only |
| Multi-AZ | 3 AZs; data nodes spread 8/8/8; internal NLB per AZ for clients | Balances AZ blast radius | A 2-AZ design cannot keep Keeper quorum through an AZ loss |
| DR region | us-west-2, 12 shards x 1 replica on i4i.16xlarge, own 3-node Keeper, consumes MirrorMaker 2 replicated topics | RPO equals mirror lag (seconds); RTO is DNS cutover plus validation | Backup-only DR gives RPO of hours and RTO of a day or more at petabyte scale |
| Active-active vs active-passive | **Active-passive (warm standby)**. Active-active only if RPO under 1 minute or 99.99% is required | Active-passive halves cross-region write complexity and avoids dual-ingest reconciliation | Active-active doubles compute cost and needs idempotent ingest in two regions |

### 3.2 Infrastructure sizing

| Role | Count | Instance | CPU / memory | Storage | Network |
| --- | --- | --- | --- | --- | --- |
| Data node (primary) | 24 | i4i.16xlarge | 64 vCPU / 512 GiB | 4 x 3,750 GB NVMe (md RAID 0, about 15 TB) + 4 x 4 TiB gp3 (16,000 IOPS, 1,000 MB/s each) | 37.5 Gbps |
| Keeper (primary) | 3 | m7i.2xlarge | 8 vCPU / 32 GiB | gp3 200 GiB for logs (6,000 IOPS) + gp3 500 GiB for snapshots, separate volumes | Up to 12.5 Gbps |
| Data node (DR) | 12 | i4i.16xlarge (instance-store hosts cannot be resized without losing local data, so DR starts at full node size) | 64 vCPU / 512 GiB | 4 x 3,750 GB NVMe + 4 x 4 TiB gp3 | 37.5 Gbps |
| Keeper (DR) | 3 | m7i.xlarge | 4 vCPU / 16 GiB | gp3 as above | Up to 12.5 Gbps |
| Query proxy (chproxy) | 3 | c7i.2xlarge | 8 vCPU / 16 GiB | 50 GiB gp3 | Up to 12.5 Gbps |
| Kafka Connect workers | 6 | m7i.4xlarge | 16 vCPU / 64 GiB | 100 GiB gp3 | Up to 12.5 Gbps |

**How the numbers are derived**

- **Hot data per shard:** 2.5 TB/day x 30 days / 12 shards = 6.25 TB, about 42% of 15 TB NVMe. ClickHouse needs headroom for merges, which temporarily double a partition's size, so 70% is the alert line.
- **Warm data per shard:** 2.5 TB/day x 60 days / 12 = 12.5 TB on 16 TiB of gp3 (78%), so the warm tier must be extended or shards added within about 9 months at 0.9 PB/year growth.
- **Memory:** 512 GiB per node lets 25 concurrent BI queries per node run at 10 GiB each (300 / 12 shards, each query fans out to one replica per shard) while leaving 40% for ingestion, merges and page cache.
- **CPU:** 64 vCPU at `max_threads = 16` for BI gives about 4 heavy queries saturating a node at once; the workload scheduler (Section 4.8) queues the rest instead of thrashing.
- **Network:** average ingest is 20 TB/day raw = 231 MB/s cluster-wide (about 1.9 Gbit/s); with replication fetch, distributed query traffic and a 5x peak factor, about 3 Gbit/s per node, under 10% of 37.5 Gbps. Cross-AZ replication volume is about 2.5 TB/day, which costs roughly $50/day at AWS inter-AZ pricing.
- **Keeper:** memory holds the full znode tree (parts and replication queue metadata). 32 GiB covers about 50 million znodes. Log disk latency, not CPU, drives Keeper commit latency, hence dedicated volumes.

### 3.3 Storage architecture

| Medium | Use | Strengths | Weaknesses |
| --- | --- | --- | --- |
| Local NVMe (i4i instance store) | Hot tier, 0-30 days | Highest IOPS and lowest latency, no per-IOPS charge | Ephemeral: lost on instance stop or host failure, so recovery is a replica re-fetch |
| EBS gp3 | Warm tier, 31-90 days | Survives instance replacement; IOPS and throughput set independently; snapshots | Network-attached latency; 1,000 MB/s per volume cap |
| EBS io2 Block Express | Keeper logs only, if p99 commit latency on gp3 exceeds 10 ms | Sub-millisecond, consistent latency | About 4x the gp3 price |
| S3 (`s3` disk with local cache) | Cold tier, 91 days to 2 years | Lowest cost, 11 nines durability, unlimited capacity | Per-request cost; first-read latency 50-200 ms; needs a filesystem cache disk |

Tiered storage is one storage policy with three volumes and TTL moves, so no application change is needed:

```sql
ALTER TABLE events_local ON CLUSTER prod
  MODIFY TTL
    event_time + INTERVAL 30 DAY TO VOLUME 'warm',
    event_time + INTERVAL 90 DAY TO VOLUME 'cold',
    event_time + INTERVAL 730 DAY DELETE;
```

**S3 integration rules**

- One bucket per region per cluster, no other writers, versioning off (ClickHouse manages object lifecycle), SSE-KMS with a customer-managed key (Section 4.6).
- Access through an S3 Gateway VPC endpoint and an EC2 instance role; no access keys in config.
- A `cache` disk of 2 TB on NVMe in front of S3 so repeated cold queries do not pay S3 latency twice.
- Zero-copy replication stays **off**: it is not recommended for production. Each replica writes its own copy of cold data, which doubles cold-tier storage but keeps replicas independent.

**Cost optimization levers (approximate us-east-1 list prices)**

1. Use 3-year Reserved Instances or a Savings Plan on the 24 data nodes; this is the largest line and saves about 60% against on-demand.
2. Recompress partitions older than 90 days with `ZSTD(3)` codecs before the move to S3. This typically gains 20-30% over LZ4 at a modest CPU cost on rarely read data.
3. Move objects older than 180 days to S3 Standard-IA by bucket lifecycle rule: about 40% cheaper per GB, but each read costs $0.01/GB, so only do it for data queried less than once a month.
4. Keep raw events 2 years only where compliance requires it; elsewhere replace them after 90 days with `AggregatingMergeTree` rollups that are 50-100x smaller.
5. Watch cross-AZ traffic: put chproxy and clients in the same AZ as the replica they prefer (`load_balancing = nearest_hostname` or `in_order` with AZ-local first).

### 3.4 High availability design

| Failure | Impact | Automatic behaviour | Operator action | Recovery time |
| --- | --- | --- | --- | --- |
| One data node down | That shard runs on one replica; reads continue; writes continue to surviving replica | Distributed queries fail over via `load_balancing`; chproxy health checks remove the node | Replace instance; new replica re-fetches parts from peer | Re-fetch of about 19 TB (hot + warm) at about 1 GB/s: around 5-6 hours, during which the shard has no redundancy |
| NVMe drive failure | RAID 0 loses the hot volume on that node | Node is marked unhealthy | Treat as node loss: replace instance, re-fetch | As above |
| Whole AZ down | 8 data nodes and 1 Keeper lost; every shard keeps one replica | Keeper keeps quorum (2/3); inserts and queries continue at half capacity | Throttle BI (lower quotas) to protect ingestion | Zero downtime; full redundancy after AZ returns and replicas catch up |
| One Keeper node down | None for clients | Raft re-elects leader within seconds | Replace node, restore from snapshot, rejoin | Minutes |
| Keeper quorum lost (2 of 3) | All replicated tables become read-only; inserts fail; SELECTs still work | None | Runbook 7.4: restore quorum, or recover a single node with `--force-recovery` and re-add peers | Target under 30 minutes; Kafka buffers ingest so no data is lost |
| Region down | Primary unavailable | DR keeps consuming mirrored Kafka | Runbook 7.5: promote DR, switch DNS, add replicas later | Under 4 hours |
| Bad config or release | Can affect all nodes | None | Canary one replica per shard first; roll back via Git revert | Minutes with canary; hours without |
| Too many parts | Inserts rejected with `TOO_MANY_PARTS` | Merges continue | Find the offending writer in `system.part_log`; fix batching | Minutes to hours |

## 4. Security framework

No ClickHouse node has a public address, no port accepts plaintext, and no human or service holds a long-lived static credential. All access goes through the chproxy tier or a private endpoint and authenticates with mTLS or the corporate IdP.

### 4.1 Zero-trust network architecture

| Control | Recommended implementation | Why required | Risk if omitted | Enterprise practice |
| --- | --- | --- | --- | --- |
| VPC design | Dedicated `analytics-prod` VPC (10.40.0.0/16) in its own AWS account, joined to the shared-services and app VPCs via Transit Gateway with route-table segmentation | Account boundary limits IAM blast radius; TGW route tables enforce which VPCs may reach the data plane | Flat peering lets any peered workload scan ClickHouse ports | One account per environment (prod, staging, DR) under an AWS Organizations OU with SCPs |
| Subnets | Private only for all ClickHouse, Keeper, chproxy and Kafka Connect: `data` (3 x /22), `keeper` (3 x /26), `proxy` (3 x /26), `endpoints` (3 x /26). One public `/28` per AZ for NAT only | Nothing in the data plane is internet-routable | One misconfigured security group exposes data publicly | No IGW route in any data-plane route table; SCP denies `ec2:AssociateAddress` in the account |
| Egress | NAT gateway plus AWS Network Firewall with a domain allowlist (OS mirrors, ClickHouse package repo); all AWS APIs through VPC endpoints | Blocks data exfiltration and C2 callbacks from a compromised host | A compromised node can upload data anywhere | Egress default-deny, allowlist by FQDN, logged |
| Security groups | One SG per role (`sg-ch-data`, `sg-ch-keeper`, `sg-ch-proxy`, `sg-prometheus`, `sg-kafka-connect`), rules reference SGs, never CIDRs | Identity-based micro-segmentation | CIDR rules silently admit any new host in a subnet | Rules managed only by Terraform; AWS Config rule flags `0.0.0.0/0` |
| Network ACLs | Coarse stateless guardrail: `data` subnets accept 8443/9440 only from `proxy` and `kafka-connect` subnets, all ClickHouse ports from `data` and `keeper`, ephemeral returns; deny everything else | Second, independent layer if an SG is mis-edited | A single SG mistake is a full exposure | NACLs change rarely, through a separate approval path |
| Service endpoints | Gateway: S3. Interface: KMS, Secrets Manager, STS, SSM, SSM Messages, EC2 Messages, CloudWatch Logs, ECR | Keeps AWS API traffic private and lets endpoint policies restrict buckets and keys | S3 data traverses NAT; any bucket reachable | S3 endpoint policy allows only the cluster's own buckets |
| Bastion | **No bastion, no SSH.** AWS Systems Manager Session Manager with Entra SSO, session recording to an S3 bucket with Object Lock; port 22 closed in every SG | Removes the most-attacked entry point and gives per-command audit | Shared bastion keys; unrecorded root shells | Just-in-time access via an approval workflow (for example AWS IAM Identity Center + PIM) |
| VPN | AWS Client VPN with Entra ID SAML and MFA for engineers, landing in a `vpn` subnet that may reach chproxy only; site-to-site IPsec (or Direct Connect) to on-prem AD domain controllers for LDAPS | Humans reach the query layer only, never nodes directly | VPN users can hit Keeper or interserver ports | Device posture check; split tunnel off |
| PrivateLink | chproxy NLB (TLS passthrough on 8443 and 9440) published as a VPC endpoint service; consumer accounts (BI, apps, partner VPCs) connect with interface endpoints, allowlisted by principal | One-way, non-routable connectivity with no CIDR overlap issues | VPC peering exposes whole CIDR ranges in both directions | Azure equivalent: Private Link Service + Private Endpoint; GCP: Private Service Connect |

**ClickHouse port matrix**

| Port | Purpose | Exposure | Security controls |
| --- | --- | --- | --- |
| 8123 | HTTP interface, plaintext | **Disabled** (`http_port` removed) | Health checks use `/ping` on 8443 instead |
| 8443 | HTTPS interface (JDBC/ODBC drivers, BI tools, REST) | `sg-ch-proxy` and `sg-kafka-connect` only | TLS 1.2+, client certificate required for services; chproxy enforces per-user limits |
| 9000 | Native TCP, plaintext | **Disabled** (`tcp_port` removed) | All native traffic, including distributed queries, uses 9440 |
| 9440 | Native TCP over TLS (clickhouse-client, distributed queries between shards) | `sg-ch-proxy`, `sg-kafka-connect`, `sg-ch-data` | mTLS; `remote_servers` uses `<secure>1</secure>` and a cluster `<secret>` |
| 9004 | MySQL wire protocol | **Disabled** unless a named tool needs it; then `sg-ch-proxy` only | Requires TLS; separate user with `readonly = 1` |
| 9005 | PostgreSQL wire protocol | **Disabled**, same rule as 9004 | As 9004 |
| 9009 / 9010 | Interserver HTTP / HTTPS (replica part fetches) | 9009 disabled; 9010 from `sg-ch-data` only | `interserver_https_port`, `interserver_http_credentials` from Secrets Manager, mTLS |
| 9181 | Keeper client, plaintext | **Disabled** | Replaced by 9281 |
| 9281 | Keeper client over TLS | `sg-ch-data` to `sg-ch-keeper` only | mTLS; Keeper ACL digest auth (`<identity>`) per cluster |
| 9234 | Keeper Raft (inter-Keeper consensus) | `sg-ch-keeper` to itself only | `<secure>true</secure>` in `raft_configuration`; mTLS |
| 9363 | Prometheus metrics | `sg-prometheus` only | No data in metrics, but it leaks table and user names; scrape over the private network only |

**Firewall examples**

```hcl
# Terraform: data nodes accept native TLS from proxy and Kafka Connect; nothing else.
resource "aws_security_group_rule" "data_native_tls_from_proxy" {
  type                     = "ingress"
  security_group_id        = aws_security_group.ch_data.id
  source_security_group_id = aws_security_group.ch_proxy.id
  protocol                 = "tcp"
  from_port                = 9440
  to_port                  = 9440
  description              = "Native TLS from chproxy"
}

resource "aws_security_group_rule" "data_interserver_tls" {
  type                     = "ingress"
  security_group_id        = aws_security_group.ch_data.id
  source_security_group_id = aws_security_group.ch_data.id
  protocol                 = "tcp"
  from_port                = 9010
  to_port                  = 9010
  description              = "Replica fetch over HTTPS"
}

resource "aws_security_group_rule" "keeper_client_tls" {
  type                     = "ingress"
  security_group_id        = aws_security_group.ch_keeper.id
  source_security_group_id = aws_security_group.ch_data.id
  protocol                 = "tcp"
  from_port                = 9281
  to_port                  = 9281
  description              = "Keeper client TLS from data nodes"
}
```

```bash
# Host firewall (nftables) on each data node, defence in depth behind security groups.
cat >/etc/nftables.d/clickhouse.nft <<'EOF'
table inet clickhouse {
  set data_nodes  { type ipv4_addr; flags interval; elements = { 10.40.0.0/22, 10.40.4.0/22, 10.40.8.0/22 } }
  set proxy_nodes { type ipv4_addr; flags interval; elements = { 10.40.32.0/26, 10.40.32.64/26, 10.40.32.128/26 } }
  set prometheus  { type ipv4_addr; elements = { 10.40.40.10, 10.40.40.11 } }
  chain input {
    type filter hook input priority 0; policy drop;
    ct state established,related accept
    iif lo accept
    tcp dport { 8443, 9440 } ip saddr @proxy_nodes accept
    tcp dport { 9440, 9010 } ip saddr @data_nodes accept
    tcp dport 9363 ip saddr @prometheus accept
    counter log prefix "ch-drop " drop
  }
}
EOF
nft -f /etc/nftables.d/clickhouse.nft
```

### 4.2 TLS and mutual TLS

Every hop uses TLS 1.2 or 1.3 with certificates from a private PKI. Clients and nodes must present a certificate the server verifies (`verificationMode = strict`).

| Tier | Issuer | Lifetime | Key | Stored in |
| --- | --- | --- | --- | --- |
| Root CA | Offline, AWS CloudHSM or air-gapped HSM | 10 years | RSA 4096 or ECDSA P-384 | HSM only; used once per intermediate |
| Intermediate CA | Vault PKI secrets engine (`pki_int_clickhouse`), signed by root | 3 years | ECDSA P-384 | Vault, sealed by AWS KMS |
| Server certificates | Vault PKI role `ch-server` | 30 days, auto-renewed at 2/3 of life | ECDSA P-256; SAN = node FQDN + `*.ch.prod.internal` | Vault Agent writes to `/etc/clickhouse-server/tls/` (0400, owner clickhouse) |
| Keeper certificates | Vault PKI role `ch-keeper` | 30 days | ECDSA P-256 | As above, on Keeper nodes |
| Client certificates (services) | Vault PKI role `ch-client`, CN = ClickHouse user name, SAN `URI:spiffe://prod/ch/<user>` | 24 hours to 7 days | ECDSA P-256 | Issued at service start via Vault Agent or cert-manager |
| Client certificates (humans) | Not used; humans authenticate through the IdP (4.4) | n/a | n/a | n/a |

Coverage:

- **Client to ClickHouse:** 8443 and 9440, server certificate plus client certificate; service users are created `IDENTIFIED WITH ssl_certificate CN '<name>'`, so the certificate *is* the credential.
- **ClickHouse to ClickHouse:** distributed queries over 9440 with `<secure>1</secure>` and a shared cluster `<secret>`. Replica fetches over 9010 with `interserver_https_port`, both sides verifying against the intermediate CA.
- **Keeper to Keeper:** Raft over TLS (`<secure>true</secure>`), ClickHouse to Keeper over 9281 with `<secure>1</secure>` per node.

**Certificate rotation (no downtime)**

1. Vault Agent renews each certificate at two-thirds of its lifetime and writes the new file atomically (write to temp, rename).
2. ClickHouse reloads certificates without restart: the server re-reads `certificateFile`/`privateKeyFile` on config reload, triggered by Vault Agent running `clickhouse-client --query "SYSTEM RELOAD CONFIG"`.
3. Keeper also picks up new certificates on reload. Restart Keeper nodes one at a time only if a CA changes, verifying `mntr` shows a leader and 2 followers between each.
4. **Intermediate CA rotation** (every 2.5 years): issue the new intermediate, publish a CA bundle containing old and new intermediates to all nodes and clients, then switch issuance to the new intermediate. Remove the old one from the bundle after the longest certificate lifetime (30 days) has passed.
5. Alert at 14 days before any certificate expiry (metric from a blackbox exporter TLS probe), page at 3 days.

Full `config.xml` and `openssl` commands are in Section 5.3.

### 4.3 Identity and access management (RBAC)

People never get privileges directly. They map from IdP groups to ClickHouse roles, and roles grant on databases, not `*.*`. Only `role_admin` holds `ACCESS MANAGEMENT`.

| Role | Who | Grants (summary) | Auth method | Settings profile / quota |
| --- | --- | --- | --- | --- |
| `role_admin` | 2 named break-glass accounts, sealed in Vault, use is paged | `ALL WITH GRANT OPTION` | Password from Vault + IP restriction to the SSM-managed admin host | `profile_admin` |
| `role_dba` | Database reliability team | `SYSTEM` (merges, replicas, reload, flush logs), `KILL QUERY`, `OPTIMIZE`, DDL on `analytics.*`, `SELECT` on `system.*`; no `ACCESS MANAGEMENT`, no `SELECT` on PII databases | `AD group CH-Prod-role_dba` | `profile_dba` |
| `role_platform_engineer` | Platform / SRE | `SELECT` on `system.*`, `SYSTEM FLUSH LOGS`, `SYSTEM RELOAD CONFIG`, `SHOW`; no table data | `AD group CH-Prod-role_platform_engineer` | `profile_power` |
| `role_data_engineer` | Data engineering | `CREATE TABLE`, `ALTER`, `INSERT`, `SELECT` on `staging.*` and `analytics.*`; `SELECT` on non-PII `curated.*` | `AD group CH-Prod-role_data_engineer` | `profile_power` / `quota_power` |
| `role_etl_service` | Kafka Connect, Airflow, dbt service accounts | `INSERT` on `raw.*`, `staging.*`; `SELECT, INSERT, ALTER` on `analytics.*`; `CREATE TEMPORARY TABLE` | mTLS client certificate | `profile_etl` / `quota_etl` |
| `role_bi_analyst` | Analysts via Tableau, Power BI, Superset | `SELECT` on `curated.*` through secure views; row policies apply | `AD group CH-Prod-role_bi_analyst` | `profile_bi` / `quota_bi` |
| `role_readonly` | Broad internal read access | `SELECT` on `curated.public_*` only; `readonly = 1` | AD group `CH-Prod-role_readonly` | `profile_readonly` |
| `role_support` | Customer support (tenant-scoped look-ups) | `SELECT` on `support.*` views; row policy limits to the tenant in the session setting | AD group `CH-Prod-role_support` | `profile_bi` / `quota_support` |
| `role_security_auditor` | Security / internal audit | `SELECT` on `system.query_log`, `session_log`, `users`, `roles`, `grants`, `role_grants`, `row_policies`, `quotas`; `SHOW ACCESS`; no business data | `AD group CH-Prod-role_security_auditor` | `profile_readonly` |

**Authentication approaches compared**

| Method | How it works in ClickHouse | Strengths | Weaknesses | Use for |
| --- | --- | --- | --- | --- |
| Local password (`sha256_password` / `bcrypt_password`) | Hash stored in replicated access storage | Simple, no dependencies | Static secret; manual rotation; no MFA | Break-glass only |
| `ssl_certificate` (mTLS) | User matched on certificate CN or SAN | No shared secret; short-lived; strong for machines | Needs PKI and rotation automation | All service accounts |
| LDAP / LDAPS to Active Directory | `ldap_servers` + `user_directories/ldap` with `role_mapping` from AD groups | Central lifecycle: leaver disabled in AD is locked out at next login; group-to-role mapping | Password typed into the client; no MFA on the database hop; LDAP outage blocks new logins | Humans via BI tools and clients |
| Microsoft Entra ID | Entra has no native LDAP: either Entra Domain Services (managed LDAPS synced from Entra) or on-prem AD synced by Entra Connect, then the LDAP path above | Single identity across SaaS and ClickHouse | Extra Entra DS cost; MFA enforced at VPN / SSO, not by ClickHouse | Human users (this design) |
| Kerberos (AD) | `kerberos` section + `IDENTIFIED WITH kerberos`; SPNEGO on HTTP | Single sign-on for domain-joined desktops, no password over the wire | Keytab management; awkward for cloud-native clients | Optional for Windows BI desktops |
| OIDC / JWT | ClickHouse Cloud Enterprise supports JWT; self-managed OSS LTS does not ship it. Altinity Antalya builds (25.8.16+) add `token_processors` (`openid`, `azure`, JWKS) | MFA and conditional access at token issue; short-lived tokens | Not in the OSS LTS line this design assumes | Re-evaluate when OSS LTS includes token auth; until then, LDAP |
| External HTTP authenticator | `IDENTIFIED WITH http SERVER '<name>'` calls an internal service | Lets a custom broker apply MFA or device checks | You own an auth-critical service | Only if Entra conditional access must reach the DB hop |

SQL for every role, user and grant is in Section 5.4.

### 4.4 Identity provider integration

- **Users come from the IdP, not from SQL.** An LDAP `user_directory` authenticates every non-service login and maps AD groups prefixed `CH-` to roles. Removing someone from the AD group revokes access at their next authentication, with no ClickHouse change.
- **Entra ID path:** Entra ID is the source of truth. Entra Domain Services exposes LDAPS (636) inside a peered VNet reached over site-to-site VPN; ClickHouse binds as `{user_name}@corp.example.com` and searches group membership.
- **On-prem AD path:** ClickHouse binds to two AD domain controllers per site over LDAPS, behind an internal NLB for failover.
- **Group naming:** `CH-<Env>-<role name>` in AD (for example `CH-Prod-role_bi_analyst`); ClickHouse `role_mapping` strips the `CH-Prod-` prefix to get the role name.
- **MFA:** enforced at the two front doors, Client VPN (Entra SAML + conditional access) and the BI tool's SSO. The database hop itself uses LDAP.
- **Joiner/mover/leaver:** quarterly access review exports `system.role_grants` and the AD group membership to the auditor role; differences are tickets.

### 4.5 Secrets management

One system per secret type: Vault for certificates (it is the PKI), AWS Secrets Manager for the few remaining passwords and the interserver secret. Nothing is in Git, AMIs or user data.

| Secret | Store | Rotation | Delivery to ClickHouse |
| --- | --- | --- | --- |
| Server, Keeper, client certificates | Vault PKI | 30 days servers, 1-7 days clients, automatic | Vault Agent template to `/etc/clickhouse-server/tls/`, then `SYSTEM RELOAD CONFIG` |
| Break-glass admin passwords | Vault KV v2, two-person retrieval (Control Groups) | After every use and every 90 days | Never in config; hash applied with `ALTER USER` |
| Interserver HTTP credentials and cluster `<secret>` | AWS Secrets Manager | 180 days, dual-credential rollover | Rendered at boot into `config.d/secrets.xml` (0400) using `from_env` |
| Encrypted-disk keys | AWS Secrets Manager, envelope-encrypted by a KMS CMK | Yearly; old key kept for reading (Section 4.6) | Rendered into `config.d/disk_keys.xml` (0400) at boot |
| LDAP bind credentials | Not needed: bind uses the logging-in user's own DN | n/a | n/a |
| S3 access | No keys: EC2 instance role with `use_environment_credentials` | STS short-lived credentials, automatic | n/a |
| API tokens for chproxy, Grafana, Kafka Connect | AWS Secrets Manager | 90 days via rotation Lambda | Fetched at service start |

**Rotation without downtime for the few password-based service users** uses alternating users (`svc_x_a`, `svc_x_b`). The rotation Lambda sets a new password on the inactive one, publishes it as the current secret version, and the old one expires after all consumers have restarted.

```python
# Secrets Manager rotation Lambda (steps abbreviated): rotate the inactive ClickHouse user.
import json, secrets, boto3, clickhouse_connect

sm = boto3.client("secretsmanager")

def set_secret(arn, token):
    pending = json.loads(sm.get_secret_value(SecretId=arn, VersionId=token,
                                             VersionStage="AWSPENDING")["SecretString"])
    admin = json.loads(sm.get_secret_value(SecretId="ch/prod/rotator")["SecretString"])
    client = clickhouse_connect.get_client(host="chproxy.ch.prod.internal", port=8443, secure=True,
                                           username=admin["user"], password=admin["password"])
    client.command(
        "ALTER USER {u:Identifier} ON CLUSTER prod IDENTIFIED WITH sha256_password BY {p:String}",
        parameters={"u": pending["user"], "p": pending["password"]})

def create_secret(arn, token):
    current = json.loads(sm.get_secret_value(SecretId=arn, VersionStage="AWSCURRENT")["SecretString"])
    nxt = current["user"][:-1] + ("b" if current["user"].endswith("a") else "a")
    sm.put_secret_value(SecretId=arn, ClientRequestToken=token, VersionStages=["AWSPENDING"],
                        SecretString=json.dumps({"user": nxt, "password": secrets.token_urlsafe(32)}))
```

```hcl
# Vault Agent template: render the server certificate and reload ClickHouse on change.
template {
  contents    = "{{ with pkiCert \"pki_int_clickhouse/issue/ch-server\" \"common_name=ch-s01-r1.ch.prod.internal\" \"ttl=720h\" }}{{ .Cert }}{{ .CA }}{{ end }}"
  destination = "/etc/clickhouse-server/tls/server.crt"
  perms       = "0440"
  command     = "clickhouse-client --secure --query 'SYSTEM RELOAD CONFIG'"
}
```

On Azure, the same pattern uses Key Vault (certificates with auto-renewal, secrets with Event Grid near-expiry events) and a managed identity on each VM. On other clouds or on-prem, Vault covers every row of the table.

### 4.6 Encryption at rest

Data is encrypted twice. The storage layer encrypts every medium (Nitro NVMe, EBS with a CMK, S3 SSE-KMS with a CMK). ClickHouse `encrypted` disks add AES-256 application-layer encryption, so a stolen volume snapshot or a misconfigured bucket yields ciphertext.

| Layer | Implementation | Why required | Risk if omitted | Key rotation impact |
| --- | --- | --- | --- | --- |
| Local NVMe (instance store) | Encrypted by the Nitro system with AES-256, always on; plus a ClickHouse `encrypted` disk over it | Instance store cannot use a CMK; the app-layer disk gives customer control | No customer-controlled key on hot data (PCI-DSS 3.5 / 3.6 finding) | App-layer key: see the last row |
| EBS gp3 (warm, Keeper) | EBS encryption by default with CMK `alias/ch-prod-ebs`; account-level default enforced by SCP | Snapshots and detached volumes stay encrypted | An unencrypted snapshot shared or copied leaks data | CMK annual auto-rotation is transparent: KMS keeps old key material |
| S3 (cold, backups) | SSE-KMS with CMK `alias/ch-prod-s3`, S3 Bucket Keys on, bucket policy denies non-KMS `PutObject` | Key policy separates who can read data from who can administer the bucket | A bucket-policy mistake exposes plaintext objects | Transparent; old objects decrypt with retained key material |
| ClickHouse `encrypted` disk | AES\_256\_CTR over the NVMe, gp3 and (for PCI/HIPAA tables) S3 disks; keys from Secrets Manager, KMS-wrapped | Protects data even from AWS-level or storage-admin access; isolates regulated datasets | Regulated data protected only by provider-managed layers | New key encrypts **new parts only**. Old parts stay readable only while their key id is still configured; removing an old key makes those parts unreadable, so keys are retired only after every part is rewritten |

**Key rotation procedure for encrypted disks**

1. Add the new key as `<key_hex id="2">` and set `<current_key_id>2</current_key_id>`; roll out with Ansible; `SYSTEM RELOAD CONFIG`.
2. New inserts and merges now write with key 2. Old parts still read with key 1.
3. To finish rotation, rewrite old parts with `ALTER TABLE ... UPDATE <col> = <col> WHERE 1` per partition, or let TTL moves rewrite them. Track progress in `system.parts` (`disk_name`, `modification_time`).
4. Remove key 1 only when no active part predates step 1, and only after the next full backup. That backup must be readable with the keys that remain, because ClickHouse backups of encrypted disks store decrypted data unless the backup destination is itself an encrypted disk.

Full `storage.xml` is in Section 5.5.

### 4.7 Data governance

PII lives in a small number of tagged tables. Analysts see it masked or not at all. GDPR erasure is a delete from one narrow table, not a rewrite of petabytes.

| Control | Implementation | Why required | Risk if omitted |
| --- | --- | --- | --- |
| Data layout | Separate `pii.customers` (keyed by `customer_id`) from fact tables; facts hold only the pseudonymous `customer_id` | Erasure and masking touch one table | PII copied into every fact table makes erasure a petabyte-scale mutation |
| Row-level security | Row policies by tenant for BI and support roles; an explicit allow-all policy for engineering and ETL roles | Tenant isolation inside shared tables | By default (users\_without\_row\_policies\_can\_read\_rows = true) a user with no policy reads every row. This design sets it to false (default-deny, Section 5.4), so the allow-all policy for engineering roles is required |
| Column-level security | Column-scoped `GRANT SELECT(col, ...)`; PII columns never granted to BI | Smallest grant that works | `SELECT *` exposes every new column added later |
| Masking | Masked views (`curated.v_customers_masked`) granted to BI; unmasked table only to `role_pii_reader` | ClickHouse `CREATE MASKING POLICY` is ClickHouse Cloud only (25.12+), so self-managed uses views | Raw PII in dashboards and extracts |
| PII in logs | `query_masking_rules` redact emails, card numbers and national IDs from `query_log` and server logs | Literal PII in WHERE clauses lands in logs kept for a year | Audit logs become a second, unmanaged PII store |
| Pseudonymization | HMAC-SHA256 of natural identifiers in the ETL layer, key in Secrets Manager | Key never appears in ClickHouse queries or logs | Unsalted hashes of emails are reversible by dictionary attack |
| Retention | Table TTL per data class; column TTL nulls PII columns after 90 days where only aggregates are needed | Storage limitation (GDPR Art. 5(1)(e)) | Indefinite retention of personal data |
| Purging | Partition drops for bulk expiry; `ALTER TABLE ... DELETE` mutations for subject erasure; a suppression list re-applied after any restore | Erasure must be physical and must survive restores | Lightweight `DELETE` only masks rows until merge; restored backups resurrect erased subjects |

```sql
-- Row-level security: tenant scoping via a dictionary (fast; no subquery per query).
CREATE ROW POLICY tenant_scope ON curated.events FOR SELECT
  USING has(dictGet('governance.user_tenants_dict', 'customer_ids', currentUser()), customer_id)
  TO role_bi_analyst, role_support;

-- Required companion under default-deny: without it, engineers and ETL see zero rows.
CREATE ROW POLICY allow_all ON curated.events FOR SELECT USING 1
  TO role_data_engineer, role_etl_service, role_dba;

-- Column-level security: BI gets named columns only.
GRANT SELECT(event_id, event_time, customer_id, event_type, amount, country)
  ON curated.events TO role_bi_analyst;

-- Masking: a view owned by a definer that can read PII, granted to BI.
CREATE VIEW curated.v_customers_masked
  DEFINER = svc_view_owner SQL SECURITY DEFINER AS
SELECT
  customer_id,
  concat(substring(email, 1, 2), '***@', splitByChar('@', email)[2]) AS email_masked,
  concat('***-***-', right(phone, 4))                                 AS phone_masked,
  country,
  toStartOfMonth(date_of_birth)                                      AS birth_month
FROM pii.customers;
GRANT SELECT ON curated.v_customers_masked TO role_bi_analyst;

-- Column TTL: drop PII detail after 90 days, keep the row for aggregates.
ALTER TABLE raw.web_sessions ON CLUSTER prod
  MODIFY COLUMN ip_address String TTL event_time + INTERVAL 90 DAY;

-- GDPR erasure (Art. 17): physical delete from the one PII table, logged with the ticket id.
ALTER TABLE pii.customers_local ON CLUSTER prod
  DELETE WHERE customer_id IN (SELECT customer_id FROM governance.erasure_requests WHERE status = 'approved')
  SETTINGS mutations_sync = 2;
INSERT INTO governance.suppression_list SELECT customer_id, now(), ticket_id
  FROM governance.erasure_requests WHERE status = 'approved';

-- Bulk expiry: drop whole partitions; far cheaper than row deletes.
ALTER TABLE raw.clickstream_local ON CLUSTER prod DROP PARTITION '20240101';
```

```xml
<!-- config.d/query_masking.xml: keep PII literals out of logs. -->
<clickhouse>
  <query_masking_rules>
    <rule><name>email</name><regexp>[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}</regexp><replace>***@***</replace></rule>
    <rule><name>pan</name><regexp>\b(?:\d[ -]?){13,19}\b</regexp><replace>****PAN****</replace></rule>
  </query_masking_rules>
</clickhouse>
```

### 4.8 Query resource governance

Three layers stop noisy neighbours: server-wide ceilings, per-class settings profiles with locked maximums, and the workload scheduler that shares CPU by weight. Ingestion always gets its share before BI.

| Setting | ETL | BI tools | Power users | Service accounts (APIs) |
| --- | --- | --- | --- | --- |
| `max_memory_usage` | 40 GB | 10 GB (locked max 20 GB) | 50 GB | 4 GB |
| `max_threads` | 8 | 16 | 32 | 4 |
| `max_execution_time` | 3,600 s | 300 s | 1,800 s | 30 s |
| `max_partitions_per_insert_block` | 100 | n/a (read-only) | 100 | 10 |
| `max_result_rows` / overflow mode | none | 1,000,000 / throw | 10,000,000 / throw | 100,000 / throw |
| `max_concurrent_queries_for_user` | 20 | 30 | 10 | 50 |
| Workload (CPU weight) | `ingest` (5) | `bi` (3) | `adhoc` (1, capped at 30% CPU) | `api` (3) |
| Quota per user per hour | 50,000 queries | 2,000 queries, 100 M result rows | 500 queries, 20 TB read | 100,000 queries |

```sql
-- Settings profiles with constraints users cannot raise.
CREATE SETTINGS PROFILE profile_bi SETTINGS
  max_memory_usage = 10000000000 MAX 20000000000,
  max_threads = 16 MAX 16,
  max_execution_time = 300 MAX 300,
  max_result_rows = 1000000, result_overflow_mode = 'throw',
  max_rows_to_read = 50000000000,
  max_concurrent_queries_for_user = 30,
  readonly = 2,                       -- may set session settings, never write
  workload = 'bi' CONST
TO role_bi_analyst, role_support;

CREATE SETTINGS PROFILE profile_etl SETTINGS
  max_memory_usage = 40000000000 MAX 60000000000,
  max_threads = 8,
  max_insert_threads = 4,
  max_execution_time = 3600,
  max_partitions_per_insert_block = 100 CONST,
  max_concurrent_queries_for_user = 20,
  workload = 'ingest' CONST
TO role_etl_service;

CREATE SETTINGS PROFILE profile_power SETTINGS
  max_memory_usage = 50000000000 MAX 50000000000,
  max_threads = 32, max_execution_time = 1800,
  max_result_rows = 10000000, result_overflow_mode = 'throw',
  max_concurrent_queries_for_user = 10,
  workload = 'adhoc' CONST
TO role_data_engineer, role_platform_engineer;

CREATE SETTINGS PROFILE profile_service SETTINGS
  max_memory_usage = 4000000000 MAX 4000000000,
  max_threads = 4, max_execution_time = 30 MAX 30,
  max_result_rows = 100000, result_overflow_mode = 'throw',
  max_partitions_per_insert_block = 10 CONST,
  workload = 'api' CONST
TO role_api_service;

-- Quotas, tracked per user, enforced per hour and per day.
CREATE QUOTA quota_bi KEYED BY user_name
  FOR INTERVAL 1 hour MAX queries = 2000, errors = 200, result_rows = 100000000, read_bytes = 5000000000000,
  FOR INTERVAL 1 day  MAX execution_time = 86400
  TO role_bi_analyst;
CREATE QUOTA quota_etl KEYED BY user_name
  FOR INTERVAL 1 hour MAX queries = 50000, errors = 1000
  TO role_etl_service;
CREATE QUOTA quota_power KEYED BY user_name
  FOR INTERVAL 1 hour MAX queries = 500, read_bytes = 20000000000000
  TO role_data_engineer, role_platform_engineer;
CREATE QUOTA quota_service KEYED BY user_name
  FOR INTERVAL 1 minute MAX queries = 3000, errors = 300
  TO role_api_service;

-- Workload scheduler: CPU shared by weight; ad-hoc work capped.
CREATE RESOURCE cpu (MASTER THREAD, WORKER THREAD);
CREATE WORKLOAD all SETTINGS max_concurrent_threads_ratio_to_cores = 2;
CREATE WORKLOAD ingest IN all SETTINGS weight = 5;
CREATE WORKLOAD bi     IN all SETTINGS weight = 3;
CREATE WORKLOAD api    IN all SETTINGS weight = 3;
CREATE WORKLOAD adhoc  IN all SETTINGS weight = 1, max_cpu_share = 0.3;
```

Server-wide ceilings in `config.d/limits.xml`: `max_server_memory_usage_to_ram_ratio = 0.8`, `max_concurrent_queries = 400`, `max_concurrent_select_queries = 300`, `max_concurrent_insert_queries = 100`. These protect the process even if a profile is misassigned.

### 4.9 Audit and security logging

ClickHouse system tables are the event source. A collector exports them every 5 minutes to an immutable S3 bucket in a separate security account and streams them to the SIEM. The cluster keeps 30 days for operations; the archive keeps 13 months, then 7 years in Glacier for regulated datasets.

| Event | Source | How to identify it |
| --- | --- | --- |
| Authentication success and failure | `system.session_log` | `type IN ('LoginSuccess', 'LoginFailure', 'Logout')`, with `auth_type`, `client_address` |
| Authorization failures | `system.query_log` | `exception_code = 497` (`ACCESS_DENIED`) |
| DDL changes | `system.query_log` | `query_kind IN ('Create', 'Drop', 'Alter', 'Rename')` |
| User and role management | `system.query_log` | Normalized query starts with `CREATE USER`, `ALTER USER`, `DROP USER`, `CREATE ROLE`, `GRANT`, `REVOKE` |
| Role assignments | `system.query_log` + periodic snapshot of `system.role_grants` | Diff of daily snapshots catches out-of-band changes |
| Query executions | `system.query_log` | `type IN ('QueryFinish', 'ExceptionBeforeStart', 'ExceptionWhileProcessing')` |
| Data exports | `system.query_log` | `has(used_table_functions, 's3')`, `'url'`, `'remote'`, `INTO OUTFILE`, or `result_bytes > 10 GB` |
| Data changes | `system.part_log` | `event_type IN ('NewPart', 'RemovePart', 'MutatePart', 'MovePart')` |
| Server errors and security warnings | `system.text_log` | `level <= 'Warning'` |

```sql
-- SIEM detection examples (run every 5 minutes against clusterAllReplicas).
-- Brute force: 10+ failed logins from one address in 5 minutes.
SELECT client_address, user, count() AS failures
FROM clusterAllReplicas('prod', system.session_log)
WHERE type = 'LoginFailure' AND event_time > now() - INTERVAL 5 MINUTE
GROUP BY client_address, user HAVING failures >= 10;

-- Possible exfiltration: large results or outbound table functions.
SELECT event_time, user, query_id, formatReadableSize(result_bytes) AS out, used_table_functions
FROM clusterAllReplicas('prod', system.query_log)
WHERE type = 'QueryFinish' AND event_time > now() - INTERVAL 5 MINUTE
  AND (result_bytes > 10e9 OR hasAny(used_table_functions, ['s3', 'url', 'remote', 'file']));
```

Log configuration (TTL, partitioning, flush intervals) is in Section 5.6. `system.query_thread_log` stays off in production (`log_query_threads = 0`): it records one row per thread per query, often 20-50x the volume of `query_log`, and is enabled for a single session only while investigating a performance problem.

### 4.10 Threat model (STRIDE)

| Threat | STRIDE | Attack scenario | Risk | Detection | Mitigation |
| --- | --- | --- | --- | --- | --- |
| Credential theft | Spoofing | Phished analyst password replayed from outside, or a service password lifted from a CI log | High | `session_log` login from new ASN or geography; impossible travel in Entra; failed-login bursts | No reachable endpoint without VPN + MFA; services use short-lived mTLS certificates; secrets scanning in CI; LDAP lockout policy |
| SQL injection | Tampering, Information disclosure | An app builds SQL from user input and runs `UNION SELECT` against PII or `INSERT INTO FUNCTION s3(...)` | High | `query_log` patterns: stacked comments, `UNION` from API users, table functions from service accounts | Parameterized queries (`{name:Type}`) mandatory in client libraries; API users `readonly = 1`, no table functions (`REVOKE CREATE TEMPORARY TABLE, URL, S3, REMOTE`); row policies limit reach |
| Privilege escalation | Elevation of privilege | A data engineer with `ALTER` creates a definer view over `pii.*`, or uses `GRANT OPTION` | High | Alert on any `GRANT`, `CREATE ROW POLICY`, `CREATE VIEW ... DEFINER` outside the CI service account | Only the CI service account and `role_admin` hold `ACCESS MANAGEMENT`; no `WITH GRANT OPTION` below admin; RBAC changes only through reviewed Git PRs |
| Ransomware | Denial of service, Tampering | Attacker with admin credentials drops databases and deletes S3 cold data and backups | Critical | `part_log` mass `RemovePart`; `DROP` in `query_log`; CloudTrail `DeleteObject` spikes | Backups in a separate account, S3 Object Lock compliance mode 35 days; `max_table_size_to_drop` / `max_partition_size_to_drop` = 50 GB; DR cluster in another account |
| Insider threat | Information disclosure | An authorised analyst exports whole customer tables to sell | High | UEBA in SIEM over `result_bytes`, query frequency, after-hours activity per user | Masked views; result-row limits; no `INTO OUTFILE`; BI tool export caps; quarterly access review |
| Data exfiltration | Information disclosure | A compromised node or query uploads data with `s3()` / `url()` to an attacker bucket | Critical | Network Firewall denied-egress logs; S3 VPC endpoint policy denials in CloudTrail; table function use in `query_log` | Egress allowlist; S3 endpoint policy limited to own buckets; table functions revoked for non-ETL roles |
| Network attacks | Spoofing, Tampering, DoS | Lateral movement from a compromised app host scanning 9000/9181; MITM on replication; connection floods | Medium | VPC Flow Logs rejected-connection alerts; nftables drop counters; `max_connections` saturation | Plaintext ports disabled; mTLS everywhere; SG-to-SG rules; NLB in front; `max_connections = 4096` |
| Malicious admin | Repudiation, Elevation | A DBA disables query logging, drops audit tables, then deletes data | High | Audit stream gap detection (no rows from a node for 10 minutes); config drift alert on `config.d/` changes | DBAs lack `ACCESS MANAGEMENT` and write access to the audit account; audit copy is immutable in a separate account; break-glass admin use pages security; two-person rule for `DROP` in production |
| Repudiation of changes | Repudiation | A user denies running a destructive query | Medium | `query_log` with `initial_user`, `client_hostname`, `http_user_agent`; SSM session recordings | Named accounts only (no shared logins); Object Lock on audit archive; NTP-synchronized clocks |

## 5. Configuration examples

Every file below lives in the `clickhouse-platform` Git repository (Section 6.3), is rendered by Ansible with per-node values, and is applied only through the pipeline. Secrets appear as `from_env` references, never literals.

### 5.1 Kernel parameters (`/etc/sysctl.d/90-clickhouse.conf`)

```ini
# --- Memory ---
vm.max_map_count = 1048576          # many parts x many columns are mmapped; 65530 default causes mmap failures
vm.swappiness = 1                   # swap is also disabled; this is the fallback if swap is re-added
vm.overcommit_memory = 0            # ClickHouse expects heuristic overcommit; 2 causes spurious allocation failures
vm.dirty_background_ratio = 5
vm.dirty_ratio = 10                 # flush steadily; avoid multi-second write stalls during merges
vm.zone_reclaim_mode = 0            # never reclaim locally on NUMA; use remote memory instead
kernel.task_delayacct = 1           # enables ClickHouse OSIOWait/OSCPUWait per-query metrics

# --- Files ---
fs.file-max = 4194304
fs.aio-max-nr = 1048576
fs.suid_dumpable = 0

# --- Network throughput (37.5 Gbps NICs, replica fetches, distributed queries) ---
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.somaxconn = 4096
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_max_syn_backlog = 8192
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.ip_local_port_range = 10240 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 60    # detect dead peers well inside the 30 s Keeper session timeout window
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 6

# --- Network security ---
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
net.ipv6.conf.all.accept_redirects = 0

# --- Kernel security ---
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.randomize_va_space = 2
kernel.yama.ptrace_scope = 1
kernel.perf_event_paranoid = 2
```

```bash
sysctl --system                                   # apply
swapoff -a && sed -ri '/\sswap\s/s/^/#/' /etc/fstab  # disable swap permanently
```

### 5.2 Host settings, systemd and limits

```bash
# Transparent huge pages: madvise (ClickHouse recommendation), persisted on the kernel command line.
echo madvise > /sys/kernel/mm/transparent_hugepage/enabled
echo madvise > /sys/kernel/mm/transparent_hugepage/defrag
grubby --update-kernel=ALL --args="transparent_hugepage=madvise"

# CPU governor: performance (no frequency ramp latency on query bursts).
cpupower frequency-set -g performance

# Disk scheduler: none for NVMe and Nitro EBS (both appear as NVMe); persist with udev.
cat >/etc/udev/rules.d/60-clickhouse-io.rules <<'EOF'
ACTION=="add|change", KERNEL=="nvme[0-9]*n[0-9]*", ATTR{queue/scheduler}="none", ATTR{queue/nr_requests}="1023"
EOF
udevadm control --reload && udevadm trigger

# Hot volume: RAID 0 across 4 instance-store NVMe (replicas provide redundancy), ext4, noatime.
mdadm --create /dev/md0 --level=0 --raid-devices=4 --chunk=1024 /dev/nvme1n1 /dev/nvme2n1 /dev/nvme3n1 /dev/nvme4n1
mkfs.ext4 -F -E stride=256,stripe-width=1024 -m 0 /dev/md0
echo '/dev/md0 /data/nvme ext4 defaults,noatime,nodiratime,nofail 0 2' >> /etc/fstab

# Warm volume: RAID 0 across 4 encrypted gp3 volumes.
mdadm --create /dev/md1 --level=0 --raid-devices=4 --chunk=1024 /dev/nvme5n1 /dev/nvme6n1 /dev/nvme7n1 /dev/nvme8n1
mkfs.ext4 -F -m 0 /dev/md1
echo '/dev/md1 /data/warm ext4 defaults,noatime,nodiratime,nofail 0 2' >> /etc/fstab

# NUMA: check topology; i4i.16xlarge is expected to be a single node. On multi-socket hosts, interleave.
numactl --hardware
```

```ini
# /etc/systemd/system/clickhouse-server.service.d/override.conf
[Service]
LimitNOFILE=1048576
LimitNPROC=131072
LimitCORE=0                       # core dumps would contain query data (PII)
LimitMEMLOCK=infinity
TasksMax=infinity
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ProtectKernelTunables=true
ProtectControlGroups=true
RestrictSUIDSGID=true
ReadWritePaths=/var/lib/clickhouse /var/log/clickhouse-server /data/nvme /data/warm
CapabilityBoundingSet=CAP_NET_ADMIN CAP_IPC_LOCK CAP_SYS_NICE CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_IPC_LOCK CAP_SYS_NICE CAP_NET_BIND_SERVICE
EnvironmentFile=/run/clickhouse/secrets.env   # tmpfs, 0400, rendered by Vault Agent at boot
# Multi-socket hosts only:
# ExecStart=
# ExecStart=/usr/bin/numactl --interleave=all /usr/bin/clickhouse-server --config=/etc/clickhouse-server/config.xml
```

```ini
# /etc/security/limits.d/clickhouse.conf (interactive sessions as the clickhouse user)
clickhouse  soft  nofile  1048576
clickhouse  hard  nofile  1048576
clickhouse  soft  nproc   131072
clickhouse  hard  nproc   131072
clickhouse  hard  core    0
```

```bash
# Verify after reboot
cat /sys/kernel/mm/transparent_hugepage/enabled        # always [madvise] never
cat /sys/block/nvme1n1/queue/scheduler                  # [none] mq-deadline
systemctl show clickhouse-server -p LimitNOFILE         # LimitNOFILE=1048576
prlimit --pid "$(pidof clickhouse-server)" --nofile     # 1048576
```

### 5.3 TLS: certificate hierarchy and mutual TLS configuration

```bash
# --- Root CA (offline, HSM-backed in production; shown with files for clarity) ---
openssl ecparam -name secp384r1 -genkey -noout -out root-ca.key
openssl req -x509 -new -key root-ca.key -sha384 -days 3650 \
  -subj "/O=Example Corp/OU=Data Platform/CN=Example Data Platform Root CA" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" -out root-ca.crt

# --- Intermediate CA (in production: generated inside Vault, CSR signed by the root) ---
openssl ecparam -name secp384r1 -genkey -noout -out int-ca.key
openssl req -new -key int-ca.key -subj "/O=Example Corp/OU=Data Platform/CN=ClickHouse Intermediate CA" -out int-ca.csr
openssl x509 -req -in int-ca.csr -CA root-ca.crt -CAkey root-ca.key -CAcreateserial -days 1095 -sha384 \
  -extfile <(printf "basicConstraints=critical,CA:TRUE,pathlen:0\nkeyUsage=critical,keyCertSign,cRLSign") \
  -out int-ca.crt
cat int-ca.crt root-ca.crt > ca-bundle.crt

# --- Server certificate (one per node; serverAuth AND clientAuth: nodes are also clients of each other) ---
NODE=ch-s01-r1.ch.prod.internal
openssl ecparam -name prime256v1 -genkey -noout -out server.key
openssl req -new -key server.key -subj "/O=Example Corp/CN=${NODE}" -out server.csr
openssl x509 -req -in server.csr -CA int-ca.crt -CAkey int-ca.key -CAcreateserial -days 30 -sha256 \
  -extfile <(printf "subjectAltName=DNS:${NODE},DNS:*.ch.prod.internal\nextendedKeyUsage=serverAuth,clientAuth\nkeyUsage=critical,digitalSignature") \
  -out server.crt

# --- Client certificate for a service user (CN = ClickHouse user name) ---
openssl ecparam -name prime256v1 -genkey -noout -out svc_kafka_connect.key
openssl req -new -key svc_kafka_connect.key -subj "/O=Example Corp/CN=svc_kafka_connect" -out svc.csr
openssl x509 -req -in svc.csr -CA int-ca.crt -CAkey int-ca.key -CAcreateserial -days 7 -sha256 \
  -extfile <(printf "extendedKeyUsage=clientAuth\nsubjectAltName=URI:spiffe://prod/ch/svc_kafka_connect") \
  -out svc_kafka_connect.crt

# --- Verify ---
openssl verify -CAfile ca-bundle.crt server.crt
openssl s_client -connect ${NODE}:9440 -cert svc_kafka_connect.crt -key svc_kafka_connect.key \
  -CAfile ca-bundle.crt -tls1_3 </dev/null | grep -E 'Verify return code|Protocol'
```

```xml
<!-- /etc/clickhouse-server/config.d/10-network-tls.xml (data nodes) -->
<clickhouse>
  <listen_host>0.0.0.0</listen_host>

  <!-- Plaintext and unused protocol ports off -->
  <http_port remove="1"/>
  <tcp_port remove="1"/>
  <interserver_http_port remove="1"/>
  <mysql_port remove="1"/>
  <postgresql_port remove="1"/>

  <!-- TLS ports -->
  <https_port>8443</https_port>
  <tcp_port_secure>9440</tcp_port_secure>
  <interserver_https_port>9010</interserver_https_port>
  <interserver_http_host>ch-s01-r1.ch.prod.internal</interserver_http_host>
  <interserver_http_credentials>
    <user>interserver</user>
    <password from_env="CH_INTERSERVER_PASSWORD"/>
  </interserver_http_credentials>

  <openSSL>
    <server>
      <certificateFile>/etc/clickhouse-server/tls/server.crt</certificateFile>
      <privateKeyFile>/etc/clickhouse-server/tls/server.key</privateKeyFile>
      <caConfig>/etc/clickhouse-server/tls/ca-bundle.crt</caConfig>
      <loadDefaultCAFile>false</loadDefaultCAFile>
      <verificationMode>strict</verificationMode>   <!-- client certificate required -->
      <disableProtocols>sslv2,sslv3,tlsv1,tlsv1_1</disableProtocols>
      <cipherList>ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-ECDSA-CHACHA20-POLY1305</cipherList>
      <preferServerCiphers>true</preferServerCiphers>
      <cacheSessions>true</cacheSessions>
    </server>
    <client>  <!-- used for distributed queries, replica fetches and Keeper connections -->
      <certificateFile>/etc/clickhouse-server/tls/server.crt</certificateFile>
      <privateKeyFile>/etc/clickhouse-server/tls/server.key</privateKeyFile>
      <caConfig>/etc/clickhouse-server/tls/ca-bundle.crt</caConfig>
      <loadDefaultCAFile>false</loadDefaultCAFile>
      <verificationMode>strict</verificationMode>
      <disableProtocols>sslv2,sslv3,tlsv1,tlsv1_1</disableProtocols>
      <invalidCertificateHandler><name>RejectCertificateHandler</name></invalidCertificateHandler>
    </client>
  </openSSL>

  <!-- ClickHouse <-> ClickHouse: distributed queries over native TLS with a cluster secret -->
  <remote_servers>
    <prod>
      <secret from_env="CH_CLUSTER_SECRET"/>
      <shard>
        <internal_replication>true</internal_replication>
        <replica><host>ch-s01-r1.ch.prod.internal</host><port>9440</port><secure>1</secure></replica>
        <replica><host>ch-s01-r2.ch.prod.internal</host><port>9440</port><secure>1</secure></replica>
      </shard>
      <!-- shards 02-12 rendered by Ansible from inventory -->
    </prod>
  </remote_servers>

  <!-- ClickHouse -> Keeper over TLS with digest identity -->
  <zookeeper>
    <node><host>keeper-1.ch.prod.internal</host><port>9281</port><secure>1</secure></node>
    <node><host>keeper-2.ch.prod.internal</host><port>9281</port><secure>1</secure></node>
    <node><host>keeper-3.ch.prod.internal</host><port>9281</port><secure>1</secure></node>
    <session_timeout_ms>30000</session_timeout_ms>
    <operation_timeout_ms>10000</operation_timeout_ms>
    <identity from_env="CH_KEEPER_IDENTITY"/>   <!-- user:password, applies digest ACLs to znodes -->
  </zookeeper>

  <macros>
    <cluster>prod</cluster>
    <shard>01</shard>
    <replica>ch-s01-r1</replica>
  </macros>

  <prometheus>
    <endpoint>/metrics</endpoint>
    <port>9363</port>
    <metrics>true</metrics>
    <events>true</events>
    <asynchronous_metrics>true</asynchronous_metrics>
  </prometheus>
</clickhouse>
```

```xml
<!-- /etc/clickhouse-keeper/keeper_config.xml (keeper-1; server_id differs per node) -->
<clickhouse>
  <listen_host>0.0.0.0</listen_host>
  <keeper_server>
    <tcp_port_secure>9281</tcp_port_secure>     <!-- 9181 plaintext is not configured -->
    <server_id>1</server_id>
    <log_storage_path>/var/lib/clickhouse-keeper/logs</log_storage_path>
    <snapshot_storage_path>/var/lib/clickhouse-keeper/snapshots</snapshot_storage_path>
    <four_letter_word_white_list>ruok,mntr,srvr,stat,conf</four_letter_word_white_list>
    <coordination_settings>
      <operation_timeout_ms>10000</operation_timeout_ms>
      <session_timeout_ms>30000</session_timeout_ms>
      <force_sync>true</force_sync>
      <snapshot_distance>100000</snapshot_distance>
      <rotate_log_storage_interval>100000</rotate_log_storage_interval>
      <raft_logs_level>information</raft_logs_level>
    </coordination_settings>
    <raft_configuration>
      <secure>true</secure>                     <!-- Keeper <-> Keeper Raft over TLS -->
      <server><id>1</id><hostname>keeper-1.ch.prod.internal</hostname><port>9234</port></server>
      <server><id>2</id><hostname>keeper-2.ch.prod.internal</hostname><port>9234</port></server>
      <server><id>3</id><hostname>keeper-3.ch.prod.internal</hostname><port>9234</port></server>
    </raft_configuration>
  </keeper_server>
  <openSSL>
    <server>
      <certificateFile>/etc/clickhouse-keeper/tls/keeper.crt</certificateFile>
      <privateKeyFile>/etc/clickhouse-keeper/tls/keeper.key</privateKeyFile>
      <caConfig>/etc/clickhouse-keeper/tls/ca-bundle.crt</caConfig>
      <loadDefaultCAFile>false</loadDefaultCAFile>
      <verificationMode>strict</verificationMode>
      <disableProtocols>sslv2,sslv3,tlsv1,tlsv1_1</disableProtocols>
    </server>
    <client>
      <certificateFile>/etc/clickhouse-keeper/tls/keeper.crt</certificateFile>
      <privateKeyFile>/etc/clickhouse-keeper/tls/keeper.key</privateKeyFile>
      <caConfig>/etc/clickhouse-keeper/tls/ca-bundle.crt</caConfig>
      <loadDefaultCAFile>false</loadDefaultCAFile>
      <verificationMode>strict</verificationMode>
      <invalidCertificateHandler><name>RejectCertificateHandler</name></invalidCertificateHandler>
    </client>
  </openSSL>
  <prometheus><endpoint>/metrics</endpoint><port>9363</port><metrics>true</metrics><events>true</events><asynchronous_metrics>true</asynchronous_metrics></prometheus>
</clickhouse>
```

### 5.4 Identity: LDAP directory, access control defaults, roles, users and grants

```xml
<!-- /etc/clickhouse-server/config.d/20-access.xml -->
<clickhouse>
  <ldap_servers>
    <corp_ad>
      <host>ldaps.corp.example.com</host>          <!-- internal NLB over 2+ domain controllers or Entra DS -->
      <port>636</port>
      <enable_tls>yes</enable_tls>
      <tls_minimum_protocol_version>tls1.2</tls_minimum_protocol_version>
      <tls_require_cert>demand</tls_require_cert>
      <tls_ca_cert_file>/etc/clickhouse-server/tls/corp-ad-ca.crt</tls_ca_cert_file>
      <bind_dn>{user_name}@corp.example.com</bind_dn>
      <user_dn_detection>
        <base_dn>OU=Users,DC=corp,DC=example,DC=com</base_dn>
        <search_filter>(&amp;(objectClass=user)(userPrincipalName={bind_dn}))</search_filter>
      </user_dn_detection>
      <verification_cooldown>300</verification_cooldown>   <!-- re-check with AD at most every 5 min -->
    </corp_ad>
  </ldap_servers>

  <user_directories>
    <users_xml><path>users.xml</path></users_xml>           <!-- contains no users except disabled 'default' -->
    <replicated><zookeeper_path>/clickhouse/access/</zookeeper_path></replicated>  <!-- SQL users/roles cluster-wide -->
    <ldap>
      <server>corp_ad</server>
      <role_mapping>
        <base_dn>OU=ClickHouse,OU=Groups,DC=corp,DC=example,DC=com</base_dn>
        <attribute>CN</attribute>
        <scope>subtree</scope>
        <search_filter>(&amp;(objectClass=group)(member={user_dn}))</search_filter>
        <prefix>CH-Prod-</prefix>                            <!-- CH-Prod-role_bi_analyst -> role_bi_analyst -->
      </role_mapping>
    </ldap>
  </user_directories>

  <access_control_improvements>
    <users_without_row_policies_can_read_rows>false</users_without_row_policies_can_read_rows>
    <select_from_system_db_requires_grant>true</select_from_system_db_requires_grant>
    <select_from_information_schema_requires_grant>true</select_from_information_schema_requires_grant>
    <settings_constraints_replace_previous>true</settings_constraints_replace_previous>
    <on_cluster_queries_require_cluster_grant>true</on_cluster_queries_require_cluster_grant>
  </access_control_improvements>
</clickhouse>
```

```xml
<!-- /etc/clickhouse-server/users.d/default-user.xml: neutralize the built-in 'default' user -->
<clickhouse>
  <users>
    <default>
      <password remove="1"/>
      <no_password remove="1"/>
      <password_sha256_hex>__random_64_hex_never_shared__</password_sha256_hex>
      <networks><ip>127.0.0.1</ip></networks>
      <access_management>0</access_management>
      <profile>readonly</profile>
    </default>
  </users>
</clickhouse>
```

```sql
-- Replicated access storage propagates these to every node; no ON CLUSTER needed.

-- 1. Roles
CREATE ROLE role_admin, role_dba, role_platform_engineer, role_data_engineer,
            role_etl_service, role_api_service, role_bi_analyst, role_readonly,
            role_support, role_security_auditor, role_pii_reader;

-- 2. Admin (break-glass only)
GRANT ALL ON *.* TO role_admin WITH GRANT OPTION;

-- 3. DBA: operate the engine, not the access model, not PII
GRANT SYSTEM MERGES, SYSTEM TTL MERGES, SYSTEM MOVES, SYSTEM FETCHES, SYSTEM SENDS,
      SYSTEM REPLICATION QUEUES, SYSTEM SYNC REPLICA, SYSTEM RESTART REPLICA,
      SYSTEM FLUSH LOGS, SYSTEM RELOAD CONFIG, SYSTEM DROP CACHE, KILL QUERY, CLUSTER ON *.* TO role_dba;
GRANT CREATE TABLE, ALTER, DROP TABLE, OPTIMIZE, TRUNCATE ON analytics.* TO role_dba;
GRANT CREATE TABLE, ALTER, DROP TABLE, OPTIMIZE ON staging.* TO role_dba;
GRANT SELECT ON system.* TO role_dba;

-- 4. Platform engineer: observe and reload, no table data
GRANT SELECT ON system.* TO role_platform_engineer;
GRANT SYSTEM FLUSH LOGS, SYSTEM RELOAD CONFIG, SHOW TABLES, SHOW DATABASES ON *.* TO role_platform_engineer;

-- 5. Data engineer: build in staging and analytics; read curated non-PII
GRANT CREATE TABLE, CREATE VIEW, ALTER, DROP TABLE, DROP VIEW, INSERT, SELECT, OPTIMIZE ON staging.* TO role_data_engineer;
GRANT CREATE TABLE, CREATE VIEW, ALTER, INSERT, SELECT ON analytics.* TO role_data_engineer;
GRANT SELECT ON curated.* TO role_data_engineer;
GRANT CREATE TEMPORARY TABLE ON *.* TO role_data_engineer;

-- 6. ETL service: write paths only; S3 reads only through a named collection
GRANT INSERT ON raw.* TO role_etl_service;
GRANT SELECT, INSERT ON staging.* TO role_etl_service;
GRANT SELECT, INSERT, ALTER UPDATE, ALTER DELETE ON analytics.* TO role_etl_service;
GRANT CREATE TEMPORARY TABLE, S3 ON *.* TO role_etl_service;
GRANT NAMED COLLECTION ON s3_landing TO role_etl_service;

-- 7. BI analyst: marts and masked views only
GRANT SELECT ON marts.* TO role_bi_analyst;
GRANT SELECT(event_id, event_time, customer_id, event_type, amount, country) ON curated.events TO role_bi_analyst;
GRANT SELECT ON curated.v_customers_masked TO role_bi_analyst;

-- 8. Read-only
GRANT SELECT ON marts.* TO role_readonly;

-- 9. Support: tenant-scoped views
GRANT SELECT ON support.* TO role_support;

-- 10. Security auditor: access model and audit logs, no business data
GRANT SELECT ON system.query_log, SELECT ON system.session_log, SELECT ON system.users,
      SELECT ON system.roles, SELECT ON system.grants, SELECT ON system.role_grants,
      SELECT ON system.row_policies, SELECT ON system.quotas, SELECT ON system.settings_profiles
      TO role_security_auditor;
GRANT SHOW USERS, SHOW ROLES, SHOW ROW POLICIES, SHOW QUOTAS, SHOW SETTINGS PROFILES ON *.* TO role_security_auditor;

-- 11. PII reader (granted per approved ticket, time-boxed)
GRANT SELECT ON pii.* TO role_pii_reader;

-- Users. Humans come from LDAP; only these are defined in SQL.
CREATE USER admin_breakglass_1 IDENTIFIED WITH sha256_password BY '<from Vault>'
  HOST IP '10.40.60.10/32' DEFAULT ROLE role_admin;
CREATE USER svc_kafka_connect IDENTIFIED WITH ssl_certificate CN 'svc_kafka_connect'
  HOST IP '10.40.48.0/22' DEFAULT ROLE role_etl_service;
CREATE USER svc_airflow IDENTIFIED WITH ssl_certificate CN 'svc_airflow'
  HOST IP '10.40.52.0/24' DEFAULT ROLE role_etl_service;
CREATE USER svc_orders_api IDENTIFIED WITH ssl_certificate CN 'svc_orders_api'
  HOST IP '10.20.0.0/16' DEFAULT ROLE role_api_service;
CREATE USER svc_view_owner IDENTIFIED WITH no_password HOST NONE;   -- definer only, cannot log in
GRANT SELECT ON pii.customers TO svc_view_owner;
CREATE USER svc_ci_deployer IDENTIFIED WITH ssl_certificate CN 'svc_ci_deployer'
  HOST IP '10.40.56.0/24';
GRANT ACCESS MANAGEMENT, CREATE, ALTER, DROP, CLUSTER ON *.* TO svc_ci_deployer;  -- only via reviewed pipeline

-- Verify least privilege
SHOW GRANTS FOR role_bi_analyst;
SELECT * FROM system.role_grants WHERE granted_role_name = 'role_admin';
```

### 5.5 Storage policy and encrypted disks (`config.d/30-storage.xml`)

```xml
<clickhouse>
  <storage_configuration>
    <disks>
      <!-- Raw media -->
      <nvme_raw><type>local</type><path>/data/nvme/clickhouse/</path></nvme_raw>
      <warm_raw><type>local</type><path>/data/warm/clickhouse/</path></warm_raw>
      <s3_raw>
        <type>s3</type>
        <!-- per-replica prefix rendered by Ansible; each replica owns its objects -->
        <endpoint>https://ch-prod-cold-use1.s3.us-east-1.amazonaws.com/data/ch-s01-r1/</endpoint>
        <region>us-east-1</region>
        <use_environment_credentials>true</use_environment_credentials>  <!-- EC2 instance role, no keys -->
        <server_side_encryption_kms_key_id>arn:aws:kms:us-east-1:111122223333:key/0000-ch-prod-s3</server_side_encryption_kms_key_id>
        <server_side_encryption_kms_bucket_key_enabled>true</server_side_encryption_kms_bucket_key_enabled>
        <metadata_path>/data/nvme/clickhouse/disks/s3_raw/</metadata_path>
      </s3_raw>

      <!-- Application-layer AES-256 encryption over each medium -->
      <hot>
        <type>encrypted</type>
        <disk>nvme_raw</disk>
        <path>enc/</path>
        <algorithm>AES_256_CTR</algorithm>
        <key_hex id="1" from_env="CH_DISK_KEY_1"/>
        <key_hex id="2" from_env="CH_DISK_KEY_2"/>
        <current_key_id>2</current_key_id>
      </hot>
      <warm>
        <type>encrypted</type>
        <disk>warm_raw</disk>
        <path>enc/</path>
        <algorithm>AES_256_CTR</algorithm>
        <key_hex id="1" from_env="CH_DISK_KEY_1"/>
        <key_hex id="2" from_env="CH_DISK_KEY_2"/>
        <current_key_id>2</current_key_id>
      </warm>

      <!-- Cold: S3 with a 2 TB local NVMe cache (SSE-KMS at rest) -->
      <cold>
        <type>cache</type>
        <disk>s3_raw</disk>
        <path>/data/nvme/clickhouse/s3_cache/</path>
        <max_size>2Ti</max_size>
      </cold>
      <!-- Cold for PCI/HIPAA tables: client-side encrypted on top of SSE-KMS -->
      <cold_regulated>
        <type>encrypted</type>
        <disk>s3_raw</disk>
        <path>regulated/</path>
        <algorithm>AES_256_CTR</algorithm>
        <key_hex id="1" from_env="CH_REGULATED_KEY_1"/>
        <current_key_id>1</current_key_id>
      </cold_regulated>
    </disks>

    <policies>
      <tiered>
        <volumes>
          <hot><disk>hot</disk></hot>
          <warm><disk>warm</disk></warm>
          <cold><disk>cold</disk><prefer_not_to_merge>true</prefer_not_to_merge></cold>
        </volumes>
        <move_factor>0.1</move_factor>   <!-- spill to next volume when a volume is 90% full -->
      </tiered>
      <tiered_regulated>
        <volumes>
          <hot><disk>hot</disk></hot>
          <warm><disk>warm</disk></warm>
          <cold><disk>cold_regulated</disk><prefer_not_to_merge>true</prefer_not_to_merge></cold>
        </volumes>
      </tiered_regulated>
    </policies>
  </storage_configuration>
</clickhouse>
```

```sql
-- Table using the tiered policy, with TTL moves and a final delete.
CREATE TABLE analytics.events_local ON CLUSTER prod
(
  event_time   DateTime64(3) CODEC(Delta, ZSTD(1)),
  customer_id  UInt64,
  event_type   LowCardinality(String),
  event_id     UUID,
  amount       Decimal(18, 4) CODEC(ZSTD(1)),
  country      LowCardinality(String),
  payload      String CODEC(ZSTD(3))
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/analytics/events_local', '{replica}')
PARTITION BY toYYYYMMDD(event_time)
ORDER BY (customer_id, event_type, event_time)
TTL toDateTime(event_time) + INTERVAL 30 DAY TO VOLUME 'warm',
    toDateTime(event_time) + INTERVAL 90 DAY TO VOLUME 'cold',
    toDateTime(event_time) + INTERVAL 730 DAY DELETE
SETTINGS storage_policy = 'tiered', ttl_only_drop_parts = 1;

CREATE TABLE analytics.events ON CLUSTER prod AS analytics.events_local
ENGINE = Distributed(prod, analytics, events_local, cityHash64(customer_id));
```

An S3 bucket policy denies `s3:PutObject` without `aws:kms` encryption and denies any principal other than the cluster instance role and the backup role. The KMS key policy grants `kms:Decrypt` to those roles only, so even S3 administrators cannot read objects.

### 5.6 System log tables for audit (`config.d/40-logs.xml`)

```xml
<clickhouse>
  <query_log>
    <database>system</database><table>query_log</table>
    <engine>ENGINE = MergeTree PARTITION BY toYYYYMM(event_date) ORDER BY (event_date, event_time)
            TTL event_date + INTERVAL 30 DAY DELETE SETTINGS ttl_only_drop_parts = 1</engine>
    <flush_interval_milliseconds>7500</flush_interval_milliseconds>
  </query_log>
  <session_log>  <!-- authentication events: keep longer on-cluster -->
    <database>system</database><table>session_log</table>
    <engine>ENGINE = MergeTree PARTITION BY toYYYYMM(event_date) ORDER BY (event_date, event_time)
            TTL event_date + INTERVAL 90 DAY DELETE SETTINGS ttl_only_drop_parts = 1</engine>
    <flush_interval_milliseconds>7500</flush_interval_milliseconds>
  </session_log>
  <part_log>
    <database>system</database><table>part_log</table>
    <engine>ENGINE = MergeTree PARTITION BY toYYYYMM(event_date) ORDER BY (event_date, event_time)
            TTL event_date + INTERVAL 30 DAY DELETE SETTINGS ttl_only_drop_parts = 1</engine>
    <flush_interval_milliseconds>7500</flush_interval_milliseconds>
  </part_log>
  <text_log>
    <level>warning</level>
    <database>system</database><table>text_log</table>
    <engine>ENGINE = MergeTree PARTITION BY toYYYYMM(event_date) ORDER BY (event_date, event_time)
            TTL event_date + INTERVAL 30 DAY DELETE SETTINGS ttl_only_drop_parts = 1</engine>
    <flush_interval_milliseconds>7500</flush_interval_milliseconds>
  </text_log>
  <query_thread_log>  <!-- table exists for investigations; populated only when log_query_threads = 1 -->
    <database>system</database><table>query_thread_log</table>
    <engine>ENGINE = MergeTree PARTITION BY event_date ORDER BY (event_date, event_time)
            TTL event_date + INTERVAL 3 DAY DELETE SETTINGS ttl_only_drop_parts = 1</engine>
    <flush_interval_milliseconds>7500</flush_interval_milliseconds>
  </query_thread_log>
</clickhouse>
```

```xml
<!-- users.d/log-settings.xml: applied to every profile through the default profile -->
<clickhouse>
  <profiles>
    <default>
      <log_queries>1</log_queries>
      <log_queries_min_type>QUERY_START</log_queries_min_type>   <!-- capture queries that never finish -->
      <log_queries_min_query_duration_ms>0</log_queries_min_query_duration_ms>
      <log_query_threads>0</log_query_threads>
      <log_profile_events>1</log_profile_events>
    </default>
  </profiles>
</clickhouse>
```

**Log retention strategy**

| Tier | Where | Retention | Purpose |
| --- | --- | --- | --- |
| Operational | ClickHouse system tables | 30 days (90 days for `session_log`) | Troubleshooting, capacity, fast audit queries |
| SIEM hot | Splunk / Microsoft Sentinel | 90 days searchable | Detection rules, investigations |
| Audit archive | S3 in the security account, Object Lock compliance mode, Parquet by day | 13 months | SOC 2 / ISO 27001 / PCI-DSS 10.5.1 (12 months, 3 immediately available) |
| Long-term | S3 Glacier Deep Archive, same lock | 7 years for regulated datasets only | HIPAA documentation retention (6 years), legal hold |

Export job (every 5 minutes, idempotent by `event_time` watermark): `INSERT INTO FUNCTION s3('https://sec-audit-archive.s3.amazonaws.com/ch/prod/query_log/{_partition_id}.parquet', 'Parquet') PARTITION BY toYYYYMMDD(event_time) SELECT * FROM clusterAllReplicas('prod', system.query_log) WHERE event_time > {watermark:DateTime}`. It runs as a dedicated `svc_audit_export` user that can read system logs and write only to that bucket's endpoint.

## 6. Operational runbooks

Operations rest on three things: every alert maps to a runbook, every change reaches production through one pipeline, and day-2 tasks are scripted, not improvised.

### 6.1 Monitoring and observability stack

| Layer | Collector | Store | Why |
| --- | --- | --- | --- |
| ClickHouse server | Built-in Prometheus endpoint (9363) + `clickhouse-sql-exporter` queries on `system.*` (mutations, replication queue, query latency percentiles) | Amazon Managed Prometheus (or Mimir), 13 months | Engine health, ingestion, query performance |
| Keeper | Keeper Prometheus endpoint (9363) + `mntr` four-letter-word scrape | Same | Quorum, latency, znode growth |
| OS, disk, network | OpenTelemetry Collector (`hostmetrics` receiver) or node\_exporter; `smartctl` exporter for NVMe | Same | Saturation and hardware faults |
| Logs | OpenTelemetry Collector `filelog` receiver on `/var/log/clickhouse-server/*.log` | Loki, 30 days | Error correlation with metrics |
| Traces | ClickHouse honors W3C `traceparent` from clients and writes spans to `system.opentelemetry_span_log`; an exporter ships them to Tempo | Tempo, 7 days | End-to-end latency from BI tool to shard |
| Synthetic | Blackbox exporter: TLS handshake on 8443/9440 (cert expiry), `SELECT 1` through chproxy every 30 s | Prometheus | User-visible availability, the SLO numerator |
| Alerting | Alertmanager: critical to PagerDuty, warning to the team channel, inhibition rules (node down suppresses its replica-lag alerts) | n/a | Fewer, actionable pages |

**Critical metrics and thresholds**

| Component | Metric (Prometheus name or source) | Warning | Critical | Runbook |
| --- | --- | --- | --- | --- |
| Availability | Synthetic `SELECT 1` success through chproxy | below 99.95% over 1 h | 3 consecutive failures | 6.4 |
| Replication | `ClickHouseAsyncMetrics_ReplicasMaxAbsoluteDelay` | above 300 s | above 1,800 s | 6.4 |
| Replication | `ClickHouseMetrics_ReadonlyReplica` | n/a | above 0 | 7.4 |
| Parts | `ClickHouseAsyncMetrics_MaxPartCountForPartition` | above 500 | above 1,000 (inserts are delayed at 1,000, rejected at 3,000 by default) | 6.4 |
| Inserts | `rate(ClickHouseProfileEvents_DelayedInserts[5m])` / `RejectedInserts` | delayed above 0 | rejected above 0 | 6.4 |
| Ingestion lag | Kafka Connect consumer-group lag (time) | above 5 min | above 15 min (RPO at risk) | 6.4 |
| Memory | `ClickHouseMetrics_MemoryTracking` / host RAM | above 75% | above 90% | 6.4 |
| Concurrency | `ClickHouseMetrics_Query` | above 250 | above 350 (limit 400) | 6.4 |
| Errors | `rate(ClickHouseProfileEvents_FailedQuery)` / `rate(...Query)` | above 2% | above 5% | 6.4 |
| Query latency | BI p95 from `system.query_log` via sql-exporter | above 5 s | above 20 s | 6.4 |
| Mutations | `system.mutations` with `is_done = 0` older than | 1 h | 6 h | 6.4 |
| Distributed queue | `ClickHouseMetrics_DistributedFilesToInsert` | above 100 | above 1,000 | 6.4 |
| Keeper | `zk_avg_latency` (mntr) | above 10 ms | above 50 ms | 7.4 |
| Keeper | `zk_outstanding_requests` | above 100 | above 1,000 | 7.4 |
| Keeper | Followers in quorum (`zk_synced_followers`) | n/a | below 2 | 7.4 |
| Keeper | `zk_znode_count` growth | above 20% per week | above 40 M | 6.4 |
| Disk | Free space on hot volume | below 30% | below 15% | 6.4 |
| Disk | Free space on Keeper log/snapshot volumes | below 30% | below 15% | 7.4 |
| Disk | NVMe media errors (smartctl) | above 0 | Critical warning flag set | 6.4 |
| CPU | iowait on data nodes | above 20% for 15 min | above 40% for 15 min | 6.4 |
| Network | NIC errors / drops, conntrack table use | above 0 / above 70% | n/a / above 90% | 6.4 |
| TLS | `probe_ssl_earliest_cert_expiry - time()` | below 14 days | below 3 days | 4.2 |
| Backup | Age of last successful full / incremental backup | above 26 h / above 2 h | above 50 h / above 6 h | 7.3 |
| Security | Failed logins per source in 5 min; any `role_admin` login | 10 failures | 50 failures; any break-glass login | 4.9 |

```yaml
# Alertmanager / Prometheus rules (excerpt)
groups:
- name: clickhouse-critical
  rules:
  - alert: ClickHouseReadonlyReplica
    expr: ClickHouseMetrics_ReadonlyReplica > 0
    for: 2m
    labels: {severity: critical, team: dbre}
    annotations:
      summary: "{{ $labels.instance }} has read-only replicas (Keeper session lost)"
      runbook: "https://wiki.example.com/ch/runbooks/7.4"
  - alert: ClickHouseTooManyParts
    expr: ClickHouseAsyncMetrics_MaxPartCountForPartition > 1000
    for: 5m
    labels: {severity: critical, team: dbre}
  - alert: ClickHouseReplicationLag
    expr: ClickHouseAsyncMetrics_ReplicasMaxAbsoluteDelay > 1800
    for: 10m
    labels: {severity: critical, team: dbre}
  - alert: ClickHouseHotDiskFull
    expr: node_filesystem_avail_bytes{mountpoint="/data/nvme"} / node_filesystem_size_bytes{mountpoint="/data/nvme"} < 0.15
    for: 10m
    labels: {severity: critical, team: dbre}
  - alert: KeeperQuorumDegraded
    expr: keeper_mntr_zk_synced_followers{role="leader"} < 2
    for: 1m
    labels: {severity: critical, team: dbre}
  - alert: IngestionLagRPOAtRisk
    expr: max by (connector) (kafka_connect_consumer_lag_seconds) > 900
    for: 5m
    labels: {severity: critical, team: data-eng}
```

**Example Grafana dashboards**

| Dashboard | Audience | Panels |
| --- | --- | --- |
| Cluster overview | On-call | SLO burn rate; nodes up by AZ; read-only replicas; max replication delay; queries/s and failed %; memory per node; hot disk free per node |
| Ingestion | Data engineering | Rows/s and bytes/s by table; Kafka lag per connector; insert latency p95; parts per partition (top 10); delayed/rejected inserts; distributed queue |
| Query performance | DBRE, BI owners | p50/p95/p99 by user class; concurrent queries vs limit; top 20 queries by read bytes and memory (from `query_log`); quota consumption by user; workload CPU share |
| Keeper | DBRE | Leader and followers; avg/max latency; outstanding requests; znode count and data size; snapshot age; log disk latency |
| Storage tiers | Capacity planning, FinOps | Bytes per volume (hot/warm/cold) per shard; TTL move backlog; S3 requests/s and cache hit rate; 90-day growth projection |
| Security | Security operations | Logins success/failure by source; `ACCESS_DENIED` rate; grants and DDL timeline; export-pattern queries; break-glass usage |

### 6.2 CI/CD and DevSecOps

| Capability | Tooling | What it enforces | Risk if omitted |
| --- | --- | --- | --- |
| Infrastructure as Code | Terraform (VPC, SGs, EC2/ASG, KMS, S3, IAM, PrivateLink); remote state in S3 + DynamoDB lock, state bucket in a separate account | All infrastructure reproducible and reviewed | Console changes nobody can rebuild during DR |
| Configuration management | Ansible roles `os_hardening`, `clickhouse_server`, `clickhouse_keeper`, `vault_agent`; rolling `serial: 1` per shard replica | Identical, versioned config on every node | Snowflake nodes that behave differently under failure |
| Schema and RBAC as code | SQL migrations (versioned, forward-only) applied by `svc_ci_deployer`; RBAC in `access/*.sql` | DDL and grants reviewed like code | Ad-hoc grants accumulate; no audit trail of who approved |
| Pipelines | GitHub Actions (or Azure DevOps with the same stages); environment protection rules with required reviewers for prod | Two-person rule on every production change | Single engineer can push a destructive change |
| GitOps for K8s components | ArgoCD syncing Prometheus, Grafana, Alertmanager, chproxy, Kafka Connect on EKS | Desired state continuously reconciled | Monitoring drifts silently |
| Drift detection | Nightly `terraform plan -detailed-exitcode`, `ansible-playbook --check --diff`, and an RBAC diff of `SHOW ACCESS` against Git | Out-of-band changes found within 24 h | Manual hotfixes never reconciled |
| Secrets scanning | gitleaks in pre-commit and CI; GitHub push protection | No credential reaches Git | Leaked secrets are the most common breach root cause |
| Vulnerability scanning | Trivy on AMIs and container images; Inspector on running EC2; Dependabot | Patch SLA: critical 7 days, high 30 days | Known-exploited CVEs in production |
| Policy as code | Checkov + OPA/Conftest on Terraform plans (no `0.0.0.0/0`, KMS required, no public S3, IMDSv2 only); custom Conftest rules on ClickHouse XML (no `http_port`, `tcp_port`, `verificationMode` must be `strict`) | Security baseline cannot regress | A single PR can reopen a plaintext port |

### 6.3 Repository and deployment pipeline

**Repository structure**

```text
clickhouse-platform/
├── terraform/
│   ├── modules/            # vpc, security-groups, clickhouse-nodes, keeper-nodes, kms, s3-tiers, privatelink, backup-vault
│   └── envs/{prod-use1,dr-usw2,staging}/
├── ansible/
│   ├── inventories/{prod,dr,staging}/
│   ├── roles/{os_hardening,clickhouse_server,clickhouse_keeper,vault_agent,otel_collector}/
│   └── playbooks/{site,rolling_upgrade,replace_node,rotate_disk_key}.yml
├── clickhouse/
│   ├── config.d/           # templated XML from Section 5
│   ├── users.d/
│   ├── access/             # roles, profiles, quotas, row policies (*.sql)
│   └── migrations/         # V001__create_raw.sql, ...
├── policies/
│   ├── terraform/*.rego
│   └── clickhouse/*.rego
├── monitoring/
│   ├── alerts/*.yaml
│   └── dashboards/*.json
├── runbooks/*.md
├── argocd/applications/*.yaml
└── .github/workflows/{pr.yml,deploy.yml,drift.yml}
```

```yaml
# .github/workflows/pr.yml (excerpt)
name: pr-checks
on: pull_request
permissions: {contents: read, id-token: write, pull-requests: write}
jobs:
  security:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with: {fetch-depth: 0}
      - uses: gitleaks/gitleaks-action@v2
      - uses: aquasecurity/trivy-action@0.28.0
        with: {scan-type: config, scan-ref: ., exit-code: "1", severity: "HIGH,CRITICAL"}
      - uses: bridgecrewio/checkov-action@v12
        with: {directory: terraform, framework: terraform}
  plan:
    needs: security
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: aws-actions/configure-aws-credentials@v4
        with: {role-to-assume: arn:aws:iam::111122223333:role/gha-plan, aws-region: us-east-1}
      - run: terraform -chdir=terraform/envs/prod-use1 init -input=false
      - run: terraform -chdir=terraform/envs/prod-use1 plan -out=tfplan -input=false
      - run: terraform -chdir=terraform/envs/prod-use1 show -json tfplan > plan.json
      - run: conftest test plan.json -p policies/terraform
      - run: conftest test clickhouse/config.d -p policies/clickhouse --parser xml
      - run: ansible-lint ansible/
```

```rego
# policies/clickhouse/no_plaintext.rego
package main
deny[msg] {
  input.clickhouse.tcp_port
  not input.clickhouse.tcp_port["-remove"]
  msg := "plaintext native port (tcp_port) must be removed"
}
deny[msg] {
  input.clickhouse.openSSL.server.verificationMode != "strict"
  msg := "openSSL.server.verificationMode must be strict (mutual TLS)"
}
```

Deployment order for a ClickHouse change: staging, then a canary of one replica per shard in production (replicas `r2`), 30 minutes of SLO observation, then the remaining replicas, one shard at a time, gated on replication delay below 60 s.

### 6.4 Day-2 runbooks

**Rolling upgrade (minor or LTS patch)**

1. Confirm release notes for backward-incompatible changes and test in staging for 7 days.
2. For each shard, on replica `r2` first: drain from chproxy, run `SYSTEM STOP MERGES`, wait for running queries to finish (max 10 min), upgrade the package, restart.
3. Verify `SELECT version()`, `system.replicas` (`is_readonly = 0`, `absolute_delay < 60`), then return the replica to chproxy.
4. Repeat for `r1` after the whole cluster's `r2` replicas have run for 24 hours. Upgrade Keeper last, followers first, leader last.

**Replace a failed data node**

1. Terraform replaces the instance with the same hostname and macros; Ansible applies the role.
2. If the old replica's metadata remains in Keeper, run `SYSTEM DROP REPLICA 'ch-s05-r2' FROM ZKPATH '/clickhouse/tables/05/analytics/events_local'` from a healthy node.
3. Create tables from Git migrations; replication fetches all parts from the peer automatically.
4. Track `system.replication_queue` until empty; expect about 5-6 hours for 19 TB. Add the node back to chproxy only when `absolute_delay < 60`.

**Add shards (capacity)**

1. Add the new shards to `remote_servers` with a higher `<weight>` (for example 3 versus 1) so new inserts favor them, which avoids moving existing data.
2. Return weights to 1 once disk usage is level across shards (TTL expiry does the rebalancing over the 30/90-day tiers).
3. If co-location by `customer_id` must be preserved, re-shard instead: create a new table on the new layout and backfill with `INSERT INTO ... SELECT` per partition.

**Too many parts / delayed inserts**

1. Find the writer: `SELECT table, user, count() FROM system.part_log WHERE event_type = 'NewPart' AND event_time > now() - INTERVAL 10 MINUTE GROUP BY ALL ORDER BY 3 DESC`.
2. Fix the cause: batch size below 100k rows, too many partitions per insert, or `async_insert = 0` on a chatty client.
3. As a temporary measure, raise background merge pool threads on affected nodes; never raise `parts_to_throw_insert` as a fix.

**Stuck mutation**

1. `SELECT * FROM system.mutations WHERE is_done = 0` and read `latest_fail_reason`.
2. Fix the cause (often a type error in the expression), then `KILL MUTATION WHERE mutation_id = '...'` and re-issue it corrected.

**Kill a runaway query**

`KILL QUERY WHERE query_id = '...'` (DBA role). If a class of queries repeats, tighten that role's profile in Git rather than killing by hand.

## 7. Disaster recovery plan

Recovery uses three independent copies, each for a different failure. Replicas cover node and AZ loss (RPO 0). The DR region covers region loss (RPO under 6 minutes). Immutable backups plus 7-day Kafka replay cover corruption, accidental drops and ransomware.

### 7.1 Backup architecture

| Element | Design | Why required | Risk if omitted |
| --- | --- | --- | --- |
| Tool | Native `BACKUP` / `RESTORE ... ON CLUSTER` to S3 (Altinity `clickhouse-backup` is the fallback if per-shard scheduling is needed) | Consistent per-shard snapshots; S3-disk parts copied server-side with S3 CopyObject, so cold data never streams through nodes | Volume snapshots of NVMe are impossible (instance store) and EBS snapshots are not ClickHouse-consistent |
| Schedule | Full weekly (Sunday 01:00 UTC); incremental daily (`base_backup` = previous backup); hourly incrementals for the small set of tables fed by direct application inserts | Keeps daily backup volume near the daily ingest (2.5 TB), not the 1.8 PB total | Daily fulls of a petabyte are slower than a day |
| Destination | `ch-backup-prod-use1` bucket in a dedicated **backup AWS account**, cross-account write-only role; SSE-KMS with a backup-account CMK | Production admins cannot delete backups | Ransomware with prod credentials deletes backups first |
| Immutability | S3 Object Lock, compliance mode, 35-day retention; monthly fulls retained 12 months | Not even the root user can delete locked objects before expiry | Malicious admin or compromised automation erases recovery points |
| Cross-region | S3 Cross-Region Replication to `ch-backup-prod-usw2` in the same backup account, also Object Lock | Backups survive a region loss | Region outage takes primary and its backups together |
| Replay source | Kafka (MSK) retention 7 days on all ingest topics; consumer offsets recorded with each backup's timestamp | Restore-then-replay closes the gap between the last backup and the incident | Every restore loses up to 24 hours of data |
| Verification | Weekly automated restore of one rotating database into the staging cluster, row counts and checksums compared; quarterly full-DR game day | An untested backup is an assumption | Discovering a broken backup chain during an incident |

```sql
-- Weekly full (credentials come from the instance role; ASYNC returns a backup id to poll)
BACKUP DATABASE analytics, DATABASE curated, DATABASE pii ON CLUSTER prod
  TO S3('https://ch-backup-prod-use1.s3.us-east-1.amazonaws.com/prod/full-2026-10-18/')
  ASYNC;

-- Daily incremental on top of the previous backup
BACKUP DATABASE analytics, DATABASE curated, DATABASE pii ON CLUSTER prod
  TO S3('https://ch-backup-prod-use1.s3.us-east-1.amazonaws.com/prod/incr-2026-10-22/')
  SETTINGS base_backup = S3('https://ch-backup-prod-use1.s3.us-east-1.amazonaws.com/prod/incr-2026-10-21/')
  ASYNC;

-- Progress and outcome
SELECT id, name, status, error, formatReadableSize(total_size), start_time, end_time
FROM clusterAllReplicas('prod', system.backups) ORDER BY start_time DESC LIMIT 20;

-- Restore one table under a new name for inspection (never over the live table first)
RESTORE TABLE analytics.events_local AS analytics.events_local_restored ON CLUSTER prod
  FROM S3('https://ch-backup-prod-use1.s3.us-east-1.amazonaws.com/prod/incr-2026-10-21/');
```

### 7.2 RPO and RTO calculations

| Scenario | RPO derivation | RPO | RTO derivation | RTO | Meets 15 min / 4 h? |
| --- | --- | --- | --- | --- | --- |
| Node or disk loss | Data already on the peer replica | 0 | Automatic query failover; rebuild runs in background | 0 (redundancy restored in about 6 h) | Yes |
| AZ loss | Every shard has a replica in another AZ; Keeper keeps 2/3 | 0 | No failover needed | 0 | Yes |
| Region loss | MirrorMaker 2 lag (p99 under 60 s) + DR ingest lag (alert at 5 min) | under 6 min | Detection 15 min + decision 30 min + DNS / PrivateLink switch 30 min + validation 30 min | about 1 h 45 min | Yes |
| Accidental `DROP` / bad mutation (one table) | Last daily incremental + Kafka replay from that offset | under 15 min for Kafka-fed tables; up to 1 h for app-insert tables | Largest table hot + warm is about 9 TB per shard copy, restored at about 1 GB/s per node in parallel; cold parts by server-side copy | 2-3 h | Yes |
| Logical corruption cluster-wide | As above | under 15 min (Kafka-fed) | Full hot+warm restore: 225 TB / (24 nodes x 1 GB/s) = about 2.6 h; last 7 days restored first so dashboards return in about 1 h | about 4 h | Borderline: rehearse quarterly |
| Ransomware with prod admin access | Locked backups + DR in a separate account | under 15 min if DR is clean; else last backup + replay | Promote DR if uncompromised (about 2 h); otherwise rebuild a clean prod account from Terraform and restore (8-12 h) | 2 h (DR) / 8-12 h (rebuild) | Rebuild path exceeds 4 h: accept as a documented exception, or keep the DR account fully separate so it stays clean |

### 7.3 Backup operations

- Alerts: no successful incremental for 26 hours (warning) or 50 hours (critical); any backup with `status = 'BACKUP_FAILED'` pages.
- The weekly full deliberately starts a new chain, so a restore never walks more than 7 incrementals.
- Each backup run writes a manifest row to `governance.backup_catalog`: backup URL, start and end, Kafka offsets per topic at start, row counts per table. Restores read it to know where to start replay.
- The GDPR suppression list (Section 4.7) is re-applied automatically after every restore.

### 7.4 Runbook: Keeper quorum loss

**Symptoms:** `ReadonlyReplica > 0` on many nodes; inserts fail with `TABLE_IS_READ_ONLY` or Keeper session errors; SELECTs still work.

1. Check each Keeper: `echo mntr | openssl s_client -quiet -connect keeper-N.ch.prod.internal:9281 -cert ... -key ...` and confirm `zk_server_state`. Check disk space and log-volume latency first; a full snapshot disk is the most common cause.
2. **One node down, quorum intact:** no client impact. Replace the node; it rejoins and syncs from the leader.
3. **Two nodes down but recoverable** (process crash, disk full): fix the cause and restart them. Quorum returns and replicas leave read-only within seconds; ingest backs up in Kafka and then drains.
4. **Two nodes permanently lost:** on the survivor, stop Keeper and restart it once with `clickhouse-keeper --force-recovery`. Provision two new nodes with the same `raft_configuration`, start them, and confirm `zk_synced_followers = 2`.
5. **All Keeper data lost:** start a fresh 3-node Keeper, then on one replica per shard run `SYSTEM RESTORE REPLICA analytics.events_local` for every replicated table. ClickHouse rebuilds the Keeper metadata from local parts; the second replica re-attaches with the same command.
6. **Verify:** `SELECT count() FROM clusterAllReplicas('prod', system.replicas) WHERE is_readonly` returns 0, then Kafka lag drains below 5 minutes.
7. **Post-incident:** record time-to-quorum; any recovery over 30 minutes becomes a problem ticket.

### 7.5 Runbook: region failover to us-west-2

1. **Declare** (incident commander + data platform owner): the primary region has been unavailable or degraded for over 30 minutes with no ETA.
2. **Freeze writes** to the primary if any part is still reachable (stop Kafka Connect in us-east-1) to avoid split ingestion.
3. **Confirm DR currency:** DR consumer lag below 5 minutes; record the last offsets applied per topic.
4. **Switch traffic:** point the Route 53 private record `clickhouse.prod.internal` at the DR chproxy NLB (TTL 60 s) and switch PrivateLink consumers to the DR endpoint service.
5. **Protect capacity:** DR runs one replica per shard, so apply the stricter BI quotas (`quota_bi_degraded`) and suspend ad-hoc workloads. Add a second replica per shard (Terraform `replicas_per_shard = 2`, about 6 h to sync).
6. **Validate:** synthetic checks green, row counts for the last hour match the Kafka offsets, top 10 dashboards load.
7. **Fail back** later: rebuild or resync us-east-1 as the standby from the DR region (MirrorMaker in reverse), then repeat this runbook in the opposite direction in a planned window.

### 7.6 Runbook: restore after accidental drop, corruption or ransomware

1. **Contain:** for suspected compromise, disable the actor in AD (or `DROP USER` for SQL users), rotate the cluster secret and break-glass passwords, and preserve `query_log` and CloudTrail evidence.
2. **Pick the recovery point** from `governance.backup_catalog`: the last backup before the incident's first harmful query (found in `query_log`).
3. **Restore into a side table or a clean cluster**, never over live data first: `RESTORE TABLE ... AS ..._restored`.
4. **Replay** Kafka from the offsets stored with that backup up to the incident time. For corruption caused by a bad deploy that is already fixed, replay up to now.
5. **Validate** counts and checksums against the source, then swap with `EXCHANGE TABLES analytics.events_local AND analytics.events_local_restored ON CLUSTER prod`.
6. **Re-apply** the GDPR suppression list and confirm row policies and grants are unchanged (`SHOW ACCESS` diff against Git).

## 8. Hardening checklist

Each item is verifiable by a command or a policy check. CI enforces those tagged (policy), and the nightly drift job re-checks them.

**Operating system**

- [ ] Hardened base AMI built by Packer from CIS Level 1 (Amazon Linux 2023 or RHEL 9), rebuilt monthly (policy)
- [ ] IMDSv2 required, hop limit 1 (policy)
- [ ] Swap disabled; `vm.swappiness = 1`; `vm.max_map_count = 1048576`; THP `madvise` (5.1, 5.2)
- [ ] NVMe and EBS scheduler `none`; ext4 `noatime`; RAID 0 on instance store, verified with `mdadm --detail`
- [ ] systemd override with `LimitNOFILE=1048576`, `LimitCORE=0`, `ProtectSystem=strict`, `NoNewPrivileges=true`
- [ ] No SSH daemon listening; access only through SSM Session Manager with session recording
- [ ] SELinux enforcing (RHEL) or AppArmor profile; auditd shipping to the SIEM
- [ ] chrony against the Amazon Time Sync Service; clock skew alert above 100 ms
- [ ] Unattended security patches staged through the AMI pipeline; critical CVEs patched within 7 days

**Network**

- [ ] No public IPs, no IGW routes in data-plane subnets; SCP denies EIP association (policy)
- [ ] Security groups reference security groups, never `0.0.0.0/0` (policy)
- [ ] NACL guardrails on data and Keeper subnets
- [ ] Egress through Network Firewall with an FQDN allowlist; VPC endpoints for S3, KMS, Secrets Manager, STS, SSM, Logs
- [ ] S3 gateway endpoint policy limited to the cluster's own buckets
- [ ] Host nftables default-drop with ClickHouse port allowlist
- [ ] VPC Flow Logs enabled to the security account

**ClickHouse server**

- [ ] `http_port`, `tcp_port`, `interserver_http_port`, `mysql_port`, `postgresql_port` removed (policy)
- [ ] `openSSL.server.verificationMode = strict`, TLS 1.0/1.1 disabled, ECDHE-GCM ciphers only (policy)
- [ ] Cluster `<secret>` set; interserver credentials set; both from Secrets Manager
- [ ] Built-in `default` user locked to localhost, random password, no access management
- [ ] `access_control_improvements` set as in 5.4, including default-deny row policies
- [ ] Replicated access storage; no users in `users.xml` besides `default`
- [ ] Every role has a settings profile with locked maximums; every human and service role has a quota
- [ ] `max_table_size_to_drop` and `max_partition_size_to_drop` = 50 GB
- [ ] `query_masking_rules` active; `query_log`, `session_log`, `part_log`, `text_log` with TTL
- [ ] Encrypted disks for hot and warm tiers; S3 SSE-KMS with CMK; regulated tables on `tiered_regulated`
- [ ] Table functions `file`, `url`, `s3`, `remote` granted to no human role
- [ ] Version is a supported LTS, within one patch release of current

**ClickHouse Keeper**

- [ ] Dedicated nodes, one per AZ; separate volumes for logs and snapshots
- [ ] Only `tcp_port_secure` (9281); Raft `<secure>true</secure>`; mTLS on both
- [ ] `four_letter_word_white_list` limited to `ruok,mntr,srvr,stat,conf`
- [ ] Digest identity configured on all clients, so znodes carry ACLs
- [ ] `force_sync = true`; snapshot and log disk free-space alerts
- [ ] Quorum-loss runbook (7.4) rehearsed in staging each quarter

## 9. Compliance mapping

Every in-scope control maps to a platform mechanism and to evidence an auditor can collect without engineering help. One gap is structural: both regions are in the US, so EU personal data under GDPR needs an EU-region deployment or a documented transfer mechanism (SCCs plus a transfer impact assessment) before go-live.

| Control area | SOC 2 (TSC) | ISO 27001:2022 Annex A | GDPR | HIPAA (45 CFR) | PCI-DSS v4.0 | Platform implementation | Evidence |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Least-privilege access | CC6.1, CC6.3 | 5.15, 5.18, 8.2 | Art. 25, 32 | 164.312(a)(1) | 7.2 | 11 roles, no direct user grants, column grants, row policies (4.3, 5.4) | `SHOW ACCESS` export; `system.grants`, `system.role_grants` |
| Authentication and MFA | CC6.1 | 5.17, 8.5 | Art. 32 | 164.312(d) | 8.3, 8.4 | LDAPS to AD/Entra; MFA at VPN and BI SSO; mTLS for services | IdP conditional-access policy; `session_log` sample |
| Access reviews | CC6.2 | 5.18 | Art. 32 | 164.308(a)(4) | 7.2.4 | Quarterly review of role grants vs AD groups (4.4) | Signed review tickets |
| Network segmentation | CC6.6 | 8.20, 8.22 | Art. 32 | 164.312(e)(1) | 1.2-1.4 | Private subnets, SG-to-SG rules, NACLs, PrivateLink, no SSH (4.1) | Terraform plan, Config rules, Flow Logs |
| Encryption in transit | CC6.7 | 8.24 | Art. 32 | 164.312(e)(2)(ii) | 4.2 | TLS 1.2+ and mTLS on every port; plaintext ports removed (4.2, 5.3) | Config files; TLS probe results |
| Encryption at rest and key management | CC6.1 | 8.24 | Art. 32 | 164.312(a)(2)(iv) | 3.5, 3.6, 3.7 | Encrypted disks, EBS and S3 CMKs, key rotation procedure (4.6, 5.5) | KMS key policies, rotation logs |
| Data masking and pseudonymization | C1.1 | 8.11 | Art. 25, 32 | 164.514(b) | 3.4.1 | Masked views, HMAC pseudonymization, log masking rules (4.7) | View DDL; `query_masking_rules` |
| Logging and monitoring | CC7.2 | 8.15, 8.16 | Art. 33 (detection) | 164.312(b) | 10.2, 10.5.1, 10.7 | System logs to immutable archive and SIEM; detections (4.9, 5.6) | Object Lock config; SIEM rule list; sample alerts |
| Vulnerability management | CC7.1 | 8.8 | Art. 32 | 164.308(a)(1) | 6.3, 11.3 | Trivy, Inspector, patch SLAs (6.2) | Scan reports, patch tickets |
| Change management | CC8.1 | 8.32 | Art. 32 | 164.308(a)(1) | 6.5 | Git PRs, required reviewers, policy gates, drift detection (6.2) | PR history, pipeline logs |
| Backup and recovery | A1.2, A1.3 | 8.13, 5.30 | Art. 32(1)(c) | 164.308(a)(7) | 12.10.1 | Immutable cross-account backups, DR region, tested restores (7) | Backup catalog, restore test reports, game-day notes |
| Retention, minimization and erasure | C1.2, P4.2 | 8.10 | Art. 5(1)(c), 5(1)(e), 17 | 164.310(d)(2) | 3.2.1 | TTL per data class, column TTL, erasure mutations, suppression list (4.7) | Retention schedule; erasure request log |
| Incident response | CC7.3-CC7.5 | 5.24-5.26 | Art. 33, 34 (72 h) | 164.308(a)(6) | 12.10 | Runbooks 7.4-7.6, SIEM paging, evidence preservation | Incident records, tabletop results |
| Data residency | n/a | 5.31 | Ch. V (Art. 44-49) | n/a | n/a | **Gap:** US-only regions | Transfer impact assessment or EU cluster |

**Scoping notes**

- **PCI-DSS:** keep cardholder data out of this platform. Tokenize PANs upstream and store only tokens. If PANs must land, put them in a separate cluster as its own cardholder-data environment; otherwise the whole cluster and its connected systems are in scope.
- **HIPAA:** PHI datasets use `tiered_regulated` storage, a dedicated `phi` database, `role_pii_reader`-style time-boxed grants, and 6-year log retention. A BAA with AWS must be in place for every service used (EC2, S3, KMS, MSK).
- **GDPR:** records of processing (Art. 30) list each ClickHouse database with purpose, lawful basis and retention. Erasure requests target `pii.customers` within 30 days, and the suppression list makes them survive restores.

## 10. Production readiness assessment

As designed, the platform scores **8.2 out of 10**. Current state is **1 out of 10**, because no component is deployed yet. The three gaps that block go-live are EU data residency, the ransomware rebuild RTO, and the untested Keeper and region runbooks.

### 10.1 Readiness checklists

The hardening items in Section 8 are prerequisites and are not repeated here.

**Security**

- [ ] External penetration test of chproxy, PrivateLink endpoints and the BI path; all high findings closed
- [ ] STRIDE mitigations (4.10) each have a named owner and a test
- [ ] SIEM detections for brute force, exfiltration patterns, grants and break-glass use firing in staging
- [ ] Break-glass procedure tested: retrieval needs two people, use pages security
- [ ] Certificate rotation exercised end to end with a 1-hour test TTL in staging

**Infrastructure**

- [ ] Load test at 2x expected peak: 40 TB/day ingest and 600 concurrent queries, with p95 latency recorded per user class
- [ ] AZ failure simulated (stop all nodes in one AZ) with no failed inserts and no SLO breach
- [ ] Node replacement timed end to end; warm-tier EBS volumes re-attached rather than re-fetched
- [ ] Capacity plan for warm tier exhaustion (about 9 months) approved and budgeted

**Backup and DR**

- [ ] First full backup and 7 daily incrementals complete; Object Lock verified by a failed delete attempt
- [ ] Table restore plus Kafka replay rehearsed, with measured RPO and RTO
- [ ] Region failover game day completed within the 4-hour RTO
- [ ] Keeper quorum-loss runbook (7.4) rehearsed, including `--force-recovery` and `SYSTEM RESTORE REPLICA`

**Compliance**

- [ ] Data classification of every database (public, internal, confidential, PII, PHI, PCI) recorded
- [ ] Records of processing and retention schedule approved by the DPO
- [ ] EU residency decision taken (EU cluster or transfer impact assessment)
- [ ] Evidence collection for each row of Section 9 automated or assigned
- [ ] AWS BAA in place if PHI is in scope

**Operational**

- [ ] Every critical alert links to a runbook; on-call rotation of at least 6 engineers trained
- [ ] SLOs published: 99.95% availability, BI p95 under 5 s, ingest freshness under 5 min
- [ ] Dashboards from 6.1 live; alert noise reviewed after 2 weeks in staging
- [ ] Upgrade policy: LTS only, staging soak 7 days, canary replicas first
- [ ] Cost dashboard by tier and by team (FinOps tags on every resource)

### 10.2 Maturity scores

| Domain | Design score (out of 10) | Current state | What keeps it below 10 |
| --- | --- | --- | --- |
| Platform architecture and HA | 9 | 1 | 2 replicas leave a shard on one copy for about 2-6 h during a rebuild |
| Network and transport security | 9 | 1 | Metrics endpoint is plaintext inside the VPC |
| Identity and access | 8 | 1 | No MFA or token auth at the database hop in OSS LTS |
| Secrets and encryption | 9 | 1 | Encrypted-disk keys rotate only as parts are rewritten |
| Data governance | 7 | 1 | Masking by views (native masking policies are Cloud-only); US-only residency |
| Resource governance | 8 | 1 | Workload scheduler tuning needs production traffic to calibrate |
| Observability and audit | 8 | 1 | Query latency SLOs derived from logs, not client-side measurement |
| Backup and DR | 8 | 1 | Ransomware rebuild path is 8-12 h; DR runs one replica per shard |
| DevSecOps | 9 | 1 | RBAC drift detection is daily, not real-time |
| Compliance readiness | 7 | 1 | Residency gap; PCI and HIPAA scoping decisions pending |
| **Overall** | **8.2** | **1** |  |

### 10.3 Gaps and remediation

| # | Gap | Risk | Remediation | When |
| --- | --- | --- | --- | --- |
| 1 | EU personal data stored only in US regions | GDPR Chapter V violation; regulatory fines | Deploy an EU cluster (eu-central-1 primary, eu-west-1 DR) for EU-subject data, or complete SCCs plus a transfer impact assessment | Before go-live |
| 2 | Ransomware full-rebuild RTO is 8-12 h | RTO breach in the worst case | Keep the DR region in a separate AWS account with separate admin identities and no shared CI credentials, so promotion (about 2 h) stays available; pre-build a clean-room account from Terraform | Before go-live |
| 3 | Runbooks 7.4-7.6 untested | Recovery fails or overruns under pressure | Quarterly game days; the first round in staging before go-live | Before go-live |
| 4 | Shard runs on one replica during a node rebuild | A second failure in the same shard loses that shard's hot data until restore | Re-attach the warm-tier EBS volumes to the replacement node, so only 6 TB of hot data is re-fetched (about 2 h instead of 6). Consider 3 replicas for the top 5 revenue-critical tables | Within 90 days |
| 5 | No MFA at the database hop | Stolen AD password plus VPN session gives SQL access | Restrict LDAP logins to chproxy and VPN source ranges; evaluate OIDC token auth when it reaches OSS LTS, or an Altinity Antalya build | Within 180 days |
| 6 | Masking through views | View sprawl; a new PII column is exposed if a view is missed | CI check that fails when a `pii`-tagged column lacks a masked view; move to native masking policies if the platform moves to ClickHouse Cloud | Within 90 days |
| 7 | Warm tier full in about 9 months | Inserts slow and TTL moves stall | Expand to 6 x 4 TiB gp3 per node, or shorten warm retention to 60 days | Within 6 months |
| 8 | Cold tier stored once per replica | About $35k/month of avoidable S3 cost at full retention (approximate list price) | Roll up raw events older than 90 days where compliance allows; S3 Standard-IA for objects older than 180 days | Within 12 months |
| 9 | Nothing deployed | All controls are design-only | Phase 1 (weeks 1-4): accounts, network, Terraform modules. Phase 2 (5-8): Keeper, data nodes, TLS, RBAC. Phase 3 (9-12): ingest, monitoring, backups. Phase 4 (13-16): DR region, game days, audit evidence, go-live review | Start now |

## Sources

- [ClickHouse workload scheduling](https://clickhouse.com/docs/operations/workload-scheduling): `CREATE RESOURCE` / `CREATE WORKLOAD` syntax used in 4.8
- [ClickHouse CREATE MASKING POLICY](https://clickhouse.com/docs/sql-reference/statements/create/masking-policy): ClickHouse Cloud only, from 25.12 (basis for masking via views in 4.7)
- [ClickHouse JWT authentication](https://clickhouse.com/docs/concepts/features/security/external-authenticators/jwt): ClickHouse Cloud Enterprise feature (basis for the OIDC row in 4.3)
- [Altinity: OAuth in Antalya builds](https://altinity.com/blog/oauth-alert-token-based-authentication-lands-in-altinity-antalya-builds): token processors in Antalya 25.8.16+

Instance specifications, AWS prices and kernel defaults come from general knowledge and are approximate. Confirm them against current AWS and ClickHouse documentation before procurement.
