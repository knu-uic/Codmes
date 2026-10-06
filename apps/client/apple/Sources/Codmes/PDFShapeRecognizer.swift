import CoreGraphics
import Foundation

struct PDFShapeFit {
    var kind: String
    var points: [CGPoint]
}

struct PDFShapeRecognitionDebug {
    var selected: String
    var reason: String
    var pointCount: Int
    var endpointGap: CGFloat
    var vertexCount: Int
    var scores: [(kind: String, score: CGFloat)]
    var samplePoints: [CGPoint]

    var summary: String {
        let scoreText = scores
            .sorted { $0.score < $1.score }
            .prefix(7)
            .map { "\($0.kind)=\(String(format: "%.3f", Double($0.score)))" }
            .joined(separator: " ")
        return "shape \(selected) [\(reason)] pts=\(pointCount) gap=\(String(format: "%.2f", Double(endpointGap))) v=\(vertexCount)\n\(scoreText)"
    }

    var consoleDetails: String {
        let pointsText = samplePoints.map {
            "[\(String(format: "%.1f", Double($0.x))),\(String(format: "%.1f", Double($0.y)))]"
        }.joined(separator: ",")
        return "\(summary.replacingOccurrences(of: "\n", with: " | ")) sample=[\(pointsText)]"
    }
}

struct PDFShapeRecognitionResult {
    var fit: PDFShapeFit
    var debug: PDFShapeRecognitionDebug
}

struct PDFShapeRecognitionAttempt {
    var fit: PDFShapeFit?
    var debug: PDFShapeRecognitionDebug
}

struct PDFShapeRecognizer {
    private struct Candidate {
        var fit: PDFShapeFit
        var score: CGFloat
        var reason: String
        var vertices: [CGPoint]
    }

    private struct ExemplarMatch {
        var kind: String
        var distance: CGFloat
    }

    func recognize(points rawPoints: [CGPoint]) -> PDFShapeRecognitionResult? {
        guard let attempt = recognizeAttempt(points: rawPoints),
              let fit = attempt.fit else { return nil }
        return PDFShapeRecognitionResult(fit: fit, debug: attempt.debug)
    }

    func recognizeAttempt(points rawPoints: [CGPoint]) -> PDFShapeRecognitionAttempt? {
        var points = resampled(rawPoints, spacing: 4)
        points = smoothed(points)
        guard points.count > 8, let bounds = pointBounds(points) else {
            return failure(selected: "none", reason: "too-few-points", points: points, endpointGap: 0, vertexCount: 0, candidates: [])
        }

        let diagonal = max(hypot(bounds.width, bounds.height), 1)
        guard diagonal > 20 else {
            return failure(selected: "none", reason: "too-small", points: points, endpointGap: 0, vertexCount: 0, candidates: [])
        }

        let endpointGap = distance(points[0], points[points.count - 1]) / diagonal
        let closed = endpointGap < 0.34
        let corners = cornerCandidates(from: points, diagonal: diagonal, closed: closed)
        let angular = angularStrokeIntent(points, diagonal: diagonal)
        var candidates: [Candidate] = []

        if let line = lineCandidate(from: points, diagonal: diagonal, endpointGap: endpointGap) {
            candidates.append(line)
        }

        if !closed {
            candidates.append(contentsOf: polylineCandidates(from: points, corners: corners, diagonal: diagonal, endpointGap: endpointGap))
        }

        if endpointGap < (angular ? 0.9 : 0.58) {
            candidates.append(contentsOf: polygonCandidates(from: points, corners: corners, diagonal: diagonal, endpointGap: endpointGap))
        }

        if closed {
            candidates.append(contentsOf: roundCandidates(from: points, bounds: bounds, corners: corners, diagonal: diagonal, endpointGap: endpointGap))
        }

        if let exemplar = exemplarMatch(from: points),
           let candidate = exemplarCandidate(from: exemplar, points: points, bounds: bounds, diagonal: diagonal, endpointGap: endpointGap, existingCandidates: candidates) {
            candidates.append(candidate)
            if exemplar.distance <= 0.40 {
                return success(candidate, selected: candidate.fit.kind, reason: candidate.reason, points: points, endpointGap: endpointGap, candidates: candidates)
            }
        }

        guard !candidates.isEmpty else {
            return failure(selected: "none", reason: "no-candidates", points: points, endpointGap: endpointGap, vertexCount: corners.count, candidates: candidates)
        }

        if let polylineBest = candidates
            .filter({ $0.fit.kind == "polyline" })
           .min(by: { $0.score < $1.score }),
           let triangleBest = candidates
            .filter({ $0.fit.kind == "triangle" })
            .min(by: { $0.score < $1.score }),
           polylineBest.score < 0.05,
           triangleBest.score < 0.17,
           endpointGap < 0.9 {
            return success(triangleBest, selected: triangleBest.fit.kind, reason: "open-triangle-guard", points: points, endpointGap: endpointGap, candidates: candidates)
        }

        let circularity = closedCircularity(points)
        let elongated = aspectRatio(bounds) > 1.75
        if let roundBest = candidates
            .filter({ $0.fit.kind == "circle" || $0.fit.kind == "ellipse" })
            .min(by: { $0.score < $1.score }),
           angular,
           !elongated,
           circularity < 0.82,
           let angularBest = candidates
            .filter({ $0.fit.kind != "circle" && $0.fit.kind != "ellipse" })
            .min(by: { $0.score < $1.score }),
           angularBest.score <= roundBest.score + 0.14 {
            if roundBest.score < 0.14, angularBest.fit.kind == "rectangle" {
                if isConfidentRectangle(points: points, bounds: bounds, circularity: circularity),
                   angularBest.score + 0.08 < roundBest.score {
                    return success(angularBest, selected: angularBest.fit.kind, reason: "rectangle-guard", points: points, endpointGap: endpointGap, candidates: candidates)
                }
                return success(roundBest, selected: roundBest.fit.kind, reason: "round-guard", points: points, endpointGap: endpointGap, candidates: candidates)
            }
            return success(angularBest, selected: angularBest.fit.kind, reason: "angular-over-round", points: points, endpointGap: endpointGap, candidates: candidates)
        }

        if elongated,
           let ellipseBest = candidates
            .filter({ $0.fit.kind == "ellipse" })
            .min(by: { $0.score < $1.score }),
           let polygonBest = candidates
            .filter({ $0.fit.kind == "triangle" || $0.fit.kind == "rectangle" })
            .min(by: { $0.score < $1.score }),
           ellipseBest.score < 0.28,
           polygonBest.score >= ellipseBest.score - 0.10 {
            return success(ellipseBest, selected: ellipseBest.fit.kind, reason: "elongated-round-guard", points: points, endpointGap: endpointGap, candidates: candidates)
        }

        guard let best = candidates.min(by: { $0.score < $1.score }) else { return nil }
        let threshold: CGFloat
        switch best.fit.kind {
        case "line":
            threshold = 0.18
        case "polyline":
            threshold = 0.35
        case "triangle":
            threshold = 0.48
        case "rectangle":
            threshold = 0.44
        case "circle", "ellipse":
            threshold = 0.42
        default:
            threshold = 0.45
        }

        guard best.score < threshold else {
            return failure(selected: "none", reason: "score-threshold", points: points, endpointGap: endpointGap, vertexCount: corners.count, candidates: candidates)
        }
        if isAmbiguous(best: best, candidates: candidates) {
            return failure(selected: "none", reason: "ambiguous-candidates", points: points, endpointGap: endpointGap, vertexCount: corners.count, candidates: candidates)
        }
        return success(best, selected: best.fit.kind, reason: best.reason, points: points, endpointGap: endpointGap, candidates: candidates)
    }

