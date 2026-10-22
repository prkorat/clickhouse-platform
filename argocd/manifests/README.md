# ArgoCD manifests

Each folder is the `path` of one Application in `argocd/applications/`. Use Kustomize (`kustomization.yaml`) or a Helm values file per folder.

| Folder | Contents to add |
| --- | --- |
| `monitoring/` | Prometheus rules from `monitoring/alerts/*.yaml` (as `PrometheusRule`), Alertmanager config from `monitoring/alertmanager.yaml`, Grafana dashboards from `monitoring/dashboards/*.json` (as ConfigMaps with the `grafana_dashboard` label), sql-exporter with `monitoring/sql-exporter/queries.yaml` |
| `chproxy/` | Deployment (3 replicas, one per AZ), Service behind the PrivateLink NLB, ConfigMap from `config.yml`, ExternalSecret for passwords, cert-manager or Vault certificate |
| `kafka-connect/` | Strimzi `KafkaConnect` + `KafkaConnector` for the ClickHouse sink (`exactlyOnce: true`, topic `events.v1` -> `raw.events`) |

Keep secrets out of these folders: use ExternalSecrets (Secrets Manager) or the Vault Agent injector.
