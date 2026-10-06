#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import Codmes

@MainActor
final class MacSlidingPaneTests: XCTestCase {
    private final class Probe {
        var creations = 0
        var removals = 0
        var updateAnimations: [Bool] = []
        weak var view: NSView?
    }

    private struct ContentProbe: NSViewRepresentable {
        let probe: Probe

        func makeNSView(context: Context) -> NSView {
            probe.creations += 1
            let view = NSView()
            probe.view = view
            return view
        }

        func updateNSView(_ nsView: NSView, context: Context) {
            probe.updateAnimations.append(context.transaction.animation != nil)
        }

        func makeCoordinator() -> Probe { probe }

        static func dismantleNSView(_ nsView: NSView, coordinator: Probe) {
            coordinator.removals += 1
        }
    }

    func testBothEdgesKeepContentMountedAndAtFullWidthWhileCollapsed() async throws {
        for edge: HorizontalEdge in [.leading, .trailing] {
            let probe = Probe()
            func pane(_ visible: Bool) -> some View {
                MacSlidingPane(isVisible: visible, width: 280, edge: edge) {
                    ContentProbe(probe: probe)
                }
                .frame(height: 200)
                .animation(.easeInOut(duration: 0.01), value: visible)
            }
            let host = NSHostingView(rootView: pane(true))
            host.frame = NSRect(x: 0, y: 0, width: 281, height: 200)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
            host.layoutSubtreeIfNeeded()
            let content = try XCTUnwrap(probe.view)
            XCTAssertEqual(probe.creations, 1)
            XCTAssertEqual(content.frame.width, 280, accuracy: 1)
            XCTAssertEqual(host.fittingSize.width, 281, accuracy: 1)

            for visible in [false, true, false, true] {
                host.rootView = pane(visible)
                try await Task.sleep(for: .milliseconds(30))
                host.layoutSubtreeIfNeeded()
                XCTAssertEqual(probe.creations, 1, "Toggling must not recreate the header/body")
                XCTAssertEqual(probe.removals, 0)
                XCTAssertTrue(probe.view === content)
                XCTAssertEqual(content.frame.width, 280, accuracy: 1, "Hidden controls must not reflow into a zero-width layout")
                XCTAssertEqual(host.fittingSize.width, visible ? 281 : 0, accuracy: 1)
            }
            XCTAssertFalse(probe.updateAnimations.contains(true), "Native controls must not inherit a separate animation from the reveal frame")
        }
    }
}
#endif
