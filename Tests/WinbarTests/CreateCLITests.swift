import Foundation
import Testing
@testable import Winbar

// `winbar create`'s command line: what it accepts, what it refuses (and with which exit code), the
// checklist screen's rendering and its `?N` explanations, and the dry run's text. All pure: nothing
// here opens a terminal, reads an ISO or talks to UTM.

private let mac = MacFacts(topTierCores: 6, totalCores: 10, memoryBytes: 64 << 30, shortUserName: "alex")

private func parsed(_ arguments: [String]) throws -> CreateCLI.Options {
    switch CreateCLI.parse(arguments) {
    case .success(let options): return options
    case .failure(let refusal): throw refusal
    }
}

private func refusal(_ arguments: [String]) -> CreateCLI.Usage? {
    if case .failure(let refusal) = CreateCLI.parse(arguments) { return refusal }
    return nil
}

@Suite("Arguments")
struct CreateArgumentTests {
    @Test("The defaults: a name, everything ticked, nothing else")
    func defaults() throws {
        let options = try parsed([])
        #expect(options.positional == nil)
        #expect(options.off.isEmpty)
        #expect(!options.dryRun && !options.yes && !options.noSelect && !options.console && !options.verbose)
    }

    @Test("A name, a path and the numbers")
    func values() throws {
        let options = try parsed(["Test VM", "--iso", "/tmp/w.iso", "--cores", "4", "--memory", "12",
                                  "--disk", "256", "--user", "alex", "--computer-name", "TEST-PC"])
        #expect(options.positional == "Test VM")
        #expect(options.iso == "/tmp/w.iso")
        #expect(options.cores == 4)
        #expect(options.memoryGB == 12)
        #expect(options.diskGB == 256)
        #expect(options.user == "alex")
        #expect(options.computerName == "TEST-PC")
    }

    @Test("--flag=value works too")
    func equalsForm() throws {
        let options = try parsed(["--iso=/tmp/w.iso", "--memory=8"])
        #expect(options.iso == "/tmp/w.iso")
        #expect(options.memoryGB == 8)
    }

    @Test("Each --no-… flag turns off exactly its own row")
    func offSwitches() throws {
        let map: [(String, CreateOption)] = [
            ("--no-online-account-bypass", .noOnlineAccount), ("--no-regional", .regionalFromMac),
            ("--no-skip-privacy", .skipPrivacy), ("--allow-bitlocker", .noBitLocker), ("--no-qol", .qol),
            ("--no-autologon", .autologon), ("--no-remote-desktop", .remoteDesktop),
            ("--no-winbar-tuning", .winbarTuning),
        ]
        for (flag, option) in map {
            let options = try parsed([flag])
            #expect(options.off == [option], "\(flag)")
        }
        #expect(try parsed(["--no-visual-tweaks"]).noVisualTweaks)
        #expect(try parsed(["--no-visual-tweaks"]).off.isEmpty)
    }

    @Test("A locked row can't be turned off, and says why")
    func lockedFlags() throws {
        let cases = [("--no-bypass-requirements", "E_LOCKED_BYPASS"), ("--no-local-account", "E_LOCKED_ACCOUNT"),
                     ("--no-guest-tools", "E_LOCKED_GUEST_TOOLS")]
        for (flag, code) in cases {
            let refused = try #require(refusal([flag]))
            #expect(refused.code == code)
            #expect(refused.message.hasPrefix(flag))
        }
    }

    @Test("The password is never a flag, and the refusal says why")
    func noPasswordFlag() throws {
        for flag in ["--password", "--passwordfile", "--password=hunter2"] {
            let refused = try #require(refusal([flag]))
            #expect(refused.code == "E_PW_FLAG")
            #expect(refused.message.contains("shell history"))
        }
        // No flag anywhere takes a password as its value: --password-stdin is a switch naming the pipe
        // the password comes down, and takes none.
        #expect(CreateCLI.valueFlags.allSatisfy { !$0.contains("password") })
        #expect(CreateCLI.switches.keys.filter { $0.contains("password") } == ["--password-stdin"])
    }

