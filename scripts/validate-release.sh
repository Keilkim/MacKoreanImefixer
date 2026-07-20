#!/bin/bash

# 로컬 공식 릴리스 산출물을 검증한다. 네트워크나 GitHub 상태는 변경하지 않는다.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"
SPARKLE_KEY_ACCOUNT="${SPARKLE_KEY_ACCOUNT:-ed25519}"

fail() {
    echo "[오류] $*" >&2
    exit 1
}

require_command() {
    command -v "$1" > /dev/null 2>&1 || fail "필요한 명령을 찾을 수 없습니다: $1"
}

if [ "$#" -ne 2 ]; then
    echo "사용법: scripts/validate-release.sh <version> <build-number>" >&2
    echo "필수 환경변수: MACKOR_UPDATE_FEED_URL, MACKOR_SPARKLE_PUBLIC_ED_KEY," >&2
    echo "SPARKLE_GENERATE_KEYS, SPARKLE_SIGN_UPDATE" >&2
    exit 2
fi

VERSION="$1"
BUILD_NUMBER="$2"
ARCHIVE_NAME="Mackor-$VERSION-$BUILD_NUMBER.zip"
PKG_NAME="Mackor-$VERSION-$BUILD_NUMBER.pkg"
DMG_NAME="Mackor-$VERSION-$BUILD_NUMBER.dmg"
NOTES_NAME="Mackor-$VERSION-$BUILD_NUMBER.md"
CHECKSUM_NAME="Mackor-$VERSION-$BUILD_NUMBER-SHA256SUMS.txt"
ARCHIVE_PATH="$DIST_DIR/$ARCHIVE_NAME"
PKG_PATH="$DIST_DIR/$PKG_NAME"
DMG_PATH="$DIST_DIR/$DMG_NAME"
NOTES_PATH="$DIST_DIR/$NOTES_NAME"
CHECKSUM_PATH="$DIST_DIR/$CHECKSUM_NAME"
APPCAST_PATH="$DIST_DIR/appcast.xml.pending"
EXPECTED_BUNDLE_IDENTIFIER="com.mackor.app"

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

[ -n "${MACKOR_UPDATE_FEED_URL:-}" ] || fail "MACKOR_UPDATE_FEED_URL이 필요합니다."
[ -n "${MACKOR_SPARKLE_PUBLIC_ED_KEY:-}" ] || fail "MACKOR_SPARKLE_PUBLIC_ED_KEY가 필요합니다."
[ -x "${SPARKLE_GENERATE_KEYS:-}" ] || fail "SPARKLE_GENERATE_KEYS를 실행할 수 없습니다."
[ -x "${SPARKLE_SIGN_UPDATE:-}" ] || fail "SPARKLE_SIGN_UPDATE를 실행할 수 없습니다."
[ -z "${SPARKLE_ED_KEY_FILE:-}" ] || fail "공식 릴리스 검증은 Sparkle Keychain 키만 허용합니다."

for tool in codesign ditto file find hdiutil lipo pkgutil shasum spctl stat xcrun xmllint; do
    require_command "$tool"
done

for required_file in \
    "$ARCHIVE_PATH" \
    "$PKG_PATH" \
    "$DMG_PATH" \
    "$NOTES_PATH" \
    "$CHECKSUM_PATH" \
    "$APPCAST_PATH"; do
    [ -s "$required_file" ] || fail "릴리스 산출물이 없거나 비어 있습니다: $required_file"
done

KEYCHAIN_PUBLIC_KEY="$("$SPARKLE_GENERATE_KEYS" --account "$SPARKLE_KEY_ACCOUNT" -p | /usr/bin/tr -d '\r\n')"
[ "$KEYCHAIN_PUBLIC_KEY" = "$MACKOR_SPARKLE_PUBLIC_ED_KEY" ] \
    || fail "Keychain의 Sparkle 공개키와 앱에 넣은 공개키가 다릅니다."

TEMP_BASE="${TMPDIR:-/tmp}"
TEMP_BASE="${TEMP_BASE%/}"
[ -n "$TEMP_BASE" ] || fail "TMPDIR이 안전한 임시 경로가 아닙니다."
TEMP_DIR="$(mktemp -d "$TEMP_BASE/mackor-release-validation.XXXXXX")"
DMG_MOUNT="$TEMP_DIR/dmg"
DMG_ATTACHED=0

