#!/bin/bash

# CorelHangulFix 제거 스크립트

APP_NAME="CorelHangulFix"
INSTALL_DIR="/Applications"

echo ""
echo "========================================="
echo "  CorelDRAW 한글 입력 보정 앱 제거"
echo "========================================="
echo ""

if [ ! -d "$INSTALL_DIR/$APP_NAME.app" ]; then
    echo "앱이 설치되어 있지 않습니다."
    exit 0
fi

# 실행 중이면 종료
if pgrep -x "$APP_NAME" > /dev/null 2>&1; then
    echo "실행 중인 앱을 종료합니다..."
    killall "$APP_NAME" 2>/dev/null || true
    sleep 1
fi

rm -rf "$INSTALL_DIR/$APP_NAME.app"

echo "제거 완료!"
echo ""
