import AppKit

// NSTextView subclass that forwards Escape to close the window unless a subclass handles it.
class EscapeHandlingTextView: NSTextView {
    private static let escapeKeyCode: UInt16 = 53

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == Self.escapeKeyCode {
            return handleEscapeKeyEquivalent()
        }
        return super.performKeyEquivalent(with: event)
    }

    func handleEscapeKeyEquivalent() -> Bool {
        window?.performClose(nil)
        return true
    }
}

struct MentionMatch: Equatable {
    let completionRange: NSRange
    let typedPath: String
    let replacementRange: NSRange
}

struct MentionCompletionParser {
    func findMention(in text: String, selectionRange: NSRange) -> MentionMatch? {
        let nsString = text as NSString
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
                return MentionMatch(
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

    private static let mentionPathCharacters: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "/._-~")
        return set
    }()

    private static func isMentionPathCharacter(_ scalar: UnicodeScalar) -> Bool {
        mentionPathCharacters.contains(scalar)
    }
}

private struct MentionCompletionSession {
    let match: MentionMatch
    let candidates: [String]
    var selectedIndex: Int

    var selectedCandidate: String? {
        guard candidates.indices.contains(selectedIndex) else { return nil }
        return candidates[selectedIndex]
    }
}

private final class MentionCompletionPopupView: NSVisualEffectView, NSTableViewDataSource, NSTableViewDelegate {
    private static let maxVisibleRows = 8
    private static let horizontalPadding: CGFloat = 12
    private static let verticalPadding: CGFloat = 8
    private static let borderInset: CGFloat = 1

    private let popupFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("candidate"))
    private var candidates: [String] = []

    var onSelectCandidate: ((String) -> Void)?

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)

        material = .menu
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        clipsToBounds = true

        tableColumn.resizingMask = .autoresizingMask
        tableView.addTableColumn(tableColumn)
        tableView.headerView = nil
        tableView.focusRingType = .none
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.rowHeight = 22
        tableView.intercellSpacing = .zero
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = false
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.delegate = self
        tableView.dataSource = self
        tableView.target = self
        tableView.action = #selector(handleTableAction(_:))

        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = tableView

        addSubview(scrollView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds.insetBy(dx: Self.borderInset, dy: Self.borderInset)
        tableColumn.width = scrollView.contentSize.width
        tableView.frame = NSRect(origin: .zero, size: tableContentSize(for: candidates))
    }

    func preferredSize(for candidates: [String]) -> NSSize {
        let contentSize = tableContentSize(for: candidates)
        return NSSize(
            width: contentSize.width + Self.borderInset * 2,
            height: min(
                contentSize.height,
                CGFloat(Self.maxVisibleRows) * tableView.rowHeight + Self.verticalPadding * 2
            ) + Self.borderInset * 2
        )
    }

    func update(candidates: [String], selectedIndex: Int) {
        self.candidates = candidates
        scrollView.hasVerticalScroller = candidates.count > Self.maxVisibleRows
        tableView.reloadData()
        let rowCount = tableView.numberOfRows
        if rowCount > 0 {
            let clampedIndex = min(max(selectedIndex, 0), rowCount - 1)
            tableView.selectRowIndexes(IndexSet(integer: clampedIndex), byExtendingSelection: false)
            tableView.scrollRowToVisible(clampedIndex)
        }
        needsLayout = true
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        candidates.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("candidateCell")
        let textField: NSTextField
        if let reusedView = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField {
            textField = reusedView
        } else {
            textField = NSTextField(labelWithString: "")
            textField.identifier = identifier
            textField.lineBreakMode = .byTruncatingMiddle
            textField.font = popupFont
            textField.textColor = .labelColor
        }

        textField.stringValue = candidates[row]
        return textField
    }

    @objc private func handleTableAction(_ sender: Any?) {
        let row = tableView.clickedRow
        guard candidates.indices.contains(row) else { return }
        onSelectCandidate?(candidates[row])
    }

    private func tableContentSize(for candidates: [String]) -> NSSize {
        let attributes: [NSAttributedString.Key: Any] = [.font: popupFont]
        let widestCandidate = candidates
            .map { ($0 as NSString).size(withAttributes: attributes).width }
            .max() ?? 160
        let width = min(max(widestCandidate + Self.horizontalPadding * 2, 220), 520)
        let height = CGFloat(candidates.count) * tableView.rowHeight + Self.verticalPadding * 2
        return NSSize(width: width, height: height)
    }
}

