# Mackor

macOS에서 한글 조합을 제대로 처리하지 못하는 앱을 위한 메뉴바 입력 보정 유틸리티입니다.

구현 구조, 판단 알고리즘, 개인정보 경계, 알려진 한계와 외부 검토 체크리스트는 [설계·원리·외부 검토 문서](ARCHITECTURE.md)에 정리되어 있습니다.

Mackor은 사용자가 등록한 앱이 앞에 있고 macOS 한글 입력기가 활성화된 동안, 키 입력을 두벌식 한글로 직접 조합해 전달합니다. 이 기존 조합 보정은 등록한 앱에서만 작동합니다.

현재 개발 중인 1.3에는 입력 소스를 잘못 선택해 입력한 단어를 로컬에서 판단해 바꾸는 실험적 자동 교정도 포함됩니다. 자동 교정 적용 범위는 메뉴에서 `전체 Mac` 또는 `선택한 앱만`으로 고를 수 있으며, 기존 사용자는 안전을 위해 선택 앱 모드로 시작합니다.

## 지원 범위

| 항목 | 지원 |
|------|------|
| macOS | 13 Ventura 이상 |
| Mac | Apple Silicon 및 Intel |
| 한글 자판 | macOS 한국어 두벌식 |
| 적용 범위 | 자동 교정은 전체 Mac 또는 선택 앱, 기존 한글 조합 보정은 선택 앱 |
| 자동 교정 영문 자판 | Apple ABC 및 U.S. QWERTY |

세벌식, 두벌식 이외의 사용자 정의 자판 배열, 다른 언어 입력기는 현재 지원하지 않습니다.

다음과 같이 macOS IME 조합을 제대로 지원하지 않는 앱에서 도움이 될 수 있습니다.

| 예시 | 대표 증상 |
|------|-----------|
| CorelDRAW | 조합 중 글자가 보이지 않거나 일부 자모가 빠짐 |
| Wine / CrossOver 앱 | 자모가 풀어쓰기로 입력됨 |
| IntelliJ IDEA의 일부 JCEF 영역 | 내장 브라우저에서 한글 조합이 깨짐 |

앱과 버전에 따라 동작이 다를 수 있으므로 문제가 있는 앱만 등록해 사용하세요.

Safari, Chrome, Edge 같은 브라우저에서도 일반 웹 입력창을 자동 교정할 수 있습니다. `전체 Mac` 모드에서는 별도 등록 없이 모든 브라우저와 웹사이트에 적용되고, `선택한 앱만` 모드에서는 등록한 브라우저 앱 전체에 적용됩니다. 기존 한글 조합 보정은 해당 브라우저에서 실제 조합 문제가 있을 때만 등록하세요. 보안 입력창, 원격 데스크톱, 자체 키보드 처리를 사용하는 특수 웹 편집기는 동작이 다를 수 있습니다.

## 설치

Mackor은 설치 경로를 두 트랙으로 유지합니다.

| 트랙 | 대상 | 설치·업데이트 | 신뢰 경계 |
|---|---|---|---|
| 공식 배포 | 일반 사용자 | GitHub Releases의 공증된 PKG/DMG, 이후 Sparkle 업데이트 | 관리자만 Developer ID·Apple 공증·Sparkle 개인키로 서명 |
| 오픈소스 | 기여자·소스 검토 사용자 | 저장소의 `install.command`로 현재 소스를 로컬 빌드·설치 | ad-hoc·미공증, 공식 업데이트 비활성 |

외부 기여는 PR로 검토·병합하고, 병합된 소스에서 관리자가 새 공식 산출물을 다시 빌드·서명·공증합니다. 기여자에게 Apple 인증서나 Sparkle 개인키를 배포하지 않습니다.

### 일반 사용자: PKG 더블클릭 설치

> 현재 공증된 Mackor 공식 설치 파일은 아직 게시되지 않았습니다. 기존 최신 `1.1` 자산은 legacy CorelHangulFix 계열이며 Mackor 1.3 설치 파일이 아닙니다. 아래 절차는 첫 공식 Mackor 릴리스부터 적용됩니다.

1. [최신 릴리스](../../releases/latest)에서 `Mackor-<버전>-<빌드>.pkg`를 받습니다.
2. 내려받은 PKG를 더블클릭하고 Installer 안내에 따라 설치합니다. `/Applications` 설치를 위해 macOS 로컬 관리자 인증을 한 번 요구할 수 있지만 Apple 계정이나 앱 암호는 필요하지 않습니다.
3. 설치가 끝나면 `/Applications/Mackor.app`을 직접 실행합니다.

