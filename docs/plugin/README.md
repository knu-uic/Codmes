# Codmes plugin 문서

이 디렉터리는 Codmes plugin의 설치, manifest, native Surface, MCP 연결과
plugin별 운영 문서를 모아둔다.

## 문서 목록

- [Plugin Manifest v1](./manifest-v1.md): 설치 단위, 권한, Surface/MCP 등록 규격
- [Declarative Surface](./surface-ui.md): WebView 없이 native UI를 구성하는 JSON 계약
- [KNU plugin](./knu.md): 공주대학교 plugin 설치·실행·적용·데이터 소유권과 동작 예시

새 plugin을 추가할 때는 공통 규격을 manifest/Surface 문서에 반영하고,
서비스별 환경변수, 설치 순서, 서버 구성과 데이터 흐름은 별도 문서로 추가한다.
