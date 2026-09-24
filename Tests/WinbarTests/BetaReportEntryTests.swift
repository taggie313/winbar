import AppKit
import Testing
@testable import Winbar

// Every way into the beta's Send a Problem Report… (`BetaReport`) asks one switch, so taking the
// beta out is flipping it. Each surface is built here both ways — the menu bar menu, the Help menu,
// the title bar's Help!, and the failure cards' Send This to the Developer — from its pure builder,
// with invented states only. Nothing opens a window, reaches UTM or sends anything.

@Suite("Send a Problem Report… is in both menus while the beta is on, and in neither once it's off")
@MainActor
struct BetaReportMenuTests {
    /// Menus in the situations that matter: no VM, a running VM, the menu busy, an install, the wizard
    /// coordinating the VM.
    private static var menus: [MenuState] {
        let install = MenuInstall(vmName: "winlab01", stage: .copy, elapsed: 600, inTerminal: false, resumed: false)
        var busyWizard = MenuState(status: MenuStatus(vmName: "winlab01", running: true))
        busyWizard.setupBusy = true
        return [MenuState(status: MenuStatus(vmName: nil)),
                MenuState(status: MenuStatus(vmName: "winlab01", running: true, readiness: .ready)),
                MenuState(status: MenuStatus(vmName: "winlab01", running: true, activity: "Shutting down…")),
                MenuState(status: MenuStatus(vmName: nil, install: install)),
                busyWizard]
    }

    @Test("On: directly under Report a Problem…, and never greyed out, whatever else is going on")
    func onInEveryMenu() throws {
        for var given in Self.menus {
            given.betaReport = true
            let items = MenuShape.items(given)
            let report = try #require(items.firstIndex { if case .item(let item) = $0 { item.action == .reportProblem } else { false } })
            #expect(items[report + 1] == .action(BetaReport.Copy.menuItem, .sendReport), "\(given.status)")
        }
    }

    @Test("Off: no menu has it")
    func offInNone() {
        for var given in Self.menus {
            given.betaReport = false
            #expect(!MenuShape.items(given).contains { if case .item(let item) = $0 { item.action == .sendReport } else { false } })
        }
    }

    @Test("The Help menu has it under Report a Problem… while on, up the responder chain to the app, and not while off")
    func helpMenu() throws {
        let on = try #require(AppPresence.mainMenu(betaReport: true).items.first { $0.title == "Help" }?.submenu)
        let report = on.indexOfItem(withTitle: Diagnose.Copy.menuItem)
        let send = try #require(on.item(withTitle: BetaReport.Copy.menuItem))
        #expect(on.index(of: send) == report + 1)
        #expect(send.action == #selector(AppDelegate.sendProblemReport))
        #expect(send.target == nil)
        let off = try #require(AppPresence.mainMenu(betaReport: false).items.first { $0.title == "Help" }?.submenu)
        #expect(off.item(withTitle: BetaReport.Copy.menuItem) == nil)
        // Leave the app's Help menu as the other tests expect to find it.
        _ = AppPresence.mainMenu()
    }
}

@Suite("Send This to the Developer is on every failure card while the beta is on, and on none once it's off")
struct BetaReportCardTests {
    private static func failed(_ state: SetupWindowState, _ work: SetupRunner.Work) -> SetupWindowState {
        var state = state
        state.lastEnding = SetupRunner.Ending(work: work, outcome: .failed(.init(title: "UTM didn't answer", detail: "-1712")),
                                              facts: state.facts ?? JourneyFixtures.facts, slept: false,
                                              started: SetupFixtures.started)
        return state
    }

    /// One page per kind of failure card, each with the card on screen.
    static var failures: [(card: BetaReport.Card, state: SetupWindowState)] {
        [(.lookAround, SetupFixtures.installFailed),
         (.vmFailure, failed(SetupFixtures.state(.vm, facts: nil), .startVM("winlab01"))),
         (.problem, failed(JourneyFixtures.page(.tune), .checkAgain(.tune))),
         (.certificate, failed(JourneyFixtures.page(.certificate), .trustCertificate)),
         (.savedPC, JourneyPolishFixtures.state(.savedPC) { $0.facts?.rows["C2"] = JourneyFixtures.row("C2", SilentFixtures.status) }),
         (.connectRecovery, JourneyPolishFixtures.state(.connect) {
             $0.answers.connectionOpened = true; $0.answers.connected = false; $0.facts?.readiness = .notReady
         })]
    }

    /// Pages with nothing failed on them, some with work running.
    static var fine: [SetupWindowState] {
        [SetupFixtures.state(.welcome), SetupFixtures.installing, JourneyFixtures.page(.tune), JourneyFixtures.page(.savedPC),
         JourneyFixtures.page(.connect), ArmieFixtures.done, ArmieFixtures.starting]
    }

    @Test("On: each failure card has it, and no other card on the page does")
    func on() {
        #expect(Set(Self.failures.map(\.card)) == Set(BetaReport.Card.allCases))
        for (card, state) in Self.failures {
            #expect(BetaReport.cards(state, enabled: true) == [card], "\(card)")
        }
        for state in Self.fine {
            #expect(BetaReport.cards(state, enabled: true).isEmpty, "\(state.step)")
        }
    }

    @Test("Off: no card has it")
    func off() {
        for (card, state) in Self.failures {
            #expect(BetaReport.cards(state, enabled: false).isEmpty, "\(card)")
        }
    }

    @Test("The New Windows VM failure page has it while on, and only a failed install's page")
    func installFailurePage() {
        let failure = CreateFailure(code: "E_BOOT", title: "Windows didn't start", detail: "", nextStep: nil)
        #expect(CreateJobView.offersReport(ArmieFixtures.job(outcome: .failed, failure: failure), enabled: true))
        #expect(!CreateJobView.offersReport(ArmieFixtures.job(outcome: .failed, failure: failure), enabled: false))
        for outcome in [nil, .done, .cancelled] as [CreateJobState.Outcome?] {
            #expect(!CreateJobView.offersReport(ArmieFixtures.job(outcome: outcome), enabled: true), "\(String(describing: outcome))")
        }
    }
}

@Suite("Help! is in the title bar while the beta is on")
@MainActor
struct BetaReportTitlebarTests {
    @Test("On: a Help! button at the trailing end that opens the dialog; off: no accessory at all")
    func titlebar() throws {
        #expect(BetaReport.titlebarHelp(enabled: false, press: {}) == nil)
        var pressed = 0
        let accessory = try #require(BetaReport.titlebarHelp(enabled: true) { pressed += 1 })
        #expect(accessory.layoutAttribute == .trailing)
        let button = try #require(BetaReport.helpButton(in: accessory))
        #expect(button.title == BetaReport.Copy.helpButton)
        _ = NSApplication.shared
        button.performClick(nil)
        #expect(pressed == 1)
    }

    /// Asking for help reads; it may be pressed with anything running, and it answers nothing a
    /// refused press's banner said, so the banner stays.
    @Test("The window's Help! opens the dialog while work runs, and leaves a refusal's banner up")
    func fromTheWindow() throws {
        var state = SetupFixtures.installing
        let flight = try #require(state.inFlight)
        state.refusal = SetupRunner.Refusal(wanted: .checkAgain(.lookAround), inFlight: flight)
        var opened = 0
        let controller = SetupWindowController(state: state, art: nil,
                                               settings: .init(wizardShown: { false }, markShown: {}, armieHidden: { true },
                                                               hideArmie: {}),
                                               sendReport: { opened += 1 })
        controller.send(.sendReport)
        #expect(opened == 1)
        #expect(controller.state.refusal != nil)
    }
}