    private func isAmbiguous(best: Candidate, candidates: [Candidate]) -> Bool {
        guard best.score > 0.08 else { return false }
        let rivals = candidates
            .filter { $0.fit.kind != best.fit.kind }
            .map(\.score)
            .sorted()
        guard let rival = rivals.first else { return false }
        if (best.fit.kind == "circle" || best.fit.kind == "ellipse"),
           candidates
            .filter({ ($0.fit.kind == "circle" || $0.fit.kind == "ellipse") && $0.fit.kind != best.fit.kind })
            .contains(where: { abs($0.score - best.score) < 0.04 }) {
            return false
        }
        let margin = rival - best.score
        switch best.fit.kind {
        case "triangle", "rectangle":
            return margin < 0.035
        case "circle", "ellipse":
            return margin < 0.025
        case "line", "polyline":
            return margin < 0.045
        default:
            return false
        }
    }

    private func lineCandidate(from points: [CGPoint], diagonal: CGFloat, endpointGap: CGFloat) -> Candidate? {
        guard endpointGap > 0.22 else { return nil }
        let fit = PDFShapeFit(kind: "line", points: [points[0], points[points.count - 1]])
        let score = polylineError(points, candidate: fit.points) / diagonal
            + max(0, 0.33 - endpointGap) * 0.05
        return Candidate(fit: fit, score: score, reason: "line", vertices: fit.points)
    }

    private func polylineCandidates(from points: [CGPoint], corners: [CGPoint], diagonal: CGFloat, endpointGap: CGFloat) -> [Candidate] {
        guard endpointGap > 0.28 else { return [] }
        let vertices = normalizedOpenVertices(corners, points: points, diagonal: diagonal)
        guard vertices.count >= 3, vertices.count <= 7 else { return [] }
        let fit = PDFShapeFit(kind: "polyline", points: vertices)
        let score = polylineError(points, candidate: vertices) / diagonal
            + CGFloat(max(0, vertices.count - 4)) * 0.012
            + segmentLinePenalty(points: points, vertices: vertices, diagonal: diagonal) * 0.2
        return [Candidate(fit: fit, score: score, reason: "polyline-corners", vertices: vertices)]
    }