공식 일반 사용자용 PKG는 Developer ID 서명과 Apple 공증을 모두 통과한 파일만 게시합니다. Installer는 관리자 계정으로 GUI 앱을 강제 실행하지 않습니다.

### DMG로 설치

1. 최신 릴리스에서 `Mackor-<버전>-<빌드>.dmg`를 받아 엽니다.
2. `Mackor.app`을 `Applications` 폴더로 드래그합니다.
3. `/Applications/Mackor.app`을 실행합니다.

### 오픈소스 사용자·기여자: 소스 ZIP에서 더블클릭 설치

GitHub의 자동 생성 `Source code.zip`에는 미리 빌드된 앱이나 PKG가 들어 있지 않습니다. Xcode가 설치된 Mac에서는 ZIP을 완전히 압축 해제한 뒤 루트의 `install.command`를 더블클릭하면, 같은 폴더의 소스를 Release로 빌드해 `/Applications/Mackor.app`에 설치합니다. 처음 빌드할 때 Sparkle dependency를 내려받기 위한 네트워크와 `/Applications` 설치용 로컬 관리자 인증이 필요할 수 있습니다.

이 경로는 소스를 직접 검토·빌드하는 개발자용이며 결과는 ad-hoc 서명·미공증입니다. macOS가 `install.command` 실행을 막으면 출처를 확인한 뒤 Control-클릭 → `열기`를 사용하세요. 소스를 다시 빌드하면 ad-hoc 코드 해시가 달라져 `시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용`에서 기존 Mackor 항목을 제거하고 새 앱을 다시 추가해야 할 수 있습니다. 이 로컬 빌드에는 공식 feed URL과 업데이트 공개키를 넣지 않으므로 앱 내부 새 버전 확인·알림도 비활성입니다. Xcode가 없는 일반 사용자는 소스 ZIP 대신 공증된 버전별 PKG를 사용해야 합니다.

### 업데이트와 변경사항

첫 공식 Mackor 1.3 updater 기준선 이후의 공식 배포판부터 Mackor 메뉴에서 다음 항목을 사용할 수 있습니다. legacy CorelHangulFix나 MacKR 설치본은 이 자동 업데이트 경로에 연결되지 않습니다.

- `업데이트 확인…`: 새 버전을 확인하고 변경사항을 읽은 뒤 설치하고 다시 실행합니다.
- `이번 버전 변경사항…`: 현재 버전의 GitHub Release 설명을 엽니다.
- 업데이트 뒤 처음 메뉴를 열면 읽지 않은 버전의 변경사항 항목에 점을 표시합니다.

Mackor은 하루 한 번 새 버전을 확인하되 무인 자동 설치는 기본으로 사용하지 않습니다. 업데이트 창에는 새 기능, 개선, 버그 수정, 권한이나 동작 변화가 함께 표시됩니다. 최초 설치에는 업데이트 알림을 잘못 표시하지 않습니다.

### 서명 및 Gatekeeper 안내

저장소의 `build-installer.sh`를 인증서 환경변수 없이 실행하면 앱은 ad-hoc 서명되고, PKG는 미서명되며, Apple 공증도 받지 않습니다. 따라서 이 방식으로 만든 개발용 파일은 macOS에서 확인되지 않은 개발자 경고가 나타날 수 있습니다. 공개 배포용 파일은 아래 개발 절의 Developer ID 서명 및 공증 절차로 만들어야 합니다.

서명되지 않은 개발용 파일을 직접 만든 경우에만, 출처를 확인한 뒤 다음 방법으로 여세요.

- 앱: Finder에서 `Mackor.app`을 Control-클릭한 뒤 `열기`
- PKG: 한 번 열어 경고를 확인한 뒤 `시스템 설정 → 개인정보 보호 및 보안 → 확인 없이 열기`

## 첫 실행 설정

### 1. 손쉬운 사용 권한 허용

키보드 이벤트를 보정하려면 macOS의 손쉬운 사용 권한이 필요합니다.

1. 메뉴바의 `Mackor`을 클릭합니다.
2. `권한 설정 열기`를 클릭합니다.
3. `시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용`에서 Mackor를 켭니다.
4. 목록에 없다면 `+`를 눌러 `/Applications/Mackor.app`을 추가합니다.

