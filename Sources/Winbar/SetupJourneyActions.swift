import AppKit

// Steps 3 to 6 — Tune, the certificate, the saved PC and Connect — as the footer and the window see
// them: which main action each hands the footer's corner, when the footer's Check Again has nothing
// to add, and which look coming back to the window takes (every step's, `returnRead`). Pure, from the
// window's state, so the rules are tested without drawing; `SetupFooter` and `SetupWindowController`
// call in.
//
// The Finish step keeps the footer's own behaviour: it isn't decided here.

enum SetupJourneyActions {
    /// The steps these rules cover.
    static let steps: Set<WizardStep> = [.tune, .certificate, .savedPC, .connect]

    /// The main action a step hands the footer's bottom-right corner while the step is still to be
    /// done (`SetupFooter.stepAction`): the corner is where the way forward is on every step, as on
    /// Welcome and Look around, and a card's own button there sat mid-page. Nil where the step's
    /// next move isn't one button: a question with two answers (did the desktop appear?), or a step
    /// that is done (the footer's Continue takes the corner then). Greyed out while work runs, unless
    /// it isn't the runner's work (`elsewhere`). Pure.
    static func footerAction(_ state: SetupWindowState) -> SetupFooter.Button? {
        guard steps.contains(state.step), let facts = state.facts else { return nil }
        let idle = state.inFlight == nil
        func primary(_ title: String, _ command: SetupCommand) -> SetupFooter.Button {
            SetupFooter.Button(title, command, enabled: idle, kind: .primary)
        }
        let checkAgain = primary(SetupCopy.bCheckAgain, .perform(.run(.checkAgain(state.step))))
        // A button that isn't the runner's work — it quits another app, or takes Ben to one — can't
        // collide with a read, so it stays live through one: a read nobody pressed doesn't take away
        // the button the page is waiting on.
        func elsewhere(_ title: String, _ command: SetupCommand) -> SetupFooter.Button {
            SetupFooter.Button(title, command, kind: .primary)
        }
        switch state.step {
        case .tune:
            let screen = SetupFlow.tune(facts)
            if !screen.unread.isEmpty { return primary(SetupCopy.bCheckAgain, .perform(.run(.survey))) }
            if !screen.fixEverything.isEmpty { return primary(SetupCopy.Tune.bFixEverything, .perform(.run(.fixEverything))) }
            return tuneRowInCorner(facts).map { primary($0.action.title, $0.action.command) }
        case .certificate:
            switch SetupCertificatePage.page(state, facts: facts).next {
            case .approve(let title): return primary(title, .perform(.run(.trustCertificate)))
            case .checkAgain: return checkAgain
            // Made on the Tune step: the way on is back there, filled and on Return, as the VM step's
            // **Go Back to Look Around** is. A card naming **Back** over a footer with nothing filled
            // left Return doing nothing.
            case .goBack: return primary(SetupCopy.Certificate.bGoBack, .back)
            case .none: return nil
            }
        case .savedPC:
            switch SetupFlow.savedPC(facts) {
            case .needsWindowsApp(.wrongSignature): return nil
            case .needsWindowsApp: return primary(SetupCopy.SavedPC.bOpenAppStore, .perform(.run(.installWindowsApp)))
            case .windowsAppOpen: return elsewhere(SetupCopy.SavedPC.bQuitWindowsApp, .quitWindowsApp)
            case .save: return SetupFooter.Button(SetupCopy.SavedPC.bSaveIt, .savePassword, enabled: idle, kind: .primary,
                                                  reason: SetupCopy.SavedPC.typeFirst)
            case .manual: return primary(SetupCopy.SavedPC.bContinueToSignIn, .continueWithoutSavedPC)
            case .notYet:
                return SetupCopy.SavedPC.notYet(host: facts.rdpHost, user: facts.rdpUser).showsWindowsScreen
                    ? elsewhere(SetupCopy.SavedPC.bShowWindowsScreen, .open(.windowsScreen)) : checkAgain
            case .saved, .skipped: return nil
            }
        case .connect:
            switch SetupFlow.connect(facts) {
            case .allowAccessibility: return primary(SetupCopy.Connecting.bAllowAccessibility, .perform(.run(.guide(checkID: "C3"))))
            case .ready: return primary(SetupCopy.Connecting.bConnect, .perform(.run(.connect)))
            case .notYet: return checkAgain
            // The diagnosis' own action, in the corner every other step keeps its action in: the
            // setting first where macOS refused the check (a retry would only be refused again),
            // otherwise the retry its steps name. The corner held Continue Without Connecting, so on
            // the step that proves the setup works the corner was the skip.
            case .didNotWork(let diagnosis):
                let recovery = SetupCopy.Connecting.recovery(diagnosis)
                if recovery.opensLocalNetwork {
                    return elsewhere(SetupCopy.Connecting.bOpenLocalNetworkSettings, .open(.localNetworkSettings))
                }
                return primary(recovery.retry.title, recovery.retry.command)
            case .didItWork, .worked, .needsWindowsApp, .windowsAppSkipped: return nil
            }
        default:
            return nil
        }
    }

