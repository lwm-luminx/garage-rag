import SwiftUI
import AppKit
import PythonXPCService

// MARK: - Constants

/// External destinations surfaced by the splash dialog.
enum SplashLinks {
    static let patreon = URL(string: "https://www.patreon.com/rickmark")!
    static let linkedin = URL(string: "https://linkedin.com/in/penwellr")!
    /// The privacy policy, which the App Store guidelines want reachable from inside the app.
    static let privacyPolicy = URL(string: "https://garagerag.app/support/privacy-policy.html")!
    /// Bundled license texts for everything Garage redistributes (`//data/notices`). Nil in
    /// `swift run`, where there is no app bundle to carry it.
    static var thirdPartyNotices: URL? {
        Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "txt")
    }
}

/// UserDefaults key + helpers controlling whether the splash appears at launch.
enum SplashPreferences {
    static let showAtLaunchKey = "garage.splash.showAtLaunch"
}

/// Ensures the launch splash is presented at most once per process, even if
/// the main window is closed and reopened (or a second window is created).
@MainActor
enum SplashLaunchGate {
    static var hasPresented = false
}

extension Notification.Name {
    /// Posted to (re)open the splash dialog on demand (About menu, menu bar).
    static let garageShowSplash = Notification.Name("me.rickmark.garage-rag.showSplash")
    /// Posted by `AppDelegate.quit()` so views close their sheets through their own state first.
    static let garageWillQuit = Notification.Name("me.rickmark.garage-rag.willQuit")
}

// MARK: - Version info

/// The running app's version, read from the bundle's Info.plist. The
/// `CFBundleShortVersionString` / `CFBundleVersion` values are injected at
/// build time by the `macapp_version` Bazel rule.
struct AppVersionInfo: Equatable {
    /// Which build is running. Both are signed from the same sources; the App Store one is the
    /// sandboxed one, so the app's own sandbox entitlement tells them apart.
    enum Distribution: String, Equatable {
        case appStore = "App Store"
        case developerID = "Developer ID"

        static var current: Distribution {
            GarageAppGroup.isSandboxed ? .appStore : .developerID
        }
    }

    let shortVersion: String?
    let build: String?
    let distribution: Distribution?

    init(shortVersion: String?, build: String?, distribution: Distribution? = nil) {
        self.shortVersion = Self.clean(shortVersion)
        self.build = Self.clean(build)
        self.distribution = distribution
    }

    init(bundle: Bundle = .main) {
        self.init(
            shortVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            distribution: .current
        )
    }

    /// Whether the splash offers the Patreon link. The App Store build leaves it out: a link to an
    /// outside payment for a tip breaks App Review guideline 3.1.1 on most storefronts.
    var offersDonationLink: Bool {
        distribution != .appStore
    }

    /// Whether the splash offers the tip jar (`TipJar`), the App Store build's in-app purchase in
    /// place of the Patreon link.
    var offersTipJar: Bool {
        distribution == .appStore
    }

    /// e.g. "Version 0.9 (build 42) · Developer ID", "Version 0.9", or "Development build".
    var displayString: String {
        guard let distribution else { return versionString }
        return "\(versionString) · \(distribution.rawValue)"
    }

    private var versionString: String {
        switch (shortVersion, build) {
        case let (version?, build?) where build != version:
            return "Version \(version) (build \(build))"
        case let (version?, _):
            return "Version \(version)"
        case let (nil, build?):
            return "Build \(build)"
        case (nil, nil):
            return "Development build"
        }
    }

    private static func clean(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

// MARK: - View

/// Welcome / support dialog shown at launch (and from the About menu).
struct SplashView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @AppStorage(SplashPreferences.showAtLaunchKey) private var showAtLaunch = true

    let version: AppVersionInfo

    init(version: AppVersionInfo = AppVersionInfo()) {
        self.version = version
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.top, 28)
                .padding(.bottom, 20)

            VStack(spacing: 14) {
                supportCard
                hireCard
            }
            .padding(.horizontal, 28)

            Divider()
                .padding(.top, 22)

            footer
                .padding(.horizontal, 28)
                .padding(.vertical, 14)
        }
        .frame(width: 600)
    }

    // MARK: Sections

    private var header: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSApp?.applicationIconImage ?? NSImage())
                .resizable()
                .frame(width: 72, height: 72)
                .accessibilityHidden(true)

            Text("Garage")
                .font(.system(size: 26, weight: .bold))

            Text(version.displayString)
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .accessibilityIdentifier("splash.version")
        }
    }

    private var supportCard: some View {
        card(symbol: "heart.fill", tint: .pink, title: "Open source runs on people") {
            Text("""
                Garage is free, open source, and runs entirely on your Mac. Software like this exists because \
                someone chooses to build and maintain it: fixing bugs, keeping pace with new macOS releases \
                and models, writing docs, and answering questions. Contributing to open source funds that \
                unglamorous work, keeps the tools you depend on independent of any single vendor's roadmap, \
                and makes them available to everyone, not just those who can pay.
                """)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.secondary)

            if version.offersDonationLink {
                Text("If Garage saves you time, please consider supporting its development.")
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(.secondary)

                Button {
                    openURL(SplashLinks.patreon)
                } label: {
                    Label("Support Rick on Patreon", systemImage: "heart")
                }
                .buttonStyle(.borderedProminent)
                .tint(.pink)
                .controlSize(.large)
                .accessibilityIdentifier("splash.patreon")
            }

            if version.offersTipJar {
                TipJarView()
            }
        }
    }

    private var hireCard: some View {
        card(symbol: "briefcase.fill", tint: .blue, title: "Available for hire") {
            Text("""
                I'm Rick Mark, the author of Garage, and I'm available to hire. If you or your team could \
                use help with software like this, I'd love to hear from you.
                """)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.secondary)

            Button {
                openURL(SplashLinks.linkedin)
            } label: {
                Label("Get in touch", systemImage: "envelope")
            }
            .accessibilityIdentifier("splash.hire")
        }
    }

    private var footer: some View {
        HStack {
            Toggle("Show this window at launch", isOn: $showAtLaunch)
                .toggleStyle(.checkbox)
                .accessibilityIdentifier("splash.showAtLaunch")

            Spacer()

            Button("Privacy Policy") {
                NSWorkspace.shared.open(SplashLinks.privacyPolicy)
            }
            .buttonStyle(.link)
            .accessibilityIdentifier("splash.privacyPolicy")

            if let notices = SplashLinks.thirdPartyNotices {
                Button("Acknowledgements") {
                    NSWorkspace.shared.open(notices)
                }
                .buttonStyle(.link)
                .accessibilityIdentifier("splash.acknowledgements")
            }

            Button("Continue") {
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("splash.continue")
        }
    }

    // MARK: Card helper

    private func card<Content: View>(
        symbol: String,
        tint: Color,
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 20))
                .foregroundStyle(tint)
                .frame(width: 26)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.headline)
                content()
                    .font(.system(size: 12))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.08))
        )
    }
}
