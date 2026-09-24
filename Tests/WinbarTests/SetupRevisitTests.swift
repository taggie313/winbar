import AppKit
import SwiftUI
import Testing
@testable import Winbar

// Nothing skipped is a dead end. Live, Windows App's command line never answered the saved-PC read,
// the person chose to go on, and the step then said "Saved PC skipped" with nothing on it to press,
// though a second try might have answered; a skipped certificate with nothing to approve at that
// moment was the same. Every Skip on a step now has a way back (`SetupCommand.revisit`), which takes
// the Skip back, asks again and reads the step. Invented fixtures and a fake machine: nothing reaches
// the Mac's settings, UTM, Windows App or a VM.

/// A Mac whose certificate and saved PC read as the test says, remembering what it was asked to do.
final class RevisitMachine: SetupMachine {
    var h7: Status = .ok("Trusted")
    var c2: Status = .ok("Saved")
    var windowsApp: DependencyState = .installed(version: "11.4")
    /// Whose saved-PC tile the last Connect pressed, as the live machine reports it.
    var pressed: String?
    private let lock = NSLock()
    private var _done: [SetupRunner.Work] = []
    /// What it was asked to do, in order. Locked: the runner's queue adds while a test reads.
    var done: [SetupRunner.Work] { lock.withLock { _done } }
    private var holding = false
    private let gate = DispatchSemaphore(value: 0)

    /// The next read waits, until `release()`: a read still running when the test presses.
    func hold() { lock.withLock { holding = true } }
    func release() {
        lock.withLock { holding = false }
        gate.signal()
    }

    func readings(through step: WizardStep, answers: SetupFlow.Answers, after work: SetupRunner.Work?,
                  job: SetupRunner.Job?) -> SetupRunner.Readings {
        if lock.withLock({ holding }) { _ = gate.wait(timeout: .now() + 10) }
        var read = SetupRunner.Readings()
        read.utm = SetupFixtures.installed
        read.utmAnswers = .answered
        read.windowsApp = windowsApp
        read.vms = .success([SetupVMTests.old, SetupVMTests.new])
        read.chosenVM = SetupVMTests.new.name
        read.guestAnswers = true
        read.rdpHost = "winlab02.local"
        read.rdpUser = "Bruno"
        read.otherVMs = .success([])
        read.savedPCPressed = pressed
        for id in WizardStep.allCases.filter({ $0 <= step }).flatMap(SetupFlow.checks(in:)) { read.statuses[id] = .ok("Ready") }
        if step >= .certificate { read.statuses["H7"] = h7 }
        if step >= .savedPC { read.statuses["C2"] = c2 }
        if step >= .finish { read.statuses["H5"] = .fixable("Console on") }
        return read
    }

    func perform(_ work: SetupRunner.Work, password: String?, facts: SetupFlow.Facts, job: SetupRunner.Job) throws {
        lock.withLock { _done.append(work) }
    }
}

/// The C2 row a saved-PC read leaves when Windows App's command line didn't answer (`Recipe`'s own
/// words around `WindowsAppBookmarks.Copy.readsPaused`).
enum SilentFixtures {
    static let host = "winlab02.local"
    static let detail = "couldn't ask Windows App whether there's one for \(host) ("
        + WindowsAppBookmarks.Failure.failed(what: "list its saved PCs", output: WindowsAppBookmarks.Copy.readsPaused).description + ")"
    static var status: Status { .manual(detail, how: WindowsAppBookmarks.Copy.byHand(host: host, user: "Bruno")) }
}

@MainActor enum RevisitHarness {
    static func controller(_ machine: RevisitMachine, state: SetupWindowState, retries: @escaping () -> Void = {},
                           remember: @escaping (Bool, SetupFlow.Facts) -> Void = { _, _ in }) -> SetupWindowController {
        let runner = SetupRunner(machine: machine, environment: .init(
            queue: DispatchQueue(label: "winbar.test.revisit"), callbacks: .main, clock: Date.init,
            keepAwake: { _ in {} }, processes: { _ in ([100], 101) }, workspace: NotificationCenter()))
        return SetupWindowController(state: state, art: nil,
            settings: .init(wizardShown: { false }, markShown: {}, armieHidden: { true }, hideArmie: {},
                            rememberConnect: remember),
            makeRunner: { runner }, makeCreator: { FakeEmbeddedCreate() }, retryWindowsAppReads: retries)
    }

