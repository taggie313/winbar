import AppKit
import AVFoundation
import SwiftUI
import Testing
@testable import Winbar

// Armie's placements after step 1 (gui-wizard.md §2b): the empty step 2, the wait after Start It,
// the install while it is step 2's body, and the done screen. Where he stands is decided by a pure
// function (`ArmieCue`), so first that is held against states, each beside the neighbouring state
// where he must not be; then each placement is drawn with him and with him hidden, to show the
// decision reaches the picture; then the real player is found in the drawn window, to show the done
// screen plays the one-shot movie and a redraw doesn't start it again, and that the install's pages
// have him or not whatever the fold hides.
//
// Every state is invented (SetupFixtures, JourneyFixtures, a made-up Mac for the create views);
// nothing here reads this Mac's settings or reaches UTM, a VM, Windows App or the user's defaults.

private typealias F = SetupFixtures

enum ArmieFixtures {
    /// Step 2 on a Mac whose UTM has no VM at all: the **Make One** card.
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

    /// The done screen, after Connect was answered **Yes** and **Finish** pressed.
    static var done: SetupWindowState {
        var state = F.state(.finish, facts: JourneyFixtures.facts)
        state.answers.connectionOpened = true
        state.answers.connected = true
        state.finished = true
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

    // The create views' side: a made-up Mac, and an install placed relative to the controller's clock,
    // which doesn't tick until a window opens, so the elapsed times read the same on every draw.

    /// Its environment reaches nothing: no job on this Mac is looked for, no form refreshed from UTM,
    /// no window shown, and the work gate is its own rather than the app's. `ownsJob` says whose
    /// install it draws: by default the app's own, as **Make One** starts it, with the app's footer
    /// and **Cancel Install…**; false for one running in Terminal that the wizard is only showing.
    /// Answered here rather than by claiming the process-wide flag, which other tests draw from.
    @MainActor static func createController(ownsJob: Bool = true) -> CreateWindowController {
        CreateWindowController(facts: CreateFormFacts(
            mac: MacFacts(topTierCores: 8, totalCores: 12, memoryBytes: 32 << 30, shortUserName: "rosa"),
            utmInstalled: true, utmVersion: "4.7.5", fileVaultOn: true, freeGB: 400, volumeName: "atelier",
            existingVMNames: nil, menuVMName: nil),
            environment: .init(currentJob: { nil }, refreshForm: { _ in }, show: { _ in }, workGate: AppWorkGate(),
                               ownsJob: { ownsJob }))
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
    /// which silences him. With the app's footer they end the page just past the first-open size's
    /// fold, where a rule of his own above him would be the one thing of his left showing.
    static let preflightNotes = [
        notes[0],
        ("N_PW_FILEVAULT_OFF", CreateCopy.nPWFileVaultOff),
    ]

    static let stoppedWaiting = CreateFailure(code: "E_TIMEOUT", title: "Windows still hadn't finished installing",
                                              detail: "Windows still hadn't finished installing after 2 hours, so "
                                                + "Winbar stopped waiting.",
                                              nextStep: "The VM is still running: look at its window in UTM.")
}

private typealias A = ArmieFixtures

// MARK: - Where he stands

@Suite("Armie after step 1: the empty step 2, a start, the install and the end, and nowhere else")
struct ArmiePlacementTests {
    static func working(_ line: String) -> ArmieCue { ArmieCue(line: line, clip: .working) }

    @Test("Step 2 with no VM at all has his no-VM line, with the working clip")
    func noVM() {
        #expect(ArmieCue.cue(A.noVM) == Self.working(SetupCopy.Armie.line(.noVM)))
        // A Check Again read is still nothing to do: he stays rather than blinking out for it.
        var reading = A.noVM
        reading.inFlight = F.flight(.checkAgain(.vm))
        #expect(ArmieCue.cue(reading) == Self.working(SetupCopy.Armie.line(.noVM)))
    }

    /// Every other page step 2 can show has a decision or news on it.
    @Test("Not on a step 2 page with a VM to choose, a VM that went missing, or one running")
    func noVMOnlyWhenEmpty() {
        #expect(ArmieCue.cue(A.vmGone) == nil)
        for (name, state) in F.screens where state.step == .vm && name != "vm-none" {
            #expect(ArmieCue.cue(state) == nil, "\(name)")
        }
        for (name, state) in SetupRecoveryFixtures.screens where state.step == .vm {
            let expected = name == "vm-none" ? Self.working(SetupCopy.Armie.line(.noVM)) : nil
            #expect(ArmieCue.cue(state) == expected, "\(name)")
        }
    }

    @Test("Step 2's empty state goes quiet beside a failure, an install's warnings, and the install's own pages")
    func noVMQuietBesideTrouble() {
        #expect(ArmieCue.cue(A.failed(A.noVM, .checkAgain(.vm))) == nil)
        var warned = A.noVM
        warned.installMessages = [CreateMessage(code: "W_MEDIA_LEFT", text: "The setup disk could not be removed.",
                                                at: F.started)]
        #expect(ArmieCue.cue(warned) == nil)
        // A note that says what the install did is not trouble, and leaves him be: the rule is
        // `silences`, not "any message".
        warned.installMessages = [CreateMessage(code: "N_PC_SAVED", text: CreateCopy.nPCSaved(name: "winlab02"),
                                                at: F.started)]
        #expect(ArmieCue.cue(warned) != nil)
        var looking = A.noVM
        looking.afterInstall = F.started
        #expect(ArmieCue.cue(looking) == nil)
        #expect(ArmieCue.cue(A.creating) == nil)
        var choosing = A.noVM
        choosing.inFlight = F.flight(.chooseVM("winlab02", id: SetupVMTests.new.id))
        #expect(ArmieCue.cue(choosing) == nil)
    }

    @Test("Start It's wait has his starting line, and loses it when the three minutes run out")
    func starting() {
        let line = SetupCopy.Armie.startingLine(timedOut: false)
        #expect(line != nil)
        #expect(ArmieCue.cue(A.starting) == line.map(Self.working))
        #expect(ArmieCue.cue(A.startTimedOut) == nil)
        // Either record of the timeout is enough: the flight's newest line, or the kept lines of a
        // window reopened after something else was said.
        var byFlight = A.starting
        byFlight.inFlight?.line = SetupCopy.agentNotYet
        #expect(ArmieCue.cue(byFlight) == nil)
        var byLines = A.starting
        byLines.lines.append(SetupCopy.agentNotYet)
        byLines.inFlight?.line = "Asking UTM…"
        #expect(ArmieCue.cue(byLines) == nil)
        // The control: the stopped VM with nothing running is a page with a button to press.
        var stopped = A.starting
        stopped.inFlight = nil
        stopped.lines = []
        #expect(ArmieCue.cue(stopped) == nil)
        // A start that went wrong before is still on screen in red under this one.
        #expect(ArmieCue.cue(A.failed(A.starting, .startVM(SetupVMTests.new.name))) == nil)
    }

    @Test("The done screen after Yes has his done line, with the done clip")
    func done() {
        #expect(ArmieCue.cue(A.done) == ArmieCue(line: SetupCopy.Armie.line(.done), clip: .done))
        // A read that starts on this screen by itself (a wake) doesn't take him away, or its end would
        // bring him back and play the hop a second time.
        var reading = A.done
        reading.inFlight = F.flight(.checkAgain(.finish))
        #expect(ArmieCue.cue(reading)?.clip == .done)
    }

    @Test("Not on an ending that isn't Yes, before Finish, or beside a failure still on screen")
    func doneOnlyAfterYes() {
        for connected in [false, nil] as [Bool?] {
            var state = A.done
            state.answers.connected = connected
            state.facts?.answers = state.answers
            #expect(ArmieCue.cue(state) == nil, "\(String(describing: connected))")
        }
        var unfinished = A.done
        unfinished.finished = false
        #expect(ArmieCue.cue(unfinished) == nil)
        // Keep the Screen after a failed Go Headless finishes without new work: that card stays up.
        #expect(ArmieCue.cue(A.failed(A.done, .fix(checkID: "H5"))) == nil)
        var overtaken = A.done
        overtaken.lastEnding = SetupRunner.Ending(work: .applyChanges, outcome: .overtaken, facts: A.done.facts!,
                                                  slept: false, started: F.started)
        #expect(ArmieCue.cue(overtaken) == nil)
        for (name, state) in SetupRecoveryFixtures.screens where state.step == .finish {
            #expect(ArmieCue.cue(state) == nil, "\(name)")
        }
    }

    @Test("The install has each stage's line while it's going well")
    func installing() {
        for stage in CreateStage.allCases {
            #expect(ArmieCue.installing(A.job(stage: stage)) == Self.working(SetupCopy.Armie.line(.installing(stage))),
                    "\(stage)")
        }
        // Preflight's cautions are said before anything starts, and leave him be, as does the note
        // that the PC was saved: the notes the drawn tests put above him.
        #expect(ArmieCue.installing(A.job(messages: [("W_BATTERY", "This Mac is on battery.")])) != nil)
        #expect(ArmieCue.installing(A.job(messages: A.notes)) != nil)
    }

    @Test("Not beside a stall, a failure, an ending, a warning, or macOS asking about UTM")
    func installingQuietBesideTrouble() {
        #expect(ArmieCue.installing(A.job(stalled: .quiet)) == nil)
        #expect(ArmieCue.installing(A.job(stalled: .busy)) == nil)
        #expect(ArmieCue.installing(A.job(stalled: .writing)) != nil)
        #expect(ArmieCue.installing(A.job(stage: .oobe, outcome: .failed, failure: A.stoppedWaiting)) == nil)
        #expect(ArmieCue.installing(A.job(stage: .finish, outcome: .done)) == nil)
        #expect(ArmieCue.installing(A.job(messages: [("W_TIMEMACHINE", "Couldn't keep the setup disk out of Time "
                                                      + "Machine.")])) == nil)
        // The job's Automation detail, which the running row turns into P_AUTOMATION, is a permission.
        let asking = A.job(stage: .check, detail: CreateCopy.automationDetail(app: "Winbar"))
        #expect(CreateProgress.detail(asking.detail) == CreateCopy.pAutomation)
        #expect(ArmieCue.installing(asking) == nil)
        #expect(ArmieCue.installing(A.job(stage: .check, detail: "Reading the ISO…")) != nil)
    }

    @Test("Hide Armie takes him off every placement, and the install is lent no Armie")
    func hidden() {
        let art = ArmieArt(still: NSImage(size: NSSize(width: 2, height: 2)), working: nil, done: nil)
        for state in [A.noVM, A.starting, A.done, F.installing] {
            #expect(ArmieCue.cue(state) != nil)
            #expect(ArmieCue.cue(A.hidden(state)) == nil)
        }
        #expect(ArmieHost.lent(A.creating, art: art, send: { _ in }) != nil)
        #expect(ArmieHost.lent(A.hidden(A.creating), art: art, send: { _ in }) == nil)
        // No art in the bundle is no Armie either.
        #expect(ArmieHost.lent(A.creating, art: nil, send: { _ in }) == nil)
    }

    /// Tune, the certificate, the saved PC and Connect: a permission, a password field or a question
    /// on each. Held against every drawn fixture of them, finished or not.
    @Test("Never on the steps with a permission, a password or a question on them")
    func notOnTheJourney() {
        for (name, state) in SetupRecoveryFixtures.screens where ![.vm, .finish].contains(state.step) {
            #expect(ArmieCue.cue(state) == nil, "\(name)")
            var answered = state
            answered.answers.connected = true
            answered.finished = true
            answered.facts?.answers = answered.answers
            #expect(ArmieCue.cue(answered) == nil, "\(name), finished")
        }
    }

    @Test("His lines stay deadpan: no exclamation, no question")
    func deadpan() {
        let lines = [SetupCopy.Armie.line(.noVM), SetupCopy.Armie.line(.startingWindows), SetupCopy.Armie.line(.done)]
            + CreateStage.allCases.map { SetupCopy.Armie.line(.installing($0)) }
        for line in lines {
            #expect(!line.contains("!") && !line.contains("?"), "\(line)")
        }
    }

    @Test("A clip names its movie, and a missing movie is the still")
    func clipURL() {
        let working = URL(fileURLWithPath: "/invalid/armie-working.mov")
        let done = URL(fileURLWithPath: "/invalid/armie-done.mov")
        let art = ArmieArt(still: NSImage(size: NSSize(width: 2, height: 2)), working: working, done: done)
        #expect(art.url(.working) == working && art.url(.done) == done)
        #expect(art.playback(for: art.url(.done)!) == .once)
        let bare = ArmieArt(still: art.still, working: nil, done: nil)
        #expect(bare.url(.working) == nil && bare.url(.done) == nil)
    }
}

