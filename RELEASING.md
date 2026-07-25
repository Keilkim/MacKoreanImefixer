# Mackor 릴리스 절차

개발과 테스트는 Apple 공증을 기다리지 않고 계속할 수 있습니다. 공증은 사용자에게 전달할 **특정 빌드 산출물**이 확정된 뒤 수행합니다. 코드가 바뀌면 새 산출물을 다시 서명·공증해야 합니다.

두 배포 트랙은 서로 대체하지 않습니다.

- **일반 사용자:** 관리자가 GitHub Releases에 공증된 PKG/DMG를 게시하고, 이후 공증된 ZIP과 EdDSA 서명 appcast로 Sparkle 업데이트를 제공합니다.
- **오픈소스 기여자:** 저장소의 `install.command`로 현재 소스를 ad-hoc 로컬 빌드합니다. PR이 병합되면 관리자가 병합 커밋에서 공식 산출물을 새로 서명·공증합니다.

Developer ID, notarytool 프로필과 Sparkle 개인키는 공식 배포 관리자에게만 필요하며 기여자에게 전달하지 않습니다.

## 사용자가 받는 파일

- 처음 설치: 공증된 버전별 PKG를 다운로드해 더블클릭
- 수동 설치 대안: 공증된 DMG
- 앱 내부 업데이트: 공증된 앱 ZIP + Sparkle EdDSA 서명
- 변경 내용: 버전별 Markdown 릴리스 노트

GitHub 소스 공개와 Apple 공증은 별개입니다. 공개 저장소에서 기여를 받고, 검토·테스트를 통과한 커밋만 관리자의 Developer ID와 Sparkle 키로 공식 배포합니다.

## 공식 배포 게이트 (첫 릴리스에서 전부 통과)

첫 공식 릴리스 **v1.3(build 9)**이 2026-07-25에 아래 게이트를 모두 통과해 게시되었습니다. `Developer ID Application: SEONGHUN KIM (TZQ9JL6R7R)`와 `Developer ID Installer: SEONGHUN KIM (TZQ9JL6R7R)`가 유효하며, `build-installer.sh`의 공식 경로(`REQUIRE_SIGNING=1`, `REQUIRE_NOTARIZATION=1`)를 완주해 다음을 확인했습니다.

- 전체 XCTest 통과
- 앱이 `x86_64 arm64` 유니버설
- 최상위 앱 `valid on disk` + `satisfies its Designated Requirement`, 중첩 Sparkle XPC(Downloader·Installer)와 Updater.app까지 validated
- PKG가 `Developer ID Installer` 서명 + 신뢰된 타임스탬프, 체인이 `Developer ID Certification Authority` → `Apple Root CA`까지 완결
- DMG 서명·검증 통과
- 앱·PKG·DMG 각각 Apple 공증 `Accepted` + staple, `spctl` 결과가 `accepted / source=Notarized Developer ID`

feed URL은 빌드 시점에 앱에 박히므로(`Info.plist`의 `SUFeedURL`) 호스팅 위치를 먼저 확정한 뒤 공증본을 만들어야 그 빌드가 자동 업데이트를 받을 수 있습니다. v1.3은 `https://keilkim.github.io/MacKoreanImefixer/appcast.xml`로 확정한 뒤 구웠습니다. Sparkle 배포 도구(`generate_appcast`)는 SPM checkout에 포함되지 않아 별도로 받아야 합니다.

이후 모든 릴리스도 같은 게이트를 통과해야 합니다. 스크립트는 이 문제를 숨기지 않으며, 다음 중 하나라도 충족되지 않으면 실패합니다.

- 전체 테스트 통과
- arm64와 x86_64가 모두 포함된 앱
- 최상위 앱과 모든 중첩 Mach-O의 유효한 Developer ID Application 서명
- Developer ID Installer로 서명된 PKG
- 앱을 담은 임시 제출 ZIP, PKG, DMG 각각의 Apple 공증 결과가 명시적으로 `Accepted`
- 앱, PKG, DMG의 스테이플 및 Gatekeeper 검사 통과
- 앱에 HTTPS `SUFeedURL`, `SUPublicEDKey`, `SURequireSignedFeed`, `SUVerifyUpdateBeforeExtraction` 포함
- Sparkle 2.9+ `generate_appcast`가 만든 ZIP·릴리스 노트·appcast EdDSA 서명

