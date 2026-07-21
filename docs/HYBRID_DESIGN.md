# Mackor 하이브리드 아키텍처 — 설계 종합 (전문)

> 이 문서는 독립 설계 3안을 적대 심판 2회로 채점한 뒤 종합한 원본이다.
> 실행 계획 요약은 [MIGRATION_PLAN.md](../MIGRATION_PLAN.md)에 있고,
> 이 문서는 그 근거·줄 인용·반례를 보존하기 위한 것이다.
>
> - 설계안: IMK-Authoritative Hybrid with Explicit Per-Client Handoff (the "Verdict" protocol) / Tap-authoritative hybrid — IMK as a promoted delegate, never the default / Mackor Hybrid Transport Architecture (IMK primary + CGEvent tap fallback), arbitrated by a single-writer TransportArbiter keyed on the IMK client session
> - 심판 선택: risk-first, risk-first
> - 생성: 2026-07-20

> ## ⚠ 개정 이력 — v2와의 차이 (2026-07-21)
>
> 이 문서는 **생성 시점(2026-07-20)의 근거 archive**이며, 이후 실측으로 뒤집힌 부분이 있다.
> 실행 기준은 항상 [MIGRATION_PLAN.md](../MIGRATION_PLAN.md) v2가 우선한다.
>
> - **A-1(필드 42 마커 생존) — 반증됨.** 이 문서 :629는 A-1과 A-3이 "추론이지 측정이 아니다"라고
>   스스로 경고했다. 이후 7차 측정에서 `rawUserData=0`으로 **마커 소실이 확정**됐다
>   (`MackorIMEProbe/p0-round7-marker-survival.log`). 따라서 이 문서의 마커 기반 필터링 논증은
>   그대로 쓸 수 없고, MIGRATION_PLAN v2의 barrier 방식이 이를 대체한다.
> - **CorelDRAW의 IMK 소비 무시** — 이 문서 :29의 판정은 v2에서 한 번 "강한 가설"로 강등됐다가
>   G0 재측정으로 다시 확정됐다.
> - 전체 계획의 현재 상태(일시 중단)는 MIGRATION_PLAN 상단 배너를 참고한다.

---

# Mackor 하이브리드 아키텍처 최종 설계 (IMK 주 경로 + CGEvent tap 폴백)

기준: `risk-first` 설계를 뼈대로 하고, 판정 1·2가 지목한 4개 이식(graft)을 반영했다. 이 문서의 모든 줄 번호는 현 워킹트리에서 직접 확인했다.

---

## 0. 착수 전 필수 측정 (Phase 0, 1시간)

설계 전체가 두 개의 미측정 전제 위에 서 있는데, 그 전제를 확인해야 할 도구 자체가 고장 나 있다.

`MackorIMEProbe/ProbeInputController.swift:102`:

```swift
let synthetic = event.cgEvent?.getIntegerValueField(.eventSourceUserData) != nil
```

이것은 옵셔널 체인의 nil 검사다. `cgEvent`가 존재하면 항상 `true`. 따라서 `p0-round4-coreldraw.log`의 모든 `synth?=true`는 물리/합성 판별자로서 **무의미하다**. "합성 이벤트가 handle()에 도달한다"는 오케스트레이터의 전제는 현재 근거가 없다.

수정:

```swift
let raw = event.cgEvent?.getIntegerValueField(CGEventField(rawValue: 42)!)
let synthetic = (raw == 0x48474C46)
ProbeLog.line("... rawUserData=\(raw.map(String.init) ?? "nil") synth?=\(synthetic) ...")
```

`raw` 값을 그대로 찍는 것이 핵심이다. 이 한 줄이 두 가지를 동시에 판정한다:
- 합성 이벤트가 `handle()`에 도달하는가
- 필드 42가 CGEvent → WindowServer → TSM → NSEvent 왕복에서 살아남는가 (A-1)

재현 절차: 프로브를 선택 입력 소스로 두고, 현재 배포판 Mackor를 함께 실행해 tap이 백스페이스/유니코드를 주입하도록 만든 뒤 TextEdit와 CorelDRAW에서 각각 로그 수집.

**이 측정 결과가 나오기 전에는 2절의 마커 기반 필터를 1차 방어선으로 삼지 않는다.** 아래 설계는 그 실패를 견디도록 되어 있다.

---

## 1. 구조와 중재 규칙

### 1-1. 왜 순서가 아니라 상태로 강제하는가

tap은 `.cgSessionEventTap` / `.headInsertEventTap`로 생성된다 (`EventTapManager.swift:346-352`). 이는 입력기(TSM)보다 **상류**다. 즉 tap이 물리 키를 먼저 보고, tap이 nil을 반환하면 `handle()`은 그 키를 아예 못 본다. 그러므로 "IMK가 이 키를 먹을 것"이라는 사실을 tap이 사후에 알 방법은 없다. 소유권은 **키 도착 이전에 이미 결정되어 있어야 한다.** 이것이 키 단위 중재가 불가능하고 세션 단위여야 하는 구체적 이유다.

### 1-2. 상태

```swift
@MainActor
final class TransportArbiter {
    enum Owner: Equatable {
        case tap                              // 오늘의 동작 그대로
        case imk(clientSessionID: UUID)
        case none                             // 양쪽 모두 passthrough (전이 중)
    }
    private(set) var owner: Owner = .tap      // 단일 writer: MackorInputController
    var tapOwnsCurrentSession: Bool { owner == .tap }
}
```

- **단일 writer**: `MackorInputController`(IMK 계층)만 쓴다. tap은 읽기만.
- **락 없음**: tap 런루프 소스는 `CFRunLoopGetMain()`에 등록되고(`EventTapManager.swift:361`), IMK 컨트롤러 콜백도 메인 스레드다. getter/setter 양쪽에 `dispatchPrecondition(condition: .onQueue(.main))`. 락은 쓰지 않는다 — 이벤트 탭 콜백 안의 락은 `tapDisabledByTimeout`을 유발한다.
- **읽기는 평문 프로퍼티 읽기만.** AX를 건드리는 것은 절대 금지. `FocusedInputSafety.swift:41`의 50ms 메시징 타임아웃이 키 경로에 들어오면 탭이 통째로 죽는다.

**판정 1에서 지적된 250ms 타이머는 채택하지 않는다.** 프론트앱 알림과 경합하는 두 번째 시계가 되어 토큰 중간에 발화할 수 있다. 대신 상태를 **파생**시킨다: 활성 IMK 클라이언트 세션이 없으면 그것이 곧 tap 소유 조건이다.

```
owner = {
  Mackor가 선택 입력 소스가 아님        → .tap        (오늘의 제품 그대로)
  활성 클라이언트 세션 없음              → .tap
  활성 세션의 rung ∈ {1, 2}            → .imk(sessionID)
  활성 세션의 rung ∈ {0, 3}            → .tap
  분류 진행 중                          → .none
}
```

### 1-3. 전이 시점 — 키 입력은 절대 전이 시점이 아니다

| 신호 | 동작 |
|---|---|
| `activateServer(client)` | 세션 생성 → rung 분류(3절) → owner 갱신 |
| `deactivateServer(client)` | 해당 클라이언트 세션 종료 → `commitComposition` → owner 재계산 |
| 프론트앱 변경 (`AppMonitor.swift:74-81` 기존 옵저버 재사용) | 세션 무효화 → owner 재계산 |
| TIS 선택 소스 변경 (`AppMonitor.checkInputSource`, `:224-256` 재사용) | Mackor 미선택이면 `.tap` 고정 |

**새 옵저버를 만들지 않는다.** 두 개는 이미 있다.

### 1-4. flap 대응 (imk-first에서 이식, 필수)

