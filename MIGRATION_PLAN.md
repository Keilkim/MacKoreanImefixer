# Mackor 하이브리드 아키텍처 실행 계획 (IMK 주 경로 + CGEvent 탭 폴백)

기준: `REQUIREMENTS.md`(R1~R6, D1~D3) · 복구 지점 태그 `pre-imk` · 작업 브랜치 `imk`
사용자 결정: **2번 — 하이브리드로 근본 해결** (브라우저 포함 전역 + CorelDRAW 유지)

설계 출처: 독립 설계 3안 → 적대 심판 2회(둘 다 risk-first 선택) → 종합.
모든 파일:줄 인용은 종합 에이전트와 이 세션에서 워킹트리 실물로 확인됨.

---

## 1. Context

### 왜 하이브리드가 강제되는가 (전부 실측)

- **CorelDRAW는 IMK로 해결 불가**: IMK 세션은 성립하고 키도 `handle()`에 오지만,
  `true`(소비)를 반환해도 앱이 키를 그대로 입력한다(사용자 실측 `ab∞§£`).
  `selectedRange()=NSNotFound`, `length()=0`, 캐럿 rect `(0,0,0,0)`,
  `supportsDocumentAccess=true`는 **거짓 신고**. → 자모가 로마자로 새므로 조합 불가.
  CorelDRAW류는 **이벤트 탭이 유일한 경로**다 (역사적으로 동작했음).
- **브라우저는 탭으로 해결 불가**: Chrome에서 `focusedElement()` nil (AX 비협조).
  → 표준 앱군은 **IMK가 유일한 경로**다.
- 표준 앱에서 IMK는 완전 동작 확인: mozc 패턴(`setMarkedText(범위)` → `insertText(같은 범위)`)으로
  확정 텍스트 치환 성공, D1(`selectMode` 자기 모드 전환 후 생존) 성립, CapsLock 한/영 전환 시스템 제공.

### 목표 상태

| 앱군 | 경로 | 권한 |
|---|---|---|
| TextEdit·카톡·Safari·Chrome·VS Code·터미널 | IMK (rung 1/2) | 불필요 |
| MS Office·Evernote | IMK 조합만 (rung 0, 프로브 금지) | 불필요 |
| CorelDRAW류 | 이벤트 탭 (rung 3) | 손쉬운 사용 (지연 요청) |

R1(등록 불필요)·R2·R3 동시 충족. R6은 "rung 3 앱을 안 쓰면 프롬프트 0회"로 충족.

---

## 2. 핵심 아키텍처 (요지)

### 2-1. 세션 단위 중재 — `TransportArbiter`

탭은 `.headInsertEventTap`으로 IMK(TSM)보다 **상류**(`EventTapManager.swift:346-352`).
키 단위 중재는 불가능 — 소유권은 키 도착 **전에** 세션 단위로 결정.

```swift
@MainActor final class TransportArbiter {
    enum Owner: Equatable { case tap; case imk(clientSessionID: UUID); case none }
    private(set) var owner: Owner = .tap   // 단일 writer: MackorInputController만
}
```

- 락 없음(양쪽 다 메인 스레드, `dispatchPrecondition`으로 강제). 탭 콜백 안 락은 `tapDisabledByTimeout` 유발.
- 읽기는 평문 프로퍼티만. **키 경로에서 AX 절대 금지**(50ms 타임아웃이 탭을 죽임).
- 전이 시점은 `activateServer`/`deactivateServer`/프론트앱 변경/TIS 변경뿐. **키 입력은 전이 시점이 아니다.**
- 타이머 없음 — 상태는 파생(활성 IMK 세션 없음 → `.tap`).
- flap 대응: 핸들러 멱등 + clientID 키 세션 캐시(TTL은 Phase C 실측 후 결정 — 로그의 1–3ms activate/deactivate 쌍이 근거).
- `.none` = 양쪽 passthrough. 최악은 교정 안 된 키 몇 개, 이중 교정 불가.
- 이중 교정 불가능성: `.imk`면 탭이 **기록도 주입도 안 함**, `.tap`이면 IMK가 무조건 `false`, 동시 활성 상태는 열거형에 없음.

### 2-2. 탭 측 게이트 — 정확히 세 곳 (텍스트 쓰기 진입점 전수)

