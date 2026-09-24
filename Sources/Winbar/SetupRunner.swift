import AppKit
import Foundation

/// The set-up window's worker: the one place its `Context` lives, the typed work the window can ask
/// for, and the `SetupFlow.Facts` snapshots it hands back (gui-wizard.md §3.4). No window uses it
/// yet; this is the machinery the steps are built on, and the rules they get for free.
///
/// ## One queue, one Context
///
/// `Context` is a lazily-caching class with plain stored properties and no lock, written for a
/// single-threaded CLI run, and a window is the first caller that could reach it from two places at
/// once. So the runner's machine (`LiveSetupMachine`) owns the only one, on the named serial queue
/// `net.elusive.winbar.setup`, and nothing else touches it. Every blocking thing — an Apple Event,
/// the guest survey, the self-test, `codesign`, Homebrew — runs there. The main thread only ever
/// receives values: `Facts`, `InFlight`, `Ending`.
///
/// ## One piece of work at a time, and never a bare "busy"
///
/// A second request while one is in flight is refused, not queued. A queued **Fix** behind a
/// five-minute wait would run against facts nobody had looked at since it was pressed. The refusal
/// (`Refusal`) names the work in flight, and what it is waiting for when that's a person in another
/// app's window (`SetupCopy.Working.refusal`). A read somebody pressed (**Check Again**) is a request
/// like any other, and is refused the same way. A read nobody pressed never refuses and is never
/// refused in words: the runner's own after a wake is taken once the queue is free
/// (`retakeIfWatched`); the window's look (`lookAgain`) is declined while anything runs, and the
/// window owes it until nothing does (`SetupWindowController.readByItself`); and a look or a read the
/// window owes itself that the app's gate turned away is taken on the menu's next tick
/// (`readWhenFree`).
///
/// ## Sleep (critique §3, first part)
///
/// Long work — installing UTM, the tune fixes, the survey and the wait for Windows after a start,
/// and above all step 7's restart through `Reconfigure.apply`, which is a graceful shutdown, a UTM
/// quit, a configuration write, a verify and a start — holds the power assertion `CreateJob` takes
/// (`SleepAssertion`: idle sleep and sudden termination disabled) for exactly the duration of the
/// work, reads either side of it included, and lets it go on every way out: success, a failure, a
/// throw, a stop. `Work.holdsMacAwake` says which. A read that can survey Windows is long too, and
/// holds it by itself when no such work does (`readHoldsMacAwake(through:)`). Every wait in those paths is wall-clock time, so a lid closed anyway spends deadlines
/// rather than pausing them: an ending says the Mac slept during it (`Ending.slept`), and a window
/// coming back to step 7 is told where the restart stands (`RestartReport`) — including a VM that's
/// off with a UTM restart still owed — as a state, not a surprise.
///
/// ## Stale facts (critique §3, second part)
///
/// A snapshot is a photograph. It goes stale when the Mac wakes (`NSWorkspace.didWakeNotification`),
/// and when UTM's processes or the VM's come or go — which the menu's own five-second refresh already scans for, so
/// it calls `processTableTick()` rather than the runner keeping a second timer. Whoever holds a
/// snapshot can ask `staleness(of:)`; observers are told `.stale` the moment it happens, and a fresh
/// snapshot follows (`.refreshed`) once the queue is free. With no window attached nothing is read:
/// the snapshot is only marked stale, and the next window to attach hears so and gets a fresh one
/// (`retakeIfWatched`). And the window never acts on a stale one:
/// every work item that acts is judged against fresh facts first (`Work.applies(to:)`), re-read when
/// anything has happened since the last snapshot, and one the Mac has overtaken — a **Trust It**
/// pressed for a VM that stopped since — isn't carried out at all (`Outcome.overtaken`).
///
/// A snapshot never launches UTM and never raises macOS's Automation or Local Network prompt on its
/// own: only work the person pressed does that. `readPlan(through:readings:answers:utmUp:settled:consent:)`
/// keeps UTM's Apple Events and the window's port probe back until then, and the self-test behind C3
/// and C4, which a read from step 6 on runs, leaves the port alone altogether (`contextOptions`).
///
/// ## The certificate dialog outlives the window (critique §3, third part) — decided
///
/// `RDP.trustCertificate` runs `security add-trusted-cert` for up to 300 seconds, and the approval
/// dialog is SecurityAgent's, not Winbar's, so it stays up when the wizard is closed. The decision:
///
/// - **One at a time still holds.** The trust rewrites H7, and a Fix running beside it would read
///   and re-read facts while it was half done. Exempting one kind of work would make every snapshot
///   a question of which work finished last.
/// - **The work in flight is observable.** `inFlight` says what it is, when it started, its last
///   progress line, and what it's waiting for (`Waiting.certificateApproval`). A window that is
///   reopened calls `attach(_:)` and gets that state and every event after it, with nothing lost
///   between the two, so it shows "approve it in the macOS dialog" instead of a step whose buttons
///   do nothing.
/// - **Refusals name it.** Anything else pressed meanwhile is refused with the certificate named and
///   where to look, never a bare "busy".
/// - **It can be stopped from the window.** `stopWaiting()` ends Winbar's wait by terminating the
///   `security` tool, so a person who can't find the dialog isn't held for five minutes. What that
///   does to SecurityAgent's dialog hasn't been observed (spec §4 experiment 4 is where to look);
///   either way, the ending's fresh snapshot reads H7 again and says what is actually trusted.
final class SetupRunner {
    static let queueLabel = "net.elusive.winbar.setup"

    // MARK: - Work

    /// What the window can ask the runner to do. `Equatable`, and so never holding the password:
    /// that is `run`'s parameter, handed to the machine for `.savePC` and dropped for anything else
    /// (the same rule `CreateFormModel.forgetPassword()` keeps).
    enum Work: Equatable, Sendable {
        /// Reads what the steps up to this one show, changing nothing: the first look on step 1 (the
        /// spec's `lookAround`), arriving at a step, and every **Check Again**. One kind of work, not
        /// one per step, because each of them is the same thing — a read — and a second name for it
        /// would be a second thing to keep in step.
        case checkAgain(WizardStep)
        /// A look nobody pressed: the window's read when it becomes key again on a step that waits on
        /// another app (`SetupJourneyActions.returnRead`). Not a **Check Again**: it forgets only what
        /// the thing done elsewhere can have changed (`Forget`), so coming back never costs a survey
        /// of Windows, a second Winbar for the self-test or Windows App's command line unless that is
        /// what it's for. It goes through `SetupRunner.lookAgain`, never `run`: it is announced as a
        /// refresh (`Event.refreshing`, `.refreshed`), raises no step, and leaves `lastEnded` alone,
        /// so a failure card and the certificate's "not verified" stand through it.
        case lookAgain(WizardStep, forgetting: Forget)
        case installUTM
        /// The App Store hand-off (`Dependencies.windowPlan`), never the cask.
        case installWindowsApp
        /// Opens UTM and waits through the Automation prompt for utmctl's first answer
        /// (`UTMFirstUse.settle`): step 1's **Open UTM and Ask**, and its **Try Again**.
        case settleUTM
        case chooseVM(String, id: String?)
        /// Starts the VM and waits for Windows and its guest agent (up to three minutes).
        case startVM(String)
        /// Asks Windows again, dropping what the last survey said.
        case survey
        /// One row's **Fix**. H2, H7 and C2 have work of their own (`chooseVM`, `trustCertificate`,
        /// `savePC`), and are never fixed through this.
        case fix(checkID: String)
        /// **Fix Everything**: `SetupFlow.fixEverything` as the fresh facts have it, in order, with
        /// one survey after them all rather than one per row — `winbar setup`'s own economy.
        case fixEverything
        /// A manual row's **Done**: the check's `recordDone` if it has one, then a re-read.
        case recordDone(checkID: String)
        case guide(checkID: String)
        case keepBitLocker
        case discardChanges(checkID: String?)
        case trustCertificate
        case savePC
        case connect
        /// Step 7's one restart: whatever `Context.pending` holds, through `Reconfigure.apply`.
        case applyChanges