`p0-round4-coreldraw.log`에 동일 클라이언트에 대한 activate/deactivate 쌍이 1–3ms 간격으로 나타나고, 연속 중복 `deactivateServer`도 있다. 순진한 "deactivate마다 리셋"은 조합이 이미 취약한 앱군에서 초당 여러 번 음절을 죽인다.

규칙:
- **핸들러는 멱등.** 이미 비활성화된 클라이언트의 두 번째 `deactivateServer`는 no-op이며 두 번째 리셋을 일으키지 않는다.
- **clientID 키의 세션 캐시, TTL 300ms.** TTL 내에 동일 `clientID`로 `activateServer`가 오면 리셋이 아니라 **복원**한다.
- **튜닝 전에 로깅부터.** flap 자체가 사용자가 보고한 "먹힘" 증상의 부분 원인일 가능성이 있다. Phase C에서 실측 분포를 먼저 남기고 TTL을 정한다. 잘못 튜닝하면 이 완화책이 증상의 원인이 된다.

### 1-5. 전이 시 양쪽이 반드시 하는 일

1. `EventTapManager.resetTransientState()` (`:1261`) — tracker 리셋 + 자동교정 상태 리셋
2. 그 안의 `invalidatePendingBoundaryCorrection()` (`:1256-1259`)이 `boundaryCorrectionGeneration`을 증가시킨다. **이것이 이미 존재하는 취소 프리미티브다.** 지연 교정 클로저는 실행 직전 `self.boundaryCorrectionGeneration == generation`을 확인하므로(`:998`), 앱 A에서 예약된 교정이 앱 B에 착륙할 수 없다. 새로 만들 것이 없고 arbiter가 호출만 하면 된다.
3. **`clearSuppressedKeyUps()` 추가 호출** (`:674`) — 아래 1-6 참조
4. IMK 측: 떠나는 클라이언트에 대해 `commitComposition` + 마크드 상태 클리어

### 1-6. 발견된 잠재 버그 — `resetTransientState()`가 suppressedKeyUps를 비우지 않는다

```swift
// EventTapManager.swift:1261
private func resetTransientState() {
    tracker.reset()
    resetAutomaticCorrectionState()
}
```

그런데 `stop()` (`:377-378`)은:

```swift
resetTransientState()
clearSuppressedKeyUps()
```

두 줄을 **짝으로** 부른다. 작성자가 이 둘이 함께 가야 함을 알고 있었다는 뜻이다. 그리고 `MackorApp.swift:264`는 앱 전환마다 `resetComposition()`(→ `resetTransientState()`, `:416-418`)을 **단독으로** 호출한다. 이것은 하이브리드 전용 문제가 아니라 **현재 살아 있는 잠재 버그**다.

구체적 실패: `:638`에서 차단된 자모 keyDown이 `noteSuppressedKeyDown`으로 `suppressedPhysicalKeyUps`에 항목을 남긴다. 앱이 전환되면 그 항목이 그대로 남고, 이후 같은 keycode의 물리 keyUp이 `handleKeyUp:663`의

```swift
return suppressedPhysicalKeyUps.remove(keycode) == nil ? event : nil
```

에서 삼켜진다. 소유권이 IMK로 넘어간 뒤라면 그 키 입력이 사라진다.

조치: `resetTransientState()` 안에 `clearSuppressedKeyUps()`를 넣는다. 이것은 Phase A에 함께 넣는다(6절).

### 1-7. tap 측 게이트 — **세 곳 전부**

tap이 텍스트를 쓰는 진입점은 정확히 셋이며, 각각의 도달 경로를 전수 확인했다:

| 진입점 | 도달 경로 |
|---|---|
| `executeResult` (`:1268`) | `handleKeyDown` (`:538`, `:633`, `:982`) |
| `applyCorrection` (`:1054`) | `handleKeyUp` (`:654`) → `schedulePendingBoundaryCorrection` (`:991`) → generation 확인 클로저 |
| `applySubmitCorrection` (`:820`) | 동일 지연 경로 |

네 번째 경로는 없다. 따라서 게이트도 셋이면 충분하고, **셋 다** 필요하다:

**(a) `handleKeyDown` — 최상단, `:435`의 무조건 `invalidatePendingBoundaryCorrection()`보다 위에**

```swift
func handleKeyDown(_ event: CGEvent) -> CGEvent? {
    let tapOwns = arbiter.tapOwnsCurrentSession    // ← 정확히 한 번, 지역 변수로
    guard tapOwns, isActive || isAutoCorrectionEnabled else { return event }
    ...
}
```

이 값을 **이벤트 처리 중간에 재조회하지 않는다** (imk-first에서 이식). 재진입 `activateServer`가 record 단계(`:602`)와 compose 단계(`:628`) 사이에 소유권을 바꾸면, tap이 키를 엔진에 기록해놓고 조합은 하지 않아 엔진의 화면 모델이 깨진다.

**(b) 게이트는 `:628`(조합)이 아니라 `:566`/`:602`(기록)보다 위여야 한다.** 이것이 놓치기 쉬운 지점이다. IMK가 소유한 클라이언트에서도 물리 키는 tap을 통과한다(tap이 상류이므로). tap이 "주입만 안 하고 기록은 계속" 하면, IMK가 조합 중인 텍스트에 대해 tap의 엔진이 토큰을 쌓고 다음 경계에서 자기 것이 아닌 화면에 교정을 발사한다. **기록하지 않아야 한다. 주입을 안 하는 것만으로는 부족하다.**

**(c) `handleKeyUp` — 현재 아무 가드가 없다**

`handleKeyUp` (`:643`)에는 `isActive || isAutoCorrectionEnabled` 가드가 **존재하지 않는다** (`handleKeyDown:422`와 대조적). 그리고 지연 교정이 무장되는 곳이 바로 여기(`:650-659`)다. 따라서:

```swift
func handleKeyUp(_ event: CGEvent) -> CGEvent? {
    if EventTapManager.isInjected(event) { return event }
    let keycode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
    guard arbiter.tapOwnsCurrentSession else {
        // 소유권이 없어도 우리가 이전에 차단한 keyDown의 짝 keyUp은 정리해야 한다
        suppressedPhysicalRepeatKeyDowns.remove(keycode)
        return suppressedPhysicalKeyUps.remove(keycode) == nil ? event : nil
    }
    ...
}
```

가드 뒤에서도 suppressed 집합 정리는 유지한다. 그렇지 않으면 1-6의 고아 keyUp 문제가 되살아난다.

### 1-8. 단어 중간 앱 전환

TextEdit(IMK 소유)에서 `gksr`까지 입력, 마크드 텍스트 `한ㄱ` 표시 중 ⌘Tab으로 CorelDRAW 이동:

1. `deactivateServer` → IMK가 `한ㄱ`을 **있는 그대로 확정**하고 마크드 클리어
2. tap: `resetTransientState()` + `clearSuppressedKeyUps()`, generation 증가 → 비행 중인 지연 교정 무효화
3. `owner = .none`
4. CorelDRAW에서 `activateServer` → 프로브 실패 → rung 3 → `owner = .tap`, 빈 토큰에서 시작

반쪽 단어는 그 자리에 버려지고, 교정되지 않고, 앱을 넘어가지 않는다. 교정을 잃는 것은 허용, 단어를 망가뜨리는 것은 불허.

### 1-9. 이중 교정 불가능성

`.imk`일 때 tap은 세 게이트 모두에서 조기 반환하므로 기록도 주입도 하지 않는다. `.tap`일 때 IMK의 `handle()`은 무조건 `false`를 반환하고 마크드 텍스트를 설정하지 않는다. `.none`일 때 양쪽 모두 투명. **양쪽이 동시에 활성인 상태는 열거형에 존재하지 않는다.**

---

## 2. 주입 재진입 차단 (양방향)

두 방향은 비대칭이며, 그 비대칭이 답의 전부다.

### 2-1. 방향 A — tap의 합성 이벤트가 `handle()`에 도달 (실재, 반드시 필터)

