# OpenStack Kolla 2노드 구축 가이드 (2026-06-23)

> **목표:** control(100) + compute(101) 깡통 OpenStack 가동  
> **기준:** 강의자료 그대로 / Cinder·Octavia·Heat **OFF**  
> **Ubuntu:** [24.04.4 LTS Server amd64](https://ubuntu.com/download/server/thank-you?version=24.04.4&architecture=amd64&lts=true)

---

## 사전 체크

| 항목 | control (100) | compute (101) |
|------|---------------|---------------|
| vCPU | 8 (1×8) | 4 |
| RAM | 12 GB (12416 MB) | 6 GB (6208 MB) |
| Disk | 100 GB | 300 GB |
| NAT | **2개** (ens32 + ens33) | **1개** (ens32) |
| IP | 172.16.8.100, VIP .105 | 172.16.8.101 |
| vmnet | **동일 NAT (vmnet8)** | 동일 |
| compute 전용 | — | **VT-x/EPT 체크** (전원 켜기 전) |

**호스트 RAM:** VM 18GB + Windows 여유 → **32GB 이상 권장**

---

## Step 01 — Ubuntu 설치 (양쪽 동일)

1. ISO로 VM 생성 후 설치
2. 설치 옵션: **SSH server만** 체크, 나머지 continue
3. 사용자 `user1` / 비밀번호 `user1`
4. 설치 후 root 비밀번호:

```bash
sudo passwd root    # test123
sudo -i
```

> **이후 모든 명령은 root**

---

## Step 02 — netplan 고정 IP

`ip a`로 NIC 이름 확인 (보통 `ens32`, control은 `ens33` 추가)

### control (172.16.8.100) — `/etc/netplan/50-cloud-init.yaml`

```yaml
network:
  version: 2
  ethernets:
    ens32:
      addresses:
        - 172.16.8.100/24
      routes:
        - to: default
          via: 172.16.8.2
      nameservers:
        addresses: [8.8.8.8, 8.8.4.4]
    ens33:
      addresses:
        - 172.16.8.110/24
```

> ens33은 external용. 강의 netplan 캡처와 다르면 **강의 캡처 우선**. VIP `.105`는 Kolla가 ens32에 붙임.

### compute (172.16.8.101) — ens32만

```yaml
network:
  version: 2
  ethernets:
    ens32:
      addresses:
        - 172.16.8.101/24
      routes:
        - to: default
          via: 172.16.8.2
      nameservers:
        addresses: [8.8.8.8, 8.8.4.4]
```

```bash
netplan apply
ip a
ping -c 3 172.16.8.100   # compute에서
ping -c 3 172.16.8.101   # control에서
ping -c 3 www.google.com
```

### SSH root 허용

```bash
sed -i 's/#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
grep PermitRootLogin /etc/ssh/sshd_config
systemctl restart ssh
```

Windows MobaXterm: `root@172.16.8.100`, `root@172.16.8.101`

---

## Step 03 — Passwordless SSH (control에서)

```bash
ssh-keygen -t rsa    # Enter 3번
ssh-copy-id root@172.16.8.100
ssh-copy-id root@172.16.8.101
ssh root@172.16.8.101   # 비번 없이 접속 확인
exit
```

---

## Step 04 — venv + Kolla-Ansible (control만)

```bash
apt update -y && apt install -y git python3-dev libffi-dev gcc libssl-dev \
  libdbus-glib-1-dev python3-dbus libdbus-1-dev python3.12-venv

python3 -m venv /root/venv --system-site-packages
source /root/venv/bin/activate

pip install -U pip
pip install git+https://opendev.org/openstack/kolla-ansible@stable/2025.1
```

---

## Step 05 — /etc/kolla 준비 (control)

```bash
mkdir -p /etc/kolla
cp -r /root/venv/share/kolla-ansible/etc_examples/kolla/* /etc/kolla/
cp /root/venv/share/kolla-ansible/ansible/inventory/multinode /etc/kolla/multinode
kolla-genpwd
```

> **경로 통일:** 이후 `-i /etc/kolla/multinode` 만 사용

---

## Step 06 — multinode

`/etc/kolla/multinode` 상단:

```ini
[control]
172.16.8.100

[network]
172.16.8.100

[compute]
172.16.8.101

[monitoring]
172.16.8.100

[storage]
172.16.8.100
```

```bash
source /root/venv/bin/activate
ansible -i /etc/kolla/multinode all -m ping
```

---

## Step 07 — globals.yml 핵심

`/etc/kolla/globals.yml`:

```yaml
kolla_base_distro: "ubuntu"
openstack_release: "2025.1"

kolla_internal_vip_address: "172.16.8.105"
kolla_external_vip_address: "{{ kolla_internal_vip_address }}"

network_interface: "ens32"
kolla_external_vip_interface: "{{ network_interface }}"
api_interface: "{{ network_interface }}"
neutron_external_interface: "ens33"

neutron_plugin_agent: "openvswitch"
enable_openstack_core: "yes"
enable_haproxy: "yes"

enable_central_logging: "no"
enable_cinder: "no"
enable_grafana: "no"
enable_heat: "no"
enable_horizon: "yes"

enable_openvswitch: "{{ enable_neutron }}"
nova_compute_virt_type: "qemu"
```

---

## Step 08 — Bootstrap

```bash
source /root/venv/bin/activate
kolla-ansible install-deps
pip install docker python-openstackclient
apt update && apt install -y openvswitch-switch

kolla-ansible bootstrap-servers -i /etc/kolla/multinode
docker --version    # 양쪽 확인
```

모듈 없다고 하면: `pip install <패키지명>`

---

## Step 09 — Prechecks + common deploy

```bash
source /root/venv/bin/activate
kolla-ansible prechecks -i /etc/kolla/multinode

docker pull quay.io/openstack.kolla/kolla-toolbox:2025.1-ubuntu-noble
kolla-ansible deploy -i /etc/kolla/multinode --tags common
```

---

## Step 10 — Deploy (install.sh)

`/root/install.sh`:

```bash
#!/bin/bash
while [ 1 ]; do
  echo "========= ovs 재구성 : 시작 ==========="
  kolla-ansible reconfigure -i /etc/kolla/multinode --tags openvswitch
  if [ $? -eq 0 ]; then
    echo "======== ovs 재구성 : 완료 ============"
    kolla-ansible deploy -i /etc/kolla/multinode
    if [ $? -eq 0 ]; then
      echo "======= 컨테이너 배포 : 완료 ========="
      break
    else
      echo "======= 컨테이너 배포 : 실패 ========="
    fi
  else
    echo "======== ovs 재구성 : 실패 =========="
  fi
  sleep 3
done
```

```bash
chmod +x /root/install.sh
source /root/venv/bin/activate
./install.sh
```

**OVS waiting RETRYING만** 나오면 반복 OK. **다른 ERROR** 나오면 중단하고 로그 확인.

---

## Step 11 — post-deploy

```bash
source /root/venv/bin/activate
kolla-ansible post-deploy -i /etc/kolla/multinode
source /etc/kolla/admin-openrc.sh
cp /etc/kolla/admin-openrc.sh /root/
```

- Horizon: `http://172.16.8.105` 또는 `http://172.16.8.100`
- admin 비밀번호: `/etc/kolla/passwords.yml` → `keystone_admin_password`

---

## Step 12 — compute 디스크 확장 (300GB)

**101 (compute):**

```bash
lvextend -l +100%FREE /dev/ubuntu-vg/ubuntu-lv
resize2fs /dev/ubuntu-vg/ubuntu-lv
df -h
```

**100 (control):**

```bash
source /root/venv/bin/activate
kolla-ansible reconfigure -i /etc/kolla/multinode --tags nova
```

---

## Step 13 — 성공 확인

1. Horizon 로그인
2. flavor / image / network / SG / keypair 생성
3. 테스트 인스턴스 1대 생성
4. **101에서:** `virsh list --all` → `instance-000000xx` running

---

## 오늘 진행 체크

| Step | 내용 | 완료 |
|:----:|------|:----:|
| 0 | VMware VM 2대 생성 + VT-x | ☐ |
| 1 | Ubuntu 설치 | ☐ |
| 2 | netplan + ping + root SSH | ☐ |
| 3 | ssh-copy-id | ☐ |
| 4~5 | Kolla 설치 + /etc/kolla | ☐ |
| 6 | ansible ping | ☐ |
| 7 | globals.yml | ☐ |
| 8 | bootstrap | ☐ |
| 9 | prechecks + common | ☐ |
| 10 | deploy (install.sh) | ☐ |
| 11 | post-deploy + Horizon | ☐ |
| 12 | compute 디스크 확장 | ☐ |
| 13 | 테스트 VM + virsh | ☐ |

---

## 문제 발생 시 보낼 것

- **어느 Step**에서 막혔는지
- **전체 에러 로그** (waiting RETRYING만이면 Step 번호만)
- `ip a` 결과 (100, 101)
- `free -h` / `df -h`
