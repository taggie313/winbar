import Foundation
import Darwin

// The install itself: preflight, the media, the VM, the boot and the CD prompt, the stages and their
// limits, finish, cleanup, headless. One run per process; the lock in CreateJob.swift makes sure of
// that.
//
// Everything here is blocking and sequential, on whichever thread called `CreateJob.start`. The only
// other thread is the serial console's own queue, which never touches this object's state: it logs,
// and the run loop reads the watcher's snapshot.

/// Ctrl-C, from the CLI's signal source (not from a signal handler, so a plain lock is safe). The run
/// checks it at every poll and stops without touching the VM.
final class InterruptFlag {
    private var value = false
    private let queue = DispatchQueue(label: "net.elusive.winbar.create.interrupt")

    func raise() { queue.sync { value = true } }
    func clear() { queue.sync { value = false } }
    var raised: Bool { queue.sync { value } }
}

/// Cancel Install… / Delete VM…, raised on the run in this process by `CreateJob.requestCancel`.
/// The window can't take the lock to cancel the install its own process is driving, so it asks the
/// run to do it: the run is the one thing that holds the lock and knows where the install is.
final class CancelRequest {
    private var value: Bool?
    private let queue = DispatchQueue(label: "net.elusive.winbar.create.cancel")

    /// `deleteVM` as `CreateRun.cancel` means it: delete the VM, or keep it and take its CDs off.
    func raise(deleteVM: Bool) { queue.sync { value = deleteVM } }
    func clear() { queue.sync { value = nil } }
    /// The pending request, if any. Reading it doesn't clear it: only the run that acts on it does.
    var deleteVM: Bool? { queue.sync { value } }
}

extension CreateJob {
    /// Raised by the CLI when the person presses Ctrl-C.
    static let interrupt = InterruptFlag()

    /// Stopped before anything existed in UTM: everything Winbar made is gone again.
    static let interruptedClean = CreateJobError("N_STOPPED_CLEAN", "Stopped. Nothing was created.", "", exit: 130)

    /// Stopped after the VM existed: Windows carries on installing, and `--resume` picks it up.
    static func interruptedWatching(_ name: String) -> CreateJobError {
        CreateJobError("N_STOPPED_WATCHING",
                       "Stopped watching. Windows keeps installing in “\(name)”; the last steps (removing the "
                           + "install disks and checking the result) wait for Winbar.", "",
                       nextStep: "winbar create --resume \"\(name)\"", exit: 130)
    }

    /// What `start`/`resume` throw once a `requestCancel` has been carried out. The job is already
    /// saved as `.cancelled`, so this only unwinds the run: exit 130, like Ctrl-C, and `ended`
    /// leaves it out of the state for the same reason — the person stopped it, nothing failed.
    static func cancelled(_ name: String, deletedVM: Bool) -> CreateJobError {
        CreateJobError("N_CANCELLED",
                       deletedVM ? "Cancelled installing Windows. “\(name)” and its setup disk are deleted."
                                 : "Cancelled installing Windows. “\(name)” is kept, without its install disks.",
                       "", exit: 130)
    }
}

/// What a cancel actually did, so the CLI's ✓ lines and the window's wording say the truth rather
/// than assuming every step happened.
struct CreateCancelResult: Equatable, Sendable {
    /// The job as it ended: `.cancelled`, with no setup disk left.
    var state: CreateJobState
    /// UTM no longer has the job's VM — the person deleted or replaced it — so there was nothing to
    /// stop or delete, and Winbar touched no other VM.
    var vmGone = false
    var stopped = false
    var deletedVM = false
    /// The VM was kept and its Windows and setup CDs came off it instead.
    var removedInstallDisks = false
    var deletedSetupDisk = false
    /// The saved PC this job made in Windows App is gone too. False when there never was one, and
    /// when Windows App was open and wouldn't let it go.
    var deletedSavedPC = false
}

final class CreateRun {
    private let lock: CreateLock
    private let media: SetupMedia
    private let log: CreateLog
    private let onChange: (CreateJobState) -> Void
    private(set) var state: CreateJobState

    /// What preflight read from the ISO. The renderer needs its language and build, so the job reads
    /// the ISO itself even when a front-end already showed the person what's on it.
    private var image: WindowsImageInfo?
    private var guestTools: GuestTools.Copy?
    private var awake: SleepAssertion?
    private var history = ActivityHistory()
    private var status: InstallStatus?

    private var serial: SerialBootWatch?
    private var qemuStartedAt: TimeInterval = 0
    private var promptAnswered = false
    private var agentAnsweredAt: TimeInterval?
    /// Wall-clock start of stage 5, for "installing since". The limits run on `watchedSeconds`.
    private var installStartedAt = Date()
    /// This run took over a VM that was already running instead of starting it: it has been up for
    /// however long, so nothing that measures from "QEMU appeared" means anything for it.
    private var tookOverRunningVM = false
    /// When the console last said the CD's bootloader had started. Its key window is the only moment
    /// a keypress in the VM's window does any good.
    fileprivate var cdBootSeenAt = Date.distantPast
    /// How long cdboot.efi waits for a key: 3 s measured live, plus a little.
    static let cdBootKeyWindow: TimeInterval = 4
    /// When this run started watching, and what earlier runs had already watched (the two-hour
    /// limit's budget). nil until the watch begins.
    private var watchStartedAt: TimeInterval?
    private var watchedBefore: TimeInterval = 0

    /// A run driving an install in this process, for `CreateJob.requestCancel`. One at a time: the
    /// lock guarantees it, and the reference is dropped as the run releases everything.
    private static let liveQueue = DispatchQueue(label: "net.elusive.winbar.create.live")
    private static var live = 0
    static var isRunningHere: Bool { liveQueue.sync { live > 0 } }

    var plan: CreatePlan { state.plan }
    var vmName: String { state.plan.vmName }

    // MARK: - Setting up

    init(plan: CreatePlan, id: String, lock: CreateLock, onChange: @escaping (CreateJobState) -> Void) throws {
        self.lock = lock
        self.onChange = onChange
        let made: (media: SetupMedia, notes: [String])
        do {
            made = try SetupMedia.create(id: id, base: CreateJob.base)
        } catch {
            throw CreateJobError.unavailable("E_JOB_FOLDER", "Couldn't make the folder for the install", "\(error)")
        }
        media = made.media
        log = CreateLog(vmName: plan.vmName)
        let now = Date()
        state = CreateJobState(id: id, plan: plan, vmID: nil, stage: .check, detail: nil, startedAt: now,
                               updatedAt: now, finishedAt: nil, outcome: nil, restarts: 0, bytesWritten: nil,
                               shown: [], messages: [], failure: nil, mediaDir: media.directory.path,
                               logPath: log.url.path, watched: true, created: nil, installStartedAt: nil,
                               stageStartedAt: now)
        CreateRun.enteredProcess()
        log.write("winbar \(AppBundle.version) create “\(plan.vmName)”: \(plan.cores) vCPUs, \(plan.memoryMiB) MiB, "
                  + "\(plan.diskGiB) GiB disk, \(plan.edition.name), ISO \(plan.isoPath)")
        log.write("checklist: " + CreateOption.allCases.map { "\($0.rawValue)=\(plan.has($0) ? "on" : "off")" }.joined(separator: " "))
        for note in made.notes { message("W_TIMEMACHINE", note) }
        save()
    }

    /// Picks up a job from its state.json after an interruption.
    init(resuming state: CreateJobState, lock: CreateLock, onChange: @escaping (CreateJobState) -> Void) throws {
        self.lock = lock
        self.onChange = onChange
        guard let directory = state.mediaDir else {
            throw CreateJobError.unavailable("E_JOB_FOLDER", "That install has no folder to carry on from", "")
        }
        do {
            media = try SetupMedia.existing(URL(fileURLWithPath: directory), base: CreateJob.base)
        } catch {
            throw CreateJobError.unavailable("E_JOB_FOLDER", "Couldn't open the install's folder", "\(error)")
        }
        log = state.logPath.map { CreateLog(url: URL(fileURLWithPath: $0)) } ?? CreateLog(vmName: state.plan.vmName)
        self.state = state
        self.state.watched = true
        self.state.failure = nil
        // The job is running again, whatever ended the last run (FLOW F-INTERRUPT).
        self.state.outcome = nil
        self.state.finishedAt = nil
        // The stage is starting again as far as anyone watching is concerned; its old start would
        // show as hours on the window's per-stage clock.
        self.state.stageStartedAt = Date()
        installStartedAt = state.installStartedAt ?? state.startedAt
        watchedBefore = state.watchedSeconds ?? 0
        status = state.status.map(InstallStatus.init)
        CreateRun.enteredProcess()
        save()
    }

    private static func enteredProcess() { liveQueue.sync { live += 1 } }
    private static func leftProcess() { liveQueue.sync { live = max(0, live - 1) } }

    // MARK: - State

    private func save() {
        state.updatedAt = Date()
        // Every save keeps the watched-time budget current, so an interrupted run leaves behind how
        // long it really watched rather than how long ago it started.
        if let started = watchStartedAt {
            state.watchedSeconds = watchedBefore + max(0, ProcessInfo.processInfo.systemUptime - started)
        }
        try? CreateJob.writeState(state, in: media.directory)
        let snapshot = state
        CreateJob.deliver(snapshot, to: onChange)
    }

    private func enter(_ stage: CreateStage, detail: String? = nil) {
        if state.stage != stage || state.stageStartedAt == nil { state.stageStartedAt = Date() }
        state.stage = stage
        state.detail = detail
        log.write("stage \(stage.number)/10 \(stage.rawValue): \(stage.runningTitle)" + (detail.map { " · \($0)" } ?? ""))
        save()
    }

