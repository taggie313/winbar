import AppKit
import SwiftUI

// The three views the window shows once there's a job — progress, done and failed — with the pure
// mapping from a `CreateJobState` to what they say in `CreateProgress`, so the wording and the
// ordering can be tested without a window.
//
// The stage titles themselves live with the job (CreateJob.swift), so Terminal and this
// window can't drift apart. The rows, their marks and the orange box are StepList.swift's, so the
// setup wizard can draw with the same ones.

/// How long something has been going, in the two shapes the design uses.
enum CreateElapsed {
    /// The clocks beside the header and the running stage: `14:32`, `1:04:09`.
    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds.rounded(.down)))
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// The menu's `(14 min)` and the done view's `31 min`. Minutes only: seconds in a menu that
    /// redraws when it opens would just be noise.
    static func minutes(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds.rounded(.down)))
        if total < 60 { return "less than a minute" }
        let m = total / 60
        if m < 60 { return "\(m) min" }
        let (hours, rest) = (m / 60, m % 60)
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }
}

/// Everything the progress and ending views show, worked out from the job's state alone.
struct CreateProgress: Equatable {
    /// `attention` is never an install's: it is the set-up window's `!`, for a row waiting on the
    /// person rather than broken (UTM not installed yet, utmctl silent behind the Automation prompt).
    enum Mark: Equatable { case done, running, pending, failed, attention }

    struct Row: Equatable {
        var stage: CreateStage
        var mark: Mark
        var title: String
        /// The stage's detail line, only while it's the one running.
        var detail: String?
        /// How long the running stage has been going, as a clock.
        var elapsed: String?
    }

    /// A note or warning the job raised, as the window shows it. The job says each
    /// one once and keeps them in order, so a window opened late shows the same list Terminal
    /// printed as they happened.
    struct Note: Equatable {
        var code: String
        var text: String
        /// In a box rather than as a quiet line under the stages.
        var boxed: Bool
    }

    /// The warnings that make something the password copy promised untrue: the
    /// setup disk that couldn't be kept out of Time Machine or deleted, the answer-file copies
    /// Windows kept, the automatic sign-in password it left in plain text. Each contradicts a line
    /// the person has already read, so it can't be a footnote.
    static let boxedCodes: Set<String> = ["W_TIMEMACHINE", "W_MEDIA_LEFT", "W_PANTHER", "W_AUTOLOGON_PLAINTEXT"]

    /// done, failed or cancelled; nil while it runs.
    var outcome: CreateJobState.Outcome?
    var header: String
    /// The whole install's time as a clock, for the ending's own column.
    var elapsed: String
    /// "Stage 6 of 10 · Copying files": the install's own count, named so it isn't read as a second
    /// "step" under the setup window's "Step 3 of 8", with what the stage is.
    var step: String
    /// "14 min so far · usually 10–15 min": the running time, said as one, beside what to expect. The
    /// header's bare "14:32" didn't say what it counted.
    var soFar: String
    var fraction: Double
    var rows: [Row]
    /// W_STALL or W_STALL_BUSY, while that stall is still true.
    var stall: String?

    /// What the box says when the job's own message isn't in the state — a state file whose messages
    /// were trimmed, or a window opened on a job an older Winbar started. The words are the same.
    static func stallFallback(_ alert: InstallAlert, vmName: String) -> String {
        alert == .stallBusy ? CreateCopy.wStallBusy(vmName: vmName, restarted: false)
                            : CreateCopy.wStall(vmName: vmName)
    }
    /// Everything the job has said so far, in the order it said it.
    var notes: [Note]

    /// The job writes one detail line for both front-ends; the window says who macOS is asking about
    /// (P_AUTOMATION), because in the window it's always Winbar.
    static func detail(_ detail: String?) -> String? {
        guard let detail else { return nil }
        return detail.contains(CreateCopy.automationDetailMark) ? CreateCopy.pAutomation : detail
    }

