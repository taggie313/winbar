import Foundation
import Darwin

// `winbar create` at the terminal: the flags, the checklist screen, the hidden password
// prompt, the dry run, the progress lines, Ctrl-C and the endings. The install itself is CreateJob's.
//
// The password is read from /dev/tty with echo off and handed straight to CreateJob.start. It is
// never a flag and never an environment variable, because arguments are visible to every process on
// the Mac and end up in the shell's history, and the environment is handed to every child process.
//
// The optional Windows product key is treated the same way and for the same reasons: --product-key is
// a switch that asks, --product-key-stdin names a pipe, and neither ever takes the key as a value.
// There is deliberately no WINBAR_PRODUCT_KEY environment variable: the environment is handed to every
// program the command starts, and a key that leaked that way would be a licence someone else could use.

/// The copy `winbar create` shows, in the copy deck's words. One deck for both front-ends: the lines
/// below are the ones only Terminal says, and the rest of the deck, which the window shows too, is
/// the extension in CreateForm.swift.
enum CreateCopy {
    static let autologonPlaintext =
        "Windows stored the automatic sign-in password in plain text in the registry, which it doesn't normally do. "
        + "winbar setup's automatic sign-in step shows how to move it to Windows' encrypted store (netplwiz); the "
        + "plain-text value isn't removed for you."

    static let isoKeep = nISOKeep + " UTM reads it from there."

    static let passwordWhyPrompt =
        "The password is never a flag or an environment variable: arguments are visible to every program on your Mac "
        + "while the command runs and end up in your shell history, and environment variables are handed to every "
        + "program the command starts."

    /// The block printed before the password prompt, with its "pick a different password" line. Its
    /// second paragraph quotes the deck's own sentences about the copy inside Windows, so
    /// Terminal and the window describe it in the same words rather than in two that drift.
    ///
    /// N_PW_FILEVAULT_OFF belongs here too, not with the stage-1 notes: it goes where the
    /// password is typed, which is the only place it can still change which password is chosen. The
    /// job raises it as well, for a front-end that didn't say it; `CreateProgressPrinter`'s `said`
    /// leaves it out of the progress lines when this block already has it.
    static func beforePassword(fileVaultOn: Bool?) -> [String] {
        var paragraphs = [
            "Windows Setup needs it in its answer file. Winbar writes it there scrambled (Base64), the way Microsoft's "
            + "tools do: that hides it from a glance but isn't encryption. The answer file sits on a small setup disk in "
            + "Winbar's folder, readable only by you and kept out of Time Machine, until Windows finishes installing; then "
            + "Winbar deletes it. Winbar keeps no other copy. It also saves this PC in Windows App for you, with the same "
            + "user name and password, so Connect works the moment Windows is up: "
            + WindowsAppBookmarks.Copy.passwordGoesToWindowsApp,
            nPWPanther + " " + nPWLSA + " " + nPWNotYours,
            "Windows Setup's licence page is skipped, so creating the VM accepts Microsoft's Windows licence terms: "
            + "https://www.microsoft.com/useterms",
        ]
        if fileVaultOn == false { paragraphs.insert(nPWFileVaultOff, at: 1) }
        return paragraphs
    }

    /// W_HOME_CONFIRM: the edition picker asks it when Home is chosen, and `create` asks it at Enter
    /// for an ISO that has nothing but Home editions.
    static let wHomeConfirm = "Install Home anyway?"

    /// E_HOME_ONLY: `--yes` with no `--edition` on a Home-only ISO. Home is only ever
    /// installed when it was chosen, and `--yes` chooses nothing.
    static let eHomeOnly = "This ISO only has Home editions, and Home can't accept Remote Desktop connections."
    static func eHomeOnlyNext(edition: String) -> String {
        "To install it anyway, name the edition: --edition \"\(edition)\". Or download the ISO again from Microsoft: "
            + "its standard download includes Pro."
    }

    static let automationCLI = "macOS may ask whether {app} can control UTM. Choose Allow: it's how Winbar creates "
        + "and starts the VM."

    static let sleep = "Winbar keeps your Mac awake until Windows is installed."

    static let watch = "You can watch in the VM's window in UTM, but don't click in it or close it.\n"
        + "Ctrl-C stops watching; Windows keeps installing."

    /// N_NEXT_SETUP. The window has its own heading above the command, so it shows the same
    /// things without this line's opening, and without what headless measured.
    static func nextSetup(savedPC: Bool) -> String {
        "Next: winbar setup, about 5 minutes. " + nNextSetupSteps(savedPC: savedPC)
            + " Then it offers to go headless, which cuts idle host CPU by about two thirds."
    }

    /// Refused locked flags: the flag each locked row would turn off, and ChoiceProblem's
    /// words for why it can't.
    static let lockedFlags: [String: String] = Dictionary(uniqueKeysWithValues: CreateOption.allCases
        .filter(\.isLocked)
        .map { ("--no-" + $0.rawValue.replacingOccurrences(of: "_", with: "-"), ChoiceProblem.locked($0).description) })

    /// Why the key gets the password's treatment, in the password's own words. A licence key is worth
    /// something to whoever finds it, and an argument is readable by every process on the Mac.
    static let productKeyWhyPrompt =
        "The product key is never a flag value either, for the same reason: arguments are visible to every program "
        + "on your Mac while the command runs and end up in your shell history. --product-key asks for it with the "
        + "characters hidden, and --product-key-stdin reads it from a pipe."

    /// The block printed before the key prompt. It says the one thing that is different about a product
    /// key: unlike the password, nothing hides it in the answer file.
    static let beforeProductKey =
        "Windows Setup reads it from the same answer file, in plain text: a product key has no scrambled form the "
        + "way the password does. The answer file sits on the setup disk in Winbar's folder, readable only by you "
        + "and kept out of Time Machine, and Winbar deletes it as soon as Windows has finished installing. Winbar "
        + "keeps no other copy, and never logs it. Setup refuses a key that isn't for the edition being installed, "
        + "and the VM still installs either way — just unactivated."

    static let keyStdinTTY = "--product-key-stdin reads the product key from a pipe, but standard input is this "
        + "terminal, where every character would be echoed. Pipe it in, or use --product-key and Winbar "
        + "will ask."
    static let keyStdinEmpty = "Nothing came in on standard input. With --product-key-stdin, pipe the "
        + "Windows product key in, for example: op read op://Private/windows/key | winbar create --yes "
        + "--product-key-stdin"
    static let keyNoTTY = "winbar create needs a terminal to ask for the Windows product key, and never takes it "
        + "from a flag or an environment variable. Run it in Terminal, or pipe the key in with "
        + "--product-key-stdin."

    static let pwStdinTTY = "--password-stdin reads the password from a pipe, but standard input is this "
        + "terminal, where every character would be echoed. Pipe it in, or leave the flag off and Winbar "
        + "will ask."
    static let pwStdinEmpty = "Nothing came in on standard input. With --password-stdin, pipe the "
        + "Windows password in, for example: op read op://Private/winbar/password | winbar create --yes "
        + "--password-stdin"
    static let noTTY = "winbar create needs a terminal to ask for the Windows password, and never takes it from a "
        + "flag or an environment variable. Run it in Terminal, use \(menuNew) in Winbar's menu, or "
        + "winbar create --window."

