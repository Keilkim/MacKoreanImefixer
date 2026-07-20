# -*- coding: utf-8 -*-
"""규칙 엔진 대량 벤치마크 + 저장소 코퍼스 회귀.

사용법:
    python3 -B scripts/rulebench/bench.py

평가셋:
  - 영어: /usr/share/dict/words (알파벳 2~12자, 약 19.8만)
  - 한국어: ko_words.txt (macOS ko.lproj 지역화에서 추출한 실제 어절 19,895)
  - 저장소 코퍼스: Corpus/structure-correction/v1/*.tsv

이 스크립트는 Swift 구현(LayoutCorrectionPolicy)의 기준 사양이다.
Swift 이식 후에는 golden-parity 테스트가 여기서 샘플링한 행과
Swift 출력이 일치하는지 검증한다.
"""
import csv
import os
import pathlib
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from genrules import decide_l2k, decide_k2l, ko_to_keys, korean_eval  # noqa: E402

REPO = pathlib.Path(HERE).parent.parent


def load_sets():
    eng = [w.strip().lower() for w in open('/usr/share/dict/words', encoding='utf-8', errors='ignore')]
    eng = [w for w in eng if w.isalpha() and w.isascii() and 2 <= len(w) <= 12]
    ko = [w.strip() for w in open(os.path.join(HERE, 'ko_words.txt'), encoding='utf-8') if w.strip()]
    kokeys = [(w, ko_to_keys(w)) for w in ko]
    kokeys = [(w, k) for w, k in kokeys if k and k.isalpha()]
    return eng, kokeys


def main():
    eng, kokeys = load_sets()
    print(f"평가셋: 영어 {len(eng):,} / 한국어 {len(kokeys):,}\n")

    th = tm = 0
    for _, k in kokeys:
        d = decide_l2k(k)
        if d:
            th += d[0] == 'high'
            tm += d[0] == 'medium'
    fp_h, fp_m = [], []
    for w in eng:
        d = decide_l2k(w)
        if d:
            (fp_h if d[0] == 'high' else fp_m).append(w)
    print(f"[영→한] 재현율 {100*(th+tm)/len(kokeys):.2f}% (high {th:,}/med {tm})   "
          f"오탐 {len(fp_h)+len(fp_m)} = h{len(fp_h)}+m{len(fp_m)} "
          f"({100*(len(fp_h)+len(fp_m))/len(eng):.4f}%)")

    t2h = t2m = 0
    for w in eng:
        d = decide_k2l(w)
        if d:
            t2h += d[0] == 'high'
            t2m += d[0] == 'medium'
    fp2 = [(w, k) for w, k in kokeys if decide_k2l(k)]
    print(f"[한→영] 재현율 {100*(t2h+t2m)/len(eng):.2f}% (high {t2h:,}/med {t2m:,})   오탐 {len(fp2)}")
    for w, k in fp2[:10]:
        print("   오탐:", w, k)

    base = REPO / 'Corpus' / 'structure-correction' / 'v1'
    for name in ['tune.tsv', 'holdout.tsv', 'system-evidence.tsv']:
        path = base / name
        if not path.exists():
            continue
        rows = list(csv.DictReader(open(path, encoding='utf-8'), delimiter='\t'))
        agree = 0
        dis = []
        for r in rows:
            keys = r['physical_keys']
            d = decide_l2k(keys) if r['direction'] == 'latin_to_korean' else decide_k2l(keys)
            predicted = 'correct' if d else 'preserve'
            okrepl = (not d) or r['expected_action'] != 'correct' or d[1] == r['expected_replacement']
            if predicted == r['expected_action'] and okrepl:
                agree += 1
            else:
                dis.append((r['id'], keys, r['expected_action'], predicted, r['category']))
        print(f"[코퍼스 {name}] 일치 {agree}/{len(rows)}")
        for x in dis:
            print("   불일치:", x)


if __name__ == '__main__':
    main()
