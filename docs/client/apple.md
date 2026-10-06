# Apple 클라이언트

## 대상과 구조

하나의 Xcode 프로젝트가 macOS와 iOS/iPadOS target을 제공한다.

호환성 판정에서 iPadOS를 별도 OS로 내보내지 않는다. iPhone은 `ios + phone`,
iPad는 `ios + tablet`, Mac은 `macos + desktop`으로 판정한다. 서버가 기존
`ipados` 선언을 보내는 경우에도 `ios + tablet`로 읽는다.

```text
apps/client/apple/Codmes.xcodeproj
apps/client/apple/Sources/Codmes/
```

공통 SwiftUI 화면과 모델을 공유하고, PDF 입력 계층은 조건부 컴파일로 나뉜다.

- iOS/iPadOS: `UIViewRepresentable`, `PDFView`, UIKit gesture
- macOS: `NSViewRepresentable`, `PDFView`, AppKit event

## 주요 화면

- `RootView`: Chat, Notes, Code surface와 사이드바
- `FileSectionView`: 재귀 파일 트리, 다중 선택, 메뉴, drag and drop
- `SearchView`: 전역 검색과 문서별 PDF 결과
- `PDFWorkspaceView`: PDF 열람, 페이지 thumbnail, 필기와 object 편집
- `WorkspaceStore`: 앱 상태와 API orchestration
- `WorkspaceAPI`: HTTP 요청
- `LiveChatClient`: WebSocket stream

## 앱 시작과 선택적 서버 연결

클라이언트 시작 화면은 로그인 화면이 아니라 기본 Chat/Notes/Code 화면이다.
서버 연결·회원가입·로그인·기존 Google 계정의 Codmes ID 설정은
`Settings → Connection`에서 진행한다. 서버가 없거나 로그인이 만료되어도
앱 탐색, 메시지 초안 작성, Connection의 로컬 캐시 설정과 Profile의 선택적
기기 앱 잠금 설정은 사용할 수 있다. 사용자가 켠 앱 잠금은 별도로 유지한다.

저장된 서버 계정 세션이 있는 경우에만 시작 시 조용히 연결을 복원한다.
로그인하지 않은 첫 실행은 기본 localhost 서버에 자동 접속하지 않는다.
서버 미연결 상태에는 서버 목록·작업 상태·대화 이력을 요청하지 않는다.
로컬 저장된 Notes/Code 목록은 서버 없이도 표시한다.
Notes/Code는 `LocalWorkspace`의 영구 로컬 저장소에서 만들고 읽고 수정한다.
PDF 원본과 필기 sidecar, 파일 목록, 미전송 변경분을 Application Support에
보관한다. 로컬/동기화 원본과 미전송 변경은 파일 캐시 정리로 제거하지 않는다.
서버 모드의 내려받은 깨끗한 사본은 사용이 끝난 뒤 정리할 수 있다. AI 응답과 모델·검색·MCP·플러그인
설정 및 서버 대화 이력은 여전히 서버 기능이다.

서버 연결 시 `/api/sync/*`를 사용하여 15초마다 목록과 선택된 변경을 동기화한다.
목록을 먼저 표시하고 파일은 순차 전송한다. 파일 행의 드롭다운에서 기기별
로컬/서버/동기화 모드를 선택하며 파일 > 폴더 > 플러그인 기본값 순으로 적용한다.
이동·이름 변경은 고유 ID와 파일의 명시적 모드를 유지한다. 독립 가져오기 자료는
PDF 원본과 필기를 포함한 fingerprint가 같으면 같은 서버 ID로 연결한다. 같은 경로의
다른 내용이나 동시 최초 업로드는 확인을 요구하며 자동 덮어쓰기하지 않는다.
업로드는 각 로컬 저장의 원본 SHA-256·versionId·UUID·수정 시각을 영구 대기열에
저장하고 `merge-modified-v2`로 전송한다. 텍스트는 3-way 줄 병합 후 겹치는 줄의
단어·기호 경계로 범위를 줄인다. 같은 위치의 독립된 추가는 함께 보존하며 같은
범위의 교체는 최신 로컬 수정이 우선한다. 서버 도착 순서가 기준이 아니다.
PDF 필기는 별도 revision이며 stable pageId·객체/필기/element ID와 속성별로 합친다.
같은 박스의 텍스트와 위치 등 독립 속성은 함께 보존한다. 기기 시계 오차로 실제
시간을 완벽히 알 수는 없어 관측한 원본의 인과 관계와 deterministic tie-break를 쓴다.
충돌 사본이나 별도 이력·복원 화면은 만들지 않는다. 텍스트와 PDF 필기는 편집기의
되돌리기·다시 실행 버튼을 사용한다. 기록은 편집 세션의 메모리에만 유지하며 최대
80단계, 합계 8 MiB로 제한한다. 텍스트의 연속 입력은 600ms 단위로 묶는다.
되돌리기도 새 로컬 수정으로 자동 저장·동기화한다. 다른 기기의 변경으로 편집 내용이
교체되면 이전 되돌리기 기록을 비워 타인의 변경을 통째로 되돌리는 일을 방지한다.
PDF의 저장 시각·경로 등 서버 metadata만 갱신된 수신은 실제 내용 변경이 아니므로
되돌리기 기록을 유지한다.
전송 실패 또는 응답 유실 시에도 로컬 journal은 남고 안전하게 재시도한다.
로컬 변경 중 재전송된 이전 내용은 새 로컬 변경을 지우지 않는다.

