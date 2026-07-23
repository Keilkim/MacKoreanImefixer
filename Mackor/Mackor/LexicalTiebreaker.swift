import Foundation

/// Layer 1 — v4 규칙이 가르지 못한 토큰을 어휘로 판정합니다.
///
/// v4 규칙 엔진은 키열을 한국어·영어 두 문법으로 채점해 판정하는데, 두 문법을
/// **모두** 만족하는 토큰(`ambiguousBothValid`)은 키열만으로 구분할 수 없어
/// 보존합니다. 실측하면 한국어 어절의 1.97%가 여기 걸리고, 그중 대부분은
/// "한글은 실제 단어인데 영어 쪽은 아무 뜻 없는 글자 나열"입니다.
/// `만들다`(aksemfek)·`캐나다`(zoskek)·`배관`(qorhks)·`문맥`(ansaor)이 그 예로,
/// 지금까지 전부 영어로 보존되고 있었습니다.
///
/// 이 계층은 그 분기에서만 사전을 참조해 한쪽만 실단어면 그쪽으로 확정합니다.
/// 둘 다 실단어면(`ahem`↔`모드`처럼 진짜 both-valid) 보존을 유지합니다.
///
/// ## 왜 NSSpellChecker를 쓰지 않는가
///
/// 실측 결과 `NSSpellChecker`는 사전이 아니라 **관대한 승인기**입니다. 임의의
/// KS X 1001 단일 음절 2,350자 중 1,108자(47%)를 통과시키고 `먀그무`·`퍅셔미`
/// 같은 비단어도 인정합니다. OS 버전과 사용자 학습 사전에 따라 결과가 달라져
/// 파이썬 레퍼런스와 파리티를 맺을 수도 없습니다.
///
/// ## 왜 "투영"인가
///
/// 원본 사전은 저장소에 고정할 수 없습니다(영어 사전은 2.49 MB짜리 OS 자산).
/// 그런데 이 계층은 `ambiguousBothValid`에 도달한 키열만 조회하므로, **그 분기에
/// 도달할 수 있는 항목만 남긴 투영**이 판정에 대해 무손실입니다. 24 KB로 줄어
/// 저장소에 커밋하고 해시로 고정할 수 있게 되고, 그래야 파이썬 레퍼런스와 Swift가
/// **같은 파일**을 읽는다는 파리티 요구가 실제로 집행됩니다.
/// 무손실성은 `scripts/lexicon/make_lexicon.py verify`가 전수 대조로 검증합니다.
///
/// 한국어 쪽을 문자열 집합이 아니라 **키열 → 한글 매핑**으로 둔 이유도 같습니다.
/// 이러면 Swift가 한글 조합을 전혀 수행하지 않아, 두 언어의 조합 오토마톤이
/// 미세하게 달라 발산할 위험이 통째로 사라집니다.
struct LexicalTiebreaker {
    /// 키열 → 한글. 이 키열의 한글 해석이 실제 한국어 단어인 경우만 들어 있습니다.
    private let korean: [String: String]
    /// 소문자로 접은 키열. 이 키열이 실제 영어 단어인 경우만 들어 있습니다.
    private let english: Set<String>

    init(korean: [String: String], english: Set<String>) {
        self.korean = korean
        self.english = english
    }

    /// 앱 번들의 고정 사전을 읽습니다. 자산이 없으면 `nil`을 반환해 호출자가
    /// 이 계층 없이(= 오늘과 동일하게) 동작하도록 합니다.
    init?(bundle: Bundle) {
        guard let koreanURL = bundle.url(forResource: "ko-lexicon.v1", withExtension: "txt"),
              let englishURL = bundle.url(forResource: "en-lexicon.v1", withExtension: "txt"),
              let koreanText = try? String(contentsOf: koreanURL, encoding: .utf8),
              let englishText = try? String(contentsOf: englishURL, encoding: .utf8) else {
            return nil
        }
        self.init(
            korean: Self.parseKoreanLexicon(koreanText),
            english: Self.parseEnglishLexicon(englishText)
        )
    }

    static func parseKoreanLexicon(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            // 파일은 NFC로 생성되지만, 읽는 쪽에서도 정규화를 강제해 자소 분리
            // 표기가 섞여 들어와도 조회가 어긋나지 않게 합니다.
            out[String(parts[0])] = String(parts[1]).precomposedStringWithCanonicalMapping
        }
        return out
    }

    static func parseEnglishLexicon(_ text: String) -> Set<String> {
        Set(
            text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        )
    }

    /// 영어 조회용 정규화 — 정책 C(소문자 fold + 어중 대문자 veto).
    ///
    /// 두벌식에서 Shift는 **다른 자모**(ㅃㅉㄸㄲㅆㅒㅖ)를 만들지만, 영어에서 Shift는
    /// **같은 단어의 표기 변형**입니다. 그래서 대소문자는 한국어 쪽에서만 의미를 집니다.
    ///
    /// 어두 대문자(고유명사·문장 첫 단어)는 정상 영어이므로 소문자로 접습니다.
    /// 어중 대문자는 영어 정서법 위반이므로 영어가 아닌 것으로 봅니다 — 이게
    /// `내꾸`를 지켜줍니다. `내꾸`의 키열은 `soRn`인데(ㄲ가 Shift+R), 통째로 소문자로
    /// 접으면 스코틀랜드 방언 `sorn`에 걸려 교정이 막힙니다.
    /// 전대문자는 이 분기에 오기 전에 `acronymConvention`이 이미 걸러내므로,
    /// 여기 남는 경우는 정확히 어중 대문자입니다.
    ///
    /// 영어로 볼 수 없으면 `nil`을 반환합니다.
    static func englishLookupKey(_ keys: String) -> String? {
        if keys.dropFirst().contains(where: { $0.isUppercase }) { return nil }
        return keys.lowercased()
    }

    /// 이 키열을 한글로 확정해야 하면 그 한글을, 아니면 `nil`을 반환합니다.
    ///
    /// 호출 계약: v4 규칙이 `ambiguousBothValid`를 낸 키열에 대해서만 호출합니다.
    /// 다른 분기에 개입하면 동결된 판정이 바뀝니다.
    ///
    /// 이 자산은 **1음절 항목을 갖지 않습니다** — 원본 `ko_words.txt`에 1음절 어절이
    /// 0개라 구조적으로 그렇습니다. 그 성질이 `MonosyllableLexicon` 관문과의 분리를
    /// 지탱합니다: 두 자산의 키가 겹치지 않으므로, 단음절 관문이 여기서 확정된 교정을
    /// 죽일 수 없습니다. `make_mono_lexicon.py verify` 불변식 9와
    /// `MonosyllableLexiconTests` 가 양쪽에서 강제합니다.
    ///
    /// `nil`은 "보존" — 즉 오늘과 완전히 같은 동작입니다. 사전에 없는 한국어는
    /// 후퇴가 아니라 현상 유지이므로 이 계층은 fail-safe입니다.
    func resolve(latin: String) -> String? {
        guard let korean = korean[latin] else { return nil }
        if let key = Self.englishLookupKey(latin), english.contains(key) { return nil }
        return korean
    }
}
