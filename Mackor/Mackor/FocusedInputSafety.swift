import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// 자동 교정이 현재 입력 위치에서 안전한지 보수적으로 판단합니다.
///
/// 주변 문장이나 필드 전체 값은 읽지 않습니다. 포커스된 접근성 요소의
/// 역할·하위 역할과 제목/설명·선택 범위를 확인하고, 원문 선택 UI를
/// 표시하거나 실행할 때만 교정된 exact range를 예상 결과와 비교합니다.
/// 역할이나 빈 선택 범위를 확인하지 못하면 자동 교정을 하지 않는
/// fail-closed 정책입니다.
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
    /// 묶이지 않도록 이 프로세스의 AX 요청 시간을 짧게 제한합니다.
    private static let systemWideElement: AXUIElement = {
        let element = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(element, 0.05)
        return element
    }()

    static func prepare() {
        _ = systemWideElement
    }

    /// 포커스 캐시를 데웁니다. **결과를 쓰지 않고 버립니다.**
    ///
    /// 실측(진단 로그)으로 확인한 문제: Mackor가 막 뜬 직후나 앱을 전환한 직후의
    /// 첫 AX 읽기는 *실패*하는 게 아니라 **낡은 캐럿 위치를 돌려줍니다.**
    /// 한 사례에서 실제 캐럿은 0인데 `initial=32`가 잡혔고, 그 토큰의 교정은
    /// 위치 검증(`current == initial + 입력길이`)에서 어긋나 포기됐습니다.
    /// 포기 자체는 옳은 안전 동작이지만 — 엉뚱한 자리의 글자를 지우면 안 되므로 —
    /// 사용자에게는 "첫 단어만 안 바뀐다"로 보입니다.
    ///
    /// 재시도로는 못 고칩니다. 재시도는 `current`만 다시 읽고 `initial`은 캡처
    /// 시점 값에 고정되는데, 틀린 쪽이 `initial`이기 때문입니다. 그래서 캡처
    /// **이전에** 한 번 버리는 읽기를 넣어 캐시를 갱신합니다.
    ///
    /// 반드시 이벤트 탭 콜백 **밖에서** 호출하세요. AX IPC가 탭 콜백을 늦추면
    /// 시스템 입력 전체가 지연됩니다.
    /// 워밍업 전용 시스템 전역 요소. **일반 조회보다 훨씬 긴 타임아웃**을 씁니다.
    ///
    /// 실측(이 맥): Chrome의 포커스 조회는 데워지면 중앙값 0.4ms·p95 0.6ms지만
    /// **차가운 첫 조회는 약 57ms**가 걸립니다. 일반 경로의 50ms 제한으로는 그
    /// 첫 조회가 반드시 타임아웃 나고, 그래서 Chrome에서는 자동 교정이 전혀
    /// 걸리지 않았습니다(`focus token missing focused element`).
    ///
    /// 이 워밍업은 이벤트 탭 콜백 밖에서만 돌므로 기다려도 안전합니다. 여기서
    /// 차가운 비용을 치러 두면 탭 경로의 조회는 데워진 0.4ms 경로를 타게 됩니다.
    private static let warmingElement: AXUIElement = {
        let element = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(element, 2.0)
        return element
    }()

    /// 포커스 캐시를 데웁니다. **결과를 쓰지 않고 버립니다.**
    ///
    /// 반드시 이벤트 탭 콜백 **밖에서** 호출하세요. 이 함수는 느린 앱을 기다리도록
    /// 일부러 긴 타임아웃을 쓰므로, 탭 콜백에서 부르면 시스템 입력 전체가 멈춥니다.
    static func warmFocusCache() {
        _ = systemWideElement
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            warmingElement,
            kAXFocusedUIElementAttribute as CFString,
            &focused
        ) == .success, let element = focused else {
            return
        }
        var value: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(
            element as! AXUIElement,
            kAXSelectedTextRangeAttribute as CFString,
            &value
        )
    }

    /// 포커스 조회의 결과. **일시적 실패와 확정적 거부를 구분합니다.**
    ///
    /// 둘을 합치면 앱 전환 직후처럼 AX 트리가 아직 응답하지 않는 순간의 실패가
    /// "이 필드는 교정하면 안 된다"와 똑같이 취급됩니다. 그러면 전환 후 첫 단어가
    /// 통째로 교정되지 않습니다 — 사용자가 "처음 것만 안 바뀐다"고 겪는 증상입니다.
    enum FocusProbe {
        /// 교정해도 되는 입력란.
        case eligible(FocusToken)
        /// 확정적으로 교정하면 안 됨 — 보안 입력, 보호 필드, 텍스트가 아닌 역할.
        /// 같은 토큰 안에서 다시 물어볼 필요가 없습니다.
        case ineligible
        /// 지금은 판단할 수 없음 — AX 트리가 아직 안 잡혔거나 IPC가 타임아웃.
        /// 잠시 뒤 같은 자리에서 다시 물으면 성공할 수 있습니다.
        case unavailable
    }

    /// 기존 호출자를 위한 얇은 껍데기. 일시적 실패와 확정 거부를 구분하지
    /// 못하므로, 재시도가 필요한 경로에서는 `probeAutomaticCorrectionFocus()`를
    /// 직접 쓰세요.
    static func automaticCorrectionFocusToken() -> FocusToken? {
        if case .eligible(let token) = probeAutomaticCorrectionFocus() { return token }
        return nil
    }

    static func probeAutomaticCorrectionFocus() -> FocusProbe {
        guard !IsSecureEventInputEnabled() else {
            diagnostic("focus token rejected secure event input")
            return .ineligible
        }
        guard let element = focusedElement() else {
            // 포커스된 요소를 못 얻는 건 대개 트리가 아직 차갑다는 뜻입니다.
            diagnostic("focus token missing focused element")
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
            diagnostic("focus token attribute read failed result=\(copyResult.rawValue)")
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
            diagnostic("focus token unsupported role=\(role)")
            return .ineligible
        }

        let subrole = values[1] as? String
        // 비밀번호 필드는 항상 제외합니다. 검색 필드(kAXSearchFieldSubrole)는
        // 한국어 사용자가 한글을 가장 많이 입력하는 곳이므로 허용합니다. 주소창은
        // 이 검사가 아니라 아래 메타데이터 필터의 "주소"/"url"에서 걸립니다(실측).
        let protectedSubroles: Set<String> = [
            kAXSecureTextFieldSubrole as String,
        ]
        guard subrole.map({ !protectedSubroles.contains($0) }) ?? true else {
            diagnostic("focus token protected subrole=\(subrole ?? "")")
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
            diagnostic("focus token protected metadata hint=\(hit)")
            return .ineligible
        }
        guard let selection = selectedTextRange(from: values[6]), selection.length == 0 else {
            // 선택 영역을 못 읽는 것도 IPC 실패일 수 있어 일시적으로 봅니다.
            diagnostic("focus token missing or nonempty selection")
            return .unavailable
        }

        return .eligible(FocusToken(element: element, initialSelection: selection))
    }

    static func isCurrentFocus(_ token: FocusToken, utf16Offset: Int) -> Bool {
        guard utf16Offset >= 0, let tokenElement = token.element else {
            diagnostic("focus check rejected invalid offset or synthetic token")
            return false
        }

        guard let currentToken = automaticCorrectionFocusToken(),
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
        let rangeValue = replacementRangeValue(
            token,
            replacementUTF16Count: replacement.utf16.count
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
              let rangeValue = replacementRangeValue(
                token,
                replacementUTF16Count: replacement.utf16.count
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

    /// 현재 삽입 커서의 화면 좌표를 AppKit 좌표계로 반환합니다.
    /// 좌표를 얻지 못하면 알림 UI를 띄우지 않습니다.
    static func caretRect() -> CGRect? {
        guard let element = focusedElement() else { return nil }

        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeValue
        ) == .success,
        let rangeValue else {
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

        var axRect = CGRect.zero
        guard AXValueGetValue(axValue, .cgRect, &axRect), !axRect.isNull else {
            return nil
        }

        return appKitRect(fromQuartz: axRect)
    }

    private static func replacementRangeValue(
        _ token: FocusToken,
        replacementUTF16Count: Int
    ) -> AXValue? {
        guard replacementUTF16Count >= 0 else { return nil }
        var range = CFRange(
            location: token.initialSelection.location,
            length: replacementUTF16Count
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

    private static func focusedElement() -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &value
        ) == .success,
        let value,
        CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private static func selectedTextRange(from element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &value
        ) == .success,
        let value,
        CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }

        return selectedTextRange(from: value)
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
}
