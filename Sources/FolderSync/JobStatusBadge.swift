import SwiftUI

/// The single lifecycle stage a job is in, derived from its `JobRunner`.
///
/// A job can only be analyzing *or* syncing (never both), so one badge can
/// carry the whole pipeline. Runners live only in memory, so every job reads
/// as `.idle` again after a relaunch — finished state is deliberately not
/// persisted with the job.
enum JobStatus: Equatable {
    case idle
    /// `fraction` is nil while a phase has no known total (the initial scans).
    case analyzing(fraction: Double?)
    case analyzed(changes: Int)
    case upToDate
    case analyzeFailed(errors: Int)
    case syncing(fraction: Double)
    case synced(changes: Int)
    case cancelled
    case syncFailed(errors: Int)

    var isRunning: Bool {
        switch self {
        case .analyzing, .syncing: return true
        default: return false
        }
    }

    /// Empty for `.idle` — the badge renders nothing but keeps its width.
    var symbol: String {
        switch self {
        case .idle:                        return ""
        case .analyzing:                   return "magnifyingglass"
        case .analyzed:                    return "checklist"
        case .upToDate:                    return "checkmark.circle"
        case .analyzeFailed, .syncFailed:  return "exclamationmark.triangle.fill"
        case .syncing:                     return "arrow.right"
        case .synced:                      return "checkmark.circle.fill"
        case .cancelled:                   return "stop.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .idle:                        return .secondary
        case .analyzing, .analyzed:        return .blue
        case .upToDate:                    return .secondary
        case .syncing:                     return .accentColor
        case .synced:                      return .green
        case .cancelled:                   return .orange
        case .analyzeFailed, .syncFailed:  return .red
        }
    }

    /// Tooltip / VoiceOver text.
    var help: String {
        switch self {
        case .idle:
            return "Not analyzed yet"
        case .analyzing(let fraction):
            guard let fraction else { return "Analyzing…" }
            return "Analyzing — \(percent(fraction))"
        case .analyzed(let changes):
            return "\(changes) \(changes == 1 ? "change" : "changes") ready to sync"
        case .upToDate:
            return "Analyzed — already up to date"
        case .analyzeFailed(let errors):
            return "Analysis finished with \(errors) \(errors == 1 ? "error" : "errors")"
        case .syncing(let fraction):
            return "Syncing — \(percent(fraction))"
        case .synced(let changes):
            return "Synced — \(changes) \(changes == 1 ? "change" : "changes")"
        case .cancelled:
            return "Sync cancelled"
        case .syncFailed(let errors):
            return "Sync finished with \(errors) \(errors == 1 ? "error" : "errors")"
        }
    }

    private func percent(_ fraction: Double) -> String {
        "\(Int((min(1, max(0, fraction)) * 100).rounded()))%"
    }
}

/// A stage symbol wrapped in a progress ring while the stage is running.
///
/// The ring is determinate whenever the runner reports a fraction and falls
/// back to a sweeping arc during the indeterminate scan phases. Terminal
/// states drop the ring and show the symbol alone.
struct JobStatusBadge: View {
    let status: JobStatus

    private let diameter: CGFloat = 22
    private let lineWidth: CGFloat = 2

    var body: some View {
        ZStack {
            switch status {
            case .analyzing(let fraction): ring(fraction)
            case .syncing(let fraction):   ring(fraction)
            default:                       EmptyView()
            }

            if !status.symbol.isEmpty {
                Image(systemName: status.symbol)
                    .font(.system(size: status.isRunning ? 9 : 14, weight: .semibold))
                    .foregroundStyle(status.tint)
            }
        }
        .frame(width: diameter, height: diameter)
        .help(status.help)
        .accessibilityLabel(status.help)
    }

    private func ring(_ fraction: Double?) -> some View {
        ZStack {
            Circle().stroke(status.tint.opacity(0.18), lineWidth: lineWidth)
            if let fraction {
                Circle()
                    // Keep a visible sliver at 0 so the ring never looks absent.
                    .trim(from: 0, to: max(0.02, min(1, fraction)))
                    .stroke(status.tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.25), value: fraction)
            } else {
                SweepingArc(color: status.tint, lineWidth: lineWidth)
            }
        }
        // The stroke is centred on the path, so it overflows by half its width.
        .padding(lineWidth / 2)
    }
}

/// Continuously rotating arc used while progress is indeterminate.
private struct SweepingArc: View {
    let color: Color
    let lineWidth: CGFloat
    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.28)
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spinning)
            .onAppear { spinning = true }
    }
}
