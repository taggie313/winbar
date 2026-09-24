import AppKit
import SwiftUI
import Testing
@testable import Winbar

// Step 7, Finish: the background choice as two tiles with the footer committing it, the restart said
// in the window's words, and the finished page as an arrival with the next thing in the corner. Every
// state here is an invented fixture; nothing reaches the Mac's settings, UTM, Windows App or a VM.

enum FinishFixtures {
    /// The facts once Connect was answered: `connected` is the answer.
    static func facts(connected: Bool? = true) -> SetupFlow.Facts {
        var facts = JourneyFixtures.facts
        facts.rows["H5"] = JourneyFixtures.row("H5", .fixable("Console on"))
        facts.answers.connected = connected
        facts.answers.connectionOpened = connected != nil
        return facts
    }

    static func state(connected: Bool? = true, _ change: (inout SetupWindowState) -> Void = { _ in }) -> SetupWindowState {
        let facts = facts(connected: connected)
        var state = SetupFixtures.state(.finish, facts: facts)
        state.answers = facts.answers
        change(&state)
        state.facts?.answers = state.answers
        return state
    }

    /// The choice offered, nothing pressed: the recommended tile shows chosen.
    static var choosing: SetupWindowState { state() }
    /// **Keep Windows' Screen** pressed.
    static var kept: SetupWindowState { state { $0.answers.leftAlone.insert("H5") } }
    /// Processor cores staged on Tune and the background staged here.
    static var staged: SetupWindowState { state { $0.facts?.pending = ConfigChanges(cpuCores: 6, display: .headless) } }
    /// Already in the background; only Tune's memory is owed.
    static var tuneOnly: SetupWindowState {
        state {
            $0.facts?.rows["H5"] = JourneyFixtures.row("H5", .ok("Headless"))
            $0.facts?.pending = ConfigChanges(memoryMB: 12288)
        }
    }
    /// A restart that was tried and stopped.
    static var stopped: SetupWindowState {
        var state = staged
        state.lastEnding = SetupRunner.Ending(work: .applyChanges, outcome: .failed(.init(title: "BitLocker couldn't be checked",
                                              detail: "Windows' helper didn't answer, so Winbar didn't restart it.")),
                                              facts: state.facts!, slept: false, started: testMoment(), lines: [])
        return state
    }
    static var others: SetupWindowState { state { $0.facts?.otherVMs = .running(["atelier"]) } }

    static func finished(connected: Bool?, _ change: (inout SetupWindowState) -> Void = { _ in }) -> SetupWindowState {
        state(connected: connected) { state in
            state.finished = true
            state.answers.leftAlone.insert("H5")
            change(&state)
        }
    }
    static var ready: SetupWindowState { finished(connected: true) }
    static var almost: SetupWindowState { finished(connected: false) }
    static var noWindowsApp: SetupWindowState {
        finished(connected: nil) {
            $0.answers.leftAlone.insert("C1")
            $0.facts?.windowsApp = .missing
        }
    }

    static var screens: [(String, SetupWindowState)] {
        [("choosing", choosing), ("kept", kept), ("staged", staged), ("tune-only", tuneOnly), ("stopped", stopped),
         ("others", others), ("ready", ready), ("almost", almost), ("no-windows-app", noWindowsApp)]
    }
}

@MainActor @Suite("Finish: a choice with a default, a restart in plain words, and an arrival")
struct SetupFinishPageTests {
    private func titles(_ buttons: [SetupFooter.Button]) -> [String] { buttons.map(\.title) }

    // MARK: The choice

