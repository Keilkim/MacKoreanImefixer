# 구조 교정 설계 v4 — 순수 규칙 기반 양방향 한/영 오입력 교정

작성일: 2026-07-20
상태: **구현 완료** (v4.2). 설계·실측·Swift 이식·테스트 전부 반영됨.
기준 사양(레퍼런스 구현): `scripts/rulebench/genrules.py`
Swift 구현: `Mackor/Mackor/{KSX1001Table,EnglishPhonotactics,HangulStructure,LayoutCorrectionPolicy}.swift`
재현: `python3 -B scripts/rulebench/bench.py` / `xcodebuild -scheme Mackor test`

---

## 0. 요약

| 항목 | 현행 (v3 엔진) | 본 설계 (v4) |
|---|---|---|
| 판단 근거 | 번들 사전 143단어 + NSSpellChecker | **규칙만** (사전 0, 시스템 서비스 0) |
| 영→한 재현율 | 측정 불가 (사전 의존, 8ms 타임아웃 시 전면 실패) | **98.03%** (19,895 실어절) |
| 영→한 오탐 | 미측정 | **0.044%** (87/198,485) |
| 한→영 재현율 | 구조적으로 거의 0 (§1.2 참조) | **97.45%** (198,485 단어) |
| 한→영 오탐 | 미측정 | **0** (0/19,895) |
| tune.tsv | 23/23 (자기충족) | **23/23** (규칙만으로) |
| holdout.tsv | 27/27 (자기충족) | **27/27** (규칙만으로) |
| 골든 패리티 | 없음 | **405행** Swift↔Python 완전 일치 |
| 테스트 총계 | 147 (사전 전제 다수) | **150, 전부 통과** |
| 2글자 단어 | 전부 사망 (`minimumTokenLength=4`) | `we`, `see` 등 복원 |
| 대문자/Caps Lock | 전 기능 하드 veto | 약어 관례 규칙으로 흡수 |
| 외부 의존 | NSSpellChecker XPC (재시도/쿨다운/헬스체크 코드 ~240줄) | 없음 |

**설계 헌장: 단어 사례(사전·목록·샘플)를 코드에 기재하는 것을 금지한다.**
허용되는 상수는 두 종류뿐이다.
1. **문법적 폐쇄류** — 언어의 문법 자체가 유한하게 닫아 놓은 집합 (한글 자모 목록, 복합모음 표, 영어 이중자 목록, 공명도 위계). 기존 코드의 `HangulUnicode.compoundVowels`와 같은 지위.
2. **표준에서 유도되는 집합** — KS X 1001 음절 2,350자. 목록을 쓰지 않고 OS 인코딩 변환기에서 런타임 계산한다 (§3.2).

---

## 1. 왜 다시 설계하는가

### 1.1 현행 엔진의 사망 원인 (실측 근거)

`WrongLayoutCorrectionEngine.swift`의 한→영 승인 조건은
"영어 사전 인정 ∧ 한국어 사전 거부"의 AND다. 이 맥에서 실측한 결과:

```
macOS 한국어 맞춤법 검사기: 안녕/커피/오늘/회의/프로젝트/마케팅 … 전부 인정
                            감사합니다 → 거부 (번들 사전에는 있는 단어)
macOS 영어 맞춤법 검사기:   github → 거부, kubernetes → 거부
```

한국어 검사기가 거의 모든 것을 인정하므로 AND는 구조적으로 성립 불가.
소스 veto(`systemRecognizedSource`)가 먼저 걸려 타깃 근거를 보기도 전에
preserve로 끝난다. **한→영이 안 되는 것은 버그가 아니라 설계의 필연.**

### 1.2 부차 사망 요인

