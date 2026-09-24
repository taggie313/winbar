import AppKit
import Testing
@testable import Winbar

private final class ReviewMachine: SetupMachine {
    var selected = SetupVMTests.new
    var pending = ConfigChanges()
    var block: SetupRunner.Work?
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var count = 0
    var reads: Int { lock.lock(); defer { lock.unlock() }; return count }
    func readings(through step: WizardStep, answers: SetupFlow.Answers, after work: SetupRunner.Work?,
                  job: SetupRunner.Job?) -> SetupRunner.Readings {
        lock.lock(); count += 1; lock.unlock()
        var r = SetupRunner.Readings()
        r.utm = SetupFixtures.installed; r.utmAnswers = .answered
        r.windowsApp = .installed(version: "11.4")
        r.vms = .success([SetupVMTests.old, SetupVMTests.new])
        r.chosenVM = selected.name; r.chosenID = selected.id
        r.guestAnswers = true; r.rdpHost = "winlab02.local"; r.rdpUser = "Bruno"
        r.otherVMs = .success([]); r.pending = pending
        for id in SetupFlow.order { r.statuses[id] = .ok("Ready") }
        r.statuses["H5"] = .fixable("Screen on")
        return r
    }
    func selectionChanged(since facts: SetupFlow.Facts) -> Bool { facts.target != selected.id }
    func perform(_ work: SetupRunner.Work, password: String?, facts: SetupFlow.Facts, job: SetupRunner.Job) throws {
        if work == block { entered.signal(); release.wait() }
        if case .chooseVM(_, let id) = work { selected = id == SetupVMTests.old.id ? SetupVMTests.old : SetupVMTests.new }
        if case .discardChanges = work { pending = ConfigChanges() }
        if work == .applyChanges { pending = ConfigChanges() }
    }
}

private final class ReviewWindow: NSWindow {
    var closes = 0
    var presents = 0
    override func close() { closes += 1; super.close() }
    override func performClose(_ sender: Any?) {
        closes += 1
        delegate?.windowWillClose?(Notification(name: NSWindow.willCloseNotification, object: self))
        orderOut(nil)
    }
}

@Suite("Review repairs exercise real controller call sites", .serialized)
@MainActor struct SetupReviewTests {
    private func runner(_ machine: ReviewMachine, gate: AppWorkGate? = nil) -> SetupRunner {
        SetupRunner(machine: machine, environment: .init(queue: DispatchQueue(label: "winbar.test.review"),
            callbacks: .main, clock: Date.init, keepAwake: { _ in {} }, processes: { _ in ([100], 101) },
            workspace: NotificationCenter(), workGate: gate))
    }
    private func controller(_ runner: SetupRunner, step: WizardStep = .vm,
                            creator: FakeEmbeddedCreate = FakeEmbeddedCreate()) -> SetupWindowController {
        SetupWindowController(state: SetupFixtures.state(step, facts: JourneyFixtures.facts), art: nil,
            settings: .init(wizardShown: { false }, markShown: {}, armieHidden: { true }, hideArmie: {}),
            makeRunner: { runner }, makeCreator: { creator })
    }
    private func settle(_ runner: SetupRunner) async {
        for _ in 0..<400 where runner.inFlight != nil { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(runner.inFlight == nil)
        try? await Task.sleep(for: .milliseconds(20))
    }
    private func close(_ c: SetupWindowController) { c.windowWillClose(Notification(name: NSWindow.willCloseNotification)) }
    private func create(gate: AppWorkGate = AppWorkGate()) -> CreateWindowController {
        let facts = CreateFormFacts(mac: MacFacts(topTierCores: 8, totalCores: 10, memoryBytes: 32 << 30, shortUserName: "rosa"),
            utmInstalled: true, utmVersion: "4.7.5", fileVaultOn: true, freeGB: 400, volumeName: "Test disk",
            existingVMNames: [], menuVMName: "winlab01")
        let c = CreateWindowController(facts: facts, environment: .init(currentJob: { nil }, refreshForm: { _ in },
            show: { ($0 as? ReviewWindow)?.presents += 1 }, workGate: gate))
        let w = ReviewWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 180),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false; w.delegate = c; c.window = w
        return c
    }

    @Test("No presented wizard leaves the menu alone; closing a bare form releases it")
    func absentAndFormClose() {
        SetupWindowController.presented = nil
        #expect(!SetupWindowController.coordinatesVM && !SetupWindowController.defersNetworkProbe)
        let creator = FakeEmbeddedCreate()
        let c = controller(runner(ReviewMachine()), creator: creator)
        c.attach(); SetupWindowController.presented = c
        defer { close(c); SetupWindowController.presented = nil }
        #expect(SetupWindowController.coordinatesVM && SetupWindowController.defersNetworkProbe)
        c.send(.newWindowsVM)
        #expect(c.state.creating && creator.isEmbedded)
        close(c)
        #expect(!c.state.creating && !creator.isEmbedded)
        #expect(!SetupWindowController.coordinatesVM && !SetupWindowController.defersNetworkProbe)
    }

