#!/bin/bash

# 공증된 Mackor 업데이트 ZIP과 릴리스 노트로 Sparkle signed feed를 준비한다.
# 이 스크립트는 네트워크에 업로드하지 않으며 appcast.xml.pending만 만든다.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
DEFAULT_DIST_DIR="$ROOT_DIR/dist"
DIST_DIR="${DIST_DIR:-$DEFAULT_DIST_DIR}"

fail() {
    echo "[오류] $*" >&2
    exit 1
}

reject_preexisting_output_symlink() {
    local output_path="$1"
    local label="$2"

    [ ! -L "$output_path" ] \
        || fail "$label 출력 경로가 심볼릭 링크입니다: $output_path"
}

canonicalize_dist_dir() {
    local directory="$1"
    local probe
    local suffix=""
    local canonical_directory

    case "$directory" in
        /*) ;;
        *) fail "DIST_DIR은 절대 경로여야 합니다: $directory" ;;
    esac
    case "$directory" in
        *'/../'*|*/..|*'/./'*|*/.|*'//'*|*/)
            fail "DIST_DIR에 ., .., 중복 또는 후행 슬래시를 사용할 수 없습니다: $directory"
            ;;
    esac

    probe="$directory"
    while [ ! -e "$probe" ] && [ ! -L "$probe" ]; do
        [ "$probe" != "/" ] || fail "DIST_DIR을 정규화할 수 없습니다: $directory"
        suffix="/$(basename "$probe")$suffix"
        probe="$(dirname "$probe")"
    done
    canonical_directory="$(/bin/realpath "$probe")$suffix"

    case "$canonical_directory" in
        /|/private/tmp|/private/var|/private/var/folders|"$ROOT_DIR")
            fail "DIST_DIR 경로가 너무 넓습니다: $canonical_directory"
            ;;
    esac
    case "$canonical_directory" in
        "$DEFAULT_DIST_DIR"|/private/tmp/*|/private/var/folders/*|/var/folders/*)
            printf '%s\n' "$canonical_directory"
            ;;
        *) fail "DIST_DIR은 저장소 dist 또는 시스템 임시 디렉터리 아래여야 합니다." ;;
    esac
}

validate_https_url() {
    local value="$1"
    local label="$2"

    printf '%s\n' "$value" \
        | /usr/bin/grep -Eq '^https://[A-Za-z0-9][A-Za-z0-9.-]*(:[0-9]+)?(/[^[:space:][:cntrl:]]*)?$' \
        || fail "$label 값은 host가 있는 공백 없는 HTTPS URL이어야 합니다."
    case "$value" in
        *"&"*|*"<"*|*">"*|*"\""*|*"'"*)
            fail "$label 값에는 XML 예약 문자를 사용할 수 없습니다."
            ;;
    esac
}

usage() {
    cat <<'USAGE'
사용법: scripts/prepare-appcast.sh <version> <build-number> <release-notes.md>

필수 환경변수:
  DOWNLOAD_BASE_URL              업데이트 ZIP이 공개될 HTTPS 디렉터리 URL
  RELEASE_NOTES_BASE_URL         릴리스 노트가 공개될 HTTPS 디렉터리 URL
  MACKOR_SPARKLE_PUBLIC_ED_KEY   앱에 포함한 Sparkle Ed25519 공개키
  SPARKLE_GENERATE_APPCAST       Sparkle 2.9+ generate_appcast 실행 파일

선택 환경변수:
  PRODUCT_URL                    앱 홈페이지(기본값: DOWNLOAD_BASE_URL)
  SPARKLE_GENERATE_KEYS          generate_keys 경로(기본값: generator의 sibling)
  SPARKLE_SIGN_UPDATE            sign_update 경로(기본값: generator의 sibling)
  SPARKLE_KEY_ACCOUNT            Keychain 계정(기본값: ed25519)

보안상 개인 키 파일 모드는 아직 허용하지 않습니다. Sparkle 개인 키는 Keychain에
보관하며 generate_keys -p로 공개키 일치를 확인합니다.

출력:
  dist/appcast.xml.pending       검토용 서명 피드. 이 스크립트는 공개하지 않음
USAGE
}

if [ "$#" -ne 3 ]; then
    usage >&2
    exit 2
fi

VERSION="$1"
BUILD_NUMBER="$2"
RELEASE_NOTES_FILE="$3"
DIST_DIR="$(canonicalize_dist_dir "$DIST_DIR")"
ARCHIVE_NAME="Mackor-$VERSION-$BUILD_NUMBER.zip"
ARCHIVE_PATH="$DIST_DIR/$ARCHIVE_NAME"
NOTES_NAME="Mackor-$VERSION-$BUILD_NUMBER.md"
PENDING_APPCAST="$DIST_DIR/appcast.xml.pending"
STAGING_DIR="$DIST_DIR/.appcast-staging"
OUTPUT_NOTES_PATH="$DIST_DIR/$NOTES_NAME"
PRODUCT_URL="${PRODUCT_URL:-${DOWNLOAD_BASE_URL:-}}"
SPARKLE_KEY_ACCOUNT="${SPARKLE_KEY_ACCOUNT:-ed25519}"

case "$VERSION" in
    ''|*[!0-9A-Za-z.-]*) fail "올바르지 않은 버전입니다: $VERSION" ;;
esac
case "$BUILD_NUMBER" in
    ''|*[!0-9]*) fail "빌드 번호는 양의 정수여야 합니다: $BUILD_NUMBER" ;;
    0) fail "빌드 번호는 0보다 커야 합니다." ;;
esac
case "$SPARKLE_KEY_ACCOUNT" in
    ''|*[!0-9A-Za-z._-]*) fail "SPARKLE_KEY_ACCOUNT에 사용할 수 없는 문자가 있습니다." ;;
esac

reject_preexisting_output_symlink "$PENDING_APPCAST" "appcast"
reject_preexisting_output_symlink "$OUTPUT_NOTES_PATH" "릴리스 노트"
reject_preexisting_output_symlink "$STAGING_DIR" "appcast staging"

[ -z "${SPARKLE_ED_KEY_FILE:-}" ] \
    || fail "개인 키 파일 모드는 공개키 유도 검증이 구현될 때까지 사용할 수 없습니다. Keychain을 사용하세요."
[ -f "$ARCHIVE_PATH" ] || fail "업데이트 ZIP을 찾을 수 없습니다: $ARCHIVE_PATH"
[ -f "$RELEASE_NOTES_FILE" ] || fail "릴리스 노트를 찾을 수 없습니다: $RELEASE_NOTES_FILE"
[ -n "${DOWNLOAD_BASE_URL:-}" ] || fail "DOWNLOAD_BASE_URL이 필요합니다."
[ -n "${RELEASE_NOTES_BASE_URL:-}" ] || fail "RELEASE_NOTES_BASE_URL이 필요합니다."
[ -n "${MACKOR_SPARKLE_PUBLIC_ED_KEY:-}" ] || fail "MACKOR_SPARKLE_PUBLIC_ED_KEY가 필요합니다."
[ -n "${SPARKLE_GENERATE_APPCAST:-}" ] || fail "SPARKLE_GENERATE_APPCAST 경로가 필요합니다."
[ -x "$SPARKLE_GENERATE_APPCAST" ] || fail "generate_appcast를 실행할 수 없습니다: $SPARKLE_GENERATE_APPCAST"

SPARKLE_TOOLS_DIR="$(cd "$(dirname "$SPARKLE_GENERATE_APPCAST")" && pwd -P)"
SPARKLE_GENERATE_KEYS="${SPARKLE_GENERATE_KEYS:-$SPARKLE_TOOLS_DIR/generate_keys}"
SPARKLE_SIGN_UPDATE="${SPARKLE_SIGN_UPDATE:-$SPARKLE_TOOLS_DIR/sign_update}"
[ -x "$SPARKLE_GENERATE_KEYS" ] || fail "generate_keys를 실행할 수 없습니다: $SPARKLE_GENERATE_KEYS"
[ -x "$SPARKLE_SIGN_UPDATE" ] || fail "sign_update를 실행할 수 없습니다: $SPARKLE_SIGN_UPDATE"

validate_https_url "$DOWNLOAD_BASE_URL" "DOWNLOAD_BASE_URL"
validate_https_url "$RELEASE_NOTES_BASE_URL" "RELEASE_NOTES_BASE_URL"
validate_https_url "$PRODUCT_URL" "PRODUCT_URL"
echo "$MACKOR_SPARKLE_PUBLIC_ED_KEY" | /usr/bin/grep -Eq '^[A-Za-z0-9+/]{43}=$' \
    || fail "MACKOR_SPARKLE_PUBLIC_ED_KEY가 올바른 공개키 형식이 아닙니다."

KEYCHAIN_PUBLIC_KEY="$("$SPARKLE_GENERATE_KEYS" --account "$SPARKLE_KEY_ACCOUNT" -p | /usr/bin/tr -d '\r\n')"
[ "$KEYCHAIN_PUBLIC_KEY" = "$MACKOR_SPARKLE_PUBLIC_ED_KEY" ] \
    || fail "Keychain의 Sparkle 공개키와 앱에 넣을 공개키가 다릅니다."

if /usr/bin/grep -Eq '\{\{|\}\}|TODO|TBD|작성 필요|여기에' "$RELEASE_NOTES_FILE"; then
    fail "릴리스 노트에 템플릿 표시가 남아 있습니다: $RELEASE_NOTES_FILE"
fi

rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
trap 'rm -rf "$STAGING_DIR"' EXIT

cp "$ARCHIVE_PATH" "$STAGING_DIR/$ARCHIVE_NAME"
cp "$RELEASE_NOTES_FILE" "$STAGING_DIR/$NOTES_NAME"

GENERATED_APPCAST="$STAGING_DIR/appcast.xml"
"$SPARKLE_GENERATE_APPCAST" \
    --account "$SPARKLE_KEY_ACCOUNT" \
    --download-url-prefix "${DOWNLOAD_BASE_URL%/}/" \
    --release-notes-url-prefix "${RELEASE_NOTES_BASE_URL%/}/" \
    --maximum-deltas 0 \
    --link "$PRODUCT_URL" \
    -o "$GENERATED_APPCAST" \
    "$STAGING_DIR"

[ -s "$GENERATED_APPCAST" ] || fail "generate_appcast가 피드를 만들지 않았습니다."
/usr/bin/xmllint --noout "$GENERATED_APPCAST"
/usr/bin/grep -F -- "sparkle-sign-warning:" "$GENERATED_APPCAST" > /dev/null \
    || fail "SURequireSignedFeed용 서명 경고 블록이 없습니다."
/usr/bin/grep -F -- "sparkle-signatures:" "$GENERATED_APPCAST" > /dev/null \
    || fail "SURequireSignedFeed용 appcast 서명 블록이 없습니다."

ARCHIVE_SIGNATURE="$(/usr/bin/xmllint --xpath 'string((//*[local-name()="enclosure"])[1]/@*[local-name()="edSignature"])' "$GENERATED_APPCAST")"
NOTES_SIGNATURE="$(/usr/bin/xmllint --xpath 'string((//*[local-name()="releaseNotesLink"])[1]/@*[local-name()="edSignature"])' "$GENERATED_APPCAST")"
ARCHIVE_LENGTH="$(/usr/bin/xmllint --xpath 'string((//*[local-name()="enclosure"])[1]/@length)' "$GENERATED_APPCAST")"
NOTES_LENGTH="$(/usr/bin/xmllint --xpath 'string((//*[local-name()="releaseNotesLink"])[1]/@*[local-name()="length"])' "$GENERATED_APPCAST")"

echo "$ARCHIVE_SIGNATURE" | /usr/bin/grep -Eq '^[A-Za-z0-9+/]{86}==$' \
    || fail "업데이트 ZIP EdDSA 서명이 올바른 형식이 아닙니다."
echo "$NOTES_SIGNATURE" | /usr/bin/grep -Eq '^[A-Za-z0-9+/]{86}==$' \
    || fail "릴리스 노트 EdDSA 서명이 올바른 형식이 아닙니다."
[ "$ARCHIVE_LENGTH" = "$(/usr/bin/stat -f%z "$STAGING_DIR/$ARCHIVE_NAME")" ] \
    || fail "appcast의 업데이트 ZIP 크기가 실제 파일과 다릅니다."
[ "$NOTES_LENGTH" = "$(/usr/bin/stat -f%z "$STAGING_DIR/$NOTES_NAME")" ] \
    || fail "appcast의 릴리스 노트 크기가 실제 파일과 다릅니다."

"$SPARKLE_SIGN_UPDATE" --account "$SPARKLE_KEY_ACCOUNT" --verify "$GENERATED_APPCAST"
"$SPARKLE_SIGN_UPDATE" --account "$SPARKLE_KEY_ACCOUNT" --verify "$STAGING_DIR/$ARCHIVE_NAME" "$ARCHIVE_SIGNATURE"
"$SPARKLE_SIGN_UPDATE" --account "$SPARKLE_KEY_ACCOUNT" --verify "$STAGING_DIR/$NOTES_NAME" "$NOTES_SIGNATURE"

/usr/bin/grep -F -- "<sparkle:version>$BUILD_NUMBER</sparkle:version>" "$GENERATED_APPCAST" > /dev/null \
    || fail "appcast의 빌드 번호가 일치하지 않습니다."
/usr/bin/grep -F -- "<sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>" "$GENERATED_APPCAST" > /dev/null \
    || fail "appcast의 표시 버전이 일치하지 않습니다."
/usr/bin/grep -F -- "${DOWNLOAD_BASE_URL%/}/$ARCHIVE_NAME" "$GENERATED_APPCAST" > /dev/null \
    || fail "appcast의 다운로드 URL이 예상과 다릅니다."
/usr/bin/grep -F -- "${RELEASE_NOTES_BASE_URL%/}/$NOTES_NAME" "$GENERATED_APPCAST" > /dev/null \
    || fail "appcast의 릴리스 노트 URL이 예상과 다릅니다."

reject_preexisting_output_symlink "$PENDING_APPCAST" "appcast"
reject_preexisting_output_symlink "$OUTPUT_NOTES_PATH" "릴리스 노트"
cp "$STAGING_DIR/$NOTES_NAME" "$OUTPUT_NOTES_PATH"
cp "$GENERATED_APPCAST" "$PENDING_APPCAST"

echo "[완료] 암호학적으로 검증한 Sparkle signed feed: $PENDING_APPCAST"
echo "[안전] 어떤 파일도 업로드하지 않았습니다. 공개 산출물을 먼저 올린 뒤 appcast를 마지막에 게시하세요."
