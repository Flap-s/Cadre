import AppKit

/// A dotted numeric version ("1.2.3", "v1.2"), compared component by component.
struct AppVersion: Comparable, CustomStringConvertible {
    let components: [Int]

    init?(_ string: String) {
        var s = string.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        // Ignore pre-release / build suffixes ("1.2.0-beta").
        let core = s.split(whereSeparator: { $0 == "-" || $0 == "+" }).first.map(String.init) ?? s
        let parts = core.split(separator: ".").map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        components = parts.compactMap { $0 }
    }

    var description: String { components.map(String.init).joined(separator: ".") }

    static func < (a: AppVersion, b: AppVersion) -> Bool {
        let n = max(a.components.count, b.components.count)
        for i in 0..<n {
            let x = i < a.components.count ? a.components[i] : 0
            let y = i < b.components.count ? b.components[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    static func == (a: AppVersion, b: AppVersion) -> Bool { !(a < b) && !(b < a) }
}

/// The subset of GitHub's release payload Cadre needs.
struct GitHubRelease: Decodable, Equatable {
    struct Asset: Decodable, Equatable {
        let name: String
        let browserDownloadUrl: URL
        let size: Int
    }

    let tagName: String
    let name: String?
    let body: String?
    let htmlUrl: URL
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]

    var version: AppVersion? { AppVersion(tagName) }

    /// The zipped app: `Cadre.zip`, or any zip whose name starts with "Cadre".
    var appArchive: Asset? {
        assets.first { $0.name == "Cadre.zip" }
            ?? assets.first { $0.name.hasPrefix("Cadre") && $0.name.hasSuffix(".zip") }
    }

    static func decode(_ data: Data) throws -> GitHubRelease {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(GitHubRelease.self, from: data)
    }
}

/// Checks GitHub Releases for a newer Cadre and installs it.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(GitHubRelease)
        case downloading
        case installing
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastChecked: Date? = UserDefaults.standard.object(forKey: PrefKey.lastUpdateCheck) as? Date

    /// "owner/repo", written into Info.plist by the build script from the git remote.
    let repository: String? = (Bundle.main.object(forInfoDictionaryKey: "CadreUpdateRepository") as? String)
        .flatMap { $0.isEmpty ? nil : $0 }
    let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

    private var timer: Timer?
    private let checkInterval: TimeInterval = 6 * 3600

    var repositoryURL: URL? { repository.flatMap { URL(string: "https://github.com/\($0)") } }

    var availableRelease: GitHubRelease? {
        if case .available(let release) = state { return release }
        return nil
    }

    func startAutomaticChecks() {
        timer?.invalidate()
        guard Prefs.autoCheckUpdates, repository != nil else { return }
        Task {
            try? await Task.sleep(for: .seconds(8))
            await check(userInitiated: false)
        }
        timer = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { _ in
            Task { @MainActor in await Updater.shared.check(userInitiated: false) }
        }
    }

    func check(userInitiated: Bool) async {
        guard let repository else {
            state = .failed("This build has no update repository configured.")
            return
        }
        if state == .checking || state == .downloading || state == .installing { return }
        state = .checking
        do {
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("Cadre/\(currentVersion)", forHTTPHeaderField: "User-Agent")
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            lastChecked = Date()
            UserDefaults.standard.set(lastChecked, forKey: PrefKey.lastUpdateCheck)

            if status == 404 { state = .upToDate; return } // no release published yet
            guard status == 200 else {
                throw UpdateError.message(status == 403 ? "GitHub rate limit reached, try again later." : "GitHub answered HTTP \(status).")
            }
            let release = try GitHubRelease.decode(data)
            guard let latest = release.version, let current = AppVersion(currentVersion),
                  !release.draft, !release.prerelease, latest > current, release.appArchive != nil else {
                state = .upToDate
                return
            }
            state = .available(release)
            if !userInitiated && UserDefaults.standard.string(forKey: PrefKey.announcedUpdate) != release.tagName {
                UserDefaults.standard.set(release.tagName, forKey: PrefKey.announcedUpdate)
                HUD.show("Cadre \(latest) is available — see Settings › Updates", symbol: "arrow.down.circle.fill", duration: 4)
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func install() async {
        guard case .available(let release) = state, let asset = release.appArchive,
              let expected = release.version else { return }
        if ScreenRecorder.shared.isActive {
            state = .failed("Finish the current recording before updating.")
            return
        }
        let currentApp = Bundle.main.bundleURL
        guard FileManager.default.isWritableFile(atPath: currentApp.deletingLastPathComponent().path) else {
            state = .failed("Cadre can't replace itself in \(currentApp.deletingLastPathComponent().path). Move Cadre to a folder you can write to, such as Applications.")
            return
        }

        state = .downloading
        do {
            // ".noindex" keeps Spotlight from listing the staged copy.
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("CadreUpdate-\(UUID().uuidString).noindex")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let (downloaded, response) = try await URLSession.shared.download(from: asset.browserDownloadUrl)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.message("The download failed.") }
            let archive = work.appendingPathComponent("Cadre.zip")
            try FileManager.default.moveItem(at: downloaded, to: archive)

            state = .installing
            let bundleID = Bundle.main.bundleIdentifier ?? "app.cadre.Cadre"
            let newApp = try await Task.detached {
                let app = try UpdateInstaller.extractApp(from: archive, into: work.appendingPathComponent("extracted"))
                try UpdateInstaller.validate(app: app, bundleIdentifier: bundleID, version: expected)
                return app
            }.value
            try UpdateInstaller.replaceAfterExit(pid: ProcessInfo.processInfo.processIdentifier,
                                                 current: currentApp, with: newApp, relaunch: true, cleanUp: work)
            NSApp.terminate(nil)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

enum UpdateError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let m): return m }
    }
}

/// File-level steps of an update, kept free of UI so they can be tested.
enum UpdateInstaller {
    @discardableResult
    static func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError.message("\((tool as NSString).lastPathComponent) failed: \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return output
    }

    /// Unzips the archive (preserving the code signature) and returns the app inside it.
    static func extractApp(from archive: URL, into directory: URL) throws -> URL {
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try run("/usr/bin/ditto", ["-x", "-k", archive.path, directory.path])
        let apps = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "app" }
        guard apps.count == 1 else { throw UpdateError.message("The update archive doesn't contain exactly one app.") }
        return apps[0]
    }

    /// The downloaded app must be Cadre, at the advertised version, with an intact signature.
    static func validate(app: URL, bundleIdentifier: String, version: AppVersion) throws {
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any] else {
            throw UpdateError.message("The downloaded app has no Info.plist.")
        }
        guard info["CFBundleIdentifier"] as? String == bundleIdentifier else {
            throw UpdateError.message("The downloaded app isn't Cadre.")
        }
        guard let shipped = (info["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init), shipped == version else {
            throw UpdateError.message("The downloaded app's version doesn't match the release.")
        }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "-R=identifier \"\(bundleIdentifier)\"", app.path])
    }

    /// Waits for `pid` to exit, swaps `current` for `new` (restoring the old app on failure),
    /// deletes `cleanUp`, then optionally relaunches. Runs detached so it outlives the app.
    static func replaceAfterExit(pid: Int32, current: URL, with new: URL, relaunch: Bool, cleanUp: URL? = nil) throws {
        let script = """
        pid="$1"; current="$2"; new="$3"; relaunch="$4"; cleanup="$5"
        while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
        backup="$(mktemp -d)/previous.app"
        if mv "$current" "$backup"; then
          if mv "$new" "$current"; then
            rm -rf "$backup"
          else
            mv "$backup" "$current"
          fi
        fi
        xattr -dr com.apple.quarantine "$current" 2>/dev/null
        [ -n "$cleanup" ] && rm -rf "$cleanup"
        [ "$relaunch" = 1 ] && open "$current"
        exit 0
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "cadre-update", String(pid), current.path, new.path, relaunch ? "1" : "0",
                             cleanUp?.path ?? ""]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }
}
