import XCTest
@testable import Codmes

final class PluginSurfaceDocumentTests: XCTestCase {
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

        let document = try JSONDecoder().decode(PluginSurfaceDocument.self, from: data)

        XCTAssertEqual(document.presentation, "dashboard")
        XCTAssertEqual(document.sections?.count, 2)
        XCTAssertEqual(document.sections?[0].fields?.first?.value, "20260001")
        XCTAssertEqual(document.sections?[1].rows?.first, ["1교시", "자료구조"])
    }
}
