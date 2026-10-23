import AppKit
import SwiftUI

struct NativeTextEditor: NSViewRepresentable {
    var text: String
    var font: NSFont
    var formatting: [TextStyleRun] = []
    var onRichChange: ((String, [TextStyleRun]) -> Void)? = nil
    var onMarkdownHeading: ((String, [TextStyleRun], NSRange) -> Bool)? = nil
    var onHeadingShortcut: ((Int, String, [TextStyleRun], NSRange) -> Bool)? = nil
    var onSelectAllBlocks: () -> Bool = { false }
    var onDeleteBlocks: () -> Bool = { false }
    var onDocumentBoundary: (Bool, Bool) -> Bool = { _, _ in false }
    var onBlockMouseDown: (NSEvent.ModifierFlags) -> Bool = { _ in false }
    var onPasteDocument: ((String?, String?, String, [TextStyleRun], NSRange) -> Bool)? = nil
    var codeLanguage: String? = nil
    var sanitizePastedLaTeX = false
    var showCodeLineNumbers = true
    var darkCode = false
    var focusRequest: EditorFocusRequest? = nil
    var isFocusRequestCurrent: (UUID) -> Bool = { _ in true }
    var contentRevision: UInt64 = 0
    var onExitBlock: () -> Bool = { false }
    var onBackspaceAtStart: () -> Bool = { false }
    var onCommand: (Selector, String) -> Bool = { _, _ in false }
    var onFocus: (Bool) -> Void = { _ in }
    var onHeightChange: (CGFloat) -> Void = { _ in }
    var onChange: (String) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalRuler = false
        scrollView.hasVerticalRuler = false
        scrollView.rulersVisible = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        let view = CodeTextView(frame: NSRect(origin: .zero, size: scrollView.contentSize))
        view.delegate = context.coordinator
        view.isRichText = true
        view.importsGraphics = false
        view.isAutomaticLinkDetectionEnabled = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.drawsBackground = false
        view.showsLineNumbers = codeLanguage != nil && showCodeLineNumbers
        view.textContainer?.lineFragmentPadding = codeLanguage == nil ? 0 : 5
        view.textContainerInset = NSSize(width: codeLanguage != nil && showCodeLineNumbers ? 44 : codeLanguage != nil ? 18 : 0, height: 4)
        view.autoresizingMask = [.width]
        view.minSize = NSSize(width: 0, height: 0)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.font = font
        view.textStorage?.setAttributedString(RichTextFormatting.attributed(text, runs: formatting, base: font))
        context.coordinator.lastAppliedRuns = formatting
        context.coordinator.lastBaseFont = font
        configureCallbacks(view, coordinator: context.coordinator)
        scrollView.documentView = view
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let view = scrollView.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        if let codeView = view as? CodeTextView {
            codeView.showsLineNumbers = codeLanguage != nil && showCodeLineNumbers
            codeView.textContainerInset.width = codeLanguage != nil && showCodeLineNumbers ? 44 : codeLanguage != nil ? 18 : 0
        }
        if let codeView = view as? CodeTextView { configureCallbacks(codeView, coordinator: context.coordinator) }
        context.coordinator.synchronize(view)
        context.coordinator.style(view)
        let coordinator = context.coordinator
        coordinator.pendingUpdate?.cancel()
        let update = DispatchWorkItem { [weak coordinator, weak view] in
            guard let coordinator, coordinator.isActive, let view else { return }
            coordinator.measure(view)
            coordinator.applyFocus(to: view)
        }
        coordinator.pendingUpdate = update
        DispatchQueue.main.async(execute: update)
    }

    private func configureCallbacks(_ view: CodeTextView, coordinator: Coordinator) {
        view.focusWhenAttached = { [weak coordinator, weak view] in
            if let view { coordinator?.applyFocus(to: view) }
        }
        view.focusChanged = { [weak coordinator] focused in
            guard let coordinator, coordinator.isActive else { return }
            coordinator.parent.onFocus(focused)
        }
        view.selectAllDocument = { [weak coordinator] in coordinator?.formatPopover.close(); return onSelectAllBlocks() }
        view.deleteDocumentSelection = { [weak coordinator] in
            let handled = onDeleteBlocks(); if handled { coordinator?.formatPopover.close() }; return handled
        }
        view.copySelectionAsText = codeLanguage != nil
        view.pasteDocument = codeLanguage == nil ? { [weak view] plain, html, original, selection in
            guard let view else { return false }
            return onPasteDocument?(plain, html, original, RichTextFormatting.runs(view.attributedString(), base: font), selection) ?? false
        } : nil
        view.pasteTransform = sanitizePastedLaTeX ? { plain, html in
            ClipboardDocument.equationPaste(plain: plain, html: html)
        } : nil
        view.headingShortcut = { [weak view] level in
            guard let view else { return false }
            return onHeadingShortcut?(level, view.string, RichTextFormatting.runs(view.attributedString(), base: font), view.selectedRange()) ?? false
        }
        view.exitBlock = onExitBlock
        view.documentBoundary = onDocumentBoundary
        view.blockMouseDown = onBlockMouseDown
        view.formatSelection = { [weak coordinator, weak view] action in
            if let view { coordinator?.applyFormat(action, to: view) }
        }
    }

    static func dismantleNSView(_ view: NSScrollView, coordinator: Coordinator) {
        coordinator.isActive = false
        coordinator.pendingUpdate?.cancel()
        coordinator.pendingUpdate = nil
        (view.documentView as? NSTextView)?.delegate = nil
        coordinator.formatPopover.close()
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var isActive = true
        var pendingUpdate: DispatchWorkItem?
        var lastFocusRequest: UUID?
        var parent: NativeTextEditor
        var lastAppliedRuns: [TextStyleRun] = []
        var lastBaseFont: NSFont?
        private var lastModelText: String
        private var lastModelFormatting: [TextStyleRun]
        private var lastContentRevision: UInt64
        private var nativeEdits: [(String, [TextStyleRun])] = []
        let formatPopover = NSPopover()
        private var displayedStyle: InlineTextStyle?
        private var formatState: SelectionFormatState?
        var styleClipboard: TextStyleClipboard = .shared
        private var savedSelection = NSRange(location: 0, length: 0)
        private var applyingFormat = false
        init(parent: NativeTextEditor) {
            self.parent = parent
            lastModelText = parent.text
            lastModelFormatting = parent.formatting
            lastContentRevision = parent.contentRevision
        }

        func applyFocus(to view: NSTextView) {
            guard isActive, let request = parent.focusRequest, lastFocusRequest != request.id,
                  parent.isFocusRequestCurrent(request.id), let window = view.window else { return }
            guard window.makeFirstResponder(view), window.firstResponder === view else { return }
            lastFocusRequest = request.id
            view.setSelectedRange(NSRange(location: min(request.offset, view.string.utf16.count), length: 0))
            view.scrollRangeToVisible(view.selectedRange())
        }

        func synchronize(_ view: NSTextView) {
            guard !view.hasMarkedText(), parent.contentRevision >= lastContentRevision else { return }
            // Focus/height updates can carry the last model snapshot while the
            // native editor has already accepted the next keystroke. Never
            // replay that unchanged snapshot over live text and its caret.
            let modelChanged = parent.text != lastModelText || parent.formatting != lastModelFormatting
            let explicitReset = parent.contentRevision != lastContentRevision
            let acknowledgement = nativeEdits.firstIndex { $0.0 == parent.text && $0.1 == parent.formatting }
            let staleAcknowledgement = acknowledgement.map { $0 < nativeEdits.count - 1 } ?? false
            if explicitReset { nativeEdits.removeAll() }
            else if let acknowledgement { nativeEdits.removeFirst(acknowledgement + 1) }
            else if modelChanged { nativeEdits.removeAll() }
            let useModel = explicitReset || (modelChanged && !staleAcknowledgement)
            let fontChanged = lastBaseFont != parent.font
            if (useModel && (view.string != parent.text || lastAppliedRuns != parent.formatting)) || fontChanged {
                let range = view.selectedRange()
                let text = useModel ? parent.text : view.string
                let runs = useModel ? parent.formatting : lastAppliedRuns
                if fontChanged { view.font = parent.font }
                view.textStorage?.setAttributedString(RichTextFormatting.attributed(text, runs: runs, base: parent.font))
                let start = min(range.location, view.string.utf16.count)
                view.setSelectedRange(NSRange(location: start, length: min(range.length, view.string.utf16.count - start)))
                if fontChanged {
                    if let storage = view.textStorage, storage.length > 0 {
                        view.typingAttributes = storage.attributes(at: max(0, min(start - 1, storage.length - 1)), effectiveRange: nil)
                    } else { view.typingAttributes = [.font: parent.font, .foregroundColor: NSColor.labelColor] }
                }
                lastAppliedRuns = runs
                lastBaseFont = parent.font
            }
            lastModelText = parent.text
            lastModelFormatting = parent.formatting
            lastContentRevision = parent.contentRevision
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            // A queued initial focus request must not move the caret back to
            // offset zero after the user has started typing.
            if let request = parent.focusRequest { lastFocusRequest = request.id }
            let runs = RichTextFormatting.runs(view.attributedString(), base: parent.font)
            lastAppliedRuns = runs
            nativeEdits.append((view.string, runs))
            if nativeEdits.count > 32 { nativeEdits.removeFirst(nativeEdits.count - 32) }
            if !view.hasMarkedText(), (view as? CodeTextView)?.literalPasteInProgress != true,
               parent.onMarkdownHeading?(view.string, runs, view.selectedRange()) == true {
                // Consume the marker immediately so another keystroke cannot
                // reintroduce it before SwiftUI delivers the new block revision.
                if let match = DocumentTransfer.firstMatch(#"^(#{1,3})[ \t]+([^\r\n]*)$"#, view.string) {
                    let prefix = view.string.utf16.count - match[2].utf16.count
                    let selection = view.selectedRange()
                    view.textStorage?.deleteCharacters(in: NSRange(location: 0, length: prefix))
                    view.setSelectedRange(NSRange(location: max(0, selection.location - prefix), length: selection.length))
                }
                measure(view)
                return
            }
            if let change = parent.onRichChange { change(view.string, runs) } else { parent.onChange(view.string) }
            style(view)
            measure(view)
        }

        func textDidBeginEditing(_ notification: Notification) {
            if let request = parent.focusRequest { lastFocusRequest = request.id }
            parent.onFocus(true)
        }
        func textDidEndEditing(_ notification: Notification) { parent.onFocus(false) }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.deleteBackward(_:)),
               textView.selectedRange().location == 0, textView.selectedRange().length == 0,
               !textView.hasMarkedText(), parent.onBackspaceAtStart() { return true }
            guard !textView.hasMarkedText() else { return false }
            return parent.onCommand(commandSelector, textView.string)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !applyingFormat, let view = notification.object as? NSTextView, !view.hasMarkedText() else { return }
            let range = view.selectedRange()
            guard range.length > 0, NSMaxRange(range) <= view.string.utf16.count else { formatPopover.close(); return }
            guard view.window?.firstResponder === view else { return }
            savedSelection = range
            showFormatBar(for: view)
        }

        private func showFormatBar(for view: NSTextView) {
            guard savedSelection.length > 0, NSMaxRange(savedSelection) <= view.string.utf16.count, let window = view.window else { return }
            let sample = view.attributedString().attributedSubstring(from: NSRange(location: savedSelection.location, length: 1))
            var style = RichTextFormatting.runs(sample, base: parent.font).first?.style ?? InlineTextStyle()
            style.fontSize = style.fontSize ?? Double((sample.attribute(.font, at: 0, effectiveRange: nil) as? NSFont ?? parent.font).pointSize)
            style.bold = style.bold ?? NSFontManager.shared.traits(of: parent.font).contains(.boldFontMask)
            style.italic = style.italic ?? NSFontManager.shared.traits(of: parent.font).contains(.italicFontMask)
            // Dragging a selection emits many changes per frame. Reuse the
            // existing hosting controller while the selected style is unchanged.
            if formatPopover.isShown, displayedStyle == style { return }
            displayedStyle = style
            if let state = formatState {
                // A font Menu action still runs inside its hosting view. Never
                // replace that view/controller or synchronously relayout the
                // live popover here: AppKit material layout can recurse.
                DispatchQueue.main.async { [weak self, weak state] in
                    guard let self, self.isActive, self.displayedStyle == style else { return }
                    state?.style = style
                }
            } else {
                let state = SelectionFormatState(style)
                formatState = state
                let bar = SelectionFormatBar(state: state, clipboard: styleClipboard) { [weak self, weak view] action in
                    if let view { self?.applyFormat(action, to: view) }
                }
                let host = NSHostingController(rootView: bar)
                host.preferredContentSize = host.view.fittingSize
                formatPopover.contentViewController = host
                formatPopover.behavior = .semitransient; formatPopover.animates = false
            }
            let screenRect = view.firstRect(forCharacterRange: NSRange(location: NSMaxRange(savedSelection) - 1, length: 1), actualRange: nil)
            let rect = view.convert(window.convertFromScreen(screenRect), from: nil)
            if !formatPopover.isShown { formatPopover.show(relativeTo: rect, of: view, preferredEdge: .maxY) }
        }

        func applyFormat(_ action: TextFormatAction, to view: NSTextView) {
            let current = view.selectedRange()
            let range = current.length > 0 ? current : savedSelection
            guard range.length > 0, NSMaxRange(range) <= view.string.utf16.count, let storage = view.textStorage else { return }
            savedSelection = range
            if case .copyStyle = action {
                styleClipboard.copy(attributes: storage.attributes(at: range.location, effectiveRange: nil), base: parent.font)
                return
            }
            var copiedStyle: InlineTextStyle?
            if case .pasteStyle = action {
                guard let copied = styleClipboard.read() else { return }
                copiedStyle = copied
            }
            let previous = NSAttributedString(attributedString: storage)
            let sample = storage.attributes(at: range.location, effectiveRange: nil)
            let sampleFont = sample[.font] as? NSFont ?? parent.font
            let traits = NSFontManager.shared.traits(of: sampleFont)
            let toggleBold = !traits.contains(.boldFontMask)
            let toggleItalic = !(traits.contains(.italicFontMask) || ((sample[.obliqueness] as? NSNumber)?.doubleValue ?? 0) > 0)
            let toggleUnderline = ((sample[.underlineStyle] as? NSNumber)?.intValue ?? 0) == 0
            let toggleStrike = ((sample[.strikethroughStyle] as? NSNumber)?.intValue ?? 0) == 0
            var pieces: [(NSRange, [NSAttributedString.Key: Any])] = []
            storage.enumerateAttributes(in: range) { attrs, portion, _ in pieces.append((portion, attrs)) }
            applyingFormat = true
            for (portion, attrs) in pieces {
                let sample = NSAttributedString(string: "x", attributes: attrs)
                var style = RichTextFormatting.runs(sample, base: parent.font).first?.style ?? InlineTextStyle()
                switch action {
                case .bold: style.bold = toggleBold
                case .italic: style.italic = toggleItalic
                case .underline: style.underline = toggleUnderline
                case .strikethrough: style.strikethrough = toggleStrike
                case .size(let value): style.fontSize = value
                case .family(let value): style.fontFamily = value == "系统字体" ? nil : value
                case .color(let value): style.color = value
                case .highlight(let value): style.highlight = value
                case .clear: style = InlineTextStyle()
                case .copyStyle: break
                case .pasteStyle:
                    if var copiedStyle {
                        copiedStyle.link = style.link; copiedStyle.code = style.code
                        style = copiedStyle
                    }
                }
                storage.setAttributes([.font: parent.font, .foregroundColor: NSColor.labelColor], range: portion)
                storage.addAttributes(RichTextFormatting.attributes(style, base: parent.font), range: portion)
            }
            view.undoManager?.registerUndo(withTarget: view) { target in Self.restore(previous, in: target) }
            view.undoManager?.setActionName(L10n.tr("文字格式"))
            view.setSelectedRange(range); view.didChangeText(); measure(view)
            applyingFormat = false
            showFormatBar(for: view)
        }
        private static func restore(_ attributed: NSAttributedString, in view: NSTextView) {
            let current = NSAttributedString(attributedString: view.attributedString())
            view.undoManager?.registerUndo(withTarget: view) { target in Self.restore(current, in: target) }
            view.textStorage?.setAttributedString(attributed); view.didChangeText()
        }

        private var styledText: String?
        private var styledLanguage: String?
        private var styledDark: Bool?
        private var styledFont: NSFont?
        private var styledFormatting: [TextStyleRun] = []

        func style(_ view: NSTextView) {
            guard let language = parent.codeLanguage, !view.hasMarkedText(),
                  styledText != view.string || styledLanguage != language || styledDark != parent.darkCode || styledFont != parent.font || styledFormatting != lastAppliedRuns else { return }
            styledText = view.string
            styledLanguage = language
            styledDark = parent.darkCode
            styledFont = parent.font
            styledFormatting = lastAppliedRuns
            let dark = parent.darkCode
            let foreground = dark ? NSColor(red: 0.82, green: 0.85, blue: 0.9, alpha: 1) : NSColor(red: 0.2, green: 0.24, blue: 0.32, alpha: 1)
            view.insertionPointColor = dark ? .white : .controlAccentColor
            view.isAutomaticSpellingCorrectionEnabled = false
            view.isContinuousSpellCheckingEnabled = false
            view.isAutomaticTextReplacementEnabled = false
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 4
            view.defaultParagraphStyle = paragraph
            guard let layout = view.layoutManager else { return }
            let full = NSRange(location: 0, length: view.string.utf16.count)
            layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
            layout.removeTemporaryAttribute(.paragraphStyle, forCharacterRange: full)
            layout.addTemporaryAttributes([.paragraphStyle: paragraph, .foregroundColor: foreground], forCharacterRange: full)
            if language.lowercased() != "plain text" {
                CodeSyntax.highlight(view.string, language: language, dark: dark, layout: layout)
            }
            for run in lastAppliedRuns {
                if let hex = run.style.color, let color = RichTextFormatting.color(hex), let range = run.validRange(in: view.string) {
                    layout.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: range)
                }
            }
            view.needsDisplay = true
        }

        private struct MeasurementInput: Equatable {
            var text: String
            var runs: [TextStyleRun]
            var font: NSFont
            var width: CGFloat
            var inset: NSSize
            var language: String?
        }
        private var lastMeasurement: MeasurementInput?

        func measure(_ view: NSTextView) {
            guard let container = view.textContainer, let layout = view.layoutManager else { return }
            let input = MeasurementInput(text: view.string, runs: lastAppliedRuns, font: parent.font,
                                         width: container.containerSize.width, inset: view.textContainerInset,
                                         language: parent.codeLanguage)
            guard input != lastMeasurement, input.width > 0 else { return }
            lastMeasurement = input
            layout.ensureLayout(for: container)
            let used = layout.usedRect(for: container)
            let bottom = max(used.maxY, layout.extraLineFragmentRect.maxY)
            parent.onHeightChange(ceil(bottom + view.textContainerInset.height * 2) + 4)
            view.needsDisplay = true
        }
    }
}

