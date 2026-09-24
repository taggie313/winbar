import AppKit
import AVFoundation
import SwiftUI
import Testing
@testable import Winbar

// Armie on every page (gui-wizard.md §2b, as the owner widened it on 2026-09-24, with Astra's rules for
// her concerned and pointing poses). Where he stands and what he says is decided by one pure function
// (`ArmieCue`), so that is held against a table of every page and state first — silent, saying
// something, working, hopping, concerned — and against the rules that must hold on every state:
// silent beside a permission, a password or a question; never moving while idle; concern never the
// hop. The hop is followed through the window's own events, to show it plays once. Then each
// placement is drawn with him and with him hidden, and the real player is looked for in the drawn
// window.
//
// Every state is invented (SetupFixtures, JourneyFixtures, a made-up Mac for the create views);
// nothing here reads this Mac's settings or reaches UTM, a VM, Windows App or the user's defaults.

private typealias F = SetupFixtures

enum ArmieFixtures {
    /// Step 2 on a Mac whose UTM has no VM at all: the **Install Windows…** card.
    static var noVM: SetupWindowState {
        F.state(.vm, facts: F.facts(utm: F.installed, answers: .answered, vms: .listed([])))
    }

    /// The same card after the VM Winbar looked after was deleted in UTM: "UTM no longer has a VM
    /// named …" above it.
    static var vmGone: SetupWindowState {
        var state = noVM
        state.facts?.chosenVM = "winlab01"
        return state
    }

    /// Step 2 with the chosen VM stopped, just after **Start It**, while `Setup.waitForWindows` waits.
    static var starting: SetupWindowState {
        var facts = SetupVMTests.facts()
        facts.vmRunning = false
        var state = F.state(.vm, facts: facts,
                            inFlight: F.flight(.startVM(SetupVMTests.new.name), line: SetupCopy.waitingForWindows))
        state.lines = [SetupCopy.waitingForWindows]
        state.linesStarted = F.started
        return state
    }

    /// The same wait once its three minutes ran out without the guest agent.
    static var startTimedOut: SetupWindowState {
        var state = starting
        state.inFlight?.line = SetupCopy.agentNotYet
        state.lines.append(SetupCopy.agentNotYet)
        return state
    }

    /// The done screen, just after Connect was answered **Yes** and **Finish** pressed, which earns
    /// the hop (`SetupWindowController.send(.finish)`).
    static var done: SetupWindowState {
        var state = F.state(.finish, facts: JourneyFixtures.facts)
        state.answers.connectionOpened = true
        state.answers.connected = true
        state.finished = true
        state.armieHop = .finish
        state.facts?.answers = state.answers
        return state
    }

    /// Step 6 just after **Connect**: Winbar probing the Remote Desktop port, which raises macOS's Local
    /// Network prompt, before Windows App opens and may ask the person to sign in.
    static var connecting: SetupWindowState {
        var state = JourneyFixtures.page(.connect)
        state.inFlight = F.flight(.connect)
        return state
    }

    /// The same page after **No**.
    static var doneNo: SetupWindowState {
        var state = done
        state.answers.connected = false
        state.facts?.answers = state.answers
        return state
    }

    /// Step 2 with the New Windows VM views as its body (`SetupWindowState.creating`).
    static var creating: SetupWindowState {
        var state = noVM
        state.creating = true
        return state
    }

    static func hidden(_ state: SetupWindowState) -> SetupWindowState {
        var state = state
        state.armieHidden = true
        return state
    }

    static func failed(_ state: SetupWindowState, _ work: SetupRunner.Work) -> SetupWindowState {
        var state = state
        let problem = SetupRunner.Problem(title: "UTM didn't start “winlab02”", detail: "It answered with error -1712.")
        state.lastEnding = SetupRunner.Ending(work: work, outcome: .failed(problem), facts: state.facts!, slept: false,
                                              started: F.started)
        return state
    }

    /// Tune with one setting Winbar can fix, the rest right.
    static var tuneNeedsFix: SetupWindowState {
        var state = JourneyFixtures.page(.tune)
        state.facts?.rows["G1"] = JourneyFixtures.row("G1", .fixable("Power plan is High performance"))
        return state
    }

    // The create views' side: a made-up Mac, and an install placed relative to the controller's clock,
    // which doesn't tick until a window opens, so the elapsed times read the same on every draw.

    /// Its environment reaches nothing: no job on this Mac is looked for, no form refreshed from UTM,
    /// no window shown, and the work gate is its own rather than the app's. `ownsJob` says whose
    /// install it draws: by default the app's own, as **Install Windows…** starts it, with the app's footer
    /// and **Cancel Install…**; false for one running in Terminal that the wizard is only showing.
    /// Answered here rather than by claiming the process-wide flag, which other tests draw from.
    /// `pressed` records the install's button presses instead of carrying them out
    /// (`CreateWindowController.perform`), for the tests that press them.
    @MainActor static func createController(ownsJob: Bool = true,
                                            pressed: ((CreateJobView.Action.Press) -> Void)? = nil) -> CreateWindowController {
        CreateWindowController(facts: CreateFormFacts(
            mac: MacFacts(topTierCores: 8, totalCores: 12, memoryBytes: 32 << 30, shortUserName: "rosa"),
            utmInstalled: true, utmVersion: "4.7.5", fileVaultOn: true, freeGB: 400, volumeName: "atelier",
            existingVMNames: nil, menuVMName: nil),
            environment: .init(currentJob: { nil }, refreshForm: { _ in }, show: { _ in }, workGate: AppWorkGate(),
                               ownsJob: { ownsJob }, pressed: pressed))
    }

    static let plan = CreatePlan(vmName: "winlab02", isoPath: "/Users/rosa/Downloads/Win11_25H2_English_Arm64_v2.iso",
                                 edition: testEdition(), cores: 6, memoryMiB: 16384, diskGiB: 128,
                                 options: CreateOption.defaults, noVisualTweaks: false, userName: "rosa",
                                 computerName: "winlab02", regional: nil, select: true, keepConsole: false)

    static func job(stage: CreateStage = .copy, now: Date = F.started, outcome: CreateJobState.Outcome? = nil,
                    detail: String? = "7.9 GB written to the VM's disk", stalled: StallState? = nil,
                    messages: [(String, String)] = [], failure: CreateFailure? = nil) -> CreateJobState {
        let started = now.addingTimeInterval(-872.25)
        return CreateJobState(id: "create-20260923-101500-5d2c7a10", plan: plan,
                              vmID: SetupVMTests.new.id, stage: stage, detail: detail,
                              startedAt: started, updatedAt: now.addingTimeInterval(-20.25),
                              finishedAt: outcome == nil ? nil : now, outcome: outcome, restarts: 1,
                              bytesWritten: 7_900_000_000, shown: messages.map(\.0), stalled: stalled,
                              messages: messages.map { CreateMessage(code: $0.0, text: $0.1, at: started) },
                              failure: failure, mediaDir: "/tmp/winbar-media/5d2c7a10.noindex",
                              logPath: "/tmp/winbar-media/winbar.log", watched: outcome == nil,
                              stageStartedAt: now.addingTimeInterval(-588.25))
    }

    /// W_STALL as the job raises it when the VM goes quiet: the box on a stalled page.
    static let stall = [(InstallAlert.stall.rawValue, CreateCopy.wStall(vmName: plan.vmName))]

