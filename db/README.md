# DB Layer

## 1. 개요

본 디렉토리는 OpenStack 기반 인프라 프로젝트에서 DB 계층을 구성한 작업 산출물을 정리한 공간이다.

DB 계층의 목표는 단순히 MariaDB 서버를 설치하는 것이 아니라, 애플리케이션이 사용할 수 있는 안정적인 DB Endpoint를 제공하는 것이다.

주요 구성 범위는 다음과 같다.

- MariaDB Primary-Replica 구성
- GTID 기반 Replication 구성
- DB 백업/복구 스크립트 구성# DB Layer

## 1. 개요

본 디렉토리는 OpenStack 기반 인프라 프로젝트에서 DB 계층을 구성한 작업 산출물을 정리한 공간이다.

DB 계층의 목표는 단순히 MariaDB 서버를 설치하는 것이 아니라, 애플리케이션이 사용할 수 있는 안정적인 DB Endpoint를 제공하는 것이다.

주요 구성 범위는 다음과 같다.

- MariaDB Primary-Replica 구성
- GTID 기반 Replication 구성
- DB 백업/복구 스크립트 구성
- 백업 파일 mgmt 서버 자동 전송
- MaxScale 기반 DB Proxy 구성
- Pacemaker/Corosync 기반 VIP Failover 구성
- MariaDB 데이터 디렉토리(`/var/lib/mysql`) Cinder Volume 분리

---

## 2. 최종 아키텍처

```text
Docker Swarm / Web App
        |
        | DB Connection
        v
192.168.101.50:4006
MaxScale VIP
        |
        v
db-proxy-01 or db-proxy-02
        |
        +--------------------+
        |                    |
        v                    v
db01:3306              db02:3306
MariaDB Primary        MariaDB Replica
```

애플리케이션은 `db01`, `db02`에 직접 접속하지 않고, MaxScale VIP인 `192.168.101.50:4006`으로만 접속한다.

MaxScale은 DB 상태를 모니터링하고, 쿼리를 Primary/Replica로 라우팅한다.  
Pacemaker는 MaxScale Proxy 장애 시 VIP와 MaxScale 서비스를 다른 Proxy 노드로 이동시킨다.

---

## 3. 서버 구성

| Host | Role | Internal IP | Floating IP |
|---|---|---:|---:|
| db01 | MariaDB Primary | 192.168.101.31 | 172.16.8.190 |
| db02 | MariaDB Replica | 192.168.101.32 | 172.16.8.121 |
| db-proxy-01 | MaxScale / Pacemaker Node | 192.168.101.40 | 172.16.8.169 |
| db-proxy-02 | MaxScale / Pacemaker Node | 192.168.101.41 | 172.16.8.119 |
| VIP | DB Proxy Endpoint | 192.168.101.50 | - |

---

## 4. 네트워크 구성

| Network | CIDR | Purpose |
|---|---|---|
| sharednet1 | 172.16.8.0/24 | Floating IP / 외부 접근 |
| webserver | 192.168.1.0/24 | Web / Docker Swarm 영역 |
| db-net | 192.168.101.0/24 | DB / Proxy 전용 네트워크 |
| lb-mgmt-net | 10.1.0.0/24 | Octavia / Amphora 관리망 |

DB 서버와 DB Proxy는 `db-net`에 배치했다.

DB 전용 네트워크를 별도로 구성한 이유는 다음과 같다.

- Web 계층과 DB 계층을 네트워크 단위로 분리
- DB 서버 직접 노출 방지
- Web → MaxScale VIP → DB 흐름을 명확하게 구성
- Security Group 정책 적용 범위 단순화

---

## 5. Application DB Endpoint

애플리케이션에서는 아래 Endpoint만 사용한다.

```text
DB_HOST=192.168.101.50
DB_PORT=4006
DB_NAME=appdb
DB_USER=appuser
DB_PASSWORD=<APP_DB_PASSWORD>
```

`4006`은 MariaDB 기본 포트가 아니라 MaxScale Listener 포트이다.

