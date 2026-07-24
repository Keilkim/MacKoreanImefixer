#!/bin/bash

# Mackor 공식 릴리스 산출물을 로컬에서 준비한다.
# 테스트 -> 유니버설 빌드 -> Developer ID 서명 -> 공증/스테이플 ->
# Sparkle signed appcast -> 최종 검증 순서를 강제하며, 외부에는 게시하지 않는다.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"

fail() {
    echo "[오류] $*" >&2
    exit 1
}

require_env() {
    [ -n "${!1:-}" ] || fail "필수 환경변수가 없습니다: $1"
}

require_real_directory_or_absent() {
    local path="$1"
    local label="$2"

    [ ! -L "$path" ] || fail "$label 경로가 심볼릭 링크입니다: $path"
    if [ -e "$path" ] && [ ! -d "$path" ]; then
        fail "$label 경로가 디렉터리가 아닙니다: $path"
    fi
}

validate_https_url() {
    local value="$1"
    local label="$2"

    printf '%s\n' "$value" \
        | /usr/bin/grep -Eq '^https://[A-Za-z0-9][A-Za-z0-9.-]*(:[0-9]+)?(/[^[:space:][:cntrl:]]*)?$' \
        || fail "$label 값은 host가 있는 공백 없는 HTTPS URL이어야 합니다."
}

identity_exists() {
    /usr/bin/security find-identity -v 2>/dev/null \
        | /usr/bin/grep -F -- "\"$1\"" > /dev/null
}

# appcast의 모든 item에서 가장 큰 sparkle:version(빌드 번호)을 출력한다. item이 없으면 0.
max_published_build() {
    local feed="$1" total index value max=0
    total="$(/usr/bin/xmllint --xpath 'count(//*[local-name()="item"])' "$feed" 2>/dev/null || echo 0)"
    case "$total" in ''|*[!0-9]*) total=0 ;; esac
    index=1
    while [ "$index" -le "$total" ]; do
        value="$(/usr/bin/xmllint --xpath "string((//*[local-name()='item'])[$index]/*[local-name()='version'])" "$feed" 2>/dev/null || echo '')"
        [ -n "$value" ] || value="$(/usr/bin/xmllint --xpath "string((//*[local-name()='item'])[$index]/*[local-name()='enclosure']/@*[local-name()='version'])" "$feed" 2>/dev/null || echo '')"
        case "$value" in ''|*[!0-9]*) fail "appcast 항목 $index의 sparkle:version이 정수가 아닙니다: ${value:-없음}" ;; esac
        [ "$value" -le "$max" ] || max="$value"
        index=$((index + 1))
    done
    printf '%s\n' "$max"
}

usage() {
    cat <<'USAGE'
사용법: scripts/prepare-release.sh <version> <build-number> <release-notes.md>

필수 환경변수:
  APP_SIGN_IDENTITY             Developer ID Application 인증서 전체 이름
  INSTALLER_SIGN_IDENTITY       Developer ID Installer 인증서 전체 이름
  NOTARY_PROFILE                notarytool Keychain 프로필
  MACKOR_UPDATE_FEED_URL        실제 공개할 HTTPS appcast.xml URL
  MACKOR_SPARKLE_PUBLIC_ED_KEY  앱에 포함할 Sparkle Ed25519 공개키
  SPARKLE_GENERATE_APPCAST      Sparkle 2.9+ generate_appcast 실행 파일
  DOWNLOAD_BASE_URL             GitHub Release 등의 HTTPS 자산 디렉터리
  RELEASE_NOTES_BASE_URL        HTTPS 릴리스 노트 디렉터리

선택 환경변수:
  PRODUCT_URL                   앱 홈페이지
  SPARKLE_GENERATE_KEYS         generate_keys 경로(기본값: generator sibling)
  SPARKLE_SIGN_UPDATE           sign_update 경로(기본값: generator sibling)
  SPARKLE_KEY_ACCOUNT           Keychain 계정(기본값: ed25519)

이 명령은 업로드, Git tag 생성, GitHub Release 공개를 하지 않습니다.
USAGE
}

if [ "$#" -ne 3 ]; then
    usage >&2
    exit 2
fi

VERSION="$1"
BUILD_NUMBER="$2"
RELEASE_NOTES_FILE="$3"

case "$VERSION" in
    ''|*[!0-9A-Za-z.-]*) fail "올바르지 않은 버전입니다: $VERSION" ;;
esac
case "$BUILD_NUMBER" in
    ''|*[!0-9]*) fail "빌드 번호는 양의 정수여야 합니다: $BUILD_NUMBER" ;;
    0) fail "빌드 번호는 0보다 커야 합니다." ;;
