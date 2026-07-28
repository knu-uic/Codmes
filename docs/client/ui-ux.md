# UI와 UX 원칙

화면과 데이터 처리처럼 공통으로 사용할 수 있는 부분은 SwiftUI로 함께 만들고,
mouse·keyboard가 필요한 macOS 기능은 AppKit으로, touch·Apple Pencil이 필요한
iPhone·iPad 기능은 UIKit으로 따로 구현합니다. Notes와 PDF의 annotation data는
특정 앱에만 묶이지 않도록 만들어, 추후 Windows나 Android 앱에서도 그대로
사용할 수 있게 합니다.

## 전체 구조

- 첫 화면은 실제 Chat, Notes, Code 작업 화면이다.
- 상단 bar에는 surface 선택기, 연결 상태, 열린 파일 제목, 검색과 설정 command를 둔다.
- Notes와 Code는 같은 위치에서 여러 folder를 펼칠 수 있는 tree를 사용한다.
- 선택된 file과 drop 가능한 folder는 색과 border로 즉시 구분한다.

## 상단 surface 선택기

- Chat, Notes, Code와 plugin surface 전환은 상단 왼쪽의
  `surface 이름 + 아래 화살표 + 연결 상태 LED` menu에서 수행한다.
- 별도의 surface 전환 bar를 작업 화면 안에 중복해서 만들지 않는다.
- 연결 상태 LED는 surface 이름 옆에 항상 남기고, sidebar가 열려도 상단 bar를
  가리지 않는다.
- sidebar toggle은 surface 선택기 왼쪽, 검색과 설정은 상단 오른쪽에 둔다.
- Notes와 Code에서 연 file 제목은 상단 중앙에 표시한다.
- surface 이름이 바뀔 때 SwiftUI가 `Menu` label의 폭을 다시 측정하며 한 frame
  잘리는 현상이 생기지 않도록 label 외곽 폭을 고정한다. 이름, 화살표, LED로
  이루어진 내부 `HStack`은 leading 정렬을 사용해 요소 사이 간격을 유지한다.
- 매우 긴 plugin surface 이름은 상단의 고정 영역 안에서 tail truncation으로
  줄인다. 화살표와 LED는 유지하고, 선택 menu에서는 plugin의 전체 이름을
  표시한다. 긴 이름 때문에 검색·설정 command나 중앙 제목을 밀어내면 안 된다.

## 왼쪽 sidebar

- macOS와 iPad 가로 화면의 sidebar는 본문 위를 덮지 않고 본문을 밀어내는
  persistent layout을 기본으로 한다. 상단 toggle로 접고 다시 펼칠 수 있다.
- iPad persistent layout은 iPad idiom이면서 가로 방향이고 사용 가능한 폭이
  700pt 이상일 때 사용한다. iPhone, iPad 세로, 좁은 Split View에서는 본문 위에
  나타나는 overlay layout을 사용한다.
- overlay sidebar는 바깥 영역 tap 또는 왼쪽 방향 drag로 닫을 수 있다. 같은
  상단 toggle은 닫힌 상태에서는 열기, 열린 상태에서는 닫기로 동작한다.
- sidebar는 항상 상단 bar 아래에서 시작한다. 따라서 sidebar가 열린 동안에도
  surface 이름, 아래 화살표, 연결 LED, 검색과 설정을 확인할 수 있어야 한다.
- Chat sidebar는 project와 그 안의 session, project에 속하지 않은 최근 session을
  표시한다. Notes와 Code sidebar는 각각의 재귀 file tree를 표시한다.
- Chat, Notes, Code sidebar container는 모두
  `.background.opacity(0.96)`의 같은 배경을 사용한다. surface에 따라 다른
  material이나 tint를 적용해 색이 달라 보이게 하지 않는다.
- overlay layout에서 session이나 file을 열면 sidebar를 닫는다. persistent
  layout에서는 선택 후에도 sidebar를 유지한다.
- plugin surface에 전용 sidebar가 없으면 빈 상태 안내를 표시한다.

## Surface 설정

- Settings의 Surfaces 기본 화면에는 Surface 목록과 plugin 추가 UI를 표시한다.
- 각 Surface 행에는 활성화 toggle과 설정 아이콘을 함께 둔다. 설정 아이콘을
  누르면 Settings의 왼쪽 category sidebar는 유지하고 오른쪽 main 영역 전체를
  해당 Surface 상세로 전환한다. 상세 우상단의 닫기 버튼은 Surface 목록으로
  돌아간다.
- Chat, Notes, Code도 동일한 상세 진입점을 제공한다. 아직 개별 설정이 없더라도
  화면을 없애지 않고 향후 옵션이 들어갈 자리라는 빈 상태를 표시한다.
- 인증을 제공하는 plugin Surface 상세는 Model Config의 계정 인증 UI를 따른다.
  상단에 연결 상태, 저장된 계정, 기본 연결/해제 command를 표시하고 자격 증명은
  별도 card 안에서 다룬다.
- plugin sidebar의 로그인 버튼은 별도 임시 로그인 sheet를 만들지 않는다.
  `Settings → Surfaces → 현재 plugin` 상세로 이동하며 로그인은 그 화면에서만
  수행한다.
- 비밀번호 기반 plugin은 비밀번호를 로그인 요청에만 사용하고 client와 Codmes
  서버 어디에도 저장하지 않는다. plugin이 발급한 사용자 token만 Codmes 서버의
  credential store에 저장한다.
- KNU Surface의 인증 필드는 별도 KNU PICK 회원 계정이 아니라 공주대 포털
  학번·비밀번호를 받는다. 연결 중에는 외부 SSO 확인이 진행 중임을 명시한다.
