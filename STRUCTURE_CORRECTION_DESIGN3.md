# Mackor 양방향 자판 오입력 구조 판정 설계안 v3

> 상태: **역사 기록** — 현행 설계는 [STRUCTURE_CORRECTION_DESIGN4.md](STRUCTURE_CORRECTION_DESIGN4.md)(구현 완료 v4.2)로 대체되었습니다. 이 문서는 v4에 이르기까지의 판단 근거를 보존한 기록입니다.
> 작성 기준일: 2026-07-20 KST
> 기준 작업 트리: base commit `9cc455c46e2a` + 로컬 미커밋 변경
> 검토 환경: macOS 26.3.1, Xcode 26.5
> 선행 문서: v1·v2 설계안(`STRUCTURAL_CORRECTION_DESIGN.md`, `STRUCTURAL_CORRECTION_DESIGN2.md`) — 저장소에 보존되지 않은 역사 기록

---

## 0. 이 문서의 역할

이 문서는 v1의 구조 판정 원리와 v2의 코드·테스트·코퍼스 검증을 합치고, 이후 검토에서 발견된 반례와 제품 결정을 반영한 세 번째 설계안이다.

v1은 “사전 등재를 요구하지 않고 같은 물리 키열의 영문·한글 구조를 비교한다”는 핵심 원리를 세웠다. v2는 그 원리 대부분이 이미 구현되어 있음을 확인하고 `asd`, `dhcp`, `gksrmf.com`, Shift 처리 같은 실제 결함을 찾아냈다. v3는 다음을 추가한다.

1. 검증된 사실과 제품 정책, 미검증 가설을 구분한다.
2. `GKSK` 같은 회사 약어 반례를 반영해 v2의 절대명제를 수정한다.
3. 영문 소스의 **ALL CAPS는 하드 보존**한다.
4. 그 밖의 승인된 후보는 **먼저 자동 보정**한다.
5. 보정 직후 exact range 좌표를 얻은 앱에서는 해당 텍스트 위에 **물리 키열로 재구성한 원문만** 클릭 가능한 칩으로 표시한다.
6. v2 R1~R5를 채택·수정·폐기·보류로 다시 판정한다.
7. 코퍼스, 상태기계, 개인정보, 실제 앱 종단간 검증을 구현 선행 조건으로 둔다.
8. `fullyComposed`를 실제 한국어 단어와 동일시하지 않고 macOS 영·한 사전의 비대칭 근거를 중첩 게이트로 사용한다.

이 문서는 자동 한/영 오입력 교정 서브시스템만 다룬다. 선택 앱용 직접 한글 조합, 메뉴 구조, 서명·공증·배포 전체는 [`ARCHITECTURE.md`](ARCHITECTURE.md)의 범위다.

### 0.1 문서 표기

| 표기 | 뜻 |
|---|---|
| **구현됨** | 현재 작업 트리에 코드와 테스트가 존재함 |
| **확정 정책** | 제품 동작으로 채택하되 아직 구현되지 않았을 수 있음 |
| **실험** | 기능 플래그로 검증하고 제거 가능해야 함 |
| **측정 필요** | 고정 코퍼스나 실제 앱 검증 전에는 확정하지 않음 |
| **폐기** | v3에서 채택하지 않음 |

문서에서 “안전”, “보존”, “하드 veto”는 코드가 실제로 관측할 수 있는 조건에만 사용한다. 사용자의 머릿속 의도나 모든 앱의 필드 의미를 절대적으로 안다는 뜻으로 사용하지 않는다.

이 문서와 테스트에 나오는 단어는 **규칙을 검증하는 fixture**이지 생산 코드의 단어별 예외 목록이 아니다. 새로운 반례가 생기면 해당 단어를 `if`문이나 전용 목록에 추가하는 대신, 일반화 가능한 구조·사전·안전 조건을 고치고 서로 다른 표본으로 회귀 검증한다. macOS 사전 기반 경로의 생산 코드에는 아래 예시 단어를 직접 비교하는 분기가 없어야 한다.

---

## 1. 현재 상태 스냅샷

### 1.1 테스트 상태

2026-07-20 현재 전체 XCTest는 **155개가 통과**했고 실패·건너뜀은 0개다.

| 테스트 묶음 | 개수 |
|---|---:|
| `WrongLayoutCorrectionEngineTests` | 71 |
| `EventTapManagerTests` | 44 |
| `HangulCompositionTests` | 11 |
| `TargetAppManagerTests` | 13 |
| `InputSourceControllerTests` | 6 |
| `CorrectionNoticeControllerTests` | 2 |
| `StructureCorrectionCorpusTests` | 3 |
| `SparkleUpdateConfigurationTests` | 5 |
| **합계** | **155** |

초기 검토에서 발견한 다음 정책 불일치는 현재 해소됐다.

```text
testThreeLetterKeyboardWalkStaysUnchangedWithoutDictionary
expected: ㅁㄴㅇ 보존
현재:     ㅁㄴㅇ 보존
```

v3 정책은 `asd`가 알려진 영어 단어라는 적극적 근거가 없으면 `ㅁㄴㅇ`를 보존한다. `pureJamo`에 known-English target을 요구하도록 구현했고 결정적 회귀 테스트를 둔다.

### 1.2 현재 확인된 좋은 동작

- `qlfem → 빌드`
- `gksk → 하나`
- `rksk → 가나`
- `Dkssud? → 안녕?`
- 소문자 물리 키 `whgdk → 좋아`
- `but`, `how`, `can`, `hello`의 한글 소스 오입력 복구
- `rohan`, `schmidt`, `quora` 보존
- 기본 사전 비대칭 사례 `팿미/vocal` 교정과 양쪽 사전 hit인 `재구/worn` 보존
- 숫자·`_`·`/`·`@` 등이 섞인 run의 소급 폐기
- 경계 keyUp 전 다른 키·마우스·입력 소스 변경 시 예약 교정 취소
- 교정 직후 제한된 `⌘Z`와 입력 소스 복원 영수증

### 1.3 발견한 결함의 처리 상태와 남은 위험

| 사례 | 발견한 문제 | 현재 처리 |
|---|---|---|
| `ㅁㄴㅇ` | `asd`로 오교정 | R1 순수 자모 규칙으로 보존 구현·검증 |
| `ㅁㄴㅇㄹ` | `asdf`로 오교정 가능 | R1 순수 자모 규칙으로 보존 구현·검증 |
| `ㄷㄷㄷ`, `ㅁㅁㅁ` | `eee`, `aaa`로 오교정 | 반복 자모 선행 veto 구현·검증 |
| `dhcp` | `오체`로 오교정 | 소문자는 구조 정책대로 먼저 보정하고 가능한 앱에서 원문 칩 제공; 코퍼스로 재평가 |
| `GKSK` | `하나`로 오교정 가능 | Latin-source ALL CAPS 하드 보존 구현·검증 |
| `gksrmf.com` | 타이밍에 따라 앞부분이 `한글`로 바뀔 수 있음 | 마침표 전용 유예 상태기계 구현·검증 |
| `안녕ㅎ`, `와ㄷㄷ` | 혼합형을 무조건 영어로 보면 훼손 가능 | 후행 자모 veto와 authoritative 영어 예외 구현·검증 |
| 시스템 사전 미준비·타임아웃 | source veto가 사라져 구조 교정 결과가 달라질 수 있음 | `unavailable`을 별도 상태로 유지하고 완성형·후행 자모 공격 경로는 fail-closed |
| 토큰 뒤 긴 정지 후 경계 | 마지막 letter 뒤 경과 시간은 경계 평가 시 다시 확인하지 않음 | 실제 사용성 측정 후 boundary-timeout 정책 확정 |

### 1.4 v2 코퍼스 관측의 정확한 의미

v2 검토에서는 `/usr/share/dict/words`와 `propernames`의 길이 4 이상 토큰 234,454개를 검사했다. “영문 구조상 불가능하면서 두벌식 한글로 완전 조합”되는 항목은 `downthrow`, `downthrown`, `eightsman`, `shoq`, `spendthrift`, `spendthrifty` 6개로 관측되었고, 해당 Mac의 `NSSpellChecker`가 여섯 항목을 모두 영어로 인식했다. 무작위 문자열의 동시 만족 비율은 길이 3에서 7.69%, 길이 4에서 2.93%, 길이 5에서 3.37%로 관측되었다. 상세 원자료 표는 v2에 있다.

이 결과는 **해당 OS·사전·맞춤법 서비스·표본에서 관측된 결과**다. 다음을 증명하지는 않는다.

- 실제 사용자 입력 전체에서 오탐이 0이라는 것
- 회사 약어, 프로토콜, CLI, 제품명, ID가 안전하다는 것
- 다른 macOS 버전·언어·사용자 사전에서도 같은 결과라는 것
- `NSSpellChecker`가 미준비이거나 제한 시간 안에 응답하지 못해도 같은 결과라는 것

`dhcp`와 `GKSK`는 일반 단어 목록만으로 안전성을 일반화할 수 없다는 직접적인 반례다. 원래 측정 스크립트, seed, 입력 파일 hash가 저장소에 고정되기 전까지 v2의 수치는 참고 관측으로만 유지한다.

---

## 2. 목표와 비목표

### 2.1 목표

Mackor은 사용자가 현재 입력 소스를 착각해 친 토큰을 두 방향으로 보정한다.

- 영문 자판 상태에서 친 한글: `qlfem → 빌드`
- 한글 두벌식 상태에서 친 영어: `ㅠㅕㅅ → but`

목표는 다음과 같다.

1. 대상 단어가 사전에 없어도 이름·신조어·외래어를 교정한다.
2. 코드·약어·자모 표현을 가능한 한 보존한다.
3. 판정과 교정은 로컬에서만 수행한다.
4. 실제 교체 직전 포커스와 커서를 재검증한다.
5. 자동 보정 뒤 원문을 짧은 시간 안에 클릭으로 복원할 수 있게 한다.
6. 규칙 변경의 정밀도·재현율·지연을 재현 가능한 숫자로 비교한다.

### 2.2 비목표

- 단일 토큰만으로 사용자의 의도를 100% 알아내는 것
- LLM이나 네트워크 서비스를 이용해 문맥을 전송하는 것
- 입력 필드의 전체 문장이나 주변 텍스트를 읽어 의미를 추론하는 것. 단, 원문 칩 표시·클릭 직전 교정된 정확한 range가 예상 replacement와 같은지 확인하는 최소 읽기는 허용한다.
- 모든 웹·Electron·Wine·원격 앱의 접근성 메타데이터가 정확하다고 가정하는 것
- 자동 보정과 선택 앱용 직접 한글 조합을 하나의 기능으로 취급하는 것
- 영문·한국어 맞춤법 검사기를 자체 구현하는 것

---

## 3. 핵심 원칙

### 3.1 같은 물리 키열에서 두 후보를 만든다

화면에 보이는 문자열이 아니라 물리 keycode와 실제 Shift 상태를 저장한다.

- `E`: 같은 물리 키열을 ABC/QWERTY로 해석한 후보
- `K`: 같은 물리 키열을 두벌식으로 조합한 후보
- `source`: 실제로 켜져 있던 입력 소스
- `sourceCandidate`: 현재 입력 소스로 보이는 후보
- `targetCandidate`: 반대 입력 소스로 해석한 후보

