# 인수인계 — compute2 추가 + db Anti-Affinity (2026-06-26)

> 작성: 김현도 → **팀장(시연PC) 검증 요청**
> 이유: 내 노트북 호스트 RAM **32GB(여유 5GB)** 라 compute 2대 동시 가동이 무리.
> anti-affinity는 **compute 2대가 동시에 떠 있어야** 검증되는 작업 → **시연PC에서 진행 요청.**

---

## 1. 지금까지 된 것 (검증 완료 / 노트북)

| 항목 | 상태 |
|------|------|
| OpenStack 4노드 (control/compute1/network/storage) deploy | ✅ |
| 이미지(ubuntu-22.04) / 플레이버(m1.small·medium) | ✅ |
| 네트워크(public1, project-public/private-net) / 서브넷 / 라우터 | ✅ |
| 보안그룹(project-sg) / 키페어(project_key) | ✅ |
| Floating IP / Cinder(cinder-volumes) | ✅ |
| 첫 tenant VM **swarm-mg**(192.168.100.20, FIP 172.16.8.219) | ✅ ACTIVE |

→ **compute 1대로 가능한 건 거의 끝.** 남은 핵심 = **2-compute anti-affinity 분산**(책임 10).

---

## 2. 왜 시연PC에서 해야 하나

- anti-affinity = "db01, db02를 **서로 다른 compute 노드**에 강제 배치" → **compute 노드 2대 동시 가동 필수**
- 내 노트북: control8 + compute1 6 + network2 + storage4 = 20GB 점유, **여유 5GB** → compute2(4GB) 추가 시 호스트 스왑/버벅임/배포 중 OOM 위험
- 시연PC는 RAM 여유가 크므로 거기서 compute2 올리고 검증하는 게 합리적

---

## 3. 시연PC에서 할 일 (순서)

### STEP 1. compute2 노드 추가
- 상세: `docs/02-compute2-추가-anti-affinity-가이드.md` §A~§3 그대로
- 요약:
  1. compute2 VM 준비 (compute1 **Full Clone** 추천, 또는 신규 Ubuntu)
  2. **클론이면 식별자 교정 필수**: hostname / machine-id / SSH host key 재발급 + IP=`172.16.8.104`
  3. `/etc/kolla/multinode` `[compute]`에 `172.16.8.104` 추가
  4. `kolla-ansible bootstrap-servers --limit 172.16.8.104`
  5. `kolla-ansible deploy --limit 172.16.8.104`
  6. cell 등록: `kolla-ansible deploy --tags nova --limit 172.16.8.100,172.16.8.104`
     (또는 `docker exec -it nova_conductor nova-manage cell_v2 discover_hosts --verbose`)

### STEP 2. compute 2대 up 확인
```bash
source /etc/kolla/admin-openrc.sh
openstack compute service list --service nova-compute   # .101, .104 둘 다 up
```

### STEP 3. anti-affinity 스크립트 실행 (자동)
```bash
cd <받은폴더>/openstack/scripts
source /etc/kolla/admin-openrc.sh
bash create-db-antiaffinity.sh
# RAM 충분하면:  FLAVOR=m1.medium bash create-db-antiaffinity.sh
```
- 이 스크립트가: 서버그룹 생성 → db01/db02 생성 → ACTIVE 대기 → **host 다른지 자동 PASS/FAIL** 출력

---

## 4. 검증 기준 (PASS 조건)

```bash
openstack server show db01 -c name -c OS-EXT-SRV-ATTR:host -c addresses -c status
openstack server show db02 -c name -c OS-EXT-SRV-ATTR:host -c addresses -c status
```

| 항목 | PASS 기준 |
|------|-----------|
| db01 status | ACTIVE |
| db02 status | ACTIVE |
| **db01 host ≠ db02 host** | 하나는 compute1(.101), 하나는 compute2(.104) |
| db01 IP | 192.168.101.31 |
| db02 IP | 192.168.101.32 |

→ **db01 host ≠ db02 host 이면 anti-affinity 성공.** (스크립트가 ✅ PASS로 표시)

---

## 5. 같이 보낸 파일 (zip 내용)

| 파일 | 내용 |
|------|------|
| `docs/02-compute2-추가-anti-affinity-가이드.md` | compute2 추가 + anti-affinity 전체 런북 |
| `docs/문서화-마스터표.md` | IP/VM/네트워크/SG/배치 마스터표 (오늘 IP 반영) |
| `docs/프로젝트-로드맵.md` | 전체 방향/책임목록 |
| `scripts/create-db-antiaffinity.sh` | **시연PC에서 실행할 자동 스크립트** |
| (control에서 추출) `etc-kolla-config.zip` | globals.yml / multinode / passwords.yml / admin-openrc.sh |

> control 노드 설정 추출 방법은 §6 참고.

---

## 6. control 노드에서 설정 압축 (내가 보내기 전 실행)

```bash
# control(.100)에서
cd /etc/kolla
zip -r /root/etc-kolla-config-2026-06-26.zip globals.yml multinode passwords.yml admin-openrc.sh
ls -lh /root/etc-kolla-config-2026-06-26.zip
# → MobaXterm 등으로 노트북에 내려받아 이 폴더에 동봉
```

> ⚠️ `passwords.yml`에 admin 비밀번호 포함 → **DM/사내 채널로만 전달**, 공개 X.

---

## 7. 검증 끝나면 회신해줄 것

- `create-db-antiaffinity.sh` 출력 **마지막 검증 블록** (PASS/FAIL + db01/db02 host)
- `openstack compute service list` 결과 (compute 2대 up)
- 실패 시: `openstack server show db02 -c fault`

→ 받으면 마스터표 §1/§7/§8 + 로드맵 책임 10 **✅ 완료**로 갱신.
