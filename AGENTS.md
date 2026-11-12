# 코드 작성 규약

`functions/`의 코드를 추가하거나 고칠 때 따른다.
사용자용 설명은 [README.md](README.md)에 있고, 명령을 추가하거나 바꾸면 그 표를 함께 고친다.
문서는 이 두 파일로 충분하다. 새 문서 파일을 만들지 않는다.

## 구조

```
functions.fish                 로더. functions/*/main.fish를 모두 읽고, 대화형 셸이면 conf.d에 자신을 연결한다
functions/
  _shared/
    main.fish                  여러 모듈이 쓰는 비공개 fish 헬퍼
    lib.sh                     모든 main.sh가 source하는 bash 공용 함수
  <모듈>/
    main.fish                  fish 명령 정의 (필수)
    main.sh                    구현 스크립트 (선택)
    tests/test_*.py            테스트
```

- 이 저장소가 설치를 관리하는 도구만 자기 모듈(`functions/<도구>/`)과 `check-<도구>-update` 명령을 갖는다.
- brew, rustup, npm처럼 상태만 보여주는 외부 도구는 `computing-setup/main.fish` 안의 비공개 함수 `_computing_setup_check_<도구>`로 둔다.
- `computing-setup`에 섹션을 추가하려면 `computing-setup` 함수의 `titles`와 `checks` 목록에 한 줄씩 더한다. 번호는 자동으로 매겨진다.

## fish와 bash의 역할

| | `main.fish` | `main.sh` |
| --- | --- | --- |
| 역할 | 사용자가 부르는 명령, 출력 꾸미기, 명령 조합 | 내려받기·검증·설치처럼 중간에 실패하면 멈추거나 되돌려야 하는 작업 |
| 인자 검증 | 하지 않는다. `$argv`를 그대로 넘긴다 | 여기서만 한다 |
| 경로 같은 상수 | 두지 않는다 | 여기에만 둔다 |

- `main.sh`는 서브커맨드로 나눈다(`main.sh check`, `main.sh install <...>`). `--check` 같은 내부용 옵션을 만들지 않는다.
- 사용자는 fish 명령만 보므로, `main.sh`의 사용법 메시지에는 fish 명령 이름을 쓴다(`Usage: install-node <release-directory>`).
- 다른 모듈의 구현이 필요하면 그 모듈의 `main.sh`를 `/bin/bash`로 실행한다. fish 함수는 bash에서 부를 수 없다.
- 작업이 짧고 되돌릴 것이 없으면 `main.sh` 없이 fish만으로 작성해도 된다(`pushover`).

### fish

- 모듈 디렉토리는 `(status dirname)`으로 얻고, 함수에는 `--inherit-variable`로 넘긴다.
- 공개 명령에는 `--description`을 붙인다.
- 비공개 함수는 `_computing_setup_` 접두사를 쓴다. 여러 모듈이 쓰면 `_shared/main.fish`에 둔다.
- 스크립트는 `/bin/bash "$script" <서브커맨드> $argv`로 실행한다.
- 출력을 `_computing_setup_format`에 파이프했다면 `return $pipestatus[1]`로 스크립트의 종료 코드를 돌려준다.

### bash

- `/bin/bash`는 macOS 기본 3.2다. `mapfile`, 연관 배열, `${var,,}`을 쓸 수 없다.
- `set -euo pipefail`로 시작하고 `_shared/lib.sh`를 source한다.
- `fail`, `usage_error`, `download`, `version_is_newer`는 `lib.sh`의 것을 쓴다. 두 스크립트가 같은 함수를 갖게 되면 `lib.sh`로 옮긴다.
- 서브커맨드는 `cmd_<이름>` 함수로 작성하고 파일 끝의 `main "$@"`에서 분기한다. 함수 밖에는 상수와 상태 변수만 둔다.
- `$(...)` 안에서는 `set -e`가 꺼진다. 그 안에서 호출되는 함수는 `|| return`으로 실패를 직접 반환한다.
- `set -e`에 기대는 함수를 `if`나 `||` 뒤에서 호출하지 않는다. 그 안에서도 `set -e`가 꺼진다.
- 시스템을 변경하는 스크립트는 변경 전에 `trap`으로 정리·복구를 예약한다.

## 종료 코드

| 코드 | 의미 |
| --- | --- |
| `0` | 성공. 점검에서는 최신 상태 |
| `1` | 실패 |
| `2` | 인자 오류 |
| `100` | 점검 결과 업데이트가 있다 (`EXIT_UPDATE_AVAILABLE`) |
| `101` | 점검 결과 설치되어 있지 않다 (`EXIT_NOT_INSTALLED`) |

`100`과 `101`은 점검 명령(`check-*`, `_computing_setup_check_*`)만 쓴다.
`computing-setup`은 `_computing_setup_check_succeeded`로 `0`, `100`, `101`을 모두 정상으로 본다.

## 점검 출력

`_computing_setup_format`이 아래 두 형식에 색을 입힌다. 문구를 바꾸면 색이 빠진다.

- `[Update v1.0.0 → v1.1.0] update-dagu`: 대괄호 안에 할 일, 그 뒤에 실행할 명령
- `Dagu - up to date: v1.1.0` 또는 `Dagu - newer than latest: v1.2.0`

## 주석과 메시지

- 주석은 한국어 평서문(`~한다`)으로 쓴다. 사용자에게 보이는 메시지는 영어로 쓴다.
- 파일 첫머리에 그 파일이 하는 일을 쓰고, `main.sh`는 서브커맨드 목록을 함께 쓴다.
- 함수 위에는 하는 일을, 본문에는 단계와 "왜 이렇게 하는지"를 쓴다. 코드를 그대로 옮긴 주석은 쓰지 않는다.
- 한 줄은 120자를 넘기지 않는다. 긴 jq 필터는 변수에 여러 줄로 담는다.

## 테스트

```fish
for dir in functions/*/tests; python3 -m unittest discover -s $dir; or break; end
```

- 코드를 고친 뒤에는 위 명령과 `fish_indent --check`, `bash -n`을 통과시킨다.
- 테스트는 네트워크와 시스템을 건드리지 않는다. `curl`, `sudo`, `launchctl` 같은 외부 명령은 `PATH` 앞에 둔 가짜 명령으로 바꾼다.
- 설치 경로는 스크립트를 고쳐 쓰지 않고 환경 변수로 바꾼다(`COMPUTING_SETUP_NODE_BIN`, `COMPUTING_SETUP_DAGU_BIN`). 이 변수들은 테스트 전용이다.
- fish 명령은 `functions.fish`를 source해서 테스트한다. 모듈의 `main.fish`만 따로 source하면 `_shared`의 헬퍼가 없어 실패한다.
- `fish -c`는 대화형이 아니라서 로더가 `conf.d`를 건드리지 않는다. 링크 동작을 테스트할 때만 `--interactive`와 임시 `XDG_CONFIG_HOME`을 함께 쓴다.
