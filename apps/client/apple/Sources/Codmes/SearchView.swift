import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    var onSelectSurface: ((String) -> Void)?

    @State private var query = ""
    @State private var surface = GlobalSearchSurface.all
    @State private var isSearching = false
    @State private var isLoadingMore = false
    @State private var liveSearchTask: Task<Void, Never>?
    @State private var searchRequestSerial = 0
    @FocusState private var isSearchFieldFocused: Bool

    private var groupedResults: [(GlobalSearchSurface, [GlobalSearchResult])] {
        let results = visibleResults
        return GlobalSearchSurface.resultGroups.compactMap { group in
            let matches = results.filter { $0.surface == group.rawValue }
            return matches.isEmpty ? nil : (group, matches)
        }
    }

    private func fileGroups(surface: GlobalSearchSurface) -> [NoteSearchFileGroup] {
        let fileResults = visibleResults.filter { $0.surface == surface.rawValue && $0.target.path != nil }
        let grouped = Dictionary(grouping: fileResults) { $0.target.path ?? $0.title }
        let summaries = store.globalSearchResponse?.documents ?? []
        let summaryByPath = Dictionary(uniqueKeysWithValues: summaries.map { ($0.path, $0) })
        let documentOrder = Dictionary(uniqueKeysWithValues: summaries.enumerated().map { ($0.element.path, $0.offset) })
        return grouped.map { path, results in
            NoteSearchFileGroup(
                path: path,
                results: results.sorted(by: sortSearchResults),
                summary: summaryByPath[path]
            )
        }
        .sorted { lhs, rhs in
            (documentOrder[lhs.path] ?? .max) < (documentOrder[rhs.path] ?? .max)
        }
    }

    private var visibleResults: [GlobalSearchResult] {
        (store.globalSearchResponse?.results ?? []).filter { result in
            guard let path = result.target.path else { return true }
            let lowered = path.lowercased()
            return !lowered.hasPrefix(".codmes/") && !lowered.contains("/.codmes/")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchHeader
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    searchTextField

                    Button("Search") {
                        submitSearch()
                    }
                    .disabled(draftQuery.isEmpty)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))

                Picker("Surface", selection: $surface) {
                    ForEach(GlobalSearchSurface.allCases) { surface in
                        Text(surface.title).tag(surface)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: surface) { _, _ in
                    scheduleLiveSearch(delay: 0)
                }
            }
            .padding(16)
            .background(.quaternary.opacity(0.10))
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(.quaternary.opacity(0.35))
                    .frame(height: 1)
            }

            if submittedQuery.isEmpty {
                ContentUnavailableView(
                    "Search Codmes",
                    systemImage: "magnifyingglass",
                    description: Text("Find notes, PDF text, code, sessions, and messages.")
                )
                .contentShape(Rectangle())
                .onTapGesture { dismissSearchKeyboard() }
            } else if isSearching && (store.globalSearchResponse?.query != submittedQuery) {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { dismissSearchKeyboard() }
            } else if groupedResults.isEmpty {
                ContentUnavailableView(
                    "No Results",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("Try another keyword or switch the Surface filter.")
                )
                .contentShape(Rectangle())
                .onTapGesture { dismissSearchKeyboard() }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18, pinnedViews: []) {
                        ForEach(groupedResults, id: \.0) { group, results in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(group.title)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .textCase(.uppercase)
                                    .padding(.horizontal, 16)

                                VStack(alignment: .leading, spacing: 0) {
                                    if group == .notes || group == .codes {
                                        ForEach(fileGroups(surface: group)) { fileGroup in
                                            NoteSearchFileGroupView(
                                                fileGroup: fileGroup,
                                                query: submittedQuery,
                                                thumbnailURL: { result, crop in thumbnailURL(for: result, crop: crop) },
                                                onResultsAppear: loadMoreIfNeeded(resultIDs:)
                                            ) { result in
                                                openResult(result)
                                            }
                                            .padding(.horizontal, 16)
                                            .background(Color.secondary.opacity(0.07))
                                        }
                                    }

                                    ForEach(results.filter { group == .chat || $0.target.path == nil }) { result in
                                            Button {
                                                openResult(result)
                                            } label: {
                                                GlobalSearchResultRow(result: result, query: submittedQuery)
                                                    .padding(.horizontal, 16)
                                            }
                                            .buttonStyle(.plain)
                                            .background(Color.secondary.opacity(0.07))
                                            .onAppear {
                                                loadMoreIfNeeded(resultIDs: [result.id])
                                            }
                                    }
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .padding(.horizontal, 12)
                            }
                        }

                        if isLoadingMore {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                    }
                    .padding(.vertical, 14)
                }
                .contentShape(Rectangle())
                .simultaneousGesture(TapGesture().onEnded { dismissSearchKeyboard() })
