# Notes와 PDF

Notes는 Markdown/text 편집, attachment 관리, PDF 읽기와 annotation을 담당한다.
기능마다 공통 데이터와 동작을 먼저 설명하고, 구현이 다른 경우에만
iOS/iPadOS와 macOS 차이를 구분한다.

## 지원 파일과 저장 위치

- Markdown과 text: 읽기, 편집, 저장
- PDF: 읽기, page 이동, 필기와 text/image object 편집
- image와 일반 문서: 첨부, preview 또는 metadata 표시
- `.codmespdf`: PDF와 편집 가능한 annotation을 한 파일로 이동

사용자 file은 기본적으로 `<Workspace>/Notes`에 둔다. annotation과 index는 Notes
안에 섞지 않고 다음 document state folder에 모은다.

```text
.codmes/documents/<name>--<path-hash>/
|- manifest.json
|- source/
|  `- original.pdf
|- annotations.json
`- index/
   |- extraction.json
   |- content.md
   `- annotation-ocr/
```

`source/original.pdf`는 OCR binary 정규화가 실제로 필요했던 PDF에만 생성되는 최초
업로드 binary 백업이다. 현재 Notes의 PDF 경로에는 검사·정규화가 끝난 적용본이
있다.

## PDF 업로드와 server 분석

파일 선택, 읽기, chunk 전송과 upload progress는 client 작업이다. server가 최종
binary를 Notes 경로에 저장한 뒤에는 별도의 document job으로 PDF를 검사한다.
따라서 upload progress와 PDF 분석 progress는 같은 상태가 아니다.

- 업로드 UI는 기존 전송 진행률만 표시한다.
- PDF 분석은 `inspecting → ocr → rewriting → verifying → indexing` 순서로 진행한다.
- Notes 상단 분석 icon은 실행 중인 server job이 있을 때만 나타난다.
- 새 job이 시작되면 popover를 잠시 자동으로 열고, 닫힌 뒤에는 icon을 눌러 현재
  파일명, 단계, page 수/진행률을 다시 볼 수 있다.
- 마지막 실행 job이 완료되거나 실패하면 active 목록과 icon을 숨긴다.

서버 job은 현재 process memory에 최대 20개를 보관한다. 서버를 재시작하면 이전
완료 이력은 복원하지 않으며, UI는 실행 중인 job만 보여준다. 업로드 후 검사가
실패해도 파일 자체는 남고 가능한 범위에서 검색 index 갱신을 시도한다.

정상 text PDF는 binary를 바꾸지 않는다. 손상된 문자 map 또는 OCR이 필요한
스캔 page는 rasterized page와 invisible OCR text layer가 포함된 새 PDF binary로
교체한다. 다른 PDF reader에서도 OCR text 선택과 복사가 가능하며, 최초 binary는
document state의 `source/original.pdf`에서 보존한다.

## File tree

전체 계층을 Obsidian 방식의 재귀 tree로 표시한다. 여러 folder를 동시에 펼칠 수
있고 펼침 상태를 앱을 다시 실행해도 유지한다. 현재 file은 tree 안에서 강조한다.

context menu와 `...` menu는 copy, rename, delete를 제공한다. 길게 눌러 여러
항목을 선택할 수 있고 선택한 file을 folder 또는 상위/root drop target으로 drag해
함께 이동할 수 있다. 실제 file 작업은 server API가 수행한다.

## PDF 표시와 배율

PDFKit의 vertical `singlePageContinuous` mode를 사용한다. 초기 scale은 고정 숫자가
아니라 viewport와 현재 PDF page 크기로 계산한다. page 높이 약 88%, 너비 최대
약 94% 안에서 전체 page가 잘리지 않는 작은 값을 선택해 이웃 page가 살짝 보이게
한다.

기본 읽기 scale이 사용자가 머무를 수 있는 최소값이다. pinch/magnify 중에는 잠시
더 축소할 수 있지만 gesture를 놓으면 고무줄 반동 없이 짧은 easing으로 기본
scale에 돌아온다. 회전, Split View, window resize처럼 실제 viewport가 바뀌면
기본 scale을 다시 계산하고 current page를 중앙에 맞춘다.

플랫폼별 구현:

- iOS/iPadOS: `AnnotatedPDFKitView`가 UIKit `PDFView`를 감싸고 최소 scale 복귀에
  `easeInOut`을 사용한다. keyboard가 나타나거나 사라질 때의 임시 viewport 변화는
  scale 재계산에서 제외한다.
- macOS: `MacAnnotatedPDFKitView`가 AppKit `PDFView`를 감싸며 window 크기 변화에
  맞춰 scale을 다시 계산한다. magnify 종료 시 `easeOut`으로 복귀한다.

## Page sidebar와 thumbnail

toolbar 왼쪽 page icon을 누르면 toolbar 아래에서 sidebar가 열린다. iPhone은
PDF 위에 overlay하고, iPad와 macOS는 sidebar가 열릴 때 PDF canvas를 오른쪽 가용
공간으로 이동한다. 화면 너비에 따라 thumbnail을 1열 또는 2열로 표시하며 선택한
page를 main PDF 중앙으로 이동한다.

thumbnail loading 기준은 main PDF current page가 아니라 sidebar visible range다.
iOS 18/macOS 15 이상은 scroll visibility API를 사용하고, 이전 OS는 cell geometry로
보이는 page를 계산한다.

우선순위는 sidebar 중앙 page, visible page, visible range 앞뒤 2 page 순서다.
빠르게 scroll하면 이전 대기 request를 취소하고 새 위치를 먼저 처리한다. local
PDF는 PDFKit 전용 serial queue에서 render하고 remote PDF는 최대 3개 request를
동시에 처리한다. 각 cell이 독립적으로 task를 소유하지 않고 sidebar가 전체
queue를 관리한다.

client thumbnail memory cache는 최대 64개, 약 24MB다. 이 제한은 전체 PDF page
수를 자르는 것이 아니다. memory에서 제거된 thumbnail은 필요할 때 disk/server
cache 또는 PDF 원본에서 다시 읽는다.

전역 검색의 PDF 본문 결과는 일반 page sidebar thumbnail과 목적이 다르다.
`/api/pdf-thumbnail`에 검색 결과 bbox와 query를 전달해 해당 문장 주변을 crop한
PNG를 받고, 실제 query 위치에 주황색 highlight를 넣는다. 결과를 선택해 PDF를
열면 같은 visual bbox로 노란 focus box를 표시한다. 두 UI가 동일한 raw OCR line
box를 공유하지 않으므로 renderer와 search response의 좌표 보정을 함께 유지해야
한다.

## 대용량 PDF streaming과 file cache

대용량 PDF 전체를 받은 뒤 화면을 여는 대신 metadata와 current page를 먼저
준비한다. 사용자는 최초 download가 끝날 때까지 기다리지 않고 읽기와 scroll을
시작할 수 있다.

1. `/api/pdf/metadata`에서 page 수와 원본 정보를 읽는다.
2. `/api/pdf/skeleton`으로 같은 page 수를 가진 작은 PDF를 먼저 연다.
3. `/api/pdf/page`에서 current page fragment를 받아 skeleton의 해당 page를 교체한다.
4. `StreamedPDFSession`이 current page 주변을 순차적으로 prefetch한다.
5. 받은 page fragment는 client disk cache에 저장해 다시 방문할 때 재사용한다.

원본 PDF가 이미 local cache에 있으면 `PDFDocument`를 직접 연다. annotation은 원본
download와 별도로 저장할 수 있지만 export나 page 추가처럼 PDF 전체가 필요한
작업은 원본 download가 완료된 뒤 수행한다.

local file cache는 설정에서 1~50GB로 지정한다. 기본값은 iOS/iPadOS 6GB, macOS
20GB이며 한도를 넘으면 마지막 접근 시간이 오래된 file부터 제거한다. PDF뿐 아니라
Markdown, Excel, code 등 server에서 받은 file에 같은 정책을 적용한다.

server cache와 cancel 정책:

- thumbnail: `.codmes/index/thumbnails`
- PDF page fragment: `.codmes/index/pdf-stream`
- render 결과는 임시 file에 쓴 뒤 rename해 불완전한 cache를 막는다.
- client가 request를 취소하면 server도 연결 종료를 감지해 Python renderer를
  중단한다.
- cell에는 현재 request와 일치하는 결과만 반영해 늦게 도착한 image가 화면을
  덮어쓰지 않게 한다.

## Annotation data

annotation은 Apple view 상태가 아닌 page-relative JSON으로 저장한다.

```text
GET /api/file/annotations?path=Notes/example.pdf
PUT /api/file/annotations?path=Notes/example.pdf

