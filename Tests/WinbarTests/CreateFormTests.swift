import Foundation
import Testing
@testable import Winbar

// The New Windows VM window's view model. Views aren't tested; what they show is:
// which field blocks Create and in what order, the fields that follow other fields, the warnings,
// and the wording of the progress view. Every Mac fact is passed in, so nothing here touches this
// Mac, UTM or a VM.

private func facts(cores: Int = 10, totalCores: Int = 12, memoryGB: Int = 64, user: String = "alex",
                   utmInstalled: Bool = true, utmVersion: String? = "4.7.5", fileVaultOn: Bool? = true,
                   freeGB: Int? = 500, existing: [String]? = nil, menuVM: String? = nil) -> CreateFormFacts {
    CreateFormFacts(mac: MacFacts(topTierCores: cores, totalCores: totalCores,
                                  memoryBytes: UInt64(memoryGB) << 30, shortUserName: user),
                    utmInstalled: utmInstalled, utmVersion: utmVersion, fileVaultOn: fileVaultOn,
                    freeGB: freeGB, volumeName: "Macintosh HD", existingVMNames: existing, menuVMName: menuVM)
}

private let pro = WindowsEdition(index: 3, name: "Windows 11 Pro", displayName: "Windows 11 Pro",
                                 editionID: "Professional")
private let home = WindowsEdition(index: 1, name: "Windows 11 Home", displayName: "Windows 11 Home",
                                  editionID: "Core")

private func image(build: Int = 26200, editions: [WindowsEdition] = [home, pro]) -> WindowsImageInfo {
    WindowsImageInfo(path: "/Users/alex/Downloads/Win11_25H2_English_Arm64_v2.iso", build: build, fullBuild: nil,
                     language: "en-US", editions: editions, isArm64: true, bootPrompts: true)
}

private let regional = Regional.reading(macLocale: "en_GB", keyboard: Regional.Keyboard(macName: "British",
                                                                                        inputLocale: "0809:00000809"),
                                        ianaZone: "Europe/London", imageLanguage: "en-US")

/// A model with an ISO already read, so only the field under test blocks Create.
private func readyModel(_ given: CreateFormFacts = facts(), build: Int = 26200,
                        editions: [WindowsEdition] = [home, pro]) -> CreateFormModel {
    let model = CreateFormModel(facts: given)
    model.iso = .read(CreateFormModel.ISOFacts(path: image().path, info: image(build: build, editions: editions),
                                               regional: regional, removableVolume: nil))
    model.password = "hunter2"
    model.confirmation = "hunter2"
    return model
}

@Suite struct CreateFormDefaults {
    @Test func defaultsComeFromTheMacAndUTMsNames() {
        let model = CreateFormModel(facts: facts(cores: 10, memoryGB: 64, user: "alex", existing: ["Windows 11"]))
        #expect(model.vmName == "Windows 11 (2)")
        #expect(model.cores == 8)                       // top-tier count, kept between 4 and 8
        #expect(model.memoryGB == 16)                   // 16 GB from 64 GB of Mac memory
        #expect(model.diskGB == 128)
        #expect(model.userName == "alex")
        #expect(model.computerName == "Windows-11-2")
    }

    /// A Mac short name Windows refuses leaves the field empty, so the person picks one.
    @Test func aReservedMacNameLeavesTheUserNameEmpty() {
        let model = CreateFormModel(facts: facts(user: "administrator"))
        #expect(model.userName == "")
        #expect(model.userNameError == ChoiceProblem.userEmpty.description)
    }

    @Test func theEditionFollowsTheISOAndPrefersPro() {
        let model = CreateFormModel(facts: facts())
        #expect(model.edition == nil)
        model.iso = .read(CreateFormModel.ISOFacts(path: image().path, info: image(), regional: regional,
                                                   removableVolume: nil))
        #expect(model.edition == pro)
    }
}

@Suite struct CreateFormComputerName {
    @Test func itFollowsTheVMNameUntilItIsEdited() {
        let model = CreateFormModel(facts: facts())
        #expect(model.computerName == "Windows-11")
        model.vmName = "Alex's Work PC"
        #expect(model.computerName == "Alexs-Work-PC")
        #expect(model.computerNameEdited == false)

        model.computerName = "Bench"
        #expect(model.computerNameEdited)
        model.vmName = "Something Else"
        #expect(model.computerName == "Bench")
    }

    /// The derivation ends in "-PC" when the two names would clash, so it has to follow the user
    /// name as well as the VM name.
    @Test func itAlsoFollowsTheUserName() {
        let model = CreateFormModel(facts: facts(user: "alex"))
        model.vmName = "Bench"
        #expect(model.computerName == "Bench")
        model.userName = "bench"
        #expect(model.computerName == "Bench-PC")
    }

    @Test func theHostNameShownIsTheLowercasedName() {
        #expect(CreateChoices.hostName(computerName: "Windows-11") == "windows-11.local")
    }
}

@Suite struct CreateFormHomeEdition {
    /// Home can't accept Remote Desktop connections, so the row goes off and comes back as it was.
    @Test func homeTurnsRemoteDesktopOffAndProRestoresIt() {
        let model = readyModel()
        #expect(model.options.contains(.remoteDesktop))
        model.edition = home
        #expect(!model.options.contains(.remoteDesktop))
        #expect(!model.isEnabled(.remoteDesktop))
        #expect(model.homeWarning == ChoiceWarning.home.description)
        model.edition = pro
        #expect(model.options.contains(.remoteDesktop))
        #expect(model.isEnabled(.remoteDesktop))
        #expect(model.homeWarning == nil)
    }

