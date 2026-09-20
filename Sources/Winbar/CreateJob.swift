import Foundation
import Darwin

// The install job behind `winbar create`: one VM at a time, watched by whoever holds the lock and
// followed read-only by everyone else. This file owns the job's files (the folder, state.json, the
// log, the lock), the sweep for orphans, cancel, and the public API both front-ends call. The run
// itself — preflight, media, the VM, the install, finish — is in CreateJobRun.swift.
//
// The password is a parameter of `start` and nothing else: it is never a property of the job, never
// in state.json, never in the log, never in an argument. `CreateRun` drops its reference as soon as
// the answer file is on the setup disk (Swift can't zero a String's storage, so that is as close to
// erasing it as this can get).

/// Why a job couldn't start, or ended badly, in the copy deck's terms plus the exit code it carries.
/// The CLI prints `failure` and returns `exitCode`; the window shows the same failure.
struct CreateJobError: Error, CustomStringConvertible {
    var failure: CreateFailure
    var exitCode: Int32

    init(_ code: String, _ title: String, _ detail: String, nextStep: String? = nil, exit: Int32) {
        failure = CreateFailure(code: code, title: title, detail: detail, nextStep: nextStep)
        exitCode = exit
    }

    init(failure: CreateFailure, exit: Int32) {
        self.failure = failure
        exitCode = exit
    }

    var description: String { [failure.title, failure.detail].filter { !$0.isEmpty }.joined(separator: "\n") }

    // MARK: The ones this file raises

    static func busy(_ name: String) -> CreateJobError {
        CreateJobError("E_BUSY", "Winbar is already installing Windows in “\(name)”. It installs one VM at a time.", "",
                       nextStep: "If that run is this terminal's, stop watching it with Ctrl-C first.", exit: 64)
    }

    static let resumeNone = CreateJobError("E_RESUME_NONE", "There's no unfinished install to carry on with.", "", exit: 64)

    static func resumeWhich(_ list: [String]) -> CreateJobError {
        CreateJobError("E_RESUME_WHICH", "Unfinished installs: \(list.joined(separator: ", ")).", "",
                       nextStep: "Name one: winbar create --resume \"NAME\"", exit: 64)
    }

    static func cancelNotOurs(_ name: String) -> CreateJobError {
        CreateJobError("E_CANCEL_NOT_OURS",
                       "winbar create --cancel only deletes VMs it's still installing, and “\(name)” isn't one.",
                       "To delete another VM, use UTM.", exit: 64)
    }

    /// Something Winbar needed wasn't there (UTM, the download, the job's own folder): exit 69.
    static func unavailable(_ code: String, _ title: String, _ detail: String = "", nextStep: String? = nil) -> CreateJobError {
        CreateJobError(code, title, detail, nextStep: nextStep, exit: 69)
    }

    /// Bad input: a VM name UTM has, an unusable ISO, not enough space. Exit 65.
    static func input(_ code: String, _ title: String, _ detail: String = "", nextStep: String? = nil) -> CreateJobError {
        CreateJobError(code, title, detail, nextStep: nextStep, exit: 65)
    }

    /// The install itself failed, stalled past a limit, or finished with problems. Exit 1.
    static func install(_ code: String, _ title: String, _ detail: String = "", nextStep: String? = nil) -> CreateJobError {
        CreateJobError(code, title, detail, nextStep: nextStep, exit: 1)
    }
}

/// A read-only watcher of the job's state, for a front-end that isn't driving it (the menu bar app
/// while the CLI installs, a second `winbar create`). It polls state.json: the file is written
/// atomically, so a reader never sees half of one.
final class CreateJobFollower {
    private let queue = DispatchQueue(label: "net.elusive.winbar.create.follow")
    private var timer: DispatchSourceTimer?
    private var last: CreateJobState?

