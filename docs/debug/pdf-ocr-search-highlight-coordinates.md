# PDF OCR 검색과 highlight 좌표 문제

## 증상

`컴퓨터구조론.pdf`에는 눈으로 보이는 `김종현`이 있었지만 처음에는 검색되지
않았다. OCR 정규화 뒤 검색 결과는 나오기 시작했으나 다음 문제가 이어졌다.

- 검색 결과가 text만 표시되고 PDF 위치 thumbnail PNG가 나오지 않았다.
- thumbnail의 주황색 highlight가 글자보다 아래에 있거나 점처럼 보였다.
- 결과를 눌러 PDF를 열었을 때 노란 focus box도 아래로 밀리고 폭이 너무 넓었다.
- 긴 한글 경로와 query 조합에서는 thumbnail cache 생성이 `ENAMETOOLONG`으로
  실패할 수 있었다.

## 원인

### 1. 검색 파일 상한과 문자 map 손상

기존 검색 후보 수집은 큰 PDF를 제외했다. 해당 PDF는 약 123MB, 561 page였으며
추출 text의 한글 문자 map도 광범위하게 손상되어 화면 glyph와 추출 문자열이
일치하지 않았다. 파일 상한만 올려서는 `김종현`을 찾을 수 없었다.

### 2. OCR 좌표의 소수점 손실

Vision OCR은 0...1 normalized 소수 좌표를 반환한다. 이를 정수용 parser로 읽으면
`0.75` 같은 값이 `0`이 되어 OCR line 위치가 좌상단으로 무너진다. 좌표는
`Number` 기반 소수 parser로 별도 처리해야 한다.

### 3. thumbnail cache 파일명

초기 cache key는 상대 경로, crop, query를 base64url로 만들어 파일명에 직접
넣었다. 긴 분해형 한글 경로와 query가 결합되면 파일 시스템의 단일 파일명 제한을
넘었다. cache identity 전체를 SHA-256한 고정 길이 파일명으로 바꿨다.

### 4. PDF highlight annotation과 실제 glyph의 차이

PyMuPDF `search_for()`가 반환하는 rect는 invisible OCR font의 text metric이다.
실제 page raster에 보이는 한글 glyph보다 아래로 내려가고 높이가 작았다.
`add_highlight_annot()`는 이 metric으로 quad를 만들기 때문에 작은 점이나 어긋난
highlight처럼 보였다.

thumbnail은 PDF annotation을 만들지 않고 PNG render 전에 반투명 사각형을 직접
그린다. 확인한 OCR PDF에서는 다음 visual 보정이 실제 glyph와 일치했다.

```text
visualTop = textRect.y - textRect.height * 0.82
visualHeight = textRect.height * 1.22
```

이 값은 OCR 정규화 PDF의 현재 font/text-layer 생성 방식에 종속된다. PDF normalizer
font, font size, textbox 배치를 바꾸면 대표 문서로 다시 측정해야 한다.

### 5. thumbnail과 PDF 내부 focus가 서로 다른 좌표 경로

thumbnail은 server에서 query를 다시 찾아 보정했지만, PDF를 연 뒤 노란 box는
global search response의 raw `chunk.bbox`를 그대로 사용했다. 이 bbox는
`김종현 지음` 같은 OCR line 전체였다. 따라서 `김종현`만 검색해도 box 폭은 line
전체였고 세로 위치는 raw font metric만큼 아래로 밀렸다.

server는 OCR 정규화 PDF의 exact match에 한해 다음을 수행한다.

1. line text 안의 query 시작 위치와 길이로 가로 범위를 좁힌다.
2. PDF point bbox와 normalized bbox에 같은 세로 visual 보정을 적용한다.
3. Apple client는 보정된 normalized bbox를 그대로 노란 focus overlay로 그린다.

일반 PDF에는 이 보정을 적용하지 않는다. document state에
`source/original.pdf`가 있는지 확인해 OCR binary 정규화 PDF를 구분한다.

## PDF binary 정규화 주의사항

- viewer 위에만 text overlay를 얹는 방식이 아니다. 적용본 PDF binary 자체를
  교체한다.
- 문제 page는 150 DPI JPEG raster와 invisible OCR text layer로 다시 만든다.
  선택·복사는 가능하지만 원본 vector content는 해당 page에서 rasterized된다.
- 교체 전에 최초 binary를 `source/original.pdf`에 보관한다.
- 임시 파일을 검증한 뒤 rename해야 한다. 처리 중인 파일을 직접 덮어쓰지 않는다.
- OCR 좌표는 Vision 좌하단 기준을 PDF/화면 좌상단 기준으로 변환한다.
- 손상 page 비율이 25% 이상이면 전체 page OCR이므로 대용량 PDF는 시간이 오래
  걸린다.
- server job 실패 시 업로드 파일은 삭제하지 않고 검색 index 갱신을 시도한다.

## 업로드 UI와 server job UI

upload는 client가 binary를 읽고 전송하는 작업이다. PDF 검사, OCR, binary 재작성,
검증과 indexing은 저장 완료 뒤 server에서 시작한다.

- upload progress와 document job progress를 합치지 않는다.
- Notes 상단 icon은 server의 `running` job이 있을 때만 보여준다.
- 완료된 job 때문에 icon이 계속 남아 있으면 안 된다.
- job registry는 process memory 상태라 server restart 뒤 과거 진행 상태는
  복원되지 않는다.

## 확인 방법

1. 한 page짜리 정상 text PDF를 Notes에 업로드한다.
   - upload 완료 뒤 검사 job이 나타났다 사라지는지 확인한다.
   - binary가 불필요하게 다시 작성되지 않는지 확인한다.
2. 한 page짜리 image-only 또는 손상 text PDF를 업로드한다.
   - `inspecting`, `ocr`, `rewriting`, `verifying`, `indexing` 진행을 확인한다.
   - 다른 PDF reader에서 OCR text 선택과 복사를 확인한다.
3. 검색어가 OCR line의 앞, 중간, 끝에 각각 있는 fixture로 검색한다.
   - thumbnail 주황 box가 정확한 단어를 덮는지 확인한다.
   - 결과를 연 뒤 iPad 노란 box가 같은 단어를 덮는지 확인한다.
4. 같은 page에 같은 query가 여러 번 있을 때 각 result가 올바른 occurrence를
   선택하는지 확인한다.
5. 긴 한글 파일명과 긴 query로 thumbnail 요청을 보내 cache 파일명이 64자리
   SHA-256 PNG인지 확인한다.
6. 정상 native text PDF에 OCR 전용 baseline 보정이 적용되지 않는지 확인한다.

실제 회귀 사례인 `김종현`은 1~3 page에서 4개 결과가 유지되어야 한다. page 1의
`김종현 지음`, page 2의 `김종현 지음`, page 3의 `김종현`,
`지은이 김종현` 각각에서 query 폭만 highlight되어야 한다.

## 관련 구현과 테스트

- `server/lib/search-service.mjs`
- `server/lib/search-service.test.mjs`
- `server/lib/document-ingest.mjs`
- `server/lib/document-ingest.test.mjs`
- `server/lib/document-jobs.mjs`
- `server/lib/pdf-thumbnail.mjs`
- `server/index.mjs`
- `server/workers/document-ingest/ocr_vision.swift`
- `server/workers/document-ingest/normalize_pdf.py`
- `client/apple/Sources/Codmes/RootView.swift`
- `client/apple/Sources/Codmes/PDFWorkspaceView.swift`
