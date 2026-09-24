import AppKit
import SwiftUI
import Testing
@testable import Winbar

// The finished page lists what was passed over: under the result, one quiet section with each flagged
// step's ⚠, its name, what happened and why in the step bar's own hover words, and the one button that
// goes back to do it. The owner found an orange ⚠ on this page with nothing to say what it was.
// Invented fixtures; nothing reaches the Mac's settings, UTM, Windows App or a VM.

enum PassedOverFixtures {
    /// Finished, the desktop confirmed, with the certificate skipped (nothing approved) and the saved PC
    /// skipped because Windows App's command line never answered.
    static var skipped: SetupWindowState {
        var state = FinishFixtures.ready
        state.answers.leftAlone.formUnion(["H7", "C2"])
        state.facts?.rows["H7"] = JourneyFixtures.row("H7", .fixable("Not trusted"))
        state.facts?.rows["C2"] = JourneyFixtures.row("C2", SilentFixtures.status)
        state.facts?.answers = state.answers
        return state
    }

    /// Finished with the desktop never appearing and nothing skipped.
    static var notConnected: SetupWindowState { FinishFixtures.almost }
}

@MainActor @Suite("The finished page lists what was passed over")
struct SetupFinishPassedOverTests {
    @Test("Each flagged step, in the bar's order, with the hover's words and its way back")
    func rows() throws {
        let state = PassedOverFixtures.skipped
        let rows = SetupFinishPage.passedOver(state)
        #expect(rows.map(\.step) == [.certificate, .savedPC])
        let facts = try #require(state.facts)
        for row in rows {
            #expect(row.words == SetupCopy.passedOver(row.step, facts))
            // The same words as the segment's hover, after its step's name.
            let hover = StepBar.hovers(current: .finish, finished: true, flagged: StepBar.flagged(state),
                                       passedOver: StepBar.passedOver(state))[WizardStep.allCases.firstIndex(of: row.step)!]
            #expect(hover == SetupCopy.stepName(row.step) + ": " + row.words)
        }
        #expect(rows[0].back == .init(title: "Go Back to Certificate", command: .revisit(.certificate)))
        #expect(rows[1].back == .init(title: "Go Back to Saved PC", command: .revisit(.savedPC)))
        #expect(SetupCopy.Finish.passedOverLine(rows[1].words)
                == "Skipped — Windows App's command line didn't respond, so Winbar couldn't save it.")
    }

    /// Connect's way back is the footer's corner; a second button for the same press would be too many.
    @Test("Connect is listed with no button of its own: the corner is its way back")
    func connect() {
        let rows = SetupFinishPage.passedOver(PassedOverFixtures.notConnected)
        #expect(rows == [.init(step: .connect, words: "you said the Windows desktop didn't appear", back: nil)])
        #expect(SetupFooter.footer(PassedOverFixtures.notConnected).corner?.press == .send(.connectAgain))
    }

    /// Windows App skipped, then installed: the footer's corner is **Go Back to Saved PC** (from
    /// fix/refocus), and the list flags the saved PC with the same way back (from feat/finish-polish).
    /// One press, one button: the row keeps its words and loses its button, as Connect's does. The
    /// control is the list without the footer check: two "Go Back to Saved PC" on one page.
    @Test("Once the corner is Go Back to Saved PC, the saved PC's row has no button of its own")
    func cornerIsTheWayBack() throws {
        let state = FinishFixtures.finished(connected: nil) {
            $0.answers.leftAlone.insert("C1")
            $0.facts?.rows["C2"] = JourneyFixtures.row("C2", .fixable("No saved PC"))
        }
        #expect(SetupCopy.Finish.outcome(try #require(state.facts)) == .notTried)
        #expect(SetupFooter.footer(state).corner?.press == .send(.revisit(.savedPC)))
        let rows = SetupFinishPage.passedOver(state)
        let savedPC = try #require(rows.first { $0.step == .savedPC }, "\(rows)")
        #expect(savedPC.back == nil)
        #expect(!savedPC.words.isEmpty)
        // The certificate, skipped too, keeps its own: the footer has no way back to it.
        var both = state
        both.answers.leftAlone.insert("H7")
        both.facts?.rows["H7"] = JourneyFixtures.row("H7", .fixable("Not trusted"))
        both.facts?.answers = both.answers
        #expect(SetupFinishPage.passedOver(both).first { $0.step == .certificate }?.back?.command == .revisit(.certificate))
    }

    @Test("Nothing passed over, or not finished yet: no section")
    func none() {
        #expect(SetupFinishPage.passedOver(FinishFixtures.ready).isEmpty)
        var unfinished = PassedOverFixtures.skipped
        unfinished.finished = false
        #expect(SetupFinishPage.passedOver(unfinished).isEmpty)
    }

    private func render(_ state: SetupWindowState, _ appearance: Snapshot.Appearance = .light) throws -> Data {
        try #require(Snapshot.png(SetupScreen(state: state, art: nil, send: { _ in }),
                                  size: CGSize(width: 600, height: 900), appearance: appearance))
    }

    /// Control: drop `FinishPassedOver` from `FinishArrival` and the heading and buttons aren't drawn.
    @Test("Drawn: the heading, each step's name and words, and the buttons; none when nothing was passed over")
    func drawn() throws {
        let png = try render(PassedOverFixtures.skipped)
        try Snapshot.record(png, as: "finish-passed-over-light")
        let lines = try Drawing.lines(png)
        let words = lines.map(\.text).joined(separator: " ")
        let heading = try #require(Drawing.find(SetupCopy.Finish.passedOverHeading, in: lines), "\(lines)")
        let result = try #require(Drawing.find(SetupCopy.Finish.readyHeading, in: lines), "\(lines)")
        #expect(heading.frame.minY > result.frame.maxY, "the section is below the result")
        for button in ["Go Back to Certificate", "Go Back to Saved PC"] {
            #expect(lines.contains { $0.text == button }, "\(button) in \(lines)")
        }
        #expect(words.contains("command line didn't respond"), "\(words)")
        let plain = try Drawing.lines(try render(FinishFixtures.ready)).map(\.text)
        #expect(!plain.contains { $0.contains(SetupCopy.Finish.passedOverHeading) }, "\(plain)")
        try Snapshot.record(try render(PassedOverFixtures.skipped, .dark), as: "finish-passed-over-dark")
    }

    /// The button leaves the finished page for the step, with its Skip taken back and Windows App's
    /// command line allowed to be asked again.
    @Test("Go Back to Saved PC leaves the finished page for the step, un-skipped, and reads it")
    func goBack() async {
        let machine = RevisitMachine()
        machine.c2 = SilentFixtures.status
        var retries = 0
        var state = RevisitHarness.state(.finish, finished: true)
        state.answers.connected = true
        state.answers.connectionOpened = true
        state.facts?.answers = state.answers
        let back = SetupFinishPage.passedOver(state).first { $0.step == .savedPC }?.back
        #expect(back?.command == .revisit(.savedPC))
        let controller = RevisitHarness.controller(machine, state: state, retries: { retries += 1 })
        controller.attach()
        if let back { controller.send(back.command) }
        #expect(!controller.state.finished && controller.state.step == .savedPC)
        #expect(!controller.state.answers.leftAlone.contains("C2") && retries == 1)
        await RevisitHarness.settle(controller) {
            controller.state.lastEnding?.work == .checkAgain(.savedPC) && controller.state.inFlight == nil
        }
        #expect(controller.state.step == .savedPC && machine.done == [.checkAgain(.savedPC)])
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
    }
}
