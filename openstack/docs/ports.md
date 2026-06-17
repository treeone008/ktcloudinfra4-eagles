# 포트 정책

## 기본 포트

| 포트 | 프로토콜 | 용도 |
|---|---|---|
| 22 | TCP | SSH / Ansible |
| 80 | TCP | Web HTTP |
| 443 | TCP | Web HTTPS |
| 2377 | TCP | Docker Swarm Manager |
| 7946 | TCP/UDP | Docker Swarm 노드 통신 |
| 4789 | UDP | Docker Overlay Network |
| 3000 | TCP | Grafana |
| 9090 | TCP | Prometheus |
| 9100 | TCP | Node Exporter |
| 8080 | TCP | cAdvisor |
| 3306 | TCP | MariaDB |

## Security Group

Security Group 이름: `project-sg`

허용 항목:

- ICMP
- SSH 22
- Web 80/443
- Docker Swarm 2377, 7946, 4789
- Monitoring 3000, 9090, 9100, 8080
- DB 3306

운영 환경에서는 역할별 Security Group 분리가 필요하지만, 현재 프로토타입에서는 `project-sg` 하나로 관리한다.