중첩 서명은 Xcode archive/export에 맡기며 앱 외곽을 수동으로 다시 서명하지 않습니다. `--deep`은 서명 생성이 아니라 최종 검증에만 사용합니다.

첫 공식 Mackor 기준선에서 다음 식별자를 고정하고 이후 릴리스에서 임의로 바꾸지 않습니다.

- 앱 번들 ID: `com.mackor.app`
- 설치 경로: `/Applications/Mackor.app`
- 같은 Developer ID Team ID
- 같은 Sparkle Ed25519 공개키
- Sparkle dependency: 기준선은 정확히 `2.9.4`; 향후 변경은 별도 검토·테스트를 거쳐 의도적으로 갱신
- GitHub 태그: `v<MARKETING_VERSION>`
- `CFBundleVersion`: 이미 공개된 모든 Mackor 빌드보다 큰 양의 정수

legacy `/Applications/MacKR.app`(`com.mackr.app`)과 CorelHangulFix는 다른 앱 식별자·경로다. v1.3은 첫 공식 Mackor updater 기준선이며, legacy 앱의 설정·TCC·로그인 항목은 현재 자동 이전하지 않는다. 공개 전 별도 migration을 구현·검증하거나 사용자에게 수동 정리 절차를 안내해야 한다.

## 비밀 관리

다음 값은 Git에 커밋하지 않습니다.

- Developer ID 인증서의 개인 키
- Apple 계정 암호 또는 앱 암호
- notarytool 인증 정보
- Sparkle EdDSA 개인 키

Developer ID와 notarytool 프로필은 macOS Keychain에 둡니다. Sparkle 개인 키도 Keychain에만 보관합니다. 현재 릴리스 스크립트는 개인 키 파일 입력을 거부합니다. `SUPublicEDKey`는 공개키이므로 앱에 포함해도 안전합니다.

## 1. 릴리스 노트 작성

`RELEASE_NOTES_TEMPLATE.md`를 복사해 모든 자리표시자를 실제 내용으로 바꿉니다. 같은 버전을 `CHANGELOG.md`에도 추가합니다. 새 기능뿐 아니라 수정 사항, 권한 변경, 기본 동작 변경을 사용자 관점으로 적습니다.

`CHANGELOG.md`의 해당 버전 제목은 `## [<version>] - YYYY-MM-DD`(하이픈·en/em 대시 모두 허용, 실제 배포일)로 확정하고, 하단 비교 링크도 `v<이전>...v<version>` 태그 범위로 바꿉니다. `prepare-release.sh`는 날짜 없는 제목, "배포 전"·"초안" 등 미배포 표기, 실제 달력에 없는 날짜, 미래 날짜, `...HEAD`를 가리키는 비교 링크를 모두 거부합니다.

## 2. 로컬 릴리스 후보 준비

먼저 PR/`main` GitHub Actions의 전체 XCTest와 Release Analyze가 통과했는지 확인하고, 깨끗하게 커밋된 작업 트리에서 필요한 환경변수를 설정한 뒤 실행합니다. `prepare-release.sh`는 공식 산출물을 만들기 전에 전체 XCTest를 다시 실행합니다.

작업 트리 검사는 `--untracked-files=all`이므로 **추적되지 않는 파일이 하나라도 있으면 중단합니다.** 커밋하거나 저장소 밖으로 옮긴 뒤 실행합니다.

```bash
scripts/prepare-release.sh <version> <new-build-number> dist/releases/Mackor-<version>-<build>.md
```

릴리스 노트 파일명은 산출물과 같은 `Mackor-<version>-<build>.md` 규약입니다. 이 파일이 그대로 릴리스 자산이 되고 appcast의 `releaseNotesLink`가 EdDSA로 서명하므로, **게시 후에는 한 글자도 고칠 수 없습니다**(고치면 서명 길이·해시가 어긋나 업데이트 창이 노트를 거부합니다). 문구는 빌드 전에 확정하세요.

