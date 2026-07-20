# Mackor 자판 교정·변환 방식 — 전체 규칙 정리 (코덱스 검토용)

이 문서는 지금까지 논의·구현·설계된 Mackor의 **양방향 한–영 키보드 레이아웃 오류
탐지 및 입력 의도 기반 자동 변환** 방식을 한 곳에 정리한다. 검토받고 싶은 부분은
§8에 별도 표기했다.

작성 시점의 실측·설계 근거는 `REQUIREMENTS.md`, `MIGRATION_PLAN.md`, 그리고
이번 세션의 프로토타입 데이터.

---

## 1. 문제 정의

철자 교정(spell check)이 **아니다.** 한글 두벌식과 영어 QWERTY가 **같은 물리 키**를
공유하므로, 사용자가 자판 상태를 착각하고 친 키열 `K`가 어느 언어를 의도한 것인지
판별하고 자동 변환한다.

```
K = 물리 키 시퀀스 (가상 키코드 + shift)
  dkwn  → 영어자판으로 침, 실은 "아주"(한글) 의도  → 영→한 변환
  ㅗ디ㅣㅐ → 한글자판으로 침, 실은 "hello"(영어) 의도 → 한→영 변환
```

양방향(l2k: 영→한, k2l: 한→영) 모두 대상.

---

## 2. 핵심: 이중 가설 판별 (STRUCTURE_CORRECTION_DESIGN4.md §1.3)

같은 `K`를 **두 독립 제약계**로 채점한다. 사전 조회가 아니라 구조 충족.

- **K-판정**: `K`를 두벌식으로 읽으면 정상 현대 한국어 구조인가
- **E-판정**: `K`를 QWERTY로 읽으면 정상 영어 음소배열·정서법인가

각각 `(통과 여부, 위반 비용)`을 반환하고, 방향별 규칙이 **상호 배타성 + 비용 마진**으로
교정/보존/신뢰등급(tier)을 정한다. 헌장(`genrules.py:3`): **사전/샘플 하드코딩 0,
모든 상수는 문법적 폐쇄류 또는 표준에서 유도.**

---

## 3. 현재 규칙 (v4, frozen — R4-1)

파이썬 레퍼런스 `genrules.py`가 정본, Swift `LayoutCorrectionPolicy`가 이식,
405행 골든이 두 구현 일치를 검증. **11개 규칙 각 40행씩 표집.**

### 3-1. 영→한 (`explain_l2k`)
```
1. keys 2자+ 전부 대문자           → preserve (acronymConvention)   GKSK/DHCP/NASA
2. 한글 조합 불가                  → preserve (compositionUnavailable)
3. K_strong 실패 (단음절/3키 미만) → preserve (weakKoreanStructure)  ← Eh(또) 여기
4. 영어 불가능                     → correct/high (koreanStructure)  dkwn→아주
5. 영어 가능하나 비용≥1            → correct/medium (englishCostMargin)
6. 영어 완벽(cost 0)              → preserve (ambiguousBothValid)   ← sork(내가) 여기
```

### 3-2. 한→영 (`explain_k2l`)
```
1. 한글 조합 불가                  → preserve (compositionUnavailable)
2. 완전 조합된 현대 한국어         → preserve (modernKoreanPreserved) 코드/리뷰
3. 2자+ 전부 같은 자모 반복        → preserve (expressiveRepetition)
4. 자음자모 3개+ 나열              → preserve (consonantJamoMash)
5. 영어 불가능                     → preserve (implausibleEnglish)
6. 영어 완벽 & 자음전부 아님       → correct/high (englishStructure)
7. 그 외                          → correct/medium (markedEnglishForm)
```

**비대칭 주의(코덱스 정정):** `sork` l2k는 `ambiguousBothValid`, k2l은
`modernKoreanPreserved` — 양방향 모두 보존. 이전에 "k2l은 변환"이라 한 것은 오독.

---

## 4. 제안 Layer 1 — 사전 tiebreaker (Step 3)

**목적:** 규칙만으로 못 가르는 `ambiguousBothValid`(영·한 양쪽 cost 0)를 사전으로 판별.

```
ambiguousBothValid 진입 시:
  한글 해석이 사전에 있고 영어 해석이 사전에 없으면 → correct
  둘 다 사전에 있으면(진짜 both-valid) → preserve 유지
```

