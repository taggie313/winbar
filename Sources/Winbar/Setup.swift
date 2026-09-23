import Foundation

/// `winbar setup`: doctor, then fix what can be fixed and walk through what can't.
///
/// Order matters: Windows must answer (G0) before anything in it can change; the account needs a
/// password (G5) before Remote Desktop's protections go on (G6), or they'd lock it out; the guest
/// fixes need no restart; H7 trusts the certificate G7 just made; the other manual steps come next;
/// and every change that needs the VM off (vCPUs, RAM, display) is batched into one restart at the
/// end. Re-running changes nothing that's already right.
enum Setup {
    static func run(options: Context.Options) -> Int32 {
        let ctx = Context(options: options)
        print("Winbar \(AppBundle.version) setup")

        // UTM first: every other row asks something of a VM, and without UTM there is none. Winbar
        // offers to install it rather than handing out a command to go and type (H1).
        if !Dependencies.state(of: .utm).isInstalled, DependencySetup.offer(.utm, assumeYes: options.assumeYes) {
            // Everything below asks LaunchServices where UTM is, and it can take a moment to notice
            // an app that has just been copied in.
            waitUntil(timeout: 15, every: 1) { UTM.isInstalled }
        }

        guard UTM.isInstalled else {
            print("\nWinbar needs UTM to go on: it drives UTM's own tools. " + DependencyCopy.byHand(.utm))
            print("Then create a Windows 11 VM (winbar create does it for you) and run this again.")
            return 1
        }
        guard chooseVM(ctx), let vm = ctx.vmName else { return 1 }
        rememberOptOuts(options)

        if !VMProcesses.isRunning(vm) {
            if Term.confirm("\(vm) is stopped. Start it so Windows can be checked and tuned?", assumeYes: options.assumeYes) {
                Term.note("Starting \(vm)…")
                switch UTM.start(vm) {
                case .failure(let error):
                    Term.error("\(error)")
                case .success:
                    waitForWindows(vm)
                    ctx.refreshAll()   // the VM list was read while it was stopped; H2 would still say so
                }
            }
        } else if !UTM.guestAgentAnswers(vm) {
            waitForWindows(vm)
        }

        Doctor.report(ctx)
        print("")
        fillDefaults(ctx)

        // Windows first has to be reachable at all.
        walk("G0", ctx)
        // Then a password, before G6 turns on protections that refuse a blank one over Remote Desktop.
        walk("G5", ctx)

        // What create's checklist already answered: said once, then left alone.
        reportDeclined(ctx)

        // Changes inside Windows; none needs a restart. G11 is the drive mapping the Guest Tools
        // normally make, and only appears when a folder is shared without one.
        var changedGuest = false
        for id in fixPass where declined(id, ctx) == nil {
            if offer(id, ctx) { changedGuest = true }
        }
        let decrypting = offerDecryption(ctx)
        if changedGuest || decrypting { ctx.refreshGuest() }

        // H7 trusts the certificate G7 may just have made, so it comes after.
        offer("H7", ctx)

        // H9 first: a utmctl that isn't answering is the reason every row below it would fail, and
        // it is the one a person can otherwise only read as "Winbar is broken".
        for id in manualPass where declined(id, ctx) == nil {
            // C1 is an app Microsoft ships, not a setting: setup offers to install it (with
            // Homebrew, or by opening its App Store page) instead of printing a command. It comes
            // before C2, which has nowhere to save a PC until Windows App is there.
            if id == "C1", let check = Recipe.check(id), !ctx.status(of: check).isOK,
               DependencySetup.offer(.windowsApp, assumeYes: ctx.options.assumeYes) {
                waitUntil(timeout: 15, every: 1) { WindowsApp.appURL != nil }   // as above (H1)
                ctx.refresh(after: check)
            }
            // C2 is the one client check Winbar can now do itself, and it has its own conversation
            // (it needs a password setup wasn't given). Declining leaves the manual step `walk` shows.
            if id == "C2", let check = Recipe.check(id), offerSavedPC(ctx) { ctx.refresh(after: check) }
            walk(id, ctx)
        }

        restartBatch(ctx)

        if decrypting || ctx.guestOutput.flatMap(BitLockerState.init)?.decrypting == true { followDecryption(vm) }

        ctx.refreshAll()
        print("\nWhere things stand now:")
        let results = Doctor.report(ctx)
        Doctor.printSummary(results)
        return Doctor.exitCode(results)
    }

