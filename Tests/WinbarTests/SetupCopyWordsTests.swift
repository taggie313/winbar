import Foundation
import Testing
@testable import Winbar

// The copy pass for 0.2.1 (design review, "Copy: words Ben doesn't have"): one name for each thing,
// the step bar's; no word for Winbar's machinery in the window, its form or its menu; "choose" as the
// one instruction verb, with the button's name in bold; and Armie saying one dry thing that the page
// beside him doesn't already say. `winbar setup` and `winbar create` keep their words, and the tests
// that say so are here too, so a fix in the window can't quietly reword Terminal.

/// A deck string as a person reads it: Markdown's markers gone.
private func read(_ markdown: String) -> String { String(SetupCopy.markdown(markdown).characters) }
private func read(_ text: AttributedString) -> String { String(text.characters) }

/// The runs of `text` that are bold, as their words.
func boldRuns(_ text: AttributedString) -> [String] {
    text.runs.compactMap { run in
        run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true ? String(text[run.range].characters) : nil
    }
}

private func flight(_ work: SetupRunner.Work) -> SetupRunner.InFlight { .init(work: work, started: Date(), vm: "winlab01") }

/// Everything the finished Set Up Winbar window, its New Windows VM form and the menu can show, with
/// invented values where a function needs one. Markdown, as each is written; `read` gives the words.
private let seen: [String] = {
    var all: [String] = []
    all += SetupCopy.Welcome.body(lastBuilt: .finish) + [SetupCopy.Welcome.title, SetupCopy.Welcome.lead]
    all += [SetupCopy.LookAround.askBody, SetupCopy.LookAround.askInstruction(), SetupCopy.LookAround.askInstruction(quarantined: true),
            SetupCopy.LookAround.askAside(), SetupCopy.LookAround.askAside(quarantined: true), SetupCopy.LookAround.settleOpen,
            SetupCopy.LookAround.silent(consent: .wouldPrompt, host: "Winbar"), SetupCopy.LookAround.silent(consent: .decided, host: "Winbar"),
            SetupCopy.LookAround.denied(host: "Winbar"), SetupCopy.LookAround.utmFailed, SetupCopy.LookAround.utmFailedHeading,
            SetupCopy.LookAround.windowsAppLater(lastBuilt: .finish), SetupCopy.LookAround.quarantineAside,
            SetupCopy.LookAround.readyTitle(windowsAppReady: true), SetupCopy.LookAround.checkingNote,
            SetupCopy.LookAround.silentHeading, SetupCopy.LookAround.permissionHeading]
    for plan in [InstallPlan.brew(brew: "/opt/homebrew/bin/brew", cask: "utm"),
                 .download(url: "https://example.invalid/UTM.dmg")] {
        all.append(SetupCopy.LookAround.summary(plan, state: .missing))
    }
    all += SetupCopy.VM.noneBody + [SetupCopy.VM.noneHeading, SetupCopy.VM.notKnownWindows, SetupCopy.VM.unlisted,
                                    SetupCopy.VM.installing, SetupCopy.VM.setupDiskLeft, SetupCopy.VM.readyHeading,
                                    SetupCopy.VM.bMakeOne, SetupCopy.VM.bMakeNew, SetupCopy.VM.bChooseAnother,
                                    SetupCopy.VM.bGoBack, SetupCopy.VM.bStartIt, SetupCopy.VM.stoppedHeading,
                                    SetupCopy.VM.afterInstallHeading, SetupCopy.VM.setupDiskNotTrashed("it was locked")]
    all += [read(SetupCopy.VM.oneBody("winlab01", windows: true, use: "winlab01")), read(SetupCopy.VM.oneBody("winlab01", windows: false, use: "winlab01")),
            read(SetupCopy.VM.ready("winlab01")), read(SetupCopy.VM.stopped("winlab01"))]
    // The step bar's hover, and what it says of a step passed over.
    for mark in [StepBar.Mark.done, .current, .pending, .flagged] {
        all += WizardStep.allCases.map { SetupCopy.stepBarHelp($0, mark) }
    }
    var passed = JourneyFixtures.facts
    passed.rows["H7"] = JourneyFixtures.row("H7", .fixable("Not trusted"))
    passed.rows["C2"] = JourneyFixtures.row("C2", SilentFixtures.status)
    passed.answers.leftAlone = ["H7", "C2"]
    all += [WizardStep.certificate, .savedPC, .connect].compactMap { SetupCopy.passedOver($0, passed) }
    all += [SetupCopy.Finish.passedOverHeading, SetupCopy.goBackTo(.certificate), SetupCopy.goBackTo(.savedPC),
            SetupCopy.Finish.choiceRule, SetupCopy.Finish.inBackground]
    for id in SetupFlow.checks(in: .tune) {
        let recipe = Recipe.check(id)!
        all += [SetupCopy.Tune.title(id, recipe: recipe.title), SetupCopy.Tune.why(id) ?? recipe.why]
    }
    for work in [SetupRunner.Work.survey, .fix(checkID: "G1"), .fixEverything, .recordDone(checkID: "G8"),
                 .guide(checkID: "G5"), .keepBitLocker, .discardChanges(checkID: "H3")] {
        all.append(SetupCopy.Tune.busy(flight(work)))
    }
    for headline in [SetupTuneHeadline.notAsked, .needsYou(count: 2, fixable: 1), .unchecked(count: 1), .tuned(staged: 1)] {
        let words = SetupCopy.Tune.headline(headline)
        all += [words.title] + (words.detail.map { [$0] } ?? [])
    }
    all += [SetupCopy.Certificate.heading, SetupCopy.Certificate.instructions, SetupCopy.Certificate.completion,
            SetupCopy.Certificate.waiting, SetupCopy.Certificate.checking, SetupCopy.Certificate.skippedDetail,
            SetupCopy.Certificate.skippedNext, SetupCopy.Certificate.stopped, SetupCopy.Certificate.notVerified,
            SetupCopy.Certificate.notRunning, SetupCopy.Certificate.goBack, SetupCopy.Certificate.noCertificate,
            SetupCopy.Certificate.approvalWindow, read(SetupCopy.Certificate.body(host: "winlab01.local"))]
    all += [SetupCertificatePage.Phase.needsApproval, .approving, .checking, .verified, .skipped, .attention]
        .map(SetupCopy.Certificate.result)
    all += [SetupCopy.SavedPC.heading, SetupCopy.SavedPC.yourTurn, SetupCopy.SavedPC.saveItYourself,
            SetupCopy.SavedPC.manualTitle, SetupCopy.SavedPC.installWindowsApp, SetupCopy.SavedPC.manual,
            SetupCopy.SavedPC.manualNext, SetupCopy.SavedPC.afterSaving, SetupCopy.SavedPC.saved, SetupCopy.SavedPC.skipped,
            SetupCopy.SavedPC.skippedTitle, SetupCopy.SavedPC.savedAnnouncement, SetupCopy.SavedPC.appOpen,
            SetupCopy.SavedPC.bTrySavingAgain, SetupCopy.SavedPC.windowsAppSkippedTitle, SetupCopy.SavedPC.windowsAppSkipped,
            SetupCopy.Certificate.bCheckAgainInstead, SetupCopy.SavedPC.bOpenWindowsApp, SetupCopy.SavedPC.silentTitle,
            SetupCopy.SavedPC.silent, SetupCopy.SavedPC.silentNext,
            read(SetupCopy.SavedPC.editInstead(host: "winlab01.local", user: "Bruno")),
            SetupCopy.SavedPC.bSavedItMyself, SetupCopy.SavedPC.bContinueToSignIn, SetupCopy.SavedPC.bContinueToSignInInstead,
            read(SetupCopy.SavedPC.lead(user: "Bruno"))]
    for (host, user) in [(nil, nil), ("winlab01.local", nil), ("winlab01.local", "Bruno")] as [(String?, String?)] {
        let words = SetupCopy.SavedPC.notYet(host: host, user: user)
        all += [words.title, words.body]
    }
    all += [SetupCopy.Connecting.accessibility, SetupCopy.Connecting.accessibilityLead, SetupCopy.Connecting.readyLead,
            SetupCopy.Connecting.localNetworkLead, SetupCopy.Connecting.localNetwork, SetupCopy.Connecting.networkRecovery,
            SetupCopy.Connecting.afterRestart, SetupCopy.Connecting.openedConnection, SetupCopy.Connecting.timedOutTitle,
            SetupCopy.Connecting.timedOut, SetupCopy.Connecting.didItAppear(savedPC: true),
            SetupCopy.Connecting.didItAppear(savedPC: false)]
    for readiness in [RDP.Readiness.blocked, .notReady, .ready, nil] as [RDP.Readiness?] {
        for console in [SetupFlow.Console.headless, .onScreen, .unknown] {
            let card = SetupCopy.Connecting.recovery(readiness, savedPC: true, console: console)
            all += [card.heading] + card.steps
        }
    }
    all += [SetupCopy.Finish.choiceHeading, SetupCopy.Finish.backgroundBody, SetupCopy.Finish.keepBody,
            SetupCopy.Finish.choiceRule, SetupCopy.Finish.afterRefusal, SetupCopy.Finish.notOffering,
            SetupCopy.Finish.alreadyInBackground, SetupCopy.Finish.notReady, SetupCopy.Finish.checking,
            SetupCopy.Finish.restartStopped, SetupCopy.Finish.restartLine(vm: "winlab01", ConfigChanges(cpuCores: 6, display: .headless))]
    for outcome in [SetupCopy.Finish.Outcome.connected, .notConnected, .notTried, .windowsAppSkipped] {
        all += SetupCopy.Finish.doneBody(vm: "winlab01", outcome).map(read)
    }
    all += [SetupRunner.Work.checkAgain(.tune), .survey, .fix(checkID: "G1"), .fixEverything, .recordDone(checkID: "G8"),
            .guide(checkID: "G8"), .guide(checkID: "H6"), .guide(checkID: "C2"), .guide(checkID: "C3"),
            .trustCertificate, .savePC, .connect, .applyChanges].map { read(SetupCopy.Quitting.body(doing: SetupCopy.Working.doing(flight($0)))) }
    all += [SetupCopy.Working.startWaiting, SetupCopy.Working.startSlow, SetupCopy.Working.stopStart,
            SetupCopy.Working.stopConnect, SetupCopy.Working.stopRestart,
            SetupCopy.Working.waiting(.certificateApproval, host: "Winbar"), SetupCopy.Working.waiting(.automationPrompt, host: "Winbar"),
            SetupCopy.Working.windowLine(SetupCopy.waitingForWindows), SetupCopy.Working.windowLine(SetupCopy.agentNotYet)]
    all += WizardStep.allCases.map { SetupCopy.journeyNext($0, facts: nil) }
    all += SetupCopy.Armie.Moment.all.map(SetupCopy.Armie.line)
    // The form, in both of its windows.
    all += CreateOption.allCases.map(CreateCopy.windowTooltip) + CreateOption.allCases.map(CreateCopy.windowLabel)
    all += [CreateCopy.windowInstallTooltip, CreateCopy.windowCoresTooltip(topTier: 6),
            CreateCopy.windowComputerTooltip(host: "winlab01.local"), CreateCopy.windowCoresRange(max: 12),
            CreateCopy.windowCoresHigh(topTier: 6), CreateCopy.alwaysDone, CreateCopy.nNextSetup(savedPC: false),
            CreateCopy.lProcessorCores, CreateCopy.bInstall]
    all += ["N_PC_FAILED", "N_KEPT_CONSOLE", "W_RDP_OFF", "W_BITLOCKER_ON"].map { CreateCopy.setupNote(code: $0, text: "") }
    // The menu.
    all += [MenuCopy.runInBackground, MenuCopy.bringBackScreen, MenuCopy.noHostDetail, MenuCopy.startedNotReady,
            MenuCopy.notReady(vm: "winlab01"), MenuCopy.notReadyTitle(vm: "winlab01"), MenuCopy.noHostTitle(vm: "winlab01"),
            MenuCopy.startedNotReadyTitle(vm: "winlab01")]
    for screenOn in [true, false] {
        all += [MenuCopy.confirmTitle(vm: "winlab01", screenOn: screenOn), MenuCopy.confirmBody(vm: "winlab01", screenOn: screenOn),
                MenuCopy.working(screenOn: screenOn), MenuCopy.already(vm: "winlab01", screenOn: screenOn)]
    }
    return all
}()

