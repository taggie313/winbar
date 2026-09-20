import AppKit

/// UTM itself: the app, `utmctl`, and starting and stopping a VM.
///
/// Everything here blocks; the menu bar app calls it off the main thread. Apple Events sent by
/// utmctl (and by osascript, see UTMScripting) are attributed to the responsible app, so macOS asks
/// once per host app — "Winbar wants to control UTM" from the menu, "Terminal …" from the CLI.
enum UTM {
    static var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: Config.utmBundleID) }

    static var isInstalled: Bool { appURL != nil }

    static var version: String? {
        guard let url = appURL else { return nil }
        return Bundle(url: url)?.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    static var utmctl: String {
        appURL?.appendingPathComponent("Contents/MacOS/utmctl").path ?? "/Applications/UTM.app/Contents/MacOS/utmctl"
    }

    /// Whether UTM is running, from the process table (see `processIDs`).
    static var isAppRunning: Bool { !processIDs.isEmpty }

    /// utmctl and AppleScript both need UTM running. Launch it without activating, so a VM action
    /// doesn't pull UTM to the front.
    ///
    /// Not hidden, though: a UTM launched hidden can't bring up a VM's display window, so
    /// `utmctl start` on a VM with a console never completes (seen live on UTM 4.7.5, macOS 27).
    static func ensureRunning() {
        guard !isAppRunning, let url = appURL else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = false
        let launched = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in launched.signal() }
        _ = launched.wait(timeout: .now() + 15)
        pause(4)   // the process appears before UTM's scripting bridge is ready
    }

    /// UTM's running instances, by pid. The same as `processIDs`; kept as the name callers use.
    static var runningPIDs: [pid_t] { processIDs }

    /// UTM's executable, resolved, for matching processes against.
    static var executablePath: String? {
        appURL?.appendingPathComponent("Contents/MacOS/UTM").resolvingSymlinksInPath().path
    }

    /// Alive and running UTM's executable, so a recycled pid doesn't count.
    ///
    /// Deliberately not NSRunningApplication: once UTM closes its last window (it has no Dock icon when
    /// "Hide dock icon" is on), `NSRunningApplication(processIdentifier:)` returns nil for it while it's
    /// still running. Winbar then decided UTM had already quit, skipped the restart a display change
    /// requires, and started the VM straight into utmapp/UTM#7882. The executable's path doesn't change.
    static func isUTMProcess(_ pid: pid_t) -> Bool {
        guard kill(pid, 0) == 0, let want = executablePath, let path = executablePath(of: pid) else { return false }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path == want
    }

    static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// UTM's processes, from the process table: current even in the CLI (whose list of running
    /// applications only updates when a run loop turns) and independent of UTM's windows.
    static var processIDs: [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return pids.prefix(Int(max(filled, 0))).filter { pid in
            guard pid > 0 else { return false }
            var name = [CChar](repeating: 0, count: 64)
            proc_name(pid, &name, UInt32(name.count))
            return String(cString: name) == "UTM" && isUTMProcess(pid)
        }
    }

    /// Quits UTM and waits for it to exit. Only call with no VM running: UTM stops running VMs on quit.
    ///
    /// LaunchServices' list is topped up from the process table and from what a pending restart
    /// recorded: in the CLI that list only updates when the run loop turns, so it can miss a UTM
    /// launched since.
    static func quit(timeout: TimeInterval = 30) -> Result<Void, WinbarError> {
        let recorded = Config.pendingUTMRestart?.stillRunning(isUTM: isUTMProcess) ?? []
        let pids = Set(runningPIDs).union(processIDs).union(recorded)
        Debug.log("quit: runningPIDs=\(runningPIDs) processIDs=\(processIDs) recorded=\(recorded) -> \(pids.sorted())")
        guard !pids.isEmpty else {
            Config.pendingUTMRestart = nil
            return .success(())
        }
        // A normal quit first, addressed by bundle id: NSRunningApplication can't be relied on to find
        // UTM (see isUTMProcess), but the Apple Event reaches it regardless.
        for pid in pids { _ = NSRunningApplication(processIdentifier: pid)?.terminate() }
        _ = Shell.run("/usr/bin/osascript", ["-e", "tell application id \"\(Config.utmBundleID)\" to quit"], timeout: 15)
        var exited = waitUntil(timeout: timeout, every: 0.5) { pids.allSatisfy { kill($0, 0) != 0 } }
        if !exited {
            // Callers only quit UTM with no VM running (see otherRunningVMs), so a terminate signal
            // can't stop anything but UTM itself.
            Debug.log("quit: UTM ignored the quit request; sending SIGTERM to \(pids.sorted())")
            for pid in pids where kill(pid, 0) == 0 { kill(pid, SIGTERM) }
            exited = waitUntil(timeout: 10, every: 0.5) { pids.allSatisfy { kill($0, 0) != 0 } }
        }
        guard exited else { return .failure(WinbarError("UTM didn't quit", "Quit UTM yourself, then try again.")) }
        Config.pendingUTMRestart = nil   // whatever restart a display change owed has now happened
        return .success(())
    }

    /// Other VMs UTM is running right now: QEMU processes by name, plus whatever UTM's scripting
    /// reports as not stopped (Apple-backend VMs have no QEMU process to find).
    ///
    /// Fails closed. This is what stands between Winbar quitting UTM and the user's other VMs, and an
    /// Apple-backend VM is invisible without the listing, so a listing that fails (UTM busy, a timeout)
    /// is an error, never "none". Likewise a status that couldn't be read counts as running.
    static func otherRunningVMs(than vm: String, id: String? = nil) -> Result<[String], WinbarError> {
        // A QEMU process carries the name UTM gave it, which is the VM's name with everything but
        // letters, digits and spaces removed (UTMQemuArgs.cleanupName). Compare against that too, or
        // a VM called "winbar-test" reports itself as another VM called "winbartest" — and then
        // Winbar refuses to take that very VM headless.
        let cleaned = VMProcess.cleanedName(vm)
        var names = Set(VMProcesses.all()
            .filter { process in
                if let id, let uuid = process.uuid, uuid.caseInsensitiveCompare(id) == .orderedSame { return false }
                guard let name = process.name else { return false }
                return name != vm && name != cleaned
            }
            .compactMap(\.name))
        guard isAppRunning else { return .success(names.sorted()) }   // no UTM, so nothing but QEMU could be running
        var listed = UTMScripting.listVMs()
        if case .failure = listed {
            pause(2)   // one retry: UTM can be slow to answer right after a VM stops
            listed = UTMScripting.listVMs()
        }
        switch listed {
        case .failure(let error):
            return .failure(WinbarError("Couldn't ask UTM which other VMs are running", error.description))
        case .success(let list):
            names.formUnion(list.filter { $0.name != vm && $0.status != "stopped" }.map(\.name))
            return .success(names.sorted())
        }
    }

    // MARK: The restart a display change owes

    /// Called just before a display change is sent: whatever happens next (UTM failing, Winbar
    /// killed half way), the next start must quit UTM first. See `UTMRestart`.
    static func recordPendingRestart(for vm: String) {
        let pids = Array(Set(runningPIDs).union(processIDs))
        Config.pendingUTMRestart = UTMRestart.recording(vm: vm, pids: pids, over: Config.pendingUTMRestart)
    }

    /// Quits UTM if a display change still owes it a restart, refusing if that would stop other
    /// VMs. Every start goes through here, so no path can start a VM in a UTM that would crash.
    static func settlePendingRestart(before vm: String) -> Result<Void, WinbarError> {
        guard let pending = Config.pendingUTMRestart else {
            Debug.log("settle: no pending restart")
            return .success(())
        }
        let alive = pending.stillRunning(isUTM: isUTMProcess)
        Debug.log("settle: pending vm=\(pending.vm) pids=\(pending.pids) alive=\(alive)")
        guard !alive.isEmpty else {
            Config.pendingUTMRestart = nil   // UTM has quit (or crashed) since, so the next launch builds a fresh window
            return .success(())
        }
        let owed = "\(pending.vm)'s display changed, and UTM only picks that up when it restarts: starting "
            + "\(pending.vm) from the UTM that's running now would crash UTM."
        switch otherRunningVMs(than: vm) {
        case .failure(let error):
            return .failure(WinbarError("UTM has to restart before \(vm) starts",
                                        owed + " Winbar couldn't confirm that no other VM is running (\(error.detail)), and "
                                            + "restarting UTM would stop any that are. Try again, or quit UTM yourself."))
        case .success(let others) where !others.isEmpty:
            return .failure(WinbarError("UTM has to restart before \(vm) starts",
                                        owed + " Restarting it would stop \(others.joined(separator: ", ")). "
                                            + "Stop them (or quit UTM yourself), then try again."))
        case .success:
            if case .failure(let error) = quit() {
                return .failure(WinbarError("UTM has to restart before \(vm) starts", owed + " " + error.detail))
            }
            // The UTM that just quit held the bookmark behind any scripted shared folder, so write it
            // again while the VM is still stopped — this is the last moment before it starts. Best
            // effort: `winbar share` and doctor report what Windows ended up with.
            _ = SharedFolder.reestablish(vm: vm)
            return .success(())
        }
    }

    /// Brings UTM forward, for the menu's "Open UTM".
    static func open() {
        guard let url = appURL else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Runs utmctl, launching UTM (hidden) first if needed.
    static func ctl(_ arguments: [String], input: Data? = nil, timeout: TimeInterval = 60) -> CommandResult {
        ensureRunning()
        return Shell.run(utmctl, arguments, input: input, timeout: timeout)
    }

    // MARK: Whether this process can drive UTM at all

    /// What `utmctl` did when it was asked the cheapest question there is.
    enum CtlAnswer: Equatable {
        case answered
        /// macOS has refused this process the right to control UTM.
        case denied
        /// It started and said nothing until the deadline. The first call after UTM is installed or
        /// reinstalled is the one that does this: every utmctl call is an Apple Event, and macOS
        /// holds the first one until somebody answers "… wants to control UTM" — a prompt that can
        /// open behind another window, and that a Mac nobody is sitting at never gets.
        case silent(seconds: Int)
        /// It answered, with a failure of its own.
        case failed(String)

        var isAnswered: Bool { self == .answered }
    }

    /// Pure, so every verdict can be told apart without UTM.
    static func classifyCtl(status: Int32, output: String, timedOut: Bool, seconds: Int) -> CtlAnswer {
        if Automation.isDenied(output) { return .denied }
        if timedOut { return .silent(seconds: seconds) }
        if status == 0 { return .answered }
        return .failed(output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Asks utmctl to list the VMs — which changes nothing — and says what came back. Blocking, and
    /// bounded, because the answer this exists for is "nothing at all".
    static func ctlAnswers(timeout: TimeInterval = 20) -> CtlAnswer {
        ensureRunning()
        let result = Shell.run(utmctl, ["list"], timeout: timeout)
        Debug.log("ctlAnswers: status=\(result.status) timedOut=\(result.timedOut) output=\(result.output.prefix(200))")
        return classifyCtl(status: result.status, output: result.output, timedOut: result.timedOut,
                           seconds: Int(timeout))
    }

    // MARK: Lifecycle

    /// Starts the VM, waits for its QEMU process, then makes sure UTM survived the start.
    ///
    /// Never `--hide`: it makes utmctl print OSStatus -10004 twice even though the VM starts fine. For
    /// the same reason success is judged by processes, not by what utmctl prints.
    ///
    /// QEMU appearing is not enough. UTM can crash a couple of seconds after launching QEMU, taking the
    /// VM down with it (see `Reconfigure` for the case that did exactly that), and "QEMU appeared" is
    /// how that went unnoticed. So UTM's pid is taken once QEMU is up, and five seconds later both it and
    /// QEMU must still be alive.
    /// `cacheSettings` records the VM's MAC and display state in Winbar's per-VM settings, which only
    /// makes sense for the VM Winbar looks after: those keys say what `winbar connect` and the menu
    /// work on, so writing another VM's MAC over them makes Winbar describe the wrong VM. It
    /// defaults to "when this is the selected VM", and `winbar create --no-select` relies on that.
    /// `id` is the VM's UTM id when the caller knows it (`winbar create` always does). utmctl takes
    /// either, and the id is also how the running process is recognised: UTM strips punctuation from
    /// the name it gives QEMU, so a VM called "winbar-test" runs as `-name winbartest`.
    static func start(_ vm: String, id: String? = nil, cacheSettings: Bool = true) -> Result<VMProcess, WinbarError> {
        if let running = VMProcesses.find(vm, id: id) { return .success(running) }
        if case .failure(let error) = settlePendingRestart(before: vm) { return .failure(error) }
        let started = Date()
        let pidsBefore = Set(runningPIDs)
        let result = ctl(["start", id ?? vm], timeout: 60)
        let appeared = waitUntil(timeout: 20, every: 1) { VMProcesses.isRunning(vm, id: id) }
        guard appeared else {
            return .failure(Automation.explain(result.output, else: WinbarError("Couldn't start \(vm)", result.output)))
        }

        let owners = runningPIDs
        pause(5)
        // No pid to watch would mean UTM vanished from LaunchServices' list already; QEMU's own
        // survival below still decides in that case.
        let utmAlive = owners.allSatisfy { kill($0, 0) == 0 }
        guard utmAlive, let settled = VMProcesses.find(vm, id: id) else {
            let restarted = !pidsBefore.isEmpty && pidsBefore.isDisjoint(with: owners) ? " (UTM had already restarted once during the start)" : ""
            return .failure(WinbarError("UTM crashed while starting the VM",
                                        "\(vm) stopped within seconds of starting\(restarted). "
                                            + (crashReport(since: started).map { "Crash report: \($0)" }
                                               ?? "Look for UTM-*.ips in ~/Library/Logs/DiagnosticReports.")))
        }
        if cacheSettings { VMProcesses.cache(settled, for: vm) }
        return .success(settled)
    }

    /// Whether a start may record what it saw (the MAC, the display state) in Winbar's per-VM
    /// settings. Only for the VM Winbar looks after: those keys are what `winbar connect`, the DHCP
    /// lease lookup and the menu work from, so another VM's MAC written over them makes Winbar
    /// describe — and act on — the wrong VM. `winbar create --no-select` says `asked: false`.
    static func shouldCacheSettings(vm: String, selected: String?, asked: Bool) -> Bool {
        asked && selected != nil && vm == selected
    }

    /// The newest UTM crash report written since `date`, if any.
    static func crashReport(since date: Date) -> String? {
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files
            .filter { $0.lastPathComponent.hasPrefix("UTM") && $0.pathExtension == "ips" }
            .compactMap { url -> (URL, Date)? in
                guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                      modified >= date.addingTimeInterval(-2) else { return nil }
                return (url, modified)
            }
            .max { $0.1 < $1.1 }?.0.path
    }

    /// Stops the VM and waits for its QEMU process to exit.
    ///
    /// Graceful goes through Windows itself. UTM's own "request" stop is an ACPI power-button press, and
    /// once Windows has blanked its display that press only wakes it (Kernel-Power 566 "0→1", then
    /// "1→3") and the VM never stops. `force` is a hard power-off, like pulling the cord.
    static func stop(_ vm: String, force: Bool, timeout: TimeInterval? = nil) -> Result<Void, WinbarError> {
        stop(vm, force: force, timeout: timeout, abort: { false }) ?? .success(())
    }

    /// The same, but the wait can be given up on: `abort` is asked every couple of seconds, and nil
    /// comes back when it says yes. Windows has already been asked to shut down at that point and
    /// carries on doing it — this only stops Winbar waiting, which is what `winbar create` needs so
    /// that Ctrl-C isn't ignored for the ten minutes a slow "Configuring updates" screen can take.
    static func stop(_ vm: String, force: Bool, timeout: TimeInterval? = nil,
                     abort: () -> Bool) -> Result<Void, WinbarError>? {
        guard VMProcesses.isRunning(vm) else { return .success(()) }
        let result = force ? ctl(["stop", "--force", vm], timeout: 30) : requestShutdown(vm)
        guard result.ok else {
            return .failure(Automation.explain(result.output, else: WinbarError("Couldn't stop \(vm)", result.output)))
        }
        guard let stopped = waitForStop(deadline: Date().addingTimeInterval(timeout ?? (force ? 30 : 120)),
                                        every: 2, stopped: { !VMProcesses.isRunning(vm) }, abort: abort)
        else { return nil }
        guard !stopped else { return .success(()) }
        return .failure(WinbarError("\(vm) didn't shut down",
                                    "Windows may be waiting on an app or an update. Force Stop (⌥ in the menu, or `winbar stop --force`) powers it off."))
    }

    /// The wait after a stop request: `stopped` and `abort` are asked in turn until one says yes or
    /// the deadline passes. nil means `abort` said to give up waiting — nothing was done to the VM,
    /// which is still shutting down. Takes its two questions as closures so it can be tested without
    /// one.
    static func waitForStop(deadline: Date, every interval: TimeInterval, stopped: () -> Bool,
                            abort: () -> Bool) -> Bool? {
        while true {
            if stopped() { return true }
            if abort() { return nil }
            guard Date() < deadline else { return false }
            pause(interval)
        }
    }

    enum ForceStopChoice { case keepWaiting, forceStop, giveUp }

    /// A graceful stop that, after two minutes, explains and asks what to do; keeping on waiting is
    /// the default everywhere. Never forces without asking: Windows may be installing updates, which
    /// it shows only on a screen nobody sees while headless, and powering off in the middle of that
    /// can leave it unbootable. An app holding unsaved work is the other likely reason.
    static func shutDown(_ vm: String, offerForce: (String) -> ForceStopChoice) -> Result<Void, WinbarError> {
        guard case .failure(let error) = stop(vm, force: false, timeout: 120) else { return .success(()) }
        if error.automationDenied { return .failure(error) }   // nothing was asked of Windows, so there's nothing to wait for
        var minutes = 2
        while VMProcesses.isRunning(vm) {
            switch offerForce(forceStopQuestion(vm, minutes: minutes)) {
            case .keepWaiting:
                if waitUntil(timeout: 300, every: 2, { !VMProcesses.isRunning(vm) }) { return .success(()) }
                minutes += 5
            case .forceStop:
                return stop(vm, force: true)
            case .giveUp:
                return .failure(error)
            }
        }
        return .success(())
    }

    static func forceStopQuestion(_ vm: String, minutes: Int) -> String {
        "\(vm) hasn't shut down after \(minutes) minutes. Windows may be installing updates, which it doesn't show while "
            + "the VM is headless; turning it off in the middle of that can damage Windows. It may also be waiting on an "
            + "app with unsaved work. Force stop is like pulling the power cord."
    }

    /// Asks Windows to shut down via the guest agent, falling back to UTM's ACPI request.
    static func requestShutdown(_ vm: String) -> CommandResult {
        let guest = ctl(["exec", vm, "--cmd", "cmd.exe", "/c", "shutdown /s /t 0"], timeout: 30)
        return guest.ok ? guest : ctl(["stop", "--request", vm], timeout: 30)
    }

    // MARK: Guest agent

    /// The agent answers once Windows has booted far enough to start it; `ip-address` is the cheapest
    /// question that needs it.
    static func guestAgentAnswers(_ vm: String) -> Bool {
        let result = ctl(["ip-address", vm], timeout: 20)
        return result.ok && !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @discardableResult
    static func waitForGuestAgent(_ vm: String, timeout: TimeInterval = 180) -> Bool {
        waitUntil(timeout: timeout, every: 5) { VMProcesses.isRunning(vm) && guestAgentAnswers(vm) }
    }
}

/// The UTM restart a display change owes.
///
/// UTM (4.7.5 through 5.0.5) keeps a stopped VM's display window and reuses it on the next start;
/// with the display list changed underneath it, that start crashes UTM, and every VM it runs goes
/// with it. Quitting UTM after the change avoids it, but Reconfigure can fail, time out or be killed
/// between sending the change and quitting UTM. So the obligation is written down first, as the pids
/// of the UTM processes that got the change, and `UTM.start` settles it: once none of those pids is
/// UTM any more, it's paid.
struct UTMRestart: Equatable {
    var vm: String
    var pids: [pid_t]

    /// Adds `pids` to what an earlier, unsettled change recorded, so neither obligation is lost.
    static func recording(vm: String, pids: [pid_t], over earlier: UTMRestart?) -> UTMRestart {
        UTMRestart(vm: vm, pids: Array(Set(pids).union(earlier?.pids ?? [])).sorted())
    }

    /// The recorded processes that are still UTM.
    func stillRunning(isUTM: (pid_t) -> Bool) -> [pid_t] { pids.filter(isUTM) }

    var plist: [String: Any] { ["vm": vm, "pids": pids.map(Int.init)] }

    init(vm: String, pids: [pid_t]) {
        self.vm = vm
        self.pids = pids
    }

    init?(plist: [String: Any]) {
        guard let vm = plist["vm"] as? String, let pids = plist["pids"] as? [Int] else { return nil }
        self.init(vm: vm, pids: pids.map { pid_t($0) })
    }
}

/// `WINBAR_DEBUG=1 winbar …` prints decisions that are otherwise silent (to stderr), for diagnosing
/// reports from other Macs.
enum Debug {
    static let enabled = ProcessInfo.processInfo.environment["WINBAR_DEBUG"] == "1"
    static func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        FileHandle.standardError.write(Data(("winbar debug: " + message() + "\n").utf8))
    }
}