    // MARK: The passes

    // Named rather than written inline in `run`, so the wizard's step list (`SetupFlow.checks(in:)`)
    // can be held to them by test: the two front-ends agree by test, not by sharing a loop, because
    // `run` is two passes with G8 and G11 in both, which one flat list can't say (COHERENCE C3).
    // Changing either order here changes the terminal conversation, and SetupFlowTests will say
    // which of the wizard's steps now disagrees.

    /// Changes inside Windows, none of them needing a restart, offered after G0 and G5 have been
    /// walked. G11 is the drive mapping the Guest Tools normally make, and only appears when a folder
    /// is shared without one.
    static let fixPass = ["G1", "G2", "G3", "G4", "G6", "G7", "G8", "G11"]

    /// The manual steps, after BitLocker and H7. H9 first: a utmctl that isn't answering is the
    /// reason every row below it would fail. G8 and G11 are here as well as in the fix pass: fix it
    /// if it can be fixed, walk it if it can't.
    static let manualPass = ["H9", "G8", "G11", "H6", "H8", "C1", "C2", "C3"]

    /// Staged into the single restart at the end, before the shared-folder offer and the display.
    static let restartPass = ["H3", "H4"]

    // MARK: Choosing the VM

    private static func chooseVM(_ ctx: Context) -> Bool {
        let list: [VMInfo]
        switch ctx.vms {
        case .failure(let error):
            Term.error("Couldn't ask UTM for its VMs: \(error)")
            // The likeliest reason right after UTM is installed, and nothing on screen says so:
            // macOS is holding the first Apple Event until somebody allows it (H9).
            if !error.automationDenied {
                let consent = Automation.consent(bundleID: Config.utmBundleID)
                if consent != .decided {
                    Term.error(CreateCopy.wrap(UTMFirstUse.how(consent: consent,
                                                               quarantined: Quarantine.isMarked(UTM.appURL?.path)),
                                               width: CreateCopy.width))
                }
            }
            return false
        case .success(let vms): list = vms
        }
        // The id goes in with the name: UTM lets a VM be renamed, and its settings are filed under
        // the id wherever Winbar knows one.
        func select(_ vm: VMInfo) {
            if let previous = Config.selectVM(vm.name, id: vm.id) {
                print("Switched to \(vm.name). What Winbar remembers about \(previous) is kept for it.")
            }
            ctx.adoptSelection(name: vm.name, id: vm.id)
            ctx.refreshAll()
        }
        if let wanted = ctx.options.vmOverride {
            guard let vm = list.first(where: { $0.name == wanted }) else {
                Term.error("UTM has no VM named \(wanted). It has: \(list.map(\.name).joined(separator: ", "))")
                return false
            }
            select(vm)
            return true
        }
        if let name = ctx.vmName {
            if list.contains(where: { $0.name == name }) { return true }
            print("UTM no longer has a VM named \(name).")
        }
        let candidates = ctx.candidates
        switch candidates.count {
        case 0:
            print("UTM has no Windows VMs. Create a Windows 11 ARM64 VM in UTM, then run this again.")
            return false
        case 1:
            guard Term.confirm("Use \(candidates[0].name)?", assumeYes: ctx.options.assumeYes, defaultYes: true) else { return false }
            select(candidates[0])
            return true
        default:
            print("Which VM should Winbar look after?")
            guard let index = Term.choose("Number: ", from: candidates.map(\.name)) else {
                print("Choose one with: winbar setup --vm <name>")
                return false
            }
            select(candidates[index])
            return true
        }
    }