// MARK: - Drawn

@MainActor private enum Drawn {
    nonisolated static let size = CGSize(width: 600, height: 620)

    static let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Resources/Armie")

    /// His still, as Reduce Motion and the renders draw him: a video layer has nothing to give the
    /// harness (see SetupWindowSnapshotTests).
    static let art: ArmieArt? = NSImage(contentsOf: resources.appendingPathComponent("armie-rest.png"))
        .map { ArmieArt(still: $0, working: nil, done: nil) }

    /// The real movies, for the tests that look for the player.
    static let movies: ArmieArt? = art.map {
        ArmieArt(still: $0.still, working: resources.appendingPathComponent("armie-working.mov"),
                 done: resources.appendingPathComponent("armie-done.mov"))
    }

    /// The wizard with `creating` set draws step 2's body from `embedded`, as the window does.
    static func screen(_ state: SetupWindowState, art: ArmieArt?,
                       embedded: ((ArmieHost?) -> AnyView)? = nil) -> SetupScreen {
        SetupScreen(state: state, art: art, embedded: embedded, send: { _ in })
    }

    /// Tall enough for a whole install page, a stall's box and the job's notes included. At the
    /// first-open size a stall or a note pushes the spot after the footer, where he'd stand, below the
    /// fold, and comparing the page with him and without him there compares two pictures that can't
    /// contain him: the check passes whether or not he is drawn.
    nonisolated static let whole = CGSize(width: 600, height: 1400)

