# Mackor 요구사항

이 문서는 사용자가 요구한 것을 고정해 두는 기준 문서다. 작업 중 판단이 흔들리면
여기로 돌아온다. 추측이나 제안이 아니라 **사용자가 실제로 말한 것과 실측으로 확인된
사실만** 적는다.

최종 갱신: 2026-07-20

---

## 1. 제품 요구사항 (변경 불가)

### R1. 앱 등록 없이 시스템 전역에서 동작해야 한다

> "모든 앱 및 프로그램에서 mackor가 작동해야한다니까"
> "전체 모든 프로그램에서 작동하는거 아냐?"

**제품 의도 (변경 불가)**

- 앱을 사용자가 **등록하거나 허용 목록에 넣지 않아도** 동작한다.
- 특정 앱군(네이티브 전용 등)으로 좁히는 설계는 **요구사항 미충족**이다.

**합격 기준 (검증 가능한 형태)**

"문자 그대로 모든 프로그램"은 검증할 수 없다. IMK도 클라이언트가 macOS 텍스트 입력
계약(`IMKTextInput`)을 지원해야 동작한다. 따라서 합격 기준을 이렇게 정한다.

> 앱별 등록이나 허용 목록 없이 시스템 전역에서 활성화된다. 표준 macOS 텍스트 입력
> 클라이언트에서 동작해야 하며, 아래 **필수 호환성 대상**을 모두 통과해야 한다.

| 필수 대상 | 분류 | 현재 상태 |
|---|---|---|
| 카카오톡 | 네이티브 | 현재도 동작 |
| Safari | WebKit | 현재 실패 |
| Google Chrome | Chromium | 현재 실패 (실측: `focusedElement()` nil) |
| VS Code | Electron | 현재 실패 |
| CorelDRAW | 캔버스/커스텀 | R2 대상 |

**명시적 비대상 (동작하지 않아도 미충족이 아님)**

- 비밀번호 필드, Secure Event Input 활성 상태
- 물리 키코드를 직접 읽는 앱 (게임 엔진, IOHIDManager 직접 사용)
- VM·원격 데스크톱 클라이언트 (Parallels, VMware, RDP, VNC)

CorelDRAW 외 프로그램 목록(§R2)은 **기능 적용 대상 목록이 아니라 실기기 시험
매트릭스**다. 목록에 없는 앱에서 안 된다고 해서 설계가 앱 목록 기반이 되는 것은 아니다.

### R2. 한글 조합이 깨지는 현상 보완 — 코렐만이 아니다

> "한글로 작성하는데 코렐드로우처럼 한글이 먹히는 현상 보완"
> "코렐 뿐만이 아니라 ㅋㅋㅋㅋㅋㅋㅋ"

- 한글을 입력하는데 앱이 조합 중인 글자를 **먹어버리는(삼키는)** 현상.
- CorelDRAW **한 앱의 문제가 아니라 여러 프로그램에서 공통으로** 나타난다.
- 따라서 "문제 앱 목록을 등록해서 처리"하는 방식은 근본 해결이 **아니다.**
  전역으로 동작해야 한다 (R1과 결합).
- 사용자가 명시적으로 확인한 것: CorelDRAW.
- 아래 표는 웹 조사로 수집한 **출처 있는 보고**다 (2026-07-20 수집). 이것은 기능 적용
  목록이 아니라 **실기기 시험 매트릭스 후보**다(R1 참조). 신뢰도 표기:
  `확인됨` = 조사 에이전트가 출처 내용까지 확인, `부분확인` = 보고 존재는 확인했으나
  세부 재검증 미완. URL 재검증(2차)은 일부 미완료 상태로 기록한다.

**한글/CJK 조합 깨짐 보고 앱·툴킷 (조사 결과)**