    static let needISO = "winbar create: --iso PATH is required when there's no terminal to ask."

    /// Wraps prose so that every line holds at most `width` characters of text, and prefixes every
    /// line after the first with `indent`. The caller writes the first line's own prefix, and passes
    /// the width that leaves, so all the lines end in the same column.
    static func wrap(_ text: String, width: Int, indent: String = "") -> String {
        var lines: [String] = []
        for paragraph in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = ""
            for word in paragraph.split(separator: " ") {
                let candidate = line.isEmpty ? String(word) : line + " " + word
                if candidate.count > width, !line.isEmpty {
                    lines.append(line)
                    line = String(word)
                } else {
                    line = candidate
                }
            }
            lines.append(line)
        }
        return lines.enumerated().map { $0.offset == 0 ? $0.element : indent + $0.element }.joined(separator: "\n")
    }

    /// A language tag as a person reads it ("en-US" → "English (United States)").
    static func languageName(_ tag: String) -> String {
        Locale.current.localizedString(forIdentifier: tag) ?? tag
    }

    /// The terminal's width, capped at the 100 columns `winbar help` uses.
    static var width: Int {
        var size = winsize()
        let columns = ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0 && size.ws_col > 20 ? Int(size.ws_col) : 100
        return min(columns, 100)
    }
}

enum CreateCLI {
    // MARK: - Arguments

    struct Options: Equatable {
        var name: String?
        var iso: String?
        var edition: String?
        var cores: Int?
        var memoryGB: Int?
        var diskGB: Int?
        /// Checklist rows the `--no-…` flags turned off.
        var off: Set<CreateOption> = []
        var noVisualTweaks = false
        var user: String?
        var computerName: String?
        var dryRun = false
        var answerFileOut: String?
        var yes = false
        var noSelect = false
        var console = false
        /// Read the Windows password from standard input instead of asking for it, so a whole install
        /// can be scripted: `op read op://Private/winbar/password | winbar create --yes
        /// --password-stdin`. Still never a flag or an environment variable, which every program on
        /// the Mac can read; a pipe is private to the two processes.
        var passwordStdin = false
        /// `--product-key`: ask for a Windows product key, hidden, and put it in the answer file. A switch,
        /// not a value: see the note at the top of this file. Off by default, and off is today's behaviour.
        var productKey = false
        /// `--product-key-stdin`: the same key, read from a pipe, for a scripted run.
        var productKeyStdin = false
        var guestTools: String?
        var isoSHA256: String?
        var resume = false
        var cancel = false
        /// `--window`: hand the whole thing to the app's New Windows VM window instead.
        var window = false
        /// The positional NAME, whatever it means for this run.
        var positional: String?
        var verbose = false
        var help = false
    }

    /// A refusal from the arguments themselves: the message, and the exit code it carries.
    /// 64 is "I typed the command wrong" — an unknown or refused flag; a value a field can't take is
    /// 65, the same code the later check in `CreatePlan.init` gives the same value, so a wrapper
    /// script is told the same thing whichever check catches it.
    struct Usage: Error, Equatable {
        var code: String
        var message: String
        var exit: Int32 = 64
    }

    /// The field values that count as names and fields, caught here because the value
    /// isn't a number at all.
    static let fieldExit: Int32 = 65

    static let switches: [String: (inout Options) -> Void] = [
        "--no-online-account-bypass": { $0.off.insert(.noOnlineAccount) },
        "--no-regional": { $0.off.insert(.regionalFromMac) },
        "--no-skip-privacy": { $0.off.insert(.skipPrivacy) },
        "--allow-bitlocker": { $0.off.insert(.noBitLocker) },
        "--no-qol": { $0.off.insert(.qol) },
        "--no-autologon": { $0.off.insert(.autologon) },
        "--no-remote-desktop": { $0.off.insert(.remoteDesktop) },
        "--no-winbar-tuning": { $0.off.insert(.winbarTuning) },
        "--no-visual-tweaks": { $0.noVisualTweaks = true },
        "--dry-run": { $0.dryRun = true },
        "--yes": { $0.yes = true },
        "-y": { $0.yes = true },
        "--no-select": { $0.noSelect = true },
        "--console": { $0.console = true },
        "--password-stdin": { $0.passwordStdin = true },
        "--product-key": { $0.productKey = true },
        "--product-key-stdin": { $0.productKeyStdin = true },
        "--resume": { $0.resume = true },
        "--window": { $0.window = true },
        "--verbose": { $0.verbose = true },
        "-h": { $0.help = true },
        "--help": { $0.help = true },
    ]

    static let valueFlags: Set<String> = ["--iso", "--edition", "--cores", "--memory", "--disk", "--user",
                                          "--computer-name", "--answer-file-out", "--guest-tools", "--iso-sha256",
                                          "--cancel"]

    /// One secret from standard input: everything up to the first newline, or the whole of it when
    /// there is none (`printf %s`). Trailing CR is dropped so a file written on Windows still works.
    /// Nothing is echoed, and the bytes are never logged. Used by `--password-stdin` and, for the
    /// product key, by `--product-key-stdin`; only one of the two can have the pipe, so `parse`
    /// refuses both at once.
    static func readSecretFromStdin() -> String? {
        var data = Data()
        while let chunk = try? FileHandle.standardInput.read(upToCount: 4096), !chunk.isEmpty {
            data.append(chunk)
            if chunk.contains(0x0A) { break }
        }
        guard var text = String(data: data, encoding: .utf8) else { return nil }
        if let newline = text.firstIndex(of: "\n") { text = String(text[text.startIndex..<newline]) }
        if text.hasSuffix("\r") { text.removeLast() }
        return text.isEmpty ? nil : text
    }

