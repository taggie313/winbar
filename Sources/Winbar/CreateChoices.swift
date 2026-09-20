import Foundation

/// The facts about this Mac that `winbar create`'s defaults depend on. Passed in, so the rules can be
/// tested for any Mac.
struct MacFacts: Equatable, Sendable {
    /// `hw.perflevel0.physicalcpu`: Super cores on M5, Performance cores on M1–M4.
    var topTierCores: Int
    /// Every core, all tiers (`hw.physicalcpu`).
    var totalCores: Int
    var memoryBytes: UInt64
    /// `NSUserName()`.
    var shortUserName: String

    static var current: MacFacts {
        let top = Host.topTierCores
        return MacFacts(topTierCores: top, totalCores: max(Host.sysctlInt("hw.physicalcpu") ?? top, top),
                        memoryBytes: Host.memoryBytes, shortUserName: NSUserName())
    }

    /// Whole GB, as the memory field shows it.
    var memoryGB: Int { Int(memoryBytes / (1 << 30)) }
}

/// A field value `winbar create` can't use. The text is the copy deck's; the window shows
/// it under the field, the CLI prints it and exits 65 (64 for a locked option).
enum ChoiceProblem: Error, Equatable, CustomStringConvertible {
    case nameEmpty, nameChars, nameLong, nameTaken(String)
    case userEmpty, userLong, userChars(String), userEdges, userReserved(String), userIsComputer
    case passwordEmpty, passwordLong, passwordControl, passwordMismatch
    case productKeyShape
    case computerChars, computerDigits, computerHyphen
    case coresRange(max: Int), memoryRange(max: Int), diskRange
    case locked(CreateOption)
    case noEdition(String, available: [String]), editionAmbiguous(String, matches: [String]), noEditions

    var description: String {
        switch self {
        case .nameEmpty: return "Name the VM."
        case .nameChars: return "VM names can't contain / or :, or start with a dot."
        case .nameLong: return "Keep the VM's name to 64 characters."
        case .nameTaken(let name): return "UTM already has a VM called “\(name)”. Pick another name."
        case .userEmpty: return "Type a user name."
        case .userLong: return "Windows user names are up to 20 characters."
        case .userChars(let chars): return "User names can't contain \(chars)."
        case .userEdges: return "User names can't start or end with a space, or end with a dot."
        case .userReserved(let name): return "Windows keeps “\(name)” for itself. Pick another user name."
        case .userIsComputer: return "The user name and the computer name have to differ."
        case .passwordEmpty: return "The password can't be empty: Remote Desktop refuses accounts without one."
        case .passwordLong: return "Windows passwords are up to 127 characters."
        case .passwordControl: return "Passwords can't contain control characters, such as a tab."
        case .passwordMismatch: return "The passwords don't match."
        case .productKeyShape:
            return "A Windows product key is 25 characters in five groups of five, from "
                + CreateChoices.productKeyAlphabet.map(String.init).joined(separator: " ")
                + ". Hyphens are optional, and case doesn't matter."
        case .computerChars: return "Up to 15 letters, digits and hyphens."
        case .computerDigits: return "A computer name can't be only digits."
        case .computerHyphen: return "A computer name can't start or end with a hyphen."
        case .coresRange(let max): return "vCPUs: 2 to \(max)."
        case .memoryRange(let max): return "Memory: 4 to \(max) GB."
        case .diskRange: return "Disk: 64 to 2048 GB. Windows 11 needs at least 64 GB."
        case .locked(.bypassRequirements):
            return "--no-bypass-requirements isn't possible: UTM can't add a TPM to a VM it creates by script, so Windows "
                + "Setup would stop with “This PC can't run Windows 11”. If you want a TPM, create the VM with UTM's own "
                + "wizard and run winbar setup afterwards."
        case .locked(.localAccount):
            return "--no-local-account isn't possible: Remote Desktop and automatic sign-in need a local account with a "
                + "real password, and the install runs offline, so there's no Microsoft account sign-in to fall back on. "
                + "You can add a Microsoft account to apps later."
        case .locked(.guestTools):
            return "--no-guest-tools isn't possible: the UTM Guest Tools carry Windows' network driver and the guest "
                + "agent Winbar talks to Windows through. Without them Winbar couldn't even tell when Windows had "
                + "finished installing."
        case .locked(let option): return "\(option.rawValue) is always on."
        case .noEdition(let name, let available):
            return "This ISO has no edition called “\(name)”. It has: \(available.joined(separator: ", "))."
        case .editionAmbiguous(let name, let matches):
            return "“\(name)” could be any of: \(matches.joined(separator: ", ")). Name one of them."
        case .noEditions: return "This ISO has no Windows editions to install."
        }
    }
}