예전 **MacKR** 항목이 남아 있으면 그 항목은 `–`로 삭제하고 현재 `/Applications/Mackor.app`을 새로 추가하세요. 손쉬운 사용 권한은 사용자 계정별로 직접 허용해야 하며 Apple 계정이나 개발자용 앱 암호를 요구하지 않습니다. 권한을 켠 뒤에도 상태가 바뀌지 않으면 Mackor를 한 번 종료하고 다시 실행하세요.

### 2. 자동 교정 범위 선택

메뉴바의 `Mackor`을 클릭하고 `자동 교정 적용 범위`에서 다음 중 하나를 고릅니다.

- `전체 Mac`: 앱 등록 없이 모든 일반 입력창에서 한/영 오입력을 자동 교정합니다.
- `선택한 앱만`: 아래 대상 앱 목록에서 자동 교정을 켠 앱에서만 작동합니다.

`전체 Mac`을 처음 선택하면 모든 앱과 브라우저 웹사이트에 적용된다는 확인 창이 나타납니다. 비밀번호·주소·검색·보안 입력 필드는 어느 범위에서도 제외됩니다.

### 3. 대상 앱 등록

`선택한 앱만` 모드에서 기존 한글 조합 보정이 필요하거나 앱별 자동 교정을 사용할 때 등록합니다. `전체 Mac` 모드에서는 저장된 앱별 조합 설정도 잠시 멈추며 대상 앱 관리 메뉴가 숨겨집니다. 선택 앱 모드로 돌아오면 목록과 설정이 그대로 복원됩니다.

1. `+ 앱 추가...`에서 앱을 선택합니다.
2. 또는 해당 앱을 앞에 띄운 뒤 `+ 현재 앱 추가`를 사용합니다.

메뉴바의 `활성화` 토글로 전체 보정을 잠시 끌 수 있습니다. 자동 실행이 필요하면 메뉴의 `로그인 시 자동 실행`을 직접 켜세요. Mackor은 사용자 동의 없이 로그인 항목을 등록하지 않습니다.

### 4. 앱별 기능 선택

등록한 앱 이름의 하위 메뉴에서 기능을 따로 설정할 수 있습니다.

- `한글 조합 보정`: 한글 IME 조합이 깨지는 앱을 위한 기존 기능이며 새 앱에는 기본으로 켜집니다.
- `한/영 오입력 자동 보정 (실험적)`: 선택 앱 모드에서 `gksrmf`를 `한글`로, `dkwn`을 `아주`로, 한글 모드에서 입력된 `ㅗ디ㅣㅐ`를 `hello`로 바꿉니다. 전체 Mac 모드에서는 앱별 토글 대신 전역 범위를 따릅니다.

자동 교정은 Apple ABC/U.S. QWERTY와 macOS 한국어 두벌식 사이에서만 작동합니다. 같은 물리 키열을 영문과 두벌식으로 각각 해석해 현재 입력 구조가 강하게 무너지고 반대 후보가 성립하는지를 비교합니다. 확실한 현재 언어 단어와 macOS의 신뢰 가능한 source 판정은 먼저 원문을 보호하며, target 사전에 없는 이름·신조어도 구조 대비가 충분하면 교정할 수 있습니다. 한글 소스의 순수 자모는 `but`, `how`처럼 알려진 영어 target 근거가 있을 때만 바꾸고, `ㅁㄴㅇ`, `ㅋㅋ`, `안녕ㅎ` 같은 keyboard-walk·자모 표현은 보존합니다. 완성형·후행 자모에서는 macOS 영어 사전만 target을 인정하고 실제 한글 후보는 인정하지 않을 때 영어로 교정합니다. 반대 방향도 macOS 한국어 사전만 target을 인정하고 영어 source는 인정하지 않을 때 단순 철자 heuristic보다 사전 근거를 우선합니다. 양쪽 사전이 모두 인정하면 현재 입력을 보존하고, 사전이 준비되지 않았거나 응답 제한 시간을 넘기면 이 공격적 경로를 실행하지 않습니다.

