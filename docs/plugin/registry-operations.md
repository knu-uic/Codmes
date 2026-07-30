# Marketplace Registry 운영

공식 Codmes Marketplace는 정적 HTTPS Registry로 운영할 수 있다. 앱과 Workspace
서버가 필요한 것은 `index.json`과 immutable package뿐이므로 별도 Marketplace
application server가 필수는 아니다.

```text
Publisher
  └─ 서명된 신청서/서명 package
          ↓ 운영자 검수
Reviewed Registry source
          ↓ validate + build
Static output (index.json, health.json, packages, _headers)
          ↓ Registry root key로 index.json detached signature 생성
Static output (index.sig.json 추가)
          ↓
GitHub Pages 또는 CDN
          ↓
Codmes Workspace server
```

## 개발 Registry와 운영 Registry

개발용:

```json
{
  "signaturePolicy": "optional",
  "governancePolicy": "open"
}
```

공식 운영용:

```json
{
  "schemaVersion": 1,
  "updatedAt": "2026-07-29T00:00:00Z",
  "signaturePolicy": "required",
  "governancePolicy": "reviewed",
  "publishers": [],
  "blockedVersions": [],
  "plugins": []
}
```

`reviewed`에서는 승인된 publisher의 `active` key만 새 release를 만들 수 있다.
클라이언트는 `approved` publisher의 `active` 또는 `retired` key로 서명된 기존
package를 검증하지만 `revoked` key는 거부한다.

공식 Registry 자체도 별도의 Ed25519 root key로 서명한다. Codmes에 내장된
`trusted-registry-roots.json`은 공식 URL과 root 공개키를 함께 고정한다. 따라서
GitHub Pages의 `index.json`만 임의로 바뀌거나 다른 서버로 대체되어도
`index.sig.json` 검증에 실패한다.

```sh
# 운영 시작 시 한 번만 실행한다. private-key.pem은 저장소에 넣지 않는다.
node bin/codmes.mjs plugin registry root-init com.codmes.marketplace \
  --output "$HOME/.codmes-publisher/codmes-marketplace-root"

# 배포할 index.json의 정확한 바이트를 별도 파일에 서명한다.
node bin/codmes.mjs plugin registry sign \
  --registry /tmp/codmes-marketplace-public/index.json \
  --sign-key "$HOME/.codmes-publisher/codmes-marketplace-root/private-key.pem" \
  --root-id com.codmes.marketplace \
  --output /tmp/codmes-marketplace-public/index.sig.json
```

`registry-root.json`은 공개 정보라 앱에 포함해도 되지만, `private-key.pem`은
운영자 암호화 백업과 CI secret에만 둔다.

## 1. Publisher 신청과 승인

Publisher가 신청서를 생성한다.

```sh
node bin/codmes.mjs plugin publisher apply com.example.publisher \
  --sign-key "$HOME/.codmes-publisher/example/private-key.pem" \
  --name "Example Publisher" \
  --repository-url "https://github.com/example/plugins" \
  --contact "security@example.com" \
  --output /tmp/example-application.json
```

운영자는 repository 소유 관계, 개인정보 처리방침, Surface/Tool 권한, 외부 서버의
데이터 보관 방식을 검토한다. 승인하면 신청서 서명 검증과 Registry 등록을 한 번에
실행한다.

```sh
node bin/codmes.mjs plugin registry approve \
  /tmp/example-application.json \
  --registry /path/to/official-registry/index.json
```

연락처는 심사용 신청서에만 있고 공개 Registry에는 복사하지 않는다.

## 2. Release 검증

일반 검증:

```sh
node bin/codmes.mjs plugin registry validate \
  --registry /path/to/official-registry/index.json \
  --verify-assets
```

운영 배포 전 검증:

```sh
node bin/codmes.mjs plugin registry validate \
  --registry /path/to/official-registry/index.json \
  --production \
  --verify-assets
```

`--production`은 다음을 실패 조건으로 취급한다.

- package signature가 `required`가 아님
- publisher governance가 `reviewed`가 아님
- 유효한 `updatedAt`이 없음
- unsigned plugin 또는 승인되지 않은 publisher/key
- checksum이나 release note 누락
- 로컬 package 또는 원격 HTTPS release asset의 checksum·Ed25519 서명 불일치