    /// `--keep-bitlocker` and `--no-visual-tweaks` stick to the VM (after choosing it: they are
    /// filed under it), so doctor honours them and a later `setup --yes` doesn't undo the choice.
    private static func rememberOptOuts(_ options: Context.Options) {
        if options.keepBitLocker && !Config.keepBitLocker {
            Config.keepBitLocker = true
            print("Keeping BitLocker from now on (winbar config --keep-bitlocker no undoes it).")
        }
        if options.noVisualTweaks && !Config.noVisualTweaks {
            Config.noVisualTweaks = true
            print("Leaving visual effects alone from now on (winbar config --no-visual-tweaks no undoes it).")
        }
    }

    /// Up to three minutes for the guest agent, then up to 90 s more for autologon's desktop: the agent
    /// can answer first, and a survey before explorer.exe starts finds nobody signed in. `note` is
    /// where the two lines go: the terminal's dim note, or the setup window's step 2.
    static func waitForWindows(_ vm: String, note: (String) -> Void = { Term.note($0) }) {
        note(SetupCopy.waitingForWindows)
        guard UTM.waitForGuestAgent(vm, timeout: 180) else {
            note(SetupCopy.agentNotYet)
            return
        }
        _ = GuestAgent.run(vm: vm, GuestScripts.waitForAutologon(seconds: 90), timeout: 120)
    }

    /// Remembers the host and user found in the guest, so the menu and later runs don't need to ask.
    /// The setup window does the same after its survey, or its Connect and the menu's would have no
    /// host; `say` is where the terminal's account of it goes, and the window has no use for it.
    static func fillDefaults(_ ctx: Context, say: (String) -> Void = { print($0) }) {
        guard ctx.isConfiguredVM else { return }
        if Config.rdpHost == nil, let host = ctx.rdpHost {
            guard ctx.isConfiguredVM else { return }
            if Config.isValidHostName(host) {
                Config.rdpHost = host
                say("Remote Desktop host: \(host) (from the Windows computer name; change it with winbar config --host)")
            } else {
                say("The Windows computer name doesn't make a usable host name (\(host)); set one with winbar config --host.")
            }
        }
        if Config.rdpUser == nil, let user = ctx.rdpUser {
            guard ctx.isConfiguredVM else { return }
            Config.rdpUser = user
            say("Windows user: \(user) (the signed-in user; change it with winbar config --user)")
        }
    }

    /// The `winbar config` switch that would turn a declined row back on, or nil when the person
    /// never declined this check's row when the VM was created.
    static func declined(_ id: String, _ ctx: Context) -> String? {
        declinedSwitch(id, autologon: ctx.declinedAutologon, remoteDesktop: ctx.declinedRemoteDesktop,
                       tuning: ctx.declinedTuning)
    }

    /// Which check belongs to which row of `winbar create`'s checklist: automatic sign-in
    /// is G8, Remote Desktop G6, and the performance tuning is G1 to G4. Pure, so the mapping can be
    /// tested without a VM.
    static func declinedSwitch(_ id: String, autologon: Bool, remoteDesktop: Bool, tuning: Bool) -> String? {
        switch id {
        case "G8": return autologon ? "--autologon" : nil
        case "G6": return remoteDesktop ? "--remote-desktop" : nil
        case "G1", "G2", "G3", "G4": return tuning ? "--winbar-tuning" : nil
        default: return nil
        }
    }

    /// One line each, before the fixes: the rows `winbar create`'s checklist was left unticked for.
    /// Tuning is four checks and one choice, so it is mentioned once.
    private static func reportDeclined(_ ctx: Context) {
        var said: Set<String> = []
        for id in ["G1", "G2", "G3", "G4", "G6", "G8"] {
            guard let option = declined(id, ctx), said.insert(option).inserted else { continue }
            let title = option == "--winbar-tuning" ? "Performance tuning" : (Recipe.check(id)?.title ?? id)
            print("\n· \(title): off by choice (winbar config \(option) yes to change)")
        }
    }

    // MARK: Fixes and manual steps

    /// Offers one fix if its check says fixable. True if it was applied.
    @discardableResult
    private static func offer(_ id: String, _ ctx: Context) -> Bool {
        guard let check = Recipe.check(id), let apply = check.apply else { return false }
        let status = ctx.status(of: check)
        guard status.isFixable else { return false }
        print("\n\(status.symbol) \(check.id) \(check.title): \(status.detail)")
        print(Term.paint("   " + check.why, .dim))
        guard Term.confirm("Fix it?", assumeYes: ctx.options.assumeYes) else { return false }
        // Said here rather than by the check, so the window can say the same sentence (H7's prompt).
        if let before = SetupCopy.beforeFix(check.id) { print(before) }
        return report(apply(ctx), check, ctx)
    }

