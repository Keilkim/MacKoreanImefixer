import XCTest

/// 엔진은 토큰 수명주기만 책임진다 — 버퍼링, 백스페이스 반영, 입력 간격,
/// 오버플로, 경계 처리. 어느 자판으로 쳤는지에 대한 판단은 전부
/// `LayoutCorrectionPolicy` 에 있고 `LayoutCorrectionPolicyTests` 와
/// `GoldenCorpusParityTests` 가 검증한다.
final class WrongLayoutCorrectionEngineTests: XCTestCase {

    private var engine: WrongLayoutCorrectionEngine!

    override func setUp() {
        super.setUp()
        engine = WrongLayoutCorrectionEngine()
    }

    override func tearDown() {
        engine = nil
        super.tearDown()
    }

    // MARK: - 정책 연동

    func testCorrectionCarriesTierRuleAndDirection() throws {
        record("gksrmf", source: .supportedLatin)
        let decision = try XCTUnwrap(engine.processBoundary(.space))

        XCTAssertEqual(decision.original, "gksrmf")
        XCTAssertEqual(decision.replacement, "한글")
        XCTAssertEqual(decision.direction, .latinToKorean)
        XCTAssertEqual(decision.tier, .high)
        XCTAssertEqual(decision.rule, .koreanStructure)
    }

    func testCharacterCountsDescribeWhatIsOnScreen() throws {
        // 이벤트 탭이 이 값만큼 백스페이스를 보내므로 화면과 어긋나면 안 된다.
        record("hello", source: .koreanTwoSet)
        let decision = try XCTUnwrap(engine.processBoundary(.space))

        XCTAssertEqual(decision.original, "ㅗ디ㅣㅐ")
        XCTAssertEqual(decision.originalCharacterCount, 4)
        XCTAssertEqual(decision.replacement, "hello")
        XCTAssertEqual(decision.replacementCharacterCount, 5)
        XCTAssertEqual(decision.direction, .koreanToLatin)
    }

    func testDiagnosticRecordsThePreservingRule() {
        record("hello", source: .supportedLatin)
        XCTAssertNil(engine.processBoundary(.space))

        XCTAssertEqual(engine.lastDiagnostic?.rule, .weakKoreanStructure)
        XCTAssertNil(engine.lastDiagnostic?.tier)
        XCTAssertEqual(engine.lastDiagnostic?.wasCorrected, false)
        XCTAssertEqual(engine.lastDiagnostic?.tokenLength, 5)
    }

    func testDiagnosticRecordsTheBoundaryThatTriggeredEvaluation() throws {
        record("gksrmf", source: .supportedLatin)
        _ = try XCTUnwrap(engine.processBoundary(.punctuation))
        XCTAssertEqual(engine.lastDiagnostic?.boundary, .punctuation)

        record("gksrmf", source: .supportedLatin)
        _ = try XCTUnwrap(engine.processBoundary(.space))
        XCTAssertEqual(engine.lastDiagnostic?.boundary, .space)
    }

    func testMediumTierIsReportedForMarkedForms() throws {
        // ㅈㄷ = `we`. 교정하되 확신을 낮춘다.
        record("we", source: .koreanTwoSet)
        let decision = try XCTUnwrap(engine.processBoundary(.space))

        XCTAssertEqual(decision.tier, .medium)
        XCTAssertEqual(decision.rule, .markedEnglishForm)
    }

    func testEngineNeverEmitsANoOpReplacement() {
        // 원문과 교정문이 같으면 삭제/삽입 왕복을 할 이유가 없다.
        for source in [InputSourceKind.supportedLatin, .koreanTwoSet] {
            engine.reset()
            record("hello", source: source)
            if let decision = engine.processBoundary(.space) {
                XCTAssertNotEqual(decision.original, decision.replacement)
            }
        }
    }

    // MARK: - 토큰 수명주기

    func testBackspaceRemovesLastBufferedKeystroke() throws {
        record("gksrmfx", source: .supportedLatin)
        engine.processBackspace()

        let decision = try XCTUnwrap(engine.processBoundary(.space))
        XCTAssertEqual(decision.replacement, "한글")
    }

    func testBackspaceOnAnEmptyBufferIsHarmless() {
        engine.processBackspace()
        engine.processBackspace()
        XCTAssertNil(engine.processBoundary(.space))
    }

    func testBoundaryClearsTokenAfterDecision() {
        record("gksrmf", source: .supportedLatin)

        XCTAssertNotNil(engine.processBoundary(.space))
        XCTAssertNil(engine.processBoundary(.space))
    }

    func testBoundaryClearsPreservedToken() {
        record("hello", source: .supportedLatin)
        XCTAssertNil(engine.processBoundary(.space))

        record("gksrmf", source: .supportedLatin)
        XCTAssertNotNil(engine.processBoundary(.space))
    }

    func testExplicitResetDropsBufferedContent() {
        record("gksrmf", source: .supportedLatin)
        engine.reset()

        XCTAssertNil(engine.processBoundary(.space))
    }

    func testUnsupportedInputSourceIsNeverBuffered() {
        record("gksrmf", source: .unsupported)

        XCTAssertNil(engine.processBoundary(.space))
    }

    func testChangingInputSourceStartsANewToken() {
        record("hello", source: .supportedLatin)
        record("gksrmf", source: .koreanTwoSet)

        // 앞 토큰은 버려지고, 남은 `한글` 은 정상 한국어라 손대지 않는다.
        XCTAssertNil(engine.processBoundary(.space))
        XCTAssertEqual(engine.lastDiagnostic?.direction, .koreanToLatin)
        XCTAssertEqual(engine.lastDiagnostic?.tokenLength, 6)
    }

