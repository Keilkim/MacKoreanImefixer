#!/bin/bash

# Mackor — 유니버설 바이너리 빌드 + PKG/DMG 인스톨러 생성
# Intel Mac + Apple Silicon Mac 모두 지원

set -Eeuo pipefail

APP_NAME="Mackor"
DISPLAY_NAME="Mackor - 한글 입력 보정"
VERSION="${VERSION:-1.10}"
BUILD_NUMBER="${BUILD_NUMBER:-16}"
IDENTIFIER="com.mackor.app"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PROJECT_DIR="$SCRIPT_DIR/Mackor"
# 개발용 직접 실행 결과는 검증된 `dist/releases` 후보와 절대 같은
# 디렉터리를 공유하지 않는다. 아래 정리 단계는 이 전용 경로만 비운다.
DEFAULT_DIST_DIR="$SCRIPT_DIR/dist/local-build"
DEFAULT_BUILD_DIR="$PROJECT_DIR/build/installer"
DIST_DIR="${DIST_DIR:-$DEFAULT_DIST_DIR}"
BUILD_DIR="${BUILD_DIR:-$DEFAULT_BUILD_DIR}"
ENTITLEMENTS="$PROJECT_DIR/$APP_NAME/$APP_NAME.entitlements"

# 배포 서명/공증은 환경변수를 설정했을 때만 활성화됩니다.
# 예:
#   APP_SIGN_IDENTITY="Developer ID Application: Example (TEAMID)"
#   INSTALLER_SIGN_IDENTITY="Developer ID Installer: Example (TEAMID)"
#   NOTARY_PROFILE="MackorNotary"
#   REQUIRE_SIGNING=1 REQUIRE_NOTARIZATION=1 ./build-installer.sh
APP_SIGN_IDENTITY="${APP_SIGN_IDENTITY:-}"
INSTALLER_SIGN_IDENTITY="${INSTALLER_SIGN_IDENTITY:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
REQUIRE_SIGNING="${REQUIRE_SIGNING:-0}"
REQUIRE_NOTARIZATION="${REQUIRE_NOTARIZATION:-0}"
MACKOR_UPDATE_FEED_URL="${MACKOR_UPDATE_FEED_URL:-}"
MACKOR_SPARKLE_PUBLIC_ED_KEY="${MACKOR_SPARKLE_PUBLIC_ED_KEY:-}"

trap 'echo "[오류] 인스톨러 생성에 실패했습니다 (스크립트 ${LINENO}행)." >&2' ERR

fail() {
    echo "[오류] $*" >&2
    exit 1
}

