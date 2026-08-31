import Foundation
#if os(iOS)
import UIKit
#endif

enum CodmesPlatform {
    static var current: String {
        #if os(macOS)
        return "macos"
        #elseif os(iOS)
        return "ios"
        #else
        return "unknown"
        #endif
    }

    static var currentFormFactor: String {
        #if os(macOS)
        return "desktop"
        #elseif os(iOS)
        return UIDevice.current.userInterfaceIdiom == .pad ? "tablet" : "phone"
        #else
        return "unknown"
        #endif
    }

    static func isSupported(
        by platforms: [String],
        formFactors: [String],
        current: String = current,
        currentFormFactor formFactor: String = currentFormFactor
    ) -> Bool {
        if platforms.isEmpty && formFactors.isEmpty { return true }
        let normalizedPlatforms = platforms.map {
            $0.caseInsensitiveCompare("ipados") == .orderedSame ? "ios" : $0.lowercased()
        }
        var normalizedFormFactors = formFactors.map { $0.lowercased() }
        if normalizedFormFactors.isEmpty {
            if platforms.contains(where: { $0.caseInsensitiveCompare("macos") == .orderedSame }) {
                normalizedFormFactors.append("desktop")
            }
            if platforms.contains(where: { $0.caseInsensitiveCompare("ios") == .orderedSame }) {
                normalizedFormFactors.append("phone")
            }
            if platforms.contains(where: { $0.caseInsensitiveCompare("ipados") == .orderedSame }) {
                normalizedFormFactors.append("tablet")
            }
        }
        if platforms.contains(where: { $0.caseInsensitiveCompare("ipados") == .orderedSame })
            && !normalizedFormFactors.contains("tablet") {
            normalizedFormFactors.append("tablet")
        }
        return normalizedPlatforms.contains(current.lowercased())
            && normalizedFormFactors.contains(formFactor.lowercased())
    }
}

struct WorkspaceInfo: Codable {
    struct Root: Codable, Identifiable {
        let id: String
        let name: String
        let path: String
    }

    struct LegacyHermesInfo: Codable {
        let serverUrl: String
        let dashboardLoginConfigured: Bool
    }

    struct RuntimeInfo: Codable {
        let status: String
        let owner: String?
        let configPath: String?
    }

    struct SearchInfo: Codable {
        let provider: String
        let available: Bool
        let indexed: Bool
        let realtimeIndexing: Bool
        let description: String
        let searchableExtensions: [String]
    }

    let rootName: String
    let workspaceRoot: String
    let roots: [Root]
    let runtime: RuntimeInfo?
    let hermes: LegacyHermesInfo?
    let search: SearchInfo?
}

struct TreeResponse: Codable {
    let path: String
    let children: [WorkspaceItem]
}

struct WorkspaceItem: Codable, Identifiable, Hashable {
    var id: String { path }
    let name: String
    let path: String
    let kind: String
    let isDirectory: Bool
    let size: Int
    let modifiedAt: String
}

struct FileResponse: Codable {
    let path: String
    let name: String
    let kind: String
    let size: Int
    let modifiedAt: String
    var content: String
}

struct FileWriteResponse: Codable {
    let ok: Bool
    let path: String
    let size: Int
    let modifiedAt: String
}

struct RawFilePreview: Identifiable {
    var id: String { path }
    let path: String
    let name: String
    let kind: String
    let url: URL
    let streamSession: StreamedPDFSession?

    init(path: String, name: String, kind: String, url: URL, streamSession: StreamedPDFSession? = nil) {
        self.path = path
        self.name = name
        self.kind = kind
        self.url = url
        self.streamSession = streamSession
    }
}

struct PDFMetadataResponse: Codable {
    let path: String
    let size: Int
    let pageCount: Int
    let pageWidth: Double
    let pageHeight: Double
}

struct PDFDocumentFocus: Equatable {
    let path: String
    let page: Int?
    let bbox: AnnotationBoundingBox?
    let requestId = UUID()
}

enum UploadStatus: String, Codable {
    case reading
    case uploading
    case completed
    case failed
    case cancelled

    var label: String {
        switch self {
        case .reading: "Reading"
        case .uploading: "Uploading"
        case .completed: "Done"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }

    var systemImage: String {
        switch self {
        case .reading: "doc"
        case .uploading: "arrow.up.circle"
        case .completed: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        case .cancelled: "xmark.circle"
        }
    }
}

struct UploadItem: Identifiable, Hashable {
    let id: UUID
    let root: String
    let fileName: String
    let destinationPath: String
    var status: UploadStatus
    var progress: Double
    var bytesSent: Int64
    var totalBytes: Int64
    var message: String

    var isActive: Bool {
        status == .reading || status == .uploading
    }
}

struct UploadStartResponse: Codable {
    let ok: Bool
    let uploadId: String
    let path: String
    let received: Int64
}

struct UploadChunkResponse: Codable {
    let ok: Bool
    let uploadId: String
    let received: Int64
    let size: Int64
}

struct DocumentJobsResponse: Codable {
    let jobs: [DocumentJob]
}

struct DocumentJob: Codable, Identifiable, Equatable {
    let id: String
    let kind: String
    let path: String
    let title: String
    let status: String
    let stage: String
    let stageLabel: String
    let progress: Double
    let completedUnits: Int?
    let totalUnits: Int?
    let startedAt: String
    let updatedAt: String
    let completedAt: String?
    let message: String?

