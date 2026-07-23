import Foundation

/// 동결 엔진 **밖**의 최종 거부권·강화 계층.
///
/// v4 규칙 엔진(`LayoutCorrectionPolicy`)은 사전 없이 구조만으로 판정하는데,
/// 그 결과 "조합만 되면 바꾸는" 파괴적 오교정이 남습니다. 실사용 예:
/// - `ㅁㅊ`(미친) → `ac` — `ac`는 실제 단어가 아닌데 굳어진 자모 표현을 파괴
/// - `dns` → `운` — `dns`는 실사용 약어인데 `운`은 단독으로 쓰지 않음
///
/// 엔진 자산은 pre-imk 태그와 바이트 단위로 동결돼 있어(engine-freeze.sha256,
/// CI가 태그 diff로 강제) 규칙 자체를 고칠 수 없습니다. 이 계층은 동결 밖에서,
/// 엔진이 이미 낸 `.correct` 판정에 대해서만 개입합니다.
///
/// ## 예시 나열이 아니라 구조와 데이터로 판정한다
///
/// `ㅁㅊ`·`ㅇㅈ`·`dns`·`sns`를 손으로 나열하면 끝이 없습니다. 대신:
///
/// 1. **영→한 단음절 관문**: 결과가 한글 **정확히 한 음절**이면, 그 키열이 동결
///    자산(`ko-mono.v1.txt`)에 그 음절로 등재돼 있을 때만 통과합니다.
///
///    이전 기준은 "원문에 영어 모음(aeiou)이 없으면 약어"라는 구조 추정이었고,
///    그것은 증거가 아니라 대리 지표였습니다. 실측하면 그 게이트가 막는 3키
///    단음절 1,208개 중 **영어 사전 단어는 0개**이고, 반대로 통과시키는 435개
///    중 265개는 19,895어절 코퍼스에 한 번도 안 나오는 음절입니다 —
///    `cma`→츰이 정확히 그 형태로 살아 있었습니다. 두벌식에서 라틴 모음
///    a·e·i·o·u 는 ㅁ·ㄷ·ㅑ·ㅐ·ㅕ 일 뿐이라, 모음의 유무는 한국어 단어성과도
///    영어 단어성과도 아무 관계가 없습니다.
///
///    (옛 주석이 이 게이트의 보호 대상으로 들던 `css`·`anf`는 실측상 틀린
///    예였습니다. `css`는 두벌식으로 `ㅊㄴㄴ`(음절 0)이라 여기 **도달조차
///    하지 않고**, `anf`→물은 `ambiguousBothValid`라 아래 첫 줄에서 이미
///    빠져나갑니다. 유효한 통과 예는 `dho`→왜뿐이었습니다.)
///
///    이 관문이 **앱 전체에서 한글 한 음절이 만들어질 수 있는 유일한 통로**여야,
///    이 계층이 낼 수 있는 최악의 결과가 자산 파일의 행 수로 상한이 잡힙니다.
///    엔진 경로·어휘 경로·방향 재판정 경로가 전부 `EventTapManager.resolveBoundary`
///    의 `guarded()` 한 곳을 지나므로 그 성질이 구조적으로 보장됩니다.
///
///    예외는 하나뿐입니다 — `ambiguousBothValid`(LexicalTiebreaker 경유)는 이미
///    실단어 확인이 끝난 곳이라 그대로 통과합니다. 그 예외가 구멍이 되지 않는
///    이유는 `ko-lexicon.v1.txt`에 1음절 값이 0개이기 때문이고, 그 사실은
///    `make_mono_lexicon.py verify` 불변식 9와 `MonosyllableLexiconTests`가
///    양쪽에서 강제합니다.
/// 2. **한→영 사전 게이트**: 원문이 순수 자음 자모(`ㅁㅊ`, `ㅈㄷ`)면 결과가
///    실제 영어 단어일 때만 교정합니다. `we`·`see`·`test`는 사전에 있어
///    교정되고(신뢰가 확인됐으므로 `medium→high`), `ac`·`tq`는 없어 보존됩니다.
///    굳어진 한국어 자모 표현을 나열하지 않아도, 그 영어 대응물이 단어가
///    아니라는 사실이 자동으로 지켜줍니다.
///
/// 사전은 손 목록이 아니라 `scripts/lexicon/make_guard_lexicon.py`가 OS 영어
/// 사전(`/usr/share/dict/words`)에서 생성한 투영입니다. 순수 자음 자모가 되는
/// 단어는 자음 자판 글자({q,w,e,r,t,a,s,d,f,g,z,x,c,v})만으로 적힌 단어뿐이라,
/// 그 부분집합만 남기면 이 게이트에 대해 무손실입니다 — `LexicalTiebreaker`의
/// 투영 철학 그대로입니다. 자산은 lexicon-freeze.sha256으로 고정합니다.
///
/// ## 개입 계약 — 기준은 여전히 규칙이다
///
/// - 거부권과 **등급 조정**만 행사합니다 — 한→영 순수 자음의 `medium→high` 강화와,
///   영→한 단음절의 `high→medium` 강등입니다. `preserve`를 `correct`로 바꾸는
///   일은 여전히 없습니다(새 교정 생성 금지). 원문·교정문·방향·글자 수도
///   바꾸지 않습니다.
/// - 단음절 강등은 판정을 바꾸지 않고 **되돌릴 기회를 넓히는** 변경입니다.
///   칩 수명이 4초에서 6초(= `undoLifetime`)로 늘어 Undo 창 전체를 덮습니다.
///   단음절 교정은 입력 소스까지 한글로 전환시키므로, 의도가 영어였을 때
///   사용자가 무는 비용이 글자 하나보다 큽니다.
/// - 등급을 바꿀 때는 `diagnostic`도 같은 등급으로 다시 만듭니다. 진단이 결정과
///   다른 등급을 말하면 로그 기반 디버깅이 어긋납니다.
/// - 사전으로 이미 확정된 판정(`ambiguousBothValid`, LexicalTiebreaker 경유)에는
///   개입하지 않습니다 — 거기는 실단어 확인이 끝난 곳입니다.
/// - 자산이 없으면 순수 자음 게이트도 단음절 관문도 fail-closed(보존)입니다.
///   단음절 교정이 **전부** 사라져 오늘보다 엄격한 상태로 퇴화하므로, 자산
///   사고가 파괴로 이어지지 않습니다. 파괴를 막는 쪽이 교정을 놓치는 쪽보다
///   우선합니다.
///
/// 호출 지점은 `EventTapManager.resolveBoundary` 하나 — 엔진·어휘·방향 재판정
/// 세 경로가 전부 그 출구를 지나므로, 일반 경로와 방향 재판정 경로가 같은
/// 최종 resolver를 쓴다는 요구가 구조적으로 충족됩니다.
enum LexicalGuard {