@Suite("One name for each thing, the step bar's")
struct SetupCopyNamesTests {
    /// The footer named its destination in words of its own: "Continue to Windows App" led to Saved PC,
    /// "Continue to Connection Test" to Connect, and Look around and The VM said only "Continue".
    @Test("Each Continue names the next step as the step bar does")
    func continueNamesTheStep() {
        var connected = JourneyFixtures.facts
        connected.answers.connected = true
        let steps: [(WizardStep, SetupFlow.Facts?, String)] = [
            (.lookAround, nil, "Continue to the VM"), (.vm, nil, "Continue to Tune"),
            (.tune, nil, "Continue to Certificate"), (.certificate, nil, "Continue to Saved PC"),
            (.savedPC, nil, "Continue to Connect"), (.connect, connected, "Continue to Finish"),
        ]
        for (step, facts, title) in steps {
            #expect(SetupCopy.journeyNext(step, facts: facts) == title, "\(step)")
            let next = WizardStep.allCases[WizardStep.allCases.firstIndex(of: step)! + 1]
            #expect(title.lowercased().hasSuffix(SetupCopy.stepBarName(next).lowercased()), "\(step)")
        }
        // Without a saved PC the way on still goes to Connect, where the sign-in happens.
        #expect(SetupCopy.SavedPC.bContinueToSignIn == "Continue to Connect")
        #expect(SetupCopy.SavedPC.bContinueToSignInInstead == "Continue to Connect Instead")
    }

