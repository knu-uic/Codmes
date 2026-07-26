import SwiftUI
#if os(macOS)
import AppKit
#endif

@main
struct CodmesApp: App {
    @StateObject private var store = WorkspaceStore()

    var body: some Scene {
        #if os(macOS)
        WindowGroup("", id: "codmes-main-window-v2") {
            rootView
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1120, height: 740)
        #else
        WindowGroup {
            rootView
        }
        #endif
    }

    private var rootView: some View {
        RootView()
            .environmentObject(store)
            .tint(.secondary)
            #if os(macOS)
            .background(MacWindowConfigurator())
            .onAppear {
                activateMacAppWindow()
            }
            #endif
            .task {
                await store.refreshWorkspace()
            }
            .onOpenURL { url in
                guard url.pathExtension.lowercased() == "codmespdf" else { return }
                Task {
                    await store.importLocalFiles(root: "notes", fileURLs: [url])
                }
            }
    }
}

#if os(macOS)
private struct MacWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            configureMacWindow(nsView.window)
        }
    }
}

@MainActor
func configureMacWindow(_ window: NSWindow?) {
    guard let window else { return }
    window.styleMask.insert(.resizable)
    window.minSize = NSSize(width: 640, height: 420)
    window.title = ""
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.toolbarStyle = .unified
}

@MainActor
private func activateMacAppWindow() {
    NSApp.setActivationPolicy(.regular)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
        let window = NSApp.windows
            .filter({ $0.isVisible && $0.styleMask.contains(.titled) })
            .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
        configureMacWindow(window)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
#endif
