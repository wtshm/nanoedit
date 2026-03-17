import AppKit

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

// Provides @-mention file path completion using the AppKit completion system.
final class MentionCompletingTextView: EscapeHandlingTextView {
    struct MentionMatch {
        let completionRange: NSRange
        let typedPath: String
        let replacementRange: NSRange
    }

    var completionRootURL: URL?
    private var isApplyingMentionCompletion = false
    private var lastEditWasInsertion = false

    override var rangeForUserCompletion: NSRange {
        if let mentionMatch = findMentionAtCursor() {
            return mentionMatch.completionRange
        }
        return super.rangeForUserCompletion
    }

    override func completions(
        forPartialWordRange charRange: NSRange,
        indexOfSelectedItem index: UnsafeMutablePointer<Int>
    ) -> [String]? {
        guard let mentionMatch = findMentionAtCursor(),
              NSEqualRanges(mentionMatch.completionRange, charRange),
              let completionRootURL else {
            return super.completions(forPartialWordRange: charRange, indexOfSelectedItem: index)
        }

        let completer = FilePathCompleter(rootURL: completionRootURL)
        let completions = completer.completions(for: mentionMatch.typedPath)
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
        guard let mentionMatch = findMentionAtCursor(),
              NSEqualRanges(mentionMatch.completionRange, charRange) else {
            super.insertCompletion(word, forPartialWordRange: charRange, movement: movement, isFinal: flag)
            return
        }

        guard flag else { return }
        guard shouldCommitMentionCompletion(for: movement) else { return }

        let completedWord = "\(word) "
        let completedWordLength = (completedWord as NSString).length

        guard shouldChangeText(in: mentionMatch.replacementRange, replacementString: completedWord) else { return }

        isApplyingMentionCompletion = true
        textStorage?.replaceCharacters(in: mentionMatch.replacementRange, with: completedWord)
        didChangeText()
        setSelectedRange(NSRange(
            location: mentionMatch.replacementRange.location + completedWordLength,
            length: 0
        ))
        isApplyingMentionCompletion = false
    }

    override func didChangeText() {
        super.didChangeText()

        guard isApplyingMentionCompletion == false else { return }
        guard hasMarkedText() == false else { return }

        defer { lastEditWasInsertion = false }
        guard lastEditWasInsertion else { return }
        guard findMentionAtCursor() != nil else { return }

        complete(nil)
    }

    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        if isApplyingMentionCompletion == false {
            let replacementLength = ((replacementString ?? "") as NSString).length
            lastEditWasInsertion = (affectedCharRange.length == 0 && replacementLength > 0)
        }

        return super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
    }

    private func findMentionAtCursor() -> MentionMatch? {
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

    private static let mentionPathCharacters: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "/._-~")
        return set
    }()

    private static func isMentionPathCharacter(_ scalar: UnicodeScalar) -> Bool {
        mentionPathCharacters.contains(scalar)
    }
}

// Generates file path completion candidates from the filesystem.
private struct FilePathCompleter {
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

        let directoryPrefixLength = searchDirectoryPath.count + 1 // +1 for trailing "/"
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
