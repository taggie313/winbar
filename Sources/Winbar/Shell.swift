import CoreServices
import Foundation

/// A failure worth showing a person: a short title and the detail (often a tool's own output).
struct WinbarError: Error, CustomStringConvertible {
    let title: String
    let detail: String
    /// macOS refused to let this process control UTM (see `Automation`). Doctor and the menu turn it
    /// into a step the person can take instead of a dead end.
    let automationDenied: Bool
    /// Nothing came back at all. Not the same as a refusal: on a Mac where the first Apple Event is
    /// still waiting to be allowed, every request simply never answers (see `UTMFirstUse`), and that
    /// has its own thing to say.
    let timedOut: Bool

    init(_ title: String, _ detail: String = "", automationDenied: Bool = false, timedOut: Bool = false) {
        self.title = title
        self.detail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        self.automationDenied = automationDenied
        self.timedOut = timedOut
    }

    var description: String { detail.isEmpty ? title : "\(title): \(detail)" }
}

/// macOS's Automation privacy: whether this process may send Apple Events to UTM (osascript and
/// utmctl both do). A "Don't Allow" is sticky, and without this the only trace is a raw -1743.
enum Automation {
    static let settingsURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"

    /// errAEEventNotPermitted, as osascript and utmctl both print it.
    static func isDenied(_ text: String) -> Bool { text.contains("-1743") }

    /// The first line of macOS's Automation prompt, exactly as it reads, for the sentences that tell
    /// someone what to look for. TCC's own string (REQUEST_ACCESS_SERVICE_kTCCServiceAppleEvents in
    /// TCC.framework's Localizable.loctable) is `“%@” wants access to control “%@”.`; a paraphrase in
    /// quotation marks sends a person looking for words that aren't on the screen.
    static func promptWords(host: String, app: String = "UTM") -> String {
        "“\(host)” wants access to control “\(app)”"
    }

    /// Who macOS asked: Winbar when LaunchServices started it, otherwise the terminal the CLI runs in.
    static var host: (name: String, bundleID: String?) {
        if AppBundle.launchedByLaunchServices { return ("Winbar", Config.appBundleID) }
        return terminal(ProcessInfo.processInfo.environment["TERM_PROGRAM"])
    }

    static func terminal(_ termProgram: String?) -> (name: String, bundleID: String?) {
        switch termProgram {
        case "Apple_Terminal": return ("Terminal", "com.apple.Terminal")
        case "iTerm.app": return ("iTerm", "com.googlecode.iterm2")
        case "vscode": return ("Visual Studio Code", "com.microsoft.VSCode")
        case "WarpTerminal": return ("Warp", "dev.warp.Warp-Stable")
        case "ghostty": return ("Ghostty", "com.mitchellh.ghostty")
        default: return ("your terminal app", nil)
        }
    }

    /// What macOS says about this process being allowed to control `bundleID`.
    enum Consent: Equatable {
        /// It has never been asked about this pair, so the next Apple Event raises the prompt.
        case wouldPrompt
        /// It has an answer on file — allowed or refused — or the target isn't running, which is
        /// all it can say then (`procNotFound`).
        case decided
        /// It didn't answer. On a Mac whose Apple Event path to that app is already waiting on the
        /// prompt, this is the usual answer, and it is a symptom rather than a missing fact.
        case unknown
    }

    /// The bounded form, and the only one anything should call.
    ///
    /// `AEDeterminePermissionToAutomateTarget` is documented to ask TCC and nothing else when it is
    /// told not to prompt. It doesn't always come back: on a Mac where UTM had just been installed
    /// and the first Apple Event to it was still waiting to be allowed, it sat in a semaphore for
    /// twenty minutes and took `winbar doctor` with it — the row never returned, so no row after it
    /// was ever printed. Nothing that can't answer may be allowed to end a run, so it is asked on
    /// another thread and given a few seconds.
    static func consent(bundleID: String, timeout: TimeInterval = 3) -> Consent {
        guard let answered = withDeadline(timeout, { rawWillPrompt(bundleID: bundleID) }) else { return .unknown }
        return answered ? .wouldPrompt : .decided
    }

    /// Whether the prompt is still to come. An unknown answer is not a yes.
    static func willPrompt(bundleID: String, timeout: TimeInterval = 3) -> Bool {
        consent(bundleID: bundleID, timeout: timeout) == .wouldPrompt
    }