    /// Parses `winbar create`'s arguments. Every refusal here happens before anything is read or
    /// written, so a mistyped flag never leaves a folder behind.
    static func parse(_ arguments: [String]) -> Result<Options, Usage> {
        var options = Options()
        var i = 0
        while i < arguments.count {
            var argument = arguments[i]
            var inlineValue: String?
            if argument.hasPrefix("--"), let equals = argument.firstIndex(of: "=") {
                inlineValue = String(argument[argument.index(after: equals)...])
                argument = String(argument[..<equals])
            }
            i += 1
            if let refusal = CreateCopy.lockedFlags[argument] {
                return .failure(Usage(code: lockedCode(argument), message: refusal))
            }
            // A password can never be a value on the command line. `--password-stdin` is the one
            // exception by name only: it carries no value, it names the pipe the password comes down.
            if argument.hasPrefix("--password"), argument != "--password-stdin" {
                return .failure(Usage(code: "E_PW_FLAG",
                                      message: "winbar create has no \(argument): " + CreateCopy.passwordWhyPrompt))
            }
            // Nor a product key. `--product-key` and `--product-key-stdin` carry no value; anything else
            // spelled like them, and `--product-key=KEY`, is someone trying to pass the key itself.
            if argument.hasPrefix("--product-key"), argument != "--product-key", argument != "--product-key-stdin" {
                return .failure(Usage(code: "E_KEY_FLAG",
                                      message: "winbar create has no \(argument): " + CreateCopy.productKeyWhyPrompt))
            }
            // `--product-key KEY`, where the key would otherwise be read as the VM's name and silently
            // installed without one. Only a real key is taken this way; any other word is still a name.
            if argument == "--product-key",
               inlineValue != nil || (i < arguments.count && CreateChoices.normalizedProductKey(arguments[i]) != nil) {
                return .failure(Usage(code: "E_KEY_FLAG",
                                      message: "winbar create: --product-key takes no value. "
                                          + CreateCopy.productKeyWhyPrompt))
            }
            if let apply = switches[argument] {
                guard inlineValue == nil else {
                    return .failure(Usage(code: "E_USAGE", message: "winbar create: \(argument) takes no value"))
                }
                apply(&options)
                continue
            }
            if valueFlags.contains(argument) {
                guard let value = inlineValue ?? (i < arguments.count ? arguments[i] : nil) else {
                    return .failure(argument == "--cancel"
                                    ? Usage(code: "E_USAGE", message: "usage: winbar create --cancel NAME")
                                    : Usage(code: "E_USAGE", message: "winbar create: \(argument) needs a value"))
                }
                if inlineValue == nil { i += 1 }
                if let refusal = take(argument, value, into: &options) { return .failure(refusal) }
                continue
            }
            if argument.hasPrefix("-"), argument != "-" {
                return .failure(Usage(code: "E_USAGE", message: "winbar create: unknown option \(argument)"))
            }
            guard options.positional == nil else {
                return .failure(Usage(code: "E_USAGE", message: "winbar create: it takes one name, not \(options.positional!) "
                                      + "and \(argument)"))
            }
            options.positional = argument
        }
        if options.answerFileOut != nil, !options.dryRun {
            return .failure(Usage(code: "E_USAGE", message: "winbar create: --answer-file-out only works with --dry-run"))
        }
        if options.cancel, options.positional == nil {
            return .failure(Usage(code: "E_USAGE", message: "usage: winbar create --cancel NAME"))
        }
        if options.cancel, options.resume {
            return .failure(Usage(code: "E_USAGE", message: "winbar create: --resume and --cancel contradict each other"))
        }
        if options.productKey, options.productKeyStdin {
            return .failure(Usage(code: "E_USAGE", message: "winbar create: --product-key asks for the key and "
                                  + "--product-key-stdin reads it from a pipe. Use one or the other"))
        }
        if options.passwordStdin, options.productKeyStdin {
            return .failure(Usage(code: "E_USAGE", message: "winbar create: --password-stdin and --product-key-stdin "
                                  + "both read standard input, so only one of them can. Pipe the password in and "
                                  + "let --product-key ask for the key"))
        }
        if options.window {
            // The window asks for everything itself, so a flag alongside it would quietly do nothing.
            var alone = Options()
            alone.window = true
            alone.help = options.help
            guard options == alone else {
                return .failure(Usage(code: "E_USAGE", message: "winbar create: --window opens Winbar's window, which "
                                      + "asks for everything itself, so it takes no other options"))
            }
        }
        return .success(options)
    }

    private static func lockedCode(_ flag: String) -> String {
        switch flag {
        case "--no-bypass-requirements": return "E_LOCKED_BYPASS"
        case "--no-local-account": return "E_LOCKED_ACCOUNT"
        default: return "E_LOCKED_GUEST_TOOLS"
        }
    }

    /// One `--flag value`. Numbers are checked here so `--memory 16GB` says what's wrong instead of
    /// being read as 16 or as a name.
    private static func take(_ flag: String, _ value: String, into options: inout Options) -> Usage? {
        func number(_ unit: String) -> Int? { Int(value.trimmingCharacters(in: .whitespaces)) }
        switch flag {
        case "--iso": options.iso = value
        case "--edition": options.edition = value
        case "--user": options.user = value
        case "--computer-name": options.computerName = value
        case "--answer-file-out": options.answerFileOut = value
        case "--guest-tools": options.guestTools = value
        case "--iso-sha256":
            guard let hash = WindowsISO.normalizedSHA256(value) else {
                return Usage(code: "E_USAGE", message: "winbar create: --iso-sha256 takes a 64-character SHA-256")
            }
            options.isoSHA256 = hash
        case "--cancel":
            options.cancel = true
            options.positional = value
        case "--cores":
            guard let n = number("") else {
                return Usage(code: "E_CORES_RANGE", message: "winbar create: --cores takes a number", exit: fieldExit)
            }
            options.cores = n
        case "--memory":
            guard let n = number("GB") else {
                return Usage(code: "E_MEMORY_UNIT", message: "--memory takes gigabytes, like --memory 16.",
                             exit: fieldExit)
            }
            options.memoryGB = n
        case "--disk":
            guard let n = number("GB") else {
                return Usage(code: "E_DISK_RANGE", message: "winbar create: --disk takes gigabytes, like --disk 128.",
                             exit: fieldExit)
            }
            options.diskGB = n
        default: break
        }
        return nil
    }

    // MARK: - Entry point

    static func run(_ arguments: [String]) -> Int32 {
        let options: Options
        switch parse(arguments) {
        case .failure(let refusal):
            Term.error(CreateCopy.wrap(refusal.message, width: CreateCopy.width))
            return refusal.exit
        case .success(let parsed):
            options = parsed
        }
        if options.help {
            print(help(mac: MacFacts.current))
            return 0
        }
        do {
            if options.window { return try openWindow() }
            if options.cancel { return try cancel(options) }
            if options.resume { return try resume(options) }
            return try create(options)
        } catch let error as CreateJobError {
            printFailure(error)
            return error.exitCode
        } catch ChoiceProblem.nameTaken(let name) {
            // The job raises a name clash as a field problem, so the window can put it under Name.
            // In Terminal it reads like any other unusable value: exit 65.
            let failure = CreateJobError.input("E_NAME_TAKEN", ChoiceProblem.nameTaken(name).description,
                                               "", nextStep: "Name another one: winbar create \"NAME\"")
            printFailure(failure)
            return failure.exitCode
        } catch {
            Term.error("winbar create: \(error)")
            return 1
        }
    }

    // MARK: - help