    private func detail(_ text: String?) {
        guard state.detail != text else { return }
        state.detail = text
        save()
    }

    /// The Automation detail, when macOS still has to ask whether this process may control UTM
    /// — the scripting call below it will block on a prompt that may be behind another window. nil
    /// once macOS has an answer, so the stage shows its ordinary line.
    ///
    /// The window shows its own P_AUTOMATION instead, which it recognises by `automationDetailMark`.
    private var automationDetail: String? {
        Automation.willPrompt(bundleID: Config.utmBundleID) ? CreateCopy.automationDetail(app: Automation.host.name) : nil
    }

    /// The stages the stall rule watches: Windows Setup writing to the disk.
    static let stallStages: [CreateStage] = [.copy, .devices, .oobe]

    /// Records whether the VM is quiet right now, so the front-ends can take their stall note down
    /// again when it stirs. W_STALL itself is still said once, by `raise`.
    private func stalled(_ quiet: Bool?) {
        guard state.stalled != quiet else { return }
        state.stalled = quiet
        if quiet == false, state.shown.contains(InstallAlert.stall.rawValue) {
            log.write("the VM is writing again")
        }
        save()
    }

    /// A note or warning, once per job (UX: "shown where they apply, once").
    @discardableResult
    private func message(_ code: String, _ text: String) -> Bool {
        guard !state.shown.contains(code) else { return false }
        state.shown.append(code)
        state.messages.append(CreateMessage(code: code, text: text, at: Date()))
        log.write("\(code): \(text)")
        save()
        return true
    }

    /// Records a failure in the state (so the window and a later `--resume` can show it) and hands it
    /// back to be thrown. Nothing is stopped or deleted: the VM is left exactly as it is.
    ///
    /// The job ends here, `.failed`: a front-end that only watches `outcome` would otherwise show a
    /// spinner on a dead job for ever, and the menu bar would go on refusing to start another
    /// install. Ending it is not the same as giving up on it — `isResumable` still says whether
    /// `--resume` and Try Again can carry on, and the sweep leaves a resumable job's folder alone.
    private func record(_ error: CreateJobError) -> CreateJobError {
        state = CreateRun.ending(state, outcome: .failed, failure: error.failure, at: Date())
        log.write("✗ \(error.failure.code): \(error.failure.title)"
                  + (error.failure.detail.isEmpty ? "" : " — \(error.failure.detail)"))
        save()
        return error
    }

    private func finished(_ outcome: CreateJobState.Outcome) {
        state = CreateRun.ending(state, outcome: outcome, failure: state.failure, at: Date())
        log.write("job \(outcome.rawValue) after \(elapsed(since: state.startedAt))")
        save()
    }

    /// How a job ends, whichever way it ends. Pure, so what the two front-ends will read can be
    /// checked without a run: an ended job is one nobody is watching, with no live detail line and
    /// no stall note — and, for a failure, `outcome` as well as `failure`, or `isFinished` would
    /// leave both of them showing a spinner on a dead install for ever.
    static func ending(_ state: CreateJobState, outcome: CreateJobState.Outcome, failure: CreateFailure?,
                       at now: Date) -> CreateJobState {
        var state = state
        state.outcome = outcome
        state.failure = failure
        state.finishedAt = now
        state.watched = false
        state.detail = nil
        state.stalled = nil
        return state
    }

    /// A poll point: Ctrl-C, or the window's Cancel Install…. Both leave the run; only the cancel
    /// touches the VM, and it does that here, inside the process that holds the lock.
    private func checkInterrupt() throws {
        if let deleteVM = CreateJob.cancelRequest.deleteVM { throw cancelHere(deleteVM: deleteVM) }
        guard CreateJob.interrupt.raised else { return }
        if state.stage.number < CreateStage.vm.number || state.vmID == nil {
            // Nothing exists in UTM yet, so the setup disk (with the password in it) goes now. The
            // job is over: a front-end following it has to be told, or it waits for an install that
            // will never write another line.
            deleteMedia(announce: false)
            // The saved PC was written a stage earlier, so it points at a host that will now never
            // exist. It goes with everything else.
            CreateRun.removeSavedPC(&state, log: log)
            log.write("stopped before anything was created; the setup disk is deleted")
            finished(.cancelled)
            throw CreateJob.interruptedClean
        }
        state.watched = false
        save()
        throw CreateJob.interruptedWatching(vmName)
    }

    /// Carries out a `CreateJob.requestCancel` while this run still holds the lock, and hands back
    /// the error that unwinds it. The job is saved `.cancelled` (or, if the cancel itself failed,
    /// `.failed` with what went wrong), so whichever front-end is watching learns the job ended.
    private func cancelHere(deleteVM: Bool) -> CreateJobError {
        CreateJob.cancelRequest.clear()
        log.write("cancel requested from this process (\(deleteVM ? "delete the VM" : "keep the VM"))")
        serial?.stop()
        serial = nil
        state.watched = false
        do {
            let done = try CreateRun.cancel(state, deleteVM: deleteVM, log: log)
            state = done.state
            CreateJob.deliver(state, to: onChange)
            return CreateJob.cancelled(vmName, deletedVM: done.deletedVM)
        } catch let error as CreateJobError {
            return record(error)
        } catch {
            return record(CreateJobError.unavailable("E_CANCEL", "Couldn't cancel the install", "\(error)"))
        }
    }

    // MARK: - The run

    /// The whole install, from preflight to a headless, finished VM.
    func install(password: String) throws {
        var secret: String? = password
        defer { releaseEverything() }
        do {
            try preflight()
            try fetchGuestTools()
            try buildMedia(password: &secret)
            try createVM()
            try runInstall()
            try finishUp()
        } catch let error as CreateJobError {
            throw CreateRun.asChoiceProblem(ended(error), vmName: vmName)
        }
    }

    /// Carries on after an interruption. The stage decides what has to happen first.
    func resume() throws {
        defer { releaseEverything() }
        do {
            message("N_RESUMED", CreateCopy.nResumed(name: vmName))
            switch state.stage {
            case .check, .guestTools, .media:
                throw CreateJobError.input("E_RESUME_EARLY", "That install stopped before Windows started installing.",
                                           "Nothing of it is left to carry on with.",
                                           nextStep: "winbar create --cancel \"\(vmName)\", then create it again.")
            case .vm where state.created == nil:
                throw CreateJobError.input("E_RESUME_EARLY", "That install stopped while the VM was being created.", "",
                                           nextStep: "winbar create --cancel \"\(vmName)\", then create it again.")
            case .vm, .boot, .copy, .devices, .oobe, .firstLogon:
                try runInstall()
                try finishUp()
            case .finish:
                try finishUp()
            }
        } catch let error as CreateJobError {
            throw CreateRun.asChoiceProblem(ended(error), vmName: vmName)
        }
    }

    /// A name UTM already has is something the person can fix in the form they just filled in, not a
    /// failed install: the window puts E_NAME_TAKEN under the Name field instead of showing an
    /// alert, and the CLI prints the same words and exits 65 either way.
    static func asChoiceProblem(_ error: CreateJobError, vmName: String) -> Error {
        error.failure.code == "E_NAME_TAKEN" ? ChoiceProblem.nameTaken(vmName) : error
    }

    /// Ctrl-C isn't a failure: nothing is written into the state for it, so a later resume doesn't
    /// show a red line where the person simply stopped watching.
    ///
    /// A failure before the VM existed leaves nothing worth resuming, and the setup disk it may
    /// already have made holds the password: that folder goes now rather than waiting for a sweep.
    private func ended(_ error: CreateJobError) -> CreateJobError {
        guard error.exitCode != 130 else { return error }
        let recorded = record(error)
        if state.vmID == nil, state.mediaDir != nil { deleteMedia(announce: false) }
        state.detail = nil
        save()
        return recorded
    }

    private func releaseEverything() {
        serial?.stop()
        serial = nil
        awake?.release()
        awake = nil
        if state.outcome == nil {
            state.watched = false
            save()
        }
        CreateRun.leftProcess()
        lock.release()
    }

    // MARK: - 1. Preflight

