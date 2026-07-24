import Combine
import Foundation

/// 운영자가 게시하는 공지 하나(새 지원 앱, 버그픽스, 일반 공지).
///
/// 원격 JSON은 신뢰할 수 없는 입력으로 다룬다: 알 수 없는 `kind`는 `.notice`로,
/// URL은 https만 허용하고, 개수·문자열 길이에 상한을 둔다.
struct Announcement: Identifiable, Equatable, Codable {
    enum Kind: String, Codable {
        case apps    // 새로 지원되는 앱
        case fix     // 버그 수정
        case notice  // 일반 공지
    }

    let id: String
    let date: String
    let kind: Kind
    let title: String
    let body: String
    let url: String?

    private enum CodingKeys: String, CodingKey {
        case id, date, kind, title, body, url
    }

    init(id: String, date: String, kind: Kind, title: String, body: String, url: String? = nil) {
        self.id = id
        self.date = date
        self.kind = kind
        self.title = title
        self.body = body
        self.url = url
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        date = (try? container.decode(String.self, forKey: .date)) ?? ""
        // 알 수 없는 종류는 일반 공지로 강등한다.
        kind = (try? container.decode(Kind.self, forKey: .kind)) ?? .notice
        title = try container.decode(String.self, forKey: .title)
        body = (try? container.decode(String.self, forKey: .body)) ?? ""
        // https URL만 통과시킨다.
        if let raw = try? container.decode(String.self, forKey: .url),
           let components = URLComponents(string: raw),
           components.scheme?.lowercased() == "https",
           components.host?.isEmpty == false {
            url = raw
        } else {
            url = nil
        }
    }
}

/// 원격에서 공지 피드를 가져오는 계층. 테스트에서 목으로 대체할 수 있도록 분리한다.
protocol AnnouncementFetching: Sendable {
    /// ETag가 있으면 If-None-Match로 보내고, 변경이 없으면 `.notModified`를 돌려준다.
    func fetch(etag: String?) async -> AnnouncementFetchResult
}

enum AnnouncementFetchResult: Equatable {
    case success(Data, etag: String?)
    case notModified
    case failed
}

/// 앱의 `SUFeedURL`과 같은 호스트의 `announcements.json`을 GET으로 가져온다.
///
/// feed URL이 주입되지 않은 로컬 개발 빌드에서는 `endpoint`가 nil이 되어 어떤
/// 네트워크 요청도 하지 않는다(updater가 inert한 것과 같은 원칙).
struct RemoteAnnouncementFetcher: AnnouncementFetching {
    let endpoint: URL?
    let session: URLSession

    init(infoDictionary: [String: Any]? = Bundle.main.infoDictionary,
         session: URLSession = .shared) {
        self.endpoint = Self.announcementsURL(from: infoDictionary)
        self.session = session
    }

    /// SUFeedURL의 마지막 경로(appcast.xml)를 announcements.json으로 바꾼다.
    static func announcementsURL(from infoDictionary: [String: Any]?) -> URL? {
        guard let configuration = try? SparkleUpdateConfiguration(infoDictionary: infoDictionary) else {
            return nil
        }
        let base = configuration.feedURL.deletingLastPathComponent()
        guard var resolved = URLComponents(url: base, resolvingAgainstBaseURL: false),
              resolved.scheme?.lowercased() == "https" else {
            return nil
        }
        var path = resolved.path
        if !path.hasSuffix("/") { path += "/" }
        resolved.path = path + "announcements.json"
        return resolved.url
    }

    func fetch(etag: String?) async -> AnnouncementFetchResult {
        guard let endpoint else { return .failed }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let etag, !etag.isEmpty {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failed }
            if http.statusCode == 304 { return .notModified }
            guard (200...299).contains(http.statusCode) else { return .failed }
            let newETag = http.value(forHTTPHeaderField: "ETag")
            return .success(data, etag: newETag)
        } catch {
            return .failed
        }
    }
}

/// 미확인 공지 상태를 관리한다. 네트워크는 실패해도 조용히 넘어가고(다음 주기 재시도),
/// 사용자가 설정에서 끄면 어떤 요청도 하지 않는다.
@MainActor
final class AnnouncementCenter: ObservableObject {
    static let maximumAnnouncements = 50
    static let maximumFieldLength = 4000

    @Published private(set) var announcements: [Announcement] = []
    @Published private(set) var unreadCount: Int = 0

    /// 새 소식 확인 on/off. 끄면 네트워크 요청 0.
    @Published var checkEnabled: Bool {
        didSet {
            UserDefaults.standard.set(checkEnabled, forKey: Self.checkEnabledKey)
            if checkEnabled {
                startPeriodicRefresh()
            } else {
                stopPeriodicRefresh()
            }
        }
    }

