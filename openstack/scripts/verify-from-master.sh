#!/bin/bash
# master VM 안에서 실행 — tenant VM 간 ping/SSH 검증
# 사용: bash verify-from-master.sh

set -u

PASS=0
FAIL=0

check_ping() {
  local ip=$1 name=$2
  if ping -c 1 -W 2 "$ip" &>/dev/null; then
    echo "[OK]  ping $name ($ip)"
    PASS=$((PASS + 1))
  else
    echo "[FAIL] ping $name ($ip)"
    FAIL=$((FAIL + 1))
  fi
}

check_ssh() {
  local ip=$1 name=$2
  if ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no "ubuntu@${ip}" "hostname" &>/dev/null; then
    echo "[OK]  ssh  $name ($ip)"
    PASS=$((PASS + 1))
  else
    echo "[FAIL] ssh  $name ($ip)"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== VM 간 ping ==="
check_ping 192.168.100.20 swarm-mg
check_ping 192.168.100.21 swarm-worker
check_ping 192.168.100.40 monitor
check_ping 192.168.101.31 db01
check_ping 192.168.101.32 db02

echo ""
echo "=== VM 간 SSH ==="
check_ssh 192.168.100.20 swarm-mg
check_ssh 192.168.100.21 swarm-worker
check_ssh 192.168.100.40 monitor
check_ssh 192.168.101.31 db01
check_ssh 192.168.101.32 db02

echo ""
echo "=== 결과: OK=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
