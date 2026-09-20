import Foundation

/// What never reaches a diagnostic report, and what `--anonymise` takes out on top.
///
/// Two jobs, deliberately kept apart:
///
/// · **Secrets go always.** Nothing Winbar writes is supposed to hold one — the Windows password is
///   never logged, and `AnswerFileTests` proves the answer file doesn't carry it either — but this
///   file is assembled from Windows' own first-logon log, UTM's crash reports and whatever a
///   person's settings hold, and "supposed to" is not a thing to hand someone on the internet. So
///   every line of the report is swept for the shapes a secret takes, whichever section it came
///   from, and `RedactionTests` proves it on a report built out of fixtures that are full of them.
///
/// · **Identity goes when asked.** Host names, a Mac user name, VM names and the paths they appear
///   in are not secrets, and leaving them in makes a report far easier to read and to answer. So
///   `--anonymise` is a choice, and the report says at the top which choice made it.
///
/// Nothing here is clever: a literal replacement and a handful of patterns. A pattern that guessed
/// would be worse than none, because a report nobody trusts is a report nobody sends.
struct Redactor {
    enum Mode: String {
        case verbatim
        case anonymised
    }

    /// The names that say whose Mac this is. Gathered by `Diagnose`; a value here so the rules can
    /// be tested without a Mac.
    struct Identity: Equatable {
        var userName: String?
        var fullUserName: String?
        var computerName: String?
        /// `ProcessInfo.hostName` and friends — often the computer name with `.local` after it.
        var hostNames: [String] = []
        var vmNames: [String] = []
        /// The account inside Windows. Not on the list of things `--anonymise` promises, but it is
        /// a person's name, it is in the doctor table twice and in the settings twice, and leaving
        /// it in would make the promise a thin one.
        var windowsUsers: [String] = []

        static let none = Identity()
    }

    let mode: Mode
    /// Needle → placeholder, longest needle first so `atelier.local` is dealt with before `atelier`.
    let replacements: [(needle: String, placeholder: String)]
    /// Names left alone because replacing them would have mangled ordinary words. The report says so
    /// rather than claiming an anonymity it doesn't have.
    let kept: [String]

    /// A name has to be this long before it is worth replacing. A two-letter user name appears
    /// inside half the words in the file, and a report with every "at" turned into `<user>` is
    /// unreadable and no more anonymous.
    static let shortestReplaceable = 3

    init(mode: Mode, identity: Identity = .none) {
        self.mode = mode
        guard mode == .anonymised else {
            replacements = []
            kept = []
            return
        }
        var wanted: [(String, String)] = []
        if let user = Self.clean(identity.userName) { wanted.append((user, "<user>")) }
        if let full = Self.clean(identity.fullUserName) { wanted.append((full, "<user-full-name>")) }
        if let computer = Self.clean(identity.computerName) { wanted.append((computer, "<mac>")) }
        for host in identity.hostNames.compactMap(Self.clean) { wanted.append((host, "<mac>")) }
        // Sorted and then numbered, so the same VM is `<vm-1>` in every report from this Mac.
        for (index, vm) in identity.vmNames.compactMap(Self.clean).sorted().enumerated() {
            wanted.append((vm, "<vm-\(index + 1)>"))
        }
        for (index, user) in identity.windowsUsers.compactMap(Self.clean).sorted().enumerated() {
            wanted.append((user, "<windows-user-\(index + 1)>"))
        }

        var seen = Set<String>()
        var usable: [(needle: String, placeholder: String)] = []
        var tooShort: [String] = []
        for (needle, placeholder) in wanted {
            guard seen.insert(needle.lowercased()).inserted else { continue }
            if needle.count >= Self.shortestReplaceable {
                usable.append((needle, placeholder))
            } else {
                tooShort.append(needle)
            }
        }
        // Longest first: a host name that contains the computer name has to be replaced whole, or
        // what's left of it is `<mac>.local` at best and a half-replaced name at worst.
        replacements = usable.sorted { $0.needle.count > $1.needle.count }
        kept = tooShort
    }

    private static func clean(_ name: String?) -> String? {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        return name
    }

    /// Everything that happens to a piece of text on its way into the report: secrets always,
    /// identity when anonymising. Applied to the whole file at the end rather than to each section,
    /// so a section added later can't be the one that forgot.
    func apply(_ text: String) -> String {
        var result = Redactor.withoutSecrets(text)
        for (needle, placeholder) in replacements {
            result = Redactor.replacingWholeWords(needle, with: placeholder, in: result)
        }
        return result
    }

