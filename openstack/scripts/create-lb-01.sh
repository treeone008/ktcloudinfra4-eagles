#!/bin/bash
# lb-01 생성/복구 — control(root)에서 실행
# Windows PC의 스크립트를 control에 복사하지 않아도, 아래 블록을 터미널에 붙여넣으면 됨.
set -euo pipefail

source /root/venv/bin/activate
source /etc/kolla/admin-openrc.sh

PUB_NET=$(openstack network show project-public-net -f value -c id)

echo "=== 1) bastion (swarm-mg-01 FIP) ==="
ping -c2 -W2 172.16.8.219 || true
ssh -o BatchMode=yes -o ConnectTimeout=10 -i /root/.ssh/id_rsa ubuntu@172.16.8.219 hostname || {
  echo "FIP .219 불통 — network L3 재시작 필요:"
  echo "  ssh root@172.16.8.101 'docker restart neutron_l3_agent'"
  exit 1
}

echo "=== 2) 기존 lb-01 ==="
openstack server list --name lb-01 -c Name -c Status -c Host -c Networks || true

if openstack server show lb-01 &>/dev/null; then
  STATUS=$(openstack server show lb-01 -f value -c status)
  echo "lb-01 status=$STATUS"
  openstack server show lb-01 -c status -c host -c addresses -f table
  if [[ "$STATUS" == "ERROR" ]]; then
    echo "ERROR — 전체 출력:"
    openstack server show lb-01
    openstack server delete lb-01
    sleep 15
  elif [[ "$STATUS" == "SHUTOFF" ]]; then
    openstack server start lb-01
    sleep 20
  elif [[ "$STATUS" == "ACTIVE" ]]; then
    echo "이미 ACTIVE — SSH만 재검증"
    ssh -o BatchMode=yes -o ConnectTimeout=15 \
      -i /root/.ssh/id_rsa -J ubuntu@172.16.8.219 ubuntu@192.168.100.50 "hostname" \
      && exit 0
  fi
fi

echo "=== 3) lb-01 생성 (compute-node-02, m1.micro) ==="
openstack server create --flavor m1.micro --image ubuntu \
  --nic "net-id=${PUB_NET},v4-fixed-ip=192.168.100.50" \
  --security-group project-sg --key-name project_key \
  --host compute-node-02 \
  lb-01

echo "=== 4) ACTIVE 대기 ==="
for i in $(seq 1 24); do
  STATUS=$(openstack server show lb-01 -f value -c status 2>/dev/null || echo BUILD)
  echo "  [$i] $STATUS"
  [[ "$STATUS" == "ACTIVE" ]] && break
  [[ "$STATUS" == "ERROR" ]] && { openstack server show lb-01; exit 1; }
  sleep 5
done

openstack server show lb-01 -c status -c host -c addresses -f table

echo "=== 5) tenant 망 핑 (mg-01에서) ==="
ssh -i /root/.ssh/id_rsa ubuntu@172.16.8.219 "ping -c3 192.168.100.50" || true

echo "=== 6) SSH ==="
ssh -o BatchMode=yes -o ConnectTimeout=15 \
  -i /root/.ssh/id_rsa -J ubuntu@172.16.8.219 ubuntu@192.168.100.50 \
  "hostname; grep PRETTY /etc/os-release"
