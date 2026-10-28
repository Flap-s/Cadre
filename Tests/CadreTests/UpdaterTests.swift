import Foundation
import XCTest
@testable import Cadre

final class UpdaterTests: XCTestCase {
    func testVersionComparison() {
        XCTAssertLessThan(AppVersion("1.0.0")!, AppVersion("1.0.1")!)
        XCTAssertLessThan(AppVersion("1.9")!, AppVersion("1.10")!)
        XCTAssertLessThan(AppVersion("v1.2.3")!, AppVersion("2.0")!)
        XCTAssertEqual(AppVersion("1.2")!, AppVersion("1.2.0")!)
        XCTAssertEqual(AppVersion("v1.2.0-beta")!, AppVersion("1.2.0")!)
        XCTAssertNil(AppVersion("latest"))
    }

    func testDecodesGitHubRelease() throws {
        let json = """
        {"tag_name": "v1.1.0", "name": "Cadre 1.1.0", "body": "Notes", "draft": false, "prerelease": false,
         "html_url": "https://github.com/someone/Cadre-macOS/releases/tag/v1.1.0",
         "assets": [
           {"name": "Cadre.zip.sha256", "browser_download_url": "https://example.com/a", "size": 64},
           {"name": "Cadre.zip", "browser_download_url": "https://example.com/Cadre.zip", "size": 1500000}
         ]}
        """
        let release = try GitHubRelease.decode(Data(json.utf8))
        XCTAssertEqual(release.version, AppVersion("1.1.0"))
        XCTAssertEqual(release.appArchive?.browserDownloadUrl.absoluteString, "https://example.com/Cadre.zip")
    }

    func testReleaseFromLatestPageRedirect() {
        let page = URL(string: "https://github.com/Flap-s/Cadre/releases/tag/v1.0.2")!
        let release = GitHubRelease.fromLatestPage(page, repository: "Flap-s/Cadre")
        XCTAssertEqual(release?.version, AppVersion("1.0.2"))
        XCTAssertEqual(release?.appArchive?.browserDownloadUrl.absoluteString,
                       "https://github.com/Flap-s/Cadre/releases/download/v1.0.2/Cadre.zip")
        XCTAssertNil(GitHubRelease.fromLatestPage(URL(string: "https://github.com/Flap-s/Cadre/releases")!, repository: "Flap-s/Cadre"))
    }

        // MARK: Installer

    private var work: URL!

    override func setUpWithError() throws {
        work = FileManager.default.temporaryDirectory.appendingPathComponent("CadreUpdaterTests-\(UUID().uuidString).noindex")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: work)
    }

    /// A minimal signed app bundle, signed like build-app.sh does.
    private func makeApp(named name: String, bundleID: String, version: String, marker: String) throws -> URL {
        let app = work.appendingPathComponent("\(name).app")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: macOS.appendingPathComponent("Cadre"))
        let info: NSDictionary = [
            "CFBundleIdentifier": bundleID, "CFBundleExecutable": "Cadre", "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": version, "CFBundleVersion": version, "CadreTestMarker": marker,
        ]
        info.write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true)
        try UpdateInstaller.run("/usr/bin/codesign", ["--force", "--sign", "-", "--requirements",
                                                      "=designated => identifier \"\(bundleID)\"", app.path])
        return app
    }

    private func zip(_ app: URL) throws -> URL {
        let archive = work.appendingPathComponent("Cadre.zip")
        try? FileManager.default.removeItem(at: archive)
        try UpdateInstaller.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, archive.path])
        return archive
    }

    func testExtractsAndValidatesGenuineUpdate() throws {
        let archive = try zip(try makeApp(named: "Cadre", bundleID: "app.cadre.Cadre", version: "1.1.0", marker: "new"))
        let app = try UpdateInstaller.extractApp(from: archive, into: work.appendingPathComponent("out"))
        XCTAssertNoThrow(try UpdateInstaller.validate(app: app, bundleIdentifier: "app.cadre.Cadre", version: AppVersion("1.1.0")!))
    }

    func testRejectsWrongVersionOrIdentity() throws {
        let archive = try zip(try makeApp(named: "Cadre", bundleID: "com.example.other", version: "1.1.0", marker: "x"))
        let app = try UpdateInstaller.extractApp(from: archive, into: work.appendingPathComponent("out"))
        XCTAssertThrowsError(try UpdateInstaller.validate(app: app, bundleIdentifier: "app.cadre.Cadre", version: AppVersion("1.1.0")!))
        XCTAssertThrowsError(try UpdateInstaller.validate(app: app, bundleIdentifier: "com.example.other", version: AppVersion("2.0.0")!))
    }

    func testRejectsTamperedApp() throws {
        let original = try makeApp(named: "Cadre", bundleID: "app.cadre.Cadre", version: "1.1.0", marker: "new")
        // Modify the bundle after signing: the signature no longer matches.
        try Data("tampered".utf8).write(to: original.appendingPathComponent("Contents/Resources-extra"))
        let plist = original.appendingPathComponent("Contents/Info.plist")
        let info = NSMutableDictionary(contentsOf: plist)!
        info["CadreTestMarker"] = "evil"
        info.write(to: plist, atomically: true)
        XCTAssertThrowsError(try UpdateInstaller.validate(app: original, bundleIdentifier: "app.cadre.Cadre", version: AppVersion("1.1.0")!))
    }

    func testReplacesAppOnceProcessHasExited() throws {
        let installed = try makeApp(named: "Installed", bundleID: "app.cadre.Cadre", version: "1.0.0", marker: "old")
        let staged = work.appendingPathComponent("staged")
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        let update = try makeApp(named: "Cadre", bundleID: "app.cadre.Cadre", version: "1.1.0", marker: "new")
        let newApp = staged.appendingPathComponent("Cadre.app")
        try FileManager.default.moveItem(at: update, to: newApp)

        // A process that has already exited stands in for the running app.
        let finished = Process()
        finished.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try finished.run()
        finished.waitUntilExit()

        try UpdateInstaller.replaceAfterExit(pid: finished.processIdentifier, current: installed, with: newApp, relaunch: false,
                                             cleanUp: staged)
        let plist = installed.appendingPathComponent("Contents/Info.plist")
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, (NSDictionary(contentsOf: plist)?["CadreTestMarker"] as? String) != "new" {
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertEqual(NSDictionary(contentsOf: plist)?["CadreTestMarker"] as? String, "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: newApp.path))
        let cleaned = Date().addingTimeInterval(5)
        while Date() < cleaned, FileManager.default.fileExists(atPath: staged.path) { Thread.sleep(forTimeInterval: 0.1) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path), "staging folder should be removed")
        XCTAssertNoThrow(try UpdateInstaller.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", installed.path]))
    }
}
