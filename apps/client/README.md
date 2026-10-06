# Codmes 클라이언트

클라이언트 원본 코드와 로컬 빌드 결과를 한 앱 디렉터리 안에서 구분한다.
Server Manager는 옆의 `../server-manager/`에서 별도로 관리한다.

```text
apps/client/
├── apple/          macOS·iOS·iPadOS 원본과 테스트
├── android/        Android 원본과 테스트
├── windows/        Windows 원본과 테스트
├── shared/         공통 protocol schema
└── builds/         빌드 결과와 DerivedData (Git 제외)
    └── <platform>/
        ├── latest/     최신 성공 빌드
        └── previous/   직전 성공 빌드
```

원본은 Git에 포함하고 `builds/`와 각 도구의 중간 산출물은 이 폴더의
`.gitignore`로 제외한다. 예전 루트 `client/`나 `apps/client-builds/`는 사용하지 않는다.

저장소 루트에서 다음 명령을 실행한다.

```sh
npm run client:build:macos
npm run client:build:ios
npm run client:build:android
npm run client:build:windows
```

Mac 로컬 Release 앱은 `builds/macos/latest/Codmes.app`이다. 기존 Codmes를 종료한
뒤 이 앱을 실행하면 GitHub push 없이 확인할 수 있다. 빌드 명령은 앱을 자동으로
설치하거나 실행하지 않는다. 로컬 개발 서명과 정식 배포의 서명·공증은 별개다.

검증 명령도 저장소 루트에서 실행한다.

```sh
npm run client:build:test
swift test --package-path apps/client/apple
dotnet test apps/client/windows/tests/Codmes.Windows.Tests.csproj
```

Android 검증은 `apps/client/android/`에서 `./gradlew testDebugUnitTest lintDebug`로
실행한다. 자세한 환경 요구사항은 [루트 README](../../README.md),
[Release 정책](../../docs/release-policy.md), [Apple](../../docs/client/apple.md),
[Android](android/README.md), [Windows](windows/README.md) 문서를 참고한다.
