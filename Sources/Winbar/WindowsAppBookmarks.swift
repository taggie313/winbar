import AppKit
import Foundation

/// Windows App's own command line, which is how Winbar saves a PC instead of asking you to add one
/// by hand.
///
/// `"/Applications/Windows App.app/Contents/MacOS/Windows App" --script bookmark …` does its work,
/// prints to stdout and exits; a *bookmark* is what the app's interface calls a saved PC. The app is
/// `LSUIElement`, so nothing appears on screen. The binary is run directly, never through a shell
/// and never through `open -a`: a copy that is already running would swallow the arguments and just
/// bring its window forward.
///
/// It can save a PC but it cannot open one — there is no connect verb, `rdp://` carries settings but
/// never a password, and `ms-rd:` addresses cloud workspaces. That is why Connect still presses the
/// tile through the Accessibility API (see `WindowsApp`).
///
/// ## The password goes on the argv
///
/// `bookmark write` takes `--password`, and Windows App has no stdin form and no `--password-file`.
/// For the second or so that call takes, the password is one of this process's arguments, where any
/// other program running as you could read it out of the process table. That is the trade for not
/// making you type it into Windows App yourself. Winbar keeps the call short, runs the binary
/// directly so nothing reaches your shell history, never logs the password, and redacts it out of
/// anything Windows App prints back. Nothing here stores it or hands it back to a caller.
///
/// ## Two writers on one store
///
/// `--script` opens the same Core Data store as a running copy of Windows App, and Core Data does
/// not support two processes on one store. Winbar cannot read that store, let alone back it up
/// (it is TCC App Data-protected), so a lost update would take every saved PC you have, including
/// ones that have nothing to do with Winbar. `write` and `delete` therefore refuse while Windows App
/// is running, and say why. `list` and `export` only read, so they are allowed.
enum WindowsAppBookmarks {
    /// One saved PC, as `bookmark list` prints it.
    struct Bookmark: Equatable, Sendable {
        /// The quoted name on the line: the friendly name when one was set, else the host. This is
        /// also what the tile's accessibility description carries, which is what Connect matches on.
        var name: String
        /// Windows App's own unique id. Uppercase UUIDs in 11.4.1; the 7-digit numbers in the app's
        /// help examples are older, so nothing here assumes a shape.
        var id: String
    }

    /// What `save` did. Never "wrote over what was there".
    enum Saved: Equatable, Sendable {
        case created(Bookmark)
        /// Windows App already had a saved PC for this host, so Winbar left it exactly as it is: it
        /// may carry a password the person typed, and `bookmark write` on an existing id replaces
        /// the host, user name and password without asking.
        case alreadyThere(Bookmark)
    }

    enum Failure: Error, CustomStringConvertible, Equatable {
        case notInstalled
        /// Windows App is open. Not an error to work around — see the note above.
        case appRunning
        /// A freshly minted id was one Windows App already has. Writing would rewrite that PC.
        case idInUse(String)
        /// Windows App refused, or couldn't be run. `output` has already had the password redacted.
        case failed(what: String, output: String)
        /// The write reported nothing wrong, but the PC isn't in the list afterwards.
        case notSaved(id: String)

        var description: String {
            switch self {
            case .notInstalled:
                return "Windows App isn't installed"
            case .appRunning:
                return Copy.quitFirst
            case .idInUse(let id):
                return "Windows App already has a saved PC with the id \(id), and writing would replace it"
            case .failed(let what, let output):
                return output.isEmpty ? "Windows App couldn't \(what)" : "Windows App couldn't \(what): \(output)"
            case .notSaved(let id):
                return "Windows App reported no problem saving the PC, but it isn't in its list afterwards (id \(id))"
            }
        }
    }

    enum Copy {
        static let readsPaused = "Windows App's automatic setup command stopped responding. Winbar won't keep retrying it in the background. You can still sign in through Windows App."

        /// The refusal, in the voice the rest of Winbar uses: what to do, then why.
        static let quitFirst =
            "Quit Windows App first. Winbar saves the PC through Windows App's own command line, which opens the same "
            + "database the running app has open; two programs writing that database at once can lose every PC you have "
            + "saved, and it isn't a file Winbar can read or put back."