    private func polygonCandidates(from points: [CGPoint], corners: [CGPoint], diagonal: CGFloat, endpointGap: CGFloat) -> [Candidate] {
        var result: [Candidate] = []
        var options = polygonVertexOptions(from: points, corners: corners, diagonal: diagonal)
        if endpointGap > 0.34, options.isEmpty, let bounds = pointBounds(points) {
            options.append(extremeTriangle(from: points, bounds: bounds, diagonal: diagonal))
        }

        for vertices in options {
            guard vertices.count == 3 || vertices.count == 4 else { continue }
            let polygon = vertices + [vertices[0]]
            let areaRatio = abs(polygonArea(polygon)) / (diagonal * diagonal)
            guard areaRatio > 0.025 else { continue }
            let fitError = polylineError(points, candidate: polygon) / diagonal
            let closurePenalty = max(0, endpointGap - 0.18) * 0.16
            let segmentPenalty = segmentLinePenalty(points: points, vertices: polygon, diagonal: diagonal) * 0.16
            if vertices.count == 3 {
                let score = fitError * 0.82 + closurePenalty + segmentPenalty + 0.025
                result.append(Candidate(fit: PDFShapeFit(kind: "triangle", points: polygon), score: score, reason: "three-corners", vertices: vertices))
            } else {
                let anglePenalty = rectangleAnglePenalty(vertices)
                let sidePenalty = shortSidePenalty(vertices, diagonal: diagonal)
                let score = fitError * 0.82 + closurePenalty + segmentPenalty + anglePenalty * 0.12 + sidePenalty - 0.015
                result.append(Candidate(fit: PDFShapeFit(kind: "rectangle", points: polygon), score: score, reason: "four-corners", vertices: vertices))
            }
        }

        let strongTriangle = result.contains { $0.fit.kind == "triangle" && $0.score < 0.075 }
        if !strongTriangle,
           endpointGap < 0.34,
           angularStrokeIntent(points, diagonal: diagonal),
           let fallback = boundingRectangleCandidate(from: points, diagonal: diagonal, endpointGap: endpointGap) {
            result.append(fallback)
        }

        return result
    }

    private func boundingRectangleCandidate(from points: [CGPoint], diagonal: CGFloat, endpointGap: CGFloat) -> Candidate? {
        guard let bounds = pointBounds(points), bounds.width > 8, bounds.height > 8 else { return nil }
        let rectangle = rectanglePoints(in: bounds)
        let edgeCoverage = edgeFitRatio(points, bounds: bounds)
        let elongated = aspectRatio(bounds) > 2.3
        let cornerCoverage = rectangleCornerCoverage(points, bounds: bounds)
        let circularity = closedCircularity(points)
        guard edgeCoverage > 0.38, circularity < 0.82 else { return nil }
        guard !elongated || cornerCoverage > 0.018 else { return nil }
        let fitError = polylineError(points, candidate: rectangle) / diagonal
        let score = fitError * 0.62
            + max(0, endpointGap - 0.16) * 0.12
            + max(0, 0.56 - edgeCoverage) * 0.18
            + max(0, 0.04 - cornerCoverage) * 0.08
            + 0.005
        return Candidate(fit: PDFShapeFit(kind: "rectangle", points: rectangle), score: score, reason: "rectangle-bounds", vertices: Array(rectangle.prefix(4)))
    }

    private func roundCandidates(from points: [CGPoint], bounds: CGRect, corners: [CGPoint], diagonal: CGFloat, endpointGap: CGFloat) -> [Candidate] {
        let circularity = closedCircularity(points)
        let coverage = angularCoverage(points, bounds: bounds)
        let elongated = aspectRatio(bounds) > 1.75
        guard endpointGap < 0.52,
              coverage > (elongated ? 0.46 : 0.58),
              circularity > (elongated ? 0.22 : 0.42) else { return [] }
        let cornerPenalty: CGFloat = corners.count <= 5 ? 0.16 : 0
        if !elongated, angularStrokeIntent(points, diagonal: diagonal), corners.count <= 5, circularity < 0.86 {
            return []
        }

        var result: [Candidate] = []
        let circleError = circleFitError(points, bounds: bounds)
        let ellipseError = ellipseFitError(points, bounds: bounds)
        let coveragePenalty = max(0, 0.82 - coverage) * 0.12
        let closurePenalty = max(0, endpointGap - 0.16) * 0.18
        if !elongated, circleError < 0.48 {
            let fit = PDFShapeFit(kind: "circle", points: circlePoints(in: bounds, count: 48))
            result.append(Candidate(fit: fit, score: circleError + coveragePenalty + closurePenalty + cornerPenalty + 0.045, reason: "round", vertices: []))
        }
        if ellipseError < (elongated ? 0.62 : 0.48) {
            let fit = PDFShapeFit(kind: "ellipse", points: ellipsePoints(in: bounds, count: 48))
            let elongatedBonus: CGFloat = elongated ? -0.09 : 0
            result.append(Candidate(fit: fit, score: ellipseError + coveragePenalty + closurePenalty + cornerPenalty + 0.055 + elongatedBonus, reason: "round", vertices: []))
        }
        return result
    }

    private func exemplarMatch(from points: [CGPoint]) -> ExemplarMatch? {
        let normalized = normalizedExemplarPath(points)
        guard normalized.count == PDFShapeExemplarBank.pointCount * 2 else { return nil }
        var best: ExemplarMatch?
        for exemplar in PDFShapeExemplarBank.exemplars where exemplar.points.count == normalized.count {
            let distance = exemplarDistance(normalized, exemplar.points)
            if best == nil || distance < best!.distance {
                best = ExemplarMatch(kind: exemplar.kind, distance: distance)
            }
        }
        return best
    }

