import Foundation
import Carbon.HIToolbox

// MARK: - Jamo 타입

enum JamoType {
    case consonant
    case vowel
}

/// 두벌식 키보드에서의 자모 정보
struct Jamo: Equatable {
    let type: JamoType
    let character: Character
    let keycode: UInt16
    let shifted: Bool

    var isConsonant: Bool { type == .consonant }
    var isVowel: Bool { type == .vowel }
}

// MARK: - 키코드 → 자모 매핑

/// macOS 가상 키코드를 두벌식 한글 자모로 변환
enum KeycodeToJamoMap {

    /// 키코드와 Shift 상태로 자모 반환. 자모 키가 아니면 nil
    static func jamo(for keycode: UInt16, shift: Bool) -> Jamo? {
        if shift, let entry = shiftedMap[keycode] {
            return Jamo(type: entry.type, character: entry.char, keycode: keycode, shifted: true)
        }
        if let entry = normalMap[keycode] {
            return Jamo(type: entry.type, character: entry.char, keycode: keycode, shifted: false)
        }
        return nil
    }

    // MARK: - 일반 (Shift 없음) 매핑

    private static let normalMap: [UInt16: (char: Character, type: JamoType)] = [
        // 자음 — Q열
        0x0C: ("ㅂ", .consonant),  // Q
        0x0D: ("ㅈ", .consonant),  // W
        0x0E: ("ㄷ", .consonant),  // E
        0x0F: ("ㄱ", .consonant),  // R
        0x11: ("ㅅ", .consonant),  // T

        // 자음 — A열
        0x00: ("ㅁ", .consonant),  // A
        0x01: ("ㄴ", .consonant),  // S
        0x02: ("ㅇ", .consonant),  // D
        0x03: ("ㄹ", .consonant),  // F
        0x05: ("ㅎ", .consonant),  // G

        // 자음 — Z열
        0x06: ("ㅋ", .consonant),  // Z
        0x07: ("ㅌ", .consonant),  // X
        0x08: ("ㅊ", .consonant),  // C
        0x09: ("ㅍ", .consonant),  // V

        // 모음 — 윗줄
        0x10: ("ㅛ", .vowel),      // Y
        0x20: ("ㅕ", .vowel),      // U
        0x22: ("ㅑ", .vowel),      // I
        0x1F: ("ㅐ", .vowel),      // O
        0x23: ("ㅔ", .vowel),      // P

        // 모음 — 가운데줄
        0x04: ("ㅗ", .vowel),      // H
        0x26: ("ㅓ", .vowel),      // J
        0x28: ("ㅏ", .vowel),      // K
        0x25: ("ㅣ", .vowel),      // L

        // 모음 — 아랫줄
        0x0B: ("ㅠ", .vowel),      // B
        0x2D: ("ㅜ", .vowel),      // N
        0x2E: ("ㅡ", .vowel),      // M
    ]

    // MARK: - Shift 매핑 (쌍자음, 변형 모음)

    private static let shiftedMap: [UInt16: (char: Character, type: JamoType)] = [
        0x0C: ("ㅃ", .consonant),  // Shift+Q
        0x0D: ("ㅉ", .consonant),  // Shift+W
        0x0E: ("ㄸ", .consonant),  // Shift+E
        0x0F: ("ㄲ", .consonant),  // Shift+R
        0x11: ("ㅆ", .consonant),  // Shift+T

        0x1F: ("ㅒ", .vowel),      // Shift+O
        0x23: ("ㅖ", .vowel),      // Shift+P
    ]
}
