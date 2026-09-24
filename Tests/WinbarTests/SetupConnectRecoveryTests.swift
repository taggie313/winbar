import AppKit
import Foundation
import Testing
@testable import Winbar

// The connection's recovery card follows evidence. In the live run that prompted it, Windows App's
// credentials prompt had only timed out while the VM's Remote Desktop port answered, and the card said
// readiness "hasn't been checked" and sent the person to Local Network settings. Invented VM, host
// and user throughout; nothing here reaches the Mac, UTM or a VM.

/// A Mac whose Remote Desktop port says `port`, probed only when the runner's own read plan allows it
/// (`SetupRunner.readPlan`), exactly as the live machine decides — so a read that the plan keeps from
/// probing comes back with no readiness, as it would live.
private final class PortMachine: SetupMachine {
    private let lock = NSLock()
    private var _port: RDP.Readiness = .ready
    private var _probes = 0
    var connectFails = false

    var port: RDP.Readiness {
        get { lock.lock(); defer { lock.unlock() }; return _port }
        set { lock.lock(); _port = newValue; lock.unlock() }
    }
    var probes: Int { lock.lock(); defer { lock.unlock() }; return _probes }

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
        for id in WizardStep.allCases.filter({ $0 <= step }).flatMap(SetupFlow.checks(in:)) { read.statuses[id] = .ok("Ready") }
        let plan = SetupRunner.readPlan(through: step, readings: read, answers: answers, utmUp: true,
                                        settled: .answered, consent: { .decided })
        if plan.readiness {
            lock.lock()
            _probes += 1
            read.readiness = _port
            lock.unlock()
        }
        return read
    }

    func perform(_ work: SetupRunner.Work, password: String?, facts: SetupFlow.Facts, job: SetupRunner.Job) throws {
        if work == .connect, connectFails {
            throw WinbarError("Windows isn't accepting Remote Desktop yet", "Nothing answered on port 3389 within two minutes.")
        }
    }
}

@MainActor @Suite("After a failed connection, the recovery card reads the port and follows what it said")
struct SetupConnectRecoveryTests {
    private func rig(_ machine: PortMachine) -> SetupWindowController {
        let runner = SetupRunner(machine: machine, environment: .init(
            queue: DispatchQueue(label: "winbar.test.connect-recovery"), callbacks: .main, clock: Date.init,
            keepAwake: { _ in {} }, processes: { _ in ([300], 301) }, workspace: NotificationCenter()))
        let controller = SetupWindowController(state: SetupFixtures.state(.connect, facts: JourneyFixtures.facts), art: nil,
            settings: .init(wizardShown: { false }, markShown: {}, armieHidden: { true }, hideArmie: {}),
            makeRunner: { runner }, makeCreator: { FakeEmbeddedCreate() })
        controller.attach()
        return controller
    }

