import Testing
import Foundation
import Mockable
@testable import Baguette

/// Handler-level coverage for the console's two routes. We drive the
/// pure dispatch helpers rather than the Hummingbird `Response`
/// wrappers, with `MockSimulators` + `MockApps`.
///
/// `openURL` reports *where the link went*, not just whether dispatch
/// succeeded — an https link dispatches perfectly happily and then lands
/// in Safari, so "ok" alone would be a lie the URL bar repeats to the
/// developer. `schemes` answers the completion inventory, ranked
/// server-side so the browser never has to re-implement the ordering.
@Suite("Server deep-link routes")
struct DeepLinkRoutesTests {

    private func host(
        installed: [InstalledApp] = [],
        openSucceeds: Bool = true,
        listSucceeds: Bool = true
    ) -> (MockSimulators, MockApps) {
        let simulators = MockSimulators()
        let sim = MockSimulator()
        let apps = MockApps()
        given(simulators).find(udid: .value("U")).willReturn(sim)
        given(simulators).find(udid: .value("nope")).willReturn(nil)
        given(sim).apps().willReturn(apps)

        if openSucceeds {
            given(apps).open(.any).willReturn(())
        } else {
            given(apps).open(.any).willThrow(AppsError.openFailed(status: 1))
        }
        if listSucceeds {
            given(apps).installed().willReturn(installed)
        } else {
            given(apps).installed().willThrow(AppsError.listFailed(status: 1))
        }
        return (simulators, apps)
    }

    private static let myApp = InstalledApp(
        bundleIdentifier: "com.example.MyApp",
        name: "My App",
        schemes: ["myapp", "com.example.myapp"]
    )

    // MARK: - openurl

    @Test func `opening a custom scheme reports it reached the app`() async {
        let (simulators, apps) = host()
        let outcome = await Server.openURL(udid: "U", url: "myapp://profile", simulators: simulators)

        #expect(outcome == .opened(routing: .app))
        verify(apps).open(.value(DeepLink.from("myapp://profile")!)).called(1)
    }

    @Test func `opening an https link reports it went to the browser`() async {
        // Dispatch succeeds; the link still lands in Safari. The URL bar
        // needs to say so, so the outcome carries the routing.
        let (simulators, _) = host()
        let outcome = await Server.openURL(
            udid: "U", url: "https://example.com/x", simulators: simulators
        )
        #expect(outcome == .opened(routing: .browser))
    }

    @Test func `a bare word is refused as not a URL`() async {
        let (simulators, apps) = host()
        let outcome = await Server.openURL(udid: "U", url: "profile", simulators: simulators)

        #expect(outcome == .notAURL)
        verify(apps).open(.any).called(0)
    }

    @Test func `opening against an unknown device is reported`() async {
        let (simulators, _) = host()
        let outcome = await Server.openURL(udid: "nope", url: "myapp://x", simulators: simulators)
        #expect(outcome == .unknownDevice)
    }

    @Test func `a failed dispatch is reported`() async {
        let (simulators, _) = host(openSucceeds: false)
        let outcome = await Server.openURL(udid: "U", url: "myapp://x", simulators: simulators)
        #expect(outcome == .dispatchFailed)
    }

    // MARK: - schemes

    @Test func `the schemes route answers the ranked inventory`() async {
        let (simulators, _) = host(installed: [Self.myApp])
        let outcome = await Server.schemes(udid: "U", query: "", simulators: simulators)

        #expect(outcome == .ok([
            SchemeSuggestion(scheme: "myapp", appName: "My App", bundleIdentifier: "com.example.MyApp"),
            SchemeSuggestion(scheme: "com.example.myapp", appName: "My App", bundleIdentifier: "com.example.MyApp"),
        ]))
    }

    @Test func `the schemes route ranks against the typed query`() async {
        // Ranking is server-side so the browser never re-implements it.
        let (simulators, _) = host(installed: [
            InstalledApp(bundleIdentifier: "a", name: "A", schemes: ["superapp"]),
            InstalledApp(bundleIdentifier: "b", name: "B", schemes: ["app"]),
        ])
        let outcome = await Server.schemes(udid: "U", query: "app", simulators: simulators)

        guard case .ok(let suggestions) = outcome else { return #expect(Bool(false)) }
        #expect(suggestions.map(\.scheme) == ["app", "superapp"])
    }

    @Test func `listing against an unknown device is reported`() async {
        let (simulators, _) = host()
        #expect(await Server.schemes(udid: "nope", query: "", simulators: simulators) == .unknownDevice)
    }

    @Test func `a failed listing is reported`() async {
        let (simulators, _) = host(listSucceeds: false)
        #expect(await Server.schemes(udid: "U", query: "", simulators: simulators) == .listFailed)
    }

    // MARK: - what the browser actually receives

    private func object(_ json: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
    }

    @Test func `an opened custom scheme serialises as having reached the app`() {
        let body = object(Server.openedJSONString(routing: .app))
        #expect(body["routing"] as? String == "app")
        #expect(body["warning"] == nil)
    }

    @Test func `an opened https link serialises with the warning attached`() {
        // The copy lives server-side so the URL bar renders it rather
        // than keeping its own duplicate of the explanation.
        let body = object(Server.openedJSONString(routing: .browser))
        #expect(body["routing"] as? String == "browser")
        let warning = body["warning"] as? String
        #expect(warning?.contains("Safari") == true)
    }

    @Test func `suggestions serialise with what the bar needs to render a row`() {
        let json = Server.schemesJSONString([
            SchemeSuggestion(scheme: "myapp", appName: "My App", bundleIdentifier: "com.example.MyApp"),
        ])
        let rows = (object(json)["schemes"] as? [[String: Any]]) ?? []

        #expect(rows.count == 1)
        #expect(rows.first?["scheme"] as? String == "myapp")
        #expect(rows.first?["completion"] as? String == "myapp://")
        #expect(rows.first?["app"] as? String == "My App")
        #expect(rows.first?["bundleId"] as? String == "com.example.MyApp")
    }

    @Test func `an empty inventory serialises as an empty list`() {
        #expect((object(Server.schemesJSONString([]))["schemes"] as? [[String: Any]])?.isEmpty == true)
    }
}
