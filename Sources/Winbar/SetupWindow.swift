import AppKit
import SwiftUI

// The Set Up Winbar window (gui-wizard.md §2, §3.5): one non-modal window that walks someone from a
// freshly installed Winbar to a working Connect without a terminal. All steps are implemented, and it
// is offered to everyone: it opens on a new Mac's first run and from Set Up Winbar… in the menu.
//
// Three layers, so that what the window decides can be tested without showing one:
//
// - `SetupWindowState` is everything the window draws, as a value, and the runner's events become
//   new values of it through `applying(_:)`. Pure.
// - `LookAroundPage` turns a state into step 1's rows, its card and its buttons, and `armieLine`
//   says whether Armie is there and what he says. `VMPage` does the same for step 2. `ArmieCue`
//   says where Armie stands on every page, step 1's through `armieLine`. Pure.
// - Step 2's **Make One** shows the New Windows VM views in the window, as the step's body
//   (`CreateWindowController.embed(_:)`), until they hand back. There is still one create controller
//   and one install: the wizard holds no second copy of either.
// - `SetupWindowController` owns the NSWindow, attaches to the runner (`SetupRunner`, the one place
//   the window's `Context` lives), and turns presses into work. `SetupScreen` draws a state and sends
//   commands back; it holds nothing of its own, so the snapshot tests draw it straight from a fixture.
//
// The window never reaches `Context`, UTM or macOS from the main thread: every read and every piece
// of work goes through the runner's queue, and what comes back is a `SetupFlow.Facts` value.

// MARK: - Who is offered the window

/// Whether the window is offered to everyone, or only to someone who asks for it by name.
enum SetupWindow {
    /// On: the window opens by itself on a new Mac's first run (`SetupWindowController.opensByItself`),
    /// and every menu has **Set Up Winbar…**, directly above **Open UTM**. `winbar setup --window` opens
    /// it either way, and `winbar setup` in Terminal stays a complete route of its own.
    ///
    /// Why on (0.2.0): all eight steps exist, so the welcome's "This window does the whole thing … You
    /// don't need Terminal" is true, and on 2026-09-23 the signed app went through the whole of it on a
    /// real Mac — Connect to a Windows desktop, Finish, Go Headless with its restart, and a second
    /// Connect with the credentials Windows App stored. It was off while that was unproven: offscreen
    /// renders and unit tests can't show that macOS's prompts and Windows' sign-in work.
    ///
    /// Turning it on resets nothing. A Mac that put the welcome away before (`Config.setupWizardShown`,
    /// **Not Now** in a `--window` session) or has a VM chosen isn't greeted again, and finds the window
    /// in the menu like everyone else. The menu's no-VM hint and the ending follow this switch
    /// (`MenuState.offersSetUp`, `SetupCopy.Finish.doneBody(canReopenFromMenu:)`); the copy that
    /// sends someone to the menu to come back (`SetupCopy.Finish.notOffering`,
    /// `SetupCopy.Connecting.recoverConsole`) assumes it is on, which SetupWindowLifecycleTests pins.
    static let availableToEveryone = true
}

// MARK: - What the window shows, as a value

struct SetupWindowState: Equatable {
    var step: WizardStep = .welcome
    /// The newest snapshot, with the window's own answers laid over it. nil until the first read.
    var facts: SetupFlow.Facts?
    /// The runner's work in flight, whoever pressed it (a reopened window gets it from `attach`).
    var inFlight: SetupRunner.InFlight?
    var lastEnding: SetupRunner.Ending?
    /// The progress lines of the last piece of work that wasn't a read, newest last: Homebrew's output
    /// or the download's lines, which the install's card shows as they arrive.
    var lines: [String] = []
    /// When the run `lines` came from began (`InFlight.started`, `Ending.started`). A window reopened
    /// after a run it never saw start compares this with that run's, and drops lines that aren't its.
    var linesStarted: Date?
    /// A press the runner turned down, said until the work it was turned down for ends, or the next
    /// piece of work starts. Never longer: it says that work is still going.
    var refusal: SetupRunner.Refusal?
    /// What this run of the window has been told. Kept in memory only (§2.4).
    var answers = SetupFlow.Answers()
    /// **Hide Armie** was pressed, now or on an earlier run.
    var armieHidden = false
    /// Step 2's body is the New Windows VM views (§2.3 **Make One**): from the press that put them
    /// there until they hand back (`CreateWindowController.EmbeddedEnd`). Set only by a press — **Make
    /// One**, **Make a New One**, **Show Install Progress** — never by a snapshot, so a snapshot read
    /// before an install ended can't put its views back on screen after it has.
    var creating = false
    /// The VM ticked in step 2's picker, by UTM's id. Nothing is chosen until **Use This One**.
    var pickedVM: String?
    var choosingAnotherVM = false
    /// When the install shown here ended well. The first snapshot read after it decides whether the
    /// window moves on to step 3 (§2.3): a new VM exists now, and the install chose it, so nothing
    /// read before that moment can say whether step 2 is done. nil once decided, or with no such install.
    var afterInstall: Date?
    var installedVMID: String?
    var installMessages: [CreateMessage] = []
    var finished = false
    var secretEpoch = 0
    var reconnectAfterRestart = false
    /// Permission timing is about a press, not whether the connection succeeded. Skipping Windows
    /// App and finishing setup must not trigger the first network request merely by opening a menu.
    var connectionRequested = false
    var defersNetworkProbe: Bool { answers.started && !connectionRequested }

    /// How much of a long install's output the card keeps: enough to see it moving and to read the
    /// last thing Homebrew said when it stops, without the card growing for ten minutes.
    static let keptLines = 8

    /// The last step this build of the window has. Every step after it is a placeholder that says
    /// where that part is done for now (`SetupCopy.notBuiltYet`), and the welcome promises only this
    /// much (`SetupCopy.Welcome.body(lastBuilt:)`). Moves on as each step's commit lands.
    static let lastBuilt: WizardStep = .finish

    /// The state once `event` has happened. Pure.
    ///
    /// A snapshot never moves the window forward, only back to a step that came undone
    /// (`SetupFlow.landing`), and the window's answers always win over the ones a snapshot carries:
    /// the runner hands back what it was last told, which a press since may have changed.
    func applying(_ event: SetupRunner.Event) -> SetupWindowState {
        var next = self
        switch event {
        case .started(let flight), .refreshing(let flight):
            next.inFlight = flight
            next.refusal = nil
            if flight.work == .trustCertificate {
                // Retrying is a new choice, not "still skipped" if this attempt fails. Only an
                // accepted job clears Skip; a refused button press preserves the user's choice.
                next.answers.leftAlone.remove("H7")
                next.facts?.answers = next.answers
            }
            // A read keeps the lines it follows: re-reading after a failed install mustn't wipe
            // Homebrew's last words off the card that explains the failure.
            if !flight.work.isRead {
                next.lines = []
                next.linesStarted = flight.started
            }
        case .progressed(let flight):
            next.inFlight = flight
            if !flight.work.isRead, let line = flight.line {
                next.lines = SetupWindowState.adding(line, to: next.lines)
            }
        case .ended(let ending):
            next.inFlight = nil
            next.lastEnding = ending
            // The ending's own record of what the work said is the whole of it, where the window's may
            // have a gap: it may have been reopened part way through.
            if !ending.work.isRead { next.takeLines(of: ending) }
            // "Winbar is still installing UTM…" is untrue from here on.
            next.refusal = nil
            next = next.landing(ending.facts)
            next.settleAfterInstall(readAt: ending.started)
            next.moveOn(after: ending)
            if ending.work == .connect {
                next.answers.connectionOpened = ending.outcome == .finished
                next.answers.connected = (ending.outcome == .finished || ending.outcome == .overtaken) ? nil : false
            }
            if ending.work == .applyChanges, ending.outcome == .finished, next.answers.connected == true {
                next.answers.connected = nil
                next.answers.connectionOpened = false
                next.reconnectAfterRestart = true
                next.step = .connect
            }
            next.facts?.answers = next.answers
        case .stale:
            // A fresh snapshot follows once the queue is free (`.refreshed`); nothing to redraw yet.
            break
        case .refreshed(let facts):
            if next.inFlight?.work.isRead == true { next.inFlight = nil }
            next.refusal = nil
            next = next.landing(facts)
            next.settleAfterInstall(readAt: facts.stamp?.taken)
        }
        return next
    }

    /// Takes `facts`, and goes back to the first step that came undone, if one before this one did —
    /// except while the create views are step 2's body: they are the step's work in flight, and a
    /// snapshot taking the window off them (UTM went quiet for a moment mid-install) would hide an
    /// install the person is watching. They hand back when they're done, and landing resumes then.
    func landing(_ facts: SetupFlow.Facts) -> SetupWindowState {
        var next = self
        var facts = facts
        if let oldID = self.facts?.target, oldID != facts.target {
            // Confirmation, skips and staged choices describe a particular Windows installation.
            // A desktop opened for one VM never authorizes removing a different VM's screen.
            next.answers = SetupFlow.Answers()
            next.answers.started = answers.started
            next.finished = false
            next.secretEpoch += 1
            if !creating { next.step = .vm }
        }
        next.answers = next.answers.forVM(facts.target)
        facts.answers = next.answers
        next.facts = facts
        if !creating { next.step = SetupFlow.landing(on: next.step, facts) }
        return next
    }

