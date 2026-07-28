# KNU plugin

KNU는 Codmes의 선택형 plugin PoC다. 한 번 설치하면 다음 두 기능이 함께 등록된다.

- **KNU Surface**: 공지, LMS, 포털, 설정을 Codmes의 macOS/iOS native UI로 표시
- **KNU MCP**: AI가 공주대 공지를 검색하고 상세 근거를 읽는 도구

KNU 웹사이트를 WebView나 iframe으로 여는 구조가 아니다. KNU 서버가 JSON 데이터와
화면 구조를 제공하고 Codmes 클라이언트가 SwiftUI로 렌더링한다.

## 저장소와 전제 조건

예시는 두 저장소가 나란히 있다고 가정한다.

```text
/path/to/Codmes
/path/to/knu-ai-assistant
```

필요한 런타임:

- Node.js 22 이상
- Python 3.12와 Playwright Chromium
- PostgreSQL + pgvector
- 필수: Redis와 ARQ worker (포털/LMS 로그인·동기화)

포털 로그인과 LMS 동기화는 Redis 큐와 ARQ worker가 처리한다. API 프로세스만
실행하면 로그인 job이 완료되지 않는다.

## Codmes에 설치하는 방법

### 1. 공용 MCP 토큰 준비

KNU 서버와 Codmes 서버가 공유할 내부용 토큰을 한 번 생성한다.

```sh
python3 -c "import secrets; print(secrets.token_urlsafe(32))"
```

출력값을 KNU 저장소의 `SERVER/.env`에 넣는다.

```dotenv
MCP_AUTH_TOKEN=생성한_토큰
```

같은 값을 Codmes Workspace의 서버 전용 credential store에 등록한다.

```sh
cd /path/to/Codmes
printf '%s' "$MCP_AUTH_TOKEN" \
  | node bin/codmes.mjs mcp credential set knu \
      --root /path/to/CodmesWorkspace
```

토큰은 plugin manifest에 기록되지 않는다. KNU 서버는 환경변수로 보관하고 Codmes
서버는 `/path/to/CodmesWorkspace/.codmes/config/auth.json`에 권한 `0600`으로
보관한다.

### 2. plugin package 설치

KNU 저장소의 `CODMES_PLUGIN` 디렉터리를 설치한다.

```sh
cd /path/to/Codmes
node bin/codmes.mjs plugin install \
  /path/to/knu-ai-assistant/CODMES_PLUGIN \
  --root /path/to/CodmesWorkspace
```

설치 확인:

```sh
node bin/codmes.mjs plugin list --root /path/to/CodmesWorkspace
```

설치는 검증된 manifest를
`/path/to/CodmesWorkspace/.codmes/plugins/kr.ac.kongju.knu/plugin.json`에
복사하고, KNU Surface와 MCP 설정을 함께 등록한다. 중간에 실패하면 두 설정 모두
설치 전 상태로 되돌린다.

## 실행 방법

### 1. KNU 서버 준비

최초 한 번:

```sh
cd /path/to/knu-ai-assistant
python3 -m venv .venv
source .venv/bin/activate
pip install -r SERVER/requirements-api.txt
python -m playwright install chromium

cd SERVER
cp .env.example .env
```

`SERVER/.env`의 최소 필수값을 채운다.

```dotenv
RUNTIME_ENV=local
DATABASE_URL=postgresql://사용자:비밀번호@127.0.0.1:5432/데이터베이스
EMBEDDING_DIM=1536
AUTH_JWT_SECRET=32자_이상의_무작위_문자열
PORTAL_SYNC_ENC_KEY=Fernet으로_생성한_키
MCP_AUTH_TOKEN=Codmes에_등록한_것과_같은_토큰
VLM_PROVIDER=local
LLM_MODEL=LM_Studio에_로드한_대화_모델
EMBEDDING_PROVIDER=local
EMBEDDING_MODEL=DB_인덱싱에_사용한_임베딩_모델
RERANKER_PROVIDER=local
```

키 생성 예시:

```sh
python -c "import secrets; print(secrets.token_hex(32))"
python -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"
```

PostgreSQL을 compose로 실행하려면:

```sh
cd /path/to/knu-ai-assistant/SERVER
docker compose up -d db
```

KNU API와 MCP 서버는 같은 FastAPI 프로세스에서 실행된다.

```sh
cd /path/to/knu-ai-assistant/SERVER
source ../.venv/bin/activate
python -m uvicorn api.main:app --host 127.0.0.1 --port 8000
```

확인:

```sh
curl http://127.0.0.1:8000/api/health
```

Redis와 ARQ worker 실행 (포털 로그인/LMS 동기화에 필수):

```sh
docker compose up -d redis
source ../.venv/bin/activate
arq workers.arq_worker.WorkerSettings
```

### 2. Codmes 서버 실행

```sh
cd /path/to/Codmes
npm install
CODMES_WORKSPACE_ROOT=/path/to/CodmesWorkspace npm start
```

