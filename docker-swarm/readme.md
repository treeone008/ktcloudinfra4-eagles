# 도커 스웜

* LB와의 연동을 위해 Routing Mesh는 쓰지 않고 Host mode로 변경하였습니다.

OpenStack 인프라 위에 Docker Swarm 매니저 3대로 클러스터를 구성하고, 게시판 애플리케이션(board-app)을 배포·운영·복구·확장하는 전 과정을 Ansible로 자동화한 프로젝트입니다.

---

### 0. 환경 개요

- 관리 노드(mgmt): Rocky Linux, Ansible 2.16.3
- 클러스터 노드: OpenStack 위 Ubuntu 22.04(jammy) 인스턴스 3대 (swarm-mg, swarm-mg2, swarm-mg3)
- 로드밸런서: Octavia — swarm-mg, swarm-mg2, swarm-mg3 80번 포트를 풀 멤버로 등록, Floating IP 연결
- 애플리케이션: Node.js 20(Alpine) + Fastify 5 기반 게시판(board-app)
- 민감정보 관리: Docker Secrets(/run/secrets/*)
- 비밀값 관리(Ansible): Ansible Vault
- 모니터링/자동복구: Prometheus + Alertmanager + Flask 기반 webhook adapter (heat-webhook)

---

### 1. Docker Swarm — Manager 3대 Service 배포 (Host mode)

#### 목표

매니저 3대로 Swarm 클러스터를 구성하고, board 서비스를 host 모드 포트 바인딩으로 배포하여 Octavia LB가 각 노드의 80번 포트로 직접 트래픽을 분산하게 함.

#### 실행 흐름 (--tags swarm_setup)

Step 1) Install Docker — swarm_managers 전체에 설치

Step 2) Init Swarm on leader — swarm-mg에서 클러스터 초기화

Step 3) Join other managers — swarm-mg2, swarm-mg3 조인

Step 4) Set node labels — role 라벨 부여

Step 5) Deploy stack — stack.yml 배포

#### 실행 명령어
```bin
ansible-playbook -i hosts.ini site.yml --tags swarm_setup
```
#### 실행 결과

![swarm_setup 결과](https://github.com/user-attachments/assets/3819cc6a-c690-47d6-b846-8443a5fb139d)

#### stack.yml 핵심 설정

- ports.mode: host — 각 노드가 직접 80→3000 포트 바인딩, ingress mesh 미사용
- deploy.replicas: 2, max_replicas_per_node: 1 — 노드당 최대 1개로 분산 배치
- deploy.constraints: node.labels.role == was — 리더 노드는 배포 대상에서 제외
- secrets: DB 접속 정보 7종, uid 0 / gid 1000 / mode 0440 — non-root 컨테이너 유저에게 그룹 읽기 권한만 부여
- healthcheck: wget -qO- http://localhost:3000/health, 15초 간격

---

### 2. Docker Swarm — Rolling Update / Rollback

#### 목표

서비스 무중단으로 새 버전(jaeyun1/board:green 등)으로 교체하고, 문제 발생 시 이전 버전으로 되돌릴 수 있게 함.

#### 실행 흐름 — Update (--tags swarm_update)

Step 1) BOARD_IMAGE 환경변수로 새 이미지 태그 지정

Step 2) docker stack deploy로 재배포

Step 3) update_config에 따라 컨테이너 1개씩 순차 교체

Step 4) 헬스체크 통과 확인 후 다음 컨테이너 진행

#### 실행 명령어
```bin
ansible-playbook -i hosts.ini site.yml --tags swarm_update
```
#### 실행 결과

![swarm_update 결과](https://github.com/user-attachments/assets/7cc51507-41dd-4f7d-bd7a-e865e2fd87f7)

#### 실행 흐름 — Rollback (--tags swarm_rollback)

Step 1) 이전 이미지 태그로 재배포

Step 2) update_config에 따라 컨테이너 1개씩 순차 교체

Step 3) 헬스체크 통과 확인

#### 실행 명령어
```bin
ansible-playbook -i hosts.ini site.yml --tags swarm_rollback
```
#### 실행 결과

![swarm_rollback 결과](https://github.com/user-attachments/assets/c33b941c-672b-4a08-b1c9-ed315cf83d55)

#### Blue/Green 이미지 전환

BOARD_IMAGE=jaeyun1/board:green docker stack deploy -c stack.yml board-app

stack.yml의 이미지가 ${BOARD_IMAGE:-jaeyun1/board:blue}로 정의되어, 환경변수 하나만 바꿔서 재배포하면 이미지 태그가 교체됨. 

프론트엔드도 index_blue.html/index_green.html 두 테마로 나뉘어 있어, 화면 세션 뱃지로 현재 응답 중인 컨테이너(세션 ID/IP)를 시각적으로 확인 가능.

#### 롤링 업데이트 설정 (deploy.update_config)

- parallelism: 1 — 한 번에 1개씩만 갱신
- delay: 10s — 다음 태스크 업데이트까지 대기
- order: stop-first — 기존 컨테이너를 먼저 내린 뒤 새 컨테이너 기동
- restart_policy: on-failure 조건, 최대 3회 재시도

---

### 3. Docker Swarm — Backup

#### 목표

Docker Swarm은 Kubernetes의 etcd 스냅샷 같은 공식 백업 기능이 없어, 매니저의 raft 상태(/var/lib/docker/swarm)를 직접 백업해 S3에 보관하도록 자동화.

#### 실행 흐름 (--tags swarm_backup)

Step 1) find-leader — 각 노드가 스스로 리더인지 확인

Step 2) backup — 리더가 아닌 노드 자동 선정

Step 3) 서비스 상태 기록

Step 4) raft 안정화 대기 (15초)

Step 5) docker 완전 정지 확인

Step 6) tar 백업 (권한 보존)

Step 7) mgmt로 전송

Step 8) 무결성 검증

Step 9) S3 업로드

Step 10) 업로드 검증

#### 실행 명령
```bin
ansible-playbook -i hosts.ini site.yml --tags swarm_backup
```
#### 실행 결과

<img width="418" height="199" alt="image" src="https://github.com/user-attachments/assets/5866caab-b742-40cc-8911-76c2cb67e6fe" />

#### 핵심 설계 포인트

- k8s의 etcd 대신 스웜의 raft 데이터 백업
- 살아있는 상태에서 백업하면 raft corruption 위험 → docker 정지 후 dockerd 프로세스가 실제로 완전히 죽었는지 재확인하는 루프 추가
- 백업 대상은 항상 리더가 아닌 노드에서 진행 (리더는 관리 트래픽 유지)
- S3 접근은 IAM 최소 권한으로 제한, 정적 액세스 키는 Ansible Vault로 암호화 보관

---

### 4. Docker Swarm — Manager 복구

#### 목표

매니저가 1대/2대/3대(전체) 다운되는 시나리오별로, 원리에 맞는 복구 절차를 각각 자동화.

> **업데이트:** 더 이상 사람이 상태를 보고 수동으로 태그를 실행하지 않습니다. Prometheus가 매니저 다운 개수를 감지하면 Alertmanager → webhook adapter를 거쳐 아래 플레이북이 자동으로 트리거됩니다. 자세한 흐름은 [6. 모니터링 & 자동 복구/스케일링](#6-docker-swarm--모니터링--자동-복구스케일링-prometheus--alertmanager--webhook) 참고. 아래 명령어는 수동으로 재실행하거나 디버깅할 때 사용하는 예시이며, down 노드 정보를 down_node_hostname 단일 값이 아니라 down_nodes(이름+고정IP 리스트, JSON) 형태로 전달하도록 변경되었습니다.

#### 실행 흐름 — 1대 다운, 쿼럼 유지 (--tags swarm_recovery1)

Step 1) find-leader — 생존 노드 중 리더 탐색

Step 2) 리더에서 manager join-token 발급

Step 3) 재생성된 노드 SSH 대기

Step 4) docker 확인 후 swarm join

Step 5) 재조인 노드 자기 ID 확보 (삭제 방지용 보호 장치)

Step 6) 유령(중복) 노드 정리

Step 7) 라벨 재적용 (role=leader / role=was)

#### 실행 명령 (수동 재실행 예시)
```bin
ansible-playbook -i hosts.ini site.yml \
  --tags swarm_recovery1 \
  -e '{"down_nodes": [{"name": "swarm-mg2", "fixed_ip": "192.168.1.21"}]}'
```
**Pending**: 생존 매니저 수 = 2
**Firing**: 90초 연속 유지

매니저 인스턴스 1대를 shutdown 시킨 뒤 매니저가 복구되는지 모니터링을 통해 확인합니다.
#### 실행 결과

<img width="374" height="311" alt="image" src="https://github.com/user-attachments/assets/e8c54f3f-2921-4295-9fd0-7182b5c80662" />

#### 실행 흐름 — 2대 다운, 쿼럼 상실 (--tags swarm_recovery2)

Step 1) 생존 노드에서 쿼럼이 실제로 깨졌는지 확인

Step 2) 생존 노드 자기 raft 데이터로 force-new-cluster 실행

Step 3) 재생성된 두 노드 재조인

Step 4) 유령(중복) 노드 정리

Step 5) 라벨 재적용

#### 명령어 (수동 재실행 예시)
```bin
ansible-playbook -i hosts.ini site.yml \
  --tags swarm_recovery2 \
  -e '{"down_nodes": [{"name": "swarm-mg2", "fixed_ip": "192.168.1.21"}, {"name": "swarm-mg3", "fixed_ip": "192.168.1.22"}]}'
```
**Pending**: 생존 매니저 수 = 1
**Firing**: 90초 연속 유지

#### 실행 결과

<img width="371" height="295" alt="image" src="https://github.com/user-attachments/assets/dcda51a9-8513-4253-a78c-68e5f25688a8" />

#### 실행 흐름 — 3대 다운, 전멸 (--tags swarm_recovery3)

Step 1) S3에서 최신 백업 키 탐색 (LastModified 기준)

Step 2) 백업 파일명에서 대상 호스트명 역산

Step 3) mgmt로 다운로드 및 무결성 검증

Step 4) 대상 노드로 전송 후 압축 해제 (권한 보존)

Step 5) 소유권/권한 재설정

Step 6) force-new-cluster 실행

Step 7) 유령(중복) 노드 정리

Step 8) 나머지 노드 재조인

Step 9) 라벨 재적용

#### 실행 명령 (수동 재실행 예시)
```bin
ansible-playbook -i hosts.ini site.yml \
  --tags swarm_recovery3 \
  -e '{"down_nodes": [{"name": "swarm-mg", "fixed_ip": "192.168.1.20"}, {"name": "swarm-mg2", "fixed_ip": "192.168.1.21"}, {"name": "swarm-mg3", "fixed_ip": "192.168.1.22"}]}'
```
**Pending**: 생존 매니저 수 = 0
**Firing**: 90초 연속 유지

#### 실행 결과

<img width="377" height="317" alt="image" src="https://github.com/user-attachments/assets/37cae254-f566-4e7c-a6ef-c075a5c59f2a" />

#### 핵심 설계 포인트

- 유령(중복) 노드는 상태값(Down/Unknown) 대신 호스트명 중복 여부로 판단, 매니저 역할이면 demote 후 삭제
- 복구 후 role=leader / role=was 라벨을 자동 재적용해 서비스가 올바른 노드에 재배치되도록 함
- down_nodes를 못 받은 경우(webhook payload에 라벨이 없는 경우)를 대비해 adapter 단에 노드 이름→고정IP 매핑 fallback 값을 둠

---

### 5. Docker Swarm — Scale in / out

#### 목표

부하에 따라 워커 노드를 동적으로 추가/제거하고, stack.yml의 replicas 값도 함께 조정.

> **업데이트:** 매니저 3대의 평균 CPU 사용률을 Prometheus가 계속 감시하다가, 임계치를 넘거나 밑돌면 Alertmanager → webhook adapter를 거쳐 아래 스케일 아웃/인 플레이북이 자동으로 트리거됩니다. 자세한 흐름은 [6. 모니터링 & 자동 복구/스케일링](#6-docker-swarm--모니터링--자동-복구스케일링-prometheus--alertmanager--webhook) 참고.

#### Scale out 흐름

Step 1) find-leader

Step 2) 다음 워커 번호/이름 자동 계산 (swarm-workerN)+ IP 자동 계산

Step 3) OpenStack 인스턴스 생성 + LB pool에 member 등록

Step 4) 새 워커를 임시 인벤토리로 등록  (add_host)

Step 5) 리더에서 join-token 발급 + 노드 ID 스냅샷 (조인 전)

Step 6) 새 워커에 Docker 설치

Step 7) swarm join 실행

Step 8) 노드 ID 스냅샷 (조인 후) → diff로 새 노드 특정

Step 9) role=was 라벨 부여

Step 10) stack.yml 원본 replicas +1

Step 11) 리더로 복사 후 재배포

#### 실행 명령 (수동 재실행 예시)
```bin
ansible-playbook -i hosts.ini site.yml --tags swarm_scaleout
```
**pending**: 매니저 3대의 평균 cpu 80% 이상
**Firing**: 2분 연속 지속

#### 실행 결과

<img width="380" height="260" alt="image" src="https://github.com/user-attachments/assets/27d60a7f-c9a4-4233-a4e7-b11ed48e7695" />

#### Scale in 흐름

Step 1) find-leader

Step 2) 리더에서 swarm-workerN 패턴의 워커 중 번호가 가장 큰(최근 생성) 워커 자동 선택

Step 3) 선택된 워커의 OpenStack 인스턴스 삭제

Step 4) 삭제 확인 (재조회, 안 지워졌으면 여기서 중단)

Step 5) LB pool에서 해당 member 제거

Step 6) 스웜에서 노드 강제 제거

Step 7) stack.yml 원본 replicas -1

Step 8) 재배포

#### 실행 명령 (수동 재실행 예시)
```bin
ansible-playbook -i hosts.ini site.yml --tags swarm_scalein
```
**Pending**: 매니저 3대의 평균 cpu 40% 미만
**Firing**: 3분 연속 지속 

#### 실행 결과

<img width="377" height="237" alt="image" src="https://github.com/user-attachments/assets/c2bb6600-c842-48c1-889f-012866b0a4cd" />

#### 핵심 설계 포인트

- IP와 이름을 워커 번호로 자동 매핑
- 사람 개입 없이 리더가 자동으로 대상 워커 판별
- 리소스 정리를 실제 존재 여부 순서대로 진행 (인스턴스 생존 확인 후 join / 삭제 확인 후 LB·스웜 정리)
---

### 6. Docker Swarm — 모니터링 & 자동 복구/스케일링 (Prometheus + Alertmanager + Webhook)

#### 목표

사람이 CPU 사용률이나 매니저 다운 상황을 직접 지켜보다가 수동으로 ansible-playbook을 실행하던 방식에서 벗어나, Prometheus가 상태를 감지 → Alertmanager가 알림을 라우팅 → webhook adapter가 알맞은 태그로 ansible-playbook을 자동 트리거하는 구조로 전환.

#### 전체 흐름

1. **수집 (Prometheus + node_exporter)** — swarm-target.yml에 정의된 매니저 3대(swarm-manager1~3) / 워커 3대(swarm-worker1~3)의 node_exporter를 Prometheus가 스크레이핑.
2. **판단 (swarm-rule.yml, Alerting/Recording Rules)**
   - swarm:manager_cpu_usage:percent — 매니저 3대 평균 CPU 사용률 recording rule
   - SwarmWorkerScaleOut — 평균 CPU가 2분간 80% 초과 → action=scale_out 알림 발생
   - SwarmWorkerScaleIn — 3분 이동평균 CPU가 40% 미만이고 워커가 1대 이상 → action=scale_in 알림 발생
   - swarm:manager_active_count — 살아있는 매니저 수 recording rule
   - SwarmManagerOneDown / SwarmManagerTwoDown / SwarmManagerAllDown — 생존 매니저 수가 2/1/0대일 때 각각 action=recovery_one / recovery_two / recovery_three 알림 발생 (90초간 지속 시)
3. **라우팅 (alertmanager.yml)** — 알림의 action 라벨 값에 따라 전용 webhook receiver(scale_out/scale_in/recovery_one/two/three)로 즉시 전달(group_wait: 0s)하고, 동시에 Slack으로도 상태를 통지. 동일 액션의 중복 알림은 repeat_interval: 1h로 억제.
4. **실행 (ansible-webhook.py, Flask)** — Alertmanager가 http://<mgmt>:8080/scale/out, /scale/in, /recovery/one, /recovery/two, /recovery/three로 POST하면, adapter가 해당 태그(swarm_scaleout, swarm_scalein, swarm_recovery1/2/3)로 ansible-playbook을 실행.
   - recovery 요청은 alert payload의 labels.node 값을 읽어 다운된 노드 이름 → {name, fixed_ip} 로 변환한 down_nodes 리스트를 -e로 전달 (payload에 못 담겨 있으면 사전 정의된 fallback 값 사용).
   - 같은 action이 COOLDOWN(기본 180초) 이내에 중복 발생하면 무시.
   - 이미 실행 중인 ansible-playbook이 있으면 새 요청을 건너뛰어 중복 실행 방지.
   - Alertmanager의 webhook 타임아웃을 피하기 위해 기본적으로 비동기(subprocess, 응답은 바로 200 OK)로 실행하며, 실제 진행 상황은 journalctl -u heat-webhook -f로 모니터링.

#### 핵심 설계 포인트

- 사람이 개입하지 않아도 CPU 부하/매니저 장애를 감지한 순간부터 대응까지 전 과정이 자동화됨
- Alertmanager → webhook 사이는 action 라벨 하나로 라우팅해 규칙(swarm-rule.yml)과 실행(ansible-webhook.py)의 결합도를 낮춤
- 쿨다운 + 프로세스 락 이중 안전장치로 스팸성 알림이나 재시도로 인한 플레이북 중복 실행을 방지
- 복구 계열 플레이북은 이제 down_node_hostname 단일 문자열 대신 down_nodes(이름+고정IP 객체 리스트)를 표준 입력으로 받도록 통일 — webhook 자동 트리거와 수동 실행 모두 동일한 형식 사용
