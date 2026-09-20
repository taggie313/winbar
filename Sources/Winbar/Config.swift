import Foundation

/// The flat key-value store Winbar's settings live in: `UserDefaults` in the app and the CLI, and a
/// dictionary in the tests, which is what lets the key naming and the migration below be checked
/// without writing to the settings of the Mac the tests run on.
protocol SettingsStore: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
    func removeObject(forKey key: String)
    /// Every key that has a value. Keys Winbar doesn't own are in here too — UserDefaults answers for
    /// the whole domain — so callers match Winbar's own names rather than taking what they find.
    func allKeys() -> [String]
}

extension UserDefaults: SettingsStore {
    func allKeys() -> [String] { Array(dictionaryRepresentation().keys) }
}

/// What Winbar remembers about one VM, as flat keys named `vm.<token>.<setting>`.
///
/// Flat keys rather than a dictionary per VM, because there are two writers: the menu bar app polls
/// and writes every few seconds (`VMProcesses.cache`) while the CLI writes the same domain, and a
/// read-modify-write of one dictionary loses whichever of the two writes landed second. Separate keys
/// have nothing to lose: each write stands on its own.
///
/// The token is the id UTM gave the VM wherever Winbar knows it, because a VM can be renamed in UTM
/// and its name then stops identifying it; it is the VM's name for a record written before the id was
/// known. Both go in verbatim, so `defaults read net.elusive.winbar` still reads like settings.
enum VMSettings {
    static let prefix = "vm."

    static func key(_ setting: String, for token: String) -> String { prefix + token + "." + setting }

    /// The VM and the setting a key names, or nil when it isn't one of Winbar's per-VM keys. Read off
    /// the *end*: a VM name may contain dots, and no setting name does.
    static func split(_ key: String) -> (token: String, setting: String)? {
        guard key.hasPrefix(prefix) else { return nil }
        let rest = key.dropFirst(prefix.count)
        guard let dot = rest.lastIndex(of: "."), dot != rest.startIndex else { return nil }
        let setting = String(rest[rest.index(after: dot)...])
        guard Config.Key.record.contains(setting) else { return nil }
        return (String(rest[..<dot]), setting)
    }

    /// Whether anything is remembered about this VM. The name it was last seen under doesn't count:
    /// that one is written to find the record again, not because anything was learned.
    static func hasRecord(_ token: String, in store: SettingsStore) -> Bool {
        Config.Key.perVM.contains { store.object(forKey: key($0, for: token)) != nil }
    }

    /// Every VM with a namespace in the store, in the order the store lists them.
    static func tokens(in store: SettingsStore) -> [String] {
        var found: [String] = []
        for token in store.allKeys().compactMap({ split($0)?.token }) where !found.contains(token) {
            found.append(token)
        }
        return found
    }

    /// The name this VM was last seen under.
    static func recordedName(of token: String, in store: SettingsStore) -> String? {
        store.object(forKey: key(Config.Key.recordedName, for: token)) as? String
    }

    static func remember(name: String, for token: String, in store: SettingsStore) {
        store.set(name, forKey: key(Config.Key.recordedName, for: token))
    }

    /// Which namespace holds the settings of the VM named here.
    ///
    /// The id wins wherever Winbar has one. A record still under the *name* is used instead when the
    /// id has none of its own — that is exactly what a record written before the id was known looks
    /// like, and `adopt` moves it as soon as the VM is chosen again.
    static func token(name: String?, id: String?, in store: SettingsStore) -> String? {
        let name = Config.nonEmpty(name)
        guard let id = Config.nonEmpty(id) else { return name }
        if hasRecord(id, in: store) { return id }
        if let name, hasRecord(name, in: store) { return name }
        return id
    }

    /// The id-keyed record of a VM the caller knows only by name, which is all `winbar config --vm`
    /// and `--forget` have — neither asks UTM for its list. nil when the name is its own namespace or
    /// there is no record at all, so the caller falls back to the name.
    static func id(forName name: String, in store: SettingsStore) -> String? {
        guard !name.isEmpty, !hasRecord(name, in: store) else { return nil }
        return tokens(in: store).first { $0 != name && recordedName(of: $0, in: store) == name }
    }

