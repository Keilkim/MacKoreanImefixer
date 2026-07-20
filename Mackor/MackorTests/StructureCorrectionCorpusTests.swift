import Foundation
import XCTest

final class StructureCorrectionCorpusTests: XCTestCase {
    func testTuneCorpus() throws {
        try assertCorpus(named: "tune.tsv", expectedRowCount: 23)
    }

    func testHoldoutCorpus() throws {
        try assertCorpus(named: "holdout.tsv", expectedRowCount: 27)
    }

    // `system-evidence.tsv` 는 더 이상 읽지 않습니다. 그 코퍼스의 모든 행은
    // NSSpellChecker 근거 주입을 전제로 작성됐는데, 규칙 기반 정책은 근거를
    // 받지 않습니다. 파일은 이전 설계의 기록으로 남겨 두되 테스트는 하지
    // 않으며, 근거 없는 회귀는 v2 골든 코퍼스가 담당합니다.

    private func assertCorpus(named filename: String, expectedRowCount: Int) throws {
        let rows = try loadCorpus(named: filename)
        XCTAssertEqual(rows.count, expectedRowCount, "Unexpected row count in \(filename)")

        var matrices = Dictionary(
            uniqueKeysWithValues: CorpusDirection.allCases.map { ($0, ConfusionMatrix()) }
        )

        for row in rows {
            let engine = WrongLayoutCorrectionEngine()
            record(row.physicalKeys, source: row.direction.inputSource, into: engine, rowID: row.id)
            let decision = engine.processBoundary(.space)
            let expectedPositive = row.expectedAction == .correct
            let actualPositive = decision != nil
            matrices[row.direction, default: ConfusionMatrix()].record(
                expectedPositive: expectedPositive,
                actualPositive: actualPositive
            )

            if expectedPositive {
                guard let unwrapped = decision else {
                    XCTFail("Missing correction for \(row.id)")
                    continue
                }
                XCTAssertEqual(unwrapped.direction, row.direction.engineDirection, "Wrong direction for \(row.id)")
                XCTAssertEqual(unwrapped.original, row.expectedOriginal, "Wrong original for \(row.id)")
                XCTAssertEqual(unwrapped.replacement, row.expectedReplacement, "Wrong replacement for \(row.id)")
            } else if let decision {
                XCTFail(
                    "Unexpected correction for \(row.id): \(decision.original) -> \(decision.replacement)"
                )
            }
        }

        for direction in CorpusDirection.allCases {
            let matrix = try XCTUnwrap(matrices[direction])
            print(
                "[structure-correction \(filename) \(direction.rawValue)] "
                    + "TP=\(matrix.truePositive) FP=\(matrix.falsePositive) "
                    + "FN=\(matrix.falseNegative) TN=\(matrix.trueNegative) "
                    + String(
                        format: "precision=%.3f recall=%.3f F1=%.3f",
                        matrix.precision,
                        matrix.recall,
                        matrix.f1
                    )
            )

            XCTAssertGreaterThan(
                matrix.truePositive + matrix.falseNegative,
                0,
                "\(filename) must contain a positive \(direction.rawValue) row"
            )
            XCTAssertGreaterThan(
                matrix.trueNegative + matrix.falsePositive,
                0,
                "\(filename) must contain a negative \(direction.rawValue) row"
            )
            XCTAssertEqual(matrix.falsePositive, 0, "False positives in \(filename), \(direction.rawValue)")
            XCTAssertEqual(matrix.falseNegative, 0, "False negatives in \(filename), \(direction.rawValue)")
            XCTAssertEqual(matrix.precision, 1, accuracy: 0.000_001)
            XCTAssertEqual(matrix.recall, 1, accuracy: 0.000_001)
            XCTAssertEqual(matrix.f1, 1, accuracy: 0.000_001)
        }
    }