    /// The VM step said **Make One**, the form's last page **Create** and then **Install Windows**.
    @Test("The VM step's way into the form is the form's own last button")
    func installWindows() {
        #expect(SetupCopy.VM.bMakeOne == CreateCopy.bInstall + "…")
        #expect(SetupCopy.VM.bMakeNew.hasPrefix(CreateCopy.bInstall))
        for text in seen.map(read) {
            #expect(!text.contains("Make One") && !text.contains("Make a New One"), "\(text)")
        }
    }

    @Test("The certificate, the saved PC and Connect each have one name")
    func oneName() {
        for text in seen.map(read) {
            for other in ["connection certificate", "RDP certificate", "Remote Desktop certificate", "certificate trust",
                          "save the connection", "Saved the Connection", "Save a connection", "PC saved", "Connection Test",
                          "to Sign-in"] {
                #expect(!text.localizedCaseInsensitiveContains(other), "“\(other)” in: \(text)")
            }
        }
        // The Tune row the certificate step sends Ben back to is called what the step calls it.
        #expect(SetupCopy.Tune.title("G7", recipe: "RDP certificate") == SetupCopy.stepBarName(.certificate))
        #expect(read(SetupCopy.Certificate.goBack).contains("the Certificate row on the Tune step"))
        #expect(SetupCopy.SavedPC.afterSaving.contains(SetupCopy.SavedPC.savedAnnouncement))
    }

