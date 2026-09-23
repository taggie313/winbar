import AppKit
import Foundation

// The two apps Winbar drives but doesn't ship — UTM, which runs the VM, and Microsoft's Windows
// App, which shows its desktop — and how Winbar offers to get them instead of telling someone to
// type a Homebrew command. Part of the audience has never opened Terminal, and "go run this first"
// is where they stop.
//
// The rules this file keeps to:
//   · Nothing is installed without a yes to the question `DependencyCopy` asks (`agreed:` below).
//   · Homebrew, when it's there, does the installing; Winbar only asks it. It is never installed
//     for anyone: a package manager isn't Winbar's to force on a Mac.
//   · No sudo, ever, from Winbar (`DependencyCommand.isPrivileged` refuses it). Homebrew running
//     Microsoft's installer package asks for the Mac password itself; that prompt is Homebrew's,
//     and the copy says so.
//   · Nothing downloaded is opened before Apple's notarization and the developer's team have been
//     checked, and nothing installed is trusted before its bundle id, signature, team and version
//     have been.

/// One of the apps Winbar needs, with everything that identifies it.
enum Dependency: String, CaseIterable {
    /// The VM host. Winbar drives its tools; it doesn't replace it.
    case utm
    /// Microsoft's Remote Desktop client, which Connect opens.
    case windowsApp

    var name: String {
        switch self {
        case .utm: return "UTM"
        case .windowsApp: return "Windows App"
        }
    }

    /// One sentence for someone who has never heard of it.
    var what: String {
        switch self {
        case .utm:
            return "UTM is the app that runs the Windows virtual machine. It's free and open source, from Turing Software."
        case .windowsApp:
            return "Windows App is Microsoft's Remote Desktop client — the window Connect opens your Windows desktop in."
        }
    }

    var bundleID: String {
        switch self {
        case .utm: return Config.utmBundleID
        case .windowsApp: return Config.windowsAppBundleID
        }
    }

    /// The Homebrew cask that installs it.
    var cask: String {
        switch self {
        case .utm: return "utm"
        case .windowsApp: return "windows-app"
        }
    }

    /// The Apple developer team the app must be signed by, whichever way it arrived. Read from the
    /// signature (`TeamIdentifier`), not from the leaf certificate: an App Store copy's leaf carries
    /// no team, which is exactly how Windows App is shipped.
    var teamID: String {
        switch self {
        case .utm: return "WDNLXAD4W8"        // Turing Software, LLC
        case .windowsApp: return "UBF8T346G9" // Microsoft Corporation
        }
    }

    var vendor: String {
        switch self {
        case .utm: return "Turing Software, LLC"
        case .windowsApp: return "Microsoft"
        }
    }

    /// The oldest version Winbar works with, or nil when any version will do. UTM's floor is
    /// `winbar create`'s: 4.7 brought the scripting create needs.
    var minimumVersion: (major: Int, minor: Int)? {
        switch self {
        case .utm: return CreatePreflight.minimumVersion
        case .windowsApp: return nil
        }
    }

    var minimumVersionText: String? {
        minimumVersion.map { "\($0.major).\($0.minor)" }
    }

    /// UTM's own disk image, from the release getutm.app links to. Winbar checks Apple's
    /// notarization and the signing team before it opens it.
    static let utmDownloadURL = "https://github.com/utmapp/UTM/releases/latest/download/UTM.dmg"
    /// About that: UTM 4.7.5's UTM.dmg is 250 MB, and the app is 1.1 GB once installed.
    static let utmDownloadMB = 250
    static let utmInstalledGB = "1.1 GB"
    /// Microsoft ships Windows App through the Mac App Store, and Homebrew from the same installer
    /// package Microsoft's own updater uses (about 100 MB).
    static let windowsAppStoreID = "1295203466"
    static let windowsAppDownloadMB = 100

    /// Where macOS says the app is, or the obvious place. The fallback matters for the seconds
    /// after an install, before LaunchServices has caught up with a folder it didn't watch.
    var appURL: URL? {
        let known: URL?
        switch self {
        case .utm: known = UTM.appURL
        case .windowsApp: known = WindowsApp.appURL
        }
        if let known { return known }
        let applications = URL(fileURLWithPath: "/Applications").appendingPathComponent("\(name).app")
        return FileManager.default.fileExists(atPath: applications.path) ? applications : nil
    }