    private func preflight() throws {
        enter(.check)
        try checkInterrupt()

        guard UTM.isInstalled else {
            throw CreateJobError.unavailable("E_UTM_MISSING", CreateCopy.eUTMMissingTitle, CreateCopy.eUTMMissingNext)
        }
        let version = UTM.version ?? "an unknown version"
        if let problem = CreatePreflight.utmVersionProblem(UTM.version) { throw problem }
        if let warning = CreatePreflight.utmVersionWarning(UTM.version) { message("W_UTM_UNTESTED", warning) }
        log.write("UTM \(version)")

        detail(automationDetail ?? "Asking UTM for its VMs…")
        let list: [VMInfo]
        switch UTMScripting.listVMs() {
        case .success(let vms):
            list = vms
        case .failure(let error):
            if error.automationDenied {
                throw CreateJobError.unavailable("E_AUTOMATION", "\(Automation.host.name) isn't allowed to control UTM.",
                                                 "Turn on UTM under \(Automation.host.name) in System Settings > "
                                                     + "Privacy & Security > Automation, then run this again.")
            }
            throw CreateJobError.unavailable("E_UTM_LIST", "Couldn't ask UTM which VMs it has", error.description)
        }
        if list.contains(where: { $0.name.compare(vmName, options: .caseInsensitive) == .orderedSame }) {
            throw CreateJobError.input("E_NAME_TAKEN", ChoiceProblem.nameTaken(vmName).description)
        }
        let others = list.filter { $0.isRunning }.map(\.name)
        if !others.isEmpty {
            message("N_OTHER_VMS", "When Windows is installed, Winbar restarts UTM once to take the VM headless. "
                    + "Close your other VMs by then (\(others.joined(separator: ", "))), or the VM keeps its window.")
        }

        let file = (plan.isoPath as NSString).lastPathComponent
        detail("Reading \(file)…")
        do {
            let info = try WindowsISO.inspect(plan.isoPath)
            image = info
            log.write("ISO: \(WindowsISO.versionName(build: info.build)) \(info.language), editions "
                      + info.editions.map(\.name).joined(separator: ", "))
            if let warning = WindowsISO.untestedWarning(info) { message("W_ISO_UNTESTED", warning) }
            if let warning = WindowsISO.removableWarning(plan.isoPath) { message("W_ISO_REMOVABLE", warning) }
            guard info.editions.contains(where: { $0.name == plan.edition.name }) else {
                throw CreateJobError.input("E_ISO_NO_EDITION", "This ISO has no edition called “\(plan.edition.name)”.",
                                           "It has: " + info.editions.map(\.name).joined(separator: ", ") + ".")
            }
        } catch let problem as ISOProblem {
            throw CreateJobError.input(problem.key, problem.message)
        }

        let space = CreatePreflight.freeSpace()
        if let problem = CreatePreflight.spaceProblem(space) { throw problem }
        if let warning = CreatePreflight.spaceWarning(space, diskGiB: plan.diskGiB) { message("W_SPACE", warning) }
        if CreatePreflight.onBattery() {
            message("W_BATTERY", "Your Mac is on battery. Installing Windows keeps several cores busy for ten "
                    + "minutes or more, so plugging in is a good idea.")
        }
        if Host.fileVaultOn == false { message("N_PW_FILEVAULT_OFF", CreateCopy.nPWFileVaultOff) }
        detail(nil)
        log.write("✓ \(CreateStage.check.doneTitle)")
    }

    // MARK: - 2. UTM Guest Tools (D1)

    private func fetchGuestTools() throws {
        enter(.guestTools)
        try checkInterrupt()
        do {
            if let path = plan.guestToolsPath {
                guestTools = GuestTools.Copy(url: try GuestTools.userSupplied(path), downloadedAt: nil)
                detail("Checked its SHA-256…")
            } else if let cached = GuestTools.cached() {
                guestTools = cached
                if let date = cached.downloadedAt {
                    detail("Using the copy downloaded on \(DateFormatter.day.string(from: date))")
                }
            } else {
                var lastShown = Date.distantPast
                // The download blocks this thread until it's done, so the state this callback touches
                // has no other writer while it runs; the throttle keeps it to one line a second.
                guestTools = try GuestTools.obtain(progress: { [weak self] done, total in
                    guard Date().timeIntervalSince(lastShown) > 1 else { return }
                    lastShown = Date()
                    self?.detail(total > 0 ? "Downloading: \(done >> 20) of \(total >> 20) MB"
                                           : "Downloading: \(done >> 20) MB")
                }, waiting: { [weak self] in
                    // Another Winbar has the download. This runs on this thread, before the wait.
                    self?.message("N_GT_WAITING", CreateCopy.nGTWaiting)
                    self?.detail(CreateCopy.nGTWaitingDetail)
                })
                detail("Checking its SHA-256…")
            }
        } catch let problem as GuestToolsProblem {
            throw CreateJobError.unavailable(problem.key, problem.message)
        }
        detail(nil)
        log.write("✓ \(CreateStage.guestTools.doneTitle) (\(guestTools?.url.path ?? "?"))")
    }

    // MARK: - 3. The setup disk

    /// Renders the answer file with the password and burns WINBAR_SETUP. The password is taken
    /// `inout` and cleared the moment the ISO is verified: this is the only place it is ever used.
    private func buildMedia(password: inout String?) throws {
        enter(.media)
        try checkInterrupt()
        guard let image, let guestTools else {
            throw CreateJobError.unavailable("E_MEDIA", "Winbar lost track of what it read from the ISO", "")
        }
        guard let secret = password else {
            throw CreateJobError.unavailable("E_MEDIA", "The Windows password wasn't passed to the install", "")
        }
        let files: [SetupFile]
        do {
            files = try AnswerFile.render(plan: plan, image: image, password: secret)
        } catch let failure as AnswerFile.Failure {
            password = nil
            throw CreateJobError.input("E_ANSWER_FILE", "Winbar couldn't make Windows' answer file", failure.description)
        }
        do {
            let iso = try media.build(files: files, guestTools: guestTools.url)
            log.write("✓ \(CreateStage.media.doneTitle): \(iso.path)")
        } catch {
            password = nil
            throw CreateJobError.unavailable("E_MEDIA", "Couldn't make the setup disk", "\(error)")
        }
        saveWindowsAppPC(password: secret)
        password = nil   // the answer file is written; nothing needs it again
        detail(nil)
    }

    /// Saves the PC in Windows App, here, while the password is still in hand.
    ///
    /// Here and not at the end of the install: the password is a parameter of this run and is
    /// dropped the moment the answer file exists. Saving the PC half an hour later would mean
    /// holding the secret in memory all that time to save two seconds of work, and there is nothing
    /// to wait for — a saved PC is only a record, and Windows App doesn't check that the host is up.
    ///
    /// Nothing here can fail the install. Windows App being open is the expected refusal (two
    /// writers on its database can lose every saved PC the person has), and it becomes a note saying
    /// how to do it afterwards.
    private func saveWindowsAppPC(password: String) {
        guard WindowsAppBookmarks.executableURL != nil else { return }   // C1 already says it isn't installed
        let host = CreateChoices.hostName(computerName: plan.computerName)
        do {
            switch try WindowsAppBookmarks.save(host: host, user: plan.userName, password: password,
                                                friendlyName: plan.vmName) {
            case .created(let saved):
                state.savedPCID = saved.id
                save()
                log.write("✓ saved the PC “\(saved.name)” in Windows App for \(host) (id \(saved.id))")
                message("N_PC_SAVED", CreateCopy.nPCSaved(name: saved.name))
            case .alreadyThere(let saved):
                log.write("Windows App already had a saved PC for \(host) (“\(saved.name)”); left alone")
                message("N_PC_EXISTS", CreateCopy.nPCExists(name: saved.name, host: host))
            }
        } catch {
            // `WindowsAppBookmarks` redacts the password out of anything Windows App printed, so
            // this is safe to log; the argv itself is never built into a string anywhere.
            let running = (error as? WindowsAppBookmarks.Failure) == .appRunning
            log.write("couldn't save the PC in Windows App: \(error)")
            message(running ? "N_PC_APP_RUNNING" : "N_PC_FAILED",
                    CreateCopy.nPCNotSaved(appRunning: running, host: host))
        }
    }

    // MARK: - 4. The VM

    private func createVM() throws {
        enter(.vm, detail: automationDetail)
        try checkInterrupt()
        awake = SleepAssertion(reason: "Installing Windows in \(vmName)")
        let result = CreateScripts.createVM(name: vmName, windowsISO: (plan.isoPath as NSString).expandingTildeInPath,
                                            answerISO: media.isoURL.path, cores: plan.cores,
                                            memoryMiB: plan.memoryMiB, diskMiB: plan.diskGiB * 1024)
        switch result {
        case .success(let created):
            state.vmID = created.vmID
            state.created = created
            log.write("✓ \(CreateStage.vm.doneTitle): id \(created.vmID), disk \(created.systemDiskID), "
                      + "CDs \(created.windowsCDID)/\(created.setupCDID), MAC \(created.mac), "
                      + "\(created.displays) display(s), serial \(created.serial.rawValue)")
            if created.serial != .ptty {
                message("N_NO_SERIAL", "This VM has no serial console, so Winbar answers the installer's "
                        + "“Press any key” prompt through UTM's window instead.")
            }
            save()
        case .failure(let error):
            if case .nameTaken = error {
                throw CreateJobError.input("E_NAME_TAKEN", ChoiceProblem.nameTaken(vmName).description)
            }
            if case .vmDiffers(let vmID, let detail) = error {
                // The VM exists but isn't what was asked for (F2). Keep track of it so the person can
                // delete it with --cancel rather than hunting for it in UTM.
                state.vmID = vmID
                save()
                throw CreateJobError.unavailable("E_UTM_CREATE", "UTM created the VM but stored something unexpected",
                                                 detail, nextStep: "winbar create --cancel \"\(vmName)\" deletes it.")
            }
            if case .automationDenied = error {
                throw CreateJobError.unavailable("E_AUTOMATION", "\(Automation.host.name) isn't allowed to control UTM.",
                                                 "Turn on UTM under \(Automation.host.name) in System Settings > "
                                                     + "Privacy & Security > Automation, then run this again.")
            }
            throw CreateJobError.unavailable("E_UTM_CREATE", "UTM couldn't create the VM", error.error.description)
        }
    }

    /// What create records in Winbar's settings once the install has worked, so `winbar setup` and
    /// the menu look after the new VM and don't re-ask what the checklist already answered.
    /// `Config.selectVM` clears the previous VM's per-VM settings, so this runs at the end of
    /// stage 10 and nowhere else — and not at all with `--no-select`.
    private func select(created: CreatedVM, bitLockerOn: Bool?, headless: Bool) {
        guard let selection = CreateRun.selection(plan: plan, created: created, bitLockerOn: bitLockerOn,
                                                  headless: headless) else { return }
        _ = Config.selectVM(selection.vmName)
        Config.vmMAC = selection.mac
        Config.rdpHost = selection.rdpHost
        Config.rdpUser = selection.rdpUser
        Config.keepBitLocker = selection.keepBitLocker
        Config.noVisualTweaks = selection.noVisualTweaks
        Config.declinedAutologon = selection.declinedAutologon
        Config.declinedRemoteDesktop = selection.declinedRemoteDesktop
        Config.declinedTuning = selection.declinedTuning
        Config.consoleEnabled = selection.consoleEnabled
        if let on = selection.bitLockerOn { Config.recordBitLocker(on: on) }
        log.write("Winbar now looks after “\(selection.vmName)”")
    }

