import Foundation
import Testing
@testable import Winbar

// The install job's pure logic and its files: state.json, the lock, the log, the sweep's decision,
// the stage heuristic, the limits' wiring and the headless rule. Nothing here may reach UTM or a VM:
// every function under test takes its inputs as values or as a path in a temporary folder.

// MARK: - Fixtures

func testEdition(_ name: String = "Windows 11 Pro", id: String = "Professional", index: Int = 3) -> WindowsEdition {
    WindowsEdition(index: index, name: name, displayName: name, editionID: id)
}

func testImage(editions: [WindowsEdition] = [testEdition("Windows 11 Home", id: "Core", index: 1),
                                             testEdition("Windows 11 Home Single Language", id: "CoreSingleLanguage", index: 2),
                                             testEdition()]) -> WindowsImageInfo {
    WindowsImageInfo(path: "/Users/alex/Downloads/Win11_25H2_English_Arm64_v2.iso", build: 26200,
                     fullBuild: "26200.8037", language: "en-US", editions: editions, isArm64: true, bootPrompts: true)
}

func testPlan(name: String = "Windows 11", options: Set<CreateOption> = CreateOption.defaults,
              edition: WindowsEdition = testEdition()) -> CreatePlan {
    CreatePlan(vmName: name, isoPath: "/Users/alex/Downloads/Win11_25H2_English_Arm64_v2.iso", edition: edition,
               cores: 6, memoryMiB: 16384, diskGiB: 128, options: options, noVisualTweaks: false, userName: "alex",
               computerName: "Windows-11", regional: nil, select: true, keepConsole: false)
}

/// Whole seconds: state.json stores ISO-8601 times, which don't keep fractions, and a test that
/// compares a written state with the one read back must compare what the file can hold.
func testMoment(_ offset: TimeInterval = 0) -> Date {
    Date(timeIntervalSince1970: (Date().timeIntervalSince1970 + offset).rounded(.down))
}

func testState(stage: CreateStage = .copy, vmID: String? = "5B0F2A11", outcome: CreateJobState.Outcome? = nil,
               watched: Bool = true, updatedAt: Date = testMoment(), plan: CreatePlan = testPlan()) -> CreateJobState {
    CreateJobState(id: "create-20260919-170211-abcd1234", plan: plan, vmID: vmID, stage: stage,
                   detail: "7.9 GB written to the VM's disk", startedAt: updatedAt.addingTimeInterval(-600),
                   updatedAt: updatedAt, finishedAt: nil, outcome: outcome, restarts: 0, bytesWritten: 7_900_000_000,
                   shown: [], messages: [], failure: nil, mediaDir: nil, logPath: nil, watched: watched)
}

/// A private folder that goes away with the test.
func temporaryDirectory(_ name: String = "winbar-create-test") throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    return url
}

// MARK: - state.json

@Suite("The job's state file")
struct CreateJobStateTests {
    @Test("A state survives a round trip through the file, dates and all")
    func roundTrip() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var state = testState()
        state.created = CreatedVM(vmID: "5B0F2A11", systemDiskID: "D1", windowsCDID: "C1", setupCDID: "C2",
                                  mac: "52:54:00:12:34:56", networkShared: true, serial: .ptty, displays: 1,
                                  cores: 6, memoryMiB: 16384)
        state.installStartedAt = Date(timeIntervalSince1970: 1_790_000_000)
        state.messages = [CreateMessage(code: "W_STALL", text: CreateCopy.wStall,
                                        at: Date(timeIntervalSince1970: 1_790_000_100))]
        state.stalled = true
        try CreateJob.writeState(state, in: directory)

