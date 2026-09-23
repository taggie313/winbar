import AppKit
import Foundation
import Testing
@testable import Winbar

// The setup window's runner (SetupRunner). Everything it reaches is replaced: the machine that owns
// the Context reads whatever the test says the Mac looks like and does whatever the test's body
// does; the clock, the process table and the power assertion are the test's; and the wake and the
// app's activation are posted on notification centres of the test's own. Nothing here reaches UTM,
// a VM, TCC, the keychain, the user's defaults, a real power assertion or a real notification.

// MARK: - The rig

/// A machine that reaches nothing. Its readings are `mac`, whatever step is asked for; its work
/// runs `body`, which can wait until the test lets it go.
private final class FakeMachine: SetupMachine {
    private let lock = NSLock()
    private var _mac = SetupRunner.Readings()
    private var _reads: [(step: WizardStep, after: SetupRunner.Work?, held: Int, answers: SetupFlow.Answers)] = []
    private var _performed: [SetupRunner.Work] = []
    private var _passwords: [String?] = []
    private var _judged: [SetupFlow.Facts] = []
    private var _body: (SetupRunner.Work, SetupRunner.Job) throws -> Void = { _, _ in }
    private var _onRead: (SetupRunner.Work?) -> Void = { _ in }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var mac: SetupRunner.Readings {
        get { locked { _mac } }
        set { locked { _mac = newValue } }
    }
    var body: (SetupRunner.Work, SetupRunner.Job) throws -> Void {
        get { locked { _body } }
        set { locked { _body = newValue } }
    }
    /// Runs at the start of every read, with the work the read follows: a read can wait on a gate,
    /// as the survey behind a real one waits on Windows.
    var onRead: (SetupRunner.Work?) -> Void {
        get { locked { _onRead } }
        set { locked { _onRead = newValue } }
    }
    /// Each read, with how many power assertions were held while it ran (`heldNow`).
    var reads: [(step: WizardStep, after: SetupRunner.Work?, held: Int, answers: SetupFlow.Answers)] { locked { _reads } }
    /// How many power assertions are held right now: the rig's `FakeAwake`. A read samples it,
    /// because the survey behind a read is as long a wait as any work.
    var heldNow: () -> Int = { 0 }
    var performed: [SetupRunner.Work] { locked { _performed } }
    /// What was performed apart from reads (`checkAgain`, whose work is the snapshot after it).
    var acted: [SetupRunner.Work] {
        performed.filter { if case .checkAgain = $0 { return false } else { return true } }
    }
    var passwords: [String?] { locked { _passwords } }
    /// The facts each piece of work was handed: what it was judged against.
    var judged: [SetupFlow.Facts] { locked { _judged } }

    func readings(through step: WizardStep, answers: SetupFlow.Answers, after work: SetupRunner.Work?,
                  job: SetupRunner.Job?) -> SetupRunner.Readings {
        onRead(work)
        let held = heldNow()
        return locked {
            _reads.append((step, work, held, answers))
            return _mac
        }
    }

    func perform(_ work: SetupRunner.Work, password: String?, facts: SetupFlow.Facts, job: SetupRunner.Job) throws {
        let body = locked { () -> (SetupRunner.Work, SetupRunner.Job) throws -> Void in
            _performed.append(work)
            _passwords.append(password)
            _judged.append(facts)
            return _body
        }
        try body(work, job)
    }
}

/// Stands in for `SleepAssertion`: counts what was taken and what was let go.
private final class FakeAwake {
    private let lock = NSLock()
    private var begun = 0
    private var released = 0
    private(set) var reasons: [String] = []
    private var _onRelease: (() -> Void)?

    /// Called on each release, on whatever thread lets go: a test can look at the runner at that
    /// moment, which a callback delivered on another queue can't do without racing.
    var onRelease: (() -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _onRelease
        }
        set {
            lock.lock()
            _onRelease = newValue
            lock.unlock()
        }
    }

    var held: Int {
        lock.lock()
        defer { lock.unlock() }
        return begun - released
    }
    var taken: Int {
        lock.lock()
        defer { lock.unlock() }
        return begun
    }

    func begin(_ reason: String) -> () -> Void {
        lock.lock()
        begun += 1
        reasons.append(reason)
        lock.unlock()
        return { [self] in
            lock.lock()
            released += 1
            let hook = _onRelease
            lock.unlock()
            hook?()
        }
    }
}

private final class TestClock {
    private let lock = NSLock()
    private var now = Date(timeIntervalSince1970: 1_800_000_000)
    func read() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return now
    }
    func advance(_ seconds: TimeInterval) {
        lock.lock()
        now = now.addingTimeInterval(seconds)
        lock.unlock()
    }
}

/// The process table as the test says it is: UTM's pids and the chosen VM's.
private final class ProcessTable {
    private let lock = NSLock()
    private var utm: Set<Int32> = [4242]
    private var vm: Int32? = 5151
    func read() -> (utm: Set<Int32>, vm: Int32?) {
        lock.lock()
        defer { lock.unlock() }
        return (utm, vm)
    }
    func set(utm: Set<Int32>? = nil, vm: Int32?? = nil) {
        lock.lock()
        if let utm { self.utm = utm }
        if let vm { self.vm = vm }
        lock.unlock()
    }
}

/// Collects what an attached window hears.
private final class Heard {
    private let lock = NSLock()
    private var _events: [SetupRunner.Event] = []
    func add(_ event: SetupRunner.Event) {
        lock.lock()
        _events.append(event)
        lock.unlock()
    }
    var events: [SetupRunner.Event] {
        lock.lock()
        defer { lock.unlock() }
        return _events
    }
}

/// Values noted from any thread, in order.
private final class Recorded<Value> {
    private let lock = NSLock()
    private var _values: [Value] = []
    func add(_ value: Value) {
        lock.lock()
        _values.append(value)
        lock.unlock()
    }
    var values: [Value] {
        lock.lock()
        defer { lock.unlock() }
        return _values
    }
}

/// A gate a fake body waits at until the test opens it, and a signal that it got there.
private final class Gate {
    let reached = DispatchSemaphore(value: 0)
    let open = DispatchSemaphore(value: 0)
    func wait() {
        reached.signal()
        _ = open.wait(timeout: .now() + 10)
    }
}

private struct Rig {
    let machine = FakeMachine()
    let awake = FakeAwake()
    let clock = TestClock()
    let table = ProcessTable()
    let workspace = NotificationCenter()
    let app = NotificationCenter()
    let queue = DispatchQueue(label: "winbar.tests.setup")
    let callbacks = DispatchQueue(label: "winbar.tests.setup.callbacks")
    let runner: SetupRunner

    init(mac: SetupRunner.Readings = Given.mac, workGate: AppWorkGate? = nil) {
        machine.mac = mac
        let (awake, clock, table) = (self.awake, self.clock, self.table)
        machine.heldNow = { awake.held }
        runner = SetupRunner(machine: machine, environment: SetupRunner.Environment(
            queue: queue, callbacks: callbacks, clock: { clock.read() }, keepAwake: { awake.begin($0) },
            processes: { _ in table.read() }, workspace: workspace, app: app, workGate: workGate))
    }

    /// Runs `work` and waits for its ending.
    @discardableResult
    func finish(_ work: SetupRunner.Work, password: String? = nil) -> SetupRunner.Ending? {
        let ended = DispatchSemaphore(value: 0)
        var ending: SetupRunner.Ending?
        let refusal = runner.run(work, password: password, done: { result in
            ending = result
            ended.signal()
        })
        guard refusal == nil, ended.wait(timeout: .now() + 10) == .success else { return nil }
        return ending
    }

    /// Starts `work` and returns without waiting; the ending is signalled on `ended`.
    func start(_ work: SetupRunner.Work, ended: DispatchSemaphore? = nil,
               ending: ((SetupRunner.Ending) -> Void)? = nil) -> SetupRunner.Refusal? {
        runner.run(work, done: { result in
            ending?(result)
            ended?.signal()
        })
    }

    /// Lets everything already queued on the runner's queue and the callback queue run, including a
    /// fresh snapshot that one of them queued.
    func settle() {
        for _ in 0..<3 {
            queue.sync {}
            callbacks.sync {}
        }
    }

    func wake() { workspace.post(name: NSWorkspace.didWakeNotification, object: nil) }
    func comeBack() { app.post(name: NSApplication.didBecomeActiveNotification, object: nil) }
}

/// Invented machines and people only.
private enum Given {
    static let winlab = VMInfo(id: "5A1C0DE0-0000-4000-8000-000000000001", name: "winlab01", status: "started",
                               backend: "qemu", icon: "windows", architecture: "aarch64")
    static let atelier = VMInfo(id: "5A1C0DE0-0000-4000-8000-000000000002", name: "atelier", status: "stopped",
                                backend: "qemu", icon: "windows", architecture: "aarch64")

    /// A Mac part way through: UTM answering, winlab01 chosen and running, G1 fixable, the
    /// certificate made but not trusted, vCPUs staged for the restart.
    static var mac: SetupRunner.Readings {
        var mac = SetupRunner.Readings()
        mac.utm = .installed(version: "4.7.5")
        mac.utmAnswers = .answered
        mac.windowsApp = .installed(version: "11.1.10")
        mac.vms = .success([winlab, atelier])
        mac.chosenVM = "winlab01"
        mac.guestAnswers = true
        mac.statuses = ["G0": .ok("Windows 11 Pro"), "G1": .fixable("Balanced; recommended High performance"),
                        "G7": .ok("made for winlab01.local"), "H7": .fixable("not trusted for winlab01.local")]
        mac.rdpHost = "winlab01.local"
        mac.rdpUser = "rosa"
        mac.pending = ConfigChanges(cpuCores: 6)
        return mac
    }

    static func mac(_ change: (inout SetupRunner.Readings) -> Void) -> SetupRunner.Readings {
        var mac = Given.mac
        change(&mac)
        return mac
    }

    static let stamp = SetupFlow.Stamp(taken: Date(timeIntervalSince1970: 1_800_000_000), utmPIDs: [4242], vmPID: 5151)