        /// The checks with work of their own, which `fix(checkID:)` never takes.
        static let ownWork: Set<String> = ["H2", "H7", "C2"]
        var isSelection: Bool { if case .chooseVM = self { return true }; return false }

        /// Which step the work belongs to. Doing it extends what later snapshots read to that step —
        /// except a look (`lookAgain`), which reads what the wizard has reached and raises nothing.
        var step: WizardStep {
            switch self {
            case .checkAgain(let step), .lookAgain(let step, _): return step
            case .installUTM, .settleUTM: return .lookAround
            case .chooseVM, .startVM: return .vm
            case .survey, .fixEverything, .keepBitLocker: return .tune
            case .discardChanges(let id): return id.map(SetupRunner.step(of:)) ?? .finish
            case .fix(let id), .recordDone(let id), .guide(let id): return SetupRunner.step(of: id)
            case .trustCertificate: return .certificate
            case .installWindowsApp, .savePC: return .savedPC
            case .connect: return .connect
            case .applyChanges: return .finish
            }
        }

        /// Holds the Mac awake while it runs, from the read before it to the read after it: the work
        /// someone presses and then walks away from, whose waits are wall-clock time. Installing UTM
        /// downloads a quarter of a gigabyte; a start waits up to three minutes for Windows; the
        /// survey and the guest fixes run scripts inside Windows; and the restart is several minutes
        /// of shutdown, UTM quit, write, verify and start. Not the work that waits on a person in a
        /// dialog (the certificate, the Automation prompt): a Mac nobody is sitting at is exactly
        /// where that wait should end. A read that can survey Windows holds it for itself, whatever
        /// work it follows (`SetupRunner.readHoldsMacAwake(through:)`).
        var holdsMacAwake: Bool {
            switch self {
            case .installUTM, .startVM, .survey, .fix, .fixEverything, .applyChanges: return true
            case .checkAgain, .lookAgain, .installWindowsApp, .settleUTM, .chooseVM, .recordDone, .trustCertificate,
                 .savePC, .connect, .guide, .keepBitLocker, .discardChanges: return false
            }
        }

        /// What it waits for a person to do in a window that isn't Winbar's.
        var waitsFor: Waiting? {
            switch self {
            case .trustCertificate: return .certificateApproval
            case .settleUTM: return .automationPrompt
            default: return nil
            }
        }

        /// Whether **Stop Waiting** can end it. The certificate: its wait is Winbar's own subprocess,
        /// which Winbar can end, and it runs for five minutes. The start: once UTM has been asked, the
        /// rest is up to three minutes of Winbar asking whether Windows is up yet, which stopping
        /// leaves Windows to finish by itself. Connect: up to two minutes of asking whether Windows
        /// takes Remote Desktop yet before Windows App is opened, which stopping ends as a cancel (the
        /// step is ready to try again). The restart: the wait for Windows after it, which is the start's
        /// wait again; `Reconfigure.apply` itself can't be cut short, so a stop pressed during it only
        /// skips that wait, and the restart has still finished. Josh's Connect had no way out of its
        /// wait, and neither did the restart's. The Automation wait is three rounds of utmctl that end
        /// by themselves within a minute.
        var canStopWaiting: Bool {
            switch self {
            case .trustCertificate, .startVM, .connect, .applyChanges: return true
            default: return false
            }
        }

        /// Whether the work can be judged against the snapshot the runner holds, or needs a fresh one
        /// first. Everything but a read: a read is the fresh snapshot.
        var needsFreshFacts: Bool { !isRead }

        /// Whether fresh facts still ask for this work: the step still offers the button that asks
        /// for it. False means the Mac changed underneath the window (UTM quit, the VM stopped, a row
        /// went ok, Windows App was opened) and the work is not carried out. Pure.
        func applies(to facts: SetupFlow.Facts) -> Bool {
            switch self {
            case .checkAgain, .lookAgain:
                return true
            case .installUTM:
                return SetupRunner.actionable(Dependencies.windowPlan(for: .utm, state: facts.utm, brew: facts.homebrew,
                                                                      brewHasCask: facts.utmFromHomebrew))
            case .installWindowsApp:
                if case .appStore? = Dependencies.windowPlan(for: .windowsApp, state: facts.windowsApp,
                                                             brew: facts.homebrew) { return true }
                return false
            case .settleUTM:
                return facts.utm.isInstalled
            case .chooseVM(let name, let id):
                guard case .listed(let list) = facts.vms else { return false }
                return list.contains { $0.name == name && $0.backend == "qemu" && (id == nil || $0.id == id) }
            case .startVM(let name):
                if case .stopped(let vm) = SetupFlow.vm(facts) { return vm.name == name }
                return false
            case .survey:
                if case .ready = SetupFlow.vm(facts) { return true }
                return false
            case .fix(let id):
                guard !Work.ownWork.contains(id), let row = facts.rows[id] else { return false }
                if id == "H5", SetupFlow.headlessOffer(facts) != .offer { return false }
                // A change inside Windows needs Windows running, whatever a row read earlier says.
                if Recipe.check(id)?.section == .guest, !facts.vmRunning { return false }
                return row.kind == .fixable && row.action != .unavailable
            case .fixEverything:
                return !SetupFlow.fixEverything(facts).isEmpty
            case .recordDone(let id):
                return facts.rows[id]?.kind == .manual
            case .guide(let id):
                return facts.rows[id]?.kind == .manual && facts.rows[id]?.canGuide == true
            case .keepBitLocker:
                return facts.chosen != nil && facts.kind("G9") == .fixable
            case .discardChanges: return !facts.pending.isEmpty
            case .trustCertificate:
                // The critique's own example: a wizard left on step 4 overnight, the VM stopped since,
                // mustn't trust a certificate read from a Windows that isn't running any more.
                guard facts.vmRunning else { return false }
                if case .trust = SetupFlow.certificate(facts) { return true }
                return false
            case .savePC:
                if case .save = SetupFlow.savedPC(facts) { return true }
                return false
            case .connect:
                if case .ready = SetupFlow.connect(facts) { return true }
                return false
            case .applyChanges:
                return !facts.pending.isEmpty && facts.chosen != nil
            }
        }
    }

    /// What a look nobody pressed (`Work.lookAgain`) forgets before it reads: the one cache the thing
    /// done in another app can have changed, and never more. Caches, not checks: forgetting a check
    /// by its section (`Context.refresh(after:)`) would drop a client check's saved-PC lookup with
    /// its self-test, and a look for Accessibility would run Windows App's command line. Each case
    /// also forgets every status, so the rows are worked out again from what is kept.
    ///
    /// Nothing here forgets Windows App's saved PCs. The saved-PC step's look waits on Windows App
    /// being quit, which a statuses look reads live (`WindowsAppBookmarks.appIsRunning`, a process
    /// scan), and C2 is worked out again from the lookup already made. The lookup itself runs Windows
    /// App's `--script bookmark list`, which reads while the app is open by design and which 11.4.2
    /// was seen deadlocking; a look would run it on every return. **Check Again** and **Try Again**
    /// still ask it.
    ///
    /// Once, a look does run it: when no lookup was ever made. With Windows App not installed, C2
    /// says it needs Windows App (C1) without asking it anything, so there is no lookup to work from;
    /// the first look after Windows App appears — back from the App Store, on the saved-PC step or
    /// the finished page with Windows App skipped — makes the one lookup the step needs before it can
    /// offer **Save It**, as its arrival read would have. Every look after that works from it. On
    /// 11.4.2 that lookup can hang for the read gate's 10 seconds under "Checking again…", and the
    /// card then says the command line isn't responding (`WindowsAppBookmarks.ReadGate`).
    enum Forget: Equatable, Sendable {
        /// Only the statuses: what is read live on every snapshot — H1's and C1's apps, the port,
        /// the process table, whether Windows App is open — is read again, and the rest is worked
        /// out from the caches.
        case statuses
        /// utmctl's answer and UTM's VM list: an Automation switch turned on, a VM made in UTM.
        case utm
        /// The survey of Windows: a sign-in on Windows' own screen.
        case guest
        /// The self-test behind C3 and C4: Accessibility turned on for Winbar.
        case selfTest
    }

