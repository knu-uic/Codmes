# 아키텍처

## 실행 구조

```text
Apple App
  | HTTP + WebSocket
  v
Codmes Server
  |- Workspace file APIs
  |- Search and document ingest
  |- Session and agent runtime
  |- Provider, auth, tools and approvals
  v
Workspace + .codmes state
```

`server/index.mjs`가 HTTP/WebSocket 진입점이다. 기능 로직은 `server/lib`에,
문서 추출 worker는 `server/workers/document-ingest`에 있다. Apple 앱은
`client/apple/Sources/Codmes`의 SwiftUI, PDFKit, AppKit/UIKit 코드로 구성된다.

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
| MCP/skills/security | `server/lib/runtime/mcp-client.mjs`, `skill-registry.mjs`, `security-policy.mjs` |

## 경계 규칙

- 모든 파일 API는 Workspace-relative POSIX 경로를 받는다.
- 절대 경로와 `..` traversal은 서버에서 거부한다.
- Apple 앱은 파일, annotation, 검색 상태를 `WorkspaceAPI`를 통해 요청한다.
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

## Local KNU MCP boundary

Each Mac runs Codmes and KNU MCP together. Codmes reaches its own KNU MCP over
the loopback Streamable HTTP endpoint `http://127.0.0.1:8000/api/mcp/`; this
request does not use Tailscale. HTTP is allowed only for loopback addresses;
every non-loopback MCP endpoint must use HTTPS. The endpoint bearer is stored
only in `.codmes/config/auth.json` under `mcp_credentials`, with `0700` config
directory and `0600` auth file permissions. `codmes mcp setup-local-knu`
stores the local URL and bearer reference in one server-side operation.

## 실시간 흐름

`/api/live` WebSocket은 사용자 명령, model stream, tool event, approval 및 완료
이벤트를 전달한다. 화면에 보이는 assistant 응답과 저장되는 세션 응답은 같은
stream event에서 만들어진다.