    @Test("Unknown options, missing values and two names are refused")
    func refusals() throws {
        #expect(refusal(["--frobnicate"])?.message.contains("unknown option") == true)
        #expect(refusal(["--iso"])?.message.contains("needs a value") == true)
        #expect(refusal(["--dry-run=yes"])?.message.contains("takes no value") == true)
        #expect(refusal(["One", "Two"])?.code == "E_USAGE")
    }

    @Test("--memory takes plain gigabytes")
    func memoryUnit() throws {
        let refused = try #require(refusal(["--memory", "16GB"]))
        #expect(refused.code == "E_MEMORY_UNIT")
        #expect(refused.message == "--memory takes gigabytes, like --memory 16.")
        #expect(refusal(["--cores", "many"])?.code == "E_CORES_RANGE")
        #expect(refusal(["--disk", "128GB"])?.code == "E_DISK_RANGE")
    }

    /// 64 means the command was typed wrong, 65 that a value has to change. A value the
    /// flag parser can't read is the same field problem `CreatePlan.init` catches later, so it gets
    /// the same code rather than one of each.
    @Test("A field's value exits 65, a flag itself exits 64")
    func refusalExitCodes() throws {
        for arguments in [["--memory", "16GB"], ["--cores", "many"], ["--disk", "128GB"]] {
            #expect(refusal(arguments)?.exit == 65, "\(arguments)")
        }
        for arguments in [["--frobnicate"], ["--iso"], ["--no-bypass-requirements"], ["--password", "x"],
                          ["One", "Two"], ["--dry-run=yes"]] {
            #expect(refusal(arguments)?.exit == 64, "\(arguments)")
        }
    }

    @Test("--answer-file-out only makes sense in a dry run")
    func answerFileOut() throws {
        #expect(refusal(["--answer-file-out", "/tmp/x"])?.message.contains("--dry-run") == true)
        #expect(try parsed(["--dry-run", "--answer-file-out", "/tmp/x"]).answerFileOut == "/tmp/x")
    }

    @Test("--window goes to the app's window, and takes nothing else with it")
    func windowFlag() throws {
        #expect(try parsed(["--window"]).window)
        #expect(!(try parsed([]).window))
        for alongside in [["--iso", "/tmp/w.iso"], ["--dry-run"], ["--yes"], ["--resume"], ["Test VM"]] {
            let refused = try #require(refusal(["--window"] + alongside), "\(alongside)")
            #expect(refused.code == "E_USAGE")
            #expect(refused.message.contains("--window"))
        }
    }

    @Test("--cancel needs a name; --resume doesn't")
    func resumeAndCancel() throws {
        #expect(refusal(["--cancel"])?.message == "usage: winbar create --cancel NAME")
        #expect(try parsed(["--cancel", "Windows 11"]).positional == "Windows 11")
        #expect(try parsed(["--cancel", "Windows 11"]).cancel)
        #expect(try parsed(["--resume"]).resume)
        #expect(try parsed(["--resume", "Windows 11"]).positional == "Windows 11")
        #expect(refusal(["--resume", "--cancel", "X"])?.code == "E_USAGE")
    }

    @Test("--iso-sha256 takes a hash, not a word")
    func isoHash() throws {
        let hash = String(repeating: "ab", count: 32)
        #expect(try parsed(["--iso-sha256", hash.uppercased()]).isoSHA256 == hash)
        #expect(refusal(["--iso-sha256", "nope"])?.code == "E_USAGE")
    }

    @Test("Every refusal says something, and names the command or the flag")
    func refusalsAreUsageErrors() {
        let arguments = [["--frobnicate"], ["--no-guest-tools"], ["--memory", "x"], ["--cancel"], ["--iso"],
                         ["--password"], ["A", "B"], ["--answer-file-out", "/tmp"]]
        for argument in arguments {
            let refused = refusal(argument)
            #expect(refused != nil, "\(argument)")
            #expect(refused?.message.isEmpty == false)
        }
    }
}

@Suite("The help text")
struct CreateHelpTests {
    @Test("It fits 100 columns and shows this Mac's numbers")
    func help() {
        let text = CreateCLI.help(mac: mac)
        #expect(text.split(separator: "\n").allSatisfy { $0.count <= 100 })
        #expect(text.contains("here: 6"))       // cores
        #expect(text.contains("here: 16"))      // memory in GB
        #expect(text.contains("here: alex"))
        #expect(text.contains("here: Windows-11"))
        #expect(text.contains("--resume [NAME]"))
        // The way to the window, in the "other:" group.
        #expect(text.contains("  --window              fill the plan in Winbar's own window instead of here"))
        #expect(text.contains(GuestTools.version))
    }