**실측 (이번 세션):**
- 실제 한국어 3000개 표본: 규칙이 97% 교정, 2%(70개) 보존, 전부 ambiguousBothValid
- 70개를 NSSpellChecker로 판정: **살아남(교정) 59개(84%)** / 진짜애매 3개 / 한글 조회 실패 8개
- `sork→내가`, `모든`, `현재` 등이 살아남. `work`/`that` 등 실영어는 보존.
- **macOS에 한국어 사전 기본 내장** (`NSSpellChecker` `ko`, 별도 설치 불필요).
- **NSSpellChecker 조회 0.13ms/회** — 이벤트 탭 경로 블로킹 위험 없음.

**핵심 관문 (R4-1):** 파이썬 레퍼런스(`/usr/share/dict/words`)와 Swift(NSSpellChecker)가
**다른 사전을 쓰면 골든 파리티가 깨진다** (`ahems`가 dict/words엔 없고 NSSpellChecker엔 있음).
→ 코덱스 구조 채택: **v4 규칙 골든 405는 사전 없이 동결 유지**하고, 사전 tiebreaker는
그 **밖의 별도 후처리 계층**으로. 골든은 규칙만, 사전 계층은 자체 검증.

**⚠️ 검증으로 확정된 설계 제약 — NSSpellChecker를 정본으로 쓰면 안 된다:**
이 맥에서 직접 측정한 결과 NSSpellChecker는 **사전이 아니라 관대한 음절 승인기**다.
- 임의 KS X 1001 단일음절 2,350개 중 **1,108개(47.1%) hit** — `먀그무·퍅셔미·재강묘`
  같은 완전 비단어도 통과. 영어 2글자 조합 676개 중 221개 hit.
- 영어 구조 tie 2,521개를 양쪽 조회하면 174개를 both-hit로 판정하나 대부분 쓰레기.
- CamelCase `alRl`은 통과, 소문자 `alrl`은 miss (식별자 편향).
→ **Layer 1 tiebreaker의 정본은 반드시 버전·해시 고정된 실단어 목록**이어야 하고,
  **Python 레퍼런스와 Swift가 같은 그 파일을 읽어야** 한다. NSSpellChecker는 (OS·사용자
  학습사전에 따라 결과가 바뀌므로) 정본 금지 — 테스트에서 hit/miss 주입만 허용.
  단 "전부 쓰레기"는 아님(`모드·소개·애교·모든`은 진짜 단어) — "단어+비단어 무차별".

---

## 5. 제안 Layer 2 — confidence 문맥 소급 (Step R, 실험·flag-off)

**목적:** 사전으로도 못 가르는 **진짜 both-valid**(`Eh`: eh도 또도 사전에 있음)를
다음 단어 문맥으로 판별.

**사용자 설계 (스스로 안전 조건 도출):**
```
confidence = 판정 확신도 (연속값 0~1)
  1.0/0.0  koreanStructure / englishStructure (확정) → 절대 안 건드림
  0.5      ambiguousBothValid (both-valid) → 반반
  ~0.4     weakKoreanStructure (짧음)

애매 토큰(0.5±) 판정 시 → 임시 슬롯에 저장 (키열·화면UTF16길이·한글해석·앵커·confidence)
현재 토큰 = confidence-high 한국어 → 직전 슬롯(애매)을 한국어로 소급  (양방향 대칭)

저장 ≠ 소급:
  confidence 저장: 문장 내 여러 토큰 OK, 문장 경계(./엔터)에서 리셋 (전전 문장 안 넘음)
  화면 소급(되돌리기): 직전 하나만 (여러 단어 되돌리기는 커서 이동에 취약)

가드: 애매(0.5±)만 / 직전 이후 backspace·arrow·mouse·input-source·undo 없음 /
      공백 1개 인접 / reach cap(~24 UTF-16) / N-1의 english_eval veto(영어도 cost0이면 중단)
소급 실행: folded single transaction (기존 applyCorrection span 확장, 별도 라운드트립 금지)
엔진 동결 무접촉: 슬롯·소급은 EventTapManager. 엔진은 rule(confidence)만 제공.
```

**설계 워크플로 판정 (심판 2/2 만장일치): 이 형태로만, flag-off, 실기기 caret 검증 후.**
- 위험: 이미 화면에 정착된 직전 단어를 되돌림(커밋 경계 넘기) — 현재 단일 단어 경로가
  절대 안 넘는 유일한 안전선. `g,e,BS,o,o,d` 길이 오카운트 위험 확대.
- `weakKoreanStructure`는 `english_eval` 전에 반환되므로(`genrules.py:182`) veto 필수.

