import AppKit
import Testing
@testable import Winbar

final class FakeEmbeddedCreate: EmbeddableCreate {
    var isEmbedded = false
    var hasRunningJob = false
    var embeds = 0
    var closes = 0
    var host: CreateWindowController.EmbedHost?
    func embed(_ host: CreateWindowController.EmbedHost) { embeds += 1; isEmbedded = true; self.host = host }
    func unembed() { isEmbedded = false; host = nil }
    func hostShown() {}
    func hostClosed() { closes += 1 }
}

private final class VMHandoffMachine: SetupMachine {
    var selected = SetupVMTests.old.name
    func readings(through step: WizardStep, answers: SetupFlow.Answers, after work: SetupRunner.Work?,
                  job: SetupRunner.Job?) -> SetupRunner.Readings {
        var read = SetupRunner.Readings()
        read.utm = SetupFixtures.installed
        read.utmAnswers = .answered
        read.vms = .success([SetupVMTests.old, SetupVMTests.new])
        read.chosenVM = selected
        return read
    }
    func perform(_ work: SetupRunner.Work, password: String?, facts: SetupFlow.Facts, job: SetupRunner.Job) throws {
        if case .chooseVM(let name, let id) = work {
            #expect(name == SetupVMTests.new.name && id == SetupVMTests.new.id)
            selected = name
        }
    }
}

@Suite("The wizard's real controller receives the install callback")
@MainActor struct SetupVMControllerTests {
    @Test("The returned id selects the new VM before tune, retaining the install warnings")
    func completion() async {
        let machine = VMHandoffMachine()
        let runner = SetupRunner(machine: machine, environment: .init(
            queue: DispatchQueue(label: "winbar.test.vm-handoff"), callbacks: .main, clock: Date.init,
            keepAwake: { _ in {} }, processes: { _ in ([100], 101) },
            workspace: NotificationCenter(), app: NotificationCenter()))
        let creator = FakeEmbeddedCreate()
        let controller = SetupWindowController(state: SetupFixtures.state(.vm, facts: SetupVMTests.facts(chosen: SetupVMTests.old)),
            art: nil, settings: .init(wizardShown: { false }, markShown: {}, armieHidden: { true }, hideArmie: {}),
            makeRunner: { runner }, makeCreator: { creator })
        controller.attach()
        controller.send(.newWindowsVM)
        let warnings = [CreateMessage(code: "W_MEDIA_LEFT", text: "The setup disk could not be removed.", at: testMoment())]
        creator.host?.finished(.installed(id: SetupVMTests.new.id, name: SetupVMTests.new.name, messages: warnings))
        for _ in 0..<200 {
            if controller.state.step == .tune { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(controller.state.step == .tune)
        #expect(controller.state.facts?.chosen?.id == SetupVMTests.new.id)
        #expect(controller.state.installMessages == warnings)
        #expect(!creator.isEmbedded && !controller.state.creating)
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
    }
}

@Suite("The create views hand the correct VM back to setup")
struct SetupVMTests {
    static let old = VMInfo(id: "5A1E0C3D-0000-4000-8000-000000000001", name: "winlab01", backend: "qemu", icon: "windows")
    static let new = VMInfo(id: "5A1E0C3D-0000-4000-8000-000000000002", name: "winlab02", backend: "qemu", icon: "windows")
    static func facts(chosen: VMInfo = new) -> SetupFlow.Facts {
        var facts = SetupFixtures.facts(utm: SetupFixtures.installed, answers: .answered, vms: .listed([old, new]))
        facts.chosenVM = chosen.name
        facts.vmRunning = true
        return facts
    }

    @Test("A wizard install always selects its new VM and defers RDP and headless")
    func plan() {
        var plan = testPlan()
        plan.select = false
        let embedded = CreateWindowController.plan(plan, embedded: true)
        #expect(embedded.select && embedded.inSetupWindow == true)
        #expect(CreateWindowController.plan(plan, embedded: false) == plan)
    }

    @Test("Only a successful identified install hands back; its warnings survive")
    func result() {
        var state = testState(vmID: Self.new.id, outcome: .done)
        state.messages = [.init(code: "W_MEDIA_LEFT", text: "The setup disk could not be removed.", at: testMoment())]
        #expect(CreateWindowController.embeddedEnd(for: state, embedded: true) ==
                .installed(id: Self.new.id, name: state.plan.vmName, messages: state.messages))
        #expect(CreateWindowController.embeddedEnd(for: state, embedded: false) == nil)
        state.plan.select = false
        #expect(CreateWindowController.embeddedEnd(for: state, embedded: true) == nil)
        state.plan.select = true
        for outcome in [CreateJobState.Outcome.failed, .cancelled] {
            state.outcome = outcome
            #expect(CreateWindowController.embeddedEnd(for: state, embedded: true) == nil)
        }
        state.outcome = .done
        state.vmID = nil
        #expect(CreateWindowController.embeddedEnd(for: state, embedded: true) == nil)
    }

    @Test("The previous selected VM cannot satisfy the new install's handoff")
    func identity() {
        #expect(SetupWindowState.stepAfterInstall(Self.facts(chosen: Self.old), expectedID: Self.new.id) == .vm)
        #expect(SetupWindowState.stepAfterInstall(Self.facts(), expectedID: Self.new.id) == .tune)
        #expect(SetupWindowState.stepAfterInstall(Self.facts(), expectedID: nil) == .vm)
        var stopped = Self.facts()
        stopped.vmRunning = false
        #expect(SetupWindowState.stepAfterInstall(stopped, expectedID: Self.new.id) == .vm)
    }

    @Test("A same-named replacement cannot be selected with a stale VM id")
    func replaced() {
        #expect(SetupRunner.Work.chooseVM(Self.new.name, id: Self.new.id).applies(to: Self.facts()))
        #expect(!SetupRunner.Work.chooseVM(Self.new.name, id: Self.old.id).applies(to: Self.facts()))
    }

    @Test("An old read never advances an install handoff, and reads cannot hide an embedded install")
    func freshness() {
        var state = SetupFixtures.state(.vm, facts: Self.facts())
        state.afterInstall = testMoment()
        state.installedVMID = Self.new.id
        let early = SetupRunner.Ending(work: .checkAgain(.vm), outcome: .finished, facts: Self.facts(), slept: false,
                                       started: state.afterInstall!.addingTimeInterval(-10))
        let waiting = state.applying(.ended(early))
        #expect(waiting.step == .vm && waiting.afterInstall != nil)
        let fresh = SetupRunner.Ending(work: .checkAgain(.vm), outcome: .finished, facts: Self.facts(), slept: false,
                                       started: state.afterInstall!.addingTimeInterval(1))
        let done = state.applying(.ended(fresh))
        #expect(done.step == .tune && done.afterInstall == nil)
        state.creating = true
        #expect(state.landing(SetupFlow.Facts()).step == .vm)
    }

    @Test("Hide keeps a running install; closing a form or ending returns to setup")
    func lifecycle() {
        #expect(CreateWindowController.closing(embedded: true, job: testState()) == .hideHost)
        #expect(CreateWindowController.closing(embedded: true, job: nil) == .handBack)
        #expect(CreateWindowController.closing(embedded: true, job: testState(outcome: .failed)) == .handBack)
        #expect(CreateWindowController.presentation(embedded: true) == .host)
        let ended = testState(outcome: .done)
        #expect(!CreateWindowController.adopts(ended, dismissed: ended.id))
        #expect(CreateWindowController.adopts(testState(), dismissed: ended.id))
    }
}