    /// The menu's way back has a name of its own because it does something else: the saved PC step's
    /// **Show Windows' Screen** brings UTM forward, and this restarts the VM to give it a screen.
    @Test("The menu's display items are the window's words, and never share a name with a different action")
    func menuMatchesTheWindow() {
        #expect(MenuCopy.runInBackground == SetupCopy.Finish.bBackground + "…")
        #expect(MenuCopy.displayToggle(screenOn: true) == MenuCopy.runInBackground)
        #expect(MenuCopy.displayToggle(screenOn: false) == MenuCopy.bringBackScreen)
        #expect(!MenuCopy.bringBackScreen.hasPrefix(SetupCopy.SavedPC.bShowWindowsScreen))
        // The window's advice names the menu item as the menu shows it.
        #expect(read(SetupCopy.Connecting.recoverConsole).contains(MenuCopy.bringBackScreen))
        #expect(read(SetupCopy.Connecting.recoverEither).contains(MenuCopy.bringBackScreen))
    }
}

@Suite("No word for Winbar's machinery in the window, the form or the menu")
struct SetupCopyJargonTests {
    /// The review's table, and what the window's Tune rows and the form's tooltips said besides.
    static let jargon = ["guest agent", "headless", "vCPU", "Remote Desktop port", "3389", "recipe", "adopt",
                         "command-line tool", "utmctl", "Rufus", "Network Level Authentication", "QEMU", "netplwiz",
                         "console window", "console screen", "listener", "DiagTrack", "SHA-256", "readiness probe",
                         "framebuffer", "run this again", "winbar setup"]

