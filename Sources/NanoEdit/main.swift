import AppKit

// Validate command line arguments
guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write(Data("Usage: nanoedit <filepath>\n".utf8))
    exit(1)
}

let filePath = CommandLine.arguments[1]

let app = NSApplication.shared
let delegate = AppDelegate(filePath: filePath)
app.delegate = delegate
app.run()
