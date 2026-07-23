#!/usr/bin/env python3
"""한글 단음절 교정 자산 `ko-mono.v1.txt` 를 생성하고 검증한다.

## 왜 "무손실 투영"이 아니라 "두 투영의 합집합"인가

`make_lexicon.py` 는 원본 사전(`ko_words.txt`)의 부분집합을 만들고 그것이 판정에
대해 무손실임을 증명한다. 단음절 도메인에는 **그 원본이 없다** — `ko_words.txt`
19,894행에 1음절 어절이 0개이고, `scripts/rulebench/**` 는 engine-freeze 대상이라
거기에 단음절을 넣는 것 자체가 R4-1 위반이다. 그래서 정당화를 두 축으로 대체한다.

  KEEP   동결 엔진(`genrules.explain_l2k`)이 **오늘 실제로 시행하는** 단음절 교정의
         투영. 사람 판단이 0이다. 이 투영이 필요한 이유는 관문(LexicalGuard)이
         단음절 도메인 **전체**에 걸리기 때문이다 — 관문을 통과할 자격을 자산이
         유일하게 정의하므로, 오늘의 동작을 회귀 없이 유지하려면 오늘의 동작이
         자산에 명시돼 있어야 한다. 이건 "이 교정이 옳다"는 승인이 아니라
         "오늘 이대로다"의 동결이다.

  RESCUE 문법적 폐쇄류(T1)·유한 열거 부류(T2)로 선언한 한글 단음절 단어의
         `ko_to_keys` 투영. 손 목록과의 차이는 **정지 조건의 존재**다: 부류마다
         `#bound` 상한을 선언하고 verify 가 그 숫자를 강제하므로, 목록을 키우려면
         상한 한 줄을 고쳐야 하고 그 diff 가 리뷰 트리거가 된다.

## 사람이 답하는 질문은 정확히 둘이고, 서로 다른 파일에 산다

  mono-source.ko.tsv   "이 한글이 이 부류의 구성원인가"   (한글 측 문법 사실)
  mono-veto.tsv        "이 라틴 키열이 실사용 토큰인가"   (라틴 측 사용 사실)

빈도·가치 판단은 어느 파일에도 적지 않는다. 있으면 그건 손 목록이다.
**키열은 사람이 한 글자도 적지 않는다** — 허용 방향은 반드시 한글로 적고 키열은
`genrules.ko_to_keys`(동결 매핑의 파이썬 정본)가 계산한다. 키열을 직접 적을 수
있으면 아래 게이트를 우회해 항목을 밀어 넣을 수 있기 때문이다. 반대로 거부
방향은 키열로 적는다 — 거부는 추가가 언제나 단조 안전하다. 이 비대칭이 안전 축이다.

## 안전 게이트 — 전부 OS 자산의 투영이고, 스냅샷으로 결정적이다

  EN   /usr/share/dict/words. `english_lookup_key`(정책 C) 정규화.
  CLI  /bin /usr/bin /sbin /usr/sbin 의 2~5자 소문자 실행파일명.
       사전이 원리적으로 못 잡는 부류다 — `rm`·`du` 는 web2 에 없다.
  LOC  /usr/share/locale 의 2~3자 언어 코드. `sk`(→나)가 손 판정 없이 여기서 잡힌다.
  DENY mono-veto.tsv. OS 자산이 모르는 것만 기록한다.

  게이트는 정책 C 를 그대로 따른다. `english_lookup_key(keys) is None`(= 어중
  대문자)이면 영어·약어로 볼 수 없으므로 어떤 게이트도 적용하지 않는다. 이게
  `dP`(예)를 `dp`(에)와 분리한다.

  **왜 스냅샷인가**: 게이트 입력은 OS 자산이라 기계·러너 이미지마다 다르다.
  `verify` 가 CI 에서 그것을 다시 스캔하면 자산과 무관한 원인으로 실패하고,
  실패 메시지는 "손으로 편집했다"로 오도한다. 그래서 `generate` 는 OS 를 읽어
  **도메인과 교차하는 부분만** `mono-gates.v1.txt` 로 떨궈 저장소에 커밋하고,
  `verify` 는 그 스냅샷만 읽는다. OS 가 바뀌면 `generate` 재실행 시 스냅샷 diff 가
  보이고, 그 diff 가 곧 게이트 변화의 기록이다(lexicon-freeze 규약과 동일).

  `/etc/services` 는 검토 후 기각했다. 짧은 이름이 613개라 오탐이 커
  `ems`→든(보조사)을 죽인다. 게이트는 재현율이 아니라 정밀도로 고른다.

사용법:
    python3 -B make_mono_lexicon.py generate   # 자산 + 스냅샷 + fixture 생성
    python3 -B make_mono_lexicon.py verify     # 불변식 11개 (CI, 결정적)
    python3 -B make_mono_lexicon.py surface    # 파괴 표면 상한 검사 (CI)
    python3 -B make_mono_lexicon.py audit      # 비결정적 감사($PATH). CI 금지.

갱신 절차:
    1) mono-source.ko.tsv · mono-veto.tsv · mono-admit.tsv 중 하나를 편집한다
    2) generate -> verify -> surface -> audit (audit 출력은 PR 본문에 붙인다)
    3) scripts/lexicon-freeze.sha256 을 `>>` 로 갱신한다 (정렬하지 말 것 — 추가 순서다)
"""

