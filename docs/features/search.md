# 현재 검색 구조

## 저장 위치

```text
<Workspace>/.codmes/index/search.json
<Workspace>/.codmes/documents/<document-key>/index/extraction.json
<Workspace>/.codmes/documents/<document-key>/index/content.md
```

`search.json`은 검색용 item/chunk index다. `extraction.json`은 page, bbox, source,
table 등 구조를 보존하고 `content.md`는 같은 문서를 사람이 읽기 쉬운 Markdown으로
남긴 파생물이다. 현재 검색은 Markdown 파일 자체를 RAG source로 다시 읽는 것이
아니라 구조화된 extraction block을 index에 넣는다.

## 색인 대상

- Markdown, text와 주요 source code
- PDF와 image
- DOC/DOCX, PPT/PPTX, HWP/HWPX, ODT/ODP
- XLS/XLSX와 ZIP 내부 지원 문서
- PDF text/image annotation

문서 worker는 PyMuPDF4LLM/PyMuPDF와 bootstrap으로 설치한 Python library를
사용한다. PDF 표는 Markdown table과 구조화된 table metadata로 보존한다.
기본 검색 파일 상한은 1GB이며 `CODMES_SEARCH_MAX_FILE_BYTES`로 바꿀 수 있다.
scan, 전체 rebuild, watcher의 부분 갱신이 같은 상한을 사용한다.

query와 추출 text는 NFC로 정규화한 뒤 비교한다. macOS 파일 시스템의 분해형
한글(NFD) 경로는 원래 경로 그대로 보존하며, 검색 비교 단계에서만 정규화한다.
따라서 경로를 임의로 NFC 문자열로 바꿔 실제 파일과 불일치시키면 안 된다.

text가 없거나 손상된 문자 map이 감지된 PDF page와 image는 OCR 대상이 된다.
macOS server에서는 Apple Vision local OCR이 기본이며, Search 설정에 VLM OCR이
명시되어 있으면 결정적인 VLM OCR 경로를 사용할 수 있다. handwriting stroke
OCR은 아직 없다.

## Notes PDF 업로드 후 검사와 정규화

Notes에 PDF binary 저장이 끝나면 업로드 요청과 분리된 server document job을
시작한다. 업로드 완료 응답을 OCR 전체 처리 시간만큼 지연하지 않는다.

1. 기존 PDF text를 page 단위로 추출한다.
2. replacement character, private-use 문자, 비정상적인 CJK 비율 등으로 손상된
   text map이나 text가 없는 page를 찾는다.
3. 문제 page가 전체의 25% 이상이면 일부 표본만 처리하지 않고 전체 page를 OCR한다.
4. Vision/VLM OCR 결과의 소수점 normalized 좌표를 유지한다.
5. 문제 page를 150 DPI image로 다시 만들고, 같은 PDF binary 안에 선택·복사 가능한
   invisible OCR text layer를 기록한다.
6. 새 binary를 임시 파일로 검증한 뒤 원본 경로에 원자적으로 교체하고 검색
   index를 갱신한다.

이 처리는 viewer 전용 overlay가 아니다. 변경된 PDF를 다른 reader에서 열어도
OCR text를 선택하고 복사할 수 있다. 다만 문제 page는 vector 원본을 그대로
유지하는 것이 아니라 raster image와 OCR text layer로 다시 만들어진다. 최초
binary는 다음 위치에 한 번 보관한다.

```text
<Workspace>/.codmes/documents/<document-key>/source/original.pdf
```

정상 text layer인 PDF는 binary를 다시 쓰지 않고 색인만 갱신한다. job 단계는
`inspecting`, `ocr`, `rewriting`, `verifying`, `indexing`이며
`GET /api/document-jobs`에서 진행률을 확인할 수 있다.

## 갱신과 삭제

`POST /api/index/rebuild` 또는 `codmes index rebuild`는 전체 index를 만든다.
서버 실행 중에는 설정된 root watcher가 create/update/delete를 debounce하여
`updateSearchIndex`로 보낸다. 파일 API의 move/copy/delete와 annotation 저장도
연결된 index 및 document cache를 갱신한다.