현재 태깅은 이중이다:
- `CGEventSource.userData = 0x48474C46` (`EventTapManager.swift:57`, `:82`)
- 이벤트별 필드 쓰기 `setIntegerValueField(CGEventField(rawValue: 42)!, 0x48474C46)` — `tagAsInjected` (`:1303-1305`), 호출 지점 `:65, :74, :98, :106`
- tap 자신의 재진입 가드: `isInjected` (`:1307-1309`), 사용처 `:425`, `:645`

**이 메커니즘은 유지하고 확장한다. 기존 계획의 "주입 마커 삭제"는 틀렸다.** rung 3에서 tap은 계속 주입하며, 그것은 영구 경로다.

접근 제한 변경 필요:

```swift
// EventTapManager.swift:143-144, :1307 — private → internal
static let injectionMarker: Int64 = 0x48474C46
static let userDataField = CGEventField(rawValue: 42)!
static func isInjected(_ event: CGEvent) -> Bool { ... }
```

(`tagAsInjected`는 `:1303`에서 이미 internal static이고 테스트에서 쓰이고 있다.)

IMK 측 가드 — `handle(_:client:)`의 **문자 그대로 첫 문장**:

```swift
override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
    if let cg = event?.cgEvent, EventTapManager.isInjected(cg) { return false }
    ...
}
```

어떤 상태 변경보다도 앞. tap이 `:425`에서 하는 것과 정확히 같은 순서.

**그러나 이것을 유일한 방어선으로 삼지 않는다.** 필드 42의 생존은 0절이 측정할 때까지 미확인이다. 따라서:

- **1차 방어선은 arbiter다.** tap은 `owner == .tap`인 클라이언트에서만 주입하고, 그 클라이언트에서 `handle()`은 모든 이벤트에 무조건 `false`를 반환한다. 마커는 stale-arbiter 창에 대한 심층 방어일 뿐이다. 이 순서 지정은 의도적이다 — 측정이 실패해도 "중복성이 약간 줄어드는" 것으로 끝나지 "주입 루프"가 되지 않는다.

- **백스톱 (imk-first에서 이식):** 동일 프로세스이므로 in-process 카운터를 둔다. `QuartzKeyboardOutput`에서 이벤트 post마다 `arbiter.injectionsPending += 1`, `handle()`이 폐기할 때마다 감소, 그리고 **250ms 데드라인**을 두어 드롭된 이벤트가 IMK를 영구히 막지 못하게 한다.
  **카운터 단독은 금지.** 우리 합성 백스페이스와 사용자의 진짜 백스페이스를 구별할 수 없고, 카운터가 끼면 실제 타이핑을 삼킨다. 마커 우선, 카운터는 백스톱.

- **보조 시그널(진단용, 필터 아님):** 유니코드 주입은 더미 가상키 `0x09`에 `keyboardSetUnicodeString` 페이로드를 실어 보낸다(`:88-100`). keycode 0x09인데 문자가 한글 음절이면 주입이다. 진짜 Tab에서 오탐하므로 **필터가 아니라 assert/진단 로그로만** 쓴다.

### 2-2. 방향 B — IMK의 쓰기가 tap에 도달 (이벤트로서는 존재하지 않음. 여기가 함정)

`setMarkedText` / `insertText`는 TSM/Mach IPC로 클라이언트에 직접 간다. `.cgSessionEventTap`을 통과하지 않는다. 태그할 것도 필터할 것도 없다.

이 방향의 **실제** 재진입은 다른 것이다: **IMK가 소유한 동안에도 사용자의 물리 키는 tap을 통과한다.** 그 처리는 1-7(b)의 "기록도 하지 않는다"가 담당한다. 이것이 방향 B의 전부다.

강제 규칙 두 가지:
1. **빌드 수준 금지:** `QuartzKeyboardOutput` 밖에서 `CGEvent(...).post` 금지. 미래에 IMK 측 폴백이 이벤트를 post해야 하면 반드시 그 타입을 경유해 자동으로 태깅되게 한다. 그러면 tap의 기존 `:425`/`:645` 검사가 새 코드 없이 대칭으로 커버한다.
2. rung 1/2에서 tap은 어차피 유휴이므로 태그 없는 post도 그대로 통과된다. 유휴가 바깥 안전망, 태그가 안쪽 안전망.

### 2-3. tap → tap (이미 올바름, 보존 필요)

`handleKeyDown`은 `:425-427`에서 주입 이벤트를 반환하는데, 이는 `:435`의 무조건 `invalidatePendingBoundaryCorrection()`보다 **위**다. 이 순서는 load-bearing이다 — 주입 검사가 `:435` 아래로 내려가면 tap 자신의 교정 백스페이스가 그것을 발생시킨 pending correction을 파괴한다. 우연처럼 보이므로 **주석을 단다.**

### 2-4. 4가지 경우 요약

| 이벤트 | tap이 봄 | IMK가 봄 | 무시 방법 |
|---|---|---|---|
| tap 합성 키, tap 소유 클라이언트 | O | O(추정) | tap: 필드42 (`:425`,`:645`). IMK: arbiter가 tap 소유라고 말함 → false. 마커는 백업, 카운터는 백스톱 |
| 물리 키, IMK 소유 클라이언트 | O | O | tap: arbiter 가드. **기록도 주입도 안 함** (`:566`/`:602` 위) |
| IMK의 setMarkedText/insertText | **X** (CGEvent 아님) | — | 불필요 |
| 물리 키, tap 소유 클라이언트 | O | O | IMK가 false 반환, tap이 처리 (오늘의 동작) |

---

## 3. 앱 분류기 — 첫 단어 보장

### 3-1. 안전 성질이 설계를 결정한다

**미분류 클라이언트는 tap 소유다.** 분류가 성공하기 전까지 IMK는 모든 키에 `false`를 반환한다. "일단 IMK로 해보고 본다"는 없다.

이로써 질문이 뒤집힌다. "모르는 앱에서 첫 단어를 어떻게 안 깨뜨리나"가 아니라 "그러면 앱을 어떻게 승격시키나"가 된다. 답: 승격은 `activateServer`에서, **키를 한 개도 입력하기 전에** 일어난다. 첫 단어 문제 자체가 발생하지 않는다.

### 3-2. 프로브 — 자기보고는 완전히 무시

CorelDRAW는 `supportsProperty(DocumentAccess) = true`를 반환하고 `validAttributesForMarkedText`에 `NSTextInputReplacementRangeAttributeName`을 포함시키면서 실제 질의는 전부 실패한다(`REQUIREMENTS.md:478-487`). **능력 광고는 거짓말이고, 그 거짓말은 세션 시작 시점에 공짜로 탐지된다.** 이것이 이 설계 전체에서 가장 중요한 실측 사실이다.

`activateServer`에서 실제 질의 3개:

| 질의 | TextEdit (rung 1) | CorelDRAW (rung 3) |
|---|---|---|
| `length()` | > 0 / 유효 | **0** |
| `selectedRange()` | `(2,0)` 유효 | **NSNotFound** |
| `attributes(forCharacterIndex:0, lineHeightRectangle:)` | `(214.76, 979.0, 1.0, 13.0)` | **(0,0,0,0)** |

독립적 3중 실패. 키 입력 0회, 위험 0. CorelDRAW는 아무것도 먹기 전에 스스로 rung 3으로 분류된다.

### 3-3. 사다리