    @discardableResult
    private static func report(_ result: Result<Void, WinbarError>, _ check: Check, _ ctx: Context) -> Bool {
        switch result {
        case .success:
            // No refresh here: each guest fix would otherwise cost a fresh survey. run() re-surveys
            // once after the whole batch.
            print("   " + Term.paint("✓", .green) + " done")
            return true
        case .failure(let error):
            print("   " + Term.paint("✗", .red) + " \(error)")
            return false
        }
    }

    /// Walks one manual step: explain, open the right window, wait for the person, check again.
    /// `--yes` never answers these: they're where a person types passwords and approves things.
    private static func walk(_ id: String, _ ctx: Context) {
        guard let check = Recipe.check(id), case .manual(let detail, let how) = ctx.status(of: check) else { return }
        print("\n\(Term.paint("?", .cyan)) \(check.id) \(check.title): \(detail)")
        print(Term.paint("   why: " + check.why, .dim))
        print("   how: " + how)
        guard Term.stdinIsTTY else {
            print("   (skipped: no terminal to wait on)")
            return
        }
        check.guide?(ctx)
        while true {
            guard Term.waitForStep() == .done else {
                print("   skipped")
                return
            }
            check.recordDone?(ctx)
            ctx.refresh(after: check)
            let status = ctx.status(of: check)
            guard case .manual(let still, let how) = status else {
                print("   \(status.symbol) \(status.detail)")
                return
            }
            print("   " + SetupCopy.Tune.still(still))
            print("   how: " + how)
        }
    }

    // MARK: The saved PC (C2)

    /// Offers to save the PC in Windows App, and does it. Returns whether anything changed.
    ///
    /// `create` had the password already; setup never did, so it has to ask. The prompt is the same
    /// hidden one `create` uses — read straight from `/dev/tty` with the echo off, so it still works
    /// when stdout is a pipe and nothing typed can land in a redirected file. It is never a flag and
    /// never an argument of `winbar`: those are visible to every program on the Mac and end up in
    /// the shell's history.
    ///
    /// Asked once, not twice. `create` asks twice because a mistyped password would be baked into
    /// Windows itself; here the worst case is a saved PC that doesn't sign in, which the person can
    /// fix in Windows App or by running setup again. And `--yes` never answers this: a person typing
    /// a password is exactly what `--yes` may not do for them.
    ///
    /// Saying no keeps today's manual step, which `walk` then shows.
    @discardableResult
    private static func offerSavedPC(_ ctx: Context) -> Bool {
        guard let check = Recipe.check("C2") else { return false }
        let status = ctx.status(of: check)
        guard status.isFixable, let host = ctx.rdpHost, let user = ctx.rdpUser else { return false }
        print("\n\(status.symbol) \(check.id) \(check.title): \(status.detail)")
        print(Term.paint("   " + check.why, .dim))
        print("   " + CreateCopy.wrap(SetupCopy.SavedPC.why(user: user), width: CreateCopy.width, indent: "   "))
        guard Term.confirm("Save this PC in Windows App now?", assumeYes: false, defaultYes: true) else {
            print("   Left for you to add in Windows App.")
            return false
        }
        guard let tty = TTY.open() else {
            print("   (skipped: no terminal to ask for the password on)")
            return false
        }
        guard let password = tty.readPassword("Password for \(user) (Enter to skip): "), !password.isEmpty else {
            print("   Skipped. Add the PC in Windows App yourself, or run winbar setup again.")
            return false
        }
        do {
            switch try savePC(ctx, host: host, user: user, password: password) {
            case .created(let pc):
                print("   " + Term.paint("✓", .green) + " saved in Windows App as “\(pc.name)”")
            case .alreadyThere(let pc):
                print("   " + Term.paint("✓", .green) + " Windows App already had one (“\(pc.name)”); left alone")
            }
            return true
        } catch {
            print("   " + Term.paint("✗", .red) + " \(error)")
            return false
        }
    }

