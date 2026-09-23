import Foundation
import Testing
@testable import Winbar

// How an install job ends, carries on and is called off: the rules the CLI, the window and the menu
// bar all read, and the ones that decide what create is allowed to do to a VM or to Winbar's
// settings. Every function under test is pure or works in a temporary folder: nothing here reaches
// UTM, and no VM is touched.

/// A job folder as `SetupMedia.create` leaves one, without running `tmutil`: `<base>/<id>.noindex`,
/// mode 0700, with the marker file that proves Winbar made it.
func testJobFolder(id: String = "create-20260919-170211-abcd1234") throws -> (base: URL, directory: URL) {
    let base = try temporaryDirectory("winbar-create-base")
    let directory = base.appendingPathComponent(id + SetupMedia.suffix, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                            attributes: [.posixPermissions: 0o700])
    try Data("winbar create\n".utf8).write(to: directory.appendingPathComponent(SetupMedia.marker))
    return (base, directory)
}

func testStatus(ok: Bool = true, tools: String = "0", rdp: Bool = true,
                failed: [String] = []) -> CreateStatusRecord {
    CreateStatusRecord(ok: ok, guestTools: tools, remoteDesktopOn: rdp, failedSteps: failed, plaintextSecret: false)
}

let testFailure = CreateFailure(code: "E_TIMEOUT", title: "Windows still hadn't finished installing after 2 hours",
                                detail: "The VM is still running: look at its window in UTM.",
                                nextStep: "To start over: winbar create --cancel \"Windows 11\".")

// MARK: - Ending a job

@Suite("How a job ends")
struct CreateEndingTests {
    /// The defect both reviewers found: only E_RESULT_FAILED ever wrote `outcome`, so a timeout, a
    /// stopped VM or a silent agent left `isFinished` false for ever — a spinner on a dead job in
    /// the window, and a menu bar that went on refusing to start another install.
    @Test("Every failure ends the job, so both front-ends stop showing it as running")
    func everyFailureEndsTheJob() {
        let now = testMoment()
        var running = testState(stage: .oobe)
        running.detail = "7.9 GB written to the VM's disk"
        running.stalled = .busy
        #expect(!running.isFinished)

        let failed = CreateRun.ending(running, outcome: .failed, failure: testFailure, at: now)
        #expect(failed.isFinished)
        #expect(failed.outcome == .failed)
        #expect(failed.failure == testFailure)
        #expect(failed.finishedAt == now)
        #expect(!failed.watched)
        // Nothing that says "this is still happening" survives the ending.
        #expect(failed.detail == nil)
        #expect(failed.stalled == nil)
    }

    @Test("A job that failed with the VM still there can still be carried on with")
    func aFailureCanStillBeResumed() {
        var timedOut = testState(stage: .oobe)
        timedOut.mediaDir = "/tmp/create-x.noindex"
        timedOut = CreateRun.ending(timedOut, outcome: .failed, failure: testFailure, at: testMoment())
        #expect(timedOut.isFinished)
        #expect(timedOut.isResumable)
        #expect(!timedOut.isSpent)
        #expect(timedOut.canBeCancelled)

        // Ctrl-C leaves no failure at all, and is resumable for the same reasons.
        var interrupted = timedOut
        interrupted.outcome = nil
        interrupted.failure = nil
        interrupted.watched = false
        #expect(interrupted.isResumable)

        // Done and cancelled never are, whatever else they say.
        for outcome in [CreateJobState.Outcome.done, .cancelled] {
            var over = timedOut
            over.outcome = outcome
            #expect(!over.isResumable)
            #expect(over.isSpent)
            #expect(!over.canBeCancelled)
        }
    }

