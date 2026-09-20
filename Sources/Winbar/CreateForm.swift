import Combine
import Foundation

// Everything the New Windows VM window says and decides, with no view in sight. The views in
// CreateWindow.swift and CreateProgressView.swift read this and nothing else, so the rules — which
// field blocks Create, what the status line reads, how the computer name follows the VM name — are
// testable without a screen.
//
// Strings are the copy deck, worded to be exact about the password's life, the TPM's consequences,
// what Remote Desktop exposes, and what the guest agent can do. There is one deck, `CreateCopy`:
// this half holds the keys both front-ends share, and CreateCLI.swift's half the lines only Terminal
// says. Neither front-end keeps a second copy of a string.

/// The copy deck, keyed as the deck keys it. The window and the CLI both read it; the
/// other half of the enum is in CreateCLI.swift.
extension CreateCopy {
    // Window, headings, buttons
    static let winTitle = "New Windows VM"
    static let menuNew = "New Windows VM…"
    static let menuProgress = "Show Install Progress…"
    static let hImage = "Windows image"
    static let hVM = "Virtual machine"
    static let hWUE = "Windows User Experience"
    static let hWUESub = "Customize Windows installation?"
    static let hWinbar = "Winbar"
    static let isoDrop = "Drop a Windows 11 Arm64 ISO here, or"
    static let isoChoose = "Choose…"
    static let isoChange = "Change…"
    static let isoGet = "Don't have one? Get it from Microsoft ↗"
    static let isoGetURL = "https://www.microsoft.com/software-download/windows11arm64"
    static let isoReading = "Reading the ISO…"
    static let nISOKeep = "Keep the ISO where it is until Windows finishes installing."
    static let lName = "Name"
    static let lCores = "vCPUs"
    static let lMemory = "Memory"
    static let lDisk = "Disk"
    static let lPassword = "Password"
    static let lConfirm = "Confirm"
    static let lComputer = "Computer name"
    static let lAlwaysOn = "Always on"
    static let lNotOnHome = "Not available on Home"
    static let lSelect = "Use this VM in Winbar's menu"
    static let lMore = "More…"
    static let bCancel = "Cancel"
    static let bCreate = "Create"
    static let bShowVM = "Show VM Window"
    static let bCancelInstall = "Cancel Install…"
    static let bHide = "Hide"
    static let bCopy = "Copy"
    static let bDone = "Done"
    static let bShowLog = "Show Log"
    static let bTryAgain = "Try Again"
    static let bDeleteVM = "Delete VM…"
    static let bClose = "Close"
    static let bKeepInstalling = "Keep Installing"
    /// The destructive button in the cancel alert, where there is no room for a second "…".
    static let bDeleteVMNow = "Delete VM"
    static let pFooter = "Usually about 10 minutes on a fast Mac, longer on an older one. You don't need to watch or "
        + "click anything, and you can close this "
        + "window: Winbar carries on, and the menu bar shows how it's going."
    static let pFooterCLI = "Running in Terminal. Closing this window doesn't affect it."
    static let pAutomation = "macOS is asking whether Winbar can control UTM. Choose Allow."
    /// The Automation detail, which the job writes while macOS's prompt is up. In Terminal the
    /// app macOS asks about is the terminal, so the line names it; the window knows it is always
    /// Winbar and swaps the line for pAutomation, finding it by `automationDetailMark`.
    static func automationDetail(app: String) -> String { "Waiting for you to allow \(app) to control UTM…" }
    static let automationDetailMark = "control UTM"
    static let fNeedISO = "Choose a Windows 11 Arm64 ISO."
    static let fReady = "Ready. About 10 minutes on a fast Mac, with no clicking."
    /// The licence terms are a link, so the text is Markdown.
    static let fLicence = "Creating the VM accepts Microsoft's [Windows licence terms](https://www.microsoft.com/useterms), "
        + "which Setup would otherwise show you."

    static func isoSummary(build: Int, language: String) -> String {
        let release: String
        switch build {
        case 26100: release = "24H2"
        case 26200: release = "25H2"
        default: release = "build \(build)"
        }
        let name = Locale.current.localizedString(forIdentifier: language) ?? language
        return "Windows 11 \(release) · Arm64 · \(name)"
    }

    static func fNeedPassword(user: String) -> String { "Type a password for \(user)." }

    static func lComputerHost(_ host: String) -> String { "your Mac reaches it as \(host)" }

    static func pHeader(edition: String, name: String) -> String { "Installing \(edition) in “\(name)”" }

    /// The good ending, which Terminal writes after a ✓ with how long it took, and the window
    /// as its heading, with the time in its own column.
    static func installed(edition: String, name: String, took: String? = nil) -> String {
        "\(edition) is installed in “\(name)”" + (took.map { " (\($0))" } ?? "")
    }