    var isRunning: Bool {
        status == "running"
    }
}

struct PDFAnnotationDocument: Codable {
    var schemaVersion: Int
    var documentPath: String
    var updatedAt: String?
    var pages: [PDFAnnotationPage]
    var objects: [PDFAnnotationObject]
    var elements: [CodmesNoteElement]? = nil
}

struct PDFAnnotationPage: Codable, Identifiable {
    var id: Int { pageIndex }
    var pageIndex: Int
    var inkDataBase64: String?
    var inkStrokes: [CodmesInkStroke]? = nil
    var objects: [PDFAnnotationObject]?
    var elements: [CodmesNoteElement]? = nil
}

struct CodmesInkStroke: Codable, Identifiable {
    var id: String
    var tool: String
    var color: String
    var width: Double
    var opacity: Double?
    var points: [CodmesInkPoint]
}

struct CodmesInkPoint: Codable, Equatable {
    var x: Double
    var y: Double
    var pressure: Double?
    var timeOffset: Double?
}

struct PDFAnnotationObject: Codable, Identifiable {
    var id: String
    var type: String
    var pageIndex: Int?
    var bbox: AnnotationBoundingBox?
    var text: String?
    var dataBase64: String?
    var metadata: [String: String]?
}

struct CodmesNoteElement: Codable, Identifiable {
    var id: String
    var type: String
    var pageIndex: Int
    var bbox: AnnotationBoundingBox?
    var transform: CodmesNoteTransform?
    var style: CodmesNoteStyle?
    var zIndex: Int?
    var stroke: CodmesInkStroke?
    var shape: CodmesNoteShape?
    var text: String?
    var image: CodmesNoteImage?
    var metadata: [String: String]?
    var source: String?
}

struct CodmesNoteTransform: Codable, Equatable {
    var x: Double
    var y: Double
    var scaleX: Double
    var scaleY: Double
    var rotation: Double
}

struct CodmesNoteStyle: Codable, Equatable {
    var strokeColor: String?
    var fillColor: String?
    var lineWidth: Double?
    var opacity: Double?
    var fontSize: Double?
}

struct CodmesNoteShape: Codable, Equatable {
    var kind: String
    var points: [CodmesInkPoint]
}

struct CodmesNoteImage: Codable, Equatable {
    var dataBase64: String
    var mimeType: String?
}

struct AnnotationBoundingBox: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var normalized: NormalizedBoundingBox?
}

struct NormalizedBoundingBox: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}

extension AnnotationBoundingBox {
    var normalizedOrSelf: NormalizedBoundingBox? {
        if let normalized {
            return normalized
        }
        if x >= 0, y >= 0, width > 0, height > 0, x <= 1, y <= 1, width <= 1, height <= 1 {
            return NormalizedBoundingBox(x: x, y: y, width: width, height: height)
        }
        return nil
    }
}

struct CodmesNoteSelection: Equatable {
    var pageIndex: Int
    var strokeIds: Set<String>
    var objectIds: Set<String>
    var bounds: AnnotationBoundingBox
    var outline: [CodmesInkPoint]
}

enum CodmesNoteObjectResizeEdge {
    case left
    case right
    case bottomRight
}

enum CodmesNoteCanvasModel {
    static let textDraftMetadataKey = "draft"
    static let textManualWidthMetadataKey = "manualWidth"

    static func makeTextObject(
        pageIndex: Int,
        at point: CodmesInkPoint,
        width: Double = 0.055,
        height: Double = 0.035,
        fontSize: Int = 16,
        colorHex: String = "#111111"
    ) -> PDFAnnotationObject {
        let box = clampedBox(
            x: point.x,
            y: point.y,
            width: width,
            height: height
        )
        return PDFAnnotationObject(
            id: UUID().uuidString,
            type: "text",
            pageIndex: pageIndex,
            bbox: box,
            text: "",
            dataBase64: nil,
            metadata: [
                "fontSize": "\(fontSize)",
                "color": colorHex,
                textDraftMetadataKey: "true"
            ]
        )
    }

    static func object(at point: CodmesInkPoint, pageIndex: Int, objects: [PDFAnnotationObject]) -> PDFAnnotationObject? {
        objects.reversed().first { object in
            guard object.pageIndex == pageIndex, let box = object.bbox?.normalizedOrSelf else { return false }
            return contains(point, in: box)
        }
    }

    static func movedObject(_ object: PDFAnnotationObject, from startBox: NormalizedBoundingBox, deltaX: Double, deltaY: Double) -> PDFAnnotationObject {
        var next = object
        next.bbox = clampedBox(
            x: startBox.x + deltaX,
            y: startBox.y + deltaY,
            width: startBox.width,
            height: startBox.height
        )
        return next
    }

    static func resizedObject(
        _ object: PDFAnnotationObject,
        from startBox: NormalizedBoundingBox,
        edge: CodmesNoteObjectResizeEdge,
        deltaX: Double,
        deltaY: Double,
        minWidth: Double = 0.03,
        minHeight: Double = 0.025
    ) -> PDFAnnotationObject {
        var next = object
        var box = startBox
        switch edge {
        case .left:
            let proposedX = min(max(0, startBox.x + deltaX), startBox.x + startBox.width - minWidth)
            box.x = proposedX
            box.width = startBox.x + startBox.width - proposedX
        case .right:
            box.width = max(minWidth, min(1 - startBox.x, startBox.width + deltaX))
        case .bottomRight:
            box.width = max(minWidth, min(1 - startBox.x, startBox.width + deltaX))
            box.height = max(minHeight, min(1 - startBox.y, startBox.height + deltaY))
        }
        next.bbox = clampedBox(x: box.x, y: box.y, width: box.width, height: box.height)
        if next.type.lowercased().contains("text") {
            var metadata = next.metadata ?? [:]
            metadata[textManualWidthMetadataKey] = "true"
            next.metadata = metadata
        }
        return next
    }

    static func selection(
        pageIndex: Int,
        outline: [CodmesInkPoint],
        strokes: [CodmesInkStroke],
        objects: [PDFAnnotationObject]
    ) -> CodmesNoteSelection? {
        guard let bounds = bounds(for: outline) else { return nil }
        let selectedStrokeIds = Set(strokes.filter {
            strokeIntersectsLasso($0, polygon: outline, lassoBounds: bounds)
        }.map(\.id))
        let selectedObjectIds = Set(objects.filter { object in
            guard object.pageIndex == pageIndex, let box = object.bbox?.normalizedOrSelf else { return false }
            return objectIntersectsLasso(box: box, polygon: outline, lassoBounds: bounds)
        }.map(\.id))
        guard !selectedStrokeIds.isEmpty || !selectedObjectIds.isEmpty else { return nil }
        return CodmesNoteSelection(
            pageIndex: pageIndex,
            strokeIds: selectedStrokeIds,
            objectIds: selectedObjectIds,
            bounds: bounds,
            outline: outline
        )
    }

    static func bounds(for points: [CodmesInkPoint]) -> AnnotationBoundingBox? {
        guard let first = points.first else { return nil }
        var minX = first.x
        var maxX = first.x
        var minY = first.y
        var maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        return AnnotationBoundingBox(
            x: minX,
            y: minY,
            width: max(0.01, maxX - minX),
            height: max(0.01, maxY - minY),
            normalized: nil
        )
    }

