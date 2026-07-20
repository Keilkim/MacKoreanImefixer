import Combine
import Foundation
import Sparkle

/// Owns Sparkle's standard updater for the lifetime of the application.
///
/// The updater deliberately remains disabled when release configuration has
/// not been injected. This keeps ordinary local builds usable without a live
/// appcast or a production EdDSA public key.
@MainActor
final class UpdaterController: ObservableObject {
    @Published private(set) var canCheckForUpdates = false

    private var standardUpdaterController: SPUStandardUpdaterController?

    var isConfigured: Bool {
        standardUpdaterController != nil
    }

    init(bundle: Bundle = .main) {
        guard (try? SparkleUpdateConfiguration(
            infoDictionary: bundle.infoDictionary
        )) != nil else {
            return
        }

        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        standardUpdaterController = controller

        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$canCheckForUpdates)
    }

    /// Presents Sparkle's user-initiated update UI, including release notes.
    func checkForUpdates() {
        standardUpdaterController?.checkForUpdates(nil)
    }
}