    static func png(_ view: some View, size: CGSize = size, appearance: Snapshot.Appearance = .light) throws -> Data {
        try #require(Snapshot.png(view, size: size, appearance: appearance))
    }

    /// The widest unbroken run of pixels, in any one row, where `a` and `b` differ, as a share of the
    /// width: near 1 for a rule across the page; small for his figure or a line of text, whose letters
    /// and words leave gaps. nil when they can't be compared.
    nonisolated static func widestRun(_ a: Data, _ b: Data) -> Double? {
        guard let a = Snapshot.pixels(a), let b = Snapshot.pixels(b), a.width == b.width, a.height == b.height,
              a.width > 0 else { return nil }
        var widest = 0
        for y in 0..<a.height {
            var run = 0
            for x in 0..<a.width {
                if a.rgba[y * a.width + x] != b.rgba[y * a.width + x] {
                    run += 1
                    widest = max(widest, run)
                } else {
                    run = 0
                }
            }
        }
        return Double(widest) / Double(a.width)
    }

    /// The install's views running a job inside the wizard, from a controller that only draws it.
    /// `job` is handed the controller's clock, which the elapsed times are read against.
    static func install(ownsJob: Bool = true, _ job: (Date) -> CreateJobState) -> (ArmieHost?) -> AnyView {
        let controller = ArmieFixtures.createController(ownsJob: ownsJob)
        controller.draw(job(controller.now))
        return { armie in AnyView(CreateRootView(controller: controller, armie: armie)) }
    }
}