    /// Where the window goes once the install shown here has ended well and the Mac has been read
    /// again: step 3 when step 2 is done — the new VM chosen and running — and step 2 otherwise, whose
    /// own screen then says why (the new VM wasn't made the one Winbar looks after, it has stopped,
    /// UTM lost it). Pure.
    static func stepAfterInstall(_ facts: SetupFlow.Facts, expectedID: String?) -> WizardStep {
        if case .ready(let vm) = SetupFlow.vm(facts), vm.id == expectedID { return .tune }
        return .vm
    }

    /// Settles `afterInstall` with the facts just taken, when they were read after the install ended
    /// (`readAt`, nil for a snapshot the runner didn't take): only those can say whether step 2 is done.
    private mutating func settleAfterInstall(readAt: Date?) {
        guard let since = afterInstall, let readAt, readAt >= since, let facts else { return }
        afterInstall = nil
        if step == .vm { step = SetupWindowState.stepAfterInstall(facts, expectedID: installedVMID) }
    }

    /// **Use “…”** and **Start It** are presses to settle step 2, so when one ends with the chosen VM
    /// running the window moves on, rather than asking for a **Continue** that says nothing new. A
    /// chosen VM that's stopped stays on step 2, which then offers **Start It**.
    private mutating func moveOn(after ending: SetupRunner.Ending) {
        guard step == .vm, ending.outcome == .finished, let facts else { return }
        switch ending.work {
        case .chooseVM, .startVM:
            if case .ready(let vm) = SetupFlow.vm(facts), installedVMID == nil || installedVMID == vm.id { step = .tune }
        default:
            break
        }
    }

    /// What a window arriving at the runner is handed (`SetupRunner.attach`): the work in flight, the
    /// newest snapshot, and how the last piece of work ended. Pure.
    ///
    /// A window closed while its work ran heard none of what happened next, so each is folded in here:
    /// an ending it didn't hear replaces the one it holds (an install that failed while it was closed
    /// shows as failed, with that failure's reason, not the one before it), and brings that run's
    /// output with it — including what it said after the window closed, which is where a failure's
    /// own lines are. For work still running, lines from another run are dropped rather than shown
    /// under it; lines from the same run are kept, and the flight's newest line joins them.
    func attached(inFlight: SetupRunner.InFlight?, latest: SetupFlow.Facts?,
                  lastEnded: SetupRunner.Ending? = nil) -> SetupWindowState {
        var next = self
        if let lastEnded, lastEnded != lastEnding {
            next = next.applying(.ended(lastEnded))
        }
        next.inFlight = nil
        if let inFlight {
            if !inFlight.work.isRead { next.keepLines(of: inFlight.started) }
            next = next.applying(.progressed(inFlight))
        }
        // The runner's newest snapshot is never older than its last ending's: both are stored together.
        if let latest {
            next = next.landing(latest)
            next.settleAfterInstall(readAt: latest.stamp?.taken)
        }
        return next
    }

    /// Keeps `lines` only if they came from the run that began at `started`.
    private mutating func keepLines(of started: Date) {
        guard linesStarted != started else { return }
        lines = []
        linesStarted = started
    }

    /// Shows what `ending`'s work said, all of it: the runner kept it the same way (`adding`).
    private mutating func takeLines(of ending: SetupRunner.Ending) {
        lines = ending.lines
        linesStarted = ending.started
    }

    /// `lines` with `line` said after them, as the install's card keeps them: no line twice in a row,
    /// the download's count updating its own line rather than pushing everything else off the card
    /// (it comes once a second), and only the newest `keptLines`. Pure. The runner keeps each work's
    /// output through this too (`SetupRunner.Job.say`), so the lines an ending hands a window are the
    /// ones it would have kept had it been watching.
    static func adding(_ line: String, to lines: [String]) -> [String] {
        guard line != lines.last else { return lines }
        var lines = lines
        if let last = lines.last, isDownloadCount(last), isDownloadCount(line) { lines.removeLast() }
        return Array((lines + [line]).suffix(keptLines))
    }

    /// Whether `line` is the download's running count (`DependencyCopy.downloadProgress`, "UTM: 12 of
    /// 250 MB (4%)"), recognised by its own function's output so the two can't drift. Pure.
    static func isDownloadCount(_ line: String) -> Bool {
        [Dependency.utm, .windowsApp].contains { dependency in
            let prefix = DependencyCopy.downloadProgress(dependency, done: 0, total: 0)
                .prefix { $0 != ":" } + ": "
            guard line.hasPrefix(prefix) else { return false }
            return line.dropFirst(prefix.count).first?.isNumber == true && line.contains(" MB")
        }
    }

    /// How far a download has got, in megabytes, as the install card's bar shows it.
    struct DownloadCount: Equatable {
        var done: Int
        var total: Int
        var fraction: Double { total > 0 ? min(1, Double(done) / Double(total)) : 0 }
    }

    /// The count in `line`, when it is the download's count and says how big the whole is: read by
    /// matching `DependencyCopy.downloadProgress`'s own output around two numbers, so a change to its
    /// wording breaks this test rather than the bar. nil for any other line, and for a count with no
    /// total ("UTM: 7 MB"), which a bar can't show. Pure.
    static func downloadCount(_ line: String) -> DownloadCount? {
        for dependency in [Dependency.utm, .windowsApp] {
            // Megabyte figures no real download says, so they can't be confused with the words around them.
            let sample = DependencyCopy.downloadProgress(dependency, done: 111_111 << 20, total: 222_222 << 20)
            guard let doneRange = sample.range(of: "111111"), let totalRange = sample.range(of: "222222") else { continue }
            let head = String(sample[..<doneRange.lowerBound])
            let middle = String(sample[doneRange.upperBound..<totalRange.lowerBound])
            let tail = sample[totalRange.upperBound...].prefix { $0 != "(" }
            guard line.hasPrefix(head) else { continue }
            let rest = line.dropFirst(head.count)
            let done = rest.prefix { $0.isNumber }
            let afterDone = rest.dropFirst(done.count)
            guard !done.isEmpty, afterDone.hasPrefix(middle) else { continue }
            let totalPart = afterDone.dropFirst(middle.count)
            let total = totalPart.prefix { $0.isNumber }
            guard !total.isEmpty, totalPart.dropFirst(total.count).hasPrefix(tail),
                  let doneMB = Int(done), let totalMB = Int(total), totalMB > 0 else { continue }
            return DownloadCount(done: doneMB, total: totalMB)
        }
        return nil
    }

    /// Where **Back** goes: the step before, which on step 1 is the welcome. Going back changes
    /// nothing that has happened (§2).
    static func back(from step: WizardStep) -> WizardStep {
        let all = WizardStep.allCases
        guard let index = all.firstIndex(of: step), index > 0 else { return .welcome }
        return all[index - 1]
    }
}

extension SetupRunner.Work {
    /// A read (`checkAgain`), whose only product is the snapshot after it.
    var isRead: Bool {
        if case .checkAgain = self { return true }
        return false
    }
}

// MARK: - When the window opens by itself, and what closing it means

extension SetupWindowController {
    /// Whether the window opens by itself at launch (§2.1): when it is offered to everyone
    /// (`SetupWindow.availableToEveryone`), on a Mac where it was never put away,
    /// where no VM has been chosen, and where no install is running — and not when the launch was
    /// asked to open a window already (`winbar create --window`, `winbar setup --window`). Pure.
    ///
    /// The VM clause is this commit's, not the spec's. The spec's rule opened it for everyone whose
    /// setting was empty, which is every Mac that set Winbar up before the window existed: an update
    /// would greet each of them with a welcome to something they finished long ago. A chosen VM is
    /// the plainest sign of a Mac that isn't new, and **Set Up Winbar…** is in the menu for anyone
    /// who wants it anyway.
    static func opensByItself(available: Bool = SetupWindow.availableToEveryone, shown: Bool, vmChosen: Bool,
                              installRunning: Bool, askedForWindow: Bool) -> Bool {
        available && !shown && !vmChosen && !installRunning && !askedForWindow
    }

    /// Whether closing the window puts it away for good, the way **Not Now** does: before **Start**,
    /// where the red button is the Mac's own "not now", and past the last step this build has, where
    /// the window has done all it can (its **Close** does the same). Anywhere else closing is never
    /// cancelling (§2.4): the wizard keeps its place. Pure.
    static func dismissesOnClose(_ state: SetupWindowState) -> Bool {
        (state.step == .welcome && !state.answers.started) || state.step > SetupWindowState.lastBuilt
    }

