# Declarative Plugin Surface Contract

Codmes plugin Surface는 외부 웹사이트를 WebView/iframe으로 표시하지 않는다.
plugin package가 화면 구조와 제한된 action, data binding을 선언하고 plugin
backend는 domain data만 JSON으로 제공한다. Codmes 서버가 두 입력을 결합하며
클라이언트는 macOS/iOS, Android, Windows의 네이티브 UI로 렌더링한다.

이 문서의 기본 binding과 presentation은 v1/v2가 공유한다. collection editor와
field type을 선언하는 v2 추가 계약은 [Declarative Surface v2](./surface-v2.md)를
참고한다.

```text
plugin package surface.json ─┐
                             ├→ Codmes binding compiler/validation
plugin backend domain JSON ──┘  → Surface document → SwiftUI renderer
```

따라서 standalone KNU 웹과 Codmes KNU Surface는 같은 backend를 사용할 수
있지만 서로 다른 frontend다. Codmes는 KNU의 HTML, CSS, JavaScript를 내려받거나
실행하지 않는다.

## Manifest

```json
{
  "surface": {
    "id": "knu",
    "type": "declarative",
    "title": "KNU",
    "upstreamUrl": "http://127.0.0.1:8000",
    "entryPath": "/api/notices",
    "ui": "surface.json"
  }
}
```

설치 시 `ui` 경로는 plugin package 밖으로 벗어날 수 없다. Codmes는 파일을
검증하여 설치 manifest에 포함하고 각 route의 `dataSources`를 upstream에
요청한다. 인증 route에는 해당 plugin 사용자 credential만 전달하며 Workspace
bearer와 MCP service credential은 전달하지 않는다. data 응답은 source마다 최대
2 MiB, collection item은 최대 500개로 제한한다.

## Plugin-owned route와 binding

`surface.json`은 native navigation과 data source, 최종 document mapping을 함께
정의한다. backend 응답 필드가 바뀌면 plugin 개발자가 이 파일의 path mapping을
업데이트한다.

```json
{
  "schemaVersion": 1,
  "routes": [
    {
      "id": "notices",
      "title": "공지",
      "icon": "bell",
      "requiresAuth": false,
      "dataSources": [
        { "id": "notices", "path": "/api/notices?limit=100" }
      ],
      "document": {
        "schemaVersion": 1,
        "presentation": "collection",
        "collectionStyle": "cards",
        "title": "공지사항",
        "subtitle": { "literal": "최신 공지를 확인하세요." },
        "collection": {
          "source": "notices.notices",
          "item": {
            "id": "url",
            "title": "title",
            "eyebrow": {"join": ["source_name", "department"], "separator": " · "},
            "meta": "posted_at",
            "badge": "deadline_label",
            "badgeTone": "deadline_tone",
            "systemImage": {"literal": "bell"},
            "body": { "coalesce": ["summary", "content"] },
            "action": { "type": "openURL", "url": "url" }
          }
        }
      }
    }
  ]
}
```

binding value는 현재 문자열 path, `literal`, `coalesce`, `join`, `default`,
boolean의 `trueValue`/`falseValue`, `suffix`를 지원한다. `$`로 시작한 path는
현재 item이 아니라 모든 data source의 root를 참조한다. collection은 source
mapping과 static item을, dashboard는 `keyValue`, `table` 및 같은 형태의 group
mapping을 지원한다.

## Native navigation과 로그인

- macOS와 가로 iPad는 route 목록을 Notes처럼 왼쪽에 상시 표시한다.
- iPhone과 좁은 iPad는 sidebar에서 항목을 선택한 뒤 native content hierarchy로
  들어간다.
- plugin sidebar 상단은 Surface 이름, 로그인 LED/계정명, 작은
  로그인·로그아웃 버튼만 표시한다.
- 로그인 버튼은 `Settings → Surfaces → 해당 plugin` 상세를 연다. Surface 목록의
  설정 아이콘도 같은 상세로 이동하므로 sidebar 전용 임시 로그인 UI를 만들지
  않는다.
- Surface 상세를 열 때 Settings category sidebar는 유지하고 main 영역만
  교체한다. 상세 우상단의 닫기 버튼은 Surface 목록으로 복귀한다.
- plugin 인증 상세는 Model Config의 계정 연결 패턴과 같은 연결 상태, 저장된
  계정, Connect/Disconnect 구조를 사용한다. 사용자명과 비밀번호는 plugin의
  `loginPath`로 한 번 전달되며 비밀번호는 저장하지 않는다.