#if os(iOS)
                .scrollDismissesKeyboard(.immediately)
#endif
            }
        }
#if os(iOS)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.keyboard, edges: .bottom)
#else
        .frame(minWidth: 560, minHeight: 520)
#endif
        .onAppear { focusSearchFieldIfNeeded() }
        .task {
            submitSearchIfReady()
        }
        .onDisappear {
            liveSearchTask?.cancel()
        }
    }

    private var searchHeader: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Global Search")
                    .font(.title2.weight(.semibold))
                Text("Search Notes, Codes, and Chat")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .accessibilityLabel("Close search")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.quaternary.opacity(0.18))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(.quaternary.opacity(0.55))
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private var searchTextField: some View {
        TextField("Search Codmes", text: $query)
            .textFieldStyle(.plain)
            .focused($isSearchFieldFocused)
            .onSubmit { submitSearch() }
            .submitLabel(.search)
            .autocorrectionDisabled()
#if os(iOS)
            .textInputAutocapitalization(.never)
#endif
            .onChange(of: query) { _, _ in
                scheduleLiveSearch()
            }
    }

    private var draftQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var submittedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submitSearchIfReady() {
        guard !draftQuery.isEmpty else { return }
        scheduleLiveSearch(delay: 0)
    }

    private func submitSearch() {
        let searchQuery = draftQuery
        guard !searchQuery.isEmpty else { return }
        liveSearchTask?.cancel()
        searchRequestSerial += 1
        runGlobalSearch(query: searchQuery, surfaceValue: surface.rawValue, requestID: searchRequestSerial)
    }

    private func scheduleLiveSearch(_ rawQuery: String? = nil, delay: UInt64 = 350_000_000) {
        let searchQuery = (rawQuery ?? draftQuery).trimmingCharacters(in: .whitespacesAndNewlines)
        liveSearchTask?.cancel()
        searchRequestSerial += 1
        let requestID = searchRequestSerial
        guard !searchQuery.isEmpty else {
            query = ""
            isSearching = false
            isLoadingMore = false
            store.globalSearchResponse = nil
            return
        }
        let surfaceValue = surface.rawValue
        guard store.api != nil else { return }
        liveSearchTask = Task {
            if delay > 0 {
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                runGlobalSearch(query: searchQuery, surfaceValue: surfaceValue, requestID: requestID)
            }
        }
    }

    private func runGlobalSearch(query searchQuery: String, surfaceValue: String, requestID: Int) {
        guard let api = store.api else { return }
        query = searchQuery
        isSearching = true
        isLoadingMore = false
        Task {
            do {
                let response = try await api.globalSearch(query: searchQuery, surface: surfaceValue)
                await MainActor.run {
                    guard searchRequestSerial == requestID else { return }
                    store.globalSearchResponse = response
                    store.statusMessage = "\(response.resultCount) global results"
                    isSearching = false
                }
            } catch {
                await MainActor.run {
                    guard searchRequestSerial == requestID else { return }
                    store.statusMessage = error.localizedDescription
                    isSearching = false
                }
            }
        }
    }

    private func loadMoreIfNeeded(resultIDs: [String]) {
        guard !isSearching, !isLoadingMore,
              let response = store.globalSearchResponse,
              response.query == submittedQuery,
              response.surface == surface.rawValue,
              let cursor = response.nextCursor,
              let lastResultID = response.results.last?.id,
              resultIDs.contains(lastResultID),
              let api = store.api else { return }
        let requestID = searchRequestSerial
        let searchQuery = submittedQuery
        let surfaceValue = surface.rawValue
        isLoadingMore = true
        Task {
            do {
                let nextPage = try await api.globalSearch(
                    query: searchQuery,
                    surface: surfaceValue,
                    cursor: cursor
                )
                await MainActor.run {
                    guard searchRequestSerial == requestID,
                          submittedQuery == searchQuery,
                          surface.rawValue == surfaceValue else { return }
                    let currentResults = store.globalSearchResponse?.results ?? []
                    var seen = Set(currentResults.map(\.id))
                    let newResults = nextPage.results.filter { seen.insert($0.id).inserted }
                    let mergedResults = currentResults + newResults
                    store.globalSearchResponse = GlobalSearchResponse(
                        provider: nextPage.provider,
                        query: nextPage.query,
                        surface: nextPage.surface,
                        resultCount: nextPage.resultCount,
                        returnedCount: mergedResults.count,
                        nextCursor: nextPage.nextCursor,
                        hasMore: nextPage.hasMore,
                        documents: nextPage.documents,
                        results: mergedResults
                    )
                    store.statusMessage = "\(mergedResults.count) of \(nextPage.resultCount) global results"
                    isLoadingMore = false
                }
            } catch {
                await MainActor.run {
                    guard searchRequestSerial == requestID else { return }
                    store.statusMessage = error.localizedDescription
                    isLoadingMore = false
                }
            }
        }
    }

    private func focusSearchFieldIfNeeded() {
#if os(macOS)
        let delays: [TimeInterval] = [0.08]
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                isSearchFieldFocused = true
            }
        }
