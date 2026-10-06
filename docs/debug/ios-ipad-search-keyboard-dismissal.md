# iPad PDF 이동 후 검색 keyboard가 닫히는 문제

## 증상

첫 검색은 정상이다. PDF 검색 결과를 열고 다시 검색 화면을 띄운 뒤 입력하면
search field의 focus가 풀리고 keyboard가 내려갔다.

## 원인

iOS에서 keyboard 입력을 받는 view는 first responder다. 당시 PDF page overlay의
`PKCanvasView`는 tool 설정이 갱신될 때 `becomeFirstResponder()`를 호출했다.

PDF를 한 번 연 뒤에는 검색 화면 뒤에 PDF view가 남아 있다. 검색어 입력으로
SwiftUI state가 바뀌면 뒤쪽 PDF의 `updateUIView`도 실행될 수 있었고, 이때 canvas가
first responder를 가져가 search field가 keyboard를 잃었다.

첫 검색에서만 정상인 이유는 아직 뒤에 PDF canvas가 없었기 때문이다.

## 해결

현재 필기는 `PKCanvasView`의 interactive input이 아니라
`PDFImmediateDrawingGestureRecognizer`가 받는다. canvas는 완료된 drawing을
표현하는 overlay이므로 keyboard focus가 필요 없다.

`applyTool(to:)`는 다음 정책을 사용한다.

- `canvas.isUserInteractionEnabled = false`
- pen/eraser/lasso tool 값만 갱신
- canvas가 first responder인 경우 `resignFirstResponder()`
- text box를 실제 편집할 때만 해당 text view가 first responder 요청

따라서 보이지 않는 PDF update가 검색 field의 focus를 빼앗지 않는다.

## 회귀 확인

1. 검색 후 PDF page 결과를 연다.
2. 검색을 다시 열고 여러 글자를 연속 입력한다.
3. 결과 갱신 중에도 keyboard와 cursor가 유지되는지 확인한다.
4. PDF로 돌아와 pen, eraser, lasso, scroll, pinch zoom을 확인한다.
5. text tool로 text box를 편집할 때는 keyboard가 정상적으로 열리는지 확인한다.

비슷한 문제에서는 화면에 보이는 field만 보지 말고 아래 호출을 전체 검색한다.

```bash
rg 'becomeFirstResponder|resignFirstResponder|FocusState|focused' apps/client/apple
```

특히 `UIViewRepresentable.updateUIView`에서 사용자 action과 무관하게 responder를
바꾸는 코드는 다른 overlay나 sheet의 입력을 방해할 수 있다.
