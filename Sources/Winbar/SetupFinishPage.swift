import SwiftUI

// Step 7, Finish: one choice, one restart, and an arrival.
//
// The choice is two tiles side by side, the way a Mac setup assistant asks Light or Dark: one is
// already chosen (the recommended one), so the footer always has something to do, and its corner says
// what pressing it will do — **Restart and Finish** while a restart is owed, **Finish** otherwise. The
// review found the old page asking "Run it without a screen?" over two equal buttons, with no default
// and a greyed-out Done. Once finished, the page is an arrival like the welcome: a centred mark, a
// heading that says how it went, one sentence naming the VM, and the one thing to do next in the corner.
//
// The rules are here, as values, so the footer, the title and the tiles read one answer and the tests
// can read it without drawing.

enum SetupFinishPage {
    /// Which tile the page shows chosen.
    enum Choice: Equatable { case background, keepScreen }

    /// The tiles, with the chosen one, or nil where the page offers no choice (already in the
    /// background, Remote Desktop not proven, another VM running…). Offered but not yet staged counts
    /// as the background chosen: it is the recommendation, and the footer's **Restart and Finish** is
    /// what makes it so. Keep shows as chosen only where undoing it would offer the choice again, so
    /// a Keep pressed beside a refusal doesn't turn into tiles the refusal would then contradict. Pure.
    static func choice(_ facts: SetupFlow.Facts) -> Choice? {
        switch SetupFlow.headlessOffer(facts) {
        case .offer, .staged: return .background
        case .kept:
            var undone = facts
            undone.answers.leftAlone.remove("H5")
            switch SetupFlow.headlessOffer(undone) {
            case .offer, .staged: return .keepScreen
            default: return nil
            }
        default: return nil
        }
    }

    /// What the one restart will apply if the footer's corner is pressed now: what is staged, plus
    /// the background while it is only chosen. Empty: no restart. Pure.
    static func owed(_ facts: SetupFlow.Facts) -> ConfigChanges {
        var owed = facts.pending
        if SetupFlow.headlessOffer(facts) == .offer { owed.display = .headless }
        return owed
    }

    /// The page's title: the question while it asks one, the step's name otherwise, and none once
    /// finished, where the arrival heads itself (`FinishArrival`). Pure.
    static func title(_ state: SetupWindowState) -> String? {
        if state.finished { return nil }
        if let facts = state.facts, choice(facts) != nil { return SetupCopy.Finish.choiceHeading }
        return SetupCopy.stepName(.finish)
    }

    /// Whether the page's news is UTM's to re-read: a refusal because another VM runs, UTM not saying,
    /// or the question still being asked. Elsewhere on this step **Check Again** has nothing to change.
    static func checksAgain(_ offer: SetupFlow.HeadlessOffer) -> Bool {
        switch offer {
        case .otherVMsRunning, .couldNotConfirm, .notChecked, .checkOtherVMs: return true
        default: return false
        }
    }