require_command() {
    if ! command -v "$1" > /dev/null 2>&1; then
        fail "필요한 명령을 찾을 수 없습니다: $1"
    fi
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

submit_for_notarization() {
    local artifact="$1"
    local result_file="$2"
    local status

    if ! xcrun notarytool submit "$artifact" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait \
        --output-format json > "$result_file"; then
        fail "공증 제출 명령이 실패했습니다: $(basename "$artifact")"
    fi

    status="$(/usr/bin/plutil -extract status raw -o - "$result_file" 2>/dev/null || true)"
    [ "$status" = "Accepted" ] \
        || fail "공증 결과가 Accepted가 아닙니다: $(basename "$artifact") (${status:-알 수 없음})"
    echo "  Accepted: $(basename "$artifact")"
}

identity_exists() {
    /usr/bin/security find-identity -v 2>/dev/null \
        | /usr/bin/grep -F -- "\"$1\"" > /dev/null
}

signature_value() {
    local target="$1"
    local key="$2"
    codesign -d --verbose=4 "$target" 2>&1 \
        | /usr/bin/sed -n "s/^$key=//p" \
        | /usr/bin/head -n 1
}

validate_signed_app_graph() {
    local app_bundle="$1"
    local expected_team_id="$2"
    local top_signature
    local candidate
    local candidate_architectures
    local nested_signature

    codesign --verify --deep --strict --verbose=2 "$app_bundle"
    top_signature="$(codesign -d --verbose=4 "$app_bundle" 2>&1)"
    printf '%s\n' "$top_signature" \
        | /usr/bin/grep -F "Authority=Developer ID Application:" > /dev/null \
        || fail "최상위 앱이 Developer ID Application으로 서명되지 않았습니다."
    [ "$(signature_value "$app_bundle" TeamIdentifier)" = "$expected_team_id" ] \
        || fail "최상위 앱의 TeamIdentifier가 인증서와 다릅니다."
    printf '%s\n' "$top_signature" \
        | /usr/bin/grep -Eq '^CodeDirectory .*flags=.*\(runtime\)' \
        || fail "최상위 앱에 hardened runtime 서명이 없습니다."
    printf '%s\n' "$top_signature" \
        | /usr/bin/grep -Eq '^Timestamp=' \
        || fail "최상위 앱 서명에 secure timestamp가 없습니다."

    while IFS= read -r -d '' candidate; do
        if file -b "$candidate" | /usr/bin/grep -q 'Mach-O'; then
            candidate_architectures="$(lipo -archs "$candidate")"
            case " $candidate_architectures " in
                *" arm64 "*) ;;
                *) fail "중첩 Mach-O에 arm64가 없습니다: $candidate" ;;
            esac
            case " $candidate_architectures " in
                *" x86_64 "*) ;;
                *) fail "중첩 Mach-O에 x86_64가 없습니다: $candidate" ;;
            esac
            codesign --verify --strict --verbose=2 "$candidate"
            nested_signature="$(codesign -d --verbose=4 "$candidate" 2>&1)"
            printf '%s\n' "$nested_signature" \
                | /usr/bin/grep -F "Authority=Developer ID Application:" > /dev/null \
                || fail "중첩 Mach-O가 Developer ID Application으로 서명되지 않았습니다: $candidate"
            printf '%s\n' "$nested_signature" \
                | /usr/bin/grep -F "TeamIdentifier=$expected_team_id" > /dev/null \
                || fail "중첩 Mach-O의 TeamIdentifier가 최상위 앱과 다릅니다: $candidate"
            printf '%s\n' "$nested_signature" \
                | /usr/bin/grep -Eq '^CodeDirectory .*flags=.*\(runtime\)' \
                || fail "중첩 Mach-O에 hardened runtime 서명이 없습니다: $candidate"
            printf '%s\n' "$nested_signature" \
                | /usr/bin/grep -Eq '^Timestamp=' \
                || fail "중첩 Mach-O 서명에 secure timestamp가 없습니다: $candidate"
        fi
    done < <(find "$app_bundle/Contents" -type f -print0)
}

sign_ad_hoc_app_graph() {
    local app_bundle="$1"
    local sparkle_framework="$app_bundle/Contents/Frameworks/Sparkle.framework"
    local sparkle_version="$sparkle_framework/Versions/B"
    local nested_target

    [ -d "$sparkle_framework" ] \
        || fail "개발용 앱에 Sparkle.framework가 없습니다."

    # 중첩 코드부터 바깥 번들 순서로 같은 ad-hoc 주체로 다시 서명한다.
    # 최상위 앱만 서명하면 Sparkle의 기존 Team ID가 남아 dyld library
    # validation에서 실행 직후 거부될 수 있다.
    for nested_target in \
        "$sparkle_version/Autoupdate" \
        "$sparkle_version/XPCServices/Downloader.xpc" \
        "$sparkle_version/XPCServices/Installer.xpc" \
        "$sparkle_version/Updater.app"; do
        [ -e "$nested_target" ] || fail "Sparkle 중첩 코드를 찾을 수 없습니다: $nested_target"
        codesign \
            --force \
            --timestamp=none \
            --preserve-metadata=identifier,entitlements,flags \
            --sign - \
            "$nested_target"
    done

    codesign \
        --force \
        --timestamp=none \
        --preserve-metadata=identifier,entitlements,flags \
        --sign - \
        "$sparkle_framework"
    codesign \
        --force \
        --timestamp=none \
        --entitlements "$ENTITLEMENTS" \
        --sign - \
        "$app_bundle"
}

validate_ad_hoc_app_graph() {
    local app_bundle="$1"
    local top_team_id
    local candidate
    local candidate_team_id

    codesign --verify --deep --strict --verbose=2 "$app_bundle"
    top_team_id="$(signature_value "$app_bundle" TeamIdentifier)"
    [ -n "$top_team_id" ] || fail "개발용 앱의 TeamIdentifier를 확인할 수 없습니다."

    while IFS= read -r -d '' candidate; do
        if file -b "$candidate" | /usr/bin/grep -q 'Mach-O'; then
            codesign --verify --strict --verbose=2 "$candidate"
            candidate_team_id="$(signature_value "$candidate" TeamIdentifier)"
            [ "$candidate_team_id" = "$top_team_id" ] \
                || fail "개발용 중첩 코드의 TeamIdentifier가 앱과 다릅니다: $candidate"
        fi
    done < <(find "$app_bundle/Contents" -type f -print0)
}

