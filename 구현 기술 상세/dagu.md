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

# 문제 기록

<details>
<summary>SSH에서 <code>setup-dagu</code> 서명이 <code>errSecInternalComponent</code>로 실패할 때</summary>

**원인**

- 서명 인증서와 개인 키가 로그인 키체인이 아니라 시스템 키체인(`/Library/Keychains/System.keychain`)에 있었다.
- 시스템 키체인의 개인 키는 쓸 때마다 관리자 인증 창이 필요하다. 화면에서는 창이 떠서 서명되지만, SSH에서는 창을 띄울 수 없어 실패한다.
- 그래서 로그인 키체인을 대상으로 한 `security unlock-keychain`, `set-key-partition-list`는 효과가 없었다.

**확인**

```fish
security find-certificate -a -c "Apple Development" | grep keychain:
```

`System.keychain`이 나오면 이 경우다.

**해결**

1. 키체인 접근 → System → My Certificates에서 인증서를 선택하고 `File → Export Items…`로 `.p12`를 만든다.
   - 끌어다 놓기와 오른쪽 클릭 메뉴로는 옮길 수 없다.
2. 로그인 키체인으로 가져온다. `-T`로 `codesign`이 창 없이 키를 쓰게 한다.
   ```fish
   security import ~/Desktop/Certificates.p12 -k ~/Library/Keychains/login.keychain-db -T /usr/bin/codesign
   ```
3. System 키체인의 원본 인증서를 삭제한다. 같은 인증서가 두 곳에 있으면 `codesign`이 모호하다는 오류를 낼 수 있다.
4. `.p12` 파일은 안전한 곳에 보관하고 바탕화면에서 지운다.
5. SSH 세션에서는 로그인 키체인이 잠겨 있으므로, 열고 나서 설치한다.
   ```fish
   security unlock-keychain ~/Library/Keychains/login.keychain-db
   setup-dagu 0.0.0.0 8040
   ```

**주의**

- `security set-key-partition-list -s`는 키체인의 서명 가능한 개인 키 전부의 파티션 목록을 덮어쓴다. 범위를 `-l <키 이름>`으로 좁히지 않으면 다른 앱의 키에도 영향을 준다.

</details>