@Suite("Armie's new placements, drawn")
struct ArmiePlacementSnapshots {
    /// Each placement with him, and its Armie-hidden twin, in light and dark, recorded for looking at.
    /// With him differs from without by his figure and line; without him is exactly what no art in
    /// the bundle draws, so hiding him leaves nothing behind.
    @MainActor @Test("He is in the picture on each new placement, and hiding him or having no art takes him out")
    func inThePicture() throws {
        let art = try #require(Drawn.art, "the still wasn't found at Resources/Armie")
        let placements: [(String, SetupWindowState, ((ArmieHost?) -> AnyView)?)] = [
            ("vm-none", A.noVM, nil),
            ("vm-starting", A.starting, nil),
            ("installing", A.creating, Drawn.install { A.job(now: $0) }),
            ("installing-cli", A.creating, Drawn.install(ownsJob: false) { A.job(now: $0) }),
            ("done", A.done, nil),
        ]
        for (name, state, embedded) in placements {
            for appearance in [Snapshot.Appearance.light, .dark] {
                let with = try Drawn.png(Drawn.screen(state, art: art, embedded: embedded), appearance: appearance)
                let without = try Drawn.png(Drawn.screen(A.hidden(state), art: art, embedded: embedded),
                                            appearance: appearance)
                let noArt = try Drawn.png(Drawn.screen(state, art: nil, embedded: embedded), appearance: appearance)
                let again = try Drawn.png(Drawn.screen(state, art: art, embedded: embedded), appearance: appearance)
                #expect(Snapshot.difference(with, again)?.count == 0, "\(name), \(appearance.rawValue): unstable")
                #expect((Snapshot.difference(with, without)?.count ?? 0) > 1000, "\(name), \(appearance.rawValue)")
                #expect(Snapshot.difference(without, noArt)?.count == 0, "\(name), \(appearance.rawValue)")
                try Snapshot.record(with, as: "armie-\(name)-\(appearance.rawValue)")
                try Snapshot.record(without, as: "armie-\(name)-hidden-\(appearance.rawValue)")
            }
        }
    }

