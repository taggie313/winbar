import Foundation
import Testing
@testable import Winbar

// Pure logic only. Nothing here may reach UTM, a VM, the keychain, TCC or the user's defaults.
// The only thing that touches disk is the temporary folder in `creatingIsOnlyEverOnDemand`.

@Suite struct SharedFolderRegistry {
    let separator = String(UTMScripting.fieldSeparator)

    @Test func noFolderShared() {
        #expect(SharedFolder.parsePaths("") == [])
        #expect(SharedFolder.parsePaths(separator) == [])
    }

    @Test func oneFolderShared() {
        // `POSIX path of` always ends a folder with a slash; nothing else in Winbar writes one.
        #expect(SharedFolder.parsePaths("/Users/x/Shared with Windows/") == ["/Users/x/Shared with Windows"])
        #expect(SharedFolder.parsePaths("/Users/x/Shared with Windows") == ["/Users/x/Shared with Windows"])
    }

    @Test func spacesQuotesAndUnicode() {
        let path = "/Users/josé/“Mit Anführungszeichen”/it's here/ünïcode/"
        #expect(SharedFolder.parsePaths(path) == [String(path.dropLast())])
    }

    /// A path may legally contain a percent sign and even the separator, so the script escapes both.
    @Test func percentsAndSeparatorsComeBackIntact() {
        #expect(SharedFolder.parsePaths("/tmp/100%25 sure/%1Fweird") == ["/tmp/100% sure/\u{1F}weird"])
    }

    @Test func severalPathsAreSplit() {
        #expect(SharedFolder.parsePaths("/a/" + separator + "/b/") == ["/a", "/b"])
    }

    @Test func rootKeepsItsSlash() {
        #expect(SharedFolder.trimmingSlash("/") == "/")
        #expect(SharedFolder.trimmingSlash("/a//") == "/a")
        #expect(SharedFolder.trimmingSlash("") == "")
    }

    @Test func whatUTMAlreadyHas() {
        #expect(SharedFolder.matches("/a", .folder("/a/")))
        #expect(SharedFolder.matches(nil, .off))
        // APFS can be case-sensitive, so "/A" is not "/a".
        #expect(!SharedFolder.matches("/a", .folder("/A")))
        #expect(!SharedFolder.matches("/a", .off))
        #expect(!SharedFolder.matches(nil, .folder("/a")))
    }

    /// The two scripts are built from shared pieces; these are the parts that carry the meaning.
    @Test func theScriptsDoOnlyWhatTheySay() {
        #expect(SharedFolder.readScript.contains("set regFiles to registry of theVM"))
        #expect(!SharedFolder.readScript.contains("update registry"))   // reading changes nothing
        #expect(SharedFolder.updateScript.contains("update registry theVM with newRegistry"))
        #expect(SharedFolder.updateScript.contains("POSIX file newPath"))
        // UTM stores a change made while the VM runs and the guest never sees it, so the script refuses.
        #expect(SharedFolder.updateScript.contains("is not stopped then error"))
        #expect(SharedFolder.updateScript.contains("number 1002"))
        // Values arrive as argv items, never spliced into the source.
        #expect(SharedFolder.updateScript.contains("set newPath to item 2 of argv"))
        // Neither one touches a drive or a display.
        for script in [SharedFolder.readScript, SharedFolder.updateScript] {
            #expect(!script.contains("displays"))
            #expect(!script.contains("drives"))
            #expect(!script.contains("update configuration"))
        }
    }
}

@Suite struct SharedFolderDecision {
    @Test func aStoppedVMCanBeChangedOnTheSpot() {
        #expect(SharedFolder.decide(current: nil, wanted: .folder("/a"), running: false) == .setNow)
        #expect(SharedFolder.decide(current: "/b", wanted: .folder("/a"), running: false) == .setNow)
        #expect(SharedFolder.decide(current: "/b", wanted: .off, running: false) == .setNow)
    }

    /// Proven live on UTM 4.7.5: a change made while the VM runs is stored, survives a restart, and
    /// Windows still shows UTM's placeholder. So it is never made on the quiet — the VM restarts.
    @Test func aRunningVMHasToRestart() {
        #expect(SharedFolder.decide(current: nil, wanted: .folder("/a"), running: true) == .needsRestart)
        #expect(SharedFolder.decide(current: "/b", wanted: .off, running: true) == .needsRestart)
    }