validate_removable_directory() {
    local directory="$1"
    local label="$2"
    local probe
    local suffix=""
    local canonical_directory

    case "$directory" in
        /*) ;;
        *) fail "$label 경로는 절대 경로여야 합니다: $directory" ;;
    esac

    case "$directory" in
        *'/../'*|*/..|*'/./'*|*/.|*'//'*|*/)
            fail "$label 경로에 ., .., 중복 또는 후행 슬래시를 사용할 수 없습니다: $directory"
            ;;
    esac

    probe="$directory"
    while [ ! -e "$probe" ] && [ ! -L "$probe" ]; do
        [ "$probe" != "/" ] || fail "$label 경로를 정규화할 수 없습니다: $directory"
        suffix="/$(basename "$probe")$suffix"
        probe="$(dirname "$probe")"
    done
    canonical_directory="$(/bin/realpath "$probe")$suffix"

    case "$canonical_directory" in
        /|/private/tmp|/private/var|/private/var/folders|"$SCRIPT_DIR"|"$PROJECT_DIR")
            fail "$label 경로가 너무 넓어 안전하게 정리할 수 없습니다: $canonical_directory"
            ;;
    esac

    case "$canonical_directory" in
        "$DEFAULT_DIST_DIR"|"$DEFAULT_BUILD_DIR"|/private/tmp/*|/private/var/folders/*|/var/folders/*)
            printf '%s\n' "$canonical_directory"
            ;;
        *)
            fail "$label 재정의는 기본 경로 또는 시스템 임시 디렉터리 아래만 허용합니다: $canonical_directory"
            ;;
    esac
}

for boolean_name in REQUIRE_SIGNING REQUIRE_NOTARIZATION; do
    case "${!boolean_name}" in
        0|1) ;;
        *) fail "$boolean_name 값은 0 또는 1이어야 합니다." ;;
    esac
done

DIST_DIR="$(validate_removable_directory "$DIST_DIR" "DIST_DIR")"
BUILD_DIR="$(validate_removable_directory "$BUILD_DIR" "BUILD_DIR")"
case "$DIST_DIR/" in
    "$BUILD_DIR/"*) fail "DIST_DIR은 BUILD_DIR 안에 둘 수 없습니다." ;;
esac
case "$BUILD_DIR/" in
    "$DIST_DIR/"*) fail "BUILD_DIR은 DIST_DIR 안에 둘 수 없습니다." ;;
esac

# 경로 정규화 후 파생 산출물 경로를 다시 계산한다.
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
FINAL_PKG="$DIST_DIR/Mackor_Installer.pkg"
FINAL_DMG="$DIST_DIR/Mackor.dmg"
UPDATE_ARCHIVE="$DIST_DIR/Mackor-$VERSION-$BUILD_NUMBER.zip"

case "$VERSION" in
    ''|*[!0-9A-Za-z.-]*) fail "VERSION에 사용할 수 없는 문자가 있습니다: $VERSION" ;;
esac
case "$BUILD_NUMBER" in
    ''|*[!0-9]*) fail "BUILD_NUMBER는 양의 정수여야 합니다: $BUILD_NUMBER" ;;
    0) fail "BUILD_NUMBER는 0보다 커야 합니다." ;;
esac

for tool in xcodebuild lipo codesign ditto file find pkgbuild productbuild hdiutil pkgutil; do
    require_command "$tool"
done

if [ ! -d "$PROJECT_DIR/$APP_NAME.xcodeproj" ]; then
    fail "Xcode 프로젝트를 찾을 수 없습니다: $PROJECT_DIR/$APP_NAME.xcodeproj"
fi

if [ ! -f "$ENTITLEMENTS" ]; then
    fail "entitlements 파일을 찾을 수 없습니다: $ENTITLEMENTS"
fi

if [ -n "$INSTALLER_SIGN_IDENTITY" ] && [ -z "$APP_SIGN_IDENTITY" ]; then
    fail "PKG만 서명할 수 없습니다. APP_SIGN_IDENTITY도 함께 설정하세요."
fi

if [ "$REQUIRE_SIGNING" != "1" ] \
    && { [ -n "$APP_SIGN_IDENTITY" ] || [ -n "$INSTALLER_SIGN_IDENTITY" ]; }; then
    fail "Developer ID 인증서를 지정하려면 REQUIRE_SIGNING=1을 명시하세요."
fi

if [ "$REQUIRE_SIGNING" = "1" ] \
    && { [ -z "$APP_SIGN_IDENTITY" ] || [ -z "$INSTALLER_SIGN_IDENTITY" ]; }; then
    fail "REQUIRE_SIGNING=1이면 APP_SIGN_IDENTITY와 INSTALLER_SIGN_IDENTITY가 모두 필요합니다."
fi

if [ "$REQUIRE_NOTARIZATION" = "1" ]; then
    if [ "$REQUIRE_SIGNING" != "1" ]; then
        fail "REQUIRE_NOTARIZATION=1이면 REQUIRE_SIGNING=1도 필요합니다."
    fi
    if [ -z "$NOTARY_PROFILE" ]; then
        fail "REQUIRE_NOTARIZATION=1이면 NOTARY_PROFILE이 필요합니다."
    fi
    if [ -z "$MACKOR_UPDATE_FEED_URL" ] || [ -z "$MACKOR_SPARKLE_PUBLIC_ED_KEY" ]; then
        fail "공식 릴리스에는 MACKOR_UPDATE_FEED_URL과 MACKOR_SPARKLE_PUBLIC_ED_KEY가 필요합니다."
    fi
fi

if [ -n "$NOTARY_PROFILE" ] && [ "$REQUIRE_NOTARIZATION" != "1" ]; then
    fail "NOTARY_PROFILE을 사용하려면 REQUIRE_NOTARIZATION=1을 명시해야 합니다."
fi

if [ -n "$MACKOR_UPDATE_FEED_URL" ]; then
    validate_https_url "$MACKOR_UPDATE_FEED_URL" "MACKOR_UPDATE_FEED_URL"
fi
if [ "$REQUIRE_NOTARIZATION" = "1" ]; then
    case "$MACKOR_UPDATE_FEED_URL" in
        */appcast.xml) ;;
        *) fail "공식 MACKOR_UPDATE_FEED_URL은 appcast.xml로 끝나야 합니다." ;;
    esac