**실측 — Step R이 실제로 작동할 domain 크기 (이번 세션 대규모 측정):**

두 방향 모두 **엄격한 실단어 사전**(한글 `ko_words.txt` 19,895 / 영어 `/usr/share/dict/words`)
양쪽에 존재하는 진짜 both-valid를 전수 조사:

| 방향 | 후보 | 진짜 both-valid | 비율 |
|---|---|---|---|
| 영어단어가 한글로도 실단어 | 88,706 | **10** (dory 중복 제외 9쌍) | 0.01% |
| 한글단어가 영어로도 실단어 | 19,895 | **9** (동일 집합) | 0.05% |

**전체 목록 (전부, 4키·2음절):**
`ahem=모드` `dory=애교` `flak=리마` `thro=소개` `alem=미드` `coan=채무`
`woan=재무` `gowk=해자` `gowl=해지`. 이 중 사람이 영어로도 실제 칠 단어는
`ahem/dory/flak/thro` 정도 — **약 4개.**

**프로토타입 실행 결과 (읽기 전용, 동결 엔진 무접촉 — 이번 세션):**

메커니즘을 실제로 굴려보니 **confidence-슬롯 소급은 9쌍 both-valid를 안전하게 못 돕는다:**
```
work 했어  →  '재가' 했어      ❌ (개발자가 매일 치는 코드스위칭이 소급을 발동)
ahem 그리고 →  '모드' 그리고    ❌ (영어 감탄사 의도인데 오변환)
dory 많아  →  '애교' 많아       ✅ (의도가 한국어면 맞음)
```
- 이득(`dory→애교`)과 피해(`work→재가`)는 **구조적으로 동일**: 둘 다 conf=0.5 애매 +
  다음이 확정 한국어. 신호가 같아 분리 불가.
- veto("영어도 cost0이면 중단")를 켜면 both-valid는 **정의상 영어 cost0** → 9쌍 전부 차단
  → **이득도 0.** veto와 이득이 상호배타. → **confidence-슬롯 소급만으로는 both-valid를
  못 돕는다. 빈도(n-gram, Step 4) 없이는 `work`를 지킬 수 없다.**
- 유일하게 안전하게 남는 건 `Eh→또`류: `weakKoreanStructure`이며 영어 cost>0(영어로 안
  읽힘)이라 veto 밖. Step R의 실효 domain = 이 초단어들뿐.

**검증이 밝힌 결정적 조건부성 (Step R의 실효 domain을 다시 축소):**
- **단음절 도메인은 애초에 측정된 적이 없다.** `ko_words.txt`(19,895개)에 **한글 1음절
  단어가 0개** — 그래서 지금까지의 모든 측정이 `Eh↔또`류를 한 번도 실행시키지 못했다.
- **`Eh`류는 현재 파이프라인에서 이미 전부 보존된다.** `Eh/eh/ah/go/do/so/to`... 17개
  단음절 전부가 `english_eval` **도달 전에** `K_strong` 게이트(R-K4: 단음절은 3키+ 요구)에서
  `weakKoreanStructure`로 끝난다. 즉 veto 역설은 "현재 버그"가 아니라 **K_strong을 완화해야
  나타나는 함정.** 지금은 단음절을 아예 안 건드리는 게 설계다.
- **veto는 cost만 보면 안 된다:** `dk/dl/rm/wk`(→아/이/그/자)는 `(ok=False, cost=0)`.
  cost 필드만 검사하면 clean-English `(True,0)`과 혼동. **veto 조건은 `ok=True && cost==0`**
  이어야 안전. (검증 실측)

**중요한 층위 구분 (사용자 질문 "both-valid가 얼마나 많나"에 대한 정직한 답):**
- **구조적** both-valid(규칙이 못 가름, 영·한 cost 둘 다 0) = **한국어 어절의 1.965%(391/19,895)**,
  **영어 단어의 1.09%(2,572/235,976, 이 맥 web2 기준)**. (코덱스가 인용한 1.306%는 다른
  198,485개 목록을 써서 백분율이 부풀려진 것 — 절대수 2,500대는 근접, **검증으로 정정.**)
  절대 적지 않다. 사용자 직관("both-valid 많다")은 이 단계에서 옳다.
- **짧을수록 급증(검증 확인):** 한국어 2음절 6.63% → 3음절 1.56% → 4음절 0.47% →
  5음절 0.037% → 6음절+ **0%.** 애매는 사실상 2~3음절 단어의 문제.
