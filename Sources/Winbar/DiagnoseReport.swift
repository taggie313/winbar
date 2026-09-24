import Foundation

// The half of `winbar diagnose` that touches nothing: the shape of the file, how a section that
// couldn't be gathered still gets written, the trimming rule for a log, what the headline of a
// crash report is, how the settings are laid out and where the file goes. All of it is decided from
// values handed in, which is why the tests can build a whole report on a Mac with no VM, no UTM and
// no logs — the case the command exists for.

extension Diagnose {

    // MARK: - The shape of the file

    /// One part of the report: a heading, and the lines under it. A section always has lines, even
    /// when there was nothing to find — "there is no create log" is an answer, and a heading with
    /// nothing under it is a question.
    struct Section: Equatable {
        var heading: String
        var lines: [String]
    }

    struct Report {
        var preamble: [String]
        var sections: [Section]

        /// The finished file. Redaction is applied once, to the whole thing, rather than to each
        /// section as it is built: a section added later can then never be the one that forgot.
        func text(_ redactor: Redactor) -> String {
            var out = preamble
            for section in sections {
                out.append("")
                out.append("")
                out.append(section.heading)
                out.append(String(repeating: "-", count: section.heading.count))
                out += section.lines
            }
            return redactor.apply(out.joined(separator: "\n")) + "\n"
        }
    }

    /// Builds one section, and turns whatever went wrong into that section's own text.
    ///
    /// This is the rule the whole command rests on: it runs when things are broken, so no section
    /// may be able to take another one down with it. A missing log, a settings domain that won't
    /// open, a crash report directory macOS won't show us — each costs its own paragraph, and the
    /// file is still written.
    static func section(_ heading: String, _ body: () throws -> [String]) -> Section {
        do {
            let lines = try body()
            return Section(heading: heading, lines: lines.isEmpty ? ["Nothing to report here."] : lines)
        } catch {
            return Section(heading: heading,
                           lines: ["This part couldn't be gathered: \(error)",
                                   "Everything else in this report was gathered separately and is unaffected."])
        }
    }

    // MARK: - The first thing anyone reads

    static let headings = (environment: "1. Versions and environment",
                           doctor: "2. What winbar doctor says",
                           selfTest: "3. What the menu bar app itself sees",
                           settings: "4. Winbar's own settings",
                           logs: "5. The most recent winbar create log",
                           crashes: "6. Recent UTM crash reports",
                           focus: "7. Focus changes (most recent last)")

    /// The top of the file: what it is, what is in it, what is not, and which mode made it. Written
    /// for someone who is about to attach it to a public issue and would like to know what they are
    /// handing over — or, `forDeveloper`, who is about to send it to Winbar's developer with the
    /// beta's **Send a Problem Report…** (`BetaReport`), which puts its own sections above section 1.
    static func preamble(version: String, stamp: String, redactor: Redactor, includeLogs: Bool,
                         forDeveloper: Bool = false) -> [String] {
        var lines = [
            "Winbar diagnostic report — everything an answerable bug report about Winbar needs, in one file.",
            "Made by winbar diagnose (Winbar \(version)) on \(stamp).",
            "",
            "What's in here, in order:",
            "  1. Versions and environment — Winbar, macOS, this Mac, UTM, Windows App, the Guest Tools.",
            "  2. What winbar doctor says — the whole table, with why and how for anything that isn't ✓.",
            "  3. What the menu bar app itself sees — the VM's address on the network, whether Remote",
            "     Desktop answered, and the permissions that belong to Winbar rather than to a terminal.",
            "  4. Winbar's own settings — the keys under net.elusive.winbar, one set per VM.",
        ]
        lines.append(includeLogs
            ? "  5. The most recent winbar create log, and the serial log beside it — the tail of each."
            : "  5. The create logs — left out, because this was run with --no-logs.")
        lines += [
            "  6. Recent UTM crash reports — the headline of each, because UTM crashing is often the answer.",
            "  7. Focus changes — which app came to the front, and when, while the menu bar app was open.",
            "",
            "What's never in here: your Windows password, the answer file winbar create writes, or the",
            "contents of the setup disk. Winbar never writes a password down, and this report is swept for",
            "anything shaped like a password, a key or a token whatever section it came from.",
            "",
        ]
        lines += wrap(redactor.explanation, at: 100)
        lines.append("")
        if forDeveloper {
            lines += wrap("Written for Send a Problem Report…, which sends this file to Winbar's developer, and no one "
                              + "else, when Send is pressed. Above section 1: the note written with it, and what "
                              + "Winbar's windows were showing when it was asked for.", at: 100)
            return lines
        }
        lines += [
            "Nothing here has left your Mac. Read it, take out anything you'd rather not publish, and attach",
            "it to your issue at \(UpdateCheck.issuesURL.absoluteString).",
        ]
        return lines
    }