    var installedVersion: String? {
        switch self {
        case .utm: return UTM.version
        case .windowsApp: return WindowsApp.version
        }
    }
}

// MARK: - Where it stands

/// What an app bundle on this Mac says about itself: enough to decide whether it is the app Winbar
/// expects. Built by `AppSignature.read`; a plain value so every decision below can be tested.
struct InstalledApp: Equatable {
    var path: String
    var bundleID: String?
    var version: String?
    /// From the signature, not from the certificate's subject (see `Dependency.teamID`).
    var teamID: String?
    /// `codesign --verify --strict` passed, and the chain anchors to Apple.
    var signatureValid: Bool
}

/// The four answers that matter, and the one that means "don't touch it".
enum DependencyState: Equatable {
    case installed(version: String?)
    case missing
    case tooOld(version: String, minimum: String)
    /// The app is there but isn't the one Winbar expects: wrong bundle id, a broken signature, or
    /// another developer's. Winbar says so and stops rather than replacing someone's app.
    case wrongSignature(String)

    var isInstalled: Bool { if case .installed = self { return true } else { return false } }
}

enum Dependencies {

    /// The decision table, from facts alone: no file system, no network, no shell. `app` is nil when
    /// macOS has no copy of it.
    static func state(of dependency: Dependency, app: InstalledApp?) -> DependencyState {
        guard let app else { return .missing }
        guard let bundleID = app.bundleID, bundleID == dependency.bundleID else {
            return .wrongSignature("\(app.path) says it is \(app.bundleID ?? "no app at all"), not \(dependency.bundleID)")
        }
        guard app.signatureValid else {
            return .wrongSignature("\(dependency.name)'s signature doesn't check out (\(app.path))")
        }
        guard let team = app.teamID else {
            return .wrongSignature("\(dependency.name) at \(app.path) isn't signed by anyone macOS can name")
        }
        guard team == dependency.teamID else {
            return .wrongSignature("\(dependency.name) at \(app.path) is signed by team \(team), not "
                                       + "\(dependency.vendor)'s (\(dependency.teamID))")
        }
        if let minimum = dependency.minimumVersion, let version = app.version, !meets(version, minimum: minimum) {
            return .tooOld(version: version, minimum: "\(minimum.major).\(minimum.minor)")
        }
        return .installed(version: app.version)
    }

    /// Whether `version` is at least `minimum`. An unreadable version passes: the app is there, it
    /// just won't say, which is how `CreatePreflight` already treats UTM.
    static func meets(_ version: String, minimum: (major: Int, minor: Int)) -> Bool {
        guard let parsed = CreatePreflight.parseVersion(version) else { return true }
        return parsed.major > minimum.major || (parsed.major == minimum.major && parsed.minor >= minimum.minor)
    }

    /// What's on this Mac now: the app bundle plus what `codesign` says about it. Blocking (two
    /// short `codesign` runs), so the menu bar app calls it off the main thread.
    static func inspect(_ dependency: Dependency) -> InstalledApp? {
        guard let url = dependency.appURL else { return nil }
        return AppSignature.read(url.path, expectedTeam: dependency.teamID)
    }

    /// Where things stand, asking the Mac. Blocking.
    static func state(of dependency: Dependency) -> DependencyState {
        state(of: dependency, app: inspect(dependency))
    }
}

// MARK: - Homebrew

