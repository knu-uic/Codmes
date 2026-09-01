# Planner built-in plugin

Planner 0.2.0은 외부 backend나 MCP 없이 Codmes Workspace 안에서 실행되는 공식
기본 plugin이다. Chat·Notes·Code와 함께 Codmes 앱에 포함되며 네 기능 모두
통합 Plugin Runtime의 같은 plugin/view/tool/settings 계약을 사용한다. Planner는
`.codmes/plugins`에 Marketplace 설치 레코드를 만들지 않는다.

## 제공 방식

- 새 Workspace의 `GET /api/plugins` 응답에 처음부터 `distribution: builtin`,
  `builtIn: true`, `removable: false`로 포함된다.
- Marketplace에서 별도로 설치하거나 제거하지 않는다.
- Planner 코드와 UI 규격은 Codmes 앱 버전과 함께 업데이트된다.
- manifest의 Planner 내부 버전은 migration·호환성에 사용하며 별도 제품
  Release를 의미하지 않는다.
- 예전 Surface Registry나 호환 API를 거치지 않고 Plugin Runtime에서 직접 로드한다.

`Planner` plugin의 `플래너`, `달력`, `메모` view와 다음 AI 도구가 기본으로
등록된다.

- `planner_list`, `planner_get`
- `planner_create`, `planner_update`, `planner_delete`
- `calendar_list`, `calendar_get`
- `calendar_create`, `calendar_update`, `calendar_delete`
- `memo_list`, `memo_get`
- `memo_create`, `memo_update`, `memo_delete`

## 데이터와 동기화

할 일과 일정은 Codmes 서버 컴퓨터의 다음 파일에 저장된다.

```text
CodmesWorkspace/.codmes/plugin-data/com.codmes.planner/tasks.json
CodmesWorkspace/.codmes/plugin-data/com.codmes.planner/events.json
CodmesWorkspace/.codmes/plugin-data/com.codmes.planner/memos.json
```

Mac, iPhone, iPad, Android, Windows는 같은 Workspace 서버 API를 사용하므로
별도 클라우드 계정 없이 같은 데이터를 본다. Planner는 built-in plugin이라
사용자가 제거할 수 없다.

## 모드별 쓰기

- Safe: AI의 생성·수정·삭제 전에 Before/After 승인 화면 표시
- Full: AI의 Workspace 내부 쓰기를 즉시 실행
- 사용자가 Planner 편집 화면에서 직접 저장·삭제: 즉시 실행
- 조회: Safe/Full 모두 즉시 실행

## Plugin view

Planner는 선언형 view의 세 route를 제공한다.

- `플래너`: 할 일 검색, 상태 필터, 생성·수정·완료·삭제
- `달력`: 월 이동, 날짜 선택, 일정 생성·수정·삭제
- `메모`: 제목과 여러 줄 텍스트를 작성하고 검색·고정·수정·삭제

세 route 모두 WebView가 아닌 클라이언트별 native/declarative renderer로 표시한다.
package가 `schemaVersion: 2`, collection과 `editor.fields`를 선언하고 Apple,
Android, Windows client가 공통 Surface contract에 맞는 UI와 collection mutation을
제공한다. 자세한 계약은 [Declarative Surface v2](./surface-v2.md)를 참고한다.

`메모`는 기존 `Notes`를 확장하거나 그 파일 구조를 섞지 않는다. `Notes`는 학습
자료·PDF·문서 탐색용으로 유지하고, Planner 메모는 임시 생각이나 짧은 기록을
텍스트 값으로 저장한다. AI는 `memo_list`, `memo_get`으로 읽고 쓰기 도구로
생성·수정·삭제할 수 있다.

AI 도구와 사용자의 Planner 편집은 같은 `tasks.json`, `events.json`, `memos.json`을
사용하므로 어느 쪽에서 변경해도 다른 쪽에 바로 나타난다.