    fileprivate init(interval: TimeInterval, onChange: @escaping (CreateJobState) -> Void) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let self, let state = CreateJob.current(), state != last else { return }
            last = state
            CreateJob.deliver(state, to: onChange)
        }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
        }
    }

    deinit { stop() }
}

enum CreateJob {
    // MARK: - Public API (what the CLI and the menu bar app call)

    /// Installs Windows into a new VM, following `plan`. Blocking: it returns when the install has
    /// finished, failed or been interrupted, and throws `CreateJobError` in the last two cases.
    ///
    /// `password` is used once, to render the answer file, and then dropped. `onChange` is
    /// called for every state change, on the main queue when the caller isn't already on it (the CLI
    /// blocks the main thread, where a main-queue hop would never arrive).
    static func start(plan: CreatePlan, password: String, onChange: @escaping (CreateJobState) -> Void) throws {
        sweep()
        let lock = try takeLock()
        let run = try CreateRun(plan: plan, id: newJobID(), lock: lock, onChange: onChange)
        try run.install(password: password)
    }

    /// Carries on watching an install that was interrupted (Ctrl-C, a crash, a Mac restart).
    /// `vmName` nil picks the only unfinished job, or refuses when there are several.
    static func resume(vmName: String?, onChange: @escaping (CreateJobState) -> Void) throws {
        sweep()
        let lock = try takeLock()
        let state = try pick(vmName: vmName)
        let run = try CreateRun(resuming: state, lock: lock, onChange: onChange)
        try run.resume()
    }

    /// Stops an install **this process isn't running**: `deleteVM` deletes the VM through UTM
    /// (irreversible; the caller has already asked), otherwise the VM is kept and its install CDs
    /// are taken off it first, so the answer disk with the password never outlives the job.
    ///
    /// It takes the lock, so it only works when nobody is driving the install here or anywhere else
    /// — that is the CLI's `--cancel`, run while the install is unwatched or watched from another
    /// process. **A caller whose own process is running the job (the window's Cancel Install, which
    /// started it with `start`) must use `requestCancel(deleteVM:)` instead**: the lock is held by
    /// this process's run, and `flock` refuses a second holder in the same process just as it
    /// refuses another process, so this would throw `E_BUSY` and do nothing.
    ///
    /// Returns what it actually did, so a caller can say so rather than assume.
    @discardableResult
    static func cancel(vmName: String?, deleteVM: Bool) throws -> CreateCancelResult {
        sweep()
        let lock = try takeLock()
        defer { lock.release() }
        let state = try pick(vmName: vmName, forCancel: true)
        return try CreateRun.cancel(state, deleteVM: deleteVM)
    }

    /// Asks the install **this process is running** to stop (the window's Cancel Install… / Delete
    /// VM…). The run sees the request at its next poll point, does the stop, the delete and the
    /// cleanup itself while it still holds the lock, ends the job `.cancelled` and then throws
    /// `CreateJob.cancelled(_:)` out of `start`/`resume` — so the caller's `start` call returns with
    /// an error whose code is `N_CANCELLED` and whose exit code is 130, like Ctrl-C.
    ///
    /// Returns false when no run in this process is live to hear it, which is the caller's cue to
    /// use `cancel(vmName:deleteVM:)` (or to say nothing happened) rather than assume it worked.
    @discardableResult
    static func requestCancel(deleteVM: Bool) -> Bool {
        cancelRequest.raise(deleteVM: deleteVM)
        guard CreateRun.isRunningHere else {
            cancelRequest.clear()
            return false
        }
        return true
    }

    /// The window's cancel, raised on the run in this process. Not a signal handler, so a plain
    /// queue is safe.
    static let cancelRequest = CancelRequest()

