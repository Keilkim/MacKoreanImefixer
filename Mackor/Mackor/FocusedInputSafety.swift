import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// 자동 교정이 현재 입력 위치에서 안전한지 보수적으로 판단합니다.
///
/// 주변 문장이나 필드 전체 값은 읽지 않습니다. 포커스된 접근성 요소의
/// 역할·하위 역할과 제목/설명·선택 범위를 확인하고, 문자 삭제 직전에는
/// 캐럿 앞 exact 원문 range를, 복원과 원문 선택 UI 전에는 exact 교정 range를
/// 예상 문자열과 비교합니다. 역할이나 빈 선택 범위를 확인하지 못하면 자동
/// 교정을 하지 않는 fail-closed 정책입니다.
enum FocusedInputSafety {
    private static let diagnosticsEnabled =
        ProcessInfo.processInfo.environment["MACKOR_DIAGNOSTICS"] == "1"

    struct FocusToken {
        fileprivate let element: AXUIElement?
        fileprivate let initialSelection: CFRange

        /// 테스트에서는 실제 Accessibility 요소에 접근하지 않고도 이벤트
        /// 흐름의 fail-closed 동작을 검증할 수 있어야 합니다. 운영 코드가
        /// 만드는 토큰에는 항상 `element`가 들어갑니다.
        init(syntheticSelectionLocation: CFIndex) {
            element = nil
            initialSelection = CFRange(
                location: syntheticSelectionLocation,
                length: 0
            )
        }

        fileprivate init(element: AXUIElement, initialSelection: CFRange) {
            self.element = element
            self.initialSelection = initialSelection
        }
    }

    /// 이벤트 탭 콜백이 응답하지 않는 앱의 Accessibility IPC에 오래
    /// 묶이지 않도록 거는 요청 시간 제한.
    ///
    /// 각 AX 요청의 상한입니다. 교정 한 번에는 여러 요청이 이어질 수 있어
    /// 전체 대기 시간은 이보다 길 수 있습니다. 늘리면 느린 앱에서 입력 전체가
    /// 그만큼 더 지연될 수 있으므로 함부로 올리지 마세요.
    ///
    /// 50ms였을 때, 차가운 첫 조회 실측 ~57ms가 상한에 잘려 *실패*로 돌아왔습니다.
    /// 조회가 느린 것과 조회가 실패한 것을 구분할 수 없어, 성공했을 조회가
    /// `.unavailable`로 보고되고 그 토큰이 통째로 버려졌습니다. 100ms로 올리면
    /// 그 조회는 57ms에 정상 응답합니다.
    ///
    /// 대가: 응답하지 않는 앱에서는 요청 하나가 최대 100ms를 물고, 프로브 하나가
    /// AX 왕복 2회이므로 최악 200ms 동안 **시스템 전체 입력**이 밀립니다.
    private static let messagingTimeout: Float = 0.1

