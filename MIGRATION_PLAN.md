# Mackor 하이브리드 실행 계획 — v2 (코덱스 NO-GO 반영 개정판)

기준: `REQUIREMENTS.md` · 태그 `pre-imk` · 브랜치 `imk`
방향 유지: **하이브리드(IMK 주 + CGEvent 탭 폴백)** — 방향 자체는 심판이 지지.
NO-GO 사유였던 근거 결함·설계 허점을 전부 반영해 개정했다.

> 개정 검증: 코덱스 지적 중 계획을 바꾸는 3건을 실물 재확인했다.
> ① `0x48474C46 = 1212632134` (계획서의 1215525702는 산술 오류)
> ② round4 로그의 트리거는 전부 `ctrl+opt` 2회전(소비 6회)인데 화면 기호는 3개이고
>    `∞§£`는 ⌥ 단독 문자 — **⌥만 누른 비트리거 passthrough였을 가능성**이 있어
>    "CorelDRAW가 소비를 무시" 판정은 감사 불가 → **강한 가설로 강등**
> ③ 언두 경로(:1142-1148)가 칩 클릭발 4번째 쓰기 진입점 — "정확히 3곳"은 틀림

---

## 0. 확정 vs 가설 (경계 재설정)

**실측 확정 (유지):**
- Corel: IMK 세션 성립·키 도달·`supportsDocumentAccess=true`인데 실제 질의 전실패(거짓 신고)
- TextEdit: mozc 패턴(setMarkedText(범위)→insertText(같은 범위)) 치환 성공 / 단독 insertText 무시
- D1: 대상 모드 enabled 전제 하에 selectMode 생존 (3차)
- CapsLock 모드 전환 시스템 제공 / ⌘Z 도달은 앱 의존 / 등록 즉시성

**가설로 강등 (G0에서 재측정 전 확정 서술 금지):**
- ~~Corel이 `handle()==true` 소비를 무시한다~~ → **6차 측정으로 확정.**
  `RET=true(소비) AUTO-CONSUME [com.corel...] chars=[q]`인데 화면에 `q` 출현.
  같은 세션 TextEdit 대조군은 미출현. **하이브리드 확정.**
- Corel 직접 조합 → 미측정이나 **우선순위 하락**(소비 무시가 확정돼 조합을
  표시해도 자모 키 유출이 먼저 발생)
- ~~Corel AX 게이트 실패~~ → **5차 측정으로 확정.** `AXRole=AXUnknown`으로 거부.
  (Chrome도 정정: nil이 아니라 `AXWebArea`라 role에서 거부. 50ms 타임아웃은
  원인이 아님 — 세 앱 다 50ms/2s 동일 10/10)
- ~~필드 42 마커의 NSEvent 왕복 생존 (A-1)~~ → **측정 완료(7차): 소실 확정.**
  마커 필터 폐기, injection barrier 필수 승격 (§2-3)
- ~~"하이브리드가 강제된다"는 조건부~~ → **G0 완료로 확정.** Corel은 소비를
  무시하므로 탭이 필수이고, Chrome은 AX role에서 거부되므로 IMK가 필수다.
  **양쪽 다 필요하다 = 하이브리드 확정.**

---

## 1. G0 — 재측정 팩 【완료 2026-07-20】

프로브 개정 후 아래를 **모두** 수행. 각 항목은 로그에 감사 가능해야 한다
(반환값·수식키·화면 결과 대응이 로그만으로 재구성 가능).

1. **Corel 소비 정직성**: 일반 문자 키 1개를 명시적으로 소비하는 전용 모드
   (예: ⌃⌥T로 "다음 키 1개 소비" 무장 → `q` 입력 → `return=true` 로그 + 화면에 q가
   찍히는지 사용자 확인). **return값 자체를 로그에 남긴다.**
2. **Corel 직접 조합**: `setMarkedText("ㅎ", NSNotFound)` → 화면 표시 여부 + markedRange.
   (직접 조합이 되면 rung 3 없이 Corel도 IMK 가능 — 하이브리드 범위 축소)
3. **Corel AX 직접 측정**: `FocusedInputSafety`와 동일한 AX 질의를 Corel 텍스트 도구에
   직접 수행 (§6-5 추론의 검증)
