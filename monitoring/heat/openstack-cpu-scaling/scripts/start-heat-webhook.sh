#!/usr/bin/env bash
# Heat webhook 백그라운드 실행 (nohup)
# openstack(100) 또는 mgmt(200) — mgmt는 venv + admin-service-openrc 권장
#
# Usage:
#   ./start-heat-webhook.sh start
#   ./start-heat-webhook.sh stop|status|restart
#
# 환경변수 (선택):
#   OPENRC=~/admin-service-openrc.sh
#   VENV_DIR=~/venv                       # mgmt: openstack CLI venv
#   HEAT_STACK=swarm-scale-test

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOG_DIR="${LOG_DIR:-${BASE_DIR}/logs}"
PID_FILE="${LOG_DIR}/heat-webhook.pid"
LOG_FILE="${LOG_DIR}/heat-webhook.log"
OPENRC="${OPENRC:-${HOME}/admin-service-openrc.sh}"
VENV_DIR="${VENV_DIR:-${HOME}/venv}"

export HEAT_STACK="${HEAT_STACK:-swarm-scale-test}"
export HEAT_SCALE_MODE="${HEAT_SCALE_MODE:-parameter}"
export HEAT_WORKER_MIN="${HEAT_WORKER_MIN:-0}"
export HEAT_WORKER_MAX="${HEAT_WORKER_MAX:-3}"
export HEAT_COOLDOWN="${HEAT_COOLDOWN:-180}"

mkdir -p "$LOG_DIR"

setup_openstack_cli() {
  if [[ -x "${VENV_DIR}/bin/openstack" ]]; then
    export PATH="${VENV_DIR}/bin:${PATH}"
    export OPENSTACK_BIN="${VENV_DIR}/bin/openstack"
    if [[ -x "${VENV_DIR}/bin/python3" ]]; then
      PYTHON_BIN="${VENV_DIR}/bin/python3"
    else
      PYTHON_BIN="python3"
    fi
    echo "using venv openstack: ${OPENSTACK_BIN}"
  elif command -v openstack >/dev/null 2>&1; then
    export OPENSTACK_BIN="$(command -v openstack)"
    PYTHON_BIN="python3"
    echo "using system openstack: ${OPENSTACK_BIN}"
  else
    echo "ERROR: openstack CLI not found. Set VENV_DIR or install python-openstackclient."
    exit 1
  fi
}

is_running() {
  [[ -f "$PID_FILE" ]] || return 1
  local pid
  pid="$(cat "$PID_FILE")"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

start_webhook() {
  if is_running; then
    echo "already running (pid $(cat "$PID_FILE"))"
    exit 0
  fi

  if [[ ! -f "$OPENRC" ]]; then
    echo "ERROR: openrc not found: $OPENRC"
    exit 1
  fi

  if [[ ! -f "${BASE_DIR}/heat-webhook.py" ]]; then
    echo "ERROR: heat-webhook.py not found in ${BASE_DIR}"
    exit 1
  fi

  setup_openstack_cli

  # shellcheck disable=SC1090
  source "$OPENRC"
  unset OS_CLOUD

  if ! "${OPENSTACK_BIN}" stack show "${HEAT_STACK}" -f json >/dev/null 2>&1; then
    echo "ERROR: cannot read stack '${HEAT_STACK}' — check openrc / Keystone / Heat CLI"
    "${OPENSTACK_BIN}" stack show "${HEAT_STACK}" 2>&1 | tail -5
    exit 1
  fi

  cd "$BASE_DIR"
  nohup "${PYTHON_BIN}" heat-webhook.py >>"$LOG_FILE" 2>&1 &
  echo $! >"$PID_FILE"

  sleep 1
  if is_running; then
    echo "started pid $(cat "$PID_FILE")"
    echo "log: $LOG_FILE"
    curl -sf http://127.0.0.1:8080/health && echo " health OK" || echo " WARN: health check failed (wait a few sec)"
  else
    echo "ERROR: failed to start — see $LOG_FILE"
    rm -f "$PID_FILE"
    exit 1
  fi
}

stop_webhook() {
  if ! is_running; then
    echo "not running"
    rm -f "$PID_FILE"
    exit 0
  fi
  local pid
  pid="$(cat "$PID_FILE")"
  kill "$pid" 2>/dev/null || true
  sleep 1
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null || true
  fi
  rm -f "$PID_FILE"
  echo "stopped"
}

status_webhook() {
  if is_running; then
    echo "running pid $(cat "$PID_FILE")"
    curl -sf http://127.0.0.1:8080/health && echo "health: ok" || echo "health: FAIL"
    tail -n 8 "$LOG_FILE" 2>/dev/null || true
  else
    echo "not running"
    [[ -f "$LOG_FILE" ]] && tail -n 8 "$LOG_FILE" || true
  fi
}

cmd="${1:-start}"
case "$cmd" in
  start) start_webhook ;;
  stop) stop_webhook ;;
  status) status_webhook ;;
  restart) stop_webhook; start_webhook ;;
  *)
    echo "Usage: $0 {start|stop|status|restart}"
    exit 1
    ;;
esac
