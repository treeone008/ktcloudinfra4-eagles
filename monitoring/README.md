# Monitoring 구성 문서

> 본 문서는 `monitor` VM에서 운영하는 Prometheus, Grafana, Alertmanager 기반 모니터링 구성을 GitHub 제출용으로 정리한 문서입니다.  
> DB Proxy 구축 절차는 범위에서 제외하고, 모니터링 시스템이 어떤 대상을 수집하고 어떻게 알림을 전달하는지만 다룹니다.

---

## 1. 구성 개요

모니터링 VM은 OpenStack 프로젝트 환경의 인프라 노드, 서비스 인스턴스, 데이터베이스, 컨테이너 상태를 수집하고 시각화하기 위해 구성되었습니다.

```text
수집 대상 VM / Exporter
  -> Prometheus
  -> Grafana Dashboard
  -> Prometheus Alert Rule
  -> Alertmanager
  -> Slack / Email
```

모니터링 스택은 Docker Compose로 실행됩니다.

| 서비스 | 역할 | 접속 주소 |
|---|---|---|
| Prometheus | 메트릭 수집, PromQL 조회, Alert Rule 평가 | `http://172.16.8.110:9090` |
| Grafana | Prometheus 데이터를 대시보드로 시각화 | `http://172.16.8.110:3000` |
| Alertmanager | Prometheus 알림을 Slack/Email로 라우팅 | `http://172.16.8.110:9093` |

### 1-1. 문서화 범위

이 문서는 진수님 산출물 중 모니터링 파트만 정리합니다.

| 구분 | 포함 여부 | 내용 |
|---|---:|---|
| Prometheus 운영 | 포함 | scrape config, target 파일, rule 파일, 설정 검증 |
| Grafana 대시보드 | 포함 | 전체 현황 대시보드, 주요 패널, PromQL |
| Alertmanager 알림 | 포함 | Slack/Email receiver, secret mount, 알림 테스트 |
| Exporter 수집 | 포함 | node_exporter, mysql_exporter, cAdvisor, MaxScale exporter 수집 관점 |
| ZeroTier 모니터링 접근 | 포함 | monitor가 target에 접근하기 위한 관리망 설계 |
| DB Proxy 구축 | 제외 | MaxScale/Pacemaker/VIP 구성 절차는 별도 DB Proxy 범위 |
| DB 자체 구축 | 제외 | MariaDB Primary/Replica 설치 및 DB 스키마 |

DB Proxy나 DB 항목은 구축 절차가 아니라 **모니터링 대상**으로만 설명합니다.

---

## 2. 모니터링 VM 정보

| 항목 | 값 |
|---|---|
| VM 이름 | `monitor` |
| 관리 IP | `172.16.8.110` |
| OS | Ubuntu 24.04 계열 |
| 실행 방식 | Docker Compose |
| 기준 디렉토리 | `~/monitoring` |

VMware 설정 기준 주요 리소스는 다음과 같습니다.

| 항목 | 값 |
|---|---|
| vCPU | 2 vCPU |
| Memory | 4 GB |
| Guest OS | Ubuntu 64-bit |
| 주요 스냅샷 | `최소 환경 설정`, `current_monitoring_backup`, `maxscale 기초구성` |

### 2-1. 현재 폴더 산출물 분류

`monitoring` 폴더에는 문서화에 바로 쓸 파일과 보관용 VMware 실행 파일이 섞여 있습니다.

| 파일 | 분류 | 문서화 반영 |
|---|---|---|
| `README.md` | GitHub 제출용 문서 | 최종 정리본 |
| `monitoring_machine_usage_guide.md` | 원본 운영 가이드 | 접속 주소, PromQL, 기본 명령어 반영 |
| `인수인계 사항.txt` | 원본 인수인계 문서 | Prometheus, Grafana, Alertmanager, exporter, alert rule 반영 |
| `슬렉 및 메일 루트 수정.txt` | 원본 알림 교체 가이드 | Slack/Email secret 교체, 테스트, 보안 주의 반영 |
| `zerotier 리소스 분산 가이드.txt` | 원본 네트워크/리소스 분산 가이드 | ZeroTier 기반 Prometheus 수집망 설계 반영 |
| `moniter.vmx` | VMware VM 설정 | VM 이름, OS, CPU, Memory, 네트워크 정보 참고 |
| `moniter.vmsd` | VMware 스냅샷 메타데이터 | 스냅샷 이름과 현재 스냅샷 참고 |
| `moniter.vmxf` | VMware 보조 메타데이터 | GitHub 본문 반영 불필요 |
| `vmware*.log` | VMware 실행 로그 | 장애 분석용 보관, GitHub 본문 반영 불필요 |
| `mksSandbox*.log` | VMware 그래픽/콘솔 로그 | 장애 분석용 보관, GitHub 본문 반영 불필요 |
| `.gitkeep` | Git 빈 폴더 유지 | 설명 불필요 |

