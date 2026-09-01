# Codmes Server Manager

Codmes Server Manager는 터미널 명령 없이 Codmes Workspace 서버를 실행하는 별도
데스크톱 앱입니다. Chat/Notes/Code를 보여 주는 Codmes 클라이언트와 역할은
분리하지만, 서버 코드와 API 계약을 함께 변경하고 검증할 수 있도록 같은 Codmes
저장소의 `apps/server-manager`에 둡니다.

```text
Codmes 저장소
├── server/                 공용 Workspace·LLM·Tool·MCP 서버
├── client/                 Apple·Android·Windows 사용자 클라이언트
└── apps/server-manager/    서버 시작·중지·설정·로그를 담당하는 데스크톱 앱
```

## 설치

일반 사용자는 [Codmes GitHub Releases](https://github.com/knu-uic/Codmes/releases)에서
운영체제에 맞는 설치 파일을 받습니다. 설치 패키지 안에 Server Manager native
binary, Codmes 서버, Node, portable Python, production dependencies와 built-in
plugin이 모두 포함되므로 별도 서버·Node·Python 설치는 필요하지 않습니다.

| OS | 배포 파일 | 실행 형태 |
| --- | --- | --- |
| macOS | DMG | 메뉴바 앱, 선택적 Dock icon |
| Windows | EXE/MSI | system tray 앱 |
| Linux | DEB/RPM | system tray 앱 |

macOS arm64 설치본은 실제 앱 설치, 내장 서버 health, PDF/DOCX 추출까지 검증했다.
Windows와 Linux는 각 OS의 GitHub-hosted runner에서 native bundle과 portable Python을
만들고 검사한다.

## 제품 버전과 Release

Server Manager와 그 설치본에 포함된 서버는 `Codmes Server`라는 하나의 제품
버전을 사용합니다. 루트 `package.json`, Manager `package.json`, Tauri bundle과
Rust crate 버전이 모두 일치해야 `manager:check`가 통과합니다.

```text
codmes-server-v0.1.0
└── Codmes Server 0.1.0
    ├── Server Manager 0.1.0
    └── bundled Codmes server 0.1.0
```

`codmes-server-vX.Y.Z` 태그를 push하면 `server-manager-builds` workflow가 macOS,
Windows, Linux 설치본을 각각 만들고 같은 GitHub Release에 자동 첨부합니다. API,
Workspace schema, plugin manifest와 Distribution CLI처럼 독립 호환성이 필요한
계약 버전은 제품 버전과 별도로 유지합니다.

Release를 만들 때는 먼저 네 버전을 함께 올리고 검사한 뒤 같은 버전의 태그를
push합니다.

```bash
npm run manager:check
git tag -a codmes-server-v0.1.0 -m "Codmes Server 0.1.0"
git push origin codmes-server-v0.1.0
```

이미 존재하는 Release 태그는 다시 사용하지 않고 다음 patch/minor/major 버전으로
올립니다.

## 사용자 동작

- 앱을 열면 기본적으로 `127.0.0.1:8787`에서 서버를 시작합니다.
- macOS에서는 창을 닫아도 메뉴바에 남아 서버를 계속 실행합니다. Dock 아이콘은
  설정에서 선택적으로 표시할 수 있습니다.
- Windows와 Linux에서는 창을 닫아도 system tray에서 계속 실행합니다.
- 메뉴바·tray와 관리 창에서 서버를 시작하거나 중지할 수 있습니다.
- 로그인 시 Server Manager 자동 실행과 Manager 실행 시 서버 자동 시작을 각각
  설정할 수 있습니다.
- 관리 창에는 현재 주소, process ID, 자동 관리되는 데이터 경로와 최근 서버 로그가
  표시됩니다. 일반 사용자가 Workspace 폴더를 지정할 필요는 없습니다.

`Quit Codmes Server`로 앱을 완전히 종료하면 이 Manager가 시작한 서버 process도
함께 종료됩니다. 같은 주소에서 사용자가 직접 실행한 외부 서버는 감지하되 임의로
종료하지 않습니다.

Server Manager 앱이 서버 실행 파일과 Node runtime을 자체 포함하고 직접 서버
process를 관리합니다. 다만 Notes·대화·설정 같은 변경 가능한 사용자 데이터는 앱
번들 안에 저장하지 않습니다. 앱 업데이트나 삭제 시 데이터가 함께 사라지거나 쓰기
권한 문제가 생기지 않도록 macOS의 Application Support, Windows의 AppData,
Linux의 XDG data directory 아래 전용 Workspace를 자동으로 만들고 사용합니다.

## 안전한 기본 설정

기본 listen 주소는 이 컴퓨터에서만 접속할 수 있는 `127.0.0.1`입니다. 로컬
네트워크 공개(`0.0.0.0`)를 선택하려면 24자 이상의 server token이 반드시
필요하며 Manager가 자동으로 안전한 token을 생성합니다. 설정 파일은 Unix 계열
OS에서 현재 사용자만 읽을 수 있는 `0600`
권한으로 저장됩니다.

모바일이나 다른 PC에서 접속할 때는 Manager에서 Local network와 token을 설정한
뒤, 해당 기기의 Codmes 클라이언트에 서버 PC의 LAN/Tailscale 주소와 같은 token을
입력해야 합니다. 인터넷에 port를 직접 공개하는 방식은 권장하지 않습니다.

## 개발 실행

Node.js 22+, Rust, 해당 OS의 Tauri 2 빌드 요구사항이 필요합니다.

```bash
npm install
npm --prefix apps/server-manager install
npm run manager:dev
```

개발 모드에서는 저장소의 `server/index.mjs`와 시스템 Node를 사용합니다. 환경에
따라 명시적으로 바꾸려면 다음 변수를 설정할 수 있습니다.

```bash
CODMES_MANAGER_SERVER_ROOT=/absolute/path/to/Codmes \
CODMES_MANAGER_NODE=/absolute/path/to/node \
npm run manager:dev
```

## 테스트와 설치 패키지

```bash
npm run manager:check
npm run manager:build
```

`manager:build`는 먼저 `apps/server-manager/runtime`에 다음 항목을 준비한 뒤 현재
OS의 설치 패키지를 생성합니다.

- 현재 OS용 Node 실행 파일
- Codmes server·CLI·built-in plugin·vendor 코드
- production Node dependencies
- PDF/Office 본문 추출용 OS·CPU별 portable Python 3.11 runtime과 dependencies

Node 실행 파일은 OS와 CPU architecture가 다르면 호환되지 않으므로 macOS,
Windows, Linux 패키지는 각 OS의 CI runner에서 따로 만듭니다. GitHub Actions의
`server-manager-builds` workflow가 같은 검사를 수행하고 OS별 bundle을 artifact로
보관합니다.

개발 저장소의 `.codmes-runtime`은 복사하지 않습니다. 빌드할 때 uv가 Astral의
python-build-standalone 기반 Python을 현재 OS와 CPU architecture에 맞게 새로
준비하고, PDF·Office 추출 dependencies를 그 runtime에 직접 설치합니다. 따라서
개발자 컴퓨터의 Python 절대경로나 별도 Python 설치에 의존하지 않습니다. `uv`는
패키징 명령을 실행하는 빌드 환경에 필요하지만 완성된 Server Manager를 사용하는
일반 사용자에게는 필요하지 않습니다.

## 현재 범위

이 버전은 로그인 자동 실행되는 사용자용 tray 앱입니다. macOS LaunchAgent,
Windows 시작 프로그램, Linux desktop autostart를 사용하며 관리자 권한이 필요한
Windows Service나 systemd system service를 설치하지 않습니다. 따라서 사용자가
로그아웃한 뒤에도 서버가 계속 실행되어야 하는 무인 서버 환경에서는 기존 CLI를
systemd 등으로 등록하는 운영 방식이 아직 필요합니다.
