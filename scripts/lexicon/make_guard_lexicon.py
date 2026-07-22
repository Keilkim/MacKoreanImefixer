#!/usr/bin/env python3
"""LexicalGuard용 영어 증거 투영을 생성한다.

왜 투영인가 — make_lexicon.py와 같은 이유다. 원본 영어 사전(2.49 MB OS 자산)은
저장소에 고정할 수 없고, LexicalGuard의 사전 게이트는 **순수 자음 자모가 되는
한→영 교정 결과**만 조회한다. 두벌식에서 자음이 되는 자판 글자는
{q,w,e,r,t,a,s,d,f,g,z,x,c,v} 열넷뿐이므로, 그 글자만으로 적힌 단어의
부분집합이 이 게이트에 대해 무손실이다. 수 KB로 줄어 저장소에 커밋하고
lexicon-freeze.sha256으로 고정할 수 있다.

손 목록을 두지 않는 이유: `ㅁㅊ`(→ac)·`ㅇㅈ`(→dw) 같은 굳어진 자모 표현을
일일이 나열하면 끝이 없다. 대신 "교정 결과가 실제 영어 단어인가"를 이 투영으로
묻는다 — ac·tq·dw는 사전에 없어 자동으로 보존되고, we·see·test는 있어 교정된다.

정책:
  - 소문자 항목만 취한다(대문자 포함 항목은 고유명사 — 교정 증거로 부적합).
  - 길이 2..10. 1글자는 엔진이 애초에 토큰으로 다루지 않고, 10 초과는
    최대 토큰 길이를 넘는다.
  - 출력은 정렬·중복 제거해 결정적이다(동결 해시가 의미를 갖도록).

사용: python3 scripts/lexicon/make_guard_lexicon.py
갱신 절차: 이 스크립트를 다시 돌리고 lexicon-freeze.sha256을 함께 갱신한다.
그 diff가 곧 어휘 변화의 기록이다(ci.yml lexicon freeze 절차와 동일).
"""

from pathlib import Path

EN_SOURCE = Path("/usr/share/dict/words")
OUT = Path(__file__).resolve().parent / "en-guard.v1.txt"

# 두벌식에서 자음 자모가 되는 자판 글자.
CONSONANT_KEYS = set("qwertasdfgzxcv")


def main() -> None:
    words = set()
    for line in EN_SOURCE.read_text(encoding="utf-8").splitlines():
        word = line.strip()
        if not (2 <= len(word) <= 10):
            continue
        if not word.islower():
            continue
        if not set(word) <= CONSONANT_KEYS:
            continue
        words.add(word)

    OUT.write_text("\n".join(sorted(words)) + "\n", encoding="utf-8")
    print(f"{OUT.name}: {len(words)}개 항목")


if __name__ == "__main__":
    main()