    func testUnsupportedLetterKeyDiscardsWholeTokenUntilBoundary() {
        record("gks", source: .supportedLatin)
        XCTAssertFalse(engine.record(
            PhysicalKeystroke(keycode: 0x12, shift: false), // 숫자 1
            inputSource: .supportedLatin
        ))
        record("rmf", source: .supportedLatin)

        XCTAssertNil(engine.processBoundary(.space))

        record("gksrmf", source: .supportedLatin)
        XCTAssertNotNil(engine.processBoundary(.space))
    }

    func testExplicitInvalidationPreventsCorrectingAValidSuffix() {
        record("gks", source: .supportedLatin)
        engine.invalidateCurrentTokenUntilBoundary()
        record("gksrmf", source: .supportedLatin)

        XCTAssertNil(engine.processBoundary(.space))

        record("gksrmf", source: .supportedLatin)
        XCTAssertEqual(engine.processBoundary(.space)?.replacement, "한글")
    }

    func testBackspaceCannotResurrectADiscardedToken() {
        record("gks", source: .supportedLatin)
        engine.invalidateCurrentTokenUntilBoundary()
        engine.processBackspace()
        record("rmf", source: .supportedLatin)

        XCTAssertNil(engine.processBoundary(.space))
    }

    func testTokenOverMaximumLengthIsDiscardedUntilBoundary() {
        let boundedEngine = WrongLayoutCorrectionEngine(maximumKeystrokes: 4)
        record("gksrm", source: .supportedLatin, into: boundedEngine)
        XCTAssertNil(boundedEngine.processBoundary(.space))

        record("gksr", source: .supportedLatin, into: boundedEngine)
        // `한ㄱ` 은 완전히 조합되지 않아 강한 한국어 후보가 아니다.
        XCTAssertNil(boundedEngine.processBoundary(.space))
    }

    func testLongPauseDiscardsSuffixUntilRealBoundary() {
        var uptime: TimeInterval = 0
        let timedEngine = WrongLayoutCorrectionEngine(
            maximumInterKeystrokeInterval: 1,
            uptime: { uptime }
        )
        record("gks", source: .supportedLatin, into: timedEngine)
        uptime = 2
        record("rmf", source: .supportedLatin, into: timedEngine)

        XCTAssertNil(timedEngine.processBoundary(.space))

        record("gksrmf", source: .supportedLatin, into: timedEngine)
        XCTAssertNotNil(timedEngine.processBoundary(.space))
    }

    /// 백스페이스로 버퍼를 완전히 비운 뒤 오래 쉬어도, 그 다음 단어는 교정된다.
    ///
    /// `processBackspace()`가 버퍼를 비우면서 `lastKeystrokeUptime`을 남겨 두면,
    /// `record()`의 간격 검사가 **빈 버퍼**에 대해 옛 타임스탬프와 비교해
    /// `discardCurrentToken()`을 부른다. 간격 검사의 의도는 "긴 정지 뒤의
    /// 접미사를 완전한 단어로 오인하지 않는" 것인데, 남길 접미사가 하나도 없는
    /// 상황에서 새로 시작하는 단어를 통째로 버리게 된다.
    ///
    /// 오타를 지우고 잠깐 생각한 뒤 다시 치는 흔한 패턴이다.
    func testBackspaceToEmptyBufferDoesNotPoisonNextToken() throws {
        var uptime: TimeInterval = 0
        let timedEngine = WrongLayoutCorrectionEngine(
            maximumInterKeystrokeInterval: 1,
            uptime: { uptime }
        )

        record("gksrmf", source: .supportedLatin, into: timedEngine)
        for _ in 0..<6 {
            timedEngine.processBackspace()
        }

        // 지운 뒤 간격 상한을 넘겨 쉰다. 버퍼는 이미 비어 있으므로 이 정지는
        // 다음 토큰에 아무 영향도 주지 않아야 한다.
        uptime = 3
        record("gksrmf", source: .supportedLatin, into: timedEngine)

        let decision = try XCTUnwrap(
            timedEngine.processBoundary(.space),
            "빈 버퍼에 남은 타임스탬프가 다음 단어를 통째로 폐기했습니다"
        )
        XCTAssertEqual(decision.replacement, "한글")
    }

    func testKeystrokesWithinTheIntervalStayInTheSameToken() throws {
        var uptime: TimeInterval = 0
        let timedEngine = WrongLayoutCorrectionEngine(
            maximumInterKeystrokeInterval: 1,
            uptime: { uptime }
        )
        for character in "gksrmf" {
            uptime += 0.1
            let lowercase = Character(String(character).lowercased())
            guard let keycode = Self.keycodes[lowercase] else { return XCTFail() }
            timedEngine.record(
                PhysicalKeystroke(keycode: keycode, shift: false),
                inputSource: .supportedLatin
            )
        }
        let decision = try XCTUnwrap(timedEngine.processBoundary(.space))
        XCTAssertEqual(decision.replacement, "한글")
    }

    // MARK: - 픽스처

    private func record(
        _ letters: String,
        source: InputSourceKind,
        into targetEngine: WrongLayoutCorrectionEngine? = nil
    ) {
        let targetEngine = targetEngine ?? engine!

        for character in letters {
            let lowercase = Character(String(character).lowercased())
            guard let keycode = Self.keycodes[lowercase] else {
                XCTFail("테스트 키코드가 정의되지 않음: \(character)")
                return
            }

            let isShifted = String(character) != String(character).lowercased()
            targetEngine.record(
                PhysicalKeystroke(keycode: keycode, shift: isShifted),
                inputSource: source
            )
        }
    }

    private static let keycodes = PhysicalKeystrokeFixture.keycodes
}