    init(state: CreateJobState, now: Date) {
        outcome = state.outcome
        header = CreateCopy.pHeader(edition: state.plan.edition.displayName, name: state.plan.vmName)
        let end = state.finishedAt ?? now
        elapsed = CreateElapsed.clock(end.timeIntervalSince(state.startedAt))
        step = CreateCopy.pStage(state.stage)
        soFar = CreateCopy.pSoFar(end.timeIntervalSince(state.startedAt))
        fraction = Double(state.stage.number - (state.isFinished ? 0 : 1)) / 10
        let failedHere = state.outcome == .failed
        rows = CreateStage.allCases.map { stage in
            if stage.number < state.stage.number {
                return Row(stage: stage, mark: .done, title: stage.doneTitle)
            }
            if stage == state.stage {
                if state.outcome == .done { return Row(stage: stage, mark: .done, title: stage.doneTitle) }
                let mark: Mark = failedHere ? .failed : .running
                // Since the stage began, not since the job last wrote anything: `updatedAt` is
                // rewritten on every save, which during the copy stage is every 30 seconds, so the
                // clock would restart at 0:00 twenty times over. A state file from a Winbar that
                // didn't record the stage's start falls back to it all the same.
                let began = state.stageStartedAt ?? state.updatedAt
                // In minutes, as a duration, like the header's: a second ticking clock beside the
                // header's read as two unlabelled times.
                return Row(stage: stage, mark: mark, title: stage.runningTitle,
                           detail: CreateProgress.detail(state.detail),
                           elapsed: mark == .running ? CreateElapsed.minutes(end.timeIntervalSince(began)) : nil)
            }
            return Row(stage: stage, mark: .pending, title: stage.runningTitle)
        }
        // The job says which stall is true right now, if either is, so the box says the right words
        // and goes as soon as the VM writes again, rather than staying up for the rest of the stage
        // it appeared in. It shows the very sentence the job said when it raised the warning — and
        // that warning is then left out of the list below, which would otherwise print it twice.
        let live = state.isFinished ? nil : state.stalled?.alert
        stall = live.map { alert in
            CreateCopy.forWindow(state.messages.last { $0.code == alert.rawValue }?.text
                ?? CreateProgress.stallFallback(alert, vmName: state.plan.vmName), vmName: state.plan.vmName)
        }
        notes = state.messages.filter { $0.code != live?.rawValue }.map {
            Note(code: $0.code, text: CreateCopy.forWindow($0.text, vmName: state.plan.vmName),
                 boxed: CreateProgress.boxedCodes.contains($0.code))
        }
    }
}

/// The progress, done and failure views: one `CreateJobState`, three shapes.
struct CreateJobView: View {
    @ObservedObject var controller: CreateWindowController
    let state: CreateJobState
    /// The wizard's Armie, while these views are its step 2 (`CreateRootView.armie`): beside the
    /// page's title, as on every page of the wizard (`JobHeading`, `ArmieCue.installing`).
    var armie: ArmieHost? = nil
    /// Quieter words: the system's secondary grey in the window of its own, the wizard's muted grey
    /// inside it (`setupHosted`), where the secondary measured 3.5 to 3.9:1 on the light backdrop.
    @Environment(\.quietText) private var quiet

    /// Inside the Set Up Winbar window, where the buttons go in the wizard's own footer band.
    @Environment(\.setupHosted) private var hosted
    /// The quieter notes of a running install, folded away until asked for (`runningBody`).
    @State private var showingNotes = false

