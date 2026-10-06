# API 계약

기본 주소는 `http://127.0.0.1:8787`이다. 이 문서는 endpoint를 찾기 위한 현행
목록이며 request/response field의 최종 기준은 `server/index.mjs`와 Apple
`WorkspaceAPI.swift`다.

## 공통 규칙

### 로컬 자료 동기화

- `GET /api/sync/manifest`: 현재 인증된 프로필의 Notes/Code 파일·폴더 및 PDF 필기 revision 목록.
- `GET /api/sync/blob?path=...&resource=file|annotations&revision=...`: 정확히 지정한 SHA-256 내용의 다운로드. 변경되면 409.
- `PUT /api/sync/blob?path=...&resource=file|annotations`: binary stream 업로드. `X-Codmes-Base-Revision`에 이전 revision 또는 `missing`을 지정한다.
  최신 Swift/Kotlin/C# 저장 경로는 아래 `merge-modified-v2` 규격을 사용한다.
- `POST /api/sync/change`: `{path, resource, action:"put"|"delete", baseRevision}`로 폴더 생성 또는 삭제. 최초 생성은 명시적인 JSON null을 사용한다.

변경 응답은 `{status:"applied"|"conflict", entry, operationId?, reason?}`이다.
manifest는 `conflictPolicies`, 현재 entry의 `versionId`·`logicalModifiedAt`, 그리고
삭제된 자료의 `{path,resource,versionId,modifiedAt}`인 `deletedEntries`를 제공한다.

#### 선택 동기화 / 독립 파일 등록

manifest는 추가로 `selectiveSyncVersion:1`, `documentBundleVersion:1`, workspace별
영구 `serverId`, `catalogRevision`과 entry의 `fileId`를 제공한다. PDF 원본 entry는
annotation의 구조화된 내용까지 포함한 `annotationFingerprint`를 제공한다.
이 값은 `updatedAt`·`documentPath`를 제외하고 key/page 순서와 기본 배열을 정규화한
SHA-256이며, 완전히 빈 기본 문서는 `none`이다. 원본 SHA만으로 PDF 동일성을
판정하지 않는다. 서로 다른 ID의 같은 경로 파일은 원본·필기까지 같을 때 연결하고,
다르면 사용자 결정 전에는 전송하지 않는다.

- `X-Codmes-File-ID`: 이미 연결된 서버 ID 또는 신규 로컬 UUID. 인증 수단이 아니다.
- `X-Codmes-First-Registration: true`: 독립 최초 등록. 기존 파일과 충돌하면
  `first-registration`을 반환한다. 동일 operation 재시도는 중복 등록이 아니다.
- `X-Codmes-Expected-Revision`: 사용자 덮어쓰기 결정 당시 revision 또는 `missing`.
  현재 값과 다르면 `decision-stale`이다. 첫 업로드 경쟁은 workspace의 프로세스 간
  writer lock 안에서 다시 검사하므로 목록 검사 이후의 경쟁도 덮어쓰지 않는다.
- `POST /api/sync/move`: `{from,to,fileId,expectedRevision}`. ID와 merge bases를
  보존하며 이동한다. 대상 충돌은 사용자 확인 대상으로 반환한다. write-ahead
  move intent를 복구한 뒤 읽기/다음 변경을 처리한다.
- `GET /api/sync/devices`: 현재 workspace의 기기별 마지막 보고 목록.
- `POST /api/sync/devices`: `{policies:[{fileId,mode,locallyAvailable,pending}]}`.
  한 요청 최대 10,000개, 앱은 1,000개씩 보고한다. 기기 ID는 승인된 registration의
  인증 세션에서 결정하며 body의 `deviceId`로 다른 기기를 사칭할 수 없다. 미등록
  로컬 파일의 이름·경로는 업로드하지 않는다. preference 보고는 다른 기기의 mode나
  파일 삭제를 발생시키지 않는다. 서버 `reportedAt`은 실시간 기기 상태가 아니라
  마지막 보고 시각이다.