    /// What a wizard install has commonly said by the copy stage: preflight's battery caution, and
    /// the saved PC from the media stage. Neither silences him (`SetupCopy.Armie.silences`).
    static let notes = [
        ("W_BATTERY", "Your Mac is on battery. Installing Windows keeps several cores busy for ten minutes or more, "
            + "so plugging in is a good idea."),
        ("N_PC_SAVED", CreateCopy.nPCSaved(name: plan.vmName)),
    ]

    /// Preflight's words about the Mac itself, the battery caution and the FileVault note, neither of
    /// which silences him.
    static let preflightNotes = [
        notes[0],
        ("N_PW_FILEVAULT_OFF", CreateCopy.nPWFileVaultOff),
    ]

    /// E_TIMEOUT in the job's own words (`CreateJobRun`): the render drew a next step the job never
    /// sends, and so hid the Terminal command the real one gave inside Set Up Winbar.
    static let stoppedWaiting = CreateFailure(code: "E_TIMEOUT",
                                              title: "Windows still hadn't finished installing after 2 hours, so Winbar "
                                                + "stopped waiting.",
                                              detail: "The VM is still running: look at its window in UTM to see where it "
                                                + "stopped.",
                                              nextStep: "To start over: winbar create --cancel \"winlab02\", then create it again.")

    /// Every page state the tests below hold him against: steps 0 and 1, the recovery pages, the five
    /// journey pages, and the states this suite adds, by name.
    static var everyState: [(String, SetupWindowState)] {
        var all = F.screens.map { ($0.name, $0.state) }
        all += SetupRecoveryFixtures.screens.map { ("recovery-" + $0.0, $0.1) }
        all += JourneyFixtures.pages.map { ("journey-\($0)", JourneyFixtures.page($0)) }
        all += [("starting", starting), ("start-timed-out", startTimedOut), ("vm-gone", vmGone), ("done", done),
                ("done-no", doneNo), ("did-it-work", JourneyFixtures.didItWork), ("tune-needs-fix", tuneNeedsFix),
                ("connecting", connecting)]
        return all
    }
}

private typealias A = ArmieFixtures

/// How he stands on a page, in the few words the rules are written in.
enum Stands: Equatable, CustomStringConvertible {
    case absent
    /// Standing still, without a word.
    case silent
    /// Standing still, with a line.
    case says
    /// The working loop, without a word, or with his line for the wait (`narrates`).
    case working, narrates
    case hop
    case concerned
    case pointing(ArmieArt.Side)
    /// What no rule allows: concern or a point with words.
    case talkingWrongly

    init(_ cue: ArmieCue?) {
        guard let cue else { self = .absent; return }
        switch (cue.pose, cue.line != nil) {
        case (.rest, false): self = .silent
        case (.rest, true): self = .says
        case (.working, false): self = .working
        case (.working, true): self = .narrates
        case (.done, _): self = .hop
        case (.concerned, false): self = .concerned
        case (.pointing(let side), false): self = .pointing(side)
        case (.concerned, true), (.pointing, true): self = .talkingWrongly
        }
    }

    var description: String {
        switch self {
        case .absent: "absent"
        case .silent: "silent"
        case .says: "says"
        case .working: "working"
        case .narrates: "narrates"
        case .hop: "hop"
        case .concerned: "concerned"
        case .pointing(let side): "pointing \(side)"
        case .talkingWrongly: "talking wrongly"
        }
    }
}

// MARK: - Where he stands

@Suite("Armie on every page: silent beside a question, working while work runs, concerned beside trouble")
struct ArmiePlacementTests {
    /// The table: every page state the fixtures draw, and how he stands on it.
    static let expected: [String: Stands] = [
        // The welcome introduces him.
        "welcome": .says,
        // Step 1: the first read and a pressed Check Again are work; UTM's install is narrated, except
        // Homebrew's update, which can raise up to three of macOS's prompts part way: still and silent.
        "reading": .working, "rereading": .working,
        "installing": .narrates, "installing-download": .narrates, "refused": .narrates, "updating": .silent,
        "installing-armie-hidden": .absent,
        // UTM to install is the ordinary way through, not trouble.
        "needs-utm-download": .silent, "needs-utm-homebrew": .silent, "needs-utm-update": .silent,
        "needs-utm-update-by-hand": .silent,
        // Trouble: a copy that isn't the real UTM, an install that failed, UTM answering with an error,
        // a list that failed.
        "needs-utm-not-utm": .concerned, "install-failed": .concerned, "utm-failed": .concerned, "list-failed": .concerned,
        // Permissions: asked, predicted, awaited, refused.
        "ask-utm": .silent, "ask-utm-homebrew": .silent, "ask-utm-downloaded": .silent, "settling": .silent,
        "settling-homebrew": .silent, "utm-silent": .silent, "utm-silent-decided": .silent, "utm-denied": .silent,
        "done": .silent, "done-no-windows-app": .silent,
        // Step 2.
        "vm-one": .silent, "vm-none": .says, "vm-choose": .silent, "vm-running": .silent,
        "starting": .narrates, "start-timed-out": .concerned, "vm-gone": .concerned,
        "recovery-vm-ready": .silent, "recovery-vm-stopped-restart-owed": .silent, "recovery-vm-choose-another": .silent,
        "recovery-vm-none": .says, "recovery-vm-linux-only": .silent, "recovery-vm-installing": .working,
        "recovery-vm-unlisted": .silent, "recovery-vm-messages": .concerned,
        // Tune: settings that need Ben have his line; all right, he stands by.
        "journey-tune": .silent, "tune-needs-fix": .says, "recovery-tune-mixed": .says,
        // The certificate: the approval is a permission; no certificate for the name is trouble.
        "journey-certificate": .silent, "recovery-certificate-waiting": .silent, "recovery-certificate-needs": .concerned,
        // The saved PC: the password field; a save or a read running.
        "journey-savedPC": .silent, "recovery-saved-no-user": .silent, "recovery-saved-checking": .working,
        "recovery-saved-saving": .working, "recovery-saved-done": .silent,
        // Connect: Local Network predicted, then asked while Connect runs, the question, and every way it
        // didn't work.
        "journey-connect": .silent, "recovery-connect-ready": .silent, "connecting": .silent, "did-it-work": .silent,
        "recovery-connect-failed": .concerned, "recovery-connect-failed-answering": .concerned,
        "recovery-connect-failed-answering-one-off": .concerned, "recovery-connect-failed-not-answering": .concerned,
        "recovery-connect-failed-not-answering-headless": .concerned,
        "recovery-connect-failed-not-answering-unread": .concerned, "recovery-connect-failed-unchecked": .concerned,
        // Finish: the tiles are a question; another VM running is trouble.
        "journey-finish": .silent, "recovery-finish-staged": .silent, "recovery-finish-not-offered": .silent,
        "recovery-finish-others": .concerned,
        // The finished page: the hop after Yes, concern after No, standing by where Connect wasn't tried.
        "done-no": .concerned, "recovery-finish-done-no-connection": .silent,
        "recovery-finish-done-app-now-installed": .silent,
    ]