GitHub 문서에는 원본 `.txt`의 민감정보를 직접 올리지 않고, `README.md`처럼 정리된 형태로만 반영합니다.

---

## 3. 디렉토리 구조

현재 `~/monitoring` 디렉토리는 다음 구조로 구성되어 있습니다.

```text
~/monitoring
├── compose.yml
├── alertmanager
│   └── alertmanager.yml
├── grafana
│   ├── dashboards
│   └── provisioning
│       ├── dashboards
│       └── datasources
│           └── prometheus.yml
└── prometheus
    ├── prometheus.yml
    ├── prometheus.yml.step01
    ├── rules
    │   ├── db-alerts.yml
    │   ├── maxscale-alerts.yml
    │   └── node-alerts.yml
    └── targets
        ├── cadvisor.yml
        ├── maxscale.yml
        ├── mysql.yml
        └── openstack_nodes.yml
```

`secrets` 디렉토리에는 Slack Webhook URL과 Gmail App Password가 들어가므로 GitHub에 올리면 안 됩니다. 문서에는 파일명과 용도만 남기고 실제 값은 제외합니다.

---

## 4. Docker Compose 구성

모니터링 스택은 `compose.yml`에서 세 개의 컨테이너로 구성됩니다.

| 컨테이너 | 이미지 | 외부 포트 | 주요 볼륨 |
|---|---|---:|---|
| `prometheus` | `prom/prometheus:v3.5.3` | `9090` | `prometheus.yml`, `rules`, `targets`, `prometheus_data` |
| `grafana` | `grafana/grafana:13.0.2` | `3000` | `grafana_data`, `grafana/provisioning`, `grafana/dashboards` |
| `alertmanager` | `prom/alertmanager:v0.33.0` | `9093` | `alertmanager.yml`, secret files, `alertmanager_data` |

상태 확인 명령:

```bash
cd ~/monitoring
docker compose ps
```

확인 시점에는 세 컨테이너가 모두 실행 중이었습니다.

```text
NAME           IMAGE                       SERVICE        STATUS
alertmanager   prom/alertmanager:v0.33.0   alertmanager   Up
grafana        grafana/grafana:13.0.2      grafana        Up
prometheus     prom/prometheus:v3.5.3      prometheus     Up
```

---

## 5. Prometheus 구성

Prometheus는 15초 주기로 메트릭을 수집하고 15초 주기로 알림 규칙을 평가합니다.

```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s
```

알림은 Docker 네트워크 내부의 Alertmanager로 전달됩니다.

```yaml
alerting:
  alertmanagers:
    - static_configs:
        - targets:
            - alertmanager:9093
```

수집 대상은 `file_sd_configs` 방식으로 분리되어 있습니다.

| Job | 대상 파일 | 용도 |
|---|---|---|
| `prometheus` | static config | Prometheus 자기 자신 |
| `alertmanager` | static config | Alertmanager 상태 |
| `openstack-node` | `prometheus/targets/openstack_nodes.yml` | OpenStack 노드 및 인스턴스 node_exporter |
| `mysql` | `prometheus/targets/mysql.yml` | MySQL Exporter |
| `cadvisor` | `prometheus/targets/cadvisor.yml` | Swarm Manager cAdvisor |
| `maxscale` | `prometheus/targets/maxscale.yml` | MaxScale Exporter |

설정 검증 명령:

```bash
cd ~/monitoring
docker exec prometheus promtool check config /etc/prometheus/prometheus.yml
```