struct TableResizeGrip: NSViewRepresentable {
    let horizontal: Bool
    let index: Int
    let resize: (Double, Bool) -> Void
    func makeNSView(context: Context) -> TableResizeGripView { TableResizeGripView() }
    func updateNSView(_ view: TableResizeGripView, context: Context) {
        view.horizontal = horizontal
        view.identifier = NSUserInterfaceItemIdentifier("table-" + (horizontal ? "column-" : "row-") + String(index))
        view.resize = resize
        view.window?.invalidateCursorRects(for: view)
    }
}

final class TableResizeGripView: NSView {
    var horizontal = true
    var resize: (Double, Bool) -> Void = { _, _ in }
    override func resetCursorRects() { addCursorRect(bounds, cursor: horizontal ? .resizeLeftRight : .resizeUpDown) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let origin = event.locationInWindow
        let callback = resize
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            // Window coordinates increase upward; row heights increase downward.
            let delta = horizontal ? next.locationInWindow.x - origin.x : origin.y - next.locationInWindow.y
            callback(Double(delta), next.type == .leftMouseUp)
            if next.type == .leftMouseUp { break }
        }
    }
}

/// A real child window keeps the slash menu above lazy rows and native editors.
/// Drawing an offset SwiftUI overlay below a 30pt text view does not enlarge its
/// hit-testing bounds; the following row can consume the menu's mouse clicks.
struct EditorCommandPopup<Content: View>: NSViewRepresentable {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> EditorPopupAnchor {
        let anchor = EditorPopupAnchor()
        anchor.reposition = { [weak coordinator = context.coordinator] in coordinator?.schedulePosition() }
        context.coordinator.anchor = anchor
        context.coordinator.update(content)
        return anchor
    }
    func updateNSView(_ view: EditorPopupAnchor, context: Context) { context.coordinator.update(content) }
    static func dismantleNSView(_ view: EditorPopupAnchor, coordinator: Coordinator) { coordinator.close() }