    /// What quitting Winbar asks first while the window's long work runs (§2.4), or nil when nothing
    /// needs asking. Long work is the work that holds the Mac awake — here, UTM's install — which
    /// quitting would leave half done. Pure.
    static func quitQuestion(_ inFlight: SetupRunner.InFlight?) -> AttributedString? {
        guard let inFlight, inFlight.work.holdsMacAwake else { return nil }
        return SetupCopy.Quitting.body(doing: SetupCopy.Working.doing(inFlight))
    }
}

// MARK: - Step 1, as rows, a card and buttons

/// Step 1's page, from the window's state. Pure: the rows read H1, UTM's VM list and C1 from the
/// snapshot (the same words `winbar doctor` uses), and the card and buttons follow `SetupFlow.lookAround`.
enum LookAroundPage {
    struct Row: Equatable {
        var mark: CreateProgress.Mark
        var title: String
        var detail: String?
    }

    /// What the card under the rows says.
    enum Card: Equatable {
        /// Nothing yet, or nothing left to say.
        case none
        // Every card says its one point once, in its heading; the row above it keeps to its mark, or a
        // few words the card doesn't repeat (the review found rows and cards saying the same thing
        // twice, and failures quieter than successes, their titles only in a grey row detail).

        /// UTM missing, too old or not the real thing: the heading (`needsHeading`), what that means
        /// (`needsLead`), the plan's paragraphs, and the question the install button answers (nil when
        /// there's no button).
        case needsUTM(heading: String, lead: String?, plan: [String], question: String?)
        /// UTM's install, running: its output so far, without the download's counts, which are the
        /// bar's (`download`, while the download is the newest thing said). `update`: Homebrew is
        /// replacing a copy that's too old, which the heading says rather than "installing".
        case installing(lines: [String], update: Bool, download: SetupWindowState.DownloadCount?)
        /// The install stopped. No Armie here, and no joke: what went wrong as the heading, Homebrew's
        /// last words, and what to do.
        case installFailed(SetupRunner.Problem, lines: [String], slept: Bool)
        /// Before **Open UTM and Ask**: `SetupCopy.LookAround.askHeading` and what follows it.
        /// `quarantined`: UTM carries the "downloaded from the internet" mark, so macOS may ask whether
        /// to open it before the Automation question, and the card predicts that too.
        case askUTM(quarantined: Bool)
        /// Waiting for utmctl's first answer, which is where macOS's Automation prompt appears if it
        /// is going to: on a Mac that allowed it long ago, UTM simply answers. `quarantined`: the wait
        /// began by opening a copy with the mark, so macOS's open question can land in it too.
        case settling(quarantined: Bool)
        /// utmctl said nothing (how long on the row): what to do about it, which depends on whether
        /// macOS has an answer on file (`SetupCopy.LookAround.silent`).
        case silent(consent: Automation.Consent, quarantined: Bool)
        /// Automation refused: `Automation.deniedError`'s title, and where to turn it back on.
        case denied(heading: String)
        /// utmctl answered with an error (its own words on the row).
        case utmFailed
        /// UTM wouldn't list its VMs.
        case listFailed(heading: String, detail: String)

        /// What the card says first, as its heading: its one point. nil only for no card.
        var heading: String? {
            switch self {
            case .none: return nil
            case .needsUTM(let heading, _, _, _), .denied(let heading), .listFailed(let heading, _): return heading
            case .installing(_, let update, _): return SetupCopy.LookAround.installing(update: update)
            case .installFailed(let problem, _, _): return problem.title
            case .askUTM: return SetupCopy.LookAround.askHeading
            case .settling: return SetupCopy.LookAround.settleHeading
            case .silent: return SetupCopy.LookAround.silentHeading
            case .utmFailed: return SetupCopy.LookAround.utmFailedHeading
            }
        }
    }

    enum Action: Equatable {
        case run(SetupRunner.Work)
        case openAutomationSettings
        /// On to step 2.
        case next
    }

    struct Button: Equatable {
        var title: String
        var action: Action
        var enabled = true
    }

    struct Page: Equatable {
        var rows: [Row]
        var card: Card
        /// The default button: Return presses it.
        var primary: Button?
        var secondary: Button?
    }

    /// Who macOS names in the Automation prompt. The window only ever runs as Winbar.app.
    static let host = (name: "Winbar", bundleID: Optional(Config.appBundleID))

    static func page(_ state: SetupWindowState, lastBuilt: WizardStep = SetupWindowState.lastBuilt) -> Page {
        var page = screen(state, lastBuilt: lastBuilt)
        // A read in flight (Check Again, or the read after Start) greys the buttons out; without
        // something moving, the page looked broken. The first row the read can still change spins.
        // Windows App's row is left alone: nothing on this step acts on it.
        if state.inFlight?.work.isRead == true,
           let index = page.rows.prefix(2).firstIndex(where: { $0.mark != .done }) {
            page.rows[index].mark = .running
        }
        return page
    }

    private static func screen(_ state: SetupWindowState, lastBuilt: WizardStep) -> Page {
        let flight = state.inFlight
        let idle = flight == nil
        let work = flight?.work
        let latest = state.lines.last ?? flight?.line
        let utmTitle = SetupCopy.LookAround.rowUTM
        let vmsTitle = SetupCopy.LookAround.rowVMs

        guard let facts = state.facts else {
            // The first look hasn't come back: the rows are what's being looked at.
            let mark: CreateProgress.Mark = idle ? .pending : .running
            return Page(rows: [Row(mark: mark, title: utmTitle), Row(mark: .pending, title: vmsTitle),
                               Row(mark: .pending, title: SetupCopy.LookAround.rowWindowsApp)],
                        card: .none, primary: nil, secondary: nil)
        }
        let h1 = facts.rows["H1"]?.detail
        let windowsApp = windowsAppRow(facts, lastBuilt: lastBuilt)
        let screen = SetupFlow.lookAround(facts)

        // Work of step 1's own in flight comes first: it's what the person is watching. Neither has a
        // button while it runs: the only one there could be is the work itself, greyed out.
        // The install's card shows its output as it comes, so the row doesn't repeat the last line;
        // and there's no button, since the only thing to press would be the install itself.
        if work == .installUTM {
            let lines = state.lines.isEmpty ? latest.map { [$0] } ?? [] : state.lines
            return Page(rows: [Row(mark: .running, title: utmTitle), Row(mark: .pending, title: vmsTitle), windowsApp],
                        card: .installing(lines: lines.filter { !SetupWindowState.isDownloadCount($0) },
                                          update: utmPlan(facts)?.isUpdate == true,
                                          download: lines.last.flatMap(SetupWindowState.downloadCount)),
                        primary: nil, secondary: nil)
        }
        if work == .settleUTM {
            return Page(rows: [Row(mark: .running, title: utmTitle, detail: SetupCopy.LookAround.asking(flight?.line)),
                               Row(mark: .pending, title: vmsTitle), windowsApp],
                        card: .settling(quarantined: facts.utmQuarantined), primary: nil, secondary: nil)
        }

        let checkAgain = Button(title: SetupCopy.bCheckAgain, action: .run(.checkAgain(.lookAround)), enabled: idle)
        let tryAgain = Button(title: SetupCopy.bTryAgain, action: .run(.settleUTM), enabled: idle)
        let pendingVMs = Row(mark: .pending, title: vmsTitle)

        switch screen {
        case .needsUTM(let dependencyState):
            if let ending = state.lastEnding, ending.work == .installUTM, case .failed(let problem) = ending.outcome {
                return Page(rows: [Row(mark: .failed, title: utmTitle), pendingVMs, windowsApp],
                            card: .installFailed(problem, lines: state.lines, slept: ending.slept),
                            primary: Button(title: SetupCopy.bTryAgain, action: .run(.installUTM), enabled: idle),
                            secondary: nil)
            }
            let plan = utmPlan(facts)
            let actionable = SetupRunner.actionable(plan)
            let mark: CreateProgress.Mark
            if case .wrongSignature = dependencyState { mark = .failed } else { mark = .attention }
            var paragraphs = plan.map { SetupCopy.LookAround.plan($0, state: dependencyState) } ?? []
            if plan?.isUpdate == true { paragraphs.append(SetupCopy.LookAround.updateMayAsk(host: host.name)) }
            // The row is only its mark: "not installed; setup can download it…" said the heading's news
            // in the terminal's words, and "setup" read as the command.
            return Page(rows: [Row(mark: mark, title: utmTitle), pendingVMs, windowsApp],
                        card: .needsUTM(heading: SetupCopy.LookAround.needsHeading(dependencyState),
                                        lead: SetupCopy.LookAround.needsLead(dependencyState),
                                        plan: paragraphs,
                                        question: actionable ? plan.map { DependencyCopy.question(.utm, $0) } : nil),
                        primary: actionable ? installButton(facts, enabled: idle) : checkAgain, secondary: nil)
        case .askUTM:
            return Page(rows: [Row(mark: .pending, title: utmTitle, detail: h1), pendingVMs, windowsApp],
                        card: .askUTM(quarantined: facts.utmQuarantined),
                        primary: Button(title: SetupCopy.LookAround.bOpenUTMAndAsk, action: .run(.settleUTM), enabled: idle),
                        secondary: nil)
        case .utmSilent(let seconds, let consent, let quarantined):
            // With an answer on file, the switch is in System Settings, so that page is a button too.
            let settings = consent == .decided
                ? Button(title: SetupCopy.LookAround.bOpenAutomationSettings, action: .openAutomationSettings) : nil
            return Page(rows: [Row(mark: .attention, title: utmTitle, detail: SetupCopy.LookAround.silentRow(seconds: seconds)),
                               pendingVMs, windowsApp],
                        card: .silent(consent: consent, quarantined: quarantined),
                        primary: tryAgain, secondary: settings)
        case .utmDenied:
            let denied = Automation.deniedError(for: host)
            return Page(rows: [Row(mark: .attention, title: utmTitle), pendingVMs, windowsApp],
                        card: .denied(heading: denied.title),
                        primary: tryAgain,
                        secondary: Button(title: SetupCopy.LookAround.bOpenAutomationSettings, action: .openAutomationSettings))
        case .utmFailed(let detail):
            return Page(rows: [Row(mark: .failed, title: utmTitle, detail: "utmctl: \(detail)"), pendingVMs, windowsApp],
                        card: .utmFailed, primary: tryAgain, secondary: nil)
        case .listVMs:
            return Page(rows: [Row(mark: .done, title: utmTitle, detail: h1),
                               Row(mark: idle ? .pending : .running, title: vmsTitle), windowsApp],
                        card: .none, primary: checkAgain, secondary: nil)
        case .listFailed(let failure):
            return Page(rows: [Row(mark: .done, title: utmTitle, detail: h1),
                               Row(mark: .failed, title: vmsTitle), windowsApp],
                        card: .listFailed(heading: failure.title, detail: failure.detail),
                        primary: checkAgain,
                        secondary: failure.automationDenied
                            ? Button(title: SetupCopy.LookAround.bOpenAutomationSettings, action: .openAutomationSettings) : nil)
        case .done:
            var count = 0
            if case .listed(let list) = facts.vms { count = list.count }
            return Page(rows: [Row(mark: .done, title: utmTitle, detail: h1),
                               Row(mark: .done, title: vmsTitle, detail: SetupCopy.LookAround.vmCount(count)), windowsApp],
                        card: .none,
                        primary: Button(title: SetupCopy.LookAround.bContinue, action: .next, enabled: idle),
                        secondary: nil)
        }
    }

