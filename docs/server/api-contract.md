# API 계약

기본 주소는 `http://127.0.0.1:8787`이다. 이 문서는 endpoint를 찾기 위한 현행
목록이며 request/response field의 최종 기준은 `server/index.mjs`와 Apple
`WorkspaceAPI.swift`다.

## 공통 규칙

- JSON endpoint는 `application/json`을 사용한다.
- 파일 경로는 Workspace-relative POSIX 경로다.
- token이 설정된 서버는 `Authorization: Bearer <token>`을 요구한다.
- 오류는 적절한 HTTP status와 `{ "error": "..." }`를 반환한다.
- `/api/health`는 서버 접근 확인을 위해 인증 없이 사용할 수 있다.

## Workspace와 파일

| Method | Path | 역할 |
| --- | --- | --- |
| GET | `/api/health` | 서버 상태 |
| GET | `/api/workspace` | Workspace 정보 |
| GET | `/api/tree` | 파일 트리, `root`, `path`, `recursive` 사용 |
| GET/PUT | `/api/file` | text 파일 읽기/저장 |
| POST | `/api/file` | 새 파일 |
| POST | `/api/folder` | 새 폴더 |
| PATCH | `/api/file/move` | 파일 또는 폴더 이동/이름 변경 |
| POST | `/api/file/copy` | 복사 |
| DELETE | `/api/file` | 삭제 |
| GET | `/api/raw` | binary 원본 읽기 |
| GET | `/api/file/metadata` | 파일 및 추출 metadata |
| GET | `/api/pdf-thumbnail` | PDF page thumbnail |
| GET | `/api/pdf/metadata` | PDF page 수와 streaming metadata |
| GET | `/api/pdf/skeleton` | page 수를 유지한 작은 skeleton PDF |
| GET | `/api/pdf/page` | 지정한 PDF page fragment |
| GET | `/api/document-jobs` | 서버 PDF 검사·OCR·정규화 작업 상태 |

업로드:

- `POST /api/file/upload`: 작은 파일 JSON 업로드
- `PUT /api/file/binary`: binary 저장
- `POST /api/file/upload/start`
- `POST /api/file/upload/chunk`
- `POST /api/file/upload/complete`
- `POST /api/file/upload/cancel`

Notes PDF의 저장/업로드 완료 응답에는 작업을 시작한 경우 다음 요약이
`documentJob`으로 포함된다.

```json
{
  "id": "job-id",
  "status": "running",
  "path": "Notes/example.pdf",
  "title": "example.pdf"
}
```

파일 저장이 끝났다는 응답이며 OCR과 검색 index 갱신 완료를 뜻하지 않는다.
`GET /api/document-jobs`는 최근 최대 20개 job을 반환한다. 각 job에는 `kind`,
`status`, `stage`, `stageLabel`, `progress`, `completedUnits`, `totalUnits`,
`startedAt`, `updatedAt`, `completedAt`, `message`가 있다.

`GET /api/pdf-thumbnail` query:

- `path`, `page`
- 선택적인 normalized crop `x`, `y`, `width`, `height`
- 선택적인 `highlight`: PDF 안에서 다시 찾을 검색어
- 선택적인 `scale`

응답은 PNG다. render identity는 PDF 크기/mtime, page, crop, query, scale과
renderer version을 포함하며 SHA-256 파일명으로 cache한다.

Codmes PDF package:

- `POST /api/file/export-codmes-pdf`
- `POST /api/file/import-codmes-pdf`
- `POST /api/file/import-codmes-pdf-package`

## PDF annotation

```text
GET /api/file/annotations?path=Notes/example.pdf
PUT /api/file/annotations?path=Notes/example.pdf
```

