import Foundation

/// 영어 음소배열·정서법 제약 검사기.
///
/// 단어 목록도, 합법 자음군 목록도 두지 않는다. 공명도 위계(sonority sequencing
/// principle)와 소수의 음운·정서법 규칙에서 합법 onset/coda가 **생성**된다.
/// 따라서 사전에 없는 신조어·고유명사도 구조만 정상이면 통과한다.
///
/// 반환값은 통과 여부와 **위반 비용**이다. 비용은 "영어로 불가능하지는 않지만
/// 유표적(marked)"인 형태의 개수이며, 반대 자판 후보와 비교할 때 마진으로 쓴다.
/// 규칙 ID는 `STRUCTURE_CORRECTION_DESIGN4.md` §2.2와 대응한다.
enum EnglishPhonotactics {

    struct Evaluation: Equatable {
        /// 영어 구조로 성립 가능한가.
        let isPlausible: Bool
        /// 유표적 형태의 개수. `isPlausible == false`이면 의미 없다.
        let cost: Int

        static let implausible = Evaluation(isPlausible: false, cost: 0)
    }

    // MARK: - 문법적 폐쇄류 (언어가 유한하게 닫아 놓은 집합)

    private static let vowelLetters: Set<Character> = ["a", "e", "i", "o", "u"]

    /// R-E7 정서법: 이 글자들은 겹쳐 쓰지 않는다.
    private static let neverDouble: Set<Character> = ["h", "j", "k", "q", "v", "w", "x", "y"]

    /// 단일 자음으로 취급하는 이중자. `rh` 는 그리스계 차용어의 어두 이중자다
    /// (rhythm, rhyme, rhino). 이것이 없으면 `rh-` 단어가 영어로 인정되지 않아
    /// 한글로 오교정된다.
    private static let digraphs: Set<String> = [
        "ch", "sh", "th", "ph", "wh", "gh", "ck", "ng", "rh",
    ]

    /// R-C1 표준 모음 이중자. 어두에서 이 밖의 모음쌍은 유표적이다.
    private static let vowelDigraphs: Set<String> = [
        "ai", "au", "aw", "ay", "ea", "ee", "ei", "eu", "ew", "ey",
        "ie", "oa", "oe", "oi", "oo", "ou", "ow", "oy", "ue", "ui",
    ]

    /// 공명도 위계. 폐쇄음 1 < 마찰음 2 < 비음 3 < 유음 4 < 활음 5.
    private static let sonority: [String: Int] = [
        "p": 1, "b": 1, "t": 1, "d": 1, "k": 1, "g": 1, "c": 1, "j": 1, "q": 1,
        "ch": 1, "ck": 1, "tch": 1,
        "f": 2, "v": 2, "s": 2, "z": 2, "x": 2,
        "th": 2, "sh": 2, "ph": 2, "gh": 2, "h": 2,
        "m": 3, "n": 3, "ng": 3,
        "l": 4, "r": 4, "rh": 4,
        "w": 5, "y": 5, "wh": 5,
    ]

    private static let voicelessStops: Set<String> = ["p", "t", "k", "c"]
    private static let voicedObstruents: Set<String> = ["b", "d", "g", "v", "z", "j"]
    private static let liquidsAndGlides: Set<String> = ["l", "r", "w", "y"]
    /// 공명도 2 이하 = 장애음.
    private static let obstruents: Set<String> = {
        Set(sonority.filter { $0.value <= 2 }.map(\.key))
    }()
    /// 자음군을 이룰 수 없는 장애음.
    private static let clusterIncapable: Set<String> = [
        "v", "x", "h", "gh", "ck", "tch", "ng", "z", "j", "q",
    ]

    /// R-E3b 조음위치 충돌로 영어 onset에 나타나지 않는 쌍.
    private static let onsetBans: Set<String> = [
        "t|l", "d|l", "th|l", "s|r", "p|w", "b|w", "f|w", "v|w", "m|w",
    ]