    static func facts(_ readings: SetupRunner.Readings = Given.mac, stamp: SetupFlow.Stamp = Given.stamp,
                      previous: SetupFlow.Facts? = nil, after: SetupRunner.Performed? = nil) -> SetupFlow.Facts {
        SetupRunner.facts(from: readings, stamp: stamp, answers: SetupFlow.Answers(started: true), previous: previous,
                          after: after)
    }
}

/// Every kind of work, one of each. `covers` has no default, so a new kind doesn't compile until it
/// has been added here too — and so to every test that goes through them all.
private let everyWork: [SetupRunner.Work] = [
    .checkAgain(.lookAround), .installUTM, .installWindowsApp, .settleUTM, .chooseVM("winlab01", id: Given.winlab.id),
    .startVM("winlab01"), .survey, .fix(checkID: "G1"), .fixEverything, .recordDone(checkID: "H6"),
    .trustCertificate, .savePC, .connect, .applyChanges, .guide(checkID: "H6"), .keepBitLocker, .discardChanges(checkID: nil),
]

private func covers(_ work: SetupRunner.Work) -> Bool {
    switch work {
    case .checkAgain, .installUTM, .installWindowsApp, .settleUTM, .chooseVM, .startVM, .survey, .fix, .fixEverything,
         .recordDone, .trustCertificate, .savePC, .connect, .applyChanges, .guide, .keepBitLocker, .discardChanges:
        return true
    }
}

// MARK: - One at a time

@Suite("The runner does one thing at a time, and says what it is")
struct SetupRunnerOneAtATime {
    /// Refused, not queued: a Fix queued behind a five-minute wait would run against facts nobody
    /// had looked at since. The control is the performed list: a queued Fix would appear in it once
    /// the certificate finished.
    @Test("A second press while work is in flight is refused, and never runs")
    func refusedNotQueued() throws {
        let rig = Rig()
        let gate = Gate()
        rig.machine.body = { work, _ in if work == .trustCertificate { gate.wait() } }
        let ended = DispatchSemaphore(value: 0)
        #expect(rig.start(.trustCertificate, ended: ended) == nil)
        #expect(gate.reached.wait(timeout: .now() + 5) == .success)

        let refusal = try #require(rig.runner.run(.fix(checkID: "G1")))
        #expect(refusal.wanted == .fix(checkID: "G1"))
        #expect(refusal.inFlight.work == .trustCertificate)

        gate.open.signal()
        #expect(ended.wait(timeout: .now() + 5) == .success)
        rig.settle()
        #expect(rig.machine.acted == [.trustCertificate])
        // And once it has ended, the next press goes ahead.
        #expect(rig.finish(.fix(checkID: "G1"))?.outcome == .finished)
    }

    /// Two quick presses before the queue has picked up the first. The work is in flight from the
    /// moment `run` returns, not from the moment the queue gets to it: were it marked on the queue,
    /// both presses would be accepted, queued, and carried out one after the other.
    @Test("A second press before the queue has started the first is refused too")
    func refusedBeforeTheQueueStarts() throws {
        let rig = Rig()
        _ = try #require(rig.finish(.checkAgain(.tune)))
        let busy = Gate()
        rig.queue.async { busy.wait() }                 // the queue is taken; nothing of the runner's has run
        #expect(busy.reached.wait(timeout: .now() + 5) == .success)

        let ended = DispatchSemaphore(value: 0)
        #expect(rig.start(.fix(checkID: "G1"), ended: ended) == nil)
        let refusal = try #require(rig.start(.survey))
        #expect(refusal.inFlight.work == .fix(checkID: "G1"))

        busy.open.signal()
        #expect(ended.wait(timeout: .now() + 5) == .success)
        rig.settle()
        #expect(rig.machine.acted == [.fix(checkID: "G1")])
    }

    /// The read after work is part of the work. After `.survey` it *is* the work — a survey of
    /// Windows, up to 180 seconds by the clock — and a guest Fix's re-read is one too. A Fix let in
    /// then would wait behind it on the queue and run against facts nobody had looked at since it was
    /// pressed, which is the queueing the refusal exists to prevent. So the refusal lasts until the
    /// ending is handed out, not until `perform` returns.
    @Test("The refusal lasts through the read after the work, not only the work")
    func refusedThroughTheReread() throws {
        let rig = Rig()
        _ = try #require(rig.finish(.checkAgain(.tune)))
        let surveying = Gate()
        rig.machine.onRead = { after in if after == .survey { surveying.wait() } }
        let ended = DispatchSemaphore(value: 0)
        #expect(rig.start(.survey, ended: ended) == nil)
        #expect(surveying.reached.wait(timeout: .now() + 5) == .success)

        let refusal = rig.runner.run(.fix(checkID: "G1"))
        #expect(refusal?.wanted == .fix(checkID: "G1"))
        #expect(refusal?.inFlight.work == .survey)
        #expect(rig.runner.inFlight?.work == .survey)

        surveying.open.signal()
        #expect(ended.wait(timeout: .now() + 5) == .success)
        rig.settle()
        #expect(rig.machine.acted == [.survey])
    }

    /// Critique §3: a closed wizard mustn't leave a window whose every button says "busy". The
    /// refusal says what is in flight and, for the certificate, where to look.
    @Test("A refusal names the work in flight, and where to look when it waits on a person")
    func refusalNames() throws {
        let rig = Rig()
        let gate = Gate()
        rig.machine.body = { _, _ in gate.wait() }
        let ended = DispatchSemaphore(value: 0)
        _ = rig.start(.trustCertificate, ended: ended)
        #expect(gate.reached.wait(timeout: .now() + 5) == .success)
        let certificate = try #require(rig.runner.run(.survey)).description
        #expect(certificate.contains("waiting for you to approve the certificate in the macOS dialog"))
        #expect(certificate.contains("behind other windows"))
        #expect(certificate.contains(SetupCopy.Working.bStopWaiting))
        #expect(!certificate.localizedCaseInsensitiveContains("busy"))
        gate.open.signal()
        #expect(ended.wait(timeout: .now() + 5) == .success)

        rig.settle()
        let second = Gate()
        rig.machine.body = { _, _ in second.wait() }
        _ = rig.start(.applyChanges, ended: ended)
        #expect(second.reached.wait(timeout: .now() + 5) == .success)
        let restart = try #require(rig.runner.run(.savePC)).description
        #expect(restart.contains("restarting “winlab01”"))
        #expect(restart.contains("once that's done"))
        second.open.signal()
        #expect(ended.wait(timeout: .now() + 5) == .success)
    }

    /// The window is closed during the certificate's wait and opened again: it attaches, learns what
    /// is in flight and what it waits for, and hears the ending — nothing lost between the two.
    @Test("A reopened window attaches to the work in flight, says what it waits for, and hears it end")
    func attachAndHear() throws {
        let rig = Rig()
        let gate = Gate()
        rig.machine.body = { _, job in
            job.say(SetupCopy.Certificate.approval)
            gate.wait()
        }
        let ended = DispatchSemaphore(value: 0)
        _ = rig.start(.trustCertificate, ended: ended)
        #expect(gate.reached.wait(timeout: .now() + 5) == .success)
        rig.callbacks.sync {}

        let heard = Heard()
        let (inFlight, _, _, observation) = rig.runner.attach { heard.add($0) }
        let attached = try #require(inFlight)
        #expect(attached.work == .trustCertificate)
        #expect(attached.waitingFor == .certificateApproval)
        #expect(attached.canStopWaiting)
        #expect(attached.line == SetupCopy.Certificate.approval)
        #expect(SetupCopy.Working.waiting(.certificateApproval).contains("approve the certificate in the macOS dialog"))

        gate.open.signal()
        #expect(ended.wait(timeout: .now() + 5) == .success)
        rig.settle()
        #expect(heard.events.contains { if case .ended(let ending) = $0 { return ending.work == .trustCertificate }
                                        return false })
        #expect(rig.runner.inFlight == nil)
        withExtendedLifetime(observation) {}
    }

    /// The way out for a person who can't find SecurityAgent's dialog. The fake waits for exactly
    /// what the live machine's `abort` waits for: the job being cancelled.
    @Test("Stop Waiting ends the certificate's wait, and the next press goes ahead")
    func stopWaiting() throws {
        let rig = Rig()
        let waiting = DispatchSemaphore(value: 0)
        rig.machine.body = { _, job in
            waiting.signal()
            let deadline = Date().addingTimeInterval(10)
            while !job.isCancelled, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            try job.checkCancellation()
        }
        let ended = DispatchSemaphore(value: 0)
        var ending: SetupRunner.Ending?
        _ = rig.start(.trustCertificate, ended: ended) { ending = $0 }
        #expect(waiting.wait(timeout: .now() + 5) == .success)
        #expect(rig.runner.stopWaiting())
        #expect(ended.wait(timeout: .now() + 5) == .success)
        #expect(ending?.outcome == .cancelled)
        rig.settle()
        rig.machine.body = { _, _ in }
        #expect(rig.finish(.fix(checkID: "G1"))?.outcome == .finished)
    }

    /// Only a wait Winbar can end is offered a way to end it; a Homebrew install half done is not.
    @Test("Stop Waiting leaves work alone that can't stop waiting")
    func stopWaitingOnlyWaits() {
        let rig = Rig(mac: Given.mac { $0.utm = .missing; $0.utmAnswers = nil; $0.vms = nil })
        let gate = Gate()
        var cancelled: Bool?
        rig.machine.body = { _, job in
            gate.wait()
            cancelled = job.isCancelled
        }
        let ended = DispatchSemaphore(value: 0)
        var ending: SetupRunner.Ending?
        _ = rig.start(.installUTM, ended: ended) { ending = $0 }
        #expect(gate.reached.wait(timeout: .now() + 5) == .success)
        #expect(!rig.runner.stopWaiting())
        gate.open.signal()
        #expect(ended.wait(timeout: .now() + 5) == .success)
        #expect(cancelled == false)
        #expect(ending?.outcome == .finished)
        #expect(everyWork.filter(\.canStopWaiting) == [.trustCertificate])
    }

    @Test("Progress reaches the run's own handler and every attached window, in order")
    func progress() {
        let rig = Rig()
        rig.machine.body = { _, job in
            job.say("Asking Homebrew: brew install --cask utm")
            job.say("==> Downloading UTM.dmg")
        }
        rig.machine.mac = Given.mac { $0.utm = .missing; $0.utmAnswers = nil; $0.vms = nil }
        let heard = Heard()
        let observation = rig.runner.attach { heard.add($0) }.observation
        var lines: [String] = []
        let ended = DispatchSemaphore(value: 0)
        _ = rig.runner.run(.installUTM, progress: { lines.append($0) }) { _ in ended.signal() }
        #expect(ended.wait(timeout: .now() + 5) == .success)
        rig.settle()
        #expect(lines == ["Asking Homebrew: brew install --cask utm", "==> Downloading UTM.dmg"])
        let progressed = heard.events.compactMap { event -> String? in
            if case .progressed(let flight) = event { return flight.line }
            return nil
        }
        #expect(progressed == lines)
        guard case .started? = heard.events.first, case .ended? = heard.events.last else {
            Issue.record("expected started … ended, heard \(heard.events)")
            return
        }
        withExtendedLifetime(observation) {}
    }

    /// A window closed while the work ran hears none of what it said after, and a failure's last
    /// lines are its own ("its own output is above"), so the ending carries them: kept the way the
    /// window keeps them, with no window attached at all.
    @Test("An ending carries what its work said, kept as the window keeps it; a read's carries nothing")
    func endingKeepsOutput() {
        let rig = Rig()
        rig.machine.mac = Given.mac { $0.utm = .missing; $0.utmAnswers = nil; $0.vms = nil }
        let said = ["Asking Homebrew: brew install --cask utm", "==> Downloading UTM.dmg",
                    DependencyCopy.downloadProgress(.utm, done: 12 << 20, total: 250 << 20),
                    DependencyCopy.downloadProgress(.utm, done: 250 << 20, total: 250 << 20),
                    "curl: (56) Recv failure: Connection reset by peer"]
        rig.machine.body = { work, job in
            guard work == .installUTM else { return }
            said.forEach(job.say)
            throw WinbarError("Homebrew couldn't install UTM", "It stopped with exit status 1; its own output is above.")
        }
        let failed = rig.finish(.installUTM)
        #expect(failed?.lines == said.reduce([]) { SetupWindowState.adding($1, to: $0) })
        #expect(failed?.lines.last == said.last && failed?.lines.count == 4)
        rig.machine.body = { _, job in job.say("Asking Windows…") }
        #expect(rig.finish(.checkAgain(.lookAround))?.lines == [])
    }
}

