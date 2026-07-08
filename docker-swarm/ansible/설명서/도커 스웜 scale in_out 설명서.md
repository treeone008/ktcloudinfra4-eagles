# ⚖️ Docker Swarm 워커 노드 Scale-out / Scale-in

> Ansible 기반으로 Docker Swarm **워커(worker)** 노드를 늘리거나(scale-out),
> 죽은 워커를 정리하며 줄이는(scale-in) role 모음입니다.
> `site.yml`을 진입점으로 하며, 상황에 맞는 태그만 지정해 실행합니다.

<br>

## 목차

- [소개](#소개)
- [Scale-out / Scale-in 비교](#scale-out--scale-in-비교)
- [전체 실행 흐름](#전체-실행-흐름)
- [공통: Stack 파일 = Source of Truth](#공통-stack-파일--source-of-truth)
- [Scale-out: 워커 추가](#scale-out-워커-추가)
- [Scale-in: 죽은 워커 정리](#scale-in-죽은-워커-정리)
- [실행 방법](#실행-방법)
- [주의사항](#주의사항)

<br>

## 소개

`board` 스택을 서비스하는 워커 노드 수를 상황에 따라 늘리거나 줄이는 두 가지 role입니다.

- **Scale-out**: 새 인스턴스를 워커로 조인시키고, 서비스 replicas를 1 늘립니다.
- **Scale-in**: `Down` 상태로 확인된(이미 죽은) 워커를 클러스터에서 제거하고, replicas를 1 줄입니다.

두 role 모두 **매니저(리더)에서 직접 워커를 조작**하고, **replicas 값은 Ansible 저장소 안의
`stack.yml` 파일**을 고쳐서 관리합니다 (서버에 있는 파일이 아니라 저장소 파일이 원본).

<br>

## Scale-out / Scale-in 비교

| 구분 | Scale-out | Scale-in |
| --- | --- | --- |
| 목적 | 워커 노드 추가 | 죽은 워커 노드 제거 |
| 대상 노드 판별 | 사람이 IP 직접 지정 (`worker_ip`) | 리더가 `docker node ls`로 `Status=Down`인 워커를 자동 탐지 |
| 사전 인벤토리 등록 | 불필요 (`add_host`로 즉석 등록) | 불필요 (이미 죽어서 SSH 자체가 불가능하다는 전제) |
| Docker 설치 | 신규 워커에 `swarm/docker` role을 즉석에서 include | 해당 없음 (노드를 지우기만 함) |
| replicas 변경 | `+1` | `-1` (단, `scale_in_min_replicas` 밑으로는 안 내려감) |
| 신규/잔존 노드 라벨 | 새 워커에 `role=was` 부여 | 해당 없음 (제거만 함) |

<br>

## 전체 실행 흐름

`site.yml` 기준 관련 플레이만 발췌하면 아래와 같습니다.

```yaml
- name: Discover current swarm leader
  hosts: swarm_managers
  tags: [swarm_scaleout, swarm_scalein]
  roles: [swarm/find-leader]

- name: Scale out - join a new worker and increase replicas
  hosts: swarm_managers
  tags: [swarm_scaleout]
  roles: [swarm/scaleout]

- name: Scale in - remove a dead worker and decrease replicas
  hosts: swarm_managers
  tags: [swarm_scalein]
  roles: [swarm/scalein]
```

> Scale-out/in 모두 **`find-leader`가 먼저 실행되어 `swarm_leader_hostname` / `swarm_leader_ip`가
> 채워져 있다는 전제**로 동작합니다. 두 role의 거의 모든 태스크가
> `when: inventory_hostname == hostvars['localhost'].swarm_leader_hostname` 조건으로
> **리더 노드 한 대에서만** 실행됩니다.

<br>

## 공통: Stack 파일 = Source of Truth

두 role 모두 replicas 값을 바꿀 때 아래 순서를 동일하게 따릅니다.

1. 저장소에 있는 원본 stack 파일(`roles/swarm/deploy/files/stack.yml`)에서 **replicas 숫자만** 찾아 `+1` 또는 `-1`로 수정
2. 수정된 stack 파일을 **저장소에 다시 저장**하고 (서버가 아니라 로컬 저장소가 원본이라는 원칙 유지), 리더 노드의 `/tmp/stack.yml`로 복사
3. `docker stack deploy -c /tmp/stack.yml board`로 재배포

| 변수 | 기본값 | 설명 |
| --- | --- | --- |
| `stack_file_repo_path` | `{{ playbook_dir }}/roles/swarm/deploy/files/stack.yml` | 원본 stack 파일 경로 (저장소 내부) |
| `stack_file_remote_path` | `/tmp/stack.yml` | 리더 노드에 배포용으로 복사되는 경로 |
| `stack_name` | `board` | `docker stack deploy` 대상 스택 이름 |
| `stack_service_name` | `board` | replicas를 조정할 서비스 이름 |

<br>

## Scale-out: 워커 추가

**필수 변수**

| 변수 | 필수 | 설명 |
| --- | :---: | --- |
| `worker_ip` | ✅ | 새로 조인시킬 워커의 IP (인벤토리에 미리 등록할 필요 없음) |

**동작 순서**

1. `worker_ip`가 지정됐는지 검증합니다.
2. `add_host`로 `scaleout_new_worker`라는 임시 인벤토리 호스트를 즉석 등록합니다
   (SSH 접속 정보는 `hosts.ini`의 `[all:vars]`에서 자동 상속).
3. 리더에서 워커용 join 토큰(`docker swarm join-token -q worker`)을 발급받습니다.
4. **조인 전** 노드 ID 목록을 변수에 저장해둡니다.
   (워커는 `docker node` 계열 명령 권한이 없어 self 조회가 불가능하므로, 이후 전/후 diff로 새 노드를 찾기 위함)
5. 새 워커에서
   - SSH 연결 대기
   - `swarm/docker` role을 즉석에서 `include_role`로 실행해 Docker 설치
   - `docker swarm join`으로 워커 조인
6. 조인 후 노드 ID 목록을 다시 저장하고, 조인 전/후 노드 ID 목록을 비교해서 새로 추가된 노드가 어떤 것인지 찾아냅니다.
7. 새 워커에 `role=was` 라벨을 부여합니다.
8. stack 파일의 replicas를 `+1` 해서 stack 파일에 반영하고, 리더에 재배포합니다.

<br>

## Scale-in: 죽은 워커 정리

**필수 변수**: 없음 (자동 탐지)

**동작 순서**

1. 리더에서 `docker node ls --filter role=worker`로 모든 워커의 `ID`/`Status`를 조회합니다.
2. `Status`에 `Down`이 포함된 항목만 걸러 ID 목록을 추출합니다.
3. Down 워커가 하나도 없으면 **즉시 실패 처리**합니다. (제거할 대상이 없다는 뜻이므로)
4. 찾은 Down 워커 ID들을 `docker node rm --force`로 클러스터에서 제거합니다.
5. stack 파일을 읽어 replicas를 `-1` 하되, `scale_in_min_replicas`(기본값 `1`) 밑으로는
   내려가지 않도록 `max()`로 하한선을 둡니다.
6. 변경된 stack 파일을 수정하고, 리더에 재배포합니다.

<br>

## 실행 방법

```bash
# 워커 추가 (scale-out)
ansible-playbook site.yml --tags swarm_scaleout \
  -e worker_ip=192.168.1.x

# 죽은 워커 정리 (scale-in)
ansible-playbook site.yml --tags swarm_scalein
```

<br>

## 주의사항

- Scale-in은 대상을 사람이 지정하지 않고 **`docker node ls`에서 `Down`으로 보이는 워커를 전부**
  제거합니다. Down으로 표시된 워커가 실제로는 일시적인 네트워크 단절일 수도 있으니,
  진짜로 죽은(재생성이 필요한) 인스턴스인지 모니터링을 통한 확인이 필요합니다.
- Scale-in의 최소 replicas 안전장치(`scale_in_min_replicas`, 기본값 `1`)는 서비스가 0대로
  내려가 완전히 중단되는 것을 막기 위한 것입니다. 필요 시 `-e scale_in_min_replicas=<N>`으로
  조정할 수 있습니다.
