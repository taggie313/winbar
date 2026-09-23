import Foundation
import Testing
@testable import Winbar

// The set-up wizard's engine. Pure logic only: every fact is passed in, so nothing here may reach
// UTM, a VM, the keychain, TCC or the user's defaults. The rows are built from the real recipe's
// checks with made-up statuses; no check is ever evaluated.

/// Invented machines and people only.
private enum Given {
    static let winlab = VMInfo(id: "5A1C0DE0-0000-4000-8000-000000000001", name: "winlab01", status: "started",
                               backend: "qemu", icon: "windows", architecture: "aarch64")
    static let atelier = VMInfo(id: "5A1C0DE0-0000-4000-8000-000000000002", name: "atelier", status: "stopped",
                                backend: "qemu", icon: "windows", architecture: "aarch64")
    static let debian = VMInfo(id: "5A1C0DE0-0000-4000-8000-000000000003", name: "Debian", status: "stopped",
                               backend: "qemu", icon: "linux", architecture: "aarch64")
    /// An Apple Virtualization VM: UTM lists it, Winbar can't manage it.
    static let brunosMac = VMInfo(id: "5A1C0DE0-0000-4000-8000-000000000004", name: "Bruno's macOS",
                                  status: "stopped", backend: "apple", icon: "mac", architecture: "aarch64")

    /// The real check, so a row carries the recipe's own title and why. A renamed check shows up as
    /// a row titled "missing", and the agreement tests below say which.
    static func check(_ id: String) -> Check {
        Recipe.check(id) ?? Check(id: id, section: .host, title: "missing \(id)", why: "", evaluate: { _ in .error("") })
    }

    static func row(_ id: String, _ status: Status) -> SetupFlow.Row { SetupFlow.Row(check(id), status) }
    static func ok(_ id: String) -> SetupFlow.Row { row(id, .ok("fine")) }

    /// A status of each kind, for the tests that go through every kind a row can have.
    static func status(_ kind: SetupFlow.StatusKind) -> Status {
        switch kind {
        case .ok: return .ok("fine")
        case .fixable: return .fixable("needs changing")
        case .manual: return .manual("needs doing", how: "Do it.")
        case .info: return .info("for reference")
        case .error: return .error("Windows wouldn't say")
        }
    }

    /// A Mac the wizard has finished with: UTM answering, winlab01 chosen and running, every row
    /// fine, the desktop seen, and the VM already headless.
    static var done: SetupFlow.Facts {
        var facts = SetupFlow.Facts()
        facts.utm = .installed(version: "4.7.5")
        facts.utmAnswers = .answered
        facts.windowsApp = .installed(version: "11.1.10")
        facts.vms = .listed([winlab, debian])
        facts.chosenVM = "winlab01"
        facts.vmRunning = true
        facts.guestAnswers = true
        for id in SetupFlow.order { facts.rows[id] = ok(id) }
        facts.rdpHost = "winlab01.local"
        facts.rdpUser = "rosa"
        facts.otherVMs = .running([])
        facts.answers = SetupFlow.Answers(started: true, connectionOpened: true, connected: true)
        return facts
    }

    /// `done`, with one row changed.
    static func done(with id: String, _ status: Status) -> SetupFlow.Facts {
        var facts = done
        facts.rows[id] = row(id, status)
        return facts
    }
}

// MARK: - The step list and the recipe

/// `SetupFlow.checks(in:)` is the whole contract between the window and `winbar setup`. Since
/// `Setup.run` isn't rewritten onto it (COHERENCE C3), these are the only thing stopping the two
/// front-ends from drifting into two recipes.
@Suite("The step list and the recipe agree")
struct SetupFlowAgreement {
    /// The one that stops the window and `winbar setup` drifting: a check added to the recipe and
    /// to no step fails here, by name.
    @Test("Every recipe check belongs to exactly one step, with G11 the one deliberate exception")
    func everyCheckIsPlacedOnce() {
        #expect(SetupFlow.unplaced == ["G11"])
        for check in Recipe.checks {
            let steps = WizardStep.allCases.filter { SetupFlow.checks(in: $0).contains(check.id) }
            #expect(steps.count == (SetupFlow.unplaced.contains(check.id) ? 0 : 1), "\(check.id): \(steps)")
        }
    }