cleanup() {
    if [ "$DMG_ATTACHED" = "1" ]; then
        hdiutil detach "$DMG_MOUNT" > /dev/null 2>&1 || true
    fi
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

plist_value() {
    local app_bundle="$1"
    local key="$2"
    /usr/libexec/PlistBuddy -c "Print :$key" "$app_bundle/Contents/Info.plist" 2>/dev/null
}

signature_value() {
    local app_bundle="$1"
    local key="$2"
    codesign -d --verbose=4 "$app_bundle" 2>&1 \
        | /usr/bin/sed -n "s/^$key=//p" \
        | /usr/bin/head -n 1
}

validate_embedded_app() {
    local app_bundle="$1"
    local label="$2"
    local executable="$app_bundle/Contents/MacOS/Mackor"
    local team_id
    local architectures

    [ -d "$app_bundle" ] || fail "$label 안에 Mackor.app이 없습니다."
    [ -f "$app_bundle/Contents/Info.plist" ] || fail "$label 앱에 Info.plist가 없습니다."
    [ -f "$executable" ] || fail "$label 앱에 실행 파일이 없습니다."
    [ "$(plist_value "$app_bundle" CFBundleIdentifier)" = "$EXPECTED_BUNDLE_IDENTIFIER" ] \
        || fail "$label 앱의 번들 식별자가 다릅니다."
    [ "$(plist_value "$app_bundle" CFBundleShortVersionString)" = "$VERSION" ] \
        || fail "$label 앱의 표시 버전이 다릅니다."
    [ "$(plist_value "$app_bundle" CFBundleVersion)" = "$BUILD_NUMBER" ] \
        || fail "$label 앱의 빌드 번호가 다릅니다."
    [ "$(plist_value "$app_bundle" SUFeedURL)" = "$MACKOR_UPDATE_FEED_URL" ] \
        || fail "$label 앱의 SUFeedURL이 다릅니다."
    [ "$(plist_value "$app_bundle" SUPublicEDKey)" = "$MACKOR_SPARKLE_PUBLIC_ED_KEY" ] \
        || fail "$label 앱의 SUPublicEDKey가 다릅니다."
    [ "$(plist_value "$app_bundle" SURequireSignedFeed)" = "true" ] \
        || fail "$label 앱의 SURequireSignedFeed가 비활성화됐습니다."
    [ "$(plist_value "$app_bundle" SUVerifyUpdateBeforeExtraction)" = "true" ] \
        || fail "$label 앱의 SUVerifyUpdateBeforeExtraction이 비활성화됐습니다."
    [ -d "$app_bundle/Contents/Frameworks/Sparkle.framework" ] \
        || fail "$label 앱에 Sparkle.framework가 없습니다."

    architectures="$(lipo -archs "$executable")"
    case " $architectures " in *" arm64 "*) ;; *) fail "$label 앱에 arm64가 없습니다." ;; esac
    case " $architectures " in *" x86_64 "*) ;; *) fail "$label 앱에 x86_64가 없습니다." ;; esac

    codesign --verify --deep --strict --verbose=2 "$app_bundle"
    codesign -d --verbose=4 "$app_bundle" 2>&1 \
        | /usr/bin/grep -F "Authority=Developer ID Application:" > /dev/null \
        || fail "$label 앱이 Developer ID Application으로 서명되지 않았습니다."
    team_id="$(signature_value "$app_bundle" TeamIdentifier)"
    [ "$team_id" = "$EXPECTED_TEAM_ID" ] \
        || fail "$label 앱의 TeamIdentifier가 업데이트 ZIP과 다릅니다."
    [ "$(signature_value "$app_bundle" CDHash)" = "$EXPECTED_CDHASH" ] \
        || fail "$label 앱의 코드 서명이 업데이트 ZIP 앱과 다릅니다."
}

ditto -x -k "$ARCHIVE_PATH" "$TEMP_DIR/update"
APP_BUNDLE="$TEMP_DIR/update/Mackor.app"
[ -d "$APP_BUNDLE" ] || fail "업데이트 ZIP 최상위에 Mackor.app이 없습니다."