    /// Saves the PC in Windows App and remembers it for the configured VM: the one action behind
    /// `offerSavedPC`, and behind the setup window's **Save It**, so the two can't save differently.
    ///
    /// `passwordVerified: false`: Winbar has no way to check this one, and probing would be a failed
    /// logon — Windows locks a local account after ten. So the saved PC doesn't retry by itself until
    /// a connection has actually worked.
    static func savePC(_ ctx: Context, host: String, user: String, password: String) throws -> WindowsAppBookmarks.Saved {
        let saved = try WindowsAppBookmarks.save(host: host, user: user, password: password,
                                                 friendlyName: ctx.vmName, passwordVerified: false)
        switch saved {
        case .created(let pc), .alreadyThere(let pc): Recipe.rememberSavedPC(pc, host: host, for: ctx)
        }
        return saved
    }

    // MARK: BitLocker

    /// Where the VM's disk is kept, from the running QEMU's own arguments, and whether they were seen
    /// at all; without them, UTM's default folder on the startup disk, which is a guess the question
    /// then admits. Shared with the setup window, so G9 asks both front-ends about the same places.
    static func whereTheDiskIs(_ ctx: Context) -> (places: [Host.Storage], seen: Bool) {
        let images = ctx.process?.diskImages ?? []
        let places = images.isEmpty ? [Host.Storage.startupDisk] : Array(Set(images.map { Host.storage(of: $0) }))
        return (places, !images.isEmpty)
    }

    /// BitLocker is off by default: decrypted when the volume holding the VM's disk is encrypted
    /// (FileVault, on the startup disk). Otherwise decrypting would leave the disk unencrypted at rest,
    /// so it's asked, and --yes never does it.
    ///
    /// Where the disk is comes from the running QEMU's own arguments; G9 is only offered with Windows
    /// up, so they're there. Without them it falls back to UTM's default folder, on the startup disk,
    /// says the VM could be elsewhere, and still asks, but --yes keeps BitLocker then.
    private static func offerDecryption(_ ctx: Context) -> Bool {
        guard let check = Recipe.check("G9"), let apply = check.apply else { return false }
        let status = ctx.status(of: check)
        guard status.isFixable else { return false }
        print("\n\(status.symbol) G9 BitLocker: \(status.detail)")
        let (places, seen) = whereTheDiskIs(ctx)
        let unprotected = places.filter { Host.encryptedAtRest($0) != true }
        // The words are the deck's, so the setup window's step 3 says exactly this.
        let offer = SetupCopy.BitLocker.offer(places: places, unprotected: unprotected, imagesKnown: seen)
        print("   " + offer.explanation)
        let go: Bool
        if unprotected.isEmpty {
            if !seen && ctx.options.assumeYes {
                // The startup disk is only a guess here, and the message just offered "answer n" to anyone
                // whose VM lives elsewhere; --yes mustn't take that answer away from them.
                print("   Keeping BitLocker on: --yes never weakens encryption at rest, and Winbar can't see where the VM's disk is.")
                go = false
            } else {
                go = Term.confirm(offer.question, assumeYes: ctx.options.assumeYes, defaultYes: offer.defaultYes)
            }
        } else {
            if ctx.options.assumeYes {
                print("   Keeping BitLocker on: --yes never weakens encryption at rest.")
                go = false
            } else {
                go = Term.confirm(offer.question, assumeYes: false, defaultYes: offer.defaultYes)
            }
        }
        guard go else {
            // A person's "no" at the prompt is a choice worth keeping, like --keep-bitlocker.
            if Term.stdinIsTTY && !ctx.options.assumeYes {
                Config.keepBitLocker = true
                print("   Keeping BitLocker; setup won't ask again (winbar config --keep-bitlocker no to be asked).")
            }
            return false
        }
        let started = report(apply(ctx), check, ctx)
        if started { print("   " + SetupCopy.BitLocker.decryptingInBackground) }
        return started
    }

