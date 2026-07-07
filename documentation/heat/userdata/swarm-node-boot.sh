#!/bin/sh
# Heat str_replace 로 __NODE_IP__ __NODE_GW__ 치환
# 부팅 직후 네트워크 고정 → mirror wget 가능

NODE_IP="__NODE_IP__"
NODE_GW="__NODE_GW__"
IFACE=eth0

LOG=/var/log/swarm-node-boot.log
exec >>"$LOG" 2>&1
echo "=== boot $(date) ip=${NODE_IP} gw=${NODE_GW} ==="

fix_network() {
  ifconfig "$IFACE" down 2>/dev/null
  ifconfig "$IFACE" "$NODE_IP" netmask 255.255.255.0 broadcast 192.168.100.255 up
  route del default 2>/dev/null
  route add default gw "$NODE_GW" dev "$IFACE" 2>/dev/null
  echo "ifconfig:"; ifconfig "$IFACE"
  echo "route:"; route -n
}

# cirros DHCP/meta 실패(169.254) 대비 — wget 전에 반드시
fix_network

NE_VER=1.8.2
ARCH=linux-amd64
BIN=/home/cirros/bin/node_exporter
NE_MIRROR="${NE_MIRROR:-http://172.16.8.110:8888/node_exporter.tar.gz}"
GITHUB_URL="https://github.com/prometheus/node_exporter/releases/download/v${NE_VER}/node_exporter-${NE_VER}.${ARCH}.tar.gz"

mkdir -p /home/cirros/bin

install_exporter() {
  cd /tmp || return 1
  rm -f ne.tar.gz
  if wget -q -T 15 -O ne.tar.gz "$NE_MIRROR"; then
    echo "downloaded from mirror"
  elif wget -q -T 30 -O ne.tar.gz "$GITHUB_URL"; then
    echo "downloaded from github"
  else
    echo "ERROR: download failed"
    return 1
  fi
  tar xzf ne.tar.gz || return 1
  cp "node_exporter-${NE_VER}.${ARCH}/node_exporter" "$BIN"
  chmod +x "$BIN"
  rm -rf ne.tar.gz "node_exporter-${NE_VER}.${ARCH}"
}

if [ ! -x "$BIN" ]; then
  install_exporter || echo "install failed"
fi

if [ -x "$BIN" ] && ! pgrep -f '[n]ode_exporter' >/dev/null 2>&1; then
  "$BIN" --web.listen-address=0.0.0.0:9100 >>/var/log/node_exporter.log 2>&1 &
fi

# mg 전용 stress (worker는 사용 안 해도 무방)
if [ "$NODE_IP" = "192.168.100.20" ]; then
  cat >/home/cirros/stress-cpu.sh <<'STRESS'
#!/bin/sh
PIDFILE=/tmp/stress-cpu.pids
case "$1" in
  start)
    N="${2:-1}"; i=0
    while [ "$i" -lt "$N" ]; do
      ( while true; do :; done ) &
      echo $! >> "$PIDFILE"
      i=$((i + 1))
    done
    echo "CPU stress started: ${N}"
    ;;
  stop)
    [ -f "$PIDFILE" ] && while read -r p; do kill "$p" 2>/dev/null; done < "$PIDFILE"
    rm -f "$PIDFILE"
    echo "stopped"
    ;;
  *) echo "usage: $0 start [N]|stop"; exit 1 ;;
esac
STRESS
  chmod +x /home/cirros/stress-cpu.sh
fi

fix_network
echo "=== done $(date) ==="
