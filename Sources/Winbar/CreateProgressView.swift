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
    var elapsed: String
    var step: String
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
        step = CreateCopy.pStep(state.stage.number)
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
                return Row(stage: stage, mark: mark, title: stage.runningTitle,
                           detail: CreateProgress.detail(state.detail),
                           elapsed: mark == .running ? CreateElapsed.clock(end.timeIntervalSince(began)) : nil)
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
    /// The wizard's Armie, while these views are its step 2 (`CreateRootView.armie`).
    var armie: ArmieHost? = nil

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
                .padding(20)
            }
            Divider()
            buttons.padding(20)
        }
    }

    // MARK: Running

    private var runningBody: some View {
        let progress = self.progress
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(progress.header).font(.headline)
                Spacer()
                Text(progress.elapsed).monospacedDigit().foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                ProgressView(value: progress.fraction)
                Text(progress.step).font(.callout).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(progress.step)
            StepList(rows: progress.rows)
            if let stall = progress.stall { NoteBox(stall) }
            noteList(progress.notes)
            Text(controller.readOnly ? CreateCopy.pFooterCLI : CreateCopy.pFooter)
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // Last on the page, under the stages and anything the job has said: those are the install,
            // and he mustn't push the running row, a stall or a note further down it. Only the running
            // body has him; the ending and the failure are drawn without.
            //
            // No rule above him, unlike step 1's card. At the first-open size a note or two from the job
            // (a preflight caution, the saved PC) and the app's two-line footer put him below the fold,
            // and a rule of his own would be all that showed of him: a second line just above the
            // button bar's, which reads as something cut off. The page's spacing sets him apart.
            if let armie, let cue = ArmieCue.installing(state) {
                ArmieSays(line: cue.line, art: armie.art, clip: cue.clip, send: armie.send)
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
                            .foregroundStyle(.secondary)
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
                Text("✓ " + CreateCopy.installed(edition: state.plan.edition.displayName,
                                                 name: state.plan.vmName)).font(.headline)
                Spacer()
                Text(CreateElapsed.minutes((state.finishedAt ?? controller.now).timeIntervalSince(state.startedAt)))
                    .foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow {
                    Text("Sign in as").foregroundStyle(.secondary)
                    Text(state.plan.userName)
                }
                GridRow {
                    Text("Reach it at").foregroundStyle(.secondary)
                    Text(CreateChoices.hostName(computerName: state.plan.computerName))
                }
            }
            if controller.isEmbedded {
                Text("Close this result to return to setup. Choose this VM there if you want Winbar to look after it.")
                    .fixedSize(horizontal: false, vertical: true)
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
            Text("·").foregroundStyle(.secondary)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    // MARK: Failed and cancelled

    private var failureBody: some View {
        let progress = self.progress
        return VStack(alignment: .leading, spacing: 12) {
            Text(CreateJobView.failureHeader(state)).font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            if let failure = state.failure {
                let detail = CreateJobView.failureDetail(failure)
                if !detail.isEmpty {
                    Text(detail).fixedSize(horizontal: false, vertical: true)
                }
                if let next = failure.nextStep.flatMap({ CreateCopy.windowNextStep($0, resumable: state.isResumable) }) {
                    Text(next).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            StepList(rows: progress.rows)
            noteList(progress.notes)
        }
    }

    private var cancelledBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(CreateCopy.cancelledHeader(name: state.plan.vmName)).font(.headline)
            // What this cancel did, when this window is the one that asked; otherwise what a cancel
            // does (the CLI's, or one this window didn't see).
            Text(controller.cancelNote ?? CreateCopy.cancelledNote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// `✗ {what failed}`, or the milder `!` line when Windows is installed but some of the first
    /// sign-in steps didn't work (E_RESULT_FAILED).
    static func failureHeader(_ state: CreateJobState) -> String {
        guard let failure = state.failure else { return "✗ " + CreateCopy.eStopped }
        if failure.code == "E_RESULT_FAILED" {
            return "! " + CreateCopy.installedWithProblems(edition: state.plan.edition.displayName,
                                                           name: state.plan.vmName)
        }
        return "✗ \(failure.title)"
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

    @ViewBuilder private var buttons: some View {
        HStack {
            if state.outcome == nil || state.outcome == .failed {
                Button(CreateCopy.bShowVM) { controller.showVMWindow() }
                    .disabled(state.stage.number < CreateStage.boot.number)
            }
            if state.outcome == .failed, state.logPath != nil {
                Button(CreateCopy.bShowLog) { controller.showLog() }
            }
            // Deleting the VM is the one thing here that can't be undone, so it sits apart from the way
            // forward, marked as destructive, rather than beside Try Again in the same style.
            if state.outcome == .failed {
                Button(CreateCopy.bDeleteVM, role: .destructive) { controller.cancelInstall() }
            }
            Spacer()
            switch state.outcome {
            case nil:
                if !controller.readOnly {
                    Button(CreateCopy.bCancelInstall) { controller.cancelInstall() }
                        .disabled(controller.cancelling)
                }
                Button(CreateCopy.bHide) { controller.close() }
                    .keyboardShortcut(.defaultAction)
            case .done:
                Button(CreateCopy.bDone) { controller.dismissJob() }
                    .keyboardShortcut(.defaultAction)
            case .failed:
                // The job's own test for what `--resume` (and so Try Again) can carry on with: the
                // VM is still there, its setup disk is still there, and Windows had started.
                // When the install can carry on, carrying on is the default and Close is Escape; Close
                // being the default sent Return to the button that gives up.
                if state.isResumable {
                    Button(CreateCopy.bClose) { controller.dismissJob() }
                        .keyboardShortcut(.cancelAction)
                    Button(CreateCopy.bTryAgain) { controller.tryAgain() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                } else {
                    Button(CreateCopy.bClose) { controller.dismissJob() }
                        .keyboardShortcut(.defaultAction)
                }
            case .cancelled:
                Button(CreateCopy.bClose) { controller.dismissJob() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
