import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The **New Windows VM…** window: one non-modal `NSWindow` hosting SwiftUI, which
/// shows the form, then the install's progress, then how it ended — always in the same window, so
/// closing it never loses the job.
///
/// The same views are also the Set Up Winbar window's step 2 (gui-wizard.md §2.3, §3.5): **Install Windows…**
/// shows them there (`embed(_:)`) instead of in a window of their own. There is still one controller
/// and one job, and while they're embedded nothing opens this window: **New Windows VM…**, **Show
/// Install Progress…** and an install ending all bring the wizard forward instead (`bringForward()`),
/// and the buttons that would close this window hand back to the wizard (`close()`).
///
/// Opening the window must not launch UTM, so nothing here asks UTM anything until either
/// UTM is already running or Create is pressed. Reading the ISO and asking UTM for its VM names both
/// block, so both run off the main thread and report back on it.
final class CreateWindowController: NSObject, ObservableObject, NSWindowDelegate {
    /// The app's, and the only one whose news reaches VoiceOver (`SetupAnnouncer`).
    static let shared = CreateWindowController(environment: Environment(announce: .live))

    enum Phase: Equatable { case form, job }

    @Published private(set) var phase: Phase = .form
    @Published private(set) var form: CreateFormModel
    /// The install this window is showing, once there is one.
    @Published private(set) var job: CreateJobState?
    /// Something else (the CLI) holds the lock: no Cancel button, and a different footer.
    var readOnly: Bool { !environment.ownsJob() }

    /// Whether this process is the one driving the install (it started it, resumed it, or picked it
    /// up at launch) rather than only watching the CLI's. The menu bar reads it too.
    private(set) static var ownsJob = false

    static func claimJob() { ownsJob = true }
    static func releaseJob() { ownsJob = false }
    /// Ticks once a second while a job is on screen, so the elapsed clocks move.
    @Published private(set) var now = Date()

    /// How a cancel went, when this window is the one that asked for it: the job's own N_CANCELLED
    /// sentence, so the ending says what was actually done rather than what usually happens.
    @Published private(set) var cancelNote: String?
    /// Set between asking the run in this process to stop and its next state arriving, so Cancel
    /// Install… can't be pressed again while the run is getting to its next poll point.
    @Published private(set) var cancelling = false

    var window: NSWindow?
    struct Environment {
        var currentJob: () -> CreateJobState? = CreateJob.current
        var refreshForm: (CreateWindowController) -> Void = { $0.refreshForm() }
        var show: (NSWindow) -> Void = {
            $0.makeKeyAndOrderFront(nil)
            $0.orderFrontRegardless()   // asked for from the menu of an app that isn't the active one
            MainActor.assumeIsolated { AppPresence.update() }
            NSApp.activate()
        }
        var workGate: AppWorkGate = .shared
        /// Whether this process drives the install, as the views read it (`readOnly`). The app's is the
        /// process-wide `ownsJob`. A render passes its own answer so it can draw the page of an install
        /// the app started without claiming that flag, which every other drawing reads at the same time.
        var ownsJob: () -> Bool = { CreateWindowController.ownsJob }
        /// Where the install's ending is said to VoiceOver (`CreateJobView.announcement`): nowhere
        /// unless it is the app's `shared`, so a controller a test builds stays silent.
        var announce: SetupAnnouncer = .silent
        /// Where the install's button presses go instead of doing what they do: nil in the app. A
        /// test's controller records them (`perform`).
        var pressed: ((CreateJobView.Action.Press) -> Void)? = nil
    }
    private let environment: Environment
    @Published private(set) var busyMessage: String?
    private var clock: Timer?
    /// Set while the Set Up Winbar window shows these views as its step 2 (`embed(_:)`).
    private(set) var isEmbedded = false
    /// The wizard, while embedded: how to bring it forward, close it, and hand back to it.
    private var host: EmbedHost?
    /// The job the window last let go of. The same ended state arrives twice — from the run's own
    /// callback and from the menu bar's follower, a second apart — and the second must not put an
    /// install that was just dismissed back on screen, where the next **New Windows VM…** would find
    /// its ending instead of a form.
    private var dismissedJobID: String?
    /// Set while a job this process is driving is on screen in this window and hasn't finished, so
    /// the window comes back by itself when it ends. Not for a job the app is only
    /// watching: an install running in Terminal must not pull the focus off the terminal that is
    /// asking its next question, and not for a window the person has never opened.
    private var reopenWhenJobEnds = false

    /// The app only ever has `shared`, which reads the form's facts from this Mac. `facts` is for
    /// the tests that draw these views: `.current()` reads Winbar's settings and asks whether UTM is
    /// installed, and a test must not reach the settings of the Mac it runs on.
    init(facts: CreateFormFacts = .current(), environment: Environment = Environment()) {
        self.environment = environment
        form = CreateFormModel(facts: facts)
        super.init()
    }

    /// The hidden way in from the CLI (`winbar create --window`) and from the menu. Safe to call
    /// again: it brings the existing window forward — or the wizard, while it shows these views.
    static func present(controller: CreateWindowController = shared,
                        setupBusy: Bool = SetupWindowController.coordinatesVM,
                        showSetup: () -> Void = SetupWindowController.present) {
        controller.present(setupBusy: setupBusy, showSetup: showSetup)
    }
    func present(setupBusy: Bool, showSetup: () -> Void) {
        if setupBusy, !isEmbedded { showSetup(); return }
        bringForward()
    }

    /// **Show Install Progress…**: the same window, on the job — or the wizard, while it shows it.
    static func presentProgress(controller: CreateWindowController = shared) { controller.bringForward() }

    /// Where the views are brought forward: this window, or the wizard while it shows them. One
    /// controller drives one job, so a second window onto it — the menu's **New Windows VM…** while
    /// the wizard's install runs — would be two sets of buttons on one install.
    enum Presentation: Equatable { case ownWindow, host }

    /// Pure, so the rule can be checked without a window.
    static func presentation(embedded: Bool) -> Presentation { embedded ? .host : .ownWindow }

    func bringForward() {
        switch CreateWindowController.presentation(embedded: isEmbedded) {
        case .host: host?.present()
        case .ownWindow: show()
        }
    }

    // MARK: - Opening