    @Test("Every page state has the pose and the words the table gives it")
    func table() {
        var seen: Set<String> = []
        for (name, state) in ArmieFixtures.everyState {
            // "done" is both step 1's finished look and the finished page; the finished page is checked below.
            if name == "done", state.finished {
                #expect(Stands(ArmieCue.cue(state)) == .hop)
                continue
            }
            seen.insert(name)
            #expect(Stands(ArmieCue.cue(state)) == Self.expected[name], "\(name)")
        }
        // The table names no state that isn't drawn, so a renamed fixture can't leave a row unchecked.
        #expect(Set(Self.expected.keys).subtracting(seen).isEmpty, "\(Set(Self.expected.keys).subtracting(seen))")
    }

    /// Beside a permission, a password field or a question: never a word, never a point. Held against
    /// every state that has one, found from the page rather than from the fixtures' names.
    @Test("Silent beside every permission, password field and question")
    func silentBesideQuestions() {
        var checked = 0
        for (name, state) in ArmieFixtures.everyState where Self.asksSomething(state) {
            checked += 1
            let cue = ArmieCue.cue(state)
            #expect(cue?.line == nil, "\(name)")
            if case .pointing? = cue?.pose { Issue.record("\(name): pointing beside a question") }
        }
        #expect(checked > 15)
    }

    /// A macOS prompt awaited or predicted, the password field, which VM, the finish's tiles, Decrypt
    /// C:, the desktop question, Accessibility.
    static func asksSomething(_ state: SetupWindowState) -> Bool {
        if state.inFlight?.waitingFor != nil { return true }
        guard let facts = state.facts, state.inFlight == nil else { return false }
        switch state.step {
        case .lookAround:
            switch SetupFlow.lookAround(facts) {
            case .askUTM, .utmSilent, .utmDenied: return true
            default: return false
            }
        case .vm:
            if case .choose(let choice, _) = SetupVMView.screen(state, facts), choice != .none { return true }
            return false
        case .tune: return SetupFlow.bitLockerQuestion(facts) != nil
        case .certificate: return SetupCertificatePage.page(state, facts: facts).phase == .needsApproval
        case .savedPC: if case .save = SetupFlow.savedPC(facts) { return true }; return false
        case .connect:
            switch SetupFlow.connect(facts) {
            case .allowAccessibility, .ready, .didItWork: return true
            default: return false
            }
        case .finish: return !state.finished && SetupFinishPage.choice(facts) != nil
        case .welcome: return false
        }
    }

    /// Nothing runs: no work, no read, no install anywhere. He never moves then: the loop is for work,
    /// and the hop only for the moment a step is done, which none of these states has.
    @Test("Never moving while nothing runs")
    func stillWhileIdle() {
        for (name, state) in ArmieFixtures.everyState where state.inFlight == nil && state.afterInstall == nil
            && state.facts?.installRunning != true && !state.finished {
            let pose = ArmieCue.cue(state)?.pose
            #expect(pose != .working && pose != .done, "\(name)")
        }
    }

    /// Astra's rule: concern is still and silent, and a failure is never met with the hop or the loop,
    /// not even while a retry runs under the card that says it failed. Where the retry's own progress
    /// takes the card's place (UTM's install, the certificate's approval), he goes with the page.
    @Test("Beside a failure he is concerned: never the hop, never the loop, never a word")
    func concernedBesideFailures() {
        var restart = JourneyFixtures.page(.finish)
        restart.facts?.pending = ConfigChanges(cpuCores: 6)
        let failing: [(String, SetupWindowState, cardStays: Bool)] = [
            ("step 2's empty state", A.failed(A.noVM, .checkAgain(.vm)), true),
            ("a start", A.failed(A.starting, .startVM(SetupVMTests.new.name)), true),
            ("tune, fixing", A.failed(A.tuneNeedsFix, .fix(checkID: "G1")), true),
            ("the finish's restart", A.failed(restart, .applyChanges), true),
            ("the certificate", A.failed(JourneyFixtures.page(.certificate), .trustCertificate), false),
            ("step 1's install", F.installFailed, false),
        ]
        for (name, state, cardStays) in failing {
            #expect(ArmieCue.cue(state) == .concerned, "\(name)")
            var retrying = state
            retrying.inFlight = F.flight(state.lastEnding!.work)
            if cardStays {
                #expect(ArmieCue.cue(retrying) == .concerned, "\(name), retrying")
            } else {
                #expect(ArmieCue.cue(retrying) != .concerned, "\(name), retrying")
            }
            var hopped = state
            hopped.armieHop = state.step
            #expect(ArmieCue.cue(hopped)?.pose != .done, "\(name), hopped")
        }
        // Every concerned pose anywhere is silent.
        for (name, state) in ArmieFixtures.everyState where ArmieCue.cue(state)?.pose == .concerned {
            #expect(ArmieCue.cue(state)?.line == nil, "\(name)")
        }
    }

    @Test("The certificate's own Stop Waiting, and one not read yet, are no trouble")
    func certificateNotTrouble() {
        var stopped = JourneyFixtures.page(.certificate)
        stopped.lastEnding = SetupRunner.Ending(work: .trustCertificate, outcome: .cancelled, facts: stopped.facts!,
                                                slept: false, started: F.started)
        #expect(ArmieCue.cue(stopped) == .quiet)
        var unread = JourneyFixtures.page(.certificate)
        unread.facts?.rows["H7"] = nil
        #expect(ArmieCue.cue(unread) == .quiet)
    }

    @Test("A row Windows didn't answer for, or a Fix that didn't work, is trouble; BitLocker's question is a question")
    func tuneRows() {
        var failedFix = A.tuneNeedsFix
        failedFix.facts?.rows["G1"]?.failure = "Windows refused the change."
        #expect(ArmieCue.cue(failedFix) == .concerned)
        var unanswered = JourneyFixtures.page(.tune)
        unanswered.facts?.rows["G3"] = JourneyFixtures.row("G3", .error("Windows didn't answer"))
        #expect(ArmieCue.cue(unanswered) == .concerned)
        var bitLocker = A.tuneNeedsFix
        bitLocker.facts?.rows["G9"] = JourneyFixtures.row("G9", .fixable("BitLocker is on"))
        bitLocker.facts?.disk = .init(imagesSeen: true, places: [.init(storage: .startupDisk, encrypted: true)])
        #expect(SetupFlow.bitLockerQuestion(bitLocker.facts!) != nil)
        #expect(ArmieCue.cue(bitLocker) == .quiet)
    }

    @Test("A read nobody pressed leaves him as he was; one somebody pressed is work")
    func reads() {
        var refreshing = A.tuneNeedsFix
        refreshing.inFlight = F.flight(.lookAgain(.tune, forgetting: .statuses))
        refreshing.refreshing = true
        #expect(ArmieCue.cue(refreshing) == ArmieCue.cue(A.tuneNeedsFix))
        var pressed = refreshing
        pressed.refreshing = false
        #expect(ArmieCue.cue(pressed) == .working)
    }

