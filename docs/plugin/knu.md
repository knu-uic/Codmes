# KNU plugin

KNU는 Codmes의 선택형 plugin PoC다. 한 번 설치하면 다음 두 기능이 함께 등록된다.

- **KNU Surface**: 공지, LMS, 포털, 설정을 Codmes의 macOS/iOS native UI로 표시
- **KNU MCP**: AI가 공주대 공지를 검색하고 상세 근거를 읽는 도구

0.3.2부터 package의 `tools.json`이 Scan, Deep, 원문 조회 도구의 이름·입력
schema·승인 정책을 선언한다. 실제 검색과 상세 조회는 계속 KNU MCP 서버가 실행하며
Codmes Tool Registry가 선언과 MCP `tools/list` 결과를 연결한다.

KNU 웹사이트를 WebView나 iframe으로 여는 구조가 아니다. KNU 서버는 공지·포털·LMS
도메인 데이터만 JSON으로 제공하고, KNU plugin package의 `surface.json`이 화면
구조와 데이터 바인딩을 소유한다. Codmes 서버가 둘을 검증·결합한 뒤 Apple
클라이언트가 SwiftUI로 렌더링한다.

## 바로 실행하기

아래 명령은 각 서버 컴퓨터에서 다음 조건이 충족된 상태를 기준으로 한다.

- **KNU 서버 컴퓨터**: `knu-ai-assistant` 저장소, Python 가상환경,
  `services/api/.env`, PostgreSQL과 KNU DB가 준비되어 있다.
- **Codmes 서버 컴퓨터**: Codmes CLI, `CodmesWorkspace`, KNU plugin과 MCP
  credential이 설치되어 있다.
- 두 서버를 같은 컴퓨터에서 실행한다면 KNU plugin의 기본 주소인
  `http://127.0.0.1:8000`을 그대로 사용할 수 있다.
- 서로 다른 컴퓨터에서 실행한다면 plugin의 KNU API/MCP 주소를 KNU 서버의 실제
  HTTPS 주소로 설정한 뒤 plugin을 다시 설치해야 한다.

조건이 충족되어 있다면 각 서버에서 다음 명령만 실행하면 된다.

### 터미널 1: KNU 서버

```sh
cd "$HOME/Desktop/knu-ai-assistant/services/api"
source ../../.venv/bin/activate
python -m uvicorn api.main:app --host 127.0.0.1 --port 8000
```

`Uvicorn running on http://127.0.0.1:8000`이 나오면 성공

### 터미널 2: Codmes 서버

```sh
CODMES_WORKSPACE_ROOT="$HOME/CodmesWorkspace" \
CODMES_HOST="0.0.0.0" \
CODMES_PORT="8787" \
codmes serve
```

`[codmes] listening on http://0.0.0.0:8787`이 나오면 성공

## 앱에 KNU가 처음 보이지 않을 때

일반 사용자는 Codmes 앱에서 `Settings > Plugins > KNU > Install`만 누르면 된다.
같은 작업을 터미널에서 하려면 다음 명령을 실행한다.

```sh
cd "$HOME/Desktop/Codmes"
node bin/codmes.mjs plugin install kr.ac.kongju.knu \
  --root "$HOME/CodmesWorkspace"
```

KNU plugin 자체를 개발하며 `plugin.json`, `surface.json`의 아직 package되지 않은
변경을 시험할 때만 로컬 source 경로를 설치한다.

```sh
cd "$HOME/Desktop/Codmes"
node bin/codmes.mjs plugin install \
  "$HOME/Desktop/codmes-plugin-knu" \
  --root "$HOME/CodmesWorkspace"
```

설치 확인:

```sh
codmes plugin list --root "$HOME/CodmesWorkspace"
```

## 새 Mac에서 최초 개발환경 구축

아래 내용은 새 컴퓨터에 KNU 개발환경을 처음 만들 때만 필요하다. 일반 사용자와
이미 설정을 끝낸 개발자는 읽거나 실행할 필요가 없다. 명령은 macOS `zsh` 기준이다.