    @Test("Closing busy setup holds only until the runner ends; Make One cannot overlap")
    func closeInFlight() async {
        let m = ReviewMachine(); m.block = .survey
        let r = runner(m); let creator = FakeEmbeddedCreate(); let c = controller(r, creator: creator)
        c.attach(); SetupWindowController.presented = c
        defer { close(c); SetupWindowController.presented = nil }
        c.send(.perform(.run(.survey)))
        for _ in 0..<400 where c.state.inFlight == nil { try? await Task.sleep(for: .milliseconds(5)) }
        c.send(.newWindowsVM)
        #expect(creator.embeds == 0)
        close(c)
        #expect(SetupWindowController.coordinatesVM)
        m.release.signal(); await settle(r)
        #expect(!SetupWindowController.coordinatesVM && !SetupWindowController.defersNetworkProbe)
        #expect(c.state.inFlight != nil, "The frozen view is deliberately not the source of ownership")
    }

    @Test("A hidden install handoff stores facts without reattaching or surveying")
    func hiddenHandoff() async {
        let m = ReviewMachine(); let r = runner(m); let creator = FakeEmbeddedCreate()
        creator.hasRunningJob = true
        let c = controller(r, creator: creator); c.attach()
        c.send(.newWindowsVM); close(c)
        c.created(.installed(id: SetupVMTests.new.id, name: SetupVMTests.new.name, messages: []))
        try? await Task.sleep(for: .milliseconds(30))
        #expect(m.reads == 0 && !c.isPresented && c.state.afterInstall != nil)
        c.attach(); await settle(r)
        #expect(m.reads > 0 && c.state.afterInstall == nil)
        close(c)
    }

