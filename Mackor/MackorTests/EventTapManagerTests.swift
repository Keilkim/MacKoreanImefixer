import XCTest
import CoreGraphics

final class EventTapManagerTests: XCTestCase {
    func testSpaceCorrectionReplacesTokenAndRequestsKoreanSource() throws {
        let output = FakeKeyboardOutput()
        let focus = FakeFocusInspector()
        // `dho`→왜는 한글 한 음절이므로 단음절 관문을 지납니다. 자산을 주입하지
        // 않으면 fail-closed 로 보존되는 것이 계약입니다 — 여기서는 실제 저장소
        // 자산을 주입해 이 배관 테스트가 end-to-end 증거도 겸하게 합니다.
        let manager = makeManager(
            output: output,
            focus: focus,
            monosyllableLexicon: try makeMonosyllableLexicon()
        )
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true

        var switchedDirections: [CorrectionDirection] = []
        manager.onInputSourceSwitch = { direction in
            switchedDirections.append(direction)
            return InputSourceSwitchReceipt(
                fromInputSourceID: "com.apple.keylayout.ABC",
                toInputSourceID: InputSourceController.koreanTwoSetInputSourceID,
                selectedSourceGeneration: 2
            )
        }

        type("dho", into: manager)
        let boundary = keyDown(0x31)
        XCTAssertNotNil(manager.handleKeyDown(boundary))
        XCTAssertTrue(output.actions.isEmpty)
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))

        XCTAssertEqual(output.actions, [
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .text("왜"),
            .key(0x31, false),
        ])
        XCTAssertEqual(switchedDirections, [.latinToKorean])
    }

    /// 키열 사본이 경계마다 비워져야 한다.
    ///
    /// 사본은 `processBoundary`가 내부 `defer { reset() }`으로 토큰을 비우는
    /// 것을 알지 못한다. 그래서 한때 사본이 경계를 넘길 때마다 계속 쌓였고,
    /// 사본을 쓰는 계층(어휘 tiebreaker·방향 수정)이 전부 길이 대조에서 걸려
    /// **한 번도 발동하지 못했다.** 에러도 경고도 없이 조용히 아무 일도 하지
    /// 않았기 때문에 오래 눈치채지 못했다.
    ///
    /// 두 번째 토큰이 교정되면 그 시점에 사본 길이가 실제 토큰과 같았다는
    /// 뜻이므로, 이 테스트가 누수를 잡는다.
    func testKeystrokeMirrorIsClearedAtEveryBoundary() throws {
        let output = FakeKeyboardOutput()
        let manager = makeManager(output: output, lexicalTiebreaker: try makeLexicalTiebreaker())
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true

        // 첫 토큰을 경계까지 흘려보낸다.
        type("dkwn", into: manager)
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))
        output.actions.removeAll()

        // 두 번째 토큰. 사본이 쌓여 있으면 길이가 어긋나 어휘 계층이 죽는다.
        type("sork", into: manager)
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))

        XCTAssertTrue(
            output.actions.contains(.text("내가")),
            "경계 뒤 사본이 남아 어휘 계층이 발동하지 못했습니다: \(output.actions)"
        )
    }

    // MARK: - 낡은 캡처 앵커 (간헐 실패)
    //
    // 토큰 시작 시의 AX 읽기가 낡은 캐럿 위치를 돌려주면 산술 검증
    // (`지금 캐럿 == 캡처 캐럿 + 입력 길이`)이 어긋난다. 재시도해도 다시 읽는
    // 건 현재 캐럿뿐이라 영영 맞지 않는다 — 사용자가 겪은 "되다가 안 되다가".

    /// 산술 검증이 실패해도, 캐럿 바로 앞 글자가 원문과 같으면 교정해야 한다.
    /// 그게 지울 대상이 그 자리에 있다는 직접 증거다.
    func testStaleAnchorStillCorrectsWhenCaretTextMatches() {
        let output = FakeKeyboardOutput()
        let focus = FakeFocusInspector()
        focus.currentFocusMatches = false   // 앵커가 낡아 산술은 실패
        focus.caretTextMatches = true       // 캐럿 앞 글자는 원문과 일치
        let manager = makeManager(output: output, focus: focus)
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true

        type("dkwn", into: manager)
        let boundary = keyDown(0x31)
        XCTAssertNil(manager.handleKeyDown(boundary))
        manager.noteSuppressedKeyDown(boundary)
        XCTAssertNil(manager.handleKeyUp(keyUp(0x31)))

        XCTAssertTrue(
            output.actions.contains(.text("아주")),
            "캐럿 앞 글자가 원문과 같은데도 교정을 포기했습니다: \(output.actions)"
        )
        XCTAssertTrue(focus.currentFocusOffsets.isEmpty)
        XCTAssertTrue(focus.didReanchorFocusToken)
    }

    /// 둘 다 실패하면 교정하지 않아야 한다. 캐럿이 실제로 옮겨간 경우이므로
    /// 엉뚱한 자리의 글자를 지우는 것보다 안 고치는 편이 낫다.
    func testCorrectionIsAbandonedWhenNeitherCheckConfirms() {
        let output = FakeKeyboardOutput()
        let focus = FakeFocusInspector()
        focus.currentFocusMatches = false
        focus.caretTextMatches = false
        let manager = makeManager(output: output, focus: focus)
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true

        type("dkwn", into: manager)
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))

        XCTAssertFalse(
            output.actions.contains(.text("아주")),
            "확인되지 않았는데 교정했습니다: \(output.actions)"
        )
    }

    // MARK: - 포커스 조회의 일시적 실패
    //
    // 실측: Chrome의 차가운 첫 AX 조회는 약 57ms 걸려 이벤트 탭 경로의 50ms
    // 제한을 넘는다. 그 타임아웃을 "이 필드는 교정 금지"로 확정해 버리면
    // Chrome에서는 자동 교정이 영영 걸리지 않는다 — 실제로 그랬다.

    /// 첫 조회가 일시적으로 실패해도 같은 keyDown의 짧은 재시도로 복구합니다.
    func testTransientFocusFailureRetriesInsteadOfAbandoningTheToken() {
        let output = FakeKeyboardOutput()
        let focus = FakeFocusInspector()
        focus.transientFailuresRemaining = 1   // 첫 키만 타임아웃, 그다음 성공
        let manager = makeManager(output: output, focus: focus)
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true

        type("dkwn", into: manager)
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))

        XCTAssertTrue(
            output.actions.contains(.text("아주")),
            "일시적 조회 실패 뒤 재시도가 이뤄지지 않았습니다: \(output.actions)"
        )
    }

    /// 첫 AX 요청 하나가 예산을 다 써도 첫 글자를 버리지 않고, 다음 글자에서
    /// 데워진 연결로 성공하면 완전한 토큰을 교정해야 합니다.
    func testFocusProbeBudgetCarriesTheFirstStrokeIntoTheNextKey() {
        let output = FakeKeyboardOutput()
        let focus = FakeFocusInspector()
        focus.transientFailuresRemaining = 1
        var uptimeReads: [TimeInterval] = [0, 0.101]
        let manager = makeManager(
            output: output,
            focus: focus,
            monotonicNow: { uptimeReads.isEmpty ? 0.101 : uptimeReads.removeFirst() }
        )
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true

        type("dkwn", into: manager)
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))

        XCTAssertTrue(output.actions.contains(.text("아주")), "첫 d가 유실됐습니다")
        XCTAssertEqual(focus.tokenRequestCount, 2)
    }

    /// 계속 실패하는 앱에서는 상한에 닿으면 포기해야 한다. 그러지 않으면 매
    /// 키마다 AX IPC를 반복해 이벤트 탭이 느려진다.
    func testPersistentFocusFailureStopsRetryingAfterTheCap() {
        let output = FakeKeyboardOutput()
        let focus = FakeFocusInspector()
        focus.transientFailuresRemaining = 99   // 끝까지 실패
        let manager = makeManager(output: output, focus: focus)
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true

        type("dkwndkwn", into: manager)
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))

        XCTAssertTrue(output.actions.isEmpty, "실패가 계속되는데 교정을 시도했습니다")
        // 소프트 상한(2키) × in-key 재시도(3회) = 6에서 확정 거부로 굳는다.
        // 8키 "dkwndkwn"을 쳐도 6에 머물러 "조회는 토큰당 O(1), 키당 아님"
        // 불변식이 유지됨을 못박는다(상수만 3→6으로 바뀜).
        XCTAssertLessThanOrEqual(
            focus.tokenRequestCount, 6,
            "상한을 넘겨 매 키마다 조회했습니다: \(focus.tokenRequestCount)회"
        )
    }

    // MARK: - "첫 단어만 안 바뀐다" — 두 가설의 판별 실험
    //
    // 재현(3회, 모두 Safari 주소창): 같은 필드에서 **첫 토큰만** 교정되지 않고
    // 그 뒤 토큰은 전부 정상. "아주 좋아"를 치면 "dkwn 좋아"가 남는다.
    //
    // 가설 A — 일시적 선택 영역. 주소창을 클릭하면 URL 전체가 선택된다.
    //   head-insert 탭이라 첫 keyDown은 앱이 선택을 접기 전에 도착하고, 그
    //   조회만 `.ineligible`을 받는다. 재시도가 없으므로 그 토큰이 통째로 죽는다.
    // 가설 B — 차가운 AX가 시도 예산을 소진. 시도 횟수가 키가 아니라 토큰
    //   단위라, 키마다 한 번씩 실패하면 세 번째 키에서 상한에 닿아 확정 거부된다.
    //
    // 아래 세 테스트는 *의도한* 동작을 고정한다 — 어느 쪽이든 첫 단어는 교정돼야
    // 한다. 실패하는 쪽이 실제 원인이다. 마지막 대조군은 HEAD에서 통과해야
    // 하며, 그것이 깨지면 원인은 제품이 아니라 이 하네스 사용법이다.

    /// 가설 A. 첫 조회만 낡은 선택 영역을 읽어 거부돼도, 그 단어는 교정돼야 한다.
    ///
    /// 수정됨(감사 #10): 선택-전용 거부를 `.ineligibleTransientSelection`으로
    /// 분리해 즉시 래치하지 않고 다음 키에서 재확인한다. 첫 키에서 선택이
    /// 읽혀도 키열은 계속 기록되고, 둘째 키에서 빈 캐럿으로 바뀌면 `.eligible`이
    /// 떠 그 단어가 교정된다.
    func testTransientSelectionOnFirstKeyStillCorrectsThatWord() {
        let output = FakeKeyboardOutput()
        let focus = FakeFocusInspector()
        focus.ineligibleProbesRemaining = 1   // 첫 키만 낡은 선택을 읽는다
        let manager = makeManager(output: output, focus: focus)
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true

        type("dkwn", into: manager)
        _ = manager.handleKeyDown(keyDown(0x31))
        _ = manager.handleKeyUp(keyUp(0x31))

        XCTAssertTrue(
            output.actions.contains(.text("아주")),
            "첫 키의 일시적 선택 영역 때문에 그 단어를 통째로 잃었습니다: \(output.actions)"
        )
    }

    /// 수정 후: 첫 단어도 두 번째 단어도 모두 교정돼야 한다. 예전엔 첫 단어만
    /// 죽던 증상(사용자가 겪은 그대로)이 이 수정으로 사라졌음을 고정한다 —
    /// 전이 선택을 즉시 확정 거부하지 않고 다음 키에서 재확인하기 때문이다.
    func testTransientSelectionCorrectsFirstWordToo() {
        let output = FakeKeyboardOutput()
        let focus = FakeFocusInspector()
        focus.ineligibleProbesRemaining = 1
        let manager = makeManager(output: output, focus: focus)
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true

        type("dkwn", into: manager)
        _ = manager.handleKeyDown(keyDown(0x31))
        _ = manager.handleKeyUp(keyUp(0x31))
        let afterFirstWord = output.actions
        output.actions.removeAll()

        type("dkwn", into: manager)
        _ = manager.handleKeyDown(keyDown(0x31))
        _ = manager.handleKeyUp(keyUp(0x31))
        let afterSecondWord = output.actions

        XCTAssertTrue(
            afterFirstWord.contains(.text("아주")),
            "수정 후 첫 단어도 교정돼야 한다: \(afterFirstWord)"
        )
        XCTAssertTrue(
            afterSecondWord.contains(.text("아주")),
            "두 번째 단어도 정상 교정돼야 한다: \(afterSecondWord)"
        )
    }

    /// 가설 B. 키마다 조회 하나가 AX 예산을 다 써서 세 키 연속 실패해도,
    /// 네 번째 키에서 성공하면 그 단어는 교정돼야 한다.
    ///
    /// 조회가 일어날 때만 시계를 밀어, 키마다 재시도 없이 조회 **한 번**만
    /// 하도록 만든다(예산 만료). 경계 처리 경로는 조회를 하지 않으므로 그쪽
    /// 예산은 건드리지 않는다.
    func testColdAXAcrossThreeKeysStillCorrectsThatWord() {
        let output = FakeKeyboardOutput()
        let focus = FakeFocusInspector()
        focus.transientFailuresRemaining = 3
        var clock: TimeInterval = 0
        focus.onProbeRequest = { clock += 0.2 }
        let manager = makeManager(
            output: output,
            focus: focus,
            monotonicNow: { clock }
        )
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true

        type("dkwn", into: manager)
        _ = manager.handleKeyDown(keyDown(0x31))
        _ = manager.handleKeyUp(keyUp(0x31))

        XCTAssertTrue(
            output.actions.contains(.text("아주")),
            "토큰 단위 시도 예산이 단어 중간에서 소진돼 나머지 키를 버렸습니다: \(output.actions)"
        )
    }

    /// 대조군. 같은 시계 장치에 실패를 **한 번**만 두면 예산 안에서 회복해야
    /// 한다. 이것마저 실패하면 제품이 아니라 위 두 테스트의 하네스 사용이 틀린
    /// 것이므로, 위 결과를 근거로 삼을 수 없다.
    func testColdAXWithinAttemptBudgetRecoversAndCorrects() {
        let output = FakeKeyboardOutput()
        let focus = FakeFocusInspector()
        focus.transientFailuresRemaining = 1
        var clock: TimeInterval = 0
        focus.onProbeRequest = { clock += 0.2 }
        let manager = makeManager(
            output: output,
            focus: focus,
            monotonicNow: { clock }
        )
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true

        type("dkwn", into: manager)
        _ = manager.handleKeyDown(keyDown(0x31))
        _ = manager.handleKeyUp(keyUp(0x31))

        XCTAssertTrue(
            output.actions.contains(.text("아주")),
            "대조군이 깨졌습니다 — 하네스 사용이 틀렸다는 뜻입니다: \(output.actions)"
        )
    }

    /// 가설 B의 더 단순한 변종. 시계를 조작하지 않아도 재현된다.
    ///
    /// 예산이 남아 있으면 **첫 keyDown 안에서** 재시도가 세 번 다 소모되고,
    /// 세 번째가 여전히 실패하면 그 자리에서 확정 거부로 굳는다. 그 뒤 이
    /// 토큰에서는 AX가 아무리 멀쩡해져도 다시 묻지 않는다.
    ///
    /// 수정됨(감사 #6): 첫 키의 재시도 3회가 전부 소진돼도 즉시 확정 거부로
    /// 굳히지 않고 소프트 카운터만 1 올린 뒤 키열을 계속 기록한다. 실패한
    /// 조회가 AX를 데우므로 둘째 키가 `.eligible`을 받아 그 단어를 교정한다.
    /// 소진이 상한 키 수(2)만큼 이어질 때만 확정 거부로 굳는다.
    func testColdAXExhaustingRetriesInOneKeyStillCorrectsThatWord() {
        let output = FakeKeyboardOutput()
        let focus = FakeFocusInspector()
        focus.transientFailuresRemaining = 3   // 네 번째부터는 정상
        let manager = makeManager(output: output, focus: focus)
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true

        type("dkwn", into: manager)
        _ = manager.handleKeyDown(keyDown(0x31))
        _ = manager.handleKeyUp(keyUp(0x31))

        XCTAssertTrue(
            output.actions.contains(.text("아주")),
            "첫 키가 재시도 예산을 다 태워 토큰이 굳었습니다: \(output.actions) "
                + "조회 \(focus.tokenRequestCount)회"
        )
    }

    // MARK: - 소프트 거부 안전망 — 새로 넓힌 경로가 파괴로 새지 않는지 고정
    //
    // 아래 세 테스트는 "일시적 거부를 미해결로 보존"이라는 이번 변경이, 늘어난
    // 적격 토큰을 파괴 경로로 흘리지 않음을 못박는다. 영구 거부는 여전히 첫
    // 프로브에서 굳고(#2), 늘 선택된 필드는 키당 thrash 없이 2프로브에서 굳으며
    // (#1, 3d44306 perf 보존), 새로 적격이 된 토큰도 경계 검증이 실패하면
    // 파괴 없이 포기한다(#3, 결정적 안전 논증의 토큰 집단판).

    /// URL이 아니면서 늘 전체 선택을 유지하는 드문 필드: 소프트 상한(2)에서
    /// 확정 거부로 굳고, 키당 AX 조회를 반복하지 않는다(정확히 2회). 3d44306이
    /// 지키려던 "영구 선택 필드에서 키당 thrash 없음" 불변식을 선택측에서 고정.
    func testPersistentlySelectedFieldRefusesAfterTwoProbes() {
        let output = FakeKeyboardOutput()
        let focus = FakeFocusInspector()
        focus.ineligibleProbesRemaining = 99   // 끝까지 선택 유지
        let manager = makeManager(output: output, focus: focus)
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true

        type("dkwn", into: manager)
        _ = manager.handleKeyDown(keyDown(0x31))
        _ = manager.handleKeyUp(keyUp(0x31))

        XCTAssertTrue(
            output.actions.isEmpty,
            "늘 선택된 필드에서 교정을 시도했습니다: \(output.actions)"
        )
        XCTAssertEqual(
            focus.tokenRequestCount, 2,
            "선택은 in-key 재시도 대상이 아니어야 합니다 — 키당 thrash: \(focus.tokenRequestCount)회"
        )
    }

    /// 영구 거부(보안·미지원 role·보호 subrole·보호 메타데이터)는 소프트
    /// 카운터로 완화되지 않고 첫 프로브에서 즉시 확정 거부로 굳는다.
    func testPermanentIneligibleLatchesOnFirstProbe() {
        let output = FakeKeyboardOutput()
        let focus = FakeFocusInspector()
        focus.tokenAvailable = false   // 영구 .ineligible
        let manager = makeManager(output: output, focus: focus)
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true

        type("dkwn", into: manager)
        _ = manager.handleKeyDown(keyDown(0x31))
        _ = manager.handleKeyUp(keyUp(0x31))

        XCTAssertTrue(
            output.actions.isEmpty,
            "영구 거부 필드에서 교정을 시도했습니다: \(output.actions)"
        )
        XCTAssertEqual(
            focus.tokenRequestCount, 1,
            "영구 거부가 소프트 카운터로 완화됐습니다 — 프로브 \(focus.tokenRequestCount)회"
        )
    }

    /// 전이 선택으로 미뤘다가 뒤늦게 적격이 된 토큰도, 경계에서 두 검증(anchored·
    /// reanchored)이 모두 실패하면 삭제하지 않고 안전하게 포기한다. 넓힌 경로가
    /// 파괴 경로에 미검증 토큰을 넘기지 않음을 직접 고정.
    func testRecoveredTransientTokenAbandonsWhenBoundaryUnverified() {
        let output = FakeKeyboardOutput()
        let focus = FakeFocusInspector()
        focus.ineligibleProbesRemaining = 1     // 키1 전이 선택 → 키2 적격
        focus.currentFocusMatches = false       // anchored 실패
        // caretTextMatches는 기본 false — reanchored도 실패
        let manager = makeManager(output: output, focus: focus)
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true

        type("dkwn", into: manager)
        _ = manager.handleKeyDown(keyDown(0x31))
        _ = manager.handleKeyUp(keyUp(0x31))

        XCTAssertFalse(
            output.actions.contains(.text("아주")),
            "경계 검증이 모두 실패했는데 교정(삭제)을 시도했습니다: \(output.actions)"
        )
    }

    // MARK: - LexicalGuard 배선 — 파괴적 오교정이 이벤트 흐름에서 실제로 멈추는가

    /// `dns`+Space: 예전엔 `운`으로 파괴됐다. 모음 없는 라틴→단음절 구조
    /// 거부가 이벤트 탭 경로에서 실제로 발동해 아무것도 방출하지 않는다.
    func testVowellessAcronymIsNotDestroyedIntoASingleSyllable() {
        let output = FakeKeyboardOutput()
        let focus = FakeFocusInspector()
        let manager = makeManager(output: output, focus: focus)
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true

        type("dns", into: manager)
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))

        XCTAssertTrue(
            output.actions.isEmpty,
            "dns가 여전히 교정(파괴)됩니다: \(output.actions)"
        )
    }

    /// 한글 자판으로 `ac`를 친 화면(`ㅁㅊ`)+Space: 예전엔 `ac`로 파괴됐다.
    /// 결과가 실단어가 아니므로 순수 자음 게이트가 원문을 보존한다.
    func testFixedJamoExpressionIsNotDestroyedIntoNonWord() {
        let output = FakeKeyboardOutput()
        let focus = FakeFocusInspector()
        let manager = makeManager(output: output, focus: focus)
        manager.inputSourceKind = .koreanTwoSet
        manager.isAutoCorrectionEnabled = true

        type("ac", into: manager)
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))

        XCTAssertTrue(
            output.actions.isEmpty,
            "ㅁㅊ이 여전히 ac로 교정(파괴)됩니다: \(output.actions)"
        )
    }

    /// `ㅈㄷ`→we처럼 결과가 실단어인 순수 자음은 계속 교정된다 — 게이트가
    /// 정당한 교정까지 막지 않음을 고정한다(사전 증거 주입).
    func testConsonantRunWithRealWordResultStillCorrects() {
        let output = FakeKeyboardOutput()
        let focus = FakeFocusInspector()
        let manager = makeManager(output: output, focus: focus, guardEvidence: ["we"])
        manager.inputSourceKind = .koreanTwoSet
        manager.isAutoCorrectionEnabled = true

        type("we", into: manager)
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))

        XCTAssertTrue(
            output.actions.contains(.text("we")),
            "실단어 결과의 정당한 교정이 막혔습니다: \(output.actions)"
        )
    }

    // MARK: - 자음 매시 어휘 구제
    //
    // 구조 규칙은 서로 다른 자음 자모 3+개 나열을 키보드 매시로 보고 보존하는데,
    // 그중 `card`·`water`처럼 자음 자판 글자만으로 적힌 실제 영어 단어가 함께
    // 죽는다. 4키 이상이고 결과가 동결 사전에 실단어로 있을 때만 되살린다.

    /// 한글 자판으로 `card`를 친 화면(`ㅊㅁㄱㅇ`)+Space: 4키 매시이고 결과가
    /// 실단어이므로 영어로 되살아난다.
    func testConsonantMashRealWordIsRescued() {
        let output = FakeKeyboardOutput()
        let focus = FakeFocusInspector()
        let manager = makeManager(output: output, focus: focus, guardEvidence: ["card"])
        manager.inputSourceKind = .koreanTwoSet
        manager.isAutoCorrectionEnabled = true

        type("card", into: manager)
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))

        XCTAssertTrue(
            output.actions.contains(.text("card")),
            "ㅊㅁㄱㅇ이 card로 구제되지 않았습니다: \(output.actions)"
        )
    }

    /// 3키 매시는 `ㅁㅊㄷ`(미쳤다)류 실사용 초성체와 조밀하게 겹치므로 하한
    /// 아래로 제외한다. 결과가 사전에 있어도(`cat`) 되살리지 않는다.
    func testShortConsonantMashIsNotRescued() {
        let output = FakeKeyboardOutput()
        let focus = FakeFocusInspector()
        let manager = makeManager(output: output, focus: focus, guardEvidence: ["cat"])
        manager.inputSourceKind = .koreanTwoSet
        manager.isAutoCorrectionEnabled = true

        type("cat", into: manager)
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))

        XCTAssertTrue(
            output.actions.isEmpty,
            "3키 매시가 하한을 넘어 교정됐습니다: \(output.actions)"
        )
    }

    /// 사전 증거가 그 단어를 담지 않으면 매시 보호가 그대로 유지된다.
    /// (자산은 있으나 `card` 미포함 — 무조건 켜지는 게 아니라 사전 게이트임을 고정)
    func testConsonantMashWithoutMatchingEvidenceIsPreserved() {
        let output = FakeKeyboardOutput()
        let focus = FakeFocusInspector()
        let manager = makeManager(output: output, focus: focus, guardEvidence: ["water"])
        manager.inputSourceKind = .koreanTwoSet
        manager.isAutoCorrectionEnabled = true

        type("card", into: manager)
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))

        XCTAssertTrue(
            output.actions.isEmpty,
            "사전에 없는데도 매시가 교정됐습니다: \(output.actions)"
        )
    }

    /// 사전 자산이 없으면 fail-closed — 매시 구제 전체가 사라지고 오늘과 같이
    /// 보존한다. `asdf`(ㅁㄴㅇㄹ)는 실단어가 아니므로 어차피 보존이지만,
    /// 자산 부재로도 정당한 매시 보호가 흔들리지 않음을 함께 고정한다.
    func testConsonantMashWithoutEvidenceAssetPreserves() {
        let output = FakeKeyboardOutput()
        let focus = FakeFocusInspector()
        let manager = makeManager(output: output, focus: focus, guardEvidence: nil)
        manager.inputSourceKind = .koreanTwoSet
        manager.isAutoCorrectionEnabled = true

        type("card", into: manager)
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))

        XCTAssertTrue(
            output.actions.isEmpty,
            "자산이 없는데 매시 구제가 발동했습니다: \(output.actions)"
        )
    }

    /// 실단어가 아닌 진짜 매시(`asdf`=ㅁㄴㅇㄹ)는 풍부한 사전이 있어도 보존된다.
    func testGenuineMashIsStillPreservedWithEvidence() {
        let output = FakeKeyboardOutput()
        let focus = FakeFocusInspector()
        let manager = makeManager(output: output, focus: focus, guardEvidence: ["card", "water"])
        manager.inputSourceKind = .koreanTwoSet
        manager.isAutoCorrectionEnabled = true

        type("asdf", into: manager)
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))

        XCTAssertTrue(
            output.actions.isEmpty,
            "실단어가 아닌 매시가 교정됐습니다: \(output.actions)"
        )
    }

    // MARK: - Layer 1 어휘 tiebreaker 배선
    //
    // 규칙만으로는 한국어·영어 두 문법을 모두 만족하는 토큰을 가를 수 없어
    // 보존한다. 그 분기에서만 사전을 참조해 한쪽만 실단어면 그쪽으로 확정한다.
    // 아래 테스트가 그 경로가 실제로 이벤트 탭 흐름을 타는지 고정한다.

    /// 사전이 규칙의 보존 판정을 뒤집어 실제 교체까지 이어져야 한다.
    /// `sork`는 한글로 `내가`인데 영어로는 아무 뜻이 없다.
    func testLexicalTiebreakerCorrectsAmbiguousTokenEndToEnd() throws {
        let output = FakeKeyboardOutput()
        let manager = makeManager(output: output, lexicalTiebreaker: try makeLexicalTiebreaker())
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true

        type("sork", into: manager)
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))

        XCTAssertEqual(output.actions, [
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .text("내가"),
            .key(0x31, false),
        ])
    }

    /// 영어로도 실제 단어면 보존해야 한다. 여기서 교정하면 영어를 치던
    /// 사용자의 입력을 뒤집는 오변환이 된다.
    func testLexicalTiebreakerLeavesGenuineEnglishUntouched() throws {
        let output = FakeKeyboardOutput()
        let manager = makeManager(output: output, lexicalTiebreaker: try makeLexicalTiebreaker())
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true

        type("work", into: manager)
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))

        XCTAssertTrue(output.actions.isEmpty, "실제 영어 단어를 교정했습니다")
    }

    /// 사전 자산이 없으면 이 계층 없이 오늘과 동일하게 동작해야 한다.
    func testLexicalTiebreakerAbsentKeepsRulePreservation() {
        let output = FakeKeyboardOutput()
        let manager = makeManager(output: output, lexicalTiebreaker: nil)
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true

        type("sork", into: manager)
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))

        XCTAssertTrue(output.actions.isEmpty)
    }

    /// 키열 사본이 백스페이스에서도 엔진과 어긋나지 않아야 한다.
    /// 어긋나면 검증에서 걸려 교정이 조용히 사라진다.
    func testLexicalMirrorSurvivesBackspace() throws {
        let output = FakeKeyboardOutput()
        let manager = makeManager(output: output, lexicalTiebreaker: try makeLexicalTiebreaker())
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true

        // 오타를 한 글자 더 친 뒤 지우고 경계를 낸다.
        type("sorkk", into: manager)
        _ = manager.handleKeyDown(keyDown(0x33))
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))

        XCTAssertTrue(
            output.actions.contains(.text("내가")),
            "백스페이스 뒤 사본이 어긋나 교정이 사라졌습니다: \(output.actions)"
        )
    }

    func testScreenshotExampleDkwnReplacesWithAju() {
        let output = FakeKeyboardOutput()
        let manager = makeManager(output: output)
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true

        type("dkwn", into: manager)
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))
        XCTAssertTrue(output.actions.isEmpty)
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))

        XCTAssertEqual(output.actions, [
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .text("아주"),
            .key(0x31, false),
        ])
    }

    func testShortRuleDerivedCorrectionsReachThePostBoundaryFlow() {
        let examples: [(
            physical: String,
            source: InputSourceKind,
            replacement: String,
            originalCharacterCount: Int,
            direction: CorrectionDirection
        )] = [
            ("anjwl", .supportedLatin, "뭐지", 5, .latinToKorean),
            ("no", .koreanTwoSet, "no", 2, .koreanToLatin),
        ]

        for example in examples {
            let output = FakeKeyboardOutput()
            let manager = makeManager(output: output)
            manager.inputSourceKind = example.source
            manager.isAutoCorrectionEnabled = true
            var switchedDirections: [CorrectionDirection] = []
            manager.onInputSourceSwitch = { direction in
                switchedDirections.append(direction)
                return nil
            }

            type(example.physical, into: manager)
            XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))
            XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))

            var expected = Array(
                repeating: FakeKeyboardOutput.Action.key(0x33, false),
                count: example.originalCharacterCount + 1
            )
            expected.append(.text(example.replacement))
            expected.append(.key(0x31, false))
            XCTAssertEqual(output.actions, expected, example.physical)
            XCTAssertEqual(switchedDirections, [example.direction], example.physical)
        }
    }

    func testQuestionMarkBoundaryPreservesShift() {
        let output = FakeKeyboardOutput()
        let manager = makeManager(output: output)
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true

        type("dksehlsmsrjsep", into: manager)
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x2C, shift: true)))
        XCTAssertTrue(output.actions.isEmpty)
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x2C)))

        XCTAssertEqual(Array(output.actions.suffix(2)), [
            .text("안되는건데"),
            .key(0x2C, true),
        ])
    }

    func testImmediateBoundariesPreserveTheirPhysicalModifier() {
        let boundaries: [(UInt16, Bool)] = [
            (0x31, false), // Space
            (0x31, true),  // Shift+Space도 Space 경계
            (0x2B, false), // ,
            (0x2C, true),  // ?
            (0x12, true),  // !
        ]

        for (keycode, shift) in boundaries {
            let output = FakeKeyboardOutput()
            let manager = makeManager(output: output)
            manager.inputSourceKind = .supportedLatin
            manager.isAutoCorrectionEnabled = true
            type("gksrmf", into: manager)

            XCTAssertNotNil(manager.handleKeyDown(keyDown(keycode, shift: shift)))
            XCTAssertTrue(output.actions.isEmpty)
            XCTAssertNotNil(manager.handleKeyUp(keyUp(keycode)))
            XCTAssertEqual(output.actions.last, .key(keycode, shift))
        }
    }

    func testOneToThreePeriodsDeferUntilSpaceAndReinjectWholeSequence() {
        for periodCount in 1...3 {
            let output = FakeKeyboardOutput()
            let focus = FakeFocusInspector()
            var scheduledCorrections: [() -> Void] = []
            let manager = makeManager(
                output: output,
                focus: focus,
                scheduleBoundaryCorrection: { scheduledCorrections.append($0) }
            )
            manager.inputSourceKind = .supportedLatin
            manager.isAutoCorrectionEnabled = true
            type("gksrmf", into: manager)

            for _ in 0..<periodCount {
                XCTAssertNotNil(manager.handleKeyDown(keyDown(0x2F)))
                XCTAssertNotNil(manager.handleKeyUp(keyUp(0x2F)))
                XCTAssertTrue(scheduledCorrections.isEmpty)
                XCTAssertTrue(output.actions.isEmpty)
            }

            XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))
            XCTAssertTrue(scheduledCorrections.isEmpty)
            XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))
            XCTAssertEqual(scheduledCorrections.count, 1)
            scheduledCorrections.removeFirst()()

            var expected = Array(
                repeating: FakeKeyboardOutput.Action.key(0x33, false),
                count: 6 + periodCount + 1
            )
            expected.append(.text("한글"))
            expected.append(contentsOf: Array(
                repeating: .key(0x2F, false),
                count: periodCount
            ))
            expected.append(.key(0x31, false))
            XCTAssertEqual(output.actions, expected)
            XCTAssertEqual(focus.currentFocusOffsets, [6 + periodCount + 1])
        }
    }

    func testPeriodsCanBeFinalizedByEveryImmediateBoundary() {
        let finalBoundaries: [(UInt16, Bool)] = [
            (0x31, false), // Space
            (0x2B, false), // ,
            (0x2C, true),  // ?
            (0x12, true),  // !
        ]

        for (triggerKeycode, triggerShift) in finalBoundaries {
            let output = FakeKeyboardOutput()
            let focus = FakeFocusInspector()
            let manager = makeManager(output: output, focus: focus)
            manager.inputSourceKind = .supportedLatin
            manager.isAutoCorrectionEnabled = true
            type("gksrmf", into: manager)

            XCTAssertNotNil(manager.handleKeyDown(keyDown(0x2F)))
            XCTAssertNotNil(manager.handleKeyUp(keyUp(0x2F)))
            XCTAssertTrue(output.actions.isEmpty)
            XCTAssertNotNil(manager.handleKeyDown(keyDown(
                triggerKeycode,
                shift: triggerShift
            )))
            XCTAssertNotNil(manager.handleKeyUp(keyUp(triggerKeycode)))

            var expected = Array(
                repeating: FakeKeyboardOutput.Action.key(0x33, false),
                count: 8
            )
            expected.append(.text("한글"))
            expected.append(.key(0x2F, false))
            expected.append(.key(triggerKeycode, triggerShift))
            XCTAssertEqual(output.actions, expected)
            XCTAssertEqual(focus.currentFocusOffsets, [8])
        }
    }

    func testKoreanSourceMultiBoundaryUsesCharacterAndUTF16CountsNotStrokeCount() {
        let output = FakeKeyboardOutput()
        let focus = FakeFocusInspector()
        let manager = makeManager(output: output, focus: focus)
        manager.inputSourceKind = .koreanTwoSet
        manager.isAutoCorrectionEnabled = true
        type("hello", into: manager)
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x2F)))
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x2F)))
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x2F)))
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x2F)))
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))

        // `hello`의 한글 원문은 5 strokes가 4 Characters/UTF-16 units로
        // 표시됩니다. 삭제와 caret 검증은 물리 stroke 수를 사용하면 안 됩니다.
        XCTAssertEqual(output.actions, [
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .text("hello"),
            .key(0x2F, false),
            .key(0x2F, false),
            .key(0x31, false),
        ])
        XCTAssertEqual(focus.currentFocusOffsets, [7])
    }

    func testFourthPeriodDiscardsWholeRunAtFollowingSpace() {
        let output = FakeKeyboardOutput()
        let focus = FakeFocusInspector()
        let manager = makeManager(output: output, focus: focus)
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true
        type("gksrmf", into: manager)

        for _ in 0..<4 {
            XCTAssertNotNil(manager.handleKeyDown(keyDown(0x2F)))
            XCTAssertNotNil(manager.handleKeyUp(keyUp(0x2F)))
        }
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))

        XCTAssertTrue(output.actions.isEmpty)
        XCTAssertTrue(focus.currentFocusOffsets.isEmpty)
    }

    func testLetterDigitAndInternalSymbolsAfterPeriodDiscardWholeRun() {
        let internalCharacters: [(UInt16, Bool, String)] = [
            (Self.keycodes["c"]!, false, "letter"),
            (0x12, false, "digit"),
            (0x1B, true, "underscore"),
            (0x2C, false, "slash"),
            (0x13, true, "at sign"),
        ]

        for (keycode, shift, label) in internalCharacters {
            let output = FakeKeyboardOutput()
            let focus = FakeFocusInspector()
            let manager = makeManager(output: output, focus: focus)
            manager.inputSourceKind = .supportedLatin
            manager.isAutoCorrectionEnabled = true
            type("gksrmf", into: manager)
            XCTAssertNotNil(manager.handleKeyDown(keyDown(0x2F)))
            XCTAssertNotNil(manager.handleKeyUp(keyUp(0x2F)))

            XCTAssertNotNil(manager.handleKeyDown(keyDown(keycode, shift: shift)))
            XCTAssertNotNil(manager.handleKeyUp(keyUp(keycode)))
            XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))
            XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))

            XCTAssertTrue(output.actions.isEmpty, label)
            XCTAssertTrue(focus.currentFocusOffsets.isEmpty, label)
        }
    }

    func testBackspacePopsOnlyOneBufferedPeriodBeforeEvaluation() {
        let output = FakeKeyboardOutput()
        let focus = FakeFocusInspector()
        let manager = makeManager(output: output, focus: focus)
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true
        type("gksrmf", into: manager)
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x2F)))
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x2F)))

        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x33)))
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))

        var expected = Array(
            repeating: FakeKeyboardOutput.Action.key(0x33, false),
            count: 8
        )
        expected.append(.text("한글"))
        expected.append(.key(0x2F, false))
        expected.append(.key(0x31, false))
        XCTAssertEqual(output.actions, expected)
        XCTAssertEqual(focus.currentFocusOffsets, [8])
    }

    func testBackspaceRemovesLetterStrokeAfterAllPeriodsArePopped() {
        let output = FakeKeyboardOutput()
        let manager = makeManager(output: output)
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true
        type("gksrmf", into: manager)
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x2F)))

        // 첫 Backspace는 period, 둘째는 마지막 `f` stroke를 제거합니다.
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x33)))
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x33)))
        type("f", into: manager)
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))

        XCTAssertEqual(output.actions, [
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .text("한글"),
            .key(0x31, false),
        ])
    }

    func testEnterAndTabCorrectBeforeTheKeyReachesTheApp() {
        // 제출 키는 앱에 먼저 전달하면 안 됩니다. 메시지가 이미 전송된 뒤에는
        // 지우고 다시 쓸 수 없기 때문입니다. 따라서 교정할 것이 있으면 키를
        // 붙잡고, 교정한 다음 그 키를 주입합니다.
        for submitKeycode: UInt16 in [0x24, 0x4C, 0x30] {
            let output = FakeKeyboardOutput()
            let focus = FakeFocusInspector()
            let manager = makeManager(output: output, focus: focus)
            manager.inputSourceKind = .supportedLatin
            manager.isAutoCorrectionEnabled = true
            type("gksrmf", into: manager)

            XCTAssertNil(
                manager.handleKeyDown(keyDown(submitKeycode)),
                "교정이 있으면 제출 키를 붙잡아야 합니다"
            )

            var expected = Array(
                repeating: FakeKeyboardOutput.Action.key(0x33, false),
                count: 6
            )
            expected.append(.text("한글"))
            expected.append(.key(submitKeycode, false))
            XCTAssertEqual(output.actions, expected, "keycode \(submitKeycode)")

            // 커서는 원문 끝(경계 문자 없음)에서 확인해야 합니다.
            XCTAssertEqual(focus.currentFocusOffsets, [6])
        }
    }

    func testSubmitCorrectionDoesNotUseTheDelayedPostBoundaryScheduler() {
        // Space 계열의 20ms 정착 scheduler를 제출 키에도 사용하면, 그 사이
        // 다음 물리 키가 Enter를 추월할 수 있습니다. 제출 교정은 keyDown
        // 처리 안에서 끝나야 합니다.
        let output = FakeKeyboardOutput()
        var scheduledCorrections: [() -> Void] = []
        let manager = makeManager(
            output: output,
            scheduleBoundaryCorrection: { scheduledCorrections.append($0) }
        )
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true
        type("gksrmf", into: manager)

        XCTAssertNil(manager.handleKeyDown(keyDown(0x24)))
        XCTAssertTrue(scheduledCorrections.isEmpty)
        XCTAssertEqual(Array(output.actions.suffix(2)), [
            .text("한글"),
            .key(0x24, false),
        ])
    }

    func testSubmitCorrectionReanchorsWhenInitialCaretAnchorIsStale() {
        let output = FakeKeyboardOutput()
        let focus = FakeFocusInspector()
        focus.currentFocusMatches = false
        focus.caretTextMatches = true
        let manager = makeManager(output: output, focus: focus)
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true

        type("dkwn", into: manager)
        XCTAssertNil(manager.handleKeyDown(keyDown(0x24)))

        XCTAssertTrue(output.actions.contains(.text("아주")))
        XCTAssertEqual(focus.currentFocusOffsets, [4])
        XCTAssertEqual(focus.caretTextCheckOriginals, ["dkwn"])
        XCTAssertEqual(focus.caretTextBoundaryOffsets, [0])
        XCTAssertTrue(focus.didReanchorFocusToken)
    }

    func testSubmitRequiresExactOriginalEvenWhenCaretOffsetMatches() {
        let output = FakeKeyboardOutput()
        let focus = FakeFocusInspector()
        focus.anchoredTextMatches = false
        let manager = makeManager(output: output, focus: focus)
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true

        type("gksrmf", into: manager)
        XCTAssertNil(manager.handleKeyDown(keyDown(0x24)))

        XCTAssertEqual(output.actions, [.key(0x24, false)])
        XCTAssertEqual(focus.currentFocusOffsets, [6])
    }

    func testShiftReturnCorrectsThenPreservesShiftOnReinjection() {
        let output = FakeKeyboardOutput()
        let manager = makeManager(output: output)
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true

        type("gksrmf", into: manager)
        XCTAssertNil(manager.handleKeyDown(keyDown(0x24, shift: true)))

        XCTAssertEqual(Array(output.actions.suffix(2)), [
            .text("한글"),
            .key(0x24, true),
        ])
    }

    func testLongSubmitCandidatePassesThroughWithoutBlockingTheEventTap() {
        let output = FakeKeyboardOutput()
        let manager = makeManager(output: output)
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true

        type("dksehlsmsrjsep", into: manager)
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x24)))
        XCTAssertTrue(output.actions.isEmpty)
    }

    func testSubmitCorrectionDeliversOnlySubmitWhenValidationBudgetExpires() {
        let output = FakeKeyboardOutput()
        let focus = FakeFocusInspector()
        focus.currentFocusMatches = false
        focus.caretTextMatches = true
        var uptime: TimeInterval = 0
        focus.onReanchorRequest = { uptime = 0.101 }
        let manager = makeManager(
            output: output,
            focus: focus,
            monotonicNow: { uptime }
        )
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true

        type("dkwn", into: manager)
        XCTAssertNil(manager.handleKeyDown(keyDown(0x24)))

        // 검증이 늦어져도 원문은 건드리지 않고 Return은 반드시 전달합니다.
        XCTAssertEqual(output.actions, [.key(0x24, false)])
        XCTAssertFalse(focus.didReanchorFocusToken)
    }

    func testSubmitSkipsExactValidationWhenItsBudgetIsExhausted() {
        let output = FakeKeyboardOutput()
        let focus = FakeFocusInspector()
        var uptimeReads: [TimeInterval] = [0, 0, 0.101]
        let manager = makeManager(
            output: output,
            focus: focus,
            monotonicNow: { uptimeReads.isEmpty ? 0.101 : uptimeReads.removeFirst() }
        )
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true

        type("dkwn", into: manager)
        XCTAssertNil(manager.handleKeyDown(keyDown(0x24)))

        XCTAssertEqual(output.actions, [.key(0x24, false)])
        XCTAssertTrue(focus.currentFocusOffsets.isEmpty)
        XCTAssertTrue(focus.caretTextCheckOriginals.isEmpty)
    }

    func testSubmitAfterTrailingPeriodsPreservesTheWholeBoundarySequence() {
        for submitKeycode: UInt16 in [0x24, 0x4C, 0x30] {
            for periodCount in 1...3 {
                let output = FakeKeyboardOutput()
                let focus = FakeFocusInspector()
                let manager = makeManager(output: output, focus: focus)
                manager.inputSourceKind = .supportedLatin
                manager.isAutoCorrectionEnabled = true
                type("gksrmf", into: manager)

                for _ in 0..<periodCount {
                    XCTAssertNotNil(manager.handleKeyDown(keyDown(0x2F)))
                    XCTAssertNotNil(manager.handleKeyUp(keyUp(0x2F)))
                }
                XCTAssertTrue(output.actions.isEmpty)

                XCTAssertNil(manager.handleKeyDown(keyDown(submitKeycode)))

                var expected = Array(
                    repeating: FakeKeyboardOutput.Action.key(0x33, false),
                    count: 6 + periodCount
                )
                expected.append(.text("한글"))
                expected.append(contentsOf: Array(
                    repeating: .key(0x2F, false),
                    count: periodCount
                ))
                expected.append(.key(submitKeycode, false))
                XCTAssertEqual(output.actions, expected)
                XCTAssertEqual(focus.currentFocusOffsets, [6 + periodCount])
            }
        }
    }

    func testSubmitKeyIsAlwaysDeliveredEvenWhenTheCorrectionIsAbandoned() {
        // 포커스가 어긋나 교정을 포기하더라도 사용자의 Enter 를 삼키면 안 됩니다.
        let output = FakeKeyboardOutput()
        let focus = FakeFocusInspector()
        focus.currentFocusMatches = false
        let manager = makeManager(output: output, focus: focus)
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true
        type("gksrmf", into: manager)

        XCTAssertNil(manager.handleKeyDown(keyDown(0x24)))
        XCTAssertEqual(
            output.actions,
            [.key(0x24, false)],
            "교정 없이 Enter만 주입되어야 합니다"
        )
    }

    func testSubmitKeyPassesThroughUntouchedWhenThereIsNothingToCorrect() {
        // 가장 흔한 경로. 교정 후보가 없으면 키를 붙잡지 않아 기존 동작과 같습니다.
        for submitKeycode: UInt16 in [0x24, 0x4C, 0x30] {
            let output = FakeKeyboardOutput()
            let manager = makeManager(output: output)
            manager.inputSourceKind = .supportedLatin
            manager.isAutoCorrectionEnabled = true
            type("hello", into: manager)  // 중의적이라 교정하지 않음

            XCTAssertNotNil(manager.handleKeyDown(keyDown(submitKeycode)))
            XCTAssertNotNil(manager.handleKeyUp(keyUp(submitKeycode)))
            XCTAssertTrue(output.actions.isEmpty, "keycode \(submitKeycode)")
        }
    }

    func testShiftTabIsNeverTreatedAsASubmitBoundary() {
        // Shift+Tab 은 역방향 포커스 이동이라 교정 경계로 쓰지 않습니다.
        let output = FakeKeyboardOutput()
        let manager = makeManager(output: output)
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true
        type("gksrmf", into: manager)

        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x30, shift: true)))
        XCTAssertTrue(output.actions.isEmpty)
    }

    func testTokenCollectionResumesAfterASubmitBoundary() {
        let output = FakeKeyboardOutput()
        let manager = makeManager(output: output)
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true
        type("gksrmf", into: manager)
        let submit = keyDown(0x24)
        XCTAssertNil(manager.handleKeyDown(submit))
        manager.noteSuppressedKeyDown(submit)
        XCTAssertNil(manager.handleKeyUp(keyUp(0x24)))

        type("gksrmf", into: manager)
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))
        XCTAssertEqual(output.actions.last, .key(0x31, false))
    }

    func testEnterAndTabResetDiscardStateWithoutCorrectionOrReplay() {
        for commitKeycode: UInt16 in [0x24, 0x30] {
            let output = FakeKeyboardOutput()
            let manager = makeManager(output: output)
            manager.inputSourceKind = .supportedLatin
            manager.isAutoCorrectionEnabled = true
            type("gksrmf", into: manager)
            XCTAssertNotNil(manager.handleKeyDown(keyDown(0x2F)))
            XCTAssertNotNil(manager.handleKeyDown(keyDown(Self.keycodes["c"]!)))

            XCTAssertNotNil(manager.handleKeyDown(keyDown(commitKeycode)))
            XCTAssertNotNil(manager.handleKeyUp(keyUp(commitKeycode)))
            XCTAssertTrue(output.actions.isEmpty)

            type("gksrmf", into: manager)
            XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))
            XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))
            XCTAssertEqual(output.actions.last, .key(0x31, false))
        }
    }

    func testMultiBoundaryUndoUsesSameSequenceAndUTF16CaretOffset() {
        let output = FakeKeyboardOutput()
        let focus = FakeFocusInspector()
        let manager = makeManager(output: output, focus: focus)
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true
        type("gksrmf", into: manager)
        for _ in 0..<3 {
            XCTAssertNotNil(manager.handleKeyDown(keyDown(0x2F)))
            XCTAssertNotNil(manager.handleKeyUp(keyUp(0x2F)))
        }
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x2C, shift: true)))
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x2C)))
        XCTAssertEqual(focus.currentFocusOffsets, [10])

        output.actions.removeAll()
        focus.currentFocusOffsets.removeAll()
        XCTAssertNil(manager.handleKeyDown(keyDown(0x06, flags: .maskCommand)))

        XCTAssertEqual(output.actions, [
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .text("gksrmf"),
            .key(0x2F, false),
            .key(0x2F, false),
            .key(0x2F, false),
            .key(0x2C, true),
        ])
        XCTAssertEqual(focus.currentFocusOffsets, [6])
    }

    func testMultiBoundaryCaretMismatchPreservesEverything() {
        let output = FakeKeyboardOutput()
        let focus = FakeFocusInspector()
        focus.currentFocusMatches = false
        let manager = makeManager(output: output, focus: focus)
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true
        type("gksrmf", into: manager)
        for _ in 0..<3 {
            XCTAssertNotNil(manager.handleKeyDown(keyDown(0x2F)))
        }
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))

        XCTAssertTrue(output.actions.isEmpty)
        XCTAssertEqual(focus.currentFocusOffsets, [10, 10, 10])
    }

    func testUnsafeFieldNeverRecordsInjectsOrSwitches() {
        let output = FakeKeyboardOutput()
        let focus = FakeFocusInspector()
        focus.tokenAvailable = false
        let manager = makeManager(output: output, focus: focus)
        manager.inputSourceKind = .koreanTwoSet
        manager.isAutoCorrectionEnabled = true

        var switchCount = 0
        manager.onInputSourceSwitch = { _ in
            switchCount += 1
            return nil
        }

        for character in "excuse" {
            let event = keyDown(try! XCTUnwrap(Self.keycodes[character]))
            XCTAssertNotNil(manager.handleKeyDown(event))
        }
        let boundary = keyDown(0x2C, shift: true)
        XCTAssertNotNil(manager.handleKeyDown(boundary))
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x2C)))

        XCTAssertTrue(output.actions.isEmpty)
        XCTAssertEqual(switchCount, 0)
    }

    func testKoreanBoundaryFocusBecomingUnsafeLeavesNativeTextUntouched() {
        let output = FakeKeyboardOutput()
        let focus = FakeFocusInspector()
        let manager = makeManager(output: output, focus: focus)
        manager.inputSourceKind = .koreanTwoSet
        manager.isAutoCorrectionEnabled = true

        type("hello", into: manager)
        let boundary = keyDown(0x31)
        XCTAssertNotNil(manager.handleKeyDown(boundary))
        focus.tokenAvailable = false
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))

        XCTAssertTrue(output.actions.isEmpty)
        XCTAssertEqual(focus.currentFocusOffsets, [5, 5, 5])
    }

    func testImmediateUndoRestoresPunctuationAndRequestsOriginalSource() throws {
        let output = FakeKeyboardOutput()
        let focus = FakeFocusInspector()
        let manager = makeManager(
            output: output,
            focus: focus,
            monosyllableLexicon: try makeMonosyllableLexicon()
        )
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true
        let receipt = InputSourceSwitchReceipt(
            fromInputSourceID: "com.apple.keylayout.ABC",
            toInputSourceID: InputSourceController.koreanTwoSetInputSourceID,
            selectedSourceGeneration: 2
        )
        manager.onInputSourceSwitch = { _ in receipt }

        type("dho", into: manager)
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x2C, shift: true)))
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x2C)))

        var restoredReceipt: InputSourceSwitchReceipt?
        manager.onInputSourceRestore = {
            restoredReceipt = $0
            return true
        }
        let undo = keyDown(0x06, flags: .maskCommand)
        XCTAssertNil(manager.handleKeyDown(undo))

        XCTAssertEqual(Array(output.actions.suffix(4)), [
            .key(0x33, false),
            .key(0x33, false),
            .text("dho"),
            .key(0x2C, true),
        ])
        XCTAssertEqual(restoredReceipt, receipt)
    }

    func testLatinGksrmfSpacePassesPhysicalBoundaryAndCorrectsOnKeyUp() {
        let output = FakeKeyboardOutput()
        let focus = FakeFocusInspector()
        let manager = makeManager(output: output, focus: focus)
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true

        type("gksrmf", into: manager)
        let boundary = keyDown(0x31)
        XCTAssertNotNil(manager.handleKeyDown(boundary))
        XCTAssertTrue(output.actions.isEmpty)
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))
        XCTAssertEqual(output.actions, [
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .text("한글"),
            .key(0x31, false),
        ])
        XCTAssertEqual(focus.currentFocusOffsets, [7])

        // The physical boundary was never suppressed, so a stray duplicate
        // keyUp also passes and cannot repeat the already-consumed correction.
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))
        XCTAssertEqual(output.actions.count, 9)
    }

    func testMatchingBoundaryKeyUpSchedulesCorrectionBeforeProducingOutput() {
        let output = FakeKeyboardOutput()
        let focus = FakeFocusInspector()
        var scheduledCorrections: [() -> Void] = []
        let manager = makeManager(
            output: output,
            focus: focus,
            scheduleBoundaryCorrection: { scheduledCorrections.append($0) }
        )
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true

        type("gksrmf", into: manager)
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))

        XCTAssertTrue(output.actions.isEmpty)
        XCTAssertTrue(focus.currentFocusOffsets.isEmpty)
        XCTAssertEqual(scheduledCorrections.count, 1)

        scheduledCorrections.removeFirst()()

        XCTAssertEqual(output.actions, [
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .text("한글"),
            .key(0x31, false),
        ])
        XCTAssertEqual(focus.currentFocusOffsets, [7])
    }

    func testShortLatinCorrectionConsumesBoundaryBeforeKeyRolloverCanCancel() {
        let output = FakeKeyboardOutput()
        let focus = FakeFocusInspector()
        // 초반에 캡처한 앵커는 낡았지만, 현재 같은 입력란의 exact
        // text는 올바른 실제 사례를 고정합니다.
        focus.currentFocusMatches = false
        focus.caretTextMatches = true
        var scheduledCorrections: [() -> Void] = []
        let manager = makeManager(
            output: output,
            focus: focus,
            scheduleBoundaryCorrection: { scheduledCorrections.append($0) }
        )
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true
        var switchedDirections: [CorrectionDirection] = []
        manager.onInputSourceSwitch = { direction in
            switchedDirections.append(direction)
            return nil
        }

        type("dkwn", into: manager)
        // 빠른 타이핑의 정상 키 롤오버: Space keyUp보다 다음 글자 keyDown이
        // 먼저 옵니다. 물리 Space를 억제하고 교정+합성 Space를 한 묶음으로
        // 끝내면 다음 글자가 예약을 취소할 수 없습니다.
        let boundary = keyDown(0x31)
        XCTAssertNil(manager.handleKeyDown(boundary))
        manager.noteSuppressedKeyDown(boundary)
        XCTAssertNotNil(manager.handleKeyDown(keyDown(Self.keycodes["g"]!)))
        XCTAssertNil(manager.handleKeyUp(keyUp(0x31)))

        XCTAssertEqual(output.actions, [
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .text("아주"),
            .key(0x31, false),
        ])
        XCTAssertTrue(focus.currentFocusOffsets.isEmpty)
        XCTAssertEqual(focus.caretTextCheckOriginals, ["dkwn"])
        XCTAssertEqual(focus.caretTextBoundaryOffsets, [0])
        XCTAssertEqual(switchedDirections, [.latinToKorean])
        XCTAssertTrue(scheduledCorrections.isEmpty)
    }

    func testShortLatinCorrectionHasNoPostKeyUpSchedulingWindow() {
        let output = FakeKeyboardOutput()
        let focus = FakeFocusInspector()
        focus.caretTextMatches = true
        var scheduledCorrections: [() -> Void] = []
        let manager = makeManager(
            output: output,
            focus: focus,
            scheduleBoundaryCorrection: { scheduledCorrections.append($0) }
        )
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true

        type("dkwn", into: manager)
        let boundary = keyDown(0x31)
        XCTAssertNil(manager.handleKeyDown(boundary))
        manager.noteSuppressedKeyDown(boundary)
        XCTAssertNil(manager.handleKeyUp(keyUp(0x31)))
        let completedCorrection = output.actions

        // 기존에는 이 keyDown이 keyUp 뒤 20ms 예약을 취소했습니다.
        XCTAssertNotNil(manager.handleKeyDown(keyDown(Self.keycodes["g"]!)))

        XCTAssertEqual(output.actions, completedCorrection)
        XCTAssertTrue(output.actions.contains(.text("아주")))
        XCTAssertTrue(scheduledCorrections.isEmpty)
    }

    func testPreBoundaryCorrectionFallsBackBeforeMutatingWhenTimeBudgetExpires() {
        let output = FakeKeyboardOutput()
        let focus = FakeFocusInspector()
        focus.caretTextMatches = true
        var uptime: TimeInterval = 0
        // 대역이 토큰을 돌려준 직후 예산이 끝나는 경계도 첫 Backspace
        // 직전의 최종 guard가 잡아야 합니다.
        focus.onReanchorReturn = { uptime = 0.101 }
        var scheduledCorrections: [() -> Void] = []
        let manager = makeManager(
            output: output,
            focus: focus,
            monotonicNow: { uptime },
            scheduleBoundaryCorrection: { scheduledCorrections.append($0) }
        )
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true

        type("dkwn", into: manager)
        // exact-range 검증이 예산을 넘기면 물리 Space를 통과시키고, 아직
        // 어떤 삭제도 하지 않은 상태로 기존 keyUp 이후 경로에 맡깁니다.
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))

        XCTAssertTrue(output.actions.isEmpty)
        XCTAssertEqual(focus.caretTextCheckOriginals, ["dkwn"])
        XCTAssertTrue(focus.didReanchorFocusToken)
        XCTAssertTrue(scheduledCorrections.isEmpty)
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))
        XCTAssertEqual(scheduledCorrections.count, 1)
        XCTAssertTrue(output.actions.isEmpty)
    }

    func testDirectionEvidenceSkipsOnlyBoundariesAlreadyOnScreen() {
        let output = FakeKeyboardOutput()
        let focus = FakeFocusInspector()
        focus.observedDirection = .latinToKorean
        focus.caretTextMatches = true
        let manager = makeManager(output: output, focus: focus)
        // 시스템은 한글로 알지만 화면에는 Latin이 찍힌 상태를 재현합니다.
        manager.inputSourceKind = .koreanTwoSet
        manager.isAutoCorrectionEnabled = true

        type("dkwn", into: manager)
        let boundary = keyDown(0x31)
        XCTAssertNil(manager.handleKeyDown(boundary))
        manager.noteSuppressedKeyDown(boundary)

        // 현재 Space는 callback 반환 전이라 화면에 없으므로 0이어야 합니다.
        XCTAssertEqual(focus.scriptBoundaryOffsets, [0])
        XCTAssertTrue(output.actions.contains(.text("아주")))
        XCTAssertNil(manager.handleKeyUp(keyUp(0x31)))
    }

    func testDirectionEvidenceStillUsesLexicalTiebreaker() throws {
        let output = FakeKeyboardOutput()
        let focus = FakeFocusInspector()
        focus.observedDirection = .latinToKorean
        focus.caretTextMatches = true
        let manager = makeManager(
            output: output,
            focus: focus,
            lexicalTiebreaker: try makeLexicalTiebreaker()
        )
        // TIS는 한글이지만 대상 앱 화면에는 Latin이 찍힌 상태입니다.
        manager.inputSourceKind = .koreanTwoSet
        manager.isAutoCorrectionEnabled = true

        type("sork", into: manager)
        let boundary = keyDown(0x31)
        XCTAssertNil(manager.handleKeyDown(boundary))
        manager.noteSuppressedKeyDown(boundary)

        XCTAssertTrue(output.actions.contains(.text("내가")))
        XCTAssertNil(manager.handleKeyUp(keyUp(0x31)))
    }

    func testExpiredDirectionProbeKeepsDecisionForDeferredFallback() {
        let output = FakeKeyboardOutput()
        let focus = FakeFocusInspector()
        focus.observedDirection = .latinToKorean
        var uptime: TimeInterval = 0
        focus.onScriptRequest = { uptime = 0.101 }
        var scheduledCorrections: [() -> Void] = []
        let manager = makeManager(
            output: output,
            focus: focus,
            monotonicNow: { uptime },
            scheduleBoundaryCorrection: { scheduledCorrections.append($0) }
        )
        manager.inputSourceKind = .koreanTwoSet
        manager.isAutoCorrectionEnabled = true

        type("dkwn", into: manager)
        // 화면 방향 증거는 끝까지 보존하되, 시간이 끝났으므로 keyDown 안에서
        // 지우지 않고 decision을 기존 keyUp 이후 경로로 넘깁니다.
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))
        XCTAssertTrue(output.actions.isEmpty)
        XCTAssertEqual(focus.scriptBoundaryOffsets, [0])
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))
        XCTAssertEqual(scheduledCorrections.count, 1)
    }

    func testDirectionEvidenceAccountsForTrailingPeriodButNotCurrentSpace() {
        let output = FakeKeyboardOutput()
        let focus = FakeFocusInspector()
        focus.observedDirection = .latinToKorean
        let manager = makeManager(output: output, focus: focus)
        manager.inputSourceKind = .koreanTwoSet
        manager.isAutoCorrectionEnabled = true

        type("dkwn", into: manager)
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x2F)))
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))

        // period는 이미 통과했고 Space는 아직이므로 1만 넘깁니다.
        XCTAssertEqual(focus.scriptBoundaryOffsets, [1])
    }

    func testSubmitDirectionEvidenceAccountsForTrailingPeriod() {
        let output = FakeKeyboardOutput()
        let focus = FakeFocusInspector()
        focus.observedDirection = .latinToKorean
        let manager = makeManager(output: output, focus: focus)
        // 시스템은 한글로 알지만 화면에는 Latin이 찍힌 상태를 재현합니다.
        manager.inputSourceKind = .koreanTwoSet
        manager.isAutoCorrectionEnabled = true

        type("dkwn", into: manager)
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x2F)))
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x2F)))
        XCTAssertNil(manager.handleKeyDown(keyDown(0x24)))

        // period는 이미 통과했고 Return은 아직이므로 1만 넘깁니다.
        XCTAssertEqual(focus.scriptBoundaryOffsets, [1])
        XCTAssertEqual(output.actions, [
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .text("아주"),
            .key(0x2F, false),
            .key(0x24, false),
        ])
    }

    func testPreBoundaryQuestionMarkPreservesShiftAndSuppressesPhysicalPair() throws {
        let output = FakeKeyboardOutput()
        let focus = FakeFocusInspector()
        focus.caretTextMatches = true
        var scheduledCorrections: [() -> Void] = []
        let manager = makeManager(
            output: output,
            focus: focus,
            scheduleBoundaryCorrection: { scheduledCorrections.append($0) },
            monosyllableLexicon: try makeMonosyllableLexicon()
        )
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true

        type("dho", into: manager)
        let boundary = keyDown(0x2C, shift: true)
        XCTAssertNil(manager.handleKeyDown(boundary))
        manager.noteSuppressedKeyDown(boundary)

        XCTAssertEqual(output.actions, [
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .text("왜"),
            .key(0x2C, true),
        ])
        XCTAssertNil(manager.handleKeyUp(keyUp(0x2C)))
        XCTAssertTrue(scheduledCorrections.isEmpty)
    }

    func testConsumedBoundaryAutorepeatCannotDuplicateSyntheticBoundary() {
        let output = FakeKeyboardOutput()
        let focus = FakeFocusInspector()
        focus.caretTextMatches = true
        let manager = makeManager(output: output, focus: focus)
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true

        type("dkwn", into: manager)
        let boundary = keyDown(0x31)
        XCTAssertNil(manager.handleKeyDown(boundary))
        manager.noteSuppressedKeyDown(boundary)
        let completedCorrection = output.actions

        let repeatedBoundary = keyDown(0x31, autorepeat: true)
        XCTAssertNil(manager.handleKeyDown(repeatedBoundary))
        manager.noteSuppressedKeyDown(repeatedBoundary)

        XCTAssertEqual(output.actions, completedCorrection)
        XCTAssertEqual(output.actions.filter { $0 == .key(0x31, false) }.count, 1)
        XCTAssertNil(manager.handleKeyUp(keyUp(0x31)))
    }

    func testPreBoundaryFastPathFallsBackWhenExactTextCannotBeConfirmed() {
        let output = FakeKeyboardOutput()
        let focus = FakeFocusInspector()
        var scheduledCorrections: [() -> Void] = []
        let manager = makeManager(
            output: output,
            focus: focus,
            scheduleBoundaryCorrection: { scheduledCorrections.append($0) }
        )
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true

        type("dkwn", into: manager)
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))
        XCTAssertTrue(output.actions.isEmpty)
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))
        XCTAssertEqual(scheduledCorrections.count, 1)

        scheduledCorrections.removeFirst()()

        XCTAssertEqual(output.actions, [
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .text("아주"),
            .key(0x31, false),
        ])
        XCTAssertEqual(focus.currentFocusOffsets, [5])
        XCTAssertEqual(focus.caretTextCheckOriginals, ["dkwn"])
        XCTAssertEqual(focus.caretTextBoundaryOffsets, [0])
    }

    func testPreBoundaryFastPathKeepsLongTokensOnDeferredPath() {
        let output = FakeKeyboardOutput()
        let focus = FakeFocusInspector()
        focus.caretTextMatches = true
        var scheduledCorrections: [() -> Void] = []
        let manager = makeManager(
            output: output,
            focus: focus,
            scheduleBoundaryCorrection: { scheduledCorrections.append($0) }
        )
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true

        // 13타: 동기 경로 상한(8자)을 넘으므로 이벤트 탭 keyDown 안에서
        // 백스페이스 대기를 수행하지 않습니다.
        type("dksehlsmsrjsep", into: manager)
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))

        XCTAssertTrue(output.actions.isEmpty)
        XCTAssertTrue(focus.currentFocusOffsets.isEmpty)
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))
        XCTAssertEqual(scheduledCorrections.count, 1)
    }

    func testPreBoundaryCorrectionUndoBeforePhysicalKeyUpKeepsKeyPairsBalanced() {
        let output = FakeKeyboardOutput()
        let focus = FakeFocusInspector()
        focus.caretTextMatches = true
        let manager = makeManager(output: output, focus: focus)
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true
        let receipt = InputSourceSwitchReceipt(
            fromInputSourceID: "com.apple.keylayout.ABC",
            toInputSourceID: InputSourceController.koreanTwoSetInputSourceID,
            selectedSourceGeneration: 9
        )
        manager.onInputSourceSwitch = { direction in
            XCTAssertEqual(direction, .latinToKorean)
            // 운영의 AppMonitor처럼 콜백 안에서 동기로 상태를 갱신합니다.
            manager.inputSourceKind = .koreanTwoSet
            manager.isActive = true
            return receipt
        }
        var restoredReceipt: InputSourceSwitchReceipt?
        manager.onInputSourceRestore = {
            restoredReceipt = $0
            return true
        }

        type("dkwn", into: manager)
        let boundary = keyDown(0x31)
        XCTAssertNil(manager.handleKeyDown(boundary))
        manager.noteSuppressedKeyDown(boundary)
        output.actions.removeAll()

        let undo = keyDown(0x06, flags: .maskCommand)
        XCTAssertNil(manager.handleKeyDown(undo))
        manager.noteSuppressedKeyDown(undo)
        XCTAssertEqual(output.actions, [
            .key(0x33, false), // 이미 짝이 맞는 합성 Space를 삭제
            .key(0x33, false),
            .key(0x33, false),
            .text("dkwn"),
            .key(0x31, false),
        ])
        XCTAssertEqual(focus.currentFocusOffsets, [3])
        XCTAssertEqual(restoredReceipt, receipt)
        // 나중에 도착한 원래 Space keyUp은 앱으로 통과하지 않습니다.
        XCTAssertNil(manager.handleKeyUp(keyUp(0x31)))
    }

    func testMouseDownCancelsScheduledBoundaryCorrectionWithoutSideEffects() {
        let output = FakeKeyboardOutput()
        let focus = FakeFocusInspector()
        var scheduledCorrections: [() -> Void] = []
        let manager = makeManager(
            output: output,
            focus: focus,
            scheduleBoundaryCorrection: { scheduledCorrections.append($0) }
        )
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true

        var sourceSwitchCount = 0
        manager.onInputSourceSwitch = { _ in
            sourceSwitchCount += 1
            return nil
        }

        type("gksrmf", into: manager)
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))
        XCTAssertEqual(scheduledCorrections.count, 1)

        focus.currentFocusMatches = false
        scheduledCorrections.removeFirst()()
        XCTAssertEqual(scheduledCorrections.count, 1)
        XCTAssertEqual(focus.currentFocusOffsets, [7])

        manager.handleMouseDown()
        scheduledCorrections.removeFirst()()

        XCTAssertTrue(output.actions.isEmpty)
        XCTAssertEqual(focus.currentFocusOffsets, [7])
        XCTAssertEqual(sourceSwitchCount, 0)
    }

    func testOriginalChoiceRequestUsesPhysicalOriginalAndBoundaryLength() throws {
        let output = FakeKeyboardOutput()
        let manager = makeManager(output: output)
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true
        var request: OriginalChoiceRequest?
        manager.onOriginalChoiceAvailable = { request = $0 }

        type("gksrmf", into: manager)
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x2F)))
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x2F)))
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))

        let unwrapped = try XCTUnwrap(request)
        XCTAssertEqual(unwrapped.original, "gksrmf")
        XCTAssertEqual(unwrapped.replacement, "한글")
        XCTAssertEqual(unwrapped.boundaryUTF16Count, 3)
        XCTAssertTrue(manager.isOriginalChoiceActive(generation: unwrapped.generation))
    }

    func testPrimaryMouseDownInsideChipPreservesOnlyRestoreTransaction() throws {
        let output = FakeKeyboardOutput()
        let manager = makeManager(output: output)
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true
        var request: OriginalChoiceRequest?
        manager.onOriginalChoiceAvailable = { request = $0 }

        type("gksrmf", into: manager)
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))
        let unwrapped = try XCTUnwrap(request)
        XCTAssertTrue(manager.markOriginalChoiceChipVisible(
            generation: unwrapped.generation
        ))
        manager.originalChoiceHitTest = { point, generation in
            point == CGPoint(x: 10, y: 20) && generation == unwrapped.generation
        }
        output.actions.removeAll()

        manager.handleMouseDown(
            at: CGPoint(x: 10, y: 20),
            isPrimaryButton: true
        )
        XCTAssertTrue(manager.restoreOriginalChoice(
            generation: unwrapped.generation
        ))

        XCTAssertEqual(output.actions, [
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .text("gksrmf"),
            .key(0x31, false),
        ])
    }

    func testMouseDownOutsideChipOrNonPrimaryClickCancelsRestore() throws {
        for isPrimaryButton in [true, false] {
            let output = FakeKeyboardOutput()
            let manager = makeManager(output: output)
            manager.inputSourceKind = .supportedLatin
            manager.isAutoCorrectionEnabled = true
            var request: OriginalChoiceRequest?
            manager.onOriginalChoiceAvailable = { request = $0 }

            type("gksrmf", into: manager)
            XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))
            XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))
            let unwrapped = try XCTUnwrap(request)
            XCTAssertTrue(manager.markOriginalChoiceChipVisible(
                generation: unwrapped.generation
            ))
            manager.originalChoiceHitTest = { point, _ in
                point == CGPoint(x: 10, y: 20)
            }
            output.actions.removeAll()

            manager.handleMouseDown(
                at: isPrimaryButton
                    ? CGPoint(x: 99, y: 99)
                    : CGPoint(x: 10, y: 20),
                isPrimaryButton: isPrimaryButton
            )

            XCTAssertFalse(manager.restoreOriginalChoice(
                generation: unwrapped.generation
            ))
            XCTAssertTrue(output.actions.isEmpty)
        }
    }

    func testChipExpirationKeepsOnlyUsableRecoveryPath() throws {
        let output = FakeKeyboardOutput()
        let manager = makeManager(output: output)
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true
        var request: OriginalChoiceRequest?
        manager.onOriginalChoiceAvailable = { request = $0 }

        type("gksrmf", into: manager)
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))
        let unwrapped = try XCTUnwrap(request)
        XCTAssertTrue(manager.markOriginalChoiceChipVisible(
            generation: unwrapped.generation
        ))
        manager.originalChoiceChipDidExpire(generation: unwrapped.generation)
        output.actions.removeAll()

        XCTAssertNil(manager.handleKeyDown(keyDown(0x06, flags: .maskCommand)))
        XCTAssertEqual(output.actions.last, .key(0x31, false))

        let longOutput = FakeKeyboardOutput()
        let longManager = makeManager(output: longOutput)
        longManager.inputSourceKind = .koreanTwoSet
        longManager.isAutoCorrectionEnabled = true
        var longRequest: OriginalChoiceRequest?
        longManager.onOriginalChoiceAvailable = { longRequest = $0 }

        type("semblance", into: longManager)
        XCTAssertNotNil(longManager.handleKeyDown(keyDown(0x31)))
        XCTAssertNotNil(longManager.handleKeyUp(keyUp(0x31)))
        let unwrappedLongRequest = try XCTUnwrap(longRequest)
        XCTAssertTrue(longManager.markOriginalChoiceChipVisible(
            generation: unwrappedLongRequest.generation
        ))

        longManager.originalChoiceChipDidExpire(
            generation: unwrappedLongRequest.generation
        )

        XCTAssertFalse(longManager.isOriginalChoiceActive(
            generation: unwrappedLongRequest.generation
        ))
        XCTAssertFalse(longManager.restoreOriginalChoice(
            generation: unwrappedLongRequest.generation
        ))
    }

    func testInputSourceChangeCancelsScheduledBoundaryCorrectionWithoutSideEffects() {
        let output = FakeKeyboardOutput()
        let focus = FakeFocusInspector()
        var scheduledCorrections: [() -> Void] = []
        let manager = makeManager(
            output: output,
            focus: focus,
            scheduleBoundaryCorrection: { scheduledCorrections.append($0) }
        )
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true

        var sourceSwitchCount = 0
        manager.onInputSourceSwitch = { _ in
            sourceSwitchCount += 1
            return nil
        }

        type("gksrmf", into: manager)
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))
        XCTAssertEqual(scheduledCorrections.count, 1)

        focus.currentFocusMatches = false
        scheduledCorrections.removeFirst()()
        XCTAssertEqual(scheduledCorrections.count, 1)
        XCTAssertEqual(focus.currentFocusOffsets, [7])

        manager.inputSourceKind = .koreanTwoSet
        scheduledCorrections.removeFirst()()

        XCTAssertTrue(output.actions.isEmpty)
        XCTAssertEqual(focus.currentFocusOffsets, [7])
        XCTAssertEqual(sourceSwitchCount, 0)
    }

    func testNumberAndSymbolInvalidateWholeTokenInsteadOfCorrectingSuffix() {
        for invalidKeycode: UInt16 in [0x12, 0x1B] { // 1, hyphen
            let output = FakeKeyboardOutput()
            let manager = makeManager(output: output)
            manager.inputSourceKind = .supportedLatin
            manager.isAutoCorrectionEnabled = true

            type("gks", into: manager)
            XCTAssertNotNil(manager.handleKeyDown(keyDown(invalidKeycode)))
            type("rmf", into: manager)
            XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))
            XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))
            XCTAssertTrue(output.actions.isEmpty)
        }
    }

    func testKoreanAutoOnlyOverflowNeverInterceptsNativeComposition() {
        let output = FakeKeyboardOutput()
        let manager = makeManager(output: output)
        manager.inputSourceKind = .koreanTwoSet
        manager.isAutoCorrectionEnabled = true

        for index in 0..<33 {
            XCTAssertNotNil(
                manager.handleKeyDown(keyDown(Self.keycodes["a"]!)),
                "physical keyDown \(index + 1) must remain native"
            )
        }
        XCTAssertTrue(output.actions.isEmpty)
    }

    func testLatinBoundaryCaretMismatchOnKeyUpFailsClosedWithoutPosting() {
        let output = FakeKeyboardOutput()
        let focus = FakeFocusInspector()
        let manager = makeManager(output: output, focus: focus)
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true

        type("gksrmf", into: manager)
        focus.currentFocusMatches = false
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))
        XCTAssertTrue(output.actions.isEmpty)
        XCTAssertEqual(focus.currentFocusOffsets, [7, 7, 7])
    }

    func testDeferredCorrectionRequiresExactOriginalEvenWhenCaretOffsetMatches() {
        let output = FakeKeyboardOutput()
        let focus = FakeFocusInspector()
        focus.anchoredTextMatches = false
        let manager = makeManager(output: output, focus: focus)
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true

        type("gksrmf", into: manager)
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))

        XCTAssertTrue(output.actions.isEmpty)
        XCTAssertEqual(focus.currentFocusOffsets, [7, 7, 7])
    }

    func testBoundaryFocusRetriesTwiceAndCorrectsExactlyOnceOnThirdMatch() {
        let output = FakeKeyboardOutput()
        let focus = FakeFocusInspector()
        focus.currentFocusMatchResponses = [false, false, true]
        var scheduledCorrections: [() -> Void] = []
        let manager = makeManager(
            output: output,
            focus: focus,
            scheduleBoundaryCorrection: { scheduledCorrections.append($0) }
        )
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true

        var switchedDirections: [CorrectionDirection] = []
        manager.onInputSourceSwitch = { direction in
            switchedDirections.append(direction)
            return nil
        }

        type("gksrmf", into: manager)
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))
        XCTAssertEqual(scheduledCorrections.count, 1)

        for attempt in 1...2 {
            scheduledCorrections.removeFirst()()
            XCTAssertTrue(output.actions.isEmpty)
            XCTAssertTrue(switchedDirections.isEmpty)
            XCTAssertEqual(focus.currentFocusOffsets, Array(repeating: 7, count: attempt))
            XCTAssertEqual(scheduledCorrections.count, 1)
        }

        scheduledCorrections.removeFirst()()

        XCTAssertEqual(output.actions, [
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .text("한글"),
            .key(0x31, false),
        ])
        XCTAssertEqual(focus.currentFocusOffsets, [7, 7, 7])
        XCTAssertEqual(switchedDirections, [.latinToKorean])
        XCTAssertTrue(scheduledCorrections.isEmpty)
    }

    func testFastShiftedLatinDkssudQuestionMarkCorrectsOnlyOnMatchingKeyUp() {
        let output = FakeKeyboardOutput()
        let focus = FakeFocusInspector()
        let manager = makeManager(output: output, focus: focus)
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true

        for (index, character) in "dkssud".enumerated() {
            let keycode = Self.keycodes[character]!
            XCTAssertNotNil(manager.handleKeyDown(keyDown(keycode, shift: index == 0)))
            XCTAssertNotNil(manager.handleKeyUp(keyUp(keycode)))
        }
        XCTAssertTrue(output.actions.isEmpty)

        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x2C, shift: true)))
        XCTAssertTrue(output.actions.isEmpty)

        // An unrelated keyUp must not apply the pending replacement.
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x2F)))
        XCTAssertTrue(output.actions.isEmpty)
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x2C)))

        XCTAssertEqual(output.actions, [
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .text("안녕"),
            .key(0x2C, true),
        ])
        XCTAssertEqual(focus.currentFocusOffsets, [7])
    }

    func testKoreanBoundaryCaretMoveFailsClosedWithoutPosting() {
        let output = FakeKeyboardOutput()
        let focus = FakeFocusInspector()
        let manager = makeManager(output: output, focus: focus)
        manager.inputSourceKind = .koreanTwoSet
        manager.isAutoCorrectionEnabled = true

        type("hello", into: manager)
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))
        focus.currentFocusMatches = false
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))

        XCTAssertTrue(output.actions.isEmpty)
        XCTAssertEqual(focus.currentFocusOffsets, [5, 5, 5])
    }

    func testKoreanAutoOnlyUsesNativeIMEAndCorrectsAfterBoundaryKeyUp() {
        let output = FakeKeyboardOutput()
        let focus = FakeFocusInspector()
        let manager = makeManager(output: output, focus: focus)
        manager.inputSourceKind = .koreanTwoSet
        manager.isAutoCorrectionEnabled = true

        var switchedDirections: [CorrectionDirection] = []
        manager.onInputSourceSwitch = { direction in
            switchedDirections.append(direction)
            return nil
        }

        for character in "hello" {
            XCTAssertNotNil(manager.handleKeyDown(keyDown(Self.keycodes[character]!)))
            XCTAssertNotNil(manager.handleKeyUp(keyUp(Self.keycodes[character]!)))
        }
        XCTAssertTrue(output.actions.isEmpty)

        let boundaryDown = keyDown(0x31)
        XCTAssertNotNil(manager.handleKeyDown(boundaryDown))
        XCTAssertTrue(output.actions.isEmpty)
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))

        XCTAssertEqual(output.actions, [
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .text("hello"),
            .key(0x31, false),
        ])
        XCTAssertEqual(focus.currentFocusOffsets, [5])
        XCTAssertEqual(switchedDirections, [.koreanToLatin])
    }

    func testRuleDerivedKoreanCorrectionsReachThePostBoundaryFlow() {
        let examples: [(
            physical: String,
            original: String,
            originalCharacterCount: Int,
            boundaryKeycode: UInt16,
            boundaryShift: Bool
        )] = [
            ("vocal", "팿미", 2, 0x31, false), // Space
            ("good", "해ㅐㅇ", 3, 0x2C, true), // ?
        ]

        for example in examples {
            let output = FakeKeyboardOutput()
            let focus = FakeFocusInspector()
            // 규칙만으로 결정되므로 사전 근거를 주입하지 않습니다.
            let manager = makeManager(output: output, focus: focus)
            manager.inputSourceKind = .koreanTwoSet
            manager.isAutoCorrectionEnabled = true
            var originalChoiceRequest: OriginalChoiceRequest?
            var switchedDirections: [CorrectionDirection] = []
            manager.onOriginalChoiceAvailable = { originalChoiceRequest = $0 }
            manager.onInputSourceSwitch = { direction in
                switchedDirections.append(direction)
                return nil
            }

            type(example.physical, into: manager)
            XCTAssertNotNil(manager.handleKeyDown(keyDown(
                example.boundaryKeycode,
                shift: example.boundaryShift
            )))
            XCTAssertNotNil(manager.handleKeyUp(keyUp(example.boundaryKeycode)))

            let deleteCount = example.originalCharacterCount + 1
            var expected = Array(
                repeating: FakeKeyboardOutput.Action.key(0x33, false),
                count: deleteCount
            )
            expected.append(.text(example.physical))
            expected.append(.key(example.boundaryKeycode, example.boundaryShift))
            XCTAssertEqual(output.actions, expected, example.physical)
            XCTAssertEqual(focus.currentFocusOffsets, [deleteCount], example.physical)
            XCTAssertEqual(originalChoiceRequest?.original, example.original)
            XCTAssertEqual(originalChoiceRequest?.replacement, example.physical)
            XCTAssertEqual(switchedDirections, [.koreanToLatin])
        }
    }

    func testModernKoreanSourcePreservesWithoutPostBoundaryEffects() {
        // `worn` 은 두벌식으로 `재구` 가 되고, 두 음절 모두 현대 국어 음절이라
        // 한국어로도 완전히 성립한다. 키열만으로는 어느 쪽 의도인지 알 수 없으므로
        // 규칙은 화면을 그대로 둔다 (R-D1).
        let output = FakeKeyboardOutput()
        let manager = makeManager(output: output)
        manager.inputSourceKind = .koreanTwoSet
        manager.isAutoCorrectionEnabled = true
        var originalChoiceRequest: OriginalChoiceRequest?
        var sourceSwitchCount = 0
        manager.onOriginalChoiceAvailable = { originalChoiceRequest = $0 }
        manager.onInputSourceSwitch = { _ in
            sourceSwitchCount += 1
            return nil
        }

        type("worn", into: manager)
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))

        XCTAssertTrue(output.actions.isEmpty)
        XCTAssertNil(originalChoiceRequest)
        XCTAssertEqual(sourceSwitchCount, 0)
    }

    func testKoreanDeferredCorrectionIsCancelledByAnotherKeyDown() {
        let output = FakeKeyboardOutput()
        let manager = makeManager(output: output)
        manager.inputSourceKind = .koreanTwoSet
        manager.isAutoCorrectionEnabled = true

        type("hello", into: manager)
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))
        XCTAssertNotNil(manager.handleKeyDown(keyDown(Self.keycodes["a"]!)))
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))

        XCTAssertTrue(output.actions.isEmpty)
    }

    func testExpiredUndoPassesThroughWithoutPosting() {
        var now = Date(timeIntervalSince1970: 1_000)
        let output = FakeKeyboardOutput()
        let manager = makeManager(output: output, now: { now })
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true
        type("gksrmf", into: manager)
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))
        output.actions.removeAll()

        now = now.addingTimeInterval(7)
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x06, flags: .maskCommand)))
        XCTAssertTrue(output.actions.isEmpty)
    }

    func testLongCorrectionUndoPassesThroughWithoutSynchronousDeletion() {
        let output = FakeKeyboardOutput()
        let focus = FakeFocusInspector()
        let manager = makeManager(output: output, focus: focus)
        manager.inputSourceKind = .koreanTwoSet
        manager.isAutoCorrectionEnabled = true

        // 고정 규칙 코퍼스의 9자 영어 결과입니다. 교정 자체는 keyUp 뒤 지연
        // 경로에서 가능하지만 물리 Cmd-Z callback 안에서 9자를 지우지는 않습니다.
        type("semblance", into: manager)
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))
        XCTAssertTrue(output.actions.contains(.text("semblance")))
        output.actions.removeAll()
        focus.currentFocusOffsets.removeAll()

        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x06, flags: .maskCommand)))
        XCTAssertTrue(output.actions.isEmpty)
        XCTAssertTrue(focus.currentFocusOffsets.isEmpty)
    }

    func testLongCorrectionCanStillBeRestoredFromOriginalChoiceChip() throws {
        let output = FakeKeyboardOutput()
        let manager = makeManager(output: output)
        manager.inputSourceKind = .koreanTwoSet
        manager.isAutoCorrectionEnabled = true
        var request: OriginalChoiceRequest?
        manager.onOriginalChoiceAvailable = { request = $0 }

        type("semblance", into: manager)
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))
        let unwrapped = try XCTUnwrap(request)
        output.actions.removeAll()

        XCTAssertTrue(manager.restoreOriginalChoice(generation: unwrapped.generation))
        XCTAssertTrue(output.actions.contains(.text(unwrapped.original)))
    }

    func testFocusMismatchUndoPassesThroughWithoutPosting() {
        let output = FakeKeyboardOutput()
        let focus = FakeFocusInspector()
        let manager = makeManager(output: output, focus: focus)
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true
        type("gksrmf", into: manager)
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))
        output.actions.removeAll()

        focus.currentFocusMatches = false
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x06, flags: .maskCommand)))
        XCTAssertTrue(output.actions.isEmpty)
    }

    func testUndoRequiresExactReplacementEvenWhenCaretOffsetMatches() {
        let output = FakeKeyboardOutput()
        let focus = FakeFocusInspector()
        let manager = makeManager(output: output, focus: focus)
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true
        type("gksrmf", into: manager)
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))
        output.actions.removeAll()

        // 앱이 같은 길이의 다른 문자열로 바꿨다고 가정합니다.
        focus.anchoredTextMatches = false
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x06, flags: .maskCommand)))
        XCTAssertTrue(output.actions.isEmpty)
    }

    func testInjectedEventsPassAndSuppressedPhysicalKeyUpDoesNotLeak() {
        let output = FakeKeyboardOutput()
        let manager = makeManager(output: output)
        manager.inputSourceKind = .koreanTwoSet
        manager.isActive = true
        let keycode = Self.keycodes["r"]!

        let injectedDown = keyDown(keycode)
        EventTapManager.tagAsInjected(injectedDown)
        XCTAssertNotNil(manager.handleKeyDown(injectedDown))
        XCTAssertTrue(output.actions.isEmpty)

        let injectedUp = keyUp(keycode)
        EventTapManager.tagAsInjected(injectedUp)
        XCTAssertNotNil(manager.handleKeyUp(injectedUp))

        let physicalDown = keyDown(keycode)
        XCTAssertNil(manager.handleKeyDown(physicalDown))
        manager.noteSuppressedKeyDown(physicalDown)
        XCTAssertNotNil(manager.handleKeyUp(injectedUp))
        XCTAssertNil(manager.handleKeyUp(keyUp(keycode)))
        XCTAssertNotNil(manager.handleKeyUp(keyUp(keycode)))
    }

    func testBoundaryAutorepeatBeforeKeyUpCancelsDeferredCorrection() {
        let boundaries: [(UInt16, Bool)] = [
            (0x31, false), // Space
            (0x2B, false), // comma
        ]

        for (keycode, shift) in boundaries {
            let output = FakeKeyboardOutput()
            let manager = makeManager(output: output)
            manager.inputSourceKind = .supportedLatin
            manager.isAutoCorrectionEnabled = true
            type("gksrmf", into: manager)

            let boundary = keyDown(keycode, shift: shift)
            XCTAssertNotNil(manager.handleKeyDown(boundary))
            XCTAssertTrue(output.actions.isEmpty)

            let repeatedBoundary = keyDown(
                keycode,
                shift: shift,
                autorepeat: true
            )
            XCTAssertNotNil(manager.handleKeyDown(repeatedBoundary))
            XCTAssertTrue(output.actions.isEmpty)
            XCTAssertNotNil(manager.handleKeyUp(keyUp(keycode)))
            XCTAssertTrue(output.actions.isEmpty)
        }
    }

    func testSuccessfulUndoSuppressesAutorepeatUntilPhysicalKeyUp() {
        let output = FakeKeyboardOutput()
        let manager = makeManager(output: output)
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true
        type("gksrmf", into: manager)
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))

        let undo = keyDown(0x06, flags: .maskCommand)
        XCTAssertNil(manager.handleKeyDown(undo))
        manager.noteSuppressedKeyDown(undo)
        let outputAfterUndo = output.actions

        let repeatedUndo = keyDown(
            0x06,
            flags: .maskCommand,
            autorepeat: true
        )
        XCTAssertNil(manager.handleKeyDown(repeatedUndo))
        manager.noteSuppressedKeyDown(repeatedUndo)
        XCTAssertEqual(output.actions, outputAfterUndo)
        XCTAssertNil(manager.handleKeyUp(keyUp(0x06)))
    }

    func testDirectCompositionLetterAutorepeatKeepsComposing() {
        let output = FakeKeyboardOutput()
        let manager = makeManager(output: output)
        manager.inputSourceKind = .koreanTwoSet
        manager.isActive = true
        let keycode = Self.keycodes["r"]!

        let firstDown = keyDown(keycode)
        XCTAssertNil(manager.handleKeyDown(firstDown))
        manager.noteSuppressedKeyDown(firstDown)
        let firstOutputCount = output.actions.count

        let repeatedDown = keyDown(keycode, autorepeat: true)
        XCTAssertNil(manager.handleKeyDown(repeatedDown))
        manager.noteSuppressedKeyDown(repeatedDown)
        XCTAssertGreaterThan(output.actions.count, firstOutputCount)
        XCTAssertNil(manager.handleKeyUp(keyUp(keycode)))
    }

    func testFnModifiedLetterPassesWithoutBufferingOrComposition() {
        let output = FakeKeyboardOutput()
        let focus = FakeFocusInspector()
        let manager = makeManager(output: output, focus: focus)
        manager.inputSourceKind = .koreanTwoSet
        manager.isAutoCorrectionEnabled = true
        manager.isActive = true

        XCTAssertNotNil(manager.handleKeyDown(keyDown(
            Self.keycodes["r"]!,
            flags: .maskSecondaryFn
        )))
        XCTAssertTrue(output.actions.isEmpty)
        XCTAssertEqual(focus.tokenRequestCount, 0)
    }

    func testKeyDownRefreshesStaleKoreanSourceBeforeDirectComposition() {
        let output = FakeKeyboardOutput()
        let manager = makeManager(output: output)
        manager.inputSourceKind = .koreanTwoSet
        manager.isActive = true
        manager.onInputSourceKindRefresh = { .supportedLatin }

        XCTAssertNotNil(manager.handleKeyDown(keyDown(Self.keycodes["d"]!)))
        XCTAssertTrue(output.actions.isEmpty)
    }

    func testKeyDownRefreshActivatesDirectCompositionForNewKoreanSource() {
        let output = FakeKeyboardOutput()
        let manager = makeManager(output: output)
        manager.inputSourceKind = .supportedLatin
        manager.isActive = false
        manager.onInputSourceKindRefresh = {
            // 운영의 AppMonitor가 source 갱신과 함께 활성 상태를 발행합니다.
            manager.isActive = true
            return .koreanTwoSet
        }

        XCTAssertNil(manager.handleKeyDown(keyDown(Self.keycodes["d"]!)))
        XCTAssertEqual(output.actions, [.text("ㅇ")])
    }

    func testCapsLockTokenIsPreservedEvenWhenShiftIsAlsoPressed() {
        let output = FakeKeyboardOutput()
        let manager = makeManager(output: output)
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true

        for character in "dkwn" {
            _ = manager.handleKeyDown(keyDown(
                Self.keycodes[character]!,
                flags: [.maskAlphaShift, .maskShift]
            ))
        }
        XCTAssertNotNil(manager.handleKeyDown(keyDown(
            Self.spaceKeycode,
            flags: .maskAlphaShift
        )))
        XCTAssertTrue(output.actions.isEmpty)
    }

    // MARK: - AX 미지원 앱 학습

    /// 텍스트 역할을 계속 못 보면 그 앱을 미지원으로 학습한다.
    ///
    /// 이 경로가 없어서 목록은 "자판자동 켜짐"으로 보이는데 실제로는 아무것도
    /// 안 되는 상태가 있었다. Adobe Illustrator가 그 사례다 — AX 트리에
    /// AXTextField·AXTextArea·AXComboBox가 0개인데 UI는 켜진 것처럼 표시했다.
    func testUnsupportedRoleIsLearnedAfterRepeatedObservations() {
        let output = FakeKeyboardOutput()
        let focus = FakeFocusInspector()
        focus.alwaysUnsupportedRole = true
        let manager = makeManager(output: output, focus: focus)
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true
        var learned = 0
        manager.onAutoCorrectionUnsupported = { learned += 1 }

        // 포커스 판정은 토큰당 한 번 굳으므로 관찰 단위는 **단어**다. 여섯 단어.
        for _ in 0..<6 {
            type("gksrmf", into: manager)
            XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))
            XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))
        }

        XCTAssertEqual(learned, 1, "미지원 학습이 한 번 일어나야 합니다")
        XCTAssertTrue(output.actions.isEmpty, "미지원 앱에서 화면을 바꿨습니다")
    }

    /// 한 번 봤다고 단정하면 안 된다 — 버튼에 포커스가 가 있어도 같은 신호가 난다.
    func testSingleUnsupportedRoleObservationDoesNotLearn() {
        let output = FakeKeyboardOutput()
        let focus = FakeFocusInspector()
        focus.alwaysUnsupportedRole = true
        let manager = makeManager(output: output, focus: focus)
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true
        var learned = 0
        manager.onAutoCorrectionUnsupported = { learned += 1 }

        for _ in 0..<2 {
            type("gksrmf", into: manager)
            XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))
            XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))
        }

        XCTAssertEqual(learned, 0, "두 단어만으로 앱을 미지원으로 굳혔습니다")
    }

    /// 필드 단위 거부(비밀번호·주소창)는 앱 학습 근거가 아니다.
    /// 이걸 세면 Safari가 비밀번호 칸 하나 때문에 통째로 미지원이 된다.
    func testFieldLevelRefusalNeverLearnsUnsupported() {
        let output = FakeKeyboardOutput()
        let focus = FakeFocusInspector()
        focus.tokenAvailable = false        // 영구 .ineligible (필드 단위 거부)
        let manager = makeManager(output: output, focus: focus)
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true
        var learned = 0
        manager.onAutoCorrectionUnsupported = { learned += 1 }

        for _ in 0..<10 {
            type("gksrmf", into: manager)
            XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))
            XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))
        }

        XCTAssertEqual(learned, 0, "필드 단위 거부를 앱 미지원으로 학습했습니다")
    }

    // MARK: - 단음절 구제 (동결 자산 경유)

    /// 2키 단음절은 엔진이 R-K4로 판정을 포기한다. 동결 자산이 그 키열을
    /// 확인해 줄 때만 교정이 나온다.
    func testTwoKeyMonosyllableIsCorrectedAtBoundary() throws {
        let output = FakeKeyboardOutput()
        let manager = makeManager(
            output: output,
            monosyllableLexicon: try makeMonosyllableLexicon()
        )
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true

        type("fh", into: manager)
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))
        XCTAssertTrue(output.actions.isEmpty, "경계 키가 눌린 직후에는 아무것도 내보내지 않습니다")
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))

        // 삭제는 토큰 2자 + 경계 문자 1자 = 3회. 경계는 우리가 다시 내보낸다.
        XCTAssertEqual(output.actions, [
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .text("로"),
            .key(0x31, false),
        ])
    }

    /// 사용자가 지목한 7개가 전부 교정된다. 이 테스트가 이 작업의 수용 기준이다.
    func testReportedMonosyllablesAreAllCorrected() throws {
        let lexicon = try makeMonosyllableLexicon()
        let expected = [
            ("fh", "로"), ("dy", "요"), ("dk", "아"), ("sp", "네"),
            ("dh", "오"), ("fmf", "를"), ("sms", "는"),
        ]
        for (latin, korean) in expected {
            let output = FakeKeyboardOutput()
            let manager = makeManager(output: output, monosyllableLexicon: lexicon)
            manager.inputSourceKind = .supportedLatin
            manager.isAutoCorrectionEnabled = true

            type(latin, into: manager)
            XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))
            XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))

            // 토큰 길이 + 경계 문자 1자만큼 지운다.
            let deletions = Array(
                repeating: FakeKeyboardOutput.Action.key(0x33, false),
                count: latin.count + 1
            )
            XCTAssertEqual(
                output.actions,
                deletions + [.text(korean), .key(0x31, false)],
                "\(latin) 가 \(korean) 로 교정되지 않았습니다"
            )
        }
    }

    /// 자산 밖 단음절은 보존한다. `cma`는 **오늘 파괴 중**인 사례다.
    func testMonosyllableOutsideLexiconIsPreserved() throws {
        let lexicon = try makeMonosyllableLexicon()
        // `sk`·`eh`·`go`·`dp` 는 mono-admit.tsv 로 **의도적으로 열었으므로** 여기
        // 없습니다. 그 결정은 MonosyllableLexiconTests 가 따로 고정합니다.
        for latin in ["zh", "dns", "sns", "cma", "rm", "du", "dha"] {
            let output = FakeKeyboardOutput()
            let manager = makeManager(output: output, monosyllableLexicon: lexicon)
            manager.inputSourceKind = .supportedLatin
            manager.isAutoCorrectionEnabled = true

            type(latin, into: manager)
            XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))
            XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))
            XCTAssertTrue(output.actions.isEmpty, "\(latin) 가 교정됐습니다 — 파괴적 오교정입니다")
        }
    }

    /// 전대문자는 R-D3 약어 관례가 이미 보존한다. 단음절 관문 앞의 무료 게이트다.
    func testAllCapsAcronymIsPreserved() throws {
        let output = FakeKeyboardOutput()
        let manager = makeManager(
            output: output,
            monosyllableLexicon: try makeMonosyllableLexicon()
        )
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true

        // `SMS` — 전부 Shift. `sms`(는)와 같은 물리 키열이지만 R-D3가 약어로 본다.
        for keycode in [0x01, 0x2E, 0x01] as [UInt16] {
            _ = manager.handleKeyDown(keyDown(keycode, shift: true))
        }
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))
        XCTAssertTrue(output.actions.isEmpty, "전대문자 약어가 교정됐습니다")
    }

    /// 자산이 없으면 단음절 교정이 **전부** 사라진다(fail-closed).
    func testMissingAssetKeepsMonosyllablesPreserved() {
        for latin in ["fh", "dy", "dk", "sp", "dh", "fmf", "sms"] {
            let output = FakeKeyboardOutput()
            let manager = makeManager(output: output, monosyllableLexicon: nil)
            manager.inputSourceKind = .supportedLatin
            manager.isAutoCorrectionEnabled = true

            type(latin, into: manager)
            XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))
            XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))
            XCTAssertTrue(output.actions.isEmpty, "\(latin): 자산 없이 교정됐습니다")
        }
    }

    /// 단음절 교정은 `.medium` — 원문 칩이 Undo 창(6초) 내내 강조된다.
    func testMonosyllableCorrectionEmitsMediumTierChip() throws {
        let output = FakeKeyboardOutput()
        let manager = makeManager(
            output: output,
            monosyllableLexicon: try makeMonosyllableLexicon()
        )
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true
        var request: OriginalChoiceRequest?
        manager.onOriginalChoiceAvailable = { request = $0 }

        type("fh", into: manager)
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))

        let unwrapped = try XCTUnwrap(request, "원문 칩이 제시되지 않았습니다")
        XCTAssertEqual(unwrapped.original, "fh")
        XCTAssertEqual(unwrapped.replacement, "로")
        XCTAssertEqual(unwrapped.tier, .medium, "단음절은 항상 medium 이어야 합니다")
        XCTAssertEqual(unwrapped.boundaryUTF16Count, 1)
    }

    /// 3키 무모음 단음절은 엔진이 이미 교정을 내지만 옛 게이트가 죽였다.
    /// 관문이 자산으로 그것을 살리고, 등급은 medium으로 통일된다.
    func testVowellessThreeKeyMonosyllableIsCorrected() throws {
        let output = FakeKeyboardOutput()
        let manager = makeManager(
            output: output,
            monosyllableLexicon: try makeMonosyllableLexicon()
        )
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true
        var request: OriginalChoiceRequest?
        manager.onOriginalChoiceAvailable = { request = $0 }

        type("fmf", into: manager)
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))

        XCTAssertEqual(output.actions, [
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .text("를"),
            .key(0x31, false),
        ])
        XCTAssertEqual(try XCTUnwrap(request).tier, .medium)
    }

    /// 사본이 실제 토큰과 어긋나면(길이 대조 실패) 아무것도 하지 않는다.
    /// 발산은 기회를 놓칠 뿐 오교정을 만들지 못한다.
    func testMonosyllableRescueRequiresMatchingDiagnosticLength() throws {
        let output = FakeKeyboardOutput()
        let manager = makeManager(
            output: output,
            monosyllableLexicon: try makeMonosyllableLexicon()
        )
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true

        // 숫자 키가 섞이면 토큰이 경계까지 무효화된다 — 사본과 엔진이 어긋나는
        // 상황을 실제 경로로 만든다.
        type("fh", into: manager)
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x53)))
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))
        XCTAssertTrue(output.actions.isEmpty, "무효화된 토큰이 교정됐습니다")
    }

    private func makeManager(
        output: FakeKeyboardOutput,
        focus: FakeFocusInspector = FakeFocusInspector(),
        now: @escaping () -> Date = { Date(timeIntervalSince1970: 1_000) },
        monotonicNow: @escaping () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        },
        scheduleBoundaryCorrection: @escaping (@escaping () -> Void) -> Void = { $0() },
        lexicalTiebreaker: LexicalTiebreaker? = nil,
        guardEvidence: Set<String>? = nil,
        monosyllableLexicon: MonosyllableLexicon? = nil
    ) -> EventTapManager {
        EventTapManager(
            keyboardOutput: output,
            focusInspector: focus,
            now: now,
            monotonicNow: monotonicNow,
            pause: { _ in },
            scheduleBoundaryCorrection: scheduleBoundaryCorrection,
            lexicalTiebreaker: lexicalTiebreaker,
            guardEvidence: guardEvidence,
            monosyllableLexicon: monosyllableLexicon
        )
    }

    /// 저장소 원본 자산으로 단음절 관문을 만듭니다.
    ///
    /// 기본값을 `nil`로 둔 이유는 단음절 교정이 **자산에서만** 나온다는 사실을
    /// 테스트마다 명시적으로 드러내기 위해서입니다. 자산을 주입하지 않은 테스트가
    /// 보존을 보는 것은 버그가 아니라 fail-closed 계약 그 자체입니다.
    private func makeMonosyllableLexicon() throws -> MonosyllableLexicon {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        let url = root
            .appendingPathComponent("scripts")
            .appendingPathComponent("lexicon")
            .appendingPathComponent("ko-mono.v1.txt")
        return MonosyllableLexicon(
            entries: MonosyllableLexicon.parse(try String(contentsOf: url, encoding: .utf8))
        )
    }

    /// 저장소 원본 사전으로 어휘 계층을 만듭니다. 테스트 번들에는 앱 리소스가
    /// 없으므로 파일에서 직접 읽습니다.
    private func makeLexicalTiebreaker() throws -> LexicalTiebreaker {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        let dir = root.appendingPathComponent("scripts").appendingPathComponent("lexicon")
        return LexicalTiebreaker(
            korean: LexicalTiebreaker.parseKoreanLexicon(
                try String(contentsOf: dir.appendingPathComponent("ko-lexicon.v1.txt"), encoding: .utf8)
            ),
            english: LexicalTiebreaker.parseEnglishLexicon(
                try String(contentsOf: dir.appendingPathComponent("en-lexicon.v1.txt"), encoding: .utf8)
            )
        )
    }

    private func type(_ text: String, into manager: EventTapManager) {
        for character in text {
            guard let keycode = Self.keycodes[character] else {
                XCTFail("정의되지 않은 테스트 키: \(character)")
                return
            }
            _ = manager.handleKeyDown(keyDown(keycode))
        }
    }

    // MARK: - 공존 상태 (직접 조합 + 자동 교정 동시 활성)
    //
    // AutoCorrectionScope가 .allApps일 때 조합이 꺼지던 결합을 제거하면서
    // 두 기능이 같은 앱에서 함께 켜지는 상태가 일상적으로 도달 가능해졌다.
    // 아래 세 테스트가 그 상태의 불변식을 고정한다.

    /// 공존 상태에서 자모 키 하나는 조합 출력을 **정확히 한 번만** 낸다.
    /// 자동 교정 엔진의 record는 순수 부기라 화면에 아무것도 쓰지 않는다.
    func testCoexistenceJamoProducesSingleCompositionOutput() {
        let output = FakeKeyboardOutput()
        let manager = makeManager(output: output)
        manager.inputSourceKind = .koreanTwoSet
        manager.isActive = true
        manager.isAutoCorrectionEnabled = true

        let down = keyDown(Self.keycodes["g"]!)   // ㅎ
        XCTAssertNil(manager.handleKeyDown(down), "자모 키는 차단되어야 한다")
        XCTAssertEqual(output.actions, [.text("ㅎ")], "조합 출력이 정확히 한 번")
    }

    /// 공존 상태에서도 우리가 주입한 이벤트는 기록도 조합도 하지 않는다.
    func testCoexistenceIgnoresInjectedEvents() {
        let output = FakeKeyboardOutput()
        let manager = makeManager(output: output)
        manager.inputSourceKind = .koreanTwoSet
        manager.isActive = true
        manager.isAutoCorrectionEnabled = true

        let injected = keyDown(Self.keycodes["g"]!)
        EventTapManager.tagAsInjected(injected)
        XCTAssertNotNil(manager.handleKeyDown(injected), "주입 이벤트는 통과")
        XCTAssertTrue(output.actions.isEmpty, "주입 이벤트로는 아무것도 출력하지 않는다")

        // 트래커 상태도 오염되지 않았는지: 다음 물리 자모가 새 음절로 시작한다
        XCTAssertNil(manager.handleKeyDown(keyDown(Self.keycodes["g"]!)))
        XCTAssertEqual(output.actions, [.text("ㅎ")])
    }

    /// 공존 상태에서 백스페이스가 섞이면 그 토큰의 자동 교정을 포기한다.
    ///
    /// 엔진은 스트로크 하나를 지우고 남은 키열을 재생해 원문을 만들지만
    /// 화면 트래커는 커밋된 음절을 다시 열지 못해 두 모델이 갈라진다.
    /// 어긋난 채로 교정하면 백스페이스 수가 모자라 문자가 유출되므로,
    /// 교정을 발사하지 않는 것이 올바른 동작이다.
    func testCoexistenceBackspaceInvalidatesCorrectionForToken() {
        // 조합 자체도 백스페이스를 내보내므로(ㅎ+ㅐ→해는 delete 1) 출력의
        // 백스페이스 개수로는 교정 여부를 가릴 수 없다. onOriginalChoiceAvailable은
        // 교정이 실제로 적용될 때만 호출되므로 이것이 정확한 판별자다.
        func correctionFired(withBackspace: Bool) -> Bool {
            let output = FakeKeyboardOutput()
            var scheduled: [() -> Void] = []
            let manager = makeManager(
                output: output,
                scheduleBoundaryCorrection: { scheduled.append($0) }
            )
            manager.inputSourceKind = .koreanTwoSet
            manager.isActive = true
            manager.isAutoCorrectionEnabled = true
            var request: OriginalChoiceRequest?
            manager.onOriginalChoiceAvailable = { request = $0 }

            _ = manager.handleKeyDown(keyDown(Self.keycodes["g"]!))
            _ = manager.handleKeyDown(keyDown(Self.keycodes["e"]!))
            if withBackspace {
                _ = manager.handleKeyDown(keyDown(0x33))   // 여기서 두 모델이 갈라진다
            }
            for character in "ood" {
                _ = manager.handleKeyDown(keyDown(Self.keycodes[character]!))
            }
            _ = manager.handleKeyDown(keyDown(Self.spaceKeycode))
            _ = manager.handleKeyUp(keyUp(Self.spaceKeycode))
            for work in scheduled { work() }
            return request != nil
        }

        XCTAssertFalse(
            correctionFired(withBackspace: true),
            "백스페이스가 섞인 토큰은 교정하지 않는다 — 화면과 원문의 글자 수가 어긋난다"
        )
        XCTAssertTrue(
            correctionFired(withBackspace: false),
            "대조군: 백스페이스가 없으면 같은 흐름에서 교정이 정상 발사된다"
        )
    }

    private static let spaceKeycode: UInt16 = 0x31

    private func keyDown(
        _ keycode: UInt16,
        shift: Bool = false,
        flags: CGEventFlags = [],
        autorepeat: Bool = false
    ) -> CGEvent {
        let event = CGEvent(
            keyboardEventSource: nil,
            virtualKey: keycode,
            keyDown: true
        )!
        event.flags = flags
        if shift { event.flags.insert(.maskShift) }
        if autorepeat {
            event.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        }
        return event
    }

    private func keyUp(_ keycode: UInt16) -> CGEvent {
        CGEvent(
            keyboardEventSource: nil,
            virtualKey: keycode,
            keyDown: false
        )!
    }

    private static let keycodes: [Character: UInt16] = [
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05,
        "z": 0x06, "x": 0x07, "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C,
        "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10, "t": 0x11, "o": 0x1F,
        "u": 0x20, "i": 0x22, "p": 0x23, "l": 0x25, "j": 0x26, "k": 0x28,
        "n": 0x2D, "m": 0x2E,
    ]
}

