# 09 — OpenStack 트러블슈팅 종합 가이드

> **목적:** 김현도 팀 OpenStack(IaaS) 구축 과정(2026-06~07)에서 **실제로 겪은 장애·해결**을 한곳에 모은 레퍼런스.  
> 데일리 클린업·`06` 네트워크 가이드·인수인계 문서를 **증상별로 재배치**했다.
>
> **작성:** 김현도  
> **환경:** VMware + Kolla-Ansible 2025.1 / Ubuntu 24.04 / control·network·storage·compute×N  
> **관련:** `06`(네트워크 ACTIVE) · `08`(산출물) · `발표자료-OpenStack-멀티노드-구축.md`

---

## 0. 트러블슈팅 시작 전 (항상 동일)

```bash
sudo -i
source /root/venv/bin/activate
source /etc/kolla/admin-openrc.sh
```

| 확인 | 명령 |
|------|------|
| 인증 | `openstack token issue` |
| 서비스 | `openstack compute service list` |
| 네트워크 | `openstack network agent list` |
| 인스턴스 | `openstack server list` |
| 볼륨 | `openstack volume service list` |

> **원칙:** 명령이 이상하면 **리소스 설정부터 의심하지 말고** 에이전트·노드 전원·부팅 순서부터 본다.

---

## 1. 증상별 빠른 찾기표

| 증상 | 1순위 의심 | → 절 |
|------|-----------|------|
| 라우터 **DOWN** / 네트워크 ACTIVE 안 됨 | L3·OVS·DHCP agent | §2 |
| VM **ERROR (PortBindingFailed)** | flat 외부망에 VM 직접 연결 | §3 |
| VM **No valid host** | Placement 디스크/RAM 부족 | §4 |
| VM **ERROR** (Cinder 볼륨 VM) | storage 늦게 기동 | §5 |
| VM **SHUTOFF** (재부팅 후) | 자동 기동 미설정 | §6 |
| **FIP ping/SSH** 안 됨 | L3 agent / ARP / cloud-init | §7 |
| **SSH Permission denied** | 키페어·known_hosts | §8 |
| **mgmt → tenant SSH** 끊김/느림 | ProxyJump·비번 대기 | §9 |
| **Nova 503** / API 타임아웃 | 컨테이너 미기동 | §10 |
| **compute down** / RPC 타임아웃 | 클론 host 충돌 | §11 |
| **KVM 오류** (인스턴스 생성) | `virt_type` | §12 |
| **Octavia / LB** 헬스체크 실패 | lb-mgmt·web SG | §13 |

---

## 2. 네트워크·라우터 ACTIVE 안 됨

> 상세 절차: **`06-네트워크-라우터-구성-및-ACTIVE-트러블슈팅-가이드.md`**

### 2-1. 1순위 — agent 확인

```bash
openstack network agent list
```

| Agent | 있어야 할 노드 | State |
|-------|----------------|-------|
| neutron-openvswitch-agent | network + **모든 compute** | UP |
| neutron-l3-agent | network | UP |
| neutron-dhcp-agent | network | UP |
| neutron-metadata-agent | network | UP |

**하나라도 `XXX` / DOWN:**

```bash
# network 노드
ssh root@172.16.8.101 "docker restart neutron_l3_agent neutron_dhcp_agent neutron_openvswitch_agent neutron_metadata_agent"

# compute 노드 (해당 IP)
ssh root@<compute-ip> "docker restart neutron_openvswitch_agent"
```

### 2-2. 라우터 DOWN

```bash
openstack router show project-router -c status -c external_gateway_info
```

- `--external-gateway public1` **빠졌으면** → `openstack router set --external-gateway public1 project-router`
- 게이트웨이 있는데도 DOWN → **L3 agent 재시작** (§2-1)

### 2-3. IP 재배치 후 특정 VM만 통신 불가

- IP 안 바뀐 compute도 **OVS 터널이 옛 peer IP**를 물고 있을 수 있음.

```bash
ssh root@172.16.8.104 "docker restart neutron_openvswitch_agent"
```

---

## 3. PortBindingFailed (VM ERROR)

