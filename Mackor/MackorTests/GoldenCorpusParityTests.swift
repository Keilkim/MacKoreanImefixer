import XCTest

/// `Corpus/structure-correction/v2/golden.tsv` 와 Swift 구현이 한 행도
/// 어긋나지 않는지 검증한다.
///
/// 골든 코퍼스는 손으로 고른 사례가 아니라 파이썬 레퍼런스 구현
/// (`scripts/rulebench/genrules.py`)의 판정을 규칙 ID별로 계층 표집한 것이다.
/// 따라서 이 테스트는 "구현이 스스로를 검증"하는 순환이 아니라, 두 독립 구현이
/// 갈라지는 순간을 잡는 장치다. 규칙을 바꾸면 `make_golden.py` 를 다시 돌려
/// 코퍼스를 갱신해야 하며, 그 diff 가 곧 행동 변화의 기록이 된다.
final class GoldenCorpusParityTests: XCTestCase {

    private struct Row {
        let id: String
        let direction: String
        let physicalKeys: String
        let expectedAction: String
        let expectedOriginal: String
        let expectedReplacement: String
        let expectedTier: String
        let rule: String
    }

    private static let headers = [
        "id", "direction", "physical_keys", "expected_action",
        "expected_original", "expected_replacement", "expected_tier", "rule",
    ]

    func testGoldenCorpusMatchesTheSwiftImplementation() throws {
        let rows = try loadCorpus()
        XCTAssertGreaterThanOrEqual(rows.count, 300, "골든 코퍼스가 비정상적으로 작습니다")

        var mismatches: [String] = []

        for row in rows {
            guard let keystrokes = PhysicalKeystrokeFixture.keystrokes(row.physicalKeys) else {
                mismatches.append("\(row.id): 지원하지 않는 키 \(row.physicalKeys)")
                continue
            }
            let source: InputSourceKind = row.direction == "latin_to_korean"
                ? .supportedLatin
                : .koreanTwoSet
            let decision = LayoutCorrectionPolicy.evaluate(
                keystrokes: keystrokes,
                inputSource: source
            )

            switch decision {
            case .preserve(let rule):
                if row.expectedAction != "preserve" {
                    mismatches.append(
                        "\(row.id): 교정되어야 하는데 보존됨 (rule=\(rule))"
                    )
                } else if name(of: rule) != row.rule {
                    mismatches.append(
                        "\(row.id): 규칙 불일치 기대=\(row.rule) 실제=\(name(of: rule))"
                    )
                }

            case .correct(let tier, let original, let replacement, let rule):
                if row.expectedAction != "correct" {
                    mismatches.append(
                        "\(row.id): 보존되어야 하는데 교정됨 -> \(replacement) (rule=\(rule))"
                    )
                    continue
                }
                if original != row.expectedOriginal {
                    mismatches.append(
                        "\(row.id): 원문 불일치 기대=\(row.expectedOriginal) 실제=\(original)"
                    )
                }
                if replacement != row.expectedReplacement {
                    mismatches.append(
                        "\(row.id): 교정문 불일치 기대=\(row.expectedReplacement) 실제=\(replacement)"
                    )
                }
                if name(of: tier) != row.expectedTier {
                    mismatches.append(
                        "\(row.id): 등급 불일치 기대=\(row.expectedTier) 실제=\(name(of: tier))"
                    )
                }
                if name(of: rule) != row.rule {
                    mismatches.append(
                        "\(row.id): 규칙 불일치 기대=\(row.rule) 실제=\(name(of: rule))"
                    )
                }
            }
        }

        XCTAssertTrue(
            mismatches.isEmpty,
            "\(mismatches.count)/\(rows.count) 행 불일치:\n" + mismatches.prefix(25).joined(separator: "\n")
        )
    }

