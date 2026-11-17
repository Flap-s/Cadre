import AppKit

/// Closes a capture's thumbnail once it has been pasted somewhere.
///
/// Reads of the clipboard can't tell a paste apart from Spotlight's clipboard history or a clipboard
/// manager, which read every copy. So Cadre looks for the paste gesture itself: ⌘V pressed while the
/// capture is still what's on the clipboard. Watching key presses needs Accessibility access, and the
/// monitor only runs while a capture is waiting to be pasted.
@MainActor
final class PasteWatcher {
    static let shared = PasteWatcher()

    init() {}

    var onPaste: (CaptureItem) -> Void = { QuickAccessManager.shared.dismiss($0) }
    /// Stop watching after this long, if the capture was never pasted.
    var timeout: TimeInterval = 15 * 60

    private var watched: (item: CaptureItem, pasteboard: NSPasteboard, changeCount: Int)?
    private var monitor: Any?
    private var expiry: Timer?

    var isWatching: Bool { watched != nil }
    var isMonitoringKeys: Bool { monitor != nil }

    func watch(_ item: CaptureItem, pasteboard: NSPasteboard = .general) {
        watched = (item, pasteboard, pasteboard.changeCount)
        expiry?.invalidate()
        expiry = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { _ in
            MainActor.assumeIsolated { PasteWatcher.shared.stop() }
        }
        if Permissions.ensureAccessibility(prompt: false) {
            startMonitor()
        } else {
            Self.askForAccessibilityOnce()
        }
    }

    func forget(_ item: CaptureItem) {
        if watched?.item === item { stop() }
    }

    func stop() {
        watched = nil
        expiry?.invalidate()
        expiry = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// A key press anywhere in the system (internal for tests).
    func handleKeyDown(characters: String?, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        guard let w = watched else { return }
        guard w.pasteboard.changeCount == w.changeCount else {
            stop() // something else was copied since: the capture can no longer be pasted
            return
        }
        let flags = modifiers.intersection([.command, .control, .option])
        let isV = characters?.lowercased() == "v" || keyCode == 9 // kVK_ANSI_V
        guard flags.contains(.command), !flags.contains(.control), isV else { return }
        let item = w.item
        stop()
        // Let the target app take the image before the thumbnail goes away.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [onPaste] in
            MainActor.assumeIsolated { onPaste(item) }
        }
    }

    private func startMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            let characters = event.charactersIgnoringModifiers
            let keyCode = event.keyCode
            let modifiers = event.modifierFlags
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    PasteWatcher.shared.handleKeyDown(characters: characters, keyCode: keyCode, modifiers: modifiers)
                }
            }
        }
    }

    private static func askForAccessibilityOnce() {
        guard !UserDefaults.standard.bool(forKey: PrefKey.pasteAccessPrompted) else { return }
        UserDefaults.standard.set(true, forKey: PrefKey.pasteAccessPrompted)
        HUD.show("Allow Cadre in Accessibility to close thumbnails after pasting", symbol: "hand.raised.fill", duration: 4)
        Permissions.ensureAccessibility(prompt: true)
    }
}