    /// Stops an install whichever way suits, for a caller that doesn't want to know which: if this
    /// process is running it, the run is asked to stop and nil comes back — the cancel happens a
    /// moment later, and the job's next state (`.cancelled`, or `.failed` if the cancel itself
    /// couldn't be done) says how it went. Otherwise the cancel happens here and what it did comes
    /// back. Throws when the cancel couldn't even be started, which the caller should show rather
    /// than swallow: nothing was stopped or deleted in that case.
    @discardableResult
    static func stopInstall(vmName: String?, deleteVM: Bool) throws -> CreateCancelResult? {
        if requestCancel(deleteVM: deleteVM) { return nil }
        return try cancel(vmName: vmName, deleteVM: deleteVM)
    }

    /// The current job as it stands, read from state.json without taking the lock. nil when nothing
    /// is installing. Unfinished jobs win over finished ones, then the most recently updated.
    static func current() -> CreateJobState? {
        let states = allStates()
        return states.first { !$0.isFinished } ?? states.first
    }

    /// Watches state.json for a front-end that isn't driving the job. Call `stop()` when done.
    static func follow(onChange: @escaping (CreateJobState) -> Void) -> CreateJobFollower {
        CreateJobFollower(interval: 1, onChange: onChange)
    }

    /// Destroys the media and state of jobs nothing references any more (D3): the VM was deleted in
    /// UTM, the job finished, or it was abandoned before a VM existed. Cheap and quiet: it asks UTM
    /// for its VMs only when a job claims one, so a launch with nothing to sweep never starts UTM.
    static func sweep() {
        let jobs = SetupMedia.jobs(base: base)
        guard !jobs.isEmpty else { return }
        let lockHeld = !lockIsFree()
        let read = jobs.map { (job: $0, state: state(in: $0.directory), remains: remains(in: $0.directory)) }
        var vmIDs: Set<String>?
        if read.contains(where: { $0.state?.vmID != nil || $0.remains.vmIDHint != nil }),
           case .success(let list) = UTMScripting.listVMs() {
            vmIDs = Set(list.map(\.id))
        }
        let now = Date()
        for (job, state, remains) in read {
            let folderAge = now.timeIntervalSince(modified(job.directory) ?? now)
            guard sweepDecision(state, remains: remains, vmIDs: vmIDs, lockHeld: lockHeld, folderAge: folderAge,
                                now: now) else {
                // Nobody holds the lock, so nobody is watching, whatever the state says.
                if var state, state.watched, !lockHeld {
                    state.watched = false
                    try? writeState(state, in: job.directory)
                }
                continue
            }
            try? SetupMedia.destroy(job.directory, base: base)
        }
    }

    /// What a job folder holds besides a state this Winbar can read: the sweep's fallback evidence.
    struct JobRemains: Equatable {
        /// There is a state.json, but this build can't decode it (hand-edited, truncated by a full
        /// disk, or written by a Winbar whose state has a different shape).
        var unreadableState = false
        /// The VM id read straight out of that undecodable file, when it could still be found: it is
        /// all the sweep needs to ask UTM the usual question.
        var vmIDHint: String?
        /// The setup disk is still in the folder, so some VM may still have it as a CD.
        var hasSetupDisk = false
    }

