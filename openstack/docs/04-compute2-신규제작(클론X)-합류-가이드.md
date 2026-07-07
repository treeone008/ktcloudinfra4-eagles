# compute2(104) 신규 제작(클론 X) → kolla 합류 → Anti-Affinity 가이드 (2026-06-29)

> **왜 새로 만드나?** 02·03 가이드의 **클론 방식은 구조적으로 실패**한다(아래 근본원인). 이번엔 **새 Ubuntu VM**으로 만들어 `host=compute-node-02`를 깨끗하게 잡는다.
>
> **목표:** compute2(172.16.8.104)를 기존 클러스터에 합류 → db01/db02를 **anti-affinity**로 compute1/compute2에 분산. (로드맵 책임 10)

---

## ★ 근본원인 메모 (다시는 클론하지 말 것)

06-26~06-29 삽질의 진범:

- compute1을 **Full Clone**하면 nova 설정의 `[DEFAULT] host = compute1`이 **그대로 복사**된다.
- 그러면 compute2의 nova-compute가 **자기를 compute1이라 착각** → RabbitMQ 응답큐 `reply_compute1:nova-compute`를 **compute1과 공유**(컨슈머 2개).
- conductor가 compute1에 보내는 RPC 응답을 RabbitMQ가 **둘에게 번갈아 배달** → 절반이 엉뚱한 쪽으로 감 → 양쪽 다 `MessagingTimeout` → **compute1까지 down**.
- 증상 로그: `oslo_messaging ... No calling threads waiting for msg_id` + `MessagingTimeout: Timed out waiting for a reply` (`init_host → _get_nodes → conductor.call`).
- **해결은 compute2 VM 전원 OFF뿐이었음.** → 클론은 답이 아님. **신규 설치로 host를 분리**해야 근본 해결.

> 검증 포인트: 합류 후 RabbitMQ에 `reply_compute-node-02:nova-compute` 큐가 **따로** 생기고, `reply_compute1:nova-compute` 컨슈머가 **계속 1**이어야 정상.

---

## §0. 사전 정리

### 0-1. 깨진 클론 VM 제거
VMware Workstation에서 기존 클론 `compute-node-02`:
1. 전원 OFF 상태 확인 (이미 꺼둠)
2. 우클릭 → **Manage → Delete from Disk** (디스크째 삭제 — 약 60GB 회수)

> nova DB에는 compute2가 등록된 적 없으므로(등록 실패) 따로 지울 것 없음. 확인:
> ```bash
> source /etc/kolla/admin-openrc.sh
> openstack compute service list   # compute1만 있어야 정상
> openstack hypervisor list        # compute1만
> ```

### 0-2. RAM 배분 (storage OFF 유지 전략)
- storage(.103) **OFF 유지** → 그 RAM 자리에 compute2.
- 현재: control 6GB + compute1 6GB + network 2GB = 14GB → **compute2 = 4GB** 올려도 OK.
- ⚠️ storage는 인벤토리에서 `#172.16.8.103` 주석 상태. compute2 작업 끝나고 **볼륨 필요할 때 켜면서 주석 해제**.

---

## §1. 새 Ubuntu VM 생성 (compute-node-02)

VMware Workstation → New VM:

| 항목 | 값 |
|------|-----|
| OS | **Ubuntu 24.04.x Server** (noble) |
| 이름 | `compute-node-02` |
| vCPU | 4 (최소 2) |
| RAM | **4096MB** |
| Disk | 80GB (single file) |
| Network | **NAT (vmnet8)** — compute1과 동일 |
| **Virtualize Intel VT-x/EPT** | **반드시 ON** (nova가 KVM/QEMU 띄움) |

설치 시:
- 사용자 `user1` / 비번 `user1`
- **OpenSSH server 설치 체크**
- 설치 완료 후 reboot

> 새로 설치하므로 hostname·machine-id·SSH host key가 **처음부터 고유** → 클론 때의 식별자 정리 작업 불필요.

---

## §2. compute2 기본 설정 (compute2 콘솔)

```bash
sudo -i
# (1) 호스트네임
hostnamectl set-hostname compute-node-02

# (2) root 로그인 허용
passwd root            # test123
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
systemctl restart ssh
```

### 2-1. 고정 IP = 172.16.8.104
`/etc/netplan/50-cloud-init.yaml` (인터페이스명은 `ip a`로 확인, 보통 ens33/ens32):

```yaml
network:
  version: 2
  ethernets:
    ens33:
      addresses:
        - 172.16.8.104/24
      routes:
        - to: default
          via: 172.16.8.2
      nameservers:
        addresses: [8.8.8.8, 8.8.4.4]
```

```bash
chmod 600 /etc/netplan/50-cloud-init.yaml
netplan apply
ip -4 a | grep 172.16.8.104
ping -c2 172.16.8.100      # control
ping -c2 8.8.8.8
```

### 2-2. /etc/hosts (전 노드 일관성)
compute2의 `/etc/hosts`에 클러스터 노드 추가:

```
172.16.8.100 control
172.16.8.101 compute1
172.16.8.102 network
172.16.8.103 storage
172.16.8.104 compute-node-02
```

---

## §3. control에서 SSH 키 등록

```bash
# control(.100) root에서
ssh-keygen -f ~/.ssh/known_hosts -R 172.16.8.104   # 옛 키 흔적 제거(있으면)
ssh-copy-id root@172.16.8.104
ssh root@172.16.8.104 'hostname; ip -4 addr show | grep 172.16.8.104'   # 비번 없이 확인
```

