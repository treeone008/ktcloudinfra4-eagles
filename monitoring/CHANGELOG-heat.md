# monitoring1 변경 요약 (Heat / Swarm)

원본 `monitoring` 은 유지. 작업본은 **`monitoring1`**.

## Swarm / Heat 구조 변경

| 항목 | 이전 | monitoring1 |
|---|---|---|
| Manager | Heat `swarm-mg` 192.168.100.20 | **web1~3** 192.168.1.20~22 (Heat 밖) |
| Worker | .23~.28 (max 6) | **.23~.25 (max 3, min 0)** |
| Subnet | 192.168.100.0/24 | **192.168.1.0/24** |
| Gateway | 192.168.100.1 | **192.168.1.1** |
| Monitor mirror | 172.16.8.110 | **172.16.8.200 (mgmt)** |

## 수정된 주요 파일

- `heat/openstack-cpu-scaling/scale-cpu-test.yaml` — Worker만, HA Manager 분리
- `userdata/ubuntu-worker-cloud-config.yaml` — node_exporter + cadvisor + swarm join hook
- `prometheus/targets/swarm_nodes.yml` — 신규
- `prometheus/rules/heat-cpu.yml` — Manager(web1~3) CPU 기준
- `prometheus/targets/openstack_nodes.yml` — worker .23~.27
- `prometheus/targets/cadvisor.yml` — worker cadvisor
- `prometheus/prometheus.yml` — `swarm_nodes` job 추가
- `heat-webhook.py` — WORKER_MAX=3

## 배포 전 체크

1. web1~3 Swarm Manager ready
2. mgmt static route → 192.168.1.0/24
3. Heat stack create → Ansible worker join
4. Prometheus reload

자세한 절차: `heat/openstack-cpu-scaling/HEAT_SCALE.md`