- 8ms 타임아웃 + 500ms 쿨다운: 놓치면 `.none` → `isAuthoritative=false` → AND 성립 불가. 조용한 전면 실패.
- 하드 veto 4종 (allCaps, 반복 자모, 2글자, Shift 민감 키): 사전 조회조차 없이 차단. `evidenceCallCount == 0`으로 테스트에 고정됨.
- 번들 사전 143단어가 서비스 불능 시의 전체 어휘.

### 1.3 v4의 전환

> "이게 사전에 있는 단어인가?" (조회) → **"이 키 시퀀스가 어느 자판의 문법을 만족하는가?"** (제약 충족)

같은 물리 키열 K를 두 개의 독립된 제약계로 채점한다:
- **K-판정**: K를 두벌식으로 읽었을 때 정상 한국어 구조인가
- **E-판정**: K를 QWERTY로 읽었을 때 정상 영어 음소배열·정서법인가

둘 다 `(통과 여부, 위반 비용)`을 반환하고, 방향별 결정 규칙이
**상호 배타성 + 비용 마진**으로 교정/보존/신뢰등급을 정한다.

---

## 2. 규칙 카탈로그

### 2.1 한국어 구조 규칙 (R-K)

| ID | 규칙 | 근거 | 구현 |
|---|---|---|---|
| **R-K1** | 자모열이 오토마톤에서 **완전 조합**되어야 함 (잔여 낱자모 0) | 두벌식 오토마톤 = 한국어 음절 문법 그 자체 | 기존 `HangulCompositionTracker` 재사용 |
| **R-K2** | 모든 음절이 **KS X 1001 완성형 2,350자**에 속해야 함 | 현대 한국어가 실제 사용하는 음절만 인정. 유니코드 11,172자 중 79%가 배제됨 (`솓`,`갲`,`뮫` 등 영어 잔해가 정확히 여기 걸림) | CP949 lead `0xB0~0xC8` 범위로 런타임 유도 (§3.2). **오탐을 정확히 절반으로 줄이는 단일 최대 기여 규칙** (실측 140→71) |
| **R-K3** | 자음 키 연속 ≤ 3 | 한국어 음절 CV(C) 구조의 증명 가능한 상한: 겹받침(2) + 다음 초성(1) | 키열에서 `qwertasdfgzxcv` 연속 카운트 |
| **R-K4** | 단음절 후보는 **3키(CVC) 이상**일 때만 강한 후보 | 2키 조합(`go`→해)은 무작위 충돌률 7.69%(길이3 기준 실측)로 위험 | `syllableCount>=2 || keyCount>=3` |
| **R-K5a** | 전체가 **단일 자모/음절의 반복**이면 의도적 표현 (ㅋㅋㅋ, ㅠㅠ, ㄷㄷㄷ, 뇸뇸뇸) → 한→영 보존 | 반복은 한국어 표현 관례. `{"ㅋㅋ","ㅎㅎ"…}` 목록이 아니라 **형태 규칙**이므로 미등재 표현(뇸뇸뇸)도 잡음 | `len(set(text))==1 && len>=2` |
| **R-K5b** | **서로 다른 자음 자모 3+** 토큰(ㅁㄴㅇ, ㅁㄴㅇㄹ)은 키보드 매시 관례 → 한→영 보존. 반복 포함 자음 토큰(ㄴㄷㄷ=see)과 2자모 토큰(ㅈㄷ=we)은 **중간 신뢰로 교정** | 음절 시도조차 없는 상이한 자음 나열 = 의도적 매시. 반복이 섞이면(`see`,`add`) 실단어 가능성이 높아 교정 쪽으로 | 순수 자모 && 전원 자음 && 길이·중복 검사 |

### 2.2 영어 생성 규칙 (R-E) — onset/coda 목록 없음

영어 판정은 단어 목록은 물론 **자음군 목록도 두지 않는다.**
공명도 위계와 소수의 음운·정서법 제약에서 합법 자음군이 **생성**된다.

