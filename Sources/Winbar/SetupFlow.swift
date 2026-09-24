import Foundation

/// The wizard's steps, in the order the window walks them.
///
/// Comparable by that order, because the only questions ever asked of two steps are "which comes
/// first" (has an earlier step come undone?) and "what is the next one".
enum WizardStep: String, CaseIterable, Comparable, Sendable {
    case welcome, lookAround, vm, tune, certificate, savedPC, connect, finish

    private var position: Int { WizardStep.allCases.firstIndex(of: self) ?? 0 }

    static func < (lhs: WizardStep, rhs: WizardStep) -> Bool { lhs.position < rhs.position }
}

/// The set-up wizard's engine: which recipe checks each step is responsible for, whether a step
/// has anything left to do, and what each step's screen has to draw — all from a `Facts` value.
///
/// Pure: no I/O, no views, no `Context`. `Context` is a lazily-caching class written for one thread,
/// so the window's runner (docs/internal/specs/gui-wizard.md §3.4) owns one on its own serial queue
/// and hands the main thread a `Facts` snapshot instead. Everything a screen draws therefore has to
/// be *in* the snapshot. The spec's first `Facts` held only a status kind per check, which cannot
/// draw a single tune row (no title, no detail, no `how`) — the critique's finding 2 — so it carries
/// whole rows, and each step's screen below is derived from it and nothing else. The tests hold each
/// screen of §2.3 against a snapshot to prove it.
///
/// ## An ordering contract, not `winbar setup`'s control flow
///
/// `Setup.run` is two passes, not one list: a fix pass (`Setup.fixPass`), BitLocker's own question,
/// H7, a manual pass (`Setup.manualPass`), and the single restart (`Setup.restartPass`, then the
/// shared-folder offer and the display decision). G8 and G11 sit in both passes on purpose. A flat
/// step list cannot express that, and rewriting `Setup.run` onto this one would have changed the
/// order of the terminal conversation and dropped its only shared-folder offer. So that rewrite
/// (the spec's commit 12) is cut (COHERENCE C3), `Setup.run` stays as it is, and the two front-ends
/// agree by test instead: the window's order, restricted to either of setup's passes, is that
/// pass's order. `SetupFlowTests` holds them to it.
///
/// ## Freshness
///
/// A snapshot is a photograph. UTM can quit, restart (going headless restarts it) or be quit by the
/// person; the VM can stop; the Mac can sleep through a wait whose deadline is wall-clock time. Each
/// snapshot carries a `Stamp` saying what it was taken against, `staleness(of:…)` says whether that
/// still holds using only a process-table scan, and `landing(on:_:)` says where a window should be
/// once a fresh one arrives — never further forward, only back to an earlier step that came undone.
enum SetupFlow {

    // MARK: - What a check said

    /// A check's status, reduced to the five kinds a row is drawn by.
    enum StatusKind: String, Sendable {
        case ok, fixable, manual, info, error

        init(_ status: Status) {
            switch status {
            case .ok: self = .ok
            case .fixable: self = .fixable
            case .manual: self = .manual
            case .info: self = .info
            case .error: self = .error
            }
        }
    }

    /// One recipe row, as the window draws it: everything `Setup.offer` and `Setup.walk` print, as
    /// values. Built by the runner on its own queue from the check and the status it just
    /// evaluated, so no view ever reaches back into `Recipe` or `Context` on the main thread.
    struct Row: Equatable, Sendable {
        let id: String
        let title: String
        /// Shown as secondary text under anything that isn't ok.
        let why: String
        let kind: StatusKind
        let detail: String
        /// A manual step's instructions; nil for every other kind.
        let how: String?
        /// What a button on the row may do with the check's `apply`. A view draws **Fix** for `.fix`
        /// and for nothing else, so a row can't be given one just because its check can be applied.
        let action: Action
        /// Whether an **Open** button has a window to open (G5's Settings page, netplwiz, …).
        let canGuide: Bool
        /// The person pressed **Done** and the re-read still says manual: `Setup.walk`'s "still: …".
        var still: Bool
        /// What the last **Fix** said when it didn't work (`Setup.report`'s "✗ …"). The error stays
        /// with the row it belongs to rather than costing the whole snapshot.
        var failure: String?

        /// What pressing a row may do with its check's `apply`.
        enum Action: Equatable, Sendable {
            /// **Fix**: `apply`, then a re-read. **Fix Everything** presses it for every fixable row.
            case fix
            /// A question first, and `apply` only on its yes. G9's `apply` starts decrypting C:,
            /// which weakens encryption at rest and which nothing in Winbar turns back on, so it's
            /// asked the way `Setup.offerDecryption` asks it (`bitLockerQuestion(_:)`), and a no is
            /// kept (`Facts.keepBitLocker`). Never a Fix button, and never **Fix Everything**.
            case ask
            /// No `apply`, so nothing for a row's button to run. H1, C1 and C2 read fixable, but
            /// their steps hold their own conversations (an install, a password).
            case unavailable
        }

        /// The checks whose `apply` is only ever the answer to a question of its own. `winbar setup`
        /// keeps G9 out of both its passes for the same reason and asks it between them.
        static let asksFirst: Set<String> = ["G9"]

        init(_ check: Check, _ status: Status, still: Bool = false, failure: String? = nil) {
            id = check.id
            title = check.title
            why = check.why
            kind = StatusKind(status)
            detail = status.detail
            if case .manual(_, let how) = status { self.how = how } else { how = nil }
            if check.apply == nil {
                action = .unavailable
            } else {
                action = Row.asksFirst.contains(check.id) ? .ask : .fix
            }
            canGuide = check.guide != nil
            self.still = still
            self.failure = failure
        }
    }