예를 들어 `q-l-f-e-m`은 `E = qlfem`, `K = 빌드`다.

### 3.2 구조 판정은 의도의 증명이 아니라 교정 자격 판정이다

v2의 다음 절대명제는 폐기한다.

> 영문 후보가 구조적으로 불가능하면 사용자는 영어를 치려던 것이 아니다.

`dhcp`, `GKSK`, 회사 약어, 프로토콜, CLI, 사용자 ID가 반례다. v3의 표현은 다음과 같다.

> 영문 후보가 강한 비정상 구조를 보이고 한글 후보가 완전 조합되면 Latin→Korean 자동교정의 강한 후보가 된다. 단, source veto와 안전 게이트를 모두 통과해야 한다.

한글 완전 조합도 실제 한국어 의도를 증명하지 않는다. 두벌식 구조상 가능한 후보라는 뜻이다.

### 3.3 명확한 위험은 먼저 제외한다

사전이나 구조 점수를 계산하기 전에 다음을 처리한다.

- 지원하지 않는 입력 소스
- Secure Event Input 활성 상태
- 안전한 단일 캐럿을 확인할 수 없는 AX 요소
- 명확한 보안·주소·검색 필드
- Cmd·Ctrl·Option·Fn 단축키
- 숫자나 지원하지 않는 기호가 섞인 run
- 최대 32타 초과 또는 타건 간 2초 초과
- Caps Lock이 관측된 토큰
- Latin source에서 2글자 이상 모든 물리 영문 타건이 대문자인 ALL CAPS
- 포커스·커서·앱·입력 소스 세대가 바뀐 예약 교정

AX 역할과 메타데이터는 앱이 정확히 제공하는 범위에서만 유효하다. 따라서 “모든 비밀번호·ID를 절대 보호한다”고 표현하지 않는다. **관측 가능한 위험 문맥에서 fail-closed**하는 것이 정확한 약속이다.

### 3.4 공격적으로 보정하되 복구를 짧고 명확하게 만든다

하드 보존 조건을 통과하고 엔진이 교정 후보로 승인한 경우 높은 확신과 중간 확신은 모두 먼저 자동 적용한다. 정확한 교정 range 좌표를 얻은 경우 그 직후 해당 교정 텍스트 위에 원문 문자열 하나만 클릭 가능한 칩으로 표시한다.

```text
   [gksk]
     하나
```

- 시각 텍스트는 `gksk`뿐이다.
- “원문”, “되돌리기”, 화살표, 결과 후보, 아이콘을 표시하지 않는다.
- 선택은 당분간 마우스·트랙패드 클릭만 지원한다.
- 클릭 직전 안전 조건 재검증에 성공하면 현재 교정을 원문으로 복원한다.
- 클릭하지 않고 다음 입력을 계속하면 교정 결과가 확정되고 복원 transaction도 폐기된다.
- 4초 칩 만료는 UI만 숨기며, 다른 입력이 없었다면 기존 `⌘Z` transaction은 최대 6초까지 남는다.
- 기존 `⌘Z`는 별도의 안전망으로 유지하지만 칩 안에는 안내하지 않는다.

이 UI는 엔진과 분리된 실험 기능이다. 위치 불안정, 포커스 탈취, 타이핑 방해가 발견되면 원문 칩만 제거할 수 있어야 한다. **range 좌표를 얻지 못하거나 칩 기능이 꺼져 있어도 현재 확정 정책에서는 자동교정을 계속하고 기존 `⌘Z`만 남긴다.** 다만 원문 칩을 장기적으로 제거한다면 lowercase acronym 같은 중간 확신 자동 적용 정책을 다시 검토해야 한다.

### 3.5 완성도를 다루는 세 구역

| 구역 | 성격 | v3 해법 |
|---|---|---|
| 정보상 판별 불가능 | 같은 키열을 macOS 양쪽 사전이 모두 인정함 (`worn/재구` 등), lowercase acronym 등 | 양쪽 사전 hit는 source를 보존; 한쪽 근거만 우세해 보정한 경우 짧은 복구 제공 |
| 관측 가능한 하드 조건 | Secure Input, 명확한 위험 field, 숫자·기호 run, Latin-source ALL CAPS | 확률이 아니라 결정적 veto |
| 통계적 영역 | 이름·신조어·혼합 자모·영문 구조 휴리스틱 | 고정 corpus와 실제 앱 E2E로 측정 |

이 구분은 v2의 “완벽의 세 구역”을 유지하되, URL·ID·비밀번호 전체를 절대 식별할 수 있다는 과장을 제거한 것이다. 하드 보장은 Mackor이 실제로 관측한 조건 안에서만 주장한다.

---

## 4. 후보 분류

### 4.1 한글 후보 `K`

| 분류 | 정의 | 예 |
|---|---|---|
| `fullyComposed` | 모든 문자가 U+AC00~U+D7A3 현대 한글 완성 음절 | `빌드`, `하나`, `의`, `와` |
| `mixed` | 완성 음절과 U+3131~U+318E 호환 자모가 함께 있음 | `ㅗ디ㅣㅐ`, `ㅊ무`, `안녕ㅎ` |
| `pureJamo` | 완성 음절 없이 호환 자모만 있음 | `ㅠㅕㅅ`, `ㅙㅈ`, `ㅁㄴㅇ`, `ㅋㅋ` |
| `unsupported` | 한글 후보를 안전하게 구성할 수 없음 | 매핑 실패·지원 밖 문자 |

`ㅙ`는 U+3159 호환 자모이며 완성 음절이 아니다. 따라서 `ㅙㅈ`은 `pureJamo`다.

### 4.2 의도적 한글 자모 표현

`mixed`가 곧 잘못된 한글이라는 v2의 주장은 폐기한다.

- `안녕ㅎ`
- `진짜ㅋㅋ`
- `와ㄷㄷ`
- `헐ㄷㄷ`
- `아ㅠ`

v3의 1차 보호 규칙은 다음과 같다.

1. `mixed`에서는 **토큰 전체가 처음부터** `^[가-힣]+[호환자모]+$`, 즉 하나 이상의 연속된 완성 음절 prefix 뒤에 호환 자모 suffix만 남는 경우에만 후행 자모형으로 보존한다.
2. `mixed`의 반복 자모 여부는 위 패턴에 맞는 suffix 안에서만 본다. 토큰 앞부분이 자모로 시작하거나 완성 음절 뒤에 다시 완성 음절이 나오면 이 veto를 적용하지 않는다.
3. `pureJamo`에서는 토큰 전체가 하나의 호환 자모로만 반복되거나 `ㅋㅋ`, `ㅎㅎ`, `ㅠㅠ`, `ㅜㅜ`, `ㄷㄷ`, `ㅇㅋ`, `ㄱㄱ` 고정 표현과 정확히 일치할 때 source 표현으로 보존한다. 일부에 같은 자모가 연속됐다는 이유만으로 막지 않는다. 그래야 `see → ㄴㄷㄷ`, `add → ㅁㅇㅇ`, `tree → ㅅㄱㄷㄷ` 같은 정상 double-letter 영어를 authoritative target 근거로 복구할 수 있다.
4. 따라서 `안녕ㅎ`, `진짜ㅋㅋ`, `와ㄷㄷ`, `아ㅠ`는 보호하지만, 자모로 시작하는 `ㅗ디ㅣㅐ`와 `ㅊ무`는 이 규칙만으로 보호하지 않는다.
5. 이 보호 규칙의 재현율 손실은 한국어 채팅 코퍼스로 측정한다.

이는 모든 인터넷 표현을 완벽히 식별한다는 규칙이 아니다. 관측된 흔한 패턴을 source veto로 삼는 보수적 1차 규칙이다.

### 4.3 영문 후보 `E`

현재의 영문 구조 규칙은 유지하되 “영어 여부 판정”이 아니라 강한 비정상 형태 검출로 정의한다.

1. `A-Z` 또는 `a-z` 물리 키로만 구성되어야 한다.
2. 소문자화한 형태에 `a e i o u y` 중 하나가 있어야 한다.
3. `q` 다음에는 원칙적으로 `u`가 와야 한다.
4. 첫머리 자음 연속 4 이상은 비정상으로 본다.
5. 내부 자음 연속 5 이상은 비정상으로 본다.
6. `schm-`, `schw-` 같은 확인된 이름 접두는 보호한다.
7. 번들 또는 신뢰 가능한 시스템 판정이 source 영어를 인식하면 구조 규칙보다 먼저 보존한다.

예:

- `qlfem`: `q + 비-u`로 `implausible`
- `gksk`: 모음 부재로 `implausible`
- `dhcp`: 모음 부재로 `implausible`이지만 실제 약어일 수 있음
- `hello`, `rohan`, `schmidt`: `plausible`
- `asd`: 구조상 `plausible`이지만 단어·keyboard-walk 여부는 별도 근거가 필요

### 4.4 대소문자 프로필

대소문자 분류는 소문자화하기 전에 물리 Shift 기록으로 계산한다.

| 프로필 | v3 정책 |
|---|---|
| Latin-source `ALL_CAPS`, 길이 ≥ 2 | **하드 보존**, 교정·원문 칩 없음 |
| 첫 글자만 대문자 | 대소문자만으로 veto하지 않음 |
| 혼합 대소문자 | 대소문자만으로 veto하지 않음 |
| 전체 소문자 | 일반 판정 |
| Caps Lock 관측 | 현재 run 폐기 |

ALL CAPS 규칙은 언어학적 진리가 아니라 Mackor 제품 정책이다. `GKSK`, `DHCP`, `NASA`, `HTTP`, `XML`을 약어·회사명·식별자 의도로 간주한다.

이 규칙은 **현재 입력 소스가 Latin일 때 source `E`에만** 적용한다. 한글 소스에서 반대 후보 `E`가 ALL CAPS라고 해서 영어 복구를 막아서는 안 된다.

여기서 Korean-source target ALL CAPS는 물리 Shift로 만들어진 경우를 뜻한다. Caps Lock 관측은 source 방향과 무관한 독립 안전 정책으로 run 전체를 폐기한다. 즉 “Shift로 만든 Latin-source ALL CAPS 보존”과 “Caps Lock이 켜진 run 폐기”는 서로 다른 규칙이다.

앱이나 CSS가 물리 Shift 없이 화면만 대문자로 표시하는 경우 Mackor은 입력 내용을 읽지 않으므로 이를 감지하지 못한다. 하드 보존의 범위는 관측한 물리 키열이다.

`Mackor`, `OpenAI`, `iPhone` 같은 혼합 대소문자에는 별도 하드 veto를 두지 않는다. 이들은 영문 구조와 source 사전 근거가 자연스러우면 기존 규칙으로 보존된다. 혼합 대소문자를 일괄 차단하면 `dlTdj → 있어`, `dhkTek → 왔다`처럼 한글 된소리에 필요한 실제 Shift까지 과도하게 막을 수 있다.

---

## 5. 사전과 시스템 언어 근거

### 5.1 소형 bootstrap fallback

현재 코드의 소형 번들 단어 집합은 시스템 맞춤법 서비스가 아직 준비되지 않았을 때를 위한 bootstrap fallback이다. 완전한 사전도, 제품 어휘를 계속 누적하는 저장소도 아니다. 다음 용도로만 사용한다.

