import SwiftUI
#if os(iOS)
import UIKit
#endif

struct RootView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @State private var selection: WorkspaceSection? = .chat
    @State private var selectedPluginViewId: String?
    @State private var selectedPluginRouteId: String?
    @State private var isChatPanelVisible = false
    @State private var chatPanelDragX: CGFloat = 0
    @State private var isSidebarVisible = false
    @State private var sidebarDragX: CGFloat = 0
    @State private var showingGlobalSearch = false
    @State private var showingSettings = false
    @State private var isMacSidebarVisible = true
    @State private var showingMacPluginMenu = false
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

    private var selectedPluginView: PluginView? {
        guard let selectedPluginViewId else { return nil }
        return store.pluginViews.first { $0.id == selectedPluginViewId }
    }

    private var activeSurfaceId: String {
        selectedPluginView?.id ?? selectedSection.runtimeSurfaceId
    }

    private var activeSurfaceTitle: String {
        selectedPluginView?.title ?? selectedSection.rawValue
    }

    private var activeSurfaceIcon: String {
        selectedPluginView?.systemImage ?? selectedSection.systemImage
    }

    private var activeSurfaceTaskKey: String {
        activeSurfaceId
    }

    private var macHasSidebar: Bool {
        activeSurfaceId == "chat"
            || activeSurfaceId == "notes"
            || activeSurfaceId == "code"
            || !(selectedPluginView?.navigation ?? []).isEmpty
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
        } else if let selectedPluginView {
            PluginNavigationSidebar(
                surface: selectedPluginView,
                selectedRouteId: $selectedPluginRouteId
            )
        }
    }

    private func macSidebarWidth(for availableWidth: CGFloat) -> CGFloat {
        if activeSurfaceId == "chat" {
            return min(300, max(240, availableWidth * 0.24))
        }
        if selectedPluginView != nil {
            return min(290, max(230, availableWidth * 0.24))
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
                    showingMacPluginMenu.toggle()
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
                .popover(isPresented: $showingMacPluginMenu, arrowEdge: .top) {
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
                    showingMacPluginMenu = false
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: section.systemImage)
                            .frame(width: 18)
                        Text(section.rawValue)
                        Spacer()
                        if selectedPluginViewId == nil && selectedSection == section {
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

            ForEach(store.enabledBuiltInPluginViews) { view in
                pluginMenuButton(view)
            }

            if !store.enabledCommunityPluginViews.isEmpty {
                Divider()
                    .padding(.vertical, 4)
            }

            ForEach(store.enabledCommunityPluginViews) { view in
                pluginMenuButton(view)
            }
        }
        .padding(8)
        .frame(minWidth: 210)
    }

    private func pluginMenuButton(_ view: PluginView) -> some View {
        Button {
            selectPluginView(view)
            showingMacPluginMenu = false
        } label: {
            HStack(spacing: 10) {
                Image(systemName: view.systemImage)
                    .frame(width: 18)
                Text(view.title)
                Spacer()
                if selectedPluginViewId == view.id {
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
                                    if selectedPluginViewId == nil && selectedSection == section {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }

                            ForEach(store.enabledBuiltInPluginViews) { view in
                                Button {
                                    selectPluginView(view)
                                } label: {
                                    Label(view.title, systemImage: view.systemImage)
                                    if selectedPluginViewId == view.id {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }

                            if !store.enabledCommunityPluginViews.isEmpty {
                                Divider()
                            }

                            ForEach(store.enabledCommunityPluginViews) { view in
                                Button {
                                    selectPluginView(view)
                                } label: {
                                    Label(view.title, systemImage: view.systemImage)
                                    if selectedPluginViewId == view.id {
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
            } else if let selectedPluginView {
                PluginNavigationSidebar(
                    surface: selectedPluginView,
                    selectedRouteId: $selectedPluginRouteId,
                    onSelectRoute: {
                        if !persistent {
                            closeSidebar()
                        }
                    }
                )
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
        selectedPluginViewId = nil
        selectedPluginRouteId = nil
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

    private func selectPluginView(_ surface: PluginView) {
        selectedPluginViewId = surface.id
        selectedPluginRouteId = surface.navigation?.first?.id
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
            if let selectedPluginView {
                PluginContentView(
                    surface: selectedPluginView,
                    routeId: selectedPluginRouteId,
                    reloadRevision: store.pluginAuthRevision
                )
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

struct PluginNavigationSidebar: View {
    @EnvironmentObject private var store: WorkspaceStore
    let surface: PluginView
    @Binding var selectedRouteId: String?
    var onSelectRoute: () -> Void = {}

    @State private var showingSettings = false

    private var authStatus: PluginAuthStatus? {
        store.pluginAuthStatus(for: surface.pluginId)
    }

    private var authOperation: String? {
        store.pluginAuthOperation(for: surface.pluginId)
    }

    private var errorMessage: String? {
        store.pluginAuthError(for: surface.pluginId)
    }

    var body: some View {
        VStack(spacing: 0) {
            if surface.hasAuthentication == true {
                accountHeader

                Divider()
                    .padding(.horizontal, 12)
            }

            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(surface.navigation ?? []) { route in
                        Button {
                            selectedRouteId = route.id
                            onSelectRoute()
                        } label: {
                            HStack(spacing: 11) {
                                Image(systemName: route.systemImage)
                                    .frame(width: 20)
                                Text(route.title)
                                    .lineLimit(1)
                                Spacer()
                                if route.requiresAuth == true, authStatus?.authenticated != true {
                                    Image(systemName: "lock.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .font(.callout.weight(.medium))
                            .foregroundStyle(selectedRouteId == route.id ? .primary : .secondary)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 38)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .background(
                                selectedRouteId == route.id ? Color.primary.opacity(0.09) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(10)
            }
        }
        .background(.background.opacity(0.96))
        .task(id: surface.id) {
            if selectedRouteId == nil {
                selectedRouteId = surface.navigation?.first?.id
            }
            await refreshAuthStatus()
        }
        .sheet(isPresented: $showingSettings, onDismiss: {
            Task {
                await refreshAuthStatus()
            }
        }) {
            WorkspaceSettingsView(
                isPresented: $showingSettings,
                initialSection: .runtimePlugins,
                initialSurfaceId: surface.id
            )
            .environmentObject(store)
        }
    }

    private var accountHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: surface.systemImage)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(surface.title)
                    .font(.headline)
                    .lineLimit(1)

                HStack(spacing: 5) {
                    Circle()
                        .fill(accountStatusColor)
                        .frame(width: 7, height: 7)
                    Text(accountStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if authStatus?.authenticated == true,
                   authStatus?.profileSyncing == true {
                    HStack(spacing: 5) {
                        ProgressView()
                            .controlSize(.mini)
                        Text(authStatus?.syncStage ?? "학교 데이터 동기화 중…")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: 6)

            if authOperation != nil {
                ProgressView()
                    .controlSize(.small)
            } else if authStatus?.authenticated == true {
                Button("로그아웃") {
                    logout()
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .controlSize(.small)
            } else {
                Button("로그인") {
                    showingSettings = true
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .help(
            errorMessage
                ?? authStatus?.portalSyncError
                ?? authStatus?.lmsSyncError
                ?? accountStatusText
        )
    }

    private var accountStatusText: String {
        if authOperation == "login" {
            return "로그인 중…"
        }
        if authOperation == "logout" {
            return "로그아웃 중…"
        }
        if let errorMessage, !errorMessage.isEmpty {
            return "상태 확인 불가"
        }
        if authStatus?.authenticated == true {
            let identity = [
                authStatus?.studentId ?? authStatus?.username ?? "",
                authStatus?.name ?? "",
            ].filter { !$0.isEmpty }
            if !identity.isEmpty {
                return identity.joined(separator: " ")
            }
            return "로그인됨"
        }
        return "로그인 필요"
    }

    private var accountStatusColor: Color {
        guard authStatus?.authenticated == true else {
            return .secondary
        }
        let hasStudentId = authStatus?.studentId?.isEmpty == false
        let hasName = authStatus?.name?.isEmpty == false
        return hasStudentId && hasName ? .green : .orange
    }

    @MainActor
    private func refreshAuthStatus() async {
        guard surface.hasAuthentication == true, let pluginId = surface.pluginId else {
            return
        }
        await store.refreshPluginAuthStatus(pluginId: pluginId)
    }

    @MainActor
    private func logout() {
        guard let pluginId = surface.pluginId else { return }
        store.startPluginLogout(pluginId: pluginId)
    }
}

private struct PluginAuthenticationSettingsView: View {
    @EnvironmentObject private var store: WorkspaceStore
    let surface: PluginView

    @State private var username = ""
    @State private var password = ""

    private var authStatus: PluginAuthStatus? {
        store.pluginAuthStatus(for: surface.pluginId)
    }

    private var authOperation: String? {
        store.pluginAuthOperation(for: surface.pluginId)
    }

    private var isWorking: Bool {
        authOperation != nil
    }

    private var errorMessage: String? {
        store.pluginAuthError(for: surface.pluginId)
    }

    private var isKNUPortal: Bool {
        surface.id == "knu"
    }

    private var portalProfileNeedsRefresh: Bool {
        isKNUPortal
            && authStatus?.authenticated == true
            && (
                authStatus?.profileSyncing == true
                    || authStatus?.name?.isEmpty != false
            )
    }

    private var connectedAccountTitle: String {
        if isKNUPortal {
            return authStatus?.name
                ?? authStatus?.studentId
                ?? authStatus?.username
                ?? "공주대 포털 계정"
        }
        return authStatus?.username ?? "\(surface.title) 계정"
    }

    private var connectedAccountDetail: String {
        if isKNUPortal {
            let academic = [
                authStatus?.studentId ?? "",
                authStatus?.major ?? "",
                authStatus?.year.map { "\($0)학년" } ?? "",
            ].filter { !$0.isEmpty }
            if !academic.isEmpty {
                return academic.joined(separator: " · ")
            }
            return "포털 프로필을 가져오는 중입니다."
        }
        return "사용자 토큰이 Codmes 서버에 저장되어 있습니다."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if authOperation == "login" {
                authenticationProgress
            } else if authStatus?.authenticated == true {
                VStack(alignment: .leading, spacing: 8) {
                    Text(isKNUPortal ? "Connected portal account" : "Stored account")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(connectedAccountTitle)
                                .font(.callout.weight(.medium))
                            Text(connectedAccountDetail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            if portalProfileNeedsRefresh {
                                Text(authStatus?.syncStage ?? "학교 데이터 동기화 중…")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if portalProfileNeedsRefresh {
                            ProgressView()
                                .controlSize(.small)
                                .help(authStatus?.syncStage ?? "학교 데이터 동기화 중")
                        } else {
                            Text("Connected")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                    }
                    .padding(10)
                    .background(.quaternary.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))

                    if let portalSyncError = authStatus?.portalSyncError,
                       !portalSyncError.isEmpty {
                        Label(
                            "포털 동기화에 실패했습니다: \(portalSyncError)",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.caption)
                        .foregroundStyle(.red)
                    }

                    if let lmsSyncError = authStatus?.lmsSyncError,
                       !lmsSyncError.isEmpty {
                        Label(
                            "LMS 동기화에 실패했습니다: \(lmsSyncError)",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                }

                HStack {
                    Label("비밀번호는 저장되지 않습니다.", systemImage: "person.badge.key")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(role: .destructive) {
                        logout()
                    } label: {
                        Label("Disconnect", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    .buttonStyle(.bordered)
                    .disabled(isWorking)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text(isKNUPortal ? "Kongju portal authentication" : "Account authentication")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextField(
                        isKNUPortal ? "공주대 포털 학번" : "\(surface.title) 서비스 아이디",
                        text: $username
                    )
                        .textFieldStyle(.roundedBorder)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                    SecureField("비밀번호", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            login()
                        }

                    Button {
                        login()
                    } label: {
                        if isWorking {
                            HStack(spacing: 7) {
                                ProgressView()
                                    .controlSize(.small)
                                Text(isKNUPortal ? "포털 인증 중…" : "연결 중…")
                            }
                        } else {
                            Label(
                                isKNUPortal ? "공주대 포털 연결" : "Connect \(surface.title)",
                                systemImage: "person.crop.circle.badge.plus"
                            )
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        isWorking
                            || username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || password.isEmpty
                    )

                    Label(
                        isKNUPortal
                            ? "학번과 비밀번호로 공주대 포털을 직접 확인합니다. 비밀번호는 인증 요청 후 폐기하고, 발급된 세션 토큰만 Codmes 서버에 저장합니다."
                            : "비밀번호는 로그인 요청에만 사용하고 폐기하며, 발급된 사용자 토큰만 Codmes 서버에 저장합니다.",
                        systemImage: "lock.shield"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

        }
        .task {
            await refreshStatus()
        }
    }

    private var authenticationProgress: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.regular)
            VStack(spacing: 5) {
                Text(isKNUPortal ? "공주대 포털 인증 중" : "\(surface.title) 연결 중")
                    .font(.headline)
                Text(
                    isKNUPortal
                        ? "학교 포털에서 계정을 확인하고 있습니다. 설정을 닫아도 인증은 계속됩니다."
                        : "서비스에서 계정을 확인하고 있습니다. 설정을 닫아도 연결은 계속됩니다."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .padding(.horizontal, 20)
        .background(.quaternary.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
    }

    @MainActor
    private func refreshStatus() async {
        guard let pluginId = surface.pluginId else { return }
        await store.refreshPluginAuthStatus(pluginId: pluginId)
    }

    @MainActor
    private func login() {
        guard let pluginId = surface.pluginId else { return }
        store.startPluginLogin(
            pluginId: pluginId,
            username: username,
            password: password
        )
        password = ""
    }

    @MainActor
    private func logout() {
        guard let pluginId = surface.pluginId else { return }
        store.startPluginLogout(pluginId: pluginId)
    }
}

struct PluginContentView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.openURL) private var openURL
    let surface: PluginView
    let routeId: String?
    let reloadRevision: Int
    @State private var document: PluginViewDocument?
    @State private var loadError: String?
    @State private var query = ""
    @State private var selectedFilters: [String: String] = [:]
    @State private var selectedCalendarDate = Date()
    @State private var visibleCalendarMonth = Date()
    @State private var calendarEditor: CalendarEventEditorContext?
    @State private var collectionEditor: PluginCollectionEditorContext?

    var body: some View {
        Group {
            if surface.renderer == "declarative", surface.pluginId != nil {
                if let document {
                    VStack(spacing: 0) {
                        if let dataState = document.dataState {
                            pluginDataStateBanner(dataState)
                        }
                        if document.presentation == "calendar" {
                            calendar(document)
                        } else if document.presentation == "dashboard" {
                            dashboard(document)
                        } else {
                            collection(document)
                        }
                    }
                } else if let loadError {
                    ContentUnavailableView {
                        Label("Couldn’t open \(activeRouteTitle)", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(loadError)
                    } actions: {
                        Button("Retry") {
                            Task { await loadPluginViewDocument() }
                        }
                    }
                } else {
                    ProgressView("Loading \(activeRouteTitle)…")
                }
            } else {
                placeholder
            }
        }
        .task(id: "\(surface.id):\(routeId ?? ""):\(reloadRevision)") {
            await loadPluginViewDocument()
        }
        .sheet(item: $calendarEditor) { context in
            CalendarEventEditor(
                context: context,
                onSave: { draft in
                    try await saveCalendarEvent(context: context, draft: draft)
                    await loadPluginViewDocument()
                },
                onDelete: context.item == nil ? nil : {
                    try await deleteCalendarEvent(context: context)
                    await loadPluginViewDocument()
                }
            )
        }
        .sheet(item: $collectionEditor) { context in
            PluginCollectionEditor(
                context: context,
                onSave: { values in
                    try await savePluginCollectionItem(context: context, values: values)
                    await loadPluginViewDocument()
                },
                onDelete: context.item == nil ? nil : {
                    try await deletePluginCollectionItem(context: context)
                    await loadPluginViewDocument()
                }
            )
        }
    }

    private var activeRouteTitle: String {
        surface.navigation?.first(where: { $0.id == routeId })?.title ?? surface.title
    }

    private func pluginDataStateBanner(_ state: PluginSurfaceDataState) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: state.status == "partial" ? "exclamationmark.circle" : "wifi.exclamationmark")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(state.status == "partial" ? "Some data could not be loaded" : "Plugin data is unavailable")
                    .font(.callout.weight(.semibold))
                Text(dataStateMessage(state))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if state.errors.contains(where: \.retryable) {
                Button("Retry") {
                    Task { await loadPluginViewDocument() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(Color.orange.opacity(0.10))
        .overlay(alignment: .bottom) { Divider() }
    }

    private func dataStateMessage(_ state: PluginSurfaceDataState) -> String {
        state.errors.map(\.message).reduce(into: [String]()) { messages, message in
            if !messages.contains(message) {
                messages.append(message)
            }
        }.joined(separator: " ")
    }

    private func collection(_ document: PluginViewDocument) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(document.title)
                            .font(.title2.weight(.semibold))
                        if let subtitle = document.subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if let editor = document.editor {
                        Button {
                            collectionEditor = PluginCollectionEditorContext(
                                editor: editor,
                                item: nil
                            )
                        } label: {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("새 항목")
                    }
                }
                .padding(.bottom, 18)

                if let search = document.search {
                    HStack(spacing: 9) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.tertiary)
                        TextField(search.placeholder ?? "Search", text: $query)
                            .textFieldStyle(.plain)
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            #endif
                    }
                    .padding(.horizontal, 12)
                    .frame(minHeight: 38)
                    .background(.quaternary.opacity(0.22), in: RoundedRectangle(cornerRadius: 9))
                    .overlay {
                        RoundedRectangle(cornerRadius: 9)
                            .stroke(.quaternary.opacity(0.55), lineWidth: 0.5)
                    }
                    .padding(.bottom, 12)
                }

                ForEach(document.filters) { filter in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(filter.options) { option in
                                filterChip(filter: filter, option: option)
                            }
                        }
                    }
                    .padding(.bottom, 14)
                }

                let items = filteredItems(in: document)
                if items.isEmpty {
                    ContentUnavailableView(
                        document.emptyState?.title ?? "Nothing to show",
                        systemImage: document.emptyState?.systemImage ?? "tray"
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.top, 50)
                } else {
                    LazyVStack(spacing: document.collectionStyle == "cards" ? 12 : 1) {
                        ForEach(items) { item in
                            collectionRow(item)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay {
                        if document.collectionStyle != "cards" {
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(.quaternary.opacity(0.55), lineWidth: 0.5)
                        }
                    }
                }
            }
            .frame(maxWidth: 980, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(.background)
        .refreshable {
            await loadPluginViewDocument()
        }
    }

    private func calendar(_ document: PluginViewDocument) -> some View {
        let selectedItems = calendarItems(document.items, on: selectedCalendarDate)

        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(document.title)
                            .font(.title2.weight(.semibold))
                        if let subtitle = document.subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("오늘") {
                        let now = Date()
                        selectedCalendarDate = now
                        visibleCalendarMonth = now
                    }
                    .buttonStyle(.borderless)
                    if let collectionId = document.editor?.collection {
                        Button {
                            calendarEditor = CalendarEventEditorContext(
                                collectionId: collectionId,
                                item: nil,
                                defaultDate: selectedCalendarDate
                            )
                        } label: {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("새 일정")
                    }
                }

                VStack(spacing: 12) {
                    HStack {
                        Button {
                            moveCalendarMonth(by: -1)
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("이전 달")

                        Spacer()
                        Text(calendarMonthTitle(visibleCalendarMonth))
                            .font(.headline)
                        Spacer()

                        Button {
                            moveCalendarMonth(by: 1)
                        } label: {
                            Image(systemName: "chevron.right")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("다음 달")
                    }
                    .padding(.horizontal, 4)

                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7),
                        spacing: 5
                    ) {
                        ForEach(Array(calendarWeekdaySymbols().enumerated()), id: \.offset) { _, symbol in
                            Text(symbol)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                        }

                        ForEach(Array(calendarMonthDates().enumerated()), id: \.offset) { _, date in
                            if let date {
                                calendarDayCell(date, items: calendarItems(document.items, on: date))
                            } else {
                                Color.clear
                                    .frame(minHeight: 46)
                            }
                        }
                    }
                }
                .padding(16)
                .background(.quaternary.opacity(0.16), in: RoundedRectangle(cornerRadius: 14))
                .overlay {
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(.quaternary.opacity(0.55), lineWidth: 0.5)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text(calendarDayTitle(selectedCalendarDate))
                        .font(.headline)
                    if selectedItems.isEmpty {
                        ContentUnavailableView(
                            "이 날짜에는 일정이 없습니다.",
                            systemImage: "calendar"
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 26)
                    } else {
                        LazyVStack(spacing: 1) {
                            ForEach(selectedItems) { item in
                                calendarEventRow(item)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(.quaternary.opacity(0.55), lineWidth: 0.5)
                        }
                    }
                }
            }
            .frame(maxWidth: 980, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(.background)
        .refreshable {
            await loadPluginViewDocument()
        }
    }

    private func calendarDayCell(_ date: Date, items: [PluginSurfaceItem]) -> some View {
        let calendar = Calendar.autoupdatingCurrent
        let selected = calendar.isDate(date, inSameDayAs: selectedCalendarDate)
        let today = calendar.isDateInToday(date)

        return Button {
            selectedCalendarDate = date
        } label: {
            VStack(spacing: 5) {
                Text(String(calendar.component(.day, from: date)))
                    .font(.callout.weight(today || selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.white : Color.primary)
                HStack(spacing: 2) {
                    ForEach(0..<min(items.count, 3), id: \.self) { _ in
                        Circle()
                            .fill(selected ? Color.white.opacity(0.9) : Color.accentColor)
                            .frame(width: 4, height: 4)
                    }
                }
                .frame(height: 4)
            }
            .frame(maxWidth: .infinity, minHeight: 46)
            .background(
                selected ? Color.accentColor : (today ? Color.accentColor.opacity(0.1) : Color.clear),
                in: RoundedRectangle(cornerRadius: 9)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(calendarDayTitle(date))
        .accessibilityValue(items.isEmpty ? "일정 없음" : "일정 \(items.count)개")
    }

    private func calendarEventRow(_ item: PluginSurfaceItem) -> some View {
        Button {
            if let collectionId = document?.editor?.collection {
                calendarEditor = CalendarEventEditorContext(
                    collectionId: collectionId,
                    item: item,
                    defaultDate: selectedCalendarDate
                )
            } else {
                perform(item.action)
            }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor)
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 5) {
                    Text(calendarTimeText(item))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(item.title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                    if let location = item.tags.first, !location.isEmpty {
                        Label(location, systemImage: "mappin.and.ellipse")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let body = item.body, !body.isEmpty {
                        Text(body)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(.background)
        }
        .buttonStyle(.plain)
    }

    private func calendarItems(_ items: [PluginSurfaceItem], on date: Date) -> [PluginSurfaceItem] {
        let calendar = Calendar.autoupdatingCurrent
        return items
            .filter { item in
                guard let startsAt = pluginDate(item.temporal?.startsAt) else { return false }
                return calendar.isDate(startsAt, inSameDayAs: date)
            }
            .sorted {
                (pluginDate($0.temporal?.startsAt) ?? .distantFuture)
                    < (pluginDate($1.temporal?.startsAt) ?? .distantFuture)
            }
    }

    private func moveCalendarMonth(by value: Int) {
        guard let next = Calendar.autoupdatingCurrent.date(
            byAdding: .month,
            value: value,
            to: visibleCalendarMonth
        ) else { return }
        visibleCalendarMonth = next
        selectedCalendarDate = next
    }

    private func calendarMonthDates() -> [Date?] {
        let calendar = Calendar.autoupdatingCurrent
        guard let interval = calendar.dateInterval(of: .month, for: visibleCalendarMonth),
              let dayRange = calendar.range(of: .day, in: .month, for: interval.start)
        else { return [] }
        let weekday = calendar.component(.weekday, from: interval.start)
        let leading = (weekday - calendar.firstWeekday + 7) % 7
        return Array(repeating: nil, count: leading) + dayRange.compactMap { day in
            calendar.date(byAdding: .day, value: day - 1, to: interval.start)
        }.map(Optional.some)
    }

    private func calendarWeekdaySymbols() -> [String] {
        let calendar = Calendar.autoupdatingCurrent
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let offset = max(0, min(symbols.count - 1, calendar.firstWeekday - 1))
        return Array(symbols[offset...] + symbols[..<offset])
    }

    private func calendarMonthTitle(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("yyyyMMMM")
        return formatter.string(from: date)
    }

    private func calendarDayTitle(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.autoupdatingCurrent
        formatter.dateStyle = .full
        return formatter.string(from: date)
    }

    private func calendarTimeText(_ item: PluginSurfaceItem) -> String {
        guard let temporal = item.temporal else { return "" }
        if temporal.allDay { return "종일" }
        guard let start = pluginDate(temporal.startsAt) else { return temporal.startsAt }
        let formatter = DateFormatter()
        formatter.locale = Locale.autoupdatingCurrent
        formatter.timeStyle = .short
        let startText = formatter.string(from: start)
        guard let end = pluginDate(temporal.endsAt) else { return startText }
        return "\(startText) – \(formatter.string(from: end))"
    }

    private func pluginDate(_ value: String?) -> Date? {
        parsePluginSurfaceDate(value)
    }

    @MainActor
    private func saveCalendarEvent(
        context: CalendarEventEditorContext,
        draft: CalendarEventDraft
    ) async throws {
        guard let api = store.api, let pluginId = surface.pluginId else {
            throw WorkspaceAPIError.invalidURL
        }
        if let item = context.item {
            try await api.updatePluginCollectionItem(
                pluginId: pluginId,
                collectionId: context.collectionId,
                itemId: item.id,
                item: draft
            )
        } else {
            try await api.createPluginCollectionItem(
                pluginId: pluginId,
                collectionId: context.collectionId,
                item: draft
            )
        }
    }

    @MainActor
    private func deleteCalendarEvent(context: CalendarEventEditorContext) async throws {
        guard let api = store.api,
              let pluginId = surface.pluginId,
              let item = context.item
        else {
            throw WorkspaceAPIError.invalidURL
        }
        try await api.deletePluginCollectionItem(
            pluginId: pluginId,
            collectionId: context.collectionId,
            itemId: item.id
        )
    }

    private func dashboard(_ document: PluginViewDocument) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(document.title)
                        .font(.title2.weight(.semibold))
                    if let subtitle = document.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                let sections = document.sections ?? []
                if sections.isEmpty {
                    ContentUnavailableView(
                        document.emptyState?.title ?? "Nothing to show",
                        systemImage: document.emptyState?.systemImage ?? "tray"
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                } else {
                    ForEach(sections) { section in
                        dashboardSection(section)
                    }
                }
            }
            .frame(maxWidth: 1180, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(.background)
        .refreshable {
            await loadPluginViewDocument()
        }
    }

    private func dashboardSection(_ section: PluginSurfaceSection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if let systemImage = section.systemImage, !systemImage.isEmpty {
                    Image(systemName: systemImage)
                        .foregroundStyle(.secondary)
                }
                Text(section.title)
                    .font(.headline)
            }
            if let subtitle = section.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if section.kind == "keyValue" {
                keyValueCard(section.fields ?? [])
            } else {
                tableCard(columns: section.columns ?? [], rows: section.rows ?? [])
            }
        }
    }

    private func keyValueCard(_ fields: [PluginSurfaceField]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(fields.enumerated()), id: \.element.id) { index, field in
                HStack(alignment: .firstTextBaseline, spacing: 18) {
                    Text(field.label)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(width: 82, alignment: .leading)
                    Text(field.value)
                        .font(.callout.weight(.medium))
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 15)
                .padding(.vertical, 12)
                if index < fields.count - 1 {
                    Divider().padding(.leading, 15)
                }
            }
        }
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(.quaternary.opacity(0.55), lineWidth: 0.5)
        }
    }

    private func tableCard(columns: [String], rows: [[String]]) -> some View {
        ScrollView(.horizontal, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 0) {
                tableRow(columns, isHeader: true)
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    Divider()
                    tableRow(row, isHeader: false)
                        .background(index.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.018))
                }
            }
        }
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(.quaternary.opacity(0.55), lineWidth: 0.5)
        }
    }

    private func tableRow(_ values: [String], isHeader: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                Text(value.isEmpty ? " " : value)
                    .font(isHeader ? .caption.weight(.semibold) : .caption)
                    .foregroundStyle(isHeader ? .secondary : .primary)
                    .lineLimit(4)
                    .frame(
                        width: index == 0 ? 112 : 154,
                        alignment: .leading
                    )
                    .padding(.horizontal, 10)
                    .padding(.vertical, isHeader ? 10 : 11)
            }
        }
        .background(isHeader ? Color.primary.opacity(0.045) : Color.clear)
    }

    private func filterChip(
        filter: PluginSurfaceFilter,
        option: PluginSurfaceFilterOption
    ) -> some View {
        let selected = selectedFilters[filter.id] == option.value
            || (selectedFilters[filter.id] == nil && option.value == "__all__")
        return Button {
            selectedFilters[filter.id] = option.value
        } label: {
            Text(option.label)
                .font(.caption.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? .primary : .secondary)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(
                    selected ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 8)
                )
        }
        .buttonStyle(.plain)
    }

    private func collectionRow(_ item: PluginSurfaceItem) -> some View {
        let usesCardStyle = document?.collectionStyle == "cards"
        return Button {
            if let editor = document?.editor {
                collectionEditor = PluginCollectionEditorContext(editor: editor, item: item)
            } else {
                perform(item.action)
            }
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                if item.eyebrow != nil || item.meta != nil || item.badge != nil {
                    HStack(alignment: .top, spacing: 12) {
                        if let eyebrow = item.eyebrow, !eyebrow.isEmpty {
                            HStack(spacing: 6) {
                                if let systemImage = item.systemImage, !systemImage.isEmpty {
                                    Image(systemName: systemImage)
                                }
                                Text(eyebrow)
                            }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                        }
                        Spacer(minLength: 8)
                        VStack(alignment: .trailing, spacing: 4) {
                            if let badge = item.badge, !badge.isEmpty {
                                Text(badge)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(pluginBadgeColor(item.badgeTone))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(
                                        pluginBadgeColor(item.badgeTone).opacity(0.12),
                                        in: Capsule()
                                    )
                            }
                            if let meta = item.meta, !meta.isEmpty {
                                Text(meta)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                if let subtitle = item.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(item.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                if let body = item.body, !body.isEmpty {
                    Text(body)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                if !item.tags.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(Array(item.tags.prefix(3)), id: \.self) { tag in
                            Text(tag)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 5))
                        }
                    }
                }
            }
            .padding(usesCardStyle ? 18 : 15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(.background)
            .clipShape(RoundedRectangle(cornerRadius: usesCardStyle ? 14 : 0))
            .overlay {
                if usesCardStyle {
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(.quaternary.opacity(0.65), lineWidth: 0.5)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(item.action == nil && document?.editor == nil)
    }

    private func pluginBadgeColor(_ tone: String?) -> Color {
        switch tone {
        case "danger": return .red
        case "warning": return .orange
        case "success": return .green
        case "neutral": return .secondary
        default: return .accentColor
        }
    }

    private func filteredItems(in document: PluginViewDocument) -> [PluginSurfaceItem] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return document.items.filter { item in
            for filter in document.filters {
                let selected = selectedFilters[filter.id] ?? "__all__"
                if selected != "__all__", item.filterValues[filter.id] != selected {
                    return false
                }
            }
            guard !needle.isEmpty else { return true }
            return ([item.title, item.subtitle ?? "", item.body ?? ""] + item.tags)
                .joined(separator: " ")
                .lowercased()
                .contains(needle)
        }
    }

    private func perform(_ action: PluginSurfaceAction?) {
        guard action?.type == "openURL",
              let value = action?.url,
              let url = URL(string: value),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "")
        else { return }
        openURL(url)
    }

    @MainActor
    private func savePluginCollectionItem(
        context: PluginCollectionEditorContext,
        values: [String: PluginSurfaceEditorValue]
    ) async throws {
        guard let api = store.api, let pluginId = surface.pluginId else {
            throw WorkspaceAPIError.invalidURL
        }
        if let item = context.item {
            try await api.updatePluginCollectionItem(
                pluginId: pluginId,
                collectionId: context.editor.collection,
                itemId: item.id,
                item: values
            )
        } else {
            try await api.createPluginCollectionItem(
                pluginId: pluginId,
                collectionId: context.editor.collection,
                item: values
            )
        }
    }

    @MainActor
    private func deletePluginCollectionItem(
        context: PluginCollectionEditorContext
    ) async throws {
        guard let api = store.api,
              let pluginId = surface.pluginId,
              let item = context.item
        else {
            throw WorkspaceAPIError.invalidURL
        }
        try await api.deletePluginCollectionItem(
            pluginId: pluginId,
            collectionId: context.editor.collection,
            itemId: item.id
        )
    }

    private var placeholder: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: surface.systemImage)
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text(surface.title)
                        .font(.title2.weight(.semibold))
                    Text(surface.description?.isEmpty == false ? surface.description! : "Plugin view")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text("Open the chat panel to use this surface with its own prompt and tool mode.")
                .font(.callout)
                .foregroundStyle(.secondary)

            if let prompt = surface.prompt, !prompt.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("View prompt")
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

    @MainActor
    private func loadPluginViewDocument() async {
        guard surface.renderer == "declarative", let pluginId = surface.pluginId else { return }
        let requestedRouteId = routeId
        document = nil
        loadError = nil
        query = ""
        selectedFilters = [:]
        guard let api = store.api else {
            loadError = "Connect to the Codmes server first."
            return
        }
        do {
            let loadedDocument = try await api.pluginViewDocument(
                pluginId: pluginId,
                routeId: requestedRouteId
            )
            guard !Task.isCancelled, routeId == requestedRouteId else { return }
            document = loadedDocument
        } catch {
            guard !Task.isCancelled, routeId == requestedRouteId else { return }
            loadError = error.localizedDescription
        }
    }
}

private struct PluginCollectionEditorContext: Identifiable {
    let id = UUID()
    let editor: PluginSurfaceEditor
    let item: PluginSurfaceItem?
}

private struct PluginCollectionEditor: View {
    @Environment(\.dismiss) private var dismiss
    let context: PluginCollectionEditorContext
    let onSave: ([String: PluginSurfaceEditorValue]) async throws -> Void
    let onDelete: (() async throws -> Void)?

    @State private var textValues: [String: String]
    @State private var booleanValues: [String: Bool]
    @State private var dateValues: [String: Date]
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showDeleteConfirmation = false

    init(
        context: PluginCollectionEditorContext,
        onSave: @escaping ([String: PluginSurfaceEditorValue]) async throws -> Void,
        onDelete: (() async throws -> Void)?
    ) {
        self.context = context
        self.onSave = onSave
        self.onDelete = onDelete
        var texts: [String: String] = [:]
        var booleans: [String: Bool] = [:]
        var dates: [String: Date] = [:]
        for field in context.editor.fields ?? [] {
            let value = context.item?.editorValues?[field.id]
            if field.type == "boolean" {
                booleans[field.id] = value?.booleanValue ?? false
            } else if field.type == "date" || field.type == "dateTime" {
                dates[field.id] = parsePluginSurfaceDate(value?.stringValue) ?? Date()
            } else {
                texts[field.id] = value?.stringValue ?? ""
            }
        }
        _textValues = State(initialValue: texts)
        _booleanValues = State(initialValue: booleans)
        _dateValues = State(initialValue: dates)
    }

    var body: some View {
        NavigationStack {
            Form {
                ForEach(context.editor.fields ?? []) { field in
                    editorField(field)
                }
                if onDelete != nil {
                    Section {
                        Button("삭제", role: .destructive) {
                            showDeleteConfirmation = true
                        }
                        .disabled(isSaving)
                    }
                }
            }
            .navigationTitle(context.item == nil ? "새 항목" : "항목 편집")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장") {
                        Task { await save() }
                    }
                    .disabled(isSaving || !requiredFieldsAreValid)
                }
            }
            .overlay {
                if isSaving {
                    ProgressView()
                        .padding(18)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .alert(
                "변경사항을 저장하지 못했습니다.",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("확인", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .confirmationDialog(
                "이 항목을 삭제할까요?",
                isPresented: $showDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("삭제", role: .destructive) {
                    Task { await delete() }
                }
                Button("취소", role: .cancel) {}
            }
        }
        #if os(macOS)
        .frame(width: 480, height: 580)
        #endif
    }

    @ViewBuilder
    private func editorField(_ field: PluginSurfaceEditorField) -> some View {
        if field.type == "boolean" {
            Toggle(
                field.label,
                isOn: Binding(
                    get: { booleanValues[field.id] ?? false },
                    set: { booleanValues[field.id] = $0 }
                )
            )
        } else if field.type == "date" || field.type == "dateTime" {
            DatePicker(
                field.label,
                selection: Binding(
                    get: { dateValues[field.id] ?? Date() },
                    set: { dateValues[field.id] = $0 }
                ),
                displayedComponents: field.type == "date" ? [.date] : [.date, .hourAndMinute]
            )
        } else if field.type == "multiline" {
            Section(field.label) {
                TextEditor(text: textBinding(field))
                    .frame(minHeight: 100)
            }
        } else {
            TextField(field.placeholder ?? field.label, text: textBinding(field))
            #if os(iOS)
                .keyboardType(field.type == "number" ? .decimalPad : .default)
            #endif
        }
    }

    private func textBinding(_ field: PluginSurfaceEditorField) -> Binding<String> {
        Binding(
            get: { textValues[field.id] ?? "" },
            set: { textValues[field.id] = $0 }
        )
    }

    private var requiredFieldsAreValid: Bool {
        (context.editor.fields ?? []).allSatisfy { field in
            guard field.required else { return true }
            if ["text", "multiline", "number"].contains(field.type) {
                return !(textValues[field.id] ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
            }
            return true
        }
    }

    private func encodedValues() -> [String: PluginSurfaceEditorValue] {
        var values: [String: PluginSurfaceEditorValue] = [:]
        for field in context.editor.fields ?? [] {
            if field.type == "boolean" {
                values[field.id] = .boolean(booleanValues[field.id] ?? false)
            } else if field.type == "number" {
                let text = (textValues[field.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if let number = Double(text) {
                    values[field.id] = .number(number)
                }
            } else if field.type == "date" || field.type == "dateTime" {
                let date = dateValues[field.id] ?? Date()
                if field.type == "date" {
                    let formatter = DateFormatter()
                    formatter.locale = Locale(identifier: "en_US_POSIX")
                    formatter.calendar = Calendar(identifier: .gregorian)
                    formatter.dateFormat = "yyyy-MM-dd"
                    values[field.id] = .string(formatter.string(from: date))
                } else {
                    let formatter = ISO8601DateFormatter()
                    formatter.formatOptions = [.withInternetDateTime]
                    values[field.id] = .string(formatter.string(from: date))
                }
            } else {
                values[field.id] = .string(
                    (textValues[field.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
        }
        return values
    }

    @MainActor
    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await onSave(encodedValues())
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func delete() async {
        guard let onDelete else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await onDelete()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct CalendarEventEditorContext: Identifiable {
    let id = UUID()
    let collectionId: String
    let item: PluginSurfaceItem?
    let defaultDate: Date
}

private struct CalendarEventDraft: Encodable {
    let title: String
    let startsAt: String
    let endsAt: String
    let allDay: Bool
    let location: String
    let notes: String
}

private struct CalendarEventEditor: View {
    @Environment(\.dismiss) private var dismiss
    let context: CalendarEventEditorContext
    let onSave: (CalendarEventDraft) async throws -> Void
    let onDelete: (() async throws -> Void)?

    @State private var title: String
    @State private var startsAt: Date
    @State private var endsAt: Date
    @State private var allDay: Bool
    @State private var location: String
    @State private var notes: String
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showDeleteConfirmation = false

    init(
        context: CalendarEventEditorContext,
        onSave: @escaping (CalendarEventDraft) async throws -> Void,
        onDelete: (() async throws -> Void)?
    ) {
        self.context = context
        self.onSave = onSave
        self.onDelete = onDelete
        let item = context.item
        let start = parsePluginSurfaceDate(item?.temporal?.startsAt) ?? context.defaultDate
        let end = parsePluginSurfaceDate(item?.temporal?.endsAt)
            ?? Calendar.autoupdatingCurrent.date(byAdding: .hour, value: 1, to: start)
            ?? start
        _title = State(initialValue: item?.title ?? "")
        _startsAt = State(initialValue: start)
        _endsAt = State(initialValue: end)
        _allDay = State(initialValue: item?.temporal?.allDay ?? false)
        _location = State(initialValue: item?.tags.first ?? "")
        _notes = State(initialValue: item?.body ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("일정") {
                    TextField("제목", text: $title)
                    TextField("장소", text: $location)
                }

                Section("시간") {
                    Toggle("종일", isOn: $allDay)
                    if allDay {
                        DatePicker("시작", selection: $startsAt, displayedComponents: .date)
                        DatePicker("종료", selection: $endsAt, in: startsAt..., displayedComponents: .date)
                    } else {
                        DatePicker(
                            "시작",
                            selection: $startsAt,
                            displayedComponents: [.date, .hourAndMinute]
                        )
                        DatePicker(
                            "종료",
                            selection: $endsAt,
                            in: startsAt...,
                            displayedComponents: [.date, .hourAndMinute]
                        )
                    }
                }

                Section("메모") {
                    TextEditor(text: $notes)
                        .frame(minHeight: 100)
                }

                if onDelete != nil {
                    Section {
                        Button("일정 삭제", role: .destructive) {
                            showDeleteConfirmation = true
                        }
                        .disabled(isSaving)
                    }
                }
            }
            .navigationTitle(context.item == nil ? "새 일정" : "일정 편집")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장") {
                        Task { await save() }
                    }
                    .disabled(isSaving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .overlay {
                if isSaving {
                    ProgressView()
                        .padding(18)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .alert(
                "일정을 저장하지 못했습니다.",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("확인", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .confirmationDialog(
                "이 일정을 삭제할까요?",
                isPresented: $showDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("삭제", role: .destructive) {
                    Task { await delete() }
                }
                Button("취소", role: .cancel) {}
            }
        }
        #if os(macOS)
        .frame(width: 480, height: 590)
        #endif
        .onChange(of: startsAt) {
            if endsAt < startsAt {
                endsAt = startsAt
            }
        }
    }

    @MainActor
    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await onSave(makeDraft())
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func delete() async {
        guard let onDelete else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await onDelete()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func makeDraft() -> CalendarEventDraft {
        CalendarEventDraft(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            startsAt: encodeCalendarDate(startsAt, allDay: allDay),
            endsAt: encodeCalendarDate(endsAt, allDay: allDay),
            allDay: allDay,
            location: location.trimmingCharacters(in: .whitespacesAndNewlines),
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func encodeCalendarDate(_ date: Date, allDay: Bool) -> String {
        if allDay {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.string(from: date)
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

private func parsePluginSurfaceDate(_ value: String?) -> Date? {
    guard let value, !value.isEmpty else { return nil }
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = iso.date(from: value) { return date }
    iso.formatOptions = [.withInternetDateTime]
    if let date = iso.date(from: value) { return date }
    let day = DateFormatter()
    day.locale = Locale(identifier: "en_US_POSIX")
    day.calendar = Calendar(identifier: .gregorian)
    day.dateFormat = "yyyy-MM-dd"
    return day.date(from: value)
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

enum SettingsSection: String, CaseIterable, Identifiable {
    case connection = "Connection"
    case model = "Model"
    case modelConfig = "Model Config"
    case search = "Search"
    case mcp = "MCP"
    case plugins = "Marketplace"
    case runtimePlugins = "Plugins"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .connection: "network"
        case .model: "cube"
        case .modelConfig: "key"
        case .search: "magnifyingglass"
        case .mcp: "point.3.connected.trianglepath.dotted"
        case .plugins: "shippingbox"
        case .runtimePlugins: "puzzlepiece.extension"
        }
    }

    var subtitle: String {
        switch self {
        case .connection: "Server URL and token"
        case .model: "Choose provider and model"
        case .modelConfig: "Provider auth and endpoints"
        case .search: "Indexing and document search"
        case .mcp: "External MCP tools"
        case .plugins: "Discover and update community plugins"
        case .runtimePlugins: "Built-in and installed plugins"
        }
    }
}

struct WorkspaceSettingsView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @Binding var isPresented: Bool
    let initialSurfaceId: String?
    @State private var selectedSection: SettingsSection

    init(
        isPresented: Binding<Bool>,
        initialSection: SettingsSection = .model,
        initialSurfaceId: String? = nil
    ) {
        _isPresented = isPresented
        self.initialSurfaceId = initialSurfaceId
        _selectedSection = State(initialValue: initialSection)
    }

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
                case .plugins:
                    MarketplaceSettingsView()
                case .runtimePlugins:
                    PluginSettingsView(initialViewId: initialSurfaceId)
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
    @State private var transport = "stdio"
    @State private var argsText = ""
    @State private var scopePath = ""
    @State private var envText = ""
    @State private var url = ""
    @State private var credentialId = ""
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

                Picker("Transport", selection: $transport) {
                    Text("Local process (stdio)").tag("stdio")
                    Text("Remote HTTPS").tag("streamable_http")
                }
                .pickerStyle(.segmented)

                if transport == "stdio" {
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

                } else {
                    TextField("HTTPS MCP URL", text: $url)
                        .textFieldStyle(.roundedBorder)
                    TextField("Credential ID", text: $credentialId)
                        .textFieldStyle(.roundedBorder)
                    Text("The bearer token is server-only. Provision it with `codmes mcp credential set <id>`; it is never sent to this device.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if transport == "stdio" {
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
                }

                Toggle("Enabled", isOn: $enabled)

                HStack {
                    Button {
                        Task {
                            await store.saveMCPServer(
                                name: name,
                                transport: transport,
                                command: command,
                                argsText: argsText,
                                envText: envText,
                                scopePath: scopePath,
                                url: url,
                                credentialId: credentialId,
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
                if server.isRemote {
                    Text("\(server.url ?? "") · credential: \(server.credentialConfigured == true ? "configured" : "not configured")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else {
                    Text("\(server.command ?? "") \(server.argsText)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
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
        transport = server.transport ?? "stdio"
        command = server.command ?? ""
        argsText = server.argsText
        scopePath = server.scopePath ?? ""
        envText = server.envText
        url = server.url ?? ""
        credentialId = server.credentialId ?? ""
        enabled = server.isEnabled
    }

    private func clearEditor() {
        editingName = nil
        name = "custom-tool"
        command = ""
        transport = "stdio"
        argsText = ""
        scopePath = ""
        envText = ""
        url = ""
        credentialId = ""
        enabled = true
    }

}

private enum MarketplaceFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case featured = "Featured"
    case installed = "Installed"
    case updates = "Updates"

    var id: String { rawValue }
}

private struct MarketplaceSettingsView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @State private var pendingRemoval: MarketplacePlugin?
    @State private var pendingPermissionUpdate: MarketplacePlugin?
    @State private var selectedPlugin: MarketplacePlugin?
    @State private var searchText = ""
    @State private var selectedFilter: MarketplaceFilter = .all
    @State private var selectedCategory = "All"

    private var categories: [String] {
        let values = Set(
            store.marketplacePlugins
                .map(\.category)
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        )
        return ["All"] + values.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    private var filteredPlugins: [MarketplacePlugin] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.marketplacePlugins.filter { plugin in
            let matchesSearch = query.isEmpty || [
                plugin.name,
                plugin.description,
                plugin.publisher,
                plugin.category
            ].contains {
                $0.localizedCaseInsensitiveContains(query)
            }
            let matchesCategory = selectedCategory == "All" || plugin.category == selectedCategory
            let matchesFilter: Bool = switch selectedFilter {
            case .all:
                true
            case .featured:
                plugin.featured
            case .installed:
                plugin.installed
            case .updates:
                plugin.updateAvailable || plugin.installedVersionBlocked
            }
            return matchesSearch && matchesCategory && matchesFilter
        }
        .sorted {
            if $0.featured != $1.featured { return $0.featured && !$1.featured }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Plugin Marketplace")
                        .font(.headline)
                    Text("Install once on the Workspace server. Connected Mac, iPhone, and iPad clients use the same plugin.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await store.refreshMarketplace() }
                } label: {
                    if store.isMarketplaceLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.plain)
                .disabled(store.isMarketplaceLoading)
                .help("Refresh Marketplace")
            }

            if !store.isMarketplaceLoading || !store.marketplacePlugins.isEmpty {
                marketplaceSummary
            }
            marketplaceFilters

            if !store.marketplaceMessage.isEmpty {
                Label(store.marketplaceMessage, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if store.isMarketplaceLoading && store.marketplacePlugins.isEmpty {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Loading Marketplace…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 44)
            } else if store.marketplacePlugins.isEmpty {
                ContentUnavailableView {
                    Label("No plugins available", systemImage: "shippingbox")
                } description: {
                    Text("Check the Marketplace registry and Workspace server connection.")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
            } else if filteredPlugins.isEmpty {
                ContentUnavailableView {
                    Label("No matching plugins", systemImage: "magnifyingglass")
                } description: {
                    Text("Try changing the search, category, or installation filter.")
                } actions: {
                    Button("Clear Filters") {
                        searchText = ""
                        selectedFilter = .all
                        selectedCategory = "All"
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(filteredPlugins) { plugin in
                        pluginCard(plugin)
                    }
                }
            }
        }
        .task {
            await store.refreshMarketplace()
        }
        .confirmationDialog(
            "Remove \(pendingRemoval?.name ?? "plugin")?",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let plugin = pendingRemoval {
                Button("Remove Plugin", role: .destructive) {
                    pendingRemoval = nil
                    Task { await store.removeMarketplacePlugin(plugin) }
                }
            }
            Button("Cancel", role: .cancel) {
                pendingRemoval = nil
            }
        } message: {
            Text("Plugin views, tools, and MCP registration will be removed. Saved credentials and service data are kept.")
        }
        .confirmationDialog(
            "Allow new permissions for \(pendingPermissionUpdate?.name ?? "plugin")?",
            isPresented: Binding(
                get: { pendingPermissionUpdate != nil },
                set: { if !$0 { pendingPermissionUpdate = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let plugin = pendingPermissionUpdate {
                Button("Allow and Update") {
                    pendingPermissionUpdate = nil
                    Task {
                        await store.updateMarketplacePlugin(
                            plugin,
                            acceptedPermissions: plugin.addedPermissions
                        )
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                pendingPermissionUpdate = nil
            }
        } message: {
            if let plugin = pendingPermissionUpdate {
                Text(permissionConsentMessage(plugin))
            }
        }
        .sheet(item: $selectedPlugin) { plugin in
            MarketplacePluginDetailView(plugin: plugin)
        }
        .onChange(of: categories) {
            if !categories.contains(selectedCategory) {
                selectedCategory = "All"
            }
        }
    }

    private var marketplaceSummary: some View {
        HStack(spacing: 8) {
            marketplaceSummaryItem(
                "\(store.marketplacePlugins.count)",
                label: "Available",
                systemImage: "shippingbox"
            )
            marketplaceSummaryItem(
                "\(store.marketplacePlugins.filter(\.installed).count)",
                label: "Installed",
                systemImage: "checkmark.circle"
            )
            marketplaceSummaryItem(
                "\(store.marketplacePlugins.filter(\.updateAvailable).count)",
                label: "Updates",
                systemImage: "arrow.down.circle"
            )
        }
    }

    private func marketplaceSummaryItem(
        _ value: String,
        label: String,
        systemImage: String
    ) -> some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text(value)
                    .font(.callout.weight(.semibold).monospacedDigit())
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 9)
        .padding(.horizontal, 10)
        .background(.quaternary.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
    }

    private var marketplaceFilters: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search plugins", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .background(.quaternary.opacity(0.14), in: RoundedRectangle(cornerRadius: 9))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(MarketplaceFilter.allCases) { filter in
                        marketplaceFilterButton(
                            filter.rawValue,
                            selected: selectedFilter == filter
                        ) {
                            selectedFilter = filter
                        }
                    }

                    Divider()
                        .frame(height: 20)

                    ForEach(categories, id: \.self) { category in
                        marketplaceFilterButton(
                            category == "All" ? "All Categories" : category,
                            selected: selectedCategory == category
                        ) {
                            selectedCategory = category
                        }
                    }
                }
            }
        }
    }

    private func marketplaceFilterButton(
        _ title: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(selected ? .semibold : .regular))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    selected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.09),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
    }

    private func pluginCard(_ plugin: MarketplacePlugin) -> some View {
        let isWorking = store.marketplaceOperations.contains(plugin.id)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: plugin.systemImage)
                    .font(.title2)
                    .frame(width: 34, height: 34)
                    .background(.quaternary.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(plugin.name)
                            .font(.callout.weight(.semibold))
                        if plugin.featured {
                            Text("Featured")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.orange.opacity(0.12), in: Capsule())
                        }
                        if plugin.verified {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.caption)
                                .foregroundStyle(.blue)
                                .help("Verified publisher")
                        }
                    }
                    Text("\(plugin.publisher) · \(plugin.category)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if !plugin.description.isEmpty {
                        Text(plugin.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if plugin.installedVersionBlocked {
                        Label(
                            plugin.installedBlockReason ?? "The installed version is blocked.",
                            systemImage: "exclamationmark.shield.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(.red)
                    } else if plugin.blocked {
                        Label(
                            plugin.blockReason ?? "This version is blocked.",
                            systemImage: "exclamationmark.shield"
                        )
                        .font(.caption)
                        .foregroundStyle(.red)
                    } else if plugin.updateAvailable, !plugin.releaseNotes.isEmpty {
                        Text("What’s new: \(plugin.releaseNotes)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if plugin.previousVersion != nil,
                       !plugin.canRollback,
                       let rollbackBlockedReason = plugin.rollbackBlockedReason {
                        Label(rollbackBlockedReason, systemImage: "arrow.uturn.backward.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !plugin.supportsCurrentPlatform {
                        Label("Not supported on this device", systemImage: "laptopcomputer.slash")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 8)

                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button {
                        selectedPlugin = plugin
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("View \(plugin.name) details")
                }
            }

            HStack(spacing: 8) {
                Text("Latest v\(plugin.version)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                if plugin.installed, let installedVersion = plugin.installedVersion {
                    Text("Installed v\(installedVersion)")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(plugin.updateAvailable ? .orange : .green)
                }
                Spacer()
                pluginActions(plugin, isWorking: isWorking)
            }
        }
        .padding(13)
        .background(.quaternary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func pluginActions(_ plugin: MarketplacePlugin, isWorking: Bool) -> some View {
        if plugin.installed {
            if plugin.canRollback {
                Button("Rollback to v\(plugin.previousVersion ?? "")") {
                    Task { await store.rollbackMarketplacePlugin(plugin) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isWorking)
            }
            if plugin.updateAvailable {
                Button("Update") {
                    if plugin.permissionChangeRequired {
                        pendingPermissionUpdate = plugin
                    } else {
                        Task { await store.updateMarketplacePlugin(plugin) }
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isWorking || plugin.blocked)
            }
            Button(role: .destructive) {
                pendingRemoval = plugin
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isWorking)
            .help("Remove \(plugin.name)")
        } else {
            Button("Install") {
                Task { await store.installMarketplacePlugin(plugin) }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(isWorking || plugin.blocked)
        }
    }

    private func permissionConsentMessage(_ plugin: MarketplacePlugin) -> String {
        let permissions = plugin.addedPermissions.map { "• \($0)" }.joined(separator: "\n")
        let notes = plugin.releaseNotes.isEmpty ? "" : "\n\nWhat’s new\n\(plugin.releaseNotes)"
        return "This update requests additional access:\n\(permissions)\(notes)"
    }
}

private struct MarketplacePluginDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let plugin: MarketplacePlugin

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: plugin.systemImage)
                            .font(.largeTitle)
                            .frame(width: 54, height: 54)
                            .background(.quaternary.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(plugin.name)
                                    .font(.title2.weight(.semibold))
                                if plugin.verified {
                                    Image(systemName: "checkmark.seal.fill")
                                        .foregroundStyle(.blue)
                                }
                            }
                            Text(plugin.publisher)
                                .foregroundStyle(.secondary)
                            Text("Version \(plugin.version) · \(plugin.category)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if !plugin.description.isEmpty {
                        Text(plugin.description)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    detailSection("Compatibility") {
                        Label(plugin.platforms.joined(separator: ", "), systemImage: "laptopcomputer.and.iphone")
                        Label((plugin.formFactors ?? []).joined(separator: ", "), systemImage: "rectangle.3.group")
                        Label(plugin.installed ? "Installed" : "Not installed", systemImage: plugin.installed ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(plugin.installed ? .green : .secondary)
                        if let installedVersion = plugin.installedVersion {
                            Text("Installed version \(installedVersion)")
                        }
                    }

                    detailSection("Permissions") {
                        if plugin.permissions.isEmpty {
                            Text("No additional permissions")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(plugin.permissions, id: \.self) { permission in
                                Label(permission, systemImage: "checkmark.shield")
                            }
                        }
                    }

                    if !plugin.releaseNotes.isEmpty {
                        detailSection("What’s New") {
                            Text(plugin.releaseNotes)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if plugin.repositoryUrl != nil || plugin.privacyUrl != nil {
                        detailSection("Links") {
                            if let repositoryUrl = plugin.repositoryUrl,
                               let url = URL(string: repositoryUrl) {
                                Link("Source Repository", destination: url)
                            }
                            if let privacyUrl = plugin.privacyUrl,
                               let url = URL(string: privacyUrl) {
                                Link("Privacy Policy", destination: url)
                            }
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .navigationTitle("Plugin Details")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 500, minHeight: 520)
        #endif
    }

    private func detailSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.headline)
            VStack(alignment: .leading, spacing: 7) {
                content()
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.quaternary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

private struct PluginSettingsView: View {
    @EnvironmentObject private var store: WorkspaceStore
    let initialViewId: String?
    @State private var selectedPluginId: String?

    init(initialViewId: String? = nil) {
        self.initialViewId = initialViewId
    }

    private var selectedPlugin: RuntimePlugin? {
        guard let selectedPluginId else { return nil }
        return store.runtimePlugins.first { $0.id == selectedPluginId }
    }

    var body: some View {
        Group {
            if selectedPlugin != nil {
                pluginDetail
            } else {
                pluginOverview
            }
        }
        .task {
            await store.refreshPlugins()
            if let initialViewId,
               let plugin = store.runtimePlugins.first(where: {
                   $0.views.contains(where: { $0.id == initialViewId })
               }) {
                selectedPluginId = plugin.id
            } else if selectedPlugin == nil {
                selectedPluginId = nil
            }
        }
        .task(id: selectedPluginId) {
            guard let plugin = selectedPlugin,
                  let pluginId = plugin.views.first?.pluginId else {
                return
            }
            await store.refreshPluginAuthStatus(pluginId: pluginId)
        }
    }

    private var pluginOverview: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Plugins")
                        .font(.headline)
                    Text("Built-in and Marketplace plugins use the same runtime, views, tools, storage, and settings contract.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await store.refreshPlugins() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
            }

            pluginList

            if !store.pluginSetupMessage.isEmpty {
                Text(store.pluginSetupMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var pluginList: some View {
        VStack(spacing: 4) {
            ForEach(store.runtimePlugins) { plugin in
                pluginRow(plugin)
            }
        }
    }

    private func pluginRow(_ plugin: RuntimePlugin) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: plugin.systemImage)
                    .frame(width: 20)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(plugin.name)
                        .font(.callout.weight(.medium))
                    Text(plugin.builtIn ? "Built-in Plugin" : "Community Plugin")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if !plugin.supportsCurrentPlatform {
                        Text("Not supported on this device")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }

            Toggle("", isOn: Binding(
                get: { plugin.enabled },
                set: { enabled in
                    Task { await store.setPluginEnabled(plugin, enabled: enabled) }
                }
            ))
            .labelsHidden()
            .controlSize(.small)
            .disabled(plugin.id == "com.codmes.chat")

            Button {
                selectedPluginId = plugin.id
            } label: {
                Image(systemName: "gearshape")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Configure \(plugin.name)")
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 9)
        .background(.quaternary.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var pluginDetail: some View {
        if let plugin = selectedPlugin {
            let primaryView = plugin.views.first
            let primaryAuthStatus = store.pluginAuthStatus(for: primaryView?.pluginId)
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    HStack(spacing: 10) {
                        Image(systemName: plugin.systemImage)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(plugin.name)
                                .font(.headline)
                            Text(plugin.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button {
                        selectedPluginId = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.callout.weight(.semibold))
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Close plugin settings")
                }

                HStack {
                    Label(
                        plugin.enabled ? "Enabled" : "Disabled",
                        systemImage: plugin.enabled ? "checkmark.circle.fill" : "circle"
                    )
                    .font(.caption)
                    .foregroundStyle(plugin.enabled ? .green : .secondary)
                    Spacer()
                    Text(plugin.builtIn ? "Built-in" : "Community")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 14) {
                    if let primaryView,
                       primaryView.hasAuthentication == true,
                       primaryView.pluginId != nil {
                        PluginAuthenticationSettingsView(surface: primaryView)
                    } else {
                        ContentUnavailableView {
                            Label("Plugin settings", systemImage: "gearshape")
                        } description: {
                            if plugin.builtIn {
                                Text("\(plugin.name)의 개별 설정은 아직 없습니다. 향후 built-in plugin 설정이 이 화면에 추가됩니다.")
                            } else {
                                Text("이 플러그인은 별도의 사용자 설정을 제공하지 않습니다.")
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                    }
                }
                .padding(14)
                .background(.quaternary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))

                if let primaryView,
                   let navigation = primaryView.navigation,
                   !navigation.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Plugin views")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(navigation) { item in
                            HStack(spacing: 8) {
                                Image(systemName: item.systemImage)
                                    .frame(width: 18)
                                Text(item.title)
                                Spacer()
                                if item.requiresAuth == true {
                                    Image(
                                        systemName: primaryAuthStatus?.authenticated == true
                                            ? "checkmark.circle.fill"
                                            : "lock"
                                    )
                                        .font(.caption2)
                                        .foregroundStyle(
                                            primaryAuthStatus?.authenticated == true
                                                ? .green
                                                : .secondary
                                        )
                                }
                            }
                            .font(.caption)
                        }
                    }
                    .padding(10)
                    .background(.quaternary.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        } else {
            EmptyView()
        }
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