    @Test func whatIsAlreadySetCostsNoRestart() {
        #expect(SharedFolder.decide(current: "/a/", wanted: .folder("/a"), running: true) == .alreadySet)
        #expect(SharedFolder.decide(current: nil, wanted: .off, running: true) == .alreadySet)
    }

    @Test func theFolderIsNotHardware() {
        var changes = ConfigChanges(sharedFolder: .folder("/tmp/f"))
        #expect(!changes.isEmpty)
        // No device changes, so no BitLocker guard — and no booting a stopped VM to run one.
        #expect(!changes.changesHardware)
        changes.display = .headless
        #expect(changes.changesHardware)
        #expect(ConfigChanges().isEmpty && !ConfigChanges().changesHardware)
    }

    @Test func theRestartSaysWhatItIsFor() {
        #expect(ConfigChanges(sharedFolder: .off).summary == "no shared folder")
        #expect(ConfigChanges(cpuCores: 6, sharedFolder: .folder("/tmp/f")).summary == "6 vCPUs, sharing /tmp/f")
        #expect(ConfigChanges(display: .headless).summary == "headless")
    }
}

@Suite struct SharedFolderOnTheMac {
    /// Hyphens, not spaces: a space anywhere in the path leaves Windows with a drive it can read
    /// nothing from, which is exactly the folder someone would otherwise be offered by default.
    @Test func theDefaultFolderSaysWhatItIsForAndHasNoSpaces() {
        #expect(SharedFolder.defaultFolderName == "Shared-with-Windows")
        #expect(!SharedFolder.hasSpace(SharedFolder.defaultFolderName))
        #expect(SharedFolder.defaultFolder(home: "/Users/x") == "/Users/x/Shared-with-Windows")
        #expect(SharedFolder.refusal(SharedFolder.defaultFolder(home: "/Users/x")) == nil)
    }

    /// `~/Shared with Windows` mounted as an empty drive and every write failed with "A device
    /// attached to the system is not functioning"; the same files at `~/Shared-with-Windows` worked
    /// both ways in the same VM minutes later. So it is refused, with the hyphenated name offered.
    @Test func aPathWithASpaceIsRefusedNotSet() {
        let refusal = SharedFolder.refusal("/Users/x/Shared with Windows")
        #expect(refusal != nil)
        #expect(refusal?.detail.contains("Shared-with-Windows") == true)
        #expect(refusal?.detail.contains("not functioning") == true)
        #expect(SharedFolder.hyphenated("/Users/x/Shared with Windows") == "/Users/x/Shared-with-Windows")
    }

    /// Spaces further up are the person's home or disk, which Winbar has no business renaming.
    @Test func aSpaceAboveTheFolderHasNothingToSuggest() {
        #expect(SharedFolder.hyphenated("/Volumes/Big Disk/share") == nil)
        let refusal = SharedFolder.refusal("/Volumes/Big Disk/share")
        #expect(refusal != nil)
        #expect(refusal?.detail.contains("whole path") == true)
        #expect(!SharedFolder.hasSpace("/Volumes/Big-Disk/share"))
        #expect(SharedFolder.refusal("/Volumes/Big-Disk/share") == nil)
    }

    @Test func homeFoldersAreShownShort() {
        #expect(SharedFolder.abbreviate("/Users/x/Shared-with-Windows", home: "/Users/x") == "~/Shared-with-Windows")
        #expect(SharedFolder.abbreviate("/Users/x/", home: "/Users/x") == "~")
        #expect(SharedFolder.abbreviate("/Volumes/Big/Share", home: "/Users/x") == "/Volumes/Big/Share")
        // A sibling that merely starts the same way is not in the home folder.
        #expect(SharedFolder.abbreviate("/Users/xerox/f", home: "/Users/x") == "/Users/xerox/f")
    }

