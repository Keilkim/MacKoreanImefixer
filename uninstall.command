#!/bin/bash

# CorelDRAW 한글 입력 보정 — 삭제 스크립트
# 더블클릭하면 실행됩니다

echo ""
echo "========================================="
echo "  CorelDRAW 한글 입력 보정 앱 삭제"
echo "========================================="
echo ""

# 앱 종료
if pgrep -x MacKR > /dev/null 2>&1; then
    echo "앱 종료 중..."
    killall MacKR 2>/dev/null
    sleep 1
fi

# 앱 삭제
if [ -d "/Applications/MacKR.app" ]; then
    echo "앱 삭제 중... (관리자 비밀번호가 필요할 수 있습니다)"
    sudo rm -rf /Applications/MacKR.app
    echo "앱 삭제 완료!"
else
    echo "앱이 이미 없습니다."
fi

# 설치 기록 삭제
if pkgutil --pkg-info com.mackr.app > /dev/null 2>&1; then
    echo "설치 기록 삭제 중..."
    sudo pkgutil --forget com.mackr.app > /dev/null 2>&1
fi

echo ""
echo "삭제 완료!"
echo ""
read -p "아무 키나 누르면 창이 닫힙니다..." -n 1
