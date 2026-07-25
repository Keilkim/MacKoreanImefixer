import XCTest

/// 단음절 관문 자산(`scripts/lexicon/ko-mono.v1.txt`)과 그 조회 계층의 계약을 고정한다.
///
/// 이 자산은 단음절 도메인에서 **한글 한 음절이 만들어질 수 있는 유일한 통로**다.
/// 따라서 여기서 고정해야 하는 것은 두 가지다 — 사용자가 지목한 통증이 실제로
/// 해결되는가(양성), 그리고 파괴적 오교정이 자산에 유입되지 않았는가(음성).
///
/// 자산 로딩에 `Bundle` 을 쓰지 않는다: 테스트 타깃에는 Resources 빌드 페이즈가
/// 없어 번들 조회가 원리적으로 실패한다. 저장소 **원본**을 `#filePath` 로 읽는
/// 것이 이 저장소의 관용구다(`LexicalGuardTests` 와 동일). 번들 사본이 어긋나는
/// 사고는 CI 의 `Verify bundled lexicon resources` 가 따로 잡는다.
final class MonosyllableLexiconTests: XCTestCase {

    private struct Row {
        let keys: String
        let hangul: String
        let provenance: String
    }

    // MARK: - 파리티

    /// 파이썬 레퍼런스가 만든 fixture 전 행과 Swift 조회가 한 행도 어긋나지 않는지.
    func testFixtureMatchesTheSwiftImplementation() throws {
        let lexicon = try loadLexicon()
        let rows = try loadFixture()
        XCTAssertGreaterThanOrEqual(rows.count, 500, "fixture 가 비정상적으로 작습니다")

        var mismatches: [String] = []
        for (keys, action, replacement) in rows {
            let resolved = lexicon.resolve(latin: keys)
            let actual = resolved == nil ? "preserve" : "correct"
            if actual != action {
                mismatches.append("\(keys): action 기대 \(action), 실제 \(actual)")
                continue
            }
            if action == "correct", resolved != replacement {
                mismatches.append(
                    "\(keys): replacement 기대 \(replacement), 실제 \(resolved ?? "nil")"
                )
            }
        }
        XCTAssertTrue(
            mismatches.isEmpty,
            "레퍼런스와 어긋난 행 \(mismatches.count)개:\n" + mismatches.prefix(20).joined(separator: "\n")
        )
    }

    /// 자산 전 행을 **동결 조합기로 독립 재조합**해 대조한다.
    ///
    /// 파이썬이 만든 것을 파이썬으로 재확인하는 fixture 보다 강한 검사다 — 서로
    /// 다른 두 구현이 같은 결론에 도달해야 하므로 생성기 버그와 자산 오타가
    /// 둘 다 잡힌다. 런타임 교차확인(`monosyllableCorrection`)이 기대는 성질을
    /// 여기서 전수로 못 박는다.
    func testAssetKeysReplayTheFrozenAutomaton() throws {
        var mismatches: [String] = []
        for row in try loadAsset() {
            guard let keystrokes = PhysicalKeystrokeFixture.keystrokes(row.keys) else {
                mismatches.append("\(row.keys): 지원하지 않는 키")
                continue
            }
            guard let composed = HangulStructure.evaluate(keystrokes) else {
                mismatches.append("\(row.keys): 조합 실패")
                continue
            }
            if composed.text.precomposedStringWithCanonicalMapping != row.hangul {
                mismatches.append("\(row.keys): 조합 \(composed.text) != 자산 \(row.hangul)")
            }
            if composed.syllableCount != 1 || composed.jamoCount != 0 {
                mismatches.append(
                    "\(row.keys): 음절 \(composed.syllableCount) 낱자모 \(composed.jamoCount)"
                )
            }
        }
        XCTAssertTrue(
            mismatches.isEmpty,
            "동결 조합기와 어긋난 행 \(mismatches.count)개:\n" + mismatches.prefix(20).joined(separator: "\n")
        )
    }

    /// 모든 값이 현대 한글 **정확히 한 음절**이어야 한다.
    ///
    /// `count == utf16.count == 1` 까지 보는 이유: 되돌리기는 `count`(백스페이스
    /// 횟수)로 지우고 AX 앵커는 `utf16.count`(캐럿 오프셋)로 검증한다. 자소 분리
    /// 표기가 섞이면 그 둘이 갈라져 삭제량과 앵커가 동시에 어긋난다.
    func testEveryValueIsExactlyOneHangulSyllable() throws {
        for row in try loadAsset() {
            XCTAssertEqual(row.hangul.count, 1, "\(row.keys): 값이 한 글자가 아닙니다")
            XCTAssertEqual(row.hangul.utf16.count, 1, "\(row.keys): UTF-16 길이가 1이 아닙니다")
            let scalars = Array(row.hangul.unicodeScalars)
            XCTAssertEqual(scalars.count, 1, "\(row.keys): 스칼라가 1개가 아닙니다")
            if let value = scalars.first?.value {
                XCTAssertTrue(
                    (0xAC00...0xD7A3).contains(value),
                    "\(row.keys): 현대 한글 음절 범위 밖입니다"
                )
            }
        }
    }