    private func show() {
        if job == nil, let current = environment.currentJob(), !current.isFinished {
            adopt(current)
        }
        let window = existingWindow()
        environment.show(window)
        if phase == .form { environment.refreshForm(self) }
        startClockIfNeeded()
    }

    private func existingWindow() -> NSWindow {
        if let window { return window }
        let content = NSHostingController(rootView: CreateRootView(controller: self))
        // The layout is drawn for 600 pt and scrolls below that; without this the hosting controller
        // would keep pushing SwiftUI's own ideal size onto the window as the content changes.
        content.sizingOptions = []
        let window = NSWindow(contentViewController: content)
        window.title = CreateCopy.winTitle
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 600, height: 700))
        window.contentMinSize = NSSize(width: 600, height: 360)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("winbar-create")
        // The beta's Help!, as Set Up Winbar has it (`BetaReport.titlebarHelp`).
        if let help = BetaReport.titlebarHelp(press: { BetaReportWindowController.present(.newWindowsVM) }) {
            window.addTitlebarAccessoryViewController(help)
        }
        self.window = window
        return window
    }

    /// Closing is Hide: the job carries on, and the password goes. A job that has
    /// already ended is let go instead of being kept on screen, so the next **New Windows VM…**
    /// opens a form rather than the last install's ending.
    func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated { AppPresence.update(closing: notification.object as? NSWindow) }
        form.forgetPassword()
        stopClock()
        if !CreateWindowController.keepsJob(onClose: job) { forgetJob() }
    }

    /// Whether closing the window keeps the job it was showing: only while that job is still
    /// running. Pure, so the rule can be checked without a window.
    static func keepsJob(onClose state: CreateJobState?) -> Bool {
        guard let state else { return false }
        return !state.isFinished
    }

    /// Lets go of the job the window was showing and goes back to the form. Ownership is only given
    /// up when there was a job here to give up: closing a form must not release a job the app picked
    /// up at launch and hasn't shown yet.
    private func forgetJob() {
        if let job {
            CreateWindowController.releaseJob()
            dismissedJobID = job.id
        }
        job = nil
        phase = .form
        reopenWhenJobEnds = false
        cancelling = false
        cancelNote = nil
    }

    /// **Cancel** on the form, **Hide** while the install runs, and — through `dismissJob()` — **Done**
    /// and **Close** on its ending. In this window each of them closes it; inside the wizard there is
    /// no window of its own to close, and what each one means there is `closing(embedded:job:)`.
    func close() {
        switch CreateWindowController.closing(embedded: isEmbedded, job: job) {
        case .ownWindow: window?.performClose(nil)
        case .hideHost: host?.hide()
        case .handBack: finishEmbedded(.handedBack)
        }
    }

    /// What `close()` does.
    enum Closing: Equatable {
        /// Closes this window. Closing is Hide: the job carries on (`windowWillClose`).
        case ownWindow
        /// **Hide** inside the wizard: the wizard's window closes and the install carries on, as it
        /// does when this window closes; reopening the wizard lands back on it (§2.4). Handing back to
        /// step 2 instead would put the person on a step whose only screen is this install.
        case hideHost
        /// The form's **Cancel**, or **Done** or **Close** once the install has ended and been let go
        /// (`dismissJob()`): the wizard takes its step back (§2.3: "Close returns to step 2").
        case handBack
    }

    /// Pure, so the rule can be checked without a window (spec §5, "a pure test on a small close
    /// decision function").
    static func closing(embedded: Bool, job: CreateJobState?) -> Closing {
        guard embedded else { return .ownWindow }
        if let job, !job.isFinished { return .hideHost }
        return .handBack
    }

    // MARK: - Facts about this Mac

    /// Cheap facts first, so the window is up immediately; FileVault costs a subprocess and UTM's VM
    /// list costs an Apple Event, so both arrive afterwards.
    ///
    /// A form nobody has touched starts again from this Mac's current facts; one with an ISO or a
    /// half-typed password is left alone, because reopening the window shouldn't undo typing.
    private func refreshForm() {
        if form.iso == .none, !form.submitted, form.password.isEmpty {
            form = CreateFormModel(facts: .current())
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let fileVault = Host.fileVaultOn
            // Only when UTM is already running: opening this window must never launch it.
            let names: [String]? = UTM.isAppRunning ? (try? UTMScripting.listVMs().get())?.map(\.name) : nil
            DispatchQueue.main.async {
                self.form.facts.fileVaultOn = fileVault
                if let names {
                    self.form.facts.existingVMNames = names
                    // The default name was chosen before the list arrived; if it clashed, move on.
                    if self.form.vmName == CreateChoices.baseVMName {
                        self.form.vmName = CreateChoices.defaultVMName(existing: names)
                    }
                }
            }
        }
    }

    // MARK: - The ISO

    func chooseISOFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "iso") ?? .diskImage]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.prompt = "Choose"
        // A sheet on the window the form is in: the wizard's while embedded, where this one is closed
        // or was never opened, and a sheet on it would be a panel nobody can see.
        let parent = isEmbedded ? host?.window() : window
        let chosen: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.readISO(url)
        }
        if let parent { panel.beginSheetModal(for: parent, completionHandler: chosen) } else { panel.begin(completionHandler: chosen) }
    }

    /// True when the drop is a `.iso` this window can take.
    func acceptsDrop(_ url: URL) -> Bool { url.pathExtension.lowercased() == "iso" }

    /// Preflight, off the main thread: it attaches the ISO read-only, reads a few structures and
    /// detaches it (WindowsISO.inspect), which takes a few seconds.
    func readISO(_ url: URL) {
        let path = url.path
        let file = url.lastPathComponent
        form.iso = .reading(file: file)
        DispatchQueue.global(qos: .userInitiated).async {
            let state: CreateFormModel.ISOState
            do {
                let info = try WindowsISO.inspect(path)
                let regional = Regional.read(imageLanguage: info.language)
                state = .read(CreateFormModel.ISOFacts(path: info.path, info: info, regional: regional,
                                                       removableVolume: Self.removableVolumeName(of: info.path)))
            } catch let problem as ISOProblem {
                state = .failed(file: file, message: problem.message)
            } catch {
                state = .failed(file: file, message: "\(error)")
            }
            DispatchQueue.main.async { self.form.iso = state }
        }
    }

    /// The volume's name when it can be unplugged (W_ISO_REMOVABLE), else nil.
    private static func removableVolumeName(of path: String) -> String? {
        let keys: Set<URLResourceKey> = [.volumeIsRemovableKey, .volumeIsEjectableKey, .volumeNameKey]
        guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: keys),
              values.volumeIsRemovable == true || values.volumeIsEjectable == true
        else { return nil }
        return values.volumeName
    }

    // MARK: - Create

    func create() {
        // Check before even accepting a form: an older window must not race setup's restart.
        let lease: AppWorkGate.Lease
        switch environment.workGate.begin(.create, label: "installing Windows", vm: form.vmName) {
        case .failure(let error): busyMessage = error.detail; return
        case .success(let held): lease = held
        }
        busyMessage = nil
        form.submitted = true
        guard let plan = form.plan.map({ CreateWindowController.plan($0, embedded: isEmbedded) }) else { return }
        let password = form.password
        let productKey = form.normalizedProductKey
        form.forgetPassword()
        cancelNote = nil
        CreateWindowController.claimJob()
        adopt(CreateJobState(id: "starting", plan: plan, vmID: nil, stage: .check, detail: nil, startedAt: Date(),
                             updatedAt: Date(), finishedAt: nil, outcome: nil, restarts: 0, bytesWritten: nil,
                             shown: [], failure: nil, mediaDir: nil, logPath: nil, watched: true))
        DispatchQueue.global(qos: .userInitiated).async {
            defer { lease.finish() }
            do {
                try CreateJob.start(plan: plan, password: password, productKey: productKey) { state in
                    CreateWindowController.shared.jobChanged(state)
                }
            } catch {
                DispatchQueue.main.async { self.runEnded(with: error, vmName: plan.vmName) }
            }
        }
    }

    /// The plan Create sends: marked as the wizard's when the form is its step 2, so the install leaves
    /// the Local Network prompt and headless to set-up (`CreatePlan.inSetupWindow`). Pure.
    static func plan(_ plan: CreatePlan, embedded: Bool) -> CreatePlan {
        var plan = plan
        plan.inSetupWindow = embedded ? true : nil
        if embedded { plan.select = true }
        return plan
    }

    /// A run in this process threw: how it ended decides what the window shows.
    ///
    /// The job records everything it can reach a state for, and delivers it before it throws, so by
    /// the time this runs the failure is usually already on screen — this only has to leave it
    /// there, rather than sweeping a two-hour install away behind an alert that says it
    /// never started. The alert is for what is left: a refusal before the VM existed, where there is
    /// nothing to show but the reason, and the form to put it right.
    private func runEnded(with error: Error, vmName: String) {
        cancelling = false
        switch CreateWindowController.ending(for: error, job: job, vmName: vmName) {
        case .nameTaken(let name):
            forgetJob()
            form.nameTaken = name
        case .cancelled:
            // The job saved itself `.cancelled` and that ending is already on screen; N_CANCELLED's
            // own sentence says what the cancel did.
            if cancelNote == nil { cancelNote = (error as? CreateJobError)?.failure.title }
            CreateWindowController.releaseJob()
        case .failureView:
            guard let state = job else { return }
            let failure = (error as? CreateJobError)?.failure ?? CreateWindowController.unknownFailure(error)
            adopt(state.outcome == .failed ? state
                  : CreateRun.ending(state, outcome: .failed, failure: failure, at: Date()))
            CreateWindowController.releaseJob()
        case .alert:
            startRefused(error)
        }
    }

    /// What the window does with a run that ended badly.
    enum Ending: Equatable {
        /// The failure view, with Show Log, Try Again and Delete VM… — every failure once
        /// the VM existed, however far in. The form must not come back: the VM is still in UTM.
        case failureView
        /// A refusal before anything was created: the form, with the reason in an alert.
        case alert
        /// The person cancelled it themselves; the job's own ending is what to show.
        case cancelled
        /// A name UTM already has goes under the Name field instead.
        case nameTaken(String)
    }

    /// Which of those an error is, for a run of `vmName`. Pure, so the rule can be checked without a
    /// window or a job.
    ///
    /// The state on screen has to be this run's own: a refusal to start (E_BUSY) while the window
    /// happens to be showing the install the CLI got in first with must not paint that other job as
    /// failed.
    static func ending(for error: Error, job: CreateJobState?, vmName: String) -> Ending {
        if let problem = error as? ChoiceProblem, case .nameTaken(let name) = problem { return .nameTaken(name) }
        if (error as? CreateJobError)?.failure.code == CreateWindowController.cancelledCode { return .cancelled }
        guard let job, job.plan.vmName == vmName else { return .alert }
        return job.vmID != nil || job.outcome == .failed ? .failureView : .alert
    }

    /// N_CANCELLED, the code `start`/`resume` throw once a Cancel Install… has been carried out.
    static let cancelledCode = "N_CANCELLED"

    /// A failure the job never got to name: the view still needs a heading and a reason.
    static func unknownFailure(_ error: Error) -> CreateFailure {
        CreateFailure(code: "E_UNKNOWN", title: CreateCopy.eStopped, detail: "\(error)", nextStep: nil)
    }

    /// The job refused to start, before anything existed in UTM (E_BUSY, E_UTM_MISSING, E_SPACE,
    /// E_ISO_*): there is no install to show, so the form comes back with the reason.
    private func startRefused(_ error: Error) {
        forgetJob()
        alert(CreateCopy.eCouldntStart, error)
    }

    private func alert(_ title: String, _ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = CreateWindowController.alertBody(error)
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// What an alert says under its heading: the failure as the deck writes it, and what to do about
    /// it. Pure, so the two can be held against the `CreateFailure` the job raised.
    static func alertBody(_ error: Error) -> String {
        guard let failure = (error as? CreateJobError)?.failure else { return "\(error)" }
        return [failure.title, failure.detail, failure.nextStep]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    // MARK: - Following the job

    /// New state from `CreateJob.follow` (the menu bar's subscription) or from our own `start`.
    func jobChanged(_ state: CreateJobState) {
        DispatchQueue.main.async {
            guard CreateWindowController.adopts(state, dismissed: self.dismissedJobID) else { return }
            let reopen = self.reopenWhenJobEnds
            let before = self.job
            self.adopt(state)
            // Ten minutes in, the person is rarely looking at this window: its ending has to be said.
            if let line = CreateJobView.announcement(from: before, to: state) { self.environment.announce.say(line) }
            if state.isFinished, reopen {
                // The window comes back by itself when the job it was showing ends — the wizard, when
                // it was showing it there.
                self.bringForward()
            }
            if let end = CreateWindowController.embeddedEnd(for: state, embedded: self.isEmbedded) {
                self.finishEmbedded(end)
            }
        }
    }

    /// Whether a state from the job is put on screen: every one, except the ending of the job this
    /// window has just let go of, which arrives a second time from the follower. Pure.
    static func adopts(_ state: CreateJobState, dismissed: String?) -> Bool {
        !(state.isFinished && state.id == dismissed)
    }

    private func adopt(_ state: CreateJobState) {
        // The job is running again (Try Again, `--resume`): its ending, when it comes, is a new one.
        if !state.isFinished { dismissedJobID = nil }
        job = state
        phase = .job
        if state.isFinished { cancelling = false }
        reopenWhenJobEnds = CreateWindowController.reopensWhenJobEnds(state, ownsJob: CreateWindowController.ownsJob,
                                                                     windowExists: window != nil, embedded: isEmbedded)
        startClockIfNeeded()
    }

    /// Whether this window should come back by itself when the job ends: only for one this process
    /// is driving that has already been on screen here — or in the wizard, which is where the person
    /// watched it. The app follows the CLI's installs too, and activating Winbar as one of those ends
    /// would take the keystrokes meant for Terminal's last question. Pure, so the rule can be checked
    /// without a window.
    static func reopensWhenJobEnds(_ state: CreateJobState, ownsJob: Bool, windowExists: Bool,
                                   embedded: Bool = false) -> Bool {
        !state.isFinished && ownsJob && (windowExists || embedded)
    }

    /// Draws `state` without following it: no clock, and no claim on the job. For the renders of the
    /// wizard's step 2, which show an install without running one.
    func draw(_ state: CreateJobState) {
        job = state
        phase = .job
    }

    /// Back to the form after a job is done with: Done, Close, or a cancelled install.
    func dismissJob() {
        forgetJob()
        close()
    }

    private func startClockIfNeeded() {
        guard clock == nil, phase == .job, job?.isFinished != true else { return }
        now = Date()
        clock = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.now = Date() }
        clock?.tolerance = 0.2
    }

    private func stopClock() {
        clock?.invalidate()
        clock = nil
    }

    // MARK: - Buttons on the progress and ending views

    func showVMWindow() { UTM.open() }

    /// A press on the install's buttons (`CreateJobView.Action`). A controller a test builds records
    /// them instead (`Environment.pressed`), so pressing Try Again in a test never resumes an install
    /// and Show VM Window never opens UTM.
    func perform(_ press: CreateJobView.Action.Press) {
        if let pressed = environment.pressed { pressed(press); return }
        switch press {
        case .showVM: showVMWindow()
        case .showLog: showLog()
        case .deleteVM, .cancelInstall: cancelInstall()
        case .close: close()
        case .done: dismissJob()
        case .tryAgain: tryAgain()
        case .sendReport: BetaReportWindowController.present(.newWindowsVM)
        }
    }

    func showLog() {
        guard let path = job?.logPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// The same command the Done screen shows, worked out from the plan.
    func copySetupCommand() {
        guard let plan = job?.plan else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(CreateCopy.setupCommand(plan: plan), forType: .string)
    }

    /// **Try Again**: carry on with the install that failed. Only offered while the job says it can
    /// be carried on with (`isResumable`), which is the same test `--resume` uses.
    func tryAgain() {
        guard let name = job?.plan.vmName else { return }
        let lease: AppWorkGate.Lease
        switch environment.workGate.begin(.create, label: "resuming the Windows install", vm: name) {
        case .failure(let error): busyMessage = error.detail; return
        case .success(let held): lease = held
        }
        busyMessage = nil
        CreateWindowController.claimJob()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { lease.finish() }
            do {
                try CreateJob.resume(vmName: name) { state in
                    CreateWindowController.shared.jobChanged(state)
                }
            } catch {
                DispatchQueue.main.async { self.runEnded(with: error, vmName: name) }
            }
        }
    }

    /// **Cancel Install…** and **Delete VM…**: the same alert, then what `--cancel` does.
    ///
    /// It goes through `stopInstall`, not `cancel`: when the install is the one this process is
    /// driving, the lock is already held here, and `flock` refuses a second holder in the same
    /// process exactly as it refuses another one — so cancelling from inside has to be a request to
    /// the run, which stops the VM and ends the job itself. Nothing is dismissed until the job says
    /// it ended, and a cancel that couldn't be done is shown rather than swallowed.
    func cancelInstall() {
        guard let name = job?.plan.vmName, !cancelling else { return }
        let alert = NSAlert()
        alert.messageText = CreateCopy.cancelTitle
        alert.informativeText = CreateCopy.cancelBody(name: name)
        alert.addButton(withTitle: CreateCopy.bKeepInstalling)
        let delete = alert.addButton(withTitle: CreateCopy.bDeleteVMNow)
        delete.hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        cancelling = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let done = try CreateJob.stopInstall(vmName: name, deleteVM: true)
                DispatchQueue.main.async { self.cancelled(done, name: name) }
            } catch {
                DispatchQueue.main.async {
                    self.cancelling = false
                    self.alert(CreateCopy.eCouldntCancel, error)
                }
            }
        }
    }

    /// nil means the run in this process was asked to stop: it does the cancel itself while it holds
    /// the lock, and its next state — `.cancelled`, or `.failed` when the cancel couldn't be done —
    /// is what the window shows. Anything else was done here and now, and says what it did.
    private func cancelled(_ done: CreateCancelResult?, name: String) {
        guard let done else { return }
        cancelling = false
        cancelNote = CreateWindowController.cancelNote(done, name: name)
        adopt(done.state)
        CreateWindowController.releaseJob()
    }

    /// What the ending says a cancel did, in the job's own words where they fit. Pure.
    static func cancelNote(_ done: CreateCancelResult, name: String) -> String {
        done.vmGone ? CreateCopy.nCancelVMGone(name: name)
                    : CreateJob.cancelled(name, deletedVM: done.deletedVM).failure.title
    }
}