import os
import sys
import unicodedata
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
sys.path.insert(0, str(HERE.parent / "rulebench"))
sys.path.insert(0, str(HERE))

import genrules as g  # noqa: E402
from make_lexicon import english_lookup_key, read_lines  # noqa: E402

SOURCE = HERE / "mono-source.ko.tsv"
VETO = HERE / "mono-veto.tsv"
ADMIT = HERE / "mono-admit.tsv"
GATES = HERE / "mono-gates.v1.txt"
OUT = HERE / "ko-mono.v1.txt"
KO_LEX = HERE / "ko-lexicon.v1.txt"
FIXTURE = REPO / "Corpus" / "lexical" / "v1" / "monosyllable.tsv"

EN_SOURCE = Path("/usr/share/dict/words")
BIN_DIRS = ("/bin", "/usr/bin", "/sbin", "/usr/sbin")
LOCALE_DIR = "/usr/share/locale"

# 파괴 표면 상한. 올릴 때는 사유를 커밋 메시지에 남긴다.
SURFACE_LIMIT = 600
# T2(닫혀 있지 않은 부류) 총합 상한.
T2_LIMIT = 60
T2_CLASSES = ("감탄사", "부사", "용언활용")
CLASSES = ("keep", "조사", "대명사", "의존명사", "수관형사") + T2_CLASSES
VETO_CODES = ("ABBR_LOWER", "CLI_THIRD")
VETO_STATUS = ("active", "prospective")

CHO = "ㄱㄲㄴㄷㄸㄹㅁㅂㅃㅅㅆㅇㅈㅉㅊㅋㅌㅍㅎ"
JUNG = "ㅏㅐㅑㅒㅓㅔㅕㅖㅗㅘㅙㅚㅛㅜㅝㅞㅟㅠㅡㅢㅣ"

# 음성 표본 — fixture 에 `preserve` 로 박아 회귀를 고정한다.
#
# mono-admit.tsv 로 연 키열(eh·go·dl·dml·dp·tl·ch·wp·gh·sk·di·ro·Eh·aht 등)은
# 여기서 뺐다. 같은 키열을 자산에도 넣고 "보존해야 한다"고도 적으면 모순이고,
# `write_fixture` 가 그 모순을 실제로 잡아 준다(생성이 멈춘다).
NEGATIVES = (
    "dns sns xml tls fps skt smt thx gmt dhl cma dha "
    "an sh th do so to ao ah en rm du dir wo"
).split()


# ---------- 도메인 전수 열거 ----------

def enumerate_domain():
    """현대 한글 1음절이 되는 키열 전수.

    구성적 열거(초성19 x 중성21 x 종성28)이므로 표본이 아니라 전수다. 음절에서
    키열을 얻고(`ko_to_keys`) 다시 조합해(`korean_eval`) 같은 음절로 돌아오는
    것만 남기므로, 매핑이 어긋난 항목은 여기서 이미 탈락한다.
    """
    out = {}
    for i in range(len(CHO)):
        for j in range(len(JUNG)):
            for t in range(28):
                syllable = chr(0xAC00 + i * 588 + j * 28 + t)
                keys = g.ko_to_keys(syllable)
                if not keys:
                    continue
                r = g.korean_eval(keys)
                if not r or r["syl"] != 1 or not r["fully"] or r["text"] != syllable:
                    continue
                out[keys] = syllable
    return out


