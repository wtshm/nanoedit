import AppKit
import Highlightr

// Custom NSTextView that forwards Escape to the window's close handler.
// NSTextView consumes Escape for autocomplete by default, so we intercept it here.
class EscapeHandlingTextView: NSTextView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 53 { // Escape
            window?.performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

class EditorViewController: NSViewController, NSWindowDelegate {
    let filePath: String
    private var textView: NSTextView!
    private var originalContent: String = ""

    init(filePath: String) {
        self.filePath = filePath
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autoresizingMask = [.width, .height]

        // Set up Highlightr with CodeAttributedString
        let highlightr = Highlightr()!
        highlightr.setTheme(to: "monokai")
        let textStorage = CodeAttributedString(highlightr: highlightr)
        textStorage.language = "markdown"

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
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.backgroundColor = highlightr.theme.themeBackgroundColor

        // Set text color and insertion point color for dark theme
        textView.textColor = .white
        textView.insertionPointColor = .white

        scrollView.documentView = textView
        self.textView = textView
        self.view = scrollView
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
                originalContent = ""
            }
        } else {
            originalContent = ""
        }
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
}