필수 환경변수의 전체 목록은 `scripts/prepare-release.sh`를 인자 없이 실행하면 볼 수 있습니다. 스크립트는 테스트부터 공증과 Sparkle 피드 검증까지 순서대로 수행하되 외부에 아무것도 게시하지 않습니다.

성공한 산출물은 다음 위치에만 보관됩니다.

```text
dist/releases/<version>-<build>/
├── Mackor-<version>-<build>.pkg
├── Mackor-<version>-<build>.dmg
├── Mackor-<version>-<build>.zip
├── Mackor-<version>-<build>.md
├── Mackor-<version>-<build>-SHA256SUMS.txt
└── appcast.xml.pending
```

`<new-build-number>`는 이전에 공개된 모든 `CFBundleVersion`보다 커야 합니다. 이 규칙은 이제 `prepare-release.sh`가 라이브 appcast(`MACKOR_UPDATE_FEED_URL`)의 모든 `sparkle:version`을 조회해 기계적으로 강제하며(테스트·빌드 전에 먼저 검사), 피드를 가져오지 못하면 실패합니다(공증도 네트워크가 필요하므로 오프라인 준비는 지원하지 않습니다). 저장소의 `docs/appcast.xml`과 라이브 피드의 최신 빌드가 다르면(미완료 게시 또는 `git pull` 필요) 역시 중단합니다. marketing version만 바꾸고 build 번호를 재사용하면 Sparkle이 새 버전으로 판단하지 못합니다.

현재 인증서가 유효하지 않거나 테스트가 실패하면 이 단계에서 종료되는 것이 정상입니다.

## 3. 공개 순서

공개 순서는 업데이트 중인 사용자가 아직 존재하지 않는 파일을 받지 않도록 반드시 지킵니다.

0. **릴리스 커밋을 먼저 push합니다.** GitHub은 아직 없는 태그를 만들 때 대상 브랜치가 **원격에서** 가리키는 커밋에 붙입니다. 로컬에만 있는 커밋 위에서 릴리스를 만들면 태그가 조용히 그 이전 커밋에 붙고, 자산·appcast는 정상이라 어떤 검증도 이를 잡지 못합니다(v1.9에서 실제로 발생). push한 뒤 다음이 일치하는지 확인합니다.

   ```bash
   git push origin main
   git rev-parse origin/main            # prepare-release.sh 를 돌린 HEAD 와 같아야 합니다
   ```

   `v<version>` 태그는 **산출물을 빌드한 커밋**, 즉 appcast 게시 커밋 직전 커밋을 가리켜야 합니다. 게시 후 확인:

   ```bash
   gh api repos/<owner>/<repo>/git/ref/tags/v<version> --jq '.object.sha'
   git log --oneline v<이전>..v<version>   # 이번 릴리스의 커밋이 전부 보여야 합니다
   ```

1. 정확히 `v<version>` 태그의 GitHub **Draft Release**를 만들고 PKG, DMG, ZIP, 릴리스 노트, SHA-256 파일을 업로드합니다.
   - 여기에 더해 **버전 없는 고정 이름 `Mackor.dmg`** 를 같은 릴리스에 하나 더 올립니다. 이는 `Mackor-<version>-<build>.dmg`와 **바이트가 동일한 복사본**이며, 웹사이트(`docs/index.html`)의 다운로드 버튼이 가리키는 `releases/latest/download/Mackor.dmg` 링크가 버전이 올라가도 항상 최신을 주도록 하기 위한 별칭입니다. Sparkle 자동 업데이트는 이 별칭을 쓰지 않고 계속 버전 이름 자산을 사용합니다.
