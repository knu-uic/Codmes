# Common Tool Registry

Codmes의 native 기능, Marketplace plugin, 외부 MCP는 AI에게 모두 “도구”로
보이지만 실제 실행 주체와 입력값은 서로 다르다. Common Tool Registry는 입력을
통일하는 규격이 아니라, 서로 다른 도구를 같은 방식으로 등록·필터링·승인·실행하기
위한 공통 봉투다.

## 공통 descriptor

```json
{
  "name": "calendar_create",
  "description": "일정을 생성합니다.",
  "inputSchema": {
    "type": "object",
    "properties": {
      "title": {"type": "string"},
      "startsAt": {"type": "string", "format": "date-time"},
      "endsAt": {"type": "string", "format": "date-time"}
    },
    "required": ["title", "startsAt", "endsAt"]
  },
  "provider": {
    "type": "plugin",
    "id": "com.codmes.planner",
    "tool": "event.create"
  },
  "surfaces": ["calendar"],
  "requiresApproval": true,
  "readOnly": false
}
```

공통 필드는 다음 역할을 한다.

- `name`: 모델에 노출되는 충돌 없는 이름
- `description`: 모델이 호출 여부를 판단하는 설명
- `inputSchema`: 해당 도구만의 JSON Schema
- `provider`: 실제 실행 주체와 내부 도구 이름
- `surfaces`: 노출 가능한 Surface
- `requiresApproval`: 실행 전 사용자 승인 필요 여부
- `readOnly`: 읽기 전용 여부

예를 들어 Notes 검색은 `query`, 선택 `folderId`, `limit`이 필요하지만 Calendar
생성은 `title`, `startsAt`, `endsAt`이 필요하다. Registry는 두 입력을 같게 만들지
않고 각각의 schema를 그대로 모델에 전달한다.

## provider

### `native`

Codmes Workspace 서버가 직접 실행한다. 현재 workspace 검색, Notes 파일 읽기,
DocSearch, conversation recall, Code 도구가 여기에 해당한다.

```json
{
  "type": "native",
  "id": "workspace",
  "tool": "notes.search"
}
```

### `mcp`

외부 서비스가 MCP 서버에서 실행한다. KNU, Google Calendar처럼 데이터와 비즈니스
로직이 외부 서비스에 있을 때 사용한다.

```json
{
  "type": "mcp",
  "id": "knu",
  "tool": "knu_search_notice_details"
}
```

### `plugin`

Calendar·Planner처럼 Codmes Workspace 저장소와 공식 native component를 사용하는
plugin용 실행 adapter다. `storage.json`에 collection schema를 선언하고
`collection.<id>.<operation>` 도구로 접근한다.

```json
{
  "type": "plugin",
  "id": "com.codmes.planner",
  "tool": "event.create"
}
```

## MCP 서버가 직접 제공하는 도구 catalog

MCP가 `tools/list`로 반환하는 이름·설명·`inputSchema`가 실행 도구의 원본이다.
Codmes 계층형 catalog에 안정적인 공개 이름과 그룹을 제공하려면 표준 MCP `_meta`에
선택적인 확장 정보를 넣는다. 다른 MCP client는 모르는 metadata를 무시하므로 같은
서버를 Hermes 등에서도 그대로 사용할 수 있다.

플러그인 package는 MCP 도구 목록을 고정하지 않는다. 대신 Codmes Workspace가
발견한 catalog와 승인된 이름을 `.codmes/plugin-runtime/mcp-tool-consent.json`에
로컬로 저장한다. 이 상태는 Marketplace 서명이 아니라 해당 Workspace 사용자의
선택이다.

최초 연결에서 모든 도구는 대기 상태다. `Settings > Plugins > <plugin> > MCP tools`에서
`Discover`를 눌러 catalog를 갱신하고 각 도구를 켜면 그때부터 계층형 도구 탐색과
실행에 참여한다. 이후 MCP가 새 도구를 광고하면 기존 승인은 유지되지만
새 이름만 다시 `Waiting for approval`로 남는다.

```json
{
  "name": "knu_search_notice_details",
  "description": "공주대학교 공지의 구체적인 근거를 검색합니다.",
  "inputSchema": {"type": "object", "properties": {}},
  "annotations": {"readOnlyHint": true, "destructiveHint": false},
  "_meta": {
    "com.codmes/tool": {
      "publicName": "knu_search_notice_details",
      "group": "knu.notices",
      "groupDescriptions": {
        "knu": "공주대학교 데이터를 조회합니다.",
        "knu.notices": "학교·학과 공지를 검색합니다."
      }
    }
  }
}
```