#endif
    }

    private func dismissSearchKeyboard() {
        isSearchFieldFocused = false
    }

    private func thumbnailURL(for result: GlobalSearchResult, crop: NormalizedBoundingBox? = nil) -> URL? {
        guard let path = result.target.path,
              path.lowercased().hasSuffix(".pdf"),
              let api = store.api else { return nil }
        let page = result.target.page ?? 1
        return try? api.pdfThumbnailURL(
            path: path,
            page: page,
            crop: result.target.page == nil ? nil : crop ?? result.target.bbox?.normalizedOrSelf,
            highlightQuery: result.target.page == nil ? nil : submittedQuery
        )
    }

    private func openResult(_ result: GlobalSearchResult) {
        onSelectSurface?(result.surface)
        Task {
            await store.openGlobalSearchResult(result)
            dismiss()
        }
    }
}

private struct NoteSearchFileGroup: Identifiable {
    let path: String
    let results: [GlobalSearchResult]
    let summary: GlobalSearchDocumentSummary?

    var id: String { path }
    var title: String { URL(fileURLWithPath: path).lastPathComponent }
}

private struct NoteSearchFileGroupView: View {
    let fileGroup: NoteSearchFileGroup
    let query: String
    let thumbnailURL: (GlobalSearchResult, NormalizedBoundingBox?) -> URL?
    let onResultsAppear: ([String]) -> Void
    let onOpen: (GlobalSearchResult) -> Void

    private var previewResults: [NoteSearchPreview] {
        let contentMatches = fileGroup.results.filter { !isFileTitleResult($0) }
        let pageMatches = contentMatches.filter { $0.target.page != nil }
        let groupedByPage = Dictionary(grouping: pageMatches) { $0.target.page ?? 0 }
        let pagePreviews = groupedByPage.keys.sorted().flatMap { page in
            makePagePreviews(groupedByPage[page] ?? [])
        }
        let nonPagePreviews = contentMatches
            .filter { $0.target.page == nil }
            .map { NoteSearchPreview(result: $0, crop: nil, matchCount: 1, resultIDs: [$0.id]) }
        return [NoteSearchPreview(result: coverResult, crop: nil, matchCount: 0, resultIDs: [coverResult.id])]
            + pagePreviews
            + nonPagePreviews
    }