공통 조상이 없거나 8 MiB 초과 텍스트 충돌 및 diff 계산 한도를 넘는 대규모 변경은
안전하지 않은 덮어쓰기 대신 미전송 상태로 남는다. 비 UTF-8 파일·PDF binary 교체·페이지
삽입/재배치는 원본 전체 단위이며, 불투명한 기존 PencilKit drawing만 있는 페이지는
페이지 단위로 처리한다. structured stroke가 있으면 stroke ID로 병합하고 derived
PencilKit 렌더링을 재구성한다. 파일/폴더 종류 충돌은 복사본
대신 로컬 변경을 미전송 상태로 유지한다. 구버전 서버는 업데이트가 필요하다.

서버 URL과 프로필 UUID별로 로컬 저장소를 분리한다. 로그인 전 자료는 독립적인
device-local 저장소에 남으며 `Connection → 현재 계정으로 가져오기`를 눌러야
계정 저장소로 복사된다. 로그아웃은 다른 계정 자료를 노출하지 않도록 device-local로
전환하며, 기존 계정의 로컬 자료와 미전송 변경분은 삭제하지 않는다.
로컬 object는 내용 해시로 중복을 방지한다. 최신 파일과 모든 미전송 operation,
현재 표시 중인 원본 URL을 보호하고, journal commit 후 참조 없는 과거 사본을 정리한다.
계정 로그아웃으로 해당 계정의 최신 파일·미전송 변경을 삭제하지는 않는다.
서버의 병합 기준 자료는 변경되지 않은 블록을 공유·압축하며 오래된 전체 사본은
읽을 때 검증 후 새 저장 형식으로 전환한다. 장기 오프라인 병합에 필요한 기준과
operation metadata는 유지하므로 전체 저장공간에 고정된 상한을 보장하지는 않는다.
이 기능은 macOS/iOS/iPadOS 공통 클라이언트에 적용된다.

텍스트 편집은 저장 버튼 없이 입력이 600ms 멈추면 로컬에 자동 저장하며 편집 화면은
유지된다. 다른 파일로 이동·미리보기 전환·백그라운드 진입·Mac 정상 종료 시 대기 중
입력도 즉시 저장한다. 갑작스러운 강제 종료/프로세스 crash는 debounce 중인 마지막
600ms까지 보장하지 않는다. 저장 실패는 명시적으로 표시하고 재시도를 제공한다.
서버 업로드는 별도 debounce/재연결 동기화이며 서버가 꺼져 있어도 로컬 저장은 된다.

## 반응형 navigation

Notes와 Code는 문서 선택, 텍스트 편집 모드·되돌리기 기록을 메뉴별로 보관한다.
비활성 미리보기도 화면 트리에 유지하므로 Notes로 돌아오면 PDF 페이지·확대·
스크롤 위치와 필기 도구 상태가 그대로 보인다. 숨겨진 화면은 입력·접근성에서
제외하고 크기를 고정해 다른 메뉴의 키보드가 PDF를 재배치하지 않게 한다.
iOS 메모리 경고 시 비활성 PDF 화면·스트리밍 캐시만 해제하고, 복귀 시 문서를
다시 읽어 페이지·확대 위치를 복원한다. 원본·필기·텍스트 편집 내용은 삭제하지
않는다. 전환 전 텍스트를 로컬에 저장하고 저장 실패 시 전환하지 않는다.
전환 전 다운로드가 늦게 완료되어도 새 메뉴의 문서 선택을 덮어쓰지 않는다.

macOS의 왼쪽 navigation sidebar와 오른쪽 Chat panel은 `MacSlidingPane`으로
상단바와 본문을 함께 260ms 동안 슬라이드한다. 내부 너비는 유지하고 바깥의
보이는 너비만 바꾸므로 열고 닫을 때 상단 버튼이 별도로 튀어나오거나
줄바꿈하지 않는다. 닫힌 패널도 유지해 파일 목록 상태와 채팅 초안을 보존하며,
닫힌 동안에는 입력과 접근성 탐색에서 제외한다. 시스템의 동작 줄이기 설정에서는
애니메이션을 생략한다.

`RootView`의 iOS/iPadOS 상단 bar는 surface menu와 연결 상태 LED를 항상
유지한다. iPad 가로 700pt 이상에서는 왼쪽 sidebar와 본문을 `HStack`으로
배치하고, iPhone·iPad 세로·좁은 Split View에서는 overlay sidebar를 사용한다.
sidebar는 상단 bar 아래에서만 열리므로 현재 surface와 연결 상태를 가리지 않는다.

