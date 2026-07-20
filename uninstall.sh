#!/bin/bash

# Mackor 앱과 Installer 패키지 영수증 제거

set -uo pipefail

APP_NAME="Mackor"
APP_PATH="/Applications/$APP_NAME.app"
PACKAGE_ID="com.mackor.app"

fail() {
    echo "[오류] $*" >&2
    exit 1
}

echo ""
echo "========================================="
echo "  Mackor — 한글 입력 보정 앱 제거"
echo "========================================="
echo ""

HAS_APP=0
HAS_RECEIPT=0
if [ -e "$APP_PATH" ] || [ -L "$APP_PATH" ]; then
    HAS_APP=1
fi
if pkgutil --pkg-info "$PACKAGE_ID" > /dev/null 2>&1; then
    HAS_RECEIPT=1
fi

if [ "$HAS_APP" = "0" ] && [ "$HAS_RECEIPT" = "0" ]; then
    echo "Mackor 앱과 패키지 설치 기록이 이미 없습니다."
    echo "로그인 시 자동 실행을 사용했다면 시스템 설정 > 일반 > 로그인 항목에서 Mackor가 남아 있지 않은지 확인하세요."
    exit 0
fi

echo "관리자 인증 후 다음 항목을 제거합니다:"
if [ "$HAS_APP" = "1" ]; then
    echo "  - $APP_PATH"
fi
if [ "$HAS_RECEIPT" = "1" ]; then
    echo "  - 패키지 설치 기록 $PACKAGE_ID"
fi

echo ""
echo "[로그인 항목 확인]"
echo "자동 실행을 사용 중이면 앱 메뉴에서 '로그인 시 자동 실행'을 먼저 끄세요."
echo "앱이 실행되지 않으면 시스템 설정 > 일반 > 로그인 항목에서 Mackor를 제거하세요."
if [ -t 0 ]; then
    CONFIRM=""
    read -r -p "로그인 항목을 해제했거나 사용하지 않았습니까? (y/N): " CONFIRM || true
    case "$CONFIRM" in
        y|Y|yes|YES|Yes) ;;
        *) echo "제거를 취소했습니다."; exit 1 ;;
    esac
else
    echo "[경고] 비대화형 실행에서는 로그인 항목 해제 여부를 확인할 수 없습니다." >&2
fi

if ! sudo -v; then
    fail "관리자 인증이 취소되었습니다. 아무 항목도 제거하지 않았습니다."
fi

if pgrep -x "$APP_NAME" > /dev/null 2>&1; then
    echo "실행 중인 $APP_NAME 종료 중..."
    sudo killall "$APP_NAME" > /dev/null 2>&1 || true
    for _ in {1..20}; do
        if ! pgrep -x "$APP_NAME" > /dev/null 2>&1; then
            break
        fi
        sleep 0.2
    done
    if pgrep -x "$APP_NAME" > /dev/null 2>&1; then
        fail "$APP_NAME을 종료하지 못해 제거를 중단했습니다."
    fi
fi

if [ "$HAS_APP" = "1" ]; then
    echo "앱 삭제 중..."
    if ! sudo rm -rf "$APP_PATH"; then
        fail "앱 삭제에 실패했습니다: $APP_PATH"
    fi
    if [ -e "$APP_PATH" ] || [ -L "$APP_PATH" ]; then
        fail "앱이 삭제되지 않았습니다: $APP_PATH"
    fi
    echo "  앱 삭제 완료"
fi

if [ "$HAS_RECEIPT" = "1" ]; then
    echo "패키지 설치 기록 삭제 중..."
    if ! sudo pkgutil --forget "$PACKAGE_ID" > /dev/null; then
        fail "앱은 삭제되었지만 패키지 설치 기록을 지우지 못했습니다: $PACKAGE_ID"
    fi
    if pkgutil --pkg-info "$PACKAGE_ID" > /dev/null 2>&1; then
        fail "패키지 설치 기록이 남아 있습니다: $PACKAGE_ID"
    fi
    echo "  패키지 설치 기록 삭제 완료"
fi

echo ""
echo "Mackor 제거 완료"
echo ""
