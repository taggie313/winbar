import AppKit

/// UTM itself: the app, `utmctl`, and starting and stopping a VM.
///
/// Everything here blocks; the menu bar app calls it off the main thread. Apple Events sent by
/// utmctl (and by osascript, see UTMScripting) are attributed to the responsible app, so macOS asks
/// once per host app — "“Winbar” wants access to control “UTM”" from the menu, "“Terminal” …" from the CLI.
enum UTM {
    static var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: Config.utmBundleID) }

    static var isInstalled: Bool { appURL != nil }

    /// Read from UTM's Info.plist on disk every time, not through `Bundle`: a `Bundle` is cached per
    /// path for the life of the process, so the menu bar app would go on reporting the UTM it first
    /// saw after UTM was replaced under it. That used to cost a wrong doctor row; now that the #7882
    /// restart is gated on this (`UTMFixes`), a stale 5.0.6 after going back to 4.7.5 would skip a
    /// restart 4.7.5 needs and crash it.
    static var version: String? {
        guard let url = appURL else { return nil }
        let plist = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
        return plist?["CFBundleShortVersionString"] as? String
    }

    /// Whether a display change on this UTM owes the #7882 restart (`UTMFixes`). Traced, with UTM's
    /// pids, because the UTM 5 spike reads this decision and "the pid didn't change" off
    /// `WINBAR_DEBUG=1`; `caller` says which path asked.
    static func displayChangeRestartsUTM(tracing caller: String) -> Bool {
        let version = self.version
        let restarts = UTMFixes.displayChangeRestartsUTM(version)
        Debug.log("gate7882 (\(caller)): UTM \(version ?? "version unknown") -> "
                  + (restarts ? "restart UTM after the display change" : "no UTM restart: this UTM has the #7882 fix (5.0.6+)")
                  + "; UTM pids \(processIDs)")
        return restarts
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
    /// launched since. `progress` hears the one thing a person may have to do part way: close a UTM
    /// window that refuses the quit (`UTMQuitSequence`).
    static func quit(timeout: TimeInterval = 30, progress: (String) -> Void = { _ in }) -> Result<Void, WinbarError> {
        let recorded = Config.pendingUTMRestart?.stillRunning(isUTM: isUTMProcess) ?? []
        let pids = Set(runningPIDs).union(processIDs).union(recorded)
        Debug.log("quit: runningPIDs=\(runningPIDs) processIDs=\(processIDs) recorded=\(recorded) -> \(pids.sorted())")
        guard !pids.isEmpty else {
            Config.pendingUTMRestart = nil
            return .success(())
        }
        let result = UTMQuitSequence.run(
            ask: {
                // A normal quit first, addressed by bundle id: NSRunningApplication can't be relied on to
                // find UTM (see isUTMProcess), but the Apple Event reaches it regardless, and its answer
                // is what says a window refused.
                for pid in pids { _ = NSRunningApplication(processIdentifier: pid)?.terminate() }
                return Shell.run("/usr/bin/osascript", ["-e", "tell application id \"\(Config.utmBundleID)\" to quit"], timeout: 15)
            },
            exited: { limit in waitUntil(timeout: limit, every: 0.5) { pids.allSatisfy { kill($0, 0) != 0 } } },
            forceQuit: {
                // Callers only quit UTM with no VM running (see otherRunningVMs), so a terminate signal
                // can't stop anything but UTM itself.
                Debug.log("quit: UTM ignored the quit request; sending SIGTERM to \(pids.sorted())")
                for pid in pids where kill(pid, 0) == 0 { kill(pid, SIGTERM) }
            },
            progress: { line in
                Debug.log("quit: UTM refused the quit (-128): a window of its own is in the way")
                progress(line)
            },
            timeout: timeout)
        if case .success = result {
            Config.pendingUTMRestart = nil   // whatever restart a display change owed has now happened
        }
        return result
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
    static func settlePendingRestart(before vm: String, progress: (String) -> Void = { _ in }) -> Result<Void, WinbarError> {
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
            if case .failure(let error) = quit(progress: progress) {
                return .failure(WinbarError("UTM has to restart before \(vm) starts", owed + " " + error.detail))
            }
            // The UTM that just quit held the bookmark behind any scripted shared folder, so write it
            // again while the VM is still stopped — this is the last moment before it starts. Best
            // effort: `winbar share` and doctor report what Windows ended up with.
            _ = SharedFolder.reestablish(vm: vm)
            return .success(())
        }
    }

    // MARK: What UTM 5.0.6 does that older UTMs don't

    /// After a script that sent `update configuration`: whether the UTM it went to has quit by itself
    /// (`UTMFixes.mayQuitAfterUpdate`), and if it has, UTM launched again so that whatever asks next —
    /// the read-back first — has something to answer it. `grace` is how long to give the quit to
    /// finish: it can land a moment after the script's own error, or just after an answer. On a UTM
    /// that never does this it returns straight away, so older UTMs pay nothing for it.
    @discardableResult
    static func relaunchIfQuitItself(after pidsBefore: [pid_t], sentChange: Bool, grace: TimeInterval) -> Bool {
        let version = self.version
        guard UTMFixes.mayQuitAfterUpdate(version), sentChange, !pidsBefore.isEmpty else { return false }
        let gone = waitUntil(timeout: grace, every: 0.5) { pidsBefore.allSatisfy { !isUTMProcess($0) } }
        guard UTMFixes.quitItselfAfterUpdate(version: version, sentChange: sentChange, utmGone: gone) else {
            Debug.log("utmquit: UTM \(pidsBefore) still running after update configuration")
            return false
        }
        Debug.log("utmquit: UTM \(version ?? "?") (pids \(pidsBefore)) quit by itself after update configuration; "
                  + "launching it again before the read-back")
        ensureRunning()
        Debug.log("utmquit: UTM is running again as \(processIDs)")
        return true
    }

    /// Runs `body` — a script that sends `update configuration` — with UTM told not to quit when its
    /// last window closes, on a UTM that would otherwise quit mid-change and lose it
    /// (`UTMFixes.mayQuitAfterUpdate`). UTM's own scripting has the switch: the application's
    /// `auto terminate` property (UTM.sdef, the same in 4.7.5 and 5.0.6), which is its "keep
    /// running after the last window closes" setting read the other way round. Winbar only ever
    /// turns it off when it was on, and turns it back on straight after; a UTM older than 5.0.6 is
    /// never asked anything, so 4.7.5 behaves exactly as before.
    ///
    /// Chosen over opening UTM's library window around the change: showing a window would put UTM
    /// in front of whatever the person is doing, and closing it again afterwards has no scripting
    /// verb at all.
    static func keepingOpen<T>(_ body: () -> T) -> T {
        UTMOpenHold.around(applies: UTMFixes.mayQuitAfterUpdate(version),
                           pending: Config.utmHeldOpen, record: { Config.utmHeldOpen = $0 },
                           hold: UTMScripting.holdOpen,
                           release: { isAppRunning && UTMScripting.releaseHold() },
                           body)
    }

    /// Waits while UTM 5.0.6+ reports this VM, which is off, as pausing or resuming: it is working on
    /// the VM's disks (`UTMFixes.reportsBusyWhileOff`), and a start in that window fails after opening
    /// a window. Bounded; past the bound it says UTM is busy, never that the VM is starting or
    /// stopping. Asks nothing of an older UTM, so a start there costs no extra Apple Event. A listing
    /// that fails says nothing about busy, and the caller carries on as it did before.
    static func waitWhileBusy(_ vm: String, id: String? = nil, timeout: TimeInterval = 120) -> Result<Void, WinbarError> {
        guard UTMFixes.reportsBusyWhileOff(version) else { return .success(()) }
        var logged = false
        let started = Date()
        let stillBusy = UTMFixes.waitOutBusy(deadline: started.addingTimeInterval(timeout), every: 2) {
            guard case .success(let list) = UTMScripting.listVMs(),
                  let info = list.first(where: { info in
                      if let id { return info.id.caseInsensitiveCompare(id) == .orderedSame }
                      return info.name == vm
                  }),
                  info.busyWhileOff
            else { return nil }
            if !logged {
                Debug.log("busy: UTM reports \(vm) as \(info.status) with no QEMU process (working on its disks); "
                          + "waiting up to \(Int(timeout)) s")
                logged = true
            }
            return info.status
        }
        guard let stillBusy else {
            if logged { Debug.log("busy: \(vm) settled after \(Int(Date().timeIntervalSince(started))) s") }
            return .success(())
        }
        Debug.log("busy: \(vm) still \(stillBusy) after \(Int(timeout)) s; giving up")
        return .failure(WinbarError("UTM is busy with \(vm)",
                                    "UTM reports \(vm) as \(stillBusy) although it's off: it is working on the VM's disk "
                                        + "images, which UTM 5 does for snapshots and saved states. Winbar waited "
                                        + "\(Int(timeout)) seconds. Try again once UTM has finished."))
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
        /// holds the first one until somebody answers "“…” wants access to control “UTM”" — a prompt that can
        /// open behind another window, and that a Mac nobody is sitting at never gets.
        case silent(seconds: Int)
        /// It answered, with a failure of its own.
        case failed(String)

        var isAnswered: Bool { self == .answered }
    }

    /// Pure, so every verdict can be told apart without UTM.
    ///
    /// Exit 0 alone isn't an answer: utmctl prints UTM's refusals as "Error from event: …" and still
    /// exits 0 (UTMCtl.swift at 4.7.5 and 5.0.6 alike; the spike saw it for a failing exec, row 14,
    /// and for UTM 5.0.6 refusing to save a GPU VM's state, row 12b). Only that prefix is looked for,
    /// not "Error" anywhere, because a successful `list` prints VM names, which may contain the word.
    static func classifyCtl(status: Int32, output: String, timedOut: Bool, seconds: Int) -> CtlAnswer {
        if Automation.isDenied(output) { return .denied }
        if timedOut { return .silent(seconds: seconds) }
        if status == 0, !output.contains(utmctlEventError) { return .answered }
        return .failed(output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// How utmctl starts a failure it reports on stderr while exiting 0.
    static let utmctlEventError = "Error from event"

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
    /// `progress` reaches the person while an owed UTM restart is settled first: a What's New window
    /// (4.7.5 has one too) makes UTM refuse that quit, and only the person can close it, so the line
    /// saying so has to be on their screen during the wait, not just in the error after it. No
    /// default, so a new caller has to decide where that line goes rather than drop it by omission.
    static func start(_ vm: String, id: String? = nil, cacheSettings: Bool = true,
                      progress: (String) -> Void) -> Result<VMProcess, WinbarError> {
        if let running = VMProcesses.find(vm, id: id) {
            // A paused VM has its process too: resume it rather than call it started.
            if case .failure(let error) = resumeIfPaused(vm, id: id) { return .failure(error) }
            return .success(running)
        }
        if case .failure(let error) = waitWhileBusy(vm, id: id) { return .failure(error) }
        // Still asked on a UTM with the #7882 fix: a restart recorded under an older UTM whose
        // process is still running is owed by that process, whatever is on disk now.
        if case .failure(let error) = settlePendingRestart(before: vm, progress: progress) { return .failure(error) }
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

    // MARK: Paused VMs

    /// What `resumeIfPaused` found.
    enum PausedOutcome: Equatable {
        /// Not paused (or UTM couldn't say): whatever the caller was about to do still stands.
        case notPaused
        /// It was paused in UTM and is running again.
        case resumed
    }

    /// Resumes the VM when UTM holds it paused. A paused VM keeps its QEMU process, so every "is it
    /// running?" Winbar asks of the process table says yes, and `winbar start` answered "already
    /// running" to a VM frozen in UTM (spike rows 12a, 12b) while Connect waited on a Windows that
    /// couldn't answer. utmctl's `start` is UTM's resume for a paused VM, on 4.7.5 and 5.0.6 alike
    /// (`UTMScriptingVirtualMachineImpl.start`: `.paused` → `vm.resume()` at both tags), so that is
    /// what is sent. UTM's word is asked only once a process exists, so an ordinary start costs
    /// nothing more; a UTM that can't be asked leaves the caller's path as it was.
    static func resumeIfPaused(_ vm: String, id: String? = nil) -> Result<PausedOutcome, WinbarError> {
        resumeIfPaused(vm, status: { status(of: vm, id: id) },
                       resume: { ctl(["start", id ?? vm], timeout: 60) },
                       wait: { waitUntil(timeout: 20, every: 1, $0) })
    }

    /// The decision, with UTM behind closures. utmctl exits 0 on most failures and says so only in
    /// text (a refused resume included), so the command is judged by `ok`, and then by UTM saying
    /// "started": a resume UTM accepted but didn't carry out still reads as a failure.
    static func resumeIfPaused(_ vm: String, status: @escaping () -> String?, resume: () -> CommandResult,
                               wait: (() -> Bool) -> Bool) -> Result<PausedOutcome, WinbarError> {
        guard status() == "paused" else { return .success(.notPaused) }
        Debug.log("resume: \(vm) is paused in UTM; resuming it")
        let result = resume()
        guard result.ok else {
            return .failure(Automation.explain(result.output, else: WinbarError(
                "Couldn't resume \(vm)", "UTM has it paused and didn't resume it: \(result.output)")))
        }
        guard wait({ status() == "started" }) else {
            return .failure(WinbarError("\(vm) is still paused",
                                        "UTM took the request to resume it but still shows it paused. Resume it in UTM's window."))
        }
        return .success(.resumed)
    }

    /// UTM's own word for the VM's state ("paused", "started", …), found by id when there is one and
    /// by name otherwise; nil when UTM can't be asked.
    static func status(of vm: String, id: String?) -> String? {
        guard case .success(let list) = UTMScripting.listVMs() else { return nil }
        return (list.first { id != nil && $0.id == id } ?? list.first { $0.name == vm })?.status
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
    /// "1→3"); the VM stops only at a second press, so a stop that fell back to it presses once more,
    /// `secondPressAfter` into the wait. `force` is a hard power-off, like pulling the cord.
    ///
    /// Measured 2026-09-27 on 25H2: an idle Windows, display blanked or headless, let a first press go
    /// by and shut down cleanly at a second, and a second press while it was shutting down did no harm.
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
        let (result, asked) = force ? (ctl(["stop", "--force", vm], timeout: 30), StopRequest.forced) : requestShutdown(vm)
        guard result.ok else {
            return .failure(Automation.explain(result.output, else: WinbarError("Couldn't stop \(vm)", result.output)))
        }
        let again = asked.pressAgainAfter.map { after in
            (after: after, press: {
                let press = pressPowerButton(vm)
                Debug.log("stop: \(vm) still running \(Int(after)) s after UTM's power-button press; pressed it again: "
                          + "status=\(press.status) timedOut=\(press.timedOut) output=\(press.output.prefix(200))")
            })
        }
        guard let stopped = waitForStop(deadline: Date().addingTimeInterval(timeout ?? (force ? 30 : 120)),
                                        every: 2, stopped: { !VMProcesses.isRunning(vm) }, abort: abort,
                                        pressAgain: again)
        else { return nil }
        guard !stopped else { return .success(()) }
        return .failure(WinbarError("\(vm) didn't shut down",
                                    "Windows may be waiting on an app or an update. Force Stop (⌥ in the menu, or `winbar stop --force`) powers it off."))
    }

    /// The wait after a stop request: `stopped` and `abort` are asked in turn until one says yes or
    /// the deadline passes. nil means `abort` said to give up waiting — nothing was done to the VM,
    /// which is still shutting down. `pressAgain`, when given, is done once, the first time the VM is
    /// still running that many seconds into the wait. Takes its questions as closures so it can be
    /// tested without one.
    static func waitForStop(deadline: Date, every interval: TimeInterval, stopped: () -> Bool, abort: () -> Bool,
                            pressAgain: (after: TimeInterval, press: () -> Void)? = nil) -> Bool? {
        var again = pressAgain.map { (at: Date().addingTimeInterval($0.after), press: $0.press) }
        while true {
            if stopped() { return true }
            if abort() { return nil }
            guard Date() < deadline else { return false }
            if let due = again, Date() >= due.at {
                again = nil
                due.press()
            }
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

    /// How a stop was put to the VM: through Windows' guest agent, UTM's power-button press, or a
    /// forced power-off.
    enum StopRequest {
        case guestAgent, powerButton, forced

        /// How far into the wait the power button is pressed once more, or nil for never: only the
        /// press can go unheard, by a Windows that has been idle.
        var pressAgainAfter: TimeInterval? { self == .powerButton ? UTM.secondPressAfter : nil }
    }

    /// Twice the 7 s a heard press took to end the VM; a press while Windows was shutting down did no harm.
    static let secondPressAfter: TimeInterval = 15

    /// Asks Windows to shut down via the guest agent, falling back to UTM's ACPI request, and says
    /// which it used. `run` is utmctl, so a test can hand in its own.
    static func requestShutdown(_ vm: String, run: ([String]) -> CommandResult = { ctl($0, timeout: 30) })
        -> (result: CommandResult, asked: StopRequest) {
        let guest = run(["exec", vm, "--cmd", "cmd.exe", "/c", "shutdown /s /t 0"])
        return guest.ok ? (guest, .guestAgent) : (pressPowerButton(vm, run: run), .powerButton)
    }

    /// UTM's ACPI power-button press: a graceful stop's fallback, and its second press.
    static func pressPowerButton(_ vm: String, run: ([String]) -> CommandResult = { ctl($0, timeout: 30) }) -> CommandResult {
        run(["stop", "--request", vm])
    }

    // MARK: Guest agent

    /// The agent answers once Windows has booted far enough to start it; `ip-address` is the cheapest
    /// question that needs it.
    static func guestAgentAnswers(_ vm: String) -> Bool {
        let result = ctl(["ip-address", vm], timeout: 20)
        return result.ok && !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @discardableResult
    /// `cancelled` ends the wait early, false, the way the timeout does.
    ///
    /// `vm` is the VM's **name**: the process table is searched by `-name`, which UTM cleans of
    /// punctuation. `id`, when known, is UTM's id for it, matched against `-uuid` first and handed to
    /// utmctl, which takes either. An id passed as the name matches no process at all, so the wait
    /// runs its whole timeout against a Windows that answered long ago — the finish restart's false
    /// "Windows didn't answer within three minutes" (W_SLOW_BOOT). `isRunning` and `answers` are the
    /// two questions asked each round, so a test can hand in its own.
    static func waitForGuestAgent(_ vm: String, id: String? = nil, timeout: TimeInterval = 180,
                                  cancelled: (() -> Bool)? = nil,
                                  isRunning: (String, String?) -> Bool = { VMProcesses.isRunning($0, id: $1) },
                                  answers: (String) -> Bool = guestAgentAnswers) -> Bool {
        waitUntil(timeout: timeout, every: 5, cancelled: cancelled) { isRunning(vm, id) && answers(id ?? vm) }
    }
}

/// Turning UTM's `auto terminate` off around a change and back on afterwards (`UTM.keepingOpen`),
/// with every UTM question passed in so the order of things is tested without a UTM.
enum UTMOpenHold {
    enum Answer: Equatable {
        /// It was on; Winbar turned it off and must turn it back on.
        case held
        /// It was already off (the person keeps UTM running): nothing to put back.
        case wasOff
        /// UTM couldn't say. The change goes ahead anyway, as it did before this existed, and the
        /// relaunch-and-resend in `UTMScripting.updateConfiguration` is what's left to catch a quit.
        case failed
    }

    /// `pending` is a hold an earlier run recorded and never released (Winbar killed mid-change):
    /// the setting is still off because of Winbar, so this run doesn't ask again and puts it back
    /// at the end. The hold is recorded before `body` runs, so that can't be lost; a release that
    /// doesn't happen (UTM not running to hear it) stays recorded for the next run.
    static func around<T>(applies: Bool, pending: Bool, record: (Bool) -> Void,
                          hold: () -> Answer, release: () -> Bool, _ body: () -> T) -> T {
        guard applies else { return body() }
        var held = pending
        if !held, hold() == .held {
            held = true
            record(true)
        }
        let result = body()
        if held, release() { record(false) }
        return result
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
///
/// UTM 5.0.6 closes the window itself (utmapp/UTM#7899), so nothing new is written down there
/// (`UTMFixes.displayChangeRestartsUTM`). Settling is not gated: a record left by an older UTM whose
/// process is still running is owed by that process.
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
