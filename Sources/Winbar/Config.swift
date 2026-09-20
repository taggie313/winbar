import Foundation

/// Settings shared by the menu bar app and the CLI. Nothing about a particular VM is compiled in:
/// the VM name is chosen by the user, and everything else is discovered and cached here.
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

        static let all = [vmName, rdpHost, rdpUser, savedPCName, vmMAC, consoleEnabled, offeredAccessibility,
                          bitLockerOn, bitLockerCheckedAt, savedPCHost, passwordCheckedFor, keepBitLocker, noVisualTweaks,
                          declinedAutologon, declinedRemoteDesktop, declinedTuning,
                          sharedFolder, declinedSharedFolder, backupExclusionConfirmed, pendingUTMRestart,
                          lastUpdateCheck, lastSeenVersion]

        /// Everything that describes one VM. Switching VMs forgets these.
        static let perVM = [rdpHost, rdpUser, savedPCName, vmMAC, consoleEnabled, bitLockerOn, bitLockerCheckedAt,
                            savedPCHost, keepBitLocker, noVisualTweaks,
                            declinedAutologon, declinedRemoteDesktop, declinedTuning,
                            sharedFolder, declinedSharedFolder]
    }

    static var vmName: String? {
        get { nonEmpty(defaults.string(forKey: Key.vmName)) }
        set { set(newValue, Key.vmName) }
    }

    /// Explicitly configured host; nil means "derive it from the guest" (see `Context.rdpHost`).
    static var rdpHost: String? {
        get { nonEmpty(defaults.string(forKey: Key.rdpHost)) }
        set { set(newValue, Key.rdpHost) }
    }

    static var rdpUser: String? {
        get { nonEmpty(defaults.string(forKey: Key.rdpUser)) }
        set { set(newValue, Key.rdpUser) }
    }

    static var savedPCName: String? {
        get { nonEmpty(defaults.string(forKey: Key.savedPCName)) }
        set { set(newValue, Key.savedPCName) }
    }

    static var vmMAC: String? {
        get { nonEmpty(defaults.string(forKey: Key.vmMAC)) }
        set { set(newValue, Key.vmMAC) }
    }

    /// nil = never seen. Cached because the process arguments only say so while the VM runs.
    static var consoleEnabled: Bool? {
        get { defaults.object(forKey: Key.consoleEnabled) as? Bool }
        set { defaults.set(newValue, forKey: Key.consoleEnabled) }
    }

    static var offeredAccessibility: Bool {
        get { defaults.bool(forKey: Key.offeredAccessibility) }
        set { defaults.set(newValue, forKey: Key.offeredAccessibility) }
    }

    static var bitLockerOn: Bool? {
        get { defaults.object(forKey: Key.bitLockerOn) as? Bool }
        set { defaults.set(newValue, forKey: Key.bitLockerOn) }
    }

    static var bitLockerCheckedAt: Date? {
        get { defaults.object(forKey: Key.bitLockerCheckedAt) as? Date }
        set { defaults.set(newValue, forKey: Key.bitLockerCheckedAt) }
    }

    /// Records what Windows just reported about C:.
    static func recordBitLocker(on: Bool, at date: Date = Date()) {
        bitLockerOn = on
        bitLockerCheckedAt = date
    }

    static func forgetBitLocker() {
        defaults.removeObject(forKey: Key.bitLockerOn)
        defaults.removeObject(forKey: Key.bitLockerCheckedAt)
    }

    static var savedPCHost: String? {
        get { nonEmpty(defaults.string(forKey: Key.savedPCHost)) }
        set { set(newValue, Key.savedPCHost) }
    }

    /// Oldest first. A single string is what 0.1.0 development builds stored.
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
        get { defaults.bool(forKey: Key.keepBitLocker) }
        set { if newValue { defaults.set(true, forKey: Key.keepBitLocker) } else { defaults.removeObject(forKey: Key.keepBitLocker) } }
    }

    static var noVisualTweaks: Bool {
        get { defaults.bool(forKey: Key.noVisualTweaks) }
        set { if newValue { defaults.set(true, forKey: Key.noVisualTweaks) } else { defaults.removeObject(forKey: Key.noVisualTweaks) } }
    }

    /// Set by `winbar create` when its checklist row was unticked, and by `winbar config`. Only a
    /// true is stored, so a VM nobody declined anything for keeps a clean settings file.
    static var declinedAutologon: Bool {
        get { defaults.bool(forKey: Key.declinedAutologon) }
        set { setFlag(newValue, Key.declinedAutologon) }
    }

    static var declinedRemoteDesktop: Bool {
        get { defaults.bool(forKey: Key.declinedRemoteDesktop) }
        set { setFlag(newValue, Key.declinedRemoteDesktop) }
    }

    static var declinedTuning: Bool {
        get { defaults.bool(forKey: Key.declinedTuning) }
        set { setFlag(newValue, Key.declinedTuning) }
    }

    private static func setFlag(_ on: Bool, _ key: String) {
        if on { defaults.set(true, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    /// nil = UTM shares nothing with this VM, as far as Winbar last saw.
    static var sharedFolder: String? {
        get { nonEmpty(defaults.string(forKey: Key.sharedFolder)) }
        set { set(newValue, Key.sharedFolder) }
    }

    /// Whether setup already offered this VM a shared folder and was told no.
    static var declinedSharedFolder: Bool {
        get { defaults.bool(forKey: Key.declinedSharedFolder) }
        set { setFlag(newValue, Key.declinedSharedFolder) }
    }

    /// Records what UTM reported for `vm`, and only for the VM Winbar looks after: these keys say
    /// what the menu and doctor describe, so another VM's folder must not land in them.
    static func rememberSharedFolder(_ path: String?, for vm: String) {
        guard UTM.shouldCacheSettings(vm: vm, selected: vmName, asked: true) else { return }
        sharedFolder = path
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

    /// Switches to another VM. Everything cached or discovered belongs to the previous one, host and
    /// user included, so it all goes. Returns the keys that were cleared.
    @discardableResult
    static func selectVM(_ name: String) -> [String] {
        guard name != vmName else { return [] }
        let cleared = Key.perVM.filter { defaults.object(forKey: $0) != nil }
        Key.perVM.forEach { defaults.removeObject(forKey: $0) }
        vmName = name
        return cleared
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

    private static func set(_ value: String?, _ key: String) {
        if let value = nonEmpty(value) { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    private static func nonEmpty(_ value: String?) -> String? {
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
