# OpenStack 리소스 이름 / ID — 팀장 전달용

> 작성: 김현도 | 기준: **2026-06-26 재실측 검증 완료** (`openstack ... list` 전체 재대조 — ID 전부 일치, 변경 없음)
> 환경: VMware 멀티노드 (control 172.16.8.100 / VIP·Horizon 172.16.8.105)
> 인증: `source /etc/kolla/admin-openrc.sh` (control, venv 활성화 후)

---

## 한눈에 보기

| 종류 | 이름 | 비고 |
|------|------|------|
| 이미지 | `ubuntu` (24.04 noble) | active |
| 플레이버 | `m1.small`, `m1.medium` | 2종 |
| 외부망 | `public1` | Floating IP 풀 |
| 내부망 | `project-public-net`, `project-private-net` | tenant |
| 라우터 | `project-router` | public↔private |
| 보안그룹 | `project-sg` | 작업용 (default 별도) |
| 키페어 | `project_key` | 전 VM 공용 |
| 서버그룹 | `db-server-group`, `swarm-server-group` | anti-affinity (db01/db02 생성 시 필수) |

---

## 1. 이미지 (Image)

| 이름 | ID | 포맷/상태 |
|------|-----|-----------|
| `ubuntu` (24.04 noble cloudimg) | `db848620-7131-4b71-baa4-3c501ffcc833` | qcow2 / active |

> 📌 06-29: `noble-server-cloudimg-amd64`(Ubuntu 24.04)를 `ubuntu`로 등록, 기존 `ubuntu-22.04`는 삭제. 인스턴스 생성 시 `--image ubuntu`.

---

## 2. 플레이버 (Flavor)

| 이름 | ID | vCPU | RAM(MB) | Disk(GB) | 용도 |
|------|-----|:----:|:-------:|:--------:|------|
| `m1.small` | `98975758-119a-4986-a389-8cfcdd5e8394` | 1 | 2048 | 20 | swarm-mg, proxy, lb, monitor |
| `m1.medium` | `90613177-0f34-4d3d-b9d6-093e5c70c859` | 2 | 4096 | 40 | db01, db02 |

---

## 3. 네트워크 (Network)

| 이름 | ID | 구분 |
|------|-----|------|
| `public1` | `5a6c143f-4fe7-432a-8743-4ed148123372` | External (FIP 풀) |
| `project-public-net` | `8de76e30-b55c-4607-ba84-93c22c3a7d69` | Tenant Public |
| `project-private-net` | `3b1d5e65-8c25-49ca-9dff-c647ee671c4c` | Tenant Private |

---

## 4. 서브넷 (Subnet)

| 이름 | ID | CIDR | 소속 네트워크 |
|------|-----|------|---------------|
| `public-subnet` | `b613c49c-89d0-4873-813e-abe8ff506cdf` | 172.16.8.0/24 | public1 |
| `project-public-subnet` | `8981b59d-f4a3-4c55-a7e3-32dbb5f7cb95` | 192.168.100.0/24 | project-public-net |
| `project-private-subnet` | `6e061800-9880-4785-a42e-6875ad41ee57` | 192.168.101.0/24 | project-private-net |

> FIP 풀: `172.16.8.201~250` (.200은 mgmt 노드용으로 제외)

---

## 5. 라우터 (Router)

| 이름 | ID | 상태 | 연결 |
|------|-----|------|------|
| `project-router` | `d4cbf325-caed-4652-8cb2-d0969170018e` | ACTIVE / UP | public1 ↔ public/private subnet |

---

## 6. 보안그룹 (Security Group)

| 이름 | ID | 용도 |
|------|-----|------|
| `project-sg` | `7363bb1e-2d20-4243-89c4-b74af7419853` | **작업용 (이거 사용)** |
| `default` | `490c4ca1-639f-4dbb-bd7b-9d4127098007` | 기본 (참고) |

### project-sg 규칙 (ingress)

| Protocol | Port | 용도 |
|----------|------|------|
| icmp | — | ping |
| tcp | 22 | SSH |
| tcp | 80 / 443 | HTTP/HTTPS |
| tcp | 2377 | Swarm 관리 |
| tcp/udp | 7946 | Swarm 노드 통신 |
| udp | 4789 | Swarm overlay (VXLAN) |
| tcp | 3306 | MariaDB |
| tcp | 9090 | Prometheus |
| tcp | 3000 | Grafana |

> egress: IPv4/IPv6 전체 허용

---

## 7. 키페어 / Floating IP

| 종류 | 값 |
|------|-----|
| 키페어 | `project_key` (control `/root/.ssh/id_rsa`) |
| Floating IP | `172.16.8.219` (현재 swarm-mg-01 연결) |

---

## 8. Anti-Affinity 서버그룹 (db01/db02 생성 시 필수)

| 이름 | ID | 정책 | 멤버 | 용도 |
|------|-----|------|------|------|
| `db-server-group` | `52557a3a-e4ab-4330-a096-de8fafc2fd3e` | anti-affinity | (없음) | db01·db02를 **서로 다른 compute에 분산** |
| `swarm-server-group` | `61f54db2-0c66-4a43-af91-62bbcfa8ca52` | anti-affinity | (없음) | swarm 매니저 분산 |

> ⚠️ db01/db02 생성 시 반드시 `--hint group=<db-server-group ID>` 를 붙여야 anti-affinity가 적용됩니다.
> ID 확인: `openstack server group list` → ID 복사 후 사용
>
> ```bash
> GID=$(openstack server group list -f value -c ID -c Name | awk '/db-server-group/{print $1}')
> openstack server create --flavor m1.medium --image ubuntu-22.04 \
>   --nic net-id=project-private-net,v4-fixed-ip=192.168.101.31 \
>   --security-group project-sg --key-name project_key \
>   --hint group=$GID db01
> ```

---

## ⚠️ 사용 시 주의 — ID는 "이 클러스터 전용"

| 상황 | 무엇을 쓰나 |
|------|-------------|
| **이 클러스터(172.16.8.100)에 직접 명령** | 위 **ID** 그대로 OK |
| **시연PC에 새로 deploy 후 재현** | **이름 + CIDR + SG 규칙**(스펙). ID는 새로 생기므로 무의미 |

> 즉, 내일 "미리 세팅"이 새 환경이면 → **이름/CIDR/규칙**을 스펙으로 재현.
> 기존 클러스터에 인스턴스 쏘는 거면 → **ID** 사용.

---

## 빠른 재확인 명령 (control)

```bash
source /root/venv/bin/activate
source /etc/kolla/admin-openrc.sh
openstack image list
openstack flavor list
openstack network list
openstack subnet list
openstack router list
openstack security group list
openstack keypair list
openstack floating ip list
openstack server group list
```

---

## ⚠️ 팀장 계획 대조 시 꼭 확인할 것

1. **이미지**: 팀장이 쓰려는 `noble-server-cloudimg-amd64`(Ubuntu 24.04)는 **아직 미업로드**. 현재는 `ubuntu-22.04`만 존재 → 계획 1번에서 먼저 `openstack image create`로 올려야 함.
2. **서버그룹**: db01/db02는 `--hint group=db-server-group` 필수 (위 §8).
3. **재배포 여부**: 노드 IP 변경 + 전체 재배포를 했다면 위 **ID가 무효일 수 있음** → `openstack ... list`로 ID 재확인 후 사용. 네트워크/SG를 다시 만들었다면 이름+CIDR+규칙(스펙)으로 재현.