    func testGoldenCorpusCoversEveryDecisionRule() throws {
        let rows = try loadCorpus()
        let covered = Set(rows.map(\.rule))
        // 실행 경로가 있는 모든 규칙이 최소 한 행씩 고정되어야 한다.
        for rule in [
            "koreanStructure", "englishCostMargin", "acronymConvention",
            "weakKoreanStructure", "ambiguousBothValid",
            "englishStructure", "markedEnglishForm", "modernKoreanPreserved",
            "expressiveRepetition", "consonantJamoMash", "implausibleEnglish",
        ] {
            XCTAssertTrue(covered.contains(rule), "골든 코퍼스에 \(rule) 행이 없습니다")
        }
    }

    // MARK: - 로딩

    private func loadCorpus() throws -> [Row] {
        let url = Self.fixtureDirectory.appendingPathComponent("golden.tsv")
        let contents = try String(contentsOf: url, encoding: .utf8)

        XCTAssertFalse(contents.contains("\r"), "골든 코퍼스에 CR 이 있습니다")
        XCTAssertTrue(contents.hasSuffix("\n"), "골든 코퍼스는 개행으로 끝나야 합니다")

        var lines = contents.components(separatedBy: "\n")
        if lines.last?.isEmpty == true { lines.removeLast() }
        guard let header = lines.first else {
            XCTFail("골든 코퍼스가 비어 있습니다")
            return []
        }
        XCTAssertEqual(header.components(separatedBy: "\t"), Self.headers)

        var rows: [Row] = []
        var seen = Set<String>()
        for line in lines.dropFirst() {
            let fields = line.components(separatedBy: "\t")
            guard fields.count == Self.headers.count else {
                XCTFail("필드 수가 맞지 않습니다: \(line)")
                continue
            }
            for field in fields where field.isEmpty {
                XCTFail("빈 필드가 있습니다: \(line)")
            }
            let row = Row(
                id: fields[0],
                direction: fields[1],
                physicalKeys: fields[2],
                expectedAction: fields[3],
                expectedOriginal: fields[4],
                expectedReplacement: fields[5],
                expectedTier: fields[6],
                rule: fields[7]
            )
            XCTAssertTrue(seen.insert(row.id).inserted, "중복 id: \(row.id)")
            XCTAssertTrue(
                row.physicalKeys.allSatisfy { $0.isASCII && $0.isLetter },
                "physical_keys 는 ASCII 알파벳이어야 합니다: \(row.id)"
            )
            XCTAssertTrue(
                ["latin_to_korean", "korean_to_latin"].contains(row.direction),
                "알 수 없는 방향: \(row.id)"
            )
            XCTAssertEqual(
                row.expectedAction == "correct",
                row.expectedReplacement != "-",
                "action 과 replacement 가 어긋납니다: \(row.id)"
            )
            rows.append(row)
        }
        return rows
    }

    private static var fixtureDirectory: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return url
            .appendingPathComponent("Corpus")
            .appendingPathComponent("structure-correction")
            .appendingPathComponent("v2")
    }

    // MARK: - 이름 매핑 (TSV 문자열 <-> Swift 케이스)

    private func name(of tier: LayoutCorrectionPolicy.Tier) -> String {
        switch tier {
        case .high: return "high"
        case .medium: return "medium"
        }
    }

    private func name(of rule: LayoutCorrectionPolicy.Rule) -> String {
        switch rule {
        case .koreanStructure: return "koreanStructure"
        case .englishCostMargin: return "englishCostMargin"
        case .englishStructure: return "englishStructure"
        case .markedEnglishForm: return "markedEnglishForm"
        case .acronymConvention: return "acronymConvention"
        case .weakKoreanStructure: return "weakKoreanStructure"
        case .ambiguousBothValid: return "ambiguousBothValid"
        case .modernKoreanPreserved: return "modernKoreanPreserved"
        case .expressiveRepetition: return "expressiveRepetition"
        case .consonantJamoMash: return "consonantJamoMash"
        case .implausibleEnglish: return "implausibleEnglish"
        case .unsupportedSource: return "unsupportedSource"
        case .compositionUnavailable: return "compositionUnavailable"
        }
    }
}