확인 결과:

```text
SUCCESS: /etc/prometheus/prometheus.yml is valid prometheus config file syntax
SUCCESS: 3 rule files found
```

### 5-1. Target 파일 반영 방식

수집 대상은 `prometheus/targets/*.yml` 파일로 관리합니다. target 또는 label을 수정한 뒤에는 먼저 설정을 검증합니다.

```bash
cd ~/monitoring
docker exec prometheus promtool check config /etc/prometheus/prometheus.yml
```

문제가 없으면 Prometheus를 재시작합니다.

```bash
docker compose restart prometheus
```

기존 인수인계 기록에 따르면 target 수정이 단순 restart만으로 반영되지 않은 사례가 있었습니다. 이 경우 Prometheus 컨테이너만 재생성합니다.

```bash
docker compose stop prometheus
docker compose rm -f prometheus
docker compose up -d prometheus
```

주의할 점은 `docker compose down -v`를 사용하지 않는 것입니다. 이 명령은 Prometheus/Grafana 볼륨까지 삭제할 수 있어 수집 데이터와 대시보드 설정이 사라질 수 있습니다.

### 5-2. 자주 쓰는 PromQL

운영 확인 시 자주 쓰는 PromQL은 다음과 같습니다.

| 목적 | PromQL |
|---|---|
| 전체 target 상태 | `up` |
| OpenStack node_exporter 상태 | `up{job="openstack-node"}` |
| DB Proxy 노드 상태 | `up{job="openstack-node", role="db-proxy"}` |
| MySQL Exporter 상태 | `up{job="mysql"}` |
| cAdvisor 상태 | `up{job="cadvisor"}` |
| MaxScale Exporter 상태 | `up{job="maxscale"}` |
| DB Replica IO Thread | `mysql_slave_status_slave_io_running{job="mysql"}` |
| DB Replica SQL Thread | `mysql_slave_status_slave_sql_running{job="mysql"}` |
| DB Replication Lag | `mysql_slave_status_seconds_behind_master{job="mysql"}` |
| MaxScale Backend 상태 | `maxctrl_server_up{job="maxscale"}` |
| MaxScale Uptime | `maxctrl_status_uptime{job="maxscale"}` |

Prometheus UI에서 직접 확인할 수 있습니다.

```text
http://172.16.8.110:9090
```

---

## 6. 수집 대상

### 6-1. 모니터링 스택 자체

| 대상 | 주소 | 설명 |
|---|---|---|
| Prometheus | `localhost:9090` | Prometheus 자체 상태 |
| Alertmanager | `alertmanager:9093` | Alertmanager 자체 상태 |

### 6-2. OpenStack 노드

| 노드 | Target | 역할 |
|---|---|---|
| `mgmt` | `172.16.8.200:9100` | Management |
| `controll` | `172.16.8.100:9100` | Controller |
| `network` | `172.16.8.101:9100` | Network |
| `storage` | `172.16.8.102:9100` | Storage |
| `compute1` | `172.16.8.103:9100` | Compute |
| `compute2` | `172.16.8.104:9100` | Compute |
| `monitor` | `172.16.8.110:9100` | Monitoring |

### 6-3. 서비스 인스턴스

| 계층 | Target | Exporter |
|---|---|---|
| Swarm Manager | `192.168.100.20:9100`, `192.168.100.21:9100`, `192.168.100.22:9100` | node_exporter |
| Swarm cAdvisor | `192.168.100.20:8080`, `192.168.100.21:8080`, `192.168.100.22:8080` | cAdvisor |
| Database | `192.168.101.31:9100`, `192.168.101.32:9100` | node_exporter |
| MySQL | `192.168.101.31:9104`, `192.168.101.32:9104` | mysql_exporter |
| DB Proxy | `192.168.101.40:9100`, `192.168.101.41:9105` | node_exporter / MaxScale Exporter |

DB Proxy 구축 과정은 별도 담당 범위이므로 이 문서에서는 수집 대상과 대시보드 표시 대상으로만 다룹니다.

### 6-4. Exporter별 역할