**전처리 (정서법 정규화)**
| ID | 규칙 |
|---|---|
| R-E6 | 어말 `j`/`q`/`v` 금지 (영어 정서법: love, judge처럼 e를 붙임) |
| R-E7 | `h j k q v w x y`는 겹칠 수 없음 (정서법 겹침 규칙) |
| R-E8 | `qu` 단위화. 그 외 위치의 `q` 뒤에 모음 없으면 실패 |
| R-E13 | `j` 뒤에는 모음이 온다(`y` 허용) — jam·inject·fjord. 사전 235,974단어 중 위반 52개(0.022%)로 전부 raj·hadj·majlis류 차용어. R-E6의 일반화이며 coda `nj`+onset 분절로 살아남던 `anjdi`(뭐야)류가 여기서 갈린다 |
| R-E14 | 어중 대문자는 영어 정서법이 아니다 — 어두 대문자(고유명사)·전대문자(약어, 영→한은 R-D3 선점)는 표기 관례지만 어중은 아니다. 두벌식 어중 Shift 쌍자모(`alcuTek`=미쳤다, `roRnf`=개꿀)가 여기서 갈린다. `LexicalTiebreaker.englishLookupKey`가 조회 정규화에 쓰던 논리의 엔진 승격 |
| R-E10 | 어말 모음+`h`는 묵음 (ah, oh, messiah) — 통과시키되 **비용 +1** |
| R-E11 | 모음 뒤 `gn`의 `g`는 묵음 (sign, reign, foreign) |
| 이중자 | `ch sh th ph wh gh ck ng rh tch` = 단일 자음 단위 (폐쇄류). `rh` 는 그리스계 어두 이중자 — 없으면 `rhythm`/`rhino`/`rhapsody` 가 한글로 오교정된다 |

**핵(모음) 규칙**
| ID | 규칙 |
|---|---|
| R-E2 | 모든 단어에 모음자 필수. `y`는 어두+모음앞이면 자음, 그 외 모음 |
| R-E12 | `y`/`w`가 **모음 사이**에 있으면 자음(활음 onset: sawyer, abeyant, away) — 모음 뒤+비모음앞 `w`는 이중모음 활음(cow) |
| R-C2 | 모음자 4연속 = 실패, 3연속 = **비용 +1** (beau류 차용어) |
| R-C1 | 어두 모음쌍이 표준 이중자 20종(`ai au aw ay ea ee ei eu ew ey ie oa oe oi oo ou ow oy ue ui`, 폐쇄류) 밖이면 **비용 +1** (`eo-`, `ao-`) |

**Onset 생성 규칙 (공명도 상승 원리)**
| ID | 규칙 |
|---|---|
| R-E3a | 단일 자음: `ng ck tch` 및 비어두 `x` 제외 전부 |
| R-E3b | 2자음: ① `s` + {무성폐쇄음, m, n, f, l, w, qu} (s-예외 규칙) ② 장애음 + {l r w y} (공명도 상승), 단 조음위치 금지쌍 제외: `tl dl thl sr pw bw fw vw mw`, 그리고 `v x h z j q`는 군 불가 |
| R-E3c | 3자음: `s` + 무성폐쇄음 + 유음/활음 (str, spl, squ …) |
| R-E3d | 어두 한정 고전어 묵음 onset (폐쇄류): `kn gn wr ps pn pt mn ts` |

