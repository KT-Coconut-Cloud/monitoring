# 코코넛 모니터링 — KT Cloud 수신 스택 + Alloy 설정

온프렘(k3s, DB VM)이 **먼저 밖으로** 메트릭/로그를 보내고(push), KT Cloud 모니터링 VM이 받아서 저장·시각화·알림한다.
KT Cloud → 온프렘 방향의 연결은 없다.

```
[k3s monitoring ns]  Alloy ─┐
[DB Primary VM]      Alloy ─┼─ HTTPS 443 (basic auth) ─▶ Caddy ─┬▶ Prometheus (/api/v1/write)
[DB Replica VM]      Alloy ─┘                                   ├▶ Loki       (/loki/api/v1/push)
                                                                └▶ Grafana    (그 외)
                          Prometheus ─▶ Alertmanager ─▶ Discord
```

## 구성

| 위치 | 파일 | 내용 |
| --- | --- | --- |
| KT 모니터링 VM | `docker-compose.yml` 외 | caddy, prometheus, loki, alertmanager, grafana, node-exporter, cadvisor |
| k3s | `alloy/k3s/` | Alloy 설정, Helm values, NetworkPolicy 초안 |
| DB VM 2대 | `alloy/db-vm/config.alloy` | MySQL/호스트 메트릭 + MySQL 에러 로그 |

## 1. KT 모니터링 VM 설치 (Rocky 8.10)

```bash
# Docker (Rocky 8 은 podman 이 기본이라 충돌 시 --allowerasing)
sudo dnf install -y dnf-plugins-core
sudo dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
sudo dnf install -y --allowerasing docker-ce docker-ce-cli containerd.io docker-compose-plugin
sudo systemctl enable --now docker

# 방화벽: 443 만 연다
sudo firewall-cmd --permanent --add-port=443/tcp && sudo firewall-cmd --reload
```

KT Cloud 콘솔에서 공인 IP를 이 VM에 연결하고, 방화벽/포트포워딩에서 **443/tcp** 를 허용한다 (소스를 온프렘 공인 IP로 제한할 수 있으면 제한).

```bash
cd monitoring-kt
cp .env.example .env                     # PUBLIC_IP, 비밀번호, 해시 채우기
docker run --rm caddy:2 caddy hash-password --plaintext '<수신 비밀번호>'   # → INGEST_PASS_HASH (작은따옴표로 감싸서 .env 에)
./gen-certs.sh <KT_PUBLIC_IP>            # 자체 서명 인증서 (도메인 없이 IP 로 쓰기 위함)

# Discord 웹훅 URL (Alertmanager 는 파일로 읽는다)
printf '%s' '<#ops-alerts 웹훅 URL>'   > alertmanager/secrets/discord_alerts
printf '%s' '<#security 웹훅 URL>'     > alertmanager/secrets/discord_security

docker compose up -d
docker compose ps
```

`caddy/ca/ca.key` 는 재발급용 비밀키다. 인증서를 만든 뒤 VM 밖 안전한 곳으로 옮겨 두고 VM에서는 지운다.
`caddy/ca/ca.crt` 는 온프렘(k3s, DB VM)에 배포한다.

### 동작 확인

```bash
curl --cacert caddy/ca/ca.crt https://<IP>/healthz                       # ok
curl --cacert caddy/ca/ca.crt -o /dev/null -w '%{http_code}\n' -X POST https://<IP>/api/v1/write   # 401 (인증 없음)
# Loki 로 테스트 로그 1줄 (204 가 오면 성공)
curl --cacert caddy/ca/ca.crt -u alloy:'<비밀번호>' -X POST https://<IP>/loki/api/v1/push \
  -H 'Content-Type: application/json' \
  -d "{\"streams\":[{\"stream\":{\"job\":\"smoke\"},\"values\":[[\"$(date +%s%N)\",\"hello\"]]}]}"
```

Grafana 는 `https://<IP>/` (admin / `.env` 의 비밀번호). 자체 서명 인증서라 브라우저 경고가 뜬다.
디스크 크기에 맞게 `.env` 의 `PROM_RETENTION_SIZE` 를 조정한다.

## 2. k3s (용희님 작업 + Alloy 설정은 이쪽에서 제공)

배포 방식(Argo CD 등)은 팀 구성에 맞춘다. 아래는 수동 배포 기준의 순서다.

```bash
kubectl create namespace monitoring

# 수신 서버 정보 / CA / Alloy 설정
kubectl -n monitoring create secret generic kt-ingest \
  --from-literal=prom_url=https://<KT_IP>/api/v1/write \
  --from-literal=loki_url=https://<KT_IP>/loki/api/v1/push \
  --from-literal=user=alloy --from-literal=pass='<수신 비밀번호>'
kubectl -n monitoring create configmap kt-ca --from-file=ca.crt=caddy/ca/ca.crt
kubectl -n monitoring create configmap alloy-config --from-file=config.alloy=alloy/k3s/config.alloy

helm repo add grafana https://grafana.github.io/helm-charts
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm upgrade --install kube-state-metrics prometheus-community/kube-state-metrics -n monitoring
helm upgrade --install node-exporter prometheus-community/prometheus-node-exporter -n monitoring
helm upgrade --install alloy grafana/alloy -n monitoring -f alloy/k3s/values-alloy.yaml
kubectl apply -f alloy/k3s/networkpolicy.yaml     # <...> 값 채운 뒤
```

