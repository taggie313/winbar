import Foundation

/// One line of the recipe: something doctor can evaluate and setup may fix or walk someone through.
struct Check {
    enum Section: String, CaseIterable { case host = "Host", guest = "Guest", client = "Client" }

    let id: String
    let section: Section
    let title: String
    /// Why this matters, shown for anything that isn't ok.
    let why: String
    /// Changes the VM's configuration, so setup batches it into the single restart.
    var needsRestart = false
    let evaluate: (Context) -> Status
    /// For `needsRestart` checks this only stages the change into `Context.pending`.
    var apply: ((Context) -> Result<Void, WinbarError>)?
    /// For manual steps: opens the right window so the person can do their part.
    var guide: ((Context) -> Void)?
    /// For manual steps nothing can verify (a saved PC in Windows App, a Time Machine exclusion
    /// without Full Disk Access): records the person's word.
    var recordDone: ((Context) -> Void)?
}

enum Status {
    case ok(String)
    case fixable(String)
    case manual(String, how: String)
    case info(String)
    case error(String)

    var symbol: String {
        switch self {
        case .ok: return Term.paint("✓", .green)
        case .fixable: return Term.paint("!", .yellow)
        case .manual: return Term.paint("?", .cyan)
        case .info: return Term.paint("·", .dim)
        case .error: return Term.paint("✗", .red)
        }
    }

    var detail: String {
        switch self {
        case .ok(let d), .fixable(let d), .manual(let d, _), .info(let d), .error(let d): return d
        }
    }

    var isOK: Bool { if case .ok = self { return true } else { return false } }
    var isFixable: Bool { if case .fixable = self { return true } else { return false } }
    var isManual: Bool { if case .manual = self { return true } else { return false } }

    /// Anything that keeps doctor from exiting 0.
    var needsAttention: Bool {
        switch self {
        case .fixable, .manual, .error: return true
        case .ok, .info: return false
        }
    }
}

/// What a doctor or setup run knows. Facts are fetched lazily and once, because each costs real time
/// (an AppleScript round trip to UTM, a guest script, launching the app for its self-test), and
/// dropped again when a fix changes them.
final class Context {
    struct Options {
        var vmOverride: String?
        var assumeYes = false
        var noVisualTweaks = false
        var keepBitLocker = false
        var display: UTMScripting.DisplayMode?
    }

    enum GuestState {
        case notConfigured
        case stopped
        case noAgent
        case failed(WinbarError)
        case ready(GuestOutput)
    }

    let options: Options
    var vmName: String?

    /// This run's flag, or the choice remembered for the configured VM (setup saves them).
    var keepBitLocker: Bool { options.keepBitLocker || (isConfiguredVM && Config.keepBitLocker) }
    var noVisualTweaks: Bool { options.noVisualTweaks || (isConfiguredVM && Config.noVisualTweaks) }
    /// Rows `winbar create`'s checklist was left unticked for this VM: setup says so once
    /// rather than offering them again on every run.
    var declinedAutologon: Bool { isConfiguredVM && Config.declinedAutologon }
    var declinedRemoteDesktop: Bool { isConfiguredVM && Config.declinedRemoteDesktop }
    var declinedTuning: Bool { isConfiguredVM && Config.declinedTuning }
    /// Staged configuration changes (vCPUs, RAM, display) awaiting setup's single restart.
    var pending = ConfigChanges()

    init(options: Options) {
        self.options = options
        vmName = options.vmOverride ?? Config.vmName
    }

    // MARK: UTM

    private var cachedVMs: Result<[VMInfo], WinbarError>?

    var vms: Result<[VMInfo], WinbarError> {
        if let cachedVMs { return cachedVMs }
        let result = UTM.isInstalled ? UTMScripting.listVMs() : .failure(WinbarError("UTM isn't installed"))
        cachedVMs = result
        return result
    }

    var vm: VMInfo? {
        guard let vmName, case .success(let list) = vms else { return nil }
        return list.first { $0.name == vmName }
    }

    /// Live, and cheap: a process-table scan.
    var process: VMProcess? { VMProcesses.find(vmName) }

    /// Windows QEMU VMs to offer when none is configured; any QEMU VM if none says it's Windows.
    var candidates: [VMInfo] {
        guard case .success(let list) = vms else { return [] }
        let qemu = list.filter { $0.backend == "qemu" }
        let windows = qemu.filter(\.isWindows)
        return windows.isEmpty ? qemu : windows
    }

    // MARK: The shared folder

    private var cachedSharedFolder: Result<String?, WinbarError>?

    /// What the marker file held while the last survey ran, so G11 can tell which folder Windows is
    /// actually serving. nil when there was no folder to mark, or it couldn't be written.
    private(set) var sharedFolderMarker: String?

    /// The folder UTM shares with this VM, straight from UTM (one AppleScript round trip, cached like
    /// every other fact here). Works while the VM is stopped, which is when it can be changed.
    var sharedFolder: Result<String?, WinbarError> {
        if let cachedSharedFolder { return cachedSharedFolder }
        guard let vmName, vm != nil else { return .success(nil) }
        let result = SharedFolder.current(vm: vmName).map { path -> String? in
            Config.rememberSharedFolder(path, for: vmName)
            return path
        }
        cachedSharedFolder = result
        return result
    }

    // MARK: Guest

    private var cachedGuest: GuestState?

    var guest: GuestState {
        if let cachedGuest { return cachedGuest }
        let state = surveyGuest()
        cachedGuest = state
        return state
    }

