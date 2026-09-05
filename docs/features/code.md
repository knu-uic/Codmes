# Code Surface

Code는 `<Workspace>/Code` 아래 project를 탐색하고 server의 code agent 작업을
제어하는 surface다.

## 현재 기능

- 재귀 file tree와 여러 folder 동시 expand
- source file 읽기와 편집
- file/folder 생성, rename, move, copy, delete와 다중 선택 drag
- 여러 언어의 Shiki syntax highlight
- code task 생성과 상태 조회
- patch 제안, 승인 적용과 거절
- 승인된 check 및 제한된 Git command 실행
- 현재 file/project context를 Chat에 전달

## Server 흐름

```text
Apple Code UI
  -> /api/agent/code-task
  -> CodeAgentRuntime
  -> task / patch / diff state under .codmes
  -> approval and checks
```

Code 작업은 Workspace의 `Code` 범위 안에서 실행하며 path traversal을 허용하지
않는다. patch 적용과 위험한 Git/shell 작업은 security policy와 approval을 따른다.

Code 작업은 Code Surface에서만 시작할 필요가 없다. Chat이나 plugin Surface에서
대화를 시작했더라도 모델이 최초 Code 도구를 선택하면 Code task를 지연 생성하고
현재 대화에 연결한다. 이때 원래 UI Surface는 `uiSurface`로 보존하고 실제 실행
문맥은 `executionSurface`와 발견한 tool group으로 관리한다.

Code 도구가 선택되면 일반 8라운드 예산을 32라운드로 확장한다. 검사 실패로
추가 분석과 재수정이 필요해지면 최대 64라운드의 `code-deep` 프로필로 승격한다.
쓰기·명령 실행에 대한 기존 승인 정책은 실행 예산과 별도로 계속 적용된다.

## 현재 경계

- 완전한 LSP, debugger, extension host는 없다.
- 기기 내부 terminal 대신 향후 server terminal session을 제어하는 방향이다.
- 자동 수정 반복은 task/check 결과를 기반으로 점진적으로 확장한다.

API는 [Server API 문서](../server/api-contract.md), 전체 남은 작업은
[roadmap](../roadmap.md)을 참고한다.