실제 MariaDB 서버는 `3306` 포트를 사용한다.

```text
App
  -> 192.168.101.50:4006
  -> MaxScale
  -> db01:3306 / db02:3306
```

---

## 6. 디렉토리 구조

```text
db/
├── README.md
├── config/
│   ├── db01-60-replication.cnf
│   ├── db02-60-replication.cnf
│   ├── db.env.example
│   └── maxscale.cnf.example
├── scripts/
│   ├── backup.sh
│   └── restore.sh
├── sql/
│   ├── init-appdb.sql
│   ├── create-users.sql.example
│   └── replication-setup.sql.example
├── logs/
│   ├── db01-status.txt
│   ├── db02-status.txt
│   ├── db-proxy-01-status.txt
│   └── db-proxy-02-status.txt
├── openstack/
│   └── openstack-db-info.txt
└── docs/
```

---

## 7. MariaDB Primary-Replica

### 역할

| Host | Role |
|---|---|
| db01 | Primary |
| db02 | Replica |

`db01`에서 발생한 변경 사항은 binary log에 기록되고, `db02`는 해당 log를 받아 relay log로 저장한 뒤 자기 DB에 적용한다.

```text
db01 Primary
  -> binary log
  -> db02 relay log
  -> db02 Replica apply
```

### db01 설정 요약

```ini
[mysqld]
server_id=1
bind-address=0.0.0.0
log_bin=mysql-bin
binlog_format=ROW
gtid_strict_mode=ON
log_slave_updates=ON
```

### db02 설정 요약

```ini
[mysqld]
server_id=2
bind-address=0.0.0.0
log_bin=mysql-bin
relay_log=relay-bin
binlog_format=ROW
gtid_strict_mode=ON
log_slave_updates=ON
read_only=ON
```

### Replication 정상 기준

```text
Slave_IO_Running: Yes
Slave_SQL_Running: Yes
Seconds_Behind_Master: 0
Using_Gtid: Slave_Pos
Last_IO_Error:
Last_SQL_Error:
```

---

## 8. Backup / Restore

### 구조

```text
db01
  /home/ubuntu/db-practice/
    ├── config/db.env
    ├── scripts/backup.sh
    ├── scripts/restore.sh
    └── backup/

mgmt
  /home/team5/db-backups/
```

### Backup Flow

```text
backup.sh 실행
  -> db.env 로드
  -> mysqldump로 appdb dump 생성
  -> db01 로컬 backup 디렉토리에 저장
  -> mgmt 서버로 scp 전송
```

### Restore Flow

```text
restore.sh latest
  -> 최신 백업 파일 탐색
  -> appdb 생성
  -> 백업 SQL 파일 restore
```

현재 구현 범위는 다음과 같다.

- `backup.sh` 실행 시 로컬 백업 생성
- mgmt 서버로 백업 파일 자동 전송
- `restore.sh latest`를 통한 최신 백업 복구

주기적 자동 실행은 별도 cron 또는 systemd timer 구성이 필요하다.

---

## 9. MaxScale

MaxScale은 DB Proxy 역할을 수행한다.

애플리케이션은 DB 서버에 직접 접속하지 않고 MaxScale에 접속한다.  
MaxScale은 backend DB 서버 상태를 확인하고 쿼리를 적절한 DB 서버로 라우팅한다.

### 주요 설정

| Item | Value |
|---|---|
| Listener Port | 4006 |
| Backend DB | db01:3306, db02:3306 |
| Router | readwritesplit |
| Monitor | mariadbmon |
| VIP | 192.168.101.50 |

### MaxScale 구성 요약

```text
[Read-Write-Listener]
  -> 0.0.0.0:4006

[Read-Write-Service]
  -> readwritesplit

[MariaDB-Monitor]
  -> db01, db02 상태 모니터링
```

### readwritesplit 의미

- 쓰기 쿼리: Primary인 db01로 라우팅
- 읽기 쿼리: Replica인 db02 또는 적절한 서버로 라우팅

