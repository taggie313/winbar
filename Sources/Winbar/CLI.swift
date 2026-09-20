import Foundation

/// The `winbar` command line. Same binary as the menu bar app; see main.swift for how it decides.
enum CLI {
    static let commands: Set<String> = ["doctor", "setup", "create", "display", "share", "start", "stop", "restart",
                                        "connect", "config", "help"]
    static let flags: Set<String> = ["--self-test", "--version", "-h", "--help"]

    enum Mode: Equatable {
        case cli
        case help
        case unknownCommand(String)
        case app
    }

    /// The dual-mode rule, applied to `normalized` arguments. A known subcommand or flag runs the CLI;
    /// no arguments on a terminal prints help (someone typed `winbar`); no arguments otherwise starts
    /// the menu bar app, which is how LaunchServices runs it.
    ///
    /// Anything else is a mistake typed at a shell (`winbar statsu`, `winbar -v`, `winbar --vm X
    /// doctor`), and gets an error instead of a second menu bar app holding the terminal's privacy
    /// grants. Only an unknown option with LaunchServices as the parent and no terminal attached is
    /// left to the app, in case LaunchServices passes something new.
    static func mode(arguments: [String], stdoutIsTTY: Bool, launchedByLaunchServices: Bool) -> Mode {
        guard let first = arguments.first else { return stdoutIsTTY ? .help : .app }
        if commands.contains(first) || flags.contains(first) { return .cli }
        let optionLike = first.hasPrefix("-") || first.hasPrefix("/")
        if optionLike && launchedByLaunchServices && !stdoutIsTTY { return .app }
        return .unknownCommand(first)
    }

    /// Drops what LaunchServices and AppKit add on their own: `-psn_…` (no value), and `-NS…` /
    /// `-Apple…` defaults overrides with the value after each. Then `--self-test` or `connect` is found
    /// even if something was put in front of it.
    static func normalized(_ arguments: [String]) -> [String] {
        var kept: [String] = []
        var i = 0
        while i < arguments.count {
            let argument = arguments[i]
            if argument.hasPrefix("-psn_") {
                i += 1
            } else if argument.hasPrefix("-NS") || argument.hasPrefix("-Apple") {
                i += 2
            } else {
                kept.append(argument)
                i += 1
            }
        }
        return kept
    }

    static let usage = """
        usage: winbar <command> [options]

        Winbar runs a UTM Windows VM headless and connects to it over Remote Desktop.
        With no command it's the menu bar app (open Winbar.app).

        commands:
          setup [--vm NAME] [--yes] [--no-visual-tweaks] [--keep-bitlocker] [--headless | --console]
                        check everything, fix what can be fixed, walk through the rest
                        --yes answers the y/N questions yes; it never types passwords for you,
                        never decrypts BitLocker unless it sees the VM's disk on an encrypted
                        volume, and never goes headless unasked. --no-visual-tweaks and
                        --keep-bitlocker are remembered for the VM (undo with winbar config)
          create [NAME] [--iso PATH] [options]
                        make a new UTM VM and install Windows 11 in it, unattended (about 10 minutes).
                        Shows the plan as a checklist you can change, then asks for the Windows
                        password (never a flag). winbar create --help lists every option
          doctor [--vm NAME]
                        check everything and explain; exits 0 only when all is well
          start         start the VM and wait for Remote Desktop
          stop [--force]
                        shut Windows down cleanly (--force: pull the plug)
          restart       shut down cleanly, then start
          display on|off
                        show the UTM console window, or run headless (restarts the VM)
          share [FOLDER | --off]
                        show the folder this VM shares with Windows, share one (offering
                        to create it), or stop sharing. A change needs the VM to restart —
                        sometimes twice, which Winbar checks for — and the folder's path
                        must have no spaces in it
          connect       open the VM in Windows App, starting it if needed
          config [--vm NAME] [--host HOST] [--user USER] [--saved-pc NAME]
                 [--keep-bitlocker yes|no] [--no-visual-tweaks yes|no] [--autologon yes|no]
                 [--remote-desktop yes|no] [--winbar-tuning yes|no]
                        show settings, or change them ("" resets one to its default). The last
                        three are what winbar create's checklist asked: "no" keeps setup from
                        offering them again
          help          this text

        flags:
          --version [--check]
                        print the version; --check also asks GitHub whether there is a newer
                        release (the app does this by itself, once a day)
          --self-test   print what the menu bar app sees (run as the app: doctor does this)
        """