private final class FakeKeyboardOutput: EventTapKeyboardOutputting {
    enum Action: Equatable {
        case key(UInt16, Bool)
        case text(String)
    }

    var actions: [Action] = []

    func sendKeyEvent(keycode: UInt16, shift: Bool) {
        actions.append(.key(keycode, shift))
    }

    func sendUnicodeText(_ text: String) {
        actions.append(.text(text))
    }
}

private final class FakeFocusInspector: EventTapFocusInspecting {
    let token = FocusedInputSafety.FocusToken(syntheticSelectionLocation: 0)
    let reanchoredToken = FocusedInputSafety.FocusToken(syntheticSelectionLocation: 0)
    var tokenAvailable = true
    var currentFocusMatches = true
    var anchoredTextMatches = true
    var currentFocusMatchResponses: [Bool] = []
    var tokenRequestCount = 0
    var currentFocusOffsets: [Int] = []
    /// 이 횟수만큼 조회가 *일시적으로* 실패한 뒤 성공합니다. Chrome처럼 차가운
    /// 첫 조회가 타임아웃 나는 앱을 흉내 냅니다.
    var transientFailuresRemaining = 0
    /// 이 횟수만큼 조회가 `.ineligibleTransientSelection`을 돌려준 뒤 성공합니다.
    /// 필드 클릭 시 내용이 전체 선택된 채로 남아 있고, head-insert 이벤트 탭은
    /// 앱이 그 선택을 접기 *전에* 첫 keyDown을 받습니다. 그 순간의 조회만 낡은
    /// 선택 영역을 읽어 일시적으로 거부되고, 다음 키부터는 정상입니다.
    var ineligibleProbesRemaining = 0
    /// 켜면 모든 조회가 `.ineligibleUnsupportedRole`을 돌려줍니다. AX에 텍스트
    /// 요소를 아예 안 내놓는 앱(Adobe Illustrator 실측: 메뉴 2,976개, 텍스트 0개)을
    /// 흉내 냅니다.
    var alwaysUnsupportedRole = false
    /// 조회가 일어날 때마다 불립니다. 조회 하나가 AX 예산을 통째로 쓰는 앱을
    /// 흉내 내려고 테스트가 여기서 시계를 밀 수 있습니다.
    var onProbeRequest: (() -> Void)?
    /// 캡처 앵커가 낡아 산술 검증이 실패해도, 캐럿 앞 글자 대조는 통과하는 상황.
    var caretTextMatches = false
    var caretTextCheckOriginals: [String] = []
    var caretTextBoundaryOffsets: [Int] = []
    var didReanchorFocusToken = false
    var onReanchorRequest: (() -> Void)?
    var onReanchorReturn: (() -> Void)?
    var observedDirection: CorrectionDirection?
    var scriptBoundaryOffsets: [Int] = []
    var onScriptRequest: (() -> Void)?