    @Test("The install's pages: the stage's line, silent beside macOS asking, concerned beside trouble")
    func installing() {
        for stage in CreateStage.allCases {
            #expect(Stands(ArmieCue.installing(A.job(stage: stage))) == .narrates, "\(stage)")
        }
        #expect(Stands(ArmieCue.installing(A.job(messages: A.notes))) == .narrates)
        #expect(Stands(ArmieCue.installing(A.job(stalled: .writing))) == .narrates)
        #expect(ArmieCue.installing(A.job(stalled: .quiet, messages: A.stall)) == .concerned)
        #expect(ArmieCue.installing(A.job(stalled: .busy, messages: A.stall)) == .concerned)
        #expect(ArmieCue.installing(A.job(stage: .oobe, outcome: .failed, failure: A.stoppedWaiting)) == .concerned)
        // A warning the page keeps boxed in view.
        #expect(ArmieCue.installing(A.job(messages: [("W_TIMEMACHINE", "Couldn't keep the setup disk out of Time "
                                                         + "Machine.")])) == .concerned)
        // A note that something didn't work, and the error asking for a key press in UTM's window,
        // while the install still runs: concern, not the loop.
        #expect(ArmieCue.installing(A.job(messages: [("N_PC_FAILED", "Winbar couldn't save this PC.")])) == .concerned)
        #expect(ArmieCue.installing(A.job(stage: .boot, messages: [(InstallAlert.bootNoPrompt.rawValue,
                                                                    "Click into the VM's window and press a key.")]))
            == .concerned)
        // A stall that has cleared: the VM writing again, he works on without a line.
        #expect(ArmieCue.installing(A.job(stalled: .writing, messages: A.stall)) == .working)
        // The job's Automation detail, which the running row turns into P_AUTOMATION, is a permission.
        let asking = A.job(stage: .check, detail: CreateCopy.automationDetail(app: "Winbar"))
        #expect(CreateProgress.detail(asking.detail) == CreateCopy.pAutomation)
        #expect(ArmieCue.installing(asking) == .quiet)
        #expect(ArmieCue.installing(A.job(stage: .finish, outcome: .done)) == .quiet)
        #expect(ArmieCue.form == .quiet)
    }

    @Test("Hide Armie takes him off every page, the install and the popover")
    func hidden() {
        let art = ArmieArt(still: NSImage(size: NSSize(width: 2, height: 2)), working: nil, done: nil)
        for (name, state) in ArmieFixtures.everyState {
            #expect(ArmieCue.cue(A.hidden(state)) == nil, "\(name)")
            #expect(SetupScreen.besideTitle(A.hidden(state)) == nil, "\(name)")
        }
        #expect(ArmieHost.lent(A.creating, art: art, send: { _ in }) != nil)
        #expect(ArmieHost.lent(A.hidden(A.creating), art: art, send: { _ in }) == nil)
        // No art in the bundle is no Armie either.
        #expect(ArmieHost.lent(A.creating, art: nil, send: { _ in }) == nil)
        #expect(ArmieCue.popover(hidden: true, icon: CGPoint(x: 900, y: 1100), figure: CGPoint(x: 700, y: 1060)) == nil)
    }

    /// The arrivals draw him themselves, larger; every other page has him beside its title.
    @Test("Beside the title on every page with one; the welcome and the finished page draw him larger")
    func whereDrawn() {
        #expect(SetupScreen.besideTitle(ArmieFixtures.everyState.first { $0.0 == "welcome" }!.1) == nil)
        #expect(SetupScreen.besideTitle(A.done) == nil)
        #expect(SetupScreen.besideTitle(A.creating) == nil)
        #expect(SetupScreen.besideTitle(A.tuneNeedsFix) == ArmieCue.cue(A.tuneNeedsFix))
    }

    /// Only from where the popover and the icon were laid out, and only toward a side: an icon more
    /// above him than beside him, one not shown, or one not laid out yet, and he stands by.
    @MainActor @Test("In the popover he points toward the icon's side, or stands by")
    func popover() {
        let figure = CGPoint(x: 1000, y: 1040)
        #expect(ArmieCue.popover(hidden: false, icon: CGPoint(x: 1150, y: 1100), figure: figure)
            == ArmieCue(pose: .pointing(.right)))
        #expect(ArmieCue.popover(hidden: false, icon: CGPoint(x: 850, y: 1100), figure: figure)
            == ArmieCue(pose: .pointing(.left)))
        // Straight above, or more above than beside: Astra drew no point upwards.
        #expect(ArmieCue.popover(hidden: false, icon: CGPoint(x: 1010, y: 1100), figure: figure) == .quiet)
        #expect(ArmieCue.popover(hidden: false, icon: CGPoint(x: 1050, y: 1100), figure: figure) == .quiet)
        #expect(ArmieCue.popover(hidden: false, icon: nil, figure: figure) == .quiet)
        #expect(ArmieCue.popover(hidden: false, icon: CGPoint(x: 1150, y: 1100), figure: nil) == .quiet)
        // The model the popover draws, from the content's frame on screen and the icon's.
        let armie = MenuBarIntroArmie(art: nil, hidden: false)
        #expect(armie.cue == .quiet)
        let content = CGRect(x: 1000, y: 900, width: 336, height: 110)
        let icon = CGRect(x: 1150, y: 1030, width: 22, height: 24)
        armie.laidOut(content: content, icon: icon)
        #expect(armie.cue == ArmieCue(pose: .pointing(.right)))
        // The icon no longer shown: he doesn't point at it.
        armie.laidOut(content: content, icon: nil)
        #expect(armie.cue == .quiet)
        // The popover pushed right, past the icon (by the screen's edge): he turns the other way.
        armie.laidOut(content: content.offsetBy(dx: 300, dy: 0), icon: icon)
        #expect(armie.cue == ArmieCue(pose: .pointing(.left)))
        // Hidden, he isn't in the popover at all.
        let hidden = MenuBarIntroArmie(art: nil, hidden: true)
        hidden.laidOut(content: content, icon: icon)
        #expect(hidden.cue == nil && !hidden.shown)
    }

    @Test("His lines stay deadpan: no exclamation, no question")
    func deadpan() {
        for moment in SetupCopy.Armie.Moment.all {
            let line = SetupCopy.Armie.line(moment)
            #expect(!line.contains("!") && !line.contains("?"), "\(line)")
        }
    }

    /// What he says on any page is one of his moments' lines: no page makes up words of its own.
    @Test("Every line he says is one of his moments'")
    func linesAreMoments() {
        let lines = Set(SetupCopy.Armie.Moment.all.map(SetupCopy.Armie.line))
        for (name, state) in ArmieFixtures.everyState {
            if let line = ArmieCue.cue(state)?.line { #expect(lines.contains(line), "\(name)") }
        }
    }
}

// MARK: - The hop, once

/// The window's two settings, in memory, so Hide Armie is remembered here and not in this Mac's defaults.
private final class ArmieSettings {
    var hidden = false
    var settings: SetupSettings {
        SetupSettings(wizardShown: { true }, markShown: {}, armieHidden: { self.hidden },
                      hideArmie: { self.hidden = true })
    }
}

@Suite("Armie hops once when a step is done, and not for a read, a refresh or coming back")
struct ArmieHopTests {
    static func ended(_ work: SetupRunner.Work, _ facts: SetupFlow.Facts,
                      outcome: SetupRunner.Outcome = .finished) -> SetupRunner.Event {
        .ended(SetupRunner.Ending(work: work, outcome: outcome, facts: facts, slept: false, started: F.started))
    }

    /// Tune's facts once every setting is right.
    static var tuned: SetupFlow.Facts { JourneyFixtures.page(.tune).facts! }