- 확실한 source 단어의 하드 veto
- 흔한 target 단어의 결정적 고신뢰 교정
- 3타처럼 충돌이 큰 짧은 토큰의 적극적 근거
- 시스템 맞춤법 서비스가 없어도 최소 핵심 동작을 결정적으로 유지

**운영 규칙:** 사용자가 신고한 새 단어를 이 집합에 한 건씩 추가하지 않는다. 새 반례는 먼저 fixture로만 고정하고, 생산 동작은 구조 규칙이나 macOS 영·한 사전의 대칭적인 authoritative 판정으로 일반화한다. fallback 집합 변경은 단일 사례가 아니라 버전이 고정된 corpus 전체에서 정밀도·재현율 근거가 있을 때만 허용한다.

### 5.2 시스템 판정 결과와 조회 상태를 분리한다

개별 언어의 시스템 판정 결과는 다음 세 상태로 해석한다.

| 상태 | 뜻 | 구조 교정에 미치는 영향 |
|---|---|---|
| `recognized` | 준비된 서비스가 source 또는 target을 인식 | source hit는 veto, 반대 언어만 hit인 target은 방향별 고신뢰 근거 |
| `notRecognized` | 준비된 서비스가 정상 응답했지만 인식하지 못함 | 부정적 보조 근거일 뿐 “단어가 아님”의 증명은 아님 |
| `unavailable` | 미준비·타임아웃·리소스 부재·서비스 오류 | 거부 근거로 쓰지 않으며 구조-only 결과는 중간 확신 |

문자열 없는 진단에서는 사전 조회 자체의 상태를 별도로 둔다.

| `SystemEvidenceAvailability` | 뜻 |
|---|---|
| `notRequested` | ALL CAPS·확정 source·고정 자모·길이 gate가 먼저 결론을 내 사전을 호출하지 않음 |
| `available` | 양쪽 언어 서비스의 건강성 probe를 통과하고 이번 후보에 authoritative 응답함 |
| `unavailable` | 조회를 시도했지만 cold start·timeout·리소스 부재·서비스 오류로 신뢰할 응답을 얻지 못함 |

현재 코드의 `SystemWordEvidence.none`은 `isAuthoritative == false`지만 일반 구조 경로는 이를 이유로 중단하지 않는다. 따라서 “타임아웃을 단어가 아님으로 직접 간주하지 않는다”는 말은 맞지만, **source veto가 없어져 결과적으로 구조 교정 가능성이 높아질 수 있다.** 반면 Korean-source 완성형과 후행 자모 mixed는 unavailable일 때 보존한다. v3는 `notRequested`와 `unavailable`까지 분리해 이 차이를 숨기지 않는다.

영어 사전 조회는 물리 Shift가 만든 원형 표기를 먼저 확인하고, 다르면 소문자형을 fallback으로 한 번 더 확인한다. macOS 사전은 `Qatar/qatar`, `Iraq/iraq`, `OpenAI/openai`처럼 casing에 따라 결과가 달라질 수 있으므로 무조건 소문자화하면 정상 source 보호와 반대 방향 복구를 모두 잃는다. 구조 분류는 계속 소문자형을 사용하지만 authoritative 사전 hit는 원형과 fallback 중 하나의 hit로 인정한다.

### 5.3 사전 승인 경로와 구조 경로

현재 엔진에는 서로 다른 두 판정 경로가 있다.

1. **사전 승인 경로**: bootstrap exact target 또는 양쪽 시스템 사전의 authoritative 비대칭 근거로 승인한다. 완성형·후행 자모처럼 오탐 위험이 큰 Korean-source 경로는 system exclusive target을 요구한다.
2. **구조 경로**: 사전 target hit 없이도 강한 구조 대비로 교정한다.

현재 production 엔진에는 부동소수점 score, `minimumReplacementScore`, `minimumConfidenceGap`이 없다. `high`, `mediumEvidence`, `mediumUnavailable`은 이미 승인된 결과의 근거를 설명하는 진단 등급이지 가산점 임계값이 아니다. 따라서 사전 없는 `qlfem → 빌드` 같은 결과는 명시적인 구조 경로에서 나온다.

---

## 6. 최상위 판정 정책

### 6.1 공통 선행 순서

```text
1. 물리 타건과 현재 입력 소스를 수집한다.
2. 안전하지 않은 필드·단축키·지원 밖 소스면 즉시 폐기한다.
3. 숫자·지원 밖 기호·overflow·긴 정지가 있으면 경계까지 폐기한다.
4. E를 생성하고 물리 대소문자 프로필을 먼저 계산한다.
5. Latin-source ALL CAPS면 소문자화나 영문 형태 판정 전에 즉시 보존한다.
6. 나머지 후보에서 K를 생성하고 한글 형태와 소문자화한 영문 형태를 계산한다.
7. 현재 source의 확실한 번들 단어면 보존한다.
8. Korean source의 고정·반복 `pureJamo` 표현은 source-pattern 하드 veto로 보존한다. `완성 음절 prefix + 자모 suffix` mixed 표현은 아직 보존 후보로 표시하되 authoritative 영어 근거를 보기 전에는 최종 반환하지 않는다. 완성형이라는 사실만으로는 veto하지 않는다.
9. macOS 기본 영·한 사전 근거를 recognized/notRecognized/unavailable로 얻는다.
10. authoritative source 시스템 hit면 보존한다.
11. 반대쪽의 확실한 번들 단어 또는 authoritative 시스템 target hit이면 방향·shape별 고신뢰 판정을 시도한다. Korean-source `fullyComposed`와 후행 자모 mixed는 번들 단어만으로 승인하지 않고 `영어 hit ∧ 한국어 miss`를 요구한다.
12. 방향별 구조 규칙을 적용한다.
13. 어떤 명시적 승인 규칙도 성립하지 않으면 이유 enum과 함께 source를 보존한다.
14. 교정 직전 동일 필드·캐럿·예상 offset을 재검증한다.
15. 교정 후 입력 소스를 전환하고 복원 transaction을 만든 뒤, 정확한 range가 있으면 원문 칩을 표시한다.
```

현재 구현은 authoritative source hit와 bundled target hit가 충돌하면 source를 보존한다. 고정·전체 반복 `pureJamo`는 target 조회 전에 하드 veto하고, 후행 자모 mixed는 번들 target만으로 넘지 못하되 exclusive authoritative 영어 근거를 확인한 뒤 최종 보존 또는 교정을 결정한다.

### 6.2 판정표

| 현재 source | source 구조 | target 구조 | 추가 근거 | 결과 |
|---|---|---|---|---|
| Latin | heuristic과 무관 | `K fullyComposed` | macOS 영어 miss + 한국어 hit | 자동 한글 보정 + 가능한 경우 원문 칩 |
| Latin | `E implausible` | `K fullyComposed` | authoritative target 없이 하드 veto 없음 | 구조-only 한글 보정 + 가능한 경우 원문 칩 |
| Korean | `K pureJamo` | `E plausible` 또는 exclusive authoritative 영어 hit | 알려진 영어 target | 자동 영문 보정 + 가능한 경우 원문 칩 |
| Korean | `K mixed` | `E plausible` 또는 exclusive authoritative 영어 hit | 의도적 자모 veto 없음 또는 authoritative override | 자동 영문 보정 + 가능한 경우 원문 칩 |
| Korean | `K fullyComposed` | heuristic과 무관 | macOS 영어 hit + 한국어 miss | 자동 영문 보정 + 가능한 경우 원문 칩 |
| Korean | `K fullyComposed` | heuristic과 무관 | 양쪽 사전 hit 또는 사전 unavailable | source 보존 |
| 어느 쪽이든 | 둘 다 자연스러움 | — | source 우위 없음 | 보존 |
| 어느 쪽이든 | 둘 다 부자연스러움 | — | target 적극 근거 없음 | 보존 |
| 어느 쪽이든 | 하드 veto | — | — | 보존 |

`valid/invalid/unknown`을 하나의 3상태 enum으로 뭉치지 않고 현재 구현은 `KoreanShape`, `EnglishShape`, `SystemEvidenceAvailability`, `CaseProfile`, `CorrectionReason`을 분리해 문자열 없는 판정 이유를 남긴다.

### 6.3 확신도와 동작

| 등급 | 대표 근거 | 동작 |
|---|---|---|
| `high` | source veto를 통과한 번들 exact target 또는 authoritative 비대칭 target 근거 | 먼저 자동 적용, exact range가 있으면 원문 칩 |
| `mediumEvidence` | 구조 비대칭 + 사용 가능한 시스템 판정에서 source 미인식 | 먼저 자동 적용, exact range가 있으면 원문 칩 |
| `mediumUnavailable` | 구조 비대칭은 강하지만 시스템 근거가 unavailable | 먼저 자동 적용, exact range가 있으면 원문 칩 |
| `preserve` | 하드 veto, 양쪽 모두 자연스러움, 양쪽 모두 불명확, target 근거 부족 | 원문 보존, 칩 없음 |

칩은 best-effort 복구 UI다. 현재 정책에서는 칩 anchor를 얻지 못해도 `high`와 두 `medium` 등급의 승인 결과를 적용한다. 이 공격적 선택은 lowercase acronym 코퍼스와 실제 앱 복원 성공률을 본 뒤 다시 열 수 있다.

---

## 7. 방향별 규칙

### 7.1 Latin source → Korean target

공통으로 필드·run·포커스 안전 게이트를 통과하고, source `E`가 길이 2 이상의 물리 ALL CAPS가 아니며, 번들 또는 authoritative 시스템 영어 source로 인식되지 않아야 한다. 그 뒤 다음 두 경로 중 하나로 자동 보정한다.

1. **authoritative 사전 경로:** `K`가 전체 완성형이고 macOS 한국어 사전만 `K`를 인식한다(`한국어 hit ∧ 영어 miss`). 이때 단순 영문 철자 heuristic은 target 사전보다 약한 신호이므로 승인을 막지 않는다.
2. **구조-only 경로:** `E`가 강한 `implausible`, `K`가 전체 완성형이고 현재 Shift 안전 규칙을 통과한다. 사전이 unavailable이어도 이 강한 구조 비대칭은 중간 확신으로 적용한다.

예상 정책:

아래 표의 `+[원문]` 표기는 exact-range 조회와 anchor 배치를 지원하는 필드를 가정한다. 이를 지원하지 않는 앱에서도 승인된 교정은 적용되지만 칩은 생략되고 기존 `⌘Z` transaction만 남는다.

| 물리 입력 | 결과 | 이유 |
|---|---|---|
| `qlfem` | `빌드` + `[qlfem]` | q 규칙 위반 + 완전 조합 |
| `gksk` | `하나` + `[gksk]` | 모음 부재 + 완전 조합 |
| `rksk` | `가나` + `[rksk]` | 모음 부재 + 완전 조합 |
| `qkfto` | `발새` + `[qkfto]` | 구조 정책상 의도된 공격적 보정 |
| `dhcp` | `오체` + `[dhcp]` | 소문자 약어와 한글 의도를 구분할 정보가 부족함 |
| `dufma` | 한국어 사전이 `여름`만 인식하면 `여름` + `[dufma]` | exclusive authoritative target이 plausible 영문 형태보다 우선 |
| `GKSK` | 보존, 칩 없음 | Latin-source ALL CAPS |
| `DHCP` | 보존, 칩 없음 | Latin-source ALL CAPS |
| `Mackor`, `OpenAI` | 보존 예상 | 별도 case veto가 아니라 영문 구조와 원형-case 시스템 source 근거 |
| `rohan`, `schmidt`, `quora` | 보존 | 자연스러운 영문 구조 또는 source 근거 |
| `worn` | 보존 | 정상 source 영어 |