fi

if [ -n "$MACKOR_SPARKLE_PUBLIC_ED_KEY" ]; then
    echo "$MACKOR_SPARKLE_PUBLIC_ED_KEY" | /usr/bin/grep -Eq '^[A-Za-z0-9+/]{43}=$' \
        || fail "MACKOR_SPARKLE_PUBLIC_ED_KEY가 올바른 Ed25519 공개키 형식이 아닙니다."
fi

if [ -n "$APP_SIGN_IDENTITY" ]; then
    case "$APP_SIGN_IDENTITY" in
        "Developer ID Application:"*) ;;
        *) fail "APP_SIGN_IDENTITY에는 Developer ID Application 인증서 이름을 지정하세요." ;;
    esac
    identity_exists "$APP_SIGN_IDENTITY" \
        || fail "키체인에서 앱 서명 인증서와 개인 키를 찾을 수 없습니다: $APP_SIGN_IDENTITY"
fi

if [ -n "$INSTALLER_SIGN_IDENTITY" ]; then
    case "$INSTALLER_SIGN_IDENTITY" in
        "Developer ID Installer:"*) ;;
        *) fail "INSTALLER_SIGN_IDENTITY에는 Developer ID Installer 인증서 이름을 지정하세요." ;;
    esac
    identity_exists "$INSTALLER_SIGN_IDENTITY" \
        || fail "키체인에서 인스톨러 서명 인증서와 개인 키를 찾을 수 없습니다: $INSTALLER_SIGN_IDENTITY"
fi

if [ "$REQUIRE_SIGNING" = "1" ]; then
    APP_TEAM_ID="$(printf '%s\n' "$APP_SIGN_IDENTITY" | /usr/bin/sed -nE 's/.*\(([A-Z0-9]{10})\)$/\1/p')"
    INSTALLER_TEAM_ID="$(printf '%s\n' "$INSTALLER_SIGN_IDENTITY" | /usr/bin/sed -nE 's/.*\(([A-Z0-9]{10})\)$/\1/p')"
    [ -n "$APP_TEAM_ID" ] || fail "앱 서명 인증서 이름에서 Team ID를 확인할 수 없습니다."
    [ "$INSTALLER_TEAM_ID" = "$APP_TEAM_ID" ] \
        || fail "앱과 인스톨러 서명 인증서의 Team ID가 다릅니다."
else
    APP_TEAM_ID=""
fi

if [ "$REQUIRE_NOTARIZATION" = "1" ]; then
    if [ -z "$APP_SIGN_IDENTITY" ] || [ -z "$INSTALLER_SIGN_IDENTITY" ]; then
        fail "공증하려면 앱과 인스톨러 Developer ID 인증서가 모두 필요합니다."
    fi
    require_command xcrun
    require_command ditto
    require_command spctl
    require_command plutil
    xcrun --find notarytool > /dev/null \
        || fail "notarytool을 사용할 수 없습니다. 최신 Xcode를 확인하세요."
    xcrun --find stapler > /dev/null \
        || fail "stapler를 사용할 수 없습니다. 최신 Xcode를 확인하세요."