    static func help(mac: MacFacts) -> String {
        let user = CreateChoices.defaultUserName(macShortName: mac.shortUserName)
        let computer = CreateChoices.deriveComputerName(vmName: CreateChoices.baseVMName, userName: user)
        return """
            usage: winbar create [NAME] [--iso PATH] [options]
                   winbar create --resume [NAME]
                   winbar create --cancel NAME

            Makes a new UTM virtual machine called NAME (default “Windows 11”) and installs Windows 11 Arm64 in
            it from Microsoft's ISO, with no clicking: Rufus's "Windows User Experience" options plus what
            Winbar needs. It takes about 10 minutes on a fast Mac, and you don't need to watch.

            In Terminal it shows the plan as a checklist you can change, then asks for the Windows password
            twice. The password is never a flag or an environment variable: arguments are visible to every
            program on your Mac while the command runs and end up in your shell history, and environment
            variables are handed to every program the command starts.

            the VM:
              --iso PATH            a Windows 11 Arm64 ISO, from microsoft.com/software-download/windows11arm64
              --edition NAME        Pro (default), or another edition the ISO has. Home can't accept
                                    Remote Desktop connections, so Winbar's Connect won't work with it
              --cores N             vCPUs (default: your Mac's top-tier cores, 4 to 8; here: \(CreateChoices.suggestedCores(mac)))
              --memory GB           memory in GB (default by your Mac's memory; here: \(CreateChoices.suggestedMemoryGB(mac)))
              --disk GB             disk size in GB, at least 64 (default 128; the file grows as it's used)

            Windows (all on by default; these turn one off):
              --no-online-account-bypass  leave out the online-account bypass
              --no-regional         don't copy this Mac's region, keyboard and time zone
              --no-skip-privacy     let Windows turn on its recommended privacy settings
              --allow-bitlocker     let Windows encrypt its disk by itself
              --no-qol              let Windows force Copilot, OneDrive, Outlook, Fast Startup, etc.
              --no-autologon        show Windows' sign-in screen at startup
              --no-remote-desktop   leave Remote Desktop off (Winbar's Connect needs it)
              --no-winbar-tuning    skip Winbar's performance tuning
              --no-visual-tweaks    tune, but leave animations and transparency alone
              --user NAME           Windows user name (default: your Mac's; here: \(user))
              --computer-name NAME  Windows computer name (default: from the VM name; here: \(computer))
              --product-key         ask for a Windows product key, hidden, and install with it. Optional:
                                    without one Windows installs unactivated, and you can activate it later
                                    in Settings > System > Activation. The key goes into Windows' answer
                                    file in plain text (a key has no scrambled form the way the password
                                    does), on the setup disk Winbar deletes when the install finishes.
                                    Setup refuses a key that isn't for the edition being installed
              --product-key-stdin   read that key from standard input instead, for scripted runs

              Always on: removing the TPM, Secure Boot and RAM requirement (UTM can't add a TPM to a VM
              it creates by script), the local account (Remote Desktop and automatic sign-in need one),
              and the UTM Guest Tools (they carry Windows' network driver and the guest agent Winbar
              talks to Windows through).

              Left out from Rufus: 'Windows CA 2023' bootloaders and SkuSiPolicy (both only matter with
              Secure Boot, which the VM doesn't have), S Mode (the Guest Tools couldn't install), Windows
              To Go (a VM isn't one).

            other:
              --dry-run             print the plan and change nothing (reads the ISO; no password needed)
              --answer-file-out DIR with --dry-run: also write the answer file there, with a stand-in password
              --yes                 skip the checklist and go (still asks for the password)
              --password-stdin      read the Windows password from standard input, for scripted runs:
                                    op read op://Private/winbar/pw | winbar create --yes --password-stdin
              --no-select           don't make the new VM the one Winbar's menu looks after
              --console             keep the VM's UTM window on at the end instead of going headless
              --guest-tools PATH    use this UTM Guest Tools installer instead of downloading (must be \(GuestTools.version))
              --iso-sha256 HASH     check the ISO against Microsoft's SHA-256 before using it
              --window              fill the plan in Winbar's own window instead of here
              --resume [NAME]       carry on watching an install that was interrupted
              --cancel NAME         stop an unfinished install and delete its VM (asks first)
              --verbose             also show what Winbar is doing under the hood
            """
    }

    // MARK: - --window (the same job with a form instead of a checklist)

    /// Opens the app's **New Windows VM** window and leaves it to it. The window belongs to Winbar.app,
    /// not to this process: macOS grants Automation to whoever is responsible for a process, so a
    /// window opened by the app asks about Winbar once instead of about this terminal.
    ///
    /// LaunchServices hands arguments only to a process it starts, and starting a second Winbar would
    /// put a second icon in the menu bar, so a Winbar that is already running is asked by notification.
    private static func openWindow() throws -> Int32 {
        guard let app = AppBundle.url else {
            throw CreateJobError.unavailable("E_NO_APP",
                                             "The New Windows VM window is part of Winbar.app, and this winbar isn't "
                                                 + "inside one.",
                                             "Install the app (brew install --cask taggie313/tap/winbar), or make the "
                                                 + "VM here in Terminal: winbar create.")
        }
        let route = WindowHandOff.route(app: app, appRunning: AppBundle.isAppRunning,
                                        argument: AppDelegate.createWindowArgument,
                                        notification: AppDelegate.createWindowNotification)
        if let failure = WindowHandOff.perform(route) {
            throw CreateJobError.unavailable("E_NO_APP", "Couldn't open \(app.lastPathComponent)", failure)
        }
        print("Winbar's New Windows VM window is open. It asks for the ISO and the password itself, and the install "
              + "carries on there; this terminal is free.")
        return 0
    }

    // MARK: - --resume and --cancel

    private static func resume(_ options: Options) throws -> Int32 {
        CreateJob.sweep()
        guard let state = try? CreateJob.pick(vmName: options.positional) else {
            // The same test `pick` uses: a job that failed with the VM still there is exactly what
            // `--resume` is for, and one that ended with nothing left to carry on with isn't.
            let unfinished = CreateJob.allStates().filter(\.isResumable)
            if unfinished.count > 1 { throw CreateJobError.resumeWhich(unfinished.map(CreateJob.describe)) }
            throw CreateJobError.resumeNone
        }
        print("Carrying on with “\(state.plan.vmName)” (started \(DateFormatter.clock.string(from: state.startedAt)), "
              + "\(state.stage.runningTitle)).")
        let progress = CreateProgressPrinter(verbose: options.verbose)
        watching = progress
        watchSignals()
        defer {
            progress.finish()   // also on the way out of a failure, so nothing overwrites its lines
            restoreSignals()
        }
        try CreateJob.resume(vmName: state.plan.vmName) { progress.update($0) }
        progress.finish()   // before the ending, so the last line is closed
        return try ending(progress.state, options: options)
    }

    private static func cancel(_ options: Options) throws -> Int32 {
        CreateJob.sweep()
        guard let name = options.positional else { throw CreateJobError.resumeNone }
        let state = try CreateJob.pick(vmName: name, forCancel: true)
        let question = "Delete the VM “\(state.plan.vmName)” and its disk? Windows hasn't finished installing, so "
            + "nothing of yours is in it. UTM deletes the disk file outright (not to the Trash). Your Windows ISO "
            + "isn't touched."
        // The whole paragraph is the question, so the [y/N] sits at the end of it.
        guard Term.confirm(CreateCopy.wrap(question, width: CreateCopy.width), assumeYes: options.yes) else {
            print("Nothing was changed. The install is still there: winbar create --resume "
                  + "\"\(state.plan.vmName)\" carries on with it.")
            return 0
        }
        let done = try CreateJob.cancel(vmName: state.plan.vmName, deleteVM: true)
        for line in cancelLines(done, name: state.plan.vmName) { print(line) }
        return 0
    }

    /// What a cancel says it did, from what it actually did rather than from what it usually does.
    /// Pure, so the lines can be held against `CreateCancelResult` without UTM.
    static func cancelLines(_ done: CreateCancelResult, name: String) -> [String] {
        var lines: [String] = []
        if done.vmGone {
            lines.append("· “\(name)” is no longer in UTM, so there was nothing to stop or delete there.")
        }
        if done.stopped { lines.append(Term.paint("✓", .green) + " Stopped the VM") }
        if done.deletedVM { lines.append(Term.paint("✓", .green) + " Deleted the VM in UTM") }
        if done.removedInstallDisks { lines.append(Term.paint("✓", .green) + " Detached the install disks from UTM") }
        if done.deletedSetupDisk { lines.append(Term.paint("✓", .green) + " Deleted the setup disk") }
        if done.deletedSavedPC { lines.append(Term.paint("✓", .green) + " Deleted the saved PC in Windows App") }
        // A job that had already lost its VM and its setup disk: it is closed, and saying nothing at
        // all would read as if the command hadn't run.
        if lines.isEmpty { lines.append("· There was nothing left to stop or delete. The install is closed.") }
        return lines
    }