    /// The help may name the pipe (--password-stdin), but must never show a way to put the password
    /// itself on the command line, where every process on the Mac can read it.
    @Test("It never suggests a way to pass the password as a value")
    func noPasswordFlag() {
        let text = CreateCLI.help(mac: mac)
        #expect(!text.contains("--password ") && !text.contains("--password="))
        #expect(!text.contains("--password PASSWORD") && !text.contains("WINBAR_PASSWORD"))
        #expect(text.contains("--password-stdin"))
    }
}

@Suite("The checklist screen")
struct ChecklistTests {
    private func screen(_ plan: CreatePlan = testPlan(), reading: Regional.Reading? = nil) -> Checklist {
        Checklist(plan: plan, image: testImage(), mac: mac, reading: reading)
    }

    @Test("Thirteen rows, in Rufus's order then Winbar's")
    func rows() {
        #expect(Checklist.rows.count == 13)
        #expect(Checklist.row(1) == .option(.bypassRequirements))
        #expect(Checklist.row(3) == .user)
        #expect(Checklist.row(6) == .edition)
        #expect(Checklist.row(11) == .option(.guestTools))
        #expect(Checklist.row(13) == .computerName)
        #expect(Checklist.row(0) == nil)
        #expect(Checklist.row(14) == nil)
    }

    @Test("The locked rows are the three that can't be turned off, plus the account and the edition")
    func locked() {
        #expect(Checklist.isLocked(.option(.bypassRequirements)))
        #expect(Checklist.isLocked(.user))
        #expect(Checklist.isLocked(.edition))
        #expect(Checklist.isLocked(.option(.guestTools)))
        #expect(!Checklist.isLocked(.option(.qol)))
        #expect(!Checklist.isLocked(.computerName))
    }

    @Test("The screen shows the VM's fields, every row with its box, and the two headings")
    func render() {
        let text = screen().render()
        #expect(text.hasPrefix("New Windows VM"))
        #expect(text.contains("  n  Name      Windows 11"))
        #expect(text.contains("  c  vCPUs     6        your Mac's top-tier cores"))
        #expect(text.contains("  m  Memory    16 GB    recommended for a Mac with 64 GB"))
        #expect(text.contains("  d  Disk      128 GB   the file grows as Windows uses it"))
        #expect(text.contains("Windows User Experience: customize Windows installation?"))
        #expect(text.contains("\nWinbar\n"))
        #expect(text.contains("   1 [x] Remove requirement for 4GB+ RAM, Secure Boot and TPM 2.0"))
        #expect(text.contains("   3 [x] Create a local account with username: alex"))
        #expect(text.contains("   6 [x] Install on the VM's new, empty disk: Windows 11 Pro"))
        #expect(text.contains("  10 [x] Turn on Remote Desktop (with Network Level Authentication)"))
        #expect(text.contains("  13     Computer name: Windows-11 (your Mac reaches it as windows-11.local)"))
        #expect(text.hasSuffix("Type a number or letter to change it, ? and a number for why (?7), Enter to go, q to quit:"))
    }

    @Test("A row that's off shows an empty box")
    func unticked() {
        var plan = testPlan()
        plan.options.remove(.qol)
        let text = screen(plan).render()
        #expect(text.contains("   8 [ ] Don't force Copilot"))
        #expect(text.contains("   7 [x] Disable BitLocker"))
    }

    @Test("Locked rows say so, and only locked ones do")
    func alwaysOn() {
        let lines = screen().render().split(separator: "\n").filter { $0.contains("always on") }
        #expect(lines.count == 4)
        #expect(lines.allSatisfy { line in ["   1 ", "   3 ", "   6 ", "  11 "].contains(where: line.hasPrefix) })
    }

    @Test("Row 4 shows what the Mac's region becomes in Windows")
    func regionLine() {
        let reading = Regional.reading(macLocale: "en_GB", keyboard: Regional.keyboard(currentLayoutID: nil, selectedSources: []),
                                       ianaZone: "Europe/London", imageLanguage: "en-US")
        let text = screen(testPlan(), reading: reading).render()
        #expect(text.contains("Europe/London → GMT Standard Time"))
        #expect(Checklist.regionSummary(reading).contains("English (United Kingdom)"))
    }