    static func contains(_ point: CodmesInkPoint, in box: NormalizedBoundingBox) -> Bool {
        point.x >= box.x &&
            point.x <= box.x + box.width &&
            point.y >= box.y &&
            point.y <= box.y + box.height
    }

    static func contains(_ point: CodmesInkPoint, in polygon: [CodmesInkPoint]) -> Bool {
        guard polygon.count > 2 else { return false }
        var inside = false
        var previous = polygon[polygon.count - 1]
        for current in polygon {
            let crosses = (current.y > point.y) != (previous.y > point.y)
            if crosses {
                let denominator = previous.y - current.y
                guard abs(denominator) > 0.000001 else {
                    previous = current
                    continue
                }
                let x = (previous.x - current.x) * (point.y - current.y) / denominator + current.x
                if point.x < x {
                    inside.toggle()
                }
            }
            previous = current
        }
        return inside
    }

    static func boxesIntersect(_ a: NormalizedBoundingBox, _ b: NormalizedBoundingBox) -> Bool {
        a.x < b.x + b.width &&
            a.x + a.width > b.x &&
            a.y < b.y + b.height &&
            a.y + a.height > b.y
    }

    static func clampedBox(x: Double, y: Double, width: Double, height: Double) -> AnnotationBoundingBox {
        let safeWidth = min(max(width, 0.001), 1)
        let safeHeight = min(max(height, 0.001), 1)
        let safeX = min(max(x, 0), max(0, 1 - safeWidth))
        let safeY = min(max(y, 0), max(0, 1 - safeHeight))
        return AnnotationBoundingBox(
            x: safeX,
            y: safeY,
            width: safeWidth,
            height: safeHeight,
            normalized: nil
        )
    }

    private static func strokeIntersectsLasso(_ stroke: CodmesInkStroke, polygon: [CodmesInkPoint], lassoBounds: AnnotationBoundingBox) -> Bool {
        guard stroke.points.count > 1 else { return false }
        if stroke.points.contains(where: { contains($0, in: polygon) }) {
            return true
        }
        if let strokeBounds = bounds(for: stroke.points)?.normalizedOrSelf,
           let lassoBox = lassoBounds.normalizedOrSelf,
           !boxesIntersect(strokeBounds, lassoBox) {
            return false
        }
        let lassoSegments = polygonSegments(polygon)
        for strokeSegment in zip(stroke.points, stroke.points.dropFirst()) {
            if lassoSegments.contains(where: { segmentsIntersect(strokeSegment.0, strokeSegment.1, $0.0, $0.1) }) {
                return true
            }
            if polygon.contains(where: { distance($0, toSegmentStart: strokeSegment.0, end: strokeSegment.1) < 0.006 }) {
                return true
            }
        }
        return false
    }

    private static func objectIntersectsLasso(box: NormalizedBoundingBox, polygon: [CodmesInkPoint], lassoBounds: AnnotationBoundingBox) -> Bool {
        let center = CodmesInkPoint(x: box.x + box.width / 2, y: box.y + box.height / 2, pressure: nil, timeOffset: nil)
        let corners = [
            CodmesInkPoint(x: box.x, y: box.y, pressure: nil, timeOffset: nil),
            CodmesInkPoint(x: box.x + box.width, y: box.y, pressure: nil, timeOffset: nil),
            CodmesInkPoint(x: box.x, y: box.y + box.height, pressure: nil, timeOffset: nil),
            CodmesInkPoint(x: box.x + box.width, y: box.y + box.height, pressure: nil, timeOffset: nil)
        ]
        return contains(center, in: polygon)
            || corners.contains { contains($0, in: polygon) }
            || (lassoBounds.normalizedOrSelf.map { boxesIntersect(box, $0) } ?? false)
    }

    private static func polygonSegments(_ polygon: [CodmesInkPoint]) -> [(CodmesInkPoint, CodmesInkPoint)] {
        guard polygon.count > 1 else { return [] }
        return Array(zip(polygon, polygon.dropFirst())) + [(polygon[polygon.count - 1], polygon[0])]
    }

    private static func segmentsIntersect(_ a: CodmesInkPoint, _ b: CodmesInkPoint, _ c: CodmesInkPoint, _ d: CodmesInkPoint) -> Bool {
        func ccw(_ p1: CodmesInkPoint, _ p2: CodmesInkPoint, _ p3: CodmesInkPoint) -> Bool {
            (p3.y - p1.y) * (p2.x - p1.x) > (p2.y - p1.y) * (p3.x - p1.x)
        }
        return ccw(a, c, d) != ccw(b, c, d) && ccw(a, b, c) != ccw(a, b, d)
    }

    private static func distance(_ point: CodmesInkPoint, toSegmentStart start: CodmesInkPoint, end: CodmesInkPoint) -> Double {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else {
            return hypot(point.x - start.x, point.y - start.y)
        }
        let t = max(0, min(1, ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared))
        let projectedX = start.x + t * dx
        let projectedY = start.y + t * dy
        return hypot(point.x - projectedX, point.y - projectedY)
    }
}

extension PDFAnnotationDocument {
    func noteElements(pageIndex: Int) -> [CodmesNoteElement] {
        var result: [CodmesNoteElement] = []
        var seen = Set<String>()

        func append(_ element: CodmesNoteElement) {
            guard element.pageIndex == pageIndex, !seen.contains(element.id) else { return }
            seen.insert(element.id)
            result.append(element)
        }

        if let page = pages.first(where: { $0.pageIndex == pageIndex }) {
            for element in page.elements ?? [] {
                append(element)
            }
        }
        for element in elements ?? [] {
            append(element)
        }

        if result.isEmpty, let page = pages.first(where: { $0.pageIndex == pageIndex }) {
            for element in page.noteElementsFromLegacy() {
                append(element)
            }
            for object in objects where object.pageIndex == pageIndex {
                append(object.noteElement(pageIndex: pageIndex))
            }
        }

        return result.sorted { ($0.zIndex ?? 0, $0.id) < ($1.zIndex ?? 0, $1.id) }
    }

    func noteStrokes(pageIndex: Int) -> [CodmesInkStroke] {
        noteElements(pageIndex: pageIndex).compactMap(\.stroke)
    }