최종 검증에서 `SELECT` 결과가 `db02`로 나온 것은 read query가 Replica로 라우팅되었기 때문이다.

---

## 10. Pacemaker / Corosync

MaxScale Proxy 자체의 장애에 대비하기 위해 `db-proxy-01`, `db-proxy-02`를 2-node Pacemaker Cluster로 구성했다.

### Resource 구성

```text
Resource Group: g_db_proxy
  ├── p_vip       192.168.101.50
  └── p_maxscale  systemd:maxscale
```

VIP와 MaxScale을 같은 resource group으로 묶은 이유는, VIP가 존재하는 노드에서 MaxScale도 함께 실행되어야 하기 때문이다.

### Proxy Failover 흐름

```text
db-proxy-01 장애
  -> Pacemaker 감지
  -> g_db_proxy 리소스 그룹을 db-proxy-02로 이동
  -> VIP + MaxScale이 db-proxy-02에서 실행
  -> 애플리케이션은 동일하게 192.168.101.50:4006 접속
```

### 실습 환경 설정

2-node 실습 환경에서는 다음 설정을 사용했다.

```text
stonith-enabled=false
no-quorum-policy=ignore
```

운영 환경에서는 split-brain 방지를 위해 STONITH/fencing 구성이 필요하다.

---

## 11. Cinder Volume

초기 DB 구성에서는 MariaDB 데이터 디렉토리(`/var/lib/mysql`)가 인스턴스 root disk에 있었다.

운영 관점에서는 OS 디스크와 DB 데이터 디스크를 분리하는 것이 적절하므로, db01/db02 각각에 Cinder Volume을 attach하고 `/var/lib/mysql`을 Cinder Volume으로 이전했다.

### 변경 전

```text
db01
  root disk
    └── /var/lib/mysql

db02
  root disk
    └── /var/lib/mysql
```

### 변경 후

```text
db01
  root disk
  cinder volume /dev/vdb -> /var/lib/mysql

db02
  root disk
  cinder volume /dev/vdb -> /var/lib/mysql
```

### 최종 확인 결과

```text
/var/lib/mysql -> /dev/vdb
Filesystem: ext4
Size: 20G
```

각 DB 서버는 자기 전용 Cinder Volume을 사용한다.  
하나의 Cinder Volume을 db01/db02가 동시에 mount하지 않는다.

데이터 동기화는 Cinder가 아니라 MariaDB Replication이 담당한다.

---

## 12. 주요 검증 결과

최종 검증 항목은 다음과 같다.

### Cinder Mount

```text
db01 /var/lib/mysql -> /dev/vdb
db02 /var/lib/mysql -> /dev/vdb
```

### Replication

```text
Slave_IO_Running: Yes
Slave_SQL_Running: Yes
Seconds_Behind_Master: 0
Last_IO_Error:
Last_SQL_Error:
```

### Replication Insert Test

db01에 INSERT한 데이터가 db02에서 정상 조회됨.

```text
cinder-final-test
```

### Pacemaker

```text
Resource Group: g_db_proxy
  p_vip       Started db-proxy-01
  p_maxscale  Started db-proxy-01
```

### VIP

```text
db-proxy-01: 192.168.101.50
db-proxy-02: 없음
```

VIP는 두 Proxy 노드 중 하나에만 존재해야 한다.

### MaxScale VIP Connection

```text
192.168.101.50:4006 접속 성공
```

### Backup

```text
Backup completed
Transfer to mgmt completed
```

db01 로컬과 mgmt 서버 양쪽에 백업 파일 생성 확인.

---

## 13. Troubleshooting Summary

### 1. OpenStack CLI 접근 문제

OpenStack host에서 `openstack` 명령어가 바로 동작하지 않았다.  
Kolla-Ansible 기반 환경이므로 `kolla_toolbox` 내부에서 CLI를 사용했다.

```bash
docker exec -it kolla_toolbox bash
source /tmp/admin-service-openrc.sh
```

### 2. 고정 IP VM 생성 실패