- plugin 로그인 작업과 인증 상태는 설정 상세 View가 아니라 앱 전역
  `WorkspaceStore`가 소유한다. 설정과 Surface sidebar는 같은 상태를 구독하며
  로그인 중 표시, 성공, 실패가 양쪽에 즉시 반영되어야 한다.
- 사용자가 인증 도중 설정 상세 또는 설정 sheet를 닫아도 로그인 요청과 후속
  동기화 polling은 취소하지 않는다. 명시적인 취소 기능을 제공하기 전까지
  화면 종료는 작업 취소 의미로 사용하지 않는다.
- 로그인 요청이 시작되면 학번·비밀번호 입력 card를 즉시 숨기고 인증 전용
  progress 상태로 교체한다. 진행 중인 form과 입력값을 화면에 남기지 않는다.
- 인증 성공과 포털 데이터 동기화는 별개 상태다. sidebar의 주 상태는 로그인된
  계정명을 유지하고, 후속 데이터 동기화는 작은 progress indicator로만 보조
  표시한다.
- 포털 인증 후 서버의 KNUIS/LMS sync가 진행되는 동안 계정명 옆에 작은 progress
  indicator를 표시하고 auth status를 polling한다. 완료되면 계정 card에 이름과
  `학번 · 학과 · 학년`을 표시하고 LMS Surface를 자동으로 다시 읽는다.

## Chat sidebar interaction

- project header에는 project 관리 menu와 새 chat command를 둔다.
- project menu는 프로젝트 관리, 이름 변경, 제거 command를 제공한다.
- 최근 header에는 session history와 새 session command를 둔다. 다중 선택
  중에는 전체 선택/해제와 삭제 command로 교체한다.
- macOS session row의 `...`는 pointer hover 중에만 표시한다. iOS/iPadOS에서는
  `...`를 상시 표시하지 않고 long press context menu로 고정, 선택, 이름 변경,
  삭제 command를 연다.
- session row의 전체 영역을 hit target으로 사용한다. 제목 text만 hover 또는
  tap target이 되면 안 된다.
- session은 project 사이와 최근 영역으로 drag and drop할 수 있다. 다중 선택
  중 선택된 session 하나를 drag하면 선택된 전체 session을 함께 이동한다.
- project 아래와 최근 영역에 같은 session을 중복 표시하지 않는다.

## 오른쪽 Chat panel

- Notes와 Code의 오른쪽 Chat panel은 오른쪽 edge에서 drag하여 열고, panel이나
  dimmed background를 오른쪽으로 drag하거나 바깥 영역을 tap하여 닫는다.
- 왼쪽 sidebar와 같은 spring 응답과 drag threshold를 반대 방향으로 적용한다.
  별도의 handle 폭이나 추가 offset을 두지 말고 panel 전체가 pointer/touch 이동을
  연속적으로 따라야 한다.
- 대각선 drag 중 translation을 갑자기 `0`으로 초기화하지 않는다. 이 처리는
  panel이 손가락에서 끊겨 보이는 원인이 된다.
- 오른쪽 Chat panel이 열리면 좁은 작업 공간에서 충돌하지 않도록 왼쪽 sidebar를
  접는다. 왼쪽 sidebar를 열 때도 오른쪽 panel을 닫는다.
- Chat panel 내부에는 `Codmes Chat` 같은 중복 header를 추가하지 않는다.

## 파일 interaction

- folder arrow는 expand/fold만 담당한다.
- file row tap은 열기, 길게 누르기는 context menu 또는 drag 진입점이다.
- `...` menu는 long press가 불편할 때 같은 관리 command를 제공한다.
- 다중 선택은 copy/delete/drag 같은 묶음 동작에 사용한다.
- folder 밖으로 이동할 수 있도록 root도 명확한 drop target을 제공한다.
- iOS/iPadOS custom drag payload는 app Info.plist에 exported UTI로 선언한다.
  file tree는 `com.codmes.workspace-item`, chat session은
  `com.codmes.chat-sessions`를 사용한다.

## 검색

- iOS 검색은 작업 화면을 완전히 교체하지 않는 popup 형태를 사용한다.
- 결과는 document 단위로 묶고 filename 일치를 가장 먼저 보여준다.
- PDF document 안에서는 page 순서로 배치하며 같은 page의 여러 결과를 보존한다.
- PDF 본문 결과는 해당 text 주변을 crop한 PNG thumbnail에 검색어를 주황색으로
  highlight한다.
- 결과를 선택하면 해당 PDF page로 이동하고 같은 검색어 영역에 노란 focus box를
  표시한다. line 전체 box나 raw PDF font metric box를 그대로 사용하지 않는다.

## 서버 문서 작업

- upload progress는 client의 파일 전송 상태이고 PDF 분석 progress는 server
  document job 상태다. 하나의 progress UI로 합치지 않는다.
- Notes 상단의 분석 icon은 `running` server job이 있을 때만 표시한다.
- 새 분석이 시작되면 popover를 3초간 자동 표시하고 이후 icon으로 다시 열 수 있다.
- popover는 파일명, 현재 단계, page 단위 진행률 또는 percent를 표시한다.
- 실행 중인 job이 없어지면 popover와 icon을 함께 숨긴다.

## PDF

- 초기 화면은 한 page 전체와 이웃 page 일부가 보여 현재 위치를 이해할 수 있어야 한다.
- 최소 읽기 배율보다 축소한 뒤에는 반동 없이 자연스럽게 기본 배율로 돌아온다.
- page sidebar는 toolbar 아래 왼쪽에서 열리며 넓은 화면에서는 PDF도 남은 공간
  쪽으로 이동한다.
- iPhone thumbnail은 화면 폭에 따라 1열 또는 2열을 사용한다.

구현 중 발견한 재발 가능한 문제는 [debug 문서](../debug/)에 원인과 검증 절차를
남긴다.