    private var progress: CreateProgress { CreateProgress(state: state, now: controller.now) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch state.outcome {
                    case .done: doneBody
                    case .failed: failureBody
                    case .cancelled: cancelledBody
                    case nil: runningBody
                    }
                }
                // Inside Set Up Winbar the title sits where every other page's does, under the step
                // bar's row (`SetupStyle.titleAbove`), as the form's does; the window of its own keeps
                // its margin.
                .padding(.horizontal, SetupStyle.pagePadding)
                .padding(.top, hosted ? SetupStyle.titleAbove : SetupStyle.pagePadding)
                .padding(.bottom, SetupStyle.pagePadding)
                .frame(maxWidth: hosted ? SetupStyle.contentWidth + 2 * SetupStyle.pagePadding : .infinity, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            if hosted {
                // The wizard's own footer band, the one its other pages draw (`SetupFooterBand`): the
                // install drew a divider and buttons of its own, 9 pt higher, so the footer jumped when
                // an install started.
                SetupFooterBand { buttons }
            } else {
                Divider()
                buttons.padding(20)
            }
        }
    }

    // MARK: Running

    private var runningBody: some View {
        let progress = self.progress
        let (boxed, quiet) = (progress.notes.filter(\.boxed), progress.notes.filter { !$0.boxed })
        let heading = CreateJobView.heading(state, hosted: hosted)
        return VStack(alignment: .leading, spacing: 14) {
            // The page's title, a heading of its own (`JobHeading`): it sat inside the relabelled
            // element below, whose label dropped it, so VoiceOver never read the header at all.
            JobHeading(heading: heading, hosted: hosted, armie: armie, job: state)
            VStack(alignment: .leading, spacing: 8) {
                // Under the title, what is installed where; in the window of its own the headline says it.
                if hosted {
                    Text(CreateCopy.pSubtitle(edition: state.plan.edition.displayName, name: state.plan.vmName))
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(progress.step)
                    Spacer(minLength: 0)
                    Text(progress.soFar).monospacedDigit().foregroundStyle(self.quiet)
                }
                .font(.callout)
                ProgressView(value: progress.fraction)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(CreateJobView.progressLabel(progress, state: state, hosted: hosted))
            // A stall is the one thing here that needs the person, so it comes before the stages. Its
            // button, Show VM Window, is the footer's corner and Return's while it lasts (`actions`).
            if let stall = progress.stall {
                Callout(.attention) { Text(stall) }
            }
            StepList(rows: progress.rows)
            // The warnings that make something the password copy promised untrue stay in view; the
            // rest (a battery caution, FileVault) are there for whoever wants them.
            ForEach(boxed, id: \.code) { NoteBox($0.text) }
            if !quiet.isEmpty {
                DisclosureGroup(isExpanded: $showingNotes) {
                    noteList(quiet).padding(.top, 6)
                } label: {
                    Text(CreateCopy.pNotes(quiet.count)).font(.callout)
                }
            }
            if controller.readOnly {
                Text(CreateCopy.pFooterCLI).font(.callout).foregroundStyle(self.quiet)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // Not "you don't need to watch or click anything" under a stall that asks Ben to look
                // at the VM's window.
                Text(progress.stall == nil ? CreateCopy.pCloseWindow : CreateCopy.pCloseWindowStalled)
                    .font(.callout).foregroundStyle(self.quiet)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// What the job has said so far. Terminal prints these as they arrive; the window
    /// keeps the list, so closing it and coming back doesn't lose one — and the warnings D4's
    /// password copy depends on are boxed, not tucked under the stages.
    @ViewBuilder private func noteList(_ notes: [CreateProgress.Note]) -> some View {
        if !notes.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(notes, id: \.code) { note in
                    if note.boxed {
                        NoteBox(note.text)
                    } else {
                        Text(note.text)
                            .font(.callout)
                            .foregroundStyle(quiet)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    // MARK: Done

    private var doneBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                JobHeading(heading: CreateJobView.heading(state, hosted: hosted), hosted: hosted, armie: armie, job: state)
                Spacer()
                Text(CreateElapsed.minutes((state.finishedAt ?? controller.now).timeIntervalSince(state.startedAt)))
                    .foregroundStyle(quiet)
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow {
                    Text("Sign in as").foregroundStyle(quiet)
                    Text(state.plan.userName)
                }
                GridRow {
                    Text("Reach it at").foregroundStyle(quiet)
                    Text(CreateChoices.hostName(computerName: state.plan.computerName))
                }
            }
            if controller.isEmbedded {
                Text(SetupCopy.markdown(CreateCopy.doneEmbedded)).fixedSize(horizontal: false, vertical: true)
            } else {
            Text(CreateCopy.nNextCommand(plan: state.plan)).fixedSize(horizontal: false, vertical: true)
            HStack {
                // Not the literal "winbar setup": with this VM left unselected, Winbar's menu still
                // looks after the old one, and setup has to be told which VM this is.
                Text(CreateCopy.setupCommand(plan: state.plan))
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: 380, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.12)))
                Button(CreateCopy.bCopy) { controller.copySetupCommand() }
            }
            Text(CreateCopy.nNextSetup(savedPC: state.wroteSavedPC)).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 4) {
                bullet(state.usedProductKey ? CreateCopy.nActivating : CreateCopy.nNotActivated)
                bullet(CreateCopy.nUpdates)
            }
            noteList(progress.notes)
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("·").foregroundStyle(quiet)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
        .foregroundStyle(quiet)
    }

    // MARK: Failed and cancelled

    private var failureBody: some View {
        let progress = self.progress
        return VStack(alignment: .leading, spacing: 12) {
            JobHeading(heading: CreateJobView.heading(state, hosted: hosted), hosted: hosted, armie: armie, job: state)
            if let failure = state.failure {
                let detail = CreateJobView.failureDetail(failure)
                if !detail.isEmpty {
                    Text(detail).fixedSize(horizontal: false, vertical: true)
                }
                if let next = failure.nextStep.flatMap({ CreateCopy.windowNextStep($0, resumable: state.isResumable) }) {
                    Text(SetupCopy.markdown(next)).foregroundStyle(quiet).fixedSize(horizontal: false, vertical: true)
                }
            }
            if CreateJobView.offersReport(state) { SendToDeveloperButton { press(.sendReport) } }
            StepList(rows: progress.rows)
            noteList(progress.notes)
        }
    }

    private var cancelledBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            JobHeading(heading: CreateJobView.heading(state, hosted: hosted), hosted: hosted, armie: armie, job: state)
            // What this cancel did, when this window is the one that asked; otherwise what a cancel
            // does (the CLI's, or one this window didn't see).
            Text(controller.cancelNote ?? CreateCopy.cancelledNote)
                .foregroundStyle(quiet)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// What VoiceOver is told when the install ends — its heading — once per ending: nil while it
    /// runs, and nil for an ending already said (the same ended state arrives from the run's own
    /// callback and from the menu bar's follower). Pure.
    static func announcement(from old: CreateJobState?, to new: CreateJobState) -> String? {
        guard new.isFinished, !(old?.isFinished == true && old?.id == new.id) else { return nil }
        switch new.outcome {
        case .done:
            return CreateCopy.installed(edition: new.plan.edition.displayName, name: new.plan.vmName)
        case .failed:
            return failureHeader(new)
        case .cancelled:
            return CreateCopy.cancelledHeader(name: new.plan.vmName)
        case nil:
            return nil
        }
    }

    /// What failed, or the milder line when Windows is installed but some of the first sign-in steps
    /// didn't work (E_RESULT_FAILED). Words only: the mark beside it is `failureMark`'s, the one
    /// `StatusMark` the rest of the window uses, where a text ✗ or ! in the body colour was read out
    /// as part of the title.
    static func failureHeader(_ state: CreateJobState) -> String {
        guard let failure = state.failure else { return CreateCopy.eStopped }
        if failure.code == "E_RESULT_FAILED" {
            return CreateCopy.installedWithProblems(edition: state.plan.edition.displayName, name: state.plan.vmName)
        }
        return failure.title
    }

    static func failureMark(_ state: CreateJobState) -> StatusMark.Status {
        state.failure?.code == "E_RESULT_FAILED" ? .attention : .failed
    }

    /// The top of each view: inside Set Up Winbar, a page title at the wizard's size over the status
    /// line; in the window of its own, the status line alone as the headline. Every other page of the
    /// wizard has a 24 pt title, and the install's was 13 pt text. Pure.
    struct Heading: Equatable {
        /// The page's title (`SetupPageTitle`), inside Set Up Winbar only.
        var title: String?
        var mark: StatusMark.Status?
        /// The line under the title, or the headline in the window of its own.
        var line: String?
    }

    static func heading(_ state: CreateJobState, hosted: Bool) -> Heading {
        let edition = state.plan.edition.displayName, name = state.plan.vmName
        switch state.outcome {
        case nil:
            // The line goes in the progress element's label, which VoiceOver reads after the title.
            return hosted ? Heading(title: CreateCopy.pTitle) : Heading(line: CreateCopy.pHeader(edition: edition, name: name))
        case .done:
            return Heading(title: hosted ? CreateCopy.dTitle : nil, mark: .done,
                           line: CreateCopy.installed(edition: edition, name: name))
        case .failed:
            let problems = state.failure?.code == "E_RESULT_FAILED"
            // Installed with problems says so as its title; its line is which steps failed.
            let line = problems && hosted ? (state.failure?.title ?? failureHeader(state)) : failureHeader(state)
            return Heading(title: hosted ? (problems ? CreateCopy.dTitleProblems : CreateCopy.fTitle) : nil,
                           mark: failureMark(state), line: line)
        case .cancelled:
            return hosted ? Heading(title: CreateCopy.cTitle) : Heading(line: CreateCopy.cancelledHeader(name: name))
        }
    }

    /// The running page's progress, as VoiceOver reads it after the heading: inside Set Up Winbar what
    /// is installed where (the title says only "Installing Windows"), then the stage and the time. The
    /// label replaced the header the element once held, so the header was never read. Pure.
    static func progressLabel(_ progress: CreateProgress, state: CreateJobState, hosted: Bool) -> String {
        let parts = [hosted ? CreateCopy.pSubtitle(edition: state.plan.edition.displayName, name: state.plan.vmName) : nil,
                     progress.step, progress.soFar]
        return parts.compactMap { $0 }.joined(separator: ", ")
    }

    /// The detail with the header's own sentence taken off the front. Several failures word their
    /// detail as "{title}, so …", which Terminal prints as one line but the window would show twice:
    /// once as the heading and again as the first sentence.
    static func failureDetail(_ failure: CreateFailure) -> String {
        guard !failure.title.isEmpty, failure.detail.hasPrefix(failure.title) else { return failure.detail }
        var rest = failure.detail.dropFirst(failure.title.count)
        while let first = rest.first, ".,;:! ".contains(first) { rest = rest.dropFirst() }
        guard let first = rest.first else { return failure.detail }
        return first.uppercased() + rest.dropFirst()
    }

    // MARK: Buttons

    /// One of the buttons under an install, as a value, so the rule for which ones there are, and which
    /// is the default, can be read without drawing.
    struct Action: Equatable {
        /// `sendReport` is the beta's **Send This to the Developer** (`BetaReport`), drawn with the
        /// failure rather than in the footer (`offersReport`).
        enum Press: Equatable { case showVM, showLog, deleteVM, cancelInstall, close, done, tryAgain, sendReport }
        /// `standard` is the window's default button, which Return presses; `cancel` takes Escape.
        enum Kind: Equatable { case plain, destructive, cancel, standard }

        var title: String
        var press: Press
        var kind: Kind = .plain
        var enabled = true
    }

    /// Whether the failure page has the beta's **Send This to the Developer**: while the beta is on, on
    /// an install that failed. Under the failure's words rather than in the footer, whose five buttons
    /// already fill the window's 600 pt, and whose corners are the page's own way on. Pure.
    static func offersReport(_ state: CreateJobState, enabled: Bool = BetaReport.enabled) -> Bool {
        enabled && state.outcome == .failed
    }

    /// The buttons under `state`: bottom-left what looks at the VM, bottom-right the way on. Pure.
    ///
    /// While a stall is shown, **Show VM Window** moves from the bottom left to the corner, as the
    /// default: the stall asks Ben to look at the VM's window.
    static func actions(_ state: CreateJobState, readOnly: Bool, cancelling: Bool,
                        stalled: Bool = false) -> (leading: [Action], trailing: [Action]) {
        var leading: [Action] = []
        if state.outcome == nil || state.outcome == .failed, !(state.outcome == nil && stalled) {
            leading.append(Action(title: CreateCopy.bShowVM, press: .showVM,
                                  enabled: state.stage.number >= CreateStage.boot.number))
        }
        if state.outcome == .failed, state.logPath != nil {
            leading.append(Action(title: CreateCopy.bShowLog, press: .showLog))
        }
        // Deleting the VM is the one thing here that can't be undone, so it sits apart from the way
        // forward, marked as destructive, rather than beside Try Again in the same style.
        if state.outcome == .failed {
            leading.append(Action(title: CreateCopy.bDeleteVM, press: .deleteVM, kind: .destructive))
        }
        var trailing: [Action] = []
        switch state.outcome {
        case nil:
            if !readOnly {
                trailing.append(Action(title: CreateCopy.bCancelInstall, press: .cancelInstall, enabled: !cancelling))
            }
            // "Hide" sat right under "Hide Armie", and said nothing of what came after it.
            // A stall is the one moment in the install when Ben has to act, and its callout asks him to
            // look at the VM's window: Show VM Window is then the corner and Return's, and Close Window,
            // the default the rest of the time, is plain beside it.
            trailing.append(Action(title: CreateCopy.bCloseWindow, press: .close, kind: stalled ? .plain : .standard))
            if stalled {
                trailing.append(Action(title: CreateCopy.bShowVM, press: .showVM, kind: .standard,
                                       enabled: state.stage.number >= CreateStage.boot.number))
            }
        case .done:
            trailing.append(Action(title: CreateCopy.bDone, press: .done, kind: .standard))
        case .failed:
            // The job's own test for what `--resume` (and so Try Again) can carry on with: the VM is
            // still there, its setup disk is still there, and Windows had started. When the install
            // can carry on, carrying on is the default and Close is Escape; Close being the default
            // sent Return to the button that gives up.
            if state.isResumable {
                trailing.append(Action(title: CreateCopy.bClose, press: .done, kind: .cancel))
                trailing.append(Action(title: CreateCopy.bTryAgain, press: .tryAgain, kind: .standard))
            } else {
                trailing.append(Action(title: CreateCopy.bClose, press: .done, kind: .standard))
            }
        case .cancelled:
            trailing.append(Action(title: CreateCopy.bClose, press: .done, kind: .standard))
        }
        return (leading, trailing)
    }

    @ViewBuilder private var buttons: some View {
        let actions = CreateJobView.actions(state, readOnly: controller.readOnly, cancelling: controller.cancelling,
                                            stalled: state.outcome == nil && progress.stall != nil)
        HStack(spacing: 10) {
            ForEach(Array(actions.leading.enumerated()), id: \.offset) { _, action in button(action) }
            Spacer()
            ForEach(Array(actions.trailing.enumerated()), id: \.offset) { _, action in button(action) }
        }
    }

    @ViewBuilder private func button(_ action: Action) -> some View {
        let control = Button(action.title, role: action.kind == .destructive ? .destructive : nil) { press(action.press) }
            .disabled(!action.enabled)
        switch action.kind {
        case .standard: control.windowDefaultButton()
        case .cancel: control.keyboardShortcut(.cancelAction)
        case .plain, .destructive: control
        }
    }

    private func press(_ press: Action.Press) { controller.perform(press) }
}

/// The top of an install view (`CreateJobView.Heading`): inside Set Up Winbar the page's title at the
/// wizard's size, then the status line with its mark; in the window of its own, the status line as the
/// headline. Either way VoiceOver lands on it as a heading.
struct JobHeading: View {
    let heading: CreateJobView.Heading
    let hosted: Bool
    /// The wizard's Armie, lent while these views are its step 2, and the job he stands by.
    var armie: ArmieHost? = nil
    var job: CreateJobState? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title = heading.title {
                SetupPageHead(title: title, armie: armie.flatMap { _ in job.map(ArmieCue.installing) },
                              art: armie?.art, send: armie?.send ?? { _ in })
            }
            if let line = heading.line {
                if hosted {
                    SetupStatusLine(heading.mark, line)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if let mark = heading.mark { StatusMark(mark) }
                        Text(line).font(.headline).fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isHeader)
                }
            }
        }
    }
}