    func noteObjects(pageIndex: Int) -> [PDFAnnotationObject] {
        noteElements(pageIndex: pageIndex).compactMap { $0.annotationObject() }
    }

    mutating func syncNoteElementsFromLegacy() {
        schemaVersion = max(schemaVersion, 2)
        pages = pages.map { page in
            var copy = page
            let legacyElements = page.noteElementsFromLegacy()
            let legacyIds = Set(legacyElements.map(\.id))
            let retainedElements = (page.elements ?? []).filter { element in
                !legacyIds.contains(element.id) && element.isEditableElementSource
            }
            copy.elements = legacyElements + retainedElements
            return copy
        }
        let legacyRootElements: [CodmesNoteElement] = self.objects.compactMap { object in
            guard let pageIndex = object.pageIndex else { return nil }
            return object.noteElement(pageIndex: pageIndex)
        }
        let legacyRootIds = Set(legacyRootElements.map { $0.id })
        let retainedRootElements = (self.elements ?? []).filter { element in
            !legacyRootIds.contains(element.id) && element.isEditableElementSource
        }
        self.elements = legacyRootElements + retainedRootElements
    }

    func syncedNoteElementsFromLegacy() -> PDFAnnotationDocument {
        var copy = self
        copy.syncNoteElementsFromLegacy()
        return copy
    }
}

extension PDFAnnotationPage {
    func noteElementsFromLegacy() -> [CodmesNoteElement] {
        let strokeElements = (inkStrokes ?? []).map { $0.noteElement(pageIndex: pageIndex) }
        let objectElements = (objects ?? []).map { $0.noteElement(pageIndex: $0.pageIndex ?? pageIndex) }
        return strokeElements + objectElements
    }
}

extension CodmesInkStroke {
    func noteElement(pageIndex: Int) -> CodmesNoteElement {
        let shapeKind = metadataShapeKind
        return CodmesNoteElement(
            id: id,
            type: shapeKind == nil ? "stroke" : "shape",
            pageIndex: pageIndex,
            bbox: nil,
            transform: CodmesNoteTransform.identity,
            style: CodmesNoteStyle(
                strokeColor: color,
                fillColor: nil,
                lineWidth: width,
                opacity: opacity,
                fontSize: nil
            ),
            zIndex: nil,
            stroke: self,
            shape: shapeKind.map { CodmesNoteShape(kind: $0, points: points) },
            text: nil,
            image: nil,
            metadata: ["tool": tool],
            source: "legacyInkStroke"
        )
    }

    private var metadataShapeKind: String? {
        if tool.hasPrefix("shape:") {
            return String(tool.dropFirst("shape:".count))
        }
        if tool == "line" || tool == "polyline" || tool == "triangle" || tool == "rectangle" || tool == "circle" || tool == "ellipse" {
            return tool
        }
        return nil
    }
}

extension PDFAnnotationObject {
    func noteElement(pageIndex: Int) -> CodmesNoteElement {
        let objectType = type.lowercased().contains("image") ? "image" : (type.lowercased().contains("text") ? "text" : type)
        let fontSize = Double(metadata?["fontSize"] ?? "")
        let color = metadata?["color"]
        return CodmesNoteElement(
            id: id,
            type: objectType,
            pageIndex: pageIndex,
            bbox: bbox,
            transform: CodmesNoteTransform.identity,
            style: CodmesNoteStyle(
                strokeColor: color,
                fillColor: nil,
                lineWidth: nil,
                opacity: nil,
                fontSize: fontSize
            ),
            zIndex: nil,
            stroke: nil,
            shape: nil,
            text: text,
            image: dataBase64.map { CodmesNoteImage(dataBase64: $0, mimeType: metadata?["mimeType"]) },
            metadata: metadata,
            source: "legacyAnnotationObject"
        )
    }
}

extension CodmesNoteElement {
    var isEditableElementSource: Bool {
        source != "legacyInkStroke" && source != "legacyAnnotationObject"
    }

    func annotationObject() -> PDFAnnotationObject? {
        guard type.lowercased().contains("text") || type.lowercased().contains("image") else { return nil }
        var nextMetadata = metadata ?? [:]
        if let fontSize = style?.fontSize {
            nextMetadata["fontSize"] = String(Int(fontSize))
        }
        if let color = style?.strokeColor ?? style?.fillColor {
            nextMetadata["color"] = color
        }
        if let mimeType = image?.mimeType {
            nextMetadata["mimeType"] = mimeType
        }
        return PDFAnnotationObject(
            id: id,
            type: type,
            pageIndex: pageIndex,
            bbox: bbox,
            text: text,
            dataBase64: image?.dataBase64,
            metadata: nextMetadata.isEmpty ? nil : nextMetadata
        )
    }

    func replacing(stroke nextStroke: CodmesInkStroke) -> CodmesNoteElement {
        var copy = self
        copy.stroke = nextStroke
        let shapeKind = nextStroke.shapeKind
        copy.type = shapeKind == nil ? "stroke" : "shape"
        copy.shape = shapeKind.map { CodmesNoteShape(kind: $0, points: nextStroke.points) }
        copy.style = CodmesNoteStyle(
            strokeColor: nextStroke.color,
            fillColor: style?.fillColor,
            lineWidth: nextStroke.width,
            opacity: nextStroke.opacity,
            fontSize: style?.fontSize
        )
        var nextMetadata = copy.metadata ?? [:]
        nextMetadata["tool"] = nextStroke.tool
        copy.metadata = nextMetadata
        return copy
    }

    func replacing(object: PDFAnnotationObject) -> CodmesNoteElement {
        var copy = self
        copy.type = object.type
        copy.pageIndex = object.pageIndex ?? pageIndex
        copy.bbox = object.bbox
        copy.text = object.text
        copy.image = object.dataBase64.map { CodmesNoteImage(dataBase64: $0, mimeType: object.metadata?["mimeType"]) }
        copy.metadata = object.metadata
        copy.style = CodmesNoteStyle(
            strokeColor: object.metadata?["color"],
            fillColor: nil,
            lineWidth: nil,
            opacity: nil,
            fontSize: Double(object.metadata?["fontSize"] ?? "")
        )
        return copy
    }
}