    // MARK: - The snapshot

    /// UTM's list of VMs, or why there isn't one. Never an empty list standing in for a failure:
    /// "UTM has no Windows VM — Install Windows…" said to a Mac whose Apple Event is still waiting on the
    /// Automation prompt would send someone off to install a second copy of Windows.
    enum VMListing: Equatable, Sendable {
        case notAsked
        case listed([VMInfo])
        case failed(Failure)

        /// `WinbarError`, as a value that can cross to the main thread and be compared.
        struct Failure: Equatable, Sendable {
            var title: String
            var detail: String
            var automationDenied = false
            var timedOut = false

            init(title: String, detail: String = "", automationDenied: Bool = false, timedOut: Bool = false) {
                self.title = title
                self.detail = detail
                self.automationDenied = automationDenied
                self.timedOut = timedOut
            }

            init(_ error: WinbarError) {
                self.init(title: error.title, detail: error.detail, automationDenied: error.automationDenied,
                          timedOut: error.timedOut)
            }
        }

        init(_ result: Result<[VMInfo], WinbarError>) {
            switch result {
            case .success(let vms): self = .listed(vms)
            case .failure(let error): self = .failed(Failure(error))
            }
        }
    }

    /// The other VMs UTM is running, which going headless would stop (restarting UTM stops them
    /// all). An Apple Event, so asked only at the last step, never on a timer.
    enum OtherVMs: Equatable, Sendable {
        case notAsked
        /// Empty: none.
        case running([String])
        /// UTM wouldn't say. Counts as "maybe", like `Reconfigure.otherVMsRefusal`: this is what
        /// stands between a UTM restart and somebody else's VM.
        case unconfirmed(String)

        init(_ result: Result<[String], WinbarError>) {
            switch result {
            case .success(let names): self = .running(names)
            case .failure(let error): self = .unconfirmed(error.detail.isEmpty ? error.title : error.detail)
            }
        }
    }

    /// Where the VM's disk is kept, and whether each place is encrypted at rest: what BitLocker's
    /// question (G9) turns on. `Host.encryptedAtRest` shells out to `fdesetup` and `diskutil`, so
    /// the runner asks and the window reads the answer.
    struct Disk: Equatable, Sendable {
        struct Place: Equatable, Sendable {
            var storage: Host.Storage
            /// nil when macOS wouldn't say, which counts as not encrypted, as it does in
            /// `Setup.offerDecryption`: the question must never make decrypting sound safer than it is.
            var encrypted: Bool?
        }

        /// Whether the disk images were seen in the running QEMU's arguments. When they weren't,
        /// `places` is UTM's default — the startup disk — and the question says it is a guess.
        var imagesSeen: Bool
        /// Never empty: the runner puts the startup disk here when it couldn't see the images.
        var places: [Place]
    }

    /// The rows `winbar create`'s checklist was left unticked for, as `Context` reads them.
    struct Declined: Equatable, Sendable {
        var autologon = false
        var remoteDesktop = false
        var tuning = false

        /// The `winbar config` switch that turns `id`'s row back on, or nil when it wasn't declined.
        /// `winbar setup`'s own rule, not a copy of it.
        func switchFor(_ id: String) -> String? {
            Setup.declinedSwitch(id, autologon: autologon, remoteDesktop: remoteDesktop, tuning: tuning)
        }
    }

    /// What this run of the window has been told, or has done, that no machine can check
    /// afterwards. Kept in memory only (§2.4): after a relaunch the wizard asks again, which is
    /// also what `winbar setup` does on every run. The runner never writes these; the window does,
    /// and puts them back into each snapshot it receives.
    struct Answers: Equatable, Sendable {
        /// A confirmation and a skip describe one VM, even across a closed window or a failed list.
        var vmID: String?
        func forVM(_ id: String?) -> Answers {
            var result = self
            if let vmID, vmID != id { result = Answers(); result.started = started }
            result.vmID = id
            return result
        }
        /// **Start** was pressed on the welcome screen.
        var started = false
        /// Rows the person said "not now" to in this run: `winbar setup`'s `n` to "Fix it?" and `s`
        /// at a manual step; the window's **Skip** on Windows App (C1) or the saved PC (C2), and
        /// **Keep the Screen** (H5).
        /// A row left alone counts as settled for its step, or the window would hold someone on a
        /// row they have every right to refuse (a bridged network, their animations, Time Machine).
        /// G0 never does: nothing else in Windows can be read without it. BitLocker's **No** is not
        /// here but in `Facts.keepBitLocker`, because setup remembers that one across runs.
        var leftAlone: Set<String> = []
        /// Winbar pressed the saved PC's tile (or opened a one-off connection) in this run.
        var connectionOpened = false
        /// The person's answer to "Did the Windows desktop appear?". Nothing can check this.
        var connected: Bool?
        /// **Connect**, or its **Try Again**, was pressed in this run. From then on a read may probe the
        /// Remote Desktop port (`SetupRunner.ReadPlan.readiness`): the Connect card has predicted the
        /// Local Network prompt that probe can raise, and Connect's own wait for Windows probes the
        /// same port. Set with the press rather than when the connection opens, because the reads the
        /// recovery card needs are the one after a Connect that failed and the one after **No** — and
        /// keyed on `connectionOpened` alone, neither probed, so the card said readiness "hasn't been
        /// checked" while the port was answering.
        var connectPressed = false
    }

