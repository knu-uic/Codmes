# Release 소유권과 버전 정책

Codmes는 소스 소유권과 실제 업데이트 단위를 기준으로 Release를 관리한다.
Release 목록을 나누기 위해 소스가 없는 배포 전용 저장소를 따로 만들지
않는다.

## 저장소별 책임

| 저장소 | 소유하는 소스 | 배포 책임 |
| --- | --- | --- |
| `knu-uic/Codmes` | Server, Server Manager, Apple/Android/Windows client, Distribution CLI, built-in Chat/Notes/Code/Planner | Codmes 제품 Release |
| `knu-uic/Codmes-Marketplace` | 서명된 Registry metadata와 검증된 community plugin package | 정적 Registry 배포; 일반 제품 Release 없음 |
| `knu-uic/codmes-plugin-knu` | KNU plugin Surface, MCP 연결, publisher workflow | KNU plugin 독립 Release |

## Built-in plugin

Chat, Notes, Code, Planner는 Codmes 클라이언트 renderer와 서버 API에 같이 의존하는
기본 기능이다. 내부 manifest의 `version`은 데이터 migration과 호환성 판정에
사용할 수 있지만, 사용자가 따로 설치하는 제품 버전은 아니다.

Planner만 수정했더라도 배포는 다음 Codmes 제품 버전에 포함한다.

```text
Codmes 0.2.1
├─ Server / Server Manager 0.2.1
├─ Clients 0.2.1
└─ bundled Planner 0.2.1
```

Codmes client 업데이트 없이 plugin만 독립적으로 업데이트해야 할 요구가
생기면, 그때 built-in에서 community plugin으로 분리하고 독립 저장소와
Release를 부여한다.

## Distribution CLI

Distribution CLI는 Codmes plugin package, publisher 서명, manifest/Registry validator의
호환성 계약이다. 현재 소스는 Codmes runtime module과 같이 검증되므로 Codmes
저장소에 둔다.

- 검증된 버전은 `codmes-distribution-cli-vX.Y.Z` immutable Git tag로 고정한다.
- Marketplace와 plugin publisher workflow는 commit SHA 대신 이 tag를 checkout한다.
- 일반 사용자용 Codmes GitHub Release는 생성하지 않는다.
- 독립 npm package로 추출하게 되면 그때 소스와 테스트까지 함께 이전한다.

## GitHub Release 규칙

Codmes의 새 GitHub Release는 설치 가능한 제품에만 사용한다.

- `codmes-server-vX.Y.Z`: Server Manager와 포함된 Workspace Server
- `codmes-client-macos-vX.Y.Z`: macOS Apple Silicon 용 Codmes client

초기 client 배포는 macOS 14 이상과 Apple Silicon을 지원한다. Android,
Windows, iPhone·iPad 사용자용 설치본은 각 플랫폼의 서명·스토어
배포 준비가 완료된 후 별도 tag 규칙을 정의한다.

`codmes-client-macos-vX.Y.Z` tag를 push하면 `macOS client release` workflow가
Apple client를 arm64 Release로 build하고 Developer ID 서명과 Apple 공증을
거친 DMG를 GitHub Release에 게시한다. workflow를 수동 실행하면
서명하지 않은 개발 검증용 DMG만 artifact로 만든다.

정식 배포에는 다음 GitHub Actions secret이 필요하다.

- `MACOS_CERTIFICATE`: Developer ID Application `.p12`의 base64 문자열
- `MACOS_CERTIFICATE_PASSWORD`: `.p12` 비밀번호
- `APPLE_SIGNING_IDENTITY`: 인증서의 완전한 Developer ID Application 이름
- `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD`, `APPLE_TEAM_ID`: `notarytool` 공증 자격 증명

`com.codmes.planner-v0.2.0`과 `codmes-distribution-cli-v1.0.0` GitHub Release는 이
정책 이전에 생성된 legacy 기록이다. 기존 다운로드와 링크를 깨지 않기
위해 삭제하지 않지만 새 버전은 같은 형태로 발행하지 않는다.
