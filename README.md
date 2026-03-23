# CorelDRAW 한글 입력 보정 (CorelHangulFix)

macOS에서 CorelDRAW 사용 시 한글 입력이 깨지는 문제를 해결하는 앱입니다.

## 문제

CorelDRAW는 macOS의 한글 IME 조합을 제대로 지원하지 않아서:
- 입력 중인 글자가 보이지 않음
- "한글" 입력 시 "한ㅡ"로 깨짐
- 글자마다 방향키를 눌러야 하는 불편함

## 해결

CorelHangulFix는 키보드 입력을 가로채서 직접 한글을 조합한 뒤, 완성된 유니코드 문자를 CorelDRAW에 전달합니다.

- 모든 CorelDRAW 버전 자동 감지 (2020~2025+)
- Intel Mac / Apple Silicon Mac 모두 지원
- 메뉴바 앱으로 백그라운드 실행

## 설치 방법

### 1. 다운로드
[Releases](../../releases) 페이지에서 `CorelHangulFix_Installer.pkg` 다운로드

### 2. 설치
PKG 파일 더블클릭 → "계속" → "설치"

> "확인되지 않은 개발자" 경고가 뜨면:
> 시스템 설정 → 개인정보 보호 및 보안 → "확인 없이 열기" 클릭

### 3. 권한 설정 (필수!)
앱 첫 실행 시 **손쉬운 사용** 권한을 허용해야 합니다:

1. 메뉴바에 **한** 아이콘 클릭
2. **"권한 설정 열기"** 클릭
3. **CorelHangulFix** 토글 켜기

### 4. 사용
CorelDRAW를 열고 한글을 입력하면 자동으로 작동합니다!

## 삭제 방법

`uninstall.command` 파일을 더블클릭하면 자동으로 삭제됩니다.

또는 수동으로:
```bash
killall CorelHangulFix
sudo rm -rf /Applications/CorelHangulFix.app
sudo pkgutil --forget com.corelhangulfix.app
```

## 빌드 (개발자용)

Xcode가 설치되어 있어야 합니다.

```bash
# 유니버설 바이너리 빌드 + PKG/DMG 인스톨러 생성
bash build-installer.sh
```

## 동작 원리

1. CGEventTap으로 키보드 이벤트 감시
2. CorelDRAW가 활성 앱이고 한글 입력 중일 때만 작동
3. 자모 키 입력을 가로채서 자체 한글 조합 엔진으로 처리
4. 완성된 유니코드 문자를 CGEvent로 직접 전달

## 라이선스

MIT License