### 증상

```
Binding failed for port ...
```

### 원인

`public1`(flat 외부망)에 **tenant VM을 직접** 붙임. compute에는 `physnet1`이 없음.

### 해결

```
❌ VM → public1 직접
✅ VM → project-public/private-net → router → public1 + Floating IP
```

```bash
openstack server create --nic net-id=<project-public-net-id>,v4-fixed-ip=192.168.100.xx ...
openstack server add floating ip <VM> 172.16.8.xxx
```

---

## 4. No valid host (스케줄 실패)

### 증상

`openstack server create` 후 status **ERROR**, fault에 `No valid host`.

### 원인 (실측 사례)

| 원인 | 사례 |
|------|------|
| **DISK_GB 부족** | compute-node-02 Placement 38GB, db01 20GB 후 18GB 남음 → m1.small(20GB) 실패 |
| **RAM 부족** | 호스트 RAM 16GB + QEMU, VM 5~6대 동시 불가 |
| **특정 host 지정** | `--host compute1` 인데 리소스 없음 |

### 해결

```bash
# Placement 확인 (API)
curl -s http://172.16.8.100:8780/resource_providers -H "X-Auth-Token: $(openstack token issue -f value -c id)" | python3 -m json.tool

# 디스크 확장 (compute에서)
lvextend -l +100%FREE /dev/ubuntu-vg/ubuntu-lv && resize2fs /dev/ubuntu-vg/ubuntu-lv
ssh root@<compute> "docker restart nova_compute"

# flavor 축소 또는 다른 compute로 이동
openstack flavor create --vcpus 1 --ram 1024 --disk 10 m1.micro
```

### 교훈

- db·swarm **동시 생성** 시 레이스 → **순차 생성** 권장.
- `m1.micro`(disk 10)로 여유 확보 후 배치 조정.

---

## 5. db VM ERROR + Cinder 볼륨 (재부팅 후)

### 증상

- `openstack server list` → db01/db02 **ERROR**
- `volume list` → `in-use` (볼륨은 붙어 있음)
- `openstack server start` → **409** (vm_state error)

### 원인

**storage/Cinder** 준비 전 compute가 guest를 올리려다 볼륨 attach 실패.

### 부팅 순서 (DB VM 있을 때)

```
control → network → storage → compute(s) → 2~3분 대기
```

### 복구

```bash
openstack volume service list    # cinder-volume @ storage up 확인

openstack server reset-state --active db01
openstack server reset-state --active db02
openstack server start db01
openstack server start db02

# 안 되면
openstack server reboot --hard db01
```

---

## 6. 재부팅 후 VM SHUTOFF

### 증상

호스트/VMware 재기동 후 tenant VM 전부 **SHUTOFF**, SSH `No route to host`.

### 해결

```bash
openstack server start <이름>
# 또는 일괄
for vm in swarm-mg db01 db02; do openstack server start $vm; done
```

### 예방 (nova-compute)

```bash
# /etc/kolla/config/nova/nova-compute.conf
[DEFAULT]
resume_guests_state_on_host_boot = true

kolla-ansible reconfigure --tags nova
```

---

## 7. Floating IP ping / SSH 실패

### 체크 순서

```bash
openstack floating ip list
openstack server show <VM> -c status -c addresses
ping -c2 <FIP>
ip route get <FIP>

openstack network agent list | grep -i l3
ssh root@172.16.8.101 "docker restart neutron_l3_agent"
```

### FIP 409 Conflict

Neutron이 **private 포트**에 FIP 연결 시도할 때.

```bash
openstack floating ip unset --port <port-id> <FIP>
openstack server add floating ip <VM> <FIP> --fixed-ip-address 192.168.100.xx
```

### FIP ping OK · SSH timeout

- **cloud-init** 미완료 → 1~2분 대기
- **known_hosts** 충돌 → `ssh-keygen -R <FIP>`

```bash
openstack console log show <VM> | tail -30
ssh -o StrictHostKeyChecking=accept-new -i /root/.ssh/id_rsa ubuntu@<FIP> hostname
```

---

## 8. SSH · 키페어

