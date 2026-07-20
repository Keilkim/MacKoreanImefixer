#!/usr/bin/env python3
"""Layer 1 어휘 tiebreaker의 "모호성 투영(ambiguity projection)"을 생성한다.

Layer 1은 v4 규칙 엔진이 `ambiguousBothValid`로 보존한 키열에 대해서만 사전을
조회한다. 그 분기에 도달하지 못하는 문자열은 사전에 있든 없든 판정이 같으므로,
**그 분기에 도달할 수 있는 항목만 남긴 투영이 판정에 대해 무손실이다.**

이게 중요한 이유: 원본 사전은 저장소에 고정할 수 없다.
  - `/usr/share/dict/words`(2.49 MB)는 OS 자산이라 저장소 밖이고 버전이 OS에 종속된다.
  - 투영하면 22 KB로 줄어 저장소에 커밋하고 SHA-256으로 고정할 수 있다.
그래야 "파이썬 레퍼런스와 Swift가 **같은 파일**을 읽는다"는 파리티 요구가 실제로
집행 가능해진다.

무손실성은 `verify` 서브커맨드가 검증한다.

사용법:
    python3 -B make_lexicon.py generate   # 투영 파일 생성
    python3 -B make_lexicon.py verify     # 원본 대비 무손실 검증
"""

import sys
import unicodedata
from pathlib import Path

HERE = Path(__file__).resolve().parent
RULEBENCH = HERE.parent / "rulebench"
sys.path.insert(0, str(RULEBENCH))

import genrules as g  # noqa: E402

KO_SOURCE = RULEBENCH / "ko_words.txt"
EN_SOURCE = Path("/usr/share/dict/words")
KO_OUT = HERE / "ko-lexicon.v1.txt"
EN_OUT = HERE / "en-lexicon.v1.txt"


def is_ambiguous(keys: str) -> bool:
    """v4 규칙이 이 키열을 `ambiguousBothValid`로 보존하는가."""
    action, _tier, rule, _repl = g.explain_l2k(keys)
    return action == "preserve" and rule == "ambiguousBothValid"


def read_lines(path: Path):
    """빈 줄을 제거하고 읽는다. 파일이 개행으로 끝나지 않아도 마지막 항목을 잃지 않는다."""
    text = path.read_text(encoding="utf-8")
    return [line for line in text.split("\n") if line]


def english_lookup_key(keys: str):
    """영어 조회 정규화 — 정책 C (fold + 어중 대문자 veto).

    두벌식에서 Shift는 **다른 자모**(ㅃㅉㄸㄲㅆㅒㅖ)를 만들지만, 영어에서 Shift는
    **같은 단어의 표기 변형**이다. 그래서 대소문자는 한국어 쪽에서만 의미를 진다.

    어두 대문자(고유명사·문장 첫 단어)는 정상 영어이므로 소문자로 fold한다.
    어중 대문자는 영어 정서법 위반이므로 영어가 아닌 것으로 본다 — 이게 `내꾸`를
    지켜준다: `내꾸`의 키열은 `soRn`(ㄲ가 Shift+R)인데, 소문자로 fold하면 방언
    `sorn`에 걸려 교정이 막힌다. 전대문자는 이 분기 앞의 `acronymConvention`이
    이미 걸러내므로, 여기 남는 건 정확히 어중 대문자다.

    영어가 아니라고 판단하면 None을 반환한다.
    """
    if any(c.isupper() for c in keys[1:]):
        return None
    return keys.lower()


def build_korean():
    """모호 분기에 도달할 수 있는 **키열 → 한글** 매핑.

    한글 문자열이 아니라 매핑으로 두는 이유: 이러면 Swift가 한글 조합을 전혀
    수행하지 않고 사전 조회 한 번으로 끝난다. 두 언어의 조합 오토마톤이 미세하게
    달라 발산할 위험이 통째로 사라지고, 파리티가 문자열 동일성으로 환원된다.
    """
    out = {}
    for word in read_lines(KO_SOURCE):
        keys = g.ko_to_keys(word)
        if not keys or not is_ambiguous(keys):
            continue
        r = g.korean_eval(keys)
        if not r:
            continue
        korean = unicodedata.normalize("NFC", r["text"])
        if keys in out and out[keys] != korean:
            raise SystemExit(f"키열 충돌: {keys} -> {out[keys]} / {korean}")
        out[keys] = korean
    return out


