import AppKit
import Foundation

/// `winbar diagnose`: one plain-text file somebody can send.
///
/// Why it exists: when a report says "it doesn't work", the answer is almost always in one of four
/// places — the versions involved, the doctor table, Winbar's settings, or a UTM crash report — and
/// asking someone to copy and paste from four places gets you two of them. One command, one file.
///
/// Three rules it is built around:
///
/// · **It runs when things are broken.** No VM, no UTM, UTM installed but not answering Apple
///   Events (which can block for minutes, so the doctor table has a deadline on it), no logs, no
///   settings at all. Every section reports its own absence and the rest of the file is still
///   written. A diagnostic tool that needs a working system is a tool for the case nobody has.
///
/// · **It is readable before it is sent.** Headings, sentences, and a first line that says what the
///   file is and what is in it. Not JSON: the person attaching it is entitled to know what they are
///   attaching, and so is the person reading it.
///
/// · **It says what it took out.** Secrets go always; names, ids and MAC addresses go with
///   `--anonymise`; the top of the file says which of those made it. See `Redactor`.
///
/// What it never does: `sudo`, read UTM's container (macOS 27 forbids it, and Winbar has no
/// business there), or copy the answer file or the setup disk — the two things `winbar create`
/// writes that a password has ever been near.
enum Diagnose {
    struct Options {
        var out: String?
        var includeLogs = true
        var mode: Redactor.Mode = .verbatim
        /// The most a create log or serial log contributes, and the most the doctor table may take.
        var logLines = 200
        var logBytes = 256 << 10
        var crashReports = 3
        /// The doctor table asks UTM and Windows, and either can be slow or silent; this is when the
        /// report gives up on the rest of the table and gets written with what there is.
        var doctorTimeout: TimeInterval = 180

        /// What the menu bar app's Report a Problem… asks for: today's file on the Desktop, logs and
        /// all, anonymised only if the person ticked the box. The only thing the two front-ends
        /// disagree about is that tick, so this is the whole of the difference between them.
        static func fromTheMenu(anonymise: Bool) -> Options {
            var options = Options()
            options.mode = anonymise ? .anonymised : .verbatim
            return options
        }
    }

    /// What `gather` is doing, for a front-end that shows it. An enum rather than a string, because
    /// a terminal can spare a sentence and a menu bar line can't, and neither should have to keep
    /// its own copy of the fact.
    enum Step: Equatable, CaseIterable {
        /// The long one — minutes, when UTM is the thing that is wrong.
        case doctor
        /// It never answered; the rest of the report is written without it.
        case doctorGaveUp
        /// Everything else, and the file itself. Seconds.
        case writing

        /// For a terminal, where there is room to say why this is taking so long.
        var sentence: String {
            switch self {
            case .doctor: return "Running winbar doctor for the report — it asks UTM and Windows, so give it a minute…"
            case .doctorGaveUp: return "doctor didn't finish in time; carrying on with the rest of the report."
            case .writing: return "Gathering the rest of the report…"
            }
        }

        /// For the menu bar, which is one line beside a blinking icon.
        var label: String {
            switch self {
            case .doctor: return "Asking UTM and Windows…"
            case .doctorGaveUp: return "UTM didn't answer; carrying on…"
            case .writing: return "Writing the report…"
            }
        }
    }

    /// What the menu bar app says about a report, in the copy deck's words rather than the view's.
    ///
    /// The app matters here more than it looks: Winbar's audience includes people who have never
    /// opened Terminal, and the menu is the whole of Winbar to them. A diagnostic command only they
    /// can't run is a command that doesn't exist for the reports hardest to answer.
    enum Copy {
        /// Title case and an ellipsis, like every other item in the menu that asks first.
        static let menuItem = "Report a Problem…"

        static let askTitle = "Write a diagnostic report?"

