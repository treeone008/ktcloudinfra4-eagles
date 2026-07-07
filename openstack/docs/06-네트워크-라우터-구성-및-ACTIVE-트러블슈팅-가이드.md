# 06 — 네트워크·라우터 구성 & "ACTIVE 안 됨" 트러블슈팅 가이드

> **목적:** OpenStack(Kolla 멀티노드)에서 외부망·프로젝트망·라우터를 만들 때
> 네트워크/라우터가 **ACTIVE(또는 라우터 DOWN)** 안 되거나, VM 붙일 때 **PortBindingFailed** 나는
> 시행착오를 **처음부터 안 겪게** 하는 가이드.
>
> 작성: 김현도 / 기준 환경: control(.100)+network(.101)+storage(.102)+compute(.103/.104), Kolla-Ansible, Ubuntu 24.04

---

## 0. 시작 전 — 인증

```bash
sudo -i                              # root 필수 (user1로는 Permission denied)
source /root/venv/bin/activate       # (venv) 확인
source /etc/kolla/admin-openrc.sh
openstack token issue                # 인증 OK 확인
```

> Horizon = `http://<VIP>` (예: `http://172.16.8.105`), admin 비번: `grep keystone_admin_password /etc/kolla/passwords.yml`

---

## 1. ⭐ 가장 먼저 — 에이전트 상태 확인 (ACTIVE 안 되는 99%의 원인)

**네트워크/라우터가 ACTIVE가 안 되거나 라우터가 계속 DOWN이면, 리소스 명령 문제가 아니라 Neutron 에이전트가 죽어있는 경우가 대부분.** 무조건 먼저 확인:

```bash
openstack network agent list
```

기대 상태 (`Alive = :-)` / `State = UP`):

| Agent | 떠야 하는 노드 |
|-------|----------------|
| Open vSwitch agent | network + **모든 compute** |
| L3 agent | network |
| DHCP agent | network |
| Metadata agent | network |

- **하나라도 `Alive = XXX`(죽음)면** → 그 노드에서 컨테이너 재시작:
  ```bash
  ssh root@<해당노드IP> "docker restart neutron_openvswitch_agent neutron_l3_agent neutron_dhcp_agent neutron_metadata_agent"
  ```
  (compute 노드는 `neutron_openvswitch_agent`만 있음)
- **L3 agent가 죽어 있으면 → 라우터가 영원히 DOWN.** (라우터 ACTIVE의 직접 원인)

---

## 2. 외부망(public1) + Floating IP 풀  ← 실제 적용된 명령

```bash
# 외부(provider) 네트워크 — flat / physnet1
openstack network create --external \
  --provider-physical-network physnet1 \
  --provider-network-type flat public1

# 외부 서브넷 = Floating IP 풀 (DHCP 끔)
openstack subnet create --network public1 \
  --subnet-range 172.16.8.0/24 --gateway 172.16.8.2 \
  --allocation-pool start=172.16.8.200,end=172.16.8.250 \
  --no-dhcp public-subnet
```

### ⚠️ 외부망이 ACTIVE인데 나중에 VM/FIP가 안 되는 함정
- `--provider-physical-network physnet1` 이름은 **Neutron 설정의 bridge_mappings(`physnet1:br-ex`)와 정확히 일치**해야 함.
  안 맞으면 네트워크는 만들어져도 트래픽이 안 흐름.
- 확인:
  ```bash
  ssh root@<network노드> "docker exec openvswitch_vswitchd ovs-vsctl show | grep -A3 br-ex"
  grep -i bridge_mappings /etc/kolla/config/neutron/* 2>/dev/null
  ```
- `--allocation-pool`은 **노드/VIP가 쓰는 IP와 안 겹치게**. (여기선 .200~.250, 노드는 .100~.105)

---

## 3. 프로젝트 네트워크 (public 100 / private 101)  ← 실제 적용된 명령

```bash
openstack network create project-public-net
openstack subnet create --network project-public-net \
  --subnet-range 192.168.100.0/24 --gateway 192.168.100.1 \
  --dns-nameserver 8.8.8.8 project-public-subnet

openstack network create project-private-net
openstack subnet create --network project-private-net \
  --subnet-range 192.168.101.0/24 --gateway 192.168.101.1 \
  --dns-nameserver 8.8.8.8 project-private-subnet
```

> 이 둘은 **tenant(내부 오버레이) 네트워크**라 거의 즉시 ACTIVE. 안 되면 → §1 OVS/DHCP agent 확인.

---

## 4. 라우터 (외부 게이트웨이 + 내부 서브넷 연결)  ← 실제 적용된 명령

```bash
openstack router create project-router
openstack router set --external-gateway public1 project-router      # ★ 이게 있어야 라우터가 산다
openstack router add subnet project-router project-public-subnet
openstack router add subnet project-router project-private-subnet
```