extension CreateFormFacts {
    /// Before anything has been read: the window is never shown in this state, but a model needs one.
    static let blank = CreateFormFacts(mac: MacFacts(topTierCores: 4, totalCores: 4, memoryBytes: 16 << 30,
                                                     shortUserName: NSUserName()),
                                       utmInstalled: true, utmVersion: nil, fileVaultOn: nil, freeGB: nil,
                                       volumeName: "this Mac", existingVMNames: nil, menuVMName: nil)

    /// Everything that can be read without asking UTM or running a subprocess.
    static func current() -> CreateFormFacts {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeNameKey])
        let freeGB = values?.volumeAvailableCapacityForImportantUsage.map { Int($0 / (1 << 30)) }
        return CreateFormFacts(mac: .current,
                               utmInstalled: UTM.isInstalled,
                               utmVersion: UTM.version,
                               fileVaultOn: nil,
                               freeGB: freeGB,
                               volumeName: values?.volumeName ?? "this Mac",
                               existingVMNames: nil,
                               menuVMName: Config.vmName)
    }
}

// MARK: - Views

struct CreateRootView: View {
    @ObservedObject var controller: CreateWindowController
    /// Lent by the Set Up Winbar window while these views are its step 2; nil in this window of its
    /// own. He stands silent beside the form's title (its pages are questions, and one has the
    /// password field) and narrates the install (`ArmieCue.form`, `ArmieCue.installing`).
    var armie: ArmieHost? = nil