**Coda 생성 규칙 (공명도 하강 원리)**
| ID | 규칙 |
|---|---|
| R-E4 | 핵에서 바깥으로 공명도 비증가. 첫 단위가 `w y h`면 실패 |
| **T1** | 동일 공명도 폐쇄음 연쇄는 **무성 `t` 종결만** 합법 (-ct, -pt, -xt). `gk`, `kd` 류 즉사 → `대한→eogks`, `다음→ekdma`가 영어 행세를 못 하게 만든 규칙 |
| **T3** | 장애음 연쇄는 **유성성 일치** 필수 (`sd` 불법 → `ㅁㄴㅇ=asd`가 영어 행세 불가). 교과서 규칙(voicing assimilation) |
| R-E5 | 굴절 접미 자음 **`s z th`** 최대 2개를 coda 뒤에 허용 (-s, sixths, texts) — appendix 스트리핑. **어말에만 적용**한다. ① `t`/`d` 를 넣으면 `해당`(goekd)·`ㅁㄴㅇ`(asd)이 T3를 우회한다 (영어 과거형 `-ed` 는 철자에 언제나 모음 `e` 가 있어 맨자음 접미가 아니다). ② 내부 자음군에 적용하면 `다음`(ekdma)이 T1을 우회한다 |
| R-E9 | 어말 마찰음+`m`은 음절성 비음 (-ism, -asm, -rhythm) |
| 내부 | 모음 사이 자음군은 합법 coda + 합법 onset으로 분할 가능해야 (최대 onset 원리) |

### 2.3 방향별 결정 규칙 (R-D)

```
E-판정 결과: hard-fail | pass(cost=0) | pass(cost≥1)
K-판정 결과: K-strong (R-K1∧K2∧K3∧K4) | K-any (완전조합만) | fail
```

**영→한 (화면 = 라틴, 영어 자판에서 침)**
| 조건 | 결정 |
|---|---|
| R-D3: 2글자+ 전부 대문자 | **보존** (약어 표기 관례 — GKSK, DHCP는 여기서 생존. 소문자 dhcp는 §5 참조) |
| ¬K-strong | 보존 |
| K-strong ∧ E hard-fail | **교정 (high)** |
| K-strong ∧ E cost≥1 | **교정 (medium)** — 마진 규칙. `메모→apah`(어말 h 비용) 복원 담당 |
| K-strong ∧ E cost=0 | 보존 (진짜 중의성: `모든↔ahems`) |

**한→영 (화면 = 한글, 한글 자판에서 침)**
| 조건 | 결정 |
|---|---|
| R-D1: 완전조합 ∧ 전 음절 KS | **보존** (`재깅↔world` 중의성. 단 비-KS 조합(`팿미=vocal`)은 통과 → 교정 가능) |
| R-K5a 반복 / R-K5b 매시 | 보존 |
| E hard-fail | 보존 (`nginx` 등 비음소배열 식별자는 못 구함 — 현행 NSSpellChecker도 github를 거부했으므로 후퇴 아님) |
| E pass | **교정** — cost=0이면 high, cost≥1 또는 2자모·반복자모 토큰이면 medium |

**신뢰 등급의 의미**: 둘 다 즉시 교정한다. 차이는 복구 안내의 강도로, `medium` 은 원문 칩을 더 강하게 노출할 근거다. 등급은 `CorrectionDecision.tier` 로 이벤트 탭까지 전달되며, UI 분기는 아직 넣지 않았다 (§4.4).

---

## 3. 측정 결과 (전부 재현 가능)

### 3.1 반복 이력 — 각 규칙의 기여

| 버전 | 변경 | 영→한 재현율 / 오탐 | 한→영 재현율 / 오탐 |
|---|---|---|---|
| v0 목록 기반 | onset/coda 목록 + KS | 98.21% / 71 | 96.88% / 1 |
| v1 생성 규칙 | SSP로 목록 제거 | 96.24% / 152 | 94.92% / 0 |
| v2 | +R-E9,E10,E11 (묵음·음절성) | 96.05% / 59 | 96.40% / 0 |
| v3 | +T1,T3 (하드) +비용 마진 | 97.82% / 132 | 96.38% / 0 |
| v4.1 | +R-E12, R-D1 KS가드, R-K5 정제 | 97.81% / 109 (h52+m57) | 97.29% / 0 |
| v4.2 | +`rh` 이중자, 접미를 `{s,z,th}` 어말 한정으로 축소 | 98.03% / 87 (h29+m58) | 97.45% / 0 |
| **v4.3 (구현본)** | +R-E13(j 뒤 모음), R-E14(어중 대문자) | **98.08% / 87 (h29+m58)** | **97.44% / 0** |