    /// What a snapshot was taken against: when, which UTM and which QEMU. The two processes are
    /// read from the process table in a moment, so the runner can tell a stale snapshot from a fresh
    /// one without the Apple Event that taking a new one costs.
    struct Stamp: Equatable, Sendable {
        var taken: Date
        /// UTM's process ids (empty: UTM wasn't running). A different set means UTM quit, was
        /// quit, restarted — going headless restarts it — or was started underneath the window.
        var utmPIDs: Set<Int32>
        /// The chosen VM's QEMU process, nil when it wasn't running.
        var vmPID: Int32?
    }

    /// A snapshot of everything a step decision or a screen needs, taken on the setup queue and
    /// handed to the main thread as a value. Nothing here is a reference to `Context`.
    ///
    /// The defaults are "nothing known, nothing done", so `Facts()` is a Mac the wizard has not
    /// looked at yet, and every step is unsatisfied.
    struct Facts: Equatable, Sendable {
        // Step 1 — look around.
        var utm: DependencyState = .missing
        /// Homebrew's path, which decides how UTM would be installed (brew or UTM's own download).
        var homebrew: String?
        /// Homebrew installed this UTM (`Homebrew.hasCask`), so it can update a copy that's too old.
        var utmFromHomebrew = false
        /// nil until utmctl has been asked. H9.
        var utmAnswers: UTM.CtlAnswer?
        /// Only read when utmctl hasn't answered: which of the two silences it is, for
        /// `UTMFirstUse.how(consent:quarantined:)`. Asking costs an Apple Event, so it isn't
        /// asked of a utmctl that answers — the same economy as H9's own evaluation.
        var utmConsent: Automation.Consent = .decided
        /// UTM carries macOS's "downloaded from the internet" mark. Read whenever UTM is installed — it
        /// is a getxattr, not an Apple Event — because step 1 predicts the question it can raise before
        /// **Open UTM and Ask**, as well as explaining it once utmctl has gone quiet.
        var utmQuarantined = false
        var windowsApp: DependencyState = .missing

        // Step 2 — the VM.
        var vms: VMListing = .notAsked
        var chosenVM: String?
        var chosenID: String?
        var target: String? { chosenID ?? chosen?.id ?? chosenVM.map { "name:" + $0 } }
        /// From the process table: live, unlike the status in the VM list.
        var vmRunning = false
        /// Whether the guest agent answered when the snapshot was taken. The runner reads it to
        /// know whether the survey has to wait for Windows first (`Setup.waitForWindows`); no screen
        /// needs it, because G0's row says what a silent agent means.
        var guestAnswers = false
        /// `winbar create` is installing Windows. One install at a time, and the VM being made
        /// isn't the chosen one until the install's last stage selects it — so while it runs, the
        /// VM step isn't done, whatever VM was chosen before.
        var installRunning = false

        // Every step's recipe rows, by check id, whichever step shows them (look-around draws C1's
        // row long before step 5 acts on it). A check the runner hasn't read yet is absent, and
        // absent is never "fine".
        var rows: [String: Row] = [:]
        var declined = Declined()
        /// `--keep-bitlocker`, or a **No** to BitLocker's question in this run or an earlier one.
        var keepBitLocker = false
        /// nil until the runner has looked, which it does whenever G9 is fixable.
        var disk: Disk?

        // Steps 4 to 6.
        var rdpHost: String?
        var rdpUser: String?
        var windowsAppRunning = false
        /// The Remote Desktop port's answer, for the "it didn't work" screen.
        var readiness: RDP.Readiness?
        /// The host whose saved-PC tile this window's last Connect pressed; nil after a one-off
        /// connection, or before any. Paired with the person's answer to "Did the Windows desktop
        /// appear?", it's evidence of a saved PC that Windows App's command line may never give
        /// (`Recipe.connectedSavedPC`).
        var savedPCPressed: String?

        // Step 7.
        /// vCPUs and memory staged in step 3, and headless if chosen: applied with one restart.
        var pending = ConfigChanges()
        var otherVMs: OtherVMs = .notAsked
        /// An earlier display change left UTM owing a restart (`Config.pendingUTMRestart`): the next
        /// start restarts UTM first, which a finish step coming back from sleep has to say.
        var utmRestartOwed = false

        var answers = Answers()
        /// nil for a value the runner didn't take (a test's, or the window's before the first).
        var stamp: Stamp?

        func kind(_ id: String) -> StatusKind? { rows[id]?.kind }

        /// The chosen VM as UTM listed it, when it did.
        var chosen: VMInfo? {
            guard let chosenVM, case .listed(let list) = vms else { return nil }
            return list.first { $0.name == chosenVM && (chosenID == nil || chosenID == $0.id) }
        }
    }

    // MARK: - Which checks belong to which step