## 3. 정적 호스팅 산출물

```sh
node bin/codmes.mjs plugin registry build \
  --registry /path/to/official-registry/index.json \
  --output-dir /tmp/codmes-marketplace-public \
  --production
```

결과:

```text
/tmp/codmes-marketplace-public/
├── index.json
├── index.sig.json  # build 후 registry sign으로 생성
├── health.json
├── _headers
└── packages/
    └── *.codmes-plugin
```

- `index.json`: 5분 cache 후 재검증
- `health.json`: cache하지 않는 배포 상태와 Registry SHA-256
- `packages/*`: version별 파일이므로 1년 immutable cache
- `_headers`: Cloudflare Pages/Netlify 계열 정적 호스팅에서 바로 쓸 cache 규칙

기존 output을 교체하려면 검증을 통과한 상태에서만 `--force`를 사용한다. 빌드는
staging 디렉터리에 전부 만든 뒤 마지막에 output을 교체하므로 중간 산출물이
공개되지 않는다.

GitHub Pages는 `_headers`를 해석하지 않으므로 동일한 cache 정책을 앞단 CDN 또는
배포 workflow에서 설정한다. CDN이 없다면 `index.json` URL에 긴 cache를 두지 않는다.

## 4. Key 회전

새 key pair를 다른 디렉터리에 만든 뒤 공개 identity만 운영자에게 전달한다.

```sh
node bin/codmes.mjs plugin publisher init com.example.publisher \
  --output "$HOME/.codmes-publisher/example-2027"

node bin/codmes.mjs plugin registry rotate \
  "$HOME/.codmes-publisher/example-2027/publisher.json" \
  --registry /path/to/official-registry/index.json
```

기존 `active` key는 `retired`, 새 key는 `active`가 된다. 다음 release부터 새 개인키로
서명한다. 전환 기간에 두 key를 모두 active로 두어야 하는 특별한 경우에만
`--keep-current-key`를 사용한다.

## 5. Key 유출과 취약 버전 차단

Key가 유출됐으면 즉시 폐기한다.

```sh
node bin/codmes.mjs plugin registry revoke com.example.publisher \
  --key-id "ed25519:..." \
  --reason "CI secret exposure on 2026-07-29" \
  --registry /path/to/official-registry/index.json
```

해당 key를 참조하는 현재 Registry release는 자동으로 `critical` 차단된다. 그 뒤
안전한 key로 수정 version을 배포한다.

Plugin 자체 취약점은 key 폐기 없이 정확한 version만 차단한다.

```sh
node bin/codmes.mjs plugin registry block com.example.plugin 1.2.0 \
  --severity critical \
  --reason "Credential disclosure vulnerability" \
  --registry /path/to/official-registry/index.json

node bin/codmes.mjs plugin registry unblock com.example.plugin 1.2.0 \
  --registry /path/to/official-registry/index.json
```

차단 해제는 오탐이 명확할 때만 사용한다. 보안 수정은 같은 version 파일을 교체하지
말고 반드시 새 semver release로 발행한다.

## 6. 배포·장애 운영

- Registry source와 정적 output은 별도 branch 또는 별도 저장소로 분리할 수 있다.
- 배포 전 `validate --production --verify-assets`를 CI 필수 검사로 둔다.
- `health.json`의 SHA-256과 배포 시각을 외부 모니터가 확인한다.
- `index.json` 장애 시 기존에 설치된 plugin은 계속 동작한다. 신규 설치·업데이트만
  일시적으로 불가능하다.
- package URL은 version별 immutable이어야 하며 기존 파일을 덮어쓰지 않는다.
- Registry 원본, publisher 신청서, 승인·폐기 사유는 Git history나 별도 감사
  기록으로 보관한다.
- 설치 상태에는 최초 설치 package의 `publisherId`가 고정된다. 같은 plugin id의
  update가 다른 publisher로 바뀌면 Registry가 정상 서명되어 있어도 설치를
  거부한다. 정상적인 key 회전은 publisher id를 유지하고 key id만 바꾼다.
