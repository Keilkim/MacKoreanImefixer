import AppKit
import Foundation

/// 자판 자동 교정이 안 되는 앱을 저장소에 이슈로 요청하는 링크를 만듭니다.
///
/// ## 왜 필요한가
///
/// 어떤 앱은 접근성(AX)에 텍스트를 내놓지 않아 교정이 **원리적으로** 불가능합니다
/// (Adobe Illustrator는 AX 요소 2,976개가 전부 메뉴이고 텍스트 요소가 0개입니다).
/// 그런 앱을 "미지원"으로 표시하는 것까지는 정직하지만, 사용자 입장에서 거기서
/// 끝나면 할 수 있는 게 없습니다. 요청 경로가 있어야 "안 됨"이 막다른 길이 아니라
/// 다음 단계가 됩니다.
///
/// ## 무엇을 보내고 무엇을 보내지 않는가
///
/// 보냅니다: 앱 이름·번들 ID·앱 버전, Mackor 버전, macOS 버전, AX 진단 요약
/// (텍스트 역할이 관찰됐는지 여부 같은 범주값).
///
/// **보내지 않습니다: 입력한 내용, 파일 경로, 사용자 이름, 화면 캡처.** 이 타입은
/// 그런 값을 인자로 받지도 않습니다 — 받을 수 없으면 실수로 새어 나갈 수도 없습니다.
/// 그리고 최종 제출은 사용자가 브라우저에서 직접 누릅니다. 앱이 대신 보내지 않습니다.
enum AppSupportRequest {

    static let repositoryURL = "https://github.com/Keilkim/MacKoreanImefixer"

    /// 이슈 작성 화면을 미리 채워 여는 URL. 만들지 못하면 `nil`.
    ///
    /// - Parameters:
    ///   - appName: 대상 앱 이름 (예: `Adobe Illustrator 2026`)
    ///   - bundleID: 대상 앱 번들 ID (예: `com.adobe.illustrator`)
    ///   - support: 지금까지 관찰된 지원 상태
    static func issueURL(
        appName: String,
        bundleID: String?,
        support: TargetAppManager.AXAutoCorrectionSupport
    ) -> URL? {
        var components = URLComponents(string: "\(repositoryURL)/issues/new")
        components?.queryItems = [
            URLQueryItem(name: "title", value: "[앱 지원 요청] \(appName)"),
            URLQueryItem(name: "labels", value: "app-support"),
            URLQueryItem(name: "body", value: body(
                appName: appName, bundleID: bundleID, support: support
            )),
        ]
        return components?.url
    }

    /// 이슈 본문. 사람이 읽고 손볼 수 있는 형태로 두되, 재현에 필요한 사실은
    /// 미리 채워 사용자가 직접 알아내지 않아도 되게 합니다.
    static func body(
        appName: String,
        bundleID: String?,
        support: TargetAppManager.AXAutoCorrectionSupport
    ) -> String {
        let status: String
        switch support {
        case .supported: status = "동작 확인 (그런데도 안 되는 경우)"
        case .unknown: status = "미확인"
        case .unsupported: status = "미지원 (접근성에 텍스트 요소가 관찰되지 않음)"
        }
        return """
        ## 요청하는 앱

        - 이름: \(appName)
        - 번들 ID: \(bundleID ?? "(알 수 없음)")
        - Mackor가 판정한 상태: \(status)

        ## 환경

        - Mackor: \(shortVersion) (빌드 \(buildVersion))
        - macOS: \(osVersion)

        ## 어떤 상황인지 (직접 적어 주세요)

        <!-- 예: 문자 도구로 캔버스에 글자를 칠 때 교정이 안 됩니다. -->

        ---
        이 내용은 Mackor 앱 목록의 '요청' 버튼이 자동으로 채웠습니다.
        입력한 글자·파일 경로·사용자 이름은 포함되지 않습니다.
        """
    }

    /// 요청 버튼을 눌렀을 때. 열지 못하면 `false`.
    @discardableResult
    static func open(
        appName: String,
        bundleID: String?,
        support: TargetAppManager.AXAutoCorrectionSupport
    ) -> Bool {
        guard let url = issueURL(appName: appName, bundleID: bundleID, support: support) else {
            return false
        }
        return NSWorkspace.shared.open(url)
    }

    // MARK: - 환경 문자열

    private static var shortVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
    }

    private static var buildVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "–"
    }

    private static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
}
