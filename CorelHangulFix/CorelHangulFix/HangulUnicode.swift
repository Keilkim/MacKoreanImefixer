import Foundation

/// Hangul Unicode 조합 유틸리티
/// 초성+중성+종성 자모를 받아서 완성형 한글 음절 유니코드 문자를 생성
enum HangulUnicode {

    static let syllableBase: UInt32 = 0xAC00

    // 초성 19자 (Unicode 순서)
    static let choseong: [Character] = [
        "ㄱ", "ㄲ", "ㄴ", "ㄷ", "ㄸ", "ㄹ", "ㅁ", "ㅂ", "ㅃ",
        "ㅅ", "ㅆ", "ㅇ", "ㅈ", "ㅉ", "ㅊ", "ㅋ", "ㅌ", "ㅍ", "ㅎ"
    ]

    // 중성 21자 (Unicode 순서)
    static let jungseong: [Character] = [
        "ㅏ", "ㅐ", "ㅑ", "ㅒ", "ㅓ", "ㅔ", "ㅕ", "ㅖ", "ㅗ",
        "ㅘ", "ㅙ", "ㅚ", "ㅛ", "ㅜ", "ㅝ", "ㅞ", "ㅟ", "ㅠ",
        "ㅡ", "ㅢ", "ㅣ"
    ]

    // 종성 28자 (Unicode 순서, 인덱스 0 = 종성 없음)
    static let jongseong: [Character?] = [
        nil,   "ㄱ", "ㄲ", "ㄳ", "ㄴ", "ㄵ", "ㄶ", "ㄷ", "ㄹ",
        "ㄺ", "ㄻ", "ㄼ", "ㄽ", "ㄾ", "ㄿ", "ㅀ", "ㅁ", "ㅂ",
        "ㅄ", "ㅅ", "ㅆ", "ㅇ", "ㅈ", "ㅊ", "ㅋ", "ㅌ", "ㅍ", "ㅎ"
    ]

    // MARK: - 음절 조합

    /// 초성+중성+종성(옵션)으로 완성형 한글 음절 문자 생성
    static func compose(cho: Character, jung: Character, jong: Character? = nil) -> Character? {
        guard let choIdx = choseong.firstIndex(of: cho),
              let jungIdx = jungseong.firstIndex(of: jung) else {
            return nil
        }

        var jongIdx = 0
        if let j = jong {
            guard let idx = jongseong.firstIndex(of: j) else { return nil }
            jongIdx = idx
        }

        let code = syllableBase + UInt32(choIdx) * 21 * 28 + UInt32(jungIdx) * 28 + UInt32(jongIdx)
        guard let scalar = Unicode.Scalar(code) else { return nil }
        return Character(scalar)
    }

    /// 현재 조합 상태를 문자열로 변환
    static func buildString(cho: Character?, jung: Character?, jong: Character? = nil) -> String {
        if let cho = cho, let jung = jung {
            if let syllable = compose(cho: cho, jung: jung, jong: jong) {
                return String(syllable)
            }
        }
        // 초성만 있으면 자음 그대로
        if let cho = cho { return String(cho) }
        // 중성만 있으면 모음 그대로
        if let jung = jung { return String(jung) }
        return ""
    }

    // MARK: - 복합 모음

    static let compoundVowels: [(first: Character, second: Character, result: Character)] = [
        ("ㅗ", "ㅏ", "ㅘ"),
        ("ㅗ", "ㅐ", "ㅙ"),
        ("ㅗ", "ㅣ", "ㅚ"),
        ("ㅜ", "ㅓ", "ㅝ"),
        ("ㅜ", "ㅔ", "ㅞ"),
        ("ㅜ", "ㅣ", "ㅟ"),
        ("ㅡ", "ㅣ", "ㅢ"),
    ]

    static func compoundVowel(first: Character, second: Character) -> Character? {
        compoundVowels.first { $0.first == first && $0.second == second }?.result
    }

    // MARK: - 복합 종성

    static let compoundJongseongs: [(first: Character, second: Character, result: Character)] = [
        ("ㄱ", "ㅅ", "ㄳ"),
        ("ㄴ", "ㅈ", "ㄵ"),
        ("ㄴ", "ㅎ", "ㄶ"),
        ("ㄹ", "ㄱ", "ㄺ"),
        ("ㄹ", "ㅁ", "ㄻ"),
        ("ㄹ", "ㅂ", "ㄼ"),
        ("ㄹ", "ㅅ", "ㄽ"),
        ("ㄹ", "ㅌ", "ㄾ"),
        ("ㄹ", "ㅍ", "ㄿ"),
        ("ㄹ", "ㅎ", "ㅀ"),
        ("ㅂ", "ㅅ", "ㅄ"),
    ]

    static func compoundJongseong(first: Character, second: Character) -> Character? {
        compoundJongseongs.first { $0.first == first && $0.second == second }?.result
    }

    /// 복합 종성을 두 자음으로 분리 (앞=종성 유지, 뒤=다음 초성으로 이동)
    static func splitCompoundJongseong(_ compound: Character) -> (first: Character, second: Character)? {
        compoundJongseongs.first { $0.result == compound }.map { ($0.first, $0.second) }
    }

    // MARK: - 종성 가능 여부

    /// ㄸ, ㅃ, ㅉ은 종성이 될 수 없음
    static let invalidJongseong: Set<Character> = ["ㄸ", "ㅃ", "ㅉ"]

    static func canBeJongseong(_ char: Character) -> Bool {
        !invalidJongseong.contains(char)
    }
}
