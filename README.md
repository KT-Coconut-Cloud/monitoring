# 코코넛 모니터링 — KT Cloud 수신 스택 + Alloy 설정

온프렘(k3s)이 **먼저 밖으로** 메트릭/로그를 보내고(push), KT Cloud 모니터링 VM이 받아서 저장·시각화·알림한다.
KT Cloud → 온프렘 방향의 연결은 없다.

```
[k3s monitoring ns]  Alloy ── HTTPS 443 (basic auth) ─▶ Caddy ─┬▶ Prometheus (/api/v1/write)
   └ database ns 의 primary-db / replica-db 에 접속(3306)         ├▶ Loki       (/loki/api/v1/push)
                                                                 └▶ Grafana    (그 외)
                          Prometheus ─▶ Alertmanager ─▶ Discord
```

## 구성

| 위치 | 파일 | 내용 |
| --- | --- | --- |
| KT 모니터링 VM | `docker-compose.yml` 외 | caddy, prometheus, loki, alertmanager, grafana, node-exporter, cadvisor |
| k3s | `alloy/k3s/` | Alloy 설정(k8s·Argo·Vault·MySQL 수집), Helm values, NetworkPolicy 초안 |

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
`caddy/ca/ca.crt` 는 온프렘(k3s)에 배포한다.

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

### Grafana 도메인 + 정식 HTTPS (선택)

도메인이 있으면 Grafana 는 Let's Encrypt 인증서로 접속할 수 있다. Alloy 수신(IP 기준 자체 서명 인증서)은 그대로 둔다.

- `Caddyfile` 의 `auto_https off` 를 제거하고, 도메인용 사이트 블록을 추가한다 (`<GRAFANA_DOMAIN> { reverse_proxy grafana:3000 }`).
- 인증서 발급(http-01)을 위해 **80/tcp** 도 열고 compose 의 caddy 포트에 `"80:80"` 을 추가한다. 인증서는 `caddy_data` 볼륨에 저장된다.
- DNS 에서 `<GRAFANA_DOMAIN>` 이 모니터링 VM 공인 IP 를 가리키게 한다. Cloudflare 프록시를 켜면 SSL/TLS 모드를 Full(strict) 로 둔다. 처음 발급 때는 DNS only 가 간단하다.
- `docker-compose.yml` 의 `GF_SERVER_ROOT_URL` 을 `https://<GRAFANA_DOMAIN>/` 로 맞춘다.

## 2. k3s (Alloy 설정은 이쪽에서 제공)

배포 방식(Argo CD 등)은 팀 구성에 맞춘다. 아래는 수동 배포 기준의 순서다.