    /// The Tune step's corner when nothing is left for **Fix Everything** or a read and a setting
    /// needs Ben's own hands: the first such row's first button (**Open Time Machine Settings…**, or
    /// **I've Done It** where Winbar can't open the place). The headline says "follow its steps"; the
    /// corner held a greyed-out Continue and the first step was a plain button in the row, so the
    /// page had nothing filled and Return did nothing. The row draws its other buttons, not this one
    /// again (`SetupJourneyView`). Pure.
    static func tuneRowInCorner(_ facts: SetupFlow.Facts) -> (rowID: String, action: SetupTuneRowActions.Action)? {
        let screen = SetupFlow.tune(facts)
        guard screen.unread.isEmpty, screen.fixEverything.isEmpty,
              let row = SetupTuneGroups(facts).needsYou.first(where: { $0.kind == .manual }),
              let first = SetupTuneRowActions.of(row, facts: facts).first else { return nil }
        return (row.id, first)
    }

    /// Whether the footer draws its plain **Check Again** beside the corner. Not once the step is
    /// done, where there is nothing left to read for — except Tune, whose rows are settings in
    /// Windows that can change behind its back and are never read again by themselves (Tune takes no
    /// look on return, `returnRead`), so a person who wants a fresh look has a button for it; not
    /// where the corner is itself Check Again; and not where the card has a retry of its own (a
    /// failed Connect's, a row Windows didn't answer for, the saved PC's **Try Again**), which left
    /// two retry buttons with different verbs. The Finish step, and the steps before these, keep it.
    /// Pure.
    static func footerChecksAgain(_ state: SetupWindowState) -> Bool {
        guard steps.contains(state.step), let facts = state.facts else { return true }
        if SetupFlow.isSatisfied(state.step, facts), state.step != .tune { return false }
        if footerAction(state)?.press == .send(.perform(.run(.checkAgain(state.step)))) { return false }
        if footerAction(state)?.press == .send(.perform(.run(.survey))) { return false }
        switch state.step {
        case .tune:
            return !SetupTuneGroups(facts).needsYou.contains { $0.kind == .error }
        case .savedPC:
            if case .manual = SetupFlow.savedPC(facts) { return false }
            return true
        case .connect:
            // The card asks a question with two answers; a re-read under it only blanks the card.
            if case .didItWork = SetupFlow.connect(facts) { return false }
            return true
        default:
            return true
        }
    }

