# 통합 Plugin Runtime

Codmes의 Chat·Notes·Code·Planner와 Marketplace에서 설치한 KNU는 모두 하나의
Plugin Runtime에서 관리한다. `Surface`는 더 이상 별도 설치 단위나 Registry가
아니다. 사용자가 전환하는 화면은 plugin이 제공하는 `view`다.

## Plugin 종류

| 구분 | 예시 | 배포 | 제거 |
| --- | --- | --- | --- |
| built-in | Chat, Notes, Code, Planner | Codmes 앱과 함께 배포·업데이트 | 불가 |
| community | KNU | Marketplace package로 설치·업데이트·rollback | 가능 |

두 종류 모두 `GET /api/plugins`에서 같은 형태로 반환된다.

```json
{
  "id": "com.codmes.planner",
  "distribution": "builtin",
  "builtIn": true,
  "removable": false,
  "enabled": true,
  "platforms": ["macos", "ios", "android", "windows"],
  "formFactors": ["phone", "tablet", "desktop"],
  "views": [{ "id": "planner", "renderer": "declarative" }],
  "toolNames": ["planner_list", "planner_create"]
}
```

## 실행 흐름

```text
bundled plugin 또는 설치된 community package
  -> Plugin Runtime
     -> views       -> client별 native/declarative renderer
     -> tools       -> 공통 Tool Registry -> AI 도구 호출
     -> storage     -> Workspace plugin-data
     -> MCP         -> 외부 service가 필요한 community plugin
     -> settings    -> plugin 단위 enabled/configuration
```

- Chat·Notes·Code는 native view를 제공한다.
- Planner는 declarative view와 Workspace collection tool을 제공한다.
- KNU는 declarative view, 원격 데이터 API, MCP tool을 함께 제공한다.
- built-in과 community tool 모두 provider type `plugin`으로 공통 Tool Registry에
  등록된다.
- client는 plugin package의 HTML, JavaScript, native binary를 실행하지 않는다.
- `platforms`/`formFactors`는 view 표시 가능 여부만 결정한다. 서버-side LLM,
  tool, storage, MCP 등록과 Workspace 설치 상태에는 영향을 주지 않는다.

## API

- `GET /api/plugins`: built-in/community plugin 전체 조회
- `POST /api/plugins/:id/configuration`: plugin 활성화 상태 변경
- `GET /api/plugins/:id/view-document`: declarative view 문서 조회
- `/api/plugins/:id/collections/...`: Workspace collection 조회·변경
- `/api/plugins/:id/auth/...`: plugin service 로그인 상태·로그인·로그아웃
- `/api/plugins/:id/mcp-tools/...`: MCP catalog 발견과 Workspace별 승인 스냅샷 관리
- `/api/marketplace/plugins/...`: community plugin 설치·업데이트
- `DELETE /api/plugins/:id`: community plugin 제거

`/api/surfaces`와 별도 Surface Registry는 존재하지 않는다. 이전 API를 새 API로
중계하는 호환 adapter도 두지 않는다. 서버와 각 client는 `/api/plugins`만
사용한다.

## 저장 위치

- Runtime 설정: `.codmes/plugin-runtime/settings.json`
- Community 설치: `.codmes/plugins/<plugin-id>/`
- Plugin Workspace 데이터: `.codmes/plugin-data/<plugin-id>/`
- 외부 서비스 데이터와 계정: 해당 plugin service가 소유
- Codmes에 저장하는 service credential: Codmes 서버의 credential store가 소유

Planner는 built-in이므로 `.codmes/plugins` 설치 metadata가 없지만, 데이터는
`.codmes/plugin-data/com.codmes.planner`에 저장한다. 따라서 같은 Workspace
서버에 연결한 모든 지원 client가 같은 Planner 데이터를 본다.
