import SwiftUI

// The band at the foot of the Set Up Winbar window, as a value: which buttons it has, which one sits
// bottom-right, and whether that one is the filled default. Every step's footer is decided here, from
// the window's state, so the rule for the one filled button is written once and a test can read it
// without drawing.
//
// The bottom-right corner is the way forward on every step (§2, Apple's and Windows' assistants
// alike). A step whose main action is still to be pressed hands that action to the footer
// (`stepAction`), so it sits there rather than in a card; once the step is satisfied, the footer's
// Continue takes the corner. Step 1 has always worked this way (`LookAroundPage.Page.primary`); the
// others move their actions here one by one.

struct SetupFooter: Equatable {
    struct Button: Equatable {
        /// What pressing it does: a command for the window, or the saved-PC step's **Save It**, which
        /// hands over the password typed on the page — something no command may carry
        /// (`SetupWindowController.savePC(password:)`).
        enum Press: Equatable {
            case send(SetupCommand)
            case savePassword
        }

        /// `primary` is filled and takes Return, but only while it can be pressed: a greyed-out filled
        /// button measured as the most solid thing in the footer under Increase Contrast, and a
        /// default nobody can press holds Return from a button on the page that can take it. `cancel`
        /// takes Escape.
        enum Kind: Equatable { case plain, cancel, primary }

        var title: String
        var press: Press
        var enabled = true
        var kind: Kind = .plain
        /// Why it can't be pressed yet, drawn beside it in the quiet grey while it can't, as the New
        /// Windows VM form says why its Continue is greyed out: a greyed-out button measured about
        /// 1.6:1 and said nothing of what it waited for.
        var reason: String?

        init(_ title: String, _ press: Press, enabled: Bool = true, kind: Kind = .plain, reason: String? = nil) {
            self.title = title
            self.press = press
            self.enabled = enabled
            self.kind = kind
            self.reason = reason
        }

        init(_ title: String, _ command: SetupCommand, enabled: Bool = true, kind: Kind = .plain, reason: String? = nil) {
            self.init(title, .send(command), enabled: enabled, kind: kind, reason: reason)
        }

        /// Whether it can be pressed now. **Save It** has nothing to save while the field is empty.
        func pressable(passwordTyped: Bool = true) -> Bool {
            enabled && (press != .savePassword || passwordTyped)
        }

        /// Whether it is drawn filled and takes Return: a primary that can be pressed. `passwordTyped`
        /// is the saved-PC field's, for **Save It**, which has nothing to save while it is empty.
        func isDefault(passwordTyped: Bool = true) -> Bool {
            kind == .primary && pressable(passwordTyped: passwordTyped)
        }
    }

    /// Bottom-left, in order: **Back**, and anything that belongs with it.
    var leading: [Button] = []
    /// Bottom-right, in order; the last is the corner.
    var trailing: [Button] = []

    /// The corner's button, the step's way forward.
    var corner: Button? { trailing.last }

    /// Whether the footer holds the page's one filled button right now, so the page's own stands down
    /// (`stepPrimaryButton`).
    func holdsDefault(passwordTyped: Bool = true) -> Bool {
        (leading + trailing).contains { $0.isDefault(passwordTyped: passwordTyped) }
    }

    /// The footer for `state`. `stepAction` is what the step hands the footer: its main action while
    /// the step is still to be done (`stepAction(_:)`, which the tests replace to try the rule).
    ///
    /// While work runs, only what can be pressed: every greyed-out button went (Back, Check Again, a
    /// Continue, Save It), which left rows of them at about 1.6:1 that nothing could press until the
    /// work ended, beside the one thing that could — the page's **Stop Waiting**, in its card. Pure.
    static func footer(_ state: SetupWindowState,
                       stepAction: (SetupWindowState) -> Button? = SetupFooter.stepAction) -> SetupFooter {
        let footer = arranged(state, stepAction: stepAction)
        guard state.inFlight != nil else { return footer }
        return SetupFooter(leading: footer.leading.filter(\.enabled), trailing: footer.trailing.filter(\.enabled))
    }

