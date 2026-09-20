import Foundation

/// VM configuration changes that need the VM off: vCPUs, RAM, the display and the shared folder.
/// Collected so that setup can apply several of them with a single restart.
struct ConfigChanges: Equatable {
    var cpuCores: Int?
    var memoryMB: Int?
    var display: UTMScripting.DisplayMode?
    /// The folder UTM shares with the guest. Not hardware (see `changesHardware`), but UTM only
    /// passes it to the guest when it is set while the VM is stopped, so it rides the same restart.
    var sharedFolder: SharedFolder.Setting?

    var isEmpty: Bool { cpuCores == nil && memoryMB == nil && display == nil && sharedFolder == nil }

    /// Whether anything about the VM's devices changes. BitLocker seals itself to those, so only
    /// these need the guard; the shared folder alters no device (the SPICE channel carrying it is
    /// there either way).
    var changesHardware: Bool { cpuCores != nil || memoryMB != nil || display != nil }

    var summary: String {
        var parts: [String] = []
        if let cpuCores { parts.append("\(cpuCores) vCPUs") }
        if let memoryMB { parts.append("\(memoryMB) MB RAM") }
        switch display {
        case .headless: parts.append("headless")
        case .console: parts.append("console window on")
        case nil: break
        }
        switch sharedFolder {
        case .folder(let path): parts.append("sharing \(SharedFolder.abbreviate(path))")
        case .off: parts.append("no shared folder")
        case nil: break
        }
        return parts.joined(separator: ", ")
    }
}

/// How a long VM operation talks to whoever started it: the menu (alerts) or the CLI (prompts).
struct Interaction {
    /// Each step, as it starts.
    var progress: (String) -> Void
    /// BitLocker couldn't be checked. Carry on anyway? The reason is passed in.
    var confirmUnverifiedBitLocker: (String) -> Bool
    /// A graceful shutdown is taking long. Keep waiting, force it off, or give up? The explanation is
    /// passed in.
    var offerForceStop: (String) -> UTM.ForceStopChoice

    /// The terminal's way of asking what `offerForceStop` asks. Enter keeps waiting; with no terminal
    /// to ask on, Winbar stops waiting rather than force anything.
    static func askForceStopAtTerminal(_ why: String) -> UTM.ForceStopChoice {
        print(why)
        guard Term.stdinIsTTY else {
            print("No terminal to ask on, so Winbar stops waiting (Windows carries on shutting down).")
            return .giveUp
        }
        switch Term.pick("Keep waiting five more minutes, force stop, or give up waiting?",
                         [("w", "wait"), ("f", "force stop"), ("g", "give up")]) {
        case "f": return .forceStop
        case "g": return .giveUp
        default: return .keepWaiting
        }
    }
}

