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
// - `LookAroundPage` turns a state into step 1's rows, its card and its buttons. `VMPage` does the
//   same for step 2. `ArmieCue` says how Armie stands and what he says on every page. Pure.
// - Step 2's **Install Windows…** shows the New Windows VM views in the window, as the step's body
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
    /// real Mac — Connect to a Windows desktop, Finish, Run in the Background with its restart, and a second
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
    /// The read in flight is one nobody pressed (`Event.refreshing`): the runner's own after a wake or
    /// a process came or went, or the window's look on coming back (`SetupJourneyActions.returnRead`).
    /// Pages keep their card through one (`LookAroundPage.page`, `SetupJourneyView`), and the saved PC
    /// its password field: a card that blinked out whenever someone clicked back into the window would
    /// be a page that flickers, and a field that went took what was being typed out of sight. Until the
    /// read's `.refreshed`, and no longer.
    var refreshing = false
    var lastEnding: SetupRunner.Ending?
    /// The progress lines of the last piece of work that wasn't a read, newest last: Homebrew's output
    /// or the download's lines, which the install's card shows as they arrive.
    var lines: [String] = []
    /// When the run `lines` came from began (`InFlight.started`, `Ending.started`). A window reopened
    /// after a run it never saw start compares this with that run's, and drops lines that aren't its.
    var linesStarted: Date?
    /// A press the runner turned down, said until it stops being true (`stillRefused`): not when the
    /// next thing starts, which is often the read that took the press's place, and which used to take
    /// the banner with it before anyone had read it — the refused **Approve Certificate…** that left
    /// Josh with no dialog and no word why. It says the press didn't start and to choose it again
    /// (`SetupCopy.Working.refused`), on every step.
    var refusal: SetupRunner.Refusal?
    /// What this run of the window has been told. Kept in memory only (§2.4).
    var answers = SetupFlow.Answers()
    /// **Hide Armie** was pressed, now or on an earlier run.
    var armieHidden = false
    /// The step Armie hops for (`ArmieCue`): set when a press's work, or Connect's **Yes**, turns the
    /// step on screen done well where it wasn't (`noteHop`), and cleared by the next work that starts,
    /// a move to another step, or the window coming back (`attached`). So the hop plays once for each
    /// time a step is done: never for a read, pressed or not, since a read finds what was already so;
    /// never for a snapshot's refresh; and never again on reopening, where it would celebrate
    /// something done minutes ago.
    var armieHop: WizardStep?
    /// Step 2's body is the New Windows VM views (§2.3 **Install Windows…**): from the press that put them
    /// there until they hand back (`CreateWindowController.EmbeddedEnd`). Set only by a press — **Make
    /// One**, **Install Windows in a New VM…**, **Show Install Progress** — never by a snapshot, so a snapshot read
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
    /// The setup disk an install that ended well couldn't delete (`EmbeddedEnd.installed`), until it is
    /// moved to the Trash from step 2.
    var setupDisk: String?
    var finished = false
    var secretEpoch = 0
    var reconnectAfterRestart = false
    /// Permission timing is about a press, not whether the connection succeeded. Skipping Windows
    /// App and finishing setup must not trigger the first network request merely by opening a menu.
    var connectionRequested = false
    var defersNetworkProbe: Bool { answers.started && !connectionRequested }

    /// The last press's failure, while it still stands: while the step still offers the work that
    /// failed, on the facts the window has now (`Work.applies(to:)`), or with no facts to say. A
    /// failure is how a press ended, and a look nobody pressed doesn't replace an ending, so a failure
    /// card now lasts through every look on coming back — which is right while it is still true, and
    /// wrong once it was put right some other way: an App Store hand-off that failed, then Windows App
    /// installed by hand; a Fix that failed, then the setting changed in Windows; a start that failed,
    /// then the VM started in UTM. Pure.
    var standingFailure: SetupRunner.Problem? {
        guard let ending = lastEnding, case .failed(let problem) = ending.outcome else { return nil }
        guard let facts else { return problem }
        return ending.work.applies(to: facts) ? problem : nil
    }

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
    /// (`SetupFlow.landing`) — and never a finished window anywhere (`landing`) — and the window's
    /// answers always win over the ones a snapshot carries: the runner hands back what it was last
    /// told, which a press since may have changed.
    func applying(_ event: SetupRunner.Event) -> SetupWindowState {
        var next = self
        switch event {
        case .started(let flight), .refreshing(let flight):
            next.inFlight = flight
            next.refreshing = { if case .refreshing = event { return true }; return false }()
            // New work, or a read somebody pressed or a step arrived at: the page is busy, and a hop
            // is over. A read nobody pressed leaves him as he was, as it leaves the page's card.
            if !next.refreshing { next.armieHop = nil }
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
            // Only for the run the window is showing. The runner sends a line after letting go of its
            // lock (`SetupRunner.said`), so one said just before the work ended can arrive after its
            // `.ended`, and taken then it put the work back in flight with nothing left to take it
            // away: a page that looked busy for good.
            guard next.inFlight?.started == flight.started else { break }
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
            next = next.landing(ending.facts)
            next.settleAfterInstall(readAt: ending.started)
            next.moveOn(after: ending)
            if ending.work == .connect {
                next.answers.connectionOpened = ending.outcome == .finished
                // Stopped waiting, it didn't not work: nothing was tried, and the step is ready again.
                next.answers.connected = [.finished, .overtaken, .cancelled].contains(ending.outcome) ? nil : false
            }
            if ending.work == .applyChanges, ending.outcome == .finished, next.answers.connected == true {
                next.answers.connected = nil
                next.answers.connectionOpened = false
                next.reconnectAfterRestart = true
                next.step = .connect
            }
            next.facts?.answers = next.answers
            next.refusal = next.refusal.flatMap { SetupWindowState.stillRefused($0, after: ending.work, on: next.facts) }
        case .stale:
            // A fresh snapshot follows once the queue is free (`.refreshed`); nothing to redraw yet.
            break
        case .refreshed(let facts):
            if next.inFlight?.work.isRead == true { next.inFlight = nil }
            next.refreshing = false
            next = next.landing(facts)
            next.settleAfterInstall(readAt: facts.stamp?.taken)
            next.refusal = next.refusal.flatMap { SetupWindowState.stillRefused($0, after: nil, on: next.facts) }
        }
        // The gate's words ("Winbar is still starting …") stop being true once the runner has had the
        // gate since: for work or a read that began after the refusal. An event queued before it
        // doesn't count, so what began is compared rather than taken as an event arriving.
        if let refusal = next.refusal, refusal.reason != nil, let began = SetupWindowState.began(event),
           began > refusal.inFlight.started {
            next.refusal?.reasonPassed = true
        }
        // A refusal is about the page it was pressed on, and so is a hop.
        if next.step != step {
            next.refusal = nil
            next.armieHop = nil
        }
        // The press's own work having done the step on screen, and not a read's finding it done.
        if case .ended(let ending) = event, ending.work.earnsHop, ending.outcome == .finished, ending.work.step == next.step {
            next.noteHop(on: next.step, before: facts)
        }
        return next
    }

    /// Marks `step` for Armie's hop when it is on screen and is now done well (`ArmieCue.doneWell`)
    /// where `before` — the facts from before the press — wasn't. Pure.
    mutating func noteHop(on step: WizardStep, before: SetupFlow.Facts?) {
        guard step == self.step, let facts, ArmieCue.doneWell(step, facts),
              !(before.map { ArmieCue.doneWell(step, $0) } ?? false) else { return }
        armieHop = step
    }

    /// When the runner's work or read behind `event` began, having taken the app's gate: nil for an
    /// event that says nothing of it. Pure.
    static func began(_ event: SetupRunner.Event) -> Date? {
        switch event {
        case .started(let flight), .refreshing(let flight): return flight.started
        case .ended(let ending): return ending.started
        case .refreshed(let facts): return facts.stamp?.taken
        case .progressed, .stale: return nil
        }
    }

    /// Whether a refusal is still true once `done` has ended (nil: a read nobody pressed) and the Mac
    /// looks like `facts`: the press is still one the page offers, and so still worth choosing again.
    /// Not a refused read, which any fresh snapshot answers; not once the very work it wanted has run
    /// (pressed again, and taken); and not once the page no longer offers it — the certificate trusted
    /// in the meantime, the row fixed. Judged with the answers the press would have given
    /// (`Refusal.answers`) where it carried any. Pure.
    static func stillRefused(_ refusal: SetupRunner.Refusal, after done: SetupRunner.Work?,
                             on facts: SetupFlow.Facts?) -> SetupRunner.Refusal? {
        if refusal.wanted.isRead || done == refusal.wanted { return nil }
        guard var facts else { return refusal }
        if let answers = refusal.answers { facts.answers = answers }
        return refusal.wanted.applies(to: facts) ? refusal : nil
    }

    /// Takes `facts`, and goes back to the first step that came undone, if one before this one did —
    /// except while the create views are step 2's body: they are the step's work in flight, and a
    /// snapshot taking the window off them (UTM went quiet for a moment mid-install) would hide an
    /// install the person is watching. They hand back when they're done, and landing resumes then.
    ///
    /// And never once the window is finished. A VM stopped after setup, or Windows App gone since,
    /// is a Mac in use, not a setup come undone: dragging the finished page back to the VM step would
    /// ask for setup again over a VM that only needs starting. The finished page's buttons start what
    /// they need (**Open Windows** is the menu's Connect; **Try Connecting Again** starts a stopped VM
    /// first), and leaving the page is the person's press (**Go Back to Saved PC**, Try Connecting
    /// Again). Only another VM chosen elsewhere un-finishes it: the page described a different
    /// Windows, and its answers go with it.
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
        if !creating, !next.finished { next.step = SetupFlow.landing(on: next.step, facts) }
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
        // Set, not heard as `.progressed`, which only updates a run the window is already showing.
        next.inFlight = inFlight
        if let inFlight, !inFlight.work.isRead {
            next.keepLines(of: inFlight.started)
            if let line = inFlight.line { next.lines = SetupWindowState.adding(line, to: next.lines) }
        }
        // The runner's newest snapshot is never older than its last ending's: both are stored together.
        if let latest {
            next = next.landing(latest)
            next.settleAfterInstall(readAt: latest.stamp?.taken)
        }
        // Whatever was done before the window came back, an ending it only hears of now included, was
        // done out of sight: Armie doesn't hop for it on reopening.
        next.armieHop = nil
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

    /// Whether **Set Up Winbar…** opens this window again from the start once it has closed: finished
    /// with Windows' desktop seen. That page says "To run this window again, choose **Set Up
    /// Winbar…**", and nothing made it true — a finished window stays finished through every snapshot
    /// (`landing`), so the menu brought back the same page, days old, with no Back and no Check Again,
    /// until Winbar was relaunched. Not the other finished pages: they say "pick up where this leaves
    /// off", and their buttons (**Try Connecting Again**, **Go Back to Saved PC**, **Open the App
    /// Store**) are that. Pure.
    var runsAgainWhenReopened: Bool {
        finished && facts.map(SetupCopy.Finish.outcome) == .connected
    }

    /// The window as it opens again after `runsAgainWhenReopened`: started, on Look around, with this
    /// run's answers and pages gone and Armie as he was. The window then reads the Mac afresh
    /// (`SetupWindowController.attach`). Pure.
    func startedAgain() -> SetupWindowState {
        var fresh = SetupWindowState()
        fresh.armieHidden = armieHidden
        fresh.answers.started = true
        fresh.step = .lookAround
        return fresh
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
    /// A read (`checkAgain`, or a look nobody pressed, `lookAgain`), whose only product is the
    /// snapshot after it.
    var isRead: Bool {
        switch self {
        case .checkAgain, .lookAgain: return true
        default: return false
        }
    }

    /// Whether this work, having finished, can earn Armie's hop (`SetupWindowState.noteHop`): not a
    /// read, and not the survey either. The survey is work to the runner (it runs scripts in Windows
    /// and holds the Mac awake), but to the person it is Tune's **Check Again**: it only asks Windows
    /// how it's set up and changes nothing, so a survey that finds every setting right has found what
    /// was already so, and celebrating it would be the hop for a read.
    var earnsHop: Bool { !isRead && self != .survey }
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
///
/// The page's one point is its title (`Page.title`), which `SetupScreen.pageTitle` puts at the top:
/// "Look around" over a card whose own heading said the point stacked two titles over every card.
/// The card under the rows then opens on what to do, with anything longer folded under **Show
/// Details**, and the step's buttons are the footer's (`SetupFooter.footer`).
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
        // Every card's one point is said once, as the page's title (`heading`); the row above it keeps
        // to its mark, or a few words the card doesn't repeat (the review found rows and cards saying
        // the same thing twice, and failures quieter than successes, their titles only in a grey row
        // detail).

        /// UTM missing, too old or not the real thing: the title (`needsHeading`), the one sentence
        /// that says what's needed and which button does it (`SetupCopy.LookAround.summary`), and the
        /// plan's particulars for **Show Details** (`SetupCopy.LookAround.details`).
        case needsUTM(heading: String, summary: String, details: [String])
        /// UTM's install, running: its output so far, without the download's counts, which are the
        /// bar's (`download`, while the download is the newest thing said). `update`: Homebrew is
        /// replacing a copy that's too old, which the title says rather than "installing".
        case installing(lines: [String], update: Bool, download: SetupWindowState.DownloadCount?)
        /// The install stopped. No Armie here, and no joke: what went wrong as the title, what to do,
        /// and Homebrew's last words, shown rather than folded away.
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
        /// Automation refused: where to turn it back on.
        case denied
        /// utmctl answered with an error: its own words, for **Show Details**.
        case utmFailed(detail: String)
        /// UTM wouldn't list its VMs.
        case listFailed(heading: String, detail: String)

        /// The card's one point, which the page says as its title. nil only for no card.
        var heading: String? {
            switch self {
            case .none: return nil
            case .needsUTM(let heading, _, _), .listFailed(let heading, _): return heading
            case .installing(_, let update, _): return SetupCopy.LookAround.installing(update: update)
            case .installFailed(let problem, _, _): return problem.title
            case .askUTM: return SetupCopy.LookAround.askHeading
            case .settling: return SetupCopy.LookAround.settleHeading
            case .silent(let consent, _):
                // With an answer on file, what's needed is the switch, as when it was refused.
                return consent == .decided ? SetupCopy.LookAround.permissionHeading : SetupCopy.LookAround.silentHeading
            case .denied: return SetupCopy.LookAround.permissionHeading
            case .utmFailed: return SetupCopy.LookAround.utmFailedHeading
            }
        }
    }

    enum Action: Equatable {
        case run(SetupRunner.Work)
        case openAutomationSettings
        /// Shows UTM's app in the Finder: the copy Winbar won't replace, one drag from the Trash.
        case showUTMInFinder
        /// On to step 2.
        case next
    }

    struct Button: Equatable {
        var title: String
        var action: Action
        var enabled = true
    }

    struct Page: Equatable {
        /// The page's one title (`SetupScreen.pageTitle`).
        var title: String = SetupCopy.stepName(.lookAround)
        var rows: [Row]
        var card: Card
        /// A quiet line under the rows where there's no card: how long a read takes.
        var note: String?
        /// The default button: Return presses it.
        var primary: Button?
        var secondary: Button?
    }

    /// Who macOS names in the Automation prompt. The window only ever runs as Winbar.app.
    static let host = (name: "Winbar", bundleID: Optional(Config.appBundleID))

    static func page(_ state: SetupWindowState, lastBuilt: WizardStep = SetupWindowState.lastBuilt) -> Page {
        var page = screen(state, lastBuilt: lastBuilt)
        // A read in flight (Check Again, or the read after Start) greys the runner's buttons out;
        // without something moving, the page looked broken. The first row the read can still change
        // spins. Windows App's row is left alone: nothing on this step acts on it. The two buttons that
        // only open another app's window stay: they touch nothing the read is reading.
        if state.inFlight?.work.isRead == true {
            if let index = page.rows.prefix(2).firstIndex(where: { $0.mark != .done }) {
                page.rows[index].mark = .running
            }
            // A read somebody pressed puts the card away until it answers, and the buttons that went
            // with it: the card is the last read's, and "UTM isn't installed" beside a spinner that's
            // checking whether it now is said something already out of date, over a greyed-out
            // install button. Not for a read nobody pressed (`refreshing`) — the runner's own after a
            // wake, or the window's look when it becomes key — or the card would blink out under the
            // person reading it. And never a failure, whose card is how the work ended, not what the
            // Mac looks like.
            if !state.refreshing, page.card != .none {
                if case .installFailed = page.card {} else {
                    page.card = .none
                    page.title = SetupCopy.LookAround.checkingTitle
                    page.note = SetupCopy.LookAround.checkingNote
                    page.primary = nil
                    page.secondary = nil
                }
            }
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
            // The first look hasn't come back: the rows are what's being looked at, and the line under
            // them says how long, rather than a spinner over an empty window.
            let mark: CreateProgress.Mark = idle ? .pending : .running
            return Page(title: SetupCopy.LookAround.checkingTitle,
                        rows: [Row(mark: mark, title: utmTitle), Row(mark: .pending, title: vmsTitle),
                               Row(mark: .pending, title: SetupCopy.LookAround.rowWindowsApp)],
                        card: .none, note: SetupCopy.LookAround.checkingNote, primary: nil, secondary: nil)
        }
        // UTM's row once it's there: its version, as "Installed · 4.7.5".
        let installed = SetupCopy.LookAround.installed(facts.utm)
        let windowsApp = windowsAppRow(facts, lastBuilt: lastBuilt)
        let screen = SetupFlow.lookAround(facts)

        // Work of step 1's own in flight comes first: it's what the person is watching. Neither has a
        // button while it runs: the only one there could be is the work itself, greyed out.
        // The install's card shows its progress as it comes, so the row doesn't repeat the last line;
        // and there's no button, since the only thing to press would be the install itself.
        if work == .installUTM {
            let lines = state.lines.isEmpty ? latest.map { [$0] } ?? [] : state.lines
            return page(Row(mark: .running, title: utmTitle), Row(mark: .pending, title: vmsTitle), windowsApp,
                        card: .installing(lines: lines.filter { !SetupWindowState.isDownloadCount($0) },
                                          update: utmPlan(facts)?.isUpdate == true,
                                          download: lines.last.flatMap(SetupWindowState.downloadCount)))
        }
        if work == .settleUTM {
            return page(Row(mark: .running, title: utmTitle, detail: SetupCopy.LookAround.asking(flight?.line)),
                        Row(mark: .pending, title: vmsTitle), windowsApp,
                        card: .settling(quarantined: facts.utmQuarantined))
        }

        let checkAgain = Button(title: SetupCopy.bCheckAgain, action: .run(.checkAgain(.lookAround)), enabled: idle)
        let tryAgain = Button(title: SetupCopy.bTryAgain, action: .run(.settleUTM), enabled: idle)
        let settings = Button(title: SetupCopy.LookAround.bOpenAutomationSettings, action: .openAutomationSettings)
        let pendingVMs = Row(mark: .pending, title: vmsTitle)

        switch screen {
        case .needsUTM(let dependencyState):
            if let ending = state.lastEnding, ending.work == .installUTM, case .failed(let problem) = ending.outcome {
                return page(Row(mark: .failed, title: utmTitle), pendingVMs, windowsApp,
                            card: .installFailed(problem, lines: state.lines, slept: ending.slept),
                            primary: Button(title: SetupCopy.bTryAgain, action: .run(.installUTM), enabled: idle))
            }
            let plan = utmPlan(facts)
            let actionable = SetupRunner.actionable(plan)
            let mark: CreateProgress.Mark
            if case .wrongSignature = dependencyState { mark = .failed } else { mark = .attention }
            // The row is only its mark: "not installed; setup can download it…" said the title's news
            // in the terminal's words, and "setup" read as the command.
            let card = Card.needsUTM(heading: SetupCopy.LookAround.needsHeading(dependencyState),
                                     summary: SetupCopy.LookAround.summary(plan, state: dependencyState, host: host.name),
                                     details: SetupCopy.LookAround.details(plan, state: dependencyState, host: host.name))
            if case .wrongSignature = dependencyState {
                // The fix is in the Finder, so that's the button; Check Again is for after it (and the
                // window looks again by itself when it becomes key, `SetupJourneyActions.returnRead`).
                return page(Row(mark: mark, title: utmTitle), pendingVMs, windowsApp, card: card,
                            primary: Button(title: SetupCopy.LookAround.bShowInFinder, action: .showUTMInFinder),
                            secondary: checkAgain)
            }
            return page(Row(mark: mark, title: utmTitle), pendingVMs, windowsApp, card: card,
                        primary: actionable ? installButton(facts, enabled: idle) : checkAgain)
        case .askUTM:
            // Found, and nothing wrong with it: a tick, with its version. It sat at the pending circle
            // beside "UTM 4.7.5", found but drawn as not looked at yet.
            return page(Row(mark: .done, title: utmTitle, detail: installed), pendingVMs, windowsApp,
                        card: .askUTM(quarantined: facts.utmQuarantined),
                        primary: Button(title: SetupCopy.LookAround.bOpenUTMAndAsk, action: .run(.settleUTM), enabled: idle))
        case .utmSilent(let seconds, let consent, let quarantined):
            let row = Row(mark: .attention, title: utmTitle, detail: SetupCopy.LookAround.silentRow(seconds: seconds))
            // With an answer on file, no prompt is coming and the switch in System Settings is the way
            // on, so that page is the filled button, as it is when the answer was no; Try Again beside it.
            if consent == .decided {
                return page(row, pendingVMs, windowsApp, card: .silent(consent: consent, quarantined: quarantined),
                            primary: settings, secondary: tryAgain)
            }
            return page(row, pendingVMs, windowsApp, card: .silent(consent: consent, quarantined: quarantined),
                        primary: tryAgain)
        case .utmDenied:
            // Settings first and filled: nothing Try Again does can change a refusal, and the card's
            // sentence ends on that button. Try Again stays for after.
            return page(Row(mark: .attention, title: utmTitle, detail: installed), pendingVMs, windowsApp,
                        card: .denied, primary: settings, secondary: tryAgain)
        case .utmFailed(let detail):
            // The fix is UTM open, which `settleUTM` does before it asks again: named for the fix.
            return page(Row(mark: .failed, title: utmTitle, detail: installed), pendingVMs, windowsApp,
                        card: .utmFailed(detail: detail),
                        primary: Button(title: SetupCopy.LookAround.bOpenUTM, action: .run(.settleUTM), enabled: idle))
        case .listVMs:
            return page(Row(mark: .done, title: utmTitle, detail: installed),
                        Row(mark: idle ? .pending : .running, title: vmsTitle), windowsApp,
                        card: .none, primary: checkAgain)
        case .listFailed(let failure):
            let card = Card.listFailed(heading: failure.title, detail: failure.detail)
            let rows = (Row(mark: .done, title: utmTitle, detail: installed), Row(mark: .failed, title: vmsTitle))
            if failure.automationDenied {
                return page(rows.0, rows.1, windowsApp, card: card, primary: settings, secondary: checkAgain)
            }
            return page(rows.0, rows.1, windowsApp, card: card, primary: checkAgain)
        case .done:
            var count = 0
            if case .listed(let list) = facts.vms { count = list.count }
            var done = page(Row(mark: .done, title: utmTitle, detail: installed),
                            Row(mark: .done, title: vmsTitle, detail: SetupCopy.LookAround.vmCount(count)), windowsApp,
                            card: .none,
                            primary: Button(title: SetupCopy.journeyNext(.lookAround, facts: facts), action: .next,
                                            enabled: idle))
            done.title = SetupCopy.LookAround.readyTitle(windowsAppReady: windowsApp.mark == .done)
            return done
        }
    }

    /// A page of the three rows, titled with its card's point, or the step's name where there's none.
    private static func page(_ utm: Row, _ vms: Row, _ windowsApp: Row, card: Card,
                             primary: Button? = nil, secondary: Button? = nil) -> Page {
        Page(title: card.heading ?? SetupCopy.stepName(.lookAround), rows: [utm, vms, windowsApp], card: card,
             primary: primary, secondary: secondary)
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
        if c1.kind == .ok {
            return Row(mark: .done, title: title, detail: SetupCopy.LookAround.installed(facts.windowsApp) ?? c1.detail)
        }
        if case .missing = facts.windowsApp {
            return Row(mark: .pending, title: title, detail: SetupCopy.LookAround.windowsAppLater(lastBuilt: lastBuilt))
        }
        return Row(mark: .attention, title: title, detail: c1.detail)
    }

    /// Whether the UTM the window would install is an update of a copy that's too old: Homebrew then
    /// quits UTM, with an Apple Event that can raise the Automation prompt part way, and may raise App
    /// Management and Gatekeeper's after it, so Armie stands still and says nothing through it
    /// (`ArmieCue`). Pure.
    static func installsUpdate(_ facts: SetupFlow.Facts) -> Bool { utmPlan(facts)?.isUpdate == true }

    /// A card's words, in `CardText`'s order, for every card that is only words; nil for no card, and
    /// for the install and its failure, which draw its progress and output too. The heading is the
    /// page's title, so it isn't in the card. Pure, so the tests can read every word a screen says
    /// rather than only the renders.
    static func cardText(_ card: Card) -> CardText? {
        switch card {
        case .none, .installing, .installFailed:
            return nil
        case .needsUTM(_, let summary, _):
            return CardText(paragraphs: [SetupCopy.markdown(summary)])
        case .askUTM(let quarantined):
            return CardText(paragraphs: [SetupCopy.markdown(SetupCopy.LookAround.askBody)],
                            emphasis: SetupCopy.markdown(SetupCopy.LookAround.askInstruction(host: host.name,
                                                                                             quarantined: quarantined)),
                            aside: AttributedString(SetupCopy.LookAround.askAside(quarantined: quarantined)))
        case .settling(let quarantined):
            // The open question first, as macOS asks it: UTM has to be running to be asked anything.
            let control = SetupCopy.Working.whereToLook(.automationPrompt, host: host.name)
            return CardText(paragraphs: [SetupCopy.markdown(quarantined ? SetupCopy.LookAround.settleOpen + " " + control
                                                                        : control)])
        case .silent(let consent, let quarantined):
            return CardText(paragraphs: [SetupCopy.markdown(SetupCopy.LookAround.silent(consent: consent, host: host.name))],
                            aside: quarantined ? SetupCopy.markdown(SetupCopy.LookAround.quarantineAside) : nil)
        case .denied:
            return CardText(paragraphs: [SetupCopy.markdown(SetupCopy.LookAround.denied(host: host.name))])
        case .utmFailed:
            return CardText(paragraphs: [SetupCopy.markdown(SetupCopy.LookAround.utmFailed)])
        case .listFailed(_, let detail):
            return CardText(paragraphs: [AttributedString(detail)])
        }
    }

    /// What a card folds under **Show Details**, as plain paragraphs; empty for a card with nothing
    /// folded. The install's output and its failure's are drawn by the view, as output. Pure.
    static func details(_ card: Card) -> [String] {
        switch card {
        case .needsUTM(_, _, let details): return details
        case .utmFailed(let detail): return [SetupCopy.LookAround.utmSaid(detail)]
        default: return []
        }
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
    /// Step 2's two buttons for a setup disk an install couldn't delete (`SetupWindowState.setupDisk`).
    case showSetupDisk
    case trashSetupDisk
    case retryConnection
    case retrySavedPC
    /// Takes back a step's Skip and goes back to it (`SetupFlow.skips(in:)`): the Saved PC step's **Try
    /// Saving Again**, a skipped certificate's **Check the Certificate Again**, and the finished page's
    /// **Go Back to Saved PC** or **Go Back to Certificate** (its corner once Windows App is here after
    /// it was skipped, or its list of what was passed over), which leaves the finished page on purpose.
    case revisit(WizardStep)
    case continueWithoutSavedPC
    case connected(Bool)
    case stopWaiting
    case quitWindowsApp
    /// A button that takes Ben somewhere outside the window: Local Network's settings, or Windows'
    /// own screen to sign in on (`SetupPlace`).
    case open(SetupPlace)
    case reportProblem
    /// The beta's **Help!** in the title bar, and **Send This to the Developer** on a failure card: the
    /// Send a Problem Report… dialog, with this window's step and last failure in it (`BetaReport`).
    case sendReport
    case finish
    /// The placeholder's **Close**: this build's window has done what it can.
    case closeForNow
    /// Finish's two tiles: **Run in the Background** (true) or **Keep Windows' Screen** (false). A
    /// choice, not the restart: the footer's **Restart and Finish** does that (`SetupFinishPage`).
    case chooseBackground(Bool)
    /// **Restart and Finish**: the background choice staged if it is still only chosen, then the
    /// one restart that applies everything staged.
    case restartAndFinish
    /// **Finish Without Restarting**: drops what is staged, then finishes.
    case finishWithoutRestarting
    /// The done page's **Open Windows**: the menu's Connect, with this window put away.
    case openWindows
    /// The "Almost done" page's **Try Connecting Again**: back to Connect, pressing it.
    case connectAgain
}

