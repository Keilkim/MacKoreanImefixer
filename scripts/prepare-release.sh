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

/usr/bin/grep -F -- "## [$VERSION]" "$ROOT_DIR/CHANGELOG.md" > /dev/null \
    || fail "CHANGELOG.md에 ## [$VERSION] 항목이 없습니다."
if /usr/bin/grep -F -- "## [$VERSION] - 배포 전 초안" "$ROOT_DIR/CHANGELOG.md" > /dev/null; then
    fail "CHANGELOG.md의 $VERSION 항목을 실제 배포일로 확정해야 합니다."
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
