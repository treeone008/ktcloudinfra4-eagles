# 🐳 stack.yml 설명서

> `board-app`을 Docker Swarm 환경에 배포하기 위한 스택 정의 파일입니다.
> Rolling update, Rollback, Docker Secrets, 헬스체크, 리소스 제한을 고려하여 구성되었습니다.

<br>

## 목차

- [개요](#개요)
- [서비스 구성](#서비스-구성)
  - [이미지 & 환경변수](#이미지--환경변수)
  - [포트 설정](#포트-설정)
  - [Secrets](#secrets)
  - [배포 전략(deploy)](#배포-전략deploy)
  - [리소스 제한](#리소스-제한)
  - [헬스체크](#헬스체크)
  - [로깅](#로깅)
- [실행 방법](#실행-방법)
- [참고 사항](#참고-사항)

<br>

## 개요

`stack.yml`은 Docker Compose v3.8 스펙을 기반으로 작성된 **Swarm 전용 스택 파일**입니다.
`board` 서비스 하나만 정의되어 있으며, DB 접속 정보는 환경변수가 아닌 **Docker Secrets**로 주입받는 구조입니다.

<br>

## 서비스 구성

### 이미지 & 환경변수

| 항목 | 값 | 설명 |
| --- | --- | --- |
| 이미지 | `${BOARD_IMAGE:-jaeyun1/board:blue}` | `BOARD_IMAGE` 환경변수로 배포 이미지 지정 가능, 미지정 시 기본값은 `jaeyun1/board:blue` |
| `PORT` | `3000` | 컨테이너 내부 Fastify 서버가 사용하는 포트 |
| `HOST` | `0.0.0.0` | 모든 인터페이스에서 요청 수신 |

> 💡 이미지는 Blue/Green 총 2개로 배포 시 `BOARD_IMAGE=jaeyun1/board:green docker stack deploy ...` 형태로 이미지 태그만 바꿔서 배포하면 됩니다.

<br>

### 포트 설정

```yaml
ports:
  - target: 3000
    published: 80
    mode: host
```

| 항목 | 설명 |
| --- | --- |
| `target: 3000` | 컨테이너 내부 포트 |
| `published: 80` | 외부에 노출되는 포트 (호스트의 80번) |
| `mode: host` | 각 노드에서 직접 포트를 바인딩 (host 모드, ingress 로드밸런싱 미사용) |

<br>

### Secrets

DB 접속 정보 7종을 모두 **external secret**으로 참조합니다. (사전에 `docker secret create`로 생성 필요)

| Secret 이름 | 권한(mode) | uid | gid |
| --- | :---: | :---: | :---: |
| `db_type` | `0440` | `0` | `1000` |
| `db_primary_host` | `0440` | `0` | `1000` |
| `db_primary_port` | `0440` | `0` | `1000` |
| `db_user` | `0440` | `0` | `1000` |
| `db_password` | `0440` | `0` | `1000` |
| `db_name` | `0440` | `0` | `1000` |
| `db_replica_hosts` | `0440` | `0` | `1000` |

- 모든 secret은 읽기 전용(`0440`)이며, `gid: 1000` 그룹에게만 읽기 권한이 부여됩니다.
- 컨테이너 내부에서는 `/run/secrets/{secret명}` 경로로 파일 형태로 마운트됩니다.

<br>

### 배포 전략(deploy)

| 항목 | 값 | 설명 |
| --- | --- | --- |
| `mode` | `replicated` | 지정한 개수만큼 복제된 태스크 실행 |
| `replicas` | `2` | 총 2개의 컨테이너 실행 |
| `max_replicas_per_node` | `1` | 노드 하나당 최대 1개 컨테이너만 배치 (분산 배치) |
| `constraints` | `node.labels.role == was` | `role=was` 라벨이 붙은 노드에만 배포 |
| `update_config.parallelism` | `1` | 롤링 업데이트 시 한 번에 1개씩 갱신 |
| `update_config.delay` | `10s` | 다음 태스크 업데이트까지 10초 대기 |
| `update_config.order` | `stop-first` | 기존 컨테이너를 먼저 내린 후 새 컨테이너 기동 |
| `restart_policy.condition` | `on-failure` | 실패 시에만 재시작 |
| `restart_policy.delay` | `5s` | 재시작 전 5초 대기 |
| `restart_policy.max_attempts` | `3` | 최대 3회까지 재시도 |

> ⚠️ 라벨 
> 배포 전 리더 노드가 아닌 나머지 매니저 노드 + 워커 노드에 `docker node update --label-add role=was <노드명>` 으로 라벨을 지정되어 있음을 가정합니다.

<br>

### 리소스 제한

| 항목 | 값 |
| --- | --- |
| CPU 제한 | `1` core |
| 메모리 제한 | `256M` |
| 메모리 예약(reservation) | `128M` |

컨테이너 하나당 최소 128M ~ 최대 256M 메모리, 최대 1 코어까지 사용 가능하도록 제한되어 있습니다.

<br>

### 헬스체크

```yaml
healthcheck:
  test: ["CMD", "wget", "-qO-", "http://localhost:3000/health"]
  interval: 15s
  timeout: 5s
  retries: 3
  start_period: 10s
```

| 항목 | 값 | 설명 |
| --- | --- | --- |
| `test` | `wget -qO- http://localhost:3000/health` | `/health` 엔드포인트 호출로 상태 확인 |
| `interval` | `15s` | 15초마다 체크 |
| `timeout` | `5s` | 5초 이상 응답 없으면 실패 처리 |
| `retries` | `3` | 3회 연속 실패 시 unhealthy 판정 |
| `start_period` | `10s` | 컨테이너 기동 후 10초간은 실패해도 무시 (초기 부팅 유예시간) |

Dockerfile에서 `wget`을 별도 설치해두었기 때문에 이 헬스체크가 정상 동작합니다.

<br>

### 로깅

```yaml
logging:
  driver: json-file
  options:
    max-size: "10m"
    max-file: "3"
```

- `json-file` 드라이버 사용
- 로그 파일 하나당 최대 10MB, 최대 3개까지만 보관 (총 30MB 제한, 디스크 사용량 관리)

<br>

## 실행 방법

```bash
# 기본 이미지(jaeyun1/board:blue)로 배포
docker stack deploy -c stack.yml board-app

# 이미지를 직접 지정해서 배포 (Update 시)
BOARD_IMAGE=jaeyun1/board:green docker stack deploy -c stack.yml board-app
```

배포 전 아래 secret들이 먼저 생성되어 있어야 합니다.

```bash
echo "mysql" | docker secret create db_type -
echo "primary.db.internal" | docker secret create db_primary_host -
echo "3306" | docker secret create db_primary_port -
echo "board_user" | docker secret create db_user -
echo "supersecret" | docker secret create db_password -
echo "board_db" | docker secret create db_name -
echo "replica1.db.internal:3306,replica2.db.internal:3306" | docker secret create db_replica_hosts -
```

<br>

## 참고 사항

- `mode: host` 포트 바인딩을 사용하므로, 별도의 LB(예: Octavia)가 있어야 합니다.
- `constraints: node.labels.role == was`로 인해 `role=was` 라벨이 없는 노드에는 절대 스케줄링되지 않습니다.
- `replicas: 2` + `max_replicas_per_node: 1` 조합이므로, **최소 2개 이상의 `role=was` 노드**가 준비되어 있어야 정상 배포됩니다.