`dhcp` 정책은 오탐을 부정하는 것이 아니다. 사용자가 선택한 “승인된 후보는 일단 바꾸고 본다”는 공격적 정책을 적용하고, 원문 칩으로 즉시 복구할 수 있게 한다. `dufma → 여름` 같은 사전 경로도 개별 문자열 분기가 아니라 모든 후보에 동일한 `한국어 hit ∧ 영어 miss`를 적용한다. 이 정책의 실제 비용은 이름/acronym/CLI 코퍼스와 원문 칩 복원률로 측정한다.

### 7.2 Korean source → Latin target

#### 순수 자모형

`K`가 `pureJamo`이면 다음을 모두 만족할 때만 영어로 교정한다.

1. `E`가 영문 구조상 plausible이거나 macOS 영어 사전의 exclusive authoritative hit가 있다. 사전의 확정 hit는 단순 철자 휴리스틱보다 강하다.
2. `E`가 번들 영어 단어이거나 authoritative 시스템 영어 hit다.
3. 현재 한글 source를 보호하는 근거가 없다.

따라서:

- `ㅠㅕㅅ → but`: 교정
- `ㅙㅈ → how`: 교정
- `ㅁㄴㅇ`: 보존 (`asd` 적극 근거 없음)
- `ㅁㄴㅇㄹ`: 보존 (`asdf` 적극 근거 없음)
- `ㄷㄷㄷ`: 토큰 전체 단일 자모 반복이므로 보존
- `ㅁㅁㅁ`: 토큰 전체 단일 자모 반복이므로 보존
- `ㄴㄷㄷ → see`, `ㅁㅇㅇ → add`: 부분 반복일 뿐이므로 영어 사전 hit + 한국어 miss면 교정

#### 혼합형

`K`가 `mixed`이면 다음을 모두 만족할 때 영어로 교정한다.

1. `E`가 plausible이거나 macOS 영어 사전의 exclusive authoritative hit가 있다.
2. 현재 한글 source가 authoritative 시스템 한국어로 인식되지 않는다.
3. 토큰 전체가 `완성 음절 prefix + 자모 suffix`인 후행 자모형이면 macOS 영어 사전의 authoritative target hit가 있어야 한다. hit가 없으면 source 표현으로 보존한다.

예:

- `ㅗ디ㅣㅐ → hello`: 기존 번들 고신뢰 경로
- `ㅊ무 → can`: 혼합형 또는 번들/시스템 근거로 교정
- `해ㅐㅇ → good`: 후행 자모형이지만 macOS 영어 사전 hit가 있으므로 교정 후 `[해ㅐㅇ]` 제공
- `안녕ㅎ`, `진짜ㅋㅋ`, `와ㄷㄷ`, `아ㅠ`: 보존

후행 자모형이 아닌 혼합형 구조-only 보정은 중간 확신이다. 후행 자모형은 번들 단어를 하나씩 추가하는 것으로 보호를 넘지 못하며, macOS 기본 영어 사전의 authoritative hit만 보호를 넘을 수 있다. 코퍼스에서 의도적 한국어 표현 오탐이 높으면 authoritative 영어 target을 모든 혼합형에 요구하는 더 보수적인 정책으로 바꾼다.

현재 `SystemLanguageLexicon`은 엔진이 생성할 수 있는 완성 음절과 호환 자모만으로 이뤄진 `K`를 실제 한국어 맞춤법 서비스에도 조회한다. 따라서 mixed 경로도 단순히 `recognizesKorean = false`를 가정하지 않고 `영어 hit ∧ 실제 한국어 miss`를 확인한다. 반복·고정 자모 표현은 사전 서비스가 준비되기 전에도 선행 하드 veto로 보존한다.

#### 완성형

`K`가 `fullyComposed`라는 것은 Unicode 조합이 끝났다는 뜻이지 실제 한국어 단어라는 뜻이 아니다. 이 경로는 단어를 하나씩 코드에 추가하지 않고 macOS에 기본 탑재된 영·한 맞춤법 사전의 비대칭 근거를 사용한다.

1. 한국어 사전이 `K`를 인식하면 source를 보존한다.
2. 영어 사전이 `E`를 인식하고 한국어 사전은 `K`를 인식하지 않을 때만 영어로 교정한다.
3. 양쪽을 모두 인식하면 source를 보존한다.
4. 시스템 사전이 unavailable이면 완성형 source를 보존한다. 로컬 fallback 단어 목록 하나만으로 이 경로를 강제하지 않는다.
5. 교정한 경우 다른 승인 경로와 동일하게 exact range를 얻으면 원문 칩을 표시한다.
6. 3타 이상이면 이 authoritative 경로를 평가한다. 일반 구조 fallback의 4타 기준 때문에 `dog/앻` 같은 짧은 확정 후보를 사전 조회 전에 버리지 않는다.

실제 개발 Mac의 기본 사전 확인 예시는 다음과 같다.

- `vocal` hit + `팿미` miss → `팿미`를 `vocal`로 교정하고 `[팿미]` 제공
- `dog` hit + `앻` miss → 3타 완성형도 `dog`로 교정하고 `[앻]` 제공
- `auto` hit + `며새` miss → `며새`를 `auto`로 교정하고 `[며새]` 제공
- `worn` hit + `재구` hit → 현재 source인 `재구` 보존

### 7.3 양쪽이 모두 가능한 경우

`worn/재구`처럼 같은 물리 키열을 macOS 영·한 사전이 모두 인식하면 source를 보존한다. 반면 `vocal/팿미`처럼 영어만 인식되면 먼저 교정하고 원문 칩으로 즉시 복구할 수 있게 한다.

#### 단일 신호가 아닌 중첩 게이트

사전 hit 하나만으로 교정하지 않는다. Korean→Latin 승인은 다음 게이트가 **동시에** 성립한 결과다.

1. 비밀번호·주소·검색·보안 입력란이 아니고, 동일한 안전 필드와 캐럿을 유지한다.
2. 지원하는 한국어 두벌식 입력 소스에서 하나의 bounded 물리 타건 토큰을 얻는다.
3. Space 또는 `?`, `!`, `.`, `,` 경계까지 토큰이 끊기지 않았고 숫자·지원 밖 기호·긴 정지·overflow가 없다.
4. 같은 물리 키열로 만든 `E`가 영문 구조상 plausible이거나 macOS 영어 사전의 exclusive authoritative hit가 있다. `nth`처럼 사전이 인정하는 예외는 모음·`qu` 휴리스틱이 막지 않는다.
5. 확정 source 단어·반복 자모·고정 감탄 표현 같은 선행 보호 규칙에 걸리지 않는다.
6. `fullyComposed` 또는 `완성 음절 prefix + 자모 suffix` 경로에서는 macOS 영어 사전이 `E`를 인정하고, authoritative 한국어 source hit는 없어야 한다.
7. 실제 교체 직전에 필드·캐럿·예상 offset을 다시 확인한다.

즉 `해ㅐㅇ → good`과 `팿미 → vocal`은 예외 단어 하드코딩이 아니라 `안전 문맥 ∧ 올바른 입력 방향 ∧ 완전한 토큰 ∧ source 보호 미충돌 ∧ 영어 사전 hit ∧ 실제 한국어 source miss`의 결론이다. 반대 방향도 같은 대칭식으로 `한국어 hit ∧ 영어 source miss`를 적용한다. heuristic plausible/implausible은 사전이 없는 구조 경로의 신호이고, authoritative한 exclusive target hit가 있으면 그보다 우선한다. 시스템 사전 응답이 timeout·비정상으로 `unavailable`이면 완성형과 후행 자모의 공격적 사전 경로는 fail-closed로 원문을 보존한다.

| 영어 사전 | 한국어 source 사전 | authoritative | `팿미/vocal`, `해ㅐㅇ/good` 정책 |
|---|---|---:|---|
| hit | miss | 예 | 나머지 안전 게이트 통과 시 교정 + 원문 칩 |
| hit | hit | 예 | source 보존 |
| miss | miss | 예 | target 근거 부족으로 보존 |
| miss | hit | 예 | source 보존 |
| 어떤 값이든 | 어떤 값이든 | 아니오 | unavailable로 보고 보존 |

향후 문맥을 읽지 않는 한 선택지는 다음뿐이다.

- 항상 보존
- 사용자가 명시적으로 실행하는 수동 변환
- 앱·사용자별 선호를 별도 설정으로 받기

v3는 양쪽 authoritative hit일 때 source 보존을 선택한다. 한쪽만 authoritative hit인 경우에는 그 방향으로 교정한다.

---

## 8. Shift 정책

### 8.1 현재 사실

- `composeKoreanCandidate`는 이미 실제 Shift 자모를 사용한다.
- Q/W/E/R/T의 Shift는 `ㅃ/ㅉ/ㄸ/ㄲ/ㅆ`, O/P의 Shift는 `ㅒ/ㅖ`로 두벌식 자모 자체를 바꾼다.
- `Whgdk`는 실제로 `쫗아`까지 완전 조합될 수 있다.
- 현재 `hasShiftSensitiveKoreanStroke`는 구조 fallback의 실제 방어선이다.
- 앱의 화면 자동 대문자화는 물리 Shift 이벤트를 만들지 않는다. 따라서 “자동 대문자는 첫 글자에서만 생긴다”는 설명으로 물리 Shift 정책을 정당화하면 안 된다.

### 8.2 v3 결정

v2의 “Shift 민감 타건이 첫 타건일 때만 veto”는 **측정 전 확정하지 않는다.** 현재의 보수적인 Shift-sensitive veto를 유지한다.

v2의 회복 예시 중 `Wkrdms`, `Rkr`, `Qkfml`은 첫 타건 자체가 Shift 민감하므로 first-only veto에서도 여전히 막힌다. first-only 축소로 실제 회복되는 대표 사례는 `dlTdj`, `dhkTek`처럼 Shift 민감 타건이 중간에 있는 경우다.

정확한 target 번들 hit나 authoritative 시스템 target hit는 별도 고신뢰 경로에서 Shift 구조 veto를 넘어설 수 있다. 구조-only fallback의 축소 여부는 다음 코퍼스를 측정한 뒤 결정한다.

- 문장 첫 대문자와 실제 사용자 Shift
- ALL CAPS 약어
- CamelCase·제품명·코드
- 한글 된소리 포함 단어
- Shift+O/P의 `ㅒ/ㅖ` 포함 단어
- 첫 Shift와 내부 Shift의 오탐·누락 분리

---

## 9. 경계와 마침표 상태기계

### 9.1 구현 전 문제와 현재 해결

초기 구현에서 `.` `,` `?` `!`를 모두 즉시 교정 경계로 취급하면 `gksrmf.com`에서 `gksrmf`만 먼저 평가할 수 있었다. 현재 구현은 `.`만 `trailingPeriods` 상태로 유예하고, 빠른 후속 keyDown과 autorepeat에는 예약 교정을 취소해 URL·도메인 prefix를 부분 교정하지 않는다.

숫자, `_`, `/`, `@`와 같은 다른 기호는 `discardingUntilBoundary`로 전체 run을 소급 폐기한다.

### 9.2 v3 결정