    /// E_RESULT_FAILED's ending: Windows is installed, so the line says so before the problem.
    static func installedWithProblems(edition: String, name: String, took: String? = nil) -> String {
        installed(edition: edition, name: name, took: took) + ", with problems"
    }

    static func pStep(_ n: Int) -> String { "step \(n) of 10" }

    /// The heading above the command on the Done screen; the command itself is `setupCommand`.
    static let nNextCommand = "One more step, about 5 minutes, in Terminal:"

    /// What to run next, worked out from the plan rather than assumed: with the new VM left
    /// unselected (`--no-select`, or the window's "Use this VM in Winbar's menu" unticked) Winbar's
    /// menu still looks after the old one, so setup has to be told which VM this is about. Both
    /// front-ends show this, and the window's Copy button copies it.
    static func setupCommand(plan: CreatePlan) -> String {
        plan.select ? "winbar setup" : "winbar setup --vm \"\(plan.vmName)\""
    }

    // The cancel alert, and how the window says what a cancel did.
    static let cancelTitle = "Cancel installing Windows?"
    static func cancelBody(name: String) -> String {
        "Winbar stops “\(name)” and deletes it, with its disk and the setup disk. Nothing of yours is in it yet. "
            + "Your Windows ISO isn't touched."
    }
    static func cancelledHeader(name: String) -> String { "Cancelled installing Windows in “\(name)”" }
    static let cancelledNote = "The VM and its setup disk are gone. Your Windows ISO isn't touched."
    /// The VM had already gone from UTM by the time the cancel ran, so only the Mac's side was left.
    static func nCancelVMGone(name: String) -> String {
        "Cancelled installing Windows. “\(name)” was no longer in UTM, so Winbar deleted only its setup disk."
    }

    /// The alerts the window shows for what it can't put in the job view: a refusal before anything
    /// was created, and a cancel that couldn't be done.
    static let eCouldntStart = "Couldn't start installing Windows"
    static let eCouldntCancel = "Couldn't cancel the install"
    /// The failure view's heading when the job ended badly without saying how.
    static let eStopped = "Installing Windows stopped"

    // Checklist labels
    static func label(_ option: CreateOption) -> String {
        switch option {
        case .bypassRequirements: return "Remove requirement for 4GB+ RAM, Secure Boot and TPM 2.0"
        case .noOnlineAccount: return "Remove requirement for an online Microsoft account"
        case .localAccount: return "Create a local account with username:"
        case .regionalFromMac: return "Set regional options to the same values as this Mac's"
        case .skipPrivacy: return "Disable data collection (Skip privacy questions)"
        case .noBitLocker: return "Disable BitLocker automatic device encryption"
        case .qol: return "Don't force Copilot, OneDrive, Outlook, Fast Startup, etc."
        case .autologon: return "Sign in automatically at startup"
        case .remoteDesktop: return "Turn on Remote Desktop (with Network Level Authentication)"
        case .guestTools: return "Install UTM Guest Tools (drivers + guest agent)"
        case .winbarTuning: return "Apply Winbar's performance tuning after install"
        }
    }

    /// Row 6, which isn't a `CreateOption`: it's always on and carries the edition pop-up.
    static let installLabel = "Install on the VM's new, empty disk:"