    /// Everything create writes into Winbar's settings at the end, or nil with `--no-select`. Pure,
    /// so the `--no-select` promise ("Winbar keeps looking after the VM it has now") can be checked
    /// without touching this Mac's settings: nil here has to mean *nothing* is written, the MAC and
    /// the display state included, or those keys end up describing a different VM than the one
    /// Winbar says it looks after.
    struct Selection: Equatable {
        var vmName: String
        var mac: String
        var rdpHost: String
        var rdpUser: String
        var keepBitLocker: Bool
        var noVisualTweaks: Bool
        var declinedAutologon: Bool
        var declinedRemoteDesktop: Bool
        var declinedTuning: Bool
        var consoleEnabled: Bool
        /// What the guest audit saw, when it could be read.
        var bitLockerOn: Bool?
    }

    static func selection(plan: CreatePlan, created: CreatedVM, bitLockerOn: Bool?,
                          headless: Bool) -> Selection? {
        guard plan.select else { return nil }
        return Selection(vmName: plan.vmName, mac: created.mac,
                         rdpHost: CreateChoices.hostName(computerName: plan.computerName), rdpUser: plan.userName,
                         keepBitLocker: !plan.has(.noBitLocker), noVisualTweaks: plan.noVisualTweaks,
                         declinedAutologon: !plan.has(.autologon),
                         declinedRemoteDesktop: !plan.has(.remoteDesktop),
                         declinedTuning: !plan.has(.winbarTuning), consoleEnabled: !headless,
                         bitLockerOn: bitLockerOn)
    }

    // MARK: - 5. Start, answer the prompt, and watch

    private func runInstall() throws {
        if state.stage.number < CreateStage.boot.number { enter(.boot) }
        if awake == nil { awake = SleepAssertion(reason: "Installing Windows in \(vmName)") }
        if state.installStartedAt == nil {
            state.installStartedAt = Date()
            installStartedAt = state.installStartedAt ?? Date()
        }
        try checkInterrupt()
        try startVM()
        openSerial()
        // Whatever ends the watch, what it watched is folded into the budget and the clock stops:
        // the last steps aren't time Windows spends installing.
        defer { stopCountingWatchedTime() }
        try watchInstall()
    }

    private func stopCountingWatchedTime() {
        guard watchStartedAt != nil else { return }
        watchedBefore = watchedSoFar(now: ProcessInfo.processInfo.systemUptime)
        watchStartedAt = nil
        state.watchedSeconds = watchedBefore
    }

    /// Starts the VM (or takes over a running one, after a resume) and brings UTM forward so the
    /// installer's window is visible: this is the one run where watching it helps.
    private func startVM() throws {
        guard let vmID = state.vmID else {
            throw CreateJobError.unavailable("E_VM_GONE", "Winbar doesn't know which VM this install belongs to", "")
        }
        if let running = VMProcesses.find(vmName, id: state.vmID) {
            qemuStartedAt = ProcessInfo.processInfo.systemUptime
            tookOverRunningVM = true
            log.write("the VM is already running (pid \(running.pid)); taking it over as it is")
            return
        }
        if case .success(let info?) = UTMScripting.vm(named: vmName), info.status == "paused" {
            message("N_RESUME_SUSPENDED", "The VM was suspended. Resuming it; Windows carries on where it was.")
        } else if state.stage.number >= CreateStage.devices.number {
            // Setup had already written its boot loader, so the disk boots and Windows carries on. A
            // key pressed now would restart Setup from scratch, which is why the watcher is told.
            message("N_RESUME_LATE", "The VM was stopped after Windows Setup had copied its files. Starting it again "
                    + "from its own disk; if Windows says “The computer restarted unexpectedly”, the quickest fix is "
                    + "to start over: winbar create --cancel \"\(vmName)\", then create it again.")
        } else if state.stage.number >= CreateStage.copy.number {
            message("N_RESUME_EARLY", "The VM was shut off while Setup was copying files. Starting it again; Setup "
                    + "starts that over.")
        }
        detail("Starting the VM…")
        switch UTM.start(vmName, id: state.vmID, cacheSettings: plan.select) {
        case .success(let process):
            qemuStartedAt = ProcessInfo.processInfo.systemUptime
            // A new QEMU process counts from zero, so what the last one had written says nothing
            // about this one — and the keypress fallback reads that number to decide whether Setup
            // is past the “Press any key” prompt.
            state.bytesWritten = nil
            log.write("QEMU up (pid \(process.pid)) for VM \(vmID)")
        case .failure(let error):
            throw CreateJobError.unavailable(CreatePreflight.startFailureCode(error), "Couldn't start \(vmName)",
                                             error.description)
        }
        UTM.open()   // The installer's window in front, once
    }

    /// Opens the VM's serial console and lets the BootWatcher answer "Press any key to boot from CD".
    /// Failure here is not fatal: the keypress fallback takes over.
    private func openSerial() {
        guard let vmID = state.vmID, state.created?.serial != .absent else { return }
        var address: String?
        for _ in 0..<20 {
            if case .success(let found) = CreateScripts.serialAddress(vmID: vmID), let found, !found.isEmpty {
                address = found
                break
            }
            pause(0.5)
        }
        guard let address else {
            log.write("no serial console address after 10 s; using the keypress fallback")
            return
        }
        switch SerialConsole.open(path: address, logURL: log.serialURL) {
        case .failure(let error):
            log.write("couldn't open the serial console (\(error.description)); using the keypress fallback")
        case .success(let console):
            log.write("serial console: \(address)")
            // These handlers run on the console's own queue: they only write to the log, which is
            // queue-protected. The run loop reads the watcher through `snapshot`.
            serial = console.watchBoot(BootWatcher(diskBoots: state.restarts), onAction: { [log, weak self] action in
                log.write("serial: \(action)")
                // The CD's bootloader is waiting for a key on the graphical console, which is the one
                // console Winbar can't read or type into over the serial port. The watcher is already
                // sending keys down the serial line; press one in the VM's window as well, in case
                // cdboot.efi is only listening there (2026-09-20: the prompt itself never appears on
                // serial, so this window is the only warning there is).
                if case .cdBoot = action { self?.cdBootSeenAt = Date() }
            }, onClosed: { [log] reason in
                // QEMU has gone, which the run loop sees for itself; this is for the log's record.
                log.write("serial console closed: \(reason)")
            })
        }
    }

    /// The watch loop: one tick a second until `status.txt` is complete, the VM stops, a limit ends
    /// the run, or Ctrl-C.
    private func watchInstall() throws {
        guard let vmID = state.vmID else {
            throw CreateJobError.unavailable("E_VM_GONE", "Winbar doesn't know which VM this install belongs to", "")
        }
        // A resume that already knows how the install went has nothing left to watch for: the only
        // signal this loop waits on is the status file, and it is in the state.
        if status != nil {
            advanceStage()
            return
        }
        var lastSample = Date.distantPast
        var lastAgentPoll = Date.distantPast
        var lastStatusPoll = Date.distantPast
        var lastKeyPress = Date.distantPast
        var fallbackUsed = false
        let watchStart = ProcessInfo.processInfo.systemUptime
        watchStartedAt = watchStart
        lastRestartAt = CreateRun.seededLastRestart(restarts: state.restarts, lastRestartAt: lastRestartAt,
                                                    watchStartedAt: watchStart)
        log.write("watching (\(Int(watchedBefore / 60)) min watched so far of the \(Int(InstallLimits.whole / 60))-"
                  + "minute limit)")

        while true {
            try checkInterrupt()
            let now = ProcessInfo.processInfo.systemUptime

            // The VM's own process: gone means Windows isn't installing any more.
            guard let process = VMProcesses.find(vmName, id: state.vmID) else {
                throw CreateJobError.install("E_VM_STOPPED",
                                             "The VM stopped before Windows finished installing (closed or suspended "
                                                 + "in UTM, or the Mac restarted).",
                                             "", nextStep: "winbar create --resume \"\(vmName)\"")
            }

            let snapshot = serial?.snapshot
            if let watcher = snapshot?.watcher {
                promptAnswered = promptAnswered || watcher.answers > 0
                if watcher.diskBoots != state.restarts {
                    state.restarts = watcher.diskBoots
                    lastRestartAt = now
                    save()
                }
            }
            if !promptAnswered, (state.bytesWritten ?? 0) > InstallLimits.fallbackProgressBytes {
                // This QEMU process filling the disk up is proof the installer got past the prompt,
                // whether or not there is a console to read. `startVM` clears the count
                // when it starts the VM, so this is always about the process running now.
                promptAnswered = true
                log.write("the VM has written \(state.bytesWritten ?? 0) bytes, so Setup is running")
            }

            // The keypress fallback: no console, or nothing read from it 20 s after QEMU appeared.
            let noSerialText = snapshot == nil || (snapshot?.lastTextAt == nil && now - qemuStartedAt > 20)
            // Either nothing is coming from the console at all, or the console just said the CD's
            // bootloader started and its key window (about 3 s) is open.
            let inCDBootWindow = Date().timeIntervalSince(cdBootSeenAt) < CreateRun.cdBootKeyWindow
            if mayPressBootKey, noSerialText || inCDBootWindow, !promptAnswered,
               inCDBootWindow || (now - qemuStartedAt > 3 && now - qemuStartedAt < 30),
               Date().timeIntervalSince(lastKeyPress) >= 2 {
                lastKeyPress = Date()
                fallbackUsed = true
                if case .failure(let error) = CreateScripts.sendBootKey(vmID: vmID) {
                    log.write("keypress fallback: \(error.error.description)")
                } else {
                    log.write("keypress fallback: pressed a key in the VM's window")
                }
            }

            if Date().timeIntervalSince(lastSample) >= 30 {
                lastSample = Date()
                if let sample = ProcessActivity.sample(pid: process.pid, at: now) {
                    history.add(sample)
                    state.bytesWritten = sample.bytesWritten
                }
            }

            if agentAnsweredAt == nil, Date().timeIntervalSince(lastAgentPoll) >= 20 {
                lastAgentPoll = Date()
                if UTM.guestAgentAnswers(vmID) {
                    agentAnsweredAt = now
                    log.write("the guest agent answered")
                }
            }

            if agentAnsweredAt != nil, Date().timeIntervalSince(lastStatusPoll) >= 10 {
                lastStatusPoll = Date()
                if let parsed = pullStatus(vmID: vmID) {
                    status = parsed
                    // Kept in the state as well: after a resume the VM may be shut down and the file
                    // out of reach, and an unreadable result must not pass for a clean install.
                    state.status = parsed.record
                    log.write("status.txt: result=\(parsed.ok ? "ok" : "failed") guest_tools=\(parsed.guestTools) "
                              + "rdp=\(parsed.remoteDesktopOn ? "on" : "off")")
                    save()
                    break
                }
                detail(progressDetail(vmID: vmID) ?? state.detail)
            }

            advanceStage()
            if state.stage != .firstLogon { detail(stageDetail()) }

            let times = installTimes(now: now, serialConsole: !(serial == nil || fallbackUsed))
            stalled(CreateRun.stallStages.contains(state.stage) ? InstallWatch.isStalled(history.samples, now: now) : nil)
            if let alert = InstallWatch.evaluate(times, history: history.samples, now: now,
                                                 shown: Set(state.shown.compactMap(InstallAlert.init(rawValue:)))) {
                try raise(alert)
            }
            pause(1)
        }
    }

