import AppKit
import SwiftUI
import Testing
@testable import Winbar

enum JourneyFixtures {
    static var facts: SetupFlow.Facts {
        var facts = SetupVMTests.facts()
        facts.windowsApp = .installed(version: "11.4")
        facts.guestAnswers = true
        facts.rdpHost = "winlab02.local"
        facts.rdpUser = "Bruno"
        facts.otherVMs = .running([])
        for id in SetupFlow.order {
            if let check = Recipe.check(id) { facts.rows[id] = SetupFlow.Row(check, .ok("Ready")) }
        }
        return facts
    }
    static func row(_ id: String, _ status: Status) -> SetupFlow.Row { SetupFlow.Row(Recipe.check(id)!, status) }
}

private final class JourneyMachine: SetupMachine {
    private var trusted = false
    private var saved = false
    private var accessible = false
    private var headless = false
    private var pending = ConfigChanges()
    init(trusted: Bool = false) { self.trusted = trusted }
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
        if step >= .certificate { read.statuses["H7"] = trusted ? .ok("Trusted") : .fixable("Not trusted") }
        if step >= .savedPC { read.statuses["C2"] = saved ? .ok("Saved") : .fixable("Not saved") }
        if step >= .connect { read.statuses["C3"] = accessible ? .ok("Allowed") : .manual("Not allowed", how: "Allow access") }
        if step >= .finish { read.statuses["H5"] = headless ? .ok("Headless") : .fixable("Console on") }
        return read
    }
    func perform(_ work: SetupRunner.Work, password: String?, facts: SetupFlow.Facts, job: SetupRunner.Job) throws {
        #expect((password != nil) == (work == .savePC))
        switch work {
        case .trustCertificate: trusted = true
        case .savePC:
            #expect(password == "synthetic-test-secret")
            saved = true
        case .guide(checkID: "C3"): accessible = true
        case .fix(checkID: "H5"):
            #expect(facts.answers.connected == true)
            pending.display = .headless
        case .applyChanges:
            headless = pending.display == .headless
            pending = ConfigChanges()
        default: break
        }
    }
}

