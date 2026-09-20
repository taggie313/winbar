import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The **New Windows VM…** window: one non-modal `NSWindow` hosting SwiftUI, which
/// shows the form, then the install's progress, then how it ended — always in the same window, so
/// closing it never loses the job.
///
/// Opening the window must not launch UTM, so nothing here asks UTM anything until either
/// UTM is already running or Create is pressed. Reading the ISO and asking UTM for its VM names both
/// block, so both run off the main thread and report back on it.
final class CreateWindowController: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = CreateWindowController()

    enum Phase: Equatable { case form, job }

    @Published private(set) var phase: Phase = .form
    @Published private(set) var form = CreateFormModel(facts: .current())
    /// The install this window is showing, once there is one.
    @Published private(set) var job: CreateJobState?
    /// Something else (the CLI) holds the lock: no Cancel button, and a different footer.
    var readOnly: Bool { !CreateWindowController.ownsJob }

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

    private var window: NSWindow?
    private var clock: Timer?
    /// Set while a job this process is driving is on screen in this window and hasn't finished, so
    /// the window comes back by itself when it ends. Not for a job the app is only
    /// watching: an install running in Terminal must not pull the focus off the terminal that is
    /// asking its next question, and not for a window the person has never opened.
    private var reopenWhenJobEnds = false

    /// The hidden way in from the CLI (`winbar create --window`) and from the menu. Safe to call
    /// again: it brings the existing window forward.
    static func present() { shared.show() }

    /// **Show Install Progress…**: the same window, on the job.
    static func presentProgress() { shared.show() }

    // MARK: - Opening

    private func show() {
        if job == nil, let current = CreateJob.current(), !current.isFinished {
            adopt(current)
        }
        let window = existingWindow()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if phase == .form { refreshForm() }
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
        self.window = window
        return window
    }

    /// Closing is Hide: the job carries on, and the password goes. A job that has
    /// already ended is let go instead of being kept on screen, so the next **New Windows VM…**
    /// opens a form rather than the last install's ending.
    func windowWillClose(_ notification: Notification) {
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
        if job != nil { CreateWindowController.releaseJob() }
        job = nil
        phase = .form
        reopenWhenJobEnds = false
        cancelling = false
        cancelNote = nil
    }

    func close() {
        window?.performClose(nil)
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
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.readISO(url)
        }
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
        form.submitted = true
        guard let plan = form.plan else { return }
        let password = form.password
        form.forgetPassword()
        cancelNote = nil
        CreateWindowController.claimJob()
        adopt(CreateJobState(id: "starting", plan: plan, vmID: nil, stage: .check, detail: nil, startedAt: Date(),
                             updatedAt: Date(), finishedAt: nil, outcome: nil, restarts: 0, bytesWritten: nil,
                             shown: [], failure: nil, mediaDir: nil, logPath: nil, watched: true))
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try CreateJob.start(plan: plan, password: password) { state in
                    CreateWindowController.shared.jobChanged(state)
                }
            } catch {
                DispatchQueue.main.async { self.runEnded(with: error, vmName: plan.vmName) }
            }
        }
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
            let reopen = self.reopenWhenJobEnds
            self.adopt(state)
            if state.isFinished, reopen {
                // The window comes back by itself when the job it was showing ends.
                self.show()
            }
        }
    }

    private func adopt(_ state: CreateJobState) {
        job = state
        phase = .job
        if state.isFinished { cancelling = false }
        reopenWhenJobEnds = CreateWindowController.reopensWhenJobEnds(state, ownsJob: CreateWindowController.ownsJob,
                                                                     windowExists: window != nil)
        startClockIfNeeded()
    }

    /// Whether this window should come back by itself when the job ends: only for one this process
    /// is driving that has already been on screen here. The app follows the CLI's installs too, and
    /// activating Winbar as one of those ends would take the keystrokes meant for Terminal's last
    /// question. Pure, so the rule can be checked without a window.
    static func reopensWhenJobEnds(_ state: CreateJobState, ownsJob: Bool, windowExists: Bool) -> Bool {
        !state.isFinished && ownsJob && windowExists
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
        CreateWindowController.claimJob()
        DispatchQueue.global(qos: .userInitiated).async {
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

    var body: some View {
        Group {
            if controller.phase == .job, let job = controller.job {
                CreateJobView(controller: controller, state: job)
            } else {
                CreateFormView(controller: controller, model: controller.form)
            }
        }
        .frame(minWidth: 600, maxWidth: .infinity, alignment: .topLeading)
    }
}

/// The form: Rufus's layout, Winbar's words.
struct CreateFormView: View {
    @ObservedObject var controller: CreateWindowController
    @ObservedObject var model: CreateFormModel
    @State private var dropping = false
    @State private var showingPasswordNote = false
    @FocusState private var confirmationFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    imageSection
                    vmSection
                    experienceSection
                    winbarSection
                }
                .padding(20)
            }
            footer
        }
        // The whole window takes a dropped .iso, not just the box.
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in handleDrop(providers) }
    }

    // MARK: Windows image

    private var imageSection: some View {
        FormSection(CreateCopy.hImage) {
            isoBox
            Text(CreateCopy.nISOKeep).font(.callout).foregroundStyle(.secondary)
            ForEach(model.isoWarnings, id: \.self) { warning in
                Text(warning).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var isoBox: some View {
        switch model.iso {
        case .none:
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(CreateCopy.isoDrop)
                    Button(CreateCopy.isoChoose) { controller.chooseISOFile() }
                }
                Link(CreateCopy.isoGet, destination: URL(string: CreateCopy.isoGetURL)!)
                    .font(.callout)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(dropping ? Color.accentColor : Color.secondary.opacity(0.5),
                              style: StrokeStyle(lineWidth: dropping ? 2 : 1, dash: [5, 4])))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(CreateCopy.isoDrop)
        case .reading(let file):
            chosenBox(file: file) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(CreateCopy.isoReading).foregroundStyle(.secondary)
                }
            }
        case .failed(let file, let message):
            chosenBox(file: file, bad: true) {
                Text(message).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        case .read(let facts):
            chosenBox(file: facts.file) {
                Text("✓ " + CreateCopy.isoSummary(build: facts.info.build, language: facts.info.language))
            }
        }
    }

    private func chosenBox<Detail: View>(file: String, bad: Bool = false,
                                         @ViewBuilder detail: () -> Detail) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(file).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button(CreateCopy.isoChange) { controller.chooseISOFile() }
            }
            detail().font(.callout)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(bad ? Color.red : (dropping ? Color.accentColor : Color.secondary.opacity(0.4)),
                          lineWidth: dropping ? 2 : 1))
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url, controller.acceptsDrop(url) else { return }
            DispatchQueue.main.async { controller.readISO(url) }
        }
        return true
    }

    // MARK: Virtual machine

    private var vmSection: some View {
        FormSection(CreateCopy.hVM) {
            HStack(alignment: .firstTextBaseline) {
                Text(CreateCopy.lName).frame(width: 70, alignment: .leading)
                TextField("", text: $model.vmName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 300)
                    .help(CreateCopy.vmNameTooltip)
                    .accessibilityLabel(CreateCopy.lName)
                    .accessibilityHint(CreateCopy.vmNameTooltip)
                Spacer()
            }
            caption(model.vmNameError, bad: true, indent: 70)
            HStack(spacing: 22) {
                number(CreateCopy.lCores, value: $model.cores, range: CreateChoices.coresRange(model.facts.mac),
                       unit: nil, help: CreateCopy.coresTooltip(topTier: model.facts.mac.topTierCores))
                number(CreateCopy.lMemory, value: $model.memoryGB,
                       range: CreateChoices.memoryRangeGB(model.facts.mac), unit: "GB",
                       help: CreateCopy.memoryTooltip(suggested: CreateChoices.suggestedMemoryGB(model.facts.mac)))
                number(CreateCopy.lDisk, value: $model.diskGB, range: CreateChoices.diskRangeGB, unit: "GB",
                       help: CreateCopy.diskTooltip)
                Spacer()
            }
            caption(model.coresWarning)
            ForEach(model.memoryWarnings, id: \.self) { caption($0) }
        }
    }

    private func number(_ label: String, value: Binding<Int>, range: ClosedRange<Int>, unit: String?,
                        help: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
            TextField("", value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 54)
                .accessibilityLabel(label)
                .accessibilityHint(help)
            if let unit { Text(unit).foregroundStyle(.secondary) }
            Stepper("", value: value, in: range).labelsHidden().accessibilityHidden(true)
        }
        .help(help)
    }

    // MARK: Windows User Experience

    private var experienceSection: some View {
        FormSection(CreateCopy.hWUE) {
            Text(CreateCopy.hWUESub).font(.callout).foregroundStyle(.secondary)
            check(.bypassRequirements)
            check(.noOnlineAccount)
            accountRow
            check(.regionalFromMac)
            if let detail = model.regionalDetail { caption(detail, indent: 22) }
            ForEach(model.regionalNotes, id: \.self) { caption($0, indent: 22) }
            check(.skipPrivacy)
            installRow
            if let warning = model.homeWarning { caption(warning, bad: false, orange: true, indent: 22) }
            check(.noBitLocker)
            if let note = model.bitLockerNote { caption(note, indent: 22) }
            check(.qol)
            omissions
        }
    }

    private var accountRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                lockedBox(label: CreateCopy.label(.localAccount), tooltip: CreateCopy.tooltip(.localAccount))
                TextField("", text: $model.userName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 130)
                    .accessibilityLabel("User name")
                    .accessibilityHint(CreateCopy.tooltip(.localAccount))
                Spacer()
                alwaysOn
            }
            caption(model.userNameError, bad: true, indent: 22)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(CreateCopy.lPassword)
                SecureField("", text: $model.password)
                    .frame(width: 150)
                    .help(CreateCopy.passwordTooltip)
                    .accessibilityLabel(CreateCopy.lPassword)
                    .accessibilityHint(CreateCopy.passwordTooltip)
                Text(CreateCopy.lConfirm)
                SecureField("", text: $model.confirmation)
                    .frame(width: 150)
                    .focused($confirmationFocused)
                    .onChange(of: confirmationFocused) { _, focused in
                        if !focused { model.confirmationBlurred = true }
                    }
                    .accessibilityLabel(CreateCopy.lConfirm)
                Spacer()
            }
            .padding(.leading, 22)
            caption(model.passwordError ?? model.confirmationError, bad: true, indent: 22)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(CreateCopy.nPWShort).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(CreateCopy.lMore) { showingPasswordNote = true }
                    .buttonStyle(.link).font(.callout)
                    .popover(isPresented: $showingPasswordNote) {
                        Text(CreateCopy.nPWLong)
                            .font(.callout)
                            .frame(width: 380)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(16)
                    }
            }
            .padding(.leading, 22)
            caption(model.passwordFileVaultNote, indent: 22)
        }
    }

    private var installRow: some View {
        HStack(alignment: .firstTextBaseline) {
            lockedBox(label: CreateCopy.installLabel, tooltip: CreateCopy.installTooltip)
            Picker("", selection: editionSelection) {
                ForEach(model.iso.facts?.info.editions ?? [], id: \.index) { edition in
                    Text(edition.displayName).tag(edition.index)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 220)
            .disabled(model.iso.facts == nil)
            .accessibilityLabel("Edition")
            .accessibilityHint(CreateCopy.installTooltip)
            Spacer()
            alwaysOn
        }
    }

    private var editionSelection: Binding<Int> {
        Binding(get: { model.edition?.index ?? -1 },
                set: { index in model.edition = model.iso.facts?.info.editions.first { $0.index == index } })
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
        .foregroundStyle(.secondary)
    }

    // MARK: Winbar

    private var winbarSection: some View {
        FormSection(CreateCopy.hWinbar) {
            check(.autologon)
            check(.remoteDesktop, trailing: model.isHomeEdition ? CreateCopy.lNotOnHome : nil)
            check(.guestTools)
            check(.winbarTuning)
            HStack(alignment: .firstTextBaseline) {
                Text(CreateCopy.lComputer)
                TextField("", text: $model.computerName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
                    .help(CreateCopy.computerTooltip(host: CreateChoices.hostName(computerName: model.computerName)))
                    .accessibilityLabel(CreateCopy.lComputer)
                    .accessibilityHint(CreateCopy.computerTooltip(
                        host: CreateChoices.hostName(computerName: model.computerName)))
                Text(CreateCopy.lComputerHost(CreateChoices.hostName(computerName: model.computerName)))
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
            }
            caption(model.computerNameError, bad: true)
            if model.facts.menuVMName != nil {
                Toggle(CreateCopy.lSelect, isOn: $model.select)
            }
        }
    }

    // MARK: Checklist rows

    private func check(_ option: CreateOption, trailing: String? = nil) -> some View {
        let tooltip = CreateCopy.tooltip(option)
        let locked = option.isLocked
        return HStack(alignment: .firstTextBaseline) {
            Toggle(CreateCopy.label(option), isOn: binding(option))
                .disabled(!model.isEnabled(option))
                .help(tooltip)
                .accessibilityLabel(CreateCopy.label(option) + (locked ? ", \(CreateCopy.lAlwaysOn)" : ""))
                .accessibilityHint(tooltip)
            Spacer()
            if let trailing {
                Text(trailing).font(.callout).foregroundStyle(.secondary)
            } else if locked {
                alwaysOn
            }
        }
    }

    /// A locked row's box: on, not clickable, with its label beside it so a field can follow.
    private func lockedBox(label: String, tooltip: String) -> some View {
        Toggle(label, isOn: .constant(true))
            .disabled(true)
            .help(tooltip)
            .accessibilityLabel(label + ", " + CreateCopy.lAlwaysOn)
            .accessibilityHint(tooltip)
            .fixedSize()
    }

    private var alwaysOn: some View {
        Text(CreateCopy.lAlwaysOn).font(.callout).foregroundStyle(.secondary)
    }

    private func binding(_ option: CreateOption) -> Binding<Bool> {
        Binding(get: { model.options.contains(option) },
                set: { on in
                    if on { model.options.insert(option) } else { model.options.remove(option) }
                })
    }

    @ViewBuilder
    private func caption(_ text: String?, bad: Bool = false, orange: Bool = false, indent: CGFloat = 0) -> some View {
        if let text, !text.isEmpty {
            Text(text)
                .font(.callout)
                .foregroundStyle(bad ? Color.red : (orange ? Color.orange : Color.secondary))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, indent)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            ForEach(model.generalWarnings, id: \.self) { warning in
                Text(warning).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text(model.status.text)
                .fontWeight(model.canCreate ? .regular : .medium)
                .foregroundStyle(model.canCreate ? Color.primary : Color.red)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                // A live region, so VoiceOver reads the reason Create is off as it changes.
                .accessibilityAddTraits(.updatesFrequently)
                .accessibilityLabel(model.status.text)
            Text(.init(CreateCopy.fLicence))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(CreateCopy.bCancel) { controller.close() }
                    .keyboardShortcut(.cancelAction)
                Button(CreateCopy.bCreate) { controller.create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canCreate)
            }
        }
        .padding(20)
    }
}

/// A bold heading with a hairline rule, as Rufus's dialog has.
private struct FormSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(title).fontWeight(.semibold)
                VStack { Divider() }
            }
            .accessibilityAddTraits(.isHeader)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
