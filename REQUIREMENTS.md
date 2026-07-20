# Mackor 요구사항

이 문서는 사용자가 요구한 것을 고정해 두는 기준 문서다. 작업 중 판단이 흔들리면
여기로 돌아온다. 추측이나 제안이 아니라 **사용자가 실제로 말한 것과 실측으로 확인된
사실만** 적는다.

최종 갱신: 2026-07-20

---

## 1. 제품 요구사항 (변경 불가)

### R1. 모든 앱과 프로그램에서 동작해야 한다

> "모든 앱 및 프로그램에서 mackor가 작동해야한다니까"
> "전체 모든 프로그램에서 작동하는거 아냐?"

- 앱을 사용자가 **등록하지 않아도** 동작해야 한다.
- 특정 앱군(네이티브 전용 등)으로 범위를 좁히는 것은 **요구사항 미충족**이다.
- 브라우저(Safari·Chrome), Electron(VS Code), 네이티브(카톡) 모두 포함한다.

### R2. 한글 조합 문제를 해결해야 한다 — 코렐만이 아니다

> "코렐 뿐만이 아니라 ㅋㅋㅋㅋㅋㅋㅋ"

- 이 현상은 CorelDRAW **한 앱의 문제가 아니라 여러 프로그램에서 공통으로** 나타난다.
- 따라서 "문제 앱 목록을 등록해서 처리"하는 방식은 근본 해결이 아니다.
- **TODO:** 같은 현상이 나타나는 프로그램 목록을 사용자에게 확인받아 여기에 채운다.
  현재 확인된 것: CorelDRAW. (나머지 미확인 — 추측으로 채우지 말 것)

### R3. 한/영 오입력 자동 변환을 유지해야 한다

영문 자판 상태로 한글을 친 경우(`dkwn` → `아주`) 자동으로 바로잡는 기능.
R2와 함께 **두 기능 모두** 유지되어야 한다. 하나를 버리는 설계는 미충족이다.

### R4. 지금 방식 그대로 IMK로 옮긴다

> "사실 지금 방식 그대~~~로 imk로 하길바라는거야"

- 동작·사용자 경험은 현재와 동일하게 유지한다.
- 바꾸는 것은 **구현 계층**이다: CGEvent 탭 + Accessibility → InputMethodKit.
- 기능 축소나 동작 변경을 동반한 "재설계"가 아니다.

### R5. 백업 가능해야 한다

> "백업은 가능하게 해야지~"

- 큰 작업 전에 **되돌릴 수 있는 지점**이 있어야 한다.
- 현재 신규 소스가 미추적 상태로 방치되면 안 된다.

### R6. 권한 프롬프트가 반복되면 안 된다

> "왜 자꾸 설치하면 권한 허용 두번뜨냐 귀찮게"

- 설치할 때마다 다시 승인해야 하는 상태는 해결 대상이다.
- 확인된 사실: 프롬프트는 **전부 "손쉬운 사용"**이며 입력 모니터링은 관여하지 않는다.

---

## 2. 릴리스 절차 요구사항

사용자가 지정한 순서. 임의로 건너뛰지 않는다.

1. 실기기 입력 확인
2. 전체 테스트 통과
3. 소스와 `install.command` 커밋·푸시
4. GitHub CI 통과 및 PR 병합
5. 병합된 정확한 커밋을 깨끗하게 체크아웃
6. 버전/build 번호 고정
7. Developer ID 서명 → Apple 공증 → staple
8. 공증된 DMG/PKG만 GitHub Release에 게시
9. **Sparkle appcast는 마지막**

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
| Developer ID Installer | **없음** | `security find-identity -v -p codesigning` 목록에 없음 → **PKG 불가, DMG만 가능** |
| 공증 제출 | 미완료 | 아직 submit/staple 안 됨 |
| 현재 설치본 서명 | ad-hoc | `Signature=adhoc`, `TeamIdentifier=not set`, `spctl: rejected` |

> `RELEASING.md`에 있던 "유효한 Developer ID identity 0개" 기술은 **사실과 달라 정정했다.**

### 권한 프롬프트가 두 번 뜨는 이유

TCC 권한이 두 개인 게 **아니다.** 다이얼로그가 두 개다.

1. `MackorApp.swift:38-48` — 앱 자체 `NSAlert` 안내창
2. 그 버튼 → `requestPermission()` → `checkAccessibilityPermission()`(`prompt: true`)
   → `AXIsProcessTrustedWithOptions` → macOS 시스템 프롬프트

매번 다시 뜨는 것은 **ad-hoc 서명이라 재빌드마다 코드 해시가 바뀌어** TCC가 새 코드
객체로 인식하기 때문. 해결책은 공증이 아니라 **안정적인 Developer ID 서명 + 동일
bundle ID/designated requirement 유지**.

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
- [ ] **백업 커밋** (R5)
- [ ] IMK 마이그레이션 설계 확정 (R4)
- [ ] IMK 구현
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