문서의 `팿미/vocal`, `해ㅐㅇ/good`, `챌ㄹㄷㄷ/coffee` 같은 단어는 일반 규칙을 깨뜨리지 않는지 보는 회귀 fixture일 뿐입니다. 앱이 실행 중에 이 예시 목록을 순회하거나 단어별 `if` 분기를 사용하지 않으며, 새 신고 단어를 fallback 목록에 한 건씩 추가하는 방식도 금지합니다. 실제 판정식은 방향에 따라 `안전 필드 ∧ 완전한 물리 토큰 ∧ source 보호 미충돌 ∧ 한쪽 사전 hit ∧ 반대쪽 사전 miss`입니다. `see`, `add`처럼 영어의 일부 double letter는 전체가 한 자모만 반복된 표현과 구분합니다. 영문 사전은 `Qatar`, `OpenAI` 같은 casing-sensitive 단어를 위해 원형 case를 먼저 조회합니다. 영문 소스에서 실제 Shift로 입력한 2글자 이상의 ALL CAPS와 Caps Lock이 관측된 run, 숫자·지원하지 않는 기호가 섞인 run, 32타를 넘는 입력은 건너뜁니다.

Space·`,`·`?`·`!`는 즉시 단어 경계로 평가합니다. 마침표는 URL·도메인의 앞부분만 바꾸지 않도록 1~3개까지 유예하며, 뒤에 글자나 숫자·기호가 이어지면 해당 run 전체를 보존합니다. 문장 끝의 마침표 뒤 Space 등이 오면 마침표를 포함한 경계를 정확히 한 번 복원합니다. 교정되면 시스템 입력 소스도 의도한 언어로 전환되어 다음 입력이 바뀐 `한/A` 상태로 이어집니다. 입력 보정 자체에는 외부 AI/LLM, 유료 API, API 키, 구독 또는 네트워크 연결이 필요하지 않습니다.

Return·숫자패드 Enter·Tab은 제출 경계입니다. 교정 후보가 있을 때만 물리 키를 붙잡아 같은 keyDown 처리 안에서 원문과 후행 마침표를 교정한 뒤 제출 키를 주입합니다. 후보가 없으면 원래 키가 그대로 통과하며, `Shift+Tab`은 제외합니다.

정확한 교정 range를 확인할 수 있는 입력란에서는 보정된 단어 바로 위에 물리 키열로 재구성한 원래 입력 하나만 최대 4초 동안 표시합니다. 이를 클릭하면 해당 교정과 입력 소스 전환을 복원합니다. range 좌표를 지원하지 않는 앱이거나 실험 기능을 끈 경우에도 자동 교정은 계속되며, 같은 입력 필드에서 다른 입력을 하기 전 최대 6초 동안 `⌘Z` 복원을 사용할 수 있습니다. 교정 뒤 사용자가 입력 소스를 직접 바꿨다면 그 선택은 덮어쓰지 않습니다.

## 권한과 개인정보 보호

손쉬운 사용 권한은 기술적으로 시스템 전역 키보드 이벤트에 접근할 수 있는 강한 권한입니다. 기존 한글 조합 보정은 다음 조건을 모두 만족할 때만 입력을 가로채 조합 결과로 바꿉니다.

1. 메뉴에서 보정이 활성화되어 있음
2. 사용자가 등록한 대상 앱이 현재 앞에 있음
3. macOS 한국어 두벌식 입력 소스가 활성화되어 있음

자동 교정은 사용자가 선택한 범위가 현재 앱에 적용되고, Apple ABC/U.S. 또는 한국어 두벌식 입력 소스를 사용하며, 현재 입력 위치가 안전한 일반 텍스트 필드로 확인된 경우에만 작동합니다. macOS Secure Input, 비밀번호 필드, 검색 필드, 주소·URL·위치·비밀번호로 식별되는 필드에서는 작동하지 않으며 안전 여부나 같은 포커스인지 확인할 수 없어도 교정하지 않습니다.

Mackor은 주변 문장이나 입력 필드 전체 값을 읽지 않습니다. 자동 교정 중에는 현재 단어의 물리 키코드·수정키 상태·입력 간격을 최대 32개까지만 메모리에 잠시 보관하고, 경계·긴 입력 정지·포커스 변경·입력 소스 변경·취소 시 지웁니다. 원문 칩을 배치하거나 클릭으로 복원하기 직전에는 교정된 정확한 range만 읽어 예상 결과와 같은지 비교하며, 비교한 문자열은 즉시 버리고 주변 텍스트는 요청하지 않습니다. 완성된 두 후보는 단어 경계에서 Apple의 기기 내 언어 자원에 일회성으로 조회하지만 앱이 따로 캐시하지 않습니다.