| 게이트 | 위치 | 핵심 |
|---|---|---|
| (a) `handleKeyDown` 최상단 | `:435`의 무조건 invalidate보다 **위** | `arbiter.tapOwnsCurrentSession`을 **한 번만** 지역 변수로 읽음(중간 재조회 금지 — 재진입 activate가 기록/조합 사이에 끼면 엔진 모델 파손) |
| (b) 게이트 위치는 기록(`:566`/`:602`) **위** | 조합(`:628`)이 아님 | 주입만 막고 기록을 계속하면 엔진이 남의 화면에 다음 경계에서 교정 발사 |
| (c) `handleKeyUp` | 현재 가드 **전무**, 지연 교정 무장 지점(`:650-659`) | 가드 추가하되 suppressed 집합 정리는 가드 밖 유지(고아 keyUp 방지) |

### 2-3. 주입 재진입 — 비대칭이 답

- **방향 A (탭 합성 → IMK)**: 기존 이중 태깅 유지·확장 — `injectionMarker 0x48474C46` + 필드 42
  (`:1303-1309`). private → internal로 열어 IMK `handle()` **첫 문장**에서
  `if let cg = event?.cgEvent, EventTapManager.isInjected(cg) { return false }`.
  **단, 1차 방어선은 arbiter다** (탭 소유 클라이언트에서 IMK는 어차피 무조건 false) —
  필드 42의 NSEvent 왕복 생존은 **미측정**(A-1)이라 마커는 심층 방어.
  백스톱: in-process 주입 카운터 + 250ms 데드라인 (마커 우선, 카운터 단독 금지 — 진짜 백스페이스를 삼킴).
- **방향 B (IMK 쓰기 → 탭)**: `setMarkedText`/`insertText`는 TSM IPC — **CGEvent가 아니라서 탭에 안 보임**. 필터 불필요.
  실제 위험은 "IMK 소유 중에도 물리 키는 탭을 통과"이며 게이트 (b)가 담당.
  빌드 규칙: `QuartzKeyboardOutput` 밖에서 `CGEvent(...).post` 금지 (자동 태깅 보장).
- 탭→탭: `:425-427`의 주입 검사가 `:435`보다 위인 순서는 **load-bearing** — 주석으로 고정.

### 2-4. 앱 분류기 (rung 사다리) — 첫 단어 보장

**미분류 = 탭 소유.** 분류는 `activateServer`에서 키 0회 입력 전에 완료 — "첫 단어 문제"가 발생 자체를 안 함.

```
activateServer(client):
  rung 0 금지 목록(MS Word/Excel/PowerPoint — mozc가 selectedRange 크래시 기록, Evernote)
    → 프로브 없이 rung 0 (조합만, replacementRange 사용 금지)
  프로브 3종 (자기 신고 완전 무시, 실제 질의만):
    length() / selectedRange() / attributes(forCharacterIndex:0, lineHeightRectangle:)
    → CorelDRAW는 3중 실패로 키 0회에 rung 3 자동 분류 (실측 근거)
  통과 + 캐시에 clean 세션 ≥ 3 → rung 1/2 승격
  아니면 → rung 3 유지 + 백그라운드 조합 왕복 검증(setMarkedText("ㅎ")→markedRange 확인→즉시 클리어)
    결과는 캐시에, 승격은 다음 activateServer부터
```

- **세션 중간 강등 금지 / 승격은 다음 세션부터** — 한 토큰이 두 전송으로 쪼개지지 않음.
- 캐시: `bundleID + CFBundleVersion → rung` 힌트. **강등 즉시·권위적, 승격 3회 clean.** 매 activate 재프로브(IPC 3회 — 무시 가능).
- 처음 보는 앱 첫 세션은 탭(권한 없으면 침묵). **침묵 허용, 손상 불허.**
- `TargetAppManager`: 1차 라우터에서 물러나 사용자 override 전용.
- R1 충족: 사용자 등록 0, 전부 출하 시드 + 런타임 프로브 (mozc/vChewing 전례).

### 2-5. 공유 코어 — 결정과 실행 분리

엔진은 이미 전송 중립(`PhysicalKeystroke`에 client/NSEvent/AX 채널 자체가 없음). 할 일은 안 깨뜨리기.