    /// Tune, a Fix pressed, and ended with the step done.
    static var fixed: SetupWindowState {
        A.tuneNeedsFix.applying(.started(F.flight(.fix(checkID: "G1")))).applying(ended(.fix(checkID: "G1"), tuned))
    }

    @Test("A press's work that does the step hops; the work running before it is the loop")
    func hops() {
        let running = A.tuneNeedsFix.applying(.started(F.flight(.fix(checkID: "G1"))))
        #expect(ArmieCue.cue(running) == .working)
        #expect(ArmieCue.cue(Self.fixed) == ArmieCue(pose: .done))
        // A Fix that failed is concern, not a hop.
        let problem = SetupRunner.Problem(title: "Windows refused the change", detail: "")
        let failed = running.applying(Self.ended(.fix(checkID: "G1"), A.tuneNeedsFix.facts!, outcome: .failed(problem)))
        #expect(ArmieCue.cue(failed) == .concerned)
    }

    @Test("A refresh keeps the hop where it is; the next work or pressed read ends it, and it doesn't come back")
    func once() {
        // A read nobody pressed (a wake, the look on coming back) neither restarts nor ends it.
        let refreshed = Self.fixed.applying(.refreshing(F.flight(.lookAgain(.tune, forgetting: .statuses))))
            .applying(.refreshed(Self.tuned))
        #expect(ArmieCue.cue(refreshed)?.pose == .done)
        // Check Again: the loop while it reads, then standing by, never the hop again.
        let reading = refreshed.applying(.started(F.flight(.checkAgain(.tune))))
        #expect(ArmieCue.cue(reading) == .working)
        let read = reading.applying(Self.ended(.checkAgain(.tune), Self.tuned))
        #expect(ArmieCue.cue(read) == .quiet)
    }

    @Test("A read that finds the step done isn't a hop, pressed or not")
    func notForAReread() {
        let reread = A.tuneNeedsFix.applying(.started(F.flight(.checkAgain(.tune))))
            .applying(Self.ended(.checkAgain(.tune), Self.tuned))
        #expect(ArmieCue.cue(reread) == .quiet)
        // Tune's Check Again beside settings Windows didn't answer for asks Windows again (the survey):
        // work to the runner, but a read all the same.
        let surveyed = A.tuneNeedsFix.applying(.started(F.flight(.survey)))
        #expect(ArmieCue.cue(surveyed) == .working)
        #expect(ArmieCue.cue(surveyed.applying(Self.ended(.survey, Self.tuned))) == .quiet)
        let looked = A.tuneNeedsFix.applying(.refreshing(F.flight(.lookAgain(.tune, forgetting: .statuses))))
            .applying(.refreshed(Self.tuned))
        #expect(ArmieCue.cue(looked) == .quiet)
        // Work on a step that was already done doesn't hop either.
        let again = JourneyFixtures.page(.tune).applying(.started(F.flight(.fix(checkID: "G1"))))
            .applying(Self.ended(.fix(checkID: "G1"), Self.tuned))
        #expect(ArmieCue.cue(again) == .quiet)
    }

    @Test("Coming back to the window doesn't hop, even for an ending it only hears of then")
    func notOnReopen() {
        #expect(ArmieCue.cue(Self.fixed.attached(inFlight: nil, latest: Self.tuned)) == .quiet)
        let heard = A.tuneNeedsFix.attached(inFlight: nil, latest: Self.tuned,
                                            lastEnded: SetupRunner.Ending(work: .fix(checkID: "G1"), outcome: .finished,
                                                                          facts: Self.tuned, slept: false,
                                                                          started: F.started))
        #expect(ArmieCue.cue(heard) == .quiet)
    }

    @MainActor @Test("Connect's Yes hops; leaving the step and coming back doesn't hop again")
    func connectYesAndBack() {
        let memory = ArmieSettings()
        let controller = SetupWindowController(state: JourneyFixtures.didItWork, art: nil, settings: memory.settings)
        controller.send(.connected(true))
        #expect(ArmieCue.cue(controller.state)?.pose == .done)
        controller.send(.next)
        #expect(controller.state.step == .finish && controller.state.armieHop == nil)
        controller.send(.back)
        #expect(controller.state.step == .connect)
        #expect(ArmieCue.cue(controller.state) == .quiet)
        // No is the one answer that isn't done well.
        let no = SetupWindowController(state: JourneyFixtures.didItWork, art: nil, settings: memory.settings)
        no.send(.connected(false))
        #expect(ArmieCue.cue(no.state) == .concerned)
    }

    /// The finished page is brought by **Finish**, not by work: that press is its hop, and a window
    /// reopened on it has him standing by with his sign-off.
    @MainActor @Test("Finish after Yes hops on the finished page; reopened there, he stands by")
    func finishHops() throws {
        var before = A.done
        before.finished = false
        before.armieHop = nil
        let memory = ArmieSettings()
        let controller = SetupWindowController(state: before, art: nil, settings: memory.settings)
        #expect(ArmieCue.cue(controller.state)?.pose != .done)
        controller.send(.finish)
        #expect(controller.state.finished)
        let hopping = try #require(ArmieCue.cue(controller.state))
        #expect(hopping.pose == .done && hopping.line != nil)
        let reopened = ArmieCue.cue(controller.state.attached(inFlight: nil, latest: controller.state.facts!))
        #expect(reopened == ArmieCue(pose: .rest, line: hopping.line))
    }

    @MainActor @Test("A skip isn't a hop")
    func notForASkip() {
        let memory = ArmieSettings()
        let controller = SetupWindowController(state: JourneyFixtures.page(.savedPC), art: nil, settings: memory.settings)
        controller.send(.skip("C2"))
        #expect(SetupFlow.isSatisfied(.savedPC, controller.state.facts!))
        #expect(ArmieCue.cue(controller.state) == .quiet)
    }
}

// MARK: - Drawn

@MainActor private enum Drawn {
    nonisolated static let size = CGSize(width: 600, height: 620)

    static let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Resources/Armie")

    static func image(_ name: String) -> NSImage? { NSImage(contentsOf: resources.appendingPathComponent(name + ".png")) }

    /// His stills, as Reduce Motion and the renders draw him: a video layer has nothing to give the
    /// harness (see SetupWindowSnapshotTests).
    static let art: ArmieArt? = image(ArmieArt.stillName).map {
        ArmieArt(still: $0, working: nil, done: nil, concerned: image(ArmieArt.concernedName),
                 pointingLeft: image(ArmieArt.pointingLeftName), pointingRight: image(ArmieArt.pointingRightName))
    }

    /// The real movies, for the tests that look for the player.
    static let movies: ArmieArt? = art.map {
        ArmieArt(still: $0.still, working: resources.appendingPathComponent("armie-working.mov"),
                 done: resources.appendingPathComponent("armie-done.mov"), concerned: $0.concerned,
                 pointingLeft: $0.pointingLeft, pointingRight: $0.pointingRight)
    }

    /// The wizard with `creating` set draws step 2's body from `embedded`, as the window does.
    static func screen(_ state: SetupWindowState, art: ArmieArt?,
                       embedded: ((ArmieHost?) -> AnyView)? = nil) -> SetupScreen {
        SetupScreen(state: state, art: art, embedded: embedded, send: { _ in })
    }

    /// Tall enough for a whole install page, a stall's box and the job's notes included.
    nonisolated static let whole = CGSize(width: 600, height: 1400)

