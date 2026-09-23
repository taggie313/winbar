import Foundation

/// A permission request finishing is not proof of trust. Keep the user's next action and the
/// observed result together, including Skip: a newly enabled Continue button is not feedback.
struct SetupCertificatePage: Equatable {
    enum Phase { case needsApproval, approving, checking, verified, skipped, attention }
    let phase: Phase
    let detail: String
    let canApprove: Bool
    let canSkip: Bool

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
        // Read-back wins over any old failure. Without it, a successful exit, Cancel, or Stop
        // Waiting must never become a green tick or an implied approval.
        if let ending = state.lastEnding, ending.work.step == .certificate {
            switch ending.outcome {
            case .failed(let problem):
                return .init(phase: .attention, detail: problem.description, canApprove: canApprove, canSkip: true)
            case .cancelled:
                return .init(phase: .attention, detail: SetupCopy.Certificate.stopped, canApprove: canApprove, canSkip: true)
            case .finished where ending.work == .trustCertificate:
                return .init(phase: .attention, detail: SetupCopy.Certificate.notVerified, canApprove: canApprove, canSkip: true)
            default: break
            }
        }
        switch screen {
        case .trust:
            return .init(phase: .needsApproval, detail: "", canApprove: canApprove, canSkip: true)
        case .needsCertificate:
            return .init(phase: .attention, detail: SetupCopy.Certificate.noCertificate, canApprove: false, canSkip: true)
        case .notYet(let row):
            return .init(phase: .attention, detail: row?.detail ?? "The certificate hasn't been checked yet.", canApprove: false, canSkip: true)
        case .trusted: preconditionFailure("Trusted is handled above")
        }
    }
}
