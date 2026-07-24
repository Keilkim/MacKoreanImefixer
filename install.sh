#!/bin/bash

# Mackor 로컬 빌드 및 설치 스크립트
# 사용법: ./install.sh

set -Eeuo pipefail

APP_NAME="Mackor"
EXPECTED_IDENTIFIER="com.mackor.app"
VERSION="${VERSION:-1.4}"
BUILD_NUMBER="${BUILD_NUMBER:-10}"
INSTALL_DIR="/Applications"
APP_PATH="$INSTALL_DIR/$APP_NAME.app"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/Mackor"
BUILD_ROOT="$PROJECT_DIR/build/local-install"
PRODUCT_DIR="$BUILD_ROOT/products"
BUILT_APP="$PRODUCT_DIR/$APP_NAME.app"

trap 'echo "[오류] 설치에 실패했습니다 (스크립트 ${LINENO}행)." >&2' ERR
trap 'rm -rf "$BUILD_ROOT"' EXIT

fail() {
    echo "[오류] $*" >&2
    exit 1
}

signature_value() {
    local target="$1"
    local key="$2"
    codesign -d --verbose=4 "$target" 2>&1 \
        | /usr/bin/sed -n "s/^$key=//p" \
        | /usr/bin/head -n 1
}

# Sparkle framework와 중첩 XPC/Updater가 앱과 다른 Team ID로 남으면
# codesign --deep 검증을 통과해도 hardened runtime에서 dyld가 로드를 거부할
# 수 있습니다. 소스 설치본도 모든 Mach-O의 서명 주체를 명시적으로 비교합니다.
validate_local_app_graph() {
    local app_bundle="$1"
    local top_team_id
    local candidate
    local candidate_team_id

    codesign --verify --deep --strict --verbose=2 "$app_bundle"
    top_team_id="$(signature_value "$app_bundle" TeamIdentifier)"
    [ -n "$top_team_id" ] || fail "앱의 TeamIdentifier를 확인할 수 없습니다."

    while IFS= read -r -d '' candidate; do
        if file -b "$candidate" | /usr/bin/grep -q 'Mach-O'; then
            codesign --verify --strict --verbose=2 "$candidate"
            candidate_team_id="$(signature_value "$candidate" TeamIdentifier)"
            [ "$candidate_team_id" = "$top_team_id" ] \
                || fail "중첩 코드의 TeamIdentifier가 앱과 다릅니다: $candidate"
        fi
    done < <(find "$app_bundle/Contents" -type f -print0)
}

echo ""
echo "========================================="
echo "  Mackor v$VERSION — 한글 입력 보정 앱 설치"
echo "========================================="
echo ""

if ! command -v xcodebuild > /dev/null 2>&1 \
        || ! xcodebuild -version > /dev/null 2>&1; then
    echo "[오류] 이 소스 설치에는 전체 Xcode가 필요합니다." >&2
    echo "  Xcode를 설치하고 한 번 실행한 뒤 다시 시도하세요." >&2
    echo "  Xcode가 이미 있다면 활성 개발자 경로를 확인하세요:" >&2
    echo "    sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
    exit 1
fi

if ! command -v ditto > /dev/null 2>&1; then
    fail "ditto 명령을 찾을 수 없습니다."
fi

if ! command -v codesign > /dev/null 2>&1; then
    fail "codesign 명령을 찾을 수 없습니다."
fi

if [ ! -d "$PROJECT_DIR/$APP_NAME.xcodeproj" ]; then
    fail "Xcode 프로젝트를 찾을 수 없습니다."
fi

rm -rf "$BUILD_ROOT"
mkdir -p "$BUILD_ROOT"

echo "[1/5] 프로젝트 빌드 중..."
cd "$PROJECT_DIR"
xcodebuild \
    -project "$APP_NAME.xcodeproj" \
    -scheme "$APP_NAME" \
    -configuration Release \
    -destination "platform=macOS" \
    -derivedDataPath "$BUILD_ROOT/DerivedData" \
    build \
    CONFIGURATION_BUILD_DIR="$PRODUCT_DIR" \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    ENABLE_CODE_COVERAGE=NO \
    ENABLE_DEBUG_DYLIB=NO \
    ENABLE_HARDENED_RUNTIME=NO \
    -quiet

