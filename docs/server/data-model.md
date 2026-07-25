# 데이터와 저장 경로

## Workspace

```text
<Workspace>/
|- Notes/
|- Code/
|- Documents/
|- Attachments/
`- .codmes/
```

사용자 파일은 일반 파일 시스템 형식이다. Codmes 전용 상태는 `.codmes` 아래에
두며 Notes 폴더 안에 숨은 상태 파일을 새로 만들지 않는다.

## 주요 상태

```text
.codmes/
|- config/                 provider, model, auth, search settings
|- documents/              document-specific state
|  `- <name>--<path-hash>/
|     |- manifest.json
|     |- source/
|     |  `- original.pdf    OCR 정규화 전 최초 PDF binary
|     |- annotations.json
|     `- index/
|        |- extraction.json
|        |- content.md
|        `- annotation-ocr/
|- index/
|  |- files.json
|  |- search.json
|  |- pdf-stream/           PDF page fragment cache
|  `- thumbnails/           PDF thumbnail cache
|- sessions/
|- conversation-index/
|- conversation-folders/
|- tasks/
|- approvals/
|- diffs/
|- tool-logs/
|- decisions/
|- memory/
|- skills/
|- plugins/
|- tool-modes/
`- audit/
```

`<name>--<path-hash>`는 읽기 쉬운 파일명과 Workspace 상대 경로의 SHA-256 앞
8자리를 조합한다. 같은 이름의 문서가 다른 폴더에 있어도 충돌하지 않는다.

## 원본과 파생 상태

| 종류 | 예 | 재생성 가능 |
| --- | --- | --- |
| 원본 | 사용자 파일, OCR 전 `source/original.pdf`, `annotations.json`, sessions, config | 아니오 |
| 파생 | `files.json`, `search.json`, `extraction.json`, `content.md`, OCR/PDF stream/thumbnail cache | 예 |

파일 API로 문서를 이동하거나 복사하면 문서 상태의 `sourcePath`와 저장 위치도
함께 갱신된다. 삭제하면 연결된 문서 상태와 검색 항목도 제거된다. 서버 밖에서
직접 파일을 변경한 경우 watcher와 다음 indexing 과정이 파생 상태를 정리한다.

`source/original.pdf`는 모든 PDF의 복제본이 아니다. Notes PDF 검사 중 text layer
정규화가 필요한 경우에만 현재 파일을 교체하기 직전에 한 번 생성한다. 현재 Notes
경로의 PDF가 사용자가 보는 적용본이며 backup 존재 여부는 OCR 전용 검색 좌표
보정 여부를 판별하는 marker 역할도 한다.

`.codmes/index/thumbnails`의 파일명은 경로/query 문자열 자체가 아니라 SHA-256
render identity다. 긴 한글 경로를 base64 파일명으로 직접 사용하면 macOS 파일명
제한을 넘을 수 있으므로 되돌리지 않는다.

## PDF annotation 핵심

`annotations.json`은 schema version, document path, 페이지별 stroke, text/image
object, 공통 element 배열을 저장한다. 좌표는 페이지 기준 정규화 값이므로 화면
크기와 Apple UI 클래스에 의존하지 않는다. 자세한 계약은
[Notes annotation 문서](../features/notes.md#annotation-data)를 참고한다.
