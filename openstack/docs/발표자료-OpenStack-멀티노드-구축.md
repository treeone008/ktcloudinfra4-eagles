# 발표자료 — OpenStack 멀티노드 IaaS 구축 (김현도)

> **목적:** VMware + Kolla-Ansible 기반 **멀티노드 OpenStack** 환경을 설계·구축·검증한 결과를 정리한다.  
> **검증 일시:** 2026-07-06 · tenant VM **10/10 ACTIVE**  
> **캡처:** `[캡처 삽입]` 표시 위치에 스크린샷을 붙여 발표 슬라이드로 사용한다.

---

## 1. 한 줄 요약

| 항목 | 내용 |
|------|------|
| 플랫폼 | VMware Workstation Pro + Ubuntu 24.04 + Kolla-Ansible 2025.1 |
| 구성 | 인프라 **7노드** (mgmt + control / network / storage / compute×3) + tenant **10대** |
| 핵심 | 멀티 compute 분산, anti-affinity, public/private 이중망, FIP, Cinder, **mgmt 설계** |
| 실시연 | 강사 PC **mgmt+올인원 2VM**, Swarm **원노드** (본 문서는 **구축 증명**용) |

---

## 2. 전체 아키텍처

```
VMware Workstation Pro
├─ mgmt-01          (.200)  외부 관리 / Ansible / SSH 진입점
├─ control          (.100)  OpenStack Controller + API (Horizon VIP .105)
├─ network          (.101)  Neutron L3 / DHCP / OVS
├─ storage          (.102)  Cinder (LVM)
├─ compute-node-01  (.103)  Nova Compute
├─ compute-node-02  (.104)  Nova Compute
└─ compute-node-03  (.106)  Nova Compute

Tenant (OpenStack 인스턴스 10대)
├─ compute-01: swarm-mg, db01, db_proxy-01, lb-01
├─ compute-02: swarm-mg2, db02, db_proxy-02, lb-02
└─ compute-03: swarm-mg3, automation-01
```

**[캡처 삽입]** VMware 라이브러리 — **mgmt 포함** 인프라 VM 전원 ON 화면

---

## 3. 인프라 노드

| 노드 | IP | 역할 | RAM (문서 기준) |
|------|-----|------|-----------------|
| **mgmt-01** | **172.16.8.200** | **외부 관리 / Ansible / SSH 진입점** | 8GB |
| control | 172.16.8.100 | Controller, Nova API/Conductor/Scheduler | 6GB |
| network | 172.16.8.101 | Neutron (L3, DHCP, OVS, Metadata) | 2GB |
| storage | 172.16.8.102 | Cinder Volume (LVM) | 3GB |
| compute-node-01 | 172.16.8.103 | Nova Compute | 6GB |
| compute-node-02 | 172.16.8.104 | Nova Compute | 8GB |
| compute-node-03 | 172.16.8.106 | Nova Compute | ≈6GB |
| VIP / Horizon | 172.16.8.105 | 웹 콘솔 | — |

- 배포 도구: **Kolla-Ansible** (`/etc/kolla/multinode`)
- OS: Ubuntu 24.04 Server
- Horizon: `http://172.16.8.105`

**[캡처 삽입]** Horizon 로그인 / 대시보드 Overview

---

## 4. 네트워크 설계

| 구분 | 이름 | CIDR | 용도 |
|------|------|------|------|
| External | `public1` | 172.16.8.0/24 | FIP 풀 (.201~.250) |
| Tenant Public | `project-public-net` | 192.168.100.0/24 | 웹·Swarm·LB 등 |
| Tenant Private | `project-private-net` | 192.168.101.0/24 | DB·Proxy (사설 전용) |
| Router | `project-router` | — | public1 ↔ tenant subnets |

**망 규칙:** `192.168.100.x` = public · `192.168.101.x` = private

**[캡처 삽입]** `openstack network list` + `openstack subnet list`  
**[캡처 삽입]** `openstack network agent list` (L3/DHCP/OVS 전부 UP)

---

## 5. Tenant VM 목록 (검증 완료 2026-07-06)

| 이름 | Fixed IP | FIP | Compute | Flavor | 상태 |
|------|----------|-----|---------|--------|:----:|
| swarm-mg | 192.168.100.20 | 172.16.8.219 | compute-01 | m1.small | ACTIVE |
| swarm-mg2 | 192.168.100.21 | 172.16.8.243 | compute-02 | m1.swarm | ACTIVE |
| swarm-mg3 | 192.168.100.22 | — | compute-03 | m1.micro | ACTIVE |
| db01 | 192.168.101.31 | — | compute-01 | m1.micro | ACTIVE |
| db02 | 192.168.101.32 | — | compute-02 | m1.micro | ACTIVE |
| db_proxy-01 | 192.168.101.40 | — | compute-01 | m1.micro | ACTIVE |
| db_proxy-02 | 192.168.101.41 | — | compute-02 | m1.micro | ACTIVE |
| lb-01 | 192.168.100.50 | — | compute-01 | m1.micro | ACTIVE |
| lb-02 | 192.168.100.51 | — | compute-02 | m1.micro | ACTIVE |
| automation-01 | 192.168.100.60 | — | compute-03 | m1.micro | ACTIVE |