extension CodmesInkStroke {
    var shapeKind: String? {
        if tool.hasPrefix("shape:") {
            return String(tool.dropFirst("shape:".count))
        }
        if tool == "line" || tool == "polyline" || tool == "triangle" || tool == "rectangle" || tool == "circle" || tool == "ellipse" {
            return tool
        }
        return nil
    }
}

extension CodmesNoteTransform {
    static var identity: CodmesNoteTransform {
        CodmesNoteTransform(x: 0, y: 0, scaleX: 1, scaleY: 1, rotation: 0)
    }
}

struct SearchResponse: Codable {
    struct Result: Codable, Identifiable {
        var id: String { path }
        let path: String
        let kind: String
        let size: Int
        let modifiedAt: String
        let score: Double
        let snippet: String
        let source: String?
        let page: Int?
        let bbox: AnnotationBoundingBox?
    }

    let provider: String
    let query: String
    let scopePath: String
    let totalCandidates: Int
    let resultCount: Int
    let results: [Result]
}

struct GlobalSearchResponse: Codable {
    let provider: String
    let query: String
    let surface: String
    let resultCount: Int
    let returnedCount: Int?
    let nextCursor: String?
    let hasMore: Bool?
    let documents: [GlobalSearchDocumentSummary]?
    let results: [GlobalSearchResult]
}

struct GlobalSearchDocumentSummary: Codable, Identifiable {
    var id: String { path }
    let path: String
    let title: String
    let surface: String
    let titleMatch: String
    let matchedPageCount: Int
    let occurrenceCount: Int
}

struct GlobalSearchResult: Codable, Identifiable {
    let id: String
    let surface: String
    let kind: String
    let title: String
    let subtitle: String
    let snippet: String
    let score: Double
    let updatedAt: String?
    let target: GlobalSearchTarget
}

struct GlobalSearchTarget: Codable {
    let path: String?
    let page: Int?
    let sessionId: String?
    let messageId: String?
    let projectId: String?
    let line: Int?
    let bbox: AnnotationBoundingBox?
}

struct RuntimePluginsResponse: Codable {
    let plugins: [RuntimePlugin]
}

struct RuntimePlugin: Codable, Identifiable, Hashable {
    let id: String
    let version: String
    let name: String
    let description: String
    let publisher: String
    let icon: String
    let platforms: [String]
    let formFactors: [String]?
    let permissions: [String]
    let distribution: String
    let builtIn: Bool
    let removable: Bool
    let enabled: Bool
    let views: [PluginView]
    let toolNames: [String]

    var systemImage: String { icon.isEmpty ? "shippingbox" : icon }
    var supportsCurrentPlatform: Bool {
        CodmesPlatform.isSupported(by: platforms, formFactors: formFactors ?? [])
    }
}

struct MarketplacePluginsResponse: Codable {
    let schemaVersion: Int
    let source: String
    let plugins: [MarketplacePlugin]
}

struct MarketplacePlugin: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let version: String
    let description: String
    let publisher: String
    let category: String
    let icon: String
    let verified: Bool
    let featured: Bool
    let platforms: [String]
    let formFactors: [String]?
    let permissions: [String]
    let repositoryUrl: String?
    let privacyUrl: String?
    let installed: Bool
    let installedVersion: String?
    let updateAvailable: Bool
    let canRollback: Bool
    let previousVersion: String?
    let releaseNotes: String
    let dataVersion: Int
    let addedPermissions: [String]
    let permissionChangeRequired: Bool
    let blocked: Bool
    let blockReason: String?
    let installedVersionBlocked: Bool
    let installedBlockReason: String?
    let rollbackBlockedReason: String?

    var systemImage: String { icon.isEmpty ? "shippingbox" : icon }
    var supportsCurrentPlatform: Bool {
        CodmesPlatform.isSupported(by: platforms, formFactors: formFactors ?? [])
    }
}

struct PluginView: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let kind: String?
    let icon: String?
    let enabled: Bool?
    let removable: Bool?
    let order: Int?
    let description: String?
    let prompt: String?
    let root: String?
    let pluginId: String?
    let pluginName: String?
    let distribution: String?
    let renderer: String?
    let dataPath: String?
    let navigation: [PluginSurfaceNavigationItem]?
    let hasAuthentication: Bool?

    var isEnabled: Bool { enabled ?? true }
    var canRemove: Bool { removable ?? true }
    var systemImage: String { icon?.isEmpty == false ? icon! : "square.grid.2x2" }
}

struct PluginSurfaceNavigationItem: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let icon: String?
    let path: String?
    let requiresAuth: Bool?

    var systemImage: String { icon?.isEmpty == false ? icon! : "square.grid.2x2" }
}

struct PluginAuthStatus: Codable, Equatable {
    let supported: Bool?
    let authenticated: Bool
    let username: String?
    let reachable: Bool?
    let studentId: String?
    let name: String?
    let major: String?
    let year: Int?
    let profileSyncing: Bool?
    let syncStage: String?
    let portalSyncError: String?
    let lmsSyncError: String?

    init(
        supported: Bool?,
        authenticated: Bool,
        username: String?,
        reachable: Bool?,
        studentId: String? = nil,
        name: String? = nil,
        major: String? = nil,
        year: Int? = nil,
        profileSyncing: Bool? = nil,
        syncStage: String? = nil,
        portalSyncError: String? = nil,
        lmsSyncError: String? = nil
    ) {
        self.supported = supported
        self.authenticated = authenticated
        self.username = username
        self.reachable = reachable
        self.studentId = studentId
        self.name = name
        self.major = major
        self.year = year
        self.profileSyncing = profileSyncing
        self.syncStage = syncStage
        self.portalSyncError = portalSyncError
        self.lmsSyncError = lmsSyncError
    }
}

struct PluginAuthLoginResponse: Codable {
    let authenticated: Bool
    let username: String?
}

struct PluginAuthLogoutResponse: Codable {
    let authenticated: Bool
    let removed: Bool?
}

struct PluginViewDocument: Codable {
    let schemaVersion: Int
    let presentation: String
    let collectionStyle: String?
    let title: String
    let subtitle: String?
    let search: PluginSurfaceSearch?
    let filters: [PluginSurfaceFilter]
    let emptyState: PluginSurfaceEmptyState?
    let items: [PluginSurfaceItem]
    let sections: [PluginSurfaceSection]?
    let editor: PluginSurfaceEditor?
    let dataState: PluginSurfaceDataState?
}