        /// Said wherever Winbar is about to hand the password over (create's password block, setup's
        /// offer). The honest half of the trade, at the moment it is being made.
        static let passwordGoesToWindowsApp =
            "Winbar hands it straight to Windows App, which keeps it in your login keychain, the same as when you type it "
            + "in yourself. Winbar keeps no copy. For the second that takes, the password is one of Windows App's command "
            + "line arguments, where another program running as you could read it: Windows App has no other way to be "
            + "given a password without you typing it in again."

        /// The step as a person would do it themselves — the fallback whenever Winbar can't.
        static func byHand(host: String, user: String?) -> String {
            "In Windows App: Devices → + → Add PC. PC name: \(host). Credentials: add your Windows user account"
                + (user.map { " (\($0))" } ?? "") + " with its password. Save."
        }
    }

    // MARK: - Running the command line

    /// A timed-out reader must not run again on every wizard page. Windows App 11.4.2 was
    /// observed deadlocking during provider startup before processing `bookmark list`.
    /// Remember only that timeout, not the list itself: an unanswered read is never an empty list.
    /// An explicit retry, relaunching Winbar, or replacing the executable permits another attempt.
    struct ExecutableIdentity: Hashable {
        var path: String
        var modified: Date?
        var size: Int?

        init(path: String, modified: Date? = nil, size: Int? = nil) {
            self.path = path
            self.modified = modified
            self.size = size
        }

        init(_ url: URL) {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            self.init(path: url.resolvingSymlinksInPath().path,
                      modified: values?.contentModificationDate, size: values?.fileSize)
        }
    }

    final class ReadGate {
        static let readTimeout: TimeInterval = 10
        private let lock = NSLock()
        private var blocked = Set<ExecutableIdentity>()

        func reset() {
            lock.lock(); defer { lock.unlock() }
            blocked.removeAll()
        }

        func run(executable: ExecutableIdentity, arguments: [String], what: String,
                 timeout: TimeInterval,
                 operation: (TimeInterval) -> CommandResult) throws -> CommandResult {
            let reads = arguments.first == "list" || arguments.first == "export"
            lock.lock()
            let unavailable = reads && blocked.contains(executable)
            lock.unlock()
            if unavailable { throw Failure.failed(what: what, output: Copy.readsPaused) }
            // Writes retain their existing deadline and are never retried here.
            let result = operation(reads ? min(timeout, Self.readTimeout) : timeout)
            if reads && result.timedOut {
                lock.lock(); blocked.insert(executable); lock.unlock()
            }
            return result
        }
    }

    private static let readGate = ReadGate()

    static func retryReadCommands() { readGate.reset() }

    /// The binary inside the bundle. `--script` has to reach a *new* process, so this is the path
    /// that gets executed; `open -a` would hand the arguments to a running copy instead.
    static var executableURL: URL? {
        guard let app = WindowsApp.appURL,
              let name = Bundle(url: app)?.infoDictionary?["CFBundleExecutable"] as? String,
              !name.isEmpty
        else { return nil }
        return app.appendingPathComponent("Contents/MacOS", isDirectory: true).appendingPathComponent(name)
    }