    // MARK: - A new install

    private static func create(_ options: Options) throws -> Int32 {
        let mac = MacFacts.current
        if !options.dryRun { print("Winbar \(AppBundle.version) create") }

        // UTM before anything else. Making a Windows VM is exactly where "install UTM yourself
        // first" is the step someone stops at, so create offers the same install setup does, in the
        // same words. A dry run changes nothing, so it only reports (the plan says "not installed").
        // The job's preflight still refuses without UTM (E_UTM_MISSING) for the window and for a run
        // with no terminal to ask on.
        if !options.dryRun, !Dependencies.state(of: .utm).isInstalled {
            DependencySetup.offer(.utm, assumeYes: options.yes, indent: "")
        }

        // The ISO: the flag, or the newest one in Downloads with a question, or nothing to go on.
        // Absolute and tilde-free from here on: UTM keeps a bookmark to whatever path it is given.
        func absolute(_ path: String) -> String {
            URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
        }
        let isoPath: String
        if let iso = options.iso {
            isoPath = absolute(iso)
        } else if Term.stdinIsTTY, let found = WindowsISO.defaultISO() {
            let shown = found.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
            guard Term.confirm("Windows ISO: found \(shown). Use it?", assumeYes: options.yes, defaultYes: true) else {
                throw CreateJobError.input("E_NEED_ISO", "Name the ISO to use: winbar create --iso PATH")
            }
            isoPath = found.path
        } else if Term.stdinIsTTY {
            print("No Windows ISO in ~/Downloads. Get one from microsoft.com/software-download/windows11arm64.")
            throw CreateJobError.input("E_NEED_ISO", "Name it with --iso PATH.")
        } else {
            throw CreateJobError(failure: CreateFailure(code: "E_NEED_ISO", title: CreateCopy.needISO, detail: "",
                                                        nextStep: nil), exit: 64)
        }

        print(options.dryRun ? "Dry run: nothing is created, downloaded or changed. (Winbar reads the ISO.)\n"
                             : "Reading the ISO… ", terminator: options.dryRun ? "\n" : "")
        fflush(stdout)
        let image: WindowsImageInfo
        do {
            image = try WindowsISO.inspect(isoPath)
        } catch let problem as ISOProblem {
            if !options.dryRun { print("") }
            throw CreateJobError.input(problem.key, problem.message)
        }
        if let hash = options.isoSHA256 {
            do {
                try WindowsISO.checkSHA256(isoPath, expected: hash)
            } catch let problem as ISOProblem {
                throw CreateJobError.input(problem.key, problem.message)
            }
        }
        if !options.dryRun {
            print("Windows \(WindowsISO.versionName(build: image.build)) (build \(image.fullBuild ?? String(image.build))), "
                  + "Arm64, \(CreateCopy.languageName(image.language))")
            print(CreateCopy.wrap(CreateCopy.isoKeep, width: CreateCopy.width))
            print("")
        }

        let reading = options.off.contains(.regionalFromMac) ? nil : Regional.read(imageLanguage: image.language)
        var plan = try CreatePlan(options: options, image: image, mac: mac, isoPath: isoPath, reading: reading)
        let problems = CreateChoices.problems(in: plan, mac: mac)
        if !problems.isEmpty {
            throw CreateJobError.input("E_FIELD", problems.map(\.description).joined(separator: "\n"))
        }

        if options.dryRun {
            // Asked for here so --answer-file-out can show where the key lands, and so a key Windows
            // would refuse is caught by a dry run too.
            return try dryRun(plan: plan, image: image, mac: mac, reading: reading, options: options,
                              productKey: try productKey(options))
        }

        let askedOnScreen = !options.yes && Term.stdinIsTTY
        if askedOnScreen {
            var checklist = Checklist(plan: plan, image: image, mac: mac, reading: reading,
                                      productKeyWanted: options.productKey || options.productKeyStdin)
            switch checklist.run() {
            case .quit: return 0
            case .go(let edited): plan = edited
            }
        } else {
            // The checklist prints these as they apply; a run that skips it would otherwise install
            // Home, or a VM with more vCPUs than the Mac has top-tier cores, without saying so.
            for warning in planWarnings(plan, mac: mac) {
                print(CreateCopy.wrap(warning.description, width: CreateCopy.width))
            }
        }
        // An ISO with nothing but Home editions is confirmed at Enter, because the
        // checklist's edition row has nothing else to offer and W_HOME is already above it. With
        // --yes there is no Enter, so `CreatePlan.init` refuses it instead (E_HOME_ONLY).
        if askedOnScreen, options.edition == nil, plan.edition.isHome,
           CreateChoices.defaultEdition(image.editions)?.homeOnly == true {
            guard Term.confirm(CreateCopy.wHomeConfirm, assumeYes: false) else { return 0 }
        }
        for note in reading?.notes ?? [] where plan.has(.regionalFromMac) {
            print(CreateCopy.wrap(note.description, width: CreateCopy.width))
        }
        plan = try CreateChoices.effective(plan).plan

        // The password: from a pipe when the run is scripted, otherwise twice, hidden, from /dev/tty.
        // Nothing else may ask for it.
        if options.passwordStdin {
            // A terminal on stdin would echo every character typed: that is not what this flag is for.
            guard isatty(FileHandle.standardInput.fileDescriptor) == 0 else {
                throw CreateJobError(failure: CreateFailure(code: "E_PW_STDIN_TTY", title: CreateCopy.pwStdinTTY,
                                                            detail: "", nextStep: nil), exit: 64)
            }
            guard let piped = CreateCLI.readSecretFromStdin() else {
                throw CreateJobError(failure: CreateFailure(code: "E_PW_STDIN", title: CreateCopy.pwStdinEmpty,
                                                            detail: "", nextStep: nil), exit: 65)
            }
            if let problem = CreateChoices.passwordProblem(piped) {
                throw CreateJobError(failure: CreateFailure(code: "E_PW", title: problem.description, detail: "",
                                                            nextStep: nil), exit: 65)
            }
            // The pipe carried the password, so a key can only come from the terminal here; `parse`
            // refuses --password-stdin and --product-key-stdin together for that reason.
            let key = try productKey(options)
            let progress = CreateProgressPrinter(verbose: options.verbose, said: [])
            watching = progress
            watchSignals()
            defer {
                progress.finish()
                restoreSignals()
            }
            try CreateJob.start(plan: plan, password: piped, productKey: key) { progress.update($0) }
            progress.finish()
            return try ending(progress.state, options: options)
        }
        guard let tty = TTY.open() else {
            throw CreateJobError(failure: CreateFailure(code: "E_NO_TTY", title: CreateCopy.noTTY, detail: "",
                                                        nextStep: nil), exit: 64)
        }
        defer { tty.close() }
        // Read before the prompt, not after it: with FileVault off, N_PW_FILEVAULT_OFF is the line
        // that can still change which password is chosen.
        let fileVaultOn = Host.fileVaultOn
        print("Before you type the password")
        for paragraph in CreateCopy.beforePassword(fileVaultOn: fileVaultOn) {
            print("  " + CreateCopy.wrap(paragraph, width: CreateCopy.width - 2, indent: "  "))
            print("")
        }
        // After the password, and before anything is created: a key Windows would refuse stops the run here.
        let password = try askPassword(tty: tty, user: plan.userName)
        let key = try productKey(options)

        print(CreateCopy.wrap(CreateCopy.automationCLI.replacingOccurrences(of: "{app}", with: Automation.host.name),
                              width: CreateCopy.width))
        print(CreateCopy.wrap(CreateCopy.sleep, width: CreateCopy.width))
        print("")

        let progress = CreateProgressPrinter(verbose: options.verbose,
                                             said: fileVaultOn == false ? ["N_PW_FILEVAULT_OFF"] : [])
        watching = progress
        watchSignals()
        defer {
            progress.finish()   // also on the way out of a failure, so nothing overwrites its lines
            restoreSignals()
        }
        try CreateJob.start(plan: plan, password: password, productKey: key) { progress.update($0) }
        progress.finish()   // before the ending, so the last line is closed
        return try ending(progress.state, options: options)
    }