    @Test func homeDoesNotResurrectARowTheyTurnedOff() {
        let model = readyModel()
        model.options.remove(.remoteDesktop)
        model.edition = home
        model.edition = pro
        #expect(!model.options.contains(.remoteDesktop))
    }

    @Test func lockedRowsAreNeverClickable() {
        let model = readyModel()
        for option in CreateOption.allCases where option.isLocked {
            #expect(!model.isEnabled(option))
        }
        #expect(model.isEnabled(.qol))
    }
}

@Suite struct CreateFormStatusLine {
    @Test func itNamesTheFirstThingThatBlocksCreate() {
        let model = CreateFormModel(facts: facts())
        #expect(model.status == .blocked(CreateCopy.fNeedISO))
        #expect(!model.canCreate)

        model.iso = .reading(file: "Win11.iso")
        #expect(model.status == .blocked(CreateCopy.isoReading))

        model.iso = .failed(file: "Win11.iso", message: "not a Windows installer")
        #expect(model.status == .blocked("not a Windows installer"))

        model.iso = .read(CreateFormModel.ISOFacts(path: image().path, info: image(), regional: regional,
                                                   removableVolume: nil))
        #expect(model.status == .blocked(CreateCopy.fNeedPassword(user: "alex")))

        model.password = "hunter2"
        #expect(model.status == .blocked(ChoiceProblem.passwordMismatch.description))
        model.confirmation = "hunter2"
        #expect(model.status == .ready)
        #expect(model.canCreate)
    }

    /// UTM missing comes before everything: the window opens, but nothing can be created.
    @Test func noUTMBlocksBeforeTheISO() {
        let model = readyModel(facts(utmInstalled: false, utmVersion: nil))
        #expect(model.status == .blocked(CreateCopy.eUTMMissing))
    }

    @Test func theNameErrorComesBeforeTheUserName() {
        let model = readyModel(facts(user: ""))
        model.vmName = "bad/name"
        #expect(model.status == .blocked(ChoiceProblem.nameChars.description))
        model.vmName = "Bench"
        #expect(model.status == .blocked(ChoiceProblem.userEmpty.description))
    }

    /// The clash the window finds when UTM is already running reads the same as the job's.
    @Test func aClashShowsUnderTheName() {
        let model = readyModel(facts(existing: ["Bench"]))
        model.vmName = "bench"
        #expect(model.vmNameError == ChoiceProblem.nameTaken("Bench").description)
        #expect(model.status == .blocked(ChoiceProblem.nameTaken("Bench").description))
    }

    @Test func theComputerNameComesAfterThePassword() {
        let model = readyModel()
        model.computerName = "-bad-"
        model.password = ""
        model.confirmation = ""
        #expect(model.status == .blocked(CreateCopy.fNeedPassword(user: "alex")))
        model.password = "hunter2"
        model.confirmation = "hunter2"
        #expect(model.status == .blocked(ChoiceProblem.computerHyphen.description))
    }

    @Test func tooLittleFreeSpaceBlocksLast() {
        let model = readyModel(facts(freeGB: 12))
        #expect(model.status == .blocked(CreateCopy.eSpace(freeGB: 12, volume: "Macintosh HD")))
    }

    /// Steppers keep these in range; the editable number beside them doesn't have to.
    @Test func aTypedNumberOutOfRangeStillBlocks() {
        let model = readyModel()
        model.memoryGB = 200
        #expect(model.status == .blocked(ChoiceProblem.memoryRange(max: 60).description))
        model.memoryGB = 16
        model.diskGB = 10
        #expect(model.status == .blocked(ChoiceProblem.diskRange.description))
    }

    /// The key is optional, so an empty field never blocks; a wrong one does, before the computer name,
    /// which is where the field sits on screen.
    @Test func aProductKeyThatIsntOneBlocksCreate() {
        let model = readyModel()
        #expect(model.productKey.isEmpty)
        #expect(model.status == .ready)
        #expect(model.productKeyError == nil)

        model.productKey = "  "
        #expect(model.status == .ready)

        model.productKey = "not a key"
        #expect(model.productKeyError == ChoiceProblem.productKeyShape.description)
        #expect(model.status == .blocked(ChoiceProblem.productKeyShape.description))

        model.productKey = "VK7JG-NPHTM-C97JM-9MPGT-3V66T"
        #expect(model.productKeyError == nil)
        #expect(model.status == .ready)
    }

    @Test func mismatchOnlyGetsACaptionOnceConfirmHasLostFocus() {
        let model = readyModel()
        model.confirmation = "hunter"
        #expect(model.confirmationError == nil)      // still typing
        #expect(model.status == .blocked(ChoiceProblem.passwordMismatch.description))
        model.confirmationBlurred = true
        #expect(model.confirmationError == ChoiceProblem.passwordMismatch.description)
    }
}

@Suite struct CreateFormWarnings {
    @Test func sizingWarningsAppearAboveTheSuggestions() {
        let model = readyModel(facts(cores: 8, totalCores: 12, memoryGB: 16))
        #expect(model.coresWarning == nil)
        model.cores = 12
        // In processor cores, the window's word for them; Terminal's warning says vCPUs.
        #expect(model.coresWarning == CreateCopy.windowCoresHigh(topTier: 8))
        #expect(model.coresWarning?.contains("vCPU") == false && ChoiceWarning.coresHigh(topTier: 8).description.contains("vCPUs"))
        model.memoryGB = 12
        #expect(model.memoryWarnings == [ChoiceWarning.memoryHigh(totalGB: 16).description])
        model.memoryGB = 4
        #expect(model.memoryWarnings == [ChoiceWarning.memoryLow.description])
    }