    /// R-E3d 어두 한정 고전어 묵음 onset.
    private static let initialSilentOnsets: Set<String> = [
        "k|n", "g|n", "w|r", "p|s", "p|n", "p|t", "m|n", "t|s",
    ]

    /// R-E5 굴절 접미 자음. 영어에서 모음 글자 없이 자음군에 바로 붙을 수 있는
    /// 것은 복수/서수의 -s(-z)와 -th 뿐이다. 과거형 -ed 는 철자에 언제나 모음
    /// `e` 가 들어가므로 여기에 넣지 않는다. `t`/`d` 를 넣으면 `해당`(goekd)
    /// 같은 불법 폐쇄음 연쇄가 유성성 규칙(T3)을 우회한다.
    private static let inflectionalAppendix: Set<String> = ["s", "z", "th"]

    // MARK: - 진입점

    static func evaluate(_ word: String) -> Evaluation {
        var cost = 0
        var letters = Array(word.lowercased())

        guard !letters.isEmpty else { return .implausible }
        for character in letters where !character.isASCII || !character.isLetter {
            return .implausible
        }

        // R-E6 어말 j/q/v 금지.
        if let last = letters.last, last == "j" || last == "q" || last == "v" {
            return .implausible
        }

        // R-E10 어말 모음+h 는 묵음이지만 유표적이다.
        if letters.count >= 2,
           letters[letters.count - 1] == "h",
           vowelLetters.contains(letters[letters.count - 2]) {
            letters.removeLast()
            cost += 1
        }

        // R-E11 모음 뒤 gn 의 g 는 묵음이다.
        letters = removingSilentG(letters)

        // R-E8 qu 를 한 단위로 묶는다. 이후 남은 q 뒤에는 모음이 와야 한다.
        letters = collapsingQU(letters)
        if let index = letters.firstIndex(of: "q") {
            let next = letters.index(after: index)
            guard next < letters.endIndex,
                  vowelLetters.contains(letters[next]) || letters[next] == "y" else {
                return Evaluation(isPlausible: false, cost: cost)
            }
        }

        let vowelPositions = resolveVowelPositions(letters)
        // R-E2 핵 없는 단어는 없다.
        guard !vowelPositions.isEmpty else { return Evaluation(isPlausible: false, cost: cost) }

        let segments = segment(letters, vowelPositions: vowelPositions)

        for (index, segment) in segments.enumerated() {
            if segment.isVowel {
                // R-C2 모음자 4연속은 불가, 3연속은 유표적.
                if segment.text.count > 3 { return Evaluation(isPlausible: false, cost: cost) }
                if segment.text.count == 3 { cost += 1 }
                // R-C1 어두 비표준 모음쌍.
                if index == 0,
                   segment.text.count == 2,
                   !vowelDigraphs.contains(String(segment.text)) {
                    cost += 1
                }
                continue
            }

            guard let units = consonantUnits(segment.text) else {
                return Evaluation(isPlausible: false, cost: cost)
            }
            let isFirst = index == 0
            let isLast = index == segments.count - 1

            // 자음만으로 이루어진 토큰은 위에서 이미 걸러진다.
            if isFirst && isLast { return Evaluation(isPlausible: false, cost: cost) }

            if isFirst {
                guard isValidOnset(units, isInitial: true) else {
                    return Evaluation(isPlausible: false, cost: cost)
                }
            } else if isLast {
                guard isValidCoda(units, isFinal: true) else {
                    return Evaluation(isPlausible: false, cost: cost)
                }
            } else {
                // 모음 사이 자음군은 coda + onset 으로 나뉠 수 있어야 한다.
                let splittable = (0...units.count).contains { split in
                    isValidCoda(Array(units[0..<split]), isFinal: false)
                        && isValidOnset(Array(units[split...]), isInitial: false)
                }
                guard splittable else { return Evaluation(isPlausible: false, cost: cost) }
            }
        }

        return Evaluation(isPlausible: true, cost: cost)
    }

    // MARK: - 정서법 정규화

