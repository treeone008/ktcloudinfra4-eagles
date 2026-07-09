# OpenStack Heat 오토스케일 × 외부 모니터링 연동 가이드

> Docker Swarm worker 자동 증감을 목표로 한 **Prometheus → Alertmanager → Heat** 경로 구축·검증 기록입니다.  
> Kolla 내부 Prometheus/Grafana는 사용하지 않고, **외부 모니터링 VM**만 사용합니다.

**관련 문서:** [모니터링 머신 사용 가이드](./monitoring_machine_usage_guide.md) (Grafana/Prometheus/Alertmanager 일반 사용법)

---

## 목차

1. [배경과 아키텍처 선택](#1-배경과-아키텍처-선택)
2. [환경 정보](#2-환경-정보)
3. [전체 데이터 흐름](#3-전체-데이터-흐름)
4. [1단계: OpenStack Exporter](#4-1단계-openstack-exporter)
5. [2단계: Prometheus 연동](#5-2단계-prometheus-연동)
6. [3단계: Heat ASG + 수동 Signal](#6-3단계-heat-asg--수동-signal)
7. [4단계: Webhook Adapter](#7-4단계-webhook-adapter)
8. [5단계: Alertmanager + 알람 Rule](#8-5단계-alertmanager--알람-rule)
9. [End-to-End 검증](#9-end-to-end-검증)
10. [트러블슈팅](#10-트러블슈팅)
11. [테스트 중지·정리](#11-테스트-중지정리)
12. [다음 단계 (본 프로젝트)](#12-다음-단계-본-프로젝트)

---

## 1. 배경과 아키텍처 선택

### 시도했던 경로: Aodh (미채택)

Kolla 내부 Prometheus + Heat `OS::Aodh::Prometheus` 알람을 먼저 시도했습니다.

| 문제 | 내용 |
|------|------|
| `insufficient data` | Aodh가 Keystone **`metric-storage`** 서비스를 찾지 못함 (Kolla 기본 미등록) |
| Prometheus 접근 | VIP 파싱 오류, Basic Auth 401 등으로 Aodh ↔ Prometheus 경로 불안정 |
| 역할 혼동 | Grafana는 Prometheus 직접 조회 OK, Aodh만 catalog 경로 실패 |

**결론:** OpenStack 내부 Aodh 경로는 보류하고, **외부 Prometheus + Alertmanager**로 알람·webhook을 처리합니다.

### 채택한 경로: Alertmanager (경로 B)

```
[외부 monitor VM]
  Prometheus (alert rules)
       ↓ firing
  Alertmanager (webhook receiver)
       ↓ POST
  heat-webhook.py (:8080)
       ↓ openstack stack resource signal
[OpenStack]
  Heat ScalingPolicy → AutoScalingGroup → Nova VM ±
```

| 구성 | 역할 |
|------|------|
| **Prometheus** (외부) | 메트릭 수집, PromQL 알람 규칙 |
| **Alertmanager** (외부) | 알람 라우팅, Heat webhook 전송 |
| **Grafana** (외부) | 대시보드 (스케일 트리거 아님) |
| **Heat** | min/max, scaling policy, VM ± 실행 |
| **Aodh** | **이 경로에서 불필요** |

---

## 2. 환경 정보

| 항목 | 값 |
|------|-----|
| OpenStack | Kolla-Ansible 멀티노드 |
| OpenStack VIP | `172.16.8.105` (Keystone `:5000` 등) |
| 모니터링 VM | `monitor`, IP `172.16.8.110` |
| 모니터링 작업 디렉터리 | `~/monitoring`, `~/monitoring/prometheus` |
| Heat 테스트 스택 | `scale-test` |
| 테스트 네트워크 UUID | `fd0108a6-902d-47b5-8862-e33bddc9a07e` |

### 주요 URL

| 서비스 | URL |
|--------|-----|
| Grafana | http://172.16.8.110:3000 |
| Prometheus | http://172.16.8.110:9090 |
| Alertmanager | http://172.16.8.110:9093 |
| OpenStack Exporter | http://172.16.8.110:9198/metrics |
| Heat Webhook Adapter | http://172.16.8.110:8080 |

### 주요 파일 (monitor VM)

| 파일 | 경로 |
|------|------|
| OpenStack 인증 | `/etc/openstack/clouds.yaml` |
| Webhook adapter | `~/monitoring/heat-webhook.py` |
| Python venv | `~/monitoring/venv` |
| Prometheus 설정 | `~/monitoring/prometheus/prometheus.yml` |
| Alertmanager 설정 | `~/monitoring/prometheus/alertmanager.yml` |
| 테스트 알람 rule | `~/monitoring/prometheus/rules/heat-test.yml` |

---

## 3. 전체 데이터 흐름

```mermaid
flowchart LR
  subgraph external [모니터링 VM 172.16.8.110]
    OSE[openstack-exporter :9198]
    Prom[Prometheus :9090]
    AM[Alertmanager :9093]
    WH[heat-webhook.py :8080]
    OSE -->|scrape| Prom
    Prom -->|firing| AM
    AM -->|POST /scale/up\|down| WH
  end

  subgraph openstack [OpenStack 172.16.8.105]
    API[Keystone / Nova / Heat API]
    ASG[AutoScalingGroup]
    SP[ScalingPolicy]
    Nova[Nova VM]
    WH -->|stack resource signal| SP
    SP --> ASG
    ASG --> Nova
    OSE -->|API 조회| API
  end
```

**완료된 검증 구간:** exporter → Prometheus → (rule) → Alertmanager → webhook → Heat signal → VM ± → `openstack_nova_total_vms` 변화

---

## 4. 1단계: OpenStack Exporter

### 4.1 사전 확인

monitor VM에서 OpenStack API 도달:

```bash
curl -s --connect-timeout 3 http://172.16.8.105:5000/v3/ | head
# version JSON → OK
```

### 4.2 clouds.yaml

control 노드의 admin 정보로 작성. cloud 이름은 **`openstack`** (exporter 인자와 일치).

```yaml
clouds:
  openstack:
    auth:
      auth_url: http://172.16.8.105:5000/v3
      username: admin
      password: <passwords.yml에서>
      project_name: admin
      user_domain_name: Default
      project_domain_name: Default
    region_name: RegionOne
    interface: internal
```

**최종 배치:** `/etc/openstack/clouds.yaml` + `chmod 644`

> `/home/jinsu/...` 아래 두면 홈 디렉터리 권한(750) 때문에 컨테이너가 **permission denied** 발생.

### 4.3 Docker 실행

```bash
docker run -d --name openstack-exporter \
  --restart unless-stopped \
  -p 9198:9180 \
  -v /etc/openstack/clouds.yaml:/etc/openstack/clouds.yaml:ro \
  ghcr.io/openstack-exporter/openstack-exporter:latest \
  openstack
```

### 4.4 확인

```bash
docker logs openstack-exporter --tail 10
curl -s http://127.0.0.1:9198/metrics | grep openstack_nova_total_vms
curl -s http://127.0.0.1:9198/metrics | grep -c "^openstack_"
# autodetect: network, compute, image, volume, identity, gnocchi, orchestration, placement
```

### 4.5 겪었던 문제

| symptom | 원인 | 해결 |
|-----------|------|------|
| `is a directory` | `-v ./openstack/clouds.yaml` 경로 오류 | 실제 파일 경로로 마운트 |
| `permission denied` | `/home/...` 마운트 | `/etc/openstack/clouds.yaml` + 644 |

---

## 5. 2단계: Prometheus 연동

### 5.1 scrape 설정

**주의:** Prometheus도 Docker면 `127.0.0.1:9198`은 **Prometheus 컨테이너 자신**을 가리킴 → Empty query result.

`prometheus.yml`에 **호스트 IP** 사용:

```yaml
scrape_configs:
  - job_name: openstack_exporter
    scrape_interval: 60s
    scrape_timeout: 55s
    static_configs:
      - targets: ['172.16.8.110:9198']
```

### 5.2 Alertmanager 연결 (prometheus.yml)

```yaml
alerting:
  alertmanagers:
    - static_configs:
        - targets: ['127.0.0.1:9093']
        # docker compose 같은 네트워크면 alertmanager:9093
```

### 5.3 확인

```bash
docker exec prometheus promtool check config /etc/prometheus/prometheus.yml
docker compose restart prometheus
```

- Targets: http://172.16.8.110:9090/targets → `openstack_exporter` **UP**
- Query: `openstack_nova_total_vms`
- Status → Alertmanagers → **UP**

---

## 6. 3단계: Heat ASG + 수동 Signal

Alertmanager 연결 전, **Heat가 signal을 받아 VM을 ± 하는지** control에서 먼저 검증합니다.

### 6.1 scale-test.yaml

```yaml
heat_template_version: 2018-08-31

parameters:
  network:
    type: string

resources:
  asg:
    type: OS::Heat::AutoScalingGroup
    properties:
      min_size: 0
      max_size: 2
      desired_capacity: 1
      resource:
        type: OS::Nova::Server
        properties:
          name: scale-vm
          image: cirros
          flavor: m1.tiny
          networks:
            - network: { get_param: network }

  scale_up:
    type: OS::Heat::ScalingPolicy
    properties:
      auto_scaling_group_id: { get_resource: asg }
      adjustment_type: change_in_capacity
      scaling_adjustment: 1
      cooldown: 120

  scale_down:
    type: OS::Heat::ScalingPolicy
    properties:
      auto_scaling_group_id: { get_resource: asg }
      adjustment_type: change_in_capacity
      scaling_adjustment: -1
      cooldown: 120

outputs:
  scale_up_policy:
    value: { get_attr: [scale_up, alarm_url] }
  scale_down_policy:
    value: { get_attr: [scale_down, alarm_url] }
```

### 6.2 배포 (control)

```bash
source /etc/kolla/admin-openrc.sh

openstack stack create -t scale-test.yaml \
  --parameter network=fd0108a6-902d-47b5-8862-e33bddc9a07e \
  scale-test

openstack stack show scale-test -c stack_status
openstack server list | grep scale-vm
```

### 6.3 수동 signal

```bash
openstack stack resource signal scale-test scale_up
openstack server list | grep scale-vm    # 2대

# scale_up 직후 2분(cooldown) 대기 필수
openstack stack resource signal scale-test scale_down
openstack server list | grep scale-vm    # 1대
```

### 6.4 cooldown 이해

| 현상 | 설명 |
|------|------|
| `SIGNAL_COMPLETE` | policy에 signal **도착** (처리 큐에 들어감) |
| cooldown 120초 | scale_up 직후 scale_down은 **무시**될 수 있음 |
| Prometheus | VM ± 후 `openstack_nova_total_vms` 숫자 변화 확인 |

---

## 7. 4단계: Webhook Adapter

Alertmanager는 Heat `signal_url`(trust+URL)을 직접 치기 어렵습니다. **중간 adapter**가 `openstack stack resource signal`을 실행합니다.

### 7.1 venv 및 패키지 (monitor VM)

```bash
cd ~/monitoring
python3 -m venv venv
source venv/bin/activate

pip install flask python-openstackclient python-heatclient
```

> **`python-heatclient` 필수.** 없으면 `openstack stack resource signal` 명령 자체가 없어 500 에러.

### 7.2 heat-webhook.py

`~/monitoring/heat-webhook.py`:

```python
#!/usr/bin/env python3
import os
import subprocess
import logging
from flask import Flask, request

app = Flask(__name__)
logging.basicConfig(level=logging.INFO)

STACK = os.environ["HEAT_STACK"]
POLICY_UP = os.environ.get("POLICY_UP", "scale_up")
POLICY_DOWN = os.environ.get("POLICY_DOWN", "scale_down")
OS_CLOUD = os.environ.get("OS_CLOUD", "openstack")

def signal(policy: str):
    cmd = [
        "openstack", "--os-cloud", OS_CLOUD,
        "stack", "resource", "signal",
        STACK, policy,
    ]
    app.logger.info("running: %s", " ".join(cmd))
    subprocess.check_call(cmd)

@app.post("/scale/up")
def scale_up():
    app.logger.info("scale up webhook: %s", request.get_data(as_text=True)[:200])
    signal(POLICY_UP)
    return "ok\n", 200

@app.post("/scale/down")
def scale_down():
    app.logger.info("scale down webhook: %s", request.get_data(as_text=True)[:200])
    signal(POLICY_DOWN)
    return "ok\n", 200

@app.get("/health")
def health():
    return "ok\n", 200

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
```

### 7.3 실행

```bash
cd ~/monitoring
source venv/bin/activate
export OS_CLOUD=openstack
export HEAT_STACK=scale-test

python3 heat-webhook.py
# 상시: nohup python3 heat-webhook.py >> heat-webhook.log 2>&1 &
```

### 7.4 수동 테스트

```bash
curl http://127.0.0.1:8080/health
curl -X POST http://127.0.0.1:8080/scale/up
# control: openstack server list | grep scale-vm
# scale_up 후 2분 뒤
curl -X POST http://127.0.0.1:8080/scale/down
```

---

## 8. 5단계: Alertmanager + 알람 Rule

### 8.1 Prometheus 테스트 rule

`~/monitoring/prometheus/rules/heat-test.yml`:

```yaml
groups:
  - name: heat_webhook_test
    rules:
      - alert: HeatScaleUpTest
        expr: openstack_nova_total_vms == 1
        for: 30s
        labels:
          severity: warning
          action: scale_up
        annotations:
          summary: "test scale up via alertmanager"

      - alert: HeatScaleDownTest
        expr: openstack_nova_total_vms >= 2
        for: 30s
        labels:
          severity: info
          action: scale_down
        annotations:
          summary: "test scale down via alertmanager"
```

> **테스트 전용.** VM 1대면 scale_up, 2대면 scale_down이 계속 Firing → **1↔2 ping-pong** (의도된 동작).

`prometheus.yml`에 rule 경로 포함:

```yaml
rule_files:
  - /etc/prometheus/rules/*.yml
```

### 8.2 Alertmanager 설정 (merge 방식)

**`route:`와 `receivers:`는 YAML 최상위에 각각 한 번만.** 기존 Slack 등 receiver와 **merge**합니다.

```yaml
route:
  receiver: default          # 기존 default 유지
  group_wait: 10s
  group_interval: 1m
  repeat_interval: 5m        # Heat cooldown(120s)보다 길게
  routes:
    # ... 기존 routes ...
    - matchers: ['action="scale_up"']
      receiver: heat-scale-up
      repeat_interval: 5m
    - matchers: ['action="scale_down"']
      receiver: heat-scale-down
      repeat_interval: 10m

receivers:
  # ... 기존 receivers (Slack 등) ...

  - name: heat-scale-up
    webhook_configs:
      - url: 'http://172.16.8.110:8080/scale/up'
        send_resolved: false

  - name: heat-scale-down
    webhook_configs:
      - url: 'http://172.16.8.110:8080/scale/down'
        send_resolved: false
```

| 설정 | 이유 |
|------|------|
| `repeat_interval: 5m` | Heat cooldown과 맞춰 webhook 연속 폭주 방지 |
| `send_resolved: false` | resolved 시 scale_down 중복 호출 방지 |

### 8.3 검증 및 재시작

```bash
cd ~/monitoring/prometheus

docker run --rm \
  -v $(pwd)/alertmanager.yml:/etc/alertmanager/alertmanager.yml:ro \
  prom/alertmanager:v0.33.0 \
  amtool check-config /etc/alertmanager/alertmanager.yml

docker compose restart alertmanager
docker ps | grep alertmanager    # Up (Restarting 아님)
curl -s http://127.0.0.1:9093/-/healthy
```

---

## 9. End-to-End 검증

### 9.1 성공 기준

**VM이 1대 ↔ 2대 반복**하면 파이프라인 전체 성공입니다.

```
Prometheus (Firing) → Alertmanager → webhook → Heat signal → Nova ±
```

Prometheus `openstack_nova_total_vms`도 같이 오르내리면 완료.

### 9.2 짧은 확인 시나리오 (약 10분)

| # | 확인 | 명령/위치 |
|---|------|-----------|
| 1 | 스택 1대 | control: `openstack server list \| grep scale-vm` |
| 2 | scale_up Firing | Prometheus Alerts: `HeatScaleUpTest` |
| 3 | AM 수신 | http://172.16.8.110:9093 |
| 4 | webhook | `tail -f ~/monitoring/heat-webhook.log` |
| 5 | VM +1 | control: scale-vm **2대**, event `SIGNAL_COMPLETE` |
| 6 | cooldown | **2분 대기** |
| 7 | scale_down Firing | `HeatScaleDownTest` |
| 8 | VM -1 | scale-vm **1대** |

### 9.3 ping-pong이 반복되는 이유 (정상)

| Rule | 조건 | 결과 |
|------|------|------|
| HeatScaleUpTest | `== 1` | 1대일 때 +1 |
| HeatScaleDownTest | `>= 2` | 2대일 때 -1 |

→ 테스트 rule 설계상 **무한 루프**. 실습·데모 성공 지표이며, 운영에서는 CPU 등 + 히스테리시스로 교체 필요.

---

## 10. 트러블슈팅

| 증상 | 볼 곳 | 조치 |
|------|--------|------|
| Prometheus query empty | Targets | scrape target을 **172.16.8.110:9198** 로 |
| exporter permission denied | docker logs | `/etc/openstack/clouds.yaml` + 644 |
| webhook 500 | adapter 로그 | venv에서 `pip install python-heatclient` |
| `HEAT_STACK` KeyError | 실행 전 | `export HEAT_STACK=scale-test` |
| scale_down 안 됨 | stack event | scale_up 후 **2분 cooldown** 대기 |
| AM Restarting (1) | docker logs | `route`/`receivers` **중복** 제거 |
| `:9093` connection refused | docker ps | AM Up + 포트 9093 매핑 |
| Firing인데 webhook 없음 | Prom → AM | prometheus.yml `alertmanagers` UP 확인 |
| VIP 파싱 깨짐 | globals.yml | `grep` 대신 **172.16.8.105** 리터럴 사용 |

### Alertmanager 중복 YAML 오류

```
line 60: field route already set
line 73: field receivers already set
```

Heat webhook 블록을 **파일 맨 아래에 추가**하지 말고, 기존 `route:` / `receivers:` **안에 merge**.

---

## 11. 테스트 중지·정리

### 11.1 VM 1↔2 반복만 멈추기

**webhook adapter만 중지:**

```bash
# adapter 터미널 Ctrl+C
pkill -f heat-webhook.py
```

| 구간 | 중지 후 |
|------|---------|
| Heat / VM | **± 안 함** (1대 또는 2대 고정) |
| Prometheus | 알람 **계속 Firing** |
| Alertmanager | webhook **connection refused** 로그 |

### 11.2 알람까지 조용히

| 방법 | 명령 |
|------|------|
| Rule 끄기 | `heat-test.yml` rename 또는 rule_files에서 제거 → `docker restart prometheus` |
| AM Silence | Alertmanager UI → Silence |
| AM 중지 | `docker stop alertmanager` |

### 11.3 테스트 리소스 삭제

```bash
# adapter 끈 뒤 control
openstack stack delete scale-test --yes --wait
```

---

## 12. 다음 단계 (본 프로젝트)

| 항목 | 내용 |
|------|------|
| Heat 템플릿 | cirros `scale-test` → **Swarm worker** VM |
| 메트릭 | `openstack_nova_total_vms` → **node_exporter CPU/메모리** |
| 알람 rule | scale_up/down **히스테리시스** (예: CPU 80% 5분 / 20% 10분) |
| adapter | **systemd** 또는 gunicorn으로 상시 운영 |
| 인프라 | Octavia LB, Swarm manager 3 + worker n, MaxScale + MariaDB |
| 모니터링 | **외부 VM만** — Kolla VIP `:9091` / `:3000` 미사용 |

### 멘토링용 한 줄 요약

> 외부 Prometheus 알람이 Alertmanager webhook으로 Heat scaling policy를 호출해 worker VM이 자동으로 늘었다 줄었다 하는 것을 검증했다. Aodh 대신 Alertmanager + webhook adapter 경로를 사용한다.

---

## 부록: 진행 체크리스트

| 단계 | 내용 | 상태 |
|------|------|------|
| 1 | clouds.yaml + OpenStack API | ✅ |
| 2 | openstack-exporter (:9198) | ✅ |
| 3 | Prometheus scrape (호스트 IP) | ✅ |
| 4 | Heat ASG + 수동 signal | ✅ |
| 5 | heat-webhook adapter (curl ±) | ✅ |
| 6 | Alertmanager + heat-test rule | ✅ |
| 7 | E2E 1↔2 자동 반복 | ✅ |
| 8 | Swarm worker / CPU 기반 운영 rule | 🔜 |

---

*문서 작성 기준: 2026-07-02, 외부 monitor VM + OpenStack Heat scale-test 파이프라인 검증 완료.*