    final class Coordinator {
        weak var anchor: EditorPopupAnchor?
        private var panel: EditorPopupPanel?
        private var host: NSHostingView<Content>?
        private var pending: DispatchWorkItem?
        private var active = true
        private var scrollObserver: NSObjectProtocol?
        private weak var observedClip: NSClipView?

        func update(_ content: Content) {
            guard active else { return }
            if let host { host.rootView = content }
            else {
                let host = EditorPopupHostingView(rootView: content)
                let panel = EditorPopupPanel(contentRect: NSRect(x: 0, y: 0, width: 330, height: 384),
                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.isReleasedWhenClosed = false
                panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
                panel.hidesOnDeactivate = true
                panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
                panel.contentView = host
                panel.setAccessibilityLabel(L10n.tr("插入块"))
                self.host = host; self.panel = panel
            }
            schedulePosition()
        }
        func schedulePosition() {
            guard active else { return }
            pending?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.position() }
            pending = work
            DispatchQueue.main.async(execute: work)
        }
        private func position() {
            guard active, let anchor, let window = anchor.window, let panel else { return }
            let clip = anchor.enclosingScrollView?.contentView
            if clip !== observedClip {
                if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
                observedClip = clip
                if let clip {
                    clip.postsBoundsChangedNotifications = true
                    scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                        object: clip, queue: .main) { [weak self] _ in self?.schedulePosition() }
                }
            }
            guard !anchor.visibleRect.isEmpty, !window.isMiniaturized else { panel.orderOut(nil); return }
            let rect = anchor.convert(anchor.bounds, to: nil)
            let screenRect = window.convertToScreen(rect)
            let available = window.screen?.visibleFrame ?? screenRect.insetBy(dx: -500, dy: -500)
            let size = NSSize(width: 330, height: 384)
            var origin = NSPoint(x: screenRect.minX, y: screenRect.minY - size.height - 8)
            if origin.y < available.minY { origin.y = min(available.maxY - size.height, screenRect.maxY + 8) }
            origin.x = min(max(available.minX, origin.x), max(available.minX, available.maxX - size.width))
            panel.setFrame(NSRect(origin: origin, size: size), display: true)
            if panel.parent !== window {
                panel.parent?.removeChildWindow(panel)
                window.addChildWindow(panel, ordered: .above)
            }
            panel.orderFront(nil)
        }
        func close() {
            active = false
            pending?.cancel(); pending = nil
            if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
            scrollObserver = nil
            if let panel { panel.parent?.removeChildWindow(panel) }
            panel?.orderOut(nil); panel?.close()
            panel = nil; host = nil
        }
    }
}