        /// Written for somebody who has never seen `winbar diagnose`: what is in the file, how long
        /// it takes, and what Winbar does with it afterwards. The Finder and the issues page both
        /// happen without asking again, so they are promised here rather than sprung.
        static let askDetail = """
            Winbar writes one plain-text file with everything an answerable bug report needs: the versions \
            involved, the whole winbar doctor table, Winbar's own settings, the tail of the last install log, \
            and UTM's recent crash reports. It never contains your Windows password.

            It takes a minute or two, because it asks UTM and Windows. Then Winbar shows you the file in the \
            Finder and opens its issues page, so you can read it — it's plain text, and it's yours — and drag \
            it straight into your report.

            Issues are public, and the report names this Mac (<mac>), your Mac user name and full name \
            (<user>, <user-full-name>), your Windows user name (<windows-user-1>), the Windows PC name \
            (<windows-pc-1>), and each of your VMs by name, by the id UTM gave it and by its MAC address \
            (<vm-1>, <vm-1-id>, <vm-1-mac>). Winbar can write the placeholders in brackets instead, and \
            anything else shaped like an id as <id-1> or like a MAC address as <mac-address-1>.
            """

        /// A checkbox rather than a second item held under ⌥, the way Force Stop is. ⌥ hides a thing
        /// from people who shouldn't press it; this is the opposite — the people most likely to want it
        /// are the least likely to know the key exists.
        ///
        /// Short on purpose: an accessory view wider than the alert's text column is centred rather
        /// than aligned with it, and a checkbox 4pt out of line with everything above it looks like
        /// a mistake. The placeholders it means are named in the paragraph above it instead.
        ///
        /// MAC addresses are named here all the same, in full, and the verb went instead to make
        /// room. The label is the last thing read before the box is ticked or not, "names and ids"
        /// is what a MAC address is neither of, and somebody deciding whether this covers the one
        /// identifier that outlives every rename should not have to go back up three paragraphs.
        static let anonymise = "Names, ids and MAC addresses as placeholders"
        static let anonymiseHelp = "The same as winbar diagnose --anonymise. A name too short to replace "
            + "without mangling ordinary words is kept, and the report says so at the top. Every string shaped "
            + "like an id or a MAC address goes, including the ones Winbar can't tie to a VM."

        static let askButton = "Write Report"

        /// The status line while it runs; `Step.label` replaces it as the run moves on.
        static let working = "Writing a diagnostic report…"
    }

    /// The report, once it is on disk.
    struct Written: Equatable {
        /// Where it actually went, which is what to tell somebody and what to show them.
        var url: URL
        /// Where it was meant to go. Different when that place wasn't writable — the Desktop is
        /// behind a macOS privacy prompt — and then worth saying so.
        var wanted: URL
        var bytes: Int
        var mode: Redactor.Mode

        var wentSomewhereElse: Bool { url != wanted }
    }

    /// Everything `winbar diagnose` does except talk to a terminal: gather the report, write it,
    /// and say where it went.
    ///
    /// Split out from `run` because `run` answers a shell — an exit code, and prose on stdout — and
    /// the menu bar app needs the file itself, to show it in the Finder. `progress` is called from
    /// whichever thread this is called on.
    static func gather(_ options: Options, progress: (Step) -> Void = { _ in }) -> Result<Written, WinbarError> {
        let now = Date()
        progress(.doctor)
        let doctor = doctor(timeout: options.doctorTimeout)
        if !doctor.finished { progress(.doctorGaveUp) }
        progress(.writing)

        let logs = CreateLog.directory
        let sections = [
            section(headings.environment) { environmentLines(doctor) },
            section(headings.doctor) { doctor.lines },
            // Free: doctor's C3 and C4 already made the app answer, and the Context cached it.
            section(headings.selfTest) { selfTestLines(doctor.context?.selfTest) },
            section(headings.settings) { settingsLines(Config.defaults.dictionaryRepresentation()) },
            section(headings.logs) {
                try logLines(includeLogs: options.includeLogs, directory: logs,
                             lines: options.logLines, bytes: options.logBytes)
            },
            section(headings.crashes) { try crashLines(directory: crashDirectory, limit: options.crashReports) },
        ]

        let redactor = Redactor(mode: options.mode, identity: identity(doctor.context))
        let report = Report(preamble: preamble(version: AppBundle.version, stamp: reportStamp.string(from: now),
                                               redactor: redactor, includeLogs: options.includeLogs),
                            sections: sections)
        let text = report.text(redactor)

        let wanted = destination(out: options.out, desktop: desktop, fallback: home, now: now,
                                 isDirectory: isDirectory, exists: { FileManager.default.fileExists(atPath: $0.path) })
        return write(text, to: wanted).map {
            Written(url: $0, wanted: wanted, bytes: text.utf8.count, mode: redactor.mode)
        }
    }