    private func exemplarCandidate(
        from match: ExemplarMatch,
        points: [CGPoint],
        bounds: CGRect,
        diagonal: CGFloat,
        endpointGap: CGFloat,
        existingCandidates: [Candidate]
    ) -> Candidate? {
        let strictThreshold: CGFloat = 0.40
        let bestExisting = existingCandidates.min(by: { $0.score < $1.score })
        guard match.distance <= strictThreshold || bestExisting == nil else { return nil }
        if (match.kind == "circle" || match.kind == "ellipse"), endpointGap > 0.55 {
            return nil
        }

        let matchingExisting = existingCandidates
            .filter { $0.fit.kind == match.kind }
            .min(by: { $0.score < $1.score })
        if match.kind != "polyline",
           let polylineBest = existingCandidates
            .filter({ $0.fit.kind == "polyline" })
            .min(by: { $0.score < $1.score }),
           let bounds = pointBounds(points),
           isStrongOpenPolylineIntent(polylineBest, points: points, bounds: bounds, diagonal: diagonal, endpointGap: endpointGap, candidates: existingCandidates) {
            return nil
        }
        let fit: PDFShapeFit
        let vertices: [CGPoint]
        if let matchingExisting {
            fit = matchingExisting.fit
            vertices = matchingExisting.vertices
        } else {
            switch match.kind {
            case "line":
                fit = PDFShapeFit(kind: "line", points: [points[0], points[points.count - 1]])
                vertices = fit.points
            case "polyline":
                let polyline = normalizedOpenVertices(
                    deduplicated(simplify(points, epsilon: max(diagonal * 0.045, 4)), diagonal: diagonal, closed: false),
                    points: points,
                    diagonal: diagonal
                )
                guard polyline.count >= 3 else { return nil }
                fit = PDFShapeFit(kind: "polyline", points: polyline)
                vertices = polyline
            case "rectangle":
                let rectangle = rectanglePoints(in: bounds)
                fit = PDFShapeFit(kind: "rectangle", points: rectangle)
                vertices = Array(rectangle.dropLast())
            case "triangle":
                let triangle = extremeTriangle(from: points, bounds: bounds, diagonal: diagonal)
                fit = PDFShapeFit(kind: "triangle", points: triangle + [triangle[0]])
                vertices = triangle
            case "circle":
                fit = PDFShapeFit(kind: "circle", points: circlePoints(in: bounds, count: 48))
                vertices = []
            case "ellipse":
                fit = PDFShapeFit(kind: "ellipse", points: ellipsePoints(in: bounds, count: 48))
                vertices = []
            default:
                return nil
            }
        }

        let score = max(0.012, match.distance * 0.18 + 0.01)
        return Candidate(fit: fit, score: score, reason: "exemplar-bank:\(String(format: "%.3f", Double(match.distance)))", vertices: vertices)
    }

    private func isStrongOpenPolylineIntent(
        _ polyline: Candidate,
        points: [CGPoint],
        bounds: CGRect,
        diagonal: CGFloat,
        endpointGap: CGFloat,
        candidates: [Candidate]
    ) -> Bool {
        guard endpointGap > 0.68,
              polyline.vertices.count >= 5,
              polyline.score < 0.04 else { return false }
        if let lineBest = candidates
            .filter({ $0.fit.kind == "line" })
            .min(by: { $0.score < $1.score }),
           lineBest.score < 0.24 {
            return false
        }
        if let rectangleBest = candidates
            .filter({ $0.fit.kind == "rectangle" })
            .min(by: { $0.score < $1.score }),
           rectangleBest.score < 0.08,
           edgeFitRatio(points, bounds: bounds) > 0.48,
           rectangleCornerCoverage(points, bounds: bounds) > 0.018 {
            return false
        }
        if endpointGap < 0.82,
           let angularBest = candidates
            .filter({ $0.fit.kind == "triangle" || $0.fit.kind == "rectangle" })
            .min(by: { $0.score < $1.score }),
           angularBest.score < 0.08 {
            return false
        }
        if endpointGap < 0.78,
           closedCircularity(points) > 0.52 {
            return false
        }
        return true
    }

    private func normalizedExemplarPath(_ points: [CGPoint]) -> [Float] {
        let sampled = resampleToCount(points, count: PDFShapeExemplarBank.pointCount)
        guard !sampled.isEmpty else { return [] }
        let centroid = sampled.reduce(CGPoint.zero) { partial, point in
            CGPoint(x: partial.x + point.x, y: partial.y + point.y)
        }
        let center = CGPoint(x: centroid.x / CGFloat(sampled.count), y: centroid.y / CGFloat(sampled.count))
        var translated = sampled.map { CGPoint(x: $0.x - center.x, y: $0.y - center.y) }
        if let first = translated.first {
            translated = rotate(translated, by: -atan2(first.y, first.x))
        }
        let scale = max(
            translated.map { abs($0.x) }.max() ?? 1,
            translated.map { abs($0.y) }.max() ?? 1,
            1
        )
        var normalized: [Float] = []
        normalized.reserveCapacity(translated.count * 2)
        for point in translated {
            normalized.append(Float(point.x / scale))
            normalized.append(Float(point.y / scale))
        }
        return normalized
    }

    private func rotate(_ points: [CGPoint], by angle: CGFloat) -> [CGPoint] {
        let cosA = cos(angle)
        let sinA = sin(angle)
        return points.map { point in
            CGPoint(x: point.x * cosA - point.y * sinA, y: point.x * sinA + point.y * cosA)
        }
    }