final class EditorPopupHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class EditorPopupAnchor: NSView {
    var reposition: (() -> Void)?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); reposition?() }
    override func layout() { super.layout(); reposition?() }
}

final class EditorPopupPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Draw the gutter inside the text view, bounded by the editor itself.
/// Avoid NSRulerView's separate layer and coordinate system inside a SwiftUI ScrollView.
final class CodeTextView: NSTextView {
    private var gutterText = ""
    private(set) var gutterLineStarts: [Int] = [0]

    func updateGutterIndex() {
        guard gutterText != string else { return }
        gutterText = string
        let source = string as NSString
        gutterLineStarts = [0]
        var offset = 0
        while offset < source.length {
            offset = NSMaxRange(source.lineRange(for: NSRange(location: offset, length: 0)))
            gutterLineStarts.append(offset)
        }
        if source.length > 0 && !string.hasSuffix("\n") && !string.hasSuffix("\r") {
            gutterLineStarts.removeLast()
        }
    }

    var showsLineNumbers = false
    var focusWhenAttached: () -> Void = {}
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { DispatchQueue.main.async { [weak self] in self?.focusWhenAttached() } }
    }
    var focusChanged: (Bool) -> Void = { _ in }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { focusChanged(true) }
        return accepted
    }
    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { focusChanged(false) }
        return accepted
    }
    var selectAllDocument: () -> Bool = { false }
    var deleteDocumentSelection: () -> Bool = { false }
    var documentBoundary: (Bool, Bool) -> Bool = { _, _ in false }
    var blockMouseDown: (NSEvent.ModifierFlags) -> Bool = { _ in false }
    var formatSelection: (TextFormatAction) -> Void = { _ in }

    var pasteDocument: ((String?, String?, String, NSRange) -> Bool)?
    var pasteTransform: ((String?, String?) -> String)?
    var literalPasteInProgress = false
    var copySelectionAsText = false
    override func copy(_ sender: Any?) {
        guard copySelectionAsText else { super.copy(sender); return }
        let range = selectedRange()
        guard range.length > 0, NSMaxRange(range) <= (string as NSString).length else { return }
        let clipboard = NSPasteboard.general
        clipboard.clearContents()
        clipboard.setString((string as NSString).substring(with: range), forType: .string)
        clipboard.setString("1", forType: ClipboardDocument.textSelectionType)
    }
    override func paste(_ sender: Any?) {
        let clipboard = NSPasteboard.general
        if !hasMarkedText(), clipboard.data(forType: ClipboardDocument.textSelectionType) != nil,
           let plain = clipboard.string(forType: .string) {
            literalPasteInProgress = true
            defer { literalPasteInProgress = false }
            insertText(plain, replacementRange: selectedRange())
            return
        }
        if !hasMarkedText(), pasteDocument?(clipboard.string(forType: .string), clipboard.string(forType: .html), string, selectedRange()) == true { return }
        if !hasMarkedText(), let pasteTransform {
            let replacement = pasteTransform(clipboard.string(forType: .string), clipboard.string(forType: .html))
            if !replacement.isEmpty {
                insertText(replacement, replacementRange: selectedRange())
                return
            }
        }
        super.paste(sender)
    }

    override func copyFont(_ sender: Any?) { formatSelection(.copyStyle) }
    override func pasteFont(_ sender: Any?) { formatSelection(.pasteStyle) }
    override func selectAll(_ sender: Any?) { if !selectAllDocument() { super.selectAll(sender) } }
    override func mouseDown(with event: NSEvent) { if !blockMouseDown(event.modifierFlags) { super.mouseDown(with: event) } }
    var headingShortcut: (Int) -> Bool = { _ in false }
    var exitBlock: () -> Bool = { false }
    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.shift, .command, .option, .control])
        if modifiers == [.command, .option], !hasMarkedText(),
           let key = event.charactersIgnoringModifiers?.lowercased(), ["c", "v"].contains(key) {
            formatSelection(key == "c" ? .copyStyle : .pasteStyle)
            return
        }
        if modifiers == [.command, .option], !hasMarkedText(),
           let level = [UInt16(18): 1, 19: 2, 20: 3][event.keyCode], headingShortcut(level) { return }
        if [36, 76].contains(event.keyCode), modifiers == .shift, !hasMarkedText(), exitBlock() { return }
        let command = event.modifierFlags.contains(.command)
        if command, let key = event.charactersIgnoringModifiers?.lowercased() {
            if key == "a", selectAllDocument() { return }
            if key == "b" { formatSelection(.bold); return }
            if key == "i" { formatSelection(.italic); return }
            if key == "u" { formatSelection(.underline); return }
        }
        if (command && [125, 126].contains(event.keyCode)) || (event.modifierFlags.contains(.control) && [115, 119].contains(event.keyCode)) {
            if documentBoundary(event.keyCode == 126 || event.keyCode == 115, event.modifierFlags.contains(.shift)) { return }
        }
        if [51, 117].contains(event.keyCode), deleteDocumentSelection() { return }
        super.keyDown(with: event)
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard showsLineNumbers, let layout = layoutManager, let container = textContainer else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: bounds.intersection(rect)).addClip()
        layout.ensureLayout(for: container)
        let text = string as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.6)
        ]
        updateGutterIndex()
        // Begin at the dirty region rather than walking every preceding line.
        let point = NSPoint(x: 0, y: max(0, rect.minY - textContainerOrigin.y))
        let glyph = layout.glyphIndex(for: point, in: container)
        let character = layout.numberOfGlyphs > 0 ? layout.characterIndexForGlyph(at: min(glyph, layout.numberOfGlyphs - 1)) : 0
        var low = 0, high = gutterLineStarts.count
        while low < high {
            let middle = (low + high) / 2
            if gutterLineStarts[middle] <= character { low = middle + 1 } else { high = middle }
        }
        var number = max(1, low)
        var start = gutterLineStarts[number - 1]
        repeat {
            let lineRect: NSRect
            if start < text.length {
                let glyph = layout.glyphIndexForCharacter(at: start)
                lineRect = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            } else { lineRect = layout.extraLineFragmentRect }
            let y = lineRect.minY + textContainerOrigin.y
            let label = "\(number)" as NSString
            let size = label.size(withAttributes: attributes)
            if y + lineRect.height >= rect.minY && y <= rect.maxY {
                label.draw(at: NSPoint(x: 32 - size.width, y: y + 2), withAttributes: attributes)
            }
            if y > rect.maxY || start >= text.length { break }
            start = NSMaxRange(text.lineRange(for: NSRange(location: start, length: 0)))
            number += 1
            if start == text.length && !string.hasSuffix("\n") { break }
        } while start <= text.length
    }
}