| 앱/툴킷 | 계열 | 신뢰도 | 출처 |
|---|---|---|---|
| Discord | Electron | 확인됨 | github.com/korean-input/issues/issues/15 (3번째 글자 초성 삭제) |
| Notion | Electron | 확인됨 | github.com/gureum/gureum/issues/776 (앞 글자 소실) |
| Obsidian | Electron | 확인됨 | forum.obsidian.md — Korean input line merge |
| Figma | Electron+캔버스 | 확인됨 | forum.figma.com — 자모 분리·중복 |
| VS Code | Electron | 부분확인 | github.com/microsoft/vscode/issues/134254 (자모 분해) |
| ChatGPT 앱 | Electron계 | 확인됨 | community.openai.com (조합 취소·소실) |
| Electron webview 전반 | Electron | 확인됨 | github.com/electron/electron/issues/9173 |
| Qt 6.8.3/6.9.0 전반 | Qt | 확인됨 | bugreports.qt.io/QTBUG-136128 (첫 글자 깨짐) |
| JetBrains IDE | Java/Swing | 부분확인 | youtrack.jetbrains.com/IDEA-331220 외 복수 |
| Java AWT/Swing | Java | 부분확인 | bugs.openjdk.org/JDK-8068283 |
| Unity Editor/InputField | 자체 렌더링 | 부분확인 | issuetracker.unity3d.com (확정 시 소실) |
| Godot | 자체 렌더링 | 확인됨 | github.com/godotengine/godot/pull/85458 |
| Blender | 자체 렌더링 | 부분확인 | developer.blender.org/T43569 |
| Ghostty | 터미널 | 확인됨 | github.com/ghostty-org/ghostty/discussions/9213 (초성 소실) |
| Alacritty | 터미널 | 확인됨 | github.com/alacritty/alacritty/issues/6942 |
| kitty | 터미널 | 부분확인 | github.com/kovidgoyal/kitty/issues/4907 |
| Corel Vector | Electron/캔버스 | 부분확인 | discuss.gravit.io (CJK 입력기 오동작 — CorelDRAW 계열) |
| Avalonia (.NET) | 자체 렌더링 | 확인됨 | github.com/AvaloniaUI/Avalonia/issues/10031 |
| wxWidgets/wxSTC | wxWidgets | 부분확인 | github.com/wxWidgets/wxWidgets/issues/26228 |
| Evernote·AppFlowy·OBS(browser)·Toast UI·ink-text-input | 기타 | 부분확인 | 각 저장소 이슈 |

주목할 사실: 이 보고들은 전부 **Apple 기본 한글 IME를 쓰는데도** 깨진다는 내용이다.
즉 이 앱들은 NSTextInputClient(marked text)를 잘못 다루며, 이것이 R2 전달 사다리
(조합 존중 클라이언트 = marked text, 먹는 클라이언트 = 즉시 커밋)가 필요한 실증 근거다.

**합격 기준 (테스트 가능한 정의)**

"먹힘"은 사용자 표현이지 테스트 조건이 아니다. 아래를 모두 만족해야 통과다.

*포함하는 손상 유형*

| 유형 | 설명 |
|---|---|
| 누락 | 친 자모가 화면에 나타나지 않음 |
| 중복 | 같은 자모가 두 번 들어감 |
| 자모 잔류 | 조합이 확정되지 못하고 낱자가 남음 (예: `좀ㅅ`) |
| 잘못된 받침 | 받침이 다음 글자로 넘어가거나 잘못 붙음 |
| 커서 이동 후 손상 | 방향키·클릭으로 커서를 옮긴 뒤 조합이 깨짐 |

*시험 조건 — 각 필수 대상 앱마다 전부 수행*

- 최소 재현 문자열: `안녕하세요 반갑습니다` (받침·쌍자음·복모음 포함)
- **느린 입력**(자모당 200ms 이상)과 **빠른 입력**(키 롤오버 발생 수준) 각각
- 조합 확정 트리거별로: Space / Enter / Backspace / 방향키 / 마우스 클릭
- 각 조건 **10회 반복해 전부 무손실**이어야 통과 (1회라도 손상 시 실패)
- 기대 최종 문자열이 입력 의도와 **정확히 일치**해야 함

**[결정 D3] R2와 R3가 동시에 후보일 때 R2가 먼저다.**

같은 키 흐름에서 조합 보정(R2)과 오입력 전환(R3)이 함께 발동할 수 있다.
조합이 먼저 정상적으로 확정되어야 그 결과 문자열을 대상으로 R3 판정이 의미를 갖는다.
따라서 **R2로 조합을 확정한 뒤 그 확정 문자열에 R3 규칙을 적용**한다.
역순이면 깨진 조합을 대상으로 전환을 판정하게 되어 오탐이 발생한다.

### R3. 오입력 자동 전환 — 양방향 + 원문 칩 + 입력 소스 강제 전환