    /// Whether Winbar may still press a key in the VM's window to answer “Press any key to boot from
    /// CD”. Never after a disk boot has been seen or Setup has got past copying: a key at that
    /// prompt would start the install again from scratch (FLOW F-BOOT), and the serial watcher
    /// refuses for the same reason. Never on a VM this run only took over either — it has been up
    /// for however long, so "three to thirty seconds after QEMU appeared" describes nothing.
    var mayPressBootKey: Bool {
        CreateRun.mayPressBootKey(stage: state.stage, restarts: state.restarts, tookOverRunningVM: tookOverRunningVM)
    }

    static func mayPressBootKey(stage: CreateStage, restarts: Int, tookOverRunningVM: Bool) -> Bool {
        !tookOverRunningVM && restarts == 0 && stage.number <= CreateStage.copy.number
    }

    /// Where the fifteen-minute agent-silence clock starts when a run begins watching. A restart an
    /// earlier run saw still counts — that is what `state.restarts` is for — but the clock never
    /// starts before this run did: a resume gives the guest the same fifteen minutes a first run
    /// gives it, instead of failing E_AGENT_NEVER on its first tick because the restart it is
    /// measuring from happened last night.
    static func seededLastRestart(restarts: Int, lastRestartAt: TimeInterval?,
                                  watchStartedAt: TimeInterval) -> TimeInterval? {
        if let lastRestartAt { return max(lastRestartAt, watchStartedAt) }
        return restarts > 0 ? watchStartedAt : nil
    }

    /// The limits' view of the install, built from what the watcher and the pollers saw.
    func installTimes(now: TimeInterval, serialConsole: Bool) -> InstallTimes {
        CreateRun.installTimes(stage: state.stage,
                               watchedFor: watchedSoFar(now: now),
                               qemuStartedAt: qemuStartedAt,
                               serialConsole: serialConsole,
                               promptMissed: serial?.snapshot.watcher.flags.contains(.promptMissed) ?? false,
                               restarts: state.restarts,
                               lastRestartAt: lastRestartAt,
                               agentAnsweredAt: agentAnsweredAt,
                               now: now)
    }

    /// How long this job has watched a running VM, this run's watching included. The two-hour limit
    /// runs on this: time the Mac spent asleep, or the hours between an interrupted run and its
    /// resume, were not time Windows spent installing, and FLOW F-INTERRUPT's recovery has to work
    /// the morning after.
    func watchedSoFar(now: TimeInterval) -> TimeInterval {
        CreateRun.watchedSoFar(before: watchedBefore, watchStartedAt: watchStartedAt, now: now)
    }

    /// Pure. `before` is what earlier runs of this job recorded in `watchedSeconds`, and this run
    /// adds only the time since it started watching — the hours between an interruption and its
    /// resume belong to neither.
    static func watchedSoFar(before: TimeInterval, watchStartedAt: TimeInterval?,
                             now: TimeInterval) -> TimeInterval {
        before + max(0, now - (watchStartedAt ?? now))
    }

    /// The same, as a pure function. `watchedFor` is seconds of watching, and the limits measure on a
    /// monotonic clock, so it arrives as a duration rather than as a date.
    static func installTimes(stage: CreateStage, watchedFor: TimeInterval, qemuStartedAt: TimeInterval,
                             serialConsole: Bool, promptMissed: Bool, restarts: Int, lastRestartAt: TimeInterval?,
                             agentAnsweredAt: TimeInterval?, now: TimeInterval) -> InstallTimes {
        InstallTimes(stage: stage, installStartedAt: now - watchedFor, qemuStartedAt: qemuStartedAt,
                     serialConsole: serialConsole, promptMissed: promptMissed, restarts: restarts,
                     lastRestartAt: lastRestartAt, agentAnsweredAt: agentAnsweredAt)
    }

    private var lastRestartAt: TimeInterval?

    /// What a limit means for the run: the two that say Windows is stuck end it (the VM keeps
    /// running, and `--resume` can try again); the other two are shown once and waited out.
    private func raise(_ alert: InstallAlert) throws {
        switch alert {
        case .stall:
            message(alert.rawValue, CreateCopy.wStall)
        case .bootNoPrompt:
            message(alert.rawValue, "The VM started, but the installer's “Press any key” prompt never appeared on its "
                    + "serial console. Look at the VM's window in UTM: if it says “Press any key to boot from CD or "
                    + "DVD”, click in the window and press a key. Winbar carries on by itself.")
        case .agentNever:
            throw CreateJobError.install(alert.rawValue,
                                         "Windows is up, but its guest agent hasn't answered for 15 minutes, so Winbar "
                                             + "can't tell whether setup finished.",
                                         "The UTM Guest Tools probably didn't install. In the VM's window, open File "
                                             + "Explorer, open the setup disk and run utm-guest-tools.exe.",
                                         nextStep: "winbar create --resume \"\(vmName)\"")
        case .timeout:
            throw CreateJobError.install(alert.rawValue,
                                         "Windows still hadn't finished installing after 2 hours, so Winbar stopped "
                                             + "waiting.",
                                         "The VM is still running: look at its window in UTM to see where it stopped.",
                                         nextStep: "To start over: winbar create --cancel \"\(vmName)\", then create it again.")
        }
    }

    /// Moves the stage on from what the signals say, never backwards. A heuristic.
    private func advanceStage() {
        let signals = CreateRun.Signals(restarts: state.restarts, promptAnswered: promptAnswered,
                                        agentAnswered: agentAnsweredAt != nil, statusComplete: status != nil)
        let next = CreateRun.stage(for: signals, current: state.stage)
        guard next != state.stage else { return }
        log.write("✓ \(state.stage.doneTitle)")
        enter(next)
    }

    /// What the install's signals say the stage is. Pure, so the heuristic can be tested on its own.
    struct Signals: Equatable {
        var restarts: Int
        var promptAnswered: Bool
        var agentAnswered: Bool
        var statusComplete: Bool
    }

    static func stage(for signals: Signals, current: CreateStage) -> CreateStage {
        let inferred: CreateStage
        if signals.statusComplete {
            inferred = .finish
        } else if signals.agentAnswered {
            inferred = .firstLogon
        } else if signals.restarts >= 2 {
            inferred = .oobe
        } else if signals.restarts == 1 {
            inferred = .devices
        } else {
            inferred = signals.promptAnswered ? .copy : .boot
        }
        // Never a step back: Windows restarts more than the heuristic expects on some Macs, and a
        // title that jumped backwards would read like something had gone wrong.
        return inferred.number >= current.number ? inferred : current
    }

    private func stageDetail() -> String? {
        let written = state.bytesWritten.map { String(format: "%.1f GB written to the VM's disk", Double($0) / 1e9) }
        switch state.stage {
        case .boot: return "Answering the installer's “Press any key” prompt…"
        case .copy: return written
        case .devices:
            let restarts = "Restarted \(state.restarts) time\(state.restarts == 1 ? "" : "s")"
            return [restarts, written].compactMap { $0 }.joined(separator: " · ")
        case .oobe:
            // The DHCP lease is a supplementary signal only: the tools' network driver is
            // in, which is worth showing, but the stage still moves on the agent.
            let lease = RDP.leasedIP(mac: state.created?.mac) != nil ? "the VM has a network address" : nil
            return ["Your account, region and privacy settings", lease, written].compactMap { $0 }.joined(separator: " · ")
        default: return nil
        }
    }