    /// The namespace a VM chosen by this name — and this id, when the caller has one — must use from
    /// now on, with a record written before the id was known moved into the id's namespace first and
    /// the name it was chosen under written down. Everything `Config.selectVM` does apart from
    /// remembering which VM is chosen, so that a switch can be checked (both records surviving it
    /// included) without touching the settings of the Mac the tests run on.
    static func select(name: String, id: String?, in store: SettingsStore) -> (id: String?, token: String) {
        let id = Config.nonEmpty(id) ?? self.id(forName: name, in: store)
        if let id { adopt(id: id, name: name, in: store) }
        let token = token(name: name, id: id, in: store) ?? name
        remember(name: name, for: token, in: store)
        return (id, token)
    }

    /// Every namespace a VM known by this name, and this id where there is one, can have: both of
    /// them, and any whose remembered name matches. Forgetting clears all of them, so a record caught
    /// half way through `adopt` can't come back.
    static func tokens(forName name: String, id: String?, in store: SettingsStore) -> [String] {
        var found = [name]
        if let id = Config.nonEmpty(id), !found.contains(id) { found.append(id) }
        for token in tokens(in: store) where !found.contains(token) && recordedName(of: token, in: store) == name {
            found.append(token)
        }
        return found
    }

    /// Moves a record written before the id was known into the id's namespace, so that renaming the
    /// VM in UTM afterwards can't lose it. Only when the id has nothing of its own: a name whose
    /// record belongs to some other VM must not be taken over.
    ///
    /// Everything is written under the id first and removed from the name afterwards, so an
    /// interruption leaves a whole record under both rather than half of one under each.
    @discardableResult
    static func adopt(id: String, name: String, in store: SettingsStore) -> Bool {
        guard !id.isEmpty, !name.isEmpty, id != name,
              !hasRecord(id, in: store), hasRecord(name, in: store) else { return false }
        let held = Config.Key.record.compactMap { (setting: String) -> (String, Any)? in
            store.object(forKey: key(setting, for: name)).map { (setting, $0) }
        }
        for (setting, value) in held { store.set(value, forKey: key(setting, for: id)) }
        for (setting, _) in held { store.removeObject(forKey: key(setting, for: name)) }
        return true
    }

    /// Drops everything remembered about one VM, and says which settings were there.
    @discardableResult
    static func forget(_ token: String, in store: SettingsStore) -> [String] {
        let held = Config.Key.record.filter { store.object(forKey: key($0, for: token)) != nil }
        held.forEach { store.removeObject(forKey: key($0, for: token)) }
        return held.filter { $0 != Config.Key.recordedName }
    }

    /// The one-time move of the single global set of settings 0.1.0 kept into the selected VM's own
    /// namespace. Says which settings it moved.
    ///
    /// Each value is written into the namespace *before* the global key is removed, so an interrupted
    /// run leaves a whole record and a few stale globals rather than a gap. The next run finds those
    /// globals, sees the namespaced value already there, keeps it and clears the global — and a run
    /// with nothing left to move changes nothing at all.
    ///
    /// With no VM selected the values describe a VM nobody can name, so they are left where they are
    /// rather than handed to whichever VM is chosen next, which is the very bug this scheme exists to
    /// stop. They are inert from then on.
    @discardableResult
    static func migrate(name: String?, id: String?, in store: SettingsStore) -> [String] {
        guard store.object(forKey: Config.Key.settingsMigrated) == nil else { return [] }
        defer { store.set(true, forKey: Config.Key.settingsMigrated) }
        guard let token = token(name: name, id: id, in: store) else { return [] }
        let held = Config.Key.perVM.compactMap { (setting: String) -> (String, Any)? in
            store.object(forKey: setting).map { (setting, $0) }
        }
        for (setting, value) in held where store.object(forKey: key(setting, for: token)) == nil {
            store.set(value, forKey: key(setting, for: token))
        }
        for (setting, _) in held { store.removeObject(forKey: setting) }
        if let name = Config.nonEmpty(name) { remember(name: name, for: token, in: store) }
        return held.map(\.0)
    }
}