EXPECTED_TEAM_ID="$(signature_value "$APP_BUNDLE" TeamIdentifier)"
EXPECTED_CDHASH="$(signature_value "$APP_BUNDLE" CDHash)"
echo "$EXPECTED_TEAM_ID" | /usr/bin/grep -Eq '^[A-Z0-9]{10}$' \
    || fail "최상위 앱의 TeamIdentifier를 확인할 수 없습니다."
[ -n "$EXPECTED_CDHASH" ] || fail "최상위 앱의 CDHash를 확인할 수 없습니다."

validate_embedded_app "$APP_BUNDLE" "업데이트 ZIP"
TOP_SIGNATURE="$(codesign -d --verbose=4 "$APP_BUNDLE" 2>&1)"
echo "$TOP_SIGNATURE" | /usr/bin/grep -Eq '^CodeDirectory .*flags=.*\(runtime\)' \
    || fail "최상위 앱에 hardened runtime 서명이 없습니다."
echo "$TOP_SIGNATURE" | /usr/bin/grep -Eq '^Timestamp=' \
    || fail "최상위 앱 서명에 secure timestamp가 없습니다."

# Sparkle의 XPC/Updater를 포함한 모든 Mach-O를 개별 검사한다.
# --deep은 서명 생성에 사용하지 않고 위의 전체 그래프 검증에만 사용했다.
while IFS= read -r -d '' candidate; do
    if file -b "$candidate" | /usr/bin/grep -q 'Mach-O'; then
        CANDIDATE_ARCHITECTURES="$(lipo -archs "$candidate")"
        case " $CANDIDATE_ARCHITECTURES " in
            *" arm64 "*) ;;
            *) fail "중첩 Mach-O에 arm64가 없습니다: $candidate ($CANDIDATE_ARCHITECTURES)" ;;
        esac
        case " $CANDIDATE_ARCHITECTURES " in
            *" x86_64 "*) ;;
            *) fail "중첩 Mach-O에 x86_64가 없습니다: $candidate ($CANDIDATE_ARCHITECTURES)" ;;
        esac
        codesign --verify --strict --verbose=2 "$candidate"
        NESTED_SIGNATURE="$(codesign -d --verbose=4 "$candidate" 2>&1)"
        echo "$NESTED_SIGNATURE" | /usr/bin/grep -F "Authority=Developer ID Application:" > /dev/null \
            || fail "중첩 Mach-O가 Developer ID Application으로 서명되지 않았습니다: $candidate"
        echo "$NESTED_SIGNATURE" | /usr/bin/grep -F "TeamIdentifier=$EXPECTED_TEAM_ID" > /dev/null \
            || fail "중첩 Mach-O의 TeamIdentifier가 최상위 앱과 다릅니다: $candidate"
        echo "$NESTED_SIGNATURE" | /usr/bin/grep -Eq '^CodeDirectory .*flags=.*\(runtime\)' \
            || fail "중첩 Mach-O에 hardened runtime 서명이 없습니다: $candidate"
        echo "$NESTED_SIGNATURE" | /usr/bin/grep -Eq '^Timestamp=' \
            || fail "중첩 Mach-O 서명에 secure timestamp가 없습니다: $candidate"
    fi
done < <(find "$APP_BUNDLE/Contents" -type f -print0)

xcrun stapler validate "$APP_BUNDLE"
spctl --assess --type execute --verbose=2 "$APP_BUNDLE"

PKG_SIGNATURE="$(pkgutil --check-signature "$PKG_PATH" 2>&1)"
echo "$PKG_SIGNATURE" | /usr/bin/grep -F "Developer ID Installer" > /dev/null \
    || fail "PKG가 Developer ID Installer로 서명되지 않았습니다."
echo "$PKG_SIGNATURE" | /usr/bin/grep -F "$EXPECTED_TEAM_ID" > /dev/null \
    || fail "PKG 서명 Team ID가 앱과 다릅니다."