    private static func followDecryption(_ vm: String) {
        print("\nC: is decrypting. Following progress (Ctrl-C is safe: Windows carries on by itself).")
        var last: Int?
        let deadline = Date().addingTimeInterval(3600)
        while Date() < deadline {
            guard VMProcesses.isRunning(vm) else {
                print("   \(vm) stopped; decryption continues when it starts again.")
                return
            }
            switch BitLocker.status(vm: vm) {
            case .failure(let error):
                print("   couldn't read progress: \(error)")
                return
            case .success(let state):
                if state.decrypted {
                    print("   " + Term.paint("✓", .green) + " C: is decrypted.")
                    return
                }
                if state.percent != last {
                    print("   \(state.percent.map { "\($0)%" } ?? "?") still encrypted")
                    last = state.percent
                }
            }
            pause(15)
        }
        print("   Still going after an hour; `winbar doctor` shows where it's got to.")
    }

    // MARK: The single restart

    private static func restartBatch(_ ctx: Context) {
        guard let vm = ctx.vmName, ctx.vm != nil else { return }
        ctx.pending = ConfigChanges()
        for id in restartPass {
            guard let check = Recipe.check(id), let apply = check.apply else { continue }
            let status = ctx.status(of: check)
            guard status.isFixable else { continue }
            print("\n\(status.symbol) \(check.id) \(check.title): \(status.detail)")
            print(Term.paint("   " + check.why, .dim))
            if Term.confirm("Change it? (applied with one restart at the end)", assumeYes: ctx.options.assumeYes) { _ = apply(ctx) }
        }
        offerSharedFolder(ctx)
        decideDisplay(ctx)
        guard !ctx.pending.isEmpty else { return }

        print("\n" + SetupCopy.Finish.oneRestart(of: vm, applies: ctx.pending.summary))
        let interaction = Interaction(
            progress: { Term.note($0) },
            confirmUnverifiedBitLocker: { reason in
                print(reason)
                if ctx.options.assumeYes {
                    print("Not risking the recovery-key screen unattended (--yes). Run setup without --yes to decide.")
                    return false
                }
                return Term.confirm("Carry on anyway?", assumeYes: false)
            },
            offerForceStop: Interaction.askForceStopAtTerminal)
        switch Reconfigure.apply(ctx.pending, to: vm, interaction) {
        case .failure(let error):
            print(Term.paint("✗", .red) + " \(error)")
        case .success(let done) where done.isEmpty:
            print(Term.paint("✓", .green) + " \(vm) already had that; nothing changed.")
        case .success(let done):
            print(Term.paint("✓", .green) + " \(vm) now has \(done.summary).")
            if VMProcesses.isRunning(vm) { waitForWindows(vm) }
            if let folder = done.sharedFolder { settleSharedFolder(folder, vm: vm) }
        }
        ctx.pending = ConfigChanges()
        ctx.refreshAll()
    }

    /// Offers a folder the Mac and Windows both see, once per VM. Nobody is worse off without one, so
    /// this is an offer and never a fix: the folder is created only after a yes, a no is remembered,
    /// and `--yes` doesn't take it. It joins the same restart as the other changes, because UTM hands
    /// a new shared folder to Windows only when it is set while the VM is off.
    private static func offerSharedFolder(_ ctx: Context) {
        guard let check = Recipe.check("G11"), !Config.declinedSharedFolder else { return }
        guard case .success(let existing) = ctx.sharedFolder, existing == nil else { return }
        let status = ctx.status(of: check)
        let path = SharedFolder.defaultFolder()
        let name = SharedFolder.abbreviate(path)
        print("\n\(status.symbol) \(check.id) \(check.title): \(status.detail)")
        print(Term.paint("   " + check.why, .dim))
        print("   \(name) on the Mac would appear in Windows as \(SharedFolder.defaultDrive). " + SharedFolder.worthKnowing)
        print("   " + SharedFolder.restartCost)
        if ctx.options.assumeYes {
            print("   --yes doesn't create folders. To share one: winbar share ~/\(SharedFolder.defaultFolderName)")
            return
        }
        guard Term.confirm("Share \(name) with Windows? (with the other changes, at the end)", assumeYes: false) else {
            Config.declinedSharedFolder = true
            print("   No shared folder; setup won't ask again (winbar share <folder> whenever you like).")
            return
        }
        switch SharedFolder.inspect(path) {
        case .notAFolder:
            print("   " + Term.paint("✗", .red) + " \(name) is a file, not a folder. Share another: winbar share <folder>")
            return
        case .missing:
            if case .failure(let error) = SharedFolder.create(path) {
                print("   " + Term.paint("✗", .red) + " \(error)")
                return
            }
            print("   Created \(name).")
        case .folder:
            break
        }
        ctx.pending.sharedFolder = .folder(path)
    }

