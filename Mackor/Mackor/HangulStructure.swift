import Foundation

/// 물리 키열을 두벌식으로 읽었을 때의 한국어 구조 평가.
///
/// 조합 자체는 앱이 이미 쓰고 있는 `HangulCompositionTracker`(= 두벌식 음절 문법)를
/// 그대로 재사용한다. 이 타입이 더하는 것은 조합 결과에 대한 구조 판정이다.
/// 규칙 ID는 `STRUCTURE_CORRECTION_DESIGN4.md` §2.1과 대응한다.
enum HangulStructure {

    private static let syllableRange: ClosedRange<UInt32> = 0xAC00...0xD7A3
    private static let compatibilityJamoRange: ClosedRange<UInt32> = 0x3131...0x318E
    private static let compatibilityConsonantRange: ClosedRange<UInt32> = 0x3131...0x314E

    struct Evaluation: Equatable {
        /// 조합된 한글 문자열.
        let text: String
        /// 완성된 음절 수.
        let syllableCount: Int
        /// 조합되지 못하고 남은 낱자모 수.
        let jamoCount: Int
        /// 물리 키 수.
        let keyCount: Int
        /// 자음 키가 연달아 눌린 최대 길이.
        let maximumConsonantRun: Int

        /// R-K1 낱자모 없이 전부 음절로 조합되었는가.
        var isFullyComposed: Bool { jamoCount == 0 && syllableCount > 0 }

        /// R-K1 + R-K2. 모든 음절이 현대 국어 음절인가.
        var isModernKorean: Bool {
            isFullyComposed && KSX1001Table.containsOnlyModernSyllables(text)
        }

        /// R-K1~K4를 모두 만족하는 강한 한국어 후보인가.
        ///
        /// 단음절 후보는 CVC(3키) 이상일 때만 인정한다. 2키 조합은 무작위
        /// 충돌률이 높아 오교정의 주된 원인이 된다.
        var isStrongKoreanCandidate: Bool {
            guard isModernKorean, maximumConsonantRun <= 3 else { return false }
            return syllableCount >= 2 || keyCount >= 3
        }

        /// R-K5a 전체가 같은 문자의 반복인가 (ㅋㅋㅋ, ㅠㅠ, 뇸뇸뇸).
        ///
        /// 특정 표현을 나열하지 않고 형태로만 판정하므로 미등재 표현도 걸린다.
        var isWholeRepetition: Bool {
            guard text.count >= 2 else { return false }
            return Set(text).count == 1
        }

        /// R-K5b 서로 다른 자음 자모만 3개 이상 나열된 키보드 매시인가 (ㅁㄴㅇ, ㅁㄴㅇㄹ).
        ///
        /// 음절을 이루려는 시도조차 없는 형태다. 반복이 섞이면(ㄴㄷㄷ = `see`)
        /// 실제 영어 단어일 가능성이 높으므로 여기서 제외한다.
        var isConsonantJamoMash: Bool {
            let characters = Array(text)
            guard characters.count >= 3 else { return false }
            guard characters.allSatisfy(isCompatibilityConsonant) else { return false }
            return Set(characters).count == characters.count
        }

        /// 순수 자음 자모로만 이루어졌는가. 신뢰 등급 강등 판단에 쓴다.
        var isAllConsonantJamo: Bool {
            !text.isEmpty && text.allSatisfy(isCompatibilityConsonant)
        }
    }

    /// 물리 키열을 두벌식으로 조합한다.
    ///
    /// 지원하지 않는 키가 섞이거나 조합기가 처리하지 못하면 `nil`.
    static func evaluate(_ keystrokes: [PhysicalKeystroke]) -> Evaluation? {
        guard !keystrokes.isEmpty else { return nil }

        let tracker = HangulCompositionTracker()
        var text = ""
        var consonantRun = 0
        var maximumConsonantRun = 0

        for keystroke in keystrokes {
            guard let jamo = KeycodeToJamoMap.jamo(
                for: keystroke.keycode,
                shift: keystroke.shift
            ) else {
                return nil
            }

            // R-K3 자음 키 연속 길이. 키 목록을 따로 두지 않고 자모 종류에서 얻는다.
            if jamo.isConsonant {
                consonantRun += 1
                maximumConsonantRun = max(maximumConsonantRun, consonantRun)
            } else {
                consonantRun = 0
            }

            let result = tracker.processJamo(jamo)
            guard !result.passthrough, result.deleteCount <= text.count else { return nil }
            for _ in 0..<result.deleteCount {
                text.removeLast()
            }
            text.append(contentsOf: result.insertText)
        }

        guard !text.isEmpty else { return nil }

        var syllableCount = 0
        var jamoCount = 0
        for character in text {
            if isSyllable(character) {
                syllableCount += 1
            } else if isCompatibilityJamo(character) {
                jamoCount += 1
            } else {
                return nil
            }
        }

        return Evaluation(
            text: text,
            syllableCount: syllableCount,
            jamoCount: jamoCount,
            keyCount: keystrokes.count,
            maximumConsonantRun: maximumConsonantRun
        )
    }

    // MARK: - 문자 분류

    private static func scalarValue(_ character: Character) -> UInt32? {
        guard character.unicodeScalars.count == 1 else { return nil }
        return character.unicodeScalars.first?.value
    }

    static func isSyllable(_ character: Character) -> Bool {
        guard let value = scalarValue(character) else { return false }
        return syllableRange.contains(value)
    }

    static func isCompatibilityJamo(_ character: Character) -> Bool {
        guard let value = scalarValue(character) else { return false }
        return compatibilityJamoRange.contains(value)
    }
}

private func isCompatibilityConsonant(_ character: Character) -> Bool {
    guard character.unicodeScalars.count == 1,
          let value = character.unicodeScalars.first?.value else { return false }
    return (0x3131...0x314E).contains(value)
}
