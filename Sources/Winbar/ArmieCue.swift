import CoreGraphics

// MARK: - Where Armie is, and what he says there

/// Armie on one screen: the pose he stands in and what he says, if anything. Every placement is
/// decided here, from the state the screen is drawn from, so gui-wizard.md §2b's rules are kept in one
/// place rather than once per view. Pure.
///
/// The rule (the owner's, 2026-09-24, with Astra's for her poses):
///
/// - **On every page, quietly.** A small figure beside each page's title (`SetupPageHead`), a larger
///   one on the welcome and the finished page (`WelcomeView`, `FinishArrival`), and a small one in the
///   menu bar icon's popover (`popover`). He says something only where it is one dry fact the page
///   doesn't: most pages he stands on without a word.
/// - **Silent beside a permission, a password field or a question.** macOS's prompts and the pages
///   that predict them, the saved PC's password, the create form, which VM, Decrypt C:, Run in the
///   Background or Keep the Screen, whether the desktop appeared, and Connect while it runs (its
///   probe is what raises Local Network's): the figure alone, standing still. Nothing cute stands next
///   to those, and nothing moves while macOS asks.
/// - **The working loop only while Winbar works on that page**: an install, a start, a fix, a save, a
///   read somebody pressed or a step arrived at. Never while idle, and never for a read
///   nobody pressed (the look on coming back, a wake), which keeps him as he was, as the page keeps
///   its card: a figure that fidgeted each time the window was clicked into would be animating for
///   the sake of it.
/// - **The hop once, when a step has just been done**: a press's work, or Connect's Yes, turning the
///   page's step done well (`doneWell`) while it is on screen, and **Finish** bringing the finished
///   page after a Yes. Not for a read, a refresh, a skip, or the window coming back
///   (`SetupWindowState.armieHop`).
/// - **Concern beside what went wrong**: a failure card, a stall, an install's message that asks for
///   help or says something didn't work, a start that timed out, a VM UTM no longer has, a certificate
///   that didn't verify, a connection that didn't work. Still and silent,
///   never the hop and never the loop, even while a retry runs under the failure. Not beside a step's
///   ordinary to-do (UTM to install, a setting that needs Ben): that is the way through, not trouble,
///   and a worried face on it would read as a warning. Nor beside a permission refused, which is the
///   person's answer and is only asked again.
/// - **Apart from Send This to the Developer.** A card with the beta's button (`BetaReport.cards`,
///   `CreateJobView.offersReport`) is a failure, and the button is the page's way to ask for help, so
///   beside it he is concern and nothing else (`besideReport`): silent, so no bubble of his takes room
///   near the card, and still, so nothing moves by the one thing on the page to read. He stands beside
///   the page's title in the column its measure leaves free (`SetupPageHead`), or as the finished
///   page's mark over it, never in the card where the button is, and never points at it: sending is
///   the person's own choice. Decided with the beta's switch on whatever it is, since the card is a
///   failure with or without its button.
/// - **Pointing only at a target on screen on that side**, named in words beside him, and never to
///   hurry a permission, a password or anything that can't be undone. In this window nothing he could
///   point at sits beside him (the way on is the footer, below), so only the popover points: at the
///   icon it hangs from, from where the two were laid out (`popover`).
///
/// Hide Armie ends all of it, for good.
struct ArmieCue: Equatable {
    var pose: ArmieArt.Pose
    /// What he says, in his bubble; nil is silent, the figure alone.
    var line: String?

    init(pose: ArmieArt.Pose, line: String? = nil) {
        self.pose = pose
        self.line = line
    }

    /// Standing still, saying nothing.
    static let quiet = ArmieCue(pose: .rest)
    static let concerned = ArmieCue(pose: .concerned)
    static let working = ArmieCue(pose: .working)

