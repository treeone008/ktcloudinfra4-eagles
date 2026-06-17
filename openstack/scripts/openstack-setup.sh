#!/usr/bin/env bash
set -euo pipefail

PUBLIC_NET="project-public-net"
PUBLIC_SUBNET="project-public-subnet"
PRIVATE_NET="project-private-net"
PRIVATE_SUBNET="project-private-subnet"
ROUTER="project-router"
EXTERNAL_NET="sharednet1"
SECURITY_GROUP="project-sg"

openstack network show "$PUBLIC_NET" >/dev/null 2>&1 || openstack network create "$PUBLIC_NET"
openstack network show "$PRIVATE_NET" >/dev/null 2>&1 || openstack network create "$PRIVATE_NET"

openstack subnet show "$PUBLIC_SUBNET" >/dev/null 2>&1 || \
  openstack subnet create "$PUBLIC_SUBNET" \
    --network "$PUBLIC_NET" \
    --subnet-range 192.168.100.0/24 \
    --gateway 192.168.100.1 \
    --dns-nameserver 8.8.8.8

openstack subnet show "$PRIVATE_SUBNET" >/dev/null 2>&1 || \
  openstack subnet create "$PRIVATE_SUBNET" \
    --network "$PRIVATE_NET" \
    --subnet-range 192.168.101.0/24 \
    --gateway 192.168.101.1 \
    --dns-nameserver 8.8.8.8

openstack router show "$ROUTER" >/dev/null 2>&1 || openstack router create "$ROUTER"
openstack router set "$ROUTER" --external-gateway "$EXTERNAL_NET"
openstack router add subnet "$ROUTER" "$PUBLIC_SUBNET" 2>/dev/null || true
openstack router add subnet "$ROUTER" "$PRIVATE_SUBNET" 2>/dev/null || true

openstack security group show "$SECURITY_GROUP" >/dev/null 2>&1 || \
  openstack security group create "$SECURITY_GROUP" --description "security group for project nodes"

add_rule() {
  local proto="$1"
  local port="${2:-}"
  if [[ "$proto" == "icmp" ]]; then
    openstack security group rule create --proto icmp "$SECURITY_GROUP" 2>/dev/null || true
  else
    openstack security group rule create --proto "$proto" --dst-port "$port" "$SECURITY_GROUP" 2>/dev/null || true
  fi
}

add_rule icmp
add_rule tcp 22
add_rule tcp 80
add_rule tcp 443
add_rule tcp 2377
add_rule tcp 7946
add_rule udp 7946
add_rule udp 4789
add_rule tcp 3000
add_rule tcp 9090
add_rule tcp 9100
add_rule tcp 8080
add_rule tcp 3306

echo "OpenStack network and security group setup completed."