    /// The call itself, which can block for as long as macOS likes. Safe to abandon: it reads, and
    /// writes nothing anybody else looks at. Never call it directly — `consent` bounds it.
    static func rawWillPrompt(bundleID: String) -> Bool {
        var target = AEAddressDesc()
        let id = Array(bundleID.utf8)
        let made = id.withUnsafeBufferPointer {
            AECreateDesc(typeApplicationBundleID, $0.baseAddress, $0.count, &target)
        }
        guard made == noErr else { return false }
        defer { AEDisposeDesc(&target) }
        return AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, false)
            == OSStatus(errAEEventWouldRequireUserConsent)
    }

    /// `for` is who was refused: this process's host by default. The set-up window names Winbar
    /// itself, because it only ever runs as the app, and so its words don't depend on how the test
    /// that draws it was started.
    static func deniedError(for host: (name: String, bundleID: String?) = host) -> WinbarError {
        let (name, bundleID) = host
        let reset = bundleID.map { " To get the macOS prompt back instead: tccutil reset AppleEvents \($0)" } ?? ""
        return WinbarError("\(name.prefix(1).uppercased() + name.dropFirst()) isn't allowed to control UTM",
                           "Turn on UTM under \(name) in System Settings → Privacy & Security → Automation, then try again.\(reset)",
                           automationDenied: true)
    }

    /// `fallback`, unless `output` shows the Automation denial.
    static func explain(_ output: String, else fallback: WinbarError) -> WinbarError {
        isDenied(output) ? deniedError() : fallback
    }
}

struct CommandResult {
    let status: Int32
    let stdout: Data
    let stderr: Data
    let timedOut: Bool

    var text: String { String(decoding: stdout, as: UTF8.self) }
    var errorText: String { String(decoding: stderr, as: UTF8.self) }
    var output: String { [text, errorText].filter { !$0.isEmpty }.joined(separator: "\n") }

    /// utmctl reports some failures only as text while still exiting 0, hence the "Error" check.
    var ok: Bool { status == 0 && !timedOut && !output.contains("Error") }
}

enum Shell {
    /// Runs a tool and captures both streams. Blocking: call off the main thread in the app.
    ///
    /// Both pipes are drained concurrently, because a child that fills one pipe while we sit reading
    /// the other would deadlock. A timeout matters because utmctl can wait indefinitely on UTM (for
    /// example behind an Automation prompt nobody has answered).
    ///
    /// `abort`, when given, is asked four times a second while the tool runs, and a yes ends it the
    /// way the timeout does. For a tool that waits on a person in someone else's dialog: the setup
    /// window's **Stop Waiting** (`RDP.trustCertificate`). Without it the wait is exactly as it was.
    static func run(_ path: String, _ arguments: [String], input: Data? = nil,
                    timeout: TimeInterval = 60, abort: (() -> Bool)? = nil) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let inPipe = input.map { _ in Pipe() }
        process.standardInput = inPipe ?? FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch {
            return CommandResult(status: -1, stdout: Data(), stderr: Data(error.localizedDescription.utf8), timedOut: false)
        }

        let group = DispatchGroup()
        var outData = Data(), errData = Data()
        DispatchQueue.global(qos: .utility).async(group: group) { outData = out.fileHandleForReading.readDataToEndOfFile() }
        DispatchQueue.global(qos: .utility).async(group: group) { errData = err.fileHandleForReading.readDataToEndOfFile() }
        if let input, let inPipe {
            DispatchQueue.global(qos: .utility).async {
                try? inPipe.fileHandleForWriting.write(contentsOf: input)
                try? inPipe.fileHandleForWriting.close()
            }
        }

        var timedOut = false
        var stopped = false
        if let abort {
            let deadline = Date().addingTimeInterval(timeout)
            while exited.wait(timeout: .now() + 0.25) == .timedOut {
                if abort() { stopped = true; break }
                if Date() >= deadline { timedOut = true; break }
            }
        } else if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
        }
        if timedOut || stopped {
            process.terminate()
            if exited.wait(timeout: .now() + 3) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 3)
            }
        }
        _ = group.wait(timeout: .now() + 5)
        return CommandResult(status: process.isRunning ? -1 : process.terminationStatus,
                             stdout: outData, stderr: errData, timedOut: timedOut)
    }
}

/// Waits without freezing whatever owns the thread. On the main thread (the CLI) it spins the run loop
/// so NSWorkspace and NSRunningApplication keep receiving their updates; elsewhere it just sleeps.
func pause(_ seconds: TimeInterval) {
    if Thread.isMainThread {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    } else {
        Thread.sleep(forTimeInterval: seconds)
    }
}

/// Runs `body` on the main thread and returns its result. The CLI already is the main thread, where
/// `DispatchQueue.main.sync` would deadlock.
func onMain<T>(_ body: () -> T) -> T {
    Thread.isMainThread ? body() : DispatchQueue.main.sync(execute: body)
}

