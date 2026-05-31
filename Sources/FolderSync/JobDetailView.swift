import SwiftUI

struct JobDetailView: View {
    @Binding var job: SyncJob
    @StateObject private var runner = JobRunner()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                nameField
                pathsSection
                optionsSection
                actionsSection
                if let result = runner.result { resultView(result) }
                if let plan = runner.plan { planView(plan) }
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(job.name.isEmpty ? "Untitled Job" : job.name)
    }

    // MARK: Name

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("JOB NAME").font(.caption).foregroundStyle(.secondary)
            TextField("Job name", text: $job.name)
                .textFieldStyle(.roundedBorder)
                .font(.title3)
        }
    }

    // MARK: Paths

    private var pathsSection: some View {
        GroupBox {
            VStack(spacing: 12) {
                pathRow(title: "Local folder (source)",
                        systemImage: "internaldrive",
                        path: $job.localPath)
                Divider()
                pathRow(title: "Remote folder (destination)",
                        systemImage: "externaldrive.connected.to.line.below",
                        path: $job.remotePath)
            }
            .padding(6)
        }
    }

    private func pathRow(title: String, systemImage: String, path: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage).font(.subheadline.weight(.medium))
            HStack {
                TextField("Not set", text: path)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                Button("Choose…") {
                    if let chosen = chooseFolder(start: path.wrappedValue) {
                        path.wrappedValue = chosen
                        runner.reset()
                    }
                }
            }
        }
    }

    // MARK: Options

    private var optionsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("When a file is removed locally:")
                    Picker("", selection: $job.deletionPolicy) {
                        ForEach(DeletionPolicy.allCases) { policy in
                            Text(policy.label).tag(policy)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                Text(job.deletionPolicy == .moveToDeletedFolder
                     ? "Removed files are moved to a “\(SyncEngine.deletedFolderName)” folder at the remote root, keeping their subpath. Nothing is permanently deleted."
                     : "Removed files are left untouched on the remote. The remote only grows.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(6)
        } label: {
            Label("Options", systemImage: "slider.horizontal.3")
        }
    }

    // MARK: Actions

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button {
                    runner.analyze(job: job)
                } label: {
                    Label("Analyze", systemImage: "magnifyingglass")
                        .frame(minWidth: 90)
                }
                .keyboardShortcut("a", modifiers: [.command])
                .disabled(runner.isAnalyzing || runner.isSyncing)

                Button {
                    runner.sync(job: job)
                } label: {
                    Label("Run Sync", systemImage: "arrow.right.doc.on.clipboard")
                        .frame(minWidth: 90)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!runner.canSync)

                if runner.isSyncing {
                    Button(role: .cancel) { runner.cancel() } label: {
                        Label("Cancel", systemImage: "stop.fill")
                    }
                }

                if runner.isAnalyzing {
                    ProgressView().controlSize(.small)
                    Text("Analyzing…").foregroundStyle(.secondary)
                }
            }

            if runner.isSyncing, let p = runner.progress {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: p.fraction)
                    HStack {
                        Text("\(p.doneItems) / \(p.totalItems)")
                        Spacer()
                        Text(Format.bytes(p.bytesCopied) + " of " + Format.bytes(p.totalBytes))
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    Text(p.currentFile).font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
        }
    }

    // MARK: Result

    private func resultView(_ result: SyncResult) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if result.cancelled {
                    Label("Sync cancelled", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } else if result.errors.isEmpty {
                    Label("Sync complete", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Label("Sync finished with \(result.errors.count) error\(result.errors.count == 1 ? "" : "s")",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                Text("Copied \(result.created) new, updated \(result.updated), moved \(result.deletedMoved) to _Deleted, created \(result.dirsCreated) folders — \(Format.bytes(result.bytesCopied)).")
                    .font(.callout).foregroundStyle(.secondary)

                if !result.errors.isEmpty {
                    DisclosureGroup("Errors") {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(result.errors.enumerated()), id: \.offset) { _, err in
                                Text("• " + err).font(.caption).textSelection(.enabled)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    // MARK: Plan

    @ViewBuilder
    private func planView(_ plan: SyncPlan) -> some View {
        if !plan.errors.isEmpty {
            GroupBox {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Cannot analyze", systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                    ForEach(Array(plan.errors.enumerated()), id: \.offset) { _, err in
                        Text("• " + err).font(.caption).textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }
        } else if plan.isEmpty {
            GroupBox {
                Label("Already in sync — nothing to do.", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
            }
        } else {
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 16) {
                        summaryBadge(count: plan.createCount, label: "New", color: .green, symbol: "plus.circle.fill")
                        summaryBadge(count: plan.updateCount, label: "Changed", color: .blue, symbol: "arrow.triangle.2.circlepath.circle.fill")
                        summaryBadge(count: plan.deleteCount, label: "Removed", color: .orange, symbol: "trash.circle.fill")
                        Spacer()
                        Text("To copy: \(Format.bytes(plan.bytesToCopy))")
                            .font(.callout.weight(.medium))
                    }
                    Divider()
                    planList(plan)
                }
                .padding(6)
            } label: {
                Label("Analysis — preview of changes", systemImage: "list.bullet.rectangle")
            }
        }
    }

    private func summaryBadge(count: Int, label: String, color: Color, symbol: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).foregroundStyle(color)
            Text("\(count)").fontWeight(.semibold)
            Text(label).foregroundStyle(.secondary)
        }
    }

    private func planList(_ plan: SyncPlan) -> some View {
        let cap = 2000
        let shown = Array(plan.items.prefix(cap))
        return VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(shown) { item in
                        HStack(spacing: 8) {
                            Image(systemName: item.action.symbol)
                                .foregroundStyle(color(for: item.action))
                            Text(item.relativePath + (item.isDirectory ? "/" : ""))
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(1).truncationMode(.middle)
                            Spacer()
                            if !item.isDirectory && item.action != .delete {
                                Text(Format.bytes(item.size))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                        Divider().opacity(0.3)
                    }
                }
                .padding(.trailing, 6)
            }
            .frame(height: 280)
            if plan.items.count > cap {
                Text("Showing first \(cap) of \(plan.items.count) items. Sync still processes all of them.")
                    .font(.caption2).foregroundStyle(.secondary).padding(.top, 4)
            }
        }
    }

    private func color(for action: SyncAction) -> Color {
        switch action {
        case .create: return .green
        case .update: return .blue
        case .delete: return .orange
        }
    }
}
