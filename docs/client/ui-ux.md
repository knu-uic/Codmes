# UI와 UX 원칙

화면과 데이터 처리처럼 공통으로 사용할 수 있는 부분은 SwiftUI로 함께 만들고,
mouse·keyboard가 필요한 macOS 기능은 AppKit으로, touch·Apple Pencil이 필요한
iPhone·iPad 기능은 UIKit으로 따로 구현합니다. Notes와 PDF의 annotation data는
특정 앱에만 묶이지 않도록 만들어, 추후 Windows나 Android 앱에서도 그대로
사용할 수 있게 합니다.

## 전체 구조

- 첫 화면은 실제 Chat, Notes, Code 작업 화면이다.
- 상단 bar에는 현재 surface와 열린 파일 제목, 검색과 설정 command를 둔다.
- Notes와 Code는 같은 위치에서 여러 folder를 펼칠 수 있는 tree를 사용한다.
- 선택된 file과 drop 가능한 folder는 색과 border로 즉시 구분한다.

## 파일 interaction

- folder arrow는 expand/fold만 담당한다.
- file row tap은 열기, 길게 누르기는 context menu 또는 drag 진입점이다.
- `...` menu는 long press가 불편할 때 같은 관리 command를 제공한다.
- 다중 선택은 copy/delete/drag 같은 묶음 동작에 사용한다.
- folder 밖으로 이동할 수 있도록 root도 명확한 drop target을 제공한다.

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
