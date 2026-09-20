import AppKit
import ServiceManagement

/// The menu bar app.
///
/// Polls the process table for the VM's QEMU process every five seconds (no subprocesses, no Apple
/// Events) and only touches the RDP port when the menu opens or while starting, so it stays cheap on
/// battery. Nothing that talks to UTM runs on a timer: any utmctl or AppleScript call launches UTM if
/// it isn't running.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private var statusLine: NSMenuItem?

    private var vmName: String?
    private var running = false
    private var consoleEnabled = true
    private var rdpReady: RDP.Readiness?  // nil = not checked since the VM last changed state
    private var activity: String?         // non-nil while a start/stop/etc. is in progress
    private var blinkOn = false
    private var pollTimer: Timer?
    private var blinkTimer: Timer?

    private let chooseMenu = NSMenu()
    private var knownVMs: [VMInfo]?
    private var vmListError: WinbarError?   // why the last listing failed, shown instead of "Asking UTM…"
    private var loadingVMs = false

    /// The `winbar create` job, while there is one. The app follows it whether or not it started it,
    /// so the menu can show a CLI run too.
    private var install: CreateJobState?
    private var installFollower: CreateJobFollower?
    /// N_RESUMED is shown for a minute after the app picks a job up on launch.
    private var resumedUntil: Date?
    /// Stage 10 only: the icon blinks while the VM is restarting.
    private var installBlinking = false

    /// A newer release, once `UpdateCheck` has found one. nil is the normal state and adds nothing
    /// to the menu: an app that is up to date should look exactly as it did before there was a
    /// check at all.
    private var newerVersion: String?

    /// What `winbar create --window` passes when it relaunches Winbar.app.
    static let createWindowArgument = "--create-window"

    /// What `winbar create --window` posts when Winbar is already running: LaunchServices hands
    /// `--args` only to a process it starts, and a second instance would mean a second menu bar icon.
    static let createWindowNotification = Notification.Name("net.elusive.winbar.create-window")

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.autosaveName = "winbar"
        menu.autoenablesItems = false
        menu.delegate = self
        chooseMenu.autoenablesItems = false
        chooseMenu.delegate = self
        statusItem.menu = menu
        followInstall()
        refresh()
        // `winbar create --window`: the CLI relaunches this bundle through LaunchServices with this
        // argument, so the window opens with the app's own privacy grants instead of the terminal's.
        // CLI.mode already leaves an option-like argument from LaunchServices to the app.
        if CommandLine.arguments.dropFirst().contains(AppDelegate.createWindowArgument) {
            CreateWindowController.present()
        }
        DistributedNotificationCenter.default().addObserver(forName: AppDelegate.createWindowNotification,
                                                            object: nil, queue: .main) { _ in
            CreateWindowController.present()
        }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refresh() }
        pollTimer?.tolerance = 2
        // What the last check found, straight from settings, so the menu is right before anything
        // touches the network — and on a Mac that has been offline ever since.
        newerVersion = UpdateCheck.knownNewerVersion
        // Then today's check, if one is due. It returns immediately and calls back only when there
        // is something newer; every failure is silent, by design (see UpdateCheck).
        UpdateCheck.checkIfDue { [weak self] version in
            self?.newerVersion = version
            self?.render()
        }
    }

    // MARK: The install job (winbar create)

    /// Follows `state.json` whoever is writing it, and picks an abandoned job up: when the watcher
    /// died without finishing (Ctrl-C, a crash, Quit), the lock is free and this app carries on from
    /// where it stopped. A job the CLI still holds is only watched, never taken.
    private func followInstall() {
        installFollower = CreateJob.follow { [weak self] state in self?.installChanged(state) }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            CreateJob.sweep()
            guard let current = CreateJob.current(), !current.isFinished, !current.watched else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                CreateWindowController.claimJob()
                self.install = current
                self.resumedUntil = Date().addingTimeInterval(60)
                self.render()
            }
            try? CreateJob.resume(vmName: current.plan.vmName) { state in
                DispatchQueue.main.async { self?.installChanged(state) }
            }
        }
    }

    /// New state, from our own run or from the CLI's. The window shows it; the menu reduces it to one
    /// line and stops offering what would fight the install.
    private func installChanged(_ state: CreateJobState) {
        CreateWindowController.shared.jobChanged(state)
        install = state.isFinished ? nil : state
        if state.isFinished {
            resumedUntil = nil
            CreateWindowController.releaseJob()
        }
        // The icon blinks only in stage 10, where Winbar is restarting the VM as it does elsewhere:
        // half an hour of blinking would be noise.
        setInstallBlinking(install?.stage == .finish)
        render()
    }

    private func setInstallBlinking(_ on: Bool) {
        guard on != installBlinking else { return }
        installBlinking = on
        if on, blinkTimer == nil {
            blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
                self?.blinkOn.toggle()
                self?.render()
            }
        } else if !on, activity == nil {
            blinkTimer?.invalidate()
            blinkTimer = nil
        }
    }

    /// The install this menu speaks for: the one whose VM the menu already looks after, or any
    /// install when no VM has been chosen yet.
    private var primaryInstall: CreateJobState? {
        guard let install else { return nil }
        return install.plan.vmName == vmName || vmName == nil ? install : nil
    }

    /// An install of a different VM: the menu keeps its own items and gains one line.
    private var otherInstall: CreateJobState? {
        guard let install, primaryInstall == nil else { return nil }
        return install
    }

    /// "copying files (14 min)", with "(in Terminal)" when the CLI is the one watching.
    private func installSummary(_ state: CreateJobState) -> String {
        let elapsed = CreateElapsed.minutes(Date().timeIntervalSince(state.startedAt))
        let terminal = CreateWindowController.ownsJob ? "" : " (in Terminal)"
        return "\(state.stage.shortTitle) (\(elapsed))\(terminal)"
    }

    @objc private func newWindowsVM() { CreateWindowController.present() }

    @objc private func showInstallProgress() { CreateWindowController.presentProgress() }

    // MARK: State + icon

    private func refresh() {
        let name = Config.vmName
        if name != vmName {
            vmName = name
            running = false
            rdpReady = nil
        }
        let process = VMProcesses.find(name)
        if (process != nil) != running {
            running = process != nil
            rdpReady = nil
        }
        if let name, let process { VMProcesses.cache(process, for: name) }
        consoleEnabled = process.map { !$0.headless } ?? Config.consoleEnabled ?? true
        render()
    }

    private var statusText: String {
        if let activity { return activity }
        if let install = primaryInstall {
            if let resumedUntil, Date() < resumedUntil { return CreateCopy.nResumed(name: install.plan.vmName) }
            return "Installing Windows: " + installSummary(install)
        }
        guard vmName != nil else { return "No VM chosen" }
        guard running else { return "Stopped" }
        switch rdpReady {
        case .ready: return "Running · ready for Remote Desktop"
        case .notReady: return "Running · Windows is still starting"
        case .blocked: return "Running · allow Local Network for Winbar to see readiness"
        case .none: return "Running"
        }
    }

    private func render() {
        let filled = (activity != nil || installBlinking) ? blinkOn : (running || install != nil)
        let image = NSImage(systemSymbolName: filled ? "square.split.2x2.fill" : "square.split.2x2",
                            accessibilityDescription: "Winbar")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.appearsDisabled = !running && activity == nil && install == nil
        statusItem.button?.toolTip = "\(vmName ?? primaryInstall?.plan.vmName ?? "Winbar") — \(statusText)"
        statusLine?.title = statusText
    }

    private func begin(_ label: String) {
        activity = label
        blinkTimer?.invalidate()
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            self?.blinkOn.toggle()
            self?.render()
        }
        render()
    }

    /// Updates the working label from a background step.
    private func step(_ label: String) {
        DispatchQueue.main.async {
            guard self.activity != nil else { return }
            self.activity = label
            self.render()
        }
    }

    private func end() {
        activity = nil
        if !installBlinking {
            blinkTimer?.invalidate()
            blinkTimer = nil
        }
        refresh()
    }

    /// Runs blocking work off the main thread, then `done` back on it.
    private func background<T>(_ work: @escaping () -> T, done: @escaping (T) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = work()
            DispatchQueue.main.async { done(result) }
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === chooseMenu {
            fillChooseMenu()
            return
        }
        refresh()
        menu.removeAllItems()
        menu.addItem(NSMenuItem.sectionHeader(title: vmName ?? primaryInstall?.plan.vmName ?? "Winbar"))
        let line = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        line.isEnabled = false
        menu.addItem(line)
        statusLine = line
        // An install of some other VM doesn't change this menu's own items; it adds one line.
        if let other = otherInstall {
            let extra = NSMenuItem(title: "Installing Windows in “\(other.plan.vmName)”: " + installSummary(other),
                                   action: nil, keyEquivalent: "")
            extra.isEnabled = false
            menu.addItem(extra)
        }
        menu.addItem(.separator())
        if install != nil {
            addItem(CreateCopy.menuProgress, #selector(showInstallProgress))
            menu.addItem(.separator())
        }

        let idle = activity == nil
        if primaryInstall != nil {
            // Connect, Start, Shut Down, Restart and the display item would all fight the install.
        } else if vmName == nil {
            // Listing VMs means asking UTM, which launches it, so that only happens once this submenu
            // is actually opened.
            let choose = NSMenuItem(title: "Choose VM", action: nil, keyEquivalent: "")
            choose.submenu = chooseMenu
            menu.addItem(choose)
            let hint = NSMenuItem(title: "Then run “winbar setup” in Terminal to tune it", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
            addItem(CreateCopy.menuNew, #selector(newWindowsVM), enabled: install == nil)
        } else {
            addItem(running ? "Connect" : "Start and Connect", #selector(connect), enabled: idle)
            menu.addItem(.separator())
            if running {
                let shutDown = addItem("Shut Down", #selector(shutDown), enabled: idle)
                shutDown.keyEquivalentModifierMask = []
                let force = addItem("Force Stop", #selector(forceStop), enabled: idle)
                force.keyEquivalentModifierMask = .option
                force.isAlternate = true
                addItem("Restart", #selector(restart), enabled: idle)
            } else {
                addItem("Start", #selector(start), enabled: idle)
            }
            menu.addItem(.separator())
            addItem(consoleEnabled ? "Go Headless…" : "Show Console Window…", #selector(toggleConsole), enabled: idle)
            // From the remembered folder, not from UTM: opening the menu must not send an Apple Event
            // (and so launch UTM). The action checks with UTM before it changes anything.
            addItem(sharedFolderOnDisk == nil ? "Share a Folder…" : "Open Shared Folder",
                    #selector(openOrChooseSharedFolder), enabled: idle)
        }
        addItem("Open UTM", #selector(openUTM))
        // One install at a time, so this is off while one runs.
        addItem(CreateCopy.menuNew, #selector(newWindowsVM), enabled: install == nil)
        // The only thing an update check is allowed to change about this menu, and only when there
        // is genuinely a newer release.
        if let newerVersion {
            menu.addItem(.separator())
            addItem(UpdateCheck.menuTitle(version: newerVersion, homebrew: UpdateCheck.isHomebrewInstall),
                    #selector(showUpdate))
        }
        menu.addItem(.separator())
        let login = addItem("Launch at Login", #selector(toggleLaunchAtLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        addItem("Quit Winbar", #selector(quit), key: "q")

        if running && idle && primaryInstall == nil {
            RDP.probe(mac: Connection.mac(vm: vmName ?? "")) { [weak self] readiness in
                self?.rdpReady = readiness
                self?.render()
            }
        }
    }

    @discardableResult
    private func addItem(_ title: String, _ action: Selector, enabled: Bool = true, key: String = "", to target: NSMenu? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.isEnabled = enabled
        (target ?? menu).addItem(item)
        return item
    }

    private func fillChooseMenu() {
        guard UTM.isInstalled else {
            // Nothing to ask, and osascript would only fail.
            chooseMenu.removeAllItems()
            let missing = NSMenuItem(title: "UTM isn't installed", action: nil, keyEquivalent: "")
            missing.isEnabled = false
            chooseMenu.addItem(missing)
            return
        }
        renderChooseItems()
        guard !loadingVMs else { return }
        loadingVMs = true
        vmListError = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result = UTMScripting.listVMs()
            // Common modes, so the submenu updates while it's open and being tracked.
            RunLoop.main.perform(inModes: [.common]) {
                self.loadingVMs = false
                switch result {
                case .success(let list):
                    self.knownVMs = list
                case .failure(let error):
                    NSLog("Winbar: couldn't list UTM's VMs: \(error)")
                    self.vmListError = error
                }
                self.renderChooseItems()
            }
        }
    }

    /// QEMU VMs, Windows ones first; the last list seen until a fresh one arrives.
    private func renderChooseItems() {
        chooseMenu.removeAllItems()
        guard let knownVMs else {
            let title = vmListError.map { "Couldn't ask UTM: \($0.title)" } ?? "Asking UTM…"
            let line = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            line.isEnabled = false
            line.toolTip = vmListError?.detail
            chooseMenu.addItem(line)
            if vmListError?.automationDenied == true {
                addItem("Open Automation Settings…", #selector(openAutomationSettings), to: chooseMenu)
            }
            return
        }
        let offered = knownVMs.filter { $0.backend == "qemu" }
            .sorted { ($0.isWindows ? 0 : 1, $0.name) < ($1.isWindows ? 0 : 1, $1.name) }
        for vm in offered {
            let item = addItem(vm.name, #selector(chooseVM(_:)), to: chooseMenu)
            item.representedObject = vm
        }
        if offered.isEmpty {
            let none = NSMenuItem(title: "UTM has no QEMU VMs", action: nil, keyEquivalent: "")
            none.isEnabled = false
            chooseMenu.addItem(none)
        }
    }

    @objc private func openAutomationSettings() {
        if let url = URL(string: Automation.settingsURL) { NSWorkspace.shared.open(url) }
    }

    @objc private func chooseVM(_ sender: NSMenuItem) {
        // The whole VM as UTM listed it, for its id: settings are filed under that, so a VM renamed
        // in UTM keeps what Winbar knows about it.
        guard let vm = sender.representedObject as? VMInfo else { return }
        Config.selectVM(vm.name, id: vm.id)
        refresh()
    }

    // MARK: Actions

    @objc private func connect() {
        guard let vm = vmName else { return }
        guard running else { startVM(thenConnect: true); return }
        begin("Waiting for Windows…")
        background({ () -> (String?, RDP.Readiness) in
            // The VM may have been started from UTM moments ago, so give its guest agent time to answer.
            let host = Connection.resolveHost(vm: vm, timeout: 120)
            return (host, host == nil ? .notReady : Connection.waitForRemoteDesktop(vm: vm, timeout: 120))
        }) { [weak self] result in
            guard let self else { return }
            let (host, readiness) = result
            self.end()
            guard let host else {
                self.fail("Winbar doesn't know \(vm)'s Remote Desktop address",
                          "Windows' guest agent didn't answer, so Winbar couldn't ask for its name. Try again once Windows "
                              + "has booted, or set it with “winbar config --host <name>” in Terminal.")
                return
            }
            if readiness == .notReady {
                self.fail("\(vm) isn't accepting Remote Desktop yet",
                          "The VM is running but port 3389 on \(host) didn't answer within two minutes.")
            } else {
                self.openRemoteDesktop(host: host)
            }
        }
    }

    @objc private func start() { startVM(thenConnect: false) }

    private func startVM(thenConnect: Bool) {
        guard let vm = vmName else { return }
        begin("Starting…")
        background({ () -> Result<RDP.Readiness, WinbarError> in
            switch UTM.start(vm) {
            case .failure(let error): return .failure(error)
            case .success:
                self.step("Waiting for Windows…")
                return .success(Connection.waitForRemoteDesktop(vm: vm, timeout: 180))
            }
        }) { [weak self] result in
            guard let self else { return }
            self.end()
            switch result {
            case .failure(let error):
                self.fail(error.title, error.detail)
            case .success(.notReady):
                self.fail("\(vm) started, but Remote Desktop never came up",
                          "Nothing answered on port 3389 within three minutes.")
            case .success(let readiness):
                self.rdpReady = readiness
                self.render()
                if thenConnect { self.connect() }
            }
        }
    }

    @objc private func shutDown() { stopVM(force: false, then: nil) }

    @objc private func forceStop() {
        guard let vm = vmName,
              confirm("Force stop \(vm)?", "This is like pulling the power cord. Anything unsaved in Windows is lost.",
                      button: "Force Stop") else { return }
        stopVM(force: true, then: nil)
    }

    @objc private func restart() {
        stopVM(force: false) { [weak self] in self?.startVM(thenConnect: false) }
    }

    private func stopVM(force: Bool, then next: (() -> Void)?) {
        guard let vm = vmName else { return }
        begin(force ? "Force stopping…" : "Shutting down…")
        background({
            force ? UTM.stop(vm, force: true) : UTM.shutDown(vm, offerForce: self.offerForceStop)
        }) { [weak self] result in
            guard let self else { return }
            self.end()
            switch result {
            case .failure(let error): self.fail(error.title, error.detail)
            case .success: next?()
            }
        }
    }

    @objc private func toggleConsole() {
        guard let vm = vmName else { return }
        let showing = consoleEnabled
        guard confirm(showing ? "Switch \(vm) to headless?" : "Show \(vm)'s console window?",
                      "This restarts \(vm) and UTM. " + (showing
                        ? "Afterwards it's reachable only over Remote Desktop, and uses far less power."
                        : "Useful for boot menus or when Remote Desktop won't connect. It costs about a CPU core while visible."),
                      button: "Restart") else { return }
        begin(showing ? "Going headless…" : "Enabling console…")
        let interaction = Interaction(
            progress: { [weak self] in self?.step($0) },
            confirmUnverifiedBitLocker: { [weak self] reason in
                onMain { self?.confirm("Winbar couldn't check BitLocker", reason, button: "Continue") ?? false }
            },
            offerForceStop: offerForceStop)
        background({ () -> (Result<ConfigChanges, WinbarError>, SharedFolder.Checked?) in
            let result = Reconfigure.apply(ConfigChanges(display: showing ? .headless : .console), to: vm, interaction)
            // A display change restarts UTM, which kills a shared folder set by script. Reconfigure
            // wrote it again on the way through; this is where Windows is asked whether it took.
            guard case .success(let done) = result, let folder = done.sharedFolder else { return (result, nil) }
            return (result, try? SharedFolder.settle(folder, vm: vm, user: Config.rdpUser, interaction).get())
        }) { [weak self] result in
            guard let self else { return }
            self.end()
            switch result.0 {
            case .failure(let error):
                self.fail("Couldn't change \(vm)'s display: \(error.title)", error.detail)
                return
            case .success(let done) where done.display == nil:
                // The menu's idea of the display was stale; Reconfigure has corrected it from UTM.
                self.inform(showing ? "\(vm) is already headless" : "\(vm)'s console window is already on",
                            "UTM says its display was already that way, so it wasn't changed.")
            case .success:
                break
            }
            // Silent when the folder came back: the display change is what was asked for. Said when
            // it didn't, because the alternative is a dead Z: and no message.
            guard let checked = result.1, checked.verification != .live else { return }
            self.inform("\(vm)'s shared folder is empty in Windows now",
                        SharedFolder.diedWhenUTMRestarted + " Choose the folder again from this menu, or run winbar "
                            + "share in Terminal. " + SharedFolder.durableAdvice)
        }
    }

    // MARK: The shared folder

    /// The folder Winbar last saw UTM sharing, if it's still there. A folder that has been deleted
    /// or moved counts as none, so the menu offers to choose one instead of opening nothing.
    private var sharedFolderOnDisk: String? {
        guard let path = Config.sharedFolder, SharedFolder.inspect(path) == .folder else { return nil }
        return path
    }

    /// One item for both jobs: show me the folder, or let me pick one.
    @objc private func openOrChooseSharedFolder() {
        guard let vm = vmName else { return }
        if let path = sharedFolderOnDisk {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Share"
        panel.message = "Choose a folder for \(vm) to share with Windows."
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = SharedFolder.trimmingSlash(url.path)
        let name = SharedFolder.abbreviate(path)
        // A space in the path makes a drive Windows can read nothing from, so it is refused here
        // rather than set and left broken.
        if let refusal = SharedFolder.refusal(path) {
            fail(refusal.title, refusal.detail)
            return
        }
        // UTM hands a shared folder to Windows only when it was set while the VM was off, and only a
        // start after that. Said plainly, and only done after a yes.
        let worth = "Windows sees it as the \(SharedFolder.defaultDrive) drive. " + SharedFolder.worthKnowing
        guard confirm("Share “\(name)” with \(vm)?",
                      running ? SharedFolder.restartCost + "\n\n" + worth
                              : "\(vm) is off, so nothing restarts now; Windows picks it up over the next start or two. " + worth,
                      button: running ? "Restart" : "Share") else { return }
        begin("Sharing \(name)…")
        let interaction = Interaction(
            progress: { [weak self] in self?.step($0) },
            confirmUnverifiedBitLocker: { [weak self] reason in
                onMain { self?.confirm("Winbar couldn't check BitLocker", reason, button: "Continue") ?? false }
            },
            offerForceStop: offerForceStop)
        background({ () -> Result<SharedFolder.Checked, WinbarError> in
            // The change, then whatever else it takes for Windows to really have it.
            Reconfigure.apply(ConfigChanges(sharedFolder: .folder(path)), to: vm, interaction)
                .flatMap { _ in SharedFolder.settle(.folder(path), vm: vm, user: Config.rdpUser, interaction) }
        }) { [weak self] result in
            guard let self else { return }
            self.end()
            switch result {
            case .failure(let error):
                self.fail("Couldn't share \(name) with \(vm): \(error.title)", error.detail)
            case .success(let checked):
                switch checked.verification {
                case .live:
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                    // A drive letter belongs to a logon session: theirs can still be a dead handle.
                    if let view = checked.view, SharedFolder.driveState(view).needsMapping {
                        self.inform("\(vm) shares \(name), but its Windows drive letter is stale",
                                    "The folder itself works. The drive letter in your Windows session lists nothing "
                                        + "even after being mapped again — signing out of Windows and back in makes it afresh.")
                    }
                case .stale:
                    self.fail("\(vm) is set to share \(name), but Windows hasn't got it yet",
                              "Windows is given the folder UTM held at the start before this one. Restart \(vm) once more "
                                  + "and it appears.")
                case .unknown(let why):
                    self.inform("\(vm) is set to share \(name)",
                                "Winbar couldn't check from inside Windows (\(why)). It appears over the next start or two.")
                }
            }
        }
    }

    /// Asked from a background step when a graceful shutdown is taking long. Return keeps waiting:
    /// the likeliest cause is Windows installing updates, and powering off then can damage it.
    private func offerForceStop(_ why: String) -> UTM.ForceStopChoice {
        onMain {
            let alert = NSAlert()
            alert.messageText = "Windows is still shutting down"
            alert.informativeText = why
            alert.addButton(withTitle: "Keep Waiting")
            let force = alert.addButton(withTitle: "Force Stop")
            force.keyEquivalent = ""
            force.hasDestructiveAction = true
            alert.addButton(withTitle: "Cancel")   // "Cancel" gets Escape: stop waiting, force nothing
            NSApp.activate(ignoringOtherApps: true)
            switch alert.runModal() {
            case .alertFirstButtonReturn: return .keepWaiting
            case .alertSecondButtonReturn: return .forceStop
            default: return .giveUp
            }
        }
    }

    @objc private func openUTM() { UTM.open() }

    /// The update item. Homebrew put this copy here, so Homebrew should take it away again: its
    /// owner gets the command on the clipboard rather than a page offering a disk image that would
    /// leave them with two Winbars. Everyone else gets the release page, notes and all.
    @objc private func showUpdate() {
        guard UpdateCheck.isHomebrewInstall else {
            NSWorkspace.shared.open(UpdateCheck.releasesURL)
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(UpdateCheck.brewCommand, forType: .string)
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            fail("Couldn't change Launch at Login", error.localizedDescription)
        }
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    /// Quitting in the middle of an operation can leave the VM off, or half way through a
    /// configuration change, so it's asked about first.
    ///
    /// An install is different: Windows keeps going inside the VM whatever Winbar does, so the
    /// warning is about the last steps only. It isn't asked when the CLI holds the job,
    /// because quitting the app doesn't touch it.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let install, CreateWindowController.ownsJob {
            let quit = confirm("Windows is still installing",
                               "If you quit, Windows keeps installing in “\(install.plan.vmName)”, but the last steps "
                                   + "(removing the install disks and checking the result) wait until you open Winbar again.",
                               button: "Quit Anyway")
            guard quit else { return .terminateCancel }
        }
        guard let activity else { return .terminateNow }
        let quit = confirm("Quit while Winbar is busy?",
                           "Winbar is still working (\(activity)). Quitting now leaves that unfinished.", button: "Quit")
        return quit ? .terminateNow : .terminateCancel
    }

    private func openRemoteDesktop(host: String) {
        guard WindowsApp.accessibilityTrusted else {
            if offerAccessibilityOnce(host: host) { return }  // they're off granting it; Connect again afterwards
            openOneOffConnection(host: host)
            return
        }
        background({ WindowsApp.openSavedPC(host: host) }) { [weak self] opened in
            if !opened {
                NSLog("Winbar: falling back to a one-off .rdp connection")
                self?.openOneOffConnection(host: host)
            }
        }
    }

    /// Fallback: works without Accessibility, but Windows App asks for the password.
    private func openOneOffConnection(host: String) {
        if !RDP.openOneOff(host: host, user: Config.rdpUser) {
            fail("Couldn't open Windows App",
                 "Run winbar setup in Terminal and it offers to install Windows App for you, or get it from the Mac App "
                     + "Store. Then try Connect again.")
        }
    }

    /// Returns true if the user chose to go and grant Accessibility.
    private func offerAccessibilityOnce(host: String) -> Bool {
        guard !Config.offeredAccessibility else { return false }
        Config.offeredAccessibility = true
        let grant = confirm("Connect without the password prompt or chooser?",
                            "Winbar can open your saved \(host) PC in Windows App directly, so it uses the saved password "
                            + "and never shows the chooser window. That needs Accessibility access for Winbar.\n\n"
                            + "Grant it in System Settings, then choose Connect again.",
                            button: "Open Accessibility Settings")
        if grant { WindowsApp.requestAccessibility() }
        return grant
    }

    // MARK: Alerts

    private func fail(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func inform(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = detail
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func confirm(_ title: String, _ detail: String, button: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}