esac

for env_name in \
    APP_SIGN_IDENTITY \
    INSTALLER_SIGN_IDENTITY \
    NOTARY_PROFILE \
    MACKOR_UPDATE_FEED_URL \
    MACKOR_SPARKLE_PUBLIC_ED_KEY \
    SPARKLE_GENERATE_APPCAST \
    DOWNLOAD_BASE_URL \
    RELEASE_NOTES_BASE_URL; do
    require_env "$env_name"
done

[ -f "$RELEASE_NOTES_FILE" ] || fail "릴리스 노트를 찾을 수 없습니다: $RELEASE_NOTES_FILE"
[ -x "$SPARKLE_GENERATE_APPCAST" ] || fail "generate_appcast를 실행할 수 없습니다."
[ -z "${SPARKLE_ED_KEY_FILE:-}" ] \
    || fail "공식 릴리스는 Sparkle 개인 키 파일을 허용하지 않습니다. Keychain을 사용하세요."

SPARKLE_TOOLS_DIR="$(cd "$(dirname "$SPARKLE_GENERATE_APPCAST")" && pwd -P)"
SPARKLE_GENERATE_KEYS="${SPARKLE_GENERATE_KEYS:-$SPARKLE_TOOLS_DIR/generate_keys}"
SPARKLE_SIGN_UPDATE="${SPARKLE_SIGN_UPDATE:-$SPARKLE_TOOLS_DIR/sign_update}"
SPARKLE_KEY_ACCOUNT="${SPARKLE_KEY_ACCOUNT:-ed25519}"
[ -x "$SPARKLE_GENERATE_KEYS" ] || fail "generate_keys를 실행할 수 없습니다."
[ -x "$SPARKLE_SIGN_UPDATE" ] || fail "sign_update를 실행할 수 없습니다."
case "$SPARKLE_KEY_ACCOUNT" in
    ''|*[!0-9A-Za-z._-]*) fail "SPARKLE_KEY_ACCOUNT에 사용할 수 없는 문자가 있습니다." ;;
esac
validate_https_url "$MACKOR_UPDATE_FEED_URL" "MACKOR_UPDATE_FEED_URL"
case "$MACKOR_UPDATE_FEED_URL" in
    */appcast.xml) ;;
    *) fail "MACKOR_UPDATE_FEED_URL은 appcast.xml로 끝나야 합니다." ;;
esac
echo "$MACKOR_SPARKLE_PUBLIC_ED_KEY" | /usr/bin/grep -Eq '^[A-Za-z0-9+/]{43}=$' \
    || fail "MACKOR_SPARKLE_PUBLIC_ED_KEY가 올바른 공개키 형식이 아닙니다."
KEYCHAIN_PUBLIC_KEY="$("$SPARKLE_GENERATE_KEYS" --account "$SPARKLE_KEY_ACCOUNT" -p | /usr/bin/tr -d '\r\n')"
[ "$KEYCHAIN_PUBLIC_KEY" = "$MACKOR_SPARKLE_PUBLIC_ED_KEY" ] \
    || fail "Keychain의 Sparkle 공개키와 앱에 넣을 공개키가 다릅니다."

