import Testing
import Foundation
import Mockable
@testable import Baguette

/// Orchestration coverage for `SimctlApps` — argv assembly + the
/// `Subprocess` exit handshake. The irreducible `xcrun` spawn lives in
/// `HostSubprocess` (integration-only), so every branch is driven
/// through `MockSubprocess`.
@Suite("SimctlApps")
struct SimctlAppsTests {

    final class Captures: @unchecked Sendable {
        var executable: URL?
        var arguments: [String]?
        var ran = false
    }

    private func makeApps(exitCode: Int32 = 0) -> (SimctlApps, Captures) {
        let sub = MockSubprocess()
        let captures = Captures()
        given(sub).run(
            executable: .any, arguments: .any, onBytes: .any, onExit: .any
        ).willProduce { exe, args, _, onExit in
            captures.ran = true
            captures.executable = exe
            captures.arguments = args
            onExit(exitCode)
        }
        given(sub).terminate().willReturn()
        return (SimctlApps(udid: "U", subprocess: sub), captures)
    }

    @Test func `install spawns xcrun simctl install with the app path`() async throws {
        let (apps, captures) = makeApps()
        try await apps.install(AppBundle(path: URL(fileURLWithPath: "/tmp/MyApp.ipa")))

        #expect(captures.executable == URL(fileURLWithPath: "/usr/bin/xcrun"))
        #expect(captures.arguments == ["simctl", "install", "U", "/tmp/MyApp.ipa"])
    }

    @Test func `a non-zero simctl exit propagates as an install failure`() async {
        let (apps, _) = makeApps(exitCode: 3)
        var caught: AppsError?
        do {
            try await apps.install(AppBundle(path: URL(fileURLWithPath: "/tmp/MyApp.ipa")))
        } catch {
            caught = error as? AppsError
        }
        #expect(caught == .installFailed(status: 3))
    }

    // MARK: archives — extract → locate → install

    /// Per-call capture for the two-subprocess archive flow: the ditto
    /// stub plays the extraction's side effect (materialising entries
    /// in the destination dir), the xcrun stub records the install argv.
    final class ArchiveCaptures: @unchecked Sendable {
        var extractionDir: String?
        var installArguments: [String]?
    }

    private func makeArchiveApps(
        dittoExit: Int32 = 0,
        installExit: Int32 = 0,
        extractedEntries: [String] = ["MyApp.app"],
        payloadBytes: Int = 0,
        maxExtractedBytes: Int64 = 4 << 30
    ) -> (SimctlApps, ArchiveCaptures) {
        let sub = MockSubprocess()
        let captures = ArchiveCaptures()
        given(sub).run(
            executable: .any, arguments: .any, onBytes: .any, onExit: .any
        ).willProduce { exe, args, _, onExit in
            if exe == URL(fileURLWithPath: "/usr/bin/ditto") {
                let dest = args[args.count - 1]
                captures.extractionDir = dest
                for entry in extractedEntries {
                    try? FileManager.default.createDirectory(
                        atPath: dest + "/" + entry, withIntermediateDirectories: true
                    )
                    if payloadBytes > 0 {
                        FileManager.default.createFile(
                            atPath: dest + "/" + entry + "/payload",
                            contents: Data(count: payloadBytes)
                        )
                    }
                }
                onExit(dittoExit)
            } else {
                captures.installArguments = args
                onExit(installExit)
            }
        }
        given(sub).terminate().willReturn()
        return (
            SimctlApps(udid: "U", subprocess: sub, maxExtractedBytes: maxExtractedBytes),
            captures
        )
    }

    @Test func `an archive is extracted with ditto and the inner app installed`() async throws {
        let (apps, captures) = makeArchiveApps()
        try await apps.install(archive: AppArchive(path: URL(fileURLWithPath: "/tmp/up/MyApp.app.zip")))

        let dir = try #require(captures.extractionDir)
        let argv = try #require(captures.installArguments)
        #expect(argv == ["simctl", "install", "U", dir + "/MyApp.app"])
    }

    @Test func `the extraction directory is cleaned up after the install`() async throws {
        let (apps, captures) = makeArchiveApps()
        try await apps.install(archive: AppArchive(path: URL(fileURLWithPath: "/tmp/up/MyApp.app.zip")))

        let dir = try #require(captures.extractionDir)
        #expect(!FileManager.default.fileExists(atPath: dir))
    }

