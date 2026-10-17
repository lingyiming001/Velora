import AppKit
import SwiftUI

struct DocumentKeyboardCapture: NSViewRepresentable {
    var selected: Bool
    var selectAll: () -> Void
    var delete: () -> Void
    var escape: () -> Void
    var boundary: (Bool, Bool) -> Void
    func makeNSView(context: Context) -> DocumentSelectionView { DocumentSelectionView() }
    func updateNSView(_ view: DocumentSelectionView, context: Context) {
        view.selectAll = selectAll; view.delete = delete; view.escape = escape; view.boundary = boundary
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
    var escape: () -> Void = {}
    var boundary: (Bool, Bool) -> Void = { _, _ in }
    override var acceptsFirstResponder: Bool { true }
    override func selectAll(_ sender: Any?) { selectAll() }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "a" { selectAll(); return }
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
