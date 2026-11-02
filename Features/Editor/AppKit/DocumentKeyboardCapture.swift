import AppKit
import PDFKit
import SwiftUI

struct DocumentKeyboardCapture: NSViewRepresentable {
    var selected: Bool
    var selectAll: () -> Void
    var delete: () -> Void
    var copy: () -> Void
    var escape: () -> Void
    var insertAfter: () -> Void
    var boundary: (Bool, Bool) -> Void
    func makeNSView(context: Context) -> DocumentSelectionView { DocumentSelectionView() }
    func updateNSView(_ view: DocumentSelectionView, context: Context) {
        view.selectAll = selectAll; view.delete = delete; view.copy = copy; view.escape = escape; view.insertAfter = insertAfter; view.boundary = boundary
        view.selectionActive = selected
        if selected {
            DispatchQueue.main.async {
                guard view.selectionActive, let window = view.window,
                      !((window.firstResponder as? NSTextView)?.isFieldEditor ?? false), window.firstResponder !== view else { return }
                window.makeFirstResponder(view)
            }
        }
    }
}

final class DocumentSelectionView: NSView {
    private static let instances = NSHashTable<DocumentSelectionView>.weakObjects()
    private var keyboardMonitor: Any?
    /// A text view may regain first responder during SwiftUI focus updates.
    /// Resolve the active document selection before copying its local text range.
    static func copySelection(in window: NSWindow?, cutting: Bool = false) -> Bool {
        guard let window, window.attachedSheet == nil,
              let owner = instances.allObjects.first(where: { $0.window === window && $0.selectionActive }) else { return false }
        // Title/search/native text fields own their own selection. A stale
        // document block selection must never intercept their Copy/Cut actions.
        if (window.firstResponder as? NSTextView)?.isFieldEditor == true { return false }
        owner.copy()
        if cutting { owner.delete() }
        return true
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        Self.instances.add(self)
        if let keyboardMonitor { NSEvent.removeMonitor(keyboardMonitor); self.keyboardMonitor = nil }
        guard window != nil else { return }
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.selectionActive, event.window === self.window,
                  event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command,
                  let key = event.charactersIgnoringModifiers?.lowercased(), ["c", "x"].contains(key),
                  Self.copySelection(in: self.window, cutting: key == "x") else { return event }
            return nil
        }
    }
    deinit { if let keyboardMonitor { NSEvent.removeMonitor(keyboardMonitor) } }
    var selectionActive = false
    var selectAll: () -> Void = {}
    var delete: () -> Void = {}
    var copy: () -> Void = {}
    var escape: () -> Void = {}
    var insertAfter: () -> Void = {}
    var boundary: (Bool, Bool) -> Void = { _, _ in }
    override var acceptsFirstResponder: Bool { true }
    override func selectAll(_ sender: Any?) { selectAll() }
    @objc func copy(_ sender: Any?) { copy() }
    @objc func cut(_ sender: Any?) { copy(); delete() }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "a" { selectAll(); return }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "c" { copy(); return }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "x" { copy(); delete(); return }
        if [51, 117].contains(event.keyCode) { delete(); return }
        if event.keyCode == 53 { escape(); return }
        if [36, 76].contains(event.keyCode), event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
            insertAfter(); return
        }
        if event.modifierFlags.contains(.command), [125, 126].contains(event.keyCode) {
            boundary(event.keyCode == 126, event.modifierFlags.contains(.shift)); return
        }
        if event.modifierFlags.contains(.control), [115, 119].contains(event.keyCode) {
            boundary(event.keyCode == 115, event.modifierFlags.contains(.shift)); return
        }
        super.keyDown(with: event)
    }
}

/// Non-interactive row geometry lets a page-level drag cross native text views,
/// WebKit previews and media without placing an input-blocking overlay on them.
struct DocumentBlockSelectionAnchor: NSViewRepresentable {
    let blockID: UUID
    func makeNSView(context: Context) -> DocumentBlockSelectionAnchorView {
        let view = DocumentBlockSelectionAnchorView()
        view.blockID = blockID
        return view
    }
    func updateNSView(_ view: DocumentBlockSelectionAnchorView, context: Context) { view.blockID = blockID }
}

