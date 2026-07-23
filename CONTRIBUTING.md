# Mackor에 기여하기

첫 절이 가장 많이 오는 요청에 대한 답이고, 나머지는 실제로 코드를 고칠 때 필요한 것들입니다.

## 1. "제 앱에서도 되게 해주세요"는 PR이 아니라 이슈입니다

Mackor에는 **지원 앱 목록이 없습니다.** 설치된 모든 앱에서 이미 동작을 시도합니다. 그래서 앱을 "추가"할 자리 자체가 없습니다.

교정 엔진에는 앱 이름으로 갈라지는 분기가 **하나도 없습니다.** 소스에 나오는 앱 이름(Chrome · VS Code · Safari · Illustrator)은 전부 주석입니다 — 왜 그렇게 짰는지의 근거이지 조건문이 아닙니다. Electron 대응인 `AXManualAccessibility`조차 Chromium을 골라서 켜지 않고 [자동 교정 대상인 모든 앱에 그냥 켭니다](Mackor/Mackor/AppMonitor.swift). 지원하지 않는 앱에서는 호출이 실패할 뿐이고, 기존 경로가 그대로 쓰입니다.

이건 게으름이 아니라 선택입니다. 앱별 분기를 하나 받으면 그다음을 거절할 기준이 사라지고, 검증할 수 없는 특수 경로가 앱 수만큼 쌓입니다.

> **판정 기준 한 줄: PR이 특정 앱 이름을 조건문에 넣는다면 병합하지 않습니다.**

### 그럼 그 앱에서 발견한 문제는 어떻게 하나

**공통 계층의 개선으로 바꿔서** 보내 주세요. 실제로 그렇게 해결한 적이 있습니다 — "VS Code에서 첫 단어가 씹힌다"는 리포트는 VS Code 분기가 아니라 **모든 앱에 적용되는 AX 예열**로 해결됐습니다. 앱 이름은 코드가 아니라 주석에 근거로 남았습니다.

먼저 이슈로 관찰을 남겨 주세요. 앱 목록의 **요청** 버튼이 필요한 정보를 미리 채워 줍니다. 어느 계층의 문제인지 같이 좁힌 다음에 코드를 쓰는 편이 서로 시간을 아낍니다.

### 왜 앱별 PR은 리뷰가 성립하지 않는가

- 리뷰어가 그 앱을 갖고 있지 않습니다. CorelDRAW · AutoCAD · Illustrator를 전부 구입할 수 없습니다.
- CI로도 못 잡습니다. AX 지원 여부는 그 앱이 실제로 떠 있고 입력란에 포커스가 있는 **순간에만** 관찰됩니다.
- 즉 병합 근거가 **기여자의 주장뿐**입니다. 전역 키보드 이벤트를 가로채고 사용자가 친 글자를 지웠다 다시 넣는 앱에서, 그건 병합 사유가 되지 않습니다.

### `미지원` 목록에 추가하는 PR도 받지 않습니다

`TargetAppManager.knownAutoCorrectionUnsupportedKeywords`는 **되는 앱을 죽이는 방향**의 목록입니다. 검증이 안 되는데 파괴적이라 가장 나쁜 조합입니다. 게다가 앱이 실사용에서 스스로 학습하므로(`noteAutoCorrectionUnsupported`) 손으로 채울 필요도 없습니다. 지금 3개(`illustrator` · `coreldraw` · `intellij`)뿐인 것은 전부 관리자가 실기로 반복 확인한 항목이며, 추측으로 넣은 것은 하나도 없습니다.

## 2. 받는 기여

| 종류 | 검증 방법 |
|---|---|
| 단음절 사전 (`mono-admit.tsv` · `mono-veto.tsv` · `mono-source.ko.tsv`) | 생성 스크립트의 불변식 11개 + 파괴 표면 상한 |
| 회귀 fixture · 코퍼스 | XCTest |
| AX 대기·재시도 타이밍, 안전 필드 판정, 조합 추적 | XCTest + 실기 재현 |
| 문서 · 오탈자 · 번역 | 읽으면 됩니다 |

공통 조건 하나: **앱 이름이 조건문에 들어가지 않을 것.**

## 3. 개발 환경

- macOS 13 Ventura 이상, Xcode
- 저장소 루트의 `install.command`를 더블클릭하면 현재 소스를 Release로 빌드해 `/Applications/Mackor.app`에 설치합니다. 결과는 미공증이며 앱 내부 업데이트는 비활성입니다.
- ad-hoc으로 다시 빌드하면 코드 해시가 달라져 `시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용`에서 기존 항목을 지우고 새로 추가해야 할 수 있습니다.

테스트:

```sh
xcodebuild \
  -project Mackor/Mackor.xcodeproj \
  -scheme Mackor \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  test
```

## 4. CI가 막는 것 — 동결 게이트

