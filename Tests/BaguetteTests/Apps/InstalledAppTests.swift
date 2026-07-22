import Testing
import Foundation
@testable import Baguette

/// Pure-value coverage for `InstalledApp` — "the apps on this device,
/// and the URL schemes each one answers to." This is the data source
/// behind console completion: typing `myap` can only suggest
/// `myapp://` once something has read the device's schemes.
///
/// Reading them takes **two** steps, which is the load-bearing fact
/// here. `xcrun simctl listapps <udid>` emits an old-style property list
/// keyed by bundle identifier, but it carries only a curated subset of
/// each app's metadata — verified against Xcode 26: `ApplicationType`,
/// `Bundle`, `BundleContainer`, `CFBundleDisplayName`,
/// `CFBundleExecutable`, `CFBundleIdentifier`, `CFBundleName`,
/// `CFBundleShortVersionString`, `CFBundleVersion`, `DataContainer`,
/// `GroupContainers`, `IsAppClip`, `IsDeveloperApp`, `IsFirstParty`,
/// `IsHidden`, `IsRemovable`, `Path`, `SBAppTags`. **`CFBundleURLTypes`
/// is not among them**, so schemes cannot come from `listapps` alone.
///
/// What `listapps` does give is `Path` — the app's real on-disk bundle.
/// So schemes come from `<Path>/Info.plist`, and we never have to guess
/// CoreSimulator's container layout or its per-install UUIDs. The two
/// parses are separate pure functions; `SimctlApps` composes them.
@Suite("InstalledApp")
struct InstalledAppTests {

    /// Shape of real `simctl listapps` output, trimmed to the keys we
    /// read. Deliberately carries no `CFBundleURLTypes`, because the
    /// real command doesn't.
    private static let listAppsOutput = """
    {
        "com.example.MyApp" =     {
            ApplicationType = User;
            Bundle = "file:///tmp/Apps/MyApp.app/";
            CFBundleDisplayName = "My App";
            CFBundleIdentifier = "com.example.MyApp";
            CFBundleName = MyApp;
            Path = "/tmp/Apps/MyApp.app";
        };
        "com.example.Pathless" =     {
            ApplicationType = User;
            CFBundleIdentifier = "com.example.Pathless";
            CFBundleName = Pathless;
        };
    }
    """

    private static func parse() -> [InstalledApp] {
        InstalledApp.all(fromListApps: Data(listAppsOutput.utf8))
    }

    private static func app(_ identifier: String) -> InstalledApp? {
        parse().first { $0.bundleIdentifier == identifier }
    }

    // MARK: - the listapps inventory

    @Test func `reads every installed app, ordered by bundle identifier`() {
        #expect(Self.parse().map(\.bundleIdentifier) == ["com.example.MyApp", "com.example.Pathless"])
    }

    @Test func `an app carries its on-disk bundle path`() {
        #expect(Self.app("com.example.MyApp")?.bundlePath == URL(fileURLWithPath: "/tmp/Apps/MyApp.app"))
    }

    @Test func `an app listapps gives no path for has none`() {
        #expect(Self.app("com.example.Pathless")?.bundlePath == nil)
    }

    @Test func `listapps alone yields no schemes`() {
        // Not an edge case — simctl listapps never reports
        // CFBundleURLTypes, so this is the normal result of step one.
        #expect(Self.parse().allSatisfy { $0.schemes.isEmpty })
    }

    @Test func `an app is named by its display name`() {
        #expect(Self.app("com.example.MyApp")?.name == "My App")
    }

    @Test func `an app with no display name falls back to its bundle name`() {
        #expect(Self.app("com.example.Pathless")?.name == "Pathless")
    }

    @Test func `unparseable output yields no apps`() {
        #expect(InstalledApp.all(fromListApps: Data("not a plist".utf8)) == [])
    }

    @Test func `empty output yields no apps`() {
        #expect(InstalledApp.all(fromListApps: Data()) == [])
    }

    // MARK: - schemes, read from the bundle's Info.plist

    /// Two URL-type entries on one app is the common case, not an edge
    /// case: tooling such as Expo appends its own `exp+…` dev-client
    /// scheme as a second entry alongside the app's own.
    private static func infoPlist(_ body: String) -> Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>\(body)</dict></plist>
        """.utf8)
    }

    private static let urlTypes = infoPlist("""
        <key>CFBundleURLTypes</key>
        <array>
          <dict><key>CFBundleURLSchemes</key>
            <array><string>myapp</string><string>com.example.myapp</string></array>
          </dict>
          <dict><key>CFBundleURLSchemes</key>
            <array><string>exp+myapp</string></array>
          </dict>
        </array>
        """)

    @Test func `schemes are read across every URL type entry`() {
        #expect(InstalledApp.schemes(inInfoPlist: Self.urlTypes)
                == ["myapp", "com.example.myapp", "exp+myapp"])
    }

    @Test func `schemes are normalised to lower case for matching`() {
        let plist = Self.infoPlist("""
            <key>CFBundleURLTypes</key>
            <array><dict><key>CFBundleURLSchemes</key>
              <array><string>MyApp</string></array></dict></array>
            """)
        #expect(InstalledApp.schemes(inInfoPlist: plist) == ["myapp"])
    }

    @Test func `a repeated scheme is only listed once`() {
        let plist = Self.infoPlist("""
            <key>CFBundleURLTypes</key>
            <array>
              <dict><key>CFBundleURLSchemes</key><array><string>myapp</string></array></dict>
              <dict><key>CFBundleURLSchemes</key><array><string>MYAPP</string></array></dict>
            </array>
            """)
        #expect(InstalledApp.schemes(inInfoPlist: plist) == ["myapp"])
    }

    @Test func `an app registering no URL types has no schemes`() {
        #expect(InstalledApp.schemes(inInfoPlist: Self.infoPlist("<key>CFBundleName</key><string>X</string>")) == [])
    }

    @Test func `an unreadable Info.plist yields no schemes`() {
        #expect(InstalledApp.schemes(inInfoPlist: Data("nonsense".utf8)) == [])
    }

    @Test func `an app takes on the schemes read from its bundle`() {
        let app = Self.app("com.example.MyApp")?.withSchemes(["myapp"])
        #expect(app?.schemes == ["myapp"])
        #expect(app?.bundleIdentifier == "com.example.MyApp")
    }
}