def is_vowelless(keys):
    """라틴 모음이 하나도 없는가. 오늘의 LexicalGuard 게이트 조건 재현용이다."""
    return not any(c in "aeiou" for c in keys.lower())


def live_today(keys):
    """오늘 이 키열이 실제로 화면을 바꾸는가.

    동결 엔진이 `.correct` 를 내고, 현행 무모음 게이트가 거부하지 않는 것.
    KEEP 의 정의이자 회귀 가드(불변식 3)의 기준이다.
    """
    action, _tier, _rule, _repl = g.explain_l2k(keys)
    return action == "correct" and not is_vowelless(keys)


# ---------- 게이트 ----------

def scan_os_gates(domain):
    """OS 자산을 읽어 **도메인과 교차하는 부분만** 남긴 게이트 스냅샷.

    도메인 밖 항목은 이 계층의 판정에 영향을 줄 수 없으므로 버려도 무손실이다.
    (`make_guard_lexicon.py` 의 "자음 자판 글자 부분집합" 과 같은 계보다.)
    """
    lookup = {}
    for keys in domain:
        key = english_lookup_key(keys)
        if key is not None:
            lookup.setdefault(key, []).append(keys)

    hits = {}

    def note(key, source):
        if key in lookup:
            hits.setdefault(key, source)

    for word in read_lines(EN_SOURCE):
        if word.isalpha():
            key = english_lookup_key(word)
            if key is not None:
                note(key, "EN")

    for directory in BIN_DIRS:
        try:
            names = os.listdir(directory)
        except OSError:
            continue
        for name in names:
            if name.isalpha() and name.islower() and 2 <= len(name) <= 5:
                note(name, "CLI")

    try:
        entries = os.listdir(LOCALE_DIR)
    except OSError:
        entries = []
    for entry in entries:
        code = entry.split("_")[0].split(".")[0]
        if code.isalpha() and code.islower() and 2 <= len(code) <= 3:
            note(code, "LOC")

    return hits


def write_gates(hits):
    body = "\n".join(f"{k}\t{hits[k]}" for k in sorted(hits))
    GATES.write_text(body + "\n", encoding="utf-8")
    return len(hits)


def read_gates():
    hits = {}
    for line in read_lines(GATES):
        if line.startswith("#"):
            continue
        key, source = line.split("\t")
        hits[key] = source
    return hits


def read_veto():
    """거부 원장. `키열 -> (status, code, reason)`."""
    rows = {}
    seen_header = False
    for line in read_lines(VETO):
        if line.startswith("#"):
            continue
        if not seen_header:
            if line != "keys\tstatus\tcode\treason":
                raise SystemExit(f"mono-veto.tsv 헤더가 다릅니다: {line}")
            seen_header = True
            continue
        parts = line.split("\t", 3)
        if len(parts) != 4:
            raise SystemExit(f"mono-veto.tsv 형식 오류: {line}")
        keys, status, code, reason = parts
        rows[keys] = (status, code, reason)
    return rows


def read_admit():
    """사람이 게이트를 이기는 목록. `키열 -> (위험도, 사유)`.

    자동 게이트는 "이 키열이 다른 뜻으로도 쓰인다"를 잡을 뿐 **어느 쪽이 더 자주
    쓰이는지는 모른다.** 그 저울질은 데이터가 아니라 판단이므로 자리를 따로 둔다.
    """
    rows = {}
    seen_header = False
    for line in read_lines(ADMIT):
        if line.startswith("#"):
            continue
        if not seen_header:
            if line != "keys\trisk\treason":
                raise SystemExit(f"mono-admit.tsv 헤더가 다릅니다: {line}")
            seen_header = True
            continue
        parts = line.split("\t", 2)
        if len(parts) != 3:
            raise SystemExit(f"mono-admit.tsv 형식 오류: {line}")
        keys, risk, reason = parts
        rows[keys] = (risk, reason)
    return rows