/// Settings shared by the menu bar app and the CLI. Nothing about a particular VM is compiled in:
/// the VM name is chosen by the user, and everything else is discovered and cached here.
///
/// Everything that describes a VM is filed under that VM (see `VMSettings`); the rest — which VM is
/// chosen, what this copy of Winbar has asked or checked — is global to the Mac.
enum Config {
    static let suiteName = "net.elusive.winbar"
    static let appBundleID = "net.elusive.winbar"
    static let utmBundleID = "com.utmapp.UTM"
    static let windowsAppBundleID = "com.microsoft.rdc.macos"

    /// The app runs as net.elusive.winbar, so `.standard` is already this domain. The CLI runs under
    /// Terminal with no bundle identity of its own, so it names the suite explicitly. The app can't do
    /// the same: UserDefaults rejects a suite named after the process's own bundle identifier.
    static let defaults: UserDefaults = {
        if Bundle.main.bundleIdentifier == suiteName { return .standard }
        return UserDefaults(suiteName: suiteName) ?? .standard
    }()

    enum Key {
        static let vmName = "vmName"
        /// The id UTM gave the VM Winbar looks after, when Winbar has been told one (UTM's VM list and
        /// `winbar create` both carry it). A VM can be renamed in UTM, so this — not the name — is
        /// what its settings are filed under. Global, like `vmName`: it says which VM is chosen.
        static let vmID = "vmID"
        static let rdpHost = "rdpHost"
        static let rdpUser = "rdpUser"
        /// The saved PC's name in Windows App when it isn't rdpHost. Its tile's accessibility
        /// description is the friendly name when one is set, so Connect matches either.
        static let savedPCName = "savedPCName"
        static let vmMAC = "vmMAC"
        static let consoleEnabled = "consoleEnabled"
        static let offeredAccessibility = "offeredAccessibility"
        /// Whether C: was last seen encrypted, and when, for `winbar config`. Never a reason to skip
        /// the BitLocker guard: it can be turned back on after Winbar last looked.
        static let bitLockerOn = "bitLockerOn"
        static let bitLockerCheckedAt = "bitLockerCheckedAt"
        /// The host name a saved PC was last seen for (the menu found its tile, or the user confirmed
        /// it in setup). Windows App's own data is off limits, so this is the only evidence we have.
        static let savedPCHost = "savedPCHost"
        /// `COMPUTER\user` keys whose password was already found non-blank. Probing with an empty
        /// password counts as a failed logon, and Windows 11 locks local accounts after 10 of those, so
        /// doctor must not repeat the probe on every run. The key names the guest, so it's kept across
        /// VM switches and for `doctor --vm` runs too.
        static let passwordCheckedFor = "passwordCheckedFor"
        /// Setup's `--keep-bitlocker` and `--no-visual-tweaks`, remembered per VM so doctor honours them
        /// and a later `setup --yes` doesn't undo the choice.
        static let keepBitLocker = "keepBitLocker"
        static let noVisualTweaks = "noVisualTweaks"
        /// What `winbar create`'s checklist was left unticked for this VM: setup says
        /// so once instead of offering the same three things on every run.
        static let declinedAutologon = "declinedAutologon"
        static let declinedRemoteDesktop = "declinedRemoteDesktop"
        static let declinedTuning = "declinedTuning"
        /// The Mac folder this VM shares with Windows, as UTM last reported it. UTM's own registry is
        /// the truth; this is what doctor and `winbar config` can show without asking it.
        static let sharedFolder = "sharedFolder"
        /// The UTM processes that were running when Windows was last seen serving the shared folder.
        /// A scripted `update registry` stores a bookmark resolved in a helper process, which UTM
        /// relaunching invalidates, so a different UTM means the share is dead however good the
        /// registry still looks.
        static let sharedFolderUTM = "sharedFolderUTM"
        /// Winbar wrote this VM's shared folder itself, so it is Winbar's to write again after UTM
        /// restarts. A folder picked on UTM's own VM details screen has a durable bookmark instead,
        /// which a scripted rewrite would quietly downgrade — so that one is left alone.
        static let sharedFolderByWinbar = "sharedFolderByWinbar"
        /// Setup offered a shared folder for this VM and the answer was no. Asked once, then left
        /// alone: nobody needs one, and `winbar share <folder>` is there whenever they change their mind.
        static let declinedSharedFolder = "declinedSharedFolder"
        /// The person said UTM's folder is excluded from Time Machine, which Winbar usually can't check
        /// (that needs Full Disk Access). A real "[Included]" from tmutil overrides it.
        static let backupExclusionConfirmed = "backupExclusionConfirmed"
        /// UTM must quit before a VM starts again: a display change was sent to these UTM processes.
        /// See `UTMRestart`.
        static let pendingUTMRestart = "pendingUTMRestart"
        /// When Winbar last asked GitHub whether there is a newer release, and the newest version
        /// that answer named. The whole of what `UpdateCheck` remembers: no history, no counters,
        /// and nothing about the Mac. Not per-VM — they describe this copy of Winbar.
        static let lastUpdateCheck = "lastUpdateCheck"
        static let lastSeenVersion = "lastSeenVersion"
        /// The name a VM was last seen under, kept inside its own record so that a record filed under
        /// an id can still be found by someone holding only the name (`winbar config --vm NAME`,
        /// `--forget NAME`, neither of which asks UTM). Bookkeeping rather than a setting, so it is
        /// not one of `perVM`: a VM with nothing but this is a VM nothing is remembered about.
        static let recordedName = "name"
        /// Set once the one global set of settings 0.1.0 kept has been moved into the selected VM's
        /// namespace. See `VMSettings.migrate`.
        static let settingsMigrated = "settingsMigrated"