> "한글로 쓰는데 사실 영어로 써야 말이 되는걸 쓰던걸 영어로 자동 전환
> (전환 전것은 위에 버튼식으로 보여주기) 이후 영어로 한영 전환 강제 또는 영어 > 한글"

세 가지 동작이 **하나의 흐름**으로 묶인다. 어느 하나도 빠지면 미충족이다.

**R3-a. 자동 전환 — 양방향**

| 방향 | 상황 | 예 |
|---|---|---|
| 한 → 영 | 한글 IME가 켜진 채로 영어를 침 | `ㅗ디ㅣㅐ` → `hello` |
| 영 → 한 | 영문 자판 상태로 한글을 침 | `dkwn` → `아주` |

두 방향 **모두** 지원해야 한다. 한쪽만 되는 것은 미충족.

**R3-b. 전환 전 원문을 위에 버튼식으로 표시**

- 자동 전환이 일어나면 **바꾸기 전 원문**을 입력 지점 위에 버튼(칩) 형태로 보여준다.
- 사용자가 그 버튼을 누르면 원문으로 되돌릴 수 있어야 한다.
- 기존 구현 대응: `CorrectionNoticeController.swift`,
  `onOriginalChoiceAvailable` / `isOriginalChoiceActive` / `restoreOriginalChoice` /
  `cancelOriginalChoice` / `markOriginalChoiceChipVisible` (`MackorApp.swift:189-231`),
  `originalChoiceHitTest` (`MackorApp.swift:233`)

**R3-c. 전환 후 입력 소스 강제 전환**

- 텍스트만 바꾸고 끝내면 안 된다. 이어서 치는 글자가 또 틀리기 때문이다.
- 전환한 언어에 맞게 **입력 모드를 강제로 바꾼다.**
  (한→영 전환이면 이후 입력이 영문으로, 영→한이면 한글로)
- 기존 구현 대응: `InputSourceController.swift`,
  `onInputSourceSwitch` / `onInputSourceRestore` (`MackorApp.swift:249-253`),
  `AppMonitor.restoreInputSource` (`AppMonitor.swift:266-271`)

> **[결정 D1] IMK에서 R3-c는 Mackor 내부 모드 전환으로 구현한다.**
>
> **충돌:** IMK 입력기는 활성 입력 소스일 때만 입력 세션과 이벤트를 받는다. 따라서
> 교정 후 Apple ABC/두벌식으로 `TISSelectInputSource`를 호출하면 **Mackor 자신이
> 비활성화되어 다음 입력을 관찰하지 못한다.** R3-c를 문자 그대로 "Apple 입력 소스로
> 전환"으로 구현하면 R4(순수 IMK 전환)와 양립할 수 없다.
>
> **결정:** Mackor 입력 소스 **하나가 한글 모드와 영문 모드를 모두 소유**한다.
> R3-c의 "강제 전환"은 `TISSelectInputSource` 호출이 아니라 **Mackor 내부 모드 변수
> 전환**으로 달성한다. 사용자가 체감하는 효과(다음에 치는 글자가 맞는 언어로 나옴)는
> 동일하다.
>
> **사용자가 받아들여야 하는 대가:** Apple 두벌식 대신 **Mackor를 입력 소스로 선택**해야
> 한다. 입력기 목록에서 Mackor 하나만 쓰는 구성이 된다.
>
> **미검증 전제:** "전환 시 IMK가 비활성화된다"는 Apple 문서 기반 추론이며 실측하지
> 않았다. 구현 착수 전 최소 IMK 프로토타입으로 확인한다. (P0-1 참조)
>
> **메커니즘 정정 (2026-07-20 적대 검증):** 내부 모드 전환의 구현 수단은
> `TISSelectInputSource`가 아니라 **`IMKTextInput.selectMode(모드ID)`**다 — Gureum이
> 실사용하는 검증된 경로이며, Gureum 리포에 `TISSelectInputSource` 호출은 0건이다
> (`OSXCore/InputReceiver.swift` 실측). 시스템발 모드 변경 수신용
> `setValue(forTag: kTextServiceInputModePropertyTag)` 구현이 짝으로 필수다.

### R3+R2 관계

두 기능은 **모두** 유지되어야 한다. 하나를 버리는 설계는 미충족이다.
현재 코드에서는 `AppMonitor.swift:276`이 두 기능을 배타적으로 만들어 놓았는데
(`.allApps`면 R2가 꺼짐), **IMK 이후에는 둘이 동시에 동작해야 한다.**