enum Reconfigure {
    /// Applies `requested` with one clean restart: BitLocker guard (while Windows is still up) →
    /// graceful shutdown → `update registry` for the shared folder → UTM's `update configuration` →
    /// verify → start. The VM ends in the state it started in. Returns what actually had to change: a
    /// display already in the requested mode, or a shared folder UTM already has, is dropped from the
    /// request.
    ///
    /// Blocking. The guard runs before every hardware change, not only display ones: vCPU and RAM
    /// changes alter the ACPI tables too, and that case was never tested against a protected disk. A
    /// shared-folder change alters no device, so it doesn't boot a stopped VM for the guard. The drive
    /// list is never touched: topology changes there trip BitLocker recovery and can invalidate the
    /// UEFI boot entry.
    static func apply(_ requested: ConfigChanges, to vm: String, _ interaction: Interaction) -> Result<ConfigChanges, WinbarError> {
        let progress = interaction.progress
        var changes = requested
        guard !changes.isEmpty else { return .success(changes) }

        switch UTMScripting.vm(named: vm) {
        case .failure(let error): return .failure(error)
        case .success(nil): return .failure(WinbarError("UTM has no VM named \(vm)"))
        case .success(let info?):
            guard info.backend == "qemu" else {
                return .failure(WinbarError("\(vm) doesn't use UTM's QEMU backend", "Winbar only manages QEMU virtual machines."))
            }
            // UTM's own count is the truth, and the menu decides its toggle from a cache that can be
            // stale while the VM is off: correct the cache, and never rewrite a display (booting the
            // VM for the BitLocker guard, restarting UTM) just to land where it already is.
            if let count = info.displayCount {
                Config.consoleEnabled = count > 0
                if changes.display == (count == 0 ? .headless : .console) { changes.display = nil }
            }
        }
        // Same idea for the shared folder, and it matters more: this is the only way to know, and a
        // folder UTM already shares must never cost a restart.
        if let wanted = changes.sharedFolder {
            switch SharedFolder.current(vm: vm) {
            case .failure(let error):
                return .failure(WinbarError("Couldn't ask UTM which folder \(vm) shares", error.description))
            case .success(let now):
                if SharedFolder.matches(now, wanted) { changes.sharedFolder = nil }
            }
        }
        guard !changes.isEmpty else {
            // An earlier display change that failed half way may still owe UTM its restart. The VM is
            // off and the person asked for a display change, which always restarts UTM, so pay it now
            // rather than at the next start.
            if requested.display != nil, !VMProcesses.isRunning(vm), let pending = Config.pendingUTMRestart {
                if !pending.stillRunning(isUTM: UTM.isUTMProcess).isEmpty {
                    progress("Restarting UTM, which an earlier display change still needs…")
                }
                if case .failure(let error) = UTM.settlePendingRestart(before: vm) { return .failure(error) }
            }
            return .success(changes)
        }

        // A display change ends with quitting UTM (see below), which would stop every other VM it runs.
        // Refuse before anything has happened rather than after this VM is already shut down.
        if changes.display != nil, let refusal = otherVMsRefusal(vm, changed: false) { return .failure(refusal) }

        let wasRunning = VMProcesses.isRunning(vm)

        // The guard has to run while Windows is up, i.e. before the shutdown, so a stopped VM is always
        // booted for it. A cached "C: is decrypted" is no shortcut: BitLocker can be turned back on (by
        // the person, or a work policy) before the VM was shut down, and nothing Winbar can see while
        // it's off proves otherwise. Trusting it would leave a headless VM at an invisible recovery screen.
        //
        // Only for hardware changes. BitLocker seals to the device topology, which a shared folder
        // doesn't touch, so sharing a folder must not cost a stopped VM a boot and a shutdown.
        if changes.changesHardware {
            var bootedForGuard = false
            let guardResult: BitLocker.Guard
            if wasRunning {
                progress("Checking BitLocker…")
                guardResult = UTM.guestAgentAnswers(vm)
                    ? BitLocker.suspendForOneBoot(vm: vm)
                    : .unknown("The guest agent isn't answering, so Winbar can't check BitLocker.")
            } else {
                progress("Starting \(vm) to check BitLocker…")
                if case .failure(let error) = UTM.start(vm) { return .failure(error) }
                bootedForGuard = true
                progress("Waiting for Windows…")
                guardResult = UTM.waitForGuestAgent(vm, timeout: 240)
                    ? BitLocker.suspendForOneBoot(vm: vm)
                    : .unknown("Windows didn't start far enough for Winbar to check BitLocker.")
            }
            if case .unknown(let why) = guardResult {
                let carryOn = interaction.confirmUnverifiedBitLocker(
                    why + " If C: is BitLocker-protected, Windows will ask for its recovery key after this change.")
                if !carryOn {
                    if bootedForGuard { _ = UTM.shutDown(vm, offerForce: interaction.offerForceStop) }
                    return .failure(WinbarError("Cancelled", "Nothing was changed."))
                }
            }
        }

        if VMProcesses.isRunning(vm) {
            progress("Shutting down \(vm)…")
            if case .failure(let error) = UTM.shutDown(vm, offerForce: interaction.offerForceStop) { return .failure(error) }
        }
        // UTM can report "stopping" for a moment after QEMU exits, and refuses updates until "stopped".
        let settled = waitUntil(timeout: 30, every: 2) {
            if case .success(let info?) = UTMScripting.vm(named: vm) { return info.status == "stopped" }
            return false
        }
        guard settled else { return .failure(WinbarError("UTM still reports \(vm) as running")) }

        /// Brings the VM back if it was running, so a failure doesn't leave it off. Only while its display
        /// hasn't changed: starting it in this UTM after that would crash it.
        func startAgain(after error: WinbarError) -> WinbarError {
            guard wasRunning else { return error }
            progress("Starting \(vm) again…")
            if case .failure(let startError) = UTM.start(vm) {
                return WinbarError(error.title, error.detail + " \(vm) is off, and starting it again failed too: \(startError)")
            }
            return WinbarError(error.title, error.detail + " \(vm) was started again.")
        }

        // First of the changes, because it is the only one that can fail with nothing else touched
        // yet: `update registry` is a separate call from `update configuration`.
        if let folder = changes.sharedFolder {
            progress(folder == .off ? "Stopping \(vm)'s folder sharing…" : "Setting \(vm)'s shared folder…")
            switch SharedFolder.setWhileStopped(folder, vm: vm) {
            case .failure(let error):
                return .failure(startAgain(after: WinbarError("UTM didn't accept the shared folder", error.description)))
            case .success(let now):
                guard SharedFolder.matches(now, folder) else {
                    let reported = now.map { "“\(SharedFolder.abbreviate($0))”" } ?? "no folder"
                    return .failure(startAgain(after: WinbarError("UTM didn't apply the shared folder",
                                                                  "It reports \(reported) for \(vm).")))
                }
                Config.rememberSharedFolder(folder.path, for: vm)
            }
        }

        var restartBefore: UTMRestart?
        if changes.display != nil {
            // Again, just before anything changes: the guard and the shutdown take minutes, and a VM
            // started meanwhile would be stopped by the UTM restart.
            if let refusal = otherVMsRefusal(vm, changed: false) { return .failure(startAgain(after: refusal)) }
            // Written down before the change is sent, so a failure, a timeout or Winbar being killed
            // from here on still leaves the next start knowing UTM must restart first.
            UTM.ensureRunning()
            restartBefore = Config.pendingUTMRestart
            UTM.recordPendingRestart(for: vm)
        }

        if changes.changesHardware {
            progress("Changing \(vm)'s configuration…")
            let applied: UTMScripting.Applied
            switch UTMScripting.updateConfiguration(vm: vm, cpuCores: changes.cpuCores,
                                                    memoryMB: changes.memoryMB, display: changes.display) {
            case .failure(let error):
                let failure = WinbarError("UTM didn't accept the change", error.description)
                // 1001–1003 are the script's own checks, raised before `update configuration` is sent:
                // nothing changed, so nothing is owed. Anything else may have landed part way.
                let untouched = AppleScriptRunner.errorNumber(in: error.detail).map { (1001...1003).contains($0) } ?? false
                if untouched || changes.display == nil {
                    if changes.display != nil { Config.pendingUTMRestart = restartBefore }
                    return .failure(startAgain(after: failure))
                }
                return .failure(WinbarError(failure.title, failure.detail + " " + restartOwed(vm)))
            case .success(let result):
                applied = result
            }
            var mismatches: [String] = []
            if let want = changes.cpuCores, applied.cpuCores != want { mismatches.append("vCPUs \(applied.cpuCores.map(String.init) ?? "?") (wanted \(want))") }
            if let want = changes.memoryMB, applied.memoryMB != want { mismatches.append("RAM \(applied.memoryMB.map(String.init) ?? "?") MB (wanted \(want))") }
            switch changes.display {
            case .headless where applied.displayCount != 0: mismatches.append("display still present")
            case .console where (applied.displayCount ?? 0) == 0: mismatches.append("no display added")
            default: break
            }
            if let count = applied.displayCount { Config.consoleEnabled = count > 0 }
            guard mismatches.isEmpty else {
                let detail = mismatches.joined(separator: "; ") + (changes.display != nil ? ". " + restartOwed(vm) : "")
                return .failure(WinbarError("UTM didn't apply everything", detail))
            }
        }
        if changes.display != nil {
            // UTM (4.7.5 through 5.0.5) keeps a stopped VM's display window and reuses it on the next
            // start. Its SPICE delegate then reads `displays[0]` of the *new* configuration, and with the
            // list emptied that's an out-of-bounds trap: UTM crashes about two seconds after QEMU starts
            // and takes the VM with it. A freshly launched UTM picks the window type from the current
            // configuration, so quit it now; the next utmctl call relaunches it. Any display change gets
            // this treatment, not only console → headless. (UTM.start refuses too, until this is done.)
            if let refusal = otherVMsRefusal(vm, changed: true) { return .failure(refusal) }
            progress("Restarting UTM so it forgets the old display window…")
            if case .failure(let error) = UTM.quit() {
                return .failure(WinbarError("The configuration changed, but UTM has to restart before \(vm) starts again",
                                            error.detail + " " + restartOwed(vm)))
            }
        }

        if wasRunning {
            progress("Starting \(vm)…")
            if case .failure(let error) = UTM.start(vm) {
                return .failure(WinbarError("The configuration changed, but \(vm) didn't start again", error.description))
            }
        }
        return .success(changes)
    }