/// Lightweight lexical coloring; temporary layout attributes leave plain text and undo history intact.
private enum CodeSyntax {
    private static let regexCache: NSCache<NSString, NSRegularExpression> = {
        let cache = NSCache<NSString, NSRegularExpression>()
        cache.countLimit = 32
        return cache
    }()

    static func highlight(_ text: String, language: String, dark: Bool, layout: NSLayoutManager) {
        let lang = language.lowercased()
        let keywordSets: [String: String] = [
            "swift": "import let var func class struct enum protocol extension return if else guard switch case default for in while try throws throw catch do async await actor private public static self nil true false init override weak some",
            "python": "def class import from as return if elif else for in while try except finally with lambda pass raise yield async await None True False and or not is global nonlocal del assert break continue",
            "sql": "SELECT FROM WHERE JOIN LEFT RIGHT INNER OUTER ON AS INSERT INTO VALUES UPDATE SET DELETE CREATE TABLE INDEX DROP ALTER GROUP BY ORDER HAVING LIMIT DISTINCT NULL AND OR NOT IN IS ASC DESC",
            "bash": "if then else elif fi for while do done case esac function in export local return exit echo",
            "javascript": "import export from const let var function class extends return if else switch case default for of in while try catch finally throw new this null undefined true false async await typeof instanceof static get set",
            "rust": "fn let mut impl struct enum trait pub use mod match if else for in loop while return self Self Some None Ok Err async await move ref const static",
            "go": "package import func var const type struct interface map chan go defer select case default range if else for return nil true false"
        ]
        let fallback = "class struct enum public private protected static void int float double bool string new return if else switch case default for while break continue try catch throw import package true false null using namespace const auto"
        let key = ["typescript", "jsx", "tsx"].contains(lang) ? "javascript" : lang
        let keywords = (keywordSets[key] ?? fallback).split(separator: " ").map(String.init)
        let words = keywords.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        let hashComments = ["python", "bash", "ruby", "yaml"].contains(lang)
        let comments = hashComments ? #"#[^\n]*"# : #"//[^\n]*|/\*[\s\S]*?\*/"#
        let strings = #""(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`"#
        let pattern = "(?<comment>" + comments + ")|(?<string>" + strings + ")|(?<number>" + #"\b\d+(?:\.\d+)?\b"# + ")|(?<keyword>\\b(?:" + words + ")\\b)"
        let cacheKey = (key + ":" + (hashComments ? "hash" : "slash")) as NSString
        let regex: NSRegularExpression
        if let cached = regexCache.object(forKey: cacheKey) {
            regex = cached
        } else {
            guard let compiled = try? NSRegularExpression(pattern: pattern, options: lang == "sql" ? [.caseInsensitive] : []) else { return }
            regexCache.setObject(compiled, forKey: cacheKey)
            regex = compiled
        }
        let colors: [(String, NSColor)] = [
            ("comment", dark ? NSColor(red: 0.45, green: 0.53, blue: 0.61, alpha: 1) : NSColor(red: 0.49, green: 0.55, blue: 0.62, alpha: 1)),
            ("string", dark ? NSColor(red: 0.65, green: 0.8, blue: 0.57, alpha: 1) : NSColor(red: 0.2, green: 0.47, blue: 0.36, alpha: 1)),
            ("number", dark ? NSColor(red: 0.9, green: 0.69, blue: 0.46, alpha: 1) : NSColor(red: 0.68, green: 0.39, blue: 0.19, alpha: 1)),
            ("keyword", dark ? NSColor(red: 0.74, green: 0.64, blue: 0.96, alpha: 1) : NSColor(red: 0.44, green: 0.3, blue: 0.72, alpha: 1))
        ]
        regex.enumerateMatches(in: text, range: NSRange(location: 0, length: text.utf16.count)) { match, _, _ in
            guard let match else { return }
            for (name, color) in colors {
                let range = match.range(withName: name)
                if range.location != NSNotFound { layout.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: range) }
            }
        }
    }
}