- 인증 작업과 상태는 navigation/sidebar와 설정 상세가 공유하는 app-level
  store가 소유한다. 설정을 닫아도 진행 중 요청을 취소하지 않으며, sidebar의
  LED·진행 문구·계정명은 설정 화면과 실시간으로 동일하게 갱신한다.
- 인증 요청 중에는 credential form을 숨기고 독립된 progress state를 표시한다.
  인증이 완료된 뒤의 background data sync는 로그인 상태를 덮어쓰지 않고
  계정명 옆의 작은 보조 indicator로 표현한다.
- KNU plugin의 `loginPath`는 KNU PICK 자체 계정이 아니라 공주대 포털 학번과
  비밀번호를 직접 검증한다. 검증된 같은 요청의 background task에서 KNUIS와
  Canvas/LearningX LMS를 동기화한 뒤 비밀번호를 폐기하고, 학번을 주체로 한
  만료 없는 plugin session token만 Codmes 서버에 저장한다.
- KNU 서버는 검증된 포털 browser session을 background sync에 재사용해
  이름·학과·학년·시간표·졸업학점·성적분포·누적성적을 DB에 저장한다.
  같은 일회성 비밀번호로 LMS 세션을 만들어 과목·과제·공지·미시청 강의를
  동기화하지만 비밀번호나 임시 browser session은 영속화하지 않는다. Apple
  client는 비밀번호나 portal cookie를 받지 않고 완료된 데이터만 표시한다.
- Codmes 서버는 `tokenField`로 받은 JWT만 server-side credential store에
  저장하고 `requiresAuth` route 요청에 Bearer로 붙인다. 토큰 값은 Apple
  client나 Surface document에 노출하지 않는다.

## 컴파일된 Surface document v1

원격 data source가 일시적으로 응답하지 않아도 route의 UI 구조는 유지한다.
Codmes 서버는 실패한 source에 빈 payload를 대입해 document를 컴파일하고,
다음 `dataState`를 추가한다.

```json
{
  "dataState": {
    "status": "unavailable",
    "errors": [
      {
        "sourceId": "notices",
        "message": "The plugin service is unavailable. Check that it is running and retry.",
        "retryable": true
      }
    ]
  }
}
```

`partial`은 여러 source 중 일부만 실패했을 때, `unavailable`은 모두 실패했을
때 사용한다. Client는 route 제목과 화면 구조를 먼저 표시하고 내부에 오류
안내와 재시도 조작을 제공한다. 실패한 upstream URL이나 credential은 document에
노출하지 않는다.

이 문서는 plugin backend가 직접 반환하는 계약이 아니라 Codmes가
`surface.json`과 domain data를 결합한 뒤 호환되는 native client에 보내는 내부 렌더링
계약이다. `collection`, `dashboard`, `calendar` presentation을 지원한다.

```json
{
  "schemaVersion": 1,
  "presentation": "collection",
  "collectionStyle": "cards",
  "title": "공지사항",
  "subtitle": "최신 학사·일반 공지를 확인하세요.",
  "search": {
    "placeholder": "제목·내용으로 검색",
    "fields": ["title", "body", "subtitle", "tags"]
  },
  "filters": [
    {
      "id": "category",
      "label": "카테고리",
      "style": "chips",
      "options": [
        { "value": "__all__", "label": "전체" },
        { "value": "장학", "label": "장학" }
      ]
    }
  ],
  "emptyState": {
    "title": "표시할 공지사항이 없어요.",
    "systemImage": "doc.text.magnifyingglass"
  },
  "items": [
    {
      "id": "stable-item-id",
      "title": "2026학년도 장학금 신청 안내",
      "subtitle": "학생지원과 · 2026-07-28",
      "eyebrow": "공주대학교 · 컴퓨터공학과",
      "meta": "2026-07-28",
      "badge": "D-3",
      "badgeTone": "danger",
      "systemImage": "bell",
      "body": "신청 기간과 제출 서류를 확인하세요.",
      "tags": ["재학생", "장학금"],
      "filterValues": { "category": "장학" },
      "action": {
        "type": "openURL",
        "url": "https://example.edu/notice/1"
      }
    }
  ]
}
```

- 검색과 filter는 client에서 즉시 수행한다.
- `collectionStyle`은 `list` 또는 `cards`다. 생략하면 기존 compact list를
  사용하며, `cards`는 공지·과제처럼 출처와 상태를 한눈에 비교해야 하는 화면에
  사용한다.