    // Tooltips. These are also the VoiceOver hints: a tooltip alone is hover-only, and someone using
    // VoiceOver would never hear why a row is locked.
    static func tooltip(_ option: CreateOption) -> String {
        switch option {
        case .bypassRequirements:
            return "Always on: UTM can't add a TPM to a VM it creates by script, so without this Windows Setup would stop "
                + "with “This PC can't run Windows 11”. It only skips Setup's checks; Windows still uses all the memory "
                + "and vCPUs you give it. The VM simply has no TPM, so features that need one (like TPM-protected "
                + "BitLocker) aren't available, Microsoft treats it as an unsupported device, and a future yearly "
                + "feature update may need the ISO again. You can add a TPM later in UTM's settings for the VM."
        case .noOnlineAccount:
            return "The VM has no network while Windows installs (its network driver comes with the UTM Guest Tools, "
                + "afterwards) and Winbar creates your account itself, so Windows won't ask for a Microsoft account. "
                + "This also sets the switch Rufus uses, which Windows 11 25H2 ignores, so today it changes nothing you "
                + "can see. Unticked, only that switch is left out. You can still sign in to the Store, OneDrive and "
                + "other apps with a Microsoft account later."
        case .localAccount:
            return "Always on. Winbar creates a local administrator account with the password you type here. Unlike "
                + "Rufus, the password isn't blank and you aren't made to change it at first sign-in: Remote Desktop "
                + "refuses blank passwords, and nobody's at the screen to change it. Winbar needs a local account "
                + "because a Windows Hello PIN never works over Remote Desktop, and because the install runs offline, "
                + "so there's no Microsoft account to sign in with — signing in to one automatically would mean "
                + "storing that account's password in the VM as well."
        case .regionalFromMac:
            return "Copies this Mac's region (date, time, number and currency formats), keyboard layout and time zone, "
                + "so Windows doesn't need to ask. Windows' display language stays the ISO's. Unticked, nobody's there "
                + "to answer, so Windows uses the ISO's defaults; change them later in Settings > Time & language."
        case .skipPrivacy:
            return "Answers “no” to the privacy questions Windows asks while it sets up (optional diagnostic data, "
                + "location, tailored experiences and similar). It only answers the optional ones: Windows still sends "
                + "its required diagnostic data unless “Apply Winbar's performance tuning”, which turns DiagTrack off, "
                + "is ticked. Unticked, nobody's there to answer them, so Windows turns on its recommended settings "
                + "instead. You can change each one later in Settings > Privacy & security."
        case .noBitLocker:
            return "Makes sure Windows doesn't encrypt its disk by itself (without a TPM it's unlikely to, but Windows' "
                + "rules change). The VM's disk is a file on your Mac, which FileVault encrypts when it's on, and "
                + "BitLocker on top slows the disk down. You can still turn BitLocker on yourself later; without a TPM "
                + "that needs the “Allow BitLocker without a compatible TPM” policy and a startup password at every boot."
        case .qol:
            return "Rufus's “quality of life” set: no Copilot button, OneDrive, Outlook or Teams apps pushed at you, no "
                + "Fast Startup, no web results or suggestions in Start and Search, no news feed, no Edge welcome tour. "
                + "Unticked, Windows keeps its own defaults. Most of it can be undone in Settings; OneDrive is blocked "
                + "by a policy (the README says how to lift it)."
        case .autologon:
            return "Windows signs in to your account by itself when the VM starts, so it boots straight to your desktop "
                + "and your Remote Desktop connection takes over that same session: anything started at boot keeps "
                + "running. " + lsaSecret + " Anyone who can open the VM's window on your Mac lands on the desktop, so "
                + "the VM is as private as your Mac account and its backups. Unticked, Windows signs in once to finish "
                + "setting up, then shows its sign-in screen."
        case .remoteDesktop:
            return "Turns on Remote Desktop with Network Level Authentication (Windows checks your password before it "
                + "starts a session), enables its firewall rules and keeps blank-password network sign-ins blocked. "
                + "It's how Winbar's Connect reaches Windows; in UTM's Shared Network mode, your Mac and other VMs on "
                + "that network can reach it. The firewall rules are on for every profile, so putting the VM on "
                + "Bridged networking later exposes it to your whole network. Needs Pro, Enterprise or Education. "
                + "Unticked, Connect won't work until winbar setup turns it on."
        case .guestTools:
            return "Always on. UTM's drivers for the VM's network, disks, display and memory, and the QEMU guest agent, "
                + "which is how Winbar talks to Windows: to see when setup has finished, to shut Windows down properly "
                + "and to check its settings. The agent runs as SYSTEM, so anything on your Mac that can drive UTM can "
                + "run commands in Windows with full rights. Without them Windows has no network at all. Winbar "
                + "downloads version \(GuestTools.version) from UTM's releases on GitHub and checks its SHA-256 first."
        case .winbarTuning:
            return "Does what winbar setup would do inside Windows, straight away: Balanced power plan with a fast "
                + "ramp-up, display off after 5 minutes, no sleep or hibernation, power button = Shut down, SysMain, "
                + "Windows Search indexing and telemetry (DiagTrack) off, and fewer animations and less transparency. "
                + "Each was measured; the README has the numbers. Unticked, setup offers them later."
        }
    }

    static let installTooltip = "Always on. Rufus warns that this erases a disk without asking; here the only disk is "
        + "the VM's new, empty one, so nothing of yours can be erased. Choose the edition to install: Pro is the "
        + "default, and what Winbar needs for Remote Desktop."
    static let vmNameTooltip = "The name UTM shows for the VM, and what winbar commands call it (--vm)."
    static func coresTooltip(topTier: Int) -> String {
        "Winbar suggests your Mac's top-tier core count (\(topTier) here), kept between 4 and 8: in testing, more "
            + "vCPUs cost extra host CPU without being faster."
    }
    static func memoryTooltip(suggested: Int) -> String {
        "Suggested: \(suggested) GB (16 GB on a Mac with 64 GB or more, 12 GB from 32 GB, otherwise 8 GB, never more "
            + "than half your Mac's memory)."
    }
    static let diskTooltip = "The disk is a file that grows as Windows uses it, up to this size. Windows 11 needs at "
        + "least 64 GB. Making it bigger later takes both UTM and Windows' Disk Management, so leave room."
    static let passwordTooltip = "The password for your Windows account. Winbar also saves this PC in Windows App with "
        + "it, so Connect doesn't ask you for it again."
    static func computerTooltip(host: String) -> String {
        "The VM's name on the network. Your Mac reaches it as \(host), and that's the name Windows App and the VM's "
            + "Remote Desktop certificate use. Up to 15 letters, digits and hyphens, not only digits, and not the same "
            + "as the user name."
    }

