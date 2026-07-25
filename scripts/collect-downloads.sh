#!/bin/bash

# 게시된 릴리스의 설치본 다운로드 수를 태그 구분 없이 모두 합해 docs/downloads.json에 쓴다.
# 랜딩 페이지가 방문자 브라우저에서 GitHub API를 직접 부르면 "외부 요청·추적 금지"
# (RELEASING.md §5)를 깨뜨리므로, 수집은 CI에서만 하고 페이지는 같은 오리진의 이 JSON만
# 읽는다. 읽기 전용이며 릴리스·피드·Pages 상태를 바꾸지 않는다.
#
# 세는 대상 — 릴리스에 업로드한 .dmg·.pkg 자산 전부:
#   고정 별칭 Mackor.dmg  랜딩 다운로드 버튼이 가리키는 대상
#   버전별 .dmg/.pkg      릴리스 페이지에서 직접 받아가는 경로
#
# 빼는 대상과 이유:
#   .zip             Sparkle 자동 업데이트가 내려받는 파일 — 이미 쓰고 있는 사용자의 갱신
#                    트래픽이라 합계에 넣으면 사용자 수가 업데이트 횟수만큼 부풀려진다.
#   SHA256SUMS.txt   검증용 텍스트, 설치와 무관.
#   릴리스 노트 .md   문서, 설치와 무관.
#
# 한계 — GitHub는 소스 아카이브(Code ▸ Download ZIP, 릴리스의 Source code (zip/tar.gz))의
# 다운로드 수를 어느 API로도 노출하지 않는다. 릴리스 객체에 download_count 필드가 없고
# zipball_url/tarball_url에도 카운터가 붙지 않으므로 합계에 포함할 방법이 없다.
# traffic/clones는 git clone만 세고 14일치만 남으며 CI 체크아웃까지 섞여 대체물이 못 된다.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
GITHUB_REPO="${GITHUB_REPO:-Keilkim/MacKoreanImefixer}"
OUTPUT="${1:-$ROOT_DIR/docs/downloads.json}"

fail() {
    echo "[오류] $*" >&2
    exit 1
}

command -v gh > /dev/null 2>&1 || fail "필요한 명령을 찾을 수 없습니다: gh"

# 초안(draft)은 아직 공개되지 않았으므로 제외한다.
COUNTS="$(
    gh api --paginate "repos/$GITHUB_REPO/releases" \
        --jq '.[] | select(.draft == false) | .assets[]
              | select((.name | endswith(".dmg")) or (.name | endswith(".pkg")))
              | .download_count'
)" || fail "릴리스 목록을 가져오지 못했습니다"

TOTAL=0
while read -r COUNT; do
    [ -n "$COUNT" ] || continue
    case "$COUNT" in
        '' | *[!0-9]*) fail "다운로드 수가 정수가 아닙니다: $COUNT" ;;
    esac
    TOTAL=$((TOTAL + COUNT))
done <<< "$COUNTS"

# 합계가 0이면 자산 이름 규칙이 바뀌어 아무것도 못 셌다는 뜻이다. 0을 게시해 랜딩에
# "사용자 0명"을 띄우는 것보다 실패해서 사람이 보게 하는 편이 낫다.
[ "$TOTAL" -gt 0 ] || fail "설치본 자산을 하나도 세지 못했습니다 — 자산 이름 규칙을 확인하세요"

printf '{\n  "total": %d,\n  "updated": "%s"\n}\n' \
    "$TOTAL" "$(date -u +%Y-%m-%d)" > "$OUTPUT"

echo "[완료] $OUTPUT — 누적 설치본 다운로드 $TOTAL"