def gate(keys, hits, veto, admit=frozenset()):
    """이 키열을 거부해야 하면 사유 문자열을, 통과면 None 을 돌려준다.

    `admit` 에 있으면 어떤 게이트보다 먼저 통과시킨다 — 사람이 위험을 알고 연
    항목이기 때문이다. 대소문자를 접지 않고 **정확히** 비교한다(`Eh`=또 ≠ `eh`=도).
    """
    if keys in admit:
        return None
    key = english_lookup_key(keys)
    if key is None:
        # 정책 C — 어중 대문자는 영어 표기가 아니므로 어떤 게이트도 적용하지 않는다.
        return None
    if key in veto:
        return "DENY"
    return hits.get(key)


# ---------- 소스 ----------

def read_source():
    """선언 소스. `(부류, 한글)` 목록과 `#bound` 선언을 함께 돌려준다."""
    bounds = {}
    rows = []
    for line in read_lines(SOURCE):
        if line.startswith("#bound "):
            _, name, count = line.split()
            bounds[name] = int(count)
            continue
        if line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) != 2:
            raise SystemExit(f"mono-source.ko.tsv 형식 오류: {line}")
        cls, word = parts
        if cls not in CLASSES or cls == "keep":
            raise SystemExit(f"알 수 없는 부류: {cls}")
        rows.append((cls, unicodedata.normalize("NFC", word)))
    return rows, bounds


# ---------- 조립 ----------

def build():
    """자산 본문을 만든다. `(entries, provenance, rejected, bounds, veto, domain, hits)`."""
    domain = enumerate_domain()
    hits = read_gates() if GATES.exists() else scan_os_gates(domain)
    veto = read_veto()
    admit = set(read_admit())

    entries = {}
    provenance = {}
    rejected = []

    # KEEP — 오늘 살아 있는 교정의 투영. 사람 판단 0.
    for keys, syllable in domain.items():
        if not live_today(keys):
            continue
        reason = gate(keys, hits, veto, admit)
        if reason:
            rejected.append((syllable, keys, "keep", reason))
            continue
        entries[keys] = syllable
        provenance[keys] = "keep"

    # RESCUE — 선언한 한글의 키열 투영.
    source_rows, bounds = read_source()
    for cls, word in source_rows:
        keys = g.ko_to_keys(word)
        if not keys:
            rejected.append((word, "-", cls, "NOKEYS"))
            continue
        if keys not in domain or domain[keys] != word:
            rejected.append((word, keys, cls, "NOTMONO"))
            continue
        reason = gate(keys, hits, veto, admit)
        if reason:
            rejected.append((word, keys, cls, reason))
            continue

        action, _tier, rule, _repl = g.explain_l2k(keys)
        if action == "correct" or rule == "weakKoreanStructure":
            # 갈래 A(오늘 R-K4가 막던 2키) / B(오늘 무모음 가드가 막던 3키+) /
            # K(이미 KEEP — 부류 라벨만 승격).
            pass
        else:
            # `ambiguousBothValid` 는 주인이 LexicalTiebreaker 다. 건드리지 않는다.
            rejected.append((word, keys, cls, "BRANCH:" + rule))
            continue

        if keys in entries and entries[keys] != word:
            raise SystemExit(f"키열 충돌: {keys} -> {entries[keys]} / {word}")
        entries[keys] = word
        # 같은 키열을 여러 부류가 선언하면 먼저 온 부류를 쓴다. `keep` 라벨은
        # 부류 선언이 있으면 그쪽으로 승격한다 — 자산이 감사 가능해야 하기 때문이다.
        if provenance.get(keys) in (None, "keep"):
            provenance[keys] = cls

    return entries, provenance, rejected, bounds, veto, domain, hits, admit


def write_mono(entries, provenance):
    """`키열<TAB>한글<TAB>부류`. 코드포인트 오름차순, NFC, UTF-8, LF, 개행 종료.

    3열인 이유: 자산 자체가 감사 가능해야 한다. 어느 행이 오늘의 동결(`keep`)이고
    어느 행이 이번에 새로 연 것인지가 파일 안에서 보여야 리뷰가 성립한다.
    Swift 는 3열을 읽고 부류는 버린다.
    """
    body = "\n".join(f"{k}\t{entries[k]}\t{provenance[k]}" for k in sorted(entries))
    OUT.write_text(body + "\n", encoding="utf-8")
    return len(entries)


