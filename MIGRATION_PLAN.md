# Mackor IMK 마이그레이션 계획

기준 문서: [`REQUIREMENTS.md`](REQUIREMENTS.md) (R1~R6, D1~D3)
복구 지점: 태그 `pre-imk` (`a1c5828`, 원격 푸시 완료)
작업 브랜치: `imk`

> 이 문서는 저장소 안에 둔다. 계획이 커밋별로 리뷰되어야 하기 때문이다.
> (이전에는 `~/.claude/plans/`에만 있어 리뷰 불가능했다.)

---

## 1. 왜 이 작업인가

현재 구조(CGEvent 탭 + Accessibility)의 두 실패가 실측으로 확인됐다.

- **앱 의존 실패**: Chrome에서 `FocusedInputSafety.focusedElement()` nil.
  `AXManualAccessibility` 미지원(-25205), `AXEnhancedUserInterface`는 이미 켜져 있는데도 실패.
- **타이밍 실패**: 키 롤오버 경합 — 스페이스 keyUp 전에 다음 키를 누르면 보정이 조용히
  폐기(`EventTapManager.swift:435`). **실행 테스트로 증명됨.**

추가로 사용자가 겪은 R2 회귀: `AutoCorrectionScope = allApps`가
`AppMonitor.swift:276`에서 한글 조합 보정을 통째로 끈다. CorelDRAW가 등록돼 있어도
동작하지 않는다. 현재 구조에서 R2와 R3는 **배타적**이다.

---

## 2. 확정 아키텍처

**단일 번들 `Mackor.app`** = 메뉴바 UI + IMKServer,
설치 위치 `~/Library/Input Methods/` (사용자 도메인, sudo 불필요 — P0-8 실측 확인).
번들 ID: `com.mackor.inputmethod.Mackor` (입력기 관례; 구 `com.mackor.app` defaults는 Phase 5에서 이전).

### 2-1. 입력 모드는 **하나**다 (D1 대체안, 실측 근거)

두 모드(han2/roman) 방식은 **실측에서 실패**했다:

| 시도 | 결과 |
|---|---|
| `IMKTextInput.selectMode(roman)` | 모드 안 바뀜 (0/50/250/1000ms 전부 원래 모드) |
| `TISSelectInputSource(roman)` | `-50` (paramErr) |
| `TISEnableInputSource(roman)` | `0` 반환하지만 실제 `enabled=false` 유지 |

원인은 두 번째 모드가 `enabled=false`이고 **프로그램적 활성화가 불가능**하다는 것이다
(사용자가 시스템 설정에서 직접 추가해야 함).

**Apple 한국어 IME도 동일 구조다** — 활성 모드는 `2SetKorean` 하나뿐이고
(3Set·390Sebulshik·Romaja 전부 `enabled=false`), 한/영은 **IME 내부 처리**다.

→ **모드 하나 + 한/영 내부 불리언.** R3-c는 API 호출이 아니라 내부 상태 전환이 되고,
D1 문제와 모드 추가 온보딩 부담이 함께 소멸한다.

### 2-2. 교정 적용: mozc 패턴 (실측 확인)

**규칙: 대상 범위에 먼저 `setMarkedText`로 조합을 건 뒤 같은 범위로 커밋한다.**

```
setMarkedText(교정문, replacementRange: 단어범위)   →  화면의 확정 텍스트가 대체됨
insertText(교정문,  replacementRange: 단어범위)    →  확정
```

TextEdit 실측 (`MackorIMEProbe/p0-round2-textedit.log`):

| 호출 | 결과 |
|---|---|
| `setMarkedText(범위)` → `insertText(같은 범위)` | **작동** (`ab` → `한글`) |
| `insertText(범위)` 단독 | 무시 |
| `insertText("", 범위)` ranged 삭제 | 무시 |

`supportsProperty(DocumentAccess) = true`,
`validAttributesForMarkedText`에 `NSTextInputReplacementRangeAttributeName` 포함.

**선례**: mozc `mozc_imk_input_controller.mm` — `replacementRange_`를 하나 두고
`setMarkedText`(L684-687)와 `insertText`(L465)에 공유, 커밋 직후 `NSNotFound`로 리셋.
단위 테스트도 존재(`mozc_imk_input_controller_test.mm:576-584`).

**자동 소급 교정의 선례**: mozc `DeletionRange` (`commands.proto:1322-1338`) —
사용자 선택 없이 IME가 캐럿 앞 **확정 텍스트**를 음수 offset으로 덮어쓴다.
Mackor가 필요로 하는 것과 같은 성격이다.

**→ 합성 백스페이스가 불필요하다.** 따라서 권한(`CGRequestPostEventAccess`) 문제도
기본 경로에서는 발생하지 않는다.

### 2-3. 앱 호환성 가드 (선례 3건이 모두 같은 지점에서 다침)

`replacementRange`·`selectedRange`는 앱마다 다르게 동작한다. 실제 IME들의 대응:

- **mozc**: `CanSelectedRange()` — MS Excel/PowerPoint/Word 제외
  ("could lead to application crash"), Evernote는 `attributedSubstringFromRange`가
  "very heavy"라 제외
- **vChewing**: `replacementRange 不要亂填，否則會在 Microsoft Office 等軟體內出現故障`
  (함부로 채우면 MS Office에서 오작동)
- **Squirrel·Gureum**: `replacementRange`를 아예 쓰지 않음(`.empty` 고정)

→ **번들 ID 시드 목록은 선택이 아니라 필수**다. 조사로 확보한 조합 깨짐 앱 25종
(REQUIREMENTS §R2)과 위 크래시 위험 앱을 함께 동봉한다. 사용자 등록이 아니라
**출하 데이터**이므로 R1과 양립한다.

