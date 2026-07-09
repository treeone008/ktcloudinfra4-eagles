#!/usr/bin/env bash
# web1~web3 (192.168.1.20~22) CPU stress — Scale Up 테스트용
# mgmt(172.16.8.200) 또는 openstack(172.16.8.100)에서 실행
#
# Usage:
#   ./stress-web-cpu.sh start [cores_per_host]
#   ./stress-web-cpu.sh stop
#   ./stress-web-cpu.sh status
#
# 환경변수:
#   SSH_KEY=~/ansible-swarm/openstack2.pem
#   WEB_IPS="192.168.1.20 192.168.1.21 192.168.1.22"
#   JUMP_HOST / QROUTER_NS  (mgmt→tenant net 경유 시)

set -uo pipefail

SSH_USER="${SSH_USER:-ubuntu}"
SSH_KEY="${SSH_KEY:-}"
WEB_IPS="${WEB_IPS:-192.168.1.20 192.168.1.21 192.168.1.22}"
JUMP_HOST="${JUMP_HOST:-}"
QROUTER_NS="${QROUTER_NS:-}"
SSH_TIMEOUT="${SSH_TIMEOUT:-30}"
CORES="${2:-2}"

ssh_opts=(
  -o StrictHostKeyChecking=no
  -o ConnectTimeout=10
  -o BatchMode=yes
  -o LogLevel=ERROR
  -o ServerAliveInterval=5
  -o ServerAliveCountMax=2
)
[[ -n "$SSH_KEY" && -f "$SSH_KEY" ]] && ssh_opts+=(-i "$SSH_KEY")

read -r -d '' REMOTE_START <<'EOF' || true
N="$1"
PIDFILE=/tmp/web-stress-cpu.pids
rm -f "$PIDFILE"
if command -v stress-cpu.sh >/dev/null 2>&1; then
  if sudo -n stress-cpu.sh start "$N" 2>/dev/null; then
    echo "started ${N} core(s) via stress-cpu.sh on $(hostname)"
    exit 0
  fi
fi
for ((i=0; i<N; i++)); do
  nohup yes >/dev/null 2>&1 </dev/null &
  echo $! >> "$PIDFILE"
  disown 2>/dev/null || true
done
echo "started ${N} loop(s) on $(hostname)"
exit 0
EOF

read -r -d '' REMOTE_STOP <<'EOF' || true
PIDFILE=/tmp/web-stress-cpu.pids
if command -v stress-cpu.sh >/dev/null 2>&1; then
  sudo -n stress-cpu.sh stop 2>/dev/null || true
fi
if [[ -f "$PIDFILE" ]]; then
  while read -r p; do kill "$p" 2>/dev/null || true; done < "$PIDFILE"
  rm -f "$PIDFILE"
fi
pkill -f '^yes$' 2>/dev/null || true
echo "stopped on $(hostname)"
exit 0
EOF

read -r -d '' REMOTE_STATUS <<'EOF' || true
echo "host: $(hostname)"
count=$(pgrep -c '^yes$' 2>/dev/null || echo 0)
echo "yes_procs: ${count:-0}"
exit 0
EOF

build_proxy() {
  local target_ip="$1"
  if [[ -n "$JUMP_HOST" && -n "$QROUTER_NS" ]]; then
    echo "ssh -o StrictHostKeyChecking=no root@${JUMP_HOST} ip netns exec ${QROUTER_NS} /bin/nc ${target_ip} 22"
  elif [[ -n "$JUMP_HOST" ]]; then
    echo "ssh -o StrictHostKeyChecking=no root@${JUMP_HOST} /bin/nc ${target_ip} 22"
  fi
}

run_ssh_script() {
  local ip="$1" n="${2:-}" script="${3:-}" proxy
  proxy="$(build_proxy "$ip")"

  local ssh_cmd=(ssh "${ssh_opts[@]}")
  [[ -n "$proxy" ]] && ssh_cmd+=(-o "ProxyCommand=${proxy}")
  ssh_cmd+=("${SSH_USER}@${ip}" bash -s)
  [[ -n "$n" ]] && ssh_cmd+=(-- "$n")

  if command -v timeout >/dev/null 2>&1; then
    printf '%s\n' "$script" | timeout "$SSH_TIMEOUT" "${ssh_cmd[@]}"
  else
    printf '%s\n' "$script" | "${ssh_cmd[@]}"
  fi
}

stress_start_remote() {
  local ip="$1" n="$2"
  echo ">>> ${ip} start (${n} core(s))..."
  if run_ssh_script "$ip" "$n" "$REMOTE_START"; then
    echo ">>> ${ip} OK"
    return 0
  fi
  echo ">>> ${ip} FAILED"
  return 1
}

stress_stop_remote() {
  local ip="$1"
  echo ">>> ${ip} stop..."
  if run_ssh_script "$ip" "" "$REMOTE_STOP"; then
    echo ">>> ${ip} OK"
    return 0
  fi
  echo ">>> ${ip} FAILED"
  return 1
}

stress_status_remote() {
  local ip="$1"
  echo "=== ${ip} ==="
  run_ssh_script "$ip" "" "$REMOTE_STATUS" || echo "(unreachable)"
}

run_parallel() {
  local fn="$1"
  shift
  local pids=() ip
  for ip in $WEB_IPS; do
    ( "$fn" "$ip" "$@" ) &
    pids+=($!)
  done
  local fail=0 pid
  for pid in "${pids[@]}"; do
    wait "$pid" || fail=1
  done
  return "$fail"
}

cmd="${1:-}"
case "$cmd" in
  start)
    echo "CPU stress start: ${CORES} core(s) per host on: ${WEB_IPS}"
    run_parallel stress_start_remote "$CORES" || true
    ;;
  stop)
    echo "CPU stress stop on: ${WEB_IPS}"
    run_parallel stress_stop_remote || true
    ;;
  status)
    for ip in $WEB_IPS; do
      stress_status_remote "$ip"
    done
    ;;
  *)
    echo "Usage: $0 start [cores_per_host]|stop|status"
    echo ""
    echo "Example:"
    echo "  export SSH_KEY=~/ansible-swarm/openstack2.pem"
    echo "  ./stress-web-cpu.sh start 2"
    exit 1
    ;;
esac

echo "done."
