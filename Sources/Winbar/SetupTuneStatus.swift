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

    static func counts(_ facts: SetupFlow.Facts, work: SetupRunner.Work? = nil) -> [Self: Int] {
        let screen = SetupFlow.tune(facts)
        var counts: [Self: Int] = [:]
        for row in screen.rows { counts[status(for: row, facts: facts, work: work), default: 0] += 1 }
        if !screen.unread.isEmpty { counts[.notChecked] = screen.unread.count }
        return counts
    }
}

/// The tune page's rows, in the three groups it draws, each in the recipe's order (rows Windows
/// didn't answer for after the rest of the first): what waits on Ben first and open, then what is settled some other way (a Skip, a change waiting for the restart, a
/// note), and last, folded into one line, what passed. Fifteen cards of the same weight, with the one
/// that mattered twelfth, is what this replaces.
///
/// Grouped by how each row stands without the work in flight, so a Check Again doesn't empty the
/// folded group into a column of spinners and put it back a moment later: the rows stay where they
/// are, and only their marks turn (`SetupTuneStatus.status(for:facts:work:)`). Pure.
struct SetupTuneGroups: Equatable {
    var needsYou: [SetupFlow.Row] = []
    var others: [SetupFlow.Row] = []
    var verified: [SetupFlow.Row] = []

    init(_ facts: SetupFlow.Facts) {
        var unread: [SetupFlow.Row] = []
        for row in SetupFlow.tune(facts).rows {
            switch SetupTuneStatus.status(for: row, facts: facts) {
            // A row Windows didn't answer for goes after the ones Ben can act on: the headline's "1
            // setting needs you" points at the first row, and that has to be his.
            case .needsAttention: if row.kind == .error { unread.append(row) } else { needsYou.append(row) }
            case .verified: verified.append(row)
            default: others.append(row)
            }
        }
        needsYou += unread
    }
}

/// What the tune page says first: the one line that answers "is this done, and if not, what's mine?".
enum SetupTuneHeadline: Equatable {
    /// Work is running on this step; the words name it (`SetupCopy.Tune.busy`).
    case working(String)
    /// Some rows haven't been read, so the survey still has to ask Windows.
    case notAsked
    /// Rows the step waits on: `fixable` of them are what **Fix Everything** would fix.
    case needsYou(count: Int, fixable: Int)
    /// Nothing waits on Ben, but Winbar couldn't read some rows (Windows didn't answer). The step
    /// goes on without them (`SetupFlow.isSatisfied`), so saying "tuned" would be untrue and "needs
    /// you" would hold him for nothing.
    case unchecked(count: Int)
    /// Done: every row passed, was left alone, or is staged for the restart (`staged` of them).
    case tuned(staged: Int)

    static func of(_ facts: SetupFlow.Facts, working: String? = nil) -> Self {
        if let working { return .working(working) }
        let screen = SetupFlow.tune(facts)
        if !screen.unread.isEmpty { return .notAsked }
        let needs = SetupTuneGroups(facts).needsYou
        // G0 is the exception to "errors don't hold the step": without Windows answering, nothing
        // else could be read (`SetupFlow.settled`).
        let holding = needs.filter { $0.kind != .error || $0.id == "G0" }
        if !holding.isEmpty { return .needsYou(count: holding.count, fixable: screen.fixEverything.count) }
        if !needs.isEmpty { return .unchecked(count: needs.count) }
        return .tuned(staged: screen.staged.count)
    }
}

/// The buttons on a row that waits on Ben, as values: what each says, what VoiceOver says for it,
/// and what it sends. **Fix** where Winbar can fix it (**Try Again** after a Fix that didn't work);
/// where Ben has to do it, a button that takes him there and one that says he did, each named for the
/// row; **Check Again** where Windows didn't answer, which offered only Skip; **Undo This Change**
/// for a staged change that was refused; and **Skip**, except where the row is already skipped and
/// on G0, which nothing can stand in for. Pure.
enum SetupTuneRowActions {
    struct Action: Equatable {
        var title: String
        var spoken: String
        var command: SetupCommand
    }

    static func of(_ row: SetupFlow.Row, facts: SetupFlow.Facts) -> [Action] {
        func action(_ title: String, _ command: SetupCommand) -> Action {
            Action(title: title, spoken: SetupCopy.Tune.spoken(title, row: SetupCopy.Tune.title(row)), command: command)
        }
        let screen = SetupFlow.tune(facts)
        var actions: [Action] = []
        if row.kind == .fixable, row.action == .fix {
            actions.append(action(row.failure == nil ? SetupCopy.Tune.bFix : SetupCopy.bTryAgain, .perform(.run(.fix(checkID: row.id)))))
        }
        if row.kind == .manual {
            if row.canGuide { actions.append(action(SetupCopy.Tune.bGuide(row.id), .perform(.run(.guide(checkID: row.id))))) }
            actions.append(action(SetupCopy.Tune.bDone(row.id), .perform(.run(.recordDone(checkID: row.id)))))
        }
        if row.kind == .error { actions.append(action(SetupCopy.bCheckAgain, .perform(.run(.checkAgain(.tune))))) }
        if screen.staged.contains(row.id) { actions.append(action("Undo This Change", .discardChanges(row.id))) }
        if row.id != "G0", SetupTuneStatus.status(for: row, facts: facts) != .skipped {
            actions.append(action(SetupCopy.bSkip, .skip(row.id)))
        }
        return actions
    }
}