    /// Where he is on the window's own pages, or nil where he isn't: hidden, or while the New Windows
    /// VM views are step 2's body, which place him themselves (`form`, `installing(_:)`).
    static func cue(_ state: SetupWindowState) -> ArmieCue? {
        guard !state.armieHidden, !state.creating else { return nil }
        if let beside = besideReport(state) { return beside }
        switch state.step {
        // A cover: he introduces himself, since every page after it has him on it.
        case .welcome: return ArmieCue(pose: .rest, line: SetupCopy.Armie.line(.welcome))
        case .lookAround: return lookAround(state)
        case .vm: return vm(state)
        case .tune, .certificate, .savedPC, .connect: return journey(state)
        case .finish: return state.finished ? finished(state) : journey(state)
        }
    }

    /// Beside a card with **Send This to the Developer**, before anything the step would otherwise
    /// say: concern, still and silent, even with the step's facts not read yet (a start that failed
    /// before the first read has its card and nothing else) or a retry running under it. The one card
    /// that isn't trouble is UTM's list refused at macOS's Automation prompt: that is the person's
    /// answer, and he stands by a refused permission without a word, as everywhere else. nil where
    /// the page has no such card. Pure.
    static func besideReport(_ state: SetupWindowState) -> ArmieCue? {
        let cards = BetaReport.cards(state, enabled: true)
        guard !cards.isEmpty else { return nil }
        if cards == [.lookAround], let facts = state.facts, case .listFailed(let failure) = SetupFlow.lookAround(facts),
           failure.automationDenied {
            return .quiet
        }
        return .concerned
    }

    /// The page's own work running: the loop, or — while it waits on the person at macOS's prompt —
    /// standing still. nil when nothing runs, or only a read nobody pressed.
    private static func busy(_ state: SetupWindowState) -> ArmieCue? {
        guard let flight = state.inFlight, !state.refreshing else { return nil }
        return standsStill(through: flight) ? .quiet : .working
    }

    /// Whether work in flight can put a prompt in front of the person, so he stands still through it
    /// rather than looping beside it. The work that waits on one by name (`waitingFor`: the
    /// certificate's approval, the Automation prompt), and Connect: its first act is probing the
    /// Remote Desktop port, which is what raises macOS's Local Network prompt (`SetupRunner.readPlan`),
    /// and then Windows App can ask the person to sign in. Connect isn't given a `Waiting` of its own
    /// for this: that would put "Waiting for you…" on its page before anything has asked. Pure.
    static func standsStill(through flight: SetupRunner.InFlight) -> Bool {
        flight.waitingFor != nil || flight.work == .connect
    }

    /// The hop, while `step` is the one just done (`SetupWindowState.armieHop`).
    private static func hop(_ state: SetupWindowState, _ step: WizardStep) -> ArmieCue? {
        state.armieHop == step ? ArmieCue(pose: .done) : nil
    }

    /// Whether `step` is done by what it is for — UTM answering with its list, the VM ready, Windows
    /// tuned, the certificate trusted, the PC saved, the desktop seen — rather than skipped or passed
    /// over: what earns the hop. Never the welcome, and never the Finish step, whose finished page is
    /// arrived at by the **Finish** press rather than by work, and earns its hop there. Pure.
    static func doneWell(_ step: WizardStep, _ facts: SetupFlow.Facts) -> Bool {
        switch step {
        case .welcome, .finish: return false
        case .lookAround: if case .done = SetupFlow.lookAround(facts) { return true }
        case .vm: if case .ready = SetupFlow.vm(facts) { return true }
        case .tune: return SetupFlow.isSatisfied(.tune, facts)
        case .certificate: return facts.kind("H7") == .ok
        case .savedPC: if case .saved = SetupFlow.savedPC(facts) { return true }
        case .connect: return SetupFlow.connect(facts) == .worked
        }
        return false
    }

    // MARK: Step 1