| Exporter | Port | 수집 내용 |
|---|---:|---|
| `node_exporter` | `9100` | CPU, Memory, Disk, Network, OS 상태 |
| `mysql_exporter` | `9104` | MariaDB 응답 여부, Primary/Replica, Replication 상태 |
| `cadvisor` | `8080` | Docker 컨테이너 CPU/Memory 등 리소스 |
| `maxctrl_exporter` | `9105` | MaxScale Backend DB 상태, Primary 상태, 세션/업타임 |

`node_exporter`는 OS 자원만 보여주므로 MaxScale 내부 상태까지 확인할 수 없습니다. 그래서 MaxScale REST API 값을 Prometheus metric 형식으로 변환하는 `maxctrl_exporter`가 별도로 사용되었습니다.

### 6-5. ZeroTier 기반 모니터링 접근 설계

인수인계 문서에는 팀원 PC에 VM이 분산될 경우를 대비해 ZeroTier 관리망을 사용하는 방안이 정리되어 있습니다. 핵심은 서비스 통신망과 모니터링 접근망을 분리하는 것입니다.

| 대역 | 용도 |
|---|---|
| `172.16.8.0/24` | ZeroTier 관리망, SSH, Ansible, Prometheus 수집 |
| `192.168.100.0/24` | OpenStack 내부 WAS/Swarm 서비스망 |
| `192.168.101.0/24` | OpenStack 내부 DB/Proxy 서비스망 |

현재 target 파일에는 서비스망 IP인 `192.168.100.x`, `192.168.101.x`가 포함되어 있습니다. monitor VM이 해당 내부망에 직접 접근하지 못하면 Prometheus target은 `DOWN`이 되고 `no route to host`가 발생합니다.

이 경우 권장 방향은 모니터링 대상 인스턴스에도 ZeroTier를 설치하고, Prometheus target을 접근 가능한 `172.16.8.x` 주소로 잡는 것입니다.

| 대상 | 서비스 IP 예시 | 모니터링 IP 예시 |
|---|---|---|
| `swarm-mg` | `192.168.100.20` | `172.16.8.120` |
| `swarm-mg2` | `192.168.100.21` | `172.16.8.121` |
| `swarm-mg3` | `192.168.100.22` | `172.16.8.122` |
| `db01` | `192.168.101.31` | `172.16.8.131` |
| `db02` | `192.168.101.32` | `172.16.8.132` |
| `db_proxy-01` | `192.168.101.40` | `172.16.8.140` |
| `db_proxy-02` | `192.168.101.41` | `172.16.8.141` |

서비스 통신은 기존 `192.168.100.x` / `192.168.101.x`를 유지하고, SSH/Ansible/Prometheus 수집만 `172.16.8.x`를 사용하는 것이 가장 단순합니다.

---

## 7. Grafana 대시보드

Grafana는 Prometheus를 데이터소스로 사용하여 `Cloud Infra Monitoring` 대시보드를 제공합니다.

대시보드 주요 영역:

| 영역 | 설명 |
|---|---|
| 전체 요약 | 전체 노드 수, UP 노드 수, DOWN 노드 수, Active Alerts |
| 계층/역할별 | node, role, layer 기준 상태 확인 |
| 변수별 상세 리소스 | 선택한 노드의 CPU, Memory, Disk, Network |
| DB | MySQL Exporter, SQL Response, Replication 상태 |
| MaxScale | MaxScale 실행 상태, Primary/Replica 상태 |
| Swarm / Container | cAdvisor, Container CPU/Memory |
| Alert 목록 | 현재 활성화된 Alert 목록 |

확인 시점의 Grafana 화면에서는 `Total Nodes`가 15개로 표시되었고, 다수 대상 VM 또는 exporter가 기동되지 않아 `No data` 및 `DOWN` 상태가 함께 표시되었습니다. 이는 Grafana 자체 장애라기보다 Prometheus target 접근 실패 상태를 반영한 것입니다.

### 7-1. 주요 패널과 쿼리

인수인계 문서 기준 Grafana 대시보드에서 의도한 주요 패널은 다음과 같습니다.

