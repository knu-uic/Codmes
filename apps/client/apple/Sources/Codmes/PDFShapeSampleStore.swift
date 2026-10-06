import CoreGraphics
import Foundation

struct PDFShapeSamplePoint: Codable {
    var x: Double
    var y: Double

    init(_ point: CGPoint) {
        x = Double(point.x)
        y = Double(point.y)
    }

    var cgPoint: CGPoint {
        CGPoint(x: x, y: y)
    }
}

struct PDFShapeSampleScore: Codable {
    var kind: String
    var score: Double
}

struct PDFShapeSampleRecord: Codable {
    var id: String
    var createdAt: String
    var appVersion: String
    var source: String
    var expectedKind: String?
    var selectedKind: String
    var reason: String
    var endpointGap: Double
    var vertexCount: Int
    var scores: [PDFShapeSampleScore]
    var rawPoints: [PDFShapeSamplePoint]
    var fittedPoints: [PDFShapeSamplePoint]
}

enum PDFShapeSampleStore {
    static let fileName = "shape-recognition-samples.jsonl"

    static var samplesURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("Codmes", isDirectory: true)
            .appendingPathComponent("Diagnostics", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    static func append(source: String, rawPoints: [CGPoint], attempt: PDFShapeRecognitionAttempt) {
        guard rawPoints.count > 1 else { return }
        let record = PDFShapeSampleRecord(
            id: UUID().uuidString,
            createdAt: isoTimestamp(),
            appVersion: "1",
            source: source,
            expectedKind: nil,
            selectedKind: attempt.fit?.kind ?? "none",
            reason: attempt.debug.reason,
            endpointGap: Double(attempt.debug.endpointGap),
            vertexCount: attempt.debug.vertexCount,
            scores: attempt.debug.scores
                .sorted { $0.score < $1.score }
                .map { PDFShapeSampleScore(kind: $0.kind, score: Double($0.score)) },
            rawPoints: rawPoints.map(PDFShapeSamplePoint.init),
            fittedPoints: (attempt.fit?.points ?? []).map(PDFShapeSamplePoint.init)
        )
        do {
            try FileManager.default.createDirectory(at: samplesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            var data = try encoder.encode(record)
            data.append(0x0A)
            if FileManager.default.fileExists(atPath: samplesURL.path) {
                let handle = try FileHandle(forWritingTo: samplesURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: samplesURL, options: .atomic)
            }
        } catch {
            print("[CodmesShapeRecognition] sample write failed: \(error.localizedDescription)")
        }
    }

    static func loadRecords(from url: URL = samplesURL) throws -> [PDFShapeSampleRecord] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        return try text
            .split(whereSeparator: \.isNewline)
            .map { try decoder.decode(PDFShapeSampleRecord.self, from: Data($0.utf8)) }
    }

    private static func isoTimestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}