v4.3 은 오탐을 하나도 늘리지 않고(87 동일) 재현율만 올렸다 — `anjdi`(뭐야)·`anjgo`(뭐해)·`alcuTek`(미쳤다)·`roRnf`(개꿀) 계열이 `ambiguousBothValid` 보존에서 high 교정으로 이동. 한→영 손실은 hajj·majlis류 차용어 약 22단어(무시 가능).

- 평가셋: 영어 `/usr/share/dict/words` 198,485 단어(2~12자), 한국어 macOS `ko.lproj` 실어절 19,895개. 서로 상대 자판으로 변환해 전수 평가.
- 오탐 0.044%의 내역: high 29는 `dharma, fjeld, dirndl` 등 비영어계 차용어, medium 58은 `amah, aortism` 등 희귀어 — 전부 칩으로 복구 가능. v4.1 대비 high 오탐이 52→29로 절반 가까이 줄었다 (`rh-` 계열이 정상 영어로 인정되면서).

### 3.2 저장소 코퍼스 회귀

| 코퍼스 | 결과 | 해석 |
|---|---|---|
| `tune.tsv` | **23/23** | 사전·근거 주입 없이 전 행 일치 |
| `holdout.tsv` | **27/27** | 〃 |
| `system-evidence.tsv` | 11/20 | 불일치 9행은 전부 **NSSpellChecker 근거 주입을 전제로 설계된 행**. 내역: `vocal(3행)·good(2행)·gksrmf`는 v4가 근거 없이도 올바르게 교정(개선), `dufma→여름`·`auto`·`nth`는 근거 없인 불가한 손실(§5). **은퇴 완료** — `StructureCorrectionCorpusTests` 는 더 이상 읽지 않는다. 파일은 이전 설계의 기록으로 디스크에만 남겨 두었다 |
| `v2/golden.tsv` | **405/405** | 11개 규칙 ID를 계층 표집해 고정. Swift 구현이 파이썬 레퍼런스와 행 단위로 완전 일치 |

### 3.3 대표 동작 (스모크)

```
영→한:  dkssudgktpdy→안녕하세요(h)  tkfkd→사랑(h)  qlfem→빌드(h)  whgdk→좋아(h)
        hello/quora/rohan/cory/schmidt → 보존   GKSK → 보존(R-D3)
한→영:  ㅗ디ㅣㅐ→hello(h)  챌ㄹㄷㄷ→coffee(h)  챙ㄷ→code(h)  해ㅐㅇ→good(h)
        팿미→vocal(h)  앻→dog(h)  ㅈㄷ→we(m)  ㄴㄷㄷ→see(m)  ㅅㄷㄴㅅ→test(m)
        ㅁㄴㅇ/ㄷㄷㄷ/ㄷㄷ/ㅇㅋ/ㄱㄱ → 보존   재깅(world) → 보존(중의성)
```

현행 엔진이 하드 veto로 죽이던 `code`, `coffee`, `good`, `see`, `we`, `test`가 전부 복원됐다.

---

## 4. Swift 구현 (완료)

### 4.1 신규 파일