### R4. 지금 방식 그대로 IMK로 옮긴다

> "사실 지금 방식 그대~~~로 imk로 하길바라는거야"

- 동작·사용자 경험은 현재와 동일하게 유지한다.
- 바꾸는 것은 **구현 계층**이다: CGEvent 탭 + Accessibility → InputMethodKit.
- 기능 축소나 동작 변경을 동반한 "재설계"가 아니다.

### R4-1. 코어 규칙은 그대로 전수한다 (재작성 금지)

> "우리가 개발했던 코어 규칙도 전수하는거지?"

IMK 전환은 **계층 교체**지 규칙 재작성이 아니다. 아래 자산은 손대지 않고 그대로
옮긴다. 규칙을 다시 만들거나 "더 나은 방식"으로 바꾸는 것은 **요구사항 위반**이다.

**전수 대상**

| 구분 | 대상 |
|---|---|
| 규칙 코드 | `LayoutCorrectionPolicy.swift`(§2.3), `EnglishPhonotactics.swift`(§2.2), `HangulStructure.swift`(§2.1), `KSX1001Table.swift`, `WrongLayoutCorrectionEngine.swift` |
| 조합 코드 | `HangulCompositionTracker.swift`, `HangulUnicode.swift`, `KeycodeToJamoMap.swift` |
| 골든 코퍼스 | `Corpus/structure-correction/v2/golden.tsv` (406줄), v1 `holdout.tsv`(28) · `tune.tsv`(24) · `system-evidence.tsv`(21) |
| 규칙 벤치 | `scripts/rulebench/` (auto.py, bench.py, genrules.py, make_golden.py, make_ksx1001.py, ko_words.txt, ksx1001.txt) |
| 규범 문서 | `STRUCTURE_CORRECTION_DESIGN4.md` (§2.1–2.3 규칙 ID 정의), `STRUCTURE_CORRECTION_DESIGN3.md` (마침표 상태기계·원문 선택 UI) |

**전수 보증 방법**

규칙이 실제로 보존됐는지는 말로 확인하지 않는다. **테스트와 코퍼스가 판정한다.**

- 규칙 관련 테스트 44개(`LayoutCorrectionPolicyTests` 17,
  `WrongLayoutCorrectionEngineTests` 19, `KSX1001TableTests` 6,
  `StructureCorrectionCorpusTests` 2)가 **수정 없이 그대로 통과**해야 한다.
- 골든 코퍼스 판정 결과가 마이그레이션 전후로 **동일**해야 한다.
- 테스트를 고쳐서 통과시키는 것은 전수 실패다. 테스트가 기준이다.

즉 IMK 계층은 이 엔진들을 **호출하는 껍데기**여야 한다. 엔진 안으로 IMK 개념이
스며들면 안 된다.

### R5. 백업 가능해야 한다

> "백업은 가능하게 해야지~"

- 큰 작업 전에 **되돌릴 수 있는 지점**이 있어야 한다.
- 현재 신규 소스가 미추적 상태로 방치되면 안 된다.

### R6. 권한 프롬프트가 반복되면 안 된다

> "왜 자꾸 설치하면 권한 허용 두번뜨냐 귀찮게"

- 설치할 때마다 다시 승인해야 하는 상태는 해결 대상이다.
- 확인된 사실: 프롬프트는 **전부 "손쉬운 사용"**이며 입력 모니터링은 관여하지 않는다.
- IMK 전환 후: **현 기능 범위에서는** 권한이 아예 불필요하다 (Gureum도
  `AXIsProcessTrusted` 0건). 단, 추후 "Caps Lock/우측 ⌘로 한영 전환" 류 기능을 넣으면
  **입력 모니터링 권한이 부활**한다 — Gureum이 정확히 그 이유로
  `IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)`를 호출한다
  (`OSX/GureumAppDelegate.swift`). 프롬프트 소멸 주장은 기능 범위 한정으로만 유효.

---

## 2. 릴리스 절차 요구사항

사용자가 지정한 순서. 임의로 건너뛰지 않는다.

1. 실기기 입력 확인
2. 전체 테스트 통과
3. **버전/build 번호를 소스에 고정** ([결정 D2] 참조)
4. 소스와 `install.command` 커밋·푸시 (버전 고정분 포함)
5. GitHub CI 통과 및 PR 병합
6. 병합된 정확한 커밋을 깨끗하게 체크아웃 — **이 시점 이후 소스를 수정하지 않는다**
7. Developer ID 서명 → Apple 공증 → staple
8. 공증된 DMG/PKG만 GitHub Release에 게시
9. **Sparkle appcast는 마지막**

