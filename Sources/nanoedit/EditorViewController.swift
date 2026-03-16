import AppKit
import Highlighter

// NSTextView subclass that forwards Escape to close the window instead of autocomplete.
class EscapeHandlingTextView: NSTextView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 53 { // Escape
            window?.performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

private final class FixedLineMetricsDelegate: NSObject, NSLayoutManagerDelegate {
    let lineHeight: CGFloat
    private let baselineY: CGFloat

    init(primaryFont: NSFont, fallbackFont: NSFont?) {
        let fonts = [primaryFont, fallbackFont].compactMap { $0 }
        let ascender = fonts.map(\.ascender).max() ?? primaryFont.ascender
        let descender = fonts.map { abs($0.descender) }.max() ?? abs(primaryFont.descender)

        let padding: CGFloat = 4
        self.lineHeight = ceil(ascender + descender) + padding
        self.baselineY = ceil(ascender) + padding / 2
    }

    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
        lineFragmentUsedRect: UnsafeMutablePointer<NSRect>,
        baselineOffset: UnsafeMutablePointer<CGFloat>,
        in textContainer: NSTextContainer,
        forGlyphRange glyphRange: NSRange
    ) -> Bool {
        lineFragmentRect.pointee.size.height = lineHeight
        lineFragmentUsedRect.pointee.size.height = lineHeight
        baselineOffset.pointee = baselineY
        return true
    }
}

// Applies syntax highlighting asynchronously to avoid re-entering textStorage editing.
class HighlightingTextStorageDelegate: NSObject, NSTextStorageDelegate {
    private let highlighter: Highlighter
    private let language: String
    private let font: NSFont
    private let paragraphStyle: NSParagraphStyle
    private let didApplyHighlighting: (() -> Void)?
    private var pendingHighlight = false

    init(
        highlighter: Highlighter,
        language: String,
        font: NSFont,
        paragraphStyle: NSParagraphStyle,
        didApplyHighlighting: (() -> Void)? = nil
    ) {
        self.highlighter = highlighter
        self.language = language
        self.font = font
        self.paragraphStyle = paragraphStyle
        self.didApplyHighlighting = didApplyHighlighting
    }

    func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters), !pendingHighlight else { return }

        pendingHighlight = true
        DispatchQueue.main.async { [weak self, weak textStorage] in
            guard let textStorage else { return }
            self?.applyHighlighting(to: textStorage)
        }
    }

    private func applyHighlighting(to textStorage: NSTextStorage) {
        defer { pendingHighlight = false }

        // Skip while IME composition is active
        for layoutManager in textStorage.layoutManagers {
            if layoutManager.firstTextView?.hasMarkedText() == true { return }
        }

        let fullText = textStorage.string
        guard !fullText.isEmpty,
              let highlighted = highlighter.highlight(fullText, as: language),
              highlighted.length == textStorage.length else { return }

        let font = self.font
        let fullRange = NSRange(location: 0, length: textStorage.length)

        textStorage.beginEditing()
        highlighted.enumerateAttributes(in: fullRange) { attrs, range, _ in
            var merged = attrs
            merged[.font] = font
            merged[.paragraphStyle] = paragraphStyle
            textStorage.setAttributes(merged, range: range)
        }
        textStorage.endEditing()
        didApplyHighlighting?()
    }
}

class EditorViewController: NSViewController, NSWindowDelegate, NSTextViewDelegate {
    static let editorFont = NSFont(name: "Menlo", size: 13) ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    static let fallbackEditorFont = NSFont(name: "Hiragino Sans", size: editorFont.pointSize)

    static func makeEditorParagraphStyle(lineHeight: CGFloat) -> NSParagraphStyle {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.minimumLineHeight = lineHeight
        paragraphStyle.maximumLineHeight = lineHeight
        return paragraphStyle
    }

    let filePath: String
    private var textView: NSTextView!
    private var originalContent: String = ""
    private var highlightingDelegate: HighlightingTextStorageDelegate?
    private var lineMetricsDelegate: FixedLineMetricsDelegate?
    private var editorParagraphStyle: NSParagraphStyle!
    private var themeTextColor: NSColor = .white