    /// 자소 분리(NFD)로 적힌 자산이 들어와도 NFC 로 저장된다.
    ///
    /// `String ==` 은 정준 동치로 비교하므로 NFD/NFC 를 구분하지 못한다. 그래서
    /// 여기서 봐야 하는 것은 문자열 동일성이 아니라 **표현**이다 — 되돌리기는
    /// `count`(백스페이스 횟수)로 지우고 AX 앵커는 `utf16.count`(캐럿 오프셋)로
    /// 검증하는데, NFD 가 그대로 저장되면 `utf16.count` 만 3이 되어 그 둘이
    /// 갈라지고 삭제량과 앵커가 동시에 어긋난다.
    func testLexiconParsingNormalisesToNFC() {
        let decomposed = "로".decomposedStringWithCanonicalMapping
        // 로 = ㄹ + ㅗ (종성 없음) 이므로 NFD 는 자모 2개다.
        XCTAssertEqual(decomposed.unicodeScalars.count, 2, "테스트 전제: NFD 는 자모로 쪼개집니다")

        let lexicon = MonosyllableLexicon(
            entries: MonosyllableLexicon.parse("fh\t\(decomposed)\t조사\n")
        )
        let stored = lexicon.resolve(latin: "fh")
        XCTAssertEqual(stored, "로")
        XCTAssertEqual(stored?.unicodeScalars.count, 1, "NFD 가 그대로 저장됐습니다")
        XCTAssertEqual(stored?.utf16.count, 1, "utf16 길이가 1이 아니면 AX 앵커가 어긋납니다")
        XCTAssertEqual(stored?.count, stored?.utf16.count)
        // 조합기가 NFD 를 넘겨도 교차확인이 성립해야 한다.
        XCTAssertTrue(lexicon.confirms(latin: "fh", hangul: decomposed))
    }

    /// 대소문자를 접으면 안 된다 — 두벌식에서 Shift 는 **다른 자모**다.
    func testLookupIsCaseExact() throws {
        let lexicon = try loadLexicon()
        XCTAssertEqual(lexicon.resolve(latin: "Rp"), "께")
        XCTAssertNil(lexicon.resolve(latin: "rp"), "대소문자를 접으면 다른 음절을 조회합니다")
        // `dP`(예)와 `dp`(에)는 **서로 다른 음절**이다. 둘 다 자산에 있지만 접으면
        // 안 된다 — 접는 순간 한쪽이 다른 쪽 자리를 차지한다.
        XCTAssertEqual(lexicon.resolve(latin: "dP"), "예")
        XCTAssertEqual(lexicon.resolve(latin: "dp"), "에")
    }

    /// 자산이 없으면 단음절 교정이 전부 사라진다(fail-closed).
    func testMissingAssetDegradesToNil() {
        let empty = MonosyllableLexicon(entries: [:])
        for keys in ["fh", "dy", "dk", "sp", "dh", "fmf", "sms"] {
            XCTAssertNil(empty.resolve(latin: keys))
            XCTAssertFalse(empty.confirms(latin: keys, hangul: "로"))
        }
    }

    // MARK: - 사용자 통증 (양성)

    /// 사용자가 지목한 사례 7개. 이 테스트가 이 작업의 존재 이유다.
    func testRepositoryAssetCoversReportedCases() throws {
        let lexicon = try loadLexicon()
        let expected = [
            "fh": "로", "dy": "요", "dk": "아", "sp": "네",
            "dh": "오", "fmf": "를", "sms": "는",
        ]
        for (keys, hangul) in expected {
            XCTAssertEqual(lexicon.resolve(latin: keys), hangul, "\(keys) 가 교정되지 않습니다")
        }
    }

    // MARK: - 파괴 방지 (음성)