// Provides @-mention file path completion using a custom popup.
final class MentionCompletingTextView: EscapeHandlingTextView {
    var completionRootURL: URL?
    var onCompletionSessionEnded: (() -> Void)?

    private let mentionParser = MentionCompletionParser()
    private var isApplyingMentionCompletion = false
    private var completionSession: MentionCompletionSession?
    private weak var observedClipView: NSClipView?
    private weak var observedWindow: NSWindow?

    private lazy var popupView: MentionCompletionPopupView = {
        let view = MentionCompletionPopupView()
        view.onSelectCandidate = { [weak self] candidate in
            self?.commitMentionCompletion(with: candidate)
        }
        return view
    }()

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSelectionDidChange(_:)),
            name: NSTextView.didChangeSelectionNotification,
            object: self
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        updateLayoutObservers()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateLayoutObservers()
    }

    override func resignFirstResponder() -> Bool {
        if isMouseEventInsidePopup() == false {
            dismissMentionCompletion()
        }
        return super.resignFirstResponder()
    }

    override func handleEscapeKeyEquivalent() -> Bool {
        if hasActiveMentionCompletion() {
            dismissMentionCompletion()
            return true
        }
        return super.handleEscapeKeyEquivalent()
    }

    override func didChangeText() {
        super.didChangeText()

        guard isApplyingMentionCompletion == false else { return }
        guard hasMarkedText() == false else { return }

        refreshMentionCompletion()
    }

    override func doCommand(by selector: Selector) {
        guard hasActiveMentionCompletion() else {
            super.doCommand(by: selector)
            return
        }

        switch selector {
        case #selector(moveUp(_:)):
            moveSelection(delta: -1)
        case #selector(moveDown(_:)):
            moveSelection(delta: 1)
        case #selector(insertTab(_:)),
             #selector(insertNewline(_:)),
             #selector(insertNewlineIgnoringFieldEditor(_:)):
            guard let candidate = completionSession?.selectedCandidate else { return }
            commitMentionCompletion(with: candidate)
        case #selector(cancelOperation(_:)):
            dismissMentionCompletion()
        default:
            super.doCommand(by: selector)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        if hasActiveMentionCompletion() {
            dismissMentionCompletion()
            return
        }
        super.cancelOperation(sender)
    }

    func hasActiveMentionCompletion() -> Bool {
        completionSession != nil
    }

    @objc private func handleSelectionDidChange(_ notification: Notification) {
        guard isApplyingMentionCompletion == false else { return }
        guard hasMarkedText() == false else { return }
        guard hasActiveMentionCompletion() else { return }

        refreshMentionCompletion()
    }

    @objc private func handleClipViewBoundsDidChange(_ notification: Notification) {
        guard hasActiveMentionCompletion() else { return }
        refreshPopupPlacement()
    }

    @objc private func handleWindowDidMoveOrResize(_ notification: Notification) {
        guard hasActiveMentionCompletion() else { return }
        refreshPopupPlacement()
    }

    private func refreshMentionCompletion() {
        guard let mentionMatch = findMentionAtCursor(),
              let completionRootURL else {
            dismissMentionCompletion()
            return
        }

        let selectedCandidate = completionSession?.selectedCandidate
        let completer = FilePathCompleter(rootURL: completionRootURL)
        let candidates = completer.completions(for: mentionMatch.typedPath)
        guard candidates.isEmpty == false else {
            dismissMentionCompletion()
            return
        }

        let selectedIndex = selectedCandidate.flatMap { candidates.firstIndex(of: $0) } ?? 0
        completionSession = MentionCompletionSession(
            match: mentionMatch,
            candidates: candidates,
            selectedIndex: selectedIndex
        )
        showOrUpdatePopup(for: candidates, selectedIndex: selectedIndex)
    }

    private func moveSelection(delta: Int) {
        guard var session = completionSession, session.candidates.isEmpty == false else { return }

        let nextIndex = min(max(session.selectedIndex + delta, 0), session.candidates.count - 1)
        session.selectedIndex = nextIndex
        completionSession = session
        popupView.update(candidates: session.candidates, selectedIndex: nextIndex)
    }

    private func commitMentionCompletion(with candidate: String) {
        guard let mentionMatch = findMentionAtCursor() else {
            dismissMentionCompletion()
            return
        }

        let replacement = "\(candidate) "
        guard shouldChangeText(in: mentionMatch.replacementRange, replacementString: replacement) else { return }

        let shouldNotifySessionEnd = dismissMentionCompletion(notify: false)
        isApplyingMentionCompletion = true
        textStorage?.replaceCharacters(in: mentionMatch.replacementRange, with: replacement)
        didChangeText()
        setSelectedRange(NSRange(
            location: mentionMatch.replacementRange.location + (replacement as NSString).length,
            length: 0
        ))
        isApplyingMentionCompletion = false

        if shouldNotifySessionEnd {
            onCompletionSessionEnded?()
        }

        window?.makeFirstResponder(self)
    }

    private func showOrUpdatePopup(for candidates: [String], selectedIndex: Int) {
        guard let hostView = popupHostView(),
              let popupFrame = popupFrame(for: candidates, in: hostView) else {
            dismissMentionCompletion()
            return
        }

        if popupView.superview !== hostView {
            popupView.removeFromSuperview()
            hostView.addSubview(popupView)
        }

        popupView.frame = popupFrame
        popupView.update(candidates: candidates, selectedIndex: selectedIndex)
    }

    private func refreshPopupPlacement() {
        guard let session = completionSession else { return }
        showOrUpdatePopup(for: session.candidates, selectedIndex: session.selectedIndex)
    }

    @discardableResult
    private func dismissMentionCompletion(notify: Bool = true) -> Bool {
        let hadActiveSession = completionSession != nil
        completionSession = nil
        popupView.removeFromSuperview()

        if notify && hadActiveSession {
            onCompletionSessionEnded?()
        }

        return hadActiveSession
    }

    private func popupHostView() -> NSView? {
        enclosingScrollView?.superview ?? superview ?? window?.contentView
    }

    private func isMouseEventInsidePopup() -> Bool {
        guard popupView.superview != nil,
              let event = NSApp.currentEvent,
              event.type == .leftMouseDown || event.type == .leftMouseUp else {
            return false
        }

        let point = popupView.convert(event.locationInWindow, from: nil)
        return popupView.bounds.contains(point)
    }

    private func popupFrame(for candidates: [String], in hostView: NSView) -> NSRect? {
        guard let caretRectInWindow = currentCaretRectInWindow() else {
            return nil
        }

        let hostRect = hostView.convert(caretRectInWindow, from: nil)
        let popupSize = popupView.preferredSize(for: candidates)
        let horizontalPadding: CGFloat = 6
        let verticalPadding: CGFloat = 4

        var originX = min(hostRect.minX, hostView.bounds.maxX - popupSize.width - horizontalPadding)
        originX = max(horizontalPadding, originX)

        let hasRoomBelow = hostRect.minY - popupSize.height - verticalPadding >= hostView.bounds.minY
        var originY = hasRoomBelow
            ? hostRect.minY - popupSize.height - verticalPadding
            : hostRect.maxY + verticalPadding

        if originY + popupSize.height > hostView.bounds.maxY - verticalPadding {
            originY = hostView.bounds.maxY - popupSize.height - verticalPadding
        }
        originY = max(verticalPadding, originY)

        return NSRect(origin: NSPoint(x: originX, y: originY), size: popupSize)
    }

    private func currentCaretRectInWindow() -> NSRect? {
        guard let layoutManager,
              let textContainer else {
            return nil
        }

        let selectedLocation = min(selectedRange().location, (string as NSString).length)
        var glyphIndex = layoutManager.glyphIndexForCharacter(at: selectedLocation)
        if layoutManager.numberOfGlyphs == 0 {
            return NSRect(origin: NSPoint(x: textContainerInset.width, y: textContainerInset.height), size: .zero)
        }

        if glyphIndex >= layoutManager.numberOfGlyphs {
            glyphIndex = max(layoutManager.numberOfGlyphs - 1, 0)
        }

        let characterRange = layoutManager.characterRange(
            forGlyphRange: NSRange(location: glyphIndex, length: 1),
            actualGlyphRange: nil
        )
        let isAtEndOfCharacter = selectedLocation >= NSMaxRange(characterRange)
        let lineFragmentRect = layoutManager.lineFragmentUsedRect(forGlyphAt: glyphIndex, effectiveRange: nil)
        var glyphLocation = layoutManager.location(forGlyphAt: glyphIndex)
        if isAtEndOfCharacter {
            let glyphRect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyphIndex, length: 1), in: textContainer)
            glyphLocation.x = glyphRect.maxX
        }

        let caretPointInTextView = NSPoint(
            x: textContainerInset.width + glyphLocation.x,
            y: textContainerInset.height + lineFragmentRect.minY
        )
        let caretRectInTextView = NSRect(
            x: caretPointInTextView.x,
            y: caretPointInTextView.y,
            width: 1,
            height: lineFragmentRect.height
        )
        return convert(caretRectInTextView, to: nil)
    }

    private func updateLayoutObservers() {
        if observedClipView !== enclosingScrollView?.contentView {
            if let observedClipView {
                NotificationCenter.default.removeObserver(
                    self,
                    name: NSView.boundsDidChangeNotification,
                    object: observedClipView
                )
            }

            observedClipView = enclosingScrollView?.contentView
            observedClipView?.postsBoundsChangedNotifications = true
            if let observedClipView {
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(handleClipViewBoundsDidChange(_:)),
                    name: NSView.boundsDidChangeNotification,
                    object: observedClipView
                )
            }
        }

        if observedWindow !== window {
            if let observedWindow {
                NotificationCenter.default.removeObserver(
                    self,
                    name: NSWindow.didResizeNotification,
                    object: observedWindow
                )
                NotificationCenter.default.removeObserver(
                    self,
                    name: NSWindow.didMoveNotification,
                    object: observedWindow
                )
            }

            observedWindow = window
            if let observedWindow {
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(handleWindowDidMoveOrResize(_:)),
                    name: NSWindow.didResizeNotification,
                    object: observedWindow
                )
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(handleWindowDidMoveOrResize(_:)),
                    name: NSWindow.didMoveNotification,
                    object: observedWindow
                )
            }
        }
    }

    private func findMentionAtCursor() -> MentionMatch? {
        mentionParser.findMention(in: string, selectionRange: selectedRange())
    }
}

