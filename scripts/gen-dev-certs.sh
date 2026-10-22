#!/usr/bin/env bash
# Generate a throwaway CA + server/client certificates for testing mTLS locally (design doc Section 5.3).
# Production certificates come from Vault PKI (30-day servers, 1-7 day clients), never from this script.
#
#   scripts/gen-dev-certs.sh [out_dir]      default out_dir: local/tls (git-ignored)
set -euo pipefail
OUT="${1:-$(cd "$(dirname "$0")/.." && pwd)/local/tls}"
mkdir -p "$OUT" && cd "$OUT"

openssl ecparam -name secp384r1 -genkey -noout -out ca.key
openssl req -x509 -new -key ca.key -sha384 -days 30 \
  -subj "/O=Dev/CN=ClickHouse Dev CA" \
  -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" -out ca-bundle.crt

issue() {  # name, extfile contents
  openssl ecparam -name prime256v1 -genkey -noout -out "$1.key"
  openssl req -new -key "$1.key" -subj "/O=Dev/CN=$1" -out "$1.csr"
  openssl x509 -req -in "$1.csr" -CA ca-bundle.crt -CAkey ca.key -CAcreateserial -days 7 -sha256 \
    -extfile <(printf '%s' "$2") -out "$1.crt"
  rm -f "$1.csr"
}

for node in ch-s1-r1 ch-s1-r2 ch-s2-r1 ch-s2-r2 keeper-1 keeper-2 keeper-3; do
  issue "$node" "subjectAltName=DNS:${node},DNS:localhost
extendedKeyUsage=serverAuth,clientAuth
keyUsage=critical,digitalSignature"
done
for user in svc_kafka_connect dev_engineer; do
  issue "$user" "extendedKeyUsage=clientAuth"
done

chmod 600 ./*.key
echo "certificates written to $OUT"