    static func run(_ arguments: [String]) -> Int32 {
        guard let command = arguments.first else { print(usage); return 0 }
        let rest = Array(arguments.dropFirst())
        switch command {
        case "--version":
            print("winbar \(AppBundle.version)")
            // The menu bar app checks for a newer release by itself, once a day and silently. This
            // is the same check asked for on purpose, so it waits for the answer and says when
            // there isn't one.
            if rest.contains("--check") { return UpdateCheck.report() }
            return 0
        case "help", "-h", "--help":
            print(usage)
            return 0
        case "--self-test":
            return SelfTest.run(requestAccessibility: rest.contains("--request-accessibility"))
        case "doctor":
            return withOptions(rest, values: ["--vm"], switches: []) { parsed in
                Doctor.run(options: Context.Options(vmOverride: parsed.values["--vm"]))
            }
        case "setup":
            return withOptions(rest, values: ["--vm"],
                               switches: ["--yes", "-y", "--no-visual-tweaks", "--keep-bitlocker", "--headless", "--console"]) { parsed in
                if parsed.has("--headless") && parsed.has("--console") {
                    Term.error("winbar setup: --headless and --console contradict each other")
                    return 64
                }
                var options = Context.Options(vmOverride: parsed.values["--vm"])
                options.assumeYes = parsed.has("--yes") || parsed.has("-y")
                options.noVisualTweaks = parsed.has("--no-visual-tweaks")
                options.keepBitLocker = parsed.has("--keep-bitlocker")
                options.display = parsed.has("--headless") ? .headless : parsed.has("--console") ? .console : nil
                return Setup.run(options: options)
            }
        case "create":
            // create parses its own arguments: it has more flags than `withOptions` handles, and
            // every refusal has its own message and exit code.
            return CreateCLI.run(rest)
        case "start":
            return withOptions(rest, values: [], switches: []) { _ in withVM(start) }
        case "stop":
            return withOptions(rest, values: [], switches: ["--force"]) { parsed in withVM { stop($0, force: parsed.has("--force")) } }
        case "restart":
            return withOptions(rest, values: [], switches: []) { _ in withVM(restart) }
        case "display":
            return withOptions(rest, values: [], switches: []) { parsed in
                guard parsed.positionals.count == 1, let mode = ["on": UTMScripting.DisplayMode.console, "off": .headless][parsed.positionals[0]] else {
                    Term.error("usage: winbar display on|off")
                    return 64
                }
                return withVM { display($0, mode) }
            }
        case "share":
            return withOptions(rest, values: [], switches: ["--off"]) { parsed in
                guard parsed.positionals.count <= 1, !(parsed.has("--off") && !parsed.positionals.isEmpty) else {
                    Term.error("usage: winbar share [FOLDER | --off]")
                    return 64
                }
                return withVM { share($0, folder: parsed.positionals.first, off: parsed.has("--off")) }
            }
        case "connect":
            // --parent-pid is internal: the shell's winbar passes it to the app instance it relaunches.
            return withOptions(rest, values: ["--parent-pid"], switches: []) { parsed in
                let parent = parsed.values["--parent-pid"].flatMap { Int32($0) }
                return withVM { connect($0, parent: parent) }
            }
        case "config":
            return withOptions(rest, values: ["--vm", "--host", "--user", "--saved-pc", "--keep-bitlocker",
                                              "--no-visual-tweaks", "--autologon", "--remote-desktop",
                                              "--winbar-tuning"],
                               switches: []) { parsed in config(parsed) }
        default:
            Term.error("winbar: unknown command '\(command)'")
            Term.error(usage)
            return 64
        }
    }

    // MARK: Arguments