fi

echo ""
echo "========================================="
echo "  $DISPLAY_NAME v$VERSION — 인스톨러 생성"
echo "========================================="
echo ""

if [ -n "$APP_SIGN_IDENTITY" ]; then
    echo "[서명] 앱: $APP_SIGN_IDENTITY"
else
    echo "[경고] Developer ID Application 인증서가 없습니다."
    echo "       앱은 로컬 테스트용 ad-hoc 서명으로 생성됩니다."
fi

if [ -n "$INSTALLER_SIGN_IDENTITY" ]; then
    echo "[서명] PKG: $INSTALLER_SIGN_IDENTITY"
else
    echo "[경고] Developer ID Installer 인증서가 없습니다. PKG는 미서명 상태입니다."
fi

if [ "$REQUIRE_NOTARIZATION" = "1" ]; then
    echo "[공증] 키체인 프로필: $NOTARY_PROFILE"
else
    echo "[경고] NOTARY_PROFILE이 없어 공증하지 않습니다."
fi
echo ""

# 이전 산출물 정리
rm -rf "$BUILD_DIR" "$DIST_DIR"
mkdir -p "$BUILD_DIR" "$DIST_DIR"

# ─────────────────────────────────────
# 1. 유니버설 바이너리 빌드 (arm64 + x86_64)
# ─────────────────────────────────────

cd "$PROJECT_DIR"
if [ "$REQUIRE_SIGNING" = "1" ]; then
    echo "[1/6] Xcode 유니버설 Archive 생성 중..."
    XCODE_ARCHIVE="$BUILD_DIR/$APP_NAME.xcarchive"
    EXPORT_DIR="$BUILD_DIR/export"
    EXPORT_OPTIONS="$BUILD_DIR/ExportOptions.plist"

    cat > "$EXPORT_OPTIONS" << EXPORTPLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>signingCertificate</key>
    <string>Developer ID Application</string>
    <key>teamID</key>
    <string>$APP_TEAM_ID</string>
    <key>manageAppVersionAndBuildNumber</key>
    <false/>
</dict>
</plist>
EXPORTPLIST

    xcodebuild \
        -project "$APP_NAME.xcodeproj" \
        -scheme "$APP_NAME" \
        -configuration Release \
        -archivePath "$XCODE_ARCHIVE" \
        archive \
        ARCHS="arm64 x86_64" \
        ONLY_ACTIVE_ARCH=NO \
        MARKETING_VERSION="$VERSION" \
        CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
        ENABLE_CODE_COVERAGE=NO \
        ENABLE_DEBUG_DYLIB=NO \
        CODE_SIGN_STYLE=Manual \
        CODE_SIGN_IDENTITY="$APP_SIGN_IDENTITY" \
        DEVELOPMENT_TEAM="$APP_TEAM_ID" \
        MACKOR_UPDATE_FEED_URL="$MACKOR_UPDATE_FEED_URL" \
        MACKOR_SPARKLE_PUBLIC_ED_KEY="$MACKOR_SPARKLE_PUBLIC_ED_KEY"

    echo "[2/6] Developer ID Archive 내보내는 중..."
    xcodebuild \
        -exportArchive \
        -archivePath "$XCODE_ARCHIVE" \
        -exportPath "$EXPORT_DIR" \
        -exportOptionsPlist "$EXPORT_OPTIONS"

    EXPORTED_APP="$(find "$EXPORT_DIR" -maxdepth 2 -type d -name "$APP_NAME.app" -print -quit)"
    [ -n "$EXPORTED_APP" ] && [ -d "$EXPORTED_APP" ] \
        || fail "Xcode가 내보낸 앱을 찾을 수 없습니다."

    echo "[3/6] Xcode 서명 유니버설 앱 준비 중..."
    ditto "$EXPORTED_APP" "$APP_BUNDLE"