// MARK: - Sleep

@Suite("Long work keeps the Mac awake for exactly as long as it runs")
struct SetupRunnerSleep {
    /// The work someone presses and walks away from holds it; the waits on a person don't — a Mac
    /// nobody is at is exactly where a certificate prompt's wait should end.
    @Test("Which work holds the power assertion")
    func whichWork() {
        let holds = everyWork.filter(\.holdsMacAwake)
        #expect(holds == [.installUTM, .startVM("winlab01"), .survey, .fix(checkID: "G1"), .fixEverything, .applyChanges])
        #expect(everyWork.allSatisfy(covers))
    }

    /// Step 7's restart is the critique's worst case: minutes of shutdown, UTM quit, write, verify and
    /// start. The assertion is held inside the work and let go before anyone hears it ended.
    ///
    /// "Before" is pinned at the release itself, not in `done`: `done` runs on the callback queue,
    /// and would read 0 held whichever order the runner let go and handed out the ending in, once the
    /// queue got round to it. At the release the work must still be in flight — `store` is what
    /// clears it, in the same breath as it hands the ending out.
    @Test("The restart holds it while it runs, and lets it go before the ending is delivered")
    func heldDuring() {
        let rig = Rig()
        rig.finish(.checkAgain(.finish))
        let taken = rig.awake.taken
        var heldInside = -1
        rig.machine.body = { _, _ in heldInside = rig.awake.held }
        let runner = rig.runner
        let inFlightAtRelease = Recorded<SetupRunner.Work?>()
        rig.awake.onRelease = { [weak runner] in inFlightAtRelease.add(runner?.inFlight?.work) }
        var heldAtEnd = -1
        let ended = DispatchSemaphore(value: 0)
        _ = rig.runner.run(.applyChanges, done: { _ in
            heldAtEnd = rig.awake.held
            ended.signal()
        })
        #expect(ended.wait(timeout: .now() + 5) == .success)
        rig.awake.onRelease = nil
        #expect(heldInside == 1)
        #expect(heldAtEnd == 0)
        #expect(inFlightAtRelease.values == [.applyChanges], "nil: let go after the ending was handed out")
        #expect(rig.awake.taken == taken + 1)
        #expect(rig.awake.reasons.last == "Winbar is restarting “winlab01”")
    }

    /// `.survey` does nothing itself: it makes the read after it ask Windows again, and that read
    /// is the survey — up to three minutes of waiting on Windows by the clock. A guest Fix's re-read
    /// surveys too, and a restart pressed on a stale snapshot reads the Mac again before it's judged.
    /// All of it is the work's, so all of it is inside the work's one assertion. The control is the
    /// `held` each read sampled: an assertion around `perform` alone reads 0 in every one of them.
    @Test("The reads around long work are inside its assertion: the survey's, a Fix's, a stale restart's")
    func readsHeld() throws {
        let rig = Rig()
        _ = try #require(rig.finish(.checkAgain(.tune)))

        for work: SetupRunner.Work in [.survey, .fix(checkID: "G1"), .fixEverything] {
            let (reads, taken) = (rig.machine.reads.count, rig.awake.taken)
            #expect(rig.finish(work)?.outcome == .finished, "\(work)")
            #expect(rig.machine.reads.dropFirst(reads).map(\.held) == [1], "\(work)")
            #expect(rig.awake.taken == taken + 1, "\(work)")
            rig.settle()
        }

        rig.table.set(utm: [4343])                       // stale: the restart reads the Mac again first
        let (reads, taken) = (rig.machine.reads.count, rig.awake.taken)
        #expect(rig.finish(.applyChanges)?.outcome == .finished)
        #expect(rig.machine.reads.dropFirst(reads).map(\.held) == [1, 1])
        #expect(rig.awake.taken == taken + 1)            // one assertion, from the first read to the last
        #expect(rig.awake.held == 0)
    }

    /// Check Again on the tune step, and the re-read after a wake, survey Windows as much as the
    /// **Survey** button does. The first look reads app bundles and asks UTM a question: no survey,
    /// and no assertion.
    @Test("A read that reaches tune holds it by itself; one that stops short of it doesn't")
    func readsThatSurvey() {
        let rig = Rig()
        rig.finish(.checkAgain(.lookAround))
        rig.finish(.checkAgain(.vm))
        #expect(rig.awake.taken == 0)
        #expect(rig.machine.reads.map(\.held) == [0, 0])

        rig.finish(.checkAgain(.tune))
        #expect(rig.machine.reads.last?.held == 1)
        #expect(rig.awake.taken == 1)
        #expect(rig.awake.reasons.last == "Winbar is looking at what's on this Mac")

        let observation = rig.runner.attach { _ in }.observation
        rig.clock.advance(3600)
        rig.wake()
        rig.settle()
        #expect(rig.machine.reads.count == 4)
        #expect(rig.machine.reads.last?.held == 1)
        #expect(rig.awake.taken == 2)
        #expect(rig.awake.held == 0)
        withExtendedLifetime(observation) {}
    }

    /// Every way out of the work: a Winbar failure, a stop, anything else thrown.
    @Test("It is let go when the work fails, stops, or throws anything at all",
          arguments: ["winbar", "stop", "other"])
    func releasedOnEveryExit(_ way: String) {
        struct Odd: Error {}
        let rig = Rig()
        rig.machine.body = { _, _ in
            switch way {
            case "winbar": throw WinbarError("UTM didn't quit", "Quit UTM yourself, then try again.")
            case "stop": throw CancellationError()
            default: throw Odd()
            }
        }
        let ending = rig.finish(.applyChanges)
        #expect(rig.awake.taken == 1)
        #expect(rig.awake.held == 0)
        switch way {
        case "winbar": #expect(ending?.outcome == .failed(SetupRunner.Problem(title: "UTM didn't quit",
                                                                              detail: "Quit UTM yourself, then try again.")))
        case "stop": #expect(ending?.outcome == .cancelled)
        default: #expect({ if case .failed? = ending?.outcome { return true }; return false }())
        }
    }

    /// A Mac nobody is at is exactly where a certificate prompt's wait should end. The read after it
    /// is another matter: at step 4 a read reaches tune, and can survey.
    @Test("Work that waits on a person never holds it while it waits")
    func notWhileWaiting() {
        let rig = Rig()
        rig.finish(.checkAgain(.certificate))
        var heldInside = -1
        rig.machine.body = { _, _ in heldInside = rig.awake.held }
        #expect(rig.finish(.trustCertificate)?.outcome == .finished)
        #expect(heldInside == 0)
        #expect(rig.machine.reads.last?.held == 1)
        #expect(rig.awake.held == 0)
    }

    /// The fresh read that overtook it is the restart's, and held; nothing after it is.
    @Test("A restart the Mac has overtaken holds it for the read that said so, and does nothing")
    func overtakenLetsGo() {
        let rig = Rig()
        rig.finish(.checkAgain(.finish))
        rig.machine.mac = Given.mac { $0.pending = ConfigChanges() }
        rig.table.set(utm: [4343])                       // stale, so the restart is judged afresh
        let (reads, taken) = (rig.machine.reads.count, rig.awake.taken)
        #expect(rig.finish(.applyChanges)?.outcome == .overtaken)
        #expect(rig.machine.acted.isEmpty)
        #expect(rig.machine.reads.dropFirst(reads).map(\.held) == [1])
        #expect(rig.awake.taken == taken + 1)
        #expect(rig.awake.held == 0)
    }

    /// A closed lid still sleeps the Mac, and every wait is wall-clock: the ending says so.
    @Test("An ending says the Mac slept while the work ran, and only then")
    func sleptDuring() {
        let rig = Rig()
        let gate = Gate()
        rig.machine.body = { _, _ in gate.wait() }
        let ended = DispatchSemaphore(value: 0)
        var ending: SetupRunner.Ending?
        _ = rig.start(.applyChanges, ended: ended) { ending = $0 }
        #expect(gate.reached.wait(timeout: .now() + 5) == .success)
        rig.clock.advance(3600)
        rig.wake()
        gate.open.signal()
        #expect(ended.wait(timeout: .now() + 5) == .success)
        #expect(ending?.slept == true)

        rig.settle()
        rig.clock.advance(60)
        rig.machine.body = { _, _ in }
        #expect(rig.finish(.applyChanges)?.slept == false)
    }
}