    /// AX 연결을 미리 데웁니다. **결과를 쓰지 않고 버립니다.**
    ///
    /// 앱을 전환하면 그 앱과의 AX 연결을 새로 맺어야 하고, 그 첫 조회는 이후
    /// 조회보다 훨씬 느립니다(실측: 데워진 뒤 중앙값 0.4ms, 차가울 때 최대 57ms).
    /// 게다가 그 첫 조회는 *실패*가 아니라 **낡은 캐럿 위치를 돌려주기도** 합니다 —
    /// 진단 로그에서 실제 캐럿이 0인데 `initial=32`가 잡혀 그 토큰의 교정이
    /// 통째로 포기된 사례를 확인했습니다("첫 단어만 안 바뀐다").
    ///
    /// 실제 입력이 오기 전에 여기서 그 비용을 치르고 캐시를 갱신합니다.
    ///
    /// 반드시 이벤트 탭 콜백 **밖에서** 호출하세요. 탭 콜백에서 AX를 기다리면
    /// 시스템 입력 전체가 지연됩니다.
    static func warmFocusCache() {
        guard let element = focusedElement() else { return }
        var value: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &value
        )
    }

    /// 응답하지 않는 대상 앱의 AX 요청이 이벤트 탭이나 메인 루프를 오래
    /// 붙잡지 않도록 모든 요청 대상에 같은 제한을 적용합니다.
    static func limitMessagingTime(for element: AXUIElement) {
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
    }

    /// 포커스 조회의 결과. **일시적 실패와 확정적 거부를 구분합니다.**
    ///
    /// 둘을 합치면 앱 전환 직후처럼 AX 트리가 아직 응답하지 않는 순간의 실패가
    /// "이 필드는 교정하면 안 된다"와 똑같이 취급됩니다. 그러면 전환 후 첫 단어가
    /// 통째로 교정되지 않습니다 — 사용자가 "처음 것만 안 바뀐다"고 겪는 증상입니다.
    enum FocusProbe {
        /// 교정해도 되는 입력란.
        case eligible(FocusToken)
        /// 확정적으로 교정하면 안 됨 — 보안 입력, 보호 필드(비밀번호·주소창).
        /// 같은 토큰 안에서 다시 물어볼 필요가 없습니다.
        ///
        /// **이 거부는 필드 단위입니다.** 같은 앱의 다른 입력란은 멀쩡할 수 있으므로
        /// 앱 전체를 미지원으로 판단하는 근거가 되면 안 됩니다 — 그러면 Safari가
        /// 비밀번호 칸 하나 때문에 통째로 미지원이 됩니다.
        case ineligible
        /// 포커스된 요소가 **텍스트 역할 자체가 아님**. 필드 단위가 아니라 앱이
        /// AX에 텍스트를 안 내놓는다는 신호일 수 있어 따로 구분합니다.
        ///
        /// 한 번으로는 단정할 수 없습니다 — 버튼에 포커스가 가 있어도 이게 나옵니다.
        /// 그래서 판정은 여기서 하지 않고, 호출부가 같은 앱에서 반복 관찰될 때만
        /// 미지원으로 학습합니다.
        case ineligibleUnsupportedRole
        /// 지금은 판단할 수 없음 — AX 트리가 아직 안 잡혔거나 IPC가 타임아웃.
        /// 잠시 뒤 같은 자리에서 다시 물으면 성공할 수 있습니다.
        case unavailable
        /// 선택 영역이 남아 지금은 거부하나, 그 선택은 이 키가 곧 지울 직전
        /// 상태의 증거일 뿐입니다. 다음 키에서 다시 물으면 대개 빈 캐럿으로
        /// 바뀝니다(주소창 전체 선택 후 타이핑 등). 영구 거부(.ineligible)와
        /// 구분해 제한된 횟수만 재확인을 허용합니다.
        case ineligibleTransientSelection
    }

    static func probeAutomaticCorrectionFocus() -> FocusProbe {
        guard !IsSecureEventInputEnabled() else {
            diagnostic("focus token rejected secure event input")
            return .ineligible
        }
        guard let element = focusedElement() else {
            // 포커스된 요소를 못 얻는 건 대개 트리가 아직 차갑다는 뜻입니다.
            diagnostic("focus token missing focused element \(diagnosticContext())")
            return .unavailable
        }

        // 여러 속성을 한 번의 IPC로 읽어 이벤트 탭의 대기 시간을 제한합니다.
        let attributes: [CFString] = [
            kAXRoleAttribute as CFString,
            kAXSubroleAttribute as CFString,
            kAXTitleAttribute as CFString,
            kAXDescriptionAttribute as CFString,
            kAXRoleDescriptionAttribute as CFString,
            kAXPlaceholderValueAttribute as CFString,
            kAXSelectedTextRangeAttribute as CFString,
        ]
        var copiedValues: CFArray?
        let copyResult = AXUIElementCopyMultipleAttributeValues(
            element,
            attributes as CFArray,
            [],
            &copiedValues
        )
        guard copyResult == .success,
        let values = copiedValues as? [Any],
        values.count == attributes.count,
        let role = values[0] as? String else {
            // 속성 읽기 실패는 IPC 타임아웃이 대부분이라 일시적입니다.
            diagnostic("focus token attribute read failed result=\(copyResult.rawValue) \(diagnosticContext())")
            return .unavailable
        }

        // AXComboBox는 브라우저 웹페이지의 입력란이 흔히 쓰는 역할이다.
        // 이것이 빠져 있어서 Safari·Chrome에서 자동 교정이 전혀 걸리지 않았다.
        //
        // 주소창을 걱정할 필요는 없다. 실측으로 확인했다 — Safari 주소창은
        // role 검사를 통과한 뒤 아래 메타데이터 필터("주소"/"url"/"search")에
        // 걸려 거부된다(진단 로그 `focus token protected metadata`).
        // role 검사가 먼저이고 메타데이터 필터가 나중이므로, 여기에 역할을
        // 추가해도 그 보호는 그대로 유지된다.
        let supportedRoles: Set<String> = [
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            kAXComboBoxRole as String,
        ]
        guard supportedRoles.contains(role) else {
            diagnostic("focus token unsupported \(diagnosticContext(role: role))")
            return .ineligibleUnsupportedRole
        }

        let subrole = values[1] as? String
        // 비밀번호 필드는 항상 제외합니다. 검색 필드(kAXSearchFieldSubrole)는
        // 한국어 사용자가 한글을 가장 많이 입력하는 곳이므로 허용합니다. 주소창은
        // 이 검사가 아니라 아래 메타데이터 필터의 "주소"/"url"에서 걸립니다(실측).
        let protectedSubroles: Set<String> = [
            kAXSecureTextFieldSubrole as String,
        ]
        guard subrole.map({ !protectedSubroles.contains($0) }) ?? true else {
            diagnostic("focus token protected subrole=\(subrole ?? "") \(diagnosticContext(role: role))")
            return .ineligible
        }

        // URL 오교정과 비밀번호 유출만 막습니다.
        //
        // 이전에는 "search/검색/location/위치"까지 막았는데, 이 힌트는 URL 보호에
        // 불필요하면서 한국어 사용자가 한글을 가장 많이 치는 검색창·게시글·댓글창을
        // 통째로 차단했습니다. 주소창(옴니박스)은 "주소"/"url"/"web address" 힌트로
        // 계속 걸리므로 URL 보호는 유지됩니다(실측: 주소창은 이 필터에서 걸림).
        let metadata = values[2...5]
            .compactMap { ($0 as? String)?.lowercased() }
            .joined(separator: " ")
        let protectedHints = [
            "address", "url", "web address", "주소", "웹 주소",
            "password", "passcode", "암호", "비밀번호",
        ]
        if let hit = protectedHints.first(where: metadata.contains) {
            diagnostic("focus token protected metadata hint=\(hit) \(diagnosticContext(role: role))")
            return .ineligible
        }
        // "못 읽었다"와 "선택 영역이 비어있지 않다"는 원인도 해법도 다르므로
        // 진단에서 반드시 구분합니다. 전자는 앱이 캐럿 정보를 안 주는 것이고,
        // 후자는 사용자가 실제로 글자를 선택해 둔 것입니다.
        guard let selection = selectedTextRange(from: values[6]) else {
            diagnostic("focus token caret unreadable \(diagnosticContext(role: role))")
            return .unavailable
        }
        guard selection.length == 0 else {
            // 선택 영역이 있는 건 명확한 상태이지 일시적 실패는 아닙니다. 다만
            // 이 키가 곧 그 선택을 지우므로, 다음 키에서 다시 물으면 대개 빈
            // 캐럿으로 바뀝니다("weather" 전체 선택 후 덮어쓰기 등). 그래서
            // 즉시 확정 거부하지 않고 별도 케이스로 알려, 호출자가 제한된
            // 횟수만 재확인하게 합니다. 주소창처럼 늘 전체 선택된 필드는 위쪽
            // 메타데이터 필터(:179)가 먼저 .ineligible로 걸러내므로, 여기에는
            // "URL이 아니면서 선택을 유지하는" 드문 필드만 도달합니다.
            diagnostic(
                "focus token has selection len=\(selection.length) "
                    + diagnosticContext(role: role)
            )
            return .ineligibleTransientSelection
        }

        diagnostic("focus token ok \(diagnosticContext(role: role))")
        return .eligible(FocusToken(element: element, initialSelection: selection))
    }

    static func isCurrentFocus(_ token: FocusToken, utf16Offset: Int) -> Bool {
        guard utf16Offset >= 0, let tokenElement = token.element else {
            diagnostic("focus check rejected invalid offset or synthetic token")
            return false
        }

        guard case .eligible(let currentToken) = probeAutomaticCorrectionFocus(),
              let currentElement = currentToken.element else {
            diagnostic("focus check could not read current token")
            return false
        }

        let (expectedLocation, overflowed) = token.initialSelection.location
            .addingReportingOverflow(utf16Offset)
        let sameElement = CFEqual(tokenElement, currentElement)
        let matches = !overflowed
            && sameElement
            && currentToken.initialSelection.length == 0
            && currentToken.initialSelection.location == expectedLocation
        diagnostic(
            "focus check sameElement=\(sameElement) initial=\(token.initialSelection.location) "
                + "current=\(currentToken.initialSelection.location) expected=\(expectedLocation) "
                + "length=\(currentToken.initialSelection.length) matches=\(matches)"
        )
        return matches
    }

    /// 캡처한 토큰 시작점과 현재 캐럿의 거리를 확인하고, 그 시작점의 실제
    /// 문자열이 원문과 정확히 같은지도 대조합니다. 같은 길이의 자동 치환이
    /// 끼어도 다른 텍스트를 지우지 않도록 교정 직전에 사용합니다.
    static func anchoredOriginalFocusToken(
        _ token: FocusToken,
        original: String,
        boundaryUTF16Count: Int,
        shouldContinue: () -> Bool = { true }
    ) -> FocusToken? {
        let originalUTF16Count = original.utf16.count
        guard shouldContinue(),
              originalUTF16Count > 0,
              boundaryUTF16Count >= 0,
              isCurrentFocus(
                token,
                utf16Offset: originalUTF16Count + boundaryUTF16Count
              ),
              shouldContinue(),
              let element = token.element,
              let rangeValue = anchoredRangeValue(
                token,
                utf16Count: originalUTF16Count
              ) else {
            return nil
        }

        var stringValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            rangeValue,
            &stringValue
        ) == .success,
        let exactString = stringValue as? String,
        shouldContinue(),
        exactString == original else {
            return nil
        }
        return token
    }

    /// Verifies only the exact replacement range produced by Mackor and returns
    /// its screen bounds. No surrounding text or whole-field value is read.
    ///
    /// The returned rectangle uses AppKit's global coordinate space so it can
    /// anchor a non-activating panel directly above the corrected token.
    static func exactReplacementRect(
        _ token: FocusToken,
        replacement: String,
        boundaryUTF16Count: Int
    ) -> CGRect? {
        guard exactReplacementIsCurrent(
            token,
            replacement: replacement,
            boundaryUTF16Count: boundaryUTF16Count
        ),
        let element = token.element,
        let rangeValue = anchoredRangeValue(
            token,
            utf16Count: replacement.utf16.count
        ) else {
            return nil
        }

        var boundsValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeValue,
            &boundsValue
        ) == .success,
        let boundsValue,
        CFGetTypeID(boundsValue) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = boundsValue as! AXValue
        guard AXValueGetType(axValue) == .cgRect else { return nil }

        var quartzRect = CGRect.zero
        guard AXValueGetValue(axValue, .cgRect, &quartzRect),
              !quartzRect.isNull,
              quartzRect.origin.x.isFinite,
              quartzRect.origin.y.isFinite,
              quartzRect.size.width.isFinite,
              quartzRect.size.height.isFinite else {
            return nil
        }
        return appKitRect(fromQuartz: quartzRect)
    }

    /// Revalidates focus, caret and the exact corrected range immediately
    /// before an original-choice click or Command-Z transaction deletes text.
    static func exactReplacementIsCurrent(
        _ token: FocusToken,
        replacement: String,
        boundaryUTF16Count: Int
    ) -> Bool {
        guard boundaryUTF16Count >= 0,
              isCurrentFocus(
                token,
                utf16Offset: replacement.utf16.count + boundaryUTF16Count
              ),
              let element = token.element,
              let rangeValue = anchoredRangeValue(
                token,
                utf16Count: replacement.utf16.count
              ) else {
            return false
        }

        var stringValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            rangeValue,
            &stringValue
        ) == .success,
        let exactString = stringValue as? String else {
            return false
        }
        return exactString == replacement
    }

    /// 캡처 시점 앵커에 기대지 않고, **지금 캐럿 바로 앞의 실제 글자**가 원문과
    /// 같은지 확인합니다.
    ///
    /// 기본 검증(`isCurrentFocus`)은 산술입니다 — `지금 캐럿 == 캡처한 캐럿 + 입력 길이`.
    /// 그런데 토큰 시작 시의 AX 읽기가 **낡은 캐럿 위치를 돌려주는** 경우가 있습니다.
    /// 진단 로그에서 실제 캐럿이 0인데 `initial=32`가 잡혀 교정이 포기된 사례를
    /// 확인했고, 재시도 세 번이 모두 같은 값으로 실패했습니다 — 다시 읽는 쪽은
    /// `current`뿐이고 틀린 쪽은 `initial`이라 재시도로는 고칠 수 없습니다.
    /// 사용자에게는 "되다가 안 되다가" 하는 간헐 실패로 보입니다.
    ///
    /// 이 함수는 캡처값을 전혀 쓰지 않습니다. 지금 캐럿을 새로 읽고 그 바로 앞
    /// `original` 길이만큼을 읽어 **문자열로 대조**합니다. 일치하면 지울 대상이
    /// 정확히 그 자리에 있다는 직접 증거이므로 낡은 앵커와 무관하게 안전합니다.
    /// 산술보다 오히려 강한 보장입니다 — 엉뚱한 글자를 지울 수 없습니다.
    ///
    /// 읽는 범위는 방금 사용자가 친 토큰과 경계 문자뿐이며, 주변 문장이나 필드
    /// 전체 값은 읽지 않습니다(`exactReplacementIsCurrent`와 같은 범위 정책).
    static func reanchoredFocusToken(
        _ token: FocusToken,
        original: String,
        boundaryUTF16Count: Int,
        shouldContinue: () -> Bool = { true }
    ) -> FocusToken? {
        guard shouldContinue() else {
            diagnostic("caret text check exceeded time budget before focus lookup")
            return nil
        }
        guard boundaryUTF16Count >= 0,
              !IsSecureEventInputEnabled(),
              let element = token.element,
              let currentElement = focusedElement(),
              CFEqual(element, currentElement) else {
            diagnostic("caret text check rejected changed focus or secure input")
            return nil
        }
        guard shouldContinue() else {
            diagnostic("caret text check exceeded time budget after focus lookup")
            return nil
        }
        var selectionValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &selectionValue
        ) == .success,
        let selectionValue,
        let caret = selectedTextRange(from: selectionValue),
        caret.length == 0 else {
            diagnostic("caret text check could not read caret")
            return nil
        }
        guard shouldContinue() else {
            diagnostic("caret text check exceeded time budget after caret lookup")
            return nil
        }

        let originalCount = original.utf16.count
        let start = caret.location - boundaryUTF16Count - originalCount
        guard start >= 0, originalCount > 0 else {
            diagnostic("caret text check out of range start=\(start)")
            return nil
        }

        var range = CFRange(location: start, length: originalCount)
        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return nil }
        var stringValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            rangeValue,
            &stringValue
        ) == .success,
        let text = stringValue as? String else {
            diagnostic("caret text check could not read range")
            return nil
        }
        let matches = text == original
        diagnostic("caret text check caret=\(caret.location) start=\(start) matches=\(matches)")
        guard shouldContinue(), matches else { return nil }
        return FocusToken(
            element: element,
            initialSelection: CFRange(location: start, length: 0)
        )
    }

    /// 화면에 **실제로 찍힌** 글자가 한글인지 라틴인지 확인합니다.
    ///
    /// 지금까지 교정 방향은 "입력 소스가 무엇인가"라는 **믿음**으로 정했습니다.
    /// 그 믿음은 어긋날 수 있습니다 — 시스템(TIS)은 한글이라는데 앱은 계속
    /// 라틴을 찍는 경우가 실제로 있습니다. 그러면 영자판으로 친 `dkwn`을
    /// 한글자판으로 친 것으로 오판해 `아주` 교정을 놓칩니다.
    ///
    /// 화면에 찍힌 글자는 믿음이 아니라 **증거**입니다. 캐럿 바로 앞 한 글자의
    /// 문자 종류만 보면 어느 자판으로 쳤는지 확정됩니다.
    ///
    /// 이미 앱에 들어간 선행 경계 문자(후행 마침표 등)가 있으면 그만큼
    /// 앞을 봅니다. 현재 처리 중인 경계 keyDown은 이 수에 포함하지 않습니다.
    /// 판단할 수 없으면 `nil` — 호출자는 기존 믿음을 그대로 씁니다.
    static func scriptBeforeCaret(
        _ token: FocusToken,
        boundaryUTF16Count: Int,
        shouldContinue: () -> Bool = { true }
    ) -> CorrectionDirection? {
        guard shouldContinue(),
              boundaryUTF16Count >= 0,
              !IsSecureEventInputEnabled(),
              let element = token.element,
              let currentElement = focusedElement(),
              CFEqual(element, currentElement) else {
            return nil
        }
        guard shouldContinue() else { return nil }
        var selectionValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &selectionValue
        ) == .success,
        let selectionValue,
        let caret = selectedTextRange(from: selectionValue),
        caret.length == 0 else {
            return nil
        }

        guard shouldContinue() else { return nil }
        let start = caret.location - boundaryUTF16Count - 1
        guard start >= 0 else { return nil }
        var range = CFRange(location: start, length: 1)
        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return nil }
        var stringValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            rangeValue,
            &stringValue
        ) == .success,
        let text = stringValue as? String,
        let scalar = text.unicodeScalars.first else {
            return nil
        }

        // 완성형 음절·자모 어느 쪽이든 한글이면 한글자판으로 친 것입니다.
        let isHangul = (0xAC00...0xD7A3).contains(scalar.value)
            || (0x1100...0x11FF).contains(scalar.value)
            || (0x3130...0x318F).contains(scalar.value)
        if isHangul { return .koreanToLatin }
        let isLatin = (0x41...0x5A).contains(scalar.value)
            || (0x61...0x7A).contains(scalar.value)
        if isLatin { return .latinToKorean }
        return nil
    }

    /// Converts Quartz global event coordinates to AppKit global coordinates.
    /// The main display defines the shared vertical origin even when another
    /// display has a negative x/y origin.
    static func appKitPoint(fromQuartz point: CGPoint) -> CGPoint? {
        guard point.x.isFinite,
              point.y.isFinite,
              let mainScreen = mainScreen else {
            return nil
        }
        return CGPoint(x: point.x, y: mainScreen.frame.maxY - point.y)
    }

    private static func anchoredRangeValue(
        _ token: FocusToken,
        utf16Count: Int
    ) -> AXValue? {
        guard utf16Count >= 0 else { return nil }
        var range = CFRange(
            location: token.initialSelection.location,
            length: utf16Count
        )
        return AXValueCreate(.cfRange, &range)
    }

    private static func appKitRect(fromQuartz rect: CGRect) -> CGRect? {
        guard let lowerLeft = appKitPoint(
            fromQuartz: CGPoint(x: rect.minX, y: rect.maxY)
        ) else {
            return nil
        }
        return CGRect(
            x: lowerLeft.x,
            y: lowerLeft.y,
            width: max(rect.width, 1),
            height: max(rect.height, 1)
        )
    }

    private static var mainScreen: NSScreen? {
        NSScreen.screens.first(where: { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
                == CGMainDisplayID()
        }) ?? NSScreen.main
    }

    /// 최전면 앱의 요소를 캐시합니다. 매 조회마다 만들면 AX 연결 핸드셰이크를
    /// 반복해 느려집니다. pid가 바뀌면 버립니다.
    private static var frontmostElementCache: (pid: pid_t, element: AXUIElement)?

    /// 포커스된 요소를 **최전면 앱에 직접** 물어서 얻습니다.
    ///
    /// 전에는 시스템 전역 요소(`AXUIElementCreateSystemWide`)에 물었는데,
    /// **크로미움 계열 앱에서 그 경로가 실패합니다.** 이 맥에서 측정한 결과
    /// (Chrome이 최전면, 텍스트 입력란에 포커스가 있는 상태):
    ///
    ///     타임아웃 50ms — 시스템 전역: -25204 실패 / 앱 직접: 성공(AXComboBox)
    ///     타임아웃  2초 — 시스템 전역: -25204 실패 / 앱 직접: 성공
    ///
    /// 타임아웃을 아무리 늘려도 전역 경로는 실패하고, 앱에 직접 물으면 50ms
    /// 안에 곧바로 성공합니다. 그래서 Chrome·VS Code 같은 크로미움 앱에서는
    /// 자동 교정이 전혀 걸리지 않았고, Safari·카카오톡 같은 네이티브 앱에서는
    /// 잘 걸렸습니다.
    ///
    /// 전역 요소는 낡은 포커스를 돌려주기도 합니다. 앱에 직접 물으면 그 경로도
    /// 함께 없어집니다.
    private static func focusedElement() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = app.processIdentifier
        guard pid != ProcessInfo.processInfo.processIdentifier else { return nil }

        let element: AXUIElement
        if let cached = frontmostElementCache, cached.pid == pid {
            element = cached.element
        } else {
            element = AXUIElementCreateApplication(pid)
            // 응답하지 않는 앱에 이벤트 탭 콜백이 오래 묶이지 않도록
            // 전역 요소와 같은 제한을 겁니다.
            limitMessagingTime(for: element)
            frontmostElementCache = (pid, element)
        }

        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXFocusedUIElementAttribute as CFString,
            &value
        ) == .success,
        let value,
        CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        let focusedElement = value as! AXUIElement
        // 앱 요소에 건 50ms 상한은 반환된 child 요소에 자동으로 전파되지
        // 않습니다. 경계 keyDown 안의 exact-range 조회도 이 상한 밖으로
        // 빠져나가지 않도록 실제 요청 대상에도 같은 제한을 겁니다.
        limitMessagingTime(for: focusedElement)
        return focusedElement
    }

    private static func selectedTextRange(from value: Any) -> CFRange? {
        let cfValue = value as CFTypeRef
        guard CFGetTypeID(cfValue) == AXValueGetTypeID() else { return nil }

        let axValue = cfValue as! AXValue
        guard AXValueGetType(axValue) == .cfRange else { return nil }

        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range), range.location >= 0 else {
            return nil
        }
        return range
    }

    private static func diagnostic(_ message: @autoclosure () -> String) {
        guard diagnosticsEnabled else { return }
        print("[Mackor][diagnostic] \(message())")
    }

    /// 진단 로그에 붙일 문맥 — **어느 앱의 어떤 입력란인지**만 담습니다.
    ///
    /// 실패 로그에 이게 없으면 `matches=false`가 떠도 어느 앱에서 생긴 일인지
    /// 알 수 없어 원인을 좁힐 수 없습니다. 특정 앱에만 몰리는지, 특정 역할
    /// (텍스트필드/텍스트영역/콤보박스)에만 생기는지가 곧 다음 조사 방향입니다.
    ///
    /// **입력 내용은 절대 포함하지 않습니다.** 앱 이름·번들ID·요소 역할뿐입니다.
    /// 호출부가 `diagnostic`의 지연 평가 안에서만 부르므로 진단이 꺼져 있으면
    /// 이 조회 비용도 들지 않습니다.
    static func diagnosticContext(role: String? = nil) -> String {
        let app = NSWorkspace.shared.frontmostApplication
        let name = app?.localizedName ?? "?"
        let bundle = app?.bundleIdentifier ?? "?"
        let roleText = role.map { " role=\($0)" } ?? ""
        return "app=\(name)[\(bundle)]\(roleText)"
    }
}