else
    echo "[1/6] Apple Silicon (arm64) 개발용 빌드 중..."
    xcodebuild \
        -project "$APP_NAME.xcodeproj" \
        -scheme "$APP_NAME" \
        -configuration Release \
        -arch arm64 \
        -derivedDataPath "$BUILD_DIR/DerivedData-arm64" \
        build \
        CONFIGURATION_BUILD_DIR="$BUILD_DIR/arm64" \
        MARKETING_VERSION="$VERSION" \
        CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
        ENABLE_CODE_COVERAGE=NO \
        ENABLE_DEBUG_DYLIB=NO \
        CODE_SIGNING_ALLOWED=NO \
        CODE_SIGNING_REQUIRED=NO \
        MACKOR_UPDATE_FEED_URL="$MACKOR_UPDATE_FEED_URL" \
        MACKOR_SPARKLE_PUBLIC_ED_KEY="$MACKOR_SPARKLE_PUBLIC_ED_KEY" \
        -quiet

    echo "[2/6] Intel (x86_64) 개발용 빌드 중..."
    xcodebuild \
        -project "$APP_NAME.xcodeproj" \
        -scheme "$APP_NAME" \
        -configuration Release \
        -arch x86_64 \
        -derivedDataPath "$BUILD_DIR/DerivedData-x86_64" \
        build \
        CONFIGURATION_BUILD_DIR="$BUILD_DIR/x86_64" \
        MARKETING_VERSION="$VERSION" \
        CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
        ENABLE_CODE_COVERAGE=NO \
        ENABLE_DEBUG_DYLIB=NO \
        CODE_SIGNING_ALLOWED=NO \
        CODE_SIGNING_REQUIRED=NO \
        MACKOR_UPDATE_FEED_URL="$MACKOR_UPDATE_FEED_URL" \
        MACKOR_SPARKLE_PUBLIC_ED_KEY="$MACKOR_SPARKLE_PUBLIC_ED_KEY" \
        -quiet

    ARM_APP="$BUILD_DIR/arm64/$APP_NAME.app"
    INTEL_APP="$BUILD_DIR/x86_64/$APP_NAME.app"
    if [ ! -d "$ARM_APP" ] || [ ! -d "$INTEL_APP" ]; then
        fail "아키텍처별 앱 산출물을 찾을 수 없습니다."
    fi

    echo "[3/6] 개발용 유니버설 앱 생성 중..."
    ditto "$ARM_APP" "$APP_BUNDLE"
    lipo -create \
        "$ARM_APP/Contents/MacOS/$APP_NAME" \
        "$INTEL_APP/Contents/MacOS/$APP_NAME" \
        -output "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
fi

ARCHITECTURES="$(lipo -archs "$APP_BUNDLE/Contents/MacOS/$APP_NAME")"
case " $ARCHITECTURES " in
    *" arm64 "*) ;;
    *) fail "유니버설 앱에 arm64 아키텍처가 없습니다: $ARCHITECTURES" ;;
esac
case " $ARCHITECTURES " in
    *" x86_64 "*) ;;
    *) fail "유니버설 앱에 x86_64 아키텍처가 없습니다: $ARCHITECTURES" ;;
esac
echo "  아키텍처: $ARCHITECTURES"

BUILT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_BUNDLE/Contents/Info.plist")"
if [ "$BUILT_VERSION" != "$VERSION" ]; then
    fail "앱 버전이 일치하지 않습니다 (예상 $VERSION, 실제 $BUILT_VERSION)."
fi

BUILT_BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_BUNDLE/Contents/Info.plist")"
if [ "$BUILT_BUILD_NUMBER" != "$BUILD_NUMBER" ]; then
    fail "앱 빌드 번호가 일치하지 않습니다 (예상 $BUILD_NUMBER, 실제 $BUILT_BUILD_NUMBER)."
fi

if [ "$REQUIRE_NOTARIZATION" = "1" ]; then
    BUILT_FEED_URL="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true)"
    BUILT_PUBLIC_ED_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true)"
    BUILT_REQUIRE_SIGNED_FEED="$(/usr/libexec/PlistBuddy -c 'Print :SURequireSignedFeed' "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true)"
    BUILT_VERIFY_BEFORE_EXTRACTION="$(/usr/libexec/PlistBuddy -c 'Print :SUVerifyUpdateBeforeExtraction' "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true)"

    [ "$BUILT_FEED_URL" = "$MACKOR_UPDATE_FEED_URL" ] \
        || fail "빌드된 앱의 SUFeedURL이 공식 피드 URL과 다릅니다."
    [ "$BUILT_PUBLIC_ED_KEY" = "$MACKOR_SPARKLE_PUBLIC_ED_KEY" ] \
        || fail "빌드된 앱에 지정한 Sparkle 공개키가 포함되지 않았습니다."
    [ "$BUILT_REQUIRE_SIGNED_FEED" = "true" ] \
        || fail "공식 빌드에는 SURequireSignedFeed=true가 필요합니다."
    [ "$BUILT_VERIFY_BEFORE_EXTRACTION" = "true" ] \
        || fail "공식 빌드에는 SUVerifyUpdateBeforeExtraction=true가 필요합니다."
    [ -d "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework" ] \
        || fail "공식 빌드에 Sparkle.framework가 포함되지 않았습니다."
