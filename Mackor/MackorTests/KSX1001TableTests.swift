import XCTest

final class KSX1001TableTests: XCTestCase {

    func testDerivesExactlyTheStandardSyllableCount() {
        // 표준이 정의한 완성형 음절 수. 목록을 코드에 두지 않고 macOS EUC-KR
        // 변환기에서 유도하므로, 이 숫자가 유도가 성공했다는 유일한 증거다.
        XCTAssertEqual(KSX1001Table.derivedSyllableCount, 2350)
        XCTAssertTrue(KSX1001Table.isTrustworthy)
    }

    func testAcceptsSyllablesUsedInModernKorean() {
        for character in "안녕하세요감사합니다한글빌드좋아재깅뭉오체" {
            guard let scalar = character.unicodeScalars.first else { return XCTFail() }
            XCTAssertTrue(
                KSX1001Table.isModernSyllable(scalar),
                "현대 국어 음절이어야 합니다: \(character)"
            )
        }
    }

    func testRejectsSyllablesThatOnlyAppearAsWrongLayoutDebris() {
        // 영문 자판 문자열을 두벌식으로 잘못 읽었을 때 생기는 잔해.
        // the -> 솓, downthrow -> 애주소갲, abetment -> 뮫스둣
        for character in "솓갲뮫걄쳥뎧" {
            guard let scalar = character.unicodeScalars.first else { return XCTFail() }
            XCTAssertFalse(
                KSX1001Table.isModernSyllable(scalar),
                "현대 국어에 쓰이지 않는 음절이어야 합니다: \(character)"
            )
        }
    }

    func testRejectsScalarsOutsideTheHangulSyllableBlock() {
        for scalar in "aㅁ1 ".unicodeScalars {
            XCTAssertFalse(KSX1001Table.isModernSyllable(scalar))
        }
    }

    func testWholeStringCheckIgnoresNonSyllableCharacters() {
        // 낱자모는 음절이 아니므로 이 검사의 대상이 아니다.
        XCTAssertTrue(KSX1001Table.containsOnlyModernSyllables("안녕ㅎ"))
        XCTAssertTrue(KSX1001Table.containsOnlyModernSyllables("ㅁㄴㅇ"))
        XCTAssertFalse(KSX1001Table.containsOnlyModernSyllables("애주소갲"))
    }

    func testPrepareIsIdempotent() {
        KSX1001Table.prepare()
        KSX1001Table.prepare()
        XCTAssertEqual(KSX1001Table.derivedSyllableCount, 2350)
    }
}
