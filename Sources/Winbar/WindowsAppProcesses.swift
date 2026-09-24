import AppKit
import Darwin

/// Which running copies of Windows App are the app someone uses, and which are its command line.
///
/// `Windows App --script …` runs as a full copy of the app, with the same bundle id. On 11.4.2 it can
/// deadlock during start-up and never exit (seen on the author's Mac; Winbar's own calls time out and
/// kill theirs, but a copy started by anything else stays). Counting such a copy as "Windows App is
/// open" sent Connect to it: Winbar searched it for a tile, activated it instead of launching the
/// app, handed the `.rdp` fallback to it too — and nothing appeared. It also made saving a PC refuse
/// with "Quit Windows App first".
enum WindowsAppProcesses {
    /// A copy started with `--script` is the command line, not the app. Pure.
    static func isScriptCopy(arguments: [String]) -> Bool {
        arguments.dropFirst().contains("--script")
    }

    /// A command-line copy that has run this long is stuck: Winbar's own give up after 45 s. Pure.
    static func isStuck(arguments: [String], ageSeconds: Double) -> Bool {
        isScriptCopy(arguments: arguments) && ageSeconds > 45
    }

    /// The copies of Windows App that are the app itself.
    static func apps() -> [NSRunningApplication] {
        running().filter { app in
            guard let args = arguments(of: app.processIdentifier) else { return true }   // can't tell: assume the app
            return !isScriptCopy(arguments: args)
        }
    }

    /// Stops command-line copies that have been stuck past any caller's deadline, so the app can
    /// start. A `--script` copy has no window and no session, so nothing is lost; it is asked to
    /// terminate, never force-killed.
    @discardableResult
    static func stopStuckScriptCopies(now: Date = Date()) -> [pid_t] {
        var stopped: [pid_t] = []
        for app in running() {
            let pid = app.processIdentifier
            guard let args = arguments(of: pid), let started = startDate(of: pid),
                  isStuck(arguments: args, ageSeconds: now.timeIntervalSince(started)) else { continue }
            if kill(pid, SIGTERM) == 0 {
                stopped.append(pid)
                NSLog("Winbar: stopped a stuck Windows App command-line copy (pid \(pid)) so the app can open")
            }
        }
        return stopped
    }

    private static func running() -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: Config.windowsAppBundleID)
    }

    static func arguments(of pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return VMProcess.parseProcArgs(Array(buffer.prefix(size)))
    }

    private static func startDate(of pid: pid_t) -> Date? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Date(timeIntervalSince1970: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000)
    }
}
