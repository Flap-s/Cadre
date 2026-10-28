import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private static var shared: SettingsWindowController?

    static func show(tab: SettingsTab? = nil) {
        if let tab { SettingsNavigation.shared.tab = tab }
        if let shared {
            shared.window?.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let controller = SettingsWindowController()
        shared = controller
        AppPresence.windowOpened()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private init() {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 620, height: 520),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Cadre Settings"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: SettingsView())
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        HotKeyManager.shared.isSuspended = false
        Self.shared = nil
        AppPresence.windowClosed()
    }
}

enum SettingsTab: Hashable {
    case general, screenshots, recording, shortcuts, updates
}

final class SettingsNavigation: ObservableObject {
    static let shared = SettingsNavigation()
    @Published var tab: SettingsTab = .general
}

struct SettingsView: View {
    @ObservedObject private var navigation = SettingsNavigation.shared

    var body: some View {
        TabView(selection: $navigation.tab) {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }.tag(SettingsTab.general)
            ScreenshotSettings().tabItem { Label("Screenshots", systemImage: "camera.viewfinder") }.tag(SettingsTab.screenshots)
            RecordingSettings().tabItem { Label("Recording", systemImage: "record.circle") }.tag(SettingsTab.recording)
            ShortcutSettings().tabItem { Label("Shortcuts", systemImage: "command") }.tag(SettingsTab.shortcuts)
            UpdateSettings().tabItem { Label("Updates", systemImage: "arrow.down.circle") }.tag(SettingsTab.updates)
        }
        .padding(20)
        .frame(width: 620, height: 540)
    }
}

private struct GeneralSettings: View {
    @AppStorage(PrefKey.playSounds) private var playSounds = true
    @AppStorage(PrefKey.saveFolder) private var saveFolder = ""
    @AppStorage(PrefKey.imageFormat) private var imageFormat = ImageFormat.png.rawValue
    @AppStorage(PrefKey.jpegQuality) private var jpegQuality = 0.9
    @AppStorage(PrefKey.downscaleRetina) private var downscaleRetina = false
    @AppStorage(PrefKey.historyRetentionDays) private var retention = 30
    @AppStorage(PrefKey.hideDesktopIconsWhileCapturing) private var hideIcons = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in
                    do {
                        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    } catch {
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            Toggle("Play sounds", isOn: $playSounds)
            Toggle("Hide desktop icons while capturing", isOn: $hideIcons)

            Section("Export") {
                LabeledContent("Save to") {
                    HStack {
                        Text(saveFolder.isEmpty ? "Desktop" : (saveFolder as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("Choose…") { chooseFolder() }
                    }
                }
                Picker("File format", selection: $imageFormat) {
                    ForEach(ImageFormat.allCases) { Text($0.title).tag($0.rawValue) }
                }
                if imageFormat != ImageFormat.png.rawValue {
                    LabeledContent("Quality") { Slider(value: $jpegQuality, in: 0.3...1) }
                }
                Toggle("Save Retina screenshots at 1x", isOn: $downscaleRetina)
            }

            Section("History") {
                Picker("Keep captures for", selection: $retention) {
                    Text("1 day").tag(1)
                    Text("1 week").tag(7)
                    Text("1 month").tag(30)
                    Text("Forever").tag(0)
                }
                Button("Open History") { HistoryWindowController.show() }
            }
        }
        .formStyle(.grouped)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { saveFolder = url.path }
    }
}

private struct ScreenshotSettings: View {
    @AppStorage(PrefKey.afterCaptureShowOverlay) private var showOverlay = true
    @AppStorage(PrefKey.afterCaptureCopy) private var copy = false
    @AppStorage(PrefKey.afterCaptureSave) private var save = true
    @AppStorage(PrefKey.afterCaptureOpenEditor) private var openEditor = false
    @AppStorage(PrefKey.freezeScreen) private var freeze = false
    @AppStorage(PrefKey.showMagnifier) private var magnifier = true
    @AppStorage(PrefKey.showCrosshair) private var crosshair = true
    @AppStorage(PrefKey.captureCursor) private var cursor = false
    @AppStorage(PrefKey.windowShadow) private var shadow = true
    @AppStorage(PrefKey.selfTimerSeconds) private var timer = 5
    @AppStorage(PrefKey.overlayOnRight) private var overlayRight = false
    @AppStorage(PrefKey.overlayAutoCloseSeconds) private var autoClose = 0