물리 키열로 재구성한 원문과 교정 결과는 판정 중의 bounded RAM과 최대 6초의 복원 transaction에만 존재합니다. 입력 단어나 교정 결과를 파일, 로그, UserDefaults 또는 네트워크에 저장·전송하지 않습니다. 적용 범위, 등록한 대상 앱 목록과 기능별 활성화 설정만 현재 사용자 계정의 macOS UserDefaults에 로컬로 저장합니다.

Mackor 프로세스가 직접 요청하는 네트워크는 Sparkle의 버전 확인과 서명된 공식 업데이트 다운로드뿐입니다. `이번 버전 변경사항…`은 사용자가 선택할 때 기본 브라우저로 GitHub Release 페이지를 엽니다. 입력 내용, 교정 결과, 대상 앱 목록은 업데이트 서버로 보내지 않으며 Sparkle 시스템 프로파일링도 비활성화합니다. feed URL이나 EdDSA 공개키가 없는 로컬 개발 빌드에서는 updater가 시작되지 않습니다.

## 삭제

메뉴바의 `앱 삭제 (Uninstall)`을 사용하는 것이 가장 확실합니다. 이 경로는 로그인 항목을 해제하고 앱과 저장된 설정을 함께 삭제합니다. 저장소의 외부 스크립트를 사용하려면 먼저 앱 메뉴에서 `로그인 시 자동 실행`을 끈 뒤 다음 명령을 실행하세요.

```bash
./uninstall.sh
```

Finder에서는 `uninstall.command`와 `uninstall.sh`를 같은 폴더에 둔 채 `uninstall.command`를 더블클릭하세요. 두 스크립트는 로그인 항목 확인을 요청한 뒤 `/Applications/Mackor.app`과 Installer 패키지 영수증 `com.mackor.app`을 제거합니다. 앱이 이미 실행되지 않으면 `시스템 설정 → 일반 → 로그인 항목`에서 Mackor를 먼저 제거하세요.

수동으로 제거하려면 다음 명령을 사용합니다.

```bash
sudo killall Mackor 2>/dev/null || true
sudo rm -rf /Applications/Mackor.app
sudo pkgutil --forget com.mackor.app
```

대상 앱 목록 등 사용자 설정과 macOS의 손쉬운 사용 권한 기록은 삭제 스크립트가 지우지 않습니다. 사용자 설정도 초기화하려면 앱을 종료한 뒤 `defaults delete com.mackor.app`을 실행하고, 손쉬운 사용 목록은 시스템 설정에서 직접 정리하세요.

legacy `/Applications/MacKR.app`(`com.mackr.app`)과 CorelHangulFix 설치본·설정·권한은 현재 제거 스크립트가 자동 삭제하거나 이전하지 않습니다. 두 앱이 남아 있으면 직접 종료·제거하고 손쉬운 사용의 옛 항목도 수동으로 정리하세요.

## 동작 원리

일부 macOS 앱은 `NSTextInputClient` 기반의 한글 조합 상태를 올바르게 처리하지 못합니다. Mackor은 대상 앱이 활성화된 동안 두벌식 물리 키코드를 한글 자모로 변환하고, 자체 조합 상태 머신으로 완성한 유니코드 문자를 해당 앱에 전달합니다.

실험적 자동 교정은 주변 텍스트를 읽는 대신 현재 단어의 제한된 물리 키 입력으로 영문과 두벌식 한글 후보를 각각 재구성합니다. 짧은 내장 사전·구조 규칙과 macOS의 로컬 영·한 언어 자원을 정해진 source-first 우선순위로 결합합니다. 단일 신호가 아니라 입력 방향, 길이·경계·시간, 후보 구조, 보호 패턴, 양쪽 사전 결과가 함께 맞을 때만 기존 단어를 교체합니다. 시스템 자원이 모르는 활용형·신조어·고유명사는 여전히 보수적으로 건너뛸 수 있습니다.

일반 앱의 IME 동작을 개선하는 시스템 확장이나 새로운 입력 소스는 아닙니다. 입력이 정상인 앱을 대상에 추가하면 예상치 못한 편집 동작이 생길 수 있습니다.

## 개발 및 빌드

PR과 `main` push에서는 `.github/workflows/ci.yml`이 shell 설치·릴리스 진입점의 구문, 전체 XCTest와 Release Analyze를 검사합니다. 외부 기여는 이 검사를 통과한 뒤 병합하며, 병합 자체가 Developer ID 서명이나 Apple 공증 권한을 부여하지는 않습니다.

Xcode가 설치된 macOS에서 로컬 Release 빌드 후 `/Applications`에 설치하려면 다음 명령을 실행합니다.