- `PUT /api/sync/document`: 최초 PDF 등록/명시적 공동 덮어쓰기용 binary transaction.
  body는 4-byte big-endian JSON header 길이 + UTF-8 header + PDF 원본 + 필기 JSON.
  header는 `{fileChange,annotationChange,fileSize,annotationSize}`이며 change는
  아래 `merge-modified-v2` camelCase 규격에 `fileId`와 `expectedRevision`을 더한다.
  두 path/ID는 같고 resource는 각각 `file`/`annotations`여야 한다. header ≤64 KiB,
  annotations ≤16 MiB, 총 stream ≤2 GiB. 두 revision을 한 lock에서 검사한 후
  fsync된 transaction intent를 기록한다. 실패·프로세스 종료 시 다음 reader가
  두 자원을 모두 복구한 뒤 응답한다. 큰 PDF를 base64/메모리에 모으지 않는다.

기기 모드는 file > nearest folder > ancestor > Notes/Code(plugin default) 순이다.
서버는 content와 ID만 제공하고 어떤 payload를 보관할지의 결정은 클라이언트가 한다.
server 모드라도 열린 파일·미전송 변경은 안전을 위해 로컬에 잠시 남길 수 있다.
일반 편집 변경은 기존 merge 규격으로 처리하고, 독립 첫 등록/서로 다른 PDF 교체를
일반 merge로 오인하지 않는다. 자동 충돌 사본은 생성하지 않는다.

`merge-modified-v2` 업로드 헤더:

- `X-Codmes-Conflict-Policy: merge-modified-v2`
- `X-Codmes-Operation-ID`: 변경마다 생성한 UUID. 재시도 때 바꾸지 않는다.
- `X-Codmes-Device-ID`: 영구 기기 ID.
- `X-Codmes-Modified-At`: 해당 **로컬 수정** 시각(ISO 8601 UTC). 전송 시각이 아니다.
- `X-Codmes-Base-Revision`: 편집한 원본의 SHA-256 또는 `missing`.
- `X-Codmes-Base-Version`: 그 원본의 `versionId`. 생성은 생략 가능하다.

삭제는 `/api/sync/change`에 동일 필드의 camelCase JSON과 `action:"delete"`를
보낸다. 폴더는 기존 조건부 revision 검사를 유지한다. 오프라인 저장 각각의
snapshot·시각·원본을 보관하며 다음 오프라인 변경은 이전 변경의 operation UUID를
baseVersion으로 사용할 수 있다. 병합 acknowledgement를 원본 snapshot으로
잘못 바꾸지 않는다. 동일 SHA라도 인과 버전이 다를 수 있다.

서버는 변경을 로컬 시각 → 인과 counter → ASCII 기기 ID → operation ID 순으로
정렬해 동일 순서로 재현한다. 관측한 원본보다 기기 시계가 뒤로 갔으면 인과 관계를
우선한다. 동시 수정의 실제 시간은 기기 시계 정확도에 의존한다. 5분 이상 미래인
시각은 거절하고 로컬 변경을 유지한다. 늦게 도착한 과거 수정은 최신 수정이 되지 않는다.

UTF-8 텍스트는 3-way 줄 병합 후 겹친 줄 안의 단어·기호 경계로 범위를 줄인다.
독립된 수정과 추가는 보존하고 같은 단어의 동시 교체만 최신 로컬 수정이 우선한다.
PDF sidecar는 stable pageId와 object/element/stroke ID, 내부 속성별로 병합한다.
텍스트·색상 등 독립 속성은 함께 반영하며 bbox/transform/points는 원자 단위다.
PDF 원본 binary·비 UTF-8 자료는 파일 단위 최신 로컬 수정으로 처리한다.
불투명한 PencilKit bytes만 있는 필기는 페이지 단위다. 구조화 stroke가 섞이면
derived PencilKit 렌더링을 폐기하고 재구성한다. 동시 페이지 구조 충돌은 자동
병합을 보장하지 않으며 중복 pageId/pageIndex는 거절한다.

