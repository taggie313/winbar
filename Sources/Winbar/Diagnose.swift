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
/// · **It says what it took out.** Secrets go always; names go with `--anonymise`; the top of the
///   file says which of those made it. See `Redactor`.
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
    }

    static func run(_ options: Options) -> Int32 {
        let now = Date()
        Term.note("Running winbar doctor for the report — it asks UTM and Windows, so give it a minute…")
        let doctor = doctor(timeout: options.doctorTimeout)
        if !doctor.finished { Term.note("doctor didn't finish in time; carrying on with the rest of the report.") }

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
        switch write(text, to: wanted) {
        case .failure(let error):
            Term.error("winbar diagnose: \(error)")
            return 1
        case .success(let written):
            if written != wanted {
                Term.note("Couldn't write to \(tildeShortened(wanted.path)), so it went here instead.")
            }
            print("Wrote \(tildeShortened(written.path)) (\(number(text.utf8.count / 1024)) KB).")
            print("Read it — it's plain text and it's yours — then attach it to your issue at "
                  + "https://github.com/\(UpdateCheck.repo)/issues.")
            if redactor.mode == .verbatim {
                print("It has this Mac's name, your user name and your VM names in it. "
                      + "winbar diagnose --anonymise writes the same report with those replaced.")
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

    /// The names `--anonymise` replaces. Gathered whichever mode is in force — `Redactor` ignores
    /// them in verbatim mode — so that the two paths differ in one place only.
    static func identity(_ ctx: Context?) -> Redactor.Identity {
        var vms = Set(Config.rememberedVMs())
        if let name = Config.vmName { vms.insert(name) }
        if let ctx, case .success(let list) = ctx.vms { vms.formUnion(list.map(\.name)) }
        // Every VM's Windows account, not just the chosen VM's: the settings section prints all of
        // them, so replacing only one would be a half-kept promise.
        var windowsUsers = Set(windowsUserNames(Config.defaults.dictionaryRepresentation()))
        if let user = ctx?.guestOutput?["USER"], !user.isEmpty { windowsUsers.insert(user) }
        // Both of these can consult macOS's configuration store, which on a Mac with a sick network
        // stack is one more thing that can hang. A name we couldn't read is one we say we kept.
        let computer = withDeadline(2) { Foundation.Host.current().localizedName } ?? nil
        let hostName = withDeadline(2) { ProcessInfo.processInfo.hostName }
        return Redactor.Identity(userName: NSUserName(),
                                 fullUserName: NSFullUserName(),
                                 computerName: computer,
                                 hostNames: [hostName, Host.sysctlString("kern.hostname")].compactMap { $0 },
                                 vmNames: Array(vms),
                                 windowsUsers: Array(windowsUsers))
    }

    /// The Windows account each VM's settings name.
    static func windowsUserNames(_ values: [String: Any]) -> [String] {
        values.compactMap { key, value in
            VMSettings.split(key)?.setting == Config.Key.rdpUser ? value as? String : nil
        }
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