    func automaticCorrectionFocusToken() -> FocusedInputSafety.FocusToken? {
        tokenRequestCount += 1
        return tokenAvailable ? token : nil
    }

    func probeAutomaticCorrectionFocus() -> FocusedInputSafety.FocusProbe {
        onProbeRequest?()
        if alwaysUnsupportedRole {
            tokenRequestCount += 1
            return .ineligibleUnsupportedRole
        }
        if ineligibleProbesRemaining > 0 {
            ineligibleProbesRemaining -= 1
            tokenRequestCount += 1
            return .ineligibleTransientSelection
        }
        if transientFailuresRemaining > 0 {
            transientFailuresRemaining -= 1
            tokenRequestCount += 1
            return .unavailable
        }
        guard let token = automaticCorrectionFocusToken() else { return .ineligible }
        return .eligible(token)
    }

    func reanchoredFocusToken(
        _ token: FocusedInputSafety.FocusToken,
        original: String,
        boundaryUTF16Count: Int,
        shouldContinue: () -> Bool
    ) -> FocusedInputSafety.FocusToken? {
        caretTextCheckOriginals.append(original)
        caretTextBoundaryOffsets.append(boundaryUTF16Count)
        onReanchorRequest?()
        guard shouldContinue(), caretTextMatches else { return nil }
        didReanchorFocusToken = true
        onReanchorReturn?()
        return reanchoredToken
    }