- Space, `,`, `?`, `!`는 현재처럼 즉시 경계로 둔다.
- `.`만 별도의 `trailingPeriods` 상태로 유예한다.
- 모든 `.,?!`를 공백까지 미루는 v2안은 폐기한다.

이유는 `Dkssud?` 뒤에 곧바로 Enter를 눌러 전송하는 채팅 흐름을 보존하기 위해서다. `?`와 `!`까지 유예하면 공백이 없을 때 교정 기회를 잃는다.

### 9.3 서로 독립적인 세 상태기계

토큰 수집, 예약 교정, 원문 선택은 동시에 존재할 수 있으므로 하나의 enum에 섞지 않는다.

**`TokenCaptureState`**

| 상태 | 의미 |
|---|---|
| `idle` | 수집 중인 토큰 없음 |
| `collecting` | 최대 32개의 안전한 letter stroke 수집 중 |
| `trailingPeriods` | 1~3개의 `.`가 뒤따랐고 내부 기호인지 후행 문장부호인지 미정 |
| `discardUntilBoundary` | 현재 공백 run 전체가 교정 부적격 |

**`PendingCorrectionState`**

| 상태 | 의미 |
|---|---|
| `none` | 예약 교정 없음 |
| `awaitingTriggerKeyUp` | 최종 경계 keyDown은 통과했고 일치 keyUp 대기 |
| `awaitingFocusCheck` | keyUp 뒤 동일 요소·캐럿을 비동기 재검증 중 |
| `applying` | 삭제·replacement·경계 재주입 중 |

**`OriginalChoiceState`**

| 상태 | 의미 |
|---|---|
| `none` | 복원 가능한 교정 없음 |
| `chipVisible` | 원문 칩과 최대 6초 복원 transaction이 모두 활성 |
| `shortcutOnly` | 4초 칩은 숨었지만 기존 `⌘Z` transaction은 최대 6초까지 활성 |

새 letter가 들어오면 기존 `OriginalChoiceState`는 `none`이 되면서 같은 keyDown은 새 `TokenCaptureState`에 정상적으로 처리된다.

### 9.4 토큰 수집 전이

| 현재 상태 | 입력 | 다음 상태·동작 |
|---|---|---|
| `idle` | 지원 letter | `collecting` 시작 |
| `idle` | 경계·기호·Backspace | 그대로 통과, `idle` 유지 |
| `collecting` | letter | stroke 추가 |
| `collecting` | `.` | `trailingPeriods`, period 1개 버퍼 |
| `collecting` | Space·`,`·`?`·`!` | `TokenCaptureState → idle`; 평가 결과 decision이 있으면 `BoundarySequence`를 emit하고 `PendingCorrectionState: none → awaitingTriggerKeyUp` |
| `collecting` | 숫자·지원 밖 기호 | `discardUntilBoundary` |
| `collecting` | Backspace | 마지막 stroke 제거 후 원래 Backspace 통과; 비면 `idle` |
| `trailingPeriods` | `.` | 3개까지 버퍼·앱 통과; 네 번째부터 `discardUntilBoundary` |
| `trailingPeriods` | letter·숫자·기타 내부 문자 | `discardUntilBoundary` (`gksrmf.com`) |
| `trailingPeriods` | Backspace | period 하나를 pop하고 원래 Backspace 통과; 비면 `collecting` |
| `trailingPeriods` | Space·`,`·`?`·`!` | 해당 키를 최종 trigger로 평가한 뒤 `TokenCaptureState → idle`; decision이 있으면 `BoundarySequence`를 emit하고 `PendingCorrectionState: none → awaitingTriggerKeyUp` |
| `trailingPeriods` | Enter·Tab | 보존·reset 후 원래 키를 정확히 한 번 통과 |
| `discardUntilBoundary` | letter·숫자·`.`·기타 내부 문자 | 계속 discard |
| `discardUntilBoundary` | Backspace | 앞선 history를 모르므로 계속 discard, 원래 Backspace는 통과 |
| `discardUntilBoundary` | Space·`,`·`?`·`!`·Enter·Tab | 교정 없이 reset 후 `idle`, 원래 키 통과 |

period 자체의 keyUp은 그대로 통과하며 교정을 예약하지 않는다. period buffer가 모두 지워진 뒤 Backspace autorepeat가 계속되면 이후부터 수집 stroke를 하나씩 제거한다. smart punctuation이나 앱 자체 변환 때문에 예상 cursor offset이 다르면 어떤 삭제도 하지 않고 보존한다.

### 9.5 예약 교정과 원문 선택 전이

| 현재 상태 | 사건 | 다음 상태·동작 |
|---|---|---|
| `none` | 평가된 decision + trigger keyDown | `awaitingTriggerKeyUp` |
| `awaitingTriggerKeyUp` | 일치 trigger keyUp | `awaitingFocusCheck` |
| `awaitingTriggerKeyUp` | 무관한 keyUp | 그대로 통과, 상태 유지 |
| `awaitingTriggerKeyUp` | 다른 keyDown·trigger autorepeat | 예약 교정 취소, `none` |
| `awaitingFocusCheck` | focus 검증 성공 | `applying` |
| `awaitingFocusCheck` | 재시도 소진·generation 변경 | 아무 출력 없이 `none` |
| `applying` | 교정 성공 + exact range 사용 가능 | `chipVisible` |
| `applying` | 교정 성공 + chip anchor 없음 | `shortcutOnly` |
| `chipVisible` | 4초 UI 만료 | `shortcutOnly` |
| `chipVisible` | 원문 칩 클릭 성공 | 원문 복원 후 `none` |
| `chipVisible`·`shortcutOnly` | 기존 `⌘Z` 성공 | 원문 복원 후 `none` |
| `chipVisible`·`shortcutOnly` | 새 실제 입력·외부 클릭·외부 source 변경·6초 만료 | transaction 폐기 후 `none` |

### 9.6 경계 자료구조와 불변식

`PendingBoundaryCorrection`과 원문 복원 transaction은 단일 `(keycode, shift)`가 아니라 하나의 `BoundarySequence`를 공유한다.

```swift
struct BoundaryStroke {
    let keycode: UInt16
    let shift: Bool
    let producedCharacterCount: Int
    let producedUTF16Count: Int
}

struct BoundarySequence {
    let strokes: [BoundaryStroke]
    let triggerKeycode: UInt16 // 마지막 물리 경계의 keyUp을 기다린다.
}
```

현재 지원 기호는 ASCII 한 문자라 두 count가 모두 1이지만 계산 목적은 다르다.

- AX 예상 caret: `original.utf16.count + sequenceUTF16Count`
- 삭제 Backspace 횟수: `originalCharacterCount + sequenceCharacterCount`
- 교정문 range: 원래 token 시작 위치, 길이 `replacement.utf16.count`; 후행 경계는 포함하지 않음
- 교정 적용: 경계를 뒤에서부터 삭제 → 원문 삭제 → 결과 삽입 → 배열 순서대로 경계 재주입
- 원문 복원: 경계를 뒤에서부터 삭제 → 결과 삭제 → 원문 삽입 → 배열 순서대로 경계 재주입
- 기다릴 keyUp: `BoundarySequence`의 마지막 물리 trigger key

Enter·Tab 커밋은 현재 적용 메커니즘에 억지로 추가하지 않는다. 대상 앱 처리 후 같은 키를 재주입하면 제출·개행·포커스 이동이 중복될 수 있다. 별도 suppress-and-replay 설계가 검증되기 전까지 보존·reset이 안전한 기본값이다.

---

## 10. 원문-only 클릭 칩

### 10.1 제품 동작

자동교정이 성공하고 exact range 좌표·문자열 검증을 지원하는 앱이면 교정된 단어 바로 위에 작은 버튼 하나를 표시한다.

```text
   [qlfem]
     빌드
```

대괄호는 버튼 외곽을 설명하는 도식이며 실제 표시 문자가 아니다. 버튼의 시각적 내용은 물리 키열에서 재구성한 원문 `qlfem`뿐이다.

- 별도 제목 없음
- “원문” 없음
- “되돌리기” 없음
- 화살표·아이콘 없음
- 변환 결과 중복 표시 없음
- 키보드 선택 단축키 없음
- Enter·Tab·숫자 선택 없음

사용자가 버튼을 클릭하면 해당 교정만 원문으로 복원한다. 무시하고 타이핑하면 자동교정 결과가 유지된다.

### 10.2 “원문”의 정확한 정의

Mackor은 필드의 전체 값이나 주변 문장을 읽지 않는다. 칩에 표시하는 원문은 **물리 keycode와 Shift로 재구성한 source 문자열**이다. 다만 stale-text 삭제를 막기 위해 칩 표시 직전과 클릭 직전에 교정된 정확한 range만 읽고 예상 replacement와 일치하는지 비교할 수 있다. 이 range 문자열은 비교 직후 버리고 로그나 cache에 남기지 않는다.

앱이 자동 대문자화, smart punctuation, 자체 autocorrect를 적용했다면 화면에 잠깐 보였던 문자열과 100% 같지 않을 수 있다. 화면의 실제 이전 값을 읽어 완전 동일성을 보장하려면 현재 개인정보 원칙을 바꿔야 하므로 v3 범위에서 하지 않는다.

### 10.3 위치

`caretRect()`만으로 “해당 단어 위”를 추정하지 않고 현재 구현은 다음 절차를 사용한다.

1. 교정 전 `FocusToken.initialSelection`을 시작 offset으로 유지한다.
2. 교정 결과의 UTF-16 길이로 대상 range를 만든다.
3. 동일 AX 요소에 `kAXBoundsForRangeParameterizedAttribute`를 요청한다.
4. 같은 range의 문자열을 최소 범위로 읽어 예상 replacement와 일치하는지 확인한다.
5. 얻은 rect 위에 non-activating `NSPanel`을 배치한다.
6. range bounds 또는 exact-range 문자열 검증을 지원하지 않으면 임의의 위치에 표시하지 않고 칩을 생략한다.

이 과정은 범위 좌표와 교정된 exact range 문자열만 요청하며 주변 문장이나 필드 전체 값은 읽지 않는다.

### 10.4 클릭 안전성

기존 비대화형 알림은 mouse event를 무시해 클릭 전에 복원 트랜잭션이 사라지는 문제가 있었다. 현재 `CorrectionNoticeController`는 `ignoresMouseEvents = false`인 실제 버튼을 제공하고, `EventTapManager`와 content rect·generation을 공유해 칩 내부 클릭만 복원 트랜잭션 보존 예외로 처리한다.

현재 구현은 다음 안전 순서를 따른다.

1. 패널을 `.nonactivatingPanel`로 유지하되 `ignoresMouseEvents = false`로 한다.
2. 활성 원문 칩의 화면 rect와 transaction generation을 공유한다.
3. 전역 mouseDown이 칩 내부인지 먼저 hit-test한다.
4. 어느 mouseDown이든 조합 tracker, 수집 token, pending boundary correction은 reset한다.
5. 칩 내부 클릭일 때만 **원문 복원 transaction**을 mouse reset에서 보존하며 앱 포커스는 가져오지 않는다.
6. 버튼 action은 같은 transaction ID가 아직 활성인지 확인한다.
7. 클릭 직전 Secure Input, 동일 AX 요소, 동일 캐럿, 예상 replacement offset을 다시 확인한다.
8. 교정된 exact range만 읽어 현재 문자열이 예상 replacement와 같은지 확인한다.
9. 하나라도 다르거나 exact-range 읽기를 지원하지 않으면 어떤 문자도 지우지 않고 칩만 닫는다.
10. 성공하면 경계와 replacement를 지우고 원문과 동일 경계를 복원한다.
11. 입력 소스 복원 영수증의 generation이 맞을 때만 원래 source로 돌린다.