    /// Which recipe checks a step is responsible for, in the order it works through them. The whole
    /// ordering contract between the window and `winbar setup`.
    ///
    /// Two places differ from the spec's table (gui-wizard.md §3.3), both on purpose, and one is
    /// where the table put it but for reasons worth writing down:
    /// - **C1 is the saved-PC step's, not look-around's.** Look-around shows Windows App's row but
    ///   does nothing about it (§2.3: "Winbar gets to that at the saved-PC step"), and step 5 is
    ///   where it gets installed. This is also where `Setup.manualPass` has it: right before C2,
    ///   which has nowhere to save a PC until Windows App is there.
    /// - **H6 before H8**, as both `Setup.manualPass` and the recipe have them. The table's H8, H6
    ///   contradicted its own "everything else keeps its place".
    /// - **G9, in tune right after G8.** `Setup.run` asks it between its two passes
    ///   (`offerDecryption`), in neither list, which is where "after G8, before H7" comes from. It
    ///   keeps its own question here too: **Fix Everything** never answers it (`fixEverything(_:)`).
    ///
    /// H9 moves to the front, as the spec says: a silent utmctl is the reason every row below it
    /// fails, and it's exactly the state a Mac is in right after UTM is installed. G11 belongs to no
    /// step (`unplaced`). C4 belongs to connect, which `winbar setup` never walks; it is `.info`
    /// whenever the login item is off, so it can never hold the step up.
    static func checks(in step: WizardStep) -> [String] {
        switch step {
        case .welcome: return []
        case .lookAround: return ["H1", "H9"]
        case .vm: return ["H2"]
        // G0 before G5 before G6: Windows has to answer before anything in it can change, and
        // Remote Desktop's protections would lock out an account with no password. The fixes keep
        // `Setup.fixPass`'s order. H3 and H4 last: they're only staged here, for the restart.
        case .tune: return ["G0", "G5", "G1", "G2", "G3", "G4", "G6", "G7", "G8", "G9", "G10", "H6", "H8", "H3", "H4"]
        // After tune, because there's no certificate to trust before G7 makes one.
        case .certificate: return ["H7"]
        case .savedPC: return ["C1", "C2"]
        case .connect: return ["C3", "C4"]
        case .finish: return ["H5"]
        }
    }

    /// Recipe checks no step is responsible for, deliberately. Only G11, the shared folder: it costs
    /// an extra restart and UTM's two-starts explanation, and it isn't on the path to a working
    /// Connect (§1). `winbar setup` keeps it — in both of its passes, and as the offer that stages a
    /// folder into its single restart (`Setup.offerSharedFolder`), which is `winbar setup`'s only
    /// one. That offer surviving is why `Setup.run` isn't rewritten onto this engine (COHERENCE C3).
    static let unplaced: Set<String> = ["G11"]

    /// Every placed check, in the order the window meets them.
    static var order: [String] { WizardStep.allCases.flatMap(checks(in:)) }

    // MARK: - Is a step done?

    /// Whether a step has nothing left to do. Pure.
    static func isSatisfied(_ step: WizardStep, _ facts: Facts) -> Bool {
        switch step {
        case .welcome:
            return facts.answers.started
        case .lookAround:
            if case .done = lookAround(facts) { return true }
            return false
        case .vm:
            if case .ready = vm(facts) { return true }
            return false
        case .tune:
            return checks(in: .tune).allSatisfy { settled($0, facts) }
        case .certificate:
            return facts.kind("H7") == .ok || facts.answers.leftAlone.contains("H7")
        case .savedPC:
            switch savedPC(facts) {
            case .saved, .skipped: return true
            default: return false
            }
        case .connect:
            // A skipped Windows App settles it too: nothing on this step can connect without one,
            // so holding it would leave the person on a screen with nothing to press.
            switch connect(facts) {
            case .worked, .didNotWork, .windowsAppSkipped: return true
            default: return false
            }
        case .finish:
            return facts.pending.isEmpty && !finish(facts).headless.isOutstanding
        }
    }

    /// The first step from `step` onwards that isn't satisfied, or nil when there is none. Pure.
    static func next(from step: WizardStep, _ facts: Facts) -> WizardStep? {
        WizardStep.allCases.filter { $0 >= step }.first { !isSatisfied($0, facts) }
    }

    /// Where a window showing `current` belongs once `facts` arrive: `current`, unless a step before
    /// it has come undone — UTM quit, the VM stopped, a row went back to fixable — and then the first
    /// such step. Never forward: moving on is the person's press, not a snapshot's, or a fresh
    /// snapshot could carry someone past a screen they were still reading. Pure.
    static func landing(on current: WizardStep, _ facts: Facts) -> WizardStep {
        guard let first = next(from: .welcome, facts), first < current else { return current }
        return first
    }

    /// Whether a tune row has nothing left to do: fine, or informational, or shown-not-actioned, or
    /// the person's choice (declined in create's checklist, left alone in this run), or its change
    /// already staged for the restart.
    private static func settled(_ id: String, _ facts: Facts) -> Bool {
        guard let row = facts.rows[id] else { return false }
        // Windows answering at all is the one thing no choice can stand in for: without G0 every
        // other guest row reads "not checked (G0)", which is `.info` and would pass.
        if id == "G0" { return row.kind == .ok }
        if facts.answers.leftAlone.contains(id) || facts.declined.switchFor(id) != nil { return true }
        switch row.kind {
        // Errors are shown, not actioned (§2.3): nothing here can fix them, and holding the step
        // on one would leave the person nothing to press.
        case .ok, .info, .error: return true
        case .manual: return false
        case .fixable:
            switch id {
            case "G9": return facts.keepBitLocker
            case "H3": return facts.pending.cpuCores != nil
            case "H4": return facts.pending.memoryMB != nil
            default: return false
            }
        }
    }

    // MARK: - Freshness

    /// Why a snapshot no longer describes this Mac.
    enum Staleness: Equatable, Sendable {
        /// The runner never took it.
        case neverTaken
        /// The Mac slept since. Every wait in the flow runs against wall-clock time, so a closed lid
        /// doesn't pause a deadline, it spends it; nothing read before the sleep can be trusted.
        case slept
        /// UTM quit, restarted or started underneath the window.
        case utmChanged
        /// The chosen VM stopped, started or was restarted.
        case vmChanged
        // Not Winbar coming back to the front: that made every page read itself again whenever it was
        // looked at (`SetupRunner.init`). A step waiting on another app looks again, quietly, a moment
        // after its window becomes key (`SetupJourneyActions.returnRead`), and marks nothing stale.
    }