    private static func arranged(_ state: SetupWindowState, stepAction: (SetupWindowState) -> Button?) -> SetupFooter {
        let idle = state.inFlight == nil
        let back = Button(SetupCopy.bBack, .back, enabled: backable(state))
        let handed = stepAction(state)
        switch state.step {
        case .welcome:
            return SetupFooter(trailing: [Button(SetupCopy.Welcome.bNotNow, .notNow, kind: .cancel),
                                          Button(SetupCopy.Welcome.bStart, .start, kind: .primary)])
        case .lookAround:
            let page = LookAroundPage.page(state)
            let secondary = page.secondary.map { Button($0.title, .perform($0.action), enabled: $0.enabled) }
            let primary = page.primary.map { Button($0.title, .perform($0.action), enabled: $0.enabled, kind: .primary) }
            return SetupFooter(leading: [back], trailing: [secondary, primary].compactMap { $0 })
        case .vm:
            // Check Again beside Back, not bottom-right: that corner is the way forward, and on this
            // step the way forward is the step's own (Use, Install Windows…, Start It, Continue), which its
            // page hands over (`SetupVMView.footerAction`) — Continue included, since only the page
            // knows whether the VM just chosen is the one an install made.
            let checkAgain = Button(SetupCopy.bCheckAgain, .perform(.run(.checkAgain(.vm))), enabled: idle)
            return SetupFooter(leading: [back, checkAgain], trailing: handed.map { [$0] } ?? [])
        case .finish:
            // Its own rules: a choice, a restart and an arrival, not a Continue (`SetupFinishPage`).
            return SetupFinishPage.footer(state)
        case .tune, .certificate, .savedPC, .connect:
            if state.finished {
                return SetupFooter(leading: [back], trailing: [Button(SetupCopy.bClose, .closeForNow, kind: .primary)])
            }
            let checkAgain = Button(SetupCopy.bCheckAgain, .perform(.run(.checkAgain(state.step))), enabled: idle)
                .when(SetupJourneyActions.footerChecksAgain(state))
            let satisfied = state.facts.map { SetupFlow.isSatisfied(state.step, $0) } == true
            if let handed, !satisfied {
                return SetupFooter(leading: [back], trailing: checkAgain + [handed])
            }
            // Continue Without Connecting skips the one step that proves the setup works, so it is
            // never the filled default; a greyed-out Continue isn't either (`Kind.primary`), so the
            // page's own default (Save It, the desktop question's Yes) gets Return.
            let skipsTheTest = state.step == .connect && state.facts?.answers.connected != true
            let next = Button(SetupCopy.journeyNext(state.step, facts: state.facts),
                              state.step == .finish ? .finish : .next,
                              enabled: idle && satisfied, kind: skipsTheTest ? .plain : .primary,
                              reason: satisfied ? nil : SetupCopy.notYetReason(state.step, facts: state.facts))
            // A failed Connect lets Ben move on, but its fix is the way forward: the fix takes the
            // corner, and moving on without the test waits beside Back, plain.
            if let handed, skipsTheTest {
                return SetupFooter(leading: [back, next], trailing: checkAgain + [handed])
            }
            return SetupFooter(leading: [back], trailing: checkAgain + [next])
        }
    }

    /// Whether **Back** can be pressed: with nothing running, or while only a read runs. A read is the
    /// one thing that can hold a page for minutes without anyone having pressed anything — a survey
    /// of Windows after a wake takes up to three — and it changes nothing a step decided: its snapshot
    /// never moves the window forward, and the window's answers win over the ones it carries
    /// (`SetupWindowState.landing`). Work that acts (an install, a Fix, the restart) keeps Back until it
    /// ends: going back from under it would leave its page while it's still doing what was asked. Pure.
    static func backable(_ state: SetupWindowState) -> Bool {
        state.inFlight == nil || state.inFlight?.work.isRead == true
    }

