import Foundation
import XCTest
@testable import nanoedit

final class MentionCompletionTests: XCTestCase {
    func testParserFindsMentionAtCursor() {
        let parser = MentionCompletionParser()
        let match = parser.findMention(
            in: "open @Sources/nanoedit",
            selectionRange: NSRange(location: 22, length: 0)
        )

        XCTAssertEqual(
            match,
            MentionMatch(
                completionRange: NSRange(location: 6, length: 16),
                typedPath: "Sources/nanoedit",
                replacementRange: NSRange(location: 5, length: 17)
            )
        )
    }

    func testParserIgnoresMentionsSeparatedByWhitespace() {
        let parser = MentionCompletionParser()
        let match = parser.findMention(
            in: "open @Sources test",
            selectionRange: NSRange(location: 18, length: 0)
        )

        XCTAssertNil(match)
    }

    func testCompleterListsRootCandidatesForEmptyPrefix() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        try FileManager.default.createDirectory(
            at: rootURL.appendingPathComponent("Sources", isDirectory: true),
            withIntermediateDirectories: true
        )
        try "readme".write(
            to: rootURL.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )

        let completer = FilePathCompleter(rootURL: rootURL)
        let candidates = completer.completions(for: "")

        XCTAssertTrue(candidates.contains("Sources/"))
        XCTAssertTrue(candidates.contains("README.md"))
    }

    func testCompleterRecursesWhenPrefixIsPresent() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let nestedDirectoryURL = rootURL
            .appendingPathComponent("Sources", isDirectory: true)
            .appendingPathComponent("nanoedit", isDirectory: true)
        try FileManager.default.createDirectory(
            at: nestedDirectoryURL,
            withIntermediateDirectories: true
        )
        try "struct Example {}".write(
            to: nestedDirectoryURL.appendingPathComponent("Editor.swift"),
            atomically: true,
            encoding: .utf8
        )

        let completer = FilePathCompleter(rootURL: rootURL)
        let candidates = completer.completions(for: "S")

        XCTAssertTrue(candidates.contains("Sources/"))
        XCTAssertTrue(candidates.contains("Sources/nanoedit/"))
        XCTAssertTrue(candidates.contains("Sources/nanoedit/Editor.swift"))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }
}
