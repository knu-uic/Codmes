# Apple 클라이언트

## 대상과 구조

하나의 Xcode 프로젝트가 macOS와 iOS/iPadOS target을 제공한다.

```text
client/apple/Codmes.xcodeproj
client/apple/Sources/Codmes/
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

## 파일 탐색

Notes와 Code는 한 위치로 들어가는 탐색 방식이 아니라 재귀 트리를 사용한다.
여러 폴더를 동시에 펼칠 수 있고 펼침 상태를 앱 저장소에 보존한다. 파일은 길게
눌러 선택하거나 여러 항목을 선택할 수 있으며, 폴더 행에 drag and drop하여
이동한다. 폴더 바깥으로 이동할 때는 상위/root drop target을 사용한다.

## PDF 읽기

- 세로 연속 한 페이지 모드
- 화면과 PDF page 크기로 계산한 초기/최소 읽기 배율
- 첫 페이지는 다음 페이지 일부, 중간 페이지는 위아래 페이지 일부 노출
- 최소 읽기 배율보다 축소한 뒤 놓으면 반동 없이 자연스럽게 원래 배율로 복귀
- 회전 또는 viewport 변경 시 배율 재계산
- toolbar 아래에서 열리는 왼쪽 page thumbnail sidebar
- thumbnail 선택 시 해당 페이지 중앙 정렬

대용량 PDF는 metadata와 current page를 먼저 받아 열고, 나머지 page는 필요할 때
streaming한다. PDF를 포함해 server에서 받은 파일은 local disk cache에 보관한다.
cache 한도는 설정에서 1~50GB로 조절하며, 한도를 넘으면 오래 사용하지 않은
파일부터 제거한다.

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
