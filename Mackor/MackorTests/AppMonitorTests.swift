import XCTest

/// `AppMonitor.computeActiveState`의 활성 판정 검증.
///
/// 이 파일이 고정하는 회귀: `AutoCorrectionScope = .allApps`가 한글 직접 조합을
/// 통째로 끄던 문제. 등록된 앱(CorelDRAW)에서 조합 토글을 켜뒀는데도 전체 Mac
/// 모드에서는 조합이 동작하지 않았고, 사용자는 아무 경고 없이 기능을 잃었다.
///
/// 판정 로직을 순수 함수로 뽑은 이유: `AppMonitor`의 init이 NSWorkspace와 TIS를
/// 실제로 읽으므로 인스턴스 기반 테스트는 실행 환경에 따라 결과가 달라진다.
final class AppMonitorTests: XCTestCase {

    /// 기본값은 "조합·교정이 모두 켜질 수 있는" 상태. 각 테스트가 한 축만 바꾼다.
    private func state(
        isEnabled: Bool = true,
        isTargetAppFront: Bool = true,
        isKoreanIME: Bool = true,
        hangulCompositionEnabled: Bool = true,
        autoCorrectionEnabled: Bool = true,
        inputSourceKind: InputSourceKind = .koreanTwoSet
    ) -> AppMonitor.ActiveState {
        AppMonitor.computeActiveState(
            isEnabled: isEnabled,
            isTargetAppFront: isTargetAppFront,
            isKoreanIME: isKoreanIME,
            hangulCompositionEnabled: hangulCompositionEnabled,
            autoCorrectionEnabled: autoCorrectionEnabled,
            inputSourceKind: inputSourceKind
        )
    }

    // MARK: - 회귀 고정

    /// 이 테스트가 회귀 수정의 핵심이다.
    ///
    /// `.allApps`에서 `isAutoCorrectionEnabled`는 앱 목록을 보지 않고 true를
    /// 반환하고(TargetAppManager), 조합은 등록 조회 결과를 그대로 받는다.
    /// 두 값이 동시에 true여야 한다 — 이전 코드는 scope를 이유로 조합을 껐다.
    func testAllAppsScopeKeepsCompositionForRegisteredApp() {
        let result = state()
        XCTAssertTrue(result.composition, "전체 Mac 모드에서도 등록 앱의 조합은 켜져야 한다")
        XCTAssertTrue(result.autoCorrection, "자동 교정도 동시에 켜져야 한다")
    }

    /// R2와 R3는 배타가 아니다. 둘 다 true인 상태가 정상이며 도달 가능해야 한다.
    func testCompositionAndAutoCorrectionCoexist() {
        let result = state()
        XCTAssertTrue(result.composition && result.autoCorrection)
    }

    // MARK: - 등록·토글이 여전히 조합을 통제하는가

    /// scope 항을 지웠어도 "등록한 앱에서만 조합"은 유지되어야 한다.
    /// 이 보증은 isTargetAppFront와 앱별 토글이 이중으로 강제한다.
    func testUnregisteredAppHasNoComposition() {
        XCTAssertFalse(state(isTargetAppFront: false).composition)
    }

    func testCompositionToggleOffDisablesComposition() {
        let result = state(hangulCompositionEnabled: false)
        XCTAssertFalse(result.composition, "앱별 조합 토글은 계속 off 스위치로 동작해야 한다")
        XCTAssertTrue(result.autoCorrection, "조합만 꺼지고 교정은 남는다")
    }

    // MARK: - 공통 차단 조건

    func testGlobalDisableTurnsOffBoth() {
        let result = state(isEnabled: false)
        XCTAssertFalse(result.composition)
        XCTAssertFalse(result.autoCorrection)
    }

    func testNonKoreanIMEDisablesCompositionOnly() {
        let result = state(isKoreanIME: false)
        XCTAssertFalse(result.composition, "한글 IME가 아니면 직접 조합은 무의미하다")
        XCTAssertTrue(result.autoCorrection, "영문 입력 중의 교정은 계속 필요하다")
    }

    // MARK: - 자동 교정 쪽 조건

    func testUnsupportedInputSourceDisablesAutoCorrection() {
        let result = state(inputSourceKind: .unsupported)
        XCTAssertFalse(result.autoCorrection, "지원하지 않는 입력 소스에서는 교정하지 않는다")
    }

    func testAutoCorrectionDisabledForAppKeepsComposition() {
        let result = state(autoCorrectionEnabled: false)
        XCTAssertFalse(result.autoCorrection)
        XCTAssertTrue(result.composition, "교정만 꺼지고 조합은 남는다")
    }

    /// `.selectedApps`에서의 동작이 바뀌지 않았음을 표로 고정한다.
    /// 이전 식은 `scope == .selectedApps && 토글`이었으므로, 그 모드에서는
    /// 새 식(`토글`)과 결과가 완전히 같아야 한다.
    func testSelectedAppsScopeBehaviourUnchanged() {
        // scope는 이제 판정에 들어가지 않으므로, 같은 입력이면 같은 결과다.
        for toggle in [true, false] {
            for front in [true, false] {
                let result = state(isTargetAppFront: front, hangulCompositionEnabled: toggle)
                XCTAssertEqual(result.composition, front && toggle)
            }
        }
    }
}