// MARK: - The settings the window reads and writes

/// The settings the window touches, as functions, so a test can hand it its own: two global ones,
/// and what Connect's answer says about the chosen VM's saved PC.
struct SetupSettings {
    var wizardShown: () -> Bool
    var markShown: () -> Void
    var armieHidden: () -> Bool
    var hideArmie: () -> Void
    /// Remembers what the answer to "Did the Windows desktop appear?" says about the saved PC
    /// (`Recipe.connectedSavedPC`), in the chosen VM's settings — and only while that is still the VM
    /// `facts` describe, so an answer about one VM is never filed under another. Does nothing unless
    /// handed a way to write: a test's controller never touches the Mac's settings.
    var rememberConnect: (_ desktopAppeared: Bool, _ facts: SetupFlow.Facts) -> Void = { _, _ in }

    static let live = SetupSettings(wizardShown: { Config.setupWizardShown },
                                    markShown: { Config.setupWizardShown = true },
                                    armieHidden: { Config.armieHidden },
                                    hideArmie: { Config.armieHidden = true },
                                    rememberConnect: { appeared, facts in
                                        guard let vm = Config.vmName, facts.chosenVM == vm,
                                              facts.chosenID == Config.vmID else { return }
                                        Config.savedPCConnectedHost = Recipe.connectedSavedPC(
                                            desktopAppeared: appeared, pressed: facts.savedPCPressed,
                                            host: facts.rdpHost, previous: Config.savedPCConnectedHost)
                                    })
}