    @Test("A failure with nothing left to carry on with is spent, and the sweep may take it")
    func aFailureWithNothingLeft() {
        // Before the VM existed: preflight, the download, the setup disk.
        var early = testState(stage: .media, vmID: nil)
        early.mediaDir = "/tmp/create-x.noindex"
        early = CreateRun.ending(early, outcome: .failed, failure: testFailure, at: testMoment())
        #expect(!early.isResumable)
        #expect(early.isSpent)

        // The VM was made but create-vm stored something unexpected (F2): nothing to resume, but
        // --cancel still has a VM to delete.
        var halfMade = testState(stage: .vm, vmID: "5B0F2A11")
        halfMade.mediaDir = "/tmp/create-x.noindex"
        halfMade.created = nil
        halfMade = CreateRun.ending(halfMade, outcome: .failed, failure: testFailure, at: testMoment())
        #expect(!halfMade.isResumable)
        #expect(halfMade.canBeCancelled)

        // The setup disk has already gone, so there is nothing to resume from either.
        var noFolder = testState(stage: .oobe)
        noFolder.mediaDir = nil
        noFolder = CreateRun.ending(noFolder, outcome: .failed, failure: testFailure, at: testMoment())
        #expect(!noFolder.isResumable)
        #expect(noFolder.isSpent)
    }

    /// `CreateRun.cancel` used to set `.cancelled` on a local copy of the state and throw it away,
    /// so the job simply vanished and a following front-end never learned it had ended.
    @Test("A cancel leaves a state that says the job was cancelled")
    func cancelWritesATerminalState() {
        var state = testState(stage: .copy)
        state.mediaDir = "/tmp/create-x.noindex"
        state = CreateRun.afterDeletingMedia(state, directory: URL(fileURLWithPath: state.mediaDir!), deleted: true)
        state = CreateRun.ending(state, outcome: .cancelled, failure: nil, at: testMoment())
        #expect(state.outcome == .cancelled)
        #expect(state.isFinished)
        #expect(state.isSpent)
        #expect(state.mediaDir == nil)
        #expect(state.failure == nil)
    }

    /// The other half: while the folder is still there, the state has to keep naming it. Clearing
    /// `mediaDir` after a failed delete orphaned the ISO that holds the password — `--resume` said
    /// there was no folder to carry on from and `--cancel` skipped its cleanup entirely.
    @Test("The setup disk stays named in the state until it really goes")
    func theSetupDiskStaysNamedWhileItIsThere() {
        let directory = URL(fileURLWithPath: "/tmp/create-20260919-170211-abcd1234.noindex")
        var state = testState()
        state.mediaDir = directory.path
        #expect(CreateRun.afterDeletingMedia(state, directory: directory, deleted: false).mediaDir == directory.path)
        #expect(CreateRun.afterDeletingMedia(state, directory: directory, deleted: true).mediaDir == nil)
    }
}

// MARK: - The job's folder

@Suite("The job's folder outlives its setup disk")
struct CreateJobFolderTests {
    /// A terminal state written into a folder that is destroyed a moment later is a state nobody
    /// ever reads: the followers poll once a second. The disk goes; state.json and the marker stay
    /// for the sweep.
    @Test("Emptying a job folder takes the setup disk and keeps the state")
    func emptyingAJobFolderKeepsItsState() throws {
        let (base, directory) = try testJobFolder()
        defer { try? FileManager.default.removeItem(at: base) }
        let iso = directory.appendingPathComponent(SetupMedia.isoName)
        try Data(repeating: 0x5A, count: 2048).write(to: iso)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("src"),
                                                withIntermediateDirectories: false)
        try Data("<unattend/>".utf8).write(to: directory.appendingPathComponent("src/Autounattend.xml"))
        try CreateJob.writeState(testState(), in: directory)

        try CreateJob.emptyFolder(directory, base: base)