    private static func removingSilentG(_ letters: [Character]) -> [Character] {
        var result: [Character] = []
        result.reserveCapacity(letters.count)
        var index = 0
        while index < letters.count {
            if letters[index] == "g",
               index + 1 < letters.count,
               letters[index + 1] == "n",
               let previous = result.last,
               vowelLetters.contains(previous) {
                index += 1  // g 를 버리고 n 은 다음 회차에 그대로 담는다.
                continue
            }
            result.append(letters[index])
            index += 1
        }
        return result
    }

    private static func collapsingQU(_ letters: [Character]) -> [Character] {
        var result: [Character] = []
        result.reserveCapacity(letters.count)
        var index = 0
        while index < letters.count {
            if letters[index] == "q", index + 1 < letters.count, letters[index + 1] == "u" {
                result.append("q")
                index += 2
                continue
            }
            result.append(letters[index])
            index += 1
        }
        return result
    }

    // MARK: - 핵 판정

    /// R-E2 + R-E12. `y`와 `w`는 위치에 따라 모음이 되기도 자음이 되기도 한다.
    /// 활음이 모음으로 승격되면 이웃의 판정이 달라질 수 있으므로 고정점까지 반복한다.
    private static func resolveVowelPositions(_ letters: [Character]) -> Set<Int> {
        var positions = Set<Int>()
        for (index, character) in letters.enumerated() where vowelLetters.contains(character) {
            positions.insert(index)
        }

        var changed = true
        while changed {
            changed = false
            for (index, character) in letters.enumerated() {
                guard !positions.contains(index) else { continue }
                let previousIsVowel = index > 0 && positions.contains(index - 1)
                let nextIsPlainVowel = index + 1 < letters.count
                    && vowelLetters.contains(letters[index + 1])

                if character == "y" {
                    // 어두 y + 모음, 그리고 모음 사이 y 는 자음(활음 onset)이다.
                    if index == 0 && nextIsPlainVowel { continue }
                    if previousIsVowel && nextIsPlainVowel { continue }
                    positions.insert(index)
                    changed = true
                } else if character == "w" {
                    // 모음 뒤에서 모음이 따르지 않으면 이중모음의 활음이다.
                    if previousIsVowel && !nextIsPlainVowel {
                        positions.insert(index)
                        changed = true
                    }
                }
            }
        }
        return positions
    }

    private struct Segment {
        let isVowel: Bool
        let text: [Character]
    }

    private static func segment(
        _ letters: [Character],
        vowelPositions: Set<Int>
    ) -> [Segment] {
        var segments: [Segment] = []
        var current: [Character] = []
        var currentIsVowel: Bool?

        for (index, character) in letters.enumerated() {
            let isVowel = vowelPositions.contains(index)
            if currentIsVowel == nil || isVowel == currentIsVowel {
                current.append(character)
            } else {
                segments.append(Segment(isVowel: currentIsVowel!, text: current))
                current = [character]
            }
            currentIsVowel = isVowel
        }
        if let currentIsVowel {
            segments.append(Segment(isVowel: currentIsVowel, text: current))
        }
        return segments
    }

    // MARK: - 자음 단위 분해

    /// 이중자를 묶고 겹자음을 축약한다. R-E7 위반이면 `nil`.
    private static func consonantUnits(_ cluster: [Character]) -> [String]? {
        var units: [String] = []
        var index = 0
        while index < cluster.count {
            if index + 2 < cluster.count,
               cluster[index] == "t", cluster[index + 1] == "c", cluster[index + 2] == "h" {
                units.append("tch")
                index += 3
                continue
            }
            if index + 1 < cluster.count {
                let pair = String([cluster[index], cluster[index + 1]])
                if digraphs.contains(pair) {
                    units.append(pair)
                    index += 2
                    continue
                }
                if cluster[index + 1] == cluster[index] {
                    guard !neverDouble.contains(cluster[index]) else { return nil }
                    units.append(String(cluster[index]))
                    index += 2
                    continue
                }
            }
            units.append(String(cluster[index]))
            index += 1
        }
        return units
    }

    // MARK: - Onset 생성 규칙