// MARK: - The window

final class SetupCredentials: ObservableObject {
    @Published var password = ""
    func clear() { password = "" }
}

final class SetupWindowController: NSObject, ObservableObject, NSWindowDelegate {
    /// The app's, and the only one whose news reaches VoiceOver (`SetupAnnouncer`).
    static let shared = SetupWindowController(announcer: .live)
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

    @Published private(set) var state: SetupWindowState {
        // Every change of state passes here, whoever made it — a runner event, a press, a refusal —
        // so nothing VoiceOver should hear can take a path around it.
        didSet {
            guard isPresented else { return }
            for line in SetupAnnouncement.said(from: oldValue, to: state) { announcer.say(line) }
        }
    }
    /// Armie's art, from the app's bundle; nil where it isn't (then there is no Armie).
    let art: ArmieArt?
    let credentials = SetupCredentials()

    private let settings: SetupSettings
    private let setupDisk: SetupDiskActions
    /// Silent unless this is `shared` (`SetupAnnouncer`).
    let announcer: SetupAnnouncer
    private let makeRunner: () -> SetupRunner
    private var runner: SetupRunner?
    private var observation: SetupRunner.Observation?
    private var window: NSWindow?

    private let makeCreator: () -> EmbeddableCreate
    private var creator: EmbeddableCreate?
    /// What **Open Windows** runs: the menu's own **Connect**, so the done page and the menu open
    /// Windows one way, with the menu's waiting and its alerts. A test passes its own.
    private let openWindows: () -> Void
    /// **Quit Windows App**: asks it to quit and calls back once it has (`WindowsAppQuitter`). A test
    /// hands in its own, which quits nothing.
    private let quitWindowsApp: (@escaping () -> Void) -> Void
    /// Lets Windows App's command line be asked again after it stopped answering
    /// (`WindowsAppBookmarks.retryReadCommands`): **Try Again** on the saved PC, and a saved PC's Skip
    /// taken back. A test hands in its own, which counts.
    private let retryWindowsAppReads: () -> Void
    /// A press that is two pieces of work (**Restart and Finish** from a choice not yet staged,
    /// **Finish Without Restarting**): the command to send once `work` has ended well and nothing
    /// else is running. Dropped if the work ends any other way, so a failure stays on screen.
    private var afterWork: (work: SetupRunner.Work, then: SetupCommand, ended: Bool)?
    var embeddedController: CreateWindowController? { creator as? CreateWindowController }
    /// Runs a closure after a delay, on the main queue: `DispatchQueue.main.asyncAfter` in the app. A
    /// test hands in its own, which keeps the closure to call when it chooses.
    private let later: (TimeInterval, @escaping () -> Void) -> Void
    /// Opens the beta's Send a Problem Report… dialog (`BetaReport`), which reads this window's state
    /// as it opens. A test hands in its own, which opens nothing.
    private let sendReport: () -> Void
    /// The look on coming back that is waiting for its moment (`windowDidBecomeKey`), by a token of
    /// its own, so a press, a click or a key since can call it off or put it back.
    private var returnLook: UUID?
    /// How long the window waits after becoming key before its look. Long enough for the click that
    /// brought it forward, or the click after one that didn't reach the button, to land first; short
    /// enough that a page waiting on another app has said what changed by the time it's read.
    static let returnLookDelay: TimeInterval = 0.5
    /// A read the window owes itself (`readByItself`) because something was running when it was due:
    /// taken at the first event that finds nothing running, if the window is still on its step.
    private var owedRead: SetupRunner.Work?
    /// The window closed finished with the desktop seen (`SetupWindowState.runsAgainWhenReopened`):
    /// the next `attach` starts it again rather than bringing back the finished page.
    private var runsAgain = false