    @Test("No step names a check twice, or one the recipe doesn't have")
    func noDuplicatesOrStrangers() {
        let order = SetupFlow.order
        #expect(Set(order).count == order.count)
        let recipe = Set(Recipe.checks.map(\.id))
        for id in order { #expect(recipe.contains(id), "\(id)") }
        #expect(Set(order).union(SetupFlow.unplaced) == recipe)
    }

    /// `Setup.run` is two passes, with G8 and G11 in both. The window has one list, so what can be
    /// held to is this: take the window's order, keep only one pass's ids, and it reads as that pass.
    @Test("The window keeps each of winbar setup's passes in its order")
    func setupPassesKeepTheirOrder() {
        for pass in [Setup.fixPass, Setup.manualPass, Setup.restartPass] {
            let placed = pass.filter { !SetupFlow.unplaced.contains($0) }
            #expect(SetupFlow.order.filter(placed.contains) == placed, "\(pass)")
        }
        // The single call sites `Setup.run` doesn't loop over: G0 and G5 walked before any fix,
        // BitLocker between the passes (after G8, the fix pass's last placed row), H7 after it.
        let tune = SetupFlow.checks(in: .tune)
        #expect(Array(tune.prefix(2)) == ["G0", "G5"])
        #expect(tune.firstIndex(of: "G9") == tune.firstIndex(of: "G8").map { $0 + 1 })
    }

    @Test("Everything winbar setup fixes or walks has a step, apart from the shared folder")
    func setupsChecksArePlaced() {
        for id in Setup.fixPass + Setup.manualPass + Setup.restartPass where !SetupFlow.unplaced.contains(id) {
            #expect(SetupFlow.order.contains(id), "\(id)")
        }
    }

    /// COHERENCE C3. The wizard leaves the shared folder out (§1), and `winbar setup` must keep
    /// offering it: in both passes, and through `offerSharedFolder` in its single restart — which
    /// is why `Setup.run` is not rewritten to walk the wizard's steps.
    @Test("winbar setup keeps the shared folder the window leaves out")
    func setupKeepsTheSharedFolder() {
        #expect(WizardStep.allCases.allSatisfy { !SetupFlow.checks(in: $0).contains("G11") })
        #expect(Setup.fixPass.contains("G11"))
        #expect(Setup.manualPass.contains("G11"))
        #expect(Recipe.check("G11")?.apply != nil)
    }

    /// §5's ordering: the lock-out rule, the certificate that has to exist before it's trusted, and
    /// the restart at the end.
    @Test("G0 before G5 before G6, G7 before H7, and H3 and H4 last")
    func theOrderThatMatters() throws {
        let tune = SetupFlow.checks(in: .tune)
        let g0 = try #require(tune.firstIndex(of: "G0"))
        let g5 = try #require(tune.firstIndex(of: "G5"))
        let g6 = try #require(tune.firstIndex(of: "G6"))
        #expect(g0 < g5 && g5 < g6)
        #expect(Array(tune.suffix(2)) == ["H3", "H4"])
        // Across steps: G7 makes the certificate in tune, H7 trusts it a step later.
        #expect(SetupFlow.checks(in: .certificate) == ["H7"])
        #expect(WizardStep.tune < WizardStep.certificate)
        let order = SetupFlow.order
        let g7 = try #require(order.firstIndex(of: "G7"))
        let h7 = try #require(order.firstIndex(of: "H7"))
        #expect(g7 < h7)
        // H9 moves to the front: a silent utmctl is why everything after it would fail.
        #expect(Array(order.prefix(2)) == ["H1", "H9"])
    }

    /// Setup batches everything that needs the VM off into one restart at the end. The window
    /// stages vCPUs and memory in tune and applies them with the display at the finish.
    @Test("Checks that need the VM off are staged, and applied only at the finish")
    func restartChecksComeLast() {
        let tune = SetupFlow.checks(in: .tune)
        for check in Recipe.checks where check.needsRestart {
            let step = WizardStep.allCases.first { SetupFlow.checks(in: $0).contains(check.id) }
            #expect(step == .tune || step == .finish, "\(check.id)")
        }
        let staged = tune.filter { Recipe.check($0)?.needsRestart == true }
        #expect(Array(tune.suffix(staged.count)) == staged)
        #expect(SetupFlow.checks(in: .finish) == ["H5"])
    }

    /// G9 is in neither of setup's lists: `offerDecryption` asks it between them. The window puts it
    /// in tune, where a generic row with a Fix button would decrypt the disk without asking. So its
    /// row asks, and a button called Fix Everything never answers it.
    @Test("G9 asks its own question: its row has no Fix, and Fix Everything never decrypts BitLocker")
    func bitLockerKeepsItsOwnQuestion() throws {
        #expect(!Setup.fixPass.contains("G9") && !Setup.manualPass.contains("G9"))
        #expect(SetupFlow.checks(in: .tune).contains("G9"))
        #expect(Recipe.check("G9")?.apply != nil)   // it can be applied — only as the question's yes
        var facts = Given.done(with: "G9", .fixable("C: is encrypted"))
        facts.rows["G1"] = Given.row("G1", .fixable("active plan isn't Balanced"))
        #expect(SetupFlow.fixEverything(facts) == ["G1"])
        // What the tune screen hands its view: G9's row asks, and the question is there to ask.
        facts.disk = SetupFlow.Disk(imagesSeen: true, places: [.init(storage: .startupDisk, encrypted: true)])
        let screen = SetupFlow.tune(facts)
        let g9 = try #require(screen.rows.first { $0.id == "G9" })
        #expect(g9.kind == .fixable && g9.action == .ask)
        #expect(screen.bitLocker == .encryptedAtRest(places: [.startupDisk], guessed: false))
    }

    /// Every tune row fixable at once, which is the most Fix Everything can be handed. It presses
    /// exactly the rows a Fix button is drawn on, and no row that asks is one of them.
    @Test("With every tune row fixable, Fix Everything presses exactly the rows that say Fix")
    func fixEverythingIsTheFixRows() {
        var facts = Given.done
        for id in SetupFlow.checks(in: .tune) { facts.rows[id] = Given.row(id, .fixable("needs changing")) }
        let fixRows = SetupFlow.checks(in: .tune).filter { facts.rows[$0]?.action == .fix }
        #expect(SetupFlow.fixEverything(facts) == fixRows)
        #expect(!SetupFlow.fixEverything(facts).contains("G9"))
        #expect(SetupFlow.checks(in: .tune).filter { facts.rows[$0]?.action == .ask } == ["G9"])
    }

    /// The row's action is the check's `apply`, less the one that must be asked: every other check
    /// the window can apply is a plain Fix, and one with nothing to apply has no button at all.
    @Test("Only G9 asks; every other check with an apply is a Fix, and one without has none")
    func rowActions() {
        for check in Recipe.checks {
            let action = SetupFlow.Row(check, .fixable("needs changing")).action
            let expected: SetupFlow.Row.Action = check.apply == nil ? .unavailable : (check.id == "G9" ? .ask : .fix)
            #expect(action == expected, "\(check.id)")
        }
        #expect(SetupFlow.Row.asksFirst == ["G9"])
    }

    /// C4 is in the connect step and `Setup.run` never walks it. It's `.info` whenever the login item
    /// is off, so it can't hold the step up — which is why that's harmless.
    @Test("C4 is the connect step's, and can't hold it up")
    func loginItemNeverBlocks() {
        #expect(SetupFlow.checks(in: .connect) == ["C3", "C4"])
        #expect(!(Setup.fixPass + Setup.manualPass + Setup.restartPass).contains("C4"))
        let facts = Given.done(with: "C4", .info("off; turn it on from the menu: Launch at Login"))
        #expect(SetupFlow.isSatisfied(.connect, facts))
    }

    /// The spec's table had C1 in look-around, which only shows Windows App's row; step 5 is where
    /// it's installed, and setup walks it right before C2.
    @Test("Windows App (C1) is the saved-PC step's, right before C2")
    func windowsAppBelongsToTheSavedPC() {
        #expect(SetupFlow.checks(in: .lookAround) == ["H1", "H9"])
        #expect(SetupFlow.checks(in: .savedPC) == ["C1", "C2"])
        #expect(Setup.manualPass.firstIndex(of: "C1").map { $0 + 1 } == Setup.manualPass.firstIndex(of: "C2"))
    }

    @Test("H6 before H8, as setup and the recipe have them")
    func backupsBeforeNetwork() throws {
        let tune = SetupFlow.checks(in: .tune)
        let h6 = try #require(tune.firstIndex(of: "H6"))
        let h8 = try #require(tune.firstIndex(of: "H8"))
        #expect(h6 < h8)
    }
}

// MARK: - Satisfaction and ordering

@Suite("Which step comes next")
struct SetupFlowOrdering {
    @Test("A Mac nothing has been done to has all eight steps to do")
    func nothingDone() {
        let facts = SetupFlow.Facts()
        for step in WizardStep.allCases { #expect(!SetupFlow.isSatisfied(step, facts), "\(step)") }
        #expect(SetupFlow.next(from: .welcome, facts) == .welcome)
    }

    /// Each step's facts arrive in turn, and the wizard visits every step once, in order.
    @Test("Walking a new Mac visits the eight steps in order and ends")
    func walksAllEight() {
        var facts = SetupFlow.Facts()
        let finish: [(SetupFlow.Facts) -> SetupFlow.Facts] = [
            { var f = $0; f.answers.started = true; return f },
            { var f = $0; f.utm = .installed(version: "4.7.5"); f.utmAnswers = .answered
              f.vms = .listed([Given.winlab]); return f },
            { var f = $0; f.chosenVM = "winlab01"; f.vmRunning = true; return f },
            { var f = $0; for id in SetupFlow.checks(in: .tune) { f.rows[id] = Given.ok(id) }
              f.rdpHost = "winlab01.local"; f.rdpUser = "rosa"; return f },
            { var f = $0; f.rows["H7"] = Given.ok("H7"); return f },
            { var f = $0; f.windowsApp = .installed(version: "11.1.10")
              f.rows["C1"] = Given.ok("C1"); f.rows["C2"] = Given.ok("C2"); return f },
            { var f = $0; f.rows["C3"] = Given.ok("C3"); f.answers.connectionOpened = true
              f.answers.connected = true; return f },
            { var f = $0; f.rows["H5"] = Given.ok("H5"); return f },
        ]
        var visited: [WizardStep] = []
        for satisfy in finish {
            guard let step = SetupFlow.next(from: .welcome, facts) else { break }
            visited.append(step)
            facts = satisfy(facts)
        }
        #expect(visited == WizardStep.allCases)
        #expect(SetupFlow.next(from: .welcome, facts) == nil)
    }

    @Test("next(from:) skips steps with nothing to do and returns nil at the end")
    func nextSkipsAndEnds() {
        #expect(SetupFlow.next(from: .welcome, Given.done) == nil)
        let tuneOpen = Given.done(with: "G3", .fixable("SysMain running, automatic"))
        #expect(SetupFlow.next(from: .welcome, tuneOpen) == .tune)
        #expect(SetupFlow.next(from: .tune, tuneOpen) == .tune)
        #expect(SetupFlow.next(from: .certificate, tuneOpen) == nil)
    }

    @Test("Look-around isn't done while UTM is missing, too old or not UTM")
    func lookAroundNeedsUTM() {
        for state: DependencyState in [.missing, .tooOld(version: "4.6.4", minimum: "4.7"),
                                       .wrongSignature("UTM at /Applications/UTM.app is signed by team QQQQQQQQQQ")] {
            var facts = Given.done
            facts.utm = state
            #expect(!SetupFlow.isSatisfied(.lookAround, facts), "\(state)")
        }
    }

    @Test("Look-around isn't done until utmctl has answered and the VMs are listed")
    func lookAroundNeedsAnAnswer() {
        for answer: UTM.CtlAnswer? in [nil, .silent(seconds: 60), .denied, .failed("no such VM")] {
            var facts = Given.done
            facts.utmAnswers = answer
            #expect(!SetupFlow.isSatisfied(.lookAround, facts), "\(String(describing: answer))")
        }
        var unlisted = Given.done
        unlisted.vms = .notAsked
        #expect(!SetupFlow.isSatisfied(.lookAround, unlisted))
        unlisted.vms = .failed(.init(title: "UTM didn't answer", timedOut: true))
        #expect(!SetupFlow.isSatisfied(.lookAround, unlisted))
        // Windows App missing is said and moved past: nothing to connect to yet.
        var noClient = Given.done
        noClient.windowsApp = .missing
        #expect(SetupFlow.isSatisfied(.lookAround, noClient))
    }

    @Test("The VM step isn't done with nothing chosen, a VM UTM no longer has, or one that's stopped")
    func vmNeedsAChosenRunningVM() {
        var facts = Given.done
        facts.chosenVM = nil
        #expect(!SetupFlow.isSatisfied(.vm, facts))
        facts.chosenVM = "winlab02"   // deleted in UTM
        #expect(!SetupFlow.isSatisfied(.vm, facts))
        facts = Given.done
        facts.vmRunning = false
        #expect(!SetupFlow.isSatisfied(.vm, facts))
        facts = Given.done
        facts.vms = .listed([Given.brunosMac])
        facts.chosenVM = Given.brunosMac.name
        #expect(!SetupFlow.isSatisfied(.vm, facts))
        #expect(SetupFlow.isSatisfied(.vm, Given.done))
    }

    /// The install selects its VM only at its last stage, so what was chosen before says nothing
    /// about whether step 2 is finished while one runs.
    @Test("The VM step isn't done while an install is running")
    func vmWaitsForTheInstall() {
        var facts = Given.done
        facts.installRunning = true
        #expect(!SetupFlow.isSatisfied(.vm, facts))
        #expect(SetupFlow.vm(facts) == .installing)
    }

    @Test("Tune is done when every row is ok, and not while one is still to be read")
    func tuneRows() {
        #expect(SetupFlow.isSatisfied(.tune, Given.done))
        var unread = Given.done
        unread.rows["G4"] = nil
        #expect(!SetupFlow.isSatisfied(.tune, unread))
    }

    /// §5: tune isn't done with any one fixable or manual row. Every row the step can show, in both
    /// kinds, rather than a sample: a slip that settles one row by mistake (a stray case in
    /// `settled`) fails here, and the arguments name the row.
    @Test("Tune isn't done with any one of its rows fixable or manual",
          arguments: SetupFlow.checks(in: .tune), [SetupFlow.StatusKind.fixable, .manual])
    func tuneHeldByAnyRow(id: String, kind: SetupFlow.StatusKind) {
        let facts = Given.done(with: id, Given.status(kind))
        #expect(!SetupFlow.isSatisfied(.tune, facts))
        #expect(SetupFlow.next(from: .welcome, facts) == .tune)
    }

    /// The other half, so a row can't be misclassified the other way either: nothing holds the step
    /// by being fine, informational, or an error nothing here can fix (§2.3: shown, not actioned).
    /// G0 is the exception, and the only one: nothing but its ok says Windows answered.
    @Test("Tune is done with any one of its rows ok, info or error, apart from G0",
          arguments: SetupFlow.checks(in: .tune), [SetupFlow.StatusKind.ok, .info, .error])
    func tuneNotHeldByAnyRow(id: String, kind: SetupFlow.StatusKind) {
        let facts = Given.done(with: id, Given.status(kind))
        #expect(SetupFlow.isSatisfied(.tune, facts) == (id != "G0" || kind == .ok))
    }

    @Test("BitLocker fixable doesn't hold up tune once the person kept it")
    func tuneKeptBitLocker() {
        var facts = Given.done(with: "G9", .fixable("C: is encrypted"))
        #expect(!SetupFlow.isSatisfied(.tune, facts))
        facts.keepBitLocker = true
        #expect(SetupFlow.isSatisfied(.tune, facts))
    }

    /// Setup lets any fix be answered no and any manual step be skipped. Without the same in the
    /// window, someone who wants their bridged network or their animations could never finish.
    @Test("A row the person left alone, or declined in create, doesn't hold up tune")
    func tuneRespectsChoices() {
        var facts = Given.done(with: "H8", .manual("bridged", how: "Network Mode: Shared Network."))
        facts.answers.leftAlone = ["H8"]
        #expect(SetupFlow.isSatisfied(.tune, facts))
        var declined = Given.done(with: "G1", .fixable("active plan isn't Balanced"))
        declined.declined.tuning = true
        #expect(SetupFlow.isSatisfied(.tune, declined))
        var autologon = Given.done(with: "G8", .manual("doesn't sign rosa in at boot", how: "netplwiz"))
        autologon.declined.autologon = true
        #expect(SetupFlow.isSatisfied(.tune, autologon))
    }

    @Test("vCPUs and memory are done once they're staged for the restart")
    func tuneStagedRestart() {
        var cpus = Given.done(with: "H3", .fixable("UTM's default; recommended 6"))
        #expect(!SetupFlow.isSatisfied(.tune, cpus))
        cpus.pending.memoryMB = 16384   // the other one staged is no help
        #expect(!SetupFlow.isSatisfied(.tune, cpus))
        cpus.pending.cpuCores = 6
        #expect(SetupFlow.isSatisfied(.tune, cpus))
        var facts = Given.done(with: "H3", .fixable("UTM's default; recommended 6"))
        facts.rows["H4"] = Given.row("H4", .fixable("8192 MB; recommended 16384 MB"))
        #expect(!SetupFlow.isSatisfied(.tune, facts))
        facts.pending.cpuCores = 6
        #expect(!SetupFlow.isSatisfied(.tune, facts))
        facts.pending.memoryMB = 16384
        #expect(SetupFlow.isSatisfied(.tune, facts))
    }

    /// Without G0 every other guest row reads "not checked (G0)", which is info and would pass.
    @Test("Windows has to answer: G0 is never settled by anything but ok")
    func tuneNeedsWindows() {
        var facts = Given.done(with: "G0", .error("Windows 11 Home can't host Remote Desktop sessions"))
        #expect(!SetupFlow.isSatisfied(.tune, facts))
        facts = Given.done(with: "G0", .manual("the QEMU guest agent isn't answering", how: "Install UTM Guest Tools."))
        facts.answers.leftAlone = ["G0"]
        #expect(!SetupFlow.isSatisfied(.tune, facts))
        // Any other row's error is shown, not actioned, and doesn't hold the step.
        #expect(SetupFlow.isSatisfied(.tune, Given.done(with: "G2", .error("Windows reported no power schemes"))))
    }

    @Test("The certificate step is done when H7 is ok, or the person left it")
    func certificateStep() {
        #expect(SetupFlow.isSatisfied(.certificate, Given.done))
        var facts = Given.done(with: "H7", .fixable("not trusted for winlab01.local (no trust setting)"))
        #expect(!SetupFlow.isSatisfied(.certificate, facts))
        facts.answers.leftAlone = ["H7"]
        #expect(SetupFlow.isSatisfied(.certificate, facts))
        #expect(!SetupFlow.isSatisfied(.certificate, Given.done(with: "H7", .info("needs Windows (G0)"))))
    }

    @Test("The saved-PC step is done when there's a saved PC, or on Skip")
    func savedPCStep() {
        #expect(SetupFlow.isSatisfied(.savedPC, Given.done))
        var facts = Given.done(with: "C2", .fixable("none for winlab01.local; setup can save it for you"))
        #expect(!SetupFlow.isSatisfied(.savedPC, facts))
        facts.answers.leftAlone = ["C2"]
        #expect(SetupFlow.isSatisfied(.savedPC, facts))
    }

    @Test("Connect isn't done until the person has answered, either way")
    func connectStep() {
        var facts = Given.done
        facts.answers.connected = nil
        #expect(!SetupFlow.isSatisfied(.connect, facts))
        facts.answers.connected = false
        #expect(SetupFlow.isSatisfied(.connect, facts))
        facts.answers.connected = true
        #expect(SetupFlow.isSatisfied(.connect, facts))
    }

    /// Step 5 offers Skip on Windows App, so every step after it has to be one the person can
    /// leave. Connect can't connect without the app: it says it was skipped rather than asking for
    /// an app nobody is offering, and the finish has no connection to wait for.
    @Test("Skipping Windows App leads on to the finish, through steps that say it was skipped")
    func skippingWindowsAppReachesTheEnd() {
        var facts = Given.done
        facts.windowsApp = .missing
        facts.rows["C1"] = Given.row("C1", .fixable("not installed; setup can open its App Store page"))
        facts.rows["C2"] = Given.row("C2", .info("needs Windows App (C1)"))
        facts.rows["H5"] = Given.row("H5", .fixable("console window on; headless cuts idle host CPU"))
        facts.answers = SetupFlow.Answers(started: true)
        facts.pending.cpuCores = 6                     // staged in tune: the finish has a restart to do
        #expect(SetupFlow.next(from: .welcome, facts) == .savedPC)
        #expect(SetupFlow.savedPC(facts) == .needsWindowsApp(.missing))

        facts.answers.leftAlone.insert("C1")           // Skip
        #expect(SetupFlow.savedPC(facts) == .skipped)
        #expect(SetupFlow.isSatisfied(.savedPC, facts))
        // Connect: said, and settled. A window already on it (Back, the step bar) stays and says so.
        #expect(SetupFlow.connect(facts) == .windowsAppSkipped)
        #expect(SetupFlow.isSatisfied(.connect, facts))
        #expect(SetupFlow.landing(on: .connect, facts) == .connect)
        // The finish: reached from either step, with its restart and no headless offer, because
        // nobody has seen Remote Desktop work.
        #expect(SetupFlow.next(from: .savedPC, facts) == .finish)
        #expect(SetupFlow.next(from: .connect, facts) == .finish)
        #expect(SetupFlow.landing(on: .finish, facts) == .finish)
        #expect(SetupFlow.finish(facts).restart.summary == "6 vCPUs")
        #expect(SetupFlow.finish(facts).headless == .connectSkipped)
        // And the end: once the restart is applied there's nothing left to do.
        facts.pending = ConfigChanges()
        #expect(SetupFlow.isSatisfied(.finish, facts))
        #expect(SetupFlow.next(from: .welcome, facts) == nil)
    }

    /// The saved PC's Skip skips saving, not Windows App. If the app has gone since, step 5 comes
    /// undone and the window goes back there, where it can be installed or skipped in turn — not on
    /// to a connect step asking for an app nothing offers.
    /// A saved PC is only saved if the app that holds it is there. C2 can read `.ok` while Windows App
    /// is missing or isn't Microsoft's: when the app won't answer, C2 falls back to the host Winbar was
    /// told (`Config.savedPCHost`, "your word"). If that `.ok` counted, step 5 passed, and connect then
    /// showed `.needsWindowsApp` — which never settles and has nothing to press — while step 5, showing
    /// `.saved`, offered no Skip either. A dead end, reached through a state a real Mac gets into.
    @Test("A saved PC doesn't count while Windows App is missing or isn't Microsoft's",
          arguments: [DependencyState.missing, .wrongSignature("signed by team X, not Microsoft's")])
    func aSavedPCNeedsItsApp(state: DependencyState) {
        var facts = Given.done
        facts.windowsApp = state
        facts.rows["C1"] = Given.row("C1", .fixable("not installed; setup can open its App Store page"))
        facts.rows["C2"] = Given.row("C2", .ok("winlab01.local (your word; Windows App didn't answer)"))
        facts.answers = SetupFlow.Answers(started: true)
        #expect(SetupFlow.savedPC(facts) == .needsWindowsApp(state))
        #expect(!SetupFlow.isSatisfied(.savedPC, facts))
        #expect(SetupFlow.landing(on: .connect, facts) == .savedPC)
        // The trap itself, stated as the thing that must never be true.
        let trapped = SetupFlow.next(from: .welcome, facts) == .connect && SetupFlow.connect(facts) == .needsWindowsApp
        #expect(!trapped)
        // And Skip still gets them out, all the way to the end.
        facts.answers.leftAlone.insert("C1")
        #expect(SetupFlow.isSatisfied(.savedPC, facts))
        #expect(SetupFlow.connect(facts) == .windowsAppSkipped)
        #expect(SetupFlow.isSatisfied(.connect, facts))
    }

    /// The common skip: nothing staged in tune, so there is no restart to hold the finish open and the
    /// whole flow is complete the moment Windows App is skipped. The Done screen is what the person sees
    /// next, and its line about Connect would be false — so the engine has to tell it Connect was skipped.
    @Test("Skipping Windows App with nothing staged still tells the Done screen Connect was skipped")
    func skippingWithNothingStaged() {
        var facts = Given.done
        facts.windowsApp = .missing
        facts.rows["C1"] = Given.row("C1", .fixable("not installed; setup can open its App Store page"))
        facts.rows["C2"] = Given.row("C2", .info("needs Windows App (C1)"))
        facts.rows["H5"] = Given.row("H5", .fixable("console window on; headless cuts idle host CPU"))
        facts.answers = SetupFlow.Answers(started: true)
        #expect(facts.pending.isEmpty)
        #expect(SetupFlow.next(from: .welcome, facts) == .savedPC)
        facts.answers.leftAlone.insert("C1")                      // Skip
        #expect(SetupFlow.next(from: .welcome, facts) == nil)     // complete: straight to Done
        #expect(SetupFlow.finish(facts).headless == .connectSkipped)
    }

    @Test("Skipping the saved PC still needs Windows App, and step 5 is where it comes back")
    func skippingTheSavedPCIsNotSkippingWindowsApp() {
        var facts = Given.done(with: "C2", .info("needs Windows App (C1)"))
        facts.rows["C1"] = Given.row("C1", .fixable("not installed; setup can open its App Store page"))
        facts.windowsApp = .missing
        facts.answers = SetupFlow.Answers(started: true, leftAlone: ["C2"])
        #expect(SetupFlow.savedPC(facts) == .needsWindowsApp(.missing))
        #expect(SetupFlow.landing(on: .connect, facts) == .savedPC)
        facts.answers.leftAlone.insert("C1")
        #expect(SetupFlow.landing(on: .connect, facts) == .connect)
        #expect(SetupFlow.connect(facts) == .windowsAppSkipped)
        // With the app there, the saved PC's Skip means a one-off connection, as the spec has it.
        var oneOff = Given.done(with: "C2", .fixable("none for winlab01.local; setup can save it for you"))
        oneOff.answers = SetupFlow.Answers(started: true, leftAlone: ["C2"])
        #expect(SetupFlow.savedPC(oneOff) == .skipped)
        #expect(SetupFlow.connect(oneOff) == .ready(host: "winlab01.local", savedPC: false))
    }

    /// With Remote Desktop not seen working there's nothing to offer, so the finish is done — unless
    /// vCPUs or memory are still staged for the restart.
    @Test("Finish with connected == false offers nothing, and is done once nothing is staged")
    func finishWhenConnectFailed() {
        var facts = Given.done(with: "H5", .fixable("console window on; headless cuts idle host CPU"))
        facts.answers.connected = false
        #expect(SetupFlow.isSatisfied(.finish, facts))
        #expect(SetupFlow.finish(facts).headless == .notOffered)
        facts.pending.cpuCores = 6
        #expect(!SetupFlow.isSatisfied(.finish, facts))
        #expect(SetupFlow.finish(facts).headless == .notOffered)
    }

    @Test("Finish waits for the headless answer, and for the restart")
    func finishWaitsForAnswers() {
        var facts = Given.done(with: "H5", .fixable("console window on; headless cuts idle host CPU"))
        #expect(!SetupFlow.isSatisfied(.finish, facts))            // offered, unanswered
        facts.answers.leftAlone = ["H5"]                           // Keep the Screen
        #expect(SetupFlow.isSatisfied(.finish, facts))
        facts.answers.leftAlone = []
        facts.pending.display = .headless                          // Go Headless: staged, not applied
        #expect(!SetupFlow.isSatisfied(.finish, facts))
        facts.otherVMs = .notAsked
        facts.pending = ConfigChanges()
        #expect(!SetupFlow.isSatisfied(.finish, facts))            // UTM still to be asked
        facts.otherVMs = .running(["Debian"])
        #expect(SetupFlow.isSatisfied(.finish, facts))             // a refusal is said, not waited on
    }
}

// MARK: - Freshness

@Suite("Telling a fresh snapshot from a stale one")
struct SetupFlowFreshness {
    static let taken = Date(timeIntervalSince1970: 1_800_000_000)