struct PluginSurfaceDataState: Codable {
    let status: String
    let errors: [PluginSurfaceDataSourceError]
}

struct PluginSurfaceDataSourceError: Codable, Identifiable {
    var id: String { sourceId }
    let sourceId: String
    let message: String
    let retryable: Bool
}

struct PluginSurfaceEditor: Codable, Hashable {
    let collection: String
    let fields: [PluginSurfaceEditorField]?
}

struct PluginSurfaceEditorField: Codable, Identifiable, Hashable {
    let id: String
    let label: String
    let type: String
    let required: Bool
    let placeholder: String?
    let role: String?
}

enum PluginSurfaceEditorValue: Codable, Hashable {
    case string(String)
    case boolean(Bool)
    case number(Double)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value):
            try container.encode(value)
        case let .boolean(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        }
    }

    var stringValue: String {
        switch self {
        case let .string(value): value
        case let .boolean(value): value ? "true" : "false"
        case let .number(value): String(value)
        }
    }

    var booleanValue: Bool {
        if case let .boolean(value) = self { return value }
        return stringValue.lowercased() == "true"
    }
}

struct PluginSurfaceSearch: Codable {
    let placeholder: String?
    let fields: [String]
}

struct PluginSurfaceFilter: Codable, Identifiable {
    let id: String
    let label: String?
    let style: String?
    let options: [PluginSurfaceFilterOption]
}

struct PluginSurfaceFilterOption: Codable, Identifiable {
    var id: String { value }
    let value: String
    let label: String
}

struct PluginSurfaceEmptyState: Codable {
    let title: String
    let systemImage: String?
}

struct PluginSurfaceItem: Codable, Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let body: String?
    let tags: [String]
    let filterValues: [String: String]
    let action: PluginSurfaceAction?
    let eyebrow: String?
    let meta: String?
    let badge: String?
    let badgeTone: String?
    let systemImage: String?
    let temporal: PluginSurfaceTemporal?
    let editorValues: [String: PluginSurfaceEditorValue]?
}

struct PluginSurfaceTemporal: Codable, Hashable {
    let startsAt: String
    let endsAt: String?
    let allDay: Bool
}

struct PluginSurfaceAction: Codable {
    let type: String
    let url: String?
}

struct PluginSurfaceSection: Codable, Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let systemImage: String?
    let kind: String
    let fields: [PluginSurfaceField]?
    let columns: [String]?
    let rows: [[String]]?
}

struct PluginSurfaceField: Codable, Identifiable {
    let id: String
    let label: String
    let value: String
}

struct PluginConfigurationBody: Encodable {
    let enabled: Bool?
    let remove: Bool?
}

struct MCPServersResponse: Codable {
    let servers: [MCPServerConfig]
}

struct MCPServerConfig: Codable, Identifiable, Hashable {
    var id: String { name }
    let name: String
    let transport: String?
    let command: String?
    let args: [String]?
    let enabled: Bool?
    let env: [String: String]?
    let scopePath: String?
    let url: String?
    let credentialId: String?
    let surfaces: [String]?
    let credentialConfigured: Bool?

    var isEnabled: Bool { enabled ?? true }
    var isRemote: Bool { transport == "streamable_http" }
    var argsText: String { (args ?? []).joined(separator: " ") }
    var envText: String {
        (env ?? [:])
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "\n")
    }

    enum CodingKeys: String, CodingKey { case name, transport, command, args, enabled, env, scopePath, url, credentialId = "credential_id", surfaces, credentialConfigured }
}

struct MCPServerUpdateBody: Encodable {
    let name: String?
    let transport: String
    let command: String?
    let args: [String]?
    let enabled: Bool
    let env: [String: String]?
    let scopePath: String?
    let url: String?
    let credentialId: String?
    let surfaces: [String]?

    enum CodingKeys: String, CodingKey { case name, transport, command, args, enabled, env, scopePath, url, credentialId = "credential_id", surfaces }
}

struct SearchConfigResponse: Codable {
    let ok: Bool?
    let configPath: String
    let roots: [String]
    let includeGlobs: [String]
    let excludeGlobs: [String]
    let embeddingsProvider: String
    let openaiBaseUrl: String
    let openaiApiKeyConfigured: Bool
    let openaiEmbedModel: String
    let openaiEmbedDim: Int
    let vlmProvider: String?
    let vlmModel: String?
    let vlmBaseUrl: String?
    let vlmApiKeyConfigured: Bool?
    let dbPath: String
    let backend: String?
}

struct SearchConfigUpdateBody: Encodable {
    let roots: [String]
    let embeddingsProvider: String
    let openaiBaseUrl: String
    let openaiApiKey: String?
    let openaiEmbedModel: String
    let openaiEmbedDim: Int
    let vlmProvider: String?
    let vlmModel: String?
    let vlmBaseUrl: String?
    let vlmApiKey: String?
    let includeGlobs: [String]?
    let excludeGlobs: [String]?
    let dbPath: String?
}

struct AgentTasksResponse: Codable {
    let tasks: [AgentTaskSummary]
}

struct AgentTaskSummary: Codable, Identifiable, Hashable {
    let id: String
    let type: String?
    let status: String?
    let createdAt: String?
    let updatedAt: String?
    let runtime: String?
    let sessionId: String?
    let scopePath: String?
    let message: String?
    let summary: String?
    let approvalIds: [String]?
    let hasPendingState: Bool?
    let error: String?
}

struct AgentTaskActionResponse: Codable {
    let ok: Bool?
    let engine: String?
    let runtime: String?
    let status: String?
    let task: AgentTaskSummary?
    let alreadyResolved: Bool?
}

struct CodeTaskRecord: Codable, Identifiable {
    struct Plan: Codable {
        struct Step: Codable, Identifiable {
            var id: String { title }
            let title: String
            let status: String?
            let detail: String?
        }

        let summary: String?
        let instruction: String?
        let steps: [Step]?
        let risks: [String]?
    }

    struct GitInfo: Codable {
        let isRepository: Bool?
        let root: String?
        let status: String?
        let diffStat: String?
        let diffRef: String?
    }