    /// The app only ever has `shared`. The parameters are for tests, which must not reach the Mac's
    /// settings, make the live runner (whose machine asks UTM and Windows things) or open a window.
    init(state: SetupWindowState = SetupWindowState(), art: ArmieArt? = ArmieArt.app, settings: SetupSettings = .live,
         announcer: SetupAnnouncer = .silent, setupDisk: SetupDiskActions = .live,
         makeRunner: @escaping () -> SetupRunner = { SetupRunner.shared },
         makeCreator: @escaping () -> EmbeddableCreate = { CreateWindowController.shared },
         openWindows: @escaping () -> Void = { (NSApp.delegate as? AppDelegate)?.connect() },
         quitWindowsApp: @escaping (@escaping () -> Void) -> Void = WindowsAppQuitter.shared.quit,
         retryWindowsAppReads: @escaping () -> Void = WindowsAppBookmarks.retryReadCommands,
         later: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, body in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: body)
         },
         sendReport: @escaping () -> Void = { BetaReportWindowController.present(.setUpWinbar) }) {
        var state = state
        state.armieHidden = state.armieHidden || settings.armieHidden()
        self.state = state
        self.art = art
        self.settings = settings
        self.setupDisk = setupDisk
        self.announcer = announcer
        self.makeRunner = makeRunner
        self.makeCreator = makeCreator
        self.openWindows = openWindows
        self.quitWindowsApp = quitWindowsApp
        self.retryWindowsAppReads = retryWindowsAppReads
        self.later = later
        self.sendReport = sendReport
        super.init()
    }

    /// From the menu, the notification `winbar setup --window` posts, its launch argument, and the
    /// first-run open. Safe to call again: it brings the window forward.
    static func present() { shared.show() }

    private func show() {
        Self.presented = self
        let window = existingWindow()
        // Asked for from outside — `winbar setup --window`, a reopen, the first-run open — a menu bar
        // app isn't the active one, and macOS 14's cooperative activation may decline to make it so;
        // the window then opened behind whatever was in front. Ordering it front regardless puts it
        // where the person looks, whether or not the activation is granted.
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        MainActor.assumeIsolated { AppPresence.update() }
        NSApp.activate()
        attach()
        if state.creating { creator?.hostShown() }
        // Reopened on step 1 with nothing known and nothing running: look. The welcome touches nothing.
        if state.step >= .lookAround, state.facts == nil, state.inFlight == nil { readByItself(.checkAgain(.lookAround)) }
    }

    /// The window's title, frame and first size. Its own function so the layout check that holds
    /// Armie clear of **Help!** in the title bar measures the window people get, in one that is
    /// never put on screen.
    static func shape(_ window: NSWindow) {
        window.title = SetupCopy.winTitle
        // The backdrop runs under the title bar, as Windows 11's Mica does and as plenty of Mac apps'
        // unified title bars do; the traffic lights and the title stay where they always are, so
        // Winbar's name is on every step without a heading of its own saying it again.
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.setContentSize(NSSize(width: 600, height: 620))
        window.contentMinSize = NSSize(width: 600, height: 420)
    }

    private func existingWindow() -> NSWindow {
        if let window { return window }
        let content = NSHostingController(rootView: SetupRootView(controller: self))
        // The window owns its size, not SwiftUI; the layout is drawn for 600 pt and scrolls below it.
        content.sizingOptions = []
        let window = SetupNSWindow(contentViewController: content)
        Self.shape(window)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("winbar-setup")
        // The beta's Help!, on every page: the title bar is the one place every page has.
        if let help = BetaReport.titlebarHelp(press: { [weak self] in self?.send(.sendReport) }) {
            window.addTitlebarAccessoryViewController(help)
        }
        self.window = window
        return window
    }

    /// Listens to the runner from now until the window closes: what is in flight, the newest
    /// snapshot, how the last work ended, then every event. Reads by itself only for an install that
    /// handed back, and for a window that closed finished with the desktop seen, which starts again
    /// on Look around (`SetupWindowState.runsAgainWhenReopened`). Internal rather than private so a
    /// test can reopen the window's state exactly as `show()` does, without a window.
    func attach() {
        let again = runsAgain && !isPresented
        if again {
            runsAgain = false
            state = state.startedAgain()
        }
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
        if state.afterInstall != nil { readByItself(.checkAgain(.vm)) }
        // Run again: the runner's newest snapshot is the finished page's, so it is read afresh.
        if again { readByItself(.checkAgain(.lookAround)) }
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
        if state.step > oldStep, state.step >= .tune { readByItself(.checkAgain(state.step)) }
        sendAfterWork(event)
        takeOwedRead()
    }

    /// A read the window takes by itself, nobody having pressed it: arriving at a step (Continue, a
    /// VM ready, an install handed back, a Skip taken back), Windows App having quit, a **No** to the
    /// desktop question, the look on coming back. Never refused in words: a banner saying a press
    /// didn't start, over a press nobody made, was noise, and the read was simply lost — a step
    /// arrived at while a wake's survey ran was never read for. Taken now if the runner will take it;
    /// owed (`owedRead`) while something runs, and taken at the first event that finds nothing
    /// running (`takeOwedRead`). Turned away by the app's gate (the menu starting a VM), the runner
    /// reads everything on the menu's next tick — it already owes a turned-away look that
    /// (`SetupRunner.lookAgain`), and a Check Again asks it to (`SetupRunner.readWhenFree`) — and a
    /// Check Again stays owed until that read's refresh, since the step it arrived at may be further
    /// than the runner has read before.
    ///
    /// A look never replaces a Check Again owed for the same step: the Check Again reads everything
    /// the look would, and more, and a look raises nothing, so the step it arrived at would never be
    /// read: Windows App quitting (`windowsAppQuit`) while the saved PC's arrival read was owed left C2
    /// unread, and the page said "not yet" until Ben found Check Again. The owed Check Again is tried
    /// in the look's place instead, taken now if the runner will.
    private func readByItself(_ work: SetupRunner.Work) {
        guard isPresented, let runner else { return }
        if case .lookAgain = work {
            if case .checkAgain(let step)? = owedRead, step == work.step {
                readByItself(.checkAgain(step))
                return
            }
            if runner.lookAgain(work) {
                owedRead = nil
            } else {
                owedRead = runner.inFlight == nil ? nil : work
            }
            return
        }
        guard let refusal = runner.run(work, answers: state.answers) else {
            owedRead = nil
            return
        }
        owedRead = work
        if refusal.reason != nil { runner.readWhenFree() }
    }

    /// The read the window owes itself (`readByItself`), once nothing runs and nothing is waiting to
    /// follow the last press — and only on the step it was owed for: a read for a step the window has
    /// left says nothing to the one it's on.
    private func takeOwedRead() {
        guard let owed = owedRead, state.inFlight == nil, runner?.inFlight == nil, afterWork == nil else { return }
        guard owed.step == state.step else {
            owedRead = nil
            return
        }
        readByItself(owed)
    }

    /// The second half of a two-part press. Not from the `.ended` callback alone: the runner may
    /// start a read of its own straight after (a stale snapshot), and a press then would be refused,
    /// so it waits for the first event that finds nothing running.
    private func sendAfterWork(_ event: SetupRunner.Event) {
        guard var pending = afterWork else { return }
        if case .ended(let ending) = event, ending.work == pending.work {
            guard ending.outcome == .finished else { afterWork = nil; return }
            pending.ended = true
            afterWork = pending
        }
        guard pending.ended, state.inFlight == nil, runner?.inFlight == nil else { return }
        afterWork = nil
        send(pending.then)
    }

    /// Coming back to the window after doing what a step asked elsewhere — a switch in System
    /// Settings, a sign-in on Windows' screen, an App Store install — takes a look, so the page says
    /// what changed without a **Check Again** press. Only where the step waits on such a thing
    /// (`SetupJourneyActions.returnRead`), and never at once: the click that brought the window forward
    /// may be the press it came back for, and a read that started first greyed that button out, so an
    /// **Approve Certificate…** was refused and macOS's dialog never came. The look waits a moment
    /// (`returnLookDelay`); a press in that moment calls it off (`send`), and a click or a key puts it
    /// back by another moment (`personActed`), so the person's press always comes first.
    func windowDidBecomeKey(_ notification: Notification) {
        guard isPresented else { return }
        armReturnLook()
    }

    /// A mouse-down or key-down in the window (`SetupNSWindow.sendEvent`), before it reaches a button:
    /// a look still waiting waits another moment, so the press it may be part of lands first.
    func personActed() {
        guard returnLook != nil else { return }
        armReturnLook()
    }

    private func armReturnLook() {
        let token = UUID()
        returnLook = token
        later(Self.returnLookDelay) { [weak self] in self?.takeReturnLook(token) }
    }

    /// The look, if it is still the one armed last and the page still waits on another app now that
    /// its moment has come: what the page shows may have changed in it. Not while anything runs, which
    /// ends with a snapshot of its own; and never a refusal (`readByItself`).
    private func takeReturnLook(_ token: UUID) {
        guard returnLook == token else { return }
        returnLook = nil
        guard isPresented, state.inFlight == nil, let runner, runner.inFlight == nil,
              let work = SetupJourneyActions.returnRead(state) else { return }
        readByItself(work)
    }

    /// Windows App has quit after **Quit Windows App**: the saved PC step looks again, so the card
    /// that said it was open moves on to the password without a **Check Again**. The look reads what
    /// is read live (whether Windows App is open is a process scan) and works C2 out again from the
    /// lookup already made, so it never runs Windows App's command line (`SetupRunner.Forget`). Owed
    /// if something runs when the quit comes, as it was when Ben pressed Quit during a read: the quit
    /// was then dropped, and the card said Windows App was open until he found Check Again. Only on
    /// that step; a quit that comes after Ben moved on reads nothing.
    func windowsAppQuit() {
        guard isPresented, state.step == .savedPC else { return }
        readByItself(.lookAgain(.savedPC, forgetting: .statuses))
    }

    /// Closing is never cancelling: the work carries on, and the runner only marks snapshots stale
    /// until a window attaches again. Closing a welcome nobody started is **Not Now**.
    func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated { AppPresence.update(closing: notification.object as? NSWindow) }
        isPresented = false
        runsAgain = state.runsAgainWhenReopened
        if SetupWindowController.dismissesOnClose(state) { settings.markShown() }
        observation?.cancel()
        observation = nil
        afterWork = nil
        returnLook = nil
        owedRead = nil
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
        // Whatever was pressed, it came first: a look still waiting for its moment isn't taken.
        returnLook = nil
        // A hop is for the page it was earned on: Back, Continue or a revisit leaves it behind.
        let stepBefore = state.step
        defer { if state.step != stepBefore { state.armieHop = nil } }
        // And the person has moved on from the press that was refused: a new press says its own, if
        // it is refused too (`run`). Not for ticking a VM in the list, hiding Armie or asking for help,
        // which answer nothing the refusal said.
        switch command {
        case .pickVM, .hideArmie, .sendReport: break
        default: state.refusal = nil
        }
        switch command {
        case .notNow:
            settings.markShown()
            window?.performClose(nil)
        case .start:
            attach()
            state.answers.started = true
            state.step = .lookAround
            // The answers go with the read, so the snapshot after it carries Start. A read the window
            // takes by itself, as every arrival is: a Start the menu's work turned away left "Checking
            // this Mac" with nothing to press and nothing ever read, under a banner saying to try again.
            runner?.update(answers: state.answers)
            readByItself(.checkAgain(.lookAround))
        case .back:
            // Also while only a read runs (`SetupFooter.backable`).
            guard state.inFlight?.work.isRead != false, !state.creating else { return }
            state.step = SetupWindowState.back(from: state.step)
            state.finished = false
            credentials.clear()
        case .perform(.run(let work)):
            if work == .connect { connect() } else { run(work) }
        case .perform(.openAutomationSettings):
            if let url = URL(string: Automation.settingsURL) { NSWorkspace.shared.open(url) }
        case .perform(.showUTMInFinder):
            if let url = UTM.appURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        case .perform(.next):
            state.step = .vm
        case .hideArmie:
            settings.hideArmie()
            state.armieHidden = true
        case .newWindowsVM:
            // Also while only a read runs: showing the form starts nothing, and its own Install takes
            // the app's gate (`CreateWindowController`), which names anything in its way. It was
            // dropped without a word during a read.
            guard state.inFlight?.work.isRead != false, !state.creating,
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
        case .showSetupDisk:
            if let disk = state.setupDisk { setupDisk.reveal(URL(fileURLWithPath: disk, isDirectory: true)) }
        case .trashSetupDisk:
            state = SetupDiskActions.trashing(state, with: setupDisk)
        case .useVM(let name, let id):
            // Another VM starts its answers afresh, once the runner takes the choice: refused, the
            // skips and answers given for the one still chosen stand.
            var next: SetupFlow.Answers?
            if state.facts?.chosen?.id != id {
                var fresh = SetupFlow.Answers()
                fresh.started = true
                next = fresh
            }
            guard run(.chooseVM(name, id: id), answers: next) else { return }
            state.choosingAnotherVM = false
            state.installedVMID = nil
        case .startVM(let name):
            run(.startVM(name))
        case .continueFromVM:
            if let facts = state.facts, case .ready(let vm) = SetupFlow.vm(facts),
               state.installedVMID == nil || state.installedVMID == vm.id {
                state.step = .tune
                readByItself(.checkAgain(.tune))
            }
        case .next:
            guard state.inFlight == nil, let facts = state.facts, SetupFlow.isSatisfied(state.step, facts),
                  let index = WizardStep.allCases.firstIndex(of: state.step), index + 1 < WizardStep.allCases.count else { return }
            state.step = WizardStep.allCases[index + 1]
            credentials.clear()
            readByItself(.checkAgain(state.step))
        case .skip(let id):
            // An answer, not work: it goes with the next press, and a read's snapshot can't undo it
            // (the window's answers win in `landing`). So it can be given while only a read runs.
            guard state.inFlight?.work.isRead != false, !state.creating, id != "G0" else { return }
            state.answers.leftAlone.insert(id)
            syncAnswers()
        case .discardChanges(let id):
            guard state.inFlight == nil else { return }
            var next = state.answers
            next.leftAlone.formUnion(id.map { [$0] } ?? ["H3", "H4", "H5"])
            run(.discardChanges(checkID: id), answers: next)
        case .retryConnection:
            connect()
        case .retrySavedPC:
            // Said if it's refused, as any press is: it was dropped without a word while anything ran.
            guard state.step == .savedPC else { return }
            retryWindowsAppReads()
            run(.checkAgain(.savedPC))
        case .revisit(let step):
            // Only back, never ahead: a wizard that jumps forward lies about what's done (§2). A Skip
            // taken back is an answer, like the Skip itself, not work: so, like Skip and Back, it can be
            // given while only a read runs, and the step's read is one the window takes by itself
            // (`readByItself`), owed while anything runs, never lost and never refused in words.
            let skips = SetupFlow.skips(in: step)
            guard !skips.isEmpty, step <= state.step, state.inFlight?.work.isRead != false, !state.creating,
                  state.facts != nil else { return }
            state.answers.leftAlone.subtract(skips)
            // From the finished page this leaves it, on purpose: the person chose the step. Nothing
            // else un-finishes a window (`SetupWindowState.landing`).
            state.finished = false
            state.step = step
            credentials.clear()
            syncAnswers()
            // A Skip taken back is a retry of what it skipped, and the saved PC's may have been
            // Windows App's command line never answering, which Winbar otherwise stops asking
            // (`WindowsAppBookmarks.ReadGate`), as **Try Again** does.
            if step == .savedPC { retryWindowsAppReads() }
            readByItself(.checkAgain(step))
        case .continueWithoutSavedPC:
            guard state.step == .savedPC, state.inFlight == nil,
                  state.facts?.windowsApp.isInstalled == true else { return }
            credentials.clear()
            state.answers.leftAlone.insert("C2")
            syncAnswers()
            send(.next)
        case .connected(let yes):
            guard state.answers.connectionOpened else { return }
            let before = state.facts
            state.answers.connected = yes
            if yes { state.reconnectAfterRestart = false }
            syncAnswers()
            // Yes is what Connect is for, and the one step done by an answer rather than work.
            if yes { state.noteHop(on: .connect, before: before) }
            // A desktop seen through the saved PC's own tile is evidence it's saved, which Windows
            // App's command line may never give (C2, `Recipe.unansweredSavedPCStatus`).
            if let facts = state.facts { settings.rememberConnect(yes, facts) }
            // The recovery card reasons from the port, and what it said when Windows App opened can
            // be minutes old by the time someone answers No (a credentials prompt timing out, Windows
            // restarting for an update). Look at it again: the port is probed on every snapshot once
            // Connect was pressed, so the look forgets nothing else, and is owed if something runs.
            if !yes { readByItself(.lookAgain(.connect, forgetting: .statuses)) }
        case .stopWaiting:
            runner?.stopWaiting()
        case .quitWindowsApp:
            // A normal quit request only; never force-quit a client with someone else's session. The
            // page said Windows App was open, with the same filled button, until Ben found Check
            // Again: a quit in the background doesn't make this window key, so nothing read again.
            quitWindowsApp { [weak self] in self?.windowsAppQuit() }
        case .open(let place):
            place.open()
        case .reportProblem:
            // Not the runner's work, and the app's gate admits a report beside anything
            // (`AppWorkGate.Owner.report`); the menu's own says if it's busy. It did nothing, and said
            // nothing, while anything ran.
            (NSApp.delegate as? AppDelegate)?.reportProblem()
        case .sendReport:
            // Allowed whatever runs, as Report a Problem… is: the report only reads, and the dialog
            // gathers it under the app's report lease, which refuses nothing.
            sendReport()
        case .finish:
            guard state.inFlight == nil, let facts = state.facts, SetupFlow.isSatisfied(.finish, facts) else { return }
            state.finished = true
            // The finished page is arrived at by this press, not by work: its hop is earned here, once
            // (`ArmieCue`), and a reopened window, or a pose that came and went, doesn't earn it again.
            state.armieHop = .finish
            settings.markShown()
        case .closeForNow:
            settings.markShown()
            window?.performClose(nil)
        case .chooseBackground(let background):
            guard state.inFlight == nil, let facts = state.facts else { return }
            if background {
                // Undoes Keep: the choice goes back to the one offered, which the page shows chosen.
                state.answers.leftAlone.remove("H5")
                syncAnswers()
            } else if facts.pending.display != nil {
                send(.discardChanges("H5"))
            } else {
                send(.skip("H5"))
            }
        case .restartAndFinish:
            guard state.inFlight == nil, let facts = state.facts else { return }
            if SetupFlow.headlessOffer(facts) == .offer {
                run(.fix(checkID: "H5"), then: .perform(.run(.applyChanges)))
            } else {
                run(.applyChanges)
            }
        case .finishWithoutRestarting:
            guard state.inFlight == nil else { return }
            var next = state.answers
            next.leftAlone.formUnion(["H3", "H4", "H5"])
            run(.discardChanges(checkID: nil), answers: next, then: .finish)
        case .openWindows:
            guard state.finished else { return }
            settings.markShown()
            window?.performClose(nil)
            openWindows()
        case .connectAgain:
            // Back to Connect, pressing it; the finished page stays until the runner has taken it. A
            // VM stopped since setup finished is started first, as the menu's Connect starts one, and
            // Connect is pressed once it's running; the page doesn't go back to the VM step for it.
            guard state.finished, state.inFlight == nil else { return }
            if let facts = state.facts, case .stopped(let vm) = SetupFlow.vm(facts) {
                guard run(.startVM(vm.name), then: .retryConnection) else { return }
            } else {
                guard connect() else { return }
            }
            state.finished = false
            state.step = .connect
            credentials.clear()
        }
    }

    /// Connect, or its Try Again, and whether the runner took it. Pressed, the connection is a fresh
    /// one (not answered, not opened), and the runner's reads may probe the port from now on
    /// (`Answers.connectPressed`), since the Connect card predicted the Local Network prompt they can
    /// raise: those answers go with the press, so the read that ends Connect probes the port as well.
    /// The menu's own probe may run too (`connectionRequested`). All of it only once the runner has
    /// taken the press (`run`): a refused Try Again leaves the recovery card and its answer as they were.
    @discardableResult
    private func connect() -> Bool {
        var next = state.answers
        next.connectPressed = true
        next.connected = nil
        next.connectionOpened = false
        guard run(.connect, answers: next) else { return false }
        state.connectionRequested = true
        return true
    }

    private func syncAnswers() {
        state.facts?.answers = state.answers
        runner?.update(answers: state.answers)
    }

    /// The secret is handed directly to one save operation. It is never a command, state or note.
    /// The field keeps it until the runner has taken the press, and forgets it then: a **Save It**
    /// the runner turned down left an empty field, and what was typed had to be typed again, where
    /// the refusal said only to choose it again. The views hand it over without clearing it
    /// (`SetupJourneyView`, `SetupFooterBar`), so this is the one place it is forgotten after a press.
    func savePC(password: String) {
        returnLook = nil
        state.refusal = nil
        if run(.savePC, password: password) { credentials.clear() }
    }

    func created(_ end: CreateWindowController.EmbeddedEnd) {
        creator?.unembed()
        state.creating = false
        state.step = .vm
        if case .installed(let id, _, let messages, let disk) = end {
            state.setupDisk = disk
            state.answers = SetupFlow.Answers()
            state.answers.started = true
            syncAnswers()
            state.installedVMID = id
            state.installMessages = messages
            state.afterInstall = Date()
        }
        readByItself(.checkAgain(.vm))
    }

    /// Only an open window requests new work, and says whether the runner took it. A refusal is kept
    /// to be said on that window.
    ///
    /// `next` is the answers the press gives — Try Again's "not answered yet", a Discard's "left
    /// alone", another VM's fresh start. They go to the runner with the press, which adopts them only
    /// once it has taken it (`SetupRunner.run`), and they become the window's only then too. A refused
    /// press changes nothing: Try Again on a failed Connect used to clear "didn't work" first, so a
    /// refusal turned the recovery card into "Ready to test" over a press that never started. A
    /// refusal carries them (`Refusal.answers`), to judge whether it's still worth choosing again.
    @discardableResult
    private func run(_ work: SetupRunner.Work, password: String? = nil, answers next: SetupFlow.Answers? = nil) -> Bool {
        guard isPresented, let runner else { return false }
        if var refusal = runner.run(work, password: password, answers: next ?? state.answers) {
            refusal.answers = next
            state.refusal = refusal
            // The gate's words are true only while what holds it runs. The runner reads once the gate
            // is free, on the menu's next tick, and the page's refusal says it in the past tense then.
            if refusal.reason != nil { runner.readWhenFree() }
            return false
        }
        if let next {
            state.answers = next
            syncAnswers()
        }
        // A Check Again somebody pressed reads all an owed read would have, and more.
        if case .checkAgain(let step) = work, let owed = owedRead, step >= owed.step { owedRead = nil }
        return true
    }

    /// `work`, and `command` once it has ended well (`afterWork`). Nothing follows a refused press.
    @discardableResult
    private func run(_ work: SetupRunner.Work, answers next: SetupFlow.Answers? = nil, then command: SetupCommand) -> Bool {
        guard run(work, answers: next) else { return false }
        afterWork = (work, command, false)
        return true
    }
}