        let left = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
        #expect(left == [CreateJob.stateFileName, SetupMedia.marker])
        #expect(CreateJob.state(in: directory)?.stage == .copy)
        #expect(!FileManager.default.fileExists(atPath: iso.path))
    }

    @Test("It refuses a folder Winbar didn't make")
    func itRefusesAForeignFolder() throws {
        let base = try temporaryDirectory("winbar-create-base")
        defer { try? FileManager.default.removeItem(at: base) }
        let foreign = base.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        try Data("keep me".utf8).write(to: foreign.appendingPathComponent("notes.txt"))
        #expect(throws: SetupMediaError.self) { try CreateJob.emptyFolder(foreign, base: base) }
        #expect(FileManager.default.fileExists(atPath: foreign.appendingPathComponent("notes.txt").path))
    }

    @Test("A job's folder is known even after its setup disk has gone")
    func theFolderIsKnownWithoutMediaDir() {
        var state = testState()
        state.mediaDir = "/somewhere/create-abc.noindex"
        #expect(CreateJob.directory(of: state).path == "/somewhere/create-abc.noindex")
        state.mediaDir = nil
        #expect(CreateJob.directory(of: state).lastPathComponent == state.id + SetupMedia.suffix)
    }
}

// MARK: - The sweep

@Suite("What the sweep may take")
struct CreateSweepRemainsTests {
    /// The answer ISO is never deleted while a VM still references it. A state.json this
    /// build can't decode used to be treated like an empty folder and destroyed an hour later, CD
    /// and all, leaving a VM that won't start.
    @Test("An undecodable state is still a job: its VM id decides")
    func anUnreadableStateIsStillAJob() {
        let old = CreateJob.staleAge + 1
        func decide(_ remains: CreateJob.JobRemains, vmIDs: Set<String>?) -> Bool {
            CreateJob.sweepDecision(nil, remains: remains, vmIDs: vmIDs, lockHeld: false, folderAge: old, now: Date())
        }
        let unreadable = CreateJob.JobRemains(unreadableState: true, vmIDHint: "5B0F2A11", hasSetupDisk: true)
        #expect(!decide(unreadable, vmIDs: ["5B0F2A11"]))          // the VM still has the CD
        #expect(decide(unreadable, vmIDs: ["SOMETHING-ELSE"]))     // the VM is gone from UTM
        #expect(!decide(unreadable, vmIDs: nil))                   // UTM couldn't be asked

        // No id to be had: a folder still holding the setup disk is left alone either way.
        let noHint = CreateJob.JobRemains(unreadableState: true, vmIDHint: nil, hasSetupDisk: true)
        #expect(!decide(noHint, vmIDs: []))
        #expect(!decide(noHint, vmIDs: nil))
        var emptied = noHint
        emptied.hasSetupDisk = false
        #expect(decide(emptied, vmIDs: []))

        // A folder with no state.json at all is the old rule, unchanged.
        #expect(decide(CreateJob.JobRemains(), vmIDs: nil))
        #expect(!CreateJob.sweepDecision(nil, vmIDs: nil, lockHeld: false, folderAge: 5, now: Date()))
    }

    @Test("The VM id is read out of a state.json this Winbar can't decode")
    func vmIDHintFromUndecodableJSON() throws {
        let state = testState(vmID: "5B0F2A11")
        var object = try #require(try JSONSerialization.jsonObject(with: CreateJob.encodeState(state))
                                  as? [String: Any])
        object["stage"] = "a_stage_from_a_later_winbar"
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(CreateJob.decodeState(data) == nil)
        #expect(CreateJob.vmIDHint(data) == "5B0F2A11")
        #expect(CreateJob.vmIDHint(Data("not json".utf8)) == nil)
        #expect(CreateJob.vmIDHint(Data("{}".utf8)) == nil)
    }

    /// A failure is an ending, not a verdict: the folder of a job that can still be resumed has to
    /// survive the sweep exactly as a running job's does, or Try Again has nothing to work with.
    @Test("A resumable failure keeps its folder; a spent one doesn't")
    func aResumableFailureKeepsItsFolder() {
        let now = Date()
        var failed = testState(stage: .oobe, vmID: "5B0F2A11")
        failed.mediaDir = "/tmp/create-x.noindex"
        failed = CreateRun.ending(failed, outcome: .failed, failure: testFailure, at: now)
        #expect(!CreateJob.sweepDecision(failed, vmIDs: ["5B0F2A11"], lockHeld: false, folderAge: 10, now: now))
        #expect(CreateJob.sweepDecision(failed, vmIDs: [], lockHeld: false, folderAge: 10, now: now))

        // Once the setup disk has gone, only state.json is left and the sweep takes the folder.
        var spent = CreateRun.afterDeletingMedia(failed, directory: URL(fileURLWithPath: failed.mediaDir!),
                                                 deleted: true)
        #expect(CreateJob.sweepDecision(spent, vmIDs: ["5B0F2A11"], lockHeld: false, folderAge: 10, now: now))
        spent.outcome = .cancelled
        #expect(CreateJob.sweepDecision(spent, vmIDs: ["5B0F2A11"], lockHeld: false, folderAge: 10, now: now))

        // A run killed between deleting the setup disk and saving its ending looks unfinished but
        // can never be resumed (there is no folder to carry on from), so it goes once it is stale
        // rather than being picked up again and again by the menu bar.
        var orphan = spent
        orphan.outcome = nil
        orphan.finishedAt = nil
        #expect(!orphan.isResumable)
        #expect(!CreateJob.sweepDecision(orphan, vmIDs: ["5B0F2A11"], lockHeld: false, folderAge: 10, now: now))
        let old = testState(stage: .oobe, vmID: "5B0F2A11", watched: false,
                            updatedAt: now.addingTimeInterval(-CreateJob.staleAge - 1))
        #expect(CreateJob.sweepDecision(old, vmIDs: ["5B0F2A11"], lockHeld: false,
                                        folderAge: CreateJob.staleAge + 1, now: now))
    }
}