| 패널 | 목적 | 대표 PromQL |
|---|---|---|
| All Node Status | 전체 노드 UP/DOWN 확인 | `up{job="openstack-node"}` |
| DB Proxy Node Status | DB Proxy 노드 exporter 상태 확인 | `up{job="openstack-node", role="db-proxy"}` |
| Active MaxScale Proxy | MaxScale이 실행 중인 Proxy 노드 확인 | `max by (node) (maxctrl_status_uptime{job="maxscale", target_type="node"} > 0)` |
| VIP MaxScale Status | VIP 기준 MaxScale exporter 접근 확인 | `up{job="maxscale", target_type="vip"}` |
| MaxScale Backend DB Status | MaxScale이 보는 Backend DB 상태 확인 | `maxctrl_server_up{job="maxscale"}` |
| Current Primary DB | 현재 Primary/Master DB 확인 | `maxctrl_server_up{job="maxscale", status=~".*(Master|Primary).*"} == 1` |
| CPU Usage | 노드 CPU 사용률 | `100 - (avg by (node, role, layer) (rate(node_cpu_seconds_total{job="openstack-node", mode="idle"}[2m])) * 100)` |
| Memory Usage | 노드 메모리 사용률 | `100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)` |
| Disk Usage | 루트 파일시스템 사용률 | `100 * (1 - node_filesystem_avail_bytes / node_filesystem_size_bytes)` |
| Active Alerts | 현재 firing 알림 목록 | `ALERTS{alertstate="firing"}` |

Grafana 변수는 `node`, `role`, `layer` 기준으로 설계되어 있습니다. 패널에서 UP/DOWN은 보이는데 CPU, Memory, Disk가 보이지 않으면 target label 또는 port 오타를 먼저 확인합니다.

### 7-2. 대시보드 수정 시 주의사항

- 실습 또는 문서화 목적이면 조회만 하고 저장하지 않는 것을 권장합니다.
- 패널 수정 후 저장하면 다른 팀원 화면에도 영향을 줄 수 있습니다.
- Grafana 데이터소스 삭제, 기존 대시보드 삭제, 볼륨 삭제는 복구가 어려울 수 있습니다.

---

## 8. Alert Rule

Prometheus는 세 개의 rule 파일을 로드합니다.

| 파일 | Rule 수 | 주요 알림 |
|---|---:|---|
| `db-alerts.yml` | 5 | MySQL Exporter Down, DB Down, Replication 이상 |
| `maxscale-alerts.yml` | 4 | MaxScale Exporter Down, Backend Down, Primary 이상 |
| `node-alerts.yml` | 4 | Node Exporter Down, CPU/Memory/Disk 사용량 높음 |

확인 시점의 Prometheus Alerts 화면에서는 다음 알림이 firing 상태였습니다.

| Alert | 상태 | 의미 |
|---|---|---|
| `MySQLExporterDown` | Firing | MySQL Exporter 대상 접근 실패 |
| `NodeExporterDown` | Firing | node_exporter 대상 접근 실패 |

대상 VM이 꺼져 있거나 exporter가 실행되지 않으면 위 알림이 발생합니다.

---

## 9. Alertmanager 구성

Alertmanager는 Prometheus에서 전달받은 알림을 `team-alert-receiver`로 라우팅합니다.

```yaml
route:
  receiver: team-alert-receiver
  group_by:
    - alertname
    - node
  group_wait: 10s
  group_interval: 1m
  repeat_interval: 4h
```

Receiver는 Email과 Slack을 함께 사용합니다.

| Receiver | Secret 파일 | 설명 |
|---|---|---|
| Email | `/run/secrets/gmail_app_password` | Gmail SMTP App Password 사용 |
| Slack | `/run/secrets/slack_webhook_url` | Slack Incoming Webhook 사용 |

실제 이메일 주소, App Password, Slack Webhook URL은 GitHub에 올리지 않습니다. 운영 환경에서는 `secrets` 디렉토리의 파일로만 관리합니다.

Alertmanager 화면에서는 `team-alert-receiver` 기준으로 `MySQLExporterDown`, `NodeExporterDown` 알림이 그룹화되어 표시되었습니다.

### 9-1. Slack / Email 교체 대상

Alertmanager 알림 계정을 교체할 때 수정 대상은 다음과 같습니다.

