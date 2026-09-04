import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import WebKit
#elseif os(iOS)
import WebKit
#endif
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

struct ChatHomeView: View {
    @EnvironmentObject private var store: WorkspaceStore
    var compact = false
    var showsHeader = true
    var showsSessionToolbar = true
    var onOpenModelSettings: (() -> Void)? = nil
    @State private var draft = ""
    @State private var showingSessionManager = false
    @State private var showingCreateGroupFolder = false
    @State private var pendingDeleteGroupFolder: ConversationFolder?
    @State private var newGroupFolderName = ""
    @FocusState private var isDraftFocused: Bool
    @State private var isAtBottom = true
    @State private var isScrollingToBottom = false

    var body: some View {
        VStack(spacing: 0) {
            if showsHeader {
                chatHeader
            }
            if showsSessionToolbar {
                sessionToolbar
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 14) {
                        ForEach(store.chatLines) { line in
                            MessageBubble(line: line) { approved in
                                Task { await store.respondToApproval(lineId: line.id, approved: approved) }
                            }
                            .id(line.id)
                        }
                        
                        Color.clear
                            .frame(height: 1)
                            .id("bottom-anchor")
                            .onAppear {
                                isAtBottom = true
                            }
                            .onDisappear {
                                if !isScrollingToBottom {
                                    isAtBottom = false
                                }
                            }
                    }
                    .padding(compact ? 14 : 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: store.chatLines) {
                    if isAtBottom {
                        isScrollingToBottom = true
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo("bottom-anchor", anchor: .bottom)
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            isScrollingToBottom = false
                        }
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .contentShape(Rectangle())
            .onTapGesture {
                isDraftFocused = false
            }
            Divider()
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    Picker("Context", selection: $store.chatContextScope) {
                        ForEach(ChatContextScope.allCases) { scope in
                            Label(scope.label, systemImage: scope.systemImage)
                                .tag(scope)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()

                    Text(store.chatContextLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer()
                }

                VStack(spacing: 8) {
                    TextField("Message Codmes...", text: $draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...(compact ? 3 : 4))
                        .focused($isDraftFocused)
                        .onSubmit(sendDraft)

                    HStack(spacing: 12) {
                        Menu {
                            ForEach(ChatContextScope.allCases) { scope in
                                Button(scope.label) {
                                    store.chatContextScope = scope
                                }
                            }
                        } label: {
                            Text("@")
                                .font(.headline.weight(.semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)

                        Spacer(minLength: 8)

                        chatControlMenu(
                            title: store.chatAccessMode.label,
                            width: 48,
                            options: ChatAccessMode.allCases.map { ($0.label, $0) }
                        ) { mode in
                            store.chatAccessMode = mode
                            Task { await store.applyAccessModeToLiveSession() }
                        }

                        modelMenu

                        chatControlMenu(
                            title: store.chatReasoningMode.label,
                            width: 44,
                            options: ChatReasoningMode.allCases.map { ($0.label, $0) }
                        ) { mode in
                            store.chatReasoningMode = mode
                            Task { await store.applyReasoningModeToLiveSession() }
                        }

                        Button {
                            sendDraft()
                        } label: {
                            Image(systemName: "paperplane.fill")
                        }
                        .buttonStyle(.plain)
                        .font(.title3)
                        .foregroundStyle(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .tertiary : .primary)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding(compact ? 9 : 10)
                .background(.quaternary.opacity(0.34), in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.quaternary.opacity(0.70), lineWidth: 1)
                )
            }
            .padding(compact ? 12 : 16)
            .background(.background.opacity(0.96))
        }
        .sheet(isPresented: $showingSessionManager) {
            SessionManagerView(isPresented: $showingSessionManager)
                .environmentObject(store)
        }
        .confirmationDialog(
            "Delete group folder?",
            isPresented: Binding(
                get: { pendingDeleteGroupFolder != nil },
                set: { if !$0 { pendingDeleteGroupFolder = nil } }
            ),
            presenting: pendingDeleteGroupFolder
        ) { folder in
            Button("Delete \(folder.name)", role: .destructive) {
                Task {
                    await store.deleteConversationFolder(folder)
                    pendingDeleteGroupFolder = nil
                }
            }
            Button("Cancel", role: .cancel) {
                pendingDeleteGroupFolder = nil
            }
        } message: { folder in
            Text("Sessions in \(folder.name) will be kept and moved out of the group.")
        }
    }

    private var chatHeader: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Codmes Chat")
                    .font(compact ? .headline.weight(.semibold) : .title2.weight(.semibold))
                Text(store.workspace?.runtime?.status ?? "No runtime status loaded")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 10)
        }
        .padding(.horizontal, compact ? 14 : 20)
        .padding(.vertical, compact ? 10 : 14)
        .background(.quaternary.opacity(0.14))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(.quaternary.opacity(0.55))
                .frame(height: 1)
        }
    }

    private var sessionToolbar: some View {
        ViewThatFits(in: .horizontal) {
            sessionToolbarRow(compactLayout: usesCompactSessionToolbar)
            sessionToolbarRow(compactLayout: true)
        }
    }

    private func sessionToolbarRow(compactLayout: Bool) -> some View {
        HStack(spacing: 8) {
            Button {
                showingSessionManager = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                    if !compactLayout {
                        Text("History")
                    }
                }
                .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Search and manage sessions")

            Spacer(minLength: 8)

            Rectangle()
                .fill(.quaternary.opacity(0.75))
                .frame(width: 1, height: 22)

            projectMenu
                .frame(maxWidth: compactLayout ? 104 : 170, alignment: .trailing)

            sessionMenu
                .frame(maxWidth: compactLayout ? 126 : 230, alignment: .trailing)

            Button {
                store.prepareNewChat()
            } label: {
                Image(systemName: "plus")
                    .font(.headline.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .frame(width: 30, height: 30)
            .contentShape(Rectangle())
            .help("New chat")
        }
        .padding(.horizontal, compact ? 12 : 16)
        .padding(.vertical, 5)
        .background(.background.opacity(0.96))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(.quaternary.opacity(0.45))
                .frame(height: 1)
        }
    }

    private var usesCompactSessionToolbar: Bool {
        #if os(iOS)
        true
        #else
        compact
        #endif
    }

    private var projectMenu: some View {
        Menu {
            ForEach(store.hermesSessionProjects) { project in
                Button {
                    store.selectedHermesProjectId = project.id
                } label: {
                    HStack {
                        Text(project.title)
                        Text("(\(project.sessionCount))")
                    }
                }
            }
            Divider()
            Button {
                newGroupFolderName = ""
                showingCreateGroupFolder = true
            } label: {
                Label("New group folder...", systemImage: "folder.badge.plus")
            }
            if let folder = store.conversationFolders.first(where: { $0.id == store.selectedHermesProjectId }) {
                Divider()
                Button(role: .destructive) {
                    pendingDeleteGroupFolder = folder
                } label: {
                    Label("Delete selected group folder", systemImage: "trash")
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                Text(store.selectedHermesProjectTitle)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture().onEnded {
            Task { await store.refreshHermesMetadata() }
        })
        .help("Select project")
        .alert("New group folder", isPresented: $showingCreateGroupFolder) {
            TextField("Folder name", text: $newGroupFolderName)
            Button("Create") {
                Task { await store.createConversationFolder(name: newGroupFolderName) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Sessions inside this folder share folder-level memory.")
        }
    }

    private var modelMenu: some View {
        Menu {
            if store.visibleHermesModelGroups.isEmpty {
                Button("Default") {
                    store.selectedHermesModelId = ""
                }
            } else {
                ForEach(store.visibleHermesModelGroups) { group in
                    Section(group.title) {
                        ForEach(group.models) { model in
                            Button {
                                store.selectedHermesModelId = model.id
                            } label: {
                                HStack {
                                    Text(model.model)
                                    if store.selectedHermesModelId == model.id {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    }
                }
            }
            Divider()
            Button {
                onOpenModelSettings?()
            } label: {
                Label("Model Settings...", systemImage: "slider.horizontal.3")
            }
            Button {
                onOpenModelSettings?()
            } label: {
                Label("Choose Visible Models...", systemImage: "eye")
            }
        } label: {
            HStack(spacing: 4) {
                Text(store.selectedHermesModelShortLabel)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.caption2)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(width: compact ? 82 : 108, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .controlSize(.small)
    }

    private var sessionMenu: some View {
        Menu {
            if store.sessionsForSelectedHermesProject.isEmpty {
                Text("No sessions loaded")
            } else {
                ForEach(store.sessionsForSelectedHermesProject) { session in
                    Button {
                        Task { await store.resumeHermesSession(session) }
                    } label: {
                        VStack(alignment: .leading) {
                            Text(session.title)
                            if let updatedAt = session.updatedAt {
                                Text(updatedAt)
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "bubble.left")
                    .foregroundStyle(.secondary)
                Text(store.activeHermesSessionTitle == "No session" ? "Session: none" : store.activeHermesSessionTitle)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .simultaneousGesture(TapGesture().onEnded {
            Task { await store.refreshHermesMetadata() }
        })
        .help("Select session")
    }

    private func chatControlMenu<Value>(
        title: String,
        width: CGFloat,
        options: [(String, Value)],
        onSelect: @escaping (Value) -> Void
    ) -> some View {
        Menu {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                Button(option.0) {
                    onSelect(option.1)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(title)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Image(systemName: "chevron.down")
                    .font(.caption2)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(width: width, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .controlSize(.small)
    }

    private func sendDraft() {
        let message = draft
        draft = ""
        isDraftFocused = false
        isAtBottom = true
        Task { await store.sendChatMessage(message) }
    }
}

struct ChatNavigationSidebar: View {
    @EnvironmentObject private var store: WorkspaceStore
    var onOpenSession: (() -> Void)? = nil
    @State private var showingSessionManager = false
    @State private var showingCreateGroupFolder = false
    @State private var pendingDeleteGroupFolder: ConversationFolder?
    @State private var renamingProject: ConversationFolder?
    @State private var renameProjectName = ""
    @State private var newGroupFolderName = ""
    @State private var isSelectingSessions = false
    @State private var selectedSessionIds = Set<String>()
    @State private var pendingDeleteSession: HermesSessionSummary?
    @State private var renamingSession: HermesSessionSummary?
    @State private var renameSessionTitle = ""
    @State private var pendingBulkDelete = false
    @State private var targetedProjectId: String?
    @State private var isRecentDropTargeted = false
    @State private var hoveredSessionId: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Text("프로젝트")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button {
                        showingSessionManager = true
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Manage projects and chats")

                    Button {
                        newGroupFolderName = ""
                        showingCreateGroupFolder = true
                    } label: {
                        Image(systemName: "plus")
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Create project")
                }
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 8)

                if projects.isEmpty {
                    Text("프로젝트가 없습니다")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                } else {
                    ForEach(projects) { project in
                        projectSection(project)
                    }
                }

                recentHeader
                    .padding(.horizontal, 14)
                    .padding(.top, 22)
                    .padding(.bottom, 8)
                    .background(
                        isRecentDropTargeted
                            ? Color.accentColor.opacity(0.12)
                            : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                    .padding(.horizontal, 4)
                    .onDrop(
                        of: [.codmesChatSessions, .utf8PlainText],
                        isTargeted: $isRecentDropTargeted,
                        perform: { providers in
                            moveDroppedProviders(providers, to: nil)
                        }
                    )

                if recentSessions.isEmpty {
                    Text("프로젝트에 속하지 않은 최근 채팅이 없습니다")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                } else {
                    ForEach(recentSessions) { session in
                        sessionRow(session, indentation: 0)
                    }
                }
            }
            .padding(.bottom, 14)
        }
        .background(.background.opacity(0.96))
        .task {
            await store.refreshHermesMetadata()
        }
        .sheet(isPresented: $showingSessionManager) {
            SessionManagerView(isPresented: $showingSessionManager)
                .environmentObject(store)
        }
        .alert("New group folder", isPresented: $showingCreateGroupFolder) {
            TextField("Folder name", text: $newGroupFolderName)
            Button("Create") {
                Task { await store.createConversationFolder(name: newGroupFolderName) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Sessions inside this folder share folder-level memory.")
        }
        .alert(
            "프로젝트 이름 변경",
            isPresented: Binding(
                get: { renamingProject != nil },
                set: { if !$0 { renamingProject = nil } }
            )
        ) {
            TextField("프로젝트 이름", text: $renameProjectName)
            Button("변경") {
                guard let project = renamingProject else { return }
                Task {
                    await store.renameConversationFolder(project, name: renameProjectName)
                    renamingProject = nil
                }
            }
            Button("취소", role: .cancel) {
                renamingProject = nil
            }
        }
        .alert(
            "세션 이름 변경",
            isPresented: Binding(
                get: { renamingSession != nil },
                set: { if !$0 { renamingSession = nil } }
            )
        ) {
            TextField("세션 이름", text: $renameSessionTitle)
            Button("변경") {
                guard let session = renamingSession else { return }
                let title = renameSessionTitle
                renamingSession = nil
                Task { await store.renameHermesSession(session, title: title) }
            }
            Button("취소", role: .cancel) {
                renamingSession = nil
            }
        } message: {
            Text(renamingSession?.title ?? "")
        }
        .confirmationDialog(
            "Delete group folder?",
            isPresented: Binding(
                get: { pendingDeleteGroupFolder != nil },
                set: { if !$0 { pendingDeleteGroupFolder = nil } }
            ),
            presenting: pendingDeleteGroupFolder
        ) { folder in
            Button("Delete \(folder.name)", role: .destructive) {
                Task {
                    await store.deleteConversationFolder(folder)
                    pendingDeleteGroupFolder = nil
                }
            }
            Button("Cancel", role: .cancel) {
                pendingDeleteGroupFolder = nil
            }
        } message: { folder in
            Text("Sessions in \(folder.name) will be kept and moved out of the group.")
        }
        .confirmationDialog(
            "세션을 삭제할까요?",
            isPresented: Binding(
                get: { pendingDeleteSession != nil },
                set: { if !$0 { pendingDeleteSession = nil } }
            ),
            presenting: pendingDeleteSession
        ) { session in
            Button("삭제", role: .destructive) {
                Task {
                    await store.deleteHermesSession(session)
                    pendingDeleteSession = nil
                }
            }
            Button("취소", role: .cancel) {
                pendingDeleteSession = nil
            }
        } message: { session in
            Text(session.title)
        }
        .confirmationDialog(
            "선택한 세션을 삭제할까요?",
            isPresented: $pendingBulkDelete
        ) {
            Button("\(selectedSessionIds.count)개 삭제", role: .destructive) {
                let sessions = selectedSessions
                Task {
                    await store.deleteHermesSessions(sessions)
                    endSessionSelection()
                }
            }
            Button("취소", role: .cancel) {}
        }
    }

    private var recentHeader: some View {
        HStack(spacing: 5) {
            Text("최근")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.secondary)

            Spacer()

            if isSelectingSessions {
                Button {
                    if allSessionsSelected {
                        selectedSessionIds.removeAll()
                    } else {
                        selectedSessionIds = Set(store.hermesSessions.map(\.id))
                    }
                } label: {
                    Image(systemName: allSessionsSelected ? "checkmark.circle.fill" : "checkmark.circle")
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(allSessionsSelected ? "전체 선택 해제" : "전체 선택")

                Button {
                    pendingBulkDelete = true
                } label: {
                    Image(systemName: "trash")
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .foregroundStyle(selectedSessionIds.isEmpty ? .tertiary : .secondary)
                .disabled(selectedSessionIds.isEmpty)
                .help("선택한 세션 삭제")

                Button {
                    endSessionSelection()
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("선택 취소")
            } else {
                Button {
                    showingSessionManager = true
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("세션 히스토리")

                Button {
                    store.selectedHermesProjectId = "__all__"
                    store.prepareNewChat()
                } label: {
                    Image(systemName: "square.and.pencil")
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("새 세션")
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var projects: [HermesSessionProject] {
        store.hermesSessionProjects.filter { $0.id != "__all__" }
    }

    private var recentSessions: [HermesSessionSummary] {
        orderedSessions(store.hermesSessions.filter { session in
            let projectId = session.folderId ?? session.projectId ?? session.projectTitle
            return projectId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
        })
    }

    private var selectedSessions: [HermesSessionSummary] {
        store.hermesSessions.filter { selectedSessionIds.contains($0.id) }
    }

    private var allSessionsSelected: Bool {
        !store.hermesSessions.isEmpty
            && selectedSessionIds.count == store.hermesSessions.count
    }

    private func sessions(in project: HermesSessionProject) -> [HermesSessionSummary] {
        orderedSessions(store.hermesSessions.filter {
            ($0.folderId ?? $0.projectId ?? $0.projectTitle) == project.id
        })
    }

    private func orderedSessions(_ sessions: [HermesSessionSummary]) -> [HermesSessionSummary] {
        sessions.enumerated()
            .sorted {
                if $0.element.pinned != $1.element.pinned {
                    return $0.element.pinned && !$1.element.pinned
                }
                return $0.offset < $1.offset
            }
            .map(\.element)
    }

    @ViewBuilder
    private func projectSection(_ project: HermesSessionProject) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 9) {
                Image(systemName: "folder")
                    .frame(width: 18)

                Text(project.title)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 6)
            }
            .font(.headline.weight(.medium))
            .foregroundStyle(.primary)
            .contentShape(Rectangle())
            .onTapGesture {
                store.selectedHermesProjectId = project.id
            }

            Menu {
                Button {
                    store.selectedHermesProjectId = project.id
                    showingSessionManager = true
                } label: {
                    Label("프로젝트 관리", systemImage: "slider.horizontal.3")
                }

                if let folder = store.conversationFolders.first(where: { $0.id == project.id }) {
                    Divider()
                    Button {
                        renameProjectName = folder.name
                        renamingProject = folder
                    } label: {
                        Label("프로젝트 이름 변경", systemImage: "pencil")
                    }

                    Button(role: .destructive) {
                        pendingDeleteGroupFolder = folder
                    } label: {
                        Label("프로젝트 제거", systemImage: "trash")
                    }
                } else {
                    Divider()
                    Button("프로젝트 이름 변경") {}
                        .disabled(true)
                    Button("프로젝트 제거", role: .destructive) {}
                        .disabled(true)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 26, height: 28)
            }
            #if os(macOS)
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            #else
            .buttonStyle(.plain)
            #endif
            .foregroundStyle(.secondary)
            .help("Project actions")

            Button {
                store.selectedHermesProjectId = project.id
                store.prepareNewChat()
            } label: {
                Image(systemName: "square.and.pencil")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("New chat in \(project.title)")
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .frame(height: 38)
        .background(
            targetedProjectId == project.id
                ? Color.accentColor.opacity(0.14)
                : store.selectedHermesProjectId == project.id
                ? Color.secondary.opacity(0.12)
                : Color.clear,
            in: RoundedRectangle(cornerRadius: 8)
        )
        .padding(.horizontal, 4)
        .onDrop(
            of: [.codmesChatSessions, .utf8PlainText],
            isTargeted: projectDropTargetBinding(project.id),
            perform: { providers in
                moveDroppedProviders(providers, to: project)
            }
        )

        ForEach(sessions(in: project)) { session in
            sessionRow(session, indentation: 32)
        }
    }

    private func sessionRow(_ session: HermesSessionSummary, indentation: CGFloat) -> some View {
        HStack(spacing: 4) {
            HStack(spacing: 5) {
                if session.pinned {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Text(session.title)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 12 + indentation)
            .contentShape(Rectangle())
            .onTapGesture {
                if isSelectingSessions {
                    toggleSessionSelection(session)
                    return
                }
                if let projectId = session.folderId ?? session.projectId ?? session.projectTitle {
                    store.selectedHermesProjectId = projectId
                } else {
                    store.selectedHermesProjectId = "__all__"
                }
                Task {
                    await store.resumeHermesSession(session)
                    onOpenSession?()
                }
            }
            .accessibilityAddTraits(.isButton)
            .onDrag {
                dragProvider(for: session)
            } preview: {
                dragPreview(for: session)
            }

            #if os(macOS)
            if isSelectingSessions {
                Button {
                    toggleSessionSelection(session)
                } label: {
                    Image(
                        systemName: selectedSessionIds.contains(session.id)
                            ? "checkmark.circle.fill"
                            : "circle"
                    )
                    .frame(width: 25, height: 28)
                }
                .buttonStyle(.plain)
                .foregroundStyle(selectedSessionIds.contains(session.id) ? .primary : .tertiary)
                .help(selectedSessionIds.contains(session.id) ? "선택 해제" : "선택")
            } else {
                Menu {
                    sessionActionsMenu(for: session)
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 27, height: 28)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .foregroundStyle(.secondary)
                .opacity(hoveredSessionId == session.id ? 1 : 0)
                .help("세션 작업")
            }
            #else
            if isSelectingSessions {
                Button {
                    toggleSessionSelection(session)
                } label: {
                    Image(
                        systemName: selectedSessionIds.contains(session.id)
                            ? "checkmark.circle.fill"
                            : "circle"
                    )
                    .frame(width: 25, height: 28)
                }
                .buttonStyle(.plain)
                .foregroundStyle(selectedSessionIds.contains(session.id) ? .primary : .tertiary)
                .help(selectedSessionIds.contains(session.id) ? "선택 해제" : "선택")
            }
            #endif
        }
        .padding(.trailing, 7)
        .frame(maxWidth: .infinity)
        .frame(height: 34)
        .background(
            store.liveSessionId == session.id
                ? Color.secondary.opacity(0.18)
                : selectedSessionIds.contains(session.id)
                ? Color.secondary.opacity(0.12)
                : Color.clear,
            in: RoundedRectangle(cornerRadius: 8)
        )
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .help(session.title)
        #if os(macOS)
        .onHover { isHovering in
            if isHovering {
                hoveredSessionId = session.id
            } else if hoveredSessionId == session.id {
                hoveredSessionId = nil
            }
        }
        #endif
        .contextMenu {
            sessionActionsMenu(for: session)
        }
    }

    @ViewBuilder
    private func sessionActionsMenu(for session: HermesSessionSummary) -> some View {
        Button {
            Task { await store.setHermesSessionPinned(session, pinned: !session.pinned) }
        } label: {
            Label(
                session.pinned ? "고정 해제" : "고정",
                systemImage: session.pinned ? "pin.slash" : "pin"
            )
        }

        Button {
            isSelectingSessions = true
            selectedSessionIds.insert(session.id)
        } label: {
            Label("선택", systemImage: "checkmark.circle")
        }

        Button {
            renamingSession = session
            renameSessionTitle = session.title
        } label: {
            Label("이름 변경", systemImage: "pencil")
        }

        Divider()

        Button(role: .destructive) {
            pendingDeleteSession = session
        } label: {
            Label("삭제", systemImage: "trash")
        }
        .disabled(session.id == store.liveSessionId)
    }

    private func dragPreview(for session: HermesSessionSummary) -> some View {
        Label(
            dragPayload(for: session).sessionIds.count == 1
                ? session.title
                : "\(dragPayload(for: session).sessionIds.count)개 세션",
            systemImage: "bubble.left.and.bubble.right"
        )
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func toggleSessionSelection(_ session: HermesSessionSummary) {
        if selectedSessionIds.contains(session.id) {
            selectedSessionIds.remove(session.id)
        } else {
            selectedSessionIds.insert(session.id)
        }
    }

    private func endSessionSelection() {
        isSelectingSessions = false
        selectedSessionIds.removeAll()
    }

    private func dragPayload(for session: HermesSessionSummary) -> SessionSidebarDragPayload {
        let ids = isSelectingSessions && selectedSessionIds.contains(session.id)
            ? Array(selectedSessionIds)
            : [session.id]
        return SessionSidebarDragPayload(sessionIds: ids)
    }

    private func dragProvider(for session: HermesSessionSummary) -> NSItemProvider {
        let data = (try? JSONEncoder().encode(dragPayload(for: session))) ?? Data()
        let payload = String(data: data, encoding: .utf8) ?? ""
        let provider = NSItemProvider(object: payload as NSString)
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.codmesChatSessions.identifier,
            visibility: .all
        ) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }

    private func moveDroppedProviders(
        _ providers: [NSItemProvider],
        to project: HermesSessionProject?
    ) -> Bool {
        guard let provider = providers.first(where: { provider in
            provider.hasItemConformingToTypeIdentifier(UTType.codmesChatSessions.identifier)
                || provider.canLoadObject(ofClass: NSString.self)
        }) else {
            return false
        }

        let handleData: @Sendable (Data?) -> Void = { data in
            guard let data,
                  let dragPayload = try? JSONDecoder().decode(SessionSidebarDragPayload.self, from: data) else { return }
            Task { @MainActor in
                let ids = Set(dragPayload.sessionIds)
                let sessions = store.hermesSessions.filter { ids.contains($0.id) }
                guard !sessions.isEmpty else { return }
                let folderId = project.flatMap { destination in
                    store.conversationFolders.contains(where: { $0.id == destination.id })
                        ? destination.id
                        : nil
                }
                let codeProject = project.flatMap { destination in
                    folderId == nil ? destination : nil
                }
                await store.moveSessions(
                    sessions,
                    toFolderId: folderId,
                    projectId: codeProject?.id,
                    projectTitle: codeProject?.title
                )
                endSessionSelection()
            }
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.codmesChatSessions.identifier) {
            provider.loadDataRepresentation(
                forTypeIdentifier: UTType.codmesChatSessions.identifier
            ) { data, _ in
                handleData(data)
            }
        } else {
            provider.loadObject(ofClass: NSString.self) { object, _ in
                handleData((object as? String)?.data(using: .utf8))
            }
        }
        return true
    }

    private func projectDropTargetBinding(_ projectId: String) -> Binding<Bool> {
        Binding(
            get: { targetedProjectId == projectId },
            set: { isTargeted in
                if isTargeted {
                    targetedProjectId = projectId
                } else if targetedProjectId == projectId {
                    targetedProjectId = nil
                }
            }
        )
    }
}

private struct SessionSidebarDragPayload: Codable, Sendable {
    let sessionIds: [String]
}

private extension UTType {
    static let codmesChatSessions = UTType(exportedAs: "com.codmes.chat-sessions")
}

struct SessionManagerView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @Binding var isPresented: Bool
    var showsCloseButton = true
    @State private var pendingDelete: HermesSessionSummary?
    @State private var renamingSession: HermesSessionSummary?
    @State private var renameTitle = ""
    @State private var selectedSessionIds = Set<String>()
    @State private var pendingBulkDelete = false
    @State private var pendingDeleteGroupFolder: ConversationFolder?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("History")
                        .font(.title2.weight(.semibold))
                    Text("Search and manage sessions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await store.refreshHermesMetadata() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                if showsCloseButton {
                    Button {
                        isPresented = false
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                }
            }

            HStack(spacing: 16) {
                Label("Total \(store.chatHistoryStorageText)", systemImage: "internaldrive")
                Text("\(store.chatHistoryStorage.sessionCount) chats")
                Text("\(store.chatHistoryStorage.assetCount) saved images")
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.quaternary.opacity(0.16), in: RoundedRectangle(cornerRadius: 8))

            TextField("Search session title...", text: $store.sessionManagerSearch)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 8) {
                Label(store.selectedHermesProjectTitle, systemImage: "folder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(selectedVisibleSessions.count) selected")
                    .font(.caption)
                    .foregroundStyle(selectedVisibleSessions.isEmpty ? .tertiary : .secondary)
                Spacer()
                Button(allVisibleSelected ? "Deselect all" : "Select all") {
                    if allVisibleSelected {
                        selectedSessionIds.subtract(visibleDeletableSessionIds)
                    } else {
                        selectedSessionIds.formUnion(visibleDeletableSessionIds)
                    }
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .disabled(visibleDeletableSessionIds.isEmpty)

                Button(role: .destructive) {
                    pendingBulkDelete = true
                } label: {
                    Label("Delete selected", systemImage: "trash")
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .disabled(selectedVisibleSessions.isEmpty)

                if let folder = store.conversationFolders.first(where: { $0.id == store.selectedHermesProjectId }) {
                    Button(role: .destructive) {
                        pendingDeleteGroupFolder = folder
                    } label: {
                        Label("Delete folder only", systemImage: "trash")
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }

            if store.filteredSessionsForSelectedHermesProject.isEmpty {
                ContentUnavailableView("No sessions", systemImage: "clock", description: Text("No saved sessions match this search."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(store.filteredSessionsForSelectedHermesProject) { session in
                    HStack(spacing: 12) {
                        Button {
                            toggleSessionSelection(session)
                        } label: {
                            Image(systemName: selectedSessionIds.contains(session.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selectedSessionIds.contains(session.id) ? .primary : .tertiary)
                        }
                        .buttonStyle(.plain)
                        .disabled(session.id == store.liveSessionId)
                        .help(session.id == store.liveSessionId ? "Active session cannot be selected for deletion" : "Select session")

                        Button {
                            Task {
                                await store.resumeHermesSession(session)
                                isPresented = false
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(session.title)
                                    .lineLimit(1)
                                if let updatedAt = session.updatedAt {
                                    Text(updatedAt)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Text(ByteCountFormatter.string(fromByteCount: session.storageBytes, countStyle: .file))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                if let projectTitle = session.projectTitle {
                                    Label(projectTitle, systemImage: "folder")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                }
                                if let folderTitle = session.folderTitle {
                                    Label(folderTitle, systemImage: "folder.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)

                        Menu {
                            Button {
                                Task { await store.moveSession(session, toFolderId: nil) }
                            } label: {
                                Label("No folder", systemImage: "tray")
                            }
                            if !store.conversationFolders.isEmpty {
                                Divider()
                                ForEach(store.conversationFolders) { folder in
                                    Button {
                                        Task { await store.moveSession(session, toFolderId: folder.id) }
                                    } label: {
                                        Label(folder.name, systemImage: "folder")
                                    }
                                }
                            }
                        } label: {
                            Image(systemName: "folder")
                        }
                        .buttonStyle(.borderless)
                        .help("Move session to group folder")

                        Button {
                            renamingSession = session
                            renameTitle = session.title
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .buttonStyle(.borderless)
                        .help("Rename session")

                        Button(role: .destructive) {
                            pendingDelete = session
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .disabled(session.id == store.liveSessionId)
                        .help(session.id == store.liveSessionId ? "Cannot delete the active session" : "Delete session")
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(20)
        .frame(idealWidth: 520, idealHeight: 460)
        .task {
            await store.refreshHermesMetadata()
        }
        .alert("Rename session", isPresented: renameBinding) {
            TextField("Session title", text: $renameTitle)
            Button("Rename") {
                let session = renamingSession
                let title = renameTitle
                renamingSession = nil
                if let session {
                    Task { await store.renameHermesSession(session, title: title) }
                }
            }
            Button("Cancel", role: .cancel) {
                renamingSession = nil
            }
        } message: {
            Text(renamingSession?.id ?? "")
        }
        .confirmationDialog(
            "Delete this session?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { session in
            Button("Delete \(session.title)", role: .destructive) {
                Task {
                    await store.deleteHermesSession(session)
                    pendingDelete = nil
                }
            }
            Button("Cancel", role: .cancel) {
                pendingDelete = nil
            }
        } message: { session in
            Text("This deletes the saved session, not just the local row: \(session.title)")
        }
        .confirmationDialog(
            "Delete selected sessions?",
            isPresented: $pendingBulkDelete,
            titleVisibility: .visible
        ) {
            Button("Delete \(selectedVisibleSessions.count) sessions", role: .destructive) {
                let sessions = selectedVisibleSessions
                selectedSessionIds.subtract(sessions.map(\.id))
                Task { await store.deleteHermesSessions(sessions) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes the selected saved sessions. The active session is never included.")
        }
        .confirmationDialog(
            "Delete group folder?",
            isPresented: Binding(
                get: { pendingDeleteGroupFolder != nil },
                set: { if !$0 { pendingDeleteGroupFolder = nil } }
            ),
            presenting: pendingDeleteGroupFolder
        ) { folder in
            Button("Delete folder only", role: .destructive) {
                Task {
                    await store.deleteConversationFolder(folder)
                    pendingDeleteGroupFolder = nil
                }
            }
            Button("Cancel", role: .cancel) {
                pendingDeleteGroupFolder = nil
            }
        } message: { folder in
            Text("Sessions in \(folder.name) will be kept and moved out of the group.")
        }
        .onChange(of: store.filteredSessionsForSelectedHermesProject) {
            selectedSessionIds.formIntersection(Set(store.filteredSessionsForSelectedHermesProject.map(\.id)))
        }
    }

    private var renameBinding: Binding<Bool> {
        Binding(
            get: { renamingSession != nil },
            set: { if !$0 { renamingSession = nil } }
        )
    }

    private var visibleDeletableSessions: [HermesSessionSummary] {
        store.filteredSessionsForSelectedHermesProject.filter { $0.id != store.liveSessionId }
    }

    private var visibleDeletableSessionIds: Set<String> {
        Set(visibleDeletableSessions.map(\.id))
    }

    private var selectedVisibleSessions: [HermesSessionSummary] {
        visibleDeletableSessions.filter { selectedSessionIds.contains($0.id) }
    }

    private var allVisibleSelected: Bool {
        !visibleDeletableSessionIds.isEmpty && visibleDeletableSessionIds.isSubset(of: selectedSessionIds)
    }

    private func toggleSessionSelection(_ session: HermesSessionSummary) {
        guard session.id != store.liveSessionId else { return }
        if selectedSessionIds.contains(session.id) {
            selectedSessionIds.remove(session.id)
        } else {
            selectedSessionIds.insert(session.id)
        }
    }
}

struct MessageBubble: View {
    let line: ChatLine
    let onApproval: (Bool) -> Void
    @State private var activityExpanded = false

    var body: some View {
        if line.role == "activity" {
            activityRow
        } else {
            messageRow
        }
    }

    private var messageRow: some View {
        if line.role == "assistant" {
            return AnyView(assistantMessageRow)
        }
        return AnyView(bubbledMessageRow)
    }

    private var assistantMessageRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            RichMarkdownView(markdown: line.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var bubbledMessageRow: some View {
        HStack {
            if line.role == "user" {
                Spacer(minLength: 52)
            }

            VStack(alignment: bubbleAlignment, spacing: 6) {
                Text(roleLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(line.text)
                    .textSelection(.enabled)
                    .multilineTextAlignment(line.role == "user" ? .trailing : .leading)
                if line.role == "approval", let state = line.approvalState {
                    approvalControls(state)
                }
            }
            .padding(bubblePadding)
            .background(bubbleBackground, in: RoundedRectangle(cornerRadius: 10))

            if line.role != "user" {
                Spacer(minLength: 52)
            }
        }
        .frame(maxWidth: .infinity, alignment: frameAlignment)
    }

    private var activityRow: some View {
        HStack(alignment: .top) {
            activityView
                .padding(.vertical, 6)
                .padding(.horizontal, 9)
                .frame(maxWidth: 520, alignment: .leading)
                .background(.quaternary.opacity(0.16), in: RoundedRectangle(cornerRadius: 8))
            Spacer(minLength: 80)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var roleLabel: String {
        switch line.role {
        case "user": "YOU"
        case "assistant": "AI"
        default: line.role.uppercased()
        }
    }

    private var bubbleAlignment: HorizontalAlignment {
        line.role == "user" ? .trailing : .leading
    }

    private var frameAlignment: Alignment {
        line.role == "user" ? .trailing : .leading
    }

    private var bubbleBackground: AnyShapeStyle {
        if line.role == "activity" {
            return AnyShapeStyle(.quaternary.opacity(0.22))
        }
        if line.role == "user" {
            return AnyShapeStyle(.secondary.opacity(0.22))
        }
        return AnyShapeStyle(.quaternary.opacity(0.35))
    }

    private var bubblePadding: EdgeInsets {
        if line.role == "activity" {
            return EdgeInsets(top: 7, leading: 10, bottom: 7, trailing: 10)
        }
        return EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
    }

    private var activityView: some View {
        DisclosureGroup(isExpanded: $activityExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(line.activityItems) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.type)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(item.text)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 1)
                }
            }
            .padding(.top, 4)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Image(systemName: line.isStreamingActivity ? "sparkles" : "checkmark.circle")
                        .foregroundStyle(.secondary)
                    Text(activityLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .shimmering(active: line.isStreamingActivity)

                if line.isStreamingActivity && !activityExpanded {
                    Text(activityPreview)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                        .transition(.opacity)
                }
            }
        }
    }

    private var activityPreview: String {
        let text = line.activityItems.last?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if lines.count >= 3 {
            return lines.suffix(3).joined(separator: "\n")
        }
        let words = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard words.count > 36 else { return text }
        return words.suffix(36).joined(separator: " ")
    }

    private var activityLabel: String {
        let status = line.isStreamingActivity ? "Running" : "Done"
        let text = line.text
            .replacingOccurrences(of: "Activity · ", with: "")
            .replacingOccurrences(of: "Activity", with: "thinking")
        return "\(text) · \(status)"
    }

    @ViewBuilder
    private func approvalControls(_ state: ApprovalState) -> some View {
        switch state {
        case .pending:
            HStack(spacing: 12) {
                Button {
                    onApproval(true)
                } label: {
                    Label("Approve", systemImage: "checkmark.circle")
                }
                Button {
                    onApproval(false)
                } label: {
                    Label("Deny", systemImage: "xmark.circle")
                }
            }
            .buttonStyle(.borderless)
            .padding(.top, 4)
        case .approved:
            Label("Approved", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .denied:
            Label("Denied", systemImage: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }
}

struct RichMarkdownView: View {
    @EnvironmentObject private var store: WorkspaceStore
    let markdown: String
    @State private var renderedHTML: String?
    @State private var webHeight: CGFloat = 80
    @State private var renderFailed = false

    var body: some View {
        Group {
            if let renderedHTML, !renderFailed {
                RenderedMarkdownWebView(html: renderedHTML, height: $webHeight)
                    .frame(minHeight: webHeight, maxHeight: webHeight)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                nativeMarkdownView
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: markdown) {
            await loadServerRenderedHTML()
        }
    }

    private var nativeMarkdownView: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(markdownBlocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    private var markdownBlocks: [MarkdownBlock] {
        parseMarkdownBlocks(markdown)
    }

    private func loadServerRenderedHTML() async {
        guard let api = store.api else {
            renderFailed = true
            renderedHTML = nil
            return
        }
        do {
            try await Task.sleep(nanoseconds: 250_000_000)
            let html = try await api.renderMarkdown(markdown: markdown)
            guard !Task.isCancelled else { return }
            renderedHTML = html
            renderFailed = false
        } catch {
            guard !Task.isCancelled else { return }
            renderedHTML = nil
            renderFailed = true
        }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case let .heading(level, text):
            Text(text)
                .font(headingFont(level))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case let .paragraph(text):
            Text(attributed(text))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case let .bullet(text):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("•")
                    .foregroundStyle(.secondary)
                Text(attributed(text))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case let .ordered(index, text):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("\(index).")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 22, alignment: .trailing)
                Text(attributed(text))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case let .task(checked, text):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: checked ? "checkmark.square.fill" : "square")
                    .font(.caption)
                    .foregroundStyle(checked ? .green : .secondary)
                Text(attributed(text))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case let .quote(text):
            Text(attributed(text))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(.secondary.opacity(0.38))
                        .frame(width: 3)
                }
                .foregroundStyle(.secondary)
        case .horizontalRule:
            Rectangle()
                .fill(.quaternary.opacity(0.75))
                .frame(height: 1)
                .padding(.vertical, 4)
        case let .code(language, text):
            CodeBlockView(language: language, code: text)
        case let .table(table):
            markdownTable(table)
        }
    }

    private func markdownTable(_ table: MarkdownTable) -> some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(Array(table.rows.enumerated()), id: \.offset) { rowIndex, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            MarkdownTableCell(text: attributed(cell), isHeader: rowIndex == 0)
                        }
                    }
                }
            }
            .background(.quaternary.opacity(0.10))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.quaternary.opacity(0.65), lineWidth: 1)
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title3.weight(.semibold)
        case 2: .headline
        default: .subheadline.weight(.semibold)
        }
    }

    private func attributed(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

#if os(macOS)
final class NonScrollingWKWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }
}

struct RenderedMarkdownWebView: NSViewRepresentable {
    let html: String
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(height: $height)
    }

    func makeNSView(context: Context) -> WKWebView {
        let webView = NonScrollingWKWebView()
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.height = $height
        if context.coordinator.currentHTML != html {
            context.coordinator.currentHTML = html
            webView.loadHTMLString(nonScrollingHTML(html), baseURL: nil)
        }
    }

    private func nonScrollingHTML(_ value: String) -> String {
        let style = "<style>html,body{overflow:visible!important;} body{height:auto!important;}</style>"
        if value.contains("</head>") {
            return value.replacingOccurrences(of: "</head>", with: "\(style)</head>")
        }
        return "\(style)\n\(value)"
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var height: Binding<CGFloat>
        var currentHTML = ""

        init(height: Binding<CGFloat>) {
            self.height = height
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            updateHeight(webView)
            updateHeightAfterRemoteImagesLoad(webView)
        }

        private func updateHeightAfterRemoteImagesLoad(_ webView: WKWebView) {
            for delay in [0.25, 0.8, 1.8] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak webView] in
                    guard let self, let webView else { return }
                    self.updateHeight(webView)
                }
            }
        }

        private func updateHeight(_ webView: WKWebView) {
            webView.evaluateJavaScript("document.body.scrollHeight") { [weak self] value, _ in
                guard let self else { return }
                let next = CGFloat(value as? Double ?? 80)
                DispatchQueue.main.async {
                    self.height.wrappedValue = max(32, next)
                }
            }
        }
    }
}
#elseif os(iOS)
struct RenderedMarkdownWebView: UIViewRepresentable {
    let html: String
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(height: $height)
    }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.height = $height
        if context.coordinator.currentHTML != html {
            context.coordinator.currentHTML = html
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var height: Binding<CGFloat>
        var currentHTML = ""

        init(height: Binding<CGFloat>) {
            self.height = height
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            updateHeight(webView)
            updateHeightAfterRemoteImagesLoad(webView)
        }

        private func updateHeightAfterRemoteImagesLoad(_ webView: WKWebView) {
            for delay in [0.25, 0.8, 1.8] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak webView] in
                    guard let self, let webView else { return }
                    self.updateHeight(webView)
                }
            }
        }

        private func updateHeight(_ webView: WKWebView) {
            webView.evaluateJavaScript("document.body.scrollHeight") { [weak self] value, _ in
                guard let self else { return }
                let next = CGFloat(value as? Double ?? 80)
                DispatchQueue.main.async {
                    self.height.wrappedValue = max(32, next)
                }
            }
        }
    }
}
#endif

struct CodeBlockView: View {
    let language: String?
    let code: String

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Text("<|>")
                    .font(.caption2.weight(.bold).monospaced())
                    .foregroundStyle(.secondary)
                Text("Code")
                    .font(.caption.weight(.semibold))
                let displayLanguage = displayLanguageName(language)
                if !displayLanguage.isEmpty {
                    Text("· \(displayLanguage)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    copyToClipboard(code)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Copy code")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.quaternary.opacity(0.24))

            ScrollView(.horizontal) {
                Text(highlightedCode(code, language: language))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(.black.opacity(0.10))
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.quaternary.opacity(0.55), lineWidth: 1)
        )
    }
}

private func copyToClipboard(_ text: String) {
    #if os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    #elseif os(iOS)
    UIPasteboard.general.string = text
    #endif
}

private struct MarkdownTableCell: View {
    let text: AttributedString
    let isHeader: Bool

    var body: some View {
        Text(text)
            .font(isHeader ? .caption.weight(.semibold) : .caption)
            .textSelection(.enabled)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(minWidth: 118, maxWidth: 240, alignment: .leading)
            .background(cellBackground)
            .overlay(Rectangle().stroke(.quaternary.opacity(0.38), lineWidth: 0.5))
    }

    private var cellBackground: AnyShapeStyle {
        if isHeader {
            return AnyShapeStyle(.quaternary.opacity(0.35))
        }
        return AnyShapeStyle(.quaternary.opacity(0.16))
    }
}

private struct ShimmerModifier: ViewModifier {
    let active: Bool
    @State private var phase = false

    func body(content: Content) -> some View {
        if active {
            content
                .opacity(phase ? 1 : 0.62)
                .shadow(color: .white.opacity(phase ? 0.35 : 0.05), radius: phase ? 8 : 1)
                .onAppear {
                    withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                        phase = true
                    }
                }
        } else {
            content
        }
    }
}

private extension View {
    func shimmering(active: Bool) -> some View {
        modifier(ShimmerModifier(active: active))
    }
}

private func highlightedCode(_ code: String, language: String?) -> AttributedString {
    var result = AttributedString()
    let profile = codeHighlightProfile(for: language)
    let scalars = Array(code)
    var index = 0

    func append(_ text: String, color: Color? = nil) {
        var part = AttributedString(text)
        if let color {
            part.foregroundColor = color
        }
        result.append(part)
    }

    while index < scalars.count {
        let char = scalars[index]

        if startsLineComment(at: index, in: scalars, prefixes: profile.lineCommentPrefixes) {
            let start = index
            while index < scalars.count, scalars[index] != "\n" {
                index += 1
            }
            append(String(scalars[start..<index]), color: .secondary)
            continue
        }

        if startsBlockComment(at: index, in: scalars), profile.supportsBlockComments {
            let start = index
            index += 2
            while index + 1 < scalars.count {
                if scalars[index] == "*", scalars[index + 1] == "/" {
                    index += 2
                    break
                }
                index += 1
            }
            append(String(scalars[start..<index]), color: .secondary)
            continue
        }

        if char == "\"" || char == "'" {
            let quote = char
            let start = index
            index += 1
            var escaped = false
            while index < scalars.count {
                let current = scalars[index]
                index += 1
                if escaped {
                    escaped = false
                    continue
                }
                if current == "\\" {
                    escaped = true
                    continue
                }
                if current == quote {
                    break
                }
            }
            append(String(scalars[start..<index]), color: .green)
            continue
        }

        if char.isNumber {
            let start = index
            while index < scalars.count, scalars[index].isNumber || scalars[index] == "." {
                index += 1
            }
            append(String(scalars[start..<index]), color: .orange)
            continue
        }

        if char.isLetter || char == "_" {
            let start = index
            while index < scalars.count, scalars[index].isLetter || scalars[index].isNumber || scalars[index] == "_" || scalars[index] == "-" {
                index += 1
            }
            let token = String(scalars[start..<index])
            if profile.keywords.contains(token)
                || profile.keywords.contains(token.lowercased())
                || profile.keywords.contains(token.uppercased()) {
                append(token, color: .purple)
            } else if profile.literals.contains(token) || profile.literals.contains(token.lowercased()) {
                append(token, color: .blue)
            } else {
                append(token)
            }
            continue
        }

        append(String(char))
        index += 1
    }

    return result
}

private struct CodeHighlightProfile {
    let keywords: Set<String>
    let literals: Set<String>
    let lineCommentPrefixes: [String]
    let supportsBlockComments: Bool
}

private func normalizedLanguage(_ language: String?) -> String {
    let raw = (language ?? "").lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    let aliases: [String: String] = [
        "py": "python",
        "pyw": "python",
        "js": "javascript",
        "mjs": "javascript",
        "cjs": "javascript",
        "jsx": "javascript",
        "ts": "typescript",
        "tsx": "typescript",
        "c++": "cpp",
        "cc": "cpp",
        "cxx": "cpp",
        "hpp": "cpp",
        "hh": "cpp",
        "hxx": "cpp",
        "cs": "csharp",
        "kt": "kotlin",
        "kts": "kotlin",
        "rs": "rust",
        "rb": "ruby",
        "sh": "bash",
        "zsh": "bash",
        "shell": "bash",
        "yml": "yaml",
        "htm": "html",
        "md": "markdown",
        "docker": "dockerfile",
        "make": "makefile",
        "mk": "makefile"
    ]
    return aliases[raw] ?? raw
}

private func displayLanguageName(_ language: String?) -> String {
    let normalized = normalizedLanguage(language)
    let names: [String: String] = [
        "": "",
        "bash": "Shell",
        "c": "C",
        "cpp": "C++",
        "csharp": "C#",
        "css": "CSS",
        "dockerfile": "Dockerfile",
        "go": "Go",
        "html": "HTML",
        "java": "Java",
        "javascript": "JavaScript",
        "json": "JSON",
        "kotlin": "Kotlin",
        "makefile": "Makefile",
        "markdown": "Markdown",
        "php": "PHP",
        "python": "Python",
        "ruby": "Ruby",
        "rust": "Rust",
        "sql": "SQL",
        "swift": "Swift",
        "typescript": "TypeScript",
        "xml": "XML",
        "yaml": "YAML"
    ]
    return names[normalized] ?? normalized
}

private func codeHighlightProfile(for language: String?) -> CodeHighlightProfile {
    let normalized = normalizedLanguage(language)
    let commonLiterals: Set<String> = ["true", "false", "null", "nil", "none", "True", "False", "None"]

    switch normalized {
    case "python":
        return CodeHighlightProfile(keywords: [
            "and", "as", "assert", "async", "await", "break", "class", "continue",
            "def", "del", "elif", "else", "except", "False", "finally", "for",
            "from", "global", "if", "import", "in", "is", "lambda", "None",
            "nonlocal", "not", "or", "pass", "raise", "return", "True", "try",
            "while", "with", "yield"
        ], literals: commonLiterals, lineCommentPrefixes: ["#"], supportsBlockComments: false)
    case "c", "cpp", "objc", "objective-c":
        return CodeHighlightProfile(keywords: [
            "auto", "bool", "break", "case", "char", "class", "const", "constexpr",
            "continue", "default", "delete", "do", "double", "else", "enum",
            "extern", "float", "for", "friend", "goto", "if", "inline", "int",
            "long", "namespace", "new", "operator", "private", "protected", "public",
            "return", "short", "signed", "sizeof", "static", "struct", "switch",
            "template", "this", "throw", "try", "typedef", "typename", "union",
            "unsigned", "using", "virtual", "void", "volatile", "while"
        ], literals: commonLiterals, lineCommentPrefixes: ["//", "#"], supportsBlockComments: true)
    case "java", "kotlin", "csharp":
        return CodeHighlightProfile(keywords: [
            "abstract", "break", "case", "catch", "class", "const", "continue",
            "default", "do", "else", "enum", "extends", "final", "finally", "for",
            "fun", "if", "implements", "import", "interface", "new", "object",
            "override", "package", "private", "protected", "public", "return",
            "static", "super", "switch", "this", "throw", "throws", "try", "val",
            "var", "void", "when", "while"
        ], literals: commonLiterals, lineCommentPrefixes: ["//"], supportsBlockComments: true)
    case "javascript", "typescript":
        return CodeHighlightProfile(keywords: [
            "async", "await", "break", "case", "catch", "class", "const", "continue",
            "debugger", "default", "delete", "do", "else", "export", "extends",
            "finally", "for", "from", "function", "if", "import", "in", "instanceof",
            "interface", "let", "new", "of", "private", "protected", "public",
            "return", "static", "super", "switch", "this", "throw", "try", "type",
            "typeof", "var", "void", "while", "yield"
        ], literals: commonLiterals, lineCommentPrefixes: ["//"], supportsBlockComments: true)
    case "swift":
        return CodeHighlightProfile(keywords: [
            "actor", "as", "associatedtype", "async", "await", "break", "case",
            "catch", "class", "continue", "defer", "do", "else", "enum", "extension",
            "fallthrough", "false", "fileprivate", "for", "func", "guard", "if",
            "import", "in", "init", "internal", "is", "let", "nil", "open",
            "operator", "private", "protocol", "public", "repeat", "return",
            "self", "static", "struct", "subscript", "super", "switch", "throw",
            "throws", "true", "try", "typealias", "var", "where", "while"
        ], literals: commonLiterals, lineCommentPrefixes: ["//"], supportsBlockComments: true)
    case "rust":
        return CodeHighlightProfile(keywords: [
            "as", "async", "await", "break", "const", "continue", "crate", "dyn",
            "else", "enum", "extern", "fn", "for", "if", "impl", "in", "let",
            "loop", "match", "mod", "move", "mut", "pub", "ref", "return",
            "self", "Self", "static", "struct", "super", "trait", "type", "unsafe",
            "use", "where", "while"
        ], literals: commonLiterals, lineCommentPrefixes: ["//"], supportsBlockComments: true)
    case "go":
        return CodeHighlightProfile(keywords: [
            "break", "case", "chan", "const", "continue", "default", "defer",
            "else", "fallthrough", "for", "func", "go", "goto", "if", "import",
            "interface", "map", "package", "range", "return", "select", "struct",
            "switch", "type", "var"
        ], literals: commonLiterals, lineCommentPrefixes: ["//"], supportsBlockComments: true)
    case "bash", "makefile", "dockerfile":
        return CodeHighlightProfile(keywords: [
            "case", "do", "done", "elif", "else", "esac", "fi", "for", "function",
            "if", "in", "select", "then", "until", "while", "export", "local",
            "readonly", "return", "source", "from", "run", "copy", "add", "cmd",
            "entrypoint", "env", "arg", "workdir", "expose", "volume", "user"
        ], literals: commonLiterals, lineCommentPrefixes: ["#"], supportsBlockComments: false)
    case "sql":
        return CodeHighlightProfile(keywords: [
            "ADD", "ALTER", "AND", "AS", "ASC", "BETWEEN", "BY", "CREATE", "DELETE",
            "DESC", "DISTINCT", "DROP", "FROM", "GROUP", "HAVING", "IN", "INSERT",
            "INTO", "JOIN", "LEFT", "LIKE", "LIMIT", "NOT", "NULL", "ON", "OR",
            "ORDER", "RIGHT", "SELECT", "SET", "TABLE", "UPDATE", "VALUES", "WHERE"
        ], literals: commonLiterals, lineCommentPrefixes: ["--"], supportsBlockComments: true)
    case "json", "yaml":
        return CodeHighlightProfile(keywords: [], literals: commonLiterals, lineCommentPrefixes: ["#"], supportsBlockComments: false)
    case "html", "xml":
        return CodeHighlightProfile(keywords: [
            "html", "head", "body", "div", "span", "section", "article", "header",
            "footer", "main", "script", "style", "link", "meta", "class", "id",
            "src", "href", "type", "name", "content", "template", "button", "input",
            "form", "table", "thead", "tbody", "tr", "td", "th"
        ], literals: commonLiterals, lineCommentPrefixes: [], supportsBlockComments: true)
    case "css":
        return CodeHighlightProfile(keywords: [
            "align-items", "animation", "background", "border", "color", "display",
            "flex", "font", "gap", "grid", "height", "justify-content", "margin",
            "padding", "position", "relative", "absolute", "width", "z-index",
            "transform", "transition", "opacity", "content", "media", "keyframes"
        ], literals: commonLiterals, lineCommentPrefixes: [], supportsBlockComments: true)
    case "ruby":
        return CodeHighlightProfile(keywords: [
            "alias", "and", "begin", "break", "case", "class", "def", "defined?",
            "do", "else", "elsif", "end", "ensure", "false", "for", "if", "in",
            "module", "next", "nil", "not", "or", "redo", "rescue", "retry",
            "return", "self", "super", "then", "true", "undef", "unless", "until",
            "when", "while", "yield"
        ], literals: commonLiterals, lineCommentPrefixes: ["#"], supportsBlockComments: false)
    case "php":
        return CodeHighlightProfile(keywords: [
            "abstract", "and", "array", "as", "break", "callable", "case", "catch",
            "class", "clone", "const", "continue", "declare", "default", "do",
            "echo", "else", "elseif", "empty", "extends", "final", "finally", "fn",
            "for", "foreach", "function", "global", "if", "implements", "include",
            "instanceof", "interface", "namespace", "new", "private", "protected",
            "public", "require", "return", "static", "switch", "throw", "trait",
            "try", "use", "var", "while", "yield"
        ], literals: commonLiterals, lineCommentPrefixes: ["//", "#"], supportsBlockComments: true)
    case "markdown":
        return CodeHighlightProfile(keywords: [], literals: commonLiterals, lineCommentPrefixes: [], supportsBlockComments: false)
    default:
        return CodeHighlightProfile(keywords: [
            "async", "await", "break", "case", "catch", "class", "const", "continue",
            "default", "else", "enum", "export", "extends", "false", "for", "func",
            "function", "guard", "if", "import", "in", "let", "nil", "null", "private",
            "public", "return", "static", "struct", "switch", "throw", "true", "try",
            "var", "while"
        ], literals: commonLiterals, lineCommentPrefixes: ["//", "#"], supportsBlockComments: true)
    }
}

private func startsLineComment(at index: Int, in chars: [Character], prefixes: [String]) -> Bool {
    prefixes.contains { prefix in
        startsWith(prefix, at: index, in: chars)
    }
}

private func startsBlockComment(at index: Int, in chars: [Character]) -> Bool {
    startsWith("/*", at: index, in: chars)
}

private func startsWith(_ prefix: String, at index: Int, in chars: [Character]) -> Bool {
    let prefixChars = Array(prefix)
    guard index + prefixChars.count <= chars.count else { return false }
    for offset in 0..<prefixChars.count where chars[index + offset] != prefixChars[offset] {
        return false
    }
    return true
}

private func parseMarkdownBlocks(_ markdown: String) -> [MarkdownBlock] {
    let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    var blocks: [MarkdownBlock] = []
    var paragraph: [String] = []
    var index = 0

    func flushParagraph() {
        let text = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            blocks.append(.paragraph(text))
        }
        paragraph.removeAll()
    }

    while index < lines.count {
        let line = lines[index]
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if trimmed.isEmpty {
            flushParagraph()
            index += 1
            continue
        }

        if trimmed.hasPrefix("```") {
            flushParagraph()
            let language = String(trimmed.dropFirst(3))
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: " ")
                .first
                .map(String.init)
            index += 1
            var code: [String] = []
            while index < lines.count {
                let codeLine = lines[index]
                if codeLine.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    index += 1
                    break
                }
                code.append(codeLine)
                index += 1
            }
            blocks.append(.code(language: language, text: code.joined(separator: "\n")))
            continue
        }

        if let table = parseMarkdownTable(lines: lines, start: index) {
            flushParagraph()
            blocks.append(.table(table.table))
            index = table.nextIndex
            continue
        }

        if isHorizontalRule(trimmed) {
            flushParagraph()
            blocks.append(.horizontalRule)
            index += 1
            continue
        }

        if let heading = parseHeading(trimmed) {
            flushParagraph()
            blocks.append(.heading(level: heading.level, text: heading.text))
            index += 1
            continue
        }

        if let task = parseTask(trimmed) {
            flushParagraph()
            blocks.append(.task(checked: task.checked, text: task.text))
            index += 1
            continue
        }

        if let quote = parseQuote(trimmed) {
            flushParagraph()
            blocks.append(.quote(quote))
            index += 1
            continue
        }

        if let ordered = parseOrdered(trimmed) {
            flushParagraph()
            blocks.append(.ordered(index: ordered.index, text: ordered.text))
            index += 1
            continue
        }

        if let bullet = parseBullet(trimmed) {
            flushParagraph()
            blocks.append(.bullet(bullet))
            index += 1
            continue
        }

        paragraph.append(line)
        index += 1
    }

    flushParagraph()
    return blocks.isEmpty ? [.paragraph(markdown)] : blocks
}

private func parseHeading(_ line: String) -> (level: Int, text: String)? {
    let hashes = line.prefix { $0 == "#" }.count
    guard hashes > 0, hashes <= 6 else { return nil }
    let rest = line.dropFirst(hashes)
    guard rest.first == " " else { return nil }
    return (hashes, String(rest.dropFirst()).trimmingCharacters(in: .whitespaces))
}

private func parseBullet(_ line: String) -> String? {
    for prefix in ["- ", "* ", "+ "] where line.hasPrefix(prefix) {
        return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }
    return nil
}

private func parseOrdered(_ line: String) -> (index: Int, text: String)? {
    let pattern = #"^(\d+)[\.\)]\s+(.+)$"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
          let indexRange = Range(match.range(at: 1), in: line),
          let textRange = Range(match.range(at: 2), in: line),
          let index = Int(line[indexRange]) else {
        return nil
    }
    return (index, String(line[textRange]).trimmingCharacters(in: .whitespaces))
}

private func parseTask(_ line: String) -> (checked: Bool, text: String)? {
    let lower = line.lowercased()
    for marker in ["- [ ] ", "* [ ] ", "+ [ ] "] where lower.hasPrefix(marker) {
        return (false, String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces))
    }
    for marker in ["- [x] ", "* [x] ", "+ [x] "] where lower.hasPrefix(marker) {
        return (true, String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces))
    }
    return nil
}

private func parseQuote(_ line: String) -> String? {
    guard line.hasPrefix(">") else { return nil }
    return String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
}

private func isHorizontalRule(_ line: String) -> Bool {
    let stripped = line.replacingOccurrences(of: " ", with: "")
    guard stripped.count >= 3 else { return false }
    return stripped.allSatisfy { $0 == "-" }
        || stripped.allSatisfy { $0 == "*" }
        || stripped.allSatisfy { $0 == "_" }
}

private func parseMarkdownTable(lines: [String], start: Int) -> (table: MarkdownTable, nextIndex: Int)? {
    guard start + 1 < lines.count else { return nil }
    let header = lines[start].trimmingCharacters(in: .whitespaces)
    let separator = lines[start + 1].trimmingCharacters(in: .whitespaces)
    guard header.contains("|"), isTableSeparator(separator) else { return nil }

    var rows = [splitTableRow(header)]
    var index = start + 2
    while index < lines.count {
        let line = lines[index].trimmingCharacters(in: .whitespaces)
        guard line.contains("|"), !line.isEmpty else { break }
        rows.append(splitTableRow(line))
        index += 1
    }

    let maxColumns = rows.map(\.count).max() ?? 0
    guard maxColumns > 1 else { return nil }
    rows = rows.map { row in
        row + Array(repeating: "", count: max(0, maxColumns - row.count))
    }
    return (MarkdownTable(rows: rows), index)
}

private func splitTableRow(_ line: String) -> [String] {
    var text = line
    if text.hasPrefix("|") { text.removeFirst() }
    if text.hasSuffix("|") { text.removeLast() }
    return text
        .components(separatedBy: "|")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
}

private func isTableSeparator(_ line: String) -> Bool {
    guard line.contains("|") else { return false }
    let cells = splitTableRow(line)
    guard !cells.isEmpty else { return false }
    return cells.allSatisfy { cell in
        let stripped = cell.replacingOccurrences(of: ":", with: "")
        return stripped.count >= 3 && stripped.allSatisfy { $0 == "-" }
    }
}
