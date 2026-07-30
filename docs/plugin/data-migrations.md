# Plugin 데이터 migration

Workspace collection을 쓰는 plugin은 코드 version과 데이터 schema version을
따로 관리한다.

- `version`: package release의 semver. UI나 문구만 바뀌어도 올라갈 수 있다.
- `dataVersion`: 저장된 collection 구조의 정수 version. 필드 구조가 바뀔 때만
  `1 → 2 → 3`처럼 한 단계씩 올린다.

## Manifest와 migration 파일

`plugin.json`:

```json
{
  "schemaVersion": 1,
  "id": "com.example.planner",
  "version": "2.0.0",
  "dataVersion": 2,
  "storage": "storage.json",
  "migrations": "migrations.json"
}
```

`migrations.json`:

```json
{
  "schemaVersion": 1,
  "migrations": [{
    "id": "memos-v2",
    "from": 1,
    "to": 2,
    "operations": [
      {
        "type": "renameField",
        "collection": "memos",
        "from": "body",
        "to": "content"
      },
      {
        "type": "setDefault",
        "collection": "memos",
        "field": "pinned",
        "value": false
      },
      {
        "type": "removeField",
        "collection": "memos",
        "field": "legacyColor"
      }
    ]
  }]
}
```

현재 지원하는 선언형 operation:

- `renameField`: 기존 필드 이름을 바꾼다. 대상 필드가 이미 있으면 그 값을 보존하고
  이전 필드를 제거한다.
- `setDefault`: 필드가 없거나 `null`일 때 문자열·숫자·불리언·`null` 기본값을 넣는다.
- `removeField`: 더 이상 쓰지 않는 필드를 제거한다.

각 migration은 인접한 version 하나만 이동할 수 있다. 예를 들어 `1 → 3` 업데이트는
`1 → 2`, `2 → 3` 두 단계가 모두 새 package 안에 있어야 한다. 이 제한 덕분에
사용자가 어떤 이전 version에서 업데이트해도 같은 경로로 검증할 수 있다.

## 업데이트 시 처리 순서

1. 새 package, 서명, 권한, manifest와 migration 문서를 검증한다.
2. 관련 collection 파일을 메모리에 snapshot한다.
3. 선언된 operation을 순서대로 적용한다.
4. 변환된 모든 item을 새 `storage.json` schema로 다시 검증한다.
5. 새 plugin version을 staging하고 collection을 원자적으로 교체한다.
6. Surface/MCP 설정과 활성 version pointer를 바꾼다.

중간 단계가 없거나 변환 결과가 새 schema와 맞지 않으면 collection과 활성 plugin
version을 전혀 바꾸지 않는다. 적용 뒤 후속 설치 단계가 실패해도 snapshot으로
원래 데이터를 복원한다.

## Rollback 제한

현재 자동 migration은 앞으로 가는 방향만 지원한다. 활성 version과 이전 version의
`dataVersion`이 같을 때만 즉시 rollback할 수 있다. 데이터 schema가 달라졌다면
Marketplace UI가 이유를 표시하고 rollback을 막는다.

이는 새 데이터 일부를 잃으면서 이전 schema로 억지 변환하는 것보다 안전한 기본값이다.
향후 역방향 migration이 필요해지면 별도 계약과 사용자 백업 UX를 추가한다.

## 개발자 점검 사항

- 필드 구조가 바뀌지 않았다면 `dataVersion`을 올리지 않는다.
- migration과 새 `storage.json`을 같은 release에 포함한다.
- 실제 기존 데이터와 비어 있는 collection을 모두 시험한다.
- 배포 전에 서명 package에 `migrations.json`이 포함됐는지 확인한다.
- 데이터 migration release는 이전 schema와 호환되지 않으므로 release note에
  rollback 제한을 명확히 적는다.