    @Test("None of the review's words is in anything the window, its form or its menu says")
    func noJargon() {
        #expect(seen.count > 250)
        for text in seen.map(read) {
            for word in Self.jargon {
                #expect(!text.localizedCaseInsensitiveContains(word), "“\(word)” in: \(text)")
            }
            #expect(text.range(of: #"\bNLA\b"#, options: .regularExpression) == nil, "\(text)")
            // A check's code is `winbar setup`'s: the quit prompt said "fixing G1 (Power plan)".
            #expect(text.range(of: #"\b[GHC][0-9]{1,2}\b"#, options: .regularExpression) == nil, "\(text)")
        }
    }

    @Test("The quit prompt names a setting as the Tune page does")
    func quitPromptNamesTheRow() {
        #expect(SetupCopy.Working.doing(flight(.fix(checkID: "G1"))) == "fixing Power plan")
        #expect(SetupCopy.Working.doing(flight(.fix(checkID: "H3"))) == "fixing Processor cores")
        #expect(SetupCopy.Working.doing(flight(.guide(checkID: "H6"))) == "opening Time Machine settings")
    }

    /// The Tune page's rows are the recipe's, which `winbar setup` prints: the window has its own titles
    /// and reasons for them, and puts its own words into the status lines built from Windows' answers.
    @Test("Tune rows say what they are and why in the window's words, and the recipe keeps its own")
    func tuneRows() {
        // `seen` holds every Tune row's window title and reason; these are the recipe's, unchanged.
        #expect(Recipe.check("H3")?.title == "vCPUs" && SetupCopy.Tune.title("H3", recipe: "vCPUs") == "Processor cores")
        #expect(Recipe.check("G0")?.why.contains("QEMU guest agent") == true)
        #expect(SetupCopy.Tune.words("the QEMU guest agent isn't answering") == "Windows isn't answering Winbar")
        #expect(SetupCopy.Tune.words("waiting for a password (G5): Bruno has none, and Network Level Authentication would "
                                     + "lock Bruno out of Remote Desktop")
                == "waiting for a password: Bruno has none, and Remote Desktop's password check would lock Bruno out of "
                    + "Remote Desktop")
        // A manual row's way on is its own button, not a command to run again.
        #expect(SetupCopy.Tune.how("G4", "Sign in once (console window or Remote Desktop), then run this again.")
                == "Sign in once (on Windows' screen or over Remote Desktop), then choose I've Done It.")
        #expect(SetupCopy.Tune.how("G0", "winbar start, wait for Windows, then run this again.")
                == "Start the VM in UTM, wait for Windows, then choose I've Done It.")
    }

    /// Each phrase the window replaces is one the recipe says, word for word; a reworded recipe would
    /// otherwise leave the window showing the new jargon with this table none the wiser.
    @Test("Every phrase the window rewords is still in the recipe")
    func phrasesAreTheRecipes() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Winbar")
        // Joined where a literal is split across lines with +, the way a phrase reaches the window.
        let recipe = try String(contentsOf: sources.appendingPathComponent("Recipe.swift"), encoding: .utf8)
            .replacingOccurrences(of: #""\s*\+\s*""#, with: "", options: .regularExpression)
        for (phrase, _) in SetupCopy.Tune.windowWords {
            #expect(recipe.contains(phrase), "\(phrase)")
        }
    }

    /// Terminal's words are Terminal's: the flags, the prompts and the `?` help all stay.
    @Test("winbar create and winbar setup say what they always said")
    func terminalKeepsItsWords() {
        #expect(CreateCopy.tooltip(.qol).hasPrefix("Rufus's “quality of life” set"))
        #expect(CreateCopy.tooltip(.remoteDesktop).contains("Network Level Authentication"))
        #expect(CreateCopy.coresTooltip(topTier: 6).contains("vCPUs"))
        #expect(CreateCopy.installTooltip.contains("Rufus warns"))
        #expect(ChoiceProblem.coresRange(max: 12).description == "vCPUs: 2 to 12.")
        #expect(SetupCopy.waitingForWindows.contains("guest agent"))
        #expect(Recipe.check("G7")?.title == "RDP certificate")
    }
}