/// Escape closes the window, which is harmless here (closing never cancels), the way a Mac panel
/// answers it. On the welcome, **Not Now** has Escape first, as the cancel button.
///
/// Every mouse-down and key-down is told to the controller before it goes anywhere
/// (`SetupWindowController.personActed`), so a look on coming back never starts under a press.
private final class SetupNSWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { performClose(sender) }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .keyDown {
            (delegate as? SetupWindowController)?.personActed()
        }
        super.sendEvent(event)
    }
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
    /// Watched, not just held: whether the footer's **Save It** can be pressed follows what is typed.
    @ObservedObject var credentials = SetupCredentials()
    var savePassword: (String) -> Void = { _ in }
    let send: (SetupCommand) -> Void

    var body: some View {
        let footer = SetupFooter.footer(state)
        withSetupAppearance { look in
            VStack(spacing: 0) {
                if SetupScreen.showsHeader(state) {
                    SetupHeader(state: state)
                        .frame(maxWidth: SetupStyle.contentWidth)
                        .padding(.horizontal, SetupStyle.pagePadding)
                        .padding(.top, 10)
                        .padding(.bottom, SetupStyle.headerBelow)
                }
                if state.creating, let embedded {
                    embedded(ArmieHost.lent(state, art: art, send: send))
                } else {
                    GeometryReader { viewport in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                // Armie beside the title, where `ArmieCue` has him there: every page but
                                // the two arrivals, which draw him larger themselves.
                                if let title = SetupScreen.pageTitle(state) {
                                    SetupPageHead(title: title, armie: SetupScreen.besideTitle(state), art: art, send: send)
                                }
                                content
                            }
                            .frame(maxWidth: SetupStyle.contentWidth, alignment: .leading)
                            .padding(.horizontal, SetupStyle.pagePadding)
                            .padding(.top, SetupStyle.titleAbove)
                            .padding(.bottom, SetupStyle.pagePadding)
                            // The welcome and the finished page sit in the middle of the page rather than on
                            // top of an empty half: both are an arrival, not a form.
                            .frame(maxWidth: .infinity, minHeight: viewport.size.height,
                                   alignment: state.step == .welcome || state.finished ? .center : .top)
                        }
                    }
                    SetupFooterBar(footer: footer, credentials: credentials, savePassword: savePassword, send: send)
                }
            }
            .frame(minWidth: 600, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(SetupBackdrop().ignoresSafeArea())
            // While the footer's corner is the filled default, a step's own main button on the page
            // stands down to a plain one (`stepPrimaryButton`): one filled button, one owner of Return.
            .environment(\.footerHoldsDefault, footer.holdsDefault(passwordTyped: !credentials.password.isEmpty))
            // The palette's quiet, problem and caution colours, for these pages and the New Windows VM
            // views embedded in them.
            .setupHosted(look)
            // One button size in the whole window: in-card buttons were regular rounded rectangles
            // beside the footer's large capsules.
            .controlSize(.large)
            // The accent a word or a line takes: a bordered button's title is one, and in dark mode the
            // fill blue behind white text is too deep to be read on a dark bezel. The default button
            // is the one filled shape, and takes the fill (`primaryButton`).
            .tint(look.accentText)
        }
    }

    /// Whether the step bar and its counter head the page. Not on the welcome, which is a cover rather
    /// than a step: "Step 1 of 8" over "Welcome to Winbar" counted the greeting as work, and the bar's
    /// first segment sat over a hero whose mark already says whose window this is. Pure.
    static func showsHeader(_ state: SetupWindowState) -> Bool { state.step != .welcome }

    /// The page's one title, under the step bar, or nil where the page has none of its own: the
    /// welcome, which draws its own over its mark (`WelcomeView`), and the New Windows VM views while
    /// they are step 2, which head themselves. Step 1's says its state's one point
    /// (`LookAroundPage.Page.title`). Until a page says something more particular, its step's name. Pure.
    static func pageTitle(_ state: SetupWindowState) -> String? {
        switch state.step {
        case .welcome: return nil
        case .lookAround: return LookAroundPage.page(state).title
        case .vm: return state.creating ? nil : SetupCopy.stepName(.vm)
        case .tune: return SetupCopy.Tune.heading
        case .certificate: return SetupCopy.Certificate.heading
        case .savedPC: return SetupCopy.SavedPC.heading
        case .connect: return SetupCopy.Connecting.heading
        case .finish: return SetupFinishPage.title(state)
        }
    }

    /// Armie beside the page's title (`SetupPageHead`): `ArmieCue`'s, on every page with a title of
    /// its own, which is every page but the welcome and the finished page, whose arrivals draw him
    /// larger (`WelcomeView`, `FinishArrival`). Pure.
    static func besideTitle(_ state: SetupWindowState) -> ArmieCue? {
        guard pageTitle(state) != nil else { return nil }
        return ArmieCue.cue(state)
    }

    @ViewBuilder private var content: some View {
        switch state.step {
        case .welcome:
            WelcomeView(paragraphs: SetupCopy.Welcome.body(lastBuilt: SetupWindowState.lastBuilt),
                        armie: ArmieCue.cue(state), art: art, send: send)
        case .lookAround:
            LookAroundView(page: LookAroundPage.page(state), refusal: state.refusal, busy: state.inFlight,
                           offersReport: BetaReport.cards(state).contains(.lookAround), send: send)
        case .vm:
            SetupVMView(state: state, send: send)
        case .tune, .certificate, .savedPC, .connect, .finish:
            SetupJourneyView(state: state, credentials: credentials, savePassword: savePassword,
                             armie: state.finished ? ArmieCue.cue(state) : nil, art: art, send: send)
        }
    }
}

