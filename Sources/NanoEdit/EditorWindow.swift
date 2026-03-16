import AppKit

class EditorWindow: NSWindow {
    init(contentViewController viewController: NSViewController) {
        let defaultFrame = NSRect(x: 0, y: 0, width: 600, height: 400)

        super.init(
            contentRect: defaultFrame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        self.contentViewController = viewController
        self.level = .floating
        self.isReleasedWhenClosed = false
        self.setFrameAutosaveName("NanoEditWindow")

        // Transparent title bar (keep traffic light buttons)
        self.titlebarAppearsTransparent = true
        self.titleVisibility = .hidden
        self.isMovableByWindowBackground = true

        // Translucent background
        self.isOpaque = false
        self.backgroundColor = .clear

        // Center only if no saved frame exists
        if !self.setFrameUsingName("NanoEditWindow") {
            self.center()
        }
    }
}