    @Test func whatSomeoneTypedBecomesOneAbsolutePath() {
        #expect(SharedFolder.resolve("~/Shared-with-Windows", home: "/Users/x", currentDirectory: "/w") == "/Users/x/Shared-with-Windows")
        #expect(SharedFolder.resolve("~", home: "/Users/x", currentDirectory: "/w") == "/Users/x")
        #expect(SharedFolder.resolve("docs/", home: "/Users/x", currentDirectory: "/w") == "/w/docs")
        #expect(SharedFolder.resolve("  /Users/x/a/../b/  ", home: "/Users/x", currentDirectory: "/w") == "/Users/x/b")
        #expect(SharedFolder.resolve("   ", home: "/Users/x", currentDirectory: "/w") == "")
    }

    /// The folder is made only when someone asks for it; `inspect` is what the asking is based on.
    @Test func creatingIsOnlyEverOnDemand() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("winbar-share-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = base.appendingPathComponent(SharedFolder.defaultFolderName).path
        #expect(SharedFolder.inspect(folder) == .missing)
        try SharedFolder.create(folder).get()
        #expect(SharedFolder.inspect(folder) == .folder)
        try SharedFolder.create(folder).get()   // twice is fine: nothing is replaced
        let file = base.appendingPathComponent("a file").path
        FileManager.default.createFile(atPath: file, contents: Data())
        #expect(SharedFolder.inspect(file) == .notAFolder)
    }

    /// Whichever folder UTM reports belongs to one VM, so switching VMs forgets it.
    @Test func theFolderIsRememberedPerVM() {
        for key in [Config.Key.sharedFolder, Config.Key.declinedSharedFolder] {
            #expect(Config.Key.all.contains(key))
            #expect(Config.Key.perVM.contains(key), "\(key) belongs to one VM")
        }
        // And only for the VM Winbar looks after: another VM's folder must not land in these keys.
        #expect(UTM.shouldCacheSettings(vm: "winlab01", selected: "winlab01", asked: true))
        #expect(!UTM.shouldCacheSettings(vm: "other", selected: "winlab01", asked: true))
        #expect(!UTM.shouldCacheSettings(vm: "winlab01", selected: nil, asked: true))
        // What is stored is the path itself, or nothing at all.
        #expect(SharedFolder.Setting.folder("/tmp/f").path == "/tmp/f")
        #expect(SharedFolder.Setting.off.path == nil)
    }
}

@Suite struct SharedFolderInWindows {
    /// UTM shares a temporary folder holding this README when nobody has chosen one, so the guest
    /// always has something to mount. Its first line is how "nothing shared" is told from "empty".
    @Test func utmsPlaceholderMeansNothingIsShared() {
        #expect(SharedFolder.isPlaceholder("You have not selected a shared directory."))
        #expect(SharedFolder.isPlaceholder("\u{FEFF}You have not selected a shared directory. Select one in UTM."))
        #expect(SharedFolder.isPlaceholder("  You have not selected a shared directory"))
    }

    @Test func anyOtherReadmeIsSomeonesOwn() {
        #expect(!SharedFolder.isPlaceholder(nil))
        #expect(!SharedFolder.isPlaceholder(""))
        #expect(!SharedFolder.isPlaceholder("Build notes"))
        #expect(!SharedFolder.isPlaceholder("Mine: You have not selected a shared directory"))
    }

    @Test func thePortComesFromTheGuestsOwnMapping() {
        #expect(SharedFolder.port(in: #"\\localhost@9843\DavWWWRoot"#) == 9843)
        #expect(SharedFolder.port(in: #"\\localhost@1234\DavWWWRoot"#) == 1234)
        #expect(SharedFolder.port(in: #"\\localhost\DavWWWRoot"#) == nil)
        #expect(SharedFolder.port(in: nil) == nil)
        #expect(SharedFolder.defaultRemotePath == #"\\localhost@9843\DavWWWRoot"#)
    }

    @Test func readsWhatTheSurveySaid() {
        let out = GuestOutput.parse("""
            SF_WEBDAVD=Running:Automatic
            SF_WEBCLIENT=Running:Manual
            SF_DRIVE=Z:
            SF_REMOTE=\\\\localhost@9843\\DavWWWRoot
            SF_REACHABLE=True
            SF_COUNT=3
            DONE=1
            """)
        let view = SharedFolder.guestView(out)
        #expect(view.webdavdRunning && view.webClientRunning && view.mapped)
        #expect(view.drive == "Z:" && view.port == 9843)
        #expect(view.reachable == true && view.entryCount == 3)
        #expect(!view.seesPlaceholder && view.error == nil && view.marker == nil)
    }

