// 단음절 도메인의 라틴 키열 중 **macOS 영어 맞춤법 검사기가 단어로 인정하는 것**을
// 스냅샷으로 떨군다. `mono-gates.v1.txt` 의 EN 게이트를 보강한다.
//
// 왜 필요한가: 기존 EN 게이트는 `/usr/share/dict/words`(웹스터 1934) 하나였다.
// 그 목록은 두 방향으로 틀린다.
//
//   놓친다  현대 약어·확장자를 모른다. 실측:
//           dmg(파일 확장자)·db(데이터베이스)·co(회사)·fl(플로리다)·xl(엑셀)이
//           전부 미등재라 게이트를 그냥 통과한다. `dmg` 는 실제로 `읗` 로
//           교정되고 있었다 — `읗` 은 한국어 사전도 단어로 인정하지 않는다.
//
//   과하다  90년 전 사어·방언을 표제어로 갖고 있다. sla·sha·rhe·wha 가 그래서
//           막혔고, 사람이 `mono-admit.tsv` 에 한 줄씩 적어 되열어야 했다.
//
// macOS 영어 사전은 정확히 그 반대 특성을 갖는다(위 실측 참고). 그래서 둘을
// 합집합으로 쓴다 — 어느 한쪽이라도 단어로 보면 막는다. 안전 방향의 합집합이므로
// 추가는 언제나 단조 안전하다.
//
// 두 사전이 다 놓치는 것(ep·wl·rh·tpa·cnr·sus)은 여전히 `mono-veto.tsv` 원장이
// 담당한다. 자동 게이트는 사람 판단을 줄일 뿐 없애지 못한다.
//
// 사용법:
//   swift scripts/lexicon/scan_en_dictionary.swift > scripts/lexicon/mono-endict.v1.txt

import AppKit
import Foundation

let checker = NSSpellChecker.shared

guard checker.availableLanguages.contains(where: { $0.hasPrefix("en") }) else {
    FileHandle.standardError.write(Data("영어 맞춤법 검사기를 쓸 수 없습니다.\n".utf8))
    exit(1)
}

func isEnglishWord(_ text: String) -> Bool {
    checker.checkSpelling(
        of: text,
        startingAt: 0,
        language: "en",
        wrap: false,
        inSpellDocumentWithTag: 0,
        wordCount: nil
    ).location == NSNotFound
}

// 변별력 자체 검사. 전부 인정하거나 전부 거부하면 스냅샷이 무의미하다.
for word in ["go", "the", "water", "great", "company"] where !isEnglishWord(word) {
    FileHandle.standardError.write(Data("변별력 검사 실패: 실단어 \(word) 를 거부합니다\n".utf8))
    exit(1)
}
for word in ["aks", "eho", "qor", "vks", "zzqx"] where isEnglishWord(word) {
    FileHandle.standardError.write(Data("변별력 검사 실패: 비단어 \(word) 를 인정합니다\n".utf8))
    exit(1)
}

// 두벌식 자판 문자만으로 이루어진 2~5자 조합 전수. 단음절 도메인의 키열은
// 최대 5키(초성2+중성2+종성1 형태)이므로 이 범위면 도메인을 덮는다.
let alphabet = Array("abcdefghijklmnopqrstuvwxyzEQRTOPW")
var accepted: [String] = []

func walk(_ prefix: String, _ depth: Int) {
    if depth >= 2, isEnglishWord(prefix) {
        accepted.append(prefix)
    }
    guard depth < 3 else { return }
    for character in alphabet {
        walk(prefix + String(character), depth + 1)
    }
}

for character in alphabet {
    walk(String(character), 1)
}

print(accepted.sorted().joined(separator: "\n"))
FileHandle.standardError.write(Data(
    "2~3자 조합 중 \(accepted.count)개를 영어 단어로 인정했습니다.\n".utf8
))