    @Test func `a non-zero ditto exit propagates as an extract failure`() async {
        let (apps, _) = makeArchiveApps(dittoExit: 2)
        var caught: AppsError?
        do {
            try await apps.install(archive: AppArchive(path: URL(fileURLWithPath: "/tmp/up/broken.zip")))
        } catch {
            caught = error as? AppsError
        }
        #expect(caught == .extractFailed(status: 2))
    }

    @Test func `an archive with no app inside is refused`() async {
        let (apps, captures) = makeArchiveApps(extractedEntries: ["readme.txt"])
        var caught: AppsError?
        do {
            try await apps.install(archive: AppArchive(path: URL(fileURLWithPath: "/tmp/up/docs.zip")))
        } catch {
            caught = error as? AppsError
        }
        #expect(caught == .noAppInArchive)
        #expect(captures.installArguments == nil)
    }

    @Test func `an archive declaring more than the cap is refused before extraction`() async throws {
        let (apps, captures) = makeArchiveApps(maxExtractedBytes: 16)
        let zipURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bomb-\(UUID().uuidString).app.zip")
        try ZipFixture.archive(declaring: [("MyApp.app/MyApp", 64)]).write(to: zipURL)
        defer { try? FileManager.default.removeItem(at: zipURL) }

        var caught: AppsError?
        do {
            try await apps.install(archive: AppArchive(path: zipURL))
        } catch {
            caught = error as? AppsError
        }
        #expect(caught == .archiveTooLarge(bytes: 64, limit: 16))
        #expect(captures.extractionDir == nil)   // ditto never spawned
        #expect(captures.installArguments == nil)
    }

    @Test func `an archive declaring less than the cap proceeds to extraction`() async throws {
        let (apps, captures) = makeArchiveApps(maxExtractedBytes: 1024)
        let zipURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ok-\(UUID().uuidString).app.zip")
        try ZipFixture.archive(declaring: [("MyApp.app/MyApp", 64)]).write(to: zipURL)
        defer { try? FileManager.default.removeItem(at: zipURL) }

        try await apps.install(archive: AppArchive(path: zipURL))
        #expect(captures.extractionDir != nil)
        #expect(captures.installArguments != nil)
    }

    @Test func `an archive that inflates past the extraction cap is refused before install`() async {
        let (apps, captures) = makeArchiveApps(payloadBytes: 64, maxExtractedBytes: 16)
        var caught: AppsError?
        do {
            try await apps.install(archive: AppArchive(path: URL(fileURLWithPath: "/tmp/up/bomb.zip")))
        } catch {
            caught = error as? AppsError
        }
        #expect(caught == .archiveTooLarge(bytes: 64, limit: 16))
        #expect(captures.installArguments == nil)
        if let dir = captures.extractionDir {
            #expect(!FileManager.default.fileExists(atPath: dir))
        }
    }

    @Test func `an archive within the extraction cap still installs`() async throws {
        let (apps, captures) = makeArchiveApps(payloadBytes: 8, maxExtractedBytes: 16)
        try await apps.install(archive: AppArchive(path: URL(fileURLWithPath: "/tmp/up/MyApp.app.zip")))
        #expect(captures.installArguments != nil)
    }

    @Test func `a simctl failure after extraction propagates as an install failure`() async {
        let (apps, _) = makeArchiveApps(installExit: 5)
        var caught: AppsError?
        do {
            try await apps.install(archive: AppArchive(path: URL(fileURLWithPath: "/tmp/up/MyApp.app.zip")))
        } catch {
            caught = error as? AppsError
        }
        #expect(caught == .installFailed(status: 5))
    }

    // MARK: deep links — openurl + the scheme inventory behind completion

    /// Stub that plays a child which writes `output` to stdout and then
    /// exits — the shape of `simctl listapps`, which answers on stdout
    /// rather than through its exit code alone.
    private func makeListingApps(
        output: String, exitCode: Int32 = 0
    ) -> (SimctlApps, Captures) {
        let sub = MockSubprocess()
        let captures = Captures()
        given(sub).run(
            executable: .any, arguments: .any, onBytes: .any, onExit: .any
        ).willProduce { exe, args, onBytes, onExit in
            captures.ran = true
            captures.executable = exe
            captures.arguments = args
            onBytes(Data(output.utf8))
            onExit(exitCode)
        }
        given(sub).terminate().willReturn()
        return (SimctlApps(udid: "U", subprocess: sub), captures)
    }