    /// Whether `facts` still describe this Mac, from what a process-table scan says now and when the
    /// Mac last woke (`NSWorkspace.didWakeNotification`). nil while they do. Pure: the runner passes the observations in, so the rule can be checked without
    /// UTM.
    ///
    /// The most serious reason wins: a sleep puts every wall-clock wait in doubt, and a process change
    /// says what moved.
    static func staleness(of facts: Facts, utmPIDs: Set<Int32>, vmPID: Int32?, lastWake: Date?) -> Staleness? {
        guard let stamp = facts.stamp else { return .neverTaken }
        if let lastWake, lastWake > stamp.taken { return .slept }
        if utmPIDs != stamp.utmPIDs { return .utmChanged }
        if vmPID != stamp.vmPID { return .vmChanged }
        return nil
    }

    // MARK: - The screens, step by step (§2.3)

    /// Step 1. The three rows read H1, the VM list and C1 (all in `Facts`); this says which body
    /// goes under them.
    enum LookAroundScreen: Equatable, Sendable {
        /// Missing, too old or not the real thing: `DependencyCopy.situation(.utm, state:)`, the plan
        /// from `state` and `Facts.homebrew`, and the question as a button.
        case needsUTM(DependencyState)
        /// Installed and never asked: `[Open UTM and Ask]`, after `SetupCopy.LookAround.askHeading`.
        case askUTM
        /// utmctl said nothing: the window's own advice for the consent (`SetupCopy.LookAround.silent`),
        /// with **Try Again**; the terminal's is `UTMFirstUse.how(consent:quarantined:)`.
        case utmSilent(seconds: Int, consent: Automation.Consent, quarantined: Bool)
        /// Automation was refused: `Automation.deniedError()` says where to turn it back on.
        case utmDenied
        /// utmctl answered with a failure of its own.
        case utmFailed(String)
        /// utmctl answers; the VM list is still to be asked for.
        case listVMs
        case listFailed(VMListing.Failure)
        /// Nothing left here. Windows App's state decides whether the row adds that it isn't installed
        /// (`SetupCopy.LookAround.windowsAppLater(lastBuilt:)`).
        case done(windowsApp: DependencyState)
    }

    static func lookAround(_ facts: Facts) -> LookAroundScreen {
        guard facts.utm.isInstalled else { return .needsUTM(facts.utm) }
        switch facts.utmAnswers {
        case nil: return .askUTM
        case .silent(let seconds)?: return .utmSilent(seconds: seconds, consent: facts.utmConsent,
                                                      quarantined: facts.utmQuarantined)
        case .denied?: return .utmDenied
        // Every start and stop is a utmctl call, so a utmctl that fails leaves nothing below working.
        case .failed(let detail)?: return .utmFailed(detail)
        case .answered?: break
        }
        switch facts.vms {
        case .notAsked: return .listVMs
        case .failed(let failure): return .listFailed(failure)
        case .listed: return .done(windowsApp: facts.windowsApp)
        }
    }

    /// Step 2.
    enum VMScreen: Equatable, Sendable {
        /// The VM list isn't in hand. Step 1's to fix; `landing` never leaves a window here.
        case unlisted
        /// The embedded create views, showing the install that's running.
        case installing
        /// Nothing usable is chosen: make one, adopt one, or pick one. `previous` says why an
        /// earlier choice no longer counts.
        case choose(VMChoice, previous: PreviousChoice?)
        /// Chosen and stopped: "“Windows 11” is stopped…" `[Start It]`.
        case stopped(VMInfo)
        /// Chosen and running. Nothing left here.
        case ready(VMInfo)
    }

    enum VMChoice: Equatable, Sendable {
        /// "No Windows VM yet" `[Install Windows…]`.
        case none
        /// "One Windows VM" `[Install Windows in a New VM…]` `[Use “…”]`.
        case one(VMInfo)
        /// "Which VM?", every QEMU VM, in the order the menu's **Choose VM** lists them
        /// (`VMInfo.choosable`).
        case several([VMInfo])
    }

    enum PreviousChoice: Equatable, Sendable {
        /// Deleted or renamed in UTM since it was chosen: "UTM no longer has a VM named …".
        case gone(String)
        /// An Apple Virtualization VM, which Winbar can't manage (H2).
        case notQEMU(String)
    }

    static func vm(_ facts: Facts) -> VMScreen {
        guard case .listed(let list) = facts.vms else { return .unlisted }
        if facts.installRunning { return .installing }
        var previous: PreviousChoice?
        if let name = facts.chosenVM {
            if let chosen = facts.chosen {
                if chosen.backend == "qemu" { return facts.vmRunning ? .ready(chosen) : .stopped(chosen) }
                previous = .notQEMU(name)
            } else {
                previous = .gone(name)
            }
        }
        return .choose(choice(in: list), previous: previous)
    }

    /// Zero, one or several, by `winbar setup`'s own rule (`Context.candidates(in:)`: the Windows
    /// QEMU VMs, or every QEMU VM when none says it's Windows — a hand-made VM can have UTM's
    /// generic icon), so both front-ends adopt the same VM without asking. Several shows every QEMU
    /// VM, Debian included, as the spec's own example does. Pure.
    static func choice(in list: [VMInfo]) -> VMChoice {
        let candidates = Context.candidates(in: list)
        switch candidates.count {
        case 0: return .none
        case 1: return .one(candidates[0])
        default: return .several(VMInfo.choosable(list))
        }
    }

