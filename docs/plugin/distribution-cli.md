# Distribution CLI 버전 정책

Codmes 앱의 제품 버전과 plugin 배포 도구의 버전은 독립적으로 관리한다.
앱 UI, PDF 편집기나 client 기능만 바뀌면 Marketplace와 plugin workflow가
검사 도구를 함께 올릴 필요가 없다.

현재 공식 배포 도구 버전은 다음 명령으로 확인한다.

```sh
node bin/codmes.mjs plugin distribution version
node bin/codmes.mjs plugin distribution version --json
```

`1.0.0`은 다음 기능을 하나의 호환성 단위로 묶는다.

- plugin package 생성과 검증
- publisher release 준비와 Ed25519 서명
- Marketplace Registry 검증, 정적 build와 root 서명
- manifest schema v1
- Registry schema v1
- Surface schema v1과 v2

## 공식 Git tag

검증된 Distribution CLI commit에는 다음 형식의 immutable tag를 붙인다.

```text
codmes-distribution-cli-v1.0.0
```

Codmes-Marketplace와 plugin publisher workflow는 임의의 Codmes commit SHA가
아니라 이 tag를 checkout한다. 두 workflow는 checkout 후 CLI가 보고하는 버전도
확인해 tag 이름과 실제 도구 버전이 다른 경우 즉시 실패해야 한다.

## 버전 변경

- patch: 기존 유효 package의 결과를 바꾸지 않는 오류 수정
- minor: 기존 규격과 호환되는 새 manifest·Surface 기능
- major: 기존 package가 새 검증에서 실패할 수 있는 규칙 변경

새 버전은 Codmes 전체 테스트가 통과한 commit에만 tag를 생성한다. tag는 이동하거나
재사용하지 않는다. Marketplace와 publisher는 새 버전 검증 PR이 통과한 뒤 각각
독립적으로 새 tag로 전환한다.

장기적으로 Distribution CLI가 독립 package로 배포되더라도 이 버전 계약과 명령
출력은 유지한다.