/// Shown once, never blocking.
enum ChoiceWarning: Equatable, CustomStringConvertible {
    case home
    case coresHigh(topTier: Int)
    case memoryHigh(totalGB: Int)
    case memoryLow

    var description: String {
        switch self {
        case .home:
            return "Windows 11 Home can't accept Remote Desktop connections, so Winbar's Connect won't work with it, and "
                + "“Turn on Remote Desktop” is off. Choose Pro unless you have a reason not to. (A Pro product key can "
                + "upgrade Home later.)"
        case .coresHigh(let n):
            return "More vCPUs than your Mac's \(n) top-tier cores cost more host CPU and weren't faster in testing."
        case .memoryHigh(let total):
            return "That's more than half of this Mac's \(total) GB, so macOS may start swapping while the VM runs."
        case .memoryLow:
            return "Windows 11 is slow with less than 8 GB."
        }
    }
}

/// Defaults and rules for every field of `winbar create`, shared by the CLI and the window.
/// Pure: the Mac's facts, UTM's VM names and the ISO's editions come in as arguments.
enum CreateChoices {
    // MARK: - VM name

    static let baseVMName = "Windows 11"

    /// “Windows 11”; if UTM has it (in any letter case), “Windows 11 (2)”, “(3)”…
    static func defaultVMName(existing: [String]) -> String {
        let taken = Set(existing.map { $0.lowercased() })
        if !taken.contains(baseVMName.lowercased()) { return baseVMName }
        var n = 2
        while taken.contains("\(baseVMName) (\(n))".lowercased()) { n += 1 }
        return "\(baseVMName) (\(n))"
    }

