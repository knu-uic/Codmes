# Codmes Plugin Marketplace

Codmes Marketplace는 Workspace 서버에 plugin을 한 번 설치하고, 그 서버에 연결된
macOS·iPhone·iPad가 같은 plugin view와 도구를 사용하는 구조다. Apple 앱마다 package를
따로 내려받거나 임의 JavaScript/native binary를 실행하지 않는다.
Package manifest의 `platforms`가 현재 기기를 포함하지 않으면 Marketplace에는
호환되지 않음으로 표시되고 설치 버튼이 비활성화되며, 이미 Workspace에 설치된
plugin이라도 해당 기기에는 Surface를 노출하지 않는다. 예전 Registry 항목처럼
`platforms`가 없는 경우에만 하위 호환을 위해 모든 Apple 기기를 지원하는 것으로 본다.

Chat·Notes·Code·Planner는 Codmes가 함께 배포하는 built-in plugin이다. KNU처럼
사용자가 선택하는 community plugin만 Marketplace에서 설치한다. 두 종류는 동일한
Plugin Runtime과 앱 UI를 사용하지만, built-in plugin은 앱과 함께 업데이트되고
제거할 수 없다.

기본 공식 Registry 주소는 `marketplace/trusted-registry-roots.json` 한 곳에서
관리한다. 런타임은 이 신뢰 루트 문서의 첫 번째 Registry를 기본값으로 사용하므로
조직이나 저장소 이름이 바뀌어도 런타임 코드를 수정할 필요가 없다.

앱에는 URL과 Marketplace root 공개키가 함께 고정되어 있다. 서버는
`index.sig.json`의 detached Ed25519 서명을 먼저 확인하고, 그 다음 각 package의
Publisher 서명과 SHA-256을 별도로 확인한다. 개발 Registry를 사용할 때만
`CODMES_MARKETPLACE_REGISTRY` 환경 변수나 CLI의 `--registry`로 주소를 덮어쓴다.

## 사용자가 보는 흐름

1. Codmes 앱의 `Settings > Marketplace`에서 community plugin 목록을 연다.
2. `Install`을 누르면 Workspace 서버가 registry에서 package를 가져온다.
3. 서버가 SHA-256, publisher 서명, package metadata, manifest, 권한, plugin view를
   검증한다.
4. 성공하면 view·tool·MCP 설정을 한 단위로 활성화한다.
5. 연결된 Mac/iPhone/iPad는 새 plugin을 새로고침해 표시한다.

업데이트가 있으면 `Update`, 직전 버전이 남아 있으면 `Restore`, 설치된 plugin에는
제거 버튼이 표시된다. 제거는 plugin 실행 등록을 없애지만 사용자 credential과
서비스 데이터는 자동 삭제하지 않는다.

업데이트가 기존 설치에서 없던 권한을 추가하면 앱은 새 권한과 release note를
보여주고 사용자가 동의한 뒤에만 설치한다. 기존에 승인한 권한만 사용하는 업데이트는
다시 묻지 않는다. Registry에서 취약 버전으로 차단한 버전은 신규 설치·업데이트·
rollback 대상이 될 수 없고, 이미 설치돼 있으면 앱에 보안 경고가 표시된다.

## 현재 MVP 배포 구조

```text
Marketplace registry (index.json)
       │ id, version, package URL/path, SHA-256, publisher 공개키, 권한
       ▼
Codmes Workspace server
       │ 다운로드 → 검증 → versions/<version>에 staging
       │ 성공 후 state.json의 currentVersion 교체
       ├── Plugin view/tool 등록
       └── MCP 등록
                │
                ▼
        macOS / iOS / iPadOS native UI
```

- 개발 registry: 저장소의 `marketplace/index.json`
- 개발 package: `marketplace/packages/*.codmes-plugin`
- 운영 배포 지원: 공개 HTTPS Registry + Registry-relative versioned package
- package 확장자: `.codmes-plugin`(ZIP container)
- 전송 무결성: registry의 SHA-256과 실제 package digest 비교
- publisher 신원과 내용 무결성: Ed25519 package signature
- 설치 위치:
  `.codmes/plugins/<plugin-id>/versions/<version>/`
- 활성 버전 포인터:
  `.codmes/plugins/<plugin-id>/state.json`

업데이트는 새 버전을 먼저 별도 디렉터리에 검증·설치한 다음 활성 포인터를
교체한다. 실패하면 기존 view/tool/MCP 설정과 활성 버전을 복원한다. `previousVersion`
한 개를 유지해 앱과 CLI에서 즉시 롤백할 수 있다.