    /// The warnings a plan carries by itself (W_CORES_HIGH, W_MEMORY_HIGH, W_MEMORY_LOW, W_HOME), in
    /// the order the checklist shows them. The checklist prints them as the person changes things;
    /// `--yes` and the dry run print the same list, so no route leaves one out. Pure.
    static func planWarnings(_ plan: CreatePlan, mac: MacFacts) -> [ChoiceWarning] {
        var warnings: [ChoiceWarning] = []
        if let cores = CreateChoices.coresWarning(plan.cores, mac: mac) { warnings.append(cores) }
        warnings += CreateChoices.memoryWarnings(plan.memoryMiB / 1024, mac: mac)
        if plan.edition.isHome { warnings.append(.home) }
        return warnings
    }

    /// The Windows product key, when the run asked for one, and nil when it didn't — which is the default,
    /// and today's behaviour. From the pipe with `--product-key-stdin`, otherwise from a hidden prompt on the
    /// controlling terminal. Called before anything is created, so a key Windows would refuse stops the run
    /// rather than an install.
    static func productKey(_ options: Options) throws -> String? {
        if options.productKeyStdin {
            guard isatty(FileHandle.standardInput.fileDescriptor) == 0 else {
                throw CreateJobError(failure: CreateFailure(code: "E_KEY_STDIN_TTY", title: CreateCopy.keyStdinTTY,
                                                            detail: "", nextStep: nil), exit: 64)
            }
            guard let piped = readSecretFromStdin() else {
                throw CreateJobError(failure: CreateFailure(code: "E_KEY_STDIN", title: CreateCopy.keyStdinEmpty,
                                                            detail: "", nextStep: nil), exit: 65)
            }
            guard let key = CreateChoices.normalizedProductKey(piped) else {
                throw CreateJobError(failure: CreateFailure(code: "E_KEY", title: ChoiceProblem.productKeyShape.description,
                                                            detail: "", nextStep: nil), exit: 65)
            }
            return key
        }
        guard options.productKey else { return nil }
        guard let tty = TTY.open() else {
            throw CreateJobError(failure: CreateFailure(code: "E_NO_TTY", title: CreateCopy.keyNoTTY, detail: "",
                                                        nextStep: nil), exit: 64)
        }
        defer { tty.close() }
        // The blank line lives here, not at the call site: without a key nothing at all is printed.
        print("")
        print("Before you type the product key")
        print("  " + CreateCopy.wrap(CreateCopy.beforeProductKey, width: CreateCopy.width - 2, indent: "  "))
        print("")
        return try askProductKey(tty: tty)
    }

    /// Hidden, three tries, normalised. Once, not twice: a mistyped key is caught by its shape, which a
    /// mistyped password never is.
    static func askProductKey(tty: TTY) throws -> String {
        for attempt in 1...3 {
            guard let typed = tty.readPassword("Windows product key: ") else {
                throw CreateJobError(failure: CreateFailure(code: "E_NO_TTY", title: CreateCopy.keyNoTTY, detail: "",
                                                            nextStep: nil), exit: 64)
            }
            if let key = CreateChoices.normalizedProductKey(typed) { return key }
            let problem = ChoiceProblem.productKeyShape.description
            tty.write(CreateCopy.wrap(problem, width: CreateCopy.width) + "\n")
            if attempt == 3 { throw CreateJobError.input("E_KEY", problem) }
        }
        throw CreateJobError.input("E_KEY", ChoiceProblem.productKeyShape.description)
    }

    /// Twice, hidden, three tries. Nothing is created before this passes.
    static func askPassword(tty: TTY, user: String) throws -> String {
        for attempt in 1...3 {
            guard let first = tty.readPassword("Password for \(user): ") else {
                throw CreateJobError(failure: CreateFailure(code: "E_NO_TTY", title: CreateCopy.noTTY, detail: "",
                                                            nextStep: nil), exit: 64)
            }
            if let problem = CreateChoices.passwordProblem(first) {
                tty.write(problem.description + "\n")
                if attempt == 3 { throw CreateJobError.input("E_PW_EMPTY", problem.description) }
                continue
            }
            guard let again = tty.readPassword("Again: ") else {
                throw CreateJobError(failure: CreateFailure(code: "E_NO_TTY", title: CreateCopy.noTTY, detail: "",
                                                            nextStep: nil), exit: 64)
            }
            if first == again { return first }
            tty.write("The passwords don't match. Try again.\n")
        }
        throw CreateJobError.input("E_PW_MISMATCH", "The passwords don't match.")
    }

    // MARK: - Endings

    /// Prints the last screen of a run that got as far as installing, and returns its exit code.
    private static func ending(_ state: CreateJobState?, options: Options) throws -> Int32 {
        guard let state else { return 0 }
        let plan = state.plan
        let took = CreateElapsed.minutes((state.finishedAt ?? Date()).timeIntervalSince(state.startedAt))
        print("")
        print(Term.paint("✓", .green) + " " + CreateCopy.installed(edition: plan.edition.displayName,
                                                                   name: plan.vmName, took: took))
        print("")
        let host = CreateChoices.hostName(computerName: plan.computerName)
        print("  Sign in as     \(plan.userName), with the password you chose")
        print("  Reach it at    \(host)")
        print("  Winbar's VM    “\(plan.vmName)”" + (plan.select ? " (the menu bar icon now looks after it)" : ""))
        for text in [state.usedProductKey ? CreateCopy.nActivating : CreateCopy.nNotActivated, CreateCopy.nUpdates] {
            print("  ·  " + CreateCopy.wrap(text, width: CreateCopy.width - 5, indent: "     "))
        }
        print("")
        print(CreateCopy.wrap(CreateCopy.nextSetup(savedPC: state.wroteSavedPC), width: CreateCopy.width))
        print("")
        let command = CreateCopy.setupCommand(plan: plan)
        guard Term.stdinIsTTY, Term.confirm("Run \(command) now?", assumeYes: options.yes, defaultYes: true) else {
            return 0
        }
        var setupOptions = Context.Options(vmOverride: plan.select ? nil : plan.vmName)
        setupOptions.assumeYes = options.yes
        setupOptions.noVisualTweaks = plan.noVisualTweaks
        setupOptions.keepBitLocker = !plan.has(.noBitLocker)
        return Setup.run(options: setupOptions)
    }

