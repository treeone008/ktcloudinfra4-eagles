# OpenStack / Linux / Network 구성 문서

## 담당 범위

담당자: 김현도 (OpenStack·네트워크), 최진성 (OpenStack 운영 협업)

역할: OpenStack 기반 서버 기본 환경 및 네트워크 구성

## 프로젝트 네트워크

| 구분 | 이름 | CIDR | Gateway | 용도 |
|---|---|---|---|---|
| Public | project-public-net | 192.168.100.0/24 | 192.168.100.1 | 관리, Swarm, Monitoring |
| Private | project-private-net | 192.168.101.0/24 | 192.168.101.1 | DB 내부 통신 |
| External | sharednet1 | 172.16.8.0/24 | 172.16.8.2 | Floating IP 외부 접속 |

Router:
- project-router
- external gateway: sharednet1

## Tenant VM (6노드 — 1단계 뼈대)

| 노드 | Fixed IP | Floating IP | 역할 |
|---|---|---|---|
| master | 192.168.100.10 | 172.16.8.146 | Ansible 제어 / SSH 진입점 |
| swarm-mg | 192.168.100.20 | — | Docker Swarm Manager |
| swarm-worker | 192.168.100.21 | — | Docker Swarm Worker |
| monitor | 192.168.100.40 | — | Prometheus / Grafana |
| db01 | 192.168.101.31 | — | MariaDB Primary |
| db02 | 192.168.101.32 | — | MariaDB Replica |

> 상세 표: [vm-ip-table.md](./vm-ip-table.md)  
> 접속법: [access-guide.md](./access-guide.md)  
> 시연 전 점검: [pre-demo-checklist.md](./pre-demo-checklist.md)

## OpenStack 호스트 (AIO)

| 항목 | 값 |
|---|---|
| 배포 | Kolla All-in-One (`testopenstack`) |
| 호스트 IP | 172.16.8.100 |
| Horizon | http://172.16.8.100 |
| VMware NAT | vmnet8 = 172.16.8.0/24 |

## 검증

- master SSH (FIP 172.16.8.146) 확인
- master → 나머지 VM ping/SSH: `scripts/verify-from-master.sh`

## 관련 문서

- [ports.md](./ports.md) — 포트·Security Group
- [access-guide.md](./access-guide.md) — Horizon / SSH / CLI
- [vm-ip-table.md](./vm-ip-table.md) — IP·담당 매핑