- card item의 `eyebrow`는 출처·학과 같은 상단 문맥, `meta`는 게시일·마감일,
  `badge`는 `D-3` 같은 짧은 상태를 표시한다. `badgeTone`은 `accent`, `danger`,
  `warning`, `success`, `neutral` 중 하나이며 `systemImage`는 행의 의미 아이콘이다.
- 이 필드는 React/CSS를 실행하는 확장점이 아니다. plugin은 정보 계층만 선언하고
  실제 간격, 글꼴, 색상, hover와 접근성은 Codmes의 SwiftUI renderer가 통일한다.
- `__all__` filter option은 해당 filter를 적용하지 않는 예약 값이다.
- v1 action은 `http`/`https` `openURL`만 허용한다.
- plugin package가 선언한 system image 이름은 client가 지원하지 않으면 기본 icon으로
  대체할 수 있다.
- loading, empty, error, pull-to-refresh 표현은 Codmes가 소유한다.

### Calendar presentation

일정 plugin은 일반 목록을 흉내 내지 않고 `calendar`를 선언할 수 있다. collection
item binding에 표준 시간 의미만 추가하고, 실제 월간 grid와 날짜 선택 UI는 Codmes
client가 플랫폼에 맞게 렌더링한다.

```json
{
  "schemaVersion": 1,
  "presentation": "calendar",
  "title": "Calendar",
  "editor": {
    "collection": "events"
  },
  "collection": {
    "source": "events.items",
    "item": {
      "id": "id",
      "title": "title",
      "body": "notes",
      "temporal": {
        "startsAt": "startsAt",
        "endsAt": "endsAt",
        "allDay": "allDay"
      }
    }
  }
}
```

- `startsAt`은 필수이며 ISO 8601 날짜 또는 날짜·시간 문자열을 사용한다.
- `endsAt`은 선택이고 `allDay`는 종일 일정 표시를 제어한다.
- `editor.collection`을 선언하면 Codmes가 해당 collection을 대상으로 native
  생성·편집·삭제 UI를 활성화한다. 생략하면 calendar는 읽기 전용이다.
- plugin은 일정 데이터와 binding을 소유하고 Codmes는 월 이동, 날짜 선택, 접근성,
  플랫폼별 레이아웃을 소유한다.
- 공식 Calendar renderer는 생성·편집 sheet도 제공한다. 이 화면에서 사용자가 누른
  저장은 직접 조작이므로 collection API로 즉시 반영한다. 같은 collection을 AI가
  tool provider로 변경할 때는 Safe 모드 승인을 별도로 적용한다.

### Dashboard presentation

시간표나 성적표처럼 행과 열의 의미를 보존해야 하는 화면은 `dashboard`를 사용한다.
Codmes가 SwiftUI로 섹션과 표를 직접 렌더링하며 plugin HTML이나 JavaScript는 실행하지
않는다. 표는 좁은 iPhone 화면에서 가로 스크롤되고 macOS/iPad에서는 가용 폭을 사용한다.

```json
{
  "schemaVersion": 1,
  "presentation": "dashboard",
  "title": "포털",
  "subtitle": "통합정보시스템에서 동기화한 정보입니다.",
  "filters": [],
  "items": [],
  "sections": [
    {
      "id": "profile",
      "title": "학적 정보",
      "systemImage": "person.text.rectangle",
      "kind": "keyValue",
      "fields": [
        { "id": "student-id", "label": "학번", "value": "20260001" }
      ]
    },
    {
      "id": "timetable",
      "title": "주간 시간표",
      "systemImage": "calendar",
      "kind": "table",
      "columns": ["교시", "월요일", "화요일"],
      "rows": [["1교시", "자료구조", ""]]
    }
  ]
}
```

- 허용 section kind는 v1에서 `keyValue`, `table`이다.
- `keyValue.fields`는 최대 100개, `table.columns`는 최대 50개,
  `table.rows`는 최대 1,000개다.
- plugin binding은 문자열 데이터의 의미와 배치를 선언하고 글꼴·색상·플랫폼
  표현은 Codmes가 소유한다.

## 확장 원칙

새 presentation이나 action은 allowlist에 명시적으로 추가한다. plugin이 임의
Swift 코드, JavaScript, native binary를 client 안에서 실행하는 escape hatch는
제공하지 않는다.

향후 후보:

- detail/navigation stack
- form과 credential setup command
- grouped collection
- Codmes 문서/file picker action
- pagination과 server-side search

이 기능들은 실제 plugin UX가 필요해지는 시점에 공통 규격으로 추가하며, 특정
plugin만을 위한 client 코드 분기는 만들지 않는다.
