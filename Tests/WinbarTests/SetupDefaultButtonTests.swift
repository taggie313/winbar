import AppKit
import SwiftUI
import Testing
@testable import Winbar

// Which button Return presses, and which one is filled, on the wizard's screens where the design
// review found the wrong one: a failed Connect whose default skipped the test, a saved-PC password
// that Return couldn't save, and a footer whose greyed-out Continue held the default. Each screen is
// drawn from an invented fixture in an offscreen window (`Pressing`) and pressed; nothing is run.

/// What a drawn screen sent, in order.
@MainActor final class Sent {
    var commands: [SetupCommand] = []
    var saved: [String] = []
    func send(_ command: SetupCommand) { commands.append(command) }
    func save(_ password: String) { saved.append(password) }
}

@MainActor private func drawn(_ state: SetupWindowState, _ sent: Sent,
                              credentials: SetupCredentials = SetupCredentials()) -> Pressing<SetupScreen> {
    Pressing(SetupScreen(state: state, art: nil, credentials: credentials, savePassword: sent.save, send: sent.send))
}

/// The footer band's height at the window's first-open size: its buttons are `.large` capsules with
/// 14 pt above and below, so everything drawn lower than this from the bottom is the footer.
private let footerBand: CGFloat = 70

@MainActor @Suite("A failed Connect: Return does what the card says, and never skips the test")
struct ConnectFailureDefaultTests {
    /// The seven recovery screens after No, each with the button its card names.
    private var failures: [(String, SetupWindowState)] {
        SetupRecoveryFixtures.screens.filter { $0.0.hasPrefix("connect-failed") }
    }

    @Test("Return retries on every diagnosis, and checks again on the one that asks for a check")
    func returnFollowsTheCard() throws {
        #expect(failures.count == 7)
        for (name, state) in failures {
            let facts = try #require(state.facts)
            guard case .didNotWork(let diagnosis) = SetupFlow.connect(facts) else {
                Issue.record("\(name) isn't the recovery card")
                continue
            }
            let sent = Sent()
            #expect(drawn(state, sent).press(.return), "\(name): nothing took Return")
            // Where macOS refused the check, the setting comes first: a retry would only be refused.
            let expected: SetupCommand = diagnosis.readiness == nil ? .perform(.run(.checkAgain(.connect)))
                : diagnosis.readiness == .blocked ? .open(.localNetworkSettings) : .retryConnection
            #expect(sent.commands == [expected], "\(name)")
        }
    }

    /// The card's words and its button can't disagree: each diagnosis names, in bold, the one button
    /// its card draws — "Choose **Check Again**" sat over a button labelled Try Again.
    @Test("Each card's steps name the button the card draws")
    func copyNamesTheButton() {
        for readiness in [RDP.Readiness.blocked, .notReady, .ready, nil] {
            let recovery = SetupCopy.Connecting.recovery(readiness, savedPC: true, console: .unknown)
            let other = recovery.retry == .checkAgain ? SetupCopy.bTryAgain : SetupCopy.bCheckAgain
            #expect(recovery.steps.contains { $0.contains("**\(recovery.retry.title)**") }, "\(String(describing: readiness))")
            #expect(!recovery.steps.contains { $0.contains("**\(other)**") }, "\(String(describing: readiness))")
        }
        #expect(SetupCopy.Connecting.recovery(nil, savedPC: true, console: .unknown).retry == .checkAgain)
        #expect(SetupCopy.Connecting.recovery(.notReady, savedPC: true, console: .unknown).retry == .tryAgain)
    }

