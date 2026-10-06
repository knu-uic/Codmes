import XCTest
@testable import Codmes

final class PluginViewDocumentTests: XCTestCase {
    func testDashboardDocumentDecodesNativeTableSections() throws {
        let data = Data(
            #"""
            {
              "schemaVersion": 1,
              "presentation": "dashboard",
              "title": "포털",
              "subtitle": "동기화된 정보",
              "search": null,
              "filters": [],
              "emptyState": null,
              "items": [],
              "sections": [
                {
                  "id": "profile",
                  "title": "학적 정보",
                  "subtitle": null,
                  "systemImage": "person.text.rectangle",
                  "kind": "keyValue",
                  "fields": [
                    { "id": "student-id", "label": "학번", "value": "20260001" }
                  ]
                },
                {
                  "id": "timetable",
                  "title": "주간 시간표",
                  "subtitle": null,
                  "systemImage": "calendar",
                  "kind": "table",
                  "columns": ["교시", "월요일"],
                  "rows": [["1교시", "자료구조"]]
                }
              ]
            }
            """#.utf8
        )

        let document = try JSONDecoder().decode(PluginViewDocument.self, from: data)

        XCTAssertEqual(document.presentation, "dashboard")
        XCTAssertEqual(document.sections?.count, 2)
        XCTAssertEqual(document.sections?[0].fields?.first?.value, "20260001")
        XCTAssertEqual(document.sections?[1].rows?.first, ["1교시", "자료구조"])
    }

    func testSurfaceV2DecodesDeclarativeEditorFields() throws {
        let data = Data(
            #"""
            {
              "schemaVersion": 2,
              "presentation": "calendar",
              "title": "Calendar",
              "subtitle": null,
              "search": null,
              "filters": [],
              "emptyState": null,
              "items": [],
              "sections": null,
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
                  }
                ]
              }
            }
            """#.utf8
        )

        let document = try JSONDecoder().decode(PluginViewDocument.self, from: data)

        XCTAssertEqual(document.schemaVersion, 2)
        XCTAssertEqual(document.editor?.collection, "events")
        XCTAssertEqual(document.editor?.fields?.first?.type, "text")
        XCTAssertEqual(document.editor?.fields?.first?.role, "title")
    }

    func testCollectionDocumentDecodesCardMetadata() throws {
        let data = Data(
            #"""
            {
              "schemaVersion": 1,
              "presentation": "collection",
              "collectionStyle": "cards",
              "title": "공지사항",
              "subtitle": null,
              "search": null,
              "filters": [],
              "emptyState": null,
              "items": [
                {
                  "id": "notice-1",
                  "title": "수강신청 안내",
                  "subtitle": null,
                  "eyebrow": "공주대학교 · 컴퓨터공학과",
                  "meta": "2026-07-31",
                  "badge": "D-3",
                  "badgeTone": "danger",
                  "systemImage": "bell",
                  "body": "신청 기간과 절차를 확인하세요.",
                  "tags": ["수강", "3학년"],
                  "filterValues": {},
                  "action": null
                }
              ],
              "sections": null
            }
            """#.utf8
        )

        let document = try JSONDecoder().decode(PluginViewDocument.self, from: data)

        XCTAssertEqual(document.collectionStyle, "cards")
        XCTAssertEqual(document.items.first?.eyebrow, "공주대학교 · 컴퓨터공학과")
        XCTAssertEqual(document.items.first?.meta, "2026-07-31")
        XCTAssertEqual(document.items.first?.badge, "D-3")
        XCTAssertEqual(document.items.first?.badgeTone, "danger")
        XCTAssertEqual(document.items.first?.systemImage, "bell")
    }
}