    @Test("The recommended tile shows chosen until Keep is pressed, and Keep only where undoing it offers again")
    func tiles() throws {
        #expect(SetupFinishPage.choice(try #require(FinishFixtures.choosing.facts)) == .background)
        #expect(SetupFinishPage.choice(try #require(FinishFixtures.staged.facts)) == .background)
        #expect(SetupFinishPage.choice(try #require(FinishFixtures.kept.facts)) == .keepScreen)
        // Keep pressed beside another VM's refusal: undoing it would only refuse again, so no tiles.
        var keptBesideOthers = FinishFixtures.others
        keptBesideOthers.facts?.answers.leftAlone.insert("H5")
        #expect(SetupFinishPage.choice(try #require(keptBesideOthers.facts)) == nil)
        #expect(SetupFinishPage.choice(try #require(FinishFixtures.tuneOnly.facts)) == nil)
        #expect(SetupFinishPage.choice(try #require(FinishFixtures.others.facts)) == nil)
    }

    /// The review: "Headless choice has no default and Done is greyed out". Now the corner always
    /// has something to press, it says what pressing it does, and Return is it.
    @Test("The footer's corner is Restart and Finish while a restart is owed, Finish once none is")
    func footer() throws {
        let choosing = SetupFooter.footer(FinishFixtures.choosing)
        #expect(titles(choosing.leading) == [SetupCopy.bBack])
        #expect(choosing.trailing == [.init(SetupCopy.Finish.bRestartAndFinish, .restartAndFinish, kind: .primary)])
        #expect(choosing.holdsDefault())

        let kept = SetupFooter.footer(FinishFixtures.kept)
        #expect(kept.trailing == [.init(SetupCopy.Finish.bFinish, .finish, kind: .primary)] && kept.holdsDefault())

        // Keep, with Tune's changes still owed: a restart all the same.
        var keptWithCores = FinishFixtures.kept
        keptWithCores.facts?.pending = ConfigChanges(cpuCores: 6)
        #expect(SetupFooter.footer(keptWithCores).corner?.press == .send(.restartAndFinish))
        #expect(SetupFooter.footer(FinishFixtures.tuneOnly).corner?.title == SetupCopy.Finish.bRestartAndFinish)

        // Check Again only where UTM's answer is the news.
        #expect(titles(SetupFooter.footer(FinishFixtures.others).trailing) == [SetupCopy.bCheckAgain, SetupCopy.Finish.bFinish])
        #expect(!titles(SetupFooter.footer(FinishFixtures.staged).trailing).contains(SetupCopy.bCheckAgain))

        // Nothing pressable while work runs.
        var busy = FinishFixtures.choosing
        busy.inFlight = SetupFixtures.flight(.applyChanges)
        #expect(!SetupFooter.footer(busy).holdsDefault())
    }

    @Test("What the restart applies includes the background while it is only chosen")
    func owed() throws {
        #expect(SetupFinishPage.owed(try #require(FinishFixtures.choosing.facts)) == ConfigChanges(display: .headless))
        #expect(SetupFinishPage.owed(try #require(FinishFixtures.kept.facts)).isEmpty)
        #expect(SetupFinishPage.owed(try #require(FinishFixtures.staged.facts)) == ConfigChanges(cpuCores: 6, display: .headless))
    }

    @Test("The page asks its question as its title, and the arrival heads itself")
    func title() {
        #expect(SetupScreen.pageTitle(FinishFixtures.choosing) == SetupCopy.Finish.choiceHeading)
        #expect(SetupScreen.pageTitle(FinishFixtures.kept) == SetupCopy.Finish.choiceHeading)
        #expect(SetupScreen.pageTitle(FinishFixtures.tuneOnly) == SetupCopy.stepName(.finish))
        #expect(SetupScreen.pageTitle(FinishFixtures.ready) == nil)
    }

    /// The caption about BitLocker and a shutdown used to sit under every staged restart, about a case
    /// that hadn't happened. It is said once a restart has stopped, and not before.
    @Test("What's left after a stopped restart is said only after one stopped")
    func stoppedRestart() throws {
        #expect(!SetupFinishPage.restartStopped(FinishFixtures.staged))
        #expect(SetupFinishPage.restartStopped(FinishFixtures.stopped))
        let drawn = try render(FinishFixtures.stopped, .light, height: 900)
        let before = try render(FinishFixtures.staged, .light, height: 900)
        let words = try Drawing.lines(drawn).map(\.text).joined(separator: " ")
        #expect(words.contains("stopped rather than restart"), "\(words)")
        #expect(!(try Drawing.lines(before).map(\.text).joined(separator: " ")).contains("stopped rather than restart"))
    }

