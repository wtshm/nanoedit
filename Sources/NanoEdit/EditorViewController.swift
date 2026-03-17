import AppKit
import Highlighter

// NSLayoutManagerDelegate that enforces a uniform line height and baseline offset.
private final class UniformLineMetricsDelegate: NSObject, NSLayoutManagerDelegate {
    let lineHeight: CGFloat
    private let baselineOffset: CGFloat

    init(primaryFont: NSFont, fallbackFont: NSFont?) {
        let fonts = [primaryFont, fallbackFont].compactMap { $0 }
        let ascender = fonts.map(\.ascender).max() ?? primaryFont.ascender
        let descender = fonts.map { abs($0.descender) }.max() ?? abs(primaryFont.descender)

        let padding: CGFloat = 4
        self.lineHeight = ceil(ascender + descender) + padding
        self.baselineOffset = ceil(ascender) + padding / 2
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
        baselineOffset.pointee = self.baselineOffset
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
    private let shouldDeferHighlighting: (() -> Bool)?
    private var isHighlightPending = false
    private weak var deferredTextStorage: NSTextStorage?
    private var hasDeferredHighlightRequest = false

    init(
        highlighter: Highlighter,
        language: String,
        font: NSFont,
        paragraphStyle: NSParagraphStyle,
        shouldDeferHighlighting: (() -> Bool)? = nil,
        didApplyHighlighting: (() -> Void)? = nil
    ) {
        self.highlighter = highlighter
        self.language = language
        self.font = font
        self.paragraphStyle = paragraphStyle
        self.shouldDeferHighlighting = shouldDeferHighlighting
        self.didApplyHighlighting = didApplyHighlighting
    }

    func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters), !isHighlightPending else { return }

        scheduleHighlighting(for: textStorage)
    }

    private func scheduleHighlighting(for textStorage: NSTextStorage) {
        isHighlightPending = true
        DispatchQueue.main.async { [weak self, weak textStorage] in
            guard let self else { return }
            guard let textStorage else {
                self.isHighlightPending = false
                self.hasDeferredHighlightRequest = false
                return
            }
            self.applyHighlighting(to: textStorage)
        }
    }

    private func applyHighlighting(to textStorage: NSTextStorage) {
        if shouldDeferHighlighting?() == true {
            deferredTextStorage = textStorage
            hasDeferredHighlightRequest = true
            isHighlightPending = false
            return
        }

        defer { isHighlightPending = false }
        hasDeferredHighlightRequest = false
        deferredTextStorage = nil

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
            var mergedAttributes = attrs
            mergedAttributes[.font] = font
            mergedAttributes[.paragraphStyle] = paragraphStyle
            textStorage.setAttributes(mergedAttributes, range: range)
        }
        textStorage.endEditing()
        didApplyHighlighting?()
    }

    func resumeDeferredHighlightingIfNeeded() {
        guard hasDeferredHighlightRequest, isHighlightPending == false else { return }
        guard shouldDeferHighlighting?() != true else { return }
        guard let textStorage = deferredTextStorage else {
            hasDeferredHighlightRequest = false
            return
        }

        scheduleHighlighting(for: textStorage)
    }
}

// Main view controller that manages file loading, saving, and the text editing environment.
class EditorViewController: NSViewController, NSWindowDelegate, NSTextViewDelegate {
    static let editorFontSize: CGFloat = 13
    static let editorFont = NSFont(name: "Menlo", size: editorFontSize) ?? NSFont.monospacedSystemFont(ofSize: editorFontSize, weight: .regular)
    static let fallbackEditorFont = NSFont(name: "Hiragino Sans", size: editorFontSize)

    static func makeEditorParagraphStyle(lineHeight: CGFloat) -> NSParagraphStyle {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.minimumLineHeight = lineHeight
        paragraphStyle.maximumLineHeight = lineHeight
        return paragraphStyle
    }