    private func wait(_ controller: SetupWindowController, for work: SetupRunner.Work) async {
        for _ in 0..<3000 {
            if controller.state.lastEnding?.work == work, controller.state.inFlight == nil { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(controller.state.lastEnding?.work == work)
        #expect(controller.state.inFlight == nil)
    }

    private func diagnosis(_ controller: SetupWindowController) -> SetupFlow.Diagnosis? {
        guard let facts = controller.state.facts, case .didNotWork(let diagnosis) = SetupFlow.connect(facts) else { return nil }
        return diagnosis
    }

    /// Connect's own wait already probed the port, and the Connect card predicted the Local Network
    /// prompt; the read that ends a Connect that failed probes too, so its card knows the port's answer.
    @Test("A Connect that fails comes back with the port's answer, not \"hasn't been checked\"")
    func failedConnectKnowsThePort() async {
        let machine = PortMachine()
        machine.port = .notReady
        machine.connectFails = true
        let controller = rig(machine)
        controller.send(.perform(.run(.connect)))
        #expect(controller.state.answers.connectPressed && controller.state.connectionRequested)
        await wait(controller, for: .connect)
        #expect(controller.state.answers.connected == false)
        #expect(diagnosis(controller)?.readiness == .notReady)
        let card = SetupCopy.Connecting.recovery(diagnosis(controller)!)
        #expect(card.heading == "Windows isn't answering yet")
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
    }

    /// Only the finish step reads H5, so a Connect reached without visiting Finish in this session has
    /// no reading of the VM's screen — as for a VM made headless by `winbar setup` or Go Headless…,
    /// going through Set Up Winbar… again. The card then mustn't point at a UTM window that may not
    /// exist, and offers Close Setup for the menu's Show Console Window….
    @Test("A failed Connect with the VM's screen unread says both ways to watch Windows, and offers Close Setup")
    func failedConnectWithScreenUnread() async {
        let machine = PortMachine()
        machine.port = .notReady
        machine.connectFails = true
        let controller = rig(machine)
        controller.send(.perform(.run(.connect)))
        await wait(controller, for: .connect)
        #expect(controller.state.facts?.kind("H5") == nil)
        let found = diagnosis(controller)
        #expect(found?.console == .unknown)
        let card = SetupCopy.Connecting.recovery(found!)
        let text = card.steps.map { String(SetupCopy.markdown($0).characters) }.joined(separator: " ")
        #expect(!text.contains(SetupCopy.Connecting.recoverOnScreen))
        #expect(text.contains("If it runs in the background") && text.contains(MenuCopy.bringBackScreen))
        #expect(card.offersConsole)
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
    }

    /// The port's answer when Windows App opened can be minutes old by the time someone says No: the
    /// live run's credentials prompt timed out, and Windows can restart for an update meanwhile. A look,
    /// not a Check Again (changed on purpose: it waited for one): the port is read on every snapshot
    /// once Connect was pressed, and the look is owed rather than refused if something runs.
    @Test("No reads the port again, and the card says what it says now")
    func noReadsThePortAgain() async {
        let machine = PortMachine()
        machine.port = .ready
        let controller = rig(machine)
        controller.send(.perform(.run(.connect)))
        await wait(controller, for: .connect)
        #expect(controller.state.answers.connectionOpened)
        #expect(controller.state.facts?.readiness == .ready)
        let before = machine.probes
        machine.port = .notReady
        controller.send(.connected(false))
        for _ in 0..<3000 where diagnosis(controller)?.readiness != .notReady || controller.state.inFlight != nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(controller.state.lastEnding?.work == .connect && controller.state.refusal == nil)
        #expect(machine.probes == before + 1)
        #expect(diagnosis(controller)?.readiness == .notReady)
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
    }

    /// Yes needs nothing read: the desktop is the evidence.
    @Test("Yes reads nothing")
    func yesReadsNothing() async {
        let machine = PortMachine()
        let controller = rig(machine)
        controller.send(.perform(.run(.connect)))
        await wait(controller, for: .connect)
        let probes = machine.probes
        controller.send(.connected(true))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(controller.state.lastEnding?.work == .connect && machine.probes == probes)
        #expect(SetupFlow.connect(controller.state.facts!) == .worked)
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
    }
}

/// Stop Waiting on Connect: nothing was tried, so the step is ready to try again, not the "it didn't
/// work" card. The control is HEAD's mapping, which counted a cancel as a No.
@Suite("A Connect stopped while it waited is ready again, and one that failed isn't")
struct ConnectStoppedTests {
    private func ended(_ outcome: SetupRunner.Outcome) -> SetupWindowState {
        let state = JourneyPolishFixtures.state(.connect) { $0.answers.connectPressed = true }
        return state.applying(.ended(SetupRunner.Ending(work: .connect, outcome: outcome, facts: state.facts!, slept: false,
                                                        started: SetupFixtures.started)))
    }

    @Test("Stopped: not answered, not opened, and Connect is offered again")
    func stopped() throws {
        let stopped = ended(.cancelled)
        #expect(stopped.answers.connected == nil && !stopped.answers.connectionOpened)
        #expect(SetupFlow.connect(try #require(stopped.facts)) == .ready(host: "winlab02.local", savedPC: true))
        #expect(SetupFooter.footer(stopped).corner?.press == .send(.perform(.run(.connect))))
        let failed = ended(.failed(.init(title: "Windows isn't accepting Remote Desktop yet")))
        #expect(failed.answers.connected == false)
        guard case .didNotWork = SetupFlow.connect(try #require(failed.facts)) else {
            Issue.record("a failed Connect isn't the recovery card")
            return
        }
    }
}

@Suite("The recovery card says only what the port supports")
struct SetupConnectRecoveryCopyTests {
    private func words(_ card: SetupCopy.Connecting.Recovery) -> String {
        ([card.heading] + card.steps.map { String(SetupCopy.markdown($0).characters) }).joined(separator: " ")
    }

    @Test("Blocked: the one branch that sends anyone to Local Network, for Winbar and Windows App")
    func blocked() {
        let text = words(SetupCopy.Connecting.recovery(.blocked, savedPC: true, console: .onScreen))
        #expect(text.contains("Privacy & Security → Local Network"))
        #expect(text.contains("turn on Winbar, and Windows App too"))
        #expect(text.contains("can't tell whether Windows is ready"))
        #expect(!text.contains("PIN"))
    }

    @Test("Not answering: Windows is starting, restarting or updating; wait, then Try Again")
    func notAnswering() {
        let card = SetupCopy.Connecting.recovery(.notReady, savedPC: true, console: .onScreen)
        let text = words(card)
        #expect(text.contains("still starting, restarting or installing updates"))
        #expect(text.contains("then choose Try Again"))
        #expect(text.contains("The VM's window in UTM shows what Windows is doing."))
        #expect(!text.contains(MenuCopy.bringBackScreen))
        #expect(!text.contains("Local Network") && !text.contains("PIN") && !card.offersConsole)
        // A VM in the background can only be watched once the menu's Bring Back Windows' Screen… has
        // given it one, after the card's own Close Setup, which comes with this advice.
        let headless = SetupCopy.Connecting.recovery(.notReady, savedPC: true, console: .headless)
        #expect(words(headless).contains("choose Close Setup, then Bring Back Windows' Screen… in Winbar's menu")
                && headless.offersConsole)
        #expect(!words(headless).contains("The VM's window in UTM"))
        // Unread: both, as conditions, and never the UTM window as a fact.
        let unknown = SetupCopy.Connecting.recovery(.notReady, savedPC: true, console: .unknown)
        #expect(!words(unknown).contains("The VM's window in UTM shows what Windows is doing."))
        #expect(words(unknown).contains("If the VM has a window in UTM, it shows what Windows is doing."))
        #expect(words(unknown).contains("If it runs in the background, choose Close Setup, then Bring Back Windows' Screen…"))
        #expect(unknown.offersConsole)
        #expect(Set([card, headless, unknown].map(\.steps)).count == 3)
    }

    /// H5 is the only evidence about the VM's screen: ok is headless, fixable is a console, and
    /// anything else — no reading, or info (unknown, or not yet offered) — is unknown.
    @Test("The diagnosis reads the VM's screen from H5, and unread is unknown")
    func consoleFromH5() {
        var facts = JourneyFixtures.facts
        facts.answers.connected = false
        func console() -> SetupFlow.Console? {
            guard case .didNotWork(let diagnosis) = SetupFlow.connect(facts) else { return nil }
            return diagnosis.console
        }
        facts.rows["H5"] = JourneyFixtures.row("H5", .ok("headless"))
        #expect(console() == .headless)
        facts.rows["H5"] = JourneyFixtures.row("H5", .fixable("console window on"))
        #expect(console() == .onScreen)
        facts.rows["H5"] = JourneyFixtures.row("H5", .info("unknown"))
        #expect(console() == .unknown)
        facts.rows["H5"] = nil
        #expect(console() == .unknown)
        // What Connect reads leaves H5 out, which is how a Connect reached without Finish has none.
        #expect(!SetupFlow.checks(in: .connect).contains("H5"))
    }

    @Test("Answering: the problem is Windows App or the sign-in, with the password, not a PIN")
    func answering() {
        let saved = words(SetupCopy.Connecting.recovery(.ready, savedPC: true, console: .headless))
        #expect(saved.contains("Windows answered Winbar's check, so the problem is in Windows App or the sign-in."))
        #expect(saved.contains("finish signing in there") && saved.contains("choose Try Again for a new one"))
        #expect(saved.contains("password, not its PIN"))
        #expect(saved.contains("store the credentials with the saved PC, so later connections don't ask"))
        #expect(!saved.contains("Local Network") && !saved.contains("starting"))
        for console in [SetupFlow.Console.headless, .onScreen, .unknown] {
            #expect(!SetupCopy.Connecting.recovery(.ready, savedPC: true, console: console).offersConsole)
        }
        // A one-off connection has no saved PC to store them with, so it says what one would do.
        let oneOff = words(SetupCopy.Connecting.recovery(.ready, savedPC: false, console: .onScreen))
        #expect(oneOff.contains("A PC saved in Windows App can store the credentials") && oneOff.contains("a one-off connection can't"))
        #expect(!oneOff.contains("with the saved PC"))
    }

    @Test("Not read: says so and how to read it, and claims nothing about Windows or the network")
    func unread() {
        let text = words(SetupCopy.Connecting.recovery(nil, savedPC: true, console: .onScreen))
        #expect(text.contains("hasn't checked whether Windows is answering") && text.contains("Choose Check Again"))
        #expect(!text.contains("Local Network") && !text.contains("PIN") && !text.contains("starting"))
    }

    @Test("The saved-PC step's heading is neutral, and its busy line names the work")
    func savedPCLabels() {
        #expect(SetupCopy.SavedPC.heading == "The saved PC in Windows App")
        func busy(_ work: SetupRunner.Work) -> String {
            SetupCopy.SavedPC.busy(.init(work: work, started: Date(timeIntervalSince1970: 0), vm: "winlab02"))
        }
        #expect(busy(.checkAgain(.savedPC)) == "Checking Windows App for a saved PC…")
        #expect(busy(.savePC) == "Saving the PC in Windows App…")
        #expect(busy(.installWindowsApp) == "Opening Windows App's page in the App Store…")
        #expect(busy(.guide(checkID: "C2")) == "Opening Windows App…")
        #expect(busy(.recordDone(checkID: "C2")) == "Checking Windows App for the saved PC again…")
        // The card shows exactly that line while the work runs, and the step itself otherwise.
        var state = SetupFixtures.state(.savedPC, facts: JourneyFixtures.facts)
        #expect(SetupJourneyView.savedPCWaiting(state) == nil)
        state.inFlight = .init(work: .checkAgain(.savedPC), started: Date(timeIntervalSince1970: 0), vm: "winlab02")
        #expect(SetupJourneyView.savedPCWaiting(state) == "Checking Windows App for a saved PC…")
        state.inFlight = .init(work: .savePC, started: Date(timeIntervalSince1970: 0), vm: "winlab02")
        #expect(SetupJourneyView.savedPCWaiting(state) == "Saving the PC in Windows App…")
        // Only saving says saving.
        for work in [SetupRunner.Work.checkAgain(.savedPC), .installWindowsApp, .guide(checkID: "C2"),
                     .recordDone(checkID: "C2")] {
            #expect(!busy(work).contains("Saving"), "\(work)")
        }
    }
}

/// The finishing restart quits UTM and starts it again, so UTM's process ids change while the work
/// runs, and the menu's five-second tick marks the snapshot stale. Live, the Set Up Winbar window was
/// missing from Winbar's Accessibility window list for about five seconds just then, and came back by
/// itself. Nothing in the window's code closes, hides or remakes it on that path (`windowWillClose` is
/// AppKit's alone, `present()` reuses the one window, `.stale` redraws nothing), and this holds the
/// part a test can: the controller stays attached, keeps its answers, and lands on Connect afterwards.
private final class RestartMachine: SetupMachine {
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var _headless = false
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
        for id in WizardStep.allCases.filter({ $0 <= step }).flatMap(SetupFlow.checks(in:)) { read.statuses[id] = .ok("Ready") }
        lock.lock()
        read.pending = _headless ? ConfigChanges() : ConfigChanges(display: .headless)
        lock.unlock()
        return read
    }
    func perform(_ work: SetupRunner.Work, password: String?, facts: SetupFlow.Facts, job: SetupRunner.Job) throws {
        guard work == .applyChanges else { return }
        job.say(SetupCopy.waitingForWindows)
        // Long enough that a busy test run can't end the restart before the test has looked at it
        // mid-way; the test always signals.
        _ = release.wait(timeout: .now() + 300)
        lock.lock(); _headless = true; lock.unlock()
    }
}