    private func loadCorpus(named filename: String) throws -> [CorpusRow] {
        let url = Self.fixtureDirectory.appendingPathComponent(filename)
        let contents = try String(contentsOf: url, encoding: .utf8)
        guard contents.hasSuffix("\n"), !contents.contains("\r") else {
            throw CorpusFormatError("\(filename) must use LF line endings and end with LF")
        }

        let allLines = contents.split(separator: "\n", omittingEmptySubsequences: false)
        let lines = allLines.dropLast()
        let header = lines.first.map(String.init)
        guard header == Self.baseHeader else {
            throw CorpusFormatError("Unexpected header in \(filename)")
        }

        var seenIDs = Set<String>()
        return try lines.dropFirst().enumerated().map { offset, line in
            let lineNumber = offset + 2
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            let expectedFieldCount = 7
            guard fields.count == expectedFieldCount else {
                throw CorpusFormatError(
                    "\(filename):\(lineNumber) has \(fields.count) fields, expected \(expectedFieldCount)"
                )
            }
            guard !fields.contains(where: \.isEmpty) else {
                throw CorpusFormatError("\(filename):\(lineNumber) contains an empty field")
            }
            guard seenIDs.insert(fields[0]).inserted else {
                throw CorpusFormatError("Duplicate id \(fields[0]) in \(filename)")
            }
            guard let direction = CorpusDirection(rawValue: fields[1]) else {
                throw CorpusFormatError("Unknown direction on \(filename):\(lineNumber)")
            }
            let expectedActionIndex = 3
            let expectedOriginalIndex = 4
            let expectedReplacementIndex = 5
            let categoryIndex = 6
            guard let expectedAction = ExpectedAction(rawValue: fields[expectedActionIndex]) else {
                throw CorpusFormatError("Unknown expected_action on \(filename):\(lineNumber)")
            }
            guard fields[2].allSatisfy({ $0.isASCII && $0.isLetter }) else {
                throw CorpusFormatError("physical_keys must contain only ASCII letters on \(filename):\(lineNumber)")
            }
            guard (expectedAction == .correct) == (fields[expectedReplacementIndex] != "-") else {
                throw CorpusFormatError("Invalid expected_replacement on \(filename):\(lineNumber)")
            }

            return CorpusRow(
                id: fields[0],
                direction: direction,
                physicalKeys: fields[2],
                expectedAction: expectedAction,
                expectedOriginal: fields[expectedOriginalIndex],
                expectedReplacement: fields[expectedReplacementIndex],
                category: fields[categoryIndex]
            )
        }
    }

    private func record(
        _ letters: String,
        source: InputSourceKind,
        into engine: WrongLayoutCorrectionEngine,
        rowID: String
    ) {
        for character in letters {
            let lowercaseText = String(character).lowercased()
            guard lowercaseText.count == 1,
                  let lowercase = lowercaseText.first,
                  let keycode = Self.keycodes[lowercase] else {
                XCTFail("Undefined physical key in \(rowID)")
                return
            }

            let accepted = engine.record(
                PhysicalKeystroke(
                    keycode: keycode,
                    shift: String(character) != lowercaseText
                ),
                inputSource: source
            )
            XCTAssertTrue(accepted, "Engine rejected a fixture key in \(rowID)")
        }
    }

    private static let fixtureDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Corpus")
        .appendingPathComponent("structure-correction")
        .appendingPathComponent("v1")

    private static let baseHeader = [
        "id", "direction", "physical_keys", "expected_action",
        "expected_original", "expected_replacement", "category",
    ].joined(separator: "\t")

    private static let keycodes: [Character: UInt16] = [
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05,
        "z": 0x06, "x": 0x07, "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C,
        "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10, "t": 0x11, "o": 0x1F,
        "u": 0x20, "i": 0x22, "p": 0x23, "l": 0x25, "j": 0x26, "k": 0x28,
        "n": 0x2D, "m": 0x2E,
    ]
}

private struct CorpusRow {
    let id: String
    let direction: CorpusDirection
    let physicalKeys: String
    let expectedAction: ExpectedAction
    let expectedOriginal: String
    let expectedReplacement: String
    let category: String
}

private enum CorpusDirection: String, CaseIterable {
    case latinToKorean = "latin_to_korean"
    case koreanToLatin = "korean_to_latin"

    var inputSource: InputSourceKind {
        switch self {
        case .latinToKorean: .supportedLatin
        case .koreanToLatin: .koreanTwoSet
        }
    }

    var engineDirection: CorrectionDirection {
        switch self {
        case .latinToKorean: .latinToKorean
        case .koreanToLatin: .koreanToLatin
        }
    }
}

private enum ExpectedAction: String {
    case correct
    case preserve
}

private struct ConfusionMatrix {
    private(set) var truePositive = 0
    private(set) var falsePositive = 0
    private(set) var falseNegative = 0
    private(set) var trueNegative = 0

    mutating func record(expectedPositive: Bool, actualPositive: Bool) {
        switch (expectedPositive, actualPositive) {
        case (true, true): truePositive += 1
        case (false, true): falsePositive += 1
        case (true, false): falseNegative += 1
        case (false, false): trueNegative += 1
        }
    }

    var precision: Double {
        ratio(truePositive, truePositive + falsePositive)
    }

    var recall: Double {
        ratio(truePositive, truePositive + falseNegative)
    }

    var f1: Double {
        let denominator = precision + recall
        return denominator == 0 ? 0 : 2 * precision * recall / denominator
    }

    private func ratio(_ numerator: Int, _ denominator: Int) -> Double {
        denominator == 0 ? 0 : Double(numerator) / Double(denominator)
    }
}

private struct CorpusFormatError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