### 0. 필요한 프로그램 확인

필요한 프로그램:

- Node.js 22 이상
- Python 3.12
- PostgreSQL 16과 pgvector
- Redis 7
- Xcode

터미널에서 설치 여부를 확인한다.

```sh
node --version
python3.12 --version
psql --version
redis-server --version
xcode-select -p
```

Homebrew가 있다면 PostgreSQL, pgvector와 Redis는 다음 명령으로 설치할 수 있다.

```sh
brew install postgresql@16 pgvector redis
export PATH="$(brew --prefix postgresql@16)/bin:$PATH"
```

Docker는 필수가 아니다. 이 문서는 KNU API와 PostgreSQL을 모두 Mac에서 직접
실행하는 방식을 기본으로 설명한다.

### 1. 저장소 위치 지정

새 터미널을 열고 두 저장소와 Codmes Workspace 위치를 지정한다. 다른 경로에
저장소를 두었다면 아래 세 줄만 자신의 경로에 맞게 바꾼다.

```sh
export CODMES_REPO="$HOME/Desktop/Codmes"
export KNU_REPO="$HOME/Desktop/knu-ai-assistant"
export KNU_PLUGIN_REPO="$HOME/Desktop/codmes-plugin-knu"
export CODMES_WORKSPACE="$HOME/CodmesWorkspace"

test -d "$CODMES_REPO" && echo "Codmes 저장소 확인"
test -d "$KNU_REPO" && echo "KNU 저장소 확인"
test -d "$KNU_PLUGIN_REPO" && echo "KNU plugin 저장소 확인"
mkdir -p "$CODMES_WORKSPACE"
```

이 환경변수는 현재 터미널에만 유지된다. 터미널을 새로 열면 같은 세 줄을 다시
실행하거나 문서의 명령에 실제 경로를 직접 넣는다.

## 최초 한 번만 하는 설정