/// Finding `brew`, and nothing else: Winbar never installs Homebrew, and never asks anyone to.
enum Homebrew {
    /// The two prefixes Homebrew itself documents: Apple silicon, then the Intel one (a Mac migrated
    /// from an Intel machine can still have it, and a Rosetta shell uses it).
    static let standardPaths = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]

    /// Where brew is, from the two standard layouts and then from `brew --prefix` for a Homebrew
    /// installed somewhere else. Pure: `isExecutable` probes the file system and `prefixOnPATH` runs
    /// `brew --prefix`, so every layout — and no Homebrew at all — can be tested.
    static func locate(isExecutable: (String) -> Bool, prefixOnPATH: () -> String?) -> String? {
        if let known = standardPaths.first(where: isExecutable) { return known }
        guard let prefix = prefixOnPATH()?.trimmingCharacters(in: .whitespacesAndNewlines), !prefix.isEmpty else {
            return nil
        }
        // `brew --prefix` prints the prefix, and brew itself lives in its bin. A prefix that doesn't
        // have one isn't a Homebrew this can use.
        let candidate = URL(fileURLWithPath: prefix).appendingPathComponent("bin/brew").path
        return isExecutable(candidate) ? candidate : nil
    }

    /// Asked once per run: the probe costs a process, and Homebrew doesn't appear mid-run.
    private static var cached: String??

    /// `WINBAR_IGNORE_HOMEBREW=1` makes Winbar act as though Homebrew weren't installed, so the
    /// paths for a Mac without it — UTM's signed download, Windows App's App Store page — can be
    /// tried on a Mac that has it. Nothing else reads it, and it installs nothing by itself.
    static var isIgnored: Bool { ProcessInfo.processInfo.environment["WINBAR_IGNORE_HOMEBREW"] == "1" }

    static var path: String? {
        if isIgnored { return nil }
        if let cached { return cached }
        let found = locate(isExecutable: { FileManager.default.isExecutableFile(atPath: $0) },
                           prefixOnPATH: { prefixFromPATH() })
        cached = found
        return found
    }

    /// Where Homebrew keeps what it knows about a cask it installed: `Caskroom/<cask>/.metadata`,
    /// under the prefix whose `bin` holds `brew`. `brew upgrade --cask` needs it, and refuses a cask
    /// Homebrew didn't install ("Cask 'utm' is not installed.", cask/upgrade.rb) whatever is in
    /// /Applications. Pure.
    static func caskMetadata(_ cask: String, brew: String) -> String {
        URL(fileURLWithPath: brew).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Caskroom").appendingPathComponent(cask).appendingPathComponent(".metadata").path
    }

    /// Whether Homebrew installed `cask`, so it can update it. One file-system check; false without
    /// Homebrew.
    static func hasCask(_ cask: String, brew: String?) -> Bool {
        guard let brew else { return false }
        return FileManager.default.fileExists(atPath: caskMetadata(cask, brew: brew))
    }

    /// `brew --prefix` through the login shell's PATH. `/usr/bin/env` because the path is exactly
    /// what isn't known here; nothing is installed or changed by asking.
    static func prefixFromPATH() -> String? {
        let result = DependencyCommand.run("/usr/bin/env", ["brew", "--prefix"], timeout: 20)
        guard result.status == 0 else { return nil }
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// For tests and for the copy: what Winbar would ask Homebrew to do.
    ///
    /// Deliberately not `--no-quarantine`. Homebrew leaves macOS's "downloaded from the internet"
    /// mark on what it installs, and dropping it is tempting — Winbar checks the signature, the team
    /// and Apple's notarization itself, so the mark tells it nothing new. But the thing that
    /// actually stalls a fresh UTM is the Apple Event grant macOS holds the first utmctl call on,
    /// and that has nothing to do with the mark: macOS opens UTM and lets it answer Apple Events
    /// with the mark in place (seen live). Stripping a macOS safety mark to fix something it doesn't
    /// cause isn't a trade Winbar should make on anyone's behalf; `UTMFirstUse` handles the real
    /// cause instead.
    static func installCommand(brew: String, cask: String) -> (tool: String, arguments: [String]) {
        (brew, ["install", "--cask", cask])
    }

    static func upgradeCommand(brew: String, cask: String) -> (tool: String, arguments: [String]) {
        (brew, ["upgrade", "--cask", cask])
    }
}

// MARK: - What Winbar would do about it

/// The one way to get each app, chosen from where things stand and whether Homebrew is there.
enum InstallPlan: Equatable {
    /// Ask Homebrew to install the cask. Homebrew does the downloading, the checksum and the copy.
    case brew(brew: String, cask: String)
    /// Ask Homebrew to update a copy that's too old for Winbar.
    case brewUpgrade(brew: String, cask: String)
    /// No Homebrew: fetch UTM's own signed, notarized disk image and copy the app out of it.
    case download(url: String)
    /// No Homebrew, and the App Store is the only way in: open the app's page and leave the button
    /// to the person. Nobody can install a Mac App Store app for someone else.
    case appStore(id: String)
    /// Nothing Winbar may do by itself; the text says what the person can.
    case manual(String)