- **Rung 0 — 프로브 금지 목록.** MS Word / Excel / PowerPoint (mozc가 `selectedRange`가 **앱을 크래시시킬 수 있어서** 제외), Evernote (`attributedSubstringFromRange`가 "very heavy"). **여기서는 `selectedRange`를 아예 호출하지 않는다.** 프로브 자체가 일으키는 크래시는 어떤 런타임 게이트로도 복구 불가이므로 정적 목록이어야 한다. `replacementRange = .empty`로 마크드 텍스트 조합만: R2 동작, R3 소급 교체 off.
- **Rung 1 — 완전 IMK.** 프로브 3개 통과 + 금지 목록 아님. 마크드 텍스트 조합 + mozc 교체 패턴.
- **Rung 2 — 조합 전용 IMK.** 조합은 되지만 문서 접근 불가. R2만, R3는 미확정 토큰 범위로 제한하거나 생략. Electron/Chromium이 여기 올 것으로 예상.
- **Rung 3 — tap.** 프로브 실패 또는 승격 게이트 실패. IMK는 이 클라이언트에서 모든 것에 false. 손쉬운 사용 권한 필요.

**R1 준수:** 사용자 등록 0. 전부 출하 시드 데이터 + 런타임 프로브. mozc/vChewing 전례와 동일(`MIGRATION_PLAN.md:94-96`).

### 3-4. 프로브가 볼 수 없는 것과 그 처리 (tap-first에서 이식 — risk-first 원안 교체)

프로브는 "키 소비를 무시하는가"를 볼 수 없다. CorelDRAW는 `handle()`이 `true`를 반환했는데도 앱이 `ab∞§£`를 삽입했다.

**risk-first 원안(첫 조합 키에서 writeback 확인 후 즉시 강등)은 채택하지 않는다.** 이유가 구체적이다: 강등 시점에 유출된 라틴 문자가 이미 화면에 있는데 tap의 엔진은 stroke 2부터 시작한다. 그러면 `decision.originalCharacterCount`가 1 부족하고, `applyCorrection` (`:1059-1062`)이 n−1개만 백스페이스해서 유출 문자가 교정 단어에 접착된다. 원안의 "라틴 문자 1개" 상한은 유출만 설명하고 이 산술 어긋남을 설명하지 못한다. (현재는 `FocusedInputSafety.isCurrentFocus`의 캐럿 오프셋 비교가 fail-closed로 막아주지만, 이는 사고에 가깝지 설계가 아니다.)

**대신: `activateServer`에서의 승격 전 게이트.**

```
activateServer(client):
    if rung0denylist.contains(bundleID) → rung 0, 종료 (프로브 안 함)
    프로브 3종 실행
    실패 → rung 3, 종료
    통과 → 캐시 힌트 확인
        캐시에 clean 세션 ≥ 3 → rung 1/2 승격
        아니면 → rung 3 (tap 소유) + 백그라운드 조합 왕복 검증:
            setMarkedText("ㅎ", replacementRange: .notFound)
            markedRange()가 NSNotFound가 아니고 length가 움직였는가?
            → 즉시 setMarkedText("", ...) 로 클리어
            결과를 캐시에 기록. 승격은 **다음 activateServer부터** 적용.
```

핵심 규칙 두 개:
- **세션 중간 강등 금지.** 하나의 토큰이 두 전송 계층으로 쪼개지는 것이 중재 설계가 존재하는 이유 그 자체다.
- **승격은 다음 세션부터.** 토큰 중간에 절대 전환되지 않는다.

왕복 검증 중에도 소유자는 tap이므로, 검증이 실패해도 사용자 텍스트에 남는 것은 없다(마크드 텍스트는 확정 텍스트가 아니고 즉시 클리어된다). 소비 무시 앱에서 잔류 자모가 남을 이론적 가능성은 rung 0 금지 목록과 "확정 텍스트는 절대 건드리지 않음"으로 봉쇄한다.

**부작용 비용:** 처음 보는 앱은 첫 세션에서 tap 경로로 동작한다. tap이 못 쓰는 상황(권한 없음)이면 그 세션은 교정 없음 — 침묵. 침묵은 허용, 손상은 불허.

### 3-5. 캐시 — 의도적 비대칭

`bundleID + CFBundleVersion → rung`을 Mackor 자체 defaults에 **힌트로** 저장. 스키마 버전 + macOS 빌드 스탬프 포함, 둘 중 하나라도 바뀌면 무효화.

- **`activateServer`마다 프로브 재실행** (IPC 3회, 포커스 변경당 1회 — 무시할 비용).
- **강등은 즉시·권위적. 승격은 연속 3회 clean 세션 필요.**
- 캐시된 rung 1이 실시간 프로브 실패를 절대 덮어쓸 수 없다.
- 버전 키잉이 중요한 이유: 앱 업데이트가 텍스트 입력 동작을 바꿀 수 있고, 그때 stale rung 1은 적극적으로 해롭다.

사용자는 이 캐시를 보지도 편집하지도 않는다. 지워도 재프로브 1회 비용뿐. 지원용 숨겨진 override(defaults 키)는 두되 제품 기능이 아니다.

### 3-6. TargetAppManager의 역할 변경

현재 `AppMonitor.swift:154`, `:195-198`이 `isTargetApp`으로 **게이팅**한다. 이것이 R1이 금지하는 앱 목록 아키텍처다. 하이브리드에서 `TargetAppManager` 등록은 **override 전용**(사용자가 특정 앱을 특정 rung으로 강제)이 되고 **1차 라우터에서 물러난다.**

---

## 4. 권한이 없을 때

### 4-1. 권한 지도

| rung | 필요 권한 | 대상 |
|---|---|---|
| 1, 2 | **없음** | TextEdit, KakaoTalk, VS Code, Safari, Chrome, 터미널류 |
| 0 | 없음 | MS Office, Evernote (조합만) |
| 3 | 손쉬운 사용 | CorelDRAW류 |

IMK는 TCC 권한이 필요 없다(Gureum은 `AXIsProcessTrusted`를 0회 호출).

### 4-2. 절대 조용히 저하되지 않는다

이것이 현재 회귀의 실패 유형 그 자체다. `AppMonitor.swift:276`이 CorelDRAW의 R2를 아무 신호 없이 껐고, 사용자는 "기능이 그냥 안 됨"으로 발견했다. **침묵이 버그다.**

arbiter는 클라이언트의 rung과 tap 가용 여부를 모두 안다. rung 3 + tap 불가로 해석되면:
- 앱 이름을 명시한 **1회성** 알림: "CorelDRAW에서는 손쉬운 사용 권한이 필요합니다" + 손쉬운 사용 설정 패널 직접 링크
- rung 3 클라이언트가 전면에 있고 tap이 죽어 있는 동안 메뉴바 아이콘이 경고 글리프
- 같은 bundleID에 대해 세션 내 반복 금지

`MackorApp.swift:155-180`의 전역 `hasAccessibility` 불리언은 두 기능을 하나로 접어버려서, TextEdit만 쓰는 사용자에게 "Mackor가 고장났다"고 말하게 된다. **앱별 상태 문구로 교체**: "IMK가 처리 중" / "CorelDRAW에는 손쉬운 사용 권한이 필요합니다" / "Mackor가 입력 소스로 선택되어 있지 않습니다".

### 4-3. 지연 요청 — 이것이 R6 마찰을 실제로 없애는 부분

현재 `MackorApp.swift:144-153`의 `setup()`이 실행 시점에 무조건 tap을 시작하므로, rung 3 앱을 하나도 안 쓰는 사용자까지 첫 실행에서 권한 프롬프트를 만난다.

**변경: 실행 시 tap을 만들지 않는다. 첫 rung 3 클라이언트 진입 시에만 생성하고 그때 요청한다.** CorelDRAW를 열지 않는 사용자는 손쉬운 사용 프롬프트를 **한 번도 보지 않는다.** 부수 효과로 R-2(탭/AX 경로 크래시가 IME를 죽임)의 폭발 반경도 줄어든다 — 탭이 아직 존재하지 않으니까.

### 4-4. 런타임 권한 회수