        let read = try #require(CreateJob.state(in: directory))
        #expect(read == state)
        #expect(read.created?.systemDiskID == "D1")
        #expect(read.messages.first?.code == "W_STALL")
        // W_STALL is said once; `stalled` is what both front-ends watch to take the note down again.
        #expect(read.stalled == true)
        #expect(CreateCopy.wStall.hasPrefix("Nothing has changed for 10 minutes."))
        #expect(CreateCopy.wStall.lowercased().hasPrefix(CreateCopy.wStallShort))
    }

    @Test("A half-written state reads as no state at all, rather than as a wrong one")
    func halfWritten() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try CreateJob.writeState(testState(), in: directory)
        let file = directory.appendingPathComponent(CreateJob.stateFileName)
        let whole = try Data(contentsOf: file)
        try whole.prefix(whole.count / 2).write(to: file)
        #expect(CreateJob.state(in: directory) == nil)
        #expect(CreateJob.decodeState(Data()) == nil)
        #expect(CreateJob.decodeState(Data("{}".utf8)) == nil)
    }

    @Test("The state is written by rename, so a reader never sees a partial file")
    func writtenAtomically() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try CreateJob.writeState(testState(), in: directory)
        try CreateJob.writeState(testState(stage: .oobe), in: directory)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(names == [CreateJob.stateFileName])   // no .tmp left behind
        #expect(CreateJob.state(in: directory)?.stage == .oobe)
    }

    @Test("A job id is a folder name the media builder accepts")
    func jobID() {
        let id = CreateJob.newJobID(now: Date(timeIntervalSince1970: 1_790_000_000))
        #expect(SetupMedia.isValidID(id))
        #expect(id.hasPrefix("create-"))
        #expect(CreateJob.newJobID() != CreateJob.newJobID())
    }
}

// MARK: - The lock

@Suite("One install at a time")
struct CreateLockTests {
    @Test("A second holder is refused while the first has it, and let in once it's released")
    func exclusive() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(".lock")

        let first = try #require(CreateLock(url: url))
        #expect(CreateLock(url: url) == nil)
        first.release()

        let second = try #require(CreateLock(url: url))
        #expect(CreateLock(url: url) == nil)
        second.release()
        #expect(CreateLock(url: url) != nil)
    }

    @Test("Releasing twice is harmless")
    func releaseTwice() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let lock = try #require(CreateLock(url: directory.appendingPathComponent(".lock")))
        lock.release()
        lock.release()
    }
}

// MARK: - The sweep (D3)

@Suite("Sweeping orphaned jobs")
struct CreateSweepTests {
    @Test("A job whose VM is gone from UTM goes; one whose VM is still there stays")
    func vmGone() {
        let state = testState(vmID: "GONE")
        #expect(CreateJob.sweepDecision(state, vmIDs: ["OTHER"], lockHeld: false, folderAge: 10, now: Date()))
        #expect(!CreateJob.sweepDecision(state, vmIDs: ["GONE"], lockHeld: false, folderAge: 10, now: Date()))
    }

    @Test("UTM couldn't be asked, so nothing that claims a VM is touched")
    func utmUnknown() {
        #expect(!CreateJob.sweepDecision(testState(), vmIDs: nil, lockHeld: false, folderAge: 10, now: Date()))
    }

    @Test("A job someone is watching is never swept, even when UTM doesn't list its VM")
    func watched() {
        let state = testState(vmID: "GONE", watched: true)
        #expect(!CreateJob.sweepDecision(state, vmIDs: [], lockHeld: true, folderAge: 10_000, now: Date()))
        // …but a stale "watched" with nobody holding the lock doesn't protect it.
        #expect(CreateJob.sweepDecision(state, vmIDs: [], lockHeld: false, folderAge: 10_000, now: Date()))
    }

    @Test("A finished job goes whatever UTM says")
    func finished() {
        let state = testState(outcome: .done, watched: false)
        #expect(CreateJob.sweepDecision(state, vmIDs: nil, lockHeld: false, folderAge: 1, now: Date()))
    }

    @Test("A folder with no state has to be stale first: another process may just have made it")
    func noState() {
        #expect(!CreateJob.sweepDecision(nil, vmIDs: nil, lockHeld: false, folderAge: 5, now: Date()))
        #expect(CreateJob.sweepDecision(nil, vmIDs: nil, lockHeld: false, folderAge: CreateJob.staleAge + 1, now: Date()))
        #expect(!CreateJob.sweepDecision(nil, vmIDs: nil, lockHeld: true, folderAge: CreateJob.staleAge + 1, now: Date()))
    }