    private var coverResult: GlobalSearchResult {
        if let fileMatch = fileGroup.results
            .first(where: isFileTitleResult) {
            return fileMatch
        }
        let source = fileGroup.results[0]
        return GlobalSearchResult(
            id: "cover:\(fileGroup.path)",
            surface: source.surface,
            kind: source.surface == "codes" ? "code_file" : "note_file",
            title: fileGroup.title,
            subtitle: fileGroup.path,
            snippet: fileGroup.path,
            score: source.score,
            updatedAt: source.updatedAt,
            target: GlobalSearchTarget(
                path: fileGroup.path,
                page: nil,
                sessionId: nil,
                messageId: nil,
                projectId: nil,
                line: nil,
                bbox: nil
            )
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: fileGroup.title.lowercased().hasSuffix(".pdf") ? "doc.richtext" : "note.text")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(fileGroup.title)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(resultSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(previewResults) { preview in
                        Button {
                            onOpen(preview.result)
                        } label: {
                            NoteSearchPreviewCard(
                                preview: preview,
                                query: query,
                                thumbnailURL: thumbnailURL(preview.result, preview.crop)
                            )
                        }
                        .buttonStyle(.plain)
                        .onAppear {
                            onResultsAppear(preview.resultIDs)
                        }
                    }
                }
                .padding(.bottom, 2)
            }
        }
        .padding(.vertical, 8)
    }

    private var resultSummary: String {
        let occurrences = fileGroup.summary?.occurrenceCount ?? fileGroup.results.filter { !isFileTitleResult($0) }.count
        let pages = fileGroup.summary?.matchedPageCount ?? Set(fileGroup.results.compactMap(\.target.page)).count
        if occurrences == 0 { return "Filename match" }
        if pages > 0 { return "\(pages) pages · \(occurrences) matches" }
        return "\(occurrences) matches"
    }
}

private struct NoteSearchPreviewCard: View {
    let preview: NoteSearchPreview
    let query: String
    let thumbnailURL: URL?

