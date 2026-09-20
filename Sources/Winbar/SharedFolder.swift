import Foundation

/// The folder the Mac and Windows share, and how Windows reaches it.
///
/// UTM has exactly one way to set it from outside: `update registry <vm> with {POSIX file …}`, whose
/// own dictionary says "Currently you can only change the shared directory with this!". The matching
/// `registry` property reads back what is set — no path, or one.
///
/// Two things about it were measured on UTM 4.7.5 with Windows 11 25H2 ARM64, and everything here
/// is built around them:
///
/// - It has to be set while the VM is stopped. Set on a running VM it is stored and survives a
///   restart, and Windows carries on showing UTM's placeholder. So Winbar refuses to set it while
///   the VM runs and offers the restart instead of making one behind the person's back.
/// - Windows is given the folder UTM's registry held at the *previous* start, so one start after a
///   change is never enough (see `settle`). Winbar proves what Windows ended up with instead of
///   counting restarts.
/// - A working share dies as soon as UTM itself restarts, with nothing re-set: Z: comes back empty
///   and every write fails. Winbar restarts UTM for every display change (utmapp/UTM#7882), so it
///   writes the folder again on its way through and checks the result (see `reestablish`).
///
/// UTM's own source says why: `update registry` (UTMScriptingRegistryEntryImpl) resolves the path
/// into a *remote* bookmark inside a helper process — with the VM stopped, a throwaway `UTMProcess()`
/// — and stores that. It is not the durable security-scoped bookmark UTM's own file picker makes,
/// which is why it survives neither the start it was written for nor a relaunch of UTM. Anyone who
/// wants a folder that simply stays should pick it in UTM itself; `durableAdvice` says so.
///
/// And the path must have no space in it: see `hasSpace`.
///
/// Nothing has to be installed in Windows: UTM Guest Tools bring `spice-webdavd`, Windows' own
/// WebClient service carries WebDAV, and the Guest Tools map a drive (Z: by default) to
/// `\\localhost@<port>\DavWWWRoot`. Winbar only looks, and maps the drive if the Guest Tools somehow
/// didn't.
///
/// Nothing here reads or writes inside UTM's container, and nothing here touches the VM's drives or
/// its display: the shared folder is not VM hardware, which is also why changing it needs no
/// BitLocker guard (see `Reconfigure`).
enum SharedFolder {
    /// What a change asks for. Absent (nil, in `ConfigChanges`) means "leave it alone".
    enum Setting: Equatable {
        case folder(String)
        case off

        var path: String? {
            if case .folder(let path) = self { return path }
            return nil
        }
    }

    /// Offered when nobody has chosen a folder. Created only when asked for, never behind someone's
    /// back. Hyphens, not spaces: see `hasSpace`.
    static let defaultFolderName = "Shared-with-Windows"

    static func defaultFolder(home: String = NSHomeDirectory()) -> String {
        (home as NSString).appendingPathComponent(defaultFolderName)
    }

    /// Where UTM's WebDAV server answers inside the guest. Only a fallback: the guest's own drive
    /// mapping says which port it actually uses, and that is read first.
    static let defaultPort = 9843
    static let defaultDrive = "Z:"
    static var defaultRemotePath: String { remotePath(port: defaultPort) }