    /// Step 3.
    struct TuneScreen: Equatable, Sendable {
        /// The step's rows in `checks(in: .tune)` order, for every check the runner has read.
        var rows: [Row]
        /// The step's checks not read yet. Any at all means the survey still has to run ("Asking
        /// Windows (this takes a few seconds)…").
        var unread: [String]
        /// What **Fix Everything** applies, in order. Absent when there's nothing to fix.
        var fixEverything: [String]
        /// BitLocker's own question, when it's being asked.
        var bitLocker: BitLockerQuestion?
        /// Rows create's checklist left unticked, with the switch that turns each back on: said,
        /// then left alone, as `Setup.reportDeclined` does.
        var declined: [String: String]
        /// H3 and H4 rows whose change is staged: "Applied at the end, with one restart of …".
        var staged: [String]
    }

    static func tune(_ facts: Facts) -> TuneScreen {
        let ids = checks(in: .tune)
        var declined: [String: String] = [:]
        for id in ids { if let option = facts.declined.switchFor(id) { declined[id] = option } }
        var staged: [String] = []
        if facts.pending.cpuCores != nil { staged.append("H3") }
        if facts.pending.memoryMB != nil { staged.append("H4") }
        return TuneScreen(rows: ids.compactMap { facts.rows[$0] },
                          unread: ids.filter { facts.rows[$0] == nil },
                          fixEverything: fixEverything(facts),
                          bitLocker: bitLockerQuestion(facts),
                          declined: declined,
                          staged: staged)
    }

    /// Every fixable tune row whose button is **Fix**, in order, apart from the ones the person
    /// owns: never a manual row, never a declined or left-alone one, nothing already staged — and
    /// never a row that asks (`Row.Action.ask`), which is G9. A button called Fix Everything must
    /// not weaken encryption at rest; `--yes` doesn't answer BitLocker either. Read from the row's
    /// action rather than its id, so this button and a row's own Fix can't disagree.
    static func fixEverything(_ facts: Facts) -> [String] {
        checks(in: .tune).filter { id in
            guard let row = facts.rows[id], row.kind == .fixable, row.action == .fix else { return false }
            return !settled(id, facts)
        }
    }

    /// BitLocker's question, in `Setup.offerDecryption`'s two branches.
    enum BitLockerQuestion: Equatable, Sendable {
        /// Every place the VM's disk is kept is encrypted at rest, so decrypting C: costs nothing at
        /// rest. `guessed`: the images weren't seen, and the startup disk is UTM's default — "if
        /// this VM is stored somewhere else, such as an external drive… answer no".
        case encryptedAtRest(places: [Host.Storage], guessed: Bool)
        /// Some place isn't (or macOS wouldn't say), so decrypting C: would leave the VM's disk
        /// unencrypted there. Asked, defaulting to no.
        case unencrypted(places: [Host.Storage])

        /// What Return answers, as in `Setup.offerDecryption`: "Decrypt C:?" defaults to yes when
        /// every place is encrypted at rest, "Decrypt C: anyway?" to no. The window's default button
        /// follows this, or Return would decrypt a disk kept somewhere that isn't encrypted.
        var decryptsByDefault: Bool {
            if case .encryptedAtRest = self { return true }
            return false
        }
    }

    /// nil when G9 isn't being asked: it isn't fixable, BitLocker is kept, or the person left it —
    /// or the runner hasn't looked at the disk yet, which it does whenever G9 is fixable. Pure.
    static func bitLockerQuestion(_ facts: Facts) -> BitLockerQuestion? {
        guard facts.kind("G9") == .fixable, !facts.keepBitLocker, !facts.answers.leftAlone.contains("G9"),
              let disk = facts.disk, !disk.places.isEmpty else { return nil }
        let unprotected = disk.places.filter { $0.encrypted != true }.map(\.storage)
        guard unprotected.isEmpty else { return .unencrypted(places: unprotected) }
        return .encryptedAtRest(places: disk.places.map(\.storage), guessed: !disk.imagesSeen)
    }

    /// Step 4.
    enum CertificateScreen: Equatable, Sendable {
        /// "✓ Trusted for …", H7's own ok.
        case trusted(host: String)
        /// "Trusting the VM's certificate…" `[Trust It]`, with the approval predicted first.
        case trust(host: String)
        /// "Windows hasn't got a Remote Desktop certificate for this name yet. That's step 3's G7".
        case needsCertificate(host: String)
        /// Nothing to trust or send the person back for: H7's row says why (no host name yet,
        /// Windows didn't report the certificate, not read yet).
        case notYet(Row?)
    }

    static func certificate(_ facts: Facts) -> CertificateScreen {
        let h7 = facts.rows["H7"]
        if let host = facts.rdpHost {
            if h7?.kind == .ok { return .trusted(host: host) }
            if h7?.kind == .fixable { return .trust(host: host) }
            // Only once Windows was actually read: G7's "not checked (G0)" is no reason to send
            // anyone back to make a certificate.
            if facts.kind("G0") == .ok, let g7 = facts.kind("G7"), g7 != .ok { return .needsCertificate(host: host) }
        }
        return .notYet(h7)
    }