    /// Whether a snapshot read through `step` holds the Mac awake while it reads. From tune on, a read
    /// includes the guest rows, and so can survey Windows: up to 180 seconds of waiting on it, by the
    /// clock (`Context.surveyGuest`), after a wake, a Check Again or any work that dropped the survey.
    /// Deliberately the step and not whether this read will survey — that depends on caches only the
    /// machine sees — so a read whose survey was still cached holds an assertion for a few seconds it
    /// didn't need, which costs nothing. Pure.
    static func readHoldsMacAwake(through step: WizardStep) -> Bool { step >= .tune }

    /// The step a recipe check belongs to; tune for G11, which belongs to none.
    static func step(of id: String) -> WizardStep {
        WizardStep.allCases.first { SetupFlow.checks(in: $0).contains(id) } ?? .tune
    }

    /// H1's and C1's rows as the window shows them: from the plan the window carries out
    /// (`Dependencies.windowPlan`), not the terminal's. Step 1 draws C1 long before step 5 acts on it,
    /// and with Homebrew here the terminal's row says "setup can ask Homebrew to install it" — which
    /// the window never does. Pure.
    static func dependencyRow(_ dependency: Dependency, state: DependencyState, brew: String?,
                              brewHasCask: Bool = false) -> Status {
        Recipe.dependencyStatus(dependency, state: state,
                                plan: Dependencies.windowPlan(for: dependency, state: state, brew: brew,
                                                              brewHasCask: brewHasCask))
    }

    /// The rows a snapshot builds itself, from states it has just read, rather than asking the check:
    /// H1 and C1 (`dependencyRow`). Asking the check would run `codesign` twice more, and C1's check
    /// says what the *terminal* would do — with Homebrew here, "setup can ask Homebrew to install
    /// it" — where the window's Windows App comes from the App Store. nil for every other check,
    /// which the machine asks `Context` for. Pure, so the machine's loop keeps no decision of its own.
    static func row(for id: String, readings: Readings) -> Status? {
        switch id {
        case "H1": return dependencyRow(.utm, state: readings.utm, brew: readings.homebrew,
                                        brewHasCask: readings.utmFromHomebrew)
        case "C1": return dependencyRow(.windowsApp, state: readings.windowsApp, brew: readings.homebrew)
        default: return nil
        }
    }

    /// A plan the window can carry out: one that installs, updates or hands off, not advice.
    static func actionable(_ plan: InstallPlan?) -> Bool {
        switch plan {
        case .brew?, .brewUpgrade?, .download?, .appStore?: return true
        case .manual?, nil: return false
        }
    }

    /// A person's part in another app's window, which Winbar can predict but not see.
    enum Waiting: Equatable, Sendable {
        /// SecurityAgent's dialog for trusting the certificate (H7).
        case certificateApproval
        /// macOS's "“Winbar” wants access to control “UTM”".
        case automationPrompt
    }

    /// The work in flight, as a value: what a reopened window, a refusal and the quit guard say.
    struct InFlight: Equatable, Sendable {
        let work: Work
        let started: Date
        /// The chosen VM when it started, for "restarting “winlab01”".
        let vm: String?
        /// The last progress line.
        var line: String?

        var waitingFor: Waiting? { work.waitsFor }
        var canStopWaiting: Bool { work.canStopWaiting }
    }

    /// `WinbarError`, as a value that can cross to the main thread and be compared.
    struct Problem: Equatable, Sendable, CustomStringConvertible {
        var title: String
        var detail: String

        init(title: String, detail: String = "") {
            self.title = title
            self.detail = detail
        }

        init(_ error: WinbarError) { self.init(title: error.title, detail: error.detail) }

        var description: String { detail.isEmpty ? title : "\(title): \(detail)" }
    }

    enum Outcome: Equatable, Sendable {
        case finished
        case failed(Problem)
        /// **Stop Waiting**, or the work stopped itself (`CancellationError`).
        case cancelled
        /// Not carried out: on fresh facts the step no longer offers it. The ending's facts say where
        /// things stand instead, and the window lands on them (`SetupFlow.landing`).
        case overtaken
    }

    /// How a piece of work ended, always with a snapshot read after it: a failure or a stop leaves
    /// the window as much in need of fresh facts as a success does.
    struct Ending: Equatable, Sendable {
        let work: Work
        let outcome: Outcome
        let facts: SetupFlow.Facts
        /// The Mac woke from sleep while this ran. Its waits are wall-clock time, so a failure may be a
        /// deadline spent asleep rather than anything Windows or UTM did.
        let slept: Bool
        /// When the work began (its `InFlight.started`): which run this is the end of. A window that
        /// was closed while two runs of the same work came and went tells them apart by it, and so
        /// keeps one run's output from being shown under another's ending.
        let started: Date
        /// What the work said, kept as the window keeps it (`SetupWindowState.adding`): its last
        /// lines, newest last. Empty for a read. A window closed while the work ran heard none of what
        /// it said after that, and a failure's own last lines are the ones it said just before the end
        /// — Homebrew's error — which its detail then points at ("its own output is above").
        var lines: [String] = []
    }

    /// A press turned down because something else is in flight. Says what.
    struct Refusal: Error, Equatable, Sendable, CustomStringConvertible {
        let wanted: Work
        let inFlight: InFlight
        /// The app's gate's own words (`AppWorkGate`), when it was the gate that turned it down: the
        /// menu or another window is doing something, which `inFlight` can't name.
        var reason: String? = nil
        /// The gate's words have stopped being true: the runner has had the gate since, for work or a
        /// read that began after this refusal, so whatever held it then has let go. "Winbar is still
        /// starting “…”" said on after the menu had finished, until Ben pressed something else; the
        /// page says it in the past tense from then on (`SetupCopy.Working.refused`).
        var reasonPassed = false
        /// The answers the press would have given, when it would have changed them: it is judged with
        /// them whether it still makes sense to choose again (`SetupWindowState.stillRefused`).
        var answers: SetupFlow.Answers? = nil
        var description: String { reason ?? String(SetupCopy.Working.refusal(inFlight).characters) }
    }

    /// What an attached window hears, on the callback queue, in order.
    enum Event: Equatable, Sendable {
        case started(InFlight)
        case progressed(InFlight)
        case ended(Ending)
        /// The snapshot last handed out no longer describes the Mac. A fresh one follows.
        case stale(SetupFlow.Staleness)
        /// A read nobody pressed has begun: the runner's own after a wake or a process came or went
        /// (`retake`), or the window's look on coming back (`lookAgain`). Pages keep their card
        /// through it; the runner's buttons wait for it, since it holds the queue.
        case refreshing(InFlight)
        /// That read's fresh snapshot. It never replaces how the last press ended (`lastEnded`).
        case refreshed(SetupFlow.Facts)
    }

    /// Keeps an attached handler listening; `cancel()`, or letting go of it, stops it.
    final class Observation {
        private var stop: (() -> Void)?
        init(_ stop: @escaping () -> Void) { self.stop = stop }
        func cancel() {
            stop?()
            stop = nil
        }
        deinit { cancel() }
    }

    /// The machine's handle on the work it's doing: where progress lines go, whether it's been asked
    /// to stop, and which rows a fix failed on.
    final class Job {
        let work: Work
        private let lock = NSLock()
        private var cancelled = false
        private var failures: [String: String] = [:]
        /// Everything said, kept the window's way, for the ending (`Ending.lines`).
        private var lines: [String] = []
        private let said: (String) -> Void

        init(work: Work, said: @escaping (String) -> Void) {
            self.work = work
            self.said = said
        }

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }

        func say(_ line: String) {
            // A read's lines ("Asking Windows…") are progress, not output: the window never keeps them.
            if !work.isRead {
                lock.lock()
                lines = SetupWindowState.adding(line, to: lines)
                lock.unlock()
            }
            said(line)
        }

        /// What the work has said so far, as the window would have kept it.
        var output: [String] {
            lock.lock()
            defer { lock.unlock() }
            return lines
        }

        /// Throws `CancellationError` once the work has been asked to stop.
        func checkCancellation() throws {
            if isCancelled { throw CancellationError() }
        }

        /// A fix that didn't work, kept with its row (`Row.failure`) rather than failing the snapshot.
        func rowFailed(_ id: String, _ problem: Problem) {
            lock.lock()
            failures[id] = problem.description
            lock.unlock()
        }

        var rowFailures: [String: String] {
            lock.lock()
            defer { lock.unlock() }
            return failures
        }
    }

    // MARK: - What it needs from the Mac, injected

    /// Everything the runner reaches outside itself, so the rules above can be tested with none of
    /// it real: no power assertion, no notification from macOS, no process table.
    struct Environment {
        /// Where the machine, and so the `Context`, lives. Serial.
        var queue: DispatchQueue
        /// Where `progress`, `done` and events are delivered: the main queue in the app.
        var callbacks: DispatchQueue
        var clock: () -> Date
        /// Begins the power assertion and returns what releases it.
        var keepAwake: (String) -> () -> Void
        /// UTM's processes and the named VM's QEMU process, from the process table.
        var processes: (String?) -> (utm: Set<Int32>, vm: Int32?)
        /// `NSWorkspace.shared.notificationCenter`, where the wake is posted.
        var workspace: NotificationCenter
        var workGate: AppWorkGate? = nil

        static var live: Environment {
            Environment(queue: DispatchQueue(label: SetupRunner.queueLabel, qos: .userInitiated),
                        callbacks: .main,
                        clock: Date.init,
                        // The same assertion `CreateJob` takes, not a second kind of it.
                        keepAwake: { reason in
                            let assertion = SleepAssertion(reason: reason)
                            return { assertion.release() }
                        },
                        processes: { vm in (Set(UTM.processIDs), VMProcesses.find(vm)?.pid) },
                        workspace: NSWorkspace.shared.notificationCenter,
                        workGate: .shared)
        }
    }

    // MARK: - State

    private let machine: SetupMachine
    private let env: Environment
    private let lock = NSLock()
    // Everything below is read and written under `lock`.
    private var current: InFlight?
    private var refreshFlight: InFlight?
    private var currentJob: Job?
    private var latest: SetupFlow.Facts?
    /// Why `latest` is stale, once something has said so; nil again with the next snapshot.
    private var latestStale: SetupFlow.Staleness?
    private var retakeQueued = false
    /// A look, or a read the window owed itself, that the app's gate turned away (the menu was
    /// starting a VM, say): owed, and taken as a read of everything once the gate is free, on the
    /// menu's next tick (`retakeIfWatched`, `readWhenFree`).
    private var lookTurnedAway = false
    private var lastEnding: Ending?
    private var answers = SetupFlow.Answers()
    /// How far the wizard has got: snapshots read every step up to here (`readPlan`).
    private var reach: WizardStep = .lookAround
    private var lastWake: Date?
    private var observers: [UUID: (Event) -> Void] = [:]
    private var notificationTokens: [(NotificationCenter, NSObjectProtocol)] = []

    init(machine: SetupMachine, environment: Environment = .live) {
        self.machine = machine
        env = environment
        let wake = env.workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                             queue: nil) { [weak self] _ in self?.woke() }
        // Not Winbar coming back to the front. That re-read everything up to the furthest step each
        // time — a survey of Windows from Tune on — so a page that was done went back to Checking…
        // whenever the person looked at it, and the click that brought the window forward greyed out
        // the button they came back to press: an Approve Certificate… pressed during the read was
        // refused, and the refusal went with the read, so macOS's dialog never came. A step that waits
        // on something done in another app takes a quiet, scoped look when its window becomes key
        // instead (`SetupJourneyActions.returnRead`, `lookAgain`), a moment later, so any press made
        // first wins; everything else keeps what it read, and Check Again.
        notificationTokens = [(env.workspace, wake)]
    }

    deinit {
        for (center, token) in notificationTokens { center.removeObserver(token) }
    }

    /// The app's runner, made the first time the window asks for it. Main thread only.
    static var shared: SetupRunner {
        if let instance { return instance }
        let made = SetupRunner(machine: LiveSetupMachine())
        instance = made
        return made
    }

    /// The runner if the window has ever asked for one, for the menu's refresh: a Mac that never
    /// opens the window pays one nil check every five seconds and nothing else.
    static var started: SetupRunner? { instance }
    private static var instance: SetupRunner?

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    // MARK: - Asking

    /// The work in flight, if any.
    var inFlight: InFlight? { locked { current ?? refreshFlight } }

    /// The newest snapshot handed out.
    var latestFacts: SetupFlow.Facts? { locked { latest } }

    /// How the last piece of work ended.
    var lastEnded: Ending? { locked { lastEnding } }

    /// A window arriving — opened for the first time, or reopened while work runs — attaches here. It
    /// gets what is in flight now, the newest snapshot and how the last piece of work ended, and then
    /// every event from that moment on, with nothing lost and nothing twice in between: the state and
    /// the registration are taken under the same lock every change is made under.
    ///
    /// The ending is part of it because a window closed while its work ran heard no `.ended`, and the
    /// ending is the one thing a snapshot can't say: that an install failed, and why (§2.4: reopening
    /// "shows how far it got").
    ///
    /// A snapshot that went stale while no window was attached was only marked (`invalidate`), so the
    /// window hears `.stale` first, then gets the fresh snapshot that attaching queues (`.refreshed`).
    func attach(_ handler: @escaping (Event) -> Void)
        -> (inFlight: InFlight?, latest: SetupFlow.Facts?, lastEnded: Ending?, observation: Observation) {
        let id = UUID()
        let state: (InFlight?, SetupFlow.Facts?, Ending?) = locked {
            observers[id] = handler
            // Queued under the lock, so a fresh snapshot handed out right after can't reach the
            // window before the word that this one is stale.
            if let stale = latestStale { env.callbacks.async { handler(.stale(stale)) } }
            return (current ?? refreshFlight, latest, lastEnding)
        }
        retakeIfWatched()
        noticeSelectionChange()
        let observation = Observation { [weak self] in
            guard let self else { return }
            self.locked { self.observers[id] = nil }
        }
        return (state.0, state.1, state.2, observation)
    }

    /// The window's own answers (`SetupFlow.Answers`), which every snapshot from now on carries.
    func update(answers: SetupFlow.Answers) {
        locked { self.answers = answers }
    }

    /// Starts `work`, or refuses it because something else is in flight. `progress` and `done` are
    /// called on the callback queue; `done` always gets an `Ending`, with a snapshot read after the
    /// work. `password` is for `.savePC` only, and is never stored: it goes to the machine for that
    /// one call and is dropped for any other work.
    @discardableResult
    func run(_ work: Work, password: String? = nil, answers: SetupFlow.Answers? = nil,
             progress: @escaping (String) -> Void = { _ in },
             done: @escaping (Ending) -> Void = { _ in }) -> Refusal? {
        let started = env.clock()
        lock.lock()
        if let busy = current ?? refreshFlight {
            lock.unlock()
            return Refusal(wanted: work, inFlight: busy)
        }
        let lease: AppWorkGate.Lease?
        if let gate = env.workGate {
            let flight = InFlight(work: work, started: started, vm: latest?.chosenVM)
            switch gate.begin(.setup, label: SetupCopy.Working.doing(flight), vm: latest?.chosenVM,
                              readsInstall: work.isRead && work.step <= .vm) {
            case .success(let held): lease = held
            case .failure(let error):
                lock.unlock()
                return Refusal(wanted: work, inFlight: flight, reason: error.detail)
            }
        } else { lease = nil }
        if let answers { self.answers = answers }
        reach = max(reach, work.step)
        let flight = InFlight(work: work, started: started, vm: latest?.chosenVM, line: nil)
        let job = Job(work: work) { [weak self] line in self?.said(line, progress) }
        current = flight
        currentJob = job
        let targets = Array(observers.values)
        lock.unlock()

        env.callbacks.async { targets.forEach { $0(.started(flight)) } }
        let secret = work == .savePC ? password : nil
        env.queue.async { self.execute(job, started: flight, password: secret, lease: lease, done: done) }
        return nil
    }

    /// **Stop Waiting**: asks the work in flight to stop, when it's one whose wait Winbar can end
    /// (`Work.canStopWaiting`). Returns whether there was one to ask. Its ending arrives as usual,
    /// with a fresh snapshot.
    @discardableResult
    func stopWaiting() -> Bool {
        locked {
            guard let job = currentJob, job.work.canStopWaiting else { return false }
            job.cancel()
            return true
        }
    }

    /// A look nobody pressed (`Work.lookAgain`): a fresh snapshot that forgets only what the look
    /// names, handed out as a refresh (`.refreshing`, then `.refreshed`). Returns whether a read is
    /// coming: this one, or a read of everything already queued.
    ///
    /// Not `run`, and not work. It makes no `Job` and says no lines; it never raises `reach`, so going
    /// back to look doesn't make every later snapshot read further; and it never touches `lastEnded`.
    /// That last is the point. A look that ended as work would replace how the last press ended: a
    /// failed install's card would turn back into the plain "install UTM" card, and the certificate's
    /// "not verified — check again" would be answered by a read that was never about it.
    ///
    /// Declined — false, and nothing said — while anything is in flight: that work ends with a
    /// snapshot of its own. Turned away by the app's gate (the menu starting a VM), it is owed, and
    /// taken as a read of everything on the menu's next tick (`lookTurnedAway`, `retakeIfWatched`).
    /// Either way nothing reaches the window but the refresh itself: no refusal, no banner.
    @discardableResult
    func lookAgain(_ work: Work) -> Bool {
        let started = env.clock()
        lock.lock()
        if retakeQueued {
            lock.unlock()
            return true
        }
        guard current == nil, refreshFlight == nil else {
            lock.unlock()
            return false
        }
        // In `run`'s order: this lock, then the gate's.
        var lease: AppWorkGate.Lease?
        if let gate = env.workGate {
            guard case .success(let held) = gate.begin(.setup, label: "checking setup", vm: latest?.chosenVM,
                                                       readsInstall: work.step <= .vm) else {
                lookTurnedAway = true
                lock.unlock()
                return false
            }
            lease = held
        }
        let flight = InFlight(work: work, started: started, vm: latest?.chosenVM)
        refreshFlight = flight
        let targets = Array(observers.values)
        // Queued under the lock, as `retake` does, so nothing handed out after can overtake it.
        env.callbacks.async { targets.forEach { $0(.refreshing(flight)) } }
        lock.unlock()

        env.queue.async {
            // Everything, when something has happened since the last snapshot or there is none.
            let everything = self.locked { self.latestStale != nil || self.latest == nil }
            let facts = self.snapshot(after: Performed(work: work, outcome: .finished), everything: everything)
            lease?.finish()
            self.store(facts) { targets in targets.forEach { $0(.refreshed(facts)) } }
        }
        return true
    }

    /// A read the window owed itself that the app's gate turned away (the menu starting a VM): owed
    /// here as a turned-away look is (`lookTurnedAway`), and taken as a read of everything once the
    /// gate is free, on the menu's next tick. The window hears it as a refresh, which is its moment
    /// to take a Check Again it still owes (`SetupWindowController.readByItself`).
    func readWhenFree() {
        locked { lookTurnedAway = true }
        retakeIfWatched()
    }

    /// Whether `facts` still describe this Mac: a process-table scan and the last wake, cheap enough
    /// to ask before drawing any button that acts.
    func staleness(of facts: SetupFlow.Facts) -> SetupFlow.Staleness? {
        let scan = env.processes(facts.chosenVM)
        return SetupFlow.staleness(of: facts, utmPIDs: scan.utm, vmPID: scan.vm, lastWake: locked { lastWake })
    }

    // MARK: - Freshness

    private func woke() {
        let now = env.clock()
        locked { lastWake = now }
        invalidate(.slept)
    }

    /// The menu's five-second refresh calls this (`AppDelegate.refresh`): its timer is the one that
    /// already notices processes coming and going, so the runner hangs off it rather than keeping a
    /// second. It scans UTM's processes and the chosen VM's, and marks the snapshot stale when either
    /// set moved since it was taken. Nothing is read when nothing moved.
    func processTableTick() {
        noticeSelectionChange()
        // A menu operation may have owned the gate when the last refresh was requested.
        // Retry only while somebody is watching, rather than leaving an already-stale page stuck.
        retakeIfWatched()
        guard let facts = latestFacts else { return }
        let scan = env.processes(facts.chosenVM)
        switch SetupFlow.staleness(of: facts, utmPIDs: scan.utm, vmPID: scan.vm, lastWake: nil) {
        case .utmChanged?: invalidate(.utmChanged)
        case .vmChanged?: invalidate(.vmChanged)
        default: break
        }
    }

    private func noticeSelectionChange() {
        env.queue.async { [weak self] in
            guard let self, let facts = self.latestFacts, self.machine.selectionChanged(since: facts) else { return }
            self.invalidate(.vmChanged)
        }
    }

    /// Says the snapshot is stale, once, and queues a fresh one if a window is attached to see it
    /// (`retakeIfWatched`).
    private func invalidate(_ reason: SetupFlow.Staleness) {
        lock.lock()
        guard latest != nil, latestStale == nil else {
            lock.unlock()
            return
        }
        latestStale = reason
        let targets = Array(observers.values)
        lock.unlock()

        env.callbacks.async { targets.forEach { $0(.stale(reason)) } }
        retakeIfWatched()
    }

    /// Queues a fresh snapshot when the one held is stale and nothing else will replace it: nothing
    /// in flight (work ends with a snapshot of its own, read after whatever made this one stale), and
    /// none queued already.
    ///
    /// And only while a window is attached. Once the runner exists it hears every wake and
    /// process change for the rest of the session, and a read at the wizard's furthest step can be a
    /// survey of Windows, a second Winbar launched for the self-test, Windows App's CLI, an Apple
    /// Event, a network probe and a write to Config — all for nobody, and some of it beside the menu's
    /// own work. With no window, the snapshot is only marked stale: `attach` re-reads it for the
    /// first window that needs it, and `run` re-reads stale facts before judging any work anyway.
    ///
    /// A look the app's gate turned away (`lookTurnedAway`) is owed in the same way: nothing marked
    /// the snapshot stale, but the window asked for a look and was told nothing, so the menu's next
    /// tick takes it.
    private func retakeIfWatched() {
        let retake: Bool = locked {
            guard latestStale != nil || lookTurnedAway, !observers.isEmpty, current == nil, refreshFlight == nil,
                  !retakeQueued else { return false }
            retakeQueued = true
            return true
        }
        if retake { env.queue.async { self.retake() } }
    }

    /// On the queue.
    private func retake() {
        guard locked({ !observers.isEmpty }) else { locked { retakeQueued = false }; return }
        var lease: AppWorkGate.Lease?
        if let gate = env.workGate {
            guard case .success(let held) = gate.begin(.setup, label: "checking setup", vm: latestFacts?.chosenVM,
                                                       readsInstall: locked { reach <= .vm }) else {
                locked { retakeQueued = false }; return
            }
            lease = held
        }
        defer { withExtendedLifetime(lease) {} }
        let flight: InFlight? = locked {
            // A button can have queued work after the refresh was scheduled. Let that work's
            // own fresh read settle it; never overwrite its ownership or report it finished.
            guard current == nil, refreshFlight == nil else { retakeQueued = false; return nil }
            let flight = InFlight(work: .checkAgain(reach), started: env.clock(), vm: latest?.chosenVM)
            refreshFlight = flight
            // This read is of everything, so it is the look that was turned away, too.
            lookTurnedAway = false
            let targets = Array(observers.values)
            env.callbacks.async { targets.forEach { $0(.refreshing(flight)) } }
            return flight
        }
        guard flight != nil else { return }
        let facts = snapshot(after: nil, everything: true)
        // An enabled button must not immediately lose to the read's still-held work gate.
        lease?.finish()
        store(facts) { targets in targets.forEach { $0(.refreshed(facts)) } }
    }

    /// Hands out a new snapshot, then checks it straight away: something that happened while it was
    /// being read makes it stale already, and then another one is queued.
    private func store(_ facts: SetupFlow.Facts, ending: Ending? = nil, done: ((Ending) -> Void)? = nil,
                       announce: @escaping ([(Event) -> Void]) -> Void) {
        lock.lock()
        latest = facts
        latestStale = nil
        retakeQueued = false
        if let ending {
            lastEnding = ending
            current = nil
            currentJob = nil
        } else {
            refreshFlight = nil
        }
        let targets = Array(observers.values)
        lock.unlock()

        env.callbacks.async {
            if let ending { done?(ending) }
            announce(targets)
        }
        if let reason = staleness(of: facts) { invalidate(reason) }
    }

    // MARK: - Doing

    private func said(_ line: String, _ progress: @escaping (String) -> Void) {
        lock.lock()
        guard var flight = current else {
            lock.unlock()
            return
        }
        flight.line = line
        current = flight
        let targets = Array(observers.values)
        lock.unlock()
        env.callbacks.async {
            progress(line)
            targets.forEach { $0(.progressed(flight)) }
        }
    }

    /// On the queue.
    ///
    /// Long work holds the power assertion from its first read to its last, not just while the
    /// machine performs it. The reads are where much of the waiting is: `.survey` does nothing by
    /// itself but make the read after it ask Windows again, and that read is the survey (up to three
    /// minutes, by the clock); a guest Fix and Fix Everything are re-read by surveying; and a restart
    /// pressed on a stale snapshot reads the Mac again before it's judged. The assertion is let go
    /// before `store` hands the ending out, so nobody who hears it finds the Mac still held.
    private func execute(_ job: Job, started flight: InFlight, password: String?, lease: AppWorkGate.Lease?,
                         done: @escaping (Ending) -> Void) {
        // Release before callbacks can start the next step; a local retain also spans every read.
        let work = job.work
        let (outcome, facts) = awake(if: work.holdsMacAwake, SetupCopy.Working.keepingAwake(flight)) {
            carryOut(job, flight, password: password, held: work.holdsMacAwake)
        }
        let slept = locked { lastWake.map { $0 > flight.started } ?? false }
        let ending = Ending(work: work, outcome: outcome, facts: facts, slept: slept, started: flight.started,
                            lines: job.output)
        lease?.finish()
        store(facts, ending: ending, done: done) { targets in targets.forEach { $0(.ended(ending)) } }
    }

    /// The work and the reads either side of it. `held`: the work already holds the Mac awake, so
    /// its reads don't take an assertion of their own.
    private func carryOut(_ job: Job, _ flight: InFlight, password: String?, held: Bool) -> (Outcome, SetupFlow.Facts) {
        let work = job.work
        // Judge the work against facts that describe the Mac now.
        var before = locked { latest }
        let targetChanged = before.map { machine.selectionChanged(since: $0) } ?? false
        if work.needsFreshFacts, targetChanged || (before.map({ staleness(of: $0) != nil }) ?? true) {
            let fresh = snapshot(after: nil, everything: true, held: held)
            locked {
                latest = fresh
                latestStale = nil
            }
            before = fresh
        }
        // …and with the window's answers as they are now: the ones handed in with this press, not the
        // ones the last snapshot carried. A "Not now" said just before Fix Everything was pressed has
        // to keep that row out of it (`SetupFlow.fixEverything` reads `leftAlone`), and a Skip just
        // before Save It has to stop the save.
        let target = before?.target
        before?.answers = locked { answers.forVM(target) }

        let outcome: Outcome
        if job.isCancelled {
            outcome = .cancelled
        } else if targetChanged && work.needsFreshFacts && !work.isSelection && work.step > .lookAround {
            outcome = .overtaken
        } else if let before, work.needsFreshFacts, !work.applies(to: before) {
            outcome = .overtaken
        } else {
            outcome = perform(job, password: password, facts: before ?? SetupFlow.Facts())
        }

        // What the work may have changed is read again. Everything is, when anything happened while
        // it ran (a wake, a process coming or going) or there was nothing before.
        if outcome == .overtaken, let before { return (outcome, before) }
        let everything = before.map { staleness(of: $0) != nil } ?? true
        let facts = snapshot(after: Performed(work: work, outcome: outcome, rowFailures: job.rowFailures),
                             everything: everything, held: held)
        return (outcome, facts)
    }

    /// `body`, inside the power assertion when `hold` says so. The release is a `defer`, so it runs
    /// however `body` leaves.
    private func awake<T>(if hold: Bool, _ reason: @autoclosure () -> String, _ body: () -> T) -> T {
        guard hold else { return body() }
        let release = env.keepAwake(reason())
        defer { release() }
        return body()
    }

    /// The machine's part of the work. Every way it can leave — returning, throwing a `WinbarError`,
    /// throwing `CancellationError`, throwing anything else — becomes an `Outcome`, so the reads and
    /// the assertion around it always finish.
    private func perform(_ job: Job, password: String?, facts: SetupFlow.Facts) -> Outcome {
        do {
            try machine.perform(job.work, password: password, facts: facts, job: job)
            return .finished
        } catch is CancellationError {
            return .cancelled
        } catch let error as WinbarError {
            return .failed(Problem(error))
        } catch {
            return .failed(Problem(title: "Something went wrong", detail: "\(error)"))
        }
    }

    /// On the queue. A read that reaches tune can survey Windows (`readHoldsMacAwake(through:)`), so
    /// it holds the Mac awake by itself — Check Again, a re-read nobody pressed — unless the work it
    /// belongs to already does (`held`).
    private func snapshot(after performed: Performed?, everything: Bool, held: Bool = false) -> SetupFlow.Facts {
        let taken = env.clock()
        let (through, answers, previous) = locked { (reach, self.answers, latest) }
        let job = locked { currentJob }
        let reading = InFlight(work: .checkAgain(through), started: taken, vm: previous?.chosenVM)
        let readings = awake(if: !held && SetupRunner.readHoldsMacAwake(through: through),
                             SetupCopy.Working.keepingAwake(reading)) {
            machine.readings(through: through, answers: answers, after: everything ? nil : performed?.work, job: job)
        }
        let scan = env.processes(readings.chosenVM)
        let stamp = SetupFlow.Stamp(taken: taken, utmPIDs: scan.utm, vmPID: scan.vm)
        let facts = SetupRunner.facts(from: readings, stamp: stamp, answers: answers, previous: previous,
                                      after: performed)
        locked {
            self.answers = self.answers.forVM(facts.target)
            if let old = previous?.target, old != facts.target { reach = .vm }
        }
        return facts
    }
}