export SPARKLE_GENERATE_KEYS SPARKLE_SIGN_UPDATE SPARKLE_KEY_ACCOUNT

identity_exists "$APP_SIGN_IDENTITY" \
    || fail "유효한 앱 서명 인증서와 개인 키를 찾을 수 없습니다: $APP_SIGN_IDENTITY"
identity_exists "$INSTALLER_SIGN_IDENTITY" \
    || fail "유효한 인스톨러 서명 인증서와 개인 키를 찾을 수 없습니다: $INSTALLER_SIGN_IDENTITY"

if [ -n "$(git -C "$ROOT_DIR" status --porcelain --untracked-files=all)" ]; then
    fail "공식 릴리스는 커밋된 깨끗한 작업 트리에서만 준비할 수 있습니다."
fi

# CHANGELOG의 해당 버전 섹션이 실제 배포일로 확정되었는지 검사한다. 리터럴 문자열에
# 의존하지 않고 "## [<version>] <대시> YYYY-MM-DD" 형식을 강제하므로, 초안 표기나
# 날짜 없는 제목("배포 전" 등)은 어떤 문구든 구조적으로 차단된다.
CHANGELOG_PATH="$ROOT_DIR/CHANGELOG.md"
ESCAPED_VERSION="${VERSION//./\\.}"
CHANGELOG_HEADING_COUNT="$(/usr/bin/grep -Ec "^## \[$ESCAPED_VERSION\]" "$CHANGELOG_PATH" || true)"
[ "$CHANGELOG_HEADING_COUNT" = "1" ] \
    || fail "CHANGELOG.md에 '## [$VERSION]' 섹션 제목이 정확히 하나여야 합니다(현재 ${CHANGELOG_HEADING_COUNT}개)."
CHANGELOG_HEADING="$(/usr/bin/grep -E -m 1 "^## \[$ESCAPED_VERSION\]" "$CHANGELOG_PATH")"
printf '%s\n' "$CHANGELOG_HEADING" \
    | /usr/bin/grep -Eq "^## \[$ESCAPED_VERSION\] (-|–|—) [0-9]{4}-[0-9]{2}-[0-9]{2}$" \
    || fail "CHANGELOG의 $VERSION 제목을 '## [$VERSION] - YYYY-MM-DD'(실제 배포일)로 확정해야 합니다: $CHANGELOG_HEADING"
if printf '%s\n' "$CHANGELOG_HEADING" | /usr/bin/grep -Eiq '배포 전|미배포|초안|아직|태그되지|unreleased|draft|tbd|todo'; then
    fail "CHANGELOG의 $VERSION 제목에 초안 표기가 남아 있습니다: $CHANGELOG_HEADING"
fi
CHANGELOG_DATE="${CHANGELOG_HEADING##* }"
[ "$(/bin/date -j -f '%Y-%m-%d' "$CHANGELOG_DATE" '+%Y-%m-%d' 2>/dev/null)" = "$CHANGELOG_DATE" ] \
    || fail "CHANGELOG의 $VERSION 배포일이 실제 달력 날짜가 아닙니다: $CHANGELOG_DATE"
[ "$(/bin/date -j -f '%Y-%m-%d' "$CHANGELOG_DATE" '+%s')" -le "$(/bin/date '+%s')" ] \
    || fail "CHANGELOG의 $VERSION 배포일이 미래입니다: $CHANGELOG_DATE"
if /usr/bin/grep -Eq "^\[$ESCAPED_VERSION\]:.*\.\.\.HEAD[[:space:]]*$" "$CHANGELOG_PATH"; then
    fail "CHANGELOG 하단의 [$VERSION] 비교 링크가 HEAD를 가리킵니다. v$VERSION 태그 범위로 확정하세요."
fi
/usr/bin/grep -F -- "$VERSION" "$RELEASE_NOTES_FILE" > /dev/null \
    || fail "릴리스 노트에 버전 $VERSION이 없습니다."
