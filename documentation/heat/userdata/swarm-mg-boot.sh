#!/bin/sh
# cirros 부팅 시 node_exporter + CPU stress 도구 설치
# Heat user_data (RAW)
#
# VM에 인터넷 없으면 monitor에서 미리 띄운 HTTP mirror 사용:
#   NE_MIRROR=http://172.16.8.110:8888/node_exporter.tar.gz

LOG=/var/log/swarm-mg-boot.log
exec >>"$LOG" 2>&1
echo "=== boot $(date) ==="

NE_VER=1.8.2
ARCH=linux-amd64
BIN=/home/cirros/bin/node_exporter
NE_MIRROR="${NE_MIRROR:-http://172.16.8.110:8888/node_exporter.tar.gz}"
GITHUB_URL="https://github.com/prometheus/node_exporter/releases/download/v${NE_VER}/node_exporter-${NE_VER}.${ARCH}.tar.gz"

mkdir -p /home/cirros/bin

install_exporter() {
  cd /tmp || exit 1
  rm -f ne.tar.gz
  if wget -q -T 15 -O ne.tar.gz "$NE_MIRROR"; then
    echo "downloaded from mirror: $NE_MIRROR"
  elif wget -q -T 30 -O ne.tar.gz "$GITHUB_URL"; then
    echo "downloaded from github"
  else
    echo "ERROR: node_exporter download failed (no mirror/github)"
    return 1
  fi
  tar xzf ne.tar.gz || return 1
  cp "node_exporter-${NE_VER}.${ARCH}/node_exporter" "$BIN" || return 1
  chmod +x "$BIN"
  rm -rf ne.tar.gz "node_exporter-${NE_VER}.${ARCH}"
}

if [ ! -x "$BIN" ]; then
  install_exporter || echo "install_exporter failed — see log"
fi

if [ -x "$BIN" ] && ! pgrep -f '[n]ode_exporter' >/dev/null 2>&1; then
  "$BIN" --web.listen-address=0.0.0.0:9100 >>/var/log/node_exporter.log 2>&1 &
  sleep 1
  pgrep -fa node_exporter || echo "node_exporter failed to start"
fi

cat >/home/cirros/stress-cpu.sh <<'STRESS'
#!/bin/sh
PIDFILE=/tmp/stress-cpu.pids
case "$1" in
  start)
    N="${2:-1}"
    i=0
    while [ "$i" -lt "$N" ]; do
      ( while true; do :; done ) &
      echo $! >> "$PIDFILE"
      i=$((i + 1))
    done
    echo "CPU stress started: ${N} loop(s)"
    ;;
  stop)
    if [ -f "$PIDFILE" ]; then
      while read -r p; do kill "$p" 2>/dev/null; done < "$PIDFILE"
      rm -f "$PIDFILE"
    fi
    echo "CPU stress stopped"
    ;;
  status)
    if [ -f "$PIDFILE" ]; then wc -l < "$PIDFILE"; else echo 0; fi
    ;;
  *)
    echo "usage: $0 start [N] | stop | status"
    exit 1
    ;;
esac
STRESS
chmod +x /home/cirros/stress-cpu.sh

echo "=== done $(date) ==="