// MARK: - Carrying on after an interruption

@Suite("Carrying on after an interruption")
struct CreateResumeTests {
    /// The documented recovery path: Ctrl-C at 11pm, resume after breakfast. The limit used to run
    /// from the persisted start of stage 5, so the first tick of that resume threw E_TIMEOUT —
    /// whose advice is to delete a VM that may be one step from done.
    @Test("The two-hour limit counts watching, not the night in between")
    func theTwoHourLimitCountsWatching() {
        let now: TimeInterval = 100_000
        func evaluate(watchedFor: TimeInterval) -> InstallAlert? {
            let times = CreateRun.installTimes(stage: .oobe, watchedFor: watchedFor, qemuStartedAt: now - 60,
                                               serialConsole: true, promptMissed: false, restarts: 2,
                                               lastRestartAt: now - 60, agentAnsweredAt: nil, now: now)
            return InstallWatch.evaluate(times, history: [], now: now)
        }
        // Forty minutes were watched last night; this resume has watched ten seconds.
        let carriedOn = CreateRun.watchedSoFar(before: 40 * 60, watchStartedAt: now - 10, now: now)
        #expect(carriedOn == 40 * 60 + 10)
        #expect(evaluate(watchedFor: carriedOn) == nil)
        // Two hours of watching, however they were spread over the days, is still the limit.
        #expect(evaluate(watchedFor: InstallLimits.whole + 1) == .timeout)
        // A run that hasn't started watching yet adds nothing.
        #expect(CreateRun.watchedSoFar(before: 600, watchStartedAt: nil, now: now) == 600)
    }

