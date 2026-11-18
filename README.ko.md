# devlink

macOS용 개발 링크 탭 브라우저입니다. macOS에 내장된 WebKit 엔진(Safari와 같은 엔진)을 쓰므로 브라우저 엔진을 따로 담지 않습니다.

링크를 프로젝트와 환경(dev, staging, prod…)별로 묶습니다. 탭마다 쿠키와 저장소가 따로라서 같은 사이트에 여러 계정으로 동시에 로그인해 둘 수 있습니다. 데이터는 메모리에만 있고 탭이나 창을 닫으면 사라집니다.

[English](README.md)

## 기능

- 탭별로 격리된 웹사이트 데이터(쿠키, 저장소, 캐시): 시크릿 창 없이 같은 사이트에 여러 계정으로 동시에 로그인. 페이지에서 연 링크는 그 탭의 그룹 탭이 되어 데이터를 공유하고, "Open Link in Tab" 으로 열면 따로 시작합니다
- 스크롤하지 않고 한 번에 전체 페이지 스크린샷, 영역 스크린샷, 룰러와 안내선
- 프로젝트 → 환경 → 링크 구조
- 화면 분할, 스크롤 동기화
- 개발자 도구(Web Inspector), 모바일 보기
- 프로젝트 단위 내보내기·가져오기 (JSON), 새 프로젝트 또는 기존 프로젝트로 가져오기

## 단축키

| 메뉴 | 명령 | 단축키 |
|---|---|---|
| File | New Tab | ⌘T |
| | Close Tab | ⌘W |
| View | Zoom In / Zoom Out / Actual Size | ⌘+ / ⌘- / ⌘0 |
| | Split View / Unsplit | ⌘D |
| | Sync Scrolling (분할 화면에서만) | ⌥⌘D |
| | Developer Tools | ⌥⌘I |
| | Show / Hide Status Bar | ⌘/ |
| | Clear This Tab's Site Data | ⇧⌘⌫ |
| Capture | Capture Full Page | ⇧⌘S |
| | Capture Area | ⌥⌘S |
| | Show / Hide Rulers | ⌥⌘R |

## 빌드

Xcode 와 macOS 27 이상이 필요합니다.

1. `Config/Local.xcconfig.example` 을 `Config/Local.xcconfig` 로 복사합니다 (git 에서 제외됨).
2. 본인의 `DEVELOPMENT_TEAM` 과 역방향 도메인 형식의 `DEVLINK_BUNDLE_ID_PREFIX` 를 채웁니다.
3. `Devlink.xcodeproj` 를 열어 `Devlink` 스킴을 실행합니다.

## 참고

모바일 보기는 레이아웃 폭을 바꾸고 iPhone Safari 사용자 에이전트를 보낼 뿐, 터치 입력이나 실제 기기를 흉내 내지 않습니다. 참고용으로 쓰고 실제 기기에서 확인하세요. 또한 WebKit 비공개 API를 쓰므로 이후 macOS 업데이트에서 동작하지 않을 수 있습니다.

## 라이선스

[Apache License 2.0](LICENSE)