`openstack server create --nic net-id=...,v4-fixed-ip=...` 방식에서 Nova API schema 오류가 발생했다.

해결 방식:

```text
Neutron Port를 먼저 생성
-> Port에 fixed IP 부여
-> openstack server create --port 방식으로 VM 생성
```

### 3. GTID 충돌

증상:

```text
Slave_SQL_Running: No
out-of-order sequence number
gtid strict mode is enabled
```

해결:

```text
db02 복제 초기화
-> db01 dump 생성
-> db02 restore
-> db01 gtid_binlog_pos를 db02 gtid_slave_pos로 설정
-> replication 재설정
```

### 4. MaxScale에서 db02 Down

원인:

```text
MariaDB 계정 Host 허용 범위 문제
```

해결:

```text
appuser, maxscale 계정의 Host 허용 범위 재정리
```

### 5. Cinder Volume 이전 후 GTID 충돌

db02의 `/var/lib/mysql`을 Cinder Volume으로 이전한 뒤 GTID 충돌이 재발했다.

해결 방식:

```text
db01 기준 dump 재생성
db02 appdb 재동기화
gtid_slave_pos 재설정
replication 재시작
```

---

## 14. 보안 및 운영 개선 사항

현재 구성은 실습/프로젝트 시연 기준이다.  
운영 환경에서는 다음 개선이 필요하다.

- DB 계정 권한 최소화
- `%` Host 허용 범위 축소
- 단순 비밀번호 제거
- Secret/Vault 기반 비밀번호 관리
- MaxScale REST API 기본 계정 변경
- Pacemaker STONITH/fencing 구성
- Security Group 최소 허용 정책 적용
- 주기적 백업 자동화
- 백업 보관 주기 및 삭제 정책 추가
- Cinder Snapshot/Backup 정책 추가

---

## 15. 최종 요약

본 DB 계층은 OpenStack 환경에서 MariaDB Primary-Replica를 구성하고, MaxScale과 Pacemaker 기반의 고정 DB Endpoint를 제공하도록 구성했다.

최종적으로 애플리케이션은 `192.168.101.50:4006` 하나만 바라보며, 뒤쪽에서 MaxScale이 DB 라우팅을 담당하고 Pacemaker가 Proxy 장애 시 VIP와 MaxScale 서비스를 이동시킨다.

또한 MariaDB 데이터 디렉토리(`/var/lib/mysql`)를 Cinder Volume으로 분리하여 OS disk와 DB data disk를 분리했고, `backup.sh` 실행 시 mgmt 서버로 백업 파일이 자동 전송되도록 구성했다.
- 백업 파일 mgmt 서버 자동 전송
- MaxScale 기반 DB Proxy 구성
- Pacemaker/Corosync 기반 VIP Failover 구성
- MariaDB 데이터 디렉토리(`/var/lib/mysql`) Cinder Volume 분리

---

## 2. 최종 아키텍처

```text
Docker Swarm / Web App
        |
        | DB Connection
        v
192.168.101.50:4006
MaxScale VIP
        |
        v
db-proxy-01 or db-proxy-02
        |
        +--------------------+
        |                    |
        v                    v
db01:3306              db02:3306
MariaDB Primary        MariaDB Replica
```

애플리케이션은 `db01`, `db02`에 직접 접속하지 않고, MaxScale VIP인 `192.168.101.50:4006`으로만 접속한다.

MaxScale은 DB 상태를 모니터링하고, 쿼리를 Primary/Replica로 라우팅한다.  
Pacemaker는 MaxScale Proxy 장애 시 VIP와 MaxScale 서비스를 다른 Proxy 노드로 이동시킨다.

---

## 3. 서버 구성

| Host | Role | Internal IP | Floating IP |
|---|---|---:|---:|
| db01 | MariaDB Primary | 192.168.101.31 | 172.16.8.190 |
| db02 | MariaDB Replica | 192.168.101.32 | 172.16.8.121 |
| db-proxy-01 | MaxScale / Pacemaker Node | 192.168.101.40 | 172.16.8.169 |
| db-proxy-02 | MaxScale / Pacemaker Node | 192.168.101.41 | 172.16.8.119 |
| VIP | DB Proxy Endpoint | 192.168.101.50 | - |