    /// UTM's install says his one line for it. An update stands still without a word, as the embedded
    /// install does at its Automation prompt: the update page predicts up to three of macOS's prompts
    /// part way through it (`SetupCopy.LookAround.updateMayAsk`) — Automation as Homebrew quits UTM,
    /// App Management as it replaces the bundle, Gatekeeper as it opens the new copy — and nothing
    /// moves while macOS asks. The install's failure, a UTM that isn't the real thing, one that
    /// answered with an error and a list that failed are trouble; everything else on this step is a
    /// permission macOS asks, or predicted, or refused, and he stands by it without a word.
    private static func lookAround(_ state: SetupWindowState) -> ArmieCue {
        if state.inFlight?.work == .installUTM {
            guard let facts = state.facts else { return .working }
            if LookAroundPage.installsUpdate(facts) { return .quiet }
            return ArmieCue(pose: .working, line: SetupCopy.Armie.line(.installingUTM))
        }
        let page = LookAroundPage.page(state)
        switch page.card {
        case .installFailed, .utmFailed:
            return .concerned
        case .needsUTM:
            if let facts = state.facts, case .needsUTM(.wrongSignature) = SetupFlow.lookAround(facts) { return .concerned }
        case .listFailed:
            if let facts = state.facts, case .listFailed(let failure) = SetupFlow.lookAround(facts),
               !failure.automationDenied { return .concerned }
        default:
            break
        }
        if let busy = busy(state) { return busy }
        if page.card == .none, let facts = state.facts, doneWell(.lookAround, facts) {
            return hop(state, .lookAround) ?? .quiet
        }
        return .quiet
    }

    // MARK: Step 2

    /// The empty state before any VM exists says why Arm, and the wait after **Start It** how the wait
    /// feels; both only on the step's own page. A VM gone from UTM, a failed piece of work and the
    /// install's warnings (the notes that silenced him during the install, shown here in full as
    /// cards) are trouble. Which VM, and Use or Start It, are the person's to press.
    private static func vm(_ state: SetupWindowState) -> ArmieCue {
        if state.afterInstall != nil { return .working } // "Looking at the new VM…"
        guard let facts = state.facts else { return busy(state) ?? .quiet }
        if state.standingFailure != nil || state.installMessages.contains(where: { SetupCopy.Armie.silences($0.code) }) {
            return .concerned
        }
        let screen = SetupVMView.screen(state, facts)
        if case .choose(_, previous: .some) = screen { return .concerned }
        if let flight = state.inFlight, !state.refreshing, case .startVM = flight.work {
            // `Setup.waitForWindows` says `agentNotYet` when its three minutes run out, and nothing after
            // it; the window keeps the run's lines, so either place can hold it — the flight's newest
            // line, or the kept lines of a window that was reopened part way.
            let timedOut = flight.line == SetupCopy.agentNotYet || state.lines.contains(SetupCopy.agentNotYet)
            return SetupCopy.Armie.startingLine(timedOut: timedOut).map { ArmieCue(pose: .working, line: $0) } ?? .concerned
        }
        if let busy = busy(state) { return busy }
        switch screen {
        case .choose(.none, previous: nil):
            return ArmieCue(pose: .rest, line: SetupCopy.Armie.line(.noVM))
        case .installing:
            // An install running elsewhere (the menu's, or Terminal's): work Winbar is doing.
            return .working
        case .ready:
            return hop(state, .vm) ?? .quiet
        default:
            return .quiet
        }
    }

    // MARK: Steps 3 to 7

    /// Tune, the certificate, the saved PC, Connect, and Finish before it's finished: a failure card
    /// first (`SetupJourneyView.problemCard`), then work running, then what the step's card says.
    private static func journey(_ state: SetupWindowState) -> ArmieCue {
        guard let facts = state.facts else { return busy(state) ?? .quiet }
        if SetupJourneyView.problemCard(state) != nil { return .concerned }
        if let busy = busy(state) { return busy }
        switch state.step {
        case .tune: return tune(state, facts)
        case .certificate: return certificate(state, facts)
        case .savedPC: return savedPC(state, facts)
        case .connect: return connect(state, facts)
        default: return finishChoice(facts)
        }
    }