    @Test func readsAGuestWithNothingSetUp() {
        let out = GuestOutput.parse("SF_WEBDAVD=Missing:Missing\nSF_WEBCLIENT=Stopped:Manual\nSF_DRIVE=\nSF_REMOTE=\nDONE=1\n")
        let view = SharedFolder.guestView(out)
        #expect(!view.webdavdRunning && !view.webClientRunning && !view.mapped)
        #expect(view.drive == nil && view.remotePath == nil && view.reachable == nil && view.port == nil)
    }

    @Test func theMappingCommandIsTheOneUTMsToolsUse() {
        #expect(SharedFolder.mapArguments(drive: "Z:", remotePath: #"\\localhost@9843\DavWWWRoot"#)
                == #"use Z: \\localhost@9843\DavWWWRoot /persistent:yes"#)
    }

    /// The drive mapping is per-user and the guest agent is SYSTEM in session 0, so the survey reads
    /// it out of the user's own hive rather than asking for this session's drives.
    @Test func theGuestScriptLooksWhereTheMappingActuallyIs() {
        let body = GuestScripts.sharedFolder(user: "alex").body
        // This session first (that is where the Guest Tools' drive turned out to be), then the user's
        // own persistent mapping.
        #expect(body.contains("Win32_NetworkConnection"))
        #expect(body.contains("DisplayRoot"))
        #expect(body.contains(#"HKEY_USERS\' + $userSid + '\Network"#))
        #expect(body.contains("'RemotePath'"))
        #expect(body.contains("spice-webdavd") && body.contains("WebClient"))
        #expect(body.contains("README.txt"))
        // The marker file is how the host proves which Mac folder is at the other end.
        #expect(body.contains("$wbMarker") && body.contains("SF_MARKER"))
        // It reads; it installs and starts nothing.
        #expect(!body.contains("Start-Service") && !body.contains("Set-Service"))
        // The survey asks the same questions in the same round trip.
        let survey = GuestScripts.survey(user: "alex", passwordChecked: []).body
        #expect(survey.contains("SF_WEBDAVD") && survey.contains("SF_DRIVE"))
    }
}

@Suite struct SharedFolderRow {
    func view(webdavd: String = "Running:Automatic", webClient: String = "Running:Automatic",
              drive: String? = "Z:", readme: String? = nil, reachable: Bool? = true) -> SharedFolder.GuestView {
        var view = SharedFolder.GuestView()
        view.webdavd = webdavd
        view.webClient = webClient
        view.drive = drive
        view.remotePath = drive == nil ? nil : SharedFolder.defaultRemotePath
        view.readme = readme
        view.reachable = reachable
        return view
    }

    func isInfo(_ status: Status) -> Bool {
        if case .info = status { return true }
        return false
    }

    /// Nobody is broken for not sharing a folder, so doctor still exits 0.
    @Test func nothingSharedIsInformation() {
        let status = Recipe.sharedFolderStatus(folder: nil, guest: view(), running: true)
        #expect(isInfo(status))
        #expect(!status.needsAttention)
        #expect(status.detail.contains("winbar share"))
    }

    @Test func sharedAndWindowsHasIt() {
        let status = Recipe.sharedFolderStatus(folder: "/tmp/f", guest: view(), running: true)
        #expect(status.isOK)
        #expect(status.detail == "/tmp/f ↔ Z: in Windows")
    }