// MARK: - Coming back to step 7

@Suite("A window coming back to step 7 is told where the restart stands")
struct SetupRunnerRestartReport {
    static let flight = SetupRunner.InFlight(work: .applyChanges, started: Given.stamp.taken, vm: "winlab01",
                                             line: "Shutting down winlab01…")

    static func facts(running: Bool, owed: Bool) -> SetupFlow.Facts {
        var mac = Given.mac
        mac.pendingRestart = owed ? UTMRestart(vm: "winlab01", pids: [4242]) : nil
        return Given.facts(mac, stamp: SetupFlow.Stamp(taken: Given.stamp.taken, utmPIDs: [4242],
                                                       vmPID: running ? 5151 : nil))
    }

    static func ending(_ outcome: SetupRunner.Outcome, running: Bool, owed: Bool, slept: Bool = false) -> SetupRunner.Ending {
        SetupRunner.Ending(work: .applyChanges, outcome: outcome, facts: facts(running: running, owed: owed), slept: slept,
                           started: Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test("Still going: the step shows the restart, with its latest line")
    func running() {
        #expect(SetupRunner.restartReport(inFlight: Self.flight, last: nil, facts: Self.facts(running: false, owed: true))
                    == .running(Self.flight))
    }

    /// The critique's case: the lid closed during the restart, the display change went in, UTM never
    /// quit. The VM is off and the next start restarts UTM first — said, not sprung.
    @Test("Off with a UTM restart owed, whether or not the Mac slept, and after a relaunch too")
    func owed() {
        let failed = SetupRunner.Outcome.failed(SetupRunner.Problem(title: "winlab01 didn't start"))
        #expect(SetupRunner.restartReport(inFlight: nil, last: Self.ending(failed, running: false, owed: true, slept: true),
                                          facts: Self.facts(running: false, owed: true))
                    == .offWithUTMRestartOwed(vm: "winlab01", slept: true))
        #expect(SetupRunner.restartReport(inFlight: nil, last: nil, facts: Self.facts(running: false, owed: true))
                    == .offWithUTMRestartOwed(vm: "winlab01", slept: false))
        // The control: the same VM, off, with nothing owed, is an ordinary start.
        #expect(SetupRunner.restartReport(inFlight: nil, last: Self.ending(failed, running: false, owed: false, slept: true),
                                          facts: Self.facts(running: false, owed: false))
                    == .off(vm: "winlab01", slept: true))
    }

    @Test("A failure that left the VM running, a clean finish, and nothing at all")
    func theRest() {
        let problem = SetupRunner.Problem(title: "Stop your other VMs first")
        #expect(SetupRunner.restartReport(inFlight: nil, last: Self.ending(.failed(problem), running: true, owed: false),
                                          facts: Self.facts(running: true, owed: false)) == .failed(problem, slept: false))
        #expect(SetupRunner.restartReport(inFlight: nil, last: Self.ending(.finished, running: true, owed: false),
                                          facts: Self.facts(running: true, owed: false)) == .none)
        #expect(SetupRunner.restartReport(inFlight: nil, last: nil, facts: Self.facts(running: false, owed: false)) == .none)
    }

    /// Owed while a UTM process the display change was sent to is still running: once it has quit
    /// (or UTM restarted), the next launch builds a fresh window and nothing is owed.
    @Test("A restart is owed while UTM is the one the display change was sent to")
    func owedMeans() {
        var mac = Given.mac
        mac.pendingRestart = UTMRestart(vm: "winlab01", pids: [4242, 4243])
        let stamp = { (utm: Set<Int32>) in SetupFlow.Stamp(taken: Given.stamp.taken, utmPIDs: utm, vmPID: nil) }
        #expect(Given.facts(mac, stamp: stamp([4243])).utmRestartOwed)
        #expect(!Given.facts(mac, stamp: stamp([5555])).utmRestartOwed)
        #expect(!Given.facts(mac, stamp: stamp([])).utmRestartOwed)
        mac.pendingRestart = nil
        #expect(!Given.facts(mac, stamp: stamp([4242])).utmRestartOwed)
    }

    @Test("The words for it name the VM as it is, and the rule the start keeps")
    func words() {
        let owed = String(SetupCopy.Working.restartOwed(vm: "winlab01 *beta*").characters)
        #expect(owed.contains("“winlab01 *beta*” is off"))
        #expect(owed.contains("Start It quits UTM first, and only while no other VM is running in it"))
        let slept = String(SetupCopy.Working.slept(while: "restarting “winlab01”").characters)
        #expect(slept.contains("while Winbar was restarting “winlab01”"))
    }
}

// MARK: - Freshness

@Suite("A snapshot the Mac has moved on from is recognisably stale, and never acted on")
struct SetupRunnerFreshness {
    @Test("An automatic read is visible, blocks approval honestly, and survives reopening")
    func visibleBackgroundRead() throws {
        let workGate = AppWorkGate()
        let rig = Rig(workGate: workGate)
        let old = try #require(rig.finish(.checkAgain(.certificate))?.facts)
        let heard = Heard()
        let observation = rig.runner.attach { heard.add($0) }.observation
        let gate = Gate()
        rig.machine.onRead = { _ in gate.wait() }
        rig.clock.advance(90)
        rig.comeBack()
        #expect(gate.reached.wait(timeout: .now() + 3) == .success)
        let flight = try #require(rig.runner.inFlight)
        #expect(flight.work == .checkAgain(.certificate))
        #expect(rig.runner.run(.trustCertificate)?.inFlight == flight)
        let reopened = rig.runner.attach { _ in }
        #expect(reopened.inFlight == flight)
        rig.callbacks.sync {}
        #expect(heard.events.contains { if case .refreshing = $0 { return true }; return false })
        var state = SetupFixtures.state(.certificate, facts: old)
        state.refusal = .init(wanted: .trustCertificate, inFlight: flight)
        state = state.applying(.refreshing(flight))
        #expect(state.inFlight != nil && state.refusal == nil)
        rig.machine.onRead = { _ in }
        gate.open.signal()
        rig.settle()
        #expect(rig.runner.inFlight == nil)
        let fresh = try #require(rig.runner.latestFacts)
        state.refusal = .init(wanted: .trustCertificate, inFlight: flight)
        state = state.applying(.refreshed(fresh))
        #expect(state.inFlight == nil && state.refusal == nil)
        #expect(rig.finish(.trustCertificate)?.outcome == .finished)
        withExtendedLifetime((observation, reopened.observation)) {}
    }

    @Test("Waking makes the snapshot stale, says so, and a fresh one follows")
    func wake() throws {
        let rig = Rig()
        let old = try #require(rig.finish(.checkAgain(.tune))?.facts)
        #expect(rig.runner.staleness(of: old) == nil)
        let heard = Heard()
        let observation = rig.runner.attach { heard.add($0) }.observation

        rig.clock.advance(8 * 3600)
        rig.wake()
        #expect(rig.runner.staleness(of: old) == .slept)
        rig.settle()
        guard case .stale(.slept)? = heard.events.first, case .refreshing? = heard.events.dropFirst().first,
              case .refreshed(let fresh)? = heard.events.last else {
            Issue.record("expected stale, refreshing, refreshed, heard \(heard.events)")
            return
        }
        #expect(fresh.stamp?.taken == rig.clock.read())
        #expect(rig.runner.staleness(of: fresh) == nil)
        #expect(rig.machine.reads.last?.after == nil)       // everything, not what one piece of work touched
        withExtendedLifetime(observation) {}
    }

    /// Back from System Settings, the App Store or Windows itself: anything can have changed there.
    @Test("Coming back to the front does the same")
    func cameBack() throws {
        let rig = Rig()
        let old = try #require(rig.finish(.checkAgain(.savedPC))?.facts)
        let observation = rig.runner.attach { _ in }.observation
        let reads = rig.machine.reads.count
        rig.clock.advance(90)
        rig.comeBack()
        #expect(rig.runner.staleness(of: old) == .reactivated)
        rig.settle()
        #expect(rig.machine.reads.count == reads + 1)
        #expect(rig.runner.latestFacts.map { rig.runner.staleness(of: $0) } == .some(nil))
        withExtendedLifetime(observation) {}
    }

