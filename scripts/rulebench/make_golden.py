# -*- coding: utf-8 -*-
"""Corpus/structure-correction/v2/golden.tsv 생성기.

파이썬 레퍼런스 구현(genrules)의 판정을 규칙 ID 단위로 계층 표집해 고정한다.
Swift `GoldenCorpusParityTests`가 이 파일을 읽어 동일한 결과를 내는지 검증하므로,
두 구현이 갈라지면 즉시 드러난다.

행은 손으로 고른 사례가 아니라 규칙별 계층 표집 결과다. 표집은 고정 시드로
결정적이며, 규칙이 바뀌면 이 스크립트를 다시 돌려 갱신한다.

사용법:
    python3 -B scripts/rulebench/make_golden.py
"""
import os
import pathlib
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from genrules import explain_l2k, explain_k2l, ko_to_keys  # noqa: E402

REPO = pathlib.Path(HERE).parent.parent
OUT = REPO / 'Corpus' / 'structure-correction' / 'v2' / 'golden.tsv'

PER_RULE = 40
SEED = 20260720

HEADER = [
    'id', 'direction', 'physical_keys', 'expected_action',
    'expected_original', 'expected_replacement', 'expected_tier', 'rule',
]


def load_tokens():
    eng = [w.strip().lower() for w in open('/usr/share/dict/words', encoding='utf-8', errors='ignore')]
    eng = [w for w in eng if w.isalpha() and w.isascii() and 2 <= len(w) <= 12]
    ko = [w.strip() for w in open(os.path.join(HERE, 'ko_words.txt'), encoding='utf-8') if w.strip()]
    kokeys = [ko_to_keys(w) for w in ko]
    kokeys = [k for k in kokeys if k and k.isalpha()]
    return eng, kokeys


def main():
    rng = random.Random(SEED)
    eng, kokeys = load_tokens()

    # 대문자 변형은 약어 규칙(R-D3)을 덮기 위해 별도로 만든다.
    upper = [k.upper() for k in rng.sample(kokeys, 400)]
    initial_cap = [k[0].upper() + k[1:] for k in rng.sample(kokeys, 400) if len(k) >= 2]

    buckets = {}

    def offer(direction, keys, explain):
        action, tier, rule, replacement = explain(keys)
        key = (direction, rule)
        bucket = buckets.setdefault(key, [])
        if len(bucket) >= PER_RULE:
            return
        if any(row[0] == keys for row in bucket):
            return
        bucket.append((keys, action, tier, rule, replacement))

    l2k_pool = kokeys + eng + upper + initial_cap
    k2l_pool = eng + kokeys + initial_cap
    rng.shuffle(l2k_pool)
    rng.shuffle(k2l_pool)

    for keys in l2k_pool:
        offer('latin_to_korean', keys, explain_l2k)
    for keys in k2l_pool:
        offer('korean_to_latin', keys, explain_k2l)

    rows = []
    for (direction, rule) in sorted(buckets):
        for index, (keys, action, tier, _, replacement) in enumerate(sorted(buckets[(direction, rule)])):
            prefix = 'l2k' if direction == 'latin_to_korean' else 'k2l'
            original = keys if direction == 'latin_to_korean' else _korean_text(keys)
            rows.append([
                f'{prefix}-{rule}-{index:03d}',
                direction,
                keys,
                action,
                original if action == 'correct' else '-',
                replacement if action == 'correct' else '-',
                tier if tier else '-',
                rule,
            ])

    OUT.parent.mkdir(parents=True, exist_ok=True)
    with open(OUT, 'w', encoding='utf-8', newline='\n') as handle:
        handle.write('\t'.join(HEADER) + '\n')
        for row in rows:
            assert all(field for field in row), row
            handle.write('\t'.join(row) + '\n')

    print(f'wrote {len(rows)} rows -> {OUT}')
    counts = {}
    for row in rows:
        counts[(row[1], row[7])] = counts.get((row[1], row[7]), 0) + 1
    for key in sorted(counts):
        print(f'  {key[0]:16s} {key[1]:24s} {counts[key]}')


def _korean_text(keys):
    from genrules import korean_eval
    evaluation = korean_eval(keys)
    return evaluation['text'] if evaluation else '-'


if __name__ == '__main__':
    main()
