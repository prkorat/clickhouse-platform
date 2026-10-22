#!/usr/bin/env bash
# Shared helpers. CH_CLIENT is the full client command, so the same scripts work against the local
# Docker cluster and against staging/prod over mTLS:
#
#   local : CH_CLIENT="docker compose -f local/docker-compose.yml exec -T ch-s1-r1 clickhouse-client --user admin --password admin"
#   prod  : CH_CLIENT="clickhouse-client --host chproxy.ch.prod.internal --port 9440 --secure --user svc_ci_deployer"
#           (client certificate configured in ~/.clickhouse-client/config.xml by the pipeline)
set -euo pipefail

: "${CH_CLIENT:?set CH_CLIENT to the clickhouse-client command (see scripts/lib.sh)}"
export REPO_ROOT
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Run SQL read from stdin. Multi-statement files are allowed.
# shellcheck disable=SC2086  # CH_CLIENT is a command line and must word-split
ch_exec() { ${CH_CLIENT} --multiquery; }

# Run a single query and print the result (TSV, no header).
# shellcheck disable=SC2086
ch_query() { ${CH_CLIENT} --format TSV --query "$1"; }

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
fail() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