개발 Registry는 `"signaturePolicy": "optional"`로 기존 unsigned package를 허용할
수 있다. 공개 운영 Registry는 `"signaturePolicy": "required"`로 설정한다.
이 경우 package가 unsigned이거나 Registry에 등록된 publisher 공개키로 검증되지
않으면 설치와 업데이트를 중단한다. SHA-256은 다운로드된 archive가 Registry와
같은지 확인하고, Ed25519 서명은 package 안의 모든 배포 파일이 publisher가 만든
내용인지 확인한다.

공개 Registry는 추가로 `"governancePolicy": "reviewed"`를 사용한다. 이 모드에서는
운영자가 서명된 publisher 신청서를 승인하고 활성 상태로 등록한 공개키만 새 release
서명에 사용할 수 있다. 저장소에 포함된 개발 Registry는 기존 unsigned fixture를
위해 `open`을 유지하며 운영 Registry와 혼동하지 않는다.

## CLI

기본 registry의 목록:

```sh
cd "$HOME/Desktop/Codmes"
node bin/codmes.mjs plugin marketplace \
  --root "$HOME/CodmesWorkspace"
```

Marketplace ID로 설치:

```sh
node bin/codmes.mjs plugin install kr.ac.kongju.knu \
  --root "$HOME/CodmesWorkspace"
```

업데이트와 직전 버전 복원:

```sh
node bin/codmes.mjs plugin update kr.ac.kongju.knu \
  --accept-permissions "network:https://new-api.example.com" \
  --root "$HOME/CodmesWorkspace"

node bin/codmes.mjs plugin rollback kr.ac.kongju.knu \
  --root "$HOME/CodmesWorkspace"
```

개발 중인 로컬 package source를 설치하거나 배포 파일을 만드는 방법:

```sh
node bin/codmes.mjs plugin install /path/to/CODMES_PLUGIN \
  --root "$HOME/CodmesWorkspace"

node bin/codmes.mjs plugin pack /path/to/CODMES_PLUGIN \
  --output /tmp/example.codmes-plugin
```

공개 배포 package는 publisher 키로 서명한다. 전체 명령은
[Plugin publishing과 서명](./publishing.md)을 참고한다.

다른 registry를 시험할 때만 `--registry /path/to/index.json` 또는 HTTPS URL을
지정한다. 평소 사용자는 CLI 대신 앱의 `Settings > Plugins`만 사용하면 된다.
`--accept-permissions`는 업데이트가 새로 요구하는 권한만 쉼표로 나열하거나 옵션을
여러 번 지정한다. 필요한 권한이 빠지면 업데이트 전 상태를 그대로 유지하고 실패한다.

## Workspace API

- `GET /api/marketplace/plugins`: 마켓 metadata와 설치/업데이트/롤백 상태
- `POST /api/marketplace/plugins/:id/install`: registry 버전 설치
- `POST /api/marketplace/plugins/:id/update`: registry 최신 버전 설치
- `POST /api/plugins/:id/rollback`: 직전 또는 지정된 설치 버전 활성화
- `DELETE /api/plugins/:id`: community plugin의 view/tool/MCP 실행 등록 제거

모든 endpoint는 기존 Codmes Workspace bearer 인증을 사용한다. plugin용 서비스
계정과 Codmes 연결 토큰은 서로 다른 credential이다.

## Package와 registry 작성

Registry entry에는 다음 정보가 필요하다.

```json
{
  "id": "kr.ac.kongju.knu",
  "name": "KNU",
  "version": "0.3.3",
  "packagePath": "packages/knu-plugin/0.3.3.codmes-plugin",
  "sha256": "<64 hex characters>",
  "signature": {
    "algorithm": "ed25519",
    "publisherId": "kr.ac.kongju.knu",
    "keyId": "ed25519:<32 hex characters>"
  },
  "dataVersion": 1,
  "releaseNotes": "공지 검색 속도와 오류 안내를 개선했습니다.",
  "platforms": ["macos", "ios", "ipados"],
  "permissions": ["network:https://knu.example"],
  "verified": true
}
```

공식 Marketplace는 Registry와 함께 검증·배포되는 `packagePath`를 사용한다.
별도 private Registry만 `packageUrl`을 사용할 수 있으며 외부 URL은 HTTPS만
허용한다. HTTP 예외는 loopback 개발 주소뿐이다.

Registry 최상위에는 publisher 공개키를 둔다.