    @Test("?N explains a row, and every row has an explanation")
    func tooltips() {
        for number in 1...Checklist.rows.count {
            let tooltip = Checklist.tooltip(String(number), plan: testPlan(), mac: mac)
            #expect(tooltip?.isEmpty == false, "row \(number)")
        }
        for key in ["n", "c", "m", "d"] {
            #expect(Checklist.tooltip(key, plan: testPlan(), mac: mac)?.isEmpty == false)
        }
        #expect(Checklist.tooltip("99", plan: testPlan(), mac: mac) == nil)
        #expect(Checklist.tooltip("x", plan: testPlan(), mac: mac) == nil)
    }

    @Test("The tooltips carry the security review's corrections (D4)")
    func correctedTooltips() throws {
        let autologon = CreateCopy.tooltip(.autologon)
        #expect(autologon.contains("LSA secret: not plain text"))
        #expect(autologon.contains("copy of the VM's disk"))
        #expect(autologon.contains("your Mac account and its backups"))
        #expect(!autologon.contains("as private as your Mac account is"))

        #expect(CreateCopy.tooltip(.bypassRequirements).contains("unsupported device"))
        #expect(CreateCopy.tooltip(.skipPrivacy).contains("required"))
        #expect(CreateCopy.tooltip(.noBitLocker).contains("Allow BitLocker without a compatible TPM"))
        #expect(CreateCopy.tooltip(.guestTools).contains("SYSTEM"))
        #expect(CreateCopy.tooltip(.remoteDesktop).contains("other VMs on that network"))
        #expect(CreateCopy.tooltip(.localAccount).contains("offline"))
        #expect(!CreateCopy.tooltip(.localAccount).contains("plain text"))
    }

    @Test("The password copy tells the truth about where it ends up")
    func passwordCopy() {
        let block = CreateCopy.beforePassword(fileVaultOn: true).joined(separator: " ")
        #expect(block.contains("Pick a password you don't use for your Mac or anywhere else."))
        #expect(block.contains("LSA secret"))
        #expect(block.contains("https://www.microsoft.com/useterms"))
        #expect(!block.contains("Winbar deletes those copies"))
    }

    /// One sentence, one source: Terminal and the window said different things about the answer-file
    /// copies inside Windows, and the window's was the accurate one.
    @Test("Both front-ends describe the copies inside Windows in the same words")
    func onePantherSentence() {
        #expect(CreateCopy.nPWLong.contains(CreateCopy.nPWPanther))
        #expect(CreateCopy.beforePassword(fileVaultOn: true).joined(separator: " ").contains(CreateCopy.nPWPanther))
        #expect(CreateCopy.nPWPanther.contains("deletes any copy that still holds one"))
        #expect(!CreateCopy.beforePassword(fileVaultOn: true).joined(separator: " ").contains("Winbar checks that it did"))
        // D4's LSA wording is written once too, and quoted by the tooltip and by both password notes.
        #expect(CreateCopy.tooltip(.autologon).contains(CreateCopy.lsaSecret))
        #expect(CreateCopy.nPWLong.contains(CreateCopy.lsaSecret))
    }

    /// N_PW_FILEVAULT_OFF is what might change which password is chosen, so it goes above the
    /// prompt, not into the stage-1 notes underneath it.
    @Test("With FileVault off, the caveat is read before the password is typed")
    func fileVaultCaveatComesFirst() throws {
        let off = CreateCopy.beforePassword(fileVaultOn: false)
        let note = try #require(off.firstIndex(of: CreateCopy.nPWFileVaultOff))
        let licence = try #require(off.firstIndex { $0.contains("useterms") })
        #expect(note < licence)
        #expect(!CreateCopy.beforePassword(fileVaultOn: true).contains(CreateCopy.nPWFileVaultOff))
        #expect(!CreateCopy.beforePassword(fileVaultOn: nil).contains(CreateCopy.nPWFileVaultOff))
        // And the job's own copy of it isn't printed a second time by the progress lines.
        let raised = [CreateMessage(code: "N_PW_FILEVAULT_OFF", text: CreateCopy.nPWFileVaultOff, at: Date()),
                      CreateMessage(code: "W_BATTERY", text: "Your Mac is on battery.", at: Date())]
        #expect(CreateProgressPrinter.newMessages(raised, printed: 0, said: ["N_PW_FILEVAULT_OFF"]).map(\.code)
                == ["W_BATTERY"])
        #expect(CreateProgressPrinter.newMessages(raised, printed: 0, said: []).count == 2)
        #expect(CreateProgressPrinter.newMessages(raised, printed: 2, said: []).isEmpty)
    }

    @Test("A tooltip mentions the row it belongs to, not a password")
    func tooltipsHaveNoSecrets() {
        for option in CreateOption.allCases {
            #expect(!CreateCopy.tooltip(option).lowercased().contains("type your password here"))
        }
    }
}