    @Test("A job abandoned before its VM existed goes once it has sat still for an hour")
    func abandonedBeforeVM() {
        let now = Date()
        let fresh = testState(stage: .media, vmID: nil, watched: false, updatedAt: now.addingTimeInterval(-60))
        let old = testState(stage: .media, vmID: nil, watched: false, updatedAt: now.addingTimeInterval(-7200))
        #expect(!CreateJob.sweepDecision(fresh, vmIDs: nil, lockHeld: false, folderAge: 60, now: now))
        #expect(CreateJob.sweepDecision(old, vmIDs: nil, lockHeld: false, folderAge: 7200, now: now))
    }
}

// MARK: - Stages and limits

@Suite("Stages, limits and the headless rule")
struct CreateRunLogicTests {
    @Test("Restarts, the agent and the status file decide the stage")
    func stageFromSignals() {
        func stage(_ restarts: Int, prompt: Bool = true, agent: Bool = false, status: Bool = false,
                   from current: CreateStage = .boot) -> CreateStage {
            CreateRun.stage(for: CreateRun.Signals(restarts: restarts, promptAnswered: prompt, agentAnswered: agent,
                                                   statusComplete: status), current: current)
        }
        #expect(stage(0, prompt: false) == .boot)
        #expect(stage(0) == .copy)
        #expect(stage(1) == .devices)
        #expect(stage(2) == .oobe)
        #expect(stage(5) == .oobe)
        // The agent answering moves it on whatever the restart count says.
        #expect(stage(0, agent: true) == .firstLogon)
        #expect(stage(9, agent: true, status: true) == .finish)
    }

    @Test("The stage never steps backwards")
    func stageNeverGoesBack() {
        let signals = CreateRun.Signals(restarts: 0, promptAnswered: true, agentAnswered: false, statusComplete: false)
        #expect(CreateRun.stage(for: signals, current: .oobe) == .oobe)
        #expect(CreateRun.stage(for: signals, current: .firstLogon) == .firstLogon)
    }

    @Test("The two-hour limit is measured from when stage 5 began, not from this start")
    func timeoutWiring() {
        let now: TimeInterval = 100_000
        let times = CreateRun.installTimes(stage: .oobe, watchedFor: InstallLimits.whole + 60, qemuStartedAt: now - 300,
                                           serialConsole: true, promptMissed: false, restarts: 2,
                                           lastRestartAt: now - 60, agentAnsweredAt: nil, now: now)
        #expect(InstallWatch.evaluate(times, history: [], now: now) == .timeout)
    }

    @Test("A silent agent after the last restart is E_AGENT_NEVER, and only after fifteen minutes")
    func agentNeverWiring() {
        let now: TimeInterval = 100_000
        func times(sinceRestart: TimeInterval) -> InstallTimes {
            CreateRun.installTimes(stage: .oobe, watchedFor: 1800, qemuStartedAt: now - 1800, serialConsole: true,
                                   promptMissed: false, restarts: 2, lastRestartAt: now - sinceRestart,
                                   agentAnsweredAt: nil, now: now)
        }
        #expect(InstallWatch.evaluate(times(sinceRestart: 60), history: [], now: now) == nil)
        #expect(InstallWatch.evaluate(times(sinceRestart: InstallLimits.agentSilence + 1), history: [], now: now) == .agentNever)
    }

    @Test("A missed prompt is reported once, then left alone")
    func promptWiring() {
        let now: TimeInterval = 100_000
        let times = CreateRun.installTimes(stage: .boot, watchedFor: 60, qemuStartedAt: now - 60, serialConsole: true,
                                           promptMissed: true, restarts: 0, lastRestartAt: nil, agentAnsweredAt: nil,
                                           now: now)
        #expect(InstallWatch.evaluate(times, history: [], now: now) == .bootNoPrompt)
        #expect(InstallWatch.evaluate(times, history: [], now: now, shown: [.bootNoPrompt]) == nil)
    }

