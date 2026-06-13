import SwiftUI

/// Which side's folder-size breakdown the analysis panel is showing.
enum SizeSide: String, CaseIterable, Identifiable {
    case local = "Local", remote = "Remote"
    var id: String { rawValue }
}

/// The two views of an analysis result; only one is shown at a time.
enum AnalysisTab: String, CaseIterable, Identifiable {
    case changes = "Changes to sync", sizes = "Folder sizes"
    var id: String { rawValue }
}

struct JobDetailView: View {
    @Binding var job: SyncJob
    @StateObject private var runner = JobRunner()
    @State private var sizeSide: SizeSide = .local
    @State private var analysisTab: AnalysisTab = .changes

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
                    analysisTab = .changes   // always land on "what changed" first
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

                if runner.isSyncing || runner.isAnalyzing {
                    Button(role: .cancel) { runner.cancel() } label: {
                        Label("Cancel", systemImage: "stop.fill")
                    }
                }

                if runner.isAnalyzing {
                    ProgressView().controlSize(.small)
                }
            }

            if runner.isAnalyzing, let a = runner.analyzeProgress {
                analyzePanel(a)
            }

            if runner.isSyncing, let p = runner.progress {
                progressPanel(p)
            }
        }
    }

    private func analyzePanel(_ a: AnalyzeProgress) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if let fraction = a.fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView().progressViewStyle(.linear)   // indeterminate while scanning
                }
                HStack {
                    Text(a.phase).font(.callout.weight(.semibold))
                    Spacer()
                    if a.total > 0 {
                        Text("\(a.checked) / \(a.total)").font(.callout).foregroundStyle(.secondary)
                    } else if a.filesSeen > 0 {
                        Text("\(a.filesSeen) items").font(.callout).foregroundStyle(.secondary)
                    }
                }
                if !a.currentFile.isEmpty {
                    Text(a.currentFile)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
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
        } else {
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("", selection: $analysisTab) {
                        ForEach(AnalysisTab.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.segmented)
                    Divider()
                    switch analysisTab {
                    case .changes: changesTab(plan)
                    case .sizes:   sizesTab(plan)
                    }
                }
                .padding(6)
            } label: {
                Label("Analysis", systemImage: "checklist")
            }
        }
    }

    // MARK: Changes-to-sync tab

    @ViewBuilder
    private func changesTab(_ plan: SyncPlan) -> some View {
        if plan.isEmpty {
            Label("Already in sync — nothing to do.", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            let sel = plan.items.filter { runner.includedIDs.contains($0.id) }
            let selFiles = sel.filter { !$0.isDirectory }.count
            let allFiles = plan.items.filter { !$0.isDirectory }.count
            let selBytes = sel.filter { ($0.action == .create || $0.action == .update) && !$0.isDirectory }
                .reduce(Int64(0)) { $0 + $1.size }
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 14) {
                    Button {
                        let allSelected = sel.count == plan.items.count
                        runner.setIncluded(plan.items, !allSelected)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: Self.checkboxSymbol(selected: sel.count, total: plan.items.count))
                            Text("All")
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Check or uncheck every file")

                    summaryBadge(count: sel.filter { $0.action == .create && !$0.isDirectory }.count,
                                 label: "New", color: .green, symbol: "plus.circle.fill")
                    summaryBadge(count: sel.filter { $0.action == .move }.count,
                                 label: "Moved", color: .purple, symbol: "arrow.left.arrow.right.circle.fill")
                    summaryBadge(count: sel.filter { $0.action == .update }.count,
                                 label: "Changed", color: .blue, symbol: "arrow.triangle.2.circlepath.circle.fill")
                    summaryBadge(count: sel.filter { $0.action == .delete }.count,
                                 label: "Removed", color: .orange, symbol: "trash.circle.fill")
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("To copy: \(Format.bytes(selBytes))").font(.callout.weight(.medium))
                        Text("\(selFiles) of \(allFiles) files selected")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Divider()
                planList(plan)
            }
        }
    }

    // MARK: Folder-sizes tab

    @ViewBuilder
    private func sizesTab(_ plan: SyncPlan) -> some View {
        let tree = sizeSide == .local ? plan.localSizes : plan.remoteSizes
        if let tree {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Picker("", selection: $sizeSide) {
                        ForEach(SizeSide.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.segmented).fixedSize()
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(Format.bytes(tree.totalBytes)).font(.callout.weight(.medium))
                        Text("\(tree.fileCount) file\(tree.fileCount == 1 ? "" : "s")")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Text("Cumulative size per folder — biggest first. Click a folder to drill in.")
                    .font(.caption2).foregroundStyle(.secondary)
                Divider()
                if tree.children.isEmpty && tree.fileCount == 0 {
                    Text("This folder is empty.")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ScrollView {
                        FolderSizeRow(node: tree, parentBytes: tree.totalBytes, depth: 0)
                            .padding(.trailing, 6)
                    }
                    .frame(height: 300)
                }
            }
        } else {
            Text("No size information available.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    static func checkboxSymbol(selected: Int, total: Int) -> String {
        if total == 0 || selected == 0 { return "square" }
        if selected == total { return "checkmark.square.fill" }
        return "minus.square.fill"
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
        // Headers render lazily and cheaply, so the cap can be generous; it only
        // exists as a backstop against pathological folder counts.
        let cap = 5000
        let shown = Array(groups.prefix(cap))
        // On large plans, start every folder collapsed. Expanded groups build all
        // their file rows eagerly, which previously made big analyses render blank
        // or stall. Collapsed, the whole list shows instantly and files appear on
        // demand when a folder is opened.
        let startExpanded = plan.items.count <= 500
        return VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(shown) { group in
                        FolderGroupView(group: group, color: color(for:),
                                        runner: runner, startExpanded: startExpanded)
                    }
                }
                .padding(.trailing, 6)
            }
            .frame(height: 320)
            if groups.count > cap {
                Text("Showing first \(cap) of \(groups.count) folders. Sync still processes all of them.")
                    .font(.caption2).foregroundStyle(.secondary).padding(.top, 4)
            } else if !startExpanded {
                Text("\(groups.count) folders, \(plan.items.count) items — folders start collapsed; click one to see its files.")
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
    @ObservedObject var runner: JobRunner
    @State private var expanded: Bool

    init(group: FolderGroup, color: @escaping (SyncAction) -> Color,
         runner: JobRunner, startExpanded: Bool = true) {
        self.group = group
        self.color = color
        self._runner = ObservedObject(wrappedValue: runner)
        self._expanded = State(initialValue: startExpanded)
    }

    private var selectedInFolder: Int { group.items.filter { runner.isIncluded($0) }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                // Folder include checkbox (tri-state).
                Button {
                    let allOn = selectedInFolder == group.items.count
                    runner.setIncluded(group.items, !allOn)
                } label: {
                    Image(systemName: JobDetailView.checkboxSymbol(selected: selectedInFolder,
                                                                   total: group.items.count))
                        .foregroundStyle(selectedInFolder == 0 ? Color.secondary : Color.accentColor)
                }
                .buttonStyle(.plain)
                .help("Check or uncheck this whole folder")

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
            }

            if expanded {
                ForEach(group.items) { item in
                    fileRow(item)
                        .padding(.leading, 24)
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
        let included = runner.isIncluded(item)
        return HStack(spacing: 8) {
            Button { runner.toggle(item) } label: {
                Image(systemName: included ? "checkmark.square.fill" : "square")
                    .foregroundStyle(included ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(included ? "Exclude from this sync" : "Include in this sync")

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
        .opacity(included ? 1 : 0.45)
    }
}

// MARK: - Folder size breakdown

/// One collapsible folder in the size-breakdown tree. Shows cumulative size,
/// a bar for its share of the parent, and its file count. Renders children
/// recursively, largest-first. Children are only built when expanded, so a
/// deep tree stays cheap until you drill into it.
struct FolderSizeRow: View {
    let node: FolderSizeNode
    let parentBytes: Int64
    let depth: Int
    @State private var expanded: Bool

    init(node: FolderSizeNode, parentBytes: Int64, depth: Int) {
        self.node = node
        self.parentBytes = parentBytes
        self.depth = depth
        _expanded = State(initialValue: depth == 0)   // root open, rest collapsed
    }

    private var hasChildren: Bool { !node.children.isEmpty }
    private var fraction: Double {
        parentBytes > 0 ? min(1, Double(node.totalBytes) / Double(parentBytes)) : 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if hasChildren { withAnimation(.easeInOut(duration: 0.12)) { expanded.toggle() } }
            } label: {
                HStack(spacing: 6) {
                    if hasChildren {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.caption2).foregroundStyle(.secondary).frame(width: 10)
                    } else {
                        Spacer().frame(width: 10)
                    }
                    Image(systemName: "folder.fill").foregroundStyle(.secondary).font(.caption)
                    Text(node.name.isEmpty ? "(root)" : node.name)
                        .font(.system(.caption, design: .monospaced)
                            .weight(depth == 0 ? .semibold : .regular))
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    proportionBar
                    Text("\(Int((fraction * 100).rounded()))%")
                        .font(.caption2).foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .trailing)
                    Text(Format.bytes(node.totalBytes))
                        .font(.caption.weight(.medium))
                        .frame(width: 72, alignment: .trailing)
                    Text("\(node.fileCount)")
                        .font(.caption2).foregroundStyle(.secondary)
                        .frame(width: 52, alignment: .trailing)
                        .help("\(node.fileCount) files in total")
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                ForEach(node.children) { child in
                    FolderSizeRow(node: child, parentBytes: node.totalBytes, depth: depth + 1)
                        .padding(.leading, 14)
                }
            }
        }
    }

    private var proportionBar: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.secondary.opacity(0.15)).frame(width: 60, height: 5)
            Capsule().fill(barColor).frame(width: max(2, 60 * fraction), height: 5)
        }
    }

    private var barColor: Color {
        switch fraction {
        case 0.5...:     return .red
        case 0.2..<0.5:  return .orange
        default:         return .accentColor
        }
    }
}
