import Foundation
import Mockable

/// The apps installed on a device — "the apps on my phone." You add to
/// the collection by installing an `AppBundle`; uninstall / list aren't
/// modelled yet (drag-and-drop only ever *adds*). Named as the plural
/// collection noun per the aggregate convention, alongside `Simulators`
/// / `Chromes` / `Cameras`.
///
/// `@Mockable` so the serve route and CLI command can be unit-tested
/// without a booted simulator. The production impl is `SimctlApps`,
/// backed by `xcrun simctl install`.
@Mockable
protocol Apps: Sendable {
    /// Install an app onto the device. Throws `AppsError.installFailed`
    /// when simctl exits non-zero (device not booted, bad bundle, …).
    func install(_ app: AppBundle) async throws

    /// Install an app that arrived zipped — a browser-packed or
    /// user-zipped folder-form `.app` (simctl can't take a zip
    /// directly). Extracts the archive, locates the single `.app`
    /// inside, and installs it through the normal `AppBundle` path.
    /// Throws `AppsError.extractFailed` when extraction dies,
    /// `.archiveTooLarge` when the extracted contents blow past the
    /// decompression cap (zip bomb), `.noAppInArchive` when nothing
    /// installable is inside, and `.installFailed` when simctl rejects
    /// the located app.
    func install(archive: AppArchive) async throws

    /// Open a deep link on the device — the console's whole point.
    /// Throws `AppsError.openFailed` when simctl exits non-zero.
    ///
    /// Note this reports only whether *dispatch* succeeded. A link with
    /// `.browser` routing dispatches perfectly happily and then lands in
    /// Safari, so callers that care (the console does) inspect
    /// `DeepLink.routing` before calling, rather than expecting a
    /// failure here.
    func open(_ link: DeepLink) async throws

    /// The apps on the device and the schemes they answer to — the
    /// inventory behind console completion. Throws
    /// `AppsError.listFailed` when simctl exits non-zero.
    func installed() async throws -> [InstalledApp]
}

/// Failure modes surfaced when installing an app. Maps to a CLI exit
/// message and an HTTP status on the serve route (bad archives are the
/// client's fault → 4xx; simctl failures are the device's → 5xx).
enum AppsError: Error, Equatable, CustomStringConvertible {
    case installFailed(status: Int32)
    case extractFailed(status: Int32)
    case archiveTooLarge(bytes: Int64, limit: Int64)
    case noAppInArchive
    case openFailed(status: Int32)
    case listFailed(status: Int32)

    var description: String {
        switch self {
        case .openFailed(let status):
            return "xcrun simctl openurl exited \(status)"
        case .listFailed(let status):
            return "xcrun simctl listapps exited \(status)"
        case .installFailed(let status):
            return "xcrun simctl install exited \(status)"
        case .extractFailed(let status):
            return "ditto -x -k exited \(status) (corrupt zip?)"
        case .archiveTooLarge(let bytes, let limit):
            return "archive inflates to \(bytes) bytes, over the \(limit)-byte cap (zip bomb?)"
        case .noAppInArchive:
            return "no single .app bundle at the top level of the zip"
        }
    }
}