| 목적 | 수정 파일 |
|---|---|
| Slack Webhook 교체 | `secrets/slack_webhook_url`, `alertmanager/alertmanager.yml` |
| Email App Password 교체 | `secrets/gmail_app_password`, `alertmanager/alertmanager.yml` |
| Secret mount 확인 | `compose.yml` |

현재 Compose 기준 secret 파일은 컨테이너 내부에서 아래 경로로 mount됩니다.

```text
/run/secrets/slack_webhook_url
/run/secrets/gmail_app_password
```

알림 설정만 바꾸는 경우 일반적으로 Alertmanager만 재시작하면 됩니다.

```bash
cd ~/monitoring
docker compose restart alertmanager
```

Prometheus의 Alertmanager target 또는 rule 파일까지 바꾼 경우에는 Prometheus 설정 검증도 함께 수행합니다.

```bash
docker exec prometheus promtool check config /etc/prometheus/prometheus.yml
```

### 9-2. Alertmanager 설정 검증

Alertmanager 설정 문법은 컨테이너 내부의 `amtool`로 확인합니다.

```bash
cd ~/monitoring
docker exec alertmanager amtool check-config /etc/alertmanager/alertmanager.yml
```

문제가 있으면 YAML 들여쓰기, receiver 이름, secret 파일 경로를 먼저 확인합니다.

### 9-3. Slack 알림 테스트

Webhook 자체 테스트:

```bash
WEBHOOK_URL=$(cat ~/monitoring/secrets/slack_webhook_url)
curl -X POST \
  -H 'Content-type: application/json' \
  --data '{"text":"[TEST] Alertmanager Slack Webhook 테스트 메시지입니다."}' \
  "$WEBHOOK_URL"
```

Alertmanager를 통한 테스트:

```bash
curl -XPOST http://localhost:9093/api/v2/alerts \
  -H "Content-Type: application/json" \
  -d '[
    {
      "labels": {
        "alertname": "ManualSlackTest",
        "severity": "test",
        "node": "monitor"
      },
      "annotations": {
        "summary": "Slack 알림 테스트",
        "description": "Alertmanager를 통한 Slack 알림 테스트입니다."
      },
      "startsAt": "'$(date -Iseconds)'"
    }
  ]'
```

### 9-4. Email 알림 테스트

```bash
curl -XPOST http://localhost:9093/api/v2/alerts \
  -H "Content-Type: application/json" \
  -d '[
    {
      "labels": {
        "alertname": "ManualEmailTest",
        "severity": "test",
        "node": "monitor"
      },
      "annotations": {
        "summary": "Email 알림 테스트",
        "description": "Alertmanager를 통한 Email 알림 테스트입니다."
      },
      "startsAt": "'$(date -Iseconds)'"
    }
  ]'
```

Gmail 인증 실패 시에는 App Password 오타, App Password 공백 포함, `smtp_auth_username`과 발급 계정 불일치, 2단계 인증 미활성화 여부를 확인합니다.

---

## 10. 현재 캡처 시점 상태

확인 시점의 핵심 상태는 다음과 같습니다.

| 항목 | 상태 |
|---|---|
| Prometheus 컨테이너 | 실행 중 |
| Grafana 컨테이너 | 실행 중 |
| Alertmanager 컨테이너 | 실행 중 |
| Prometheus 설정 문법 | 정상 |
| Prometheus 자체 target | UP |
| Alertmanager target | UP |
| OpenStack/Swarm/DB 대상 target | 대부분 DOWN |
| 주요 오류 | `connect: no route to host` |

Prometheus Targets 화면에서 `192.168.100.x`, `192.168.101.x` 대상은 `no route to host` 오류가 표시되었습니다. 이는 모니터링 VM에서 해당 네트워크의 대상 VM 또는 exporter로 접근하지 못하는 상태를 의미합니다.

### 10-1. 캡처 자료

문서화 시 확인한 화면은 다음 네 가지입니다.

| 화면 | 확인 내용 |
|---|---|
| Grafana `Cloud Infra Monitoring` | 전체 노드 15개, Active Alerts 17개, 다수 패널 `No data` 또는 `DOWN` |
| Prometheus Targets | `prometheus`, `alertmanager`는 UP, `cadvisor`, `maxscale`, `mysql`, `openstack-node`는 대부분 DOWN |
| Prometheus Alerts | `MySQLExporterDown`, `NodeExporterDown` firing 상태 확인 |
| Alertmanager Alerts | `team-alert-receiver` 기준으로 노드별 알림 그룹화 확인 |

