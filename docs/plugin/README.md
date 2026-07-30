# Codmes plugin 문서

이 디렉터리는 Codmes plugin의 설치, manifest, native view, MCP 연결과
plugin별 운영 문서를 모아둔다.

## 문서 목록

- [통합 Plugin Runtime](./runtime.md): built-in/community plugin의 공통 view·tool·storage·settings 실행 계약
- [Plugin Manifest v1](./manifest-v1.md): 설치 단위, 권한, Surface/MCP 등록 규격
- [Declarative Surface](./surface-ui.md): WebView 없이 native UI를 구성하는 JSON 계약
- [Declarative Surface v2](./surface-v2.md): collection과 선언형 editor field 계약
- [Plugin Marketplace](./marketplace.md): 배포·설치·업데이트·롤백과 향후 Tool provider 계획
- [Plugin publishing과 서명](./publishing.md): publisher 키 생성, package 서명·검증, Registry 신뢰 정책
- [Marketplace Registry 운영](./registry-operations.md): publisher 심사, 키 회전·폐기, 정적 호스팅과 장애 대응
- [Plugin 데이터 migration](./data-migrations.md): 저장 schema 변경, 원자적 적용, rollback 제한
- [Common Tool Registry](./tool-registry.md): 도구 descriptor, 서로 다른 입력 schema와 provider 계약
- [Planner built-in plugin](./planner.md): 기본 plugin으로 내장된 할 일·달력·텍스트 메모와 AI 도구
- [KNU plugin](./knu.md): 공주대학교 plugin 설치·실행·적용·데이터 소유권과 동작 예시

새 plugin을 추가할 때는 공통 규격을 manifest/view 문서에 반영하고,
서비스별 환경변수, 설치 순서, 서버 구성과 데이터 흐름은 별도 문서로 추가한다.