    struct Parsed {
        var positionals: [String] = []
        var values: [String: String] = [:]
        var switches: Set<String> = []
        func has(_ flag: String) -> Bool { switches.contains(flag) }
    }

    /// `--flag value`, `--flag=value` and bare switches. Anything else starting with `-` is an error.
    static func parse(_ arguments: [String], values: Set<String>, switches: Set<String>) -> Result<Parsed, WinbarError> {
        var parsed = Parsed()
        var i = 0
        while i < arguments.count {
            let argument = arguments[i]
            i += 1
            if let eq = argument.firstIndex(of: "="), argument.hasPrefix("--"), values.contains(String(argument[..<eq])) {
                parsed.values[String(argument[..<eq])] = String(argument[argument.index(after: eq)...])
            } else if values.contains(argument) {
                guard i < arguments.count else { return .failure(WinbarError("\(argument) needs a value")) }
                parsed.values[argument] = arguments[i]
                i += 1
            } else if switches.contains(argument) {
                parsed.switches.insert(argument)
            } else if argument.hasPrefix("-") && argument != "-" {
                return .failure(WinbarError("unknown option \(argument)"))
            } else {
                parsed.positionals.append(argument)
            }
        }
        return .success(parsed)
    }

    private static func withOptions(_ arguments: [String], values: Set<String>, switches: Set<String>,
                                    _ body: (Parsed) -> Int32) -> Int32 {
        switch parse(arguments, values: values, switches: switches) {
        case .failure(let error):
            Term.error("winbar: \(error)")
            return 64
        case .success(let parsed):
            return body(parsed)
        }
    }

    private static func withVM(_ body: (String) -> Int32) -> Int32 {
        guard UTM.isInstalled else {
            Term.error("UTM isn't installed: brew install --cask utm")
            return 1
        }
        guard let vm = Config.vmName else {
            Term.error("No VM chosen yet. Run winbar setup (or winbar config --vm <name>).")
            return 1
        }
        return body(vm)
    }

    // MARK: VM commands

    private static var terminalInteraction: Interaction {
        Interaction(
            progress: { Term.note($0) },
            confirmUnverifiedBitLocker: { reason in
                print(reason)
                return Term.confirm("Carry on anyway?", assumeYes: false)
            },
            offerForceStop: Interaction.askForceStopAtTerminal)
    }

    private static func start(_ vm: String) -> Int32 {
        if VMProcesses.isRunning(vm) {
            print("\(vm) is already running.")
            return 0
        }
        Term.note("Starting \(vm)…")
        if case .failure(let error) = UTM.start(vm) {
            Term.error("\(error)")
            return 1
        }
        Term.note("Waiting for Remote Desktop…")
        switch Connection.waitForRemoteDesktop(vm: vm, timeout: 180) {
        case .ready: print("\(vm) is running and ready for Remote Desktop.")
        case .blocked: print("\(vm) is running. (macOS Local Network privacy kept this terminal from checking Remote Desktop.)")
        case .notReady: print("\(vm) is running, but Remote Desktop didn't answer within three minutes.")
        }
        return 0
    }

    private static func stop(_ vm: String, force: Bool) -> Int32 {
        guard VMProcesses.isRunning(vm) else {
            print("\(vm) isn't running.")
            return 0
        }
        if force { Term.note("Force stopping \(vm): anything unsaved in Windows is lost.") } else { Term.note("Shutting down \(vm)…") }
        let result = force ? UTM.stop(vm, force: true) : UTM.shutDown(vm, offerForce: Interaction.askForceStopAtTerminal)
        if case .failure(let error) = result {
            Term.error("\(error)")
            return 1
        }
        print("\(vm) is off.")
        return 0
    }

    private static func restart(_ vm: String) -> Int32 {
        if VMProcesses.isRunning(vm) {
            let code = stop(vm, force: false)
            guard code == 0 else { return code }
        }
        return start(vm)
    }