    /// `lastRestartAt` was per-run and started nil, so after a resume the fifteen-minute rule could
    /// never fire at all — the one alert that tells a person the Guest Tools didn't install.
    @Test("The agent-silence clock starts when a resumed run starts watching")
    func agentSilenceStartsWhenTheResumeStartsWatching() {
        let watchStart: TimeInterval = 100_000
        // A resume of a job that had already restarted twice: the clock starts now, not last night.
        #expect(CreateRun.seededLastRestart(restarts: 2, lastRestartAt: nil, watchStartedAt: watchStart)
                == watchStart)
        // Before any restart there is nothing to measure from (the audit needs two restarts anyway).
        #expect(CreateRun.seededLastRestart(restarts: 0, lastRestartAt: nil, watchStartedAt: watchStart) == nil)
        // A restart this run saw wins, and one from before it started watching never moves it back.
        #expect(CreateRun.seededLastRestart(restarts: 2, lastRestartAt: watchStart + 300,
                                            watchStartedAt: watchStart) == watchStart + 300)
        #expect(CreateRun.seededLastRestart(restarts: 2, lastRestartAt: watchStart - 9000,
                                            watchStartedAt: watchStart) == watchStart)

        // …and it does then fire, fifteen minutes into the resume.
        let now = watchStart + InstallLimits.agentSilence + 1
        let times = CreateRun.installTimes(stage: .oobe, watchedFor: 1800, qemuStartedAt: watchStart,
                                           serialConsole: true, promptMissed: false, restarts: 2,
                                           lastRestartAt: watchStart, agentAnsweredAt: nil, now: now)
        #expect(InstallWatch.evaluate(times, history: [], now: now) == .agentNever)
    }

    /// Every resume of a running VM used to type up to five spaces into the live guest, because
    /// `qemuStartedAt` was reset to "now" for a VM that had been up for half an hour.
    @Test("No keypress into a guest that is past the prompt, or one this run only took over")
    func noKeypressIntoALiveGuest() {
        func may(_ stage: CreateStage, restarts: Int = 0, tookOver: Bool = false) -> Bool {
            CreateRun.mayPressBootKey(stage: stage, restarts: restarts, tookOverRunningVM: tookOver)
        }
        // A first run, at the prompt: this is what the fallback is for.
        #expect(may(.boot))
        // Setup restarts WinPE from scratch when the VM was shut off in stage 6.
        #expect(may(.copy))
        // A disk boot has been seen: a key now would start the whole install again (FLOW F-BOOT).
        #expect(!may(.copy, restarts: 1))
        #expect(!may(.devices))
        #expect(!may(.oobe))
        #expect(!may(.firstLogon))
        // The VM was already running when this run took it over: Windows is wherever it is.
        #expect(!may(.boot, tookOver: true))
        #expect(!may(.copy, tookOver: true))
    }

    /// A resume at stage `finish` with the VM shut down couldn't re-read status.txt, and a nil
    /// result fell through to a clean `.done`: a failed install reported as a success, with the
    /// warnings about a password left in the guest silently skipped.
    @Test("The install's result survives a resume")
    func statusSurvivesAResume() {
        let failed = InstallStatus(ok: false, guestTools: .exitCode(3), remoteDesktopOn: false,
                                   values: ["result": "failed", "guest_tools": "3", "rdp": "off",
                                            "failed_steps": "rdp, panther", "plaintext_password": "yes",
                                            "error": "rdp: Set-ItemProperty threw at line 41"])
        let record = failed.record
        #expect(record.ok == false)
        #expect(record.guestTools == "3")
        #expect(record.remoteDesktopOn == false)
        #expect(record.failedSteps == ["rdp", "panther"])
        #expect(record.plaintextSecret)

        let reread = InstallStatus(record)
        #expect(reread.ok == failed.ok)
        #expect(reread.guestTools == failed.guestTools)
        #expect(reread.remoteDesktopOn == failed.remoteDesktopOn)
        #expect(reread.failedStepNames == ["Remote Desktop", "Setup's cached answer file"])
        #expect(reread.plaintextPassword)
        // Never the guest's own text: what Windows wrote is not Winbar's to keep in state.json.
        #expect(reread.error == nil)

        let ok = InstallStatus(ok: true, guestTools: .installed, remoteDesktopOn: true, values: ["guest_tools": "0"])
        #expect(InstallStatus(ok.record).ok)
        #expect(InstallStatus(ok.record).guestTools == .installed)
    }

    @Test("A state file from a Winbar without the new fields still decodes")
    func olderStateStillDecodes() throws {
        var object = try #require(try JSONSerialization.jsonObject(with: CreateJob.encodeState(testState()))
                                  as? [String: Any])
        for key in ["stageStartedAt", "watchedSeconds", "status", "installStartedAt", "stalled"] {
            object.removeValue(forKey: key)
        }
        let state = try #require(CreateJob.decodeState(try JSONSerialization.data(withJSONObject: object)))
        #expect(state.stageStartedAt == nil)
        #expect(state.watchedSeconds == nil)
        #expect(state.status == nil)
    }

    /// The window's per-stage clock read `updatedAt`, which the job rewrites every time it saves
    /// anything — so it counted to about thirty seconds and started again, all through an
    /// eleven-minute stage.
    @Test("The state says when the stage began, apart from when it was last written")
    func stageStartedAtRoundTrip() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = testMoment()
        let stageStartedAt = now.addingTimeInterval(-588)
        var state = testState(stage: .copy, updatedAt: now)
        state.stageStartedAt = stageStartedAt
        state.watchedSeconds = 1234
        state.status = testStatus()
        try CreateJob.writeState(state, in: directory)
        let read = try #require(CreateJob.state(in: directory))
        #expect(read == state)
        #expect(read.stageStartedAt == stageStartedAt)
        #expect(read.updatedAt != read.stageStartedAt)
        #expect(read.watchedSeconds == 1234)
        #expect(read.status == testStatus())
    }

    @Test("A state carrying the install's result still has nowhere to put a password")
    func theResultCarriesNoPassword() throws {
        var state = testState()
        state.status = CreateStatusRecord(ok: false, guestTools: "-2", remoteDesktopOn: false,
                                          failedSteps: ["autologon", "rdp"], plaintextSecret: true)
        let json = String(decoding: try CreateJob.encodeState(state), as: UTF8.self).lowercased()
        #expect(!json.contains("password"))
    }
}

