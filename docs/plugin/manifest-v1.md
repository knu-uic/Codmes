# Plugin Manifest v1

Codmes의 선택형 plugin은 서버 Workspace에 한 번 설치하며, 연결된 macOS/iOS/Android/Windows
클라이언트가 같은 설치 상태를 공유한다. 현재 PoC의 설치 단위는 웹 Surface와 MCP
도구 한 묶음이다. Codmes 계정이나 marketplace 계정은 필요하지 않다.

## Manifest

```json
{
  "schemaVersion": 1,
  "id": "kr.ac.kongju.knu",
  "version": "0.3.1",
  "name": "KNU",
  "platforms": ["macos", "ios", "android", "windows"],
  "formFactors": ["phone", "tablet", "desktop"],
  "permissions": ["network:127.0.0.1"],
  "dataVersion": 1,
  "migrations": "migrations.json",
  "tools": "tools.json",
  "surface": {
    "id": "knu",
    "type": "declarative",
    "title": "KNU",
    "upstreamUrl": "http://127.0.0.1:8000",
    "entryPath": "/api/notices",
    "ui": "surface.json",
    "auth": {
      "type": "password",
      "credentialId": "knu-user-session",
      "loginPath": "/api/auth/portal-login",
      "logoutPath": "/api/auth/logout",
      "statusPath": "/api/me",
      "usernameField": "student_id",
      "passwordField": "password",
      "tokenField": "access_token"
    }
  },
  "mcp": {
    "name": "knu",
    "transport": "streamable_http",
    "url": "http://127.0.0.1:8000/api/mcp",
    "surfaces": ["knu"],
    "credentialId": "knu-user-session",
    "requiresApproval": true
  }
}
```

- `id`는 reverse-domain 형식, `version`은 semver다.
- `platforms`는 Surface/UI가 지원하는 OS인 `macos`, `ios`, `android`, `windows`를,
  `formFactors`는 `phone`, `tablet`, `desktop`을 선언한다. iPhone은 `ios + phone`,
  iPad는 `ios + tablet`, Android phone은 `android + phone`, Android tablet은
  `android + tablet`, Mac은 `macos + desktop`, Windows는 `windows + desktop`이다.
  이 값은 서버-side LLM/tool/MCP 호환성이 아니라 client Surface/UI 호환성이다.
- 기존 `ipados`는 읽을 때 `ios + tablet`로 정규화한다. `formFactors`가 없는 기존
  manifest는 `macos -> desktop`, `ios -> phone`, `ipados -> tablet`로 migration한다.
- 하나의 `.codmes-plugin` package를 Workspace에 설치한다. 현재 기기에서 UI가
  호환되지 않아도 설치·업데이트·제거는 가능하며, 해당 기기에서 Surface만 숨긴다.
- Marketplace Surface는 현재 `declarative`만 허용한다.
- Surface와 MCP URL은 HTTPS가 원칙이며 loopback 개발 서비스만 HTTP를 허용한다.
- MCP는 반드시 자기 Surface id를 포함한다. 다른 Surface 권한은 Manifest v1에서
  자동 부여하지 않는다.
- 인증 없는 MCP는 loopback에서만 허용한다. KNU는 Surface와 MCP가
  `credentialId: "knu-user-session"`을 공유해 포털 로그인 token을 Bearer로
  보낸다.
- 설치는 Manifest와 `surface.ui`가 가리키는 declarative JSON을 검증해 하나의
  설치 manifest로 저장한다. 임의 native binary나 JavaScript를 Codmes process
  안에서 실행하지 않는다.
- `surface.ui`는 package 내부 JSON 파일 또는 같은 구조의 object다. 여기에 선언한
  route가 native sidebar/계층형 내비게이션 항목이 된다. `requiresAuth`인 route는
  사용자 토큰이 없으면 Codmes가 잠금 화면을 반환한다.
- `surface.auth`는 로그인·상태·로그아웃 endpoint 계약을 선언한다. 비밀번호는
  로그인 요청에만 사용하고 저장하지 않으며, 반환된 사용자 session token만 Codmes
  서버 credential store에 저장한다. MCP가 같은 `credentialId`를 선언하면 한 번의
  로그인으로 두 경로가 token을 공유하고 로그아웃할 때 함께 폐기한다.
