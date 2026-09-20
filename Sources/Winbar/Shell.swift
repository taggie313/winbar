import CoreServices
import Foundation

/// A failure worth showing a person: a short title and the detail (often a tool's own output).
struct WinbarError: Error, CustomStringConvertible {
    let title: String
    let detail: String
    /// macOS refused to let this process control UTM (see `Automation`). Doctor and the menu turn it
    /// into a step the person can take instead of a dead end.
    let automationDenied: Bool

    init(_ title: String, _ detail: String = "", automationDenied: Bool = false) {
        self.title = title
        self.detail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        self.automationDenied = automationDenied
    }

    var description: String { detail.isEmpty ? title : "\(title): \(detail)" }
}

/// macOS's Automation privacy: whether this process may send Apple Events to UTM (osascript and
/// utmctl both do). A "Don't Allow" is sticky, and without this the only trace is a raw -1743.
enum Automation {
    static let settingsURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"

    /// errAEEventNotPermitted, as osascript and utmctl both print it.
    static func isDenied(_ text: String) -> Bool { text.contains("-1743") }

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

    /// Whether macOS would put its “… wants to control UTM” prompt on screen for the next Apple Event
    /// this process sends to `bundleID`: it has never been asked about this pair. Asks TCC only, with
    /// `askUserIfNeeded` false, so nothing is sent to the app and nothing is launched.
    ///
    /// False once macOS has an answer, allowed or refused, and false when the target isn't running,
    /// which is all this can say then (`procNotFound`). `winbar create` uses it to name what it is
    /// waiting for while a scripting call blocks.
    static func willPrompt(bundleID: String) -> Bool {
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

    static func deniedError() -> WinbarError {
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
    static func run(_ path: String, _ arguments: [String], input: Data? = nil,
                    timeout: TimeInterval = 60) -> CommandResult {
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
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
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