// MARK: - Cancel

@Suite("Calling an install off")
struct CreateCancelTests {
    /// `--cancel` force-stopped whatever VM answered to the job's *name* and only then deleted by
    /// id. A rename, or a retry under the same default name, made that somebody else's running VM.
    @Test("Cancel only ever touches the VM that has the job's id")
    func cancelOnlyTouchesTheVMWithTheJobsID() {
        let ours = VMInfo(id: "5B0F2A11", name: "Windows 11 (old)", status: "started")
        let namesake = VMInfo(id: "0000FFFF", name: "Windows 11", status: "started")
        #expect(CreateRun.cancelTarget(vmID: "5B0F2A11", listed: [namesake, ours])?.id == ours.id)
        // The stop goes to the name that id answers to now, not to the job's plan.
        #expect(CreateRun.cancelTarget(vmID: "5B0F2A11", listed: [namesake, ours])?.name == "Windows 11 (old)")
        // The VM was deleted in UTM by hand: nothing is stopped and nothing is deleted.
        #expect(CreateRun.cancelTarget(vmID: "5B0F2A11", listed: [namesake]) == nil)
        #expect(CreateRun.cancelTarget(vmID: nil, listed: [namesake, ours]) == nil)
        // Ids are case-sensitive in UTM, and a near miss must not pass for a match.
        #expect(CreateRun.cancelTarget(vmID: "5b0f2a11", listed: [ours]) == nil)
    }

    /// The window's Cancel Install… ran `CreateJob.cancel`, which takes the lock — and `flock`
    /// refuses a second holder in the same process exactly as it refuses another process, so the
    /// cancel always threw E_BUSY into a `try?` and nothing was stopped or deleted.
    @Test("A second holder in this process is refused, which is why the window has its own cancel")
    func theWindowsCancelCannotTakeTheLock() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(".lock")
        let held = try #require(CreateLock(url: url))
        defer { held.release() }
        #expect(CreateLock(url: url) == nil, "flock is per open file description, in one process too")

        // So the window asks the run that holds the lock instead. With no run here, the request is
        // refused rather than quietly dropped, and nothing is left raised for a later run to obey.
        #expect(!CreateRun.isRunningHere)
        #expect(!CreateJob.requestCancel(deleteVM: true))
        #expect(CreateJob.cancelRequest.deleteVM == nil)
        // (`stopInstall` is the pair of them behind one call; it isn't exercised here because the
        // fallback takes the real lock and sweeps this Mac's own Create folder.)
    }

    @Test("The request carries what the person confirmed")
    func theRequestCarriesDeleteVM() {
        let request = CancelRequest()
        #expect(request.deleteVM == nil)
        request.raise(deleteVM: true)
        #expect(request.deleteVM == true)
        request.raise(deleteVM: false)
        #expect(request.deleteVM == false)   // "keep the VM" is a request, not the absence of one
        request.clear()
        #expect(request.deleteVM == nil)
    }

    @Test("A cancel says what it actually did")
    func aCancelSaysWhatItDid() {
        let done = CreateCancelResult(state: testState(), vmGone: true)
        #expect(!done.stopped)
        #expect(!done.deletedVM)
        #expect(!done.deletedSetupDisk)
        #expect(done.vmGone)
    }
}