PR을 열기 전에 알아두셔야 CI에서 놀라지 않습니다. `.github/workflows/ci.yml`에 두 겹의 동결 가드가 있습니다.

### 엔진 동결 (R4-1)

IMK 마이그레이션 동안 코어 규칙 자산 **31파일**이 바이트 단위로 바뀌지 않았음을 보증합니다. 해시 대조뿐 아니라 기준 태그 `pre-imk`와 직접 diff까지 봅니다. 여기에 손대면 CI가 **설계대로** 실패합니다.

동결된 Swift 파일:

```
EnglishPhonotactics · HangulCompositionTracker · HangulStructure · HangulUnicode
InputSourceController · KSX1001Table · KeycodeToJamoMap · LayoutCorrectionPolicy
WrongLayoutCorrectionEngine
```

전체 목록은 `scripts/engine-freeze.sha256`에 있습니다. 이 파일들을 고쳐야 하는 변경은 지금 시점에 병합할 수 없습니다 — 이슈로 먼저 이야기해 주세요.

동결되지 않은 곳(`EventTapManager` · `FocusedInputSafety` · `AppMonitor` · `LexicalGuard` · `LexicalTiebreaker` · `MonosyllableLexicon` · `TargetAppManager` · `MackorApp`)은 평소대로 고칠 수 있습니다.

### 어휘 동결 (Layer 1)

사전은 앞으로 자랄 자산이라 엔진 동결과 **별도**로 관리합니다. 태그 diff 가드 없이 해시 대조만 합니다. 사전을 바꾸려면 생성 스크립트를 돌려 매니페스트를 함께 갱신해야 하고, **그 diff가 곧 어휘 변화의 기록**이 됩니다.

## 5. 사전을 바꾸려면

한 글자 교정은 `해`(`go`)처럼 영어와 정면으로 충돌하는 항목을 포함합니다. 그래서 절차가 코드보다 엄격합니다. `scripts/lexicon/make_mono_lexicon.py`의 규약을 그대로 따릅니다.

1. `mono-source.ko.tsv` · `mono-veto.tsv` · `mono-admit.tsv` 중 하나를 편집합니다. **결정한 사유를 그 줄에 남깁니다.**
2. 아래를 차례로 돌립니다.
   ```sh
   python3 -B scripts/lexicon/make_mono_lexicon.py generate
   python3 -B scripts/lexicon/make_mono_lexicon.py verify
   python3 -B scripts/lexicon/make_mono_lexicon.py surface
   python3 -B scripts/lexicon/make_mono_lexicon.py audit   # 출력을 PR 본문에 붙입니다
   ```
   `audit`은 `$PATH`를 읽어 비결정적이므로 CI에서 돌리지 않습니다. 사람이 읽으라고 있는 것입니다.
3. `scripts/lexicon-freeze.sha256`을 `>>`로 갱신합니다. **정렬하지 마세요** — 추가 순서입니다.

`surface`가 막는 상한(`SURFACE_LIMIT`)을 올려야 한다면 사유를 커밋 메시지에 남깁니다. 자산이 자라면 파괴 표면도 자라므로, 리뷰가 diff를 놓쳐도 CI가 숫자로 잡게 해둔 장치입니다.

배경은 [MONOSYLLABLE_CORRECTION.md](MONOSYLLABLE_CORRECTION.md)에 있습니다.

## 6. 신뢰 경계

소스 공개와 Apple 공증은 별개입니다.

- 공개 저장소에서 기여를 받고, 검토·테스트를 통과한 커밋만 관리자가 Developer ID와 Sparkle 개인키로 다시 빌드·서명·공증해 배포합니다.
- **기여자에게 Apple 인증서나 Sparkle 개인키를 배포하지 않습니다.** PR이 병합돼도 마찬가지입니다.
- 자세한 내용은 [RELEASING.md](RELEASING.md)에 있습니다.

이 앱은 손쉬운 사용 권한으로 시스템 전역 키보드 이벤트에 접근합니다. 리뷰가 보수적인 이유가 그것입니다. 기능이 아니라 **권한의 크기**에 맞춘 기준입니다.

## 7. PR을 열 때

- 무엇을 왜 바꿨는지 본문에 씁니다. 이 저장소는 코드 주석에도 "왜"를 남기는 편입니다 — 같은 기준으로 봐주세요.
- 관련 이슈를 링크합니다.
- 재현 절차나 근거를 붙입니다. 실기로 확인한 것과 추측을 **구분해서** 적어 주세요. 추측을 추측이라고 적은 PR은 환영이고, 추측을 사실처럼 적은 PR은 되돌리기 어렵습니다.
- 테스트를 통과시킵니다. 사전을 바꿨다면 `audit` 출력도 함께 붙입니다.

## 8. 라이선스

MIT입니다. 기여하시면 같은 라이선스로 배포되는 데 동의하는 것으로 봅니다.