```bash
./install.sh
```

Apple Silicon과 Intel을 모두 포함한 PKG/DMG를 만들려면 다음 명령을 실행합니다.

```bash
./build-installer.sh
```

인증서가 없으면 스크립트가 개발용 ad-hoc 앱, 미서명 PKG, 미공증 DMG를 만들고 경고를 표시합니다. 공개 배포에서는 `REQUIRE_SIGNING=1`과 `REQUIRE_NOTARIZATION=1`을 모두 사용하며 업데이트 feed URL과 Sparkle EdDSA 공개키도 주입해야 합니다.

### Developer ID 서명 및 공증

먼저 `notarytool` 인증 정보를 로그인 키체인에 저장합니다. 앱 전용 암호를 사용하고 암호 자체를 빌드 명령이나 저장소에 넣지 마세요.

```bash
xcrun notarytool store-credentials "<KEYCHAIN_PROFILE>" \
  --apple-id "APPLE_ID" \
  --team-id "TEAM_ID" \
  --password "APP_SPECIFIC_PASSWORD"
```

그다음 키체인에 설치된 인증서의 전체 이름을 환경변수로 지정해 빌드합니다.

```bash
APP_SIGN_IDENTITY="Developer ID Application: Example (TEAMID)" \
INSTALLER_SIGN_IDENTITY="Developer ID Installer: Example (TEAMID)" \
NOTARY_PROFILE="<KEYCHAIN_PROFILE>" \
REQUIRE_SIGNING=1 \
REQUIRE_NOTARIZATION=1 \
MACKOR_UPDATE_FEED_URL="https://keilkim.github.io/MacKoreanImefixer/appcast.xml" \
MACKOR_SPARKLE_PUBLIC_ED_KEY="PUBLIC_KEY" \
./build-installer.sh
```

| 환경변수 | 설명 |
|----------|------|
| `APP_SIGN_IDENTITY` | 앱과 DMG에 사용할 Developer ID Application 인증서 전체 이름 |
| `INSTALLER_SIGN_IDENTITY` | 최종 PKG에 사용할 Developer ID Installer 인증서 전체 이름 |
| `NOTARY_PROFILE` | `notarytool store-credentials`로 저장한 키체인 프로필 |
| `REQUIRE_SIGNING` | `1`이면 앱 또는 PKG 인증서가 없을 때 즉시 실패 |
| `REQUIRE_NOTARIZATION` | `1`이면 공증 설정·승인·스테이플 검증이 없을 때 공개 빌드를 중단 |
| `MACKOR_UPDATE_FEED_URL` | 공개 HTTPS Sparkle appcast 주소 |
| `MACKOR_SPARKLE_PUBLIC_ED_KEY` | 업데이트 검증용 공개키; 개인키는 저장소 밖 Keychain 또는 release secret에만 보관 |
| `VERSION` | 표시 버전; 기본값 `1.3` |
| `BUILD_NUMBER` | `CFBundleVersion`; 기본값 `8` |

`REQUIRE_NOTARIZATION=1`과 `NOTARY_PROFILE`을 함께 지정하면 앱 공증용 archive, PKG, DMG를 각각 Apple에 제출합니다. 모두 승인된 뒤 앱·PKG·DMG에 티켓을 스테이플하고, 스테이플된 앱으로 Sparkle 업데이트 ZIP을 새로 만듭니다. appcast는 업데이트 자산을 먼저 게시한 뒤 가장 마지막에 공개해야 합니다.

서명 상태는 다음과 같이 별도로 확인할 수 있습니다.

```bash
codesign --verify --deep --strict --verbose=2 /Applications/Mackor.app
pkgutil --check-signature dist/local-build/Mackor_Installer.pkg
xcrun stapler validate dist/local-build/Mackor_Installer.pkg
xcrun stapler validate dist/local-build/Mackor.dmg
```

## 프로젝트 정보

| 항목 | 내용 |
|------|------|
| 소스 버전 | 1.3 (개발 중) |
| 최신 공개 배포 | legacy CorelHangulFix 1.1; 첫 공식 Mackor 기준선은 아직 미배포 |
| 개발사 | Draftup |
| 개발자 | SEONGHUN KIM / draftup@naver.com |

문제가 있으면 [Issues](../../issues)에 재현할 앱과 macOS 버전을 남겨주세요.

## 라이선스

[MIT License](LICENSE)