    @Test("Headless at the end needs every signal (D2)")
    func headless() {
        let ok = InstallStatus(ok: true, guestTools: .installed, remoteDesktopOn: true, values: [:])
        func decide(plan: CreatePlan = testPlan(), status: InstallStatus? = nil,
                    readiness: RDP.Readiness = .ready, others: [String] = []) -> (go: Bool, why: String) {
            CreateRun.headlessDecision(plan: plan, status: status ?? ok, readiness: readiness, otherVMsRunning: others)
        }
        #expect(decide().go)
        #expect(!decide(readiness: .notReady).go)
        #expect(!decide(readiness: .blocked).go)
        #expect(!decide(others: ["Ubuntu"]).go)
        #expect(decide(others: ["Ubuntu"]).why.contains("Ubuntu"))
        #expect(!decide(status: InstallStatus(ok: true, guestTools: .installed, remoteDesktopOn: false, values: [:])).go)
        #expect(!decide(status: InstallStatus(ok: false, guestTools: .installed, remoteDesktopOn: true, values: [:])).go)

        var console = testPlan()
        console.keepConsole = true
        #expect(!decide(plan: console).go)

        var home = testPlan(edition: testEdition("Windows 11 Home", id: "Core", index: 1))
        home.options.remove(.remoteDesktop)
        #expect(!decide(plan: home).go)

        var noRDP = testPlan()
        noRDP.options.remove(.remoteDesktop)
        #expect(!decide(plan: noRDP).go)
    }

    @Test("Without a status file there is nothing to go headless on")
    func headlessWithoutStatus() {
        let decision = CreateRun.headlessDecision(plan: testPlan(), status: nil, readiness: .ready, otherVMsRunning: [])
        #expect(!decision.go)
    }
}

// MARK: - Preflight pieces

@Suite("Preflight rules")
struct CreatePreflightTests {
    @Test("UTM before 4.7 is refused, and an untested one only warns")
    func utmVersion() {
        #expect(CreatePreflight.utmVersionProblem("4.6.9")?.failure.code == "E_UTM_OLD")
        #expect(CreatePreflight.utmVersionProblem("4.7.5") == nil)
        #expect(CreatePreflight.utmVersionProblem("5.0.5") == nil)
        #expect(CreatePreflight.utmVersionProblem(nil) == nil)
        #expect(CreatePreflight.utmVersionProblem("4.6.9")?.exitCode == 69)
        #expect(CreatePreflight.utmVersionWarning("4.7.5") == nil)
        #expect(CreatePreflight.utmVersionWarning("5.0.5")?.contains("5.0.5") == true)
    }

    @Test("Free space: under 40 GB refuses, under the disk size warns")
    func space() {
        let tight = CreatePreflight.Space(volume: "Macintosh HD", freeBytes: 30 << 30)
        let enough = CreatePreflight.Space(volume: "Macintosh HD", freeBytes: 100 << 30)
        let plenty = CreatePreflight.Space(volume: "Macintosh HD", freeBytes: 400 << 30)
        #expect(CreatePreflight.spaceProblem(tight)?.failure.code == "E_SPACE")
        #expect(CreatePreflight.spaceProblem(tight)?.exitCode == 65)
        #expect(CreatePreflight.spaceProblem(enough) == nil)
        #expect(CreatePreflight.spaceWarning(enough, diskGiB: 128)?.contains("128 GB") == true)
        #expect(CreatePreflight.spaceWarning(plenty, diskGiB: 128) == nil)
        // A volume that won't say how much is free isn't a reason to refuse.
        #expect(CreatePreflight.spaceProblem(CreatePreflight.Space(volume: "?", freeBytes: 0)) == nil)
    }

    @Test("pmset's power source")
    func battery() {
        #expect(CreatePreflight.parseBattery("Now drawing from 'Battery Power'\n -InternalBattery-0 91%"))
        #expect(!CreatePreflight.parseBattery("Now drawing from 'AC Power'\n -InternalBattery-0 100%; charged"))
    }

    @Test("A start that failed because UTM lost an ISO gets its own message")
    func startFailure() {
        #expect(CreatePreflight.startFailureCode(WinbarError("Couldn't start", "Failed to access drive image path")) == "E_UTM_ISO_ACCESS")
        #expect(CreatePreflight.startFailureCode(WinbarError("Couldn't start", "something else")) == "E_START")
        #expect(CreatePreflight.startFailureCode(Automation.deniedError()) == "E_AUTOMATION")
    }
}