xcrun stapler validate "$PKG_PATH"
spctl --assess --type install --verbose=2 "$PKG_PATH"
pkgutil --expand-full "$PKG_PATH" "$TEMP_DIR/pkg-expanded"
PKG_DISTRIBUTION="$TEMP_DIR/pkg-expanded/Distribution"
PKG_COMPONENT="$TEMP_DIR/pkg-expanded/component.pkg"
PKG_INFO="$PKG_COMPONENT/PackageInfo"
PKG_PAYLOAD="$PKG_COMPONENT/Payload"
PKG_APP="$PKG_PAYLOAD/Applications/Mackor.app"

[ -f "$PKG_DISTRIBUTION" ] || fail "PKG에 Distribution 메타데이터가 없습니다."
[ -f "$PKG_INFO" ] || fail "PKG에 component.pkg/PackageInfo가 없습니다."
[ "$(find "$TEMP_DIR/pkg-expanded" -type f -name PackageInfo -print | /usr/bin/wc -l | /usr/bin/tr -d '[:space:]')" = "1" ] \
    || fail "PKG에는 정확히 하나의 컴포넌트 영수증만 있어야 합니다."

PKG_RECEIPT_IDENTIFIER="$(xmllint --xpath 'string(/pkg-info/@identifier)' "$PKG_INFO")"
PKG_RECEIPT_VERSION="$(xmllint --xpath 'string(/pkg-info/@version)' "$PKG_INFO")"
PKG_INSTALL_LOCATION="$(xmllint --xpath 'string(/pkg-info/@install-location)' "$PKG_INFO")"
PKG_APP_BUNDLE_XPATH="/pkg-info/bundle[@path='./Applications/Mackor.app']"
PKG_BUNDLE_PATH="$(xmllint --xpath "string(($PKG_APP_BUNDLE_XPATH)[1]/@path)" "$PKG_INFO")"
PKG_BUNDLE_IDENTIFIER="$(xmllint --xpath "string(($PKG_APP_BUNDLE_XPATH)[1]/@id)" "$PKG_INFO")"
PKG_BUNDLE_SHORT_VERSION="$(xmllint --xpath "string(($PKG_APP_BUNDLE_XPATH)[1]/@CFBundleShortVersionString)" "$PKG_INFO")"
PKG_BUNDLE_BUILD_VERSION="$(xmllint --xpath "string(($PKG_APP_BUNDLE_XPATH)[1]/@CFBundleVersion)" "$PKG_INFO")"

[ "$PKG_RECEIPT_IDENTIFIER" = "$EXPECTED_BUNDLE_IDENTIFIER" ] \
    || fail "PKG 영수증 식별자가 다릅니다: ${PKG_RECEIPT_IDENTIFIER:-없음}"
[ "$PKG_RECEIPT_VERSION" = "$VERSION" ] \
    || fail "PKG 영수증 버전이 다릅니다: ${PKG_RECEIPT_VERSION:-없음}"
[ "$PKG_INSTALL_LOCATION" = "/" ] \
    || fail "PKG install-location은 정확히 /여야 합니다: ${PKG_INSTALL_LOCATION:-없음}"
[ "$PKG_BUNDLE_PATH" = "./Applications/Mackor.app" ] \
    || fail "PKG 앱 설치 경로가 정확히 /Applications/Mackor.app이 아닙니다: ${PKG_BUNDLE_PATH:-없음}"
[ "$PKG_BUNDLE_IDENTIFIER" = "$EXPECTED_BUNDLE_IDENTIFIER" ] \
    || fail "PKG 번들 메타데이터의 식별자가 다릅니다."
[ "$PKG_BUNDLE_SHORT_VERSION" = "$VERSION" ] \
    || fail "PKG 번들 메타데이터의 표시 버전이 다릅니다."
[ "$PKG_BUNDLE_BUILD_VERSION" = "$BUILD_NUMBER" ] \
    || fail "PKG 번들 메타데이터의 빌드 번호가 다릅니다."
[ "$(xmllint --xpath "count($PKG_APP_BUNDLE_XPATH)" "$PKG_INFO")" = "1" ] \
    || fail "PKG 영수증에는 최상위 Mackor 앱 번들 메타데이터가 정확히 하나여야 합니다."