    /// `SetupRunner.restartReport` knew a failed restart had spanned a sleep, and nothing said it: the
    /// restart's waits run by the clock, so the failure may be only the sleep. The control is a note
    /// that doesn't ask the report: nil for the slept case.
    @Test("A restart that failed while the Mac slept says so; one that failed awake doesn't")
    func restartSlept() throws {
        func failed(slept: Bool) -> SetupWindowState {
            var state = FinishFixtures.stopped
            let ending = try! #require(state.lastEnding)
            state.lastEnding = SetupRunner.Ending(work: .applyChanges, outcome: ending.outcome, facts: ending.facts,
                                                  slept: slept, started: ending.started)
            return state
        }
        let note = try #require(SetupFinishPage.restartNote(failed(slept: true)))
        #expect(String(note.characters).hasPrefix("The Mac went to sleep while Winbar was restarting “winlab02”"), "\(note)")
        #expect(SetupFinishPage.restartNote(failed(slept: false)) == nil)
        #expect(SetupFinishPage.restartNote(FinishFixtures.choosing) == nil)
    }

    @Test("Drawn, the two tiles show which is chosen")
    func tilesDrawn() throws {
        let background = try render(FinishFixtures.choosing, .light)
        let keep = try render(FinishFixtures.kept, .light)
        #expect((Snapshot.difference(background, keep)?.count ?? 0) > 500)
        let words = try Drawing.lines(background).map(\.text)
        for title in [SetupCopy.Finish.bBackground, SetupCopy.Finish.bKeepScreen, SetupCopy.Finish.recommended] {
            #expect(words.contains { $0.contains(title) }, "\(title) in \(words)")
        }
        // Side by side: the two names on one row.
        let row = try Drawing.lines(background).filter { [SetupCopy.Finish.bBackground, SetupCopy.Finish.bKeepScreen].contains($0.text) }
        #expect(row.count == 2 && abs(row[0].frame.midY - row[1].frame.midY) < 4, "\(row)")
    }

    @Test("Return presses Restart and Finish on the choice and the staged restart")
    func returnRestarts() {
        for state in [FinishFixtures.choosing, FinishFixtures.staged] {
            let sent = Sent()
            #expect(Pressing(SetupScreen(state: state, art: nil, send: sent.send)).press(.return))
            #expect(sent.commands == [.restartAndFinish])
        }
        let sent = Sent()
        #expect(Pressing(SetupScreen(state: FinishFixtures.kept, art: nil, send: sent.send)).press(.return))
        #expect(sent.commands == [.finish])
    }

    // MARK: The arrival