    /// The install **Make One** started, with preflight's battery caution and FileVault note, at the
    /// window's first-open size: those and the app's two-line footer put him just below the fold,
    /// where a rule of his own above him was all that showed, a second line over the button bar's
    /// that read as something cut off. What shows of him there must not be a rule across the page.
    /// Drawn whole, he is under the notes and adds nothing across the page either, so no other fold
    /// can leave one.
    @MainActor @Test("Below the fold he leaves no stray rule, and drawn whole he is there under the notes")
    func belowTheFold() throws {
        let art = try #require(Drawn.art)
        let install = Drawn.install { A.job(now: $0, messages: A.preflightNotes) }
        for appearance in [Snapshot.Appearance.light, .dark] {
            let label = appearance.rawValue
            let fold = try Drawn.png(Drawn.screen(A.creating, art: art, embedded: install), appearance: appearance)
            let foldHidden = try Drawn.png(Drawn.screen(A.hidden(A.creating), art: art, embedded: install),
                                           appearance: appearance)
            let whole = try Drawn.png(Drawn.screen(A.creating, art: art, embedded: install), size: Drawn.whole,
                                      appearance: appearance)
            let wholeHidden = try Drawn.png(Drawn.screen(A.hidden(A.creating), art: art, embedded: install),
                                            size: Drawn.whole, appearance: appearance)
            let atFold = try #require(Snapshot.difference(fold, foldHidden))
            let drawnWhole = try #require(Snapshot.difference(whole, wholeHidden))
            #expect(drawnWhole.count > 1000, "\(label)")
            // The premise: this page really does hide some of him at the first-open size. If the page
            // ever fits, the fixture needs more notes for this test to be about the fold.
            #expect(atFold.count < drawnWhole.count, "\(label): he fits above the fold now")
            #expect(try #require(Drawn.widestRun(fold, foldHidden)) < 0.5, "\(label): a rule at the fold")
            #expect(try #require(Drawn.widestRun(whole, wholeHidden)) < 0.5, "\(label): a rule above him")
            try Snapshot.record(fold, as: "armie-installing-notes-\(label)")
            try Snapshot.record(whole, as: "armie-installing-notes-whole-\(label)")
        }
    }

