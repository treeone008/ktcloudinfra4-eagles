#!/bin/bash

# 1. 초경량 가상 하드웨어 사양(Flavor) 생성
echo "Creating Lightweight Flavors..."
openstack flavor create --id 101 --ram 2048 --disk 15 --vcpus 1 m1.master
#openstack flavor create --id 102 --ram 2048 --disk 15 --vcpus 1 m1.swarm-mg
openstack flavor create --id 103 --ram 1024 --disk 10 --vcpus 1 m1.swarm-worker
#openstack flavor create --id 104 --ram 1024 --disk 10 --vcpus 1 m1.monitor
#openstack flavor create --id 105 --ram 1024 --disk 10 --vcpus 1 m1.db

# 2. 투-트랙 네트워크 및 서브넷 구성 (100번 대역 & 101번 대역)
echo "Creating Networks and Subnets..."
openstack network create internal-net

# 192.168.100.0/24 대역 생성
openstack subnet create --network internal-net --subnet-range 192.168.100.0/24 \
  --dns-nameserver 8.8.8.8 public-subnet

# 192.168.101.0/24 대역 생성
openstack subnet create --network internal-net --subnet-range 192.168.101.0/24 \
  --dns-nameserver 8.8.8.8 private-subnet

# 3. 라우터 생성 및 두 서브넷 통합 연결 (라우팅 허용)
echo "Creating Router and Connecting Subnets..."
openstack router create multi-router
openstack router add subnet multi-router public-subnet
openstack router add subnet multi-router private-subnet
openstack router set --external-gateway sharednet1 multi-router

# 4. SSH 키페어 자동 생성
echo "Handling SSH Keypair..."
if [ ! -f "./my-key.pem" ]; then
    openstack keypair create my-key > my-key.pem
    chmod 600 my-key.pem
fi

# 5. 보안 그룹 설정 (두 사설 대역 전체 오픈)
echo "Creating Security Group..."
openstack security group create project-sg
openstack security group rule create --protocol tcp --dst-port 22 project-sg
openstack security group rule create --protocol tcp --dst-port 80 project-sg
openstack security group rule create --protocol icmp project-sg
openstack security group rule create --protocol tcp --remote-ip 192.168.0.0/16 project-sg
openstack security group rule create --protocol udp --remote-ip 192.168.0.0/16 project-sg
openstack security group rule create --protocol icmp --remote-ip 192.168.0.0/16 project-sg

# 6. VM 인스턴스 순차적 생성 (새 확정 IP 규칙 반영)
IMAGE_NAME="ubuntu"
NET_ID=$(openstack network show internal-net -f value -c id)

echo "Launching VM Instances..."

# [100번 대역 배치 노드들]
# master (기존 앤시블 관리 기능을 겸함)
openstack server create --flavor m1.master --image $IMAGE_NAME --nic net-id=$NET_ID,v4-fixed-ip=192.168.100.10 --key-name my-key --security-group project-sg --user-data mgmt_init.txt master

#openstack server create --flavor m1.swarm-mg --image $IMAGE_NAME --nic net-id=$NET_ID,v4-fixed-ip=192.168.100.20 --key-name my-key --security-group project-sg swarm-mg
openstack server create --flavor m1.swarm-worker --image $IMAGE_NAME --nic net-id=$NET_ID,v4-fixed-ip=192.168.100.21 --key-name my-key --security-group project-sg swarm-worker
#openstack server create --flavor m1.monitor --image $IMAGE_NAME --nic net-id=$NET_ID,v4-fixed-ip=192.168.100.40 --key-name my-key --security-group project-sg monitor

# [101번 대역 배치 노드들]
#openstack server create --flavor m1.db --image $IMAGE_NAME --nic net-id=$NET_ID,v4-fixed-ip=192.168.101.31 --key-name my-key --security-group project-sg db01
#openstack server create --flavor m1.db --image $IMAGE_NAME --nic net-id=$NET_ID,v4-fixed-ip=192.168.101.32 --key-name my-key --security-group project-sg db02

# 7. 외부 접속을 위한 Floating IP 생성 및 master 서버 연결
echo "Allocating Floating IP to Master node..."
FLOATING_IP=$(openstack floating ip create sharednet1 -f value -c floating_ip_address)
openstack server add floating ip master $FLOATING_IP

# =============================================================
# 인증용 마스터 개인키를 master 노드로 원격 배달
# =============================================================
echo "Waiting for Master node SSH to wake up..."
sleep 120 

echo "Injecting Private Key into Master node..."
scp -o StrictHostKeyChecking=no -i my-key.pem my-key.pem ubuntu@$FLOATING_IP:/home/ubuntu/.ssh/id_rsa
ssh -o StrictHostKeyChecking=no -i my-key.pem ubuntu@$FLOATING_IP "chmod 600 /home/ubuntu/.ssh/id_rsa"

echo "========================================="
echo "Infrastructure deployment completed successfully!"
echo "Connect to Master Node: ssh -i my-key.pem ubuntu@$FLOATING_IP"
echo "========================================="
