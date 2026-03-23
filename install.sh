#!/bin/bash

# MacKR 빌드 및 설치 스크립트
# 사용법: ./install.sh

set -e

APP_NAME="MacKR"
INSTALL_DIR="/Applications"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/MacKR"

echo ""
echo "========================================="
echo "  CorelDRAW 한글 입력 보정 앱 설치"
echo "========================================="
echo ""

# 1. Xcode 커맨드라인 도구 확인
if ! command -v xcodebuild &> /dev/null; then
    echo "[오류] Xcode 커맨드라인 도구가 설치되어 있지 않습니다."
    echo "  다음 명령어로 설치해주세요:"
    echo "  xcode-select --install"
    exit 1
fi

echo "[1/4] 프로젝트 빌드 중..."
cd "$PROJECT_DIR"

xcodebuild \
    -project "$APP_NAME.xcodeproj" \
    -scheme "$APP_NAME" \
    -configuration Release \
    build \
    CONFIGURATION_BUILD_DIR="$PROJECT_DIR/build" \
    -quiet

if [ ! -d "$PROJECT_DIR/build/$APP_NAME.app" ]; then
    echo "[오류] 빌드 실패. 위 로그를 확인해주세요."
    exit 1
fi

echo "[2/4] 빌드 완료!"

# 2. 기존 앱이 실행 중이면 종료
if pgrep -x "$APP_NAME" > /dev/null 2>&1; then
    echo "[3/4] 기존 $APP_NAME 종료 중..."
    killall "$APP_NAME" 2>/dev/null || true
    sleep 1
else
    echo "[3/4] 기존 앱 없음, 계속 진행..."
fi

# 3. /Applications에 복사 (기존 있으면 교체)
echo "[4/4] $INSTALL_DIR 에 설치 중..."

if [ -d "$INSTALL_DIR/$APP_NAME.app" ]; then
    rm -rf "$INSTALL_DIR/$APP_NAME.app"
fi

cp -R "$PROJECT_DIR/build/$APP_NAME.app" "$INSTALL_DIR/$APP_NAME.app"

# 빌드 임시 파일 정리
rm -rf "$PROJECT_DIR/build"

echo ""
echo "========================================="
echo "  설치 완료!"
echo "========================================="
echo ""
echo "  위치: $INSTALL_DIR/$APP_NAME.app"
echo ""
echo "  [다음 단계]"
echo "  1. Finder에서 /Applications/$APP_NAME.app 을 더블클릭하여 실행"
echo "  2. 메뉴바에 '한' 아이콘이 나타남"
echo "  3. 첫 실행 시 팝업이 뜨면:"
echo "     시스템 설정 > 개인정보 보호 및 보안 > 손쉬운 사용"
echo "     에서 $APP_NAME 을 허용해주세요"
echo ""

# 4. 설치 후 바로 실행할지 물어보기
read -p "지금 바로 실행할까요? (y/n): " -n 1 -r
echo ""
if [[ $REPLY =~ ^[Yy]$ ]]; then
    open "$INSTALL_DIR/$APP_NAME.app"
    echo "앱을 실행했습니다. 메뉴바를 확인하세요!"
fi