    /// The one state that proves the set-while-stopped rule was broken.
    @Test func windowsStillShowingUTMsPlaceholder() {
        let status = Recipe.sharedFolderStatus(folder: "/tmp/f",
                                               guest: view(readme: "You have not selected a shared directory."),
                                               running: true)
        #expect(status.isManual)
        #expect(status.detail.contains("placeholder"))
        if case .manual(_, let how) = status { #expect(how.contains("winbar restart")) } else { Issue.record("not manual") }
    }

    @Test func theWindowsHelpersHaveToBeRunning() {
        let noDaemon = Recipe.sharedFolderStatus(folder: "/tmp/f", guest: view(webdavd: "Stopped:Manual"), running: true)
        #expect(noDaemon.isManual && noDaemon.detail.contains("spice-webdavd"))
        let noWebClient = Recipe.sharedFolderStatus(folder: "/tmp/f", guest: view(webClient: "Stopped:Manual"), running: true)
        #expect(noWebClient.isManual && noWebClient.detail.contains("WebClient"))
    }

    /// The only thing this row can fix by itself, and normally the Guest Tools already did it.
    @Test func anUnmappedDriveIsFixable() {
        let status = Recipe.sharedFolderStatus(folder: "/tmp/f", guest: view(drive: nil), running: true)
        #expect(status.isFixable)
        #expect(status.detail.contains("no drive is mapped"))
        #expect(Recipe.check("G11")?.apply != nil)
        #expect(Recipe.check("G11")?.needsRestart == false)
    }

    @Test func aStoppedVMStillShowsTheFolder() {
        let status = Recipe.sharedFolderStatus(folder: "/tmp/f", guest: nil, running: false)
        #expect(status.isOK && status.detail.contains("/tmp/f"))
        #expect(status.detail.contains("running"))
        // An older survey, without the shared-folder lines, is "Windows wasn't asked" too.
        let unasked = Recipe.sharedFolderStatus(folder: "/tmp/f", guest: SharedFolder.GuestView(), running: true)
        #expect(unasked.isOK && unasked.detail.contains("G0"))
    }

    /// The guest agent is SYSTEM, which doesn't always get to walk another session's WebDAV mount.
    /// Worth saying, never a failure.
    @Test func aProbeThatCouldNotReadTheShareIsNotAFailure() {
        let status = Recipe.sharedFolderStatus(folder: "/tmp/f", guest: view(reachable: false), running: true)
        #expect(status.isOK)
        #expect(status.detail.contains("didn't manage to read it"))
    }
}

/// UTM gives Windows the folder its registry held at the *previous* start, so one restart after a
/// change is never enough: set A while running → restart → placeholder; stop, set A, start → A;
/// stop, set B, start → still A; stop, set C, start → B; restart unchanged → C. Winbar doesn't
/// count restarts, it asks Windows — with a marker file, since the guest only ever sees a WebDAV
/// root and can't name the Mac folder behind it.
@Suite struct SharedFolderTakesEffect {
    func view(marker: String? = nil, readme: String? = nil, webdavd: String = "Running:Automatic",
              reachable: Bool? = true) -> SharedFolder.GuestView {
        var view = SharedFolder.GuestView()
        view.webdavd = webdavd
        view.webClient = "Running:Automatic"
        view.drive = "Z:"
        view.remotePath = SharedFolder.defaultRemotePath
        view.marker = marker
        view.readme = readme
        view.reachable = reachable
        return view
    }

    @Test func theMarkerWindowsFoundIsTheProof() {
        let folder = SharedFolder.Setting.folder("/tmp/f")
        #expect(SharedFolder.judge(folder, view: view(marker: "abc"), token: "abc") == .live)
        // Windows is still serving the folder from the start before: its files, not ours.
        #expect(SharedFolder.judge(folder, view: view(marker: nil), token: "abc") == .stale)
        #expect(SharedFolder.judge(folder, view: view(marker: "older-token"), token: "abc") == .stale)
    }

    @Test func stoppingTheSharingIsProvedByUTMsPlaceholder() {
        #expect(SharedFolder.judge(.off, view: view(readme: "You have not selected a shared directory."), token: nil) == .live)
        #expect(SharedFolder.judge(.off, view: view(readme: "Someone's notes"), token: nil) == .stale)
        #expect(SharedFolder.judge(.off, view: view(), token: nil) == .stale)
    }