    private let fetcher: AnnouncementFetching
    private let defaults: UserDefaults
    private var acknowledgedIDs: Set<String>
    private var refreshTask: Task<Void, Never>?
    private var lastManualRefresh: Date?
    private let manualRefreshThrottle: TimeInterval = 300 // 패널을 여닫아도 5분에 한 번만

    private static let checkEnabledKey = "MackorAnnouncementCheckEnabled"
    private static let acknowledgedKey = "MackorAcknowledgedAnnouncementIDs"
    private static let cacheKey = "MackorAnnouncementsCache"
    private static let etagKey = "MackorAnnouncementsETag"
    private static let refreshInterval: UInt64 = 86_400 * 1_000_000_000 // 24h

    init(fetcher: AnnouncementFetching = RemoteAnnouncementFetcher(),
         defaults: UserDefaults = .standard) {
        self.fetcher = fetcher
        self.defaults = defaults
        self.checkEnabled = defaults.object(forKey: Self.checkEnabledKey) as? Bool ?? true
        self.acknowledgedIDs = Self.loadStringSet(defaults, key: Self.acknowledgedKey)
        self.announcements = Self.loadCachedAnnouncements(defaults)
        recomputeUnread()
    }

    deinit {
        refreshTask?.cancel()
    }

    /// 실행 시 1회 + 24시간 간격으로 조용히 확인한다.
    func start() {
        guard checkEnabled else { return }
        startPeriodicRefresh()
    }

    /// 패널을 열 때 등 수동 갱신. 설정이 꺼져 있으면, 또는 최근에 이미 시도했으면
    /// 아무 것도 하지 않는다(ETag로 캐시되지만 여닫기 반복 시 요청을 더 줄인다).
    func refreshIfEnabled() {
        guard checkEnabled else { return }
        let now = Date()
        if let last = lastManualRefresh, now.timeIntervalSince(last) < manualRefreshThrottle {
            return
        }
        lastManualRefresh = now
        Task { await self.refresh() }
    }

    /// 공지 화면을 열었을 때 현재 목록을 모두 확인 처리하고 배지·글로우를 해제한다.
    func acknowledgeAll() {
        acknowledgedIDs.formUnion(announcements.map(\.id))
        persistAcknowledged()
        recomputeUnread()
    }

    func isUnread(_ announcement: Announcement) -> Bool {
        !acknowledgedIDs.contains(announcement.id)
    }

    // MARK: - 내부

    private func startPeriodicRefresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: Self.refreshInterval)
            }
        }
    }

    private func stopPeriodicRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    func refresh() async {
        guard checkEnabled else { return }
        let etag = defaults.string(forKey: Self.etagKey)
        switch await fetcher.fetch(etag: etag) {
        case .notModified, .failed:
            return
        case let .success(data, newETag):
            guard let parsed = Self.decode(data) else { return }
            announcements = parsed
            persistCache(data)
            if let newETag { defaults.set(newETag, forKey: Self.etagKey) }
            recomputeUnread()
        }
    }

    private func recomputeUnread() {
        unreadCount = announcements.reduce(0) { $0 + (isUnread($1) ? 1 : 0) }
    }

    private func persistAcknowledged() {
        // 사라진 공지의 오래된 id가 무한히 쌓이지 않도록 현재 목록 범위로 제한한다.
        acknowledgedIDs.formIntersection(announcements.map(\.id))
        if let data = try? JSONEncoder().encode(Array(acknowledgedIDs).sorted()) {
            defaults.set(data, forKey: Self.acknowledgedKey)
        }
    }

    private func persistCache(_ data: Data) {
        defaults.set(data, forKey: Self.cacheKey)
    }

    private static func decode(_ data: Data) -> [Announcement]? {
        struct Feed: Decodable { let announcements: [Announcement] }
        guard let feed = try? JSONDecoder().decode(Feed.self, from: data) else { return nil }
        return feed.announcements
            .prefix(maximumAnnouncements)
            .map { sanitize($0) }
    }

    private static func sanitize(_ announcement: Announcement) -> Announcement {
        func clamp(_ s: String) -> String { String(s.prefix(maximumFieldLength)) }
        return Announcement(
            id: announcement.id,
            date: clamp(announcement.date),
            kind: announcement.kind,
            title: clamp(announcement.title),
            body: clamp(announcement.body),
            url: announcement.url
        )
    }

    private static func loadStringSet(_ defaults: UserDefaults, key: String) -> Set<String> {
        guard let data = defaults.data(forKey: key),
              let array = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(array)
    }

    private static func loadCachedAnnouncements(_ defaults: UserDefaults) -> [Announcement] {
        guard let data = defaults.data(forKey: cacheKey),
              let parsed = decode(data) else {
            return []
        }
        return parsed
    }
}