PDFAnnotationDocument
|- schemaVersion
|- documentPath
|- updatedAt
|- pages[]
|- objects[]
`- elements[]
```

- `pageIndex`는 0부터 시작한다.
- `inkStrokes`는 portable stroke의 기준 형식이다.
- `inkDataBase64`는 과거 PencilKit 상태를 읽기 위한 호환 field다.
- `objects`는 text와 image object를 저장한다.
- `elements`는 stroke, shape, text, image를 표현하는 공통 element model이다.

stroke에는 안정적인 id, tool, color, width, opacity와 points가 있다. point의 `x`,
`y`는 page 좌상단 기준 0...1 normalized coordinate이며 pressure와 time offset은
선택값이다. 자동 보정 도형은 `shape:<kind>` tool과 보정된 points로 저장한다.

text/image object의 공통 field:

- `id`, `type`, `pageIndex`
- `bbox`: page-relative normalized rectangle
- `text`: text 내용 또는 OCR text
- `dataBase64`: image payload
- `metadata`: font, color, MIME type, filename, OCR 및 편집 hint

UIKit/AppKit view는 이 데이터에서 매번 만드는 표현 계층이다. view frame,
responder, gesture, selection handle과 작성 중 preview는 저장하지 않는다. 빠른
연속 편집은 client에서 debounce한 뒤 현재 annotation document 전체를 PUT한다.