@Suite("Choose is the one instruction verb, and a button's name is bold")
struct SetupCopyVerbTests {
    /// Where "press" and "click" are allowed: Winbar pressing Windows App's tile itself, a key press,
    /// and saying there is nothing to click.
    static let described = ["pressing its tile", "pressed your saved PC", "key press", "click through", "nothing to click",
                            "no clicking", "watch or click"]

    @Test("No instruction says press or click")
    func choose() {
        for text in seen.map(read) {
            var rest = text
            for phrase in Self.described { rest = rest.replacingOccurrences(of: phrase, with: "") }
            #expect(rest.range(of: #"(?i)\b(press|presses|click|clicks)\b"#, options: .regularExpression) == nil, "\(text)")
            #expect(!text.contains("one click away"), "\(text)")
        }
    }

    @Test("The buttons the new instructions name are bold")
    func bold() {
        // The instructions the review found in regular weight: Homebrew's failure, and the install's
        // done page inside the wizard, which also said "Close this result" for a button labelled Done.
        #expect(boldRuns(SetupCopy.LookAround.forWindow("Try it again yourself: brew install --cask utm")) == [SetupCopy.bTryAgain])
        #expect(boldRuns(SetupCopy.markdown(CreateCopy.doneEmbedded)) == [CreateCopy.bDone])
        for next in ["winbar create --resume \"winlab02\"", "winbar start", "winbar setup",
                     "To start over: winbar create --cancel \"winlab02\", then create it again.",
                     "Close this result, choose the new VM, then continue to Tune."] {
            let window = try? #require(CreateCopy.windowNextStep(next, resumable: true))
            #expect(boldRuns(SetupCopy.markdown(window ?? "")).count == 1, "\(next) → \(window ?? "nil")")
        }
        #expect(boldRuns(SetupCopy.VM.oneBody("winlab01", windows: true, use: "winlab01")) == ["Use “winlab01”"])
        // The ticked row's Use, not the lone Windows VM's, and none where the tick isn't Windows.
        #expect(boldRuns(SetupCopy.VM.oneBody("winlab01", windows: true, use: "winlab03")) == ["Use “winlab03”"])
        #expect(boldRuns(SetupCopy.VM.oneBody("winlab01", windows: true, use: nil)).isEmpty)
        #expect(boldRuns(SetupCopy.markdown(SetupCopy.VM.unlisted)) == [SetupCopy.VM.bGoBack])
        #expect(boldRuns(SetupCopy.markdown(SetupCopy.VM.installing)) == [SetupCopy.VM.bShowInstallProgress])
        #expect(boldRuns(SetupCopy.markdown(SetupCopy.VM.notKnownWindows)) == [SetupCopy.VM.bMakeNew])
        #expect(boldRuns(SetupCopy.markdown(SetupCopy.Certificate.waiting)) == [SetupCopy.Certificate.bApprove])
        #expect(boldRuns(SetupCopy.markdown(SetupCopy.Connecting.localNetwork)) == ["Allow"])
        #expect(boldRuns(SetupCopy.markdown(SetupCopy.Connecting.afterRestart)) == [SetupCopy.Connecting.bConnect])
        #expect(boldRuns(SetupCopy.markdown(SetupCopy.Finish.restartStopped))
                == [SetupCopy.Finish.bRestartAndFinish, SetupCopy.Finish.bFinishWithoutRestarting])
        #expect(boldRuns(SetupCopy.Finish.doneBody(vm: "winlab01", .notConnected)[0]) == [SetupCopy.Finish.bTryConnectingAgain])
        #expect(boldRuns(SetupCopy.Finish.doneBody(vm: "winlab01", .windowsAppSkipped)[0]) == [SetupCopy.SavedPC.bOpenAppStore])
        #expect(boldRuns(SetupCopy.Finish.doneBody(vm: "winlab01", .notTried)[0]) == [SetupCopy.Finish.bGoBackToSavedPC])
        #expect(read(SetupCopy.markdown(SetupCopy.LookAround.askBody)).hasPrefix("Choose Open UTM and Ask"))
    }

    /// The bold on a button that carries a VM's name is set on the run, so the name is never parsed:
    /// asterisks in it stay asterisks, and the rest of the sentence stays plain.
    @Test("A button's name with a VM's name in it is bold and still the name's own characters")
    func boldName() {
        let body = SetupCopy.VM.oneBody("winlab01 **beta**", windows: true, use: "winlab01 **beta**")
        #expect(boldRuns(body) == ["Use “winlab01 **beta**”"])
        #expect(read(body).contains("If you choose Use “winlab01 **beta**”, Winbar will look after it"))
    }
}