    // Notes. N_PW_SHORT carries the "don't reuse it" line.
    //
    // The three sentences below are written once and quoted wherever the password's life is
    // described — the tooltip, N_PW_LONG and Terminal's block before the prompt — so the two
    // front-ends can't drift into describing the same thing differently.

    /// D4's wording, verbatim, wherever automatic sign-in's password store is described.
    static let lsaSecret = "Windows stores it as an LSA secret: not plain text, but anyone with admin rights in "
        + "Windows, or with a copy of the VM's disk (backups, exports), can recover it, because BitLocker is off."
    /// The same sentence where automatic sign-in isn't the subject of the paragraph.
    static let nPWLSA = "For automatic sign-in, " + lsaSecret
    /// What happens to Setup's own copy of the answer file inside Windows. Both halves are real:
    /// Setup blanks its copy, and Winbar's first sign-in step sweeps `%WINDIR%\Panther` and
    /// `$WINDOWS.~BT` and deletes any copy that still holds an open password (W_PANTHER reports what
    /// it had to leave).
    static let nPWPanther = "Inside Windows, Setup blanks the password in its own copy of the answer file, and "
        + "Winbar's first sign-in step deletes any copy that still holds one."
    /// D4's line, on the short note and in Terminal's block before the prompt.
    static let nPWNotYours = "Pick a password you don't use for your Mac or anywhere else."

    static let nPWShort = "The password goes into Windows' answer file, scrambled but not encrypted, until Windows is "
        + "installed. " + nPWNotYours

    // The saved PC in Windows App. Raised while the answer file is still being made,
    // which is the moment the password is already committed to disk and the last moment Winbar still
    // has it: holding it in memory for the rest of a 30-minute install to save two seconds of work
    // would be the wrong trade, and a saved PC is only a record — Windows App never checks that the
    // host exists yet.

    /// N_PC_SAVED.
    static func nPCSaved(name: String) -> String {
        "Winbar saved this PC in Windows App as “\(name)”, with the same user name and password, so Connect works the "
            + "moment Windows is up. " + WindowsAppBookmarks.Copy.passwordGoesToWindowsApp
    }

    /// N_PC_EXISTS: someone already added this PC by hand. Winbar doesn't touch it — it may carry a
    /// password the person typed, and a second tile for one machine makes Connect's choice arbitrary.
    static func nPCExists(name: String, host: String) -> String {
        "Windows App already has a saved PC for \(host) (“\(name)”), so Winbar left it alone rather than adding a "
            + "second one for the same machine. If it doesn't have this password, edit it in Windows App."
    }