    /// The renders above say whose install they draw. The wizard's own is drawn as the app draws it,
    /// with its two-line footer and **Cancel Install…**: the footer is longer than the Terminal
    /// install's, and it is what decides where the fold falls on him.
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

    /// The pages next to each placement where he must not be, drawn lent an Armie and not: the same
    /// pixels. The create form has a password field; a failure, a stall and a timed-out start are
    /// trouble; and the New Windows VM window of its own is not the wizard. The install's pages are
    /// drawn whole (`Drawn.whole`), so the place he would stand is in the picture being compared.
    @MainActor @Test("Not drawn on the create form, a failed or stalled install, a timed-out start, or a No ending")
    func notInThePicture() throws {
        let art = try #require(Drawn.art)
        var noAnswer = A.done
        noAnswer.answers.connected = false
        noAnswer.facts?.answers = noAnswer.answers
        let form = ArmieFixtures.createController()
        let neighbours: [(String, SetupWindowState, ((ArmieHost?) -> AnyView)?, CGSize)] = [
            ("create-form", A.creating, { armie in AnyView(CreateRootView(controller: form, armie: armie)) },
             Drawn.whole),
            ("install-failed", A.creating, Drawn.install {
                A.job(stage: .oobe, now: $0, outcome: .failed, failure: A.stoppedWaiting)
            }, Drawn.whole),
            ("install-stalled", A.creating, Drawn.install { A.job(now: $0, stalled: .quiet, messages: A.stall) },
             Drawn.whole),
            ("vm-start-timed-out", A.startTimedOut, nil, Drawn.size),
            ("vm-gone", A.vmGone, nil, Drawn.size),
            ("done-no", noAnswer, nil, Drawn.size),
        ]
        for (name, state, embedded, size) in neighbours {
            let lent = try Drawn.png(Drawn.screen(state, art: art, embedded: embedded), size: size)
            let hidden = try Drawn.png(Drawn.screen(A.hidden(state), art: art, embedded: embedded), size: size)
            #expect(Snapshot.difference(lent, hidden)?.count == 0, "\(name)")
            try Snapshot.record(lent, as: "armie-absent-\(name)-light")
        }
        // The control, at the same size: a running install that has said more than the stalled one
        // has (a caution and the saved PC, which leave him be, where the stall has one box) is drawn
        // with him. So the size holds a page longer than the stall's with him at the end of it, and
        // what keeps him off the stalled page is the stall, not the fold.
        let running = Drawn.install { A.job(now: $0, messages: A.notes) }
        let lent = try Drawn.png(Drawn.screen(A.creating, art: art, embedded: running), size: Drawn.whole)
        let hidden = try Drawn.png(Drawn.screen(A.hidden(A.creating), art: art, embedded: running), size: Drawn.whole)
        #expect((Snapshot.difference(lent, hidden)?.count ?? 0) > 1000)
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

    /// A job view that isn't given an Armie — the New Windows VM window's own, which `existingWindow`
    /// builds with `CreateRootView(controller:)` — draws exactly as one given none.
    @MainActor @Test("The install window of its own is never given him")
    func ownWindowUnlent() throws {
        let art = try #require(Drawn.art)
        let controller = ArmieFixtures.createController()
        let job = A.job(now: controller.now)
        let own = try Drawn.png(CreateJobView(controller: controller, state: job))
        let lent = try Drawn.png(CreateJobView(controller: controller, state: job,
                                               armie: ArmieHost(art: art, send: { _ in })))
        #expect(Snapshot.difference(own, try Drawn.png(CreateJobView(controller: controller, state: job, armie: nil)))?
            .count == 0)
        #expect((Snapshot.difference(own, lent)?.count ?? 0) > 1000)
    }
}

// MARK: - The real player