| 파일 | 역할 |
|---|---|
| `Mackor/Mackor/KSX1001Table.swift` | R-K2. `kCFStringEncodingEUC_KR` 로 `0xAC00...0xD7A3` 을 훑어 인코딩 가능한 음절만 비트셋에 담는다. macOS EUC-KR 은 엄격한 KS X 1001 이라 인코딩 성공 여부가 곧 소속 여부다 — 실측 정확히 2,350자. 변환기가 비정상이면(개수 불일치) 모든 음절을 통과시켜 이 규칙이 조용히 교정을 막지 않게 한다. **비용 실측: 4.8ms / 1,400 bytes**, `EventTapManager.init()` 에서 1회. 이벤트 탭 콜백이 아니라 시작 시점에 치르므로 탭 타임아웃 위험이 없다 |
| `Mackor/Mackor/EnglishPhonotactics.swift` | R-E 전체. `evaluate(_:) -> (isPlausible, cost)`. onset/coda 목록 없이 공명도 위계 + 정서법 제약에서 생성 |
| `Mackor/Mackor/HangulStructure.swift` | R-K1/K3/K4/K5. 기존 `HangulCompositionTracker` 로 조합하고 구조를 판정. 자음 키 연속은 키 목록이 아니라 `Jamo.isConsonant` 에서 얻는다 |
| `Mackor/Mackor/LayoutCorrectionPolicy.swift` | R-D 결정 매트릭스. `Tier`(high/medium), `Rule`(13종), `Decision`(correct/preserve). 물리 키→라틴 매핑의 소유자 |

### 4.2 기존 파일 변경

**`WrongLayoutCorrectionEngine.swift`** — 1,232행 → 258행.
- 삭제: `SystemLanguageLexicon`(239행), 번들 사전 143단어, `SystemWordEvidence`, `KoreanShape`/`EnglishShape`/`CaseProfile`/`SystemEvidenceAvailability`, allCaps·Shift민감·반복자모·2글자 하드 veto, 결정 트리 전체.
- 유지: 토큰 수명주기(record/backspace/invalidate/boundary/reset), 시간창, 오버플로, `PhysicalKeystroke`/`CorrectionDirection`/`CorrectionBoundary`/`CorrectionDecision` 공개 표면.
- `CorrectionDecision` 은 `confidence`/`reason` 대신 `tier`/`rule` 을 싣는다.

**`EventTapManager.swift`**
- `SystemLanguageLexicon.prepare()` → `KSX1001Table.prepare()`. `systemWordEvidence` 주입 배관 제거.
- Caps Lock: 영문 자판에서만 Shift 로 취급한다. 화면이 대문자인데 후보를 소문자로 들고 있으면 Undo 가 원문을 훼손하기 때문이고, 전대문자 토큰은 R-D3 가 보존한다. 한글 자판에서는 Caps Lock 이 IME 출력에 어떻게 반영되는지 보장할 수 없어 기존대로 토큰을 폐기한다.
- 교정·Undo·경계 재주입·칩 메커니즘은 변경 없음.

### 4.3 테스트 (150개, 전부 통과)

| 파일 | 내용 |
|---|---|
| `KSX1001TableTests` | 유도 개수 2,350 고정, 현대 음절 통과 / 잔해 음절 배제 |
| `EnglishPhonotacticsTests` | 규칙별 통과·차단·비용. 사전에 없는 단어(`kubernetes`, `blorping`)가 구조만으로 통과하는지 포함 |
| `LayoutCorrectionPolicyTests` | §3.3 스모크 전건 + 규칙 ID 고정 |
| `GoldenCorpusParityTests` | `Corpus/structure-correction/v2/golden.tsv` 405행. Swift↔Python 행 단위 일치 + 11개 규칙 전수 커버 검증 |
| `CorrectionNoticeControllerTests` | 칩 표시·히트테스트에 더해 등급→강조 매핑과 수명 |
| `WrongLayoutCorrectionEngineTests` | 수명주기 + 정책 연동(등급·규칙·문자 수 전달)으로 재작성 |
| `StructureCorrectionCorpusTests` | `tune`/`holdout` 유지. `system-evidence` 은퇴 |

**골든 코퍼스의 위상**: 손으로 고른 사례가 아니라 파이썬 레퍼런스 판정을 규칙 ID별로 계층 표집(고정 시드)한 것이다. 따라서 "구현이 스스로를 검증"하는 순환이 아니라 두 독립 구현이 갈라지는 순간을 잡는 장치다. 규칙을 바꾸면 `make_golden.py` 를 다시 돌려야 하고, 그 diff 가 곧 행동 변화의 기록이 된다. 실제로 v4.1→v4.2 규칙 수정 때 이 코퍼스가 재생성·재검증됐다.

