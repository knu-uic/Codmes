import SwiftUI
import PDFKit
import UniformTypeIdentifiers

#if os(iOS)
import PencilKit
import UIKit
#endif

#if os(macOS)
import AppKit
#endif

#if os(iOS)
fileprivate typealias PDFPagePreviewImage = UIImage
#else
fileprivate typealias PDFPagePreviewImage = NSImage
#endif

fileprivate enum PDFReadingZoom {
    static let pageHeightFraction: CGFloat = 0.88
    static let pageWidthFraction: CGFloat = 0.94
    static let elasticLowerBoundFraction: CGFloat = 0.78

    static func fittedScale(page: PDFPage, displayBox: PDFDisplayBox, viewport: CGSize) -> CGFloat? {
        guard viewport.width > 1, viewport.height > 1 else { return nil }
        var pageSize = page.bounds(for: displayBox).size
        if abs(page.rotation) % 180 == 90 {
            pageSize = CGSize(width: pageSize.height, height: pageSize.width)
        }
        guard pageSize.width > 1, pageSize.height > 1 else { return nil }
        let widthScale = viewport.width * pageWidthFraction / pageSize.width
        let heightScale = viewport.height * pageHeightFraction / pageSize.height
        return min(widthScale, heightScale)
    }
}

#if os(iOS)
fileprivate enum PDFMarkupTool: String, CaseIterable, Identifiable {
    case pen
    case eraser
    case lasso
    case text

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .pen: "pencil.tip"
        case .eraser: "eraser"
        case .lasso: "lasso"
        case .text: "textformat"
        }
    }

    var label: String {
        switch self {
        case .pen: "Pen"
        case .eraser: "Erase"
        case .lasso: "Lasso"
        case .text: "Text"
        }
    }
}

fileprivate struct PDFExportShare: Identifiable {
    let id = UUID()
    let urls: [URL]
}

fileprivate enum PDFExportPageScope: Equatable {
    case currentPage
    case pageSelection
    case allPages
}

fileprivate enum PDFExportFormat: String, CaseIterable, Identifiable {
    case pdf
    case editableCodmes

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pdf: "PDF"
        case .editableCodmes: "Editable Codmes"
        }
    }

    var systemImage: String {
        switch self {
        case .pdf: "doc.richtext"
        case .editableCodmes: "shippingbox"
        }
    }
}
#endif

fileprivate struct PDFLassoSelectionSummary: Equatable {
    var pageIndex: Int
    var strokeIds: Set<String>
    var objectIds: Set<String>
    var bounds: AnnotationBoundingBox
    var optionAnchor: CGPoint?
    var isMoving: Bool
}

@MainActor
final class StreamedPDFSession: ObservableObject {
    typealias CachedPageLoader = @Sendable (Int) async -> URL?
    typealias PageCacheWriter = @Sendable (URL, Int) async throws -> URL

    let path: String
    let name: String
    let metadata: PDFMetadataResponse
    let document: PDFDocument
    @Published private(set) var revision = 0
    @Published private(set) var loadedPageIndexes = Set<Int>()
    @Published private(set) var failedPageIndexes = Set<Int>()
    @Published private(set) var lastInstalledPageIndex: Int?

    private let api: WorkspaceAPI
    private let cachedPageLoader: CachedPageLoader
    private let pageCacheWriter: PageCacheWriter
    private var loadingPageIndexes = Set<Int>()
    private var retainedPageDocuments: [Int: PDFDocument] = [:]

    init?(
        path: String,
        name: String,
        metadata: PDFMetadataResponse,
        skeletonURL: URL,
        api: WorkspaceAPI,
        cachedPageLoader: @escaping CachedPageLoader,
        pageCacheWriter: @escaping PageCacheWriter
    ) {
        guard let document = PDFDocument(url: skeletonURL), document.pageCount == metadata.pageCount else {
            return nil
        }
        self.path = path
        self.name = name
        self.metadata = metadata
        self.document = document
        self.api = api
        self.cachedPageLoader = cachedPageLoader
        self.pageCacheWriter = pageCacheWriter
    }

    func requestPages(around pageIndex: Int) {
        guard metadata.pageCount > 0 else { return }
        let current = min(max(pageIndex, 0), metadata.pageCount - 1)
        let priority = [current, current + 1, current - 1, current + 2, current - 2]
        for index in priority where index >= 0 && index < metadata.pageCount {
            requestPage(index)
        }
    }

    func requestPage(_ pageIndex: Int) {
        guard pageIndex >= 0,
              pageIndex < metadata.pageCount,
              !loadedPageIndexes.contains(pageIndex),
              !loadingPageIndexes.contains(pageIndex) else { return }
        loadingPageIndexes.insert(pageIndex)
        failedPageIndexes.remove(pageIndex)

        Task { [weak self] in
            await self?.loadPage(pageIndex)
        }
    }

    func preparePage(_ pageIndex: Int) async {
        guard pageIndex >= 0, pageIndex < metadata.pageCount else { return }
        if loadedPageIndexes.contains(pageIndex) { return }
        if loadingPageIndexes.contains(pageIndex) {
            while loadingPageIndexes.contains(pageIndex) {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            return
        }
        loadingPageIndexes.insert(pageIndex)
        failedPageIndexes.remove(pageIndex)
        await loadPage(pageIndex)
    }

    private func loadPage(_ pageIndex: Int) async {
        do {
            let pageURL: URL
            if let cached = await cachedPageLoader(pageIndex) {
                pageURL = cached
            } else {
                let downloaded = try await api.downloadPDFPage(path: path, page: pageIndex + 1, name: name)
                pageURL = try await pageCacheWriter(downloaded, pageIndex)
            }
            guard !Task.isCancelled,
                  let pageDocument = PDFDocument(url: pageURL),
                  let page = pageDocument.page(at: 0) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            retainedPageDocuments[pageIndex] = pageDocument
            install(page, at: pageIndex)
        } catch {
            loadingPageIndexes.remove(pageIndex)
            failedPageIndexes.insert(pageIndex)
        }
    }

    private func install(_ page: PDFPage, at pageIndex: Int) {
        guard !loadedPageIndexes.contains(pageIndex), pageIndex < document.pageCount else {
            loadingPageIndexes.remove(pageIndex)
            return
        }
        document.removePage(at: pageIndex)
        document.insert(page, at: pageIndex)
        loadingPageIndexes.remove(pageIndex)
        loadedPageIndexes.insert(pageIndex)
        lastInstalledPageIndex = pageIndex
        revision += 1
    }
}

#if os(macOS)
fileprivate enum MacPDFMarkupTool: String, CaseIterable, Identifiable {
    case pen
    case eraser
    case lasso
    case text

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .pen: "pencil.tip"
        case .eraser: "eraser"
        case .lasso: "lasso"
        case .text: "textformat"
        }
    }

    var label: String {
        switch self {
        case .pen: "Pen"
        case .eraser: "Erase"
        case .lasso: "Lasso"
        case .text: "Text"
        }
    }
}

fileprivate enum MacPDFObjectInteraction {
    case move
    case resize(CodmesNoteObjectResizeEdge)
}
#endif

/// Lightweight fallback after memory-pressure eviction; ordinary navigation
/// keeps the PDFKit view itself, including zoom, viewport, tools and undo.
struct PDFReadingState: Equatable, Sendable {
    let pageIndex: Int
    let scale: Double
    let x: Double
    let y: Double

    @MainActor
    static func capture(_ view: PDFView) -> Self? {
        guard let document = view.document, let destination = view.currentDestination,
              let page = destination.page else { return nil }
        let index = document.index(for: page)
        guard index >= 0, index < document.pageCount, view.scaleFactor > 0 else { return nil }
        return Self(pageIndex: index, scale: Double(view.scaleFactor), x: Double(destination.point.x), y: Double(destination.point.y))
    }

    @MainActor
    func restore(_ view: PDFView) {
        guard let page = view.document?.page(at: pageIndex), scale.isFinite, scale > 0,
              x.isFinite, y.isFinite else { return }
        view.scaleFactor = CGFloat(scale)
        view.go(to: PDFDestination(page: page, at: CGPoint(x: x, y: y)))
        // PDFKit clamps destinations to page bounds, excluding page-break
        // margins. Correct the underlying viewport rather than asking for an
        // out-of-page destination (which PDFKit would clamp again).
        if let actual = view.currentDestination, actual.page === page {
            let desiredPoint = view.convert(CGPoint(x: x, y: y), from: page)
            let actualPoint = view.convert(actual.point, from: page)
            #if os(macOS)
            if let scroll = view.documentView?.enclosingScrollView {
                let clip = scroll.contentView
                let desired = clip.convert(desiredPoint, from: view)
                let current = clip.convert(actualPoint, from: view)
                clip.scroll(to: CGPoint(x: clip.bounds.origin.x + desired.x - current.x,
                                        y: clip.bounds.origin.y + desired.y - current.y))
                scroll.reflectScrolledClipView(clip)
            }
            #else
            if let scroll = view.descendantScrollViews.filter({ $0.isScrollEnabled }).max(by: { $0.contentSize.height < $1.contentSize.height }) {
                let desired = scroll.convert(desiredPoint, from: view)
                let current = scroll.convert(actualPoint, from: view)
                scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x + desired.x - current.x,
                                                y: scroll.contentOffset.y + desired.y - current.y), animated: false)
            }
            #endif
        }
    }
}

struct PDFWorkspaceView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.isFileSurfaceActive) private var isSurfaceActive
    let rawFile: RawFilePreview
    var streamSession: StreamedPDFSession? = nil
    var streamRevision = 0
    @State private var annotations: PDFAnnotationDocument?
    @State private var undoStack: [PDFAnnotationDocument] = []
    @State private var redoStack: [PDFAnnotationDocument] = []
    @State private var statusText = ""
    @State private var saveTask: Task<Void, Never>?
    @State private var currentPageIndex = 0
    @State private var isPageBrowserPresented = false

    #if os(iOS)
    @State private var markupTool: PDFMarkupTool = .pen
    @State private var isWritingMode = false
    @State private var toolOptions: PDFMarkupTool?
    @State private var didConfirmCurrentTool = false
    @State private var penColorHex = "#111111"
    @State private var penWidth = 2.5
    @State private var eraserWidth = 18.0
    @State private var isImportingImage = false
    @State private var selectedObjectId: String?
    @State private var lassoSelection: PDFLassoSelectionSummary?
    @State private var textEditRequest = 0
    @State private var isExportScopePresented = false
    @State private var isExportOptionsPresented = false
    @State private var exportPageScope = PDFExportPageScope.allPages
    @State private var exportFormat = PDFExportFormat.pdf
    @State private var exportIncludesAnnotations = true
    @State private var exportPageRange = ""
    @State private var exportPageCount = 0
    @State private var isExportingPDF = false
    @State private var exportedPDFShare: PDFExportShare?
    @State private var isImportingPDFPages = false
    #endif

    #if os(macOS)
    @State private var macMarkupTool: MacPDFMarkupTool = .pen
    @State private var isMacWritingMode = false
    @State private var macToolOptions: MacPDFMarkupTool?
    @State private var didConfirmCurrentMacTool = false
    @State private var macPenColorHex = "#111111"
    @State private var macPenWidth = 2.5
    @State private var macEraserWidth = 18.0
    @State private var macSelectedObjectId: String?
    @State private var macLassoSelection: PDFLassoSelectionSummary?
    @State private var macTextEditRequest = 0
    #endif

    var body: some View {
        VStack(spacing: 0) {
            header

            GeometryReader { stageProxy in
                ZStack(alignment: .leading) {
                    #if os(iOS)
                    AnnotatedPDFKitView(
                url: rawFile.url,
                documentOverride: streamSession?.document,
                documentRevision: streamRevision,
                forceDocumentReload: streamSession?.lastInstalledPageIndex == currentPageIndex,
                readingState: store.pdfReadingState(for: rawFile.path),
                onSaveReadingState: readingStateSaver,
                annotations: annotations,
                focus: store.pdfFocus(for: rawFile.path),
                tool: markupTool,
                isWritingMode: isWritingMode,
                penColorHex: penColorHex,
                penWidth: penWidth,
                eraserWidth: eraserWidth,
                selectedObjectId: selectedObjectId,
                lassoSelection: lassoSelection,
                textEditRequest: textEditRequest,
                onCurrentPageChanged: {
                    currentPageIndex = $0
                    if isSurfaceActive { streamSession?.requestPages(around: $0) }
                },
                onStrokeFinished: appendInkStroke(pageIndex:stroke:),
                onStrokesChanged: replaceInkStrokes(pageIndex:strokes:),
                onObjectSelected: { selectedObjectId = $0.id },
                onObjectChanged: updateAnnotationObject(_:),
                onObjectDeleted: deleteAnnotationObject(_:),
                onLassoSelectionChanged: { lassoSelection = $0 },
                onFocusCleared: { if store.selectedPDFFocus?.path == rawFile.path { store.selectedPDFFocus = nil } }
                    )
                    .frame(
                        width: stageProxy.size.width,
                        height: stageProxy.size.height
                    )
                    .overlay {
                        GeometryReader { proxy in
                            if let selection = lassoSelection,
                               !selection.isMoving,
                               let anchor = selection.optionAnchor,
                               isWritingMode {
                                PDFLassoOptionsBar(
                                    selection: selection,
                                    hasTextSelection: hasTextObject(in: selection),
                                    onDelete: { deleteLassoSelection(selection) },
                                    onColor: { recolorLassoSelection(selection, colorHex: $0) },
                                    onFontSize: { adjustLassoTextSize(selection, delta: $0) },
                                    onEditText: { editLassoText(selection) }
                                )
                                .position(
                                    x: min(max(anchor.x, 92), proxy.size.width - 92),
                                    y: min(max(anchor.y, 28), proxy.size.height - 28)
                                )
                            }
                        }
                    }
                    .scaleEffect(pdfCanvasScale, anchor: .center)
                    .offset(x: pdfCanvasOffset(for: stageProxy.size))
                    #else
                    MacAnnotatedPDFKitView(
                url: rawFile.url,
                documentOverride: streamSession?.document,
                documentRevision: streamRevision,
                forceDocumentReload: streamSession?.lastInstalledPageIndex == currentPageIndex,
                readingState: store.pdfReadingState(for: rawFile.path),
                onSaveReadingState: readingStateSaver,
                focus: store.pdfFocus(for: rawFile.path),
                annotations: annotations,
                tool: macMarkupTool,
                isWritingMode: isMacWritingMode,
                penColorHex: macPenColorHex,
                penWidth: macPenWidth,
                eraserWidth: macEraserWidth,
                selectedObjectId: macSelectedObjectId,
                lassoSelection: macLassoSelection,
                textEditRequest: macTextEditRequest,
                onStrokeFinished: appendMacInkStroke(pageIndex:stroke:),
                onStrokesChanged: replaceMacInkStrokes(pageIndex:strokes:),
                onObjectSelected: { macSelectedObjectId = $0.id },
                onObjectChanged: updateMacAnnotationObject(_:),
                onObjectDeleted: deleteMacAnnotationObject(_:),
                onLassoSelectionChanged: { macLassoSelection = $0 },
                onCurrentPageChanged: {
                    currentPageIndex = $0
                    if isSurfaceActive { streamSession?.requestPages(around: $0) }
                },
                onObjectEditRequested: {
                    macSelectedObjectId = $0.id
                    if $0.type.lowercased().contains("text") {
                        isMacWritingMode = true
                        macMarkupTool = .text
                        macTextEditRequest += 1
                    }
                }
                    )
                    .frame(
                        width: stageProxy.size.width,
                        height: stageProxy.size.height
                    )
                    .overlay {
                        GeometryReader { proxy in
                            if let selection = macLassoSelection,
                               !selection.isMoving,
                               let anchor = selection.optionAnchor,
                               isMacWritingMode {
                                MacPDFLassoOptionsBar(
                                    hasTextSelection: hasMacTextObject(in: selection),
                                    onDelete: { deleteMacLassoSelection(selection) },
                                    onColor: { recolorMacLassoSelection(selection, colorHex: $0) },
                                    onFontSize: { adjustMacLassoTextSize(selection, delta: $0) },
                                    onEditText: { editMacLassoText(selection) }
                                )
                                .position(
                                    x: min(max(anchor.x, 92), proxy.size.width - 92),
                                    y: min(max(anchor.y, 28), proxy.size.height - 28)
                                )
                            }
                        }
                    }
                    .scaleEffect(pdfCanvasScale, anchor: .center)
                    .offset(x: pdfCanvasOffset(for: stageProxy.size))
                    #endif

                    if isPDFWritingMode {
                        historyControls
                            .padding(.leading, 12)
                            .padding(.top, 12)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .offset(x: historyControlsOffset(for: stageProxy.size.width))
                            .transition(.opacity)
                            .zIndex(0.5)
                    }

                    if let streamSession,
                       !streamSession.loadedPageIndexes.contains(currentPageIndex) {
                        HStack(spacing: 7) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Loading page \(currentPageIndex + 1)")
                                .font(.caption.monospacedDigit())
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .frame(height: 34)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .padding(10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .zIndex(0.6)
                    }

                    if isPageBrowserPresented, usesOverlayPageBrowser {
                        Color.black.opacity(0.14)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.25)) {
                                    isPageBrowserPresented = false
                                }
                            }
                            .transition(.opacity)
                            .zIndex(1)
                    }

                    if isPageBrowserPresented {
                        pageBrowserPanel(width: pageBrowserWidth(for: stageProxy.size.width))
                            .transition(.move(edge: .leading).combined(with: .opacity))
                            .zIndex(2)
                    }
                }
                .clipped()
                .animation(.easeInOut(duration: 0.25), value: isPageBrowserPresented)
                .animation(.easeInOut(duration: 0.25), value: stageProxy.size)
            }
        }
        .task(id: "\(rawFile.path):\(store.localSyncRevision):\(isSurfaceActive)") {
            guard isSurfaceActive else { return }
            streamSession?.requestPages(around: currentPageIndex)
            await loadAnnotations()
        }
        .onChange(of: statusText, initial: true) { _, value in
            guard isSurfaceActive else { return }
            store.activePDFStatusPath = rawFile.path
            store.activePDFStatusText = value
        }
        .onChange(of: isSurfaceActive) { _, active in
            if active {
                store.activePDFStatusPath = rawFile.path
                store.activePDFStatusText = statusText
            }
        }
        .onDisappear {
            saveTask?.cancel()
            if store.activePDFStatusPath == rawFile.path {
                store.activePDFStatusPath = ""
                store.activePDFStatusText = ""
            }
        }
        #if os(iOS)
        .fileImporter(isPresented: $isImportingImage, allowedContentTypes: [.image], allowsMultipleSelection: false) { result in
            switch result {
            case let .success(urls):
                guard let url = urls.first else { return }
                importAnnotationImage(from: url)
            case .failure:
                statusText = "Image import failed"
            }
        }
        .sheet(item: $exportedPDFShare) { item in
            PDFShareSheet(urls: item.urls)
        }
        .sheet(isPresented: $isExportOptionsPresented) {
            PDFExportOptionsView(
                pageScope: exportPageScope,
                currentPageNumber: currentPageIndex + 1,
                pageCount: exportPageCount,
                exportFormat: $exportFormat,
                includeAnnotations: $exportIncludesAnnotations,
                pageRange: $exportPageRange,
                isExporting: isExportingPDF,
                onExport: {
                    isExportOptionsPresented = false
                    switch exportFormat {
                    case .pdf:
                        exportPDF(includeAnnotations: exportIncludesAnnotations)
                    case .editableCodmes:
                        exportPDFWithCodmesState()
                    }
                }
            )
            .presentationDetents([.height(exportPageScope == .pageSelection ? 390 : 340), .medium])
        }
        .fileImporter(isPresented: $isImportingPDFPages, allowedContentTypes: [.pdf, .json], allowsMultipleSelection: true) { result in
            switch result {
            case let .success(urls):
                importPDFPages(from: urls)
            case .failure:
                statusText = "PDF import failed"
            }
        }
        #endif
    }

    private var readingStateSaver: (PDFReadingState) -> Void {
        let path = rawFile.path, scope = store.profileStorageScope
        return { store.savePDFReadingState($0, path: path, scope: scope) }
    }

    private var header: some View {
        GeometryReader { proxy in
            let compact = proxy.size.width < 600

            ZStack {
                HStack(spacing: compact ? 4 : 8) {
                    pageBrowserButton
                    pdfModePicker(compact: compact)

                    Spacer(minLength: 8)

                    documentActionControls(compact: compact)
                }

                centeredToolControls(compact: compact)
            }
            .padding(.horizontal, compact ? 8 : 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: 42)
        .background(.quaternary.opacity(0.08))
    }

    private var pageBrowserButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.25)) {
                isPageBrowserPresented.toggle()
            }
        } label: {
            Image(systemName: "rectangle.grid.2x2")
                .foregroundStyle(isPageBrowserPresented ? Color.accentColor : Color.secondary)
                .frame(width: 28, height: 28)
                .background(isPageBrowserPresented ? Color.accentColor.opacity(0.14) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Page thumbnails")
    }

    @ViewBuilder
    private func pdfModePicker(compact: Bool) -> some View {
        #if os(iOS)
            Picker("PDF mode", selection: $isWritingMode) {
                Image(systemName: "hand.draw").tag(false)
                Image(systemName: "pencil.tip").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(width: compact ? 72 : 92)
            .accessibilityLabel("PDF mode")
        #elseif os(macOS)
            Picker("PDF mode", selection: $isMacWritingMode) {
                Image(systemName: "hand.draw").tag(false)
                Image(systemName: "pencil.tip").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(width: 92)
            .accessibilityLabel("PDF mode")
        #endif
    }

    @ViewBuilder
    private func centeredToolControls(compact: Bool) -> some View {
        #if os(iOS)
            HStack(spacing: compact ? 0 : 4) {
                pdfToolButton(.pen)
                pdfToolButton(.eraser)
                pdfToolButton(.lasso)

                Button {
                    isWritingMode = true
                    markupTool = .text
                    toolOptions = nil
                    didConfirmCurrentTool = false
                } label: {
                    Image(systemName: "textformat")
                        .font(.system(size: 15, weight: markupTool == .text ? .semibold : .regular))
                        .foregroundStyle(markupTool == .text ? Color.accentColor : Color.secondary)
                        .frame(width: 28, height: 28)
                        .background(markupTool == .text ? Color.accentColor.opacity(0.14) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Place text box")

                Button {
                    isWritingMode = true
                    markupTool = .lasso
                    isImportingImage = true
                } label: {
                    Image(systemName: "photo.badge.plus")
                        .foregroundStyle(Color.secondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Attach image")
            }
            .popover(item: $toolOptions) { selectedTool in
                PDFToolOptionsPopover(
                    tool: selectedTool,
                    penColorHex: $penColorHex,
                    penWidth: $penWidth,
                    eraserWidth: $eraserWidth
                )
                .frame(width: 260)
                .padding(14)
            }
        #elseif os(macOS)
            HStack(spacing: 4) {
                macPDFToolButton(.pen)
                macPDFToolButton(.eraser)
                macPDFToolButton(.lasso)
                macPDFToolButton(.text)
            }
            .popover(item: $macToolOptions) { selectedTool in
                MacPDFToolOptionsPopover(
                    tool: selectedTool,
                    penColorHex: $macPenColorHex,
                    penWidth: $macPenWidth,
                    eraserWidth: $macEraserWidth
                )
                .frame(width: 260)
                .padding(14)
            }
        #endif
    }

    @ViewBuilder
    private func documentActionControls(compact: Bool) -> some View {
        #if os(iOS)
        HStack(spacing: compact ? 0 : 8) {
            Button {
                isWritingMode = true
                markupTool = .lasso
                isImportingPDFPages = true
            } label: {
                Image(systemName: "doc.badge.plus")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .disabled(isExportingPDF)
            .accessibilityLabel("Insert PDF pages after current page")

            Button {
                exportPageCount = streamSession?.metadata.pageCount ?? PDFDocument(url: rawFile.url)?.pageCount ?? 0
                isExportScopePresented = true
            } label: {
                Image(systemName: isExportingPDF ? "hourglass" : "square.and.arrow.up")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .disabled(isExportingPDF)
            .accessibilityLabel("Export PDF")
            .popover(isPresented: $isExportScopePresented, attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
                PDFExportPageScopeView(
                    currentPageNumber: currentPageIndex + 1,
                    pageCount: exportPageCount,
                    onSelect: prepareExport(scope:)
                )
                .presentationCompactAdaptation(.popover)
            }
        }
        #elseif os(macOS)
        EmptyView()
        #endif
    }

    private var historyControls: some View {
        HStack(spacing: 0) {
            Button {
                undoAnnotationChange()
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .disabled(undoStack.isEmpty)
            .accessibilityLabel("Undo annotation change")

            Divider()
                .frame(height: 20)

            Button {
                redoAnnotationChange()
            } label: {
                Image(systemName: "arrow.uturn.forward")
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .disabled(redoStack.isEmpty)
            .accessibilityLabel("Redo annotation change")
        }
        .padding(2)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.quaternary, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.10), radius: 4, y: 1)
    }

    private var isPDFWritingMode: Bool {
        #if os(iOS)
        isWritingMode
        #elseif os(macOS)
        isMacWritingMode
        #endif
    }

    private func pageBrowserPanel(width: CGFloat) -> some View {
        PDFPageThumbnailBrowser(
            url: rawFile.url,
            streamPath: streamSession?.path,
            streamedPageCount: streamSession?.metadata.pageCount,
            currentPageIndex: currentPageIndex,
            onSelectPage: navigateToPage(_:),
            onClose: {
                withAnimation(.easeInOut(duration: 0.25)) {
                    isPageBrowserPresented = false
                }
            }
        )
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .overlay(alignment: .trailing) {
            Divider()
        }
        .shadow(color: .black.opacity(0.16), radius: 12, x: 4, y: 0)
    }

    private var usesOverlayPageBrowser: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }

    private func pageBrowserWidth(for containerWidth: CGFloat) -> CGFloat {
        if usesOverlayPageBrowser {
            return min(max(containerWidth * 0.84, 280), 360)
        }
        return min(max(containerWidth * 0.34, 320), 360)
    }

    private func pdfCanvasOffset(for containerSize: CGSize) -> CGFloat {
        guard isPageBrowserPresented, !usesOverlayPageBrowser else { return 0 }
        let minimumOffset = (1 - pdfCanvasScale) * containerSize.width / 2
        guard containerSize.width > containerSize.height else { return minimumOffset }

        // In landscape, center the page in the area remaining to the right of the sidebar.
        return pageBrowserWidth(for: containerSize.width) / 2
    }

    private func historyControlsOffset(for containerWidth: CGFloat) -> CGFloat {
        guard isPageBrowserPresented, !usesOverlayPageBrowser else { return 0 }
        return pageBrowserWidth(for: containerWidth)
    }

    private var pdfCanvasScale: CGFloat {
        isPageBrowserPresented && !usesOverlayPageBrowser ? 0.88 : 1
    }

    private func navigateToPage(_ pageIndex: Int) {
        if let streamSession {
            Task {
                await streamSession.preparePage(pageIndex)
                applyPageNavigation(pageIndex)
                streamSession.requestPages(around: pageIndex)
            }
            return
        }
        applyPageNavigation(pageIndex)
    }

    private func applyPageNavigation(_ pageIndex: Int) {
        currentPageIndex = pageIndex
        store.selectedPDFFocus = PDFDocumentFocus(
            path: rawFile.path,
            page: pageIndex + 1,
            bbox: nil
        )
    }

    #if os(iOS)
    private func pdfToolButton(_ tool: PDFMarkupTool) -> some View {
        Button {
            isWritingMode = true
            if (tool == .pen || tool == .eraser), markupTool == tool, didConfirmCurrentTool {
                toolOptions = tool
                didConfirmCurrentTool = false
            } else {
                markupTool = tool
                toolOptions = nil
                didConfirmCurrentTool = tool == .pen || tool == .eraser
            }
        } label: {
            Image(systemName: tool.systemImage)
                .font(.system(size: 15, weight: markupTool == tool ? .semibold : .regular))
                .foregroundStyle(markupTool == tool ? Color.accentColor : Color.secondary)
                .frame(width: 28, height: 28)
                .background(markupTool == tool ? Color.accentColor.opacity(0.14) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tool.label)
    }

    private struct PDFToolOptionsPopover: View {
        let tool: PDFMarkupTool
        @Binding var penColorHex: String
        @Binding var penWidth: Double
        @Binding var eraserWidth: Double

        private let colorChoices = ["#111111", "#E03131", "#1971C2", "#2F9E44", "#F08C00", "#7048E8"]

        var body: some View {
            VStack(alignment: .leading, spacing: 14) {
                Label(tool.label, systemImage: tool.systemImage)
                    .font(.headline)

                if tool == .pen {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Color")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        HStack(spacing: 10) {
                            ForEach(colorChoices, id: \.self) { hex in
                                Button {
                                    penColorHex = hex
                                } label: {
                                    Circle()
                                        .fill(Color(UIColor(hexString: hex)))
                                        .frame(width: 24, height: 24)
                                        .overlay {
                                            Circle()
                                                .stroke(penColorHex == hex ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: penColorHex == hex ? 3 : 1)
                                        }
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Pen color \(hex)")
                            }
                        }
                    }

                    ToolWidthSlider(label: "Width", value: $penWidth, range: 1...12)
                } else {
                    ToolWidthSlider(label: "Width", value: $eraserWidth, range: 6...44)
                }
            }
        }
    }

    private struct PDFLassoOptionsBar: View {
        let selection: PDFLassoSelectionSummary
        let hasTextSelection: Bool
        var onDelete: () -> Void
        var onColor: (String) -> Void
        var onFontSize: (Double) -> Void
        var onEditText: () -> Void

        private let colorChoices = [
            ("Black", "#111111"),
            ("Red", "#E03131"),
            ("Blue", "#1971C2"),
            ("Green", "#2F9E44"),
            ("Orange", "#F08C00"),
            ("Purple", "#7048E8")
        ]

        var body: some View {
            HStack(spacing: 8) {
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete selection")

                Menu {
                    ForEach(colorChoices, id: \.1) { name, hex in
                        Button {
                            onColor(hex)
                        } label: {
                            Label(name, systemImage: "circle.fill")
                                .foregroundStyle(Color(UIColor(hexString: hex)))
                        }
                    }
                } label: {
                    Image(systemName: "paintpalette")
                        .frame(width: 30, height: 30)
                }
                .accessibilityLabel("Selection color")

                if hasTextSelection {
                    Button(action: onEditText) {
                        Image(systemName: "square.and.pencil")
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Edit text")

                    Button {
                        onFontSize(-1)
                    } label: {
                        Image(systemName: "textformat.size.smaller")
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Smaller text")

                    Button {
                        onFontSize(1)
                    } label: {
                        Image(systemName: "textformat.size.larger")
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Larger text")
                }
            }
            .padding(6)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .shadow(radius: 8, y: 2)
        }
    }

    private struct ToolWidthSlider: View {
        let label: String
        @Binding var value: Double
        let range: ClosedRange<Double>

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(value.rounded())) pt")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $value, in: range)
            }
        }
    }
    #endif

    #if os(macOS)
    private func macPDFToolButton(_ tool: MacPDFMarkupTool) -> some View {
        Button {
            isMacWritingMode = true
            if (tool == .pen || tool == .eraser), macMarkupTool == tool, didConfirmCurrentMacTool {
                macToolOptions = tool
            } else {
                macToolOptions = nil
            }
            macMarkupTool = tool
            didConfirmCurrentMacTool = true
        } label: {
            Image(systemName: tool.systemImage)
                .font(.system(size: 15, weight: macMarkupTool == tool ? .semibold : .regular))
                .foregroundStyle(macMarkupTool == tool ? Color.accentColor : Color.secondary)
                .frame(width: 28, height: 28)
                .background(macMarkupTool == tool ? Color.accentColor.opacity(0.14) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tool.label)
    }

    private struct MacPDFToolOptionsPopover: View {
        let tool: MacPDFMarkupTool
        @Binding var penColorHex: String
        @Binding var penWidth: Double
        @Binding var eraserWidth: Double

        private let swatches = ["#111111", "#EF4444", "#F59E0B", "#10B981", "#3B82F6", "#8B5CF6"]

        var body: some View {
            VStack(alignment: .leading, spacing: 14) {
                if tool == .pen {
                    Text("Pen")
                        .font(.headline)
                    HStack(spacing: 10) {
                        ForEach(swatches, id: \.self) { hex in
                            Button {
                                penColorHex = hex
                            } label: {
                                Circle()
                                    .fill(Color(nsColor: NSColor(hexString: hex) ?? .black))
                                    .frame(width: 24, height: 24)
                                    .overlay(
                                        Circle()
                                            .stroke(penColorHex == hex ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: penColorHex == hex ? 3 : 1)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    MacToolWidthSlider(label: "Width", value: $penWidth, range: 1...12)
                } else if tool == .eraser {
                    Text("Eraser")
                        .font(.headline)
                    MacToolWidthSlider(label: "Width", value: $eraserWidth, range: 6...44)
                }
            }
        }
    }

    private struct MacToolWidthSlider: View {
        let label: String
        @Binding var value: Double
        let range: ClosedRange<Double>

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(value.rounded())) pt")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $value, in: range)
            }
        }
    }

    private struct MacPDFLassoOptionsBar: View {
        let hasTextSelection: Bool
        var onDelete: () -> Void
        var onColor: (String) -> Void
        var onFontSize: (Double) -> Void
        var onEditText: () -> Void

        private let colorChoices = [
            ("Black", "#111111"),
            ("Red", "#E03131"),
            ("Blue", "#1971C2"),
            ("Green", "#2F9E44"),
            ("Orange", "#F08C00"),
            ("Purple", "#7048E8")
        ]

        var body: some View {
            HStack(spacing: 8) {
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)

                Menu {
                    ForEach(colorChoices, id: \.1) { name, hex in
                        Button {
                            onColor(hex)
                        } label: {
                            Label(name, systemImage: "circle.fill")
                                .foregroundStyle(Color(nsColor: NSColor(hexString: hex) ?? .black))
                        }
                    }
                } label: {
                    Image(systemName: "paintpalette")
                        .frame(width: 30, height: 30)
                }

                if hasTextSelection {
                    Button(action: onEditText) {
                        Image(systemName: "square.and.pencil")
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)

                    Button {
                        onFontSize(-1)
                    } label: {
                        Image(systemName: "textformat.size.smaller")
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)

                    Button {
                        onFontSize(1)
                    } label: {
                        Image(systemName: "textformat.size.larger")
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .shadow(radius: 8, y: 2)
        }
    }

    private func appendMacInkStroke(pageIndex: Int, stroke: CodmesInkStroke) {
        var next = annotations ?? emptyAnnotationDocument()
        if let index = next.pages.firstIndex(where: { $0.pageIndex == pageIndex }) {
            var strokes = next.pages[index].inkStrokes ?? []
            strokes.append(stroke)
            next.pages[index].inkStrokes = strokes
        } else {
            next.pages.append(PDFAnnotationPage(pageIndex: pageIndex, inkDataBase64: nil, inkStrokes: [stroke], objects: []))
            next.pages.sort { $0.pageIndex < $1.pageIndex }
        }
        commitAnnotationDocument(next)
    }

    private func replaceMacInkStrokes(pageIndex: Int, strokes: [CodmesInkStroke]) {
        var next = annotations ?? emptyAnnotationDocument()
        if let index = next.pages.firstIndex(where: { $0.pageIndex == pageIndex }) {
            next.pages[index].inkStrokes = strokes
        } else {
            next.pages.append(PDFAnnotationPage(pageIndex: pageIndex, inkDataBase64: nil, inkStrokes: strokes, objects: []))
            next.pages.sort { $0.pageIndex < $1.pageIndex }
        }
        commitAnnotationDocument(next)
    }

    private func hasMacTextObject(in selection: PDFLassoSelectionSummary) -> Bool {
        annotations?.noteObjects(pageIndex: selection.pageIndex).contains {
            selection.objectIds.contains($0.id) && $0.type.lowercased().contains("text")
        } == true
    }

    private func editMacLassoText(_ selection: PDFLassoSelectionSummary) {
        guard let object = annotations?.noteObjects(pageIndex: selection.pageIndex).first(where: {
            selection.objectIds.contains($0.id) && $0.type.lowercased().contains("text")
        }) else { return }
        macSelectedObjectId = object.id
        macMarkupTool = .text
        isMacWritingMode = true
        macTextEditRequest += 1
    }

    private func deleteMacLassoSelection(_ selection: PDFLassoSelectionSummary) {
        var next = annotations ?? emptyAnnotationDocument()
        if let pageOffset = next.pages.firstIndex(where: { $0.pageIndex == selection.pageIndex }) {
            if var strokes = next.pages[pageOffset].inkStrokes {
                strokes.removeAll { selection.strokeIds.contains($0.id) }
                next.pages[pageOffset].inkStrokes = strokes
            }
            if var objects = next.pages[pageOffset].objects {
                objects.removeAll { selection.objectIds.contains($0.id) }
                next.pages[pageOffset].objects = objects
            }
            let selectedIds = selection.strokeIds.union(selection.objectIds)
            next.pages[pageOffset].elements = next.pages[pageOffset].elements?.filter { !selectedIds.contains($0.id) }
        }
        next.objects.removeAll { selection.objectIds.contains($0.id) }
        let selectedIds = selection.strokeIds.union(selection.objectIds)
        next.elements = next.elements?.filter { !selectedIds.contains($0.id) }
        if let macSelectedObjectId, selection.objectIds.contains(macSelectedObjectId) {
            self.macSelectedObjectId = nil
        }
        macLassoSelection = nil
        commitAnnotationDocument(next)
    }

    private func recolorMacLassoSelection(_ selection: PDFLassoSelectionSummary, colorHex: String) {
        var next = annotations ?? emptyAnnotationDocument()
        if let pageOffset = next.pages.firstIndex(where: { $0.pageIndex == selection.pageIndex }) {
            if var strokes = next.pages[pageOffset].inkStrokes {
                for index in strokes.indices where selection.strokeIds.contains(strokes[index].id) {
                    strokes[index].color = colorHex
                }
                next.pages[pageOffset].inkStrokes = strokes
            }
            if var objects = next.pages[pageOffset].objects {
                for index in objects.indices where selection.objectIds.contains(objects[index].id) {
                    var metadata = objects[index].metadata ?? [:]
                    metadata["color"] = colorHex
                    objects[index].metadata = metadata
                }
                next.pages[pageOffset].objects = objects
            }
        }
        for index in next.objects.indices where selection.objectIds.contains(next.objects[index].id) {
            var metadata = next.objects[index].metadata ?? [:]
            metadata["color"] = colorHex
            next.objects[index].metadata = metadata
        }
        commitAnnotationDocument(next)
    }

    private func adjustMacLassoTextSize(_ selection: PDFLassoSelectionSummary, delta: Double) {
        var next = annotations ?? emptyAnnotationDocument()
        func adjust(_ object: inout PDFAnnotationObject) {
            guard selection.objectIds.contains(object.id), object.type.lowercased().contains("text") else { return }
            var metadata = object.metadata ?? [:]
            let current = Double(metadata["fontSize"] ?? "16") ?? 16
            metadata["fontSize"] = String(Int(max(8, min(72, current + delta))))
            object.metadata = metadata
        }
        for pageOffset in next.pages.indices where next.pages[pageOffset].pageIndex == selection.pageIndex {
            if var objects = next.pages[pageOffset].objects {
                for index in objects.indices {
                    adjust(&objects[index])
                }
                next.pages[pageOffset].objects = objects
            }
        }
        for index in next.objects.indices {
            adjust(&next.objects[index])
        }
        commitAnnotationDocument(next)
    }

    private func updateMacAnnotationObject(_ object: PDFAnnotationObject) {
        guard let pageIndex = object.pageIndex else { return }
        var next = annotations ?? emptyAnnotationDocument()
        if let pageOffset = next.pages.firstIndex(where: { $0.pageIndex == pageIndex }) {
            var objects = next.pages[pageOffset].objects ?? []
            if let objectOffset = objects.firstIndex(where: { $0.id == object.id }) {
                objects[objectOffset] = object
            } else {
                objects.append(object)
            }
            next.pages[pageOffset].objects = objects
        } else {
            next.pages.append(PDFAnnotationPage(pageIndex: pageIndex, inkDataBase64: nil, inkStrokes: nil, objects: [object]))
            next.pages.sort { $0.pageIndex < $1.pageIndex }
        }
        macSelectedObjectId = object.id
        commitAnnotationDocument(next)
    }

    private func deleteMacAnnotationObject(_ object: PDFAnnotationObject) {
        guard let pageIndex = object.pageIndex else { return }
        var next = annotations ?? emptyAnnotationDocument()
        if let pageOffset = next.pages.firstIndex(where: { $0.pageIndex == pageIndex }) {
            var objects = next.pages[pageOffset].objects ?? []
            objects.removeAll { $0.id == object.id }
            next.pages[pageOffset].objects = objects
            next.pages[pageOffset].elements = next.pages[pageOffset].elements?.filter { $0.id != object.id }
        }
        next.objects.removeAll { $0.id == object.id }
        next.elements = next.elements?.filter { $0.id != object.id }
        if macSelectedObjectId == object.id {
            macSelectedObjectId = nil
        }
        commitAnnotationDocument(next)
    }

    #endif

    private func loadAnnotations() async {
        do {
            var loaded = try store.localAnnotations(path: rawFile.path)
            loaded.syncNoteElementsFromLegacy()
            if annotations.map({ annotationDocumentsEqual($0, loaded) }) != true {
                undoStack = []
                redoStack = []
            }
            annotations = loaded
            statusText = annotations?.pages.isEmpty == false ? "Annotations loaded" : "Ready"
        } catch {
            annotations = PDFAnnotationDocument(
                schemaVersion: 2,
                documentPath: rawFile.path,
                updatedAt: nil,
                pages: [],
                objects: []
            )
            undoStack = []
            redoStack = []
            statusText = "Annotation sync unavailable"
        }
    }

    #if os(iOS)
    private func updatePageInk(pageIndex: Int, data: Data, drawing: PKDrawing, canvasSize: CGSize) {
        var next = annotations ?? emptyAnnotationDocument()
        let encoded = data.base64EncodedString()
        let oldPage = next.pages.first(where: { $0.pageIndex == pageIndex })
        let previousDrawing = oldPage?.inkDataBase64.flatMap { Data(base64Encoded: $0) }.flatMap { try? PKDrawing(data: $0) }
        let strokes = codmesStrokes(from: drawing, canvasSize: canvasSize, previous: oldPage?.inkStrokes ?? [], previousDrawing: previousDrawing)
        if let index = next.pages.firstIndex(where: { $0.pageIndex == pageIndex }) {
            next.pages[index].inkDataBase64 = encoded
            next.pages[index].inkStrokes = strokes
        } else {
            next.pages.append(PDFAnnotationPage(pageIndex: pageIndex, inkDataBase64: encoded, inkStrokes: strokes, objects: []))
            next.pages.sort { $0.pageIndex < $1.pageIndex }
        }
        commitAnnotationDocument(next)
    }

    private func appendInkStroke(pageIndex: Int, stroke: CodmesInkStroke) {
        var next = annotations ?? emptyAnnotationDocument()
        if let index = next.pages.firstIndex(where: { $0.pageIndex == pageIndex }) {
            var strokes = next.pages[index].inkStrokes ?? []
            strokes.append(stroke)
            next.pages[index].inkStrokes = strokes
        } else {
            next.pages.append(PDFAnnotationPage(pageIndex: pageIndex, inkDataBase64: nil, inkStrokes: [stroke], objects: []))
            next.pages.sort { $0.pageIndex < $1.pageIndex }
        }
        commitAnnotationDocument(next)
    }

    private func replaceInkStrokes(pageIndex: Int, strokes: [CodmesInkStroke]) {
        var next = annotations ?? emptyAnnotationDocument()
        if let index = next.pages.firstIndex(where: { $0.pageIndex == pageIndex }) {
            next.pages[index].inkStrokes = strokes
        } else {
            next.pages.append(PDFAnnotationPage(pageIndex: pageIndex, inkDataBase64: nil, inkStrokes: strokes, objects: []))
            next.pages.sort { $0.pageIndex < $1.pageIndex }
        }
        commitAnnotationDocument(next)
    }

    private func hasTextObject(in selection: PDFLassoSelectionSummary) -> Bool {
        annotations?.noteObjects(pageIndex: selection.pageIndex).contains {
            selection.objectIds.contains($0.id) && $0.type.lowercased().contains("text")
        } == true
    }

    private func editLassoText(_ selection: PDFLassoSelectionSummary) {
        guard let object = annotations?.noteObjects(pageIndex: selection.pageIndex).first(where: {
            selection.objectIds.contains($0.id) && $0.type.lowercased().contains("text")
        }) else { return }
        selectedObjectId = object.id
        markupTool = .text
        isWritingMode = true
        textEditRequest += 1
    }

    private func deleteLassoSelection(_ selection: PDFLassoSelectionSummary) {
        var next = annotations ?? emptyAnnotationDocument()
        if let pageOffset = next.pages.firstIndex(where: { $0.pageIndex == selection.pageIndex }) {
            if var strokes = next.pages[pageOffset].inkStrokes {
                strokes.removeAll { selection.strokeIds.contains($0.id) }
                next.pages[pageOffset].inkStrokes = strokes
            }
            if var objects = next.pages[pageOffset].objects {
                objects.removeAll { selection.objectIds.contains($0.id) }
                next.pages[pageOffset].objects = objects
            }
            let selectedIds = selection.strokeIds.union(selection.objectIds)
            next.pages[pageOffset].elements = next.pages[pageOffset].elements?.filter { !selectedIds.contains($0.id) }
        }
        next.objects.removeAll { selection.objectIds.contains($0.id) }
        let selectedIds = selection.strokeIds.union(selection.objectIds)
        next.elements = next.elements?.filter { !selectedIds.contains($0.id) }
        if let selectedObjectId, selection.objectIds.contains(selectedObjectId) {
            self.selectedObjectId = nil
        }
        lassoSelection = nil
        commitAnnotationDocument(next)
    }

    private func recolorLassoSelection(_ selection: PDFLassoSelectionSummary, colorHex: String) {
        var next = annotations ?? emptyAnnotationDocument()
        if let pageOffset = next.pages.firstIndex(where: { $0.pageIndex == selection.pageIndex }) {
            if var strokes = next.pages[pageOffset].inkStrokes {
                for index in strokes.indices where selection.strokeIds.contains(strokes[index].id) {
                    strokes[index].color = colorHex
                }
                next.pages[pageOffset].inkStrokes = strokes
            }
            if var objects = next.pages[pageOffset].objects {
                for index in objects.indices where selection.objectIds.contains(objects[index].id) {
                    var metadata = objects[index].metadata ?? [:]
                    metadata["color"] = colorHex
                    objects[index].metadata = metadata
                }
                next.pages[pageOffset].objects = objects
            }
            next.pages[pageOffset].elements = next.pages[pageOffset].elements?.map { element in
                guard selection.strokeIds.contains(element.id) || selection.objectIds.contains(element.id) else { return element }
                var copy = element
                if var stroke = copy.stroke {
                    stroke.color = colorHex
                    copy = copy.replacing(stroke: stroke)
                }
                var style = copy.style ?? CodmesNoteStyle(strokeColor: nil, fillColor: nil, lineWidth: nil, opacity: nil, fontSize: nil)
                style.strokeColor = colorHex
                copy.style = style
                var metadata = copy.metadata ?? [:]
                metadata["color"] = colorHex
                copy.metadata = metadata
                return copy
            }
        }
        for index in next.objects.indices where selection.objectIds.contains(next.objects[index].id) {
            var metadata = next.objects[index].metadata ?? [:]
            metadata["color"] = colorHex
            next.objects[index].metadata = metadata
        }
        next.elements = next.elements?.map { element in
            guard selection.strokeIds.contains(element.id) || selection.objectIds.contains(element.id) else { return element }
            var copy = element
            if var stroke = copy.stroke {
                stroke.color = colorHex
                copy = copy.replacing(stroke: stroke)
            }
            var style = copy.style ?? CodmesNoteStyle(strokeColor: nil, fillColor: nil, lineWidth: nil, opacity: nil, fontSize: nil)
            style.strokeColor = colorHex
            copy.style = style
            var metadata = copy.metadata ?? [:]
            metadata["color"] = colorHex
            copy.metadata = metadata
            return copy
        }
        commitAnnotationDocument(next)
    }

    private func adjustLassoTextSize(_ selection: PDFLassoSelectionSummary, delta: Double) {
        var next = annotations ?? emptyAnnotationDocument()
        func adjust(_ object: inout PDFAnnotationObject) {
            guard selection.objectIds.contains(object.id), object.type.lowercased().contains("text") else { return }
            var metadata = object.metadata ?? [:]
            let current = Double(metadata["fontSize"] ?? "16") ?? 16
            metadata["fontSize"] = String(Int(max(8, min(72, current + delta))))
            object.metadata = metadata
        }
        for pageOffset in next.pages.indices where next.pages[pageOffset].pageIndex == selection.pageIndex {
            if var objects = next.pages[pageOffset].objects {
                for index in objects.indices {
                    adjust(&objects[index])
                }
                next.pages[pageOffset].objects = objects
            }
            next.pages[pageOffset].elements = next.pages[pageOffset].elements?.map { element in
                guard selection.objectIds.contains(element.id), element.type.lowercased().contains("text") else { return element }
                var copy = element
                let current = copy.style?.fontSize ?? Double(copy.metadata?["fontSize"] ?? "16") ?? 16
                var style = copy.style ?? CodmesNoteStyle(strokeColor: nil, fillColor: nil, lineWidth: nil, opacity: nil, fontSize: nil)
                style.fontSize = max(8, min(72, current + delta))
                copy.style = style
                var metadata = copy.metadata ?? [:]
                metadata["fontSize"] = String(Int(style.fontSize ?? 16))
                copy.metadata = metadata
                return copy
            }
        }
        for index in next.objects.indices {
            adjust(&next.objects[index])
        }
        next.elements = next.elements?.map { element in
            guard selection.objectIds.contains(element.id), element.type.lowercased().contains("text") else { return element }
            var copy = element
            let current = copy.style?.fontSize ?? Double(copy.metadata?["fontSize"] ?? "16") ?? 16
            var style = copy.style ?? CodmesNoteStyle(strokeColor: nil, fillColor: nil, lineWidth: nil, opacity: nil, fontSize: nil)
            style.fontSize = max(8, min(72, current + delta))
            copy.style = style
            var metadata = copy.metadata ?? [:]
            metadata["fontSize"] = String(Int(style.fontSize ?? 16))
            copy.metadata = metadata
            return copy
        }
        commitAnnotationDocument(next)
    }

    private func importAnnotationImage(from url: URL) {
        Task {
            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped { url.stopAccessingSecurityScopedResource() }
            }
            do {
                let data = try Data(contentsOf: url)
                let mime = imageMime(for: url)
                let object = PDFAnnotationObject(
                    id: UUID().uuidString,
                    type: "image",
                    pageIndex: currentPageIndex,
                    bbox: AnnotationBoundingBox(x: 0.2, y: 0.2, width: 0.42, height: 0.24, normalized: nil),
                    text: nil,
                    dataBase64: data.base64EncodedString(),
                    metadata: ["mime": mime, "fileName": url.lastPathComponent]
                )
                await MainActor.run {
                    updateAnnotationObject(object)
                    selectedObjectId = object.id
                    markupTool = .lasso
                    isWritingMode = true
                    statusText = "Image attached"
                }
            } catch {
                await MainActor.run { statusText = "Image import failed" }
            }
        }
    }

    private func imageMime(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": "image/jpeg"
        case "webp": "image/webp"
        case "gif": "image/gif"
        case "bmp": "image/bmp"
        case "tif", "tiff": "image/tiff"
        default: "image/png"
        }
    }

    private func updateAnnotationObject(_ object: PDFAnnotationObject) {
        guard let pageIndex = object.pageIndex else { return }
        var next = annotations ?? emptyAnnotationDocument()
        if let pageOffset = next.pages.firstIndex(where: { $0.pageIndex == pageIndex }) {
            var objects = next.pages[pageOffset].objects ?? []
            if let objectOffset = objects.firstIndex(where: { $0.id == object.id }) {
                objects[objectOffset] = object
            } else {
                objects.append(object)
            }
            next.pages[pageOffset].objects = objects
        } else {
            next.pages.append(PDFAnnotationPage(pageIndex: pageIndex, inkDataBase64: nil, inkStrokes: nil, objects: [object]))
            next.pages.sort { $0.pageIndex < $1.pageIndex }
        }
        commitAnnotationDocument(next)
    }

    private func deleteAnnotationObject(_ object: PDFAnnotationObject) {
        guard let pageIndex = object.pageIndex else { return }
        var next = annotations ?? emptyAnnotationDocument()
        if let pageOffset = next.pages.firstIndex(where: { $0.pageIndex == pageIndex }) {
            var objects = next.pages[pageOffset].objects ?? []
            objects.removeAll { $0.id == object.id }
            next.pages[pageOffset].objects = objects
            next.pages[pageOffset].elements = next.pages[pageOffset].elements?.filter { $0.id != object.id }
        }
        next.objects.removeAll { $0.id == object.id }
        next.elements = next.elements?.filter { $0.id != object.id }
        if selectedObjectId == object.id {
            selectedObjectId = nil
        }
        commitAnnotationDocument(next)
    }

    private func exportPDF(includeAnnotations: Bool) {
        isExportingPDF = true
        statusText = "Exporting..."
        let annotations = annotations ?? emptyAnnotationDocument()
        let outputURL = exportDirectory()
            .appendingPathComponent(exportFileName(includeAnnotations: includeAnnotations))
        let requestedPages = selectedPageIndexes()

        Task {
            do {
                let sourceURL = try await originalPDFURLForOperation()
                try await Task.detached {
                    try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    guard let sourceDocument = PDFDocument(url: sourceURL) else { throw CocoaError(.fileNoSuchFile) }
                    let pages = normalizedPageIndexes(requestedPages, pageCount: sourceDocument.pageCount)
                    if includeAnnotations {
                        let exportDocument = try copyPDFDocument(sourceDocument, pageIndexes: pages)
                        let exportAnnotations = annotations.sliced(to: pages, documentPath: outputURL.lastPathComponent)
                        try renderFlattenedPDF(document: exportDocument, annotations: exportAnnotations, to: outputURL)
                    } else if requestedPages.isEmpty {
                        try replaceFileCopy(from: sourceURL, to: outputURL)
                    } else {
                        let exportDocument = try copyPDFDocument(sourceDocument, pageIndexes: pages)
                        guard exportDocument.write(to: outputURL) else { throw CocoaError(.fileWriteUnknown) }
                    }
                }.value
                isExportingPDF = false
                statusText = "Export ready"
                exportedPDFShare = PDFExportShare(urls: [outputURL])
            } catch {
                isExportingPDF = false
                statusText = "Export failed"
            }
        }
    }

    private func prepareExport(scope: PDFExportPageScope) {
        exportPageScope = scope
        switch scope {
        case .currentPage:
            exportPageRange = "\(currentPageIndex + 1)"
        case .pageSelection, .allPages:
            exportPageRange = ""
        }
        isExportScopePresented = false

        // Let the anchored popover finish dismissing before presenting the modal sheet.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            isExportOptionsPresented = true
        }
    }

    private func exportPDFWithCodmesState() {
        isExportingPDF = true
        statusText = "Exporting..."
        let annotations = annotations ?? emptyAnnotationDocument()
        let requestedPages = selectedPageIndexes()
        let packageBaseName = "\(basePDFName())\(requestedPages.isEmpty ? "" : "-pages")"
        let outputDirectory = exportDirectory()

        Task {
            do {
                let sourceURL = try await originalPDFURLForOperation()
                let (pdfData, annotationData) = try await Task.detached { () -> (Data, Data) in
                    guard let sourceDocument = PDFDocument(url: sourceURL) else { throw CocoaError(.fileNoSuchFile) }
                    let pages = normalizedPageIndexes(requestedPages, pageCount: sourceDocument.pageCount)
                    let exportDocument = try copyPDFDocument(sourceDocument, pageIndexes: pages)
                    guard let pdfData = exportDocument.dataRepresentation() else { throw CocoaError(.fileWriteUnknown) }
                    let exportAnnotations = annotations.sliced(to: pages, documentPath: "\(packageBaseName).pdf")
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    return (pdfData, try encoder.encode(exportAnnotations))
                }.value
                let packageData = try await Task.detached {
                    try CodmesPDFArchive.create(pdf: pdfData, annotations: JSONDecoder().decode(PDFAnnotationDocument.self, from: annotationData), title: packageBaseName)
                }.value
                let outputURL = outputDirectory.appendingPathComponent("\(packageBaseName).codmespdf")
                try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try packageData.write(to: outputURL, options: .atomic)
                isExportingPDF = false
                statusText = "Editable Codmes PDF ready"
                exportedPDFShare = PDFExportShare(urls: [outputURL])
            } catch {
                isExportingPDF = false
                statusText = "Export failed: \(error.localizedDescription)"
            }
        }
    }

    private func exportDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("CodmesExports", isDirectory: true)
    }

    private func basePDFName() -> String {
        let name = (rawFile.name as NSString).deletingPathExtension
        return name.isEmpty
            ? rawFile.name.replacingOccurrences(of: ".pdf", with: "", options: [.caseInsensitive])
            : name
    }

    private func exportFileName(includeAnnotations: Bool) -> String {
        let hasRange = !selectedPageIndexes().isEmpty
        if includeAnnotations {
            return "\(basePDFName())\(hasRange ? "-pages" : "")-annotated.pdf"
        }
        return hasRange ? "\(basePDFName())-pages.pdf" : rawFile.name
    }

    private func selectedPageIndexes() -> [Int] {
        parsePDFPageRange(exportPageRange)
    }

    private func originalPDFURLForOperation() async throws -> URL {
        guard streamSession != nil else { return rawFile.url }
        guard let api = store.api else { throw WorkspaceAPIError.invalidURL }
        return try await api.downloadRawFile(path: rawFile.path, name: rawFile.name)
    }

    private func importPDFPages(from urls: [URL]) {
        let api = store.api
        let scoped = urls.map { ($0, $0.startAccessingSecurityScopedResource()) }
        defer {
            for (url, didAccess) in scoped where didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }
        guard let pdfURL = urls.first(where: { $0.pathExtension.lowercased() == "pdf" }) else {
            statusText = "Select a PDF file."
            return
        }
        let stateURL = urls.first(where: { $0.lastPathComponent.lowercased().hasSuffix(".codmes.json") })
        isExportingPDF = true
        statusText = "Inserting PDF..."
        let existingAnnotations = annotations ?? emptyAnnotationDocument()
        let targetPath = rawFile.path
        let fallbackSourceURL = rawFile.url
        let requiresOriginalDownload = streamSession != nil
        let sourceName = rawFile.name
        let insertAfter = currentPageIndex
        Task.detached {
            do {
                let sourceURL: URL
                if requiresOriginalDownload {
                    guard let api else { throw WorkspaceAPIError.invalidURL }
                    sourceURL = try await api.downloadRawFile(path: targetPath, name: sourceName)
                } else { sourceURL = fallbackSourceURL }
                guard let baseDocument = PDFDocument(url: sourceURL),
                      let incomingDocument = PDFDocument(url: pdfURL) else {
                    throw CocoaError(.fileNoSuchFile)
                }
                let insertAt = min(max(insertAfter + 1, 0), baseDocument.pageCount)
                for offset in 0..<incomingDocument.pageCount {
                    guard let page = incomingDocument.page(at: offset)?.copy() as? PDFPage else { continue }
                    baseDocument.insert(page, at: insertAt + offset)
                }
                let outputURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("CodmesPDFMerge-\(UUID().uuidString).pdf")
                guard baseDocument.write(to: outputURL) else { throw CocoaError(.fileWriteUnknown) }
                let mergedData = try Data(contentsOf: outputURL)
                let importedAnnotations = try stateURL.map { url -> PDFAnnotationDocument in
                    let data = try Data(contentsOf: url)
                    return try JSONDecoder().decode(PDFAnnotationDocument.self, from: data)
                }
                let mergedAnnotations = existingAnnotations.inserting(
                    importedAnnotations,
                    at: insertAt,
                    insertedPageCount: incomingDocument.pageCount,
                    documentPath: targetPath
                )
                try? FileManager.default.removeItem(at: outputURL)
                try await MainActor.run {
                    try store.saveLocalPDF(path: targetPath, pdf: mergedData, annotations: mergedAnnotations)
                    annotations = mergedAnnotations
                    isExportingPDF = false
                    statusText = importedAnnotations == nil ? "PDF inserted and reindexed" : "PDF + Codmes state inserted"
                }
            } catch {
                await MainActor.run {
                    isExportingPDF = false
                    statusText = "PDF insert failed"
                }
            }
        }
    }
    #endif

    private func commitAnnotationDocument(_ document: PDFAnnotationDocument, registerUndo: Bool = true) {
        var synced = document
        synced.syncNoteElementsFromLegacy()
        if registerUndo,
           let current = annotations?.syncedNoteElementsFromLegacy(),
           !annotationDocumentsEqual(current, synced) {
            undoStack.append(current)
            redoStack = []
            trimUndoHistory()
        }
        annotations = synced
        scheduleSave(synced)
    }

    private func undoAnnotationChange() {
        guard let current = annotations?.syncedNoteElementsFromLegacy(),
              let previous = undoStack.popLast() else { return }
        redoStack.append(current)
        trimUndoHistory()
        clearCurrentSelectionState()
        commitAnnotationDocument(previous, registerUndo: false)
        statusText = "Undone"
    }

    private func redoAnnotationChange() {
        guard let current = annotations?.syncedNoteElementsFromLegacy(),
              let next = redoStack.popLast() else { return }
        undoStack.append(current)
        trimUndoHistory()
        clearCurrentSelectionState()
        commitAnnotationDocument(next, registerUndo: false)
        statusText = "Redone"
    }

    private func trimUndoHistory() {
        while undoStack.count + redoStack.count > 80 || (undoStack + redoStack).reduce(0, { $0 + ((try? JSONEncoder().encode($1).count) ?? 0) }) > 8 * 1024 * 1024 {
            if !undoStack.isEmpty { undoStack.removeFirst() } else if !redoStack.isEmpty { redoStack.removeFirst() } else { break }
        }
    }

    private func clearCurrentSelectionState() {
        #if os(iOS)
        selectedObjectId = nil
        lassoSelection = nil
        #endif
        #if os(macOS)
        macSelectedObjectId = nil
        macLassoSelection = nil
        #endif
    }

    private func annotationDocumentsEqual(_ lhs: PDFAnnotationDocument, _ rhs: PDFAnnotationDocument) -> Bool {
        lhs.editorContentMatches(rhs)
    }

    private func emptyAnnotationDocument() -> PDFAnnotationDocument {
        PDFAnnotationDocument(
            schemaVersion: 2,
            documentPath: rawFile.path,
            updatedAt: nil,
            pages: [],
            objects: []
        )
    }

    private func scheduleSave(_ document: PDFAnnotationDocument) {
        saveTask?.cancel()
        // Persist before navigation or app termination; only network sync is debounced.
        do {
            _ = try store.saveLocalAnnotations(path: rawFile.path, annotations: document.syncedNoteElementsFromLegacy())
            statusText = "로컬에 저장됨"
        } catch {
            statusText = "로컬 저장 실패: \(error.localizedDescription)"
        }
    }

    private func saveAnnotations(_ document: PDFAnnotationDocument) async {
        do {
            let saved = try store.saveLocalAnnotations(path: rawFile.path, annotations: document.syncedNoteElementsFromLegacy())
            guard !Task.isCancelled else { return }
            annotations = saved.syncedNoteElementsFromLegacy()
            statusText = store.isWorkspaceConnected ? "로컬에 저장됨 · 동기화 대기" : "로컬에 저장됨"
        } catch {
            guard !Task.isCancelled else { return }
            statusText = "Save failed"
        }
    }
}

private struct PDFPageThumbnailBrowser: View {
    @EnvironmentObject private var store: WorkspaceStore
    let url: URL
    let streamPath: String?
    let streamedPageCount: Int?
    let currentPageIndex: Int
    let onSelectPage: (Int) -> Void
    let onClose: () -> Void
    @State private var pageCount: Int?
    @State private var renderer: PDFPageThumbnailRenderer?
    @State private var didFailToLoad = false
    @State private var remoteRenderer = PDFRemotePageThumbnailRenderer()
    @State private var visiblePageIndexes = Set<Int>()
    @State private var thumbnailImages = [String: PDFPagePreviewImage]()
    @State private var thumbnailFailures = Set<String>()
    @State private var thumbnailLoadingKeys = Set<String>()
    @State private var thumbnailLoadID = ""
    @State private var thumbnailLoadTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.grid.2x2")
                    .foregroundStyle(.secondary)
                Text("Pages")
                    .font(.headline)
                if let pageCount {
                    Text("\(min(currentPageIndex + 1, pageCount)) / \(pageCount)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close page thumbnails")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            if let pageCount {
                GeometryReader { proxy in
                    ScrollViewReader { scrollProxy in
                        ScrollView {
                            LazyVGrid(columns: gridColumns(for: proxy.size.width), spacing: 12) {
                                ForEach(0..<pageCount, id: \.self) { pageIndex in
                                    if let thumbnailKey = thumbnailKey(pageIndex: pageIndex) {
                                        PDFPageThumbnailCell(
                                            image: thumbnailImages[thumbnailKey],
                                            isLoading: thumbnailLoadingKeys.contains(thumbnailKey),
                                            didFail: thumbnailFailures.contains(thumbnailKey),
                                            pageIndex: pageIndex,
                                            isCurrent: pageIndex == currentPageIndex,
                                            onSelect: { onSelectPage(pageIndex) }
                                        )
                                        .id(pageIndex)
                                        .background { thumbnailFrameReader(pageIndex: pageIndex) }
                                    }
                                }
                            }
                            .scrollTargetLayout()
                            .padding(12)
                        }
                        .coordinateSpace(name: PDFPageSidebarCoordinateSpace.name)
                        .modifier(PDFPageSidebarVisibilityModifier { pageIndexes in
                            updateVisiblePageIndexes(pageIndexes)
                        })
                        .onPreferenceChange(PDFPageThumbnailFramePreferenceKey.self) { frames in
                            updateSidebarAnchor(frames: frames, viewportHeight: proxy.size.height)
                        }
                        .task {
                            await Task.yield()
                            scrollProxy.scrollTo(currentPageIndex, anchor: .center)
                        }
                        .onChange(of: currentPageIndex) { _, pageIndex in
                            withAnimation(.easeInOut(duration: 0.18)) {
                                scrollProxy.scrollTo(pageIndex, anchor: .center)
                            }
                        }
                    }
                }
            } else if didFailToLoad {
                ContentUnavailableView("PDF unavailable", systemImage: "doc.questionmark")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(.background)
        .task(id: url) {
            pageCount = nil
            renderer = nil
            didFailToLoad = false
            cancelThumbnailLoading()
            thumbnailImages.removeAll()
            thumbnailFailures.removeAll()
            thumbnailLoadingKeys.removeAll()

            if let streamedPageCount {
                pageCount = streamedPageCount
                visiblePageIndexes = [currentPageIndex]
                scheduleThumbnailLoading(around: currentPageIndex)
                return
            }

            let nextRenderer = PDFPageThumbnailRenderer(url: url)
            guard let count = await nextRenderer.loadPageCount() else {
                didFailToLoad = true
                return
            }
            guard !Task.isCancelled else { return }
            renderer = nextRenderer
            pageCount = count
            visiblePageIndexes = [currentPageIndex]
            scheduleThumbnailLoading(around: currentPageIndex)
        }
        .onDisappear {
            cancelThumbnailLoading()
        }
    }

    private func updateSidebarAnchor(frames: [Int: CGRect], viewportHeight: CGFloat) {
        guard !usesNativeScrollVisibility else { return }
        guard viewportHeight > 0 else { return }
        let centerY = viewportHeight / 2
        let visibleFrames = frames.filter { $0.value.maxY > 0 && $0.value.minY < viewportHeight }
        let nextVisiblePageIndexes = Set(visibleFrames.keys)
        if nextVisiblePageIndexes != visiblePageIndexes {
            visiblePageIndexes = nextVisiblePageIndexes
        }
        let centerPage = visibleFrames
            .min { abs($0.value.midY - centerY) < abs($1.value.midY - centerY) }?
            .key
        if let centerPage {
            scheduleThumbnailLoading(around: centerPage)
        }
    }

    private func updateVisiblePageIndexes(_ pageIndexes: [Int]) {
        let sortedPageIndexes = pageIndexes.sorted()
        let nextVisiblePageIndexes = Set(sortedPageIndexes)
        if nextVisiblePageIndexes != visiblePageIndexes {
            visiblePageIndexes = nextVisiblePageIndexes
        }
        if let centerPage = sortedPageIndexes.isEmpty ? nil : sortedPageIndexes[sortedPageIndexes.count / 2] {
            scheduleThumbnailLoading(around: centerPage)
        }
    }

    private func scheduleThumbnailLoading(around centerPageIndex: Int) {
        guard let pageCount else { return }
        let visibleIndexes = prioritized(
            visiblePageIndexes.filter { $0 >= 0 && $0 < pageCount },
            around: centerPageIndex
        )
        let requestedIndexes = Array(
            Set(visibleIndexes + prioritizedPageIndexes(around: centerPageIndex, pageCount: pageCount))
        )
        let prioritizedIndexes = prioritized(requestedIndexes, around: centerPageIndex)
        guard !prioritizedIndexes.isEmpty else { return }

        let isLocal = renderer != nil
        let remoteRequests: [PDFRemoteThumbnailRequest]
        if !isLocal, let streamPath {
            remoteRequests = prioritizedIndexes.compactMap { pageIndex in
                guard let url = remoteThumbnailURL(path: streamPath, pageIndex: pageIndex) else { return nil }
                return PDFRemoteThumbnailRequest(pageIndex: pageIndex, url: url)
            }
        } else {
            remoteRequests = []
        }
        guard isLocal || !remoteRequests.isEmpty else { return }

        let orderedKeys = isLocal
            ? prioritizedIndexes.map(localThumbnailKey(pageIndex:))
            : remoteRequests.map { $0.url.absoluteString }
        let requestedKeys = Set(orderedKeys)
        let loadID = (isLocal ? "local|" : "remote|") + orderedKeys.joined(separator: "|")
        guard loadID != thumbnailLoadID else { return }
        thumbnailLoadID = loadID
        thumbnailLoadTask?.cancel()

        thumbnailImages = thumbnailImages.filter { requestedKeys.contains($0.key) }
        thumbnailFailures.subtract(requestedKeys)
        thumbnailLoadingKeys = requestedKeys.subtracting(thumbnailImages.keys)
        if let renderer {
            thumbnailLoadTask = Task {
                for pageIndex in prioritizedIndexes {
                    guard !Task.isCancelled, thumbnailLoadID == loadID else { return }
                    let key = localThumbnailKey(pageIndex: pageIndex)
                    guard thumbnailImages[key] == nil else {
                        thumbnailLoadingKeys.remove(key)
                        continue
                    }
                    let data = await renderer.thumbnailData(pageIndex: pageIndex)
                    guard !Task.isCancelled, thumbnailLoadID == loadID else { return }
                    thumbnailLoadingKeys.remove(key)
                    if let data, let image = PDFPagePreviewImage(data: data) {
                        thumbnailImages[key] = image
                        thumbnailFailures.remove(key)
                    } else {
                        thumbnailFailures.insert(key)
                    }
                }
            }
        } else {
            let remoteRenderer = remoteRenderer
            thumbnailLoadTask = Task {
                await withTaskGroup(of: PDFRemoteThumbnailResult.self) { group in
                    for request in remoteRequests where thumbnailImages[request.url.absoluteString] == nil {
                        group.addTask {
                            let data = await remoteRenderer.thumbnailData(pageIndex: request.pageIndex, url: request.url)
                            return PDFRemoteThumbnailResult(request: request, data: data)
                        }
                    }

                    for await result in group {
                        guard !Task.isCancelled, thumbnailLoadID == loadID else { continue }
                        let key = result.request.url.absoluteString
                        thumbnailLoadingKeys.remove(key)
                        if let data = result.data, let image = PDFPagePreviewImage(data: data) {
                            thumbnailImages[key] = image
                            thumbnailFailures.remove(key)
                        } else {
                            thumbnailFailures.insert(key)
                        }
                    }
                }
            }
        }
    }

    private func cancelThumbnailLoading() {
        thumbnailLoadTask?.cancel()
        thumbnailLoadTask = nil
        thumbnailLoadID = ""
    }

    private var usesNativeScrollVisibility: Bool {
        if #available(iOS 18.0, macOS 15.0, *) {
            return true
        }
        return false
    }

    private func thumbnailFrameReader(pageIndex: Int) -> some View {
        Group {
            if #available(iOS 18.0, macOS 15.0, *) {
                Color.clear
            } else {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: PDFPageThumbnailFramePreferenceKey.self,
                        value: [pageIndex: proxy.frame(in: .named(PDFPageSidebarCoordinateSpace.name))]
                    )
                }
            }
        }
    }

    private func remoteThumbnailURL(path: String, pageIndex: Int) -> URL? {
        guard let api = store.api else { return nil }
        return try? api.pdfThumbnailURL(path: path, page: pageIndex + 1)
    }

    private func thumbnailKey(pageIndex: Int) -> String? {
        if renderer != nil {
            return localThumbnailKey(pageIndex: pageIndex)
        }
        guard let streamPath else { return nil }
        return remoteThumbnailURL(path: streamPath, pageIndex: pageIndex)?.absoluteString
    }

    private func localThumbnailKey(pageIndex: Int) -> String {
        "local:\(pageIndex)"
    }

    private func gridColumns(for width: CGFloat) -> [GridItem] {
        #if os(iOS)
        let minimumTwoColumnWidth: CGFloat = UIDevice.current.userInterfaceIdiom == .phone ? 300 : 320
        let columnCount = width >= minimumTwoColumnWidth ? 2 : 1
        #else
        let columnCount = width >= 320 ? 2 : 1
        #endif
        return Array(repeating: GridItem(.flexible(), spacing: 12), count: columnCount)
    }

    private func prioritizedPageIndexes(around pageIndex: Int, pageCount: Int) -> [Int] {
        guard pageCount > 0 else { return [] }
        let current = min(max(pageIndex, 0), pageCount - 1)
        return [current, current + 1, current - 1, current + 2, current - 2]
            .filter { $0 >= 0 && $0 < pageCount }
    }

    private func prioritized<S: Sequence>(_ pageIndexes: S, around centerPageIndex: Int) -> [Int]
    where S.Element == Int {
        pageIndexes.sorted {
            let leftDistance = abs($0 - centerPageIndex)
            let rightDistance = abs($1 - centerPageIndex)
            return leftDistance == rightDistance ? $0 < $1 : leftDistance < rightDistance
        }
    }
}

private enum PDFPageSidebarCoordinateSpace {
    static let name = "pdf-page-sidebar-scroll"
}

private struct PDFPageSidebarVisibilityModifier: ViewModifier {
    let onChange: ([Int]) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 18.0, macOS 15.0, *) {
            content.onScrollTargetVisibilityChange(idType: Int.self, threshold: 0.1, onChange)
        } else {
            content
        }
    }
}

private struct PDFPageThumbnailFramePreferenceKey: PreferenceKey {
    static let defaultValue: [Int: CGRect] = [:]

    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

private struct PDFRemoteThumbnailRequest: Sendable {
    let pageIndex: Int
    let url: URL
}

private struct PDFRemoteThumbnailResult: Sendable {
    let request: PDFRemoteThumbnailRequest
    let data: Data?
}

private actor PDFRemotePageThumbnailRenderer {
    private let gate = PDFThumbnailRequestGate(limit: 3)
    private let cache = NSCache<NSString, NSData>()
    private var activeKeys = Set<String>()

    init() {
        cache.countLimit = 64
        cache.totalCostLimit = 24 * 1024 * 1024
    }

    func thumbnailData(pageIndex: Int, url: URL) async -> Data? {
        let key = url.absoluteString
        let cacheKey = key as NSString
        if let cached = cache.object(forKey: cacheKey) {
            return cached as Data
        }

        while activeKeys.contains(key) {
            guard !Task.isCancelled else { return nil }
            try? await Task.sleep(for: .milliseconds(20))
            if let cached = cache.object(forKey: cacheKey) {
                return cached as Data
            }
        }
        activeKeys.insert(key)

        guard await gate.acquire() else {
            activeKeys.remove(key)
            return nil
        }
        let data: Data?
        if Task.isCancelled {
            data = nil
        } else if let cached = cache.object(forKey: cacheKey) {
            data = cached as Data
        } else {
            data = await Self.download(url: url)
        }
        await gate.release()
        activeKeys.remove(key)
        if let data, cache.object(forKey: cacheKey) == nil {
            cache.setObject(data as NSData, forKey: cacheKey, cost: data.count)
        }
        return data
    }

    private static func download(url: URL) async -> Data? {
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode) else { return nil }
            return data
        } catch {
            return nil
        }
    }
}

private actor PDFThumbnailRequestGate {
    private let limit: Int
    private var activeCount = 0

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    func acquire() async -> Bool {
        while activeCount >= limit {
            guard !Task.isCancelled else { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard !Task.isCancelled else { return false }
        activeCount += 1
        return true
    }

    func release() {
        activeCount = max(0, activeCount - 1)
    }
}

private struct PDFPageThumbnailCell: View {
    let image: PDFPagePreviewImage?
    let isLoading: Bool
    let didFail: Bool
    let pageIndex: Int
    let isCurrent: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 7) {
                ZStack {
                    Color.white
                    if let image {
                        platformImage(image)
                            .resizable()
                            .scaledToFit()
                    } else if didFail {
                        Image(systemName: "exclamationmark.circle")
                            .foregroundStyle(.secondary)
                    } else if isLoading {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .aspectRatio(0.72, contentMode: .fit)
                .clipped()
                .overlay {
                    Rectangle()
                        .stroke(Color.black.opacity(0.12), lineWidth: 1)
                }

                Text("Page \(pageIndex + 1)")
                    .font(.caption.weight(isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? Color.accentColor : Color.primary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .padding(7)
            .frame(maxWidth: 270)
            .background(isCurrent ? Color.accentColor.opacity(0.12) : Color.clear)
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(isCurrent ? Color.accentColor : Color.clear, lineWidth: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Page \(pageIndex + 1)")
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    @ViewBuilder
    private func platformImage(_ image: PDFPagePreviewImage) -> Image {
        #if os(iOS)
        Image(uiImage: image)
        #else
        Image(nsImage: image)
        #endif
    }
}

private final class PDFPageThumbnailRenderer: @unchecked Sendable {
    private let url: URL
    private let queue = DispatchQueue(label: "com.codmes.pdf-thumbnail-renderer", qos: .userInitiated)
    private let cache = NSCache<NSNumber, NSData>()
    private var document: PDFDocument?

    init(url: URL) {
        self.url = url
        cache.countLimit = 64
        cache.totalCostLimit = 24 * 1024 * 1024
    }

    func loadPageCount() async -> Int? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                let document = loadDocumentIfNeeded()
                continuation.resume(returning: document?.pageCount)
            }
        }
    }

    func thumbnailData(pageIndex: Int) async -> Data? {
        if let cached = cache.object(forKey: NSNumber(value: pageIndex)) {
            return cached as Data
        }
        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                let key = NSNumber(value: pageIndex)
                if let cached = cache.object(forKey: key) {
                    continuation.resume(returning: cached as Data)
                    return
                }
                guard let page = loadDocumentIfNeeded()?.page(at: pageIndex),
                      let data = encodedThumbnail(for: page) else {
                    continuation.resume(returning: nil)
                    return
                }
                cache.setObject(data as NSData, forKey: key, cost: data.count)
                continuation.resume(returning: data)
            }
        }
    }

    private func loadDocumentIfNeeded() -> PDFDocument? {
        if let document { return document }
        let loaded = PDFDocument(url: url)
        document = loaded
        return loaded
    }

    private func encodedThumbnail(for page: PDFPage) -> Data? {
        let image = page.thumbnail(of: CGSize(width: 320, height: 440), for: .cropBox)
#if os(iOS)
        return image.pngData()
#else
        return image.tiffRepresentation
#endif
    }
}

#if os(macOS)
@MainActor
final class PDFDocumentCache {
    private var currentURL: URL?
    private var currentDocument: PDFDocument?

    func document(for url: URL) -> PDFDocument? {
        if currentURL != url || currentDocument == nil {
            currentURL = url
            currentDocument = PDFDocument(url: url)
        }
        return currentDocument
    }
}

private struct MacAnnotatedPDFKitView: NSViewRepresentable {
    let url: URL
    var documentOverride: PDFDocument?
    var documentRevision: Int
    var forceDocumentReload: Bool
    var readingState: PDFReadingState?
    var onSaveReadingState: (PDFReadingState) -> Void
    var focus: PDFDocumentFocus?
    var annotations: PDFAnnotationDocument?
    var tool: MacPDFMarkupTool
    var isWritingMode: Bool
    var penColorHex: String
    var penWidth: Double
    var eraserWidth: Double
    var selectedObjectId: String?
    var lassoSelection: PDFLassoSelectionSummary?
    var textEditRequest: Int
    var onStrokeFinished: (Int, CodmesInkStroke) -> Void
    var onStrokesChanged: (Int, [CodmesInkStroke]) -> Void
    var onObjectSelected: (PDFAnnotationObject) -> Void
    var onObjectChanged: (PDFAnnotationObject) -> Void
    var onObjectDeleted: (PDFAnnotationObject) -> Void
    var onLassoSelectionChanged: (PDFLassoSelectionSummary?) -> Void
    var onCurrentPageChanged: (Int) -> Void
    var onObjectEditRequested: (PDFAnnotationObject) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            annotations: annotations,
            selectedObjectId: selectedObjectId,
            lassoSelection: lassoSelection,
            tool: tool,
            isWritingMode: isWritingMode,
            onObjectSelected: onObjectSelected,
            onObjectChanged: onObjectChanged,
            onObjectDeleted: onObjectDeleted,
            onStrokesChanged: onStrokesChanged,
            onCurrentPageChanged: onCurrentPageChanged
        )
    }

    func makeNSView(context: Context) -> CodmesMacPDFView {
        let view = CodmesMacPDFView()
        view.autoScales = false
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.pageBreakMargins = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        view.backgroundColor = .clear
        view.pageOverlayViewProvider = context.coordinator
        context.coordinator.pdfView = view
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.visiblePageChanged(_:)),
            name: Notification.Name.PDFViewPageChanged,
            object: view
        )
        return view
    }

    func updateNSView(_ view: CodmesMacPDFView, context: Context) {
        context.coordinator.onSaveReadingState = onSaveReadingState
        context.coordinator.annotations = annotations
        context.coordinator.selectedObjectId = selectedObjectId
        context.coordinator.lassoSelection = lassoSelection
        context.coordinator.tool = tool
        context.coordinator.isWritingMode = isWritingMode
        context.coordinator.onObjectSelected = onObjectSelected
        context.coordinator.onObjectChanged = onObjectChanged
        context.coordinator.onObjectDeleted = onObjectDeleted
        context.coordinator.onStrokesChanged = onStrokesChanged
        context.coordinator.onCurrentPageChanged = onCurrentPageChanged
        context.coordinator.applyTextEditRequest(textEditRequest)
        view.tool = tool
        view.isWritingMode = isWritingMode
        view.penColorHex = penColorHex
        view.penWidth = penWidth
        view.eraserWidth = eraserWidth
        view.annotations = annotations
        view.selectedObjectId = selectedObjectId
        view.lassoSelection = lassoSelection
        view.onStrokeFinished = onStrokeFinished
        view.onStrokesChanged = onStrokesChanged
        view.onObjectSelected = onObjectSelected
        view.onObjectChanged = onObjectChanged
        view.onObjectDeleted = onObjectDeleted
        view.onLassoSelectionChanged = onLassoSelectionChanged
        view.onObjectEditRequested = onObjectEditRequested
        // SwiftUI also updates this view for unrelated workspace status changes.
        // Keep PDFKit's document, rendered pages and reading position for the same URL.
        let targetDocument = documentOverride ?? context.coordinator.documentCache.document(for: url)
        if view.document !== targetDocument {
            view.document = targetDocument
            view.pendingReadingState = readingState
            view.applyReadingScaleIfNeeded(force: true)
            context.coordinator.documentRevision = documentRevision
        } else if context.coordinator.documentRevision != documentRevision {
            context.coordinator.documentRevision = documentRevision
            if forceDocumentReload, let documentOverride {
                let pageIndex = view.currentPage.flatMap { view.document?.index(for: $0) }
                let scale = view.scaleFactor
                context.coordinator.resetOverlays()
                view.document = nil
                view.document = documentOverride
                view.scaleFactor = scale
                if let pageIndex, let page = documentOverride.page(at: pageIndex) {
                    view.go(to: page)
                }
            } else {
                view.layoutDocumentView()
            }
        }
        context.coordinator.applyFocus(focus, to: view)
        context.coordinator.refreshVisibleOverlays()
        if let current = view.currentPage, let index = view.document?.index(for: current), index >= 0 {
            onCurrentPageChanged(index)
        }
    }

    static func dismantleNSView(_ view: CodmesMacPDFView, coordinator: Coordinator) {
        if let state = PDFReadingState.capture(view) { coordinator.onSaveReadingState?(state) }
        NotificationCenter.default.removeObserver(coordinator)
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency PDFPageOverlayViewProvider, NSTextViewDelegate {
        private struct NormalizedEllipseGeometry {
            var center: CodmesInkPoint
            var rx: Double
            var ry: Double
            var angle: Double
        }

        weak var pdfView: CodmesMacPDFView?
        var onSaveReadingState: ((PDFReadingState) -> Void)?
        var annotations: PDFAnnotationDocument?
        var selectedObjectId: String?
        var lassoSelection: PDFLassoSelectionSummary?
        var tool: MacPDFMarkupTool
        var isWritingMode: Bool
        var onObjectSelected: (PDFAnnotationObject) -> Void
        var onObjectChanged: (PDFAnnotationObject) -> Void
        var onObjectDeleted: (PDFAnnotationObject) -> Void
        var onStrokesChanged: (Int, [CodmesInkStroke]) -> Void
        var onCurrentPageChanged: (Int) -> Void
        private var overlays: [Int: MacPDFPageAnnotationOverlay] = [:]
        let documentCache = PDFDocumentCache()
        var documentRevision = -1

        func resetOverlays() {
            overlays.removeAll()
        }
        private var lastTextEditRequest = 0
        private var pendingTextEditObjectId: String?
        private var lastFocusKey = ""

        init(
            annotations: PDFAnnotationDocument?,
            selectedObjectId: String?,
            lassoSelection: PDFLassoSelectionSummary?,
            tool: MacPDFMarkupTool,
            isWritingMode: Bool,
            onObjectSelected: @escaping (PDFAnnotationObject) -> Void,
            onObjectChanged: @escaping (PDFAnnotationObject) -> Void,
            onObjectDeleted: @escaping (PDFAnnotationObject) -> Void,
            onStrokesChanged: @escaping (Int, [CodmesInkStroke]) -> Void,
            onCurrentPageChanged: @escaping (Int) -> Void
        ) {
            self.annotations = annotations
            self.selectedObjectId = selectedObjectId
            self.lassoSelection = lassoSelection
            self.tool = tool
            self.isWritingMode = isWritingMode
            self.onObjectSelected = onObjectSelected
            self.onObjectChanged = onObjectChanged
            self.onObjectDeleted = onObjectDeleted
            self.onStrokesChanged = onStrokesChanged
            self.onCurrentPageChanged = onCurrentPageChanged
        }

        @objc func visiblePageChanged(_ notification: Notification) {
            guard let view = notification.object as? PDFView,
                  let page = view.currentPage,
                  let index = view.document?.index(for: page),
                  index >= 0 else { return }
            onCurrentPageChanged(index)
        }

        func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> NSView? {
            guard let document = view.document else { return nil }
            let pageIndex = document.index(for: page)
            let overlay = MacPDFPageAnnotationOverlay()
            overlays[pageIndex] = overlay
            (view as? CodmesMacPDFView)?.applyCodmesInkAnnotations(annotations, pageIndex: pageIndex)
            applyObjects(to: overlay, pageIndex: pageIndex)
            return overlay
        }

        func pdfView(_ pdfView: PDFView, willDisplayOverlayView overlayView: NSView, for page: PDFPage) {
            guard let document = pdfView.document,
                  let overlay = overlayView as? MacPDFPageAnnotationOverlay else { return }
            let pageIndex = document.index(for: page)
            overlays[pageIndex] = overlay
            (pdfView as? CodmesMacPDFView)?.applyCodmesInkAnnotations(annotations, pageIndex: pageIndex)
            applyObjects(to: overlay, pageIndex: pageIndex)
        }

        func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: NSView, for page: PDFPage) {
            guard let document = pdfView.document else { return }
            let pageIndex = document.index(for: page)
            (pdfView as? CodmesMacPDFView)?.clearCodmesInkAnnotations(pageIndex: pageIndex)
            overlays[pageIndex] = nil
        }

        func refreshVisibleOverlays() {
            for (pageIndex, overlay) in overlays {
                pdfView?.applyCodmesInkAnnotations(annotations, pageIndex: pageIndex)
                applyObjects(to: overlay, pageIndex: pageIndex)
            }
        }

        func applyTextEditRequest(_ request: Int) {
            guard request != lastTextEditRequest else { return }
            lastTextEditRequest = request
            pendingTextEditObjectId = selectedObjectId
            focusPendingTextEditor()
        }

        func applyFocus(_ focus: PDFDocumentFocus?, to view: CodmesMacPDFView) {
            guard let focus,
                  let document = view.document,
                  let pageNumber = focus.page,
                  pageNumber > 0,
                  pageNumber <= document.pageCount,
                  let page = document.page(at: pageNumber - 1) else { return }
            let key = "\(focus.requestId.uuidString):\(focus.path):\(pageNumber):\(focus.bbox?.x ?? -1):\(focus.bbox?.y ?? -1)"
            guard key != lastFocusKey else { return }
            lastFocusKey = key
            navigateToFocusedPage(page, in: view)
        }

        private func navigateToFocusedPage(_ page: PDFPage, in view: PDFView) {
            view.go(to: page)
            for delay in [0.05, 0.18] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak view] in
                    view?.go(to: page)
                }
            }
        }

        private func applyObjects(to overlay: MacPDFPageAnnotationOverlay, pageIndex: Int) {
            let objects = annotations?.noteObjects(pageIndex: pageIndex) ?? []
            let textObjects = objects.filter { $0.type.lowercased().contains("text") }
            let liveIds = Set(textObjects.map(\.id))
            overlay.clearResizeHandles()
            overlay.clearShapeHandles()
            for (id, view) in overlay.textViews where !liveIds.contains(id) {
                view.removeFromSuperview()
                overlay.textViews[id] = nil
            }
            for object in textObjects {
                let textView = overlay.textViews[object.id] ?? MacPDFTextView(objectId: object.id)
                if overlay.textViews[object.id] == nil {
                    overlay.textViews[object.id] = textView
                    overlay.addSubview(textView)
                }
                configure(textView, object: object, overlay: overlay)
                if object.id == selectedObjectId, tool == .text || tool == .lasso {
                    overlay.addResizeHandles(for: object, around: textView.frame) { [weak self, weak overlay] objectId, edge, deltaX in
                        guard let self, let overlay else { return }
                        self.resizeTextObject(objectId: objectId, edge: edge, deltaX: deltaX, overlay: overlay)
                    }
                }
            }
            applyShapeHandles(to: overlay, pageIndex: pageIndex)
        }

        private func applyShapeHandles(to overlay: MacPDFPageAnnotationOverlay, pageIndex: Int) {
            guard isWritingMode,
                  tool == .lasso,
                  let lassoSelection,
                  lassoSelection.pageIndex == pageIndex,
                  lassoSelection.strokeIds.count == 1,
                  let strokeId = lassoSelection.strokeIds.first,
                  let stroke = annotations?.noteStrokes(pageIndex: pageIndex).first(where: { $0.id == strokeId }),
                  stroke.tool.hasPrefix("shape:") else { return }
            let kind = String(stroke.tool.dropFirst("shape:".count))
            for handle in macShapeHandles(for: stroke, kind: kind) {
                overlay.addShapeHandle(strokeId: stroke.id, handleIndex: handle.index, point: handle.point) { [weak self] strokeId, handleIndex, deltaX, deltaY in
                    self?.resizeShapeStroke(pageIndex: pageIndex, strokeId: strokeId, kind: kind, handleIndex: handleIndex, deltaX: deltaX, deltaY: deltaY)
                }
            }
        }

        private func macShapeHandles(for stroke: CodmesInkStroke, kind: String) -> [(index: Int, point: CodmesInkPoint)] {
            switch kind {
            case "line":
                guard let first = stroke.points.first, let last = stroke.points.last else { return [] }
                return [(0, first), (1, last)]
            case "triangle":
                return Array(stroke.points.prefix(3)).enumerated().map { ($0.offset, $0.element) }
            case "rectangle":
                return Array(stroke.points.prefix(4)).enumerated().map { ($0.offset, $0.element) }
            case "circle":
                guard let box = normalizedBounds(for: stroke.points) else { return [] }
                return [
                    (0, CodmesInkPoint(x: box.x + box.width / 2, y: box.y, pressure: nil, timeOffset: nil)),
                    (1, CodmesInkPoint(x: box.x + box.width, y: box.y + box.height / 2, pressure: nil, timeOffset: nil)),
                    (2, CodmesInkPoint(x: box.x + box.width / 2, y: box.y + box.height, pressure: nil, timeOffset: nil)),
                    (3, CodmesInkPoint(x: box.x, y: box.y + box.height / 2, pressure: nil, timeOffset: nil))
                ]
            case "ellipse":
                guard let geometry = normalizedEllipseGeometry(from: stroke.points) else { return [] }
                return normalizedEllipseHandlePoints(for: geometry)
            case "polyline":
                return stroke.points.enumerated().map { ($0.offset, $0.element) }
            default:
                return []
            }
        }

        private func resizeShapeStroke(pageIndex: Int, strokeId: String, kind: String, handleIndex: Int, deltaX: Double, deltaY: Double) {
            guard var strokes = annotations?.noteStrokes(pageIndex: pageIndex),
                  let strokeOffset = strokes.firstIndex(where: { $0.id == strokeId }),
                  !strokes[strokeOffset].points.isEmpty else { return }
            var stroke = strokes[strokeOffset]
            let handles = macShapeHandles(for: stroke, kind: kind)
            guard let currentHandle = handles.first(where: { $0.index == handleIndex }) else { return }
            let target = movedPoint(currentHandle.point, dx: deltaX, dy: deltaY)
            stroke.points = resizedShapePoints(stroke.points, kind: kind, handleIndex: handleIndex, to: target)
            strokes[strokeOffset] = stroke
            onStrokesChanged(pageIndex, strokes)
        }

        private func resizedShapePoints(_ points: [CodmesInkPoint], kind: String, handleIndex: Int, to point: CodmesInkPoint) -> [CodmesInkPoint] {
            var next = CodmesInkStroke(id: "", tool: "shape:\(kind)", color: "#111111", width: 1, opacity: nil, points: points)
            switch kind {
            case "line":
                guard next.points.count >= 2 else { return next.points }
                if handleIndex == 0 {
                    next.points[0] = point
                } else {
                    next.points[next.points.count - 1] = point
                }
            case "triangle":
                guard next.points.count >= 4, handleIndex < 3 else { return next.points }
                next.points[handleIndex] = point
                if handleIndex == 0 {
                    next.points[next.points.count - 1] = point
                }
            case "rectangle":
                guard let box = normalizedBounds(for: next.points) else { return next.points }
                let opposite: CodmesInkPoint
                switch handleIndex {
                case 0:
                    opposite = CodmesInkPoint(x: box.x + box.width, y: box.y + box.height, pressure: nil, timeOffset: nil)
                case 1:
                    opposite = CodmesInkPoint(x: box.x, y: box.y + box.height, pressure: nil, timeOffset: nil)
                case 2:
                    opposite = CodmesInkPoint(x: box.x, y: box.y, pressure: nil, timeOffset: nil)
                default:
                    opposite = CodmesInkPoint(x: box.x + box.width, y: box.y, pressure: nil, timeOffset: nil)
                }
                next.points = rectanglePoints(from: point, to: opposite)
            case "circle":
                guard let box = normalizedBounds(for: next.points) else { return next.points }
                let center = CodmesInkPoint(
                    x: box.x + box.width / 2,
                    y: box.y + box.height / 2,
                    pressure: nil,
                    timeOffset: nil
                )
                let radius = max(hypot(point.x - center.x, point.y - center.y), 0.005)
                next.points = circlePoints(center: center, radius: radius, count: 48)
            case "ellipse":
                guard let geometry = normalizedEllipseGeometry(from: next.points) else { return next.points }
                let adjusted = adjustedNormalizedEllipseGeometry(geometry, handleIndex: handleIndex, to: point)
                next.points = ellipsePoints(center: adjusted.center, rx: adjusted.rx, ry: adjusted.ry, angle: adjusted.angle, count: 48)
            case "polyline":
                guard next.points.indices.contains(handleIndex) else { return next.points }
                next.points[handleIndex] = point
            default:
                break
            }
            return next.points
        }

        private func movedPoint(_ point: CodmesInkPoint, dx: Double, dy: Double) -> CodmesInkPoint {
            CodmesInkPoint(
                x: min(max(point.x + dx, 0), 1),
                y: min(max(point.y + dy, 0), 1),
                pressure: point.pressure,
                timeOffset: point.timeOffset
            )
        }

        private func normalizedBounds(for points: [CodmesInkPoint]) -> NormalizedBoundingBox? {
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
            return normalizedBox(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
        }

        private func normalizedBox(minX: Double, minY: Double, maxX: Double, maxY: Double) -> NormalizedBoundingBox {
            let left = max(0, min(1, min(minX, maxX)))
            let right = max(0, min(1, max(minX, maxX)))
            let top = max(0, min(1, min(minY, maxY)))
            let bottom = max(0, min(1, max(minY, maxY)))
            return NormalizedBoundingBox(
                x: left,
                y: top,
                width: max(0.01, right - left),
                height: max(0.01, bottom - top)
            )
        }

        private func normalizedEllipseGeometry(from points: [CodmesInkPoint]) -> NormalizedEllipseGeometry? {
            let source = openShapePoints(points)
            guard source.count >= 6 else { return nil }
            let centerX = source.reduce(0) { $0 + $1.x } / Double(source.count)
            let centerY = source.reduce(0) { $0 + $1.y } / Double(source.count)
            var xx = 0.0
            var xy = 0.0
            var yy = 0.0
            for point in source {
                let dx = point.x - centerX
                let dy = point.y - centerY
                xx += dx * dx
                xy += dx * dy
                yy += dy * dy
            }
            var angle = 0.5 * atan2(2 * xy, xx - yy)
            let cosA = cos(angle)
            let sinA = sin(angle)
            var rx = 0.005
            var ry = 0.005
            for point in source {
                let dx = point.x - centerX
                let dy = point.y - centerY
                rx = max(rx, abs(dx * cosA + dy * sinA))
                ry = max(ry, abs(-dx * sinA + dy * cosA))
            }
            if ry > rx {
                swap(&rx, &ry)
                angle += Double.pi / 2
            }
            return NormalizedEllipseGeometry(
                center: CodmesInkPoint(x: centerX, y: centerY, pressure: nil, timeOffset: nil),
                rx: max(rx, 0.005),
                ry: max(ry, 0.005),
                angle: angle
            )
        }

        private func adjustedNormalizedEllipseGeometry(_ geometry: NormalizedEllipseGeometry, handleIndex: Int, to point: CodmesInkPoint) -> NormalizedEllipseGeometry {
            let dx = point.x - geometry.center.x
            let dy = point.y - geometry.center.y
            let distanceFromCenter = max(hypot(dx, dy), 0.005)
            let ratio = max(geometry.rx / max(geometry.ry, 0.005), 1.05)
            switch handleIndex {
            case 0:
                return NormalizedEllipseGeometry(center: geometry.center, rx: distanceFromCenter * ratio, ry: distanceFromCenter, angle: atan2(dy, dx) + Double.pi / 2)
            case 2:
                return NormalizedEllipseGeometry(center: geometry.center, rx: distanceFromCenter * ratio, ry: distanceFromCenter, angle: atan2(dy, dx) - Double.pi / 2)
            case 3:
                return NormalizedEllipseGeometry(center: geometry.center, rx: distanceFromCenter, ry: distanceFromCenter / ratio, angle: atan2(dy, dx) + Double.pi)
            default:
                return NormalizedEllipseGeometry(center: geometry.center, rx: distanceFromCenter, ry: distanceFromCenter / ratio, angle: atan2(dy, dx))
            }
        }

        private func normalizedEllipseHandlePoints(for geometry: NormalizedEllipseGeometry) -> [(Int, CodmesInkPoint)] {
            let cosA = cos(geometry.angle)
            let sinA = sin(geometry.angle)
            let major = (x: cosA * geometry.rx, y: sinA * geometry.rx)
            let minor = (x: -sinA * geometry.ry, y: cosA * geometry.ry)
            return [
                (0, CodmesInkPoint(x: geometry.center.x - minor.x, y: geometry.center.y - minor.y, pressure: nil, timeOffset: nil)),
                (1, CodmesInkPoint(x: geometry.center.x + major.x, y: geometry.center.y + major.y, pressure: nil, timeOffset: nil)),
                (2, CodmesInkPoint(x: geometry.center.x + minor.x, y: geometry.center.y + minor.y, pressure: nil, timeOffset: nil)),
                (3, CodmesInkPoint(x: geometry.center.x - major.x, y: geometry.center.y - major.y, pressure: nil, timeOffset: nil))
            ]
        }

        private func openShapePoints(_ points: [CodmesInkPoint]) -> [CodmesInkPoint] {
            guard points.count > 2,
                  let first = points.first,
                  let last = points.last,
                  hypot(first.x - last.x, first.y - last.y) < 0.0001 else { return points }
            return Array(points.dropLast())
        }

        private func rectanglePoints(from point: CodmesInkPoint, to opposite: CodmesInkPoint) -> [CodmesInkPoint] {
            let box = normalizedBox(minX: point.x, minY: point.y, maxX: opposite.x, maxY: opposite.y)
            let topLeft = CodmesInkPoint(x: box.x, y: box.y, pressure: nil, timeOffset: nil)
            let topRight = CodmesInkPoint(x: box.x + box.width, y: box.y, pressure: nil, timeOffset: nil)
            let bottomRight = CodmesInkPoint(x: box.x + box.width, y: box.y + box.height, pressure: nil, timeOffset: nil)
            let bottomLeft = CodmesInkPoint(x: box.x, y: box.y + box.height, pressure: nil, timeOffset: nil)
            return [topLeft, topRight, bottomRight, bottomLeft, topLeft]
        }

        private func circlePoints(center: CodmesInkPoint, radius: Double, count: Int) -> [CodmesInkPoint] {
            let clampedRadius = max(0.005, min(radius, center.x, 1 - center.x, center.y, 1 - center.y))
            return (0...count).map { index in
                let angle = Double(index) / Double(count) * Double.pi * 2
                return CodmesInkPoint(
                    x: center.x + cos(angle) * clampedRadius,
                    y: center.y + sin(angle) * clampedRadius,
                    pressure: nil,
                    timeOffset: nil
                )
            }
        }

        private func ellipsePoints(center: CodmesInkPoint, rx: Double, ry: Double, angle: Double, count: Int) -> [CodmesInkPoint] {
            let maxRadius = max(0.005, min(center.x, 1 - center.x, center.y, 1 - center.y))
            let clampedRX = min(max(rx, 0.005), maxRadius)
            let clampedRY = min(max(ry, 0.005), maxRadius)
            return (0...count).map { index in
                let theta = Double(index) / Double(count) * Double.pi * 2
                let x = cos(theta) * clampedRX
                let y = sin(theta) * clampedRY
                return CodmesInkPoint(
                    x: center.x + x * cos(angle) - y * sin(angle),
                    y: center.y + x * sin(angle) + y * cos(angle),
                    pressure: nil,
                    timeOffset: nil
                )
            }
        }

        private func configure(_ textView: MacPDFTextView, object: PDFAnnotationObject, overlay: MacPDFPageAnnotationOverlay) {
            guard let box = object.bbox?.normalizedOrSelf else { return }
            textView.objectId = object.id
            textView.delegate = self
            if textView.window?.firstResponder !== textView {
                textView.string = object.text ?? ""
            }
            textView.font = .systemFont(ofSize: CGFloat(Double(object.metadata?["fontSize"] ?? "16") ?? 16))
            textView.textColor = NSColor(hexString: object.metadata?["color"] ?? "#111111") ?? .labelColor
            textView.backgroundColor = .clear
            textView.drawsBackground = false
            textView.isRichText = false
            let isDraft = object.metadata?[CodmesNoteCanvasModel.textDraftMetadataKey] == "true"
            let canEditInline = isWritingMode && tool == .text
            textView.isEditable = canEditInline
            textView.isSelectable = canEditInline
            textView.isVerticallyResizable = true
            textView.isHorizontallyResizable = false
            textView.textContainer?.widthTracksTextView = true
            textView.textContainerInset = NSSize(width: 4, height: 3)
            textView.frame = CGRect(
                x: overlay.bounds.width * box.x,
                y: overlay.bounds.height * box.y,
                width: overlay.bounds.width * box.width,
                height: max(24, overlay.bounds.height * box.height)
            )
            textView.wantsLayer = true
            textView.layer?.borderColor = object.id == selectedObjectId ? NSColor.systemGray.withAlphaComponent(0.7).cgColor : NSColor.clear.cgColor
            textView.layer?.borderWidth = object.id == selectedObjectId ? 1 : 0
            textView.layer?.cornerRadius = 3
            if canEditInline,
               object.id == selectedObjectId,
               isDraft || pendingTextEditObjectId == object.id || textView.window?.firstResponder == textView {
                pendingTextEditObjectId = object.id
                focus(textView)
            }
        }

        private func focusPendingTextEditor() {
            guard let pendingTextEditObjectId else { return }
            for overlay in overlays.values {
                if let textView = overlay.textViews[pendingTextEditObjectId] {
                    focus(textView)
                    return
                }
            }
        }

        private func focus(_ textView: MacPDFTextView) {
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, let textView else { return }
                textView.window?.makeFirstResponder(textView)
                textView.setSelectedRange(NSRange(location: textView.string.count, length: 0))
                if textView.window?.firstResponder === textView {
                    self.pendingTextEditObjectId = nil
                } else {
                    DispatchQueue.main.async { [weak self, weak textView] in
                        guard let self, let textView else { return }
                        textView.window?.makeFirstResponder(textView)
                        textView.setSelectedRange(NSRange(location: textView.string.count, length: 0))
                        if textView.window?.firstResponder === textView {
                            self.pendingTextEditObjectId = nil
                        }
                    }
                }
            }
        }

        func textDidBeginEditing(_ notification: Notification) {
            guard let textView = notification.object as? MacPDFTextView,
                  let object = object(with: textView.objectId) else { return }
            selectedObjectId = object.id
            onObjectSelected(object)
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? MacPDFTextView,
                  var object = object(with: textView.objectId),
                  let overlay = textView.superview as? MacPDFPageAnnotationOverlay else { return }
            object.text = textView.string
            resizeTextViewToFit(textView, object: object, overlay: overlay)
            object.bbox = bbox(for: textView.frame, in: overlay.bounds)
            var metadata = object.metadata ?? [:]
            if !textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                metadata[CodmesNoteCanvasModel.textDraftMetadataKey] = nil
            }
            object.metadata = metadata
            onObjectChanged(object)
        }

        func textDidEndEditing(_ notification: Notification) {
            guard let textView = notification.object as? MacPDFTextView,
                  var object = object(with: textView.objectId),
                  let overlay = textView.superview as? MacPDFPageAnnotationOverlay else { return }
            object.text = textView.string
            if deleteEmptyTextObjectIfNeeded(object, textView: textView, overlay: overlay) {
                return
            }
            resizeTextViewToFit(textView, object: object, overlay: overlay)
            object.bbox = bbox(for: textView.frame, in: overlay.bounds)
            var metadata = object.metadata ?? [:]
            metadata[CodmesNoteCanvasModel.textDraftMetadataKey] = nil
            object.metadata = metadata
            onObjectChanged(object)
        }

        private func deleteEmptyTextObjectIfNeeded(
            _ object: PDFAnnotationObject,
            textView: MacPDFTextView,
            overlay: MacPDFPageAnnotationOverlay
        ) -> Bool {
            guard textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            if selectedObjectId == object.id {
                selectedObjectId = nil
            }
            if pendingTextEditObjectId == object.id {
                pendingTextEditObjectId = nil
            }
            overlay.textViews[object.id] = nil
            textView.removeFromSuperview()
            onObjectDeleted(object)
            return true
        }

        private func object(with id: String) -> PDFAnnotationObject? {
            guard let annotations else { return nil }
            for page in annotations.pages {
                if let object = annotations.noteObjects(pageIndex: page.pageIndex).first(where: { $0.id == id }) {
                    return object
                }
            }
            return annotations.objects.first(where: { $0.id == id })
        }

        private func resizeTextViewToFit(_ textView: MacPDFTextView, object: PDFAnnotationObject, overlay: MacPDFPageAnnotationOverlay) {
            let metadata = object.metadata ?? [:]
            let manualWidth = metadata[CodmesNoteCanvasModel.textManualWidthMetadataKey] == "true"
            let font = textView.font ?? .systemFont(ofSize: 16)
            let horizontalInset = textView.textContainerInset.width * 2 + 8
            let verticalInset = textView.textContainerInset.height * 2 + 8
            let minWidth: CGFloat = 28
            let maxWidth = max(80, overlay.bounds.width * 0.72)
            var frame = textView.frame

            if !manualWidth {
                let measured = (textView.string as NSString).size(withAttributes: [.font: font]).width + horizontalInset
                frame.size.width = min(max(minWidth, measured), maxWidth)
            }

            textView.frame = frame
            guard let textContainer = textView.textContainer else { return }
            textContainer.containerSize = NSSize(width: max(frame.width - horizontalInset, 1), height: CGFloat.greatestFiniteMagnitude)
            textView.layoutManager?.ensureLayout(for: textContainer)
            let usedRect = textView.layoutManager?.usedRect(for: textContainer) ?? .zero
            frame.size.height = max(24, usedRect.height + verticalInset)
            frame.size.width = min(frame.width, max(1, overlay.bounds.width - frame.minX))
            frame.size.height = min(frame.height, max(1, overlay.bounds.height - frame.minY))
            textView.frame = frame
        }

        private func bbox(for frame: CGRect, in bounds: CGRect) -> AnnotationBoundingBox {
            CodmesNoteCanvasModel.clampedBox(
                x: Double(frame.minX / max(bounds.width, 1)),
                y: Double(frame.minY / max(bounds.height, 1)),
                width: Double(frame.width / max(bounds.width, 1)),
                height: Double(frame.height / max(bounds.height, 1))
            )
        }

        private func resizeTextObject(
            objectId: String,
            edge: CodmesNoteObjectResizeEdge,
            deltaX: CGFloat,
            overlay: MacPDFPageAnnotationOverlay
        ) {
            guard let object = object(with: objectId),
                  let startBox = object.bbox?.normalizedOrSelf else { return }
            let normalizedDeltaX = Double(deltaX / max(overlay.bounds.width, 1))
            let resized = CodmesNoteCanvasModel.resizedObject(
                object,
                from: startBox,
                edge: edge,
                deltaX: normalizedDeltaX,
                deltaY: 0,
                minWidth: 0.035,
                minHeight: startBox.height
            )
            selectedObjectId = objectId
            onObjectChanged(resized)
        }
    }

}

private final class MacPDFPageAnnotationOverlay: NSView {
    var textViews: [String: MacPDFTextView] = [:]
    private var resizeHandles: [NSView] = []
    private var shapeHandles: [NSView] = []

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        for subview in subviews.reversed() {
            let converted = convert(point, to: subview)
            if let hit = subview.hitTest(converted) {
                return hit
            }
        }
        return nil
    }

    func clearResizeHandles() {
        for handle in resizeHandles {
            handle.removeFromSuperview()
        }
        resizeHandles.removeAll()
    }

    func clearShapeHandles() {
        for handle in shapeHandles {
            handle.removeFromSuperview()
        }
        shapeHandles.removeAll()
    }

    func addResizeHandles(
        for object: PDFAnnotationObject,
        around frame: CGRect,
        onResize: @escaping @MainActor (String, CodmesNoteObjectResizeEdge, CGFloat) -> Void
    ) {
        guard object.type.lowercased().contains("text") else { return }
        let handles: [(x: CGFloat, edge: CodmesNoteObjectResizeEdge)] = [
            (frame.minX, .left),
            (frame.maxX, .right)
        ]
        for item in handles {
            let handle = MacPDFTextResizeHandleView(
                objectId: object.id,
                edge: item.edge,
                onResize: onResize
            )
            handle.frame = CGRect(x: item.x - 14, y: frame.midY - 22, width: 28, height: 44)
            addSubview(handle)
            resizeHandles.append(handle)
        }
    }

    func addShapeHandle(
        strokeId: String,
        handleIndex: Int,
        point: CodmesInkPoint,
        onDrag: @escaping @MainActor (String, Int, Double, Double) -> Void
    ) {
        let handle = MacPDFShapeHandleView(strokeId: strokeId, handleIndex: handleIndex, onDrag: onDrag)
        handle.frame = CGRect(
            x: bounds.width * point.x - 12,
            y: bounds.height * point.y - 12,
            width: 24,
            height: 24
        )
        addSubview(handle)
        shapeHandles.append(handle)
    }
}

private final class MacPDFShapeHandleView: NSView {
    let strokeId: String
    let handleIndex: Int
    let onDrag: @MainActor (String, Int, Double, Double) -> Void
    private let dotView = NSView()
    private var lastLocation: NSPoint?

    init(
        strokeId: String,
        handleIndex: Int,
        onDrag: @escaping @MainActor (String, Int, Double, Double) -> Void
    ) {
        self.strokeId = strokeId
        self.handleIndex = handleIndex
        self.onDrag = onDrag
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        dotView.wantsLayer = true
        dotView.layer?.backgroundColor = NSColor.systemOrange.cgColor
        dotView.layer?.cornerRadius = 3
        dotView.layer?.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
        dotView.layer?.borderWidth = 1
        addSubview(dotView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        dotView.frame = CGRect(x: bounds.midX - 3, y: bounds.midY - 3, width: 6, height: 6)
    }

    override func mouseDown(with event: NSEvent) {
        lastLocation = superview?.convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let superview else { return }
        let current = superview.convert(event.locationInWindow, from: nil)
        let previous = lastLocation ?? current
        lastLocation = current
        onDrag(
            strokeId,
            handleIndex,
            Double((current.x - previous.x) / max(superview.bounds.width, 1)),
            Double((current.y - previous.y) / max(superview.bounds.height, 1))
        )
    }

    override func mouseUp(with event: NSEvent) {
        lastLocation = nil
    }
}

private final class MacPDFTextResizeHandleView: NSView {
    let objectId: String
    let edge: CodmesNoteObjectResizeEdge
    let onResize: @MainActor (String, CodmesNoteObjectResizeEdge, CGFloat) -> Void
    private let gripView = NSView()
    private var lastLocation: NSPoint?

    init(
        objectId: String,
        edge: CodmesNoteObjectResizeEdge,
        onResize: @escaping @MainActor (String, CodmesNoteObjectResizeEdge, CGFloat) -> Void
    ) {
        self.objectId = objectId
        self.edge = edge
        self.onResize = onResize
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        gripView.wantsLayer = true
        gripView.layer?.backgroundColor = NSColor.systemGray.cgColor
        gripView.layer?.cornerRadius = 2
        addSubview(gripView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func layout() {
        super.layout()
        gripView.frame = CGRect(x: bounds.midX - 2, y: bounds.midY - 11, width: 4, height: 22)
    }

    override func mouseDown(with event: NSEvent) {
        lastLocation = superview?.convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let superview else { return }
        let current = superview.convert(event.locationInWindow, from: nil)
        let deltaX = current.x - (lastLocation?.x ?? current.x)
        lastLocation = current
        onResize(objectId, edge, deltaX)
    }

    override func mouseUp(with event: NSEvent) {
        lastLocation = nil
    }
}

private final class MacPDFTextView: NSTextView {
    var objectId: String

    init(objectId: String) {
        self.objectId = objectId
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(containerSize: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        textStorage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)
        super.init(frame: .zero, textContainer: textContainer)
        isEditable = true
        isSelectable = true
        importsGraphics = false
        allowsUndo = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isEditable || isSelectable ? super.hitTest(point) : nil
    }
}

private final class CodmesMacPDFView: PDFView {
    var pendingReadingState: PDFReadingState?
    private var readingFitGeneration = 0
    private struct ShapeHandleDrag {
        var pageIndex: Int
        var strokeId: String
        var kind: String
        var handleIndex: Int
    }

    var tool: MacPDFMarkupTool = .pen
    var isWritingMode = false
    var penColorHex = "#111111"
    var penWidth = 2.5
    var eraserWidth = 18.0
    var annotations: PDFAnnotationDocument?
    var selectedObjectId: String?
    var lassoSelection: PDFLassoSelectionSummary?
    var onStrokeFinished: ((Int, CodmesInkStroke) -> Void)?
    var onStrokesChanged: ((Int, [CodmesInkStroke]) -> Void)?
    var onObjectSelected: ((PDFAnnotationObject) -> Void)?
    var onObjectChanged: ((PDFAnnotationObject) -> Void)?
    var onObjectDeleted: ((PDFAnnotationObject) -> Void)?
    var onLassoSelectionChanged: ((PDFLassoSelectionSummary?) -> Void)?
    var onObjectEditRequested: ((PDFAnnotationObject) -> Void)?
    private var activePage: PDFPage?
    private var activePoints: [CodmesInkPoint] = []
    private var activeStartTime: TimeInterval = 0
    private var activeObject: PDFAnnotationObject?
    private var activeObjectStartBox: NormalizedBoundingBox?
    private var activeObjectStartPoint: CodmesInkPoint?
    private var activeObjectInteraction: MacPDFObjectInteraction = .move
    private weak var activePreviewPage: PDFPage?
    private var activePreviewAnnotation: PDFAnnotation?
    private var activeShapeFit: PDFShapeFit?
    private var activeShapeHoldWorkItem: DispatchWorkItem?
    private var activeShapeDragAnchorIndex: Int?
    private var lastMacPenPointTime: TimeInterval = 0
    private var lastActivePreviewTool = "pen"
    private var lassoMoveStartSelection: PDFLassoSelectionSummary?
    private var lassoMoveStartPoint: CodmesInkPoint?
    private var lassoMoveStartStrokes: [CodmesInkStroke] = []
    private var lassoMoveStartObjects: [PDFAnnotationObject] = []
    private var activeShapeHandleDrag: ShapeHandleDrag?
    private var readingMinimumScaleFactor: CGFloat = 1
    private var lastReadingViewportSize = CGSize.zero
    private var isApplyingReadingScale = false

    override var acceptsFirstResponder: Bool { true }

    override func layout() {
        super.layout()
        applyReadingScaleIfNeeded()
    }

    override func magnify(with event: NSEvent) {
        super.magnify(with: event)
        guard event.phase.contains(.ended) || event.phase.contains(.cancelled),
              scaleFactor < readingMinimumScaleFactor else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().scaleFactor = readingMinimumScaleFactor
        }
    }

    func applyReadingScaleIfNeeded(force: Bool = false) {
        guard !isApplyingReadingScale,
              let document,
              let page = currentPage ?? document.page(at: 0),
              bounds.width > 1,
              bounds.height > 1,
              force || bounds.size != lastReadingViewportSize,
              let fittedScale = PDFReadingZoom.fittedScale(
                  page: page,
                  displayBox: displayBox,
                  viewport: bounds.size
              ) else { return }

        lastReadingViewportSize = bounds.size
        readingMinimumScaleFactor = fittedScale
        isApplyingReadingScale = true
        autoScales = false
        minScaleFactor = fittedScale * PDFReadingZoom.elasticLowerBoundFraction
        maxScaleFactor = max(fittedScale * 6, 4)
        scaleFactor = fittedScale
        isApplyingReadingScale = false
        readingFitGeneration += 1
        let generation = readingFitGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.readingFitGeneration == generation else { return }
            if let state = self.pendingReadingState {
                self.pendingReadingState = nil
                state.restore(self)
            } else {
                self.go(to: page)
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isWritingMode else {
            super.mouseDown(with: event)
            return
        }
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        guard let page = page(for: point, nearest: true), let document else {
            super.mouseDown(with: event)
            return
        }
        let pageIndex = document.index(for: page)
        let normalized = normalizedPoint(from: point, event: event, page: page, startTime: event.timestamp)

        if discardEmptyTextObjectIfNeeded(at: normalized, pageIndex: pageIndex) {
            return
        }

        if consumeTextEditingBlurClickIfNeeded(at: normalized, pageIndex: pageIndex) {
            return
        }

        if tool == .lasso,
           pageIndex >= 0,
           let handleDrag = macShapeHandleDrag(at: normalized, page: page, pageIndex: pageIndex) {
            activePage = page
            activeShapeHandleDrag = handleDrag
            return
        }

        if (tool == .text || tool == .lasso),
           pageIndex >= 0,
           let hit = textResizeHandleHit(at: normalized, page: page, pageIndex: pageIndex) {
            activePage = page
            activeObject = hit.object
            activeObjectStartBox = hit.object.bbox?.normalizedOrSelf
            activeObjectStartPoint = normalized
            activeObjectInteraction = .resize(hit.edge)
            selectedObjectId = hit.object.id
            onObjectSelected?(hit.object)
            return
        }

        if tool == .lasso,
           pageIndex >= 0,
           let selection = lassoSelection,
           selection.pageIndex == pageIndex,
           let selectionBounds = selection.bounds.normalizedOrSelf,
           CodmesNoteCanvasModel.contains(normalized, in: selectionBounds) {
            activePage = page
            lassoMoveStartSelection = selection
            lassoMoveStartPoint = normalized
            lassoMoveStartStrokes = annotations?.noteStrokes(pageIndex: pageIndex).filter { selection.strokeIds.contains($0.id) } ?? []
            lassoMoveStartObjects = annotations?.noteObjects(pageIndex: pageIndex).filter { selection.objectIds.contains($0.id) } ?? []
            return
        }

        if tool == .text || tool == .lasso,
           pageIndex >= 0,
           let object = object(at: normalized, pageIndex: pageIndex) {
            activePage = page
            activeObject = object
            activeObjectStartBox = object.bbox?.normalizedOrSelf
            activeObjectStartPoint = normalized
            activeObjectInteraction = .move
            selectedObjectId = object.id
            onObjectSelected?(object)
            if event.clickCount >= 2, object.type.lowercased().contains("text") {
                onObjectEditRequested?(object)
            }
            return
        }

        switch tool {
        case .pen:
            activePage = page
            activeStartTime = event.timestamp
            lastMacPenPointTime = ProcessInfo.processInfo.systemUptime
            activePoints = [normalizedPoint(from: point, event: event, page: page, startTime: activeStartTime)]
            updateActivePreview(on: page, pageIndex: pageIndex, tool: "pen")
            scheduleMacShapeHold(page: page, pageIndex: pageIndex)
            if document.index(for: page) < 0 {
                activePage = nil
                activePoints = []
            }
        case .eraser:
            eraseStroke(at: point, page: page)
        case .lasso:
            activePage = page
            activeStartTime = event.timestamp
            activePoints = [normalizedPoint(from: point, event: event, page: page, startTime: activeStartTime)]
            if document.index(for: page) < 0 {
                activePage = nil
                activePoints = []
            }
        case .text:
            guard pageIndex >= 0 else { return }
            let object = makeTextObject(at: point, page: page, pageIndex: pageIndex)
            selectedObjectId = object.id
            onObjectChanged?(object)
            onObjectSelected?(object)
            onObjectEditRequested?(object)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard isWritingMode else {
            super.mouseDragged(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        guard let page = activePage ?? page(for: point, nearest: true) else {
            super.mouseDragged(with: event)
            return
        }

        if let handleDrag = activeShapeHandleDrag {
            updateMacShapeHandleDrag(handleDrag, to: normalizedPoint(from: point, page: page), commit: false)
            return
        }

        switch tool {
        case .pen:
            guard activePage != nil else {
                super.mouseDragged(with: event)
                return
            }
            let normalized = normalizedPoint(from: point, event: event, page: page, startTime: activeStartTime)
            if let fit = activeShapeFit {
                let adjusted = adjustedMacShapeFit(fit, to: normalized)
                activeShapeFit = adjusted
            } else {
                activePoints.append(normalized)
                lastMacPenPointTime = ProcessInfo.processInfo.systemUptime
                scheduleMacShapeHold(page: page, pageIndex: document?.index(for: page) ?? -1)
            }
            if let document {
                updateActivePreview(on: page, pageIndex: document.index(for: page), tool: "pen")
            }
        case .eraser:
            eraseStroke(at: point, page: page)
        case .lasso:
            if lassoMoveStartSelection != nil {
                updateMacLassoMove(to: point, page: page, commit: false)
                return
            }
            if activeObject != nil {
                updateActiveObjectDrag(with: point, event: event, page: page, commit: true)
                return
            }
            guard activePage != nil else {
                super.mouseDragged(with: event)
                return
            }
            activePoints.append(normalizedPoint(from: point, event: event, page: page, startTime: activeStartTime))
            if let document {
                updateActivePreview(on: page, pageIndex: document.index(for: page), tool: "lasso")
            }
        case .text:
            if activeObject != nil {
                updateActiveObjectDrag(with: point, event: event, page: page, commit: true)
            } else {
                super.mouseDragged(with: event)
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard isWritingMode else {
            super.mouseUp(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        if let handleDrag = activeShapeHandleDrag,
           let page = activePage ?? page(for: point, nearest: true) {
            updateMacShapeHandleDrag(handleDrag, to: normalizedPoint(from: point, page: page), commit: true)
            activeShapeHandleDrag = nil
            activePage = nil
            return
        }
        if activeObject != nil,
           let page = activePage ?? page(for: point, nearest: true) {
            updateActiveObjectDrag(with: point, event: event, page: page, commit: true)
            clearMacActiveShapeState()
            activeObject = nil
            activeObjectStartBox = nil
            activeObjectStartPoint = nil
            activeObjectInteraction = .move
            activePage = nil
            return
        }
        if lassoMoveStartSelection != nil,
           let page = activePage ?? page(for: point, nearest: true) {
            updateMacLassoMove(to: point, page: page, commit: true)
            clearMacLassoMoveState()
            activePage = nil
            return
        }
        switch tool {
        case .pen:
            guard let page = activePage, let document else {
                super.mouseUp(with: event)
                return
            }
            activePoints.append(normalizedPoint(from: point, event: event, page: page, startTime: activeStartTime))
            let pageIndex = document.index(for: page)
            if pageIndex >= 0, activePoints.count > 1 {
                let recognized: (kind: String?, points: [CodmesInkPoint])
                if let activeShapeFit {
                    recognized = (
                        kind: activeShapeFit.kind,
                        points: inkPoints(from: activeShapeFit.points, template: activePoints)
                    )
                } else {
                    recognized = (kind: nil, points: activePoints)
                }
                let stroke = CodmesInkStroke(
                    id: UUID().uuidString,
                    tool: recognized.kind.map { "shape:\($0)" } ?? "pen",
                    color: penColorHex,
                    width: penWidth,
                    opacity: nil,
                    points: recognized.points
                )
                removeActivePreview()
                onStrokeFinished?(pageIndex, stroke)
                if recognized.kind != nil,
                   let bounds = CodmesNoteCanvasModel.bounds(for: stroke.points) {
                    let selection = PDFLassoSelectionSummary(
                        pageIndex: pageIndex,
                        strokeIds: [stroke.id],
                        objectIds: [],
                        bounds: bounds,
                        optionAnchor: optionAnchor(pageIndex: pageIndex, bounds: bounds),
                        isMoving: false
                    )
                    lassoSelection = selection
                    onLassoSelectionChanged?(selection)
                }
            }
            activePage = nil
            activePoints = []
            clearMacActiveShapeState()
        case .eraser:
            if let page = page(for: point, nearest: true) {
                eraseStroke(at: point, page: page)
            }
        case .lasso:
            guard let page = activePage, let document else {
                super.mouseUp(with: event)
                return
            }
            activePoints.append(normalizedPoint(from: point, event: event, page: page, startTime: activeStartTime))
            let pageIndex = document.index(for: page)
            if pageIndex >= 0 {
                selectLassoContent(pageIndex: pageIndex, outline: activePoints)
            }
            activePage = nil
            activePoints = []
        case .text:
            activeObject = nil
            activeObjectStartBox = nil
            activeObjectStartPoint = nil
            activeObjectInteraction = .move
        }
        removeActivePreview()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        activeShapeHoldWorkItem?.cancel()
    }

    override func keyDown(with event: NSEvent) {
        guard event.keyCode == 51 || event.keyCode == 117,
              let selectedObjectId,
              let object = allObjects().first(where: { $0.id == selectedObjectId }) else {
            super.keyDown(with: event)
            return
        }
        onObjectDeleted?(object)
    }

    func applyCodmesInkAnnotations(_ annotations: PDFAnnotationDocument?) {
        guard let document,
              let page = currentPage,
              document.index(for: page) >= 0 else { return }
        applyCodmesInkAnnotations(annotations, pageIndex: document.index(for: page))
    }

    func clearCodmesInkAnnotations(pageIndex: Int) {
        guard let page = document?.page(at: pageIndex) else { return }
        for annotation in page.annotations where annotation.contents?.hasPrefix("codmes-") == true || annotation.userName?.hasPrefix("codmes-") == true {
            page.removeAnnotation(annotation)
        }
    }

    func applyCodmesInkAnnotations(_ annotations: PDFAnnotationDocument?, pageIndex: Int) {
        guard let page = document?.page(at: pageIndex) else { return }
        clearCodmesInkAnnotations(pageIndex: pageIndex)
        guard let annotations else { return }
        let pageBounds = page.bounds(for: .mediaBox)
        let strokes = annotations.noteStrokes(pageIndex: pageIndex)
        for stroke in strokes where stroke.points.count > 1 {
            let ink = PDFAnnotation(bounds: pageBounds, forType: .ink, withProperties: nil)
            ink.contents = "codmes-ink-preview:\(stroke.id)"
            ink.color = NSColor(hexString: stroke.color) ?? .labelColor
            let path = NSBezierPath()
            let first = stroke.points[0]
            path.move(to: pagePoint(first, pageBounds: pageBounds))
            for point in stroke.points.dropFirst() {
                path.line(to: pagePoint(point, pageBounds: pageBounds))
            }
            path.lineWidth = max(0.5, stroke.width)
            ink.add(path)
            page.addAnnotation(ink)
        }
        for object in annotations.noteObjects(pageIndex: pageIndex) {
            guard !object.type.lowercased().contains("text") else { continue }
            addObjectPreview(object, to: page, pageBounds: pageBounds)
        }
    }

    private func normalizedPoint(from viewPoint: NSPoint, event: NSEvent, page: PDFPage, startTime: TimeInterval) -> CodmesInkPoint {
        let pagePoint = convert(viewPoint, to: page)
        let bounds = page.bounds(for: .mediaBox)
        let x = min(max((pagePoint.x - bounds.minX) / max(bounds.width, 1), 0), 1)
        let y = min(max(1 - ((pagePoint.y - bounds.minY) / max(bounds.height, 1)), 0), 1)
        return CodmesInkPoint(
            x: x,
            y: y,
            pressure: Double(event.pressure),
            timeOffset: event.timestamp - startTime
        )
    }

    private func pagePoint(_ point: CodmesInkPoint, pageBounds: CGRect) -> NSPoint {
        NSPoint(
            x: pageBounds.minX + pageBounds.width * point.x,
            y: pageBounds.minY + pageBounds.height * (1 - point.y)
        )
    }

    private func updateActivePreview(on page: PDFPage, pageIndex: Int, tool: String) {
        guard pageIndex >= 0, activePoints.count > 1 else { return }
        lastActivePreviewTool = tool
        removeActivePreview()
        let pageBounds = page.bounds(for: .mediaBox)
        let ink = PDFAnnotation(bounds: pageBounds, forType: .ink, withProperties: nil)
        ink.contents = "codmes-active-preview"
        ink.color = tool == "lasso" ? .systemOrange : (NSColor(hexString: penColorHex) ?? .labelColor)
        let path = NSBezierPath()
        let previewPoints = activeShapeFit.map {
            inkPoints(from: $0.points, template: activePoints)
        } ?? activePoints
        let first = previewPoints[0]
        path.move(to: pagePoint(first, pageBounds: pageBounds))
        for point in previewPoints.dropFirst() {
            path.line(to: pagePoint(point, pageBounds: pageBounds))
        }
        path.lineWidth = tool == "lasso" ? 1.5 : max(0.5, penWidth)
        ink.add(path)
        page.addAnnotation(ink)
        activePreviewPage = page
        activePreviewAnnotation = ink
    }

    private func scheduleMacShapeHold(page: PDFPage, pageIndex: Int) {
        guard pageIndex >= 0 else { return }
        activeShapeHoldWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self, weak page] in
            guard let self, let page, self.activePage === page, self.tool == .pen, self.activeShapeFit == nil else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if now - self.lastMacPenPointTime < 0.5 {
                self.scheduleMacShapeHold(page: page, pageIndex: pageIndex)
                return
            }
            guard let fit = self.recognizedMacShapeFit(from: self.activePoints) else { return }
            self.activeShapeFit = fit
            self.activeShapeDragAnchorIndex = self.macShapeDragAnchorIndex(for: fit)
            self.updateActivePreview(on: page, pageIndex: pageIndex, tool: "pen")
        }
        activeShapeHoldWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }

    private func recognizedMacShapeFit(from points: [CodmesInkPoint]) -> PDFShapeFit? {
        let scale: CGFloat = 1_000
        let cgPoints = points.map { CGPoint(x: CGFloat($0.x) * scale, y: CGFloat($0.y) * scale) }
        guard cgPoints.count > 8,
              let result = PDFShapeRecognizer().recognize(points: cgPoints) else {
            return nil
        }
        return PDFShapeFit(
            kind: result.fit.kind,
            points: result.fit.points.map {
                CGPoint(
                    x: min(max($0.x / scale, 0), 1),
                    y: min(max($0.y / scale, 0), 1)
                )
            }
        )
    }

    private func adjustedMacShapeFit(_ fit: PDFShapeFit, to point: CodmesInkPoint) -> PDFShapeFit {
        let cgPoint = CGPoint(x: point.x, y: point.y)
        let index = activeShapeDragAnchorIndex ?? macShapeDragAnchorIndex(for: fit)
        switch fit.kind {
        case "line":
            guard fit.points.count >= 2 else { return fit }
            return PDFShapeFit(kind: fit.kind, points: [fit.points[0], cgPoint])
        case "polyline":
            guard fit.points.count >= 2 else { return fit }
            var points = fit.points
            let index = min(max(index, 0), points.count - 1)
            points[index] = cgPoint
            return PDFShapeFit(kind: fit.kind, points: points)
        case "triangle":
            guard fit.points.count >= 4 else { return fit }
            var points = fit.points
            let index = min(max(index, 0), 2)
            points[index] = cgPoint
            if points.count > 3 {
                points[points.count - 1] = points[0]
            }
            return PDFShapeFit(kind: fit.kind, points: points)
        case "rectangle":
            guard let bounds = pointBounds(for: fit.points) else { return fit }
            let opposite: CGPoint
            switch index {
            case 0:
                opposite = CGPoint(x: bounds.maxX, y: bounds.maxY)
            case 1:
                opposite = CGPoint(x: bounds.minX, y: bounds.maxY)
            case 2:
                opposite = CGPoint(x: bounds.minX, y: bounds.minY)
            default:
                opposite = CGPoint(x: bounds.maxX, y: bounds.minY)
            }
            return PDFShapeFit(kind: fit.kind, points: rectanglePoints(from: cgPoint, to: opposite))
        case "circle":
            guard let bounds = pointBounds(for: fit.points) else { return fit }
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            let radius = max(hypot(cgPoint.x - center.x, cgPoint.y - center.y), 0.005)
            return PDFShapeFit(kind: fit.kind, points: circlePoints(center: center, radius: radius, count: 48))
        case "ellipse":
            guard let geometry = ellipseGeometry(from: fit.points) else { return fit }
            let adjusted = adjustedEllipseGeometry(geometry, handleIndex: index, to: cgPoint)
            return PDFShapeFit(kind: fit.kind, points: ellipsePoints(center: adjusted.center, rx: adjusted.rx, ry: adjusted.ry, angle: adjusted.angle, count: 48))
        default:
            return fit
        }
    }

    private func macShapeDragAnchorIndex(for fit: PDFShapeFit) -> Int {
        guard let last = activePoints.last else { return fit.points.indices.last ?? 0 }
        let point = CGPoint(x: last.x, y: last.y)
        return fit.points.indices.min {
            hypot(fit.points[$0].x - point.x, fit.points[$0].y - point.y) <
                hypot(fit.points[$1].x - point.x, fit.points[$1].y - point.y)
        } ?? (fit.points.indices.last ?? 0)
    }

    private func macRectanglePoints(from first: CGPoint, to second: CGPoint) -> [CGPoint] {
        rectanglePoints(from: first, to: second)
    }

    private func pointBounds(for points: [CGPoint]) -> CGRect? {
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
        return CGRect(x: minX, y: minY, width: max(0.001, maxX - minX), height: max(0.001, maxY - minY))
    }

    private func rectanglePoints(from first: CGPoint, to second: CGPoint) -> [CGPoint] {
        let rect = CGRect(
            x: min(first.x, second.x),
            y: min(first.y, second.y),
            width: max(0.001, abs(second.x - first.x)),
            height: max(0.001, abs(second.y - first.y))
        )
        let topLeft = CGPoint(x: rect.minX, y: rect.minY)
        let topRight = CGPoint(x: rect.maxX, y: rect.minY)
        let bottomRight = CGPoint(x: rect.maxX, y: rect.maxY)
        let bottomLeft = CGPoint(x: rect.minX, y: rect.maxY)
        return [topLeft, topRight, bottomRight, bottomLeft, topLeft]
    }

    private func macEllipsePoints(in rect: CGRect, count: Int) -> [CGPoint] {
        ellipsePoints(in: rect, count: count)
    }

    private func circlePoints(center: CGPoint, radius: CGFloat, count: Int) -> [CGPoint] {
        (0...count).map { index in
            let angle = CGFloat(index) / CGFloat(count) * .pi * 2
            return CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
        }
    }

    private func ellipsePoints(in rect: CGRect, count: Int) -> [CGPoint] {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let rx = rect.width / 2
        let ry = rect.height / 2
        return (0...count).map { index in
            let angle = CGFloat(index) / CGFloat(count) * .pi * 2
            return CGPoint(x: center.x + cos(angle) * rx, y: center.y + sin(angle) * ry)
        }
    }

    private struct MacEllipseGeometry {
        var center: CGPoint
        var rx: CGFloat
        var ry: CGFloat
        var angle: CGFloat
    }

    private func ellipseGeometry(from points: [CGPoint]) -> MacEllipseGeometry? {
        var source = points
        if source.count > 2,
           let first = source.first,
           let last = source.last,
           hypot(first.x - last.x, first.y - last.y) < 0.0001 {
            source.removeLast()
        }
        guard source.count >= 6 else { return nil }
        let center = CGPoint(
            x: source.reduce(CGFloat(0)) { $0 + $1.x } / CGFloat(source.count),
            y: source.reduce(CGFloat(0)) { $0 + $1.y } / CGFloat(source.count)
        )
        var xx: CGFloat = 0
        var xy: CGFloat = 0
        var yy: CGFloat = 0
        for point in source {
            let dx = point.x - center.x
            let dy = point.y - center.y
            xx += dx * dx
            xy += dx * dy
            yy += dy * dy
        }
        var angle = CGFloat(0.5) * atan2(2 * xy, xx - yy)
        let cosA = cos(angle)
        let sinA = sin(angle)
        var rx: CGFloat = 0.005
        var ry: CGFloat = 0.005
        for point in source {
            let dx = point.x - center.x
            let dy = point.y - center.y
            rx = max(rx, abs(dx * cosA + dy * sinA))
            ry = max(ry, abs(-dx * sinA + dy * cosA))
        }
        if ry > rx {
            swap(&rx, &ry)
            angle += .pi / 2
        }
        return MacEllipseGeometry(center: center, rx: rx, ry: ry, angle: angle)
    }

    private func adjustedEllipseGeometry(_ geometry: MacEllipseGeometry, handleIndex: Int, to point: CGPoint) -> MacEllipseGeometry {
        let dx = point.x - geometry.center.x
        let dy = point.y - geometry.center.y
        let distanceFromCenter = max(hypot(dx, dy), 0.005)
        let ratio = max(geometry.rx / max(geometry.ry, 0.005), 1.05)
        switch handleIndex {
        case 0:
            return MacEllipseGeometry(center: geometry.center, rx: distanceFromCenter * ratio, ry: distanceFromCenter, angle: atan2(dy, dx) + .pi / 2)
        case 2:
            return MacEllipseGeometry(center: geometry.center, rx: distanceFromCenter * ratio, ry: distanceFromCenter, angle: atan2(dy, dx) - .pi / 2)
        case 3:
            return MacEllipseGeometry(center: geometry.center, rx: distanceFromCenter, ry: distanceFromCenter / ratio, angle: atan2(dy, dx) + .pi)
        default:
            return MacEllipseGeometry(center: geometry.center, rx: distanceFromCenter, ry: distanceFromCenter / ratio, angle: atan2(dy, dx))
        }
    }

    private func ellipsePoints(center: CGPoint, rx: CGFloat, ry: CGFloat, angle: CGFloat, count: Int) -> [CGPoint] {
        (0...count).map { index in
            let theta = CGFloat(index) / CGFloat(count) * .pi * 2
            let x = cos(theta) * rx
            let y = sin(theta) * ry
            return CGPoint(
                x: center.x + x * cos(angle) - y * sin(angle),
                y: center.y + x * sin(angle) + y * cos(angle)
            )
        }
    }

    private func removeActivePreview() {
        if let page = activePreviewPage, let annotation = activePreviewAnnotation {
            page.removeAnnotation(annotation)
        }
        activePreviewPage = nil
        activePreviewAnnotation = nil
    }

    private func clearMacActiveShapeState() {
        activeShapeHoldWorkItem?.cancel()
        activeShapeHoldWorkItem = nil
        activeShapeFit = nil
        activeShapeDragAnchorIndex = nil
        lastMacPenPointTime = 0
    }

    private func recognizedMacShape(from points: [CodmesInkPoint]) -> (kind: String?, points: [CodmesInkPoint]) {
        guard let fit = recognizedMacShapeFit(from: points) else {
            return (nil, points)
        }
        return (fit.kind, inkPoints(from: fit.points, template: points))
    }

    private func inkPoints(from points: [CGPoint], template: [CodmesInkPoint]) -> [CodmesInkPoint] {
        points.enumerated().map { index, point in
            CodmesInkPoint(
                x: min(max(point.x, 0), 1),
                y: min(max(point.y, 0), 1),
                pressure: template[min(index, max(template.count - 1, 0))].pressure,
                timeOffset: template[min(index, max(template.count - 1, 0))].timeOffset
            )
        }
    }

    private func makeTextObject(at viewPoint: NSPoint, page: PDFPage, pageIndex: Int) -> PDFAnnotationObject {
        let normalized = normalizedPoint(from: viewPoint, page: page)
        return CodmesNoteCanvasModel.makeTextObject(pageIndex: pageIndex, at: normalized)
    }

    private func addObjectPreview(_ object: PDFAnnotationObject, to page: PDFPage, pageBounds: CGRect) {
        guard let box = object.bbox?.normalizedOrSelf else { return }
        let rect = CGRect(
            x: pageBounds.minX + pageBounds.width * box.x,
            y: pageBounds.minY + pageBounds.height * (1 - box.y - box.height),
            width: pageBounds.width * box.width,
            height: pageBounds.height * box.height
        )
        let annotation: PDFAnnotation
        if object.type.lowercased().contains("text") {
            annotation = PDFAnnotation(bounds: rect, forType: .freeText, withProperties: nil)
            annotation.contents = object.text?.isEmpty == false ? object.text : " "
            annotation.userName = "codmes-object-preview:\(object.id)"
            annotation.font = .systemFont(ofSize: CGFloat(Double(object.metadata?["fontSize"] ?? "16") ?? 16))
            annotation.fontColor = NSColor(hexString: object.metadata?["color"] ?? "#111111") ?? .labelColor
            annotation.color = object.id == selectedObjectId ? .systemGray.withAlphaComponent(0.24) : .clear
        } else {
            annotation = PDFAnnotation(bounds: rect, forType: .square, withProperties: nil)
            annotation.contents = "codmes-object-preview:\(object.id)"
            annotation.color = object.id == selectedObjectId ? .systemOrange : .systemBlue.withAlphaComponent(0.65)
            annotation.interiorColor = .systemBlue.withAlphaComponent(0.08)
        }
        page.addAnnotation(annotation)
    }

    private func eraseStroke(at viewPoint: NSPoint, page: PDFPage) {
        guard let document, let annotations else { return }
        let pageIndex = document.index(for: page)
        guard pageIndex >= 0 else { return }
        let strokes = annotations.noteStrokes(pageIndex: pageIndex)
        guard !strokes.isEmpty else { return }
        let normalized = normalizedPoint(from: viewPoint, page: page)
        let pageBounds = page.bounds(for: .mediaBox)
        let threshold = max(0.004, eraserWidth / Double(max(min(pageBounds.width, pageBounds.height), 1)))
        let kept = splitStrokes(strokes, erasingAt: normalized, threshold: threshold)
        guard kept.map(\.id) != strokes.map(\.id) || kept.count != strokes.count else { return }
        onStrokesChanged?(pageIndex, kept)
    }

    private func normalizedPoint(from viewPoint: NSPoint, page: PDFPage) -> CodmesInkPoint {
        let pagePoint = convert(viewPoint, to: page)
        let bounds = page.bounds(for: .mediaBox)
        let x = min(max((pagePoint.x - bounds.minX) / max(bounds.width, 1), 0), 1)
        let y = min(max(1 - ((pagePoint.y - bounds.minY) / max(bounds.height, 1)), 0), 1)
        return CodmesInkPoint(x: x, y: y, pressure: nil, timeOffset: nil)
    }

    private func allObjects() -> [PDFAnnotationObject] {
        guard let annotations else { return [] }
        var result: [PDFAnnotationObject] = []
        var seen = Set<String>()
        for page in annotations.pages {
            for object in annotations.noteObjects(pageIndex: page.pageIndex) where !seen.contains(object.id) {
                seen.insert(object.id)
                result.append(object)
            }
        }
        return result
    }

    private func selectLassoContent(pageIndex: Int, outline: [CodmesInkPoint]) {
        guard let annotations,
              let selection = CodmesNoteCanvasModel.selection(
                  pageIndex: pageIndex,
                  outline: outline,
                  strokes: annotations.noteStrokes(pageIndex: pageIndex),
                  objects: annotations.noteObjects(pageIndex: pageIndex)
              ) else {
            selectedObjectId = nil
            applyCodmesInkAnnotations(self.annotations)
            return
        }
        if let objectId = selection.objectIds.first,
           let object = allObjects().first(where: { $0.id == objectId }) {
            selectedObjectId = object.id
            onObjectSelected?(object)
        } else {
            selectedObjectId = nil
        }
        onLassoSelectionChanged?(PDFLassoSelectionSummary(
            pageIndex: selection.pageIndex,
            strokeIds: selection.strokeIds,
            objectIds: selection.objectIds,
            bounds: selection.bounds,
            optionAnchor: optionAnchor(for: selection),
            isMoving: false
        ))
        applyCodmesInkAnnotations(self.annotations)
    }

    private func updateMacLassoMove(to viewPoint: NSPoint, page: PDFPage, commit: Bool) {
        guard let document,
              let selection = lassoMoveStartSelection,
              let start = lassoMoveStartPoint else { return }
        let pageIndex = document.index(for: page)
        guard pageIndex == selection.pageIndex else { return }
        let current = normalizedPoint(from: viewPoint, page: page)
        let dx = current.x - start.x
        let dy = current.y - start.y
        let movedStrokes = lassoMoveStartStrokes.map { offset(stroke: $0, dx: dx, dy: dy) }
        let movedObjects = lassoMoveStartObjects.map { object -> PDFAnnotationObject in
            guard let box = object.bbox?.normalizedOrSelf else { return object }
            return CodmesNoteCanvasModel.movedObject(object, from: box, deltaX: dx, deltaY: dy)
        }
        let movedBounds = CodmesNoteCanvasModel.clampedBox(
            x: selection.bounds.x + dx,
            y: selection.bounds.y + dy,
            width: selection.bounds.width,
            height: selection.bounds.height
        )
        let movedSelection = PDFLassoSelectionSummary(
            pageIndex: selection.pageIndex,
            strokeIds: selection.strokeIds,
            objectIds: selection.objectIds,
            bounds: movedBounds,
            optionAnchor: optionAnchor(pageIndex: selection.pageIndex, bounds: movedBounds),
            isMoving: !commit
        )
        lassoSelection = movedSelection
        onLassoSelectionChanged?(movedSelection)
        onStrokesChanged?(selection.pageIndex, mergedStrokes(pageIndex: selection.pageIndex, moved: movedStrokes, selectedIds: selection.strokeIds))
        for object in movedObjects {
            onObjectChanged?(object)
        }
        if commit {
            applyCodmesInkAnnotations(annotations)
        }
    }

    private func clearMacLassoMoveState() {
        lassoMoveStartSelection = nil
        lassoMoveStartPoint = nil
        lassoMoveStartStrokes = []
        lassoMoveStartObjects = []
    }

    private func macShapeHandleDrag(at point: CodmesInkPoint, page: PDFPage, pageIndex: Int) -> ShapeHandleDrag? {
        guard let selection = lassoSelection,
              selection.pageIndex == pageIndex,
              selection.strokeIds.count == 1,
              let strokeId = selection.strokeIds.first,
              let stroke = annotations?.noteStrokes(pageIndex: pageIndex).first(where: { $0.id == strokeId }),
              stroke.tool.hasPrefix("shape:") else { return nil }
        let kind = String(stroke.tool.dropFirst("shape:".count))
        let pageBounds = page.bounds(for: .mediaBox)
        let hitRadius = max(0.012, 18 / Double(max(min(pageBounds.width, pageBounds.height), 1)))
        return macShapeHandles(for: stroke, kind: kind)
            .filter { hypot($0.point.x - point.x, $0.point.y - point.y) <= hitRadius }
            .min {
                hypot($0.point.x - point.x, $0.point.y - point.y) <
                    hypot($1.point.x - point.x, $1.point.y - point.y)
            }
            .map {
                ShapeHandleDrag(
                    pageIndex: pageIndex,
                    strokeId: stroke.id,
                    kind: kind,
                    handleIndex: $0.index
                )
            }
    }

    private func updateMacShapeHandleDrag(_ drag: ShapeHandleDrag, to point: CodmesInkPoint, commit: Bool) {
        guard var strokes = annotations?.noteStrokes(pageIndex: drag.pageIndex),
              let strokeIndex = strokes.firstIndex(where: { $0.id == drag.strokeId }) else { return }
        strokes[strokeIndex] = resizedMacShapeStroke(
            strokes[strokeIndex],
            kind: drag.kind,
            handleIndex: drag.handleIndex,
            to: point
        )
        onStrokesChanged?(drag.pageIndex, strokes)
        if let bounds = CodmesNoteCanvasModel.bounds(for: strokes[strokeIndex].points) {
            let selection = PDFLassoSelectionSummary(
                pageIndex: drag.pageIndex,
                strokeIds: [drag.strokeId],
                objectIds: [],
                bounds: bounds,
                optionAnchor: optionAnchor(pageIndex: drag.pageIndex, bounds: bounds),
                isMoving: !commit
            )
            lassoSelection = selection
            onLassoSelectionChanged?(selection)
        }
        if commit {
            applyCodmesInkAnnotations(annotations)
        }
    }

    private func macShapeHandles(for stroke: CodmesInkStroke, kind: String) -> [(index: Int, point: CodmesInkPoint)] {
        switch kind {
        case "line":
            guard let first = stroke.points.first, let last = stroke.points.last else { return [] }
            return [(0, first), (1, last)]
        case "polyline":
            return stroke.points.enumerated().map { ($0.offset, $0.element) }
        case "triangle":
            return Array(stroke.points.prefix(3)).enumerated().map { ($0.offset, $0.element) }
        case "rectangle":
            return Array(stroke.points.prefix(4)).enumerated().map { ($0.offset, $0.element) }
        case "circle":
            guard let box = normalizedBounds(for: stroke.points) else { return [] }
            return [
                (0, CodmesInkPoint(x: box.x + box.width / 2, y: box.y, pressure: nil, timeOffset: nil)),
                (1, CodmesInkPoint(x: box.x + box.width, y: box.y + box.height / 2, pressure: nil, timeOffset: nil)),
                (2, CodmesInkPoint(x: box.x + box.width / 2, y: box.y + box.height, pressure: nil, timeOffset: nil)),
                (3, CodmesInkPoint(x: box.x, y: box.y + box.height / 2, pressure: nil, timeOffset: nil))
            ]
        case "ellipse":
            guard let geometry = normalizedEllipseGeometry(from: stroke.points) else { return [] }
            return normalizedEllipseHandlePoints(for: geometry)
        default:
            return []
        }
    }

    private func resizedMacShapeStroke(_ stroke: CodmesInkStroke, kind: String, handleIndex: Int, to point: CodmesInkPoint) -> CodmesInkStroke {
        var next = stroke
        switch kind {
        case "line":
            guard next.points.count >= 2 else { return next }
            if handleIndex == 0 {
                next.points[0] = point
            } else {
                next.points[next.points.count - 1] = point
            }
        case "polyline":
            guard next.points.indices.contains(handleIndex) else { return next }
            next.points[handleIndex] = point
        case "triangle":
            guard next.points.count >= 4, handleIndex < 3 else { return next }
            next.points[handleIndex] = point
            if handleIndex == 0 {
                next.points[next.points.count - 1] = point
            }
        case "rectangle":
            guard let box = normalizedBounds(for: next.points) else { return next }
            let opposite: CodmesInkPoint
            switch handleIndex {
            case 0:
                opposite = CodmesInkPoint(x: box.x + box.width, y: box.y + box.height, pressure: nil, timeOffset: nil)
            case 1:
                opposite = CodmesInkPoint(x: box.x, y: box.y + box.height, pressure: nil, timeOffset: nil)
            case 2:
                opposite = CodmesInkPoint(x: box.x, y: box.y, pressure: nil, timeOffset: nil)
            default:
                opposite = CodmesInkPoint(x: box.x + box.width, y: box.y, pressure: nil, timeOffset: nil)
            }
            next.points = rectanglePoints(from: point, to: opposite)
        case "circle":
            guard let box = normalizedBounds(for: next.points) else { return next }
            let center = CodmesInkPoint(
                x: box.x + box.width / 2,
                y: box.y + box.height / 2,
                pressure: nil,
                timeOffset: nil
            )
            let radius = max(hypot(point.x - center.x, point.y - center.y), 0.005)
            next.points = circlePoints(center: center, radius: radius, count: 48)
        case "ellipse":
            guard let geometry = normalizedEllipseGeometry(from: next.points) else { return next }
            let adjusted = adjustedNormalizedEllipseGeometry(geometry, handleIndex: handleIndex, to: point)
            next.points = ellipsePoints(center: adjusted.center, rx: adjusted.rx, ry: adjusted.ry, angle: adjusted.angle, count: 48)
        default:
            break
        }
        return next
    }

    private func normalizedBounds(for points: [CodmesInkPoint]) -> NormalizedBoundingBox? {
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
        return normalizedBox(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
    }

    private func normalizedBox(minX: Double, minY: Double, maxX: Double, maxY: Double) -> NormalizedBoundingBox {
        let left = max(0, min(1, min(minX, maxX)))
        let right = max(0, min(1, max(minX, maxX)))
        let top = max(0, min(1, min(minY, maxY)))
        let bottom = max(0, min(1, max(minY, maxY)))
        return NormalizedBoundingBox(
            x: left,
            y: top,
            width: max(0.01, right - left),
            height: max(0.01, bottom - top)
        )
    }

    private struct MacNormalizedEllipseGeometry {
        var center: CodmesInkPoint
        var rx: Double
        var ry: Double
        var angle: Double
    }

    private func normalizedEllipseGeometry(from points: [CodmesInkPoint]) -> MacNormalizedEllipseGeometry? {
        let source = openShapePoints(points)
        guard source.count >= 6 else { return nil }
        let centerX = source.reduce(0) { $0 + $1.x } / Double(source.count)
        let centerY = source.reduce(0) { $0 + $1.y } / Double(source.count)
        var xx = 0.0
        var xy = 0.0
        var yy = 0.0
        for point in source {
            let dx = point.x - centerX
            let dy = point.y - centerY
            xx += dx * dx
            xy += dx * dy
            yy += dy * dy
        }
        var angle = 0.5 * atan2(2 * xy, xx - yy)
        let cosA = cos(angle)
        let sinA = sin(angle)
        var rx = 0.005
        var ry = 0.005
        for point in source {
            let dx = point.x - centerX
            let dy = point.y - centerY
            rx = max(rx, abs(dx * cosA + dy * sinA))
            ry = max(ry, abs(-dx * sinA + dy * cosA))
        }
        if ry > rx {
            swap(&rx, &ry)
            angle += Double.pi / 2
        }
        return MacNormalizedEllipseGeometry(
            center: CodmesInkPoint(x: centerX, y: centerY, pressure: nil, timeOffset: nil),
            rx: max(rx, 0.005),
            ry: max(ry, 0.005),
            angle: angle
        )
    }

    private func adjustedNormalizedEllipseGeometry(_ geometry: MacNormalizedEllipseGeometry, handleIndex: Int, to point: CodmesInkPoint) -> MacNormalizedEllipseGeometry {
        let dx = point.x - geometry.center.x
        let dy = point.y - geometry.center.y
        let distanceFromCenter = max(hypot(dx, dy), 0.005)
        let ratio = max(geometry.rx / max(geometry.ry, 0.005), 1.05)
        switch handleIndex {
        case 0:
            return MacNormalizedEllipseGeometry(center: geometry.center, rx: distanceFromCenter * ratio, ry: distanceFromCenter, angle: atan2(dy, dx) + Double.pi / 2)
        case 2:
            return MacNormalizedEllipseGeometry(center: geometry.center, rx: distanceFromCenter * ratio, ry: distanceFromCenter, angle: atan2(dy, dx) - Double.pi / 2)
        case 3:
            return MacNormalizedEllipseGeometry(center: geometry.center, rx: distanceFromCenter, ry: distanceFromCenter / ratio, angle: atan2(dy, dx) + Double.pi)
        default:
            return MacNormalizedEllipseGeometry(center: geometry.center, rx: distanceFromCenter, ry: distanceFromCenter / ratio, angle: atan2(dy, dx))
        }
    }

    private func normalizedEllipseHandlePoints(for geometry: MacNormalizedEllipseGeometry) -> [(Int, CodmesInkPoint)] {
        let cosA = cos(geometry.angle)
        let sinA = sin(geometry.angle)
        let major = (x: cosA * geometry.rx, y: sinA * geometry.rx)
        let minor = (x: -sinA * geometry.ry, y: cosA * geometry.ry)
        return [
            (0, CodmesInkPoint(x: geometry.center.x - minor.x, y: geometry.center.y - minor.y, pressure: nil, timeOffset: nil)),
            (1, CodmesInkPoint(x: geometry.center.x + major.x, y: geometry.center.y + major.y, pressure: nil, timeOffset: nil)),
            (2, CodmesInkPoint(x: geometry.center.x + minor.x, y: geometry.center.y + minor.y, pressure: nil, timeOffset: nil)),
            (3, CodmesInkPoint(x: geometry.center.x - major.x, y: geometry.center.y - major.y, pressure: nil, timeOffset: nil))
        ]
    }

    private func openShapePoints(_ points: [CodmesInkPoint]) -> [CodmesInkPoint] {
        guard points.count > 2,
              let first = points.first,
              let last = points.last,
              hypot(first.x - last.x, first.y - last.y) < 0.0001 else { return points }
        return Array(points.dropLast())
    }

    private func rectanglePoints(from point: CodmesInkPoint, to opposite: CodmesInkPoint) -> [CodmesInkPoint] {
        let box = normalizedBox(minX: point.x, minY: point.y, maxX: opposite.x, maxY: opposite.y)
        let topLeft = CodmesInkPoint(x: box.x, y: box.y, pressure: nil, timeOffset: nil)
        let topRight = CodmesInkPoint(x: box.x + box.width, y: box.y, pressure: nil, timeOffset: nil)
        let bottomRight = CodmesInkPoint(x: box.x + box.width, y: box.y + box.height, pressure: nil, timeOffset: nil)
        let bottomLeft = CodmesInkPoint(x: box.x, y: box.y + box.height, pressure: nil, timeOffset: nil)
        return [topLeft, topRight, bottomRight, bottomLeft, topLeft]
    }

    private func circlePoints(center: CodmesInkPoint, radius: Double, count: Int) -> [CodmesInkPoint] {
        let clampedRadius = max(0.005, min(radius, center.x, 1 - center.x, center.y, 1 - center.y))
        return (0...count).map { index in
            let angle = Double(index) / Double(count) * Double.pi * 2
            return CodmesInkPoint(
                x: center.x + cos(angle) * clampedRadius,
                y: center.y + sin(angle) * clampedRadius,
                pressure: nil,
                timeOffset: nil
            )
        }
    }

    private func ellipsePoints(center: CodmesInkPoint, rx: Double, ry: Double, angle: Double, count: Int) -> [CodmesInkPoint] {
        let maxRadius = max(0.005, min(center.x, 1 - center.x, center.y, 1 - center.y))
        let clampedRX = min(max(rx, 0.005), maxRadius)
        let clampedRY = min(max(ry, 0.005), maxRadius)
        return (0...count).map { index in
            let theta = Double(index) / Double(count) * Double.pi * 2
            let x = cos(theta) * clampedRX
            let y = sin(theta) * clampedRY
            return CodmesInkPoint(
                x: center.x + x * cos(angle) - y * sin(angle),
                y: center.y + x * sin(angle) + y * cos(angle),
                pressure: nil,
                timeOffset: nil
            )
        }
    }

    private func offset(stroke: CodmesInkStroke, dx: Double, dy: Double) -> CodmesInkStroke {
        var next = stroke
        next.points = stroke.points.map {
            CodmesInkPoint(
                x: min(max($0.x + dx, 0), 1),
                y: min(max($0.y + dy, 0), 1),
                pressure: $0.pressure,
                timeOffset: $0.timeOffset
            )
        }
        return next
    }

    private func mergedStrokes(pageIndex: Int, moved: [CodmesInkStroke], selectedIds: Set<String>) -> [CodmesInkStroke] {
        var byId = Dictionary(uniqueKeysWithValues: moved.map { ($0.id, $0) })
        return (annotations?.noteStrokes(pageIndex: pageIndex) ?? []).map { stroke in
            selectedIds.contains(stroke.id) ? (byId.removeValue(forKey: stroke.id) ?? stroke) : stroke
        } + byId.values
    }

    private func optionAnchor(for selection: CodmesNoteSelection) -> CGPoint? {
        optionAnchor(pageIndex: selection.pageIndex, bounds: selection.bounds)
    }

    private func optionAnchor(pageIndex: Int, bounds: AnnotationBoundingBox) -> CGPoint? {
        guard let document,
              let page = document.page(at: pageIndex),
              let box = bounds.normalizedOrSelf else { return nil }
        let pageBounds = page.bounds(for: .mediaBox)
        let top = NSPoint(
            x: pageBounds.minX + pageBounds.width * (box.x + box.width / 2),
            y: pageBounds.minY + pageBounds.height * (1 - box.y)
        )
        let viewPoint = convert(top, from: page)
        return CGPoint(x: viewPoint.x, y: viewPoint.y - 26)
    }

    private func object(at point: CodmesInkPoint, pageIndex: Int) -> PDFAnnotationObject? {
        CodmesNoteCanvasModel.object(at: point, pageIndex: pageIndex, objects: allObjects())
    }

    private func discardEmptyTextObjectIfNeeded(at point: CodmesInkPoint, pageIndex: Int) -> Bool {
        let candidateIds = [selectedObjectId, lassoSelection?.objectIds.first].compactMap { $0 }
        for id in candidateIds {
            guard let object = allObjects().first(where: { $0.id == id }),
                  object.type.lowercased().contains("text"),
                  (object.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            if object.pageIndex == pageIndex,
               let box = object.bbox?.normalizedOrSelf,
               CodmesNoteCanvasModel.contains(point, in: box) {
                return false
            }
            if selectedObjectId == object.id {
                selectedObjectId = nil
            }
            if lassoSelection?.objectIds.contains(object.id) == true {
                lassoSelection = nil
                onLassoSelectionChanged?(nil)
            }
            onObjectDeleted?(object)
            return true
        }
        return false
    }

    private func consumeTextEditingBlurClickIfNeeded(at point: CodmesInkPoint, pageIndex: Int) -> Bool {
        guard tool == .text,
              let selectedObjectId,
              let selectedTextObject = allObjects().first(where: { $0.id == selectedObjectId }),
              selectedTextObject.type.lowercased().contains("text") else { return false }
        if selectedTextObject.pageIndex == pageIndex,
           let box = selectedTextObject.bbox?.normalizedOrSelf,
           CodmesNoteCanvasModel.contains(point, in: box) {
            return false
        }
        if object(at: point, pageIndex: pageIndex) != nil {
            return false
        }
        self.selectedObjectId = nil
        if lassoSelection?.objectIds.contains(selectedTextObject.id) == true {
            lassoSelection = nil
            onLassoSelectionChanged?(nil)
        }
        return true
    }

    private func updateActiveObjectDrag(with viewPoint: NSPoint, event: NSEvent, page: PDFPage, commit: Bool) {
        guard var object = activeObject,
              let startBox = activeObjectStartBox,
              let startPoint = activeObjectStartPoint else { return }
        let current = normalizedPoint(from: viewPoint, event: event, page: page, startTime: event.timestamp)
        let dx = current.x - startPoint.x
        let dy = current.y - startPoint.y
        switch activeObjectInteraction {
        case .move:
            object = CodmesNoteCanvasModel.movedObject(object, from: startBox, deltaX: dx, deltaY: dy)
        case .resize(let edge):
            object = CodmesNoteCanvasModel.resizedObject(
                object,
                from: startBox,
                edge: edge,
                deltaX: dx,
                deltaY: dy
            )
            if object.type.lowercased().contains("text") {
                object = textObjectWithMeasuredHeight(object, page: page)
            }
        }
        if commit {
            onObjectChanged?(object)
        }
    }

    private func textObjectWithMeasuredHeight(_ object: PDFAnnotationObject, page: PDFPage) -> PDFAnnotationObject {
        guard let box = object.bbox?.normalizedOrSelf else { return object }
        let pageBounds = page.bounds(for: .mediaBox)
        let fontSize = CGFloat(Double(object.metadata?["fontSize"] ?? "16") ?? 16)
        let font = NSFont.systemFont(ofSize: fontSize)
        let horizontalInset: CGFloat = 16
        let verticalInset: CGFloat = 14
        let text = object.text?.isEmpty == false ? object.text! : " "
        let width = max(1, pageBounds.width * box.width - horizontalInset)
        let measured = (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        var next = object
        next.bbox = CodmesNoteCanvasModel.clampedBox(
            x: box.x,
            y: box.y,
            width: box.width,
            height: min(1 - box.y, max(0.025, Double((ceil(measured.height) + verticalInset) / max(pageBounds.height, 1))))
        )
        return next
    }

    private func textResizeHandleHit(
        at point: CodmesInkPoint,
        page: PDFPage,
        pageIndex: Int
    ) -> (object: PDFAnnotationObject, edge: CodmesNoteObjectResizeEdge)? {
        guard let selectedObjectId,
              let object = allObjects().first(where: { $0.id == selectedObjectId && $0.pageIndex == pageIndex }),
              object.type.lowercased().contains("text"),
              let box = object.bbox?.normalizedOrSelf else { return nil }
        let pageBounds = page.bounds(for: .mediaBox)
        let handleX = max(0.012, 18 / Double(max(pageBounds.width, 1)))
        let handleY = max(0.025, 26 / Double(max(pageBounds.height, 1)))
        let midY = box.y + box.height / 2
        guard abs(point.y - midY) <= handleY else { return nil }
        if abs(point.x - box.x) <= handleX {
            return (object, .left)
        }
        if abs(point.x - (box.x + box.width)) <= handleX {
            return (object, .right)
        }
        return nil
    }
}
#endif

#if os(macOS)
private extension NSColor {
    convenience init?(hexString: String) {
        let clean = hexString.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard clean.count == 6 else { return nil }
        var value: UInt64 = 0
        guard Scanner(string: clean).scanHexInt64(&value) else { return nil }
        let red = CGFloat((value >> 16) & 0xff) / 255
        let green = CGFloat((value >> 8) & 0xff) / 255
        let blue = CGFloat(value & 0xff) / 255
        self.init(red: red, green: green, blue: blue, alpha: 1)
    }
}
#endif

#if os(iOS)
fileprivate final class AnnotatedPDFView: PDFView {
    var pendingReadingState: PDFReadingState?
    private var readingFitGeneration = 0
    let drawingOverlay = PDFDrawingOverlayView()
    private let shapeDebugLabel = UILabel()
    private var readingMinimumScaleFactor: CGFloat = 1
    private var lastReadingViewportSize = CGSize.zero
    private var observedPinchRecognizers = Set<ObjectIdentifier>()
    private var isApplyingReadingScale = false
    // The keyboard changes the viewport height; that must not reset the reader's zoom.
    var isEditingText = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        drawingOverlay.isUserInteractionEnabled = false
        addSubview(drawingOverlay)
        shapeDebugLabel.isHidden = true
        shapeDebugLabel.numberOfLines = 0
        shapeDebugLabel.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        shapeDebugLabel.textColor = .white
        shapeDebugLabel.backgroundColor = UIColor.black.withAlphaComponent(0.72)
        shapeDebugLabel.layer.cornerRadius = 8
        shapeDebugLabel.layer.masksToBounds = true
        addSubview(shapeDebugLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        drawingOverlay.frame = bounds
        let maxWidth = min(bounds.width - 24, 420)
        shapeDebugLabel.frame = CGRect(x: 12, y: safeAreaInsets.top + 12, width: maxWidth, height: 68)
        bringSubviewToFront(drawingOverlay)
        bringSubviewToFront(shapeDebugLabel)
        applyReadingScaleIfNeeded()
    }

    func applyReadingScaleIfNeeded(force: Bool = false) {
        guard !isApplyingReadingScale,
              !isEditingText,
              let document,
              let page = currentPage ?? document.page(at: 0),
              bounds.width > 1,
              bounds.height > 1,
              force || bounds.size != lastReadingViewportSize,
              let fittedScale = PDFReadingZoom.fittedScale(
                  page: page,
                  displayBox: displayBox,
                  viewport: bounds.size
              ) else {
            installReadingZoomBehavior()
            return
        }

        lastReadingViewportSize = bounds.size
        readingMinimumScaleFactor = fittedScale
        isApplyingReadingScale = true
        autoScales = false
        minScaleFactor = fittedScale * PDFReadingZoom.elasticLowerBoundFraction
        maxScaleFactor = max(fittedScale * 6, 4)
        scaleFactor = fittedScale
        isApplyingReadingScale = false
        installReadingZoomBehavior()
        readingFitGeneration += 1
        let generation = readingFitGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.readingFitGeneration == generation else { return }
            if let state = self.pendingReadingState {
                self.pendingReadingState = nil
                state.restore(self)
            } else {
                self.centerPageVertically(page)
            }
        }
    }

    func centerPageVertically(_ page: PDFPage) {
        guard let scrollView = descendantScrollViews
            .filter({ $0.isScrollEnabled })
            .max(by: { $0.contentSize.height < $1.contentSize.height }) else { return }
        let pageRect = convert(page.bounds(for: displayBox), from: page)
        let delta = pageRect.midY - bounds.midY
        let minimumY = -scrollView.adjustedContentInset.top
        let maximumY = max(
            minimumY,
            scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
        )
        var offset = scrollView.contentOffset
        offset.y = min(max(offset.y + delta, minimumY), maximumY)
        scrollView.setContentOffset(offset, animated: false)
    }

    func finishTextEditingTransition() {
        guard !containsFirstResponder(in: self) else { return }
        // Accept the restored viewport without applying its fitted scale over the user's zoom.
        lastReadingViewportSize = bounds.size
        isEditingText = false
    }

    func centerTextEditor(_ textView: UITextView, aboveKeyboardFrame keyboardFrame: CGRect, duration: TimeInterval) {
        guard let window,
              let scrollView = descendantScrollViews
                .filter({ $0.isScrollEnabled })
                .max(by: { $0.contentSize.height < $1.contentSize.height }) else { return }

        layoutIfNeeded()
        let keyboardFrameInWindow = window.convert(keyboardFrame, from: window.screen.coordinateSpace)
        let keyboardFrameInView = convert(keyboardFrameInWindow, from: window)
        let keyboardIntersection = bounds.intersection(keyboardFrameInView)
        let visibleTop = safeAreaInsets.top
        let visibleBottom = keyboardIntersection.isNull
            ? bounds.maxY - safeAreaInsets.bottom
            : min(bounds.maxY - safeAreaInsets.bottom, keyboardIntersection.minY)
        guard visibleBottom > visibleTop else { return }

        let editorFrame = textView.convert(textView.bounds, to: self)
        let targetCenterY = (visibleTop + visibleBottom) / 2
        let minimumY = -scrollView.adjustedContentInset.top
        let maximumY = max(
            minimumY,
            scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
        )
        var offset = scrollView.contentOffset
        offset.y = min(max(offset.y + editorFrame.midY - targetCenterY, minimumY), maximumY)

        UIView.animate(
            withDuration: max(duration, 0.2),
            delay: 0,
            options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseInOut]
        ) {
            scrollView.setContentOffset(offset, animated: false)
        }
    }

    private func containsFirstResponder(in view: UIView) -> Bool {
        if view is UITextView, view.isFirstResponder { return true }
        return view.subviews.contains { containsFirstResponder(in: $0) }
    }

    private func installReadingZoomBehavior() {
        for scrollView in descendantScrollViews where scrollView.isScrollEnabled {
            scrollView.bouncesZoom = false
            guard let pinch = scrollView.pinchGestureRecognizer else { continue }
            let identifier = ObjectIdentifier(pinch)
            guard observedPinchRecognizers.insert(identifier).inserted else { continue }
            pinch.addTarget(self, action: #selector(handleReadingPinch(_:)))
        }
    }

    @objc private func handleReadingPinch(_ gesture: UIPinchGestureRecognizer) {
        guard gesture.state == .ended || gesture.state == .cancelled,
              scaleFactor < readingMinimumScaleFactor else { return }
        UIView.animate(
            withDuration: 0.22,
            delay: 0,
            options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseInOut]
        ) {
            self.scaleFactor = self.readingMinimumScaleFactor
            self.layoutIfNeeded()
        }
    }

    func showShapeDebug(_ text: String) {
        shapeDebugLabel.text = "  \(text)"
        shapeDebugLabel.isHidden = false
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(hideShapeDebug), object: nil)
        perform(#selector(hideShapeDebug), with: nil, afterDelay: 4)
    }

    @objc private func hideShapeDebug() {
        shapeDebugLabel.isHidden = true
    }
}

fileprivate final class PDFImmediateDrawingGestureRecognizer: UIGestureRecognizer {
    var maximumNumberOfTouches = 1
    private var activeTouch: UITouch?
    private var currentSamples: [UITouch] = []

    func locations(in view: UIView) -> [CGPoint] {
        let samples = currentSamples.isEmpty ? activeTouch.map { [$0] } ?? [] : currentSamples
        return samples.map { $0.location(in: view) }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard activeTouch == nil else {
            state = .cancelled
            return
        }
        guard touches.count <= maximumNumberOfTouches,
              let touch = touches.first else {
            state = .failed
            return
        }
        activeTouch = touch
        currentSamples = [touch]
        state = .began
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let activeTouch, touches.contains(activeTouch) else { return }
        currentSamples = event.coalescedTouches(for: activeTouch) ?? [activeTouch]
        state = .changed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let activeTouch, touches.contains(activeTouch) else { return }
        currentSamples = event.coalescedTouches(for: activeTouch) ?? [activeTouch]
        state = .ended
        self.activeTouch = nil
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let activeTouch, touches.contains(activeTouch) else { return }
        currentSamples = []
        state = .cancelled
        self.activeTouch = nil
    }

    override func reset() {
        activeTouch = nil
        currentSamples = []
    }
}

fileprivate final class PDFDrawingOverlayView: UIView {
    var strokeColor = UIColor.black
    var lineWidth: CGFloat = 2.5
    var isDashed = false
    private var path: UIBezierPath?
    private(set) var points: [CGPoint] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func begin(at point: CGPoint) {
        let nextPath = UIBezierPath()
        nextPath.lineCapStyle = .round
        nextPath.lineJoinStyle = .round
        nextPath.lineWidth = lineWidth
        nextPath.move(to: point)
        path = nextPath
        points = [point]
        setNeedsDisplay()
    }

    func move(to point: CGPoint) {
        guard let path else { return }
        if let previous = points.last {
            let mid = CGPoint(x: (previous.x + point.x) / 2, y: (previous.y + point.y) / 2)
            path.addQuadCurve(to: mid, controlPoint: previous)
        } else {
            path.move(to: point)
        }
        points.append(point)
        setNeedsDisplay()
    }

    func replace(with nextPoints: [CGPoint]) {
        guard let first = nextPoints.first else {
            cancel()
            return
        }
        let nextPath = UIBezierPath()
        nextPath.lineCapStyle = .round
        nextPath.lineJoinStyle = .round
        nextPath.lineWidth = lineWidth
        nextPath.move(to: first)
        for point in nextPoints.dropFirst() {
            nextPath.addLine(to: point)
        }
        path = nextPath
        points = nextPoints
        setNeedsDisplay()
    }

    func finish() -> [CGPoint] {
        let result = points
        path = nil
        points = []
        setNeedsDisplay()
        return result
    }

    func cancel() {
        path = nil
        points = []
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let path else { return }
        strokeColor.setStroke()
        path.lineWidth = lineWidth
        if isDashed {
            path.setLineDash([7, 5], count: 2, phase: 0)
        } else {
            path.setLineDash([], count: 0, phase: 0)
        }
        path.stroke()
    }
}

private extension UIView {
    var isInShapeHandleHierarchy: Bool {
        if self is PDFShapeHandleView {
            return true
        }
        return superview?.isInShapeHandleHierarchy == true
    }

    var descendantScrollViews: [UIScrollView] {
        var result: [UIScrollView] = []
        if let scrollView = self as? UIScrollView {
            result.append(scrollView)
        }
        for subview in subviews {
            result.append(contentsOf: subview.descendantScrollViews)
        }
        return result
    }
}

fileprivate final class PDFPageAnnotationOverlay: UIView {
    let canvas = PKCanvasView()
    let shapePreviewLayer = CAShapeLayer()
    let selectionOutlineLayer = CAShapeLayer()
    let lassoMovePreviewLayer = CAShapeLayer()
    var objectViews: [String: UIView] = [:]
    var shapeHandleViews: [UIView] = []
    var textResizeHandleViews: [UIView] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = true
        backgroundColor = .clear
        isOpaque = false
        canvas.isUserInteractionEnabled = true
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.alwaysBounceVertical = false
        canvas.alwaysBounceHorizontal = false
        canvas.isScrollEnabled = false
        canvas.delaysContentTouches = false
        canvas.minimumZoomScale = 1
        canvas.maximumZoomScale = 1
        addSubview(canvas)
        shapePreviewLayer.fillColor = UIColor.clear.cgColor
        shapePreviewLayer.lineCap = .round
        shapePreviewLayer.lineJoin = .round
        layer.addSublayer(shapePreviewLayer)
        shapePreviewLayer.actions = [
            "path": NSNull(),
            "position": NSNull(),
            "bounds": NSNull(),
            "opacity": NSNull()
        ]
        selectionOutlineLayer.fillColor = UIColor.clear.cgColor
        selectionOutlineLayer.strokeColor = UIColor.systemOrange.cgColor
        selectionOutlineLayer.lineWidth = 1.5
        selectionOutlineLayer.lineDashPattern = [7, 5]
        selectionOutlineLayer.lineCap = .round
        selectionOutlineLayer.lineJoin = .round
        layer.addSublayer(selectionOutlineLayer)
        selectionOutlineLayer.actions = [
            "path": NSNull(),
            "position": NSNull(),
            "bounds": NSNull(),
            "opacity": NSNull()
        ]
        lassoMovePreviewLayer.fillColor = UIColor.clear.cgColor
        lassoMovePreviewLayer.lineCap = .round
        lassoMovePreviewLayer.lineJoin = .round
        layer.addSublayer(lassoMovePreviewLayer)
        lassoMovePreviewLayer.actions = [
            "sublayers": NSNull(),
            "position": NSNull(),
            "bounds": NSNull(),
            "opacity": NSNull()
        ]
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        canvas.frame = bounds
        canvas.contentSize = bounds.size
        shapePreviewLayer.frame = bounds
        selectionOutlineLayer.frame = bounds
        lassoMovePreviewLayer.frame = bounds
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isUserInteractionEnabled, !isHidden, alpha > 0.01 else { return nil }
        for handle in textResizeHandleViews.reversed() {
            guard !handle.isHidden, handle.alpha > 0.01, handle.isUserInteractionEnabled else { continue }
            let handlePoint = handle.convert(point, from: self)
            if handle.point(inside: handlePoint, with: event) {
                return handle.hitTest(handlePoint, with: event)
            }
        }
        for handle in shapeHandleViews.reversed() {
            guard !handle.isHidden, handle.alpha > 0.01, handle.isUserInteractionEnabled else { continue }
            let handlePoint = handle.convert(point, from: self)
            if handle.point(inside: handlePoint, with: event) {
                return handle.hitTest(handlePoint, with: event)
            }
        }
        return super.hitTest(point, with: event)
    }
}

fileprivate final class PDFShapeHandleView: UIView {
    private enum Metrics {
        static let hitSize: CGFloat = 40
        static let dotSize: CGFloat = 8
    }

    let strokeId: String
    let kind: String
    let handleIndex: Int
    private let dotView = UIView()

    init(strokeId: String, kind: String, handleIndex: Int) {
        self.strokeId = strokeId
        self.kind = kind
        self.handleIndex = handleIndex
        super.init(frame: CGRect(x: 0, y: 0, width: Metrics.hitSize, height: Metrics.hitSize))
        backgroundColor = .clear
        isUserInteractionEnabled = true

        dotView.frame = CGRect(x: 0, y: 0, width: Metrics.dotSize, height: Metrics.dotSize)
        dotView.backgroundColor = .systemBackground
        dotView.layer.borderColor = UIColor.systemOrange.cgColor
        dotView.layer.borderWidth = 1
        dotView.layer.cornerRadius = Metrics.dotSize / 2
        dotView.layer.shadowColor = UIColor.black.cgColor
        dotView.layer.shadowOpacity = 0.18
        dotView.layer.shadowRadius = 3
        dotView.layer.shadowOffset = CGSize(width: 0, height: 1)
        dotView.isUserInteractionEnabled = false
        addSubview(dotView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        dotView.center = CGPoint(x: bounds.midX, y: bounds.midY)
    }
}

fileprivate final class PDFTextResizeHandleView: UIView {
    enum Edge {
        case left
        case right
    }

    private enum Metrics {
        static let hitWidth: CGFloat = 34
        static let hitHeight: CGFloat = 44
        static let gripWidth: CGFloat = 4
        static let gripHeight: CGFloat = 22
    }

    let objectId: String
    let edge: Edge
    private let gripView = UIView()

    init(objectId: String, edge: Edge) {
        self.objectId = objectId
        self.edge = edge
        super.init(frame: CGRect(x: 0, y: 0, width: Metrics.hitWidth, height: Metrics.hitHeight))
        backgroundColor = .clear
        isUserInteractionEnabled = true

        gripView.frame = CGRect(x: 0, y: 0, width: Metrics.gripWidth, height: Metrics.gripHeight)
        gripView.backgroundColor = .systemGray
        gripView.layer.cornerRadius = Metrics.gripWidth / 2
        gripView.layer.borderColor = UIColor.systemBackground.withAlphaComponent(0.85).cgColor
        gripView.layer.borderWidth = 1
        gripView.center = CGPoint(x: bounds.midX, y: bounds.midY)
        addSubview(gripView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        gripView.center = CGPoint(x: bounds.midX, y: bounds.midY)
    }
}

private struct AnnotatedPDFKitView: UIViewRepresentable {
    let url: URL
    var documentOverride: PDFDocument?
    var documentRevision: Int
    var forceDocumentReload: Bool
    var readingState: PDFReadingState?
    var onSaveReadingState: (PDFReadingState) -> Void
    var annotations: PDFAnnotationDocument?
    var focus: PDFDocumentFocus?
    var tool: PDFMarkupTool
    var isWritingMode: Bool
    var penColorHex: String
    var penWidth: Double
    var eraserWidth: Double
    var selectedObjectId: String?
    var lassoSelection: PDFLassoSelectionSummary?
    var textEditRequest: Int
    var onCurrentPageChanged: (Int) -> Void
    var onStrokeFinished: (Int, CodmesInkStroke) -> Void
    var onStrokesChanged: (Int, [CodmesInkStroke]) -> Void
    var onObjectSelected: (PDFAnnotationObject) -> Void
    var onObjectChanged: (PDFAnnotationObject) -> Void
    var onObjectDeleted: (PDFAnnotationObject) -> Void
    var onLassoSelectionChanged: (PDFLassoSelectionSummary?) -> Void
    var onFocusCleared: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onCurrentPageChanged: onCurrentPageChanged,
            onStrokeFinished: onStrokeFinished,
            onStrokesChanged: onStrokesChanged,
            onObjectSelected: onObjectSelected,
            onObjectChanged: onObjectChanged,
            onObjectDeleted: onObjectDeleted,
            onLassoSelectionChanged: onLassoSelectionChanged,
            onFocusCleared: onFocusCleared
        )
    }

    func makeUIView(context: Context) -> AnnotatedPDFView {
        let view = AnnotatedPDFView()
        view.autoScales = false
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.pageBreakMargins = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        view.backgroundColor = .clear
        view.pageOverlayViewProvider = context.coordinator
        let drawGesture = PDFImmediateDrawingGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDrawingPan(_:)))
        drawGesture.maximumNumberOfTouches = 1
        drawGesture.cancelsTouchesInView = true
        drawGesture.delegate = context.coordinator
        view.addGestureRecognizer(drawGesture)
        let textResizePan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTextResizePan(_:)))
        textResizePan.maximumNumberOfTouches = 1
        textResizePan.cancelsTouchesInView = true
        textResizePan.delegate = context.coordinator
        textResizePan.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue),
            NSNumber(value: UITouch.TouchType.pencil.rawValue)
        ]
        view.addGestureRecognizer(textResizePan)
        let objectMovePan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePDFObjectPan(_:)))
        objectMovePan.maximumNumberOfTouches = 1
        objectMovePan.cancelsTouchesInView = true
        objectMovePan.delegate = context.coordinator
        view.addGestureRecognizer(objectMovePan)
        let objectEditTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePDFObjectDoubleTap(_:)))
        objectEditTap.numberOfTapsRequired = 2
        objectEditTap.cancelsTouchesInView = false
        objectEditTap.delegate = context.coordinator
        view.addGestureRecognizer(objectEditTap)
        let clearSelectionTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePDFTap(_:)))
        clearSelectionTap.cancelsTouchesInView = false
        clearSelectionTap.delegate = context.coordinator
        clearSelectionTap.require(toFail: objectEditTap)
        view.addGestureRecognizer(clearSelectionTap)
        context.coordinator.drawingGesture = drawGesture
        context.coordinator.textResizePanGesture = textResizePan
        context.coordinator.objectMovePanGesture = objectMovePan
        context.coordinator.objectEditTapGesture = objectEditTap
        context.coordinator.clearSelectionTapGesture = clearSelectionTap
        context.coordinator.pdfView = view
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.visiblePageChanged(_:)),
            name: Notification.Name.PDFViewPageChanged,
            object: view
        )
        return view
    }

    func updateUIView(_ view: AnnotatedPDFView, context: Context) {
        context.coordinator.onSaveReadingState = onSaveReadingState
        context.coordinator.onCurrentPageChanged = onCurrentPageChanged
        context.coordinator.onStrokeFinished = onStrokeFinished
        context.coordinator.onStrokesChanged = onStrokesChanged
        context.coordinator.onObjectSelected = onObjectSelected
        context.coordinator.onObjectChanged = onObjectChanged
        context.coordinator.onObjectDeleted = onObjectDeleted
        context.coordinator.onLassoSelectionChanged = onLassoSelectionChanged
        context.coordinator.onFocusCleared = onFocusCleared
        context.coordinator.annotations = annotations
        context.coordinator.focus = focus
        context.coordinator.tool = tool
        context.coordinator.isWritingMode = isWritingMode
        context.coordinator.penColorHex = penColorHex
        context.coordinator.penWidth = penWidth
        context.coordinator.eraserWidth = eraserWidth
        context.coordinator.selectedObjectId = selectedObjectId
        context.coordinator.syncExternalLassoSelection(lassoSelection)
        if let documentOverride {
            if view.document !== documentOverride {
                context.coordinator.currentURL = url
                context.coordinator.overlays.removeAll()
                view.document = documentOverride
                view.pendingReadingState = readingState
                view.applyReadingScaleIfNeeded(force: true)
                context.coordinator.documentRevision = documentRevision
            } else if context.coordinator.documentRevision != documentRevision {
                context.coordinator.documentRevision = documentRevision
                if forceDocumentReload {
                    let pageIndex = view.currentPage.flatMap { view.document?.index(for: $0) }
                    let scale = view.scaleFactor
                    context.coordinator.overlays.removeAll()
                    view.document = nil
                    view.document = documentOverride
                    view.scaleFactor = scale
                    if let pageIndex, let page = documentOverride.page(at: pageIndex) {
                        view.go(to: page)
                    }
                } else {
                    view.layoutDocumentView()
                }
            }
        } else if context.coordinator.currentURL != url {
            context.coordinator.currentURL = url
            context.coordinator.overlays.removeAll()
            view.document = PDFDocument(url: url)
            view.pendingReadingState = readingState
            view.applyReadingScaleIfNeeded(force: true)
        } else if view.document == nil {
            view.document = PDFDocument(url: url)
            view.pendingReadingState = readingState
            view.applyReadingScaleIfNeeded(force: true)
        }
        context.coordinator.applyToolToVisibleOverlays()
        context.coordinator.applyPDFNavigationMode()
        context.coordinator.applyCodmesInkAnnotations()
        context.coordinator.applyAnnotationsToVisibleOverlays()
        context.coordinator.applyTextEditRequest(textEditRequest)
        context.coordinator.applyFocus()
        if let current = view.currentPage, let index = view.document?.index(for: current), index >= 0 {
            onCurrentPageChanged(index)
        }
    }

    static func dismantleUIView(_ view: AnnotatedPDFView, coordinator: Coordinator) {
        if let state = PDFReadingState.capture(view) { coordinator.onSaveReadingState?(state) }
        NotificationCenter.default.removeObserver(coordinator)
    }

    final class Coordinator: NSObject, @preconcurrency PDFPageOverlayViewProvider, UIGestureRecognizerDelegate, UITextViewDelegate {
        private struct LassoSelection {
            var pageIndex: Int
            var strokeIds: Set<String>
            var objectIds: Set<String>
            var bounds: AnnotationBoundingBox
            var outline: [CodmesInkPoint]
        }

        private enum LassoInteraction {
            case drawing
            case moving
        }

        private typealias ShapeFit = PDFShapeFit
        private typealias ShapeRecognitionDebug = PDFShapeRecognitionDebug

        private struct ShapeCandidate {
            var fit: ShapeFit
            var score: CGFloat
        }

        private struct ShapeTemplate {
            var kind: String
            var points: [CGPoint]
            var isClosed: Bool
        }

        private struct ShapeHandleDrag {
            var pageIndex: Int
            var strokeId: String
            var kind: String
            var handleIndex: Int
        }

        private struct EllipseGeometry {
            var center: CGPoint
            var rx: CGFloat
            var ry: CGFloat
            var angle: CGFloat
        }

        private struct NormalizedEllipseGeometry {
            var center: CodmesInkPoint
            var rx: Double
            var ry: Double
            var angle: Double
        }

        weak var pdfView: AnnotatedPDFView?
        var onSaveReadingState: ((PDFReadingState) -> Void)?
        weak var drawingGesture: PDFImmediateDrawingGestureRecognizer?
        weak var textResizePanGesture: UIPanGestureRecognizer?
        weak var objectMovePanGesture: UIPanGestureRecognizer?
        weak var objectEditTapGesture: UITapGestureRecognizer?
        weak var clearSelectionTapGesture: UITapGestureRecognizer?
        var currentURL: URL?
        var documentRevision = -1
        var annotations: PDFAnnotationDocument?
        var focus: PDFDocumentFocus?
        var tool: PDFMarkupTool = .pen
        var isWritingMode = false
        var penColorHex = "#111111"
        var penWidth = 2.5
        var eraserWidth = 18.0
        var selectedObjectId: String?
        var onCurrentPageChanged: (Int) -> Void
        var onStrokeFinished: (Int, CodmesInkStroke) -> Void
        var onStrokesChanged: (Int, [CodmesInkStroke]) -> Void
        var onObjectSelected: (PDFAnnotationObject) -> Void
        var onObjectChanged: (PDFAnnotationObject) -> Void
        var onObjectDeleted: (PDFAnnotationObject) -> Void
        var onLassoSelectionChanged: (PDFLassoSelectionSummary?) -> Void
        var onFocusCleared: () -> Void
        var overlays: [Int: PDFPageAnnotationOverlay] = [:]
        private var highlightViews: [Int: UIView] = [:]
        private var lastFocusKey = ""
        private var applyingProgrammaticDrawing = false
        private var activePage: PDFPage?
        private var activePageIndex: Int?
        private var activeStartTime: TimeInterval = 0
        private var didLockScrollForDrawing = false
        private var shapeHoldWorkItem: DispatchWorkItem?
        private var activeShapeFit: ShapeFit?
        private var lastShapeRecognitionDebug: ShapeRecognitionDebug?
        private var activeShapeDragHandleIndex: Int?
        private var activeShapeHandleDrag: ShapeHandleDrag?
        private var activeShapeHandleStartStroke: CodmesInkStroke?
        private var lastPenPointTime: TimeInterval = 0
        private var lastPenOverlayPoint: CGPoint?
        private var activeEraserPageIndex: Int?
        private var activeEraserStrokes: [CodmesInkStroke] = []
        private var lastEraserPoint: CodmesInkPoint?
        private var lassoInteraction: LassoInteraction?
        private var lassoSelection: LassoSelection?
        private var lassoMoveStartSelection: LassoSelection?
        private var lassoMoveStartPoint: CodmesInkPoint?
        private var lassoMoveStartStrokes: [CodmesInkStroke] = []
        private var lassoMoveStartObjects: [PDFAnnotationObject] = []
        private var activeObjectMoveId: String?
        private var activeObjectMovePageIndex: Int?
        private var activeTextResizeObjectId: String?
        private var activeTextResizePageIndex: Int?
        private var activeTextResizeEdge: PDFTextResizeHandleView.Edge?
        private var editingTextObjectId: String?
        private var pendingFocusTextObjectId: String?
        private weak var activeTextView: UITextView?
        private var lastKeyboardFrame: CGRect?
        private var lastTextEditRequest = 0
        private let textDraftMetadataKey = "draft"
        private let textManualWidthMetadataKey = "manualWidth"

        init(
            onCurrentPageChanged: @escaping (Int) -> Void,
            onStrokeFinished: @escaping (Int, CodmesInkStroke) -> Void,
            onStrokesChanged: @escaping (Int, [CodmesInkStroke]) -> Void,
            onObjectSelected: @escaping (PDFAnnotationObject) -> Void,
            onObjectChanged: @escaping (PDFAnnotationObject) -> Void,
            onObjectDeleted: @escaping (PDFAnnotationObject) -> Void,
            onLassoSelectionChanged: @escaping (PDFLassoSelectionSummary?) -> Void,
            onFocusCleared: @escaping () -> Void
        ) {
            self.onCurrentPageChanged = onCurrentPageChanged
            self.onStrokeFinished = onStrokeFinished
            self.onStrokesChanged = onStrokesChanged
            self.onObjectSelected = onObjectSelected
            self.onObjectChanged = onObjectChanged
            self.onObjectDeleted = onObjectDeleted
            self.onLassoSelectionChanged = onLassoSelectionChanged
            self.onFocusCleared = onFocusCleared
            super.init()
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(keyboardDidHide(_:)),
                name: UIResponder.keyboardDidHideNotification,
                object: nil
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(keyboardWillChangeFrame(_:)),
                name: UIResponder.keyboardWillChangeFrameNotification,
                object: nil
            )
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        @objc func visiblePageChanged(_ notification: Notification) {
            guard let pdfView, let page = pdfView.currentPage, let index = pdfView.document?.index(for: page), index >= 0 else { return }
            onCurrentPageChanged(index)
        }

        @objc private func keyboardDidHide(_ notification: Notification) {
            lastKeyboardFrame = nil
            pdfView?.finishTextEditingTransition()
        }

        @objc private func keyboardWillChangeFrame(_ notification: Notification) {
            guard let pdfView,
                  let textView = activeTextView,
                  let keyboardFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
                  let screenMaxY = pdfView.window?.screen.bounds.maxY,
                  keyboardFrame.minY < screenMaxY else { return }
            lastKeyboardFrame = keyboardFrame
            let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? TimeInterval ?? 0.25
            DispatchQueue.main.async { [weak pdfView, weak textView] in
                guard let pdfView, let textView else { return }
                pdfView.centerTextEditor(textView, aboveKeyboardFrame: keyboardFrame, duration: duration)
            }
        }

        func syncExternalLassoSelection(_ external: PDFLassoSelectionSummary?) {
            if external == nil, lassoSelection != nil {
                if let selectedObjectId, lassoSelection?.objectIds.contains(selectedObjectId) == true {
                    return
                }
                clearLassoSelection(notify: false)
            }
        }

        func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
            guard let document = view.document else { return nil }
            let pageIndex = document.index(for: page)
            if let existing = overlays[pageIndex] {
                return existing
            }

            let overlay = PDFPageAnnotationOverlay()
            overlay.canvas.drawingPolicy = .anyInput
            overlay.canvas.isUserInteractionEnabled = false
            overlays[pageIndex] = overlay
            applyCodmesInkAnnotations(pageIndex: pageIndex)
            applyTool(to: overlay)
            applyAnnotation(to: overlay.canvas, pageIndex: pageIndex)
            applyObjects(to: overlay, pageIndex: pageIndex)
            applyHighlight(to: overlay, pageIndex: pageIndex)
            applyLassoSelectionOutline(to: overlay, pageIndex: pageIndex)
            applyShapeHandles(to: overlay, pageIndex: pageIndex)
            applyTextResizeHandles(to: overlay, pageIndex: pageIndex)
            return overlay
        }

        func pdfView(_ pdfView: PDFView, willDisplayOverlayView overlayView: UIView, for page: PDFPage) {
            guard let overlay = overlayView as? PDFPageAnnotationOverlay,
                  let pageIndex = pdfView.document?.index(for: page) else { return }
            overlays[pageIndex] = overlay
            applyCodmesInkAnnotations(pageIndex: pageIndex)
            applyTool(to: overlay)
            applyAnnotation(to: overlay.canvas, pageIndex: pageIndex)
            applyObjects(to: overlay, pageIndex: pageIndex)
            applyHighlight(to: overlay, pageIndex: pageIndex)
            applyLassoSelectionOutline(to: overlay, pageIndex: pageIndex)
            applyShapeHandles(to: overlay, pageIndex: pageIndex)
            applyTextResizeHandles(to: overlay, pageIndex: pageIndex)
        }

        func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage) {
            guard let pageIndex = pdfView.document?.index(for: page) else { return }
            clearCodmesInkAnnotations(pageIndex: pageIndex)
            highlightViews[pageIndex]?.removeFromSuperview()
            highlightViews[pageIndex] = nil
            overlays[pageIndex] = nil
        }

        func applyToolToVisibleOverlays() {
            for overlay in overlays.values {
                applyTool(to: overlay)
            }
        }

        func applyPDFNavigationMode() {
            guard let pdfView else { return }
            let navigationEnabled = !isWritingMode
            pdfView.isInMarkupMode = false
            pdfView.drawingOverlay.isHidden = navigationEnabled
            pdfView.drawingOverlay.strokeColor = tool == .lasso ? .systemOrange : UIColor(hexString: penColorHex)
            pdfView.drawingOverlay.lineWidth = CGFloat(tool == .lasso ? 1.5 : (tool == .eraser ? eraserWidth : penWidth))
            pdfView.drawingOverlay.isDashed = tool == .lasso
            drawingGesture?.isEnabled = !navigationEnabled && tool != .text
            applyPDFScrollTouchPolicy()
        }

        private func applyPDFScrollTouchPolicy() {
            guard let pdfView else { return }
            let directTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            let readingTouchTypes = [
                NSNumber(value: UITouch.TouchType.direct.rawValue),
                NSNumber(value: UITouch.TouchType.pencil.rawValue)
            ]
            let shouldReservePencilForDrawing = UIDevice.current.userInterfaceIdiom == .pad
                && isWritingMode
                && (tool == .pen || tool == .eraser || tool == .lasso)
            let shouldReserveSingleTouchForDrawing = UIDevice.current.userInterfaceIdiom != .pad
                && isWritingMode
                && (tool == .pen || tool == .eraser || tool == .lasso)
            if shouldReservePencilForDrawing {
                drawingGesture?.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
                for scrollView in pdfView.descendantScrollViews {
                    scrollView.isScrollEnabled = true
                    scrollView.panGestureRecognizer.minimumNumberOfTouches = 1
                    scrollView.panGestureRecognizer.allowedTouchTypes = directTouchTypes
                    scrollView.pinchGestureRecognizer?.allowedTouchTypes = directTouchTypes
                }
            } else if shouldReserveSingleTouchForDrawing {
                drawingGesture?.allowedTouchTypes = directTouchTypes
                for scrollView in pdfView.descendantScrollViews {
                    scrollView.isScrollEnabled = true
                    scrollView.panGestureRecognizer.minimumNumberOfTouches = 2
                    scrollView.panGestureRecognizer.allowedTouchTypes = directTouchTypes
                    scrollView.pinchGestureRecognizer?.allowedTouchTypes = directTouchTypes
                }
            } else {
                drawingGesture?.allowedTouchTypes = readingTouchTypes
                for scrollView in pdfView.descendantScrollViews {
                    scrollView.isScrollEnabled = true
                    scrollView.panGestureRecognizer.minimumNumberOfTouches = 1
                    scrollView.panGestureRecognizer.allowedTouchTypes = readingTouchTypes
                    scrollView.pinchGestureRecognizer?.allowedTouchTypes = readingTouchTypes
                }
            }
        }

        func applyAnnotationsToVisibleOverlays() {
            for (pageIndex, overlay) in overlays {
                applyAnnotation(to: overlay.canvas, pageIndex: pageIndex)
                applyObjects(to: overlay, pageIndex: pageIndex)
                applyHighlight(to: overlay, pageIndex: pageIndex)
                applyLassoSelectionOutline(to: overlay, pageIndex: pageIndex)
                applyShapeHandles(to: overlay, pageIndex: pageIndex)
                applyTextResizeHandles(to: overlay, pageIndex: pageIndex)
            }
        }

        func applyFocus() {
            guard let pdfView, let document = pdfView.document, let focus else { return }
            let key = "\(focus.requestId.uuidString):\(focus.path):\(focus.page ?? -1):\(focus.bbox?.x ?? -1):\(focus.bbox?.y ?? -1)"
            if key != lastFocusKey, let page = focus.page, page > 0, page <= document.pageCount, let pdfPage = document.page(at: page - 1) {
                lastFocusKey = key
                navigateToFocusedPage(pdfPage, in: pdfView)
            }
            for (pageIndex, overlay) in overlays {
                applyHighlight(to: overlay, pageIndex: pageIndex)
            }
        }

        private func navigateToFocusedPage(_ page: PDFPage, in pdfView: PDFView) {
            pdfView.go(to: page)
            (pdfView as? AnnotatedPDFView)?.centerPageVertically(page)
            for delay in [0.05, 0.18] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak pdfView] in
                    pdfView?.go(to: page)
                    (pdfView as? AnnotatedPDFView)?.centerPageVertically(page)
                }
            }
        }

        private func clearSearchFocusIfNeeded() {
            guard focus != nil else { return }
            focus = nil
            lastFocusKey = ""
            for highlightView in highlightViews.values {
                highlightView.removeFromSuperview()
            }
            highlightViews.removeAll()
            onFocusCleared()
        }

        private func applyTool(to overlay: PDFPageAnnotationOverlay) {
            let canAdjustShape = selectedShapeStroke(pageIndex: overlayPageIndex(for: overlay)) != nil
            overlay.isUserInteractionEnabled = isWritingMode && (tool == .lasso || tool == .text || canAdjustShape)
            overlay.canvas.isUserInteractionEnabled = false
            for view in overlay.objectViews.values {
                view.isUserInteractionEnabled = isWritingMode && (tool == .lasso || tool == .text)
            }
            for handle in overlay.shapeHandleViews {
                handle.isUserInteractionEnabled = isWritingMode
            }
            for handle in overlay.textResizeHandleViews {
                handle.isUserInteractionEnabled = isWritingMode
            }
            applyTool(to: overlay.canvas)
        }

        private func applyTool(to canvas: PKCanvasView) {
            canvas.isUserInteractionEnabled = false
            switch tool {
            case .pen:
                canvas.tool = PKInkingTool(.pen, color: UIColor(hexString: penColorHex), width: CGFloat(penWidth))
            case .eraser:
                canvas.tool = PKEraserTool(.vector, width: CGFloat(eraserWidth))
            case .lasso:
                canvas.tool = PKLassoTool()
            case .text:
                break
            }

            // Drawing is handled by PDFImmediateDrawingGestureRecognizer, so the
            // canvas must not take focus from text fields presented above the PDF.
            if canvas.isFirstResponder {
                canvas.resignFirstResponder()
            }
        }

        private func overlayPageIndex(for overlay: PDFPageAnnotationOverlay) -> Int? {
            overlays.first(where: { $0.value === overlay })?.key
        }

        private func currentPageIndex() -> Int? {
            guard let pdfView, let page = pdfView.currentPage, let index = pdfView.document?.index(for: page), index >= 0 else { return nil }
            return index
        }

        func applyCodmesInkAnnotations() {
            for pageIndex in overlays.keys {
                applyCodmesInkAnnotations(pageIndex: pageIndex)
            }
        }

        private func clearCodmesInkAnnotations(pageIndex: Int) {
            guard let page = pdfView?.document?.page(at: pageIndex) else { return }
            for annotation in page.annotations where annotation.contents?.hasPrefix("codmes-ink-") == true {
                page.removeAnnotation(annotation)
            }
        }

        private func applyCodmesInkAnnotations(pageIndex: Int) {
            guard let page = pdfView?.document?.page(at: pageIndex) else { return }
            clearCodmesInkAnnotations(pageIndex: pageIndex)
            guard let annotations else { return }
            let strokes = annotations.noteStrokes(pageIndex: pageIndex)
            let hiddenStrokeIds = movingLassoStrokeIds(pageIndex: pageIndex)
                .union(activeShapeHandleStrokeIds(pageIndex: pageIndex))
            for stroke in strokes {
                guard !hiddenStrokeIds.contains(stroke.id) else { continue }
                addInkPreview(stroke, to: page, contentsPrefix: "codmes-ink-preview")
            }
        }

        private func movingLassoStrokeIds(pageIndex: Int) -> Set<String> {
            guard lassoInteraction == .moving,
                  lassoMoveStartSelection?.pageIndex == pageIndex else { return [] }
            return lassoMoveStartSelection?.strokeIds ?? []
        }

        private func activeShapeHandleStrokeIds(pageIndex: Int) -> Set<String> {
            guard let drag = activeShapeHandleDrag,
                  drag.pageIndex == pageIndex else { return [] }
            return [drag.strokeId]
        }

        private func removeCodmesInkAnnotation(id: String, from page: PDFPage) {
            for annotation in page.annotations where annotation.contents?.hasSuffix(":\(id)") == true {
                page.removeAnnotation(annotation)
            }
        }

        @objc func handleDrawingPan(_ gesture: UIGestureRecognizer) {
            guard let pdfView else { return }
            let viewPoint = gesture.location(in: pdfView)
            let overlayPoint = gesture.location(in: pdfView.drawingOverlay)
            let overlaySamples = (gesture as? PDFImmediateDrawingGestureRecognizer)?.locations(in: pdfView.drawingOverlay) ?? [overlayPoint]
            let viewSamples = (gesture as? PDFImmediateDrawingGestureRecognizer)?.locations(in: pdfView) ?? [viewPoint]

            switch gesture.state {
            case .began:
                guard tool == .pen || tool == .eraser || tool == .lasso,
                      let page = pdfView.page(for: viewPoint, nearest: true),
                      let document = pdfView.document else { return }
                let pageIndex = document.index(for: page)
                guard pageIndex >= 0 else { return }
                activePage = page
                activePageIndex = pageIndex
                activeStartTime = ProcessInfo.processInfo.systemUptime
                lockPDFScrollingForActiveDrawing()
                if let handleDrag = shapeHandleDrag(at: viewPoint, pageIndex: pageIndex) {
                    activeShapeHandleDrag = handleDrag
                    pdfView.drawingOverlay.cancel()
                    if let overlay = overlays[pageIndex],
                       let stroke = strokes(for: pageIndex).first(where: { $0.id == handleDrag.strokeId }) {
                        activeShapeHandleStartStroke = stroke
                        removeCodmesInkAnnotation(id: stroke.id, from: page)
                        clearShapeHandles(in: overlay)
                        updateShapeLayerPreview(stroke, in: overlay)
                    }
                    return
                }
                if tool == .pen {
                    clearLassoSelectionIfNeeded()
                    pdfView.drawingOverlay.strokeColor = UIColor(hexString: penColorHex)
                    pdfView.drawingOverlay.lineWidth = CGFloat(penWidth)
                    pdfView.drawingOverlay.isDashed = false
                    activeShapeFit = nil
                    activeShapeDragHandleIndex = nil
                    lastPenPointTime = ProcessInfo.processInfo.systemUptime
                    let firstOverlayPoint = overlaySamples.first ?? overlayPoint
                    lastPenOverlayPoint = firstOverlayPoint
                    pdfView.drawingOverlay.begin(at: firstOverlayPoint)
                    scheduleShapeHoldFit(page: page)
                } else if tool == .eraser {
                    clearLassoSelectionIfNeeded()
                    pdfView.drawingOverlay.cancel()
                    beginEraserStroke(page: page)
                    updateEraserStroke(samples: viewSamples, page: page)
                } else {
                    let normalized = normalizedPoint(from: viewPoint, page: page)
                    if let lassoSelection,
                       lassoSelection.pageIndex == pageIndex,
                       contains(normalized, in: lassoSelection.bounds) {
                        lassoInteraction = .moving
                        lassoMoveStartSelection = lassoSelection
                        lassoMoveStartPoint = normalized
                        lassoMoveStartStrokes = strokes(for: pageIndex).filter { lassoSelection.strokeIds.contains($0.id) }
                        lassoMoveStartObjects = objects(for: pageIndex).filter { lassoSelection.objectIds.contains($0.id) }
                        pdfView.drawingOverlay.cancel()
                        if let overlay = overlays[pageIndex] {
                            for strokeId in lassoSelection.strokeIds {
                                removeCodmesInkAnnotation(id: strokeId, from: page)
                            }
                            clearShapeHandles(in: overlay)
                            applyLassoSelectionOutline(to: overlay, pageIndex: pageIndex)
                        }
                    } else {
                        lassoInteraction = .drawing
                        pdfView.drawingOverlay.strokeColor = .systemOrange
                        pdfView.drawingOverlay.lineWidth = 1.5
                        pdfView.drawingOverlay.isDashed = true
                        pdfView.drawingOverlay.begin(at: overlayPoint)
                    }
                }
            case .changed:
                guard let page = activePage else { return }
                if let handleDrag = activeShapeHandleDrag {
                    updateShapeHandleDrag(handleDrag, to: viewPoint, commit: false)
                    return
                }
                if tool == .pen {
                    if let fit = activeShapeFit {
                        let adjusted = adjustedShapeFit(fit, to: overlayPoint, handleIndex: activeShapeDragHandleIndex)
                        activeShapeFit = adjusted
                        lastPenOverlayPoint = overlayPoint
                        pdfView.drawingOverlay.replace(with: adjusted.points)
                    } else {
                        for sample in overlaySamples {
                            let movedDistance = lastPenOverlayPoint.map { distance($0, sample) } ?? .greatestFiniteMagnitude
                            if movedDistance >= 0.75 {
                                pdfView.drawingOverlay.move(to: sample)
                                lastPenOverlayPoint = sample
                                lastPenPointTime = ProcessInfo.processInfo.systemUptime
                            }
                        }
                    }
                } else if tool == .eraser {
                    updateEraserStroke(samples: viewSamples, page: page)
                } else if tool == .lasso {
                    switch lassoInteraction {
                    case .drawing:
                        pdfView.drawingOverlay.move(to: overlayPoint)
                    case .moving:
                        updateLassoMove(to: viewPoint, page: page, commit: false)
                    case nil:
                        break
                    }
                }
            case .ended:
                defer {
                    activePage = nil
                    activePageIndex = nil
                    shapeHoldWorkItem?.cancel()
                    shapeHoldWorkItem = nil
                    activeShapeFit = nil
                    activeShapeDragHandleIndex = nil
                    activeShapeHandleDrag = nil
                    activeShapeHandleStartStroke = nil
                    lastPenOverlayPoint = nil
                    lassoInteraction = nil
                    lassoMoveStartSelection = nil
                    lassoMoveStartPoint = nil
                    lassoMoveStartStrokes = []
                    lassoMoveStartObjects = []
                    unlockPDFScrollingAfterActiveDrawing()
                }
                if let handleDrag = activeShapeHandleDrag {
                    updateShapeHandleDrag(handleDrag, to: viewPoint, commit: true)
                    return
                }
                if tool == .lasso {
                    guard let page = activePage, let pageIndex = activePageIndex else {
                        pdfView.drawingOverlay.cancel()
                        return
                    }
                    switch lassoInteraction {
                    case .drawing:
                        pdfView.drawingOverlay.move(to: overlayPoint)
                        let overlayPoints = pdfView.drawingOverlay.finish()
                        let viewPoints = overlayPoints.map { pdfView.convert($0, from: pdfView.drawingOverlay) }
                        selectLassoContent(from: viewPoints, page: page, pageIndex: pageIndex)
                    case .moving:
                        updateLassoMove(to: viewPoint, page: page, commit: true)
                    case nil:
                        pdfView.drawingOverlay.cancel()
                    }
                    return
                }
                if tool == .eraser {
                    if let page = activePage {
                        updateEraserStroke(samples: viewSamples, page: page)
                    }
                    finishEraserStroke()
                    return
                }
                guard tool == .pen,
                      let page = activePage,
                      let pageIndex = activePageIndex else {
                    pdfView.drawingOverlay.cancel()
                    return
                }
                if activeShapeFit == nil {
                    for sample in overlaySamples {
                        let movedDistance = lastPenOverlayPoint.map { distance($0, sample) } ?? .greatestFiniteMagnitude
                        if movedDistance >= 0.75 {
                            pdfView.drawingOverlay.move(to: sample)
                            lastPenOverlayPoint = sample
                        }
                    }
                }
                let overlayPoints = activeShapeFit?.points ?? pdfView.drawingOverlay.finish()
                if activeShapeFit != nil {
                    _ = pdfView.drawingOverlay.finish()
                }
                guard overlayPoints.count > 1 else { return }
                let viewPoints = overlayPoints.map { pdfView.convert($0, from: pdfView.drawingOverlay) }
                let stroke = makeStroke(from: viewPoints, page: page, tool: activeShapeFit.map { "shape:\($0.kind)" } ?? "pen")
                addInkPreview(stroke, to: page)
                if shapeKind(for: stroke) != nil {
                    appendLocalStroke(pageIndex: pageIndex, stroke: stroke)
                    selectShapeStroke(stroke, pageIndex: pageIndex)
                    applyCodmesInkAnnotations()
                    applyAnnotationsToVisibleOverlays()
                }
                onStrokeFinished(pageIndex, stroke)
            case .cancelled, .failed:
                pdfView.drawingOverlay.cancel()
                activePage = nil
                activePageIndex = nil
                shapeHoldWorkItem?.cancel()
                shapeHoldWorkItem = nil
                activeShapeFit = nil
                activeShapeDragHandleIndex = nil
                activeShapeHandleDrag = nil
                activeShapeHandleStartStroke = nil
                finishEraserStroke()
                lastPenOverlayPoint = nil
                lassoInteraction = nil
                lassoMoveStartSelection = nil
                lassoMoveStartPoint = nil
                lassoMoveStartStrokes = []
                lassoMoveStartObjects = []
                clearLassoMovePreviews()
                applyCodmesInkAnnotations()
                applyAnnotationsToVisibleOverlays()
                unlockPDFScrollingAfterActiveDrawing()
            default:
                break
            }
        }

        @objc func handlePDFTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended else { return }
            clearSearchFocusIfNeeded()
            guard isWritingMode,
                  let pdfView else { return }
            let viewPoint = gesture.location(in: pdfView)
            guard let page = pdfView.page(for: viewPoint, nearest: true),
                  let document = pdfView.document else {
                clearLassoSelection()
                return
            }
            let pageIndex = document.index(for: page)
            if discardEmptyTextDraftIfNeeded() {
                return
            }
            if let tappedObject = object(at: viewPoint, page: page, pageIndex: pageIndex) {
                pdfView.endEditing(true)
                selectTappedObject(tappedObject, pageIndex: pageIndex)
                return
            }
            if let selection = lassoSelection {
                guard pageIndex == selection.pageIndex else {
                    pdfView.endEditing(true)
                    clearLassoSelection()
                    if tool == .lasso {
                        selectTappedLassoContent(at: viewPoint, page: page, pageIndex: pageIndex)
                    }
                    return
                }
                let normalized = normalizedPoint(from: viewPoint, page: page)
                if !contains(normalized, in: selection.bounds) {
                    pdfView.endEditing(true)
                    clearLassoSelection()
                    if tool == .lasso {
                        selectTappedLassoContent(at: viewPoint, page: page, pageIndex: pageIndex)
                    }
                }
                return
            }
            if tool == .text {
                placeTextObject(at: viewPoint, page: page, pageIndex: pageIndex)
                return
            }
            guard tool == .lasso else { return }
            selectTappedLassoContent(at: viewPoint, page: page, pageIndex: pageIndex)
        }

        @objc func handlePDFObjectDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended,
                  isWritingMode,
                  let pdfView else { return }
            let viewPoint = gesture.location(in: pdfView)
            guard let page = pdfView.page(for: viewPoint, nearest: true),
                  let document = pdfView.document else { return }
            let pageIndex = document.index(for: page)
            guard let object = object(at: viewPoint, page: page, pageIndex: pageIndex),
                  object.type.lowercased().contains("text") else { return }
            selectTappedObject(object, pageIndex: pageIndex)
            editTextObject(object)
        }

        private func placeTextObject(at viewPoint: CGPoint, page: PDFPage, pageIndex: Int) {
            pdfView?.endEditing(true)
            clearLassoSelectionIfNeeded()
            let normalized = normalizedPoint(from: viewPoint, page: page)
            let object = CodmesNoteCanvasModel.makeTextObject(
                pageIndex: pageIndex,
                at: normalized
            )
            guard let box = object.bbox else { return }
            selectedObjectId = object.id
            editingTextObjectId = object.id
            pendingFocusTextObjectId = object.id
            lassoSelection = LassoSelection(
                pageIndex: pageIndex,
                strokeIds: [],
                objectIds: [object.id],
                bounds: box,
                outline: []
            )
            notifyLassoSelectionChanged()
            onObjectSelected(object)
            onObjectChanged(object)
        }

        private func lockPDFScrollingForActiveDrawing() {
            guard isWritingMode,
                  tool == .pen || tool == .eraser || tool == .lasso,
                  let pdfView else { return }
            didLockScrollForDrawing = true
            for scrollView in pdfView.descendantScrollViews {
                scrollView.isScrollEnabled = false
            }
        }

        private func unlockPDFScrollingAfterActiveDrawing() {
            guard didLockScrollForDrawing else { return }
            didLockScrollForDrawing = false
            pdfView?.descendantScrollViews.forEach { $0.isScrollEnabled = true }
            applyPDFScrollTouchPolicy()
        }

        private func lockPDFScrollingForObjectMove() {
            guard isWritingMode, let pdfView else { return }
            didLockScrollForDrawing = true
            for scrollView in pdfView.descendantScrollViews {
                scrollView.isScrollEnabled = false
            }
        }

        @objc func handlePDFObjectPan(_ gesture: UIPanGestureRecognizer) {
            guard isWritingMode, let pdfView else { return }
            if gesture.state == .began {
                let viewPoint = gesture.location(in: pdfView)
                guard let page = pdfView.page(for: viewPoint, nearest: true),
                      let document = pdfView.document else { return }
                let pageIndex = document.index(for: page)
                guard let object = object(at: viewPoint, page: page, pageIndex: pageIndex),
                      selectedObjectId == object.id || lassoSelection?.objectIds.contains(object.id) == true else { return }
                activeObjectMoveId = object.id
                activeObjectMovePageIndex = pageIndex
                lockPDFScrollingForObjectMove()
                clearTextResizeHandlesInVisibleOverlays()
                selectedObjectId = object.id
                editingTextObjectId = nil
                if let textView = overlays[pageIndex]?.objectViews[object.id] as? UITextView {
                    textView.resignFirstResponder()
                    textView.isEditable = false
                    textView.isSelectable = false
                }
                onObjectSelected(object)
            }

            guard let objectId = activeObjectMoveId,
                  let pageIndex = activeObjectMovePageIndex,
                  let overlay = overlays[pageIndex],
                  let view = overlay.objectViews[objectId],
                  var object = object(with: objectId) else { return }
            let translation = gesture.translation(in: overlay)
            view.center = CGPoint(x: view.center.x + translation.x, y: view.center.y + translation.y)
            gesture.setTranslation(.zero, in: overlay)

            if gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed {
                object.bbox = bbox(for: view.frame, in: overlay.bounds)
                if let box = object.bbox {
                    lassoSelection = LassoSelection(
                        pageIndex: pageIndex,
                        strokeIds: [],
                        objectIds: [object.id],
                        bounds: box,
                        outline: []
                    )
                    notifyLassoSelectionChanged()
                }
                onObjectChanged(object)
                activeObjectMoveId = nil
                activeObjectMovePageIndex = nil
                unlockPDFScrollingAfterActiveDrawing()
                applyAnnotationsToVisibleOverlays()
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            let isShapeHandleTouch = isTouchOnShapeHandle(touch)
            let isTextResizeHandleTouch = isTouchOnTextResizeHandle(touch)
            let isObjectTouch = isTouchOnObjectView(touch)
            let isObjectContentTouch = isTouchOnObjectContent(touch)
            if gestureRecognizer === textResizePanGesture {
                return isWritingMode && isTextResizeHandleTouch
            }
            if gestureRecognizer === objectMovePanGesture {
                guard isWritingMode,
                      !isTextResizeHandleTouch,
                      isObjectContentTouch || isObjectTouch,
                      let object = object(at: touch) else { return false }
                return selectedObjectId == object.id || lassoSelection?.objectIds.contains(object.id) == true
            }
            if gestureRecognizer === objectEditTapGesture {
                return isWritingMode && !isTextResizeHandleTouch
            }
            if gestureRecognizer === clearSelectionTapGesture {
                if focus != nil {
                    return true
                }
                guard !isShapeHandleTouch,
                      !isTextResizeHandleTouch,
                      isWritingMode,
                      let pdfView else { return false }
                if isObjectContentTouch || isObjectTouch || tool == .text || tool == .lasso {
                    return true
                }
                guard lassoSelection != nil else { return false }
                let viewPoint = touch.location(in: pdfView)
                if !isPointInsideCurrentSelection(viewPoint) {
                    clearLassoSelection()
                }
                return false
            }
            if isShapeHandleTouch {
                return isWritingMode
            }
            if isTextResizeHandleTouch {
                return false
            }
            if isObjectTouch || isObjectContentTouch {
                return false
            }
            guard isWritingMode, tool == .pen || tool == .eraser || tool == .lasso else { return false }
            if UIDevice.current.userInterfaceIdiom == .pad {
                return touch.type == .pencil
            }
            return true
        }

        private func isTouchOnTextResizeHandle(_ touch: UITouch) -> Bool {
            textResizeHandle(at: touch) != nil
        }

        private func textResizeHandle(at touch: UITouch) -> PDFTextResizeHandleView? {
            for overlay in overlays.values {
                let overlayPoint = touch.location(in: overlay)
                for handle in overlay.textResizeHandleViews {
                    guard let handle = handle as? PDFTextResizeHandleView,
                          !handle.isHidden,
                          handle.alpha > 0.01,
                          handle.isUserInteractionEnabled else { continue }
                    let handlePoint = handle.convert(overlayPoint, from: overlay)
                    if handle.point(inside: handlePoint, with: nil) {
                        return handle
                    }
                }
            }
            return nil
        }

        private func textResizeHandle(at gesture: UIPanGestureRecognizer) -> PDFTextResizeHandleView? {
            guard let pdfView else { return nil }
            let viewPoint = gesture.location(in: pdfView)
            for overlay in overlays.values {
                let overlayPoint = overlay.convert(viewPoint, from: pdfView)
                for handle in overlay.textResizeHandleViews {
                    guard let handle = handle as? PDFTextResizeHandleView,
                          !handle.isHidden,
                          handle.alpha > 0.01,
                          handle.isUserInteractionEnabled else { continue }
                    let handlePoint = handle.convert(overlayPoint, from: overlay)
                    if handle.point(inside: handlePoint, with: nil) {
                        return handle
                    }
                }
            }
            return nil
        }

        private func textResizeHandleOverlay(for objectId: String) -> PDFPageAnnotationOverlay? {
            overlays.values.first { overlay in
                overlay.textResizeHandleViews.contains { view in
                    (view as? PDFTextResizeHandleView)?.objectId == objectId
                }
            }
        }

        private func object(at touch: UITouch) -> PDFAnnotationObject? {
            guard let pdfView else { return nil }
            let viewPoint = touch.location(in: pdfView)
            guard let page = pdfView.page(for: viewPoint, nearest: true),
                  let document = pdfView.document else { return nil }
            return object(at: viewPoint, page: page, pageIndex: document.index(for: page))
        }

        private func isTouchOnShapeHandle(_ touch: UITouch) -> Bool {
            for overlay in overlays.values {
                let overlayPoint = touch.location(in: overlay)
                for handle in overlay.shapeHandleViews {
                    guard !handle.isHidden, handle.alpha > 0.01, handle.isUserInteractionEnabled else { continue }
                    let handlePoint = handle.convert(overlayPoint, from: overlay)
                    if handle.point(inside: handlePoint, with: nil) {
                        return true
                    }
                }
            }
            return false
        }

        private func isTouchOnObjectView(_ touch: UITouch) -> Bool {
            for overlay in overlays.values {
                let overlayPoint = touch.location(in: overlay)
                for view in overlay.objectViews.values {
                    guard !view.isHidden, view.alpha > 0.01, view.isUserInteractionEnabled else { continue }
                    let objectPoint = view.convert(overlayPoint, from: overlay)
                    if view.point(inside: objectPoint, with: nil) {
                        return true
                    }
                }
            }
            return false
        }

        private func isTouchOnObjectContent(_ touch: UITouch) -> Bool {
            guard let pdfView else { return false }
            let viewPoint = touch.location(in: pdfView)
            guard let page = pdfView.page(for: viewPoint, nearest: true),
                  let document = pdfView.document else { return false }
            return object(at: viewPoint, page: page, pageIndex: document.index(for: page)) != nil
        }

        private func clearLassoSelectionIfNeeded() {
            guard lassoSelection != nil else { return }
            clearLassoSelection()
        }

        private func isPointInsideCurrentSelection(_ viewPoint: CGPoint) -> Bool {
            guard let pdfView,
                  let selection = lassoSelection,
                  let page = pdfView.page(for: viewPoint, nearest: true),
                  let document = pdfView.document,
                  document.index(for: page) == selection.pageIndex else { return false }
            let normalized = normalizedPoint(from: viewPoint, page: page)
            return contains(normalized, in: selection.bounds)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            false
        }

        private func scheduleShapeHoldFit(page: PDFPage) {
            guard tool == .pen, let pdfView else { return }
            let workItem = DispatchWorkItem { [weak self, weak pdfView, weak page] in
                guard let self,
                      let pdfView,
                      let page,
                      self.tool == .pen,
                      self.activePage === page else { return }
                guard self.activeShapeFit == nil else { return }
                let now = ProcessInfo.processInfo.systemUptime
                if now - self.lastPenPointTime < 0.5 {
                    self.scheduleShapeHoldFit(page: page)
                    return
                }
                let overlayPoints = pdfView.drawingOverlay.points
                guard let fit = self.fitShape(from: overlayPoints) else {
                    self.publishShapeRecognitionDebug(on: pdfView)
                    return
                }
                self.activeShapeFit = fit
                self.activeShapeDragHandleIndex = self.shapeDragHandleIndex(for: fit, near: overlayPoints.last)
                pdfView.drawingOverlay.replace(with: fit.points)
                self.publishShapeRecognitionDebug(on: pdfView)
            }
            shapeHoldWorkItem?.cancel()
            shapeHoldWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
        }

        private func publishShapeRecognitionDebug(on pdfView: AnnotatedPDFView) {
            guard let debug = lastShapeRecognitionDebug else { return }
            print("[CodmesShapeRecognition] \(debug.consoleDetails)")
            pdfView.showShapeDebug(debug.summary)
        }

        private func shapeDragHandleIndex(for fit: ShapeFit, near point: CGPoint?) -> Int {
            guard let point else {
                return fit.kind == "line" ? 1 : 0
            }
            let handles = shapeHandlePoints(for: fit)
            guard let nearest = handles.min(by: { distance($0.point, point) < distance($1.point, point) }) else {
                return fit.kind == "line" ? 1 : 0
            }
            return nearest.index
        }

        private func adjustedShapeFit(_ fit: ShapeFit, to point: CGPoint, handleIndex: Int?) -> ShapeFit {
            let index = handleIndex ?? shapeDragHandleIndex(for: fit, near: point)
            switch fit.kind {
            case "line":
                guard fit.points.count >= 2 else { return fit }
                return ShapeFit(kind: fit.kind, points: [fit.points[0], point])
            case "polyline":
                guard fit.points.count >= 2 else { return fit }
                var points = fit.points
                let vertexIndex = min(max(index, 0), points.count - 1)
                points[vertexIndex] = point
                return ShapeFit(kind: fit.kind, points: points)
            case "triangle":
                guard fit.points.count >= 4 else { return fit }
                var points = fit.points
                let vertexIndex = min(max(index, 0), 2)
                points[vertexIndex] = point
                if vertexIndex == 0 {
                    points[points.count - 1] = point
                }
                return ShapeFit(kind: fit.kind, points: points)
            case "rectangle":
                guard let bounds = pointBounds(fit.points) else { return fit }
                let opposite: CGPoint
                switch index {
                case 0:
                    opposite = CGPoint(x: bounds.maxX, y: bounds.maxY)
                case 1:
                    opposite = CGPoint(x: bounds.minX, y: bounds.maxY)
                case 2:
                    opposite = CGPoint(x: bounds.minX, y: bounds.minY)
                default:
                    opposite = CGPoint(x: bounds.maxX, y: bounds.minY)
                }
                return ShapeFit(kind: fit.kind, points: rectanglePoints(from: point, to: opposite))
            case "circle":
                guard let bounds = pointBounds(fit.points) else { return fit }
                let center = CGPoint(x: bounds.midX, y: bounds.midY)
                let radius = max(distance(center, point), 1)
                return ShapeFit(kind: fit.kind, points: circlePoints(center: center, radius: radius, count: 48))
            case "ellipse":
                guard let geometry = ellipseGeometry(from: fit.points) else { return fit }
                let adjusted = adjustedEllipseGeometry(geometry, handleIndex: index, to: point)
                return ShapeFit(kind: fit.kind, points: ellipsePoints(center: adjusted.center, rx: adjusted.rx, ry: adjusted.ry, angle: adjusted.angle, count: 48))
            default:
                return fit
            }
        }

        private func shapeHandlePoints(for fit: ShapeFit) -> [(index: Int, point: CGPoint)] {
            switch fit.kind {
            case "line", "polyline":
                guard let first = fit.points.first, let last = fit.points.last else { return [] }
                if fit.kind == "line" {
                    return [(0, first), (1, last)]
                }
                return fit.points.enumerated().map { (index: $0.offset, point: $0.element) }
            case "rectangle":
                return fit.points.prefix(4).enumerated().map { (index: $0.offset, point: $0.element) }
            case "triangle":
                return fit.points.prefix(3).enumerated().map { (index: $0.offset, point: $0.element) }
            case "circle":
                guard let bounds = pointBounds(fit.points) else { return [] }
                return [
                    (0, CGPoint(x: bounds.midX, y: bounds.minY)),
                    (1, CGPoint(x: bounds.maxX, y: bounds.midY)),
                    (2, CGPoint(x: bounds.midX, y: bounds.maxY)),
                    (3, CGPoint(x: bounds.minX, y: bounds.midY))
                ]
            case "ellipse":
                guard let geometry = ellipseGeometry(from: fit.points) else { return [] }
                return ellipseHandlePoints(for: geometry)
            default:
                return []
            }
        }

        private func ellipseGeometry(from points: [CGPoint]) -> EllipseGeometry? {
            let source = openShapePoints(points)
            guard source.count >= 6 else { return nil }
            let center = source.reduce(CGPoint.zero) { partial, point in
                CGPoint(x: partial.x + point.x, y: partial.y + point.y)
            }
            let normalizedCenter = CGPoint(
                x: center.x / CGFloat(source.count),
                y: center.y / CGFloat(source.count)
            )
            var xx: CGFloat = 0
            var xy: CGFloat = 0
            var yy: CGFloat = 0
            for point in source {
                let dx = point.x - normalizedCenter.x
                let dy = point.y - normalizedCenter.y
                xx += dx * dx
                xy += dx * dy
                yy += dy * dy
            }
            var angle = 0.5 * atan2(2 * xy, xx - yy)
            let cosA = cos(angle)
            let sinA = sin(angle)
            var rx: CGFloat = 1
            var ry: CGFloat = 1
            for point in source {
                let dx = point.x - normalizedCenter.x
                let dy = point.y - normalizedCenter.y
                rx = max(rx, abs(dx * cosA + dy * sinA))
                ry = max(ry, abs(-dx * sinA + dy * cosA))
            }
            if ry > rx {
                swap(&rx, &ry)
                angle += .pi / 2
            }
            return EllipseGeometry(center: normalizedCenter, rx: max(rx, 1), ry: max(ry, 1), angle: angle)
        }

        private func adjustedEllipseGeometry(_ geometry: EllipseGeometry, handleIndex: Int, to point: CGPoint) -> EllipseGeometry {
            let dx = point.x - geometry.center.x
            let dy = point.y - geometry.center.y
            let distanceFromCenter = max(hypot(dx, dy), 1)
            let ratio = max(geometry.rx / max(geometry.ry, 1), 1.05)
            switch handleIndex {
            case 0:
                return EllipseGeometry(center: geometry.center, rx: distanceFromCenter * ratio, ry: distanceFromCenter, angle: atan2(dy, dx) + .pi / 2)
            case 2:
                return EllipseGeometry(center: geometry.center, rx: distanceFromCenter * ratio, ry: distanceFromCenter, angle: atan2(dy, dx) - .pi / 2)
            case 3:
                return EllipseGeometry(center: geometry.center, rx: distanceFromCenter, ry: distanceFromCenter / ratio, angle: atan2(dy, dx) + .pi)
            default:
                return EllipseGeometry(center: geometry.center, rx: distanceFromCenter, ry: distanceFromCenter / ratio, angle: atan2(dy, dx))
            }
        }

        private func ellipseHandlePoints(for geometry: EllipseGeometry) -> [(index: Int, point: CGPoint)] {
            let cosA = cos(geometry.angle)
            let sinA = sin(geometry.angle)
            let major = CGVector(dx: cosA * geometry.rx, dy: sinA * geometry.rx)
            let minor = CGVector(dx: -sinA * geometry.ry, dy: cosA * geometry.ry)
            return [
                (0, CGPoint(x: geometry.center.x - minor.dx, y: geometry.center.y - minor.dy)),
                (1, CGPoint(x: geometry.center.x + major.dx, y: geometry.center.y + major.dy)),
                (2, CGPoint(x: geometry.center.x + minor.dx, y: geometry.center.y + minor.dy)),
                (3, CGPoint(x: geometry.center.x - major.dx, y: geometry.center.y - major.dy))
            ]
        }

        private func openShapePoints(_ points: [CGPoint]) -> [CGPoint] {
            guard points.count > 2,
                  let first = points.first,
                  let last = points.last,
                  distance(first, last) < 0.5 else { return points }
            return Array(points.dropLast())
        }

        private func fitShape(from points: [CGPoint]) -> ShapeFit? {
            lastShapeRecognitionDebug = nil
            guard let attempt = PDFShapeRecognizer().recognizeAttempt(points: points) else { return nil }
            lastShapeRecognitionDebug = attempt.debug
            PDFShapeSampleStore.append(source: "pdf-notes-hold", rawPoints: points, attempt: attempt)
            return attempt.fit
        }

        private func templateRecognizedShape(from points: [CGPoint], bounds: CGRect, diagonal: CGFloat, endpointGap: CGFloat) -> ShapeFit? {
            let isClosed = endpointGap < 0.68
            guard let normalized = normalizedGesture(points, count: 64) else { return nil }
            let templates = shapeTemplates(includeClosed: isClosed)
            guard !templates.isEmpty else { return nil }

            let scored = templates
                .map { template in
                    ShapeCandidate(
                        fit: ShapeFit(kind: template.kind, points: []),
                        score: templateDistance(normalized, template.points)
                            + templateFeaturePenalty(kind: template.kind, points: points, bounds: bounds, diagonal: diagonal, endpointGap: endpointGap)
                    )
                }
                .sorted { $0.score < $1.score }

            let triangleCandidate = bestTriangleFit(from: points, bounds: bounds, diagonal: diagonal)
            if let triangle = triangleCandidate?.fit,
               let triangleScore = scored.first(where: { $0.fit.kind == "triangle" })?.score,
               let rectangleScore = scored.first(where: { $0.fit.kind == "rectangle" })?.score,
               triangleScore <= rectangleScore + 0.24,
               triangleScore < 0.62 {
                lastShapeRecognitionDebug = shapeDebug(selected: "triangle", reason: "triangle-guard", points: points, diagonal: diagonal, endpointGap: endpointGap, candidates: scored)
                return triangle
            }

            guard let best = scored.first,
                  best.score < 0.34 else {
                lastShapeRecognitionDebug = shapeDebug(selected: "none", reason: "template-threshold", points: points, diagonal: diagonal, endpointGap: endpointGap, candidates: scored)
                return nil
            }

            switch best.fit.kind {
            case "line":
                lastShapeRecognitionDebug = shapeDebug(selected: "line", reason: "template", points: points, diagonal: diagonal, endpointGap: endpointGap, candidates: scored)
                return ShapeFit(kind: "line", points: [points[0], points[points.count - 1]])
            case "polyline":
                lastShapeRecognitionDebug = shapeDebug(selected: "polyline", reason: "template", points: points, diagonal: diagonal, endpointGap: endpointGap, candidates: scored)
                return ShapeFit(kind: "polyline", points: fittedPolyline(from: points, diagonal: diagonal))
            case "triangle":
                if let triangle = triangleCandidate?.fit {
                    lastShapeRecognitionDebug = shapeDebug(selected: "triangle", reason: "template", points: points, diagonal: diagonal, endpointGap: endpointGap, candidates: scored)
                    return triangle
                }
                lastShapeRecognitionDebug = shapeDebug(selected: "triangle", reason: "template-fallback", points: points, diagonal: diagonal, endpointGap: endpointGap, candidates: scored)
                return fallbackTriangle(from: points, bounds: bounds, diagonal: diagonal)
            case "rectangle":
                if let triangle = triangleCandidate,
                   triangle.score < 0.34,
                   let triangleScore = scored.first(where: { $0.fit.kind == "triangle" })?.score,
                   let rectangleScore = scored.first(where: { $0.fit.kind == "rectangle" })?.score,
                   triangleScore <= rectangleScore + 0.32 {
                    lastShapeRecognitionDebug = shapeDebug(selected: "triangle", reason: "rectangle-veto", points: points, diagonal: diagonal, endpointGap: endpointGap, candidates: scored)
                    return triangle.fit
                }
                if let rectangle = closedPolygonCandidates(from: points, diagonal: diagonal)
                    .filter({ $0.fit.kind == "rectangle" })
                    .min(by: { $0.score < $1.score })?.fit {
                    lastShapeRecognitionDebug = shapeDebug(selected: "rectangle", reason: "template", points: points, diagonal: diagonal, endpointGap: endpointGap, candidates: scored)
                    return rectangle
                }
                lastShapeRecognitionDebug = shapeDebug(selected: "rectangle", reason: "template-fallback", points: points, diagonal: diagonal, endpointGap: endpointGap, candidates: scored)
                return ShapeFit(kind: "rectangle", points: rectanglePoints(from: CGPoint(x: bounds.minX, y: bounds.minY), to: CGPoint(x: bounds.maxX, y: bounds.maxY)))
            case "circle":
                lastShapeRecognitionDebug = shapeDebug(selected: "circle", reason: "template", points: points, diagonal: diagonal, endpointGap: endpointGap, candidates: scored)
                return ShapeFit(kind: "circle", points: circlePoints(in: bounds, count: 48))
            case "ellipse":
                lastShapeRecognitionDebug = shapeDebug(selected: "ellipse", reason: "template", points: points, diagonal: diagonal, endpointGap: endpointGap, candidates: scored)
                return ShapeFit(kind: "ellipse", points: ellipsePoints(in: bounds, count: 48))
            default:
                return nil
            }
        }

        private func shapeDebug(selected: String, reason: String, points: [CGPoint], diagonal: CGFloat, endpointGap: CGFloat, candidates: [ShapeCandidate]) -> ShapeRecognitionDebug {
            let vertices = deduplicatedVertices(simplify(points, epsilon: max(diagonal * 0.045, 4)), diagonal: diagonal)
            var bestByKind: [String: CGFloat] = [:]
            for candidate in candidates {
                bestByKind[candidate.fit.kind] = min(bestByKind[candidate.fit.kind] ?? .greatestFiniteMagnitude, candidate.score)
            }
            let scores = bestByKind.map { (kind: $0.key, score: $0.value) }
            return ShapeRecognitionDebug(
                selected: selected,
                reason: reason,
                pointCount: points.count,
                endpointGap: endpointGap,
                vertexCount: vertices.count,
                scores: scores,
                samplePoints: resampleToCount(points, count: 32)
            )
        }

        private func normalizedGesture(_ points: [CGPoint], count: Int) -> [CGPoint]? {
            let sampled = resampleToCount(points, count: count)
            guard sampled.count == count, let bounds = pointBounds(sampled) else { return nil }
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            let firstAngle = atan2(sampled[0].y - center.y, sampled[0].x - center.x)
            let rotated = sampled.map { rotate($0, around: center, by: -firstAngle) }
            guard let rotatedBounds = pointBounds(rotated) else { return nil }
            let scale = max(rotatedBounds.width, rotatedBounds.height, 1)
            let normalizedCenter = CGPoint(x: rotatedBounds.midX, y: rotatedBounds.midY)
            return rotated.map {
                CGPoint(
                    x: ($0.x - normalizedCenter.x) / scale,
                    y: ($0.y - normalizedCenter.y) / scale
                )
            }
        }

        private func shapeTemplates(includeClosed: Bool) -> [ShapeTemplate] {
            var templates: [ShapeTemplate] = [
                ShapeTemplate(kind: "line", points: templatePolyline([CGPoint(x: -0.5, y: 0), CGPoint(x: 0.5, y: 0)], count: 64), isClosed: false),
                ShapeTemplate(kind: "polyline", points: templatePolyline([CGPoint(x: -0.5, y: -0.42), CGPoint(x: -0.12, y: 0.35), CGPoint(x: 0.5, y: 0.35)], count: 64), isClosed: false),
                ShapeTemplate(kind: "polyline", points: templatePolyline([CGPoint(x: -0.5, y: -0.35), CGPoint(x: 0.15, y: -0.35), CGPoint(x: -0.15, y: 0.35), CGPoint(x: 0.5, y: 0.35)], count: 64), isClosed: false)
            ]
            if includeClosed {
                templates.append(contentsOf: [
                    ShapeTemplate(kind: "triangle", points: templatePolyline([CGPoint(x: 0, y: -0.5), CGPoint(x: 0.48, y: 0.42), CGPoint(x: -0.48, y: 0.42), CGPoint(x: 0, y: -0.5)], count: 64), isClosed: true),
                    ShapeTemplate(kind: "rectangle", points: templatePolyline([CGPoint(x: -0.5, y: -0.38), CGPoint(x: 0.5, y: -0.38), CGPoint(x: 0.5, y: 0.38), CGPoint(x: -0.5, y: 0.38), CGPoint(x: -0.5, y: -0.38)], count: 64), isClosed: true),
                    ShapeTemplate(kind: "circle", points: circlePoints(center: .zero, radius: 0.5, count: 63), isClosed: true),
                    ShapeTemplate(kind: "ellipse", points: ellipsePoints(center: .zero, rx: 0.5, ry: 0.32, angle: 0, count: 63), isClosed: true)
                ])
            }
            return templates
        }

        private func templateFeaturePenalty(kind: String, points: [CGPoint], bounds: CGRect, diagonal: CGFloat, endpointGap: CGFloat) -> CGFloat {
            let aspect = max(bounds.width, bounds.height) / max(min(bounds.width, bounds.height), 1)
            let circularity = closedCircularity(points)
            let vertices = deduplicatedVertices(simplify(points, epsilon: max(diagonal * 0.045, 4)), diagonal: diagonal)
            let vertexCount = vertices.count
            switch kind {
            case "line":
                return endpointGap < 0.24 ? 0.18 : min(lineError(points, from: points[0], to: points[points.count - 1]) / diagonal, 0.35)
            case "polyline":
                return endpointGap < 0.24 ? 0.16 : (vertices.count < 3 ? 0.14 : 0)
            case "triangle":
                let vertexPenalty: CGFloat = vertexCount == 3 ? 0 : (vertexCount == 4 ? 0.05 : abs(CGFloat(vertexCount) - 3) * 0.055)
                return endpointGap > 0.58 ? 0.24 : vertexPenalty + max(0, circularity - 0.58) * 0.1
            case "rectangle":
                let vertexPenalty: CGFloat = vertexCount <= 3 ? 0.18 : abs(CGFloat(vertexCount) - 4) * 0.055
                return endpointGap > 0.48 ? 0.22 : vertexPenalty + max(0, circularity - 0.72) * 0.12
            case "circle":
                return endpointGap > 0.52 ? 0.2 : abs(aspect - 1) * 0.05 + max(0, 0.58 - circularity) * 0.18 + (vertices.count <= 5 ? 0.08 : 0)
            case "ellipse":
                return endpointGap > 0.52 ? 0.2 : max(0, 0.38 - circularity) * 0.16 + (vertices.count <= 5 ? 0.08 : 0)
            default:
                return 0
            }
        }

        private func templateDistance(_ lhs: [CGPoint], _ rhs: [CGPoint]) -> CGFloat {
            guard lhs.count == rhs.count, !lhs.isEmpty else { return .greatestFiniteMagnitude }
            return zip(lhs, rhs).reduce(CGFloat(0)) { sum, pair in
                sum + distance(pair.0, pair.1)
            } / CGFloat(lhs.count)
        }

        private func templatePolyline(_ points: [CGPoint], count: Int) -> [CGPoint] {
            normalizedGesture(points, count: count) ?? resampleToCount(points, count: count)
        }

        private func resampleToCount(_ points: [CGPoint], count: Int) -> [CGPoint] {
            guard count > 1, points.count > 1 else { return points }
            let totalLength = max(polylineLength(points), 1)
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
                    let next = CGPoint(
                        x: segmentStart.x + (current.x - segmentStart.x) * ratio,
                        y: segmentStart.y + (current.y - segmentStart.y) * ratio
                    )
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
            if result.count > count {
                result = Array(result.prefix(count))
            }
            return result
        }

        private func rotate(_ point: CGPoint, around center: CGPoint, by angle: CGFloat) -> CGPoint {
            let translated = CGPoint(x: point.x - center.x, y: point.y - center.y)
            return CGPoint(
                x: center.x + translated.x * cos(angle) - translated.y * sin(angle),
                y: center.y + translated.x * sin(angle) + translated.y * cos(angle)
            )
        }

        private func openGapTriangleCandidate(from points: [CGPoint], diagonal: CGFloat) -> ShapeFit? {
            guard points.count > 8 else { return nil }
            let start = points[0]
            let end = points[points.count - 1]
            let endpointGap = distance(start, end) / diagonal
            guard endpointGap > 0.015, endpointGap < 0.55 else { return nil }

            let apex = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
            let orderedPath = [apex] + Array(points.dropFirst().dropLast()) + [apex]
            let epsilons: [CGFloat] = [0.035, 0.045, 0.06, 0.08, 0.105]
            var best: (fit: ShapeFit, score: CGFloat)?

            for epsilon in epsilons {
                let simplified = simplify(orderedPath, epsilon: max(diagonal * epsilon, 4))
                let interior = simplified.dropFirst().dropLast().filter { distance($0, apex) / diagonal > 0.14 }
                guard interior.count >= 2 else { continue }
                for firstIndex in 0..<(interior.count - 1) {
                    for secondIndex in (firstIndex + 1)..<interior.count {
                        let firstBase = interior[firstIndex]
                        let secondBase = interior[secondIndex]
                        guard distance(firstBase, secondBase) / diagonal > 0.18,
                              distance(apex, firstBase) / diagonal > 0.18,
                              distance(apex, secondBase) / diagonal > 0.18 else { continue }

                        let triangle = [apex, firstBase, secondBase, apex]
                        let areaRatio = abs(polygonArea(triangle)) / (diagonal * diagonal)
                        guard areaRatio > 0.028 else { continue }

                        let shapeChangePenalty = abs(polylineLength(triangle) - polylineLength(orderedPath)) / max(polylineLength(orderedPath), 1) * 0.08
                        let score = polylineError(points, candidate: triangle) / diagonal + shapeChangePenalty
                        guard score < 0.54 else { continue }
                        if best == nil || score < best!.score {
                            best = (ShapeFit(kind: "triangle", points: triangle), score)
                        }
                    }
                }
            }
            return best?.fit
        }

        private func closedPolygonCandidate(from points: [CGPoint], diagonal: CGFloat) -> ShapeFit? {
            closedPolygonCandidates(from: points, diagonal: diagonal).min(by: { $0.score < $1.score })?.fit
        }

        private func closedPolygonCandidates(from points: [CGPoint], diagonal: CGFloat) -> [ShapeCandidate] {
            let endpointGap = distance(points[0], points[points.count - 1]) / diagonal
            guard endpointGap < 0.42 else { return [] }
            let epsilons: [CGFloat] = [0.022, 0.03, 0.04, 0.055, 0.075, 0.1]
            var result: [ShapeCandidate] = []

            for epsilon in epsilons {
                let vertices = polygonVertices(from: points, epsilon: max(diagonal * epsilon, 4))
                guard vertices.count == 3 || vertices.count == 4 else { continue }
                let polygon = vertices + [vertices[0]]
                let areaRatio = abs(polygonArea(polygon)) / (diagonal * diagonal)
                guard areaRatio > 0.03 else { continue }
                let score = polylineError(points, candidate: polygon) / diagonal
                    + max(0, endpointGap - 0.18) * 0.18
                    + (vertices.count == 4 ? -0.015 : 0.015)
                let kind = vertices.count == 4 ? "rectangle" : "triangle"
                result.append(ShapeCandidate(fit: ShapeFit(kind: kind, points: polygon), score: score))
            }

            return result
        }

        private func angularStrokeIntent(_ points: [CGPoint], diagonal: CGFloat) -> Bool {
            guard points.count > 8 else { return false }
            let simplified = deduplicatedVertices(simplify(points, epsilon: max(diagonal * 0.045, 4)), diagonal: diagonal)
            guard simplified.count >= 3 else { return false }
            var sharpTurns = 0
            for index in 1..<(simplified.count - 1) {
                let angle = turnAngle(previous: simplified[index - 1], current: simplified[index], next: simplified[index + 1])
                if angle < 2.35 {
                    sharpTurns += 1
                }
            }
            if distance(points[0], points[points.count - 1]) / diagonal < 0.2, simplified.count > 3 {
                let angle = turnAngle(previous: simplified[simplified.count - 2], current: simplified[0], next: simplified[1])
                if angle < 2.35 {
                    sharpTurns += 1
                }
            }
            return sharpTurns >= 2
        }

        private func openPolylineIntent(points: [CGPoint], diagonal: CGFloat) -> Bool {
            let endpointGap = distance(points[0], points[points.count - 1]) / diagonal
            guard endpointGap > 0.26 else { return false }
            let simplified = deduplicatedVertices(simplify(points, epsilon: max(diagonal * 0.035, 4)), diagonal: diagonal)
            return simplified.count >= 3 && simplified.count <= 8
        }

        private func roundCandidate(from points: [CGPoint], bounds: CGRect, diagonal: CGFloat) -> ShapeFit? {
            roundCandidates(from: points, bounds: bounds, diagonal: diagonal).min(by: { $0.score < $1.score })?.fit
        }

        private func roundCandidates(from points: [CGPoint], bounds: CGRect, diagonal: CGFloat) -> [ShapeCandidate] {
            let endpointGap = distance(points[0], points[points.count - 1]) / diagonal
            let circleScore = circleFitError(points, bounds: bounds)
            let ellipseScore = ellipseFitError(points, bounds: bounds)
            let angleCoverage = angularCoverage(points, bounds: bounds)
            let circularityScore = closedCircularity(points)
            guard endpointGap < 0.55,
                  angleCoverage > 0.48,
                  circularityScore > 0.28 else { return [] }
            let dominantVertices = deduplicatedVertices(simplify(points, epsilon: max(diagonal * 0.04, 4)), diagonal: diagonal)
            guard dominantVertices.count > 5 || circularityScore > 0.64 else { return [] }
            if dominantVertices.count <= 5,
               angularStrokeIntent(points, diagonal: diagonal),
               circularityScore < 0.86 {
                return []
            }

            var result: [ShapeCandidate] = []
            let coveragePenalty = max(0, 0.8 - angleCoverage) * 0.12
            let closurePenalty = max(0, endpointGap - 0.2) * 0.18
            let cornerPenalty: CGFloat = dominantVertices.count <= 5 ? 0.16 : 0
            if circleScore < 0.54 {
                result.append(ShapeCandidate(
                    fit: ShapeFit(kind: "circle", points: circlePoints(in: bounds, count: 48)),
                    score: circleScore + coveragePenalty + closurePenalty + cornerPenalty + 0.04
                ))
            }
            if ellipseScore < 0.5 {
                result.append(ShapeCandidate(
                    fit: ShapeFit(kind: "ellipse", points: ellipsePoints(in: bounds, count: 48)),
                    score: ellipseScore + coveragePenalty + closurePenalty + cornerPenalty + 0.055
                ))
            }
            return result
        }

        private func deduplicatedVertices(_ points: [CGPoint], diagonal: CGFloat) -> [CGPoint] {
            var result: [CGPoint] = []
            for point in points {
                if result.last.map({ distance($0, point) / diagonal < 0.035 }) == true {
                    continue
                }
                result.append(point)
            }
            if result.count > 2, let first = result.first, let last = result.last, distance(first, last) / diagonal < 0.05 {
                result.removeLast()
            }
            return result
        }

        private func turnAngle(previous: CGPoint, current: CGPoint, next: CGPoint) -> CGFloat {
            let first = CGVector(dx: previous.x - current.x, dy: previous.y - current.y)
            let second = CGVector(dx: next.x - current.x, dy: next.y - current.y)
            let firstLength = max(hypot(first.dx, first.dy), 0.001)
            let secondLength = max(hypot(second.dx, second.dy), 0.001)
            let dot = (first.dx * second.dx + first.dy * second.dy) / (firstLength * secondLength)
            return acos(max(-1, min(1, dot)))
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

        private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
            hypot(a.x - b.x, a.y - b.y)
        }

        private func lineError(_ points: [CGPoint], from start: CGPoint, to end: CGPoint) -> CGFloat {
            let denominator = max(distance(start, end), 1)
            return points.map { point in
                abs((end.x - start.x) * (start.y - point.y) - (start.x - point.x) * (end.y - start.y)) / denominator
            }.max() ?? .greatestFiniteMagnitude
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

        private func polygonVertexOptions(from points: [CGPoint], diagonal: CGFloat) -> [[CGPoint]] {
            let multipliers: [CGFloat] = [0.04, 0.055, 0.075, 0.095, 0.12, 0.15, 0.2]
            var options: [[CGPoint]] = []
            let sourceOptions = [points, convexHull(points)].filter { $0.count >= 3 }
            for source in sourceOptions {
                for multiplier in multipliers {
                    let vertices = polygonVertices(from: source, epsilon: diagonal * multiplier)
                    guard vertices.count >= 3, vertices.count <= 8 else { continue }
                    if !options.contains(where: { areSimilarVertices($0, vertices, tolerance: diagonal * 0.035) }) {
                        options.append(vertices)
                    }
                }
            }
            return options
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
                while lower.count >= 2,
                      cross(lower[lower.count - 2], lower[lower.count - 1], point) <= 0 {
                    lower.removeLast()
                }
                lower.append(point)
            }
            var upper: [CGPoint] = []
            for point in sorted.reversed() {
                while upper.count >= 2,
                      cross(upper[upper.count - 2], upper[upper.count - 1], point) <= 0 {
                    upper.removeLast()
                }
                upper.append(point)
            }
            return Array((lower.dropLast() + upper.dropLast()))
        }

        private func cross(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
            (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
        }

        private func bestTriangleCandidate(from points: [CGPoint], diagonal: CGFloat) -> (fit: ShapeFit, score: CGFloat)? {
            var best: (fit: ShapeFit, score: CGFloat)?
            for vertices in polygonVertexOptions(from: points, diagonal: diagonal) {
                let triangles = trianglePointOptions(from: vertices)
                for trianglePoints in triangles {
                    let triangle = trianglePoints + [trianglePoints[0]]
                    let score = polylineError(points, candidate: triangle) / diagonal
                    guard score < 0.46 else { continue }
                    let weighted = score * 0.58
                    if best == nil || weighted < best!.score {
                        best = (ShapeFit(kind: "triangle", points: triangle), weighted)
                    }
                }
            }
            return best
        }

        private func bestTriangleFit(from points: [CGPoint], bounds: CGRect, diagonal: CGFloat) -> (fit: ShapeFit, score: CGFloat)? {
            var candidates: [(fit: ShapeFit, score: CGFloat)] = []
            if let openTriangle = openGapTriangleCandidate(from: points, diagonal: diagonal) {
                candidates.append((openTriangle, polylineError(points, candidate: openTriangle.points) / diagonal * 0.72))
            }
            if let triangle = bestTriangleCandidate(from: points, diagonal: diagonal) {
                candidates.append(triangle)
            }
            if let fallback = fallbackTriangle(from: points, bounds: bounds, diagonal: diagonal) {
                candidates.append((fallback, polylineError(points, candidate: fallback.points) / diagonal * 0.9))
            }
            return candidates.min(by: { $0.score < $1.score })
        }

        private func fallbackTriangle(from points: [CGPoint], bounds: CGRect, diagonal: CGFloat) -> ShapeFit? {
            let hull = convexHull(points)
            guard hull.count >= 3 else { return nil }
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            let sorted = hull.sorted { distance($0, center) > distance($1, center) }
            var selected: [CGPoint] = []
            for point in sorted {
                guard selected.allSatisfy({ distance($0, point) > diagonal * 0.22 }) else { continue }
                selected.append(point)
                if selected.count == 3 { break }
            }
            guard selected.count == 3 else { return nil }
            let ordered = selected.sorted {
                atan2($0.y - center.y, $0.x - center.x) < atan2($1.y - center.y, $1.x - center.x)
            }
            return ShapeFit(kind: "triangle", points: ordered + [ordered[0]])
        }

        private func fittedPolyline(from points: [CGPoint], diagonal: CGFloat) -> [CGPoint] {
            let simplified = simplify(points, epsilon: max(diagonal * 0.08, 6))
            guard simplified.count > 2 else {
                return [points[0], points[points.count - 1]]
            }
            if simplified.count <= 6 {
                return simplified
            }
            let step = CGFloat(simplified.count - 1) / 5
            var result: [CGPoint] = []
            for index in 0...5 {
                result.append(simplified[min(simplified.count - 1, Int(round(CGFloat(index) * step)))])
            }
            return result
        }

        private func trianglePointOptions(from vertices: [CGPoint]) -> [[CGPoint]] {
            guard vertices.count >= 3 else { return [] }
            if vertices.count == 3 {
                return [vertices]
            }
            var result: [[CGPoint]] = []
            for first in 0..<(vertices.count - 2) {
                for second in (first + 1)..<(vertices.count - 1) {
                    for third in (second + 1)..<vertices.count {
                        result.append([vertices[first], vertices[second], vertices[third]])
                    }
                }
            }
            return result
        }

        private func areSimilarVertices(_ lhs: [CGPoint], _ rhs: [CGPoint], tolerance: CGFloat) -> Bool {
            guard lhs.count == rhs.count else { return false }
            return zip(lhs, rhs).allSatisfy { distance($0, $1) <= tolerance }
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

        private func circleFitError(_ points: [CGPoint], bounds: CGRect) -> CGFloat {
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            let radius = max(min(bounds.width, bounds.height) / 2, 1)
            let errors = points.map { abs(distance($0, center) / radius - 1) }
            let sorted = errors.sorted()
            guard !sorted.isEmpty else { return .greatestFiniteMagnitude }
            let cutoff = max(1, Int(CGFloat(sorted.count) * 0.82))
            return sorted.prefix(cutoff).reduce(0, +) / CGFloat(cutoff)
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

        private func circlePoints(in bounds: CGRect, count: Int) -> [CGPoint] {
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            let radius = max(bounds.width, bounds.height) / 2
            return circlePoints(center: center, radius: radius, count: count)
        }

        private func circlePoints(center: CGPoint, radius: CGFloat, count: Int) -> [CGPoint] {
            (0...count).map { index in
                let angle = CGFloat(index) / CGFloat(count) * .pi * 2
                return CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
            }
        }

        private func ellipsePoints(center: CGPoint, rx: CGFloat, ry: CGFloat, angle: CGFloat, count: Int) -> [CGPoint] {
            (0...count).map { index in
                let theta = CGFloat(index) / CGFloat(count) * .pi * 2
                let x = cos(theta) * rx
                let y = sin(theta) * ry
                return CGPoint(
                    x: center.x + x * cos(angle) - y * sin(angle),
                    y: center.y + x * sin(angle) + y * cos(angle)
                )
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

        private func normalizedRect(minX: CGFloat, minY: CGFloat, maxX: CGFloat, maxY: CGFloat) -> CGRect {
            let left = min(minX, maxX)
            let right = max(minX, maxX)
            let top = min(minY, maxY)
            let bottom = max(minY, maxY)
            return CGRect(x: left, y: top, width: max(1, right - left), height: max(1, bottom - top))
        }

        private func rectanglePoints(from point: CGPoint, to opposite: CGPoint) -> [CGPoint] {
            let bounds = normalizedRect(minX: point.x, minY: point.y, maxX: opposite.x, maxY: opposite.y)
            let topLeft = CGPoint(x: bounds.minX, y: bounds.minY)
            let topRight = CGPoint(x: bounds.maxX, y: bounds.minY)
            let bottomRight = CGPoint(x: bounds.maxX, y: bounds.maxY)
            let bottomLeft = CGPoint(x: bounds.minX, y: bounds.maxY)
            return [topLeft, topRight, bottomRight, bottomLeft, topLeft]
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
                    result.append(CGPoint(
                        x: previous.x + (current.x - previous.x) * t,
                        y: previous.y + (current.y - previous.y) * t
                    ))
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

        private func makeStroke(from points: [CGPoint], page: PDFPage, tool: String = "pen") -> CodmesInkStroke {
            let bounds = page.bounds(for: .mediaBox)
            let sourcePoints = tool == "pen" ? smoothedStrokePoints(points) : points
            let normalizedPoints = sourcePoints.enumerated().map { offset, point in
                normalizedPoint(from: point, page: page, timeOffset: Double(offset) * 0.008, pageBounds: bounds)
            }
            return CodmesInkStroke(
                id: UUID().uuidString,
                tool: tool,
                color: penColorHex,
                width: penWidth / max(Double(pdfView?.scaleFactor ?? 1), 0.001),
                opacity: nil,
                points: normalizedPoints
            )
        }

        private func smoothedStrokePoints(_ points: [CGPoint]) -> [CGPoint] {
            guard points.count > 3 else { return points }
            var result = points
            for index in 1..<(points.count - 1) {
                let previous = points[index - 1]
                let current = points[index]
                let next = points[index + 1]
                result[index] = CGPoint(
                    x: previous.x * 0.28 + current.x * 0.44 + next.x * 0.28,
                    y: previous.y * 0.28 + current.y * 0.44 + next.y * 0.28
                )
            }
            return result
        }

        private func normalizedPoint(from viewPoint: CGPoint, page: PDFPage, timeOffset: Double? = nil, pageBounds: CGRect? = nil) -> CodmesInkPoint {
            guard let pdfView else { return CodmesInkPoint(x: 0, y: 0, pressure: nil, timeOffset: timeOffset) }
            let pagePoint = pdfView.convert(viewPoint, to: page)
            let bounds = pageBounds ?? page.bounds(for: .mediaBox)
            let x = min(max((pagePoint.x - bounds.minX) / max(bounds.width, 1), 0), 1)
            let y = min(max(1 - ((pagePoint.y - bounds.minY) / max(bounds.height, 1)), 0), 1)
            return CodmesInkPoint(x: x, y: y, pressure: nil, timeOffset: timeOffset)
        }

        private func pagePoint(_ point: CodmesInkPoint, pageBounds: CGRect) -> CGPoint {
            CGPoint(
                x: pageBounds.minX + pageBounds.width * point.x,
                y: pageBounds.minY + pageBounds.height * (1 - point.y)
            )
        }

        private func addInkPreview(_ stroke: CodmesInkStroke, to page: PDFPage, contentsPrefix: String = "codmes-ink-live", selected: Bool = false) {
            guard stroke.points.count > 1 else { return }
            let bounds = page.bounds(for: .mediaBox)
            let annotation = PDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
            annotation.contents = "\(contentsPrefix):\(stroke.id)"
            annotation.color = selected ? .systemOrange : UIColor(hexString: stroke.color)
            let border = PDFBorder()
            border.lineWidth = CGFloat(max(0.5, stroke.width + (selected ? 1.5 : 0)))
            annotation.border = border
            let path = UIBezierPath()
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.lineWidth = CGFloat(max(0.5, stroke.width + (selected ? 1.5 : 0)))
            path.move(to: pagePoint(stroke.points[0], pageBounds: bounds))
            for point in stroke.points.dropFirst() {
                path.addLine(to: pagePoint(point, pageBounds: bounds))
            }
            annotation.add(path)
            page.addAnnotation(annotation)
        }

        private func eraseStroke(at viewPoint: CGPoint, page: PDFPage) {
            guard let pdfView, let document = pdfView.document, let annotations else { return }
            let pageIndex = document.index(for: page)
            guard pageIndex >= 0 else { return }
            let strokes = annotations.noteStrokes(pageIndex: pageIndex)
            guard !strokes.isEmpty else { return }
            let normalized = normalizedPoint(from: viewPoint, page: page)
            let pageBounds = page.bounds(for: .mediaBox)
            let threshold = max(0.004, eraserWidth / Double(max(min(pageBounds.width, pageBounds.height), 1)))
            let kept = splitStrokes(strokes, erasingAt: normalized, threshold: threshold)
            guard kept.map(\.id) != strokes.map(\.id) || kept.count != strokes.count else { return }
            onStrokesChanged(pageIndex, kept)
        }

        private func beginEraserStroke(page: PDFPage) {
            guard let pdfView, let document = pdfView.document else { return }
            let pageIndex = document.index(for: page)
            guard pageIndex >= 0 else { return }
            activeEraserPageIndex = pageIndex
            activeEraserStrokes = annotations?.noteStrokes(pageIndex: pageIndex) ?? []
            lastEraserPoint = nil
        }

        private func updateEraserStroke(samples: [CGPoint], page: PDFPage) {
            guard let pdfView,
                  let document = pdfView.document else { return }
            let pageIndex = document.index(for: page)
            guard pageIndex >= 0 else { return }
            if activeEraserPageIndex != pageIndex {
                beginEraserStroke(page: page)
            }
            guard activeEraserPageIndex == pageIndex,
                  !activeEraserStrokes.isEmpty else { return }
            let pageBounds = page.bounds(for: .mediaBox)
            let threshold = max(0.004, eraserWidth / Double(max(min(pageBounds.width, pageBounds.height), 1)))
            var nextStrokes = activeEraserStrokes
            var didChange = false
            for sample in samples {
                let normalized = normalizedPoint(from: sample, page: page, pageBounds: pageBounds)
                if let lastEraserPoint,
                   inkDistance(lastEraserPoint, normalized) < threshold * 0.35 {
                    continue
                }
                let kept = splitStrokes(nextStrokes, erasingAt: normalized, threshold: threshold)
                if kept.map(\.id) != nextStrokes.map(\.id) || kept.count != nextStrokes.count {
                    nextStrokes = kept
                    didChange = true
                }
                lastEraserPoint = normalized
            }
            guard didChange else { return }
            activeEraserStrokes = nextStrokes
            onStrokesChanged(pageIndex, nextStrokes)
        }

        private func finishEraserStroke() {
            activeEraserPageIndex = nil
            activeEraserStrokes = []
            lastEraserPoint = nil
        }

        private func strokes(for pageIndex: Int) -> [CodmesInkStroke] {
            annotations?.noteStrokes(pageIndex: pageIndex) ?? []
        }

        private func selectLassoContent(from viewPoints: [CGPoint], page: PDFPage, pageIndex: Int) {
            guard viewPoints.count > 2 else {
                clearLassoSelection()
                return
            }
            let polygon = viewPoints.map { normalizedPoint(from: $0, page: page) }
            guard let bounds = bounds(for: polygon) else {
                clearLassoSelection()
                return
            }
            let selectedStrokeIds = Set(strokes(for: pageIndex).filter { stroke in
                strokeIntersectsLasso(stroke, polygon: polygon, lassoBounds: bounds)
            }.map(\.id))
            let selectedObjects = objects(for: pageIndex).filter { object in
                guard let box = object.bbox?.normalizedOrSelf else { return false }
                return objectIntersectsLasso(box: box, polygon: polygon, lassoBounds: bounds)
            }
            let selectedObjectIds = Set(selectedObjects.map(\.id))

            guard !selectedStrokeIds.isEmpty || !selectedObjectIds.isEmpty else {
                clearLassoSelection()
                return
            }

            lassoSelection = LassoSelection(
                pageIndex: pageIndex,
                strokeIds: selectedStrokeIds,
                objectIds: selectedObjectIds,
                bounds: bounds,
                outline: polygon
            )
            notifyLassoSelectionChanged()
            if let firstObject = selectedObjects.first {
                selectedObjectId = firstObject.id
                onObjectSelected(firstObject)
            }
            applyCodmesInkAnnotations()
            applyAnnotationsToVisibleOverlays()
        }

        private func selectTappedLassoContent(at viewPoint: CGPoint, page: PDFPage, pageIndex: Int) {
            let point = normalizedPoint(from: viewPoint, page: page)
            let pageBounds = page.bounds(for: .mediaBox)
            let hitRadius = max(0.006, 18 / Double(max(min(pageBounds.width, pageBounds.height), 1)))
            let strokeHit = strokes(for: pageIndex)
                .compactMap { stroke -> (stroke: CodmesInkStroke, distance: Double)? in
                    guard let distance = distance(point, to: stroke),
                          distance <= hitRadius else { return nil }
                    return (stroke, distance)
                }
                .min { $0.distance < $1.distance }
            let objectHit = objects(for: pageIndex)
                .compactMap { object -> (object: PDFAnnotationObject, distance: Double)? in
                    guard let box = object.bbox?.normalizedOrSelf else { return nil }
                    let distance = distance(point, to: box)
                    return distance <= hitRadius ? (object, distance) : nil
                }
                .min { $0.distance < $1.distance }

            switch (strokeHit, objectHit) {
            case let (.some(strokeHit), .some(objectHit)) where objectHit.distance < strokeHit.distance:
                selectTappedObject(objectHit.object, pageIndex: pageIndex)
            case let (.some(strokeHit), _):
                selectTappedStroke(strokeHit.stroke, pageIndex: pageIndex)
            case let (_, .some(objectHit)):
                selectTappedObject(objectHit.object, pageIndex: pageIndex)
            default:
                clearLassoSelection()
            }
        }

        private func object(at viewPoint: CGPoint, page: PDFPage, pageIndex: Int) -> PDFAnnotationObject? {
            let point = normalizedPoint(from: viewPoint, page: page)
            let pageBounds = page.bounds(for: .mediaBox)
            let hitSlop = max(0.004, 10 / Double(max(min(pageBounds.width, pageBounds.height), 1)))
            return objects(for: pageIndex).reversed().first { object in
                guard let box = object.bbox?.normalizedOrSelf else { return false }
                let expanded = AnnotationBoundingBox(
                    x: max(0, box.x - hitSlop),
                    y: max(0, box.y - hitSlop),
                    width: min(1, box.width + hitSlop * 2),
                    height: min(1, box.height + hitSlop * 2),
                    normalized: nil
                )
                return contains(point, in: expanded)
            }
        }

        private func selectTappedStroke(_ stroke: CodmesInkStroke, pageIndex: Int) {
            guard let strokeBounds = bounds(for: stroke.points) else { return }
            lassoSelection = LassoSelection(
                pageIndex: pageIndex,
                strokeIds: [stroke.id],
                objectIds: [],
                bounds: strokeBounds,
                outline: []
            )
            notifyLassoSelectionChanged()
            applyCodmesInkAnnotations()
            applyAnnotationsToVisibleOverlays()
        }

        private func selectTappedObject(_ object: PDFAnnotationObject, pageIndex: Int) {
            guard let box = object.bbox?.normalizedOrSelf else { return }
            lassoSelection = LassoSelection(
                pageIndex: pageIndex,
                strokeIds: [],
                objectIds: [object.id],
                bounds: AnnotationBoundingBox(x: box.x, y: box.y, width: box.width, height: box.height, normalized: nil),
                outline: []
            )
            selectedObjectId = object.id
            notifyLassoSelectionChanged()
            onObjectSelected(object)
            applyCodmesInkAnnotations()
            applyAnnotationsToVisibleOverlays()
        }

        private func updateLassoMove(to viewPoint: CGPoint, page: PDFPage, commit: Bool) {
            guard let selection = lassoSelection,
                  selection.pageIndex == activePageIndex,
                  let startSelection = lassoMoveStartSelection,
                  let start = lassoMoveStartPoint else { return }
            let current = normalizedPoint(from: viewPoint, page: page)
            let dx = current.x - start.x
            let dy = current.y - start.y
            let movedStrokes = lassoMoveStartStrokes.map { offset(stroke: $0, dx: dx, dy: dy) }
            let movedObjects = lassoMoveStartObjects.map { offset(object: $0, dx: dx, dy: dy) }
            guard let selectionBounds = startSelection.bounds.normalizedOrSelf else { return }
            let nextBounds = offset(box: selectionBounds, dx: dx, dy: dy)
            let nextOutline = offset(points: startSelection.outline, dx: dx, dy: dy)

            replaceLocalObjects(movedObjects)
            lassoSelection = LassoSelection(
                pageIndex: selection.pageIndex,
                strokeIds: selection.strokeIds,
                objectIds: selection.objectIds,
                bounds: AnnotationBoundingBox(x: nextBounds.x, y: nextBounds.y, width: nextBounds.width, height: nextBounds.height, normalized: nil),
                outline: nextOutline
            )
            notifyLassoSelectionChanged(isMoving: !commit)
            if commit {
                replaceLocalStrokes(pageIndex: selection.pageIndex, movedStrokes: movedStrokes, selectedIds: selection.strokeIds)
                lassoInteraction = nil
                lassoMoveStartSelection = nil
                clearLassoMovePreviews()
                applyCodmesInkAnnotations()
                applyAnnotationsToVisibleOverlays()
            } else if let overlay = overlays[selection.pageIndex] {
                for strokeId in selection.strokeIds {
                    removeCodmesInkAnnotation(id: strokeId, from: page)
                }
                clearShapeHandles(in: overlay)
                updateLassoMovePreview(movedStrokes, in: overlay)
                applyObjects(to: overlay, pageIndex: selection.pageIndex)
                applyLassoSelectionOutline(to: overlay, pageIndex: selection.pageIndex)
            }

            if commit {
                notifyLassoSelectionChanged(isMoving: false)
                onStrokesChanged(selection.pageIndex, strokes(for: selection.pageIndex))
                for object in movedObjects {
                    onObjectChanged(object)
                }
            }
        }

        private func clearLassoSelection(notify: Bool = true) {
            lassoSelection = nil
            selectedObjectId = nil
            if notify {
                onLassoSelectionChanged(nil)
            }
            clearLassoMovePreviews()
            applyCodmesInkAnnotations()
            applyAnnotationsToVisibleOverlays()
        }

        private func notifyLassoSelectionChanged(isMoving: Bool = false) {
            guard let lassoSelection else {
                onLassoSelectionChanged(nil)
                return
            }
            onLassoSelectionChanged(PDFLassoSelectionSummary(
                pageIndex: lassoSelection.pageIndex,
                strokeIds: lassoSelection.strokeIds,
                objectIds: lassoSelection.objectIds,
                bounds: lassoSelection.bounds,
                optionAnchor: optionAnchor(for: lassoSelection),
                isMoving: isMoving
            ))
        }

        private func optionAnchor(for selection: LassoSelection) -> CGPoint? {
            guard let pdfView,
                  let page = pdfView.document?.page(at: selection.pageIndex),
                  let box = selection.bounds.normalizedOrSelf else { return nil }
            let pageBounds = page.bounds(for: .mediaBox)
            let topLeft = CGPoint(
                x: pageBounds.minX + pageBounds.width * box.x,
                y: pageBounds.minY + pageBounds.height * (1 - box.y)
            )
            let bottomRight = CGPoint(
                x: pageBounds.minX + pageBounds.width * (box.x + box.width),
                y: pageBounds.minY + pageBounds.height * (1 - box.y - box.height)
            )
            let viewTopLeft = pdfView.convert(topLeft, from: page)
            let viewBottomRight = pdfView.convert(bottomRight, from: page)
            let rect = CGRect(
                x: min(viewTopLeft.x, viewBottomRight.x),
                y: min(viewTopLeft.y, viewBottomRight.y),
                width: abs(viewBottomRight.x - viewTopLeft.x),
                height: abs(viewBottomRight.y - viewTopLeft.y)
            )
            return CGPoint(x: rect.midX, y: rect.minY - 22)
        }

        private func applyShapeHandles(to overlay: PDFPageAnnotationOverlay, pageIndex: Int) {
            clearShapeHandles(in: overlay)
            overlay.shapePreviewLayer.path = nil

            guard isWritingMode,
                  lassoInteraction != .moving,
                  activeShapeHandleDrag == nil,
                  let selected = selectedShapeStroke(pageIndex: pageIndex) else { return }
            let stroke = selected.stroke
            let kind = selected.kind

            for (handleIndex, point) in shapeHandlePoints(for: stroke, kind: kind, in: overlay.bounds) {
                let handle = PDFShapeHandleView(strokeId: stroke.id, kind: kind, handleIndex: handleIndex)
                handle.center = point
                let pan = UIPanGestureRecognizer(target: self, action: #selector(handleShapeHandlePan(_:)))
                pan.maximumNumberOfTouches = 1
                pan.cancelsTouchesInView = true
                pan.allowedTouchTypes = [
                    NSNumber(value: UITouch.TouchType.direct.rawValue),
                    NSNumber(value: UITouch.TouchType.pencil.rawValue)
                ]
                handle.addGestureRecognizer(pan)
                overlay.addSubview(handle)
                overlay.bringSubviewToFront(handle)
                overlay.shapeHandleViews.append(handle)
            }
        }

        private func clearShapeHandles(in overlay: PDFPageAnnotationOverlay) {
            for handle in overlay.shapeHandleViews {
                handle.removeFromSuperview()
            }
            overlay.shapeHandleViews.removeAll()
        }

        private func applyTextResizeHandles(to overlay: PDFPageAnnotationOverlay, pageIndex: Int) {
            guard activeTextResizeObjectId == nil else { return }
            clearTextResizeHandles(in: overlay)
            guard isWritingMode,
                  activeObjectMoveId == nil,
                  let selectedObjectId,
                  let object = object(with: selectedObjectId),
                  object.pageIndex == pageIndex,
                  object.type.lowercased().contains("text"),
                  let textView = overlay.objectViews[selectedObjectId] as? UITextView,
                  lassoSelection?.objectIds.contains(selectedObjectId) == true else { return }

            let frame = textView.frame
            for edge in [PDFTextResizeHandleView.Edge.left, .right] {
                let handle = PDFTextResizeHandleView(objectId: selectedObjectId, edge: edge)
                handle.center = CGPoint(
                    x: edge == .left ? frame.minX : frame.maxX,
                    y: frame.midY
                )
                overlay.addSubview(handle)
                overlay.bringSubviewToFront(handle)
                overlay.textResizeHandleViews.append(handle)
            }
        }

        private func clearTextResizeHandles(in overlay: PDFPageAnnotationOverlay) {
            for handle in overlay.textResizeHandleViews {
                handle.removeFromSuperview()
            }
            overlay.textResizeHandleViews.removeAll()
        }

        private func clearTextResizeHandlesInVisibleOverlays() {
            for overlay in overlays.values {
                clearTextResizeHandles(in: overlay)
            }
        }

        @objc func handleTextResizePan(_ gesture: UIPanGestureRecognizer) {
            if gesture.state == .began {
                guard let handle = textResizeHandle(at: gesture),
                      let overlay = handle.superview as? PDFPageAnnotationOverlay else { return }
                activeTextResizeObjectId = handle.objectId
                activeTextResizePageIndex = overlayPageIndex(for: overlay)
                activeTextResizeEdge = handle.edge
            }
            guard let objectId = activeTextResizeObjectId,
                  let edge = activeTextResizeEdge,
                  let overlay = activeTextResizePageIndex.flatMap({ overlays[$0] }) ?? textResizeHandleOverlay(for: objectId),
                  let textView = overlay.objectViews[objectId] as? UITextView,
                  var object = object(with: objectId),
                  object.type.lowercased().contains("text") else { return }
            let pageIndex = object.pageIndex ?? activeTextResizePageIndex ?? 0
            if gesture.state == .began {
                activeTextResizePageIndex = pageIndex
                selectedObjectId = objectId
                editingTextObjectId = nil
                textView.resignFirstResponder()
                textView.isEditable = false
                textView.isSelectable = false
                lockPDFScrollingForObjectMove()
                onObjectSelected(object)
            }

            var frame = textView.frame
            let translation = gesture.translation(in: overlay)
            let minWidth: CGFloat = 36
            if edge == .left {
                let proposedMinX = min(max(0, frame.minX + translation.x), frame.maxX - minWidth)
                frame.size.width = frame.maxX - proposedMinX
                frame.origin.x = proposedMinX
            } else {
                let proposedMaxX = max(frame.minX + minWidth, min(overlay.bounds.width, frame.maxX + translation.x))
                frame.size.width = proposedMaxX - frame.minX
            }
            gesture.setTranslation(.zero, in: overlay)

            textView.frame = frame
            var metadata = object.metadata ?? [:]
            metadata[textManualWidthMetadataKey] = "true"
            object.metadata = metadata
            resizeTextObjectIfNeeded(&object, textView: textView)
            updateSelection(for: object)
            positionTextResizeHandles(in: overlay, around: textView.frame, objectId: objectId)

            if gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed {
                activeTextResizeObjectId = nil
                activeTextResizePageIndex = nil
                activeTextResizeEdge = nil
                if let box = object.bbox {
                    lassoSelection = LassoSelection(
                        pageIndex: pageIndex,
                        strokeIds: [],
                        objectIds: [object.id],
                        bounds: box,
                        outline: []
                    )
                    notifyLassoSelectionChanged()
                }
                onObjectChanged(object)
                unlockPDFScrollingAfterActiveDrawing()
                applyAnnotationsToVisibleOverlays()
            }
        }

        private func positionTextResizeHandles(in overlay: PDFPageAnnotationOverlay, around frame: CGRect, objectId: String) {
            for view in overlay.textResizeHandleViews {
                guard let handle = view as? PDFTextResizeHandleView, handle.objectId == objectId else { continue }
                handle.center = CGPoint(
                    x: handle.edge == .left ? frame.minX : frame.maxX,
                    y: frame.midY
                )
            }
        }

        private func applyLassoSelectionOutline(to overlay: PDFPageAnnotationOverlay, pageIndex: Int) {
            guard let selection = lassoSelection,
                  selection.pageIndex == pageIndex,
                  selection.outline.count > 2 else {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                overlay.selectionOutlineLayer.path = nil
                CATransaction.commit()
                return
            }
            let path = UIBezierPath()
            path.move(to: overlayPoint(selection.outline[0], in: overlay.bounds))
            for point in selection.outline.dropFirst() {
                path.addLine(to: overlayPoint(point, in: overlay.bounds))
            }
            path.close()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            overlay.selectionOutlineLayer.path = path.cgPath
            CATransaction.commit()
        }

        private func updateLassoMovePreview(_ strokes: [CodmesInkStroke], in overlay: PDFPageAnnotationOverlay) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            clearLassoMovePreview(in: overlay)
            for stroke in strokes where stroke.points.count > 1 {
                let layer = CAShapeLayer()
                let path = UIBezierPath()
                path.move(to: overlayPoint(stroke.points[0], in: overlay.bounds))
                for point in stroke.points.dropFirst() {
                    path.addLine(to: overlayPoint(point, in: overlay.bounds))
                }
                layer.path = path.cgPath
                layer.fillColor = UIColor.clear.cgColor
                layer.strokeColor = UIColor(hexString: stroke.color).cgColor
                layer.lineWidth = CGFloat(max(0.5, stroke.width))
                layer.lineCap = .round
                layer.lineJoin = .round
                overlay.lassoMovePreviewLayer.addSublayer(layer)
            }
            CATransaction.commit()
        }

        private func clearLassoMovePreview(in overlay: PDFPageAnnotationOverlay) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            overlay.lassoMovePreviewLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
            CATransaction.commit()
        }

        private func clearLassoMovePreviews() {
            for overlay in overlays.values {
                clearLassoMovePreview(in: overlay)
            }
        }

        private func updateShapeLayerPreview(_ stroke: CodmesInkStroke, in overlay: PDFPageAnnotationOverlay) {
            guard stroke.points.count > 1 else {
                overlay.shapePreviewLayer.path = nil
                return
            }
            let path = UIBezierPath()
            path.move(to: overlayPoint(stroke.points[0], in: overlay.bounds))
            for point in stroke.points.dropFirst() {
                path.addLine(to: overlayPoint(point, in: overlay.bounds))
            }
            overlay.shapePreviewLayer.path = path.cgPath
            overlay.shapePreviewLayer.strokeColor = UIColor(hexString: stroke.color).cgColor
            overlay.shapePreviewLayer.lineWidth = CGFloat(max(0.5, stroke.width + 1.5))
            overlay.shapePreviewLayer.opacity = 1
        }

        private func overlayPoint(_ point: CodmesInkPoint, in bounds: CGRect) -> CGPoint {
            CGPoint(x: bounds.width * point.x, y: bounds.height * point.y)
        }

        private func selectedShapeStroke(pageIndex: Int?) -> (stroke: CodmesInkStroke, kind: String)? {
            guard let pageIndex,
                  let selection = lassoSelection,
                  selection.pageIndex == pageIndex,
                  selection.strokeIds.count == 1,
                  let strokeId = selection.strokeIds.first,
                  let stroke = strokes(for: pageIndex).first(where: { $0.id == strokeId }),
                  let kind = shapeKind(for: stroke) else { return nil }
            return (stroke, kind)
        }

        private func shapeKind(for stroke: CodmesInkStroke) -> String? {
            guard stroke.tool.hasPrefix("shape:") else { return nil }
            return String(stroke.tool.dropFirst("shape:".count))
        }

        private func shapeHandlePoints(for stroke: CodmesInkStroke, kind: String, in bounds: CGRect) -> [(Int, CGPoint)] {
            func viewPoint(_ point: CodmesInkPoint) -> CGPoint {
                CGPoint(x: bounds.width * point.x, y: bounds.height * point.y)
            }

            switch kind {
            case "line":
                guard let first = stroke.points.first, let last = stroke.points.last else { return [] }
                return [(0, viewPoint(first)), (1, viewPoint(last))]
            case "polyline":
                return stroke.points.enumerated().map { ($0.offset, viewPoint($0.element)) }
            case "rectangle":
                return stroke.points.prefix(4).enumerated().map { ($0.offset, viewPoint($0.element)) }
            case "triangle":
                return stroke.points.prefix(3).enumerated().map { ($0.offset, viewPoint($0.element)) }
            case "circle":
                guard let box = normalizedBounds(for: stroke.points) else { return [] }
                return [
                    (0, CGPoint(x: bounds.width * (box.x + box.width / 2), y: bounds.height * box.y)),
                    (1, CGPoint(x: bounds.width * (box.x + box.width), y: bounds.height * (box.y + box.height / 2))),
                    (2, CGPoint(x: bounds.width * (box.x + box.width / 2), y: bounds.height * (box.y + box.height))),
                    (3, CGPoint(x: bounds.width * box.x, y: bounds.height * (box.y + box.height / 2)))
                ]
            case "ellipse":
                guard let geometry = normalizedEllipseGeometry(from: stroke.points) else { return [] }
                return normalizedEllipseHandlePoints(for: geometry, in: bounds)
            default:
                return []
            }
        }

        private func shapeHandleDrag(at viewPoint: CGPoint, pageIndex: Int) -> ShapeHandleDrag? {
            guard let pdfView,
                  let selection = lassoSelection,
                  selection.pageIndex == pageIndex,
                  let overlay = overlays[pageIndex] else { return nil }
            let overlayPoint = overlay.convert(viewPoint, from: pdfView)
            for view in overlay.shapeHandleViews.reversed() {
                guard let handle = view as? PDFShapeHandleView,
                      !handle.isHidden,
                      handle.alpha > 0.01,
                      handle.isUserInteractionEnabled,
                      selection.strokeIds.contains(handle.strokeId) else { continue }
                let handlePoint = handle.convert(overlayPoint, from: overlay)
                if handle.point(inside: handlePoint, with: nil) {
                    return ShapeHandleDrag(
                        pageIndex: pageIndex,
                        strokeId: handle.strokeId,
                        kind: handle.kind,
                        handleIndex: handle.handleIndex
                    )
                }
            }
            return nil
        }

        private func updateShapeHandleDrag(_ drag: ShapeHandleDrag, to viewPoint: CGPoint, commit: Bool) {
            guard let pdfView,
                  let overlay = overlays[drag.pageIndex],
                  var stroke = activeShapeHandleStartStroke ?? strokes(for: drag.pageIndex).first(where: { $0.id == drag.strokeId }) else { return }
            let location = overlay.convert(viewPoint, from: pdfView)
            let normalized = CodmesInkPoint(
                x: Double(max(0, min(overlay.bounds.width, location.x)) / max(overlay.bounds.width, 1)),
                y: Double(max(0, min(overlay.bounds.height, location.y)) / max(overlay.bounds.height, 1)),
                pressure: nil,
                timeOffset: nil
            )
            stroke = updateShapeStroke(stroke, kind: drag.kind, handleIndex: drag.handleIndex, to: normalized)
            if let nextBounds = bounds(for: stroke.points) {
                lassoSelection = LassoSelection(
                    pageIndex: drag.pageIndex,
                    strokeIds: [stroke.id],
                    objectIds: [],
                    bounds: nextBounds,
                    outline: []
                )
            }
            clearShapeHandles(in: overlay)
            updateShapeLayerPreview(stroke, in: overlay)

            if commit {
                replaceLocalStrokes(pageIndex: drag.pageIndex, movedStrokes: [stroke], selectedIds: [stroke.id])
                overlay.shapePreviewLayer.path = nil
                activeShapeHandleDrag = nil
                activeShapeHandleStartStroke = nil
                notifyLassoSelectionChanged()
                onStrokesChanged(drag.pageIndex, strokes(for: drag.pageIndex))
                applyCodmesInkAnnotations()
                applyAnnotationsToVisibleOverlays()
            }
        }

        @objc private func handleShapeHandlePan(_ gesture: UIPanGestureRecognizer) {
            guard let handle = gesture.view as? PDFShapeHandleView,
                  handle.superview is PDFPageAnnotationOverlay,
                  let selection = lassoSelection,
                  selection.strokeIds.contains(handle.strokeId),
                  let pdfView else { return }

            if gesture.state == .began,
               let page = pdfView.document?.page(at: selection.pageIndex) {
                let drag = ShapeHandleDrag(pageIndex: selection.pageIndex, strokeId: handle.strokeId, kind: handle.kind, handleIndex: handle.handleIndex)
                activeShapeHandleDrag = drag
                activeShapeHandleStartStroke = strokes(for: selection.pageIndex).first(where: { $0.id == handle.strokeId })
                removeCodmesInkAnnotation(id: handle.strokeId, from: page)
                if let overlay = overlays[selection.pageIndex] {
                    clearShapeHandles(in: overlay)
                }
            }
            let drag = ShapeHandleDrag(pageIndex: selection.pageIndex, strokeId: handle.strokeId, kind: handle.kind, handleIndex: handle.handleIndex)
            updateShapeHandleDrag(drag, to: gesture.location(in: pdfView), commit: gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed)
        }

        private func updateShapeStroke(_ stroke: CodmesInkStroke, kind: String, handleIndex: Int, to point: CodmesInkPoint) -> CodmesInkStroke {
            var next = stroke
            switch kind {
            case "line":
                guard next.points.count >= 2 else { return next }
                if handleIndex == 0 {
                    next.points[0] = point
                } else {
                    next.points[next.points.count - 1] = point
                }
            case "polyline":
                guard next.points.indices.contains(handleIndex) else { return next }
                next.points[handleIndex] = point
            case "triangle":
                guard next.points.count >= 4, handleIndex < 3 else { return next }
                next.points[handleIndex] = point
                if handleIndex == 0 {
                    next.points[next.points.count - 1] = point
                }
            case "rectangle":
                guard let box = normalizedBounds(for: next.points) else { return next }
                let opposite: CodmesInkPoint
                switch handleIndex {
                case 0:
                    opposite = CodmesInkPoint(x: box.x + box.width, y: box.y + box.height, pressure: nil, timeOffset: nil)
                case 1:
                    opposite = CodmesInkPoint(x: box.x, y: box.y + box.height, pressure: nil, timeOffset: nil)
                case 2:
                    opposite = CodmesInkPoint(x: box.x, y: box.y, pressure: nil, timeOffset: nil)
                default:
                    opposite = CodmesInkPoint(x: box.x + box.width, y: box.y, pressure: nil, timeOffset: nil)
                }
                next.points = rectanglePoints(from: point, to: opposite)
            case "circle":
                guard let box = normalizedBounds(for: next.points) else { return next }
                let center = CodmesInkPoint(
                    x: box.x + box.width / 2,
                    y: box.y + box.height / 2,
                    pressure: nil,
                    timeOffset: nil
                )
                let radius = max(abs(point.x - center.x), abs(point.y - center.y), 0.005)
                next.points = circlePoints(center: center, radius: radius, count: 48)
            case "ellipse":
                guard let geometry = normalizedEllipseGeometry(from: next.points) else { return next }
                let adjusted = adjustedNormalizedEllipseGeometry(geometry, handleIndex: handleIndex, to: point)
                next.points = ellipsePoints(center: adjusted.center, rx: adjusted.rx, ry: adjusted.ry, angle: adjusted.angle, count: 48)
            default:
                break
            }
            return next
        }

        private func normalizedBounds(for points: [CodmesInkPoint]) -> NormalizedBoundingBox? {
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
            return normalizedBox(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
        }

        private func normalizedBox(minX: Double, minY: Double, maxX: Double, maxY: Double) -> NormalizedBoundingBox {
            let left = max(0, min(1, min(minX, maxX)))
            let right = max(0, min(1, max(minX, maxX)))
            let top = max(0, min(1, min(minY, maxY)))
            let bottom = max(0, min(1, max(minY, maxY)))
            return NormalizedBoundingBox(
                x: left,
                y: top,
                width: max(0.01, right - left),
                height: max(0.01, bottom - top)
            )
        }

        private func normalizedEllipseGeometry(from points: [CodmesInkPoint]) -> NormalizedEllipseGeometry? {
            let source = openShapePoints(points)
            guard source.count >= 6 else { return nil }
            let centerX = source.reduce(0) { $0 + $1.x } / Double(source.count)
            let centerY = source.reduce(0) { $0 + $1.y } / Double(source.count)
            var xx = 0.0
            var xy = 0.0
            var yy = 0.0
            for point in source {
                let dx = point.x - centerX
                let dy = point.y - centerY
                xx += dx * dx
                xy += dx * dy
                yy += dy * dy
            }
            var angle = 0.5 * atan2(2 * xy, xx - yy)
            let cosA = cos(angle)
            let sinA = sin(angle)
            var rx = 0.005
            var ry = 0.005
            for point in source {
                let dx = point.x - centerX
                let dy = point.y - centerY
                rx = max(rx, abs(dx * cosA + dy * sinA))
                ry = max(ry, abs(-dx * sinA + dy * cosA))
            }
            if ry > rx {
                swap(&rx, &ry)
                angle += Double.pi / 2
            }
            return NormalizedEllipseGeometry(
                center: CodmesInkPoint(x: centerX, y: centerY, pressure: nil, timeOffset: nil),
                rx: max(rx, 0.005),
                ry: max(ry, 0.005),
                angle: angle
            )
        }

        private func adjustedNormalizedEllipseGeometry(_ geometry: NormalizedEllipseGeometry, handleIndex: Int, to point: CodmesInkPoint) -> NormalizedEllipseGeometry {
            let dx = point.x - geometry.center.x
            let dy = point.y - geometry.center.y
            let distanceFromCenter = max(hypot(dx, dy), 0.005)
            let ratio = max(geometry.rx / max(geometry.ry, 0.005), 1.05)
            switch handleIndex {
            case 0:
                return NormalizedEllipseGeometry(center: geometry.center, rx: distanceFromCenter * ratio, ry: distanceFromCenter, angle: atan2(dy, dx) + Double.pi / 2)
            case 2:
                return NormalizedEllipseGeometry(center: geometry.center, rx: distanceFromCenter * ratio, ry: distanceFromCenter, angle: atan2(dy, dx) - Double.pi / 2)
            case 3:
                return NormalizedEllipseGeometry(center: geometry.center, rx: distanceFromCenter, ry: distanceFromCenter / ratio, angle: atan2(dy, dx) + Double.pi)
            default:
                return NormalizedEllipseGeometry(center: geometry.center, rx: distanceFromCenter, ry: distanceFromCenter / ratio, angle: atan2(dy, dx))
            }
        }

        private func normalizedEllipseHandlePoints(for geometry: NormalizedEllipseGeometry, in bounds: CGRect) -> [(Int, CGPoint)] {
            let cosA = cos(geometry.angle)
            let sinA = sin(geometry.angle)
            let major = (x: cosA * geometry.rx, y: sinA * geometry.rx)
            let minor = (x: -sinA * geometry.ry, y: cosA * geometry.ry)
            let handles = [
                (0, geometry.center.x - minor.x, geometry.center.y - minor.y),
                (1, geometry.center.x + major.x, geometry.center.y + major.y),
                (2, geometry.center.x + minor.x, geometry.center.y + minor.y),
                (3, geometry.center.x - major.x, geometry.center.y - major.y)
            ]
            return handles.map { index, x, y in
                (index, CGPoint(x: bounds.width * x, y: bounds.height * y))
            }
        }

        private func openShapePoints(_ points: [CodmesInkPoint]) -> [CodmesInkPoint] {
            guard points.count > 2,
                  let first = points.first,
                  let last = points.last,
                  hypot(first.x - last.x, first.y - last.y) < 0.0001 else { return points }
            return Array(points.dropLast())
        }

        private func rectanglePoints(from point: CodmesInkPoint, to opposite: CodmesInkPoint) -> [CodmesInkPoint] {
            let box = normalizedBox(minX: point.x, minY: point.y, maxX: opposite.x, maxY: opposite.y)
            let topLeft = CodmesInkPoint(x: box.x, y: box.y, pressure: nil, timeOffset: nil)
            let topRight = CodmesInkPoint(x: box.x + box.width, y: box.y, pressure: nil, timeOffset: nil)
            let bottomRight = CodmesInkPoint(x: box.x + box.width, y: box.y + box.height, pressure: nil, timeOffset: nil)
            let bottomLeft = CodmesInkPoint(x: box.x, y: box.y + box.height, pressure: nil, timeOffset: nil)
            return [topLeft, topRight, bottomRight, bottomLeft, topLeft]
        }

        private func circlePoints(center: CodmesInkPoint, radius: Double, count: Int) -> [CodmesInkPoint] {
            let clampedRadius = max(0.005, min(radius, center.x, 1 - center.x, center.y, 1 - center.y))
            return (0...count).map { index in
                let angle = Double(index) / Double(count) * Double.pi * 2
                return CodmesInkPoint(
                    x: center.x + cos(angle) * clampedRadius,
                    y: center.y + sin(angle) * clampedRadius,
                    pressure: nil,
                    timeOffset: nil
                )
            }
        }

        private func ellipsePoints(in box: NormalizedBoundingBox, count: Int) -> [CodmesInkPoint] {
            let centerX = box.x + box.width / 2
            let centerY = box.y + box.height / 2
            let rx = box.width / 2
            let ry = box.height / 2
            return (0...count).map { index in
                let angle = Double(index) / Double(count) * Double.pi * 2
                return CodmesInkPoint(
                    x: centerX + cos(angle) * rx,
                    y: centerY + sin(angle) * ry,
                    pressure: nil,
                    timeOffset: nil
                )
            }
        }

        private func ellipsePoints(center: CodmesInkPoint, rx: Double, ry: Double, angle: Double, count: Int) -> [CodmesInkPoint] {
            let maxRadius = max(0.005, min(center.x, 1 - center.x, center.y, 1 - center.y))
            let clampedRX = min(max(rx, 0.005), maxRadius)
            let clampedRY = min(max(ry, 0.005), maxRadius)
            return (0...count).map { index in
                let theta = Double(index) / Double(count) * Double.pi * 2
                let x = cos(theta) * clampedRX
                let y = sin(theta) * clampedRY
                return CodmesInkPoint(
                    x: center.x + x * cos(angle) - y * sin(angle),
                    y: center.y + x * sin(angle) + y * cos(angle),
                    pressure: nil,
                    timeOffset: nil
                )
            }
        }

        private func appendLocalStroke(pageIndex: Int, stroke: CodmesInkStroke) {
            var next = annotations ?? PDFAnnotationDocument(schemaVersion: 2, documentPath: "", updatedAt: nil, pages: [], objects: [])
            if let index = next.pages.firstIndex(where: { $0.pageIndex == pageIndex }) {
                var strokes = next.pages[index].inkStrokes ?? []
                if !strokes.contains(where: { $0.id == stroke.id }) {
                    strokes.append(stroke)
                }
                next.pages[index].inkStrokes = strokes
            } else {
                next.pages.append(PDFAnnotationPage(pageIndex: pageIndex, inkDataBase64: nil, inkStrokes: [stroke], objects: []))
                next.pages.sort { $0.pageIndex < $1.pageIndex }
            }
            next.syncNoteElementsFromLegacy()
            annotations = next
        }

        private func selectShapeStroke(_ stroke: CodmesInkStroke, pageIndex: Int) {
            guard shapeKind(for: stroke) != nil,
                  let strokeBounds = bounds(for: stroke.points) else { return }
            lassoSelection = LassoSelection(
                pageIndex: pageIndex,
                strokeIds: [stroke.id],
                objectIds: [],
                bounds: strokeBounds,
                outline: []
            )
            notifyLassoSelectionChanged()
            applyToolToVisibleOverlays()
        }

        private func replaceLocalStrokes(pageIndex: Int, movedStrokes: [CodmesInkStroke], selectedIds: Set<String>) {
            var next = annotations ?? PDFAnnotationDocument(schemaVersion: 2, documentPath: "", updatedAt: nil, pages: [], objects: [])
            let movedById = Dictionary(uniqueKeysWithValues: movedStrokes.map { ($0.id, $0) })
            if let index = next.pages.firstIndex(where: { $0.pageIndex == pageIndex }) {
                let current = next.pages[index].inkStrokes ?? []
                next.pages[index].inkStrokes = current.map { selectedIds.contains($0.id) ? (movedById[$0.id] ?? $0) : $0 }
                next.pages[index].elements = next.pages[index].elements?.map { element in
                    guard let stroke = movedById[element.id] else { return element }
                    return element.replacing(stroke: stroke)
                }
            }
            next.elements = next.elements?.map { element in
                guard element.pageIndex == pageIndex, let stroke = movedById[element.id] else { return element }
                return element.replacing(stroke: stroke)
            }
            next.syncNoteElementsFromLegacy()
            annotations = next
        }

        private func replaceLocalObjects(_ movedObjects: [PDFAnnotationObject]) {
            guard !movedObjects.isEmpty else { return }
            var next = annotations ?? PDFAnnotationDocument(schemaVersion: 2, documentPath: "", updatedAt: nil, pages: [], objects: [])
            let movedById = Dictionary(uniqueKeysWithValues: movedObjects.map { ($0.id, $0) })
            for pageIndex in next.pages.indices {
                guard var objects = next.pages[pageIndex].objects else { continue }
                objects = objects.map { movedById[$0.id] ?? $0 }
                next.pages[pageIndex].objects = objects
                next.pages[pageIndex].elements = next.pages[pageIndex].elements?.map { element in
                    guard let object = movedById[element.id] else { return element }
                    return element.replacing(object: object)
                }
            }
            next.objects = next.objects.map { movedById[$0.id] ?? $0 }
            next.elements = next.elements?.map { element in
                guard let object = movedById[element.id] else { return element }
                return element.replacing(object: object)
            }
            next.syncNoteElementsFromLegacy()
            annotations = next
        }

        private func bounds(for points: [CodmesInkPoint]) -> AnnotationBoundingBox? {
            CodmesNoteCanvasModel.bounds(for: points)
        }

        private func contains(_ point: CodmesInkPoint, in box: AnnotationBoundingBox) -> Bool {
            guard let normalized = box.normalizedOrSelf else { return false }
            return CodmesNoteCanvasModel.contains(point, in: normalized)
        }

        private func contains(_ point: CodmesInkPoint, in polygon: [CodmesInkPoint]) -> Bool {
            CodmesNoteCanvasModel.contains(point, in: polygon)
        }

        private func strokeIntersectsLasso(_ stroke: CodmesInkStroke, polygon: [CodmesInkPoint], lassoBounds: AnnotationBoundingBox) -> Bool {
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

        private func polygonSegments(_ polygon: [CodmesInkPoint]) -> [(CodmesInkPoint, CodmesInkPoint)] {
            guard polygon.count > 1 else { return [] }
            return zip(polygon, polygon.dropFirst() + [polygon[0]]).map { ($0.0, $0.1) }
        }

        private func segmentsIntersect(_ a: CodmesInkPoint, _ b: CodmesInkPoint, _ c: CodmesInkPoint, _ d: CodmesInkPoint) -> Bool {
            let o1 = orientation(a, b, c)
            let o2 = orientation(a, b, d)
            let o3 = orientation(c, d, a)
            let o4 = orientation(c, d, b)
            if o1 == 0, point(c, liesOnSegmentFrom: a, to: b) { return true }
            if o2 == 0, point(d, liesOnSegmentFrom: a, to: b) { return true }
            if o3 == 0, point(a, liesOnSegmentFrom: c, to: d) { return true }
            if o4 == 0, point(b, liesOnSegmentFrom: c, to: d) { return true }
            return o1 != o2 && o3 != o4
        }

        private func orientation(_ a: CodmesInkPoint, _ b: CodmesInkPoint, _ c: CodmesInkPoint) -> Int {
            let value = (b.y - a.y) * (c.x - b.x) - (b.x - a.x) * (c.y - b.y)
            if abs(value) < 0.000001 { return 0 }
            return value > 0 ? 1 : 2
        }

        private func point(_ point: CodmesInkPoint, liesOnSegmentFrom start: CodmesInkPoint, to end: CodmesInkPoint) -> Bool {
            point.x <= max(start.x, end.x) + 0.000001 &&
                point.x + 0.000001 >= min(start.x, end.x) &&
                point.y <= max(start.y, end.y) + 0.000001 &&
                point.y + 0.000001 >= min(start.y, end.y)
        }

        private func distance(_ point: CodmesInkPoint, toSegmentStart start: CodmesInkPoint, end: CodmesInkPoint) -> Double {
            let dx = end.x - start.x
            let dy = end.y - start.y
            let lengthSquared = dx * dx + dy * dy
            guard lengthSquared > 0 else {
                return hypot(point.x - start.x, point.y - start.y)
            }
            let t = max(0, min(1, ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared))
            let projection = CodmesInkPoint(x: start.x + t * dx, y: start.y + t * dy, pressure: nil, timeOffset: nil)
            return hypot(point.x - projection.x, point.y - projection.y)
        }

        private func distance(_ point: CodmesInkPoint, to stroke: CodmesInkStroke) -> Double? {
            guard stroke.points.count > 1 else { return nil }
            return zip(stroke.points, stroke.points.dropFirst())
                .map { distance(point, toSegmentStart: $0.0, end: $0.1) }
                .min()
        }

        private func distance(_ point: CodmesInkPoint, to box: NormalizedBoundingBox) -> Double {
            if point.x >= box.x,
               point.x <= box.x + box.width,
               point.y >= box.y,
               point.y <= box.y + box.height {
                return 0
            }
            let clampedX = max(box.x, min(box.x + box.width, point.x))
            let clampedY = max(box.y, min(box.y + box.height, point.y))
            return hypot(point.x - clampedX, point.y - clampedY)
        }

        private func objectIntersectsLasso(box: NormalizedBoundingBox, polygon: [CodmesInkPoint], lassoBounds: AnnotationBoundingBox) -> Bool {
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

        private func boxesIntersect(_ a: NormalizedBoundingBox, _ b: NormalizedBoundingBox) -> Bool {
            CodmesNoteCanvasModel.boxesIntersect(a, b)
        }

        private func offset(stroke: CodmesInkStroke, dx: Double, dy: Double) -> CodmesInkStroke {
            var next = stroke
            next.points = stroke.points.map {
                CodmesInkPoint(
                    x: max(0, min(1, $0.x + dx)),
                    y: max(0, min(1, $0.y + dy)),
                    pressure: $0.pressure,
                    timeOffset: $0.timeOffset
                )
            }
            return next
        }

        private func offset(object: PDFAnnotationObject, dx: Double, dy: Double) -> PDFAnnotationObject {
            var next = object
            if let box = object.bbox?.normalizedOrSelf {
                let moved = offset(box: box, dx: dx, dy: dy)
                next.bbox = AnnotationBoundingBox(x: moved.x, y: moved.y, width: moved.width, height: moved.height, normalized: nil)
            }
            return next
        }

        private func offset(points: [CodmesInkPoint], dx: Double, dy: Double) -> [CodmesInkPoint] {
            points.map {
                CodmesInkPoint(
                    x: max(0, min(1, $0.x + dx)),
                    y: max(0, min(1, $0.y + dy)),
                    pressure: $0.pressure,
                    timeOffset: $0.timeOffset
                )
            }
        }

        private func offset(box: NormalizedBoundingBox, dx: Double, dy: Double) -> NormalizedBoundingBox {
            NormalizedBoundingBox(
                x: max(0, min(1 - box.width, box.x + dx)),
                y: max(0, min(1 - box.height, box.y + dy)),
                width: box.width,
                height: box.height
            )
        }

        private func applyAnnotation(to canvas: PKCanvasView, pageIndex: Int) {
            guard let drawing = annotationDrawing(pageIndex: pageIndex, canvasSize: canvas.bounds.size) else { return }
            let data = drawing.dataRepresentation()
            if canvas.drawing.dataRepresentation() == data { return }
            setDrawing(drawing, on: canvas)
        }

        private func annotationDrawing(pageIndex: Int, canvasSize: CGSize) -> PKDrawing? {
            guard let page = annotations?.pages.first(where: { $0.pageIndex == pageIndex }) else { return nil }
            if let encoded = page.inkDataBase64, let data = Data(base64Encoded: encoded), let drawing = try? PKDrawing(data: data) { return drawing }
            guard let strokes = page.inkStrokes else { return nil }
            // A server object-level merge invalidates the derived whole-page PencilKit blob.
            // Reconstruct it from the authoritative structured strokes, including additions.
            return PKDrawing(strokes: strokes.map { stroke in
                let points = stroke.points.map { point in
                    PKStrokePoint(location: CGPoint(x: point.x * canvasSize.width, y: point.y * canvasSize.height),
                                  timeOffset: point.timeOffset ?? 0, size: CGSize(width: stroke.width, height: stroke.width),
                                  opacity: stroke.opacity ?? 1, force: point.pressure ?? 1, azimuth: 0, altitude: .pi / 2)
                }
                return PKStroke(ink: PKInk(.pen, color: UIColor(hexString: stroke.color)),
                                path: PKStrokePath(controlPoints: points, creationDate: pencilDate(for: stroke.id)))
            })
        }

        private func setDrawing(_ drawing: PKDrawing, on canvas: PKCanvasView) {
            applyingProgrammaticDrawing = true
            canvas.drawing = drawing
            applyingProgrammaticDrawing = false
        }

        private func objects(for pageIndex: Int) -> [PDFAnnotationObject] {
            annotations?.noteObjects(pageIndex: pageIndex) ?? []
        }

        private func applyObjects(to overlay: PDFPageAnnotationOverlay, pageIndex: Int) {
            let objects = objects(for: pageIndex)
            let liveIds = Set(objects.map(\.id))
            for (id, view) in overlay.objectViews where !liveIds.contains(id) {
                view.removeFromSuperview()
                overlay.objectViews[id] = nil
            }

            for object in objects {
                let view = overlay.objectViews[object.id] ?? makeObjectView(object: object, pageIndex: pageIndex)
                if overlay.objectViews[object.id] == nil {
                    overlay.objectViews[object.id] = view
                    overlay.addSubview(view)
                }
                configureObjectView(view, object: object)
                if (activeObjectMoveId != object.id || activeObjectMovePageIndex != pageIndex) &&
                    (activeTextResizeObjectId != object.id || activeTextResizePageIndex != pageIndex) {
                    view.frame = frame(for: object.bbox, in: overlay.bounds)
                }
                let isTextObject = object.type.lowercased().contains("text")
                view.isUserInteractionEnabled = isWritingMode && (tool == .lasso || isTextObject)
                overlay.bringSubviewToFront(view)
            }
            if let selectedObjectId, let selected = overlay.objectViews[selectedObjectId] {
                overlay.bringSubviewToFront(selected)
            }
        }

        private func makeObjectView(object: PDFAnnotationObject, pageIndex: Int) -> UIView {
            let view: UIView
            if object.type.lowercased().contains("image"), let dataString = object.dataBase64,
               let data = Data(base64Encoded: dataString.replacingOccurrences(of: "^data:[^,]+,", with: "", options: .regularExpression)),
               let image = UIImage(data: data) {
                let imageView = UIImageView(image: image)
                imageView.contentMode = .scaleAspectFit
                imageView.backgroundColor = UIColor.secondarySystemBackground.withAlphaComponent(0.35)
                view = imageView
            } else {
                let textView = UITextView()
                textView.delegate = self
                textView.backgroundColor = .clear
                textView.textContainerInset = UIEdgeInsets(top: 3, left: 4, bottom: 3, right: 4)
                textView.textContainer.lineFragmentPadding = 0
                textView.isScrollEnabled = false
                textView.panGestureRecognizer.isEnabled = false
                textView.autocorrectionType = .default
                textView.autocapitalizationType = .sentences
                textView.keyboardDismissMode = .interactive
                textView.tintColor = .black
                view = textView
            }
            view.layer.borderColor = object.type.lowercased().contains("text")
                ? UIColor.clear.cgColor
                : UIColor.systemBlue.withAlphaComponent(0.45).cgColor
            view.layer.borderWidth = object.type.lowercased().contains("text") ? 0 : 1
            view.layer.cornerRadius = object.type.lowercased().contains("text") ? 0 : 6
            view.clipsToBounds = true
            view.accessibilityIdentifier = object.id
            addGestures(to: view, object: object, pageIndex: pageIndex)
            return view
        }

        private func configureObjectView(_ view: UIView, object: PDFAnnotationObject) {
            if let textView = view as? UITextView {
                if !textView.isFirstResponder {
                    textView.text = object.text ?? ""
                }
                textView.font = .systemFont(ofSize: CGFloat(Double(object.metadata?["fontSize"] ?? "16") ?? 16), weight: .regular)
                if let color = object.metadata?["color"] {
                    textView.textColor = UIColor(hexString: color)
                } else {
                    textView.textColor = .black
                }
                textView.tintColor = .black
                let isEditingText = editingTextObjectId == object.id || textView.isFirstResponder
                textView.isEditable = isWritingMode && isEditingText
                textView.isSelectable = isWritingMode && isEditingText
                textView.panGestureRecognizer.isEnabled = false
                textView.textContainer.widthTracksTextView = true
            }
            let directlySelected = object.id == selectedObjectId && lassoSelection?.objectIds.contains(object.id) != true
            if let textView = view as? UITextView {
                let isLassoSelected = lassoSelection?.objectIds.contains(object.id) == true
                let isEditing = textView.isFirstResponder || editingTextObjectId == object.id || (object.text ?? "").isEmpty && selectedObjectId == object.id
                if isEditing {
                    view.backgroundColor = .clear
                    view.layer.borderColor = UIColor.black.cgColor
                    view.layer.borderWidth = 1
                    view.layer.shadowOpacity = 0
                } else if isLassoSelected {
                    view.backgroundColor = .clear
                    view.layer.borderColor = UIColor.systemGray2.withAlphaComponent(0.7).cgColor
                    view.layer.borderWidth = 1
                    view.layer.shadowColor = UIColor.systemGray.cgColor
                    view.layer.shadowOpacity = 0.28
                    view.layer.shadowRadius = 5
                    view.layer.shadowOffset = .zero
                } else {
                    view.backgroundColor = .clear
                    view.layer.borderColor = UIColor.clear.cgColor
                    view.layer.borderWidth = 0
                    view.layer.shadowOpacity = 0
                }
                view.layer.cornerRadius = 0
                if pendingFocusTextObjectId == object.id {
                    pendingFocusTextObjectId = nil
                    DispatchQueue.main.async { [weak textView] in
                        textView?.becomeFirstResponder()
                    }
                }
            } else {
                view.layer.borderColor = directlySelected ? UIColor.systemOrange.cgColor : UIColor.systemBlue.withAlphaComponent(0.45).cgColor
                view.layer.borderWidth = directlySelected ? 2 : 1
                view.layer.shadowColor = directlySelected ? UIColor.systemOrange.cgColor : UIColor.clear.cgColor
                view.layer.shadowOpacity = directlySelected ? 0.25 : 0
                view.layer.shadowRadius = directlySelected ? 8 : 0
            }
        }

        private func addGestures(to view: UIView, object: PDFAnnotationObject, pageIndex: Int) {
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handleObjectPan(_:)))
            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handleObjectPinch(_:)))
            let tap = UITapGestureRecognizer(target: self, action: #selector(handleObjectTap(_:)))
            let selectTap = UITapGestureRecognizer(target: self, action: #selector(handleObjectSelect(_:)))
            let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleObjectLongPress(_:)))
            tap.numberOfTapsRequired = 2
            selectTap.numberOfTapsRequired = 1
            tap.cancelsTouchesInView = true
            selectTap.cancelsTouchesInView = true
            view.addGestureRecognizer(pan)
            view.addGestureRecognizer(pinch)
            view.addGestureRecognizer(tap)
            view.addGestureRecognizer(selectTap)
            view.addGestureRecognizer(longPress)
        }

        @objc private func handleObjectSelect(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view,
                  let id = view.accessibilityIdentifier,
                  let object = object(with: id) else { return }
            let wasSelected = selectedObjectId == object.id
            selectedObjectId = object.id
            if let pageIndex = object.pageIndex, let box = object.bbox {
                lassoSelection = LassoSelection(
                    pageIndex: pageIndex,
                    strokeIds: [],
                    objectIds: [object.id],
                    bounds: box,
                    outline: []
                )
                notifyLassoSelectionChanged()
            }
            onObjectSelected(object)
            if wasSelected,
               object.type.lowercased().contains("text"),
               let textView = view as? UITextView {
                beginEditingTextView(textView, object: object)
            }
            applyAnnotationsToVisibleOverlays()
        }

        @objc private func handleObjectPan(_ gesture: UIPanGestureRecognizer) {
            guard let view = gesture.view, let overlay = view.superview as? PDFPageAnnotationOverlay,
                  let id = view.accessibilityIdentifier,
                  var object = object(with: id) else { return }
            if gesture.state == .began {
                selectedObjectId = object.id
                editingTextObjectId = nil
                if let textView = view as? UITextView {
                    textView.resignFirstResponder()
                    textView.isEditable = false
                    textView.isSelectable = false
                }
                onObjectSelected(object)
            }
            let translation = gesture.translation(in: overlay)
            view.center = CGPoint(x: view.center.x + translation.x, y: view.center.y + translation.y)
            gesture.setTranslation(.zero, in: overlay)
            if gesture.state == .ended || gesture.state == .cancelled {
                object.bbox = bbox(for: view.frame, in: overlay.bounds)
                if let pageIndex = object.pageIndex, let box = object.bbox {
                    lassoSelection = LassoSelection(
                        pageIndex: pageIndex,
                        strokeIds: [],
                        objectIds: [object.id],
                        bounds: box,
                        outline: []
                    )
                    notifyLassoSelectionChanged()
                }
                onObjectChanged(object)
            }
        }

        @objc private func handleObjectPinch(_ gesture: UIPinchGestureRecognizer) {
            guard let view = gesture.view, let overlay = view.superview as? PDFPageAnnotationOverlay,
                  let id = view.accessibilityIdentifier,
                  var object = object(with: id) else { return }
            selectedObjectId = object.id
            if let pageIndex = object.pageIndex, let box = object.bbox {
                lassoSelection = LassoSelection(
                    pageIndex: pageIndex,
                    strokeIds: [],
                    objectIds: [object.id],
                    bounds: box,
                    outline: []
                )
                notifyLassoSelectionChanged()
            }
            onObjectSelected(object)
            let scale = gesture.scale
            let center = view.center
            var frame = view.frame
            frame.size.width = max(34, min(overlay.bounds.width, frame.size.width * scale))
            frame.size.height = max(24, min(overlay.bounds.height, frame.size.height * scale))
            frame.origin.x = center.x - frame.size.width / 2
            frame.origin.y = center.y - frame.size.height / 2
            view.frame = frame
            gesture.scale = 1
            if let textView = view as? UITextView, object.type.lowercased().contains("text") {
                var metadata = object.metadata ?? [:]
                metadata[textManualWidthMetadataKey] = "true"
                object.metadata = metadata
                resizeTextObjectIfNeeded(&object, textView: textView)
            }
            if gesture.state == .ended || gesture.state == .cancelled {
                object.bbox = bbox(for: view.frame, in: overlay.bounds)
                if let pageIndex = object.pageIndex, let box = object.bbox {
                    lassoSelection = LassoSelection(
                        pageIndex: pageIndex,
                        strokeIds: [],
                        objectIds: [object.id],
                        bounds: box,
                        outline: []
                    )
                    notifyLassoSelectionChanged()
                }
                onObjectChanged(object)
            }
        }

        @objc private func handleObjectTap(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view, let id = view.accessibilityIdentifier,
                  let object = object(with: id), object.type.lowercased().contains("text") else { return }
            selectedObjectId = object.id
            if let pageIndex = object.pageIndex, let box = object.bbox {
                lassoSelection = LassoSelection(
                    pageIndex: pageIndex,
                    strokeIds: [],
                    objectIds: [object.id],
                    bounds: box,
                    outline: []
                )
                notifyLassoSelectionChanged()
            }
            onObjectSelected(object)
            if let textView = view as? UITextView {
                beginEditingTextView(textView, object: object)
            }
        }

        private func beginEditingTextView(_ textView: UITextView, object: PDFAnnotationObject) {
            editingTextObjectId = object.id
            textView.isEditable = true
            textView.isSelectable = true
            textView.becomeFirstResponder()
            configureObjectView(textView, object: object)
        }

        private func editTextObject(_ object: PDFAnnotationObject) {
            selectedObjectId = object.id
            editingTextObjectId = object.id
            for overlay in overlays.values {
                guard let textView = overlay.objectViews[object.id] as? UITextView else { continue }
                beginEditingTextView(textView, object: object)
                return
            }
            pendingFocusTextObjectId = object.id
            applyAnnotationsToVisibleOverlays()
        }

        func applyTextEditRequest(_ request: Int) {
            guard request != lastTextEditRequest else { return }
            lastTextEditRequest = request
            guard let selectedObjectId,
                  let object = object(with: selectedObjectId),
                  object.type.lowercased().contains("text") else { return }
            for overlay in overlays.values {
                guard let textView = overlay.objectViews[selectedObjectId] as? UITextView else { continue }
                beginEditingTextView(textView, object: object)
                return
            }
            pendingFocusTextObjectId = selectedObjectId
            applyAnnotationsToVisibleOverlays()
        }

        func textViewDidChange(_ textView: UITextView) {
            guard let id = textView.accessibilityIdentifier,
                  var object = object(with: id),
                  object.type.lowercased().contains("text") else { return }
            object.text = textView.text
            if !textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                var metadata = object.metadata ?? [:]
                metadata[textDraftMetadataKey] = nil
                object.metadata = metadata
            }
            resizeTextObjectIfNeeded(&object, textView: textView)
            selectedObjectId = object.id
            updateSelection(for: object)
            onObjectChanged(object)
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            guard let id = textView.accessibilityIdentifier,
                  let object = object(with: id) else { return }
            pdfView?.isEditingText = true
            activeTextView = textView
            selectedObjectId = id
            editingTextObjectId = id
            if let pageIndex = object.pageIndex, let box = object.bbox {
                lassoSelection = LassoSelection(
                    pageIndex: pageIndex,
                    strokeIds: [],
                    objectIds: [id],
                    bounds: box,
                    outline: []
                )
                notifyLassoSelectionChanged()
            }
            onObjectSelected(object)
            configureObjectView(textView, object: object)
            if let keyboardFrame = lastKeyboardFrame {
                DispatchQueue.main.async { [weak pdfView, weak textView] in
                    guard let pdfView, let textView else { return }
                    pdfView.centerTextEditor(textView, aboveKeyboardFrame: keyboardFrame, duration: 0.2)
                }
            }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            if activeTextView === textView {
                activeTextView = nil
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak pdfView] in
                pdfView?.finishTextEditingTransition()
            }
            guard let id = textView.accessibilityIdentifier,
                  var object = object(with: id),
                  object.type.lowercased().contains("text") else { return }
            editingTextObjectId = nil
            object.text = textView.text
            if deleteEmptyTextObjectIfNeeded(object, textView: textView) {
                return
            }
            if !textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                var metadata = object.metadata ?? [:]
                metadata[textDraftMetadataKey] = nil
                object.metadata = metadata
            }
            resizeTextObjectIfNeeded(&object, textView: textView)
            selectedObjectId = object.id
            updateSelection(for: object)
            onObjectChanged(object)
            configureObjectView(textView, object: object)
        }

        private func deleteEmptyTextObjectIfNeeded(_ object: PDFAnnotationObject, textView: UITextView) -> Bool {
            guard textView.markedTextRange == nil,
                  (textView.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            editingTextObjectId = nil
            pendingFocusTextObjectId = nil
            if selectedObjectId == object.id {
                selectedObjectId = nil
            }
            onObjectDeleted(object)
            clearLassoSelection()
            textView.removeFromSuperview()
            return true
        }

        private func discardEmptyTextDraftIfNeeded() -> Bool {
            let candidateIds = [editingTextObjectId, selectedObjectId].compactMap { $0 }
            for id in candidateIds {
                guard let object = object(with: id),
                      object.type.lowercased().contains("text"),
                      isDraftTextObject(object),
                      (object.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                editingTextObjectId = nil
                pendingFocusTextObjectId = nil
                onObjectDeleted(object)
                clearLassoSelection()
                return true
            }
            return false
        }

        private func isDraftTextObject(_ object: PDFAnnotationObject) -> Bool {
            object.metadata?[textDraftMetadataKey] == "true"
        }

        private func updateSelection(for object: PDFAnnotationObject) {
            guard let pageIndex = object.pageIndex, let box = object.bbox else { return }
            lassoSelection = LassoSelection(
                pageIndex: pageIndex,
                strokeIds: [],
                objectIds: [object.id],
                bounds: box,
                outline: []
            )
            notifyLassoSelectionChanged()
        }

        private func resizeTextObjectIfNeeded(_ object: inout PDFAnnotationObject, textView: UITextView) {
            guard let overlay = textView.superview as? PDFPageAnnotationOverlay,
                  overlay.bounds.width > 0,
                  overlay.bounds.height > 0 else { return }
            let text = textView.text ?? ""
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let maxWidth = max(80, overlay.bounds.width * 0.62)
            let hasManualWidth = object.metadata?[textManualWidthMetadataKey] == "true"
            let targetWidth = hasManualWidth ? min(maxWidth, max(36, textView.frame.width)) : maxWidth
            let fittingSize = textView.sizeThatFits(CGSize(width: targetWidth, height: .greatestFiniteMagnitude))
            var frame = textView.frame
            frame.size.width = hasManualWidth ? targetWidth : min(maxWidth, max(36, ceil(fittingSize.width)))
            frame.size.height = min(overlay.bounds.height, max(24, ceil(fittingSize.height)))
            frame.origin.x = min(max(0, frame.origin.x), max(0, overlay.bounds.width - frame.width))
            frame.origin.y = min(max(0, frame.origin.y), max(0, overlay.bounds.height - frame.height))
            textView.frame = frame
            object.bbox = bbox(for: frame, in: overlay.bounds)
        }

        @objc private func handleObjectLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began,
                  let view = gesture.view,
                  let id = view.accessibilityIdentifier,
                  let object = object(with: id) else { return }
            let alert = UIAlertController(title: "Delete annotation?", message: nil, preferredStyle: .actionSheet)
            alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
                self?.onObjectDeleted(object)
            })
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            if let popover = alert.popoverPresentationController {
                popover.sourceView = view
                popover.sourceRect = view.bounds
            }
            pdfView?.window?.rootViewController?.present(alert, animated: true)
        }

        private func object(with id: String) -> PDFAnnotationObject? {
            guard let annotations else { return nil }
            for page in annotations.pages {
                if let object = annotations.noteObjects(pageIndex: page.pageIndex).first(where: { $0.id == id }) {
                    return object
                }
            }
            return annotations.objects.first(where: { $0.id == id })
        }

        private func frame(for bbox: AnnotationBoundingBox?, in bounds: CGRect) -> CGRect {
            guard let box = bbox?.normalizedOrSelf else {
                return CGRect(x: bounds.width * 0.2, y: bounds.height * 0.2, width: bounds.width * 0.36, height: bounds.height * 0.12)
            }
            return CGRect(
                x: bounds.width * box.x,
                y: bounds.height * box.y,
                width: max(28, bounds.width * box.width),
                height: max(22, bounds.height * box.height)
            )
        }

        private func bbox(for frame: CGRect, in bounds: CGRect) -> AnnotationBoundingBox {
            guard bounds.width > 0, bounds.height > 0 else {
                return AnnotationBoundingBox(x: 0, y: 0, width: 0, height: 0, normalized: nil)
            }
            return AnnotationBoundingBox(
                x: max(0, min(1, frame.minX / bounds.width)),
                y: max(0, min(1, frame.minY / bounds.height)),
                width: max(0.01, min(1, frame.width / bounds.width)),
                height: max(0.01, min(1, frame.height / bounds.height)),
                normalized: nil
            )
        }

        private func applyHighlight(to overlay: PDFPageAnnotationOverlay, pageIndex: Int) {
            highlightViews[pageIndex]?.removeFromSuperview()
            highlightViews[pageIndex] = nil
            guard let focus,
                  let page = focus.page,
                  page - 1 == pageIndex,
                  let box = focus.bbox?.normalizedOrSelf else { return }

            let highlight = UIView()
            highlight.isUserInteractionEnabled = false
            highlight.layer.borderColor = UIColor.systemYellow.withAlphaComponent(0.95).cgColor
            highlight.layer.borderWidth = 2
            highlight.backgroundColor = UIColor.systemYellow.withAlphaComponent(0.18)
            highlight.layer.cornerRadius = 3
            let bounds = overlay.bounds
            let frame = CGRect(
                x: bounds.width * box.x,
                y: bounds.height * box.y,
                width: max(12, bounds.width * box.width),
                height: max(10, bounds.height * box.height)
            )
            highlight.frame = frame
            overlay.addSubview(highlight)
            highlightViews[pageIndex] = highlight
        }
    }
}

private struct PDFExportPageScopeView: View {
    let currentPageNumber: Int
    let pageCount: Int
    let onSelect: (PDFExportPageScope) -> Void

    var body: some View {
        VStack(spacing: 0) {
            scopeButton(
                title: "Current Page",
                detail: "Page \(currentPageNumber)",
                systemImage: "doc.text",
                scope: .currentPage
            )
            Divider()
            scopeButton(
                title: "Page Selection",
                detail: "Enter pages to export",
                systemImage: "text.badge.checkmark",
                scope: .pageSelection
            )
            Divider()
            scopeButton(
                title: "All Pages",
                detail: pageCount > 0 ? "\(pageCount) pages" : "Full document",
                systemImage: "square.stack.3d.up",
                scope: .allPages
            )
        }
        .frame(width: 240)
        .padding(.vertical, 6)
    }

    private func scopeButton(
        title: String,
        detail: String,
        systemImage: String,
        scope: PDFExportPageScope
    ) -> some View {
        Button {
            onSelect(scope)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 17))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 14)
            .frame(height: 58)
        }
        .buttonStyle(.plain)
    }
}

private struct PDFExportOptionsView: View {
    @Environment(\.dismiss) private var dismiss
    let pageScope: PDFExportPageScope
    let currentPageNumber: Int
    let pageCount: Int
    @Binding var exportFormat: PDFExportFormat
    @Binding var includeAnnotations: Bool
    @Binding var pageRange: String
    let isExporting: Bool
    let onExport: () -> Void
    @FocusState private var isPageRangeFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                LabeledContent("Pages") {
                    Text(pageSummary)
                        .foregroundStyle(.secondary)
                }

                if pageScope == .pageSelection {
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("For example 1-3, 5", text: $pageRange)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.numbersAndPunctuation)
                            .textFieldStyle(.roundedBorder)
                            .focused($isPageRangeFocused)

                        Text(pageRangeHelp)
                            .font(.footnote)
                            .foregroundStyle(pageRange.isEmpty || isPageRangeValid ? Color.secondary : Color.red)
                    }
                }

                Picker("Format", selection: $exportFormat) {
                    ForEach(PDFExportFormat.allCases) { format in
                        Text(format.label).tag(format)
                    }
                }
                .pickerStyle(.segmented)

                if exportFormat == .pdf {
                    Toggle("Include annotations", isOn: $includeAnnotations)
                } else {
                    Text("Editable Codmes keeps handwriting, text boxes, and images editable when opened on another device.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                Button(action: onExport) {
                    Label("Export", systemImage: exportFormat.systemImage)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isExporting || !canExport)

                Text(exportFormat == .pdf
                     ? "A PDF with annotations is flattened so it can be viewed in other PDF apps."
                     : "The .codmespdf package contains the selected PDF pages and their editable Codmes annotations.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task {
                guard pageScope == .pageSelection else { return }
                try? await Task.sleep(nanoseconds: 250_000_000)
                isPageRangeFocused = true
            }
        }
    }

    private var pageSummary: String {
        switch pageScope {
        case .currentPage:
            "Current page (\(currentPageNumber))"
        case .pageSelection:
            "Selected pages"
        case .allPages:
            pageCount > 0 ? "All \(pageCount) pages" : "All pages"
        }
    }

    private var isPageRangeValid: Bool {
        isValidPDFPageRange(pageRange, pageCount: pageCount)
    }

    private var canExport: Bool {
        pageScope != .pageSelection || isPageRangeValid
    }

    private var pageRangeHelp: String {
        guard !pageRange.isEmpty else { return "Enter pages such as 1-3, 5." }
        return isPageRangeValid
            ? "Only the entered pages will be exported."
            : "Enter page numbers between 1 and \(max(pageCount, 1))."
    }
}

private struct PDFShareSheet: UIViewControllerRepresentable {
    let urls: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: urls, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private func replaceFileCopy(from sourceURL: URL, to targetURL: URL) throws {
    let manager = FileManager.default
    if manager.fileExists(atPath: targetURL.path) {
        try manager.removeItem(at: targetURL)
    }
    try manager.copyItem(at: sourceURL, to: targetURL)
}

private func parsePDFPageRange(_ value: String) -> [Int] {
    let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty else { return [] }
    var pages = Set<Int>()
    for token in cleaned.split(separator: ",") {
        let part = String(token).trimmingCharacters(in: .whitespacesAndNewlines)
        if part.contains("-") {
            let bounds = part.split(separator: "-", maxSplits: 1).compactMap {
                Int(String($0).trimmingCharacters(in: .whitespaces))
            }
            guard bounds.count == 2 else { continue }
            let lower = max(1, min(bounds[0], bounds[1]))
            let upper = max(bounds[0], bounds[1])
            for page in lower...upper {
                pages.insert(page - 1)
            }
        } else if let page = Int(part), page > 0 {
            pages.insert(page - 1)
        }
    }
    return pages.sorted()
}

private func isValidPDFPageRange(_ value: String, pageCount: Int) -> Bool {
    let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty, pageCount > 0 else { return false }

    let tokens = cleaned.split(separator: ",", omittingEmptySubsequences: false)
    guard !tokens.isEmpty else { return false }
    for token in tokens {
        let part = String(token).trimmingCharacters(in: .whitespacesAndNewlines)
        let bounds = part.split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 1 || bounds.count == 2 else { return false }
        let pageNumbers = bounds.compactMap {
            Int(String($0).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard pageNumbers.count == bounds.count,
              pageNumbers.allSatisfy({ (1...pageCount).contains($0) }) else {
            return false
        }
    }
    return true
}

private func normalizedPageIndexes(_ requested: [Int], pageCount: Int) -> [Int] {
    let valid = requested.filter { $0 >= 0 && $0 < pageCount }
    if valid.isEmpty {
        return Array(0..<max(0, pageCount))
    }
    return Array(NSOrderedSet(array: valid).array.compactMap { $0 as? Int })
}

private func copyPDFDocument(_ source: PDFDocument, pageIndexes: [Int]) throws -> PDFDocument {
    let output = PDFDocument()
    for (offset, index) in pageIndexes.enumerated() {
        guard index >= 0, index < source.pageCount,
              let page = source.page(at: index)?.copy() as? PDFPage else { continue }
        output.insert(page, at: offset)
    }
    if output.pageCount == 0 {
        throw CocoaError(.fileNoSuchFile)
    }
    return output
}

private func pencilDate(for id: String) -> Date {
    let prefix = LocalWorkspace.digest(Data(id.utf8)).prefix(12)
    return Date(timeIntervalSince1970: Double(UInt64(prefix, radix: 16) ?? 0) / 1000)
}

private func codmesStrokes(from drawing: PKDrawing, canvasSize: CGSize, previous: [CodmesInkStroke], previousDrawing: PKDrawing?) -> [CodmesInkStroke] {
    let width = max(canvasSize.width, 1)
    let height = max(canvasSize.height, 1)
    var available = previous
    return drawing.strokes.compactMap { stroke in
        let points = stroke.path.map { point in
            CodmesInkPoint(
                x: min(max(Double(point.location.x / width), 0), 1),
                y: min(max(Double(point.location.y / height), 0), 1),
                pressure: Double(point.force),
                timeOffset: point.timeOffset
            )
        }
        guard !points.isEmpty else { return nil }
        let priorIndex = previousDrawing?.strokes.firstIndex { $0.path.creationDate == stroke.path.creationDate }
        let priorID = priorIndex.flatMap { previous.indices.contains($0) ? previous[$0].id : nil }
        let match = available.firstIndex {
            $0.id == priorID || pencilDate(for: $0.id) == stroke.path.creationDate ||
            ($0.points == points && $0.color == hexColor(stroke.ink.color))
        }
        let id = match.map { available.remove(at: $0).id } ?? UUID().uuidString
        return CodmesInkStroke(
            id: id,
            tool: stroke.ink.inkType.rawValue,
            color: hexColor(stroke.ink.color),
            width: Double(points.count > 1 ? stroke.renderBounds.width / CGFloat(points.count) : stroke.renderBounds.width),
            opacity: nil,
            points: points
        )
    }
}

private func hexColor(_ color: UIColor) -> String {
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 0
    guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
        return "#000000"
    }
    return String(
        format: "#%02X%02X%02X",
        Int(red * 255),
        Int(green * 255),
        Int(blue * 255)
    )
}

private extension PDFAnnotationDocument {
    func sliced(to pageIndexes: [Int], documentPath: String) -> PDFAnnotationDocument {
        let mapping = Dictionary(uniqueKeysWithValues: pageIndexes.enumerated().map { ($0.element, $0.offset) })
        var nextPages: [PDFAnnotationPage] = []
        for page in pages {
            guard let mappedIndex = mapping[page.pageIndex] else { continue }
            var copy = page
            copy.pageId = page.pageId ?? "index:\(page.pageIndex)"
            copy.pageIndex = mappedIndex
            copy.objects = copy.objects?.map { object in
                var nextObject = object
                nextObject.pageIndex = mappedIndex
                return nextObject
            }
            copy.elements = copy.elements?.compactMap { element in
                var nextElement = element
                let sourcePageIndex = element.pageIndex
                guard let elementMappedIndex = mapping[sourcePageIndex] else { return nil }
                nextElement.pageIndex = elementMappedIndex
                return nextElement
            }
            nextPages.append(copy)
        }
        var nextObjects: [PDFAnnotationObject] = []
        for object in objects {
            guard let pageIndex = object.pageIndex, let mappedIndex = mapping[pageIndex] else { continue }
            var copy = object
            copy.pageIndex = mappedIndex
            nextObjects.append(copy)
        }
        var nextElements: [CodmesNoteElement] = []
        for element in elements ?? [] {
            guard let mappedIndex = mapping[element.pageIndex] else { continue }
            var copy = element
            copy.pageIndex = mappedIndex
            nextElements.append(copy)
        }
        var document = PDFAnnotationDocument(
            schemaVersion: schemaVersion,
            documentPath: documentPath,
            updatedAt: ISO8601DateFormatter().string(from: Date()),
            pages: nextPages.sorted { $0.pageIndex < $1.pageIndex },
            objects: nextObjects
        )
        document.elements = nextElements
        document.syncNoteElementsFromLegacy()
        return document
    }

    func inserting(_ imported: PDFAnnotationDocument?, at insertAt: Int, insertedPageCount: Int, documentPath: String) -> PDFAnnotationDocument {
        var nextPages = pages.map { page in
            var copy = page
            copy.pageId = page.pageId ?? "index:\(page.pageIndex)"
            if copy.pageIndex >= insertAt {
                copy.pageIndex += insertedPageCount
            }
            copy.objects = copy.objects?.map { object in
                var nextObject = object
                if let pageIndex = nextObject.pageIndex, pageIndex >= insertAt {
                    nextObject.pageIndex = pageIndex + insertedPageCount
                }
                return nextObject
            }
            copy.elements = copy.elements?.map { element in
                var nextElement = element
                if nextElement.pageIndex >= insertAt {
                    nextElement.pageIndex += insertedPageCount
                }
                return nextElement
            }
            return copy
        }
        var nextObjects = objects.map { object in
            var copy = object
            if let pageIndex = copy.pageIndex, pageIndex >= insertAt {
                copy.pageIndex = pageIndex + insertedPageCount
            }
            return copy
        }
        var nextElements = (elements ?? []).map { element in
            var copy = element
            if copy.pageIndex >= insertAt {
                copy.pageIndex += insertedPageCount
            }
            return copy
        }

        if let imported {
            for page in imported.pages {
                var copy = page
                copy.pageId = UUID().uuidString
                copy.pageIndex = insertAt + page.pageIndex
                copy.objects = copy.objects?.map { object in
                    var nextObject = object
                    nextObject.id = UUID().uuidString
                    nextObject.pageIndex = insertAt + (object.pageIndex ?? page.pageIndex)
                    return nextObject
                }
                copy.elements = copy.elements?.map { element in
                    var nextElement = element
                    nextElement.id = UUID().uuidString
                    nextElement.pageIndex = insertAt + element.pageIndex
                    if var stroke = nextElement.stroke {
                        stroke.id = nextElement.id
                        nextElement.stroke = stroke
                    }
                    return nextElement
                }
                nextPages.append(copy)
            }
            for object in imported.objects {
                var copy = object
                copy.id = UUID().uuidString
                copy.pageIndex = insertAt + (object.pageIndex ?? 0)
                nextObjects.append(copy)
            }
            for element in imported.elements ?? [] {
                var copy = element
                copy.id = UUID().uuidString
                copy.pageIndex = insertAt + element.pageIndex
                if var stroke = copy.stroke {
                    stroke.id = copy.id
                    copy.stroke = stroke
                }
                nextElements.append(copy)
            }
        }

        var document = PDFAnnotationDocument(
            schemaVersion: schemaVersion,
            documentPath: documentPath,
            updatedAt: ISO8601DateFormatter().string(from: Date()),
            pages: nextPages.sorted { $0.pageIndex < $1.pageIndex },
            objects: nextObjects
        )
        document.elements = nextElements
        document.syncNoteElementsFromLegacy()
        return document
    }
}

private func renderFlattenedPDF(document: PDFDocument, annotations: PDFAnnotationDocument, to outputURL: URL) throws {
    guard let firstPage = document.page(at: 0) else { throw CocoaError(.fileNoSuchFile) }
    let firstBounds = firstPage.bounds(for: .mediaBox)
    let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: firstBounds.size))
    try renderer.writePDF(to: outputURL) { context in
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            let pageBounds = page.bounds(for: .mediaBox)
            context.beginPage()
            UIColor.white.setFill()
            UIRectFill(CGRect(origin: .zero, size: pageBounds.size))
            context.cgContext.saveGState()
            context.cgContext.translateBy(x: 0, y: pageBounds.height)
            context.cgContext.scaleBy(x: 1, y: -1)
            page.draw(with: .mediaBox, to: context.cgContext)
            context.cgContext.restoreGState()

            if let annotationPage = annotations.pages.first(where: { $0.pageIndex == pageIndex }) {
                drawInk(annotationPage.inkDataBase64, pageBounds: pageBounds)
            }

            let hasLegacyPKDrawing = annotations.pages.first(where: { $0.pageIndex == pageIndex })?.inkDataBase64 != nil
            let elements = annotations.noteElements(pageIndex: pageIndex)
            let strokes = hasLegacyPKDrawing ? elements.compactMap { $0.isEditableElementSource ? $0.stroke : nil } : elements.compactMap(\.stroke)
            drawCodmesInk(strokes, pageBounds: pageBounds)
            for object in elements.compactMap({ $0.annotationObject() }) {
                drawAnnotationObject(object, pageBounds: pageBounds)
            }
        }
    }
}

private func drawInk(_ encoded: String?, pageBounds: CGRect) {
    guard let encoded,
          let data = Data(base64Encoded: encoded),
          let drawing = try? PKDrawing(data: data) else { return }
    let image = drawing.image(from: CGRect(origin: .zero, size: pageBounds.size), scale: 2)
    image.draw(in: CGRect(origin: .zero, size: pageBounds.size))
}

private func drawCodmesInk(_ strokes: [CodmesInkStroke]?, pageBounds: CGRect) {
    guard let strokes else { return }
    for stroke in strokes {
        guard stroke.points.count > 1 else { continue }
        let path = UIBezierPath()
        let first = stroke.points[0]
        path.move(to: CGPoint(x: pageBounds.width * first.x, y: pageBounds.height * first.y))
        for point in stroke.points.dropFirst() {
            path.addLine(to: CGPoint(x: pageBounds.width * point.x, y: pageBounds.height * point.y))
        }
        UIColor(hexString: stroke.color).setStroke()
        path.lineWidth = max(0.5, stroke.width)
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }
}

private func drawAnnotationObject(_ object: PDFAnnotationObject, pageBounds: CGRect) {
    guard let box = object.bbox?.normalizedOrSelf else { return }
    let rect = CGRect(
        x: pageBounds.width * box.x,
        y: pageBounds.height * box.y,
        width: pageBounds.width * box.width,
        height: pageBounds.height * box.height
    )

    if object.type.lowercased().contains("image"),
       let dataString = object.dataBase64,
       let data = Data(base64Encoded: stripDataURLPrefix(dataString)),
       let image = UIImage(data: data) {
        image.draw(in: rect)
        return
    }

    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .left
    paragraph.lineBreakMode = .byWordWrapping
    let fontSize = CGFloat(Double(object.metadata?["fontSize"] ?? "16") ?? 16)
    let attributes: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: fontSize),
        .foregroundColor: UIColor.label,
        .paragraphStyle: paragraph
    ]
    UIColor.systemBackground.withAlphaComponent(0.65).setFill()
    UIBezierPath(roundedRect: rect, cornerRadius: 4).fill()
    (object.text ?? "").draw(in: rect.insetBy(dx: 5, dy: 4), withAttributes: attributes)
}

private func stripDataURLPrefix(_ value: String) -> String {
    value.replacingOccurrences(of: "^data:[^,]+,", with: "", options: .regularExpression)
}

private extension UIColor {
    convenience init(hexString: String) {
        let clean = hexString.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var value: UInt64 = 0
        Scanner(string: clean).scanHexInt64(&value)
        let red = CGFloat((value >> 16) & 0xff) / 255
        let green = CGFloat((value >> 8) & 0xff) / 255
        let blue = CGFloat(value & 0xff) / 255
        self.init(red: red, green: green, blue: blue, alpha: 1)
    }
}
#endif

private func splitStrokes(_ strokes: [CodmesInkStroke], erasingAt point: CodmesInkPoint, threshold: Double) -> [CodmesInkStroke] {
    strokes.flatMap { splitStroke($0, erasingAt: point, threshold: threshold) }
}

private func splitStroke(_ stroke: CodmesInkStroke, erasingAt point: CodmesInkPoint, threshold: Double) -> [CodmesInkStroke] {
    let sourceStroke = stroke.isCodmesShapeStroke
        ? stroke.asDensifiedPenStroke(maxSegmentLength: max(0.002, threshold * 0.45))
        : stroke
    guard sourceStroke.points.count > 1 else { return [stroke] }
    var segments: [[CodmesInkPoint]] = []
    var current: [CodmesInkPoint] = []
    let points = sourceStroke.points
    var didErase = false

    for index in points.indices {
        let candidate = points[index]
        let previous = index > points.startIndex ? points[points.index(before: index)] : nil
        let next = index < points.index(before: points.endIndex) ? points[points.index(after: index)] : nil
        let isHit = inkDistance(candidate, point) <= threshold
            || previous.map { inkDistanceToSegment(point, $0, candidate) <= threshold } == true
            || next.map { inkDistanceToSegment(point, candidate, $0) <= threshold } == true

        if isHit {
            didErase = true
            if current.count > 1 {
                segments.append(current)
            }
            current = []
        } else {
            current.append(candidate)
        }
    }

    if current.count > 1 {
        segments.append(current)
    }

    guard didErase else { return [stroke] }
    guard !segments.isEmpty else { return [] }
    if !stroke.isCodmesShapeStroke, segments.count == 1, segments[0].count == stroke.points.count {
        return [stroke]
    }
    return segments.map { segment in
        CodmesInkStroke(
            id: UUID().uuidString,
            tool: sourceStroke.tool,
            color: stroke.color,
            width: stroke.width,
            opacity: stroke.opacity,
            points: segment
        )
    }
}

private func inkDistance(_ first: CodmesInkPoint, _ second: CodmesInkPoint) -> Double {
    let dx = first.x - second.x
    let dy = first.y - second.y
    return (dx * dx + dy * dy).squareRoot()
}

private func inkDistanceToSegment(_ point: CodmesInkPoint, _ start: CodmesInkPoint, _ end: CodmesInkPoint) -> Double {
    let vx = end.x - start.x
    let vy = end.y - start.y
    let wx = point.x - start.x
    let wy = point.y - start.y
    let lengthSquared = vx * vx + vy * vy
    guard lengthSquared > 0 else { return inkDistance(point, start) }
    let t = min(1, max(0, (wx * vx + wy * vy) / lengthSquared))
    let projection = CodmesInkPoint(
        x: start.x + t * vx,
        y: start.y + t * vy,
        pressure: nil,
        timeOffset: nil
    )
    return inkDistance(point, projection)
}

private extension CodmesInkStroke {
    var isCodmesShapeStroke: Bool {
        tool.hasPrefix("shape:")
            || tool == "line"
            || tool == "polyline"
            || tool == "triangle"
            || tool == "rectangle"
            || tool == "circle"
            || tool == "ellipse"
    }

    func asDensifiedPenStroke(maxSegmentLength: Double) -> CodmesInkStroke {
        guard points.count > 1 else {
            var copy = self
            copy.tool = "pen"
            return copy
        }
        var dense: [CodmesInkPoint] = []
        for (start, end) in zip(points, points.dropFirst()) {
            if dense.isEmpty {
                dense.append(start)
            }
            let distance = inkDistance(start, end)
            let steps = max(1, Int(ceil(distance / max(maxSegmentLength, 0.0005))))
            for step in 1...steps {
                let t = Double(step) / Double(steps)
                dense.append(CodmesInkPoint(
                    x: start.x + (end.x - start.x) * t,
                    y: start.y + (end.y - start.y) * t,
                    pressure: nil,
                    timeOffset: nil
                ))
            }
        }
        var copy = self
        copy.tool = "pen"
        copy.points = dense
        return copy
    }
}
