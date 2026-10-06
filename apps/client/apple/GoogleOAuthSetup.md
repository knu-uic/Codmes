# Apple 클라이언트 Google 로그인 설정

Codmes는 Google 비밀번호를 받지 않습니다. macOS/iOS 앱은 시스템 인증 브라우저에서 OAuth authorization code + PKCE로 ID 토큰을 받은 뒤 Codmes 서버에 전달합니다. 서버는 Google 서명과 audience를 확인하고 기기 등록을 `pending` 또는 `approved`로 처리합니다.

## Codmes 앱 배포자가 Google Cloud에서 준비할 값

- macOS용 OAuth 클라이언트: 유형 **iOS**, Bundle ID `com.codmes.app`. 공개 클라이언트 ID를 공식 Server Manager 빌드에 포함합니다.
- iOS용 OAuth 클라이언트: 유형 **iOS**, Bundle ID `com.codmes.app.ios`. 공개 클라이언트 ID를 공식 Server Manager 빌드에 포함합니다.
- Server Manager/Windows의 Desktop-loopback OAuth ID는 별도입니다. Apple용 ID를 `CODMES_GOOGLE_DESKTOP_CLIENT_ID`와 혼용하지 않습니다.

앱 배포자는 각 Apple 앱을 만들 때 공개 ID를 Xcode 빌드 설정 `CODMES_GOOGLE_CLIENT_ID`에, 해당 ID를 뒤집은 URL 스킴을 `CODMES_GOOGLE_URL_SCHEME`에 지정합니다. 예를 들어 ID가 `123-abc.apps.googleusercontent.com`이면 스킴은 `com.googleusercontent.apps.123-abc`이고 로그인 콜백은 `com.googleusercontent.apps.123-abc:/oauth2redirect`입니다. macOS와 iOS의 ID가 다르면 각 타깃을 별도로 빌드합니다. iOS 기본값은 아직 미등록 상태이며 배포자가 등록한 ID가 필요합니다. 앱은 서버가 알려 준 ID와 앱에 포함된 배포자 ID가 다르면 로그인을 시작하지 않습니다. ID와 스킴은 `Info.plist`에 빌드 시 기록되므로 서버 운영자가 값을 바꿀 필요도, 바꿀 수도 없습니다.

원격 서버 로그인에는 HTTPS가 필요합니다. HTTP는 앱과 서버가 **같은 기기**의 `localhost`일 때만 허용됩니다. iPhone에서 Mac의 `localhost`에 접속할 수는 없습니다.

Codmes 계정이 본체이며 Google은 선택적인 로그인 수단입니다. 최초 관리자는 서버
컴퓨터의 Server Manager에서 Codmes ID·비밀번호를 정합니다. 클라이언트는 시작 화면을
막지 않고 `Settings → Connection`에서 서버 주소·회원가입·ID/비밀번호 로그인 또는
Google 로그인을 제공합니다. Google로 처음 가입해도 Codmes ID·비밀번호를 설정합니다.
기존 계정의 Google 연결·변경·해제는 현재 Codmes 비밀번호 확인 후 수행합니다.

## 클라이언트 확인 흐름

서버 연결 뒤 Codmes 계정 로그인 → 기기 등록 승인 대기 → 본인 프로필 자동 연결
순서로 진행합니다. `ask` 모드에서는 Server Manager의 `클라이언트 승인`에서 해당
기기를 수락해야 하며 승인 상태를 자동 확인합니다. Codmes 계정당 하나의 프로필을
같은 서버의 여러 기기에서 공유하므로 Google 연결을 바꿔도 자료와 기기 승인은 유지됩니다.
필수 PIN과 별도의 프로필 추가 화면은 없습니다. 원하는 사람만 `설정 → Profile`에서
기기별 앱 잠금을 켤 수 있습니다. PIN은 Keychain에 저장하며 서버 인증·자료 암호화와 별개입니다.

AuthenticationServices의 완료 콜백은 메인 스레드가 아닌 Safari XPC 큐에서도 도착합니다. Swift 6에서는 콜백을 `@MainActor` 문맥 밖에서 생성하고, 스레드 안전한 일회성 continuation을 통해 인증 결과를 전달합니다. 시작 실패와 늦은 콜백이 겹쳐도 중복 완료하지 않습니다.

기기 등록 승인 확인은 동시에 하나만 실행합니다. 승인된 polling 작업은 자기 자신을 취소하지 않고 종료하여, 뒤이어 실행하는 프로필 목록 요청이 `cancelled`로 실패하지 않도록 합니다. 로그아웃이나 서버 주소 변경으로 중단할 때만 작업을 취소합니다.

참고: [Google iOS/macOS 로그인 설정](https://developers.google.com/identity/sign-in/ios/start-integrating), [Google 설치형 앱 OAuth 및 PKCE](https://developers.google.com/identity/protocols/oauth2/native-app).
