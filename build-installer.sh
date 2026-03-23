#!/bin/bash

# MacKR — 유니버설 바이너리 빌드 + PKG/DMG 인스톨러 생성
# Intel Mac + Apple Silicon Mac 모두 지원

set -e

APP_NAME="MacKR"
DISPLAY_NAME="MacKR - 한글 입력 보정"
VERSION="1.1"
IDENTIFIER="com.mackr.app"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/MacKR"
DIST_DIR="$SCRIPT_DIR/dist"
BUILD_DIR="$PROJECT_DIR/build"

echo ""
echo "========================================="
echo "  $DISPLAY_NAME — 인스톨러 생성"
echo "========================================="
echo ""

# Xcode 확인
if ! command -v xcodebuild &> /dev/null; then
    echo "[오류] Xcode가 필요합니다."
    exit 1
fi

# 정리
rm -rf "$BUILD_DIR" "$DIST_DIR"
mkdir -p "$DIST_DIR"

# ─────────────────────────────────────
# 1. 유니버설 바이너리 빌드 (arm64 + x86_64)
# ─────────────────────────────────────

echo "[1/5] Apple Silicon (arm64) 빌드 중..."
cd "$PROJECT_DIR"
xcodebuild \
    -project "$APP_NAME.xcodeproj" \
    -scheme "$APP_NAME" \
    -configuration Release \
    -arch arm64 \
    build \
    CONFIGURATION_BUILD_DIR="$BUILD_DIR/arm64" \
    -quiet 2>/dev/null

echo "[2/5] Intel (x86_64) 빌드 중..."
xcodebuild \
    -project "$APP_NAME.xcodeproj" \
    -scheme "$APP_NAME" \
    -configuration Release \
    -arch x86_64 \
    build \
    CONFIGURATION_BUILD_DIR="$BUILD_DIR/x86_64" \
    -quiet 2>/dev/null

echo "[3/5] 유니버설 바이너리 합치는 중..."

# arm64 앱을 기반으로 복사
cp -R "$BUILD_DIR/arm64/$APP_NAME.app" "$BUILD_DIR/$APP_NAME.app"

# lipo로 두 아키텍처 합치기
lipo -create \
    "$BUILD_DIR/arm64/$APP_NAME.app/Contents/MacOS/$APP_NAME" \
    "$BUILD_DIR/x86_64/$APP_NAME.app/Contents/MacOS/$APP_NAME" \
    -output "$BUILD_DIR/$APP_NAME.app/Contents/MacOS/$APP_NAME"

# 유니버설 확인
echo "  아키텍처: $(lipo -archs "$BUILD_DIR/$APP_NAME.app/Contents/MacOS/$APP_NAME")"

# ─────────────────────────────────────
# 2. PKG 인스톨러 생성 (더블클릭으로 설치)
# ─────────────────────────────────────

echo "[4/5] PKG 인스톨러 생성 중..."

# 임시 payload 폴더
PAYLOAD_DIR="$BUILD_DIR/payload"
mkdir -p "$PAYLOAD_DIR/Applications"
cp -R "$BUILD_DIR/$APP_NAME.app" "$PAYLOAD_DIR/Applications/"

# postinstall 스크립트 — 설치 후 자동 실행
SCRIPTS_DIR="$BUILD_DIR/scripts"
mkdir -p "$SCRIPTS_DIR"
cat > "$SCRIPTS_DIR/postinstall" << 'POSTINSTALL'
#!/bin/bash
# 설치 완료 후 앱 자동 실행
sleep 1
open "/Applications/MacKR.app"
exit 0
POSTINSTALL
chmod +x "$SCRIPTS_DIR/postinstall"

# 컴포넌트 pkg 생성
pkgbuild \
    --root "$PAYLOAD_DIR" \
    --scripts "$SCRIPTS_DIR" \
    --identifier "$IDENTIFIER" \
    --version "$VERSION" \
    --install-location "/" \
    "$BUILD_DIR/component.pkg" \
    > /dev/null 2>&1