// MARK: - What create is allowed to change

@Suite("What create changes outside itself")
struct CreateBlastRadiusTests {
    /// `--no-select` promises "Winbar keeps looking after the VM it has now". The select call was
    /// guarded; the MAC, the BitLocker record and the console flag weren't.
    @Test("--no-select records nothing at all in Winbar's settings")
    func noSelectRecordsNothing() {
        let created = CreatedVM(vmID: "5B0F2A11", systemDiskID: "D1", windowsCDID: "C1", setupCDID: "C2",
                                mac: "52:54:00:12:34:56", networkShared: true, serial: .ptty, displays: 1,
                                cores: 6, memoryMiB: 16384)
        var plan = testPlan()
        plan.select = false
        #expect(CreateRun.selection(plan: plan, created: created, bitLockerOn: true, headless: true) == nil)

        plan.select = true
        let selection = CreateRun.selection(plan: plan, created: created, bitLockerOn: true,
                                            headless: true)
        #expect(selection?.vmName == plan.vmName)
        #expect(selection?.mac == created.mac)
        #expect(selection?.rdpUser == plan.userName)
        #expect(selection?.consoleEnabled == false)
        #expect(selection?.bitLockerOn == true)
        #expect(selection?.keepBitLocker == false)   // the checklist's "don't use BitLocker" is on
    }

    @Test("A start only records the selected VM's MAC and display state")
    func startOnlyCachesTheSelectedVMsSettings() {
        #expect(UTM.shouldCacheSettings(vm: "winlab01", selected: "winlab01", asked: true))
        // create --no-select, even for a VM with the selected one's name.
        #expect(!UTM.shouldCacheSettings(vm: "winlab01", selected: "winlab01", asked: false))
        // The new VM, while Winbar still looks after another one.
        #expect(!UTM.shouldCacheSettings(vm: "Windows 11", selected: "winlab01", asked: true))
        #expect(!UTM.shouldCacheSettings(vm: "Windows 11", selected: nil, asked: true))
    }

    /// The "no other VMs are running" answer behind the quit could be 150 seconds old, because the
    /// display change UTM is given can take that long. winlab01 is the VM this would have killed.
    @Test("UTM is only quit on an answer from a moment ago, and a missing answer counts as busy")
    func utmIsNotQuitOnAStaleCheck() {
        #expect(CreateRun.restartDecision(.success([])).quit)
        let busy = CreateRun.restartDecision(.success(["winlab01"]))
        #expect(!busy.quit)
        #expect(busy.why.contains("winlab01"))
        #expect(busy.why.contains("is running now"))
        #expect(CreateRun.restartDecision(.success(["winlab01", "Ubuntu"])).why.contains("are running now"))
        let unknown = CreateRun.restartDecision(.failure(WinbarError("Couldn't ask UTM", "it didn't answer")))
        #expect(!unknown.quit)
        #expect(unknown.why.contains("couldn't confirm"))
    }

