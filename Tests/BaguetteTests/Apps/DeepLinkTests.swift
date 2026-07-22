import Testing
import Foundation
@testable import Baguette

/// Pure-value coverage for `DeepLink` — what a developer means when they
/// type a URL into the console and expect it to land in their app.
///
/// The load-bearing behaviour is the routing verdict. A custom scheme
/// (`myapp://…`) reaches the app that registered it, but an `https://…`
/// universal link is handed to Safari by the simulator rather than the
/// app — long-standing simulator behaviour that every existing tool
/// (`simctl openurl`, `idb open`, Maestro's `openLink`) performs
/// silently. Modelling the verdict as a value lets the console warn
/// *before* dispatch instead of leaving the developer to wonder why
/// Safari opened.
@Suite("DeepLink")
struct DeepLinkTests {

    @Test func `a custom scheme link routes to the app that registered it`() {
        let link = DeepLink.from("myapp://profile/42")
        #expect(link?.scheme == "myapp")
        #expect(link?.routing == .app)
    }

    @Test func `an https link routes to the browser, not the app`() {
        let link = DeepLink.from("https://example.com/profile/42")
        #expect(link?.scheme == "https")
        #expect(link?.routing == .browser)
    }

    @Test func `an http link routes to the browser too`() {
        #expect(DeepLink.from("http://example.com")?.routing == .browser)
    }

    @Test func `a scheme is normalised to lower case`() {
        let link = DeepLink.from("MyApp://Profile")
        #expect(link?.scheme == "myapp")
        #expect(link?.routing == .app)
    }

    @Test func `a pasted link is trimmed before parsing`() {
        #expect(DeepLink.from("  myapp://profile\n")?.scheme == "myapp")
    }

    @Test func `a bare word is not a deep link`() {
        #expect(DeepLink.from("profile") == nil)
    }

    @Test func `empty input is not a deep link`() {
        #expect(DeepLink.from("   ") == nil)
    }

    @Test func `openArguments projects the simctl openurl argv tail`() {
        let link = DeepLink.from("myapp://profile/42")
        #expect(link?.openArguments(udid: "U") == ["simctl", "openurl", "U", "myapp://profile/42"])
    }
}