무효화 감지는 이미 있다: `isEventTapHealthy`가 `CFMachPortIsValid` 확인(`:322-325`), 앱 활성화 시 `start()` 재시도(`MackorApp.swift:270-272`). 확장: rung 3 클라이언트가 전면인데 재시작 실패 → 4-2의 경고 상태. `tapDisabledByTimeout` / `tapDisabledByUserInput`(`:1334-1342`)도 현재 조용히 재활성화하는데, 복구로는 맞지만 **arbiter generation도 함께 증가**시켜 공백 이후 비행 중이던 것이 착륙하지 못하게 한다.

### 4-5. R6 — 정직하게

- "IMK 전환 후 권한 불필요"는 **rung 1/2 한정**이다. README에 그대로 쓰고 과장하지 않는다.
- ad-hoc 서명 가설(재빌드 → 새 코드 해시 → TCC가 새 앱으로 인식)은 `REQUIREMENTS.md:309-312`에 **명시적으로 미검증**으로 기록되어 있다. 격상할 근거가 없다. **A/B를 돌리기 전에 주장하지 않는다**: ad-hoc 빌드 설치 → 승인 → 재빌드 → 재설치 → 프롬프트 관찰; Developer ID로 반복. 데이터 2점, 반나절.
- 가설과 무관하게 참인 것 둘: (1) 프롬프트를 rung 3 진입 조건부로 만들면 대부분의 사용자에게서 사라진다. (2) Developer ID 인증서(`SEONGHUN KIM (TZQ9JL6R7R)`, `REQUIREMENTS.md:291`)는 존재하고 서명에 성공하며, 안정적 designated requirement는 재빌드 간 identity churn의 **올바른** 해결책이다.
- **하이브리드 고유 함정:** IME는 `~/Library/Input Methods/`에 산다. `/Applications`와 다른 경로이고, TCC는 경로·서명 민감이므로 이 이동 자체가 안정적 서명이어도 승인을 1회 리셋할 가능성이 크다. **불가피한 재승인 1회를 예산에 넣고 릴리스 노트에 명시한다.** 그리고 이것을 R6 A/B 실험에 섞지 않는다 — 결과가 오염된다.

---

## 5. 공유 코어 — 엔진은 전송 계층을 모른다

### 5-1. 이미 만족되어 있다. 할 일은 깨뜨리지 않는 것

- `WrongLayoutCorrectionEngine.record(_:inputSource:)` (`:132`) ← `PhysicalKeystroke(keycode:shift:)` + `InputSourceKind`
- `processBoundary(_:)` (`:197`) → `CorrectionDecision`
- `LayoutCorrectionPolicy.evaluate` (`:55`) ← 동일 2개

이 타입들 중 어느 것도 전송 계층을 명명할 수 없다. client도, NSEvent도, AXUIElement도, range도 없다. **엔진에서 숨겨야 할 것이 없다. 전송 계층이 도달할 채널 자체가 없기 때문이다.** 엔진 파일은 한 줄도 바뀌지 않는다.

### 5-2. 결정과 실행을 분리

현재 `EventTapManager`는 한 호출 안에서 결정하고 실행한다: `applyCorrection` (`:1054-1095`)이 계산하고 즉시 백스페이스+유니코드를 발사한다. 값을 반환하는 전송 중립 세션을 도입한다:

```swift
// import CoreGraphics 없음, import AppKit 없음, import InputMethodKit 없음
enum EditOp {
    case deleteCharacters(Int)
    case insert(String)
    case replaceRange(TokenRange, with: String)   // IMK 네이티브; tap은 delete+insert로 낮춤
    case switchDirection(CorrectionDirection)
}
struct EditPlan { let ops: [EditOp]; let undo: UndoRecord }

final class MackorSession {
    func keystroke(_ k: PhysicalKeystroke, source: InputSourceKind) -> EditPlan
    func boundary(_ b: CorrectionBoundary) -> EditPlan
    func backspace() -> EditPlan
}
```

`MackorSession`이 `HangulCompositionTracker` + `WrongLayoutCorrectionEngine` + `tokenCaptureState`(`:186-191`) + 후행 마침표 상태 기계(`:920-957`) + 경계/제출 분류(`:681-737`)를 소유한다.

렌더러 2개:
- **TapRenderer** — 기존 `executeResult`(`:1268-1284`) / `applyCorrection`(`:1054`) 로직을 **그대로 이동**(재작성 아님). `replaceRange`는 `deleteCharacters(n) + insert(s)`로 낮춘다.
- **IMKRenderer** — `setMarkedText(text, replacementRange:)` **다음에** `insertText(text, 동일 range)`. 순서는 선택 사항이 아니다. 대조군에서 `insertText` 단독은 무시됨이 확인되었다. rung 2에서는 `replaceRange`를 그냥 버린다(근사하지 않는다).

이동할 호출 지점(인자와 순서 불변): `autoCorrectionEngine.record` (`:602`), `processBoundary` (`:764`, `:895`), `processBackspace` (`:518`), `invalidateCurrentTokenUntilBoundary` (`:1240`), `reset` (`:1234`), `tracker.processJamo` (`:633`), `tracker.processBackspace` (`:538`), `tracker.processNonJamo` (`:982`).

### 5-3. 위반하면 405 골든이 조용히 깨지는 두 가지 제약

**(1) IMK는 `PhysicalKeystroke`를 `NSEvent.keyCode` + `modifierFlags`에서 만들어야 한다. `characters`에서 만들면 안 된다.**
모든 골든 케이스가 가상 키코드 기반이다(`LayoutCorrectionPolicy.qwertyLetters` `:186-192`, `KeycodeToJamoMap`). characters 기반은 QWERTY 테스트를 전부 통과하고 비-QWERTY 물리 배열에서 갈라진다. 변환은 IMK 계층의 **함수 하나**에 두고, 같은 키가 양쪽 전송에서 동일한 `PhysicalKeystroke`를 만든다는 단위 테스트를 붙인다.

**(2) IMK의 조합기는 `HangulCompositionTracker` **자신**이어야 한다. 새 상태 기계 금지.**
비자명한 지점이다. `LayoutCorrectionPolicy.evaluate` → `HangulStructure.evaluate`가 `HangulCompositionTracker`를 직접 인스턴스화해 키스트로크를 재생하여 `decision.original`을 만든다(`HangulStructure.swift:74`, `:95-101`). 즉 `decision.original`은 "그 트래커가 이 키스트로크들로부터 만들어내는 것"으로 **정의**되어 있다. IMK 경로가 다른 것으로 조합하면 — 설령 더 정확하더라도 — `decision.originalCharacterCount`가 화면 텍스트와 어긋나고 mozc 교체 range가 정확히 그 차이만큼 틀어진다. 트래커를 재사용하면 일치가 **합의가 아니라 구조적 항등**이 된다. 트래커의 `CompositionResult{deleteCount, insertText}`(`HangulCompositionTracker.swift:5-20`)를 마크드 텍스트 갱신으로 번역하면 산술은 이미 맞는다(둘 다 자모 단위).

부수 효과로 얻는 것: 현재 `.allApps` tap 경로에서는 **Apple IME**가 텍스트를 조합하므로 엔진의 화면 모델이 근사치다. 이 불일치가 관찰된 "같은 입력란 안에서도 간헐적" 실패와 `좀ㅅ` 잔류의 유력한 원인이다. rung 1/2에서는 Mackor가 조합을 소유하므로 모델이 정확해지고 그 실패 부류가 통째로 사라진다.

### 5-4. R4-1을 실제로 증명하는 테스트

기존 44 rule + 405 golden은 엔진을 직접 호출하며 **손대지 않는다.** 추가로:

- **전송 계층 간 텍스트 패리티 테스트:** 동일 키스트로크 시퀀스를 `TapRenderer`와 `IMKRenderer`에 가짜 싱크로 흘리고, 결과 **텍스트 상태**가 동일함을 단언. ops가 아니라 텍스트다 — ops는 정당하게 다르다(delete+insert vs ranged replace). 골든 코퍼스 전체에 대해 실행. 기존 테스트는 전송 계층을 넘지 않으므로 이 발산을 볼 수 없다.
- **동결 가드:** `MIGRATION_PLAN.md` Phase 1의 SHA-256 매니페스트를, in-PR 매니페스트가 아니라 **`a1c5828`과 직접 diff**한다(매니페스트와 엔진을 같은 PR에서 바꾸는 구멍 차단). 추가로 `MackorSession`이 실제로 동결된 심볼에 도달함을 확인하는 통합 테스트 1개 — 아무도 호출하지 않는 코드를 동결한 매니페스트는 보증이 아니다.

### 5-5. `InputSourceKind`의 단일 출처

두 전송이 진짜로 다른 유일한 지점이며, 함수 하나에 격리한다.

- tap 경로: 시스템 TIS (`AppMonitor.checkInputSource`, `:224-256`)
- IMK 경로: Mackor **자신**이 입력 소스이므로 kind는 Mackor 내부 한/영 불리언(D1 단일 모드)에서 와야 한다

둘 다 `func currentInputSourceKind() -> InputSourceKind` 하나를 통과해야 한다. `LayoutCorrectionPolicy`가 이것으로 방향을 분기하므로(`LayoutCorrectionPolicy.swift:64-72`, `WrongLayoutCorrectionEngine.swift:274-285`), 여기서 갈라지면 **모든 교정이 조용히 반대로 뒤집힌다.**

### 5-6. 같은 단계에 반드시 들어가야 하는 입력 소스 정체성 수정

`AppMonitor.swift:44`가 `com.apple.inputmethod.Korean.2SetKorean`을 하드코딩하고, `:246`이 나머지 전부를 `.unsupported`로 매핑한다. 사용자가 Mackor를 입력 소스로 선택하는 순간:

- `shouldDirectlyComposeCurrentInput` (`:987-989`, `.koreanTwoSet` 요구) → false
- R3 게이트 (`AppMonitor.swift:299`, `!= .unsupported` 요구) → false

**하이브리드가 CorelDRAW를 위해 tap을 필요로 하는 바로 그 순간에 tap이 조용히 죽는다.** `checkInputSource`가 Mackor 자신의 소스 ID를 인식하고 IME 내부 한/영 불리언을 `InputSourceKind`로 매핑해야 한다. 이것은 IMK 번들을 도입하는 **바로 그 단계**에 들어간다. 나중이 아니다.

---

## 6. `AppMonitor.swift:276` 판정 — 이중 처리는 실재하는가

## **판정: 실재하지 않는다. 결합 제거는 안전하며, 하이브리드보다 먼저 출하할 수 있다.**

세 설계 모두 같은 결론이고, 소스에서 직접 확인했다.

### 6-1. 276행이 실제로 하는 일

```swift
// AppMonitor.swift:275-280
let compositionEnabled = targetAppManager?.autoCorrectionScope == .selectedApps
    && (targetAppManager?.isHangulCompositionEnabled(
        bundleID: frontAppBundleID, appName: frontAppName) ?? false)
```

`.allApps`에서는 `compositionEnabled`가 무조건 false → `isActive`(`:289-292`) false → `shouldDirectlyComposeCurrentInput`(`:987-989`, `isActive && inputSourceKind == .koreanTwoSet`) false → **R2 전면 off**, 앱 등록 여부와 무관하게. 이것이 CorelDRAW 회귀 그 자체다.

비대칭에 주목: `isAutoCorrectionEnabled`는 `.allApps`에서 무조건 true를 반환한다(`TargetAppManager.swift:177-179`). scope 항은 오직 **빼기만** 했다.

### 6-2. 공존 상태는 이미 출하 중이다

`TargetAppManager.setAutoCorrectionEnabled`가 자동 교정을 켤 때마다 `updatedApp.hangulCompositionEnabled = true`를 강제한다(`:127-139`). 따라서 `.selectedApps`에서 자동 교정이 켜진 앱은 **이미** `isActive`와 `isAutoCorrectionEnabled`를 동시에 갖는다. scope 항 제거는 새 상태 조합을 만드는 것이 아니라, 이미 실행 중인 조합을 `.allApps`에서도 도달 가능하게 할 뿐이다. `.selectedApps`에서는 식이 `true && …`가 되므로 **비트 단위로 무변화.**

### 6-3. 한 키 입력은 출력을 정확히 한 번 낸다

자모 keyDown:
1. `:602` `autoCorrectionEngine.record` — 순수 부기, 출력 없음, 이벤트 소비 없음
2. `:628` `shouldDirectlyComposeCurrentInput` true → `:633` `tracker.processJamo` → `executeResult` → `:638` `return nil`

경계 키:
1. `processImmediateBoundary`(`:871`)는 **예약만** 한다 — `pendingCorrectionState = .awaitingTriggerKeyUp`, 출력 없음
2. 모든 경계 경로가 `commitCompositionIfNeeded()`를 부르는데(`:459, :481, :489, :503, :548, :559`), 이는 아무것도 방출하지 않는다: `tracker.processNonJamo()`가 `.pass()`(deleteCount 0, insertText "")를 반환하고(`HangulCompositionTracker.swift:75-78`), `executeResult`의 가드(`:1269`)가 정확히 그것에서 조기 반환한다. 순수 리셋이다.
3. 교정은 나중에, 트리거 **keyUp**에서 발사된다(`:650-659` → `:991` → generation 확인 클로저)

**조합이 교정보다 엄격히 먼저 완료된다. 이것이 정확히 D3다.** 양쪽이 동시에 화면 쓰기를 대기하는 창은 없다.

### 6-4. 백스페이스 산술은 우연이 아니라 구조적으로 일치한다

직접 조합이 켜지면 Mackor가 물리 자모 키를 차단하고(`:638`) 조합 음절을 직접 쓴다. 교정기의 `decision.original`은 `HangulStructure.evaluate`에서 오는데, 이것은 **같은** `HangulCompositionTracker`를 **같은** 키코드로 재생한다(`HangulStructure.swift:74`, `:95-101`). 그러므로 `applyCorrection`(`:1059-1062`)이 발사하는 `originalCharacterCount`개의 백스페이스는 화면에 있는 것과 정확히 일치한다.

**이것이 load-bearing 사실이다.** 만약 정책이 자체 조합기를 들고 있었다면 결합 제거는 안전하지 않았을 것이고 이 판정은 뒤집힌다.

### 6-5. 게이트가 중첩이므로 실패 방향은 과소 교정뿐

교정기는 AX 게이트 통과 시에만 기록하고(`automaticCorrectionFieldAllowed == true`, `:586`), 토큰과 포커스 토큰이 살아 있을 때만 결정을 내고(`:891-894`), 손대기 전 포커스를 재검증한다(`:1031-1040`). 직접 조합(`:987`)은 AX 게이트를 보지 않는다. 그러므로 CorelDRAW 캔버스처럼 AX가 실패하는 곳에서는 교정기가 아무것도 기록하지 않고 R2 직접 조합만 돈다 — **그것이 사용자가 기억하는, 예전에 동작하던 동작이다.**

### 6-6. 286-288행 주석은 코드를 설명하지 않는다

주석은 "전체 Mac 자동 교정에 필요한 임시 조합은 EventTapManager가 안전한 일반 텍스트 입력란임을 확인한 뒤 별도로 처리합니다"라고 말한다. 추적한 결과: 화면 위의 임시 조합은 어디에도 없다. 여기서 말하는 "임시 조합"은 `HangulStructure.evaluate`(`HangulStructure.swift:74-101`)가 **메모리 안에서** 자체 `HangulCompositionTracker`를 돌리는 재생이다. 화면을 건드리지 않고 이벤트를 post하지 않는다. 주석은 이 둘을 혼동해서 계층 관계에서 배타성을 결론지었다. 게이트는 아무것도 막고 있지 않다.