    /// The footer. Finished: no **Back** — the step bar is full and the page says it's done — with
    /// **Close** for Escape and the next thing in the corner: **Open Windows** when the desktop
    /// appeared, **Try Connecting Again** when it didn't, and **Open the App Store** when there is no
    /// Windows App to open it with — the fix the page names, as the Saved PC step offers it, where a
    /// lone filled **Close** named the fix without offering it — with **Check Again** beside it for
    /// an install made another way (the window also looks by itself when it comes back,
    /// `SetupJourneyActions.returnRead`). Once Windows App is here after it was skipped, the saved PC
    /// was never set up and Connect never tried: **Go Back to Saved PC** in the corner, which leaves
    /// the finished page for the step the skip passed over, and **Connect** beside it to test the
    /// connection as it is. A finished page stays finished until one of these is pressed (a snapshot
    /// never moves it, `SetupWindowState.landing`). Before that, **Restart and Finish** or **Finish**.
    /// Pure.
    static func footer(_ state: SetupWindowState) -> SetupFooter {
        typealias Button = SetupFooter.Button
        let idle = state.inFlight == nil
        let close = Button(SetupCopy.bClose, .closeForNow, kind: .cancel)
        if state.finished {
            switch state.facts.map(SetupCopy.Finish.outcome) {
            case .connected?:
                return SetupFooter(trailing: [close, Button(SetupCopy.Finish.bOpenWindows, .openWindows, kind: .primary)])
            case .notConnected?:
                return SetupFooter(trailing: [close, Button(SetupCopy.Finish.bTryConnectingAgain, .connectAgain,
                                                            enabled: idle, kind: .primary)])
            case .notTried?:
                // Connect is the same press as Try Connecting Again, named for a first try: nothing has
                // failed to say "again" about. Go Back to Saved PC is the saved PC step's way back, with
                // its Skips taken back (`SetupCommand.revisit`); like Back, it is live while only a read
                // runs.
                return SetupFooter(trailing: [close, Button(SetupCopy.Finish.bConnect, .connectAgain, enabled: idle),
                                              Button(SetupCopy.Finish.bGoBackToSavedPC, .revisit(.savedPC),
                                                     enabled: SetupFooter.backable(state), kind: .primary)])
            case .windowsAppSkipped?:
                return SetupFooter(trailing: [close, Button(SetupCopy.bCheckAgain, .perform(.run(.checkAgain(.finish))),
                                                            enabled: idle),
                                              Button(SetupCopy.SavedPC.bOpenAppStore, .perform(.run(.installWindowsApp)),
                                                     enabled: idle, kind: .primary)])
            case nil:
                return SetupFooter(trailing: [Button(SetupCopy.bClose, .closeForNow, kind: .primary)])
            }
        }
        let back = Button(SetupCopy.bBack, .back, enabled: SetupFooter.backable(state))
        guard let facts = state.facts else {
            return SetupFooter(leading: [back], trailing: [Button(SetupCopy.Finish.bFinish, .finish, enabled: false, kind: .primary)])
        }
        let offer = SetupFlow.headlessOffer(facts)
        var trailing: [Button] = []
        if checksAgain(offer) {
            trailing.append(Button(SetupCopy.bCheckAgain, .perform(.run(.checkAgain(.finish))), enabled: idle))
        }
        if !owed(facts).isEmpty {
            // Not while UTM is still being asked whether the choice can be offered at all.
            let asking = offer == .notChecked || offer == .checkOtherVMs
            trailing.append(Button(SetupCopy.Finish.bRestartAndFinish, .restartAndFinish, enabled: idle && !asking,
                                   kind: .primary))
        } else {
            trailing.append(Button(SetupCopy.Finish.bFinish, .finish,
                                   enabled: idle && SetupFlow.isSatisfied(.finish, facts), kind: .primary))
        }
        return SetupFooter(leading: [back], trailing: trailing)
    }

    /// What the page adds when the last restart failed while the Mac slept: every wait in it runs by
    /// the clock, so the failure may have been nothing but the sleep (`SetupCopy.Working.slept`). nil
    /// otherwise. `SetupRunner.restartReport` said so and nothing drew it. Pure.
    static func restartNote(_ state: SetupWindowState) -> AttributedString? {
        guard let facts = state.facts, let ending = state.lastEnding,
              case .failed(_, slept: true) = SetupRunner.restartReport(inFlight: state.inFlight, last: ending, facts: facts)
        else { return nil }
        let restart = SetupRunner.InFlight(work: .applyChanges, started: ending.started, vm: facts.chosenVM)
        return SetupCopy.Working.slept(while: SetupCopy.Working.doing(restart))
    }

    /// Whether the VM has no screen of its own now (H5 reads ok: no display device), so the finished
    /// page says where its screen is (`SetupCopy.Finish.inBackground`). Pure.
    static func runsInBackground(_ facts: SetupFlow.Facts) -> Bool { facts.kind("H5") == .ok }

    /// A step the finished page lists as passed over.
    struct PassedOver: Equatable {
        var step: WizardStep
        /// What happened and why, in the step bar's hover words (`SetupCopy.passedOver`).
        var words: String
        /// The way back to the step, or nil where the footer's corner is already it.
        var back: Back?
    }

    struct Back: Equatable {
        var title: String
        var command: SetupCommand
    }