    func anchoredOriginalFocusToken(
        _ token: FocusedInputSafety.FocusToken,
        original: String,
        boundaryUTF16Count: Int,
        shouldContinue: () -> Bool
    ) -> FocusedInputSafety.FocusToken? {
        guard shouldContinue() else { return nil }
        let focusMatches = isCurrentFocus(
                token,
                utf16Offset: original.utf16.count + boundaryUTF16Count
        )
        guard focusMatches, shouldContinue(), anchoredTextMatches else {
            return nil
        }
        return token
    }

    func isCurrentFocus(
        _ token: FocusedInputSafety.FocusToken,
        utf16Offset: Int
    ) -> Bool {
        currentFocusOffsets.append(utf16Offset)
        guard tokenAvailable else { return false }
        if didReanchorFocusToken { return true }
        if !currentFocusMatchResponses.isEmpty {
            return currentFocusMatchResponses.removeFirst()
        }
        return currentFocusMatches
    }

    func scriptBeforeCaret(
        _ token: FocusedInputSafety.FocusToken,
        boundaryUTF16Count: Int,
        shouldContinue: () -> Bool
    ) -> CorrectionDirection? {
        guard shouldContinue() else { return nil }
        scriptBoundaryOffsets.append(boundaryUTF16Count)
        onScriptRequest?()
        return observedDirection
    }
}
