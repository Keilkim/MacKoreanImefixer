#!/bin/bash

# 게시된 Mackor 릴리스가 로컬 검증 산출물과 일치하는지 원격에서 확인한다.
# gh api(GET)와 curl(GET)만 사용하며 GitHub·피드·Pages 상태를 절대 변경하지 않는다.
# 따라서 "스크립트는 공개 작업을 자동 수행하지 않는다"는 정책의 예외가 아니라, 그 정책이
# 요구하는 수동 게시의 검증 단계를 자동화한다.
#
# 2단계로 공개 순서를 지킨다.
#   before-appcast : 자산 게시 직후·appcast 게시 전 (라이브 피드에 새 빌드가 "없어야" 통과)
#   final          : appcast까지 게시한 뒤 (라이브 피드에 새 빌드가 "있어야" 통과, 기본값)

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"
SPARKLE_KEY_ACCOUNT="${SPARKLE_KEY_ACCOUNT:-ed25519}"
GITHUB_REPO="${GITHUB_REPO:-Keilkim/MacKoreanImefixer}"
LANDING_URL="${LANDING_URL:-https://keilkim.github.io/MacKoreanImefixer/}"

fail() {
    echo "[오류] $*" >&2
    exit 1
}

require_command() {
    command -v "$1" > /dev/null 2>&1 || fail "필요한 명령을 찾을 수 없습니다: $1"
}

usage() {
    cat <<'USAGE'
사용법: scripts/verify-published.sh <version> <build-number> [before-appcast|final]

  before-appcast : 자산 6종 게시 직후, appcast 게시 전에 실행
  final          : appcast까지 게시한 뒤 실행 (기본값)

필수 환경변수:
  MACKOR_UPDATE_FEED_URL         라이브 appcast.xml URL
선택 환경변수:
  MACKOR_SPARKLE_PUBLIC_ED_KEY   설정 시 Keychain 공개키 일치 확인
  SPARKLE_SIGN_UPDATE            설정 시 라이브 피드의 EdDSA 서명 재검증(권장)
  SPARKLE_GENERATE_KEYS          Keychain 공개키 확인용
  GITHUB_REPO                    기본값 Keilkim/MacKoreanImefixer
  DIST_DIR                       기본값 <repo>/dist
  LANDING_URL                    기본값 https://keilkim.github.io/MacKoreanImefixer/

이 스크립트는 읽기 전용입니다. 어떤 파일도 업로드·변경하지 않습니다.
USAGE
}

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
    usage >&2
    exit 2
fi

VERSION="$1"
BUILD_NUMBER="$2"
PHASE="${3:-final}"

case "$VERSION" in
    ''|*[!0-9A-Za-z.-]*) fail "올바르지 않은 버전입니다: $VERSION" ;;
esac
case "$BUILD_NUMBER" in
    ''|*[!0-9]*) fail "빌드 번호는 양의 정수여야 합니다: $BUILD_NUMBER" ;;
    0) fail "빌드 번호는 0보다 커야 합니다." ;;
esac
case "$PHASE" in
    before-appcast|final) ;;
    *) usage >&2; exit 2 ;;
esac

[ -n "${MACKOR_UPDATE_FEED_URL:-}" ] || fail "MACKOR_UPDATE_FEED_URL이 필요합니다."

for tool in gh curl xmllint shasum stat cmp; do
    require_command "$tool"
done
gh auth status > /dev/null 2>&1 || fail "gh CLI 인증이 필요합니다: gh auth login"

TAG="v$VERSION"
RELEASE_DIR="$DIST_DIR/releases/$VERSION-$BUILD_NUMBER"
ARCHIVE_NAME="Mackor-$VERSION-$BUILD_NUMBER.zip"
PKG_NAME="Mackor-$VERSION-$BUILD_NUMBER.pkg"
DMG_NAME="Mackor-$VERSION-$BUILD_NUMBER.dmg"
NOTES_NAME="Mackor-$VERSION-$BUILD_NUMBER.md"
CHECKSUM_NAME="Mackor-$VERSION-$BUILD_NUMBER-SHA256SUMS.txt"
ALIAS_DMG_NAME="Mackor.dmg"
DOWNLOAD_BASE="https://github.com/$GITHUB_REPO/releases/download/$TAG"
LATEST_ALIAS_URL="https://github.com/$GITHUB_REPO/releases/latest/download/$ALIAS_DMG_NAME"

for name in "$ARCHIVE_NAME" "$PKG_NAME" "$DMG_NAME" "$NOTES_NAME" "$CHECKSUM_NAME"; do
    [ -s "$RELEASE_DIR/$name" ] || fail "로컬 기준 산출물이 없습니다: $RELEASE_DIR/$name (prepare-release.sh를 먼저 실행하세요)."