# Welcome HTML 파일 (별도 파일로 인코딩 문제 해결)
RESOURCES_DIR="$BUILD_DIR/resources"
mkdir -p "$RESOURCES_DIR"

/usr/bin/python3 -c "
html = '''<!DOCTYPE html>
<html lang=\"ko\">
<head><meta charset=\"UTF-8\"></head>
<body style=\"font-family: -apple-system, sans-serif; padding: 20px;\">
<h2>CorelDRAW \ud55c\uae00 \uc785\ub825 \ubcf4\uc815</h2>
<p>CorelDRAW\uc5d0\uc11c \ud55c\uae00\uc744 \uc790\uc5f0\uc2a4\ub7fd\uac8c \uc785\ub825\ud560 \uc218 \uc788\ub3c4\ub85d \ub3c4\uc640\uc8fc\ub294 \uc571\uc785\ub2c8\ub2e4.</p>
<br/>
<p><b>\uc124\uce58 \ud6c4 \ud544\uc694\ud55c \uc124\uc815:</b></p>
<ol>
<li>\uc571\uc774 \uc790\ub3d9\uc73c\ub85c \uc2e4\ud589\ub429\ub2c8\ub2e4</li>
<li>\uba54\ub274\ubc14\uc5d0 <b>\ud55c</b> \uc544\uc774\ucf58\uc774 \ub098\ud0c0\ub0a9\ub2c8\ub2e4</li>
<li><b>\uc190\uc26c\uc6b4 \uc0ac\uc6a9</b> \uad8c\ud55c\uc744 \ud5c8\uc6a9\ud574\uc8fc\uc138\uc694<br/>
(\uc2dc\uc2a4\ud15c \uc124\uc815 \u2192 \uac1c\uc778\uc815\ubcf4 \ubcf4\ud638 \ubc0f \ubcf4\uc548 \u2192 \uc190\uc26c\uc6b4 \uc0ac\uc6a9)</li>
</ol>
</body></html>'''
with open('$RESOURCES_DIR/welcome.html', 'w', encoding='utf-8') as f:
    f.write(html)
"

# Distribution XML
cat > "$BUILD_DIR/distribution.xml" << DISTXML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>$DISPLAY_NAME</title>
    <welcome file="welcome.html" mime-type="text/html"/>
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

# 최종 PKG 생성
productbuild \
    --distribution "$BUILD_DIR/distribution.xml" \
    --resources "$RESOURCES_DIR" \
    --package-path "$BUILD_DIR" \
    "$DIST_DIR/MacKR_Installer.pkg" \
    > /dev/null 2>&1

echo "  PKG: $DIST_DIR/MacKR_Installer.pkg"

# ─────────────────────────────────────
# 3. DMG도 생성 (드래그 앤 드롭 방식)
# ─────────────────────────────────────

echo "[5/5] DMG 생성 중..."

DMG_TEMP="$BUILD_DIR/dmg_contents"
mkdir -p "$DMG_TEMP"
cp -R "$BUILD_DIR/$APP_NAME.app" "$DMG_TEMP/"
ln -s /Applications "$DMG_TEMP/Applications"

hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$DMG_TEMP" \
    -ov \
    -format UDZO \
    "$DIST_DIR/MacKR.dmg" \
    > /dev/null 2>&1

echo "  DMG: $DIST_DIR/MacKR.dmg"

# 정리
rm -rf "$BUILD_DIR"

echo ""
echo "========================================="
echo "  완료! 배포 파일:"
echo "========================================="
echo ""
echo "  1. MacKR_Installer.pkg  (더블클릭 → 자동 설치)"
echo "  2. MacKR.dmg            (드래그 앤 드롭 설치)"
echo ""
echo "  위치: $DIST_DIR/"
echo ""
echo "  이 파일을 다른 사람에게 보내주면 됩니다!"
echo ""