Chat에서는 왼쪽 sidebar가 project와 session을 표시하고, Notes와 Code에서는 같은
자리에 `FileBrowserPane`을 표시한다. overlay 상태에서는 항목을 열면 sidebar를
닫고 persistent 상태에서는 유지한다. Notes와 Code의 오른쪽 Chat panel은 왼쪽
sidebar gesture를 좌우 반전한 drag/offset/spring 규칙을 사용한다.

surface menu label은 compact에서 92pt, regular에서 132pt의 안정된 외곽 폭을
사용한다. 내부 이름·화살표·LED는 leading 정렬하므로 짧은 이름에도 불필요한
간격이 생기지 않는다. 긴 plugin 이름은 상단에서 말줄임표로 축약하고 menu
목록에서는 전체 이름을 보여준다.

## 파일 탐색

Notes와 Code는 한 위치로 들어가는 탐색 방식이 아니라 재귀 트리를 사용한다.
여러 폴더를 동시에 펼칠 수 있고 펼침 상태를 앱 저장소에 보존한다. 파일은 길게
눌러 선택하거나 여러 항목을 선택할 수 있으며, 폴더 행에 drag and drop하여
이동한다. 폴더 바깥으로 이동할 때는 상위/root drop target을 사용한다.

iOS/iPadOS drag and drop에 사용하는 custom type은 `iOS-Info.plist`에서 exported
UTI로 선언한다.

- `com.codmes.workspace-item`: Notes/Code file tree 항목
- `com.codmes.chat-sessions`: 단일 또는 다중 선택 Chat session

## PDF 읽기

- 세로 연속 한 페이지 모드
- 화면과 PDF page 크기로 계산한 초기/최소 읽기 배율
- 첫 페이지는 다음 페이지 일부, 중간 페이지는 위아래 페이지 일부 노출
- 최소 읽기 배율보다 축소한 뒤 놓으면 반동 없이 자연스럽게 원래 배율로 복귀
- 회전 또는 viewport 변경 시 배율 재계산
- toolbar 아래에서 열리는 왼쪽 page thumbnail sidebar
- thumbnail 선택 시 해당 페이지 중앙 정렬

동기화한 PDF는 영구 로컬 원본을 열고 필기도 즉시 로컬 journal에 기록한다.
`.codmespdf` 가져오기·내보내기와 PDF page 삽입도 서버 없이 처리한다. PDF와 필기는
하나의 journal 갱신으로 함께 저장한다. 서버 기반 검색 등의 보조 미리보기는 기존
page streaming과 local disk cache를 사용한다. 캐시 한도(1~50GB)와 캐시 삭제는
로컬/동기화 모드의 영구 원본·필기·미전송 변경분에는 적용되지 않는다. 서버 모드는
열 때 내려받고 사용이 끝난 깨끗한 사본을 정리할 수 있어 오프라인 열람을 보장하지 않는다.

Notes PDF upload가 완료되면 `WorkspaceStore`는 `/api/document-jobs`를 polling한다.
active job이 없을 때는 2초, 있을 때는 1초 간격이다. `RootView`의 server 분석
icon/popover는 이 목록만 사용하며 client `uploadItems`와 분리한다.

전역 검색 PDF 결과의 thumbnail은 server PNG를 사용한다. 결과를 선택한 뒤 iOS
PDF overlay가 그리는 노란 focus box는 server `target.bbox.normalized`를 page
overlay 크기로 변환한다. 따라서 검색어 폭과 OCR baseline 보정은 server response
단계에서 끝나 있어야 한다.

세부 사항과 플랫폼 차이는 [Notes와 PDF 문서](../features/notes.md)를 참고한다.

## 빌드

명령과 Workspace server 실행 방법은 루트 [README](../../README.md)에 정리한다.

시뮬레이터에서 로그인까지 테스트할 때는 `CODE_SIGNING_ALLOWED=NO`를 사용하지
않는다. 서명 없이 링크한 앱은 시뮬레이터 Keychain 접근에 필요한
`application-identifier`가 없어 `errSecMissingEntitlement`(-34018)가 발생할 수 있다.
Xcode의 시뮬레이터 서명/entitlement 생성을 유지한 빌드를 설치한다.

```sh
npm run client:build:ios
```

설치·실행 시 bundle ID는 `com.codmes.app.ios`이다. 시뮬레이터 앱 데이터 경로는
재설치 시 달라질 수 있으므로 `xcrun simctl get_app_container <UDID>
com.codmes.app.ios data`로 매번 확인한다. 비밀번호와 세션 토큰은 테스트 문서나
출력 로그에 기록하지 않는다.

## 검증 범위

현행 정책은 공통 기준 병합 + 겹치는 변경의 로컬 수정 순서이며 자동 충돌 사본을
만들지 않는다. 예전 충돌 사본/도착순 정책을 현행 동작으로 설명하지 않는다.
자동 테스트와 설치 앱·시뮬레이터 검증 결과, 아직 검증되지 않은 실제 기기·필기 UI
범위는 [동기화 검증 기록](../server/sync-v2-validation.md)을 참고한다.
빌드 출력은 `apps/client/builds/<platform>/latest/`이며 날짜별 복사본을 쌓지 않는다.