**[캡처 삽입]** `openstack server list` — **10/10 ACTIVE** (핵심 증명)

---

## 6. Compute 분산 배치

```
compute-node-01 (.103)     compute-node-02 (.104)     compute-node-03 (.106)
├─ swarm-mg                ├─ swarm-mg2               ├─ swarm-mg3
├─ db01                    ├─ db02                    └─ automation-01
├─ db_proxy-01             ├─ db_proxy-02
└─ lb-01                   └─ lb-02
```

- **Swarm 매니저 3대** → compute 01 / 02 / 03 **각 1대씩 분산**
- **DB Primary/Replica** → 서로 다른 compute (anti-affinity)

**[캡처 삽입]** `openstack compute service list` — nova-compute 3대 **up**  
**[캡처 삽입]** (선택) Horizon → Admin → System → Hypervisors

---

## 7. Anti-Affinity Server Group

| Server Group | 정책 | 멤버 | 검증 |
|--------------|------|------|------|
| `db-server-group` | anti-affinity | db01, db02 | compute-01 ↔ compute-02 |
| `swarm-server-group` | anti-affinity | swarm-mg, mg2, mg3 | compute 01 / 02 / 03 |

**[캡처 삽입]** `openstack server group list` + show (멤버 확인)

---

## 8. Floating IP

| FIP | Fixed IP | VM | 용도 |
|-----|----------|-----|------|
| 172.16.8.219 | 192.168.100.20 | swarm-mg | 외부 SSH bastion |
| 172.16.8.243 | 192.168.100.21 | swarm-mg2 | 외부 SSH |

**[캡처 삽입]** `openstack floating ip list`

---

## 9. Cinder 볼륨 (DB 영속 스토리지)

| 볼륨 | 크기 | 연결 VM | Device | 상태 |
|------|------|---------|--------|:----:|
| db01-data | 10GB | db01 | /dev/vdb | in-use |
| db02-data | 10GB | db02 | /dev/vdb | in-use |

- Cinder 백엔드: storage 노드 LVM (`cinder-volume @ storage@lvm-1`)

**[캡처 삽입]** `openstack volume list`  
**[캡처 삽입]** `openstack volume service list` (cinder-volume **up**)

> **운영 참고:** DB VM은 Cinder 볼륨 연결이 있어 재부팅 시 **storage → compute** 순서로 기동해야 한다.  
> ERROR 시 `openstack server reboot --hard` 또는 `reset-state --active` 후 `start`.

---

## 10. Security Group (`project-sg`)

| Protocol | Port | 용도 |
|----------|------|------|
| icmp | — | ping |
| tcp | 22 | SSH |
| tcp | 80 / 443 | HTTP/S |
| tcp | 2377 | Swarm |
| tcp/udp | 7946 | Swarm |
| udp | 4789 | overlay |
| tcp | 3306 | MariaDB |
| tcp | 9090 / 3000 | Prometheus / Grafana |

**[캡처 삽입]** Horizon → Network → Security Groups → project-sg Rules

---

## 11. mgmt 노드 & SSH (설계·구현 — 발표는 개념 위주)

> **발표:** mgmt VM 존재 + SSH **설계(ProxyJump)** 를 슬라이드·구두로 설명.  
> **라이브 SSH 데모·캡처 증명은 생략** (환경에 따라 지연·불안정). tenant 접속은 control + `project_key`로 검증.

### 11-1. mgmt-01 개요

| 항목 | 값 |
|------|-----|
| VMware VM | **mgmt-01** |
| IP | **172.16.8.200** |
| OS | Ubuntu 24.04 Server |
| 역할 | OpenStack **외부 관리** / Ansible / SSH **진입점** (강사 PC 실시연에도 동일 역할) |
| 키 | control `project_key` 개인키 → mgmt `~/.ssh/id_rsa` 복사 |

> FIP 풀(`.201~.250`)에서 **`.200`은 mgmt 전용**으로 제외.

### 11-2. SSH 설계 (발표용 다이어그램)

mgmt는 provider(FIP) 세그먼트에 **직접 라우팅이 안 되므로**, 실무와 같이 **control을 점프호스트(ProxyJump)** 로 거쳐 tenant에 접속한다.

