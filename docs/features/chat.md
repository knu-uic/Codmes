# Chat

Chat은 Codmes가 소유하는 session에서 model과 대화하고, Workspace context와 tool을
사용하는 surface다. 화면에 표시되는 response와 server에 저장되는 message는 같은
stream event에서 만들어진다.

## Session

- Chat session 생성, 저장, 검색과 이어서 대화
- session rename, delete와 conversation folder 이동
- 대화 archive, summary와 memory 검색
- 현재 file/folder/workspace context 선택

일반 Chat session은 최신 30개를 기본 목록에 유지하고 오래된 항목을 자동 archive한다.
project/folder에 속하거나 고정된 session, 진행 중 task, approval 대기 상태인 session은
자동 archive에서 제외한다.

## Model과 streaming

- LLM model, 접근 mode와 reasoning 수준 선택
- response, reasoning, tool event의 live streaming
- Markdown, table, code block과 Shiki syntax highlighting
- safe mode에서 approval 요청 확인, 허용과 거절

Apple client의 `LiveChatClient`가 `/api/live` WebSocket을 사용한다. model output,
reasoning, tool event, approval과 완료 event가 같은 연결을 통해 전달된다.

## Conversation context

현재 session의 user/assistant 원문은 context window 사용량이 압축 임계값에 도달하기
전까지 모두 모델에 전달한다. 메시지 개수(예: 최근 12개)나 키워드 정규식으로 자르지
않는다. Ollama는 model metadata의 실제 context length를 우선 사용하고, 확인할 수 없는
provider만 model별 보수적 추정값을 사용한다.

임계값에 도달하면 OpenAI Responses 계열은 `/responses/compact`가 돌려준 opaque
compaction item을 저장하고 다음 요청의 input으로 그대로 재사용한다. 이를 지원하지 않는
provider는 선택된 LLM을 보조 요약기로 호출해 목표, 결정, 제약, 완료·검증, 남은 작업,
오류, 정확한 파일 경로와 식별자를 의미 기반으로 압축한다. 압축 상태에는 provider/model,
포함된 마지막 message 범위와 압축 횟수를 함께 저장한다. 최근 원문 범위도 고정 개수가
아니라 token 목표로 정하므로, 매우 긴 goal/tool message 때문에 context가 넘치지 않는다.
다시 임계값에 도달하면 이전 압축 상태와 이후 대화만 재압축한다.
압축 호출이 실패하면 원문을 버리지 않고 해당 turn에는 전체 원문을 유지한다.

한 turn 안에서 tool 결과가 누적된 경우에도 동일하게 LLM이 오래된 완료 tool 흐름을
의미 기반 checkpoint로 압축하고 최신 tool 호출은 원문으로 유지한다. 저장된 session
message와 tool event 원본은 압축과 무관하게 삭제하지 않는다.

다른 session의 message나 summary는 모델 입력에 자동으로 주입하지 않는다. 과거 대화가
필요하면 model은 항상 제공되는 `conversation_search`와 `conversation_read`를 사용한다.
이 두 도구는 모든 Surface와 사용자 설정에서도 제거되지 않는 고정 tool이다.

## Plugin tools

A plugin can scope its MCP tools to its own Surface. For example, the KNU
proof-of-concept exposes notice search/detail tools while `KNU` is selected, but
does not add them to Chat/Notes/Code. Every `mcp.tool.call` follows the normal
approval inbox: rejecting sends no remote request; approving resumes exactly
the stored call. Service credentials are never included in prompts, schemas,
events, approval records, or results.

## Context와 tool

mention으로 file, folder 또는 Workspace를 현재 대화 context에 넣을 수 있다. 작은
현재 file은 직접 읽고, 큰 문서나 넓은 범위는 필요한 search result만 context에
포함한다. tool execution은 server의 security policy와 approval 규칙을 따른다.

Session API는 [Server API 문서](../server/api-contract.md), 저장 구조는
[Server data model](../server/data-model.md)을 참고한다.