    /// The one filled shape is the diagnosis' own action in the footer's corner, where every other
    /// step keeps its action: the corner held a plain Continue Without Connecting and the action sat
    /// in the card. The accent's fill is painted exactly, so where its pixels are is where the filled
    /// button is; and Continue Without Connecting, plain, is on the left beside Back.
    @Test("The filled button is the footer's corner, and moving on without the test is beside Back",
          arguments: [Snapshot.Appearance.light, .dark])
    func filledInTheCorner(appearance: Snapshot.Appearance) throws {
        let fill = SetupStyle.palette(dark: appearance.isDark, increasedContrast: false).accentFill
        for (name, state) in failures {
            let png = try #require(Snapshot.png(SetupScreen(state: state, art: nil, send: { _ in }),
                                                size: CGSize(width: 600, height: 620), appearance: appearance))
            let filled = Drawing.filled(fill, in: png)
            #expect(filled.count == 1, "\(name): \(filled)")
            #expect(filled.allSatisfy { $0.minY > 620 - footerBand && $0.midX > 300 }, "\(name): not the corner, \(filled)")
            let footer = SetupFooter.footer(state)
            #expect(footer.leading.map(\.title) == [SetupCopy.bBack, SetupCopy.journeyNext(.connect, facts: state.facts)],
                    "\(name)")
            #expect(footer.leading.allSatisfy { $0.kind == .plain } && footer.trailing.count == 1, "\(name)")
        }
    }

    /// The control: Connect answered Yes. Continue to Finish is the footer's filled default, as on
    /// every other step, so the rule above is about the failure, not the footer.
    @Test("After Yes, Return is the footer's Continue to Finish")
    func workedContinues() throws {
        var state = SetupFixtures.state(.connect, facts: JourneyFixtures.facts)
        state.answers.connectionOpened = true
        state.answers.connected = true
        state.facts?.answers = state.answers
        let sent = Sent()
        drawn(state, sent).press(.return)
        #expect(sent.commands == [.next])
        let png = try #require(Snapshot.png(SetupScreen(state: state, art: nil, send: { _ in }),
                                            size: CGSize(width: 600, height: 620), appearance: .light))
        let filled = Drawing.filled(SetupStyle.palette(dark: false, increasedContrast: false).accentFill, in: png)
        #expect(filled.count == 1 && filled.allSatisfy { $0.minY > 620 - footerBand }, "\(filled)")
    }
}

@MainActor @Suite("The saved PC: the field says Windows, and Return saves")
struct SavedPCReturnTests {
    private var saveScreen: SetupWindowState {
        var state = SetupFixtures.state(.savedPC, facts: JourneyFixtures.facts)
        state.facts?.rows["C2"] = JourneyFixtures.row("C2", .fixable("No saved PC"))
        return state
    }

    @Test("Return with a password typed saves it, and hands it over once")
    func returnSaves() throws {
        let state = saveScreen
        guard case .save = SetupFlow.savedPC(try #require(state.facts)) else {
            Issue.record("not the password screen")
            return
        }
        let sent = Sent()
        let credentials = SetupCredentials()
        credentials.password = "synthetic-test-secret"
        let window = drawn(state, sent, credentials: credentials)
        #expect(window.press(.return))
        #expect(sent.saved == ["synthetic-test-secret"])
        #expect(sent.commands.isEmpty)
        // Forgotten by the controller once the runner takes it, not by the page: a refused Save It
        // keeps what was typed (`SetupWindowController.savePC(password:)`).
        #expect(credentials.password == "synthetic-test-secret")
    }

    /// Typed into the field itself, as a keystroke rather than a key equivalent: the field's own
    /// submit. Nothing to save with an empty field, and the step's footer isn't pressed instead.
    @Test("Return in the field saves too, and an empty field saves nothing")
    func submitSaves() throws {
        let sent = Sent()
        let credentials = SetupCredentials()
        credentials.password = "synthetic-test-secret"
        let window = drawn(saveScreen, sent, credentials: credentials)
        #expect(window.submitSecureField())
        #expect(sent.saved == ["synthetic-test-secret"])

        let empty = Sent()
        let nothing = drawn(saveScreen, empty)
        nothing.submitSecureField()
        nothing.press(.return)
        #expect(empty.saved.isEmpty && empty.commands.isEmpty)
    }

    @Test("The field is labelled as the Windows password, for the Windows user")
    func label() {
        #expect(String(SetupCopy.SavedPC.passwordLabel(user: "Bruno").characters) == "Windows password for Bruno")
    }
}

@MainActor @Suite("The footer's Continue is the default only while it can be pressed")
struct FooterDefaultTests {
    /// A step whose Continue is enabled takes Return; the same step with it greyed out gives Return
    /// to nothing in the footer, so the page's own main button (Save It, a failed Connect's retry,
    /// Approve Certificate…) gets it — filled, as the one filled button on the screen
    /// (`stepPrimaryButton`). Before the button system, a greyed-out Continue left Return to nothing.
    @Test("An enabled Continue takes Return; a greyed-out one leaves it to the page's own button")
    func onlyWhileEnabled() throws {
        var verified = SetupFixtures.state(.certificate, facts: JourneyFixtures.facts)
        verified.facts?.rows["H7"] = JourneyFixtures.row("H7", .ok("Trusted"))
        let sent = Sent()
        drawn(verified, sent).press(.return)
        #expect(sent.commands == [.next])

        var needs = SetupFixtures.state(.certificate, facts: JourneyFixtures.facts)
        needs.facts?.rows["H7"] = JourneyFixtures.row("H7", .fixable("Not trusted"))
        #expect(!SetupFlow.isSatisfied(.certificate, try #require(needs.facts)))
        #expect(SetupCertificatePage.page(needs, facts: try #require(needs.facts)).canApprove)
        let card = Sent()
        #expect(drawn(needs, card).press(.return))
        #expect(card.commands == [.perform(.run(.trustCertificate))])

        // With nothing to approve, the step's one action is to look again, and Return does that: the
        // greyed-out Continue never holds it.
        needs.facts?.vmRunning = false
        #expect(!SetupCertificatePage.page(needs, facts: try #require(needs.facts)).canApprove)
        #expect(SetupFooter.footer(needs).corner?.title == SetupCopy.bCheckAgain)
        let none = Sent()
        #expect(drawn(needs, none).press(.return))
        #expect(none.commands == [.perform(.run(.checkAgain(.certificate)))])
    }
}

