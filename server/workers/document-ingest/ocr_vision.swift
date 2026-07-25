#!/usr/bin/env swift

import Foundation
import PDFKit
import Vision
import CoreGraphics
import ImageIO

struct OCRBox: Codable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct OCRLine: Codable {
    let text: String
    let bbox: OCRBox
}

struct OCRBlock: Codable {
    let page: Int
    let text: String
    let lines: [OCRLine]
}

struct OCRResult: Codable {
    let blocks: [OCRBlock]
    let warnings: [String]
}

func render(_ page: PDFPage, dpi: CGFloat) -> CGImage? {
    let bounds = page.bounds(for: .mediaBox)
    let scale = dpi / 72.0
    let width = max(1, Int(ceil(bounds.width * scale)))
    let height = max(1, Int(ceil(bounds.height * scale)))
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          ) else {
        return nil
    }
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.saveGState()
    context.scaleBy(x: scale, y: scale)
    page.draw(with: .mediaBox, to: context)
    context.restoreGState()
    return context.makeImage()
}

func recognize(_ image: CGImage, languages: [String]) throws -> (String, [OCRLine]) {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    let supported = try request.supportedRecognitionLanguages()
    let selected = languages.filter { supported.contains($0) }
    if !selected.isEmpty {
        request.recognitionLanguages = selected
    }
    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    try handler.perform([request])
    let observations = (request.results ?? []).sorted {
        let verticalDelta = abs($0.boundingBox.midY - $1.boundingBox.midY)
        if verticalDelta > 0.012 {
            return $0.boundingBox.midY > $1.boundingBox.midY
        }
        return $0.boundingBox.minX < $1.boundingBox.minX
    }
    let lines = observations.compactMap { observation -> OCRLine? in
        guard let text = observation.topCandidates(1).first?.string, !text.isEmpty else {
            return nil
        }
        let box = observation.boundingBox
        return OCRLine(
            text: text,
            bbox: OCRBox(
                x: box.minX,
                y: 1.0 - box.maxY,
                width: box.width,
                height: box.height
            )
        )
    }
    return (lines.map(\.text).joined(separator: "\n"), lines)
}

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: ocr_vision.swift PDF [pages] [dpi]\n".utf8))
    exit(2)
}

let input = arguments[1]
let requestedPages = arguments.count >= 3
    ? Set(arguments[2].split(separator: ",").compactMap { Int($0) }.filter { $0 > 0 })
    : Set<Int>()
var blocks: [OCRBlock] = []
var warnings: [String] = []
let inputURL = URL(fileURLWithPath: input)
let dpi = arguments.count >= 4 ? CGFloat(Double(arguments[3]) ?? 150) : 150
if inputURL.pathExtension.lowercased() == "pdf" {
    guard let document = PDFDocument(url: inputURL) else {
        FileHandle.standardError.write(Data("Unable to open PDF.\n".utf8))
        exit(3)
    }
    let selectedPageCount = requestedPages.isEmpty
        ? document.pageCount
        : requestedPages.filter { $0 <= document.pageCount }.count
    var completedPageCount = 0
    for pageIndex in 0..<document.pageCount {
        let pageNumber = pageIndex + 1
        if !requestedPages.isEmpty && !requestedPages.contains(pageNumber) {
            continue
        }
        autoreleasepool {
            guard let page = document.page(at: pageIndex),
                  let image = render(page, dpi: dpi) else {
                warnings.append("Page \(pageNumber): render failed.")
                return
            }
            do {
                let recognized = try recognize(image, languages: ["ko-KR", "en-US"])
                let text = recognized.0.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    blocks.append(OCRBlock(page: pageNumber, text: text, lines: recognized.1))
                }
            } catch {
                warnings.append("Page \(pageNumber): \(error.localizedDescription)")
            }
        }
        completedPageCount += 1
        emitProgress(completed: completedPageCount, total: selectedPageCount, page: pageNumber)
    }
} else if let source = CGImageSourceCreateWithURL(inputURL as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
    do {
        let recognized = try recognize(image, languages: ["ko-KR", "en-US"])
        let text = recognized.0.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            blocks.append(OCRBlock(page: 1, text: text, lines: recognized.1))
        }
    } catch {
        warnings.append("Image: \(error.localizedDescription)")
    }
    emitProgress(completed: 1, total: 1, page: 1)
} else {
    FileHandle.standardError.write(Data("Unable to open document image.\n".utf8))
    exit(3)
}

let encoder = JSONEncoder()
encoder.outputFormatting = [.withoutEscapingSlashes]
let output = OCRResult(blocks: blocks, warnings: warnings)
FileHandle.standardOutput.write(try encoder.encode(output))
FileHandle.standardOutput.write(Data("\n".utf8))

func emitProgress(completed: Int, total: Int, page: Int) {
    let payload: [String: Any] = [
        "type": "progress",
        "completed": completed,
        "total": total,
        "page": page,
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: payload),
          var line = String(data: data, encoding: .utf8) else {
        return
    }
    line.append("\n")
    FileHandle.standardError.write(Data(line.utf8))
}
