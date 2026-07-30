# Plugin Manifest v1

Codmes의 선택형 plugin은 서버 Workspace에 한 번 설치하며, 연결된 macOS/iOS
클라이언트가 같은 설치 상태를 공유한다. 현재 PoC의 설치 단위는 웹 Surface와 MCP
도구 한 묶음이다. Codmes 계정이나 marketplace 계정은 필요하지 않다.

## Manifest

```json
{
  "schemaVersion": 1,
  "id": "kr.ac.kongju.knu",
  "version": "0.3.0",
  "name": "KNU",
  "platforms": ["macos", "ios", "ipados"],
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
    "credentialId": "knu",
    "requiresApproval": true
  }
}
```

- `id`는 reverse-domain 형식, `version`은 semver다.
- Marketplace Surface는 현재 `declarative`만 허용한다.
- Surface와 MCP URL은 HTTPS가 원칙이며 loopback 개발 서비스만 HTTP를 허용한다.
- MCP는 반드시 자기 Surface id를 포함한다. 다른 Surface 권한은 Manifest v1에서
  자동 부여하지 않는다.
- 인증 없는 MCP는 loopback에서만 허용한다. KNU는 로컬 개발에서도
  `credentialId: "knu"`를 사용해 FastAPI MCP로 Bearer를 직접 보낸다.
- 설치는 Manifest와 `surface.ui`가 가리키는 declarative JSON을 검증해 하나의
  설치 manifest로 저장한다. 임의 native binary나 JavaScript를 Codmes process
  안에서 실행하지 않는다.
- `surface.ui`는 package 내부 JSON 파일 또는 같은 구조의 object다. 여기에 선언한
  route가 native sidebar/계층형 내비게이션 항목이 된다. `requiresAuth`인 route는
  사용자 토큰이 없으면 Codmes가 잠금 화면을 반환한다.
- `surface.auth`는 로그인 endpoint 계약만 선언한다. 비밀번호는 로그인 요청에만
  사용하고 저장하지 않으며, 반환된 사용자 JWT만 Codmes 서버 credential store에
  저장한다.
- `tools`는 package 내부 `tools.json`을 가리킨다. Manifest v1에서는 plugin 자신의
  MCP 또는 선언된 Workspace collection 도구만 등록할 수 있고, 다른 plugin,
  MCP server나 Surface 권한을 요청할 수 없다.
  각 도구는 독립된 JSON input schema를 가진다. 자세한 규격은
  [Common Tool Registry](./tool-registry.md)를 따른다.
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

KNU를 설치하기 전, KNU 서버의 `MCP_AUTH_TOKEN`과 같은 값을 Codmes 서버에
등록한다. Manifest에는 토큰 자체가 아니라 이를 가리키는 이름만 들어간다.

```sh
printf '%s' "$MCP_AUTH_TOKEN" \
  | codmes mcp credential set knu --root /path/to/workspace
```

설치와 제거는 Surface manifest와 MCP config를 함께 갱신하며 실패 시 이전 상태로
복구한다. Marketplace 설치는 package SHA-256과 metadata를 확인하고 버전별
디렉터리에 staging한 뒤 활성 버전 포인터를 바꾼다. 앱의 `Settings > Plugins`에서
같은 설치·업데이트·롤백 작업을 실행할 수 있다. 자세한 내용은
[Plugin Marketplace](./marketplace.md)를 따른다.

## Declarative Surface 보안

Apple 앱은 HTML/JavaScript를 실행하지 않는다. Codmes 서버는 설치된 UI binding에
plugin backend의 domain JSON을 대입해 Surface document를 만든다. Apple 앱은
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