/// Runs `work` on another thread and stops waiting for it after `limit`; nil means it hadn't
/// answered by then.
///
/// For the few macOS calls that have no timeout of their own and can block for ever (see
/// `Automation.consent` for the one that proved it). A call that is given up on is *not* cancelled
/// — there is no way to cancel it — so `work` must be something it is safe to abandon: it must not
/// write to anything the caller goes on to use, and the thread it is on stays blocked until it
/// returns or the process ends.
func withDeadline<T>(_ limit: TimeInterval, _ work: @escaping () -> T) -> T? {
    let box = Box<T>()
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInitiated).async {
        box.value = work()
        done.signal()
    }
    guard done.wait(timeout: .now() + limit) == .success else { return nil }
    return box.value
}

/// Somewhere for an answer to land that both threads may touch.
private final class Box<T> {
    private let lock = NSLock()
    private var stored: T?
    var value: T? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

/// Re-runs `check` until it passes or `timeout` elapses. Blocking.
@discardableResult
func waitUntil(timeout: TimeInterval, every interval: TimeInterval, _ check: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while true {
        if check() { return true }
        if Date() >= deadline { return false }
        pause(interval)
    }
}

enum Host {
    /// Cores of the fastest tier: "Super" on M5, "Performance" on M1–M4.
    static var topTierCores: Int {
        sysctlInt("hw.perflevel0.physicalcpu") ?? sysctlInt("hw.physicalcpu") ?? 4
    }

    static var memoryBytes: UInt64 {
        var size: UInt64 = 0
        var length = MemoryLayout<UInt64>.size
        return sysctlbyname("hw.memsize", &size, &length, nil, 0) == 0 ? size : 0
    }

    static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var length = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &length, nil, 0) == 0, value > 0 else { return nil }
        return Int(value)
    }

    /// A sysctl that answers with text: `hw.model` ("Mac16,6"), `machdep.cpu.brand_string`
    /// ("Apple M5 Max"), `kern.osversion` (the macOS build). Two calls, the first only to be told
    /// how much room the answer needs. Used by `winbar diagnose` to say what Mac this is without
    /// starting `system_profiler`, which takes seconds.
    static func sysctlString(_ name: String) -> String? {
        var length = 0
        guard sysctlbyname(name, nil, &length, nil, 0) == 0, length > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: length)
        guard sysctlbyname(name, &buffer, &length, nil, 0) == 0 else { return nil }
        let value = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// nil when fdesetup can't say. Non-root `fdesetup status` is enough for the on/off answer.
    static var fileVaultOn: Bool? {
        let result = Shell.run("/usr/bin/fdesetup", ["status"], timeout: 10)
        guard result.status == 0 else { return nil }
        if result.text.contains("FileVault is On") { return true }
        if result.text.contains("FileVault is Off") { return false }
        return nil
    }

    /// Where a file lives, as far as encryption at rest goes. FileVault covers only the startup
    /// disk; a VM bundle on an external drive is exactly as encrypted as that drive.
    enum Storage: Hashable {
        case startupDisk
        case volume(String)   // its mount point, /Volumes/<name>

        var description: String {
            switch self {
            case .startupDisk: return "this Mac's startup disk"
            case .volume(let mount): return (mount as NSString).lastPathComponent
            }
        }
    }

    /// Decided by the path alone, never by touching the file: disk images live in UTM's container,
    /// which macOS guards. `resolve` is realpath; /Volumes/<startup disk> is a symlink to /.
    static func storage(of path: String, resolve: (String) -> String? = { Host.realPath($0) }) -> Storage {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 3, parts[0] == "Volumes" else { return .startupDisk }
        let mount = "/Volumes/" + parts[1]
        return resolve(mount) == "/" ? .startupDisk : .volume(mount)
    }

    static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Whether what's stored there is encrypted at rest; nil if macOS can't say. For another volume
    /// that's diskutil's "FileVault" (an encrypted APFS volume reports it too); an unencrypted
    /// format such as exFAT doesn't report the key at all. diskutil asks Disk Arbitration, so nothing
    /// on the volume itself is read.
    static func encryptedAtRest(_ storage: Storage) -> Bool? {
        switch storage {
        case .startupDisk:
            return fileVaultOn
        case .volume(let mount):
            let result = Shell.run("/usr/sbin/diskutil", ["info", "-plist", mount], timeout: 20)
            guard result.status == 0,
                  let plist = try? PropertyListSerialization.propertyList(from: result.stdout, format: nil) as? [String: Any]
            else { return nil }
            return plist["FileVault"] as? Bool ?? false
        }
    }

    static var applicationSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Winbar", isDirectory: true)
    }
}