> **[결정 D2] 버전/build 번호는 PR 전에 소스에 고정해 함께 병합한다.**
>
> 이전 순서는 버전 고정을 PR 병합 **뒤**에 두었다. 버전이 프로젝트 파일 변경이므로,
> 병합된 커밋을 체크아웃한 뒤 다시 수정하면 **빌드한 트리가 병합된 커밋과 달라진다.**
> "병합된 정확한 커밋으로 빌드"가 성립하지 않고 재현성이 깨진다.
>
> 따라서 버전·build를 소스에 박은 상태로 PR을 올려 함께 병합하고, 체크아웃 이후에는
> 소스를 일절 수정하지 않는다.
>
> 주의: 버전 상수가 `build-installer.sh:10-11`, `install.sh:10-11`, `project.pbxproj`
> 세 곳에 있다. 고정할 때 **세 곳을 함께** 맞춰야 한다.

### 금지사항

- `dist/local-build` 등 개발용 산출물을 GitHub Release에 올리지 않는다.
- 인증서·공증 자격증명·Sparkle **개인키**를 커밋하지 않는다. (공개키는 무방)

---

## 3. 실측으로 확인된 사실

추측이 아니라 이 머신에서 실제로 실행해 확인한 것만 적는다.

### 서명·배포

| 항목 | 상태 | 근거 |
|---|---|---|
| Developer ID Application | **있음, 서명 성공** | `Authority=Developer ID Application: SEONGHUN KIM (TZQ9JL6R7R)` → `Developer ID CA` → `Apple Root CA`, exit 0 |
| Developer ID Installer | **없음** | 목록에 없음 → **공개 배포용 서명 PKG 불가, DMG 경로만 가능.** 미서명 개발용 PKG 생성 자체는 가능 |
| 공증 제출 | 미완료 | 아직 submit/staple 안 됨 |
| 현재 설치본 서명 | ad-hoc | `Signature=adhoc`, `TeamIdentifier=not set`, `spctl: rejected` |

> `RELEASING.md`에 있던 "유효한 Developer ID identity 0개" 기술은 **사실과 달라 정정했다.**

### 권한 프롬프트가 두 번 뜨는 이유

TCC 권한이 두 개인 게 **아니다.** 다이얼로그가 두 개다.

1. `MackorApp.swift:38-48` — 앱 자체 `NSAlert` 안내창
2. 그 버튼 → `requestPermission()` → `checkAccessibilityPermission()`(`prompt: true`)
   → `AXIsProcessTrustedWithOptions` → macOS 시스템 프롬프트

**[실측]** 두 창이 모두 손쉬운 사용에 관한 것이라는 점, 그리고 코드가
`AXIsProcessTrustedWithOptions`만 호출하고 Input Monitoring 요청 API는 쓰지 않는다는 점.

**[가설 — 미검증]** 매번 다시 뜨는 원인이 "ad-hoc 서명이라 재빌드마다 코드 해시가 바뀌어
TCC가 새 코드 객체로 인식하기 때문"이라는 설명은 **아직 검증하지 않았다.** Developer ID로
서명한 빌드와 ad-hoc 빌드를 각각 재설치해 프롬프트 재발생 여부를 비교해야 확정된다.
확정 전까지 "공증하면 해결된다"고 말하지 않는다.

### 현재 구조가 브라우저에서 실패하는 지점

사용자 머신 실제 진단 로그(Chrome, pid 667):

```
[Mackor][diagnostic] lazy accessibility pid=667 result=-25205
[Mackor][diagnostic] focus token missing focused element
```

- `-25205` = `kAXErrorAttributeUnsupported`
- 실패 지점은 AX role 화이트리스트도, 메타데이터 필터도 **아니다.**
  그 이전 단계인 `FocusedInputSafety.focusedElement()`가 nil을 반환한다.

AX 프로브 직접 측정 결과:

| 앱 | `AXEnhancedUserInterface` | `AXManualAccessibility` |
|---|---|---|
| Chrome (667) | settable=true, **현재값 1 (이미 켜짐)** | 미지원 (-25205) |
| Safari (664) | settable=true, 현재값 0 | 미지원 (-25205) |