    /// Changed on purpose twice over: with Windows App skipped, **Check Again** now sits beside the App
    /// Store for an install made some other way; once it's here, the corner goes back to the saved PC
    /// step the skip passed over, and **Connect** is beside it (it was the corner, and the saved PC
    /// could then never be set up from here).
    @Test("Finished: no Back, Close for Escape, and the corner opens Windows, tries again, or goes back to the saved PC")
    func arrivalFooter() throws {
        let ready = SetupFooter.footer(FinishFixtures.ready)
        #expect(ready.leading.isEmpty)
        #expect(ready.trailing == [.init(SetupCopy.bClose, .closeForNow, kind: .cancel),
                                   .init(SetupCopy.Finish.bOpenWindows, .openWindows, kind: .primary)])
        let almost = SetupFooter.footer(FinishFixtures.almost)
        #expect(almost.leading.isEmpty && almost.corner == .init(SetupCopy.Finish.bTryConnectingAgain, .connectAgain, kind: .primary))
        // Windows App skipped and installed since: the saved PC was never set up and Connect never
        // tried. The corner goes back to the saved PC step; Connect, named for a first try (nothing
        // has failed to say "again" about), tests it as it is.
        let untried = FinishFixtures.finished(connected: nil) { $0.answers.leftAlone.insert("C1") }
        #expect(SetupCopy.Finish.outcome(try #require(untried.facts)) == .notTried)
        #expect(SetupFooter.footer(untried).trailing == [
            .init(SetupCopy.bClose, .closeForNow, kind: .cancel),
            .init(SetupCopy.Finish.bConnect, .connectAgain),
            .init(SetupCopy.Finish.bGoBackToSavedPC, .revisit(.savedPC), kind: .primary)])
        let words = String(SetupCopy.Finish.doneBody(vm: "winlab02", .notTried)[0].characters)
        #expect(words.contains("Choose Go Back to Saved PC to save") && !words.contains("again") && !words.contains("once more"),
                "\(words)")
        // No Windows App: the page names the fix, and the corner is it, with Check Again beside it for
        // an install made some other way; Close is Escape's.
        let noApp = SetupFooter.footer(FinishFixtures.noWindowsApp)
        #expect(noApp.leading.isEmpty && noApp.trailing == [
            .init(SetupCopy.bClose, .closeForNow, kind: .cancel),
            .init(SetupCopy.bCheckAgain, .perform(.run(.checkAgain(.finish)))),
            .init(SetupCopy.SavedPC.bOpenAppStore, .perform(.run(.installWindowsApp)), kind: .primary)])
    }

    @Test("Drawn, Return opens Windows (tries again, or opens the App Store) and Escape closes")
    func arrivalKeys() {
        for (state, expected) in [(FinishFixtures.ready, SetupCommand.openWindows), (FinishFixtures.almost, .connectAgain),
                                  (FinishFixtures.noWindowsApp, .perform(.run(.installWindowsApp)))] {
            let sent = Sent()
            let window = Pressing(SetupScreen(state: state, art: nil, send: sent.send))
            #expect(window.press(.return))
            #expect(window.press(.escape))
            #expect(sent.commands == [expected, .closeForNow])
        }
    }

    /// Welcome's composition: the mark, the heading and the sentence centred in the page, rather than
    /// a 20 pt heading top-left over 55–60% empty backdrop.
    @Test("The arrival is centred, with its heading at 26 pt and how it went in the mark")
    func arrivalDrawn() throws {
        let png = try render(FinishFixtures.ready, .light)
        let lines = try Drawing.lines(png)
        let heading = try #require(lines.first { $0.text == SetupCopy.Finish.readyHeading }, "\(lines)")
        #expect(abs(heading.frame.midX - 300) < 12, "\(heading)")
        #expect(heading.frame.minY > 150, "\(heading): still at the top of the page")
        #expect(heading.frame.height > 20, "\(heading)")
        #expect(!lines.contains { $0.text == SetupCopy.bBack }, "\(lines)")
        #expect(FinishArrival.headingSize == 26)
        // Almost done: a different heading, and a different mark.
        let almost = try render(FinishFixtures.almost, .light)
        #expect(try Drawing.lines(almost).contains { $0.text == SetupCopy.Finish.almostHeading })
        let mark = { (status: StatusMark.Status) in
            try #require(Snapshot.png(FinishMark(status: status), size: CGSize(width: 100, height: 100), appearance: .light))
        }
        #expect((Snapshot.difference(try mark(.done), try mark(.attention))?.count ?? 0) > 100)
    }

    // MARK: The presses, through the controller

    private final class FinishMachine: SetupMachine {
        var pending: ConfigChanges
        var headless = false
        var failApply = false
        var failStaging = false
        var done: [SetupRunner.Work] = []
        private let lock = NSLock()
        private var _running = true
        /// Whether the VM's process is up, for the process table the runner scans (`controller`).
        var running: Bool {
            get { lock.lock(); defer { lock.unlock() }; return _running }
            set { lock.lock(); _running = newValue; lock.unlock() }
        }
        init(pending: ConfigChanges = ConfigChanges()) { self.pending = pending }

        func readings(through step: WizardStep, answers: SetupFlow.Answers, after work: SetupRunner.Work?,
                      job: SetupRunner.Job?) -> SetupRunner.Readings {
            var read = SetupRunner.Readings()
            read.utm = SetupFixtures.installed
            read.utmAnswers = .answered
            read.windowsApp = .installed(version: "11.4")
            read.vms = .success([SetupVMTests.new])
            read.chosenVM = SetupVMTests.new.name
            read.guestAnswers = true
            read.rdpHost = "winlab02.local"
            read.rdpUser = "Bruno"
            read.otherVMs = .success([])
            read.pending = pending
            for id in WizardStep.allCases.filter({ $0 <= step }).flatMap(SetupFlow.checks(in:)) { read.statuses[id] = .ok("Ready") }
            if step >= .finish { read.statuses["H5"] = headless ? .ok("Headless") : .fixable("Console on") }
            return read
        }

        func perform(_ work: SetupRunner.Work, password: String?, facts: SetupFlow.Facts, job: SetupRunner.Job) throws {
            done.append(work)
            switch work {
            case .fix(checkID: "H5"):
                if failStaging { throw WinbarError("UTM didn't answer") }
                pending.display = .headless
            case .applyChanges:
                if failApply { throw WinbarError("BitLocker couldn't be checked") }
                headless = pending.display == .headless
                pending = ConfigChanges()
            case .discardChanges(nil): pending = ConfigChanges()
            case .startVM: running = true
            default: break
            }
        }
    }

    private func controller(_ machine: FinishMachine, state: SetupWindowState = FinishFixtures.choosing,
                            marked: @escaping () -> Void = {}, opened: @escaping () -> Void = {}) -> SetupWindowController {
        let runner = SetupRunner(machine: machine, environment: .init(
            queue: DispatchQueue(label: "winbar.test.finish"), callbacks: .main, clock: Date.init,
            keepAwake: { _ in {} }, processes: { _ in ([100], machine.running ? 101 : nil) }, workspace: NotificationCenter()))
        var state = state
        state.facts?.pending = machine.pending
        return SetupWindowController(state: state, art: nil,
            settings: .init(wizardShown: { false }, markShown: marked, armieHidden: { true }, hideArmie: {}),
            makeRunner: { runner }, makeCreator: { FakeEmbeddedCreate() }, openWindows: opened)
    }

    private func settle(_ controller: SetupWindowController, tries: Int = 400, until done: () -> Bool) async {
        for _ in 0..<tries {
            if done() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// The recommendation is only chosen, not staged, so the one press stages it and then restarts:
    /// the two pieces of work the old page needed two presses (and a hunt for the second) to do.
    @Test("Restart and Finish from the recommended choice stages it, restarts, and goes back to prove Connect")
    func restartAndFinish() async {
        let machine = FinishMachine(pending: ConfigChanges(cpuCores: 6))
        let controller = controller(machine)
        controller.attach()
        controller.send(.restartAndFinish)
        await settle(controller) { machine.done.contains(.applyChanges) && controller.state.inFlight == nil
            && controller.state.lastEnding?.work == .applyChanges }
        #expect(machine.done == [.fix(checkID: "H5"), .applyChanges], "\(machine.done)")
        #expect(machine.headless)
        // The restart could have stopped Remote Desktop, so Connect asks again (the existing flow).
        #expect(controller.state.step == .connect && controller.state.reconnectAfterRestart)
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
    }

    /// The second half waits on the first ending well: staging that fails leaves its failure on
    /// screen, and no restart follows it.
    @Test("When staging the choice fails, no restart follows")
    func stagingFails() async {
        // Tune's cores are owed too, so a restart sent after the failure would have something to apply.
        let machine = FinishMachine(pending: ConfigChanges(cpuCores: 6))
        machine.failStaging = true
        let controller = controller(machine)
        controller.attach()
        controller.send(.restartAndFinish)
        await settle(controller) { controller.state.lastEnding?.work == .fix(checkID: "H5") && controller.state.inFlight == nil }
        try? await Task.sleep(for: .milliseconds(200))
        #expect(machine.done == [.fix(checkID: "H5")])
        #expect(controller.state.step == .finish)
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
    }

    /// A restart that stops leaves the page where it was, saying what is left.
    @Test("A stopped restart stays on Finish and says what's left")
    func restartStops() async {
        let machine = FinishMachine()
        machine.failApply = true
        let controller = controller(machine)
        controller.attach()
        controller.send(.restartAndFinish)
        await settle(controller) { controller.state.lastEnding?.work == .applyChanges && controller.state.inFlight == nil }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(machine.done == [.fix(checkID: "H5"), .applyChanges])
        #expect(controller.state.step == .finish && !controller.state.finished)
        #expect(SetupFinishPage.restartStopped(controller.state))
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
    }

    @Test("Finish Without Restarting drops what's staged and finishes, in one press")
    func finishWithoutRestarting() async {
        var marked = false
        let machine = FinishMachine(pending: ConfigChanges(cpuCores: 6))
        let controller = controller(machine, state: FinishFixtures.staged, marked: { marked = true })
        controller.attach()
        controller.send(.finishWithoutRestarting)
        await settle(controller) { controller.state.finished }
        #expect(controller.state.finished && marked)
        #expect(machine.done == [.discardChanges(checkID: nil)])
        #expect(controller.state.facts?.pending.isEmpty == true)
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
    }

    @Test("The tiles choose, and choosing runs nothing")
    func choosing() {
        let machine = FinishMachine()
        let controller = controller(machine)
        controller.attach()
        controller.send(.chooseBackground(false))
        #expect(SetupFinishPage.choice(controller.state.facts!) == .keepScreen)
        #expect(SetupFooter.footer(controller.state).corner?.press == .send(.finish))
        controller.send(.chooseBackground(true))
        #expect(SetupFinishPage.choice(controller.state.facts!) == .background)
        #expect(SetupFooter.footer(controller.state).corner?.press == .send(.restartAndFinish))
        #expect(machine.done.isEmpty)
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
    }

    @Test("Open Windows runs the menu's Connect and puts the window away, and only once finished")
    func openWindows() {
        var opened = 0
        var marked = false
        let early = controller(FinishMachine(), opened: { opened += 1 })
        early.send(.openWindows)
        #expect(opened == 0)
        let done = controller(FinishMachine(), state: FinishFixtures.ready, marked: { marked = true }, opened: { opened += 1 })
        done.send(.openWindows)
        #expect(opened == 1 && marked)
    }

    @Test("Try Connecting Again goes back to Connect and presses it")
    func connectAgain() async {
        let machine = FinishMachine()
        let controller = controller(machine, state: FinishFixtures.almost)
        controller.attach()
        controller.send(.connectAgain)
        #expect(controller.state.step == .connect && !controller.state.finished)
        #expect(controller.state.answers.connectPressed && controller.state.answers.connected == nil)
        await settle(controller) { machine.done.contains(.connect) && controller.state.inFlight == nil }
        #expect(machine.done == [.connect])
        // Windows App opened again, so the page asks whether the desktop appeared.
        #expect(SetupFlow.connect(controller.state.facts!) == .didItWork(host: "winlab02.local"))
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
    }

    /// Owner's rule: a finished window stays finished. A VM stopped after setup is a Mac in use, not a
    /// setup come undone, and the page it was on used to be dragged back to the VM step (with the bar
    /// still full). It stays, and its buttons start Windows: Open Windows is the menu's Connect, which
    /// starts a stopped VM, and Try Connecting Again starts it here first. The controls are a landing
    /// that moves a finished window (the step goes to the VM), and a Try Connecting Again that only
    /// connects (no start: Connect would wait on a VM that isn't running).
    @Test("A finished window whose VM stopped stays finished, and its buttons start Windows")
    func finishedWithTheVMStopped() async throws {
        var opened = 0
        let machine = FinishMachine()
        let ready = controller(machine, state: FinishFixtures.ready, opened: { opened += 1 })
        ready.attach()
        machine.running = false
        ready.send(.perform(.run(.checkAgain(.finish))))
        await settle(ready, tries: 3000) { ready.state.lastEnding?.work == .checkAgain(.finish) && ready.state.inFlight == nil }
        #expect(ready.state.facts?.vmRunning == false)
        #expect(ready.state.step == .finish && ready.state.finished)
        #expect(SetupFooter.footer(ready.state).corner == .init(SetupCopy.Finish.bOpenWindows, .openWindows, kind: .primary))
        ready.send(.openWindows)
        #expect(opened == 1)

        let almost = controller(machine, state: FinishFixtures.almost)
        almost.attach()
        almost.send(.perform(.run(.checkAgain(.finish))))
        await settle(almost, tries: 3000) { almost.state.lastEnding?.work == .checkAgain(.finish) && almost.state.inFlight == nil }
        #expect(almost.state.step == .finish && almost.state.finished)
        #expect(SetupFooter.footer(almost.state).corner?.press == .send(.connectAgain))
        machine.done = []
        almost.send(.connectAgain)
        #expect(almost.state.step == .connect && !almost.state.finished)
        // The Connect's own ending, not merely its start: the start's ending sends it, and the window
        // is idle for a moment between the two.
        await settle(almost, tries: 3000) { almost.state.lastEnding?.work == .connect && almost.state.inFlight == nil }
        #expect(machine.done == [.startVM(SetupVMTests.new.name), .connect], "\(machine.done)")
        #expect(SetupFlow.connect(try #require(almost.state.facts)) == .didItWork(host: "winlab02.local"))
        almost.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        ready.windowWillClose(Notification(name: NSWindow.willCloseNotification))
    }

    /// Windows App skipped, the setup finished, then installed from the App Store: the page stays
    /// finished (a snapshot never moves it), says Connect was never tried, and its corner goes back to
    /// the saved PC step the skip passed over, with the skip taken back and the step read. The control
    /// is a landing that un-finishes by itself, or a Go Back that keeps the skip (the step then only
    /// says it was skipped).
    @Test("Windows App installed after the finish: the page stays, and Go Back to Saved PC goes there")
    func windowsAppInstalledAfterTheFinish() async throws {
        let machine = FinishMachine()
        let controller = controller(machine, state: FinishFixtures.noWindowsApp)
        controller.attach()
        #expect(SetupCopy.Finish.outcome(try #require(controller.state.facts)) == .windowsAppSkipped)
        controller.send(.perform(.run(.checkAgain(.finish))))
        await settle(controller, tries: 3000) { controller.state.lastEnding?.work == .checkAgain(.finish) && controller.state.inFlight == nil }
        #expect(controller.state.facts?.windowsApp.isInstalled == true)
        #expect(controller.state.step == .finish && controller.state.finished)
        #expect(SetupCopy.Finish.outcome(try #require(controller.state.facts)) == .notTried)
        #expect(SetupFooter.footer(controller.state).corner?.press == .send(.revisit(.savedPC)))

        controller.send(.revisit(.savedPC))
        #expect(controller.state.step == .savedPC && !controller.state.finished)
        #expect(controller.state.answers.leftAlone.isDisjoint(with: ["C1", "C2"]))
        await settle(controller, tries: 3000) { controller.state.lastEnding?.work == .checkAgain(.savedPC) && controller.state.inFlight == nil }
        #expect(controller.state.lastEnding?.work == .checkAgain(.savedPC))
        guard case .saved? = controller.state.facts.map(SetupFlow.savedPC) else {
            Issue.record("the saved PC step says \(String(describing: controller.state.facts.map(SetupFlow.savedPC)))")
            return
        }
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
    }

    // MARK: Renders

    private func render(_ state: SetupWindowState, _ appearance: Snapshot.Appearance, height: CGFloat = 620) throws -> Data {
        try #require(Snapshot.png(SetupScreen(state: state, art: nil, send: { _ in }),
                                  size: CGSize(width: 600, height: height), appearance: appearance))
    }

    @Test("Every Finish page renders, light and dark", arguments: [Snapshot.Appearance.light, .dark])
    func renders(appearance: Snapshot.Appearance) throws {
        for (name, state) in FinishFixtures.screens {
            try Snapshot.record(try render(state, appearance), as: "finish-\(name)-\(appearance.rawValue)")
        }
    }
}