    /// The number beside the stepper can be typed past it, and the status line then says so in the
    /// window's word for them: Terminal's "vCPUs: 2 to 12." was the one place the form still said vCPUs.
    @Test func tooManyCoresBlockInProcessorCores() {
        let model = readyModel(facts(cores: 8, totalCores: 12))
        model.cores = 99
        #expect(model.status == .blocked(CreateCopy.windowCoresRange(max: 12)))
        #expect(model.status != .blocked(ChoiceProblem.coresRange(max: 12).description))
    }

    @Test func fileVaultOffIsSaidUnderBitLockerAndUnderThePassword() {
        let on = readyModel(facts(fileVaultOn: true))
        #expect(on.bitLockerNote == nil)
        #expect(on.passwordFileVaultNote == nil)
        let off = readyModel(facts(fileVaultOn: false))
        #expect(off.bitLockerNote == CreateCopy.nBitLockerFileVaultOff)
        #expect(off.passwordFileVaultNote == CreateCopy.nPWFileVaultOff)
    }

    /// The rule is WindowsISO's, which the job uses too: the answer file is verified for 24H2 and
    /// 25H2, so only a newer build is untested.
    @Test func anUntestedBuildAndAnUntestedUTMAreSaidOnce() {
        let model = readyModel(facts(utmVersion: "4.8.0"), build: 27000)
        #expect(model.isoWarnings.contains { $0.hasPrefix("This is Windows 11 build 27000") })
        #expect(model.generalWarnings
                == [CreateCopy.wUTMUntested(version: "4.8.0", tested: CreatePreflight.testedList())])
        let verified = readyModel(facts(), build: 26100)
        #expect(!verified.isoWarnings.contains { $0.hasPrefix("This is Windows 11 build") })
        let tested = readyModel()
        #expect(!tested.isoWarnings.contains { $0.hasPrefix("This is Windows 11 build") })
        #expect(tested.generalWarnings.isEmpty)
    }

    /// A UTM 5 pre-release is a different sentence from a 4.x nobody has run, and the form shows
    /// whichever one the preflight rule picked — the job's message and the form's caption are one
    /// text, so this is the only place the form has to be right about it.
    @Test func aPreReleaseUTMGetsTheLongerSentence() {
        let model = readyModel(facts(utmVersion: "5.0.5"))
        #expect(model.generalWarnings
                == [CreateCopy.wUTMPrerelease(version: "5.0.5", tested: CreatePreflight.testedList())])
        #expect(model.generalWarnings.first?.contains("pre-release") == true)
        // It is a warning, never a block: create still goes ahead on an untested UTM.
        #expect(model.canCreate)
    }

    /// Enough to install, not enough to fill the disk: a warning, not a block.
    @Test func aDiskBiggerThanTheFreeSpaceOnlyWarns() {
        let model = readyModel(facts(freeGB: 90))
        #expect(model.canCreate)
        #expect(model.generalWarnings == [CreateCopy.wSpace(diskGB: 128, freeGB: 90)])
    }

    @Test func theRegionalRowShowsTheMacsValuesOrWindowsDefaults() {
        let model = readyModel()
        #expect(model.regionalDetail == regional.values.summary)
        model.options.remove(.regionalFromMac)
        #expect(model.regionalDetail == CreateCopy.nRegionalOff(isoLanguage: "en-US"))
        #expect(model.regionalNotes.isEmpty)
    }
}

@Suite struct CreateFormPlan {
    @Test func thePlanCarriesTheChoicesAndNeverThePassword() throws {
        let model = readyModel(facts(menuVM: "Old VM"))
        model.vmName = "  Bench  "
        model.options.remove(.qol)
        let plan = try #require(model.plan)
        #expect(plan.vmName == "Bench")
        #expect(plan.edition == pro)
        #expect(plan.memoryMiB == 16 * 1024)
        #expect(!plan.has(.qol))
        #expect(plan.regional == regional.values)
        #expect(plan.select)
        // CreatePlan has no password field at all; this is the belt-and-braces check.
        let json = try String(data: JSONEncoder().encode(plan), encoding: .utf8) ?? ""
        #expect(!json.contains("hunter2"))
    }

    @Test func regionalOffLeavesNoMacValuesInThePlan() throws {
        let model = readyModel()
        model.options.remove(.regionalFromMac)
        #expect(try #require(model.plan).regional == nil)
    }

    @Test func forgettingThePasswordEmptiesBothFieldsAndTheKey() {
        let model = readyModel()
        model.confirmationBlurred = true
        model.productKey = "VK7JG-NPHTM-C97JM-9MPGT-3V66T"
        model.forgetPassword()
        #expect(model.password.isEmpty)
        #expect(model.confirmation.isEmpty)
        #expect(!model.confirmationBlurred)
        #expect(model.productKey.isEmpty)
        #expect(model.plan == nil)
    }

