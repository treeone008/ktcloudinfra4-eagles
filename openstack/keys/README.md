# SSH 키페어 — project_key

> tenant 인스턴스 공용 SSH 키. **공개키만 보관**(개인키는 절대 repo에 올리지 말 것).

## 구성
| 키 | 위치 | 역할 |
|----|------|------|
| 공개키 (`project_key.pub`) | OpenStack 키페어 `project_key` + 이 폴더 + 인스턴스 `~ubuntu/.ssh/authorized_keys` | 자물쇠 (인스턴스에 주입) |
| 개인키 (`id_rsa`) | **control `/root/.ssh/id_rsa`** (나중에 mgmt에도 복사) | 열쇠 (접속하는 쪽) |

- 키페어 이름: `project_key`
- 지문(fingerprint): `0b:23:0e:cd:0c:c8:b6:8a:5f:6c:aa:26:97:79:df:a1`
- 등록일: 2026-06-25

## 사용
인스턴스 생성 시 `--key-name project_key` → cloud-init이 공개키를 인스턴스에 주입.

```bash
# FIP 있는 인스턴스 접속 (예: swarm-mg-01)
ssh -i /root/.ssh/id_rsa ubuntu@172.16.8.219

# 사설 전용(db) → mgmt 노드 생기면 mgmt에서 사설망 통해 접속
```

## mgmt 노드 만들 때 (예정)
control의 개인키를 mgmt로 복사해야 mgmt에서 인스턴스 SSH 가능:
```bash
# control → mgmt 로 개인키 복사 (mgmt 구축 후)
scp /root/.ssh/id_rsa root@172.16.8.200:/root/.ssh/id_rsa
```