    static func remains(in directory: URL) -> JobRemains {
        var remains = JobRemains()
        remains.hasSetupDisk = FileManager.default
            .fileExists(atPath: directory.appendingPathComponent(SetupMedia.isoName).path)
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(stateFileName)) else { return remains }
        guard decodeState(data) == nil else { return remains }
        remains.unreadableState = true
        remains.vmIDHint = vmIDHint(data)
        return remains
    }

    /// The `vmID` of a state.json this build can't decode. A state that grew a field, or a stage
    /// name this Winbar doesn't know, still answers the only question the sweep has to ask.
    static func vmIDHint(_ data: Data) -> String? {
        let object = try? JSONSerialization.jsonObject(with: data)
        guard let id = (object as? [String: Any])?["vmID"] as? String, !id.isEmpty else { return nil }
        return id
    }

    /// Whether a job folder can go. Pure, so the rule can be tested without UTM or a clock.
    ///
    /// - `vmIDs` nil: UTM wasn't asked or couldn't answer, so no job that claims a VM is touched.
    /// - A job someone is watching is never touched, whatever it says.
    /// - A folder with no readable state, or one abandoned before its VM existed, has to be stale
    ///   first: another process may have made it seconds ago and not written state.json yet.
    /// - A state.json that won't decode is a job all the same: its VM id decides where one can still
    ///   be read, and where it can't, a folder that still holds the setup disk is left alone. That
    ///   rule is absolute — the answer ISO is never deleted while a VM still references it,
    ///   and a VM whose CD image has gone won't start at all.
    static func sweepDecision(_ state: CreateJobState?, remains: JobRemains = JobRemains(), vmIDs: Set<String>?,
                              lockHeld: Bool, folderAge: TimeInterval, now: Date) -> Bool {
        guard let state else {
            guard !lockHeld, folderAge > staleAge else { return false }
            guard remains.unreadableState else { return true }
            if let hint = remains.vmIDHint { return vmIDs.map { !$0.contains(hint) } ?? false }
            return !remains.hasSetupDisk
        }
        if state.watched && lockHeld { return false }
        // UTM says the job's VM has gone, so nothing references its setup disk any more (D3).
        if let vmIDs, let vmID = state.vmID, !vmIDs.contains(vmID) { return true }
        // The job is over and its setup disk has already been deleted: only state.json is left, kept
        // this long so a front-end polling once a second still saw how the job ended. A failure the
        // person can still resume keeps its folder exactly as a running job does, which is why this
        // asks `isSpent` and not `isFinished`.
        if state.isSpent, state.mediaDir == nil { return true }
        // Unfinished on paper, but with no setup disk and nothing to carry on from: a run killed
        // between deleting the disk and saving its ending. Nobody can ever use this again, so it
        // goes once it has sat still — otherwise it is a job the menu bar keeps trying to resume.
        if !state.isResumable, state.mediaDir == nil {
            return !lockHeld && now.timeIntervalSince(state.updatedAt) > staleAge
        }
        guard state.vmID != nil else {
            return !lockHeld && now.timeIntervalSince(state.updatedAt) > staleAge
        }
        return false
    }

    /// How long a job with no VM (or no readable state) must have sat still before the sweep takes it.
    static let staleAge: TimeInterval = 60 * 60

    // MARK: - The job's files

    /// `~/Library/Application Support/Winbar/Create`, the same base the media builder uses.
    static var base: URL { SetupMedia.defaultBase }

    static let stateFileName = "state.json"

    /// A job id: a folder name (SetupMedia's rules) that says when the job started, so the folders
    /// sort by age and a person can tell them apart. The VM's UTM id is recorded inside state.json
    /// instead of naming the folder: UTM holds a bookmark to the setup disk in here from the moment
    /// the VM is created, so the folder must never be renamed.
    static func newJobID(now: Date = Date()) -> String {
        let stamp = DateFormatter.jobStamp.string(from: now)
        return "create-\(stamp)-\(UUID().uuidString.prefix(8).lowercased())"
    }

    /// Where a job's files are: `<base>/<id>.noindex`, named when the job was made and never renamed
    /// (UTM keeps a bookmark into it). `mediaDir` says the same thing while there is still a setup
    /// disk in there; this also answers once that has gone.
    static func directory(of state: CreateJobState) -> URL {
        state.mediaDir.map { URL(fileURLWithPath: $0) }
            ?? base.appendingPathComponent(state.id + SetupMedia.suffix, isDirectory: true)
    }

    /// The state of the job in `directory`, or nil when there is none, it can't be read, or it was
    /// written only half way (a crash mid-write; the writer renames into place, so this is rare).
    static func state(in directory: URL) -> CreateJobState? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(stateFileName)) else { return nil }
        return decodeState(data)
    }

    static func decodeState(_ data: Data) -> CreateJobState? {
        try? JSONDecoder.job.decode(CreateJobState.self, from: data)
    }

    static func encodeState(_ state: CreateJobState) throws -> Data {
        try JSONEncoder.job.encode(state)
    }

    /// Writes state.json where a reader can only ever see a whole one: a private temporary file in
    /// the same folder, renamed over the old one.
    static func writeState(_ state: CreateJobState, in directory: URL) throws {
        let data = try encodeState(state)
        let file = directory.appendingPathComponent(stateFileName)
        let temporary = directory.appendingPathComponent(stateFileName + ".tmp")
        try? FileManager.default.removeItem(at: temporary)
        try SetupMedia.writePrivate(data, to: temporary)
        guard rename(temporary.path, file.path) == 0 else {
            let reason = String(cString: strerror(errno))
            try? FileManager.default.removeItem(at: temporary)
            throw CreateJobError.unavailable("E_STATE", "Couldn't record the install's state", "\(file.path): \(reason)")
        }
    }

    /// Every job's state, newest first.
    static func allStates() -> [CreateJobState] {
        SetupMedia.jobs(base: base).compactMap { state(in: $0.directory) }.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Deletes the setup disk — and everything else the job wrote — but keeps the folder, its marker
    /// and state.json.
    ///
    /// The disk holding the password has to go the moment nothing references it, while the
    /// state saying how the job ended has to stay readable long enough for a front-end polling once a
    /// second to see it: destroying the whole folder in one step loses `.done` and `.cancelled`
    /// almost every time, and a menu bar that never learns the job ended goes on offering nothing.
    /// The empty folder is the sweep's to take (`isSpent`).
    ///
    /// Refuses any folder `SetupMedia.create` didn't make, and won't delete under a live mount, the
    /// same way `SetupMedia.destroy` does.
    static func emptyFolder(_ directory: URL, base: URL = base) throws {
        if let reason = SetupMedia.ownershipProblem(directory, base: base) {
            throw SetupMediaError.notOurs(path: directory.path, reason: reason)
        }
        for mount in DiskImage.mounts(under: directory.path) { _ = DiskImage.eject(mount.device) }
        if let mount = DiskImage.mounts(under: directory.path).first {
            throw SetupMediaError.stillMounted(mountPoint: mount.mountPoint, device: mount.device)
        }
        let keep: Set<String> = [stateFileName, SetupMedia.marker]
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where !keep.contains(name) {
            do { try FileManager.default.removeItem(at: directory.appendingPathComponent(name)) } catch {
                throw SetupMediaError.io("\(directory.appendingPathComponent(name).path): \(error.localizedDescription)")
            }
        }
    }

    /// The job `--resume`/`--cancel` means. A name must match an open job's VM; without one, the
    /// only open job is used. "Open" is `isResumable` for a resume — a job that failed with the VM
    /// still installing is exactly what Try Again and `--resume` are for — and `canBeCancelled` for
    /// a cancel, which also covers a job abandoned before its VM existed.
    static func pick(vmName: String?, forCancel: Bool = false) throws -> CreateJobState {
        let unfinished = allStates().filter { forCancel ? $0.canBeCancelled : $0.isResumable }
        if let vmName {
            guard let match = unfinished.first(where: { $0.plan.vmName.compare(vmName, options: .caseInsensitive) == .orderedSame })
            else { throw forCancel ? CreateJobError.cancelNotOurs(vmName) : CreateJobError.resumeNone }
            return match
        }
        guard let only = unfinished.first else { throw CreateJobError.resumeNone }
        guard unfinished.count == 1 else { throw CreateJobError.resumeWhich(unfinished.map(describe)) }
        return only
    }

    /// “Windows 11” (copying files, started 17:02) — the list E_RESUME_WHICH shows.
    static func describe(_ state: CreateJobState) -> String {
        "“\(state.plan.vmName)” (\(state.stage.shortTitle), started \(DateFormatter.clock.string(from: state.startedAt)))"
    }

    // MARK: - The lock (one install at a time)

    /// `~/Library/Application Support/Winbar/Create/.lock`, held with `flock` for as long as a
    /// process is driving an install. A holder that dies loses it, which is the whole point: the
    /// menu bar app (or `--resume`) can then pick the job up.
    static var lockURL: URL { base.appendingPathComponent(".lock") }

    static func takeLock() throws -> CreateLock {
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        guard let lock = CreateLock(url: lockURL) else {
            let name = current()?.plan.vmName ?? Config.vmName ?? "another VM"
            throw CreateJobError.busy(name)
        }
        return lock
    }

    /// Whether nobody holds the lock right now. Used by the sweep, which must not disturb a job
    /// somebody else is driving.
    static func lockIsFree() -> Bool {
        guard let probe = CreateLock(url: lockURL) else { return false }
        probe.release()
        return true
    }

    // MARK: - Delivering state

    /// The app watches from the main queue; the CLI blocks the main thread, so hopping there would
    /// never arrive. Deliver directly when this already is the main thread.
    static func deliver(_ state: CreateJobState, to onChange: @escaping (CreateJobState) -> Void) {
        if Thread.isMainThread {
            onChange(state)
        } else {
            DispatchQueue.main.async { onChange(state) }
        }
    }

    private static func modified(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}

/// An exclusive `flock` on the Create folder's `.lock`. Advisory, per open file description: two
/// tries in one process conflict just as two processes do, which is what makes it testable.
final class CreateLock {
    private var fd: Int32

    /// nil when someone else holds it.
    init?(url: URL) {
        let file = open(url.path, O_RDWR | O_CREAT, 0o600)
        guard file >= 0 else { return nil }
        guard flock(file, LOCK_EX | LOCK_NB) == 0 else {
            close(file)
            return nil
        }
        fd = file
    }

    func release() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }

    deinit { release() }
}