    /// The key never rides along in the plan, for the same reason the password doesn't: the plan is
    /// written to state.json and quoted in the log. `create()` reads `normalizedProductKey` instead.
    @Test func thePlanNeverCarriesTheProductKey() throws {
        let model = readyModel()
        model.productKey = " vk7jg-nphtm c97jm 9mpgt 3v66t "
        #expect(model.normalizedProductKey == "VK7JG-NPHTM-C97JM-9MPGT-3V66T")
        let plan = try #require(model.plan)
        let json = try String(data: JSONEncoder().encode(plan), encoding: .utf8) ?? ""
        #expect(!json.uppercased().contains("VK7JG"))
        #expect(!json.lowercased().contains("productkey"))

        model.productKey = ""
        #expect(model.normalizedProductKey == nil)
        model.productKey = "   "
        #expect(model.normalizedProductKey == nil)
    }

    /// The row only exists when Winbar already looks after another VM; without one, create always
    /// selects the new VM.
    @Test func selectIsAlwaysTrueWithoutAnotherVM() throws {
        let model = readyModel()
        model.select = false
        #expect(try #require(model.plan).select)
    }
}

// MARK: - The progress view

private func state(stage: CreateStage, outcome: CreateJobState.Outcome? = nil, detail: String? = nil,
                   started: Date, updated: Date, shown: [String] = [], stalled: StallState? = nil,
                   messages: [CreateMessage] = [], failure: CreateFailure? = nil, vmID: String? = "1",
                   mediaDir: String? = "/tmp/job.noindex", select: Bool = true,
                   stageStarted: Date? = nil) -> CreateJobState {
    let plan = CreatePlan(vmName: "Windows 11", isoPath: image().path, edition: pro, cores: 8, memoryMiB: 16384,
                          diskGiB: 128, options: CreateOption.defaults, noVisualTweaks: false, userName: "alex",
                          computerName: "Windows-11", regional: nil, select: select, keepConsole: false)
    return CreateJobState(id: "job", plan: plan, vmID: vmID, stage: stage, detail: detail, startedAt: started,
                          updatedAt: updated, finishedAt: outcome == nil ? nil : updated, outcome: outcome,
                          restarts: 0, bytesWritten: nil, shown: shown, stalled: stalled, messages: messages,
                          failure: failure, mediaDir: mediaDir, logPath: "/tmp/winbar.log", watched: true,
                          stageStartedAt: stageStarted)
}

private func message(_ code: String, _ text: String, at: Date = Date()) -> CreateMessage {
    CreateMessage(code: code, text: text, at: at)
}

@Suite struct CreateProgressWording {
    /// Both endings read the same flag, so neither tells someone who has just used a licence that
    /// Windows isn't activated. The flag is a note the job raised, not the key.
    @Test func theActivationLineFollowsWhetherThereWasAKey() {
        let now = Date()
        let plain = state(stage: .finish, outcome: .done, started: now, updated: now)
        #expect(!plain.usedProductKey)
        #expect(CreateCopy.nNotActivated.contains("isn't activated"))

        let keyed = state(stage: .finish, outcome: .done, started: now, updated: now,
                          messages: [message("N_PRODUCT_KEY", CreateCopy.nProductKey, at: now)])
        #expect(keyed.usedProductKey)
        #expect(CreateCopy.nActivating.contains("installed with your product key"))
        #expect(CreateCopy.nActivating.contains("Settings > System > Activation"))
        #expect(!CreateCopy.nActivating.contains("isn't activated"))
    }

    @Test func elapsedReadsAsAClockOrAsMinutes() {
        #expect(CreateElapsed.clock(0) == "0:00")
        #expect(CreateElapsed.clock(9 * 60 + 48) == "9:48")
        #expect(CreateElapsed.clock(14 * 60 + 32) == "14:32")
        #expect(CreateElapsed.clock(3600 + 4 * 60 + 9) == "1:04:09")

        #expect(CreateElapsed.minutes(30) == "less than a minute")
        #expect(CreateElapsed.minutes(60) == "1 min")
        #expect(CreateElapsed.minutes(31 * 60 + 40) == "31 min")
        #expect(CreateElapsed.minutes(3600) == "1 h")
        #expect(CreateElapsed.minutes(75 * 60) == "1 h 15 min")
    }

    @Test func eachStageHasARunningTitleADoneTitleAndAShortOne() {
        for stage in CreateStage.allCases {
            #expect(!stage.runningTitle.isEmpty)
            #expect(!stage.doneTitle.isEmpty)
            #expect(!stage.shortTitle.isEmpty)
        }
        #expect(CreateStage.copy.runningTitle == "Windows Setup: copying files")
        #expect(CreateStage.copy.doneTitle == "Windows Setup copied its files")
        // The stage shorts, which the menu bar and the CLI's heartbeat share.
        #expect(CreateStage.copy.shortTitle == "copying files")
        #expect(CreateStage.check.shortTitle == "checking the ISO and UTM")
        #expect(CreateStage.guestTools.shortTitle == "getting Guest Tools")
        #expect(CreateStage.guestTools.runningTitle == "Getting UTM Guest Tools \(GuestTools.version)")
    }

