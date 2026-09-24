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

    var symbol: String { symbol(color: Term.color) }

    /// The symbol itself never changes; only whether it is coloured. A row bound for a file (see
    /// `winbar diagnose`) asks for no colour, and reads the same ✓ / ! / ? / · / ✗ as the terminal.
    func symbol(color: Bool) -> String {
        switch self {
        case .ok: return Term.paint("✓", .green, if: color)
        case .fixable: return Term.paint("!", .yellow, if: color)
        case .manual: return Term.paint("?", .cyan, if: color)
        case .info: return Term.paint("·", .dim, if: color)
        case .error: return Term.paint("✗", .red, if: color)
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
        /// Whether the self-test behind C3 and C4 probes the Remote Desktop port. doctor and
        /// diagnose report the answer; the setup window leaves the port alone
        /// (`SetupRunner.contextOptions`).
        var selfTestProbesPort = true
        /// A problem report's run (`Diagnose.doctorOptions`): it asks everything doctor asks and
        /// writes nothing doctor writes. Report a Problem… is allowed beside a set-up step or an
        /// install (`AppWorkGate.Owner.report`), and doctor writes what it learns into the very
        /// settings a step writes from what it has just done — the saved PC (C2), BitLocker's state
        /// and the password probe's result (the survey), the folder UTM shares, Time Machine's answer
        /// (H6). A report that read Windows App's list a moment before the wizard saved a PC would
        /// write that stale answer back over the new one, and Connect would open a one-off
        /// connection instead. For the same reason the survey keeps out of the files a step uses
        /// (`surveyTraces`).
        var readOnly = false
        /// Told of every saved-PC lookup (C2), on the thread running the checks. A problem report
        /// keeps them (`Diagnose.Sightings`) to mask the names C2's row prints: its own run writes
        /// no setting, and when the table misses its deadline this Context is still busy on another
        /// thread and nobody's to read.
        var sawSavedPCs: ((WindowsAppBookmarks.Lookup) -> Void)?
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
    var vmID: String?

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

    /// Where a fact that takes a while says so ("Asking Windows…"). A window has no terminal to write
    /// to, so it passes its own; everything else gets `toTerminal`, which is what this always did.
    let progress: (String) -> Void

    init(options: Options, progress: @escaping (String) -> Void = Context.toTerminal) {
        self.options = options
        self.progress = progress
        vmName = options.vmOverride ?? Config.vmName
        vmID = vmName == Config.vmName ? Config.vmID : nil
    }

    /// The long-lived window must follow selection changes made by the menu or another process.
    /// This is local bookkeeping only: it never asks UTM or writes settings.
    @discardableResult
    func adoptSelection(name: String?, id: String?) -> Bool {
        guard vmName != name || vmID != id else { return false }
        vmName = name
        vmID = id
        pending = ConfigChanges()
        refreshAll()
        return true
    }

    /// The terminal's progress: a dim note on stderr, and only while stdout is a terminal, exactly as the
    /// survey always did it. A doctor run piped into something else doesn't get it.
    static func toTerminal(_ line: String) {
        if Term.stdoutIsTTY { Term.note(line) }
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
        return list.first { $0.name == vmName && (vmID == nil || vmID == $0.id) }
    }

    /// Live, and cheap: a process-table scan.
    var process: VMProcess? { VMProcesses.find(vmName, id: vmID) }

    private var cachedCtl: UTM.CtlAnswer?

    /// Whether utmctl answers this process at all (H9). Probed once per run like every other fact:
    /// the probe is a second when it works, and twenty when it doesn't.
    var utmctl: UTM.CtlAnswer {
        if let cachedCtl { return cachedCtl }
        let answer = UTM.isInstalled ? UTM.ctlAnswers() : .failed("UTM isn't installed")
        cachedCtl = answer
        return answer
    }

    /// Takes utmctl's answer from someone who has just asked (`UTMFirstUse.settle`, the setup
    /// window's **Open UTM and Ask**), so H9 reads it instead of asking again: a utmctl that said
    /// nothing for a minute would say nothing for another twenty seconds.
    func noteUTMCtl(_ answer: UTM.CtlAnswer) {
        cachedCtl = answer
        statuses.removeAll()
    }

    /// Windows QEMU VMs to offer when none is configured; any QEMU VM if none says it's Windows.
    var candidates: [VMInfo] {
        guard case .success(let list) = vms else { return [] }
        return Context.candidates(in: list)
    }

    /// The rule itself, pure, so the wizard's VM step (`SetupFlow.choice(in:)`) adopts the same VM
    /// `winbar setup` would. Any QEMU VM when none says it's Windows: a VM made by hand in UTM can
    /// have its generic icon, and `VMInfo.isWindows` reads nothing else.
    static func candidates(in list: [VMInfo]) -> [VMInfo] {
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
            if !options.readOnly { Config.rememberSharedFolder(path, for: vmName) }
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

    /// The files a survey leaves while it runs: the shared folder's marker, by this name, and — when
    /// `asksSession` — the helper that asks the person's own session about their drive letter, which
    /// has one fixed path in Windows. A read-only run (a problem report) uses a marker of its own and
    /// doesn't ask, so it can't delete a set-up step's files from under it or have its token read as
    /// the step's; its G11 row then leaves the drive letter unchecked. Pure.
    static func surveyTraces(readOnly: Bool) -> (marker: String, asksSession: Bool) {
        readOnly ? (SharedFolder.reportMarkerName, false) : (SharedFolder.markerName, true)
    }

    private func surveyGuest() -> GuestState {
        guard let vmName, vm != nil else { return .notConfigured }
        guard process != nil else { return .stopped }
        guard UTM.guestAgentAnswers(vmName) else { return .noAgent }
        progress(SetupCopy.Tune.askingWindows)
        let traces = Context.surveyTraces(readOnly: options.readOnly)
        // A marker in the shared folder, for as long as the survey takes: UTM gives Windows the folder
        // its registry held at the previous start, so without it the survey can't tell "Windows has
        // this folder" from "Windows still has the one before" (see SharedFolder).
        var markerFolder: String?
        if case .success(let folder?) = sharedFolder, SharedFolder.inspect(folder) == .folder {
            sharedFolderMarker = SharedFolder.writeMarker(in: folder, named: traces.marker)
            if sharedFolderMarker != nil { markerFolder = folder }
        }
        defer { if let markerFolder { SharedFolder.removeMarker(in: markerFolder, named: traces.marker) } }
        // The piece that asks the person's own session about their drive letter is a file of its own.
        let asksSession = markerFolder != nil && traces.asksSession
        if asksSession {
            GuestAgent.push(vm: vmName, path: GuestScripts.userDrivePath, text: GuestScripts.userDriveChild)
        }
        defer { if asksSession { GuestAgent.remove(vm: vmName, path: GuestScripts.userDrivePath) } }
        // The password cache is keyed by the guest's own COMPUTER\user, so it applies whichever VM this is.
        let script = GuestScripts.survey(user: isConfiguredVM ? Config.rdpUser : nil,
                                         passwordChecked: Config.passwordCheckedFor,
                                         marker: sharedFolderMarker == nil ? "" : traces.marker,
                                         userDrive: asksSession)
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
    var isConfiguredVM: Bool { vmName != nil && vmName == Config.vmName && vmID == Config.vmID }

    /// This VM's MAC: UTM's answer, else its running process's, else what was remembered — and that
    /// last one only when these settings are this VM's. Another VM's MAC finds another VM's DHCP
    /// lease, which is the address the certificate is made for and Connect goes to.
    var vmMAC: String? { vm?.mac ?? process?.mac ?? (isConfiguredVM ? Config.vmMAC : nil) }

    /// Whether the VM was last seen with a console window, for when neither UTM nor a running
    /// process says. Nothing for a VM these settings don't describe.
    var consoleEnabled: Bool? { isConfiguredVM ? Config.consoleEnabled : nil }

    /// The Windows user these settings name, and only when they name this VM's. What a guest script
    /// means by "the account Winbar was told about"; unlike `rdpUser` it doesn't fall back to
    /// whoever is signed in, because a script that acts on the wrong account is worse than one that
    /// acts on the default.
    var configuredUser: String? { isConfiguredVM ? Config.rdpUser : nil }

    /// Caches worth keeping between runs, taken from a fresh survey. None from a problem report's
    /// (`Options.readOnly`). Its password probe, when it makes one, then isn't remembered, so the next
    /// doctor may probe once more — but the survey never probes while a failed sign-in still counts
    /// (G5 "deferred"), so that can't add up towards Windows' lockout.
    private func remember(_ output: GuestOutput) {
        guard !options.readOnly else { return }
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
        guard let vmName, isConfiguredVM else { return }
        if let state = BitLockerState(output) { Config.recordBitLocker(on: !state.decrypted, for: vmName) }
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

    private var cachedSavedPC: Result<WindowsAppBookmarks.Lookup, WindowsAppBookmarks.Failure>?

    /// The saved PCs Windows App has for `host`, sorted into this VM's (signing in as `user`) and
    /// another account's, asked of Windows App itself — the one way past the TCC wall around its
    /// container, since the app reads its own data out for us. Cached like every other fact here:
    /// the lookup runs Windows App's binary once for the list and once per saved PC it has to read.
    func savedPC(for host: String, user: String?) -> Result<WindowsAppBookmarks.Lookup, WindowsAppBookmarks.Failure> {
        if let cachedSavedPC { return cachedSavedPC }
        return note(savedPCs: Result { try WindowsAppBookmarks.savedPC(for: host, user: user) }
            .mapError { error in
                error as? WindowsAppBookmarks.Failure
                    ?? .failed(what: "list its saved PCs", output: "\(error)")
            })
    }

    /// Keeps a lookup's answer for the rest of the run, and tells `Options.sawSavedPCs` about it.
    @discardableResult
    func note(savedPCs result: Result<WindowsAppBookmarks.Lookup, WindowsAppBookmarks.Failure>)
        -> Result<WindowsAppBookmarks.Lookup, WindowsAppBookmarks.Failure> {
        cachedSavedPC = result
        if case .success(let lookup) = result { options.sawSavedPCs?(lookup) }
        return result
    }

    // MARK: The app's own view (self-test)

    private var cachedSelfTest: Result<[String: String], WinbarError>?

    var selfTest: Result<[String: String], WinbarError> {
        if let cachedSelfTest { return cachedSelfTest }
        let result = SelfTest.launchAsApp(extraArguments: SelfTest.arguments(probingPort: options.selfTestProbesPort))
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
            cachedCtl = nil
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
        cachedCtl = nil
        cachedGuest = nil
        cachedSelfTest = nil
        cachedSavedPC = nil
        statuses.removeAll()
    }

    func refreshGuest() {
        cachedGuest = nil
        statuses.removeAll()
    }

    /// Forgets what utmctl said and UTM's VM list, and nothing else: the setup window's look after an
    /// Automation switch was turned on, or a VM was made in UTM (`SetupRunner.Forget.utm`).
    func forgetUTM() {
        cachedCtl = nil
        cachedVMs = nil
        statuses.removeAll()
    }

    /// Forgets the self-test behind C3 and C4, and nothing else: the setup window's look after
    /// Accessibility was turned on for Winbar (`SetupRunner.Forget.selfTest`). Not `refresh(after:)`
    /// for C3, which drops every client fact and so Windows App's saved-PC lookup with it.
    func forgetSelfTest() {
        cachedSelfTest = nil
        statuses.removeAll()
    }

    /// Re-evaluates every check from the facts already fetched. Cheap: no survey, no AppleScript.
    func forgetStatuses() {
        statuses.removeAll()
    }
}