```swift
// CoreGraphics/AppKit/IMK import 없음
enum EditOp { case deleteCharacters(Int); case insert(String)
              case replaceRange(TokenRange, with: String); case switchDirection(CorrectionDirection) }
struct EditPlan { let ops: [EditOp]; let undo: UndoRecord }
final class MackorSession {   // tracker + engine + tokenCaptureState + 마침표 상태기계 소유
    func keystroke(_:source:) -> EditPlan; func boundary(_:) -> EditPlan; func backspace() -> EditPlan
}
```

- **TapRenderer**: 기존 `executeResult`(`:1268-1284`)/`applyCorrection`(`:1054`) 로직 **이동**(재작성 아님). `replaceRange`는 delete+insert로 강하.
- **IMKRenderer**: `setMarkedText(범위)` **후** `insertText(같은 범위)` — 순서는 실측 강제(단독 insertText는 무시됨). rung 2에서 `replaceRange`는 버림(근사 금지).
- **골든 405가 조용히 깨지는 두 함정**:
  (1) IMK의 `PhysicalKeystroke`는 `NSEvent.keyCode`에서 — **characters 금지** (전 케이스가 키코드 키잉, characters는 QWERTY 통과 후 비-QWERTY에서 발산). 변환 함수 1개 + 전송 간 동일성 단위 테스트.
  (2) IMK 조합기는 **`HangulCompositionTracker` 자신** — `decision.original`이 그 트래커 재생으로 *정의*됨(`HangulStructure.swift:74,95-101`). 두 번째 조합기는 교체 range를 조용히 깨뜨림(A-5).
- `InputSourceKind` 단일 출처: `currentInputSourceKind()` 함수 하나 — 탭은 TIS, IMK는 내부 한/영 불리언. 갈라지면 **모든 교정이 반대로 뒤집힘**.
- **입력 소스 정체성 수정**: `AppMonitor.swift:44`가 Apple 두벌식을 하드코딩 → 사용자가 Mackor를 선택하는 순간 `inputSourceKind=.unsupported`로 **탭이 죽음**. Mackor 자신의 소스 ID 인식을 IMK 골격과 **같은 단계**에 넣는다(5-6).

### 2-6. 권한 저하 — 침묵이 버그다

- **탭 지연 생성**: 실행 시가 아니라 **첫 rung 3 클라이언트 진입 시** 생성·요청(`MackorApp.swift:144-153` 변경). CorelDRAW를 안 쓰면 프롬프트 0회 — R6의 실질 해결.
- rung 3 + 탭 불가 시: 앱 이름 명시 1회성 알림 + 설정 딥링크 + 메뉴바 경고 글리프. 전역 `hasAccessibility` 불리언(`MackorApp.swift:155-180`)을 앱별 상태 문구로 교체.
- R6 서술: "권한 불필요"는 rung 1/2 한정. ad-hoc 해시 가설은 A/B 실측(각 2회) 전 주장 금지.
  `~/Library/Input Methods/` 이동은 안정 서명이어도 TCC 1회 리셋 가능성 — 예산에 넣고 공지, A/B와 분리 측정(A-8).

---

## 3. 단계별 계획 (각 단계 = 독립 머지 가능 + 검증 게이트)

### Phase 0 — 프로브 측정 완결 【일부 완료】
- ✅ 프로브 계측 버그 수정(마커 비교 + raw 로깅) — 커밋 `0d95c04`
- 남은 것: 현행 Mackor와 프로브를 함께 돌려 탭 주입 발생 → TextEdit·CorelDRAW에서
  `rawUserData=1215525702` 관측 여부 = **A-1 판정** (마커 방어선 확정/포기)
- flap 계측(activate/deactivate 간격 히스토그램) 삽입 — TTL은 데이터 후 결정
- 게이트: 측정 로그가 존재하기 전에 A-1·A-3을 확정 서술 금지

### Phase A — 회귀 수정 (즉시 출하 가능, IMK 없음) 【일부 완료】
- ✅ `resetTransientState()`에 `clearSuppressedKeyUps()` — 커밋 `0d95c04`
- `AppMonitor.swift:275` scope 항 삭제 (이중 처리 **실재하지 않음** — 판정 §6:
  자모 키는 record(부기)+조합 1회 출력, 경계는 keyUp에서 교정, `commitCompositionIfNeeded`는
  `.pass()`로 무출력, 백스페이스 산술은 트래커 재생 항등으로 구조적 일치,
  `.selectedApps`에서는 비트 단위 무변화, 공존 상태는 이미 출하 중)
