import Foundation

/// A physical letter-key press. The engine deliberately keeps only virtual
/// keycodes and modifier state; it never reads surrounding text from an app.
struct PhysicalKeystroke: Equatable {
    let keycode: UInt16
    let shift: Bool
}

/// Input sources for which wrong-layout correction is safe to evaluate.
///
/// `supportedLatin` currently means an Apple ABC/U.S.-style QWERTY layout.
enum InputSourceKind: Equatable {
    case koreanTwoSet
    case supportedLatin
    case unsupported
}

enum CorrectionDirection: Equatable {
    case latinToKorean
    case koreanToLatin
}

/// Delimiters at which a complete token may be evaluated.
///
/// `submit` covers Return/Enter/Tab. Those keys can send a message or move
/// focus, so the event-tap layer must correct *before* letting them reach the
/// app rather than deleting and retyping afterwards.
enum CorrectionBoundary: Equatable {
    case space
    case punctuation
    case submit
}

/// Last-token diagnostics contain only categorical data and a bounded length;
/// they intentionally contain no original or replacement strings.
struct CorrectionDiagnostic: Equatable {
    let direction: CorrectionDirection
    /// `nil` when the token was preserved.
    let tier: LayoutCorrectionPolicy.Tier?
    let rule: LayoutCorrectionPolicy.Rule
    let tokenLength: Int
    let boundary: CorrectionBoundary

    var wasCorrected: Bool { tier != nil }
}

/// A short-lived replacement transaction.
///
/// The event-tap layer can use the two character counts both for replacement
/// and for an immediate undo. Nothing in this value is persisted or logged.
struct CorrectionDecision: Equatable {
    let original: String
    let replacement: String
    let direction: CorrectionDirection
    let originalCharacterCount: Int
    let replacementCharacterCount: Int
    /// How strongly the rule system backs this replacement. `medium` means the
    /// opposite reading was structurally possible but marked.
    let tier: LayoutCorrectionPolicy.Tier
    let rule: LayoutCorrectionPolicy.Rule
    let diagnostic: CorrectionDiagnostic?

    init(
        original: String,
        replacement: String,
        direction: CorrectionDirection,
        tier: LayoutCorrectionPolicy.Tier,
        rule: LayoutCorrectionPolicy.Rule,
        diagnostic: CorrectionDiagnostic? = nil
    ) {
        self.original = original
        self.replacement = replacement
        self.direction = direction
        originalCharacterCount = original.count
        replacementCharacterCount = replacement.count
        self.tier = tier
        self.rule = rule
        self.diagnostic = diagnostic
    }
}

/// Buffers a bounded sequence of physical letter keys and, at a word boundary,
/// asks `LayoutCorrectionPolicy` whether the token was typed on the wrong
/// layout.
///
/// The engine owns only token lifetime — buffering, backspace mirroring, the
/// inter-keystroke time window and overflow. Every language decision lives in
/// `LayoutCorrectionPolicy`, which consults no dictionary and no system
/// service. Candidate strings remain transient and are never persisted or
/// logged.
final class WrongLayoutCorrectionEngine {
    private struct BufferedStroke {
        let keystroke: PhysicalKeystroke
        let latinCharacter: Character
    }

    private let maximumKeystrokes: Int
    private let maximumInterKeystrokeInterval: TimeInterval
    private let uptime: () -> TimeInterval
    private var strokes: [BufferedStroke] = []
    private var tokenInputSource: InputSourceKind?
    private var lastKeystrokeUptime: TimeInterval?
    private var evaluationBoundary: CorrectionBoundary = .space

    /// The most recent completed-token outcome. It contains no candidate text.
    private(set) var lastDiagnostic: CorrectionDiagnostic?

    /// Once a token exceeds the memory bound or contains an unsupported key,
    /// its suffix must not be mistaken for a complete word.
    private var discardingUntilBoundary = false

    init(
        maximumKeystrokes: Int = 32,
        maximumInterKeystrokeInterval: TimeInterval = 2,
        uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        precondition(maximumKeystrokes > 0)
        precondition(maximumInterKeystrokeInterval > 0)
        self.maximumKeystrokes = maximumKeystrokes
        self.maximumInterKeystrokeInterval = maximumInterKeystrokeInterval
        self.uptime = uptime
        strokes.reserveCapacity(maximumKeystrokes)
    }