    static var stamped: SetupFlow.Facts {
        var facts = Given.done
        facts.stamp = SetupFlow.Stamp(taken: taken, utmPIDs: [4242], vmPID: 5151)
        return facts
    }

    @Test("A snapshot the runner didn't take is stale")
    func neverTaken() {
        #expect(SetupFlow.staleness(of: Given.done, utmPIDs: [4242], vmPID: 5151, lastWake: nil) == .neverTaken)
    }

    @Test("Nothing changed, nothing stale")
    func fresh() {
        #expect(SetupFlow.staleness(of: Self.stamped, utmPIDs: [4242], vmPID: 5151, lastWake: nil) == nil)
        #expect(SetupFlow.staleness(of: Self.stamped, utmPIDs: [4242], vmPID: 5151,
                                    lastWake: Self.taken.addingTimeInterval(-60)) == nil)
    }

    /// Every wait runs against wall-clock time: a closed lid spends a deadline, it doesn't pause it.
    @Test("A sleep since the snapshot makes it stale")
    func slept() {
        #expect(SetupFlow.staleness(of: Self.stamped, utmPIDs: [4242], vmPID: 5151,
                                    lastWake: Self.taken.addingTimeInterval(8 * 3600)) == .slept)
    }

    @Test("UTM quitting, restarting or starting underneath makes it stale")
    func utmChanged() {
        for now: Set<Int32> in [[], [4343], [4242, 4343]] {
            #expect(SetupFlow.staleness(of: Self.stamped, utmPIDs: now, vmPID: 5151, lastWake: nil) == .utmChanged)
        }
    }

    @Test("The VM stopping, starting or restarting makes it stale")
    func vmChanged() {
        for now: Int32? in [nil, 5252] {
            #expect(SetupFlow.staleness(of: Self.stamped, utmPIDs: [4242], vmPID: now, lastWake: nil) == .vmChanged)
        }
    }

    /// Back from System Settings, the App Store or Windows itself: nothing read before the person
    /// left can be trusted. The control is an activation before the snapshot, which changes nothing.
    @Test("Coming back to the front since the snapshot makes it stale, and before it doesn't")
    func reactivated() {
        #expect(SetupFlow.staleness(of: Self.stamped, utmPIDs: [4242], vmPID: 5151, lastWake: nil,
                                    lastActivation: Self.taken.addingTimeInterval(90)) == .reactivated)
        #expect(SetupFlow.staleness(of: Self.stamped, utmPIDs: [4242], vmPID: 5151, lastWake: nil,
                                    lastActivation: Self.taken.addingTimeInterval(-90)) == nil)
        // A sleep or a process change says more than coming back does, so it wins.
        #expect(SetupFlow.staleness(of: Self.stamped, utmPIDs: [4242], vmPID: 5151,
                                    lastWake: Self.taken.addingTimeInterval(60),
                                    lastActivation: Self.taken.addingTimeInterval(90)) == .slept)
        #expect(SetupFlow.staleness(of: Self.stamped, utmPIDs: [], vmPID: nil, lastWake: nil,
                                    lastActivation: Self.taken.addingTimeInterval(90)) == .utmChanged)
    }

    /// A wizard left on step 4 overnight, with the VM stopped since, goes back to step 2's Start It
    /// rather than offering Trust It against a VM that isn't running.
    @Test("A fresh snapshot sends the window back to a step that came undone")
    func landsBack() {
        var facts = Given.done
        facts.vmRunning = false
        #expect(SetupFlow.landing(on: .certificate, facts) == .vm)
        facts = Given.done
        facts.utmAnswers = nil                        // UTM restarted; utmctl not asked since
        #expect(SetupFlow.landing(on: .finish, facts) == .lookAround)
        #expect(SetupFlow.landing(on: .savedPC, Given.done(with: "G6", .fixable("Remote Desktop is off"))) == .tune)
    }

    /// Moving on is the person's press: a snapshot that arrives while they read must not move them.
    @Test("A fresh snapshot never moves the window forward")
    func neverForward() {
        #expect(SetupFlow.landing(on: .tune, Given.done) == .tune)
        let later = Given.done(with: "H7", .fixable("not trusted for winlab01.local (no trust setting)"))
        #expect(SetupFlow.landing(on: .tune, later) == .tune)
        #expect(SetupFlow.landing(on: .welcome, SetupFlow.Facts()) == .welcome)
    }
}