/// The create log: `~/Library/Logs/Winbar/create-{VM name}-{yyyymmdd-HHmm}.log`, kept afterwards and
/// quoted by failures. It holds stages, warnings, what UTM and Windows said, and Windows' own
/// first-logon log pulled at the end. Never the password: nothing writes user input here, and the
/// tests scan a rendered log for a canary to prove it.
final class CreateLog {
    let url: URL
    /// The serial console's own log, beside it (firmware text and the keys Winbar typed).
    var serialURL: URL { url.deletingPathExtension().appendingPathExtension("serial.log") }
    private let handle: FileHandle?
    private let queue = DispatchQueue(label: "net.elusive.winbar.create.log")

    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Winbar", isDirectory: true)
    }

    static func fileName(vmName: String, at date: Date) -> String {
        // The VM name can't hold "/" or ":" (CreateChoices), so it's safe in a file name as it is.
        "create-\(vmName)-\(DateFormatter.logStamp.string(from: date)).log"
    }

    /// Opens (or reopens, after a resume) the log at `url`.
    init(url: URL) {
        self.url = url
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        handle = fd >= 0 ? FileHandle(fileDescriptor: fd, closeOnDealloc: true) : nil
    }

    convenience init(vmName: String, at date: Date = Date(), directory: URL = CreateLog.directory) {
        self.init(url: directory.appendingPathComponent(CreateLog.fileName(vmName: vmName, at: date)))
    }

    func write(_ line: String) {
        let stamped = DateFormatter.logLine.string(from: Date()) + "  " + line + "\n"
        queue.sync { try? handle?.write(contentsOf: Data(stamped.utf8)) }
    }

    /// A block of someone else's text (Windows' first-logon log, a UTM error), indented so it can't
    /// be mistaken for Winbar's own lines.
    func writeBlock(_ title: String, _ text: String) {
        write(title)
        let body = text.split(separator: "\n", omittingEmptySubsequences: false).map { "    " + $0 }.joined(separator: "\n")
        queue.sync { try? handle?.write(contentsOf: Data((body + "\n").utf8)) }
    }
}