4. ✅ **A-1 완료(7차)**: 전용 주입기(`inject.swift`)로 제품과 동일 방식 태깅 후
   측정. `rawUserData=0` — 마커 소실 확정. 주입 이벤트의 `handle()` 도달은 확정.
   (Mackor로 주입시키는 경로는 막힌다 — 프로브가 입력 소스면 Mackor가
   `.unsupported`로 잠든다. 설계 §5-6 문제가 측정을 막는 형태로 나타남)
5. **빈 문서 3-프로브**: `length=0`은 빈 정상 문서에서도 나온다 — activate 직후
   빈 TextEdit에서 3-프로브 결과를 받아 Corel과 구분 가능한지 확인
6. P0-8 원시 등록 로그 보존 재실행 / flap 간격 히스토그램 계측 삽입

**게이트 판정: 통과.** Corel은 소비를 무시하므로 하이브리드 유지가 확정됐다.
6·7차 원시 로그: `MackorIMEProbe/p0-round6-consume-honesty.log`,
`p0-round7-marker-survival.log`. 잔여(직접 조합·빈 문서 3-프로브)는 Phase C 전까지.

---

## 2. 아키텍처 v2 (코덱스 보강 반영)

### 2-1. 중재자 — epoch 기반

- **세션 식별 = controller/sender identity + activation epoch.** bundleID는 분류
  캐시 키로만 쓴다 (round4 실증: activate(B) 후 deactivate(A)가 늦게 도착 —
  21:27:05.267 activate VSCode → .271 deactivate TextEdit).
- **불변식: `deactivate(A)`는 현재 owner B를 절대 해제하지 않는다.**
- 전이 순서 고정: `.none` + epoch 증가 → pending/조합 취소 → 분류 → epoch 재확인
  → 새 owner 게시.
- **출력 싱크 가드**: 모든 출력에 발행 시점 epoch를 싣고 **출력 직전 재확인.**
  쓰기 진입점은 4곳 — executeResult / applyCorrection / applySubmitCorrection /
  **undoLastCorrectionIfPossible(:1142-1148, 칩 클릭발)**. 핸들러 게이트만으로는
  4번째가 새므로 싱크 레벨 가드가 필수.
- reset 신호 확장: 앱 종료·IMK connection 상실·sleep/세션 전환·tap disable·권한 변화.
- flap: 멱등 핸들러 + **로깅 먼저**. live 조합 복원은 기본 안 함
  (bundleID 키 300ms 복원은 같은 앱 다른 필드로 상태를 옮길 수 있음 — 폐기.
  TTL은 분류 캐시 전용).

### 2-2. 탭 게이트 (유지 + 보강)

- 게이트 위치는 기록(:566/:602) **위** (유지 — 코덱스 동의)
- `handleKeyUp` 순서: injected 검사 → keycode → owner+활성 가드 → **가드 밖에서
  suppressed 정리** → 소유 시에만 지연 교정 무장 (코덱스 순서안 채택)

### 2-3. 주입 재진입 — owner-aware 방향 수정

- IMK 마커 분기는 무조건 `false`가 **아니다**: IMK에서 `false`는 폐기가 아니라
  **앱 전달**이다. 규칙: `owner==tap`이면 `false`(탭 주입이 앱에 도달해야 정상),
  **`owner!=tap`이면 `true`로 삼킨다** (비행 중 소유권이 바뀐 stale 백스페이스가
  앱에 착륙하는 것 방지).
- 카운터 백스톱은 **keyDown만 계수** (탭은 down+up 쌍을 post하지만 IMK에 keyUp은
  오지 않음 — 쌍 계수 시 카운터가 남아 다음 물리 키를 삼킴) + 데드라인.
- **A-1 실측 완료(7차) — 마커 경로 폐기 확정.**
  태깅 주입의 `field42=1212632134`가 `handle()`에서 `rawUserData=0`으로 읽힌다.
  무태그·물리와 **구분 불가**. 동시에 **주입 이벤트가 `handle()`에 도달하는 것은
  확정**됐다(그동안 추정이었음). → IMK 측 마커 필터는 성립하지 않으므로 설계에서
  제거한다. 탭→탭 가드(`:425`)는 CGEvent 그대로라 무영향(현행 제품이 증거).
  - **arbiter가 1차이자 유일한 방어선**이 된다.
  - **injection drain/handoff barrier 필수**(조건부 → **승격**): 탭 출력이 모두
    소진된 것을 확인한 뒤에만 owner를 전이. Phase C에서 구현하고 검증 항목에 명시.
  - 카운터 단독 금지는 그대로 유효 — barrier가 유일한 안전장치다.