hit-test는 패널 그림자가 아닌 실제 버튼 content rect만 사용한다. `CGEvent.location`과 `NSPanel.frame`의 좌표계를 명시적으로 Quartz 전역 좌표 또는 AppKit 좌표 하나로 통일하고, 음수 원점의 다중 모니터에서도 `panel visible && generation 일치`일 때만 transaction 보존 예외를 허용한다.

칩 밖 클릭, 새 타건, 앱·포커스·커서 변경, timeout, 화면 잠금이나 세션 비활성화는 칩과 복원 transaction을 즉시 폐기한다. 입력 소스 변경은 다음처럼 구분한다.

- 교정 직후 영수증과 일치하는 Mackor 자신의 자동 source 전환: transaction 유지
- 그 밖의 사용자·앱·외부 source 변경: transaction 즉시 폐기

현재 `preserveUndoAcrossNextInputSourceChange`와 같은 generation 보호를 원문 칩 transaction에도 적용한다.

### 10.5 표시 시간과 데이터 수명

- 칩은 현재 알림과 비슷한 짧은 시간만 표시한다. 초기값은 4초다.
- 내부 복원 transaction은 기존 `⌘Z` 창을 넘지 않으며 최대 6초다.
- 칩이 사라졌어도 남은 6초 안에서 기존 `⌘Z`가 안전 조건을 만족하면 동작할 수 있다.
- 다음 의미 있는 입력이 들어오면 현재처럼 복원 transaction을 폐기한다.
- 원문과 결과는 판정 중 bounded RAM, 완료될 때까지의 맞춤법 worker 작업, 최대 6초의 복원/UI transaction에만 존재한다.
- 칩 hide·만료·reset 때 label 문자열, content view, target/action 또는 action closure와 transaction 참조를 명시적으로 비운다.
- 제한 시간 뒤에도 실행 중인 맞춤법 작업은 완료 즉시 후보 capture를 해제하며, 원문·결과 cache를 만들지 않는다.

### 10.6 실험 종료 조건

다음 중 하나가 반복되면 텍스트 위 칩을 취소한다.

- 대상 앱의 입력 포커스를 빼앗음
- 첫 클릭이 앱으로 새어가거나 이중 동작함
- 빠른 타이핑을 누락·지연시킴
- 잘못된 단어 위에 자주 표시됨
- 다중 모니터·전체 화면·Electron·Wine에서 위치가 불안정함
- VoiceOver 등 접근성 사용을 심각하게 방해함
- 원문 노출의 개인정보 비용이 효용보다 큼

기능 플래그로 UI만 즉시 끌 수 있어야 한다. UI를 제거할 때 엔진, `⌘Z`, 입력 소스 복원은 유지한다.

---

## 11. 복원 학습과 개인정보

### 11.1 v2 R5 판정

“사용자가 되돌린 토큰은 평생 기억한다”는 v2 R5는 폐기한다.

이유:

- 영구 저장은 현재의 입력 내용 비저장 약속과 충돌한다.
- 짧은 토큰 hash도 사전 공격이 가능해 익명화가 아니다.
- 사용자가 한 번 복원했다고 항상 그 단어를 영원히 금지하려는 것은 아니다.
- 앱, 방향, 대소문자, 물리 Shift, 시간에 따라 의도가 달라질 수 있다.
- 목록 확인·삭제 UI 없이 UserDefaults에 저장하면 통제권이 없다.

### 11.2 v3 최초 범위

원문 칩 클릭은 현재 교정 한 건만 복원한다. **최초 구현에는 자동 학습이나 영구 예외 저장을 넣지 않는다.**

반복 오교정 비용이 실제 사용에서 크다면 후속 실험으로 다음만 허용한다.

- 앱 종료 시 사라지는 session-only
- 방향 + 물리 타건 signature 기준
- bounded LRU와 짧은 TTL
- 기능 off·앱 종료 시 즉시 삭제
- 파일·UserDefaults·iCloud·네트워크 저장 금지
- 디버그 로그에 원문·결과 기록 금지

세션 억제를 도입하더라도 별도 정책·테스트·UI 검토 후 진행한다.

### 11.3 원문 칩이 바꾸는 개인정보 약속

원문 칩을 도입하면서 “알림에는 입력 단어를 표시하지 않는다”던 이전 개인정보 설명을 아래 약속으로 갱신했다.

현재 약속은 다음과 같다.

> 안전한 일반 텍스트 필드에서 자동교정 직후, 물리 키열로 재구성한 원문을 해당 텍스트 위에 최대 몇 초간 표시할 수 있다. 원문은 판정 중 bounded RAM과 최대 6초의 복원/UI transaction에만 존재하며 로그·파일·네트워크에 저장하거나 전송하지 않는다.

원문은 이미 사용자가 화면에 입력했던 값이지만, 화면 공유나 주변 사람이 볼 수 있는 시간이 늘어나는 새 노출 표면이다. 민감 필드 판정과 클릭 직전 재검증을 원문 칩에도 동일하게 적용한다.

---

## 12. v1·v2 제안 종합 판정

| 항목 | v3 판정 | 결론 |
|---|---|---|
| 동일 물리 키열에서 `E/K` 생성 | **채택** | 전체 설계의 중심 |
| 사전 target 등재를 필수로 하지 않음 | **수정 채택** | mixed 구조 경로는 이름·신조어 재현율을 유지하되, Korean-source fullyComposed는 macOS 사전의 비대칭 hit를 요구 |
| 둘 다 자연스럽거나 둘 다 불명확하면 보존 | **채택** | 원문 칩이 있어도 안전 게이트를 완화하지 않음 |
| “E invalid면 영어 의도가 아님” | **수정** | 강한 휴리스틱일 뿐, 약어·ID 반례 존재 |
| 한글 완전 조합이면 충분 | **수정** | 자동교정 자격 신호이지 의도 증명 아님 |
| 음절 bigram 도입 | **현 단계 미도입** | 고정 코퍼스에서 필요성이 입증될 때 재검토 |
| R1 혼합형/순수형 | **수정 채택** | pure는 known English 필요; mixed는 의도적 후행 자모 veto 추가 |
| R2 Shift veto 제거 | **폐기** | 실제 방어선임 |
| R2 first-stroke-only veto | **측정 보류** | 현재 보수 veto 유지, 설명·예시 오류 수정 |
| R3 최소 5타 | **폐기** | 짧은 한국어 재현율 손실 큼 |
| R3 종성 1개 요구 | **폐기** | `하나`, `가나`, `나비`, `여우` 같은 무종성 후보를 막음 |
| R3 약어 denylist | **현 단계 미도입** | 유지보수·일반화 문제; 코퍼스로 재평가 |
| Latin-source ALL CAPS | **신규 확정** | 길이 2 이상 하드 보존 |
| mixed-case 일괄 보호 | **폐기** | 일반 구조·사전으로 판단, 한글 Shift 재현율 보호 |
| lowercase `dhcp` | **공격적 보정** | `오체`로 보정 후 exact range를 얻으면 `[dhcp]` 제공; 측정 대상 |
| R4 모든 문장부호 유예 | **폐기** | `?` 뒤 Enter 등 채팅 UX 회귀 |
| R4 마침표 전용 유예 | **수정 채택** | URL prefix race 제거, 정식 상태기계 필요 |
| R5 평생 학습 | **폐기** | 개인정보·선호 노후화 문제 |
| 원문-only 클릭 칩 | **신규 실험** | 먼저 보정 후 원문 문자열 하나만 표시 |
| 코퍼스 회귀 하네스 | **필수 채택** | 정책 구현보다 앞선 gate |
| URL·ID·비밀번호 절대 보장 | **표현 폐기** | 관측 가능한 위험 문맥에서 fail-closed |

---

## 13. 제안 의사 코드

```swift
func decision(for token: PhysicalToken, source: InputSourceKind) -> Decision {
    guard safetyContextAllowsCorrection(),
          token.isWithinLengthAndTimingLimits,
          !token.containsUnsupportedRunCharacter else {
        return .preserve(.unsafeOrUnsupported)
    }

    if token.capsLockObserved {
        return .preserve(.capsLockObserved)
    }

    let E = token.latinCandidate
    let caseProfile = classifyPhysicalCase(token)

    if source == .supportedLatin,
       caseProfile == .allCaps,
       token.letterCount >= 2 {
        return .preserve(.latinSourceAllCaps)
    }

    let K = token.koreanCandidate
    let koreanShape = classifyKorean(K)
    let englishShape = classifyEnglish(E.lowercased())

    if bundledSourceWord(E, K, source) {
        return .preserve(.knownSource)
    }

    let looksLikeIntentionalJamo =
        looksLikeIntentionalKoreanJamoExpression(K)
    if source == .koreanTwoSet,
       koreanShape == .pureJamo,
       looksLikeIntentionalJamo {
        return .preserve(.koreanSourcePatternVeto)
    }

    let evidence = systemEvidence(E, K) // recognized / notRecognized / unavailable
    if evidence.recognizesSource(source) {
        return .preserve(.systemRecognizedSource)
    }

    switch source {
    case .supportedLatin:
        if bundledKorean(K), koreanShape == .fullyComposed {
            return .replace(E, with: K, confidence: .high, reason: .bundledTarget)
        }
        if evidence.authoritativelyRecognizesKorean,
           !evidence.authoritativelyRecognizesEnglish,
           koreanShape == .fullyComposed {
            return .replace(E, with: K, confidence: .high, reason: .authoritativeTarget)
        }
        guard token.passesShiftSensitiveFallbackPolicy else {
            return .preserve(.shiftSensitiveStroke)
        }
        guard englishShape == .implausible else {
            return .preserve(.insufficientTargetEvidence)
        }
        guard koreanShape == .fullyComposed else {
            return .preserve(.koreanSourceStillPlausible)
        }
        return .replace(
            E,
            with: K,
            confidence: evidence.isAvailable ? .mediumEvidence : .mediumUnavailable,
            showOriginalChip: true
        )

    case .koreanTwoSet:
        let exclusiveAuthoritativeEnglishTarget =
            evidence.isAuthoritative
            && evidence.recognizesEnglish
            && !evidence.recognizesKorean
        guard englishShape == .plausible
                || exclusiveAuthoritativeEnglishTarget else {
            return .preserve(.implausibleTarget)
        }

        let targetIsKnown = bundledEnglish(E)
            || exclusiveAuthoritativeEnglishTarget
        switch koreanShape {
        case .pureJamo:
            guard targetIsKnown else {
                return .preserve(.pureJamoWithoutKnownEnglishTarget)
            }
        case .mixed:
            guard !looksLikeIntentionalJamo
                    || exclusiveAuthoritativeEnglishTarget else {
                return .preserve(.koreanSourcePatternVeto)
            }
        case .fullyComposed:
            guard exclusiveAuthoritativeEnglishTarget else {
                return .preserve(.insufficientTargetEvidence)
            }
        case .unsupported:
            return .preserve(.unsupportedCandidate)
        }

        let confidence: Confidence = targetIsKnown
            ? .high
            : (evidence.isAvailable ? .mediumEvidence : .mediumUnavailable)
        let requiredAuthority = koreanShape == .fullyComposed
            || (koreanShape == .mixed && looksLikeIntentionalJamo)
        let reason = requiredAuthority
            ? .authoritativeTarget
            : (bundledEnglish(E) ? .bundledTarget : .structuralAsymmetry)
        return .replace(
            K,
            with: E,
            confidence: confidence,
            reason: reason,
            showOriginalChip: true
        )

    case .unsupported:
        return .preserve(.unsupportedInputSource)
    }
}
```