// Generates file path completion candidates from the filesystem.
struct FilePathCompleter {
    private static let maxCandidates = 10000
    let rootURL: URL

    func completions(for typedPath: String) -> [String] {
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

        let fileURLs = candidateFileURLs(
            in: searchDirectoryURL,
            options: options,
            recursively: pathParts.namePrefix.isEmpty == false
        )

        let directoryPrefixLength = searchDirectoryPath.count + 1
        var completions = fileURLs.compactMap { fileURL -> (value: String, isDirectory: Bool)? in
            let fullPath = fileURL.standardizedFileURL.path
            guard fullPath.hasPrefix(searchDirectoryPath),
                  fullPath.count > directoryPrefixLength else { return nil }
            let relativePath = String(fullPath.dropFirst(directoryPrefixLength))
            guard relativePath.hasPrefix(pathParts.namePrefix) else { return nil }
            guard relativePath != pathParts.namePrefix else { return nil }

            let isDirectory = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let completionValue = pathParts.parentPath.isEmpty
                ? relativePath
                : "\(pathParts.parentPath)/\(relativePath)"
            return (isDirectory ? "\(completionValue)/" : completionValue, isDirectory)
        }

        for dotEntry in dotEntryCompletions(for: pathParts) {
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

    private func candidateFileURLs(
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
        results.reserveCapacity(min(Self.maxCandidates, 256))
        for case let url as URL in enumerator {
            results.append(url)
            if results.count >= Self.maxCandidates { break }
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

    private func dotEntryCompletions(for pathParts: (parentPath: String, namePrefix: String)) -> [String] {
        guard pathParts.parentPath.isEmpty else { return [] }
        guard pathParts.namePrefix.hasPrefix(".") else { return [] }

        return ["./", "../"].filter { $0.hasPrefix(pathParts.namePrefix) }
    }
}