- `:286-288` 주석을 사실로 교체("임시 조합"은 `HangulStructure.evaluate`의 메모리 재생 — 화면 무접촉)
- `AppMonitorTests.swift` 신설(현재 **부재**) + 공존 상태 탭 테스트 3종
  (두 scope 모두 `isActive==true` / 자모 1키 = executeResult 1회·엔진 출력 0회 / 주입 이벤트 무기록·무조합)
- 공시: `.allApps`에서 등록 앱 전부가 직접 조합을 받음(앱별 토글은 off 스위치로 유지)
- **정직성**: 이 단계는 CorelDRAW 복구이지 R1 충족이 아님(조합은 여전히 등록 요구). R1은 Phase D/E.
- 게이트: 161 + 44 + 405 **무수정** 통과, CorelDRAW에서 `dkssud`→`안녕` 실기 확인
- 번들 금지(별도 PR): `:435` 롤오버 경합(방향: 무효화가 아니라 **즉시 적용**),
  후행 마침표 백스페이스 발산(`gks.`→BS 시나리오, `invalidateAutomaticCorrectionTokenUntilBoundary` 호출로 수정)

### Phase B — `MackorSession` + `EditPlan` 추출, 탭을 `TapRenderer`로 (~1주)
- 엔진 파일 무변경(동결 31파일 SHA 유지). 이동할 호출 지점: `record :602`,
  `processBoundary :764,:895`, `processBackspace :518`, `processJamo :633` 등 (인자·순서 불변)
- 게이트: 44+405 무수정 통과 + `pre-imk` 대비 골든 verdict diff **정확히 0**. no-op 릴리스 출하 가능.

### Phase C — `TransportArbiter` + IMK 골격 (항상 false) (~1주)
- Squirrel/Gureum 실물 구조 Info.plist, 단일 입력 모드(D1 대체안 — 모드 enable 온보딩 리스크 제거),
  `InputMethodServerControllerClass` 필수
- `handle()` 전면 방어 래핑(passthrough 불변식, 강제 언랩 금지 — A-4: imklaunchagent 크래시 스로틀링)
- 컨트롤러는 분류·로깅만, 조합 0. 세 게이트(2-2) 삽입, arbiter `.tap` 고정
- **`AppMonitor.swift:44`/`:237-248` 입력 소스 정체성 수정 동반** (안 하면 Mackor 선택 즉시 탭 사망)
- 게이트: 동작 변경 0. 실제 앱들의 rung 분포·flap 분포 로그 확보 — 키 손상 능력 0인 상태로 실측.

### Phase D — rung 1/2에서 IMK 조합 활성화 (1~2주)
- 트래커 기반 marked text(조합기 = `HangulCompositionTracker` 재사용, A-5), 승격 전 게이트, 세션 중간 강등 금지
- 게이트: REQUIREMENTS §R2 매트릭스(`안녕하세요 반갑습니다`, 느림/빠름 × 트리거 5종 × 10회 무손실)
  — TextEdit·카톡·Safari·Chrome·VS Code. **전송 간 텍스트 패리티 테스트**(같은 키스트로크 → TapRenderer/IMKRenderer 가짜 싱크 → 텍스트 상태 동일, 골든 전체) 통과.

### Phase E — IMK R3 (~1주)
- mozc 패턴 소급 교정(R3-a 양방향), 칩(`CorrectionNoticeController` 무변경, 앵커만 IMK 캐럿 rect), R3-b
- 내부 한/영 불리언 + CapsLock 전환(`TICapsLockLanguageSwitchCapable` — 실측 확인, 권한 불필요), R3-c
- undo 1차 경로 = 칩 클릭(⌘Z는 앱 의존 실측 — 보너스)
- 게이트: R3 시나리오 매트릭스(`dkwn`→`아주`, `ㅗ디ㅣㅐ`→`hello`) + 칩 위치 육안 + 복원 시 방향 역전환