    static func run(_ options: Options) -> Int32 {
        switch gather(options, progress: { Term.note($0.sentence) }) {
        case .failure(let error):
            Term.error("winbar diagnose: \(error)")
            return 1
        case .success(let written):
            if written.wentSomewhereElse {
                Term.note("Couldn't write to \(tildeShortened(written.wanted.path)), so it went here instead.")
            }
            print("Wrote \(tildeShortened(written.url.path)) (\(number(written.bytes / 1024)) KB).")
            print("Read it — it's plain text and it's yours — then attach it to your issue at "
                  + "\(UpdateCheck.issuesURL.absoluteString).")
            if written.mode == .verbatim {
                print("It has this Mac's name, your Mac and Windows user names, the Windows PC name, your VM "
                      + "names and the ids and MAC addresses UTM gave them in it. winbar diagnose --anonymise "
                      + "writes the same report with those replaced.")
            }
            return 0
        }
    }

    // MARK: - The doctor table, with a deadline

    struct DoctorRun {
        var lines: [String]
        var finished: Bool
        /// The facts the run gathered, for the environment section. nil when it didn't finish: the
        /// thread filling them is still going, and `Context` is nobody's to read from two places.
        var context: Context?
    }

    /// The doctor table, rendered without colour, bounded as a whole.
    ///
    /// Every probe doctor makes is already bounded on its own (`Shell.run`'s timeout,
    /// `Automation.consent`'s deadline), but the sum of them is not: a Mac where the first Apple
    /// Event to UTM is still waiting on the macOS prompt answers nothing, slowly, several times
    /// over. That is exactly the Mac this command is for, so the table is collected line by line on
    /// another thread and whatever has arrived by the deadline is what goes in the file.
    static func doctor(timeout: TimeInterval) -> DoctorRun {
        let ctx = Context(options: Context.Options())
        let collected = Lines()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            collected.append(Doctor.header(ctx))
            let results = Doctor.report(ctx, color: false) { collected.append($0) }
            for line in Doctor.summaryLines(results, color: false) { collected.append(line) }
            done.signal()
        }
        let finished = done.wait(timeout: .now() + timeout) == .success
        var lines = collected.all
        if !finished {
            lines.append("")
            lines += wrap("winbar doctor was still working after \(Int(timeout.rounded())) seconds, so the table stops "
                              + "here and the rest of this report was written without it.", at: 100)
            lines.append("")
            lines += wrap("The row that would have come next is the one that didn't answer. When that is a Host row it "
                              + "is almost always macOS's Automation permission: UTM never answers because the prompt "
                              + "asking whether Winbar may control it is still waiting, or was answered with Don't "
                              + "Allow (System Settings → Privacy & Security → Automation).", at: 100)
        }
        return DoctorRun(lines: lines, finished: finished, context: finished ? ctx : nil)
    }

    /// Lines arriving on one thread and read from another.
    private final class Lines {
        private let lock = NSLock()
        private var lines: [String] = []
        func append(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
    }

    // MARK: - Section 1: versions and environment

    static func environmentLines(_ doctor: DoctorRun) -> [String] {
        let space = CreatePreflight.freeSpace()
        let guest = guestVersions(doctor)
        var rows: [(String, String)] = [
            ("Winbar", AppBundle.version),
            ("Installed from", installedFrom(appPath: AppBundle.url?.path, homebrew: UpdateCheck.isHomebrewInstall)),
            ("macOS", macOSDescription),
            ("Mac", macDescription),
            ("Free space", "\(CreatePreflight.gb(space.freeBytes)) GB on \(space.volume), the volume UTM keeps its VMs on"),
            ("UTM", appDescription(UTM.version, path: UTM.appURL?.path,
                                   extra: UTM.isAppRunning ? "running" : "not running")),
            ("Windows App", appDescription(WindowsApp.version, path: WindowsApp.appURL?.path, extra: nil)),
            ("UTM Guest Tools", guest.tools),
            ("Guest agent", guest.agent),
            ("Homebrew", homebrewDescription),
        ]
        if let vm = Config.vmName { rows.insert(("VM Winbar looks after", vm), at: 2) }
        return facts(rows)
    }

    /// The three ways a copy of Winbar gets onto a Mac, which decide what its owner is told to do
    /// about an update — and, here, whether "reinstall it" is even sensible advice.
    static func installedFrom(appPath: String?, homebrew: Bool) -> String {
        guard let appPath else {
            return "a bare build — this binary isn't inside a Winbar.app (swift build, most likely)"
        }
        return (homebrew ? "the Homebrew cask, at " : "the disk image or a copy by hand, at ") + appPath
    }

    static var macOSDescription: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let build = Host.sysctlString("kern.osversion").map { " (build \($0))" } ?? ""
        return "\(version.majorVersion).\(version.minorVersion)"
            + (version.patchVersion > 0 ? ".\(version.patchVersion)" : "") + build
    }

    static var macDescription: String {
        let model = Host.sysctlString("hw.model") ?? "unknown model"
        let chip = Host.sysctlString("machdep.cpu.brand_string") ?? "unknown chip"
        let memory = Host.memoryBytes > 0 ? ", \(Host.memoryBytes >> 30) GB memory" : ""
        return "\(model) — \(chip), \(Host.sysctlInt("hw.physicalcpu") ?? 0) cores\(memory)"
    }

    static func appDescription(_ version: String?, path: String?, extra: String?) -> String {
        guard let path else { return "not installed" }
        let parts = [version ?? "version unreadable", "at \(path)"] + (extra.map { [$0] } ?? [])
        return parts.joined(separator: ", ")
    }

    /// Homebrew, as Winbar itself finds it — `Homebrew.path`, not a second search of this file's
    /// own, so the report says what `winbar setup` would do rather than something near it. Its
    /// off switch is reported too: an environment variable that changes what Winbar offers is
    /// exactly the sort of thing a report is written to surface.
    static var homebrewDescription: String {
        if Homebrew.isIgnored { return "ignored — WINBAR_IGNORE_HOMEBREW=1 is set in this environment" }
        return Homebrew.path ?? "not installed"
    }

    /// What Windows said about itself, when it was asked at all. Each way of not knowing gets its
    /// own sentence, because "unknown" is the answer that wastes a round trip with the reporter.
    static func guestVersions(_ doctor: DoctorRun) -> (tools: String, agent: String) {
        guard let ctx = doctor.context else {
            let why = "not asked — winbar doctor didn't finish (see section 2)"
            return (why, why)
        }
        if let out = ctx.guestOutput {
            return (out["G10_TOOLS"] ?? "not found in Windows' installed programs",
                    out["G10_AGENT"] ?? "not found in Windows' installed programs")
        }
        let why: String
        switch ctx.guest {
        case .notConfigured: why = "no VM is chosen yet, so Windows wasn't asked"
        case .stopped: why = "the VM is off, so Windows wasn't asked"
        case .noAgent: why = "the QEMU guest agent didn't answer (see G0 in section 2)"
        case .failed(let error): why = "Windows couldn't be asked: \(error.title)"
        case .ready: why = "unknown"
        }
        return (why, why)
    }

    // MARK: - Section 4: the create logs

    static func logLines(includeLogs: Bool, directory: URL, lines limit: Int, bytes: Int) throws -> [String] {
        guard includeLogs else {
            return ["Left out, because this was run with --no-logs.",
                    "The logs themselves are in \(tildeShortened(directory.path)) if you want to look."] + jobStateLines()
        }
        guard let newest = try newestCreateLog(in: directory) else {
            return ["There are no winbar create logs on this Mac (nothing in \(tildeShortened(directory.path))).",
                    "That is normal for a VM made in UTM by hand rather than with winbar create."] + jobStateLines()
        }
        var out: [String] = []
        out += quoted(newest, lines: limit, bytes: bytes)
        let serial = CreateLog.serialURL(for: newest)
        out.append("")
        if FileManager.default.fileExists(atPath: serial.path) {
            out += quoted(serial, lines: limit, bytes: bytes)
        } else {
            out.append("There is no serial log beside it (\(serial.lastPathComponent)). "
                       + "One is only written once the VM has been created and started.")
        }
        return out + jobStateLines()
    }

    /// Where the install job keeps its own state, asked of this Mac.
    static func jobStateLines() -> [String] {
        let path = CreateJob.current().map {
            CreateJob.directory(of: $0).appendingPathComponent(CreateJob.stateFileName).path
        }
        return jobStateLines(statePath: path.map(tildeShortened), base: tildeShortened(CreateJob.base.path))
    }

    /// One log file, trimmed, with its own name and what was left out above it.
    static func quoted(_ url: URL, lines limit: Int, bytes: Int) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return ["\(url.lastPathComponent): couldn't be read."]
        }
        let trimmed = trim(text, lines: limit, bytes: bytes)
        return ["\(url.lastPathComponent) — \(trimmed.note)",
                "----- begin \(url.lastPathComponent) -----",
                trimmed.text,
                "----- end \(url.lastPathComponent) -----"]
    }

    /// The newest `create-*.log`, which is the install a report is almost certainly about. Its
    /// serial log sits beside it under the same name and is not a candidate itself.
    static func newestCreateLog(in directory: URL) throws -> URL? {
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
        let files = try FileManager.default.contentsOfDirectory(at: directory,
                                                                includingPropertiesForKeys: [.contentModificationDateKey])
        return files
            .filter { $0.lastPathComponent.hasPrefix("create-") && $0.pathExtension == "log"
                      && !$0.lastPathComponent.hasSuffix(".serial.log") }
            .compactMap { url -> (URL, Date)? in
                guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                else { return nil }
                return (url, modified)
            }
            .max { $0.1 < $1.1 }?.0
    }

    // MARK: - Section 5: UTM's crash reports

    static var crashDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
    }

    /// A crash report can be megabytes of every thread's stack. Anything past this isn't read at
    /// all, rather than read and thrown away.
    static let crashReportLimit = 16 << 20

    static func crashLines(directory: URL, limit: Int) throws -> [String] {
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return ["macOS has no crash report folder for this user (\(tildeShortened(directory.path)))."]
        }
        let files = try FileManager.default.contentsOfDirectory(at: directory,
                                                                includingPropertiesForKeys: [.contentModificationDateKey,
                                                                                             .fileSizeKey])
        let utm = files
            .filter { $0.lastPathComponent.hasPrefix("UTM") && $0.pathExtension == "ips" }
            .compactMap { url -> (url: URL, modified: Date, size: Int)? in
                guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                      let modified = values.contentModificationDate else { return nil }
                return (url, modified, values.fileSize ?? 0)
            }
            .sorted { $0.modified > $1.modified }
        guard !utm.isEmpty else {
            return ["No UTM crash reports in \(tildeShortened(directory.path)).",
                    "UTM hasn't crashed on this Mac, or macOS has cleared them out."]
        }
        var out = ["UTM has \(number(utm.count)) crash report\(utm.count == 1 ? "" : "s") here; "
                       + "the \(min(limit, utm.count)) most recent, headline only:",
                   "(Winbar exists partly because UTM crashes — see utmapp/UTM#7882 — so this is often the answer.)"]
        for report in utm.prefix(limit) {
            out.append("")
            guard report.size <= crashReportLimit else {
                out.append("\(report.url.lastPathComponent) — \(number(report.size / (1 << 20))) MB, too big to read here.")
                continue
            }
            guard let contents = try? String(contentsOf: report.url, encoding: .utf8) else {
                out.append("\(report.url.lastPathComponent) — couldn't be read.")
                continue
            }
            out += crashHeadline(fileName: report.url.lastPathComponent, contents: contents, modified: report.modified)
        }
        return out
    }

    // MARK: - Who this Mac belongs to

    /// The names and ids `--anonymise` replaces. Gathered whichever mode is in force — `Redactor`
    /// ignores them in verbatim mode — so that the two paths differ in one place only.
    ///
    /// Three places know an id, and all three are read here so that as many ids as possible reach
    /// the report as `<vm-N-id>` rather than as an anonymous `<id-N>`: the settings namespaces (a
    /// VM's own record says which name it was last seen under), `vmID`/`vmName` (the only pairing
    /// that covers the global `vmID` value, whose namespace may still be the name), and UTM's own
    /// list (the only one that covers a VM Winbar has no record of). An id nothing can name is left
    /// out on purpose: `Redactor` numbers it as an id of its own rather than inventing a VM for it.
    static func identity(_ ctx: Context?) -> Redactor.Identity {
        let settings = Config.defaults.dictionaryRepresentation()
        var vms = Set<String>()
        var vmIDs: [String: String] = [:]
        var macsByVM: [String: String] = [:]
        let remembered = vmMACs(settings)
        func named(_ value: String?) -> String? {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return value
        }
        func learn(id: String?, name: String?) {
            guard let name = named(name) else { return }
            vms.insert(name)
            // A token that *is* the name is a record written before Winbar knew the id, not an id.
            guard let id = named(id), id.caseInsensitiveCompare(name) != .orderedSame else { return }
            vmIDs[id] = name
        }
        func learn(mac: String?, name: String?) {
            guard let mac = named(mac), let name = named(name) else { return }
            macsByVM[mac] = name
        }
        for record in Config.rememberedVMRecords() {
            if let name = record.name {
                learn(id: record.token, name: name)
            } else if !Redactor.isID(record.token) {
                // No name was ever written into this record, so the namespace is the only handle on
                // it — and a namespace that isn't id-shaped is the VM's own name, which has to go in
                // as a name or it is published. An id-shaped one is left out, for the shape rule to
                // number as `<id-N>`: there is nothing here to say which VM it is.
                learn(id: nil, name: record.token)
            }
            // The MAC is filed in the same namespace, so the name that namespace is known under is
            // the one it belongs to — its recorded name, or the namespace itself when that is a name.
            learn(mac: remembered[record.token],
                  name: record.name ?? (Redactor.isID(record.token) ? nil : record.token))
        }
        learn(id: Config.vmID, name: Config.vmName)
        learn(mac: Config.vmMAC, name: Config.vmName)
        if let ctx, case .success(let list) = ctx.vms {
            for vm in list { learn(id: vm.id, name: vm.name) }
        }
        learn(mac: ctx?.vmMAC, name: ctx?.vmName)
        // Every VM's Windows account, not just the chosen VM's: the settings section prints all of
        // them, so replacing only one would be a half-kept promise.
        let checked = passwordCheckedNames(settings)
        var windowsUsers = Set(windowsUserNames(settings)).union(checked.users)
        if let user = ctx?.guestOutput?["USER"], !user.isEmpty { windowsUsers.insert(user) }
        // The guest's own machine name, which nothing used to gather. It is written into
        // `passwordCheckedFor` as `COMPUTERNAME\user`, and the DNS form of it is what the RDP host
        // is derived from. Both, because Windows cuts COMPUTERNAME to 15 characters and the DNS name
        // isn't cut: masking only the short one leaves the long one whole.
        //
        // And from the settings, which is the half that was missing. `passwordCheckedFor` is only
        // written after a logon probe has found a password, and the two guest values below need the
        // VM to be running and answering — so on the Mac this matters most on, the one whose VM
        // won't start, neither source has anything and the name reached the report anyway: it is in
        // `rdpHost`, in `savedPCHost` and in `savedPCName`, all of which section 4 prints, and
        // `Connection.resolveHost` writes it there the first time Connect works.
        let windowsPCs = windowsPCNames(settings: settings, checked: checked.pcs,
                                        guestOutput: ctx?.guestOutput)
        // Both of these can consult macOS's configuration store, which on a Mac with a sick network
        // stack is one more thing that can hang. A name we couldn't read is one we say we kept.
        let computer = withDeadline(2) { Foundation.Host.current().localizedName } ?? nil
        let hostName = withDeadline(2) { ProcessInfo.processInfo.hostName }
        return Redactor.Identity(userName: NSUserName(),
                                 fullUserName: NSFullUserName(),
                                 computerName: computer,
                                 hostNames: [hostName, Host.sysctlString("kern.hostname")].compactMap { $0 },
                                 vmNames: Array(vms),
                                 vmIDs: vmIDs,
                                 vmMACs: macsByVM,
                                 windowsUsers: Array(windowsUsers),
                                 windowsPCNames: Array(windowsPCs))
    }

    /// The Windows account each VM's settings name.
    static func windowsUserNames(_ values: [String: Any]) -> [String] {
        values.compactMap { key, value in
            VMSettings.split(key)?.setting == Config.Key.rdpUser ? value as? String : nil
        }
    }

    /// The Windows machine name as Winbar's own settings hold it: every `rdpHost`, `savedPCHost`
    /// and `savedPCName`, per-VM or left over globally from before the settings were filed per VM.
    ///
    /// These three are the only record of the guest's name once the VM is off, which is the state a
    /// diagnostic report is usually written in, and section 4 prints all of them.
    ///
    /// **The `.local` is taken off, and only the `.local`.** A host name here is `<pc-name>.local`
    /// and the same machine is written bare in `passwordCheckedFor` and in `savedPCName`, so what
    /// has to become one needle with one placeholder is the bare name: `Redactor` replaces longest
    /// first, and feeding it both `winbox` and `winbox.local` would give one machine two numbers and
    /// leave `<windows-pc-1>` and `<windows-pc-2>` reading as two Windows installs. Masking the bare
    /// name leaves `<windows-pc-1>.local`, which says the shape of the thing and names nothing —
    /// `.local` is the suffix every mDNS name on every network has.
    ///
    /// An address typed in place of a name is not a name and is left out: masking `192.168.64.7` as
    /// `<windows-pc-1>` would be a lie about what it is, and the same address is printed as the VM's
    /// lease two sections earlier, where nothing masks it and nothing should.
    /// All three sources of the guest's machine name, together.
    ///
    /// This is a function rather than four lines inside `identity` for one reason: `identity` reads
    /// the real defaults, so no test may call it, and the settings source was therefore wired up
    /// with nothing exercising the wiring — a reviewer deleted that line and all 664 tests still
    /// passed. Gathering them here makes the join itself testable, so dropping any one source fails
    /// `everySourceOfTheWindowsPCNameIsUsed`.
    static func windowsPCNames(settings: [String: Any], checked: [String],
                               guestOutput: GuestOutput?) -> [String] {
        var names = Set(checked)
        names.formUnion(windowsPCNamesFromSettings(settings))
        for key in ["COMPUTERNAME", "DNSHOST"] {
            if let name = guestOutput?[key], !name.isEmpty { names.insert(name) }
        }
        return Array(names)
    }

    static func windowsPCNamesFromSettings(_ values: [String: Any]) -> [String] {
        let hostSettings = [Config.Key.rdpHost, Config.Key.savedPCHost, Config.Key.savedPCName]
        var found: [String] = []
        for (key, value) in values {
            guard let text = value as? String,
                  hostSettings.contains(VMSettings.split(key)?.setting ?? key),
                  let name = bareHostName(text) else { continue }
            found.append(name)
        }
        return found
    }

    /// `winbox.local` → `winbox`; an address or an empty string → nil. See above.
    static func bareHostName(_ value: String) -> String? {
        var name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasSuffix(".") { name.removeLast() }
        if name.lowercased().hasSuffix(".local") { name = String(name.dropLast(".local".count)) }
        guard !name.isEmpty, !isAddressLiteral(name) else { return nil }
        return name
    }

    /// Whether this is an address rather than a name. Deliberately crude: an IPv6 literal is the
    /// only thing in a host field with a colon in it, and four all-digit parts is IPv4.
    static func isAddressLiteral(_ text: String) -> Bool {
        if text.contains(":") { return true }
        let parts = text.components(separatedBy: ".")
        return parts.count == 4 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }

    /// The MAC address each VM's settings remember, by the namespace it is filed under.
    static func vmMACs(_ values: [String: Any]) -> [String: String] {
        var found: [String: String] = [:]
        for (key, value) in values {
            guard let split = VMSettings.split(key), split.setting == Config.Key.vmMAC,
                  let mac = value as? String else { continue }
            found[split.token] = mac
        }
        return found
    }

    /// Both halves of every `COMPUTERNAME\user` key in `passwordCheckedFor` — the record of which
    /// accounts a logon probe has found a password on.
    ///
    /// The only place in the report the guest's machine name is written down, and until this was
    /// read it went out verbatim. It only *looked* masked on the Mac Winbar was written on, where
    /// Windows happens to be named after its VM; a default install is `DESKTOP-4F8J2K1` and shares
    /// nothing with any name Winbar was already replacing. The account half is taken too: it is the
    /// same field, and a VM whose `rdpUser` was never written still names its user here.
    static func passwordCheckedNames(_ values: [String: Any]) -> (pcs: [String], users: [String]) {
        let raw = values[Config.Key.passwordCheckedFor]
        let keys = (raw as? [String]) ?? (raw as? String).map { [$0] } ?? []
        var pcs: [String] = []
        var users: [String] = []
        for key in keys {
            let parts = key.components(separatedBy: "\\")
            guard parts.count == 2 else { continue }
            if !parts[0].isEmpty { pcs.append(parts[0]) }
            if !parts[1].isEmpty { users.append(parts[1]) }
        }
        return (pcs, users)
    }

    // MARK: - Writing it

    static var desktop: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop") }
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    static func isDirectory(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
    }

    /// Writes the report, and keeps trying somewhere else if it can't. The Desktop is behind a
    /// macOS privacy prompt for a terminal that has never asked, and a report that isn't written is
    /// the one failure this command isn't allowed to have.
    static func write(_ text: String, to url: URL) -> Result<URL, WinbarError> {
        var attempts = [url]
        if url.deletingLastPathComponent() != home { attempts.append(home.appendingPathComponent(url.lastPathComponent)) }
        attempts.append(FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent))
        var last: Error?
        for attempt in attempts {
            do {
                try text.write(to: attempt, atomically: true, encoding: .utf8)
                return .success(attempt)
            } catch {
                last = error
            }
        }
        return .failure(WinbarError("Couldn't write the report anywhere",
                                    last.map { "\($0)" } ?? "no writable place was found"))
    }

    static func tildeShortened(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