| 증상 | 해결 |
|------|------|
| `Permission denied (publickey)` | `--key-name project_key` 확인, `openstack keypair show project_key` |
| 개인키 없음 | control `/root/.ssh/id_rsa` 재생성 후 `openstack keypair create --public-key ... project_key` |
| `Host key changed` | `ssh-keygen -R <IP>` |
| private VM 접속 | `ssh -J ubuntu@<FIP-bastion> ubuntu@192.168.101.xx` |

```bash
ssh -i /root/.ssh/id_rsa ubuntu@172.16.8.219              # swarm-mg
ssh -J ubuntu@172.16.8.219 ubuntu@192.168.101.31          # db01
```

---

## 9. mgmt SSH (ProxyJump)

### 설계

```
mgmt (.200) → control (.100) → tenant FIP/private
```

mgmt는 FIP 세그먼트에 **직접 라우팅 불가** (`No route to host`) → **정상**. control 경유가 공식.

### 자주 막히는 것

| 증상 | 원인 | 해결 |
|------|------|------|
| `Connection reset` (control) | ssh.socket 충돌 | control/mgmt에서 `systemctl disable ssh.socket` + `enable ssh.service` |
| ProxyJump **멈춤** | control **비번 대기** | `ssh-copy-id user1@172.16.8.100` (mgmt에서) |
| 매우 느림 | GSSAPI / DNS | `-o GSSAPIAuthentication=no -o ConnectTimeout=15` |

```bash
# mgmt에서 (발표·설계용)
ssh -o IdentitiesOnly=yes -J user1@172.16.8.100 -i ~/.ssh/id_rsa \
  ubuntu@172.16.8.219 hostname
```

---

## 10. Nova API 503

### 증상

```
HttpException: 503 ... nova ... Service Unavailable
```

### 원인

재부팅 직후 **nova_api / haproxy** 미완료.

### 해결

```bash
docker ps -a | grep nova
docker restart nova_api nova_conductor nova_scheduler haproxy
sleep 45
openstack compute service list
openstack server list
```

---

## 11. compute 클론 → RPC 타임아웃 (★ 금~월 삽질)

### 증상

- compute2 nova-compute 컨테이너 Up인데 `compute service list`에 **안 뜸**
- 로그: `MessagingTimeout`, `No calling threads waiting for msg_id`

### 근본 원인

**compute Full Clone** → `host=compute1` 동일 → RabbitMQ 응답큐 `reply_compute1:nova-compute` **컨슈머 2개** → 응답 경쟁 → **compute1까지 down**.

### 해결

1. 클론 compute **전원 OFF** → compute1 회복 확인
2. **신규 VM으로 compute 재제작** (클론 금지) → `host=compute-node-02` 분리
3. 가이드: **`04-compute2-신규제작(클론X)-합류-가이드.md`**

### 교훈

> **compute 노드는 클론하지 말 것.** 신규 설치 + netplan + bootstrap이 정답.

---

## 12. KVM 오류 → QEMU 전환

### 증상

인스턴스 생성 시 KVM 관련 오류 (중첩 가상화 미지원).

### 해결

`/etc/kolla/globals.yml`:

```yaml
nova_compute_virt_type: "qemu"
```

```bash
kolla-ansible reconfigure --tags nova
```

> 성능은 KVM보다 낮지만, VMware 안에서 OpenStack 돌릴 때 **흔한 우회**.

---

## 13. Octavia 보안그룹 (강사 AIO 실습)

### 토폴로지 예시

| 망 | CIDR | 용도 |
|----|------|------|
| sharednet1 | 172.16.8.0/24 | external |
| webserver | 192.168.1.0/24 | web1~3, amphora |
| db-net | 192.168.101.0/24 | db |
| lb-mgmt-net | 10.1.0.0/24 | amphora 관리 |

### lb-mgmt-sec-grp (필수)

```bash
source /etc/kolla/octavia-openrc.sh 2>/dev/null || source /etc/kolla/admin-openrc.sh

openstack security group create lb-mgmt-sec-grp
openstack security group rule create --protocol icmp lb-mgmt-sec-grp
openstack security group rule create --protocol tcp --dst-port 22 lb-mgmt-sec-grp
openstack security group rule create --protocol tcp --dst-port 9443 lb-mgmt-sec-grp
```

