import Foundation

/// A permission request finishing is not proof of trust. Keep the user's next action and the
/// observed result together, including Skip: a newly enabled Continue button is not feedback.
struct SetupCertificatePage: Equatable {
    enum Phase { case needsApproval, approving, checking, verified, skipped, attention }

    /// The one thing to do next while the step isn't done, which the footer's corner holds
    /// (`SetupJourneyActions.footerAction`) and the card's words name (`SetupCopy.Certificate.next`).
    /// Every problem state used to offer the same three: check again, try approval if available, or
    /// skip; each now has the one that fits what happened.
    enum Next: Equatable {
        /// Ask macOS for the approval: **Approve Certificate…** the first time, **Try Approval
        /// Again…** after a denial or a Stop Waiting, where nothing says it was approved.
        case approve(String)
        /// Read the trust again: after a request that finished without a trust Winbar can see, or
        /// when there's nothing yet to approve.
        case checkAgain
        /// Windows has no certificate for this name: it's made on the Tune step, one step back.
        case goBack
        /// Nothing: the step is done, skipped, or work is running.
        case none
    }

    let phase: Phase
    let detail: String
    let canApprove: Bool
    let canSkip: Bool
    var next: Next = .none

    /// Skipped, with nothing to approve right now: **Check the Certificate Again** takes the Skip back
    /// (`SetupCommand.revisit`). With an approval to ask for, **Approve Instead…** does, and a second
    /// way back beside it would be one button too many.
    var revisits: Bool { phase == .skipped && !canApprove }

    static func page(_ state: SetupWindowState, facts: SetupFlow.Facts) -> Self {
        if let flight = state.inFlight {
            return .init(phase: flight.work == .trustCertificate ? .approving : .checking,
                         detail: "", canApprove: false, canSkip: false)
        }
        let screen = SetupFlow.certificate(facts)
        if case .trusted(let host) = screen {
            return .init(phase: .verified, detail: "Trusted for \(host) on this Mac.", canApprove: false, canSkip: false)
        }
        let canApprove: Bool
        if case .trust = screen { canApprove = facts.vmRunning } else { canApprove = false }
        if facts.answers.leftAlone.contains("H7") {
            return .init(phase: .skipped, detail: SetupCopy.Certificate.skippedDetail, canApprove: canApprove, canSkip: false)
        }
        // A denial or a Stop Waiting leaves nothing approved, so the way on is to ask again. A request
        // that finished may have been approved after all, so the way on is to look.
        let retry: Next = canApprove ? .approve(SetupCopy.Certificate.bRetry) : .checkAgain
        // Read-back wins over any old failure. Without it, a successful exit, Cancel, or Stop
        // Waiting must never become a green tick or an implied approval.
        if let ending = state.lastEnding, ending.work.step == .certificate {
            switch ending.outcome {
            case .failed(let problem):
                return .init(phase: .attention, detail: problem.description, canApprove: canApprove, canSkip: true, next: retry)
            case .cancelled:
                return .init(phase: .attention, detail: SetupCopy.Certificate.stopped, canApprove: canApprove, canSkip: true, next: retry)
            // Only while the page is the request's own read-back: the first read after it (Check Again,
            // or the look on coming back, `awaitsLook`) decides it, and the page is then what that read
            // says. Otherwise nothing would end "not verified", since a read nobody pressed isn't an
            // ending and doesn't replace this one.
            case .finished where ending.work == .trustCertificate && ending.facts.stamp == facts.stamp:
                return .init(phase: .attention, detail: SetupCopy.Certificate.notVerified, canApprove: canApprove, canSkip: true,
                             next: .checkAgain)
            default: break
            }
        }
        switch screen {
        case .trust:
            return .init(phase: .needsApproval, detail: "", canApprove: canApprove, canSkip: true,
                         next: canApprove ? .approve(SetupCopy.Certificate.bApprove) : .checkAgain)
        case .needsCertificate:
            return .init(phase: .attention, detail: SetupCopy.Certificate.noCertificate, canApprove: false, canSkip: true,
                         next: .goBack)
        case .notYet(let row):
            return .init(phase: .attention, detail: row.map { SetupCopy.Tune.words($0.detail) } ?? "The certificate hasn't been checked yet.",
                         canApprove: false, canSkip: true, next: .checkAgain)
        case .trusted: preconditionFailure("Trusted is handled above")
        }
    }

    /// Whether the page is an approval's own read-back saying "not verified": the request finished,
    /// and nothing has been read since. A trust given in the macOS dialog can land after that read,
    /// so coming back to the window looks (`SetupJourneyActions.returnRead`), and that look decides
    /// it. Not an approval to press, a denial or a Stop Waiting: those are presses, and a look is
    /// never taken before one. Pure.
    static func awaitsLook(_ state: SetupWindowState) -> Bool {
        guard state.inFlight == nil, let facts = state.facts, let ending = state.lastEnding,
              ending.work == .trustCertificate, ending.outcome == .finished, ending.facts.stamp == facts.stamp else { return false }
        let page = page(state, facts: facts)
        return page.phase == .attention && page.next == .checkAgain
    }
}