## 입력과 편집 도구

공통 도구는 pen, partial eraser, lasso, shape correction, text box, image object,
annotation inspector, undo/redo다.

입력 정책은 platform interaction에 맞게 다르다.

- iPad: Apple Pencil은 필기, finger는 기본적으로 scroll/zoom
- iPhone: write mode에서 한 finger 필기, 두 finger scroll/zoom
- macOS: mouse와 trackpad event를 `CodmesMacPDFView`가 판별
- read mode: PDFKit 기본 navigation 사용

text/image/shape handle과 선택 gesture가 시작되면 PDF scroll보다 object 편집을
우선한다.

### Eraser와 lasso

eraser는 stroke 전체만 지우지 않고 지우개 영역과 겹친 구간을 제거한다. 남은
구간은 각각 새 stroke가 된다. 자동 보정 shape 일부를 지우면 일반 pen stroke로
변환한다.

lasso는 stroke와 text/image object를 함께 선택한다. 이동, 색 변경, text 크기 변경,
삭제를 선택된 id 집합에 적용한다.

### Undo와 redo

- client memory에 최대 80개의 annotation snapshot을 유지한다.
- 편집이 확정될 때 이전 snapshot을 undo stack에 넣고 redo stack을 비운다.
- 결과는 일반 편집과 동일하게 server에 저장한다.
- 앱 재실행 후에는 history를 복원하지 않고 마지막 저장 결과부터 시작한다.

read mode에서는 undo/redo control을 숨긴다. live stroke point나 handle 이동 중간값은
history에 넣지 않는다.

### 도형 인식

pen stroke를 그린 뒤 잠시 유지하면 line, polyline, rectangle, triangle, circle,
ellipse 후보를 계산한다. 인식이 통과하면 `shape:<kind>` stroke로 저장하고 resize
handle을 제공한다.

- recognizer: `PDFShapeRecognizer.swift`
- exemplar bank: `PDFShapeExemplarBank.swift`
- sample store: `PDFShapeSampleStore.swift`
- replay corpus: `scripts/fixtures/shape-recognition-quickdraw-samples.jsonl`

기하 규칙과 exemplar 결과가 모두 품질 기준을 통과해야 한다. sample은 저장소의
고정 corpus로 replay하며 개인 문서의 실제 필기나 민감한 좌표를 넣지 않는다.

