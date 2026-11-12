# Homebrew 버전 사용 불가

- 앱 서명이 ad-hoc로 되어있어서 macOS 보안 권한 유지가 되지 않는다.
- Github release의 바이너리를 직접 다운로드하고, 애플 개발자 인증서로 서명해서 사용한다.
  - `computing-setup`으로 설치와 업데이트 가능 여부를 확인한다.

# Web Admin

<http://localhost:8040>

# `dags/*.yml` 설정 경로

`~/.config/dagu/dags`

# `fish` shell 연결

- `~/.config/dagu/base.yaml`에 `shell: fish`를 설정.
- `run:`에는 Fish 문법으로 작성. `config.fish`, `conf.d/*.fish`와 자동 로드 함수가 적용된다.

# Gmail 발송 설정

- 구글 계정에서 2단계 인증을 켜고 [앱 비밀번호](https://myaccount.google.com/apppasswords)를 발급한다.
- `Notifications → Channels → Email Delivery`에서 설정.
  - Authentication: `Password`
  - Host: `smtp.gmail.com`, Port: `587`
  - Username / Default sender: Gmail 주소
  - Password: 발급받은 16자리 앱 비밀번호
- `Notifications → Channels → Add channel`에서 채널 생성.
- `Notifications → Rules → Add rule`에서 룰 생성.
