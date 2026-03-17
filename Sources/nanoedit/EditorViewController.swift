import AppKit
import Highlighter

// NSTextView subclass that forwards Escape to close the window instead of autocomplete.
class EscapeHandlingTextView: NSTextView {
    private static let escapeKeyCode: UInt16 = 53

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == Self.escapeKeyCode {
            window?.performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

final class MentionAwareTextView: EscapeHandlingTextView {
    struct MentionQuery {
        let completionRange: NSRange
        let typedPath: String
        let replacementRange: NSRange
    }

    private enum EditKind {
        case none
        case insertion
        case deletion
        case replacement
    }

    private static let maxCompletionCandidates = 10000

    var completionRootURL: URL?
    private var isApplyingMentionCompletion = false
    private var lastEditKind: EditKind = .none

    override var rangeForUserCompletion: NSRange {
        if let mentionQuery = makeMentionQuery() {
            return mentionQuery.completionRange
        }
        return super.rangeForUserCompletion
    }

    override func completions(
        forPartialWordRange charRange: NSRange,
        indexOfSelectedItem index: UnsafeMutablePointer<Int>
    ) -> [String]? {
        guard let mentionQuery = makeMentionQuery(),
              NSEqualRanges(mentionQuery.completionRange, charRange),
              let completionRootURL else {
            return super.completions(forPartialWordRange: charRange, indexOfSelectedItem: index)
        }

        let completions = makeFileCompletions(for: mentionQuery.typedPath, rootURL: completionRootURL)
        if completions.isEmpty {
            return []
        }

        index.pointee = 0
        return completions
    }

    override func insertCompletion(
        _ word: String,
        forPartialWordRange charRange: NSRange,
        movement: Int,
        isFinal flag: Bool
    ) {
        guard let mentionQuery = makeMentionQuery(),
              NSEqualRanges(mentionQuery.completionRange, charRange) else {
            super.insertCompletion(word, forPartialWordRange: charRange, movement: movement, isFinal: flag)
            return
        }

        guard flag else { return }
        guard shouldCommitMentionCompletion(for: movement) else { return }

        let completedWord = "\(word) "
        let completedWordLength = (completedWord as NSString).length

        guard shouldChangeText(in: mentionQuery.replacementRange, replacementString: completedWord) else { return }

        isApplyingMentionCompletion = true
        textStorage?.replaceCharacters(in: mentionQuery.replacementRange, with: completedWord)
        didChangeText()
        setSelectedRange(NSRange(
            location: mentionQuery.replacementRange.location + completedWordLength,
            length: 0
        ))
        isApplyingMentionCompletion = false
    }

    override func didChangeText() {
        super.didChangeText()

        guard isApplyingMentionCompletion == false else { return }
        guard hasMarkedText() == false else { return }

        defer { lastEditKind = .none }
        guard lastEditKind == .insertion else { return }
        guard makeMentionQuery() != nil else { return }

        complete(nil)
    }

    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        if isApplyingMentionCompletion {
            return super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
        }

        let replacementLength = ((replacementString ?? "") as NSString).length
        if affectedCharRange.length == 0, replacementLength > 0 {
            lastEditKind = .insertion
        } else if affectedCharRange.length > 0, replacementLength == 0 {
            lastEditKind = .deletion
        } else if affectedCharRange.length > 0 || replacementLength > 0 {
            lastEditKind = .replacement
        } else {
            lastEditKind = .none
        }

        return super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
    }

    private func makeMentionQuery() -> MentionQuery? {
        let selectionRange = selectedRange()
        let nsString = string as NSString
        let cursorLocation = selectionRange.location
        let selectionEnd = selectionRange.location + selectionRange.length
        guard cursorLocation <= nsString.length, selectionEnd <= nsString.length else { return nil }

        var scanLocation = cursorLocation
        while scanLocation > 0 {
            let scalarValue = nsString.character(at: scanLocation - 1)
            guard let scalar = UnicodeScalar(scalarValue) else { return nil }

            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                return nil
            }

            if scalar == "@" {
                let completionRange = NSRange(
                    location: scanLocation,
                    length: cursorLocation - scanLocation
                )
                let replacementRange = NSRange(
                    location: scanLocation - 1,
                    length: findMentionPathEnd(in: nsString, from: selectionEnd) - (scanLocation - 1)
                )
                let typedPath = nsString.substring(with: completionRange)
                return MentionQuery(
                    completionRange: completionRange,
                    typedPath: typedPath,
                    replacementRange: replacementRange
                )
            }

            guard Self.isMentionPathCharacter(scalar) else {
                return nil
            }

            scanLocation -= 1
        }

        return nil
    }

    private func shouldCommitMentionCompletion(for movement: Int) -> Bool {
        switch movement {
        case NSTextMovement.cancel.rawValue:
            return false
        case NSTextMovement.tab.rawValue, NSTextMovement.return.rawValue:
            return true
        case NSTextMovement.other.rawValue:
            switch NSApp.currentEvent?.type {
            case .leftMouseDown, .leftMouseUp:
                return true
            default:
                return false
            }
        default:
            return false
        }
    }

    private func findMentionPathEnd(in text: NSString, from location: Int) -> Int {
        var scanLocation = location
        while scanLocation < text.length {
            let scalarValue = text.character(at: scanLocation)
            guard let scalar = UnicodeScalar(scalarValue),
                  Self.isMentionPathCharacter(scalar) else { break }
            scanLocation += 1
        }
        return scanLocation
    }