// MARK: - What the job hands the two front-ends

/// The seam CreateWindow and CreateCLI both rely on.
@Suite("The job's side of the seam")
struct CreateSeamTests {
    @Test("A name UTM already has comes back as a field problem, not as a failed install")
    func nameTaken() {
        let clash = CreateJobError.input("E_NAME_TAKEN", ChoiceProblem.nameTaken("Windows 11").description)
        let raised = CreateRun.asChoiceProblem(clash, vmName: "Windows 11")
        #expect(raised as? ChoiceProblem == .nameTaken("Windows 11"))
        // Everything else stays what it was, with its own exit code.
        let other = CreateJobError.unavailable("E_UTM_CREATE", "UTM couldn't create the VM")
        #expect((CreateRun.asChoiceProblem(other, vmName: "Windows 11") as? CreateJobError)?.failure.code
                == "E_UTM_CREATE")
    }

    /// The two front-ends are written separately and must not drift: the stage titles and the
    /// failure's words come from the job, and neither Terminal nor the window rewrites them.
    @Test("Terminal and the window take the same words from the same place")
    func frontEndsSayTheSameThing() {
        let started = testMoment(-900)
        for stage in CreateStage.allCases {
            var job = testState(stage: stage, updatedAt: testMoment())
            job.detail = "7.9 GB written to the VM's disk"
            job.startedAt = started
            let window = CreateProgress(state: job, now: testMoment())
            // Wide enough that nothing is cut: a narrow terminal ends the line in "…" instead.
            let terminal = CreateProgressPrinter.line(job, spinner: "⠼", elapsed: 588, width: 200)
            #expect(CreateProgressPrinter.line(job, spinner: "⠼", elapsed: 588, width: 100).count <= 100)

            let running = window.rows[stage.number - 1]
            #expect(running.mark == .running)
            #expect(running.title == stage.runningTitle)
            #expect(terminal.contains(stage.runningTitle), "\(stage.rawValue) in Terminal")
            #expect(running.detail == job.detail)
            #expect(terminal.contains(job.detail ?? ""), "the detail in Terminal")
            #expect(window.step == "step \(stage.number) of 10")
            #expect(terminal.contains("step \(stage.number) of 10"))
            // Every stage before this one is done, in the done title's words, in both.
            for earlier in CreateStage.allCases where earlier.number < stage.number {
                #expect(window.rows[earlier.number - 1] == CreateProgress.Row(stage: earlier, mark: .done,
                                                                              title: earlier.doneTitle))
            }
        }

        // A failure: one CreateFailure, the same words on both sides.
        let failure = CreateFailure(code: "E_TIMEOUT", title: "Windows still hadn't finished installing after 2 hours",
                                    detail: "The VM is still running: look at its window in UTM.",
                                    nextStep: "To start over: winbar create --cancel \"Windows 11\".")
        var failed = testState(stage: .oobe, outcome: .failed)
        failed.failure = failure
        let terminal = CreateCLI.failureLines(CreateJobError(failure: failure, exit: 1), state: failed,
                                              logPath: "/tmp/create.log", vmName: failed.plan.vmName, width: 100)
            .joined(separator: "\n")
        #expect(terminal.contains(failure.title))
        #expect(terminal.contains(failure.detail))
        #expect(terminal.contains(failure.nextStep ?? ""))
        #expect(CreateJobView.failureHeader(failed).contains(failure.title))
        // The window shows the stage list beside it, with the failed stage crossed out.
        #expect(CreateProgress(state: failed, now: testMoment()).rows[failed.stage.number - 1].mark == .failed)
        #expect(terminal.contains(failed.stage.runningTitle))

        // Windows installed, some first sign-in steps didn't: the milder ending, one sentence.
        var problems = testState(stage: .firstLogon, outcome: .failed)
        problems.failure = CreateFailure(code: "E_RESULT_FAILED", title: "Some of Winbar's first sign-in steps failed",
                                         detail: "", nextStep: nil)
        let sentence = CreateCopy.installedWithProblems(edition: problems.plan.edition.displayName,
                                                        name: problems.plan.vmName)
        #expect(CreateJobView.failureHeader(problems) == "! " + sentence)
        let milder = CreateCLI.failureLines(CreateJobError(failure: problems.failure!, exit: 1), state: problems,
                                            logPath: nil, vmName: problems.plan.vmName, width: 100)
            .joined(separator: "\n")
        #expect(milder.contains(sentence.replacingOccurrences(of: ", with problems", with: "")))
        #expect(milder.contains("with problems"))
    }

    @Test("The Automation detail carries the mark the window swaps its own wording in on")
    func automationDetail() {
        let line = CreateCopy.automationDetail(app: "Terminal")
        #expect(line.contains("Terminal"))
        #expect(line.contains(CreateCopy.automationDetailMark))
        #expect(CreateProgress.detail(line) == CreateCopy.pAutomation)
        #expect(CreateProgress.detail("7.9 GB written to the VM's disk") == "7.9 GB written to the VM's disk")
    }
}