    /// Step 5.
    enum SavedPCScreen: Equatable, Sendable {
        /// Windows App isn't usable: the dependency conversation, for `.windowsApp`.
        case needsWindowsApp(DependencyState)
        /// `WindowsAppBookmarks.Copy.quitFirst` `[Quit Windows App]` `[Check Again]`.
        case windowsAppOpen(host: String)
        /// "Saving the PC in Windows App…" with the password field for `user`.
        case save(host: String, user: String)
        case saved(Row)
        /// C2 is manual for a reason saving can't fix (Windows App wouldn't say what it has).
        case manual(Row)
        /// **Skip**: the person will add it themselves, or not. After the saved PC's Skip, step 6
        /// falls back to a one-off connection; after Windows App's, step 6 says it was skipped.
        case skipped
        /// C2 can't be answered yet (no host name, no user, not read).
        case notYet(Row?)
    }

    static func savedPC(_ facts: Facts) -> SavedPCScreen {
        let c2 = facts.rows["C2"]
        let leftAlone = facts.answers.leftAlone
        // Skipping the saved PC doesn't skip Windows App, which step 6 still needs. If the app is
        // gone (uninstalled since that Skip), this is where it's installed or skipped again —
        // otherwise the step would pass, and step 6 would ask for an app nobody is offering.
        //
        // This comes BEFORE `.saved`, not after. C2 can read `.ok` with the app missing or signed by
        // someone else: when Windows App won't answer, C2 falls back to the host Winbar was told
        // (`Config.savedPCHost`). Letting that `.ok` win first passed this step and stranded the
        // person on connect, showing `.needsWindowsApp` with nothing to press and no Skip anywhere.
        guard facts.windowsApp.isInstalled || leftAlone.contains("C1") else {
            return .needsWindowsApp(facts.windowsApp)
        }
        if let c2, c2.kind == .ok { return .saved(c2) }
        if leftAlone.contains("C2") || leftAlone.contains("C1") { return .skipped }
        guard let c2, let host = facts.rdpHost else { return .notYet(c2) }
        switch c2.kind {
        case .fixable, .manual:
            // Live, not C2's word: the app can be opened or quit between two reads, and a save while
            // it's open is the one thing never worth risking. Not when its command line has stopped
            // answering, though: nothing can be saved then anyway, quitting doesn't bring it back, and
            // the card's **Open Windows App** is how the person saves the PC themselves.
            if facts.windowsAppRunning, !commandLineSilent(facts) { return .windowsAppOpen(host: host) }
            guard c2.kind == .fixable else { return .manual(c2) }
            guard let user = facts.rdpUser else { return .notYet(c2) }
            return .save(host: host, user: user)
        case .ok, .info, .error:
            return .notYet(c2)
        }
    }

    /// C2 couldn't be answered because Windows App's command line didn't respond: the read ran out of
    /// time, or an earlier one did and Winbar stopped asking (`WindowsAppBookmarks.ReadGate`). A
    /// Windows App problem, not the person's: Windows App 11.4.2's `--script bookmark list` was seen
    /// hanging before it read anything, three times out of three. The saved PC's card says so in
    /// those words rather than the terminal's (`SetupCopy.SavedPC.silent`). Pure.
    static func commandLineSilent(_ facts: Facts) -> Bool {
        guard let c2 = facts.rows["C2"], c2.kind == .manual else { return false }
        return WindowsAppBookmarks.Copy.saysNoAnswer(c2.detail)
    }

    /// Step 6.
    enum ConnectScreen: Equatable, Sendable {
        /// Windows App went missing after step 5. Not a place to stay: step 5 comes undone with it
        /// (`savedPC(_:)`), so `landing` takes the window back there to install it or skip it.
        case needsWindowsApp
        /// Windows App was skipped at step 5, so there is nothing to connect with and nothing here
        /// to press: said, and settled, so the person can carry on to the finish. The Skip is kept
        /// in memory only (`Answers`), so after a relaunch the wizard offers Windows App again.
        case windowsAppSkipped
        /// "Connecting for the first time…", predicting Accessibility and Local Network.
        /// `[Allow Accessibility]`.
        case allowAccessibility
        /// `[Connect]`. `savedPC` false: a one-off connection, where Windows App asks for the password.
        case ready(host: String, savedPC: Bool)
        /// "Did the Windows desktop appear?" `[No, something's wrong]` `[Yes]`.
        case didItWork(host: String)
        /// **No**: what Winbar knows, with **Try Again** and **Skip**.
        case didNotWork(Diagnosis)
        case worked
        /// Not read yet: no host name, or the Accessibility self-test hasn't run.
        case notYet
    }

    /// What the "it didn't work" screen shows: the port, the host, the user, whether there's a
    /// saved PC, and what is known about the VM's own screen.
    struct Diagnosis: Equatable, Sendable {
        var readiness: RDP.Readiness?
        var host: String?
        var user: String?
        var savedPC: Bool
        var console: Console
    }

    /// The VM's own screen, as H5's last reading has it, for the recovery card's advice on watching
    /// Windows start. Only the finish step reads H5 (`checks(in:)`), so someone who reaches Connect
    /// without having been to Finish in this session has no reading: a VM made headless by `winbar
    /// setup` or **Run in the Background…**, going through **Set Up Winbar…** again, is exactly that. The card
    /// must not guess a UTM window for them, nor a missing one for everyone else.
    enum Console: Equatable, Sendable {
        /// H5 ok: no display device, so only **Bring Back Windows' Screen…** shows what Windows is doing.
        case headless
        /// H5 fixable: the console is on, so UTM has a window for the VM.
        case onScreen
        /// Not read, or read as info. Info is "unknown", or a console that isn't offered headless yet;
        /// the row's detail would tell those apart, but only as prose, and the neutral advice is true
        /// of both.
        case unknown
    }

