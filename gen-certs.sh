#!/usr/bin/env bash
# 공인 IP용 자체 서명 인증서 생성 (도메인을 못 쓰는 환경용)
#   ./gen-certs.sh <KT_PUBLIC_IP>
# 결과:
#   caddy/certs/server.crt, server.key  → Caddy가 사용
#   caddy/ca/ca.crt                     → 온프렘 Alloy가 서버를 검증할 때 쓰는 CA (k3s ConfigMap, DB VM에 배포)
#   caddy/ca/ca.key                     → 인증서 재발급용. VM 밖 안전한 곳에 옮겨 보관
set -euo pipefail

IP="${1:?usage: $0 <KT_PUBLIC_IP>}"
BASE="$(cd "$(dirname "$0")" && pwd)"
CERTS="$BASE/caddy/certs"
CA="$BASE/caddy/ca"
mkdir -p "$CERTS" "$CA"

openssl genrsa -out "$CA/ca.key" 4096 2>/dev/null
openssl req -x509 -new -nodes -key "$CA/ca.key" -sha256 -days 825 \
  -subj "/CN=coconut-monitoring-ca" -out "$CA/ca.crt"

openssl genrsa -out "$CERTS/server.key" 2048 2>/dev/null
openssl req -new -key "$CERTS/server.key" -subj "/CN=${IP}" -out "$CERTS/server.csr"

cat > "$CERTS/server.ext" <<EOF
subjectAltName=IP:${IP}
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
EOF

openssl x509 -req -in "$CERTS/server.csr" -CA "$CA/ca.crt" -CAkey "$CA/ca.key" \
  -CAcreateserial -CAserial "$CA/ca.srl" -out "$CERTS/server.crt" \
  -days 825 -sha256 -extfile "$CERTS/server.ext" 2>/dev/null

rm -f "$CERTS/server.csr" "$CERTS/server.ext"
chmod 600 "$CERTS/server.key" "$CA/ca.key"

echo "완료: 유효기간 825일. CA 인증서는 $CA/ca.crt"
openssl x509 -in "$CERTS/server.crt" -noout -subject -ext subjectAltName -dates 2>/dev/null || true