### 4.4 신뢰 등급의 UI 반영 (완료)

`CorrectionDecision.tier` → `OriginalChoiceRequest.tier` → `CorrectionNoticeController.Emphasis` 로 전달된다.

| 등급 | 칩 표시 | 수명 |
|---|---|---|
| `high` (`.standard`) | 기본 라벨 색, medium 굵기 | 4초 |
| `medium` (`.prominent`) | 강조색 테두리 1.5pt + 강조색 라벨, semibold | **6초** |

`medium` 은 반대 읽기도 구조적으로 가능했던 교정이라 사용자가 되돌릴 확률이 높다. 수명을 6초로 맞춘 것은 ⌘Z 트랜잭션 수명과 같게 만들어, 칩은 사라졌는데 되돌리기는 아직 되는 간극을 없애기 위해서다.

### 4.5 제출 경계 Enter/Tab (완료)

Space·쉼표는 경계 문자를 **앱에 먼저 전달한 뒤 지우고 다시 넣는다**. Enter 에는 이 방식을 쓸 수 없다 — 메시지가 이미 전송된 뒤에는 빈 입력창을 고치게 된다. 그래서 제출 키는 흐름을 뒤집었다.

```
Space :  keyDown → 앱에 전달 → keyUp → 20ms → 경계+원문 삭제 → 교정문+경계 재주입
Enter :  keyDown → 교정할 것이 있는가?
           없음 → 그대로 통과 (대부분의 입력이 이 경로, 기존 동작과 동일)
           있음 → 키를 붙잡음 → 같은 콜백에서 원문 삭제 → 교정문 입력 → Enter 주입
```

세 가지 안전 설계:

1. **교정할 것이 있을 때만 붙잡는다.** 후보가 없으면 `nil` 을 돌려주지 않고 키를 그대로 흘려보내므로, 절대 다수의 Enter 입력에 대해 동작이 전혀 바뀌지 않는다.
2. **제출 키는 무조건 주입한다.** 포커스가 어긋나 교정을 포기해도 `defer` 로 Enter 를 주입한다. 사용자의 Enter 를 삼키는 것이 잘못 교정하는 것보다 나쁘다.
3. **커서 기대값이 다르다.** 제출 키는 아직 앱에 닿지 않았으므로 그 키의 길이는 더하지 않는다. 다만 앞서 앱에 전달된 후행 마침표 1~3개가 있으면 그 길이는 포함한다 (`expectedOffset = original.utf16.count + precedingPeriods.utf16.count`). 마침표는 교정 전에 지웠다가 교정문 뒤에 복원한다.

제출 교정은 Space 계열의 20ms 정착 scheduler를 사용하지 않는다. 제출 키만 지연시키면 그 사이 다음 물리 키가 먼저 앱에 도착할 수 있으므로, 후보 평가·안전 검사·교정·제출 키 주입을 물리 keyDown 처리 안에서 순서대로 끝낸다.

`Shift+Tab` 은 역방향 포커스 이동이라 경계로 쓰지 않는다. 대상 키는 Return(0x24)·숫자패드 Enter(0x4C)·Tab(0x30).

### 4.6 남은 작업

- **릴리스 게이트** — `python3 -B scripts/rulebench/bench.py` 수치가 §3.1 v4.2 에서 후퇴하면 릴리스 불가로 운영한다.
- **실기기 종단간 검증** — 161개 테스트는 AX·CGEventTap·TIS 를 전부 가짜 의존성으로 대체한다. 2026-07-20 에 Release 빌드(1.3 build 8)를 설치해 VS Code 프로세스의 lazy accessibility 활성화와 이벤트 탭 기동까지 확인했으나, **실제 타이핑 교정 결과의 사용자 확인은 아직 필요하다.** `ARCHITECTURE.md` §18 수동 체크리스트가 여전히 필요하다.