    /// The main action each step hands the footer while it is still to be done, or nil where the
    /// step's page keeps its own. Step 1's actions come from its page (`LookAroundPage`); step 2's
    /// from its own (`SetupVMView.footerAction`); steps 3 to 6 hand theirs from `SetupJourneyActions`.
    /// Pure.
    static func stepAction(_ state: SetupWindowState) -> Button? {
        if state.step == .vm { return SetupVMView.footerAction(state) }
        if let journey = SetupJourneyActions.footerAction(state) { return journey }
        return nil
    }
}

extension SetupFooter.Button {
    /// This button, or none: for a footer that draws a button only when a rule says so.
    func when(_ shown: Bool) -> [SetupFooter.Button] { shown ? [self] : [] }
}

/// The footer, drawn: its buttons at the window's one size, the corner's filled while it is the
/// default, in a band a shade apart from the page, as a Windows 11 dialog's footer is.
struct SetupFooterBar: View {
    let footer: SetupFooter
    /// Watched for **Save It**, which is pressable only once something is typed.
    @ObservedObject var credentials: SetupCredentials
    let savePassword: (String) -> Void
    let send: (SetupCommand) -> Void

    var body: some View {
        withSetupAppearance { look in
            SetupFooterBand {
                ForEach(Array(footer.leading.enumerated()), id: \.offset) { _, button in draw(button, look) }
                Spacer()
                ForEach(Array(footer.trailing.enumerated()), id: \.offset) { _, button in draw(button, look) }
            }
        }
    }

    @ViewBuilder private func draw(_ button: SetupFooter.Button, _ look: SetupAppearance) -> some View {
        let typed = !credentials.password.isEmpty
        if let reason = button.reason, !button.pressable(passwordTyped: typed) {
            Text(reason)
                .font(.system(size: SetupStyle.smallestText))
                .foregroundStyle(look.mutedText)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        let control = SwiftUI.Button(button.title) { press(button) }
            .disabled(!button.pressable(passwordTyped: typed))
        if button.isDefault(passwordTyped: typed) {
            control.primaryButton(look)
        } else if button.kind == .cancel {
            control.keyboardShortcut(.cancelAction)
        } else {
            control
        }
    }

    private func press(_ button: SetupFooter.Button) {
        switch button.press {
        case .send(let command):
            send(command)
        case .savePassword:
            // Handed over as the field's own Return does (`SetupJourneyView`), and forgotten by the
            // controller once the runner has taken it (`SetupWindowController.savePC(password:)`).
            guard !credentials.password.isEmpty else { return }
            savePassword(credentials.password)
        }
    }
}

/// The footer's band on its own: a row of buttons at the window's one size, in the page's column, a
/// shade apart from the page with a hairline above. `SetupFooterBar` draws the wizard's footer in it,
/// and the New Windows VM views draw their buttons in it while they are the wizard's step 2, so the
/// footer doesn't move when an install starts (it drew its own, 9 pt higher).
struct SetupFooterBand<Content: View>: View {
    private let content: Content

    init(@ViewBuilder _ content: () -> Content) { self.content = content() }

    var body: some View {
        withSetupAppearance { look in
            HStack(spacing: 10) { content }
                .controlSize(.large)
                // A large button's height, so a band with nothing to press while work runs keeps its
                // place rather than shrinking to a sliver and moving the page above it.
                .frame(minHeight: SetupStyle.largeButtonHeight)
                .frame(maxWidth: SetupStyle.contentWidth)
                .padding(.horizontal, SetupStyle.pagePadding)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity)
                .background {
                    ZStack(alignment: .top) {
                        look.palette.card.color.opacity(look.reduceTransparency ? 1 : 0.45)
                        Rectangle().fill(look.stroke).frame(height: look.increasedContrast ? 1.5 : 1)
                    }
                }
        }
    }
}