- `tools`는 선택적인 package 내부 `tools.json`을 가리킨다. Workspace collection
  도구나 이전 MCP 서버의 정적 선언에 사용할 수 있다. 최신 MCP 서버는 `tools/list`의
  설명·input schema와 `com.codmes/tool` 메타데이터로 공개 이름과 계층 그룹을 직접
  제공할 수 있으므로 중복 `tools.json`이 필요하지 않다. 어느 방식이든 plugin은
  다른 plugin, MCP server나 Surface 권한을 요청할 수 없다. 자세한 규격은
  [Common Tool Registry](./tool-registry.md)를 따른다.
- plugin MCP의 도구 이름·설명·schema는 manifest에 복사하지 않는다. Codmes가
  `tools/list`로 처음 발견한 도구는 Workspace별 대기 목록에 넣고, Plugin 설정에서
  사용자가 승인한 이름만 AI에게 노출한다. 원격 MCP가 나중에 도구를 추가해도
  plugin과 Marketplace package를 다시 배포할 필요는 없지만, 새 도구는 자동 승인되지
  않는다. `mcp.allowedTools`처럼 package가 자기 권한을 스스로 승인하는 필드는 사용하지
  않는다.
- `storage`는 선택적인 package 내부 `storage.json`이다. Planner처럼
  외부 backend가 필요 없는 plugin은 MCP 없이 Surface + storage + plugin tool로
  구성할 수 있다.
- `dataVersion`은 plugin 코드 버전과 별개인 Workspace collection schema 버전이다.
  생략하면 `1`이다. 저장 구조가 바뀔 때만 1씩 올린다.
- `migrations`는 선택적인 package 내부 `migrations.json` 또는 같은 구조의
  object다. `dataVersion`을 올리는 업데이트는 중간 단계가 빠짐없이 선언되어야
  하며, 자세한 규격은 [Plugin 데이터 migration](./data-migrations.md)을 따른다.

## 설치 수명주기

```sh
codmes plugin marketplace --root /path/to/workspace
codmes plugin install kr.ac.kongju.knu --root /path/to/workspace
codmes plugin update kr.ac.kongju.knu --root /path/to/workspace
codmes plugin rollback kr.ac.kongju.knu --root /path/to/workspace

# 개발 중인 로컬 source 설치
codmes plugin install /path/to/plugin-package --root /path/to/workspace
codmes plugin list --root /path/to/workspace
codmes plugin remove kr.ac.kongju.knu --root /path/to/workspace
```

KNU 설치 후 plugin 설정에서 포털 계정으로 로그인한다. 일반 사용자는 KNU 서버의
`MCP_AUTH_TOKEN`을 알거나 Codmes에 직접 등록하지 않는다. 이 값은 운영자용
loopback 점검 경로에만 사용한다.

설치와 제거는 Surface manifest와 MCP config를 함께 갱신하며 실패 시 이전 상태로
복구한다. Marketplace 설치는 package SHA-256과 metadata를 확인하고 버전별
디렉터리에 staging한 뒤 활성 버전 포인터를 바꾼다. 앱의 `Settings > Plugins`에서
같은 설치·업데이트·롤백 작업을 실행할 수 있다. 자세한 내용은
[Plugin Marketplace](./marketplace.md)를 따른다.

## Declarative Surface 보안

Codmes client는 plugin package의 HTML/JavaScript를 실행하지 않는다. Codmes 서버는 설치된 UI binding에
plugin backend의 domain JSON을 대입해 Surface document를 만든다. 각 client는
인증된 Codmes API를 통해 이 문서를 받고 SwiftUI renderer로 허용된 component와
action만 표시한다. Workspace bearer와 MCP credential은 plugin data endpoint로
전달하지 않는다.
스키마와 제한은 [Declarative Plugin Surface Contract](./surface-ui.md)를 따른다.

## KNU PoC 범위

- 공개 공지 목록 Surface
- 공지 검색/상세 MCP
- MCP 호출별 Codmes 승인
- Codmes Surface와 MCP는 로컬 FastAPI만으로 실행할 수 있으며 Docker는 선택 사항
- KNU 계정 로그인, 포털, LMS 데이터는 KNU가 소유한다. Codmes는 native 설정
  화면과 sidebar 상태만 제공한다.
- Marketplace는 package 다운로드, SHA-256·publisher 서명 검증, 새 권한 재동의,
  취약 버전 차단, release note, 업데이트와 호환 가능한 직전 버전 롤백을 제공한다.
  Codmes 계정 기반 클라우드 동기화는 아직 포함하지 않는다.