    /// The plan the window carries out for UTM, from the snapshot: the same one the runner judges the
    /// press against and the machine carries out.
    private static func utmPlan(_ facts: SetupFlow.Facts) -> InstallPlan? {
        Dependencies.windowPlan(for: .utm, state: facts.utm, brew: facts.homebrew, brewHasCask: facts.utmFromHomebrew)
    }

    /// The button that installs UTM, in the words of the plan the window will carry out.
    private static func installButton(_ facts: SetupFlow.Facts, enabled: Bool) -> Button? {
        guard let plan = utmPlan(facts), let title = SetupCopy.LookAround.bInstall(.utm, plan) else { return nil }
        return Button(title: title, action: .run(.installUTM), enabled: enabled)
    }

    /// Windows App's row. Nothing on step 1 acts on it (§2.3): missing is said and left for later —
    /// the saved-PC step once the window has one, `winbar setup` until then.
    private static func windowsAppRow(_ facts: SetupFlow.Facts, lastBuilt: WizardStep) -> Row {
        let title = SetupCopy.LookAround.rowWindowsApp
        guard let c1 = facts.rows["C1"] else { return Row(mark: .pending, title: title) }
        if c1.kind == .ok { return Row(mark: .done, title: title, detail: c1.detail) }
        if case .missing = facts.windowsApp {
            return Row(mark: .pending, title: title, detail: SetupCopy.LookAround.windowsAppLater(lastBuilt: lastBuilt))
        }
        return Row(mark: .attention, title: title, detail: c1.detail)
    }

    /// What Armie says, or nil when he isn't there. He appears on one thing in steps 0 and 1: UTM's
    /// install while it runs, which is minutes of nothing to do (§2b). Not on the welcome, which is a
    /// decision; not on the Automation prompt or anything after it, which is a permission; not on an
    /// update, where Homebrew quitting UTM can raise that same prompt in the middle; never once the
    /// install has failed, since his line comes only from work in flight; and never once he's been
    /// hidden. Pure.
    static func armieLine(_ state: SetupWindowState) -> String? {
        guard !state.armieHidden, state.step == .lookAround, state.inFlight?.work == .installUTM,
              let facts = state.facts, utmPlan(facts)?.isUpdate != true else { return nil }
        return SetupCopy.Armie.line(.installingUTM)
    }

    /// A card's words, in `CardText`'s order, for every card that is only words; nil for no card, and
    /// for the install and its failure, which draw its output too. Pure, so the tests can read every
    /// word a screen says rather than only the renders.
    static func cardText(_ card: Card) -> CardText? {
        let heading = card.heading ?? ""
        switch card {
        case .none, .installing, .installFailed:
            return nil
        case .needsUTM(_, let lead, let plan, let question):
            return CardText(heading: heading, lead: lead.map { AttributedString($0) },
                            paragraphs: plan.map { AttributedString($0) },
                            emphasis: question.map { AttributedString($0) })
        case .askUTM(let quarantined):
            return CardText(heading: heading,
                            paragraphs: [SetupCopy.markdown(SetupCopy.LookAround.askBody)],
                            emphasis: SetupCopy.markdown(SetupCopy.LookAround.askInstruction(host: host.name,
                                                                                             quarantined: quarantined)),
                            aside: AttributedString(SetupCopy.LookAround.askAside(quarantined: quarantined)))
        case .settling(let quarantined):
            // The open question first, as macOS asks it: UTM has to be running to be asked anything.
            let control = SetupCopy.Working.whereToLook(.automationPrompt, host: host.name)
            return CardText(heading: heading,
                            paragraphs: [SetupCopy.markdown(quarantined ? SetupCopy.LookAround.settleOpen + " " + control
                                                                        : control)])
        case .silent(let consent, let quarantined):
            return CardText(heading: heading,
                            paragraphs: [SetupCopy.markdown(SetupCopy.LookAround.silent(consent: consent, host: host.name))],
                            aside: quarantined ? SetupCopy.markdown(SetupCopy.LookAround.quarantineAside) : nil)
        case .denied:
            return CardText(heading: heading, paragraphs: [SetupCopy.markdown(SetupCopy.LookAround.denied(host: host.name))])
        case .utmFailed:
            return CardText(heading: heading, paragraphs: [SetupCopy.markdown(SetupCopy.LookAround.utmFailed)])
        case .listFailed(_, let detail):
            return CardText(heading: heading, paragraphs: [AttributedString(detail)])
        }
    }
}

// MARK: - Where Armie is, and what he says there

/// Armie on one screen: the line he says and the clip he says it with. Every placement is decided
/// here, from the state the screen is drawn from, through `SetupCopy.Armie`'s helpers, so §2b's
/// rules are kept in one place rather than once per view. Pure.
struct ArmieCue: Equatable {
    var line: String
    var clip: ArmieArt.Clip

    /// Where he is on the window's own pages, or nil where he isn't:
    ///
    /// - Step 1, UTM's install (`LookAroundPage.armieLine`, which says why nowhere else there).
    /// - Step 2, the empty state before any VM exists, and the wait after **Start It**.
    /// - The done screen, after Connect was answered **Yes**, with the done clip.
    ///
    /// Nowhere else. The welcome is a decision; tune, the certificate, the saved PC and Connect each
    /// have a permission, a password field or a question on them; and the install's own views are
    /// `installing(_:)`'s. Hide Armie ends all of them, for good.
    static func cue(_ state: SetupWindowState) -> ArmieCue? {
        guard !state.armieHidden else { return nil }
        switch state.step {
        case .lookAround: return LookAroundPage.armieLine(state).map { ArmieCue(line: $0, clip: .working) }
        case .vm: return vm(state)
        case .finish: return done(state)
        case .welcome, .tune, .certificate, .savedPC, .connect: return nil
        }
    }