# pkgbuild는 앱뿐 아니라 Sparkle의 framework·Updater·XPC도 bundle 항목으로
# 기록합니다. 이 정상 메타데이터를 거부하지 않되, 현재 고정한 Sparkle 2.9.4
# 그래프 밖의 번들이 추가되면 공개 릴리스를 중단합니다.
PKG_UNEXPECTED_BUNDLE_COUNT="$(xmllint --xpath "count(/pkg-info/bundle[not(
    @path='./Applications/Mackor.app'
    or @path='./Applications/Mackor.app/Contents/Frameworks/Sparkle.framework'
    or @path='./Applications/Mackor.app/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app'
    or @path='./Applications/Mackor.app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc'
    or @path='./Applications/Mackor.app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc'
)])" "$PKG_INFO")"
[ "$PKG_UNEXPECTED_BUNDLE_COUNT" = "0" ] \
    || fail "PKG 영수증에 예상하지 않은 중첩 번들이 있습니다."
[ "$(xmllint --xpath 'count(/pkg-info/bundle)' "$PKG_INFO")" = "5" ] \
    || fail "PKG 영수증의 Mackor/Sparkle 번들 수가 예상과 다릅니다."
[ "$(xmllint --xpath 'count(/pkg-info/scripts)' "$PKG_INFO")" = "0" ] \
    || fail "PKG에는 설치 경로 밖을 변경할 수 있는 설치 스크립트가 없어야 합니다."
[ ! -e "$PKG_COMPONENT/Scripts" ] && [ ! -L "$PKG_COMPONENT/Scripts" ] \
    || fail "PKG에는 설치 스크립트 payload가 없어야 합니다."

PKG_DISTRIBUTION_IDENTIFIER="$(xmllint --xpath 'string((/installer-gui-script/pkg-ref[@version])[1]/@id)' "$PKG_DISTRIBUTION")"
PKG_DISTRIBUTION_VERSION="$(xmllint --xpath 'string((/installer-gui-script/pkg-ref[@version])[1]/@version)' "$PKG_DISTRIBUTION")"
[ "$(xmllint --xpath 'count(/installer-gui-script/pkg-ref[@version])' "$PKG_DISTRIBUTION")" = "1" ] \
    || fail "PKG Distribution에는 버전이 지정된 pkg-ref가 정확히 하나여야 합니다."
[ "$PKG_DISTRIBUTION_IDENTIFIER" = "$EXPECTED_BUNDLE_IDENTIFIER" ] \
    || fail "PKG Distribution의 영수증 식별자가 다릅니다."
[ "$PKG_DISTRIBUTION_VERSION" = "$VERSION" ] \
    || fail "PKG Distribution의 영수증 버전이 다릅니다."
[ "$(xmllint --xpath "count(/installer-gui-script/pkg-ref[@id != '$EXPECTED_BUNDLE_IDENTIFIER'])" "$PKG_DISTRIBUTION")" = "0" ] \
    || fail "PKG Distribution에 예상하지 않은 영수증 식별자가 있습니다."
[ "$(xmllint --xpath 'normalize-space(string((/installer-gui-script/pkg-ref[@version])[1]))' "$PKG_DISTRIBUTION")" = "#component.pkg" ] \
    || fail "PKG Distribution이 예상한 로컬 component.pkg를 가리키지 않습니다."

[ -d "$PKG_PAYLOAD/Applications" ] && [ ! -L "$PKG_PAYLOAD/Applications" ] \
    || fail "PKG payload의 Applications가 실제 디렉터리가 아닙니다."
[ -d "$PKG_APP" ] && [ ! -L "$PKG_APP" ] \
    || fail "PKG payload에 실제 /Applications/Mackor.app 번들이 없습니다."
[ "$(find "$PKG_PAYLOAD" -mindepth 1 -maxdepth 1 -print | /usr/bin/wc -l | /usr/bin/tr -d '[:space:]')" = "1" ] \
    || fail "PKG payload 최상위에는 Applications만 있어야 합니다."
[ "$(find "$PKG_PAYLOAD/Applications" -mindepth 1 -maxdepth 1 -print | /usr/bin/wc -l | /usr/bin/tr -d '[:space:]')" = "1" ] \
    || fail "PKG는 /Applications/Mackor.app 외의 경로를 설치하려 합니다."
