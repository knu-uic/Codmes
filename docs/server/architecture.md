# 아키텍처

## 실행 구조

```text
Apple / Android / Windows client
  |- device-local files / per-device sync policy / pending journal
  | HTTP + WebSocket
  v
Codmes Server Manager
  |- native menu bar / system tray process
  |- bundled Node + portable Python
  v
Codmes Workspace Server
  |- Workspace file APIs
  |- Search and document ingest
  |- Session and agent runtime
  |- Provider, auth, tools and approvals
  v
Workspace + .codmes state
```

`server/index.mjs`가 HTTP/WebSocket 진입점이다. 기능 로직은 `server/lib`에,
문서 추출 worker는 `server/workers/document-ingest`에 있다. 설치형 Server
Manager는 `apps/server-manager`에 있으며 실제 서버를 bundled Node child process로
실행한다. PDF/Office worker는 설치 패키지의 OS·CPU별 portable Python을 사용한다.
클라이언트는 `apps/client/apple`, `apps/client/android`, `apps/client/windows`에 나뉜다.

Server Manager의 화면과 계정·OAuth·서버 제어는 OS 공통 코드다. 네이티브 브라우저
실행, Dock/메뉴바, 프로세스 실행 옵션, 설정 파일 권한과 실행 파일 경로는
`apps/server-manager/src-tauri/src/platform/`의 OS 어댑터를 통해 호출한다.
`macos.rs`·`linux.rs`·`windows.rs` 중 현재 OS만 컴파일하며 macOS/Linux 공통 처리는
`unix.rs`에서 공유한다. 자동 시작 등록은 Tauri 플러그인이 OS별로 처리한다.

## 주요 서버 모듈

| 영역 | 기준 구현 |
| --- | --- |
| 파일과 라우팅 | `server/index.mjs`, `server/lib/path-utils.mjs` |
| 검색 | `server/lib/search-service.mjs` |
| 문서 추출 | `server/lib/document-ingest.mjs` |
| PDF 분석 job | `server/lib/document-jobs.mjs` |
| PDF thumbnail cache key | `server/lib/pdf-thumbnail.mjs` |
| local OCR/PDF 재작성 | `server/workers/document-ingest/ocr_vision.swift`, `normalize_pdf.py` |
| 대화/세션 | `server/lib/session-runtime.mjs`, `server/lib/runtime/conversation-index.mjs` |
| 모델 실행 | `server/lib/runtime/openai-compatible-runtime.mjs` |
| 작업과 패치 | `server/lib/agent-engine.mjs`, `server/lib/code-agent-runtime.mjs` |
| 설정과 인증 | `server/lib/runtime/config-store.mjs` |
| Codmes 계정·Google 연결 | `server/lib/local-accounts.mjs`, `account-password.mjs`, `google-auth.mjs` |
| 프로필·기기 승인 | `server/lib/workspace-tenancy.mjs`, `profile-auth.mjs` |
| 파일 ID·목록·기기별 정책 | `server/lib/workspace-catalog.mjs`, `workspace-sync.mjs` |
| 병합·재전송·압축 기준 자료 | `server/lib/workspace-merge.mjs`, `workspace-versioned.mjs`, `workspace-sync-storage.mjs` |
| MCP/skills/security | `server/lib/runtime/mcp-client.mjs`, `skill-registry.mjs`, `security-policy.mjs` |
| 통합 Plugin Runtime | `server/lib/runtime/plugin-runtime.mjs`, `builtin-plugin-registry.mjs` |
| Community plugin 설치/배포 | `server/lib/runtime/plugin-registry.mjs`, `plugin-marketplace.mjs` |

## 경계 규칙

- 모든 파일 API는 Workspace-relative POSIX 경로를 받는다.
- 절대 경로와 `..` traversal은 서버에서 거부한다.
- 로그인은 서버 기능을 연결하는 절차이며 클라이언트 기본 화면의 진입 조건이 아니다.
- 파일·annotation은 기기별 로컬/서버/동기화 정책을 적용한다. Apple은 오프라인
  파일/PDF 편집을 지원하며 Android/Windows의 제한은 Notes 문서에 명시한다.