/// Keeps the Mac awake while Windows installs: a PreventUserIdleSystemSleep assertion, named for the
/// VM. Closing a laptop's lid still sleeps it, which is why the copy says so.
///
/// `ProcessInfo.beginActivity` with `.idleSystemSleepDisabled` is Foundation's wrapper around exactly
/// that assertion, and needs no extra framework.
final class SleepAssertion {
    private var token: NSObjectProtocol?

    init(reason: String) {
        token = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .suddenTerminationDisabled],
                                                      reason: reason)
    }

    func release() {
        if let token { ProcessInfo.processInfo.endActivity(token) }
        token = nil
    }

    deinit { release() }
}

// MARK: - Stage copy, shared by the CLI, the window and the log

extension CreateStage {
    /// The stage's title while it runs.
    var runningTitle: String {
        switch self {
        case .check: return "Checking the ISO and UTM"
        case .guestTools: return "Getting UTM Guest Tools \(GuestTools.version)"
        case .media: return "Making the setup disk"
        case .vm: return "Creating the VM in UTM"
        case .boot: return "Starting the Windows installer"
        case .copy: return "Windows Setup: copying files"
        case .devices: return "Windows Setup: setting up devices"
        case .oobe: return "Windows Setup: getting ready"
        case .firstLogon: return "Installing UTM Guest Tools and applying your choices"
        case .finish: return "Removing the install disks and restarting Windows"
        }
    }