@MainActor @Suite("The finishing restart doesn't close, remake or reset the window")
struct SetupRestartWindowTests {
    @Test("UTM's processes changing mid-restart leave the window attached, with its answers, and it lands on Connect")
    func utmRestartMidWork() async {
        let machine = RestartMachine()
        let pids = LockedPIDs([100])
        let runner = SetupRunner(machine: machine, environment: .init(
            queue: DispatchQueue(label: "winbar.test.restart-window"), callbacks: .main, clock: Date.init,
            keepAwake: { _ in {} }, processes: { _ in (pids.value, 101) }, workspace: NotificationCenter()))
        var state = SetupFixtures.state(.finish, facts: JourneyFixtures.facts)
        state.answers.connectionOpened = true
        state.answers.connected = true
        state.facts?.answers = state.answers
        let controller = SetupWindowController(state: state, art: nil,
            settings: .init(wizardShown: { false }, markShown: {}, armieHidden: { true }, hideArmie: {}),
            makeRunner: { runner }, makeCreator: { FakeEmbeddedCreate() })
        controller.attach()
        controller.send(.perform(.run(.applyChanges)))
        for _ in 0..<3000 where controller.state.inFlight?.line != SetupCopy.waitingForWindows {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(controller.state.inFlight?.work == .applyChanges)
        pids.value = [200]                  // UTM quit and was started again
        runner.processTableTick()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(controller.isPresented)
        #expect(controller.state.step == .finish && controller.state.inFlight?.work == .applyChanges)
        #expect(controller.state.answers.connected == true)
        machine.release.signal()
        for _ in 0..<3000 where controller.state.lastEnding?.work != .applyChanges {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(controller.isPresented)
        #expect(controller.state.lastEnding?.outcome == .finished)
        #expect(controller.state.step == .connect && controller.state.reconnectAfterRestart)
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
    }
}

private final class LockedPIDs: @unchecked Sendable {
    private let lock = NSLock()
    private var pids: Set<Int32>
    init(_ pids: Set<Int32>) { self.pids = pids }
    var value: Set<Int32> {
        get { lock.lock(); defer { lock.unlock() }; return pids }
        set { lock.lock(); pids = newValue; lock.unlock() }
    }
}

// MARK: - A read nobody pressed keeps the page

/// Josh, coming back to the window on the saved PC and Connect steps: the card went, and the password
/// field with it, for a spinner, every time. A read nobody pressed (`.refreshing`) now leaves the card,
/// the field and its text as they were, draws one quiet line, and leaves live the buttons that aren't
/// the runner's work. A read somebody pressed still says what it is doing, instead of the card.
@MainActor @Suite("A read nobody pressed keeps the page's card, its field and its words")
struct QuietReadPageTests {
    private static let look = SetupFixtures.flight(.lookAgain(.savedPC, forgetting: .statuses))

    private static var save: SetupWindowState {
        var state = SetupFixtures.state(.savedPC, facts: JourneyFixtures.facts)
        state.facts?.rows["C2"] = JourneyFixtures.row("C2", .fixable("No saved PC"))
        return state
    }

    /// The control is HEAD's card, which is the busy line whenever anything runs: the field is gone.
    @Test("The saved PC's password field stays, typed text and all, and Return saves nothing until it ends")
    func passwordFieldStays() throws {
        let quiet = Self.save.applying(.refreshing(Self.look))
        #expect(quiet.refreshing)
        #expect(SetupJourneyView.savedPCWaiting(quiet) == nil)
        #expect(SetupJourneyView.showsQuietRead(quiet))

        let sent = Sent()
        let typed = SetupCredentials()
        typed.password = "synthetic-test-secret"
        let window = Pressing(SetupScreen(state: quiet, art: nil, credentials: typed, savePassword: sent.save, send: sent.send))
        let field = try #require(window.secureField, "the password field went")
        #expect(field.isEnabled)
        #expect(field.stringValue == "synthetic-test-secret")
        // Return in the field while the read runs: nothing is handed over, and nothing is lost.
        #expect(window.submitSecureField())
        #expect(sent.saved.isEmpty && typed.password == "synthetic-test-secret")

        // A read somebody pressed still says so, in the card's own words.
        let pressed = Self.save.applying(.started(SetupFixtures.flight(.checkAgain(.savedPC))))
        #expect(SetupJourneyView.savedPCWaiting(pressed) == SetupCopy.SavedPC.busy(SetupFixtures.flight(.checkAgain(.savedPC))))
        #expect(Pressing(SetupScreen(state: pressed, art: nil, credentials: typed, send: { _ in })).secureField == nil)
    }

    /// The buttons that quit another app or take Ben to one aren't the runner's work, so no read can
    /// collide with them. The control is HEAD's corner, greyed (and so not drawn) while anything runs.
    @Test("Quit Windows App, Show Windows' Screen and Open Local Network Settings stay live through a read")
    func windowButtonsStayLive() throws {
        let reading = SetupFixtures.flight(.lookAgain(.savedPC, forgetting: .statuses))
        let open = try JourneyPolishFixtures.screen("saved-app-open").applying(.refreshing(reading))
        #expect(SetupFooter.footer(open).corner == .init(SetupCopy.SavedPC.bQuitWindowsApp, .quitWindowsApp, kind: .primary))
        let noUser = try JourneyPolishFixtures.screen("saved-no-user").applying(.refreshing(reading))
        #expect(SetupFooter.footer(noUser).corner?.press == .send(.open(.windowsScreen)))
        let blocked = try JourneyPolishFixtures.screen("connect-failed")
            .applying(.refreshing(SetupFixtures.flight(.lookAgain(.connect, forgetting: .statuses))))
        #expect(SetupFooter.footer(blocked).corner?.press == .send(.open(.localNetworkSettings)))
        #expect(SetupFooter.footer(blocked).corner?.enabled == true)
        // Runner work stays greyed: Save It isn't drawn while the read runs.
        #expect(SetupFooter.footer(Self.save.applying(.refreshing(Self.look))).corner == nil)
    }

    /// The control is the Connect card's HEAD branch, the busy line whenever anything runs.
    @Test("Connect's recovery card stays drawn under one quiet line")
    func recoveryCardStays() throws {
        let failed = try JourneyPolishFixtures.screen("connect-failed")
        let diagnosis: SetupFlow.Diagnosis = try {
            guard case .didNotWork(let diagnosis) = SetupFlow.connect(try #require(failed.facts)) else {
                throw CancellationError()
            }
            return diagnosis
        }()
        let heading = SetupCopy.Connecting.recovery(diagnosis).heading
        let quiet = failed.applying(.refreshing(SetupFixtures.flight(.lookAgain(.connect, forgetting: .statuses))))
        let lines = try Drawing.lines(try render(quiet, .light))
        #expect(Drawing.find(String(heading.prefix(24)), in: lines) != nil, "\(lines)")
        #expect(Drawing.find("Checking again", in: lines) != nil, "\(lines)")

        let pressed = failed.applying(.started(SetupFixtures.flight(.checkAgain(.connect))))
        let busy = try Drawing.lines(try render(pressed, .light))
        #expect(Drawing.find(String(heading.prefix(24)), in: busy) == nil, "\(busy)")
    }
}

// MARK: - A refused press changes nothing

/// A Mac with the journey's steps read as ready, noting each piece of work the runner carries out and
/// the password handed with it. Nothing here reaches Windows App.
private final class PressMachine: SetupMachine {
    private let lock = NSLock()
    private var _performed: [SetupRunner.Work] = []
    private var _passwords: [String] = []
    var performed: [SetupRunner.Work] { lock.lock(); defer { lock.unlock() }; return _performed }
    var passwords: [String] { lock.lock(); defer { lock.unlock() }; return _passwords }

    func readings(through step: WizardStep, answers: SetupFlow.Answers, after work: SetupRunner.Work?,
                  job: SetupRunner.Job?) -> SetupRunner.Readings {
        var read = SetupRunner.Readings()
        read.utm = SetupFixtures.installed
        read.utmAnswers = .answered
        read.windowsApp = .installed(version: "11.4")
        read.vms = .success([SetupVMTests.old, SetupVMTests.new])
        read.chosenVM = SetupVMTests.new.name
        read.guestAnswers = true
        read.rdpHost = "winlab02.local"
        read.rdpUser = "Bruno"
        read.otherVMs = .success([])
        for id in WizardStep.allCases.filter({ $0 <= step }).flatMap(SetupFlow.checks(in:)) { read.statuses[id] = .ok("Ready") }
        read.statuses["C2"] = .fixable("No saved PC")
        return read
    }

    func perform(_ work: SetupRunner.Work, password: String?, facts: SetupFlow.Facts, job: SetupRunner.Job) throws {
        lock.lock()
        _performed.append(work)
        if let password { _passwords.append(password) }
        lock.unlock()
    }
}

/// Josh's refused presses left the page changed as if they had started: Try Again on a failed Connect
/// cleared "didn't work" before the runner said no, so the recovery card became "Ready to test" over a
/// press that never ran; a refused Save It had already emptied the field. The answers a press gives,
/// and the field it hands over, now change only once the runner takes it. Each press here is turned
/// down by the app's gate, as when the menu is starting a VM; the controls are HEAD's order (answers
/// and the field first, then the runner), which fails every first half.
@MainActor @Suite("A press the runner turns down changes no answer, and keeps what was typed")
struct RefusedPressTests {
    private func rig(_ machine: PressMachine, _ state: SetupWindowState, gate: AppWorkGate) -> SetupWindowController {
        let runner = SetupRunner(machine: machine, environment: .init(
            queue: DispatchQueue(label: "winbar.test.refused-press"), callbacks: .main, clock: Date.init,
            keepAwake: { _ in {} }, processes: { _ in ([300], 301) }, workspace: NotificationCenter(), workGate: gate))
        let controller = SetupWindowController(state: state, art: nil,
            settings: .init(wizardShown: { false }, markShown: {}, armieHidden: { true }, hideArmie: {}),
            makeRunner: { runner }, makeCreator: { FakeEmbeddedCreate() })
        controller.attach()
        return controller
    }

    /// The menu starting another VM holds the app's gate, so the window's work is refused.
    private func menuBusy(_ gate: AppWorkGate) throws -> AppWorkGate.Lease {
        try gate.begin(.menu, label: "starting “atelier”", vm: "atelier").get()
    }

    private func settle(_ controller: SetupWindowController, until done: () -> Bool) async {
        for _ in 0..<3000 where !done() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test("Try Again on a failed Connect, turned down, leaves \"didn't work\" and its card; taken, it connects")
    func retryConnection() async throws {
        let failed = JourneyPolishFixtures.state(.connect) {
            $0.answers.connectPressed = true
            $0.answers.connected = false
            $0.facts?.readiness = .notReady
        }
        let gate = AppWorkGate()
        let menu = try menuBusy(gate)
        let machine = PressMachine()
        let controller = rig(machine, failed, gate: gate)
        controller.send(.retryConnection)
        #expect(controller.state.refusal?.wanted == .connect)
        #expect(controller.state.answers.connected == false)
        #expect(!controller.state.connectionRequested)
        guard case .didNotWork? = controller.state.facts.map(SetupFlow.connect) else {
            Issue.record("the recovery card went: \(String(describing: controller.state.facts.map(SetupFlow.connect)))")
            return
        }

        menu.finish()
        controller.send(.retryConnection)
        #expect(controller.state.refusal == nil)
        #expect(controller.state.answers.connected == nil && controller.state.connectionRequested)
        await settle(controller) { controller.state.lastEnding?.work == .connect && controller.state.inFlight == nil }
        #expect(machine.performed == [.connect])
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
    }

    @Test("Another VM, turned down, keeps this VM's answers; a Discard, turned down, leaves nothing left alone")
    func answersStand() throws {
        let gate = AppWorkGate()
        let menu = try menuBusy(gate)
        let machine = PressMachine()
        var vm = SetupFixtures.state(.vm, facts: SetupVMTests.facts())
        vm.answers.leftAlone = ["G1"]
        vm.choosingAnotherVM = true
        vm.facts?.answers = vm.answers
        let choosing = rig(machine, vm, gate: gate)
        choosing.send(.useVM(name: SetupVMTests.old.name, id: SetupVMTests.old.id))
        #expect(choosing.state.refusal?.wanted == .chooseVM(SetupVMTests.old.name, id: SetupVMTests.old.id))
        #expect(choosing.state.answers.leftAlone == ["G1"] && choosing.state.choosingAnotherVM)
        choosing.windowWillClose(Notification(name: NSWindow.willCloseNotification))

        let tune = JourneyPolishFixtures.state(.tune) { $0.facts?.pending.cpuCores = 6 }
        let discarding = rig(machine, tune, gate: gate)
        discarding.send(.discardChanges("H3"))
        #expect(discarding.state.refusal?.wanted == .discardChanges(checkID: "H3"))
        #expect(!discarding.state.answers.leftAlone.contains("H3"))
        #expect(discarding.state.refusal?.answers?.leftAlone.contains("H3") == true)
        discarding.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        #expect(machine.performed.isEmpty)
        menu.finish()
    }

    @Test("Save It, turned down, keeps the typed password in its field and nowhere else; taken, it's forgotten")
    func saveKeepsTheField() async throws {
        let save = JourneyPolishFixtures.state(.savedPC) { $0.facts?.rows["C2"] = JourneyFixtures.row("C2", .fixable("No saved PC")) }
        let gate = AppWorkGate()
        let menu = try menuBusy(gate)
        let machine = PressMachine()
        let controller = rig(machine, save, gate: gate)
        controller.credentials.password = "invented-pw"
        controller.savePC(password: controller.credentials.password)
        #expect(controller.state.refusal?.wanted == .savePC)
        #expect(controller.credentials.password == "invented-pw")
        #expect(!String(describing: controller.state).contains("invented-pw"))

        menu.finish()
        controller.savePC(password: controller.credentials.password)
        #expect(controller.state.refusal == nil)
        #expect(controller.credentials.password.isEmpty)
        await settle(controller) { controller.state.lastEnding?.work == .savePC && controller.state.inFlight == nil }
        #expect(machine.passwords == ["invented-pw"])
        #expect(!String(describing: controller.state).contains("invented-pw"))
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
    }
}