done

# 선택: Keychain 공개키 일치(가능한 환경에서만)
if [ -n "${MACKOR_SPARKLE_PUBLIC_ED_KEY:-}" ] && [ -x "${SPARKLE_GENERATE_KEYS:-}" ]; then
    KEYCHAIN_PUBLIC_KEY="$("$SPARKLE_GENERATE_KEYS" --account "$SPARKLE_KEY_ACCOUNT" -p | /usr/bin/tr -d '\r\n')"
    [ "$KEYCHAIN_PUBLIC_KEY" = "$MACKOR_SPARKLE_PUBLIC_ED_KEY" ] \
        || fail "Keychain의 Sparkle 공개키와 앱에 넣은 공개키가 다릅니다."
fi

TEMP_BASE="${TMPDIR:-/tmp}"
TEMP_BASE="${TEMP_BASE%/}"
[ -n "$TEMP_BASE" ] || fail "TMPDIR이 안전한 임시 경로가 아닙니다."
TEMP_DIR="$(mktemp -d "$TEMP_BASE/mackor-verify-published.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT

RELEASE_JSON="$TEMP_DIR/release.json"

remote_asset_field() {  # $1=asset name, $2=field
    gh api "repos/$GITHUB_REPO/releases/tags/$TAG" \
        --jq ".assets[] | select(.name == \"$1\") | .$2" 2>/dev/null
}
local_sha256() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }

echo "[1/7] GitHub 릴리스 메타데이터 확인 중..."
gh api "repos/$GITHUB_REPO/releases/tags/$TAG" > "$RELEASE_JSON" \
    || fail "릴리스 $TAG를 찾을 수 없습니다. Draft는 태그로 조회되지 않으니 먼저 공개했는지 확인하세요."
[ "$(gh api "repos/$GITHUB_REPO/releases/tags/$TAG" --jq '.draft')" = "false" ] \
    || fail "릴리스 $TAG가 아직 draft입니다. 공개한 뒤 다시 실행하세요."
[ "$(gh api "repos/$GITHUB_REPO/releases/tags/$TAG" --jq '.prerelease')" = "false" ] \
    || fail "릴리스 $TAG가 prerelease로 표시되어 있습니다."
ASSET_COUNT="$(gh api "repos/$GITHUB_REPO/releases/tags/$TAG" --jq '.assets | length')"
[ "$ASSET_COUNT" = "6" ] \
    || fail "자산이 정확히 6개(버전 자산 5 + 고정이름 별칭 Mackor.dmg)여야 합니다(현재 $ASSET_COUNT개)."

echo "[2/7] 자산 6종의 존재·크기·SHA-256 digest 대조 중..."
for name in "$ARCHIVE_NAME" "$PKG_NAME" "$DMG_NAME" "$NOTES_NAME" "$CHECKSUM_NAME"; do
    REMOTE_SIZE="$(remote_asset_field "$name" size)"
    [ -n "$REMOTE_SIZE" ] || fail "릴리스에 자산이 없습니다: $name"
    [ "$REMOTE_SIZE" = "$(/usr/bin/stat -f%z "$RELEASE_DIR/$name")" ] \
        || fail "$name의 원격 크기가 로컬과 다릅니다."
    REMOTE_DIGEST="$(remote_asset_field "$name" digest)"
    if [ -n "$REMOTE_DIGEST" ] && [ "$REMOTE_DIGEST" != "null" ]; then
        [ "$REMOTE_DIGEST" = "sha256:$(local_sha256 "$RELEASE_DIR/$name")" ] \
            || fail "$name의 원격 SHA-256 digest가 로컬과 다릅니다."
    fi
done

echo "[3/7] 자산 재다운로드 후 바이트 대조 중..."
for name in "$ARCHIVE_NAME" "$PKG_NAME" "$DMG_NAME" "$NOTES_NAME" "$CHECKSUM_NAME"; do
    /usr/bin/curl --fail --silent --show-error --location --proto '=https' \
        --max-time 120 --output "$TEMP_DIR/remote-$name" "$DOWNLOAD_BASE/$name" \
        || fail "$name을 내려받지 못했습니다: $DOWNLOAD_BASE/$name"
    /usr/bin/cmp -s "$TEMP_DIR/remote-$name" "$RELEASE_DIR/$name" \
        || fail "다운로드한 $name이 로컬 산출물과 바이트가 다릅니다."
done