    /// Each step the finished page lists as passed over, in the bar's order: the ones its ⚠ marks, with
    /// the hover's words (`StepBar.passedOver`), and the way back to each. Empty until the window is
    /// finished, and when nothing was passed over, so no section is drawn. Pure.
    ///
    /// The certificate and the saved PC go back with their Skips taken back (`SetupCommand.revisit`,
    /// **Go Back to Certificate**, **Go Back to Saved PC**), leaving the finished page for the step on
    /// purpose. Connect has none: the footer's corner is already its way back (**Try Connecting
    /// Again**, **Connect**, or **Open the App Store** with Windows App skipped), and a second button
    /// for one press is one too many. For the same reason the saved PC has none once the footer's
    /// corner is **Go Back to Saved PC** (Windows App installed after it was skipped): two buttons of
    /// that name on one page, one of them filled.
    static func passedOver(_ state: SetupWindowState) -> [PassedOver] {
        guard state.finished else { return [] }
        let words = StepBar.passedOver(state)
        let footer = footer(state)
        return WizardStep.allCases.compactMap { step in
            guard let said = words[step] else { return nil }
            let revisit = SetupCommand.revisit(step)
            let inFooter = (footer.leading + footer.trailing).contains { $0.press == .send(revisit) }
            let back = SetupFlow.skips(in: step).isEmpty || inFooter
                ? nil : Back(title: SetupCopy.goBackTo(step), command: revisit)
            return PassedOver(step: step, words: said, back: back)
        }
    }

    /// Whether the last restart was tried and stopped, so the page says what is left
    /// (`SetupCopy.Finish.restartStopped`) — and only then. Pure.
    static func restartStopped(_ state: SetupWindowState) -> Bool {
        guard let ending = state.lastEnding, ending.work == .applyChanges else { return false }
        if case .failed = ending.outcome { return !(state.facts?.pending.isEmpty ?? true) }
        return false
    }
}

// MARK: - Drawn

/// The page before it's finished: the tiles, what else the step has to say, and the restart.
struct FinishChoiceView: View {
    let state: SetupWindowState
    let facts: SetupFlow.Facts
    let send: (SetupCommand) -> Void

    var body: some View {
        withSetupAppearance { look in
            VStack(alignment: .leading, spacing: 14) {
                let screen = SetupFlow.finish(facts)
                if let chosen = SetupFinishPage.choice(facts) {
                    HStack(alignment: .top, spacing: 12) {
                        FinishTile(symbol: "leaf", title: SetupCopy.Finish.bBackground, detail: SetupCopy.Finish.backgroundBody,
                                   recommended: true, chosen: chosen == .background) {
                            send(.chooseBackground(true))
                        }
                        FinishTile(symbol: "macwindow", title: SetupCopy.Finish.bKeepScreen, detail: SetupCopy.Finish.keepBody,
                                   recommended: false, chosen: chosen == .keepScreen) {
                            send(.chooseBackground(false))
                        }
                    }
                    Text(SetupCopy.markdown(SetupCopy.Finish.choiceRule))
                        .font(.system(size: SetupStyle.smallestText))
                        .foregroundStyle(look.mutedText)
                        .setupProse()
                } else {
                    notice(screen.headless)
                }
                let owed = SetupFinishPage.owed(facts)
                if !owed.isEmpty {
                    Callout(.info, symbol: "arrow.clockwise") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(verbatim: SetupCopy.Finish.restartLine(vm: screen.vm ?? "the VM", owed))
                            if SetupFinishPage.restartStopped(state) {
                                Text(SetupCopy.markdown(SetupCopy.Finish.restartStopped))
                            }
                            if let note = SetupFinishPage.restartNote(state) { Text(note) }
                            // Only when something is staged: a choice not yet staged is undone by the
                            // other tile, and a third way to say Keep would be one too many.
                            if !facts.pending.isEmpty {
                                Button(SetupCopy.Finish.bFinishWithoutRestarting) { send(.finishWithoutRestarting) }
                            }
                        }
                    }
                }
            }
        }
    }

    /// What the step says where it offers no choice.
    @ViewBuilder private func notice(_ offer: SetupFlow.HeadlessOffer) -> some View {
        switch offer {
        case .otherVMsRunning(let names):
            if let refusal = Reconfigure.otherVMsRefusal(facts.chosenVM ?? "the VM", changed: false, others: .success(names)) {
                SetupCard {
                    VStack(alignment: .leading, spacing: 10) {
                        SetupStatusLine(.attention, refusal.title)
                        Text(verbatim: refusal.detail)
                        Text(SetupCopy.markdown(SetupCopy.Finish.afterRefusal))
                    }
                }
            }
        case .couldNotConfirm(let reason):
            SetupCard {
                VStack(alignment: .leading, spacing: 10) {
                    SetupStatusLine(.attention, SetupCopy.Finish.couldNotConfirm)
                    Text(verbatim: reason)
                    Text(SetupCopy.markdown(SetupCopy.Finish.afterRefusal))
                }
            }
        case .alreadyHeadless:
            SetupStatusLine(.done, SetupCopy.Finish.alreadyInBackground)
        case .kept, .notReady:
            Text(offer == .kept ? SetupCopy.Finish.keepBody : SetupCopy.Finish.notReady).setupProse()
        case .notOffered, .connectSkipped, .waitingForConnect:
            Text(SetupCopy.markdown(SetupCopy.Finish.notOffering)).setupProse()
        case .notChecked, .checkOtherVMs:
            SetupStatusLine(.running, SetupCopy.Finish.checking)
        case .offer, .staged:
            EmptyView()
        }
    }
}

