import Foundation
import zlib

/// The same three-entry ZIP format used by the server; never extracts arbitrary paths.
enum CodmesPDFArchive {
    struct Contents: Sendable { let pdf: Data; let annotations: PDFAnnotationDocument }
    private static let names: Set<String> = ["manifest.json", "document.pdf", "annotations.json"]
    private static let limit = 600 * 1024 * 1024
    private static func invalid() -> CocoaError { CocoaError(.fileReadCorruptFile) }
    private static func number(_ data: Data, _ offset: Int, _ count: Int) throws -> Int {
        guard offset >= 0, offset + count <= data.count else { throw invalid() }
        return (0..<count).reduce(0) { $0 | (Int(data[offset + $1]) << ($1 * 8)) }
    }
    private static func checksum(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { UInt32(truncatingIfNeeded: crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(data.count))) }
    }
    private static func inflated(_ input: Data, size: Int) throws -> Data {
        guard size >= 0, size <= limit else { throw invalid() }
        var output = Data(count: max(size, 1))
        var stream = z_stream()
        guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw invalid() }
        defer { inflateEnd(&stream) }
        let result = input.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { target in
                stream.next_in = UnsafeMutablePointer(mutating: source.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(input.count)
                stream.next_out = target.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(max(size, 1))
                return inflate(&stream, Z_FINISH)
            }
        }
        guard result == Z_STREAM_END, stream.total_out == size, stream.total_in == input.count else { throw invalid() }
        output.count = size
        return output
    }
    static func read(_ archive: Data) throws -> Contents {
        guard archive.count >= 22, archive.count <= 250 * 1024 * 1024 else { throw invalid() }
        // Do not mistake a ZIP signature inside a comment for the archive footer.
        let footer = stride(from: archive.count - 22, through: max(0, archive.count - 65_557), by: -1).first { offset in
            (try? number(archive, offset, 4)) == 0x06054b50 && (try? number(archive, offset + 20, 2)).map { offset + 22 + $0 == archive.count } == true
        }
        guard let footer, try number(archive, footer + 4, 2) == 0, try number(archive, footer + 6, 2) == 0,
              try number(archive, footer + 8, 2) == 3, try number(archive, footer + 10, 2) == 3 else { throw invalid() }
        var cursor = try number(archive, footer + 16, 4)
        let centralEnd = cursor + (try number(archive, footer + 12, 4))
        guard centralEnd == footer else { throw invalid() }
        var entries: [String: Data] = [:]
        var total = 0
        for _ in 0..<3 {
            guard try number(archive, cursor, 4) == 0x02014b50 else { throw invalid() }
            let flags = try number(archive, cursor + 8, 2), method = try number(archive, cursor + 10, 2)
            let crc = try number(archive, cursor + 16, 4), compressed = try number(archive, cursor + 20, 4), size = try number(archive, cursor + 24, 4)
            let nameSize = try number(archive, cursor + 28, 2), extraSize = try number(archive, cursor + 30, 2), commentSize = try number(archive, cursor + 32, 2)
            let local = try number(archive, cursor + 42, 4)
            total += size
            guard flags & 1 == 0, [0, 8].contains(method), total <= limit, cursor + 46 + nameSize + extraSize + commentSize <= centralEnd,
                  let name = String(data: archive.subdata(in: cursor + 46..<cursor + 46 + nameSize), encoding: .utf8), names.contains(name), entries[name] == nil,
                  try number(archive, local, 4) == 0x04034b50, try number(archive, local + 8, 2) == method else { throw invalid() }
            let localNameSize = try number(archive, local + 26, 2), localExtraSize = try number(archive, local + 28, 2)
            let start = local + 30 + localNameSize + localExtraSize
            guard start >= 0, start + compressed <= footer, local + 30 + localNameSize <= archive.count,
                  String(data: archive.subdata(in: local + 30..<local + 30 + localNameSize), encoding: .utf8) == name else { throw invalid() }
            let bytes = archive.subdata(in: start..<start + compressed)
            let data = method == 0 ? bytes : try inflated(bytes, size: size)
            guard data.count == size, Int(checksum(data)) == crc else { throw invalid() }
            entries[name] = data
            cursor += 46 + nameSize + extraSize + commentSize
        }
        guard cursor == centralEnd, let metadata = entries["manifest.json"], let pdf = entries["document.pdf"], let annotations = entries["annotations.json"],
              let manifest = try JSONSerialization.jsonObject(with: metadata) as? [String: Any],
              manifest["format"] as? String == "codmes-pdf", manifest["schemaVersion"] as? Int == 1,
              let files = manifest["files"] as? [String: String], files["pdf"] == "document.pdf", files["annotations"] == "annotations.json",
              let hashes = manifest["checksums"] as? [String: String], hashes["document.pdf"] == LocalWorkspace.digest(pdf), hashes["annotations.json"] == LocalWorkspace.digest(annotations),
              pdf.prefix(1024).range(of: Data("%PDF-".utf8)) != nil else { throw invalid() }
        return Contents(pdf: pdf, annotations: try JSONDecoder().decode(PDFAnnotationDocument.self, from: annotations))
    }
    static func create(pdf: Data, annotations: PDFAnnotationDocument, title: String) throws -> Data {
        guard pdf.prefix(1024).range(of: Data("%PDF-".utf8)) != nil else { throw invalid() }
        let annotationData = try JSONEncoder().encode(annotations)
        let manifest: [String: Any] = ["format": "codmes-pdf", "schemaVersion": 1, "title": title,
            "createdAt": ISO8601DateFormatter().string(from: Date()), "appVersion": "0.1.2",
            "files": ["pdf": "document.pdf", "annotations": "annotations.json"],
            "checksums": ["document.pdf": LocalWorkspace.digest(pdf), "annotations.json": LocalWorkspace.digest(annotationData)]]
        let entries = [("manifest.json", try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])), ("document.pdf", pdf), ("annotations.json", annotationData)]
        guard entries.reduce(0, { $0 + $1.1.count }) < 250 * 1024 * 1024 - 1024 else { throw CocoaError(.fileWriteOutOfSpace) }
        var output = Data(), central = Data()
        func append(_ value: Int, bytes: Int, to data: inout Data) { for index in 0..<bytes { data.append(UInt8(truncatingIfNeeded: value >> (index * 8))) } }
        for (name, data) in entries {
            let filename = Data(name.utf8), offset = output.count, crc = Int(checksum(data))
            for (value, bytes) in [(0x04034b50,4),(20,2),(0,2),(0,2),(0,2),(0,2),(crc,4),(data.count,4),(data.count,4),(filename.count,2),(0,2)] { append(value, bytes: bytes, to: &output) }
            output.append(filename); output.append(data)
            for (value, bytes) in [(0x02014b50,4),(20,2),(20,2),(0,2),(0,2),(0,2),(0,2),(crc,4),(data.count,4),(data.count,4),(filename.count,2),(0,2),(0,2),(0,2),(0,2),(0,4),(offset,4)] { append(value, bytes: bytes, to: &central) }
            central.append(filename)
        }
        let offset = output.count
        output.append(central)
        for (value, bytes) in [(0x06054b50,4),(0,2),(0,2),(3,2),(3,2),(central.count,4),(offset,4),(0,2)] { append(value, bytes: bytes, to: &output) }
        return output
    }
}