if /usr/bin/grep -Eq '\{\{|\}\}|TODO|TBD|작성 필요|여기에' "$RELEASE_NOTES_FILE"; then
    fail "릴리스 노트에 템플릿 표시가 남아 있습니다."
fi

TEMP_BASE="${TMPDIR:-/tmp}"
TEMP_BASE="${TEMP_BASE%/}"
[ -n "$TEMP_BASE" ] || fail "TMPDIR이 안전한 임시 경로가 아닙니다."
WORK_ROOT="$(mktemp -d "$TEMP_BASE/mackor-release.XXXXXX")"
WORK_BUILD="$WORK_ROOT/build"
WORK_DIST="$WORK_ROOT/dist"
TEST_DERIVED_DATA="$WORK_ROOT/test-derived-data"
DIST_ROOT="$ROOT_DIR/dist"
RELEASES_ROOT="$DIST_ROOT/releases"
FINAL_DIR="$RELEASES_ROOT/$VERSION-$BUILD_NUMBER"
trap 'rm -rf "$WORK_ROOT"' EXIT

require_real_directory_or_absent "$DIST_ROOT" "dist"
require_real_directory_or_absent "$RELEASES_ROOT" "releases"
[ ! -e "$FINAL_DIR" ] && [ ! -L "$FINAL_DIR" ] \
    || fail "같은 버전의 로컬 릴리스 폴더가 이미 있습니다: $FINAL_DIR"

# 빌드 번호 단조 증가를 기계적으로 강제한다. 이미 공개된 sparkle:version보다 크지 않으면
# Sparkle이 새 버전으로 인식하지 못해 사용자가 업데이트를 영구히 못 받는다. 공증도 온라인이
# 필수이므로 라이브 피드를 못 가져오면(오프라인/404) 하드 실패한다.
echo "[사전 점검] 공개된 빌드 번호와의 단조 증가 확인 중..."
LIVE_APPCAST="$WORK_ROOT/live-appcast.xml"
/usr/bin/curl --fail --silent --show-error --location --proto '=https' \
    --max-time 30 --retry 2 \
    --output "$LIVE_APPCAST" \
    "${MACKOR_UPDATE_FEED_URL}?mackor-preflight=$(/bin/date +%s)" \
    || fail "라이브 appcast를 내려받지 못했습니다: $MACKOR_UPDATE_FEED_URL — 공식 릴리스 준비는 네트워크가 필요합니다(공증도 마찬가지)."
/usr/bin/xmllint --noout "$LIVE_APPCAST" \
    || fail "라이브 appcast가 유효한 XML이 아닙니다(호스팅 오류 또는 404 페이지일 수 있습니다)."
MAX_PUBLISHED_BUILD="$(max_published_build "$LIVE_APPCAST")"
LOCAL_FEED_SNAPSHOT="$ROOT_DIR/docs/appcast.xml"
if [ -f "$LOCAL_FEED_SNAPSHOT" ]; then
    LOCAL_MAX_BUILD="$(max_published_build "$LOCAL_FEED_SNAPSHOT")"
    [ "$LOCAL_MAX_BUILD" = "$MAX_PUBLISHED_BUILD" ] \
        || fail "docs/appcast.xml(build $LOCAL_MAX_BUILD)과 라이브 피드(build $MAX_PUBLISHED_BUILD)의 최신 빌드가 다릅니다. 미완료 게시가 있거나 git pull이 필요합니다."
fi
[ "$BUILD_NUMBER" -gt "$MAX_PUBLISHED_BUILD" ] \
    || fail "빌드 번호 $BUILD_NUMBER는 이미 공개된 최대 빌드 $MAX_PUBLISHED_BUILD보다 커야 합니다."
echo "[사전 점검] 통과: 새 빌드 $BUILD_NUMBER > 공개된 최대 빌드 $MAX_PUBLISHED_BUILD"

