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
            let expected: SetupCommand = diagnosis.readiness == nil ? .perform(.run(.checkAgain(.connect))) : .retryConnection
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

    /// The one filled shape is the card's button, not the footer's Continue Without Connecting: the
    /// accent's fill is painted exactly, so where its pixels are is where the filled button is.
    @Test("The filled button is in the card, and the footer has none", arguments: [Snapshot.Appearance.light, .dark])
    func filledInTheCard(appearance: Snapshot.Appearance) throws {
        let fill = SetupStyle.palette(dark: appearance.isDark, increasedContrast: false).accentFill
        for (name, state) in failures {
            let png = try #require(Snapshot.png(SetupScreen(state: state, art: nil, send: { _ in }),
                                                size: CGSize(width: 600, height: 620), appearance: appearance))
            let filled = Drawing.filled(fill, in: png)
            #expect(filled.count == 1, "\(name): \(filled)")
            #expect(filled.allSatisfy { $0.maxY < 620 - footerBand }, "\(name): a filled button in the footer, \(filled)")
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
        #expect(credentials.password.isEmpty)
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
    /// to nothing in the footer, so an in-card default (Save It, a failed Connect's retry) gets it.
    @Test("An enabled Continue takes Return; a greyed-out one doesn't hold it")
    func onlyWhileEnabled() throws {
        var verified = SetupFixtures.state(.certificate, facts: JourneyFixtures.facts)
        verified.facts?.rows["H7"] = JourneyFixtures.row("H7", .ok("Trusted"))
        let sent = Sent()
        drawn(verified, sent).press(.return)
        #expect(sent.commands == [.next])

        var needs = SetupFixtures.state(.certificate, facts: JourneyFixtures.facts)
        needs.facts?.rows["H7"] = JourneyFixtures.row("H7", .fixable("Not trusted"))
        #expect(!SetupFlow.isSatisfied(.certificate, try #require(needs.facts)))
        let none = Sent()
        #expect(!drawn(needs, none).press(.return))
        #expect(none.commands.isEmpty)
    }
}