- 서버 연결 시 manifest를 먼저 표시하고 선택된 파일을 순차 전송한다. 파일의 ID는
  이동·이름 변경에도 유지하며, 독립 가져오기 ID는 이름만으로 합치지 않는다.
  원본과 필기 fingerprint가 같으면 연결하고, 다르면 첫 등록 확인이 필요하다.
- 동기화는 공통 기준을 사용한 텍스트/PDF 속성별 병합이다. 겹치는 변경은 로컬
  수정 순서를 사용하고 서버 도착 순서를 사용하지 않는다. CRDT가 아니다.
- 검색·AI·서버 대화 상태는 Workspace HTTP/WebSocket API로 요청한다.
- Notes PDF 업로드 binary는 먼저 원본 경로에 저장한 뒤 server job에서 검사한다.
  정상 PDF는 그대로 두고 OCR 정규화가 필요한 PDF는 검증된 적용본으로 원자적으로
  교체한다. 최초 binary는 문서 상태의 `source/original.pdf`에 보관한다.
- 편집 가능한 필기는 PDF binary와 분리된 문서별 `annotations.json`이다.
- 검색 인덱스와 문서 추출 결과는 파생 상태이며 다시 만들 수 있다.
- 세션, 승인, 메모리, 사용자 설정은 파생물이 아니므로 Workspace 백업에 포함한다.

## PDF upload 이후 비동기 흐름

```text
client upload
  -> server binary 저장
  -> upload 응답 + documentJob
  -> PDF text 검사
  -> 필요한 page Vision/VLM OCR
  -> PDF binary 재작성과 검증
  -> 부분 search index 갱신
  -> job 완료
```

document job registry는 현재 server process memory 상태다. Apple client는 유휴 시
2초, active job이 있으면 1초 간격으로 polling한다. Notes 상단 icon은 client
upload queue가 아니라 이 server job 목록의 `running` 상태만 반영한다.

## Plugin boundary

Chat·Notes·Code·Planner는 Codmes에 포함된 built-in plugin이고, KNU 같은 optional
plugin은 Workspace 서버에 한 번 설치한다. 둘 다 `Plugin Runtime`에서 동일한
plugin/view/tool/settings 계약으로 조회되며 호환되는 macOS/iOS/Android/Windows
client에 함께
표시된다. 별도의 Surface Registry나 `/api/surfaces` 호환 API는 없다.

Community plugin 설치는 declarative view와 Streamable HTTP MCP entry를 원자적으로
등록한다. 클라이언트 앱은 plugin service에 직접 연결하지 않는다.

```text
Native client renderer  <- Codmes binding compiler <- plugin package UI JSON
                                     ^              + plugin domain data API
AI runtime             -> Codmes MCP client    -> plugin MCP service
```

The client never executes plugin HTML, JavaScript, or native binaries. Codmes
validates the plugin-owned binding and compiled document, then renders
allowlisted components/actions. The data client does not forward the Workspace
bearer or MCP credential.
HTTPS is required for non-loopback services; plain HTTP and credential-free MCP
are allowed only on loopback for a locally deployed plugin gateway. Tool calls
remain subject to the normal Codmes approval policy.

KNU is the first proof of concept. Its development package points directly at
local FastAPI, maps public notice data to a native collection through the
package's `surface.json`, and exposes its notice evidence MCP only on the `knu`
Surface. Codmes sends the server-side
`knu` credential as a Bearer token; Docker/Caddy is an optional deployment
path. KNU account/portal/LMS authentication remains a KNU-service concern, not
a Codmes account feature.

## 실시간 흐름

`/api/live` WebSocket은 사용자 명령, model stream, tool event, approval 및 완료
이벤트를 전달한다. 화면에 보이는 assistant 응답과 저장되는 세션 응답은 같은
stream event에서 만들어진다.