@Suite("The complete setup journey uses one controller and one runner")
@MainActor struct SetupJourneyTests {
    @Test("A client automation failure can continue to sign-in without claiming a saved PC or desktop")
    func directSignInFallback() async {
        var facts = JourneyFixtures.facts
        facts.rows["C2"] = JourneyFixtures.row("C2", .manual("Client did not answer", how: "Use Windows App"))
        let runner = SetupRunner(machine: JourneyMachine(trusted: true), environment: .init(
            queue: DispatchQueue(label: "winbar.test.direct-sign-in"), callbacks: .main, clock: Date.init,
            keepAwake: { _ in {} }, processes: { _ in ([100], 101) }, workspace: NotificationCenter(), app: NotificationCenter()))
        let controller = SetupWindowController(state: SetupFixtures.state(.savedPC, facts: facts), art: nil,
            settings: .init(wizardShown: { false }, markShown: {}, armieHidden: { true }, hideArmie: {}),
            makeRunner: { runner }, makeCreator: { FakeEmbeddedCreate() })
        controller.attach()
        controller.credentials.password = "synthetic-test-secret"
        controller.send(.continueWithoutSavedPC)
        #expect(controller.state.step == .connect)
        #expect(controller.credentials.password.isEmpty)
        #expect(controller.state.answers.leftAlone.contains("C2"))
        #expect(controller.state.answers.connected == nil)
        for _ in 0..<300 {
            if controller.state.lastEnding?.work == .checkAgain(.connect), controller.state.inFlight == nil { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(controller.state.lastEnding?.work == .checkAgain(.connect))
        #expect(controller.state.step == .connect)
        #expect(controller.state.answers.connected == nil)
        #expect(controller.state.facts?.kind("C2") != .ok)
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
    }

    /// The done screen passes the switch (`SetupJourneyView.finish`), so 0.2.0's ending says where to
    /// run the window again; a build with the window dark wouldn't promise a menu item it hasn't got.
    @Test("The ending points at Set Up Winbar… exactly when the menu offers it")
    func endingPointsAtMenu() {
        let shipped = SetupCopy.Finish.doneBody(vm: "winlab02", .connected, canReopenFromMenu: SetupWindow.availableToEveryone)
        #expect(shipped.count == 2)
        #expect(shipped.last.map { String($0.characters) }?.hasPrefix("Run this window again from Set Up Winbar… in the menu") == true)
        let dark = SetupCopy.Finish.doneBody(vm: "winlab02", .windowsAppSkipped, canReopenFromMenu: false)
        #expect(dark.count == 1)
        #expect(String(dark[0].characters).contains("isn't installed"))
    }

    @Test("Installed Windows reaches a confirmed desktop, then an explicit headless restart")
    func fullJourney() async {
        let runner = SetupRunner(machine: JourneyMachine(), environment: .init(
            queue: DispatchQueue(label: "winbar.test.journey"), callbacks: .main, clock: Date.init,
            keepAwake: { _ in {} }, processes: { _ in ([100], 101) }, workspace: NotificationCenter(), app: NotificationCenter()))
        var marked = false
        let controller = SetupWindowController(state: SetupFixtures.state(.vm, facts: SetupVMTests.facts()), art: nil,
            settings: .init(wizardShown: { false }, markShown: { marked = true }, armieHidden: { true }, hideArmie: {}),
            makeRunner: { runner }, makeCreator: { FakeEmbeddedCreate() })
        func wait(_ work: SetupRunner.Work) async {
            for _ in 0..<300 {
                if controller.state.lastEnding?.work == work, controller.state.inFlight == nil { break }
                try? await Task.sleep(for: .milliseconds(10))
            }
            #expect(controller.state.lastEnding?.work == work)
            #expect(controller.state.lastEnding?.outcome == .finished)
            #expect(controller.state.inFlight == nil)
        }
        controller.attach()
        controller.send(.continueFromVM)
        await wait(.checkAgain(.tune))
        #expect(controller.state.step == .tune)
        controller.send(.next)
        await wait(.checkAgain(.certificate))
        controller.send(.skip("H7"))
        #expect(SetupCertificatePage.page(controller.state, facts: controller.state.facts!).phase == .skipped)
        controller.send(.perform(.run(.trustCertificate)))
        await wait(.trustCertificate)
        #expect(!controller.state.answers.leftAlone.contains("H7"))
        #expect(SetupCertificatePage.page(controller.state, facts: controller.state.facts!).phase == .verified)
        controller.send(.next)
        await wait(.checkAgain(.savedPC))
        controller.savePC(password: "synthetic-test-secret")
        await wait(.savePC)
        #expect(!String(describing: controller.state).contains("synthetic-test-secret"))
        controller.send(.next)
        await wait(.checkAgain(.connect))
        controller.send(.perform(.run(.guide(checkID: "C3"))))
        await wait(.guide(checkID: "C3"))
        controller.send(.perform(.run(.connect)))
        await wait(.connect)
        #expect(controller.state.answers.connectionOpened)
        #expect(controller.state.answers.connected == nil)
        controller.send(.connected(true))
        controller.send(.next)
        await wait(.checkAgain(.finish))
        #expect(SetupFlow.headlessOffer(controller.state.facts!) == .offer)
        controller.send(.perform(.run(.fix(checkID: "H5"))))
        await wait(.fix(checkID: "H5"))
        #expect(controller.state.facts?.pending.display == .headless)
        controller.send(.perform(.run(.applyChanges)))
        await wait(.applyChanges)
        #expect(controller.state.step == .connect && controller.state.answers.connected == nil)
        controller.send(.perform(.run(.connect)))
        await wait(.connect)
        controller.send(.connected(true))
        controller.send(.next)
        await wait(.checkAgain(.finish))
        controller.send(.finish)
        #expect(marked && controller.state.finished && controller.state.step == .finish)
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
    }

    @Test("Closing setup immediately clears the pending password without waiting for a view update")
    func closingClearsSecret() {
        var madeRunner = false
        let controller = SetupWindowController(art: nil,
            settings: .init(wizardShown: { false }, markShown: {}, armieHidden: { true }, hideArmie: {}),
            makeRunner: { madeRunner = true; return SetupRunner(machine: JourneyMachine(), environment: .init(
                queue: DispatchQueue(label: "winbar.test.unused"), callbacks: .main, clock: Date.init,
                keepAwake: { _ in {} }, processes: { _ in ([], nil) }, workspace: NotificationCenter(), app: NotificationCenter())) },
            makeCreator: { FakeEmbeddedCreate() })
        controller.credentials.password = "synthetic-test-secret"
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        #expect(controller.credentials.password.isEmpty)
        #expect(!madeRunner)
    }

    @Test("Even finishing with Windows App skipped defers the menu's first network probe")
    func networkPromptTiming() {
        var state = SetupWindowState()
        state.answers.started = true
        #expect(state.defersNetworkProbe)
        state.finished = true
        state.answers.leftAlone.insert("C1")
        #expect(state.defersNetworkProbe)
        state.connectionRequested = true
        #expect(!state.defersNetworkProbe)
    }

    @Test("A desktop confirmed for a different VM is not proof for this one")
    func changedVM() {
        var state = SetupFixtures.state(.finish, facts: JourneyFixtures.facts)
        state.answers.connected = true
        state.answers.connectionOpened = true
        state.answers.leftAlone = ["H5", "C2"]
        var changed = JourneyFixtures.facts
        changed.chosenVM = SetupVMTests.old.name
        let next = state.landing(changed)
        #expect(next.answers.connected == nil && !next.answers.connectionOpened)
        #expect(next.answers.leftAlone.isEmpty)
        #expect(next.secretEpoch == 1)
    }

    @Test("No desktop confirmation or unknown other VMs means no headless action")
    func headlessGuard() {
        var facts = JourneyFixtures.facts
        facts.rows["H5"] = JourneyFixtures.row("H5", .fixable("Console on"))
        #expect(!SetupRunner.Work.fix(checkID: "H5").applies(to: facts))
        facts.answers.connected = true
        facts.otherVMs = .unconfirmed("No answer")
        #expect(!SetupRunner.Work.fix(checkID: "H5").applies(to: facts))
        facts.otherVMs = .running(["atelier"])
        #expect(!SetupRunner.Work.fix(checkID: "H5").applies(to: facts))
        facts.otherVMs = .running([])
        #expect(SetupRunner.Work.fix(checkID: "H5").applies(to: facts))
    }

    @Test("The menu cannot select, create or reconfigure while setup owns the VM")
    func menuOwnership() {
        for running in [true, false] {
        let state = MenuState(status: MenuStatus(vmName: "winlab01", running: running), offersSetUp: true, setupBusy: true)
        let items = MenuShape.items(state).compactMap { spec -> MenuItem? in if case .item(let item) = spec { return item }; return nil }
        #expect(items.first { $0.action == .newWindowsVM }?.enabled == false)
        #expect(items.first { $0.action == .setUpWinbar }?.enabled == true)
        let actions: [MenuAction] = running ? [.connect, .shutDown, .forceStop, .restart, .toggleConsole, .sharedFolder] : [.start, .toggleConsole, .sharedFolder]
        for action in actions {
            #expect(items.contains { $0.action == action }, "The test must actually include \(action)")
            #expect(items.first { $0.action == action }?.enabled == false)
        }
        }
    }

    @Test("All remaining screens render in light and dark without a running VM")
    func pages() throws {
        for step in [WizardStep.tune, .certificate, .savedPC, .connect, .finish] {
            var facts = JourneyFixtures.facts
            facts.rows["H7"] = JourneyFixtures.row("H7", step == .certificate ? .fixable("Not trusted") : .ok("Trusted"))
            facts.rows["C2"] = JourneyFixtures.row("C2", step == .savedPC ? .fixable("Not saved") : .ok("Saved"))
            facts.rows["H5"] = JourneyFixtures.row("H5", .fixable("Console on"))
            var state = SetupFixtures.state(step, facts: facts)
            state.answers.connected = step == .finish ? true : nil
            state.facts?.answers = state.answers
            for appearance in [Snapshot.Appearance.light, .dark] {
                let png = try #require(Snapshot.png(SetupScreen(state: state, art: nil, send: { _ in }),
                                                   size: CGSize(width: 600, height: 620), appearance: appearance))
                try Snapshot.record(png, as: "journey-\(step.rawValue)-\(appearance.rawValue)")
                #expect((Snapshot.inked(png, rows: 0.18...0.5) ?? 0) > 0.02)
            }
        }
    }
}

@Suite("Connect's saved-PC and one-off paths are shared")
struct SharedConnectionTests {
    @Test("A missing permission never tries the tile; a missing tile falls back once")
    func fallback() throws {
        var saves = 0
        var fallbacks = 0
        let saved: (String) -> Bool = { _ in saves += 1; return false }
        let oneOff: (String, String?) -> Bool = { _, _ in fallbacks += 1; return true }
        #expect(try !Connection.openDesktop(host: "winlab01.local", user: "Bruno", accessibility: { false }, saved: saved, oneOff: oneOff))
        #expect(saves == 0 && fallbacks == 1)
        #expect(try !Connection.openDesktop(host: "winlab01.local", user: "Bruno", accessibility: { true }, saved: saved, oneOff: oneOff))
        #expect(saves == 1 && fallbacks == 2)
        #expect(try Connection.openDesktop(host: "winlab01.local", user: "Bruno", accessibility: { true }, saved: { _ in true }, oneOff: oneOff))
        #expect(fallbacks == 2)
        #expect(throws: WinbarError.self) {
            try Connection.openDesktop(host: "winlab01.local", user: nil, accessibility: { false }, oneOff: { _, _ in false })
        }
    }
}