    @Test func theListMarksEarlierStagesDoneAndLaterOnesPending() {
        let started = Date(timeIntervalSince1970: 1_000_000)
        let progress = CreateProgress(state: state(stage: .copy, detail: "7.9 GB written to the VM's disk",
                                                  started: started, updated: started.addingTimeInterval(284)),
                                      now: started.addingTimeInterval(872))
        #expect(progress.header == "Installing Windows 11 Pro in “Windows 11”")
        #expect(progress.elapsed == "14:32")
        #expect(progress.step == "Stage 6 of 10 · Copying files")
        #expect(progress.soFar == "14 min so far · usually 10–15 min")
        #expect(progress.fraction == 0.5)
        #expect(progress.rows.count == 10)
        #expect(progress.rows[0] == CreateProgress.Row(stage: .check, mark: .done,
                                                       title: "Checked the ISO and UTM"))
        let running = progress.rows[5]
        #expect(running.mark == .running)
        #expect(running.title == "Windows Setup: copying files")
        #expect(running.detail == "7.9 GB written to the VM's disk")
        #expect(running.elapsed == "9 min")
        #expect(progress.rows[6].mark == .pending)
        #expect(progress.rows[6].title == "Windows Setup: setting up devices")
        #expect(progress.stall == nil)
    }

    @Test func aFinishedJobMarksEveryStageDone() {
        let started = Date(timeIntervalSince1970: 1_000_000)
        let progress = CreateProgress(state: state(stage: .finish, outcome: .done, started: started,
                                                   updated: started.addingTimeInterval(1860)),
                                      now: started.addingTimeInterval(3000))
        #expect(progress.rows.allSatisfy { $0.mark == .done })
        #expect(progress.fraction == 1)
        // The clock stops when the job does, not when the window is looked at.
        #expect(progress.elapsed == "31:00")
    }

    @Test func aFailedStageIsMarkedWithACross() {
        let started = Date(timeIntervalSince1970: 1_000_000)
        let failure = CreateFailure(code: "E_TIMEOUT", title: "Windows still hadn't finished installing",
                                    detail: "…after 2 hours, so Winbar stopped waiting.", nextStep: nil)
        let job = state(stage: .oobe, outcome: .failed, started: started, updated: started.addingTimeInterval(7200),
                        failure: failure)
        let progress = CreateProgress(state: job, now: started.addingTimeInterval(7300))
        #expect(progress.rows[7].mark == .failed)
        #expect(progress.rows[7].title == "Windows Setup: getting ready")
        // The words, and the one red cross beside them, not a ✗ in the text VoiceOver reads out.
        #expect(CreateJobView.failureHeader(job) == "Windows still hadn't finished installing")
        #expect(CreateJobView.failureMark(job) == .failed)
        // Try Again asks the job, not a list of codes the two could drift apart on: the VM and its
        // setup disk are still there, so this one can be carried on with.
        #expect(job.isResumable)
    }

    /// result=failed means Windows is installed; the header says so rather than shouting.
    @Test func partlyFailedFirstLogonStepsGetTheMilderHeader() {
        let started = Date(timeIntervalSince1970: 1_000_000)
        let failure = CreateFailure(code: "E_RESULT_FAILED", title: "Some of Winbar's first sign-in steps failed",
                                    detail: "Remote Desktop", nextStep: nil)
        // Windows is installed, so the setup disk has already gone: there is nothing to resume, and
        // no Try Again button.
        let job = state(stage: .firstLogon, outcome: .failed, started: started, updated: started, failure: failure,
                        mediaDir: nil)
        #expect(CreateJobView.failureHeader(job) == "Windows 11 Pro is installed in “Windows 11”, with problems")
        #expect(CreateJobView.failureMark(job) == .attention)
        #expect(!job.isResumable)
    }

    /// The job writes one detail line for both front-ends; in the window the app macOS is asking
    /// about is always Winbar, so it says so.
    @Test func theAutomationPromptGetsTheWindowsOwnWording() {
        let started = Date(timeIntervalSince1970: 1_000_000)
        let asking = state(stage: .vm, detail: "Waiting for you to allow Winbar to control UTM…",
                           started: started, updated: started)
        #expect(CreateProgress(state: asking, now: started).rows[3].detail == CreateCopy.pAutomation)
        let ordinary = state(stage: .copy, detail: "3.4 GB written to the VM's disk", started: started,
                             updated: started)
        #expect(CreateProgress(state: ordinary, now: started).rows[5].detail == "3.4 GB written to the VM's disk")
    }

    /// The note follows the job's own stall state, so it goes as soon as the VM writes again — not
    /// when the stage changes, and not when a job from an older Winbar says nothing.
    @Test func theStallNoteShowsOnlyWhileTheJobSaysTheVMIsQuiet() {
        let started = Date(timeIntervalSince1970: 1_000_000)
        let stalled = state(stage: .devices, started: started, updated: started, shown: ["W_STALL"], stalled: .quiet)
        #expect(CreateProgress(state: stalled, now: started).stall
            == CreateCopy.forWindow(CreateCopy.wStall(vmName: "Windows 11"), vmName: "Windows 11"))
        let writingAgain = state(stage: .devices, started: started, updated: started, shown: ["W_STALL"],
                                 stalled: .writing)
        #expect(CreateProgress(state: writingAgain, now: started).stall == nil)
        let unsaid = state(stage: .devices, started: started, updated: started, shown: ["W_STALL"])
        #expect(CreateProgress(state: unsaid, now: started).stall == nil)
        let done = state(stage: .finish, outcome: .done, started: started, updated: started, shown: ["W_STALL"],
                         stalled: .quiet)
        #expect(CreateProgress(state: done, now: started).stall == nil)
    }

    /// The kind of stall reaches both front-ends: the box says which wedge it is, and so does the
    /// one clause the CLI's spinner line has room for. A busy VM writing nothing must not be
    /// described as an idle one.
    @Test func bothFrontEndsSayWhichStallItIs() {
        let started = Date(timeIntervalSince1970: 1_000_000)
        let busy = state(stage: .copy, started: started, updated: started, shown: ["W_STALL_BUSY"], stalled: .busy)
        let box = try! #require(CreateProgress(state: busy, now: started).stall)
        #expect(box.hasPrefix("Windows hasn't written anything to the VM's disk for 12 minutes, though the VM is busy"))
        // The window's box names its own button for the recovery; the job's sentence, which the
        // terminal prints, keeps the command.
        #expect(box.contains(CreateCopy.wStallRecoveryWindow) && !box.contains("--resume"))
        #expect(CreateCopy.wStallBusy(vmName: "Windows 11", restarted: false).contains("winbar create --resume “Windows 11”"))
        let quiet = state(stage: .copy, started: started, updated: started, shown: ["W_STALL"], stalled: .quiet)
        #expect(try! #require(CreateProgress(state: quiet, now: started).stall).contains("almost no CPU"))

        let line = CreateProgressPrinter.line(busy, spinner: "⠋", elapsed: 90, width: 120)
        #expect(line.contains("nothing written for 12 minutes, though the VM is busy"))
        #expect(CreateProgressPrinter.line(quiet, spinner: "⠋", elapsed: 90, width: 120)
            .contains("the VM has been idle for 10 minutes"))
        #expect(!CreateProgressPrinter.line(state(stage: .copy, started: started, updated: started, stalled: .writing),
                                            spinner: "⠋", elapsed: 90, width: 120).contains("minutes,"))
    }

    /// The box is the stall's one place in the window: without this the same paragraph appeared
    /// twice, once boxed and once in the list of everything the job has said.
    @Test func theStallIsBoxedOrListed_neverBoth() {
        let started = Date(timeIntervalSince1970: 1_000_000)
        let said = [message("W_STALL_BUSY", CreateCopy.wStallBusy(vmName: "Windows 11", restarted: false))]
        let stalled = state(stage: .copy, started: started, updated: started, shown: ["W_STALL_BUSY"],
                            stalled: .busy, messages: said)
        // While it is true, the box carries the job's own words and the list leaves it out.
        #expect(CreateProgress(state: stalled, now: started).stall == CreateCopy.forWindow(said[0].text, vmName: "Windows 11"))
        #expect(CreateProgress(state: stalled, now: started).notes.isEmpty)
        // Once the VM writes again the box goes, and the warning stays in the record.
        var writing = stalled
        writing.stalled = .writing
        #expect(CreateProgress(state: writing, now: started).stall == nil)
        #expect(CreateProgress(state: writing, now: started).notes.map(\.code) == ["W_STALL_BUSY"])
    }

    /// The stage's clock counts from when the stage began, not from the job's last save: during the
    /// copy stage the job saves every time the "{n} GB written" line changes, about every 30 s.
    @Test func theRunningStagesClockCountsFromWhenTheStageBegan() {
        let started = Date(timeIntervalSince1970: 1_000_000)
        let copying = state(stage: .copy, detail: "7.9 GB written to the VM's disk", started: started,
                            updated: started.addingTimeInterval(860), stageStarted: started.addingTimeInterval(284))
        #expect(CreateProgress(state: copying, now: started.addingTimeInterval(872)).rows[5].elapsed == "9 min")
        // A state file from a Winbar that didn't record the stage's start still reads something.
        let older = state(stage: .copy, started: started, updated: started.addingTimeInterval(284))
        #expect(CreateProgress(state: older, now: started.addingTimeInterval(872)).rows[5].elapsed == "9 min")
    }

    /// Every note and warning the job raised reaches the window, in order. Four of them say that
    /// something the password copy promised didn't happen (D4), so they get a box of their own.
    @Test func theJobsNotesAndWarningsReachTheWindow() {
        let started = Date(timeIntervalSince1970: 1_000_000)
        let raised = [message("N_RESUMED", "Picked up the install of “Windows 11” where it left off."),
                      message("W_AUTOLOGON_PLAINTEXT", CreateCopy.autologonPlaintext),
                      message("W_UTM_RESTART_OWED", "Windows is installed and the VM's display is off.")]
        let notes = CreateProgress(state: state(stage: .finish, started: started, updated: started, messages: raised),
                                   now: started).notes
        #expect(notes.map(\.code) == ["N_RESUMED", "W_AUTOLOGON_PLAINTEXT", "W_UTM_RESTART_OWED"])
        #expect(notes.map(\.text) == raised.map(\.text))
        #expect(notes.map(\.boxed) == [false, true, false])
        #expect(CreateProgress(state: state(stage: .copy, started: started, updated: started), now: started)
            .notes.isEmpty)
        // The ones D4's copy depends on: each says a promise the person already read is now false.
        #expect(CreateProgress.boxedCodes == ["W_TIMEMACHINE", "W_MEDIA_LEFT", "W_PANTHER", "W_AUTOLOGON_PLAINTEXT"])
    }
}