기본 주소는 `http://127.0.0.1:8787`이다. Apple 앱의 Connection 설정도 이
Workspace 서버를 가리켜야 한다.

### 3. Apple 앱 실행

Xcode에서 `client/apple/Codmes.xcodeproj`를 열고 다음 scheme 중 하나를 실행한다.

- `Codmes`: macOS
- `Codmes iOS`: iPhone/iPad Simulator 또는 실제 기기

macOS와 가로 iPad는 KNU 섹션을 왼쪽 sidebar에 상시 표시한다. iPhone은 항목을
선택해 계층형 native 화면으로 들어간다.

실제 iPhone/iPad에서 KNU 서버와 Codmes 서버가 Mac에서 실행 중이라면 manifest의
`127.0.0.1`은 기기 자신을 의미한다. 이 경우 개발용 LAN 주소 또는 HTTPS 개발
gateway를 사용하도록 plugin manifest의 upstream/MCP URL을 바꿔 설치해야 한다.

## 적용 방법

1. Codmes를 실행하고 Surface 선택 메뉴에서 `KNU`를 선택한다.
2. KNU sidebar 상단의 `로그인`을 누른다.
3. `Settings → Surfaces → KNU` 상세에서 공주대 포털 학번과 비밀번호를 입력한다.
4. KNU 서버가 포털 SSO를 검증하면 Codmes 서버가 KNU 사용자 JWT만 저장한다.
5. KNU 서버 background task가 포털과 LMS를 순서대로 동기화한다.
6. 설정 화면을 닫아도 동기화는 계속된다. sidebar에는 로그인한 계정명과 작은
   진행 indicator가 표시된다.
7. 완료 후 `포털`에서 학적·시간표·성적 정보를, `LMS`에서 과제·공지·남은 강의를
   확인한다.

비밀번호가 틀리면 사용자 JWT를 저장하지 않는다. LMS만 실패하면 포털 연결은
유지하며 설정 화면에 LMS 실패 원인을 따로 표시한다. 비밀번호는 저장하지 않으므로
LMS 재인증이 필요한 경우 사용자가 다시 연결해야 한다.

## 구체적인 동작 예시

### 예시 1: 사용자가 포털 로그인

```text
Apple 앱
  → Codmes 서버 POST /api/plugins/kr.ac.kongju.knu/auth/login
  → KNU 서버 POST /api/auth/portal-login {student_id,password}
  ← {job_id} (202)
  → KNU 서버 POST /api/auth/portal-login/status {job_id} (queued/running 반복)
  ← {status:"done",access_token,token_type:"bearer"}
  ← Codmes 서버가 JWT를 로컬 credential store에 저장
  → KNU 서버 POST /api/lms/sync/start (Bearer JWT, {student_id,password})
  ← 202 (enqueue; 완료 대기 안 함)

Redis + ARQ worker
  → 공주대 포털 SSO 검증
  → 검증된 임시 포털 browser session으로 KNUIS 조회
  → 같은 요청에서 받은 비밀번호로 임시 LMS session 생성
  → 학적/시간표/성적/과목/과제 등을 KNU PostgreSQL에 저장
  → 비밀번호와 임시 browser session 폐기
```

Apple 앱에는 KNU JWT, 포털 cookie, MCP 토큰 또는 비밀번호가 전달되지 않는다.

### 예시 2: 포털 화면 열기

```text
Apple 앱
  → Codmes 서버에 KNU portal Surface document 요청
  → Codmes 서버가 저장한 KNU JWT를 Authorization 헤더에 추가
  → KNU 서버가 PostgreSQL에서 사용자 포털 데이터 조회
  ← declarative dashboard JSON
  ← Codmes 서버가 schema/크기/action 검증
  ← Apple 앱이 SwiftUI table/key-value UI로 렌더링
```

Codmes 서버는 KNU의 HTML을 전달하지 않고 허용된 JSON 문서만 중계한다.

### 예시 3: AI에게 “이번 학기 장학금 신청 공지 찾아줘”

KNU Surface가 선택된 대화에서 다음 흐름이 일어난다.

```text
사용자 질문
  → Codmes AI runtime이 KNU MCP tool schema를 model에 제공
  → model이 mcp__knu__search_knu_notices 호출 결정
  → Codmes approval inbox에서 사용자 승인
  → Codmes 서버가 MCP_AUTH_TOKEN을 Bearer로 붙여 KNU /api/mcp 호출
  → KNU MCP가 공지 DB 검색·rerank 수행
  ← 제목, 날짜, 본문 근거, 원문 URL
  → model이 반환된 근거만 사용해 답변하고 URL을 인용
```

MCP 토큰은 model prompt, tool argument, approval 기록과 결과에 포함되지 않는다.
현재 manifest는 MCP 도구 범위를 `knu` Surface로 제한하므로 일반
Chat/Notes/Code Surface에서는 KNU 도구가 노출되지 않는다.