    /// Whether a copy of Windows App is open, which is what `save` and `delete` refuse on. The same
    /// question `WindowsApp.openSavedPC` already asks.
    static var appIsRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Config.windowsAppBundleID).isEmpty
    }

    /// Why a write can't go ahead, or nil when it can. Only `save` and `delete` ask: `list` and
    /// `export` read, and reading alongside the running app is what lets doctor say what Windows App
    /// has while the person is using it. Pure, so the rule can be checked without Windows App.
    static func refusalToWrite(installed: Bool, appRunning: Bool) -> Failure? {
        if !installed { return .notInstalled }
        if appRunning { return .appRunning }
        return nil
    }

    /// Runs one `--script bookmark …` command and returns its stdout.
    ///
    /// `secret`, when there is one, is redacted out of everything that comes back, so a refusal that
    /// quotes its own arguments can't carry the password into an error, a log line or the screen.
    /// The argv itself is never printed anywhere: `what` is what the caller says instead.
    private static func script(_ arguments: [String], secret: String? = nil, what: String,
                               timeout: TimeInterval = 45) throws -> String {
        guard let executable = executableURL else { throw Failure.notInstalled }
        let result = try readGate.run(executable: ExecutableIdentity(executable), arguments: arguments,
                                      what: what, timeout: timeout) { limit in
            Shell.run(executable.path, ["--script", "bookmark"] + arguments, timeout: limit)
        }
        guard !result.timedOut else { throw Failure.failed(what: what, output: "Windows App didn't answer in time") }
        let output = redact(result.output, secret: secret)
        guard result.status == 0 else { throw Failure.failed(what: what, output: output) }
        // The handler terminates the app itself, so a refusal can still exit 0 and only say so on
        // stdout. The text has to be read as well as the status.
        guard !refused(output) else { throw Failure.failed(what: what, output: output) }
        return redact(result.text, secret: secret)
    }

    /// Windows App's own refusals, in its handler's words. Matched as fragments because each one is
    /// followed by a reason Winbar has no use for.
    static func refused(_ output: String) -> Bool {
        let refusals = ["cannot save bookmark", "no bookmark id provided", "adding bookmark not successful",
                        "failed to save bookmark", "failed to delete bookmark", "failed to export bookmark"]
        let lowered = output.lowercased()
        return refusals.contains { lowered.contains($0) }
    }

    /// Replaces the password wherever it appears. Nothing that leaves this file may carry it.
    static func redact(_ text: String, secret: String?) -> String {
        guard let secret, !secret.isEmpty else { return text }
        return text.replacingOccurrences(of: secret, with: "••••••")
    }

    // MARK: - Reading what Windows App has

    /// Every saved PC. Allowed while Windows App is open: it only reads.
    static func list() throws -> [Bookmark] {
        parseList(try script(["list"], what: "list its saved PCs"))
    }

    /// `bookmark list` prints one saved PC per line: the name in double quotes, a comma, a space,
    /// then the id — `"mypc.local", 8B1F0C52-0000-4E2A-9A11-DEADBEEF0002`.
    ///
    /// The name is the person's, so it can hold commas and any script at all, while an id can't hold
    /// a space. So the name is everything between the first quote on the line and the last one, and
    /// the id is what follows the comma after that. A line that isn't that shape is one of the app's
    /// own messages: skipped, rather than guessed at. Pure.
    static func parseList(_ text: String) -> [Bookmark] {
        text.split(separator: "\n", omittingEmptySubsequences: false).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("\"") else { return nil }
            let afterOpen = line.index(after: line.startIndex)
            guard let close = line.lastIndex(of: "\""), close >= afterOpen else { return nil }
            let rest = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
            guard rest.hasPrefix(",") else { return nil }
            let id = rest.dropFirst().trimmingCharacters(in: .whitespaces)
            guard !id.isEmpty, !id.contains(where: \.isWhitespace) else { return nil }
            return Bookmark(name: String(line[afterOpen..<close]), id: id)
        }
    }

    /// One saved PC as RDP-file text. The only way to learn a PC's host: `list` prints the friendly
    /// name when there is one. Read-only, so this too is allowed while Windows App is open.
    static func export(_ id: String) throws -> String {
        try script(["export", id], what: "export the saved PC \(id)")
    }

    /// One `key:s:value` line out of RDP-file syntax (`full address:s:mypc.local`). The value is the
    /// rest of the line. Pure.
    static func rdpValue(_ key: String, in text: String) -> String? {
        let prefix = key + ":s:"
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let marker = line.range(of: prefix, options: [.caseInsensitive, .anchored]) else { continue }
            let value = String(line[marker.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !value.isEmpty { return value }
        }
        return nil
    }

    /// What a saved PC actually connects to. Pure.
    static func address(inExport export: String) -> String? { rdpValue("full address", in: export) }

    // MARK: - Deciding whether there is one already

    /// Which saved PC, if any, already stands for `host` — the question that decides whether Winbar
    /// writes one at all.
    ///
    /// `addresses` is each bookmark's `full address:s:`, for the ones `export` could be read for. An
    /// address is what the connection really uses, so it settles the question. A bookmark whose
    /// address couldn't be read falls back to the name `list` printed, which is the host only when
    /// nobody gave the PC a friendly name — which is exactly what Winbar's own 0.1.0 instructions
    /// told people to do. Pure, so the decision can be checked without Windows App.
    static func match(host: String, in bookmarks: [Bookmark], addresses: [String: String]) -> Bookmark? {
        func same(_ one: String, _ other: String) -> Bool { one.caseInsensitiveCompare(other) == .orderedSame }
        if let byAddress = bookmarks.first(where: { addresses[$0.id].map { same($0, host) } == true }) { return byAddress }
        return bookmarks.first { addresses[$0.id] == nil && same($0.name, host) }
    }

    /// The saved PC for `host`, asked of Windows App itself.
    static func savedPC(for host: String) throws -> Bookmark? {
        let bookmarks = try list()
        return match(host: host, in: bookmarks, addresses: addresses(of: bookmarks, matching: host))
    }

    /// `full address:s:` for each saved PC, stopping at the first that is `host`: each export is
    /// another run of Windows App's binary, and once one matches the rest can't change the answer.
    /// A PC that won't export is left out rather than counted as a non-match, so `match` falls back
    /// to its name.
    private static func addresses(of bookmarks: [Bookmark], matching host: String) -> [String: String] {
        var found: [String: String] = [:]
        for bookmark in bookmarks {
            guard let text = try? export(bookmark.id), let address = address(inExport: text) else { continue }
            found[bookmark.id] = address
            if address.caseInsensitiveCompare(host) == .orderedSame { break }
        }
        return found
    }

    /// A fresh id for a new saved PC.
    ///
    /// `bookmark write` is create-*or-edit*: handed an id that already exists it rewrites that PC's
    /// host, user name and password with no warning. So the id is minted against the list rather
    /// than derived from anything, and a collision is refused instead of risked. Uppercase, which is
    /// the shape Windows App's own ids have. Pure, given `make`.
    static func newID(notIn taken: [String], make: () -> String = { UUID().uuidString }) throws -> String {
        let taken = Set(taken.map { $0.lowercased() })
        var last = ""
        for _ in 1...8 {
            last = make().uppercased()
            if !taken.contains(last.lowercased()) { return last }
        }
        throw Failure.idInUse(last)
    }

    /// The friendly name to give a new saved PC: the one asked for, unless another saved PC already
    /// carries it. Two tiles with the same accessibility description would make Connect's choice
    /// between them arbitrary, so Winbar gives up the name rather than the certainty; the tile then
    /// matches on the host. Pure.
    static func freeName(_ wanted: String?, notIn bookmarks: [Bookmark]) -> String? {
        guard let wanted = wanted?.trimmingCharacters(in: .whitespacesAndNewlines), !wanted.isEmpty else { return nil }
        return bookmarks.contains { $0.name.caseInsensitiveCompare(wanted) == .orderedSame } ? nil : wanted
    }

    // MARK: - Writing

    /// Saves a PC for `host` in Windows App, or reports the one that is already there.
    ///
    /// Refuses while Windows App is open (see the note on this type). Mints an id no saved PC has,
    /// writes, then reads the list back: the handler exits 0 whatever happens, so a write is only
    /// believed once `list` shows it.
    ///
    /// `password` is used for the one `write` call and nowhere else. It is not stored, not logged,
    /// not returned, and redacted out of anything Windows App prints back.
    ///
    /// `passwordVerified` is false when Winbar was handed a password it has no way to check. A saved
    /// PC retries by itself by default, and Windows locks a local account after ten failed sign-ins,
    /// so an unchecked password gets `--autoreconnect false` until a connection has worked.
    @discardableResult
    static func save(host: String, user: String, password: String, friendlyName: String?,
                     passwordVerified: Bool = true) throws -> Saved {
        if let refusal = refusalToWrite(installed: executableURL != nil, appRunning: appIsRunning) { throw refusal }

        let existing = try list()
        if let already = match(host: host, in: existing, addresses: addresses(of: existing, matching: host)) {
            return .alreadyThere(already)
        }
        let id = try newID(notIn: existing.map(\.id))

        var arguments = ["write", id, "--hostname", host, "--username", user, "--password", password]
        if let name = freeName(friendlyName, notIn: existing) { arguments += ["--friendlyname", name] }
        // A VM has no fixed screen, so the session should follow the window. Everything else is left
        // at Windows App's own defaults: nothing else has been measured, and a setting has to pay for
        // itself before Winbar sets it.
        arguments += ["--dynamicdisplay", "true"]
        if !passwordVerified { arguments += ["--autoreconnect", "false"] }
        _ = try script(arguments, secret: password, what: "save a PC for \(host)")

        guard let saved = try list().first(where: { $0.id.caseInsensitiveCompare(id) == .orderedSame }) else {
            throw Failure.notSaved(id: id)
        }
        return .created(saved)
    }

    /// Removes a saved PC. Refuses while Windows App is open, for the same reason `save` does.
    static func delete(_ id: String) throws {
        if let refusal = refusalToWrite(installed: executableURL != nil, appRunning: appIsRunning) { throw refusal }
        _ = try script(["delete", id], what: "delete the saved PC \(id)")
    }
}
