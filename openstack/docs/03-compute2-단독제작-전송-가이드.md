# compute2(104) 로컬 제작 + 합류 + Anti-Affinity 검증 가이드 (2026-06-26)

> **방식:** storage 노드를 끄고, 그 RAM 자리에 compute2를 올려 **본인 노트북에서 직접**
> kolla 합류 + db01/db02 anti-affinity 검증까지 완료. (책임 10을 본인이 직접 마무리)
>
> **RAM 핵심:** anti-affinity 검증은 m1.small(볼륨X)라 **storage 불필요**.
> storage(4GB) OFF ↔ compute2(4GB) ON → **총 RAM 20GB 그대로, 조정 불필요.**

**켤 노드:** control(8) + compute1(6) + network(2) + compute2(4) = 20GB
**끌 노드:** storage

---

## 전체 흐름

```
1. storage 종료
2. compute1 Full Clone → compute-node-02
3. 식별자 정리 (hostname/machine-id/sshkey/IP=.104)
4. compute2 OS 검증 (IP/인터넷/docker)
5. control에서 kolla 합류 (인벤토리+bootstrap+deploy+cell discover)
6. compute 2대 up 확인
7. anti-affinity 검증 (db01/db02 서로 다른 host) ✅
```

---

## STEP 1. storage 노드 종료

storage 노드(콘솔 또는 SSH)에서:
```bash
shutdown -h now
```
→ VMware에서 storage가 Powered Off 되면 RAM 4GB 확보.

> control/compute1/network 3대는 계속 켜둔 채로.

---

## STEP 2. compute2 VM 생성 — compute1 클론

1. compute1(`Ubuntu 64-bit (2)`)을 **완전 종료** (clone은 전원 OFF에서)
   ```bash
   # compute1에서
   shutdown -h now
   ```
2. VMware → compute1 우클릭 → **Manage → Clone → Full Clone**
   - 이름: `compute-node-02`
3. 클론 설정: RAM **4096MB**, NIC = **NAT(vmnet8)**, **VT-x/EPT ON**
4. compute1 다시 전원 ON, 클론(compute2)도 전원 ON

---

## STEP 3. 식별자 정리 (클론 필수)

> 클론은 IP·hostname·machine-id·SSH host key가 compute1과 동일 → 충돌. 반드시 새로 발급.

compute2 콘솔(user1/user1 → `sudo -i`):

```bash
# 1) 호스트네임
hostnamectl set-hostname compute-node-02

# 2) machine-id 재발급
rm -f /etc/machine-id /var/lib/dbus/machine-id
systemd-machine-id-setup
ln -sf /etc/machine-id /var/lib/dbus/machine-id

# 3) SSH host key 재발급
rm -f /etc/ssh/ssh_host_*
ssh-keygen -A
```

IP 고정 — `/etc/netplan/50-cloud-init.yaml`:

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
reboot
```

---

## STEP 4. compute2 OS 검증

compute2 재부팅 후 (`sudo -i`):

```bash
ip -4 addr show ens32 | grep inet     # 172.16.8.104
hostname                               # compute-node-02
ping -c2 172.16.8.100                  # control 통신
ping -c2 www.google.com                # 인터넷
docker --version                       # 클론이라 docker 있음
docker images | grep -i kolla | head   # kolla 이미지 잔존(배포 빨라짐)
```

✅ IP=.104, hostname OK, control ping OK, 인터넷 OK 면 다음.

---

## STEP 5. control에서 kolla 합류

### 5-1. passwordless SSH 등록 (control에서)
```bash
# control(.100)
ssh-keygen -f /root/.ssh/known_hosts -R 172.16.8.104   # 옛 키 제거(클론이라 중요)
ssh-copy-id root@172.16.8.104
ssh root@172.16.8.104 'hostname'                        # 비번 없이 확인 → compute-node-02
```

### 5-2. 인벤토리에 .104 추가
`/etc/kolla/multinode`의 `[compute]` 섹션에 추가:
```ini
[compute]
<기존 compute1 IP>
172.16.8.104
```

```bash
source /root/venv/bin/activate
ansible -i /etc/kolla/multinode all -m ping            # .104 포함 SUCCESS (storage는 unreachable 무시)
```

> ⚠️ storage가 꺼져 있어 ansible ping에서 storage는 **UNREACHABLE** 뜸 → **정상**(의도된 것).

### 5-3. compute2 부트스트랩 + 배포 (compute2만 타겟)
```bash
kolla-ansible bootstrap-servers -i /etc/kolla/multinode --limit 172.16.8.104
kolla-ansible deploy -i /etc/kolla/multinode --limit 172.16.8.104
```

> OVS agent `waiting RETRYING`만 반복은 정상. 필요시:
> `kolla-ansible reconfigure -i /etc/kolla/multinode --tags openvswitch --limit 172.16.8.104`

### 5-4. 컨트롤러에 등록 (cell discover)
```bash
kolla-ansible deploy -i /etc/kolla/multinode --tags nova --limit 172.16.8.100,172.16.8.104
# 또는 수동:
# docker exec -it nova_conductor nova-manage cell_v2 discover_hosts --verbose
```

---

## STEP 6. compute 2대 up 확인

```bash
source /etc/kolla/admin-openrc.sh
openstack compute service list --service nova-compute
# compute1, compute-node-02(.104) 둘 다 State=up
openstack hypervisor list
```

---

## STEP 7. Anti-Affinity 검증 (오늘의 핵심)

> 서버그룹 `db-server-group`은 이미 생성됨(06-26). 스크립트가 재사용.

```bash
cd <repo>/openstack/scripts
source /etc/kolla/admin-openrc.sh
bash create-db-antiaffinity.sh
```

스크립트가 자동으로:
- compute 2대 up 확인 → db01/db02(m1.small) 생성 → ACTIVE 대기 → **host 다른지 PASS/FAIL**

수동 확인:
```bash
openstack server show db01 -c name -c OS-EXT-SRV-ATTR:host -c status
openstack server show db02 -c name -c OS-EXT-SRV-ATTR:host -c status
```

✅ **db01 host ≠ db02 host → anti-affinity 성공 (책임 10 완료)**

---

## 끝난 뒤

- 마스터표 §1(db01/db02 host 기입)·§7(멤버 채워짐)·§8 갱신
- (선택) 검증 끝난 완성본을 팀장에게 백업 전달
- storage 다시 필요해지면(볼륨 작업) compute2 또는 다른 노드와 RAM 조율

---

## 체크리스트

| 단계 | 내용 | 완료 |
|:---:|------|:---:|
| 1 | storage 종료 | ☐ |
| 2 | compute1 Full Clone → compute-node-02 | ☐ |
| 3 | hostname/machine-id/sshkey/IP=.104 | ☐ |
| 4 | compute2 OS 검증 | ☐ |
| 5 | kolla 합류 (인벤토리+bootstrap+deploy+cell) | ☐ |
| 6 | compute 2대 up | ☐ |
| 7 | anti-affinity 검증 PASS | ☐ |

---

## 트러블슈팅

| 증상 | 원인 | 조치 |
|------|------|------|
| ansible ping에서 storage UNREACHABLE | storage 꺼둠 | 정상(의도) |
| ansible ping .104 실패 | SSH 키 충돌 | 5-1 known_hosts -R 후 ssh-copy-id |
| compute service에 .104 없음 | cell 미등록 | 5-4 discover_hosts |
| db02 No valid host | compute2 RAM 부족 | flavor m1.small 확인, compute2 메모리 확인 |
| db01/db02 같은 host | 노드 1대만 up / hint 누락 | compute 2대 up 확인, 스크립트 재실행 |