    /// Why UTM mustn't be restarted now, if it mustn't: other VMs are running (or UTM couldn't say),
    /// and restarting it would stop them. `changed` says whether the display change already happened.
    private static func otherVMsRefusal(_ vm: String, changed: Bool) -> WinbarError? {
        let title: String, why: String
        switch UTM.otherRunningVMs(than: vm) {
        case .failure(let error):
            title = "Couldn't confirm no other VMs are running"
            why = "Winbar couldn't ask UTM (\(error.detail)), and restarting UTM would stop any other VM"
        case .success(let others) where !others.isEmpty:
            title = "Stop your other VMs first"
            why = "Restarting UTM would stop \(others.joined(separator: ", "))"
        case .success:
            return nil
        }
        guard changed else {
            return WinbarError(title, why + ". Changing the display means restarting UTM, so nothing was changed. "
                                   + "Stop your other VMs (or quit UTM), then try again.")
        }
        return WinbarError("\(vm)'s display changed, but UTM couldn't restart yet",
                           why + ", so Winbar left UTM running. " + restartOwed(vm))
    }

    private static func restartOwed(_ vm: String) -> String {
        "UTM has to restart before \(vm) starts again, or it would crash: Winbar does that at the next start once no other VM is "
            + "running, or quit UTM yourself."
    }
}
