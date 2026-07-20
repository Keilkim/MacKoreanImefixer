#!/bin/bash

# Finder에서 더블클릭하는 오픈소스 개발자용 설치 진입점입니다.
# 실제 빌드·설치 검증은 같은 폴더의 install.sh가 담당합니다.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
INSTALL_SCRIPT="$SCRIPT_DIR/install.sh"

if [ ! -f "$INSTALL_SCRIPT" ]; then
    echo "[오류] 같은 폴더에서 install.sh를 찾을 수 없습니다."
    echo "       GitHub 소스 ZIP을 완전히 압축 해제한 뒤 다시 실행하세요."
    read -r -p "Return을 누르면 닫습니다..." _
    exit 1
fi

/bin/bash "$INSTALL_SCRIPT"
STATUS=$?

if [ "$STATUS" -ne 0 ]; then
    echo ""
    echo "설치가 완료되지 않았습니다. 위 오류를 확인하세요."
    read -r -p "Return을 누르면 닫습니다..." _
fi

exit "$STATUS"
