#!/bin/bash
# MackorIMEProbe 빌드·설치 스크립트 (P0 측정 전용)
#
# Xcode 프로젝트(수기 관리 pbxproj)를 건드리지 않기 위해 swiftc로 직접 빌드한다.
# 사용법:
#   ./build.sh            빌드만
#   ./build.sh install    빌드 + ~/Library/Input Methods 설치 + 등록(P0-8 측정)

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
APP="$BUILD_DIR/MackorIMEProbe.app"
INSTALL_DIR="$HOME/Library/Input Methods"

echo "[1/3] swiftc 빌드..."
rm -rf "$BUILD_DIR"
mkdir -p "$APP/Contents/MacOS"

swiftc \
    -O \
    -module-name MackorIMEProbe \
    -framework AppKit \
    -framework InputMethodKit \
    -framework Carbon \
    -o "$APP/Contents/MacOS/MackorIMEProbe" \
    "$SCRIPT_DIR/ProbeLog.swift" \
    "$SCRIPT_DIR/ProbeInputController.swift" \
    "$SCRIPT_DIR/main.swift"

cp "$SCRIPT_DIR/Info.plist" "$APP/Contents/Info.plist"

echo "[2/3] ad-hoc 서명..."
codesign --force --sign - "$APP"
codesign --verify --strict "$APP" && echo "  서명 검증 OK"

if [ "${1:-}" != "install" ]; then
    echo "빌드 완료: $APP"
    echo "설치하려면: ./build.sh install"
    exit 0
fi

echo "[3/3] 설치 + 등록 (P0-8 측정)..."
pkill -x MackorIMEProbe 2>/dev/null || true
mkdir -p "$INSTALL_DIR"
rm -rf "$INSTALL_DIR/MackorIMEProbe.app"
ditto "$APP" "$INSTALL_DIR/MackorIMEProbe.app"

# 등록 — 재로그인 없이 시스템 설정에 보이는지가 P0-8의 측정 대상
"$INSTALL_DIR/MackorIMEProbe.app/Contents/MacOS/MackorIMEProbe" --enable || true

echo ""
echo "설치 완료. 다음을 확인하세요:"
echo "  1. 시스템 설정 > 키보드 > 입력 소스 > 편집 > '+' 목록에"
echo "     MackorIMEProbe가 (재로그인 없이) 보이는가 → P0-8 결과"
echo "  2. 보이면 추가한 뒤 입력 소스로 선택"
echo "  3. 로그 관찰: tail -f ~/mackor-probe.log"