### 2-4. 사다리 v3 — candidate 상태 신설 (R6 충돌 해소)

기존 설계의 결함: 미검증 신규 앱 = rung 3 = 첫 진입 시 권한 프롬프트
→ "Corel 안 쓰면 프롬프트 0회"가 거짓이 되고, 권한 거부 시 passthrough는
Mackor가 입력 소스인 이상 **한글 입력 불능**(교정 누락이 아님).

```
rung 0  프로브 금지 시드 (MS Office·Evernote) — 조합만, replacementRange 금지
rung 1  프로브 통과 + 왕복 검증 누적 → 완전 IMK (조합+R3)
rung 2  조합 OK, 문서 접근 불가 → 조합만
candidate  프로브 통과 + 미검증 신규 앱 → IMK 조합 수행 + 왕복 검증 증거 수집
           프롬프트 없음. 근거: 소비 부정직 앱에서도 IMK 조합의 최악은
           Apple IME와 동일(그 앱군은 Apple IME로도 깨짐 = R2 현상 그 자체)
           — 현상 유지이지 악화가 아님. 증거로 승격(rung1/2) 또는 강등(rung3).
rung 3  프로브 실패 or 시드 목록만 (진짜 탭 필요 앱)
```

- **권한 프롬프트는 "진짜 rung 3 앱에서 사용자가 실제 타이핑을 시작할 때"만.**
- 강등 즉시·권위적, 승격은 증거 누적. 세션 중간 전환 금지 유지.

### 2-5. A-5 — "구조적 항등" 철회, 발산은 실재

코덱스 반례 (의미론으로 성립): 엔진 BS는 **스트로크 1개** 제거 후 남은 키열 재생,
트래커 BS는 **문자 꼬리** 삭제 + 커밋된 음절 재개방 불가.
`g,e,BS,o,o,d` → 화면 4자(ㅎㅐㅐㅇ) vs decision.original 3자(해ㅐㅇ) → 백스페이스
카운트 1 부족. **Phase A 논거 3은 틀렸다.**

- **Phase A 즉시 수정**: 조합 활성 중 BS 발생 시 해당 토큰 R3 즉시 무효화
  (`invalidateCurrentTokenUntilBoundary`) — 작고 안전, 교정 기회만 잃음.
- **Phase B 근본 해결**: `MackorSession`에서 트래커/엔진이 스냅샷 스택 공유.
- **EditPlan 의미 연산 확장**: `deleteCharacters/insert`만으로는 IMK marked 수명을
  표현 못 함 (`processNonJamo()`는 reset 후 `.pass()` — 커밋 표현 없음).
  추가: `updateComposition(fullText, selectionUTF16:)` / `commitComposition` /
  `replaceCommittedRange(rangeUTF16:, with:)`. **Character vs UTF-16 단위 규율**
  (deleteCount는 Character, NSRange는 UTF-16 — 한글 BMP라 대개 1:1이지만 규율 명시).
- **패리티 테스트 강화**: 최종 텍스트만이 아니라 **매 키 후** 텍스트+markedRange+
  selection+commit 횟수+양끝 sentinel. 골든 405는 문자 키열 전용이라 BS·경계·
  marked 수명을 못 봄 — 해당 케이스 별도 생성. 두 renderer가 같은 버그를 공유하면
  패리티가 침묵한다는 한계를 문서에 명시.

### 2-6. Phase A 논거표 (개정)

| 논거 | 판정 |
|---|---|
| 1 자모 record는 부기 | 맞음 (유지) |
| 2 조합 reset 후 keyUp 교정 (D3) | 맞음 (유지) |
| 3 백스페이스 산술 항등 | **철회** → BS 무효화 수정으로 대체 |
| 4 `.selectedApps` 무변화 | 맞음 (유지) |
| 5 공존 상태 기출하 | 도달 가능성만 — 안전성 증거 아님 → 테스트로 보강 |
| 6 주석 오독 | 맞음 (유지) |

---

## 3. 단계 재편

### G0 — 재측정 팩 (§1) 【최우선, 반나절】

### Phase A — 회귀 수정 (G0 통과 후)
- scope 항 삭제 + 주석 교체 + `AppMonitorTests` 신설 + 공존 테스트 3종 (기존안 유지)
- **추가**: 조합 중 BS → 토큰 무효화 (§2-5)
- 게이트 추가: Corel 소비 재측정 결과 반영, Corel `dkssud`→`안녕` 실기 확인
- **배포 범위: 로컬 install.sh 한정** — 공개 릴리스는 토폴로지 확정(T) 후.
  구 토폴로지(`/Applications`+`com.mackor.app`) 사용자를 새로 만들면
  마이그레이션 부채가 늘어난다.
