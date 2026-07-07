# Ubuntu CPU 스케일링

> control + monitor 순서대로 실행. 값은 환경에 맞게 이미 확인된 것 사용.

---

## A. control — 전부 지우기

```bash
source /etc/kolla/admin-openrc.sh
cd ~/heat   # scale-cpu-test.yaml 있는 디렉터리

# Heat 스택
openstack stack delete swarm-scale-test --yes --wait 2>/dev/null
openstack stack delete scale-test --yes --wait 2>/dev/null

# 스택 잔여 VM 확인
openstack server list -c Name -c ID -c Status | grep -E 'swarm|scale-vm'

# 스택 밖에 남은 VM 있으면 (이름 확인 후)
# openstack server delete <id>

# 고아 port (.20~.28)
openstack port list -c ID -c "Fixed IP Addresses" -c Device | grep 192.168.100
# Device 컬럼이 비어 있거나 이상하면:
# openstack port delete <port-id>

openstack stack list
openstack server list | grep -E 'swarm|scale-vm'   # 비어 있어야 함
```

---

## B. control — 파일 확인

`~/heat/` 구조:

```text
~/heat/
  scale-cpu-test.yaml
  userdata/
    ubuntu-mg-cloud-config.yaml
    ubuntu-worker-cloud-config.yaml
```

검증:

```bash
grep user_data_format scale-cpu-test.yaml | head -1
# user_data_format: RAW  ← SOFTWARE 아님

ls userdata/ubuntu-mg-cloud-config.yaml userdata/ubuntu-worker-cloud-config.yaml
```

---

## C. monitor — webhook 끄기 (돌고 있으면)

```bash
pkill -f heat-webhook.py 2>/dev/null
```

---

## D. monitor — mirror (node_exporter 설치용)

```bash
cd ~/monitoring   # serve-node-exporter-mirror.sh 위치
bash scripts/serve-node-exporter-mirror.sh
# 또는 openstack-cpu-scaling/scripts/ 복사 후 실행

# 다른 터미널
curl -I http://127.0.0.1:8888/node_exporter.tar.gz
```

---

## E. control — stack 생성

```bash
source /etc/kolla/admin-openrc.sh
cd ~/heat

openstack stack create -t scale-cpu-test.yaml \
  --parameter network=fd0108a6-902d-47b5-8862-e33bddc9a07e \
  --parameter subnet=963ce3e4-680a-4ca7-80ef-e025b810a442 \
  --parameter image=ubuntu2204 \
  --parameter key_name=project_key \
  --parameter flavor=m1.small \
  --parameter worker_count=1 \
  swarm-scale-test

openstack stack show swarm-scale-test -c stack_status -c stack_status_reason
# CREATE_COMPLETE 될 때까지 대기 (수 분)

openstack server list -c Name -c Networks -c Status | grep swarm
# swarm-mg         192.168.100.20   ACTIVE
# swarm-worker-23  192.168.100.23   ACTIVE
```

---

## F. SSH 접속 (control 또는 pem 있는 PC)

```bash
chmod 600 project_key.pem
ssh -i project_key.pem ubuntu@192.168.100.20
```

VM 안 (cloud-init 2~3분 후):

```bash
ip addr show eth0
sudo tail -40 /var/log/cloud-init-output.log
sudo systemctl status node_exporter --no-pager
curl -s http://127.0.0.1:9100/metrics | grep node_cpu | head
```

---

## G. monitor — Prometheus

### G1. ping-pong rule 끄기

```bash
cd ~/monitoring/prometheus/rules
mv heat-test.yml heat-test.yml.disabled 2>/dev/null
```

### G2. CPU rule

`heat-cpu.yml` 이 `rules/` 에 있는지 확인.

### G3. targets (고정 IP)

`~/monitoring/prometheus/targets/swarm_nodes.yml`:

```yaml
- targets: ['192.168.100.20:9100']
  labels:
    job: swarm_nodes
    role: swarm-mg

- targets:
    - '192.168.100.23:9100'
    - '192.168.100.24:9100'
    - '192.168.100.25:9100'
    - '192.168.100.26:9100'
    - '192.168.100.27:9100'
    - '192.168.100.28:9100'
  labels:
    job: swarm_nodes
    role: swarm-worker
```

### G4. reload

```bash
cd ~/monitoring/prometheus
docker exec prometheus promtool check config /etc/prometheus/prometheus.yml
docker compose restart prometheus
```

확인: http://172.16.8.110:9090/targets → `swarm_nodes` mg/worker **UP**

```bash
curl -s http://192.168.100.20:9100/metrics | grep node_cpu | head
```

---

## H. monitor — webhook adapter

```bash
cd ~/monitoring
source venv/bin/activate
pip install flask python-openstackclient python-heatclient 2>/dev/null

export OS_CLOUD=openstack
export HEAT_STACK=swarm-scale-test
export HEAT_SCALE_MODE=parameter
export HEAT_WORKER_MIN=1
export HEAT_WORKER_MAX=6
export HEAT_COOLDOWN=180

nohup python3 heat-webhook.py >> heat-webhook.log 2>&1 &
curl http://127.0.0.1:8080/health
```

(`heat-webhook.py`는 openstack-cpu-scaling 버전 — parameter 모드)

---

## I. CPU 스케일 테스트

```bash
# mg SSH
sudo /usr/local/bin/stress-cpu.sh start 1

# monitor — 2~3분 후
# Prometheus Alerts: SwarmWorkerScaleUp Firing
# openstack server list | grep swarm-worker   # .24 추가 등
```

부하 중지:

```bash
sudo /usr/local/bin/stress-cpu.sh stop
```

---

## J. 문제 시

| 증상 | 확인 |
|------|------|
| stack CREATE_FAILED | `openstack stack event list swarm-scale-test` |
| SSH refused | SG 22, ping 192.168.100.20 |
| node_exporter down | cloud-init-output.log, mirror 8888 |
| target DOWN | monitor → :9100 curl |
| scale 안 됨 | heat-webhook.log, HEAT_SCALE_MODE=parameter |

---

## 한 줄 체크리스트

- [ ] A 스택/고아 port 삭제
- [ ] D mirror 8888
- [ ] E stack CREATE_COMPLETE
- [ ] F SSH + node_exporter active
- [ ] G Prometheus targets UP
- [ ] H webhook health ok
- [ ] I stress → worker +1