/// The step bar and the counter, on one compact row: where the person is, in about 20 pt. The window's
/// own name is in its title bar, where a Mac window's name goes, and the page's title is the page's
/// (`SetupPageTitle`). The header used to say the step's name at 20 pt, over the bar and its eight
/// labels, over a page title: three layers of heading before a word of instruction.
struct SetupHeader: View {
    let step: WizardStep
    var finished = false
    var flagged: Set<WizardStep> = []

    init(step: WizardStep, finished: Bool = false, flagged: Set<WizardStep> = []) {
        self.step = step
        self.finished = finished
        self.flagged = flagged
    }

    init(state: SetupWindowState) {
        self.init(step: state.step, finished: state.finished, flagged: StepBar.flagged(state))
        passedOver = StepBar.passedOver(state)
    }

    /// What each flagged step's segment says happened (`StepBar.passedOver`).
    var passedOver: [WizardStep: String] = [:]

    var body: some View {
        withSetupAppearance { look in
            HStack(alignment: .center, spacing: 16) {
                StepBar(current: step, finished: finished, flagged: flagged, passedOver: passedOver)
                // The bar's own VoiceOver label says the count and the step's name; this is for the eye.
                Text(SetupCopy.stepCounter(step))
                    .font(.system(size: SetupStyle.smallestText, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(look.mutedText)
                    .fixedSize()
                    .accessibilityHidden(true)
            }
        }
    }
}

/// All eight steps, the current one marked: the window's one progress device. Not clickable: the
/// steps depend on each other, and a wizard that lets you jump ahead is a wizard that lies (§2).
/// VoiceOver reads it as one sentence; the pointer is told each step and how it stands, and what
/// happened to a step passed over (`hovers`).
///
/// No labels under the segments. At the 12 pt floor for text that matters, "Look around" is 70 pt and
/// a segment beside the counter about 55: the labels shrank to 9.35 pt to fit, which is no label.
/// The page's title says where the person is; the counter says how far.
struct StepBar: View {
    let current: WizardStep
    var finished = false
    var flagged: Set<WizardStep> = []
    /// What happened to each flagged step, and why (`passedOver(_:)`), for its segment's hover.
    var passedOver: [WizardStep: String] = [:]

    /// `flagged`: done, but skipped or failed, so the finish doesn't read as all well when a step
    /// was passed over.
    enum Mark: Equatable { case done, current, pending, flagged }

    /// The gap between segments.
    static let spacing: CGFloat = 4
    /// A segment's line, and the current step's, which is taller: the current step is marked by its
    /// shape as well as its place, not by colour alone.
    static let line: CGFloat = 4
    static let currentLine: CGFloat = 8

    /// Everything before the cursor is done: the window only ever stands on the first step with
    /// something left to do, going back when an earlier one comes undone (`SetupFlow.landing`). Once
    /// the window is finished, all eight are, the last included — the bar used to stop one short of
    /// complete on the page that says it is. A done step in `flagged` is marked as such. Pure.
    static func marks(current: WizardStep, finished: Bool = false, flagged: Set<WizardStep> = []) -> [Mark] {
        WizardStep.allCases.map { step in
            if finished || step < current { return flagged.contains(step) ? .flagged : .done }
            return step == current ? .current : .pending
        }
    }

    /// The steps passed over without doing what they're for: the certificate skipped, the saved PC or
    /// Windows App skipped, and Connect left without the desktop confirmed. Only steps behind the
    /// window count (`marks`). Pure.
    ///
    /// A step skipped and since found done isn't passed over: a certificate trusted after all, or a
    /// saved PC that reads saved — which, where Windows App's command line never answers, is Connect
    /// having used it (`Recipe.unansweredSavedPCStatus`). Live, the owner skipped the saved PC, saved
    /// it by hand, connected through it, and the bar still flagged it.
    static func flagged(_ state: SetupWindowState) -> Set<WizardStep> {
        var steps: Set<WizardStep> = []
        if state.answers.leftAlone.contains("H7"), state.facts?.kind("H7") != .ok { steps.insert(.certificate) }
        if !state.answers.leftAlone.isDisjoint(with: ["C1", "C2"]) {
            if let facts = state.facts, case .saved = SetupFlow.savedPC(facts) {} else { steps.insert(.savedPC) }
        }
        if state.finished || state.step > .connect, state.answers.connected != true { steps.insert(.connect) }
        return steps
    }

    /// What happened to each step `flagged(_:)` marks, and why, from what Winbar read
    /// (`SetupCopy.passedOver`): the words its segment's hover gives after the step's name, and the
    /// finished page's list gives beside it. Pure.
    static func passedOver(_ state: SetupWindowState) -> [WizardStep: String] {
        guard let facts = state.facts else { return [:] }
        var words: [WizardStep: String] = [:]
        for step in flagged(state) { words[step] = SetupCopy.passedOver(step, facts) }
        return words
    }

    /// What the pointer is told over each segment, in the bar's order (`SetupCopy.stepBarHelp`). Pure.
    static func hovers(current: WizardStep, finished: Bool = false, flagged: Set<WizardStep> = [],
                       passedOver: [WizardStep: String] = [:]) -> [String] {
        let marks = marks(current: current, finished: finished, flagged: flagged)
        return WizardStep.allCases.enumerated().map { index, step in
            SetupCopy.stepBarHelp(step, marks[index], passedOver: passedOver[step])
        }
    }

    /// Each segment's width: all equal, so the bar has one rhythm. Pure.
    static func segmentWidth(total: CGFloat, count: Int = WizardStep.allCases.count) -> CGFloat {
        max(0, (total - spacing * CGFloat(count - 1)) / CGFloat(count))
    }

    var body: some View {
        withSetupAppearance { look in
            GeometryReader { bar in
                let marks = StepBar.marks(current: current, finished: finished, flagged: flagged)
                let hovers = StepBar.hovers(current: current, finished: finished, flagged: flagged, passedOver: passedOver)
                let width = StepBar.segmentWidth(total: bar.size.width)
                HStack(alignment: .center, spacing: StepBar.spacing) {
                    ForEach(Array(WizardStep.allCases.enumerated()), id: \.offset) { index, _ in
                        segment(marks[index], look)
                            .frame(width: width, height: bar.size.height)
                            // AppKit's own tooltip, not `.help` (`HoverText` says why).
                            .overlay(HoverText(hovers[index]))
                    }
                }
            }
            .frame(height: 14)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(SetupCopy.stepBarLabel(current))
            .accessibilityValue(SetupCopy.stepBarFlagged(WizardStep.allCases.filter {
                StepBar.marks(current: current, finished: finished, flagged: flagged)[$0.index] == .flagged
            }) ?? "")
        }
    }

    /// A segment: a line on the backdrop, so the accent's line-and-word shade, not its fill. Done and
    /// current in the accent, at full strength (done was 55%, 2.4:1, and faded as the person finished);
    /// still to come in the palette's track grey; a flagged step in the attention orange with its mark
    /// in the middle of the line.
    @ViewBuilder private func segment(_ mark: Mark, _ look: SetupAppearance) -> some View {
        switch mark {
        case .done:
            Capsule().fill(look.accentText).frame(height: StepBar.line)
        case .current:
            Capsule().fill(look.accentText).frame(height: StepBar.currentLine)
        case .pending:
            Capsule().fill(look.palette.track.color).frame(height: StepBar.line)
        case .flagged:
            HStack(spacing: 3) {
                Capsule().fill(look.attention).frame(height: StepBar.line)
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(look.attention)
                Capsule().fill(look.attention).frame(height: StepBar.line)
            }
        }
    }
}

private extension WizardStep {
    var index: Int { WizardStep.allCases.firstIndex(of: self) ?? 0 }
}

/// AppKit's own tooltip over a view: a transparent `NSView` laid over it, with `toolTip` set.
///
/// The step bar's segments had SwiftUI's `.help`, inside a bar that hands VoiceOver one element with
/// its children ignored (so the bar reads as one sentence). On macOS `.help` keeps its words with the
/// view's accessibility, and live, the owner found no useful hover on a flagged segment. Whether a
/// `.help` survives an ignoring parent couldn't be settled offscreen — SwiftUI builds neither its
/// tooltips nor its accessibility tree until someone points or asks — so the segments carry a plain
/// `NSView.toolTip`, which AppKit shows whatever VoiceOver is told, and which a test can read back off
/// the drawn bar. Never an accessibility element itself: VoiceOver has the bar's label and value.
struct HoverText: NSViewRepresentable {
    let text: String

    init(_ text: String) { self.text = text }

    func makeNSView(context: NSViewRepresentableContext<HoverText>) -> TipView {
        let view = TipView()
        view.toolTip = text
        return view
    }

    func updateNSView(_ view: TipView, context: NSViewRepresentableContext<HoverText>) {
        if view.toolTip != text { view.toolTip = text }
    }

    final class TipView: NSView {
        override func isAccessibilityElement() -> Bool { false }
    }
}

// MARK: Step 0

/// The welcome, composed as Apple's setup assistants open: Winbar's mark, a title, one sentence of
/// what Winbar is, then what this window does, how long it takes and what macOS may ask, one line each.
/// Where Armie is (`ArmieCue`), he is the mark, at his larger size, introducing himself: he is the app's
/// icon already, and every page after this one has him on it. Hidden, the mark is Winbar's four panes.
struct WelcomeView: View {
    /// What the welcome promises: `SetupCopy.Welcome.body(lastBuilt:)`.
    let paragraphs: [String]
    var armie: ArmieCue? = nil
    var art: ArmieArt? = nil
    var send: (SetupCommand) -> Void = { _ in }

    /// The welcome's title: larger than a page's (`SetupPageTitle.size`), as a cover's is, and about
    /// the 28 pt the review asked for.
    static let titleSize: CGFloat = 28

    var body: some View {
        withSetupAppearance { look in
            VStack(spacing: 28) {
                VStack(spacing: 12) {
                    if let armie, let art {
                        ArmieSays(cue: armie, art: art, size: ArmieSays.hero, send: send)
                            // Read after the welcome's own words: they say what this is, and he only
                            // says who he is.
                            .accessibilitySortPriority(-1)
                    } else {
                        WinbarMark(size: 64)
                            .padding(.bottom, 4)
                    }
                    Text(SetupCopy.Welcome.title)
                        .font(.system(size: Self.titleSize, weight: .bold))
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                    // Quieter than the title, as a subtitle is; the palette's muted grey keeps 4.5:1 on
                    // the backdrop.
                    Text(SetupCopy.Welcome.lead)
                        .font(.system(size: 15))
                        .foregroundStyle(look.mutedText)
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
            .accessibilityElement(children: .contain)
        }
    }
}

// MARK: Step 1

struct LookAroundView: View {
    let page: LookAroundPage.Page
    let refusal: SetupRunner.Refusal?
    /// What runs now, for the refusal's words: still going, or done (`SetupCopy.Working.refused`).
    var busy: SetupRunner.InFlight? = nil
    /// The card is a failure's, and the beta is on: **Send This to the Developer** at its foot
    /// (`BetaReport.cards`). Step 1's own buttons are the footer's, so it has the card to itself.
    var offersReport = false
    let send: (SetupCommand) -> Void

    var body: some View {
        withSetupAppearance { look in
            VStack(alignment: .leading, spacing: 14) {
                // First, where a press that changed nothing is explained: at the bottom, in grey, it fell
                // under the footer at the window's size, and the person saw nothing happen.
                if let refusal {
                    RefusalBanner(text: SetupCopy.Working.refused(refusal, busy: busy, host: LookAroundPage.host.name))
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
                } else if let note = page.note {
                    // In line with the words in the card above it.
                    QuietText(AttributedString(note)).padding(.horizontal, SetupStyle.cardPadding)
                }
            }
        }
    }

    @ViewBuilder private var card: some View {
        // The card's point is the page's title (`LookAroundPage.Page.title`); the card opens on what to
        // do, and folds anything longer under Show Details.
        VStack(alignment: .leading, spacing: 12) {
            if let text = LookAroundPage.cardText(page.card) {
                text
            } else {
                drawnCard
            }
            let details = LookAroundPage.details(page.card)
            if !details.isEmpty {
                DetailsDisclosure {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(details.enumerated()), id: \.offset) { _, paragraph in
                            QuietText(AttributedString(paragraph)).setupProse()
                        }
                    }
                }
            }
            if offersReport { SendToDeveloperButton { send(.sendReport) } }
        }
    }

    /// The two cards that are more than words: the install while it runs, and its failure.
    @ViewBuilder private var drawnCard: some View {
        switch page.card {
        case .installing(let lines, let update, let download):
            // What is happening — the bar and one line saying it in words; Armie narrates it beside the
            // page's title. Homebrew's own output is folded away: in monospace, on screen for the whole
            // of a healthy install, it read as something gone wrong.
            VStack(alignment: .leading, spacing: 12) {
                InstallProgress(download: download,
                                status: SetupCopy.LookAround.progress(lines.last, download: download, update: update))
                if !lines.isEmpty {
                    DetailsDisclosure { OutputBox(lines: lines, rows: OutputBox.liveRows) }
                }
            }
        case .installFailed(let problem, let lines, let slept):
            // What to do first; then Homebrew's last words, open, since on a failure they are the
            // explanation (Homebrew's own "its output is above" becomes "below", `forWindow`).
            VStack(alignment: .leading, spacing: 10) {
                if !problem.detail.isEmpty {
                    Text(SetupCopy.LookAround.forWindow(problem.detail)).setupProse()
                }
                if slept {
                    QuietText(SetupCopy.Working.slept(while: "installing UTM"))
                }
                if !lines.isEmpty {
                    DetailsDisclosure(open: true) { OutputBox(lines: lines) }
                }
            }
        default:
            EmptyView()
        }
    }
}

/// What only some people want to read, folded under one line — **Show Details** — that opens it in
/// place. Open to begin with where the details are the explanation: a failure's own output. The
/// chevron and the words are in the accent, as something to press is; the review measured the
/// system's grey chevron at 1.78:1 in light mode.
struct DetailsDisclosure<Content: View>: View {
    @State private var open: Bool
    let content: Content

    init(open: Bool = false, @ViewBuilder content: () -> Content) {
        _open = State(initialValue: open)
        self.content = content()
    }

    var body: some View {
        withSetupAppearance { look in
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { open.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .bold))
                            .rotationEffect(.degrees(open ? 90 : 0))
                            .accessibilityHidden(true)
                        Text(open ? SetupCopy.LookAround.bHideDetails : SetupCopy.LookAround.bShowDetails)
                    }
                    .foregroundStyle(look.accentText)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if open { content }
            }
        }
    }
}

