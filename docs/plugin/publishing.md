# Plugin publishing과 서명

Codmes publisher CLI는 Ed25519 키 생성, package 서명, 공개키 검증을 제공한다.
개인키는 배포자의 컴퓨터나 CI secret에만 보관하고 Marketplace에는 공개키만
등록한다.

## 1. Publisher 키 만들기

다음 명령은 처음 한 번만 실행한다.

```sh
cd "$HOME/Desktop/Codmes"

node bin/codmes.mjs plugin publisher init com.example.publisher \
  --output "$HOME/.codmes-publisher/example"
```

생성 파일:

```text
$HOME/.codmes-publisher/example/
├── private-key.pem  # 비공개, 권한 0600
└── publisher.json   # Marketplace에 등록할 공개 정보
```

`private-key.pem`은 Git에 커밋하거나 사용자에게 배포하지 않는다. 잃어버리면 같은
publisher의 기존 key로 업데이트를 서명할 수 없으므로 암호화된 백업 또는 CI secret
manager에 보관한다. `publisher.json`에는 비밀정보가 없고 다음 값을 담는다.

```json
{
  "schemaVersion": 1,
  "publisherId": "com.example.publisher",
  "algorithm": "ed25519",
  "keyId": "ed25519:...",
  "publicKey": "..."
}
```

기존 키를 덮어쓰지 않으며, 의도적으로 교체할 때만 `--force`를 사용한다. 운영 중
key 교체는 이전 key와 새 key를 Registry에 함께 등록한 뒤 새 release부터 새 key로
서명하는 순서로 진행한다.

공개 Marketplace에 처음 등록할 때는 키 파일을 운영자에게 보내지 않는다. 아래처럼
개인키 소유 증명을 포함한 신청서만 만든다.

```sh
node bin/codmes.mjs plugin publisher apply com.example.publisher \
  --sign-key "$HOME/.codmes-publisher/example/private-key.pem" \
  --name "Example Publisher" \
  --repository-url "https://github.com/example/plugins" \
  --contact "security@example.com" \
  --output /tmp/example-publisher-application.json
```

신청서에는 공개키와 repository, 연락처, 신청 내용의 Ed25519 서명이 들어간다.
개인키는 포함되지 않는다. 운영자는 서명을 검증한 뒤 승인하며 자세한 절차는
[Marketplace Registry 운영](./registry-operations.md)을 따른다.

## 2. Package 서명하기

```sh
node bin/codmes.mjs plugin pack /path/to/CODMES_PLUGIN \
  --output /tmp/example-1.0.0.codmes-plugin \
  --sign-key "$HOME/.codmes-publisher/example/private-key.pem" \
  --publisher-id com.example.publisher
```

결과 JSON의 `sha256`은 Registry entry에 복사한다. `signature.publisherId`와
`signature.keyId`도 같은 entry의 `signature`에 넣는다.

서명 대상은 `plugin.json`, `surface.json`, `tools.json`, `storage.json`,
`migrations.json`,
README·LICENSE 등 package에 포함된 모든 파일과 `codmes-package.json`이다.
ZIP 압축 방식과 무관하게 파일 이름과 바이트를 정규화한 payload에 서명한다.
서명 metadata인 `codmes-signature.json` 자체는 payload에서 제외된다.

## 3. 배포 전에 로컬 검증하기

```sh
node bin/codmes.mjs plugin verify /tmp/example-1.0.0.codmes-plugin \
  --public-key "$HOME/.codmes-publisher/example/publisher.json"
```

성공하면 `valid: true`, plugin id, version, publisher id, key id와 SHA-256을
출력한다. 서명 이후 package 파일이 하나라도 바뀌었거나 다른 공개키를 사용하면
검증에 실패한다.

## 4. Marketplace에 공개키와 package 등록하기

`publisher.json`의 값을 Registry 최상위 `publishers[].keys[]`에 등록한다.

```json
{
  "schemaVersion": 1,
  "signaturePolicy": "required",
  "publishers": [{
    "id": "com.example.publisher",
    "name": "Example Publisher",
    "keys": [{
      "algorithm": "ed25519",
      "keyId": "ed25519:...",
      "publicKey": "..."
    }]
  }],
  "plugins": [{
    "id": "com.example.plugin",
    "name": "Example",
    "version": "1.0.0",
    "packagePath": "packages/com.example.plugin/1.0.0.codmes-plugin",
    "sha256": "...",
    "signature": {
      "algorithm": "ed25519",
      "publisherId": "com.example.publisher",
      "keyId": "ed25519:..."
    }
  }]
}
```

- `optional`: 로컬 개발과 기존 unsigned package 전환용
- `required`: 공개 Marketplace 운영용

`required` Registry에서 Codmes 서버는 설치·업데이트 전에 다음을 모두 확인한다.

1. archive SHA-256이 Registry 값과 같은지
2. package의 publisher id와 key id가 Registry entry와 같은지
3. key가 Registry의 신뢰 publisher 목록에 존재하는지
4. Ed25519 서명이 package의 실제 파일 전체와 일치하는지
5. package manifest의 plugin id와 version이 Registry entry와 같은지
6. 기존 설치의 publisher id와 update publisher id가 같은지

검증 후에만 staging 디렉터리에 풀고 활성 버전 포인터를 변경한다. 검증 실패는
기존 설치 버전과 사용자 plugin data를 변경하지 않는다.