base 누락, 파일/폴더 충돌, 외부에서 직접 변경된 관리 파일, 큰/복잡한 텍스트 충돌은
삭제·덮어쓰기 대신 미전송 상태로 유지한다. 안전한 텍스트 병합은 8 MiB, annotations는
16 MiB다. 기존 10,000 operations 제한으로 장기 사용자의 동기화가 중단되는 동작은
제거했다. 늦게 도착한 변경의 재현에 필요한 operation metadata는 유지한다.

정책 없는 요청은 기존 CAS, `merge-latest`는 과거 도착순 규격이다. v2 관리 자료는
구규격 및 기존 mutation API로 우회 수정할 수 없으며 클라이언트 업데이트가 필요하다.
병합 SHA는 업로드 SHA와 다를 수 있어 실제 manifest/blob를 검증해 내려받는다.
write-ahead journal `.codmes/sync-v2`와 immutable `.codmes/sync-bases`에 병합 기준을
저장한다. content-defined 2–32 KiB 블록을 내용 해시로 공유하고 압축한다. 각 revision은
블록 ID 목록만 보관해 작은 삽입 후에도 나머지 블록을 재사용한다. chain delta가 아니므로
원본 복원에 과거 모든 버전을 순서대로 재생할 필요는 없다. projection 목록은 최신
항목 하나만 남기지만, 모든 인과 version alias와 병합용 원본 기준은 보존한다.
장기 오프라인 지원 때문에 이 내부 기준 저장소의 전체 용량은 고정 상한이 아니다.
기존 `.codmes/sync-history` 전체 사본은 읽을 때 새 저장 형식으로 변환하고 검증 후
해당 사본만 제거한다. commit 이후 projection 중단은 다음 조회 때 복구한다.
응답 유실 재전송은 같은 operation ID로 중복 적용되지 않는다. 삭제는 tombstone과
병합 기준으로 남고 과거 offline 수정만으로 부활하지 않는다. 별도의 전체파일 trash
사본은 새로 생성하지 않는다. 충돌 사본 파일은 만들지 않는다.

- `GET /api/sync/history?path=...&resource=file|annotations&offset=0`: 100개씩 조회,
  `{entries,nextOffset}`. 원본 변경과 병합 결과, 삭제 기록을 구분한다.
- `GET /api/sync/history/blob?path=...&resource=...&version=...`: 해당 문서의 특정 이력.
- `GET /api/sync/recovery`: 삭제된 문서의 `{entries:[{path,modifiedAt}]}`.

위 조회 endpoint는 기존 규격과 진단의 호환성을 위해 유지하지만 새 클라이언트에
이력 조회·복원 메뉴로 노출하지 않는다. 모든 sync/history/recovery endpoint는 기존
프로필 인증·기기 승인·권한 검사를 적용한다. 사용자 편집기는 세션 내 제한적인
undo/redo를 사용하며 되돌리기를 현재 기준에 대한 새 수정으로 저장한다.

- JSON endpoint는 `application/json`을 사용한다.
- 파일 경로는 Workspace-relative POSIX 경로다.
- Server Manager로 실행한 서버는 계정 로그인 후 프로필을 열어 받은 token을
  `Authorization: Bearer <token>`으로 전달한다.
- 오류는 적절한 HTTP status와 `{ "error": "..." }`를 반환한다.
- `/api/health`는 서버 접근 확인을 위해 인증 없이 사용할 수 있다.

## 서버 계정과 프로필

Codmes 계정 UUID가 본체이며 Google은 연결 가능한 로그인 수단이다. ID·비밀번호
또는 Google 중 하나로 로그인한다. Google 가입도 ID·비밀번호를 한 번 설정한다.
기존 Google 사용자 설정과 Google 연결 변경·해제는 계정·프로필·기기 승인 ID를
유지한다. 비밀번호는 scrypt 해시로 저장하고 API에 노출하지 않는다.

