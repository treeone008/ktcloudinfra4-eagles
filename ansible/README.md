## 🚀 시연 및 배포 방법 (발표자 가이드)

본 프로젝트는 안전한 암호 관리를 위해 Ansible Vault를 사용합니다. 발표 전, 시연 PC에 비밀번호 파일을 먼저 생성해야 정상적으로 작동합니다.

### 1. 시연 사전 작업 (비밀번호 파일 생성)
터미널을 열고 홈 디렉터리에 `.ansible_vault_pass` 파일을 생성하고 비밀번호(`test123`)를 입력합니다.
```bash
echo "test123" > ~/.ansible_vault_pass
```
* **참고**: `ansible.cfg` 파일에 `vault_password_file = ~/.ansible_vault_pass` 설정이 이미 반영되어 있으므로, 파일만 생성해 두면 플레이북 실행 시 비밀번호를 묻지 않고 자동으로 인식합니다.

### 2. 관리 대상 서버 연결 상태 확인 (Ping 테스트)
모든 대상 노드와 SSH 연결 및 Ansible 통신이 정상적인지 확인합니다.
```bash
ansible all -m ping -i hosts.ini
```
> **예상 결과**: 모든 서버 항목이 초록색으로 `SUCCESS`가 떠야 합니다.

### 3. 전체 인프라 자동 구축 (Playbook 실행)
사전 작업이 완료되었다면 추가 옵션 없이 아래 명령어로 전체 자동화를 한 번에 실행합니다.
```bash
ansible-playbook -i hosts.ini site.yml
```
> **장점**: 비밀번호 파일 덕분에 `--ask-vault-pass` 옵션을 붙이거나 타이핑할 필요 없이 **원클릭 시연**이 가능합니다.