    // MARK: - Laying out facts

    /// A paragraph broken into lines at word boundaries, for the sentences the report writes itself.
    /// The doctor table isn't wrapped — it is reproduced exactly as `winbar doctor` prints it, long
    /// `why:` lines and all, because a table that doesn't match the command is a table that starts
    /// an argument.
    static func wrap(_ text: String, at width: Int) -> [String] {
        var lines: [String] = []
        var current = ""
        for word in text.split(separator: " ", omittingEmptySubsequences: true) {
            if current.isEmpty {
                current = String(word)
            } else if current.count + 1 + word.count <= width {
                current += " " + word
            } else {
                lines.append(current)
                current = String(word)
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines.isEmpty ? [""] : lines
    }

    /// `label: value`, with the values lined up.
    static func facts(_ rows: [(String, String)]) -> [String] {
        let width = rows.map(\.0.count).max() ?? 0
        return rows.map { label, value in
            label + ":" + String(repeating: " ", count: max(1, width - label.count + 1)) + value
        }
    }

    // MARK: - What the app itself sees

    /// The self-test rows worth naming, in the order someone debugging "Connect doesn't work" wants
    /// them: where the VM is on the network, whether anything answered there, then the two grants
    /// that belong to Winbar and can't be asked for from a shell.
    static let selfTestRows: [(key: String, label: String)] = [
        ("rdp readiness", "Remote Desktop, on port 3389"),
        ("leased ip", "The address macOS has leased the VM"),
        ("vm mac", "The VM's MAC address (which lease to look for)"),
        ("vm bridge", "The network interface Winbar probed"),
        ("qemu running", "The VM's own process, seen by the app"),
        ("accessibility", "Accessibility, granted to Winbar itself"),
        ("login item", "Launch at Login"),
        ("windows app", "Windows App, where the app finds it"),
        ("utmctl present", "utmctl"),
    ]

    /// Rows section 1 and the doctor table already carry. Left out here so this section is the facts
    /// nothing else in the file can answer — but named, so that "not shown" is a decision rather
    /// than an oversight.
    static let selfTestElsewhere: Set<String> = ["winbar", "vm", "console enabled", "vcpus", "memory mb"]

    /// Why this section exists at all, in the words of the thing it is about.
    static let selfTestPreamble =
        "These are the menu bar app's own answers, not this terminal's. macOS gives a privacy grant to "
        + "whoever is responsible for a process, so Accessibility and Local Network asked from a shell are the "
        + "terminal's grants and not Winbar's — a report built that way once said \"ready\" while Connect "
        + "couldn't reach the VM at all. So Winbar launches itself to ask, and these are what it answered."

    /// The section. `answer` is what `SelfTest.launchAsApp` came back with, or nil when the app was
    /// never asked because the doctor run it belongs to didn't finish.
    static func selfTestLines(_ answer: Result<[String: String], WinbarError>?) -> [String] {
        var lines = wrap(selfTestPreamble, at: 100)
        lines.append("")
        switch answer {
        case nil:
            lines += wrap("The app wasn't asked: winbar doctor didn't finish (see section 2), and this is one of the "
                              + "things its run gathers. Running winbar diagnose again when UTM is answering fills "
                              + "this in.", at: 100)
            return lines
        case .failure(let error):
            lines += wrap("Winbar couldn't be launched to ask, so none of it is here: \(error.description)", at: 100)
            lines.append("")
            lines += wrap("Nothing below this is missing because the VM is broken — it is missing because the "
                              + "question couldn't be put to the app. A copy of Winbar run straight out of a build "
                              + "directory (rather than from Winbar.app) can't answer for the app's own grants at all.",
                          at: 100)
            return lines
        case .success(let values):
            var rows: [(label: String, answer: (value: String, note: String?))] = []
            for (key, label) in selfTestRows {
                rows.append((label, values[key].map { selfTestAnswer(key: key, $0) }
                                    ?? (value: "the app didn't report this", note: nil)))
            }
            // Anything the self-test grows later appears here rather than being dropped in silence.
            let extra = values.keys.filter { key in
                !selfTestRows.contains { $0.key == key } && !selfTestElsewhere.contains(key)
            }
            for key in extra.sorted() { rows.append((key, (values[key] ?? "", nil))) }

            // The answers stay short so the column stays a column; what to do about one goes
            // underneath it, where there is room for a sentence.
            let width = rows.map(\.label.count).max() ?? 0
            for (label, answer) in rows {
                lines.append(label + ":" + String(repeating: " ", count: max(1, width - label.count + 1)) + answer.value)
                if let note = answer.note { lines += wrap(note, at: 92).map { "    " + $0 } }
            }
            return lines
        }
    }

    /// A self-test value as a person reads it: a short answer, and — for the ones somebody is about
    /// to act on — the sentence that says what to do. `true` and `false` are a program's words, so
    /// each row that uses them says them in its own.
    ///
    /// The per-row cases come first on purpose: a bare `(_, "true")` at the top would answer for
    /// every one of them, which is how "the VM's own process: yes" got into the first draft.
    static func selfTestAnswer(key: String, _ value: String) -> (value: String, note: String?) {
        switch (key, value) {
        case ("rdp readiness", "ready"):
            return ("ready", "Something answered on port 3389, so the network path Connect uses is open.")
        case ("rdp readiness", "notReady"):
            return ("notReady", "Nothing answered on port 3389. Windows may still be booting, or Remote Desktop may "
                        + "be off inside it (see G6 in section 2).")
        case ("rdp readiness", "blocked"):
            return ("blocked", "macOS's Local Network privacy stopped the check, so this says nothing about the VM: "
                        + "System Settings → Privacy & Security → Local Network → turn on Winbar.")
        case ("rdp readiness", "vm off"):
            return ("not checked", "The VM is off, so there was nothing to ask.")
        case ("qemu running", "true"): return ("running", nil)
        case ("qemu running", "false"): return ("not running", nil)
        case ("utmctl present", "true"): return ("present", nil)
        case ("utmctl present", "false"):
            return ("missing", "utmctl comes with UTM; Winbar couldn't find it where UTM says it is.")
        case ("accessibility", "true"): return ("yes", nil)
        case ("accessibility", "false"):
            return ("no", "Connect presses the saved PC's tile through the Accessibility API, so it can't work "
                        + "until this is on: System Settings → Privacy & Security → Accessibility → turn on Winbar.")
        case ("login item", "enabled"): return ("on", nil)
        case ("login item", "notRegistered"): return ("off", "Turn it on from the menu: Launch at Login.")
        case ("login item", "requiresApproval"):
            return ("waiting for you", "macOS is holding it in System Settings → General → Login Items.")
        case ("login item", "notFound"): return ("not found", "macOS has no record of this copy of Winbar.")
        case ("leased ip", "none"):
            return ("none", "macOS has no DHCP lease for that MAC yet, and the lease is where Connect gets the "
                        + "VM's address. A VM that has just started may not have asked for one yet.")
        case ("vm bridge", "not found"):
            return ("not found", "No interface on this Mac serves that address — the readiness check above has "
                        + "nowhere to look.")
        case ("windows app", "missing"): return ("not installed", nil)
        case (_, "true"): return ("yes", nil)
        case (_, "false"): return ("no", nil)
        default: return (value, nil)
        }
    }

    /// The install job's own state, named but never copied.
    ///
    /// `state.json` says which stage an install reached, when each one started and which VM it made,
    /// which is worth having for an install that is stuck. It is the wrong shape for this file
    /// though — JSON, in a report written to be read as prose — and the log above already carries
    /// the failure and the stage it happened in. So the path goes in and the contents don't.
    static func jobStateLines(statePath: String?, base: String) -> [String] {
        guard let statePath else {
            return ["", "No winbar create job is on this Mac now; if one were, its \(CreateJob.stateFileName) "
                        + "would be under \(base)/."]
        }
        return ["",
                "The install job's own state — which stage it reached, when each one started, the VM it made — is in "
                    + statePath + ".",
                "It isn't copied in here (it's JSON, and the log above already carries the failure); ask for it if "
                    + "you want it."]
    }

    // MARK: - Settings

    /// Winbar's own keys, out of a whole settings domain. `UserDefaults` answers for everything
    /// macOS puts in the domain too (every `NSGlobalDomain` default a process inherits), so the keys
    /// are matched against Winbar's own names rather than taken as they come.
    static func winbarKeys(_ keys: [String]) -> [String] {
        let global = Set(Config.Key.all).subtracting(Config.Key.record)
        return keys.filter { global.contains($0) || VMSettings.split($0) != nil }
    }

    /// The settings section: what belongs to this copy of Winbar, then one block per VM.
    ///
    /// Verbatim, because none of it is a secret and every one of them is a fact somebody will want:
    /// which VM is chosen, which host name Connect goes to, whether BitLocker was seen on. The
    /// report's own sweep still runs over them, and `--anonymise` still replaces the names — and, as
    /// of the id pass, the ids too. This is the section the ids actually live in: `vmID` is one, and
    /// so is every `vm.<id>.*` key prefix, repeated once per key. Masking them costs this section
    /// nothing a reader needs, because the placeholder is numbered for the VM it belongs to and the
    /// key keeps its shape; leaving them would have left the settings as the one place a published
    /// report still named a machine.
    static func settingsLines(_ values: [String: Any]) -> [String] {
        let keys = winbarKeys(Array(values.keys))
        guard !keys.isEmpty else {
            return ["Winbar has no settings on this Mac: nothing has chosen a VM yet.",
                    "(A fresh install looks exactly like this.)"]
        }
        var lines = ["Read straight out of net.elusive.winbar. Every vm.<id>.* key belongs to one VM; the id is",
                     "the one UTM gave it — a placeholder, in an anonymised report — or its name for a record",
                     "made before Winbar knew the id."]

        let global = keys.filter { VMSettings.split($0) == nil }.sorted()
        if !global.isEmpty {
            lines.append("")
            lines.append("This copy of Winbar")
            lines += facts(global.map { ($0, describe(values[$0])) }).map { "  " + $0 }
        }

        var perVM: [String: [(setting: String, key: String)]] = [:]
        for key in keys {
            guard let split = VMSettings.split(key) else { continue }
            perVM[split.token, default: []].append((split.setting, key))
        }
        for token in perVM.keys.sorted() {
            let name = (values[VMSettings.key(Config.Key.recordedName, for: token)] as? String) ?? token
            lines.append("")
            lines.append("VM \"\(name)\"" + (name == token ? "" : " (vm.\(token).*)"))
            let rows = perVM[token]!.sorted { $0.setting < $1.setting }
            lines += facts(rows.map { ($0.setting, describe(values[$0.key])) }).map { "  " + $0 }
        }
        return lines
    }

    /// One settings value as text. Dates and booleans are spelled out rather than printed as the
    /// numbers `UserDefaults` keeps them as, because a bug report is read by a person.
    static func describe(_ value: Any?) -> String {
        switch value {
        case nil: return "(not set)"
        case let text as String: return text
        case let date as Date: return settingDate.string(from: date)
        case let list as [Any]: return list.isEmpty ? "(empty list)" : list.map { describe($0) }.joined(separator: ", ")
        case let dictionary as [String: Any]:
            return dictionary.keys.sorted().map { "\($0)=\(describe(dictionary[$0]))" }.joined(separator: ", ")
        case let data as Data: return "\(data.count) bytes"
        case let number as NSNumber:
            // UserDefaults keeps a Bool as an NSNumber; only CFBoolean knows it was one.
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "yes" : "no" }
            return number.stringValue
        default: return String(describing: value!)
        }
    }

    // MARK: - Trimming a log

    struct Trimmed: Equatable {
        var text: String
        /// The sentence that says what was left out. Always present, including when nothing was.
        var note: String
    }

    /// The last `lines` lines, and then no more than `bytes` bytes of those — with a sentence saying
    /// what that cost. A create log of a failed install runs to thousands of lines and its serial
    /// log to more; the end is where the failure is, and the whole thing is not sendable.
    ///
    /// **Whole lines come off first, and a cut inside a line never leaves half a word.** This used
    /// to take the byte limit off the front in characters, which put it wherever the arithmetic
    /// landed — in the middle of a UUID as readily as between two words. `--anonymise` runs over the
    /// finished report, and the last twenty characters of an id are not id-shaped, so the sweep saw
    /// nothing and a fragment of a real identifier went into a public issue beside placeholders that
    /// had dealt with every whole one. So: drop lines until it fits, and only when a single line is
    /// still too big cut inside it — then drop the partial token the cut made, unless the whole
    /// remainder is one token, which is the case this can cut inside a line for in the first place
    /// (a serial log can be one burst of firmware text with no newline in it, and the choice there
    /// is a fragment or nothing at all).
    static func trim(_ text: String, lines limit: Int, bytes maxBytes: Int) -> Trimmed {
        var all = text.components(separatedBy: "\n")
        if all.last == "" { all.removeLast() }   // the trailing newline, not a line
        guard !all.isEmpty else { return Trimmed(text: "", note: "The file is empty.") }

        var kept = Array(all.suffix(limit))
        let forCount = all.count - kept.count
        var forSize = 0
        while kept.count > 1, kept.joined(separator: "\n").utf8.count > maxBytes {
            kept.removeFirst()
            forSize += 1
        }
        var body = kept.joined(separator: "\n")
        var cutBytes = 0
        if body.utf8.count > maxBytes {
            let before = body.utf8.count
            body = String(body.suffix(max(0, body.count - (before - maxBytes))))
            // Whatever word the cut landed in goes with it — unless it is the only word left, which
            // is the one case cutting inside a line exists for.
            if let space = body.firstIndex(where: \.isWhitespace),
               !body[body.index(after: space)...].isEmpty {
                body = String(body[body.index(after: space)...])
            }
            cutBytes = before - body.utf8.count      // what was actually taken, not what was over
        }

        let cutLines = forCount + forSize
        var note = cutLines == 0
            ? (all.count == 1 ? "All 1 line is here." : "All \(number(all.count)) lines are here.")
            : "The last \(number(kept.count)) lines of \(number(all.count)); \(number(cutLines)) earlier lines are not here."
        if forSize > 0 {
            note += " \(number(forSize)) of those went because the tail was still too big to send,"
                + " not because of the line limit."
        }
        if cutBytes > 0 {
            note += " The line that was left was still too big, so about \(number(cutBytes / 1024)) KB was"
                + " cut from the front of it — up to the first space, where there is one, so nothing is"
                + " left half-written."
        }
        return Trimmed(text: body, note: note)
    }

    // MARK: - Crash reports

    /// The headline of one UTM crash report: when it happened, what killed it, and the top frame of
    /// the thread that died. Never the whole report — a .ips is hundreds of kilobytes of every
    /// thread's stack, and the first two lines are what says whether this is utmapp/UTM#7882 again.
    ///
    /// macOS writes .ips as a JSON header line followed by a JSON body. Older ones (and some
    /// third-party writers) are the plain-text crash log instead, so that is read too rather than
    /// reported as unreadable.
    ///
    /// Worth knowing before adding a field to this: a .ips is full of ids that identify this Mac
    /// rather than UTM — `incident_id` and `slice_uuid` in the header, `bootSessionUUID`,
    /// `sleepWakeUUID` and every `usedImages[].uuid` in the body. None of them is read, which is why
    /// section 6 has nothing for `--anonymise` to take out; the file name carries a timestamp and no
    /// id. Anything added here that is one of those is a host identifier in a published file, and
    /// `--anonymise` would reduce it to `<id-N>`, which is worth less than not printing it.
    static func crashHeadline(fileName: String, contents: String, modified: Date?) -> [String] {
        let when = crashDate(contents) ?? modified.map { settingDate.string(from: $0) } ?? "date unknown"
        var first = "\(fileName) — \(when)"
        if let version = crashHeader(contents)?["app_version"] as? String { first += ", UTM \(version)" }
        var lines = [first]
        if let reason = crashReason(contents) { lines.append("    " + reason) }
        lines.append("    " + (crashTopFrame(contents) ?? "the crashing thread's top frame couldn't be read from this file"))
        return lines
    }

    /// The JSON object on the first line, which carries the app, its version and the timestamp.
    static func crashHeader(_ contents: String) -> [String: Any]? {
        guard let line = contents.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first,
              let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }

    /// Everything after the first line: the report proper.
    static func crashBody(_ contents: String) -> [String: Any]? {
        let parts = contents.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let data = parts[1].data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }

    static func crashDate(_ contents: String) -> String? {
        if let stamp = crashHeader(contents)?["timestamp"] as? String { return stamp }
        // The plain-text form: "Date/Time:  2026-09-19 12:01:53.123 -0400".
        return textField(contents, "Date/Time")
    }

    /// What macOS says killed it: the exception and signal, or the plain-text equivalents.
    static func crashReason(_ contents: String) -> String? {
        if let body = crashBody(contents) {
            var parts: [String] = []
            if let exception = body["exception"] as? [String: Any] {
                if let type = exception["type"] as? String { parts.append(type) }
                if let signal = exception["signal"] as? String { parts.append(signal) }
            }
            if let termination = body["termination"] as? [String: Any],
               let indicator = termination["indicator"] as? String { parts.append(indicator) }
            return parts.isEmpty ? nil : "ended with: " + parts.joined(separator: " / ")
        }
        guard let type = textField(contents, "Exception Type") else { return nil }
        return "ended with: " + type
    }

    /// The top frame of the thread that crashed — the one line that usually says which bug this is.
    static func crashTopFrame(_ contents: String) -> String? {
        if let body = crashBody(contents) {
            guard let threads = body["threads"] as? [[String: Any]] else { return nil }
            let faulting = (body["faultingThread"] as? Int)
                ?? threads.firstIndex { $0["triggered"] as? Bool == true }
            guard let index = faulting, threads.indices.contains(index),
                  let frames = threads[index]["frames"] as? [[String: Any]], let top = frames.first
            else { return nil }
            let images = body["usedImages"] as? [[String: Any]] ?? []
            let image = (top["imageIndex"] as? Int)
                .flatMap { images.indices.contains($0) ? images[$0] : nil }
                .flatMap { ($0["name"] as? String) ?? ($0["path"] as? String).map { ($0 as NSString).lastPathComponent } }
            // Apple's own reports carry no symbols for a release build, so the frame is usually the
            // image and an offset into it. That is still the fact that matters: two reports with the
            // same offset in the same UTM version are the same crash.
            let where_ = (top["symbol"] as? String).map { image == nil ? $0 : "\($0) in \(image!)" }
                ?? "\(image ?? "an unnamed image")+\(top["imageOffset"] as? Int ?? 0)"
            let queue = (threads[index]["queue"] as? String).map { " on \($0)" } ?? ""
            return "thread \(index)\(queue) crashed; its top frame: \(where_)"
        }
        // The plain-text form: the line after "Thread N Crashed:".
        let lines = contents.components(separatedBy: "\n")
        guard let marker = lines.firstIndex(where: { $0.contains("Crashed:") && $0.hasPrefix("Thread") }),
              lines.indices.contains(marker + 1)
        else { return nil }
        let frame = lines[marker + 1].trimmingCharacters(in: .whitespaces)
        return frame.isEmpty ? nil : "\(lines[marker].trimmingCharacters(in: .whitespaces)) top frame: \(frame)"
    }

    /// `Label:   value` out of a plain-text crash log.
    private static func textField(_ contents: String, _ label: String) -> String? {
        for line in contents.components(separatedBy: "\n") where line.hasPrefix(label + ":") {
            let value = line.dropFirst(label.count + 1).trimmingCharacters(in: .whitespaces)
            if !value.isEmpty { return value }
        }
        return nil
    }

    // MARK: - Where the file goes

    static func fileName(for date: Date) -> String { "winbar-diagnose-" + fileStamp.string(from: date) + ".txt" }

    /// The path to write to.
    ///
    /// With no `--out` it is a file named for today on the Desktop, which is where someone who is
    /// about to attach a file to an issue will look for it; with a Desktop that isn't there (it
    /// happens) the home folder instead. `--out` naming a folder puts today's file in it; `--out`
    /// naming a file is taken at its word and overwrites, because that is what a path someone typed
    /// means. Only the generated names are made unique, so running it twice in a day keeps both.
    static func destination(out: String?, desktop: URL, fallback: URL, now: Date,
                            isDirectory: (URL) -> Bool, exists: (URL) -> Bool) -> URL {
        let name = fileName(for: now)
        guard let out, !out.trimmingCharacters(in: .whitespaces).isEmpty else {
            let directory = isDirectory(desktop) ? desktop : fallback
            return unique(directory.appendingPathComponent(name), exists: exists)
        }
        let typed = URL(fileURLWithPath: (out as NSString).expandingTildeInPath)
        if isDirectory(typed) { return unique(typed.appendingPathComponent(name), exists: exists) }
        return typed
    }

    /// `…-2`, `…-3`, and so on. Two reports on the same day are two reports.
    static func unique(_ url: URL, exists: (URL) -> Bool) -> URL {
        guard exists(url) else { return url }
        let directory = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        for n in 2...99 {
            let candidate = directory.appendingPathComponent("\(base)-\(n)").appendingPathExtension(ext)
            if !exists(candidate) { return candidate }
        }
        return url
    }

    // MARK: - Small things

    /// 1,842. Fixed locale, so a report reads the same wherever it was made and the tests can say
    /// what they expect.
    static func number(_ value: Int) -> String {
        numbers.string(from: NSNumber(value: value)) ?? String(value)
    }

    private static let numbers: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        // The POSIX locale groups nothing, and "1842 lines" is harder to read at a glance than
        // "1,842" is. Said explicitly rather than left to a locale, so the file reads the same
        // whoever made it.
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        formatter.groupingSize = 3
        return formatter
    }()

    static let fileStamp: DateFormatter = fixed("yyyy-MM-dd")
    static let reportStamp: DateFormatter = fixed("yyyy-MM-dd 'at' HH:mm:ss ZZZZZ")
    static let settingDate: DateFormatter = fixed("yyyy-MM-dd HH:mm:ss ZZZZZ")

    private static func fixed(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }
}
