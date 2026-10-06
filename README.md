# Codmes

[![check](https://github.com/knu-uic/Codmes/actions/workflows/check.yml/badge.svg)](https://github.com/knu-uic/Codmes/actions/workflows/check.yml)

Codmes는 Chat, Notes, Code 등 여러 작업을 하나의 환경에서 연결하는 통합 AI 워크스페이스입니다.

Notes/Code 파일은 클라이언트 로컬 저장소와 사용자가 운영하는 서버를 선택해 사용합니다. 검색 인덱스, AI 런타임과 대화 기록은 서버가 관리하며, Mac, iPhone, iPad, Android, Windows 클라이언트는 같은 서버 계정으로 작업을 이어갈 수 있습니다. 플랫폼별 오프라인 지원 범위는 [Notes 문서](docs/features/notes.md)에 정리합니다.

단순히 AI와 대화하는 것을 넘어, 사용자의 문서와 노트, 코드 프로젝트, 이전 작업 맥락을 지속적으로 이해하는 개인 AI 에이전트 환경을 지향합니다.

한 기기에서 작성한 노트나 진행하던 코드 작업을 다른 기기에서도 그대로 이어갈 수 있으며, AI는 서버에 연결된 파일과 검색 인덱스를 바탕으로 필요한 정보를 찾아 답변하고 실제 작업을 수행합니다.

대용량 AI 모델은 서버에서 실행합니다. 파일은 기기별로 로컬·서버·동기화 모드를 선택하며, 파일 > 폴더 > 플러그인 순으로 설정이 우선합니다. 서버 연결 전에도 기본 화면·설정에 접근할 수 있고, Apple Notes/Code는 로컬 파일 작성·편집을 지원합니다.

Codmes가 제공하는 핵심 가치는 다음과 같습니다.

* 어디서든 접속할 수 있는 개인 AI 작업 환경
* 기기가 바뀌어도 유지되는 대화 맥락과 작업 상태
* Chat, Notes, Code 사이의 자연스러운 정보 연결
* 내 파일과 프로젝트를 이해하는 개인화된 AI 에이전트
* 문서 검색, 코드 작업, AI 추론을 하나의 서버에서 통합 처리
* 기기별 선택적 동기화와 서버 모드로 저장 공간 관리
* 사용자가 직접 소유하고 관리할 수 있는 데이터와 AI 환경

Codmes는 단순한 AI 채팅 앱이 아니라, 사용자의 지식과 파일, 프로젝트, 작업 흐름을 연결하고 어디서든 함께 작업할 수 있는 ‘나만의 AI 워크스페이스’입니다.

## 주요 기능

- Chat: 세션 관리, AI 모델 선택, 실시간 응답 스트리밍, 대화 문맥 유지, 접근 권한 관리, 파일 및 사용자 멘션, 대화 이미지 보관과 용량 확인
- Notes: 트리 기반 파일 관리, PDF 필기, 다양한 형식의 파일 열람 및 편집, 노트 내보내기, 노트와 문서를 기반으로 하는 AI 채팅
- Code: 소스 코드 탐색 및 편집, Code Agent 작업 실행, 변경 사항 패치 검토, 테스트 및 검사 결과 확인
- Search: 대화 기록 검색, 파일 및 문서 검색, 검색 인덱스를 활용한 통합 검색
- Server: AI Provider 및 모델 관리, Tool 실행, 파일과 검색 인덱스 관리, Workspace API 제공

아직 구현되지 않은 기능은 [roadmap](docs/roadmap.md)을 참고하세요.

## 빠른 시작

### 일반 사용자: Codmes Server 설치

Codmes Server는 Server Manager, 실제 Workspace 서버, Node, PDF/Office용 portable
Python과 built-in plugin을 하나의 설치 패키지로 제공합니다. Node나 Python을
별도로 설치할 필요가 없습니다. [GitHub Releases](https://github.com/knu-uic/Codmes/releases)에서
운영체제에 맞는 파일을 내려받습니다.

- macOS: `.dmg`
- Ubuntu/Debian x64: `.deb`

Windows Server Manager는 pgvector를 포함한 재배치 가능 PostgreSQL runtime이
준비될 때까지 독립 실행형 Release 대상에서 제외합니다.

초기 지원 범위를 명확히 하기 위해 Windows 기업 일괄 배포용 `.msi`와
Fedora/RHEL 계열용 `.rpm`은 생성하지 않습니다. 해당 환경은 실제 요구와
설치 검증 범위가 준비된 후 추가합니다.

앱을 실행하면 서버가 자동으로 시작됩니다. 기본값은 이 컴퓨터에서만 접근 가능한
`127.0.0.1:8787`입니다. iPhone·iPad·Android·다른 PC에서 접속하려면 Manager의
Access를 `Local network`로 바꾸고 클라이언트에서 Codmes ID·비밀번호 또는 연결된 Google 계정으로 로그인합니다.
첫 관리자 Codmes 계정은 서버 컴퓨터의 Server Manager에서 ID·비밀번호로 만들며 Google을 선택해 연결할 수 있고,
기본 관리자 프로필을 생성합니다. 공식 배포 앱에는 Codmes가 등록한
Google 로그인 설정이 포함되어 서버 운영자와 클라이언트 사용자가 별도 OAuth
프로젝트를 만들 필요가 없습니다.
Server Manager는 클라이언트 등록을 수락·거절·삭제합니다. 클라이언트의 비밀번호를 화면에 노출하지 않으며 서버 DB에는 검증용 scrypt 해시만 저장합니다.
다른 기기에서 접속하려면 신뢰 가능한 HTTPS 인증서를 설정해야 합니다.
승인된 Codmes 계정당 프로필 하나를 자동으로 만들고 같은 서버의 여러 기기에서
공유합니다. 별도의 프로필 추가나 필수 PIN 입력은 없습니다. `설정 → Profile`에서
원하는 사람만 기기별 앱 잠금 PIN을 켤 수 있습니다. 이 PIN은 서버에 보내지 않습니다.
Google 연결을 바꾸거나 해제해도 Codmes 계정·프로필·기기 승인은 유지됩니다. 기존 Google 사용자는 ID·비밀번호를 한 번 설정하며 자료는 보존됩니다.
Manager의 `프로필 관리`에서는 이름 변경과 삭제·복구를 관리하며 기존 자료는 보존합니다.

Server Manager와 그 안에 포함된 서버는 하나의 Codmes Server 제품 버전으로 함께
배포됩니다. 예를 들어 `codmes-server-v0.1.2` Release에는 같은 `0.1.2` Manager와
서버가 들어갑니다.

외부 plugin이 답변에 사용한 이미지는 세션에 필요한 항목만 Codmes Workspace로
복사해 대화 기록과 함께 보관합니다. 이후 대화를 열 때 plugin 서버에 다시
요청하지 않으며, `Settings > Chat History`에서 전체·세션별 용량을 확인하고
기존 기록을 수정·삭제할 수 있습니다.

Chat·Notes·Code·Planner는 Codmes에 포함된 built-in plugin으로, 독립
GitHub Release를 만들지 않고 Codmes 제품 버전과 함께 업데이트됩니다. KNU처럼
독립적으로 설치·업데이트하는 community plugin만 자체 저장소와 Release를
갖습니다. 상세한 규칙은 [Release 정책](docs/release-policy.md)을 참고하세요.
프로필 모드에서 community plugin은 서버에 한 번 설치하며, 클라이언트 Marketplace의
업데이트는 모든 프로필에 적용됩니다. 사용 여부·로그인 정보·도구 승인·데이터는
각 프로필에서 따로 관리합니다.

### 클라이언트 상태

- Apple 앱은 macOS와 iPhone·iPad를 지원합니다. Android와 Windows native client는
  공통 protocol, declarative Surface, Live Chat, 편집 가능한 Notes/Code 탐색을
  지원합니다. Code patch 승인·거절과 선택적 검사 실행, PDF 페이지 표시·필기·
  사각형·텍스트 주석 동기화도 지원합니다.
- Apple, Android, Windows 클라이언트는 GitHub Actions에서 각각 테스트·빌드되며
  Android APK와 Windows win-x64 실행 패키지는 CI artifact로 생성됩니다.

Apple 클라이언트는 현재 개발 실행에 Xcode와 Development Team 설정이 필요합니다.
Android는 Gradle/Android Studio, Windows는 .NET publish 또는 CI artifact로
실행합니다. 일반 사용자용 App Store/TestFlight/서명 설치본 배포는 별도 단계입니다.

### 개발자 요구사항

- Node.js 22 이상
- npm
- document runtime bootstrap용 Python 3.11~3.13
- Apple 앱을 build할 경우 Xcode
- 사용할 AI provider 또는 local model server

```bash
git clone https://github.com/knu-uic/Codmes.git
cd Codmes
npm install
npm link
npm run runtime:bootstrap
```

`runtime:bootstrap`은 저장소의 `.codmes-runtime`에 Python 환경과 PDF/Office
추출 library를 설치합니다.

### Model 설정

```bash
codmes model
codmes provider list
codmes model list
codmes auth list
codmes doctor --deep
```

Ollama Local을 빠르게 설정하려면 다음 명령을 사용할 수 있습니다.

```bash
codmes ollama
codmes ollama --model gemma4:e2b-mlx --serve
```

### 개발자용 CLI Server 실행

기본 주소는 `127.0.0.1:8787`, 기본 Workspace는 `~/CodmesWorkspace`입니다.

```bash
codmes serve
codmes serve --host 0.0.0.0 --port 8787 --root ~/CodmesWorkspace
```

환경 변수로 실행할 수도 있습니다.

```bash
CODMES_WORKSPACE_ROOT="$HOME/CodmesWorkspace" \
CODMES_HOST="0.0.0.0" \
CODMES_PORT="8787" \
CODMES_SERVER_TOKEN="충분히-긴-개인용-token" \
npm start
```

상태 확인:

```bash
codmes status
curl http://127.0.0.1:8787/api/health
curl http://127.0.0.1:8787/api/workspace
```

iPhone과 iPad는 Mac의 `127.0.0.1`에 접속할 수 없습니다. Mac의 LAN 또는
Tailscale 주소를 앱의 Server URL에 입력하고, 외부 interface로 열 때는
`CODMES_SERVER_TOKEN`을 설정하세요.

Server Manager 자체를 개발 실행하려면 다음 명령을 사용합니다. macOS에서는
기본적으로 Dock을 차지하지 않고 메뉴바에서 실행되며, Windows와 Linux에서는
system tray에서 시작·중지합니다.

```bash
npm --prefix apps/server-manager install
npm run manager:dev
```

설치 패키지를 만들 때는 현재 OS용 Node, portable Python과 Codmes 서버 파일을
앱에 포함합니다. 패키징 환경에는 `uv`가 필요합니다.

```bash
npm run manager:build
```

서버 매니저의 화면·native·패키징 결과도 `apps/server-manager/builds/`에 모으며
설치본은 `builds/rust/release/bundle/`에서 찾습니다. `src/`와 `src-tauri/`는 원본 코드라
Git에 포함하고, `builds/`와 `node_modules/`는 제외합니다.

Server Manager의 구조, 보안 기본값, 배포 방법은
[Server Manager 문서](docs/server/manager.md)를 참고하세요.

## 클라이언트 로컬 빌드

클라이언트는 `apps/client/`, 서버 매니저는 `apps/server-manager/`에서 관리합니다.
클라이언트의 `apple/`, `android/`, `windows/`, `shared/`는 Git에 포함하는 원본 코드이고,
`builds/`는 Git에서 제외하는 로컬 빌드 결과입니다. 루트에 별도 `client/` 복사본을
두지 않습니다. 플랫폼별 `builds/<platform>/latest/`는 최신
성공 빌드, `previous/`는 직전 성공 빌드입니다. 다음 빌드가 검증된 뒤에만 교체하며
더 오래된 스크립트 소유 `previous/`는 제거합니다. 날짜별 복사본을 계속 쌓지 않습니다.
빌드만 수행하며 설치된 앱을 교체하거나 실행하지 않습니다.

## Apple 앱 build

Xcode project는 `apps/client/apple/Codmes.xcodeproj`입니다.

macOS:

```bash
npm run client:build:macos
```

iOS Simulator:

```bash
npm run client:build:ios
```

두 명령은 Apple Silicon용 Release 개발 빌드와 서명 검증을 수행합니다. 결과는
`apps/client/builds/macos/latest/Codmes.app`과
`apps/client/builds/ios-simulator/latest/Codmes iOS.app`이며 DerivedData도 각각의
플랫폼 폴더에 유지합니다. iOS 시뮬레이터 서명을 유지하여 Keychain 오류를 방지합니다.
실제 iPhone/iPad 설치에는 Xcode에서 Apple Development Team을 지정해야 합니다.
서버 계정 연결은 `Settings → Connection`에서 하며 세션은 Keychain에 저장됩니다.
일반 사용자 배포용 서명·공증 DMG는 [Release 정책](docs/release-policy.md)을 따릅니다.

## Android 앱 build

```bash
npm run client:build:android
```

APK는 `apps/client/builds/android/latest/Codmes-debug.apk`에 모읍니다.
Gradle의 중간 빌드 디렉터리는 그대로 유지합니다. JDK 17과 Android SDK가 필요합니다.
검증은 `apps/client/android`에서 `./gradlew testDebugUnitTest lintDebug`로 실행합니다.

## Windows 앱 build

```bash
npm run client:build:windows
```

.NET 10이 필요하며 결과는 `apps/client/builds/windows/latest/`입니다. Mac에서도
크로스 빌드는 가능하지만 WPF 앱 실행 검증은 Windows에서 해야 합니다.
Linux용 Server Manager는 제공하지만 Linux Codmes 클라이언트는 아직 없습니다.

빌드 출력 경로·안전한 교체 규칙 테스트: `npm run client:build:test`.

전체 JavaScript 문법 검사와 server test:

```bash
npm run check
```

## 문서

- [Server architecture](docs/server/architecture.md)
- [Server API](docs/server/api-contract.md)
- [Server data model](docs/server/data-model.md)
- [Server Manager](docs/server/manager.md)
- [Apple client](docs/client/apple.md)
- [Client compatibility](docs/client/compatibility.md)
- [UI/UX 원칙](docs/client/ui-ux.md)
- [Debug 기록](docs/debug/)