`publicName`이 없거나 안전하지 않거나 이미 등록된 이름과 충돌하면 Codmes는
`mcp__<server>__<tool>` 이름을 사용한다. MCP metadata는 도구를 읽기 전용으로
설명할 수 있지만 Codmes의 승인 정책이나 Surface 접근 범위를 낮출 수 없다. 그
보안 정책은 설치된 plugin manifest 또는 Workspace 설정이 계속 소유한다.
승인되지 않은 이름은 유효한 metadata가 있어도 등록 전에 보류된다. 이름을 승인해도
각 호출은 도구의 `requiresApproval`과 현재 Safe/Full mode 정책을 다시 거친다.

## 선택적·호환용 `tools.json`

`tools.json`은 MCP가 위 metadata를 제공하지 않는 기존 서버의 공개 이름·그룹을
보완하거나 Workspace collection 도구를 선언할 때 계속 사용할 수 있다.

```json
{
  "schemaVersion": 1,
  "tools": [
    {
      "name": "knu_search_notice_details",
      "description": "공주대학교 공지의 구체적인 근거를 검색합니다.",
      "inputSchema": {
        "type": "object",
        "properties": {
          "query": {"type": "string"}
        },
        "required": ["query"]
      },
      "provider": {
        "type": "mcp",
        "server": "knu",
        "tool": "knu_search_notice_details"
      },
      "requiresApproval": true,
      "readOnly": true
    }
  ]
}
```

`plugin.json`에서 다음과 같이 참조한다.

```json
{
  "tools": "tools.json"
}
```

설치 시 Codmes는 다음을 검증한다.

- JSON Schema가 object 입력인지
- 공개 tool 이름과 provider 내부 이름이 안전한지
- tool이 plugin 자신의 MCP server만 참조하는지
- tool이 plugin 자신의 Surface 범위를 벗어나지 않는지
- 중복 이름과 과도하게 큰 schema가 없는지

MCP 연결 후 서버가 반환한 실제 `tools/list`와 정적 선언을 provider 내부 이름으로
연결한다. 서버가 `com.codmes/tool` metadata를 제공하면 실시간 설명·schema·그룹을
우선 사용한다. metadata와 정적 선언이 모두 없는 MCP 도구는 자동 생성된
`mcp__...` 이름으로 계속 사용할 수 있다.

## 호출 흐름

```text
사용자: “이번 학기 수강 철회 기간 알려줘”
  → 모델이 knu_search_notice_details({query: "수강 철회 기간", category: "수강"}) 선택
  → Registry가 provider=mcp, server=knu, tool=knu_search_notice_details 확인
  → Surface/disabled/approval 정책 확인
  → 승인 후 Codmes MCP client가 KNU 서버 호출
  → 근거·URL 반환
  → 모델이 출처를 이용해 답변
```

Calendar의 향후 호출도 Registry 이후 provider만 달라진다.

```text
calendar_create({title, startsAt, endsAt})
  → provider=plugin
  → 사용자 승인
  → Calendar collection storage adapter
  → Workspace에 event 저장
  → 연결된 호환 native client에서 같은 일정 표시
```

## Workspace collection storage

```json
{
  "schemaVersion": 1,
  "collections": [{
    "id": "events",
    "itemSchema": {
      "type": "object",
      "properties": {
        "title": {"type": "string"},
        "startsAt": {"type": "string"},
        "endsAt": {"type": "string"}
      },
      "required": ["title", "startsAt", "endsAt"]
    }
  }]
}
```

`plugin.json`은 `"storage": "storage.json"`으로 참조하고 도구 provider는
`collection.events.list|get|create|update|delete` 중 하나를 사용한다. 데이터는
`.codmes/plugin-data/<plugin-id>/<collection>.json`에 격리한다. 같은 collection의
쓰기는 직렬화하고 임시 파일을 rename해 원자적으로 교체한다.

쓰기 도구는 `requiresApproval: true`로 선언한다. Safe 모드에서는 승인 요청에
collection, operation, item id, `before`, `after` 미리보기를 포함하고 승인된
재개 요청에서만 실제로 저장한다. Full 모드는 Workspace 내부 plugin 쓰기를 즉시
실행한다. 원격 MCP 및 보안 정책 승인은 별도로 적용된다. 읽기 API는
`GET /api/plugins/:pluginId/collections/:collectionId`다.