def write_fixture(entries):
    """`Corpus/lexical/v1/tiebreaker.tsv` 와 같은 형식·같은 규율의 파리티 fixture."""
    lines = ["keys\taction\treplacement"]
    for keys in sorted(entries):
        lines.append(f"{keys}\tcorrect\t{entries[keys]}")
    for keys in sorted(set(NEGATIVES)):
        if keys in entries:
            raise SystemExit(f"음성 표본이 자산에 있습니다: {keys}")
        lines.append(f"{keys}\tpreserve\t")
    FIXTURE.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return len(lines) - 1


# ---------- 서브커맨드 ----------

def cmd_generate():
    domain = enumerate_domain()
    n_gates = write_gates(scan_os_gates(domain))
    entries, provenance, rejected, _bounds, _veto, _domain, _hits, _admit = build()
    n = write_mono(entries, provenance)
    n_fix = write_fixture(entries)
    keep = sum(1 for k in provenance.values() if k == "keep")
    print(f"mono-gates.v1.txt  {n_gates:>6} entries")
    print(f"ko-mono.v1.txt     {n:>6} entries  (keep {keep} / rescue {n - keep})")
    print(f"monosyllable.tsv   {n_fix:>6} rows")
    print(f"\n게이트·분기로 탈락한 선언 {len([r for r in rejected if r[2] != 'keep'])}개:")
    for word, keys, cls, reason in sorted(rejected, key=lambda r: (r[2], r[1])):
        if cls != "keep":
            print(f"  {word} ({cls}) {keys}: {reason}")
    print(f"\n오늘 살아 있으나 게이트가 닫는 교정 {len([r for r in rejected if r[2] == 'keep'])}개:")
    for word, keys, cls, reason in sorted(rejected, key=lambda r: r[1]):
        if cls == "keep":
            print(f"  {keys} -> {word}: {reason}")