@Suite("The dry run")
struct DryRunTests {
    private func text(plan: CreatePlan = testPlan(), reading: Regional.Reading? = nil,
                      guestTools: GuestTools.Copy? = nil, onBattery: Bool = false,
                      space: CreatePreflight.Space = .init(volume: "Macintosh HD", freeBytes: 412 << 30),
                      warnings: [String] = []) -> String {
        CreateCLI.dryRunText(plan: plan, image: testImage(), mac: mac, reading: reading, utmVersion: "4.7.5",
                             space: space, fileVault: true, onBattery: onBattery, guestTools: guestTools,
                             warnings: warnings)
    }

    @Test("It lays out the plan and the checks, and fits 100 columns")
    func layout() {
        let output = text()
        #expect(output.hasPrefix("The plan\n"))
        #expect(output.contains("  VM          “Windows 11” in UTM 4.7.5: 6 vCPUs, 16 GB memory, 128 GB disk (NVMe)"))
        #expect(output.contains("  Windows     Windows 11 Pro (image 3 of 3), build 26200.8037"))
        #expect(output.contains("  Account     alex, local administrator; password asked for when you run it for real"))
        #expect(output.contains("  Computer    Windows-11, reached from your Mac as windows-11.local"))
        #expect(output.contains("\nChecks\n"))
        #expect(output.contains("✓ Windows 11 Arm64 installer, no answer file of its own"))
        #expect(output.contains("✓ 442 GB free on Macintosh HD (installing needs 40 GB)"))
        #expect(output.contains("✓ UTM 4.7.5"))
        #expect(output.contains("· FileVault is on"))
        #expect(output.hasSuffix("To do it for real, run the same command without --dry-run."))
        #expect(output.split(separator: "\n").allSatisfy { $0.count <= 100 })
    }

    @Test("The checklist prints its ids in three columns, ticked or not")
    func checklistGrid() {
        var plan = testPlan()
        plan.options.remove(.qol)
        let grid = CreateCLI.checklistGrid(plan.options)
        let lines = grid.split(separator: "\n").map(String.init)
        #expect(lines.count == 4)
        #expect(lines[0] == "[x] bypass_requirements   [x] no_online_account   [x] local_account")
        #expect(lines[1] == "[x] regional_from_mac     [x] skip_privacy        [x] no_bitlocker")
        #expect(lines[2] == "[ ] qol                   [x] autologon           [x] remote_desktop")
        #expect(lines[3] == "[x] guest_tools           [x] winbar_tuning")
        #expect(text(plan: plan).contains("[ ] qol"))
    }

    @Test("It says the Guest Tools have to be downloaded, or that they're already here")
    func guestTools() {
        #expect(text().contains("to download, \(GuestTools.size >> 20) MB"))
        let cached = GuestTools.Copy(url: URL(fileURLWithPath: "/tmp/utm-guest-tools.exe"), downloadedAt: Date())
        #expect(text(guestTools: cached).contains("already in"))
        // D1: one CD carries both the answer file and the installer, so there is no tools ISO.
        #expect(!text().contains("Guest Tools ISO"))
        #expect(text().contains("WINBAR_SETUP, which carries UTM Guest Tools"))
    }

