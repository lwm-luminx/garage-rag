import GarageUpdater
import SwiftUI

/// "Check for Updates…" — the app menu item and the menu bar equivalent.
///
/// The button renders nothing at all when the running build can't update itself
/// (App Store builds, or a Developer ID build made without a signing key): a
/// permanently disabled menu item just invites the user to wonder what is wrong.
struct CheckForUpdatesButton: View {
    @ObservedObject var updater: UpdaterService

    var body: some View {
        if updater.isAvailable {
            Button("Check for Updates…") {
                updater.checkForUpdates()
            }
            // False while a check is already running.
            .disabled(!updater.canCheckForUpdates)
            .accessibilityIdentifier("updates.check")
        }
    }
}

/// "Receive Beta Updates" — a checkmark item under "Check for Updates…". Betas are
/// appcast entries on the `beta` channel; releases on no channel reach everyone.
/// Absent, like the button, when the build can't update itself.
struct BetaUpdatesToggle: View {
    @ObservedObject var updater: UpdaterService

    var body: some View {
        if updater.isAvailable {
            Toggle("Receive Beta Updates", isOn: $updater.receivesBetaUpdates)
                .accessibilityIdentifier("updates.beta")
        }
    }
}