echo "[1/5] 전체 테스트 실행 중..."
xcodebuild \
    -project "$ROOT_DIR/Mackor/Mackor.xcodeproj" \
    -scheme Mackor \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "$TEST_DERIVED_DATA" \
    test \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    MACKOR_UPDATE_FEED_URL="$MACKOR_UPDATE_FEED_URL" \
    MACKOR_SPARKLE_PUBLIC_ED_KEY="$MACKOR_SPARKLE_PUBLIC_ED_KEY"

echo "[2/5] 공식 유니버설 설치 파일 빌드·서명·공증 중..."
VERSION="$VERSION" \
BUILD_NUMBER="$BUILD_NUMBER" \
BUILD_DIR="$WORK_BUILD" \
DIST_DIR="$WORK_DIST" \
REQUIRE_SIGNING=1 \
REQUIRE_NOTARIZATION=1 \
APP_SIGN_IDENTITY="$APP_SIGN_IDENTITY" \
INSTALLER_SIGN_IDENTITY="$INSTALLER_SIGN_IDENTITY" \
NOTARY_PROFILE="$NOTARY_PROFILE" \
MACKOR_UPDATE_FEED_URL="$MACKOR_UPDATE_FEED_URL" \
MACKOR_SPARKLE_PUBLIC_ED_KEY="$MACKOR_SPARKLE_PUBLIC_ED_KEY" \
"$ROOT_DIR/build-installer.sh"

PKG_NAME="Mackor-$VERSION-$BUILD_NUMBER.pkg"
DMG_NAME="Mackor-$VERSION-$BUILD_NUMBER.dmg"
ARCHIVE_NAME="Mackor-$VERSION-$BUILD_NUMBER.zip"
NOTES_NAME="Mackor-$VERSION-$BUILD_NUMBER.md"
CHECKSUM_NAME="Mackor-$VERSION-$BUILD_NUMBER-SHA256SUMS.txt"

mv "$WORK_DIST/Mackor_Installer.pkg" "$WORK_DIST/$PKG_NAME"
mv "$WORK_DIST/Mackor.dmg" "$WORK_DIST/$DMG_NAME"

echo "[3/5] EdDSA 서명 appcast 준비 중..."
DIST_DIR="$WORK_DIST" \
"$SCRIPT_DIR/prepare-appcast.sh" "$VERSION" "$BUILD_NUMBER" "$RELEASE_NOTES_FILE"

(
    cd "$WORK_DIST"
    shasum -a 256 \
        "$ARCHIVE_NAME" \
        "$PKG_NAME" \
        "$DMG_NAME" \
        "$NOTES_NAME" > "$CHECKSUM_NAME"
)

echo "[4/5] 서명·공증·스테이플·피드 무결성 검증 중..."
DIST_DIR="$WORK_DIST" "$SCRIPT_DIR/validate-release.sh" "$VERSION" "$BUILD_NUMBER"

echo "[5/5] 검증된 로컬 산출물 보관 중..."
require_real_directory_or_absent "$DIST_ROOT" "dist"
require_real_directory_or_absent "$RELEASES_ROOT" "releases"
mkdir -p "$RELEASES_ROOT"
require_real_directory_or_absent "$RELEASES_ROOT" "releases"
mkdir "$FINAL_DIR"
cp -R "$WORK_DIST/." "$FINAL_DIR/"

echo ""
echo "[완료] 검증된 릴리스 후보: $FINAL_DIR"
echo "[안전] 아직 GitHub나 업데이트 서버에 아무것도 게시하지 않았습니다."
echo "[순서] PKG/DMG/ZIP/릴리스 노트를 먼저 업로드하고 다운로드 검증을 마친 뒤,"
echo "       appcast.xml.pending을 appcast.xml로 이름을 바꾸어 반드시 마지막에 게시하세요."