// MARK: - The machine

/// What the runner drives: the `Context`, and everything that does something to the Mac. The runner
/// calls it only on its queue, one call at a time. `LiveSetupMachine` is the real one; tests pass
/// their own, so the runner's rules can be held to without UTM, a VM or a password.
protocol SetupMachine: AnyObject {
    func selectionChanged(since facts: SetupFlow.Facts) -> Bool
    /// Everything a snapshot holds, read now, through `step` (`SetupRunner.readPlan`). `answers` are
    /// the window's as they are now, for the one read that waits on the person: the Remote Desktop
    /// port, probed only once Connect was pressed. `after` is the work just done, so only what it can
    /// have changed is dropped from the caches; nil drops everything. `job` is the work in flight,
    /// for progress lines while reading (the survey's "Asking Windows…"); nil for a re-read nobody
    /// pressed.
    func readings(through step: WizardStep, answers: SetupFlow.Answers, after work: SetupRunner.Work?,
                  job: SetupRunner.Job?) -> SetupRunner.Readings

    /// Carries out `work`. Throws a `WinbarError` to say it failed, and `CancellationError` when it
    /// stopped because the job was cancelled. `password` is non-nil for `.savePC` only. `facts` is
    /// the fresh snapshot the work was judged against (`Work.applies(to:)`), so the machine acts on
    /// the rows the person saw — **Fix Everything** fixes exactly `SetupFlow.fixEverything(facts)`.
    func perform(_ work: SetupRunner.Work, password: String?, facts: SetupFlow.Facts, job: SetupRunner.Job) throws
}