---

## 5. 정직한 한계 (규칙으로 넘을 수 없는 것)

이 절의 항목들은 구현 결함이 아니라 **키 시퀀스 단독의 정보 이론적 한계**다. 어떤 규칙을 몇 개 쌓아도 0이 되지 않으며, 해소하려면 문맥 또는 어휘 지식이 필요하다.

1. **양방 무결 충돌**: `world↔재깅`, `모든↔ahems`, `auto↔며새`, `여름↔dufma` — 두 문법을 모두 완벽히 만족. v4는 보존(오탐 방지 우선). 전체의 ~2.9%(영어 표본 실측).
2. **소문자 약어**: `dhcp→오체`는 여전히 교정된다. `dhcp`와 `tkfkd(사랑)`는 구조적으로 완전히 동일(무모음, KS 2음절 완전조합)하므로 구분 불가. 완화 장치: 칩 UI + 6초 Undo. (대문자 `DHCP`는 R-D3로 생존.)
3. **비음소배열 식별자**: `nginx`, `nth` 등은 영어 문법 밖이라 한→영 복원 불가. 단, 현행 NSSpellChecker도 `github`를 거부했으므로 후퇴가 아니다.
4. **어두 대문자 + 한글자판**: `Test`(ㅆㄷㄴㅅ)는 Shift+T가 ㅆ와 물리적으로 동일해 보존됨. 소문자 `test`는 복원됨.
5. **혼합 토큰**: 숫자·기호가 섞인 토큰(`test1`, `e-mail`)은 현행과 동일하게 경계까지 폐기. 이벤트 탭 계층의 제약이며 본 설계 범위 밖.

수치 인용 규칙(DESIGN3 §1142 계승): 본 문서의 모든 수치는
"corpus = dict/words 198,485 + ko.lproj 19,895, 환경 = macOS 26/Darwin 25.3, harness = scripts/rulebench @ v4.2" 없이 재인용하지 말 것.

---

## 6. 재현 절차

```bash
# KS X 1001 테이블 재생성 (규칙 유도 검증)
python3 -B scripts/rulebench/make_ksx1001.py   # → 2350 syllables

# 전체 벤치 + 저장소 코퍼스 회귀
python3 -B scripts/rulebench/bench.py
# 기대: 영→한 98.03% / 오탐 87, 한→영 97.45% / 오탐 0,
#       tune 23/23, holdout 27/27

# 골든 코퍼스 재생성 (규칙을 바꾼 뒤에는 반드시)
python3 -B scripts/rulebench/make_golden.py   # → 405 rows

# Swift 구현 + 골든 패리티
cd Mackor && xcodebuild -project Mackor.xcodeproj -scheme Mackor test
# 기대: Executed 150 tests, with 0 failures
```

| 파일 | 역할 |
|---|---|
| `scripts/rulebench/auto.py` | 두벌식 오토마톤 (Swift `HangulCompositionTracker`와 동작 일치 검증됨) |
| `scripts/rulebench/genrules.py` | **v4.2 규칙 전체 — Swift 구현의 기준 사양.** `explain_l2k`/`explain_k2l` 가 규칙 ID까지 반환한다 |
| `scripts/rulebench/bench.py` | 대량 측정 + 코퍼스 회귀 러너 |
| `scripts/rulebench/make_ksx1001.py` | KS X 1001 유도 (CP949 바이트 범위 규칙) |
| `scripts/rulebench/make_golden.py` | 골든 코퍼스 계층 표집 생성기 (고정 시드) |
| `scripts/rulebench/ko_words.txt` | 한국어 평가셋 19,895 어절 (macOS ko.lproj 추출) |
