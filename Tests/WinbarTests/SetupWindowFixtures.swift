import AppKit
import Foundation
@testable import Winbar

// Invented Macs for the set-up window's tests: every screen and state of steps 0 and 1, as a
// `SetupWindowState`. Nothing here reads this Mac, its settings, UTM or a VM. The names and paths are
// made up; the words the window shows come from the deck and the recipe, as they do in the app.

enum SetupFixtures {
    static let brew = "/opt/homebrew/bin/brew"

    /// A snapshot as the runner would build it: H1 and C1 from the window's own plan
    /// (`SetupRunner.dependencyRow`), the way `SetupRunner.row(for:readings:)` builds them.
    static func facts(utm: DependencyState, brew: String? = nil, fromHomebrew: Bool = false, answers: UTM.CtlAnswer? = nil,
                      consent: Automation.Consent = .decided, quarantined: Bool = false,
                      vms: SetupFlow.VMListing = .notAsked,
                      windowsApp: DependencyState = .installed(version: "11.4.1")) -> SetupFlow.Facts {
        var facts = SetupFlow.Facts()
        facts.utm = utm
        facts.homebrew = brew
        facts.utmFromHomebrew = fromHomebrew
        facts.utmAnswers = answers
        facts.utmConsent = consent
        facts.utmQuarantined = quarantined
        facts.vms = vms
        facts.windowsApp = windowsApp
        facts.rows["H1"] = SetupFlow.Row(Recipe.check("H1")!, SetupRunner.dependencyRow(.utm, state: utm, brew: brew,
                                                                                         brewHasCask: fromHomebrew))
        facts.rows["C1"] = SetupFlow.Row(Recipe.check("C1")!,
                                         SetupRunner.dependencyRow(.windowsApp, state: windowsApp, brew: brew))
        if let answers {
            facts.rows["H9"] = SetupFlow.Row(Recipe.check("H9")!,
                                             Recipe.utmctlStatus(answers, consent: consent, quarantined: quarantined))
        }
        facts.answers.started = true
        return facts
    }

    static let installed = DependencyState.installed(version: "4.7.5")
    static let twoVMs: SetupFlow.VMListing = .listed([
        VMInfo(id: "5A1E0C3D-0000-4000-8000-00000000000D", name: "winlab01", backend: "qemu", icon: "windows"),
        VMInfo(id: "5A1E0C3D-0000-4000-8000-00000000000A", name: "atelier", backend: "qemu", icon: "linux"),
    ])

    static let started = Date(timeIntervalSince1970: 1_800_000_000)

    static func flight(_ work: SetupRunner.Work, line: String? = nil) -> SetupRunner.InFlight {
        SetupRunner.InFlight(work: work, started: started, vm: nil, line: line)
    }

    static func state(_ step: WizardStep = .lookAround, facts: SetupFlow.Facts? = nil,
                      inFlight: SetupRunner.InFlight? = nil) -> SetupWindowState {
        var state = SetupWindowState()
        state.step = step
        state.answers.started = step != .welcome
        state.facts = facts
        state.inFlight = inFlight
        return state
    }

    /// Homebrew's words, as `runStreaming` relays them. Invented, in Homebrew's own shape.
    static let homebrewLines = [
        DependencyCopy.askingHomebrew(.utm, command: Homebrew.installCommand(brew: brew, cask: "utm")),
        "==> Downloading https://github.com/utmapp/UTM/releases/download/v4.7.5/UTM.dmg",
        "==> Installing Cask utm",
        "==> Moving App 'UTM.app' to '/Applications/UTM.app'",
        "==> Linking Binary 'utmctl' to '/opt/homebrew/bin/utmctl'",
    ]

    static var installing: SetupWindowState {
        var state = state(facts: facts(utm: .missing, brew: brew), inFlight: flight(.installUTM, line: homebrewLines.last))
        state.lines = homebrewLines
        state.linesStarted = started
        return state
    }

    static let old = DependencyState.tooOld(version: "4.5.4", minimum: "4.6.0")

    /// Winbar's own download, a little under half way.
    static var downloading: SetupWindowState {
        let source = URL(string: "https://github.com/utmapp/UTM/releases/download/v4.7.5/UTM.dmg")!
        let lines = [DependencyCopy.downloading(.utm, from: source),
                     DependencyCopy.downloadProgress(.utm, done: 112 << 20, total: 250 << 20)]
        var state = state(facts: facts(utm: .missing), inFlight: flight(.installUTM, line: lines.last))
        state.lines = lines
        state.linesStarted = started
        return state
    }