### 6-7. scope 항은 자기가 주장하는 보증과 중복이다

"명시적으로 등록된 앱에서만 직접 조합"은 이미 두 번 강제된다: `isTargetAppFront`(`:290` → `:154` → `TargetAppManager.isTargetApp` `:168`)가 등록을 요구하고, `isHangulCompositionEnabled`(`TargetAppManager.swift:172`)가 미등록 앱에 false를 반환한다. scope 항은 안전을 하나도 더하지 않고 회귀만 더했다.

### 6-8. 수정

```swift
// AppMonitor.swift:275 — scope 항 삭제
let compositionEnabled = targetAppManager?.isHangulCompositionEnabled(
    bundleID: frontAppBundleID,
    appName: frontAppName
) ?? false
```

`:286-288` 주석을 사실로 교체:

```swift
// 직접 한글 조합은 명시적으로 등록되고(isTargetAppFront) 앱별 토글이 켜진
// 앱에서만 활성화됩니다. 자동 교정 엔진이 후보를 만들 때 쓰는 "임시 조합"은
// HangulStructure.evaluate 안의 메모리 재생이며(화면을 건드리지 않음) 이
// 플래그와 무관합니다. R2(조합)와 R3(소급 교정)는 배타가 아니라 D3 계층입니다.
```

### 6-9. 함께 출하할 것

**(a) 테스트.** `AppMonitorTests.swift`는 **존재하지 않는다**(확인함). 그리고 전체 스위트에서 `isActive = true`는 3회만 나온다. 공존 상태의 자모/경계/백스페이스 경로는 사실상 커버리지가 0이다. "이미 실행 중"은 도달 가능하다는 뜻이지 테스트되어 있다는 뜻이 아니다.
- `AppMonitorTests`: 등록 + 조합 활성 앱이 **두 scope 모두에서** `isActive == true`
- tap 레벨: 공존 상태에서 자모 키 1개가 정확히 1회의 `executeResult` 방출과 0회의 엔진 구동 출력을 낸다
- tap 레벨: 공존 상태에서 주입 이벤트는 기록도 조합도 하지 않는다

**(b) `clearSuppressedKeyUps()`를 `resetTransientState()`에 추가** (1-6). `MackorApp.swift:264`가 이미 앱 전환마다 `resetComposition()`을 단독 호출하므로 오늘 살아 있는 누수다.

**(c) 동작 변경 공시.** `.allApps`에서 사용자가 추가한 모든 앱이 직접 조합을 받는다 — `TargetApp.init`이 `hangulCompositionEnabled: true`를 기본값으로 하고 `addApp`이 그 기본값을 쓰기 때문이다. 이 사용자에게는 CorelDRAW + `autoDetectKnownApps`가 잡은 것(키워드 coreldraw/intellij). 이것이 의도된 복구지만 **앱별 토글이 설정에서 계속 보이는 off 스위치로 남아야 한다.** 별건으로, `.allApps`에서는 앱별 **자동 교정** 토글이 이미 무력하다(`isAutoCorrectionEnabled`가 true로 단락) — 기존 문제지만 이제 사용자 눈에 띌 것이다.

### 6-10. 번들하지 말 것

- **`:435` 롤오버 경합.** `invalidatePendingBoundaryCorrection()`이 모든 keyDown에서 무조건 실행되므로, 빠른 타이피스트가 경계 keyUp 전에 다음 키를 누르면 교정이 조용히 폐기된다(테스트로 증명됨). 세 설계 모두 직교적이라고 동의한다. 자체 테스트가 필요하다. **수정 방향은 기록해 둔다: 무효화가 아니라 *적용*이 옳다** — 트리거 keyUp 대기 중 새 keyDown이 오면 경계 키는 이미 앱에 도달했으므로 교정을 즉시 적용해야 한다.
- **후행 마침표 백스페이스 발산** (확인함): `:503`의 `commitCompositionIfNeeded`가 트래커를 idle로 리셋하는데 엔진은 letter stroke를 유지한다 → `:509-513`에서 마침표를 pop → 다음 백스페이스가 `:518`에서 엔진 stroke 1개를 떨어뜨리지만 `:536-539`의 `tracker.processBackspace()`가 idle이라 passthrough → 물리 백스페이스가 음절 통째로 삭제. `gks.` → `한.` → BS → `한` → BS → 화면은 비었는데 엔진은 `하`가 남았다고 믿는다. 현재는 `FocusedInputSafety.isCurrentFocus`의 캐럿 오프셋 비교가 fail-closed로 막는다. 수정: 조합 분기에서 `tracker.processBackspace()`가 passthrough인데 엔진이 여전히 stroke를 들고 있으면 `return event` 전에 `invalidateAutomaticCorrectionTokenUntilBoundary()`(`:1239-1243`) 호출. **별도 PR.**

### 6-11. 정직성 주석

이 수정은 사용자의 CorelDRAW를 복구하지만 **R1을 만족시키지 않는다.** 조합은 여전히 `TargetAppManager` 등록을 요구한다(`AppMonitor.swift:290` → `:154`). Phase A를 R1 수정으로 제시하지 말 것. R1을 만족시키는 것은 rung 분류기이며 Phase D/E에 온다.

---

## 7. 단계별 계획과 검증

### Phase 0 — 프로브 수정과 측정 (1시간)
- `ProbeInputController.swift:102`를 마커 비교로 수정, raw 값 로깅
- 현행 Mackor를 함께 돌려 tap 주입을 발생시키고 TextEdit + CorelDRAW에서 로그 수집
- **검증(측정 자체가 게이트):** 로그에 `rawUserData=1215525702`(0x48474C46)를 가진 keyDown이 나타나는가? 나타나면 A-1 해소, 마커를 2차 방어선으로 확정. 안 나타나면 백스톱 카운터가 유일한 심층 방어이며 arbiter 단독 의존을 문서에 명시.
- flap 계측 코드도 이 단계에서 넣는다(activate/deactivate 간격 히스토그램). **TTL을 정하기 전에 데이터부터.**

### Phase A — 회귀 수정 (즉시 출하, IMK 없음, 새 개념 없음)
- `AppMonitor.swift:275` scope 항 삭제, `:286-288` 주석 재작성
- `resetTransientState()`에 `clearSuppressedKeyUps()` 추가
- `AppMonitorTests.swift` 신설 + 공존 상태 tap 테스트 3종
- **검증:** 기존 161 테스트 + 44 rule + 405 golden 전부 **무수정** 통과. CorelDRAW에서 `dkssud` → `안녕` 수동 확인.
- 독립 출하 가능, 독립 revert 가능. **사용자가 지금 막혀 있는 유일한 단계.**

### Phase B — `MackorSession` + `EditPlan` 추출, tap을 `TapRenderer`로 (1주)
- 엔진 파일 무변경(SHA 동결 유지)
- **검증:** 44 + 405 무수정 통과 **그리고** 골든 코퍼스 verdict diff가 `pre-imk` 대비 정확히 0. no-op 릴리스로 출하 가능 — 그것이 검증 가능성의 근거다.

### Phase C — `TransportArbiter` + IMK 골격 (항상 false) (1주)
- Squirrel/Gureum 형태의 `Info.plist`, 단일 입력 모드
- `handle()` 전체 방어 래핑 — 어떤 오류에서도 `false` 반환(passthrough 불변식). 강제 언랩 전면 금지. 크래시하는 IME는 시스템 전역 타이핑을 막고 `imklaunchagent`는 반복 크래시 후 재시작을 거부한다.
- 컨트롤러는 `activateServer`에서 클라이언트를 분류하고 **rung을 로깅만 한다. 아무것도 조합하지 않는다.**
- **`AppMonitor.swift:44`/`:237-248` 입력 소스 정체성 수정을 여기서 함께 한다** (5-6). 안 하면 Mackor 선택 즉시 tap이 죽는다.
- 세 게이트(1-7 a/b/c) 삽입, arbiter는 `.tap` 고정
- **검증:** 동작 변경 0. 사용자 실제 앱들의 rung 분포 로그 수집. flap 분포 확정. 위험 대비 가치가 가장 높은 단계 — 키를 손상시킬 능력이 없는 상태로 실측을 얻는다.