    /// Ctrl-C was ignored for the whole of stage 10 — up to a quarter of an hour of blocking waits
    /// with no output — because the ten-minute shutdown wait never looked at the flag.
    @Test("The shutdown wait can be given up on without touching the VM")
    func theShutdownWaitCanBeGivenUpOn() {
        let far = Date().addingTimeInterval(60)
        #expect(UTM.waitForStop(deadline: far, every: 0.01, stopped: { true }, abort: { false }) == true)
        // Ctrl-C: nil, and Windows is left shutting down.
        #expect(UTM.waitForStop(deadline: far, every: 0.01, stopped: { false }, abort: { true }) == nil)
        // Stopping wins over a flag raised at the same moment: the wait is over anyway.
        #expect(UTM.waitForStop(deadline: far, every: 0.01, stopped: { true }, abort: { true }) == true)
        // The deadline still ends it.
        #expect(UTM.waitForStop(deadline: Date().addingTimeInterval(-1), every: 0.01, stopped: { false },
                                abort: { false }) == false)
        // It really does poll: a VM that stops on the third look is seen.
        var looks = 0
        let stopped = UTM.waitForStop(deadline: far, every: 0.01, stopped: {
            looks += 1
            return looks >= 3
        }, abort: { false })
        #expect(stopped == true)
        #expect(looks == 3)
    }
}

// MARK: - What the ending says is left to do

@Suite("The ending's “what's left for you” line")
struct CreateEndingCopyTests {
    /// A job that raised one of the saved-PC notes.
    func state(pc code: String?) -> CreateJobState {
        var state = testState(stage: .finish, outcome: .done)
        if let code {
            state.messages = [CreateMessage(code: code, text: "…", at: testMoment())]
        }
        return state
    }

    /// The bug: `create` saves the PC in Windows App itself now, and the closing message went on
    /// asking the person to do it anyway — a step that was already done, next to two that weren't.
    @Test("With the PC saved, only the certificate and Accessibility are left")
    func savedPCIsNotOnTheList() {
        let done = state(pc: "N_PC_SAVED")
        #expect(done.wroteSavedPC)

        for line in [CreateCopy.nNextSetupSteps(savedPC: true), CreateCopy.nNextSetup(savedPC: true),
                     CreateCopy.nextSetup(savedPC: true)] {
            #expect(!line.contains("saving the PC"), "\(line)")
            #expect(!line.contains("Windows App"), "\(line)")
            #expect(line.contains("certificate"))
            #expect(line.contains("Accessibility"))
            #expect(line.contains("two things"))
            #expect(!line.contains("three things"))
        }
    }

    /// Every way it didn't get written — Windows App open, a PC already there, the command line
    /// failing, no Windows App at all — still leaves the person to do it, so it stays on the list.
    @Test("With the PC not saved, saving it is back on the list")
    func unsavedPCIsOnTheList() {
        for code in ["N_PC_APP_RUNNING", "N_PC_EXISTS", "N_PC_FAILED", nil] {
            let job = state(pc: code)
            #expect(!job.wroteSavedPC, "\(code ?? "no note at all")")

            for line in [CreateCopy.nNextSetupSteps(savedPC: job.wroteSavedPC),
                         CreateCopy.nNextSetup(savedPC: job.wroteSavedPC),
                         CreateCopy.nextSetup(savedPC: job.wroteSavedPC)] {
                #expect(line.contains("saving the PC in Windows App"), "\(line)")
                #expect(line.contains("certificate"))
                #expect(line.contains("Accessibility"))
                #expect(line.contains("three things"))
            }
        }
    }

    /// Both front-ends read the same sentence: the window adds the headless offer, Terminal adds
    /// the command and what headless measured, and neither rewords the list.
    @Test("Terminal and the window say the same things are left")
    func bothFrontEndsAgree() {
        for savedPC in [true, false] {
            let steps = CreateCopy.nNextSetupSteps(savedPC: savedPC)
            #expect(CreateCopy.nNextSetup(savedPC: savedPC).hasPrefix(steps))
            #expect(CreateCopy.nextSetup(savedPC: savedPC).contains(steps))
        }
    }

    @Test("The list reads as a sentence, however many things are on it")
    func theListIsPunctuated() {
        #expect(CreateCopy.list([]) == "")
        #expect(CreateCopy.list(["one"]) == "one")
        #expect(CreateCopy.list(["one", "two"]) == "one and two")
        #expect(CreateCopy.list(["one", "two", "three"]) == "one, two, and three")
        #expect(CreateCopy.spelled(2) == "two")
        #expect(CreateCopy.spelled(3) == "three")
        #expect(CreateCopy.spelled(9) == "9")
    }
}