@Suite("Armie says one dry thing the page beside him doesn't")
struct ArmieLinesTests {
    @Test("No Rosetta joke, no guest agent, and the setup disk is a disk")
    func words() {
        for moment in SetupCopy.Armie.Moment.all {
            let line = SetupCopy.Armie.line(moment)
            for word in ["translat", "agent", "Rosetta", "!", "?"] {
                #expect(!line.contains(word), "\(moment): \(line)")
            }
            #expect(line.range(of: #"\bdiscs?\b"#, options: .regularExpression) == nil, "\(moment): \(line)")
        }
    }

    @Test("He doesn't say what the card, the status line or the stage row beside him says")
    func noRepeats() {
        let noVM = SetupCopy.Armie.line(.noVM)
        #expect(!noVM.contains(SetupCopy.VM.noneHeading) && !noVM.hasPrefix("No Windows"))
        let done = SetupCopy.Armie.line(.done)
        #expect(!done.contains("Connect in Winbar's menu") && !done.contains("set up"))
        #expect(!SetupCopy.Armie.line(.installingUTM).hasPrefix(SetupCopy.LookAround.installing(update: false)))
        #expect(!SetupCopy.Armie.line(.startingWindows).contains("Waiting for Windows"))
        for stage in CreateStage.allCases where stage != .copy {
            let line = SetupCopy.Armie.line(.installing(stage)).lowercased()
            #expect(!line.hasPrefix(stage.shortTitle.lowercased()) && !line.hasPrefix(stage.runningTitle.lowercased()),
                    "\(stage): \(line)")
        }
    }
}