2. Draft Release를 공개합니다.
3. `scripts/verify-published.sh <version> <build> before-appcast`를 실행합니다. 자산 6종의 존재·크기·SHA-256과 재다운로드 바이트 대조, 별칭 `Mackor.dmg`==버전 DMG, `releases/latest`==태그, 랜딩 버튼 URL, 그리고 **appcast에 새 빌드가 아직 없는지**(순서 위반 감지)를 확인합니다. 실패하면 appcast를 게시하기 전에 자산을 바로잡습니다.
4. `appcast.xml.pending`으로 `docs/appcast.xml`을 교체해 커밋·푸시합니다. **appcast가 항상 마지막입니다.** 이 pending 파일은 기존 `docs/appcast.xml`의 모든 과거 항목을 보존한 **전체 피드**이므로, 통째로 교체하면 됩니다(과거 릴리스 ZIP 보관이나 수동 병합 불필요).
5. `scripts/verify-published.sh <version> <build>`(final)를 실행합니다. 라이브 피드의 새 항목·enclosure URL/length·EdDSA 서명(도구가 있으면)과 라이브==`docs/appcast.xml` 동일성까지 확인합니다.

이 저장소의 스크립트는 위 업로드·공개·appcast 게시를 어느 것도 자동 수행하지 않습니다. `verify-published.sh`는 `gh api`·`curl`의 읽기 전용 조회만 하므로 이 정책의 예외가 아니라, 정책이 요구하는 수동 게시의 검증 단계를 자동화한 것입니다.

## 4. 공개 후 확인

- 처음 설치하는 Mac에서 PKG 더블클릭 설치
- 첫 공식 Mackor updater 기준선 이후 버전에서 **업데이트 확인…** 실행
- 업데이트 창에 같은 릴리스 노트가 표시되는지 확인
- 설치 후 앱 버전과 빌드 번호 확인
- Gatekeeper 경고 없이 실행되는지 확인

문제가 있으면 appcast를 같은 버전으로 덮어써서 숨기지 않습니다. 원인을 수정하고 새 marketing version·`v<version>` 태그와 더 높은 build 번호로 다시 테스트·서명·공증합니다.

## 5. 웹사이트(랜딩 페이지)

일반 사용자가 GitHub 화면을 거치지 않고 받도록, 저장소 `docs/index.html`에 정적 랜딩 페이지를 둡니다. 파일 자체는 GitHub Releases에 있고, 페이지는 **얼굴 역할만** 합니다.

- 호스팅: **GitHub Pages** — 저장소 **Settings → Pages → Source: `Deploy from a branch` → `main` / `/docs`**. 게시 주소는 `https://keilkim.github.io/MacKoreanImefixer/`입니다.
- 다운로드 버튼은 `https://github.com/Keilkim/MacKoreanImefixer/releases/latest/download/Mackor.dmg`를 가리킵니다. 이 링크는 §3 1단계에서 올린 **고정 이름 별칭**이 있어야 동작하며, `verify-published.sh`가 그 존재·동일성을 검사합니다. 별칭이 없는 릴리스에서는 404가 납니다.
- 페이지는 순수 정적 HTML/CSS/JS 한 파일이며 외부(서드파티) 요청·추적이 없습니다. 유일한 요청은 같은 오리진의 `announcements.json`(앱과 공유하는 공지 소스)을 읽어 "새 소식"을 릴리스처럼 표시하는 것뿐이며, 파일이 없거나 JS가 없으면 그 섹션은 조용히 숨깁니다. 문구·예시는 README와 앱의 실제 동작 범위에 맞춰 유지합니다.
- 공지 게시는 릴리스와 별개입니다. `docs/announcements.json`의 `announcements` 배열 맨 앞에 `{ "id", "date", "kind": "apps"|"fix"|"notice", "title", "body", "url"(선택) }` 항목을 추가해 커밋·push하면, 설치된 앱의 알림과 이 랜딩이 같은 소스로 함께 갱신됩니다. `id`는 한 번 정하면 바꾸지 않습니다(수정은 새 항목으로).

### Sparkle 피드와의 순서 주의

`SUFeedURL`은 빌드 시점에 앱에 박히므로(위 "공식 배포 게이트" 참고), 자동 업데이트 피드도 여기서 호스팅할 계획이면 **호스팅 주소(GitHub Pages 또는 커스텀 도메인)를 먼저 확정한 뒤 공증 빌드를 만들어야** 합니다. v1.3은 `https://keilkim.github.io/MacKoreanImefixer/appcast.xml`로 확정한 뒤 구웠습니다.
