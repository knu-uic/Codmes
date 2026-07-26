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
    @State private var expandedFolderPaths: Set<String>
    @State private var dropTargetPath: String?
    @State private var selectedTreePaths: Set<String> = []
    @State private var isSelectingItems = false

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
        _expandedFolderPaths = State(initialValue: Self.savedExpandedFolders(root: root))
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsHeader {
                HeaderView(title: title, subtitle: headerSubtitle)
            }
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

                Button {
                    store.selectFolder(root: root, item: nil)
                } label: {
                    Image(systemName: "house")
                }
                .buttonStyle(.plain)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
                .foregroundStyle(dropTargetPath == workspaceRootName ? Color.accentColor : Color.primary)
                .help("Use root folder")

                Text(store.currentPath(for: root).isEmpty ? "/" : store.currentPath(for: root))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()
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

            UploadStatusPanel(root: root)

            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(visibleTreeEntries) { entry in
                        treeRowWithContextMenu(entry)
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
                        await store.createFile(root: root, name: name)
                    case .folder:
                        await store.createFolder(root: root, name: name)
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
                        await store.renameItem(root: root, item: item, newName: name)
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
                        await store.copyItems(root: root, items: items, destinationFolder: destination)
                        clearTreeSelection()
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
        .task {
            revealSelectedFile()
            if root == "code" {
                await store.refreshCodeTasks()
            }
        }
        .onChange(of: selectedFilePath) { _, _ in
            revealSelectedFile()
        }
        .onChange(of: store.items(for: root)) { _, items in
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

    private var newItemBinding: Binding<Bool> {
        Binding(
            get: { newItemKind != nil },
            set: { if !$0 { newItemKind = nil } }
        )
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

    @ViewBuilder
    private func treeRowWithContextMenu(_ entry: FileTreeEntry) -> some View {
        treeRow(entry)
            .contextMenu {
                itemManagementMenu(entry.item)
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

            Button {
                if isSelectingItems {
                    toggleTreeSelection(item)
                } else if item.isDirectory {
                    store.selectFolder(root: root, item: item)
                    toggleFolder(item)
                } else {
                    open(item)
                }
            } label: {
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
                }
                .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                itemManagementMenu(item)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.bold))
                    .foregroundStyle(Color.primary.opacity(0.82))
                    .frame(width: 28, height: 30)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .tint(.primary)
        }
        .contentShape(Rectangle())
        .draggable(dragItem(for: item)) {
            Label(dragPreviewTitle(for: item), systemImage: dragPreviewIcon(for: item))
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }

        if item.isDirectory {
            row.dropDestination(for: FileTreeDragItem.self, action: { items, _ in
                moveDraggedItems(items.first?.paths ?? [], into: item)
            }, isTargeted: { isTargeted in
                if isTargeted {
                    dropTargetPath = item.path
                } else if dropTargetPath == item.path {
                    dropTargetPath = nil
                }
            })
        } else {
            row
        }
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
            await store.moveTreeItems(root: root, sourcePaths: sourcePaths, into: folder)
            clearTreeSelection()
        }
        return true
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
        UserDefaults.standard.set(Array(expandedFolderPaths).sorted(), forKey: Self.expandedFoldersKey(root: root))
    }

    private static func savedExpandedFolders(root: String) -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: expandedFoldersKey(root: root)) ?? [])
    }

    private static func expandedFoldersKey(root: String) -> String {
        "codmes.fileTree.expanded.\(root)"
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

private struct FileTreeDragItem: Codable, Transferable, Sendable {
    let paths: [String]

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .codmesWorkspaceItem)
    }
}

private extension UTType {
    static let codmesWorkspaceItem = UTType(exportedAs: "com.codmes.workspace-item")
}


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

struct FilePreviewView: View {
    @EnvironmentObject private var store: WorkspaceStore

    var body: some View {
        VStack(spacing: 0) {
            if let loadingFile = store.loadingRawFile {
                RawFileLoadingView(
                    item: loadingFile,
                    errorMessage: store.rawFileLoadError,
                    retry: {
                        Task { await store.loadFile(loadingFile) }
                    }
                )
            } else if let rawFile = store.selectedRawFile {
#if os(macOS)
                HeaderView(title: rawFile.name, subtitle: rawFile.path)
#endif
                if rawFile.kind == "pdf" {
                    if let session = rawFile.streamSession {
                        StreamedPDFWorkspaceHost(rawFile: rawFile, session: session)
                    } else {
                        PDFWorkspaceView(rawFile: rawFile)
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
            } else if let file = store.selectedFile {
#if os(macOS)
                HeaderView(title: file.name, subtitle: file.path)
#endif
                HStack(spacing: 12) {
                    if store.isEditingFile {
                        Button {
                            Task { await store.saveSelectedFile() }
                        } label: {
                            Label("Save", systemImage: "square.and.arrow.down")
                        }
                        .buttonStyle(.borderless)
                        .disabled(!store.selectedFileIsDirty)

                        Button {
                            store.cancelEditingSelectedFile()
                        } label: {
                            Label("Cancel", systemImage: "xmark.circle")
                        }
                        .buttonStyle(.borderless)
                    } else {
                        Button {
                            store.startEditingSelectedFile()
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        .buttonStyle(.borderless)
                        .disabled(!store.selectedFileCanEdit)
                    }

                    if store.selectedFileIsDirty {
                        Label("Unsaved changes", systemImage: "circle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)

                if store.isEditingFile {
                    TextEditor(text: $store.editorText)
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
                ContentUnavailableView("Select a file", systemImage: "doc.text.magnifyingglass", description: Text("Open a markdown or text file from the tree."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
#if os(macOS)
            HeaderView(title: item.name, subtitle: item.path)
#endif
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