    /// Step 2's two moments with nothing to do. Only on the step's own page — not "Looking at the new
    /// VM…" after an install, not while the install's views are the step — and only while that page
    /// shows no problem: a failed piece of work's line, or install notes that would have silenced him
    /// during the install (`SetupCopy.Armie.silences`). Step 2 shows those notes in full, as cards,
    /// so a note that ended his narration of the install ends it here too.
    private static func vm(_ state: SetupWindowState) -> ArmieCue? {
        guard !state.creating, state.afterInstall == nil, let facts = state.facts,
              !state.installMessages.contains(where: { SetupCopy.Armie.silences($0.code) }) else { return nil }
        if case .failed? = state.lastEnding?.outcome { return nil }
        if let flight = state.inFlight, case .startVM = flight.work {
            // `Setup.waitForWindows` says `agentNotYet` when its three minutes run out, and says nothing
            // after it; the window keeps the run's lines, so either place can hold it — the flight's
            // newest line, or the kept lines of a window that was reopened part way.
            let timedOut = flight.line == SetupCopy.agentNotYet || state.lines.contains(SetupCopy.agentNotYet)
            return SetupCopy.Armie.startingLine(timedOut: timedOut).map { ArmieCue(line: $0, clip: .working) }
        }
        // A read (Check Again) keeps him: it changes nothing, and a figure that blinked out on every
        // read would be animating for the sake of it. Any other work is not the empty state's.
        if let flight = state.inFlight, !flight.work.isRead { return nil }
        // "No Windows here yet" is the empty state before a VM exists. With `previous` set, one did:
        // UTM no longer has the VM Winbar was looking after, which is news, not dead time.
        guard case .choose(.none, previous: nil) = SetupVMView.screen(state, facts) else { return nil }
        return ArmieCue(line: SetupCopy.Armie.line(.noVM), clip: .working)
    }

    /// The done screen. Only once the window is finished and Connect was answered **Yes**
    /// (`doneLine(connected:)`), and not beside a failure or an overtaken piece of work still on
    /// screen above it — Keep the Screen after a failed Go Headless finishes without new work, so
    /// that failure's card stays up. Not held to reads in flight: one can start on this screen by
    /// itself (a wake), and removing him for it would replay the hop when it ended.
    private static func done(_ state: SetupWindowState) -> ArmieCue? {
        guard state.finished, let facts = state.facts else { return nil }
        switch state.lastEnding?.outcome {
        case .failed?, .overtaken?: return nil
        case .finished?, .cancelled?, nil: break
        }
        return SetupCopy.Armie.doneLine(connected: facts.answers.connected).map { ArmieCue(line: $0, clip: .done) }
    }

    /// The install's own views while they are step 2 (`ArmieHost`): the stage's line while the install
    /// is going well (`SetupCopy.Armie.line(for:)`, nil for a failure, a stall or a note that silences
    /// him). Also nil while macOS asks whether Winbar may control UTM, which the job says in the
    /// running row: that is a permission, and he isn't beside one (step 1 keeps him off the same
    /// prompt). Pure.
    static func installing(_ job: CreateJobState) -> ArmieCue? {
        guard CreateProgress.detail(job.detail) != CreateCopy.pAutomation else { return nil }
        return SetupCopy.Armie.line(for: job).map { ArmieCue(line: $0, clip: .working) }
    }
}

/// What the wizard lends the New Windows VM views while they are its step 2, so Armie can narrate
/// the install there: his art, and the window's `send`, so **Hide Armie** is the wizard's own and is
/// remembered. The views belong to `CreateWindowController`, which knows nothing of the wizard's
/// settings, so this is the only way he reaches them — and the New Windows VM window of their own is
/// never lent one.
struct ArmieHost {
    let art: ArmieArt
    let send: (SetupCommand) -> Void

    /// The host for a window drawn from `state`, or nil when he's been hidden or the bundle has no
    /// art for him. Pure.
    static func lent(_ state: SetupWindowState, art: ArmieArt?, send: @escaping (SetupCommand) -> Void) -> ArmieHost? {
        guard !state.armieHidden, let art else { return nil }
        return ArmieHost(art: art, send: send)
    }
}

// MARK: - What a press asks for

/// Everything a view can ask the window to do.
enum SetupCommand: Equatable {
    case notNow
    case start
    case back
    case perform(LookAroundPage.Action)
    case hideArmie
    /// The placeholder's **New Windows VM…**: the create window, as the menu item opens it.
    case newWindowsVM
    case pickVM(String)
    case useVM(name: String, id: String)
    case startVM(String)
    case continueFromVM
    case next
    case skip(String)
    case discardChanges(String?)
    case chooseAnotherVM
    case retryConnection
    case retrySavedPC
    case continueWithoutSavedPC
    case connected(Bool)
    case stopWaiting
    case quitWindowsApp
    case reportProblem
    case finish
    /// The placeholder's **Close**: this build's window has done what it can.
    case closeForNow
}

// MARK: - The settings the window reads and writes

/// The two global settings the window touches, as functions, so a test can hand it its own.
struct SetupSettings {
    var wizardShown: () -> Bool
    var markShown: () -> Void
    var armieHidden: () -> Bool
    var hideArmie: () -> Void

    static let live = SetupSettings(wizardShown: { Config.setupWizardShown },
                                    markShown: { Config.setupWizardShown = true },
                                    armieHidden: { Config.armieHidden },
                                    hideArmie: { Config.armieHidden = true })
}

// MARK: - The window

final class SetupCredentials: ObservableObject {
    @Published var password = ""
    func clear() { password = "" }
}