    /// Nothing is called done on a guess: when Windows couldn't be asked, or the marker couldn't be
    /// written, the answer is "unknown" and the person is told so.
    @Test func whatCannotBeProvedIsNotClaimed() {
        let folder = SharedFolder.Setting.folder("/tmp/f")
        #expect(SharedFolder.judge(folder, view: SharedFolder.GuestView(), token: "abc")
                == .unknown("Windows didn't say"))
        #expect(SharedFolder.judge(folder, view: view(webdavd: "Stopped:Manual"), token: "abc")
                == .unknown("spice-webdavd isn't running in Windows"))
        #expect(SharedFolder.judge(folder, view: view(reachable: false), token: "abc")
                == .unknown("Windows couldn't read the share"))
        #expect(SharedFolder.judge(folder, view: view(marker: "abc"), token: nil)
                == .unknown("the marker file couldn't be written"))
    }

    /// The marker is hidden, and goes again as soon as the question has been asked.
    @Test func theMarkerIsWrittenAndTakenAwayAgain() throws {
        #expect(SharedFolder.markerName.hasPrefix("."))
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("winbar-marker-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: folder) }
        try SharedFolder.create(folder).get()
        let token = try #require(SharedFolder.writeMarker(in: folder))
        let file = (folder as NSString).appendingPathComponent(SharedFolder.markerName)
        #expect(try String(contentsOfFile: file, encoding: .utf8) == token)
        SharedFolder.removeMarker(in: folder)
        #expect(!FileManager.default.fileExists(atPath: file))
        // A folder that has gone can't be proved either way, and isn't claimed to be.
        #expect(SharedFolder.writeMarker(in: folder + "/not/there") == nil)
    }

    /// Whatever the VM is doing, the copy says the same thing: a change needs the VM to restart.
    @Test func theRestartIsSaidPlainly() {
        #expect(SharedFolder.restartCost.contains("restart"))
        #expect(SharedFolder.restartCost.contains("two restarts"))
        #expect(SharedFolder.worthKnowing.contains("spaces"))
        #expect(CLI.usage.contains("must have no spaces"))
    }
}

@Suite struct SharedFolderRowAndTheMarker {
    func view(marker: String?) -> SharedFolder.GuestView {
        var view = SharedFolder.GuestView()
        view.webdavd = "Running:Automatic"
        view.webClient = "Running:Automatic"
        view.drive = "Z:"
        view.remotePath = SharedFolder.defaultRemotePath
        view.marker = marker
        view.reachable = true
        return view
    }

    /// The survey leaves a marker in the shared folder, so the row can say which folder Windows has
    /// rather than only that a drive is mounted.
    @Test func theRowSaysSoWhenWindowsHasTheFolderBefore() {
        let live = Recipe.sharedFolderStatus(folder: "/tmp/f", guest: view(marker: "abc"), running: true, token: "abc")
        #expect(live.isOK)
        let stale = Recipe.sharedFolderStatus(folder: "/tmp/f", guest: view(marker: nil), running: true, token: "abc")
        #expect(stale.isManual)
        #expect(stale.detail.contains("still serving the folder it had before"))
        if case .manual(_, let how) = stale { #expect(how.contains("second start")) } else { Issue.record("not manual") }
    }

    /// Without a marker (the folder couldn't be written to) the row falls back to what it can see,
    /// and doesn't invent a failure.
    @Test func noMarkerMeansNoVerdictEitherWay() {
        let status = Recipe.sharedFolderStatus(folder: "/tmp/f", guest: view(marker: nil), running: true, token: nil)
        #expect(status.isOK)
    }

    /// A path with a space is said first: every other answer would be a symptom of it.
    @Test func theRowRefusesASpaceBeforeAnythingElse() {
        let status = Recipe.sharedFolderStatus(folder: "/Users/x/Shared with Windows", guest: view(marker: nil),
                                               running: true, token: "abc")
        #expect(status.isManual)
        #expect(status.detail.contains("space"))
    }
}

@Suite struct SharedFolderUnprovable {
    /// A listing that never happened is not "nothing there": WebClient down, or a probe that was
    /// skipped, leaves the question open rather than declaring the folder stale.
    @Test func nothingTriedIsNotNothingThere() {
        var view = SharedFolder.GuestView()
        view.webdavd = "Running:Automatic"
        view.webClient = "Stopped:Manual"
        #expect(SharedFolder.judge(.folder("/tmp/f"), view: view, token: "abc")
                == .unknown("Windows' WebClient service isn't running"))
        view.webClient = "Running:Automatic"
        #expect(SharedFolder.judge(.folder("/tmp/f"), view: view, token: "abc")
                == .unknown("Windows couldn't read the share"))
        #expect(SharedFolder.judge(.off, view: view, token: nil) == .unknown("Windows couldn't read the share"))
    }
}