GitHub에 이미지를 포함할 경우 아래와 같은 이름으로 저장해 본문에 연결하면 됩니다.

```text
images/01-grafana-cloud-infra-monitoring.png
images/02-prometheus-targets.png
images/03-prometheus-alerts.png
images/04-alertmanager-alerts.png
```

### 10-2. 알림 시연 캡처 만들기

문서화 품질을 높이려면 실제 장애를 만들기보다 Alertmanager API로 문서화용 테스트 알림을 주입하는 방식이 안전합니다. 운영 설정을 바꾸지 않고 Slack/Email 라우팅과 Alertmanager 화면을 확인할 수 있습니다.

테스트 알림 생성:

```bash
STARTS_AT=$(date -Iseconds)
ENDS_AT=$(date -Iseconds -d '+10 minutes')

curl -XPOST http://localhost:9093/api/v2/alerts \
  -H "Content-Type: application/json" \
  -d "[
    {
      \"labels\": {
        \"alertname\": \"DocumentationDemoAlert\",
        \"severity\": \"test\",
        \"node\": \"monitor\",
        \"role\": \"monitoring\"
      },
      \"annotations\": {
        \"summary\": \"문서화용 Alertmanager 알림 테스트\",
        \"description\": \"GitHub 문서 캡처를 위해 Alertmanager API로 주입한 테스트 알림입니다.\"
      },
      \"startsAt\": \"${STARTS_AT}\",
      \"endsAt\": \"${ENDS_AT}\"
    }
  ]"
```

캡처하면 좋은 화면:

| 캡처 | 설명 |
|---|---|
| Alertmanager Alerts | `DocumentationDemoAlert`가 `team-alert-receiver` 아래 표시되는 화면 |
| Slack 채널 | `[Cloud Monitoring] firing - DocumentationDemoAlert - monitor` 형태의 메시지 |
| Prometheus Alerts | 기존 rule 기반 알림과 별개로 Alertmanager 수동 주입 알림은 Prometheus rule 화면에는 나타나지 않을 수 있음 |

테스트 알림은 `endsAt` 이후 자동으로 resolved 상태가 됩니다. 즉시 정리하고 싶으면 같은 label로 `endsAt`을 현재 시각으로 다시 전송합니다.

---

## 11. 운영 확인 명령어

컨테이너 상태 확인:

```bash
cd ~/monitoring
docker compose ps
```

Prometheus 설정 검증:

```bash
docker exec prometheus promtool check config /etc/prometheus/prometheus.yml
```

Prometheus target 상태 확인:

```bash
curl -s 'http://localhost:9090/api/v1/query?query=up'
```

Prometheus 로그 확인:

```bash
docker compose logs --tail=100 prometheus
```

Grafana 로그 확인:

```bash
docker compose logs --tail=100 grafana
```

Alertmanager 로그 확인:

```bash
docker compose logs --tail=100 alertmanager
```

---

## 12. 트러블슈팅

### Grafana에서 `No data`가 보이는 경우

Grafana가 장애인 경우보다 Prometheus에 메트릭이 없거나 target이 DOWN인 경우가 많습니다.

확인 순서:

```bash
docker compose ps
docker exec prometheus promtool check config /etc/prometheus/prometheus.yml
curl -s 'http://localhost:9090/api/v1/query?query=up'
```

Prometheus UI에서도 확인합니다.

```text
http://172.16.8.110:9090/targets
```

### Prometheus target이 `DOWN`인 경우

주요 원인:

- 대상 VM이 꺼져 있음
- 대상 VM에서 exporter가 실행 중이지 않음
- Prometheus target IP 또는 port가 잘못됨
- 모니터링 VM에서 대상 네트워크로 라우팅이 되지 않음
- 방화벽 또는 보안그룹에서 exporter port가 차단됨

현재 확인된 대표 오류:

```text
connect: no route to host
```

이 오류는 Prometheus 설정 문법 문제가 아니라 네트워크 경로 또는 대상 VM 접근성 문제로 보는 것이 맞습니다.

