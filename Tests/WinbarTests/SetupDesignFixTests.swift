import Testing
@testable import Winbar

// The design review's ship-blockers that are about order and words rather than which button Return
// presses (those are SetupDefaultButtonTests). Invented fixtures; nothing is run.

@Suite("Tune puts what needs the person first, and names rows without codes")
struct TuneOrderTests {
    private var mixed: SetupFlow.Facts {
        get throws { try #require(SetupRecoveryFixtures.screens.first { $0.0 == "tune-mixed" }?.1.facts) }
    }

    @Test("A row that needs the person comes first; the rest keep the recipe's order")
    func attentionFirst() throws {
        let facts = try mixed
        let rows = SetupFlow.tune(facts).rows
        let ordered = SetupTuneStatus.attentionFirst(rows, facts: facts)
        let needs = rows.filter { SetupTuneStatus.status(for: $0, facts: facts) == .needsAttention }
        #expect(!needs.isEmpty, "the fixture has nothing needing attention, so this proves nothing")
        #expect(ordered.prefix(needs.count).map(\.id) == needs.map(\.id))
        #expect(ordered.dropFirst(needs.count).map(\.id) == rows.filter { !needs.map(\.id).contains($0.id) }.map(\.id))
        #expect(Set(ordered.map(\.id)) == Set(rows.map(\.id)) && ordered.count == rows.count)
    }

    @Test("The counts point at those rows, and say nothing when there are none")
    func pointer() {
        #expect(SetupCopy.Tune.attentionPointer([.verified: 14, .needsAttention: 1]) == "One setting needs you. It's first below.")
        #expect(SetupCopy.Tune.attentionPointer([.needsAttention: 3])?.hasPrefix("3 settings need you") == true)
        #expect(SetupCopy.Tune.attentionPointer([.verified: 15]) == nil)
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
        let shown = SetupCopy.LookAround.forWindow(failed)
        #expect(shown.hasPrefix("It stopped with exit status 1; its own output is above. Choose Try Again below."))
        #expect(!shown.contains("brew"))
        let unfinished = "Run it yourself and watch what it says: brew install --cask utm"
        #expect(!SetupCopy.LookAround.forWindow(unfinished).contains("brew"))
        for state in [DependencyState.wrongSignature("signed by team ABCDE12345"), .tooOld(version: "4.5.4", minimum: "4.6.0")] {
            let words = SetupCopy.LookAround.plan(.manual("brew upgrade --cask utm"), state: state).joined()
            #expect(!words.contains("brew") && words.contains("Check Again"), "\(state)")
        }
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