/// The window's two settings, in memory, so Hide Armie is remembered here and not in this Mac's defaults.
private final class ArmieSettings {
    var hidden = false
    var settings: SetupSettings {
        SetupSettings(wizardShown: { true }, markShown: {}, armieHidden: { self.hidden },
                      hideArmie: { self.hidden = true })
    }
}

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
    /// The window drawn from `state` with the real movies, as an AppKit hierarchy, Reduce Motion as given.
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

    /// Dismantling stops the player, so nothing is left running after the test.
    private func tearDown(_ host: NSHostingView<AnyView>) {
        host.rootView = AnyView(EmptyView())
        host.layoutSubtreeIfNeeded()
        loops(in: host).forEach { $0.stop() }
    }

    @Test("The done screen plays the done movie once, and drawing the screen again doesn't restart it")
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
        host.rootView = view(reading, art: art)
        host.layoutSubtreeIfNeeded()
        host.rootView = view(A.done, art: art)
        host.layoutSubtreeIfNeeded()
        #expect(loops(in: host).count == 1)
        #expect(loops(in: host).first === figure)
        #expect(figure.player === player && figure.playing == art.done)
    }

    /// The control for the clip: the same view on step 2 plays the working loop.
    @Test("Step 2's placements play the working loop")
    func workingLoops() throws {
        let art = try #require(Drawn.movies)
        for state in [A.noVM, A.starting] {
            let host = host(state, art: art)
            defer { tearDown(host) }
            let figure = try #require(loops(in: host).first)
            #expect(figure.playing == art.working && figure.mode == .repeating)
            #expect(figure.player is AVQueuePlayer && figure.looper != nil)
        }
    }

    /// The install's pages, looked for in the drawn tree rather than the picture, so where the fold
    /// falls can't hide him: a stall's box, a failure or a long list of notes can push the place he
    /// stands below the first-open size, and a picture of that size can't say whether he's there.
    @Test("The install's running page has his player, and its stalled, failed and asking pages have none")
    func installTree() throws {
        let art = try #require(Drawn.movies)
        let asking = CreateCopy.automationDetail(app: "Winbar")
        let quiet: [(String, (ArmieHost?) -> AnyView)] = [
            ("stalled", Drawn.install { A.job(now: $0, stalled: .quiet, messages: A.stall) }),
            ("stalled, busy", Drawn.install { A.job(now: $0, stalled: .busy, messages: A.stall) }),
            ("failed", Drawn.install { A.job(stage: .oobe, now: $0, outcome: .failed, failure: A.stoppedWaiting) }),
            ("asking about UTM", Drawn.install { A.job(stage: .check, now: $0, detail: asking) }),
        ]
        for (name, embedded) in quiet {
            let host = host(A.creating, art: art, embedded: embedded)
            #expect(loops(in: host).isEmpty, "\(name)")
            tearDown(host)
        }
        // The control: the running page, the same one with notes that leave him be, and a stall that
        // has cleared each have his working loop.
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

    /// The shipped window's own wiring, not a closure a test hands `SetupScreen`: **Make One** on the
    /// empty step 2 embeds the create controller, and `SetupRootView` has to pass its views the Armie
    /// `SetupScreen` lends. Every other test supplies that closure itself, so without this one the
    /// window could stop passing him on and the install would lose him with every test still green.
    @Test("The real window lends him to the install it embeds, and Hide Armie there takes him back")
    func rootViewLends() throws {
        let art = try #require(Drawn.movies)
        let memory = ArmieSettings()
        let create = ArmieFixtures.createController()
        create.draw(A.job(now: create.now))
        let runner = SetupRunner(machine: UntouchedMachine(), environment: .init(
            queue: DispatchQueue(label: "winbar.test.armie-placement"), callbacks: .main, clock: Date.init,
            keepAwake: { _ in {} }, processes: { _ in ([], nil) }, workspace: NotificationCenter(),
            app: NotificationCenter()))
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

    @Test("Under Reduce Motion no placement makes a player, the celebration included")
    func reduceMotion() throws {
        let art = try #require(Drawn.movies)
        for state in [A.noVM, A.starting, A.done] {
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