/// What the window does with an install that ends, cancels or refuses to start. The rules are pure
/// functions on the job's state, so they can be held against it without a window or UTM.
@Suite struct CreateWindowRules {
    private let started = Date(timeIntervalSince1970: 1_000_000)

    /// A failure two hours into an install is not "couldn't start installing Windows": the VM exists,
    /// so the window keeps it and shows the failure view.
    @Test func aFailureOnceTheVMExistsShowsTheFailureView() {
        let failure = CreateFailure(code: "E_TIMEOUT", title: "Windows still hadn't finished installing",
                                    detail: "", nextStep: nil)
        let running = state(stage: .oobe, started: started, updated: started)
        #expect(CreateWindowController.ending(for: CreateJobError(failure: failure, exit: 1), job: running,
                                              vmName: "Windows 11") == .failureView)
        let failed = state(stage: .oobe, outcome: .failed, started: started, updated: started, failure: failure)
        #expect(CreateWindowController.ending(for: CreateJobError(failure: failure, exit: 1), job: failed,
                                              vmName: "Windows 11") == .failureView)
        // E_RESULT_UNKNOWN ends the same way: Windows is installed, and the window has to say so
        // rather than throw the job away.
        let unknown = CreateJobError.install("E_RESULT_UNKNOWN", "Windows is installed, but Winbar couldn't read "
                                             + "the result of its first sign-in steps.")
        #expect(CreateWindowController.ending(for: unknown, job: state(stage: .finish, started: started,
                                                                      updated: started),
                                              vmName: "Windows 11") == .failureView)
        // …but only for this run's own job: the window may be showing the install the CLI got in
        // first with, and E_BUSY must not paint that one as failed.
        #expect(CreateWindowController.ending(for: CreateJobError.busy("Bench"), job: running, vmName: "Bench")
                == .alert)
    }

    /// Before the VM exists there is nothing to show but the reason, so the form comes back.
    @Test func aRefusalBeforeTheVMExistsIsAnAlert() {
        let starting = state(stage: .check, started: started, updated: started, vmID: nil, mediaDir: nil)
        #expect(CreateWindowController.ending(for: CreateJobError.busy("Windows 11"), job: starting,
                                              vmName: "Windows 11") == .alert)
        #expect(CreateWindowController.ending(for: CreateJobError.unavailable("E_UTM_MISSING",
                                                                             CreateCopy.eUTMMissingTitle),
                                              job: nil, vmName: "Windows 11") == .alert)
        #expect(CreateWindowController.ending(for: ChoiceProblem.nameTaken("Windows 11"), job: starting,
                                              vmName: "Windows 11") == .nameTaken("Windows 11"))
    }

    /// N_CANCELLED is the person's own Cancel Install…, not a failure: the job has already saved
    /// itself `.cancelled`, and that ending is what stays on screen.
    @Test func aCancelIsNotAFailure() {
        let running = state(stage: .copy, started: started, updated: started)
        let cancelled = CreateJob.cancelled("Windows 11", deletedVM: true)
        #expect(cancelled.failure.code == CreateWindowController.cancelledCode)
        #expect(cancelled.exitCode == 130)
        #expect(CreateWindowController.ending(for: cancelled, job: running, vmName: "Windows 11") == .cancelled)
    }

    /// The ending says what the cancel actually did.
    @Test func theCancelledViewSaysWhatWasDone() {
        let deleted = CreateCancelResult(state: state(stage: .copy, outcome: .cancelled, started: started,
                                                      updated: started),
                                         stopped: true, deletedVM: true, deletedSetupDisk: true)
        #expect(CreateWindowController.cancelNote(deleted, name: "Windows 11")
                == "Cancelled installing Windows. “Windows 11” and its setup disk are deleted.")
        let gone = CreateCancelResult(state: deleted.state, vmGone: true, deletedSetupDisk: true)
        #expect(CreateWindowController.cancelNote(gone, name: "Windows 11") == CreateCopy.nCancelVMGone(name: "Windows 11"))
        #expect(CreateWindowController.cancelNote(gone, name: "Windows 11").contains("no longer in UTM"))
    }

    /// An alert quotes the failure the job raised, and what to do about it.
    @Test func anAlertQuotesTheFailureAndItsNextStep() {
        let busy = CreateJobError.busy("Windows 11")
        let body = CreateWindowController.alertBody(busy)
        #expect(body.hasPrefix(busy.failure.title))
        #expect(body.contains("stop watching it with Ctrl-C first"))
        #expect(!body.contains("\n\n\n"))
        #expect(CreateWindowController.unknownFailure(CreateJobError.busy("x")).title == CreateCopy.eStopped)
    }

    /// Closing the window is Hide while the install runs, and Done once it has ended: the next
    /// New Windows VM… opens a form, not the last install's ending screen.
    @Test func closingKeepsARunningJobAndLetsAFinishedOneGo() {
        #expect(CreateWindowController.keepsJob(onClose: state(stage: .copy, started: started, updated: started)))
        for outcome in [CreateJobState.Outcome.done, .failed, .cancelled] {
            #expect(!CreateWindowController.keepsJob(onClose: state(stage: .finish, outcome: outcome,
                                                                    started: started, updated: started)))
        }
        #expect(!CreateWindowController.keepsJob(onClose: nil))
    }

    /// The window comes back when the job it was showing ends — not when the CLI's does, which would
    /// take the keystrokes meant for Terminal's last question.
    @Test func onlyAJobThisWindowIsDrivingBringsItBack() {
        let running = state(stage: .copy, started: started, updated: started)
        #expect(CreateWindowController.reopensWhenJobEnds(running, ownsJob: true, windowExists: true))
        #expect(!CreateWindowController.reopensWhenJobEnds(running, ownsJob: false, windowExists: true))
        #expect(!CreateWindowController.reopensWhenJobEnds(running, ownsJob: true, windowExists: false))
        let over = state(stage: .finish, outcome: .done, started: started, updated: started)
        #expect(!CreateWindowController.reopensWhenJobEnds(over, ownsJob: true, windowExists: true))
    }

    /// The Done screen's command, and the Copy button's, are one string worked out from the plan.
    @Test func theDoneScreenNamesTheVMWhenTheMenuStillLooksAfterAnother() {
        let selected = state(stage: .finish, outcome: .done, started: started, updated: started)
        #expect(CreateCopy.setupCommand(plan: selected.plan) == "winbar setup")
        let kept = state(stage: .finish, outcome: .done, started: started, updated: started, select: false)
        #expect(CreateCopy.setupCommand(plan: kept.plan) == "winbar setup --vm \"Windows 11\"")
    }

    /// New Windows VM… is in every menu, so its window's hand-offs are read by people who may never
    /// have opened Terminal. While the menu offers Set Up Winbar… they name it first, and keep the
    /// Terminal route; the control is the switch turned off, which gives the Terminal-only sentences.
    @Test func theHandOffsNameSetUpWinbarFirstWhileTheMenuOffersIt() {
        #expect(SetupWindow.availableToEveryone)
        var selected = state(stage: .finish, outcome: .done, started: started, updated: started).plan
        selected.vmName = "winlab04"
        var kept = selected
        kept.select = false
        #expect(CreateCopy.nNextCommand(plan: selected)
                == "One more step, about 5 minutes: choose Set Up Winbar… in Winbar's menu, or run this in Terminal:")
        // Left unselected, the menu still looks after the old VM, so the window has to be told which.
        #expect(CreateCopy.nNextCommand(plan: kept) == "One more step, about 5 minutes: choose Set Up Winbar… in "
                + "Winbar's menu and pick “winlab04” as its VM, or run this in Terminal:")
        #expect(CreateCopy.nNextCommand(plan: kept, setUpInMenu: false) == "One more step, about 5 minutes, in Terminal:")

        let utm = "UTM isn't installed. Set Up Winbar… in Winbar's menu offers to install UTM for you, and so does "
            + "winbar create in Terminal. Or install it yourself (brew install --cask utm, or getutm.app), then run this again."
        #expect(readyModel(facts(utmInstalled: false, utmVersion: nil)).status == .blocked(utm))
        #expect(CreateCopy.eUTMMissingTitle + " " + CreateCopy.eUTMMissingNext(setUpInMenu: false)
                == "UTM isn't installed. winbar create in Terminal offers to install UTM for you. Or install it "
                    + "yourself (brew install --cask utm, or getutm.app), then run this again.")
    }
}