    /// N_PC_APP_RUNNING and N_PC_FAILED: the install carries on either way, so this says what to do
    /// afterwards rather than what went wrong.
    static func nPCNotSaved(appRunning: Bool, host: String) -> String {
        if appRunning {
            return "Windows App is open, so Winbar didn't save this PC in it. " + WindowsAppBookmarks.Copy.quitFirst
                + " Quit it and run winbar setup: it will offer to save the PC for \(host)."
        }
        return "Winbar couldn't save this PC in Windows App. Run winbar setup once Windows is installed: it offers to "
            + "save the PC for \(host), or shows you how to add it yourself."
    }
    static let nPWLong = """
        Windows Setup needs your password in its answer file. Winbar writes it there scrambled (Base64), the way \
        Microsoft's tools do: that hides it from a glance but isn't encryption, and anyone who can read the file can \
        recover it.

        The answer file sits on a small setup disk in Winbar's folder on this Mac, readable only by your account and \
        kept out of Time Machine. When Windows has finished installing, Winbar removes the disk from the VM and \
        deletes it. If an install stops partway, the disk stays until you resume it, cancel it, or delete the VM.

        \(nPWPanther) \(nPWLSA)

        Winbar keeps no other copy: not in its settings, its logs or your Keychain.
        """
    static let nPWFileVaultOff = "FileVault is off on this Mac, so after the setup disk is deleted its contents may "
        + "stay readable on the disk until they're overwritten."
    static let nBitLockerFileVaultOff = "FileVault is off on this Mac, so the VM's disk isn't encrypted at rest either "
        + "way. Turning FileVault on (System Settings > Privacy & Security > FileVault) protects it, and everything "
        + "else on your Mac."
    static func nRegionalOff(isoLanguage: String) -> String {
        let name = Locale.current.localizedString(forIdentifier: isoLanguage) ?? isoLanguage
        return "Windows' defaults: \(name) formats and keyboard, Windows' default time zone."
    }
    static func nDisplayLanguage(_ language: String) -> String {
        let name = Locale.current.localizedString(forIdentifier: language) ?? language
        return "Windows' display language comes from the ISO (\(name)). For Windows in another language, download that "
            + "language's ISO from Microsoft."
    }
    static let nNotActivated = "Windows isn't activated: it installed without a product key. Activate it in Windows "
        + "under Settings > System > Activation."
    static let nUpdates = "Windows now has a network and will download updates for a while, so the VM may be busy for "
        + "the next half hour."
    /// N_NEXT_SETUP, as the window says it. The CLI frames the same sentence with "Next:
    /// winbar setup…" and what going headless measured.
    ///
    /// `savedPC` is whether THIS run wrote the saved PC in Windows App (`CreateJobState`'s
    /// `wroteSavedPC`). It used to be on the list every time, which stopped being true the day
    /// Winbar started writing it itself. It is back on the list only when this run couldn't: Windows
    /// App was open (two writers on its database can lose every saved PC there is), a PC for this
    /// host was already there and Winbar left it alone, or Windows App isn't installed. The notes
    /// above the ending say which of those it was; this line only says whether it is still to do.
    static func nNextSetupSteps(savedPC: Bool) -> String {
        let steps = ["approving the VM's certificate on this Mac"]
            + (savedPC ? [] : ["saving the PC in Windows App"])
            + ["allowing Accessibility for Winbar"]
        return "It needs you for \(spelled(steps.count)) things: " + list(steps) + "."
    }

    static func nNextSetup(savedPC: Bool) -> String {
        nNextSetupSteps(savedPC: savedPC) + " Then it offers to go headless."
    }

    /// "a and b", "a, b, and c" — the deck's own punctuation, serial comma included.
    static func list(_ items: [String]) -> String {
        guard let last = items.last else { return "" }
        if items.count == 1 { return last }
        if items.count == 2 { return items[0] + " and " + last }
        return items.dropLast().joined(separator: ", ") + ", and " + last
    }

    /// Small numbers as words, for copy that counts what is left to do.
    static func spelled(_ count: Int) -> String {
        let words = ["no", "one", "two", "three", "four", "five"]
        return words.indices.contains(count) ? words[count] : String(count)
    }
    static func nResumed(name: String) -> String { "Picked up the install of “\(name)” where it left off." }
    /// N_GT_WAITING: two Winbars, one download. The stage's detail says the same thing in four words,
    /// so neither front-end looks hung while the other run finishes.
    static let nGTWaiting = "Another Winbar is downloading the UTM Guest Tools. This one waits for it and installs "
        + "from the same copy, rather than fetching \(GuestTools.size >> 20) MB twice."
    static let nGTWaitingDetail = "Waiting for another Winbar's download…"

    // Warnings. The rules that decide when these apply live with what they watch (WindowsISO,
    // CreatePreflight); the words live here, so the job's message and the form's caption are one text.
    static func wISOUntested(build: Int) -> String {
        "This is Windows 11 build \(build); winbar create was tested with 25H2 (build \(WindowsISO.testedBuild)). It "
            + "should work. If Setup stops to ask something, answer it in the VM's window and Winbar carries on."
    }
    static func wISORemovable(file: String, volume: String) -> String {
        "\(file) is on \(volume), which can be disconnected. Keep it connected until Windows finishes installing: UTM "
            + "reads the ISO from there and doesn't copy it."
    }
    static func wUTMUntested(version: String) -> String {
        "UTM \(version) hasn't been tested with winbar create (tested: \(CreatePreflight.testedVersion)). Carrying on."
    }
    static func wSpace(diskGB: Int, freeGB: Int) -> String {
        "The VM's disk can grow to \(diskGB) GB, but your Mac has \(freeGB) GB free. That's enough to install, but "
            + "Windows will run out of room before its disk is full."
    }
    static let wStall = wStallShort.prefix(1).uppercased() + wStallShort.dropFirst()
        + ". Windows Setup may be showing a question or an error: look at the VM's window in UTM. If it's a question, "
        + "answer it there; Winbar carries on when Windows does."
    /// W_STALL's first line, for a line that has no room for the rest: the CLI's spinner shows it
    /// while `CreateJobState.stalled` is true, and drops it when the VM writes again.
    static let wStallShort = "nothing has changed for 10 minutes"