    // MARK: Reading Windows

    /// `status.txt`, once it holds all three contracted keys. A missing file fails fast, which is the
    /// normal answer while the first-logon script is still running.
    private func pullStatus(vmID: String) -> InstallStatus? {
        let pull = UTM.ctl(["file", "pull", vmID, StatusFile.path], timeout: 30)
        guard pull.status == 0, !pull.timedOut, !pull.stdout.isEmpty else { return nil }
        return StatusFile.parse(pull.stdout)
    }

    /// The optional `progress.txt` the first-logon script writes at each step.
    private func progressDetail(vmID: String) -> String? {
        let pull = UTM.ctl(["file", "pull", vmID, StatusFile.progressPath], timeout: 20)
        guard pull.status == 0, !pull.timedOut else { return "Applying your choices…" }
        let text = StatusFile.decode(pull.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "Applying your choices…" : text
    }

    // MARK: - 6-10. Finish: the audit, the CDs, cleanup, headless

    private func finishUp() throws {
        enter(.finish)
        try checkInterrupt()
        guard let vmID = state.vmID, let created = state.created else {
            throw CreateJobError.unavailable("E_VM_GONE", "Winbar doesn't know which VM this install belongs to", "")
        }
        if status == nil, let pulled = pullStatus(vmID: vmID) {
            status = pulled
            state.status = pulled.record
            save()
        }
        let result = status
        if let result { reportStatus(result) }

        // While Windows is still up: the audit, its log, and whether Remote Desktop actually answers.
        var readiness: RDP.Readiness = .notReady
        var bitLockerOn: Bool?
        if VMProcesses.isRunning(vmName, id: state.vmID) {
            bitLockerOn = audit(vmID: vmID)
            collectGuestLog(vmID: vmID, status: result)
            if plan.has(.remoteDesktop), result?.remoteDesktopOn == true {
                detail("Waiting for Remote Desktop…")
                readiness = RDP.probeNow(mac: created.mac, timeout: 3)
                log.write("RDP probe: \(readiness.rawValue)")
            }
            try checkInterrupt()
            detail("Shutting Windows down…")
            // Up to ten minutes of waiting, so the flag is checked throughout it: Ctrl-C here leaves
            // the job at stage `finish`, which a later `--resume` picks up as it is.
            guard let stopped = UTM.stop(vmName, force: false, timeout: 600,
                                         abort: { CreateJob.interrupt.raised || CreateJob.cancelRequest.deleteVM != nil })
            else {
                log.write("stopped waiting for Windows to shut down (Ctrl-C); Windows carries on shutting down")
                try checkInterrupt()
                return
            }
            if case .failure(let error) = stopped {
                throw CreateJobError.install("E_SHUTDOWN", "Windows didn't shut down, so Winbar left the install disks in place.",
                                             error.description,
                                             nextStep: "Shut Windows down yourself, then winbar create --resume \"\(vmName)\".")
            }
        }

        try checkInterrupt()
        detail("Removing the install disks…")
        switch CreateScripts.finish(vmID: vmID, diskID: created.systemDiskID) {
        case .success(let done):
            log.write("✓ removed \(done.removed) CD(s); \(done.drivesLeft) drive(s) left, display \(done.displays)")
        case .failure(let error):
            // The VM still references the setup disk, so the file stays: a CD whose image is gone
            // makes the next start fail.
            throw CreateJobError.install("E_DETACH", "Couldn't remove the install disks from the VM (\(error.error.title)).",
                                         "Windows is installed. With the VM shut down, remove its CD drives in UTM "
                                             + "(the VM's settings), then delete \(media.isoURL.path).")
        }

        // From here the VM no longer references the setup disk, so whatever happens next it goes.
        defer { deleteMedia() }
        let headless = try goHeadlessOrNot(vmID: vmID, status: result, readiness: readiness)

        awake?.release()
        awake = nil
        // Only now, with Windows installed and the disks off it, does Winbar switch to the new VM:
        // `Config.selectVM` clears every per-VM setting the previous VM had (its Remote Desktop
        // host and user, its saved PC, its BitLocker choice), and a create that failed half an hour
        // in must not have thrown those away: they are what create sets when it finishes.
        select(created: created, bitLockerOn: bitLockerOn, headless: headless)

        if let result, !result.ok {
            let steps = result.failedStepNames.isEmpty ? "" : " (" + result.failedStepNames.joined(separator: ", ") + ")"
            throw CreateJobError.install("E_RESULT_FAILED", "Some of Winbar's first sign-in steps failed\(steps).",
                                         "Windows is installed and Winbar can reach it, so winbar setup can "
                                             + "check everything and fix what it can.",
                                         nextStep: "winbar setup")
        }
        guard result != nil else {
            // Windows is installed — the disks came off and it started again — but nothing said how
            // its first sign-in steps went, and silence must not read as success.
            throw CreateJobError.install("E_RESULT_UNKNOWN",
                                         "Windows is installed, but Winbar couldn't read the result of its first "
                                             + "sign-in steps.",
                                         "The file Windows writes them to was gone by the time Winbar looked, so it "
                                             + "can't say whether Remote Desktop and the rest are on.",
                                         nextStep: "winbar setup")
        }
        finished(.done)
    }

    /// The setup disk, with the password scrambled inside it, goes as soon as nothing references
    /// it. Last, so state.json — which lives in the same folder — outlives every step that
    /// a front-end still wants to see.
    private func deleteMedia(announce: Bool = true) {
        guard state.mediaDir != nil else { return }
        if announce { detail("Deleting the setup disk…") }
        do {
            // The folder itself stays until the sweep takes it: state.json lives in there, and a
            // front-end polling once a second has to be able to see how the job ended.
            try CreateJob.emptyFolder(media.directory, base: CreateJob.base)
            state = CreateRun.afterDeletingMedia(state, directory: media.directory, deleted: true)
            log.write("✓ deleted the setup disk")
        } catch {
            state = CreateRun.afterDeletingMedia(state, directory: media.directory, deleted: false)
            message("W_MEDIA_LEFT", "Couldn't delete the setup disk at \(media.directory.path) (\(error)). It holds "
                    + "your Windows password, scrambled: delete the folder yourself.")
        }
    }

    /// What the state says after trying to delete the setup disk. Pure, because getting it wrong is
    /// invisible: a folder that is still there must still be named in the state, or `--resume` says
    /// there is no folder to carry on from, `--cancel` skips its cleanup, and the ISO holding the
    /// password is left on the disk with the state saying it has gone.
    static func afterDeletingMedia(_ state: CreateJobState, directory: URL, deleted: Bool) -> CreateJobState {
        var state = state
        state.mediaDir = deleted ? nil : directory.path
        return state
    }

    /// What `status.txt` said, as the copy deck's warnings.
    private func reportStatus(_ status: InstallStatus) {
        switch status.guestTools {
        case .installed, .notRequested:
            break
        case .stillRunning:
            message("W_GT_SLOW", "The UTM Guest Tools installer was still running after 20 minutes, so Winbar's first "
                    + "sign-in steps carried on without waiting for it. The guest agent works; if something's missing "
                    + "later, run the installer again from the setup disk.")
        case .exitCode(let code):
            message("W_GT_EXIT", "The UTM Guest Tools installer finished with code \(code). The guest agent works, so "
                    + "Winbar can manage Windows, but a driver may be missing: check Device Manager in Windows.")
        case .notFound:
            message("W_GT_EXIT", "Windows couldn't find the UTM Guest Tools installer on the setup disk. The guest "
                    + "agent is answering, so something installed it; check Device Manager in Windows.")
        case .unreadable(let raw):
            message("W_GT_EXIT", "Windows reported the UTM Guest Tools installer's result as “\(raw)”, which Winbar "
                    + "doesn't recognise. Check Device Manager in Windows.")
        }
        if status.plaintextPassword || status.values["autologon_secret"] == "plaintext" {
            message("W_AUTOLOGON_PLAINTEXT", CreateCopy.autologonPlaintext)
        }
        if plan.has(.remoteDesktop), !status.remoteDesktopOn {
            message("W_RDP_OFF", "Remote Desktop didn't turn on. winbar setup will turn it on.")
        }
        if let error = status.error { log.write("status error: \(error)") }
    }

    /// The guest audit, before the shutdown: BitLocker, and whether a password was left behind
    /// where Setup or Winbar should have removed it. It reads counts and yes/no only — never a
    /// value — so an unscrubbed password can't land in the log.
    ///
    /// Returns whether BitLocker is protecting the VM's disk, when it could be read: it is the new
    /// VM's setting, so it is recorded by `select` at the end, not written here over whichever VM
    /// Winbar is looking after at the moment.
    @discardableResult
    private func audit(vmID: String) -> Bool? {
        detail("Checking Windows…")
        var bitLockerOn: Bool?
        if case .success(let output) = GuestAgent.run(vm: vmID, GuestScripts.bitLockerStatus(), timeout: 90),
           let bitLocker = BitLockerState(output) {
            log.write("audit: BitLocker \(bitLocker.volumeStatus), protection \(bitLocker.protection)")
            bitLockerOn = bitLocker.protected
            if bitLocker.protected {
                message("W_BITLOCKER_ON", "Windows encrypted its disk with BitLocker after all. Winbar left it alone; "
                        + "winbar setup can decrypt it if you'd rather it were off.")
            }
        }
        switch GuestAgent.run(vm: vmID, script: CreateRun.auditScript, timeout: 120) {
        case .failure(let error):
            log.write("audit: couldn't run it (\(error.description))")
        case .success(let output):
            let unscrubbed = output.int("panther_unscrubbed") ?? 0
            log.write("audit: edition \(output["edition"] ?? "?"), answer-file copies \(output.int("panther_files") ?? 0), "
                      + "of those still holding a password \(unscrubbed), "
                      + "plain-text autologon password \(output["plaintext_default_password"] ?? "?")")
            if unscrubbed > 0 {
                message("W_PANTHER", "Windows kept \(unscrubbed) copy/copies of the answer file that still hold your "
                        + "password (in C:\\Windows\\Panther). Delete them in Windows, or let winbar setup report them.")
            }
            if output["plaintext_default_password"] == "yes" {
                message("W_AUTOLOGON_PLAINTEXT", CreateCopy.autologonPlaintext)
            }
        }
        return bitLockerOn
    }

    /// Windows' own first-logon log into the create log, then the folder it lived in goes.
    private func collectGuestLog(vmID: String, status: InstallStatus?) {
        let path = status?.values["log"].flatMap { $0.isEmpty ? nil : $0 } ?? #"C:\Windows\Temp\winbar-install\winbar-firstlogon.log"#
        let pull = UTM.ctl(["file", "pull", vmID, path], timeout: 60)
        if pull.status == 0, !pull.stdout.isEmpty {
            log.writeBlock("Windows' first-logon log (\(path)):", StatusFile.decode(pull.stdout))
        } else {
            log.write("couldn't pull Windows' first-logon log from \(path)")
        }
        _ = UTM.ctl(["exec", vmID, "--cmd", "cmd.exe", "/c", #"rd /s /q C:\Windows\Temp\winbar-install"#], timeout: 30)
    }

    /// D2: end headless when everything says Remote Desktop works, otherwise keep the display and say
    /// how to switch later. The VM is already stopped, so this is one UTM restart and one start.
    /// Returns whether the VM ended up headless.
    @discardableResult
    private func goHeadlessOrNot(vmID: String, status: InstallStatus?, readiness: RDP.Readiness) throws -> Bool {
        let others = (try? UTM.otherRunningVMs(than: vmName).get()) ?? ["(unknown)"]
        let decision = CreateRun.headlessDecision(plan: plan, status: status, readiness: readiness, otherVMsRunning: others)
        log.write("headless: \(decision.go ? "yes" : "no — \(decision.why)")")
        guard decision.go else {
            message("N_KEPT_CONSOLE", "The VM keeps its UTM window: \(decision.why) Turn it off later with "
                    + "winbar display off.")
            try startAgain(vmID: vmID)
            return false
        }
        detail("Turning the VM's display off…")
        UTM.ensureRunning()
        UTM.recordPendingRestart(for: vmName)
        var headless = false
        switch UTMScripting.updateConfiguration(vm: vmName, cpuCores: nil, memoryMB: nil, display: .headless) {
        case .failure(let error):
            message("N_KEPT_CONSOLE", "The VM keeps its UTM window: UTM didn't accept the display change "
                    + "(\(error.description)). Turn it off later with winbar display off.")
        case .success(let applied):
            guard applied.displayCount == 0 else {
                message("N_KEPT_CONSOLE", "The VM keeps its UTM window: UTM still reports "
                        + "\(applied.displayCount.map(String.init) ?? "an unknown number of") display(s). "
                        + "Turn it off later with winbar display off.")
                break
            }
            headless = true
            // The display change can take UTM a minute or two to answer, and a VM the person started
            // in the meantime would go down with UTM — the very thing N_OTHER_VMS warned about at
            // preflight. So ask again, now, and fail closed: no answer counts as "something is
            // running". The restart UTM is owed is already written down, so `winbar start` settles
            // it later, when nothing else is in the way.
            let restart = CreateRun.restartDecision(UTM.otherRunningVMs(than: vmName))
            guard restart.quit else {
                log.write("headless: not quitting UTM — \(restart.why)")
                return keptUTMRunning(because: restart.why)
            }
            if case .failure(let error) = UTM.quit() {
                throw CreateJobError.install("E_RESTART", "Windows is installed, but UTM had to restart and didn't "
                                             + "(\(error.title)).", error.detail, nextStep: "winbar start")
            }
        }
        try startAgain(vmID: vmID)
        return headless
    }

    /// Whether the UTM restart the display change needs may go ahead, and why not when it may not.
    /// Pure, and it fails closed: a list Winbar couldn't read counts as "something is running", the
    /// way `settlePendingRestart` already treats it. Quitting UTM stops every VM it runs, and the
    /// check this replaces was made before a display change that UTM may sit on for 150 seconds.
    static func restartDecision(_ others: Result<[String], WinbarError>) -> (quit: Bool, why: String) {
        switch others {
        case .success(let running) where running.isEmpty:
            return (true, "")
        case .success(let running):
            return (false, "\(running.joined(separator: ", ")) \(running.count == 1 ? "is" : "are") running now")
        case .failure(let error):
            return (false, "Winbar couldn't confirm that no other VM is running (\(error.detail))")
        }
    }

    /// The display is off but UTM couldn't be restarted, because that would have stopped somebody
    /// else's VM. The VM can't start until UTM does restart (utmapp/UTM#7882), so Winbar says so and
    /// leaves it off rather than starting anything or quitting UTM behind the person's back.
    private func keptUTMRunning(because reason: String) -> Bool {
        message("W_UTM_RESTART_OWED", "Windows is installed and the VM's display is off. UTM has to restart before the "
                + "VM starts again, and \(reason), so Winbar left UTM alone. Close the other VMs, then run winbar "
                + "start.")
        return true
    }

    /// Brings the VM back up after finish, and waits for Windows far enough to prove it works.
    private func startAgain(vmID: String) throws {
        detail("Starting Windows…")
        if case .failure(let error) = UTM.start(vmName, id: state.vmID) {
            throw CreateJobError.install("E_RESTART", "Windows is installed, but the VM didn't start again after its "
                                         + "install disks were removed (\(error.title)).", error.detail,
                                         nextStep: "winbar start")
        }
        detail("Waiting for Windows…")
        if UTM.waitForGuestAgent(vmID, timeout: 180) {
            log.write("✓ \(CreateStage.finish.doneTitle)")
        } else {
            message("W_SLOW_BOOT", "Windows didn't answer within three minutes of starting again. It's probably still "
                    + "booting; winbar doctor says how it's doing.")
        }
    }

    /// Whether to go headless, and why not when not. Pure.
    static func headlessDecision(plan: CreatePlan, status: InstallStatus?, readiness: RDP.Readiness,
                                 otherVMsRunning: [String]) -> (go: Bool, why: String) {
        if plan.keepConsole { return (false, "you asked for --console.") }
        if plan.edition.isHome { return (false, "Windows Home can't accept Remote Desktop connections.") }
        if !otherVMsRunning.isEmpty {
            return (false, "going headless restarts UTM, which would stop \(otherVMsRunning.joined(separator: ", ")).")
        }
        guard plan.has(.remoteDesktop) else { return (false, "Remote Desktop is off, so nothing could reach Windows.") }
        guard let status, status.ok else { return (false, "Windows' first sign-in steps didn't all finish.") }
        guard status.remoteDesktopOn else { return (false, "Remote Desktop didn't turn on in Windows.") }
        guard readiness == .ready else { return (false, "Remote Desktop didn't answer on this Mac yet.") }
        return (true, "")
    }

    // MARK: - Cancel

    /// Stops an unfinished install. With `deleteVM` the VM goes (the caller has confirmed);
    /// otherwise it's kept and its install CDs come off first, so the answer disk never outlives
    /// the job. Either way the Mac-side files go.
    ///
    /// Returns what it actually did, and leaves the job saved as `.cancelled`, so the front-end that
    /// asked can say the truth and any other front-end watching state.json learns the job has ended.
    @discardableResult
    static func cancel(_ state: CreateJobState, deleteVM: Bool, log: CreateLog? = nil) throws -> CreateCancelResult {
        var state = state
        let log = log ?? state.logPath.map { CreateLog(url: URL(fileURLWithPath: $0)) }
            ?? CreateLog(vmName: state.plan.vmName)
        let name = state.plan.vmName
        var done = CreateCancelResult(state: state)
        log.write("cancel: \(deleteVM ? "delete the VM" : "keep the VM") “\(name)”")

        if let vmID = state.vmID {
            // Which VM that id is *now*, never whichever VM answers to the job's name: the person
            // may have renamed this one, or deleted it and made another under the same default name
            // by retrying. The stop below is a pulled power cord, so it must not be the wrong VM's.
            let listed: [VMInfo]
            switch UTMScripting.listVMs() {
            case .success(let list):
                listed = list
            case .failure(let error):
                throw CreateJobError.unavailable("E_CANCEL_LIST",
                                                 "Couldn't ask UTM which VMs it has, so Winbar stopped and deleted "
                                                     + "nothing.", error.description,
                                                 nextStep: "Try again once UTM is answering.")
            }
            guard let vm = cancelTarget(vmID: vmID, listed: listed) else {
                done.vmGone = true
                log.write("the VM (id \(vmID)) is no longer in UTM: nothing to stop or delete")
                return try finishCancel(&state, done: done, keepSavedPC: false, log: log)
            }
            if VMProcesses.isRunning(vm.name) || vm.isRunning {
                // It's being thrown away (or its CDs are coming off), so force is right here: nothing
                // of the person's is in a VM that never finished installing.
                if case .failure(let error) = UTM.stop(vm.name, force: true) {
                    throw CreateJobError.unavailable("E_CANCEL_STOP", "Couldn't stop \(vm.name)", error.description)
                }
                done.stopped = true
                log.write("✓ stopped the VM")
            }
            if deleteVM {
                let result = UTM.ctl(["delete", vmID], timeout: 120)
                guard result.ok else {
                    throw CreateJobError.unavailable("E_CANCEL_DELETE", "UTM couldn't delete \(vm.name)", result.output)
                }
                done.deletedVM = true
                log.write("✓ deleted the VM in UTM")
            } else if let created = state.created {
                if case .failure(let error) = CreateScripts.finish(vmID: vmID, diskID: created.systemDiskID) {
                    throw CreateJobError.install("E_DETACH", "Couldn't remove the install disks from the VM "
                                                 + "(\(error.error.title)).",
                                                 "With the VM shut down, remove its CD drives in UTM, then delete "
                                                     + (state.mediaDir ?? "the setup disk"))
                }
                done.removedInstallDisks = true
                log.write("✓ removed the install disks")
            }
        }
        // The saved PC is kept only when the VM it names is kept: a PC pointing at a host that was
        // never installed is a tile that can only ever fail.
        return try finishCancel(&state, done: done, keepSavedPC: !deleteVM && state.vmID != nil, log: log)
    }

    /// Takes away the saved PC this job made in Windows App. Never fails the cancel: the PC is a
    /// record, the worst case is one tile the person can delete themselves, and Windows App being
    /// open is a refusal rather than an error (see `WindowsAppBookmarks`). The id is kept when the
    /// delete didn't happen, so the log still says which one it is.
    @discardableResult
    static func removeSavedPC(_ state: inout CreateJobState, log: CreateLog) -> Bool {
        guard let id = state.savedPCID else { return false }
        do {
            try WindowsAppBookmarks.delete(id)
            state.savedPCID = nil
            log.write("✓ deleted the saved PC in Windows App (id \(id))")
            return true
        } catch {
            log.write("couldn't delete the saved PC in Windows App (\(error)); remove it there if it's in the way")
            return false
        }
    }

    /// The one VM a cancel may touch: the one UTM has under the job's id now, whatever it is called
    /// today. Pure, because the alternative is what this replaces — a force stop aimed at whatever
    /// answers to the job's *name*, which after a rename, or a retry under the same default name, is
    /// somebody else's running VM having its power cord pulled. A missing id means Winbar stops and
    /// deletes nothing at all.
    static func cancelTarget(vmID: String?, listed: [VMInfo]) -> VMInfo? {
        guard let vmID, !vmID.isEmpty else { return nil }
        return listed.first { $0.id == vmID }
    }

    /// The Mac side of a cancel: the setup disk goes, and the job is saved as `.cancelled` where a
    /// front-end can still read it (the folder itself is the sweep's).
    private static func finishCancel(_ state: inout CreateJobState, done: CreateCancelResult,
                                     keepSavedPC: Bool, log: CreateLog) throws -> CreateCancelResult {
        var done = done
        if !keepSavedPC { done.deletedSavedPC = removeSavedPC(&state, log: log) }
        let directory = CreateJob.directory(of: state)
        if state.mediaDir != nil {
            do {
                try CreateJob.emptyFolder(directory, base: CreateJob.base)
                log.write("✓ deleted the setup disk")
            } catch {
                throw CreateJobError.unavailable("E_CANCEL_MEDIA", "Couldn't delete the setup disk at \(directory.path)",
                                                 "\(error)")
            }
            state.mediaDir = nil
            done.deletedSetupDisk = true
        }
        state.outcome = .cancelled
        state.finishedAt = Date()
        state.updatedAt = Date()
        state.watched = false
        state.detail = nil
        state.stalled = nil
        try? CreateJob.writeState(state, in: directory)
        log.write("job cancelled")
        done.state = state
        return done
    }

    // MARK: - The guest audit script

    /// Counts and yes/no only, never a value: an unscrubbed password must not reach the Mac's log
    /// (REVIEWS, security non-blocking #4). Recurses Panther and 25H2's `$WINDOWS.~BT`.
    static let auditScript = #"""
      $roots = @((Join-Path $env:SystemDrive 'Windows\Panther'), (Join-Path $env:SystemDrive '$WINDOWS.~BT'))
      $files = 0
      $unscrubbed = 0
      foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($item in (Get-ChildItem -LiteralPath $root -Recurse -Include '*.xml' -File -ErrorAction SilentlyContinue)) {
          $files++
          $text = Get-Content -LiteralPath $item.FullName -Raw -ErrorAction SilentlyContinue
          if ($null -eq $text) { continue }
          if ($text -match '<Password>|<AdministratorPassword>') {
            if ($text -notmatch '\*SENSITIVE\*DATA\*DELETED\*') { $unscrubbed++ }
          }
        }
      }
      Emit 'panther_files' $files
      Emit 'panther_unscrubbed' $unscrubbed
      $winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
      $plain = $null
      try { $plain = (Get-ItemProperty -LiteralPath $winlogon -Name 'DefaultPassword' -ErrorAction SilentlyContinue).DefaultPassword } catch { }
      Emit 'plaintext_default_password' $(if ([string]::IsNullOrEmpty($plain)) { 'no' } else { 'yes' })
      $auto = $null
      try { $auto = (Get-ItemProperty -LiteralPath $winlogon -Name 'AutoAdminLogon' -ErrorAction SilentlyContinue).AutoAdminLogon } catch { }
      Emit 'autoadminlogon' $auto
      try { Emit 'edition' (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name 'EditionID' -ErrorAction SilentlyContinue).EditionID } catch { }
      """#

    private func elapsed(since date: Date) -> String {
        let minutes = Int(Date().timeIntervalSince(date) / 60)
        return minutes < 1 ? "under a minute" : "\(minutes) min"
    }
}

// MARK: - Preflight pieces that are worth testing on their own

enum CreatePreflight {
    /// UTM 4.7 is the floor (create semantics, serial addresses, `input keystroke`); 4.7.5 is what
    /// create was researched and tested against.
    static let minimumVersion = (4, 7)
    static let testedVersion = "4.7.5"

    static func utmVersionProblem(_ version: String?) -> CreateJobError? {
        guard let version else { return nil }   // UTM is installed but won't say; carry on
        guard let parsed = parseVersion(version) else { return nil }
        guard parsed.major > minimumVersion.0 || (parsed.major == minimumVersion.0 && parsed.minor >= minimumVersion.1)
        else {
            return CreateJobError.unavailable("E_UTM_OLD",
                                              "winbar create needs UTM 4.7 or later, and you have \(version).",
                                              "Update UTM, then run this again.")
        }
        return nil
    }

    static func utmVersionWarning(_ version: String?) -> String? {
        guard let version, version != testedVersion, parseVersion(version) != nil else { return nil }
        return CreateCopy.wUTMUntested(version: version)
    }

    static func parseVersion(_ version: String) -> (major: Int, minor: Int, patch: Int)? {
        let parts = version.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) }
        guard let major = parts.first ?? nil else { return nil }
        return (major, parts.count > 1 ? (parts[1] ?? 0) : 0, parts.count > 2 ? (parts[2] ?? 0) : 0)
    }

    /// Installing needs 40 GiB (about 25 GiB of Windows, plus updates and the media).
    static let neededBytes: Int64 = 40 << 30

    struct Space: Equatable {
        var volume: String
        var freeBytes: Int64
    }

    /// Free space where UTM keeps its VMs: the home volume, asked through the file system so UTM's
    /// own container is never touched.
    static func freeSpace(home: String = NSHomeDirectory()) -> Space {
        let url = URL(fileURLWithPath: home)
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeNameKey])
        return Space(volume: values?.volumeName ?? "this Mac",
                     freeBytes: values?.volumeAvailableCapacityForImportantUsage ?? 0)
    }

    static func spaceProblem(_ space: Space) -> CreateJobError? {
        guard space.freeBytes > 0, space.freeBytes < neededBytes else { return nil }
        return CreateJobError.input("E_SPACE",
                                    CreateCopy.eSpaceTitle(freeGB: gb(space.freeBytes), volume: space.volume),
                                    CreateCopy.eSpaceNext)
    }

    static func spaceWarning(_ space: Space, diskGiB: Int) -> String? {
        guard space.freeBytes >= neededBytes, space.freeBytes < Int64(diskGiB) << 30 else { return nil }
        return CreateCopy.wSpace(diskGB: diskGiB, freeGB: gb(space.freeBytes))
    }

    static func gb(_ bytes: Int64) -> Int { Int(Double(bytes) / 1e9) }

    /// `pmset -g ps` says which power source is in use; no battery at all reads as plugged in.
    static func onBattery() -> Bool {
        parseBattery(Shell.run("/usr/bin/pmset", ["-g", "ps"], timeout: 10).text)
    }

    static func parseBattery(_ text: String) -> Bool {
        text.contains("'Battery Power'")
    }

    /// Which copy-deck error a failed start is: UTM losing an ISO reads very differently from the rest.
    static func startFailureCode(_ error: WinbarError) -> String {
        let text = error.description.lowercased()
        if error.automationDenied { return "E_AUTOMATION" }
        if text.contains("drive image") || text.contains("access") && text.contains("path") { return "E_UTM_ISO_ACCESS" }
        return "E_START"
    }
}

extension StatusFile {
    /// The first-logon script's optional running commentary, beside status.txt.
    static let progressPath = #"C:\Windows\Temp\winbar-install\progress.txt"#
}

extension DateFormatter {
    /// 19 September 2026, for "Using the copy downloaded on {date}".
    static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter
    }()
}