    /// 번들된 guard 사전을 읽습니다. 자산이 없으면 `nil` — 호출자는 순수 자음
    /// 게이트를 fail-closed(보존)로 운용합니다.
    static func loadEnglishEvidence(bundle: Bundle) -> Set<String>? {
        guard let url = bundle.url(forResource: "en-guard.v1", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        return parseEnglishEvidence(text)
    }

    static func parseEnglishEvidence(_ text: String) -> Set<String> {
        Set(text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init))
    }

    /// 엔진이 낸 `.correct` 결정에 거부권·강화를 적용합니다.
    ///
    /// - 반환 `nil`: 교정하지 않고 보존합니다(원문 무사).
    /// - 반환 결정: 통과(그대로) 또는 등급만 올린 사본.
    /// - Parameter monosyllables: 영→한 단음절 관문의 동결 자산. 기본값이 `nil`인
    ///   이유는 fail-closed 를 기본으로 두기 위해서입니다 — 자산 전달을 잊은
    ///   미래의 호출부는 단음절 교정을 **하지 못하는** 쪽으로 떨어집니다.
    static func apply(
        _ decision: CorrectionDecision,
        englishEvidence: Set<String>?,
        monosyllables: MonosyllableLexicon? = nil
    ) -> CorrectionDecision? {
        // LexicalTiebreaker가 실단어 확인을 끝낸 판정에는 개입하지 않습니다.
        guard decision.rule != .ambiguousBothValid else { return decision }

        switch decision.direction {
        case .latinToKorean:
            // 단음절 관문. 자산이 이 키열의 한글을 확인해 줄 때만 통과한다.
            //
            // 조회 키는 소문자로 접은 값이 아니라 **원문 그대로**다 — 두벌식에서
            // Shift 는 다른 자모(ㅃㅉㄸㄲㅆㅒㅖ)를 만들어, 접으면 다른 음절을
            // 조회하게 된다(`dP`=예 ≠ `dp`=에).
            //
            // 자산이 **다른** 한글을 적고 있으면 거부한다. 자산과 엔진이
            // 어긋났다는 뜻이고, 그때 신뢰해야 할 것은 어느 쪽도 아니다.
            //
            // 자산이 없으면 `confirms` 가 false 이므로 단음절 교정이 전부
            // 사라진다 — 오늘보다 엄격한 방향이라 자산 사고가 파괴를 만들지 못한다.
            if hangulSyllableCount(decision.replacement) == 1 {
                guard monosyllables?.confirms(
                    latin: decision.original,
                    hangul: decision.replacement
                ) == true else {
                    return nil
                }
                return retiered(decision, .medium)
            }
            return decision

        case .koreanToLatin:
            // 순수 자음 자모 원문은 (a) 자음 자판 글자만으로 친 실제 영어
            // 단어이거나 (b) 굳어진 한국어 자모 표현·매시다. 사전이 (a)를
            // 확인해 주면 확신을 올려 교정하고, 아니면 원문을 보존한다.
            guard isAllCompatibilityConsonants(decision.original) else {
                return decision
            }
            guard let evidence = englishEvidence,
                  let key = LexicalTiebreaker.englishLookupKey(decision.replacement),
                  evidence.contains(key) else {
                return nil
            }
            // 자음 매시 구제(`consonantJamoMash`)는 구조가 '보존'으로 판정한 것을
            // 사전 증거만으로 뒤집은 결정이라 확신이 낮다. medium 을 유지해 원문
            // 칩을 6초(= Undo 창) 내내 강조한다 — 엔진이 이미 교정하기로 한 순수
            // 자음 결정(`englishStructure`·`markedEnglishForm`)의 medium→high
            // 승격과 구분한다.
            if decision.rule == .consonantJamoMash {
                return retiered(decision, .medium)
            }
            return retiered(decision, .high)
        }
    }