| Method | Path | 역할 |
| --- | --- | --- |
| POST | `/api/auth/admin/bootstrap` | 비어 있는 서버의 첫 관리자 생성 (Manager 전용) |
| POST | `/api/auth/admin/login` | Codmes ID·비밀번호 관리자 로그인 (Manager 전용) |
| GET | `/api/auth/admin/setup` | 기존 서버 여부와 마스킹된 관리자 ID/이메일 (loopback + native Manager 비밀 헤더 필수) |
| POST | `/api/auth/client/register` | ID·비밀번호 회원가입 및 기기 승인 요청 |
| POST | `/api/auth/client/login` | ID·비밀번호 로그인 및 기기 승인 확인 |
| GET | `/api/auth/account` | 본인 ID, Google 연결, 자격 증명 설정 여부 |
| POST | `/api/auth/account/credentials` | 기존 Google 사용자의 ID·비밀번호 최초 설정 |
| POST | `/api/auth/account/password` | 현재 비밀번호 확인 후 새 비밀번호 설정 |
| POST | `/api/auth/account/google/link` | 현재 비밀번호와 Google 인증으로 연결·변경 |
| POST | `/api/auth/account/google/unlink` | 현재 비밀번호 확인 후 Google 연결만 해제 |

가입·로그인은 `{username,password,deviceId,deviceName?}`를 사용한다. Google 첫
로그인은 `account_setup_required`를 반환하며 검증된 ID token과 ID·비밀번호를
함께 보내 가입을 완료한다. ID 충돌이나 동일 이메일로 자동 병합하지 않는다.
계정 변경은 계정 token만 허용하고 관리자는 Manager session·전용 헤더도 필요하다.
변경 후 다른 로그인 세션은 해제되고 현재 세션은 유지된다. 다른 기기는 HTTPS 필수다.

`/api/auth/admin/setup`은 `{existingServer,maskedAccount:{id,email}|null}`만 반환하며
원본 계정이나 자격 증명을 노출하지 않는다. 관리자 토큰만으로도 호출할 수 없다.
서버 전체 초기화는 OS 확인을 거치는 native Manager 명령으로만 수행하며 HTTP
초기화 endpoint는 없다. 신규 서버 준비/가입 실패 시 원래 저장소를 복원한다.

| Method | Path | 역할 |
| --- | --- | --- |
| GET | `/api/google-auth/config` | Google 로그인 설정과 최초 관리자 생성 필요 여부 |
| POST | `/api/google-auth/admin/bootstrap` | Server Manager에서 Google 최초 관리자 생성 |
| POST | `/api/google-auth/admin/login` | Server Manager 관리자 Google 로그인 |
| POST | `/api/google-auth/client/login` | 클라이언트 Google 로그인 및 기기 등록 |
| POST | `/api/auth/logout` | 계정 세션 종료 |
| GET | `/api/client/profile` | 로그인한 Codmes 계정 정보 및 본인 프로필 |
| POST | `/api/client/profile/register` | 승인된 계정의 프로필 자동 생성·조회 (PIN 없음, 멱등) |
| GET | `/api/profiles` | 클라이언트는 본인 Codmes 계정 프로필만 조회 |
| POST | `/api/profiles/:id/open` | 본인 Codmes 계정 프로필 token 발급 (PIN 불필요) |
| POST | `/api/profiles/:id/archive` | 본인 프로필 삭제(보관), 승인된 계정 세션으로 확인 |
| GET/POST | `/api/admin/profiles` | 로컬 Manager 관리자 프로필 목록/추가 |
| POST | `/api/admin/profiles/:id/rename` | Manager에서 이름 변경 |
| POST | `/api/admin/profiles/:id/pin` | Manager에서 PIN 초기화 |
| POST | `/api/admin/profiles/:id/archive` | Manager에서 프로필 보관 |
| POST | `/api/admin/profiles/:id/restore` | Manager에서 프로필 복구 |

