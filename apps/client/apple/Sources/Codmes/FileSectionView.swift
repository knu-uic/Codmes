import CryptoKit
import SwiftUI
import PDFKit
import CoreTransferable
import UniformTypeIdentifiers

struct FileSectionView: View {
    @EnvironmentObject private var store: WorkspaceStore
    let title: String
    let root: String
    var showsBrowserOnIOS = true

    var body: some View {
        Group {
            #if os(macOS)
            HSplitView {
                FileBrowserPane(title: title, root: root, showsHeader: false)
                    .frame(minWidth: 220, idealWidth: 280, maxWidth: 380)
                    .frame(maxHeight: .infinity)

                FilePreviewView()
                    .frame(minWidth: 0)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            #else
            if showsBrowserOnIOS {
                VStack(spacing: 0) {
                    FileBrowserPane(title: title, root: root)
                        .frame(maxHeight: 320)
                    Divider()
                    FilePreviewView()
                }
            } else {
                FilePreviewView()
            }
            #endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}

struct FileBrowserPane: View {
    @EnvironmentObject private var store: WorkspaceStore
    let title: String
    let root: String
    var showsHeader = true
    var onOpenFile: (() -> Void)?
    @State private var newItemKind: NewWorkspaceItemKind?
    @State private var newItemName = ""
    @State private var itemToRename: WorkspaceItem?
    @State private var renameName = ""
    @State private var itemsToDelete: [WorkspaceItem] = []
    @State private var transferAction: WorkspaceTransferAction?
    @State private var transferDestination = ""
    @State private var isImportingFile = false
    @State private var expandedFolderPaths: Set<String> = []
    @State private var dropTargetPath: String?
    @State private var selectedTreePaths: Set<String> = []
    @State private var isSelectingItems = false
    @State private var conflictToResolve: WorkspaceSyncConflict?
    @State private var presentedConflictIds: Set<String> = []
    @State private var operationFailure: WorkspaceFileOperationFailure?
    @State private var operationRetry: FileOperationRetry?
    @State private var replacementName = ""

    private enum FileOperationRetry {
        case createFile(String)
        case createFolder(String)
        case rename(WorkspaceItem, String)
        case copy([WorkspaceItem], String, [String: String])
        case move([String], WorkspaceItem?, [String: String])
    }

    init(
        title: String,
        root: String,
        showsHeader: Bool = true,
        onOpenFile: (() -> Void)? = nil
    ) {
        self.title = title
        self.root = root
        self.showsHeader = showsHeader
        self.onOpenFile = onOpenFile
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsHeader {
                HeaderView(title: title, subtitle: headerSubtitle)
            }
            browserToolbar

            UploadStatusPanel(root: root)

            ScrollView {
                if !store.localStorageError.isEmpty {
                    Text(store.localStorageError)
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(16)
                }
                LazyVStack(spacing: 1) {
                    ForEach(visibleTreeEntries) { entry in
                        treeRow(entry)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 1)
                            .background(
                                rowBackground(for: entry.item),
                                in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                            )
                            .overlay {
                                if dropTargetPath == entry.item.path {
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .stroke(Color.accentColor, lineWidth: 2)
                                }
                            }
                            .padding(.horizontal, 6)
                    }
                }
                .padding(.vertical, 6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .confirmationDialog(conflictToResolve?.title ?? "동기화 확인", isPresented: Binding(get: { conflictToResolve != nil }, set: { if !$0 { conflictToResolve = nil } }), titleVisibility: .visible) {
            if let conflict = conflictToResolve {
                if conflict.server?.resource == "file", conflict.reason != "structure" {
                Button("서버 파일 사용 · 이 기기 내용 교체", role: .destructive) { Task { await store.resolveStorageConflict(conflict, useServer: true) }; conflictToResolve = nil }
                Button("내 파일로 서버 교체 · 다른 기기에도 반영", role: .destructive) { Task { await store.resolveStorageConflict(conflict, useServer: false) }; conflictToResolve = nil }
                }
                if conflict.isNameConflict {
                    Button("내 파일 이름 변경 후 둘 다 유지") {
                        itemToRename = (store.notes + store.code).first { $0.path == conflict.path }; renameName = itemToRename?.name ?? ""; conflictToResolve = nil
                    }
                } else {
                    Button("다시 동기화") { conflictToResolve = nil; Task { await store.syncLocalWorkspace() } }
                }
                Button("나중에 결정", role: .cancel) { conflictToResolve = nil }
            }
        } message: {
            Text((conflictToResolve?.path ?? "") + "\n" + (conflictToResolve?.message ?? "로컬 자료는 보존됩니다."))
        }
        .fileImporter(isPresented: $isImportingFile, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case let .success(urls):
                Task { await store.importLocalFiles(root: root, fileURLs: urls) }
            case let .failure(error):
                store.statusMessage = error.localizedDescription
            }
        }
        .alert(newItemKind?.title ?? "New item", isPresented: newItemBinding) {
            TextField("Name", text: $newItemName)
            Button("Create") {
                let name = newItemName
                let kind = newItemKind
                newItemKind = nil
                Task {
                    switch kind {
                    case .file:
                        await performFileOperation(.createFile(name))
                    case .folder:
                        await performFileOperation(.createFolder(name))
                    case .none:
                        break
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                newItemKind = nil
            }
        } message: {
            Text(store.currentPath(for: root).isEmpty ? "Create in \(title)." : "Create in \(store.currentPath(for: root)).")
        }
        .alert("Rename", isPresented: renameBinding) {
            TextField("Name", text: $renameName)
            Button("Rename") {
                let item = itemToRename
                let name = renameName
                itemToRename = nil
                Task {
                    if let item {
                        await performFileOperation(.rename(item, name))
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                itemToRename = nil
            }
        } message: {
            Text(itemToRename?.path ?? "")
        }
        .alert(transferAction?.title ?? "Transfer", isPresented: transferBinding) {
            TextField("Destination folder in \(title)", text: $transferDestination)
            Button(transferAction?.buttonTitle ?? "Apply") {
                let action = transferAction
                let destination = transferDestination
                transferAction = nil
                Task {
                    switch action {
                    case let .copy(items):
                        await performFileOperation(.copy(items, destination, [:]))
                    case .none:
                        break
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                transferAction = nil
            }
        } message: {
            Text("Use a folder path relative to \(title). Leave empty for the \(title) root.")
        }
        .background {
            // Separate from the input alerts so dismissing Create/Rename does
            // not swallow the operation's failure alert in the same update.
            Color.clear
                .alert(operationFailure?.title ?? "파일 작업 확인", isPresented: operationFailureBinding, presenting: operationFailure) { failure in
                    if let conflict = failure.nameConflict {
                        TextField("새 이름", text: $replacementName)
                        Button("예") { retryFileOperation(conflict: conflict) }
                            .disabled(replacementName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("아니오", role: .cancel) { cancelFileOperation() }
                    } else {
                        Button("확인", role: .cancel) { cancelFileOperation() }
                    }
                } message: { failure in
                    Text(failure.message)
                }
        }
        .confirmationDialog(deleteDialogTitle, isPresented: deleteBinding, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                let items = itemsToDelete
                itemsToDelete = []
                Task {
                    await store.deleteItems(root: root, items: items)
                    clearTreeSelection()
                }
            }
            Button("Cancel", role: .cancel) {
                itemsToDelete = []
            }
        } message: {
            Text(deleteDialogMessage)
        }
        .task(id: "\(store.profileStorageScope):\(store.isWorkspaceConnected)") {
            expandedFolderPaths = Self.savedExpandedFolders(root: root, scope: store.profileStorageScope)
            clearTreeSelection()
            revealSelectedFile()
            if root == "code", store.isWorkspaceConnected {
                await store.refreshCodeTasks()
            }
        }
        .onChange(of: selectedFilePath) { _, _ in
            revealSelectedFile()
        }
        .onChange(of: store.storageConflicts) { _, conflicts in
            if let current = conflictToResolve {
                // A successful rename/retry must also dismiss its stale dialog.
                conflictToResolve = conflicts.first { $0.id == current.id }
            }
            guard conflictToResolve == nil,
                  let conflict = conflicts.first(where: { $0.path.hasPrefix(root.capitalized + "/") && !presentedConflictIds.contains($0.id) }) else { return }
            presentedConflictIds.insert(conflict.id); conflictToResolve = conflict
        }
        .onChange(of: store.items(for: root)) { _, items in
            guard store.workspace != nil else { return }
            let validFolders = Set(items.lazy.filter(\.isDirectory).map(\.path))
            let previous = expandedFolderPaths
            expandedFolderPaths.formIntersection(validFolders)
            if previous != expandedFolderPaths {
                saveExpandedFolders()
            }
            selectedTreePaths.formIntersection(Set(items.map(\.path)))
            if isSelectingItems, selectedTreePaths.isEmpty {
                clearTreeSelection()
            }
        }
    }

    @ViewBuilder
    private var browserToolbar: some View {
        if isSelectingItems {
            HStack(spacing: 8) {
                Button {
                    clearTreeSelection()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .frame(width: 30, height: 30)
                .help("Cancel selection")

                Text("\(selectedTreePaths.count) selected")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Image(systemName: "house")
                    .foregroundStyle(dropTargetPath == workspaceRootName ? Color.accentColor : Color.primary.opacity(0.72))

                Spacer()

                Button {
                    beginCopy(items: selectedTreeItems)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .frame(width: 30, height: 30)
                .disabled(selectedTreePaths.isEmpty)
                .help("Copy selected items")

                Button(role: .destructive) {
                    itemsToDelete = selectedTreeItems
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .frame(width: 30, height: 30)
                .disabled(selectedTreePaths.isEmpty)
                .help("Delete selected items")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.quaternary.opacity(0.10))
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(.quaternary.opacity(0.35))
                    .frame(height: 1)
            }
            .background(rootDropBackground)
            .overlay { rootDropBorder }
            .contentShape(Rectangle())
            .dropDestination(for: FileTreeDragItem.self, action: dropIntoRoot, isTargeted: updateRootDropTarget)
        } else {
            HStack(spacing: 8) {
                Button {
                    newItemName = root == "code" ? "Untitled.swift" : "Untitled.md"
                    newItemKind = .file
                } label: {
                    Image(systemName: "doc.badge.plus")
                }
                .buttonStyle(.plain)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
                .help("New file")

                Button {
                    newItemName = "New Folder"
                    newItemKind = .folder
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .buttonStyle(.plain)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
                .help("New folder")

                Button {
                    isImportingFile = true
                } label: {
                    Image(systemName: "paperclip")
                }
                .buttonStyle(.plain)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
                .help("Attach or import file")

                Image(systemName: "house")
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
                .foregroundStyle(dropTargetPath == workspaceRootName ? Color.accentColor : Color.primary)
                .onTapGesture {
                    store.selectFolder(root: root, item: nil)
                }
                .accessibilityAddTraits(.isButton)
                .help("Use root folder")
                #if os(macOS)
                .onDrop(
                    of: [.codmesWorkspaceItem],
                    delegate: MacOSWorkspaceDropDelegate(
                        dropTargetPath: $dropTargetPath,
                        targetPath: workspaceRootName,
                        movePaths: { paths in
                            _ = moveDraggedItems(paths, into: nil)
                        }
                    )
                )
                #endif

                Text(store.currentPath(for: root).isEmpty ? "/" : store.currentPath(for: root))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                    .contentShape(Rectangle())
                    #if os(macOS)
                    .onDrop(
                        of: [.codmesWorkspaceItem],
                        delegate: MacOSWorkspaceDropDelegate(
                            dropTargetPath: $dropTargetPath,
                            targetPath: workspaceRootName,
                            movePaths: { paths in
                                _ = moveDraggedItems(paths, into: nil)
                            }
                        )
                    )
                    #endif
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.quaternary.opacity(0.10))
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(.quaternary.opacity(0.35))
                    .frame(height: 1)
            }
            .background(rootDropBackground)
            .overlay { rootDropBorder }
            .contentShape(Rectangle())
            .dropDestination(for: FileTreeDragItem.self, action: dropIntoRoot, isTargeted: updateRootDropTarget)
        }
    }

    private var newItemBinding: Binding<Bool> {
        Binding(
            get: { newItemKind != nil },
            set: { if !$0 { newItemKind = nil } }
        )
    }

    private var operationFailureBinding: Binding<Bool> {
        Binding(get: { operationFailure != nil }, set: { if !$0 { operationFailure = nil } })
    }

    private var renameBinding: Binding<Bool> {
        Binding(
            get: { itemToRename != nil },
            set: { if !$0 { itemToRename = nil } }
        )
    }

    private var deleteBinding: Binding<Bool> {
        Binding(
            get: { !itemsToDelete.isEmpty },
            set: { if !$0 { itemsToDelete = [] } }
        )
    }

    private var transferBinding: Binding<Bool> {
        Binding(
            get: { transferAction != nil },
            set: { if !$0 { transferAction = nil } }
        )
    }

    private func icon(for item: WorkspaceItem) -> String {
        if item.isDirectory { return "folder" }
        switch item.kind {
        case "markdown": return "doc.text"
        case "pdf": return "doc.richtext"
        case "image": return "photo"
        case "code": return "curlybraces"
        default: return "doc"
        }
    }

    private func open(_ item: WorkspaceItem) {
        guard !item.isDirectory else { return }
        onOpenFile?()
        Task {
            await store.loadFile(item)
        }
    }

    @ViewBuilder
    private func itemManagementMenu(_ item: WorkspaceItem) -> some View {
        if isSelectingItems {
            Button {
                toggleTreeSelection(item)
            } label: {
                Label(
                    selectedTreePaths.contains(item.path) ? "Deselect" : "Add to Selection",
                    systemImage: selectedTreePaths.contains(item.path) ? "checkmark.circle.fill" : "circle"
                )
            }
        } else {
            Button {
                isSelectingItems = true
                selectedTreePaths = [item.path]
            } label: {
                Label("Select Multiple", systemImage: "checkmark.circle")
            }
        }

        Divider()

        Menu("저장 모드") {
            WorkspaceStorageMenuContent(path: item.path)
        }

        Button {
            beginCopy(items: actionItems(for: item))
        } label: {
            Label("Copy to folder", systemImage: "doc.on.doc")
        }

        if actionItems(for: item).count == 1 {
            Button {
                itemToRename = item
                renameName = item.name
            } label: {
                Label("Rename", systemImage: "pencil")
            }
        }

        Button(role: .destructive) {
            itemsToDelete = actionItems(for: item)
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    private var selectedFilePath: String? {
        store.loadingRawFile?.path ?? store.selectedFile?.path ?? store.selectedRawFile?.path
    }

    private var workspaceRootName: String {
        root == "code" ? "Code" : "Notes"
    }

    private var headerSubtitle: String {
        guard root == "notes",
              let rawFile = store.selectedRawFile,
              rawFile.kind == "pdf",
              rawFile.path == store.activePDFStatusPath,
              !store.activePDFStatusText.isEmpty else {
            return store.sectionSubtitle(root: root)
        }
        return store.activePDFStatusText
    }

    private var visibleTreeEntries: [FileTreeEntry] {
        let grouped = Dictionary(grouping: store.items(for: root), by: { parentWorkspacePath($0.path) })
        var result: [FileTreeEntry] = []

        func appendChildren(of parent: String, depth: Int) {
            let children = (grouped[parent] ?? []).sorted(by: treeItemSort)
            for item in children {
                result.append(FileTreeEntry(item: item, depth: depth))
                if item.isDirectory, expandedFolderPaths.contains(item.path) {
                    appendChildren(of: item.path, depth: depth + 1)
                }
            }
        }

        appendChildren(of: workspaceRootName, depth: 0)
        return result
    }

    @ViewBuilder
    private func treeRow(_ entry: FileTreeEntry) -> some View {
        let item = entry.item
        let row = HStack(spacing: 3) {
            Color.clear
                .frame(width: CGFloat(entry.depth) * 15, height: 1)

            if isSelectingItems {
                Button {
                    toggleTreeSelection(item)
                } label: {
                    Image(systemName: selectedTreePaths.contains(item.path) ? "checkmark.circle.fill" : "circle")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(selectedTreePaths.contains(item.path) ? Color.accentColor : Color.primary.opacity(0.72))
                        .frame(width: 24, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if item.isDirectory {
                Button {
                    toggleFolder(item)
                } label: {
                    Image(systemName: expandedFolderPaths.contains(item.path) ? "chevron.down" : "chevron.right")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Color.primary.opacity(0.82))
                        .frame(width: 22, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Color.clear
                    .frame(width: 22, height: 30)
            }

            treeItemButtonBase(for: item)

            Menu {
                WorkspaceStorageMenuContent(path: item.path)
            } label: {
                Image(systemName: store.storageMode(path: item.path).icon)
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 30)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("이 기기의 저장 모드: \(store.storageMode(path: item.path).title)")
            .accessibilityLabel("저장 모드")

            Menu {
                itemManagementMenu(item)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.bold))
                    .foregroundStyle(Color.primary.opacity(0.82))
                    .frame(width: 24, height: 30)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .tint(.primary)
        }
        .contentShape(Rectangle())

        if item.isDirectory {
            #if os(macOS)
            row
                .onDrop(
                    of: [.codmesWorkspaceItem],
                    delegate: MacOSWorkspaceDropDelegate(
                        dropTargetPath: $dropTargetPath,
                        targetPath: item.path,
                        movePaths: { paths in
                            _ = moveDraggedItems(paths, into: item)
                        }
                    )
                )
            #else
            row
                .dropDestination(for: FileTreeDragItem.self, action: { items, _ in
                    moveDraggedItems(items.first?.paths ?? [], into: item)
                }, isTargeted: { isTargeted in
                    updateFolderDropTarget(isTargeted, item: item)
                })
            #endif
        } else {
            row
        }
    }

    private func treeItemButtonBase(for item: WorkspaceItem) -> some View {
        HStack(spacing: 7) {
            Image(systemName: item.isDirectory && expandedFolderPaths.contains(item.path) ? "folder.fill" : icon(for: item))
                .foregroundStyle(item.isDirectory ? Color.primary.opacity(0.82) : Color.secondary)
                .frame(width: 18)
            Text(item.name)
                .lineLimit(1)
                .truncationMode(.middle)
            if store.loadingRawFile?.path == item.path, store.rawFileLoadError == nil {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 16, height: 16)
            }
            Spacer(minLength: 4)
            if let conflict = store.storageConflicts.first(where: { $0.path == item.path }) {
                Button { conflictToResolve = conflict } label: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                    .buttonStyle(.borderless).help("동명 파일 확인 필요")
            } else if let state = store.storageTransferStates[item.path] {
                if state != "전송 중" { Image(systemName: "pause.circle").foregroundStyle(.secondary).help(state) }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelectingItems {
                toggleTreeSelection(item)
            } else if item.isDirectory {
                store.selectFolder(root: root, item: item)
                toggleFolder(item)
            } else {
                open(item)
            }
        }
        .accessibilityAddTraits(.isButton)
        .contextMenu { itemManagementMenu(item) }
        #if os(macOS)
        .onDrag {
            dragItem(for: item).macOSProvider()
        } preview: {
            dragPreview(for: item)
        }
        #else
        .draggable(dragItem(for: item)) {
            dragPreview(for: item)
        }
        #endif
    }

    private func updateFolderDropTarget(_ isTargeted: Bool, item: WorkspaceItem) {
        if isTargeted {
            dropTargetPath = item.path
        } else if dropTargetPath == item.path {
            dropTargetPath = nil
        }
    }

    private func dragPreview(for item: WorkspaceItem) -> some View {
        Label(dragPreviewTitle(for: item), systemImage: dragPreviewIcon(for: item))
            .font(.callout.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func rowBackground(for item: WorkspaceItem) -> Color {
        if dropTargetPath == item.path {
            return Color.accentColor.opacity(0.28)
        }
        if selectedFilePath == item.path {
            return Color.secondary.opacity(0.16)
        }
        if selectedTreePaths.contains(item.path) {
            return Color.accentColor.opacity(0.14)
        }
        let selectedFolderPath = store.currentPath(for: root)
        let itemFolderPath = item.isDirectory
            ? String(item.path.dropFirst(min(item.path.count, workspaceRootName.count + 1)))
            : ""
        if item.isDirectory, selectedFolderPath == itemFolderPath {
            return Color.secondary.opacity(0.07)
        }
        return Color.clear
    }

    private func toggleFolder(_ item: WorkspaceItem) {
        if expandedFolderPaths.contains(item.path) {
            expandedFolderPaths.remove(item.path)
        } else {
            expandedFolderPaths.insert(item.path)
        }
        saveExpandedFolders()
    }

    private func revealSelectedFile() {
        guard var path = selectedFilePath.map(parentWorkspacePath) else { return }
        var changed = false
        while path != workspaceRootName, path.hasPrefix(workspaceRootName + "/") {
            changed = expandedFolderPaths.insert(path).inserted || changed
            path = parentWorkspacePath(path)
        }
        if changed { saveExpandedFolders() }
    }

    private func moveDraggedItems(_ sourcePaths: [String], into folder: WorkspaceItem?) -> Bool {
        guard !sourcePaths.isEmpty else { return false }
        Task {
            await performFileOperation(.move(sourcePaths, folder, [:]))
        }
        return true
    }

    private func performFileOperation(_ action: FileOperationRetry) async {
        let failure: WorkspaceFileOperationFailure?
        switch action {
        case let .createFile(name):
            failure = await store.createFile(root: root, name: name)
        case let .createFolder(name):
            failure = await store.createFolder(root: root, name: name)
        case let .rename(item, name):
            failure = await store.renameItem(root: root, item: item, newName: name)
        case let .copy(items, destination, names):
            failure = await store.copyItems(root: root, items: items, destinationFolder: destination, replacementNames: names)
            if failure == nil { clearTreeSelection() }
        case let .move(paths, folder, names):
            failure = await store.moveTreeItems(root: root, sourcePaths: paths, into: folder, replacementNames: names)
            if failure == nil { clearTreeSelection() }
        }
        operationRetry = failure == nil ? nil : action
        replacementName = failure?.nameConflict?.suggestedName ?? ""
        operationFailure = failure
    }

    private func retryFileOperation(conflict: WorkspaceFileOperationFailure.NameConflict) {
        guard let previous = operationRetry else { return }
        let name = replacementName
        let next: FileOperationRetry
        switch previous {
        case .createFile: next = .createFile(name)
        case .createFolder: next = .createFolder(name)
        case let .rename(item, _): next = .rename(item, name)
        case let .copy(items, destination, names):
            guard let source = conflict.sourcePath else { return }
            var updated = names; updated[source] = name
            next = .copy(items, destination, updated)
        case let .move(paths, folder, names):
            guard let source = conflict.sourcePath else { return }
            var updated = names; updated[source] = name
            next = .move(paths, folder, updated)
        }
        operationFailure = nil
        Task { await performFileOperation(next) }
    }

    private func cancelFileOperation() {
        operationFailure = nil
        operationRetry = nil
        replacementName = ""
    }

    private var rootDropBackground: Color {
        dropTargetPath == workspaceRootName ? Color.accentColor.opacity(0.22) : Color.clear
    }

    @ViewBuilder
    private var rootDropBorder: some View {
        if dropTargetPath == workspaceRootName {
            Rectangle()
                .stroke(Color.accentColor, lineWidth: 2)
        }
    }

    private func dropIntoRoot(_ items: [FileTreeDragItem], _: CGPoint) -> Bool {
        moveDraggedItems(items.first?.paths ?? [], into: nil)
    }

    private func updateRootDropTarget(_ isTargeted: Bool) {
        if isTargeted {
            dropTargetPath = workspaceRootName
        } else if dropTargetPath == workspaceRootName {
            dropTargetPath = nil
        }
    }

    private var selectedTreeItems: [WorkspaceItem] {
        store.items(for: root).filter { selectedTreePaths.contains($0.path) }
    }

    private func actionItems(for item: WorkspaceItem) -> [WorkspaceItem] {
        if isSelectingItems, selectedTreePaths.contains(item.path) {
            return selectedTreeItems
        }
        return [item]
    }

    private func toggleTreeSelection(_ item: WorkspaceItem) {
        if selectedTreePaths.contains(item.path) {
            selectedTreePaths.remove(item.path)
        } else {
            if selectedTreePaths.contains(where: { item.path.hasPrefix($0 + "/") }) {
                return
            }
            selectedTreePaths = Set(selectedTreePaths.filter { !$0.hasPrefix(item.path + "/") })
            selectedTreePaths.insert(item.path)
        }
    }

    private func clearTreeSelection() {
        selectedTreePaths = []
        isSelectingItems = false
    }

    private func beginCopy(items: [WorkspaceItem]) {
        guard !items.isEmpty else { return }
        transferDestination = store.currentPath(for: root)
        transferAction = .copy(items)
    }

    private func dragItem(for item: WorkspaceItem) -> FileTreeDragItem {
        let paths = isSelectingItems && selectedTreePaths.contains(item.path)
            ? selectedTreeItems.map(\.path)
            : [item.path]
        return FileTreeDragItem(paths: paths)
    }

    private func dragPreviewTitle(for item: WorkspaceItem) -> String {
        let count = dragItem(for: item).paths.count
        return count == 1 ? item.name : "\(count) items"
    }

    private func dragPreviewIcon(for item: WorkspaceItem) -> String {
        dragItem(for: item).paths.count == 1 ? icon(for: item) : "doc.on.doc"
    }

    private var deleteDialogTitle: String {
        itemsToDelete.count == 1 ? "Delete item?" : "Delete \(itemsToDelete.count) items?"
    }

    private var deleteDialogMessage: String {
        if itemsToDelete.count == 1 {
            return itemsToDelete.first.map { "Delete \($0.path)?" } ?? ""
        }
        return "The selected files and folders will be deleted."
    }

    private func saveExpandedFolders() {
        UserDefaults.standard.set(Array(expandedFolderPaths).sorted(), forKey: Self.expandedFoldersKey(root: root, scope: store.profileStorageScope))
    }

    private static func savedExpandedFolders(root: String, scope: String) -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: expandedFoldersKey(root: root, scope: scope)) ?? [])
    }

    private static func expandedFoldersKey(root: String, scope: String) -> String {
        let digest = SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
        return "codmes.fileTree.expanded.\(digest).\(root)"
    }

    private func parentWorkspacePath(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    private func treeItemSort(_ lhs: WorkspaceItem, _ rhs: WorkspaceItem) -> Bool {
        if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}

private struct FileTreeEntry: Identifiable {
    var id: String { item.path }
    let item: WorkspaceItem
    let depth: Int
}

struct FileTreeDragItem: Codable, Transferable, Sendable {
    let paths: [String]

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .codmesWorkspaceItem)
    }
}

extension UTType {
    static let codmesWorkspaceItem = UTType(exportedAs: "com.codmes.workspace-item", conformingTo: .data)
}

#if os(macOS)
extension FileTreeDragItem {
    func macOSProvider() -> NSItemProvider {
        let provider = NSItemProvider()
        let data = (try? JSONEncoder().encode(self)) ?? Data()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.codmesWorkspaceItem.identifier, visibility: .all) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }

    static func loadPaths(from providers: [NSItemProvider], completion: @escaping @MainActor @Sendable ([String]) -> Void) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.codmesWorkspaceItem.identifier) }) else { return false }
        provider.loadDataRepresentation(forTypeIdentifier: UTType.codmesWorkspaceItem.identifier) { data, _ in
            guard let data, let item = try? JSONDecoder().decode(Self.self, from: data), !item.paths.isEmpty else { return }
            Task { @MainActor in completion(item.paths) }
        }
        return true
    }
}

struct MacOSWorkspaceDropDelegate: DropDelegate {
    @Binding var dropTargetPath: String?
    let targetPath: String
    let movePaths: @MainActor @Sendable ([String]) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.codmesWorkspaceItem])
    }

    func dropEntered(info _: DropInfo) {
        dropTargetPath = targetPath
    }

    func dropExited(info _: DropInfo) {
        if dropTargetPath == targetPath {
            dropTargetPath = nil
        }
    }

    func dropUpdated(info _: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        if dropTargetPath == targetPath { dropTargetPath = nil }
        return FileTreeDragItem.loadPaths(from: info.itemProviders(for: [.codmesWorkspaceItem]), completion: movePaths)
    }
}
#endif

private struct UploadStatusPanel: View {
    @EnvironmentObject private var store: WorkspaceStore
    let root: String

    private var uploads: [UploadItem] {
        store.uploads(for: root)
    }

    var body: some View {
        if !uploads.isEmpty {
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    Text("Uploads")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        store.clearFinishedUploads(root: root)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .disabled(!uploads.contains(where: { !$0.isActive }))
                    .help("Clear finished uploads")
                }

                ForEach(uploads.prefix(3)) { item in
                    UploadStatusRow(item: item)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.quaternary.opacity(0.08))
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(.quaternary.opacity(0.25))
                    .frame(height: 1)
            }
        }
    }
}

private struct UploadStatusRow: View {
    let item: UploadItem

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                if item.isActive {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 14, height: 14)
                } else {
                    Image(systemName: item.status.systemImage)
                        .font(.caption)
                        .foregroundStyle(iconColor)
                        .frame(width: 14, height: 14)
                }

                Text(item.fileName)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 8)

                Text(item.status.label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(iconColor)
            }

            if item.isActive {
                ProgressView(value: item.progress)
                    .progressViewStyle(.linear)
                    .controlSize(.small)
            }

            if !item.message.isEmpty {
                Text(item.message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(8)
        .background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var iconColor: Color {
        switch item.status {
        case .completed:
            return .green
        case .failed:
            return .orange
        case .cancelled:
            return .secondary
        case .reading, .uploading:
            return .accentColor
        }
    }
}

private enum WorkspaceTransferAction {
    case copy([WorkspaceItem])

    var title: String {
        switch self {
        case let .copy(items):
            items.count == 1 ? "Copy \(items[0].name)" : "Copy \(items.count) items"
        }
    }

    var buttonTitle: String {
        switch self {
        case .copy: "Copy"
        }
    }
}

private enum NewWorkspaceItemKind {
    case file
    case folder

    var title: String {
        switch self {
        case .file: "New file"
        case .folder: "New folder"
        }
    }
}

struct WorkspaceStorageMenuContent: View {
    @EnvironmentObject private var store: WorkspaceStore
    let path: String

    var body: some View {
        ForEach(WorkspaceStorageMode.allCases, id: \.self) { mode in
            Button { store.setStorageMode(path: path, mode: mode) } label: {
                Label(mode.title, systemImage: store.storageMode(path: path) == mode ? "checkmark" : mode.icon)
            }
        }
        if path.contains("/") {
            Divider()
            Button("상위 설정 따르기") { store.setStorageMode(path: path, mode: nil) }
            Button("로컬 유지") { store.setStorageMode(path: path, mode: .local, keepLocal: true) }
        }
    }
}

private struct FileSurfaceActiveKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var isFileSurfaceActive: Bool {
        get { self[FileSurfaceActiveKey.self] }
        set { self[FileSurfaceActiveKey.self] = newValue }
    }
}

/// Freeze inactive preview geometry too: a keyboard opened in Code must not
/// resize/refit the retained Notes PDF and change its reading position.
struct RetainedFileSurfaceView: View {
    let surface: String
    let isActive: Bool
    @State private var lastActiveSize = CGSize.zero

    var body: some View {
        GeometryReader { proxy in
            let size = isActive || lastActiveSize == .zero ? proxy.size : lastActiveSize
            FilePreviewView(surface: surface)
                .frame(width: size.width, height: size.height)
                .environment(\.isFileSurfaceActive, isActive)
                .disabled(!isActive)
                .onChange(of: proxy.size, initial: true) { _, size in
                    if isActive { lastActiveSize = size }
                }
                .onChange(of: isActive) { _, active in
                    if active { lastActiveSize = proxy.size }
                }
        }
        .opacity(isActive ? 1 : 0)
        .allowsHitTesting(isActive)
        .accessibilityHidden(!isActive)
    }
}

struct FilePreviewView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.isFileSurfaceActive) private var isActive
    var surface: String? = nil

    private var state: WorkspaceFileSurfaceState { store.fileSurfaceState(for: surface) }
    private var isDirty: Bool { state.file.map { $0.content != state.editorText } ?? false }
    private var editorBinding: Binding<String> {
        Binding(get: { state.editorText }, set: { if isActive { store.editorText = $0 } })
    }

    var body: some View {
        VStack(spacing: 0) {
            if let loadingFile = state.loadingFile {
                RawFileLoadingView(
                    item: loadingFile,
                    errorMessage: state.loadError,
                    retry: {
                        Task { await store.loadFile(loadingFile) }
                    }
                )
            } else if let rawFile = state.rawFile {
                if rawFile.kind == "pdf" {
                    if let session = rawFile.streamSession {
                        StreamedPDFWorkspaceHost(rawFile: rawFile, session: session)
                    } else {
                        PDFWorkspaceView(rawFile: rawFile)
                            .id(rawFile.url)
                    }
                } else if rawFile.kind == "image" {
                    AsyncImage(url: rawFile.url) { phase in
                        switch phase {
                        case let .success(image):
                            image
                                .resizable()
                                .scaledToFit()
                                .padding(20)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        case let .failure(error):
                            ContentUnavailableView("Could not load image", systemImage: "photo", description: Text(error.localizedDescription))
                        case .empty:
                            ProgressView()
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        @unknown default:
                            EmptyView()
                        }
                    }
                } else {
                    ContentUnavailableView("Raw preview unavailable", systemImage: "doc", description: Text(rawFile.path))
                }
            } else if let file = state.file {
                HStack(spacing: 12) {
                    if state.isEditing {
                        Button { store.undoEditorChange() } label: { Image(systemName: "chevron.left") }
                            .disabled(!state.history.canUndo).help("되돌리기").accessibilityLabel("되돌리기")
                        Button { store.redoEditorChange() } label: { Image(systemName: "chevron.right") }
                            .disabled(!state.history.canRedo).help("다시 실행").accessibilityLabel("다시 실행")
                        Button {
                            store.finishEditingSelectedFile()
                        } label: {
                            Label("미리보기", systemImage: "eye")
                        }
                        .buttonStyle(.borderless)
                        if !store.editorAutosaveError.isEmpty {
                            Button("저장 재시도") { Task { await store.saveSelectedFile() } }
                                .buttonStyle(.borderless)
                        } else if !isDirty {
                            Label("자동 저장됨", systemImage: "checkmark.circle")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Button {
                            store.startEditingSelectedFile()
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        .buttonStyle(.borderless)
                        .disabled(!store.selectedFileCanEdit)
                    }

                    if isDirty {
                        Label(store.editorAutosaveError.isEmpty ? "자동 저장 중…" : "저장되지 않음", systemImage: store.editorAutosaveError.isEmpty ? "clock" : "exclamationmark.circle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)

                if state.isEditing {
                    TextEditor(text: editorBinding)
                        .font(.system(.body, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(16)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        if file.kind == "markdown" {
                            RichMarkdownView(markdown: file.content)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(20)
                        } else if file.kind == "code" {
                            CodeFileRenderedView(language: languageForPath(file.path), code: file.content)
                                .padding(20)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Text(file.content)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(20)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ContentUnavailableView(
                    "파일 선택 또는 새로 만들기",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("자료는 이 기기에 저장됩니다. 서버를 연결하면 같은 계정의 다른 기기와 동기화합니다.")
                )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: isActive ? store.fileSurfaceRestoreID : nil) {
            if isActive, let surface { await store.restoreFileSurfaceIfNeeded(surface) }
        }
    }

}

private struct StreamedPDFWorkspaceHost: View {
    let rawFile: RawFilePreview
    @ObservedObject var session: StreamedPDFSession

    var body: some View {
        PDFWorkspaceView(
            rawFile: rawFile,
            streamSession: session,
            streamRevision: session.revision
        )
    }
}

private struct RawFileLoadingView: View {
    let item: WorkspaceItem
    let errorMessage: String?
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if let errorMessage {
                ContentUnavailableView {
                    Label("Could not open PDF", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button(action: retry) {
                        Label("Try Again", systemImage: "arrow.clockwise")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                    Text("Opening PDF...")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

}

struct CodeFileRenderedView: View {
    @EnvironmentObject private var store: WorkspaceStore
    let language: String?
    let code: String
    @State private var renderedHTML: String?
    @State private var webHeight: CGFloat = 120
    @State private var renderFailed = false

    var body: some View {
        Group {
            if let renderedHTML, !renderFailed {
                RenderedMarkdownWebView(html: renderedHTML, height: $webHeight)
                    .frame(minHeight: webHeight, maxHeight: webHeight)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                CodeBlockView(language: language, code: code)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: "\(language ?? ""):\(code.hashValue)") {
            await loadServerRenderedHTML()
        }
    }

    private func loadServerRenderedHTML() async {
        guard let api = store.api else {
            renderFailed = true
            renderedHTML = nil
            return
        }
        do {
            try await Task.sleep(nanoseconds: 150_000_000)
            let html = try await api.renderCode(code: code, language: language)
            guard !Task.isCancelled else { return }
            renderedHTML = html
            renderFailed = false
        } catch {
            guard !Task.isCancelled else { return }
            renderedHTML = nil
            renderFailed = true
        }
    }
}

private func languageForPath(_ path: String) -> String? {
    let lower = path.lowercased()
    let name = URL(fileURLWithPath: lower).lastPathComponent
    if name == "dockerfile" { return "dockerfile" }
    if name == "makefile" { return "makefile" }

    switch URL(fileURLWithPath: lower).pathExtension {
    case "py", "pyw": return "python"
    case "js", "mjs", "cjs": return "javascript"
    case "ts", "tsx": return "typescript"
    case "jsx": return "jsx"
    case "swift": return "swift"
    case "java": return "java"
    case "c", "h": return "c"
    case "cc", "cpp", "cxx", "hpp", "hh", "hxx": return "cpp"
    case "cs": return "csharp"
    case "kt", "kts": return "kotlin"
    case "rs": return "rust"
    case "go": return "go"
    case "rb": return "ruby"
    case "php": return "php"
    case "sh", "bash", "zsh": return "bash"
    case "sql": return "sql"
    case "json": return "json"
    case "yml", "yaml": return "yaml"
    case "html", "htm": return "html"
    case "css": return "css"
    case "md", "markdown": return "markdown"
    case "xml": return "xml"
    default: return nil
    }
}

#if os(macOS)
struct PDFPreviewView: NSViewRepresentable {
    let url: URL
    var focus: PDFDocumentFocus?
    var annotations: PDFAnnotationDocument? = nil

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .clear
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url {
            view.document = PDFDocument(url: url)
        }
        applyCodmesInkAnnotations(to: view.document, annotations: annotations)
        if let pageNumber = focus?.page,
           let page = view.document?.page(at: max(0, pageNumber - 1)) {
            view.go(to: page)
        }
    }

    private func applyCodmesInkAnnotations(to document: PDFDocument?, annotations: PDFAnnotationDocument?) {
        guard let document else { return }
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for annotation in page.annotations where annotation.contents == "codmes-ink-preview" {
                page.removeAnnotation(annotation)
            }
        }
        guard let annotations else { return }
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            let strokes = annotations.noteStrokes(pageIndex: pageIndex)
            guard !strokes.isEmpty else { continue }
            let pageBounds = page.bounds(for: .mediaBox)
            let ink = PDFAnnotation(bounds: pageBounds, forType: .ink, withProperties: nil)
            ink.contents = "codmes-ink-preview"
            ink.color = .clear
            for stroke in strokes {
                guard stroke.points.count > 1 else { continue }
                let path = NSBezierPath()
                let first = stroke.points[0]
                path.move(to: NSPoint(
                    x: pageBounds.minX + pageBounds.width * first.x,
                    y: pageBounds.minY + pageBounds.height * (1 - first.y)
                ))
                for point in stroke.points.dropFirst() {
                    path.line(to: NSPoint(
                        x: pageBounds.minX + pageBounds.width * point.x,
                        y: pageBounds.minY + pageBounds.height * (1 - point.y)
                    ))
                }
                path.lineWidth = max(0.5, stroke.width)
                ink.add(path)
            }
            page.addAnnotation(ink)
        }
    }
}
#endif

#if os(iOS)
struct PDFPreviewView: UIViewRepresentable {
    let url: URL
    var focus: PDFDocumentFocus?

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url {
            view.document = PDFDocument(url: url)
        }
        if let pageNumber = focus?.page,
           let page = view.document?.page(at: max(0, pageNumber - 1)) {
            view.go(to: page)
        }
    }
}
#endif