final class SetupWindowController: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = SetupWindowController()
    static weak var presented: SetupWindowController?
    private(set) var isPresented = false
    static var coordinatesVM: Bool {
        guard let controller = presented else { return false }
        return controller.runner?.inFlight != nil
            || (controller.isPresented && !controller.state.creating && controller.state.answers.started && !controller.state.finished)
    }
    static var menuNote: String? {
        guard let controller = presented, controller.isPresented, !controller.state.creating,
              controller.state.answers.started, !controller.state.finished else { return nil }
        return "Set Up Winbar is open"
    }
    static var defersNetworkProbe: Bool {
        guard let controller = presented else { return false }
        return (controller.isPresented || controller.runner?.inFlight != nil
                || (controller.state.creating && controller.creator?.hasRunningJob == true))
            && controller.state.defersNetworkProbe
    }
    static func connectionRequested() { presented?.state.connectionRequested = true }

    @Published private(set) var state: SetupWindowState
    /// Armie's art, from the app's bundle; nil where it isn't (then there is no Armie).
    let art: ArmieArt?
    let credentials = SetupCredentials()

    private let settings: SetupSettings
    private let makeRunner: () -> SetupRunner
    private var runner: SetupRunner?
    private var observation: SetupRunner.Observation?
    private var window: NSWindow?

    private let makeCreator: () -> EmbeddableCreate
    private var creator: EmbeddableCreate?
    var embeddedController: CreateWindowController? { creator as? CreateWindowController }

    /// The app only ever has `shared`. The parameters are for tests, which must not reach the Mac's
    /// settings, make the live runner (whose machine asks UTM and Windows things) or open a window.
    init(state: SetupWindowState = SetupWindowState(), art: ArmieArt? = ArmieArt.app, settings: SetupSettings = .live,
         makeRunner: @escaping () -> SetupRunner = { SetupRunner.shared },
         makeCreator: @escaping () -> EmbeddableCreate = { CreateWindowController.shared }) {
        var state = state
        state.armieHidden = state.armieHidden || settings.armieHidden()
        self.state = state
        self.art = art
        self.settings = settings
        self.makeRunner = makeRunner
        self.makeCreator = makeCreator
        super.init()
    }

    /// From the menu, the notification `winbar setup --window` posts, its launch argument, and the
    /// first-run open. Safe to call again: it brings the window forward.
    static func present() { shared.show() }

    private func show() {
        Self.presented = self
        let window = existingWindow()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        attach()
        if state.creating { creator?.hostShown() }
        // Reopened on step 1 with nothing known and nothing running: look. The welcome touches nothing.
        if state.step >= .lookAround, state.facts == nil, state.inFlight == nil { run(.checkAgain(.lookAround)) }
    }

    private func existingWindow() -> NSWindow {
        if let window { return window }
        let content = NSHostingController(rootView: SetupRootView(controller: self))
        // The window owns its size, not SwiftUI; the layout is drawn for 600 pt and scrolls below it.
        content.sizingOptions = []
        let window = SetupNSWindow(contentViewController: content)
        window.title = SetupCopy.winTitle
        // The backdrop runs under the title bar, as Windows 11's Mica does and as plenty of Mac apps'
        // unified title bars do; the traffic lights and the title stay where they always are, so
        // Winbar's name is on every step without a heading of its own saying it again.
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.setContentSize(NSSize(width: 600, height: 620))
        window.contentMinSize = NSSize(width: 600, height: 420)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("winbar-setup")
        self.window = window
        return window
    }

    /// Listens to the runner from now until the window closes: what is in flight, the newest
    /// snapshot, how the last work ended, then every event. Reads nothing by itself. Internal rather
    /// than private so a test can reopen the window's state exactly as `show()` does, without a window.
    func attach() {
        isPresented = true
        guard observation == nil else { return }
        let runner = self.runner ?? makeRunner()
        self.runner = runner
        runner.update(answers: state.answers)
        let attached = runner.attach { [weak self] event in self?.receive(event) }
        observation = attached.observation
        state = state.attached(inFlight: attached.inFlight, latest: attached.latest, lastEnded: attached.lastEnded)
        credentials.clear()
        runner.update(answers: state.answers)
        if state.afterInstall != nil, runner.inFlight == nil { run(.checkAgain(.vm)) }
    }

    /// Runner events arrive on the main queue (`SetupRunner.Environment.live`).
    func receive(_ event: SetupRunner.Event) {
        guard isPresented else { return } // a callback queued just before closing is not a new observer
        let oldStep = state.step
        let oldSecretEpoch = state.secretEpoch
        let waitingForInstall = state.afterInstall != nil
        state = state.applying(event)
        if oldStep != state.step || oldSecretEpoch != state.secretEpoch { credentials.clear() }
        runner?.update(answers: state.answers)
        // Refresh first: the old list cannot contain a VM just created. Select by its returned id,
        // including if UTM renamed it, and never use a same-named replacement or the previous VM.
        if waitingForInstall, state.afterInstall == nil, state.inFlight == nil,
           let id = state.installedVMID, let facts = state.facts, facts.chosen?.id != id,
           case .listed(let list) = facts.vms, let vm = list.first(where: { $0.id == id }) {
            run(.chooseVM(vm.name, id: vm.id))
            return
        }
        if state.step > oldStep, state.step >= .tune, state.inFlight == nil {
            run(.checkAgain(state.step))
        }
    }

    /// Closing is never cancelling: the work carries on, and the runner only marks snapshots stale
    /// until a window attaches again. Closing a welcome nobody started is **Not Now**.
    func windowWillClose(_ notification: Notification) {
        isPresented = false
        if SetupWindowController.dismissesOnClose(state) { settings.markShown() }
        observation?.cancel()
        observation = nil
        credentials.clear()
        state.secretEpoch += 1
        if state.creating {
            creator?.hostClosed()
            if creator?.hasRunningJob != true {
                creator?.unembed()
                state.creating = false
            }
        }
    }

    func send(_ command: SetupCommand) {
        switch command {
        case .notNow:
            settings.markShown()
            window?.performClose(nil)
        case .start:
            attach()
            state.answers.started = true
            state.step = .lookAround
            // The answers go with the read, so the snapshot after it carries Start.
            run(.checkAgain(.lookAround))
        case .back:
            guard state.inFlight == nil, !state.creating else { return }
            state.step = SetupWindowState.back(from: state.step)
            state.finished = false
            credentials.clear()
        case .perform(.run(let work)):
            if work == .connect { pressConnect() }
            run(work)
        case .perform(.openAutomationSettings):
            if let url = URL(string: Automation.settingsURL) { NSWorkspace.shared.open(url) }
        case .perform(.next):
            state.step = .vm
        case .hideArmie:
            settings.hideArmie()
            state.armieHidden = true
        case .newWindowsVM:
            guard runner?.inFlight == nil, state.inFlight == nil, !state.creating,
                  state.facts.map({ if case .listed = $0.vms { return $0.utm.isInstalled }; return false }) == true else { return }
            let creator = self.creator ?? makeCreator()
            self.creator = creator
            state.creating = true
            state.step = .vm
            creator.embed(.init(present: { [weak self] in self?.show() },
                                hide: { [weak self] in self?.window?.performClose(nil) },
                                window: { [weak self] in self?.window },
                                finished: { [weak self] in self?.created($0) }))
        case .pickVM(let id):
            state.pickedVM = id
        case .chooseAnotherVM:
            state.pickedVM = nil
            state.choosingAnotherVM = true
        case .useVM(let name, let id):
            state.choosingAnotherVM = false
            state.installedVMID = nil
            if state.facts?.chosen?.id != id {
                state.answers = SetupFlow.Answers()
                state.answers.started = true
                syncAnswers()
            }
            run(.chooseVM(name, id: id))
        case .startVM(let name):
            run(.startVM(name))
        case .continueFromVM:
            if let facts = state.facts, case .ready(let vm) = SetupFlow.vm(facts),
               state.installedVMID == nil || state.installedVMID == vm.id {
                state.step = .tune
                run(.checkAgain(.tune))
            }
        case .next:
            guard state.inFlight == nil, let facts = state.facts, SetupFlow.isSatisfied(state.step, facts),
                  let index = WizardStep.allCases.firstIndex(of: state.step), index + 1 < WizardStep.allCases.count else { return }
            state.step = WizardStep.allCases[index + 1]
            credentials.clear()
            run(.checkAgain(state.step))
        case .skip(let id):
            guard state.inFlight == nil, id != "G0" else { return }
            state.answers.leftAlone.insert(id)
            syncAnswers()
        case .discardChanges(let id):
            guard state.inFlight == nil else { return }
            state.answers.leftAlone.formUnion(id.map { [$0] } ?? ["H3", "H4", "H5"])
            syncAnswers()
            run(.discardChanges(checkID: id))
        case .retryConnection:
            pressConnect()
            state.answers.connected = nil
            state.answers.connectionOpened = false
            syncAnswers()
            run(.connect)
        case .retrySavedPC:
            guard state.step == .savedPC, state.inFlight == nil, runner?.inFlight == nil else { return }
            WindowsAppBookmarks.retryReadCommands()
            run(.checkAgain(.savedPC))
        case .continueWithoutSavedPC:
            guard state.step == .savedPC, state.inFlight == nil,
                  state.facts?.windowsApp.isInstalled == true else { return }
            credentials.clear()
            state.answers.leftAlone.insert("C2")
            syncAnswers()
            send(.next)
        case .connected(let yes):
            guard state.answers.connectionOpened else { return }
            state.answers.connected = yes
            if yes { state.reconnectAfterRestart = false }
            syncAnswers()
            // The recovery card reasons from the port, and what it said when Windows App opened can
            // be minutes old by the time someone answers No (a credentials prompt timing out, Windows
            // restarting for an update). Read it again now. Only when nothing is running: a refusal
            // banner here would be noise, and any read already in flight probes the port too.
            if !yes, state.inFlight == nil, runner?.inFlight == nil { run(.checkAgain(.connect)) }
        case .stopWaiting:
            runner?.stopWaiting()
        case .quitWindowsApp:
            // A normal quit request only; never force-quit a client with someone else's session.
            NSRunningApplication.runningApplications(withBundleIdentifier: Config.windowsAppBundleID).forEach { _ = $0.terminate() }
        case .reportProblem:
            guard state.inFlight == nil else { return }
            (NSApp.delegate as? AppDelegate)?.reportProblem()
        case .finish:
            guard state.inFlight == nil, let facts = state.facts, SetupFlow.isSatisfied(.finish, facts) else { return }
            state.finished = true
            settings.markShown()
        case .closeForNow:
            settings.markShown()
            window?.performClose(nil)
        }
    }

    /// Connect, or its Try Again: the menu's own port probe may run from now on
    /// (`connectionRequested`), and so may the runner's reads (`Answers.connectPressed`), since the
    /// Connect card predicted the Local Network prompt they can raise. Set before the work is handed
    /// to the runner, so the read that ends Connect probes the port as well.
    private func pressConnect() {
        state.connectionRequested = true
        state.answers.connectPressed = true
        syncAnswers()
    }

    private func syncAnswers() {
        state.facts?.answers = state.answers
        runner?.update(answers: state.answers)
    }

    /// The secret is handed directly to one save operation. It is never a command, state or note.
    func savePC(password: String) { credentials.clear(); run(.savePC, password: password) }

    func created(_ end: CreateWindowController.EmbeddedEnd) {
        creator?.unembed()
        state.creating = false
        state.step = .vm
        if case .installed(let id, _, let messages) = end {
            state.answers = SetupFlow.Answers()
            state.answers.started = true
            syncAnswers()
            state.installedVMID = id
            state.installMessages = messages
            state.afterInstall = Date()
        }
        if isPresented { run(.checkAgain(.vm)) }
    }

    /// Only an open window requests new work. A refusal is kept to be said on that window.
    private func run(_ work: SetupRunner.Work, password: String? = nil) {
        guard isPresented else { return }
        guard let runner else { return }
        if let refusal = runner.run(work, password: password, answers: state.answers) { state.refusal = refusal }
    }
}

/// Escape closes the window, which is harmless here (closing never cancels), the way a Mac panel
/// answers it. On the welcome, **Not Now** has Escape first, as the cancel button.
private final class SetupNSWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { performClose(sender) }
}

// MARK: - Views

struct SetupRootView: View {
    @ObservedObject var controller: SetupWindowController

    var body: some View {
        SetupScreen(state: controller.state, art: controller.art,
                    embedded: controller.embeddedController.map { create in
                        { armie in AnyView(CreateRootView(controller: create, armie: armie)) }
                    },
                    credentials: controller.credentials,
                    savePassword: { controller.savePC(password: $0) }) { controller.send($0) }
    }
}