fi

if [ "$REQUIRE_SIGNING" = "1" ]; then
    # Xcode archive/export가 모든 Sparkle 중첩 코드를 inside-out으로 서명했다.
    # 여기서 앱 외곽을 다시 서명하면 XPC/Updater의 서명 관계를 망가뜨릴 수 있다.
    validate_signed_app_graph "$APP_BUNDLE" "$APP_TEAM_ID"
else
    sign_ad_hoc_app_graph "$APP_BUNDLE"
    validate_ad_hoc_app_graph "$APP_BUNDLE"
fi
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

# PKG와 DMG 안에도 티켓이 스테이플된 앱이 들어가도록 앱을 먼저 공증한다.
if [ "$REQUIRE_NOTARIZATION" = "1" ]; then
    NOTARY_APP_ARCHIVE="$BUILD_DIR/Mackor_App_Notarization.zip"
    ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$NOTARY_APP_ARCHIVE"

    echo "  업데이트 앱을 공증 제출 중..."
    submit_for_notarization "$NOTARY_APP_ARCHIVE" "$BUILD_DIR/notary-app.json"
    xcrun stapler staple "$APP_BUNDLE"
    xcrun stapler validate "$APP_BUNDLE"
    codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
    spctl --assess --type execute --verbose=2 "$APP_BUNDLE"
fi

# ─────────────────────────────────────
# 2. PKG 인스톨러 생성
# ─────────────────────────────────────

echo "[4/6] PKG 인스톨러 생성 중..."

PAYLOAD_DIR="$BUILD_DIR/payload"
mkdir -p "$PAYLOAD_DIR/Applications"
ditto "$APP_BUNDLE" "$PAYLOAD_DIR/Applications/$APP_NAME.app"

# Installer의 postinstall은 root 세션에서 실행되므로 GUI 앱을 열지 않습니다.
# 설치 후 사용자가 /Applications/Mackor.app을 직접 실행합니다.
pkgbuild \
    --root "$PAYLOAD_DIR" \
    --identifier "$IDENTIFIER" \
    --version "$VERSION" \
    --install-location "/" \
    "$BUILD_DIR/component.pkg"

RESOURCES_DIR="$BUILD_DIR/resources"
mkdir -p "$RESOURCES_DIR"
cat > "$RESOURCES_DIR/welcome.html" << 'WELCOMEHTML'
<!DOCTYPE html>
<html lang="ko">
<head><meta charset="UTF-8"></head>
<body style="font-family: -apple-system, sans-serif; padding: 20px;">
<h2>Mackor — 한글 입력 보정</h2>
<p>macOS 한글 조합을 제대로 지원하지 않는 앱에서 두벌식 한글 입력을 보정합니다.</p>
<p><b>설치 후 필요한 설정:</b></p>
<ol>
<li><code>/Applications/Mackor.app</code>을 실행합니다.</li>
<li>메뉴바에 나타난 <b>Mackor</b>을 클릭합니다.</li>
<li><b>손쉬운 사용</b> 권한을 허용합니다.<br>
(시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용)</li>
<li>메뉴에서 <b>전체 Mac</b> 또는 <b>선택한 앱만</b>을 고릅니다.<br>
전체 Mac을 선택하면 앱을 따로 등록할 필요가 없습니다.</li>
</ol>
</body></html>
WELCOMEHTML

cat > "$RESOURCES_DIR/conclusion.html" << 'CONCLUSIONHTML'
<!DOCTYPE html>
<html lang="ko">
<head><meta charset="UTF-8"></head>
<body style="font-family: -apple-system, sans-serif; padding: 20px;">
<h2>Mackor 설치가 완료되었습니다</h2>
<ol>
<li><b>응용 프로그램</b> 폴더에서 <b>Mackor</b>를 실행합니다.</li>
<li>첫 안내에서 <b>손쉬운 사용 설정 열기</b>를 누르고 Mackor를 켭니다.</li>
<li>메뉴바의 <b>Mackor</b>에서 자동 교정 범위를 선택합니다.</li>
</ol>
<p>터미널 명령이나 Apple 계정 로그인은 필요하지 않습니다.</p>
</body></html>
CONCLUSIONHTML

cat > "$BUILD_DIR/distribution.xml" << DISTXML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>$DISPLAY_NAME</title>
    <welcome file="welcome.html" mime-type="text/html"/>
    <conclusion file="conclusion.html" mime-type="text/html"/>
    <options customize="never" require-scripts="false"/>
    <choices-outline>
        <line choice="default"/>
    </choices-outline>
    <choice id="default" title="$APP_NAME">
        <pkg-ref id="$IDENTIFIER"/>
    </choice>
    <pkg-ref id="$IDENTIFIER" version="$VERSION" onConclusion="none">component.pkg</pkg-ref>