if [ ! -d "$BUILT_APP" ]; then
    fail "빌드 산출물을 찾을 수 없습니다: $BUILT_APP"
fi

BUILT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$BUILT_APP/Contents/Info.plist")"
if [ "$BUILT_VERSION" != "$VERSION" ]; then
    fail "빌드 버전이 일치하지 않습니다 (예상 $VERSION, 실제 $BUILT_VERSION)."
fi
BUILT_BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$BUILT_APP/Contents/Info.plist")"
if [ "$BUILT_BUILD_NUMBER" != "$BUILD_NUMBER" ]; then
    fail "빌드 번호가 일치하지 않습니다 (예상 $BUILD_NUMBER, 실제 $BUILT_BUILD_NUMBER)."
fi
BUILT_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$BUILT_APP/Contents/Info.plist")"
if [ "$BUILT_IDENTIFIER" != "$EXPECTED_IDENTIFIER" ]; then
    fail "빌드 앱 ID가 일치하지 않습니다 (예상 $EXPECTED_IDENTIFIER, 실제 $BUILT_IDENTIFIER)."
fi
# Developer ID로 재서명해 손쉬운 사용 권한이 재설치를 넘어 유지되게 합니다.
#
# ad-hoc 서명은 빌드 내용이 바뀔 때마다 코드 해시가 달라져 TCC가 다른 앱으로
# 인식합니다. 그래서 새 빌드를 설치할 때마다 권한을 다시 승인해야 했습니다.
# 안정적인 Developer ID identity로 서명하면 designated requirement가 동일하게
# 유지되어 승인이 남습니다.
#
# 인증서가 없는 기여자 환경에서는 조용히 건너뛰고 기존 ad-hoc 동작을 유지합니다.
# 이 재서명은 로컬 개발 설치용이며, 공식 배포 서명·공증은 build-installer.sh가
# REQUIRE_SIGNING/REQUIRE_NOTARIZATION 경로에서 따로 수행합니다.
LOCAL_SIGN_IDENTITY="${LOCAL_SIGN_IDENTITY:-$(
    security find-identity -v -p codesigning 2>/dev/null \
        | /usr/bin/sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' \
        | /usr/bin/head -n 1
)}"

if [ -n "$LOCAL_SIGN_IDENTITY" ]; then
    echo "  Developer ID로 재서명 중: $LOCAL_SIGN_IDENTITY"
    resign_failed=0

    # validate_local_app_graph가 검사하는 것과 **같은 기준**으로 서명합니다.
    # 검증기는 Contents 아래의 모든 Mach-O 파일을 훑어 Team ID 일치를 요구하므로,
    # 번들 확장자(.app/.xpc/.framework)만 서명하면 Sparkle의 Autoupdate 같은
    # 단독 실행 파일이 원래 서명을 유지한 채 남아 검증에서 걸립니다.
    #
    # 경로 깊이 역순(깊은 것부터)으로 서명해야 상위 번들의 봉인이 유효해집니다.
    while IFS= read -r macho; do
        if ! codesign --force --sign "$LOCAL_SIGN_IDENTITY" --options runtime \
            --timestamp=none "$macho" > /dev/null 2>&1; then
            echo "  [경고] 중첩 코드 서명 실패: $macho" >&2
            resign_failed=1
        fi
    done < <(
        find "$BUILT_APP/Contents" -type f \
            -exec sh -c 'file -b "$1" | grep -q "Mach-O" && printf "%s\n" "$1"' _ {} \; \
            | /usr/bin/awk -F/ '{ print NF"\t"$0 }' \
            | /usr/bin/sort -rn \
            | /usr/bin/cut -f2-
    )

    # 중첩 실행 파일을 다시 서명했으므로 이를 담고 있는 번들도 깊은 것부터 다시 봉인합니다.
    while IFS= read -r -d '' bundle; do
        codesign --force --sign "$LOCAL_SIGN_IDENTITY" --options runtime \
            --timestamp=none "$bundle" > /dev/null 2>&1 || true
    done < <(find "$BUILT_APP/Contents" \
        \( -name "*.xpc" -o -name "*.app" -o -name "*.framework" \) -depth -print0)

    if [ "$resign_failed" -eq 0 ] \
        && codesign --force --sign "$LOCAL_SIGN_IDENTITY" --options runtime \
            --timestamp=none "$BUILT_APP" > /dev/null 2>&1; then
        echo "  재서명 완료 — 재설치해도 손쉬운 사용 권한이 유지됩니다"
    else
        echo "  [경고] Developer ID 재서명 실패. ad-hoc으로 되돌립니다." >&2
        echo "         재설치 시 손쉬운 사용 권한을 다시 승인해야 할 수 있습니다." >&2
        # 부분 서명 상태로 두면 검증기가 Team ID 불일치로 설치를 막습니다.
        # 전체를 ad-hoc으로 통일해 최소한 설치는 진행되게 합니다.
        while IFS= read -r -d '' bundle; do
            codesign --force --sign - "$bundle" > /dev/null 2>&1 || true
        done < <(find "$BUILT_APP/Contents" \
            \( -name "*.xpc" -o -name "*.app" -o -name "*.framework" \) -depth -print0)
        codesign --force --sign - "$BUILT_APP" > /dev/null 2>&1 || true
    fi
