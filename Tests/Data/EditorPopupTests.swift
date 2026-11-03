import AppKit
import SwiftUI
import XCTest
@testable import Velora

@MainActor
final class EditorPopupTests: XCTestCase {
    func testEscapeAndOutsideClickDismissWithoutChangingEditorFocus() async throws {
        _ = NSApplication.shared
        for escape in [true, false] {
            let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 500),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let anchor = EditorPopupAnchor(frame: NSRect(x: 30, y: 400, width: 200, height: 30))
            window.contentView?.addSubview(anchor)
            window.makeKeyAndOrderFront(nil)
            let coordinator = EditorCommandPopup<Text>.Coordinator()
            coordinator.anchor = anchor
            var dismissed = false
            coordinator.update(Text("No matching block types"), onDismiss: { dismissed = true })
            for _ in 0..<30 where window.childWindows?.isEmpty != false {
                try await Task.sleep(for: .milliseconds(10))
            }
            let panel = try XCTUnwrap(window.childWindows?.first as? EditorPopupPanel)
            XCTAssertTrue(panel.isVisible)
            let event: NSEvent
            if escape {
                event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                    timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                    charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
            } else {
                event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 500, y: 450),
                    modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            }
            NSApplication.shared.sendEvent(event)
            XCTAssertTrue(dismissed)
            XCTAssertFalse(panel.isVisible)
            XCTAssertNil(panel.parent)
            coordinator.schedulePosition()
            try await Task.sleep(for: .milliseconds(20))
            XCTAssertFalse(panel.isVisible, "Pending layout must not reopen a dismissed popup")
            coordinator.close()
            window.close()
        }
    }

    func testCoordinatorReleaseClosesChildWindow() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let anchor = EditorPopupAnchor(frame: NSRect(x: 30, y: 400, width: 200, height: 30))
        window.contentView?.addSubview(anchor)
        window.makeKeyAndOrderFront(nil)
        var coordinator: EditorCommandPopup<Text>.Coordinator? = .init()
        coordinator?.anchor = anchor
        coordinator?.update(Text("Menu"), onDismiss: {})
        for _ in 0..<30 where window.childWindows?.isEmpty != false {
            try await Task.sleep(for: .milliseconds(10))
        }
        let panel = try XCTUnwrap(window.childWindows?.first)
        coordinator = nil
        XCTAssertFalse(panel.isVisible)
        XCTAssertNil(panel.parent)
    }
}
