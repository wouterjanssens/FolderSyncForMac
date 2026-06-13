import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: JobStore
    @EnvironmentObject var updater: UpdateChecker
    @EnvironmentObject var runners: RunnerStore

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .sheet(isPresented: Binding(
            get: { updater.hasSomethingToShow },
            set: { if !$0 { updater.dismiss() } }
        )) {
            UpdateView()
                .environmentObject(updater)
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $store.selection) {
                ForEach($store.jobs) { $job in
                    JobRow(job: $job).tag(job.id)
                }
            }
            Divider()
            HStack(spacing: 6) {
                Button { store.addJob() } label: { Image(systemName: "plus") }
                    .help("Add a job")
                Button {
                    if let id = store.selection {
                        store.removeJob(id)
                        runners.discard(id)
                    }
                } label: { Image(systemName: "minus") }
                    .help("Remove selected job")
                    .disabled(store.selection == nil)
                Spacer()
                Text("\(store.jobs.count) job\(store.jobs.count == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .frame(minWidth: 240)
        .navigationTitle("FolderSync")
    }

    @ViewBuilder
    private var detail: some View {
        if let id = store.selection,
           let index = store.jobs.firstIndex(where: { $0.id == id }) {
            JobDetailView(job: $store.jobs[index], runner: runners.runner(for: id))
                .id(id)
        } else {
            ContentUnavailableView {
                Label("No Job Selected", systemImage: "folder.badge.gearshape")
            } description: {
                Text("Add a job with the + button, then set a local and remote folder.")
            }
        }
    }
}

struct JobRow: View {
    @Binding var job: SyncJob

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.right.circle.fill")
                .foregroundStyle(job.enabled ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.name.isEmpty ? "Untitled Job" : job.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer()
            Toggle("", isOn: $job.enabled)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .help("Include in “Sync All Enabled”")
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        let l = job.localPath.isEmpty ? "—" : (job.localPath as NSString).lastPathComponent
        let r = job.remotePath.isEmpty ? "—" : (job.remotePath as NSString).lastPathComponent
        return "\(l)  →  \(r)"
    }
}