## Text box

공통 `PDFAnnotationObject(type: text)`를 platform text view overlay로 표현한다.
새 빈 draft는 편집을 끝내면 삭제하며 content, normalized bbox, font size, color,
draft/manual-width metadata만 annotation에 반영한다.

공통 interaction은 선택, inline 편집, object drag 이동과 좌우 handle resize다.
수동 너비는 `metadata.manualWidth=true`로 저장하고 wrapped text 높이를 다시
계산한다. move/resize hit test는 PDF view가 먼저 처리해 text selection이나 PDF
scroll이 같은 gesture를 선점하지 않게 한다.

플랫폼별 구현:

- iOS/iPadOS: `UITextView`를 사용한다. tap으로 선택하고 double tap으로 편집한다.
  keyboard가 올라오면 PDF scale을 바꾸지 않고 새 text box를 keyboard 위에 남은
  viewport 중앙으로 이동한다.
- macOS: `MacPDFTextView` (`NSTextView`)를 사용한다. click으로 선택하고 double
  click 또는 edit command로 편집한다. 높이는 AppKit text layout으로 측정한다.

## Export와 import

export icon을 누르면 먼저 현재 page, page 범위 입력, 전체 page 중 대상을 고른다.
그다음 annotation을 page에 flatten할지, 편집 가능한 Codmes annotation을 포함할지
선택한다.

일반 PDF export는 annotation을 flatten하므로 다른 기기에서 stroke, text box,
image object를 다시 편집할 수 없다. `.codmespdf`는 원본 PDF와 annotation을 다음
ZIP container에 함께 보관한다.

```text
manifest.json
document.pdf
annotations.json
```

manifest에는 format/schema version, 원래 이름과 각 entry checksum이 있다.
import할 때 entry 목록, 크기, PDF signature, JSON schema와 checksum을 검증한다.
같은 이름이 있으면 기존 file을 덮어쓰지 않고 충돌하지 않는 이름을 고른다. 중간
단계가 실패하면 이번 import에서 만든 file과 state를 함께 정리한다.

## File lifecycle과 search

server API를 통한 file 작업은 PDF와 document state를 함께 처리한다.

- move/rename: state folder와 manifest의 source path 갱신
- copy: 새 path hash를 가진 state folder로 annotation 복사
- delete: document state와 search item 제거
- PDF page 삽입: binary 교체, annotation page index 조정, 문서 재색인

`extraction.json`은 page, bbox, source 등 구조화된 search metadata를 보존한다.
`content.md`는 table을 포함한 사람이 읽기 쉬운 추출 결과다. 현재 search index는
구조화 JSON을 사용하며 `content.md`는 향후 RAG 또는 점검에 사용할 수 있는 파생
file이다. 현재 LLM이 이 Markdown file을 직접 읽지는 않는다.

검색 대상:

- text object: `annotation-text`
- OCR text가 있는 image object: `annotation-image-ocr`
- PDF 원문: `pdf-text` 또는 document extractor block
- VLM으로 읽은 page image: `vlm-ocr`
- Apple Vision으로 읽은 page image: `vision-ocr`

같은 image content hash는 OCR cache를 재사용한다. 위치나 크기만 바뀌면 OCR을
다시 하지 않고 page/bbox metadata만 갱신한다. handwriting stroke는 현재 검색
대상이 아니다.

검색 query와 text는 NFC로 비교하며 기본 검색 파일 상한은 1GB다. OCR 정규화 PDF
결과는 exact query 폭과 실제 raster glyph의 세로 영역으로 `target.bbox`를
보정하므로, 문장 전체가 아니라 검색어 위치에 focus box가 표시된다.

## 관련 코드

- PDF UI와 입력: `client/apple/Sources/Codmes/PDFWorkspaceView.swift`
- annotation model: `client/apple/Sources/Codmes/Models.swift`
- file tree: `client/apple/Sources/Codmes/FileSectionView.swift`
- API client: `client/apple/Sources/Codmes/WorkspaceAPI.swift`
- annotation/file API: `server/index.mjs`
- document state: `server/lib/document-ingest.mjs`
- search: `server/lib/search-service.mjs`