    var body: some View {
        Group {
            if controller.phase == .job, let job = controller.job {
                CreateJobView(controller: controller, state: job, armie: armie)
            } else {
                CreateFormView(controller: controller, model: controller.form, armie: armie)
            }
        }
        .safeAreaInset(edge: .top) {
            if let message = controller.busyMessage { Text(message).padding().fixedSize(horizontal: false, vertical: true) }
        }
        .frame(minWidth: 600, maxWidth: .infinity, alignment: .topLeading)
    }
}

/// The form, as an assistant's three pages (`CreateFormModel.Page`): the Windows download, the
/// account, then a summary of what will be installed with everything else behind **Customize…**. The
/// same view in the New Windows VM window of its own and as the Set Up Winbar window's step 2.
struct CreateFormView: View {
    @ObservedObject var controller: CreateWindowController
    @ObservedObject var model: CreateFormModel
    /// The wizard's Armie, while the form is its step 2 (`CreateRootView.armie`).
    var armie: ArmieHost? = nil
    @State private var dropping = false
    @State private var showingPasswordNote = false
    @State private var showingAlwaysNote = false
    @FocusState private var confirmationFocused: Bool
    /// The quieter, problem and caution colours: the system's in the window of its own, the wizard's
    /// palette inside it (`setupHosted`), where the system's measured under 4.5:1 on its backdrop.
    @Environment(\.quietText) private var quiet
    @Environment(\.errorText) private var errorText
    @Environment(\.cautionText) private var caution
    @Environment(\.setupHosted) private var hosted
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    SetupPageHead(title: model.page.title, armie: armie.map { _ in ArmieCue.form }, art: armie?.art,
                                  send: armie?.send ?? { _ in })
                    switch model.page {
                    case .windows: windowsPage
                    case .account: accountPage
                    case .ready: readyPage
                    }
                }
                .frame(maxWidth: SetupStyle.contentWidth, alignment: .leading)
                .padding(.horizontal, SetupStyle.pagePadding)
                .padding(.top, hosted ? SetupStyle.titleAbove : SetupStyle.pagePadding)
                .padding(.bottom, SetupStyle.pagePadding)
                .frame(maxWidth: .infinity)
            }
            footer
        }
        // The whole page takes a dropped .iso, not just the box, while the page is the download's.
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            model.page == .windows && handleDrop(providers)
        }
    }

    // MARK: Page 1: the Windows download

    @ViewBuilder private var windowsPage: some View {
        isoBox
        if model.iso.facts != nil {
            ForEach([CreateCopy.nISOKeep] + model.isoWarnings, id: \.self) { note in
                Text(note).font(.callout).foregroundStyle(quiet).setupProse()
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text(CreateCopy.isoMissing).font(.headline)
                Text(CreateCopy.isoWhat).setupProse()
                Button(CreateCopy.isoGet + " ↗") { openURL(URL(string: CreateCopy.isoGetURL)!) }
                    .help(CreateCopy.isoGetURL)
            }
        }
    }

    @ViewBuilder private var isoBox: some View {
        switch model.iso {
        case .none:
            withSetupAppearance { look in
                VStack(spacing: 12) {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(look.accentText)
                        .accessibilityHidden(true)
                    Text(CreateCopy.isoDrop).font(.system(size: 15, weight: .semibold))
                    HStack(spacing: 8) {
                        Text(CreateCopy.isoOr).foregroundStyle(quiet)
                        Button(CreateCopy.isoChoose) { controller.chooseISOFile() }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 190)
                .background {
                    RoundedRectangle(cornerRadius: SetupStyle.cardRadius, style: .continuous)
                        .fill(look.accentText.opacity(dropping ? 0.1 : 0.04))
                }
                .overlay {
                    // The muted grey at full strength: at 60% the dashes measured 2.5:1 on the light
                    // backdrop, under the 3:1 a boundary needs to be seen as one.
                    RoundedRectangle(cornerRadius: SetupStyle.cardRadius, style: .continuous)
                        .strokeBorder(dropping ? look.accentText : look.mutedText,
                                      style: StrokeStyle(lineWidth: dropping ? 2 : 1.5, dash: [6, 5]))
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(CreateCopy.isoDrop)
            }
        case .reading(let file):
            chosenBox(file: file) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(CreateCopy.isoReading).foregroundStyle(quiet)
                }
            }
        case .failed(let file, let message):
            chosenBox(file: file, bad: true) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    StatusMark(.failed)
                    Text(message).foregroundStyle(errorText).fixedSize(horizontal: false, vertical: true)
                }
            }
        case .read(let facts):
            chosenBox(file: facts.file) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    StatusMark(.done)
                    Text(CreateCopy.isoSummary(build: facts.info.build, language: facts.info.language))
                }
            }
        }
    }

    private func chosenBox<Detail: View>(file: String, bad: Bool = false,
                                         @ViewBuilder detail: () -> Detail) -> some View {
        SetupCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: "opticaldisc").font(.system(size: 22)).foregroundStyle(quiet).accessibilityHidden(true)
                    Text(file).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button(CreateCopy.isoChange) { controller.chooseISOFile() }
                }
                detail().font(.callout)
            }
        }
        .overlay {
            if bad {
                RoundedRectangle(cornerRadius: SetupStyle.cardRadius, style: .continuous).strokeBorder(errorText, lineWidth: 1.5)
            }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url, controller.acceptsDrop(url) else { return }
            DispatchQueue.main.async { controller.readISO(url) }
        }
        return true
    }

    // MARK: Page 2: the account

    @ViewBuilder private var accountPage: some View {
        Text(CreateCopy.accountLead).setupProse()
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                label(CreateCopy.lUserName)
                TextField("", text: $model.userName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)
                    .accessibilityLabel(CreateCopy.lUserName)
                    .accessibilityHint(CreateCopy.windowTooltip(.localAccount))
            }
            if let error = model.userNameError { GridRow { Color.clear.gridCellUnsizedAxes([.horizontal, .vertical]); caption(error, bad: true) } }
            GridRow {
                label(CreateCopy.lPassword)
                SecureField("", text: $model.password)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)
                    .help(CreateCopy.passwordTooltip)
                    .accessibilityLabel(CreateCopy.lPassword)
                    .accessibilityHint(CreateCopy.passwordTooltip)
            }
            GridRow {
                label(CreateCopy.lConfirmPassword)
                SecureField("", text: $model.confirmation)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)
                    .focused($confirmationFocused)
                    .onChange(of: confirmationFocused) { _, focused in
                        if !focused { model.confirmationBlurred = true }
                    }
                    .accessibilityLabel(CreateCopy.lConfirmPassword)
            }
            if let error = model.passwordError ?? model.confirmationError {
                GridRow { Color.clear.gridCellUnsizedAxes([.horizontal, .vertical]); caption(error, bad: true) }
            }
        }
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(CreateCopy.nPWShort).font(.callout).foregroundStyle(quiet).fixedSize(horizontal: false, vertical: true)
            Button(CreateCopy.lMore) { showingPasswordNote = true }
                .buttonStyle(.link).font(.callout)
                .popover(isPresented: $showingPasswordNote) { note(CreateCopy.nPWLong) }
        }
        .setupProse()
        caption(model.passwordFileVaultNote)
    }

    private func label(_ text: String) -> some View {
        Text(text).gridColumnAlignment(.trailing)
    }

    // MARK: Page 3: ready to install

    @ViewBuilder private var readyPage: some View {
        Text(CreateCopy.readyLead).setupProse()
        SetupCard {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 8) {
                ForEach(Array(model.summary.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        Text(row.label).foregroundStyle(quiet).gridColumnAlignment(.trailing)
                        Text(verbatim: row.value).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        ForEach(model.generalWarnings, id: \.self) { caption($0) }
        // Once open it stays open: the fields are the settings, and a button to hide them again would
        // only raise the question of whether hiding them undoes what was changed.
        if !model.showsCustomize {
            Button(CreateCopy.bCustomize) { model.customizing = true }
        } else {
            vmSection
            extrasSection
        }
        Text(.init(CreateCopy.fLicence))
            .font(.callout).foregroundStyle(quiet)
            .setupProse()
    }

    private var vmSection: some View {
        FormSection(CreateCopy.hVM) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    label(CreateCopy.lName)
                    TextField("", text: $model.vmName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260)
                        .help(CreateCopy.vmNameTooltip)
                        .accessibilityLabel(CreateCopy.lName)
                        .accessibilityHint(CreateCopy.vmNameTooltip)
                }
                if let error = model.vmNameError { GridRow { Color.clear.gridCellUnsizedAxes([.horizontal, .vertical]); caption(error, bad: true) } }
                GridRow {
                    label(CreateCopy.lProcessorCores)
                    number(CreateCopy.lProcessorCores, value: $model.cores, range: CreateChoices.coresRange(model.facts.mac),
                           unit: nil, help: CreateCopy.windowCoresTooltip(topTier: model.facts.mac.topTierCores))
                }
                GridRow {
                    label(CreateCopy.lMemory)
                    number(CreateCopy.lMemory, value: $model.memoryGB, range: CreateChoices.memoryRangeGB(model.facts.mac),
                           unit: "GB", help: CreateCopy.memoryTooltip(suggested: CreateChoices.suggestedMemoryGB(model.facts.mac)))
                }
                GridRow {
                    label(CreateCopy.lDisk)
                    VStack(alignment: .leading, spacing: 4) {
                        number(CreateCopy.lDisk, value: $model.diskGB, range: CreateChoices.diskRangeGB, unit: "GB",
                               help: CreateCopy.diskTooltip)
                        caption(CreateCopy.diskCaption)
                    }
                }
                GridRow {
                    label(CreateCopy.lComputer)
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("", text: $model.computerName)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 200)
                            .help(CreateCopy.windowComputerTooltip(host: CreateChoices.hostName(computerName: model.computerName)))
                            .accessibilityLabel(CreateCopy.lComputer)
                            .accessibilityHint(CreateCopy.windowComputerTooltip(
                                host: CreateChoices.hostName(computerName: model.computerName)))
                        caption(CreateCopy.lComputerHost(CreateChoices.hostName(computerName: model.computerName)))
                        caption(model.computerNameError, bad: true)
                    }
                }
                GridRow {
                    label(CreateCopy.lEdition)
                    VStack(alignment: .leading, spacing: 4) {
                        Picker("", selection: editionSelection) {
                            ForEach(model.iso.facts?.info.editions ?? [], id: \.index) { edition in
                                Text(edition.displayName).tag(edition.index)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .accessibilityLabel(CreateCopy.lEdition)
                        .accessibilityHint(CreateCopy.windowInstallTooltip)
                        if let warning = model.homeWarning { caption(warning, orange: true) }
                    }
                }
                GridRow {
                    label(CreateCopy.lProductKey)
                    VStack(alignment: .leading, spacing: 4) {
                        productKeyField
                        caption(model.productKeyError, bad: true)
                        caption(CreateCopy.nProductKeyShort)
                    }
                }
            }
            caption(model.coresWarning)
            ForEach(model.memoryWarnings, id: \.self) { caption($0) }
            if model.facts.menuVMName != nil {
                if controller.isEmbedded {
                    caption("Winbar will look after this VM from now on—setup, Connect and the menu bar item—instead of “\(model.facts.menuVMName ?? "the current VM")”.")
                } else {
                    Toggle(CreateCopy.lSelect, isOn: $model.select)
                }
            }
        }
    }

    /// A plain TextField, not a SecureField: unlike the password, the key ends up in the answer file as
    /// plain text anyway, and hiding it on screen would suggest Winbar protects it somewhere it doesn't.
    /// The caption under it says exactly where it goes. Under the edition, because a key is for an
    /// edition: Windows Setup refuses one that isn't for the edition being installed.
    private var productKeyField: some View {
        TextField(CreateCopy.lProductKeyPlaceholder, text: $model.productKey)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 260)
            .help(CreateCopy.productKeyTooltip)
            .accessibilityLabel(CreateCopy.lProductKey)
            .accessibilityHint(CreateCopy.productKeyTooltip)
    }

    private func number(_ label: String, value: Binding<Int>, range: ClosedRange<Int>, unit: String?,
                        help: String) -> some View {
        HStack(spacing: 4) {
            TextField("", value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 60)
                .accessibilityLabel(label)
                .accessibilityHint(help)
            if let unit { Text(unit).foregroundStyle(quiet) }
            Stepper("", value: value, in: range).labelsHidden().accessibilityHidden(true)
        }
        .help(help)
    }

    private var editionSelection: Binding<Int> {
        Binding(get: { model.edition?.index ?? -1 },
                set: { index in model.edition = model.iso.facts?.info.editions.first { $0.index == index } })
    }

    // MARK: Extras

    private var extrasSection: some View {
        FormSection(CreateCopy.hWinbar) {
            check(.remoteDesktop, trailing: model.isHomeEdition ? CreateCopy.lNotOnHome : nil)
            check(.autologon)
            check(.winbarTuning)
            check(.regionalFromMac)
            if let detail = model.regionalDetail { caption(detail, indent: 24) }
            ForEach(model.regionalNotes, id: \.self) { caption($0, indent: 24) }
            check(.skipPrivacy)
            check(.noBitLocker)
            if let note = model.bitLockerNote { caption(note, indent: 24) }
            check(.qol)
            check(.noOnlineAccount)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(CreateCopy.alwaysDone).font(.callout).foregroundStyle(quiet).fixedSize(horizontal: false, vertical: true)
                Button(CreateCopy.lWhy) { showingAlwaysNote = true }
                    .buttonStyle(.link).font(.callout)
                    .popover(isPresented: $showingAlwaysNote) {
                        note(([CreateOption.bypassRequirements, .localAccount, .guestTools].map(CreateCopy.windowTooltip)
                              + [CreateCopy.windowInstallTooltip]).joined(separator: "\n\n"))
                    }
            }
            .padding(.top, 4)
            // Rufus's rows Winbar leaves out mean something to someone comparing the two, which is who
            // opens this window from the menu; inside Set Up Winbar nobody is (review, 0.2.1).
            if !hosted { omissions }
        }
    }

    private var omissions: some View {
        DisclosureGroup(CreateCopy.rufusOmissionsTitle) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(CreateCopy.rufusOmissions, id: \.name) { option in
                    (Text(option.name).italic() + Text(": " + option.why))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 4)
        }
        .font(.callout)
        .foregroundStyle(quiet)
    }

    private func check(_ option: CreateOption, trailing: String? = nil) -> some View {
        let tooltip = CreateCopy.windowTooltip(option)
        return HStack(alignment: .firstTextBaseline) {
            Toggle(CreateCopy.windowLabel(option), isOn: binding(option))
                .disabled(!model.isEnabled(option))
                .help(tooltip)
                .accessibilityLabel(CreateCopy.windowLabel(option))
                .accessibilityHint(tooltip)
            Spacer()
            if let trailing { Text(trailing).font(.callout).foregroundStyle(quiet) }
        }
    }

    private func binding(_ option: CreateOption) -> Binding<Bool> {
        Binding(get: { model.options.contains(option) },
                set: { on in
                    if on { model.options.insert(option) } else { model.options.remove(option) }
                })
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .frame(width: 380)
            .fixedSize(horizontal: false, vertical: true)
            .padding(16)
    }

    @ViewBuilder
    private func caption(_ text: String?, bad: Bool = false, orange: Bool = false, indent: CGFloat = 0) -> some View {
        if let text, !text.isEmpty {
            Text(text)
                .font(.callout)
                .foregroundStyle(bad ? errorText : (orange ? caution : quiet))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, indent)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Footer

    /// Back, the reason the way on is greyed out, Cancel, and the way on: Continue, then **Install
    /// Windows**. Inside Set Up Winbar it is drawn in that window's own footer band (`SetupFooterBand`),
    /// the one the install after it draws too, so the two can't drift apart and the buttons stay put
    /// when **Install Windows** is pressed.
    @ViewBuilder private var footer: some View {
        if hosted {
            SetupFooterBand { footerRow }
        } else {
            footerRow
                .frame(maxWidth: SetupStyle.contentWidth)
                .padding(.horizontal, SetupStyle.pagePadding)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity)
                .background { VStack { Divider(); Spacer() } }
        }
    }

    private var footerRow: some View {
        let status = model.status(of: model.page)
        return HStack(alignment: .center, spacing: 10) {
            if model.page != .windows {
                Button(CreateCopy.bBack) { model.goBack() }
            }
            if case .blocked(let reason) = status {
                let problem = model.isProblem(status)
                Text(reason)
                    .font(.system(size: SetupStyle.smallestText, weight: problem ? .medium : .regular))
                    .foregroundStyle(problem ? errorText : quiet)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    // A live region, so VoiceOver reads why the way on is off as it changes.
                    .accessibilityAddTraits(.updatesFrequently)
                    .accessibilityLabel(reason)
            }
            Spacer(minLength: 8)
            Button(CreateCopy.bCancel) { controller.close() }
                .keyboardShortcut(.cancelAction)
            if model.page == .ready {
                Button(CreateCopy.bInstall) { controller.create() }
                    .windowDefaultButton()
                    .disabled(!model.canCreate)
            } else {
                Button(CreateCopy.bContinue) { model.goForward() }
                    .windowDefaultButton()
                    .disabled(!model.canContinue(from: model.page))
            }
        }
    }
}

