// 현대 한글 1음절 중 **macOS 한국어 맞춤법 검사기가 단어로 인정하는 것**을
// 전수로 스캔해 스냅샷으로 떨군다.
//
// 왜 필요한가: 이 저장소에는 한국어 단음절 사전이 없다. `ko_words.txt` 19,894행에
// 1음절 어절이 0개이고, 그래서 지금까지는 사람이 부류별로 손으로 선언했다
// (`mono-source.ko.tsv`). 그 방식은 상한이 곧 정지 조건이라 안전하지만, 상한에
// 닿으면 `온`·`첫`·`길`·`축` 같은 일상어가 그냥 빠진다.
//
// macOS 는 한국어 사전을 이미 갖고 있다. 실측하면 11,172음절 중 1,115개만
// 단어로 인정한다 — 변별력이 있다는 뜻이다:
//
//   실단어  말 길 별 좀 흠 축 책 꽃 눈 손 밥 집 글  →  전부 인정
//   비단어  믜 킕 쁋 줱 촥 퉦 뎗 쬺 햙              →  전부 거부
//
// **런타임 의존이 아니다.** 과거에 `NSSpellChecker` 를 걷어낸 것은 교정 경로가
// 시스템 서비스에 매달리면 안 되기 때문이었고, 그 결정은 그대로다. 이 스캔은
// 자산을 만들 때 한 번 돌고, 앱에는 결과 파일만 들어간다.
//
// 스냅샷을 커밋하는 이유는 `mono-gates.v1.txt` 와 같다 — OS 자산은 기계·러너
// 이미지마다 다르므로, CI 가 다시 스캔하면 자산과 무관한 원인으로 실패하고
// 실패 메시지가 "손으로 편집했다"로 오도한다.
//
// 사용법:
//   swift scripts/lexicon/scan_ko_dictionary.swift > scripts/lexicon/mono-kodict.v1.txt

import AppKit
import Foundation

let checker = NSSpellChecker.shared

guard checker.availableLanguages.contains(where: { $0.hasPrefix("ko") }) else {
    FileHandle.standardError.write(Data(
        "한국어 맞춤법 검사기를 쓸 수 없습니다. 시스템 설정에서 한국어를 추가하세요.\n".utf8
    ))
    exit(1)
}

func isKoreanWord(_ text: String) -> Bool {
    checker.checkSpelling(
        of: text,
        startingAt: 0,
        language: "ko",
        wrap: false,
        inSpellDocumentWithTag: 0,
        wordCount: nil
    ).location == NSNotFound
}

// 변별력 자체 검사. 검사기가 전부 인정하거나 전부 거부하면 스냅샷이 무의미하므로
// 여기서 멈춘다 — 조용히 쓸모없는 자산을 만드는 것이 가장 나쁘다.
let mustAccept = ["말", "길", "별", "좀", "흠", "축", "책", "꽃", "눈", "손", "밥", "집", "글"]
let mustReject = ["믜", "킕", "쁋", "줱", "촥", "퉦", "뎗", "쬺", "햙"]
for word in mustAccept where !isKoreanWord(word) {
    FileHandle.standardError.write(Data("변별력 검사 실패: 실단어 \(word) 를 거부합니다\n".utf8))
    exit(1)
}
for word in mustReject where isKoreanWord(word) {
    FileHandle.standardError.write(Data("변별력 검사 실패: 비단어 \(word) 를 인정합니다\n".utf8))
    exit(1)
}

var accepted: [String] = []
for cho in 0..<19 {
    for jung in 0..<21 {
        for jong in 0..<28 {
            let scalar = UnicodeScalar(0xAC00 + cho * 588 + jung * 28 + jong)!
            let syllable = String(scalar)
            if isKoreanWord(syllable) {
                accepted.append(syllable)
            }
        }
    }
}

print(accepted.joined(separator: "\n"))
FileHandle.standardError.write(Data(
    "현대 한글 11,172음절 중 \(accepted.count)개를 단어로 인정했습니다.\n".utf8
))