extension SetupMachine {
    func selectionChanged(since facts: SetupFlow.Facts) -> Bool { false }
}

// MARK: - The snapshot, from what was read (pure)

extension SetupRunner {
    /// What the machine read, raw, before it becomes a `Facts`. Every field is a value it already
    /// fetched; nothing here reaches the Mac.
    struct Readings {
        var utm: DependencyState = .missing
        var homebrew: String?
        var utmFromHomebrew = false
        /// nil: utmctl wasn't asked (UTM not running, or not to be asked yet).
        var utmAnswers: UTM.CtlAnswer?
        var utmConsent: Automation.Consent = .decided
        var utmQuarantined = false
        var windowsApp: DependencyState = .missing
        /// nil: UTM wasn't asked for its VMs.
        var vms: Result<[VMInfo], WinbarError>?
        var chosenVM: String?
        var chosenID: String?
        var guestAnswers = false
        var installRunning = false
        /// Check id → what it said, for the checks read. Absent: not read.
        var statuses: [String: Status] = [:]
        var declined = SetupFlow.Declined()
        var keepBitLocker = false
        var disk: SetupFlow.Disk?
        var rdpHost: String?
        var rdpUser: String?
        var windowsAppRunning = false
        var readiness: RDP.Readiness?
        /// The host whose saved-PC tile this window's last Connect pressed (`Facts.savedPCPressed`).
        var savedPCPressed: String?
        var pending = ConfigChanges()
        /// nil: not asked (only the last step asks).
        var otherVMs: Result<[String], WinbarError>?
        /// `Config.pendingUTMRestart`: the UTM processes a display change was sent to.
        var pendingRestart: UTMRestart?
    }

