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

## 현재 공식 배포 차단 조건

2026-07-22 현재 `Developer ID Application: SEONGHUN KIM (TZQ9JL6R7R)`와 `Developer ID Installer: SEONGHUN KIM (TZQ9JL6R7R)`가 모두 유효하며, `build-installer.sh`의 공식 경로(`REQUIRE_SIGNING=1`)를 실제로 완주해 다음을 확인했습니다. 따라서 서명은 더 이상 차단 조건이 아닙니다.

- 전체 XCTest 213개 통과
- 앱이 `x86_64 arm64` 유니버설
- 최상위 앱 `valid on disk` + `satisfies its Designated Requirement`, 중첩 Sparkle XPC(Downloader·Installer)와 Updater.app까지 validated
- PKG가 `Developer ID Installer` 서명 + 신뢰된 타임스탬프, 체인이 `Developer ID Certification Authority` → `Apple Root CA`까지 완결
- DMG 서명·검증 통과
- `spctl -a -t install` 결과가 `rejected / source=Unnotarized Developer ID` — 서명은 정상이고 공증만 남았다는 뜻

남은 차단 조건은 공증과 Sparkle 배포 입력값입니다. `notarytool` 자격 증명을 Keychain에 저장한 것은 제출 준비일 뿐이며, 현재 Mackor 최종 산출물은 아직 제출·`Accepted`·staple되지 않았습니다. 또한 `REQUIRE_NOTARIZATION=1` 경로는 `MACKOR_UPDATE_FEED_URL`과 `MACKOR_SPARKLE_PUBLIC_ED_KEY`를 요구하는데, feed URL은 빌드 시점에 앱에 박히므로(`Info.plist`의 `SUFeedURL`) 호스팅 위치를 확정하기 전에 공증본을 만들면 그 빌드는 영구히 자동 업데이트를 받을 수 없습니다. Sparkle 배포 도구(`generate_appcast`)도 SPM checkout에는 포함되지 않아 별도로 받아야 합니다.

스크립트는 이 문제를 숨기지 않습니다. 다음 중 하나라도 충족되지 않으면 실패합니다.

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

## 2. 로컬 릴리스 후보 준비

먼저 PR/`main` GitHub Actions의 전체 XCTest와 Release Analyze가 통과했는지 확인하고, 깨끗하게 커밋된 작업 트리에서 필요한 환경변수를 설정한 뒤 실행합니다. `prepare-release.sh`는 공식 산출물을 만들기 전에 전체 XCTest를 다시 실행합니다.

```bash
scripts/prepare-release.sh <version> <new-build-number> /absolute/path/to/Mackor-<version>.md
```

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

`<new-build-number>`는 이전에 공개된 모든 `CFBundleVersion`보다 커야 합니다. marketing version만 바꾸고 build 번호를 재사용하면 Sparkle이 새 버전으로 판단하지 못할 수 있습니다.

현재 인증서가 유효하지 않거나 테스트가 실패하면 이 단계에서 종료되는 것이 정상입니다.

## 3. 공개 순서

공개 순서는 업데이트 중인 사용자가 아직 존재하지 않는 파일을 받지 않도록 반드시 지킵니다.

1. 정확히 `v<version>` 태그의 GitHub **Draft Release**를 만들고 PKG, DMG, ZIP, 릴리스 노트, SHA-256 파일을 업로드합니다.
2. 업로드한 파일을 다시 내려받아 크기와 SHA-256을 확인합니다.
3. Draft Release를 공개하여 다운로드 URL이 실제로 동작하는지 확인합니다.
4. `appcast.xml.pending`의 URL이 모두 동작하는지 마지막으로 확인합니다.
5. 그 파일을 `appcast.xml`로 게시합니다. **appcast가 항상 마지막입니다.**

이 저장소의 스크립트는 위 1~5의 공개 작업을 어느 것도 자동 수행하지 않습니다. 피드 호스팅 위치가 확정되고 별도의 명시적 승인 장치가 마련되기 전에는 로컬 준비와 검증까지만 담당합니다.

## 4. 공개 후 확인

- 처음 설치하는 Mac에서 PKG 더블클릭 설치
- 첫 공식 Mackor updater 기준선 이후 버전에서 **업데이트 확인…** 실행
- 업데이트 창에 같은 릴리스 노트가 표시되는지 확인
- 설치 후 앱 버전과 빌드 번호 확인
- Gatekeeper 경고 없이 실행되는지 확인

문제가 있으면 appcast를 같은 버전으로 덮어써서 숨기지 않습니다. 원인을 수정하고 새 marketing version·`v<version>` 태그와 더 높은 build 번호로 다시 테스트·서명·공증합니다.