```bash
kubectl create namespace monitoring

# 수신 서버 정보 / CA / Alloy 설정
kubectl -n monitoring create secret generic kt-ingest \
  --from-literal=prom_url=https://<KT_IP>/api/v1/write \
  --from-literal=loki_url=https://<KT_IP>/loki/api/v1/push \
  --from-literal=user=<INGEST_USER> --from-literal=pass='<수신 비밀번호>'   # user 는 모니터링 VM .env 의 INGEST_USER 와 같아야 한다 (다르면 401)
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
- cAdvisor 는 kubelet(노드IP:10250)에서 직접 읽는다. Alloy 서비스 계정에 `nodes/metrics` 읽기 권한이 있어야 하고(`kubectl auth can-i get nodes/metrics --as=system:serviceaccount:monitoring:alloy`), 방화벽에서 파드 대역 → 노드 9100, 10250 이 열려 있어야 한다. 노드 시계가 NTP 와 맞아야 한다(어긋나면 Prometheus 가 `out of bounds` 로 거절한다).
- `pii-job` 로그는 `pipeline_stage` 가 들어 있는 줄(단계 이벤트 JSON 한 줄)만 수집한다. 나머지 줄은 버린다. 주민번호·전화번호·이메일 패턴은 전송 전에 마스킹하지만 정규식만으로는 이름·주소·금액을 못 잡는다. pii-job 연결 후 허용 필드(run_id, stage, status, count 등)만 통과시키는 방식으로 보완할 예정이다.
- **Argo CD / Argo Workflows 지표**: `config.alloy` 가 파드 라벨로 대상을 찾아 긁는다. application-controller 는 `app.kubernetes.io/name=argocd-application-controller` 의 8082 (HTTP), workflow-controller 는 `app.kubernetes.io/name=argo-workflows-workflow-controller` 의 9090 이고 **HTTPS(자체 서명)** 라 `scheme = "https"` + `insecure_skip_verify` 가 필요하다. 워크플로 개수 지표는 Argo Workflows 3.6 기준 `argo_workflows_gauge{phase=...}` 이다.
- **파이프라인 로그 수집 조건**: 성공한 워크플로 파드는 `podGC` 로 바로 지워지면 Alloy 가 로그를 읽기 전에 사라진다. `podGC.deleteDelayDuration`(예: 120s) 으로 잠시 남겨 둬야 한다. ConfigMap `alloy-config` 를 바꾼 뒤에는 `kubectl -n monitoring rollout restart deployment alloy` 가 필요하다. Argo CD 기본 NetworkPolicy 는 8082 를 모든 네임스페이스에 허용하므로 따로 열 필요가 없다.
- **노드 방화벽(firewalld)**: 파드 대역이 방화벽 영역에 등록되어 있지 않으면 같은 노드의 파드 간 통신이 `filter_FWD_public_REJECT` 로 거절되어 수집이 `no route to host` 로 실패한다. k3s 권장대로 파드·서비스 대역을 신뢰 영역에 넣는다. 파드에서 노드의 다른 포트에도 닿게 되므로 보안 담당과 공유한다.
  ```bash
  firewall-cmd --permanent --zone=trusted --add-source=10.42.0.0/16   # 파드 대역
  firewall-cmd --permanent --zone=trusted --add-source=10.43.0.0/16   # 서비스 대역
  firewall-cmd --reload
  ```
  원복은 `--add-source` 를 `--remove-source` 로 바꿔 실행한다. 거절 원인을 볼 때는 `firewall-cmd --set-log-denied=all` 후 `dmesg | grep DST=<파드IP>` 로 확인하고 끝나면 `--set-log-denied=off` 로 되돌린다.
- 설정 변경은 `configReloader` 를 꺼 둔 상태라 ConfigMap 을 갱신한 뒤 `kubectl -n monitoring rollout restart deployment alloy` 로 재시작해야 반영된다.
- 노드 메모리가 3.5GB 로 빠듯해서 Alloy 는 requests 96Mi / limits 256Mi 로 가볍게 운영한다. k3s 자체와 argocd 가 메모리를 가장 많이 쓴다.

## 3. MySQL 모니터링 (Primary / Replica)

DB VM 에 Alloy 를 설치하지 않는다. k3s 의 Alloy 가 `database` 네임스페이스의 서비스 `primary-db`, `replica-db` (3306) 에 직접 접속해 지표를 읽는다.

1. 모니터링 전용 DB 계정을 만든다. **Primary 에서 만들면 Replica 로 복제된다.** 데이터 테이블 SELECT 는 주지 않는다.

```sql
CREATE USER 'alloy_mon'@'<접속 출발지>' IDENTIFIED BY '<비밀번호>' WITH MAX_USER_CONNECTIONS 3;
GRANT PROCESS, REPLICATION CLIENT ON *.* TO 'alloy_mon'@'<접속 출발지>';
GRANT SELECT ON performance_schema.* TO 'alloy_mon'@'<접속 출발지>';
```

2. 접속 정보를 Secret `mysql-monitor` 로 만든다 (키 이름은 `primary_dsn`, `replica_dsn`).

```bash
kubectl -n monitoring create secret generic mysql-monitor \
  --from-literal=primary_dsn='alloy_mon:<비밀번호>@(primary-db.database.svc:3306)/' \
  --from-literal=replica_dsn='alloy_mon:<비밀번호>@(replica-db.database.svc:3306)/'
```

3. Alloy 는 이 Secret 을 환경변수 `MYSQL_PRIMARY_DSN`, `MYSQL_REPLICA_DSN` 으로 받는다 (`alloy/k3s/values-alloy.yaml`).
4. 알림 규칙이 `cluster="onprem-db"`, `role=primary|replica` 라벨을 보므로 `config.alloy` 에서 라벨을 바꿔 붙인다.
5. NetworkPolicy 를 쓸 때 `monitoring` → `database` 3306 이 막히지 않게 한다.
6. MySQL 에러 로그는 수집하지 않는다 (지표만 수집).

## 검증 범위

| 항목 | 상태 |
| --- | --- |
| prometheus.yml, alerts.yml (규칙 29개) | `promtool` v3.1.0 으로 검증 |
| alertmanager.yml | `amtool` v0.28.1 로 검증 (v0.27.0 은 `webhook_url_file` 미지원이라 v0.28.1 로 고정) |
| Caddyfile | `caddy validate` v2.9.1 로 검증 |
| docker-compose.yml | `docker compose config` 문법 검증 |
| Alloy 설정 2개 | `alloy validate` v1.21.3 로 문법 검증 (`env()` 는 deprecated 라 `sys.env()` 사용) |
| gen-certs.sh | 실행 후 `openssl verify` 통과, SAN(IP) 확인 |
| **k3s 종단 통신** | 2026-11-19~20 실서버에서 확인: kube-state-metrics, node-exporter, cAdvisor, Argo CD, Argo Workflows 5개 대상 `up=1`, 대시보드 1·5번 표시. 11-20 에 추가한 Argo CD/Workflows 수집 블록은 이 샌드박스에서 `alloy validate` 를 다시 돌리지 못했고 실서버 기동으로 확인했다 |
| **MySQL 지표 (k3s Alloy → database ns)** | Secret `mysql-monitor` 생성됨. 지표 수집 여부는 Grafana 에서 `mysql_up` 으로 확인 |

`prometheus.exporter.mysql` 기본 수집기에 복제 상태가 포함되는지는 첫 배포 때 확인한다.