    /// A piece of work that was done, for the rows it leaves a note on.
    struct Performed: Equatable, Sendable {
        var work: Work
        var outcome: Outcome
        /// Check id → what its fix said when it didn't work (`Job.rowFailed`).
        var rowFailures: [String: String] = [:]
    }

    /// The snapshot, from what was read, the process table's stamp and the window's own answers.
    /// Pure: this is the whole of the mapping from the Mac to what the window draws.
    ///
    /// - Rows come from the recipe's own check (title, why, what a button may do) and the status
    ///   read. A check not read has no row, and absent is never "fine".
    /// - A fix that failed leaves its words on its row (`Row.failure`), and a **Done** that didn't take
    ///   leaves "still: …" (`Row.still`). Both stay across later snapshots for as long as the row
    ///   says the same kind of thing — a read nobody pressed, after a wake or on the window's look
    ///   when it becomes key, mustn't wipe the one message the person needs — and go when it
    ///   changes, or when the row is fixed.
    /// - A VM list that failed is a failure, never an empty list.
    /// - Whether the VM runs comes from the stamp's process scan, not UTM's list, so the two can't
    ///   disagree within one snapshot.
    /// - A UTM restart is owed while a UTM process a display change was sent to is still running
    ///   (`UTM.settlePendingRestart`'s own test, from the same process scan).
    /// - The answers are the window's, never the machine's.
    static func facts(from readings: Readings, stamp: SetupFlow.Stamp, answers: SetupFlow.Answers,
                      previous: SetupFlow.Facts?, after performed: Performed?) -> SetupFlow.Facts {
        var facts = SetupFlow.Facts()
        facts.utm = readings.utm
        facts.homebrew = readings.homebrew
        facts.utmFromHomebrew = readings.utmFromHomebrew
        facts.utmAnswers = readings.utmAnswers
        facts.utmConsent = readings.utmConsent
        facts.utmQuarantined = readings.utmQuarantined
        facts.windowsApp = readings.windowsApp
        facts.vms = readings.vms.map(SetupFlow.VMListing.init) ?? .notAsked
        facts.chosenVM = readings.chosenVM
        facts.chosenID = readings.chosenID
        facts.vmRunning = stamp.vmPID != nil
        facts.guestAnswers = readings.guestAnswers
        facts.installRunning = readings.installRunning
        facts.declined = readings.declined
        facts.keepBitLocker = readings.keepBitLocker
        facts.disk = readings.disk
        facts.rdpHost = readings.rdpHost
        facts.rdpUser = readings.rdpUser
        facts.windowsAppRunning = readings.windowsAppRunning
        facts.readiness = readings.readiness
        facts.savedPCPressed = readings.savedPCPressed
        facts.pending = readings.pending
        facts.otherVMs = readings.otherVMs.map(SetupFlow.OtherVMs.init) ?? .notAsked
        facts.utmRestartOwed = readings.pendingRestart.map { !stamp.utmPIDs.isDisjoint(with: $0.pids) } ?? false
        facts.answers = answers.forVM(facts.target)
        facts.stamp = stamp

        for (id, status) in readings.statuses {
            guard let check = Recipe.check(id) else { continue }
            var row = SetupFlow.Row(check, status)
            let before = previous?.rows[id]
            let sameKind = before?.kind == row.kind
            // Carried while the row says the same kind of thing.
            if sameKind {
                row.still = before?.still ?? false
                row.failure = before?.failure
            }
            if let performed {
                if performed.work == .recordDone(checkID: id) { row.still = row.kind == .manual }
                if performed.work == .fix(checkID: id) {
                    switch performed.outcome {
                    case .failed(let problem): row.failure = performed.rowFailures[id] ?? problem.description
                    case .finished: row.failure = nil
                    case .cancelled, .overtaken: break
                    }
                }
                // Fix Everything notes only the rows it failed on; the others keep what they had.
                if performed.work == .fixEverything, let failure = performed.rowFailures[id] { row.failure = failure }
            }
            if row.kind == .ok { row.failure = nil }
            facts.rows[id] = row
        }
        return facts
    }

    // MARK: What a snapshot reads (pure)

    /// Which checks and questions a snapshot reads.
    struct ReadPlan: Equatable, Sendable {
        /// Recipe checks, in the order the window meets them.
        var checks: [String]
        /// utmctl (H9) and UTM's VM list: Apple Events.
        var asksUTM: Bool
        /// UTM's other running VMs, for step 7's headless offer: an Apple Event, asked only there.
        var otherVMs: Bool
        /// The Remote Desktop port, for step 6's "what went wrong". Probing it raises macOS's Local
        /// Network prompt (`RDP.probeNow`), so only once Connect has been pressed
        /// (`SetupFlow.Answers.connectPressed`).
        var readiness: Bool
        /// Whether Windows App is open, for step 5's refusal to write its database.
        var windowsAppRunning: Bool

        /// The same plan once utmctl has said nothing (or refused): nothing else that asks UTM is
        /// read, because every Apple Event would wait out a timeout of its own on the same silence.
        /// H9 stays, since it says which silence it is.
        var utmSilent: ReadPlan {
            var plan = self
            plan.checks = checks.filter { SetupRunner.readWithoutUTM.contains($0) || $0 == "H9" }
            plan.otherVMs = false
            return plan
        }
    }