    private func exemplarDistance(_ lhs: [Float], _ rhs: [Float]) -> CGFloat {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return .greatestFiniteMagnitude }
        var total: CGFloat = 0
        var index = 0
        while index + 1 < lhs.count {
            let dx = CGFloat(lhs[index] - rhs[index])
            let dy = CGFloat(lhs[index + 1] - rhs[index + 1])
            total += hypot(dx, dy)
            index += 2
        }
        return total / CGFloat(lhs.count / 2)
    }

    private func success(_ candidate: Candidate, selected: String, reason: String, points: [CGPoint], endpointGap: CGFloat, candidates: [Candidate]) -> PDFShapeRecognitionAttempt {
        PDFShapeRecognitionAttempt(
            fit: candidate.fit,
            debug: debug(selected: selected, reason: reason, points: points, endpointGap: endpointGap, vertexCount: candidate.vertices.count, candidates: candidates)
        )
    }

    private func failure(selected: String, reason: String, points: [CGPoint], endpointGap: CGFloat, vertexCount: Int, candidates: [Candidate]) -> PDFShapeRecognitionAttempt {
        PDFShapeRecognitionAttempt(
            fit: nil,
            debug: debug(selected: selected, reason: reason, points: points, endpointGap: endpointGap, vertexCount: vertexCount, candidates: candidates)
        )
    }

    private func debug(selected: String, reason: String, points: [CGPoint], endpointGap: CGFloat, vertexCount: Int, candidates: [Candidate]) -> PDFShapeRecognitionDebug {
        var bestByKind: [String: CGFloat] = [:]
        for candidate in candidates {
            bestByKind[candidate.fit.kind] = min(bestByKind[candidate.fit.kind] ?? .greatestFiniteMagnitude, candidate.score)
        }
        return PDFShapeRecognitionDebug(
            selected: selected,
            reason: reason,
            pointCount: points.count,
            endpointGap: endpointGap,
            vertexCount: vertexCount,
            scores: bestByKind.map { (kind: $0.key, score: $0.value) },
            samplePoints: resampleToCount(points, count: min(32, max(points.count, 2)))
        )
    }

    private func cornerCandidates(from points: [CGPoint], diagonal: CGFloat, closed: Bool) -> [CGPoint] {
        guard points.count > 6 else { return points }
        let window = 3
        var straws: [CGFloat] = Array(repeating: .greatestFiniteMagnitude, count: points.count)
        for index in window..<(points.count - window) {
            straws[index] = distance(points[index - window], points[index + window])
        }
        let finite = straws.filter { $0.isFinite }.sorted()
        let median = finite.isEmpty ? diagonal : finite[finite.count / 2]
        let threshold = median * 0.95
        var indices: [Int] = [0]
        var index = window
        while index < points.count - window {
            if straws[index] < threshold {
                var localMin = straws[index]
                var localIndex = index
                while index < points.count - window, straws[index] < threshold {
                    if straws[index] < localMin {
                        localMin = straws[index]
                        localIndex = index
                    }
                    index += 1
                }
                indices.append(localIndex)
            }
            index += 1
        }
        indices.append(points.count - 1)
        indices = refinedCornerIndices(indices, points: points, diagonal: diagonal, closed: closed)
        return deduplicated(indices.map { points[$0] }, diagonal: diagonal, closed: closed)
    }

    private func refinedCornerIndices(_ source: [Int], points: [CGPoint], diagonal: CGFloat, closed: Bool) -> [Int] {
        var indices = Array(Set(source)).sorted()
        var changed = true
        while changed {
            changed = false
            var next: [Int] = []
            for offset in 0..<(indices.count - 1) {
                let startIndex = indices[offset]
                let endIndex = indices[offset + 1]
                next.append(startIndex)
                guard endIndex - startIndex > 2 else { continue }
                let segmentPoints = Array(points[startIndex...endIndex])
                let error = lineError(segmentPoints, from: points[startIndex], to: points[endIndex]) / diagonal
                if error > 0.075,
                   let split = maxDistanceIndex(segmentPoints, from: points[startIndex], to: points[endIndex]) {
                    next.append(startIndex + split)
                    changed = true
                }
            }
            if let last = indices.last {
                next.append(last)
            }
            indices = Array(Set(next)).sorted()
            if indices.count > 10 { break }
        }
        if closed, indices.count > 2, let first = indices.first, let last = indices.last, distance(points[first], points[last]) / diagonal < 0.08 {
            indices.removeLast()
        }
        return indices
    }

    private func maxDistanceIndex(_ points: [CGPoint], from start: CGPoint, to end: CGPoint) -> Int? {
        guard points.count > 2 else { return nil }
        var bestIndex = 1
        var bestDistance: CGFloat = 0
        for index in 1..<(points.count - 1) {
            let candidate = distance(points[index], toSegmentStart: start, end: end)
            if candidate > bestDistance {
                bestDistance = candidate
                bestIndex = index
            }
        }
        return bestIndex
    }

    private func polygonVertexOptions(from points: [CGPoint], corners: [CGPoint], diagonal: CGFloat) -> [[CGPoint]] {
        var options: [[CGPoint]] = []
        let cleanCorners = deduplicated(corners, diagonal: diagonal, closed: true)
        if cleanCorners.count == 3 || cleanCorners.count == 4 {
            options.append(cleanCorners)
        }

        let epsilons: [CGFloat] = [0.035, 0.045, 0.06, 0.08, 0.105, 0.135]
        for epsilon in epsilons {
            let vertices = polygonVertices(from: points, epsilon: max(diagonal * epsilon, 4))
            if vertices.count == 3 || vertices.count == 4 {
                appendUnique(vertices, to: &options, diagonal: diagonal)
            }
        }

        let hull = convexHull(points)
        if hull.count >= 3 {
            for epsilon in epsilons {
                let vertices = polygonVertices(from: hull + [hull[0]], epsilon: max(diagonal * epsilon, 4))
                if vertices.count == 3 || vertices.count == 4 {
                    appendUnique(vertices, to: &options, diagonal: diagonal)
                }
            }
        }
        return options
    }

    private func appendUnique(_ vertices: [CGPoint], to options: inout [[CGPoint]], diagonal: CGFloat) {
        if !options.contains(where: { areSimilarVertices($0, vertices, tolerance: diagonal * 0.04) }) {
            options.append(vertices)
        }
    }

    private func normalizedOpenVertices(_ vertices: [CGPoint], points: [CGPoint], diagonal: CGFloat) -> [CGPoint] {
        var result = deduplicated(vertices, diagonal: diagonal, closed: false)
        if result.first.map({ distance($0, points[0]) / diagonal > 0.04 }) != false {
            result.insert(points[0], at: 0)
        }
        if result.last.map({ distance($0, points[points.count - 1]) / diagonal > 0.04 }) != false {
            result.append(points[points.count - 1])
        }
        return deduplicated(result, diagonal: diagonal, closed: false)
    }

    private func extremeTriangle(from points: [CGPoint], bounds: CGRect, diagonal: CGFloat) -> [CGPoint] {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let selected = convexHull(points)
            .sorted { distance($0, center) > distance($1, center) }
            .reduce(into: [CGPoint]()) { result, point in
                if result.count < 3, result.allSatisfy({ distance($0, point) / diagonal > 0.2 }) {
                    result.append(point)
                }
            }
        guard selected.count == 3 else {
            return [CGPoint(x: bounds.midX, y: bounds.minY), CGPoint(x: bounds.maxX, y: bounds.maxY), CGPoint(x: bounds.minX, y: bounds.maxY)]
        }
        return selected.sorted {
            atan2($0.y - center.y, $0.x - center.x) < atan2($1.y - center.y, $1.x - center.x)
        }
    }

    private func segmentLinePenalty(points: [CGPoint], vertices: [CGPoint], diagonal: CGFloat) -> CGFloat {
        guard vertices.count > 1 else { return 1 }
        return polylineError(points, candidate: vertices) / diagonal
    }

    private func rectangleAnglePenalty(_ vertices: [CGPoint]) -> CGFloat {
        guard vertices.count == 4 else { return 1 }
        var penalty: CGFloat = 0
        for index in 0..<4 {
            let previous = vertices[(index + 3) % 4]
            let current = vertices[index]
            let next = vertices[(index + 1) % 4]
            penalty += abs(turnAngle(previous: previous, current: current, next: next) - .pi / 2) / (.pi / 2)
        }
        return penalty / 4
    }

    private func shortSidePenalty(_ vertices: [CGPoint], diagonal: CGFloat) -> CGFloat {
        guard vertices.count == 4 else { return 0 }
        let lengths = (0..<4).map { distance(vertices[$0], vertices[($0 + 1) % 4]) / diagonal }
        return lengths.contains(where: { $0 < 0.12 }) ? 0.2 : 0
    }

    private func aspectRatio(_ bounds: CGRect) -> CGFloat {
        max(bounds.width, bounds.height) / max(min(bounds.width, bounds.height), 1)
    }

    private func edgeFitRatio(_ points: [CGPoint], bounds: CGRect) -> CGFloat {
        let tolerance = max(hypot(bounds.width, bounds.height) * 0.08, 4)
        let hits = points.filter { point in
            min(
                abs(point.x - bounds.minX),
                abs(point.x - bounds.maxX),
                abs(point.y - bounds.minY),
                abs(point.y - bounds.maxY)
            ) <= tolerance
        }
        return CGFloat(hits.count) / CGFloat(max(points.count, 1))
    }

    private func rectangleCornerCoverage(_ points: [CGPoint], bounds: CGRect) -> CGFloat {
        let diagonal = max(hypot(bounds.width, bounds.height), 1)
        let shortSide = max(min(bounds.width, bounds.height), 1)
        let tolerance = max(min(diagonal * 0.08, shortSide * 0.34), 5)
        let corners = rectanglePoints(in: bounds).dropLast()
        let perCorner = corners.map { corner in
            points.filter { distance($0, corner) <= tolerance }.count
        }
        return CGFloat(perCorner.min() ?? 0) / CGFloat(max(points.count, 1))
    }

    private func isConfidentRectangle(points: [CGPoint], bounds: CGRect, circularity: CGFloat) -> Bool {
        edgeFitRatio(points, bounds: bounds) > 0.48
            && rectangleCornerCoverage(points, bounds: bounds) > 0.018
            && circularity < 0.76
    }

    private func angularStrokeIntent(_ points: [CGPoint], diagonal: CGFloat) -> Bool {
        let vertices = deduplicated(simplify(points, epsilon: max(diagonal * 0.045, 4)), diagonal: diagonal, closed: true)
        guard vertices.count >= 3 else { return false }
        var sharpTurns = 0
        for index in 1..<(vertices.count - 1) {
            if turnAngle(previous: vertices[index - 1], current: vertices[index], next: vertices[index + 1]) < 2.35 {
                sharpTurns += 1
            }
        }
        if vertices.count > 3,
           turnAngle(previous: vertices[vertices.count - 2], current: vertices[0], next: vertices[1]) < 2.35 {
            sharpTurns += 1
        }
        return sharpTurns >= 2
    }

    private func smoothed(_ points: [CGPoint]) -> [CGPoint] {
        guard points.count > 4 else { return points }
        return points.indices.map { index in
            if index == 0 || index == points.count - 1 { return points[index] }
            let previous = points[index - 1]
            let current = points[index]
            let next = points[index + 1]
            return CGPoint(
                x: previous.x * 0.2 + current.x * 0.6 + next.x * 0.2,
                y: previous.y * 0.2 + current.y * 0.6 + next.y * 0.2
            )
        }
    }

    private func resampled(_ points: [CGPoint], spacing: CGFloat) -> [CGPoint] {
        guard points.count > 2 else { return points }
        var result = [points[0]]
        var previous = points[0]
        var carry: CGFloat = 0
        for current in points.dropFirst() {
            let segment = distance(previous, current)
            guard segment > 0.001 else { continue }
            var traveled = spacing - carry
            while traveled <= segment {
                let t = traveled / segment
                result.append(CGPoint(x: previous.x + (current.x - previous.x) * t, y: previous.y + (current.y - previous.y) * t))
                traveled += spacing
            }
            carry = max(0, segment - (traveled - spacing))
            previous = current
        }
        if result.last.map({ distance($0, points[points.count - 1]) > spacing * 0.5 }) != false {
            result.append(points[points.count - 1])
        }
        return result
    }

    private func resampleToCount(_ points: [CGPoint], count: Int) -> [CGPoint] {
        guard count > 1, points.count > 1 else { return points }
        let totalLength = polylineLength(points)
        guard totalLength > 0 else { return Array(repeating: points[0], count: count) }
        let interval = totalLength / CGFloat(count - 1)
        var result = [points[0]]
        var previous = points[0]
        var distanceSinceLast: CGFloat = 0
        for current in points.dropFirst() {
            var segmentStart = previous
            var segmentLength = distance(segmentStart, current)
            while distanceSinceLast + segmentLength >= interval, segmentLength > 0.001 {
                let remaining = interval - distanceSinceLast
                let ratio = remaining / segmentLength
                let next = CGPoint(x: segmentStart.x + (current.x - segmentStart.x) * ratio, y: segmentStart.y + (current.y - segmentStart.y) * ratio)
                result.append(next)
                segmentStart = next
                segmentLength = distance(segmentStart, current)
                distanceSinceLast = 0
            }
            distanceSinceLast += segmentLength
            previous = current
        }
        while result.count < count {
            result.append(points[points.count - 1])
        }
        return Array(result.prefix(count))
    }

    private func deduplicated(_ points: [CGPoint], diagonal: CGFloat, closed: Bool) -> [CGPoint] {
        var result: [CGPoint] = []
        for point in points {
            if result.last.map({ distance($0, point) / diagonal < 0.04 }) == true {
                continue
            }
            result.append(point)
        }
        if closed, result.count > 2, let first = result.first, let last = result.last, distance(first, last) / diagonal < 0.08 {
            result.removeLast()
        }
        return result
    }

    private func pointBounds(_ points: [CGPoint]) -> CGRect? {
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
        return CGRect(x: minX, y: minY, width: max(1, maxX - minX), height: max(1, maxY - minY))
    }

    private func polygonVertices(from points: [CGPoint], epsilon: CGFloat) -> [CGPoint] {
        guard points.count > 4 else { return points }
        var open = points
        if distance(open[0], open[open.count - 1]) < epsilon * 2 {
            open.removeLast()
        }
        guard open.count > 4 else { return open }
        let anchorIndex = open.indices.max { a, b in
            distance(open[a], open[0]) < distance(open[b], open[0])
        } ?? 0
        let rotated = Array(open[anchorIndex...]) + Array(open[..<anchorIndex]) + [open[anchorIndex]]
        return Array(simplify(rotated, epsilon: epsilon).dropLast())
    }

    private func simplify(_ points: [CGPoint], epsilon: CGFloat) -> [CGPoint] {
        guard points.count > 2 else { return points }
        var maxDistance: CGFloat = 0
        var index = 0
        for offset in 1..<(points.count - 1) {
            let candidate = lineError([points[offset]], from: points[0], to: points[points.count - 1])
            if candidate > maxDistance {
                maxDistance = candidate
                index = offset
            }
        }
        if maxDistance > epsilon {
            let left = simplify(Array(points[0...index]), epsilon: epsilon)
            let right = simplify(Array(points[index..<points.count]), epsilon: epsilon)
            return Array(left.dropLast()) + right
        }
        return [points[0], points[points.count - 1]]
    }

    private func polylineError(_ points: [CGPoint], candidate: [CGPoint]) -> CGFloat {
        guard candidate.count > 1 else { return .greatestFiniteMagnitude }
        let total = points.reduce(CGFloat(0)) { sum, point in
            sum + distanceToPolyline(point, candidate: candidate)
        }
        return total / CGFloat(max(points.count, 1))
    }

    private func distanceToPolyline(_ point: CGPoint, candidate: [CGPoint]) -> CGFloat {
        var best = CGFloat.greatestFiniteMagnitude
        for index in 0..<(candidate.count - 1) {
            best = min(best, distance(point, toSegmentStart: candidate[index], end: candidate[index + 1]))
        }
        return best
    }

    private func distance(_ point: CGPoint, toSegmentStart start: CGPoint, end: CGPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0.001 else { return distance(point, start) }
        let t = max(0, min(1, ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared))
        return distance(point, CGPoint(x: start.x + dx * t, y: start.y + dy * t))
    }

    private func lineError(_ points: [CGPoint], from start: CGPoint, to end: CGPoint) -> CGFloat {
        let denominator = max(distance(start, end), 1)
        return points.map { point in
            abs((end.x - start.x) * (start.y - point.y) - (start.x - point.x) * (end.y - start.y)) / denominator
        }.max() ?? .greatestFiniteMagnitude
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    private func turnAngle(previous: CGPoint, current: CGPoint, next: CGPoint) -> CGFloat {
        let first = CGVector(dx: previous.x - current.x, dy: previous.y - current.y)
        let second = CGVector(dx: next.x - current.x, dy: next.y - current.y)
        let firstLength = max(hypot(first.dx, first.dy), 0.001)
        let secondLength = max(hypot(second.dx, second.dy), 0.001)
        let dot = (first.dx * second.dx + first.dy * second.dy) / (firstLength * secondLength)
        return acos(max(-1, min(1, dot)))
    }

    private func closedCircularity(_ points: [CGPoint]) -> CGFloat {
        guard points.count > 3 else { return 0 }
        let area = abs(polygonArea(points))
        let perimeter = max(polylineLength(points + [points[0]]), 1)
        return 4 * .pi * area / (perimeter * perimeter)
    }

    private func polygonArea(_ points: [CGPoint]) -> CGFloat {
        guard points.count > 2 else { return 0 }
        var area: CGFloat = 0
        for index in points.indices {
            let next = points[(index + 1) % points.count]
            area += points[index].x * next.y - next.x * points[index].y
        }
        return area / 2
    }

    private func polylineLength(_ points: [CGPoint]) -> CGFloat {
        guard points.count > 1 else { return 0 }
        var length: CGFloat = 0
        for index in 1..<points.count {
            length += distance(points[index - 1], points[index])
        }
        return length
    }

    private func convexHull(_ points: [CGPoint]) -> [CGPoint] {
        let sorted = points.sorted {
            if abs($0.x - $1.x) > 0.001 {
                return $0.x < $1.x
            }
            return $0.y < $1.y
        }
        guard sorted.count > 2 else { return sorted }
        var lower: [CGPoint] = []
        for point in sorted {
            while lower.count >= 2, cross(lower[lower.count - 2], lower[lower.count - 1], point) <= 0 {
                lower.removeLast()
            }
            lower.append(point)
        }
        var upper: [CGPoint] = []
        for point in sorted.reversed() {
            while upper.count >= 2, cross(upper[upper.count - 2], upper[upper.count - 1], point) <= 0 {
                upper.removeLast()
            }
            upper.append(point)
        }
        return Array((lower.dropLast() + upper.dropLast()))
    }

    private func cross(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
        (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
    }

    private func areSimilarVertices(_ lhs: [CGPoint], _ rhs: [CGPoint], tolerance: CGFloat) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { distance($0, $1) <= tolerance }
    }

    private func circleFitError(_ points: [CGPoint], bounds: CGRect) -> CGFloat {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = max(min(bounds.width, bounds.height) / 2, 1)
        let errors = points.map { abs(distance($0, center) / radius - 1) }
        let sorted = errors.sorted()
        guard !sorted.isEmpty else { return .greatestFiniteMagnitude }
        let cutoff = max(1, Int(CGFloat(sorted.count) * 0.82))
        return sorted.prefix(cutoff).reduce(0, +) / CGFloat(cutoff)
    }

    private func ellipseFitError(_ points: [CGPoint], bounds: CGRect) -> CGFloat {
        let rx = max(bounds.width / 2, 1)
        let ry = max(bounds.height / 2, 1)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let errors = points.map { point in
            let normalizedRadius = sqrt(pow((point.x - center.x) / rx, 2) + pow((point.y - center.y) / ry, 2))
            return abs(normalizedRadius - 1)
        }
        return errors.reduce(0, +) / CGFloat(max(errors.count, 1))
    }

    private func angularCoverage(_ points: [CGPoint], bounds: CGRect) -> CGFloat {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        var bins = Set<Int>()
        let binCount = 24
        for point in points where distance(point, center) > 1 {
            var angle = atan2(point.y - center.y, point.x - center.x)
            if angle < 0 {
                angle += .pi * 2
            }
            bins.insert(min(binCount - 1, max(0, Int(angle / (.pi * 2) * CGFloat(binCount)))))
        }
        return CGFloat(bins.count) / CGFloat(binCount)
    }

    private func circlePoints(in bounds: CGRect, count: Int) -> [CGPoint] {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = max(bounds.width, bounds.height) / 2
        return (0...count).map { index in
            let angle = CGFloat(index) / CGFloat(count) * .pi * 2
            return CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
        }
    }

    private func ellipsePoints(in bounds: CGRect, count: Int) -> [CGPoint] {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let rx = bounds.width / 2
        let ry = bounds.height / 2
        return (0...count).map { index in
            let angle = CGFloat(index) / CGFloat(count) * .pi * 2
            return CGPoint(x: center.x + cos(angle) * rx, y: center.y + sin(angle) * ry)
        }
    }

    private func rectanglePoints(in bounds: CGRect) -> [CGPoint] {
        let topLeft = CGPoint(x: bounds.minX, y: bounds.minY)
        let topRight = CGPoint(x: bounds.maxX, y: bounds.minY)
        let bottomRight = CGPoint(x: bounds.maxX, y: bounds.maxY)
        let bottomLeft = CGPoint(x: bounds.minX, y: bounds.maxY)
        return [topLeft, topRight, bottomRight, bottomLeft, topLeft]
    }
}