@Suite struct CreateFailureCopy {
    /// The window shows the failure's own sentence once: as the heading, not again under it.
    @Test func theHeadingIsNotRepeatedInTheBody() {
        let repeated = CreateFailure(code: "E_TIMEOUT",
                                     title: "Windows still hadn't finished installing after 2 hours",
                                     detail: "Windows still hadn't finished installing after 2 hours, so Winbar "
                                           + "stopped waiting. The VM is still running.",
                                     nextStep: nil)
        #expect(CreateJobView.failureDetail(repeated)
                == "So Winbar stopped waiting. The VM is still running.")

        let separate = CreateFailure(code: "E_DETACH", title: "Winbar didn't detach the install disks from UTM",
                                     detail: "UTM refused the change.", nextStep: nil)
        #expect(CreateJobView.failureDetail(separate) == "UTM refused the change.")

        let onlyTheTitle = CreateFailure(code: "E_X", title: "It stopped", detail: "It stopped.", nextStep: nil)
        #expect(CreateJobView.failureDetail(onlyTheTitle) == "It stopped.")
    }
}

/// A form that has just opened is missing its ISO and its password: said in the muted colour, since
/// nothing is wrong yet. A real problem is still red.
@Suite("The form's status is red only for a problem")
struct CreateFormStatusColourTests {
    @Test func hintsAreNotProblems() {
        let model = CreateFormModel(facts: facts())
        #expect(model.status == .blocked(CreateCopy.fNeedISO))
        #expect(!model.statusIsProblem)
        model.iso = .failed(file: "not-windows.iso", message: "That isn't a Windows ISO.")
        #expect(model.statusIsProblem)
    }
}