    /// The run being watched, so a failure can name the log and the stage even after the job's
    /// folder (and its state.json) have gone.
    private static var watching: CreateProgressPrinter?

    /// The ✗ (or !) ending of a run that didn't finish. Ctrl-C has its own wording.
    private static func printFailure(_ error: CreateJobError) {
        let state = watching?.state
        let lines = failureLines(error, state: state,
                                 logPath: state?.logPath ?? CreateJob.current()?.logPath,
                                 vmName: state?.plan.vmName ?? CreateJob.current()?.plan.vmName,
                                 width: CreateCopy.width)
        // Ctrl-C isn't an error: it goes to stdout with the rest of the run's lines.
        for line in lines { error.exitCode == 130 ? print(line) : Term.error(line) }
    }

    /// The failure's lines, in order. Pure, so what Terminal says about a failure can be held beside
    /// what the window says about the same `CreateFailure`: both read it, neither rewords it.
    static func failureLines(_ error: CreateJobError, state: CreateJobState?, logPath: String?, vmName: String?,
                             width: Int) -> [String] {
        let failure = error.failure
        if error.exitCode == 130 {
            var lines = ["", CreateCopy.wrap(failure.title, width: width)]
            if let next = failure.nextStep {
                lines.append("  Carry on:           \(next)")
                lines.append("  Or open Winbar's menu: it picks unfinished installs up by itself.")
                if let vmName { lines.append("  Give up and delete: winbar create --cancel \"\(vmName)\"") }
            }
            return lines
        }
        var lines = [""]
        if failure.code == "E_RESULT_FAILED", let state {
            // Windows is installed, so the heading says so and the problem sits under it.
            let took = CreateElapsed.minutes((state.finishedAt ?? Date()).timeIntervalSince(state.startedAt))
            lines.append(Term.paint("!", .yellow) + " "
                         + CreateCopy.installedWithProblems(edition: state.plan.edition.displayName,
                                                            name: state.plan.vmName, took: took))
            lines.append("  " + Term.paint("✗", .red) + " "
                         + CreateCopy.wrap(failure.title, width: width - 4, indent: "    "))
        } else {
            // The stage says where it stopped; the failure says what happened there.
            let where_ = error.exitCode == 1 ? state.map { "\($0.stage.runningTitle): " } ?? "" : ""
            lines.append(Term.paint("✗", .red) + " "
                         + CreateCopy.wrap(where_ + failure.title, width: width - 2, indent: "  "))
        }
        if !failure.detail.isEmpty {
            lines.append("  " + CreateCopy.wrap(failure.detail, width: width - 2, indent: "  "))
        }
        if let next = failure.nextStep, failure.code != "E_RESULT_FAILED" {
            lines.append("  " + CreateCopy.wrap(next, width: width - 2, indent: "  "))
        }
        if let logPath {
            lines.append("  Log: \(logPath)" + (failure.code == "E_RESULT_FAILED" ? " (includes Windows' own)" : ""))
        }
        if failure.code == "E_RESULT_FAILED" { lines += ["", "Next: winbar setup"] }
        return lines
    }

    // MARK: - Ctrl-C

    private static var signalSource: DispatchSourceSignal?

    /// Ctrl-C stops watching, it doesn't stop Windows. The default action is turned off first, so the
    /// process lives long enough to say what happens next.
    private static func watchSignals() {
        CreateJob.interrupt.clear()
        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        source.setEventHandler { CreateJob.interrupt.raise() }
        source.resume()
        signalSource = source
    }

    private static func restoreSignals() {
        signalSource?.cancel()
        signalSource = nil
        signal(SIGINT, SIG_DFL)
    }

    // MARK: - Dry run

    private static func dryRun(plan: CreatePlan, image: WindowsImageInfo, mac: MacFacts,
                               reading: Regional.Reading?, options: Options, productKey: String?) throws -> Int32 {
        let effective = try CreateChoices.effective(plan)
        print(dryRunText(plan: effective.plan, image: image, mac: mac, reading: reading,
                         utmVersion: UTM.isInstalled ? UTM.version : nil,
                         space: CreatePreflight.freeSpace(), fileVault: Host.fileVaultOn,
                         onBattery: CreatePreflight.onBattery(), guestTools: GuestTools.cached(),
                         warnings: planWarnings(effective.plan, mac: mac).map(\.description)
                             + (effective.plan.has(.regionalFromMac) ? (reading?.notes ?? []).map(\.description) : []),
                         hasProductKey: productKey != nil))
        if let directory = options.answerFileOut {
            let files = try AnswerFile.render(plan: effective.plan, image: image, password: standInPassword,
                                              productKey: productKey)
            let base = URL(fileURLWithPath: (directory as NSString).expandingTildeInPath)
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            for file in files {
                let url = base.appendingPathComponent(file.name)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try file.contents.write(to: url)
            }
            print("")
            print("Wrote \(base.appendingPathComponent(AnswerFile.answerFileName).path) (the password in it is the "
                  + "stand-in \(standInPassword)"
                  + (productKey == nil ? "" : "; the product key is your real one, in plain text") + ").")
        }
        return 0
    }

    /// Never a real password, and obvious in a file someone finds later.
    static let standInPassword = "NOT-YOUR-PASSWORD"