    init(filePath: String) {
        self.filePath = filePath
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        // Background blur effect
        let visualEffectView = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        visualEffectView.material = .hudWindow
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.state = .active
        visualEffectView.autoresizingMask = [.width, .height]

        let scrollView = NSScrollView(frame: visualEffectView.bounds)
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autoresizingMask = [.width, .height]
        scrollView.drawsBackground = false

        // Set up HighlighterSwift
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        layoutManager.usesFontLeading = false
        textStorage.addLayoutManager(layoutManager)

        let lineMetricsDelegate = FixedLineMetricsDelegate(
            primaryFont: Self.editorFont,
            fallbackFont: Self.fallbackEditorFont
        )
        layoutManager.delegate = lineMetricsDelegate
        self.lineMetricsDelegate = lineMetricsDelegate

        let paragraphStyle = Self.makeEditorParagraphStyle(lineHeight: lineMetricsDelegate.lineHeight)
        self.editorParagraphStyle = paragraphStyle

        if let highlighter = Highlighter() {
            highlighter.setTheme("atom-one-dark")

            // Extract the theme's default text color from a sample highlight
            if let sample = highlighter.highlight("x", as: "plaintext"),
               sample.length > 0,
               let color = sample.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor {
                self.themeTextColor = color
            }

            let delegate = HighlightingTextStorageDelegate(
                highlighter: highlighter,
                language: "markdown",
                font: Self.editorFont,
                paragraphStyle: paragraphStyle,
                didApplyHighlighting: { [weak self] in
                    self?.updateInputAttributes()
                }
            )
            textStorage.delegate = delegate
            self.highlightingDelegate = delegate
        }

        let containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        let textContainer = NSTextContainer(size: containerSize)
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)

        let textView = EscapeHandlingTextView(frame: scrollView.bounds, textContainer: textContainer)
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.font = Self.editorFont
        textView.defaultParagraphStyle = paragraphStyle
        textView.delegate = self

        textView.drawsBackground = false
        textView.textColor = themeTextColor
        textView.insertionPointColor = themeTextColor

        scrollView.documentView = textView
        visualEffectView.addSubview(scrollView)
        self.textView = textView
        self.view = visualEffectView
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // Load file content
        if FileManager.default.fileExists(atPath: filePath) {
            do {
                let content = try String(contentsOfFile: filePath, encoding: .utf8)
                textView.string = content
                originalContent = content
            } catch {
                let alert = NSAlert()
                alert.messageText = "Failed to read file"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
                originalContent = ""
            }
        } else {
            originalContent = ""
        }
        applyEditorParagraphStyle()
        updateInputAttributes()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.delegate = self
    }

    // MARK: - Save (called by main menu's Save item via responder chain)

    @objc func saveAndExit() {
        if saveFile() {
            NSApp.terminate(nil)
        }
    }

    private func saveFile() -> Bool {
        do {
            try textView.string.write(toFile: filePath, atomically: true, encoding: .utf8)
            return true
        } catch {
            let alert = NSAlert()
            alert.messageText = "Failed to save file"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .critical
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return false
        }
    }

    // MARK: - Close Handling (called by performClose via Cmd+W, × button, or Escape)

    private var hasUnsavedChanges: Bool {
        return textView.string != originalContent
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if !hasUnsavedChanges {
            return true
        }

        let alert = NSAlert()
        alert.messageText = "Do you want to save changes?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn: // Save
            return saveFile()
        case .alertSecondButtonReturn: // Don't Save
            return true
        default: // Cancel
            return false
        }
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        updateInputAttributes()
    }

    private func updateInputAttributes() {
        guard let textView = self.textView else { return }

        let font = Self.editorFont
        let paragraphStyle: NSParagraphStyle = editorParagraphStyle
        var foregroundColor: NSColor = themeTextColor

        if let textStorage = textView.textStorage, textStorage.length > 0 {
            let location = textView.selectedRange().location
            if location > 0,
               let color = textStorage.attribute(.foregroundColor, at: location - 1, effectiveRange: nil) as? NSColor {
                foregroundColor = color
            }
        }

        textView.typingAttributes = [
            .font: font,
            .foregroundColor: foregroundColor,
            .paragraphStyle: paragraphStyle,
        ]

        var markedAttrs = textView.markedTextAttributes ?? [:]
        markedAttrs[.font] = font
        markedAttrs[.foregroundColor] = foregroundColor
        markedAttrs[.paragraphStyle] = paragraphStyle
        textView.markedTextAttributes = markedAttrs
    }

    private func applyEditorParagraphStyle() {
        guard let textView = self.textView else { return }

        textView.defaultParagraphStyle = editorParagraphStyle

        guard let textStorage = textView.textStorage, textStorage.length > 0 else { return }
        let fullRange = NSRange(location: 0, length: textStorage.length)
        textStorage.addAttribute(.paragraphStyle, value: editorParagraphStyle!, range: fullRange)
    }
}