### web 백엔드 헬스체크 (web1~3)

```bash
openstack security group rule create \
  --protocol tcp --dst-port 80 \
  --remote-ip 192.168.1.0/24 \
  <web-SG이름>
```

---

## 14. Kolla / Ansible 함정

| 증상 | 원인 | 해결 |
|------|------|------|
| `Permission denied` (ansible) | user1로 실행 | **`sudo -i` (root)** |
| bootstrap UNREACHABLE (storage) | 꺼진 노드가 inventory에 있음 | `/etc/kolla/multinode`에서 `#` 주석 |
| `-limit` deploy 실패 | 꺼진 storage facts 수집 | inventory 주석 후 재시도 |
| `globals.yml` syntax error | nano 명령어가 파일에 섞임 | YAML만 남기고 수정 |
| root SSH 실패 (새 노드) | `PermitRootLogin` / 비번 미설정 | `sshd_config.d/99-root-login.conf` + `passwd root` |
| destroy 시 Docker 없음 | 새 노드 | bootstrap으로 해결 (무해) |

---

## 15. VMware / 호스트 운영

### 노드 부팅 순서

```
control → network → storage → compute1 → compute2 → compute3 → (mgmt)
```

### RAM 부족

| 조치 | 효과 |
|------|------|
| storage 잠시 OFF | RAM 확보 (Cinder 안 쓸 때) |
| control 12→6GB + swap 4GB | 호스트 여유 |
| 호스트 32GB↑ | 멀티노드 + mgmt 권장 |

### NAT 대역

시연 PC / 호스트 모두 **vmnet8 = 172.16.8.0/24**, gateway **172.16.8.2** 일치 필수.

---

## 16. 재부팅 후 복구 체크리스트 (복붙용)

```bash
# 1) 서비스
openstack compute service list
openstack network agent list
openstack volume service list

# 2) VM
openstack server list
# SHUTOFF → start / ERROR(db) → §5

# 3) FIP
ping -c2 172.16.8.219
# 실패 시 network L3 재시작

# 4) API
openstack server list
# 503 → §10
```

---

## 17. 하지 말 것 (교훈 모음)

| ❌ 하지 말 것 | ✅ 대신 |
|-------------|--------|
| compute **Full Clone** | 신규 VM 제작 (`04` 가이드) |
| VM을 **public1에 직접** 연결 | tenant net + router + FIP |
| storage 없이 db VM 기동 | storage 먼저 |
| db01/db02 **동시 생성** | 순차 생성 (anti-affinity) |
| `user1`로 kolla/openstack | `sudo -i` + venv + openrc |
| 재부팅 후 agent 확인 생략 | `network agent list` 먼저 |
| mgmt에서 FIP **직접** SSH | control ProxyJump |

---

## 18. 관련 문서

| 문서 | 내용 |
|------|------|
| `06-네트워크-라우터-...-가이드.md` | ACTIVE·PortBindingFailed 상세 |
| `04-compute2-신규제작(클론X)-합류-가이드.md` | compute 클론 금지 |
| `05-노드-IP-재배치-...-가이드.md` | IP 회전 + OVS |
| `07-시연PC-전달-...-가이드.md` | zip·NAT·복원 |
| `08-산출물-8종-인수인계.md` | 최종 구성·IP표 |
| `발표자료-OpenStack-멀티노드-구축.md` | 검증 캡처 |
| `데일리-클린업-2026-06-24` ~ `07-04` | 일별 원본 기록 |

---

## 19. 변경 이력

| 날짜 | 내용 |
|------|------|
| 2026-07-08 | 데일리 클린업·06 가이드·실측 사례 통합 — 종합 트러블슈팅 페이지 신규 |

---

**작성:** 김현도  
**한 줄:** 안 되면 **agent list → 부팅 순서 → SG/키** 순으로 본다. compute는 **클론 금지**, VM은 **tenant net + FIP**.
