# OpenStack / Linux / Network 구성 문서

## 담당 범위

담당자: 김현도

역할: OpenStack 기반 서버 기본 환경 및 네트워크 구성

## 프로젝트 네트워크

| 구분 | 이름 | CIDR | Gateway | 용도 |
|---|---|---|---|---|
| Public | project-public-net | 192.168.100.0/24 | 192.168.100.1 | 관리, Swarm, Web, Monitoring |
| Private | project-private-net | 192.168.101.0/24 | 192.168.101.1 | DB 내부 통신 |
| External | sharednet1 | 172.16.8.0/24 | 172.16.8.2 | Floating IP 외부 접속 |

Router:
- project-router
- external gateway: sharednet1

## 최소 공통 노드

| 노드 | Fixed IP | Floating IP | 역할 |
|---|---|---|---|
| master | 192.168.100.10 | 172.16.8.155 | Ansible 제어 / 관리 노드 |
| swarm-mg | 192.168.100.20 | 172.16.8.150 | Docker Swarm Manager |
| swarm-worker | 192.168.100.21 | 172.16.8.185 | Docker Swarm Worker |

## 검증 결과

- master SSH 접속 성공
- swarm-mg SSH 접속 성공
- swarm-worker ACTIVE 및 Floating IP 연결
- master에서 swarm-mg, swarm-worker로 ping 성공
- 기본 패키지 설치 완료

## 리소스 제한

현재 로컬 OpenStack 호스트는 RAM 16GB 환경이다. QEMU 모드에서는 5~6개 VM 동시 실행이 어려워 초기 프로토타입은 3노드 최소 구성으로 진행한다.