## 구성 요소별 담당과 저장 위치

| 구성 요소 | 담당 | 저장하는 정보 | 저장 위치 |
|---|---|---|---|
| Apple 클라이언트 | native Surface 표시, 로그인 입력, 상태 polling, AI 대화 UI | 비밀번호·KNU JWT·MCP 토큰을 저장하지 않음 | 화면 상태와 일반 앱 상태만 |
| Codmes 서버 | plugin 설치, Surface proxy/검증, AI runtime, MCP 승인·호출 | KNU 사용자 JWT, MCP service token, plugin manifest | Codmes Workspace의 `.codmes/config/auth.json`, `.codmes/plugins/` |
| KNU FastAPI 서버 | 포털 로그인 검증, JWT 발급, Surface API, 동기화 시작 | 실행 중에만 비밀번호와 임시 browser session 보유 | 프로세스 메모리/임시 디렉터리; 완료 후 폐기 |
| KNU PostgreSQL | KNU 서비스의 영속 데이터 저장 | 공지, 학적, 시간표, 성적, LMS 과목·과제·공지·강의 | KNU 서버가 사용하는 PostgreSQL |
| KNU MCP 서버 | AI용 공지 검색·상세 근거 제공 | 별도 사용자 비밀번호를 저장하지 않음 | KNU FastAPI 안에서 공지 DB를 조회 |
| 공주대 포털/LMS | 실제 학교 계정 인증과 원천 데이터 제공 | 학교 시스템 정책에 따름 | Codmes 관리 범위 밖 |

KNU FastAPI와 KNU MCP는 현재 같은 프로세스와 포트 `8000`을 사용하지만 역할은
다르다. Surface/API는 사람에게 보여줄 데이터를 제공하고 MCP는 AI가 사용할
구조화된 도구를 제공한다.

## MCP 동작 범위와 한계

현재 제공 도구:

- `search_knu_notices`: 질문, 학과, 카테고리로 공지 근거 검색
- `get_knu_notice_detail`: 검색 결과로 받은 URL의 전체 공지 본문 조회

AI가 질문할 때 무조건 MCP를 호출하는 것은 아니다. Codmes는 KNU Surface에서만
도구 schema를 model에 제공하고, 실제 호출 여부와 인자는 model이 질문 내용에 따라
결정한다. 호출에는 기본적으로 사용자 승인이 필요하다. KNU MCP는 상위 AI가 정한
검색어와 category를 바로 검색하며 내부에서 별도의 LLM을 다시 호출하지 않는다.

### 질문 분류와 MCP 인자 예시

`이번 학기 국가장학금 신청 공지 찾아줘`처럼 카테고리가 분명하면 Codmes AI가
카테고리를 tool 인자로 지정한다.

```json
{
  "name": "search_knu_notices",
  "arguments": {
    "query": "이번 학기 국가장학금 신청",
    "category": "장학",
    "limit": 5
  }
}
```

`이번 주에 내가 확인할 공지 알려줘`처럼 카테고리가 불분명하면 category를
생략한다. KNU MCP는 특정 카테고리로 제한하지 않고 전체 공지에서 관련 근거를
검색한다.

```json
{
  "name": "search_knu_notices",
  "arguments": {
    "query": "이번 주에 확인할 공지",
    "limit": 10
  }
}
```

`최근 수강 관련 공지 목록 보여줘`는 category를 `수강`으로 지정한다. KNU 서버는
`목록`, `최근`, `전체`, `여러` 같은 표현이 포함된 질문을 여러 문서를 반환하는
목록형 검색으로 처리하고, 그 외에는 단건의 구체적 근거를 찾는 검색으로 처리한다.

```text
Codmes AI
├─ MCP 호출 필요 여부 판단
├─ 검색어, category, limit 결정
└─ 사용자 승인 후 도구 호출

KNU MCP
├─ category 범위로 pgvector 후보 검색
├─ reranker로 관련도 재정렬
├─ reranker 장애 시 vector 유사도 순서로 fallback
└─ 제목, 날짜, 본문 근거와 원문 URL 반환
```

따라서 카테고리 분류가 사라진 것이 아니라 Codmes AI의 tool-calling 단계로
이동한 것이다. KNU 웹 챗봇의 기존 RAG 경로에서는 별도의 KNU LLM router를 계속
사용한다.

답변 품질은 KNU PostgreSQL에 수집·인덱싱된 공지와 검색/rerank 결과에 의존한다.
데이터가 없거나 근거가 부족하면 MCP는 `no_results`를 반환하며 AI는 추측하지 않고
정보가 부족하다고 답해야 한다.

## 제거

```sh
cd /path/to/Codmes
node bin/codmes.mjs plugin remove kr.ac.kongju.knu \
  --root /path/to/CodmesWorkspace
```

plugin 제거는 Codmes의 Surface와 MCP 등록을 제거한다. KNU PostgreSQL 데이터나
KNU 서버 자체는 삭제하지 않는다.
