# 이 기기의 설치·업데이트 상태를 한 번에 점검하는 computing-setup 명령.
# 점검만 하고 아무것도 변경하지 않는다. 실행할 명령을 [Action] 줄로 안내한다.

# 인증서 갱신 방법을 적어 둔 문서들의 디렉토리.
set -l docs (path resolve (status dirname)/../..)/'구현 기술 상세'

# ── 출력 ─────────────────────────────────────────────────────────────

# 섹션 제목을 "[번호/전체] 제목" 형식으로 구분선과 함께 출력한다.
function _computing_setup_section --argument-names number total title
    set -l heading_color ''
    set -l line_color ''
    set -l reset ''
    if isatty stdout; and not set -q NO_COLOR
        set heading_color (set_color --bold cyan)
        set line_color (set_color brblack)
        set reset (set_color --reset)
    end

    set -l line (string repeat -n 60 '─')
    printf '\n%s%s%s\n' "$line_color" "$line" "$reset"
    printf '%s  [%s/%s] %s%s\n' "$heading_color" "$number" "$total" "$title" "$reset"
    printf '%s%s%s\n\n' "$line_color" "$line" "$reset"
end

# ── 외부 도구 점검 ───────────────────────────────────────────────────
# 이 저장소가 설치를 관리하지 않는 도구들의 상태 점검.
# 종료 코드는 check-* 명령과 같은 계약을 따른다: 0 = 최신, 100 = 업데이트 있음, 그 외 = 실패.

function _computing_setup_check_brew
    if not command -sq brew
        echo 'Homebrew is not installed.'
        return 0
    end

    # 점검 결과에 새로 추가된 formula 목록이 섞이지 않게 한다.
    set -lx HOMEBREW_NO_UPDATE_REPORT_NEW 1
    set -l updates (brew outdated --verbose)
    or return 1

    if test (count $updates) -eq 0
        echo 'Homebrew - up to date' | _computing_setup_format
        return 0
    end
    printf '%s\n' $updates
    printf '\n[Upgrade] brew upgrade\n' | _computing_setup_format
    return 100
end

function _computing_setup_check_rust
    if not command -sq rustup
        echo 'Rustup is not installed.'
        return 0
    end

    # rustup check는 업데이트가 있으면 100으로 종료한다.
    rustup check
    switch $status
        case 0
            return 0
        case 100
            printf '\n[Update] rustup update\n' | _computing_setup_format
            return 100
        case '*'
            return 1
    end
end

function _computing_setup_check_npm
    if not command -sq npm
        echo 'Install Node.js before checking global npm packages.'
        return 0
    end
    if not command -sq jq
        echo 'jq is required to read npm update results.' >&2
        return 1
    end

    # npm outdated는 업데이트가 있으면 1로 종료한다. 2 이상만 실행 실패로 본다.
    set -l response (npm outdated --global --json)
    set -l npm_status $status
    if test $npm_status -gt 1
        echo 'Failed to check global npm packages.' >&2
        return 1
    end

    # {"패키지": {current, latest}} 응답을 "패키지 현재 → 최신" 줄로 바꾼다.
    # 종료 코드 1은 오류일 때도 나오므로, 오류 응답이면 jq가 실패하게 한다.
    set -l to_lines '
        if type != "object" or has("error") then
            error("Invalid npm update response")
        else
            to_entries[] | "\(.key) \(.value.current // "missing") → \(.value.latest)"
        end'
    set -l packages (printf '%s\n' $response | jq -r $to_lines)
    or return 1

    if test (count $packages) -gt 0
        printf '%s\n' $packages
        printf '\n[Update] npm-check -gu\n' | _computing_setup_format
        return 100
    end
    # 종료 코드는 1인데 업데이트 목록이 비어 있으면 결과를 믿을 수 없다.
    if test $npm_status -ne 0
        echo 'Failed to check global npm packages.' >&2
        return 1
    end
    echo 'npm - up to date' | _computing_setup_format
end

# ── 인증서 점검 ──────────────────────────────────────────────────────
# 인증서는 만료된 뒤에야 문제가 드러나므로, 만료까지 남은 날을 미리 보여준다.

# 인자로 받은 PEM 인증서(한 줄이 한 인자)의 만료 시각을 epoch 초로 출력한다. 인증서를 읽지 못하면 실패한다.
# 명령 치환은 함수의 stdin을 물려받지 않으므로, 본문을 stdin이 아니라 인자로 받는다.
function _computing_setup_certificate_expiry
    set -l not_after (printf '%s\n' $argv | openssl x509 -noout -enddate 2>/dev/null)
    or return 1
    # 출력은 "notAfter=Jun  3 05:12:33 2027 GMT" 형식이다. 월 이름을 영어로 읽도록 로케일을 고정한다.
    env LC_ALL=C date -j -u -f '%b %d %H:%M:%S %Y %Z' (string replace 'notAfter=' '' -- "$not_after") +%s
