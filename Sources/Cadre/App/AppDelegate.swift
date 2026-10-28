import AppKit
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.registerDefaults()
        NSApp.mainMenu = MainMenu.make()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu.delegate = self
        updateStatusItem()

        HotKeyManager.shared.install()
        HotKeyManager.shared.registerAll()
        HistoryStore.shared.prune()
        Updater.shared.startAutomaticChecks()

        NotificationCenter.default.addObserver(forName: .recorderStateChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateStatusItem() }
        }

        if !UserDefaults.standard.bool(forKey: PrefKey.onboarded) {
            UserDefaults.standard.set(true, forKey: PrefKey.onboarded)
            Onboarding.show()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindowController.show()
        return false
    }

    // MARK: Opening files and URLs

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.isFileURL {
                openFile(url)
            } else {
                URLSchemeHandler.handle(url)
            }
        }
    }

    private func openFile(_ url: URL) {
        let type = UTType(filenameExtension: url.pathExtension)
        if type?.conforms(to: .movie) == true || type?.conforms(to: .video) == true {
            VideoEditorWindowController.open(CaptureItem(videoAt: url, temporary: false))
        } else if let item = CaptureItem(imageAt: url) {
            AnnotationEditorController.open(item)
        }
    }

    // MARK: Status item

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        let recorder = ScreenRecorder.shared
        if recorder.isActive {
            statusItem.menu = nil
            button.image = NSImage(systemSymbolName: recorder.isPaused ? "pause.circle.fill" : "stop.circle.fill",
                                   accessibilityDescription: "Stop recording")
            button.imagePosition = .imageLeading
            button.title = " " + recorder.elapsedString
            button.contentTintColor = .systemRed
            button.target = self
            button.action = #selector(stopRecording)
        } else {
            button.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Cadre")
            button.title = ""
            button.contentTintColor = nil
            button.action = nil
            statusItem.menu = menu
        }
    }

    @objc private func stopRecording() {
        Task { await ScreenRecorder.shared.stop() }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if let release = Updater.shared.availableRelease {
            let update = menu.addItem(withTitle: "Update to Cadre \(release.version?.description ?? release.tagName)…",
                                      action: #selector(openUpdates), keyEquivalent: "")
            update.target = self
            update.image = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: nil)
            menu.addItem(.separator())
        }
        let groups: [[CaptureAction]] = [
            [.allInOne],
            [.captureArea, .capturePreviousArea, .captureFullscreen, .captureWindow, .selfTimer,
             .scrollingCapture, .captureText, .pinArea],
            [.recordScreen, .recordGIF],
        ]
        for group in groups {
            group.forEach { menu.addItem(item(for: $0)) }
            menu.addItem(.separator())
        }

        menu.addItem(withTitle: "Open Image to Annotate…", action: #selector(openImage), keyEquivalent: "").target = self
        menu.addItem(item(for: .annotateClipboard))
        menu.addItem(withTitle: "Pin Image…", action: #selector(pinImage), keyEquivalent: "").target = self
        menu.addItem(.separator())

        let icons = item(for: .toggleDesktopIcons)
        icons.title = DesktopIconsHider.shared.isHidden ? "Show Desktop Icons" : "Hide Desktop Icons"
        menu.addItem(icons)
        if PinManager.shared.hasLockedPins {
            menu.addItem(withTitle: "Unlock Pinned Screenshots", action: #selector(unlockPins), keyEquivalent: "").target = self
        }
        menu.addItem(item(for: .closeAllOverlays))
        menu.addItem(item(for: .openHistory))
        menu.addItem(.separator())
        menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Quit Cadre", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    private func item(for action: CaptureAction) -> NSMenuItem {
        let item = NSMenuItem(title: action.title, action: #selector(runAction(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = action.rawValue
        item.image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil)
        if let combo = HotKeyStore.combo(for: action), !combo.keyEquivalent.isEmpty {
            item.keyEquivalent = combo.keyEquivalent
            item.keyEquivalentModifierMask = combo.modifierFlags
        }
        return item
    }

    @objc private func runAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let action = CaptureAction(rawValue: raw) else { return }
        // Let the menu finish closing so it never appears in a capture.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { action.run() }
    }

    @objc private func openImage() {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        panel.urls.compactMap { CaptureItem(imageAt: $0) }.forEach { AnnotationEditorController.open($0) }
    }

    @objc private func pinImage() {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url, let item = CaptureItem(imageAt: url),
              let image = item.image else { return }
        PinManager.shared.pin(image: image, scale: item.scale)
    }

    @objc private func unlockPins() { PinManager.shared.unlockAll() }
    @objc private func openSettings() { SettingsWindowController.show() }
    @objc private func openUpdates() { SettingsWindowController.show(tab: .updates) }

    @objc private func checkForUpdates() {
        SettingsWindowController.show(tab: .updates)
        Task { await Updater.shared.check(userInitiated: true) }
    }
}

/// A minimal main menu so text fields and editor windows get the standard shortcuts (⌘C, ⌘V, ⌘Z, ⌘W…).
enum MainMenu {
    static func make() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings…", action: #selector(AppDelegate.openSettingsFromMenu), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Cadre", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu: appMenu, title: "Cadre")

        let file = NSMenu(title: "File")
        file.addItem(withTitle: "Save", action: #selector(AnnotationEditorController.saveDocument(_:)), keyEquivalent: "s")
        file.addItem(withTitle: "Save As…", action: #selector(AnnotationEditorController.saveDocumentAs(_:)), keyEquivalent: "S")
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(submenu: file, title: "File")

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu: edit, title: "Edit")

        let view = NSMenu(title: "View")
        view.addItem(withTitle: "Zoom In", action: #selector(AnnotationEditorController.zoomIn(_:)), keyEquivalent: "+")
        // ⌘= also zooms in (no Shift needed on QWERTY layouts).
        let zoomInAlt = view.addItem(withTitle: "Zoom In", action: #selector(AnnotationEditorController.zoomIn(_:)), keyEquivalent: "=")
        zoomInAlt.isHidden = true
        zoomInAlt.allowsKeyEquivalentWhenHidden = true
        view.addItem(withTitle: "Zoom Out", action: #selector(AnnotationEditorController.zoomOut(_:)), keyEquivalent: "-")
        view.addItem(withTitle: "Zoom to Fit", action: #selector(AnnotationEditorController.zoomToFit(_:)), keyEquivalent: "0")
        view.addItem(withTitle: "Actual Size", action: #selector(AnnotationEditorController.zoomToActualSize(_:)), keyEquivalent: "1")
        main.addItem(submenu: view, title: "View")

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        main.addItem(submenu: window, title: "Window")
        NSApp.windowsMenu = window
        return main
    }
}

extension NSMenu {
    func addItem(submenu: NSMenu, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}

extension AppDelegate {
    @objc func openSettingsFromMenu() { SettingsWindowController.show() }
}

/// Accessory apps don't appear in the Dock or ⌘-Tab. While a regular window (editor, settings,
/// history) is open we switch to a regular app so the user can find it again.
@MainActor
enum AppPresence {
    private static var openWindows = 0

    static func windowOpened() {
        openWindows += 1
        if openWindows == 1 { NSApp.setActivationPolicy(.regular) }
        NSApp.activate()
    }

    static func windowClosed() {
        openWindows = max(0, openWindows - 1)
        if openWindows == 0 { NSApp.setActivationPolicy(.accessory) }
    }
}

@MainActor
enum URLSchemeHandler {
    /// `cadre://capture-area`, `cadre://record-screen`, `cadre://open-annotate?filepath=/x.png`,
    /// `cadre://pin?filepath=/x.png`…
    static func handle(_ url: URL) {
        guard url.scheme == "cadre", let host = url.host else { return }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let filePath = query.first { $0.name == "filepath" }?.value

        switch host {
        case "open-annotate":
            if let filePath, let item = CaptureItem(imageAt: URL(fileURLWithPath: filePath)) {
                AnnotationEditorController.open(item)
            }
        case "pin":
            if let filePath, let item = CaptureItem(imageAt: URL(fileURLWithPath: filePath)), let image = item.image {
                PinManager.shared.pin(image: image, scale: item.scale)
            }
        case "open-settings":
            SettingsWindowController.show()
        case "check-for-updates":
            SettingsWindowController.show(tab: .updates)
            Task { await Updater.shared.check(userInitiated: true) }
        default:
            CaptureAction.allCases.first { $0.urlName == host }?.run()
        }
    }
}

@MainActor
enum Onboarding {
    static func show() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Welcome to Cadre"
        alert.informativeText = """
        Cadre lives in your menu bar. Default shortcuts:

        ⌥⇧3  Capture fullscreen
        ⌥⇧4  Capture area (Space toggles window mode)
        ⌥⇧5  All-In-One
        ⌥⇧R  Record screen    ⌥⇧G  Record GIF
        ⌥⇧O  Capture text (OCR)

        Cadre needs Screen Recording permission. macOS will ask for it the first time you capture.
        """
        alert.addButton(withTitle: "Grant Screen Recording")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            Permissions.requestScreenRecording()
        }
    }
}