    /// Once the runner exists it hears every wake, every activation and every process change for the
    /// rest of the session, window or no window. A re-read at step 6 is a guest survey, a second
    /// Winbar launched for the self-test, Windows App's CLI, an Apple Event and a network probe —
    /// all for nobody. With no window attached the snapshot is only marked stale; the first window
    /// to attach hears so and gets one fresh read.
    @Test("With no window attached, the snapshot is only marked stale, and attaching reads it once")
    func nobodyWatching() throws {
        let rig = Rig()
        let old = try #require(rig.finish(.checkAgain(.connect))?.facts)
        let reads = rig.machine.reads.count
        rig.clock.advance(3600)
        rig.wake()
        rig.comeBack()
        rig.table.set(vm: .some(5252))                   // the VM restarted underneath
        rig.runner.processTableTick()
        rig.settle()
        #expect(rig.machine.reads.count == reads)
        #expect(rig.runner.staleness(of: old) == .slept)

        let heard = Heard()
        let (_, latest, _, observation) = rig.runner.attach { heard.add($0) }
        #expect(latest == old)
        rig.settle()
        #expect(rig.machine.reads.count == reads + 1)
        #expect(rig.machine.reads.last?.after == nil)
        guard case .stale(.slept)? = heard.events.first, case .refreshing? = heard.events.dropFirst().first,
              case .refreshed(let fresh)? = heard.events.last else {
            Issue.record("expected stale, refreshing, refreshed, heard \(heard.events)")
            return
        }
        #expect(rig.runner.staleness(of: fresh) == nil)
        #expect(heard.events.count == 3)

        // A second window attaching to a fresh snapshot reads nothing more.
        let second = rig.runner.attach { _ in }.observation
        rig.settle()
        #expect(rig.machine.reads.count == reads + 1)
        withExtendedLifetime((observation, second)) {}
    }

    /// The menu's five-second tick is the only timer. It reads nothing while nothing moved — a
    /// snapshot every five seconds would be a survey of Windows every five seconds.
    @Test("The menu's tick re-reads only when UTM's or the VM's processes moved")
    func tick() throws {
        let rig = Rig()
        let old = try #require(rig.finish(.checkAgain(.tune))?.facts)
        let heard = Heard()
        let observation = rig.runner.attach { heard.add($0) }.observation
        let reads = rig.machine.reads.count
        for _ in 0..<3 { rig.runner.processTableTick() }
        rig.settle()
        #expect(rig.machine.reads.count == reads)
        #expect(heard.events.isEmpty)

        rig.table.set(utm: [4343])                       // UTM restarted underneath the window
        rig.runner.processTableTick()
        #expect(rig.runner.staleness(of: old) == .utmChanged)
        rig.settle()
        #expect(rig.machine.reads.count == reads + 1)
        guard case .stale(.utmChanged)? = heard.events.first else {
            Issue.record("expected stale(utmChanged), heard \(heard.events)")
            return
        }
        rig.table.set(vm: .some(nil))                    // and then the VM stopped
        rig.runner.processTableTick()
        rig.settle()
        #expect(heard.events.contains(.stale(.vmChanged)))
        withExtendedLifetime(observation) {}
    }

    /// The critique's step-4-overnight case, in miniature: the snapshot said G1 needed fixing, UTM
    /// restarted since, and on the Mac as it is now G1 is fine. The Fix isn't carried out.
    @Test("Work pressed on a stale snapshot is judged afresh, and not done when the Mac overtook it")
    func overtaken() throws {
        let rig = Rig()
        _ = try #require(rig.finish(.checkAgain(.tune)))
        rig.machine.mac = Given.mac { $0.statuses["G1"] = .ok("High performance") }
        rig.table.set(utm: [4343])                       // no tick yet: the work notices by itself
        let ending = try #require(rig.finish(.fix(checkID: "G1")))
        #expect(ending.outcome == .overtaken)
        #expect(rig.machine.acted.isEmpty)
        #expect(ending.facts.kind("G1") == .ok)
        #expect(ending.facts.stamp?.utmPIDs == [4343])
    }

    @Test("…and done when fresh facts still ask for it")
    func stillApplies() throws {
        let rig = Rig()
        _ = try #require(rig.finish(.checkAgain(.tune)))
        rig.table.set(utm: [4343])
        #expect(rig.finish(.fix(checkID: "G1"))?.outcome == .finished)
        #expect(rig.machine.acted == [.fix(checkID: "G1")])
    }

    /// The window says "Not now" to G1 and presses Fix Everything in the same breath: the answers
    /// arrive with the press. The snapshot the runner holds still carries the answers from before,
    /// so judging with its answers would fix the row the person had just chosen to leave alone.
    @Test("Work is judged with the answers handed in with it, not the last snapshot's")
    func judgedWithNewAnswers() throws {
        let rig = Rig(mac: Given.mac { $0.statuses["G3"] = .fixable("animations on") })
        let old = try #require(rig.finish(.checkAgain(.tune))?.facts)
        #expect(SetupFlow.fixEverything(old) == ["G1", "G3"])

        let answers = SetupFlow.Answers(started: true, leftAlone: ["G1"])
        let ended = DispatchSemaphore(value: 0)
        #expect(rig.runner.run(.fixEverything, answers: answers, done: { _ in ended.signal() }) == nil)
        #expect(ended.wait(timeout: .now() + 5) == .success)
        let judged = try #require(rig.machine.judged.last)
        #expect(judged.answers == answers.forVM(judged.target))
        #expect(SetupFlow.fixEverything(judged) == ["G3"])
        rig.settle()

        // And with nothing left for it to do on the new answers, it isn't done at all.
        let both = SetupFlow.Answers(started: true, leftAlone: ["G1", "G3"])
        let performed = rig.machine.performed.count
        var ending: SetupRunner.Ending?
        #expect(rig.runner.run(.fixEverything, answers: both, done: { ending = $0; ended.signal() }) == nil)
        #expect(ended.wait(timeout: .now() + 5) == .success)
        #expect(ending?.outcome == .overtaken)
        #expect(rig.machine.performed.count == performed)
    }

    /// Re-reading costs a survey of Windows, so a fresh snapshot isn't read twice: once after the
    /// work, and only what the work can have changed.
    @Test("Work on a fresh snapshot reads once, after, and only what it touched")
    func freshReadsOnce() throws {
        let rig = Rig()
        _ = try #require(rig.finish(.checkAgain(.tune)))
        let reads = rig.machine.reads.count
        #expect(rig.finish(.fix(checkID: "G1"))?.outcome == .finished)
        #expect(rig.machine.reads.count == reads + 1)
        #expect(rig.machine.reads.last?.after == .fix(checkID: "G1"))
    }

    /// Work in flight ends with a snapshot of its own, read after whatever happened; a second one
    /// queued behind it would only read the Mac twice. That read is of everything, since the partial
    /// one would keep caches from before the wake.
    @Test("A wake during work queues no second read; the ending reads everything")
    func wakeDuringWork() throws {
        let rig = Rig()
        _ = try #require(rig.finish(.checkAgain(.tune)))
        let reads = rig.machine.reads.count
        let gate = Gate()
        rig.machine.body = { _, _ in gate.wait() }
        let ended = DispatchSemaphore(value: 0)
        _ = rig.start(.fix(checkID: "G1"), ended: ended)
        #expect(gate.reached.wait(timeout: .now() + 5) == .success)
        rig.clock.advance(3600)
        rig.wake()
        gate.open.signal()
        #expect(ended.wait(timeout: .now() + 5) == .success)
        rig.settle()
        #expect(rig.machine.reads.count == reads + 1)
        #expect(rig.machine.reads.last?.after == nil)
    }

    /// How far the wizard has got decides what a snapshot reads; going Back doesn't un-read a step.
    @Test("Each snapshot reads through the furthest step any work has reached")
    func reach() {
        let rig = Rig()
        rig.finish(.checkAgain(.lookAround))
        rig.finish(.checkAgain(.finish))
        rig.finish(.checkAgain(.vm))
        #expect(rig.machine.reads.map(\.step) == [.lookAround, .finish, .finish])
    }
}

// MARK: - The snapshot mapping

@Suite("The snapshot says what was read, and nothing it wasn't")
struct SetupRunnerSnapshot {
    /// The whole mapping at once: every field the machine reads, set to something that isn't its
    /// default, against a `Facts` written out field by field. Losing any line of `facts(from:)` fails
    /// here, including the ones no other test happens to read (Windows App being open, which is
    /// what stops step 5 writing its database; the declined rows; BitLocker kept; the disk). The two
    /// `Mirror` checks keep it whole: a field added to `Readings` or `Facts` later fails this test
    /// until it is set here too.
    @Test("Every field read reaches the snapshot, as itself")
    func everyField() throws {
        var mac = SetupRunner.Readings()
        mac.utm = .tooOld(version: "4.0.9", minimum: "4.5")
        mac.homebrew = "/opt/homebrew/bin/brew"
        mac.utmFromHomebrew = true
        mac.utmAnswers = .silent(seconds: 20)
        mac.utmConsent = .wouldPrompt
        mac.utmQuarantined = true
        mac.windowsApp = .installed(version: "11.1.10")
        mac.vms = .success([Given.winlab, Given.atelier])
        mac.chosenVM = "winlab01"
        mac.chosenID = Given.winlab.id
        mac.guestAnswers = true
        mac.installRunning = true
        mac.statuses = ["G9": .fixable("BitLocker is on for C:")]
        mac.declined = SetupFlow.Declined(autologon: true, remoteDesktop: true, tuning: true)
        mac.keepBitLocker = true
        mac.disk = SetupFlow.Disk(imagesSeen: true, places: [.init(storage: .volume("/Volumes/atelier"), encrypted: false)])
        mac.rdpHost = "winlab01.local"
        mac.rdpUser = "rosa"
        mac.windowsAppRunning = true
        mac.readiness = .blocked
        mac.pending = ConfigChanges(cpuCores: 6, memoryMB: 8192)
        mac.otherVMs = .success(["atelier"])
        mac.pendingRestart = UTMRestart(vm: "winlab01", pids: [4242])
        let answers = SetupFlow.Answers(started: true, leftAlone: ["H6"], connectionOpened: true, connected: false)

        var expected = SetupFlow.Facts()
        expected.utm = .tooOld(version: "4.0.9", minimum: "4.5")
        expected.homebrew = "/opt/homebrew/bin/brew"
        expected.utmFromHomebrew = true
        expected.utmAnswers = .silent(seconds: 20)
        expected.utmConsent = .wouldPrompt
        expected.utmQuarantined = true
        expected.windowsApp = .installed(version: "11.1.10")
        expected.vms = .listed([Given.winlab, Given.atelier])
        expected.chosenVM = "winlab01"
        expected.chosenID = Given.winlab.id
        expected.vmRunning = true                        // the stamp's VM process
        expected.guestAnswers = true
        expected.installRunning = true
        expected.rows = ["G9": SetupFlow.Row(try #require(Recipe.check("G9")), .fixable("BitLocker is on for C:"))]
        expected.declined = SetupFlow.Declined(autologon: true, remoteDesktop: true, tuning: true)
        expected.keepBitLocker = true
        expected.disk = SetupFlow.Disk(imagesSeen: true, places: [.init(storage: .volume("/Volumes/atelier"),
                                                                        encrypted: false)])
        expected.rdpHost = "winlab01.local"
        expected.rdpUser = "rosa"
        expected.windowsAppRunning = true
        expected.readiness = .blocked
        expected.pending = ConfigChanges(cpuCores: 6, memoryMB: 8192)
        expected.otherVMs = .running(["atelier"])
        expected.utmRestartOwed = true                   // 4242 is still running (the stamp's)
        expected.answers = answers.forVM(Given.winlab.id)
        expected.stamp = Given.stamp

        let facts = SetupRunner.facts(from: mac, stamp: Given.stamp, answers: answers, previous: nil, after: nil)
        #expect(facts == expected)

        for (field, value) in zip(Mirror(reflecting: mac).children, Mirror(reflecting: SetupRunner.Readings()).children) {
            #expect(String(reflecting: field.value) != String(reflecting: value.value),
                    "Readings.\(field.label ?? "?") is left at its default, so the test can't tell it was mapped")
        }
        for (field, value) in zip(Mirror(reflecting: expected).children, Mirror(reflecting: SetupFlow.Facts()).children) {
            #expect(String(reflecting: field.value) != String(reflecting: value.value),
                    "Facts.\(field.label ?? "?") is left at its default, so the test can't tell it was mapped")
        }
    }