/// One of the two choices: a card with its symbol, its name, what it means, and a radio mark, with
/// the accent round the one chosen. The whole tile is the button, as a System Settings appearance
/// swatch is.
struct FinishTile: View {
    let symbol: String
    let title: String
    let detail: String
    let recommended: Bool
    let chosen: Bool
    let choose: () -> Void

    var body: some View {
        withSetupAppearance { look in
            let shape = RoundedRectangle(cornerRadius: SetupStyle.cardRadius, style: .continuous)
            Button(action: choose) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .center) {
                        Image(systemName: symbol)
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(look.accentText)
                            .frame(height: 24)
                            .accessibilityHidden(true)
                        if recommended {
                            Text(SetupCopy.Finish.recommended)
                                .font(.system(size: SetupStyle.smallestText, weight: .semibold))
                                .foregroundStyle(look.accentText)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(look.accentText.opacity(0.1)))
                        }
                        Spacer(minLength: 4)
                        Image(systemName: chosen ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 18))
                            .foregroundStyle(chosen ? look.accentFill : look.mutedText)
                            .accessibilityHidden(true)
                    }
                    Text(title).font(.system(size: 14, weight: .semibold))
                    Text(detail)
                        .font(.system(size: 13))
                        .foregroundStyle(look.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .contentShape(shape)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background {
                ZStack {
                    if !look.reduceTransparency { shape.fill(.regularMaterial) }
                    shape.fill(look.palette.card.color.opacity(look.reduceTransparency ? 1 : look.palette.cardOpacity))
                    if chosen { shape.fill(look.accentText.opacity(0.06)) }
                }
            }
            .overlay {
                shape.strokeBorder(chosen ? look.accentFill : look.stroke,
                                   lineWidth: chosen ? 2 : (look.increasedContrast ? 1.5 : 1))
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(recommended ? "\(title), \(SetupCopy.Finish.recommended)" : title)
            .accessibilityHint(detail)
            .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
        }
    }
}

/// The finished page: the welcome's composition, as its closing bookend. The mark carries how it
/// went (a green tick, or the attention triangle while Connect is still to prove), the heading says
/// it in words, and the corner of the footer holds the one next thing (`SetupFinishPage.footer`).
/// Where Armie is (`ArmieCue`), he is the mark, at the welcome's size, with the tick or the triangle
/// on his corner: hopping once and signing off after **Yes**, concerned after **No**.
struct FinishArrival: View {
    let facts: SetupFlow.Facts
    /// The steps passed over, listed under the result (`SetupFinishPage.passedOver`).
    var passedOver: [SetupFinishPage.PassedOver] = []
    var armie: ArmieCue? = nil
    var art: ArmieArt? = nil
    let send: (SetupCommand) -> Void

    /// The heading's size: macOS's `.largeTitle`, a step up from the other pages' 24 pt, as an
    /// arrival's is in Apple's assistants.
    static let headingSize: CGFloat = 26