    /// 소문자 약어·식별자는 자산에 있으면 안 된다.
    /// `cma`(→츰)는 **오늘 실제로 파괴 중**인 사례이고, 이 행이 그것을 닫는다.
    ///
    /// `mono-admit.tsv` 로 명시적으로 연 키열은 여기 없다 — 그건 위험을 알고 내린
    /// 결정이며, 아래 `testAdmittedKeysAreOpenedDeliberately` 가 따로 고정한다.
    func testRepositoryAssetExcludesAbbreviations() throws {
        let lexicon = try loadLexicon()
        let abbreviations = [
            "dns", "sns", "xml", "tls", "fps", "skt", "smt", "thx", "gmt", "dhl",
            "cma", "rm", "du", "dir",
        ]
        for keys in abbreviations {
            XCTAssertNil(lexicon.resolve(latin: keys), "\(keys) 가 자산에 있습니다 — 약어를 파괴합니다")
        }
    }

    /// 실제 영어 단어인 키열은 자산에 있으면 안 된다.
    /// `dha`(→옴)는 **오늘 파괴 중**이며 영어 사전 게이트가 닫는다.
    func testRepositoryAssetExcludesEnglishWords() throws {
        let lexicon = try loadLexicon()
        // `sla`·`sha`·`rhe`·`wha` 는 mono-admit.tsv 로 **의도적으로 열었다**
        // (1934년 웹스터의 사어·방언이라 현대 영어 문장에 단독으로 안 나온다).
        // 아래 testAdmittedKeysAreOpenedDeliberately 가 그쪽을 고정한다.
        //
        // `sus`(년)·`go`(해) 는 열었다가 되돌렸다. 양쪽 다 흔한 말이면 손대지
        // 않는 것이 원칙이다 — 파괴는 비대칭적으로 비싸다. `go `는 영어에서
        // 가장 흔한 동사 중 하나이고, `sus` 는 결과가 욕설로 읽힐 수 있다.
        let words = [
            "an", "sh", "th", "do", "so", "to", "en", "ao", "wo",
            "sus", "dha", "go",
        ]
        for keys in words {
            XCTAssertNil(lexicon.resolve(latin: keys), "\(keys) 가 자산에 있습니다 — 영어를 파괴합니다")
        }
    }

    /// **의도적으로 연** 키열. 게이트가 막던 것을 사람이 판단으로 뒤집은 목록이다.
    ///
    /// 이 테스트가 있는 이유는 두 가지다. 하나는 조사·대명사가 실제로 교정되는지
    /// 고정하는 것이고, 다른 하나는 **이게 사고가 아니라 결정이었다는 기록**이다.
    /// `go`→해 처럼 영어 문장 중 오교정이 실제로 가능한 항목이 들어 있으므로,
    /// 되돌릴 때는 `scripts/lexicon/mono-admit.tsv` 에서 해당 줄을 지운다.
    func testAdmittedKeysAreOpenedDeliberately() throws {
        let lexicon = try loadLexicon()
        let admitted = [
            "eh": "도", "dl": "이", "dml": "의", "dp": "에", "sk": "나",
            "tl": "시", "ch": "초", "wp": "제", "gh": "호",
            "ro": "개", "di": "야", "Eh": "또", "aht": "못",
            "sla": "님", "sha": "놈", "rhe": "곧", "wha": "좀", "Rho": "꽤",
        ]
        for (keys, hangul) in admitted {
            XCTAssertEqual(
                lexicon.resolve(latin: keys), hangul,
                "\(keys)→\(hangul) 가 열려 있지 않습니다"
            )
        }
        // 대소문자는 여전히 접지 않는다 — `Eh`(또)와 `eh`(도)는 다른 음절이다.
        XCTAssertEqual(lexicon.resolve(latin: "Eh"), "또")
        XCTAssertEqual(lexicon.resolve(latin: "eh"), "도")
    }

    // MARK: - 자산 분리 · 경계