final class DocumentBlockSelectionAnchorView: NSView {
    static let visibleAnchors = NSHashTable<DocumentBlockSelectionAnchorView>.weakObjects()
    var blockID: UUID?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { Self.visibleAnchors.add(self) }
        else { Self.visibleAnchors.remove(self) }
    }
}

struct DocumentRangeSelectionCapture: NSViewRepresentable {
    let documentID: UUID
    var begin: (UUID) -> Void
    var selectRange: (UUID, UUID) -> Void
    var modifiedClick: (UUID, NSEvent.ModifierFlags) -> Bool
    func makeNSView(context: Context) -> DocumentRangeSelectionView { DocumentRangeSelectionView() }
    func updateNSView(_ view: DocumentRangeSelectionView, context: Context) {
        if view.documentID != documentID { view.endDrag() }
        view.documentID = documentID
        view.begin = begin; view.selectRange = selectRange; view.modifiedClick = modifiedClick
    }
    static func dismantleNSView(_ view: DocumentRangeSelectionView, coordinator: ()) { view.stopMonitoring() }
}

final class DocumentRangeSelectionView: NSView {
    private static let activeCaptures = NSHashTable<DocumentRangeSelectionView>.weakObjects()
    var documentID: UUID?
    var begin: (UUID) -> Void = { _ in }
    var selectRange: (UUID, UUID) -> Void = { _, _ in }
    var modifiedClick: (UUID, NSEvent.ModifierFlags) -> Bool = { _, _ in false }
    private var monitor: Any?
    private var anchorID: UUID?
    private var startPoint = NSPoint.zero
    private var pointerStart = NSPoint.zero
    private var lastDragPoint: NSPoint?
    private(set) var selectingBlocks = false
    private var scrollTimer: Timer?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoring()
        guard window != nil else { return }
        Self.activeCaptures.add(self)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown]) { [weak self] event in
            guard let self else { return event }
            return self.route(event)
        }
    }
    func stopMonitoring() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        Self.activeCaptures.remove(self)
        endDrag()
    }
    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        scrollTimer?.invalidate()
    }

    func endDrag() {
        anchorID = nil; selectingBlocks = false; lastDragPoint = nil
        scrollTimer?.invalidate(); scrollTimer = nil
    }

    static func finishNativeTracking(in window: NSWindow, at location: NSPoint) {
        for capture in activeCaptures.allObjects where capture.window === window {
            // Accessibility clicks need not move the physical pointer. A click
            // alone must not select the rows between it and an old pointer position.
            let moved = hypot(location.x - capture.pointerStart.x, location.y - capture.pointerStart.y) >= 5
            if let endpoint = moved ? location : capture.lastDragPoint { capture.finishNativeTracking(at: endpoint) }
            else if NSEvent.pressedMouseButtons & 1 == 0 { capture.endDrag() }
        }
    }

    func finishNativeTracking(at location: NSPoint) {
        guard anchorID != nil, let window else { return }
        if let event = NSEvent.mouseEvent(with: .leftMouseDragged, location: location, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { _ = route(event) }
        if NSEvent.pressedMouseButtons & 1 == 0 { endDrag() }
    }

    private func startScrollTimer() {
        guard scrollTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            guard let self, self.anchorID != nil, let window = self.window else { return }
            // NSTextView consumes drag events in its own tracking loop. Polling
            // in that mode also covers stationary edge scrolling and WebKit.
            guard NSEvent.pressedMouseButtons & 1 != 0 else {
                self.scrollTimer?.invalidate(); self.scrollTimer = nil
                return
            }
            let pointer = window.mouseLocationOutsideOfEventStream
            guard self.selectingBlocks || hypot(pointer.x - self.pointerStart.x, pointer.y - self.pointerStart.y) >= 5 else { return }
            guard let event = NSEvent.mouseEvent(with: .leftMouseDragged, location: pointer,
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1) else { return }
            _ = self.route(event)
            _ = self.autoscrollSelection(with: event)
        }
        scrollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
    }

    func route(_ event: NSEvent) -> NSEvent? {
        guard let window, event.window === window, let page = enclosingScrollView else { return event }
        if event.type == .keyDown {
            if event.keyCode == 53 { endDrag() }
            return event
        }
        if event.type == .leftMouseDown {
            endDrag()
            guard let root = window.contentView,
                  page.visibleRect.contains(page.convert(event.locationInWindow, from: nil)),
                  let hit = root.hitTest(root.convert(event.locationInWindow, from: nil)),
                  !isControl(hit, inside: page, at: event.locationInWindow),
                  let row = row(at: event.locationInWindow, in: page, requireInside: true) else { return event }
            if modifiedClick(row, event.modifierFlags) { return nil }
            guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return event }
            anchorID = row; startPoint = event.locationInWindow
            pointerStart = window.mouseLocationOutsideOfEventStream
            begin(row)
            startScrollTimer()
            return event
        }
        if event.type == .leftMouseUp {
            if selectingBlocks { updateRange(with: event, in: page) }
            endDrag()
            // Native NSTextView mouse tracking still needs its matching mouse-up.
            return event
        }
        guard event.type == .leftMouseDragged, let anchorID,
              selectingBlocks || hypot(event.locationInWindow.x - startPoint.x, event.locationInWindow.y - startPoint.y) >= 5,
              let endpoint = row(at: event.locationInWindow, in: page, requireInside: false) else { return event }
        guard selectingBlocks || endpoint != anchorID else { return event }
        selectingBlocks = true
        lastDragPoint = event.locationInWindow
        selectRange(anchorID, endpoint)
        return nil
    }

    private func updateRange(with event: NSEvent, in page: NSScrollView) {
        guard let anchorID, let endpoint = row(at: event.locationInWindow, in: page, requireInside: false) else { return }
        selectRange(anchorID, endpoint)
    }

    @discardableResult
    func autoscrollSelection(with event: NSEvent) -> Bool {
        guard selectingBlocks, let page = enclosingScrollView, page.contentView.autoscroll(with: event) else { return false }
        updateRange(with: event, in: page)
        return true
    }

    private func row(at location: NSPoint, in page: NSScrollView, requireInside: Bool) -> UUID? {
        guard let document = page.documentView else { return nil }
        let point = document.convert(location, from: nil)
        let rows = DocumentBlockSelectionAnchorView.visibleAnchors.allObjects.compactMap { anchor -> (UUID, NSRect)? in
            guard let id = anchor.blockID, anchor.window === window, anchor.enclosingScrollView === page,
                  !anchor.isHiddenOrHasHiddenAncestor, anchor.bounds.height > 0 else { return nil }
            return (id, anchor.convert(anchor.bounds, to: document))
        }
        if let hit = rows.first(where: { $0.1.contains(point) }) { return hit.0 }
        guard !requireInside else { return nil }
        return rows.min { distance(point.y, to: $0.1) < distance(point.y, to: $1.1) }?.0
    }

    private func distance(_ y: CGFloat, to rect: NSRect) -> CGFloat { max(rect.minY - y, y - rect.maxY, 0) }

    private func isControl(_ hit: NSView, inside page: NSScrollView, at location: NSPoint) -> Bool {
        var view: NSView? = hit
        while let current = view, current !== page {
            if current is NSControl, !(current is NSImageView) { return true }
            view = current.superview
        }
        // Some scroll/hosting views return the container rather than the leaf
        // during tracking. Check visible native control geometry as well.
        func containsControl(_ view: NSView) -> Bool {
            guard !view.isHiddenOrHasHiddenAncestor, view.alphaValue > 0.01,
                  view.bounds.contains(view.convert(location, from: nil)) else { return false }
            if view is NSControl, !(view is NSImageView) { return true }
            return view.subviews.contains(where: containsControl)
        }
        return page.documentView.map(containsControl) ?? false
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