// MARK: - The way back to Windows' screen, by name

/// The owner asked for a way to give the VM its screen back later; the menu has one, **Bring Back
/// Windows' Screen…**, but Finish said only "Winbar's menu can switch it back later". The choice and
/// the finished page of a VM in the background now name the item as the menu does.
@MainActor @Suite("Finish names the way back to Windows' screen")
struct FinishWayBackTests {
    private func read(_ markdown: String) -> String { String(SetupCopy.markdown(markdown).characters) }

    @Test("The choice's rule and the background note name the menu item exactly")
    func words() {
        #expect(read(SetupCopy.Finish.choiceRule).contains(MenuCopy.bringBackScreen))
        #expect(read(SetupCopy.Finish.choiceRule).contains("only does it while this is the only one"))
        #expect(!SetupCopy.Finish.choiceRule.contains("can switch it back later"))
        #expect(read(SetupCopy.Finish.inBackground).contains(MenuCopy.bringBackScreen))
        #expect(boldRuns(SetupCopy.markdown(SetupCopy.Finish.inBackground)) == [MenuCopy.bringBackScreen])
    }

    @Test("Only a VM with no screen of its own is told where its screen is")
    func inBackground() throws {
        #expect(SetupFinishPage.runsInBackground(try #require(FinishFixtures.tuneOnly.facts)))
        #expect(!SetupFinishPage.runsInBackground(try #require(FinishFixtures.ready.facts)))
        var unread = try #require(FinishFixtures.ready.facts)
        unread.rows.removeValue(forKey: "H5")
        #expect(!SetupFinishPage.runsInBackground(unread))
    }

    private func words(_ state: SetupWindowState) throws -> String {
        let png = try #require(Snapshot.png(SetupScreen(state: state, art: nil, send: { _ in }),
                                            size: CGSize(width: 600, height: 900), appearance: .light))
        return try Drawing.lines(png).map(\.text).joined(separator: " ").replacingOccurrences(of: "...", with: "…")
    }

    /// Control: draw `choiceRule` as plain text again and its asterisks show; drop the note from
    /// `FinishArrival` and the background page doesn't name the item.
    @Test("Drawn: the choice names it in bold, and so does the finished page of a VM in the background")
    func drawn() throws {
        let choosing = try words(FinishFixtures.choosing)
        #expect(choosing.contains("Bring Back Windows' Screen"), "\(choosing)")
        #expect(!choosing.contains("**"), "\(choosing)")
        let background = FinishFixtures.finished(connected: true) {
            $0.facts?.rows["H5"] = JourneyFixtures.row("H5", .ok("Headless"))
        }
        let done = try words(background)
        #expect(done.contains("Bring Back Windows' Screen"), "\(done)")
        let kept = try words(FinishFixtures.ready)
        #expect(!kept.contains("Bring Back Windows' Screen"), "\(kept)")
    }
}