    static func remotePath(port: Int) -> String { #"\\localhost@\#(port)\DavWWWRoot"# }

    /// UTM writes this into a temporary folder and shares that instead when no folder is chosen, so
    /// the guest always has something to mount. Its first line is how "nothing is shared" is told
    /// apart from "shared, but empty".
    static let placeholderOpening = "You have not selected a shared directory"

    // MARK: - UTM's side

    /// The folder UTM shares with this VM, or nil when there is none. Works whether or not the VM runs.
    static func current(vm: String) -> Result<String?, WinbarError> {
        UTM.ensureRunning()
        return AppleScriptRunner.run(readScript, arguments: [vm]).map { parsePaths($0).first }
    }

    /// Sets (or clears) the shared folder and returns what UTM reports afterwards.
    ///
    /// The script refuses while the VM runs, as UTM's own updater does for configuration changes —
    /// here because a change made then is silently ignored by the guest, which is worse than an error.
    /// Callers go through `Reconfigure.apply`, which owns the shutdown and the restart.
    static func setWhileStopped(_ setting: Setting, vm: String) -> Result<String?, WinbarError> {
        UTM.ensureRunning()
        return AppleScriptRunner.run(updateScript, arguments: [vm, setting.path ?? ""], timeout: 120)
            .map { parsePaths($0).first }
    }

    /// The script's answer: percent-escaped POSIX paths, separated by the unit separator, and empty
    /// when the registry holds none. `POSIX path of` ends a folder with "/", which no other part of
    /// Winbar (or Finder, or the person) writes, so it comes off here.
    static func parsePaths(_ text: String) -> [String] {
        text.split(separator: UTMScripting.fieldSeparator, omittingEmptySubsequences: true)
            .map { UTMScripting.unescape(String($0)) }
            .map(trimmingSlash)
            .filter { !$0.isEmpty }
    }

    /// "/Users/x/Shared with Windows/" → "/Users/x/Shared with Windows"; "/" stays "/".
    static func trimmingSlash(_ path: String) -> String {
        var path = path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// Whether UTM already shares what is being asked for. Paths are compared as text after the
    /// trailing slash: UTM hands back what it was given, and the same folder typed twice is the same
    /// folder. Case matters, because APFS can be case-sensitive.
    static func matches(_ current: String?, _ wanted: Setting) -> Bool {
        switch wanted {
        case .off: return current == nil
        case .folder(let path): return current.map(trimmingSlash) == trimmingSlash(path)
        }
    }

    /// What has to happen for `wanted` to be true and Windows to see it.
    enum Decision: Equatable {
        /// UTM already shares this; nothing to do.
        case alreadySet
        /// The VM is off, so the change can be made now and is live at the next start.
        case setNow
        /// The VM is running. A change made now would be stored and ignored by Windows, so the VM
        /// has to be restarted for it.
        case needsRestart
    }

    /// `needsRewrite` is what keeps a dead share from looking like a finished one: the registry still
    /// names the folder, so only this says the bookmark behind it is no longer any good. Two things
    /// raise it — UTM has restarted since Winbar's own folder was last seen working, or Windows says
    /// the mount has nothing behind it (`GuestView.looksDead`) — and either way the answer is to
    /// write it again, not to call it done.
    static func decide(current: String?, wanted: Setting, running: Bool,
                       needsRewrite: Bool = false) -> Decision {
        let stillGood = wanted == .off || !needsRewrite
        if matches(current, wanted), stillGood { return .alreadySet }
        return running ? .needsRestart : .setNow
    }

    /// Whether the share died when UTM restarted: it was seen working under UTM processes that are
    /// not the ones running now. Pure. An empty `seenUnder` (never seen working) or no UTM at all
    /// says nothing, and claims nothing.
    static func brokenByUTMRestart(seenUnder: [Int], utmNow: [Int]) -> Bool {
        guard !seenUnder.isEmpty, !utmNow.isEmpty else { return false }
        return !seenUnder.contains { utmNow.contains($0) }
    }

    /// Whether the folder UTM reports is still the one Winbar wrote. A different path means someone
    /// else set it — UTM's own details screen — and that one has a durable bookmark Winbar must
    /// neither rewrite nor blame UTM's restart for. Pure.
    static func stillOurs(read: String?, remembered: String?, wasOurs: Bool) -> Bool {
        guard wasOurs, let read, let remembered else { return false }
        return trimmingSlash(read) == trimmingSlash(remembered)
    }

    /// The same question, asked of this Mac. Only ever about a folder Winbar wrote: one picked in
    /// UTM survives UTM restarting, which is the whole of this problem.
    static func brokenByUTMRestart(vm: String) -> Bool {
        guard vm == Config.vmName, Config.sharedFolderByWinbar, Config.sharedFolder != nil else { return false }
        return brokenByUTMRestart(seenUnder: Config.sharedFolderUTM, utmNow: UTM.processIDs.map(Int.init))
    }

    // MARK: - The Mac folder

    /// What someone typed, as an absolute path: `~` expanded, relative paths resolved, no trailing
    /// slash. Touches nothing on disk.
    static func resolve(_ typed: String, home: String = NSHomeDirectory(),
                        currentDirectory: String = FileManager.default.currentDirectoryPath) -> String {
        let trimmed = typed.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "" }
        var path = trimmed
        if path == "~" {
            path = home
        } else if path.hasPrefix("~/") {
            path = (home as NSString).appendingPathComponent(String(path.dropFirst(2)))
        } else if !path.hasPrefix("/") {
            path = (currentDirectory as NSString).appendingPathComponent(path)
        }
        return trimmingSlash((path as NSString).standardizingPath)
    }

    /// "~/Shared with Windows" for anything in the home folder, so messages stay short and the
    /// person recognises what they chose.
    static func abbreviate(_ path: String, home: String = NSHomeDirectory()) -> String {
        let path = trimmingSlash(path), home = trimmingSlash(home)
        guard !home.isEmpty else { return path }
        if path == home { return "~" }
        guard path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    /// Whether a path is one UTM's share can actually carry.
    ///
    /// A space anywhere in it breaks the share: `~/Shared with Windows` mounted as an empty drive
    /// (only `.spice-clipboard`) and every write failed with "A device attached to the system is not
    /// functioning", while the same files at `~/Shared-with-Windows` worked both ways in the same VM
    /// minutes later. So a path with a space is refused up front rather than set and left broken.
    static func hasSpace(_ path: String) -> Bool { path.contains(" ") }

    /// The same folder with hyphens instead of spaces, to offer instead — but only when the spaces
    /// are in the folder's own name. Spaces further up the path are the person's home or disk, which
    /// Winbar has no business renaming, so there is nothing to suggest.
    static func hyphenated(_ path: String) -> String? {
        let parent = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        guard !hasSpace(parent), hasSpace(name) else { return nil }
        return (parent as NSString).appendingPathComponent(name.replacingOccurrences(of: " ", with: "-"))
    }

    /// Why this path can't be shared, in a sentence, or nil when it can.
    static func refusal(_ path: String) -> WinbarError? {
        guard hasSpace(path) else { return nil }
        let why = "Windows mounts a shared folder whose path has a space in it as an empty drive, and every write to it "
            + "fails with “A device attached to the system is not functioning”."
        guard let suggestion = hyphenated(path) else {
            return WinbarError("\(abbreviate(path)) has a space in its path",
                               why + " Choose a folder whose whole path has none.")
        }
        return WinbarError("\(abbreviate(path)) has a space in its name",
                           why + " Try \(abbreviate(suggestion)) instead.")
    }

    enum FolderState: Equatable { case folder, missing, notAFolder }

    static func inspect(_ path: String) -> FolderState {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return .missing }
        return isDirectory.boolValue ? .folder : .notAFolder
    }

    static func create(_ path: String) -> Result<Void, WinbarError> {
        do {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            return .success(())
        } catch {
            return .failure(WinbarError("Couldn't create \(abbreviate(path))", error.localizedDescription))
        }
    }

    // MARK: - Windows' side

    /// What Windows reports about the share: the helper service, the drive the Guest Tools mapped,
    /// and what is actually at the other end of it.
    struct GuestView: Equatable {
        /// spice-webdavd, as "Status:StartType" from `Get-Service`; empty when the survey didn't say.
        var webdavd = ""
        /// Windows' own WebDAV redirector, same shape.
        var webClient = ""
        /// The drive letter the mapping uses, "Z:" as the Guest Tools set it up.
        var drive: String?
        /// `\\localhost@9843\DavWWWRoot`, from whichever mapping the guest could see.
        var remotePath: String?
        /// Whether the guest could list the share at all. nil when nothing tried (the helper is down).
        var reachable: Bool?
        /// The first line of a README.txt at the root, which is how UTM's placeholder announces itself.
        var readme: String?
        /// What the marker file on the Mac holds, as Windows read it back (see `verify`).
        var marker: String?
        var entryCount: Int?
        /// The share holds nothing but spice-webdavd's own `.spice-clipboard`. nil when nothing was
        /// listed.
        var onlySpiceFile: Bool?
        /// The drive letter in the signed-in person's own session, and what it showed there — a
        /// different question from everything above, which the agent answered about session 0.
        var userDrive: String?
        var userState: String?
        var userRemapped = false
        var error: String?

        var webdavdRunning: Bool { webdavd.hasPrefix("Running") }
        var webClientRunning: Bool { webClient.hasPrefix("Running") }
        var mapped: Bool { drive != nil }
        /// The port the guest's own mapping names, so nothing has to assume 9843.
        var port: Int? { SharedFolder.port(in: remotePath) }
        /// Windows is looking at UTM's stand-in, which means UTM has no folder for this VM *yet* —
        /// either none is set, or one was set while the VM was running and it never took.
        var seesPlaceholder: Bool { isPlaceholder(readme) }

        /// A mount with nothing behind it: the share answers, it isn't UTM's placeholder, and all it
        /// holds is spice-webdavd's own file. That is what a bookmark UTM can no longer resolve looks
        /// like from Windows — proven live, alongside "A device attached to the system is not
        /// functioning" on every write. Only ever asked once the marker has already said Windows
        /// isn't serving the folder we mean.
        var looksDead: Bool { reachable == true && !seesPlaceholder && onlySpiceFile == true }
    }

    /// What the signed-in person's own drive letter needs. Their letter is not the share: it can
    /// hold a dead handle while the endpoint behind it is perfectly healthy (seen live, right after
    /// a repair), because the Guest Tools map it at sign-in and that can race the share coming up.
    ///
    /// Only meaningful once the share itself is live — which is why a letter showing some other
    /// folder's files counts as stale here: with the endpoint proven good, the letter is what is out
    /// of step.
    enum DriveState: Equatable {
        case working
        case stale
        case missing
        case unknown(String)

        /// Whether replacing the mapping is the thing to try.
        var needsMapping: Bool { self == .stale || self == .missing }
    }

    static func driveState(_ view: GuestView) -> DriveState {
        switch view.userState {
        case "ok": return .working
        case "empty", "other": return .stale
        case "none": return .missing
        case "nosession": return .unknown("nobody is signed in to Windows")
        case "noanswer": return .unknown("the signed-in session didn't answer")
        case "error": return .unknown(view.error ?? "Windows couldn't check it")
        case nil: return .unknown("not checked")
        case let other?: return .unknown(other)
        }
    }

    static func isPlaceholder(_ readmeFirstLine: String?) -> Bool {
        guard let line = readmeFirstLine else { return false }
        let text = line.hasPrefix("\u{FEFF}") ? String(line.dropFirst()) : line
        return text.trimmingCharacters(in: .whitespaces).hasPrefix(placeholderOpening)
    }

    /// `\\localhost@9843\DavWWWRoot` → 9843.
    static func port(in remotePath: String?) -> Int? {
        guard let remotePath, let at = remotePath.lastIndex(of: "@") else { return nil }
        let digits = remotePath[remotePath.index(after: at)...].prefix { $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }

    /// Reads the SF_* lines the survey (and `winbar share`) collect.
    static func guestView(_ out: GuestOutput) -> GuestView {
        var view = GuestView()
        view.webdavd = out["SF_WEBDAVD"] ?? ""
        view.webClient = out["SF_WEBCLIENT"] ?? ""
        view.drive = out["SF_DRIVE"].flatMap { $0.isEmpty ? nil : $0 }
        view.remotePath = out["SF_REMOTE"].flatMap { $0.isEmpty ? nil : $0 }
        view.reachable = out.bool("SF_REACHABLE")
        view.readme = out["SF_README"]
        view.marker = out["SF_MARKER"].flatMap { $0.isEmpty ? nil : $0 }
        view.entryCount = out.int("SF_COUNT")
        view.onlySpiceFile = out.bool("SF_ONLY_SPICE")
        view.userDrive = out["SF_USER_DRIVE"].flatMap { $0.isEmpty ? nil : $0 }
        view.userState = out["SF_USER_STATE"].flatMap { $0.isEmpty ? nil : $0 }
        view.userRemapped = out["SF_USER_REMAPPED"] == "1"
        view.error = out["SF_ERROR"] ?? out["SF_UNREACHABLE"] ?? out["SF_USER_ERROR"]
        return view
    }

    /// Asks Windows on its own, for `winbar share` when there is no survey to read.
    static func view(vm: String, user: String?) -> Result<GuestView, WinbarError> {
        GuestAgent.run(vm: vm, GuestScripts.sharedFolder(user: user), timeout: 120).map(guestView)
    }

    /// What `winbar share` prints, and the menu shows, about the restart a change costs. UTM serves
    /// the folder its registry held at the previous start, so a change needs the VM to start twice.
    static let restartCost = "Windows only picks up a shared folder when the VM starts, and UTM hands it the folder from "
        + "the start before that, so this can take two restarts. Winbar checks from inside Windows and does the second "
        + "one only if it is needed."

    /// Why a share that was working is suddenly empty, and what to do about it.
    static let diedWhenUTMRestarted = "UTM restarted, and a shared folder set by script doesn't survive that: what UTM "
        + "stores is a bookmark that only lives as long as the UTM that made it."

    /// The honest limit of what Winbar can automate, said wherever a share has had to be rewritten.
    /// UTM's own placeholder README gives the same advice in the guest.
    static let durableAdvice = "The way to have one that simply stays is to pick it in UTM itself: shut the VM down and "
        + "choose a Shared Directory on its details screen. That one is a bookmark UTM can always open again."

    /// Said wherever a folder is offered or set: what it is good for, and what it isn't.
    static let worthKnowing = "It's fine for documents; very large files are slow over it, and the path must have no "
        + "spaces in it."

    // MARK: - Proving Windows really has it

    /// What Windows is serving, compared with what was asked for.
    enum Verification: Equatable {
        /// Windows has the folder that was asked for (or, for `.off`, UTM's placeholder).
        case live
        /// Windows is still serving what it had at the previous start.
        case stale
        /// Nothing could be proved either way, and why.
        case unknown(String)
    }

    /// Written into the shared folder for a moment so Windows can be asked to find it. Hidden, and
    /// removed again whatever happens.
    static let markerName = ".winbar-share-check"

    static func writeMarker(in folder: String) -> String? {
        let token = UUID().uuidString
        let path = (folder as NSString).appendingPathComponent(markerName)
        guard (try? token.write(toFile: path, atomically: true, encoding: .utf8)) != nil else { return nil }
        return token
    }

    static func removeMarker(in folder: String) {
        try? FileManager.default.removeItem(atPath: (folder as NSString).appendingPathComponent(markerName))
    }

    /// Whether Windows is serving `setting`, judged from what the guest reported.
    ///
    /// There is no way to ask the guest which Mac folder it has — it only ever sees a WebDAV root —
    /// so a folder is proved by a marker file written on the Mac and found in Windows, and "no folder"
    /// by UTM's own placeholder README. Pure, so the whole table can be checked without a VM.
    static func judge(_ setting: Setting, view: GuestView, token: String?) -> Verification {
        guard !view.webdavd.isEmpty else { return .unknown("Windows didn't say") }
        guard view.webdavdRunning else { return .unknown("spice-webdavd isn't running in Windows") }
        guard view.webClientRunning else { return .unknown("Windows' WebClient service isn't running") }
        // Only a listing that actually happened says anything; nothing tried is not "nothing there".
        guard view.reachable == true else { return .unknown("Windows couldn't read the share") }
        switch setting {
        case .off:
            return view.seesPlaceholder ? .live : .stale
        case .folder:
            guard let token else { return .unknown("the marker file couldn't be written") }
            if view.marker == token { return .live }
            return .stale
        }
    }

    /// The verdict, and what Windows said while it was being asked (the drive letter, mostly).
    struct Checked: Equatable {
        var verification: Verification
        var view: GuestView?

        var drive: String? { view?.drive }
        static func unknown(_ why: String) -> Checked { Checked(verification: .unknown(why)) }
    }

    /// Asks Windows whether it is serving `setting`, with a marker file for the folder case.
    ///
    /// `remapDrive` also replaces the mapping in the signed-in person's session. It belongs in the
    /// same call because the marker only exists while this runs, and the remap has to be judged by
    /// the same marker.
    static func verify(_ setting: Setting, vm: String, user: String?,
                       remapDrive: Bool = false) -> Result<Checked, WinbarError> {
        guard case .folder(let path) = setting else {
            return ask(vm: vm, user: user, remap: remapDrive)
                .map { Checked(verification: judge(setting, view: $0, token: nil), view: $0) }
        }
        guard inspect(path) == .folder else { return .success(.unknown("\(abbreviate(path)) isn't on this Mac any more")) }
        let token = writeMarker(in: path)
        defer { removeMarker(in: path) }
        return ask(vm: vm, user: user, remap: remapDrive).map { view in
            let verification = judge(setting, view: view, token: token)
            // Which UTM it was working under is the only way to know later that a relaunch killed it.
            if verification == .live { Config.rememberSharedFolderWorking(under: UTM.processIDs.map(Int.init), for: vm) }
            return Checked(verification: verification, view: view)
        }
    }

    private static func ask(vm: String, user: String?, remap: Bool = false) -> Result<GuestView, WinbarError> {
        // The part that runs in the person's own session is a file of its own; put it there first.
        GuestAgent.push(vm: vm, path: GuestScripts.userDrivePath, text: GuestScripts.userDriveChild)
        let script = GuestScripts.sharedFolder(user: user, marker: markerName, userDrive: true, remap: remap)
        defer { GuestAgent.remove(vm: vm, path: GuestScripts.userDrivePath) }
        return GuestAgent.run(vm: vm, script, timeout: 210).map { out in
            // The session-crossing half is the part that can quietly do nothing, so it is the part
            // WINBAR_DEBUG shows.
            Debug.log("shared folder: " + out.pairs.filter { $0.key.hasPrefix("SF_") }
                .map { "\($0.key)=\($0.value)" }.joined(separator: " "))
            return guestView(out)
        }
    }

    /// Replaces the mapping in the signed-in person's session, for the doctor row's fix.
    static func remapUserDrive(vm: String, user: String?, folder: String) -> Result<Void, WinbarError> {
        verify(.folder(folder), vm: vm, user: user, remapDrive: true).flatMap { checked in
            switch driveState(checked.view ?? GuestView()) {
            case .working:
                return .success(())
            case .stale, .missing:
                return .failure(WinbarError("Windows still can't list the drive",
                                            "The mapping was made again and still shows nothing. Signing out of Windows "
                                                + "and back in remakes it from scratch."))
            case .unknown(let why):
                return .failure(WinbarError("Couldn't check the drive in Windows", why))
            }
        }
    }

    /// Puts the share back on its feet for the moment after UTM has been restarted and the VM is
    /// still stopped — the only moment it can be written.
    ///
    /// UTM's relaunch invalidates the bookmark behind a scripted share, so a folder that was working
    /// is dead from that moment, and writing it again is the only thing that brings it back. Winbar
    /// only writes the one it wrote itself: a folder picked on UTM's own details screen holds a
    /// durable bookmark that survives by itself, and a scripted rewrite would quietly downgrade it.
    ///
    /// Returns the folder that is shared, whether or not it was rewritten, so the caller can ask
    /// Windows what became of it either way; nil when nothing is shared or UTM wouldn't say. A
    /// failure here is never worth failing a display change over.
    @discardableResult
    static func reestablish(vm: String, progress: (String) -> Void = { _ in }) -> String? {
        guard case .success(let folder?) = current(vm: vm) else { return nil }
        guard vm == Config.vmName,
              stillOurs(read: folder, remembered: Config.sharedFolder, wasOurs: Config.sharedFolderByWinbar)
        else { return folder }   // not Winbar's to rewrite; the caller still checks it
        progress("Writing \(vm)'s shared folder again: restarting UTM invalidates it…")
        guard case .success = setWhileStopped(.folder(folder), vm: vm) else { return folder }
        Config.rememberSharedFolderWritten(folder, for: vm)
        return folder
    }

    /// Finishes a change `Reconfigure` has already made and the VM has already restarted for: wait for
    /// Windows, check, and give it the second start UTM needs if it is still serving the old folder.
    ///
    /// UTM hands the guest the folder its registry held at the *previous* start, not the current one
    /// — five cycles on UTM 4.7.5 agreed: set A while running, restart → placeholder; stop, set A,
    /// start → A; stop, set B, start → still A; stop, set C, start → B; restart unchanged → C. So one
    /// start after a change is never enough, and the second start needs no further `update registry`.
    /// The check is what decides, not the count: if some UTM stops doing this, nobody pays for a
    /// restart they don't need. Blocking.
    static func settle(_ setting: Setting, vm: String, user: String?,
                       _ interaction: Interaction) -> Result<Checked, WinbarError> {
        guard VMProcesses.isRunning(vm) else { return .success(.unknown("\(vm) isn't running, so Windows can't be asked")) }
        interaction.progress("Waiting for Windows…")
        guard UTM.waitForGuestAgent(vm, timeout: 240) else { return .success(.unknown("Windows didn't answer in time")) }
        switch verify(setting, vm: vm, user: user) {
        case .failure(let error): return .failure(error)
        case .success(let checked) where checked.verification != .stale:
            return .success(fixUserDrive(checked, vm: vm, user: user, setting, interaction))
        case .success: break
        }
        interaction.progress("Windows is still serving the folder it had before; restarting \(vm) once more…")
        if case .failure(let error) = UTM.shutDown(vm, offerForce: interaction.offerForceStop) { return .failure(error) }
        if case .failure(let error) = UTM.start(vm) { return .failure(error) }
        interaction.progress("Waiting for Windows…")
        guard UTM.waitForGuestAgent(vm, timeout: 240) else { return .success(.unknown("Windows didn't answer in time")) }
        return verify(setting, vm: vm, user: user).map { fixUserDrive($0, vm: vm, user: user, setting, interaction) }
    }

    /// The last step, and the one the person actually experiences: their own drive letter. It can be
    /// a dead handle while the share behind it is healthy, and only a session of their own can
    /// replace the mapping. One remap, then whatever it says — a letter that still shows nothing is
    /// reported, never retried in a loop.
    static func fixUserDrive(_ checked: Checked, vm: String, user: String?, _ setting: Setting,
                             _ interaction: Interaction) -> Checked {
        guard checked.verification == .live, let view = checked.view, driveState(view).needsMapping else { return checked }
        interaction.progress("Mapping the drive again in Windows: the share works, the drive letter doesn't…")
        guard case .success(let remapped) = verify(setting, vm: vm, user: user, remapDrive: true) else { return checked }
        return remapped
    }

    // MARK: - Scripts
    //
    // Same two traps as `UTMScripting`'s: names are compared `considering case`, and anything that
    // isn't UTM's own terminology (POSIX file, POSIX path) is evaluated outside the tell block.

    static let findVM = #"""
			set theVM to missing value
			set matchCount to 0
			repeat with vm in virtual machines
				set vmName to (name of vm) as text
				-- Exactly the name Swift checked: AppleScript ignores case by default, and "win11"
				-- must not stand in for "Win11".
				considering case
					set isMatch to (vmName is wantedName)
				end considering
				if isMatch then
					set matchCount to matchCount + 1
					set theVM to contents of vm
				end if
			end repeat
			if theVM is missing value then error "UTM has no virtual machine named " & wantedName number 1001
			if matchCount > 1 then error "UTM has more than one virtual machine named " & wantedName & ". Rename one, then try again." number 1003
"""#

    /// Escapes and joins whatever `registry` holds. Both scripts end with it, so a set reports what
    /// UTM took rather than what it was given.
    static let joinPaths = #"""
	set paths to {}
	repeat with f in regFiles
		set end of paths to my esc(POSIX path of f)
	end repeat
	set AppleScript's text item delimiters to US
	set listText to paths as text
	set AppleScript's text item delimiters to ""
	return listText
"""#

    static let escapeHandlers = #"""
-- A path can hold the separator. Escape it, and "%" itself first, so parsePaths can undo it.
on esc(t)
	set t to my rep(t, "%", "%25")
	set t to my rep(t, character id 31, "%1F")
	return t
end esc

on rep(t, a, b)
	set AppleScript's text item delimiters to a
	set parts to text items of t
	set AppleScript's text item delimiters to b
	set t to parts as text
	set AppleScript's text item delimiters to ""
	return t
end rep
"""#

    static let readScript = #"""
on run argv
	set wantedName to item 1 of argv
	set US to character id 31
	set regFiles to {}
	with timeout of 60 seconds
		tell application id "com.utmapp.UTM"
"""# + "\n" + findVM + "\n" + #"""
			set regFiles to registry of theVM
		end tell
	end timeout
"""# + "\n" + joinPaths + "\nend run\n\n" + escapeHandlers

    static let updateScript = #"""
on run argv
	set wantedName to item 1 of argv
	set newPath to item 2 of argv
	set US to character id 31
	-- Outside the tell block: POSIX file is AppleScript's own, not UTM's.
	if newPath is "" then
		set newRegistry to {}
	else
		set newRegistry to {POSIX file newPath}
	end if
	set regFiles to {}
	with timeout of 120 seconds
		tell application id "com.utmapp.UTM"
"""# + "\n" + findVM + "\n" + #"""
			-- UTM stores a change made while the VM runs and the guest never sees it (UTM 4.7.5),
			-- which is worse than refusing, so refuse. Reconfigure owns the shutdown and the restart.
			if status of theVM is not stopped then error wantedName & " must be stopped before its shared folder can change" number 1002
			update registry theVM with newRegistry
			set regFiles to registry of theVM
		end tell
	end timeout
"""# + "\n" + joinPaths + "\nend run\n\n" + escapeHandlers
}