// MARK: - What each screen draws (the critique's finding 2)

/// Every screen of §2.3, drawn from a snapshot and nothing else: the window's views read `Facts`
/// only, so anything a screen shows has to be answerable from it without `Recipe` or `Context`.
@Suite("Each step's screen can be drawn from the snapshot")
struct SetupFlowScreens {
    @Test("A row carries everything Setup.offer and Setup.walk print")
    func rowsCarryTheirWords() {
        let manual = Given.row("G5", .manual("rosa has no password", how: "Set it in Settings → Accounts."))
        #expect(manual.id == "G5")
        #expect(manual.title == Recipe.check("G5")?.title)
        #expect(manual.why == Recipe.check("G5")?.why)
        #expect(manual.kind == .manual)
        #expect(manual.detail == "rosa has no password")
        #expect(manual.how == "Set it in Settings → Accounts.")
        #expect(manual.canGuide && manual.action == .unavailable)   // Open, and Done; no Fix
        let fixable = Given.row("G1", .fixable("hibernation on"))
        #expect(fixable.action == .fix && fixable.how == nil)
        // C2 reads fixable, but its step holds the conversation (a password), not a Fix button.
        #expect(Given.row("C2", .fixable("none for winlab01.local")).action == .unavailable)
        #expect(Given.row("H6", .manual("can't tell", how: "System Settings")).canGuide)
    }

