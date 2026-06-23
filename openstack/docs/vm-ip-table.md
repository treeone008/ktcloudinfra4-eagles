# 팀 공유 — OpenStack VM / IP 표 (AIO 환경)

> 작성: 김현도 | 환경: 노트북 VMware AIO (`testopenstack`) | 기준일: 2026-06-23  
> 시연 메인 PC가 따로 있어도 **IP 설계·역할 분담은 이 표를 기준**으로 맞추면 됩니다.

---

## 1. OpenStack 호스트 (관리)

| 항목 | 값 |
|------|-----|
| VMware VM | `testopenstack.vmx` |
| 호스트 IP | `172.16.8.100` |
| Horizon | http://172.16.8.100 |
| SSH (호스트) | `root@172.16.8.100` (MobaXterm) |
| OpenStack CLI | `kolla_toolbox` 컨테이너 + `/tmp/admin-openrc.sh` |
| VMware NAT | vmnet8 = `172.16.8.0/24` |

---

## 2. Neutron 네트워크

| 이름 | CIDR | 용도 |
|------|------|------|
| public | `192.168.100.0/24` | master, swarm, monitor |
| private | `192.168.101.0/24` | db01, db02 (외부 FIP 없음) |
| external | `sharednet1` | Floating IP 풀 (`172.16.8.x`) |
| 라우터 | `project-router` | private ↔ external 연결 |

---

## 3. Tenant VM 6대

| VM 이름 | 역할 | 네트워크 | Private IP | Floating IP | SSH (팀원용) |
|---------|------|----------|------------|-------------|--------------|
| master | Ansible/Swarm 진입점 | public | `192.168.100.10` | `172.16.8.146` | `ubuntu@172.16.8.146` |
| swarm-mg | Docker Swarm Manager | public | `192.168.100.20` | (없음) | master에서 `ubuntu@192.168.100.20` |
| swarm-worker | Docker Swarm Worker | public | `192.168.100.21` | (없음) | master에서 `ubuntu@192.168.100.21` |
| monitor | Prometheus/Grafana | public | `192.168.100.40` | (없음) | master에서 `ubuntu@192.168.100.40` |
| db01 | MariaDB Primary | private | `192.168.101.31` | (없음) | master에서 `ubuntu@192.168.101.31` |
| db02 | MariaDB Replica | private | `192.168.101.32` | (없음) | master에서 `ubuntu@192.168.101.32` |

> **외부에서 SSH:** master FIP(`172.16.8.146`)만 사용. 나머지 VM은 **master 안에서** private IP로 접속.

---

## 4. 팀 담당 매핑 (1단계)

| VM | 담당 | 할 일 |
|----|------|-------|
| master | 권건우 (Ansible) | 전 서버 설정 자동화 진입점 |
| swarm-mg / swarm-worker | 박재윤 | `docker swarm init` / `join` |
| db01 / db02 | 김인태 / 윤진수 | MariaDB Replica |
| monitor | 윤진수 | Prometheus + Grafana |
| OpenStack | 최진성 (+ 현도 지원) | VM/네트워크/FIP |

---

## 5. Ansible inventory

경로: `openstack/inventories/dev/hosts.ini`

Ansible은 **master(172.16.8.146)에 SSH한 뒤**, private IP 기준으로 실행하는 것을 권장합니다.