// MARK: - The install's words in these views

extension CreateCopy {
    /// Where the running install stands, in its own count: "Stage 6 of 10 · Copying files".
    static func pStage(_ stage: CreateStage) -> String {
        let short = stage.shortTitle
        return "Stage \(stage.number) of 10 · " + (short.first.map { $0.uppercased() + short.dropFirst() } ?? short)
    }

    /// How long a Windows install usually takes on a recent Mac, from the installs Winbar has timed.
    static let pUsually = "usually 10–15 min"

    static func pSoFar(_ seconds: TimeInterval) -> String {
        "\(CreateElapsed.minutes(seconds)) so far · \(pUsually)"
    }

    /// The running install's close button, and what closing it does: the window comes back by itself
    /// when the install ends (`CreateWindowController.reopensWhenJobEnds`, true for any install this
    /// app runs whose window has been open — the only one this sentence is drawn for).
    static let bCloseWindow = "Close Window"
    static let pCloseWindow = "You don't need to watch or click anything. " + pCloseWindowStalled
    /// The same, under a stall, which does ask Ben to look and perhaps click.
    static let pCloseWindowStalled = "You can close this window: Winbar carries on, the menu bar shows how it's going, "
        + "and this window comes back when Windows is ready."

    /// The install page's title inside Set Up Winbar, at the wizard's title size, while it runs and
    /// as it ends (`CreateJobView.heading`).
    static let pTitle = "Installing Windows"
    /// Under it: what, and where.
    static func pSubtitle(edition: String, name: String) -> String { "\(edition) in “\(name)”" }
    static let dTitle = "Windows is installed"
    static let dTitleProblems = "Windows is installed, with problems"
    static let fTitle = "Windows didn't finish installing"
    static let cTitle = "Install cancelled"

    /// The done page inside Set Up Winbar, for an install it doesn't hand back by itself (one that
    /// didn't choose its VM): the button is **Done**, and this said "Close this result".
    static let doneEmbedded = "Choose **\(bDone)** to go back to setup, where you can pick this VM for Winbar to look after."

    /// The disclosure the running install's quieter notes fold behind.
    static func pNotes(_ count: Int) -> String { count == 1 ? "1 note about this install" : "\(count) notes about this install" }
}
