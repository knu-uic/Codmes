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

## 4. Registry에 공개키와 release 등록하기

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
    "packageUrl": "https://example.com/example-1.0.0.codmes-plugin",
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

## 5. GitHub Release와 Registry를 함께 준비하기

`publisher prepare`는 서명 package를 만들고 Registry의 publisher 공개키와 최신
plugin entry를 한 번에 갱신한다. GitHub에 직접 업로드하지는 않으므로 생성 결과를
검토한 뒤 `gh` 또는 GitHub Actions로 올린다.

`governancePolicy: reviewed` Registry에서는 publisher와 현재 signing key가 운영자에게
이미 승인된 `active` 상태여야 한다. `publisher prepare`가 새 publisher나 새 key를
임의로 신뢰 목록에 추가하지 않는다.

```sh
node bin/codmes.mjs plugin publisher prepare /path/to/CODMES_PLUGIN \
  --sign-key "$HOME/.codmes-publisher/example/private-key.pem" \
  --publisher-id com.example.publisher \
  --package-url "https://github.com/OWNER/REPO/releases/download/com.example.plugin-v1.0.0/com.example.plugin-1.0.0.codmes-plugin" \
  --registry /path/to/marketplace/index.json \
  --output-dir /path/to/dist/plugins \
  --release-notes-file /path/to/release-notes.md
```

명령은 다음을 원자적으로 준비한다.

- `dist/plugins/<plugin-id>-<version>.codmes-plugin`
- package의 SHA-256과 Ed25519 signature
- Registry의 publisher 공개키
- Registry의 해당 plugin 최신 version, package URL, checksum, signature
- Registry의 `dataVersion`과 사용자에게 표시할 release note
- GitHub tag로 사용할 `<plugin-id>-v<version>` 값

결과 JSON을 확인한 뒤 release를 만든다.

```sh
gh release create "com.example.plugin-v1.0.0" \
  "/path/to/dist/plugins/com.example.plugin-1.0.0.codmes-plugin" \
  --repo OWNER/REPO \
  --title "Example Plugin 1.0.0" \
  --generate-notes
```

그 다음 갱신된 `index.json`을 HTTPS로 제공되는 GitHub Pages, 정적 CDN 또는 별도
Registry 저장소에 배포한다. Codmes에는 그 raw HTTPS 주소를 설정한다.

```sh
node bin/codmes.mjs plugin marketplace \
  --registry "https://plugins.example.com/index.json" \
  --root "$HOME/CodmesWorkspace"

node bin/codmes.mjs plugin install com.example.plugin \
  --registry "https://plugins.example.com/index.json" \
  --root "$HOME/CodmesWorkspace"
```

CI에서는 개인키 PEM을 저장소 파일로 두지 말고 GitHub Actions secret에서 임시
파일로 복원해 사용한 뒤 job 종료와 함께 폐기한다.

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