    /// The options of the window's one `Context`: the terminal's, except that the self-test behind
    /// C3 and C4 leaves the Remote Desktop port alone (`SelfTest.noPortProbe`).
    ///
    /// Reads from step 6 on run that self-test, as Winbar.app, and it probed the port whenever the VM
    /// ran. The probe is what raises macOS's Local Network prompt, so step 6 could raise it the moment
    /// it was first drawn — before Connect, and before anyone had read the sentence that says it's
    /// coming — the very thing `readPlan` holds the window's own probe back for. Nothing in the
    /// window reads the self-test's port answer: the one it shows is its own probe
    /// (`ReadPlan.readiness`), taken only once Connect has been pressed. So the self-test leaves the
    /// port alone on every read, before Connect and after, and the window has one probe and one rule
    /// for it.
    static var contextOptions: Context.Options {
        var options = Context.Options()
        options.selfTestProbesPort = false
        return options
    }

    /// The checks a snapshot can read without UTM: they look at app bundles, Time Machine and the
    /// login items, never at UTM or a VM.
    static let readWithoutUTM: Set<String> = ["H1", "H6", "C1", "C4"]

    /// What a snapshot reads when the wizard has got as far as `step`. Pure.
    ///
    /// Every step's checks up to `step`, and Windows App's (C1) from the first look, since step 1
    /// draws its row long before step 5 acts on it. Nothing beyond `step`: the survey behind the
    /// guest rows can take minutes, and the self-test behind C3 launches a second Winbar, so a step
    /// that doesn't show them doesn't pay for them.
    ///
    /// Nothing that asks UTM unless UTM is running *and* may be asked. A snapshot is a read, and
    /// reading must not launch UTM — every utmctl call and Apple Event does, if it isn't running —
    /// nor send the first Apple Event that raises macOS's "“Winbar” wants access to control “UTM”" before the
    /// window has said it's coming (spec §2.2). `mayAskUTM` is true after **Open UTM and Ask** in this
    /// run, or when macOS already has an answer on file (`readPlan(through:readings:answers:utmUp:
    /// settled:consent:)`, which the machine calls). Otherwise the checks that ask UTM are left
    /// unread, and step 1 is where the window lands.
    ///
    /// The same care for the Local Network prompt, which probing the Remote Desktop port raises: the
    /// port is read only once the window has pressed Connect (`connectPressed`), after step 6's
    /// sentence predicting the prompt, and never merely because step 6 was reached — or the prompt
    /// could appear the moment step 6 is first drawn, or on a re-read after a wake. The one screen
    /// that shows the port is the recovery card after **No** or a failed Connect, which both come
    /// after the press, so the read that ends Connect and every read after it probe.
    static func readPlan(through step: WizardStep, utmRunning: Bool, mayAskUTM: Bool, connectPressed: Bool) -> ReadPlan {
        // The first look is the least any snapshot reads: whether UTM and Windows App are here at all.
        let step = max(step, .lookAround)
        let asksUTM = utmRunning && mayAskUTM
        let reached = Set(WizardStep.allCases.filter { $0 <= step }.flatMap(SetupFlow.checks(in:)) + ["C1"])
        let checks = SetupFlow.order.filter { reached.contains($0) && (asksUTM || readWithoutUTM.contains($0)) }
        return ReadPlan(checks: checks,
                        asksUTM: asksUTM,
                        otherVMs: asksUTM && step == .finish,
                        readiness: step >= .connect && connectPressed,
                        windowsAppRunning: step >= .savedPC)
    }

    /// The plan for one snapshot, from what the machine fetches before it knows what to read: the
    /// readings so far (whether UTM is installed), whether a UTM process is up, what utmctl said to
    /// this run's last **Open UTM and Ask** (`settled`, nil if it wasn't pressed), macOS's consent on
    /// file for Winbar and UTM, and the window's answers. The machine fetches them; this decides, so
    /// the rules below are held by tests rather than by a live machine nothing can test. Pure.
    ///
    /// - UTM counts as running only when it is installed as well as up.
    /// - UTM may be asked once **Open UTM and Ask** has been pressed in this run, or when macOS
    ///   already has an answer on file, so no prompt can appear (§2.2). `consent` is asked only when
    ///   nothing was pressed: on a Mac whose Apple Events to UTM are stuck behind the prompt, asking
    ///   takes its full timeout.
    /// - The Remote Desktop port is probed only once the window has pressed Connect. A connection
    ///   that opened was pressed for, so `connectionOpened` counts too.
    static func readPlan(through step: WizardStep, readings: Readings, answers: SetupFlow.Answers, utmUp: Bool,
                         settled: UTM.CtlAnswer?, consent: () -> Automation.Consent) -> ReadPlan {
        readPlan(through: step, utmRunning: readings.utm.isInstalled && utmUp,
                 mayAskUTM: settled != nil || consent() == .decided,
                 connectPressed: answers.connectPressed || answers.connectionOpened)
    }

    /// Whether a snapshot asks utmctl again rather than taking what it said to the last **Open UTM
    /// and Ask** or **Try Again** (`settled`). A utmctl that said nothing while macOS's prompt may still
    /// be up isn't asked again by a mere re-read: twenty more seconds of nothing, and every Apple Event
    /// after it would wait out a timeout of its own. Every other answer is asked again, because the fix
    /// for it happens outside the window, and the window's look when it becomes key on such a page
    /// asks UTM again (`SetupJourneyActions.returnRead`, forgetting `Forget.utm`):
    ///
    /// - A refusal comes back at once, so asking again costs nothing, and once the switch is on in
    ///   System Settings the next read is what notices. Taking the old answer kept the window on
    ///   "not allowed" however often it was looked at again, until someone pressed **Try Again**.
    /// - Silence with macOS's answer already on file (`consent`, asked only then) has no prompt to wait
    ///   behind, so asking again can't queue behind one.
    /// - An error of UTM's own ("not running") is as quick, and opening UTM is the fix.
    ///
    /// Not the read straight after the asking (`justAsked`), which the answer was just given to: after
    /// a minute of silence with an answer on file, it would wait twenty seconds more for nothing. Pure.
    static func reasksUTM(after settled: UTM.CtlAnswer, justAsked: Bool, consent: () -> Automation.Consent) -> Bool {
        guard !justAsked else { return false }
        guard case .silent = settled else { return true }
        return consent() == .decided
    }

    // MARK: Step 7, coming back to it (pure)

    /// Where step 7's restart stands, as a window coming back to it is told: reopened while it runs,
    /// or after the Mac woke in the middle of it.
    enum RestartReport: Equatable, Sendable {
        /// Nothing to say about a restart.
        case none
        /// Still going; `InFlight.line` says which part.
        case running(InFlight)
        /// The VM is off, and UTM still owes the restart a display change asked for
        /// (`Config.pendingUTMRestart`): **Start It** quits UTM first, and `UTM.settlePendingRestart`
        /// refuses that while another VM runs. `SetupCopy.Working.restartOwed` says so.
        case offWithUTMRestartOwed(vm: String, slept: Bool)
        /// The restart didn't finish and the VM is off; nothing is owed, so **Start It** is an
        /// ordinary start.
        case off(vm: String, slept: Bool)
        /// The restart failed and the VM is running: Reconfigure's refusals and verify failures leave
        /// it as it was.
        case failed(Problem, slept: Bool)
    }

    /// Pure.
    static func restartReport(inFlight: InFlight?, last: Ending?, facts: SetupFlow.Facts) -> RestartReport {
        if let inFlight, inFlight.work == .applyChanges { return .running(inFlight) }
        let restart = last?.work == .applyChanges ? last : nil
        let slept = restart?.slept ?? false
        if let vm = facts.chosenVM, !facts.vmRunning {
            // Owed is owed, whoever left it: this run's restart, or one from before Winbar relaunched.
            if facts.utmRestartOwed { return .offWithUTMRestartOwed(vm: vm, slept: slept) }
            if let restart, restart.outcome != .finished { return .off(vm: vm, slept: slept) }
        }
        if let restart, case .failed(let problem) = restart.outcome { return .failed(problem, slept: slept) }
        return .none
    }
}