def cmd_verify():
    problems = []

    def check(ok, message):
        if not ok:
            problems.append(message)

    entries, provenance, _rejected, bounds, veto, domain, hits, admit = build()

    # 1. 재생성 동일성 — 자산이 스크립트의 투영인가.
    expected = "\n".join(f"{k}\t{entries[k]}\t{provenance[k]}" for k in sorted(entries)) + "\n"
    actual = OUT.read_text(encoding="utf-8")
    check(expected == actual, "1 재생성 동일성: 자산이 build() 결과와 다릅니다 (손으로 편집했습니까?)")

    rows = []
    for line in read_lines(OUT):
        parts = line.split("\t")
        if len(parts) != 3:
            problems.append(f"10 형식: 3열이 아닌 행 {line!r}")
            continue
        rows.append(tuple(parts))

    # 2. 왕복 정합성 — Swift 가 한글을 조합하지 않으므로 여기가 유일한 정합성 보증이다.
    for keys, word, _cls in rows:
        r = g.korean_eval(keys)
        if g.ko_to_keys(word) != keys:
            problems.append(f"2 왕복: ko_to_keys({word}) != {keys}")
        elif not r or r["text"] != word or r["syl"] != 1 or not r["fully"]:
            problems.append(f"2 왕복: korean_eval({keys}) 가 {word} 단음절이 아닙니다")

    # 3. KEEP 완전성 — 오늘 동작하던 교정이 조용히 사라지지 않았는가.
    live = {k for k in domain if live_today(k) and not gate(k, hits, veto, admit)}
    asset_keys = {k for k, _w, _c in rows}
    missing = sorted(live - asset_keys)
    check(not missing, f"3 KEEP 완전성: 오늘 교정되는데 자산에 없는 키열 {len(missing)}개 {missing[:5]}")

    # 4. RESCUE 분기 제한 — 보류하기로 한 분기를 건드리지 않았는가.
    for keys, word, cls in rows:
        action, _t, rule, _r = g.explain_l2k(keys)
        if action != "correct" and rule != "weakKoreanStructure":
            problems.append(f"4 분기: {keys}({word}) 가 {rule} 분기입니다")
        # 5. replacement 일치 — 자산이 엔진과 다른 음절을 주장하지 않는가.
        if action == "correct" and _r != word:
            problems.append(f"5 replacement: {keys} 엔진={_r} 자산={word}")

    # 6. 게이트 무충돌.
    for keys, word, _cls in rows:
        reason = gate(keys, hits, veto, admit)
        if reason:
            problems.append(f"6 게이트: {keys}({word}) 가 {reason} 에 걸립니다")

    # 7. 원장 정합.
    for keys, (status, code, _reason) in veto.items():
        if status not in VETO_STATUS:
            problems.append(f"7 원장: {keys} status={status}")
        if code not in VETO_CODES:
            problems.append(f"7 원장: {keys} code={code}")
        if keys != keys.lower():
            problems.append(f"7 원장: {keys} 는 소문자여야 합니다")
        # 자산에 있어도 되는 경우는 하나뿐 — mono-admit.tsv 가 그 위험을 알고
        # 명시적으로 연 때다. 위험 기록(veto)과 결정 기록(admit)을 둘 다 남겨야
        # 나중에 "왜 열려 있는지"를 알 수 있다.
        if keys in asset_keys and keys not in admit:
            problems.append(f"7 원장: {keys} 가 허용 기록 없이 자산에 있습니다")
        if status == "active":
            # active 는 실제로 후보를 제거해야 한다 — stale 한 원장을 잡는다.
            removes = keys in domain and (
                live_today(keys) or any(g.ko_to_keys(w) == keys for _c, w in read_source()[0])
            )
            if not removes:
                problems.append(f"7 원장: active {keys} 가 아무 후보도 제거하지 않습니다")

    # 8. 부류 상한 — 부류가 몰래 자랐는가(= 손 목록화).
    source_rows, _b = read_source()
    counts = {}
    for cls, _w in source_rows:
        counts[cls] = counts.get(cls, 0) + 1
    for cls, bound in bounds.items():
        check(counts.get(cls, 0) == bound, f"8 상한: {cls} 선언 {counts.get(cls, 0)}개 != #bound {bound}")
    for cls in counts:
        check(cls in bounds, f"8 상한: {cls} 에 #bound 선언이 없습니다")
    t2 = sum(counts.get(c, 0) for c in T2_CLASSES)
    check(t2 <= T2_LIMIT, f"8 상한: T2 총합 {t2} > {T2_LIMIT}")

    # 9. 자산 분리 — ambiguousBothValid 보류 전제가 유효한가.
    ko_lex_keys, ko_lex_mono = set(), 0
    for line in read_lines(KO_LEX):
        keys, korean = line.split("\t")
        ko_lex_keys.add(keys)
        if len(korean) == 1:
            ko_lex_mono += 1
    overlap = sorted(asset_keys & ko_lex_keys)
    check(not overlap, f"9 자산 분리: ko-lexicon 과 겹치는 키열 {overlap[:5]}")
    check(ko_lex_mono == 0, f"9 자산 분리: ko-lexicon 에 1음절 값이 {ko_lex_mono}개 있습니다")

    # 11. 허용 원장 정합 — 키열만 적어 아무거나 열 수 없게 한다.
    #
    # 이 파일은 게이트를 이기므로 안전 장치를 우회하는 유일한 통로다. 그래서
    # (a) 그 키열이 mono-source.ko.tsv 에 선언된 한글에서 나온 것이어야 하고,
    # (b) 실제로 게이트에 막히던 것이어야 한다. (b)가 없으면 원장이 stale 해져
    # "왜 열려 있는지" 아무도 모르는 줄이 쌓인다.
    admit_rows = read_admit()
    declared = {}
    for cls, word in read_source()[0]:
        k = g.ko_to_keys(word)
        if k:
            declared[k] = word
    for keys, (risk, _reason) in admit_rows.items():
        if keys not in declared:
            problems.append(f"11 허용: {keys} 는 mono-source.ko.tsv 에 선언되지 않았습니다")
            continue
        if not gate(keys, hits, veto, frozenset()):
            problems.append(f"11 허용: {keys}({declared[keys]}) 는 원래 막히지 않습니다 — stale")
        if risk not in ("낮음", "보통", "높음"):
            problems.append(f"11 허용: {keys} risk={risk}")

    # 10. 형식·결정성.
    keys_list = [k for k, _w, _c in rows]
    check(keys_list == sorted(keys_list), "10 형식: 정렬되지 않았습니다")
    check(len(keys_list) == len(set(keys_list)), "10 형식: 중복 키열이 있습니다")
    check(OUT.read_text(encoding="utf-8").endswith("\n"), "10 형식: 개행으로 끝나지 않습니다")
    for keys, word, cls in rows:
        if cls not in CLASSES:
            problems.append(f"10 형식: 알 수 없는 부류 {cls}")
        if not (2 <= len(keys) <= 5):
            problems.append(f"10 형식: 키 길이 {keys}")
        if len(word) != 1 or not (0xAC00 <= ord(word) <= 0xD7A3):
            problems.append(f"10 형식: {word} 가 현대 한글 1음절이 아닙니다")
        if unicodedata.normalize("NFC", word) != word:
            problems.append(f"10 형식: {word} 가 NFC 가 아닙니다")
    fixture_rows = [line.split("\t") for line in read_lines(FIXTURE)[1:]]
    for parts in fixture_rows:
        keys, action, replacement = parts[0], parts[1], (parts[2] if len(parts) > 2 else "")
        resolved = entries.get(keys)
        want = "correct" if resolved else "preserve"
        if action != want or (action == "correct" and resolved != replacement):
            problems.append(f"10 fixture: {keys} 기대 {want}/{resolved} 실제 {action}/{replacement}")

    print(f"검증 항목 11개, 자산 {len(rows)}행, fixture {len(fixture_rows)}행, 불일치 {len(problems)}개")
    for message in problems[:5]:
        print(f"  MISMATCH: {message}")
    if problems:
        print("불변식이 깨졌다 — 생성 로직 또는 소스를 확인하라.")
        return 1
    print("단음절 자산 불변식 확인.")
    return 0


