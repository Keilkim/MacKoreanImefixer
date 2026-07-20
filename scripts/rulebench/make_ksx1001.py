# -*- coding: utf-8 -*-
"""ksx1001.txt 생성기.

KS X 1001 완성형 현대 한글 음절 2,350자를 CP949 인코딩 바이트 범위에서
유도한다 (lead 0xB0~0xC8, trail 0xA1~0xFE). 목록을 직접 기재하지 않고
표준 인코딩 테이블에서 계산하므로 '샘플 하드코딩'이 아니라 규칙이다.

Swift 구현(KSX1001Table)도 동일 규칙을 CFString EUC-KR 변환으로 수행한다.
"""
import os

out = []
for cp in range(0xAC00, 0xD7A4):
    ch = chr(cp)
    try:
        b = ch.encode('cp949')
    except UnicodeEncodeError:
        continue
    if len(b) == 2 and 0xB0 <= b[0] <= 0xC8 and 0xA1 <= b[1] <= 0xFE:
        out.append(ch)

assert len(out) == 2350, f"KS X 1001 음절 수는 2,350이어야 함: {len(out)}"
path = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'ksx1001.txt')
open(path, 'w', encoding='utf-8').write(''.join(sorted(out)))
print(f"wrote {len(out)} syllables -> {path}")