    // Errors used by the window itself (the rest arrive as ISOProblem/ChoiceProblem/CreateFailure text).
    static let eUTMMissing = eUTMMissingTitle + " " + eUTMMissingNext
    /// The job reports the same thing as a failure, which has a title and a next step (E_UTM_MISSING).
    static let eUTMMissingTitle = "UTM isn't installed."
    static let eUTMMissingNext = "Install it (brew install --cask utm), then run this again."
    static func eSpace(freeGB: Int, volume: String) -> String {
        eSpaceTitle(freeGB: freeGB, volume: volume) + " " + eSpaceNext
    }
    static func eSpaceTitle(freeGB: Int, volume: String) -> String {
        "Your Mac has \(freeGB) GB free on \(volume); installing Windows needs at least "
            + "\(CreatePreflight.neededBytes >> 30) GB."
    }
    static let eSpaceNext = "Free some space, then try again."

    /// The Rufus rows Winbar leaves out, shown as a footnote under the checklist.
    static let rufusOmissionsTitle = "Rufus options Winbar leaves out"
    static let rufusOmissions: [(name: String, why: String)] = [
        ("Use “Windows CA 2023” signed bootloaders",
         "swaps the ISO's boot files for ones signed with Microsoft's 2023 key, for PCs with updated Secure Boot keys. "
            + "UTM's VM has no Secure Boot keys, and Winbar uses Microsoft's ISO unmodified."),
        ("Apply SkuSiPolicy.p7b on installation",
         "a Secure Boot policy that blocks old Windows boot managers. It only matters with Secure Boot on, which this "
            + "VM doesn't have."),
        ("Restrict Windows to S-Mode",
         "S Mode runs only Store apps, so the UTM Guest Tools couldn't install, and Rufus itself marks it incompatible "
            + "with a local account."),
        ("Prevent Windows To Go from accessing internal disks",
         "for Windows running from a USB stick. A VM isn't Windows To Go."),
    ]
}

/// What the window knows about this Mac and its surroundings before anything is typed. Gathered once
/// when the window opens — never by asking UTM, which would launch it — and passed in, so the
/// rules can be tested for any Mac.
struct CreateFormFacts: Equatable, Sendable {
    var mac: MacFacts
    var utmInstalled: Bool
    /// nil when UTM isn't installed.
    var utmVersion: String?
    /// nil when macOS wouldn't say.
    var fileVaultOn: Bool?
    /// Free space where the VM's disk will live; nil when it couldn't be read.
    var freeGB: Int?
    var volumeName: String
    /// UTM's VM names, but only when UTM was already running: nil means "not checked yet", and the
    /// clash check waits for Create.
    var existingVMNames: [String]?
    /// The VM Winbar's menu looks after, if any: the "Use this VM in Winbar's menu" row only appears
    /// when there's another one to replace.
    var menuVMName: String?

    /// Winbar needs this much free before it starts (E_SPACE); the job checks the same number.
    static let minimumFreeGB = Int(CreatePreflight.neededBytes >> 30)
}

/// The New Windows VM form: every field, the rules between them, and the one line that says why
/// Create is off. No I/O: the ISO is inspected by the window controller and handed over.
final class CreateFormModel: ObservableObject {
    /// What the ISO box shows.
    enum ISOState: Equatable {
        case none
        case reading(file: String)
        case failed(file: String, message: String)
        case read(ISOFacts)

        var facts: ISOFacts? { if case .read(let facts) = self { return facts }; return nil }
    }

    /// A Windows ISO that passed preflight, with what the Mac's regional values would be for it.
    struct ISOFacts: Equatable {
        var path: String
        var info: WindowsImageInfo
        var regional: Regional.Reading
        /// The name of the volume the ISO is on, when that volume can be unplugged (W_ISO_REMOVABLE).
        var removableVolume: String?

        var file: String { (path as NSString).lastPathComponent }
    }

    /// Why Create is off, or that it isn't.
    enum Status: Equatable {
        case ready
        case blocked(String)

        var text: String {
            switch self {
            case .ready: return CreateCopy.fReady
            case .blocked(let reason): return reason
            }
        }

        var isReady: Bool { self == .ready }
    }

    /// Some of these arrive after the window is already up (FileVault costs a subprocess, UTM's VM
    /// names an Apple Event), so they're published rather than fixed at init.
    @Published var facts: CreateFormFacts