    let id: String
    let type: String?
    let status: String?
    let createdAt: String?
    let updatedAt: String?
    let message: String?
    let scopePath: String?
    let plan: Plan?
    let git: GitInfo?
    let taskMemory: CodeTaskMemory?
    let patchProposals: [CodePatchProposal]?
    let checks: [CodeCheckRun]?
    let filesChanged: [String]?
}

struct CodeTaskMemory: Codable, Hashable {
    let readFiles: [String]
    let proposedFiles: [String]
    let changedFiles: [String]
    let commands: [String]
    let checkResults: [CodeCheckSummary]
    let failureLogs: [CodeFailureLog]
    let nextSteps: [String]
    let notes: [String]
}

struct CodeCheckSummary: Codable, Hashable, Identifiable {
    let id: String
    let allPassed: Bool?
    let finishedAt: String?
    let results: [CodeCheckCommandSummary]?
}

struct CodeCheckRun: Codable, Hashable, Identifiable {
    let id: String
    let approved: Bool?
    let startedAt: String?
    let finishedAt: String?
    let scopePath: String?
    let commands: [String]?
    let allPassed: Bool?
    let results: [CodeCheckCommandResult]?
}

struct CodeCheckCommandResult: Codable, Hashable {
    let command: String?
    let ok: Bool?
    let exitCode: Int?
    let signal: String?
    let durationMs: Int?
    let stdout: String?
    let stderr: String?
}

struct CodeCheckCommandSummary: Codable, Hashable {
    let command: String?
    let ok: Bool?
    let exitCode: Int?
    let durationMs: Int?
}

struct CodeFailureLog: Codable, Hashable {
    let command: String?
    let exitCode: Int?
    let stderr: String?
    let stdout: String?
}

struct CodePatchProposal: Codable, Hashable, Identifiable {
    struct Change: Codable, Hashable, Identifiable {
        var id: String { path }
        let operation: String?
        let path: String
        let existed: Bool?
        let oldHash: String?
        let newHash: String?
        let oldSize: Int?
        let newSize: Int?
    }

    let id: String
    let status: String?
    let approved: Bool?
    let createdAt: String?
    let appliedAt: String?
    let rejectedAt: String?
    let rejectionReason: String?
    let scopePath: String?
    let summary: String?
    let diffRef: String?
    let changes: [Change]?
    let filesChanged: [String]?
}

struct CodeTaskResponse: Codable {
    let ok: Bool
    let engine: String?
    let runtime: String?
    let taskId: String
    let status: String?
    let scopePath: String?
    let summary: String?
    let plan: CodeTaskRecord.Plan?
    let git: CodeTaskRecord.GitInfo?
    let taskMemory: CodeTaskMemory?
}

struct CodePatchApplyResponse: Codable {
    let ok: Bool
    let engine: String?
    let runtime: String?
    let taskId: String
    let status: String?
    let scopePath: String?
    let proposalId: String?
    let filesChanged: [String]?
    let git: CodeTaskRecord.GitInfo?
    let taskMemory: CodeTaskMemory?
    let checkRun: CodeCheckRun?
    let checkApprovalRequired: Bool?
}

struct CodePatchRejectResponse: Codable {
    let ok: Bool
    let engine: String?
    let runtime: String?
    let taskId: String
    let status: String?
    let scopePath: String?
    let proposalId: String?
    let taskMemory: CodeTaskMemory?
}

struct CodeChecksResponse: Codable {
    let ok: Bool
    let engine: String?
    let runtime: String?
    let taskId: String
    let status: String?
    let scopePath: String?
    let taskMemory: CodeTaskMemory?
}

struct RenderedMarkdownResponse: Codable {
    let html: String
}

struct HealthResponse: Codable {
    let ok: Bool
    let service: String
}

struct HermesModelOption: Identifiable, Hashable {
    var id: String { provider.map { "\($0):\(model)" } ?? model }
    let label: String
    let provider: String?
    let model: String

    var shortLabel: String {
        let value = model
            .split(separator: "/")
            .last
            .map(String.init) ?? model
        guard value.count > 14 else { return value }
        return String(value.prefix(11)) + "..."
    }
}

struct HermesModelGroup: Identifiable, Hashable {
    let id: String
    let title: String
    let models: [HermesModelOption]
}

struct RuntimeProvidersResponse: Codable {
    let providers: [RuntimeProviderOption]
}

struct RuntimeProviderOption: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let authType: String
    let tab: String?
    let env: [String]?
    let baseUrlEnv: String?
    let defaultBaseUrl: String?
    let models: [String]?
    let configured: Bool?
    let isDefault: Bool?

    var needsAPIKey: Bool { authType == "api_key" }
    var isOAuth: Bool { authType.hasPrefix("oauth") }
    var isLocalOllama: Bool { id == "ollama-local" }
    var isLocalProvider: Bool { tab == "local" || authType == "none" || isLocalOllama }
    var sectionTitle: String {
        if isLocalProvider { return "Local" }
        if isOAuth || authType == "external_process" { return "Accounts" }
        return "API Keys"
    }
    var setupHint: String {
        if isLocalOllama { return "Uses the Workspace Server's local Ollama endpoint." }
        if isOAuth { return "Account sign-in is managed by the Codmes Server runtime." }
        if needsAPIKey { return "Stores an API key in the server runtime config." }
        return "No API key is required."
    }
}

struct RuntimeProviderModelsResponse: Codable {
    let provider: String
    let source: String
    let baseUrl: String?
    let models: [String]
}

struct RuntimeProviderAuthResponse: Codable {
    let provider: String
    let credentials: [RuntimeCredentialEntry]
}

struct RuntimeCredentialEntry: Codable, Identifiable, Hashable {
    let id: String
    let label: String?
    let authType: String?
    let source: String?
    let priority: Int?
    let active: Bool?
    let hasAccessToken: Bool?
    let hasRefreshToken: Bool?
    let baseUrl: String?
    let accountId: String?
    let email: String?
    let expiresAt: String?

    var displayName: String {
        if let email, !email.isEmpty { return email }
        if let label, !label.isEmpty { return label }
        if let accountId, !accountId.isEmpty { return "Account \(accountId.prefix(8))..." }
        return id
    }

    var detailLabel: String {
        var parts: [String] = []
        if let authType, !authType.isEmpty {
            parts.append(authType)
        }
        if let source, !source.isEmpty {
            parts.append(source)
        }
        if active == true {
            parts.append("active")
        }
        return parts.isEmpty ? id : parts.joined(separator: " · ")
    }
}