    /// `everyField` sets every flag to true, so it can't tell one flag from another: a line that
    /// copied the wrong one would still land `true` where `true` was expected. These are the flags
    /// the window acts on — `windowsAppRunning` is what stops step 5 writing Windows App's database
    /// while it's open — so each is set alone, and it must come out in its own field and nowhere
    /// else. The `Mirror` check keeps the list whole: a flag added to `Readings` fails here until it
    /// is added to the arguments too.
    @Test("Each flag read lands in its own field and no other",
          arguments: ["utmFromHomebrew", "utmQuarantined", "guestAnswers", "installRunning", "keepBitLocker",
                      "windowsAppRunning"])
    func eachFlagAlone(_ field: String) {
        var mac = SetupRunner.Readings()
        switch field {
        case "utmFromHomebrew": mac.utmFromHomebrew = true
        case "utmQuarantined": mac.utmQuarantined = true
        case "guestAnswers": mac.guestAnswers = true
        case "installRunning": mac.installRunning = true
        case "keepBitLocker": mac.keepBitLocker = true
        case "windowsAppRunning": mac.windowsAppRunning = true
        default: Issue.record("no such flag: \(field)")
        }
        #expect(Self.flagsSet(mac) == [field])

        // No VM process and no restart pending, so the two flags the stamp decides stay false.
        let stamp = SetupFlow.Stamp(taken: Given.stamp.taken, utmPIDs: [4242], vmPID: nil)
        let facts = SetupRunner.facts(from: mac, stamp: stamp, answers: SetupFlow.Answers(), previous: nil, after: nil)
        #expect(Self.flagsSet(facts) == [field])
    }

    @Test("The flags above are every flag Readings has")
    func everyFlagListed() {
        let flags = Mirror(reflecting: SetupRunner.Readings()).children.filter { $0.value is Bool }.compactMap(\.label)
        #expect(Set(flags) == ["utmFromHomebrew", "utmQuarantined", "guestAnswers", "installRunning", "keepBitLocker",
                               "windowsAppRunning"])
    }

    /// The names of a value's `Bool` fields that are true: its own flags, not those of the structs
    /// inside it.
    static func flagsSet(_ value: Any) -> Set<String> {
        Set(Mirror(reflecting: value).children.compactMap { child in (child.value as? Bool) == true ? child.label : nil })
    }

    @Test("Rows come from the recipe's own checks; a check not read has no row")
    func rows() throws {
        let facts = Given.facts()
        let g1 = try #require(facts.rows["G1"])
        #expect(g1.title == Recipe.check("G1")?.title)
        #expect(g1.why == Recipe.check("G1")?.why)
        #expect(g1.kind == .fixable)
        #expect(g1.action == .fix)
        #expect(facts.rows["G5"] == nil)
        #expect(facts.rows.count == Given.mac.statuses.count)
    }

    /// "UTM has no Windows VM — Make One" said to a Mac whose Apple Event is waiting on the prompt
    /// would send someone off to install a second copy of Windows.
    @Test("A VM list that failed is a failure, one not asked is not asked, never an empty list")
    func vmList() {
        let failed = Given.facts(Given.mac {
            $0.vms = .failure(WinbarError("UTM didn't answer in time", "Gave up after 90 seconds.", timedOut: true))
        })
        #expect(failed.vms == .failed(.init(title: "UTM didn't answer in time", detail: "Gave up after 90 seconds.",
                                            timedOut: true)))
        #expect(Given.facts(Given.mac { $0.vms = nil }).vms == .notAsked)
        #expect(Given.facts().vms == .listed([Given.winlab, Given.atelier]))
    }

    /// UTM's list said winlab01 was "started"; the process table, read at the same moment as the
    /// stamp, says it isn't running now. The stamp wins, so staleness and the screen agree.
    @Test("Whether the VM runs comes from the stamp's process scan, not UTM's word")
    func running() {
        #expect(Given.facts().vmRunning)
        #expect(!Given.facts(stamp: SetupFlow.Stamp(taken: Given.stamp.taken, utmPIDs: [4242], vmPID: nil)).vmRunning)
    }

    @Test("Other VMs: not asked, running, or UTM wouldn't say — which counts as maybe")
    func otherVMs() {
        #expect(Given.facts().otherVMs == .notAsked)
        #expect(Given.facts(Given.mac { $0.otherVMs = .success(["atelier"]) }).otherVMs == .running(["atelier"]))
        #expect(Given.facts(Given.mac { $0.otherVMs = .failure(WinbarError("Couldn't ask UTM", "it timed out")) }).otherVMs
                    == .unconfirmed("it timed out"))
    }

    /// The runner never writes the window's answers; it carries them.
    @Test("The answers are the window's, and the stamp is the scan's")
    func answersAndStamp() {
        let answers = SetupFlow.Answers(started: true, leftAlone: ["H6"], connectionOpened: true, connected: true)
        let facts = SetupRunner.facts(from: Given.mac, stamp: Given.stamp, answers: answers, previous: nil, after: nil)
        #expect(facts.answers == answers.forVM(facts.target))
        #expect(facts.stamp == Given.stamp)
        #expect(facts.pending == ConfigChanges(cpuCores: 6))
    }

    /// The one message the person needs mustn't vanish because Winbar came back to the front.
    @Test("A failed Fix stays on its row across re-reads while the row still needs fixing")
    func failureStays() throws {
        let failed = SetupRunner.Performed(work: .fix(checkID: "G1"),
                                           outcome: .failed(.init(title: "The power plan couldn't be changed",
                                                                  detail: "powercfg: access denied")))
        let after = Given.facts(after: failed)
        #expect(after.rows["G1"]?.failure == "The power plan couldn't be changed: powercfg: access denied")
        let reread = Given.facts(previous: after)
        #expect(reread.rows["G1"]?.failure == after.rows["G1"]?.failure)
        // Gone once it's fixed, by any means…
        #expect(Given.facts(Given.mac { $0.statuses["G1"] = .ok("High performance") }, previous: after)
                    .rows["G1"]?.failure == nil)
        // …or once a later Fix worked.
        let worked = SetupRunner.Performed(work: .fix(checkID: "G1"), outcome: .finished)
        #expect(Given.facts(previous: after, after: worked).rows["G1"]?.failure == nil)
    }

    @Test("Fix Everything notes the rows it failed on, and leaves the others as they were")
    func fixEverythingNotes() {
        let performed = SetupRunner.Performed(work: .fixEverything,
                                              outcome: .failed(.init(title: "G1 failed")),
                                              rowFailures: ["G1": "powercfg: access denied"])
        let facts = Given.facts(after: performed)
        #expect(facts.rows["G1"]?.failure == "powercfg: access denied")
        #expect(facts.rows["H7"]?.failure == nil)
    }

    /// `Setup.walk`'s "still: …", for a Done that didn't take.
    @Test("A Done that didn't take says still, until the row changes")
    func still() {
        var mac = Given.mac
        mac.statuses["H6"] = .manual("can't tell whether Time Machine backs up UTM's VMs", how: "System Settings…")
        let done = SetupRunner.Performed(work: .recordDone(checkID: "H6"), outcome: .finished)
        let after = Given.facts(mac, after: done)
        #expect(after.rows["H6"]?.still == true)
        #expect(Given.facts(mac, previous: after).rows["H6"]?.still == true)
        mac.statuses["H6"] = .ok("excluded from Time Machine")
        #expect(Given.facts(mac, previous: after).rows["H6"]?.still == false)
    }
}

// MARK: - What a snapshot reads

@Suite("A snapshot reads what the steps so far show, and never starts UTM or its prompt")
struct SetupRunnerReadPlan {
    static let guest = SetupFlow.checks(in: .tune).filter { $0.hasPrefix("G") }

    /// The survey behind the guest rows can take minutes; the first look mustn't pay for it.
    @Test("The first look reads UTM, its answer and Windows App, and nothing of Windows")
    func firstLook() {
        let plan = SetupRunner.readPlan(through: .lookAround, utmRunning: true, mayAskUTM: true, connectPressed: true)
        #expect(plan.checks == ["H1", "H9", "C1"])
        #expect(plan.asksUTM)
        #expect(!plan.otherVMs && !plan.readiness && !plan.windowsAppRunning)
    }