// MARK: - The log, and the password's life

@Suite("The log and the password")
struct CreateLogTests {
    @Test("The log is named for the VM and the minute it started")
    func name() {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let name = CreateLog.fileName(vmName: "Windows 11", at: date)
        #expect(name.hasPrefix("create-Windows 11-"))
        #expect(name.hasSuffix(".log"))
        #expect(name.count == "create-Windows 11-20260919-1702.log".count)
    }

    @Test("The serial log sits beside it")
    func serialName() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = CreateLog(vmName: "Windows 11", directory: directory)
        #expect(log.serialURL.lastPathComponent.hasSuffix(".serial.log"))
        #expect(log.serialURL.deletingLastPathComponent() == log.url.deletingLastPathComponent())
    }

    /// The promise: the password reaches the answer file and nothing else. This writes the
    /// files the job writes, with a canary, and reads every byte back.
    @Test("Nothing but the answer file ever holds the password")
    func passwordStaysInTheAnswerFile() throws {
        let canary = "Zx9-canary-PASSWORD-42"
        let base64 = AnswerFile.obscure(canary)
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        var plan = testPlan()
        plan.regional = RegionalValues(userLocale: "en-GB", systemLocale: "en-GB", inputLocale: "0809:00000809",
                                       timeZone: "GMT Standard Time", summary: "English (United Kingdom)")
        let files = try AnswerFile.render(plan: plan, image: testImage(), password: canary)
        for file in files {
            try file.contents.write(to: directory.appendingPathComponent(file.name))
        }

        // The state, with everything the job puts in it.
        var state = testState(plan: plan)
        state.created = CreatedVM(vmID: "5B0F2A11", systemDiskID: "D1", windowsCDID: "C1", setupCDID: "C2",
                                  mac: "52:54:00:12:34:56", networkShared: true, serial: .ptty, displays: 1,
                                  cores: 6, memoryMiB: 16384)
        state.messages = [CreateMessage(code: "W_STALL", text: "Nothing has changed for 10 minutes.", at: testMoment())]
        state.failure = CreateFailure(code: "E_TIMEOUT", title: "…", detail: "…", nextStep: nil)
        try CreateJob.writeState(state, in: directory)

        // The log, written the way the job writes it.
        let log = CreateLog(vmName: plan.vmName, directory: directory)
        log.write("winbar create “\(plan.vmName)”: \(plan.cores) vCPUs, ISO \(plan.isoPath)")
        log.write("checklist: " + CreateOption.allCases.map { "\($0.rawValue)=\(plan.has($0))" }.joined(separator: " "))
        log.write("stage 3/10 media: \(CreateStage.media.runningTitle)")
        log.writeBlock("Windows' first-logon log:", "result=ok\nguest_tools=0\nrdp=on")

        let answerFile = AnswerFile.answerFileName.lowercased()
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
            let text = String(decoding: try Data(contentsOf: directory.appendingPathComponent(name)), as: UTF8.self)
            #expect(!text.contains(canary), "\(name) holds the password in plain text")
            if name.lowercased() == answerFile {
                #expect(text.contains(base64), "the answer file should carry the obscured password")
            } else {
                #expect(!text.contains(base64), "\(name) holds the obscured password")
            }
        }
    }

    @Test("The plan and the state have nowhere to put a password")
    func noPasswordField() throws {
        let plan = testPlan()
        let planJSON = String(decoding: try JSONEncoder.job.encode(plan), as: UTF8.self).lowercased()
        let stateJSON = String(decoding: try CreateJob.encodeState(testState()), as: UTF8.self).lowercased()
        #expect(!planJSON.contains("password"))
        #expect(!stateJSON.contains("password"))
    }

    /// The product key is in the answer file as plain text — that is the whole point, and the only place it
    /// can be. Everything else the job writes or says is checked for it here: the state, the log, the note
    /// the job raises about the key, and the plan, which has no field to put one in.
    @Test("Nothing but the answer file ever holds the product key")
    func productKeyStaysInTheAnswerFile() throws {
        let canary = "BCDFG-HJKMN-PQRTV-WXY23-46789"       // shaped like a key, and nobody's
        #expect(CreateChoices.normalizedProductKey(canary) == canary)
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let plan = testPlan()
        let files = try AnswerFile.render(plan: plan, image: testImage(), password: "Winbar-Test-Pa55!",
                                          productKey: canary)
        for file in files {
            try file.contents.write(to: directory.appendingPathComponent(file.name))
        }

        var state = testState(plan: plan)
        state.messages = [CreateMessage(code: "N_PRODUCT_KEY", text: CreateCopy.nProductKey, at: testMoment())]
        try CreateJob.writeState(state, in: directory)
        #expect(state.usedProductKey)

        let log = CreateLog(vmName: plan.vmName, directory: directory)
        log.write("N_PRODUCT_KEY: \(CreateCopy.nProductKey)")
        log.write("stage 3/10 media: \(CreateStage.media.runningTitle)")

        let answerFile = AnswerFile.answerFileName.lowercased()
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
            let text = String(decoding: try Data(contentsOf: directory.appendingPathComponent(name)), as: UTF8.self)
            if name.lowercased() == answerFile {
                #expect(text.contains("<Key>\(canary)</Key>"), "the answer file should carry the key")
            } else {
                #expect(!text.contains(canary), "\(name) holds the product key")
            }
        }
        let planJSON = String(decoding: try JSONEncoder.job.encode(plan), as: UTF8.self).lowercased()
        #expect(!planJSON.contains("productkey") && !planJSON.contains("product_key"))
    }

    /// The copy that says a key was used never says which. Both front-ends show these.
    @Test("The product-key copy carries no key")
    func productKeyCopyCarriesNoKey() {
        for text in [CreateCopy.nProductKey, CreateCopy.nActivating, CreateCopy.productKeyTooltip,
                     CreateCopy.beforeProductKey, CreateCopy.productKeyWhyPrompt,
                     ChoiceProblem.productKeyShape.description,
                     Checklist.productKeyLine(wanted: true), Checklist.productKeyLine(wanted: false)] {
            // Nothing in the deck is shaped like a key: no five-groups-of-five anywhere.
            let groups = text.split(whereSeparator: { $0 == " " || $0 == "\n" })
                .filter { CreateChoices.normalizedProductKey(String($0)) != nil }
            #expect(groups.isEmpty, "\(text)")
        }
        #expect(CreateCopy.nProductKey.contains("plain text"))
        #expect(CreateCopy.nProductKey.contains("Time Machine"))
        #expect(CreateCopy.nProductKey.contains("deletes it"))
    }

    @Test("The arguments create-vm is given carry no secret")
    func vmArgumentsAreHarmless() {
        // What CreateRun passes to the script: the name, two paths and three numbers.
        let plan = testPlan()
        let arguments = [plan.vmName, plan.isoPath, "/tmp/x/WINBAR_SETUP.iso", String(plan.cores),
                         String(plan.memoryMiB), String(plan.diskGiB * 1024)]
        #expect(arguments.allSatisfy { !$0.lowercased().contains("password") })
    }
}