    var guestOutput: GuestOutput? {
        if case .ready(let output) = guest { return output }
        return nil
    }

    private func surveyGuest() -> GuestState {
        guard let vmName, vm != nil else { return .notConfigured }
        guard process != nil else { return .stopped }
        guard UTM.guestAgentAnswers(vmName) else { return .noAgent }
        if Term.stdoutIsTTY { Term.note("Asking Windows (this takes a few seconds)…") }
        // A marker in the shared folder, for as long as the survey takes: UTM gives Windows the folder
        // its registry held at the previous start, so without it the survey can't tell "Windows has
        // this folder" from "Windows still has the one before" (see SharedFolder).
        var markerFolder: String?
        if case .success(let folder?) = sharedFolder, SharedFolder.inspect(folder) == .folder {
            sharedFolderMarker = SharedFolder.writeMarker(in: folder)
            if sharedFolderMarker != nil { markerFolder = folder }
        }
        defer { if let markerFolder { SharedFolder.removeMarker(in: markerFolder) } }
        // The password cache is keyed by the guest's own COMPUTER\user, so it applies whichever VM this is.
        let script = GuestScripts.survey(user: isConfiguredVM ? Config.rdpUser : nil,
                                         passwordChecked: Config.passwordCheckedFor,
                                         marker: sharedFolderMarker == nil ? "" : SharedFolder.markerName)
        switch GuestAgent.run(vm: vmName, script, timeout: 180) {
        case .failure(let error):
            return .failed(error)
        case .success(let output):
            if let error = output.error { return .failed(WinbarError("The Windows survey failed", error)) }
            remember(output)
            return .ready(output)
        }
    }

    /// Whether the settings in Config describe this run's VM (`doctor --vm` can point elsewhere).
    var isConfiguredVM: Bool { vmName != nil && vmName == Config.vmName }

    /// Caches worth keeping between runs, taken from a fresh survey.
    private func remember(_ output: GuestOutput) {
        // Every probe that found a password is remembered, for any VM: each one was a failed logon.
        if let computer = output["COMPUTERNAME"], let user = output["USER"], !user.isEmpty {
            let key = computer + "\\" + user
            switch output["G5_LOGON"] {
            case "1326":        // wrong password: it has one
                Config.passwordCheckedFor = Config.updatePasswordChecked(Config.passwordCheckedFor, key: key, hasPassword: true)
            case "ok", "1327":  // blank: check again next time
                Config.passwordCheckedFor = Config.updatePasswordChecked(Config.passwordCheckedFor, key: key, hasPassword: false)
            default: break
            }
        }
        guard isConfiguredVM else { return }
        if let state = BitLockerState(output) { Config.recordBitLocker(on: !state.decrypted) }
    }

    /// `<DNS host name>.local` unless configured otherwise.
    var rdpHost: String? {
        if isConfiguredVM, let configured = Config.rdpHost { return configured }
        return guestOutput?.defaultRDPHost
    }

    /// The configured user, else the owner of the guest's desktop session.
    var rdpUser: String? {
        if isConfiguredVM, let configured = Config.rdpUser { return configured }
        guard let user = guestOutput?["USER"], !user.isEmpty else { return nil }
        return user
    }

    // MARK: Windows App's saved PCs

    private var cachedSavedPC: Result<WindowsAppBookmarks.Bookmark?, WindowsAppBookmarks.Failure>?

    /// The saved PC Windows App has for `host`, asked of Windows App itself — the one way past the
    /// TCC wall around its container, since the app reads its own data out for us. Cached like every
    /// other fact here: the lookup runs Windows App's binary once for the list and once per saved PC
    /// it has to read the host of.
    func savedPC(for host: String) -> Result<WindowsAppBookmarks.Bookmark?, WindowsAppBookmarks.Failure> {
        if let cachedSavedPC { return cachedSavedPC }
        let result = Result { try WindowsAppBookmarks.savedPC(for: host) }
            .mapError { error in
                error as? WindowsAppBookmarks.Failure
                    ?? .failed(what: "list its saved PCs", output: "\(error)")
            }
        cachedSavedPC = result
        return result
    }

    // MARK: The app's own view (self-test)

    private var cachedSelfTest: Result<[String: String], WinbarError>?

    var selfTest: Result<[String: String], WinbarError> {
        if let cachedSelfTest { return cachedSelfTest }
        let result = SelfTest.launchAsApp()
        cachedSelfTest = result
        return result
    }

    // MARK: Status cache

    private var statuses: [String: Status] = [:]

    func status(of check: Check) -> Status {
        if let known = statuses[check.id] { return known }
        let status = check.evaluate(self)
        statuses[check.id] = status
        return status
    }

    func status(of id: String) -> Status? {
        Recipe.check(id).map { status(of: $0) }
    }

    /// Forgets whatever `check`'s fix or manual step may have changed.
    func refresh(after check: Check) {
        switch check.section {
        case .host:
            cachedVMs = nil
            cachedSharedFolder = nil
        case .guest: cachedGuest = nil
        case .client:
            cachedSelfTest = nil
            cachedSavedPC = nil
        }
        statuses.removeAll()
    }

    func refreshAll() {
        cachedVMs = nil
        cachedSharedFolder = nil
        cachedGuest = nil
        cachedSelfTest = nil
        cachedSavedPC = nil
        statuses.removeAll()
    }

    func refreshGuest() {
        cachedGuest = nil
        statuses.removeAll()
    }

    /// Re-evaluates every check from the facts already fetched. Cheap: no survey, no AppleScript.
    func forgetStatuses() {
        statuses.removeAll()
    }
}