    /// A name replaced where it stands on its own, and left alone where it is part of a longer word.
    ///
    /// Not a plain substring replacement, which is how a user whose short name began the repository's
    /// own name turned `<name>313/winbar` into `<user>313/winbar` in the first draft of this. The test is the
    /// character either side: a letter or a digit next to the match means this is some other word
    /// that happens to contain the name. Letters and digits rather than `\b`, because a VM may be
    /// called `win-11` and `\b` would then take its own hyphen for the boundary.
    static func replacingWholeWords(_ needle: String, with placeholder: String, in text: String) -> String {
        let pattern = "(?i)(?<![A-Za-z0-9])" + NSRegularExpression.escapedPattern(for: needle) + "(?![A-Za-z0-9])"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                              withTemplate: NSRegularExpression.escapedTemplate(for: placeholder))
    }

    /// One line for the top of the report, so nobody has to guess what they are about to send.
    var explanation: String {
        switch mode {
        case .verbatim:
            return "Mode: verbatim — VM names, this Mac's name, your user name and file paths appear as they are. "
                + "Run winbar diagnose --anonymise for a copy with those replaced."
        case .anonymised:
            var text = "Mode: anonymised — this Mac's name, your Mac and Windows user names and the VM names have been "
                + "replaced with <mac>, <user>, <windows-user-1> and <vm-1>, <vm-2>… Everything else is as it was, "
                + "and a name is only replaced where it stands on its own."
            if !kept.isEmpty {
                text += " These were too short to replace without mangling ordinary words, and are still here: "
                    + kept.joined(separator: ", ") + "."
            }
            return text
        }
    }

    // MARK: - Secrets

    /// The shapes a secret takes in a log. Each one is a pattern and what replaces it.
    ///
    /// Deliberately narrow. Every rule needs a label (`password=`, `--token`) or a prefix the
    /// issuer itself puts there (`ghp_`, `AKIA`), because a rule that went looking for
    /// "something that looks random" would eat serial numbers, UUIDs, certificate thumbprints and
    /// MAC addresses — the very things a bug report is made of.
    ///
    /// Note what is *not* here: a bare word with nothing to say it is a password can't be found, so
    /// the rule that matters more is the one the rest of Winbar already keeps — never write one
    /// down. This is the second lock, not the first.
    static let secretRules: [(pattern: String, template: String)] = [
        // A private key, whole, however many lines it runs to.
        ("-----BEGIN [A-Z ]*PRIVATE KEY-----[\\s\\S]*?-----END [A-Z ]*PRIVATE KEY-----", "<private key removed>"),
        // A Windows product key: five groups of five. Not a UUID (8-4-4-4-12) and not a MAC.
        ("\\b[A-Z0-9]{5}(?:-[A-Z0-9]{5}){4}\\b", "<product key removed>"),
        // Tokens that announce themselves.
        ("\\b(?:gh[pousr]_[A-Za-z0-9]{16,}|sk-[A-Za-z0-9_-]{16,}|xox[abprs]-[A-Za-z0-9-]{10,}"
            + "|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{20,})\\b", "<token removed>"),
        // Labelled, with a colon or an equals: password=…, "Password: …", client_secret = '…'.
        ("(?i)\\b(password|passwd|pwd|passphrase|secret|client[ _-]?secret|token|credential"
            + "|api[ _-]?key|access[ _-]?key|private[ _-]?key|product[ _-]?key|license[ _-]?key)"
            + "\\b[\"']?\\s*[:=]\\s*(\"[^\"\\n]*\"|'[^'\\n]*'|\\S+)", "$1=<removed>"),
        // Passed as a flag: -Password 'x', --token x. A space is enough here because the dash says
        // this is an argument and not a sentence with the word "password" in it.
        ("(?i)(--?)(password|passwd|pwd|passphrase|secret|token|key)\\b\\s+(\"[^\"\\n]*\"|'[^'\\n]*'|[^\\s\"']\\S*)",
         "$1$2 <removed>"),
        // An email address: not a secret, but it is someone's, and it is never a fact about a VM.
        ("[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\\.[A-Za-z0-9-]+)*\\.[A-Za-z]{2,}", "<email removed>"),
    ]

    private static let compiled: [(regex: NSRegularExpression, template: String)] = secretRules.compactMap {
        guard let regex = try? NSRegularExpression(pattern: $0.pattern) else { return nil }
        return (regex, $0.template)
    }

    /// The sweep itself. Always applied, whatever the mode.
    static func withoutSecrets(_ text: String) -> String {
        var result = text
        for (regex, template) in compiled {
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result),
                                                    withTemplate: template)
        }
        return result
    }
}