    /// Reconfigure asks UTM what the display is now and does nothing when it already matches (except
    /// finishing a UTM restart an earlier, interrupted display change still owes).
    private static func display(_ vm: String, _ mode: UTMScripting.DisplayMode) -> Int32 {
        if let process = VMProcesses.find(vm), process.headless != (mode == .headless) { print("This restarts \(vm).") }
        switch Reconfigure.apply(ConfigChanges(display: mode), to: vm, terminalInteraction) {
        case .failure(let error):
            Term.error("\(error)")
            return 1
        case .success(let done) where done.display == nil:
            print(mode == .headless ? "\(vm) is already headless." : "\(vm)'s console window is already on.")
            return 0
        case .success:
            print(mode == .headless ? "\(vm) is headless: reach it with winbar connect." : "\(vm)'s console window is on.")
            return 0
        }
    }

    // MARK: share

    /// With nothing to do, reports what is shared and how Windows reaches it. With a folder (or
    /// --off) it changes it — which UTM only passes on when it is set while the VM is off, and which
    /// Windows only sees a start later still, so the restart is explained and asked for, the second
    /// one is done only when Windows proves it needs it, and nothing is called done unchecked.
    private static func share(_ vm: String, folder typed: String?, off: Bool) -> Int32 {
        let current: String?
        switch SharedFolder.current(vm: vm) {
        case .failure(let error):
            Term.error("\(error)")
            return 1
        case .success(let path):
            Config.rememberSharedFolder(path, for: vm)
            current = path
        }
        guard off || typed != nil else { return showShare(vm, current) }

        var wanted = SharedFolder.Setting.off
        if let typed {
            let path = SharedFolder.resolve(typed)
            guard !path.isEmpty else {
                Term.error("usage: winbar share [FOLDER | --off]")
                return 64
            }
            // Before anything else: a path with a space in it makes a drive Windows can read nothing
            // from and write nothing to, so it is refused rather than set.
            if let refusal = SharedFolder.refusal(path) {
                Term.error("\(refusal)")
                return 1
            }
            switch SharedFolder.inspect(path) {
            case .notAFolder:
                Term.error("\(SharedFolder.abbreviate(path)) is a file, not a folder.")
                return 1
            case .missing:
                guard Term.confirm("\(SharedFolder.abbreviate(path)) doesn't exist. Create it?", assumeYes: false, defaultYes: true) else {
                    print("Nothing changed.")
                    return 1
                }
                if case .failure(let error) = SharedFolder.create(path) {
                    Term.error("\(error)")
                    return 1
                }
                print("Created \(SharedFolder.abbreviate(path)).")
            case .folder:
                break
            }
            wanted = .folder(path)
        }
        let name = wanted.path.map { SharedFolder.abbreviate($0) }

        switch SharedFolder.decide(current: current, wanted: wanted, running: VMProcesses.isRunning(vm)) {
        case .alreadySet:
            print(name.map { "\(vm) already shares \($0)." } ?? "\(vm) already shares nothing with Windows.")
            // UTM's registry is not proof that Windows has it — Windows is given the folder from the
            // start before — so ask, and offer the restart that would fix it.
            guard reportWindowsView(vm, current) == .stale else { return 0 }
            guard Term.confirm("Restart \(vm) now so Windows gets it?", assumeYes: false, defaultYes: true) else {
                print("Left as it is. Run winbar restart, then winbar share, when \(vm) can restart.")
                return 1
            }
            return finishShare(vm, wanted, name: name)
        case .needsRestart:
            print("\(vm) is running. " + SharedFolder.restartCost)
            guard Term.confirm("Restart \(vm) now?", assumeYes: false, defaultYes: true) else {
                print("Nothing changed. Run this again when \(vm) can restart, or shut it down first.")
                return 1
            }
        case .setNow:
            break
        }

        if case .failure(let error) = Reconfigure.apply(ConfigChanges(sharedFolder: wanted), to: vm, terminalInteraction) {
            Term.error("\(error)")
            return 1
        }
        guard VMProcesses.isRunning(vm) else {
            // It was off and stays off, so there is nobody to ask. The lag is still worth saying.
            print(name.map { "UTM will share \($0) with \(vm)." } ?? "UTM will share nothing with \(vm).")
            print("Windows is given the folder UTM held at the start before, so it may take two starts. "
                  + "Run winbar share once it's up and Winbar will check and finish the job.")
            return 0
        }
        return finishShare(vm, wanted, name: name)
    }

