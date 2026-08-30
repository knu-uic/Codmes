# Codmes

[![check](https://github.com/knu-uic/Codmes/actions/workflows/check.yml/badge.svg)](https://github.com/knu-uic/Codmes/actions/workflows/check.yml)

Codmes는 Chat, Notes, Code 등 여러 작업을 하나의 환경에서 연결하는 통합 AI 워크스페이스입니다.

파일, 검색 인덱스, AI 런타임, 대화 기록과 작업 상태를 중앙 서버가 관리하며, 사용자는 Mac, iPhone, iPad, Android, Windows 클라이언트에서 서버에 접속해 같은 작업 환경을 이어서 사용할 수 있습니다.

단순히 AI와 대화하는 것을 넘어, 사용자의 문서와 노트, 코드 프로젝트, 이전 작업 맥락을 지속적으로 이해하는 개인 AI 에이전트 환경을 지향합니다.

한 기기에서 작성한 노트나 진행하던 코드 작업을 다른 기기에서도 그대로 이어갈 수 있으며, AI는 서버에 연결된 파일과 검색 인덱스를 바탕으로 필요한 정보를 찾아 답변하고 실제 작업을 수행합니다.

모든 기기에 대용량 AI 모델이나 프로젝트 파일을 개별적으로 저장할 필요 없이, 연산과 데이터 관리는 서버에 맡기고 클라이언트는 가볍게 접속하여 사용할 수 있습니다.

Codmes가 제공하는 핵심 가치는 다음과 같습니다.

* 어디서든 접속할 수 있는 개인 AI 작업 환경
* 기기가 바뀌어도 유지되는 대화 맥락과 작업 상태
* Chat, Notes, Code 사이의 자연스러운 정보 연결
* 내 파일과 프로젝트를 이해하는 개인화된 AI 에이전트
* 문서 검색, 코드 작업, AI 추론을 하나의 서버에서 통합 처리
* 로컬 기기 성능과 저장 공간의 제약을 줄이는 서버 중심 구조
* 사용자가 직접 소유하고 관리할 수 있는 데이터와 AI 환경

Codmes는 단순한 AI 채팅 앱이 아니라, 사용자의 지식과 파일, 프로젝트, 작업 흐름을 연결하고 어디서든 함께 작업할 수 있는 ‘나만의 AI 워크스페이스’입니다.

## 주요 기능

- Chat: 세션 관리, AI 모델 선택, 실시간 응답 스트리밍, 대화 문맥 유지, 접근 권한 관리, 파일 및 사용자 멘션
- Notes: 트리 기반 파일 관리, PDF 필기, 다양한 형식의 파일 열람 및 편집, 노트 내보내기, 노트와 문서를 기반으로 하는 AI 채팅
- Code: 소스 코드 탐색 및 편집, Code Agent 작업 실행, 변경 사항 패치 검토, 테스트 및 검사 결과 확인
- Search: 대화 기록 검색, 파일 및 문서 검색, 검색 인덱스를 활용한 통합 검색
- Server: AI Provider 및 모델 관리, Tool 실행, 파일과 검색 인덱스 관리, Workspace API 제공

아직 구현되지 않은 기능은[roadmap](docs/roadmap.md)을 참고하세요.

## 빠른 시작

### 요구사항
- Apple 앱은 macOS와 iPhone·iPad를 지원합니다. Android와 Windows native client는
  공통 protocol, declarative Surface, Live Chat, 편집 가능한 Notes/Code 탐색을
  지원합니다. PDF 주석과 Code patch review 같은 고급 화면은 플랫폼별 확장입니다.
- Apple, Android, Windows 클라이언트는 GitHub Actions에서 각각 테스트·빌드되며
  Android APK와 Windows win-x64 실행 패키지는 CI artifact로 생성됩니다.
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

### Server 실행

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

## Apple 앱 build

Xcode project는 `client/apple/Codmes.xcodeproj`입니다.

macOS:

```bash
xcodebuild \
  -project client/apple/Codmes.xcodeproj \
  -scheme Codmes \
  -configuration Debug \
  -destination 'platform=macOS' \
  build CODE_SIGNING_ALLOWED=NO
```

iOS Simulator:

```bash
xcodebuild \
  -project client/apple/Codmes.xcodeproj \
  -scheme 'Codmes iOS' \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  build CODE_SIGNING_ALLOWED=NO
```

실제 iPhone/iPad 설치에는 Xcode에서 Apple Development Team을 지정해야 합니다.
앱 settings에서 Server URL과 token을 입력하며 token은 Keychain에 저장됩니다.

전체 JavaScript 문법 검사와 server test:

```bash
npm run check
```

## 문서

- [Server architecture](docs/server/architecture.md)
- [Server API](docs/server/api-contract.md)
- [Server data model](docs/server/data-model.md)
- [Apple client](docs/client/apple.md)
- [UI/UX 원칙](docs/client/ui-ux.md)
- [Debug 기록](docs/debug/)
