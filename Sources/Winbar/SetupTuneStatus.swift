import Foundation

/// The visible result of a tuning check, not the exit status of the script that tried to fix it.
/// In particular, a successful action is not Verified until the subsequent read reports `.ok`.
enum SetupTuneStatus: CaseIterable, Hashable {
    case verified, pendingRestart, skipped, needsAttention, information, checking, applying, notChecked

    static func status(for row: SetupFlow.Row, facts: SetupFlow.Facts,
                       work: SetupRunner.Work? = nil) -> Self {
        let screen = SetupFlow.tune(facts)
        switch work {
        case .survey?, .checkAgain(.tune)?: return .checking
        case .fix(checkID: row.id)?: return .applying
        case .fixEverything? where screen.fixEverything.contains(row.id): return .applying
        case .applyChanges? where screen.staged.contains(row.id): return .applying
        default: break
        }
        // Errors and refusals must remain visible even when an earlier change is still staged.
        if row.failure != nil || row.kind == .error { return .needsAttention }
        if screen.staged.contains(row.id) {
            return row.kind == .manual ? .needsAttention : .pendingRestart
        }
        // A fresh successful check wins over an old Skip or an unticked installer option.
        if row.kind == .ok { return .verified }
        if screen.declined[row.id] != nil || facts.answers.leftAlone.contains(row.id)
            || (row.id == "G9" && facts.keepBitLocker) { return .skipped }
        return row.kind == .info ? .information : .needsAttention
    }

    /// The rows in the recipe's order, except that the ones waiting on the person come first: a
    /// count saying "1 needs attention" above fourteen verified cards left that one below the fold.
    /// Stable, so everything else keeps the order `winbar doctor` prints.
    static func attentionFirst(_ rows: [SetupFlow.Row], facts: SetupFlow.Facts,
                               work: SetupRunner.Work? = nil) -> [SetupFlow.Row] {
        rows.enumerated()
            .sorted { a, b in
                let first = status(for: a.element, facts: facts, work: work) == .needsAttention
                let second = status(for: b.element, facts: facts, work: work) == .needsAttention
                return first != second ? first : a.offset < b.offset
            }
            .map(\.element)
    }

    static func counts(_ facts: SetupFlow.Facts, work: SetupRunner.Work? = nil) -> [Self: Int] {
        let screen = SetupFlow.tune(facts)
        var counts: [Self: Int] = [:]
        for row in screen.rows { counts[status(for: row, facts: facts, work: work), default: 0] += 1 }
        if !screen.unread.isEmpty { counts[.notChecked] = screen.unread.count }
        return counts
    }

    var symbol: String {
        switch self {
        case .verified: return "checkmark.circle.fill"
        case .pendingRestart: return "clock"
        case .skipped: return "minus.circle"
        case .needsAttention: return "exclamationmark.triangle.fill"
        case .information: return "info.circle"
        case .checking: return "magnifyingglass"
        case .applying: return "arrow.triangle.2.circlepath"
        case .notChecked: return "questionmark.circle"
        }
    }
}
