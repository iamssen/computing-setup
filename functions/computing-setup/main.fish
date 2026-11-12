# 이 기기의 설치·업데이트 상태를 한 번에 점검하는 computing-setup 명령.
# 점검만 하고 아무것도 변경하지 않는다. 실행할 명령을 [Action] 줄로 안내한다.

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

# ── 명령 ─────────────────────────────────────────────────────────────

function computing-setup --description 'Check available system setup and update commands'
    if test (count $argv) -ne 0
        echo 'Usage: computing-setup' >&2
        return 2
    end
    set -l failed 0

    # 섹션 제목과 점검 명령을 같은 순서로 나열한다. 섹션을 추가하려면 두 목록에 한 줄씩 더한다.
    set -l titles Homebrew Node.js Dagu Rust 'Global npm packages'
    set -l checks \
        _computing_setup_check_brew \
        check-node-update \
        check-dagu-update \
        _computing_setup_check_rust \
        _computing_setup_check_npm

    # 한 섹션이 실패해도 나머지 섹션은 계속 점검하고, 마지막에 실패 여부만 돌려준다.
    for index in (seq (count $checks))
        _computing_setup_section $index (count $checks) $titles[$index]
        $checks[$index]
        _computing_setup_check_succeeded $status
        or set failed 1
    end
    return $failed
end