이미 아래 설정을 완료했다면 [평소 실행 방법](#평소-실행-방법)으로 건너뛴다.

### 2. Codmes 의존성 설치

```sh
cd "$CODMES_REPO"
npm install
```

### 3. KNU Python 환경 설치

```sh
cd "$KNU_REPO"
python3.12 -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip
python -m pip install -r services/api/requirements-api.txt
python -m playwright install chromium
```

### 4. KNU 로컬 환경설정 생성

다음 명령은 로컬 PostgreSQL 주소와 세 개의 무작위 보안 키를 `services/api/.env`에
넣는다.

```sh
cd "$KNU_REPO/services/api"
cp .env.example .env

export KNU_LOCAL_JWT_SECRET="$(python -c 'import secrets; print(secrets.token_hex(32))')"
export KNU_LOCAL_PORTAL_KEY="$(python -c 'from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())')"
export KNU_LOCAL_MCP_TOKEN="$(python -c 'import secrets; print(secrets.token_urlsafe(32))')"

/usr/bin/sed -i '' \
  -e "s|^# DATABASE_URL=.*|DATABASE_URL=postgresql://$(whoami)@127.0.0.1:5432/codmes_knu_dev|" \
  -e "s|^AUTH_JWT_SECRET=.*|AUTH_JWT_SECRET=$KNU_LOCAL_JWT_SECRET|" \
  -e "s|^PORTAL_SYNC_ENC_KEY=.*|PORTAL_SYNC_ENC_KEY=$KNU_LOCAL_PORTAL_KEY|" \
  -e "s|^MCP_AUTH_TOKEN=.*|MCP_AUTH_TOKEN=$KNU_LOCAL_MCP_TOKEN|" \
  .env
```

값이 들어갔는지만 확인한다. 실제 키는 터미널에 출력하지 않는다.

```sh
grep -E '^(RUNTIME_ENV|DATABASE_URL|EMBEDDING_DIM)=' .env
grep -Eq '^MCP_AUTH_TOKEN=.+$' .env && echo "MCP 토큰 설정 완료"
grep -Eq '^PORTAL_SYNC_ENC_KEY=.+$' .env && echo "포털 암호화 키 설정 완료"
```

`.env`는 Git에 커밋하지 않는다.

### 5. 로컬 PostgreSQL 실행 및 테이블 생성

PostgreSQL을 macOS background service로 실행한다.

```sh
export PATH="$(brew --prefix postgresql@16)/bin:$PATH"
brew services start postgresql@16
pg_isready -h 127.0.0.1 -p 5432
```

`accepting connections`가 나오면 KNU용 DB를 만든다. 이미 존재한다고 나오면
그대로 다음 단계로 진행한다.

```sh
createdb codmes_knu_dev
```

KNU DB의 최초 migration과 pgvector 테이블을 생성한다.

```sh
cd "$KNU_REPO/services/api"
source ../../.venv/bin/activate
python -c "from db.schema import init_db; init_db()"
```

이 명령은 기존 데이터는 지우지 않고 필요한 migration과 pgvector 테이블만
준비한다.

### 6. KNU plugin 설치

```sh
cd "$CODMES_REPO"
node bin/codmes.mjs plugin install \
  "$KNU_PLUGIN_REPO" \
  --root "$CODMES_WORKSPACE"
```

`KNU 0.3.2`가 표시되는지 확인한다. 설치 후 KNU 설정에서 포털 계정으로 로그인하면
발급된 사용자 session token을 Surface와 MCP가 함께 사용한다. 일반 사용자는
`MCP_AUTH_TOKEN`을 직접 등록하지 않는다.

```sh
node bin/codmes.mjs plugin list --root "$CODMES_WORKSPACE"
```

설치 명령은 `plugin.json`과 `surface.json`을 검증하고 KNU Surface와 MCP를 한
단위로 등록한다. `codmes-plugin-knu` 저장소의 `plugin.json`이나 `surface.json`을
수정했을 때도
같은 설치 명령을 다시 실행해야 변경 내용이 Workspace에 반영된다.

## 개발환경 실행 명령 설명

앱을 사용할 때는 터미널 두 개와 Xcode를 실행한다.

### 터미널 1: KNU DB와 KNU 서버

```sh
export KNU_REPO="$HOME/Desktop/knu-ai-assistant"

cd "$KNU_REPO/services/api"
export PATH="$(brew --prefix postgresql@16)/bin:$PATH"
brew services start postgresql@16
brew services start redis
source ../../.venv/bin/activate
python -m uvicorn api.main:app --host 127.0.0.1 --port 8000
```

다음 문구가 나오면 KNU API와 KNU MCP가 실행된 것이다.

```text
Uvicorn running on http://127.0.0.1:8000
```

이 터미널은 끄지 않는다. 별도 터미널에서 상태를 확인할 수 있다.

```sh
curl http://127.0.0.1:8000/api/health
```

### 터미널 2: Codmes Workspace 서버

```sh
export CODMES_REPO="$HOME/Desktop/Codmes"
export CODMES_WORKSPACE="$HOME/CodmesWorkspace"

cd "$CODMES_REPO"
node bin/codmes.mjs serve --root "$CODMES_WORKSPACE"
```

다음 문구가 나오면 Codmes 서버가 실행된 것이다.

```text
[codmes] listening on http://127.0.0.1:8787
```

이 터미널도 끄지 않는다. 별도 터미널에서 설치된 plugin을 확인할 수 있다.

```sh
curl http://127.0.0.1:8787/api/plugins
```

### Xcode: macOS 앱 실행

```sh
open "$CODMES_REPO/client/apple/Codmes.xcodeproj"
```

Xcode 상단에서 scheme을 고른 뒤 실행한다.

- macOS: `Codmes`
- iPhone/iPad Simulator: `Codmes iOS`

Codmes 앱의 `Settings → Connection`에서 다음 값을 확인한다.

```text
Server URL: http://127.0.0.1:8787
```

별도로 `CODMES_SERVER_TOKEN`을 설정하지 않았다면 Server Token은 비워 둔다.

### 앱에서 KNU 로그인

1. 최상단 Surface 메뉴에서 `KNU`를 선택한다.
2. KNU sidebar 상단의 `로그인`을 누른다.
3. 열린 `Settings → Surfaces → KNU` 화면에 공주대 포털 학번과 비밀번호를
   입력한다.
4. `연결`을 누르고 포털 인증과 LMS 동기화가 끝날 때까지 기다린다.
5. 설정 화면을 닫아도 동기화는 계속된다.
6. KNU의 `포털`에서 학적·시간표·성적을, `LMS`에서 과제와 학습 일정을 확인한다.

비밀번호는 인증과 최초 동기화 중에만 KNU 서버 메모리에서 사용하고 저장하지
않는다. Codmes 서버에는 KNU가 발급한 사용자 session token만 저장된다.

## 실제 iPhone/iPad에서 실행

Simulator가 아니라 실제 기기를 사용하면 기기에서 Mac의 `127.0.0.1`로 접속할 수
없다. Codmes 서버만 LAN에 공개한다.

Mac의 IP를 확인한다.

```sh
ipconfig getifaddr en0
```

Codmes 서버를 다음처럼 실행한다.

```sh
cd "$CODMES_REPO"
node bin/codmes.mjs serve \
  --host 0.0.0.0 \
  --root "$CODMES_WORKSPACE"
```

iPhone/iPad의 `Settings → Connection`에는 다음처럼 Mac의 IP를 입력한다.

```text
http://192.168.x.x:8787
```

Mac과 iPhone/iPad는 같은 Wi-Fi에 있어야 한다. KNU plugin의
`upstreamUrl=http://127.0.0.1:8000`은 바꾸지 않는다. Apple 기기가 아니라 Mac에서
실행되는 Codmes 서버가 KNU 서버에 접속하기 때문이다.

## 종료 방법

KNU 서버와 Codmes 서버가 실행 중인 각 터미널에서 `Control-C`를 누른다.
PostgreSQL은 다음 부팅 뒤에도 자동 실행된다. PostgreSQL까지 중지하려면 다음
명령을 실행한다.

```sh
brew services stop postgresql@16
```

이 명령은 DB 데이터를 삭제하지 않는다.

## 자주 발생하는 문제

### 앱에 KNU가 보이지 않음

설치 상태와 두 서버를 차례로 확인한다.

```sh
cd "$CODMES_REPO"
node bin/codmes.mjs plugin list --root "$CODMES_WORKSPACE"
curl http://127.0.0.1:8000/api/health
curl http://127.0.0.1:8787/api/plugins
```

plugin 소스를 수정했다면 [7. KNU plugin 설치](#7-knu-plugin-설치)를 다시 실행한다.

### KNU 페이지를 열 수 없음

터미널 1에 `Uvicorn running on http://127.0.0.1:8000`, 터미널 2에
`[codmes] listening on http://127.0.0.1:8787`이 모두 표시되어 있어야 한다.
앱의 Connection URL도 `http://127.0.0.1:8787`인지 확인한다.

### DB 연결 오류

```sh
export PATH="$(brew --prefix postgresql@16)/bin:$PATH"
brew services list | grep postgresql
pg_isready -h 127.0.0.1 -p 5432
psql -d codmes_knu_dev -c "SELECT extname FROM pg_extension WHERE extname = 'vector';"
```

다른 포트나 DB를 사용한다면 `services/api/.env`의 `DATABASE_URL`을 실제 주소와
일치시킨다.

예를 들어 기존 개발 DB가 `55432` 포트에 있고 vector 차원이 `768`이라면 다음처럼
바꾼다. 기존 DB의 vector 차원과 `EMBEDDING_DIM`은 반드시 같아야 한다.

```sh
cd "$KNU_REPO/services/api"
/usr/bin/sed -i '' \
  -e "s|^DATABASE_URL=.*|DATABASE_URL=postgresql://$(whoami)@127.0.0.1:55432/codmes_knu_dev|" \
  -e "s|^EMBEDDING_DIM=.*|EMBEDDING_DIM=768|" \
  .env
```

### `Workspace server rejected the request`

Codmes 서버를 `CODMES_SERVER_TOKEN` 없이 실행했다면 앱의 Server Token도 비워
둔다. 토큰을 설정해 서버를 실행했다면 앱에도 정확히 같은 값을 입력한다.

### 로그인은 됐지만 포털/LMS가 비어 있음

KNU 서버가 로그인 뒤 background 동기화를 진행한다. KNU sidebar의 동기화 상태와
터미널 1의 로그를 먼저 확인한다. LMS만 실패하면 포털 연결은 유지되며 설정 화면에
LMS 오류가 따로 표시된다.

### AI가 KNU 공지를 참고하지 않음

KNU 화면 표시와 포털 로그인에는 LLM이 필요하지 않다. AI의 KNU 공지 검색은
KNU PostgreSQL에 수집·인덱싱된 공지와 KNU 서버의 embedding/reranker 설정이
추가로 필요하다. 또한 KNU MCP는 현재 KNU Surface에서만 노출되고 호출 전 사용자
승인을 요구한다.

## 선택: Docker로 DB 실행

로컬 PostgreSQL 대신 Docker를 선호할 때만 사용한다. `services/api/.env`의
`DB_PASSWORD`를 먼저 실제 값으로 바꾸고, `DATABASE_URL`은 Docker가 Mac에 공개한
포트와 같은 주소를 가리키게 설정한다.

```sh
cd "$KNU_REPO/services/api"
docker compose up -d db
docker compose ps db
```

이 방식을 사용하면 위의 Homebrew PostgreSQL service는 실행하지 않는다.

## 선택: 공지 수집 worker 실행

포털/LMS 로그인 직후 동기화는 KNU API가 직접 수행하므로 Redis worker가 없어도
된다. 공지 주기 수집까지 실행하려면 별도 터미널에서 다음을 실행한다.

```sh
export KNU_REPO="$HOME/Desktop/knu-ai-assistant"
cd "$KNU_REPO/services/api"
source ../../.venv/bin/activate
arq workers.arq_worker.WorkerSettings
```

worker와 사용자 session 인증에는 `services/api/.env`의 `REDIS_URL`에 연결 가능한
Redis가 필요하다. 개발 환경에서도 포털 로그인 전에 Redis를 실행한다.

비밀번호가 틀리면 사용자 session token을 저장하지 않는다. LMS만 실패하면 포털 연결은
유지하며 설정 화면에 LMS 실패 원인을 따로 표시한다. 비밀번호는 저장하지 않으므로
LMS 재인증이 필요한 경우 사용자가 다시 연결해야 한다.

## 구체적인 동작 예시

### 예시 1: 사용자가 포털 로그인

```text
Apple 앱
  → Codmes 서버 POST /api/plugins/kr.ac.kongju.knu/auth/login
  → KNU 서버 POST /api/auth/portal-login
  → 공주대 포털 SSO 검증
  ← KNU 사용자 session token 발급
  ← Codmes 서버가 token을 Surface·MCP 공용 credential로 저장

KNU 서버 background task
  → 검증된 임시 포털 browser session으로 KNUIS 조회
  → 같은 요청에서 받은 비밀번호로 임시 LMS session 생성
  → 학적/시간표/성적/과목/과제 등을 KNU PostgreSQL에 저장
  → 비밀번호와 임시 browser session 폐기
```

로그아웃하면 Codmes 서버가 KNU `/api/auth/logout`을 먼저 호출해 현재 session을
폐기하고, Workspace의 Surface·MCP credential 복사본을 함께 삭제한다. 같은 학번의
다른 기기 session은 유지된다.

Apple 앱에는 KNU JWT, 포털 cookie, MCP 토큰 또는 비밀번호가 전달되지 않는다.

### 예시 2: 포털 화면 열기

```text
Apple 앱
  → Codmes 서버에 KNU portal route 요청
  → Codmes 서버가 설치된 surface.json에서 portal binding을 선택
  → 저장한 KNU JWT를 Authorization 헤더에 추가
  → KNU 서버 GET /api/codmes/data/portal
  ← 학적·시간표·성적 domain JSON
  → Codmes 서버가 binding을 적용해 declarative dashboard document 생성
  → 생성 결과의 schema/크기/action 검증
  ← Apple 앱이 SwiftUI table/key-value UI로 렌더링
```

KNU 서버는 `presentation`, `sections`, `systemImage` 같은 UI 정보를 알지 못한다.
Codmes 서버도 KNU의 HTML을 전달하지 않고, 설치된 plugin UI 규약으로 만든 허용된
JSON 문서만 Apple 앱에 전달한다.

### 예시 3: AI에게 “이번 학기 장학금 신청 공지 찾아줘”

KNU Surface가 선택된 대화에서 다음 흐름이 일어난다.

```text
사용자 질문
  → Codmes AI runtime이 KNU MCP tool schema를 model에 제공
  → model이 질문 의미에 따라 knu_list_notices 또는 knu_search_notice_details 결정
  → Codmes approval inbox에서 사용자 승인
  → Codmes 서버가 포털 로그인 session token을 Bearer로 붙여 KNU /api/mcp 호출
  → KNU MCP가 구조화 필터 또는 공지 DB 검색·rerank 수행
  ← 제목, 날짜, 본문 근거, 원문 URL
  → model이 반환된 근거만 사용해 답변하고 URL을 인용
```

사용자 session token은 model prompt, tool argument, approval 기록과 결과에
포함되지 않는다. KNU 서버는 token의 학번을 기준으로 사용자별 호출 한도를 적용한다.
현재 manifest는 MCP 도구 범위를 `knu` Surface로 제한하므로 일반
Chat/Notes/Code Surface에서는 KNU 도구가 노출되지 않는다.

## 구성 요소별 담당과 저장 위치

| 구성 요소 | 담당 | 저장하는 정보 | 저장 위치 |
|---|---|---|---|
| Apple 클라이언트 | native Surface 표시, 로그인 입력, 상태 polling, AI 대화 UI | 비밀번호·KNU JWT·MCP 토큰을 저장하지 않음 | 화면 상태와 일반 앱 상태만 |
| KNU plugin package | Surface 내비게이션, 제목, 필터, native component와 data binding 정의 | 비밀정보 없음 | 별도 `knu-uic/codmes-plugin-knu` 저장소; 설치 시 Workspace manifest에 포함 |
| Codmes 서버 | plugin 설치, raw data 요청, Surface document 조립·검증, AI runtime, MCP 승인·호출 | KNU 사용자 session token, 설치된 plugin/UI manifest | Codmes Workspace의 `.codmes/config/auth.json`, `.codmes/plugins/` |
| KNU FastAPI 서버 | 포털 로그인 검증, session token 발급·폐기, domain data API, 동기화 시작 | 활성 session id, 실행 중 비밀번호와 임시 browser session | session은 Redis AOF, 비밀번호는 동기화 전달 후 폐기 |
| KNU PostgreSQL | KNU 서비스의 영속 데이터 저장 | 공지, 학적, 시간표, 성적, LMS 과목·과제·공지·강의 | KNU 서버가 사용하는 PostgreSQL |
| KNU MCP 서버 | AI용 공지 검색·상세 근거 제공 | 별도 사용자 비밀번호를 저장하지 않음 | KNU FastAPI 안에서 공지 DB를 조회 |
| 공주대 포털/LMS | 실제 학교 계정 인증과 원천 데이터 제공 | 학교 시스템 정책에 따름 | Codmes 관리 범위 밖 |

KNU FastAPI와 KNU MCP는 현재 같은 프로세스와 포트 `8000`을 사용하지만 역할은
다르다. 일반 API는 plugin UI가 표시할 domain data를 제공하고 MCP는 AI가 사용할
구조화된 도구를 제공한다. 어느 API도 Codmes 화면 배치를 결정하지 않는다.

## MCP 동작 범위와 한계

현재 제공 도구:

- `knu_list_notices`: 상태·기간·대상·카테고리로 공지 목록과 개수를 조회
- `knu_search_notice_details`: 구체적인 날짜·자격·절차·첨부 근거를 검색
- `knu_get_notice_detail`: 검색 결과로 받은 URL의 전체 공지 본문 조회

AI가 질문할 때 무조건 MCP를 호출하는 것은 아니다. Codmes는 KNU Surface에서만
도구 schema를 model에 제공하고, 실제 호출 여부와 인자는 model이 질문 내용에 따라
결정한다. 호출에는 기본적으로 사용자 승인이 필요하다. KNU MCP는 상위 AI가 정한
검색어와 category를 바로 검색하며 내부에서 별도의 LLM을 다시 호출하지 않는다.

### 질문 판단과 MCP 인자 예시

`지금 신청 가능한 장학금 몇 개 있어?`처럼 넓은 목록·집계 질문은 Codmes AI가
Scan 도구를 선택한다.

```json
{
  "name": "knu_list_notices",
  "arguments": {
    "category": "장학",
    "status": "open",
    "time_scope": "current"
  }
}
```

`2026학년도 2학기 수강신청 일정과 절차 알려줘`처럼 특정 사실을 자세히 찾아야
하는 질문은 Deep 도구를 선택한다.

```json
{
  "name": "knu_search_notice_details",
  "arguments": {
    "query": "2026학년도 2학기 수강신청 일정과 절차",
    "category": "수강",
    "year": 2026
  }
}
```

필요하면 모델은 먼저 Scan으로 후보 `notice_ids`를 좁힌 뒤 같은 ID를 Deep 도구에
전달하는 Hybrid 흐름을 사용할 수 있다. 도구 선택은 키워드 규칙이 아니라 대화
모델의 tool calling 판단이다.

```text
Codmes AI
├─ MCP 호출 필요 여부 판단
├─ Scan / Deep / Hybrid 선택
├─ 상태·기간·대상 또는 상세 검색어 결정
└─ 사용자 승인 후 도구 호출

KNU MCP
├─ Scan: SQL 메타데이터 필터·정렬·총 개수 계산
├─ Deep: 필터 적용 후 pgvector 후보 검색과 reranking
├─ 과거 24개월 밖 공지: 본문 없이 메타데이터만 Scan 제공
└─ 제목, 날짜, 본문 근거와 원문 URL 반환
```

KNU MCP는 질문을 다시 LLM으로 분류하지 않는다. 카테고리·상태·연도 같은 인자는
Codmes AI가 정하고, KNU 서버는 그 구조화 인자를 그대로 검증·실행한다. 독립형 KNU
웹 챗봇의 대화 경로는 MCP와 별개다.

답변 품질은 KNU PostgreSQL에 수집·인덱싱된 공지와 검색/rerank 결과에 의존한다.
데이터가 없거나 근거가 부족하면 MCP는 `no_results`를 반환하며 AI는 추측하지 않고
정보가 부족하다고 답해야 한다.

## 제거

```sh
export CODMES_REPO="$HOME/Desktop/Codmes"
export CODMES_WORKSPACE="$HOME/CodmesWorkspace"

cd "$CODMES_REPO"
node bin/codmes.mjs plugin remove kr.ac.kongju.knu \
  --root "$CODMES_WORKSPACE"
```

plugin 제거는 Codmes의 Surface와 MCP 등록을 제거한다. KNU PostgreSQL 데이터나
KNU 서버 자체는 삭제하지 않는다.
