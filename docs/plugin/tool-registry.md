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

## Plugin Manifest v1의 `tools.json`

현재 Marketplace Manifest v1에서 실제 설치 가능한 plugin tool은 자기 plugin에
등록된 MCP 도구를 이름과 schema로 선언하는 방식이다.

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

MCP 연결 후 서버가 반환한 실제 `tools/list`와 선언을 provider 내부 이름으로
연결한다. 모델에는 자동 생성된 `mcp__...` 이름 대신 package가 선언한 안정적인
이름이 표시된다. 선언하지 않은 MCP 도구는 기존 자동 이름으로 계속 사용할 수 있다.

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
- Planner의 할 일·달력·메모처럼 서로 다른 schema와 adapter routing 단위 테스트
- plugin collection CRUD, schema 검사, 원자적 저장과 쓰기 미리보기

다음 단계:

1. Planner package의 schema migration 규격
2. 앱 설정에서 plugin별 도구·권한·비활성화 관리
3. 실행 감사 로그와 plugin별 rate limit