else
    echo "  Developer ID 인증서 없음 — ad-hoc 서명 유지"
    echo "  (재설치할 때마다 손쉬운 사용 권한을 다시 승인해야 할 수 있습니다)"
fi

validate_local_app_graph "$BUILT_APP"
echo "[2/5] 빌드 완료 (v$BUILT_VERSION, 빌드 $BUILT_BUILD_NUMBER)"

# 이름이 같은 프로세스를 전부 종료합니다.
#
# `pgrep -x`만 쓰면 /Applications 사본만 잡습니다. Xcode DerivedData에서 직접
# 실행한 디버그 빌드가 함께 떠 있으면 그쪽이 살아남아 이벤트 탭을 계속 물고
# 있고, 새로 설치한 앱은 탭을 못 잡아 "설치했는데 안 된다"가 됩니다.
# 실제로 겪은 상황이라 경로와 무관하게 전부 종료합니다.
if pgrep -x "$APP_NAME" > /dev/null 2>&1 \
        || pgrep -f "/$APP_NAME.app/Contents/MacOS/$APP_NAME" > /dev/null 2>&1; then
    echo "[3/5] 실행 중인 $APP_NAME 종료 중..."
    killall "$APP_NAME" > /dev/null 2>&1 || true
    pkill -f "/$APP_NAME.app/Contents/MacOS/$APP_NAME" > /dev/null 2>&1 || true
    for _ in {1..20}; do
        if ! pgrep -x "$APP_NAME" > /dev/null 2>&1 \
                && ! pgrep -f "/$APP_NAME.app/Contents/MacOS/$APP_NAME" > /dev/null 2>&1; then
            break
        fi
        sleep 0.2
    done
    if pgrep -x "$APP_NAME" > /dev/null 2>&1 \
            || pgrep -f "/$APP_NAME.app/Contents/MacOS/$APP_NAME" > /dev/null 2>&1; then
        fail "$APP_NAME을 종료하지 못했습니다. 앱을 직접 종료한 뒤 다시 시도하세요."
    fi
else
    echo "[3/5] 실행 중인 기존 앱 없음"
fi

# 손쉬운 사용 권한 등록을 지웁니다 — 설정 창에서 '-'를 누르는 것과 같습니다.
#
# 왜 필요한가: TCC는 승인을 **코드 서명 요구사항**에 묶어 기억합니다. 새 빌드가
# 그 요구사항을 만족하지 못하면 목록에는 체크된 채로 남아 있는데 실제 권한은
# 거부되는, 겉과 속이 다른 상태가 됩니다. 그러면 "분명 켜져 있는데 안 된다"가
# 되고 원인을 찾을 단서가 화면에 없습니다. 재설치 때마다 지워서 그 상태가
# 아예 생기지 않게 합니다.
#
# `tccutil reset`은 권한을 **없애기만** 합니다 — 스크립트가 권한을 부여할 방법은
# macOS에 없고, 있어서도 안 됩니다. 그래서 아래에서 승인을 다시 요청합니다.
#
# 건너뛰려면: SKIP_TCC_RESET=1 ./install.sh
if [ "${SKIP_TCC_RESET:-0}" = "1" ]; then
    echo "[4/5] 손쉬운 사용 권한 초기화 건너뜀 (SKIP_TCC_RESET=1)"
