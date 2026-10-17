import AppKit
import SwiftUI

struct NativeTextEditor: NSViewRepresentable {
    var text: String
    var font: NSFont
    var formatting: [TextStyleRun] = []
    var onRichChange: ((String, [TextStyleRun]) -> Void)? = nil
    var onSelectAllBlocks: () -> Bool = { false }
    var onDeleteBlocks: () -> Bool = { false }
    var onDocumentBoundary: (Bool, Bool) -> Bool = { _, _ in false }
    var onBlockMouseDown: (NSEvent.ModifierFlags) -> Bool = { _ in false }
    var codeLanguage: String? = nil
    var showCodeLineNumbers = true
    var darkCode = false
    var focusRequest: EditorFocusRequest? = nil
    var onBackspaceAtStart: () -> Bool = { false }
    var onCommand: (Selector) -> Bool = { _ in false }
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
        if !view.hasMarkedText() && (view.string != text || context.coordinator.lastAppliedRuns != formatting || context.coordinator.lastBaseFont != font) {
            let range = view.selectedRange()
            view.textStorage?.setAttributedString(RichTextFormatting.attributed(text, runs: formatting, base: font))
            view.setSelectedRange(NSRange(location: min(range.location, view.string.utf16.count), length: min(range.length, max(0, view.string.utf16.count - min(range.location, view.string.utf16.count)))))
            context.coordinator.lastAppliedRuns = formatting; context.coordinator.lastBaseFont = font
        }
        context.coordinator.style(view)
        DispatchQueue.main.async {
            context.coordinator.measure(view)
            if let request = focusRequest, context.coordinator.lastFocusRequest != request.id,
               let window = view.window {
                context.coordinator.lastFocusRequest = request.id
                window.makeFirstResponder(view)
                view.setSelectedRange(NSRange(location: min(request.offset, view.string.utf16.count), length: 0))
                view.scrollRangeToVisible(view.selectedRange())
            }
        }
    }

    private func configureCallbacks(_ view: CodeTextView, coordinator: Coordinator) {
        view.selectAllDocument = { [weak coordinator] in coordinator?.formatPopover.close(); return onSelectAllBlocks() }
        view.deleteDocumentSelection = { [weak coordinator] in
            let handled = onDeleteBlocks(); if handled { coordinator?.formatPopover.close() }; return handled
        }
        view.documentBoundary = onDocumentBoundary
        view.blockMouseDown = onBlockMouseDown
        view.formatSelection = { [weak coordinator, weak view] action in
            if let view { coordinator?.applyFormat(action, to: view) }
        }
    }

    static func dismantleNSView(_ view: NSScrollView, coordinator: Coordinator) { coordinator.formatPopover.close() }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var lastFocusRequest: UUID?
        var parent: NativeTextEditor
        var lastAppliedRuns: [TextStyleRun] = []
        var lastBaseFont: NSFont?
        let formatPopover = NSPopover()
        private var savedSelection = NSRange(location: 0, length: 0)
        private var applyingFormat = false
        init(parent: NativeTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            let runs = RichTextFormatting.runs(view.attributedString(), base: parent.font)
            lastAppliedRuns = runs
            if let change = parent.onRichChange { change(view.string, runs) } else { parent.onChange(view.string) }
            style(view)
            measure(view)
        }

        func textDidBeginEditing(_ notification: Notification) { parent.onFocus(true) }
        func textDidEndEditing(_ notification: Notification) { parent.onFocus(false) }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.deleteBackward(_:)),
               textView.selectedRange().location == 0, textView.selectedRange().length == 0,
               !textView.hasMarkedText(), parent.onBackspaceAtStart() { return true }
            return parent.onCommand(commandSelector)
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
            let bar = SelectionFormatBar(style: style) { [weak self, weak view] action in if let view { self?.applyFormat(action, to: view) } }
            let host = NSHostingController(rootView: bar); host.view.layoutSubtreeIfNeeded()
            host.preferredContentSize = host.view.fittingSize
            formatPopover.contentViewController = host; formatPopover.behavior = .semitransient; formatPopover.animates = false
            let screenRect = view.firstRect(forCharacterRange: NSRange(location: NSMaxRange(savedSelection) - 1, length: 1), actualRange: nil)
            let rect = view.convert(window.convertFromScreen(screenRect), from: nil)
            if !formatPopover.isShown { formatPopover.show(relativeTo: rect, of: view, preferredEdge: .maxY) }
        }

        func applyFormat(_ action: TextFormatAction, to view: NSTextView) {
            let current = view.selectedRange()
            let range = current.length > 0 ? current : savedSelection
            guard range.length > 0, NSMaxRange(range) <= view.string.utf16.count, let storage = view.textStorage else { return }
            savedSelection = range
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
                }
                storage.setAttributes([.font: parent.font, .foregroundColor: NSColor.labelColor], range: portion)
                storage.addAttributes(RichTextFormatting.attributes(style, base: parent.font), range: portion)
            }
            view.undoManager?.registerUndo(withTarget: view) { target in Self.restore(previous, in: target) }
            view.undoManager?.setActionName("文字格式")
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

        func measure(_ view: NSTextView) {
            guard let container = view.textContainer, let layout = view.layoutManager else { return }
            layout.ensureLayout(for: container)
            let used = layout.usedRect(for: container)
            let bottom = max(used.maxY, layout.extraLineFragmentRect.maxY)
            parent.onHeightChange(ceil(bottom + view.textContainerInset.height * 2) + 4)
            view.needsDisplay = true
        }
    }
}

/// Draw the gutter inside the text view, bounded by the editor itself.
/// Avoid NSRulerView's separate layer and coordinate system inside a SwiftUI ScrollView.
private final class CodeTextView: NSTextView {
    var showsLineNumbers = false
    var selectAllDocument: () -> Bool = { false }
    var deleteDocumentSelection: () -> Bool = { false }
    var documentBoundary: (Bool, Bool) -> Bool = { _, _ in false }
    var blockMouseDown: (NSEvent.ModifierFlags) -> Bool = { _ in false }
    var formatSelection: (TextFormatAction) -> Void = { _ in }

    override func selectAll(_ sender: Any?) { if !selectAllDocument() { super.selectAll(sender) } }
    override func mouseDown(with event: NSEvent) { if !blockMouseDown(event.modifierFlags) { super.mouseDown(with: event) } }
    override func keyDown(with event: NSEvent) {
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
        var start = 0
        var number = 1
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
        guard let regex = try? NSRegularExpression(pattern: pattern, options: lang == "sql" ? [.caseInsensitive] : []) else { return }
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