### `NodeExporterDown` 알림이 발생하는 경우

대상 노드에서 `node_exporter`가 실행 중인지 확인합니다.

```bash
systemctl status node_exporter --no-pager
curl http://localhost:9100/metrics
```

원격에서 접근 가능한지도 확인합니다.

```bash
curl http://<target-ip>:9100/metrics
```

### Alertmanager 알림이 오지 않는 경우

확인 순서:

```bash
docker compose ps
docker logs alertmanager --tail=100
docker exec alertmanager ls -l /run/secrets
```

Slack Webhook URL과 Gmail App Password는 화면에 출력하지 않습니다.

---

## 13. 보안 주의사항

GitHub에 올리면 안 되는 정보:

- Slack Incoming Webhook URL
- Gmail App Password
- Grafana 관리자 비밀번호
- 실제 개인 이메일 주소
- 운영 계정 비밀번호

문서에는 아래처럼만 남깁니다.

```text
Slack Webhook URL: /run/secrets/slack_webhook_url
Gmail App Password: /run/secrets/gmail_app_password
Grafana Admin Password: .env 또는 운영자 별도 관리
```

---

## 14. 문서화 결론

현재 모니터링 스택은 Docker Compose 기반으로 실행되며 Prometheus, Grafana, Alertmanager 컨테이너는 정상 기동됩니다. Prometheus 설정 파일과 Alert Rule 문법도 정상으로 검증되었습니다.

다만 캡처 시점에는 OpenStack/Swarm/DB 계층의 대상 VM 또는 exporter에 접근하지 못해 Grafana에서 `No data`, Prometheus Targets에서 `DOWN`, Alertmanager에서 `NodeExporterDown` 및 `MySQLExporterDown` 알림이 표시되었습니다. 이 상태는 모니터링 시스템 자체 장애라기보다 수집 대상 미기동 또는 네트워크 라우팅 문제를 보여주는 상태입니다.

따라서 본 문서는 모니터링 스택의 구성, 수집 대상, 알림 흐름, 운영 확인 방법, target DOWN 시 트러블슈팅 기준을 인수인계하기 위한 기준 문서로 사용합니다.

---

## 15. 모니터링 파트 산출물 요약

진수님 산출물 중 모니터링 파트로 정리되는 기능은 다음과 같습니다.

| 기능 | 문서화 여부 | 설명 |
|---|---:|---|
| 모니터링 VM 운영 정보 | 완료 | `monitor`, `172.16.8.110`, Docker Compose 기반 운영 |
| Prometheus 구성 | 완료 | `prometheus.yml`, scrape job, file service discovery |
| Prometheus target 관리 | 완료 | `openstack_nodes.yml`, `mysql.yml`, `cadvisor.yml`, `maxscale.yml` |
| Prometheus rule 관리 | 완료 | `db-alerts.yml`, `maxscale-alerts.yml`, `node-alerts.yml` |
| Grafana 대시보드 | 완료 | `Cloud Infra Monitoring`, 노드/DB/Proxy/Container/Alert 패널 |
| PromQL 운영 쿼리 | 완료 | `up`, exporter 상태, DB replication, MaxScale metric |
| Alertmanager 라우팅 | 완료 | `team-alert-receiver`, `alertname`/`node` 기준 grouping |
| Slack 알림 | 완료 | Webhook secret 파일, 테스트 방법, 보안 주의사항 |
| Email 알림 | 완료 | Gmail SMTP App Password, 테스트 방법, 장애 확인 |
| Exporter 역할 | 완료 | node_exporter, mysql_exporter, cAdvisor, maxctrl_exporter |
| ZeroTier 기반 수집망 설계 | 완료 | `172.16.8.x` 관리망을 Prometheus 수집망으로 사용 |
| 현재 상태 캡처 해석 | 완료 | target DOWN, `No data`, `no route to host` 상태 설명 |
| 운영/트러블슈팅 명령어 | 완료 | 컨테이너 상태, 설정 검증, 로그, target 확인 |

DB Proxy 자체 구축 절차, Pacemaker/Corosync/VIP 구성, MariaDB Primary/Replica 구성은 이 문서의 범위에서 제외했습니다.