    private func makeFileCompletions(for typedPath: String, rootURL: URL) -> [String] {
        let pathParts = splitTypedPath(typedPath)
        let searchDirectoryURL: URL
        if pathParts.parentPath.isEmpty {
            searchDirectoryURL = rootURL
        } else {
            searchDirectoryURL = rootURL.appendingPathComponent(pathParts.parentPath, isDirectory: true)
        }
        let searchDirectoryPath = searchDirectoryURL.standardizedFileURL.path

        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if pathParts.namePrefix.hasPrefix(".") == false {
            options.insert(.skipsHiddenFiles)
        }

        let fileURLs = makeCandidateFileURLs(
            in: searchDirectoryURL,
            options: options,
            recursively: pathParts.namePrefix.isEmpty == false
        )

        let prefixLength = searchDirectoryPath.count + 1 // +1 for trailing "/"
        var completions = fileURLs.compactMap { fileURL -> (value: String, isDirectory: Bool)? in
            let fullPath = fileURL.standardizedFileURL.path
            guard fullPath.hasPrefix(searchDirectoryPath),
                  fullPath.count > prefixLength else { return nil }
            let relativePath = String(fullPath.dropFirst(prefixLength))
            guard relativePath.hasPrefix(pathParts.namePrefix) else { return nil }
            guard relativePath != pathParts.namePrefix else { return nil }

            let isDirectory = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let completionValue = pathParts.parentPath.isEmpty
                ? relativePath
                : "\(pathParts.parentPath)/\(relativePath)"
            return (isDirectory ? "\(completionValue)/" : completionValue, isDirectory)
        }

        for dotEntry in makeDotEntryCompletions(for: pathParts) {
            completions.append((dotEntry, true))
        }

        completions.sort { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory && !rhs.isDirectory
            }
            return lhs.value.localizedStandardCompare(rhs.value) == .orderedAscending
        }

        return completions.map(\.value)
    }

    private func makeCandidateFileURLs(
        in directoryURL: URL,
        options: FileManager.DirectoryEnumerationOptions,
        recursively: Bool
    ) -> [URL] {
        if recursively == false {
            return (try? FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: options
            )) ?? []
        }

        guard let enumerator = FileManager.default.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: options
        ) else {
            return []
        }

        var results: [URL] = []
        results.reserveCapacity(min(Self.maxCompletionCandidates, 256))
        for case let url as URL in enumerator {
            results.append(url)
            if results.count >= Self.maxCompletionCandidates { break }
        }
        return results
    }

    private func splitTypedPath(_ typedPath: String) -> (parentPath: String, namePrefix: String) {
        guard typedPath.isEmpty == false else { return ("", "") }

        if typedPath.hasSuffix("/") {
            return (String(typedPath.dropLast()), "")
        }

        guard let slashIndex = typedPath.lastIndex(of: "/") else {
            return ("", typedPath)
        }

        let parentPath = String(typedPath[..<slashIndex])
        let namePrefix = String(typedPath[typedPath.index(after: slashIndex)...])
        return (parentPath, namePrefix)
    }

    private func makeDotEntryCompletions(for pathParts: (parentPath: String, namePrefix: String)) -> [String] {
        guard pathParts.parentPath.isEmpty else { return [] }
        guard pathParts.namePrefix.hasPrefix(".") else { return [] }

        return ["./", "../"].filter { $0.hasPrefix(pathParts.namePrefix) }
    }

    private static let mentionPathCharacters: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "/._-~")
        return set
    }()

    private static func isMentionPathCharacter(_ scalar: UnicodeScalar) -> Bool {
        mentionPathCharacters.contains(scalar)
    }
}

private final class FixedLineMetricsDelegate: NSObject, NSLayoutManagerDelegate {
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
    private var isHighlightPending = false

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
        guard editedMask.contains(.editedCharacters), !isHighlightPending else { return }

        isHighlightPending = true
        DispatchQueue.main.async { [weak self, weak textStorage] in
            guard let textStorage else { return }
            self?.applyHighlighting(to: textStorage)
        }
    }

    private func applyHighlighting(to textStorage: NSTextStorage) {
        defer { isHighlightPending = false }

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
}

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
    private var lineMetricsDelegate: FixedLineMetricsDelegate?
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

        let lineMetrics = FixedLineMetricsDelegate(
            primaryFont: Self.editorFont,
            fallbackFont: Self.fallbackEditorFont
        )
        layoutManager.delegate = lineMetrics
        self.lineMetricsDelegate = lineMetrics

        let paragraphStyle = Self.makeEditorParagraphStyle(lineHeight: lineMetrics.lineHeight)
        self.editorParagraphStyle = paragraphStyle

        setupHighlighting(textStorage: textStorage, paragraphStyle: paragraphStyle)

        let containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        let textContainer = NSTextContainer(size: containerSize)
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)

        let textView = MentionAwareTextView(frame: scrollView.bounds, textContainer: textContainer)
        textView.completionRootURL = URL(fileURLWithPath: workingDirectoryPath, isDirectory: true)
        configureTextView(textView, paragraphStyle: paragraphStyle)
        return textView
    }

    private func setupHighlighting(textStorage: NSTextStorage, paragraphStyle: NSParagraphStyle) {
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
            didApplyHighlighting: { [weak self] in
                self?.updateInputAttributes()
            }
        )
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