---

## 4. 네트워크 구성

| Network | CIDR | Purpose |
|---|---|---|
| sharednet1 | 172.16.8.0/24 | Floating IP / 외부 접근 |
| webserver | 192.168.1.0/24 | Web / Docker Swarm 영역 |
| db-net | 192.168.101.0/24 | DB / Proxy 전용 네트워크 |
| lb-mgmt-net | 10.1.0.0/24 | Octavia / Amphora 관리망 |

DB 서버와 DB Proxy는 `db-net`에 배치했다.

DB 전용 네트워크를 별도로 구성한 이유는 다음과 같다.

- Web 계층과 DB 계층을 네트워크 단위로 분리
- DB 서버 직접 노출 방지
- Web → MaxScale VIP → DB 흐름을 명확하게 구성
- Security Group 정책 적용 범위 단순화

---

## 5. Application DB Endpoint

애플리케이션에서는 아래 Endpoint만 사용한다.

```text
DB_HOST=192.168.101.50
DB_PORT=4006
DB_NAME=appdb
DB_USER=appuser
DB_PASSWORD=<APP_DB_PASSWORD>
```

`4006`은 MariaDB 기본 포트가 아니라 MaxScale Listener 포트이다.

실제 MariaDB 서버는 `3306` 포트를 사용한다.

```text
App
  -> 192.168.101.50:4006
  -> MaxScale
  -> db01:3306 / db02:3306
```

---

## 6. 디렉토리 구조

```text
db/
├── README.md
├── config/
│   ├── db01-60-replication.cnf
│   ├── db02-60-replication.cnf
│   ├── db.env.example
│   └── maxscale.cnf.example
├── scripts/
│   ├── backup.sh
│   └── restore.sh
├── sql/
│   ├── init-appdb.sql
│   ├── create-users.sql.example
│   └── replication-setup.sql.example
├── logs/
│   ├── db01-status.txt
│   ├── db02-status.txt
│   ├── db-proxy-01-status.txt
│   └── db-proxy-02-status.txt
├── openstack/
│   └── openstack-db-info.txt
└── docs/
```

---

## 7. MariaDB Primary-Replica

### 역할

| Host | Role |
|---|---|
| db01 | Primary |
| db02 | Replica |

`db01`에서 발생한 변경 사항은 binary log에 기록되고, `db02`는 해당 log를 받아 relay log로 저장한 뒤 자기 DB에 적용한다.

```text
db01 Primary
  -> binary log
  -> db02 relay log
  -> db02 Replica apply
```

### db01 설정 요약

```ini
[mysqld]
server_id=1
bind-address=0.0.0.0
log_bin=mysql-bin
binlog_format=ROW
gtid_strict_mode=ON
log_slave_updates=ON
```

### db02 설정 요약

```ini
[mysqld]
server_id=2
bind-address=0.0.0.0
log_bin=mysql-bin
relay_log=relay-bin
binlog_format=ROW
gtid_strict_mode=ON
log_slave_updates=ON
read_only=ON
```

### Replication 정상 기준

```text
Slave_IO_Running: Yes
Slave_SQL_Running: Yes
Seconds_Behind_Master: 0
Using_Gtid: Slave_Pos
Last_IO_Error:
Last_SQL_Error:
```

---

## 8. Backup / Restore

### 구조

```text
db01
  /home/ubuntu/db-practice/
    ├── config/db.env
    ├── scripts/backup.sh
    ├── scripts/restore.sh
    └── backup/

mgmt
  /home/team5/db-backups/
```

### Backup Flow

```text
backup.sh 실행
  -> db.env 로드
  -> mysqldump로 appdb dump 생성
  -> db01 로컬 backup 디렉토리에 저장
  -> mgmt 서버로 scp 전송
```

### Restore Flow