## 현재 구현 범위와 다음 단계

현재 완료:

- 공통 descriptor와 `native`·`plugin`·`mcp` provider adapter
- OpenAI function schema 변환
- native와 MCP의 Registry 기반 모델 노출
- plugin `tools.json` package 포함·설치 검증
- plugin이 선언한 MCP 공개 이름 연결
- Tool Discovery에서 설치 plugin 도구 검색
- Surface → 기능 그룹 → 실제 도구의 계층형 Tool Discovery와 단계 건너뛰기 방지
- Planner의 할 일·달력·메모처럼 서로 다른 schema와 adapter routing 단위 테스트
- plugin collection CRUD, schema 검사, 원자적 저장과 쓰기 미리보기

## 계층형 Tool Discovery

모델에는 설치된 모든 도구 schema를 한 번에 보내지 않는다. 첫 요청에는
`tool_discovery`와 공통 recall 도구만 제공하며, 모델은 아래처럼 한 단계씩
탐색한다.

```text
tool_discovery()             → notes / code / planner / knu
tool_discovery(path="knu")  → knu.notices / knu.lms / knu.portal / knu.account
tool_discovery(path="knu.portal") → 포털 도구만 현재 turn에 활성화
tool_discovery(path="planner") → planner.tasks / planner.calendar / planner.memos
```

서버는 이전 결과에서 공개되지 않은 단계를 건너뛰지 못하게 한다. 작은 모델이
`knu.notices`를 바로 요청해도 실제 도구를 즉시 노출하지 않고 다음 안전한 한 단계만
돌려준다. 현재 Surface와 route는 `nextSuggestedPath`를 정하는 문맥일 뿐이며,
도구를 자동 실행하거나 다른 그룹 사용을 막지 않는다. 따라서 LMS 화면에서 누적
성적을 물으면 모델이 `knu.portal`을 선택할 수 있다.

한 요청 안에서는 발견한 도구와 각 도구의 실행 결과를 계속 유지한다. 따라서
"LMS 과제 목록을 Planner에 추가해 줘"라는 요청은 `knu.lms`를 발견해 과제를
조회한 뒤, 같은 turn에서 `planner.tasks`를 발견해 `planner_create`를 호출할 수
있다. 모델은 한 응답에서 여러 도구를 호출하거나, 첫 결과를 읽고 다음 호출의
인자를 구성할 수도 있다. 공지 두 건에 서로 다른 상세 검색이 필요할 때 같은
공지 검색 도구를 반복 호출하는 것도 허용한다.

`requiresApproval: true`인 쓰기 도구도 모델이 발견하고 호출 후보로 선택할 수
있다. 다만 실제 변경 직전에 실행이 멈추고 사용자 승인을 기다린다. 승인 후에는
앞서 공개된 도구와 이전 결과를 보존한 채 모델 실행을 재개한다. 즉, "도구가
필요한지 판단하는 단계"와 "그 도구가 실제로 데이터를 변경해도 되는지 승인하는
단계"를 분리한다.

## 작업 기반 실행 예산

Surface는 사용자가 보고 있는 UI 문맥이며, 도구 반복 예산을 고정하는 기준이
아니다. Chat에서 시작해도 Notes와 Planner를 함께 사용하면 `cross-surface`, Code
도구를 발견하면 `code` 프로필로 실행 예산이 자동 승격된다.

| 실행 프로필 | 도구 라운드 | 적용 조건 |
| --- | ---: | --- |
| `standard` | 8 | 일반 대화와 단일 기능 조회 |
| `cross-surface` | 16 | 서로 다른 기능 그룹을 함께 사용하는 작업 |
| `code` | 32 | Code 그룹을 발견하거나 Code 도구를 사용하는 작업 |
| `code-deep` | 64 | 코드 검사 실패 후 분석·수정 반복이 필요한 작업 |

라운드는 도구 개수가 아니라 모델이 도구 실행을 요청한 응답 횟수다. 한 응답에서
서로 독립적인 도구 여러 개를 요청하면 한 라운드로 계산한다. 같은 도구와 완전히
같은 인자를 세 번 연속 요청하면 진전 없는 반복으로 판단해 중단한다. 서로 다른
학과 공지 검색처럼 인자가 다른 반복 호출은 허용한다.

다음 단계:

1. Planner package의 schema migration 규격
2. 앱 설정에서 plugin별 도구·권한·비활성화 관리
3. 실행 감사 로그와 plugin별 rate limit
