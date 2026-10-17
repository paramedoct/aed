# aed
긴급 재설정 명령어 모음

레시피 값은 기존 [aed.conf](aed.conf) 한 파일에서 관리한다. `nmcli connection show` 명령으로 연결의 UUID 값을 확인하고 `CONNECTION_UUID` 항목에 입력한 다음 `./network` 명령을 실행한다. 활성 연결은 설정 후 다시 연결되므로 접속이 잠시 끊길 수 있다.

- `DHCP=on`: `ADDRESS`, `SUBNET_MASK`, `GATEWAY`는 비워 둔다.
- `DHCP=off`: `ADDRESS` 및 `SUBNET_MASK` 항목을 입력한다. 기본 경로가 없으면 `GATEWAY=none` 값을 사용한다.
- `DNS=auto`: DHCP 서버의 DNS 설정을 사용한다. `DHCP=on` 설정에서만 사용할 수 있다.
- `DNS=1.1.1.1,8.8.8.8`: 지정한 IPv4 DNS 서버를 사용한다. 서버가 필요 없으면 `DNS=none` 값을 사용한다.

현재 상태 확인 명령은 `./status`이다. `./run` 명령은 수동 IPv4 설정과 DNS 설정을 자동 설정으로 복구한다.
