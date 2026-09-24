import SwiftUI
import Testing
import Vision
@testable import Winbar

enum CertificateFixtures {
    static func state(_ name: String) -> SetupWindowState {
        var facts = JourneyFixtures.facts
        facts.rows["H7"] = JourneyFixtures.row("H7", .fixable("Not trusted"))
        if name == "verified" { facts.rows["H7"] = JourneyFixtures.row("H7", .ok("Trusted")) }
        if name == "skipped" { facts.answers.leftAlone.insert("H7") }
        var state = SetupFixtures.state(.certificate, facts: facts)
        state.answers = facts.answers
        if name == "approving" { state.inFlight = SetupFixtures.flight(.trustCertificate) }
        if name == "checking" { state.inFlight = SetupFixtures.flight(.checkAgain(.certificate)) }
        let outcome: SetupRunner.Outcome?
        switch name {
        case "failed": outcome = .failed(.init(title: "Approval was denied", detail: "macOS did not allow the change."))
        case "cancelled": outcome = .cancelled
        case "unverified": outcome = .finished
        default: outcome = nil
        }
        if let outcome {
            state.lastEnding = .init(work: .trustCertificate, outcome: outcome, facts: facts,
                                     slept: false, started: SetupFixtures.started)
        }
        return state
    }
    static func page(_ state: SetupWindowState) -> SetupCertificatePage {
        SetupCertificatePage.page(state, facts: state.facts!)
    }
}

@Suite("Certificate approval says whose turn it is and what was confirmed")
struct SetupCertificatePageTests {
    @Test("Skip changes the page and next button, without claiming success")
    func skipped() {
        let state = CertificateFixtures.state("skipped")
        let page = CertificateFixtures.page(state)
        #expect(page.phase == .skipped && page.canApprove && !page.canSkip)
        #expect(page.detail.contains("isn't approved"))
        #expect(SetupFlow.isSatisfied(.certificate, state.facts!))
        #expect(SetupCopy.journeyNext(.certificate, facts: state.facts) == "Continue Without Approval")
    }

    @Test("Only the checked trust result completes approval")
    func verified() {
        var state = CertificateFixtures.state("failed")
        state.facts?.rows["H7"] = JourneyFixtures.row("H7", .ok("Trusted"))
        state.facts?.answers.leftAlone.insert("H7")
        let page = CertificateFixtures.page(state)
        #expect(page.phase == .verified && !page.canApprove && !page.canSkip)
        #expect(page.detail.contains("winlab02.local"))
        #expect(SetupCopy.journeyNext(.certificate, facts: state.facts) == "Continue to Saved PC")
        #expect(CertificateFixtures.page(CertificateFixtures.state("unverified")).phase == .attention)
    }

    @Test("Denial, Stop Waiting and unsuccessful read-back are not success")
    func failures() {
        for name in ["failed", "cancelled", "unverified"] {
            let state = CertificateFixtures.state(name)
            let page = CertificateFixtures.page(state)
            #expect(page.phase == .attention && page.canApprove && page.canSkip)
            #expect(!page.detail.isEmpty)
            #expect(!SetupFlow.isSatisfied(.certificate, state.facts!))
        }
    }

    @Test("While work runs, hide old success and do not offer another approval")
    func inProgress() {
        for name in ["approving", "checking"] {
            var state = CertificateFixtures.state(name)
            state.facts?.rows["H7"] = JourneyFixtures.row("H7", .ok("Old reading"))
            let page = CertificateFixtures.page(state)
            #expect(page.phase == (name == "approving" ? .approving : .checking))
            #expect(!page.canApprove && !page.canSkip)
        }
    }

    @Test("Retry clears Skip only once the runner accepts the approval job")
    func retry() {
        let state = CertificateFixtures.state("skipped")
        #expect(state.answers.leftAlone.contains("H7"))
        let retried = state.applying(.started(SetupFixtures.flight(.trustCertificate)))
        #expect(!retried.answers.leftAlone.contains("H7"))
        #expect(retried.facts?.answers.leftAlone.contains("H7") == false)
        let cancelled = retried.applying(.ended(.init(work: .trustCertificate, outcome: .cancelled,
            facts: state.facts!, slept: false, started: SetupFixtures.started)))
        #expect(CertificateFixtures.page(cancelled).phase == .attention)
        #expect(!SetupFlow.isSatisfied(.certificate, cancelled.facts!))
    }

    @Test("An unavailable certificate is not an approval button that can do nothing")
    func unavailable() {
        var state = CertificateFixtures.state("initial")
        state.facts?.rows["H7"] = JourneyFixtures.row("H7", .info("No certificate"))
        state.facts?.rows["G7"] = JourneyFixtures.row("G7", .fixable("Needs certificate"))
        #expect(CertificateFixtures.page(state).phase == .attention)
        #expect(!CertificateFixtures.page(state).canApprove)
        state.facts?.answers.leftAlone.insert("H7")
        let page = CertificateFixtures.page(state)
        #expect(page.phase == .skipped && !page.canApprove)
        #expect(!SetupCopy.Certificate.next(page).contains("Approve Instead"))
    }

    @Test("The instructions explain where to act, which password, and the completion signal")
    func instructions() {
        #expect(SetupCopy.Certificate.instructions.contains("Mac login password—not your Windows password"))
        #expect(SetupCopy.Certificate.completion.contains("checks the result automatically"))
        #expect(SetupCopy.Certificate.completion.contains("Certificate verified"))
        #expect(SetupCopy.Certificate.waiting.contains("already approved"))
        #expect(SetupCopy.journeyNext(.savedPC, facts: nil) == "Continue to Connect")
        #expect(SetupCopy.journeyNext(.connect, facts: JourneyFixtures.facts) == "Continue Without Connecting")
        var facts = JourneyFixtures.facts
        facts.answers.connected = true
        #expect(SetupCopy.journeyNext(.connect, facts: facts) == "Continue to Finish")
    }
}

@MainActor @Suite("Certificate instructions visible in the actual wizard")
struct SetupCertificatePageSnapshots {
    @Test("The window displays the result and next action, not just changed button enablement")
    func visibleStates() throws {
        for name in ["initial", "approving", "checking", "verified", "skipped", "failed", "cancelled", "unverified"] {
            let state = CertificateFixtures.state(name)
            let page = CertificateFixtures.page(state)
            for appearance in [Snapshot.Appearance.light, .dark] {
                let png = try #require(Snapshot.png(SetupScreen(state: state, art: nil, send: { _ in }),
                                                   size: CGSize(width: 600, height: 620), appearance: appearance))
                try Snapshot.record(png, as: "certificate-feedback-\(name)-\(appearance.rawValue)")
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate; request.recognitionLanguages = ["en-US"]
                try VNImageRequestHandler(data: png).perform([request])
                let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                let text = lines.joined(separator: " ")
                #expect(text.contains(SetupCopy.Certificate.result(page.phase)), "Missing result for \(name): \(text)")
                if name == "verified" || name == "skipped" {
                    #expect(text.contains(SetupCopy.journeyNext(.certificate, facts: state.facts)))
                    #expect(!text.contains("Trust It"))
                }
                if name == "approving" { #expect(text.contains("Stop Waiting")) }
            }
        }
    }
}
