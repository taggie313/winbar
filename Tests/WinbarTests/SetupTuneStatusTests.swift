import SwiftUI
import Testing
import Vision
@testable import Winbar

@Suite("Tuning results say what was actually verified")
struct SetupTuneStatusTests {
    private func result(_ id: String, _ status: Status, work: SetupRunner.Work? = nil,
                        change: (inout SetupFlow.Facts) -> Void = { _ in }) -> SetupTuneStatus {
        var facts = JourneyFixtures.facts
        facts.rows[id] = JourneyFixtures.row(id, status)
        change(&facts)
        return SetupTuneStatus.status(for: facts.rows[id]!, facts: facts, work: work)
    }

    @Test("Only a passing read becomes Verified, not a missing check or successful script")
    func verifiedRequiresReadback() {
        #expect(result("G1", .ok("Balanced, tuned")) == .verified)
        #expect(result("G1", .fixable("Still on the wrong plan")) == .needsAttention)
        #expect(result("G1", .manual("Couldn't check", how: "Sign in")) == .needsAttention)
        #expect(result("G1", .error("Guest did not answer")) == .needsAttention)
        #expect(result("G1", .info("Needs Windows")) == .information)
        var facts = JourneyFixtures.facts
        facts.rows.removeValue(forKey: "G1")
        #expect(SetupTuneStatus.counts(facts)[.notChecked] == 1)
        #expect(SetupTuneStatus.counts(facts)[.verified] == SetupFlow.checks(in: .tune).count - 1)
    }

    @Test("A changed setting stays Applying through its read-back; checking replaces stale success")
    func workIsNotSuccess() {
        #expect(result("G1", .ok("Old reading"), work: .fix(checkID: "G1")) == .applying)
        #expect(result("G2", .ok("Shut down"), work: .fix(checkID: "G1")) == .verified)
        #expect(result("G1", .ok("Old reading"), work: .survey) == .checking)
        #expect(result("G1", .ok("Old reading"), work: .checkAgain(.tune)) == .checking)
        #expect(result("G1", .fixable("Wrong plan"), work: .fixEverything) == .applying)
        #expect(result("G1", .ok("Balanced"), work: .fixEverything) == .verified)
        #expect(result("G9", .fixable("Encrypted"), work: .fixEverything) == .needsAttention)
    }

    @Test("Staged hardware is Pending restart, even if the current reading passes")
    func pendingIsNotVerified() {
        for value in [Status.ok("6 cores"), .fixable("4 cores, want 6")] {
            #expect(result("H3", value) { $0.pending.cpuCores = 6 } == .pendingRestart)
        }
        #expect(result("H4", .fixable("8 GB")) { $0.pending.memoryMB = 16384 } == .pendingRestart)
        #expect(result("H3", .fixable("4 cores"), work: .applyChanges) { $0.pending.cpuCores = 6 } == .applying)
        let note = String(SetupCopy.Tune.stagedNote(vm: "winlab02").characters)
        #expect(note.hasPrefix("Not applied yet."))
    }

    @Test("A refusal or failed fix is never disguised as a queued change")
    func refusalWins() {
        #expect(result("H3", .manual("Other VM running", how: "Stop it first")) { $0.pending.cpuCores = 6 } == .needsAttention)
        #expect(result("H3", .error("Could not check UTM")) { $0.pending.cpuCores = 6 } == .needsAttention)
        #expect(result("H3", .fixable("4 cores")) {
            $0.pending.cpuCores = 6; $0.rows["H3"]?.failure = "Update failed"
        } == .needsAttention)
    }

    @Test("Skipped choices are explicit, but do not override a current successful check")
    func skipped() {
        for status in [Status.fixable("Not configured"), .manual("Needs you", how: "Do this")] {
            #expect(result("G1", status) { $0.declined.tuning = true } == .skipped)
            #expect(result("G1", status) { $0.answers.leftAlone.insert("G1") } == .skipped)
            #expect(result("G9", status) { $0.keepBitLocker = true } == .skipped)
        }
        #expect(result("G1", .ok("Balanced")) { $0.declined.tuning = true; $0.answers.leftAlone.insert("G1") } == .verified)
        #expect(result("G9", .ok("Fully decrypted")) { $0.keepBitLocker = true } == .verified)
        #expect(SetupCopy.Tune.detail(JourneyFixtures.row("G9", .ok("Fully decrypted")), keptBitLocker: true) == "Fully decrypted")
        #expect(result("G1", .fixable("Wrong plan"), work: .fixEverything) { $0.declined.tuning = true } == .skipped)
    }

    @Test("A page summary counts pending, skipped and unread items separately from verified ones")
    func summary() {
        var facts = JourneyFixtures.facts
        facts.pending.cpuCores = 6
        facts.rows["G1"] = JourneyFixtures.row("G1", .fixable("Wrong plan"))
        facts.answers.leftAlone.insert("G1")
        facts.rows["G3"] = JourneyFixtures.row("G3", .fixable("Service running"))
        facts.rows["G10"] = JourneyFixtures.row("G10", .info("Driver versions"))
        facts.rows.removeValue(forKey: "G4")
        let counts = SetupTuneStatus.counts(facts)
        #expect(counts.values.reduce(0, +) == SetupFlow.checks(in: .tune).count)
        #expect(counts[.pendingRestart] == 1 && counts[.skipped] == 1 && counts[.needsAttention] == 1)
        #expect(counts[.notChecked] == 1)
        let text = SetupCopy.Tune.summary(counts)
        #expect(text.contains("1 pending restart") && text.contains("1 skipped") && text.contains("1 not checked"))
        #expect(SetupCopy.Tune.summary([.verified: 4]) == "4 verified")
        #expect(SetupCopy.Tune.summary([.needsAttention: 2]) == "2 need attention")
    }

    @Test("Results have distinct words and symbols, with no reliance on colour")
    func labels() {
        #expect(Set(SetupTuneStatus.allCases.map(SetupCopy.Tune.status)).count == SetupTuneStatus.allCases.count)
        #expect(Set(SetupTuneStatus.allCases.map(\.symbol)).count == SetupTuneStatus.allCases.count)
        #expect(SetupCopy.Tune.status(.verified) == "Verified")
        #expect(SetupCopy.Tune.body.contains("current setting"))
    }
}