    /// The command this plan runs, for the copy to show and for tests to hold against
    /// `DependencyCommand.isPrivileged`. nil when the plan runs no command of its own.
    var command: (tool: String, arguments: [String])? {
        switch self {
        case .brew(let brew, let cask): return Homebrew.installCommand(brew: brew, cask: cask)
        case .brewUpgrade(let brew, let cask): return Homebrew.upgradeCommand(brew: brew, cask: cask)
        case .download, .appStore, .manual: return nil
        }
    }

    /// Whether carrying this out needs someone to do something in another app (the App Store).
    var isHandOff: Bool { if case .appStore = self { return true } else { return false } }

    /// Whether this replaces a copy that's there rather than installing one.
    var isUpdate: Bool { if case .brewUpgrade = self { return true } else { return false } }
}

extension Dependencies {
    /// The decision table: state × Homebrew → what to offer. Pure. nil means there is nothing to
    /// offer, which for `.installed` is the point.
    ///
    /// `brewHasCask`: Homebrew installed this copy (`Homebrew.hasCask`). Only an update asks: Homebrew
    /// updates only what it installed, and a UTM from its own download or the App Store makes
    /// `brew upgrade --cask` stop with "not installed", which the person would then be told to run
    /// again themselves. Unknown counts as no, so the default offers nothing that can't work.
    static func plan(for dependency: Dependency, state: DependencyState, brew: String?,
                     brewHasCask: Bool = false) -> InstallPlan? {
        switch state {
        case .installed:
            return nil
        case .wrongSignature:
            // Never replace an app that is there: Winbar can't tell a tampered copy from one someone
            // built themselves, and deleting either would be its own kind of damage.
            return .manual(DependencyCopy.wrongSignatureAdvice(dependency))
        case .tooOld:
            guard let brew, brewHasCask else { return .manual(DependencyCopy.updateByHand(dependency)) }
            return .brewUpgrade(brew: brew, cask: dependency.cask)
        case .missing:
            if let brew { return .brew(brew: brew, cask: dependency.cask) }
            switch dependency {
            case .utm: return .download(url: Dependency.utmDownloadURL)
            case .windowsApp: return .appStore(id: Dependency.windowsAppStoreID)
            }
        }
    }

    /// The same, asking the Mac where things stand. Blocking.
    static func plan(for dependency: Dependency) -> InstallPlan? {
        plan(for: dependency, state: state(of: dependency), brew: Homebrew.path,
             brewHasCask: Homebrew.hasCask(dependency.cask, brew: Homebrew.path))
    }

    /// What the setup window may carry out, which is narrower than the CLI's (gui-wizard.md §3.6).
    /// Pure. nil means there is nothing to offer.
    ///
    /// UTM is the CLI's table unchanged: its cask is an app and a symlink, which needs no
    /// administrator password, so Homebrew installs it from a window as well as from a terminal.
    ///
    /// **Windows App is always the App Store here, never the cask** — the proven path, not a
    /// fallback (§4 experiment 2, settled 2026-09-22). The cask installs Microsoft's installer
    /// package, and Homebrew runs that through `sudo`; with no `SUDO_ASKPASS` set, sudo needs a
    /// terminal to read the password from, and Winbar.app has none, so the install would stop with
    /// nothing done. Making it work would mean Winbar showing its own dialog for the Mac's admin
    /// password and feeding it to sudo — a phishing-shaped screen for exactly the audience this
    /// window is for. The App Store build is also the one Winbar's saved-PC automation was proven
    /// against. So the App Store whether or not Homebrew is there, and `winbar setup` in Terminal
    /// still offers Homebrew to anyone who wants it. A copy that isn't Microsoft's is never replaced,
    /// as everywhere else.
    static func windowPlan(for dependency: Dependency, state: DependencyState, brew: String?,
                           brewHasCask: Bool = false) -> InstallPlan? {
        switch dependency {
        case .utm:
            return plan(for: dependency, state: state, brew: brew, brewHasCask: brewHasCask)
        case .windowsApp:
            switch state {
            case .installed: return nil
            case .wrongSignature: return .manual(DependencyCopy.wrongSignatureAdvice(dependency))
            // Nothing sets a minimum for Windows App today, but an update is the App Store's too.
            case .missing, .tooOld: return .appStore(id: Dependency.windowsAppStoreID)
            }
        }
    }
}