    @Test("Each status maps to its kind")
    func kinds() {
        #expect(SetupFlow.StatusKind(.ok("")) == .ok)
        #expect(SetupFlow.StatusKind(.fixable("")) == .fixable)
        #expect(SetupFlow.StatusKind(.manual("", how: "")) == .manual)
        #expect(SetupFlow.StatusKind(.info("")) == .info)
        #expect(SetupFlow.StatusKind(.error("")) == .error)
    }

    // Step 1

    @Test("Look around: UTM missing carries what the dependency conversation needs")
    func lookAroundMissingUTM() {
        var facts = SetupFlow.Facts()
        #expect(SetupFlow.lookAround(facts) == .needsUTM(.missing))
        // The plan is answerable from the snapshot: Homebrew's path decides brew or download.
        #expect(Dependencies.plan(for: .utm, state: facts.utm, brew: facts.homebrew)
                == .download(url: Dependency.utmDownloadURL))
        facts.homebrew = "/opt/homebrew/bin/brew"
        #expect(Dependencies.plan(for: .utm, state: facts.utm, brew: facts.homebrew)
                == .brew(brew: "/opt/homebrew/bin/brew", cask: "utm"))
        #expect(!DependencyCopy.situation(.utm, state: facts.utm).isEmpty)
    }

    @Test("Look around: from asking UTM to the silence, the refusal and the answer")
    func lookAroundAskingUTM() {
        var facts = SetupFlow.Facts()
        facts.utm = .installed(version: "4.7.5")
        #expect(SetupFlow.lookAround(facts) == .askUTM)
        facts.utmAnswers = .silent(seconds: 60)
        facts.utmConsent = .wouldPrompt
        facts.utmQuarantined = true
        #expect(SetupFlow.lookAround(facts) == .utmSilent(seconds: 60, consent: .wouldPrompt, quarantined: true))
        // Which is everything the row's words need.
        if case .utmSilent(let seconds, let consent, let quarantined) = SetupFlow.lookAround(facts) {
            #expect(UTMFirstUse.silentDetail(seconds: seconds).contains("60 seconds"))
            #expect(UTMFirstUse.how(consent: consent, quarantined: quarantined).contains("still outstanding"))
        }
        facts.utmAnswers = .denied
        #expect(SetupFlow.lookAround(facts) == .utmDenied)
        facts.utmAnswers = .failed("utmctl: unexpected reply")
        #expect(SetupFlow.lookAround(facts) == .utmFailed("utmctl: unexpected reply"))
        facts.utmAnswers = .answered
        #expect(SetupFlow.lookAround(facts) == .listVMs)
        facts.vms = .listed([])
        #expect(SetupFlow.lookAround(facts) == .done(windowsApp: .missing))
    }

    /// An empty list standing in for a failure would say "No Windows VM yet — Make One" to a Mac
    /// that simply hasn't allowed Winbar to ask.
    @Test("Look around: a VM list that failed is never an empty one")
    func listingFailureIsNotEmpty() {
        let denied = WinbarError("Winbar isn't allowed to control UTM", "Turn on UTM under Winbar.", automationDenied: true)
        let listing = SetupFlow.VMListing(.failure(denied))
        #expect(listing == .failed(.init(title: "Winbar isn't allowed to control UTM",
                                          detail: "Turn on UTM under Winbar.", automationDenied: true)))
        var facts = Given.done
        facts.vms = listing
        if case .listFailed(let failure) = SetupFlow.lookAround(facts) { #expect(failure.automationDenied) }
        else { Issue.record("expected the listing's failure") }
        #expect(SetupFlow.vm(facts) == .unlisted)
        #expect(SetupFlow.VMListing(.success([Given.winlab])) == .listed([Given.winlab]))
    }

    @Test("Look around: the three rows read from the snapshot")
    func lookAroundRows() {
        var facts = Given.done
        facts.windowsApp = .missing
        facts.rows["C1"] = Given.row("C1", .fixable("not installed; setup can open its App Store page"))
        #expect(SetupFlow.lookAround(facts) == .done(windowsApp: .missing))
        #expect(facts.rows["H1"]?.detail == "fine")
        #expect(facts.rows["C1"]?.kind == .fixable)
        #expect(facts.vms == .listed([Given.winlab, Given.debian]))
    }

    // Step 2

    @Test("The VM step with none: only non-QEMU VMs, or nothing at all")
    func vmNone() {
        var facts = Given.done
        facts.chosenVM = nil
        facts.vms = .listed([])
        #expect(SetupFlow.vm(facts) == .choose(.none, previous: nil))
        facts.vms = .listed([Given.brunosMac])
        #expect(SetupFlow.vm(facts) == .choose(.none, previous: nil))
    }

    /// Setup's rule (`Context.candidates`): one Windows VM is adopted even with a Debian beside it,
    /// and a lone VM with UTM's generic icon still counts — a hand-made Windows VM can have one.
    @Test("The VM step with one, by winbar setup's own rule")
    func vmOne() {
        var facts = Given.done
        facts.chosenVM = nil
        facts.vms = .listed([Given.winlab])
        #expect(SetupFlow.vm(facts) == .choose(.one(Given.winlab), previous: nil))
        facts.vms = .listed([Given.debian, Given.winlab, Given.brunosMac])
        #expect(SetupFlow.vm(facts) == .choose(.one(Given.winlab), previous: nil))
        var plain = Given.winlab
        plain.icon = ""
        facts.vms = .listed([plain])
        #expect(SetupFlow.vm(facts) == .choose(.one(plain), previous: nil))
        #expect(Context.candidates(in: [plain]) == [plain])
    }

    @Test("The VM step with three: Windows first, then by name, Debian included")
    func vmThree() {
        var facts = Given.done
        facts.chosenVM = nil
        facts.vms = .listed([Given.debian, Given.winlab, Given.atelier, Given.brunosMac])
        #expect(SetupFlow.vm(facts) == .choose(.several([Given.atelier, Given.winlab, Given.debian]), previous: nil))
    }

    @Test("The VM step with twelve keeps the menu's order")
    func vmTwelve() {
        let windows = (1...7).map { n in
            VMInfo(id: "5A1C0DE0-0000-4000-8000-00000000010\(n)", name: "winlab\(String(format: "%02d", 8 - n))",
                   backend: "qemu", icon: "windows")
        }
        let others = ["rosa-arch", "atelier-debian", "bruno-fedora", "kali", "netbsd"].enumerated().map { n, name in
            VMInfo(id: "5A1C0DE0-0000-4000-8000-00000000020\(n)", name: name, backend: "qemu", icon: "linux")
        }
        var facts = Given.done
        facts.chosenVM = nil
        facts.vms = .listed(others + windows)
        guard case .choose(.several(let offered), nil) = SetupFlow.vm(facts) else {
            Issue.record("expected the picker")
            return
        }
        #expect(offered.count == 12)
        #expect(offered.map(\.name) == ["winlab01", "winlab02", "winlab03", "winlab04", "winlab05", "winlab06",
                                        "winlab07", "atelier-debian", "bruno-fedora", "kali", "netbsd", "rosa-arch"])
        // The menu's Choose VM, item for item: both read `VMInfo.choosable`.
        #expect(offered == VMInfo.choosable(others + windows))
    }

    @Test("The VM step when the chosen VM is gone, or isn't one Winbar can manage")
    func vmPreviousChoice() {
        var facts = Given.done
        facts.chosenVM = "winlab02"
        #expect(SetupFlow.vm(facts) == .choose(.one(Given.winlab), previous: .gone("winlab02")))
        facts.vms = .listed([Given.winlab, Given.brunosMac])
        facts.chosenVM = Given.brunosMac.name
        #expect(SetupFlow.vm(facts) == .choose(.one(Given.winlab), previous: .notQEMU("Bruno's macOS")))
    }

    @Test("The VM step once chosen: Start It, then nothing left")
    func vmChosen() {
        var facts = Given.done
        facts.vmRunning = false
        #expect(SetupFlow.vm(facts) == .stopped(Given.winlab))
        #expect(facts.chosen?.name == "winlab01")   // “winlab01” is stopped…
        facts.vmRunning = true
        #expect(SetupFlow.vm(facts) == .ready(Given.winlab))
    }

    // Step 3

    @Test("Tune: the rows in step order, and which are still to be read")
    func tuneRowsAndSurvey() {
        var facts = Given.done
        #expect(SetupFlow.tune(facts).rows.map(\.id) == SetupFlow.checks(in: .tune))
        #expect(SetupFlow.tune(facts).unread.isEmpty)
        for id in SetupFlow.checks(in: .tune) { facts.rows[id] = nil }
        #expect(SetupFlow.tune(facts).rows.isEmpty)
        #expect(SetupFlow.tune(facts).unread == SetupFlow.checks(in: .tune))   // Asking Windows…
    }

    @Test("Tune: Fix Everything takes the fixable rows in order, and nothing the person owns")
    func fixEverything() {
        var facts = Given.done
        facts.rows["G4"] = Given.row("G4", .fixable("3 of 9 differ"))
        facts.rows["G1"] = Given.row("G1", .fixable("hibernation on"))
        facts.rows["G7"] = Given.row("G7", .fixable("the listener uses Windows' generated certificate"))
        facts.rows["G5"] = Given.row("G5", .manual("rosa has no password", how: "Set one."))
        facts.rows["G9"] = Given.row("G9", .fixable("C: is encrypted"))
        facts.rows["H3"] = Given.row("H3", .fixable("4; recommended 6"))
        facts.rows["H4"] = Given.row("H4", .fixable("8192 MB; recommended 16384 MB"))
        #expect(SetupFlow.fixEverything(facts) == ["G1", "G4", "G7", "H3", "H4"])
        facts.answers.leftAlone = ["G4"]
        facts.pending.memoryMB = 16384
        #expect(SetupFlow.fixEverything(facts) == ["G1", "G7", "H3"])
        facts.declined.tuning = true
        #expect(SetupFlow.fixEverything(facts) == ["G7", "H3"])
        #expect(SetupFlow.tune(facts).fixEverything == ["G7", "H3"])
    }

    @Test("Tune: what create's checklist declined, and what's staged for the restart")
    func tuneDeclinedAndStaged() {
        var facts = Given.done
        facts.declined = SetupFlow.Declined(autologon: true, remoteDesktop: false, tuning: true)
        facts.pending.cpuCores = 6
        let screen = SetupFlow.tune(facts)
        #expect(screen.declined == ["G1": "--winbar-tuning", "G2": "--winbar-tuning", "G3": "--winbar-tuning",
                                    "G4": "--winbar-tuning", "G8": "--autologon"])
        #expect(screen.staged == ["H3"])
        // Which is the restart's own summary, for "Applied at the end, with one restart of …".
        #expect(facts.pending.summary == "6 vCPUs")
    }

    /// `Setup.offerDecryption`'s two branches, from facts the runner looked up so the window
    /// doesn't shell out to fdesetup and diskutil.
    @Test("Tune: BitLocker's question, on an encrypted disk and an unencrypted one")
    func bitLockerQuestion() {
        var facts = Given.done(with: "G9", .fixable("C: is encrypted"))
        #expect(SetupFlow.bitLockerQuestion(facts) == nil)   // the disk not looked at yet
        facts.disk = SetupFlow.Disk(imagesSeen: true, places: [.init(storage: .startupDisk, encrypted: true)])
        #expect(SetupFlow.bitLockerQuestion(facts) == .encryptedAtRest(places: [.startupDisk], guessed: false))
        facts.disk = SetupFlow.Disk(imagesSeen: false, places: [.init(storage: .startupDisk, encrypted: true)])
        #expect(SetupFlow.bitLockerQuestion(facts) == .encryptedAtRest(places: [.startupDisk], guessed: true))
        facts.disk = SetupFlow.Disk(imagesSeen: true, places: [.init(storage: .startupDisk, encrypted: true),
                                                               .init(storage: .volume("/Volumes/Atelier"), encrypted: false)])
        #expect(SetupFlow.bitLockerQuestion(facts) == .unencrypted(places: [.volume("/Volumes/Atelier")]))
        // macOS not saying counts as not encrypted: the question never makes decrypting sound safe.
        facts.disk = SetupFlow.Disk(imagesSeen: true, places: [.init(storage: .startupDisk, encrypted: nil)])
        #expect(SetupFlow.bitLockerQuestion(facts) == .unencrypted(places: [.startupDisk]))
        #expect(SetupFlow.tune(facts).bitLocker == .unencrypted(places: [.startupDisk]))
        facts.keepBitLocker = true
        #expect(SetupFlow.bitLockerQuestion(facts) == nil)
        #expect(SetupFlow.bitLockerQuestion(Given.done(with: "G9", .info("decrypting C: (40% still encrypted)"))) == nil)
    }

    /// `offerDecryption`'s two prompts: "Decrypt C:?" defaults to yes, "Decrypt C: anyway?" to no.
    /// Return must never decrypt a disk kept somewhere that isn't encrypted.
    @Test("Tune: BitLocker's question defaults to decrypting only when the disk is encrypted at rest")
    func bitLockerDefault() {
        #expect(SetupFlow.BitLockerQuestion.encryptedAtRest(places: [.startupDisk], guessed: false).decryptsByDefault)
        #expect(SetupFlow.BitLockerQuestion.encryptedAtRest(places: [.startupDisk], guessed: true).decryptsByDefault)
        #expect(!SetupFlow.BitLockerQuestion.unencrypted(places: [.startupDisk]).decryptsByDefault)
        #expect(!SetupFlow.BitLockerQuestion.unencrypted(places: [.volume("/Volumes/Atelier")]).decryptsByDefault)
    }

    // Step 4

    @Test("The certificate: Trust It, trusted, and back to G7 when there's none")
    func certificateScreen() {
        #expect(SetupFlow.certificate(Given.done) == .trusted(host: "winlab01.local"))
        var facts = Given.done(with: "H7", .fixable("not trusted for winlab01.local (no trust setting)"))
        #expect(SetupFlow.certificate(facts) == .trust(host: "winlab01.local"))
        facts = Given.done(with: "H7", .info("needs a certificate for winlab01.local first (G7)"))
        facts.rows["G7"] = Given.row("G7", .fixable("the listener uses Windows' generated certificate"))
        #expect(SetupFlow.certificate(facts) == .needsCertificate(host: "winlab01.local"))
        // Windows not read at all is no reason to send anyone back to G7.
        facts.rows["G0"] = Given.row("G0", .manual("winlab01 is stopped", how: "winbar start"))
        #expect(SetupFlow.certificate(facts) == .notYet(facts.rows["H7"]))
        var noHost = Given.done(with: "H7", .info("no RDP host yet"))
        noHost.rdpHost = nil
        #expect(SetupFlow.certificate(noHost) == .notYet(noHost.rows["H7"]))
    }

    // Step 5

    @Test("The saved PC: install Windows App, quit it, save, skip")
    func savedPCScreen() throws {
        var facts = Given.done(with: "C2", .info("needs Windows App (C1)"))
        facts.windowsApp = .missing
        #expect(SetupFlow.savedPC(facts) == .needsWindowsApp(.missing))
        facts = Given.done(with: "C2", .fixable("none for winlab01.local; setup can save it for you"))
        #expect(SetupFlow.savedPC(facts) == .save(host: "winlab01.local", user: "rosa"))
        // "Password for rosa", and the paragraph that goes with it.
        #expect(SetupCopy.SavedPC.why(user: facts.rdpUser ?? "").contains("the password for rosa"))   // moved to the deck in wizard commit 3
        facts.windowsAppRunning = true
        #expect(SetupFlow.savedPC(facts) == .windowsAppOpen(host: "winlab01.local"))
        facts = Given.done(with: "C2", .manual("none for winlab01.local, and Windows App is open", how: "Quit it."))
        facts.windowsAppRunning = true
        #expect(SetupFlow.savedPC(facts) == .windowsAppOpen(host: "winlab01.local"))
        let couldNotAsk = Given.done(with: "C2", .manual("couldn't ask Windows App", how: "Add it by hand."))
        let unanswered = try #require(couldNotAsk.rows["C2"])
        #expect(SetupFlow.savedPC(couldNotAsk) == .manual(unanswered))
        facts.answers.leftAlone = ["C2"]
        #expect(SetupFlow.savedPC(facts) == .skipped)
        #expect(SetupFlow.savedPC(Given.done) == .saved(Given.ok("C2")))
        var nobody = Given.done(with: "C2", .fixable("none for winlab01.local; setup can save it for you"))
        nobody.rdpUser = nil
        #expect(SetupFlow.savedPC(nobody) == .notYet(nobody.rows["C2"]))
    }

    // Step 6

    @Test("Connect: Accessibility, Connect, the question, and what went wrong")
    func connectScreen() {
        var facts = Given.done
        facts.answers = SetupFlow.Answers(started: true)
        facts.rows["C3"] = Given.row("C3", .manual("not granted to Winbar", how: "System Settings → Accessibility"))
        #expect(SetupFlow.connect(facts) == .allowAccessibility)
        facts.rows["C3"] = Given.ok("C3")
        #expect(SetupFlow.connect(facts) == .ready(host: "winlab01.local", savedPC: true))
        facts.rows["C2"] = Given.row("C2", .manual("couldn't ask Windows App", how: "Add it by hand."))
        #expect(SetupFlow.connect(facts) == .ready(host: "winlab01.local", savedPC: false))   // one-off
        facts.answers.connectionOpened = true
        #expect(SetupFlow.connect(facts) == .didItWork(host: "winlab01.local"))
        facts.answers.connected = false
        facts.readiness = .notReady
        #expect(SetupFlow.connect(facts) == .didNotWork(.init(readiness: .notReady, host: "winlab01.local",
                                                              user: "rosa", savedPC: false, console: .headless)))
        facts.answers.connected = true
        #expect(SetupFlow.connect(facts) == .worked)
        var noClient = Given.done
        noClient.answers = SetupFlow.Answers(started: true)
        noClient.windowsApp = .missing
        #expect(SetupFlow.connect(noClient) == .needsWindowsApp)
        var unread = Given.done
        unread.answers = SetupFlow.Answers(started: true)
        unread.rows["C3"] = nil
        #expect(SetupFlow.connect(unread) == .notYet)
    }

    // Step 7

    @Test("Finish: the one restart, and the VM it's for")
    func finishRestart() {
        var facts = Given.done
        facts.pending.cpuCores = 8
        facts.pending.memoryMB = 16384
        let screen = SetupFlow.finish(facts)
        #expect(screen.vm == "winlab01")
        #expect(screen.restart.summary == "8 vCPUs, 16384 MB RAM")
        #expect(!screen.utmRestartOwed)
        facts.utmRestartOwed = true
        #expect(SetupFlow.finish(facts).utmRestartOwed)
    }

    /// COHERENCE C2: `Reconfigure.apply` refuses a display change while another VM runs, so the
    /// window refuses too rather than offering a button that ends on that refusal.
    @Test("Finish: the headless offer, and the refusals in its place")
    func headlessOffer() {
        var facts = Given.done(with: "H5", .fixable("console window on; headless cuts idle host CPU"))
        #expect(SetupFlow.headlessOffer(facts) == .offer)
        facts.otherVMs = .running(["Debian"])
        #expect(SetupFlow.headlessOffer(facts) == .otherVMsRunning(["Debian"]))
        facts.otherVMs = SetupFlow.OtherVMs(.failure(WinbarError("Couldn't ask UTM which other VMs are running",
                                                                 "AppleEvent timed out", timedOut: true)))
        #expect(SetupFlow.headlessOffer(facts) == .couldNotConfirm("AppleEvent timed out"))
        facts.otherVMs = .notAsked
        #expect(SetupFlow.headlessOffer(facts) == .checkOtherVMs)
        facts.otherVMs = .running([])
        facts.answers.connected = nil
        #expect(SetupFlow.headlessOffer(facts) == .waitingForConnect)
        facts.answers.connected = false
        #expect(SetupFlow.headlessOffer(facts) == .notOffered)
        facts.answers.connected = true
        facts.rows["H5"] = Given.row("H5", .info("console window on; headless is offered once Remote Desktop works"))
        #expect(SetupFlow.headlessOffer(facts) == .notReady)
        facts.rows["H5"] = nil
        #expect(SetupFlow.headlessOffer(facts) == .notChecked)
        #expect(SetupFlow.headlessOffer(Given.done) == .alreadyHeadless)
    }

    @Test("Finish: Go Headless and Keep the Screen")
    func headlessAnswered() {
        var facts = Given.done(with: "H5", .fixable("console window on; headless cuts idle host CPU"))
        facts.pending.display = .headless
        #expect(SetupFlow.headlessOffer(facts) == .staged)
        #expect(SetupFlow.finish(facts).restart.summary == "headless")
        facts.pending = ConfigChanges()
        facts.answers.leftAlone = ["H5"]
        #expect(SetupFlow.headlessOffer(facts) == .kept)
    }
}