### Phase D — rung 1/2에서 IMK 조합 활성화 (1–2주)
- 트래커 기반 마크드 텍스트, 3-4의 승격 전 게이트, 세션 중간 강등 금지
- **검증:** `REQUIREMENTS.md:106-112` 매트릭스 — `안녕하세요 반갑습니다`, 느린/빠른 입력 × 5개 확정 트리거 × 10회 무손실 — TextEdit, KakaoTalk, Safari, Chrome, VS Code에서. 전송 계층 간 텍스트 패리티 테스트가 골든 코퍼스 전체에서 통과.

### Phase E — IMK R3 (1주)
- mozc 패턴 소급 교정, 캐럿 rect(`attributes(forCharacterIndex:lineHeightRectangle:)`)에 앵커된 칩, 내부 한/영 불리언, `TICapsLockLanguageSwitchCapable` 기반 CapsLock 전환(권한 불필요)
- `CorrectionNoticeController` 무변경, 앵커만 교체
- **검증:** R3 시나리오 매트릭스 + 칩 위치 육안 확인

### Phase F — 패키징·서명·권한 (1주)
- Developer ID 서명, 공증, 스테이플
- 첫 rung 3 클라이언트에서의 지연 손쉬운 사용 요청
- 앱별 상태 UI
- **검증:** R6 A/B 실측(ad-hoc 2회 vs Dev ID 2회, 프롬프트 횟수)을 **먼저 돌리고** 그 결과를 `REQUIREMENTS.md`에 기록한 뒤에야 R6 관련 주장을 작성. `~/Library/Input Methods/` 이동의 1회 재승인은 A/B와 분리해서 측정(오염 방지). D2에 따라 버전을 3곳(`build-installer.sh:10-11`, `install.sh:10-11`, `project.pbxproj`)에 PR 전에 고정.

Phase 0과 A는 나머지 전부와 독립. B~E는 엄격 순서. 각 단계는 제품이 동작하는 상태로 머지 가능하다.

---

## 8. 남은 위험

| # | 위험 | 왜 실재하는가 | 완화 / 남는 노출 |
|---|---|---|---|
| A-1 | **필드 42가 `handle()`까지 살아남지 않음** | 측정된 적 없음. 유일한 관련 로그는 프로브 버그로 무의미. | Phase 0에서 측정. arbiter가 1차 방어선이고 마커는 심층 방어이므로 실패해도 아키텍처는 생존. 백스톱 카운터(250ms 데드라인)가 3차. |
| A-2 | **arbiter가 포커스 변경 후 첫 키와 경합** | `activateServer` vs `didActivateApplicationNotification` 순서는 미규정. | `.none` = 양쪽 passthrough. 최악은 교정 안 된 키 몇 개, 이중 교정은 아님. |
| A-3 | **마크드 텍스트는 받아들이면서 키 소비는 무시하는 클라이언트** | 프로브가 볼 수 없는 유일한 성질. 부류가 공집합이라는 증거 없음. | 승격 전 왕복 게이트 + "세션 중간 강등 금지". 확정 텍스트를 건드리지 않으므로 손상 비용 0, 대신 첫 세션은 tap(또는 무동작). **제거가 아니라 봉쇄이며, 그렇게 문서에 쓴다.** |
| A-4 | **IME 크래시가 시스템 전역 타이핑을 막음** | 이 시스템 최악의 실패. `imklaunchagent`가 반복 크래시 후 재시작 거부. 유일하게 폭발 반경이 사용자 머신 전체. | `handle()` 전체 방어 래핑, 단일 fallback return, IMK 계층 강제 언랩 금지. rung ≠ 3에서 AX 호출 절대 금지. tap 지연 생성. README 탈출구: "Apple 두벌식을 목록에서 지우지 마세요." N회 크래시 후 자가 선택 해제 워치독 검토. |
| A-5 | **`HangulStructure`와 IMK 조합기의 발산** | `decision.original`이 트래커 재생으로 **정의**되어 있다. 두 번째 조합기는 교체 range를 조용히 깨뜨린다. | `HangulCompositionTracker`를 IMK 조합기로 재사용. 골든 코퍼스 전체 전송 간 텍스트 패리티 테스트. **조용히 실패하는 부류라 가장 주시해야 한다.** |
| A-6 | **`PhysicalKeystroke`를 characters에서 파생** | QWERTY 테스트 전부 통과, 다른 물리 배열에서 붕괴. 405 케이스 전부 키코드 키잉. | 변환 함수 1개 + 전송 간 동일성 단위 테스트. |
| A-7 | **`selectedRange`가 MS Office를 크래시** | mozc가 정확히 이 이유로 제외. 프로브 자체가 일으키는 재해는 런타임 게이트로 복구 불가. | rung 0 금지 목록을 **모든 프로브 호출보다 먼저** 확인. |
| A-8 | **`~/Library/Input Methods/` 이동으로 TCC 리셋** | 다른 경로 → 안정적 서명이어도 새 TCC identity일 가능성. | 재승인 1회를 예산에 넣고 미리 공지. R6 A/B와 분리 측정. |
| A-9 | **Sparkle이 실행 중인 IME 바이너리 교체** | `MIGRATION_PLAN.md` R-4 미해결. Squirrel 전례 미조사. | Squirrel 처리 방식 조사 + 실기 검증. Phase F. |
| A-10 | **rung 캐시가 앱 업데이트를 넘어 stale** | 앱 업데이트가 텍스트 입력 동작을 바꿀 수 있고, 그때 캐시된 rung 1은 적극적으로 해롭다. | `bundleID + CFBundleVersion` 키잉, 매 `activateServer` 재프로브, 강등이 항상 캐시를 이긴다. |
| A-11 | **flap 완화가 잘못 튜닝되면 그것이 "먹힘" 증상이 됨** | 측정된 1–3ms activate/deactivate 쌍 + 동일 클라이언트 연속 중복 deactivate. | 멱등 핸들러 + clientID 키 세션. **Phase 0에서 로깅 먼저, 튜닝 나중.** |
| A-12 | **`:435` 롤오버 경합이 하이브리드를 넘어 생존** | 테스트로 증명된 기존 버그. Phase A가 공존 앱을 늘려 노출을 넓힌다. | 별도 PR, 별도 테스트. 방향: 무효화가 아니라 즉시 적용. |

**가장 주시할 둘:** A-4(유일하게 폭발 반경이 앱 하나가 아니라 머신 전체), A-5(**조용히** 실패하며, 테스트 전략 전체가 두 조합기의 일치를 가정하는 코드베이스에서 한 글자 차이로 어긋난다).

**프로세스 위험 하나를 명시한다.** 이 프로젝트의 작업 원칙(`REQUIREMENTS.md` §6)은 검증 전에 결론을 말한 사례들과 `replacementRange` 발견이 첫 실험이 틀린 것을 테스트한 탓에 전면 철회된 사례를 기록하고 있다. 이 설계에서 **추론이지 측정이 아닌** 것은 둘이다: 필드 42 생존(A-1)과 "rung 1 프로브 통과가 소비 정직성을 예측한다"는 가정(A-3). 둘 다 Phase 0/C에 예정되어 있고, 그 로그가 존재하기 전에 어느 쪽도 확정된 것으로 서술해서는 안 된다.