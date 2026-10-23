import AppKit
import PDFKit
import SwiftUI

struct DocumentKeyboardCapture: NSViewRepresentable {
    var selected: Bool
    var selectAll: () -> Void
    var delete: () -> Void
    var copy: () -> Void
    var escape: () -> Void
    var boundary: (Bool, Bool) -> Void
    func makeNSView(context: Context) -> DocumentSelectionView { DocumentSelectionView() }
    func updateNSView(_ view: DocumentSelectionView, context: Context) {
        view.selectAll = selectAll; view.delete = delete; view.copy = copy; view.escape = escape; view.boundary = boundary
        view.selectionActive = selected
        if selected {
            DispatchQueue.main.async { if view.selectionActive, view.window?.firstResponder !== view { view.window?.makeFirstResponder(view) } }
        }
    }
}

final class DocumentSelectionView: NSView {
    var selectionActive = false
    var selectAll: () -> Void = {}
    var delete: () -> Void = {}
    var copy: () -> Void = {}
    var escape: () -> Void = {}
    var boundary: (Bool, Bool) -> Void = { _, _ in }
    override var acceptsFirstResponder: Bool { true }
    override func selectAll(_ sender: Any?) { selectAll() }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "a" { selectAll(); return }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "c" { copy(); return }
        if [51, 117].contains(event.keyCode) { delete(); return }
        if event.keyCode == 53 { escape(); return }
        if event.modifierFlags.contains(.command), [125, 126].contains(event.keyCode) {
            boundary(event.keyCode == 126, event.modifierFlags.contains(.shift)); return
        }
        if event.modifierFlags.contains(.control), [115, 119].contains(event.keyCode) {
            boundary(event.keyCode == 115, event.modifierFlags.contains(.shift)); return
        }
        super.keyDown(with: event)
    }
}

/// Auto-sized blocks may host their own AppKit/WebKit scroll views. Route vertical
/// wheel gestures to the page rather than letting those nested views consume them.
struct DocumentScrollCapture: NSViewRepresentable {
    func makeNSView(context: Context) -> DocumentScrollRoutingView { DocumentScrollRoutingView() }
    func updateNSView(_ view: DocumentScrollRoutingView, context: Context) { }
    static func dismantleNSView(_ view: DocumentScrollRoutingView, coordinator: ()) { view.stopMonitoring() }
}

final class DocumentScrollRoutingView: NSView {
    private var monitor: Any?
    private var verticalGesture = false

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoring()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let target = self.scrollTarget(for: event) else { return event }
            target.scrollWheel(with: event)
            return nil
        }
    }
    func stopMonitoring() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil; verticalGesture = false
    }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }

    func scrollTarget(for event: NSEvent) -> NSScrollView? {
        guard event.type == .scrollWheel, let window, event.window === window,
              let page = enclosingScrollView, let root = window.contentView,
              let hit = root.hitTest(root.convert(event.locationInWindow, from: nil)) else { return nil }
        return verticalScrollTarget(for: event, hit: hit, page: page)
    }

    func verticalScrollTarget(for event: NSEvent, hit: NSView, page: NSScrollView) -> NSScrollView? {
        guard event.type == .scrollWheel, hit === page || hit.isDescendant(of: page) else { return nil }
        let x = abs(event.scrollingDeltaX), y = abs(event.scrollingDeltaY)
        if x > 0 || y > 0 { verticalGesture = y >= x && y > 0 }
        guard verticalGesture else { return nil }
        // PDF originals have real pages inside their own viewer. Let it scroll
        // while there is room, then continue into the enclosing document.
        var ancestor: NSView? = hit
        var nestedScroll: NSScrollView?
        var insidePDF = false
        while let view = ancestor, view !== page {
            if nestedScroll == nil { nestedScroll = view as? NSScrollView }
            if view is PDFView { insidePDF = true }
            ancestor = view.superview
        }
        if insidePDF, let nestedScroll, Self.canScroll(nestedScroll, delta: event.scrollingDeltaY) { return nil }
        return page
    }

    static func canScroll(_ scroll: NSScrollView, delta: CGFloat) -> Bool {
        guard let document = scroll.documentView else { return false }
        let visible = scroll.contentView.bounds
        let limit = max(0, document.bounds.height - visible.height)
        guard limit > 1 else { return false }
        let offset = document.isFlipped ? visible.minY : limit - visible.minY
        return delta < 0 ? offset < limit - 1 : delta > 0 ? offset > 1 : true
    }
}
