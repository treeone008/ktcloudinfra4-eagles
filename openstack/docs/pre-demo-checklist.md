# 시연 / 통합 전 체크리스트

> 30분 전에 순서대로 확인 | AIO 기준 (시연 PC도 동일 항목 적용)

---

## A. 물리 / VMware (5분)

- [ ] 노트북(또는 시연 PC) 전원 · 네트워크 OK
- [ ] VMware Workstation 실행
- [ ] `testopenstack` VM **Power On**
- [ ] `ping 172.16.8.100` 응답 (OpenStack 호스트)
- [ ] 브라우저 http://172.16.8.100 → Horizon 로그인 화면

---

## B. OpenStack / Tenant VM (10분)

Horizon → **Project → Compute → Instances**

- [ ] master — **ACTIVE**
- [ ] swarm-mg — **ACTIVE**
- [ ] swarm-worker — **ACTIVE**
- [ ] monitor — **ACTIVE**
- [ ] db01 — **ACTIVE**
- [ ] db02 — **ACTIVE**

SHUTOFF 있으면: 선택 → **Start Instance**

Floating IP:

- [ ] master에 `172.16.8.146` 연결됨

---

## C. SSH 접속 (5분)

```bash
ssh -i ~/.ssh/project_key ubuntu@172.16.8.146
```

- [ ] master SSH 성공

master **안에서** (`scripts/verify-from-master.sh`):

- [ ] ping/SSH 전 VM OK

---

## D. 팀 연동 준비 (5분)

- [ ] `project_key.pub` 팀 공유됨
- [ ] IP 표 / 접속 가이드 Git·디스코드 공유
- [ ] Ansible inventory (`inventories/dev/hosts.ini`) 권건우 전달

---

## E. 장애 시 빠른 복구

kolla_toolbox 안에서:

```bash
openstack server list -f value -c ID -c Status | while read id st; do
  [ "$st" = "SHUTOFF" ] && openstack server start "$id"
done

openstack server add floating ip master 172.16.8.146
```