여기서 고정되는 것은 개별 key가 아니라 `publisherId`다. Publisher가 정식 key
회전 절차로 새 key를 등록하는 것은 허용하지만, 공격자가 같은 plugin id를 다른
publisher로 재등록해 update를 탈취하는 것은 차단한다.

## 5. Marketplace Pull Request 제출하기

Community plugin 저장소는 Codmes 저장소를 checkout하거나 공식 GitHub 조직명을
참조하지 않는다. 개인 또는 외부 조직에서 자유롭게 관리하고, 공개 배포의 최종
검증만 Codmes Marketplace가 담당한다.

1. 2절의 `plugin pack` 명령으로 서명 package를 만든다.
2. Codmes Marketplace 저장소를 fork한다.
3. package를
   `registry/packages/<plugin-id>/<version>.codmes-plugin`에 추가한다.
4. `registry/index.json`에 `packagePath`, SHA-256, signature, 권한과 release note를
   추가한다.
5. Pull Request를 만들면 Marketplace Actions가 공식 validator로 package를
   검증한다.

Marketplace의 `packagePath`는 다음처럼 Registry 기준 상대 경로여야 한다.

```json
{
  "packagePath": "packages/com.example.plugin/1.0.0.codmes-plugin"
}
```

검증에는 archive checksum, Publisher 서명, plugin id와 version, manifest, 권한,
data version이 포함된다. 최초 Publisher는 공개키 소유 증명과 저장소·개인정보
처리를 사람이 추가로 검수한다. 검증을 통과해 merge되면 Marketplace가 package와
서명 Registry를 같은 공개 host에 배포한다.

### 반복 릴리스는 한 명령으로 준비하기

이미 Publisher가 승인된 Marketplace에서는 package 파일명, `version`,
`packagePath`, SHA-256, Publisher 서명과 `updatedAt`을 직접 편집하지 않는다.
`--package-url`을 생략한 `publisher prepare`가 plugin manifest의 id와 version을
읽어 `registry/packages/<plugin-id>/<version>.codmes-plugin`에 서명 package를
만들고 `registry/index.json`의 기존 metadata를 보존하면서 배포 필드를 자동
갱신한다.

```sh
node bin/codmes.mjs plugin publisher prepare /path/to/plugin \
  --sign-key "$HOME/.codmes-publisher/example/private-key.pem" \
  --publisher-id com.example.publisher \
  --registry /path/to/Codmes-Marketplace/registry/index.json \
  --release-notes-file /path/to/release-notes.md
```

명령 하나가 다음을 수행한다.

1. manifest에서 plugin id와 semver 읽기
2. 모든 package 파일을 Ed25519로 서명
3. `registry/packages/<plugin-id>/<version>.codmes-plugin` 생성
4. SHA-256과 Publisher key id 계산
5. Registry의 version, packagePath, checksum, signature, release note, updatedAt 갱신

GitHub Release에 첨부한 동일 package를 먼저 `registry/packages/`에 복사한 경우에는
archive를 다시 만들지 않는다. CLI가 기존 파일의 Publisher 서명, plugin id와
version을 검증하고 그 파일의 실제 SHA-256을 Registry에 기록하므로 Release와
Marketplace가 완전히 같은 byte를 배포한다. 잘못된 파일이나 다른 Publisher가
서명한 파일은 Registry를 수정하기 전에 거부한다.

저장소 이름처럼 더 읽기 쉬운 폴더를 사용하려면 `--package-directory`를 지정한다.
예를 들어 KNU는 `--package-directory knu-plugin`을 사용해
`registry/packages/knu-plugin/0.4.0.codmes-plugin`에 저장한다. 슬러그를 생략하면
plugin id가 폴더 이름이 되므로 외부 Publisher도 별도 하드코딩 없이 같은 구조를
사용할 수 있다.

그 뒤 `plugin registry validate --production --verify-assets`를 실행하고 생성된 package와
`registry/index.json`만 Pull Request에 포함한다. 외부 GitHub Release URL을 직접
배포원으로 쓰는 Registry에서는 기존처럼 `--package-url`을 명시할 수 있다.

플러그인 저장소 자체의 CI 검증은 선택 사항이다. 필요하면 설치된 Codmes CLI로
로컬 설치와 `plugin verify`를 실행하되, Codmes GitHub 저장소를 직접 checkout하는
workflow를 배포 요구사항으로 두지 않는다.

## 6. 취약 버전 긴급 차단

이미 공개한 package에서 보안 문제가 발견되면 package 파일을 조용히 교체하지
않는다. 같은 version의 내용이 바뀌면 checksum과 서명의 의미가 사라지기 때문이다.
수정 version을 새로 발행하고 Registry 최상위 `blockedVersions`에 문제가 있는
정확한 version을 추가한다.

```json
{
  "pluginId": "com.example.plugin",
  "version": "1.0.0",
  "severity": "critical",
  "reason": "Credential disclosure vulnerability. Update to 1.0.1."
}
```

차단된 version은 설치, 업데이트 대상, rollback 대상이 될 수 없다. 이미 설치된
경우 Marketplace UI가 경고하므로, Registry의 최신 entry는 반드시 안전한 교체
version을 가리키도록 함께 갱신한다.
