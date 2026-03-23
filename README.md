# MacKoreanImefixer

**macOS에서 CorelDRAW 한글 입력이 깨지는 문제를 해결하는 앱**

---

## 이런 문제가 있다면?

- CorelDRAW에서 "한글" 입력하면 **"한ㅡ"** 로 나옴
- 입력 중인 글자가 **안 보임**
- 글자마다 **방향키**를 눌러야 함

👉 이 앱을 설치하면 바로 해결됩니다!

---

## 설치 방법

### 1단계: 다운로드

[📦 여기서 다운로드](../../releases/latest) → **CorelHangulFix_Installer.pkg** 클릭

### 2단계: 설치

1. 다운로드한 **PKG 파일 더블클릭**
2. **"계속"** → **"설치"** 클릭
3. 설치 완료!

> ⚠️ **"확인되지 않은 개발자" 경고가 뜨면:**
>
> `시스템 설정` → `개인정보 보호 및 보안` → 아래쪽에 **"확인 없이 열기"** 클릭

### 3단계: 권한 설정 (필수!)

앱이 키보드 입력을 보정하려면 **손쉬운 사용** 권한이 필요합니다.

1. 메뉴바(화면 맨 위, 시계 옆)에서 **"한"** 클릭
2. **"권한 설정 열기"** 클릭
3. `시스템 설정` → `개인정보 보호 및 보안` → `손쉬운 사용` 이 열림
4. 목록에 **CorelHangulFix**가 없으면:
   - 아래 **＋ 버튼** 클릭
   - `/Applications/CorelHangulFix.app` 선택
5. **CorelHangulFix** 토글 **켜기**

> 💡 터미널에서 직접 실행하는 경우 **터미널**도 같은 방법으로 추가해야 합니다:
> - **＋ 버튼** 클릭 → `/Applications/유틸리티/터미널.app` 선택 → 토글 켜기

### 4단계: 사용

**끝!** CorelDRAW를 열고 한글을 입력하면 자동으로 작동합니다.

- CorelDRAW가 활성화되면 → 자동 감지
- 한글 입력 모드일 때만 → 자동 작동
- 다른 앱에서는 → 간섭 없음

---

## 삭제 방법

### 방법 1: 더블클릭 삭제

`uninstall.command` 파일을 더블클릭 → 자동 삭제

### 방법 2: 수동 삭제

터미널에서 한 줄씩 입력:

```
killall CorelHangulFix
```
```
sudo rm -rf /Applications/CorelHangulFix.app
```
```
sudo pkgutil --forget com.corelhangulfix.app
```

---

## 지원 환경

| 항목 | 지원 |
|------|------|
| macOS | 13 (Ventura) 이상 |
| Mac | Intel / Apple Silicon 모두 |
| CorelDRAW | 2020 ~ 2025+ (자동 감지) |

---

## 동작 원리

CorelDRAW가 macOS 한글 IME를 제대로 지원하지 않아서 발생하는 문제입니다.

이 앱은:
1. 키보드 입력을 가로채서
2. 자체 한글 조합 엔진으로 처리하고
3. 완성된 한글 문자를 CorelDRAW에 직접 전달합니다

CorelDRAW가 아닌 다른 앱에서는 전혀 개입하지 않습니다.

---

## 문제 신고

문제가 있으면 [Issues](../../issues)에 남겨주세요!

## 라이선스

MIT License