        static let all = [vmName, vmID, rdpHost, rdpUser, savedPCName, vmMAC, consoleEnabled, offeredAccessibility,
                          bitLockerOn, bitLockerCheckedAt, savedPCHost, passwordCheckedFor, keepBitLocker, noVisualTweaks,
                          declinedAutologon, declinedRemoteDesktop, declinedTuning,
                          sharedFolder, sharedFolderUTM, sharedFolderByWinbar, declinedSharedFolder, backupExclusionConfirmed, pendingUTMRestart,
                          lastUpdateCheck, lastSeenVersion, recordedName, settingsMigrated]

        /// Everything that describes one VM. Each VM has its own set, under `vm.<id>.<setting>`, so
        /// switching VMs changes which set is current and destroys none of them.
        static let perVM = [rdpHost, rdpUser, savedPCName, vmMAC, consoleEnabled, bitLockerOn, bitLockerCheckedAt,
                            savedPCHost, keepBitLocker, noVisualTweaks,
                            declinedAutologon, declinedRemoteDesktop, declinedTuning,
                            sharedFolder, sharedFolderUTM, sharedFolderByWinbar, declinedSharedFolder]

        /// Everything one VM's namespace holds: its settings, and the name it was last seen under.
        static let record = perVM + [recordedName]
    }

    // MARK: Which VM

    static var vmName: String? {
        get { nonEmpty(defaults.string(forKey: Key.vmName)) }
        set { set(newValue, Key.vmName) }
    }

    /// The id UTM gave the selected VM, when a caller that had one said so. nil is normal: only the
    /// paths that talk to UTM (its VM list, `winbar create`) know it.
    static var vmID: String? {
        get { nonEmpty(defaults.string(forKey: Key.vmID)) }
        set { set(newValue, Key.vmID) }
    }

    /// The namespace the selected VM's settings live in, with the one-time migration done first.
    /// nil when no VM is chosen, and then nothing per-VM can be read or written: those values would
    /// belong to no VM.
    static var currentToken: String? {
        _ = migration
        return VMSettings.token(name: vmName, id: vmID, in: defaults)
    }

    /// Moves 0.1.0's global settings into the selected VM's namespace, once. A lazy `static let` runs
    /// it exactly once per process, and every per-VM read and write goes through `currentToken`, so
    /// it happens before anything can read a key that hasn't moved yet — whichever of the app, the
    /// CLI and `--self-test` started first.
    private static let migration: Void = {
        VMSettings.migrate(name: defaults.string(forKey: Key.vmName),
                           id: defaults.string(forKey: Key.vmID), in: defaults)
    }()

