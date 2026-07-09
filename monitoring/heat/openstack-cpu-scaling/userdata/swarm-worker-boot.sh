#!/bin/sh
LOG=/var/log/swarm-worker-boot.log
exec >>"$LOG" 2>&1
echo "=== worker boot $(date) ==="

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
    echo "ERROR: node_exporter download failed"
    return 1
  fi
  tar xzf ne.tar.gz || return 1
  cp "node_exporter-${NE_VER}.${ARCH}/node_exporter" "$BIN" || return 1
  chmod +x "$BIN"
  rm -rf ne.tar.gz "node_exporter-${NE_VER}.${ARCH}"
}

if [ ! -x "$BIN" ]; then
  install_exporter || echo "install_exporter failed"
fi

if [ -x "$BIN" ] && ! pgrep -f '[n]ode_exporter' >/dev/null 2>&1; then
  "$BIN" --web.listen-address=0.0.0.0:9100 >>/var/log/node_exporter.log 2>&1 &
fi

echo "=== worker done $(date) ==="
