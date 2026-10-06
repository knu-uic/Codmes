# iPad 파일 tree drag and drop 문제

## 증상

파일을 길게 누르면 drag preview는 보이지만 폴더 위에 올려도 행이 강조되지 않고
이동도 실행되지 않았다. 중첩 폴더가 tree에 보이지 않는 문제도 함께 있었다.

## 원인

한 가지 문제가 아니라 서로 다른 계층의 문제가 겹쳤다.

1. 처음 요구사항을 직접 drag가 아닌 `Move to folder` 메뉴로 이해했다.
2. `/api/tree`가 직계 child만 반환해 중첩 폴더 데이터가 client에 없었다.
3. SwiftUI `List`의 행/scroll gesture가 folder drop event를 안정적으로 전달하지
   못했다.
4. 일반 `String` transfer는 앱 내부 workspace item인지 구분하기 어려웠다.
5. code를 수정한 뒤에도 이전 server process가 실행 중인 경우가 있었다.

drag preview가 보인다는 것은 출발점만 정상이라는 뜻이다. folder의 `isTargeted`
표시가 켜지지 않으면 move API보다 drop destination부터 확인해야 한다.

## 해결

- Notes와 Code tree는 `recursive=true`로 전체 계층을 요청한다.
- 목록은 `ScrollView + LazyVStack`으로 구성한다.
- file row는 `FileTreeDragItem(paths:)`를 전달한다.
- folder row는 같은 전용 `Transferable` type의 `dropDestination`을 받는다.
- `isTargeted` 동안 accent 배경과 border를 표시한다.
- toolbar/root 영역도 drop target으로 만들어 폴더 밖으로 이동할 수 있게 한다.
- 선택 mode에서는 선택된 여러 path를 한 drag payload로 전달한다.

### macOS 폴더 드롭 회귀 (2026-10-06)

폴더의 drop handler가 파일명/아이콘 content에만 붙어 있어 펼침 버튼과 우측
메뉴 영역은 drop 대상이 아니었다. context menu는 바깥 행에, drag source는
안쪽 content에 붙어 별도의 interaction 계층도 겹쳤다. macOS는 전용 workspace
payload를 등록하면서도 drop에서는 일반 UTF-8 text/NSString 변환에 의존했다.

- context menu와 drag source는 같은 파일 content에 붙이고 폴더 행 전체를 drop
  대상으로 만든다. 우측 저장 모드와 `...`의 정렬은 유지한다.
- macOS folder/root는 모두 `com.codmes.workspace-item` data representation을
  직접 decode하는 공통 delegate를 사용한다. 일반 text는 이동 요청으로 받지 않는다.
- `dropUpdated`는 명시적으로 move를 제안하고, drop 완료 시 강조를 해제한다.
- 전용 provider의 한글 PDF 경로·다중 경로 round trip 및 일반 text 거부를
  `FileTreeDragTests`로 검사한다.

```text
GET   /api/tree?root=notes&recursive=true
PATCH /api/file/move
```

서버는 자기 자신 또는 자기 하위로 폴더를 이동하는 요청과 목적지 이름 충돌을
거부한다. 성공 후 client는 전체 tree를 다시 불러온다.

## Context menu와 drag

길게 누르기는 context menu와 drag가 공유하는 iOS 표준 interaction이다.

- 움직이지 않고 유지: Copy/Rename/Delete menu
- 누른 상태에서 이동: drag

오른쪽 `...` menu도 같은 명령을 제공한다. 여러 항목을 선택하면 copy/delete와
묶음 drag를 사용할 수 있고 rename은 한 항목일 때만 제공한다.

## 진단 순서

1. `curl`로 recursive tree에 대상 folder가 있는지 확인한다.
2. drag preview가 생기는지 확인한다.
3. folder 위에서 `isTargeted` 강조가 나타나는지 확인한다.
4. drop callback의 source/destination path를 확인한다.
5. `PATCH /api/file/move` 응답을 확인한다.
6. 이동 후 tree reload가 실행되는지 확인한다.

```bash
curl 'http://127.0.0.1:8787/api/tree?root=notes&recursive=true'
```

코드 위치:

- `apps/client/apple/Sources/Codmes/FileSectionView.swift`
- `apps/client/apple/Sources/Codmes/WorkspaceStore.swift`
- `apps/client/apple/Sources/Codmes/WorkspaceAPI.swift`
- `server/index.mjs`