def cmd_surface():
    """자산 바이트가 아니라 **효과**를 센다.

    리뷰어가 diff 를 놓쳐도 "511 -> 900" 을 CI 가 숫자로 잡는다.
    """
    entries, provenance, _r, _b, _v, domain, _h, _a = build()
    correctable = sum(1 for k in domain if g.explain_l2k(k)[0] == "correct")
    keep = sum(1 for v in provenance.values() if v == "keep")
    print(f"현대 단음절 키열 전체            {len(domain):>6}")
    print(f"동결 엔진 .correct               {correctable:>6}")
    print(f"자산 허용 (keep {keep} / rescue {len(entries) - keep})".ljust(33) + f"{len(entries):>6}")
    print(f"단음절 교정 가능 키열            {len(entries):>6}   [상한 {SURFACE_LIMIT}]")
    if len(entries) > SURFACE_LIMIT:
        print(f"파괴 표면이 상한을 넘었다 ({len(entries)} > {SURFACE_LIMIT}).")
        return 1
    return 0


def cmd_audit():
    """비결정적 감사 — CI 에서 절대 돌리지 않는다.

    `$PATH` 전체(homebrew 포함)를 훑어 서드파티 CLI 충돌을 찾고, KEEP 중
    코퍼스 빈도 0인 행을 "동결과 함께 물려받은 미감사 표면"으로 보고한다.
    """
    entries, provenance, _r, _b, veto, _d, _h, _a = build()

    commands = set()
    for directory in os.environ.get("PATH", "").split(":"):
        if not directory:
            continue
        try:
            names = os.listdir(directory)
        except OSError:
            continue
        for name in names:
            if name.isalpha() and name.islower() and 2 <= len(name) <= 5:
                commands.add(name)

    clashes = []
    for keys, word in entries.items():
        key = english_lookup_key(keys)
        if key is not None and key in commands and key not in veto:
            clashes.append((keys, word))
    print(f"$PATH 명령 {len(commands)}개와의 충돌 {len(clashes)}개:")
    for keys, word in sorted(clashes):
        print(f"  {keys} -> {word}")

    frequency = {}
    for word in read_lines(HERE.parent / "rulebench" / "ko_words.txt"):
        for ch in word:
            frequency[ch] = frequency.get(ch, 0) + 1
    unseen = sorted(
        (k, w) for k, w in entries.items()
        if provenance[k] == "keep" and frequency.get(w, 0) == 0
    )
    print(f"\nKEEP 중 코퍼스 빈도 0인 음절 {len(unseen)}개 (동결과 함께 물려받은 미감사 표면):")
    print("  " + " ".join(f"{k}->{w}" for k, w in unseen))
    return 0


if __name__ == "__main__":
    command = sys.argv[1] if len(sys.argv) > 1 else "generate"
    if command == "generate":
        cmd_generate()
    elif command == "verify":
        sys.exit(cmd_verify())
    elif command == "surface":
        sys.exit(cmd_surface())
    elif command == "audit":
        sys.exit(cmd_audit())
    else:
        print(__doc__)
        sys.exit(2)