// MARK: - Running things, and never as root

/// Every external command a dependency install runs goes through here, which refuses anything
/// privileged. Winbar never asks for an administrator password and never runs a command as root:
/// installing an app into /Applications doesn't need it, and a tool that asks for it is doing
/// something Winbar didn't agree to.
///
/// Homebrew is a different matter and the copy says so: `brew install --cask windows-app` runs
/// Microsoft's installer package, and Homebrew itself asks for the Mac password to do it. That
/// prompt is Homebrew's own, in its own words, and Winbar neither sees nor handles the password.
enum DependencyCommand {
    /// Pure, and the reason this type exists: anything that would run as another user is refused
    /// before it starts.
    static func isPrivileged(tool: String, arguments: [String]) -> Bool {
        let privileged = ["sudo", "su", "doas", "installer", "osascript"]
        func names(_ text: String) -> [String] {
            text.split(whereSeparator: \.isWhitespace).map { ($0 as NSString).lastPathComponent }
        }
        if privileged.contains((tool as NSString).lastPathComponent) { return true }
        // Also inside an argument: `sh -c "sudo installer …"` is the same thing in a coat.
        if arguments.contains(where: { names($0).contains(where: privileged.contains) }) { return true }
        // AppleScript's "with administrator privileges" is the other way to raise a password prompt.
        return arguments.contains { $0.lowercased().contains("administrator privileges") }
    }

    static func refusal(tool: String) -> CommandResult {
        CommandResult(status: -1, stdout: Data(),
                      stderr: Data("Winbar doesn't run privileged commands (\(tool))".utf8), timedOut: false)
    }

    /// Captured output, for the checks: signatures, versions, mounting.
    static func run(_ tool: String, _ arguments: [String], timeout: TimeInterval) -> CommandResult {
        guard !isPrivileged(tool: tool, arguments: arguments) else { return refusal(tool: tool) }
        return Shell.run(tool, arguments, timeout: timeout)
    }

    /// The child keeps this process's own terminal: its output appears as it happens, and anything
    /// it asks (Homebrew's password prompt, a y/n) reaches the person. Hundreds of megabytes with a
    /// captured, silent minute in the middle looks exactly like a hang, which is why Homebrew is run
    /// this way and not through `run`.
    ///
    /// Returns the exit status, or nil if it couldn't be started or ran past `timeout`.
    static func runAttached(_ tool: String, _ arguments: [String], timeout: TimeInterval) -> Int32? {
        guard !isPrivileged(tool: tool, arguments: arguments) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        // Nothing is set on the three streams, so the child inherits this process's.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return nil }
        return wait(for: process, exited: exited, timeout: timeout)
    }