    @Test("Tune reads every row of its own, and nothing from the steps after it")
    func tune() {
        let plan = SetupRunner.readPlan(through: .tune, utmRunning: true, mayAskUTM: true, connectPressed: true)
        #expect(Set(SetupFlow.checks(in: .tune)).isSubset(of: Set(plan.checks)))
        #expect(!plan.checks.contains("H7"))
        #expect(!plan.checks.contains("C2"))
        #expect(plan.checks == SetupFlow.order.filter(Set(plan.checks).contains))
    }

    /// Reading never launches UTM (every utmctl call and Apple Event does, if it isn't running), and
    /// never sends the first Apple Event before the window has said macOS will ask (§2.2).
    @Test("With UTM not running, or not to be asked yet, only what needs no UTM is read",
          arguments: [(false, true), (true, false), (false, false)])
    func withoutUTM(_ running: Bool, _ may: Bool) {
        for step in WizardStep.allCases {
            let plan = SetupRunner.readPlan(through: step, utmRunning: running, mayAskUTM: may, connectPressed: true)
            #expect(!plan.asksUTM && !plan.otherVMs)
            #expect(Set(plan.checks).isSubset(of: SetupRunner.readWithoutUTM), "\(step): \(plan.checks)")
            #expect(plan.checks.contains("H1") && plan.checks.contains("C1"))
        }
    }

    /// An Apple Event, asked only at the last step (COHERENCE C2): never on the way there.
    @Test("Other VMs are asked at the finish and nowhere else")
    func otherVMs() {
        for step in WizardStep.allCases {
            #expect(SetupRunner.readPlan(through: step, utmRunning: true, mayAskUTM: true, connectPressed: true).otherVMs == (step == .finish))
        }
    }

    @Test("Windows App's state from the saved-PC step")
    func windowsAppRunning() {
        for step in WizardStep.allCases {
            for opened in [false, true] {
                let plan = SetupRunner.readPlan(through: step, utmRunning: true, mayAskUTM: true, connectPressed: opened)
                #expect(plan.windowsAppRunning == (step >= .savedPC))
            }
        }
    }

    /// Probing the Remote Desktop port is what raises macOS's Local Network prompt, and step 6 says
    /// so in a sentence before **Connect** (§2.2). Probed on every read from step 6 on, the prompt
    /// could appear the moment step 6 is first drawn, or on a re-read after a wake, before anything
    /// had said it was coming. The only screen that shows the port is the diagnosis after **No**,
    /// which comes after Connect, and Connect's own probe has raised the prompt by then.
    @Test("The port is probed only once Connect has been pressed, whatever step the wizard reached")
    func readinessAfterConnect() {
        for step in WizardStep.allCases {
            for opened in [false, true] {
                let plan = SetupRunner.readPlan(through: step, utmRunning: true, mayAskUTM: true, connectPressed: opened)
                #expect(plan.readiness == (step >= .connect && opened), "\(step), opened: \(opened)")
            }
        }
    }

    /// `readPlan` runs in the live machine, so the machine has to be handed the window's answers as
    /// they are now — the ones given with the press, and those given since with `update(answers:)`.
    @Test("Every read is handed the window's answers as they are now")
    func readsGetAnswers() throws {
        let rig = Rig()
        let opened = SetupFlow.Answers(started: true, connectionOpened: true)
        let ended = DispatchSemaphore(value: 0)
        #expect(rig.runner.run(.checkAgain(.connect), answers: opened, done: { _ in ended.signal() }) == nil)
        #expect(ended.wait(timeout: .now() + 5) == .success)
        #expect(rig.machine.reads.last?.answers == opened)

        let no = SetupFlow.Answers(started: true, connectionOpened: true, connected: false)
        rig.runner.update(answers: no)
        let observation = rig.runner.attach { _ in }.observation
        rig.clock.advance(60)
        rig.comeBack()
        rig.settle()
        #expect(rig.machine.reads.count == 2)
        #expect(rig.machine.reads.last?.answers == no)
        withExtendedLifetime(observation) {}
    }

    /// The live machine fetches, and this is what it calls with what it fetched: so the rules the
    /// machine used to apply itself — the port only after Connect, UTM asked only once it may be —
    /// are held here. The control for each is the other value of the one thing that changes.
    @Test("The machine's plan probes the port only once the window's answers say Connect was pressed")
    func machinePlanWaitsForConnect() {
        for step in WizardStep.allCases {
            for opened in [false, true] {
                let plan = SetupRunner.readPlan(through: step, readings: Given.mac,
                                                answers: SetupFlow.Answers(started: true, connectionOpened: opened),
                                                utmUp: true, settled: .answered, consent: { .decided })
                #expect(plan.readiness == (step >= .connect && opened), "\(step), opened: \(opened)")
            }
        }
    }

    /// The press is what the Local Network prompt was predicted for, not the connection opening: a
    /// Connect that timed out, and the read after **No**, both need the port's answer for the recovery
    /// card. Keyed on `connectionOpened` alone, the read that ended Connect never probed, and the card
    /// said readiness hadn't been checked while the port was answering.
    @Test("Pressing Connect is enough for the machine's plan to probe the port")
    func machinePlanProbesOncePressed() {
        for step in WizardStep.allCases {
            for pressed in [false, true] {
                var answers = SetupFlow.Answers(started: true)
                answers.connectPressed = pressed
                let plan = SetupRunner.readPlan(through: step, readings: Given.mac, answers: answers,
                                                utmUp: true, settled: .answered, consent: { .decided })
                #expect(plan.readiness == (step >= .connect && pressed), "\(step), pressed: \(pressed)")
            }
        }
    }

    @Test("The machine's plan asks UTM only when it is installed, up, and may be asked")
    func machinePlanAsksUTM() {
        func plan(_ utm: DependencyState = .installed(version: "4.7.5"), up: Bool = true, settled: UTM.CtlAnswer? = nil,
                  consent: Automation.Consent = .decided, asked: (() -> Void)? = nil) -> SetupRunner.ReadPlan {
            SetupRunner.readPlan(through: .tune, readings: Given.mac { $0.utm = utm }, answers: SetupFlow.Answers(),
                                 utmUp: up, settled: settled, consent: { asked?(); return consent })
        }
        #expect(plan().asksUTM)
        #expect(!plan(.missing).asksUTM)                              // a process called UTM, but no UTM here
        #expect(!plan(up: false).asksUTM)                             // asking would launch it
        #expect(!plan(consent: .wouldPrompt).asksUTM)                 // the first Apple Event would raise the prompt
        #expect(!plan(consent: .unknown).asksUTM)                     // macOS didn't say, which isn't a yes
        #expect(plan(settled: .silent(seconds: 20), consent: .wouldPrompt).asksUTM)   // Open UTM and Ask was pressed

        // Once it was pressed, macOS isn't asked: on a Mac stuck behind the prompt that takes seconds.
        var asked = 0
        _ = plan(settled: .answered, asked: { asked += 1 })
        #expect(asked == 0)
        _ = plan(asked: { asked += 1 })
        #expect(asked == 1)
    }

    /// Step 1 draws C1 long before step 5 acts on it, and the window installs Windows App from the
    /// App Store, never Homebrew. The live machine builds H1 and C1 through `row(for:readings:)`, so
    /// this is the row the window shows; the control is the check's own row, which offers Homebrew.
    @Test("The snapshot's H1 and C1 are the window's rows: C1 offers the App Store, with Homebrew here or not")
    func windowRows() throws {
        for brew in ["/opt/homebrew/bin/brew", nil] {
            let mac = Given.mac { $0.homebrew = brew; $0.windowsApp = .missing; $0.utm = .missing }
            let c1 = try #require(SetupRunner.row(for: "C1", readings: mac))
            #expect(c1.isFixable)
            #expect(c1.detail.hasSuffix("; setup can open its App Store page"), "brew: \(brew ?? "none")")
            #expect(!c1.detail.contains("Homebrew"))
            let h1 = try #require(SetupRunner.row(for: "H1", readings: mac))
            #expect(h1.detail == SetupRunner.dependencyRow(.utm, state: .missing, brew: brew).detail)
        }
        #expect(Recipe.dependencyStatus(.windowsApp, state: .missing, brew: "/opt/homebrew/bin/brew").detail
                    .contains("Homebrew"))
        // Built from what the snapshot read, not read again.
        #expect(SetupRunner.row(for: "C1", readings: Given.mac)?.isOK == true)
        #expect(SetupRunner.row(for: "H1", readings: Given.mac { $0.utm = .tooOld(version: "4.0.9", minimum: "4.5") })?
                    .isOK == false)
        // Every other check is the Context's to evaluate.
        for id in SetupFlow.order where id != "H1" && id != "C1" {
            #expect(SetupRunner.row(for: id, readings: Given.mac) == nil, "\(id)")
        }
    }

    /// C3 and C4 run the self-test as Winbar.app on every read from step 6 on, and the self-test
    /// probed the port whenever the VM ran: the Local Network prompt, raised by a read the first time
    /// step 6 was drawn, before Connect. This pins every rule on the way from the window's `Context`
    /// to the probe — its options, the arguments for them, what those arguments are read back as, and
    /// the row that's built — by calling each rule's function. It does NOT go through the glue that
    /// strings them together (`Context.selfTest`'s launch at Checks.swift, the parse in CLI.run, the
    /// live machine's `Context(options:)`): that glue is one line each and can only be proven by
    /// running the real window, so it is covered by a live check instead ("no Local Network prompt
    /// before Connect", WAVE3-BRIEF.md). The control is the terminal's own options through the same
    /// rules, which still probe: doctor and diagnose report the answer.
    @Test("The window's self-test leaves the Remote Desktop port alone; the terminal's still probes it")
    func selfTestLeavesThePortAlone() {
        func run(_ options: Context.Options) -> (row: (String, String)?, probed: Int) {
            let launched = ["--self-test"] + SelfTest.arguments(probingPort: options.selfTestProbesPort)
            var probed = 0
            let row = SelfTest.readinessRow(vmRunning: true, probePort: SelfTest.probesPort(arguments: launched),
                                            probe: { probed += 1; return .blocked })
            return (row, probed)
        }
        let window = run(SetupRunner.contextOptions)
        #expect(window.row == nil)
        #expect(window.probed == 0)
        let terminal = run(Context.Options())
        #expect(terminal.row?.0 == "rdp readiness")
        #expect(terminal.row?.1 == "blocked")
        #expect(terminal.probed == 1)
    }

    @Test("A self-test probes only a running VM, and not at all when told to leave the port alone")
    func selfTestReadinessRow() {
        var probed = 0
        #expect(SelfTest.readinessRow(vmRunning: false, probePort: true, probe: { probed += 1; return .ready })?.1 == "vm off")
        #expect(SelfTest.readinessRow(vmRunning: false, probePort: false, probe: { probed += 1; return .ready }) == nil)
        #expect(probed == 0)
        #expect(SelfTest.readinessRow(vmRunning: true, probePort: true, probe: { probed += 1; return .notReady })?.1
                    == "notReady")
        #expect(probed == 1)
        // C3's own Allow Accessibility launch is left as it was.
        #expect(SelfTest.probesPort(arguments: ["--self-test", "--request-accessibility"]))
    }

    /// Every Apple Event after a silent utmctl would wait out its own timeout on the same silence.
    @Test("A silent utmctl keeps H9 and drops everything else that asks UTM")
    func silent() {
        let plan = SetupRunner.readPlan(through: .finish, utmRunning: true, mayAskUTM: true, connectPressed: true).utmSilent
        #expect(plan.checks == ["H1", "H9", "H6", "C1", "C4"])
        #expect(!plan.otherVMs)
        #expect(Self.guest.allSatisfy { !plan.checks.contains($0) })
    }
}

