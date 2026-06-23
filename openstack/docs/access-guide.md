# 접속 가이드 (1페이지)

> 김현도 AIO OpenStack — 팀 공유용 | 2026-06-23

---

## 빠른 요약

| 무엇 | 어디로 | 계정 |
|------|--------|------|
| OpenStack 웹 (Horizon) | http://172.16.8.100 | `admin` / `Asdzxcqwe!23` |
| OpenStack 호스트 SSH | `172.16.8.100` | `root` (MobaXterm 비번) |
| **팀 VM SSH (메인)** | `172.16.8.146` | `ubuntu` + `project_key` |

---

## 1. 사전 준비 (Windows)

1. VMware에서 `testopenstack` VM **Power On**
2. 2~3분 대기 후 브라우저: http://172.16.8.100
3. SSH 키 위치: `~/.ssh/project_key` (또는 `project-key`)
4. 공개키는 팀 디스코드/노션에 공유

---

## 2. Horizon (웹 UI)

```
URL   : http://172.16.8.100
ID    : admin
비밀번호: Asdzxcqwe!23
```

**여기서 확인할 것**
- Project → Compute → Instances → 6대 **ACTIVE**
- master에 Floating IP `172.16.8.146` 연결됐는지
- SHUTOFF면 ▶ Start

---

## 3. SSH — master (팀원 기본 접속)

```bash
ssh -i ~/.ssh/project_key ubuntu@172.16.8.146
```

**Host key 오류 시 (VM 재생성 후)**

```bash
ssh-keygen -R 172.16.8.146
```

---

## 4. SSH — master 안에서 다른 VM

```bash
ping -c 2 192.168.100.20    # swarm-mg
ping -c 2 192.168.100.21    # swarm-worker
ping -c 2 192.168.100.40    # monitor
ping -c 2 192.168.101.31    # db01
ping -c 2 192.168.101.32    # db02

ssh ubuntu@192.168.100.20
ssh ubuntu@192.168.100.21
ssh ubuntu@192.168.100.40
ssh ubuntu@192.168.101.31
ssh ubuntu@192.168.101.32
```

> OpenStack **호스트(172.16.8.100)** 에서 tenant private IP로 SSH 하면 **안 됩니다.** 반드시 master 안에서.

---

## 5. OpenStack CLI (관리자용)

`root@172.16.8.100` 접속 후:

```bash
docker exec -u 0 -it kolla_toolbox bash
source /tmp/admin-openrc.sh
export OS_AUTH_URL=http://172.16.8.100:5000

openstack server list
openstack floating ip list
```

`admin-openrc.sh`가 없으면:

```bash
docker cp /etc/kolla/admin-openrc.sh kolla_toolbox:/tmp/admin-openrc.sh
```

---

## 6. 자주 나는 문제

| 증상 | 해결 |
|------|------|
| `172.16.8.146` ping/SSH 안 됨 | Horizon에서 VM Start + FIP 연결 확인 |
| `Connection refused` | VM 부팅 중 — 1~2분 대기 |
| `Permission denied` | `project_key`와 VM keypair 불일치 → keypair 재등록 |
| Horizon 안 열림 | VMware VM 켜졌는지, `ping 172.16.8.100` |
