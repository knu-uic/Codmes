# 남은 작업

이 문서는 구현되지 않은 항목만 기록한다. 완료된 단계별 이력은 Git에서 확인한다.

## Search

- embedding 생성과 vector 저장소
- lexical + vector hybrid ranking
- OCR query bbox의 word/glyph 단위 정밀화와 다양한 font 회귀 검증
- handwriting stroke OCR

## Notes와 PDF

- 더 풍부한 text box 서식
- 대규모 PDF의 thumbnail/cache 성능 측정과 개선
- PDF 표준 annotation과의 선택적 round-trip
- Android/Windows의 서버 없는 PDF 원본 렌더링과 PDF+필기 묶음의 독립 최초 등록·교체
- Android/Windows 64 MiB 초과 파일의 스트리밍 읽기
- 외부 declarative plugin의 upstream 첨부파일별 동기화 provider와 오프라인 편집
- 대규모 파일 목록의 delta/pagination 동기화와 실제 저용량 기기 검증

## Code와 Runtime

- 언어 서버와 진단 정보 연동
- 서버 터미널 세션 UI
- provider별 transport 검증 확대
- 승인 정책과 감사 기록 UI 강화

항목이 구현되면 이 문서에서 제거하고 해당 기능 문서의 현행 동작에 반영한다.