    /// `ambiguousBothValid` 분기의 주인은 `LexicalTiebreaker` 하나여야 한다.
    ///
    /// 두 자산의 키가 겹치거나 `ko-lexicon` 에 1음절 값이 생기면, tiebreaker 가
    /// 무손실 증명과 함께 확정한 교정을 단음절 관문이 조용히 죽일 수 있다.
    func testRepositoryAssetIsDisjointFromTiebreakerLexicon() throws {
        let monoKeys = Set(try loadAsset().map(\.keys))
        let text = try String(
            contentsOf: Self.lexiconDirectory.appendingPathComponent("ko-lexicon.v1.txt"),
            encoding: .utf8
        )
        var tiebreakerKeys: Set<String> = []
        var monosyllableValues = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            tiebreakerKeys.insert(String(parts[0]))
            if parts[1].count == 1 { monosyllableValues += 1 }
        }
        XCTAssertTrue(
            monoKeys.isDisjoint(with: tiebreakerKeys),
            "두 자산이 겹칩니다: \(Array(monoKeys.intersection(tiebreakerKeys)).prefix(5))"
        )
        XCTAssertEqual(monosyllableValues, 0, "ko-lexicon 에 1음절 값이 생겼습니다 — 보류 전제가 깨집니다")
    }

    /// 사전 출처가 실제로 일상어를 열었는지 고정한다.
    ///
    /// 출처는 셋이다 — `keep`(동결 엔진이 이미 하던 교정), 사람이 부류별로 선언한 것,
    /// 그리고 `사전`(macOS 한국어 맞춤법 검사기가 단어로 인정한 음절). 마지막 것을
    /// 넣기 전에는 부류 상한이 커버리지를 제한해 `온`·`첫`·`길`·`축` 같은 일상어가
    /// 그냥 빠져 있었다.
    func testDictionarySourceOpensEverydayWords() throws {
        let lexicon = try loadLexicon()
        let expected = [
            "dhs": "온", "cjt": "첫", "rlf": "길", "cnr": "축", "Qjs": "뻔",
            "xhd": "통", "vks": "판", "vhr": "폭", "Tlr": "씩",
            "rkqt": "값", "sjrt": "넋", "Rhc": "꽃", "dnpq": "웹",
        ]
        for (keys, hangul) in expected {
            XCTAssertEqual(lexicon.resolve(latin: keys), hangul, "\(keys)→\(hangul) 가 열려 있지 않습니다")
        }
    }

    /// 사전 출처가 열 수 있는 키열의 형태를 고정한다.
    ///
    /// 2키는 약어로 포화된 공간이라(db·ep·co·fl·wl·xl·rh) 자동 출처가 열면 안 되고,
    /// 어중 대문자(`dPs`)는 `english_lookup_key` 가 nil 이라 **어떤 게이트도 적용되지
    /// 않으므로** 자동 출처가 열면 관문을 우회하는 것과 같다. 둘 다 사람이
    /// `mono-source.ko.tsv` 나 `mono-admit.tsv` 에 사유와 함께 적을 때만 열린다.
    func testDictionarySourceShapeIsConstrained() throws {
        for row in try loadAsset() where row.provenance == "사전" {
            XCTAssertGreaterThanOrEqual(row.keys.count, 3, "\(row.keys): 사전 출처가 2키를 열었습니다")
            let tail = row.keys.dropFirst()
            XCTAssertFalse(
                tail.contains(where: { $0.isUppercase }),
                "\(row.keys): 사전 출처가 어중 대문자를 열었습니다 — 게이트가 적용되지 않습니다"
            )
        }
    }

    /// 흔한 약어·확장자·식별자는 자산에 없어야 한다. 자산이 커질수록 중요하다.
    func testAssetExcludesCommonAbbreviationsAfterExpansion() throws {
        let lexicon = try loadLexicon()
        let abbreviations = [
            "dmg", "zip", "pdf", "png", "jpg", "svg", "csv", "log", "tmp", "exe",
            "api", "sdk", "cli", "gui", "url", "ssh", "ssl", "cdn", "cpu", "gpu",
            "ram", "usb", "sql", "npm", "git", "aws", "env", "var", "doc", "img",
            // 사전 출처 확장이 데려왔다가 검증에서 되돌린 것들
            "cls", "chr", "thr", "tld", "tos", "rhs", "qos", "vnd", "rnd", "dnf",
            "dlq", "cnf", "smd", "wls", "fhs", "dps", "vps", "xhr", "tps", "rps",
            "wms", "wps", "tns", "qhd", "fhd", "dpr", "dpf", "dls", "dur", "dif",
        ]
        for keys in abbreviations {
            XCTAssertNil(lexicon.resolve(latin: keys), "\(keys) 가 자산에 있습니다 — 약어를 파괴합니다")
        }
    }

    /// 파괴 표면의 크기 자체를 고정한다. 자산이 조용히 자라면 여기서 걸린다.
    ///
    /// 상한은 `make_mono_lexicon.py` 의 `SURFACE_LIMIT` 과 같은 값을 유지한다.
    /// 600 → 620: `ambiguousBothValid` 보류를 걷어내며 선언된 일상 단음절 12개
    /// (돼 든 들 듯 등 딴 만 명 몇 백 열 편)가 자산에 들어왔다. 그 보류는
    /// LexicalTiebreaker 로 넘기는 것이었는데 그쪽 자산에 1음절이 0개라(바로 위
    /// 테스트가 고정) 넘길 곳이 없어 버려지고 있었다. 12개 전부 영어 사전·
    /// $PATH·로케일 게이트를 통과한 키열이다.
    func testRepositoryAssetSizeIsBounded() throws {
        let rows = try loadAsset()
        XCTAssertGreaterThanOrEqual(rows.count, 400)
        XCTAssertLessThanOrEqual(rows.count, 1250, "파괴 표면이 상한을 넘었습니다")
        // `사전` = macOS 한국어 맞춤법 검사기가 단어로 인정한 음절(자동 출처).
        let allowed: Set<String> = [
            "keep", "사전", "조사", "대명사", "의존명사", "수관형사", "감탄사", "부사", "용언활용",
        ]
        for row in rows {
            XCTAssertTrue(allowed.contains(row.provenance), "\(row.keys): 알 수 없는 부류 \(row.provenance)")
        }
    }

    /// `keep` 행은 **오늘 동결 엔진이 실제로 교정하는 것**이어야 한다.
    ///
    /// 이 계층은 관문이므로, 자산에 없는 것은 오늘 되던 것도 안 되게 만든다.
    /// 그 회귀를 Swift 쪽에서도 못 박는다.
    func testKeepRowsCoverTodaysLiveCorrections() throws {
        let rows = try loadAsset()
        let keep = rows.filter { $0.provenance == "keep" }
        // v4.3(R-E13 j+모음, R-E14 어중 대문자)에서 422→487: j+자음·어중 Shift
        // 키열의 단음절이 규칙 직접 교정으로 승격되며 "오늘 시행 중" 집합이 늘었다.
        XCTAssertEqual(keep.count, 487, "keep 행 수가 바뀌었습니다 — 오늘 동작이 달라졌습니까?")

        var mismatches: [String] = []
        for row in keep {
            guard let keystrokes = PhysicalKeystrokeFixture.keystrokes(row.keys) else {
                mismatches.append("\(row.keys): 지원하지 않는 키")
                continue
            }
            let decision = LayoutCorrectionPolicy.evaluate(
                keystrokes: keystrokes,
                inputSource: .supportedLatin
            )
            guard case .correct(_, _, let replacement, _) = decision else {
                mismatches.append("\(row.keys): 엔진이 교정하지 않습니다")
                continue
            }
            if replacement != row.hangul {
                mismatches.append("\(row.keys): 엔진 \(replacement) != 자산 \(row.hangul)")
            }
        }
        XCTAssertTrue(
            mismatches.isEmpty,
            "keep 행 불일치 \(mismatches.count)개:\n" + mismatches.prefix(20).joined(separator: "\n")
        )
    }

    // MARK: - 로딩

    private func loadLexicon() throws -> MonosyllableLexicon {
        let text = try String(
            contentsOf: Self.lexiconDirectory.appendingPathComponent("ko-mono.v1.txt"),
            encoding: .utf8
        )
        return MonosyllableLexicon(entries: MonosyllableLexicon.parse(text))
    }

    private func loadAsset() throws -> [Row] {
        let text = try String(
            contentsOf: Self.lexiconDirectory.appendingPathComponent("ko-mono.v1.txt"),
            encoding: .utf8
        )
        var rows: [Row] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else {
                XCTFail("자산 형식 오류: \(line)")
                continue
            }
            rows.append(
                Row(keys: String(parts[0]), hangul: String(parts[1]), provenance: String(parts[2]))
            )
        }
        return rows
    }

    private func loadFixture() throws -> [(String, String, String)] {
        let url = Self.repositoryRoot
            .appendingPathComponent("Corpus")
            .appendingPathComponent("lexical")
            .appendingPathComponent("v1")
            .appendingPathComponent("monosyllable.tsv")
        let text = try String(contentsOf: url, encoding: .utf8)
        var rows: [(String, String, String)] = []
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
            if index == 0 {
                XCTAssertEqual(String(line), "keys\taction\treplacement", "fixture 헤더가 바뀌었습니다")
                continue
            }
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count >= 2 else {
                XCTFail("fixture 형식 오류: \(line)")
                continue
            }
            let replacement = parts.count == 3 ? String(parts[2]) : ""
            rows.append((String(parts[0]), String(parts[1]), replacement))
        }
        return rows
    }

    private static var lexiconDirectory: URL {
        repositoryRoot.appendingPathComponent("scripts").appendingPathComponent("lexicon")
    }

    /// 번들 사본이 아니라 **저장소 원본**을 읽는다. 그래야 번들 복사가 빠지거나
    /// 어긋났을 때 이 테스트가 아니라 CI 의 별도 검사가 그 사실을 드러낸다.
    private static var repositoryRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return url
    }
}