    /// Switches to another VM.
    ///
    /// Nothing is deleted. Each VM's settings live under its own keys, so the VM being left keeps its
    /// Remote Desktop host and user, its saved PC, its MAC and its BitLocker state, and has them all
    /// back the moment it is chosen again; `forget` is how a VM is forgotten on purpose.
    ///
    /// `id` is the id UTM gave the VM, which the caller knows whenever it got the VM from UTM's list
    /// or made it. Without one, a record filed under an id is still found by the name it was last seen
    /// under, so `winbar config --vm NAME` doesn't start an empty record for a VM that has one.
    ///
    /// Returns the VM it switched away from, when that was a different one.
    @discardableResult
    static func selectVM(_ name: String, id: String? = nil) -> String? {
        _ = migration
        guard let name = nonEmpty(name) else { return nil }
        let previous = vmName
        // The id before the name. The two are separate keys, so another process can read the pair
        // half-written; this way what it catches is the new VM's own namespace rather than the new
        // VM's name pointing at the namespace of the one being left, which is the record this whole
        // scheme exists to keep.
        vmID = VMSettings.select(name: name, id: id, in: defaults).id
        vmName = name
        return previous == name ? nil : previous
    }

    /// Forgets everything remembered about a VM: `winbar config --forget NAME`, and `winbar create
    /// --cancel` for the VM it made and has just deleted from UTM. Nothing else destroys a record.
    ///
    /// Both namespaces a VM can have are cleared — the id's and the name's — so a half-adopted record
    /// doesn't come back. Forgetting the VM Winbar looks after leaves none chosen, because what would
    /// be left is a name with nothing behind it.
    ///
    /// Returns the settings that were forgotten, in `Key.perVM` order.
    @discardableResult
    static func forget(_ name: String, id: String? = nil) -> [String] {
        _ = migration
        guard let name = nonEmpty(name) else { return [] }
        var forgotten: Set<String> = []
        for token in VMSettings.tokens(forName: name, id: id, in: defaults) {
            forgotten.formUnion(VMSettings.forget(token, in: defaults))
        }
        if vmName == name || (nonEmpty(id) != nil && vmID == nonEmpty(id)) {
            vmName = nil
            vmID = nil
        }
        return Key.perVM.filter { forgotten.contains($0) }
    }

    /// Every VM Winbar remembers something about, by the name each was last seen under (its id when
    /// it has never been seen by name). For `winbar config --forget`, which has to say what it can
    /// forget when the name it was given isn't one of them.
    static func rememberedVMs() -> [String] {
        _ = migration
        return VMSettings.tokens(in: defaults)
            .filter { VMSettings.hasRecord($0, in: defaults) }
            .map { VMSettings.recordedName(of: $0, in: defaults) ?? $0 }
            .sorted()
    }

    // MARK: One VM's settings

    /// Explicitly configured host; nil means "derive it from the guest" (see `Context.rdpHost`).
    static var rdpHost: String? {
        get { string(Key.rdpHost) }
        set { setString(newValue, Key.rdpHost) }
    }

    static var rdpUser: String? {
        get { string(Key.rdpUser) }
        set { setString(newValue, Key.rdpUser) }
    }

    static var savedPCName: String? {
        get { string(Key.savedPCName) }
        set { setString(newValue, Key.savedPCName) }
    }

    static var vmMAC: String? {
        get { string(Key.vmMAC) }
        set { setString(newValue, Key.vmMAC) }
    }

    /// nil = never seen. Cached because the process arguments only say so while the VM runs.
    static var consoleEnabled: Bool? {
        get { object(Key.consoleEnabled) as? Bool }
        set { setObject(newValue, Key.consoleEnabled) }
    }

    static var bitLockerOn: Bool? {
        get { object(Key.bitLockerOn) as? Bool }
        set { setObject(newValue, Key.bitLockerOn) }
    }

    static var bitLockerCheckedAt: Date? {
        get { object(Key.bitLockerCheckedAt) as? Date }
        set { setObject(newValue, Key.bitLockerCheckedAt) }
    }

    /// Records what Windows just reported about C:, for the VM Winbar looks after and no other.
    /// `doctor --vm`, `winbar create` and a reconfigure all talk to VMs that may not be the selected
    /// one, and another VM's answer written here would have the menu and doctor describing this one
    /// wrongly.
    static func recordBitLocker(on: Bool, at date: Date = Date(), for vm: String) {
        guard UTM.shouldCacheSettings(vm: vm, selected: vmName, asked: true) else { return }
        bitLockerOn = on
        bitLockerCheckedAt = date
    }

    static func forgetBitLocker() {
        remove(Key.bitLockerOn)
        remove(Key.bitLockerCheckedAt)
    }