```
[운영자]
    ▼
mgmt-01 (.200)  — 외부 관리 / 모니터링(Ansible) 예정
    │  ssh -J user1@172.16.8.100
    ▼
control (.100)  — OpenStack 컨트롤러
    │  project_key
    ▼
tenant VM       — 예) swarm-mg FIP .219 / db01 private .101.31
```

**발표 멘트 (30초):**  
「관리 전용 mgmt 노드를 `.200`에 두고, OpenStack 밖에서 Ansible·SSH로 운영한다. mgmt는 FIP망에 바로 못 붙어서 control을 경유하는 ProxyJump 구조로 설계했고, mgmt에는 project_key를 배포해 두었다.」

### 11-3. 참고 명령 (문서·Q&A용, 발표 데모 ❌)

```bash
# mgmt → control → swarm-mg (설계상 공식 경로)
ssh -o IdentitiesOnly=yes -J user1@172.16.8.100 -i ~/.ssh/id_rsa \
  ubuntu@172.16.8.219

# control에서 tenant (내부 검증·캡처용으로 충분)
ssh -i /root/.ssh/id_rsa ubuntu@172.16.8.219
ssh -J ubuntu@172.16.8.219 ubuntu@192.168.101.31   # db01 private
```

**[캡처 삽입]** (선택) 아키텍처 그림만 — mgmt → control → tenant 화살표  
**[캡처 삽입]** (선택) control에서 `ssh ... 172.16.8.219` 성공 — tenant SSH 증명용

---

## 12. 검증에 사용한 명령 (control)

```bash
sudo -i
source /root/venv/bin/activate
source /etc/kolla/admin-openrc.sh

openstack compute service list
openstack server list
openstack server group list
openstack volume list
openstack floating ip list
openstack network agent list
openstack volume service list
```

**[캡처 삽입]** 위 명령 터미널 출력 묶음 (1~2장)

---

## 13. 구축 과정 요약 (발표 멘트용)

1. **Kolla-Ansible**로 control / network / storage / compute 멀티노드 배포
2. External망(`public1`) + tenant public/private + router 구성
3. Image(`ubuntu` 24.04), Flavor, SG, Keypair(`project_key`) 생성
4. compute-node-02 **신규 제작** (클론 금지 — host 충돌 이슈 해결)
5. compute-node-03 추가 → **swarm 3분산** 완료
6. tenant VM 10대 생성 — IP·호스트 배치표 준수
7. db01/db02 **anti-affinity** + **Cinder 10GB** 연결
8. FIP 2개 연결, control → tenant SSH(bastion) 검증
9. **mgmt-01(.200) 제작** + project_key 복사 → **ProxyJump SSH 설계** (mgmt → control → tenant)

---

## 14. 실시연 환경과의 관계 (슬라이드 1장)

| 구분 | 본 구축 (발표 증명) | 강사 PC 실시연 |
|------|---------------------|----------------|
| OpenStack | **멀티노드 6VM** + mgmt | **올인원 1VM** |
| 관리 | **mgmt-01** (ProxyJump SSH 설계) | **mgmt 1VM + 모니터링** |
| Swarm | 3노드 분산 설계 | **원노드** |
| 목적 | IaaS 설계·구축 역량 증명 | 데모·운영 단순화 |

> 멀티노드 + **mgmt 노드**는 **「이렇게 설계하고 만들었다」**는 기술 증명.  
> SSH 라이브 데모는 생략하고, **OpenStack CLI·Horizon 캡처**로 IaaS 구축을 증명한다.

---

## 15. 캡처 체크리스트

| # | 내용 | 필수 |
|:-:|------|:----:|
| 1 | VMware VM (**mgmt 포함**) ON | ✅ |
| 2 | `openstack compute service list` | ✅ |
| 3 | `openstack server list` (10 ACTIVE) | ✅ |
| 4 | `openstack volume list` (db 볼륨 in-use) | ✅ |
| 5 | `openstack floating ip list` | ✅ |
| 6 | `openstack network agent list` | ✅ |
| 7 | mgmt → control → tenant **아키텍처 그림** (§11) | 권장 |
| 8 | `openstack server group list` | 권장 |
| 9 | Horizon 인스턴스 / 네트워크 탭 | 권장 |
| 10 | (선택) control → tenant SSH 캡처 | 선택 |

---

## 16. 관련 문서

| 문서 | 용도 |
|------|------|
| `08-산출물-8종-인수인계.md` | 상세 인수인계 (IP/SG/SSH 전체) |
| `문서화-마스터표.md` | 1페이지 요약 |
| `오픈스택-구성-문서화.md` | SSOT · 운영 명령 |
| `07-시연PC-전달-스냅샷-복원-가이드.md` | VM 패키징·복원 절차 |

---

**작성:** 김현도  
**최종 갱신:** 2026-07-06 (mgmt SSH — 설계 위주, 라이브 증명 생략)
