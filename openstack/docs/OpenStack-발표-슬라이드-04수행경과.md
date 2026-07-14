# 04 프로젝트 수행 경과 - OpenStack (5장)

> 파일: `OpenStack-발표-슬라이드-04수행경과.html`  
> 사용: HTML 더블클릭 → 브라우저에서 확인 · Ctrl+P로 PDF  
> Google Slides: 아래 텍스트를 각 슬라이드 텍스트 박스에 붙여넣고, `[이미지]` 자리에 captures PNG 삽입

캡처 경로: `openstack/docs/images/captures/`  
Raw 예: `https://raw.githubusercontent.com/treeone008/ktcloudinfra4-eagles/feature/openstack-network/openstack/docs/images/captures/06-cli-server-list-10active.png`  
**최종 tenant:** **9대** (`automation-01` 제외, 2026-07-14)

---

## 슬라이드 1 — 개요

**제목**
04 프로젝트 수행 경과 - OpenStack (1/5) 개요

**본문**
■ 목적
VMware 환경에서 Kolla-Ansible 기반 OpenStack(IaaS) 멀티노드 설계·구축·검증

■ 환경
• 플랫폼: VMware + Ubuntu 24.04 + Kolla-Ansible 2025.1
• 기간: 2026-06 ~ 2026-07
• 검증일: 2026-07-06

■ 구성 요약
• 인프라 노드: 7대 (mgmt / control / network / storage / compute×3)
• Tenant VM: 9대 (swarm / db / proxy / lb)
• 검증: server list 9/9 ACTIVE

■ 노드 IP
mgmt .200 · control .100 · network .101 · storage .102
compute .103 / .104 / .106 · VIP .105

[이미지] 01-vmware-library-7nodes.png

---

## 슬라이드 2 — 수행 내용

**제목**
04 프로젝트 수행 경과 - OpenStack (2/5) 수행 내용

**본문**
■ 주요 수행 항목

구분 | 내용
인프라 | control / network / storage / compute 역할 분리, Kolla-Ansible 배포
네트워크 | public1(flat) + project-public / private-net, project-router + FIP
컴퓨트·스토리지 | compute 3대, anti-affinity(db/swarm), Cinder db 볼륨
접속 | FIP .219 / .243, mgmt → control ProxyJump SSH 설계

■ 네트워크 접근 원칙
OK: VM → tenant net → router → public1 + FIP
NG: public1에 tenant VM 직접 연결

[이미지 선택] 04-horizon-network-topology.png

---

## 슬라이드 3 — 검증 결과

**제목**
04 프로젝트 수행 경과 - OpenStack (3/5) 검증 결과

**본문**
■ 검증 결과 (2026-07-06)

항목 | 결과
compute service | 3대 up
server list | 9/9 ACTIVE
network agent | L3 / DHCP / OVS UP
Floating IP | ping / SSH OK
Cinder volume | db 볼륨 in-use
server group | anti-affinity 적용

한 줄 요약: 멀티노드 OpenStack 위에 tenant 9대가 정상 ACTIVE로 기동됨

[이미지 크게] 06-cli-server-list-10active.png  (최종 9대 · 파일명 유지)
[이미지] 05-cli-compute-service-list.png

---

## 슬라이드 4 — 이슈 및 해결 (트러블슈팅)

**제목**
04 프로젝트 수행 경과 - OpenStack (4/5) 이슈 및 해결

**본문**
■ 원칙
안 되면 agent list → 부팅 순서 → SG/키 순으로 확인
(리소스 설정부터 의심하지 않음)

■ 주요 이슈

증상 | 원인 | 해결
PortBindingFailed | public1에 VM 직접 연결 | tenant net + router + FIP
compute RPC 타임아웃 | compute Full Clone → host 충돌 | 클론 금지 → 신규 VM 제작
No valid host | Placement 디스크/RAM 부족 | LVM 확장 / flavor 조정
재부팅 후 SHUTOFF | 자동 기동 미설정 | server start + nova 설정
db VM ERROR | storage 늦게 기동 | storage 먼저 → hard reboot

■ 하지 말 것
• compute Full Clone ❌ → 신규 VM 제작 ✅
• VM을 public1에 직접 ❌ → tenant net + FIP ✅
• storage 없이 db 기동 ❌ → control→network→storage→compute ✅

[이미지 선택] 08-cli-network-agent-list.png

---

## 슬라이드 5 — 결과 및 연동

**제목**
04 프로젝트 수행 경과 - OpenStack (5/5) 결과 및 연동

**본문**
■ 수행 결과
• OpenStack IaaS 멀티노드 기반 구축 완료
• tenant 9대 ACTIVE / FIP·Cinder·anti-affinity 검증 완료
• 산출물: 08 인수인계 · 캡처 13장 · 09 트러블슈팅 가이드

■ 팀 연동
본 구축(멀티노드) 위에 Ansible / Swarm / DB / Monitoring 연동
실시연은 강사 AIO로 단순화

■ 향후
• 재부팅 후 복구 체크리스트 운영
• resume_guests_state_on_host_boot 적용 검토
• mgmt ProxyJump 접속 절차 문서화 유지

[이미지] 09-cli-server-group-list.png
[이미지] 10-cli-floating-ip-list.png 또는 11-cli-volume-and-service.png
