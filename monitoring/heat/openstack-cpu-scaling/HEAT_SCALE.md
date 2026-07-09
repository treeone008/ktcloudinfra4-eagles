# Heat Swarm Worker Scaling (2026 환경)

> **monitoring1** 기준. Manager는 Heat 밖(web1~3), Worker만 Heat로 Scale.

## 아키텍처

| 구분 | VM | IP | Heat |
|---|---|---|---|
| Manager | web1, web2, web3 | 192.168.1.20~22 | ❌ 사전 구성 (Ansible/Swarm) |
| Worker | worker-01~03 | 192.168.1.23~25 | ✅ `worker_count` **0~3** |

- Network: **webserver** `192.168.1.0/24`, GW `192.168.1.1`
- Monitor: **mgmt** `172.16.8.200`, scrape CIDR `172.16.8.0/24`
- mgmt → tenant net: **static route** (Neutron router IP via) 필수

## 디렉터리

```text
heat/openstack-cpu-scaling/
  scale-cpu-test.yaml          # Worker만 생성
  userdata/
    ubuntu-worker-cloud-config.yaml
  heat-webhook.py              # Alertmanager → stack update
  prometheus/
    targets/swarm_nodes.yml
    rules/heat-cpu.yml
```

## A. 기존 스택 정리 (control)

```bash
source /etc/kolla/admin-openrc.sh

openstack stack delete swarm-scale-test --yes --wait 2>/dev/null

# 고아 VM/port (.23~.27)
openstack server list | grep -E 'worker-|swarm-'
openstack port list -c ID -c "Fixed IP Addresses" | grep 192.168.1.2
```

## B. 사전 조건

- web1~3 **ACTIVE**, Swarm Manager 초기화 완료
- web-sg(또는 동등 SG)에 mgmt→9100/8080 허용
- mgmt static route: `192.168.1.0/24`, `192.168.101.0/24`

## C. Heat 스택 생성

```bash
source /etc/kolla/admin-openrc.sh
cd ~/monitoring1/heat/openstack-cpu-scaling

# network/subnet UUID — webserver net
openstack network list
openstack subnet list --network webserver

PUBKEY=$(openstack keypair show project_key --public-key | tr -d '\r')

openstack stack create -t scale-cpu-test.yaml \
  --parameter network=<webserver-net-uuid> \
  --parameter subnet=<webserver-subnet-uuid> \
  --parameter image=ubuntu2204 \
  --parameter key_name=project_key \
  --parameter ssh_public_key="$PUBKEY" \
  --parameter flavor=m1.small \
  --parameter worker_count=1 \
  --parameter gateway=192.168.1.1 \
  swarm-scale-test

openstack stack show swarm-scale-test -c stack_status
openstack server list | grep worker
```

## D. Worker Swarm Join (Heat 이후)

Heat cloud-init은 `/run/swarm-token` 파일이 있을 때만 join.

**Ansible 권장:** worker 생성 후 play로 token 전달 + `docker swarm join`.

수동 (web1에서 token → worker):

```bash
# web1
docker swarm join-token worker -q

# worker (콘솔/SSH)
echo '<token>' | sudo tee /run/swarm-token
sudo /usr/local/bin/swarm-worker-join.sh
```

## E. Scale Out / In

```bash
openstack stack update --existing swarm-scale-test \
  --parameter worker_count=3 --wait

openstack server list | grep worker
```

Webhook (mgmt, venv + nohup):

```bash
source ~/venv/bin/activate
source ~/admin-service-openrc.sh
cd ~/monitoring1/heat/openstack-cpu-scaling/scripts

./start-heat-webhook.sh start
# 또는 수동:
# export HEAT_STACK=swarm-scale-test HEAT_SCALE_MODE=parameter
# export OPENSTACK_BIN=~/venv/bin/openstack
# unset OS_CLOUD
# python3 ../heat-webhook.py

# Alertmanager webhook → http://127.0.0.1:8080/scale/up|down (mgmt)
```

## F. Prometheus

`prometheus/targets/swarm_nodes.yml` + `rules/heat-cpu.yml`  
Manager CPU >80% → ScaleUp, <40% → ScaleDown (worker 최소 1).

```bash
cd ~/monitoring1
docker compose stop prometheus && docker compose rm -f prometheus && docker compose up -d prometheus
```

## G. CPU stress (Scale Up 테스트)

```bash
cd ~/monitoring1/heat/openstack-cpu-scaling/scripts
chmod +x stress-web-cpu.sh

# openstack에서 직접 (라우트 있으면)
./stress-web-cpu.sh start 2
./stress-web-cpu.sh status
./stress-web-cpu.sh stop

# mgmt → qrouter → web
export SSH_KEY=~/openstack2.pem
export JUMP_HOST=172.16.8.100
export QROUTER_NS=$(ssh root@172.16.8.100 "ip netns list | grep qrouter | awk '{print \$1}'")
./stress-web-cpu.sh start 2
```

Prometheus: `swarm:manager_cpu_usage:percent` > 80 (2m) → Scale Up

## H. 검증

```bash
curl -s http://192.168.1.23:9100/metrics | head
curl -s http://192.168.1.23:8080/metrics | head
# Prometheus: up{job="swarm_nodes",role="swarm-worker"}
```

## Deprecated

- `swarm-mg` / `192.168.100.x` — 이전 템플릿
- `ubuntu-mg-cloud-config.yaml` — Manager는 web1~3 사용, Heat에서 생성하지 않음