    /// Waits for Windows, checks whether it really has the folder, and gives it the second start UTM
    /// needs if it hasn't (see `SharedFolder.settle`). Both the change and the "UTM has it, Windows
    /// doesn't" path end here, and neither says it is done without having looked.
    private static func finishShare(_ vm: String, _ wanted: SharedFolder.Setting, name: String?) -> Int32 {
        switch SharedFolder.settle(wanted, vm: vm, user: Config.rdpUser, terminalInteraction) {
        case .failure(let error):
            Term.error("\(error)")
            return 1
        case .success(let checked):
            switch checked.verification {
            case .live:
                guard let name else {
                    print("\(vm) shares nothing with Windows now.")
                    return 0
                }
                print("\(vm) shares \(name), and Windows has it: \(checked.drive ?? SharedFolder.defaultDrive). "
                      + SharedFolder.worthKnowing)
                return 0
            case .stale:
                Term.error("UTM has the change, but Windows is still serving what it had before. "
                           + "Restart \(vm) once more (winbar restart), then run winbar share to check.")
                return 1
            case .unknown(let why):
                print("UTM has the change, but Winbar couldn't check it from inside Windows (\(why)). "
                      + "Run winbar share once Windows is up.")
                return 0
            }
        }
    }

    /// `winbar share` on its own: what UTM shares, and what Windows says about it when it's up.
    private static func showShare(_ vm: String, _ current: String?) -> Int32 {
        guard let current else {
            print("\(vm) shares nothing with Windows.")
            print("Share a folder:  winbar share ~/\(SharedFolder.defaultFolderName)")
            return 0
        }
        print("\(vm) shares \(SharedFolder.abbreviate(current)).")
        if SharedFolder.inspect(current) != .folder {
            print("That folder isn't on this Mac any more. Share another one, or winbar share --off.")
        } else if let refusal = SharedFolder.refusal(current) {
            print("\(refusal)")
        }
        reportWindowsView(vm, current)
        return 0
    }

    /// The Windows half of the report, shared by `share` and `showShare`. Silent when the VM is off:
    /// there is nothing to ask. It proves what Windows is serving rather than trusting the mapping —
    /// a drive can be mounted and still be the folder from the start before (see `SharedFolder`).
    @discardableResult
    private static func reportWindowsView(_ vm: String, _ current: String?) -> SharedFolder.Verification? {
        guard VMProcesses.isRunning(vm) else {
            print("Windows sees it as a drive (\(SharedFolder.defaultDrive) unless you changed it) while \(vm) runs.")
            return nil
        }
        Term.note("Asking Windows…")
        let setting: SharedFolder.Setting = current.map { .folder($0) } ?? .off
        let checked: SharedFolder.Checked
        switch SharedFolder.verify(setting, vm: vm, user: Config.rdpUser) {
        case .failure(let error):
            print("Windows didn't answer, so how it sees the folder is unknown: \(error)")
            return nil
        case .success(let answer):
            checked = answer
        }
        guard let view = checked.view else {
            if case .unknown(let why) = checked.verification { print("Winbar couldn't check inside Windows (\(why)).") }
            return checked.verification
        }
        if !view.webdavdRunning {
            print("Windows can't reach it: spice-webdavd isn't running (\(view.webdavd)). It comes with UTM Guest Tools.")
        } else if !view.webClientRunning {
            print("Windows can't reach it: its WebClient service isn't running (\(view.webClient)). WebDAV drives need it.")
        } else {
            switch checked.verification {
            case .live where current == nil:
                print("Windows has no shared folder: it shows UTM's placeholder.")
            case .live:
                if let drive = view.drive {
                    print("Windows sees it as \(drive) (\(view.remotePath ?? SharedFolder.defaultRemotePath)).")
                } else {
                    print("Windows has it, but no drive letter is mapped. winbar setup maps \(SharedFolder.defaultDrive) for you.")
                }
            case .stale:
                print("Windows is still serving what it had at the start before this one"
                      + (view.drive.map { " (\($0))" } ?? "") + ". Restart \(vm) (winbar restart) and this folder appears.")
            case .unknown(let why):
                print("Windows has a drive for it\(view.drive.map { " (\($0))" } ?? ""), but Winbar couldn't confirm it is "
                      + "this folder: \(why).")
            }
        }
        if let error = view.error { print("Windows also said: \(error)") }
        return checked.verification
    }

