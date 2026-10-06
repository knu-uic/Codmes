# Codmes Server Manager

Codmes Server Manager는 터미널 명령 없이 Codmes Workspace 서버를 실행하는 별도
데스크톱 앱입니다. Chat/Notes/Code를 보여 주는 Codmes 클라이언트와 역할은
분리하지만, 서버 코드와 API 계약을 함께 변경하고 검증할 수 있도록 같은 Codmes
저장소의 `apps/server-manager`에 둡니다.

```text
Codmes 저장소
├── server/                 공용 Workspace·LLM·Tool·MCP 서버
└── apps/
    ├── client/             Apple·Android·Windows 원본 코드와 Git 제외 builds/
    └── server-manager/     서버 시작·중지·설정·로그를 담당하는 데스크톱 앱
```

## 설치

일반 사용자는 [Codmes GitHub Releases](https://github.com/knu-uic/Codmes/releases)에서
운영체제에 맞는 설치 파일을 받습니다. 설치 패키지 안에 Server Manager native
binary, Codmes 서버, Node, portable Python, PostgreSQL 16, pgvector, pg_trgm,
production dependencies와 built-in plugin이 모두 포함되므로 별도
서버·Node·Python·PostgreSQL 설치는 필요하지 않습니다.
Codmes 서버는 Redis나 Java를 사용하지 않으므로 두 runtime은 포함하지 않습니다.

| OS | 배포 파일 | 실행 형태 |
| --- | --- | --- |
| macOS | DMG | 메뉴바 앱, 선택적 Dock icon |
| Ubuntu/Debian x64 | DEB | system tray 앱 |

macOS arm64 설치본은 실제 앱 설치, 내장 서버 health, PDF/DOCX 추출까지 검증했다.
Linux는 GitHub-hosted runner에서 native bundle, portable Python과 PostgreSQL을
만들고 검사한다. Windows Server Manager는 pgvector가 포함된 재배치 가능 PostgreSQL
런타임 빌더가 준비될 때까지 독립 실행형 Release 대상에서 제외한다.

## 제품 버전과 Release

Server Manager와 그 설치본에 포함된 서버는 `Codmes Server`라는 하나의 제품
버전을 사용합니다. 루트 `package.json`, Manager `package.json`, Tauri bundle과
Rust crate 버전이 모두 일치해야 `manager:check`가 통과합니다.

```text
codmes-server-v0.1.1
└── Codmes Server 0.1.1
    ├── Server Manager 0.1.1
    └── bundled Codmes server 0.1.1
```

`codmes-server-vX.Y.Z` 태그를 push하면 `server-manager-builds` workflow가 macOS와
Linux 설치본을 각각 만들고 같은 GitHub Release에 자동 첨부합니다. API,
Workspace schema, plugin manifest와 Distribution CLI처럼 독립 호환성이 필요한
계약 버전은 제품 버전과 별도로 유지합니다.

Release를 만들 때는 먼저 네 버전을 함께 올리고 검사한 뒤 같은 버전의 태그를
push합니다.

```bash
npm run manager:check
git tag -a codmes-server-v0.1.1 -m "Codmes Server 0.1.1"
git push origin codmes-server-v0.1.1
```

이미 존재하는 Release 태그는 다시 사용하지 않고 다음 patch/minor/major 버전으로
올립니다.

## 사용자 동작

- 앱을 열면 기본적으로 `127.0.0.1:8787`에서 서버를 시작합니다.
  시작 대기 화면에서 서버 연결을 자동 재확인하고 준비되면 로그인 화면으로
  이동합니다. 준비 중에는 일시적인 연결 오류를 표시하지 않으며, 1분 이상
  준비되지 않으면 오류 상세와 재시도 버튼을 표시합니다.
- macOS에서는 창을 닫아도 메뉴바에 남아 서버를 계속 실행합니다. Dock 아이콘은
  설정에서 선택적으로 표시할 수 있습니다.
- Windows와 Linux에서는 창을 닫아도 system tray에서 계속 실행합니다.
- 메뉴바·tray와 관리 창에서 서버를 시작하거나 중지할 수 있습니다.
- 로그인 시 Server Manager 자동 실행과 Manager 실행 시 서버 자동 시작을 각각
  설정할 수 있습니다.
- 관리 창에는 현재 주소, process ID, 자동 관리되는 데이터 경로와 최근 서버 로그가
  표시됩니다. 일반 사용자가 Workspace 폴더를 지정할 필요는 없습니다.
- 공식 배포 앱에는 Codmes가 등록한 Google 로그인 설정이 포함됩니다. 서버 운영자가
  Google Cloud 프로젝트나 OAuth 클라이언트 ID를 만들 필요가 없습니다. 첫 실행에서 Codmes ID·비밀번호로 최초 관리자와 기본 프로필을 만들며 Google은 선택적으로 연결합니다. Google로 가입할 때도 Codmes ID·비밀번호를 한 번 지정합니다. 이후 두 로그인 수단 중 하나를 사용할 수 있습니다. 기존 Google 사용자는 계정 UUID와 자료를 유지하며 ID·비밀번호를 한 번 설정합니다.
- `관리자 계정` 메뉴에서 로그아웃하거나 연동 Google 계정을 변경할 수 있습니다.
  Google 연결 변경·해제는 현재 Codmes 비밀번호로 확인합니다. 변경은 앱 내 확인 대화상자에서 새 계정 선택을 누른 뒤 Google 인증을
  완료해야 적용됩니다. 확인 창이나 인증을 취소하면 기존 계정을 유지하며,
  변경이 완료되면 새 Google 연결이 표시됩니다. Codmes 계정과 ID·비밀번호, 기기 승인은 유지되며 다른 로그인 세션만 종료됩니다. 프로필과 자료는 유지됩니다.
  Google 로그인은 시스템 브라우저에서 진행하며 콜백을 최대 10분 동안 기다립니다.
  브라우저를 닫았거나 중단하려면 Manager의 `로그인 취소`를 누르면 즉시 재시도할 수
  있습니다. 브라우저의 빈 사전 연결이나 나누어 전송된 요청 때문에 로그인 수신기를
  닫지 않습니다.
  `클라이언트 승인` 메뉴에서는 로그인 수단과 무관하게 기기를 수락·거절·삭제하고 승인 요청
  (`ask`) 또는 상시 허용 (`allow`) 모드를 고릅니다. 상시 허용은 서버에 닿는 모든
  신규 Codmes 계정과 새 기기를 자동 승인하므로 신뢰할 수 있는 네트워크에서만 사용합니다.
- `프로필 관리` 메뉴에서는 관리자 로그인 후 Codmes 계정별 프로필의 이름 변경과
  삭제·복구를 할 수 있습니다. 프로필은 승인된 계정마다 자동 생성됩니다. 앱 잠금
  PIN은 기기에만 저장하며 Manager에서는 조회하거나 초기화하지 않습니다.
- KNU Server Manager와 같은 사이드바·대시보드 구조를 사용합니다.
- Community plugin 패키지는 서버 데이터 저장소에 한 번 설치합니다. Server
  Manager의 `플러그인` 메뉴에서 공용 설치본을 설치·업데이트할 수 있고, 로그인된
  Codmes 클라이언트의 Marketplace에서는 어느 프로필이든 업데이트할 수 있습니다.
  `설정 → Plugins`의 사용 여부와 MCP 도구 승인·로그인 정보는 프로필별로
  관리합니다. Manager의 플러그인 메뉴는 로컬 관리자 로그인 후 사용합니다.

`Quit Codmes Server`로 앱을 완전히 종료하면 이 Manager가 시작한 서버 process도
함께 종료됩니다. 같은 주소에서 사용자가 직접 실행한 외부 서버는 감지하되 임의로
종료하지 않습니다.

Server Manager 앱이 서버 실행 파일과 Node runtime을 자체 포함하고 직접 서버
process를 관리합니다. 다만 Notes·대화·설정 같은 변경 가능한 사용자 데이터는 앱
번들 안에 저장하지 않습니다. 앱 업데이트나 삭제 시 데이터가 함께 사라지거나 쓰기
권한 문제가 생기지 않도록 macOS의 Application Support, Windows의 AppData,
Linux의 XDG data directory 아래 전용 Workspace를 자동으로 만들고 사용합니다.

## 재설치 후 기존 서버 / 새 서버 선택

계정이 없으면 최초 관리자 회원가입 화면을 표시합니다. 기존 데이터가 있으면
로그인 전에 두 선택지를 먼저 표시합니다.

- **기존 서버로 계속하기**: 연결된 Google 이메일 또는 Codmes ID를 마스킹해
  표시하고, 기존 ID·비밀번호 / 연결된 Google 계정으로 로그인합니다.
- **새 서버로 시작하기**: 새 Codmes ID·비밀번호를 지정하고 Google을 선택적으로
  연결합니다. 기존 관리자·클라이언트 계정, 프로필, 기기 승인, 서버 파일,
  PDF 필기, 대화, 플러그인 데이터·설정을 모두 초기화합니다. 계정만 바꾸거나
  기존 자료를 새 관리자에게 승계하는 기능이 아닙니다.

삭제 범위를 확인하고 `기존 서버 삭제`를 정확히 입력한 뒤 동의 체크박스를
선택해야 합니다. 이후 이 컴퓨터의 OS 관리자 확인을 통과해야 합니다. 비밀번호는
OS 대화상자에서 처리하고 Codmes에 보내지 않습니다. macOS는 시스템 관리자 인증,
Linux는 `pkexec`와 polkit 인증 에이전트, Windows는 UAC 승인/인증을 사용합니다.
이 기능을 사용할 수 없거나 취소하면 기존 서버를 유지합니다. 원격 HTTP 초기화
API는 제공하지 않습니다.

이 Manager가 실행한 서버와 전용 데이터 폴더만 초기화할 수 있습니다. 기본 앱
데이터 폴더는 기존 설치도 지원합니다. 사용자 지정 폴더는 Manager가 빈 폴더에
만든 소유권 표식이 필요하며, 기존 자료가 있는 임의 폴더나 심볼릭 링크 경로는
초기화를 차단하고 이유를 표시합니다.

Google 확인은 기존 서버를 변경하기 전에 진행합니다. 이후 서버와 PostgreSQL을
종료하고 기존 폴더를 같은 디스크의 임시 경로로 분리한 뒤 새 서버에 가입합니다.
가입 실패/취소 시 기존 폴더와 설정을 복원하며, 신규 가입이 확정되면 기존 폴더를
삭제합니다. 중단된 작업은 다음 앱 실행에서 복원하거나 완료된 초기화의 잔여 자료를
정리합니다. 실행 중인 외부 서버가 있으면 복구도 중단하고 자료를 변경하지 않습니다.
파일 정리 실패 시 경고와 작업 기록을 남겨 다음 실행에서 재시도합니다. 임시 폴더는
사용자용 백업으로 유지하지 않습니다.

다른 기기의 로컬 파일과 Google 계정 자체는 삭제하지 않습니다. 이전 서버 계정과
세션은 새 서버에서 사용할 수 없으므로 클라이언트는 새로 가입/승인받아야 합니다.
클라이언트 서버 이동용 내보내기·가져오기는 아직 구현하지 않았습니다. **서버에만
있는 자료를 직접 백업한 후 초기화하세요.** 앱 제거만으로 초기화되지는 않습니다.
자동 검증은 별도의 임시 서버·PostgreSQL과 테스트 계정으로만 진행합니다.

서버의 네트워크 공개/TLS 설정도 기본값으로 돌아갑니다. API/DB 포트와 Manager
창·자동 실행 설정만 유지하므로, 새 서버를 다른 기기에 공개하려면 네트워크와
인증서를 다시 설정하세요.

## 안전한 기본 설정

기본 listen 주소는 이 컴퓨터에서만 접속할 수 있는 `127.0.0.1`입니다. 로컬
네트워크 공개(`0.0.0.0`) 시에도 Codmes 계정 인증과 본인 프로필 자동 연결 흐름을 사용합니다.
ID·비밀번호와 Google 중 어느 로그인 수단이든 다른 기기에서 API에 연결하려면 신뢰 가능한 HTTPS 인증서를
설정해야 합니다. 인증서가 없으면 원격 로그인과 인증된 API 요청은 거절됩니다.
Server Manager는 계정 수에 따른 모드를 제공하지 않으며 PostgreSQL을 자동 관리합니다.
설정 파일은 Unix 계열 OS에서 현재 사용자만 읽을 수 있는 `0600` 권한으로 저장됩니다.

모바일이나 다른 PC에서 접속할 때는 Manager에서 Local network를 선택하고,
클라이언트 Connection에 서버 PC의 LAN/Tailscale 주소를 입력한 뒤 Codmes 계정으로 로그인합니다.
Google은 계정에 연결된 경우 선택할 수 있습니다. 기기가 승인되면 본인 프로필에 자동 연결됩니다. 같은 서버에서는 Codmes
계정당 하나의 프로필을 여러 기기에서 공유하고 다른 계정의 자료는 열 수 없습니다.
`설정 → Profile`에서 선택적 앱 잠금을 설정·변경·해제할 수 있으며 이 PIN은 해당
기기에만 적용됩니다. 프로필 삭제·복구는 Server Manager의 프로필 관리에서 수행하고
자료는 서버에 보관합니다. 과거 공유 프로필 자료를 다른 계정에 임의로 넘기지 않습니다.

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

화면 원본은 `src/`, OS 실행 원본은 `src-tauri/`이다. 생성 파일은 `builds/frontend/`,
`builds/runtime/`, `builds/rust/`, `builds/tools/`, `builds/native-runtime/`로 구분한다.
예전 바깥의 `dist/`, `runtime/`, `.tools/`와 `src-tauri/target/`는 사용하지 않는다.
앱 자체의 `.gitignore`는 `builds/`를 제외하고 원본은 포함한다.
Rust의 `lib.rs`·`manager.rs`·`google_oauth.rs`는 공통 로직이며 OS 전용 처리는
`src-tauri/src/platform/` 아래 `macos.rs`·`linux.rs`·`windows.rs`로 분리한다.
Unix 공용 종료 신호와 설정 파일 권한은 `unix.rs`가 담당한다. 구조와 역할은
[앱 README](../../apps/server-manager/README.md)에 정리되어 있다.
Rust 출력 설정은 `.cargo/config.toml`에 있으므로 직접 Cargo를 실행할 때도
`apps/server-manager` 또는 그 하위 `src-tauri`를 작업 디렉터리로 사용한다.

```bash
npm run manager:check
bash apps/server-manager/scripts/build-postgres-runtime.sh
export CODMES_MANAGER_POSTGRES_ROOT="$PWD/apps/server-manager/builds/native-runtime/$(uname -s | tr '[:upper:]' '[:lower:]')-$(uname -m)/postgres"
npm run manager:build
```

`manager:build`는 먼저 `apps/server-manager/builds/runtime`에 다음 항목을 준비한 뒤 현재
OS의 설치 패키지를 생성합니다.

- 현재 OS용 Node 실행 파일
- Codmes server·CLI·built-in plugin·vendor 코드
- production Node dependencies
- PDF/Office 본문 추출용 OS·CPU별 portable Python 3.11 runtime과 dependencies
- PostgreSQL 16, pgvector와 pg_trgm이 포함된 재배치 가능 데이터베이스 runtime

Node와 PostgreSQL 실행 파일은 OS와 CPU architecture가 다르면 호환되지 않으므로
macOS와 Linux 패키지는 각 OS의 CI runner에서 따로 만듭니다. GitHub Actions의
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