    /// The dry run's text. Pure, so the layout can be tested without a Mac's ISO.
    static func dryRunText(plan: CreatePlan, image: WindowsImageInfo, mac: MacFacts, reading: Regional.Reading?,
                           utmVersion: String?, space: CreatePreflight.Space, fileVault: Bool?, onBattery: Bool,
                           guestTools: GuestTools.Copy?, warnings: [String], hasProductKey: Bool = false) -> String {
        let host = CreateChoices.hostName(computerName: plan.computerName)
        let imageIndex = image.editions.firstIndex { $0.index == plan.edition.index }.map { $0 + 1 } ?? plan.edition.index
        // `wrapped` is false for a value that is already laid out in columns (the checklist grid).
        var rows: [(label: String, value: String, wrapped: Bool)] = []
        func add(_ label: String, _ value: String, wrapped: Bool = true) { rows.append((label, value, wrapped)) }
        add("VM", "“\(plan.vmName)” in UTM \(utmVersion ?? "(not installed)"): \(plan.cores) vCPUs, "
            + "\(plan.memoryMiB / 1024) GB memory, \(plan.diskGiB) GB disk (NVMe; grows as used), Shared Network, UEFI, no TPM; "
            + "its window stays on during the install"
            + (plan.keepConsole ? " and afterwards (--console)" : ", then Winbar takes it headless"))
        add("Windows", "\(plan.edition.displayName) (image \(imageIndex) of \(image.editions.count)), build "
            + "\(image.fullBuild ?? String(image.build)), \(CreateCopy.languageName(image.language))")
        add("Account", "\(plan.userName), local administrator; password asked for when you run it for real")
        add("Computer", "\(plan.computerName), reached from your Mac as \(host)")
        // Whether there is a key, never the key: the dry run's text is something people paste into bug reports.
        add("Product key", hasProductKey
            ? "the one you typed, written into the answer file in plain text; Windows activates itself with it"
            : "none. Windows installs unactivated; activate it later in Settings > System > Activation, or run "
                + "this again with --product-key")
        let region = plan.has(.regionalFromMac) ? reading.map(Checklist.regionSummary) : nil
        add("Region", region ?? "Windows' defaults: \(CreateCopy.languageName(image.language)) formats and keyboard, "
            + "Windows' default time zone")
        add("Checklist", checklistGrid(plan.options), wrapped: false)
        add("CDs", "the Windows ISO and the setup disk (WINBAR_SETUP, which carries UTM Guest Tools "
            + "\(GuestTools.version)), both removed when Windows is installed")
        add("Files", "setup disk: \(tilde(CreateJob.base.path))/<job>.noindex/\(SetupMedia.isoName)\n"
            + "Guest Tools: \(guestTools == nil ? "to download, \(GuestTools.size >> 20) MB, to" : "already in")"
            + " \(tilde(GuestTools.defaultCacheDirectory.path))/")
        add("Afterwards", plan.select ? "Winbar looks after “\(plan.vmName)”, host \(host), user \(plan.userName)"
            : "Winbar keeps looking after the VM it has now (--no-select)")

        var text = "The plan\n"
        let indent = String(repeating: " ", count: 14)
        for row in rows {
            let body = row.value.split(separator: "\n", omittingEmptySubsequences: false)
                .map { row.wrapped ? CreateCopy.wrap(String($0), width: CreateCopy.width - 14, indent: indent) : String($0) }
                .joined(separator: "\n" + indent)
            text += "  " + row.label.padding(toLength: 12, withPad: " ", startingAt: 0) + body + "\n"
        }

        text += "\nChecks\n"
        var checks: [String] = []
        checks.append("  ✓ Windows 11 Arm64 installer, no answer file of its own")
        let free = CreatePreflight.gb(space.freeBytes)
        checks.append("  \(space.freeBytes >= CreatePreflight.neededBytes ? "✓" : "✗") \(free) GB free on "
                      + "\(space.volume) (installing needs 40 GB)")
        checks.append("  \(utmVersion == nil ? "✗ UTM isn't installed" : "✓ UTM \(utmVersion!)")")
        if let fileVault {
            checks.append(fileVault ? "  · FileVault is on, so the VM's disk is encrypted at rest by macOS"
                          : "  · FileVault is off, so the VM's disk and the setup disk aren't encrypted at rest")
        }
        if onBattery { checks.append("  ! Your Mac is on battery. Plug in before the real run.") }
        for warning in warnings { checks.append("  ! " + CreateCopy.wrap(warning, width: CreateCopy.width - 4, indent: "    ")) }
        checks.append("  · " + CreateCopy.wrap("Not checked in a dry run: whether UTM already has a VM called "
                                               + "“\(plan.vmName)” (asking would start UTM)",
                                               width: CreateCopy.width - 4, indent: "    "))
        text += checks.joined(separator: "\n")
        text += "\n\nTo do it for real, run the same command without --dry-run."
        return text
    }

    /// The checklist as ids in three columns: they're the contract between Winbar's parts, and what a
    /// bug report should quote.
    static func checklistGrid(_ on: Set<CreateOption>) -> String {
        let cells = CreateOption.allCases.map { "[\(on.contains($0) ? "x" : " ")] \($0.rawValue)" }
        var lines: [String] = []
        for row in stride(from: 0, to: cells.count, by: 3) {
            let group = Array(cells[row..<min(row + 3, cells.count)])
            var line = ""
            for (column, cell) in group.enumerated() {
                let width = column == 0 ? 26 : 24
                line += column == group.count - 1 ? cell : cell.padding(toLength: width, withPad: " ", startingAt: 0)
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    static func tilde(_ path: String) -> String {
        path.hasPrefix(NSHomeDirectory()) ? "~" + path.dropFirst(NSHomeDirectory().count) : path
    }
}

// MARK: - Building the plan from flags and this Mac

extension CreatePlan {
    /// The plan the flags ask for, before the checklist screen edits it. Throws a `CreateJobError`
    /// (exit 65) for a value Windows or UTM would refuse.
    init(options: CreateCLI.Options, image: WindowsImageInfo, mac: MacFacts, isoPath: String,
         reading: Regional.Reading?) throws {
        let name = options.positional ?? CreateChoices.baseVMName
        if let problem = CreateChoices.vmNameProblem(name) { throw CreateJobError.input("E_NAME", problem.description) }
        let user = options.user ?? CreateChoices.defaultUserName(macShortName: mac.shortUserName)
        let computer = options.computerName ?? CreateChoices.deriveComputerName(vmName: name, userName: user)
        if let problem = CreateChoices.userNameProblem(user, computerName: computer) {
            throw CreateJobError.input("E_USER", problem.description)
        }
        if let problem = CreateChoices.computerNameProblem(computer, userName: user) {
            throw CreateJobError.input("E_COMPUTER", problem.description)
        }
        let edition: WindowsEdition
        do {
            if let wanted = options.edition {
                edition = try CreateChoices.matchEdition(wanted, in: image.editions)
            } else if let (fallback, homeOnly) = CreateChoices.defaultEdition(image.editions) {
                // Home is only ever installed when it was chosen. The checklist asks at
                // Enter; --yes answers nothing, so it can't choose it.
                if homeOnly, options.yes {
                    throw CreateJobError.input("E_HOME_ONLY", CreateCopy.eHomeOnly, "",
                                               nextStep: CreateCopy.eHomeOnlyNext(edition: fallback.displayName))
                }
                edition = fallback
            } else {
                throw ChoiceProblem.noEditions
            }
        } catch let problem as ChoiceProblem {
            throw CreateJobError.input("E_ISO_NO_EDITION", problem.description)
        }
        let cores = options.cores ?? CreateChoices.suggestedCores(mac)
        if let problem = CreateChoices.coresProblem(cores, mac: mac) { throw CreateJobError.input("E_CORES_RANGE", problem.description) }
        let memory = options.memoryGB ?? CreateChoices.suggestedMemoryGB(mac)
        if let problem = CreateChoices.memoryProblem(memory, mac: mac) { throw CreateJobError.input("E_MEMORY_RANGE", problem.description) }
        let disk = options.diskGB ?? CreateChoices.defaultDiskGB
        if let problem = CreateChoices.diskProblem(disk) { throw CreateJobError.input("E_DISK_RANGE", problem.description) }

        let chosen = CreateOption.defaults.subtracting(options.off)
        let regional = chosen.contains(.regionalFromMac) ? reading?.values : nil
        self.init(vmName: name, isoPath: isoPath, edition: edition, cores: cores, memoryMiB: memory * 1024,
                  diskGiB: disk, options: chosen, noVisualTweaks: options.noVisualTweaks, userName: user,
                  computerName: computer, regional: regional, select: !options.noSelect,
                  keepConsole: options.console, guestToolsPath: options.guestTools)
    }
}