### ⚠️ "라우터가 ACTIVE/DOWN" 핵심
- 라우터는 **① external-gateway 설정 + ② L3 agent 살아있음** 두 개가 모두 돼야 ACTIVE.
- `openstack router set --external-gateway` 를 빼먹으면 외부로 못 나가고 FIP도 안 붙음.
- 그래도 DOWN이면:
  ```bash
  openstack network agent list | grep -i l3       # L3 agent Alive 확인
  openstack router show project-router -c status -c external_gateway_info
  ssh root@<network노드> "docker restart neutron_l3_agent"
  ```

---

## 5. 보안그룹 (project-sg) — SSH/ICMP/내부통신

```bash
openstack security group create project-sg

# SSH(22), ICMP(핑)
openstack security group rule create --proto tcp --dst-port 22 project-sg
openstack security group rule create --proto icmp project-sg

# (선택) 프로젝트 내부 전체 허용 — Swarm/DB 통신용
openstack security group rule create --proto tcp --dst-port 1:65535 --remote-ip 192.168.0.0/16 project-sg
openstack security group rule create --proto udp --dst-port 1:65535 --remote-ip 192.168.0.0/16 project-sg
```

> 핑/SSH가 안 되면 거의 항상 **SG 규칙 누락**. 인스턴스가 ACTIVE인데 접속이 안 되면 SG부터 의심.

---

## 6. 이미지 / 플레이버 / 키페어

```bash
# 이미지 (Ubuntu 24.04 noble)
cd /root
wget https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
openstack image create "ubuntu" --file /root/noble-server-cloudimg-amd64.img \
  --disk-format qcow2 --container-format bare --public

# 플레이버
openstack flavor create --vcpus 1 --ram 2048 --disk 20 m1.small
openstack flavor create --vcpus 2 --ram 4096 --disk 40 m1.medium

# 키페어 (control의 공개키 주입용)
openstack keypair create --public-key /root/.ssh/id_rsa.pub project_key
```

---

## 7. VM 생성 (tenant net + 라우터 경유) + Floating IP

```bash
NET=$(openstack network show project-public-net -f value -c id)
openstack server create --flavor m1.small --image ubuntu \
  --nic net-id=$NET,v4-fixed-ip=192.168.100.20 \
  --security-group project-sg --key-name project_key  test-vm

openstack server add floating ip test-vm 172.16.8.219     # FIP 풀에서 하나
ssh -i /root/.ssh/id_rsa ubuntu@172.16.8.219
```

### 🔥 가장 많이 막히는 에러 — `PortBindingFailed`
> **증상:** VM이 ERROR. 로그에 `Binding failed for port ...`
>
> **원인:** `public1`(flat 외부망, physnet1)에 **VM을 직접** 붙임. 외부 flat 네트워크는
> control/network의 br-ex에만 있고 **compute에는 physnet1이 없어서** 바인딩 실패.
>
> **해결:** VM은 **반드시 tenant 네트워크(project-public-net / project-private-net)** 에 붙이고,
> 외부 접근은 **라우터 + Floating IP**로 한다. (위 §7 방식)
>
> 즉 "VM → tenant net → router → public1(외부)" 구조. VM을 public1에 직접 X.

---

## 8. 최종 검증 (한 번에)

```bash
openstack network list                 # public1(external), project-public/private-net 보임
openstack subnet list
openstack router show project-router -c status -c external_gateway_info   # status=ACTIVE
openstack network agent list           # 전부 Alive :-)
openstack security group rule list project-sg
openstack server list                  # VM ACTIVE
```

---

## 9. "ACTIVE 안 됨" 빠른 진단표

| 증상 | 1순위 의심 | 조치 |
|------|-----------|------|
| 라우터가 계속 **DOWN** | L3 agent 죽음 / 게이트웨이 미설정 | `network agent list` → `neutron_l3_agent` 재시작, `router set --external-gateway` 확인 |
| 네트워크가 **DOWN/BUILD** | OVS·DHCP agent 죽음 | 해당 노드 `neutron_openvswitch_agent`/`neutron_dhcp_agent` 재시작 |
| VM **ERROR (PortBindingFailed)** | 외부 flat망에 VM 직접 연결 | tenant net + router + FIP로 변경 (§7) |
| VM ACTIVE인데 **SSH/ping 불가** | SG 규칙 / 키페어 | `project-sg`에 22·ICMP 추가, `--key-name` 확인 |
| FIP 줘도 외부 **통신 불가** | 라우터 게이트웨이 / physnet1 매핑 | `router set --external-gateway`, bridge_mappings 확인 |
| 특정 compute의 VM만 **통신 불가** | 그 compute OVS 터널 옛 IP | 그 compute에서 `docker restart neutron_openvswitch_agent` |

---

## 10. 한 줄 요약 (팀원에게)

1. **안 되면 명령 의심하기 전에 `openstack network agent list` 부터.** (죽은 agent 재시작)
2. **라우터는 `external-gateway 설정 + L3 agent` 둘 다 살아야 ACTIVE.**
3. **VM은 절대 외부 flat망(public1)에 직접 X → tenant net + router + FIP.**