    private static func isValidOnset(_ units: [String], isInitial: Bool) -> Bool {
        switch units.count {
        case 0:
            return true

        case 1:
            // R-E3a `ng`/`ck`/`tch` 는 어두에 서지 못하고, `x` 는 어두에서만 허용된다.
            let unit = units[0]
            if unit == "ng" || unit == "ck" || unit == "tch" { return false }
            if unit == "x" && !isInitial { return false }
            return true

        case 2:
            let first = units[0], second = units[1]
            if onsetBans.contains("\(first)|\(second)") { return false }
            // R-E3d 어두 고전어 묵음 조합.
            if isInitial, initialSilentOnsets.contains("\(first)|\(second)") { return true }
            // R-E3b① s-예외: s 는 공명도 위계를 무시하고 자음군을 이끈다.
            if first == "s",
               voicelessStops.contains(second)
                   || ["m", "n", "f", "l", "w", "q"].contains(second) {
                return true
            }
            // R-E3b② 장애음 + 유음/활음 = 공명도 상승.
            if obstruents.contains(first),
               !clusterIncapable.contains(first),
               liquidsAndGlides.contains(second) {
                return true
            }
            return false

        case 3:
            // R-E3c s + 무성폐쇄음 + 유음/활음 (str, spl, squ …).
            let first = units[0], second = units[1], third = units[2]
            return first == "s"
                && voicelessStops.contains(second)
                && liquidsAndGlides.contains(third)
                && !onsetBans.contains("\(second)|\(third)")

        default:
            return false
        }
    }

    // MARK: - Coda 생성 규칙

    /// R-E4 공명도 하강 + T1 폐쇄음 연쇄 제약 + T3 유성성 일치.
    private static func isValidCodaCore(_ core: [String]) -> Bool {
        guard !core.isEmpty else { return true }
        if core[0] == "w" || core[0] == "y" { return false }

        for index in 0..<(core.count - 1) {
            let current = core[index], next = core[index + 1]
            let currentSonority = sonority[current] ?? 0
            let nextSonority = sonority[next] ?? 0

            // R-E4 핵에서 멀어질수록 공명도는 오르지 않는다.
            if currentSonority < nextSonority { return false }

            // T1 같은 공명도의 폐쇄음 연쇄는 무성 t 로만 닫힌다 (-ct, -pt, -xt).
            if currentSonority == nextSonority, currentSonority == 1 {
                guard next == "t", !voicedObstruents.contains(current) else { return false }
            }

            // T3 장애음끼리는 유성성이 일치해야 한다.
            if currentSonority <= 2, nextSonority <= 2 {
                let currentVoiced = voicedObstruents.contains(current)
                let nextVoiced = voicedObstruents.contains(next)
                if currentVoiced != nextVoiced { return false }
            }
        }
        return true
    }

    private static func isValidCoda(_ units: [String], isFinal: Bool) -> Bool {
        guard !units.isEmpty else { return true }
        // h 는 종성이 되지 못한다.
        if units[0] == "h" { return false }

        // R-E9 어말 마찰음+m 은 음절성 비음이다 (-ism, -asm, -rhythm).
        if isFinal,
           units.count >= 2,
           units[units.count - 1] == "m",
           (sonority[units[units.count - 2]] ?? 0) == 2 {
            return isValidCoda(Array(units.dropLast()), isFinal: false)
        }

        // R-E5 굴절 접미 자음을 벗기고 핵심 coda 를 검사한다. 접미는 단어 끝에만
        // 붙으므로 내부 자음군에는 적용하지 않는다. 내부에까지 허용하면
        // `다음`(ekdma) 같은 불법 연쇄가 통과한다.
        let maximumStrip = isFinal ? 2 : 0
        for strip in 0...maximumStrip {
            if strip > 0 {
                guard units.count >= strip else { continue }
                let tail = units.suffix(strip)
                guard tail.allSatisfy({ inflectionalAppendix.contains($0) }) else { continue }
            }
            let core = Array(units.prefix(units.count - strip))
            if isValidCodaCore(core) { return true }
        }
        return false
    }
}