    @Test func `opening a deep link spawns xcrun simctl openurl`() async throws {
        let (apps, captures) = makeApps()
        try await apps.open(DeepLink.from("myapp://profile/42")!)

        #expect(captures.executable == URL(fileURLWithPath: "/usr/bin/xcrun"))
        #expect(captures.arguments == ["simctl", "openurl", "U", "myapp://profile/42"])
    }

    @Test func `a non-zero simctl exit propagates as an open failure`() async {
        let (apps, _) = makeApps(exitCode: 4)
        var caught: AppsError?
        do {
            try await apps.open(DeepLink.from("myapp://profile")!)
        } catch {
            caught = error as? AppsError
        }
        #expect(caught == .openFailed(status: 4))
    }

    @Test func `the installed inventory spawns xcrun simctl listapps`() async throws {
        let (apps, captures) = makeListingApps(output: "{ }")
        _ = try await apps.installed()

        #expect(captures.arguments == ["simctl", "listapps", "U"])
    }

    /// Materialise a throwaway `.app` carrying an `Info.plist` — the
    /// second half of the inventory read. `listapps` reports the path;
    /// the schemes come from the bundle it points at.
    private func makeBundle(schemes: [String]) throws -> (URL, () -> Void) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("baguette-apps-\(UUID().uuidString)")
        let bundle = dir.appendingPathComponent("MyApp.app")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let entries = schemes.map { "<string>\($0)</string>" }.joined()
        try Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>CFBundleURLTypes</key>
          <array><dict><key>CFBundleURLSchemes</key><array>\(entries)</array></dict></array>
        </dict></plist>
        """.utf8).write(to: bundle.appendingPathComponent("Info.plist"))
        return (bundle, { try? FileManager.default.removeItem(at: dir) })
    }

    @Test func `the installed inventory reads schemes from each app's bundle`() async throws {
        // simctl listapps reports no CFBundleURLTypes, so the schemes
        // have to come from the Info.plist at the path it reports.
        let (bundle, cleanup) = try makeBundle(schemes: ["myapp"])
        defer { cleanup() }

        let (apps, _) = makeListingApps(output: """
        {
            "com.example.MyApp" = {
                CFBundleIdentifier = "com.example.MyApp";
                CFBundleName = MyApp;
                Path = "\(bundle.path)";
            };
        }
        """)
        let inventory = try await apps.installed()

        #expect(inventory.map(\.bundleIdentifier) == ["com.example.MyApp"])
        #expect(inventory.first?.schemes == ["myapp"])
    }

    @Test func `an app whose bundle has vanished still lists, with no schemes`() async throws {
        let (apps, _) = makeListingApps(output: """
        {
            "com.example.Gone" = {
                CFBundleIdentifier = "com.example.Gone";
                CFBundleName = Gone;
                Path = "/nowhere/Gone.app";
            };
        }
        """)
        let inventory = try await apps.installed()

        #expect(inventory.map(\.bundleIdentifier) == ["com.example.Gone"])
        #expect(inventory.first?.schemes == [])
    }

    @Test func `stdout arriving in several chunks still parses`() async throws {
        // A child's output lands in arbitrary chunks; the adapter has to
        // accumulate before parsing rather than parse each chunk.
        let sub = MockSubprocess()
        given(sub).run(
            executable: .any, arguments: .any, onBytes: .any, onExit: .any
        ).willProduce { _, _, onBytes, onExit in
            onBytes(Data(#"{ "com.example.MyApp" = { CFBundleN"#.utf8))
            onBytes(Data(#"ame = MyApp; }; }"#.utf8))
            onExit(0)
        }
        given(sub).terminate().willReturn()

        let inventory = try await SimctlApps(udid: "U", subprocess: sub).installed()
        #expect(inventory.map(\.bundleIdentifier) == ["com.example.MyApp"])
    }

    @Test func `a non-zero simctl exit propagates as a listing failure`() async {
        let (apps, _) = makeListingApps(output: "", exitCode: 2)
        var caught: AppsError?
        do {
            _ = try await apps.installed()
        } catch {
            caught = error as? AppsError
        }
        #expect(caught == .listFailed(status: 2))
    }
}