    @Test("Unseen Connect and restart endings are applied once on reopen")
    func unseenEndings() async {
        for work in [SetupRunner.Work.connect, .applyChanges] {
            let m = ReviewMachine(); m.block = work; m.pending.display = .headless
            let r = runner(m); let c = controller(r, step: work == .connect ? .connect : .finish)
            c.attach(); c.send(.perform(.run(.checkAgain(.finish)))); await settle(r)
            if work == .applyChanges {
                // A completed connection establishes the Yes being invalidated by this restart.
                c.send(.perform(.run(.connect))); await settle(r); c.send(.connected(true))
            }
            c.send(.perform(.run(work)))
            for _ in 0..<400 where c.state.inFlight == nil { try? await Task.sleep(for: .milliseconds(5)) }
            close(c); m.release.signal(); await settle(r)
            c.attach()
            #expect(c.state.answers.connected == nil)
            if work == .connect { #expect(c.state.answers.connectionOpened) }
            else { #expect(c.state.step == .connect && c.state.reconnectAfterRestart) }
            let state = c.state; c.attach(); #expect(c.state == state)
            close(c)
        }
    }

    @Test("External selection replaces the target and discards old confirmation and pending changes")
    func selectionChanges() async {
        let m = ReviewMachine(); let r = runner(m); let c = controller(r, step: .connect)
        c.attach(); c.send(.perform(.run(.checkAgain(.connect)))); await settle(r)
        c.send(.perform(.run(.connect))); await settle(r); c.send(.connected(true))
        #expect(c.state.answers.connected == true)
        close(c); m.selected = SetupVMTests.old
        c.attach()
        for _ in 0..<400 where c.state.facts?.target != SetupVMTests.old.id {
            try? await Task.sleep(for: .milliseconds(5))
        }
        await settle(r)
        #expect(c.state.facts?.target == SetupVMTests.old.id)
        #expect(c.state.answers.connected == nil && c.state.step == .vm)
        close(c)
        let ctx = Context(options: .init(vmOverride: "fictional-old"))
        ctx.pending = ConfigChanges(cpuCores: 8, memoryMB: 16384, display: .headless)
        #expect(ctx.adoptSelection(name: "fictional-new", id: SetupVMTests.new.id))
        #expect(ctx.pending.isEmpty && ctx.vmID == SetupVMTests.new.id)
    }

    @Test("The actual menu update honors the probe gate, including an explicit menu Connect")
    func menuProbe() {
        let c = controller(runner(ReviewMachine())); c.attach(); SetupWindowController.presented = c
        defer { close(c); SetupWindowController.presented = nil }
        let delegate = AppDelegate(); var probes = 0
        delegate.probeReadiness = { _, _ in probes += 1 }
        let state = MenuState(status: MenuStatus(vmName: "winlab01", running: true))
        delegate.updateMenu(NSMenu(), state: state); #expect(probes == 0)
        SetupWindowController.connectionRequested()
        delegate.updateMenu(NSMenu(), state: state); #expect(probes == 1)
        close(c); delegate.updateMenu(NSMenu(), state: state); #expect(probes == 2)
    }

    @Test("Actual Create routing, embed with sheet, hide and duplicate delivery use one host")
    func createLifecycle() async {
        let c = create(); let window = c.window as! ReviewWindow
        var hosts = 0; var hides = 0; var endings = 0
        CreateWindowController.present(controller: c, setupBusy: true, showSetup: { hosts += 1 })
        #expect(hosts == 1 && window.presents == 0)
        CreateWindowController.present(controller: c, setupBusy: false, showSetup: { hosts += 1 })
        #expect(window.presents == 1)
        c.close(); #expect(window.closes == 1)
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        window.beginSheet(sheet) { _ in }
        c.form.password = "synthetic-form-secret"
        c.embed(.init(present: { hosts += 1 }, hide: { hides += 1 }, window: { nil }, finished: { _ in endings += 1 }))
        #expect(window.closes == 2 && window.attachedSheet == nil && !window.isVisible)
        #expect(c.form.password.isEmpty)
        CreateWindowController.presentProgress(controller: c)
        #expect(hosts == 2 && window.presents == 1)
        c.bringForward(); #expect(hosts == 3 && window.presents == 1)
        c.draw(testState()); c.close()
        #expect(hides == 1 && c.isEmbedded && c.job?.isFinished == false)
        c.form.password = "synthetic-form-secret"; c.hostClosed(); #expect(c.form.password.isEmpty)
        c.form.password = "synthetic-form-secret"; c.unembed(); #expect(c.form.password.isEmpty)
        // Completion reopens an app-owned embedded job and can hand back only once.
        c.window = nil // the wizard may be the only window that ever existed
        CreateWindowController.claimJob()
        defer { CreateWindowController.releaseJob(); c.windowWillClose(Notification(name: NSWindow.willCloseNotification)) }
        c.embed(.init(present: { hosts += 1 }, hide: {}, window: { nil }, finished: { _ in endings += 1 }))
        c.jobChanged(testState()); try? await Task.sleep(for: .milliseconds(30))
        let end = testState(vmID: SetupVMTests.new.id, outcome: .done)
        c.jobChanged(end); try? await Task.sleep(for: .milliseconds(30))
        let after = hosts
        #expect(after == 4 && endings == 1)
        c.jobChanged(end); try? await Task.sleep(for: .milliseconds(30))
        #expect(hosts == after && endings == 1 && c.job == nil)
    }

    @Test("Every navigation and delivery boundary clears its own secret canary")
    func secrets() async {
        let r = runner(ReviewMachine()); let c = controller(r, step: .savedPC); c.attach()
        c.credentials.password = "synthetic-secret"
        c.receive(.refreshed(SetupFlow.Facts())) // moves back to Look Around
        #expect(c.credentials.password.isEmpty)
        c.credentials.password = "synthetic-secret"; c.send(.back); #expect(c.credentials.password.isEmpty)
        let next = controller(r, step: .certificate); next.attach()
        next.credentials.password = "synthetic-secret"; next.send(.next); #expect(next.credentials.password.isEmpty)
        await settle(r)
        next.credentials.password = "synthetic-secret"; next.savePC(password: "synthetic-secret")
        #expect(next.credentials.password.isEmpty); await settle(r)
        let epoch = next.state.secretEpoch; close(next)
        #expect(next.state.secretEpoch == epoch + 1)
        close(c)
    }

    @Test("A staged restart can be discarded after refusal, allowing Finish")
    func discardAfterRefusal() async {
        let m = ReviewMachine(); m.pending.display = .headless
        let r = runner(m); let c = controller(r, step: .finish); c.attach()
        c.send(.perform(.run(.checkAgain(.finish)))); await settle(r)
        c.send(.discardChanges(nil)); await settle(r)
        #expect(c.state.facts?.pending.isEmpty == true)
        #expect(SetupFlow.isSatisfied(.finish, c.state.facts!))
        close(c)
    }

    @Test("Existing menu, setup and create work refuse conflicting controller actions")
    func admission() async throws {
        let gate = AppWorkGate(); let m = ReviewMachine(); let r = runner(m, gate: gate)
        let held = try gate.begin(.menu, label: "writing a report", vm: "winlab02").get()
        let refusal = try #require(r.run(.survey))
        #expect(refusal.description.contains("writing a report"))
        #expect(m.reads == 0 && r.inFlight == nil)
        let creator = create(gate: gate)
        creator.form.vmName = "winlab02"
        creator.create()
        #expect(creator.busyMessage?.contains("writing a report") == true && !creator.form.submitted)
        held.finish(); held.finish() // release is idempotent
        m.block = .survey
        #expect(r.run(.survey) == nil)
        creator.create()
        #expect(creator.busyMessage != nil && !creator.form.submitted)
        m.release.signal(); await settle(r)
        creator.create() // invalid form is now admitted, but can never create a real VM
        #expect(creator.busyMessage == nil && creator.form.submitted)
        let install = try gate.begin(.create, label: "installing Windows", vm: "winlab02").get()
        #expect(r.run(.applyChanges) != nil)
        let other = try gate.begin(.menu, label: "starting another VM", vm: "atelier").get()
        other.finish(); install.finish()
    }

    @Test("Install progress beats the setup note, and an unrelated VM keeps its menu")
    func installMenu() {
        let install = MenuInstall(vmName: "winlab02", stage: .copy, elapsed: 240, inTerminal: false, resumed: false)
        var status = MenuStatus(vmName: "winlab02", running: true, install: install, setupNote: "Set Up Winbar is open")
        #expect(MenuShape.statusText(status).contains("Installing Windows"))
        status.vmName = "winlab01"; status.setupNote = nil
        let a = MenuShape.items(MenuState(status: status))
        let creator = FakeEmbeddedCreate(); creator.hasRunningJob = true
        let c = controller(runner(ReviewMachine()), creator: creator); c.attach()
        SetupWindowController.presented = c
        defer { close(c); SetupWindowController.presented = nil }
        c.send(.newWindowsVM)
        #expect(a == MenuShape.items(MenuState(status: status, setupBusy: SetupWindowController.coordinatesVM)))
        #expect(SetupWindowController.menuNote == nil)
    }

    @Test("Embedding also closes an invisible or minimized standalone window")
    func hiddenCreateWindow() {
        let c = create(); let w = c.window as! ReviewWindow
        #expect(!w.isVisible)
        c.embed(.init(present: {}, hide: {}, window: { nil }, finished: { _ in }))
        #expect(w.closes == 1 && c.isEmbedded)
        c.unembed()
    }

    /// The detail is the menu's own, not the wizard's; with Set Up Winbar… in that menu (0.2.0) it
    /// names that first, for the person who clicked the menu and may never have opened Terminal, and
    /// keeps `winbar setup` as the other route. The dark build's sentence is the control.
    @Test("Menu Connect keeps its own failure detail, naming Set Up Winbar… first, and logs fallback exactly once")
    func menuFailure() throws {
        #expect(Connection.menuFailureDetail == "Set Up Winbar… in Winbar's menu walks you through installing Windows App (so does winbar setup in Terminal), or get it from the Mac App Store. Then try Connect again.")
        #expect(Connection.menuFailureDetail(setUpInMenu: false) == "Run winbar setup in Terminal and it offers to install Windows App for you, or get it from the Mac App Store. Then try Connect again.")
        var fallbacks = 0
        do {
            try Connection.openDesktop(host: "winlab02.local", user: "Bruno",
                failureDetail: Connection.menuFailureDetail, fallback: { fallbacks += 1 },
                accessibility: { true }, saved: { _ in false }, oneOff: { _, _ in false })
            Issue.record("The failed opener must throw")
        } catch let error as WinbarError {
            #expect(error.title == "Couldn't open Windows App")
            #expect(error.detail == Connection.menuFailureDetail)
        }
        #expect(fallbacks == 1)
    }

    @Test("Accessibility's actual guide opts out of network probing")
    func accessibilityGuide() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Winbar/Recipe.swift")
        let code = try String(contentsOf: source, encoding: .utf8)
        #expect(code.contains("SelfTest.launchAsApp(extraArguments: [\"--request-accessibility\", SelfTest.noPortProbe])"))
        #expect(SetupCopy.Connecting.localNetwork.contains("Windows App may ask"))
        #expect(SetupCopy.Connecting.networkRecovery.contains("Local Network"))
    }

    @Test("A safe restart refusal stays recoverable and does not change standalone copy")
    func recoveryCopy() throws {
        let error = try #require(Reconfigure.otherVMsRefusal("winlab02", changed: false, others: .success(["atelier"])))
        #expect(error.detail.contains("Stop your other VMs (or quit UTM), then try again."))
        #expect(SetupCopy.Tune.how("H6", "Terminal has Full Disk Access") == "Winbar has Full Disk Access")
        let pc = CreateCopy.setupNote(code: "N_PC_FAILED", text: "Run winbar setup")
        #expect(pc.contains("Saved PC step") && !pc.contains("winbar setup"))
        var f = JourneyFixtures.facts; f.answers.leftAlone.insert("C1")
        #expect(!SetupFlow.windowsAppSkipped(f))
        f.windowsApp = .missing; #expect(SetupFlow.windowsAppSkipped(f))
    }
}
