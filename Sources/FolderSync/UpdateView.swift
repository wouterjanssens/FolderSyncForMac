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
        case .installed:
            installed
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

                if !release.notes.isEmpty {
                    ScrollView {
                        Text(release.notes)
                            .font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 160)
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(nsColor: .separatorColor))
                    )
                }
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

    // MARK: - Installed → reopen prompt

    private var installed: some View {
        simple(
            icon: "checkmark.circle.fill",
            tint: .green,
            title: "Update installed",
            message: "The new version has been installed. Quit FolderSync and open it again to start using it."
        ) {
            Button("Quit FolderSync") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut(.defaultAction)
            Button("Later") { close() }
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