    static func settle(_ controller: SetupWindowController, until done: () -> Bool) async {
        for _ in 0..<400 {
            if done() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// The saved PC step, skipped after the read `c2` said, or the whole wizard finished with it so.
    static func state(_ step: WizardStep, c2: Status = SilentFixtures.status, skipped: Set<String> = ["C2"],
                      finished: Bool = false) -> SetupWindowState {
        var facts = JourneyFixtures.facts
        facts.rows["C2"] = JourneyFixtures.row("C2", c2)
        var state = SetupFixtures.state(step, facts: facts)
        state.answers.leftAlone = skipped
        state.finished = finished
        state.facts?.answers = state.answers
        return state
    }
}

@MainActor @Suite("Nothing skipped is a dead end")
struct SetupRevisitTests {
    @Test("Which Skips a step's way back takes back")
    func skips() {
        #expect(SetupFlow.skips(in: .savedPC) == ["C1", "C2"])
        #expect(SetupFlow.skips(in: .certificate) == ["H7"])
        for step in WizardStep.allCases where step != .savedPC && step != .certificate {
            #expect(SetupFlow.skips(in: step).isEmpty, "\(step)")
        }
    }

    /// Control: drop the `subtract` in `send(.revisit)` and the step stays skipped; drop the reset and
    /// `retries` stays 0.
    @Test("Try Saving Again takes the Skip back, lets Windows App be asked again, and reads the step")
    func trySavingAgain() async throws {
        let machine = RevisitMachine()
        machine.c2 = SilentFixtures.status
        var retries = 0
        let state = RevisitHarness.state(.savedPC)
        #expect(SetupFlow.savedPC(try #require(state.facts)) == .skipped)
        let controller = RevisitHarness.controller(machine, state: state, retries: { retries += 1 })
        controller.attach()
        controller.send(.revisit(.savedPC))
        #expect(controller.state.answers.leftAlone.isDisjoint(with: ["C1", "C2"]))
        #expect(retries == 1)
        await RevisitHarness.settle(controller) {
            controller.state.lastEnding?.work == .checkAgain(.savedPC) && controller.state.inFlight == nil
        }
        #expect(machine.done == [.checkAgain(.savedPC)])
        #expect(controller.state.step == .savedPC)
        guard case .manual? = controller.state.facts.map(SetupFlow.savedPC) else {
            Issue.record("still \(String(describing: controller.state.facts.map(SetupFlow.savedPC)))")
            return
        }
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
    }

    @Test("A skipped Windows App is taken back too, and the step offers its install")
    func windowsAppSkipped() async throws {
        let machine = RevisitMachine()
        machine.windowsApp = .missing
        machine.c2 = .info("needs Windows App (C1)")
        var state = RevisitHarness.state(.savedPC, c2: .info("needs Windows App (C1)"), skipped: ["C1"])
        state.facts?.windowsApp = .missing
        #expect(SetupFlow.savedPC(try #require(state.facts)) == .skipped)
        let controller = RevisitHarness.controller(machine, state: state)
        controller.attach()
        controller.send(.revisit(.savedPC))
        await RevisitHarness.settle(controller) {
            controller.state.lastEnding?.work == .checkAgain(.savedPC) && controller.state.inFlight == nil
        }
        #expect(controller.state.facts.map(SetupFlow.savedPC) == .needsWindowsApp(.missing))
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
    }

    /// A skipped certificate with nothing to approve (the VM stopped, say) had only Continue Without
    /// Approval. With something to approve, Approve Instead… was already the way back.
    @Test("A skipped certificate with nothing to approve offers Check the Certificate Again, which takes the Skip back")
    func certificate() async throws {
        var stopped = CertificateFixtures.state("skipped")
        stopped.facts?.vmRunning = false
        let page = CertificateFixtures.page(stopped)
        #expect(page.phase == .skipped && !page.canApprove && page.revisits)
        #expect(!CertificateFixtures.page(CertificateFixtures.state("skipped")).revisits, "Approve Instead… is the way back there")
        #expect(SetupCopy.Certificate.next(page) == SetupCopy.Certificate.skippedNoApproval)
        #expect(String(SetupCopy.markdown(SetupCopy.Certificate.skippedNoApproval).characters)
                    .contains(SetupCopy.Certificate.bCheckAgainInstead))

        let machine = RevisitMachine()
        machine.h7 = .fixable("Not trusted")
        let controller = RevisitHarness.controller(machine, state: stopped)
        controller.attach()
        controller.send(.revisit(.certificate))
        #expect(!controller.state.answers.leftAlone.contains("H7"))
        await RevisitHarness.settle(controller) {
            controller.state.lastEnding?.work == .checkAgain(.certificate) && controller.state.inFlight == nil
        }
        let after = CertificateFixtures.page(controller.state)
        #expect(after.phase != .skipped, "\(after.phase)")
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
    }

    /// Changed on purpose when the two branches met: "never while work runs" had a read in flight as
    /// its work. A Skip taken back is an answer, as the Skip is, and like Skip and Back it is given
    /// while only a read runs (`SetupFooter.backable`); `whileAReadRuns` holds that. Work that acts
    /// (here, Save It) still keeps it.
    @Test("The way back goes only back, only where there is a Skip, and never while work runs")
    func guards() {
        let machine = RevisitMachine()
        // Ahead of the step the window is on.
        let early = RevisitHarness.controller(machine, state: RevisitHarness.state(.certificate, skipped: ["C2"]))
        early.attach()
        early.send(.revisit(.savedPC))
        #expect(early.state.step == .certificate && early.state.answers.leftAlone == ["C2"])
        // A step with no Skip of its own.
        let connect = RevisitHarness.controller(machine, state: RevisitHarness.state(.finish, finished: true))
        connect.attach()
        connect.send(.revisit(.connect))
        #expect(connect.state.finished && connect.state.step == .finish)
        // Work in flight.
        var busyState = RevisitHarness.state(.savedPC)
        busyState.inFlight = SetupFixtures.flight(.savePC)
        let busy = RevisitHarness.controller(machine, state: busyState)
        busy.send(.revisit(.savedPC))
        #expect(busy.state.answers.leftAlone == ["C2"])
        #expect(machine.done.isEmpty)
        for controller in [early, connect, busy] {
            controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        }
    }

    /// A's rules for a read the window takes by itself hold for B's way back. The Skip is taken back at
    /// once, while a read somebody pressed still runs, and the step's own read is owed, not refused: no
    /// banner about a press nobody made, and the read comes once the running one ends, with Windows
    /// App's command line allowed to be asked again. Controls: B's own guard (nothing in flight) drops
    /// the press without a word, and B's `run(.checkAgain(step))` puts up a refusal and reads once.
    @Test("Taken back while a read runs: at once, with no banner, and the step is read once that read ends")
    func whileAReadRuns() async throws {
        let machine = RevisitMachine()
        machine.c2 = SilentFixtures.status
        var retries = 0
        let controller = RevisitHarness.controller(machine, state: RevisitHarness.state(.savedPC), retries: { retries += 1 })
        controller.attach()
        machine.hold()
        controller.send(.perform(.run(.checkAgain(.savedPC))))
        await RevisitHarness.settle(controller) { controller.state.inFlight != nil }
        #expect(controller.state.inFlight?.work == .checkAgain(.savedPC))
        controller.send(.revisit(.savedPC))
        #expect(controller.state.answers.leftAlone.isDisjoint(with: ["C1", "C2"]), "taken back at once")
        #expect(retries == 1)
        #expect(controller.state.refusal == nil)
        machine.release()
        await RevisitHarness.settle(controller) { machine.done.count == 2 && controller.state.inFlight == nil }
        #expect(machine.done == [.checkAgain(.savedPC), .checkAgain(.savedPC)], "the owed read, after the pressed one")
        #expect(controller.state.refusal == nil)
        #expect(controller.state.step == .savedPC)
        guard case .manual? = controller.state.facts.map(SetupFlow.savedPC) else {
            Issue.record("still \(String(describing: controller.state.facts.map(SetupFlow.savedPC)))")
            return
        }
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
    }

    // MARK: Drawn

    private func words(_ state: SetupWindowState) throws -> [String] {
        let png = try #require(Snapshot.png(SetupScreen(state: state, art: nil, send: { _ in }),
                                            size: setupWindowSize, appearance: .light))
        return try Drawing.lines(png).map(\.text)
    }

    @Test("The skipped pages draw their way back, and Continue stays the corner")
    func drawn() throws {
        let skipped = RevisitHarness.state(.savedPC)
        let lines = try words(skipped)
        // The button is a line of its own; the sentence above it names it too.
        #expect(lines.contains { $0 == SetupCopy.SavedPC.bTrySavingAgain }, "\(lines)")
        #expect(SetupFooter.footer(skipped).corner?.press == .send(.next))

        var noApp = RevisitHarness.state(.savedPC, c2: .info("needs Windows App (C1)"), skipped: ["C1"])
        noApp.facts?.windowsApp = .missing
        let noAppLines = try words(noApp)
        #expect(noAppLines.contains { $0.contains(SetupCopy.SavedPC.windowsAppSkippedTitle) }, "\(noAppLines)")

        var stopped = CertificateFixtures.state("skipped")
        stopped.facts?.vmRunning = false
        let certificate = try words(stopped)
        #expect(certificate.contains { $0 == SetupCopy.Certificate.bCheckAgainInstead }, "\(certificate)")
    }

    /// A read nobody pressed keeps the saved PC's card up (fix/refocus: its password field keeps its
    /// text), so the step's card is no longer disabled as a whole during one; each row of the card's
    /// buttons is greyed by itself. The silent card's and the skipped card's rows, from
    /// feat/finish-polish, follow: drawn, titled, greyed, where a press would only be refused. Measured
    /// from the pixels, as Stop Waiting's is. The control is either row without its `.disabled`: its
    /// title reads at full strength during the read.
    @Test("Through a read nobody pressed, the silent and skipped cards stay, their buttons greyed",
          arguments: ["silent", "skipped"])
    func greyedThroughALook(card: String) throws {
        let (state, title, button) = card == "silent"
            ? (RevisitHarness.state(.savedPC, skipped: []), SetupCopy.SavedPC.silentTitle, SetupCopy.bTryAgain)
            : (RevisitHarness.state(.savedPC), SetupCopy.SavedPC.skippedTitle, SetupCopy.SavedPC.bTrySavingAgain)
        func contrast(_ state: SetupWindowState) throws -> Double {
            let png = try #require(Snapshot.png(SetupScreen(state: state, art: nil, send: { _ in }),
                                                size: setupWindowSize, appearance: .light))
            let lines = try Drawing.lines(png)
            #expect(lines.contains { $0.text.contains(title) }, "\(card): the card stays, \(lines)")
            let line = try #require(lines.first { $0.text == button }, "\(card): \(lines)")
            return try #require(Drawing.inkContrast(png, in: line.frame.insetBy(dx: -2, dy: -2)))
        }
        let looking = state.applying(.refreshing(SetupFixtures.flight(.lookAgain(.savedPC, forgetting: .statuses))))
        #expect(looking.refreshing)
        #expect(try contrast(state) >= 3, "\(card): pressable when nothing runs")
        #expect(try contrast(looking) < 3, "\(card): greyed through the look")
    }
}