@MainActor @Suite("Tuning feedback, drawn without touching a VM")
struct SetupTuneStatusSnapshots {
    @Test("The real Tune page renders the result word, not only a model value")
    func resultIsVisible() throws {
        let cases: [(String, Status, SetupTuneStatus)] = [
            ("G1", .ok("Balanced, tuned"), .verified),
            ("G1", .fixable("Wrong power plan"), .needsAttention),
            ("G1", .fixable("Wrong power plan"), .skipped),
            ("H3", .fixable("4 vCPUs; recommended: 6"), .pendingRestart),
        ]
        for (id, status, expected) in cases {
            var facts = JourneyFixtures.facts
            facts.rows = [id: JourneyFixtures.row(id, status)]
            if expected == .skipped { facts.answers.leftAlone.insert(id) }
            if expected == .pendingRestart { facts.pending.cpuCores = 6 }
            var state = SetupFixtures.state(.tune, facts: facts)
            state.answers = facts.answers
            let png = try #require(Snapshot.png(SetupScreen(state: state, art: nil, send: { _ in }),
                                               size: CGSize(width: 600, height: 800), appearance: .light))
            // Local OCR of our invented fixture, not screen capture or a live app query. This
            // catches removing the label call site while all of the model tests still pass.
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]
            try VNImageRequestHandler(data: png).perform([request])
            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            // OCR can read the adjacent icon as a letter (the warning triangle as A). Allow
            // one small icon token, but not a sentence or the page's count summary.
            let pattern = "^(?:\\S{1,2}\\s+)?" + NSRegularExpression.escapedPattern(for: SetupCopy.Tune.status(expected)) + "\\W*$"
            #expect(lines.contains { $0.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil },
                    "No visible result label for \(expected): \(lines)")
        }
    }

    @Test("Completed and mixed results stay visible in every supported appearance")
    func pages() throws {
        var mixed = JourneyFixtures.facts
        mixed.pending.cpuCores = 6
        mixed.rows["H3"] = JourneyFixtures.row("H3", .fixable("4 vCPUs; recommended: 6"))
        mixed.rows["H6"] = JourneyFixtures.row("H6", .manual("Not excluded from Time Machine", how: "Allow Full Disk Access, then try again."))
        mixed.rows["G1"] = JourneyFixtures.row("G1", .ok("Balanced, tuned"))
        mixed.rows["G2"] = JourneyFixtures.row("G2", .fixable("Power button still sleeps"))
        mixed.answers.leftAlone.insert("G2")
        mixed.rows["G3"] = JourneyFixtures.row("G3", .error("Windows did not answer"))
        mixed.rows["G4"] = JourneyFixtures.row("G4", .ok("Reduced"))
        mixed.rows["G10"] = JourneyFixtures.row("G10", .info("UTM Guest Tools installed"))
        for appearance in Snapshot.Appearance.allCases {
            for (name, facts) in [("verified", JourneyFixtures.facts), ("mixed", mixed)] {
                var state = SetupFixtures.state(.tune, facts: facts)
                state.answers = facts.answers
                let view = SetupScreen(state: state, art: nil, send: { _ in })
                let png = try #require(Snapshot.png(view, size: CGSize(width: 600, height: 620), appearance: appearance))
                try Snapshot.record(png, as: "tune-status-\(name)-\(appearance.rawValue)")
                let full = try #require(Snapshot.png(view, size: CGSize(width: 600, height: 3400), scale: 1, appearance: appearance))
                try Snapshot.record(full, as: "tune-status-full-\(name)-\(appearance.rawValue)")
            }
            let labels = SetupCard {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(SetupTuneStatus.allCases, id: \.self) { SetupTuneStatusLabel(status: $0) }
                }
            }.padding(20)
            let png = try #require(Snapshot.png(labels, size: CGSize(width: 360, height: 400), appearance: appearance))
            try Snapshot.record(png, as: "tune-status-labels-\(appearance.rawValue)")
        }
    }
}