/// Why a press did nothing: the runner does one thing at a time and something else is running. The
/// window's information `Callout`, with an hourglass for "wait" — it answers something the person just
/// did, so it must be where they look, and it isn't an error. VoiceOver hears it as it appears
/// (`SetupAnnouncement`), since the person's focus is on the button they pressed, not on it.
struct RefusalBanner: View {
    let text: AttributedString

    var body: some View {
        // Plain words: the refusal names the work, and a VM's name can be in it.
        Callout(.info, symbol: "hourglass", text)
    }
}

/// A card's words, in the one order every card uses: a heading that says the point, where the page's
/// title doesn't (step 1's cards have none: their point is the title); a lead under it; the body at the
/// normal weight; the one thing the person has to do or decide, set apart in semibold; and an aside,
/// smaller and quieter, for what only some people will want.
struct CardText: View {
    var heading: String = ""
    var lead: AttributedString?
    var paragraphs: [AttributedString] = []
    var emphasis: AttributedString?
    var aside: AttributedString?

    var body: some View {
        // Each line of prose at the readable measure (`setupProse`): at the card's full width they ran
        // to 95 characters.
        VStack(alignment: .leading, spacing: 10) {
            if !heading.isEmpty { CardTitle(heading).setupProse() }
            if let lead { Text(lead).setupProse() }
            ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                Text(paragraph).setupProse()
            }
            if let emphasis { Text(emphasis).fontWeight(.semibold).setupProse() }
            if let aside { QuietText(aside).setupProse() }
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
    /// The one line under the bar saying what's happening (`SetupCopy.LookAround.progress`); nil for the
    /// download's count alone.
    var status: String?

    var body: some View {
        withSetupAppearance { look in
            VStack(alignment: .leading, spacing: 6) {
                if let download {
                    ProgressView(value: download.fraction)
                        .tint(look.accentText)
                } else {
                    ProgressView().progressViewStyle(.linear).tint(look.accentText)
                }
                if let line = status ?? download.map({ SetupCopy.LookAround.downloaded(done: $0.done, total: $0.total) }) {
                    Text(line)
                        .font(.callout).foregroundStyle(look.mutedText).monospacedDigit()
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// Armie with what he says beside him: his figure, and his line, if `ArmieCue` gives him one, in his
/// bubble (`ArmieBubble`) to the right of it — the arrivals' larger Armie, on the welcome and the
/// finished page (`hero`). Beside a page's title he is `SetupPageHead`'s instead, with the same bubble
/// under the title; the finished page draws his figure in its mark (`FinishMark`), with its tick or
/// triangle on his corner.
struct ArmieSays: View {
    let cue: ArmieCue
    let art: ArmieArt
    var size: CGFloat = ArmieSays.small
    let send: (SetupCommand) -> Void

    /// Astra's two reference sizes: beside a title, and on an arrival.
    static let small: CGFloat = 56
    static let hero: CGFloat = 96
    /// The ✕'s target: 24 pt square, as Apple asks of the smallest control a pointer should find,
    /// though the ✕ drawn in it is 9 pt. "Hide Armie" was a 10 pt text link about 13 pt tall.
    static let hideTarget: CGFloat = 24
    /// An arrival's bubble: one or two lines beside him, never a paragraph across the page.
    static let heroBubble: CGFloat = 300

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            ArmieFigure(art: art, pose: cue.pose, size: size)
            if let line = cue.line {
                ArmieBubble(line: line, tail: .leading, send: send)
                    .frame(maxWidth: Self.heroBubble, alignment: .leading)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// What Armie says, in a speech bubble pointing at him, so the words read as his rather than as the
/// window's; his name over it in the muted grey, semibold; and a small ✕ in its corner that retires
/// him for good (no "are you sure": he goes quietly). The accent is for what can be pressed, and his
/// name and "Hide Armie" were both in it, so both read as links. One bubble for every placement, so
/// no page grows one that drifts from the others.
///
/// VoiceOver reads his name and line once, as one element, where the bubble is in the page; nothing
/// announces it as it comes or goes, since it is never news (`SetupAnnouncement` says what is).
struct ArmieBubble: View {
    let line: String
    var tail: SpeechBubble.Tail = .leading
    let send: (SetupCommand) -> Void

    var body: some View {
        withSetupAppearance { look in
            VStack(alignment: .leading, spacing: 2) {
                Text(SetupCopy.Armie.name)
                    .font(.system(size: SetupStyle.smallestText, weight: .semibold))
                    .foregroundStyle(look.mutedText)
                Text(line).fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .padding(.leading, 12 + (tail == .leading ? SpeechBubble.tail : 0))
            .padding(.trailing, ArmieSays.hideTarget + 2)
            .padding(.top, 9 + tail.above)
            .padding(.bottom, 9)
            .background {
                let bubble = SpeechBubble(tail: tail)
                ZStack {
                    bubble.fill(look.palette.card.color)
                    bubble.fill(Color.primary.opacity(look.increasedContrast ? 0 : 0.03))
                }
                .overlay(bubble.stroke(look.increasedContrast ? Color.primary.opacity(0.6) : look.stroke,
                                       lineWidth: look.increasedContrast ? 1.5 : 1))
            }
            .overlay(alignment: .topTrailing) { ArmieHideButton(send: send).padding(2).padding(.top, tail.above) }
            .accessibilityElement(children: .contain)
        }
    }
}

/// The ✕ in Armie's bubble that retires him: a 9 pt glyph in a 24 pt target, the whole of which
/// takes the click. Named for VoiceOver and the pointer as the text link it replaces was.
struct ArmieHideButton: View {
    let send: (SetupCommand) -> Void

    var body: some View {
        withSetupAppearance { look in
            Button { send(.hideArmie) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(look.mutedText)
                    .frame(width: ArmieSays.hideTarget, height: ArmieSays.hideTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(SetupCopy.Armie.bRetire)
            .accessibilityLabel(SetupCopy.Armie.bRetire)
        }
    }
}

/// A speech bubble: the window's card shape with a tail pointing at whoever speaks — from its leading
/// edge, halfway down, at an Armie beside it; or from its top edge, `fromTrailing` in from its
/// trailing edge, at an Armie above it (beside a page's title). The tail is kept clear of the corners
/// on a short or narrow bubble.
struct SpeechBubble: Shape {
    enum Tail: Equatable {
        case leading
        case top(fromTrailing: CGFloat)

        /// The room the tail takes above the bubble's body.
        var above: CGFloat { if case .top = self { return SpeechBubble.tail }; return 0 }
    }

    static let tail: CGFloat = 7
    var tail: Tail = .leading
    var radius: CGFloat = 10

    func path(in rect: CGRect) -> Path {
        let half: CGFloat = 6
        switch tail {
        case .leading:
            let body = CGRect(x: rect.minX + Self.tail, y: rect.minY, width: max(0, rect.width - Self.tail), height: rect.height)
            let r = min(radius, body.height / 2, body.width / 2)
            let y = min(max(body.midY, body.minY + r + half), body.maxY - r - half)
            var path = Path()
            path.move(to: CGPoint(x: body.minX + r, y: body.minY))
            path.addArc(tangent1End: CGPoint(x: body.maxX, y: body.minY), tangent2End: CGPoint(x: body.maxX, y: body.maxY), radius: r)
            path.addArc(tangent1End: CGPoint(x: body.maxX, y: body.maxY), tangent2End: CGPoint(x: body.minX, y: body.maxY), radius: r)
            path.addArc(tangent1End: CGPoint(x: body.minX, y: body.maxY), tangent2End: CGPoint(x: body.minX, y: body.minY), radius: r)
            path.addLine(to: CGPoint(x: body.minX, y: y + half))
            path.addLine(to: CGPoint(x: rect.minX, y: y))
            path.addLine(to: CGPoint(x: body.minX, y: y - half))
            path.addArc(tangent1End: CGPoint(x: body.minX, y: body.minY), tangent2End: CGPoint(x: body.maxX, y: body.minY), radius: r)
            path.closeSubpath()
            return path
        case .top(let fromTrailing):
            let body = CGRect(x: rect.minX, y: rect.minY + Self.tail, width: rect.width, height: max(0, rect.height - Self.tail))
            let r = min(radius, body.height / 2, body.width / 2)
            let x = min(max(body.maxX - fromTrailing, body.minX + r + half), body.maxX - r - half)
            var path = Path()
            path.move(to: CGPoint(x: body.minX + r, y: body.minY))
            path.addLine(to: CGPoint(x: x - half, y: body.minY))
            path.addLine(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x + half, y: body.minY))
            path.addArc(tangent1End: CGPoint(x: body.maxX, y: body.minY), tangent2End: CGPoint(x: body.maxX, y: body.maxY), radius: r)
            path.addArc(tangent1End: CGPoint(x: body.maxX, y: body.maxY), tangent2End: CGPoint(x: body.minX, y: body.maxY), radius: r)
            path.addArc(tangent1End: CGPoint(x: body.minX, y: body.maxY), tangent2End: CGPoint(x: body.minX, y: body.minY), radius: r)
            path.addArc(tangent1End: CGPoint(x: body.minX, y: body.minY), tangent2End: CGPoint(x: body.maxX, y: body.minY), radius: r)
            path.closeSubpath()
            return path
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
            // 12 pt, the floor for words that matter: a failure's last words are what explain it.
            .font(.system(size: SetupStyle.smallestText, design: .monospaced))
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