    static func console(_ facts: Facts) -> Console {
        switch facts.kind("H5") {
        case .ok?: return .headless
        case .fixable?: return .onScreen
        default: return .unknown
        }
    }

    static func connect(_ facts: Facts) -> ConnectScreen {
        switch facts.answers.connected {
        case true?: return .worked
        case false?:
            return .didNotWork(Diagnosis(readiness: facts.readiness, host: facts.rdpHost, user: facts.rdpUser,
                                         savedPC: facts.kind("C2") == .ok, console: console(facts)))
        case nil: break
        }
        guard facts.windowsApp.isInstalled else {
            return windowsAppSkipped(facts) ? .windowsAppSkipped : .needsWindowsApp
        }
        guard let host = facts.rdpHost, let c3 = facts.kind("C3") else { return .notYet }
        if facts.answers.connectionOpened { return .didItWork(host: host) }
        if c3 == .manual, !facts.answers.leftAlone.contains("C3") { return .allowAccessibility }
        return .ready(host: host, savedPC: facts.kind("C2") == .ok)
    }

    /// The person pressed **Skip** on Windows App at step 5 and it still isn't there. One rule for
    /// steps 6 and 7, so they can't disagree about whether Connect was ever possible.
    static func windowsAppSkipped(_ facts: Facts) -> Bool {
        !facts.windowsApp.isInstalled && facts.answers.leftAlone.contains("C1")
    }

    /// The Skips that taking a step back up undoes (`SetupCommand.revisit`): the certificate's, and the
    /// saved PC's together with Windows App's, since a skipped Windows App leaves the saved PC with
    /// nowhere to go and the step then shows Windows App's install first. Empty for every other step:
    /// Tune's Skips belong to its rows, each with its own button back. Pure.
    ///
    /// A Skip was a dead end. Live, Windows App's command line never answered, the person chose to go
    /// on, and "Saved PC skipped" then had nothing on it to press, although a second try might answer.
    static func skips(in step: WizardStep) -> Set<String> {
        switch step {
        case .certificate: return ["H7"]
        case .savedPC: return ["C1", "C2"]
        default: return []
        }
    }

    /// Step 7.
    struct FinishScreen: Equatable, Sendable {
        var vm: String?
        /// What the one restart applies; `ConfigChanges.summary` is the sentence. Empty: no restart.
        var restart: ConfigChanges
        var headless: HeadlessOffer
        /// UTM still owes a restart from an earlier display change; the VM starts only after it.
        var utmRestartOwed: Bool
    }

    /// Whether, and how, step 7 offers to take the screen away.
    ///
    /// With other VMs running, the window *refuses* rather than offers. The spec named them and
    /// offered the button anyway, but `Reconfigure.apply` refuses any display change while another
    /// VM runs, so the offer would end the wizard's last step on a refusal (COHERENCE C2). And a UTM
    /// that won't say is treated as "maybe", like the real guard.
    enum HeadlessOffer: Equatable, Sendable {
        case alreadyHeadless
        /// **Run in the Background** was pressed: it's in `pending`, waiting for the restart.
        case staged
        /// **Keep the Screen**.
        case kept
        /// The person said **No** to "Did the Windows desktop appear?": "Winbar isn't offering to
        /// remove the VM's screen, because Remote Desktop hasn't worked yet."
        case notOffered
        /// Nobody has said yet whether Remote Desktop worked; step 6 asks that first.
        case waitingForConnect
        /// Windows App was skipped, so Remote Desktop was never tried and nothing in this run will
        /// try it. Not offered, for `notOffered`'s reason, and nothing to wait for either.
        case connectSkipped
        /// H5 isn't offering it: G5, G6 or H7 isn't right, or the display state is unknown.
        case notReady
        /// H5 hasn't been read.
        case notChecked
        /// Which other VMs are running is still to be asked (an Apple Event, so only here).
        case checkOtherVMs
        case otherVMsRunning([String])
        case couldNotConfirm(String)
        /// "Run it without a screen?" `[Keep the Screen]` `[Run in the Background]`.
        case offer

        /// Something still has to happen before the step is done: a question to ask UTM, a row to
        /// read, or the person's answer.
        var isOutstanding: Bool {
            switch self {
            case .notChecked, .waitingForConnect, .checkOtherVMs, .offer: return true
            default: return false
            }
        }
    }

    static func finish(_ facts: Facts) -> FinishScreen {
        FinishScreen(vm: facts.chosenVM, restart: facts.pending, headless: headlessOffer(facts),
                     utmRestartOwed: facts.utmRestartOwed)
    }

    static func headlessOffer(_ facts: Facts) -> HeadlessOffer {
        if facts.kind("H5") == .ok { return .alreadyHeadless }
        if facts.answers.leftAlone.contains("H5") { return .kept }
        // Only a person who has just watched Remote Desktop work is offered a VM that has nothing
        // else: a headless VM with no working Remote Desktop has no way in.
        guard let connected = facts.answers.connected else {
            return windowsAppSkipped(facts) ? .connectSkipped : .waitingForConnect
        }
        guard connected else { return .notOffered }
        guard let h5 = facts.kind("H5") else { return .notChecked }
        guard h5 == .fixable else { return .notReady }
        switch facts.otherVMs {
        case .notAsked: return .checkOtherVMs
        case .unconfirmed(let detail): return .couldNotConfirm(detail)
        case .running(let names) where !names.isEmpty: return .otherVMsRunning(names)
        case .running: return facts.pending.display == .headless ? .staged : .offer
        }
    }
}
