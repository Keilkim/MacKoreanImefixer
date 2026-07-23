import XCTest

/// `Corpus/lexical/v1/tiebreaker.tsv` 와 Swift `LexicalTiebreaker` 가 한 행도
/// 어긋나지 않는지 검증한다.
///
/// 이 자산은 v4 규칙 골든(`Corpus/structure-correction/v2`)과 **완전히 별개**다.
/// 골든은 사전을 전혀 참조하지 않는 규칙만 동결하고, 이 fixture 는 그 규칙이
/// `ambiguousBothValid` 로 보존한 뒤에 오는 어휘 계층만 검증한다. 두 자산을
/// 섞지 않는 이유는 R4-1 동결의 의미를 지키기 위해서다 — 규칙은 마이그레이션
/// 중 불변이어야 하고, 사전은 앞으로 자랄 자산이다.
///
/// fixture 는 파이썬 레퍼런스(`scripts/lexicon/tiebreak.py`)가 생성한다.
final class LexicalTiebreakerParityTests: XCTestCase {

    private struct Row {
        let keys: String
        let action: String
        let replacement: String
    }

    func testFixtureMatchesTheSwiftImplementation() throws {
        let tiebreaker = try loadTiebreaker()
        let rows = try loadFixture()
        XCTAssertGreaterThanOrEqual(rows.count, 300, "fixture 가 비정상적으로 작습니다")

        var mismatches: [String] = []
        for row in rows {
            let resolved = tiebreaker.resolve(latin: row.keys)
            let action = resolved == nil ? "preserve" : "correct"
            if action != row.action {
                mismatches.append("\(row.keys): action 기대 \(row.action), 실제 \(action)")
                continue
            }
            if row.action == "correct", resolved != row.replacement {
                mismatches.append(
                    "\(row.keys): replacement 기대 \(row.replacement), 실제 \(resolved ?? "nil")"
                )
            }
        }
        XCTAssertTrue(
            mismatches.isEmpty,
            "레퍼런스와 어긋난 행 \(mismatches.count)개:\n" + mismatches.prefix(20).joined(separator: "\n")
        )
    }

    /// 사용자가 실제로 겪은 사례가 회귀하지 않는지 못 박는다.
    /// 이 단어들은 전부 한글이 실단어이고 영어 키열은 아무 뜻이 없는데도
    /// 지금까지 영어로 보존되고 있었다.
    func testReportedPainWordsAreCorrected() throws {
        let tiebreaker = try loadTiebreaker()
        let expected = [
            "aksemfek": "만들다",
            "zoskek": "캐나다",
            "qorhks": "배관",
            "ansaor": "문맥",
            "sork": "내가",
            "guswo": "현재",
        ]
        for (keys, korean) in expected {
            XCTAssertEqual(tiebreaker.resolve(latin: keys), korean, "\(keys) 가 교정되지 않습니다")
        }
    }

    /// 진짜 both-valid 는 계속 보존해야 한다. 여기서 교정하면 영어를 치던
    /// 사용자의 입력을 뒤집는 오변환이 된다.
    func testGenuineBothValidStaysPreserved() throws {
        let tiebreaker = try loadTiebreaker()
        for keys in ["ahem", "dory", "flak", "thro", "work"] {
            XCTAssertNil(tiebreaker.resolve(latin: keys), "\(keys) 는 보존해야 합니다")
        }
    }

    /// 어중 대문자 veto(정책 C). `내꾸` 의 키열 `soRn` 은 ㄲ 때문에 Shift 가 섞여
    /// 있는데, 통째로 소문자로 접으면 방언 `sorn` 에 걸려 교정이 막힌다.
    func testInternalUppercaseIsNotFoldedToEnglish() throws {
        // `내꾸`(soRn)의 보호는 R-E14(어중 대문자 = 영어 아님)로 엔진에 승격됐다.
        // 이제 규칙이 직접 교정하므로 ambiguous 분기에 도달하지 않아 투영에서
        // 빠진다 — 사전 조회는 nil이고, 정책이 직접 한글로 확정한다.
        let tiebreaker = try loadTiebreaker()
        XCTAssertNil(tiebreaker.resolve(latin: "soRn"), "R-E14 이후 투영 밖이어야 합니다")
        guard let keystrokes = PhysicalKeystrokeFixture.keystrokes("soRn") else {
            return XCTFail("soRn 키열 변환 실패")
        }
        guard case .correct(_, _, let replacement, _) = LayoutCorrectionPolicy.evaluate(
            keystrokes: keystrokes,
            inputSource: .supportedLatin
        ) else {
            return XCTFail("내꾸가 규칙으로도 사전으로도 지켜지지 않습니다")
        }
        XCTAssertEqual(replacement, "내꾸")
        XCTAssertNil(LexicalTiebreaker.englishLookupKey("soRn"))
        // 어두 대문자는 정상 영어이므로 접어야 한다.
        XCTAssertEqual(LexicalTiebreaker.englishLookupKey("Sorn"), "sorn")
    }

    /// 사전 자산이 없으면 이 계층 없이(= 오늘과 동일하게) 동작해야 한다.
    func testMissingLexiconDegradesToPreserve() {
        let empty = LexicalTiebreaker(korean: [:], english: [])
        XCTAssertNil(empty.resolve(latin: "aksemfek"))
    }

    // MARK: - 로딩

    private func loadTiebreaker() throws -> LexicalTiebreaker {
        let dir = Self.repositoryRoot.appendingPathComponent("scripts").appendingPathComponent("lexicon")
        let koreanText = try String(
            contentsOf: dir.appendingPathComponent("ko-lexicon.v1.txt"), encoding: .utf8
        )
        let englishText = try String(
            contentsOf: dir.appendingPathComponent("en-lexicon.v1.txt"), encoding: .utf8
        )
        return LexicalTiebreaker(
            korean: LexicalTiebreaker.parseKoreanLexicon(koreanText),
            english: LexicalTiebreaker.parseEnglishLexicon(englishText)
        )
    }

    private func loadFixture() throws -> [Row] {
        let url = Self.repositoryRoot
            .appendingPathComponent("Corpus")
            .appendingPathComponent("lexical")
            .appendingPathComponent("v1")
            .appendingPathComponent("tiebreaker.tsv")
        let text = try String(contentsOf: url, encoding: .utf8)
        var rows: [Row] = []
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
            if index == 0 {
                XCTAssertEqual(String(line), "keys\taction\treplacement", "fixture 헤더가 바뀌었습니다")
                continue
            }
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else {
                XCTFail("fixture 형식 오류: \(line)")
                continue
            }
            rows.append(Row(keys: String(parts[0]), action: String(parts[1]), replacement: String(parts[2])))
        }
        return rows
    }

    /// 번들 사본이 아니라 **저장소 원본**을 읽는다. 그래야 번들 복사가 빠지거나
    /// 어긋났을 때 이 테스트가 아니라 별도 검사가 그 사실을 드러낸다.
    private static var repositoryRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return url
    }
}