    /// The stage's title once it is done.
    var doneTitle: String {
        switch self {
        case .check: return "Checked the ISO and UTM"
        case .guestTools: return "Got UTM Guest Tools \(GuestTools.version)"
        case .media: return "Made the setup disk"
        case .vm: return "Created the VM in UTM"
        case .boot: return "Started the Windows installer"
        case .copy: return "Windows Setup copied its files"
        case .devices: return "Windows Setup set up devices"
        case .oobe: return "Windows Setup got Windows ready"
        case .firstLogon: return "Installed UTM Guest Tools and applied your choices"
        case .finish: return "Removed the install disks and restarted Windows"
        }
    }

    /// The stage shorts: the menu bar's status line, the CLI's heartbeat ("still copying
    /// files") and the list E_RESUME_WHICH prints ("“Windows 11” (copying files, started 17:02)").
    var shortTitle: String {
        switch self {
        case .check: return "checking the ISO and UTM"
        case .guestTools: return "getting Guest Tools"
        case .media: return "making the setup disk"
        case .vm: return "creating the VM"
        case .boot: return "starting the installer"
        case .copy: return "copying files"
        case .devices: return "setting up devices"
        case .oobe: return "getting ready"
        case .firstLogon: return "applying your choices"
        case .finish: return "finishing"
        }
    }

    /// The stages where the VM is installing: the install limits apply, and Ctrl-C leaves Windows
    /// installing instead of cleaning up.
    var isInstalling: Bool { number >= CreateStage.boot.number }
}

// MARK: - Small shared helpers

extension DateFormatter {
    /// 20260919-1702, for the log's name.
    static let logStamp: DateFormatter = fixed("yyyyMMdd-HHmm")
    /// 20260919-170211, for a job folder's name.
    static let jobStamp: DateFormatter = fixed("yyyyMMdd-HHmmss")
    /// 17:02, for "started 17:02".
    static let clock: DateFormatter = fixed("HH:mm")
    /// 2026-09-19 17:02:11, the log's and the no-terminal output's stamp.
    static let logLine: DateFormatter = fixed("yyyy-MM-dd HH:mm:ss")

    private static func fixed(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }
}

extension JSONEncoder {
    /// ISO-8601 dates and sorted keys: state.json is read by people in bug reports.
    static let job: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
}

extension JSONDecoder {
    static let job: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
