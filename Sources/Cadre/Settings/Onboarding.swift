import AppKit
import AVFoundation
import SwiftUI

/// First-launch window: moves Cadre into Applications if needed, and asks for each permission
/// with a live status.
@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private static var shared: OnboardingWindowController?

    static func show() {
        if let shared {
            shared.window?.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let controller = OnboardingWindowController()
        shared = controller
        AppPresence.windowOpened()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private init() {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 560, height: 640),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentViewController = NSHostingController(rootView: OnboardingView { [weak window] in window?.close() })
        window.setContentSize(CGSize(width: 560, height: 640))
        window.center()
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        Self.shared = nil
        AppPresence.windowClosed()
    }
}

/// The permissions Cadre uses, with how to check and request each one.
enum AppPermission: CaseIterable, Identifiable {
    case screenRecording, accessibility, microphone, camera

    var id: Self { self }

    var title: String {
        switch self {
        case .screenRecording: return "Screen Recording"
        case .accessibility: return "Accessibility"
        case .microphone: return "Microphone"
        case .camera: return "Camera"
        }
    }

    var detail: String {
        switch self {
        case .screenRecording: return "Required to take screenshots and record your screen."
        case .accessibility: return "Closes thumbnails when you paste with ⌘V, shows keystrokes in recordings and auto-scrolls scrolling captures."
        case .microphone: return "Only if you record your voice with your screen."
        case .camera: return "Only for the webcam bubble in recordings."
        }
    }

    var badge: String {
        switch self {
        case .screenRecording: return "Required"
        case .accessibility: return "Recommended"
        case .microphone, .camera: return "Optional"
        }
    }

    var symbol: String {
        switch self {
        case .screenRecording: return "rectangle.dashed.badge.record"
        case .accessibility: return "accessibility"
        case .microphone: return "mic.fill"
        case .camera: return "video.fill"
        }
    }

    var tint: Color {
        switch self {
        case .screenRecording: return .red
        case .accessibility: return .blue
        case .microphone: return .orange
        case .camera: return .green
        }
    }

    var isGranted: Bool {
        switch self {
        case .screenRecording: return Permissions.hasScreenRecording
        case .accessibility: return Permissions.ensureAccessibility(prompt: false)
        case .microphone: return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .camera: return AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        }
    }

    @MainActor func request() {
        switch self {
        case .screenRecording:
            Permissions.requestScreenRecording()
        case .accessibility:
            if !Permissions.ensureAccessibility(prompt: true) { Permissions.openPrivacyPane("Privacy_Accessibility") }
        case .microphone, .camera:
            let type: AVMediaType = self == .microphone ? .audio : .video
            if AVCaptureDevice.authorizationStatus(for: type) == .notDetermined {
                AVCaptureDevice.requestAccess(for: type) { _ in }
            } else {
                Permissions.openPrivacyPane(self == .microphone ? "Privacy_Microphone" : "Privacy_Camera")
            }
        }
    }
}

struct OnboardingView: View {
    let close: () -> Void
    @State private var granted: [AppPermission: Bool] = [:]
    @State private var inApplications = AppMover.isInApplications
    @State private var moveError: String?
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.top, 34)
                .padding(.bottom, 22)

            if !inApplications && AppMover.canOfferMove {
                moveBanner
                    .padding(.horizontal, 28)
                    .padding(.bottom, 14)
            }

            VStack(spacing: 10) {
                ForEach(AppPermission.allCases) { permission in
                    PermissionRow(permission: permission, granted: granted[permission] ?? false)
                }
            }
            .padding(.horizontal, 28)

            Spacer(minLength: 16)

            HStack {
                Text("You can change these anytime in System Settings › Privacy & Security.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(allRequiredGranted ? "Start Using Cadre" : "Later") { close() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 24)
        }
        .frame(width: 560, height: 640)
        .background(
            LinearGradient(colors: [Color(nsColor: .windowBackgroundColor), Color.accentColor.opacity(0.08)],
                           startPoint: .top, endPoint: .bottom)
        )
        .onAppear(perform: refresh)
        .onReceive(poll) { _ in refresh() }
    }

    private var header: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 84, height: 84)
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
            Text("Welcome to Cadre")
                .font(.system(size: 26, weight: .bold, design: .rounded))
            Text("Cadre lives in your menu bar. Grant these permissions so every feature works.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 60)
        }
    }

    private var moveBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.app.fill")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Move Cadre to Applications").font(.headline)
                Text(moveError ?? "Updates and launch at login work best from there.")
                    .font(.caption)
                    .foregroundStyle(moveError == nil ? Color.secondary : Color.orange)
            }
            Spacer()
            Button("Move") {
                do {
                    try AppMover.moveToApplicationsAndRelaunch()
                } catch {
                    moveError = error.localizedDescription
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor.opacity(0.3)))
    }

    private var allRequiredGranted: Bool { granted[.screenRecording] == true }

    private func refresh() {
        for permission in AppPermission.allCases { granted[permission] = permission.isGranted }
        inApplications = AppMover.isInApplications
    }
}

private struct PermissionRow: View {
    let permission: AppPermission
    let granted: Bool

    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 9)
                .fill(permission.tint.gradient)
                .frame(width: 38, height: 38)
                .overlay(Image(systemName: permission.symbol).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(permission.title).font(.headline)
                    Text(permission.badge)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(permission == .screenRecording ? Color.red.opacity(0.15) : Color.secondary.opacity(0.15)))
                        .foregroundStyle(permission == .screenRecording ? Color.red : Color.secondary)
                }
                Text(permission.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.green)
            } else {
                Button("Allow") { permission.request() }
                    .controlSize(.regular)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.06)))
    }
}

/// Copies Cadre into /Applications (e.g. when it was opened straight from the disk image) and
/// relaunches the copy.
enum AppMover {
    static let destination = URL(fileURLWithPath: "/Applications/Cadre.app")

    static var isInApplications: Bool {
        let path = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        return path.hasPrefix("/Applications/")
            || path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path + "/")
    }

    /// Not for development builds run from the source folder.
    static var canOfferMove: Bool { !Bundle.main.bundlePath.contains(".noindex/") }

    @MainActor static func moveToApplicationsAndRelaunch() throws {
        let source = Bundle.main.bundleURL
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.trashItem(at: destination, resultingItemURL: nil)
        }
        try UpdateInstaller.run("/usr/bin/ditto", [source.path, destination.path])
        // The user already chose to open this copy; don't make Gatekeeper ask again for the moved one.
        try? UpdateInstaller.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", destination.path])

        let script = """
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        open "$2"
        """
        let relauncher = Process()
        relauncher.executableURL = URL(fileURLWithPath: "/bin/sh")
        relauncher.arguments = ["-c", script, "cadre-move", String(ProcessInfo.processInfo.processIdentifier), destination.path]
        try relauncher.run()
        NSApp.terminate(nil)
    }
}