    /// The look the window takes when it becomes key again (`SetupWindowController.windowDidBecomeKey`),
    /// or nil for none: only where the step waits on something Ben does in another app — an install
    /// from UTM's site or the App Store (Windows App's, skipped or not), a switch in System Settings, a VM
    /// made in UTM, a sign-in on Windows' own screen, Windows App quit, another VM stopped in UTM — so
    /// that coming back says what changed without a **Check Again**. Everywhere else the page keeps the
    /// answer it has, and its **Check Again** (or a row's **I've Done It**) is the re-check. Winbar
    /// coming to the front used to re-read every step so far, so a done page went back to Checking…
    /// each time it was looked at.
    ///
    /// Each look forgets only what that other app can have changed (`SetupRunner.Forget`): a look for
    /// Accessibility runs the self-test and not Windows App's command line, a look for a sign-in
    /// surveys Windows and nothing else, and most read what is read live on every snapshot anyway.
    ///
    /// Never where a read would pull the page from under him: the password field, or the question
    /// about the desktop he has come back to answer. Never while anything runs, while the install's
    /// views are step 2, or while the look after an install is still owed. Tune never looks: its
    /// manual rows each have **I've Done It**, which reads that row again, and the footer keeps
    /// **Check Again**. The certificate looks only at an approval's own read-back that said "not
    /// verified" (`SetupCertificatePage.awaitsLook`); with **Approve Certificate…** or **Try Approval
    /// Again…** waiting, pressing it is the way on, and the look is not taken before it anyway (the
    /// window waits a moment, and any press or click wins). Pure.
    static func returnRead(_ state: SetupWindowState) -> SetupRunner.Work? {
        guard state.inFlight == nil, !state.creating, state.afterInstall == nil, let facts = state.facts else { return nil }
        func look(_ forget: SetupRunner.Forget) -> SetupRunner.Work { .lookAgain(state.step, forgetting: forget) }
        switch state.step {
        case .welcome, .tune:
            return nil
        case .lookAround:
            switch SetupFlow.lookAround(facts) {
            // H1 is read on every snapshot: an install or a replacement in the Finder shows at once.
            case .needsUTM: return look(.statuses)
            // utmctl asked again (`SetupRunner.reasksUTM`): the switch, or macOS's prompt, answered.
            case .utmSilent, .utmDenied: return look(.utm)
            case .listFailed(let failure) where failure.automationDenied: return look(.utm)
            case .askUTM, .utmFailed, .listVMs, .listFailed, .done: return nil
            }
        case .vm:
            // A VM made in UTM itself.
            if case .choose = SetupFlow.vm(facts) { return look(.utm) }
            return nil
        case .certificate:
            return SetupCertificatePage.awaitsLook(state) ? look(.statuses) : nil
        case .savedPC:
            switch SetupFlow.savedPC(facts) {
            // Windows App's bundle is read on every snapshot. Installed since, this look makes the
            // step's first saved-PC lookup, the one `--script` a look runs (`SetupRunner.Forget`).
            case .needsWindowsApp: return look(.statuses)
            // Whether it is open is read on every snapshot too (a process scan), and C2 is worked out
            // again from the lookup already made: no `--script` on the way back (`SetupRunner.Forget`).
            case .windowsAppOpen: return look(.statuses)
            case .notYet:
                // Signed in on Windows' screen: the survey says who.
                return SetupCopy.SavedPC.notYet(host: facts.rdpHost, user: facts.rdpUser).showsWindowsScreen
                    ? look(.guest) : nil
            // Windows App skipped, and the card says it isn't on this Mac yet: installed from the App
            // Store after all, the look finds its bundle (read on every snapshot) and the card stops
            // saying so, and makes the first saved-PC lookup (`SetupRunner.Forget`). Only with Windows
            // App skipped; the plain "Saved PC skipped" stands.
            case .skipped: return SetupFlow.windowsAppSkipped(facts) ? look(.statuses) : nil
            // Not the card that says Windows App's command line isn't responding, even with Windows App
            // opened from it to save the PC by hand: the one read that could see that PC is the command
            // line itself, which is what isn't answering, and a look never runs it again: the lookup
            // that failed is the one it works from (`SetupRunner.Forget`). **I've Saved the
            // PC** is the way on.
            case .save, .saved, .manual: return nil
            }
        case .connect:
            switch SetupFlow.connect(facts) {
            case .allowAccessibility: return look(.selfTest)
            // The port is probed on every snapshot once Connect was pressed.
            case .didNotWork(let diagnosis) where diagnosis.readiness == .blocked: return look(.statuses)
            default: return nil
            }
        case .finish:
            if state.finished {
                // Windows App installed from the App Store after all: the page's fix, and its Connect.
                // Like the saved-PC step's, this look makes the first saved-PC lookup (`SetupRunner.Forget`).
                return SetupCopy.Finish.outcome(facts) == .windowsAppSkipped ? look(.statuses) : nil
            }
            // Another VM stopped in UTM: asked of UTM on every snapshot at this step.
            if case .otherVMsRunning = SetupFlow.headlessOffer(facts) { return look(.statuses) }
            return nil
        }
    }

    /// Whether coming back to the window takes a look (`returnRead`). Pure.
    static func rechecksOnReturn(_ state: SetupWindowState) -> Bool { returnRead(state) != nil }

    /// Whether the step's own card says what is running, so the page's general spinner and line above
    /// it would only say it twice (a large spinner and "Saving the PC in Windows App…" over a card
    /// saying the same).
    static func cardShowsWork(_ state: SetupWindowState) -> Bool {
        steps.contains(state.step) && state.facts != nil
    }

    /// What the page says about work in flight, as a sentence: whom it waits on, the runner's own
    /// progress line, or what the work is.
    static func busyLine(_ flight: SetupRunner.InFlight) -> String {
        flight.waitingFor.map { SetupCopy.Working.waiting($0, host: "Winbar") }
            ?? flight.line ?? SetupCopy.Working.sentence(SetupCopy.Working.doing(flight))
    }
}

/// Somewhere outside the window a step's button takes Ben (`SetupCommand.open`).
enum SetupPlace: Equatable {
    /// System Settings › Privacy & Security › Local Network, where Winbar's switch is.
    case localNetworkSettings
    /// UTM, where the VM's window shows Windows' own screen, to sign in to Windows.
    case windowsScreen

    var settingsURL: String? {
        switch self {
        case .localNetworkSettings: return "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork"
        case .windowsScreen: return nil
        }
    }

    /// Goes there. Only the window's controller calls this, from a press.
    func open() {
        if let settingsURL, let url = URL(string: settingsURL) {
            NSWorkspace.shared.open(url)
        } else if self == .windowsScreen {
            UTM.open()
        }
    }
}