    var body: some View {
        Form {
            Section("After capture") {
                Toggle("Show Quick Access Overlay", isOn: $showOverlay)
                Toggle("Copy to clipboard", isOn: $copy)
                Toggle("Save to disk", isOn: $save)
                Toggle("Open annotation editor", isOn: $openEditor)
            }
            Section("Capturing") {
                Toggle("Freeze screen while selecting", isOn: $freeze)
                Toggle("Show magnifier", isOn: $magnifier)
                Toggle("Show crosshair", isOn: $crosshair)
                Toggle("Include mouse cursor", isOn: $cursor)
                Toggle("Capture window shadow", isOn: $shadow)
                Picker("Self-timer", selection: $timer) {
                    Text("3 seconds").tag(3)
                    Text("5 seconds").tag(5)
                    Text("10 seconds").tag(10)
                }
            }
            Section("Quick Access Overlay") {
                Picker("Position", selection: $overlayRight) {
                    Text("Bottom left").tag(false)
                    Text("Bottom right").tag(true)
                }
                Picker("Close automatically", selection: $autoClose) {
                    Text("Never").tag(0)
                    Text("After 5 seconds").tag(5)
                    Text("After 10 seconds").tag(10)
                    Text("After 30 seconds").tag(30)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct RecordingSettings: View {
    @AppStorage(PrefKey.recFPS) private var fps = 30
    @AppStorage(PrefKey.recCodec) private var codec = "h264"
    @AppStorage(PrefKey.recSystemAudio) private var systemAudio = false
    @AppStorage(PrefKey.recMicrophone) private var microphone = false
    @AppStorage(PrefKey.recShowCursor) private var cursor = true
    @AppStorage(PrefKey.recShowClicks) private var clicks = true
    @AppStorage(PrefKey.recKeystrokes) private var keystrokes = false
    @AppStorage(PrefKey.recCamera) private var camera = false
    @AppStorage(PrefKey.recCountdown) private var countdown = true
    @AppStorage(PrefKey.gifFPS) private var gifFPS = 15
    @AppStorage(PrefKey.gifMaxWidth) private var gifWidth = 960

    var body: some View {
        Form {
            Section("Video") {
                Picker("Frame rate", selection: $fps) {
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
                Picker("Codec", selection: $codec) {
                    Text("H.264 (compatible)").tag("h264")
                    Text("HEVC (smaller files)").tag("hevc")
                }
                Toggle("Record computer audio", isOn: $systemAudio)
                Toggle("Record microphone", isOn: $microphone)
                Toggle("Show webcam", isOn: $camera)
            }
            Section("Overlays") {
                Toggle("Show mouse cursor", isOn: $cursor)
                Toggle("Highlight clicks", isOn: $clicks)
                Toggle("Show keystrokes (needs Accessibility)", isOn: $keystrokes)
                Toggle("3-second countdown", isOn: $countdown)
            }
            Section("GIF") {
                Picker("Frame rate", selection: $gifFPS) {
                    Text("10 fps").tag(10)
                    Text("15 fps").tag(15)
                    Text("24 fps").tag(24)
                }
                Picker("Maximum width", selection: $gifWidth) {
                    Text("640 px").tag(640)
                    Text("960 px").tag(960)
                    Text("1280 px").tag(1280)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ShortcutSettings: View {
    @State private var refresh = 0

    var body: some View {
        VStack(alignment: .leading) {
            Form {
                ForEach(CaptureAction.allCases) { action in
                    LabeledContent {
                        HStack {
                            ShortcutRecorder(action: action, onChange: { refresh += 1 })
                                .frame(width: 150, height: 24)
                            if HotKeyManager.shared.failed.contains(action) {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                                    .help("This shortcut is already used by the system or another app.")
                            }
                        }
                    } label: {
                        Label(action.title, systemImage: action.symbol)
                    }
                }
            }
            .formStyle(.grouped)
            .id(refresh)
            HStack {
                Text("Click a field, then press the new shortcut. ⌫ clears it.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Restore Defaults") {
                    HotKeyStore.resetAll()
                    refresh += 1
                }
            }
        }
    }
}

/// Click to record a new global shortcut.
private struct ShortcutRecorder: NSViewRepresentable {
    let action: CaptureAction
    let onChange: () -> Void

    func makeNSView(context: Context) -> RecorderField {
        let field = RecorderField()
        field.action = action
        field.onChange = onChange
        return field
    }

    func updateNSView(_ view: RecorderField, context: Context) {
        view.action = action
        view.needsDisplay = true
    }

    final class RecorderField: NSView {
        var action: CaptureAction = .captureArea
        var onChange: (() -> Void)?
        private var recording = false {
            didSet {
                needsDisplay = true
                MainActor.assumeIsolated { HotKeyManager.shared.isSuspended = recording }
            }
        }

        override var acceptsFirstResponder: Bool { true }

        override func mouseDown(with event: NSEvent) {
            recording = true
            window?.makeFirstResponder(self)
        }

        override func resignFirstResponder() -> Bool {
            recording = false
            return true
        }

        override func keyDown(with event: NSEvent) {
            guard recording else { return super.keyDown(with: event) }
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            switch Int(event.keyCode) {
            case 53:
                recording = false
            case 51, 117:
                MainActor.assumeIsolated { HotKeyStore.set(nil, for: action) }
                recording = false
                onChange?()
            default:
                let isFunctionKey = KeyNames.special[UInt32(event.keyCode)]?.hasPrefix("F") == true
                guard !flags.isEmpty || isFunctionKey else { NSSound.beep(); return }
                MainActor.assumeIsolated {
                    HotKeyStore.set(KeyCombo(keyCode: UInt32(event.keyCode), modifiers: flags), for: action)
                }
                recording = false
                onChange?()
            }
        }

        override func draw(_ dirtyRect: NSRect) {
            let rect = bounds.insetBy(dx: 1, dy: 1)
            let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
            (recording ? NSColor.controlAccentColor.withAlphaComponent(0.15) : NSColor.controlBackgroundColor).setFill()
            path.fill()
            (recording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
            path.stroke()
            let text = recording ? "Type shortcut…" : (HotKeyStore.combo(for: action)?.displayString ?? "None")
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: recording ? NSColor.controlAccentColor : NSColor.labelColor,
            ]
            let str = NSAttributedString(string: text, attributes: attrs)
            let size = str.size()
            str.draw(at: CGPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
        }
    }
}

private struct UpdateSettings: View {
    @ObservedObject private var updater = Updater.shared
    @AppStorage(PrefKey.autoCheckUpdates) private var autoCheck = true

    var body: some View {
        Form {
            Section {
                LabeledContent("Installed version", value: updater.currentVersion)
                Toggle("Check for updates automatically", isOn: $autoCheck)
                    .onChange(of: autoCheck) { _, _ in updater.startAutomaticChecks() }
                if let repoURL = updater.repositoryURL, let repository = updater.repository {
                    LabeledContent("Source") { Link(repository, destination: repoURL) }
                }
            }

            Section {
                HStack(alignment: .firstTextBaseline) {
                    status
                    Spacer()
                    Button("Check Now") { Task { await updater.check(userInitiated: true) } }
                        .disabled(busy || updater.repository == nil)
                }
                if let last = updater.lastChecked {
                    Text("Last checked \(last.formatted(.relative(presentation: .named)))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if let release = updater.availableRelease {
                Section("Cadre \(release.version?.description ?? release.tagName)") {
                    ScrollView {
                        Text(release.body?.isEmpty == false ? release.body! : "No release notes.")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(height: 140)
                    HStack {
                        Link("View on GitHub", destination: release.htmlUrl)
                        Spacer()
                        Button("Download and Install") { Task { await updater.install() } }
                            .buttonStyle(.borderedProminent)
                            .disabled(busy)
                    }
                    Text("Cadre will quit, update itself and reopen. Your settings, history and permissions are kept.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var busy: Bool {
        [.checking, .downloading, .installing].contains(updater.state)
    }

    @ViewBuilder private var status: some View {
        switch updater.state {
        case .idle:
            Text("Not checked yet").foregroundStyle(.secondary)
        case .checking:
            HStack { ProgressView().controlSize(.small); Text("Checking…") }
        case .upToDate:
            Label("Cadre is up to date", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .available(let release):
            Label("Version \(release.version?.description ?? release.tagName) is available", systemImage: "arrow.down.circle.fill")
                .foregroundStyle(Color.accentColor)
        case .downloading:
            HStack { ProgressView().controlSize(.small); Text("Downloading…") }
        case .installing:
            HStack { ProgressView().controlSize(.small); Text("Installing…") }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }
}