/// The whole window, drawn from a state. Holds nothing of its own.
struct SetupScreen: View {
    let state: SetupWindowState
    let art: ArmieArt?
    /// Step 2's body while `state.creating`: the New Windows VM views, handed the Armie this window
    /// lends them (`ArmieHost.lent`), so hiding him here hides him there on the next draw.
    var embedded: ((ArmieHost?) -> AnyView)? = nil
    var credentials = SetupCredentials()
    var savePassword: (String) -> Void = { _ in }
    let send: (SetupCommand) -> Void

    var body: some View {
        withSetupAppearance { look in
            VStack(spacing: 0) {
                SetupHeader(step: state.step)
                    .frame(maxWidth: SetupStyle.contentWidth)
                    .padding(.horizontal, SetupStyle.pagePadding)
                    .padding(.top, 8)
                    .padding(.bottom, 12)
                if state.creating, let embedded {
                    embedded(ArmieHost.lent(state, art: art, send: send))
                } else {
                GeometryReader { viewport in
                    ScrollView {
                        content
                            .frame(maxWidth: SetupStyle.contentWidth)
                            .padding(.horizontal, SetupStyle.pagePadding)
                            .padding(.top, 2)
                            .padding(.bottom, SetupStyle.pagePadding)
                            // The welcome sits in the middle of the page rather than on top of an empty half.
                            .frame(maxWidth: .infinity, minHeight: viewport.size.height,
                                   alignment: state.step == .welcome ? .center : .top)
                    }
                }
                footer(look)
                }
            }
            .frame(minWidth: 600, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(SetupBackdrop().ignoresSafeArea())
            // The accent a word or a line takes: a bordered button's title is one, and in dark mode the
            // fill blue behind white text is too deep to be read on a dark bezel. The default button
            // is the one filled shape, and takes the fill (`primaryButton`).
            .tint(look.accentText)
        }
    }

    @ViewBuilder private var content: some View {
        switch state.step {
        case .welcome:
            WelcomeView(paragraphs: SetupCopy.Welcome.body(lastBuilt: SetupWindowState.lastBuilt))
        case .lookAround:
            LookAroundView(page: LookAroundPage.page(state), armie: ArmieCue.cue(state)?.line, art: art,
                           refusal: state.refusal, send: send)
        case .vm:
            SetupVMView(state: state, armie: ArmieCue.cue(state), art: art, send: send)
        case .tune, .certificate, .savedPC, .connect, .finish:
            SetupJourneyView(state: state, credentials: credentials, savePassword: savePassword,
                             armie: ArmieCue.cue(state), art: art, send: send)
        }
    }

    private func footer(_ look: SetupAppearance) -> some View {
        HStack(spacing: 10) {
            switch state.step {
            case .welcome:
                Spacer()
                Button(SetupCopy.Welcome.bNotNow) { send(.notNow) }
                    .keyboardShortcut(.cancelAction)
                Button(SetupCopy.Welcome.bStart) { send(.start) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(look.accentFill)
            case .lookAround:
                Button(SetupCopy.bBack) { send(.back) }.disabled(state.inFlight != nil)
                Spacer()
                let page = LookAroundPage.page(state)
                if let secondary = page.secondary {
                    Button(secondary.title) { send(.perform(secondary.action)) }.disabled(!secondary.enabled)
                }
                if let primary = page.primary {
                    Button(primary.title) { send(.perform(primary.action)) }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .tint(look.accentFill)
                        .disabled(!primary.enabled)
                }
            case .vm:
                // Beside Back, not bottom-right: on every other step that corner is the way forward, and
                // here the way forward is the card's own button (Use, Make One, Start It).
                Button(SetupCopy.bBack) { send(.back) }.disabled(state.inFlight != nil)
                Button(SetupCopy.bCheckAgain) { send(.perform(.run(.checkAgain(.vm)))) }
                    .disabled(state.inFlight != nil)
                Spacer()
            default:
                Button(SetupCopy.bBack) { send(.back) }.disabled(state.inFlight != nil)
                Spacer()
                if state.finished {
                    Button(SetupCopy.bClose) { send(.closeForNow) }.keyboardShortcut(.defaultAction)
                } else {
                    Button(SetupCopy.bCheckAgain) { send(.perform(.run(.checkAgain(state.step)))) }.disabled(state.inFlight != nil)
                    let enabled = state.inFlight == nil && state.facts.map { SetupFlow.isSatisfied(state.step, $0) } == true
                    // Continue Without Connecting skips the one step that proves the setup works, so it is
                    // never the filled default; a greyed-out Continue doesn't hold Return either, so the
                    // page's own default (Save It, a failed Connect's retry) gets it.
                    let skipsTheTest = state.step == .connect && state.facts?.answers.connected != true
                    let next = Button(SetupCopy.journeyNext(state.step, facts: state.facts)) {
                        send(state.step == .finish ? .finish : .next)
                    }.disabled(!enabled)
                    if enabled && !skipsTheTest {
                        next.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).tint(look.accentFill)
                    } else {
                        next
                    }
                }
            }
        }
        .controlSize(.large)
        .frame(maxWidth: SetupStyle.contentWidth)
        .padding(.horizontal, SetupStyle.pagePadding)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background {
            // A band, as a Windows 11 dialog's footer is, a shade apart from the page above it.
            ZStack(alignment: .top) {
                look.palette.card.color.opacity(look.reduceTransparency ? 1 : 0.45)
                Rectangle().fill(look.stroke).frame(height: look.increasedContrast ? 1.5 : 1)
            }
        }
    }
}

/// Winbar's mark, the step's name with the counter on its baseline, and the bar of all eight. The
/// window's own name is in its title bar, where a Mac window's name goes, so it is on every step.
struct SetupHeader: View {
    let step: WizardStep

    var body: some View {
        withSetupAppearance { look in
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    // Centred on the title's capitals rather than sitting on its baseline.
                    WinbarMark(size: 22)
                        .alignmentGuide(.firstTextBaseline) { mark in mark[VerticalAlignment.center] + 7 }
                    Text(SetupCopy.stepName(step)).font(.system(size: 20, weight: .semibold))
                    Spacer()
                    Text(SetupCopy.stepCounter(step)).font(.subheadline).foregroundStyle(look.mutedText).monospacedDigit()
                }
                .accessibilityElement(children: .combine)
                StepBar(current: step)
            }
        }
    }
}

/// All eight steps, the current one marked: the window's one progress device. Not clickable: the
/// steps depend on each other, and a wizard that lets you jump ahead is a wizard that lies (§2).
/// VoiceOver reads it as one sentence.
struct StepBar: View {
    let current: WizardStep

    enum Mark: Equatable { case done, current, pending }

    /// The gap between segments.
    static let spacing: CGFloat = 4

    /// Everything before the cursor is done: the window only ever stands on the first step with
    /// something left to do, going back when an earlier one comes undone (`SetupFlow.landing`). Pure.
    static func marks(current: WizardStep) -> [Mark] {
        WizardStep.allCases.map { step in
            step < current ? .done : step == current ? .current : .pending
        }
    }

    /// Each segment's width: all equal, whatever its label, so the bar has one rhythm. Pure.
    static func segmentWidth(total: CGFloat, count: Int = WizardStep.allCases.count) -> CGFloat {
        max(0, (total - spacing * CGFloat(count - 1)) / CGFloat(count))
    }

    var body: some View {
        withSetupAppearance { look in
            GeometryReader { bar in
                let marks = StepBar.marks(current: current)
                let width = StepBar.segmentWidth(total: bar.size.width)
                HStack(alignment: .top, spacing: StepBar.spacing) {
                    ForEach(Array(WizardStep.allCases.enumerated()), id: \.offset) { index, _ in
                        item(SetupCopy.stepBarNames[index], marks[index], look).frame(width: width)
                    }
                }
            }
            .frame(height: 24)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(SetupCopy.stepBarLabel(current))
        }
    }

    /// A segment: its line, and its label centred under it, so the gaps between labels are even
    /// whatever their lengths ("Look around" all but fills its segment).
    private func item(_ name: String, _ mark: Mark, _ look: SetupAppearance) -> some View {
        VStack(alignment: .center, spacing: 5) {
            // A line on the backdrop, so the accent's line-and-word shade, not its fill.
            Capsule()
                .fill(mark == .pending ? Color.primary.opacity(look.increasedContrast ? 0.35 : 0.12) : look.accentText)
                .frame(height: mark == .current ? 4 : 3)
                .opacity(mark == .done && !look.increasedContrast ? 0.55 : 1)
            // 11 pt, on the tinted backdrop: the current step in the accent, done steps in the text
            // colour and the rest in the palette's muted colour (the translucent secondary measured
            // under 4.5:1 there). Done and still to come differ in lightness as well as in the line's
            // hue, so the bar doesn't rely on colour alone. No checkmark: in an equal segment it
            // pushed "Look around" to "Look arou…".
            Text(name)
                .font(.subheadline.weight(mark == .current ? .semibold : .regular))
                .foregroundStyle(mark == .current ? look.accentText : mark == .done ? Color.primary : look.mutedText)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
    }
}

// MARK: Step 0

/// Winbar's mark, large, and what Winbar is, as the opening; then what this window does, how long it
/// takes and what macOS will ask, one line each.
struct WelcomeView: View {
    /// What the welcome promises: `SetupCopy.Welcome.body(lastBuilt:)`.
    let paragraphs: [String]

