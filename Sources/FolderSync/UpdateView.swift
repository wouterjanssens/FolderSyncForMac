import SwiftUI

/// The update dialog. Shown as a sheet whenever the updater has something to
/// say: a new release is available, a download is in flight, the update has
/// been installed (reopen prompt), an error, or — for a manual check — an
/// "up to date" confirmation.
struct UpdateView: View {
    @EnvironmentObject var updater: UpdateChecker
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            content
        }
        .padding(24)
        .frame(width: 460)
    }

    @ViewBuilder
    private var content: some View {
        switch updater.phase {
        case .available, .downloading:
            availableOrDownloading
        case .readyToRelaunch:
            readyToRelaunch
        case .upToDate:
            simple(
                icon: "checkmark.circle.fill",
                tint: .green,
                title: "You're up to date",
                message: "FolderSync \(updater.currentVersion) is the latest version."
            ) {
                Button("OK") { close() }.keyboardShortcut(.defaultAction)
            }
        case .failed(let message):
            simple(
                icon: "exclamationmark.triangle.fill",
                tint: .orange,
                title: "Update problem",
                message: message
            ) {
                Button("OK") { close() }.keyboardShortcut(.defaultAction)
            }
        case .idle, .checking:
            // Nothing to show — sheet is being dismissed.
            Color.clear.frame(height: 0)
        }
    }

    // MARK: - New release available / downloading

    private var availableOrDownloading: some View {
        let release = updater.available
        let downloading = updater.phase == .downloading
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text("A new version of FolderSync is available")
                        .font(.headline)
                    if let release {
                        Text("Version \(release.version) is available — you have \(updater.currentVersion).")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let release {
                Link(destination: release.pageURL) {
                    Label("See what's changed", systemImage: "link")
                }
                .font(.subheadline)
            }

            if downloading {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: updater.progress)
                    Text("Downloading update…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Spacer()
                Button("Later") { close() }
                    .disabled(downloading)
                Button("Update Now") {
                    Task { await updater.downloadAndInstall() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(downloading)
            }
        }
    }

    // MARK: - Downloaded → relaunch to apply

    private var readyToRelaunch: some View {
        simple(
            icon: "checkmark.circle.fill",
            tint: .green,
            title: "Update ready",
            message: "The update has been downloaded. FolderSync will quit and reopen automatically to finish installing it."
        ) {
            Button("Later") { close() }
            Button("Relaunch & Update") {
                updater.finishUpdate()
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func simple<Buttons: View>(
        icon: String, tint: Color, title: String, message: String,
        @ViewBuilder buttons: () -> Buttons
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 36))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        HStack {
            Spacer()
            buttons()
        }
    }

    private func close() {
        updater.dismiss()
        dismiss()
    }
}