    @Test("Battery, low space and other warnings show as their own lines")
    func warnings() {
        #expect(text(onBattery: true).contains("! Your Mac is on battery. Plug in before the real run."))
        #expect(!text().contains("on battery"))
        #expect(text(warnings: ["Windows Home cannot host Remote Desktop"]).contains("! Windows Home cannot host"))
        let tight = CreatePreflight.Space(volume: "Macintosh HD", freeBytes: 20 << 30)
        #expect(text(space: tight).contains("✗ 21 GB free on Macintosh HD"))
    }

    @Test("It always says what it couldn't check without starting UTM")
    func notChecked() {
        #expect(text().contains("Not checked in a dry run: whether UTM already has a VM called “Windows 11”"))
    }

    @Test("--console changes what it says about the window")
    func console() {
        var plan = testPlan()
        plan.keepConsole = true
        #expect(text(plan: plan).contains("and afterwards (--console)"))
        #expect(text().contains("then Winbar takes it headless"))
    }

    @Test("--no-select says Winbar won't take the new VM over")
    func noSelect() {
        var plan = testPlan()
        plan.select = false
        #expect(text(plan: plan).contains("--no-select"))
        #expect(text().contains("Winbar looks after “Windows 11”"))
    }
}

@Suite("Wrapping and other small things")
struct CreateCopyTests {
    @Test("Wrapping keeps lines inside the width and indents the rest")
    func wrap() {
        let text = CreateCopy.wrap(String(repeating: "word ", count: 40).trimmingCharacters(in: .whitespaces),
                                   width: 40, indent: "  ")
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.count > 1)
        #expect(lines.allSatisfy { $0.count <= 42 })
        #expect(lines.dropFirst().allSatisfy { $0.hasPrefix("  ") })
        #expect(!lines[0].hasPrefix(" "))
    }

    @Test("A word longer than the width isn't cut in half")
    func longWord() {
        let url = "https://example.com/" + String(repeating: "x", count: 60)
        #expect(CreateCopy.wrap(url, width: 40) == url)
    }

    @Test("Line breaks in the copy are kept")
    func keepsBreaks() {
        #expect(CreateCopy.wrap("one\ntwo", width: 40).split(separator: "\n").count == 2)
    }

    @Test("Stage titles and numbers are the ten the install is divided into")
    func stages() {
        #expect(CreateStage.allCases.count == 10)
        #expect(CreateStage.check.number == 1)
        #expect(CreateStage.finish.number == 10)
        #expect(CreateStage.copy.runningTitle == "Windows Setup: copying files")
        #expect(CreateStage.copy.doneTitle == "Windows Setup copied its files")
        #expect(CreateStage.guestTools.runningTitle.contains(GuestTools.version))
        #expect(CreateStage.allCases.allSatisfy { !$0.shortTitle.isEmpty })
        #expect(!CreateStage.media.isInstalling)
        #expect(CreateStage.boot.isInstalling)
    }

    @Test("A job is described as the person would say it")
    func describe() {
        let state = testState(stage: .copy)
        let text = CreateJob.describe(state)
        #expect(text.hasPrefix("“Windows 11” (copying files, started "))
    }
}

@Suite("The plan the flags ask for")
struct CreatePlanFromFlagsTests {
    private let homeOnly = testImage(editions: [testEdition("Windows 11 Home", id: "Core", index: 1),
                                                testEdition("Windows 11 Home Single Language",
                                                            id: "CoreSingleLanguage", index: 2)])

    private func plan(_ options: CreateCLI.Options, image: WindowsImageInfo = testImage()) throws -> CreatePlan {
        try CreatePlan(options: options, image: image, mac: mac, isoPath: "/tmp/w.iso", reading: nil)
    }

    /// Home is only ever installed when it was chosen, and `--yes` chooses nothing: it would
    /// otherwise spend 40 minutes installing an edition Connect can never reach (E_HOME_ONLY).
    @Test("--yes on a Home-only ISO refuses instead of installing Home")
    func homeOnlyUnderYes() throws {
        var yes = CreateCLI.Options()
        yes.yes = true
        let refused = try #require(throws: CreateJobError.self) { try plan(yes, image: homeOnly) }
        #expect(refused.failure.code == "E_HOME_ONLY")
        #expect(refused.exitCode == 65)
        #expect(refused.failure.title == CreateCopy.eHomeOnly)
        #expect(refused.failure.nextStep?.contains("--edition \"Windows 11 Home\"") == true)

        // Named, it installs: the person chose it.
        yes.edition = "Home"
        #expect(try plan(yes, image: homeOnly).edition.isHome)
        // Without --yes the checklist is there to ask at Enter, so the plan is built as it stands.
        var asked = CreateCLI.Options()
        asked.yes = false
        #expect(try plan(asked, image: homeOnly).edition.isHome)
        // An ISO with Pro on it is never a Home-only ISO.
        #expect(try plan(yes.with { $0.edition = nil }).edition.editionID == "Professional")
    }

