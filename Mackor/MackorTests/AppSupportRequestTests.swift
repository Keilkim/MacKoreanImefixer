import XCTest

/// 미지원 앱을 저장소에 요청하는 링크의 계약을 고정한다.
///
/// 여기서 지켜야 할 것은 두 가지다 — 링크가 실제로 열리는 형태인가, 그리고
/// **보내면 안 되는 것이 안 들어가는가.** 두 번째가 더 중요하다. 이 앱은 사용자가
/// 치는 모든 글자를 보는 위치에 있으므로, 밖으로 나가는 문자열은 무엇이 들어가는지
/// 테스트로 못 박아 둔다.
final class AppSupportRequestTests: XCTestCase {

    func testIssueURLPointsAtTheRepository() throws {
        let url = try XCTUnwrap(AppSupportRequest.issueURL(
            appName: "Adobe Illustrator 2026",
            bundleID: "com.adobe.illustrator",
            support: .unsupported
        ))
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "github.com")
        XCTAssertTrue(
            url.absoluteString.hasPrefix("\(AppSupportRequest.repositoryURL)/issues/new"),
            "저장소 이슈 작성 주소가 아닙니다: \(url.absoluteString)"
        )
    }

    /// 한글·공백이 섞인 앱 이름도 깨지지 않아야 한다.
    func testKoreanAndSpacesSurviveEncoding() throws {
        let url = try XCTUnwrap(AppSupportRequest.issueURL(
            appName: "한컴오피스 한글 2024",
            bundleID: "com.hancom.hwp",
            support: .unsupported
        ))
        let items = try XCTUnwrap(
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        )
        let title = try XCTUnwrap(items.first { $0.name == "title" }?.value)
        XCTAssertTrue(title.contains("한컴오피스 한글 2024"), "제목이 깨졌습니다: \(title)")
        // 인코딩된 주소에는 원문 공백이 남으면 안 된다.
        XCTAssertFalse(url.absoluteString.contains(" "))
    }

    /// 재현에 필요한 사실은 미리 채워 사용자가 직접 알아내지 않아도 되게 한다.
    func testBodyCarriesTheFactsNeededToReproduce() {
        let body = AppSupportRequest.body(
            appName: "Adobe Illustrator 2026",
            bundleID: "com.adobe.illustrator",
            support: .unsupported
        )
        XCTAssertTrue(body.contains("Adobe Illustrator 2026"))
        XCTAssertTrue(body.contains("com.adobe.illustrator"))
        XCTAssertTrue(body.contains("미지원"))
        XCTAssertTrue(body.contains("macOS"))
    }

    /// 번들 ID를 모르는 앱도 요청은 되어야 한다 — 그 사실을 본문이 밝힌다.
    func testMissingBundleIDIsStatedNotOmitted() {
        let body = AppSupportRequest.body(
            appName: "이름만 아는 앱", bundleID: nil, support: .unknown
        )
        XCTAssertTrue(body.contains("알 수 없음"), "번들 ID 부재를 표시하지 않았습니다")
        XCTAssertNotNil(AppSupportRequest.issueURL(
            appName: "이름만 아는 앱", bundleID: nil, support: .unknown
        ))
    }

    /// **개인정보가 새지 않는지.** 이 API는 입력 내용·경로를 받는 인자가 없어
    /// 구조적으로 넣을 수 없지만, 본문에 사용자 홈 경로나 계정 이름이 우연히
    /// 섞이지 않는지도 확인한다(버전 문자열 등을 통해 들어올 수 있다).
    func testBodyLeaksNeitherPathsNorUserName() {
        let body = AppSupportRequest.body(
            appName: "Adobe Illustrator 2026",
            bundleID: "com.adobe.illustrator",
            support: .unsupported
        )
        XCTAssertFalse(body.contains("/Users/"), "홈 경로가 들어갔습니다")
        XCTAssertFalse(body.contains(NSUserName()), "사용자 계정 이름이 들어갔습니다")
        XCTAssertFalse(body.contains(NSHomeDirectory()), "홈 디렉터리가 들어갔습니다")
        XCTAssertFalse(body.contains(NSFullUserName()), "사용자 전체 이름이 들어갔습니다")
    }

    /// 상태마다 다른 문구가 나가야 리포트를 분류할 수 있다.
    func testEachSupportStateIsDistinguishable() {
        let states: [TargetAppManager.AXAutoCorrectionSupport] = [
            .supported, .unknown, .unsupported,
        ]
        let bodies = states.map {
            AppSupportRequest.body(appName: "앱", bundleID: "com.example", support: $0)
        }
        XCTAssertEqual(Set(bodies).count, states.count, "상태별 본문이 구분되지 않습니다")
    }
}