end

# 인증서 이름과 만료 시각으로 상태 한 줄을 출력한다. 갱신할 때가 되었으면 100을 돌려준다.
function _computing_setup_certificate_status --argument-names name expiry
    set -l now (date +%s)
    set -l day (date -r $expiry '+%Y-%m-%d')
    set -l days_left (math "floor(($expiry - $now) / 86400)")

    if test $expiry -le $now
        echo "$name - expired: $day"
        return 100
    end
    # 만료 30일 전부터 갱신을 안내한다.
    if test $days_left -le 30
        echo "$name - expiring: $days_left days left ($day)"
        return 100
    end
    echo "$name - valid: $days_left days left ($day)" | _computing_setup_format
end

# 코드 서명 인증서와 mkcert 인증서가 만료되기까지 남은 날을 점검한다.
function _computing_setup_check_certificates --inherit-variable docs
    set -l failed 0
    set -l renewal_docs

    # 1. SIGNING_IDENTITY가 가리키는 코드 서명 인증서를 키체인에서 찾는다.
    if test -z "$SIGNING_IDENTITY"
        echo 'SIGNING_IDENTITY is not set.'
    else
        # security는 인증서마다 "SHA-1 hash: <지문>" 줄과 PEM 본문을 차례로 출력한다.
        # 지문이 일치하는 첫 인증서의 본문만 남긴다.
        set -l select_pem '
            /^SHA-1 hash: / { selected = ($3 == identity) }
            selected && /^-----BEGIN CERTIFICATE-----$/ { printing = 1 }
            printing { print }
            printing && /^-----END CERTIFICATE-----$/ { exit }'
        set -l pem (security find-certificate -a -Z -p \
            | awk -v identity=(string upper -- "$SIGNING_IDENTITY") $select_pem)
        set -l expiry (_computing_setup_certificate_expiry $pem)
        if test $status -eq 0
            # 인증서 이름에는 계정 정보가 들어 있으므로 이름 대신 고정된 문구로 표시한다.
            _computing_setup_certificate_status 'Signing certificate' $expiry
            or set -a renewal_docs "$docs/애플 개발자 인증서.md"
        else
            echo 'The signing certificate was not found in the keychain. Check SIGNING_IDENTITY.' >&2
            set failed 1
        end
    end

    # 2. mkcert로 만든 인증서와 rootCA.pem을 모아 둔 디렉토리를 읽는다. 변수는 테스트 전용이다.
    set -l directory ~/Certifications
    if set -q COMPUTING_SETUP_CERTIFICATES_DIR
        set directory $COMPUTING_SETUP_CERTIFICATES_DIR
    end
    set -l found 0
    for file in $directory/*.pem
        # 개인 키처럼 인증서가 아닌 PEM은 건너뛴다.
        grep -q -- '-----BEGIN CERTIFICATE-----' $file
        or continue
        set found 1

        set -l expiry (_computing_setup_certificate_expiry (cat $file))
        if test $status -eq 0
            _computing_setup_certificate_status (path basename $file) $expiry
            or contains -- "$docs/mkcert.md" $renewal_docs
            or set -a renewal_docs "$docs/mkcert.md"
        else
            echo "Failed to read the certificate: $file" >&2
            set failed 1
        end
    end
    if test $found -eq 0
        echo "No certificates found in $directory."
    end

    # 3. 갱신은 명령 하나로 끝나지 않으므로, 갱신 방법을 적어 둔 문서를 여는 명령을 안내한다.
    if test (count $renewal_docs) -gt 0
        echo
        for doc in $renewal_docs
            echo "[Renew] open "(string escape -- $doc)
        end | _computing_setup_format
    end

    test $failed -eq 0
    or return 1
    test (count $renewal_docs) -eq 0
    or return 100
end

# ── 명령 ─────────────────────────────────────────────────────────────

function computing-setup --description 'Check available system setup and update commands'
    if test (count $argv) -ne 0
        echo 'Usage: computing-setup' >&2
        return 2
    end
    set -l failed 0

    # 섹션 제목과 점검 명령을 같은 순서로 나열한다. 섹션을 추가하려면 두 목록에 한 줄씩 더한다.
    set -l titles Homebrew Node.js Dagu Rust 'Global npm packages' Certificates
    set -l checks \
        _computing_setup_check_brew \
        check-node-update \
        check-dagu-update \
        _computing_setup_check_rust \
        _computing_setup_check_npm \
        _computing_setup_check_certificates

    # 한 섹션이 실패해도 나머지 섹션은 계속 점검하고, 마지막에 실패 여부만 돌려준다.
    for index in (seq (count $checks))
        _computing_setup_section $index (count $checks) $titles[$index]
        $checks[$index]
        _computing_setup_check_succeeded $status
        or set failed 1
    end
    return $failed
end