### 2-4. 되돌리기

**1차 트리거는 칩 클릭.** ⌘Z는 실측상 `handle()`에 도달하지 않는다
(TextEdit에서 로그 없이 앱 자체 Undo가 실행되어 앞 내용이 지워짐).
칩 앵커는 `attributes(forCharacterIndex: 0, lineHeightRectangle:)` — marked text 없는
커밋 직후에도 유효 rect 반환 확인 (`(214.76, 979.0, 1.0, 13.0)`).

---

## 3. 요구사항 대응

| 요구 | 방식 |
|---|---|
| R1 전역 | 입력 소스는 시스템 전역. 앱 등록 불필요. 필수 매트릭스로 합격 판정 |
| R2 조합 보호 | 조합 존중 앱 = 일반 IME 조합. 조합을 먹는 앱 = 즉시 커밋 후 mozc 패턴 교정. 판정은 런타임 탐지 + 시드 목록 + 사용자 오버라이드 |
| R3-a 양방향 | 단일 모드가 한/영을 모두 소유하므로 양방향 관찰 가능 |
| R3-b 칩 | `CorrectionNoticeController` 무수정, 앵커만 IMK rect로 교체 |
| R3-c 강제 전환 | **내부 불리언** (§2-1) |
| R4-1 규칙 전수 | 파일 이동 0건 + SHA-256 동결 가드 + 호출 경로 통합 테스트 |
| R6 권한 | 기본 경로에 합성 이벤트 불필요 → 권한 불필요. rung 3 폴백만 예외 |
| D3 우선순위 | 조합 확정(R2) → 확정 문자열에 R3 판정 |

---

## 4. 단계

### Phase 0 — 실측 【진행 중】

완료(TextEdit): P0-8 등록 ✅ / mozc 패턴 치환 ✅ / 칩 앵커 ✅ / ⌘Z 미도달 ✅ /
D1 두 모드 방식 실패 → 단일 모드로 대체 ✅

**남은 것 (Phase 2 진입 게이트):**
1. **CorelDRAW** — `handle()` 도달 여부, marked text 표시, mozc 패턴 동작. 최대 리스크 R-1
2. Safari / Chrome / VS Code / 카톡 — 조합 유지 및 mozc 패턴 동작 → rung 판정·시드 목록
3. 별도 `NSTextView` 시험 앱 — 대조군(앱 버그와 API 한계 분리)
4. 물리 키 입력 병행 검증 (현재는 CGEvent 합성만)
5. 보안 필드 / SwiftUI+IMKServer 공존 / quarantine

### Phase 1 — R4-1 동결 가드 (파일 이동 0건)

프레임워크 추출안은 폐기했다(엔진 전부 internal, 테스트에 import 없음 → 어느 쪽이든
R4-1 위반). 대신 `scripts/engine-freeze.sha256`으로 21파일을 동결하고 CI에서 검증한다.

**보완 필요** (검토 지적):
- 누락 파일 추가: `scripts/rulebench/*` 7개, `STRUCTURE_CORRECTION_DESIGN3/4.md`,
  `Corpus/structure-correction/v1/README.md`
- manifest와 엔진을 같은 PR에서 함께 바꾸면 통과하는 허점 → 기준 커밋
  `a1c5828`과 직접 비교하는 검사 추가
- 동결 파일이 실제 빌드에 포함되는지, 새 `MackorSessionCore`가 동결 엔진을 호출하는지
  검증하는 통합 테스트 추가

### Phase 2 — IMK 골격

Info.plist는 Squirrel·Gureum 실물 구조 준용(`InputMethodConnectionName`,
`InputMethodServerControllerClass`, `ComponentInputModeDict`—**모드 1개**,
`tsInputMethodCharacterRepertoireKey`). `recognizedEvents`에 keyDown+flagsChanged+마우스.
**passthrough 불변식**: `handle()` 전체 방어 래핑, 어떤 오류에도 `false` 반환.

### Phase 3 — R2 전달 사다리
### Phase 4 — R3 교정 + 칩 + 내부 모드 전환
### Phase 5 — 구앱 정리 + 패키징 (defaults 도메인 이전 포함)
### Phase 6 — 검증 매트릭스 + 릴리스

---

## 5. 리스크

| # | 리스크 | 완화 |
|---|---|---|
| R-1 | CorelDRAW가 IMK에 도달하지 않을 가능성 | Phase 0 최우선 측정. 실패 시 rung 3(합성 이벤트, 옵트인) |
| R-2 | IME 크래시 = 전체 타이핑 차단. imklaunchagent는 반복 크래시 시 실행 자체를 거부 | passthrough 불변식. README에 탈출로 명시("Apple 두벌식을 목록에서 지우지 마세요") |
| R-3 | 앱별 `replacementRange` 동작 차이·크래시 | 시드 블랙리스트(mozc·vChewing 선례 준용) |
| R-4 | Sparkle가 실행 중 IME 교체 | Squirrel 선례 조사 + 실기기 검증 |
| R-5 | 온보딩(입력 소스 수동 추가) | 설치 스크립트가 `--register`/설정 화면 자동 오픈 |

## 6. 공수

P0 잔여 1~2일 → 재추정. 전체 3~5주 추정(코드량은 순감소).

## 7. 검증

- 매 Phase: 전체 테스트 + 규칙 44 + 골든 405 **무수정** 통과
- 회귀 기준: `pre-imk`와 골든 코퍼스 판정 diff = 0
- 실기기: REQUIREMENTS §R2 시험 조건(느림/빠름 × 트리거 5종 × 10회 무손실)