실제 구현에서는 `Decision`에 최소한 다음 진단 값을 둔다. 원문 자체는 로그에 남기지 않는다.

- direction
- confidence tier
- veto 또는 승인 reason enum
- token length
- case profile
- Korean shape
- system evidence availability
- punctuation state

---

## 14. 테스트 행렬

칩을 기대하는 아래 사례는 exact-range 조회와 anchor를 지원하는 테스트 필드에서 실행한다. 같은 입력을 미지원 필드에서 실행할 때는 교정 결과와 `shortcutOnly` transaction만 기대하며 칩 부재를 실패로 보지 않는다.

### 14.1 Latin source → Korean

| 입력 | 기대 |
|---|---|
| `qlfem` | `빌드`, `[qlfem]` 칩 |
| `gksk` | `하나`, `[gksk]` 칩 |
| `rksk` | `가나`, `[rksk]` 칩 |
| `qkfto` | `발새`, `[qkfto]` 칩 |
| `dhcp` | `오체`, `[dhcp]` 칩 |
| `dufma` + authoritative 한국어 hit·영어 miss | `여름`, `[dufma]` 칩; plausible heuristic보다 사전 근거 우선 |
| `GKSK` | 보존, 칩 없음 |
| `DHCP`, `SMTP`, `NASA`, `HTTP`, `XML` | 보존, 칩 없음 |
| Shift로 전부 입력한 `DHO`, `QLFEM` | 다른 형태·Shift 규칙과 무관하게 ALL CAPS 보존 |
| Shift로 전부 입력한 `GKSK` + fixture상 known target `하나` | target exact보다 먼저 ALL CAPS 보존 |
| Caps Lock `GKSK`/`gksk`, Caps Lock+Shift | run 폐기, 칩 없음 |
| ALL CAPS 타건을 Backspace한 뒤 새 타건 | 남아 있는 물리 stroke로 case profile 재계산 |
| `Mackor`, `OpenAI`, `iPhone`, `eBay`, `GitHub`, `OAuth` | case만으로는 차단하지 않되 최종적으로 정상 영문 보존 |
| 소문자 `whgdk` | `좋아`, `[whgdk]` 칩 |
| 실제 `Shift+W`인 `Whgdk` | 구조 fallback 보존 |
| `Dkssud?` | `안녕?` 즉시 교정, `[Dkssud]` 칩 |
| `rohan`, `schmidt`, `quora` | 영문 구조 또는 source 근거로 보존 |
| `Qatar`, `Iraq`, `OpenAI` | macOS 사전에 원형 case를 먼저 조회해 정상 영문 source를 보존 |
| `gksrmf2`, `gks_rm`, `gksrmf/path`, `gksrmf@x` | 전체 run 보존 |
| `gksrmf.com`, `gksrmf.co.kr` | 전체 run 보존 |
| `gksrmf.` + Space | `한글.` + Space, 경계 정확히 한 번 |
| `gksrmf...` + Space | `한글...` + Space |
| `gksrmf....` + Space | 4번째 period에서 discard되어 원문 보존 |

### 14.2 Korean source → Latin

| 한글 원문/물리 키 | 기대 |
|---|---|
| `ㅠㅕㅅ` / `but` | `but`, `[ㅠㅕㅅ]` 칩 |
| `ㅙㅈ` / `how` | `how`, `[ㅙㅈ]` 칩 |
| `ㅊ무` / `can` | `can`, `[ㅊ무]` 칩 |
| `ㅗ디ㅣㅐ` / `hello` | `hello`, `[ㅗ디ㅣㅐ]` 칩 |
| `ㅁㄴㅇ` / `asd` | 보존 |
| `ㅁㄴㅇㄹ` / `asdf` | 보존 |
| `ㄷㄷㄷ` / `eee` | 보존 |
| `ㅁㅁㅁ` / `aaa` | 보존 |
| `ㄴㄷㄷ` / `see`, `ㅁㅇㅇ` / `add`, `ㅅㄱㄷㄷ` / `tree` | 일부 double-jamo만으로 veto하지 않으며 macOS 영어 hit + 한국어 miss면 교정 |
| `챌ㄹㄷㄷ` / `coffee` | 후행 자모형이어도 macOS 영어 hit + 한국어 miss면 교정 |
| `ㅜ소` / `nth` | 영문 철자 휴리스틱은 implausible이지만 macOS 영어 hit + 한국어 miss면 교정 |
| `ㅋㅋ`, `ㅎㅎ`, `ㅠㅠ`, `ㅜㅜ`, `ㄷㄷ`, `ㅇㅋ`, `ㄱㄱ` | 보존 |
| `안녕ㅎ`, `진짜ㅋㅋ`, `와ㄷㄷ`, `헐ㄷㄷ`, `아ㅠ` | 보존 |
| 후행 자모 `해ㅐㅇ` / `good` | macOS 영어 hit + 한국어 miss면 `good`으로 교정 후 `[해ㅐㅇ]` 제공 |
| 완성형 `팿미` / `vocal` | macOS 영어 hit + 한국어 miss면 `vocal`로 교정 후 `[팿미]` 제공 |
| 3타 완성형 `앻` / `dog` | macOS 영어 hit + 한국어 miss면 `dog`로 교정 후 `[앻]` 제공 |
| 2타 `go`, `to`, `in`에 해당하는 Korean source | 자동 교정 최소 길이 미만이므로 사전 조회 없이 보존 |
| 완성형 `재구` / `worn` | macOS 양쪽 사전 hit면 source인 `재구` 보존 |
| 실제 Shift+B/U/T로 만들어진 `ㅠㅕㅆ` / `BUT` | 알려진 영어 `BUT`으로 교정; Latin-source ALL CAPS veto는 적용하지 않음 |
| Korean source에서 Shift로 전부 입력한 known target `HELLO` | case profile 자체로는 차단하지 않고 기존 target 근거로 판정 |

Korean-source의 target `E`가 ALL CAPS인 경우에도 case profile 자체는 veto가 아니다. `DHCP`처럼 영문 구조가 implausible한 target은 번들 항목만으로 휴리스틱을 넘지 않지만, macOS 영어 hit + 한국어 miss라는 exclusive authoritative 근거가 있으면 교정할 수 있다.

추가 충돌 회귀는 반드시 source 우선순위를 고정한다.

- 의도적 mixed/pure 자모 표현과 bundled-English target hit가 동시에 있어도 source 표현 보존
- `ㅗ디ㅣㅐ`, `ㅊ무`처럼 자모로 시작하는 mixed target은 후행 자모 source veto에 걸리지 않음
- authoritative source hit와 bundled target hit가 동시에 있으면 source 보존

### 14.3 Shift

- 첫 Shift-sensitive stroke
- 내부 Shift-sensitive stroke
- 여러 Shift-sensitive stroke
- Shift-sensitive Q/W/E/R/T/O/P 각각
- Shift-insensitive 첫 대문자 `Dkssud`
- ALL CAPS를 Shift를 계속 눌러 입력한 경우
- Caps Lock으로 입력한 경우
- 앱이 화면만 자동 대문자화한 경우의 실제 물리 lowercase
- `dlTdj`, `dhkTek`의 번들·시스템·구조 경로 분리

### 14.4 마침표·경계 상태

- `.` 1~3개 버퍼
- buffer 중 Backspace
- `.` 뒤 letter·digit·`_`·`/`·`@`
- `.` 뒤 Space·`,`·`?`·`!`
- `.` 뒤 Enter·Tab
- boundary autorepeat와 고아 keyUp
- 마지막 letter 뒤 긴 정지 후 boundary의 보존·교정 정책
- pending 중 다른 keyDown·마우스·앱·포커스·입력 소스 변경
- replacement·Undo·원문 칩 복원에서 N개 boundary 삭제·재주입 순서

### 14.5 원문 칩

- 교정 range 바로 위에 표시
- 시각 텍스트가 원문 하나뿐인지 확인
- 패널이 앱을 활성화하거나 key focus를 가져가지 않음
- 칩 내부 클릭에서 원문 복원 transaction만 mouse reset 예외로 유지
- 칩 내부 클릭도 tracker·token·pending correction은 reset하고 원문 복원 transaction만 유지
- 실제 button content rect와 Quartz/AppKit 좌표 변환, 음수 원점 다중 모니터 hit-test
- 클릭 성공 시 원문·경계·입력 소스 정확 복원
- stale focus·cursor·generation·Secure Input에서는 no-op
- 같은 AX 요소·caret offset이지만 exact replacement range를 앱이 바꾼 경우 no-op
- 칩 밖 클릭, 다음 키, 앱 전환, source 변경, timeout에 즉시 제거
- Mackor 자체 자동 source 전환은 transaction 유지, 이후 사용자 source 변경은 폐기
- 다중 모니터, 전체 화면, Retina scaling
- TextEdit, Safari, Chrome, Electron, VS Code, JetBrains, Wine/Corel
- 원문·결과가 로그·파일·UserDefaults·네트워크에 남지 않음
- hide·timeout·reset 뒤 panel label/content/action closure와 맞춤법 worker capture 해제
- range bounds 실패 시 칩을 띄우지 않음
- range bounds 실패나 UI 기능 off에서도 확정된 자동교정은 계속되고 기존 `⌘Z`만 남음
- 칩을 기능 플래그로 끄더라도 교정·`⌘Z`가 정상 동작

### 14.6 시스템 근거

- source English hit
- target Korean hit
- source Korean hit
- target English hit
- authoritative negative
- resource cold start
- 8ms wait timeout
- 언어 리소스 부재
- 정책 선행 반환으로 사전을 호출하지 않은 `notRequested`
- 사용자 사전 차이
- 서비스가 비정상적으로 모든 문자열을 정상으로 응답하는 sentinel 방어

---

## 15. 코퍼스 회귀 하네스

코퍼스 하네스는 구현되어 있으며 tune·holdout·system-evidence fixture를 독립적으로 회귀 검사한다. XCTest의 개별 사례만으로 총합 영향을 판단하지 않는다.

### 15.1 고정 조건

- 저장소 또는 재현 가능한 다운로드 위치에 버전 고정
- 라이선스 기록
- 파일 hash 기록
- 난수 seed 고정
- macOS·locale·입력 소스·맞춤법 언어 기록
- base commit과 dirty 여부 기록
- tune corpus와 holdout corpus 분리

### 15.2 필수 데이터 묶음

**한국어 target 재현율**

- 일반 단어와 활용형
- 이름·희귀 성명
- 외래어·제품명·신조어
- 종성 없는 2음절 단어 (`하나`, `가나`, `나비`, `여우`)
- 된소리와 실제 Shift가 포함된 단어

**영문 source 정밀도**

