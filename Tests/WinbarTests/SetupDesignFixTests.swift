import Testing
@testable import Winbar

// The design review's ship-blockers that are about order and words rather than which button Return
// presses (those are SetupDefaultButtonTests). Invented fixtures; nothing is run.

@Suite("Tune puts what needs the person first, and names rows without codes")
struct TuneOrderTests {
    private var mixed: SetupFlow.Facts {
        get throws { try #require(SetupRecoveryFixtures.screens.first { $0.0 == "tune-mixed" }?.1.facts) }
    }

    @Test("A row that needs the person comes first; each group keeps the recipe's order")
    func attentionFirst() throws {
        let facts = try mixed
        let rows = SetupFlow.tune(facts).rows
        let groups = SetupTuneGroups(facts)
        let ordered = groups.needsYou + groups.others + groups.verified
        let needs = rows.filter { SetupTuneStatus.status(for: $0, facts: facts) == .needsAttention }
        #expect(!needs.isEmpty, "the fixture has nothing needing attention, so this proves nothing")
        #expect(ordered.prefix(needs.count).map(\.id) == needs.map(\.id))
        for group in [groups.needsYou, groups.others, groups.verified] {
            #expect(group.map(\.id) == rows.filter { row in group.contains { $0.id == row.id } }.map(\.id))
        }
        #expect(Set(ordered.map(\.id)) == Set(rows.map(\.id)) && ordered.count == rows.count)
    }

    @Test("The headline says how many need the person, and nothing of the sort when none do")
    func pointer() throws {
        #expect(SetupTuneHeadline.of(try mixed) == .needsYou(count: 1, fixable: 0))
        #expect(SetupCopy.Tune.headline(.needsYou(count: 1, fixable: 0)).title == "1 setting needs you")
        #expect(SetupCopy.Tune.headline(.needsYou(count: 1, fixable: 0)).detail?.hasPrefix("It's first below") == true)
        #expect(SetupCopy.Tune.headline(.needsYou(count: 3, fixable: 0)).title.hasPrefix("3 settings need you"))
        #expect(SetupTuneHeadline.of(JourneyFixtures.facts) == .tuned(staged: 0))
    }

    @Test("Recipe sentences lose their check codes in the window")
    func plain() {
        #expect(SetupCopy.Tune.plain("Remote Desktop is on (G6), its certificate is trusted (H7) and it works.")
                == "Remote Desktop is on, its certificate is trusted and it works.")
        #expect(SetupCopy.Tune.plain("headless is offered once Remote Desktop works (G5, G6, H7)")
                == "headless is offered once Remote Desktop works")
        #expect(SetupCopy.Tune.plain("Nothing to strip here.") == "Nothing to strip here.")
        #expect(!SetupCopy.Certificate.noCertificate.contains("G7"))
    }
}

@Suite("The window gives its own way forward where Terminal's said to type a command")
struct WindowRecoveryWordsTests {
    @Test("A stall's recovery names the window's Try Again, and only in the window")
    func stall() {
        let cli = CreateCopy.wStall(vmName: "winlab02")
        #expect(cli.contains("winbar create --resume “winlab02”"))
        let window = CreateCopy.forWindow(cli, vmName: "winlab02")
        #expect(!window.contains("--resume") && window.contains("Try Again starts the VM again"))
        #expect(window.hasPrefix("The VM has been idle"))
    }

    @Test("A --resume next step becomes Try Again when the job can carry on, and goes when it can't")
    func nextStep() {
        #expect(CreateCopy.windowNextStep("winbar create --resume \"winlab02\"", resumable: true)?.contains("Try Again") == true)
        #expect(CreateCopy.windowNextStep("winbar create --resume \"winlab02\"", resumable: false) == nil)
        #expect(CreateCopy.windowNextStep("Check the ISO.", resumable: false) == "Check the ISO.")
    }

    @Test("Homebrew's failure points at Try Again; a UTM that isn't UTM, or is too old, at the Finder and Check Again")
    func lookAround() {
        let failed = "It stopped with exit status 1; its own output is above. Try it again yourself: brew install --cask utm"
        let drawn = SetupCopy.LookAround.forWindow(failed)
        let shown = String(drawn.characters)
        // "Its own output is above" is Terminal's layout, and the exit status a number Ben can't use; in the
        // window the output is the open fold below, and the sentence opens on what to do, naming the
        // button in bold as every instruction in the window does.
        #expect(shown == "Choose Try Again below. If it keeps failing, UTM's own download at getutm.app works too.")
        #expect(boldRuns(drawn) == [SetupCopy.bTryAgain])
        #expect(!shown.contains("brew") && !shown.contains("above") && !shown.contains("exit status"))
        let unfinished = "Run it yourself and watch what it says: brew install --cask utm"
        #expect(!String(SetupCopy.LookAround.forWindow(unfinished).characters).contains("brew"))
        // Homebrew's own words around it stay as they were, not read as Markdown.
        let path = "Couldn't write /opt/homebrew/some_cask_dir. Try it again yourself: brew install --cask utm"
        #expect(String(SetupCopy.LookAround.forWindow(path).characters).hasPrefix("Couldn't write /opt/homebrew/some_cask_dir. "))
        // A plan Winbar can't carry out: no Terminal advice under Details, and the card's sentence
        // names what to do in the Finder and the window.
        let wrong = DependencyState.wrongSignature("signed by team ABCDE12345")
        let old = DependencyState.tooOld(version: "4.5.4", minimum: "4.6.0")
        for state in [wrong, old] {
            let manual = InstallPlan.manual("brew upgrade --cask utm")
            #expect(SetupCopy.LookAround.plan(manual, state: state).isEmpty, "\(state)")
            let words = SetupCopy.LookAround.summary(manual, state: state) + SetupCopy.LookAround.details(manual, state: state).joined()
            #expect(!words.contains("brew"), "\(state)")
        }
        #expect(SetupCopy.LookAround.summary(.manual(""), state: wrong).contains("**Show in Finder**"))
        #expect(SetupCopy.LookAround.summary(.manual(""), state: old).hasSuffix(SetupCopy.LookAround.comeBack))
    }
}

@Suite("Busy lines are sentences")
struct BusySentenceTests {
    @Test func sentence() {
        #expect(SetupCopy.Working.sentence("saving the PC in Windows App") == "Saving the PC in Windows App…")
        #expect(SetupCopy.Working.sentence("") == "")
        #expect(SetupCopy.VM.startingHeading("winlab02") == "Starting “winlab02”…")
    }
}