- 별도 PR 유지: `:435` 롤오버(즉시 적용 방향), 후행 마침표 발산

### Phase B — MackorSession + EditPlan(의미 연산 포함) + TapRenderer (~1.5주)
- 게이트: 44+405 무수정 + verdict diff 0 + **강화 패리티 프레임 구축**

### Phase T — 설치 토폴로지 확정 (신설, C 전 필수) (~0.5주)
- 번들 ID·설치 경로·TIS 등록 방식 확정. 마이그레이션 설계:
  legacy 앱 종료·로그인 항목 해제·이중 탭 방지·defaults/TCC 이전·uninstall/rollback
- Squirrel은 정상상태 선례일 뿐 `/Applications`→Input Methods **전환** 선례가 아님을
  명시 — 전환 리허설은 F 게이트

### Phase C — Arbiter(epoch) + IMK 골격 (~1주)
- **내부 카나리아 전용.** Mackor 입력 소스 선택 안내 금지 — 이 단계에서 선택하면
  대부분 앱에서 한글 입력 불능. 개발 머신에서만 선택해 rung/flap 분포 수집.
- 입력 소스 정체성 수정(AppMonitor:44) 동반 (유지)
- A-1 실패 시 injection drain barrier 여기서 구현

### Phase D+E 통합 — IMK 조합 + R3 동시 활성화 (~2주)
- 기존 D/E 분리는 **D 기간 동안 rung 1/2 앱의 R3가 소실**되는 결함 — 통합.
  owner가 IMK로 넘어가는 조건 = 조합과 R3가 **둘 다** 준비된 뒤.
- candidate 상태 왕복 검증 포함. 게이트: §R2 매트릭스 + 강화 패리티 전체 통과.

### Phase F — 토폴로지 전환 + 패키징 (~1.5주)
- T 설계의 실행: 서명 N→N+1 Sparkle **실업데이트 리허설**(marked 활성 중 종료·
  pending drain·재등록·rollback 각각 게이트), 공증, R6 A/B 실측
- 재승인 1회 예산·공지 (유지)

**공수: 7~10주** (기존 5~7주는 릴리스 엔지니어링 누락 — 정정).
독립 revert는 B 이후 역순만 가능, F의 TIS/TCC/경로 변경은 git revert로 복구
불가함을 명시.

---

## 4. 문서 동기화 (구현 시작 시)

- `MIGRATION_PLAN.md`: 이 v2로 교체 (십진수 1212632134 정정 포함)
- `docs/HYBRID_DESIGN.md`: 개정 이력 추가 (원본 보존, v2 차이 명시)
- `REQUIREMENTS.md`: ① Corel 판정을 "강한 가설, G0 대상"으로 강등
  ② D1 신구 판정 혼재 정리 — 폐기된 2차 "실패" 서술에 3차 정정 참조 표기
  ③ P0 측정/추론 대조표를 코덱스 목록 기준으로 갱신
- 프로브: G0 측정 모드 추가 (소비 트리거·return 로깅·AX 직접 질의)

## 5. 리스크 대장 갱신

기존 A-1~A-12에 추가:
| # | 리스크 | 완화 |
|---|---|---|
| A-13 | 두 renderer가 같은 버그 공유 시 패리티 침묵 | 실기 매트릭스가 최종 심판임을 명시 |
| A-14 | candidate 오승격(소비 부정직인데 왕복 통과) | 강등 즉시·권위 + 실기 관찰 채널 유지 |
| A-15 | G0 결과가 하이브리드 전제를 뒤집음 | 뒤집히면 계획 단순화(전 IMK) — 손실 아님 |

## 6. 검증 (전 단계 공통, 갱신)

- 매 Phase: 161 전체 + 44 + 405 무수정 + 동결 31파일 + pre-imk diff 0
- Phase B부터: 강화 패리티(매 키 스냅샷 비교)
- Phase D+E부터: §R2 실기 매트릭스 (느림/빠름 × 트리거 5종 × 10회, BS 시나리오 포함)
- 측정 로그가 없는 주장은 계획·문서에 확정 서술 금지 (이 세션 4회 과대 판정의 교훈:
  Electron AX / ⌘Z / replacementRange / Corel 소비)
