import Foundation

/// 영자판으로 친 **한글 한 음절**을 교정해도 되는 키열의 닫힌 목록.
///
/// ## 왜 구조가 아니라 목록인가 — 구조로는 원리적으로 못 가른다
///
/// 2키로 음절을 만드는 경로는 초성1+중성1 하나뿐이라 후보 전체가 구조 특징 한 점에
/// 모인다(자모 모양 100% C+V, 종성 0, 최대 자음 연쇄 1). `dk`(아)와 `sk`(SK)는
/// 자판 행·자모 모양·키 수·종성 유무가 전부 같고 초성 하나만 다르다. `sms`(는)와
/// `sns`(눈)는 물리적으로 인접한 두 키(m/n) 차이다. 열거 가능한 어떤 구조 신호로도
/// 분리되지 않는 쌍이 여럿이고, 남는 변수는 자모의 정체 = **어휘 정보**뿐이다.
/// 그래서 이 계층은 판정하지 않는다. **조회만 한다.**
///
/// ## 무모음 조건을 쓰지 않는 이유
///
/// 이전 게이트는 "라틴에 aeiou 가 없으면 약어"라는 구조 추정이었다. 실측하면 그
/// 게이트가 막는 3키 단음절 1,208개 중 **영어 사전 단어는 0개**이고, 반대로
/// 통과시키는 435개 중 265개는 19,895어절 코퍼스에 한 번도 안 나오는 음절이다
/// (`cma`→츰이 그 형태로 살아 있었다). 두벌식에서 a·e·i·o·u 는 ㅁ·ㄷ·ㅑ·ㅐ·ㅕ 일
/// 뿐이라, 라틴 모음의 유무는 한국어 단어성과도 영어 단어성과도 아무 관계가 없다.
///
/// ## 자산의 출처
///
/// 손 목록이 아니라 `scripts/lexicon/make_mono_lexicon.py` 의 투영이다. 허용 방향의
/// 소스는 한국어 단어로만 적고 키열은 스크립트가 계산한다 — 키열을 직접 적을 수
/// 있으면 영어사전·CLI·로케일 게이트를 우회해 항목을 밀어 넣을 수 있기 때문이다.
/// 안전 게이트는 전부 **생성 시점**에 적용돼 자산에 구워져 있고, 런타임은 조회
/// 한 번이다. 자산은 `scripts/lexicon-freeze.sha256` 으로 동결하고 CI 가 대조한다.
///
/// 자산이 없으면 `init?` 이 `nil` 이고, 그때 단음절 교정은 **전부** 사라진다
/// (fail-closed). 오늘보다 엄격한 상태로 퇴화하므로 자산 사고가 파괴로 이어지지
/// 않는다 — 파괴를 막는 쪽이 교정을 놓치는 쪽보다 우선한다는 원칙 그대로다.
struct MonosyllableLexicon {
    /// 키열 → 한글 1음절.
    private let entries: [String: String]

    init(entries: [String: String]) {
        self.entries = entries
    }

    init?(bundle: Bundle) {
        guard let url = bundle.url(forResource: "ko-mono.v1", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        let parsed = Self.parse(text)
        guard !parsed.isEmpty else { return nil }
        self.init(entries: parsed)
    }

    /// `키열<TAB>한글<TAB>부류`.
    ///
    /// 3열인 이유는 자산 자체가 감사 가능해야 하기 때문이다 — 어느 행이 오늘의
    /// 동결(`keep`)이고 어느 행이 새로 연 것인지가 파일 안에서 보여야 리뷰가
    /// 성립한다. 부류는 리뷰·감사용이므로 여기서는 읽고 버린다.
    static func parse(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, !parts[0].isEmpty, !parts[1].isEmpty else { continue }
            // 파일은 NFC 로 생성되지만 읽는 쪽에서도 정규화를 강제한다. 자소 분리
            // (NFD)가 섞이면 `count`(백스페이스 횟수)와 `utf16.count`(AX 캐럿
            // 오프셋)가 갈라져 되돌리기의 삭제량과 앵커 검증이 동시에 깨진다.
            out[String(parts[0])] = String(parts[1]).precomposedStringWithCanonicalMapping
        }
        return out
    }

    /// 대소문자를 **접지 않는다.** 두벌식에서 Shift 는 다른 자모(ㅃㅉㄸㄲㅆㅒㅖ)를
    /// 만들므로, 접는 순간 `dP`(예)와 `dp`(에)가 한 칸이 된다. 자산에 없는 표기
    /// 변형은 조회에 실패해 보존된다 — fail-closed 다.
    func resolve(latin: String) -> String? {
        entries[latin]
    }

    /// 엔진이 만든 한글과 자산이 주장하는 한글이 **같은지까지** 대조한다.
    ///
    /// 다르면 조합 오토마톤과 자산이 어긋났다는 뜻이고, 그때 신뢰해야 할 것은 어느
    /// 쪽도 아니다. 이 등호 덕분에 파괴가 일어나려면 해시로 동결된 자산과 pre-imk
    /// 로 동결된 조합기가 **동시에** 틀려야 한다.
    func confirms(latin: String, hangul: String) -> Bool {
        guard let expected = entries[latin] else { return false }
        return expected == hangul.precomposedStringWithCanonicalMapping
    }
}