struct RuntimeOAuthLoginSession: Codable, Identifiable, Hashable {
    let id: String
    let provider: String
    let status: String
    let userCode: String?
    let verificationUrl: String?
    let intervalSeconds: Int?
    let createdAt: String?
    let expiresAt: String?
    let credential: RuntimeCredentialEntry?
    let error: String?

    var isTerminal: Bool {
        ["approved", "expired", "error", "canceled"].contains(status)
    }
}

struct RuntimeDefaultModelResponse: Codable {
    let defaultModel: RuntimeDefaultModel?
}

struct RuntimeDefaultModel: Codable, Hashable {
    let provider: String?
    let model: String?
    let id: String?
    let baseUrl: String?
    let apiMode: String?
}

struct WorkspaceApprovalsResponse: Codable {
    let approvals: [WorkspaceApproval]
}

struct WorkspaceApproval: Codable, Identifiable, Hashable {
    let id: String
    let type: String?
    let status: String?
    let category: String?
    let createdAt: String?
    let updatedAt: String?
    let respondedAt: String?
    let taskId: String?
    let proposalId: String?
    let scopePath: String?
    let summary: String?
    let diffRef: String?
    let commands: [String]?
    let reason: String?
    let hasPendingState: Bool?
    let pluginPreview: PluginApprovalPreview?
}

struct PluginApprovalPreview: Codable, Hashable {
    let pluginId: String
    let collection: String
    let operation: String
    let itemId: String?
    let beforeText: String?
    let afterText: String?
}

struct WorkspaceApprovalRespondResponse: Codable {
    let ok: Bool?
    let engine: String?
    let runtime: String?
    let status: String?
    let approval: WorkspaceApproval?
    let result: AgentTaskActionResponse?
}

struct HermesSessionSummary: Identifiable, Hashable {
    let id: String
    let title: String
    let updatedAt: String?
    let folderId: String?
    let folderTitle: String?
    let projectId: String?
    let projectTitle: String?
    let pinned: Bool
}

struct HermesSessionProject: Identifiable, Hashable {
    let id: String
    let title: String
    let sessionCount: Int
}

struct ConversationFolder: Identifiable, Codable, Hashable {
    let id: String
    var name: String
    var icon: String?
    var color: String?
    var createdAt: String?
    var updatedAt: String?
}

struct MarkdownTable: Identifiable {
    let id = UUID()
    let rows: [[String]]
}

enum MarkdownBlock: Identifiable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet(String)
    case ordered(index: Int, text: String)
    case task(checked: Bool, text: String)
    case quote(String)
    case horizontalRule
    case code(language: String?, text: String)
    case table(MarkdownTable)

    var id: UUID { UUID() }
}

struct HermesSessionMessagesResponse: Codable {
    let sessionId: String?
    let messages: [HermesSessionMessage]
}

struct HermesSessionMessage: Codable, Identifiable, Hashable {
    let id: String
    let role: String
    let content: String
    let timestamp: String?
    let toolName: String?
    let finishReason: String?
    let reasoning: String?
}

enum WorkspaceSection: String, CaseIterable, Identifiable {
    case chat = "Chat"
    case notes = "Notes"
    case code = "Code"

    var id: String { rawValue }

    var runtimeSurfaceId: String {
        switch self {
        case .chat: "chat"
        case .notes: "notes"
        case .code: "code"
        }
    }

    var systemImage: String {
        switch self {
        case .chat: "message"
        case .notes: "doc.text"
        case .code: "chevron.left.forwardslash.chevron.right"
        }
    }
}

struct ChatLine: Identifiable, Equatable {
    let id: UUID
    let role: String
    var text: String
    var approvalState: ApprovalState?
    let approvalId: String?
    var activityItems: [ChatActivity]
    var isStreamingActivity: Bool

    init(id: UUID = UUID(), role: String, text: String, approvalState: ApprovalState? = nil, approvalId: String? = nil, activityItems: [ChatActivity] = [], isStreamingActivity: Bool = false) {
        self.id = id
        self.role = role
        self.text = text
        self.approvalState = approvalState
        self.approvalId = approvalId
        self.activityItems = activityItems
        self.isStreamingActivity = isStreamingActivity
    }

    static func == (lhs: ChatLine, rhs: ChatLine) -> Bool {
        lhs.id == rhs.id &&
        lhs.role == rhs.role &&
        lhs.text == rhs.text &&
        lhs.approvalState == rhs.approvalState &&
        lhs.approvalId == rhs.approvalId &&
        lhs.activityItems == rhs.activityItems &&
        lhs.isStreamingActivity == rhs.isStreamingActivity
    }
}

struct ChatActivity: Identifiable, Equatable {
    let id: UUID
    let type: String
    var text: String

    init(id: UUID = UUID(), type: String, text: String) {
        self.id = id
        self.type = type
        self.text = text
    }

    static func == (lhs: ChatActivity, rhs: ChatActivity) -> Bool {
        lhs.id == rhs.id &&
        lhs.type == rhs.type &&
        lhs.text == rhs.text
    }
}

enum ApprovalState: String {
    case pending
    case approved
    case denied
}

enum ChatAccessMode: String, CaseIterable, Identifiable {
    case confirm
    case full

    var id: String { rawValue }

    var label: String {
        switch self {
        case .confirm: "Safe"
        case .full: "Full"
        }
    }
}

enum ChatReasoningMode: String, CaseIterable, Identifiable {
    case swift
    case balanced
    case deep

    var id: String { rawValue }

    var label: String {
        switch self {
        case .swift: "Fast"
        case .balanced: "Med"
        case .deep: "Deep"
        }
    }

    var effort: String {
        switch self {
        case .swift: "low"
        case .balanced: "medium"
        case .deep: "high"
        }
    }
}

enum ChatContextScope: String, CaseIterable, Identifiable {
    case none = "none"
    case currentFile = "current-file"
    case currentFolder = "current-folder"
    case workspace = "workspace"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: "No context"
        case .currentFile: "Current file"
        case .currentFolder: "Current folder"
        case .workspace: "Workspace"
        }
    }

    var systemImage: String {
        switch self {
        case .none: "slash.circle"
        case .currentFile: "doc.text"
        case .currentFolder: "folder"
        case .workspace: "externaldrive"
        }
    }
}