```text
restore.sh latest
  -> 최신 백업 파일 탐색
  -> appdb 생성
  -> 백업 SQL 파일 restore
```

현재 구현 범위는 다음과 같다.

- `backup.sh` 실행 시 로컬 백업 생성
- mgmt 서버로 백업 파일 자동 전송
- `restore.sh latest`를 통한 최신 백업 복구

주기적 자동 실행은 별도 cron 또는 systemd timer 구성이 필요하다.

---

## 9. MaxScale

MaxScale은 DB Proxy 역할을 수행한다.

애플리케이션은 DB 서버에 직접 접속하지 않고 MaxScale에 접속한다.  
MaxScale은 backend DB 서버 상태를 확인하고 쿼리를 적절한 DB 서버로 라우팅한다.

### 주요 설정

| Item | Value |
|---|---|
| Listener Port | 4006 |
| Backend DB | db01:3306, db02:3306 |
| Router | readwritesplit |
| Monitor | mariadbmon |
| VIP | 192.168.101.50 |

### MaxScale 구성 요약

```text
[Read-Write-Listener]
  -> 0.0.0.0:4006

[Read-Write-Service]
  -> readwritesplit

[MariaDB-Monitor]
  -> db01, db02 상태 모니터링
```

### readwritesplit 의미

- 쓰기 쿼리: Primary인 db01로 라우팅
- 읽기 쿼리: Replica인 db02 또는 적절한 서버로 라우팅

최종 검증에서 `SELECT` 결과가 `db02`로 나온 것은 read query가 Replica로 라우팅되었기 때문이다.

---

## 10. Pacemaker / Corosync

MaxScale Proxy 자체의 장애에 대비하기 위해 `db-proxy-01`, `db-proxy-02`를 2-node Pacemaker Cluster로 구성했다.

### Resource 구성

```text
Resource Group: g_db_proxy
  ├── p_vip       192.168.101.50
  └── p_maxscale  systemd:maxscale
```

VIP와 MaxScale을 같은 resource group으로 묶은 이유는, VIP가 존재하는 노드에서 MaxScale도 함께 실행되어야 하기 때문이다.

### Proxy Failover 흐름

```text
db-proxy-01 장애
  -> Pacemaker 감지
  -> g_db_proxy 리소스 그룹을 db-proxy-02로 이동
  -> VIP + MaxScale이 db-proxy-02에서 실행
  -> 애플리케이션은 동일하게 192.168.101.50:4006 접속
```

### 실습 환경 설정

2-node 실습 환경에서는 다음 설정을 사용했다.

```text
stonith-enabled=false
no-quorum-policy=ignore
```

운영 환경에서는 split-brain 방지를 위해 STONITH/fencing 구성이 필요하다.

---

## 11. Cinder Volume

초기 DB 구성에서는 MariaDB 데이터 디렉토리(`/var/lib/mysql`)가 인스턴스 root disk에 있었다.

운영 관점에서는 OS 디스크와 DB 데이터 디스크를 분리하는 것이 적절하므로, db01/db02 각각에 Cinder Volume을 attach하고 `/var/lib/mysql`을 Cinder Volume으로 이전했다.

### 변경 전

```text
db01
  root disk
    └── /var/lib/mysql

db02
  root disk
    └── /var/lib/mysql
```

### 변경 후

```text
db01
  root disk
  cinder volume /dev/vdb -> /var/lib/mysql

db02
  root disk
  cinder volume /dev/vdb -> /var/lib/mysql
```

### 최종 확인 결과

```text
/var/lib/mysql -> /dev/vdb
Filesystem: ext4
Size: 20G
```

각 DB 서버는 자기 전용 Cinder Volume을 사용한다.  
하나의 Cinder Volume을 db01/db02가 동시에 mount하지 않는다.

데이터 동기화는 Cinder가 아니라 MariaDB Replication이 담당한다.

---

## 12. 주요 검증 결과

최종 검증 항목은 다음과 같다.

### Cinder Mount