@MainActor @Suite("A step's own main button takes Return while the footer's Continue can't")
struct StepDefaultButtonTests {
    /// Return on a drawn screen, and the one filled button on it: in the card (`stepPrimaryButton`,
    /// where a plain button would leave Return to nothing), or in the footer's corner for a step that
    /// hands its action there (`SetupJourneyActions.footerAction`).
    private func returnPresses(_ state: SetupWindowState, _ name: String, inFooter: Bool = false) throws -> [SetupCommand] {
        let sent = Sent()
        #expect(drawn(state, sent).press(.return), "\(name): nothing took Return")
        let png = try #require(Snapshot.png(SetupScreen(state: state, art: nil, send: { _ in }),
                                            size: CGSize(width: 600, height: 620), appearance: .light))
        let filled = Drawing.filled(SetupStyle.palette(dark: false, increasedContrast: false).accentFill, in: png)
        #expect(filled.count == 1, "\(name): \(filled)")
        #expect(filled.allSatisfy { inFooter ? $0.minY > 620 - footerBand : $0.maxY < 620 - footerBand }, "\(name): \(filled)")
        return sent.commands
    }

    @Test("Ready to test: Return presses Connect, in the footer's corner")
    func connect() throws {
        let state = try #require(SetupRecoveryFixtures.screens.first { $0.0 == "connect-ready" }?.1)
        guard case .ready = SetupFlow.connect(try #require(state.facts)) else {
            Issue.record("not the Connect card")
            return
        }
        #expect(try returnPresses(state, "connect-ready", inFooter: true) == [.perform(.run(.connect))])
    }

    @Test("Did the desktop appear: Return answers Yes")
    func yes() throws {
        let state = JourneyFixtures.didItWork
        guard case .didItWork = SetupFlow.connect(try #require(state.facts)) else {
            Issue.record("not the did-it-work card")
            return
        }
        #expect(try returnPresses(state, "did-it-work") == [.connected(true)])
    }

    /// The card says to go back to Tune; the footer had nothing filled, so Return did nothing.
    @Test("No certificate yet: Return presses Go Back to Tune, in the footer's corner")
    func certificateGoBack() throws {
        let state = try #require(SetupRecoveryFixtures.screens.first { $0.0 == "certificate-needs" }?.1)
        #expect(SetupCertificatePage.page(state, facts: try #require(state.facts)).next == .goBack)
        #expect(try returnPresses(state, "certificate-needs", inFooter: true) == [.back])
    }

    /// The headline says to follow the row's steps; the corner held a greyed-out Continue and the first
    /// step was a plain button in the row, so nothing on the page was filled. The row's button is the
    /// corner's now, and drawn once.
    @Test("A setting only Ben can change: Return presses the row's first step, in the footer's corner, drawn once")
    func tuneManual() throws {
        let state = try #require(SetupRecoveryFixtures.screens.first { $0.0 == "tune-mixed" }?.1)
        let facts = try #require(state.facts)
        #expect(SetupFlow.tune(facts).fixEverything.isEmpty)
        let h6 = try #require(facts.rows["H6"])
        let first = try #require(SetupTuneRowActions.of(h6, facts: facts).first)
        #expect(try returnPresses(state, "tune-mixed", inFooter: true) == [first.command])
        let png = try #require(Snapshot.png(SetupScreen(state: state, art: nil, send: { _ in }),
                                            size: CGSize(width: 600, height: 620), appearance: .light))
        let lines = try Drawing.lines(png)
        #expect(lines.filter { $0.text.replacingOccurrences(of: "...", with: "…") == first.title }.count == 1, "\(lines)")
    }

    @Test("Settings Winbar can fix: Return presses Fix Everything, in the footer's corner")
    func fixEverything() throws {
        var state = SetupFixtures.state(.tune, facts: JourneyFixtures.facts)
        state.facts?.rows["G1"] = JourneyFixtures.row("G1", .fixable("Power plan"))
        #expect(!SetupFlow.tune(try #require(state.facts)).fixEverything.isEmpty)
        #expect(try returnPresses(state, "tune-fixable", inFooter: true) == [.perform(.run(.fixEverything))])
    }
}