validate_embedded_app "$PKG_APP" "PKG"

codesign --verify --strict --verbose=2 "$DMG_PATH"
DMG_SIGNATURE="$(codesign -d --verbose=4 "$DMG_PATH" 2>&1)"
echo "$DMG_SIGNATURE" | /usr/bin/grep -F "Authority=Developer ID Application:" > /dev/null \
    || fail "DMG가 Developer ID Application으로 서명되지 않았습니다."
[ "$(signature_value "$DMG_PATH" TeamIdentifier)" = "$EXPECTED_TEAM_ID" ] \
    || fail "DMG 외곽 서명의 TeamIdentifier가 앱과 다릅니다."
xcrun stapler validate "$DMG_PATH"
hdiutil verify "$DMG_PATH" > /dev/null
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG_PATH"
mkdir "$DMG_MOUNT"
hdiutil attach "$DMG_PATH" -readonly -nobrowse -mountpoint "$DMG_MOUNT" > /dev/null
DMG_ATTACHED=1
validate_embedded_app "$DMG_MOUNT/Mackor.app" "DMG"
[ -L "$DMG_MOUNT/Applications" ] \
    || fail "DMG의 Applications 항목이 심볼릭 링크가 아닙니다."
[ "$(/usr/bin/readlink "$DMG_MOUNT/Applications")" = "/Applications" ] \
    || fail "DMG의 Applications 링크가 정확히 /Applications를 가리키지 않습니다."
hdiutil detach "$DMG_MOUNT" > /dev/null
DMG_ATTACHED=0

xmllint --noout "$APPCAST_PATH"
/usr/bin/grep -F -- "sparkle-sign-warning:" "$APPCAST_PATH" > /dev/null \
    || fail "appcast에 signed-feed 경고 블록이 없습니다."
/usr/bin/grep -F -- "sparkle-signatures:" "$APPCAST_PATH" > /dev/null \
    || fail "appcast에 signed-feed 서명 블록이 없습니다."
/usr/bin/grep -F -- "<sparkle:version>$BUILD_NUMBER</sparkle:version>" "$APPCAST_PATH" > /dev/null \
    || fail "appcast 빌드 번호가 일치하지 않습니다."
/usr/bin/grep -F -- "<sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>" "$APPCAST_PATH" > /dev/null \
    || fail "appcast 표시 버전이 일치하지 않습니다."
/usr/bin/grep -F -- "$ARCHIVE_NAME" "$APPCAST_PATH" > /dev/null \
    || fail "appcast가 업데이트 ZIP을 가리키지 않습니다."

ARCHIVE_SIGNATURE="$(xmllint --xpath 'string((//*[local-name()="enclosure"])[1]/@*[local-name()="edSignature"])' "$APPCAST_PATH")"
NOTES_SIGNATURE="$(xmllint --xpath 'string((//*[local-name()="releaseNotesLink"])[1]/@*[local-name()="edSignature"])' "$APPCAST_PATH")"
ARCHIVE_LENGTH="$(xmllint --xpath 'string((//*[local-name()="enclosure"])[1]/@length)' "$APPCAST_PATH")"
NOTES_LENGTH="$(xmllint --xpath 'string((//*[local-name()="releaseNotesLink"])[1]/@*[local-name()="length"])' "$APPCAST_PATH")"

echo "$ARCHIVE_SIGNATURE" | /usr/bin/grep -Eq '^[A-Za-z0-9+/]{86}==$' \
    || fail "업데이트 ZIP EdDSA 서명이 올바른 형식이 아닙니다."
echo "$NOTES_SIGNATURE" | /usr/bin/grep -Eq '^[A-Za-z0-9+/]{86}==$' \
    || fail "릴리스 노트 EdDSA 서명이 올바른 형식이 아닙니다."
[ "$ARCHIVE_LENGTH" = "$(stat -f%z "$ARCHIVE_PATH")" ] \
    || fail "appcast ZIP 크기가 실제 파일과 다릅니다."