저장에 성공하면 해당 문서의 검색 항목도 갱신한다. 상태 형식과 저장 위치는
[Notes annotation 문서](../features/notes.md#annotation-data)를 참고한다.

## Search와 context

| Method | Path | 역할 |
| --- | --- | --- |
| POST | `/api/context` | 선택 범위의 model context 구성 |
| GET | `/api/index/status` | 파일/index 상태 |
| POST | `/api/index/rebuild` | 전체 검색 index 재생성 |
| GET | `/api/search/status` | search runtime 상태 |
| GET | `/api/global-search` | cursor 기반 사용자 전역 검색 |
| POST | `/api/search` | runtime chunk 검색 |
| GET/POST | `/api/search/config` | 검색 설정 조회/저장 |

`/api/global-search`는 한 번에 최대 100개를 반환하고 `nextCursor`와 `hasMore`로
다음 묶음을 읽는다. 전체 결과를 100개에서 잘라내지는 않는다. UI 결과는 문서별로
묶고 문서는 파일명 일치와 일치 page/횟수로 정렬하며, 문서 내부 PDF 결과는 page
순서를 사용한다.

PDF 본문 결과의 `target`에는 `path`, 1-based `page`, 선택적인 `bbox`가 있다.
`bbox`는 PDF point 값과 `normalized` 값을 함께 가질 수 있다. OCR 정규화 PDF의
exact query 결과는 line 전체가 아니라 query 폭과 실제 화면 glyph 위치로 보정된
box를 반환하므로 client는 추가 baseline 보정 없이 `normalized` 값을 사용한다.

## Provider, model, auth

- `GET /api/providers`
- `POST /api/providers/custom`
- `DELETE /api/providers/custom/:id`
- `GET /api/providers/:id/models`
- `GET /api/auth`
- `POST /api/auth/:provider`
- `DELETE /api/auth/:provider/:credentialId`
- `POST /api/auth/:provider/select`
- `DELETE /api/auth/:provider/credentials/:credentialId`
- `POST /api/auth/openai-codex/login/start`
- `GET /api/auth/openai-codex/login/:id`
- `POST /api/auth/openai-codex/login/:id/cancel`
- `GET/POST /api/model/default`
- `GET /api/models` (`/api/workspace/models` alias 포함)

## Sessions와 live chat

- `GET/POST /api/sessions`
- `GET/DELETE /api/sessions/:id`
- `GET /api/sessions/:id/messages`
- `POST /api/sessions/:id/rename`
- `GET /api/sessions/:id/export`
- `POST /api/sessions/prune`
- `POST /api/sessions/:id/archive`
- `POST /api/sessions/:id/unarchive`
- `POST /api/sessions/:id/summarize`
- `GET /api/conversation-archive`
- `POST /api/sessions/archive-expired`
- `GET/POST/PATCH/DELETE /api/conversation-folders...`
- `POST /api/sessions/:id/move-to-folder`
- `GET/POST /api/conversations/search`
- `POST /api/conversations/read`
- `GET /api/conversations/:id/messages`

`/api/workspace/sessions` 계열은 Workspace-owned session 호환 endpoint다.
실시간 채팅은 `/api/live` WebSocket을 사용한다.

## Tasks, approvals, code

- `/api/agent/tasks`, `/api/agent/tasks/:id`
- `/api/agent/tasks/:id/resume`, `/api/agent/tasks/:id/cancel`
- `/api/agent/approvals`, `/api/agent/approvals/:id`
- `/api/agent/approvals/:id/respond`
- `POST /api/agent/code-task`
- `POST /api/agent/code-task/:id/patches`
- `POST /api/agent/code-task/:id/patches/generate`
- `POST /api/agent/code-task/:id/patches/:proposalId/apply`
- `POST /api/agent/code-task/:id/patches/:proposalId/reject`
- `POST /api/agent/code-task/:id/checks`
- `POST /api/agent/code-task/:id/git`

## Runtime 관리

- `/api/skills...`
- `/api/security`
- `/api/mcp...`
- `/api/doctor`
- `GET /api/plugins`
- `POST /api/plugins/:id/configuration`
- `/api/tool-modes...`
- `/api/tools/available`
- `/api/tools/discover`
- `/api/memory...`
- `POST /api/render/markdown`
- `POST /api/render/code`

동적 endpoint의 허용 method와 body schema를 변경할 때는 서버 route test와
`WorkspaceAPI.swift` 호출부를 함께 수정한다.

## Plugins and remote MCP

`/api/mcp` accepts legacy local `stdio` entries and Streamable HTTP entries
shaped as
`{name, transport:"streamable_http", url, credential_id, surfaces, enabled}`.
Remote URLs must be HTTPS and contain no userinfo, query, or fragment. A
loopback HTTP MCP may explicitly set `allowUnauthenticated:true`; this is meant
for a local gateway that injects the service credential. Responses expose only
credential status and never return bearer values.

Plugin Runtime routes:

- `GET /api/plugins` lists built-in and installed community plugins through one
  response contract, including each plugin's native/declarative views.
- `POST /api/plugins/:pluginId/configuration` changes plugin enablement.
- `POST /api/plugins/install` with `{path}` installs a server-local package.
- `DELETE /api/plugins/:pluginId` removes a community plugin's view, tools, and
  MCP registration. Built-in plugins are not removable.
- `GET /api/plugins/:pluginId/view-document?route=<navigationId>` loads the
  installed plugin-owned route binding, fetches its domain JSON data sources,
  compiles them into one declarative document, and validates it for native
  client rendering.
- `GET /api/plugins/:pluginId/auth/status` returns login state without a token.
- `POST /api/plugins/:pluginId/auth/login` accepts `{username,password}`,
  maps those values to the manifest's `usernameField` and `passwordField`,
  forwards them to the plugin login endpoint, discards the password, and
  stores only the returned token server-side. External SSO verification may
  take longer than an ordinary API login, so the bounded upstream timeout is
  50 seconds.
- `DELETE /api/plugins/:pluginId/auth/logout` removes that stored token.

CLI-first installation uses
`codmes plugin install <path> --root <workspace>`. Installation resolves and
validates a package-local `surface.ui` file, embeds that declarative definition
in `.codmes/plugins/<pluginId>/plugin.json`, and updates the MCP config as one
rollback-safe operation. Removal reverses both. The current format installs
declarative configuration only; it does not download or execute native code.