    /// Settings that need Ben get his one line about what tuning is; a row Windows didn't answer for,
    /// or a Fix that didn't work, is trouble; BitLocker's question is a question.
    private static func tune(_ state: SetupWindowState, _ facts: SetupFlow.Facts) -> ArmieCue {
        switch SetupTuneHeadline.of(facts) {
        case .unchecked:
            return .concerned
        case .needsYou:
            if SetupTuneGroups(facts).needsYou.contains(where: { $0.kind == .error || $0.failure != nil }) {
                return .concerned
            }
            if SetupFlow.bitLockerQuestion(facts) != nil { return .quiet }
            return ArmieCue(pose: .rest, line: SetupCopy.Armie.line(.tuning))
        case .tuned:
            return hop(state, .tune) ?? .quiet
        case .notAsked, .working:
            return .quiet
        }
    }

    /// Approving is macOS's password dialog, so he stands by it without a word. A request that failed,
    /// one that finished without a trust Winbar can see, and a name Windows has no certificate for are
    /// trouble; a Stop Waiting (the person's own press) and a certificate not read yet aren't.
    private static func certificate(_ state: SetupWindowState, _ facts: SetupFlow.Facts) -> ArmieCue {
        let page = SetupCertificatePage.page(state, facts: facts)
        switch page.phase {
        case .verified:
            return hop(state, .certificate) ?? .quiet
        case .attention:
            if let ending = state.lastEnding, ending.work.step == .certificate {
                if case .failed = ending.outcome { return .concerned }
                if ending.outcome == .cancelled { return .quiet }
            }
            if case .notYet = SetupFlow.certificate(facts) { return .quiet }
            return .concerned
        case .needsApproval, .approving, .checking, .skipped:
            return .quiet
        }
    }

    /// The password field, Windows App to quit or install, a skip: his silence. A Windows App that
    /// isn't the real one, or one that wouldn't save the PC or say whether it has, is trouble.
    private static func savedPC(_ state: SetupWindowState, _ facts: SetupFlow.Facts) -> ArmieCue {
        switch SetupFlow.savedPC(facts) {
        case .needsWindowsApp(.wrongSignature), .manual:
            return .concerned
        case .saved:
            return hop(state, .savedPC) ?? .quiet
        case .needsWindowsApp, .windowsAppOpen, .save, .skipped, .notYet:
            return .quiet
        }
    }

    /// Accessibility is a permission, the ready card predicts Local Network's, and "did the desktop
    /// appear?" is the question: silent on all three. A connection that didn't work, and a Windows App
    /// gone since the saved PC, are trouble.
    private static func connect(_ state: SetupWindowState, _ facts: SetupFlow.Facts) -> ArmieCue {
        switch SetupFlow.connect(facts) {
        case .didNotWork, .needsWindowsApp:
            return .concerned
        case .worked:
            return hop(state, .connect) ?? .quiet
        case .allowAccessibility, .ready, .didItWork, .windowsAppSkipped, .notYet:
            return .quiet
        }
    }

    /// The two tiles are a question. UTM refusing because another VM runs, or not saying, is trouble.
    private static func finishChoice(_ facts: SetupFlow.Facts) -> ArmieCue {
        switch SetupFlow.finish(facts).headless {
        case .otherVMsRunning, .couldNotConfirm: return .concerned
        default: return .quiet
        }
    }

    /// The finished page's hero: his sign-off once Connect was answered **Yes**, with the hop when
    /// **Finish** has just brought the page (`SetupWindowState.armieHop`), standing by with it after;
    /// concern when it was **No**, or beside a failure the page still shows; otherwise (Windows App
    /// skipped, or installed since and Connect not tried) standing by. Not the hop beside a failure
    /// the page no longer draws, or after something changed while the window was open.
    private static func finished(_ state: SetupWindowState) -> ArmieCue {
        guard let facts = state.facts else { return .quiet }
        if SetupJourneyView.problemCard(state) != nil { return .concerned }
        switch state.lastEnding?.outcome {
        case .failed?, .overtaken?: return .quiet
        case .finished?, .cancelled?, nil: break
        }
        switch SetupCopy.Finish.outcome(facts) {
        case .connected:
            let pose: ArmieArt.Pose = hop(state, .finish) == nil ? .rest : .done
            return SetupCopy.Armie.doneLine(connected: facts.answers.connected).map { ArmieCue(pose: pose, line: $0) }
                ?? .quiet
        case .notConnected:
            return .concerned
        case .notTried, .windowsAppSkipped:
            return .quiet
        }
    }