- kube-state-metrics 의 Service 이름이 `kube-state-metrics` 가 아니면 `config.alloy` 의 주소를 맞춘다.
- Alloy 차트 기본 ClusterRole 에 `nodes/proxy` 가 포함되는지 확인한다 (cAdvisor 를 API 서버 프록시로 읽는다).
- `pii-job` 로그는 `batch_id` 가 들어 있는 줄(단계 이벤트 JSON 한 줄)만 수집한다. 나머지 줄은 버린다.

## 3. DB VM 2대 (Primary / Replica 각각)

1. Alloy 설치 (Rocky 9, Grafana 저장소의 `alloy` 패키지, systemd 서비스).
2. 모니터링 전용 DB 계정. **Primary 에서 만들면 Replica 로 복제된다.** 데이터 테이블 SELECT 는 주지 않는다.

```sql
CREATE USER 'alloy_mon'@'127.0.0.1' IDENTIFIED BY '<비밀번호>' WITH MAX_USER_CONNECTIONS 3;
GRANT PROCESS, REPLICATION CLIENT ON *.* TO 'alloy_mon'@'127.0.0.1';
GRANT SELECT ON performance_schema.* TO 'alloy_mon'@'127.0.0.1';
```

3. `alloy/db-vm/config.alloy` 를 `/etc/alloy/config.alloy` 로 복사하고 `/etc/sysconfig/alloy` 에 환경변수를 넣는다.

```
CONFIG_FILE="/etc/alloy/config.alloy"
KT_PROM_URL="https://<KT_IP>/api/v1/write"
KT_LOKI_URL="https://<KT_IP>/loki/api/v1/push"
KT_USER="alloy"
KT_PASS="<수신 비밀번호>"
KT_CA_FILE="/etc/alloy/ca.crt"
DB_ROLE="primary"            # Replica VM 에서는 replica
MYSQL_DSN="alloy_mon:<비밀번호>@(127.0.0.1:3306)/"
MYSQL_ERROR_LOG="/var/log/mysqld.log"
```

4. `alloy` 사용자가 MySQL 에러 로그를 읽을 수 있어야 한다 (예: `usermod -aG mysql alloy`).
5. VM 에서 KT Cloud 공인 IP 의 443/tcp 로 나가는 아웃바운드가 열려 있어야 한다. Replica 의 "k3s 노드 → 3306만 허용" 정책은 인바운드라 그대로 둔다.
6. 원본이 있는 Primary VM 에서 외부로 나가는 경로가 생기므로 보안 담당과 먼저 합의한다 (메트릭·에러 로그만, 목적지는 KT Cloud 443 한 곳).

## 검증 범위

| 항목 | 상태 |
| --- | --- |
| prometheus.yml, alerts.yml (규칙 17개) | `promtool` v3.1.0 으로 검증 |
| alertmanager.yml | `amtool` v0.28.1 로 검증 (v0.27.0 은 `webhook_url_file` 미지원이라 v0.28.1 로 고정) |
| Caddyfile | `caddy validate` v2.9.1 로 검증 |
| docker-compose.yml | `docker compose config` 문법 검증 |
| Alloy 설정 2개 | `alloy validate` v1.21.3 로 문법 검증 (`env()` 는 deprecated 라 `sys.env()` 사용) |
| gen-certs.sh | 실행 후 `openssl verify` 통과, SAN(IP) 확인 |
| **실제 기동 / 종단 통신** | **미검증** (Docker 데몬, k3s, KT Cloud 환경이 없었음). VM 에 올린 뒤 위 "동작 확인" 으로 점검 |

미검증이라 첫 배포에서 손볼 가능성이 있는 곳: cAdvisor 프록시 경로와 RBAC, node-exporter 파드 디스커버리(차트 라벨), `prometheus.exporter.mysql` 기본 수집기에 복제 상태가 포함되는지, SELinux 환경의 볼륨 마운트.

## 아직 비어 있는 것

- Grafana 대시보드 JSON (`grafana/dashboards/`) — 데이터가 들어온 뒤 작성
- 보안 알림(Macie 탐지, WireGuard handshake, 허용 외 반출) — 수집 경로가 정해지면 `alerts.yml` 의 `security` 그룹에 추가
- CloudWatch 데이터소스 — 읽기 전용 IAM 키 준비 후 `datasources.yml` 주석 해제
- status-relay (batch_id별 진행 메시지) — Alertmanager→Discord 직결이 동작한 뒤 2단계
