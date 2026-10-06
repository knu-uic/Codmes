# Codmes Server Manager

서버 시작·중지, 계정·기기 승인과 설정을 관리하는 데스크톱 앱이다.
클라이언트 작업 앱은 옆의 `../client/`에서 관리한다.

```text
apps/server-manager/
├── src/            화면 코드·스타일·assets/icon.svg
├── src-tauri/      Rust 데스크톱 코드·Tauri 설정·앱 아이콘
├── scripts/        빌드·런타임 준비 도구
├── tests/          화면 로직과 빌드 구조 테스트
├── .cargo/         Rust 출력 경로 설정
└── builds/         생성 파일만 모음 (Git 제외)
    ├── frontend/       Vite 빌드 결과
    ├── runtime/        패키징용 Node·서버·Python·PostgreSQL 복사본
    ├── rust/           Cargo 중간 산출물과 release/bundle 설치본
    ├── tools/          로컬 빌드 도구
    └── native-runtime/ PostgreSQL 런타임 빌더의 기본 출력
```

화면·계정·서버 제어는 공통 코드로 유지하고, OS에 종속된 부분만 Rust 모듈로 분리한다.

```text
src-tauri/src/
├── lib.rs          공통 앱 구성·명령·메뉴
├── manager.rs      공통 설정·서버 수명주기
├── google_oauth.rs 공통 Google 인증·콜백 처리
├── server_reset.rs 전용 저장소 초기화 트랜잭션·중단 복구
└── platform/
    ├── mod.rs      공통 호출 인터페이스·런타임 탐색·종료 대기 정책
    ├── macos.rs    브라우저·Dock·메뉴바 아이콘·실행 파일 경로
    ├── linux.rs    브라우저·실행 파일 경로
    ├── windows.rs  브라우저·콘솔 없는 실행·프로세스 종료·실행 파일 경로
    └── unix.rs     macOS/Linux 공용 종료 신호·설정 파일 권한
```

현재 OS의 모듈만 컴파일한다. 자동 시작 등록은 Tauri의 공통 플러그인을 사용한다.
OS마다 UI나 계정 기능 전체를 복제하지 않는다. Windows용 어댑터가 있다는 것과
Windows 설치본을 정식 지원하는 것은 별개이며, 배포 제한은 아래 문서를 따른다.

`node_modules/`는 npm 의존성이며 Git에 포함하지 않는다. 소스의 `src`와 `src-tauri`는
중복 앱이 아니라 하나의 앱에 필요한 화면과 OS 실행 계층이다. `builds/runtime`의
서버 복사본은 설치 패키지 구성용이고, 수정하는 원본은 저장소 루트 `server/`이다.
사용자 계정·워크스페이스 데이터는 이 빌드 폴더가 아니라 OS의 앱 데이터 위치에 있다.
`.env`는 배포자 OAuth 설정용이며 Git에 포함하지 않는다.

기존 자료가 남아 있으면 로그인 전에 기존 서버 / 새 서버를 선택한다. 새 서버는
삭제 확인 문구와 OS 관리자 확인을 거쳐 기존 서버 전체를 초기화한다. 실패 시
원래 자료를 복원하며, 다른 기기의 로컬 자료는 삭제하지 않는다. 클라이언트 서버
이동 기능은 아직 없다. 자세한 삭제 범위와 제한은 아래 Manager 문서를 따른다.

저장소 루트에서 실행한다.

```sh
npm run manager:check
npm run manager:dev
npm run manager:build
```

실제 초기화·실패 복원 테스트는 앱 데이터가 아닌 임시 서버를 사용한다.

```sh
cd apps/server-manager
CODMES_TEST_MANAGED_POSTGRES=true cargo test --manifest-path src-tauri/Cargo.toml isolated_server_reset -- --ignored
```

Node와 PostgreSQL/pgvector runtime이 필요하다. OS 인증 대화상자와 실제 Google
로그인은 자동 테스트에서 실행하지 않는다.

직접 Cargo 명령을 쓸 때는 이 앱 폴더 또는 `src-tauri/` 안에서 실행해야 `.cargo`
출력 설정을 읽는다. 설치본은 `builds/rust/release/bundle/`에 생성한다.
지원 플랫폼·portable runtime·정식 배포 요구사항은
[Server Manager 문서](../../docs/server/manager.md)를 참고한다.
