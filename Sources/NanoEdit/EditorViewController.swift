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

// Applies syntax highlighting asynchronously to avoid re-entering textStorage editing.
class HighlightingTextStorageDelegate: NSObject, NSTextStorageDelegate {
    private let highlighter: Highlighter
    private let language: String
    private let font: NSFont
    private let didApplyHighlighting: (() -> Void)?
    private var pendingHighlight = false

    init(highlighter: Highlighter, language: String, font: NSFont, didApplyHighlighting: (() -> Void)? = nil) {
        self.highlighter = highlighter
        self.language = language
        self.font = font
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
            textStorage.setAttributes(merged, range: range)
        }
        textStorage.endEditing()
        didApplyHighlighting?()
    }
}

class EditorViewController: NSViewController, NSWindowDelegate, NSTextViewDelegate {
    static let editorFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    let filePath: String
    private var textView: NSTextView!
    private var originalContent: String = ""
    private var highlightingDelegate: HighlightingTextStorageDelegate?
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
                didApplyHighlighting: { [weak self] in
                    self?.updateInputAttributes()
                }
            )
            textStorage.delegate = delegate
            self.highlightingDelegate = delegate
        }

        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)

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
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.font = Self.editorFont
        textView.delegate = self

        textView.drawsBackground = false
        textView.textColor = themeTextColor
        textView.insertionPointColor = themeTextColor

        scrollView.documentView = textView
        visualEffectView.addSubview(scrollView)
        self.textView = textView
        self.view = visualEffectView
        updateInputAttributes()
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
        var foregroundColor: NSColor = themeTextColor

        if let textStorage = textView.textStorage, textStorage.length > 0 {
            let location = textView.selectedRange().location
            if location > 0,
               let color = textStorage.attribute(.foregroundColor, at: location - 1, effectiveRange: nil) as? NSColor {
                foregroundColor = color
            }
        }

        textView.typingAttributes = [.font: font, .foregroundColor: foregroundColor]

        var markedAttrs = textView.markedTextAttributes ?? [:]
        markedAttrs[.font] = font
        markedAttrs[.foregroundColor] = foregroundColor
        textView.markedTextAttributes = markedAttrs
    }
}
