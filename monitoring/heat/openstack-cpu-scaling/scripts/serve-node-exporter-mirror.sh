#!/bin/bash
# monitor VM에서 실행 — cirros가 wget으로 받을 node_exporter tarball 제공
set -e
NE_VER=1.8.2
ARCH=linux-amd64
DIR=/tmp/node_exporter_mirror
mkdir -p "$DIR"
cd "$DIR"

if [ ! -f node_exporter.tar.gz ]; then
  curl -fsSL -o ne.tar.gz \
    "https://github.com/prometheus/node_exporter/releases/download/v${NE_VER}/node_exporter-${NE_VER}.${ARCH}.tar.gz"
  cp ne.tar.gz node_exporter.tar.gz
fi

echo "Serving http://0.0.0.0:8888/node_exporter.tar.gz"
echo "Test: curl -I http://127.0.0.1:8888/node_exporter.tar.gz"
cd "$DIR"
python3 -m http.server 8888 --bind 0.0.0.0