    static func png(_ view: some View, size: CGSize = size, appearance: Snapshot.Appearance = .light) throws -> Data {
        try #require(Snapshot.png(view, size: size, appearance: appearance))
    }

    /// The box, in points, around every pixel where `a` and `b` differ; nil when none do or they can't
    /// be compared.
    nonisolated static func changed(_ a: Data, _ b: Data) -> CGRect? {
        guard let a = Snapshot.pixels(a), let b = Snapshot.pixels(b), a.width == b.width, a.height == b.height else {
            return nil
        }
        var (minX, minY, maxX, maxY) = (Int.max, Int.max, -1, -1)
        for y in 0..<a.height {
            for x in 0..<a.width where a.rgba[y * a.width + x] != b.rgba[y * a.width + x] {
                (minX, minY, maxX, maxY) = (min(minX, x), min(minY, y), max(maxX, x), max(maxY, y))
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: Double(minX) / 2, y: Double(minY) / 2, width: Double(maxX - minX + 1) / 2,
                      height: Double(maxY - minY + 1) / 2)
    }

    /// The install's views running a job inside the wizard, from a controller that only draws it.
    /// `job` is handed the controller's clock, which the elapsed times are read against.
    static func install(ownsJob: Bool = true, _ job: (Date) -> CreateJobState) -> (ArmieHost?) -> AnyView {
        let controller = ArmieFixtures.createController(ownsJob: ownsJob)
        controller.draw(job(controller.now))
        return { armie in AnyView(CreateRootView(controller: controller, armie: armie)) }
    }
}

@Suite("Armie's placements, drawn")
struct ArmiePlacementSnapshots {
    /// Each kind of placement with him and hidden, recorded for looking at, in light and dark. With him
    /// differs from without; without him is exactly what no art in the bundle draws, so hiding him
    /// leaves nothing behind. Compared in light; dark is drawn for the eye.
    @MainActor @Test("He is in the picture on each kind of placement, and hiding him or having no art takes him out")
    func inThePicture() throws {
        let art = try #require(Drawn.art, "the still wasn't found at Resources/Armie")
        let welcome = F.state(.welcome)
        let form = ArmieFixtures.createController()
        let placements: [(String, SetupWindowState, ((ArmieHost?) -> AnyView)?)] = [
            ("welcome", welcome, nil),
            ("utm-installing", F.installing, nil),
            ("tune-says", A.tuneNeedsFix, nil),
            ("certificate-silent", JourneyFixtures.page(.certificate), nil),
            ("connect-concerned", SetupRecoveryFixtures.screens.first { $0.0 == "connect-failed" }!.1, nil),
            ("vm-none", A.noVM, nil),
            ("create-form", A.creating, { armie in AnyView(CreateRootView(controller: form, armie: armie)) }),
            ("installing", A.creating, Drawn.install { A.job(now: $0) }),
            ("done", A.done, nil),
            ("done-no", A.doneNo, nil),
        ]
        for (name, state, embedded) in placements {
            let with = try Drawn.png(Drawn.screen(state, art: art, embedded: embedded))
            let without = try Drawn.png(Drawn.screen(A.hidden(state), art: art, embedded: embedded))
            let noArt = try Drawn.png(Drawn.screen(state, art: nil, embedded: embedded))
            #expect((Snapshot.difference(with, without)?.count ?? 0) > 1000, "\(name)")
            #expect(Snapshot.difference(without, noArt)?.count == 0, "\(name)")
            try Snapshot.record(with, as: "armie-\(name)-light")
            try Snapshot.record(without, as: "armie-\(name)-hidden-light")
            try Snapshot.record(try Drawn.png(Drawn.screen(state, art: art, embedded: embedded), appearance: .dark),
                                as: "armie-\(name)-dark")
        }
    }

    /// Silent beside a title, he is only his figure, in the column the title's measure leaves free: the
    /// title, the cards and the footer's buttons are where they are without him, at the window's
    /// first-open size. One silent page of each step, standing, working and concerned.
    @MainActor @Test("Beside a title and silent, he moves nothing: only the free column beside the title changes")
    func movesNothing() throws {
        let art = try #require(Drawn.art)
        let column = SetupStyle.pagePadding + SetupStyle.textWidth
        let names: Set = ["ask-utm", "list-failed", "reading", "vm-choose", "vm-gone", "journey-tune",
                          "journey-certificate", "journey-savedPC", "recovery-saved-saving", "did-it-work",
                          "recovery-connect-failed", "journey-finish"]
        var checked = 0
        for (name, state) in ArmieFixtures.everyState where names.contains(name) {
            guard let cue = SetupScreen.besideTitle(state), cue.line == nil else { continue }
            checked += 1
            let with = try Drawn.png(Drawn.screen(state, art: art))
            let without = try Drawn.png(Drawn.screen(A.hidden(state), art: art))
            let box = try #require(Drawn.changed(with, without), "\(name): he isn't drawn")
            #expect(box.minX >= column, "\(name): \(box)")
            // Level with the title, under the step bar, well clear of the footer.
            #expect(box.minY >= 30 && box.maxY < 140, "\(name): \(box)")
        }
        #expect(checked == names.count)
    }

    /// His words take room under the title, and only there: the bubble sits between the title and
    /// the page, above the fold, with every word of it drawn.
    @MainActor @Test("What he says is under the title, in view, and whole")
    func wordsInView() throws {
        let art = try #require(Drawn.art)
        for state in [A.tuneNeedsFix, A.noVM, F.installing, A.starting] {
            let line = try #require(ArmieCue.cue(state)?.line)
            let lines = try Drawing.lines(try Drawn.png(Drawn.screen(state, art: art)))
            let said = try #require(Drawing.find(String(line.prefix(18)), in: lines), "\(lines)")
            #expect(said.frame.minY > 60 && said.frame.maxY < 260, "\(said)")
        }
    }

    /// The install **Install Windows…** started, with preflight's battery caution and FileVault note:
    /// his line is under the page's title, in view at the live window's size (the first-open 620 pt
    /// less the 28 pt title bar the window's content runs under), above the notes.
    @MainActor @Test("On the install, his line is under the title and above the notes, in view")
    func installAboveTheFold() throws {
        let art = try #require(Drawn.art)
        let install = Drawn.install { A.job(now: $0, messages: A.preflightNotes) }
        let live = CGSize(width: Drawn.size.width, height: Drawn.size.height - 28)
        let line = try #require(ArmieCue.installing(A.job(now: F.started, messages: A.preflightNotes)).line)
        for appearance in [Snapshot.Appearance.light, .dark] {
            let fold = try Drawn.png(Drawn.screen(A.creating, art: art, embedded: install), size: live, appearance: appearance)
            let lines = try Drawing.lines(fold)
            let words = try #require(Drawing.find(String(line.prefix(20)), in: lines), "\(appearance.rawValue): \(lines)")
            #expect(words.frame.maxY < live.height - setupFooterBand, "\(appearance.rawValue): \(words)")
            let notes = try #require(Drawing.find(CreateCopy.pNotes(A.preflightNotes.count), in: lines), "\(lines)")
            #expect(words.frame.maxY < notes.frame.minY, "\(appearance.rawValue): he is under the notes")
            try Snapshot.record(fold, as: "armie-installing-notes-\(appearance.rawValue)")
        }
    }