- 그 2,500개를 **Layer 1 사전이 0.01%(9쌍)로 붕괴**시킨다. 나머지 2,491개는 "구조는
  둘 다 되나 실단어는 한쪽뿐" → 문맥 없이 사전이 즉시·안전 해결.
- 따라서 **Layer 2(Step R)에 남는 실제 domain = 이 9쌍 + `Eh`류 초단어.**
- **경고(사전 관대함):** NSSpellChecker `ko`는 `먀그무`·`먀디` 같은 비단어도 통과시켜,
  같은 측정이 504개로 부푼다. 이는 진짜 애매가 아니라 사전 leniency. `ko_words.txt`도
  명사 목록이라 조사·어미·채팅체·고유명사 부재 — 진짜 값은 9와 504 사이지만 **9 쪽에 가깝다.**

---

## 6. 실행 안전 (배관)

교정 판정이 아무리 맞아도 실행 계층이 불안정하면 사용자는 "안 된다/멈춘다"로 겪는다.

- **멈춤**: 이벤트 탭 소스가 메인 런루프(`EventTapManager.swift:359-361`)라, 교정 실행의
  AX IPC + usleep이 전역 입력을 막을 수 있음. 권한 회수 시 무효 탭이 입력 경로에 잔존.
  → Step 1-A(무효 탭 정리, `handleSystemTapDisabled`) 커밋. Step 1-B(실행을 메인 밖으로) 미착수.
- **"갑자기 안됨"**: 앱 전환 직후 AX 트리가 cold → 첫 토큰 포커스 체크 실패. KAIST CHI 2019가
  "모드 오류의 78%가 앱 전환 직후"라 보고(단, 우리 AX cold와 **같은 원인으로 입증된 건 아님** —
  같은 경계에서 겹치는 두 현상). → AX 워밍업 미착수.

## 7. 안전 경계 (필터)

`FocusedInputSafety`: **URL·비밀번호만** 보호. 이전엔 검색창까지 막아 한글 입력의
주 무대를 차단 → Step 2에서 `search/검색/location/위치` 제거, `주소/url/password`만 유지.
role 화이트리스트에 `AXComboBox` 추가(브라우저 입력란). 커밋됨.

## 8. 검증 자산 (R4-1)

- **v4 규칙 골든 405** (`golden.tsv`): Python↔Swift 규칙 일치. 코덱스 권고대로 **품질 정답이
  아니라 "규칙 특징 동결" 증거.** 개명 후보 `v4-rule-parity`.
- **최종 품질**은 별도 **사람 라벨 holdout**으로 판정(신규·핵심). 골든이 최종 결정을 고정하면
  개선 때마다 재생성해야 하고 새 버그도 정답으로 승인됨.
- 사전(Layer 1)·문맥(Layer 2)은 **골든 밖 별도 계층 + 자체 parity fixture.**

---

## 9. 코덱스 검토 완료 — 원래 질문과 답

코덱스가 §1~8을 검토했고, 그 주장을 이 맥에서 **직접 실측 검증**했다(§10). 원래 5개
질문은 아래로 정리된다:

1. Layer 1을 골든 밖 별도 계층으로 → **맞다.** 단 정본은 NSSpellChecker가 아니라
   **버전·해시 고정 실단어 목록**(Python·Swift 공용)이어야 한다(§4·§10에서 확정).
2. confidence 문맥 소급이 both-valid를 못 돕는다 → **맞다, 검증됨.** Step R 보류.
3. 연속 confidence → **폐기.** 0.0=영어/1.0=한국어는 confidence가 아니라 언어방향 점수.
   이산 분리(`coreRule / lexicalVerdict / contextClass / finalAction`) 채택.
4. 우선순위 → 재배치(§10 결정).
5. 놓친 위험 → 단음절 도메인 미측정, veto의 `ok=True` 결합 필요(§5·§10).

---

## 10. 결정 (실측 검증 후, 확정)

코덱스 분석을 이 맥에서 4갈래 병렬 실측으로 검증한 결과(측정치 대부분 CONFIRMED, 영어
백분율 1건만 분모 차이로 REFUTED, 코드 5건 전부 CONFIRMED), 다음으로 확정한다:

**A. Step R(confidence 문맥 소급) 종료 — 보류가 아니라 확정.**

Layer 1 구현 후 재측정하니 판단이 아니라 **증명**으로 닫혔다. 소급이 노릴 수 있었던
두 domain이 모두 비어 있다:

*(1) both-valid domain = 정확히 0.* Layer 1은 "한쪽만 실단어"인 경우를 전부 가져간다.
따라서 남는 잔여는 **정의상 "양쪽 다 실단어"** 인데, 그게 바로 소급의 안전 veto가
반드시 발동해야 하는 조건이다. 실측: 잔여 9개 전부 영어도 실단어 → **veto 9/9 발동**
→ 소급이 안전하게 건드릴 토큰 **0개**. 두 기법이 겹침 0으로 공간을 분할한다.
```
ahem=모드 thro=소개 gowl=해지 gowk=해자 woan=재무
coan=채무 alem=미드 flak=리마 dory=애교      ← 9/9 모두 veto
```

*(2) 단음절 domain = R4-1로 차단.* `Eh↔또`류에 도달하려면 단음절을 막는
`isStrongKoreanCandidate` 게이트(`LayoutCorrectionPolicy.swift:90`)를 완화해야 하는데,
그 파일은 **동결 대상**(`engine-freeze.sha256:13`)이라 마이그레이션 중 수정 자체가
R4-1 위반이다. 게다가 그 게이트를 열면 소급 발동 가능한 2키 단음절 403개 중 18개가
실제 영어 단어라 오변환이 되는데, 그 18개에 **사용자의 대표 사례 `Eh`(또)가 그대로
들어 있다** — `ah eh sh th Eh` 등 실제로 자주 치는 짧은 영어가 오변환 대상이다.
(403이라는 분모는 `먀·뮤`처럼 아무도 안 치는 음절이 대부분이라 4.5%라는 오변환률은
빈도 가중하면 훨씬 나쁘다.)

결론: 사용자 직관("다음 단어로 애매한 걸 재검토")은 방향이 옳았고 EMNLP·코덱스와도
일치했으나, **그것이 잡으려던 것을 Layer 1이 더 싸고 안전하게 전부 지배한다.**
부활 여지는 IMK 전환 후 **비파괴 제안 UI**뿐이며, 자동 소급은 재검토 대상이 아니다.

**B. 연속 confidence 폐기, 이산 분리 채택** (코덱스 구조):
```
coreRule        v4 규칙 판정 (동결, 무접촉)
lexicalVerdict  koreanOnly | englishOnly | both | neither | unavailable  ← 고정 실단어 사전
contextClass    structuralTie | shortKoreanCandidate | ineligible
finalAction     preserve | correct | suggest
```

**C. 진짜 다음 작업 = 결정적 Layer 1 사전 tiebreaker.** 사용자 실제 통증
(`만들다·캐나다·배관·문맥`이 `aksemfek·zoskek·qorhks·ansaor` 영어 gibberish로 보존됨)을
해결. `ambiguousBothValid` 391개 중 ~78%를 문맥 없이 즉시·안전하게 회수. **정본은
NSSpellChecker 금지 — 버전·해시 고정 실단어 목록을 Python·Swift가 공유.** R4-1 동결 엔진
밖 별도 계층 + 자체 parity fixture.

**D. R-Short(`Eh↔또`, 아/이/그)는 별개·미측정 문제로 분리·보류.** `ko_words.txt`에 단음절이
0개라 코퍼스 자체가 이 영역을 못 잰다. 게다가 현재 `K_strong`이 단음절을 전부 보존 중이라,
건드리려면 게이트 완화 → 새 위험. 전용 문장 코퍼스로 따로 연구.

**E. 우선순위 (코덱스 + 검증):**
1. Step 1-A 권한회수·탭 생명주기 **실기 검증 마감** (사용자 협조 필요)
2. Step 1-B 공용 `Session/EditPlan` + 직렬 실행 배관 (이후 모든 교정·제안의 공통 토대)
3. AX cold-start 대응
4. Step 2 필터 테스트·안내 문구 마감
5. **결정적 Layer 1** (고정 사전) + 별도 fixture ← 체감 이득 큰 지점
6. 실제 문장 단위 잔여 빈도 측정
7. (IMK 이후) 제안형 Step R 실험 — 자동 소급은 제안 정밀도 입증 후에만

**F. R4-1·마이그레이션 경계:** Layer 1은 코어 밖 래퍼라 R4-1과 양립. 단 IMK 전환 중
사용자 동작을 바꾸면 R4 "동작 그대로 전수"와 충돌 → **마이그레이션과 Layer 1 출시는 분리.**
