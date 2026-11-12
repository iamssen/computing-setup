# computing-setup

맥북과 맥미니 서버의 세팅 문서, 그리고 그 세팅을 점검·설치하는 fish 명령 모음.

## 설치

fish 셸에서 처음 한 번만 실행한다.

```fish
source functions.fish
```

명령들이 바로 등록되고, fish의 `conf.d`에 링크가 만들어져 이후의 셸에서는 자동으로 등록된다.
`jq`가 필요하다(`brew install jq`).

## 명령

| 명령 | 하는 일 |
| --- | --- |
| `computing-setup` | 설치·업데이트 상태를 점검하고 실행할 명령을 안내한다. 아무것도 변경하지 않는다 |
| `check-node-update` | Node.js 업데이트를 확인한다 |
| `install-node <release-directory>` | Node.js 공식 pkg를 설치한다 (예: `latest`, `latest-v26.x`, `v26.3.0`) |
| `check-dagu-update` | Dagu 업데이트를 확인한다 |
| `setup-dagu <host> <port>` | Dagu를 처음 설치하고 서비스로 등록한다 |
| `update-dagu` | Dagu를 업데이트하고 서비스를 다시 시작한다 |
| `pushover <channel> "message"` | 아이폰으로 알림을 보낸다 |
| `validate-signing-identity <identity>` | 코드 서명 인증서가 유효한지 확인한다 |

## 환경 변수

| 변수 | 쓰는 명령 |
| --- | --- |
| `SIGNING_IDENTITY` | `setup-dagu`, `update-dagu`. 서명 인증서의 SHA-1 지문 |
| `PUSHOVER_USER` | `pushover` |
| `PUSHOVER_CHANNEL_<대문자 채널>` | `pushover <채널>`. 채널별 앱 토큰 |

## CodexBar hook

[codexbar-hook.sh](codexbar-hook.sh)는 CodexBar의 이벤트(`quota_low`, `quota_reached`, `quota_reset` 등)를
`pushover system "<메시지>"`로 보낸다. CodexBar의 Settings > Hooks에서 규칙을 만들고 executable에 이 파일의
절대 경로를 넣는다. arguments는 비워 두고, 제한 시간은 30초로 둔다.

세팅 순서와 배경은 [기기 세팅.md](기기%20세팅.md)와 [구현 기술 상세](구현%20기술%20상세/)에 있다.
