# compute2(104) 추가 + db01/db02 Anti-Affinity 가이드 (2026-06-26)

> **목표:** compute2(172.16.8.104) 노드를 기존 4노드 kolla 클러스터에 추가하고,
> db01/db02를 **anti-affinity**로 compute1/compute2에 분산 배치. (로드맵 책임 10 — 1순위 blocker)
>
> **추천 경로:** 기존 **compute1을 클론** → 도커 이미지까지 복사돼서 배포가 빠름 (3시간 내 목표 달성용).
> 시간 여유 있으면 §A2 신규 설치 경로 사용.

---

## ⏱️ 3시간 타임박스 (권장)

| 구간 | 작업 | 예상 |
|------|------|------|
| 0:00~0:15 | §0 호스트 RAM 확인 + compute2 VM 클론 | 15분 |
| 0:15~0:45 | §1 식별자 정리 (IP/hostname/machine-id/SSH) | 30분 |
| 0:45~1:30 | §2 kolla에 compute2 추가 (bootstrap + deploy --limit) | 45분 |
| 1:30~1:45 | §3 cell 등록 + compute 서비스 up 확인 | 15분 |
| 1:45~2:30 | §4 db-server-group + db01/db02 생성·분산 검증 | 45분 |
| 2:30~3:00 | §5 문서 갱신 + 데일리 클린업 | 30분 |

---

## §0. 사전 확인 (필수)

### 0-1. 호스트(Windows) RAM 체크 — compute2 올려도 되는지

**측정 결과(2026-06-26):** 총 **31.68GB**, 현재 여유 **5.04GB**.
→ 현재 4노드(control 8 + compute1 6 + network 2 + storage 4 = 20GB) + Windows가 ~27GB 점유, 여유 5GB뿐.
→ compute2 6GB **불가**, 4GB도 그냥 올리면 여유 ~1GB로 위험(스왑/버벅임).

**✅ 결정: 다이어트 후 compute2 = 4GB + db는 m1.small로 검증**

| 조치 | 효과 |
|------|------|
| control 8GB → **6GB** | +2GB (control swap 4GB 있어 견딤) |
| storage 4GB → **3GB** | +1GB (Cinder LVM RAM 거의 안 씀) |
| → 여유 ~8GB 확보 후 | **compute2 = 4GB** 올림, 여유 ~4GB 유지 |

부하 배분(목표):
- compute1(6GB): swarm-mg(2) + db01(2) = 4GB
- compute2(4GB): db02(2) = 2GB

> ⚠️ 오늘 anti-affinity 검증은 **db01/db02 = m1.small(2GB)** 로. (서로 다른 host면 성공)
> 운영용 m1.medium(4GB)은 호스트 RAM 증설 후 재생성.

체크 명령(참고):
```powershell
(Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB
(Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB
```

### 0-1b. VM RAM 다이어트 절차 (VMware)

control / storage 각각:
1. VM **정상 종료**: `shutdown -h now`
2. VMware → VM 설정 → Memory: control **6144MB**, storage **3072MB**
3. 다시 전원 ON
4. control 재기동 후: `source /root/venv/bin/activate` 다시, `free -h`로 swap 활성 확인

### 0-2. IP 충돌 메모 (오늘 IP표 반영)

- `monitor = 172.16.8.110`인데, 기존 가이드에서 control **ens33(external)**도 .110을 쓴 적 있음 → monitor 노드 구축 시 **control ens33 IP 재확인** 필요. (오늘은 compute2가 우선, monitor는 뒤)
- `mgmt = 172.16.8.200` → FIP 풀 `.201~.250`으로 이미 정리(마스터표 §2).

---

## §A. compute2 VM 준비 — 둘 중 하나 선택

### §A1. (추천) compute1 클론 — 빠름

1. **compute1(.103) 정상 종료** (clone은 전원 OFF 상태에서):
   ```bash
   # compute1에서
   shutdown -h now
   ```
2. VMware Workstation → compute1 우클릭 → **Manage → Clone**
   - **Full Clone** 선택 (Linked X)
   - 이름: `compute-node-02`
3. 클론 VM 설정: RAM **4096MB**(§0 결정값), NIC = **동일 NAT(vmnet8)**, **VT-x/EPT 체크 ON**
4. compute1 다시 전원 ON, 클론(compute2)도 전원 ON
5. → **§1로 (식별자 정리 필수: IP/hostname/machine-id/SSH 키 중복 제거)**

