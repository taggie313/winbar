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
/// · **Identity goes when asked.** Host names, a Mac user name, VM names, the ids and MAC addresses
///   those VMs have, the Windows machine name inside them, and the paths and settings keys all of
///   them appear in are not secrets, and leaving them in makes a report far easier to read and to
///   answer. So `--anonymise` is a choice, and the report says at the top which choice made it.
///
/// Nothing here is clever: a literal replacement, two shapes, and a handful of patterns. A pattern
/// that guessed would be worse than none, because a report nobody trusts is a report nobody sends.
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
        /// The id UTM gave a VM, by the name that VM is known under — `9F3C…4E5F` → `winlab01`.
        ///
        /// A map rather than a list, because an id is only worth masking as an id if the report
        /// still says *which* VM it belongs to: it is the settings key prefix (`vm.<id>.rdpUser`),
        /// the `vmID` two lines above it and the VM's name in three lines of the create log, and a
        /// reader who can't join those up has lost the whole diagnostic value of it. So the id
        /// takes its VM's number — `<vm-1-id>` beside `<vm-1>` — and an id nothing can name is left
        /// out of here on purpose, for the shape rule to number as an id of its own.
        var vmIDs: [String: String] = [:]
        /// The MAC address of a VM's network card, by the name that VM is known under.
        ///
        /// The same argument as the id, one step stronger. A MAC is globally unique by design, it
        /// outlives the VM being renamed *and* re-registered with UTM, it is the handle on the DHCP
        /// lease the whole of `RDP` turns on — and it is in this file, under `vmMAC`, whose entire
        /// purpose is to be attached to a public issue. Numbered for its VM, `<vm-1-mac>`, for the
        /// same reason the id is: the settings section has to keep saying which VM it is about.
        var vmMACs: [String: String] = [:]
        /// The account inside Windows. Not named by `winbar help`'s one-line summary of the flag,
        /// but it is a person's name, it is in the doctor table twice and in the settings twice, and
        /// leaving it in would make the promise a thin one. The report's own mode line, the menu
        /// alert and the README all say it is replaced, because it is.
        var windowsUsers: [String] = []
        /// The machine name Windows knows itself by — `COMPUTERNAME`, and the DNS host name beside
        /// it when they differ.
        ///
        /// It reaches the report in `passwordCheckedFor`, which is written as `COMPUTERNAME\USER`,
        /// and in the RDP host derived from the DNS name. On the Mac this was written on the two
        /// names happen to be the same, so it *looked* masked by the VM's name; on a default
        /// install it is `DESKTOP-4F8J2K1` and nothing was replacing it at all. A coincidence on one
        /// Mac is not a rule, and this is the rule.
        var windowsPCNames: [String] = []

        static let none = Identity()
    }

    let mode: Mode
    /// Every literal needle, in the order the one pass below tries them: the ids and MAC addresses
    /// Winbar can name first, then the names, longest first so `atelier.local` is dealt with before
    /// `atelier`. The order is load-bearing — see `pass`.
    let replacements: [(needle: String, placeholder: String)]
    /// Names left alone because replacing them would have mangled ordinary words. The report says so
    /// rather than claiming an anonymity it doesn't have.
    let kept: [String]

    /// The one regular expression `apply` runs, compiled once. nil in verbatim mode, where nothing
    /// is replaced at all.
    private let pass: NSRegularExpression?
    /// Needle → placeholder for every literal needle in `replacements`, keyed by `key(_:)` — which
    /// is how a match is turned back into what it was, whichever composition, case and line breaking
    /// the program that printed it used.
    private let placeholders: [String: String]

    /// A name has to be this long before it is worth replacing. A two-letter user name appears
    /// inside half the words in the file, and a report with every "at" turned into `<user>` is
    /// unreadable and no more anonymous.
    static let shortestReplaceable = 3

    init(mode: Mode, identity: Identity = .none) {
        self.mode = mode
        guard mode == .anonymised else {
            replacements = []
            kept = []
            pass = nil
            placeholders = [:]
            return
        }

        // 1. The names. Every one of these is somebody's word rather than a shape, so all of them
        //    are literal needles and none of them may be guessed at.
        var names: [(String, String)] = []
        if let user = Self.clean(identity.userName) { names.append((user, "<user>")) }
        if let full = Self.clean(identity.fullUserName) { names.append((full, "<user-full-name>")) }
        if let computer = Self.clean(identity.computerName) { names.append((computer, "<mac>")) }
        for host in identity.hostNames.compactMap(Self.clean) { names.append((host, "<mac>")) }
        // Sorted and then numbered, so the same VM is `<vm-1>` in every report from this Mac.
        var numberOfVM: [String: Int] = [:]
        for (index, vm) in identity.vmNames.compactMap(Self.clean).sorted().enumerated() {
            names.append((vm, "<vm-\(index + 1)>"))
            // First wins, matching the dedupe below, so a name listed twice keeps one number.
            if numberOfVM[Self.key(vm)] == nil { numberOfVM[Self.key(vm)] = index + 1 }
        }
        for (index, user) in identity.windowsUsers.compactMap(Self.clean).sorted().enumerated() {
            names.append((user, "<windows-user-\(index + 1)>"))
        }
        // After the VM names on purpose: on a Mac where Windows was named after its VM the two
        // needles are the same string, and the dedupe below keeps the first. `<vm-1>` is the more
        // useful of the two placeholders, because the id and the MAC are numbered to match it.
        for (index, pc) in identity.windowsPCNames.compactMap(Self.clean).sorted().enumerated() {
            names.append((pc, "<windows-pc-\(index + 1)>"))
        }

        var seen = Set<String>()
        var usableNames: [(needle: String, placeholder: String)] = []
        var tooShort: [String] = []
        for (needle, placeholder) in names {
            guard seen.insert(Self.key(needle)).inserted else { continue }
            if needle.count >= Self.shortestReplaceable {
                usableNames.append((needle, placeholder))
            } else {
                tooShort.append(needle)
            }
        }
        // Longest first: a host name that contains the computer name has to be replaced whole, or
        // what's left of it is `<mac>.local` at best and a half-replaced name at worst.
        usableNames.sort { $0.needle.count > $1.needle.count }

        // Which `<vm-N>` placeholders actually reach the file. An id or a MAC numbered for a VM
        // whose name never appears is a pointer to nothing: `<vm-1-id>` beside no `<vm-1>` asks the
        // reader to join up two things when only one of them is there. That happens for a VM called
        // `jo` — too short to replace, so it is published as itself and `kept` says so — and for one
        // whose name is also the Mac user's, where the dedupe above kept `<user>`. Either way the id
        // and the MAC fall through to the shape rules below and are numbered honestly as their own.
        let placedVMs = Set(usableNames.map(\.placeholder))

        // 2. The ids and MAC addresses Winbar can put a VM's number on. These go *before* the shape
        //    rules in the alternation, which is the whole of how they keep their number.
        var known: [(needle: String, placeholder: String)] = []
        func claim(_ value: String?, of vm: String?, suffix: String) -> Int? {
            guard let value = Self.clean(value), let name = Self.clean(vm),
                  let number = numberOfVM[Self.key(name)],
                  placedVMs.contains("<vm-\(number)>"),
                  // A namespace that *is* the VM's name is a record written before Winbar knew the
                  // id. It is a name, and `<vm-N>` has already claimed it; calling it an id as well
                  // would put the same needle in the list twice and leave which placeholder wins to
                  // append order.
                  value.caseInsensitiveCompare(name) != .orderedSame,
                  seen.insert(Self.key(value)).inserted else { return nil }
            known.append((value, "<vm-\(number)-\(suffix)>"))
            return number
        }
        // An id inherits its VM's number instead of being numbered by its own sort order. Sorting
        // the ids would pair them off at random — `atelier` (id F1…) and `winlab01` (id 0A…) would
        // print as `<vm-1>` and `<vm-1-id>` while belonging to different VMs, which is worse than
        // not masking them at all. Sorted by id only so the list itself is the same every run.
        for (id, vm) in identity.vmIDs.sorted(by: { $0.key < $1.key }) {
            guard let number = claim(id, of: vm, suffix: "id") else { continue }
            // The same id, written the other way. See `idPattern`: the registry and some of UTM's
            // own output drop the hyphens, and a reader should see one VM either way round.
            let unbroken = id.replacingOccurrences(of: "-", with: "")
            if unbroken != id, seen.insert(Self.key(unbroken)).inserted {
                known.append((unbroken, "<vm-\(number)-id>"))
            }
        }
        for (mac, vm) in identity.vmMACs.sorted(by: { $0.key < $1.key }) {
            guard let number = claim(mac, of: vm, suffix: "mac") else { continue }
            // The same card, in the other three spellings — see `macPattern`. Winbar's own settings
            // hold the colon form, because that is what UTM and QEMU write; Windows' own tools write
            // `52-54-00-AB-CD-EF`, a registry value and a lease file write `525400ABCDEF`, and
            // switch firmware writes `5254.00ab.cdef`. The VM's own MAC was a known needle in one
            // spelling only, so the other three fell through to the shape rule and lost this VM's
            // number — or, before the shape rule knew them, were published.
            for spelling in Self.macSpellings(of: mac) where seen.insert(Self.key(spelling)).inserted {
                known.append((spelling, "<vm-\(number)-mac>"))
            }
        }
        known.sort { $0.needle.count > $1.needle.count }

        replacements = known + usableNames
        kept = tooShort

        var byNeedle: [String: String] = [:]
        for (needle, placeholder) in replacements where byNeedle[Self.key(needle)] == nil {
            byNeedle[Self.key(needle)] = placeholder
        }
        placeholders = byNeedle

        // The alternation, in the order that makes precedence fall out of the ordering — see
        // `apply`. The shapes are in it even when there is not one name to replace, because an id
        // or a MAC that nothing on this Mac could place is exactly the one that has to go.
        //
        // The boundary is per alternative rather than around the whole group, so that one of them
        // can legitimately go without it. A known card written unbroken — twelve hex characters, no
        // separators — is matched with no boundary at all, because those twelve characters ARE that
        // card whatever happens to sit beside them. With the shared boundary, one stray hex digit
        // next to it (`525400abcdef0`) refused the whole run and published the card: proven by
        // `theKnownCardSurvivesAnAdjoiningHexDigit`, which failed before this line existed.
        //
        // The three separated spellings keep their boundary and take a longer run whole (`{5,}`,
        // `{2,}`); the unbroken SHAPE keeps its boundary too, so a hash is not read as a card. Only
        // the known value is exempt, and the worst it can do is over-mask: a longer hex run that
        // happens to contain this Mac's own card is partly replaced, which costs a reader a puzzle
        // and costs the owner nothing.
        func bounded(_ pattern: String) -> String { Self.boundaryBefore + pattern + Self.boundaryAfter }
        let alternatives = known.map { needle -> String in
            let escaped = Self.pattern(for: needle.needle)
            return Self.isUnbrokenMAC(needle.needle) ? escaped : bounded(escaped)
        }
            + [bounded(Self.idPattern), bounded(Self.macPattern)]
            + usableNames.map { bounded(Self.pattern(for: $0.needle)) }
        pass = try? NSRegularExpression(pattern: "(?i)(?:" + alternatives.joined(separator: "|") + ")")
    }

    /// A needle as it is filed: trimmed, and canonically *composed*.
    ///
    /// Composition, because the same name is two different strings depending on who wrote it down.
    /// `NSFullUserName()` hands back `Renée` precomposed (NFC, one `é`); an APFS path carries the
    /// same name decomposed (NFD, `e` followed by a combining acute), and so does anything read back
    /// off the disk or out of a log written from a path. `"Renée" == "Rene\u{0301}e"` is true in
    /// Swift — `String` compares canonically — but `NSRegularExpression` is not Swift's `String`: it
    /// works on UTF-16 code units, `UREGEX_CANON_EQ` was never implemented in ICU, and so a
    /// precomposed needle matched nothing in decomposed text and the whole name was published.
    ///
    /// Two ways out, and this file takes the second. **Normalising the report** would have worked —
    /// compose the text, compose the needle, match — but it rewrites every line of a file whose
    /// entire job is to reproduce what other programs printed, including the ones whose bug is that
    /// they mangled a name; a report that quietly recomposes UTM's output is a report that can't be
    /// used to prove UTM decomposed it. So the *text is left exactly as it arrived*, and the needle
    /// is widened instead: filed composed here, and matched in both forms by `spellings`. The cost
    /// is a longer pattern; the benefit is that nothing but the matches is ever touched.
    private static func clean(_ name: String?) -> String? {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        return name.precomposedStringWithCanonicalMapping
    }

    /// The form a needle is filed and looked back up under: composed, whitespace collapsed to one
    /// space, lowercased.
    ///
    /// All three because `apply` looks a *match* up here, and a match need not be spelled the way
    /// the needle was: decomposed (see `clean`), cased however the program that printed it felt
    /// like, and — for a name with a space in it — broken across a line by `DiagnoseReport.wrap`.
    /// Collapsing whitespace is what makes `Rosa\nMarchetti` find `Rosa Marchetti`'s placeholder.
    static func key(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased()
    }

    /// Every spelling of one literal needle that has to be matched: composed and decomposed. The
    /// same string for anything ASCII, which is nearly every needle, and then one alternative is
    /// emitted rather than two.
    ///
    /// Compared by UTF-16 code unit and not with `==`, which is the trap this whole business is:
    /// Swift's `String` compares canonically, so `"Renée" == "Rene\u{0301}e"` is *true* and a guard
    /// written that way decides the two forms are the same and emits one — the one
    /// `NSRegularExpression`, which does not compare canonically, cannot find. The first draft of
    /// this fix did exactly that and was as broken as what it replaced.
    private static func spellings(of needle: String) -> [String] {
        let composed = needle.precomposedStringWithCanonicalMapping
        let decomposed = needle.decomposedStringWithCanonicalMapping
        return Array(composed.utf16) == Array(decomposed.utf16) ? [composed] : [composed, decomposed]
    }

    /// One literal needle, as the pattern that finds it however this file's own layout wrote it
    /// down. Three things happen to it, and each is a bug that reached a published report:
    ///
    /// · **Both composition forms** (see `clean`), so an accented name matches whichever way it is
    ///   spelled.
    ///
    /// · **A space becomes `\s+`.** `fullUserName` and `computerName` are the two needles that
    ///   contain spaces, and `DiagnoseReport.wrap` breaks Winbar's own prose at 100 columns — so
    ///   `Rosa Marchetti` could arrive as `Rosa\nMarchetti`, of which a literal needle replaced
    ///   `Rosa` and published `Marchetti`. Worse than plainly failing: the first word *was*
    ///   replaced, so the line reads as though redaction worked.
    ///
    /// · **A MAC gets a continuation guard.** A known MAC is listed before the shape rule, so
    ///   without this it would match the first six pairs of a longer run and leave the rest — the
    ///   same partial mask `macPattern` exists to avoid. With the guard the known needle declines,
    ///   the shape rule takes the run whole, and it is numbered as its own.
    private static func pattern(for needle: String) -> String {
        let body = spellings(of: needle).map { form in
            form.split(whereSeparator: \.isWhitespace)
                .map { NSRegularExpression.escapedPattern(for: String($0)) }
                .joined(separator: "\\s+")
        }.joined(separator: "|")
        return "(?:" + body + ")" + (isMAC(needle) ? macContinues : "")
    }

    /// "…and the run doesn't go on". Only ever appended to a known MAC: the shape rules match a
    /// long run greedily and so need nothing.
    private static let macContinues = "(?![:.\\-][0-9A-Fa-f])"

    /// The same six bytes in each spelling this file knows how to read, from any of them. Empty for
    /// anything that isn't twelve hex digits with hardware separators between them, so a value that
    /// somehow isn't a MAC produces no needles rather than nonsense ones.
    static func macSpellings(of value: String) -> [String] {
        guard value.allSatisfy({ $0.isHexDigit || $0 == ":" || $0 == "-" || $0 == "." }) else { return [] }
        let hex = Array(value.filter(\.isHexDigit))
        guard hex.count == 12 else { return [] }
        func groups(_ size: Int) -> [String] {
            stride(from: 0, to: 12, by: size).map { String(hex[$0..<($0 + size)]) }
        }
        let pairs = groups(2)
        return [pairs.joined(separator: ":"), pairs.joined(separator: "-"),
                String(hex), groups(4).joined(separator: ".")]
    }

    /// Everything that happens to a piece of text on its way into the report: secrets always,
    /// identity when anonymising. Applied to the whole file at the end rather than to each section,
    /// so a section added later can't be the one that forgot.
    ///
    /// **One pass, and the order inside it is the rule.** This used to be two: every literal needle
    /// replaced, and then everything still shaped like an id swept up behind it. That published most
    /// of an id. A needle that is a person's word can also be four, eight or twelve hex characters —
    /// a VM called `cafe`, a user called `deadbeef`, a host name that is twelve hex digits — and
    /// where such a needle was a whole hyphen-delimited group of an id the first pass had not
    /// placed, replacing it broke the 8-4-4-4-12 shape. The second pass then found nothing, and 27
    /// of the id's 32 characters went into a public issue:
    /// `deadbeef-cafe-4a1b-…` → `deadbeef-<vm-1>-4a1b-…`.
    ///
    /// So there is one alternation, ordered `(the ids and MACs Winbar can name | an id | a MAC | the
    /// names)`, and `NSRegularExpression` decides it twice over. It takes the leftmost match, which
    /// settles every needle that sits *inside* an id — the id starts earlier, so the id wins. And at
    /// one position it takes the first alternative that matches, which settles the rest: a name that
    /// is exactly an id's first group loses to the id shape because the shape is listed first, and a
    /// known id beats the shape because it is listed before that and so keeps its VM's number.
    ///
    /// One pass also means nothing Winbar writes is ever rescanned — see the boundary note below,
    /// which is the other half of why `<vm-1-id>` is safe to write into the output at all.
    func apply(_ text: String) -> String {
        let swept = Redactor.withoutSecrets(text)
        guard mode == .anonymised, let pass else { return swept }
        var idNumbers: [String: Int] = [:]
        var macNumbers: [String: Int] = [:]
        return Redactor.replacing(pass, in: swept) { found in
            if let known = placeholders[Redactor.key(found)] { return known }
            // The same id hyphenated and unbroken is one id, so it gets one number. Keyed on the
            // hex alone for the same reason the MAC below is: the separators are spelling.
            if Redactor.isID(found) {
                return "<id-\(Redactor.number(of: Redactor.hex(found), in: &idNumbers))>"
            }
            // And the same card is one card in all four spellings, so two lines about one NIC still
            // read as one NIC whichever tool printed each of them.
            if Redactor.isMAC(found) {
                return "<mac-address-\(Redactor.number(of: Redactor.hex(found), in: &macNumbers))>"
            }
            // Unreachable: the alternation is built from these very needles and these two shapes, so
            // a match is one of them. It is written down rather than left to a silent fallback
            // because the silent fallback was to write the match back out unchanged — a bug in this
            // file would have looked exactly like a report that needed no redacting. Loud in a test
            // run, and closed rather than open in a release build: an identifier nothing here can
            // account for is the last thing to hand somebody a published placeholder for.
            assertionFailure("Redactor matched \(found), which is neither a known needle nor a known shape")
            return "<redacted>"
        }
    }

    /// The boundary every rule in this file uses, and the reason there is one.
    ///
    /// Not a plain substring replacement, which is how a user whose short name began the repository's
    /// own name turned `<name>313/winbar` into `<user>313/winbar` in the first draft of this. The test is the
    /// character either side: a letter or a digit next to the match means this is some other word
    /// that happens to contain the name. Letters and digits rather than `\b`, because a VM may be
    /// called `win-11` and `\b` would then take its own hyphen for the boundary.
    ///
    /// The same boundary is right for an id and for a MAC, and for the same reason read the other
    /// way round: their own hyphens and colons are inside the needle, so nothing has to be made of
    /// them, while the characters that surround an id in this file are all non-alphanumeric —
    /// `vm.9F3C….rdpUser`, `vmID: 9F3C…`, `(id 9F3C…)`. The key keeps its shape,
    /// `vm.<vm-1-id>.rdpUser`, which is what makes the settings section still readable. And the
    /// boundary is what stops half an id being eaten out of a longer run of hex, which would leave
    /// something that looks like an id and is not one.
    ///
    /// It is also why a placeholder must never be re-scanned. `<vm-1-id>` has `vm`, `id` and `vm-1`
    /// sitting between non-alphanumerics inside it, so a VM actually called `vm-1` used to match
    /// inside the placeholder a longer needle had just written and turn it into `<<vm-2>-id>`.
    /// Matching everything at once and writing each match's replacement straight to the output means
    /// nothing Winbar inserts is ever looked at again.
    ///
    /// A combining mark counts as inside a word too (`\p{M}`), which is the boundary half of the
    /// composition problem `clean` describes: in decomposed text `Renée` is `Rene` followed by a
    /// combining acute and an `e`, so a Mac user really called `Rene` would otherwise have been
    /// replaced *inside* somebody else's name and left `<user>´e` behind.
    /// Twelve hex characters and nothing else: a MAC address with its separators taken out. Only
    /// ever asked of a needle Winbar already knows, to decide whether it may go unbounded.
    static func isUnbrokenMAC(_ needle: String) -> Bool {
        needle.count == 12 && needle.allSatisfy(\.isHexDigit)
    }

    static let boundaryBefore = "(?<![A-Za-z0-9\\p{M}])"
    static let boundaryAfter = "(?![A-Za-z0-9\\p{M}])"

    /// The shape of an id: 8-4-4-4-12 hex, or the same thing with the hyphens taken out.
    ///
    /// Both forms, because both are written. UTM's scripting interface and Winbar's own settings use
    /// the hyphens; the Windows registry stores the same id as 32 unbroken characters, and so does
    /// some of what UTM prints. Masking one form and not the other would have made the promise
    /// depend on which program happened to write the line — and a report is only as private as its
    /// worst line. Longer runs of hex are untouched, because the boundary means a 40-character SHA-1
    /// or a 64-character digest matches neither alternative.
    ///
    /// The cost, stated rather than hidden, is a little larger for the unbroken form: a documented
    /// 32-character constant that identifies nobody now reads as `<id-N>`. Nothing Winbar prints
    /// today is one, and anything that starts printing one should print its name beside it.
    ///
    /// **Two spellings, and deliberately not four.** An id written with underscores for hyphens, or
    /// percent-encoded (`%2D`), or split across a line break is not matched, and the promise above
    /// says "8-4-4-4-12 hex, or those same 32 characters unbroken" rather than "an id" for that
    /// reason. This was looked at and left, because the question is not what a UUID *can* look like
    /// but what reaches this file: every id in it is written by UTM's scripting interface, by
    /// `UserDefaults`, by Windows App's bookmark list, by the Windows registry or by Winbar itself,
    /// and each of those writes one of these two forms. Nothing here is URL-encoded — the report
    /// carries no URLs but Winbar's own issues page — and nothing here can put a line break inside a
    /// token: `DiagnoseReport.wrap` breaks at spaces only, the log and settings sections are not
    /// wrapped at all, and `trim` now cuts at a line boundary or up to a space (see its own note).
    /// Widening the shape to separators nothing writes would buy no privacy and would cost the same
    /// shape its narrowness, which is the only reason it is trustworthy enough to match on at all.
    /// A source that starts writing a third spelling is a reason to add that spelling, the way the
    /// MAC rule just had three added to it.
    static let idPattern = "(?:[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}|[0-9A-Fa-f]{32})"

    /// The shape of a MAC address, in every spelling hardware and the programs that report it use.
    ///
    /// This used to be the colon-separated form alone, on the argument that it is the only one
    /// anything in the report writes. That argument was about the *macOS* side of the report — UTM,
    /// the QEMU process, the self-test — and the report also carries a Windows guest's own output
    /// and a create log full of it, where `getmac` and `ipconfig /all` write `52-54-00-AB-CD-EF`, a
    /// registry value or a DHCP lease writes `525400ABCDEF`, and switch and firmware output writes
    /// `5254.00ab.cdef`. Three spellings of the VM's own card went out whole, and the asymmetry was
    /// plain in the file: `idPattern` had already been taught its second spelling for exactly this
    /// reason. The promise is now as wide as the claim rather than the claim narrowed to the rule.
    ///
    /// **Six pairs or more, taken whole.** `{5,}` rather than `{5}`, and greedy, because a boundary
    /// that is happy with a `:` on either side let the leftmost match eat the first six pairs of an
    /// eight-pair run (an EUI-64, an InfiniBand GUID) and leave `:07:08` sitting beside a
    /// `<mac-address-1>` that claimed to have dealt with it. Every other escape in this file is
    /// silent; that one told the reader it had worked. The alternative — a lookbehind that refuses
    /// to start mid-run — cannot tell `…:05:` apart from the `c:` in `mac:52:54:…`, and would have
    /// dropped a real MAC rather than over-masking a longer one, so this takes the run whole.
    ///
    /// The unbroken form is exactly twelve, never more: the boundary then keeps it out of a longer
    /// run of hex, and a 32-character run is an id, which is listed before this in the alternation.
    /// Its cost is the mirror of `idPattern`'s and is stated the same way — a name or a constant
    /// that is exactly twelve hex characters now reads as a MAC address. It is still replaced, and
    /// a needle Winbar knows by name still wins, because `apply` looks the match up before it asks
    /// what shape it is.
    static let macPattern = "(?:[0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){5,}"
        + "|[0-9A-Fa-f]{2}(?:-[0-9A-Fa-f]{2}){5,}"
        + "|[0-9A-Fa-f]{4}(?:\\.[0-9A-Fa-f]{4}){2,}"
        + "|[0-9A-Fa-f]{12})"

    private static let wholeID = try? NSRegularExpression(pattern: idPattern)
    private static let wholeMAC = try? NSRegularExpression(pattern: macPattern)

    /// The hex of an identifier, without whichever separators the program that printed it used. The
    /// key both numbering tables are kept under, so one id or one card is one number however many
    /// ways this file finds it written.
    static func hex(_ text: String) -> String { text.filter(\.isHexDigit).lowercased() }

    // **An IPv6 link-local address carries the MAC inside it, and is not matched.** `fe80::` plus a
    // modified EUI-64 is the interface's own card with `ff:fe` pushed into the middle and one bit
    // flipped, so a rule that masks `52:54:00:ab:cd:ef` and prints `fe80::5054:ff:feab:cdef` beside
    // it has masked nothing. It is left alone all the same, on two grounds that both have to hold:
    //
    // · **Nothing in this report prints one.** The address section is the DHCP lease, which is
    //   IPv4; the self-test, the doctor table, UTM's output and the create log have no IPv6 in them
    //   at all. A rule with nothing to match is a rule that can only be wrong.
    //
    // · **The shape can't be matched honestly.** Zero compression means the same address is
    //   `fe80::5054:ff:feab:cdef`, `fe80:0:0:0:5054:ff:feab:cdef` and
    //   `fe80:0000:0000:0000:5054:00ff:feab:cdef`, and the derivation flips a bit, so deriving the
    //   literal from a known MAC covers one spelling of one address. Matching the *shape* instead
    //   means matching runs of hex separated by colons — which is every timestamp in the file and
    //   most of the doctor table, exactly the false-positive rule `secretRules` refuses to have.
    //
    // So the mode line says what is replaced (a MAC address, in four spellings) rather than
    // claiming no trace of the card can remain. Anything that starts printing a link-local address
    // — a `netstat`/`ndp` section, an IPv6 lease — makes this a real hole and needs the rule
    // written then, against a real example of what that source prints.

    /// Whether this string is an id and nothing else.
    ///
    /// For the one caller that has to tell them apart: a settings namespace Winbar has never
    /// written a name into is either the id UTM gave a VM, which the shape rule will number honestly
    /// as `<id-N>`, or the VM's own name, which is a name and has to be replaced as one or it is
    /// published. Guessing either way round leaks something — a name, or a claim about which VM.
    static func isID(_ text: String) -> Bool { matchesWhole(wholeID, text) }

    /// Whether this string is a hardware address in one of `macPattern`'s spellings and nothing
    /// else — which includes a run longer than six pairs, for the reason given there.
    static func isMAC(_ text: String) -> Bool { matchesWhole(wholeMAC, text) }

    private static func matchesWhole(_ regex: NSRegularExpression?, _ text: String) -> Bool {
        guard let regex else { return false }
        let whole = NSRange(location: 0, length: (text as NSString).length)
        return regex.firstMatch(in: text, options: [.anchored], range: whole)?.range == whole
    }

    /// The number this identifier already has, or the next one. Numbered in the order they first
    /// appear, and the same identifier is always the same number, so two log lines about one drive
    /// still read as one drive.
    ///
    /// Which is the one rule in this file that matches on shape alone, and it is deliberate. The
    /// argument against it is real — a report is made of identifiers, and a rule that eats one it
    /// didn't need to costs a reader something. It loses. Every id and every MAC here belongs to a
    /// thing on somebody's Mac, `--anonymise` is chosen by someone about to publish the file, and a
    /// report is only as private as its worst line: an identifier that survives because nothing
    /// could place it is exactly the line that shouldn't.
    private static func number(of key: String, in numbers: inout [String: Int]) -> Int {
        if let already = numbers[key] { return already }
        let next = numbers.count + 1
        numbers[key] = next
        return next
    }

    /// One pass: every match handed to `replacement`, and whatever it returns written in the match's
    /// place. Nothing that is written is matched against again.
    private static func replacing(_ regex: NSRegularExpression, in text: String,
                                  _ replacement: (String) -> String) -> String {
        let text = text as NSString
        let matches = regex.matches(in: text as String, range: NSRange(location: 0, length: text.length))
        guard !matches.isEmpty else { return text as String }
        var out = ""
        var written = 0
        for match in matches {
            let found = text.substring(with: match.range)
            out += text.substring(with: NSRange(location: written, length: match.range.location - written))
            out += replacement(found)
            written = match.range.location + match.range.length
        }
        out += text.substring(from: written)
        return out
    }

    /// One line for the top of the report, so nobody has to guess what they are about to send.
    var explanation: String {
        switch mode {
        case .verbatim:
            return "Mode: verbatim — VM names and the ids and MAC addresses UTM gave them, this Mac's name, your "
                + "Mac and Windows user names, the Windows PC name and file paths appear as they are. Run winbar "
                + "diagnose --anonymise for a copy with those replaced."
        case .anonymised:
            var text = "Mode: anonymised — this Mac's name, your Mac and Windows user names, the Windows PC name "
                + "and the VM names have been replaced with <mac>, <user>, <user-full-name>, <windows-user-1>, "
                + "<windows-pc-1> and <vm-1>, <vm-2>…. Where a VM's own name is in this file, the id UTM gave "
                + "that VM is <vm-1-id>, <vm-2-id>… and its MAC address is <vm-1-mac>, <vm-2-mac>…, carrying the "
                + "same number as the name, so the settings still say which VM each block is about. Every other "
                + "id-shaped string (8-4-4-4-12 hex, or those same 32 characters unbroken) is <id-1>, <id-2>… "
                + "and every other MAC address is <mac-address-1>, <mac-address-2>…, numbered in the order they "
                + "first appear: Windows App's saved PC, a UTM drive, a scratch file — and a VM's own id or MAC "
                + "lands here too whenever nothing in this file could say which VM it belongs to, because a "
                + "number that pointed at no name would be a claim rather than a fact. A MAC address is found "
                + "however it is written — xx:xx:xx:xx:xx:xx, xx-xx-xx-xx-xx-xx, xxxx.xxxx.xxxx or twelve "
                + "unbroken hex characters, in either case — and a longer run of hex pairs is replaced whole "
                + "rather than in part. Identifiers of other "
                + "shapes — an IP address, a serial number, a build number — are left exactly as they are, and a "
                + "name, an id or a MAC address is only replaced where it stands on its own. One thing is taken "
                + "out of every report whichever mode made it, this one included: anything shaped like a "
                + "password, a key, a token or an email address."
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
    /// Deliberately narrow, and narrow in a way the identity rules above do not contradict. Every
    /// rule here needs a label (`password=`, `--token`) or a prefix the issuer itself puts there
    /// (`ghp_`, `AKIA`), because this sweep runs on every report, including the verbatim one nobody
    /// asked to have altered, and a rule that went looking for "something that looks random" would
    /// eat serial numbers, certificate thumbprints and MAC addresses — the very things a bug report
    /// is made of. The id and MAC rules are allowed to match on shape because 8-4-4-4-12 and six hex
    /// pairs are shapes and not guesses, and because they only ever run when someone has asked for
    /// their identity to be taken out. The two are different jobs under different permissions, not
    /// one rule applied twice.
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