// MARK: - Whether work still applies

@Suite("Work is carried out only while the step still offers it")
struct SetupRunnerApplies {
    static var facts: SetupFlow.Facts { Given.facts() }

    @Test("A Fix while the row needs fixing, and never for rows with work of their own")
    func fix() {
        #expect(SetupRunner.Work.fix(checkID: "G1").applies(to: Self.facts))
        #expect(!SetupRunner.Work.fix(checkID: "G1").applies(to: Given.facts(Given.mac { $0.statuses["G1"] = .ok("fine") })))
        #expect(!SetupRunner.Work.fix(checkID: "G5").applies(to: Self.facts))          // not read
        for id in SetupRunner.Work.ownWork {
            let facts = Given.facts(Given.mac { $0.statuses[id] = .fixable("needs changing") })
            #expect(!SetupRunner.Work.fix(checkID: id).applies(to: facts), "\(id)")
        }
        // H1 has no apply: its install is `installUTM`.
        #expect(!SetupRunner.Work.fix(checkID: "H1").applies(to: Given.facts(Given.mac { $0.statuses["H1"] = .fixable("x") })))
    }

    @Test("Trust It only while step 4 offers it; Start It only for the chosen VM, stopped")
    func trustAndStart() {
        #expect(SetupRunner.Work.trustCertificate.applies(to: Self.facts))
        #expect(!SetupRunner.Work.trustCertificate.applies(to: Given.facts(Given.mac { $0.statuses["H7"] = .ok("trusted") })))
        let stopped = Given.facts(stamp: SetupFlow.Stamp(taken: Given.stamp.taken, utmPIDs: [4242], vmPID: nil))
        // The critique's step-4-overnight case: H7 still reads fixable, but Windows isn't running.
        #expect(!SetupRunner.Work.trustCertificate.applies(to: stopped))
        #expect(!SetupRunner.Work.fix(checkID: "G1").applies(to: stopped))
        #expect(SetupRunner.Work.startVM("winlab01").applies(to: stopped))
        #expect(!SetupRunner.Work.startVM("winlab01").applies(to: Self.facts))       // already running
        #expect(!SetupRunner.Work.startVM("atelier").applies(to: stopped))           // not the chosen one
        #expect(!SetupRunner.Work.survey.applies(to: stopped))
    }

    /// The window's Windows App is the App Store, as the proven path, whether or not Homebrew is here.
    @Test("Windows App is installed from the App Store, with Homebrew present or not")
    func windowsApp() {
        for brew in [nil, "/opt/homebrew/bin/brew"] {
            let missing = Given.facts(Given.mac { $0.windowsApp = .missing; $0.homebrew = brew })
            #expect(SetupRunner.Work.installWindowsApp.applies(to: missing))
        }
        #expect(!SetupRunner.Work.installWindowsApp.applies(to: Self.facts))
        #expect(!SetupRunner.Work.installWindowsApp.applies(to: Given.facts(Given.mac {
            $0.windowsApp = .wrongSignature("Windows App at /Applications/Windows App.app is signed by team X")
        })))
    }

    @Test("The restart only with something staged; UTM's install only while it's missing")
    func restartAndInstall() {
        #expect(SetupRunner.Work.applyChanges.applies(to: Self.facts))
        #expect(!SetupRunner.Work.applyChanges.applies(to: Given.facts(Given.mac { $0.pending = ConfigChanges() })))
        #expect(!SetupRunner.Work.installUTM.applies(to: Self.facts))
        #expect(SetupRunner.Work.installUTM.applies(to: Given.facts(Given.mac { $0.utm = .missing })))
        #expect(!SetupRunner.Work.installUTM.applies(to: Given.facts(Given.mac { $0.utm = .wrongSignature("not UTM") })))
    }

    @Test("Each kind of work belongs to its step")
    func steps() {
        #expect(everyWork.map(\.step) == [.lookAround, .lookAround, .savedPC, .lookAround, .vm, .vm, .tune, .tune, .tune,
                                          .tune, .certificate, .savedPC, .connect, .finish, .tune, .tune, .finish])
        #expect(SetupRunner.Work.fix(checkID: "H5").step == .finish)
        #expect(SetupRunner.Work.recordDone(checkID: "C3").step == .connect)
    }
}

// MARK: - The password

@Suite("The password is never part of the work, and reaches only Save It")
struct SetupRunnerPassword {
    static let canary = "Canary-7f3e-winbar-setup"

    @Test("No work, in-flight state or ending carries it, and only Save It is handed it")
    func onlySaveIt() throws {
        let rig = Rig(mac: Given.mac {
            $0.statuses["C2"] = .fixable("none for winlab01.local; setup can save it for you")
            $0.statuses["C1"] = .ok("Windows App 11.1.10")
        })
        _ = try #require(rig.finish(.checkAgain(.savedPC)))
        let saved = try #require(rig.finish(.savePC, password: Self.canary))
        #expect(saved.outcome == .finished)
        let fixed = try #require(rig.finish(.fix(checkID: "G1"), password: Self.canary))
        for (work, password) in zip(rig.machine.performed, rig.machine.passwords) {
            #expect(password == (work == .savePC ? Self.canary : nil), "\(work)")
        }
        #expect(rig.machine.performed.contains(.savePC) && rig.machine.performed.contains(.fix(checkID: "G1")))

        for work in everyWork { #expect(!String(reflecting: work).contains(Self.canary)) }
        for ending in [saved, fixed] { #expect(!String(reflecting: ending).contains(Self.canary)) }
    }
}

// MARK: - Stop Waiting's mechanism

/// What `stopWaiting()` does to the live certificate wait: `RDP.trustCertificate` hands the job's
/// cancellation to `Shell.run` as `abort`. Run against `/bin/sleep`, which reaches nothing.
@Suite("A tool waiting on someone else's dialog can be stopped")
struct ShellAbort {
    @Test("abort ends the tool well before its timeout, and doesn't call it a timeout")
    func aborts() {
        let started = Date()
        let result = Shell.run("/bin/sleep", ["30"], timeout: 60, abort: { Date().timeIntervalSince(started) > 0.3 })
        #expect(Date().timeIntervalSince(started) < 10)
        #expect(!result.timedOut)
        #expect(result.status != 0)
    }

    @Test("A tool that finishes by itself is untouched by an abort that never says yes")
    func untouched() {
        let result = Shell.run("/bin/echo", ["winlab01"], timeout: 10, abort: { false })
        #expect(result.status == 0)
        #expect(result.text == "winlab01\n")
    }
}

// MARK: - The words for work in flight

@Suite("Work in flight is always named, never just busy")
struct SetupRunnerWords {
    @Test("Every refusal names its work, and says where to look when it waits on a person")
    func everyRefusal() {
        for work in everyWork {
            let flight = SetupRunner.InFlight(work: work, started: Given.stamp.taken, vm: "winlab01")
            let doing = SetupCopy.Working.doing(flight)
            let refusal = String(SetupCopy.Working.refusal(flight).characters)
            #expect(!doing.isEmpty)
            #expect(refusal.hasPrefix("Winbar is still \(doing), and it does one thing at a time."), "\(work)")
            #expect(!refusal.localizedCaseInsensitiveContains("busy"), "\(work)")
            #expect(!refusal.contains("!"), "\(work)")
            if let waiting = work.waitsFor {
                #expect(refusal.hasSuffix(String(SetupCopy.markdown(SetupCopy.Working.whereToLook(waiting)).characters)),
                        "\(work)")
                #expect(refusal.components(separatedBy: "waiting for").count <= 2, "said twice: \(refusal)")
            } else {
                #expect(refusal.hasSuffix("This can go ahead once that's done."), "\(work)")
            }
        }
    }

    /// The quit guard's example, which the restart's phrase has to fit.
    @Test("The restart's phrase is the quit guard's own example")
    func quitGuard() {
        let flight = SetupRunner.InFlight(work: .applyChanges, started: Given.stamp.taken, vm: "Windows 11")
        #expect(String(SetupCopy.Quitting.body(doing: SetupCopy.Working.doing(flight)).characters)
                    == "Winbar is in the middle of restarting “Windows 11”. If you quit now, Winbar leaves that unfinished.")
    }
}
