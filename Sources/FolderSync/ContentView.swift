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
            // Selection is drawn as a border rather than bound to the List's
            // own `selection:`. The system highlight fills the whole row with
            // the accent colour, which swallows the status badge sitting on
            // it; `listRowBackground` cannot suppress that fill, so the
            // binding is replaced with an explicit tap + border.
            List {
                ForEach($store.jobs) { $job in
                    JobRow(job: $job, runner: runners.runner(for: job.id))
                        .listRowBackground(selectionBorder(for: job.id))
                        .contentShape(Rectangle())
                        .onTapGesture { store.selection = job.id }
                }
            }
            .focusable()
            .onMoveCommand(perform: moveSelection)
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

    /// The selected row's outline. Drawn for every row so the List keeps a
    /// stable row background; unselected rows just draw it fully transparent.
    private func selectionBorder(for id: UUID) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .strokeBorder(Color.accentColor, lineWidth: 2)
            .opacity(store.selection == id ? 1 : 0)
    }

    /// Arrow-key navigation, which the List's own `selection:` binding used to
    /// provide for free.
    private func moveSelection(_ direction: MoveCommandDirection) {
        guard !store.jobs.isEmpty else { return }
        let current = store.jobs.firstIndex { $0.id == store.selection }
        switch direction {
        case .up:
            let next = current.map { max(0, $0 - 1) } ?? store.jobs.count - 1
            store.selection = store.jobs[next].id
        case .down:
            let next = current.map { min(store.jobs.count - 1, $0 + 1) } ?? 0
            store.selection = store.jobs[next].id
        default:
            break
        }
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
    /// Observed so a job that is analyzing or syncing in the background keeps
    /// its badge live while a different job is selected.
    @ObservedObject var runner: JobRunner

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
            JobStatusBadge(status: runner.status)
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
