#!/bin/bash
# =====================================================================
# create-db-antiaffinity.sh
# db-server-group(anti-affinity) + db01/db02 생성 및 분산 검증
#
# 실행 위치: control 노드 (시연PC), root
# 전제: compute 노드 2대 이상 up + project-private-net / project-sg /
#       project_key / ubuntu-22.04 이미지 / m1.small 플레이버 존재
#
# 사용:
#   source /etc/kolla/admin-openrc.sh
#   bash create-db-antiaffinity.sh
#
# 환경변수로 조정 가능:
#   FLAVOR=m1.medium bash create-db-antiaffinity.sh   # RAM 충분하면 medium
# =====================================================================
set -euo pipefail

FLAVOR="${FLAVOR:-m1.small}"      # 오늘 검증용 기본 small(2GB). 운영은 m1.medium
IMAGE="${IMAGE:-ubuntu-22.04}"
NET="${NET:-project-private-net}"
SG="${SG:-project-sg}"
KEY="${KEY:-project_key}"
GROUP_NAME="${GROUP_NAME:-db-server-group}"
DB01_IP="${DB01_IP:-192.168.101.31}"
DB02_IP="${DB02_IP:-192.168.101.32}"

echo "==================================================================="
echo " db anti-affinity 배포 시작"
echo "  flavor=$FLAVOR image=$IMAGE net=$NET sg=$SG key=$KEY"
echo "==================================================================="

# 0) admin 인증 확인
if ! openstack token issue >/dev/null 2>&1; then
  echo "[ERROR] OpenStack 인증 실패. 먼저: source /etc/kolla/admin-openrc.sh" >&2
  exit 1
fi

# 0-1) compute 노드 2대 이상 up 확인 (anti-affinity 핵심 전제)
UP_COMPUTES=$(openstack compute service list --service nova-compute -f value -c State | grep -c '^up$' || true)
echo "[INFO] up 상태 nova-compute 수: $UP_COMPUTES"
if [ "$UP_COMPUTES" -lt 2 ]; then
  echo "[ERROR] compute 노드가 2대 미만이라 anti-affinity 검증 불가." >&2
  echo "        compute2를 먼저 추가/기동하세요. (가이드 02 §2~§3)" >&2
  openstack compute service list --service nova-compute || true
  exit 1
fi

# 1) 서버그룹 생성(이미 있으면 재사용)
if openstack server group list -f value -c Name | grep -qx "$GROUP_NAME"; then
  echo "[INFO] 서버그룹 $GROUP_NAME 이미 존재 → 재사용"
else
  openstack server group create --policy anti-affinity "$GROUP_NAME" >/dev/null
  echo "[OK] 서버그룹 생성: $GROUP_NAME (anti-affinity)"
fi
GROUP_ID=$(openstack server group list -f value -c ID -c Name | awk -v n="$GROUP_NAME" '$0 ~ n {print $1}')
echo "[INFO] GROUP_ID=$GROUP_ID"

# 2) db01 / db02 생성 (이미 있으면 건너뜀)
create_vm () {
  local name="$1" ip="$2"
  if openstack server show "$name" >/dev/null 2>&1; then
    echo "[INFO] $name 이미 존재 → 생성 건너뜀"
    return
  fi
  echo "[..] $name 생성 중 ($ip)"
  openstack server create \
    --flavor "$FLAVOR" \
    --image "$IMAGE" \
    --nic net-id="$NET",v4-fixed-ip="$ip" \
    --security-group "$SG" \
    --key-name "$KEY" \
    --hint group="$GROUP_ID" \
    "$name" >/dev/null
  echo "[OK] $name 생성 요청 완료"
}
create_vm db01 "$DB01_IP"
create_vm db02 "$DB02_IP"

# 3) ACTIVE 대기 (최대 ~3분)
echo "[..] db01/db02 ACTIVE 대기"
for i in $(seq 1 36); do
  S1=$(openstack server show db01 -f value -c status 2>/dev/null || echo NONE)
  S2=$(openstack server show db02 -f value -c status 2>/dev/null || echo NONE)
  echo "    db01=$S1 db02=$S2"
  if [ "$S1" = "ACTIVE" ] && [ "$S2" = "ACTIVE" ]; then break; fi
  if [ "$S1" = "ERROR" ] || [ "$S2" = "ERROR" ]; then
    echo "[ERROR] VM 생성 실패(ERROR). 아래 fault 확인:" >&2
    openstack server show db01 -c fault || true
    openstack server show db02 -c fault || true
    exit 1
  fi
  sleep 5
done

# 4) anti-affinity 검증 (host 다른지)
H1=$(openstack server show db01 -f value -c OS-EXT-SRV-ATTR:host)
H2=$(openstack server show db02 -f value -c OS-EXT-SRV-ATTR:host)
echo "==================================================================="
echo " 검증 결과"
echo "  db01 host = $H1"
echo "  db02 host = $H2"
if [ -n "$H1" ] && [ "$H1" != "$H2" ]; then
  echo "  ✅ PASS: db01/db02가 서로 다른 compute에 배치됨 (anti-affinity 성공)"
else
  echo "  ❌ FAIL: 같은 host. compute 2대 up + hint group 확인 필요"
fi
echo "==================================================================="

echo
echo "[참고] 상세:"
openstack server list --name 'db0' -c Name -c Status -c Networks -c Host --long || \
  openstack server list
openstack server group show "$GROUP_NAME"