echo "[4/7] 고정 이름 별칭 Mackor.dmg 동일성 확인 중..."
ALIAS_SIZE="$(remote_asset_field "$ALIAS_DMG_NAME" size)"
[ -n "$ALIAS_SIZE" ] || fail "고정 이름 별칭 $ALIAS_DMG_NAME 자산이 릴리스에 없습니다(웹사이트 다운로드가 404가 됩니다)."
ALIAS_DIGEST="$(remote_asset_field "$ALIAS_DMG_NAME" digest)"
DMG_DIGEST="$(remote_asset_field "$DMG_NAME" digest)"
if [ -n "$ALIAS_DIGEST" ] && [ "$ALIAS_DIGEST" != "null" ] && [ -n "$DMG_DIGEST" ] && [ "$DMG_DIGEST" != "null" ]; then
    [ "$ALIAS_DIGEST" = "$DMG_DIGEST" ] \
        || fail "별칭 Mackor.dmg의 digest가 버전 DMG와 다릅니다."
fi
/usr/bin/curl --fail --silent --show-error --location --proto '=https' \
    --max-time 120 --output "$TEMP_DIR/alias.dmg" "$DOWNLOAD_BASE/$ALIAS_DMG_NAME" \
    || fail "별칭 $ALIAS_DMG_NAME을 내려받지 못했습니다."
/usr/bin/cmp -s "$TEMP_DIR/alias.dmg" "$RELEASE_DIR/$DMG_NAME" \
    || fail "별칭 Mackor.dmg가 버전 DMG와 바이트가 다릅니다."

echo "[5/7] releases/latest 지시 대상 확인 중..."
[ "$(gh api "repos/$GITHUB_REPO/releases/latest" --jq '.tag_name')" = "$TAG" ] \
    || fail "releases/latest가 $TAG를 가리키지 않습니다."

echo "[6/7] 랜딩 버튼 URL 확인 중..."
/usr/bin/grep -F -- "releases/latest/download/$ALIAS_DMG_NAME" "$ROOT_DIR/docs/index.html" > /dev/null \
    || fail "docs/index.html에 releases/latest/download/$ALIAS_DMG_NAME 링크가 없습니다."
/usr/bin/curl --fail --silent --show-error --location --proto '=https' \
    --max-time 30 --output /dev/null "$LANDING_URL" \
    || fail "랜딩 페이지가 응답하지 않습니다: $LANDING_URL"
/usr/bin/curl --fail --silent --show-error --location --proto '=https' \
    --max-time 120 --output "$TEMP_DIR/latest-alias.dmg" "$LATEST_ALIAS_URL" \
    || fail "랜딩 버튼 URL이 응답하지 않습니다: $LATEST_ALIAS_URL"
/usr/bin/cmp -s "$TEMP_DIR/latest-alias.dmg" "$RELEASE_DIR/$DMG_NAME" \
    || fail "랜딩 버튼이 주는 Mackor.dmg가 이번 릴리스의 DMG가 아닙니다."

echo "[7/7] 라이브 appcast 확인 중..."
LIVE_APPCAST="$TEMP_DIR/appcast.xml"
/usr/bin/curl --fail --silent --show-error --location --proto '=https' \
    --max-time 30 --output "$LIVE_APPCAST" \
    "${MACKOR_UPDATE_FEED_URL}?mackor-verify=$(/bin/date +%s)" \
    || fail "라이브 appcast를 내려받지 못했습니다: $MACKOR_UPDATE_FEED_URL"
/usr/bin/xmllint --noout "$LIVE_APPCAST" \
    || fail "라이브 appcast가 유효한 XML이 아닙니다."