### Phase F — 패키징·서명·권한 (~1주)
- Developer ID 서명·공증·스테이플, `~/Library/Input Methods/` 설치(`--register` 셀프 등록 — P0-8 실측 확인)
- 탭 지연 생성 + 앱별 상태 UI, defaults 도메인 이전(`com.mackor.app` → 신규)
- R6 A/B 실측(ad-hoc×2 vs Dev ID×2) **후에** R6 주장 작성. 경로 이동 재승인은 분리 측정.
- D2: 버전을 3곳(`build-installer.sh:10-11`·`install.sh:10-11`·pbxproj)에 PR 전 고정
- 릴리스는 REQUIREMENTS §2 순서(공증 → DMG만 Release → appcast 마지막)

의존성: 0·A는 독립, B→C→D→E→F는 엄격 순서. 매 단계 제품이 동작하는 상태로 머지.

---

## 4. 리스크 (요약 — 상세 근거는 종합 문서)

| # | 리스크 | 완화 |
|---|---|---|
| A-1 | 필드 42 마커가 NSEvent 왕복에서 소실 | Phase 0 측정. arbiter가 1차 방어라 실패해도 아키텍처 생존. 카운터 백스톱 |
| A-2 | arbiter vs 포커스 변경 첫 키 경합 | `.none`=양쪽 passthrough — 최악은 미교정, 이중 교정 불가 |
| A-3 | marked text는 받고 키 소비는 무시하는 앱 | 승격 전 왕복 게이트 + 세션 중간 강등 금지. 확정 텍스트 무접촉이라 손상 0 |
| A-4 | **IME 크래시 = 머신 전체 타이핑 차단** | handle 방어 래핑, rung≠3에서 AX 금지, 탭 지연 생성, README 탈출로, 크래시 워치독 검토 |
| A-5 | **두 조합기 발산 → 교체 range 조용히 파손** | 트래커 재사용(항등), 골든 전체 전송 간 패리티 테스트 |
| A-6 | PhysicalKeystroke를 characters에서 파생 | 키코드 변환 함수 1개 + 동일성 테스트 |
| A-7 | 프로브가 MS Office 크래시 | rung 0 정적 목록을 **모든 프로브보다 먼저** |
| A-8 | Input Methods 경로 이동 → TCC 리셋 | 재승인 1회 예산·공지, A/B와 분리 |
| A-9 | Sparkle 실행 중 IME 교체 | Squirrel 방식 조사 + 실기 검증 (Phase F) |
| A-10 | rung 캐시 stale | 버전 키잉, 매 activate 재프로브, 강등 우선 |
| A-11 | flap 완화 오튜닝이 "먹힘" 원인화 | 멱등 핸들러, **로깅 먼저 튜닝 나중** |
| A-12 | `:435` 롤오버 경합 잔존 | 별도 PR(즉시 적용 방향), Phase A와 비번들 |

최우선 감시: A-4(폭발 반경 머신 전체), A-5(조용한 실패).

## 5. 검증 (전 단계 공통)

- 매 Phase: `xcodebuild test` 전체 + 규칙 44 + 골든 405 **무수정** 통과
- 동결 가드: 31파일 SHA + `pre-imk` 태그 직접 diff (CI 이중 검사, 이미 가동)
- 회귀 기준: `pre-imk` 대비 골든 verdict diff = 0
- Phase D부터: 전송 간 텍스트 패리티(골든 전체) + REQUIREMENTS §R2 실기 매트릭스
- 실기 확인이 필요한 게이트(CorelDRAW `dkssud`→`안녕`, R3 매트릭스)는 사용자 협조로 진행

## 6. 문서 동기화 (구현 시작 시 함께)

- `MIGRATION_PLAN.md`를 이 하이브리드 계획으로 전면 개정 (현재 IMK-단독 전제로 낡음)
- `REQUIREMENTS.md` 진행 상태 갱신 (P0 완료 항목, Phase A 판정 §6 요지 기록)
- 종합 설계 전문은 `docs/HYBRID_DESIGN.md`로 저장소에 보존 (커밋별 리뷰 가능하게)

## 7. 공수

Phase 0 잔여 반나절 · A 1~2일 · B 1주 · C 1주 · D 1~2주 · E 1주 · F 1주
= **집중 기준 5~7주** (실기 검증 게이트 포함). 사용자에게 가장 빠른 가시 성과는
Phase A(CorelDRAW + 자동 교정 동시 사용, 며칠 내)이며 이는 하이브리드의 정식 첫 단계다.
