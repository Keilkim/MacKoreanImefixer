import XCTest

private final class MockAnnouncementFetcher: AnnouncementFetching, @unchecked Sendable {
    var result: AnnouncementFetchResult
    private(set) var fetchCount = 0
    private(set) var lastEtag: String?

    init(result: AnnouncementFetchResult) {
        self.result = result
    }

    func fetch(etag: String?) async -> AnnouncementFetchResult {
        fetchCount += 1
        lastEtag = etag
        return result
    }
}

@MainActor
final class AnnouncementCenterTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "AnnouncementCenterTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func feed(_ items: String) -> Data {
        Data("{\"announcements\":[\(items)]}".utf8)
    }

    func testDecodesValidFeedAndCountsUnread() async {
        let json = """
        {"id":"a","date":"2026-07-25","kind":"apps","title":"새 앱","body":"본문","url":"https://example.com/x"},
        {"id":"b","date":"2026-07-24","kind":"fix","title":"버그 수정","body":""}
        """
        let center = AnnouncementCenter(
            fetcher: MockAnnouncementFetcher(result: .success(feed(json), etag: nil)),
            defaults: makeDefaults()
        )
        await center.refresh()

        XCTAssertEqual(center.announcements.count, 2)
        XCTAssertEqual(center.unreadCount, 2)
        XCTAssertEqual(center.announcements[0].kind, .apps)
        XCTAssertEqual(center.announcements[0].url, "https://example.com/x")
        XCTAssertEqual(center.announcements[1].kind, .fix)
    }

    func testUnknownKindBecomesNotice() async {
        let json = #"{"id":"a","date":"2026-07-25","kind":"weird","title":"x","body":"y"}"#
        let center = AnnouncementCenter(
            fetcher: MockAnnouncementFetcher(result: .success(feed(json), etag: nil)),
            defaults: makeDefaults()
        )
        await center.refresh()

        XCTAssertEqual(center.announcements.first?.kind, .notice)
    }

    func testNonHTTPSURLIsDropped() async {
        let json = #"{"id":"a","date":"2026-07-25","kind":"notice","title":"x","body":"y","url":"http://insecure.example.com"}"#
        let center = AnnouncementCenter(
            fetcher: MockAnnouncementFetcher(result: .success(feed(json), etag: nil)),
            defaults: makeDefaults()
        )
        await center.refresh()

        XCTAssertNil(center.announcements.first?.url)
    }

    func testAcknowledgeAllClearsUnreadAndPersists() async {
        let json = #"{"id":"a","date":"2026-07-25","kind":"notice","title":"x","body":"y"}"#
        let defaults = makeDefaults()
        let center = AnnouncementCenter(
            fetcher: MockAnnouncementFetcher(result: .success(feed(json), etag: nil)),
            defaults: defaults
        )
        await center.refresh()
        XCTAssertEqual(center.unreadCount, 1)

        center.acknowledgeAll()
        XCTAssertEqual(center.unreadCount, 0)

        // 같은 UserDefaults로 새 인스턴스를 만들면 확인 상태가 유지되어야 한다.
        let reloaded = AnnouncementCenter(
            fetcher: MockAnnouncementFetcher(result: .success(feed(json), etag: nil)),
            defaults: defaults
        )
        await reloaded.refresh()
        XCTAssertEqual(reloaded.unreadCount, 0)
    }

    func testDisabledDoesNotFetch() async {
        let mock = MockAnnouncementFetcher(result: .success(feed(#"{"id":"a","date":"","kind":"notice","title":"x","body":""}"#), etag: nil))
        let center = AnnouncementCenter(fetcher: mock, defaults: makeDefaults())
        center.checkEnabled = false

        await center.refresh()

        XCTAssertEqual(mock.fetchCount, 0)
        XCTAssertTrue(center.announcements.isEmpty)
    }

    func testNotModifiedKeepsExistingAnnouncements() async {
        let json = #"{"id":"a","date":"2026-07-25","kind":"notice","title":"x","body":"y"}"#
        let mock = MockAnnouncementFetcher(result: .success(feed(json), etag: "v1"))
        let center = AnnouncementCenter(fetcher: mock, defaults: makeDefaults())
        await center.refresh()
        XCTAssertEqual(center.announcements.count, 1)

        mock.result = .notModified
        await center.refresh()
        XCTAssertEqual(center.announcements.count, 1)
        // 두 번째 요청에는 첫 응답의 ETag가 실려야 한다.
        XCTAssertEqual(mock.lastEtag, "v1")
    }

    func testFailedFetchKeepsExistingAnnouncements() async {
        let json = #"{"id":"a","date":"2026-07-25","kind":"notice","title":"x","body":"y"}"#
        let mock = MockAnnouncementFetcher(result: .success(feed(json), etag: nil))
        let center = AnnouncementCenter(fetcher: mock, defaults: makeDefaults())
        await center.refresh()

        mock.result = .failed
        await center.refresh()
        XCTAssertEqual(center.announcements.count, 1)
    }

    func testCountAndFieldLengthAreClamped() async {
        let longTitle = String(repeating: "가", count: AnnouncementCenter.maximumFieldLength + 500)
        var items: [String] = []
        for index in 0..<(AnnouncementCenter.maximumAnnouncements + 20) {
            items.append("{\"id\":\"a\(index)\",\"date\":\"2026-07-25\",\"kind\":\"notice\",\"title\":\"\(longTitle)\",\"body\":\"\"}")
        }
        let data = Data("{\"announcements\":[\(items.joined(separator: ","))]}".utf8)
        let center = AnnouncementCenter(
            fetcher: MockAnnouncementFetcher(result: .success(data, etag: nil)),
            defaults: makeDefaults()
        )
        await center.refresh()

        XCTAssertEqual(center.announcements.count, AnnouncementCenter.maximumAnnouncements)
        XCTAssertLessThanOrEqual(
            center.announcements.first?.title.count ?? .max,
            AnnouncementCenter.maximumFieldLength
        )
    }

    func testInvalidJSONIsIgnored() async {
        let center = AnnouncementCenter(
            fetcher: MockAnnouncementFetcher(result: .success(Data("not json".utf8), etag: nil)),
            defaults: makeDefaults()
        )
        await center.refresh()
        XCTAssertTrue(center.announcements.isEmpty)
    }

    func testAnnouncementsURLDerivedFromFeedURL() {
        let key = Data(repeating: 0x2A, count: 32).base64EncodedString()
        let url = RemoteAnnouncementFetcher.announcementsURL(from: [
            SparkleUpdateConfiguration.feedURLInfoKey: "https://keilkim.github.io/MacKoreanImefixer/appcast.xml",
            SparkleUpdateConfiguration.publicEDKeyInfoKey: key,
        ])
        XCTAssertEqual(url?.absoluteString, "https://keilkim.github.io/MacKoreanImefixer/announcements.json")
    }

    func testAnnouncementsURLNilWithoutFeedURL() {
        let url = RemoteAnnouncementFetcher.announcementsURL(from: [
            SparkleUpdateConfiguration.feedURLInfoKey: "$(MACKOR_UPDATE_FEED_URL)",
        ])
        XCTAssertNil(url)
    }
}
