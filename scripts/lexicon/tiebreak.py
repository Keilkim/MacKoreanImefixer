#!/usr/bin/env python3
"""Layer 1 어휘 tiebreaker의 **파이썬 레퍼런스 구현**.

Swift `LexicalTiebreaker`가 이 로직을 이식하고, `Corpus/lexical/v1/tiebreaker.tsv`가
두 구현의 행 단위 일치를 강제한다. v4 규칙 골든(`Corpus/structure-correction/v2`)과는
완전히 별개의 자산이다 — 골든은 사전 없는 규칙만 검증한다.

판정:
    v4 규칙이 `ambiguousBothValid`로 보존한 키열에 대해서만 동작한다.
    한글 해석이 사전에 있고 영어 해석이 사전에 없으면 → 교정.
    둘 다 있거나(진짜 both-valid) 한글이 없으면 → 보존(오늘과 동일).

fail-safe 성질: 사전에 없는 한국어는 "보존"이므로 후퇴가 아니라 현상 유지다.

사용법:
    python3 -B tiebreak.py fixture   # 파리티 fixture 생성
"""

import sys

from pathlib import Path

HERE = Path(__file__).resolve().parent
RULEBENCH = HERE.parent / "rulebench"
sys.path.insert(0, str(RULEBENCH))

import genrules as g  # noqa: E402
from make_lexicon import english_lookup_key, is_ambiguous, read_lines  # noqa: E402

KO_LEXICON = dict(
    line.split("\t") for line in read_lines(HERE / "ko-lexicon.v1.txt")
)
EN_LEXICON = set(read_lines(HERE / "en-lexicon.v1.txt"))

FIXTURE = HERE.parent.parent / "Corpus" / "lexical" / "v1" / "tiebreaker.tsv"


def resolve(keys: str):
    """이 키열을 한글로 교정해야 하면 그 한글을, 아니면 None을 반환한다.

    호출 계약: v4 규칙이 `ambiguousBothValid`를 낸 키열에 대해서만 호출한다.
    방어적으로 여기서도 재확인한다 — 다른 분기에 개입하면 동결 판정이 바뀐다.
    """
    if not is_ambiguous(keys):
        return None
    korean = KO_LEXICON.get(keys)
    if korean is None:
        return None  # 한글 해석이 실단어가 아님 — 보존(오늘과 동일)
    key = english_lookup_key(keys)
    if key is not None and key in EN_LEXICON:
        return None  # 영어도 실단어 — 진짜 both-valid이므로 보존
    return korean


def cmd_fixture():
    """파리티 fixture를 생성한다.

    교정/보존 양쪽과 경계 사례를 모두 담아, Swift 이식이 어느 한쪽으로
    치우쳐도 잡히게 한다.
    """
    ko_words = read_lines(RULEBENCH / "ko_words.txt")
    en_words = [w for w in read_lines(Path("/usr/share/dict/words")) if w.isalpha()]

    rows = []
    seen = set()

    def add(keys):
        if keys in seen:
            return
        seen.add(keys)
        action, _tier, rule, _repl = g.explain_l2k(keys)
        if not (action == "preserve" and rule == "ambiguousBothValid"):
            return
        result = resolve(keys)
        rows.append((keys, "correct" if result else "preserve", result or ""))

    # 한국어 어절에서 나온 모호 키열 전수 (391) — 교정되는 쪽의 본체
    for word in ko_words:
        keys = g.ko_to_keys(word)
        if keys:
            add(keys)

    # 영어 사전에서 나온 모호 키열 — 보존되는 쪽. 전수는 크므로 결정적으로 표집한다.
    for i, word in enumerate(en_words):
        if i % 8 == 0:
            add(word)

    rows.sort()
    FIXTURE.parent.mkdir(parents=True, exist_ok=True)
    with FIXTURE.open("w", encoding="utf-8") as f:
        f.write("keys\taction\treplacement\n")
        for keys, action, repl in rows:
            f.write(f"{keys}\t{action}\t{repl}\n")

    n_correct = sum(1 for r in rows if r[1] == "correct")
    print(f"{FIXTURE.relative_to(HERE.parent.parent)}  {len(rows)} rows "
          f"(correct {n_correct}, preserve {len(rows) - n_correct})")


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "fixture"
    if cmd == "fixture":
        cmd_fixture()
    else:
        print(__doc__)
        sys.exit(2)