[ "$NOTES_LENGTH" = "$(stat -f%z "$NOTES_PATH")" ] \
    || fail "appcast 릴리스 노트 크기가 실제 파일과 다릅니다."

APPCAST_VERIFY_PATH="$TEMP_DIR/appcast.xml"
cp "$APPCAST_PATH" "$APPCAST_VERIFY_PATH"
"$SPARKLE_SIGN_UPDATE" --account "$SPARKLE_KEY_ACCOUNT" --verify "$APPCAST_VERIFY_PATH"
"$SPARKLE_SIGN_UPDATE" --account "$SPARKLE_KEY_ACCOUNT" --verify "$ARCHIVE_PATH" "$ARCHIVE_SIGNATURE"
"$SPARKLE_SIGN_UPDATE" --account "$SPARKLE_KEY_ACCOUNT" --verify "$NOTES_PATH" "$NOTES_SIGNATURE"

if /usr/bin/grep -Eq '\{\{|\}\}|TODO|TBD|작성 필요|여기에' "$NOTES_PATH"; then
    fail "릴리스 노트에 템플릿 표시가 남아 있습니다."
fi

# appcast.xml.pending은 공개 산출물을 업로드한 뒤 마지막에 게시하는 피드이므로
# 체크섬 manifest에서 제외한다. 나머지 네 공개 payload는 누락·중복·추가를 허용하지 않는다.
CHECKSUM_LINE_COUNT=0
SEEN_ARCHIVE=0
SEEN_PKG=0
SEEN_DMG=0
SEEN_NOTES=0
while IFS= read -r CHECKSUM_LINE || [ -n "$CHECKSUM_LINE" ]; do
    CHECKSUM_LINE_COUNT=$((CHECKSUM_LINE_COUNT + 1))
    printf '%s\n' "$CHECKSUM_LINE" \
        | LC_ALL=C /usr/bin/grep -Eq '^[0-9a-f]{64}  [^/[:cntrl:]]+$' \
        || fail "SHA256SUMS 항목 형식이 올바르지 않습니다: $CHECKSUM_LINE"

    CHECKSUM_ENTRY_NAME="${CHECKSUM_LINE#*  }"
    case "$CHECKSUM_ENTRY_NAME" in
        "$ARCHIVE_NAME")
            [ "$SEEN_ARCHIVE" = "0" ] || fail "SHA256SUMS에 ZIP이 중복되었습니다."
            SEEN_ARCHIVE=1
            ;;
        "$PKG_NAME")
            [ "$SEEN_PKG" = "0" ] || fail "SHA256SUMS에 PKG가 중복되었습니다."
            SEEN_PKG=1
            ;;
        "$DMG_NAME")
            [ "$SEEN_DMG" = "0" ] || fail "SHA256SUMS에 DMG가 중복되었습니다."
            SEEN_DMG=1
            ;;
        "$NOTES_NAME")
            [ "$SEEN_NOTES" = "0" ] || fail "SHA256SUMS에 릴리스 노트가 중복되었습니다."
            SEEN_NOTES=1
            ;;
        *)
            fail "SHA256SUMS에 예상하지 않은 항목이 있습니다: $CHECKSUM_ENTRY_NAME"
            ;;
    esac
done < "$CHECKSUM_PATH"

[ "$CHECKSUM_LINE_COUNT" = "4" ] \
    || fail "SHA256SUMS에는 ZIP, PKG, DMG, 릴리스 노트의 네 항목만 있어야 합니다."
[ "$SEEN_ARCHIVE" = "1" ] && [ "$SEEN_PKG" = "1" ] \
    && [ "$SEEN_DMG" = "1" ] && [ "$SEEN_NOTES" = "1" ] \
    || fail "SHA256SUMS에 필요한 공개 릴리스 산출물이 누락되었습니다."

(
    cd "$DIST_DIR"
    shasum -a 256 -c "$CHECKSUM_NAME"
)

echo "[완료] Mackor $VERSION ($BUILD_NUMBER) 릴리스 산출물 검증을 통과했습니다."
echo "[주의] 이 검증은 업로드하지 않습니다. appcast.xml.pending은 모든 공개 산출물 업로드 후 마지막에 게시하세요."