    @Published var iso: ISOState = .none { didSet { isoChanged(from: oldValue) } }
    @Published var vmName: String { didSet { if vmName != oldValue { vmNameChanged() } } }
    @Published var cores: Int
    @Published var memoryGB: Int
    @Published var diskGB = CreateChoices.defaultDiskGB
    @Published var userName: String { didSet { if userName != oldValue { followComputerName() } } }
    @Published var password = ""
    @Published var confirmation = ""
    @Published var computerName = "" { didSet { if computerName != oldValue { computerNameEdited = true } } }
    @Published var edition: WindowsEdition? = nil { didSet { editionChanged(from: oldValue) } }
    @Published var options = CreateOption.defaults
    @Published var select = true
    /// Set once the person types in the computer-name field: it stops following the VM name.
    @Published var computerNameEdited = false
    /// The clash check's answer for the name as typed; nil when it hasn't run or found nothing.
    @Published var nameTaken: String?
    /// Confirm only shows its mismatch caption once it has lost focus, or once Create was pressed.
    @Published var confirmationBlurred = false
    @Published var submitted = false

    /// What Remote Desktop was set to before a Home edition forced it off, so choosing Pro again
    /// restores the person's choice rather than assuming yes.
    private var remoteDesktopBeforeHome: Bool?

    /// Straight into the `Published` boxes, not through the properties: a plain assignment here would
    /// run the observers below while the rest of the model is still uninitialised, and the computer
    /// name would come out already marked as edited.
    init(facts: CreateFormFacts) {
        let name = CreateChoices.defaultVMName(existing: facts.existingVMNames ?? [])
        let user = CreateChoices.defaultUserName(macShortName: facts.mac.shortUserName)
        _facts = Published(initialValue: facts)
        _vmName = Published(initialValue: name)
        _cores = Published(initialValue: CreateChoices.suggestedCores(facts.mac))
        _memoryGB = Published(initialValue: CreateChoices.suggestedMemoryGB(facts.mac))
        _userName = Published(initialValue: user)
        _computerName = Published(initialValue: CreateChoices.deriveComputerName(vmName: name, userName: user))
    }

    // MARK: - Fields that follow other fields

    private func vmNameChanged() {
        nameTaken = nil
        followComputerName()
    }

    /// The computer name follows the VM name until it's edited. It also follows the user name,
    /// because the derivation ends in "-PC" when the two would clash.
    private func followComputerName() {
        guard !computerNameEdited else { return }
        let derived = CreateChoices.deriveComputerName(vmName: vmName, userName: userName)
        guard derived != computerName else { return }
        computerName = derived
        computerNameEdited = false   // the didSet above set it; this was Winbar typing, not the person
    }

    private func isoChanged(from old: ISOState) {
        guard let facts = iso.facts else { return }
        guard old.facts?.path != facts.path else { return }
        edition = CreateChoices.defaultEdition(facts.info.editions)?.edition
    }

    /// Home can't accept Remote Desktop connections, so row 10 goes off and disabled while it's chosen.
    private func editionChanged(from old: WindowsEdition?) {
        let wasHome = old?.isHome ?? false
        let isHome = edition?.isHome ?? false
        guard wasHome != isHome else { return }
        if isHome {
            remoteDesktopBeforeHome = options.contains(.remoteDesktop)
            options.remove(.remoteDesktop)
        } else if let before = remoteDesktopBeforeHome {
            if before { options.insert(.remoteDesktop) }
            remoteDesktopBeforeHome = nil
        }
    }

    var isHomeEdition: Bool { edition?.isHome ?? false }

    /// Locked rows and Remote Desktop on Home: shown, ticked as they are, and not clickable.
    func isEnabled(_ option: CreateOption) -> Bool {
        if option.isLocked { return false }
        if option == .remoteDesktop, isHomeEdition { return false }
        return true
    }

    // MARK: - Field errors (captions under the fields)

    var vmNameError: String? {
        if let taken = nameTaken { return ChoiceProblem.nameTaken(taken).description }
        return CreateChoices.vmNameProblem(vmName, existing: facts.existingVMNames)?.description
    }

    var userNameError: String? {
        CreateChoices.userNameProblem(userName, computerName: computerName)?.description
    }

    var computerNameError: String? {
        // The user-name clash is reported under the user name, so it isn't said twice.
        guard let problem = CreateChoices.computerNameProblem(computerName), problem != .userIsComputer else { return nil }
        return problem.description
    }

    var passwordError: String? {
        guard !password.isEmpty, let problem = CreateChoices.passwordProblem(password) else { return nil }
        return problem.description
    }

    /// Only after Confirm has lost focus or Create was pressed, so it doesn't shout while
    /// the second password is still being typed.
    var confirmationError: String? {
        guard confirmationBlurred || submitted, !password.isEmpty, confirmation != password else { return nil }
        return ChoiceProblem.passwordMismatch.description
    }

    // MARK: - Warnings (never block)

    var coresWarning: String? { CreateChoices.coresWarning(cores, mac: facts.mac)?.description }