    static var savedPCHost: String? {
        get { string(Key.savedPCHost) }
        set { setString(newValue, Key.savedPCHost) }
    }

    /// Oldest first. A single string is what 0.1.0 development builds stored. Not per-VM: the key
    /// names the guest (`COMPUTER\user`), so it applies to whichever VM that guest is.
    static var passwordCheckedFor: [String] {
        get {
            if let list = defaults.stringArray(forKey: Key.passwordCheckedFor) { return list }
            return nonEmpty(defaults.string(forKey: Key.passwordCheckedFor)).map { [$0] } ?? []
        }
        set {
            if newValue.isEmpty { defaults.removeObject(forKey: Key.passwordCheckedFor) } else { defaults.set(newValue, forKey: Key.passwordCheckedFor) }
        }
    }

    /// Adds or drops one `COMPUTER\user` key, keeping the list short. Windows compares these names
    /// without regard to case, so this does too.
    static func updatePasswordChecked(_ list: [String], key: String, hasPassword: Bool, limit: Int = 20) -> [String] {
        var list = list.filter { $0.caseInsensitiveCompare(key) != .orderedSame }
        if hasPassword { list.append(key) }
        return Array(list.suffix(limit))
    }

    static var keepBitLocker: Bool {
        get { flag(Key.keepBitLocker) }
        set { setFlag(newValue, Key.keepBitLocker) }
    }

    static var noVisualTweaks: Bool {
        get { flag(Key.noVisualTweaks) }
        set { setFlag(newValue, Key.noVisualTweaks) }
    }

    /// Set by `winbar create` when its checklist row was unticked, and by `winbar config`. Only a
    /// true is stored, so a VM nobody declined anything for keeps a clean settings file.
    static var declinedAutologon: Bool {
        get { flag(Key.declinedAutologon) }
        set { setFlag(newValue, Key.declinedAutologon) }
    }

    static var declinedRemoteDesktop: Bool {
        get { flag(Key.declinedRemoteDesktop) }
        set { setFlag(newValue, Key.declinedRemoteDesktop) }
    }

    static var declinedTuning: Bool {
        get { flag(Key.declinedTuning) }
        set { setFlag(newValue, Key.declinedTuning) }
    }

    /// nil = UTM shares nothing with this VM, as far as Winbar last saw.
    static var sharedFolder: String? {
        get { string(Key.sharedFolder) }
        set { setString(newValue, Key.sharedFolder) }
    }

    /// Whether setup already offered this VM a shared folder and was told no.
    static var declinedSharedFolder: Bool {
        get { flag(Key.declinedSharedFolder) }
        set { setFlag(newValue, Key.declinedSharedFolder) }
    }

    /// The UTM processes the share was last seen working under; empty when it never has been.
    static var sharedFolderUTM: [Int] {
        get { (object(Key.sharedFolderUTM) as? [Int]) ?? [] }
        set { setObject(newValue.isEmpty ? nil : newValue, Key.sharedFolderUTM) }
    }

    static var sharedFolderByWinbar: Bool {
        get { flag(Key.sharedFolderByWinbar) }
        set { setFlag(newValue, Key.sharedFolderByWinbar) }
    }

    /// Records what UTM reported for `vm`, and only for the VM Winbar looks after: these keys say
    /// what the menu and doctor describe, so another VM's folder must not land in them.
    ///
    /// A path that isn't the one remembered means somebody else set it — UTM's own details screen,
    /// most likely — so it stops being Winbar's to rewrite, and what it was last seen working under
    /// no longer applies.
    static func rememberSharedFolder(_ path: String?, for vm: String) {
        guard UTM.shouldCacheSettings(vm: vm, selected: vmName, asked: true) else { return }
        if !SharedFolder.stillOurs(read: path, remembered: sharedFolder, wasOurs: sharedFolderByWinbar) {
            sharedFolderByWinbar = false
            sharedFolderUTM = []
        }
        sharedFolder = path
    }

    /// Winbar has just written this folder into UTM's registry itself.
    static func rememberSharedFolderWritten(_ path: String?, for vm: String) {
        guard UTM.shouldCacheSettings(vm: vm, selected: vmName, asked: true) else { return }
        sharedFolder = path
        sharedFolderByWinbar = path != nil
        sharedFolderUTM = []   // written, but not yet seen working
    }