    /// Connect needs Winbar's own Accessibility grant (to press the saved PC) and its Local Network
    /// grant (for the readiness probe). From a shell this process would be using Terminal's, so it
    /// relaunches itself as the app through LaunchServices and relays what that instance prints.
    ///
    /// That instance's parent is launchd, so Ctrl-C here can't reach it. It's given this process's pid
    /// instead, and gives up (without opening anything) once that process is gone.
    private static func connect(_ vm: String, parent: pid_t?) -> Int32 {
        if !AppBundle.launchedByLaunchServices, AppBundle.url != nil {
            Term.note("Connecting to \(vm) through Winbar.app (Ctrl-C cancels)…")
            // Connect can include starting the VM and waiting for Windows, hence the long timeout.
            let run = AppBundle.runAsApp(["connect", "--parent-pid", String(getpid())], endMarker: "result:", timeout: 600,
                                         relay: { line in if !line.hasPrefix("result:") { print(line) } }, interruptible: true)
            switch run {
            case .finished(let text)?:
                return text.contains("result: ok") ? 0 : 1
            case .interrupted?:
                Term.error("Cancelled.")
                return 130
            case .timedOut?:
                Term.error("Winbar.app didn't finish connecting within 10 minutes.")
                return 1
            case nil:
                Term.error("Couldn't launch Winbar.app to connect.")
                return 1
            }
        }
        let cancelled = { parent.map(AppBundle.processGone) ?? false }
        let code = connectHere(vm, cancelled: cancelled)
        print("result: \(code == 0 ? "ok" : "failed")")
        return code
    }

    /// Waits for Remote Desktop before asking Windows for its host name: the port answering means
    /// Windows is up, and the name needs its guest agent, which starts later than QEMU.
    private static func connectHere(_ vm: String, cancelled: () -> Bool) -> Int32 {
        let stop = "Cancelled: the winbar command that asked for this connection has ended."
        if !VMProcesses.isRunning(vm) {
            guard !cancelled() else { print(stop); return 130 }
            print("Starting \(vm)…")
            if case .failure(let error) = UTM.start(vm) {
                print("\(error)")
                return 1
            }
        }
        print("Waiting for Remote Desktop…")
        let readiness = Connection.waitForRemoteDesktop(vm: vm, timeout: 180, cancelled: cancelled)
        guard !cancelled() else { print(stop); return 130 }
        guard readiness != .notReady else {
            print("\(vm) is running, but Remote Desktop didn't answer within three minutes.")
            return 1
        }
        guard let host = Connection.resolveHost(vm: vm, timeout: 120) else {
            print("Winbar doesn't know \(vm)'s Remote Desktop host yet, and Windows' guest agent didn't answer to tell it. "
                  + "Try again once Windows has booted, or set it with winbar config --host <name>.")
            return 1
        }
        guard !cancelled() else { print(stop); return 130 }
        if WindowsApp.accessibilityTrusted {
            if WindowsApp.openSavedPC(host: host) {
                print("Opened the saved PC in Windows App.")
                return 0
            }
            print("No saved PC for \(host) in Windows App, so opening a one-off connection (it asks for the password).")
        } else {
            print("Winbar has no Accessibility access, so opening a one-off connection (it asks for the password). winbar setup explains.")
        }
        guard RDP.openOneOff(host: host, user: Config.rdpUser) else {
            print("Couldn't open Windows App. Install it: brew install --cask windows-app")
            return 1
        }
        return 0
    }

    // MARK: config