→ `AppMonitor.swift:177-185`의 `AXManualAccessibility` 설정은 **두 브라우저에서 무효**.
→ 다만 Chrome은 enhanced UI가 **이미 켜져 있는데도 실패**하므로, 속성만 바꾼다고
   해결되지 않는다. 구조적 한계다.

### 증상 관찰

- 카톡: 잘 동작
- Safari / Chrome / VS Code: 대체로 실패
- **같은 입력란 안에서도 간헐적** — 일부 단어만 변환되고 나머지는 조용히 실패
- 자모가 남는 손상 사례 있음 (`좀ㅅ`)
- 영문 단어는 올바르게 그대로 유지됨 (오탐은 없음)

### 코드 구조상 확인된 것

- `AutoCorrectionScope`가 `.allApps`면 `TargetAppManager.swift:177-179`가 앱 목록을
  조회하지 않고 무조건 `true` 반환 → **앱 등록은 자동 교정에 무의미**
- 단, `AppMonitor.swift:276`이 `scope == .selectedApps`를 요구하므로
  **`.allApps` 모드에서는 한글 직접 조합 보정이 통째로 꺼진다.** 두 모드는 배타적.
- AX 요청 타임아웃 50ms (`FocusedInputSafety.swift:41`), 초과 시 조용히 실패

---

## 4. 진행 상태

- [x] 이벤트 탭 무효화 복구 버그 수정 (`CFMachPortIsValid` 검사 추가)
- [x] `RELEASING.md` 서명 관련 사실 오류 정정
- [x] 전체 테스트 통과 확인 (161 tests, 0 failures)
- [x] **백업 커밋** (R5) — `a1c5828` + 태그 `pre-imk`, 원격 푸시 완료 (`origin/main` = `d27ea90`)
- [x] `ARCHITECTURE.md:444` 인증서 기술 정정 (RELEASING.md와 모순 해소)
- [ ] **P0-1. IMK 프로토타입으로 D1 전제 검증** — 최소 기능 IMK 입력기를 만들어
      `TISSelectInputSource`로 Apple 입력 소스로 전환했을 때 자기 자신이 비활성화되어
      입력 관찰이 끊기는지 **실측**한다. 결정 D1의 근거가 문서 기반 추론이므로
      **구현 착수 전에 반드시 확인한다.**
- [x] **P0-2. R2 대상 프로그램 목록 확보** — 출처 있는 25종 수집 완료 (§R2 표).
      실기기 시험 대상 선정: 필수 5종(R1 표) + 확장(Discord·Notion·Obsidian·터미널 1종)
- [ ] IMK 마이그레이션 설계 확정 (R4) — P0-1 결과 반영 후
- [ ] IMK 구현
- [ ] 권한 반복 가설 검증 — Developer ID 서명본 vs ad-hoc 재설치 비교
- [ ] R2 대상 프로그램 목록 확인
- [ ] 릴리스 절차 진행

---

## 5. 미해결 질문 (사용자 확인 필요)

1. **R2 대상 프로그램**: CorelDRAW 외에 한글 조합이 깨지는 프로그램은 무엇인가?
2. **PKG 배포**: `Developer ID Installer`가 없어 현재 DMG만 가능하다.
   인증서를 추가 발급할 것인가, DMG만 배포할 것인가?
3. **권한 안내창**: 앱 자체 안내창을 없애고 시스템 프롬프트 하나만 띄울 것인가?
   (안내창에 "입력 내용은 저장하거나 전송하지 않습니다" 문구가 있어 신뢰 측면 이점은 있음)
4. **기존 v1.1 릴리스**: 새 릴리스 게시 후 삭제할 것인가?

---

## 6. 작업 원칙 (자기 점검용)

이 세션에서 실제로 발생한 실패를 근거로 한 규칙:

- **검증 전에 결론을 말하지 않는다.** 중간 분석 결과를 확정처럼 전달해 여러 번 틀렸다.
- **코드를 읽고 추론한 진단보다 실측을 우선한다.** 로그 한 줄이 추론 열 개보다 정확했다.
- **문서보다 머신 상태를 믿는다.** `RELEASING.md`의 인증서 기술이 실제와 달랐다.
- **파일을 지우기 전에 참조를 확인한다.** 현행 문서를 폐기 초안으로 오인해 삭제했다.
