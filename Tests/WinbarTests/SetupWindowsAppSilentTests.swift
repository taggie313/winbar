import AppKit
import SwiftUI
import Testing
@testable import Winbar

// Windows App's command line not answering, said as what it is. Live, Windows App 11.4.2's `--script
// bookmark list` hung three times out of three; Winbar's read gate stopped asking after ten seconds, as
// designed, and the Saved PC card then said "Winbar couldn't save the PC" with the reason in the
// terminal's words under a fold. Now it says Windows App's command line isn't responding on this Mac,
// that it's Windows App's problem, what that costs, and how to save the PC by hand, with **Open
// Windows App**, **I've Saved the PC** and **Try Again**, and Continue to Connect in the corner.
// Invented fixtures; nothing reaches Windows App or runs its command line.

@MainActor @Suite("Windows App's command line isn't responding")
struct SetupWindowsAppSilentTests {
    private func state(_ c2: Status, running: Bool = false) -> SetupWindowState {
        var facts = JourneyFixtures.facts
        facts.rows["C2"] = JourneyFixtures.row("C2", c2)
        facts.windowsAppRunning = running
        return SetupFixtures.state(.savedPC, facts: facts)
    }

    private static let timedOut: Status = .manual(
        "couldn't ask Windows App whether there's one for winlab02.local ("
            + WindowsAppBookmarks.Failure.failed(what: "list its saved PCs", output: WindowsAppBookmarks.Copy.didNotAnswer).description
            + ")",
        how: WindowsAppBookmarks.Copy.byHand(host: "winlab02.local", user: "Bruno"))

    @Test("A paused or timed-out read is the command line not answering; any other failure isn't")
    func recognised() throws {
        #expect(WindowsAppBookmarks.Copy.saysNoAnswer(WindowsAppBookmarks.Copy.readsPaused))
        #expect(WindowsAppBookmarks.Copy.saysNoAnswer(WindowsAppBookmarks.Copy.didNotAnswer))
        #expect(!WindowsAppBookmarks.Copy.saysNoAnswer("Windows App couldn't list its saved PCs: failed to export bookmark"))
        #expect(SetupFlow.commandLineSilent(try #require(state(SilentFixtures.status).facts)))
        #expect(SetupFlow.commandLineSilent(try #require(state(Self.timedOut).facts)))
        // Not answering is manual; another account's PC with Windows App open, or none saved, is not this.
        let other = Recipe.savedPCStatus(.init(mine: nil, otherAccount: .init(bookmark: .init(name: "winlab02.local", id: "B-1"),
                                                                                 user: "rosa")),
                                         host: "winlab02.local", user: "Bruno", windowsAppRunning: true)
        #expect(!SetupFlow.commandLineSilent(try #require(state(other).facts)))
        #expect(!SetupFlow.commandLineSilent(try #require(state(.fixable("none for winlab02.local")).facts)))
        // A read failure the gate didn't cause keeps the card it had.
        let refused: Status = .manual("couldn't ask Windows App whether there's one for winlab02.local (Windows App "
                                          + "couldn't list its saved PCs: failed to export bookmark)", how: "by hand")
        #expect(!SetupFlow.commandLineSilent(try #require(state(refused).facts)))
    }

    /// Quitting Windows App can't bring its command line back, and the card's Open Windows App opens it:
    /// the page mustn't turn into "quit Windows App first" the moment it does. Control: drop
    /// `!commandLineSilent(facts)` in `SetupFlow.savedPC` and this reads `.windowsAppOpen`.
    @Test("With Windows App open, a silent command line still shows its own card, not Quit Windows App")
    func openApp() throws {
        guard case .manual = SetupFlow.savedPC(try #require(state(SilentFixtures.status, running: true).facts)) else {
            Issue.record("\(SetupFlow.savedPC(state(SilentFixtures.status, running: true).facts!))")
            return
        }
        // A PC Winbar could save, with Windows App open, still asks for the quit.
        #expect(SetupFlow.savedPC(try #require(state(.fixable("none"), running: true).facts)) == .windowsAppOpen(host: "winlab02.local"))
    }

    @Test("The corner is Continue to Connect, and the card has its own retry, so no second Check Again")
    func footer() {
        let silent = state(SilentFixtures.status)
        #expect(SetupFooter.footer(silent).corner?.press == .send(.continueWithoutSavedPC))
        #expect(!SetupJourneyActions.footerChecksAgain(silent))
        #expect(!SetupJourneyActions.rechecksOnReturn(silent), "a read can't learn more; I've Saved the PC is the word")
    }

    @Test("Drawn: what happened, whose problem it is, how to save it by hand, and the three buttons")
    func drawn() throws {
        let png = try #require(Snapshot.png(SetupScreen(state: state(SilentFixtures.status), art: nil, send: { _ in }),
                                            size: CGSize(width: 600, height: 900), appearance: .light))
        try Snapshot.record(png, as: "saved-command-line-silent-light")
        let lines = try Drawing.lines(png).map(\.text)
        let words = lines.joined(separator: " ")
        #expect(lines.contains { $0.contains(SetupCopy.SavedPC.silentTitle) }, "\(lines)")
        #expect(words.contains("problem in Windows App"), "\(words)")
        #expect(words.contains("Add PC"), "the steps to save it by hand: \(words)")
        #expect(words.contains("edit that one instead"), "\(words)")
        for button in [SetupCopy.SavedPC.bOpenWindowsApp, SetupCopy.SavedPC.bSavedItMyself, SetupCopy.bTryAgain] {
            #expect(lines.contains { $0 == button || $0.replacingOccurrences(of: "’", with: "'") == button }, "\(button) in \(lines)")
        }
        #expect(!lines.contains { $0.contains(SetupCopy.SavedPC.manualTitle) }, "the old heading: \(lines)")
        // Any other read failure keeps the manual card.
        let other = try #require(Snapshot.png(SetupScreen(state: state(.manual("Windows App didn't say", how: "by hand")), art: nil,
                                                          send: { _ in }),
                                              size: CGSize(width: 600, height: 900), appearance: .light))
        #expect(try Drawing.lines(other).contains { $0.text.contains(SetupCopy.SavedPC.manualTitle) })
    }

    @Test("Try Again lets Windows App's command line be asked once more, then reads the step")
    func tryAgain() async {
        let machine = RevisitMachine()
        machine.c2 = SilentFixtures.status
        var retries = 0
        let controller = RevisitHarness.controller(machine, state: RevisitHarness.state(.savedPC, skipped: []),
                                                   retries: { retries += 1 })
        controller.attach()
        controller.send(.retrySavedPC)
        #expect(retries == 1)
        await RevisitHarness.settle(controller) {
            controller.state.lastEnding?.work == .checkAgain(.savedPC) && controller.state.inFlight == nil
        }
        #expect(machine.done == [.checkAgain(.savedPC)])
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
    }

    @Test("The card's words say only what is known, in the deck's voice")
    func copy() {
        let edit = String(SetupCopy.SavedPC.editInstead(host: "winlab02.local", user: "Bruno").characters)
        #expect(edit == "If Windows App already has a PC called winlab02.local, edit that one instead of adding another, so it signs in as Bruno.")
        #expect(String(SetupCopy.SavedPC.editInstead(host: "winlab02.local", user: nil).characters).hasSuffix("instead of adding another."))
        let next = String(SetupCopy.markdown(SetupCopy.SavedPC.silentNext).characters)
        #expect(next.contains(SetupCopy.SavedPC.bSavedItMyself) && next.contains(SetupCopy.SavedPC.bContinueToSignIn))
    }
}