    /// The install's views belong to the create controller, which has no settings of the wizard's: the
    /// button has to reach the window's own `send`, where Hide Armie is remembered (SetupWindowTests).
    @MainActor @Test("Hide Armie in the install's views is the wizard's own press")
    func hideFromTheInstall() throws {
        let art = try #require(Drawn.art)
        var lent: ArmieHost?
        var sent: [SetupCommand] = []
        let screen = SetupScreen(state: A.creating, art: art,
                                 embedded: { host in lent = host; return AnyView(EmptyView()) },
                                 send: { sent.append($0) })
        _ = try Drawn.png(screen)
        let host = try #require(lent)
        host.send(.hideArmie)
        #expect(sent == [.hideArmie])
    }

    /// The app's own install draws its two-line footer and **Cancel Install…**; one in Terminal draws
    /// neither.
    @MainActor @Test("The app's own install draws its own footer and Cancel; one in Terminal draws neither")
    func whoseInstall() throws {
        #expect(!ArmieFixtures.createController().readOnly)
        #expect(ArmieFixtures.createController(ownsJob: false).readOnly)
        let owned = try Drawn.png(Drawn.screen(A.hidden(A.creating), art: nil,
                                               embedded: Drawn.install { A.job(now: $0) }))
        let watched = try Drawn.png(Drawn.screen(A.hidden(A.creating), art: nil,
                                                 embedded: Drawn.install(ownsJob: false) { A.job(now: $0) }))
        #expect((Snapshot.difference(owned, watched)?.count ?? 0) > 1000)
    }

    /// A job view that isn't given an Armie — the New Windows VM window's own, which `existingWindow`
    /// builds with `CreateRootView(controller:)` — draws exactly as one given none.
    @MainActor @Test("The install window of its own is never given him")
    func ownWindowUnlent() throws {
        let art = try #require(Drawn.art)
        let controller = ArmieFixtures.createController()
        let job = A.job(now: controller.now)
        let own = try Drawn.png(CreateJobView(controller: controller, state: job))
        #expect(Snapshot.difference(own, try Drawn.png(CreateJobView(controller: controller, state: job, armie: nil)))?
            .count == 0)
        // The control: lent him inside the wizard, where the page has its title for him to stand by.
        let hosted = try Drawn.png(CreateJobView(controller: controller, state: job, armie: nil)
            .environment(\.setupHosted, true))
        let lent = try Drawn.png(CreateJobView(controller: controller, state: job, armie: ArmieHost(art: art, send: { _ in }))
            .environment(\.setupHosted, true))
        #expect((Snapshot.difference(hosted, lent)?.count ?? 0) > 1000)
    }

    /// The popover's figure, pointing and not, and gone once hidden. Drawn as a view: the tests never
    /// show a popover.
    @MainActor @Test("The popover draws him beside its words, and not once he is hidden")
    func popover() throws {
        let art = try #require(Drawn.art)
        let size = CGSize(width: 400, height: 110)
        let pointing = MenuBarIntroArmie(art: art, hidden: false)
        pointing.laidOut(content: CGRect(x: 1000, y: 900, width: 336, height: 110),
                         icon: CGRect(x: 1150, y: 1030, width: 22, height: 24))
        let with = try Drawn.png(MenuBarIntroBubble(armie: pointing), size: size)
        let hidden = try Drawn.png(MenuBarIntroBubble(armie: MenuBarIntroArmie(art: art, hidden: true)), size: size)
        let none = try Drawn.png(MenuBarIntroBubble(armie: nil), size: size)
        #expect((Snapshot.difference(with, hidden)?.count ?? 0) > 1000)
        #expect(Snapshot.difference(hidden, none)?.count == 0)
        try Snapshot.record(with, as: "armie-popover-light")
    }

    /// macOS doesn't scale this window's type (its sizes are fixed, and SwiftUI's Dynamic Type size
    /// changes nothing here: checked), so what "larger" means for him is longer words — a translation,
    /// or a line that runs long: his bubble wraps under a long title and every word is drawn.
    @MainActor @Test("A long title and a long line wrap, and every word of his is drawn")
    func longWords() throws {
        let art = try #require(Drawn.art)
        let line = "Windows assumes it has a PC to itself, with a fan and a desk and a person, and most of this is "
            + "telling it otherwise, one setting at a time, which takes as long as it takes."
        let head = SetupPageHead(title: "Winbar needs permission to control UTM before it can go on",
                                 armie: ArmieCue(pose: .rest, line: line), art: art)
            .frame(width: SetupStyle.contentWidth).padding(SetupStyle.pagePadding)
        let png = try Drawn.png(head, size: CGSize(width: 600, height: 340))
        let lines = try Drawing.lines(png)
        #expect(Drawing.find("takes as long as it takes", in: lines) != nil, "\(lines)")
        #expect(Drawing.find("before it can go on", in: lines) != nil, "\(lines)")
        try Snapshot.record(png, as: "armie-long-words")
    }
}

// MARK: - The real player

/// A machine for a window that is only drawn and pressed, never attached: anything that reaches it
/// is a test reaching further than it meant to.
private final class UntouchedMachine: SetupMachine {
    func readings(through step: WizardStep, answers: SetupFlow.Answers, after work: SetupRunner.Work?,
                  job: SetupRunner.Job?) -> SetupRunner.Readings {
        Issue.record("the drawn window read \(step)")
        return SetupRunner.Readings()
    }

    func perform(_ work: SetupRunner.Work, password: String?, facts: SetupFlow.Facts, job: SetupRunner.Job) throws {
        Issue.record("the drawn window performed \(work)")
    }
}

/// The drawn window's `ArmieLoop` views: where the movie actually plays.
@MainActor private func loops(in view: NSView) -> [ArmieLoop.LoopView] {
    if let loop = view as? ArmieLoop.LoopView { return [loop] }
    return view.subviews.flatMap { loops(in: $0) }
}

@MainActor @Suite("Armie's movies in the drawn window")
struct ArmiePlacementPlayback {
    /// The window drawn from `state` with the real movies, as an AppKit hierarchy in no window (so
    /// nothing plays), Reduce Motion as given.
    private func host(_ state: SetupWindowState, art: ArmieArt, reduceMotion: Bool = false,
                      embedded: ((ArmieHost?) -> AnyView)? = nil) -> NSHostingView<AnyView> {
        let host = NSHostingView(rootView: view(state, art: art, reduceMotion: reduceMotion, embedded: embedded))
        host.frame = CGRect(origin: .zero, size: Drawn.size)
        host.layoutSubtreeIfNeeded()
        return host
    }

    private func view(_ state: SetupWindowState, art: ArmieArt, reduceMotion: Bool = false,
                      embedded: ((ArmieHost?) -> AnyView)? = nil) -> AnyView {
        AnyView(SetupScreen(state: state, art: art, embedded: embedded, send: { _ in })
            .environment(\._accessibilityReduceMotion, reduceMotion))
    }

    /// Dismantling stops the player, so nothing is left after the test.
    private func tearDown(_ host: NSHostingView<AnyView>) {
        host.rootView = AnyView(EmptyView())
        host.layoutSubtreeIfNeeded()
        loops(in: host).forEach { $0.stop() }
    }