    var memoryWarnings: [String] { CreateChoices.memoryWarnings(memoryGB, mac: facts.mac).map(\.description) }

    var homeWarning: String? { isHomeEdition ? ChoiceWarning.home.description : nil }

    /// Under the BitLocker row, whatever the tick.
    var bitLockerNote: String? { facts.fileVaultOn == false ? CreateCopy.nBitLockerFileVaultOff : nil }

    /// Under the password fields, when FileVault can't protect the deleted setup disk.
    var passwordFileVaultNote: String? { facts.fileVaultOn == false ? CreateCopy.nPWFileVaultOff : nil }

    /// Under the regional row: the Mac's values, or what Windows would use instead.
    var regionalDetail: String? {
        guard let iso = iso.facts else { return nil }
        guard options.contains(.regionalFromMac) else {
            return CreateCopy.nRegionalOff(isoLanguage: iso.info.language)
        }
        return iso.regional.values.summary
    }

    /// N_KEYBOARD_FALLBACK and the locale and time-zone fallbacks, under the same row.
    var regionalNotes: [String] {
        guard options.contains(.regionalFromMac), let iso = iso.facts else { return [] }
        return iso.regional.notes.map(\.description)
    }

    /// Shown under the ISO box once one has been read.
    var isoWarnings: [String] {
        guard let iso = iso.facts else { return [] }
        var warnings: [String] = []
        if let untested = WindowsISO.untestedWarning(iso.info) { warnings.append(untested) }
        if let volume = iso.removableVolume {
            warnings.append(CreateCopy.wISORemovable(file: iso.file, volume: volume))
        }
        warnings.append(CreateCopy.nDisplayLanguage(iso.info.language))
        return warnings
    }

    /// Warnings that belong to no single row, shown above the status line.
    var generalWarnings: [String] {
        var warnings: [String] = []
        if let version = facts.utmVersion, let untested = CreatePreflight.utmVersionWarning(version) {
            warnings.append(untested)
        }
        if let free = facts.freeGB, free >= CreateFormFacts.minimumFreeGB, free < diskGB {
            warnings.append(CreateCopy.wSpace(diskGB: diskGB, freeGB: free))
        }
        return warnings
    }

    // MARK: - The status line

    /// The first thing that blocks Create, in the form's own order. It's a live region for VoiceOver, so
    /// this is also how someone who can't see the form learns why the button is off.
    var status: Status {
        if !facts.utmInstalled { return .blocked(CreateCopy.eUTMMissing) }
        switch iso {
        case .none: return .blocked(CreateCopy.fNeedISO)
        case .reading: return .blocked(CreateCopy.isoReading)
        case .failed(_, let message): return .blocked(message)
        case .read: break
        }
        if let error = vmNameError { return .blocked(error) }
        if let error = userNameError { return .blocked(error) }
        if password.isEmpty { return .blocked(CreateCopy.fNeedPassword(user: userName)) }
        if let error = passwordError { return .blocked(error) }
        if confirmation != password { return .blocked(ChoiceProblem.passwordMismatch.description) }
        if let error = computerNameError { return .blocked(error) }
        if let free = facts.freeGB, free < CreateFormFacts.minimumFreeGB {
            return .blocked(CreateCopy.eSpace(freeGB: free, volume: facts.volumeName))
        }
        // The steppers keep these in range, but the editable number beside them doesn't have to.
        if let problem = CreateChoices.coresProblem(cores, mac: facts.mac) ?? CreateChoices.memoryProblem(memoryGB, mac: facts.mac)
            ?? CreateChoices.diskProblem(diskGB) {
            return .blocked(problem.description)
        }
        if edition == nil { return .blocked(CreateCopy.fNeedISO) }
        return .ready
    }

    var canCreate: Bool { status.isReady }

    // MARK: - What Create sends to the job

    /// The plan, once nothing blocks it. The password is never part of it.
    var plan: CreatePlan? {
        guard canCreate, let iso = iso.facts, let edition else { return nil }
        return CreatePlan(vmName: vmName.trimmingCharacters(in: .whitespacesAndNewlines),
                          isoPath: iso.path,
                          edition: edition,
                          cores: cores,
                          memoryMiB: memoryGB * 1024,
                          diskGiB: diskGB,
                          options: options,
                          noVisualTweaks: false,
                          userName: userName,
                          computerName: computerName,
                          regional: options.contains(.regionalFromMac) ? iso.regional.values : nil,
                          select: facts.menuVMName == nil ? true : select,
                          keepConsole: false)
    }

    /// Both fields, emptied. Called when the window closes and as soon as the job has the password.
    func forgetPassword() {
        password = ""
        confirmation = ""
        confirmationBlurred = false
    }
}