else
    echo "[4/5] 손쉬운 사용 권한 등록 삭제 중 ($EXPECTED_IDENTIFIER)..."
    if tccutil reset Accessibility "$EXPECTED_IDENTIFIER" > /dev/null 2>&1; then
        echo "  삭제 완료 — 설치 후 다시 승인해야 합니다"
    else
        # 등록이 애초에 없으면 실패합니다. 정상이므로 설치를 막지 않습니다.
        echo "  기존 등록 없음 (또는 삭제 불필요)"
    fi
fi

echo "[5/5] $APP_PATH 에 설치 중..."
echo "  시스템 Applications 폴더를 변경하려면 관리자 인증이 필요합니다."
if ! sudo -v; then
    fail "관리자 인증이 취소되었습니다."
fi

sudo rm -rf "$APP_PATH"
sudo ditto "$BUILT_APP" "$APP_PATH"

if [ ! -d "$APP_PATH" ]; then
    fail "설치 후 앱을 찾을 수 없습니다: $APP_PATH"
fi

INSTALLED_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
if [ "$INSTALLED_VERSION" != "$VERSION" ]; then
    fail "설치된 앱 버전이 일치하지 않습니다 (예상 $VERSION, 실제 $INSTALLED_VERSION)."
fi
INSTALLED_BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Contents/Info.plist")"
if [ "$INSTALLED_BUILD_NUMBER" != "$BUILD_NUMBER" ]; then
    fail "설치된 앱 빌드 번호가 일치하지 않습니다 (예상 $BUILD_NUMBER, 실제 $INSTALLED_BUILD_NUMBER)."
fi
INSTALLED_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Contents/Info.plist")"
if [ "$INSTALLED_IDENTIFIER" != "$EXPECTED_IDENTIFIER" ]; then
    fail "설치된 앱 ID가 일치하지 않습니다 (예상 $EXPECTED_IDENTIFIER, 실제 $INSTALLED_IDENTIFIER)."
fi
validate_local_app_graph "$APP_PATH"

echo ""
echo "========================================="
echo "  Mackor v$INSTALLED_VERSION (빌드 $INSTALLED_BUILD_NUMBER) 설치 완료"
echo "========================================="
echo ""
echo "  위치: $APP_PATH"
echo ""
echo "  [다음 단계]"
if [ "${SKIP_TCC_RESET:-0}" = "1" ]; then
    echo "  1. $APP_PATH 을 실행"
    echo "  2. 메뉴바의 'Mackor' 메뉴에서 자동 교정 범위와 대상 앱 설정"
else
    echo "  1. 손쉬운 사용 목록에서 Mackor를 **다시 켜기** (등록을 지웠으므로 필수)"
    echo "  2. 메뉴바의 'Mackor' 메뉴에서 자동 교정 범위와 대상 앱 설정"
fi
echo ""

REPLY=""
if [ -t 0 ]; then
    read -r -p "지금 바로 실행할까요? (y/n): " -n 1 REPLY || true
    echo ""
fi

if [[ "$REPLY" =~ ^[Yy]$ ]]; then
    if open "$APP_PATH"; then
        echo "앱을 실행했습니다. 메뉴바를 확인하세요."
    else
        echo "[경고] 앱을 자동으로 열지 못했습니다. Finder에서 직접 실행하세요." >&2
    fi
    # 권한을 지웠으면 승인 창까지 데려다줍니다. 앱을 먼저 실행해야 목록에
    # 나타나므로 순서를 바꾸면 안 됩니다.
    if [ "${SKIP_TCC_RESET:-0}" != "1" ]; then
        sleep 1
        open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" \
            > /dev/null 2>&1 \
            && echo "손쉬운 사용 설정을 열었습니다 — 목록에서 Mackor를 켜세요." \
            || echo "[안내] 시스템 설정 > 개인정보 보호 및 보안 > 손쉬운 사용에서 Mackor를 켜세요."
    fi
elif [ ! -t 0 ]; then
    echo "비대화형 실행이므로 앱을 자동으로 열지 않았습니다."
fi