    var body: some View {
        withSetupAppearance { look in
            VStack(spacing: 24) {
                VStack(spacing: 16) {
                    WinbarMark(size: 64)
                    Text(SetupCopy.Welcome.lead)
                        .font(.system(size: 17, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 440)
                        .fixedSize(horizontal: false, vertical: true)
                }
                SetupCard {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(zip(["macwindow", "clock", "hand.raised"], paragraphs)), id: \.0) { icon, text in
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Image(systemName: icon)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(look.accentText)
                                    .frame(width: 20)
                                    .accessibilityHidden(true)
                                Text(SetupCopy.markdown(text)).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: Step 1

struct LookAroundView: View {
    let page: LookAroundPage.Page
    let armie: String?
    let art: ArmieArt?
    let refusal: SetupRunner.Refusal?
    let send: (SetupCommand) -> Void

    var body: some View {
        withSetupAppearance { look in
            VStack(alignment: .leading, spacing: 14) {
                // First, where a press that changed nothing is explained: at the bottom, in grey, it fell
                // under the footer at the window's size, and the person saw nothing happen.
                if let refusal {
                    RefusalBanner(text: SetupCopy.Working.refusal(refusal.inFlight, host: LookAroundPage.host.name))
                }
                SetupCard {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(page.rows.enumerated()), id: \.offset) { index, row in
                            if index > 0 { Divider() }
                            StepRow(mark: row.mark, title: row.title, detail: row.detail)
                        }
                    }
                }
                // The rows' quieter words in the palette's muted grey, which keeps 4.5:1 on a card.
                .environment(\.quietText, look.mutedText)
                if page.card != .none {
                    SetupCard { card }
                }
            }
        }
    }

    @ViewBuilder private var card: some View {
        // Every card opens on its heading (`Card.heading`), which the tests hold the rows against.
        let heading = page.card.heading ?? ""
        if let text = LookAroundPage.cardText(page.card) {
            text
        } else {
            drawnCard(heading: heading)
        }
    }

    /// The two cards that are more than words: the install while it runs, and its failure.
    @ViewBuilder private func drawnCard(heading: String) -> some View {
        switch page.card {
        case .installing(let lines, _, let download):
            // What is happening first — the heading, the bar, the newest output — and Armie under it,
            // so he never pushes the one live line off the page.
            VStack(alignment: .leading, spacing: 12) {
                Text(heading).font(.headline)
                InstallProgress(download: download)
                if !lines.isEmpty { OutputBox(lines: lines, rows: OutputBox.liveRows) }
                if let armie, let art {
                    Divider()
                    ArmieSays(line: armie, art: art, clip: .working, send: send)
                }
            }
        case .installFailed(let problem, let lines, let slept):
            // The heading is what went wrong; then the output, since Homebrew's failure says "its own
            // output is above", as it is in Terminal; then what to do.
            VStack(alignment: .leading, spacing: 10) {
                Text(heading).font(.headline).fixedSize(horizontal: false, vertical: true)
                if !lines.isEmpty { OutputBox(lines: lines) }
                if !problem.detail.isEmpty {
                    Text(SetupCopy.LookAround.forWindow(problem.detail)).fixedSize(horizontal: false, vertical: true)
                }
                if slept {
                    QuietText(SetupCopy.Working.slept(while: "installing UTM"))
                }
            }
        default:
            EmptyView()
        }
    }
}

/// Why a press did nothing: the runner does one thing at a time and something else is running. A
/// banner over the page, in the text colour, with the accent's tint behind it — it answers something
/// the person just did, so it must be where they look, and it isn't an error.
struct RefusalBanner: View {
    let text: AttributedString

    var body: some View {
        withSetupAppearance { look in
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "hourglass")
                    .foregroundStyle(look.accentText)
                    .accessibilityHidden(true)
                // Plain words: the refusal names the work, and a VM's name can be in it.
                Text(text).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                let shape = RoundedRectangle(cornerRadius: SetupStyle.cardRadius, style: .continuous)
                ZStack {
                    shape.fill(look.palette.card.color)
                    shape.fill(look.accentText.opacity(look.increasedContrast ? 0.14 : 0.1))
                }
                .overlay(shape.strokeBorder(look.accentText.opacity(look.increasedContrast ? 0.9 : 0.35),
                                            lineWidth: look.increasedContrast ? 1.5 : 1))
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// A card's words, in the one order every card uses: a heading that says the point; a lead under it;
/// the body at the normal weight; the one thing the person has to do or decide, set apart in
/// semibold; and an aside, smaller and quieter, for what only some people will want.
struct CardText: View {
    let heading: String
    var lead: AttributedString?
    var paragraphs: [AttributedString] = []
    var emphasis: AttributedString?
    var aside: AttributedString?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(heading).font(.headline).fixedSize(horizontal: false, vertical: true)
            if let lead { Text(lead).fixedSize(horizontal: false, vertical: true) }
            ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                Text(paragraph).fixedSize(horizontal: false, vertical: true)
            }
            if let emphasis { Text(emphasis).fontWeight(.semibold).fixedSize(horizontal: false, vertical: true) }
            if let aside { QuietText(aside) }
        }
    }
}

/// A card's aside: smaller and quieter than the body, in the palette's muted grey rather than the
/// system's secondary label, which is translucent and measured 3.9:1 on a light card (text needs
/// 4.5:1). Used for every quiet line inside a card, so they can't drift apart.
struct QuietText: View {
    let text: AttributedString

    init(_ text: AttributedString) { self.text = text }

    var body: some View {
        withSetupAppearance { look in
            Text(text).font(.callout).foregroundStyle(look.mutedText).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The install's bar: how much of the download has come while Winbar's own download runs (the
/// bytes and the total are known, so the bar says so), and a moving bar the rest of the time —
/// Homebrew says nothing measurable, and neither do the checks and the copy after a download.
///
/// Tinted with the accent's line-and-word shade, as the palette says a line on a surface is. The
/// fill shade is for a filled shape with white on it; as a bar on AppKit's dark track it measured
/// 2.0:1 in dark mode and 1.3:1 under Increase Contrast, under the 3:1 a progress bar needs.
struct InstallProgress: View {
    let download: SetupWindowState.DownloadCount?

    var body: some View {
        withSetupAppearance { look in
            VStack(alignment: .leading, spacing: 4) {
                if let download {
                    ProgressView(value: download.fraction)
                        .tint(look.accentText)
                    Text(SetupCopy.LookAround.downloaded(done: download.done, total: download.total))
                        .font(.caption).foregroundStyle(look.mutedText).monospacedDigit()
                } else {
                    ProgressView().progressViewStyle(.linear).tint(look.accentText)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// Armie and his line, with the one-click way to be rid of him: under what he's narrating, small,
/// and never in the way of it. One view for every placement; `clip` is the only thing a placement
/// changes about him, so the done screen can't grow a second Armie that drifts from this one.
struct ArmieSays: View {
    let line: String
    let art: ArmieArt
    /// The working loop beside a wait, or the done hop, which plays once and holds its last pose
    /// (`ArmieLoop` never restarts the same movie when the view is drawn again).
    let clip: ArmieArt.Clip
    let send: (SetupCommand) -> Void

    var body: some View {
        withSetupAppearance { look in
            HStack(alignment: .center, spacing: 12) {
                ArmieFigure(art: art, loop: art.url(clip), size: 56)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(SetupCopy.Armie.name).font(.caption.weight(.semibold)).foregroundStyle(look.accentText)
                        Spacer()
                        // The window's own accent, not the system link blue beside it in a second shade.
                        Button(SetupCopy.Armie.bRetire) { send(.hideArmie) }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .foregroundStyle(look.accentText)
                    }
                    Text(line).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .contain)
            }
        }
    }
}

/// The last lines of an install's output, as the install wrote them.
struct OutputBox: View {
    let lines: [String]
    /// How many of the newest lines a live box shows, newest at the bottom: a few, for the movement,
    /// and never so many that the newest is pushed below the window's edge while the install talks.
    /// nil draws every line it's given (a failure's last words).
    var rows: Int?

    /// A running install's box: the newest line and a few before it, for the movement.
    static let liveRows = 4

    var body: some View {
        let shown = rows.map { Array(lines.suffix($0)) } ?? lines
        withSetupAppearance { look in
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(shown.enumerated()), id: \.offset) { _, line in
                    Text(line).lineLimit(rows == nil ? 2 : 1).truncationMode(.middle)
                }
            }
            .font(.caption.monospaced())
            // The muted grey, not the secondary label: on the box's own shade of the card, the
            // translucent secondary is fainter still than on the card.
            .foregroundStyle(look.mutedText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
            .textSelection(.enabled)
        }
    }
}