```text
db01 /var/lib/mysql -> /dev/vdb
db02 /var/lib/mysql -> /dev/vdb
```

### Replication

```text
Slave_IO_Running: Yes
Slave_SQL_Running: Yes
Seconds_Behind_Master: 0
Last_IO_Error:
Last_SQL_Error:
```

### Replication Insert Test

db01에 INSERT한 데이터가 db02에서 정상 조회됨.

```text
cinder-final-test
```

### Pacemaker

```text
Resource Group: g_db_proxy
  p_vip       Started db-proxy-01
  p_maxscale  Started db-proxy-01
```

### VIP

```text
db-proxy-01: 192.168.101.50
db-proxy-02: 없음
```

VIP는 두 Proxy 노드 중 하나에만 존재해야 한다.

### MaxScale VIP Connection

```text
192.168.101.50:4006 접속 성공
```

### Backup

```text
Backup completed
Transfer to mgmt completed
```

db01 로컬과 mgmt 서버 양쪽에 백업 파일 생성 확인.

---

## 13. Troubleshooting Summary

### 1. OpenStack CLI 접근 문제

OpenStack host에서 `openstack` 명령어가 바로 동작하지 않았다.  
Kolla-Ansible 기반 환경이므로 `kolla_toolbox` 내부에서 CLI를 사용했다.

```bash
docker exec -it kolla_toolbox bash
source /tmp/admin-service-openrc.sh
```

### 2. 고정 IP VM 생성 실패

`openstack server create --nic net-id=...,v4-fixed-ip=...` 방식에서 Nova API schema 오류가 발생했다.

해결 방식:

```text
Neutron Port를 먼저 생성
-> Port에 fixed IP 부여
-> openstack server create --port 방식으로 VM 생성
```

### 3. GTID 충돌

증상:

```text
Slave_SQL_Running: No
out-of-order sequence number
gtid strict mode is enabled
```

해결:

```text
db02 복제 초기화
-> db01 dump 생성
-> db02 restore
-> db01 gtid_binlog_pos를 db02 gtid_slave_pos로 설정
-> replication 재설정
```

### 4. MaxScale에서 db02 Down

원인:

```text
MariaDB 계정 Host 허용 범위 문제
```

해결:

```text
appuser, maxscale 계정의 Host 허용 범위 재정리
```

### 5. Cinder Volume 이전 후 GTID 충돌

db02의 `/var/lib/mysql`을 Cinder Volume으로 이전한 뒤 GTID 충돌이 재발했다.

해결 방식:

```text
db01 기준 dump 재생성
db02 appdb 재동기화
gtid_slave_pos 재설정
replication 재시작
```

---

## 14. 보안 및 운영 개선 사항

현재 구성은 실습/프로젝트 시연 기준이다.  
운영 환경에서는 다음 개선이 필요하다.

- DB 계정 권한 최소화
- `%` Host 허용 범위 축소
- 단순 비밀번호 제거
- Secret/Vault 기반 비밀번호 관리
- MaxScale REST API 기본 계정 변경
- Pacemaker STONITH/fencing 구성
- Security Group 최소 허용 정책 적용
- 주기적 백업 자동화
- 백업 보관 주기 및 삭제 정책 추가
- Cinder Snapshot/Backup 정책 추가

---

## 15. 최종 요약

본 DB 계층은 OpenStack 환경에서 MariaDB Primary-Replica를 구성하고, MaxScale과 Pacemaker 기반의 고정 DB Endpoint를 제공하도록 구성했다.

최종적으로 애플리케이션은 `192.168.101.50:4006` 하나만 바라보며, 뒤쪽에서 MaxScale이 DB 라우팅을 담당하고 Pacemaker가 Proxy 장애 시 VIP와 MaxScale 서비스를 이동시킨다.

또한 MariaDB 데이터 디렉토리(`/var/lib/mysql`)를 Cinder Volume으로 분리하여 OS disk와 DB data disk를 분리했고, `backup.sh` 실행 시 mgmt 서버로 백업 파일이 자동 전송되도록 구성했다.