    /// Like `runAttached`, but the child's output is captured and relayed a line at a time instead
    /// of inherited. For the setup window, which has no terminal for a child to inherit: Homebrew's
    /// own words still appear as it goes, rather than a silent few minutes that look like a hang.
    ///
    /// The same refusal of anything privileged, checked before anything starts, and the same
    /// timeout and kill. Standard input is empty rather than inherited, so nothing the child asks
    /// can wait for an answer that isn't coming: a question gets end-of-file, not a hang. `line` is
    /// called one line at a time, never twice at once, and every line is delivered before this
    /// returns (give or take a grandchild that keeps a pipe open, which is waited on for five
    /// seconds, as `Shell.run` does). Both streams go to it: Homebrew writes its progress to one
    /// and its warnings to the other, and a person watching wants both.
    ///
    /// Returns the exit status, or nil if it was refused, couldn't be started or ran past `timeout`.
    static func runStreaming(_ tool: String, _ arguments: [String], timeout: TimeInterval,
                             line: @escaping (String) -> Void) -> Int32? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        return stream(process, timeout: timeout, line: line)
    }

    /// `runStreaming`'s work, on a process already made: the privilege check, an empty input
    /// whatever the process came with, both streams relayed, the timeout. Its own function so a
    /// test can hand it a process whose input was set to something else first — the one way to see
    /// the input emptied when the test's own is empty already.
    static func stream(_ process: Process, timeout: TimeInterval, line: @escaping (String) -> Void) -> Int32? {
        guard let tool = process.executableURL?.path,
              !isPrivileged(tool: tool, arguments: process.arguments ?? []) else { return nil }
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return nil }

        // One queue for `line`, so the two readers never call it at the same time.
        let relay = DispatchQueue(label: "net.elusive.winbar.stream")
        let group = DispatchGroup()
        for pipe in [out, err] {
            DispatchQueue.global(qos: .utility).async(group: group) {
                var splitter = LineSplitter()
                let handle = pipe.fileHandleForReading
                while true {
                    let chunk = handle.availableData
                    let lines = chunk.isEmpty ? splitter.finish() : splitter.feed(chunk)
                    if !lines.isEmpty { relay.sync { lines.forEach(line) } }
                    if chunk.isEmpty { break }
                }
            }
        }
        let status = wait(for: process, exited: exited, timeout: timeout)
        _ = group.wait(timeout: .now() + 5)
        return status
    }

    /// The timeout and kill both runners share: a polite terminate, then SIGKILL five seconds later.
    private static func wait(for process: Process, exited: DispatchSemaphore, timeout: TimeInterval) -> Int32? {
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 5) == .timedOut { kill(process.processIdentifier, SIGKILL) }
            return nil
        }
        return process.terminationStatus
    }
}

/// Bytes from a pipe, as lines. Pure, so the splitting can be tested without a process.
///
/// A line ends at a newline or at a carriage return: Homebrew draws its download progress by
/// rewriting one line with `\r`, and each rewrite is worth showing as the latest word rather than
/// held back until a newline that only comes at 100%. `\r\n` is one ending, not two. Bytes are split
/// before they are decoded, which is safe for UTF-8 (neither byte can occur inside a multi-byte
/// character) and means a character cut in half between two reads is joined back up before it is
/// decoded. Empty lines are dropped: in a one-line detail area they would only blank it.
struct LineSplitter {
    private var pending = Data()
    /// The last byte fed was a `\r`, so a `\n` at the start of the next chunk belongs to it.
    private var afterReturn = false

    mutating func feed(_ chunk: Data) -> [String] {
        var lines: [String] = []
        for byte in chunk {
            if byte == 0x0A, afterReturn {
                afterReturn = false
                continue
            }
            afterReturn = byte == 0x0D
            if byte == 0x0A || byte == 0x0D {
                if !pending.isEmpty { lines.append(String(decoding: pending, as: UTF8.self)) }
                pending.removeAll(keepingCapacity: true)
            } else {
                pending.append(byte)
            }
        }
        return lines
    }

    /// Whatever came after the last line ending, once the stream has closed.
    mutating func finish() -> [String] {
        defer { pending.removeAll() }
        return pending.isEmpty ? [] : [String(decoding: pending, as: UTF8.self)]
    }
}

// MARK: - Verifying an app

/// What `codesign` says about a bundle, and whether it is who it claims to be.
enum AppSignature {
    /// `codesign -dv --verbose=4`'s two facts. Pure, so both distribution channels' output can be
    /// held against it without an app: Developer ID (UTM) and the App Store (Windows App), whose
    /// certificate carries no team at all — which is why the team is taken from here.
    static func parse(_ output: String) -> (identifier: String?, teamID: String?) {
        var identifier: String?
        var team: String?
        for line in output.components(separatedBy: .newlines) {
            let text = line.trimmingCharacters(in: .whitespaces)
            if identifier == nil, text.hasPrefix("Identifier=") {
                identifier = String(text.dropFirst("Identifier=".count))
            }
            if team == nil, text.hasPrefix("TeamIdentifier=") {
                team = String(text.dropFirst("TeamIdentifier=".count))
            }
        }
        if team == "not set" { team = nil }
        return (identifier?.isEmpty == true ? nil : identifier, team?.isEmpty == true ? nil : team)
    }