/// "128 GB disk" read as 128 GB taken from the Mac. The disk grows as Windows fills it, so the summary and
/// the field say so, where people read them (not only in a tooltip).
@Suite("The disk size is presented as a ceiling, not a cost")
struct DiskSizeWordingTests {
    @Test func summaryAndCaption() {
        let model = CreateFormModel(facts: facts())
        let vm = model.summary.first { $0.label == CreateCopy.sVM }?.value ?? ""
        #expect(vm.contains("a disk that grows as needed, up to \(model.diskGB) GB"))
        #expect(!vm.hasSuffix("GB disk"))
        #expect(CreateCopy.diskCaption.contains("only as Windows fills it"))
    }
}

/// Live, the last stage showed its long wait only as a grey detail under "Detaching the install disks
/// from UTM and restarting Windows", three minutes after the disks were off; the person reported the
/// wizard as stuck on detaching. The running step's detail is drawn like its title.
@MainActor @Suite("The running step's detail says what's happening now, at full strength")
struct RunningDetailTests {
    @Test func runningDetailIsNotQuiet() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/Winbar/StepList.swift"), encoding: .utf8)
        #expect(source.contains("foregroundStyle(mark == .running ? Color.primary : quiet)"))
        let job = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/Winbar/CreateJobRun.swift"), encoding: .utf8)
        #expect(job.contains("Windows is starting. Winbar waits for it to answer, up to three minutes…"))
    }
}
