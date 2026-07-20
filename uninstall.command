#!/bin/bash

# Finder에서 더블클릭해 실행하는 Mackor 제거 래퍼

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
UNINSTALL_SCRIPT="$SCRIPT_DIR/uninstall.sh"
STATUS=0

if [ ! -f "$UNINSTALL_SCRIPT" ]; then
    echo "[오류] 제거 스크립트를 찾을 수 없습니다: $UNINSTALL_SCRIPT" >&2
    STATUS=1
elif /bin/bash "$UNINSTALL_SCRIPT"; then
    STATUS=0
else
    STATUS=$?
fi

if [ -t 0 ]; then
    echo ""
    read -r -p "아무 키나 누르면 창이 닫힙니다..." -n 1 _ || true
    echo ""
fi

exit "$STATUS"