    // MARK: The New Windows VM views, as step 2's body

    /// The create form, beside its title: its pages are questions, and one has the password field.
    static let form = ArmieCue.quiet

    /// The install's own pages (`JobHeading`): the stage's line while the install goes well
    /// (`SetupCopy.Armie.line(for:)`); concern beside a failure, a stall that's live, or a warning the
    /// page boxes (a failure's page is the one with **Send This to the Developer**, `besideReport`'s
    /// rule here); still and silent while macOS asks whether Winbar may control UTM, which the job says
    /// in the running row. Concern too, while it runs, beside any message that silences him
    /// (`SetupCopy.Armie.silences`): E_BOOT_NO_PROMPT asking the person to press a key in UTM's
    /// window, a note that something didn't work, a warning — trouble or a request for help, and the
    /// loop running on beside it would read as all being well. Not a stall's warning once the VM is
    /// writing again (`stalled` no longer an alert): that is the install recovered, and he narrates
    /// no line beside it but works on. Standing by once it has ended any other way. Pure.
    static func installing(_ job: CreateJobState) -> ArmieCue {
        let stallLive = !job.isFinished && job.stalled?.alert != nil
        if job.outcome == .failed || stallLive || job.messages.contains(where: { CreateProgress.boxedCodes.contains($0.code) }) {
            return .concerned
        }
        guard !job.isFinished else { return .quiet }
        if CreateProgress.detail(job.detail) == CreateCopy.pAutomation { return .quiet }
        if job.messages.contains(where: { SetupCopy.Armie.silences($0.code) && !stallCodes.contains($0.code) }) {
            return .concerned
        }
        return SetupCopy.Armie.line(for: job).map { ArmieCue(pose: .working, line: $0) } ?? .working
    }

    /// The stall warnings, whose standing is the job's `stalled` rather than the message: the message
    /// stays in the list after the VM starts writing again.
    private static let stallCodes: Set<String> = [InstallAlert.stall.rawValue, InstallAlert.stallBusy.rawValue]

    // MARK: The menu bar icon's popover

    /// In the popover that hangs from Winbar's menu bar icon (`MenuBarIntroBubble`), whose words name
    /// the icon ("Choose this icon…"): pointing toward it, from where macOS put the two once laid out
    /// (`ArmieArt.side`, both points on screen, y up); standing by where the icon isn't shown, where
    /// the two haven't been laid out yet, or where the icon is more above him than beside him —
    /// Astra has drawn no point upwards. Silent: the popover's words are the words. nil once hidden.
    /// Pure.
    static func popover(hidden: Bool, icon: CGPoint?, figure: CGPoint?) -> ArmieCue? {
        guard !hidden else { return nil }
        guard let icon, let figure, let side = ArmieArt.side(toward: icon, from: figure) else { return .quiet }
        return ArmieCue(pose: .pointing(side))
    }
}

/// What the wizard lends the New Windows VM views while they are its step 2, so Armie can stand by
/// the form and narrate the install there: his art, and the window's `send`, so **Hide Armie** is the
/// wizard's own and is remembered. The views belong to `CreateWindowController`, which knows nothing
/// of the wizard's settings, so this is the only way he reaches them — and the New Windows VM window
/// of their own is never lent one.
struct ArmieHost {
    let art: ArmieArt
    let send: (SetupCommand) -> Void

    /// The host for a window drawn from `state`, or nil when he's been hidden or the bundle has no
    /// art for him. Pure.
    static func lent(_ state: SetupWindowState, art: ArmieArt?, send: @escaping (SetupCommand) -> Void) -> ArmieHost? {
        guard !state.armieHidden, let art else { return nil }
        return ArmieHost(art: art, send: send)
    }
}