    /// Records one of the 26 physical QWERTY letter keys.
    ///
    /// Returns `false` when the source/key is unsupported or the current token
    /// has become ineligible. The caller should still pass the user's original
    /// event through to the target application.
    @discardableResult
    func record(_ keystroke: PhysicalKeystroke, inputSource: InputSourceKind) -> Bool {
        guard inputSource != .unsupported else {
            reset()
            return false
        }

        if let existingSource = tokenInputSource, existingSource != inputSource {
            reset()
        }

        let currentUptime = uptime()
        if let lastKeystrokeUptime,
           currentUptime - lastKeystrokeUptime > maximumInterKeystrokeInterval {
            // 긴 정지 뒤의 접미사를 하나의 완전한 단어로 오인하지 않습니다.
            discardCurrentToken()
        }

        guard !discardingUntilBoundary else { return false }

        guard let latinCharacter = LayoutCorrectionPolicy.latinCharacter(
            for: keystroke.keycode,
            shift: keystroke.shift
        ),
            KeycodeToJamoMap.jamo(for: keystroke.keycode, shift: keystroke.shift) != nil else {
            discardCurrentToken()
            return false
        }

        guard strokes.count < maximumKeystrokes else {
            discardCurrentToken()
            return false
        }

        tokenInputSource = inputSource
        lastKeystrokeUptime = currentUptime
        strokes.append(BufferedStroke(keystroke: keystroke, latinCharacter: latinCharacter))
        return true
    }

    /// Mirrors a backspace that removed the most recent buffered letter.
    /// An overflowed/unsafe token stays discarded until a real boundary because
    /// the engine no longer knows how much of that token remains on screen.
    ///
    /// 버퍼가 비면 `lastKeystrokeUptime`도 함께 비웁니다. `reset()`·
    /// `discardCurrentToken()`이 하는 것과 같은 정리입니다.
    ///
    /// 안 비우면 `record()`의 간격 검사가 **빈 버퍼**에 대해 옛 타임스탬프와
    /// 비교합니다. 백스페이스로 토큰을 다 지운 뒤 `maximumInterKeystrokeInterval`
    /// 보다 오래 쉬면, 접미사가 아니라 새로 시작하는 단어를 통째로
    /// `discardCurrentToken()`으로 버렸습니다 — 간격 검사의 의도와 정반대입니다.
    func processBackspace() {
        guard !discardingUntilBoundary else { return }
        guard !strokes.isEmpty else {
            tokenInputSource = nil
            lastKeystrokeUptime = nil
            return
        }

        strokes.removeLast()
        if strokes.isEmpty {
            tokenInputSource = nil
            lastKeystrokeUptime = nil
        }
    }

    /// Marks the current whitespace-delimited token as ineligible without
    /// losing that fact when more letters arrive. This is used for numbers and
    /// unsupported symbols so a valid-looking suffix is never corrected on
    /// its own.
    func invalidateCurrentTokenUntilBoundary() {
        discardCurrentToken()
    }

    /// Evaluates the completed token and always clears its transient state.
    /// The boundary itself is handled by the event-tap layer.
    func processBoundary(_ boundary: CorrectionBoundary) -> CorrectionDecision? {
        evaluationBoundary = boundary
        defer { reset() }

        guard !discardingUntilBoundary,
              let inputSource = tokenInputSource,
              !strokes.isEmpty else {
            return nil
        }

        guard let direction = Self.direction(for: inputSource) else { return nil }

        let decision = LayoutCorrectionPolicy.evaluate(
            keystrokes: strokes.map(\.keystroke),
            inputSource: inputSource
        )

        switch decision {
        case .preserve(let rule):
            lastDiagnostic = CorrectionDiagnostic(
                direction: direction,
                tier: nil,
                rule: rule,
                tokenLength: strokes.count,
                boundary: evaluationBoundary
            )
            return nil

        case .correct(let tier, let original, let replacement, let rule):
            // A replacement identical to the original is never worth a
            // synthetic delete/insert round trip.
            guard original != replacement else {
                lastDiagnostic = CorrectionDiagnostic(
                    direction: direction,
                    tier: nil,
                    rule: .ambiguousBothValid,
                    tokenLength: strokes.count,
                    boundary: evaluationBoundary
                )
                return nil
            }

            let diagnostic = CorrectionDiagnostic(
                direction: direction,
                tier: tier,
                rule: rule,
                tokenLength: strokes.count,
                boundary: evaluationBoundary
            )
            lastDiagnostic = diagnostic
            return CorrectionDecision(
                original: original,
                replacement: replacement,
                direction: direction,
                tier: tier,
                rule: rule,
                diagnostic: diagnostic
            )
        }
    }

    /// Clears all in-memory token state. Call this for symbols, shortcuts,
    /// focus/cursor changes, input-source changes, and unsafe input fields.
    func reset() {
        strokes.removeAll(keepingCapacity: true)
        tokenInputSource = nil
        lastKeystrokeUptime = nil
        discardingUntilBoundary = false
    }

    private func discardCurrentToken() {
        strokes.removeAll(keepingCapacity: true)
        tokenInputSource = nil
        lastKeystrokeUptime = nil
        discardingUntilBoundary = true
    }

    private static func direction(
        for inputSource: InputSourceKind
    ) -> CorrectionDirection? {
        switch inputSource {
        case .supportedLatin:
            return .latinToKorean
        case .koreanTwoSet:
            return .koreanToLatin
        case .unsupported:
            return nil
        }
    }
}