### §A2. 신규 Ubuntu 설치 — 깔끔하지만 느림

`01-kolla-2node-가이드.md` Step 01~03을 compute2에만 적용:
- Ubuntu 24.04 설치 (SSH server만), user1/user1
- `sudo passwd root` → test123
- netplan: ens32 = `172.16.8.104/24`, gw .2, DNS 8.8.8.8 (아래 §1-2 yaml 동일)
- `PermitRootLogin yes` → ssh 재시작
- → **§1-3(SSH 키 교환)부터 이어서**, machine-id/hostname은 설치 시 새로 생성되므로 §1-1 생략 가능

---

## §1. compute2 식별자 정리 (클론 경로 필수)

> 클론은 **IP·hostname·machine-id·SSH host key가 compute1과 똑같다**. 그대로 두면 kolla/ansible/neutron이 충돌. 반드시 교정.

### 1-1. hostname + machine-id 새로 발급 (compute2 콘솔에서)

```bash
sudo -i

# 호스트네임 변경
hostnamectl set-hostname compute-node-02

# machine-id 재발급 (중복 제거)
rm -f /etc/machine-id /var/lib/dbus/machine-id
systemd-machine-id-setup
ln -sf /etc/machine-id /var/lib/dbus/machine-id

# SSH host key 재발급 (중복 제거)
rm -f /etc/ssh/ssh_host_*
dpkg-reconfigure openssh-server   # 또는: ssh-keygen -A
```

### 1-2. 고정 IP = 172.16.8.104 (compute2)

`/etc/netplan/50-cloud-init.yaml`:

```yaml
network:
  version: 2
  ethernets:
    ens32:
      addresses:
        - 172.16.8.104/24
      routes:
        - to: default
          via: 172.16.8.2
      nameservers:
        addresses: [8.8.8.8, 8.8.4.4]
```

```bash
netplan apply
ip a                       # 172.16.8.104 확인
hostname                   # compute-node-02 확인
ping -c2 172.16.8.100      # control
ping -c2 www.google.com
reboot                     # machine-id/hostkey 깨끗하게 재시작 권장
```

### 1-3. control에서 passwordless SSH 등록

```bash
# control(.100)에서
ssh-keygen -f ~/.ssh/known_hosts -R 172.16.8.104   # 옛 host key 제거(클론이면 중요)
ssh-copy-id root@172.16.8.104
ssh root@172.16.8.104 'hostname; ip -4 addr show ens32 | grep inet'   # 비번 없이 확인
exit
```

---

## §2. kolla에 compute2 추가

### 2-1. 인벤토리에 .104 추가 (control)

`/etc/kolla/multinode`의 `[compute]` 섹션:

```ini
[compute]
172.16.8.101
172.16.8.104
```

```bash
source /root/venv/bin/activate
ansible -i /etc/kolla/multinode all -m ping        # .104 포함 전 노드 SUCCESS 확인
```

### 2-2. compute2만 부트스트랩 + 배포

```bash
source /root/venv/bin/activate

# 1) 새 노드 OS 준비(docker 등). 클론이면 이미 docker 있음(무해)
kolla-ansible bootstrap-servers -i /etc/kolla/multinode --limit 172.16.8.104

# 2) (신규설치 경로만) 이미지 pull — 클론은 이미지 복사돼 있어 생략 가능
kolla-ansible pull -i /etc/kolla/multinode --limit 172.16.8.104

# 3) compute2에 서비스 배포 (nova-compute, neutron-ovs-agent 등)
kolla-ansible deploy -i /etc/kolla/multinode --limit 172.16.8.104
```

> OVS agent가 `waiting RETRYING`만 반복하면 정상(잠시 대기). **다른 ERROR**면 중단 후 로그 확인.
> 필요 시 OVS 재구성: `kolla-ansible reconfigure -i /etc/kolla/multinode --tags openvswitch --limit 172.16.8.104`

### 2-3. 컨트롤러에 새 compute 등록 (cell_v2 discover) — **중요**

`--limit`로 compute만 배포하면 컨트롤러가 새 host를 모름. 등록 필요:

```bash
# 방법 A) kolla가 discover_hosts 포함 — nova 태그를 control 포함해 재적용
source /root/venv/bin/activate
kolla-ansible deploy -i /etc/kolla/multinode --tags nova --limit 172.16.8.100,172.16.8.104

# 방법 B) 수동 discover (control에서)
docker exec -it nova_conductor nova-manage cell_v2 discover_hosts --verbose
```

---

## §3. compute2 가동 확인

```bash
source /etc/kolla/admin-openrc.sh

# nova-compute 2대(compute1, compute2) up 확인
openstack compute service list --service nova-compute
# 기대: 172.16.8.101(compute1), 172.16.8.104(compute2) 둘 다 state=up

# neutron agent (compute2의 ovs agent alive 확인)
openstack network agent list

# 하이퍼바이저 목록
openstack hypervisor list
```

### 3-1. compute2 디스크 확장 (클론이면 compute1 설정 따름, 신규설치면)

```bash
# compute2(.104)에서
lvextend -l +100%FREE /dev/ubuntu-vg/ubuntu-lv
resize2fs /dev/ubuntu-vg/ubuntu-lv
df -h
```

---

## §4. db-server-group(anti-affinity) + db01/db02 분산

```bash
source /etc/kolla/admin-openrc.sh

# 1) anti-affinity 서버그룹 생성
openstack server group create --policy anti-affinity db-server-group
GROUP_ID=$(openstack server group list -f value -c ID -c Name | awk '/db-server-group/{print $1}')
echo "GROUP_ID=$GROUP_ID"

# 2) db01 생성 (private net, 101.31) — 오늘은 RAM 절약 위해 m1.small(2GB)로 검증
openstack server create \
  --flavor m1.small \
  --image ubuntu-22.04 \
  --nic net-id=project-private-net,v4-fixed-ip=192.168.101.31 \
  --security-group project-sg \
  --key-name project_key \
  --hint group=$GROUP_ID \
  db01

# 3) db02 생성 (private net, 101.32)
openstack server create \
  --flavor m1.small \
  --image ubuntu-22.04 \
  --nic net-id=project-private-net,v4-fixed-ip=192.168.101.32 \
  --security-group project-sg \
  --key-name project_key \
  --hint group=$GROUP_ID \
  db02

# (운영용) 호스트 RAM 증설 후 m1.medium으로 재생성 — 오늘은 small로 anti-affinity만 검증

# 4) ACTIVE 대기
watch -n3 openstack server list
```

> RAM 부족으로 db02가 `No valid host`면: compute2를 6GB로 올리거나, 검증용으로 db01·db02를 **m1.small**로 임시 생성(이후 medium 재생성).

### 4-1. 분산(anti-affinity) 검증 — **핵심 산출물**

```bash
# 각 VM이 올라간 compute host 확인 → 서로 달라야 성공
openstack server show db01 -c name -c OS-EXT-SRV-ATTR:host -c addresses -c status
openstack server show db02 -c name -c OS-EXT-SRV-ATTR:host -c addresses -c status
```

- **성공 기준:** db01 host ≠ db02 host (하나는 compute1, 하나는 compute2)
- 같은 host면 anti-affinity 실패 → 서버그룹 hint 누락/노드 1대만 up 인지 확인

```bash
# 서버그룹 멤버 확인
openstack server group show db-server-group
```

---

## §5. 마무리 (문서 갱신)

- `문서화-마스터표.md`: §0 compute2 상태 ✅, §1 db01/db02 ✅(host 기입), §7 db-server-group ✅
- `프로젝트-로드맵.md`: 책임 10 ✅
- 데일리 클린업 `데일리-클린업-2026-06-26.md` 작성

---

## 트러블슈팅 빠른표

| 증상 | 원인 | 조치 |
|------|------|------|
| ansible ping .104 실패 | SSH 키/known_hosts 충돌 | §1-3 known_hosts -R 후 ssh-copy-id |
| compute service list에 .104 없음 | cell 미등록 | §2-3 discover_hosts |
| db02 `No valid host found` | compute2 RAM 부족 | compute2 RAM↑ 또는 flavor m1.small |
| db01/db02 같은 host | hint 누락/노드1대 | `--hint group=` 확인, compute2 up 확인 |
| neutron agent down(.104) | OVS 미구성 | reconfigure --tags openvswitch --limit .104 |
| 클론 후 IP 중복(.103) | netplan 미수정 | §1-2 적용 후 reboot |
```
