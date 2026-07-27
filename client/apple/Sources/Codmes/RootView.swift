import SwiftUI
#if os(iOS)
import UIKit
#endif

struct RootView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @State private var selection: WorkspaceSection? = .chat
    @State private var selectedPluginSurfaceId: String?
    @State private var isChatPanelVisible = false
    @State private var chatPanelDragX: CGFloat = 0
    @State private var isSidebarVisible = false
    @State private var sidebarDragX: CGFloat = 0
    @State private var showingGlobalSearch = false
    @State private var showingSettings = false
    @State private var isMacSidebarVisible = true
    @State private var showingMacSurfaceMenu = false
    @State private var showingDocumentJobs = false
    @State private var seenDocumentJobIds = Set<String>()
    @State private var documentJobsAutoDismissTask: Task<Void, Never>?

    var body: some View {
        #if os(macOS)
        GeometryReader { proxy in
            HStack(spacing: 0) {
                if isMacSidebarVisible, macHasSidebar {
                    macSidebar
                        .frame(width: macSidebarWidth(for: proxy.size.width))

                    Divider()
                }

                detailView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .toolbar {
                if #available(macOS 26.0, *) {
                    macToolbar
                        .sharedBackgroundVisibility(.hidden)
                } else {
                    macToolbar
                }
            }
        }
        .frame(minWidth: 640, idealWidth: 1120, minHeight: 420, idealHeight: 740)
        .sheet(isPresented: $showingSettings) {
            WorkspaceSettingsView(isPresented: $showingSettings)
                .environmentObject(store)
        }
        .sheet(isPresented: $showingGlobalSearch) {
            SearchView(onSelectSurface: selectSurfaceFromSearch)
                .environmentObject(store)
        }
        .onChange(of: activeSurfaceId) { _, _ in
            DispatchQueue.main.async {
                configureMacWindow(NSApp.keyWindow)
            }
        }
        .task(id: activeSurfaceTaskKey) {
            store.activeChatSurface = activeSurfaceId
            await autoRefreshVisibleFileTree()
        }
        .task {
            await store.monitorDocumentJobs()
        }
        .onChange(of: store.activeDocumentJobs.map(\.id)) { _, ids in
            updateDocumentJobsPresentation(ids)
        }
        .onDisappear {
            documentJobsAutoDismissTask?.cancel()
        }
        #else
        iOSRootView
        #endif
    }

    private var selectedSection: WorkspaceSection {
        selection ?? .chat
    }

    private var selectedPluginSurface: WorkspaceSurface? {
        guard let selectedPluginSurfaceId else { return nil }
        return store.workspaceSurfaces.first { $0.id == selectedPluginSurfaceId }
    }

    private var activeSurfaceId: String {
        selectedPluginSurface?.id ?? selectedSection.runtimeSurfaceId
    }

    private var activeSurfaceTitle: String {
        selectedPluginSurface?.title ?? selectedSection.rawValue
    }

    private var activeSurfaceIcon: String {
        selectedPluginSurface?.systemImage ?? selectedSection.systemImage
    }

    private var activeSurfaceTaskKey: String {
        activeSurfaceId
    }

    private var macHasSidebar: Bool {
        activeSurfaceId == "chat" || activeSurfaceId == "notes" || activeSurfaceId == "code"
    }

    private var activeDocumentTitle: String? {
        guard activeSurfaceId == "notes" || activeSurfaceId == "code" else { return nil }
        return store.loadingRawFile?.name ?? store.selectedRawFile?.name ?? store.selectedFile?.name
    }

    private var activePDFStatus: String? {
        guard let rawFile = store.selectedRawFile,
              rawFile.kind == "pdf",
              rawFile.path == store.activePDFStatusPath,
              !store.activePDFStatusText.isEmpty else { return nil }
        return store.activePDFStatusText
    }

    private var visibleWorkspaceSections: [WorkspaceSection] {
        WorkspaceSection.allCases.filter { section in
            store.surfaceEnabled(section.runtimeSurfaceId)
        }
    }

    #if os(macOS)
    @ViewBuilder
    private var macSidebar: some View {
        if activeSurfaceId == "chat" {
            ChatNavigationSidebar()
        } else if activeSurfaceId == "notes" {
            FileBrowserPane(title: "Notes", root: "notes", showsHeader: false)
        } else if activeSurfaceId == "code" {
            FileBrowserPane(title: "Code", root: "code", showsHeader: false)
        }
    }

    private func macSidebarWidth(for availableWidth: CGFloat) -> CGFloat {
        if activeSurfaceId == "chat" {
            return min(300, max(240, availableWidth * 0.24))
        }
        return min(320, max(220, availableWidth * 0.26))
    }

    @ToolbarContentBuilder
    private var macToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            HStack(spacing: 10) {
                if macHasSidebar {
                    Button {
                        isMacSidebarVisible.toggle()
                    } label: {
                        Image(systemName: "sidebar.left")
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(MacToolbarIconButtonStyle(isSelected: isMacSidebarVisible))
                    .help(isMacSidebarVisible ? "Hide sidebar" : "Show sidebar")
                }

                Button {
                    showingMacSurfaceMenu.toggle()
                } label: {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 5) {
                            Text(activeSurfaceTitle)
                                .font(.headline.weight(.semibold))

                            Image(systemName: "chevron.down")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.secondary)

                            Circle()
                                .fill(store.isWorkspaceConnected ? .green : .orange)
                                .frame(width: 7, height: 7)
                        }

                        if let activePDFStatus {
                            Text(activePDFStatus)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .lineLimit(1)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .fixedSize()
                .popover(isPresented: $showingMacSurfaceMenu, arrowEdge: .top) {
                    macSurfaceMenu
                }
            }
        }

        if #available(macOS 26.0, *) {
            ToolbarSpacer(.flexible)
        }

        ToolbarItem(placement: .principal) {
            Text(activeDocumentTitle ?? "")
                .font(.headline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 420)
                .accessibilityLabel(activeDocumentTitle.map { "Open file: \($0)" } ?? "No open file")
        }

        ToolbarItemGroup(placement: .confirmationAction) {
            if activeSurfaceId != "chat" {
                Button {
                    isChatPanelVisible.toggle()
                } label: {
                    Image(systemName: "bubble.right")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(MacToolbarIconButtonStyle(isSelected: isChatPanelVisible))
                .help(isChatPanelVisible ? "Hide chat panel" : "Show chat panel")
            }

            if activeSurfaceId == "notes", !store.activeDocumentJobs.isEmpty {
                documentJobsButton
            }

            Button {
                store.selectedPDFFocus = nil
                showingGlobalSearch = true
            } label: {
                Image(systemName: "magnifyingglass")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(MacToolbarIconButtonStyle(isSelected: showingGlobalSearch))
            .help("Global search")

            Button {
                showingSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(MacToolbarIconButtonStyle(isSelected: showingSettings))
            .help("Settings")
        }
    }

    private var macSurfaceMenu: some View {
        VStack(spacing: 2) {
            ForEach(visibleWorkspaceSections) { section in
                Button {
                    selectSection(section)
                    showingMacSurfaceMenu = false
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: section.systemImage)
                            .frame(width: 18)
                        Text(section.rawValue)
                        Spacer()
                        if selectedPluginSurfaceId == nil && selectedSection == section {
                            Image(systemName: "checkmark")
                                .font(.caption.weight(.bold))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if !store.enabledPluginSurfaces.isEmpty {
                Divider()
                    .padding(.vertical, 4)
            }

            ForEach(store.enabledPluginSurfaces) { surface in
                Button {
                    selectPluginSurface(surface)
                    showingMacSurfaceMenu = false
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: surface.systemImage)
                            .frame(width: 18)
                        Text(surface.title)
                        Spacer()
                        if selectedPluginSurfaceId == surface.id {
                            Image(systemName: "checkmark")
                                .font(.caption.weight(.bold))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .frame(minWidth: 210)
    }

    private struct MacToolbarIconButtonStyle: ButtonStyle {
        let isSelected: Bool

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .foregroundStyle(.secondary)
                .background(
                    configuration.isPressed || isSelected
                        ? Color.primary.opacity(0.10)
                        : Color.clear,
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
    }
    #endif

    @ViewBuilder
    private var detailView: some View {
        #if os(macOS)
        if activeSurfaceId != "chat" && isChatPanelVisible {
            HSplitView {
                primaryDetailView
                    .frame(minWidth: 0)
                ChatHomeView(compact: true, showsHeader: false, onOpenModelSettings: openModelSettings)
                    .frame(minWidth: 320, idealWidth: 390, maxWidth: 460)
            }
        } else {
            primaryDetailView
        }
        #else
        if activeSurfaceId == "chat" {
            primaryDetailView
        } else {
            iOSSwipeChatContainer {
                primaryDetailView
            }
        }
        #endif
    }

    #if os(iOS)
    private var iOSRootView: some View {
        GeometryReader { proxy in
            let usesPersistentSidebar =
                UIDevice.current.userInterfaceIdiom == .pad
                && proxy.size.width >= 700
                && proxy.size.width > proxy.size.height
            let sidebarWidth = usesPersistentSidebar
                ? min(320, max(280, proxy.size.width * 0.28))
                : min(max(proxy.size.width * 0.78, 260), 320)

            VStack(spacing: 0) {
                iOSTopBar
                Divider()

                Group {
                    if usesPersistentSidebar {
                        HStack(spacing: 0) {
                            if isSidebarVisible {
                                iOSSidebar(width: sidebarWidth, persistent: true)
                                    .transition(.move(edge: .leading))
                            }

                            iOSMainContent
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    } else {
                        ZStack(alignment: .leading) {
                            iOSMainContent
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .simultaneousGesture(edgeOpenSidebarGesture(width: sidebarWidth))

                            if isSidebarVisible {
                                Color.black.opacity(0.25)
                                    .ignoresSafeArea()
                                    .contentShape(Rectangle())
                                    .gesture(sidebarGesture(width: sidebarWidth))
                                    .onTapGesture {
                                        closeSidebar()
                                    }
                            }

                            iOSSidebar(width: sidebarWidth, persistent: false)
                                .offset(x: sidebarOffset(width: sidebarWidth))
                                .gesture(sidebarGesture(width: sidebarWidth))
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .onAppear {
                updateIOSSidebarPresentation(usesPersistentSidebar)
            }
            .onChange(of: usesPersistentSidebar) { _, isPersistent in
                updateIOSSidebarPresentation(isPersistent)
            }
            .clipped()
        }
        .sheet(isPresented: $showingSettings) {
            WorkspaceSettingsView(isPresented: $showingSettings)
                .environmentObject(store)
        }
        .sheet(isPresented: $showingGlobalSearch) {
            SearchView(onSelectSurface: selectSurfaceFromSearch)
                .environmentObject(store)
        }
        .task(id: activeSurfaceTaskKey) {
            store.activeChatSurface = activeSurfaceId
            await autoRefreshVisibleFileTree()
        }
        .task {
            await store.monitorDocumentJobs()
        }
        .onChange(of: store.activeDocumentJobs.map(\.id)) { _, ids in
            updateDocumentJobsPresentation(ids)
        }
        .onDisappear {
            documentJobsAutoDismissTask?.cancel()
        }
    }

    private var iOSMainContent: some View {
        Group {
            if activeSurfaceId == "chat" {
                ChatHomeView(
                    showsHeader: false,
                    showsSessionToolbar: false,
                    onOpenModelSettings: openModelSettings
                )
            } else {
                iOSSwipeChatContainer {
                    primaryDetailView
                }
            }
        }
        .background(.background)
    }

    private var iOSTopBar: some View {
        GeometryReader { proxy in
            let compact = proxy.size.width < 600
            let horizontalPadding: CGFloat = compact ? 8 : 16
            let leadingLaneWidth: CGFloat = compact ? 132 : 180
            let surfaceLabelWidth: CGFloat = compact ? 92 : 132
            let titleWidth = max(
                64,
                min(compact ? 160 : 360, proxy.size.width - 2 * (horizontalPadding + leadingLaneWidth))
            )

            ZStack {
                HStack(spacing: compact ? 4 : 8) {
                    HStack(spacing: compact ? 4 : 8) {
                        Button {
                            if isSidebarVisible {
                                closeSidebar()
                            } else {
                                openSidebar()
                            }
                        } label: {
                            Image(systemName: "sidebar.left")
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())

                        Menu {
                            ForEach(visibleWorkspaceSections) { section in
                                Button {
                                    selectSection(section)
                                } label: {
                                    Label(section.rawValue, systemImage: section.systemImage)
                                    if selectedPluginSurfaceId == nil && selectedSection == section {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }

                            if !store.enabledPluginSurfaces.isEmpty {
                                Divider()
                            }

                            ForEach(store.enabledPluginSurfaces) { surface in
                                Button {
                                    selectPluginSurface(surface)
                                } label: {
                                    Label(surface.title, systemImage: surface.systemImage)
                                    if selectedPluginSurfaceId == surface.id {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 0) {
                                HStack(spacing: 5) {
                                    Text(activeSurfaceTitle)
                                        .font(.headline.weight(.semibold))
                                        .lineLimit(1)
                                        .layoutPriority(1)

                                    Image(systemName: "chevron.down")
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(.secondary)

                                    Circle()
                                        .fill(store.isWorkspaceConnected ? .green : .orange)
                                        .frame(width: 7, height: 7)
                                }

                                if let activePDFStatus {
                                    Text(activePDFStatus)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .frame(width: surfaceLabelWidth, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .transaction { transaction in
                            transaction.animation = nil
                        }
                    }
                    .lineLimit(1)
                    .frame(width: leadingLaneWidth, alignment: .leading)

                    Spacer(minLength: 8)

                    HStack(spacing: compact ? 0 : 8) {
                        if activeSurfaceId == "notes", !store.activeDocumentJobs.isEmpty {
                            documentJobsButton
                        }

                        Button {
                            store.selectedPDFFocus = nil
                            showingGlobalSearch = true
                        } label: {
                            Image(systemName: "magnifyingglass")
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())

                        Button {
                            showingSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                    }
                }

                Text(activeDocumentTitle ?? "")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: titleWidth, alignment: .center)
                    .accessibilityLabel(activeDocumentTitle.map { "Open file: \($0)" } ?? "No open file")
            }
            .padding(.horizontal, horizontalPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: 42)
        .background(.quaternary.opacity(0.14))
    }

    private func iOSSidebar(width: CGFloat, persistent: Bool) -> some View {
        Group {
            if activeSurfaceId == "chat" {
                ChatNavigationSidebar {
                    if !persistent {
                        closeSidebar()
                    }
                }
            } else if activeSurfaceId == "notes" {
                FileBrowserPane(title: "Notes", root: "notes", showsHeader: false) {
                    if !persistent {
                        closeSidebar()
                    }
                }
            } else if activeSurfaceId == "code" {
                FileBrowserPane(title: "Code", root: "code", showsHeader: false) {
                    if !persistent {
                        closeSidebar()
                    }
                }
            } else {
                ContentUnavailableView(
                    "사이드바 없음",
                    systemImage: activeSurfaceIcon,
                    description: Text("\(activeSurfaceTitle)에는 사이드바 항목이 없습니다.")
                )
            }
        }
        .frame(width: width, alignment: .leading)
        .frame(maxHeight: .infinity)
        .background(.background.opacity(0.96))
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(.quaternary.opacity(0.55))
                .frame(width: 1)
        }
    }

    private func updateIOSSidebarPresentation(_ persistent: Bool) {
        isSidebarVisible = persistent
        sidebarDragX = 0

        if persistent {
            isChatPanelVisible = false
            chatPanelDragX = 0
        }
    }

    private func openSidebar() {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
            isSidebarVisible = true
            isChatPanelVisible = false
            sidebarDragX = 0
            chatPanelDragX = 0
        }
    }

    private func closeSidebar() {
        withAnimation(.spring(response: 0.24, dampingFraction: 0.92)) {
            isSidebarVisible = false
            sidebarDragX = 0
        }
    }

    private func sidebarOffset(width: CGFloat) -> CGFloat {
        if isSidebarVisible {
            return min(0, sidebarDragX)
        }
        return min(0, -width + sidebarDragX)
    }

    private func sidebarGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard !isChatPanelVisible else { return }
                if isSidebarVisible {
                    sidebarDragX = min(0, value.translation.width)
                } else {
                    sidebarDragX = max(0, value.translation.width)
                }
            }
            .onEnded { value in
                guard !isChatPanelVisible else {
                    sidebarDragX = 0
                    return
                }
                let predicted = value.predictedEndTranslation.width
                let shouldOpen = isSidebarVisible
                    ? value.translation.width > -width * 0.28 && predicted > -width * 0.44
                    : value.translation.width > 34 || predicted > 72
                withAnimation(.spring(response: 0.26, dampingFraction: 0.9)) {
                    isSidebarVisible = shouldOpen
                    if shouldOpen {
                        isChatPanelVisible = false
                        chatPanelDragX = 0
                    }
                    sidebarDragX = 0
                }
            }
    }

    private func edgeOpenSidebarGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 14)
            .onChanged { value in
                guard !isSidebarVisible, !isChatPanelVisible, value.startLocation.x <= 26 else { return }
                sidebarDragX = max(0, value.translation.width)
            }
            .onEnded { value in
                guard !isSidebarVisible, !isChatPanelVisible, value.startLocation.x <= 26 else {
                    sidebarDragX = 0
                    return
                }
                let shouldOpen = value.translation.width > 34 || value.predictedEndTranslation.width > 72
                withAnimation(.spring(response: 0.26, dampingFraction: 0.9)) {
                    isSidebarVisible = shouldOpen
                    sidebarDragX = 0
                }
            }
    }

    private func iOSSwipeChatContainer<Content: View>(@ViewBuilder content: @escaping () -> Content) -> some View {
        GeometryReader { proxy in
            let panelWidth = min(max(proxy.size.width * 0.88, 300), 430)
            ZStack(alignment: .trailing) {
                content()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if isChatPanelVisible {
                    Color.black.opacity(0.24)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .gesture(chatPanelGesture(panelWidth: panelWidth))
                        .onTapGesture {
                            closeChatPanel()
                        }
                }

                ChatHomeView(compact: true, showsHeader: false, onOpenModelSettings: openModelSettings)
                    .frame(width: panelWidth)
                    .frame(maxHeight: .infinity)
                    .background(.regularMaterial)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(.quaternary.opacity(0.55))
                            .frame(width: 1)
                    }
                    .offset(x: chatPanelOffset(panelWidth: panelWidth))
                    .simultaneousGesture(chatPanelGesture(panelWidth: panelWidth))

                if !isChatPanelVisible {
                    Color.clear
                        .frame(width: 26)
                        .contentShape(Rectangle())
                        .gesture(chatPanelGesture(panelWidth: panelWidth))
                }
            }
            .clipped()
        }
    }

    private func chatPanelOffset(panelWidth: CGFloat) -> CGFloat {
        if isChatPanelVisible {
            return max(0, chatPanelDragX)
        }
        return max(0, panelWidth + chatPanelDragX)
    }

    private func chatPanelGesture(panelWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                if isChatPanelVisible {
                    chatPanelDragX = max(0, value.translation.width)
                } else {
                    chatPanelDragX = min(0, value.translation.width)
                }
            }
            .onEnded { value in
                let predicted = value.predictedEndTranslation.width
                let shouldOpen = isChatPanelVisible
                    ? value.translation.width < panelWidth * 0.28 && predicted < panelWidth * 0.45
                    : value.translation.width < -34 || predicted < -72
                withAnimation(.spring(response: 0.26, dampingFraction: 0.9)) {
                    isChatPanelVisible = shouldOpen
                    if shouldOpen {
                        isSidebarVisible = false
                        sidebarDragX = 0
                    }
                    chatPanelDragX = 0
                }
            }
    }

    private func closeChatPanel() {
        withAnimation(.spring(response: 0.24, dampingFraction: 0.92)) {
            isChatPanelVisible = false
            chatPanelDragX = 0
        }
    }
    #endif

    private var documentJobsButton: some View {
        Button {
            documentJobsAutoDismissTask?.cancel()
            showingDocumentJobs.toggle()
        } label: {
            ServerAnalysisProgressIcon(progress: store.documentJobProgress)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .contentShape(Rectangle())
        .help("Server PDF analysis")
        .accessibilityLabel("Server PDF analysis in progress")
        .popover(isPresented: $showingDocumentJobs, arrowEdge: .top) {
            DocumentJobsPopover(jobs: store.activeDocumentJobs)
        }
    }

    private func updateDocumentJobsPresentation(_ ids: [String]) {
        guard !ids.isEmpty else {
            showingDocumentJobs = false
            documentJobsAutoDismissTask?.cancel()
            return
        }
        let newIds = Set(ids).subtracting(seenDocumentJobIds)
        seenDocumentJobIds.formUnion(ids)
        guard !newIds.isEmpty, activeSurfaceId == "notes" else { return }
        showingDocumentJobs = true
        documentJobsAutoDismissTask?.cancel()
        documentJobsAutoDismissTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            showingDocumentJobs = false
        }
    }

    private func selectSection(_ section: WorkspaceSection) {
        selectedPluginSurfaceId = nil
        selection = section
        store.activeChatSurface = section.runtimeSurfaceId
    }

    private func selectSurfaceFromSearch(_ surface: String) {
        switch surface {
        case "notes":
            selectSection(.notes)
        case "codes":
            selectSection(.code)
        case "chat":
            selectSection(.chat)
        default:
            break
        }
        closeSidebarIfNeeded()
    }

    private func selectPluginSurface(_ surface: WorkspaceSurface) {
        selectedPluginSurfaceId = surface.id
        selection = nil
        store.activeChatSurface = surface.id
    }

    private func openModelSettings() {
        showingSettings = true
    }

    private func closeSidebarIfNeeded() {
        #if os(iOS)
        closeSidebar()
        #endif
    }

    private func autoRefreshVisibleFileTree() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            switch selectedSection {
            case .notes:
                await store.refreshTree(root: "notes")
            case .code:
                await store.refreshTree(root: "code")
            case .chat:
                return
            }
        }
    }

    @ViewBuilder
    private var primaryDetailView: some View {
        switch selectedSection {
        case .chat:
            if let selectedPluginSurface {
                PluginSurfaceView(surface: selectedPluginSurface)
            } else {
                #if os(macOS)
                ChatHomeView(
                    showsHeader: false,
                    showsSessionToolbar: false,
                    onOpenModelSettings: openModelSettings
                )
                #else
                ChatHomeView(onOpenModelSettings: openModelSettings)
                #endif
            }
        case .notes:
            #if os(iOS)
            FileSectionView(title: "Notes", root: "notes", showsBrowserOnIOS: false)
            #else
            FilePreviewView()
            #endif
        case .code:
            #if os(iOS)
            FileSectionView(title: "Code", root: "code", showsBrowserOnIOS: false)
            #else
            FilePreviewView()
            #endif
        }
    }

    private func surfaceButton(title: String, systemImage: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .frame(width: 20)
                Text(title)
                    .lineLimit(1)
                Spacer()
            }
            .font(.callout.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .foregroundStyle(isSelected ? .primary : .secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .background(isSelected ? Color.secondary.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

private struct ServerAnalysisProgressIcon: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(.secondary.opacity(0.28), style: StrokeStyle(lineWidth: 2.2, dash: [4, 3]))

            Circle()
                .trim(from: 0, to: min(max(progress, 0.04), 1))
                .stroke(
                    Color.accentColor,
                    style: StrokeStyle(lineWidth: 2.4, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))

            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 10, weight: .semibold))
        }
        .padding(3)
    }
}

private struct DocumentJobsPopover: View {
    let jobs: [DocumentJob]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("서버 PDF 분석 중")
                .font(.headline)

            ForEach(jobs) { job in
                VStack(alignment: .leading, spacing: 6) {
                    Text(job.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    HStack {
                        Text(job.stageLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Spacer()

                        if let completed = job.completedUnits, let total = job.totalUnits, total > 0 {
                            Text("\(completed)/\(total)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        } else {
                            Text("\(Int(job.progress * 100))%")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }

                    ProgressView(value: job.progress)
                        .progressViewStyle(.linear)
                }
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}

struct PluginSurfaceView: View {
    let surface: WorkspaceSurface

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: surface.systemImage)
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text(surface.title)
                        .font(.title2.weight(.semibold))
                    Text(surface.description?.isEmpty == false ? surface.description! : "Plugin surface")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text("Open the chat panel to use this surface with its own prompt and tool mode.")
                .font(.callout)
                .foregroundStyle(.secondary)

            if let prompt = surface.prompt, !prompt.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Surface prompt")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(prompt)
                        .font(.body)
                        .textSelection(.enabled)
                }
                .padding(12)
                .background(.quaternary.opacity(0.16), in: RoundedRectangle(cornerRadius: 8))
            }

            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background)
    }
}

struct ServerStatusView: View {
    @EnvironmentObject private var store: WorkspaceStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Workspace Server", text: $store.serverURLText)
                .textFieldStyle(.roundedBorder)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                #endif
                .onChange(of: store.serverURLText) {
                    store.persistServerURLText()
                }
                .onSubmit {
                    store.saveServerURL()
                    Task { await store.refreshWorkspace() }
                }
            SecureField("Server auth token (optional)", text: $store.serverAuthToken)
                .textFieldStyle(.roundedBorder)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #endif
                .onChange(of: store.serverAuthToken) {
                    store.persistServerAuthToken()
                }
            Text(store.serverConnectionHint)
                .font(.caption2)
                .foregroundStyle(store.serverURLUsesLocalhost ? .orange : .secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Effective URL: \(store.effectiveServerURLText)")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .textSelection(.enabled)
            #if os(iOS)
            Button {
                store.useMacTailscaleServerURL()
                Task { await store.refreshWorkspace() }
            } label: {
                Label("Use Mac Tailscale", systemImage: "network")
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            #endif
            HStack {
                Circle()
                    .fill(store.isWorkspaceConnected ? .green : .orange)
                    .frame(width: 8, height: 8)
                Text(store.statusMessage)
                    .font(.caption)
                    .lineLimit(2)
                Spacer()
                Button {
                    store.saveServerURL()
                    Task { await store.refreshWorkspace() }
                } label: {
                    Label("Connect", systemImage: "arrow.clockwise")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderless)
            }
            Text(store.connectionDetail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Text("Step: \(store.connectionStep)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case connection = "Connection"
    case model = "Model"
    case modelConfig = "Model Config"
    case search = "Search"
    case mcp = "MCP"
    case surfaces = "Surfaces"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .connection: "network"
        case .model: "cube"
        case .modelConfig: "key"
        case .search: "magnifyingglass"
        case .mcp: "point.3.connected.trianglepath.dotted"
        case .surfaces: "square.grid.2x2"
        }
    }

    var subtitle: String {
        switch self {
        case .connection: "Server URL and token"
        case .model: "Choose provider and model"
        case .modelConfig: "Provider auth and endpoints"
        case .search: "Indexing and document search"
        case .mcp: "External MCP tools"
        case .surfaces: "Client modes and plugins"
        }
    }
}

struct WorkspaceSettingsView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @Binding var isPresented: Bool
    @State private var selectedSection: SettingsSection = .model

    var body: some View {
        NavigationStack {
            Group {
                #if os(iOS)
                VStack(spacing: 0) {
                    Picker("Settings", selection: $selectedSection) {
                        ForEach(SettingsSection.allCases) { section in
                            Text(section.rawValue).tag(section)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding()
                    settingsDetail
                }
                #else
                HStack(spacing: 0) {
                    settingsSidebar
                        .frame(width: 220)
                    Divider()
                    settingsDetail
                }
                .frame(minWidth: 820, minHeight: 560)
                #endif
            }
            .navigationTitle("Settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        isPresented = false
                    }
                }
            }
        }
    }

    private var settingsSidebar: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(SettingsSection.allCases) { section in
                Button {
                    selectedSection = section
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: section.systemImage)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(section.rawValue)
                                .font(.callout.weight(.medium))
                            Text(section.subtitle)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 9)
                    .padding(.horizontal, 10)
                    .background(
                        selectedSection == section ? Color.accentColor.opacity(0.14) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(12)
        .background(.quaternary.opacity(0.10))
    }

    @ViewBuilder
    private var settingsDetail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                switch selectedSection {
                case .connection:
                    connectionSettings
                case .model:
                    RuntimeModelSelectionSettingsView()
                case .modelConfig:
                    RuntimeProviderConfigSettingsView()
                case .search:
                    SearchSettingsView()
                case .mcp:
                    MCPSettingsView()
                case .surfaces:
                    SurfaceSettingsView()
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var connectionSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Connection")
                    .font(.headline)
                ServerStatusView()
            }
            .padding(14)
            .background(.quaternary.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 6) {
                Text("iPhone / Tailscale")
                    .font(.headline)
                Text("Use the Mac server's Tailscale URL when the app runs on iPhone or iPad. 127.0.0.1 points to the phone itself.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .background(.quaternary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Local file cache", systemImage: "internaldrive")
                        .font(.headline)
                    Spacer()
                    Text(formatBytes(store.localFileCacheUsageBytes))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Stepper(
                    value: Binding(
                        get: { store.localFileCacheLimitGB },
                        set: { store.setLocalFileCacheLimitGB($0) }
                    ),
                    in: 1...50,
                    step: 1
                ) {
                    Text("Maximum \(store.localFileCacheLimitGB) GB")
                        .monospacedDigit()
                }

                HStack {
                    Text("Older files are removed first when the cache reaches this size.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(role: .destructive) {
                        Task { await store.clearLocalFileCache() }
                    } label: {
                        Label("Clear", systemImage: "trash")
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(14)
            .background(.quaternary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        }
        .task {
            await store.refreshLocalFileCacheUsage()
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private struct SearchSettingsView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @State private var rootsText = ""
    @State private var embeddingBaseURL = "http://127.0.0.1:11434/v1"
    @State private var embeddingApiKey = ""
    @State private var embeddingModelId = "openai:bge-m3"
    @State private var embeddingDim = "1024"
    @State private var vlmModelId = ""
    @State private var vlmBaseURL = "http://127.0.0.1:11434/v1"
    @State private var vlmApiKey = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Search")
                        .font(.headline)
                    Text("Configure Codmes built-in search. External engines can be used internally, but the assistant sees one Codmes search tool.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task {
                        await store.refreshSearchConfig()
                        await store.refreshHermesMetadata()
                        loadFields()
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Indexing scope")
                            .font(.subheadline.weight(.semibold))
                        Text("Choose the server folders Codmes should search across.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if store.searchConfig?.openaiApiKeyConfigured == true {
                        Label("Embedding key saved", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Indexed folders")
                        .font(.caption.weight(.semibold))
                    TextField("/Users/user/CodmesWorkspace/Notes, /Users/user/CodmesWorkspace/Code", text: $rootsText, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(3...8)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                    Text("Use one absolute server folder per line, or separate folders with commas. Include Notes, Documents, Code, conversation index, and sessions when you want one search layer across everything.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Embedding backend")
                        .font(.caption.weight(.semibold))
                    HStack {
                        TextField("OpenAI-compatible base URL", text: $embeddingBaseURL)
                            .textFieldStyle(.roundedBorder)
                        TextField("Dim", text: $embeddingDim)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 80)
                    }
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif

                    SecureField("API key or local placeholder, e.g. ollama", text: $embeddingApiKey)
                        .textFieldStyle(.roundedBorder)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif

                    modelSelectionField(
                        title: "Embedding model",
                        selection: $embeddingModelId,
                        allowNone: false,
                        emptyLabel: "Select embedding model"
                    )

                    Text("For local Ollama, use base URL http://127.0.0.1:11434/v1, choose an embedding model such as bge-m3, dim 1024, and API key placeholder ollama.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("PDF image OCR / VLM")
                                .font(.caption.weight(.semibold))
                            Text("Used for scanned PDF pages and image-only regions when this extractor layer is enabled.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if store.searchConfig?.vlmApiKeyConfigured == true {
                            Label("VLM key saved", systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                    }

                    HStack {
                        TextField("VLM base URL", text: $vlmBaseURL)
                            .textFieldStyle(.roundedBorder)
                        SecureField("VLM API key or local placeholder", text: $vlmApiKey)
                            .textFieldStyle(.roundedBorder)
                    }
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif

                    modelSelectionField(
                        title: "VLM model",
                        selection: $vlmModelId,
                        allowNone: true,
                        emptyLabel: "Disabled"
                    )
                }

                HStack {
                    Button {
                        Task {
                            let embedding = splitModelId(embeddingModelId)
                            let vlm = splitModelId(vlmModelId)
                            await store.saveSearchConfig(
                                rootsText: rootsText,
                                embeddingsProvider: embedding.provider,
                                openaiBaseUrl: embeddingBaseURL,
                                openaiApiKey: embeddingApiKey,
                                openaiEmbedModel: embedding.model,
                                openaiEmbedDim: embeddingDim,
                                vlmProvider: vlm.provider,
                                vlmModel: vlm.model,
                                vlmBaseUrl: vlmBaseURL,
                                vlmApiKey: vlmApiKey
                            )
                            loadFields()
                        }
                    } label: {
                        Label("Save Search", systemImage: "magnifyingglass")
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        loadDefaultFields()
                    } label: {
                        Label("Use workspace defaults", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.borderless)
                }

                if let config = store.searchConfig {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Current backend")
                            .font(.caption.weight(.semibold))
                        Text("Index database: \(config.dbPath)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        Text("Config file: \(config.configPath)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        if let vlmModel = config.vlmModel, !vlmModel.isEmpty {
                            Text("VLM model: \(config.vlmProvider ?? "provider") / \(vlmModel)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.top, 4)
                }

                if !store.searchSetupMessage.isEmpty {
                    Text(store.searchSetupMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .background(.quaternary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        }
        .padding(14)
        .background(.quaternary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .task {
            await store.refreshSearchConfig()
            await store.refreshHermesMetadata()
            loadFields()
        }
    }

    private func loadFields() {
        guard let config = store.searchConfig else {
            loadDefaultFields()
            return
        }
        rootsText = config.roots.joined(separator: "\n")
        embeddingBaseURL = config.openaiBaseUrl
        embeddingModelId = joinModelId(provider: config.embeddingsProvider, model: config.openaiEmbedModel)
        embeddingDim = String(config.openaiEmbedDim)
        vlmModelId = joinModelId(provider: config.vlmProvider ?? "", model: config.vlmModel ?? "")
        vlmBaseURL = config.vlmBaseUrl?.isEmpty == false ? (config.vlmBaseUrl ?? "") : "http://127.0.0.1:11434/v1"
        if config.openaiApiKeyConfigured && embeddingApiKey.isEmpty {
            embeddingApiKey = ""
        }
        if config.vlmApiKeyConfigured == true && vlmApiKey.isEmpty {
            vlmApiKey = ""
        }
    }

    private func loadDefaultFields() {
        if let root = store.workspace?.workspaceRoot, !root.isEmpty {
            rootsText = [
                "\(root)/Notes",
                "\(root)/Documents",
                "\(root)/Code",
                "\(root)/.codmes/conversation-index",
                "\(root)/.codmes/sessions"
            ].joined(separator: "\n")
        }
        embeddingBaseURL = "http://127.0.0.1:11434/v1"
        embeddingApiKey = "ollama"
        embeddingModelId = "ollama-local:bge-m3"
        embeddingDim = "1024"
        vlmBaseURL = "http://127.0.0.1:11434/v1"
        vlmApiKey = "ollama"
        vlmModelId = ""
    }

    @ViewBuilder
    private func modelSelectionField(title: String, selection: Binding<String>, allowNone: Bool, emptyLabel: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
            Picker(title, selection: selection) {
                if allowNone {
                    Text(emptyLabel).tag("")
                } else if store.visibleHermesModelGroups.isEmpty {
                    Text(emptyLabel).tag(selection.wrappedValue)
                }
                ForEach(store.visibleHermesModelGroups) { group in
                    Section(group.title) {
                        ForEach(group.models) { model in
                            Text(model.model)
                                .tag(model.id)
                        }
                    }
                }
            }
            .pickerStyle(.menu)
            if store.visibleHermesModelGroups.isEmpty {
                Text("Connect or refresh runtime models in Model Config first.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func joinModelId(provider: String, model: String) -> String {
        let cleanProvider = provider.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanModel.isEmpty { return "" }
        return cleanProvider.isEmpty ? cleanModel : "\(cleanProvider):\(cleanModel)"
    }

    private func splitModelId(_ id: String) -> (provider: String, model: String) {
        let clean = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return ("", "") }
        guard let separator = clean.firstIndex(of: ":") else {
            return ("openai", clean)
        }
        let provider = String(clean[..<separator])
        let modelStart = clean.index(after: separator)
        return (provider, String(clean[modelStart...]))
    }
}

private struct MCPSettingsView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @State private var name = "custom-tool"
    @State private var command = ""
    @State private var argsText = ""
    @State private var scopePath = ""
    @State private var envText = ""
    @State private var enabled = true
    @State private var editingName: String?
    @State private var pendingDelete: MCPServerConfig?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("MCP")
                        .font(.headline)
                    Text("Connect optional server-side MCP tools. Codmes Search has its own settings page.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await store.refreshMCPServers() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
            }

            if store.mcpServers.isEmpty {
                ContentUnavailableView(
                    "No MCP servers",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text("Add optional stdio MCP servers here. Search setup lives in Settings > Search.")
                )
                .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ForEach(store.mcpServers) { server in
                    mcpRow(server)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(editingName == nil ? "Add MCP server" : "Edit MCP server")
                        .font(.subheadline.weight(.semibold))
                }

                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .disabled(editingName != nil)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif

                TextField("Command", text: $command)
                    .textFieldStyle(.roundedBorder)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif

                VStack(alignment: .leading, spacing: 4) {
                    Text("Arguments")
                        .font(.caption.weight(.semibold))
                    TextField("start --file-roots Notes --openai-embed-model text-embedding-3-small", text: $argsText, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...4)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                    Text("Arguments are passed directly to the MCP server process.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                TextField("Default search scope, for example Notes or Documents", text: $scopePath)
                    .textFieldStyle(.roundedBorder)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif

                VStack(alignment: .leading, spacing: 4) {
                    Text("Environment")
                        .font(.caption.weight(.semibold))
                    TextField("KEY=value, one per line", text: $envText, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...6)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                    Text("Use env for MCP-specific model/API settings when the server supports them. Secrets are stored in the server config, so do not commit .codmes/config.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Toggle("Enabled", isOn: $enabled)

                HStack {
                    Button {
                        Task {
                            await store.saveMCPServer(
                                name: name,
                                command: command,
                                argsText: argsText,
                                envText: envText,
                                scopePath: scopePath,
                                enabled: enabled,
                                editingExisting: editingName != nil
                            )
                            if !store.mcpSetupMessage.lowercased().contains("error") {
                                clearEditor()
                            }
                        }
                    } label: {
                        Label(editingName == nil ? "Add MCP" : "Save MCP", systemImage: "checkmark")
                    }
                    .buttonStyle(.bordered)

                    if editingName != nil {
                        Button("Cancel") {
                            clearEditor()
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }

            if !store.mcpSetupMessage.isEmpty {
                Text(store.mcpSetupMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .task {
            await store.refreshMCPServers()
        }
        .confirmationDialog(
            "Remove MCP server?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { server in
            Button("Remove \(server.name)", role: .destructive) {
                Task {
                    await store.deleteMCPServer(server)
                    pendingDelete = nil
                }
            }
            Button("Cancel", role: .cancel) {
                pendingDelete = nil
            }
        } message: { server in
            Text("This removes the MCP configuration from Codmes. It does not delete indexes or files.")
        }
    }

    private func mcpRow(_ server: MCPServerConfig) -> some View {
        HStack(spacing: 10) {
            Image(systemName: server.isEnabled ? "checkmark.circle.fill" : "pause.circle")
                .foregroundStyle(server.isEnabled ? .green : .secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name)
                    .font(.callout.weight(.medium))
                Text("\(server.command) \(server.argsText)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let scope = server.scopePath, !scope.isEmpty {
                    Text("Scope: \(scope)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { server.isEnabled },
                set: { enabled in
                    Task { await store.setMCPServerEnabled(server, enabled: enabled) }
                }
            ))
            .labelsHidden()
            Button {
                edit(server)
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            Button(role: .destructive) {
                pendingDelete = server
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }

    private func edit(_ server: MCPServerConfig) {
        editingName = server.name
        name = server.name
        command = server.command
        argsText = server.argsText
        scopePath = server.scopePath ?? ""
        envText = server.envText
        enabled = server.isEnabled
    }

    private func clearEditor() {
        editingName = nil
        name = "custom-tool"
        command = ""
        argsText = ""
        scopePath = ""
        envText = ""
        enabled = true
    }

}

private struct SurfaceSettingsView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @State private var pluginId = ""
    @State private var pluginTitle = ""
    @State private var pluginPrompt = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Surfaces")
                        .font(.headline)
                    Text("Choose which work modes appear in the client. Plugin surfaces can provide their own prompt and tool mode.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await store.refreshSurfaces() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
            }

            ForEach(store.workspaceSurfaces) { surface in
                surfaceRow(surface)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Add plugin surface")
                    .font(.subheadline.weight(.semibold))
                TextField("kongju-university", text: $pluginId)
                    .textFieldStyle(.roundedBorder)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
                TextField("공주대학교", text: $pluginTitle)
                    .textFieldStyle(.roundedBorder)
                TextField("Prompt hint for this surface", text: $pluginPrompt, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...4)
                Button {
                    let id = pluginId
                    let title = pluginTitle
                    let prompt = pluginPrompt
                    Task {
                        await store.addPluginSurface(id: id, title: title, prompt: prompt)
                        if store.surfaceSetupMessage.isEmpty {
                            pluginId = ""
                            pluginTitle = ""
                            pluginPrompt = ""
                        }
                    }
                } label: {
                    Label("Add Surface", systemImage: "plus")
                }
                .buttonStyle(.bordered)
            }

            if !store.surfaceSetupMessage.isEmpty {
                Text(store.surfaceSetupMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .task {
            await store.refreshSurfaces()
        }
    }

    private func surfaceRow(_ surface: WorkspaceSurface) -> some View {
        HStack(spacing: 10) {
            Image(systemName: surface.systemImage)
                .frame(width: 20)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(surface.title)
                    .font(.callout.weight(.medium))
                Text(surface.description?.isEmpty == false ? surface.description! : surface.id)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { surface.isEnabled },
                set: { enabled in
                    Task { await store.setSurfaceEnabled(surface, enabled: enabled) }
                }
            ))
            .labelsHidden()
            .disabled(surface.id == "chat")
            if surface.canRemove {
                Button(role: .destructive) {
                    Task { await store.removeSurface(surface) }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }
}

private struct RuntimeModelSelectionSettingsView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @State private var selectedProviderId = ""
    @State private var model = ""
    @State private var isSaving = false

    private var provider: RuntimeProviderOption? {
        store.selectableRuntimeProviders.first { $0.id == selectedProviderId }
    }

    private var models: [String] {
        let discovered = store.runtimeProviderModels[selectedProviderId] ?? []
        return discovered.isEmpty ? (provider?.models ?? []) : discovered
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Model")
                    .font(.headline)
                Text("Choose the active provider and model for new chat sessions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 12) {
                Picker("Provider", selection: $selectedProviderId) {
                    Text("Select provider").tag("")
                    ForEach(store.selectableRuntimeProviders) { option in
                        Text(option.name).tag(option.id)
                    }
                }
                .onChange(of: selectedProviderId) { _, newValue in
                    model = ""
                    if !newValue.isEmpty {
                        Task { await refreshModelsForSelectedProvider() }
                    }
                }

                HStack(spacing: 10) {
                    Picker("Model", selection: $model) {
                        Text("Select model").tag("")
                        ForEach(models, id: \.self) { item in
                            Text(item).tag(item)
                        }
                    }
                    .disabled(selectedProviderId.isEmpty)

                    Button {
                        Task { await refreshModelsForSelectedProvider() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .disabled(selectedProviderId.isEmpty)
                    .help("Refresh models")
                }

                HStack(spacing: 10) {
                    Button {
                        isSaving = true
                        let providerId = selectedProviderId
                        let selectedModel = model
                        Task {
                            _ = await store.saveRuntimeModelSelection(providerId: providerId, model: selectedModel)
                            isSaving = false
                        }
                    } label: {
                        if isSaving {
                            ProgressView()
                        } else {
                            Label("Use This Model", systemImage: "checkmark")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedProviderId.isEmpty || model.isEmpty || isSaving)

                    if let provider {
                        Text(provider.configured == true || provider.isLocalProvider ? "Ready" : "Configure this provider in Model Config first.")
                            .font(.caption)
                            .foregroundStyle(provider.configured == true || provider.isLocalProvider ? Color.secondary : Color.orange)
                    }
                }
            }
            .padding(14)
            .background(.quaternary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))

            if store.selectableRuntimeProviders.isEmpty {
                Text("No configured providers yet. Connect a provider in Model Config first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !store.runtimeModelSetupMessage.isEmpty {
                Text(store.runtimeModelSetupMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            modelVisibilitySettings
        }
        .task {
            await store.refreshRuntimeProviders()
            await store.refreshHermesMetadata()
            if selectedProviderId.isEmpty {
                if let current = await store.runtimeDefaultModel(),
                   let currentProvider = current.provider,
                   store.selectableRuntimeProviders.contains(where: { $0.id == currentProvider }) {
                    selectedProviderId = currentProvider
                    model = current.model ?? ""
                    await refreshModelsForSelectedProvider()
                } else if let first = store.selectableRuntimeProviders.first {
                    selectedProviderId = first.id
                    await refreshModelsForSelectedProvider()
                }
            }
        }
    }

    private var modelVisibilitySettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Visible in Chat Picker")
                        .font(.headline)
                    Text("Hide providers or individual models from the chat input model menu without disconnecting them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Reset") {
                    store.resetModelVisibility()
                }
                .buttonStyle(.borderless)
            }

            if store.allHermesModelGroups.isEmpty {
                Text("Connect to the server and refresh models to configure picker visibility.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(store.allHermesModelGroups) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle(isOn: Binding(
                                get: { store.isProviderVisible(group.id) },
                                set: { store.setProviderVisible(group.id, visible: $0) }
                            )) {
                                Text(group.title)
                                    .font(.subheadline.weight(.semibold))
                            }
                            ForEach(group.models) { item in
                                Toggle(isOn: Binding(
                                    get: { !store.hiddenModelIds.contains(item.id) },
                                    set: { store.setModelVisible(item, visible: $0) }
                                )) {
                                    Text(item.model)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                .font(.caption)
                                .padding(.leading, 18)
                                .disabled(!store.isProviderVisible(group.id))
                            }
                        }
                        .padding(10)
                        .background(.quaternary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    private func refreshModelsForSelectedProvider() async {
        guard !selectedProviderId.isEmpty else { return }
        await store.discoverRuntimeModels(providerId: selectedProviderId)
        let nextModels = store.runtimeProviderModels[selectedProviderId] ?? provider?.models ?? []
        if model.isEmpty, let first = nextModels.first {
            model = first
        }
    }
}

private struct RuntimeProviderConfigSettingsView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.openURL) private var openURL
    @State private var selectedProviderId = ""
    @State private var apiKey = ""
    @State private var baseUrl = ""
    @State private var isSaving = false
    @State private var isStartingOAuth = false
    @State private var activeOAuthSessionId = ""

    private var provider: RuntimeProviderOption? {
        store.runtimeProviders.first { $0.id == selectedProviderId }
    }

    private var providerCredentials: [RuntimeCredentialEntry] {
        store.runtimeProviderCredentials[selectedProviderId] ?? []
    }

    private var activeOAuthSession: RuntimeOAuthLoginSession? {
        activeOAuthSessionId.isEmpty ? nil : store.runtimeOAuthSessions[activeOAuthSessionId]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Model Config")
                    .font(.headline)
                Text("Configure provider accounts, API keys, and local endpoints. Pick the active model in the Model menu.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            #if os(iOS)
            VStack(alignment: .leading, spacing: 14) {
                providerList
                providerDetail
            }
            #else
            HStack(alignment: .top, spacing: 16) {
                providerList
                    .frame(width: 300)
                providerDetail
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            #endif
            if !store.runtimeModelSetupMessage.isEmpty {
                Text(store.runtimeModelSetupMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .task {
            await store.refreshRuntimeProviders()
            if selectedProviderId.isEmpty {
                let current = store.runtimeProviders.first(where: { $0.isDefault == true }) ?? store.runtimeProviders.first
                if let current {
                    selectProvider(current)
                }
            }
        }
    }

    private var providerList: some View {
        VStack(alignment: .leading, spacing: 10) {
            providerSection("Accounts", providers: providers(in: "Accounts"))
            providerSection("API Keys", providers: providers(in: "API Keys"))
            providerSection("Local", providers: providers(in: "Local"))
        }
    }

    private var providerDetail: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let provider {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(provider.name)
                            .font(.headline)
                        Text(provider.setupHint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if provider.configured == true {
                        Label("Connected", systemImage: "checkmark")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }

                providerCredentialFields(provider)
                providerCredentialManagement(provider)
                providerOAuthLoginView(provider)

                HStack {
                    Button {
                        isSaving = true
                        Task {
                            _ = await store.saveRuntimeProviderValues(
                                providerId: selectedProviderId,
                                apiKey: apiKey,
                                baseUrl: baseUrl
                            )
                            apiKey = ""
                            isSaving = false
                        }
                    } label: {
                        if isSaving {
                            ProgressView()
                        } else {
                            Label("Save Provider", systemImage: "checkmark")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSaving || !canSave(provider))

                    if provider.isOAuth {
                        Text("Run `codmes model` on the server to add another OAuth account. Stored accounts can be selected or removed here.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if provider.configured == true {
                        Button(role: .destructive) {
                            Task { await store.disconnectRuntimeProvider(providerId: selectedProviderId) }
                        } label: {
                            Label("Disconnect", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                        .buttonStyle(.bordered)
                    }
                }
            } else {
                Text("Select a provider.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    private func providers(in section: String) -> [RuntimeProviderOption] {
        store.runtimeProviders.filter { $0.sectionTitle == section }
    }

    private func providerSection(_ title: String, providers: [RuntimeProviderOption]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(providers) { option in
                Button {
                    selectProvider(option)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: iconName(for: option))
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(option.name)
                                .font(.callout)
                                .lineLimit(1)
                            Text(option.id)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        if option.isDefault == true {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else if option.configured == true {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 7)
                    .padding(.horizontal, 9)
                    .background(
                        selectedProviderId == option.id ? Color.accentColor.opacity(0.14) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func providerCredentialManagement(_ provider: RuntimeProviderOption) -> some View {
        if provider.isOAuth {
            VStack(alignment: .leading, spacing: 8) {
                Text("Stored accounts")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if providerCredentials.isEmpty {
                    Text(provider.configured == true ? "Connected account metadata is unavailable. Reconnect with `codmes model` to expose account choices." : "No stored account for this provider.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(providerCredentials) { credential in
                        HStack(spacing: 10) {
                            Image(systemName: credential.active == true ? "checkmark.circle.fill" : "person.crop.circle")
                                .foregroundStyle(credential.active == true ? .green : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(credential.displayName)
                                    .font(.callout)
                                    .lineLimit(1)
                                Text(credential.detailLabel)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if credential.active != true {
                                Button("Use") {
                                    Task {
                                        await store.selectRuntimeProviderCredential(
                                            providerId: selectedProviderId,
                                            credentialId: credential.id
                                        )
                                    }
                                }
                                .buttonStyle(.borderless)
                            }
                            Button(role: .destructive) {
                                Task {
                                    await store.deleteRuntimeProviderCredential(
                                        providerId: selectedProviderId,
                                        credentialId: credential.id
                                    )
                                }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(9)
                        .background(.quaternary.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        } else if provider.configured == true {
            Text("Use Disconnect to remove the stored \(provider.isLocalProvider ? "endpoint" : "credential") and hide this provider from Model selection.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func providerOAuthLoginView(_ provider: RuntimeProviderOption) -> some View {
        if provider.id == "openai-codex" {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Button {
                        Task { await startOpenAICodexLogin() }
                    } label: {
                        if isStartingOAuth {
                            ProgressView()
                        } else {
                            Label(providerCredentials.isEmpty ? "Connect OpenAI Codex" : "Connect Another Account", systemImage: "person.crop.circle.badge.plus")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isStartingOAuth)

                    if let session = activeOAuthSession, !session.isTerminal {
                        Button("Cancel") {
                            Task {
                                await store.cancelRuntimeOAuthLogin(providerId: "openai-codex", sessionId: session.id)
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                }

                if let session = activeOAuthSession, session.status != "approved" {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Status: \(session.status)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            if session.status == "pending" {
                                ProgressView()
                                    .scaleEffect(0.65)
                            }
                        }
                        if let userCode = session.userCode, !userCode.isEmpty {
                            Text(userCode)
                                .font(.system(.title3, design: .monospaced).weight(.semibold))
                                .textSelection(.enabled)
                        }
                        if let verificationUrl = session.verificationUrl, !verificationUrl.isEmpty {
                            Text(verificationUrl)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        if let error = session.error, !error.isEmpty {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                    .padding(10)
                    .background(.quaternary.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    @ViewBuilder
    private func providerCredentialFields(_ provider: RuntimeProviderOption) -> some View {
        if provider.isLocalOllama {
            TextField("http://127.0.0.1:11434/v1", text: $baseUrl)
                .textFieldStyle(.roundedBorder)
            Text("The Workspace Server resolves this URL. iPhone does not connect to Ollama directly.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if provider.needsAPIKey {
            SecureField(provider.configured == true ? "New API key (leave blank to keep current)" : "API key", text: $apiKey)
                .textFieldStyle(.roundedBorder)
            if provider.baseUrlEnv != nil {
                TextField(provider.defaultBaseUrl ?? "Base URL", text: $baseUrl)
                    .textFieldStyle(.roundedBorder)
            }
        } else if provider.isOAuth {
            Label("Account OAuth is stored on the server runtime.", systemImage: "person.badge.key")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func selectProvider(_ option: RuntimeProviderOption) {
        selectedProviderId = option.id
        apiKey = ""
        baseUrl = option.defaultBaseUrl ?? ""
        Task {
            await store.refreshRuntimeProviderCredentials(providerId: option.id)
        }
    }

    private func iconName(for provider: RuntimeProviderOption) -> String {
        if provider.isLocalProvider { return "desktopcomputer" }
        if provider.isOAuth { return "person.crop.circle.badge.checkmark" }
        return "key"
    }

    private func canSave(_ provider: RuntimeProviderOption?) -> Bool {
        guard let provider else { return false }
        if provider.isOAuth { return false }
        if provider.isLocalOllama { return !baseUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if provider.needsAPIKey {
            return !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !baseUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return false
    }

    private func startOpenAICodexLogin() async {
        isStartingOAuth = true
        guard let session = await store.startOpenAICodexLogin() else {
            isStartingOAuth = false
            return
        }
        isStartingOAuth = false
        activeOAuthSessionId = session.id
        if let value = session.verificationUrl, let url = URL(string: value) {
            openURL(url)
        }
        await pollOpenAICodexLogin(sessionId: session.id, intervalSeconds: session.intervalSeconds ?? 5)
    }

    private func pollOpenAICodexLogin(sessionId: String, intervalSeconds: Int) async {
        let interval = UInt64(max(3, intervalSeconds)) * 1_000_000_000
        for _ in 0..<120 {
            try? await Task.sleep(nanoseconds: interval)
            await store.refreshRuntimeOAuthLogin(providerId: "openai-codex", sessionId: sessionId)
            if store.runtimeOAuthSessions[sessionId]?.isTerminal == true {
                break
            }
        }
    }
}