    /// The requirement every copy has to satisfy: a signature that checks out, from a certificate
    /// Apple issued. Developer ID and the App Store both anchor to Apple; nothing self-signed or
    /// ad-hoc does. The team itself is compared separately, from the signature.
    static let appleAnchor = "=anchor apple generic"

    static func verifyCommand(_ path: String) -> (tool: String, arguments: [String]) {
        ("/usr/bin/codesign", ["--verify", "--strict", "-R", appleAnchor, path])
    }

    static func readCommand(_ path: String) -> (tool: String, arguments: [String]) {
        ("/usr/bin/codesign", ["-dv", "--verbose=4", path])
    }

    /// Reads the bundle's identity: its id and version from Info.plist, its team and signature from
    /// codesign. `expectedTeam` isn't trusted into the result — it only picks the requirement the
    /// verify runs — so `Dependencies.state` still does the comparing. Blocking.
    static func read(_ path: String, expectedTeam: String) -> InstalledApp? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let described = readCommand(path)
        let facts = parse(DependencyCommand.run(described.tool, described.arguments, timeout: 60).output)
        let verify = verifyCommand(path)
        let valid = DependencyCommand.run(verify.tool, verify.arguments, timeout: 180).status == 0
        let bundle = Bundle(url: URL(fileURLWithPath: path))
        return InstalledApp(path: path,
                            bundleID: facts.identifier ?? bundle?.bundleIdentifier,
                            version: bundle?.infoDictionary?["CFBundleShortVersionString"] as? String,
                            teamID: facts.teamID,
                            signatureValid: valid)
    }
}

/// Apple's own assessment of a file that just arrived from the internet: is it notarized, and who
/// signed it. Asked of the disk image **before** it is mounted — mounting is already giving a file
/// a say in what happens on the Mac.
enum Gatekeeper {
    struct Assessment: Equatable {
        var accepted: Bool
        /// "Notarized Developer ID", "Mac App Store"… as spctl names it.
        var source: String?
        /// The signing certificate as spctl prints it, e.g. Developer ID Application: … (TEAM).
        var origin: String?
        /// The team from the origin's trailing (…), when there is one.
        var teamID: String?
    }

    /// macOS 27 keeps spctl in /usr/sbin (it was never in /usr/bin).
    static func assessCommand(_ path: String) -> (tool: String, arguments: [String]) {
        ("/usr/sbin/spctl", ["--assess", "--type", "open", "--context", "context:primary-signature", "-vv", path])
    }

    /// Pure: spctl writes its verdict to stderr in three lines.
    static func parse(_ output: String, status: Int32) -> Assessment {
        var source: String?
        var origin: String?
        for line in output.components(separatedBy: .newlines) {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("source=") { source = String(text.dropFirst("source=".count)) }
            if text.hasPrefix("origin=") { origin = String(text.dropFirst("origin=".count)) }
        }
        let accepted = status == 0 && output.contains(": accepted")
        return Assessment(accepted: accepted, source: source, origin: origin, teamID: team(in: origin))
    }

    /// The team id out of "Developer ID Application: Turing Software, LLC (WDNLXAD4W8)". Pure.
    static func team(in origin: String?) -> String? {
        guard let origin, let open = origin.lastIndex(of: "("), let close = origin.lastIndex(of: ")"), open < close else {
            return nil
        }
        let inside = String(origin[origin.index(after: open)..<close])
        let allowed = inside.allSatisfy { $0.isLetter || $0.isNumber }
        return allowed && !inside.isEmpty ? inside : nil
    }

    /// Whether Apple notarized this file and the team that signed it is the one expected. Both, or
    /// the file is not opened. Pure, so every verdict can be tested.
    static func trusted(_ assessment: Assessment, team: String) -> Bool {
        assessment.accepted && assessment.teamID == team
    }

    /// Blocking.
    static func assess(_ path: String) -> Assessment {
        let command = assessCommand(path)
        let result = DependencyCommand.run(command.tool, command.arguments, timeout: 180)
        return parse(result.output, status: result.status)
    }
}
