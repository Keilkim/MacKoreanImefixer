import XCTest

/// `FocusedInputSafety`의 메타데이터 힌트 판정 검증.
///
/// 프로브 전체(`probeAutomaticCorrectionFocus`)는 실제 AXUIElement가 필요해
/// 단위 테스트할 수 없으므로, 안전의 핵심인 **두 등급의 검사 순서**만
/// 순수 함수로 뽑아 여기서 고정한다.
///
/// 이 파일이 고정하는 결정: 주소·URL 입력란을 통째로 막던 것을
/// "되돌릴 수 없는 경계(Return·Enter·Tab)"만 막는 것으로 좁혔다. 비밀번호·보안
/// 입력란은 그 완화의 대상이 **아니며** 오늘과 100% 동일하게 확정 거부한다.
final class FocusedInputSafetyTests: XCTestCase {

    // MARK: - 보안 힌트 (완화 금지)

    func testSecureHintsAlwaysReject() {
        for hint in ["password", "passcode", "암호", "비밀번호"] {
            XCTAssertEqual(
                FocusedInputSafety.classifyMetadata("텍스트 필드 \(hint)"),
                .secure(hint),
                "보안 힌트가 확정 거부되지 않았습니다: \(hint)"
            )
        }
    }

    /// **가장 중요한 테스트.** 배열을 둘로 쪼갠 순간 보안 우선순위가 코드 순서에만
    /// 의존하게 된다. 두 등급이 함께 걸리는 메타데이터에서 보안이 이겨야 한다.
    ///
    /// 실제로 있을 수 있는 조합이다 — "비밀번호 또는 이메일 주소",
    /// "Password or URL" 같은 라벨을 쓰는 로그인 폼이 존재한다.
    func testSecureHintWinsWhenBothTiersMatch() {
        for metadata in [
            "비밀번호 주소",
            "주소 비밀번호",
            "password url",
            "url password",
            "이메일 주소 또는 비밀번호를 입력하세요",
        ] {
            guard case .secure = FocusedInputSafety.classifyMetadata(metadata) else {
                return XCTFail("보안 힌트가 URL 힌트에 밀렸습니다: \"\(metadata)\"")
            }
        }
    }

    // MARK: - URL 힌트 (제출 경계만 차단)

    func testIrreversibleHintsAreNotOutrightRejected() {
        for hint in ["address", "url", "web address", "주소", "웹 주소"] {
            XCTAssertEqual(
                FocusedInputSafety.classifyMetadata("텍스트 필드 \(hint)"),
                .irreversibleOnly,
                "URL 힌트가 확정 거부로 남아 있습니다: \(hint)"
            )
        }
    }

    /// 실측한 Chrome 옴니박스의 실제 메타데이터. 이 문자열이 바뀌면 판정이
    /// 조용히 달라지므로 그대로 고정한다.
    func testChromeOmniboxMetadataIsIrreversibleOnly() {
        let omnibox = "주소창 및 검색창 텍스트 필드 google에서 검색하거나 url을 입력하세요."
        XCTAssertEqual(
            FocusedInputSafety.classifyMetadata(omnibox),
            .irreversibleOnly
        )
    }

    // MARK: - 일반 필드

    func testOrdinaryFieldsAreClear() {
        for metadata in [
            "데스크톱 텍스트 필드",
            "연결됨 텍스트 필드",
            "검색 search field",
            "댓글을 입력하세요",
            "",
        ] {
            XCTAssertEqual(
                FocusedInputSafety.classifyMetadata(metadata),
                .clear,
                "일반 필드가 차단됐습니다: \"\(metadata)\""
            )
        }
    }

    // MARK: - 토큰 기본값

    /// 합성 토큰의 기본값은 제출 경계를 **허용**해야 한다. 기존 테스트가 고정한
    /// 제출 경계 동작이 한 건도 바뀌지 않아야 하기 때문이다.
    func testSyntheticTokenAllowsIrreversibleBoundaryByDefault() {
        let token = FocusedInputSafety.FocusToken(syntheticSelectionLocation: 0)
        XCTAssertTrue(token.allowsIrreversibleBoundary)

        let blocked = FocusedInputSafety.FocusToken(
            syntheticSelectionLocation: 0,
            allowsIrreversibleBoundary: false
        )
        XCTAssertFalse(blocked.allowsIrreversibleBoundary)
    }
}