</installer-gui-script>
DISTXML

PRODUCTBUILD_ARGS=(
    --distribution "$BUILD_DIR/distribution.xml"
    --resources "$RESOURCES_DIR"
    --package-path "$BUILD_DIR"
)
if [ -n "$INSTALLER_SIGN_IDENTITY" ]; then
    PRODUCTBUILD_ARGS+=(--sign "$INSTALLER_SIGN_IDENTITY" --timestamp)
fi

productbuild "${PRODUCTBUILD_ARGS[@]}" "$FINAL_PKG"

if [ -n "$INSTALLER_SIGN_IDENTITY" ]; then
    pkgutil --check-signature "$FINAL_PKG"
fi
echo "  PKG: $FINAL_PKG"

# ─────────────────────────────────────
# 3. DMG 생성 (드래그 앤 드롭 방식)
# ─────────────────────────────────────

echo "[5/6] DMG 생성 중..."

DMG_TEMP="$BUILD_DIR/dmg_contents"
mkdir -p "$DMG_TEMP"
ditto "$APP_BUNDLE" "$DMG_TEMP/$APP_NAME.app"
ln -s /Applications "$DMG_TEMP/Applications"

hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$DMG_TEMP" \
    -ov \
    -format UDZO \
    "$FINAL_DMG"

if [ -n "$APP_SIGN_IDENTITY" ]; then
    codesign --force --timestamp --sign "$APP_SIGN_IDENTITY" "$FINAL_DMG"
    codesign --verify --verbose=2 "$FINAL_DMG"
fi
echo "  DMG: $FINAL_DMG"

# ─────────────────────────────────────
# 4. 선택적 Apple 공증 및 스테이플
# ─────────────────────────────────────

echo "[6/6] 서명/공증 상태 확인 중..."
if [ "$REQUIRE_NOTARIZATION" = "1" ]; then
    # PKG와 DMG는 서로 다른 배포물이다. 각각 Accepted를 받아야 한 형식의
    # 성공이 다른 형식의 실패를 가리지 않는다. 앱은 패키징 전에 완료했다.
    echo "  PKG를 공증 제출 중..."
    submit_for_notarization "$FINAL_PKG" "$BUILD_DIR/notary-pkg.json"
    echo "  DMG를 공증 제출 중..."
    submit_for_notarization "$FINAL_DMG" "$BUILD_DIR/notary-dmg.json"

    xcrun stapler staple "$FINAL_PKG"
    xcrun stapler validate "$FINAL_PKG"
    xcrun stapler staple "$FINAL_DMG"
    xcrun stapler validate "$FINAL_DMG"

    # Sparkle용 업데이트 파일은 반드시 스테이플된 앱으로 다시 만든다.
    ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$UPDATE_ARCHIVE"

    # --deep은 서명 수단이 아니라, Xcode가 서명했어야 할 모든 중첩 코드를
    # 빠짐없이 검증하는 최종 게이트로만 사용한다.
    codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
    spctl --assess --type execute --verbose=2 "$APP_BUNDLE"
    spctl --assess --type install --verbose=2 "$FINAL_PKG"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$FINAL_DMG"
else
    echo "  공증 건너뜀 (NOTARY_PROFILE 미설정)"
fi

rm -rf "$BUILD_DIR"

echo ""
echo "========================================="
echo "  완료! Mackor v$VERSION 배포 파일"
echo "========================================="
echo ""
echo "  1. Mackor_Installer.pkg  (Installer 설치)"
echo "  2. Mackor.dmg            (Applications로 드래그)"
if [ -f "$UPDATE_ARCHIVE" ]; then
    echo "  3. $(basename "$UPDATE_ARCHIVE")  (서명된 자동 업데이트)"
fi
echo ""
echo "  위치: $DIST_DIR/"
if [ -z "$APP_SIGN_IDENTITY" ] || [ -z "$INSTALLER_SIGN_IDENTITY" ]; then
    echo "  상태: 개발용 산출물 — 공개 배포 전 Developer ID 서명과 공증을 권장합니다."
elif [ "$REQUIRE_NOTARIZATION" != "1" ]; then
    echo "  상태: Developer ID 서명됨 — Apple 공증은 받지 않았습니다."
else
    echo "  상태: Developer ID 서명 및 Apple 공증 완료"
fi
echo ""