    /// Windows is given the folder UTM held at the start before, so the restart that set it isn't
    /// enough on its own. Setup checks from inside Windows and gives it the second start, rather than
    /// ending with a folder that looks set and isn't (see `SharedFolder.settle`).
    private static func settleSharedFolder(_ folder: SharedFolder.Setting, vm: String) {
        let interaction = Interaction(
            progress: { Term.note($0) },
            // settle never asks this: it changes no hardware. No is the safe answer if it ever does.
            confirmUnverifiedBitLocker: { _ in false },
            offerForceStop: Interaction.askForceStopAtTerminal)
        switch SharedFolder.settle(folder, vm: vm, user: Config.rdpUser, interaction) {
        case .failure(let error):
            print("   " + Term.paint("✗", .red) + " \(error)")
        case .success(let checked):
            switch checked.verification {
            case .live:
                print("   " + Term.paint("✓", .green) + " Windows has it: \(checked.drive ?? SharedFolder.defaultDrive)")
            case .stale:
                print("   " + Term.paint("✗", .red) + " Windows is still serving the folder it had before. "
                      + "Restart \(vm) once more (winbar restart), then winbar share to check.")
                print("   " + SharedFolder.durableAdvice)
            case .unknown(let why):
                print("   · Set, but Winbar couldn't check it from inside Windows (\(why)). Run winbar share once Windows is up.")
            }
        }
    }

    /// Headless only when asked for (--headless) or once the person confirms Remote Desktop worked:
    /// C2 can't be verified by machine, and headless without a working connection locks them out
    /// until `winbar display on`.
    private static func decideDisplay(_ ctx: Context) {
        // Fixes and manual steps since the first report (H7's trust, say) may have changed G5, G6, H7
        // and so H5; their cached statuses would hide that.
        ctx.forgetStatuses()
        let headless = ctx.vm?.headless ?? ctx.process?.headless
        switch ctx.options.display {
        case .headless:
            guard headless != true else { return }
            if let g5 = ctx.status(of: "G5"), g5.isManual {
                // Remote Desktop can't sign this account in, and headless leaves nothing else. Only a
                // person at the terminal can take that on, never --yes by itself.
                print("\nG5: \(g5.detail). Remote Desktop can't sign in until that's fixed, so a headless VM would be "
                      + "unreachable (`winbar display on` brings the console back).")
                guard Term.confirm("Go headless anyway?", assumeYes: false) else {
                    print("   Staying with the console window. Fix G5, then run: winbar setup --headless")
                    return
                }
            } else if ctx.status(of: "G6")?.isOK != true {
                print("\nGoing headless as asked, although Remote Desktop isn't confirmed working (G6). `winbar display on` undoes it.")
            }
            ctx.pending.display = .headless
        case .console:
            if headless != false { ctx.pending.display = .console }
        case nil:
            guard let check = Recipe.check("H5") else { return }
            let status = ctx.status(of: check)
            guard status.isFixable else { return }
            print("\n\(status.symbol) H5 \(check.title): \(status.detail)")
            print(Term.paint("   " + check.why, .dim))
            if ctx.options.assumeYes {
                print("   --yes doesn't go headless by itself. Once you've connected, run: winbar setup --headless")
                return
            }
            let host = ctx.rdpHost ?? "the VM"
            guard Term.confirm("Has a Remote Desktop connection to \(host) worked?", assumeYes: false) else {
                print("   Then the console window stays. Connect from the menu (or winbar connect) and run setup again.")
                return
            }
            if Term.confirm("Go headless?", assumeYes: false, defaultYes: true) { ctx.pending.display = .headless }
        }
    }
}