    /// Homebrew replacing a UTM it installed, which is too old.
    static var updating: SetupWindowState {
        let lines = [DependencyCopy.askingHomebrew(.utm, command: Homebrew.upgradeCommand(brew: brew, cask: "utm")),
                     "==> Upgrading 1 outdated package:", "utm 4.5.4 -> 4.7.5",
                     "==> Quitting application 'com.utmapp.UTM'..."]
        var state = state(facts: facts(utm: old, brew: brew, fromHomebrew: true), inFlight: flight(.installUTM, line: lines.last))
        state.lines = lines
        state.linesStarted = started
        return state
    }

    static var installFailed: SetupWindowState {
        var state = state(facts: facts(utm: .missing, brew: brew))
        state.lines = Array(homebrewLines.prefix(2)) + ["curl: (56) Recv failure: Connection reset by peer",
                                                       "Error: Download failed on Cask 'utm' with message: Download failed"]
        let problem = SetupRunner.Problem(title: "Homebrew couldn't install UTM",
                                          detail: "It stopped with exit status 1; its own output is above. Try it again "
                                              + "yourself: brew install --cask utm")
        state.lastEnding = SetupRunner.Ending(work: .installUTM, outcome: .failed(problem),
                                              facts: state.facts!, slept: false, started: started, lines: state.lines)
        state.linesStarted = started
        return state
    }

    /// Every screen and state steps 0 and 1 can show, by the name its renders are filed under.
    static var screens: [(name: String, state: SetupWindowState)] {
        var hidden = installing
        hidden.armieHidden = true
        // The one way to be refused on step 1: while UTM installs, Back to the welcome and Start again.
        var refused = installing
        refused.refusal = SetupRunner.Refusal(wanted: .checkAgain(.lookAround), inFlight: flight(.installUTM))
        return [
            ("welcome", state(.welcome)),
            ("reading", state(inFlight: flight(.checkAgain(.lookAround)))),
            ("needs-utm-download", state(facts: facts(utm: .missing))),
            ("needs-utm-homebrew", state(facts: facts(utm: .missing, brew: brew))),
            ("rereading", state(facts: facts(utm: .missing), inFlight: flight(.checkAgain(.lookAround)))),
            ("needs-utm-update", state(facts: facts(utm: old, brew: brew, fromHomebrew: true))),
            ("needs-utm-update-by-hand", state(facts: facts(utm: old, brew: brew))),
            ("needs-utm-not-utm", state(facts: facts(utm: .wrongSignature(
                "UTM at /Applications/UTM.app is signed by team ABCDE12345, not Turing Software's (WDNLXAD4W8)")))),
            ("installing", installing),
            ("installing-download", downloading),
            ("updating", updating),
            ("installing-armie-hidden", hidden),
            ("install-failed", installFailed),
            ("ask-utm", state(facts: facts(utm: installed))),
            ("ask-utm-homebrew", state(facts: facts(utm: installed, brew: brew, fromHomebrew: true, quarantined: true))),
            // A UTM downloaded with a browser, the commonest way to get it: the same mark, and no Homebrew.
            ("ask-utm-downloaded", state(facts: facts(utm: installed, quarantined: true))),
            ("settling", state(facts: facts(utm: installed), inFlight: flight(.settleUTM, line: UTMFirstUse.waiting))),
            // The same wait for a copy with the mark, which Open UTM and Ask has just opened for the first time.
            ("settling-homebrew", state(facts: facts(utm: installed, brew: brew, fromHomebrew: true, quarantined: true),
                                        inFlight: flight(.settleUTM, line: UTMFirstUse.waiting))),
            ("utm-silent", state(facts: facts(utm: installed, answers: .silent(seconds: 60), consent: .wouldPrompt,
                                              quarantined: true))),
            ("utm-silent-decided", state(facts: facts(utm: installed, answers: .silent(seconds: 60), consent: .decided))),
            ("utm-denied", state(facts: facts(utm: installed, answers: .denied))),
            ("utm-failed", state(facts: facts(utm: installed, answers: .failed("UTM is not running (error -600)")))),
            ("list-failed", state(facts: facts(utm: installed, answers: .answered, vms: .failed(.init(
                title: "UTM didn't answer in time", detail: "It may be busy or showing a dialog. Nothing came back "
                    + "within 30 seconds.", timedOut: true))))),
            ("done", state(facts: facts(utm: installed, answers: .answered, vms: twoVMs))),
            ("done-no-windows-app", state(facts: facts(utm: installed, answers: .answered, vms: .listed([]),
                                                       windowsApp: .missing))),
            ("refused", refused),
            ("vm-one", state(.vm, facts: facts(utm: installed, answers: .answered, vms: twoVMs))),
            ("vm-none", state(.vm, facts: facts(utm: installed, answers: .answered, vms: .listed([])))),
            ("vm-choose", state(.vm, facts: facts(utm: installed, answers: .answered,
                                                vms: .listed([SetupVMTests.old, SetupVMTests.new])))),
            ("vm-running", state(.vm, facts: SetupVMTests.facts())),
        ]
    }
}