NEW_BUILD_ITEMS="$(/usr/bin/xmllint --xpath "count(//*[local-name()='item'][*[local-name()='version']='$BUILD_NUMBER'])" "$LIVE_APPCAST")"

if [ "$PHASE" = "before-appcast" ]; then
    [ "$NEW_BUILD_ITEMS" = "0" ] \
        || fail "appcast가 자산 검증보다 먼저 게시되었습니다(공개 순서 위반). appcast는 항상 마지막입니다."
    echo ""
    echo "[완료] Mackor $VERSION ($BUILD_NUMBER) 자산 게시 검증(before-appcast)을 통과했습니다."
    echo "[다음] appcast.xml.pending으로 docs/appcast.xml을 교체·게시한 뒤 'final'로 다시 실행하세요."
    exit 0
fi

[ "$NEW_BUILD_ITEMS" = "1" ] \
    || fail "라이브 appcast에 빌드 $BUILD_NUMBER 항목이 정확히 하나 있어야 합니다(현재 $NEW_BUILD_ITEMS개). appcast 게시를 완료하세요."
FIRST_BUILD="$(/usr/bin/xmllint --xpath 'string((//*[local-name()="item"])[1]/*[local-name()="version"])' "$LIVE_APPCAST")"
[ "$FIRST_BUILD" = "$BUILD_NUMBER" ] \
    || fail "라이브 appcast 첫 항목이 이번 빌드($BUILD_NUMBER)가 아닙니다: ${FIRST_BUILD:-없음}"
FIRST_SHORT="$(/usr/bin/xmllint --xpath 'string((//*[local-name()="item"])[1]/*[local-name()="shortVersionString"])' "$LIVE_APPCAST")"
[ "$FIRST_SHORT" = "$VERSION" ] \
    || fail "라이브 appcast 첫 항목의 표시 버전이 $VERSION이 아닙니다: ${FIRST_SHORT:-없음}"
LIVE_ENCLOSURE_URL="$(/usr/bin/xmllint --xpath 'string((//*[local-name()="item"])[1]/*[local-name()="enclosure"]/@url)' "$LIVE_APPCAST")"
[ "$LIVE_ENCLOSURE_URL" = "$DOWNLOAD_BASE/$ARCHIVE_NAME" ] \
    || fail "라이브 appcast의 enclosure URL이 예상과 다릅니다: ${LIVE_ENCLOSURE_URL:-없음}"
LIVE_ENCLOSURE_LENGTH="$(/usr/bin/xmllint --xpath 'string((//*[local-name()="item"])[1]/*[local-name()="enclosure"]/@length)' "$LIVE_APPCAST")"
[ "$LIVE_ENCLOSURE_LENGTH" = "$(/usr/bin/stat -f%z "$RELEASE_DIR/$ARCHIVE_NAME")" ] \
    || fail "라이브 appcast의 enclosure length가 실제 ZIP 크기와 다릅니다."

# 라이브 피드가 저장소 docs/appcast.xml과 바이트 동일해야 한다(Pages 배포 지연이면 잠시 후 재시도).
if [ -f "$ROOT_DIR/docs/appcast.xml" ]; then
    /usr/bin/cmp -s "$LIVE_APPCAST" "$ROOT_DIR/docs/appcast.xml" \
        || fail "라이브 피드가 저장소 docs/appcast.xml과 다릅니다. GitHub Pages 배포가 지연 중이면 몇 분 후 다시 실행하세요."
fi

# 선택(권장): Sparkle 도구가 있으면 라이브 피드의 EdDSA 서명을 실제로 재검증한다.
if [ -x "${SPARKLE_SIGN_UPDATE:-}" ]; then
    LIVE_ENCLOSURE_SIG="$(/usr/bin/xmllint --xpath 'string((//*[local-name()="item"])[1]/*[local-name()="enclosure"]/@*[local-name()="edSignature"])' "$LIVE_APPCAST")"
    LIVE_NOTES_SIG="$(/usr/bin/xmllint --xpath 'string((//*[local-name()="item"])[1]/*[local-name()="releaseNotesLink"]/@*[local-name()="edSignature"])' "$LIVE_APPCAST")"
    [ -n "$LIVE_ENCLOSURE_SIG" ] || fail "라이브 appcast 첫 항목에 enclosure EdDSA 서명이 없습니다."
    "$SPARKLE_SIGN_UPDATE" --account "$SPARKLE_KEY_ACCOUNT" --verify "$LIVE_APPCAST" \
        || fail "라이브 appcast의 피드 EdDSA 서명 검증에 실패했습니다."
    "$SPARKLE_SIGN_UPDATE" --account "$SPARKLE_KEY_ACCOUNT" --verify "$RELEASE_DIR/$ARCHIVE_NAME" "$LIVE_ENCLOSURE_SIG" \
        || fail "라이브 appcast의 ZIP EdDSA 서명이 로컬 ZIP과 맞지 않습니다."
    if [ -n "$LIVE_NOTES_SIG" ]; then
        "$SPARKLE_SIGN_UPDATE" --account "$SPARKLE_KEY_ACCOUNT" --verify "$RELEASE_DIR/$NOTES_NAME" "$LIVE_NOTES_SIG" \
            || fail "라이브 appcast의 릴리스 노트 EdDSA 서명이 로컬 노트와 맞지 않습니다."
    fi
    echo "[안전] 라이브 피드의 EdDSA 서명(피드·ZIP·릴리스 노트)을 재검증했습니다."
else
    echo "[건너뜀] SPARKLE_SIGN_UPDATE가 없어 EdDSA 재검증을 생략했습니다(구조 검증은 모두 통과)."
fi

echo ""
echo "[완료] Mackor $VERSION ($BUILD_NUMBER) 게시 상태 검증(final)을 통과했습니다."
echo "[안전] 이 스크립트는 어떤 파일도 업로드·변경하지 않았습니다."
