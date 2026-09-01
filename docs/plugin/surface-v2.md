# Declarative Surface v2

Surface v2는 Planner의 할 일·달력·메모 같은 서로 다른 데이터 화면이 같은 native
편집 기반을 재사용하기 위한 선언형 계약이다. HTML, JavaScript, WebView나 plugin
native binary를 실행하지 않는다. plugin은 데이터 구조와 필드 의미를 선언하고
Codmes 서버가 검증한 document를 Apple, Android, Windows client가 각 native UI로
렌더링한다.

## v1 호환

- 기존 `surface.json`과 document의 `schemaVersion: 1`은 계속 설치하고 렌더링한다.
- v2 plugin은 UI와 각 document에 모두 `schemaVersion: 2`를 사용한다.
- v1과 v2 모두 `collection`, `dashboard`, `calendar` presentation을 사용할 수 있다.
- v2는 collection data source와 editor가 manifest의 `storage.json`에 선언된
  collection만 가리키도록 설치 시 검증한다.

## 선언형 editor

```json
{
  "schemaVersion": 2,
  "presentation": "calendar",
  "title": "Calendar",
  "editor": {
    "collection": "events",
    "fields": [
      {
        "id": "title",
        "label": "제목",
        "type": "text",
        "required": true,
        "placeholder": "일정 제목",
        "role": "title"
      },
      {
        "id": "startsAt",
        "label": "시작",
        "type": "dateTime",
        "required": true,
        "role": "startsAt"
      }
    ]
  }
}
```

지원 field type:

- `text`: 한 줄 문자열
- `multiline`: 여러 줄 문자열
- `boolean`: toggle
- `date`: 날짜
- `dateTime`: 날짜와 시간
- `number`: 숫자

`id`는 collection item의 property와 연결되고 `role`은 presentation이 필드의 의미를
해석할 때 사용한다. 예를 들어 Calendar는 `startsAt`, `endsAt`, `allDay` role을
사용한다. `placeholder`와 `role`은 선택이고 `required`는 저장 전 필수값 검증에
사용한다.

## 보안과 쓰기

- Surface v2 editor는 설치된 plugin 자신의 Workspace collection만 변경할 수 있다.
- collection id와 field type은 package 설치 시 검증한다.
- Workspace bearer 인증을 통과한 native client의 직접 저장·삭제는 사용자 명시
  조작이므로 즉시 반영한다.
- AI가 같은 collection을 Plugin Tool로 변경할 때는 Safe/Full 승인 정책을 적용한다.
- plugin data는 `.codmes/plugin-data/<plugin-id>/`에 남으며 plugin 제거만으로
  자동 삭제하지 않는다.

## 현재 적용

Planner 0.2.0이 첫 Surface v2 package다. 하나의 package가 `tasks`, `events`,
`memos` collection과 `플래너`, `달력`, `메모` route를 함께 제공한다. 서버는 v2
binding과 editor metadata를 컴파일해 전달하고 macOS/iOS, Android, Windows client가 이를
decode한다. 달력은 표준 시간 role을 사용하고 플래너와 메모는 범용 선언형
collection editor를 사용한다.