```json
{
  "schemaVersion": 1,
  "signaturePolicy": "required",
  "publishers": [{
    "id": "com.example.publisher",
    "name": "Example Publisher",
    "keys": [{
      "algorithm": "ed25519",
      "keyId": "ed25519:<32 hex characters>",
      "publicKey": "<base64 DER SPKI>"
    }]
  }],
  "blockedVersions": [{
    "pluginId": "kr.ac.kongju.knu",
    "version": "0.2.0",
    "severity": "critical",
    "reason": "인증 토큰 노출 가능성이 있는 버전입니다."
  }],
  "plugins": []
}
```

`blockedVersions`는 Registry 운영자가 긴급하게 배포하는 denylist다. 사용자가
오래된 Registry를 보고 있지 않도록 운영 Registry/CDN의 cache 정책도 짧게 두는
것이 좋다. 차단 항목은 정확한 plugin id와 version에만 적용되며 이유와 심각도를
반드시 기록한다.

## Plugin view와 AI Tool 방향

Marketplace plugin은 필요한 기능만 조합한다.

- UI만 필요한 plugin: native/declarative view
- AI 기능도 필요한 plugin: view + Plugin Tool 또는 MCP
- UI 없이 AI 연동만 필요한 plugin: Tool/MCP

Tool의 공통점은 이름·설명·입력 JSON Schema·권한·실행 provider를 registry에
등록한다는 점이다. 입력값을 억지로 동일하게 만들지는 않는다.

```text
calendar.create({title, startsAt, endsAt})
notes.search({query, folderId?, limit?})
planner.complete({taskId})
```

각 도구는 서로 다른 JSON Schema를 갖고, 공통 Tool Registry가 모델 노출,
권한 승인, plugin별 활성화, 실행 기록만 일관되게 처리한다.

provider 기준:

- `native`: DocSearch, 기본 Notes처럼 Codmes 서버가 직접 실행
- `plugin`: built-in/community plugin의 선언과 Workspace 저장소를 이용하는 provider
- `mcp`: KNU·Google처럼 외부 서비스 서버가 실제 데이터를 소유하고 실행

따라서 Planner는 built-in plugin으로 제공하면서도 native component 규격 안에서 충분히
확장할 수 있고, AI는 같은 Tool Registry를 통해 일정 조회·생성 등을 호출한다.
외부 서비스가 없는 기능까지 별도 MCP 서버로 쪼갤 필요는 없다.

## 구현 상태와 다음 단계

현재 다음 기능이 실제 운영 경로까지 연결되어 있다.

- package/Registry와 KNU Marketplace 설치
- Chat·Notes·Code·Planner의 통합 built-in Plugin Runtime 등록
- macOS·iPhone·iPad 공용 Marketplace UI
- 이름·설명·publisher 검색, Featured·설치됨·업데이트 상태 및 category 필터
- 플러그인 상세 정보, 권한, 호환 platform, release note, 저장소·개인정보 링크
- 설치·제거·update·직전 version rollback
- update 권한 변경 재동의, 취약 version 차단, release note와 선언형 data migration
- 공통 Tool Registry provider, Workspace collection storage
- Planner 선언형 view의 할 일·달력·메모
- Publisher CLI, Ed25519 package 서명, Registry root 분리 서명
- 설치된 plugin의 Publisher 고정과 publisher 키 회전·폐기
- Codmes·KNU 운영 Publisher 키와 Marketplace에 제출된 서명 package
- 별도 `Codmes-Marketplace` 저장소의 외부 PR 자동 검증과 GitHub Pages 배포

공식 Registry의 실제 주소와 서명 주소는
`marketplace/trusted-registry-roots.json`을 기준으로 확인한다.

Registry의 plugin package는 가능하면 `packagePath` 상대 경로로 선언한다. 그러면
`index.json`, 서명 파일, 설치 package가 같은 배포 host에서 제공되어 Publisher
저장소나 GitHub 조직 이름이 바뀌어도 기존 설치 경로는 영향을 받지 않는다.

기존 Notes는 학습 자료와 문서 탐색 기능으로 유지하며 Planner 메모와 결합하지
않는다.

다음 제품화 단계:

1. 검색 결과가 많아질 때를 위한 plugin 상세 screenshot·category 탐색 화면
2. 앱 시작 시 update 확인과 선택 가능한 자동 update 정책
3. 여러 이전 release를 보관하는 장기 rollback 정책
4. 기능 branch를 기본 branch에 병합하고 macOS·iOS 실제 기기 release QA
