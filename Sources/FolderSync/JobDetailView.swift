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
                progressPanel(p)
            }
        }
    }

    private func progressPanel(_ p: SyncProgress) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: p.fraction)
                HStack {
                    Text("\(Int(p.fraction * 100))%").fontWeight(.semibold)
                    Text("·")
                    Text(Format.bytes(p.bytesCopied) + " of " + Format.bytes(p.totalBytes))
                    Spacer()
                    Text("\(p.doneItems) / \(p.totalItems) items")
                }
                .font(.callout).foregroundStyle(.secondary)

                HStack(spacing: 18) {
                    Label(Format.speed(p.currentSpeed), systemImage: "speedometer")
                        .help("Current speed (recent average)")
                    Label("avg " + Format.speed(p.averageSpeed), systemImage: "chart.line.uptrend.xyaxis")
                        .help("Average speed over the whole session")
                    Spacer()
                    if let eta = p.etaSeconds {
                        Label("~" + Format.duration(eta) + " left", systemImage: "clock")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    Text(p.phase).font(.caption.weight(.semibold))
                    if !p.currentFile.isEmpty {
                        Text(p.currentFile)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
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
                Text("Copied \(result.created) new, relocated \(result.moved), updated \(result.updated), moved \(result.deletedMoved) to _Deleted, created \(result.dirsCreated) folders — \(Format.bytes(result.bytesCopied)) copied.")
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
                        summaryBadge(count: plan.moveCount, label: "Moved", color: .purple, symbol: "arrow.left.arrow.right.circle.fill")
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
        let groups = FolderGroup.build(from: plan.items)
        let cap = 400
        let shown = Array(groups.prefix(cap))
        return VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(shown) { group in
                        FolderGroupView(group: group, color: color(for:))
                    }
                }
                .padding(.trailing, 6)
            }
            .frame(height: 320)
            if groups.count > cap {
                Text("Showing first \(cap) of \(groups.count) folders. Sync still processes all of them.")
                    .font(.caption2).foregroundStyle(.secondary).padding(.top, 4)
            }
        }
    }

    private func color(for action: SyncAction) -> Color {
        switch action {
        case .create: return .green
        case .move:   return .purple
        case .update: return .blue
        case .delete: return .orange
        }
    }
}

// MARK: - Folder grouping

/// Plan items grouped by their containing folder, with per-folder subtotals.
struct FolderGroup: Identifiable {
    let folder: String          // "" == remote root
    var items: [PlanItem]
    var copyBytes: Int64
    var newCount: Int
    var movedCount: Int
    var changedCount: Int
    var removedCount: Int

    var id: String { folder }
    var displayName: String { folder.isEmpty ? "(root)" : folder }

    static func build(from items: [PlanItem]) -> [FolderGroup] {
        var buckets: [String: FolderGroup] = [:]
        for item in items {
            let folder = (item.relativePath as NSString).deletingLastPathComponent
            var g = buckets[folder] ?? FolderGroup(folder: folder, items: [], copyBytes: 0,
                                                   newCount: 0, movedCount: 0,
                                                   changedCount: 0, removedCount: 0)
            g.items.append(item)
            switch item.action {
            case .create:
                if !item.isDirectory { g.newCount += 1; g.copyBytes += item.size }
            case .move:    g.movedCount += 1
            case .update:  g.changedCount += 1; g.copyBytes += item.size
            case .delete:  g.removedCount += 1
            }
            buckets[folder] = g
        }
        for key in buckets.keys {
            buckets[key]!.items.sort {
                ($0.action.sortRank, $0.relativePath.lowercased())
                    < ($1.action.sortRank, $1.relativePath.lowercased())
            }
        }
        return buckets.values.sorted { $0.folder.lowercased() < $1.folder.lowercased() }
    }
}

/// A collapsible folder section showing its files and a subtotal.
struct FolderGroupView: View {
    let group: FolderGroup
    let color: (SyncAction) -> Color
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.12)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2).foregroundStyle(.secondary).frame(width: 10)
                    Image(systemName: "folder.fill").foregroundStyle(.secondary)
                    Text(group.displayName)
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                        .lineLimit(1).truncationMode(.head)
                    Spacer()
                    countPills
                    if group.copyBytes > 0 {
                        Text(Format.bytes(group.copyBytes))
                            .font(.caption.weight(.medium))
                            .padding(.leading, 4)
                    }
                }
                .padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                ForEach(group.items) { item in
                    fileRow(item)
                        .padding(.leading, 26)
                }
            }
            Divider().opacity(0.4)
        }
    }

    private var countPills: some View {
        HStack(spacing: 8) {
            if group.newCount > 0 { pill(group.newCount, .green) }
            if group.movedCount > 0 { pill(group.movedCount, .purple) }
            if group.changedCount > 0 { pill(group.changedCount, .blue) }
            if group.removedCount > 0 { pill(group.removedCount, .orange) }
        }
    }

    private func pill(_ n: Int, _ c: Color) -> some View {
        Text("\(n)")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(c)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(c.opacity(0.15), in: Capsule())
    }

    private func fileRow(_ item: PlanItem) -> some View {
        let name = (item.relativePath as NSString).lastPathComponent
        return HStack(spacing: 8) {
            Image(systemName: item.action.symbol)
                .foregroundStyle(color(item.action))
                .font(.caption)
            VStack(alignment: .leading, spacing: 1) {
                Text(name + (item.isDirectory ? "/" : ""))
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
                if item.action == .move, let from = item.fromPath {
                    Text("from " + from)
                        .font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.head)
                }
            }
            Spacer()
            if !item.isDirectory {
                Text(Format.bytes(item.size))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 1)
    }
}
