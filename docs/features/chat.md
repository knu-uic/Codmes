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