    /// `existing` is UTM's VM names when known (nil: not checked yet). Case-insensitive, as the create
    /// script matches, so “win11” can't shadow “Win11” in `--vm` lookups.
    static func vmNameProblem(_ name: String, existing: [String]? = nil) -> ChoiceProblem? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .nameEmpty }
        if name.contains("/") || name.contains(":") || name.hasPrefix(".") { return .nameChars }
        if name.count > 64 { return .nameLong }
        if let existing, let clash = existing.first(where: { $0.lowercased() == name.lowercased() }) {
            return .nameTaken(clash)
        }
        return nil
    }

    // MARK: - User name

    /// Characters Windows refuses in a user name (its own list, plus % @ & "), and the
    /// braces, which Windows allows but the answer file's `{{VALUE}}` placeholders don't: a name with "{{"
    /// in it would come out of the renderer looking like a placeholder nothing filled.
    static let userNameForbidden: [Character] = ["/", "\\", "[", "]", ":", ";", "|", "=", ",", "+", "*", "?", "<", ">",
                                                 "%", "@", "&", "\"", "{", "}"]

    /// Accounts and groups Windows already has, compared ignoring case: Rufus's list (with the localised
    /// Administrator names), schneegans' and the local groups (D5), whose names make account creation fail.
    static let reservedUserNames: Set<String> = Set([
        "Administrator", "Järjestelmänvalvoja", "Administrateur", "Rendszergazda", "Administrador", "Администратор",
        "Administratör", "Guest", "DefaultAccount", "WDAGUtilityAccount", "HelpAssistant", "KRBTGT", "Local", "NONE",
        "SYSTEM", "Network Service", "Local Service", "defaultuser0",
        "Administrators", "Users", "Guests", "Power Users", "Remote Desktop Users", "Remote Management Users",
        "Backup Operators", "Network Configuration Operators", "Performance Log Users", "Performance Monitor Users",
        "Distributed COM Users", "Event Log Readers", "Hyper-V Administrators", "IIS_IUSRS", "Cryptographic Operators",
        "Device Owners", "Access Control Assistance Operators", "Replicator", "OpenSSH Users",
    ].map { $0.lowercased() })

    static func isReservedUserName(_ name: String) -> Bool { reservedUserNames.contains(name.lowercased()) }

    /// The Mac short name with the characters Windows refuses replaced by `_`, cut to 20; empty when that
    /// still isn't a usable Windows name (a reserved one, say), so the person picks one.
    static func defaultUserName(macShortName: String) -> String {
        let cleaned = String(macShortName.unicodeScalars.map { scalar -> Character in
            let c = Character(scalar)
            return userNameForbidden.contains(c) || scalar.value < 32 || scalar.value == 127 ? "_" : c
        }.prefix(20))
        return userNameProblem(cleaned) == nil ? cleaned : ""
    }

    /// `computerName`, when given, must differ from the user name (case-insensitive).
    static func userNameProblem(_ name: String, computerName: String? = nil) -> ChoiceProblem? {
        if name.isEmpty { return .userEmpty }
        if name.unicodeScalars.count > 20 { return .userLong }
        let bad = userNameForbidden.filter { name.contains($0) }
        if !bad.isEmpty { return .userChars(listed(bad.map(String.init))) }
        if name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) { return .userChars("control characters") }
        // This also covers names of only dots and spaces.
        if name != name.trimmingCharacters(in: .whitespaces) || name.hasSuffix(".") { return .userEdges }
        if isReservedUserName(name) { return .userReserved(name) }
        if let computerName, !computerName.isEmpty, computerName.lowercased() == name.lowercased() { return .userIsComputer }
        return nil
    }

    // MARK: - Password

    /// Not empty (Remote Desktop refuses blank passwords), at most 127 characters, no control characters.
    /// No strength rules: in Shared Network mode the VM is reachable from this Mac and from other VMs on
    /// the shared network; Bridged would expose it to the LAN (the answer file opens the Remote Desktop
    /// firewall group for `<Profile>all</Profile>`). What carries that to the person is D4's line before
    /// the prompt, "Pick a password you don't use for your Mac or anywhere else.", not a rule here.
    static func passwordProblem(_ password: String, confirmation: String? = nil) -> ChoiceProblem? {
        if password.isEmpty { return .passwordEmpty }
        if password.unicodeScalars.count > 127 { return .passwordLong }
        if password.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) { return .passwordControl }
        if let confirmation, confirmation != password { return .passwordMismatch }
        return nil
    }

    // MARK: - Product key

    /// Microsoft's product-key alphabet: the classic Base24 set, which leaves out every character a person could
    /// misread for another (A E I L O S U Z, and 0 1 5), plus N.
    ///
    /// N is in it. Every Windows 8-and-later key uses N — Microsoft's own generic keys do (`VK7JG-NPHTM-…` for
    /// Pro, `YTMG3-N6DKC-…` for Home), and so do retail keys — so leaving it out would refuse the very keys this
    /// is for. Nothing else is added: a key is checked for shape only.
    static let productKeyAlphabet = "BCDFGHJKMNPQRTVWXY2346789"

    private static let productKeyCharacters = Set(productKeyAlphabet)

    /// A product key in the form the answer file takes it: five groups of five, upper case, hyphenated. Hyphens
    /// and spaces are optional on the way in and case doesn't matter, so a key read off a sticker or pasted from
    /// an email is accepted as typed. nil when it isn't a product key at all.
    ///
    /// The shape is all that can be checked. Which edition a key unlocks isn't in the key, so Winbar doesn't
    /// guess: Windows Setup refuses a key that isn't for the edition being installed, and guessing here would
    /// refuse a key that would have worked.
    static func normalizedProductKey(_ typed: String) -> String? {
        let stripped = Array(typed.uppercased().filter { !$0.isWhitespace && $0 != "-" })
        guard stripped.count == 25, stripped.allSatisfy(productKeyCharacters.contains) else { return nil }
        return stride(from: 0, to: 25, by: 5).map { String(stripped[$0..<($0 + 5)]) }.joined(separator: "-")
    }

    /// Nothing typed is no problem: the key is optional, and without one Windows installs unactivated.
    static func productKeyProblem(_ typed: String) -> ChoiceProblem? {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        return normalizedProductKey(trimmed) == nil ? .productKeyShape : nil
    }

    // MARK: - Computer name

    /// The computer_name field's default: fold accents, drop apostrophes, turn every other
    /// run of characters outside A–Z a–z 0–9 into one "-", trim "-" from both ends, cut to 15 and trim a
    /// trailing "-" again. Empty → Windows-VM; only digits → VM-<digits>; equal to the user name → cut to
    /// 12 plus "-PC". The Python renderer's `derive_computer_name` does the same, and the tests hold them together.
    static func deriveComputerName(vmName: String, userName: String) -> String {
        let apostrophes: Set<Unicode.Scalar> = ["'", "\u{2018}", "\u{2019}", "\u{02BC}"]
        var name = ""
        var pendingHyphen = false
        // NFKD, then without combining marks: "é" is "e" plus a mark, and full-width letters become ASCII.
        for scalar in vmName.decomposedStringWithCompatibilityMapping.unicodeScalars {
            if scalar.properties.canonicalCombiningClass != .notReordered || apostrophes.contains(scalar) { continue }
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                if pendingHyphen, !name.isEmpty { name += "-" }
                pendingHyphen = false
                name.unicodeScalars.append(scalar)
            } else {
                pendingHyphen = true
            }
        }
        name = trimTrailingHyphens(String(name.prefix(15)))
        if name.isEmpty {
            name = "Windows-VM"
        } else if name.allSatisfy(\.isASCIIDigit) {
            name = String(("VM-" + name).prefix(15))
        }
        if name.lowercased() == userName.lowercased() {
            name = trimTrailingHyphens(String(name.prefix(12))) + "-PC"
        }
        return name
    }

    private static func trimTrailingHyphens(_ s: String) -> String {
        var s = s
        while s.hasSuffix("-") { s.removeLast() }
        return s
    }

    /// 1 to 15 of A–Z a–z 0–9 and "-"; not only digits; no "-" at either end; not the user name.
    static func computerNameProblem(_ name: String, userName: String? = nil) -> ChoiceProblem? {
        if name.isEmpty || name.count > 15 || !name.allSatisfy({ $0.isASCIILetterOrDigit || $0 == "-" }) { return .computerChars }
        if name.hasPrefix("-") || name.hasSuffix("-") { return .computerHyphen }
        if name.allSatisfy(\.isASCIIDigit) { return .computerDigits }
        if let userName, !userName.isEmpty, userName.lowercased() == name.lowercased() { return .userIsComputer }
        return nil
    }

    /// How the Mac reaches the VM: the computer name, lowercased, plus .local (what rdpHost defaults to).
    static func hostName(computerName: String) -> String { computerName.lowercased() + ".local" }

    // MARK: - Sizing (winbar setup's H3 and H4, so create and setup agree)

    static func suggestedCores(_ mac: MacFacts) -> Int { Tuning.recommendedCPUs(topTierCores: mac.topTierCores) }

    /// 2 to every core the Mac has.
    static func coresRange(_ mac: MacFacts) -> ClosedRange<Int> { 2...max(2, mac.totalCores) }

    static func coresProblem(_ cores: Int, mac: MacFacts) -> ChoiceProblem? {
        coresRange(mac).contains(cores) ? nil : .coresRange(max: coresRange(mac).upperBound)
    }

    /// Above the suggestion: more vCPUs cost host CPU without being faster.
    static func coresWarning(_ cores: Int, mac: MacFacts) -> ChoiceWarning? {
        cores > suggestedCores(mac) ? .coresHigh(topTier: mac.topTierCores) : nil
    }

    /// 16 GB from 64 GB of Mac memory, 12 GB from 32 GB, else 8 GB, never more than half.
    static func suggestedMemoryGB(_ mac: MacFacts) -> Int {
        max(1, Tuning.recommendedMemoryMB(hostBytes: mac.memoryBytes) / 1024)
    }

    /// 4 GB to the Mac's memory less 4 GB, whole GB.
    static func memoryRangeGB(_ mac: MacFacts) -> ClosedRange<Int> { 4...max(4, mac.memoryGB - 4) }

    static func memoryProblem(_ gb: Int, mac: MacFacts) -> ChoiceProblem? {
        memoryRangeGB(mac).contains(gb) ? nil : .memoryRange(max: memoryRangeGB(mac).upperBound)
    }

    static func memoryWarnings(_ gb: Int, mac: MacFacts) -> [ChoiceWarning] {
        var warnings: [ChoiceWarning] = []
        if gb * 2 > mac.memoryGB { warnings.append(.memoryHigh(totalGB: mac.memoryGB)) }
        if gb < 8 { warnings.append(.memoryLow) }
        return warnings
    }

    static let defaultDiskGB = 128
    /// Windows 11's own minimum (the bypass doesn't remove it) to 2 TB. The disk file grows as Windows uses it.
    static let diskRangeGB = 64...2048

    static func diskProblem(_ gb: Int) -> ChoiceProblem? { diskRangeGB.contains(gb) ? nil : .diskRange }

    // MARK: - Edition

    /// Pro; without Pro, the first edition that isn't Home; with only Home editions, the first of them and
    /// `homeOnly` (the window shows W_HOME, the CLI asks W_HOME_CONFIRM, and `--yes` alone refuses). Home is
    /// otherwise only used when named.
    static func defaultEdition(_ editions: [WindowsEdition]) -> (edition: WindowsEdition, homeOnly: Bool)? {
        if let pro = editions.first(where: { $0.editionID == "Professional" }) { return (pro, false) }
        if let other = editions.first(where: { !$0.isHome }) { return (other, false) }
        return editions.first.map { ($0, true) }
    }

    /// `--edition NAME`, ignoring case: the full name (“Windows 11 Pro”), the name without “Windows 11 ”
    /// (“Pro”, “Home Single Language”), the EditionID (“Professional”, “Core”) or the image index. An exact
    /// match wins over a prefix; two or more matches of the same kind are refused rather than guessed.
    static func matchEdition(_ query: String, in editions: [WindowsEdition]) throws -> WindowsEdition {
        guard !editions.isEmpty else { throw ChoiceProblem.noEditions }
        let wanted = query.trimmingCharacters(in: .whitespaces).lowercased()
        func names(_ e: WindowsEdition) -> [String] {
            var keys = [e.name, e.editionID]
            let prefix = "windows 11 "
            if e.name.lowercased().hasPrefix(prefix) { keys.append(String(e.name.dropFirst(prefix.count))) }
            return keys.map { $0.lowercased() }
        }
        func unique(_ found: [WindowsEdition]) throws -> WindowsEdition? {
            var seen = Set<Int>()
            let distinct = found.filter { seen.insert($0.index).inserted }
            if distinct.count > 1 { throw ChoiceProblem.editionAmbiguous(query, matches: distinct.map(\.name)) }
            return distinct.first
        }
        if !wanted.isEmpty {
            if let exact = try unique(editions.filter { names($0).contains(wanted) || String($0.index) == wanted }) { return exact }
            if let prefix = try unique(editions.filter { names($0).contains { $0.hasPrefix(wanted) } }) { return prefix }
        }
        throw ChoiceProblem.noEdition(query, available: editions.map(\.name))
    }

    // MARK: - Rules between options

    /// The Python renderer's `effective()` on a plan: locked options must be on (refused otherwise); the visual-tweaks
    /// modifier only means something with tuning; a Home edition can't host Remote Desktop, so it's turned off
    /// with W_HOME; with regional off there are no Mac values (the renderer uses the image language). The
    /// answer-file renderer applies the same rules again to what it's given.
    static func effective(_ plan: CreatePlan) throws -> (plan: CreatePlan, warnings: [ChoiceWarning]) {
        if let off = CreateOption.allCases.first(where: { $0.isLocked && !plan.has($0) }) { throw ChoiceProblem.locked(off) }
        var plan = plan
        var warnings: [ChoiceWarning] = []
        if !plan.has(.winbarTuning) { plan.noVisualTweaks = false }
        if plan.edition.isHome {
            warnings.append(.home)
            plan.options.remove(.remoteDesktop)
        }
        if !plan.has(.regionalFromMac) { plan.regional = nil }
        return (plan, warnings)
    }

    /// Every field problem in a plan, in the order the fields appear (UTM's names and the Mac's facts when
    /// known). Empty means it can be rendered.
    static func problems(in plan: CreatePlan, mac: MacFacts?, existingVMs: [String]? = nil) -> [ChoiceProblem] {
        var found: [ChoiceProblem?] = [vmNameProblem(plan.vmName, existing: existingVMs)]
        if let mac {
            found += [coresProblem(plan.cores, mac: mac), memoryProblem(plan.memoryMiB / 1024, mac: mac)]
        }
        found += [diskProblem(plan.diskGiB),
                  userNameProblem(plan.userName, computerName: plan.computerName),
                  computerNameProblem(plan.computerName)]
        if let off = CreateOption.allCases.first(where: { $0.isLocked && !plan.has($0) }) { found.append(.locked(off)) }
        return found.compactMap { $0 }
    }

    /// “a, b or c”.
    private static func listed(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: " ") + " or " + items.last!
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
    var isASCIILetterOrDigit: Bool { isASCII && (isLetter || isNumber) }
}