---

## §4. kolla 인벤토리 확인 (control)

`/etc/kolla/multinode` — `[compute]`에 .104 있는지(금요일에 추가됨), storage 주석 상태 확인:

```bash
grep -nE '172.16.8.10[1-4]' /etc/kolla/multinode
```

기대:
```
[compute]
172.16.8.101
172.16.8.104
...
#172.16.8.103     ← storage는 주석 유지 (OFF라서)
```

ping 테스트(꺼진 .103은 UNREACHABLE 정상):

```bash
source /root/venv/bin/activate
ansible -i /etc/kolla/multinode all -m ping
# .100/.101/.102/.104 SUCCESS, .103(주석이면 목록에 없음) — compute2 SUCCESS만 확인되면 OK
```

---

## §5. compute2 배포 (bootstrap → pull → deploy)

```bash
source /root/venv/bin/activate

# (1) OS 준비 (docker 설치 등) — 신규 노드라 필수
kolla-ansible bootstrap-servers -i /etc/kolla/multinode --limit 172.16.8.104

# (2) 컨테이너 이미지 pull (신규라 시간 걸림)
kolla-ansible pull -i /etc/kolla/multinode --limit 172.16.8.104

# (3) 서비스 배포 (nova-compute, neutron-ovs-agent 등)
kolla-ansible deploy -i /etc/kolla/multinode --limit 172.16.8.104
```

> `--limit`인데 꺼진 storage(.103) facts 수집으로 멈추면 → 인벤토리에서 .103이 `#` 주석인지 재확인.

---

## §6. 컨트롤러에 새 compute 등록 (cell_v2 discover) — 필수

`--limit`로 compute만 배포하면 컨트롤러가 새 host를 모름:

```bash
# control에서 cell 등록
docker exec nova_api nova-manage cell_v2 discover_hosts --verbose
# (또는) docker exec nova_conductor nova-manage cell_v2 discover_hosts --verbose
```

---

## §7. 합류 검증 ★ (클론 문제 재발 안 했는지까지)

```bash
source /etc/kolla/admin-openrc.sh

# (1) nova-compute 2대 up
openstack compute service list --service nova-compute
#   기대: compute1, compute-node-02  둘 다 state=up

# (2) hypervisor 2대
openstack hypervisor list

# (3) neutron ovs agent (compute-node-02) alive
openstack network agent list | grep -i compute-node-02
```

### 7-1. 응답큐 분리 확인 (이번 가이드 핵심)
```bash
docker exec rabbitmq rabbitmqctl list_queues name consumers | grep -E 'reply_compute'
```
기대:
```
reply_compute1:nova-compute:1            1   ← compute1 단독(컨슈머 1)
reply_compute-node-02:nova-compute:1     1   ← compute2 별도 큐 생성(컨슈머 1)
```
→ 큐가 **분리**되고 각각 컨슈머 1이면 클론 문제 완전 해결. compute1이 다시 down 되지 않음.

---

## §8. db01/db02 Anti-Affinity 분산 (책임 10)

```bash
source /etc/kolla/admin-openrc.sh

GID=$(openstack server group list -f value -c ID -c Name | awk '/db-server-group/{print $1}')
echo "db-server-group = $GID"   # 비어있으면: openstack server group create --policy anti-affinity db-server-group

# db01 (private 101.31)
openstack server create --flavor m1.small --image ubuntu-22.04 \
  --nic net-id=project-private-net,v4-fixed-ip=192.168.101.31 \
  --security-group project-sg --key-name project_key \
  --hint group=$GID db01

# db02 (private 101.32)
openstack server create --flavor m1.small --image ubuntu-22.04 \
  --nic net-id=project-private-net,v4-fixed-ip=192.168.101.32 \
  --security-group project-sg --key-name project_key \
  --hint group=$GID db02

watch -n3 openstack server list
```

**검증 (핵심 산출물):**
```bash
openstack server show db01 -c name -c OS-EXT-SRV-ATTR:host -c status
openstack server show db02 -c name -c OS-EXT-SRV-ATTR:host -c status
```
- ✅ 성공: db01 host ≠ db02 host (하나 compute1, 하나 compute-node-02)
- ❌ 같은 host: `--hint group=` 누락 또는 compute 1대만 up

> `scripts/create-db-antiaffinity.sh`로 자동화 가능.

---

## §9. 마무리

- `문서화-마스터표.md`: §0 compute2 ✅, §1 db01/db02(host 기입), §7 db-server-group 멤버 ✅
- `프로젝트-로드맵.md`: 책임 10 ✅
- 데일리 클린업 작성
- storage 다시 켤 때 → `/etc/kolla/multinode`의 `#172.16.8.103` 주석 해제 + storage VM ON

---

## 트러블슈팅

| 증상 | 원인 | 조치 |
|------|------|------|
| compute1이 갑자기 down + MessagingTimeout | **클론 compute가 host 공유** | 클론 VM OFF/삭제, 신규 설치로 재합류(본 가이드) |
| `reply_compute1` 컨슈머 2개 | 클론이 같은 큐 구독 | 클론 제거 |
| compute service에 .104 없음 | cell 미등록 | §6 discover_hosts |
| deploy가 .103에서 멈춤 | 꺼진 storage facts | 인벤토리 `#172.16.8.103` 주석 |
| db01/db02 같은 host | hint 누락/노드1대 | `--hint group=` + compute 2대 up 확인 |
| db `No valid host` | compute2 RAM 부족 | flavor m1.small 또는 RAM↑ |