    @Test("The finished page plays the hop once, and drawing it again doesn't restart it")
    func doneOnce() throws {
        let art = try #require(Drawn.movies)
        let host = host(A.done, art: art)
        defer { tearDown(host) }
        let figure = try #require(loops(in: host).first)
        #expect(loops(in: host).count == 1)
        #expect(figure.playing == art.done && figure.mode == .once)
        let player = try #require(figure.player)
        #expect(!(player is AVQueuePlayer) && player.actionAtItemEnd == .pause)
        // Drawn again as the window draws it after a read that started by itself (a wake): the same
        // view and the same player, not a new one from the first frame.
        var reading = A.done
        reading.inFlight = F.flight(.checkAgain(.finish))
        reading.refreshing = true
        host.rootView = view(reading, art: art)
        host.layoutSubtreeIfNeeded()
        host.rootView = view(A.done, art: art)
        host.layoutSubtreeIfNeeded()
        #expect(loops(in: host).count == 1)
        #expect(loops(in: host).first === figure)
        #expect(figure.player === player && figure.playing == art.done)
    }

    /// The done hop plays once, as the page appears, so he has to be inside the page's first view at
    /// the size the window first opens, over the menu bar row, the two login boxes and Show Me: below
    /// the fold the hop is over before anyone scrolls to it. Measured in the drawn tree against the
    /// scroll view's clip, since a picture of the first view can't show what is under it. The finished
    /// page is checked in the background too, whose extra paragraph makes the page longer, and step 2's
    /// start (the loop beside a title) as the control for the measure.
    @Test("At the first-open size his figure is wholly in the page's first view, the done hop included")
    func inTheFirstView() throws {
        let art = try #require(Drawn.movies)
        var background = A.done
        background.facts?.rows["H5"] = JourneyFixtures.row("H5", .ok("headless"))
        for (name, state) in [("done", A.done), ("done, in the background", background), ("starting", A.starting)] {
            let host = host(state, art: art)
            defer { tearDown(host) }
            let figure = try #require(loops(in: host).first, "\(name)")
            let scroll = try #require(enclosingScroll(figure), "\(name)")
            let clip = scroll.contentView
            let frame = figure.convert(figure.bounds, to: clip)
            #expect(frame.height > 0, "\(name)")
            #expect(clip.bounds.contains(frame), "\(name): \(frame) outside \(clip.bounds)")
        }
    }

    private func enclosingScroll(_ view: NSView) -> NSScrollView? {
        var next = view.superview
        while let view = next {
            if let scroll = view as? NSScrollView { return scroll }
            next = view.superview
        }
        return nil
    }

    @Test("Pages with work running have the working loop; idle pages have no player at all")
    func workingOnlyWhileWorking() throws {
        let art = try #require(Drawn.movies)
        var reading = A.tuneNeedsFix
        reading.inFlight = F.flight(.checkAgain(.tune))
        for state in [A.starting, F.installing, reading] {
            let host = host(state, art: art)
            defer { tearDown(host) }
            let figure = try #require(loops(in: host).first)
            #expect(loops(in: host).count == 1)
            #expect(figure.playing == art.working && figure.mode == .repeating)
            #expect(figure.player is AVQueuePlayer && figure.looper != nil)
            // Drawn, but in no window macOS is drawing: it doesn't play.
            #expect(figure.player?.rate == 0)
        }
        for (name, state) in ArmieFixtures.everyState where state.inFlight == nil && state.afterInstall == nil
            && state.facts?.installRunning != true && !state.finished {
            let host = host(state, art: art)
            #expect(loops(in: host).isEmpty, "\(name)")
            tearDown(host)
        }
    }

    /// The install's pages, looked for in the drawn tree rather than the picture.
    @Test("The install's running page has his loop, and its stalled, failed and asking pages none")
    func installTree() throws {
        let art = try #require(Drawn.movies)
        let asking = CreateCopy.automationDetail(app: "Winbar")
        let still: [(String, (ArmieHost?) -> AnyView)] = [
            ("stalled", Drawn.install { A.job(now: $0, stalled: .quiet, messages: A.stall) }),
            ("stalled, busy", Drawn.install { A.job(now: $0, stalled: .busy, messages: A.stall) }),
            ("failed", Drawn.install { A.job(stage: .oobe, now: $0, outcome: .failed, failure: A.stoppedWaiting) }),
            ("asking about UTM", Drawn.install { A.job(stage: .check, now: $0, detail: asking) }),
        ]
        for (name, embedded) in still {
            let host = host(A.creating, art: art, embedded: embedded)
            #expect(loops(in: host).isEmpty, "\(name)")
            tearDown(host)
        }
        let talking: [(String, (ArmieHost?) -> AnyView)] = [
            ("running", Drawn.install { A.job(now: $0) }),
            ("running with notes", Drawn.install { A.job(now: $0, messages: A.notes) }),
            ("writing again", Drawn.install { A.job(now: $0, stalled: .writing) }),
        ]
        for (name, embedded) in talking {
            let host = host(A.creating, art: art, embedded: embedded)
            #expect(loops(in: host).count == 1, "\(name)")
            #expect(loops(in: host).first?.playing == art.working, "\(name)")
            tearDown(host)
        }
    }

    /// The shipped window's own wiring, not a closure a test hands `SetupScreen`: **Install Windows…** on the
    /// empty step 2 embeds the create controller, and `SetupRootView` has to pass its views the Armie
    /// `SetupScreen` lends.
    @Test("The real window lends him to the install it embeds, and Hide Armie there takes him back")
    func rootViewLends() throws {
        let art = try #require(Drawn.movies)
        let memory = ArmieSettings()
        let create = ArmieFixtures.createController()
        create.draw(A.job(now: create.now))
        let runner = SetupRunner(machine: UntouchedMachine(), environment: .init(
            queue: DispatchQueue(label: "winbar.test.armie-placement"), callbacks: .main, clock: Date.init,
            keepAwake: { _ in {} }, processes: { _ in ([], nil) }, workspace: NotificationCenter()))
        let setup = SetupWindowController(state: A.noVM, art: art, settings: memory.settings,
                                          makeRunner: { runner }, makeCreator: { create })
        setup.send(.newWindowsVM)
        // Embedding starts the install's clock; letting go stops it.
        defer { create.unembed() }
        #expect(setup.state.creating && setup.embeddedController === create)
        let host = NSHostingView(rootView: AnyView(SetupRootView(controller: setup)))
        host.frame = CGRect(origin: .zero, size: Drawn.size)
        host.layoutSubtreeIfNeeded()
        defer { tearDown(host) }
        #expect(loops(in: host).count == 1)
        #expect(loops(in: host).first?.playing == art.working)
        // The install's own Hide Armie is the window's `send`: remembered, and he leaves the install.
        setup.send(.hideArmie)
        host.layoutSubtreeIfNeeded()
        #expect(memory.hidden)
        #expect(loops(in: host).isEmpty)
    }

    @Test("Under Reduce Motion no placement makes a player, the hop included")
    func reduceMotion() throws {
        let art = try #require(Drawn.movies)
        for state in [A.starting, F.installing, A.done] {
            let still = host(state, art: art, reduceMotion: true)
            #expect(loops(in: still).isEmpty)
            tearDown(still)
            // The control: the same screen with motion allowed has one.
            let moving = host(state, art: art)
            #expect(loops(in: moving).count == 1)
            tearDown(moving)
        }
    }
}