def build_english():
    """모호 분기에 도달할 수 있는 영어 실단어 집합 (정책 C 정규화 적용)."""
    out = set()
    for word in read_lines(EN_SOURCE):
        if not word.isalpha():
            continue
        key = english_lookup_key(word)
        if key is None:
            continue
        if not is_ambiguous(word):
            continue
        out.add(key)
    return out


def write_lexicon(path: Path, entries):
    """코드포인트 오름차순 정렬, UTF-8, LF, **개행으로 종료**.

    개행 종료를 강제하는 이유: `ko_words.txt`가 개행 없이 끝나 `wc -l`이 실제
    항목 수보다 1 적게 나오는 혼란이 이미 있었다. 새 자산은 그러지 않는다.

    `entries`가 dict면 `키열<TAB>한글` 두 열로, set이면 한 열로 쓴다.
    """
    if isinstance(entries, dict):
        body = "\n".join(f"{k}\t{entries[k]}" for k in sorted(entries))
    else:
        body = "\n".join(sorted(entries))
    path.write_text(body + "\n", encoding="utf-8")
    return len(entries)


def cmd_generate():
    ko = build_korean()
    en = build_english()
    n_ko = write_lexicon(KO_OUT, ko)
    n_en = write_lexicon(EN_OUT, en)
    print(f"ko-lexicon.v1.txt  {n_ko:>6} entries  {KO_OUT.stat().st_size:>8} bytes")
    print(f"en-lexicon.v1.txt  {n_en:>6} entries  {EN_OUT.stat().st_size:>8} bytes")


def cmd_verify():
    """투영이 판정에 대해 무손실인지 원본 사전과 대조한다.

    원본으로 판정한 결과와 투영으로 판정한 결과가 모든 표본에서 같아야 한다.
    """
    # 원본 사전 (투영 전)
    ko_full = set(unicodedata.normalize("NFC", w) for w in read_lines(KO_SOURCE))
    en_full = set()
    for w in read_lines(EN_SOURCE):
        if w.isalpha():
            key = english_lookup_key(w)
            if key is not None:
                en_full.add(key)

    # 투영본 (앱이 실제로 읽을 것)
    ko_proj = {}
    for line in read_lines(KO_OUT):
        keys, korean = line.split("\t")
        ko_proj[keys] = korean
    en_proj = set(read_lines(EN_OUT))

    mismatches = 0
    checked = 0

    def decide_full(keys):
        """원본 사전으로 한 판정 — 한글을 매번 조합해 사전에 조회한다."""
        if not is_ambiguous(keys):
            return None
        r = g.korean_eval(keys)
        if not r:
            return None
        korean = unicodedata.normalize("NFC", r["text"])
        if korean not in ko_full:
            return None
        key = english_lookup_key(keys)
        if key is not None and key in en_full:
            return None
        return korean

    def decide_proj(keys):
        """투영본으로 한 판정 — 조합 없이 매핑 조회 한 번. Swift가 하는 것과 동일."""
        if not is_ambiguous(keys):
            return None
        korean = ko_proj.get(keys)
        if korean is None:
            return None
        key = english_lookup_key(keys)
        if key is not None and key in en_proj:
            return None
        return korean

    # 한국어 어절 전수 + 영어 사전 전수를 모두 대조한다.
    samples = []
    for word in read_lines(KO_SOURCE):
        keys = g.ko_to_keys(word)
        if keys:
            samples.append(keys)
    for word in read_lines(EN_SOURCE):
        if word.isalpha():
            samples.append(word)

    for keys in samples:
        checked += 1
        if decide_full(keys) != decide_proj(keys):
            mismatches += 1
            if mismatches <= 5:
                print(f"  MISMATCH: {keys}")

    print(f"검증 표본 {checked}개, 불일치 {mismatches}개")
    if mismatches:
        print("투영이 무손실이 아니다 — 생성 로직을 확인하라.")
        return 1
    print("투영 무손실 확인.")
    return 0


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "generate"
    if cmd == "generate":
        cmd_generate()
    elif cmd == "verify":
        sys.exit(cmd_verify())
    else:
        print(__doc__)
        sys.exit(2)