    private var result: GlobalSearchResult { preview.result }
    private var cardWidth: CGFloat { isFileMatch ? 112 : 210 }
    private let imageHeight: CGFloat = 148

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.09))
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.22), lineWidth: 1)
                if let thumbnailURL {
                    AsyncImage(url: thumbnailURL) { phase in
                        switch phase {
                        case let .success(image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: isFileMatch ? .fit : .fill)
                                .frame(width: cardWidth, height: imageHeight)
                                .clipped()
                        case .failure:
                            snippetPreview
                        case .empty:
                            ProgressView()
                                .frame(width: cardWidth, height: imageHeight)
                        @unknown default:
                            snippetPreview
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    snippetPreview
                }
            }
            .frame(width: cardWidth, height: imageHeight)

            Text(pageLabel)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .frame(width: cardWidth, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var snippetPreview: some View {
        Text(result.snippet)
            .font(.caption)
            .lineLimit(6)
            .foregroundStyle(.secondary)
            .padding(10)
            .frame(width: cardWidth, height: imageHeight, alignment: .topLeading)
    }

    private var pageLabel: String {
        if let page = result.target.page {
            return preview.matchCount > 1 ? "p.\(page) · \(preview.matchCount) matches" : "p.\(page)"
        }
        return isFileMatch ? result.title : "Match"
    }

    private var isFileMatch: Bool { isFileTitleResult(result) || result.id.hasPrefix("cover:") }
}

private struct NoteSearchPreview: Identifiable {
    let result: GlobalSearchResult
    let crop: NormalizedBoundingBox?
    let matchCount: Int
    let resultIDs: [String]

    var id: String {
        guard let crop else { return result.id }
        return "\(result.target.path ?? ""):\(result.target.page ?? 0):\(crop.x):\(crop.y)"
    }
}

private func isFileTitleResult(_ result: GlobalSearchResult) -> Bool {
    result.kind == "note_file" || result.kind == "code_file"
}

private func makePagePreviews(_ results: [GlobalSearchResult]) -> [NoteSearchPreview] {
    let sorted = results.sorted { lhs, rhs in
        let lhsBox = lhs.target.bbox?.normalizedOrSelf
        let rhsBox = rhs.target.bbox?.normalizedOrSelf
        if lhsBox?.y != rhsBox?.y { return (lhsBox?.y ?? 1) < (rhsBox?.y ?? 1) }
        return (lhsBox?.x ?? 1) < (rhsBox?.x ?? 1)
    }
    var clusters: [[GlobalSearchResult]] = []
    for result in sorted {
        guard let resultBox = result.target.bbox?.normalizedOrSelf,
              let lastCluster = clusters.last,
              let clusterBox = boundingBox(for: lastCluster),
              previewCanContain(union(clusterBox, resultBox)) else {
            clusters.append([result])
            continue
        }
        clusters[clusters.count - 1].append(result)
    }
    return clusters.map { cluster in
        NoteSearchPreview(
            result: cluster[0],
            crop: boundingBox(for: cluster),
            matchCount: cluster.count,
            resultIDs: cluster.map(\.id)
        )
    }
}

private func boundingBox(for results: [GlobalSearchResult]) -> NormalizedBoundingBox? {
    let boxes = results.compactMap { $0.target.bbox?.normalizedOrSelf }
    guard var result = boxes.first else { return nil }
    for box in boxes.dropFirst() {
        result = union(result, box)
    }
    return result
}

private func union(_ lhs: NormalizedBoundingBox, _ rhs: NormalizedBoundingBox) -> NormalizedBoundingBox {
    let x = min(lhs.x, rhs.x)
    let y = min(lhs.y, rhs.y)
    let maxX = max(lhs.x + lhs.width, rhs.x + rhs.width)
    let maxY = max(lhs.y + lhs.height, rhs.y + rhs.height)
    return NormalizedBoundingBox(x: x, y: y, width: maxX - x, height: maxY - y)
}

private func previewCanContain(_ box: NormalizedBoundingBox) -> Bool {
    box.width <= 0.36 && box.height <= 0.16
}

private struct GlobalSearchResultRow: View {
    let result: GlobalSearchResult
    let query: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(result.title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(result.kind.replacingOccurrences(of: "_", with: " "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(result.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(result.snippet)
                .font(.body)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .textSelection(.enabled)
            HStack(spacing: 10) {
                Text(result.surface.capitalized)
                Text("score \(Int(result.score.rounded()))")
                if let updatedAt = result.updatedAt, !updatedAt.isEmpty {
                    Text(updatedAt)
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 6)
    }

    private var iconName: String {
        switch result.surface {
        case "notes":
            result.kind.contains("pdf") ? "doc.richtext" : "note.text"
        case "codes":
            "chevron.left.forwardslash.chevron.right"
        case "chat":
            "bubble.left.and.bubble.right"
        default:
            "magnifyingglass"
        }
    }
}

private enum GlobalSearchSurface: String, CaseIterable, Identifiable {
    case all
    case notes
    case codes
    case chat

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .notes: "Notes"
        case .codes: "Codes"
        case .chat: "Chat"
        }
    }

    static var resultGroups: [GlobalSearchSurface] {
        [.notes, .codes, .chat]
    }
}

private func sortSearchResults(_ lhs: GlobalSearchResult, _ rhs: GlobalSearchResult) -> Bool {
    if let lhsPage = lhs.target.page, let rhsPage = rhs.target.page, lhs.target.path == rhs.target.path {
        return lhsPage < rhsPage
    }
    return lhs.score > rhs.score
}