/// A heading for what **Customize…** reveals, with a hairline rule. Internal rather than private so
/// the accessibility tests can read that its title is a heading.
struct FormSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(title).font(.headline)
                VStack { Divider() }
            }
            .accessibilityAddTraits(.isHeader)
            content()
        }
        .padding(.top, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Inside the Set Up Winbar window (gui-wizard.md §2.3, §3.5)

extension CreateWindowController: EmbeddableCreate {
    /// What the wizard hands these views while they're its step 2.
    struct EmbedHost {
        /// Brings the wizard's window forward: the menu's **New Windows VM…** and **Show Install
        /// Progress…**, and an install that ends while it's shown there.
        var present: () -> Void
        /// Closes the wizard's window and leaves the install running: **Hide**.
        var hide: () -> Void
        /// The wizard's window, for the ISO chooser's sheet.
        var window: () -> NSWindow?
        /// The views are done with: `EmbeddedEnd` says how.
        var finished: (EmbeddedEnd) -> Void
    }

    /// How the views hand back to the wizard.
    enum EmbeddedEnd: Equatable {
        /// The install ended well. The wizard reads the Mac again — a new VM exists now, and the job
        /// chose it — and moves on to step 3 once that read says step 2 is done (§2.3).
        /// `setupDisk` is the setup disk's folder when the job couldn't delete it (W_MEDIA_LEFT), so
        /// the wizard can offer to show it and move it to the Trash rather than only saying it's there.
        case installed(id: String, name: String, messages: [CreateMessage], setupDisk: String? = nil)
        /// The form's **Cancel**, or **Close** or **Done** on an ending: back to step 2.
        case handedBack
    }

    /// The hand-back an adopted state calls for, or nil. Only an install that ended well moves the
    /// wizard on by itself; a failure stays on screen with its **Try Again**, **Delete VM…** and **Show
    /// Log**, and a cancel with its note, until **Close** (§2.3). Pure.
    static func embeddedEnd(for state: CreateJobState, embedded: Bool) -> EmbeddedEnd? {
        // A CLI-owned --no-select install can be watched here, but watching isn't permission to
        // change the selected VM. Leave its ending visible and let the person choose explicitly.
        guard embedded, state.outcome == .done, state.plan.select, let id = state.vmID else { return nil }
        // Only the folder the job said it couldn't delete: a folder named in the state for any other
        // reason is not the person's to clear up.
        let left = state.messages.contains { $0.code == SetupDiskActions.leftCode }
        return .installed(id: id, name: state.plan.vmName, messages: state.messages,
                          setupDisk: left ? state.mediaDir : nil)
    }

    /// What embedding does to this window and the job it holds.
    struct Embedding: Equatable {
        /// This window is open: close it, and its content moves into the wizard. Its job is kept
        /// (closing keeps a running one), so the wizard shows the same install, never a second.
        var closesOwnWindow: Bool
        /// The job on screen has ended: let it go, so **Install Windows…** is a fresh form and **Show Install
        /// Progress** the install that's running, not an old ending.
        var letsEndedJobGo: Bool
    }

    /// Pure.
    static func embedding(ownWindowOpen: Bool, job: CreateJobState?) -> Embedding {
        Embedding(closesOwnWindow: ownWindowOpen, letsEndedJobGo: job?.isFinished == true)
    }

    /// Whether there is an install for these views to show: one on screen that hasn't ended, or one
    /// running on this Mac (this app's, the New Windows VM window's, or the CLI's).
    var hasRunningJob: Bool {
        if let job, !job.isFinished { return true }
        return environment.currentJob().map { !$0.isFinished } ?? false
    }

    /// The wizard's **Install Windows…**, **Install Windows in a New VM…** and **Show Install Progress**: from here until
    /// `unembed()` these views are its step 2. The running install, if there is one, is what they show.
    func embed(_ host: EmbedHost) {
        let plan = CreateWindowController.embedding(ownWindowOpen: window != nil, job: job)
        if plan.closesOwnWindow, let window {
            if let sheet = window.attachedSheet { window.endSheet(sheet); sheet.orderOut(nil) }
            window.close() // performClose can refuse a sheet, and isVisible misses minimized windows
            windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window))
        }
        if plan.letsEndedJobGo { forgetJob() }
        isEmbedded = true
        self.host = host
        hostShown()
    }

    /// Back to being this window's views. The wizard calls it when they hand back.
    func unembed() {
        isEmbedded = false
        host = nil
        form.forgetPassword()
        stopClock()
    }

    /// The wizard's window is up with these views in it: what opening this window does.
    func hostShown() {
        if job == nil, let current = environment.currentJob(), !current.isFinished { adopt(current) }
        if phase == .form { environment.refreshForm(self) }
        startClockIfNeeded()
    }

    /// The wizard's window closed with these views in it: what closing this window does, except that
    /// an ended job stays on screen, since the wizard keeps its place and reopens on it (§2.4). The
    /// install itself is never touched: closing is never cancelling.
    func hostClosed() {
        form.forgetPassword()
        stopClock()
    }

    /// Hands back to the wizard. An install that ended well is let go first, so the next **New Windows
    /// VM…** opens a form rather than its ending.
    private func finishEmbedded(_ end: EmbeddedEnd) {
        let host = self.host
        if case .installed = end { forgetJob() }
        host?.finished(end)
    }
}

/// What the Set Up Winbar window asks of `CreateWindowController` when it shows the New Windows VM
/// views as its step 2. A protocol so the wizard's side of the hand-over can be tested with a stand-in:
/// the real controller reads this Mac's settings and install state, and asks UTM for its VMs.
protocol EmbeddableCreate: AnyObject {
    var isEmbedded: Bool { get }
    var hasRunningJob: Bool { get }
    func embed(_ host: CreateWindowController.EmbedHost)
    func unembed()
    func hostShown()
    func hostClosed()
}