    // MARK: - 등급 조정

    /// 등급만 바꾼 사본.
    ///
    /// 원문·교정문·방향·글자 수는 그대로고, **진단도 같은 등급으로 다시 만든다.**
    /// 예전에는 진단을 그대로 물려줘 `decision.tier` 와 `diagnostic.tier` 가
    /// 어긋났는데, 그러면 로그가 결정과 다른 등급을 말해 디버깅이 어긋난다.
    private static func retiered(
        _ decision: CorrectionDecision,
        _ tier: LayoutCorrectionPolicy.Tier
    ) -> CorrectionDecision {
        guard decision.tier != tier else { return decision }
        let diagnostic = decision.diagnostic.map {
            CorrectionDiagnostic(
                direction: $0.direction,
                tier: tier,
                rule: $0.rule,
                tokenLength: $0.tokenLength,
                boundary: $0.boundary
            )
        }
        return CorrectionDecision(
            original: decision.original,
            replacement: decision.replacement,
            direction: decision.direction,
            tier: tier,
            rule: decision.rule,
            diagnostic: diagnostic
        )
    }

    // MARK: - 문자 분류

    /// 이 값이 1이면 단음절 관문이 걸린다. 그러므로 **세는 데 실패하면 관문을
    /// 건너뛴다** — 세기 전에 NFC로 정규화하는 이유다. 동결 조합기는 항상 완성형
    /// 음절을 만들지만(`HangulUnicode.buildString`), 그 사실에 기대면 조합기가
    /// 바뀌는 날 관문이 조용히 열린다. 관문의 트리거는 스스로 방어해야 한다.
    private static func hangulSyllableCount(_ text: String) -> Int {
        text.precomposedStringWithCanonicalMapping
            .unicodeScalars
            .filter { (0xAC00...0xD7A3).contains($0.value) }
            .count
    }

    private static func isAllCompatibilityConsonants(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        return text.unicodeScalars.allSatisfy { (0x3131...0x314E).contains($0.value) }
    }
}