프로필은 각각 Workspace를 소유한다. 첫 Codmes 관리자 계정 생성 시 기본 프로필을
만든다. 승인된 클라이언트는 Codmes 계정당 프로필 하나를 자동 생성하며 같은 서버의
다른 기기에서도 공유한다. 필수 PIN 및 클라이언트 프로필 추가 기능은 없다.
계정 token만으로 파일 API에 접근할 수 없으며, 본인 프로필의 `open` token을 사용한다.
다른 계정의 프로필 조회·열기·삭제는 거절한다. 선택적 앱 잠금 PIN은 기기의 보안
저장소에만 저장하며 서버 API와 분리된다. 기존 프로필 PIN API는 Manager 호환용이다.
삭제는 `deleted_at`을 기록하고 세션을 폐기하는 보관 방식이며 Manager에서 복구할
수 있다. Manager 프로필 API는 loopback 접속, manager 계정 token 및 Manager 전용
헤더가 모두 필요하다.
최초 관리자 계정은 서버 컴퓨터의 Server Manager 첫 화면에서 만든다. 관리자 생성은
loopback 접속과 Manager 전용 헤더에서만 허용한다. 클라이언트의 일반 회원가입은
기기 승인 요청을 생성하며 관리자 권한을 부여하지 않는다.
Manager 로그인에서는 클라이언트와 분리된 관리자 세션을 만든다.

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
- `GET /api/plugins/:id/mcp-tools`
- `POST /api/plugins/:id/mcp-tools/refresh`
- `POST /api/plugins/:id/mcp-tools/consent`
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
- `POST /api/plugins/:pluginId/configuration` changes plugin enablement for the
  selected profile only.
- `GET /api/plugins/:pluginId/mcp-tools` returns the Workspace-local discovered,
  approved, and pending MCP tool catalog without exposing credentials.
- `POST /api/plugins/:pluginId/mcp-tools/refresh` connects to that plugin's MCP
  server and refreshes the catalog. New names remain pending.
- `POST /api/plugins/:pluginId/mcp-tools/consent` replaces the approved snapshot
  with `{ "approvedTools": ["tool_name"] }`; undiscovered names are rejected.
- `POST /api/plugins/install` with `{path}` installs a server-local package. In
  profile mode, one shared package is used by all profiles; any profile with
  write access may install or update it.
- Marketplace install, update, and rollback operate on that same server-wide
  package in profile mode. New permission consent is still required on update.
- The local Server Manager can list and install/update the same package through
  `/api/admin/plugins` and `/api/admin/plugins/:pluginId/(install|update)` with
  a loopback administrator session. Client Marketplace updates do not require
  administrator role beyond ordinary profile write access.
- `DELETE /api/plugins/:pluginId` removes a community plugin's server-wide
  installation in profile mode. Per-profile credentials and collection data
  remain; MCP registration and tool consent are removed. Built-in plugins are
  not removable.
- `GET /api/plugins/:pluginId/view-document?route=<navigationId>` loads the
  installed plugin-owned route binding, fetches its domain JSON data sources,
  compiles them into one declarative document, and validates it for native
  client rendering. A declarative route remains a successful document response
  when a remote data source is temporarily unavailable. The document keeps the
  route-owned title, presentation, filters, empty state, and other UI structure,
  substitutes an empty payload for the failed source, and includes
  `dataState.status` (`partial` or `unavailable`) plus retryable source errors.
  Clients render that state inside the selected route instead of replacing the
  whole plugin Surface with a transport error.
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
The standalone CLI keeps its Workspace-local install path. A multi-profile
server stores community plugin packages once under its managed data root, and
keeps enablement, MCP credentials, tool approvals, and plugin data per profile.
Existing Workspace-local packages are adopted on first startup; their old
directories remain as recoverable backups and cannot be re-adopted after a
server-wide removal.