    /// Records that Windows was just seen serving this VM's shared folder, under these UTM processes.
    static func rememberSharedFolderWorking(under pids: [Int], for vm: String) {
        guard UTM.shouldCacheSettings(vm: vm, selected: vmName, asked: true) else { return }
        sharedFolderUTM = pids
    }

    /// Records whether UTM says this VM has a display, for the menu's toggle while the VM is off.
    /// Only for the selected VM: a reconfigure can be aimed at another one (`setup --vm`), and its
    /// display state written here would have the menu offering to change the wrong thing.
    static func rememberConsoleEnabled(_ on: Bool, for vm: String) {
        guard UTM.shouldCacheSettings(vm: vm, selected: vmName, asked: true) else { return }
        consoleEnabled = on
    }

    // MARK: This copy of Winbar

    static var offeredAccessibility: Bool {
        get { defaults.bool(forKey: Key.offeredAccessibility) }
        set { defaults.set(newValue, forKey: Key.offeredAccessibility) }
    }

    static var backupExclusionConfirmed: Bool {
        get { defaults.bool(forKey: Key.backupExclusionConfirmed) }
        set { if newValue { defaults.set(true, forKey: Key.backupExclusionConfirmed) } else { defaults.removeObject(forKey: Key.backupExclusionConfirmed) } }
    }

    /// nil = never checked. `UpdateCheck` writes it when it starts a check, not when one succeeds.
    static var lastUpdateCheck: Date? {
        get { defaults.object(forKey: Key.lastUpdateCheck) as? Date }
        set { defaults.set(newValue, forKey: Key.lastUpdateCheck) }
    }

    /// The newest release the last check saw, whether or not it was newer than what is running.
    static var lastSeenVersion: String? {
        get { nonEmpty(defaults.string(forKey: Key.lastSeenVersion)) }
        set { set(newValue, Key.lastSeenVersion) }
    }

    static var pendingUTMRestart: UTMRestart? {
        get { defaults.dictionary(forKey: Key.pendingUTMRestart).flatMap(UTMRestart.init(plist:)) }
        set { if let newValue { defaults.set(newValue.plist, forKey: Key.pendingUTMRestart) } else { defaults.removeObject(forKey: Key.pendingUTMRestart) } }
    }

    /// A yes/no setting from `winbar config`: yes/no, on/off, true/false, 1/0, and "" for the
    /// default (no). nil if it's none of those.
    static func parseSwitch(_ value: String) -> Bool? {
        switch value.trimmingCharacters(in: .whitespaces).lowercased() {
        case "yes", "y", "on", "true", "1": return true
        case "no", "n", "off", "false", "0", "": return false
        default: return nil
        }
    }

    // MARK: Reading and writing

    /// Per-VM reads and writes. With no VM chosen they read nothing and write nothing: there would be
    /// no VM for the value to belong to, and the global key it used to land in is what let one VM's
    /// settings be handed to the next one.
    private static func object(_ setting: String) -> Any? {
        guard let token = currentToken else { return nil }
        return defaults.object(forKey: VMSettings.key(setting, for: token))
    }

    private static func setObject(_ value: Any?, _ setting: String) {
        guard let token = currentToken else { return }
        let key = VMSettings.key(setting, for: token)
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    private static func remove(_ setting: String) { setObject(nil, setting) }

    private static func string(_ setting: String) -> String? { nonEmpty(object(setting) as? String) }

    private static func setString(_ value: String?, _ setting: String) { setObject(nonEmpty(value), setting) }

    private static func flag(_ setting: String) -> Bool { object(setting) as? Bool ?? false }

    private static func setFlag(_ on: Bool, _ setting: String) { setObject(on ? true : nil, setting) }

    private static func set(_ value: String?, _ key: String) {
        if let value = nonEmpty(value) { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    fileprivate static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// RDP host names end up inside a certificate's SAN text extension, where `&` and `=` are syntax, so
    /// only plain DNS names are accepted.
    ///
    /// Each label is 1–63 characters and neither starts nor ends with a hyphen, which also catches a
    /// NetBIOS name Windows cut off at 15 characters mid-word (`winlab01-arm64-`).
    static func isValidHostName(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= 253 else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-.")
        guard host.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        return host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            !label.isEmpty && label.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-")
        }
    }
}