    private static func config(_ parsed: Parsed) -> Int32 {
        guard parsed.positionals.isEmpty else {
            Term.error("usage: winbar config [--vm NAME] [--host HOST] [--user USER] [--saved-pc NAME] "
                       + "[--keep-bitlocker yes|no] [--no-visual-tweaks yes|no] [--autologon yes|no] "
                       + "[--remote-desktop yes|no] [--winbar-tuning yes|no]")
            return 64
        }
        if let host = parsed.values["--host"], !host.isEmpty, !Config.isValidHostName(host) {
            Term.error("winbar config: '\(host)' isn't a plain host name (letters, digits, dots and hyphens)")
            return 64
        }
        var switches: [String: Bool] = [:]
        for option in ["--keep-bitlocker", "--no-visual-tweaks", "--autologon", "--remote-desktop",
                       "--winbar-tuning"] {
            guard let value = parsed.values[option] else { continue }
            guard let on = Config.parseSwitch(value) else {
                Term.error("winbar config: \(option) takes yes or no")
                return 64
            }
            switches[option] = on
        }
        if let vm = parsed.values["--vm"] {
            if vm.isEmpty {
                Config.vmName = nil
            } else {
                let cleared = Config.selectVM(vm)
                if !cleared.isEmpty { print("Forgot what was remembered about the previous VM: \(cleared.joined(separator: ", ")).") }
            }
        }
        if let host = parsed.values["--host"] { Config.rdpHost = host }
        if let user = parsed.values["--user"] { Config.rdpUser = user }
        if let name = parsed.values["--saved-pc"] { Config.savedPCName = name }
        // After --vm: switching VMs forgets these, and they belong to the VM being chosen.
        if let on = switches["--keep-bitlocker"] { Config.keepBitLocker = on }
        if let on = switches["--no-visual-tweaks"] { Config.noVisualTweaks = on }
        // The three create's checklist can turn off: "no" is what setup reports as off by choice.
        if let on = switches["--autologon"] { Config.declinedAutologon = !on }
        if let on = switches["--remote-desktop"] { Config.declinedRemoteDesktop = !on }
        if let on = switches["--winbar-tuning"] { Config.declinedTuning = !on }

        let host = Config.rdpHost
        let rows: [(String, String)] = [
            ("vmName", Config.vmName ?? "(none: run winbar setup)"),
            ("rdpHost", host ?? "(default: the Windows computer name + .local, found by setup)"),
            ("rdpUser", Config.rdpUser ?? "(default: the signed-in Windows user, found by setup)"),
            ("savedPCName", Config.savedPCName ?? "(default: \(host ?? "rdpHost"))"),
            ("vmMAC", Config.vmMAC ?? "(not seen yet)"),
            ("consoleEnabled", Config.consoleEnabled.map(String.init) ?? "(not seen yet)"),
            ("bitLockerOn", Config.bitLockerOn.map { on in
                String(on) + (Config.bitLockerCheckedAt.map { " (checked \($0.formatted(date: .abbreviated, time: .shortened)))" } ?? "")
            } ?? "(not checked yet)"),
            ("keepBitLocker", Config.keepBitLocker ? "yes" : "no"),
            ("noVisualTweaks", Config.noVisualTweaks ? "yes" : "no"),
            ("autologon", Config.declinedAutologon ? "no (off by choice)" : "yes"),
            ("remoteDesktop", Config.declinedRemoteDesktop ? "no (off by choice)" : "yes"),
            ("winbarTuning", Config.declinedTuning ? "no (off by choice)" : "yes"),
            ("sharedFolder", Config.sharedFolder ?? "(none; winbar share <folder> sets one)"),
            ("savedPCHost", Config.savedPCHost ?? "(not confirmed yet)"),
            ("backupExcluded", Config.backupExclusionConfirmed ? "yes (you confirmed it)" : "(not confirmed)"),
            ("offeredAccessibility", String(Config.offeredAccessibility)),
        ] + (Config.pendingUTMRestart.map { [("utmRestartPending", "yes, after \($0.vm)'s display change")] } ?? [])
        for (key, value) in rows { print(key.padding(toLength: 22, withPad: " ", startingAt: 0) + value) }
        return 0
    }
}