- 일반 영어 단어와 외국 이름
- 회사명·브랜드·약어 (`GKSK` 포함)
- ALL CAPS와 mixed case
- 프로토콜 (`DHCP`, `SMTP`, `HTTP`, `TLS`, `SSH`)
- CLI·패키지·기술 토큰 (`npm`, `brew`, `mkdir`, `nginx`, `mysql`, `json`, `yaml`, `uuid`, `oauth`)
- CamelCase, snake_case, kebab-case
- 파일명·경로·도메인·이메일·ID
- 영문 오타와 keyboard-walk

**한국어 source 정밀도**

- 순수 초성체와 자모 이모티콘
- `안녕ㅎ`, `진짜ㅋㅋ`, `와ㄷㄷ`, `아ㅠ` 같은 혼합형 채팅 표현
- 한글 오타와 미완성 조합

### 15.3 보고할 지표

아래 지표는 기본적으로 로컬 corpus runner와 명시적 E2E 테스트에서만 생성한다. 제품 입력 내용을 자동 원격 telemetry로 수집하지 않는다. 향후 사용 통계가 필요하다면 문자열 없는 enum/count에 한해 별도 opt-in 정책을 먼저 설계한다.

- 방향별 precision·recall·F1
- 길이별 3/4/5/6+ 분포
- case profile별 결과
- first/internal Shift별 결과
- system evidence notRequested/available/unavailable별 결과
- 문장부호·URL run별 결과
- high/medium confidence별 오탐
- 원문 칩 표시 성공률과 클릭 복원 성공률
- Event Tap callback P50/P95/P99
- 누락 키, `tapDisabledByTimeout`, focus race 횟수

“오탐 0”은 반드시 corpus 이름·버전·환경·표본 수와 함께 쓴다.

---

## 16. 성능과 원자성

### 16.1 이벤트 탭 시간

현재 안전성 검사에는 최대 50ms AX messaging timeout, 시스템 언어 근거에는 8ms wait deadline이 있다. 언어 리소스는 앱 시작 때 worker에서 비동기로 warm-up하고, timeout·비정상 응답은 `unavailable`로 fail-closed 처리하며 원문 문자열 cache를 만들지 않는다. 교정 적용은 여러 Backspace 사이에 pause를 둔다. 다음을 실제 앱에서 측정해야 한다.

정책과 deadline 자체는 구현됐지만 실제 EventTap callback, AX 정착 재시도, 다양한 앱의 사전 서비스 지연을 합친 종단간 성능 측정은 남아 있다.

- 키 이벤트 callback 지연
- 빠른 타이핑 중 dropped key
- `tapDisabledByTimeout`
- 시스템 사전 cold start
- 최대 32타 교체 시간
- 원문 칩 생성·range bounds 조회 시간

### 16.2 교체 원자성의 한계

현재 포커스 검사는 삭제를 시작하기 직전에 한 번 수행된다. 그 뒤 경계 삭제, 여러 Backspace, Unicode 주입, 경계 재주입, 입력 소스 전환 사이에 포커스가 바뀌면 부분 교체가 생길 수 있다.

따라서 “모든 교정이 완전히 원자적”이라고 약속하지 않는다. 릴리스 전 다음 E2E가 필요하다.

- 삭제 도중 앱·필드 전환
- 느린 AX 앱
- 원격 데스크톱·Wine·게임·raw-key 앱
- Unicode 주입 dummy keycode 호환성
- 실패 중간 상태에서 추가 문자를 다른 필드에 넣지 않는지

원문 칩 클릭 복원도 같은 위험을 가지므로 클릭 직전 재검증과 짧은 트랜잭션만으로 허용한다.

---

## 17. 구현 상태와 남은 순서

1. **완료 — 문서·테스트 기준 고정**
   - 현재 155개 통과를 기준으로 `asd` 보존과 다중 증거 진리표를 고정했다.
2. **완료 — 결정적 코퍼스 하네스**
   - 분류 함수를 UI·AppKit에서 분리하고 tune/holdout/system-evidence fixture 회귀 테스트를 두었다.
3. **완료 — Caps Lock과 ALL CAPS source veto**
   - Caps Lock run을 독립 폐기하고 Latin-source 물리 ALL CAPS 길이 2+를 소문자화 전에 보존한다.
4. **완료 — R1 수정 및 macOS 사전 중첩 게이트**
   - pure/mixed 분리, pure known-English 요구, 후행 자모 veto, 양방향 exclusive target 사전 규칙과 충돌 진리표를 검증했다. 문서의 구체 단어는 fixture일 뿐 생산 예외가 아니다.
5. **완료 — 판정 reason·confidence 모델**
   - 구조·사전·시스템 unavailable 경로를 문자열 없는 진단 enum으로 분리한다.
6. **완료 — `BoundarySequence`와 마침표 전용 상태기계**
   - 경계 배열, Backspace, 반복 period, offset·Undo를 단위 테스트했다.
7. **완료 — 원문 선택 transaction**
   - 다중 경계 삭제·복원, exact replacement 검증, source generation을 기존 `⌘Z`와 공유하도록 구현했다.
8. **완료(실험 플래그) — 원문-only 클릭 칩**
   - exact range bounds, nonactivating click, 좌표 변환, mouse-reset 중 복원 transaction 보존을 구현했다.
9. **측정 필요 — R2 Shift 정책**
   - 현재 보수 veto를 기준으로 first-only 실험을 corpus에서 비교한 뒤 결정한다.
10. **남음 — 실제 앱 E2E와 성능 gate**
   - 브라우저·Electron·IDE·Wine/Corel·민감 필드·포커스 race.
11. **보류 — 선택적 세션 억제 검토**
    - 실제 반복 오교정 데이터가 필요성을 보일 때만 별도 설계한다.

각 단계는 독립 PR 또는 독립 커밋으로 만들고, 이전 단계의 corpus·unit·E2E가 모두 통과한 뒤 다음 정책을 바꾼다.

---

## 18. 성공 기준

### 18.1 기능

- `qlfem → 빌드`, `gksk → 하나`, `rksk → 가나`가 target 한국어 사전 없이 동작한다.
- plausible 영문 형태라도 macOS가 한국어 target만 인식하면 개별 단어 추가 없이 한글로 복구된다.
- `but/how/can/hello`가 Korean source에서 영어로 복구된다.
- `asd/asdf/eee/aaa`와 의도적 자모 표현은 보존된다.
- Latin-source `GKSK/DHCP/NASA/HTTP/XML`은 보존되고 칩도 나타나지 않는다.
- lowercase `dhcp`처럼 승인된 구조 후보는 정책대로 먼저 보정되고, 정확한 range를 얻은 경우 원문 칩을 제공한다.
- `gksrmf.com`, 경로, 숫자·기호 혼합 run은 앞부분만 교정되지 않는다.
- `Dkssud?` 뒤 즉시 Enter 흐름을 깨뜨리지 않는다.

### 18.2 복구 UI

- range를 얻을 수 있는 지원 앱에서는 보정된 텍스트의 실제 range 위에 원문 문자열 하나만 표시된다.
- 클릭이 대상 앱 포커스를 빼앗거나 다른 mouseDown을 발생시키지 않는다.
- stale 상태에서는 어떤 텍스트도 지우지 않는다.
- 무시·새 입력·외부 클릭·timeout 시 흔적 없이 사라진다.
- UI 기능 플래그를 끄면 엔진과 `⌘Z`는 그대로 동작한다.

### 18.3 안전·개인정보

- 명확한 Secure Input과 보호 AX field에서 교정·칩이 모두 동작하지 않는다.
- 원문·결과를 로그, 파일, UserDefaults, crash report metadata, 네트워크에 명시적으로 기록·첨부하지 않는다.
- 입력 내용 전체나 주변 문장을 읽지 않는다.
- 시스템 근거 unavailable을 authoritative rejection으로 기록하지 않는다.
- 모든 정책 결과에 문자열 없는 reason enum을 남길 수 있다.

### 18.4 품질 gate

- 현재 155개 테스트와 이후 추가되는 v3 회귀 테스트가 모두 통과한다.
- 고정 holdout corpus에서 이전 승인 baseline보다 precision이 낮아지지 않는다.
- 명시된 하드 보존·민감 필드 fixture는 해당 테스트 실행 범위에서 100% 보존한다.
- 방향·길이·case·Shift·시스템 근거별 confusion matrix가 생성된다.
- 명시된 실제 앱 E2E 행렬에서 누락 키·이중 경계·이중 제출·포커스 탈취가 없다.
- Event Tap 지연과 timeout 수치가 릴리스 문서에 기록된다.

---

## 19. 남은 검토 질문

1. 혼합형에서 “완성 음절 뒤 후행 자모” veto가 정상 영어 복구를 얼마나 막는가?
2. 시스템 근거 unavailable bucket의 precision이 어느 수준 아래로 내려가면 현재 자동 적용 정책을 다시 열 것인가?
3. lowercase acronym(`dhcp`)의 오탐 비용이 원문 칩 복구로 감당 가능한가?
4. 원문 칩 exact range를 지원하지 않는 앱의 비율·오탐 비용이 어느 수준이면 현재 자동 적용 정책을 다시 열 것인가?
5. Shift-sensitive veto를 first-only로 줄였을 때 실제 precision·recall 변화는 무엇인가?
6. `.` 뒤 Enter·Tab에서도 안전하게 교정하려면 boundary를 suppress한 뒤 정확히 한 번 replay하는 별도 설계가 필요한가?
7. 클릭-only UI가 VoiceOver 사용자를 배제하지 않도록 `AXPress`를 허용할 것인가?
8. 원문 칩을 취소할 경우 기존 비대화형 알림으로 돌아갈지, 알림 자체를 없앨지?
9. 세션 한정 억제가 정말 필요한지, 필요하다면 TTL·LRU 크기와 앱 scope는 무엇인지?

이 질문들은 핵심 엔진을 모호하게 두기 위한 것이 아니다. v3에서 확정된 안전 게이트와 ALL CAPS 정책을 유지하면서, 측정이나 실제 앱 프로토타입 없이는 정직하게 확정할 수 없는 선택지만 분리한 것이다.

---

## 20. 최종 요약

v3의 제품 철학은 다음 한 문장으로 요약한다.

> **명확히 위험한 문맥과 Latin-source ALL CAPS는 건드리지 않고, 그 밖의 강한 구조 후보는 먼저 보정하되 exact range를 얻을 수 있으면 교정된 텍스트 바로 위에 물리 키열로 재구성한 원문 하나만 클릭 가능한 칩으로 잠깐 제공한다.**

이 원칙 아래에서:

- `GKSK`는 회사 약어로 보존한다.
- `gksk`는 `하나`로 먼저 보정하고 exact range를 얻으면 `[gksk]`를 제공한다.
- `Mackor`, `OpenAI`는 mixed-case라는 이유만으로 별도 차단하지 않는다.
- `asd`는 알려진 영어 target 근거가 없어 `ㅁㄴㅇ`를 보존한다.
- `dhcp`는 공격적 구조 정책의 비용을 숨기지 않고 `오체`로 보정한 뒤 exact range를 얻으면 `[dhcp]`를 제공한다.
- 원문 칩이 불편하거나 불안정하면 UI만 취소할 수 있다.
- 규칙의 완성도는 절대 표현이 아니라 고정 코퍼스, 실제 앱 E2E, 복원 성공률과 지연 수치로 증명한다.