    let filePath: String
    let workingDirectoryPath: String
    private var textView: NSTextView!
    private var originalContent: String = ""
    private var highlightingDelegate: HighlightingTextStorageDelegate?
    private var lineMetricsDelegate: UniformLineMetricsDelegate?
    private var editorParagraphStyle: NSParagraphStyle!
    private var themeTextColor: NSColor = .white

    init(filePath: String, workingDirectoryPath: String) {
        self.filePath = filePath
        self.workingDirectoryPath = workingDirectoryPath
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let backgroundView = makeBackgroundView()
        let scrollView = makeScrollView(frame: backgroundView.bounds)
        let textView = setupTextSystem(in: scrollView)

        scrollView.documentView = textView
        backgroundView.addSubview(scrollView)
        self.textView = textView
        self.view = backgroundView
    }

    private func makeBackgroundView() -> NSVisualEffectView {
        let view = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.autoresizingMask = [.width, .height]
        return view
    }

    private func makeScrollView(frame: NSRect) -> NSScrollView {
        let scrollView = NSScrollView(frame: frame)
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autoresizingMask = [.width, .height]
        scrollView.drawsBackground = false
        return scrollView
    }

    private func setupTextSystem(in scrollView: NSScrollView) -> NSTextView {
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        layoutManager.usesFontLeading = false
        textStorage.addLayoutManager(layoutManager)

        let lineMetrics = UniformLineMetricsDelegate(
            primaryFont: Self.editorFont,
            fallbackFont: Self.fallbackEditorFont
        )
        layoutManager.delegate = lineMetrics
        self.lineMetricsDelegate = lineMetrics

        let paragraphStyle = Self.makeEditorParagraphStyle(lineHeight: lineMetrics.lineHeight)
        self.editorParagraphStyle = paragraphStyle

        let containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        let textContainer = NSTextContainer(size: containerSize)
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)

        let textView = MentionCompletingTextView(frame: scrollView.bounds, textContainer: textContainer)
        textView.completionRootURL = URL(fileURLWithPath: workingDirectoryPath, isDirectory: true)
        setupHighlighting(textStorage: textStorage, paragraphStyle: paragraphStyle, textView: textView)
        configureTextView(textView, paragraphStyle: paragraphStyle)
        return textView
    }

    private func setupHighlighting(
        textStorage: NSTextStorage,
        paragraphStyle: NSParagraphStyle,
        textView: MentionCompletingTextView
    ) {
        guard let highlighter = Highlighter() else { return }
        highlighter.setTheme("atom-one-dark")

        if let sampleHighlight = highlighter.highlight("x", as: "plaintext"),
           sampleHighlight.length > 0,
           let color = sampleHighlight.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor {
            self.themeTextColor = color
        }

        let delegate = HighlightingTextStorageDelegate(
            highlighter: highlighter,
            language: "markdown",
            font: Self.editorFont,
            paragraphStyle: paragraphStyle,
            shouldDeferHighlighting: { [weak textView] in
                textView?.hasActiveMentionCompletion() == true
            },
            didApplyHighlighting: { [weak self] in
                self?.updateInputAttributes()
            }
        )
        textView.onCompletionSessionEnded = { [weak delegate] in
            delegate?.resumeDeferredHighlightingIfNeeded()
        }
        textStorage.delegate = delegate
        self.highlightingDelegate = delegate
    }

    private func configureTextView(_ textView: NSTextView, paragraphStyle: NSParagraphStyle) {
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

        var markedAttributes = textView.markedTextAttributes ?? [:]
        markedAttributes[.font] = font
        markedAttributes[.foregroundColor] = foregroundColor
        markedAttributes[.paragraphStyle] = paragraphStyle
        textView.markedTextAttributes = markedAttributes
    }

    private func applyEditorParagraphStyle() {
        guard let textView = self.textView else { return }

        textView.defaultParagraphStyle = editorParagraphStyle

        guard let textStorage = textView.textStorage, textStorage.length > 0 else { return }
        let fullRange = NSRange(location: 0, length: textStorage.length)
        textStorage.addAttribute(.paragraphStyle, value: editorParagraphStyle!, range: fullRange)
    }
}
