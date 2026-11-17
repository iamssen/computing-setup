# 적합한 환경 

CodexBar에서 보내는 알림이기 때문에 맥북같이 잠자기 상태가 될 수 있는 기기는 알림을 놓칠 가능성이 생긴다.

- 맥미니 서버에 CodexBar 설치 (CodexBar → )
- Claude의 경우 사용량 소스를 `CLI(PTY)`로 변경
- Hook 설정에서 `computing-setup/codexbar-hook.sh` 파일 연결
  - 이벤트는 `quota_reached`, `quota_reset`, `quota_low` 세 개를 연결한다
  - `quota_low`는 알림을 보내지 않고, 이후 `quota_reset` 알림을 보낼지 정하는 데만 쓴다