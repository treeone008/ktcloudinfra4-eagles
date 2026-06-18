#!/bin/bash

echo "========================================="
echo "Starting Infrastructure Cleanup Pipeline..."
echo "========================================="

# 1. 가상머신(VM) 인스턴스 일괄 강제 삭제
echo "1. Deleting VM Instances..."
openstack server delete master swarm-mg swarm-worker monitor db01 db02 2>/dev/null

# VM이 완전히 삭제될 때까지 잠시 대기 (안전장치)
echo "Waiting for VM termination..."
sleep 10

# 2. 할당되지 않은 Floating IP들 청소
echo "2. Cleaning up unused Floating IPs..."
for ip in $(openstack floating ip list -f value -c ID); do
    openstack floating ip delete $ip 2>/dev/null
done

# 3. 라우터 인터페이스 및 게이트웨이 전면 분리 후 삭제
echo "3. Removing Router connections and Router..."
# 라우터에 물려있는 두 서브넷 연결 해제
openstack router remove subnet multi-router public-subnet 2>/dev/null
openstack router remove subnet multi-router private-subnet 2>/dev/null

# 라우터 외부 게이트웨이 해제 및 라우터 최종 삭제
openstack router unset --external-gateway multi-router 2>/dev/null
openstack router delete multi-router 2>/dev/null

# 4. 서브넷 및 네트워크 삭제
echo "4. Deleting Subnets and Internal Network..."
openstack subnet delete public-subnet 2>/dev/null
openstack subnet delete private-subnet 2>/dev/null
openstack network delete internal-net 2>/dev/null

# 5. 보안 그룹 및 Flavor 삭제
echo "5. Deleting Security Groups and Flavors..."
openstack security group delete project-sg 2>/dev/null

openstack flavor delete m1.master 2>/dev/null
openstack flavor delete m1.swarm-mg 2>/dev/null
openstack flavor delete m1.swarm-worker 2>/dev/null
openstack flavor delete m1.monitor 2>/dev/null
openstack flavor delete m1.db 2>/dev/null

# 6. 로컬 인증키 파일 초기화
echo "6. Cleaning up local Keypair file..."
openstack keypair delete my-key 2>/dev/null
if [ -f "./my-key.pem" ]; then
    rm -f ./my-key.pem
fi

echo "========================================="
echo "Infrastructure cleanup completed successfully!"
echo "Your OpenStack environment is now a clean slate."
echo "========================================="