    /// The checklist prints these as they apply; a run that skips it prints the same list, so
    /// neither route installs Home, or a VM bigger than the Mac, without saying so.
    @Test("A plan's own warnings are one list, wherever they're printed")
    func planWarnings() throws {
        #expect(CreateCLI.planWarnings(testPlan(), mac: mac).isEmpty)
        let home = testPlan(edition: testEdition("Windows 11 Home", id: "Core", index: 1))
        #expect(CreateCLI.planWarnings(home, mac: mac).map(\.description) == [ChoiceWarning.home.description])
        var big = testPlan()
        big.cores = 10
        big.memoryMiB = 60 << 10
        let warned = CreateCLI.planWarnings(big, mac: mac)
        #expect(warned.count == 2)
        #expect(warned.first?.description == CreateChoices.coresWarning(10, mac: mac)?.description)
        var small = testPlan()
        small.memoryMiB = 4 << 10
        #expect(CreateCLI.planWarnings(small, mac: mac).map(\.description)
                == CreateChoices.memoryWarnings(4, mac: mac).map(\.description))
    }
}

@Suite("Cancelling from the command line")
struct CreateCancelLinesTests {
    private func result(_ build: (inout CreateCancelResult) -> Void) -> CreateCancelResult {
        var done = CreateCancelResult(state: testState(outcome: .cancelled))
        build(&done)
        return done
    }

    /// The ✓ lines say what the cancel did, not what a cancel usually does: it used to claim it had
    /// stopped and deleted a VM that UTM no longer had.
    @Test("It reports the steps that happened")
    func lines() {
        let all = result {
            $0.stopped = true
            $0.deletedVM = true
            $0.deletedSetupDisk = true
        }
        #expect(CreateCLI.cancelLines(all, name: "Windows 11")
                == ["✓ Stopped the VM", "✓ Deleted the VM in UTM", "✓ Deleted the setup disk"])

        let notRunning = result {
            $0.deletedVM = true
            $0.deletedSetupDisk = true
        }
        #expect(!CreateCLI.cancelLines(notRunning, name: "Windows 11").contains("✓ Stopped the VM"))

        let gone = result {
            $0.vmGone = true
            $0.deletedSetupDisk = true
        }
        let lines = CreateCLI.cancelLines(gone, name: "Windows 11")
        #expect(lines.first == "· “Windows 11” is no longer in UTM, so there was nothing to stop or delete there.")
        #expect(!lines.contains { $0.contains("Deleted the VM in UTM") })
        #expect(lines.contains("✓ Deleted the setup disk"))

        let kept = result {
            $0.stopped = true
            $0.removedInstallDisks = true
            $0.deletedSetupDisk = true
        }
        #expect(CreateCLI.cancelLines(kept, name: "Windows 11").contains("✓ Removed the install disks from the VM"))

        // A job that had already lost both: it is closed, and silence would read as nothing having run.
        #expect(CreateCLI.cancelLines(result { _ in }, name: "Windows 11")
                == ["· There was nothing left to stop or delete. The install is closed."])
    }
}

private extension CreateCLI.Options {
    /// A copy with one thing changed, for a test that varies a single flag.
    func with(_ change: (inout CreateCLI.Options) -> Void) -> CreateCLI.Options {
        var copy = self
        change(&copy)
        return copy
    }
}

@Suite struct PasswordFromStdin {
    /// A scripted install pipes the password in, so it is never in an argument or the environment,
    /// which every process on the Mac can read. Everything up to the first newline is the password.
    @Test func parsesTheFlag() {
        let parsed = try? CreateCLI.parse(["winbar-test", "--yes", "--password-stdin"]).get()
        #expect(parsed?.passwordStdin == true)
        #expect((try? CreateCLI.parse(["winbar-test"]).get())?.passwordStdin == false)
    }
}