    var body: some View {
        withSetupAppearance { look in
            let outcome = SetupCopy.Finish.outcome(facts)
            let lines = SetupCopy.Finish.doneBody(vm: facts.chosenVM ?? "the VM", outcome,
                                                  canReopenFromMenu: SetupWindow.availableToEveryone)
            VStack(spacing: 18) {
                let status: StatusMark.Status = outcome == .connected ? .done : .attention
                if let armie, let art {
                    HStack(alignment: .center, spacing: 6) {
                        FinishMark(status: status, armie: (art, armie.pose))
                        if let line = armie.line {
                            ArmieBubble(line: line, tail: .leading, send: send)
                                .frame(maxWidth: ArmieSays.heroBubble, alignment: .leading)
                                // Read after the page's own words: the point is those, and he only agrees.
                                .accessibilitySortPriority(-1)
                        }
                    }
                } else {
                    FinishMark(status: status)
                }
                VStack(spacing: 10) {
                    Text(SetupCopy.Finish.heading(outcome))
                        .font(.system(size: Self.headingSize, weight: .bold))
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                    Text(lines[0])
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 440)
                }
                if SetupFinishPage.runsInBackground(facts) {
                    Text(SetupCopy.markdown(SetupCopy.Finish.inBackground))
                        .font(.system(size: SetupStyle.smallestText))
                        .foregroundStyle(look.mutedText)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 400)
                }
                if lines.count > 1 {
                    Text(lines[1])
                        .font(.system(size: SetupStyle.smallestText))
                        .foregroundStyle(look.mutedText)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 400)
                }
                FinishPassedOver(rows: passedOver, send: send)
                // Where everything after setup lives, pointed at once per Mac, and on Show Me (MenuBarIntro).
                MenuBarIntroRow()
                // So the menu bar icon is still there after a restart: on for a fresh setup (LaunchAtLogin).
                // Under it, off until pressed, whether Windows starts with it (StartWindowsAtLaunch). One
                // column, so the two boxes line up.
                VStack(alignment: .leading, spacing: 14) {
                    LaunchAtLoginToggle()
                    StartWindowsToggle(vm: facts.chosenVM ?? "the VM")
                }
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .contain)
        }
    }
}

/// The finished page's quiet list of what was passed over (`SetupFinishPage.passedOver`), under the
/// result: per step, the ⚠ mark the step bar has, the step's name, what happened and why in the bar's
/// own hover words, and the way back where there is one. Nothing passed over, nothing drawn. The owner
/// found an orange ⚠ on this page with nothing to say what it was.
struct FinishPassedOver: View {
    let rows: [SetupFinishPage.PassedOver]
    let send: (SetupCommand) -> Void

    var body: some View {
        if !rows.isEmpty {
            withSetupAppearance { look in
                VStack(alignment: .leading, spacing: 12) {
                    Text(SetupCopy.Finish.passedOverHeading)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(look.mutedText)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(rows, id: \.step) { row in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            StatusMark(.attention)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(SetupCopy.stepName(row.step)).font(.system(size: 13, weight: .semibold))
                                Text(SetupCopy.Finish.passedOverLine(row.words))
                                    .font(.system(size: 13))
                                    .foregroundStyle(look.mutedText)
                                    .fixedSize(horizontal: false, vertical: true)
                                if let back = row.back {
                                    Button(back.title) { send(back.command) }.padding(.top, 2)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: SetupStyle.textWidth, alignment: .leading)
            }
        }
    }
}

/// Winbar's mark with how the setup went on its corner, like a badge on an app icon — or Armie in its
/// place, at his larger size, the badge on the corner of his square, clear of him.
struct FinishMark: View {
    let status: StatusMark.Status
    /// His art and pose, where he stands in for the mark (`FinishArrival`).
    var armie: (art: ArmieArt, pose: ArmieArt.Pose)? = nil
    static let size: CGFloat = 72

    var body: some View {
        withSetupAppearance { look in
            let size = armie == nil ? Self.size : ArmieSays.hero
            ZStack(alignment: .bottomTrailing) {
                if let armie {
                    ArmieFigure(art: armie.art, pose: armie.pose, size: size)
                } else {
                    WinbarMark(size: size)
                }
                ZStack {
                    Circle().fill(look.palette.backdropBottom.color).frame(width: 30, height: 30)
                    Image(systemName: status.symbol ?? "circle")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(status == .done ? look.success : look.attention)
                }
                // Over the mark's corner; clear of Armie's pins, in the transparent corner of his square,
                // since nothing may cover or cut any of him.
                .offset(x: armie == nil ? 9 : 20, y: armie == nil ? 7 : 14)
            }
            .frame(width: size + (armie == nil ? 12 : 22), height: size + (armie == nil ? 10 : 16))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(status.label(pending: ""))
        }
    }
}