recursive watch를 지원하지 않는 환경에서는 watcher 오류를 기록하며 수동 rebuild를
사용할 수 있다.

## 사용자 전역 검색

`GET /api/global-search`는 cursor pagination을 사용한다. 한 요청은 최대 100개지만
`nextCursor`가 있는 동안 다음 100개를 계속 요청할 수 있으므로 전체 결과를 100개로
자르지 않는다.

파일 결과는 다음 순서로 정리한다.

1. 같은 파일 경로를 하나의 문서 group으로 묶는다.
2. 문서는 파일명 exact, prefix, contains 일치 순으로 정렬한다.
3. 그다음 일치한 PDF page 수와 본문 결과 수를 사용한다.
4. 문서 내부에서는 title 결과를 먼저, PDF 결과는 page와 bbox 순으로 둔다.

page별 relevance score를 계산해 재정렬하지 않는다. 같은 page에 검색어가 여러 번
있다면 서로 다른 chunk/bbox 결과를 유지할 수 있다. PDF group의 첫 title 결과는
문서 표지를 사용하고 본문 결과 thumbnail은 해당 page를 PNG로 렌더링해 검색어
영역을 주황색으로 highlight한다.

본문 결과의 `target.bbox`는 단순히 OCR 문장 전체 box를 돌려주지 않는다. binary
정규화가 수행된 PDF는 exact query의 문자열 범위로 폭을 좁히고, PDF font metric과
실제 raster 글자 사이의 baseline/height 차이를 보정한 visual normalized box를
반환한다. Apple client는 이 좌표로 PDF를 연 뒤 노란 focus box를 표시한다.

thumbnail renderer는 PDF 자체에서 query를 다시 찾고 같은 visual 보정을 적용한다.
highlight annotation을 PDF에 추가하는 대신 PNG에 반투명 사각형을 그린다. cache
file 이름은 긴 한글 경로와 query가 있어도 파일명 한도를 넘지 않도록 전체 render
identity의 SHA-256을 사용한다.

## Runtime 검색

`POST /api/search`와 `codmes_search` tool은 model context에 넣을 작은 chunk를 찾는다.
index가 없으면 제한된 workspace scan으로 fallback한다. 이 경로는 향후 UI 검색과
분리된 hybrid retriever로 발전할 수 있다.

현재 ranking은 filename/text match 기반이다. Search 설정의 embedding provider,
model, dimension은 index metadata에 기록되지만 embedding 생성, vector store,
semantic reranking은 구현되지 않았다.

## OCR 실행 주의사항

- Vision OCR box는 Vision의 좌하단 좌표를 PDF/화면의 좌상단 좌표로 변환한다.
- normalized 좌표는 정수 parser가 아니라 소수 parser로 읽어야 한다.
- PDF text extraction box는 실제 보이는 glyph보다 아래로 내려가고 높이가 작을 수
  있으므로 검색 UI에서 raw box를 그대로 사용하지 않는다.
- 정규화 여부는 `source/original.pdf` 존재 여부로 구분한다. 일반 PDF에 OCR 전용
  baseline 보정을 적용하면 정상 text highlight가 오히려 틀어진다.
- VLM은 일반 chat 답변이 아니라 결정적인 OCR 작업으로 호출한다. temperature는 0,
  streaming과 가능한 thinking 옵션은 끄고 출력 길이를 제한한다.
- provider 이름만 믿지 않고 실제 image input이 모델까지 전달되는지 probe로
  확인해야 한다.

관련 구현:

- `server/lib/search-service.mjs`
- `server/lib/document-ingest.mjs`
- `server/lib/document-jobs.mjs`
- `server/lib/pdf-thumbnail.mjs`
- `server/lib/vlm-runtime.mjs`
- `server/workers/document-ingest/extract_document.py`
- `server/workers/document-ingest/ocr_vision.swift`
- `server/workers/document-ingest/normalize_pdf.py`
- `client/apple/Sources/Codmes/SearchView.swift`
