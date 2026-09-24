import SwiftUI

/// The post-install steps use the runner's facts and the recipe's actions. No system work runs
/// while drawing a page. The saved-PC password lives only in the controller's ephemeral input.
struct SetupJourneyView: View {
    let state: SetupWindowState
    @ObservedObject var credentials: SetupCredentials
    let savePassword: (String) -> Void
    /// Armie on the finished page, which draws him larger in its arrival (`FinishArrival`); on every
    /// other page of these steps he is beside the title (`SetupPageHead`).
    var armie: ArmieCue? = nil
    var art: ArmieArt? = nil
    let send: (SetupCommand) -> Void
    /// The palette's red: the system's measured 3.2:1 on a light card.
    @Environment(\.errorText) private var errorText
    /// The palette's quiet grey, for the facts under a card's words.
    @Environment(\.quietText) private var quietText

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // First, where a press that didn't start is explained (`LookAroundView` says why there).
            if let refusal = state.refusal {
                RefusalBanner(text: SetupCopy.Working.refused(refusal, busy: state.inFlight, host: "Winbar"))
            }
            // A read nobody pressed, over a card the page keeps: one quiet line, not the page's spinner.
            if Self.showsQuietRead(state) { QuietReadLine() }
            // Steps 3 to 6 say what's running in their own card (`SetupJourneyActions.cardShowsWork`).
            if let flight = state.inFlight, !state.refreshing, !SetupJourneyActions.cardShowsWork(state) {
                ProgressView()
                Text(SetupCopy.markdown(flight.waitingFor.map { SetupCopy.Working.waiting($0, host: "Winbar") }
                                       ?? flight.line ?? SetupCopy.Working.sentence(SetupCopy.Working.doing(flight))))
                if flight.work.canStopWaiting { StopWaitingRow(work: flight.work) { send(.stopWaiting) } }
            }
            if let problem = Self.problemCard(state) {
                SetupCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(problem.description).textSelection(.enabled)
                        if BetaReport.cards(state).contains(.problem) { SendToDeveloperButton { send(.sendReport) } }
                    }
                }
            }
            if state.lastEnding?.outcome == .overtaken {
                Text("Something changed while this window was open. Check the current result below before trying again.")
            }
            if let facts = state.facts {
                Group {
                    switch state.step {
                    case .tune: tune(facts)
                    case .certificate: certificate(facts)
                    case .savedPC: savedPC(facts)
                    case .connect: connect(facts)
                    case .finish: finish(facts)
                    default: EmptyView()
                    }
                }.disabled(state.inFlight != nil && !Self.disablesItsOwnButtons(state))
            }
            // The certificate's card draws its own (`certificate`); a wait any other step's card can't
            // hold is still said with what stopping does, never as a bare button under the card.
            if SetupJourneyActions.cardShowsWork(state), state.step != .certificate, let flight = state.inFlight,
               flight.work.canStopWaiting {
                StopWaitingRow(work: flight.work) { send(.stopWaiting) }
            }
            if !state.installMessages.isEmpty {
                DisclosureGroup("Notes from the Windows install") {
                    ForEach(Array(state.installMessages.enumerated()), id: \.offset) { _, message in
                        Text(message.text).font(.callout).textSelection(.enabled).padding(.vertical, 4)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .onDisappear { credentials.clear() }
    }

    private func action(_ title: String, _ work: SetupRunner.Work) -> some View {
        Button(title) { send(.perform(.run(work))) }
    }

    /// Hands the typed password over. Nothing to save with an empty field, and nothing while a read
    /// runs: the field stays up through one (`disablesItsOwnButtons`), but its Save It doesn't. The
    /// field is forgotten by the controller once the runner takes the press
    /// (`SetupWindowController.savePC(password:)`), so one it turns down keeps what was typed.
    private func savePC() {
        guard !credentials.password.isEmpty, state.inFlight == nil else { return }
        savePassword(credentials.password)
    }

    /// The last work's failure while it still stands (`SetupWindowState.standingFailure`), in a plain
    /// card above the step's own — or nil where the step's card already says it. The certificate's
    /// does; so does a failed Connect's recovery card (the answer is No once it fails), which drew the
    /// same heading twice, the first telling Ben to choose a Close Setup that wasn't on screen. Pure.
    static func problemCard(_ state: SetupWindowState) -> SetupRunner.Problem? {
        guard let problem = state.standingFailure, state.step != .certificate else { return nil }
        if state.step == .connect, state.facts?.answers.connected == false { return nil }
        return problem
    }

    /// Tune and the certificate keep their pages live while work runs: the certificate's **What am I
    /// approving?** has to open while macOS's dialog asks for the password, and Tune's folded list
    /// while a check runs. So does the saved PC while a read nobody pressed runs (`refreshing`): its
    /// password field stays as it was, text and focus, where a disabled field would drop the focus
    /// mid-word. Their buttons are greyed one by one instead (or aren't drawn while work runs), and
    /// the footer's are the footer's. Pure.
    static func disablesItsOwnButtons(_ state: SetupWindowState) -> Bool {
        switch state.step {
        case .tune, .certificate: return true
        case .savedPC: return state.refreshing
        default: return false
        }
    }

    /// Whether the page draws the one quiet line for a read nobody pressed (`QuietReadLine`): where it
    /// keeps its card through the read rather than drawing what runs. Tune's headline and the
    /// certificate's status line say it in their own words already. Pure.
    static func showsQuietRead(_ state: SetupWindowState) -> Bool {
        state.refreshing && state.inFlight != nil && [.savedPC, .connect, .finish].contains(state.step)
    }

    // MARK: Tune

    /// A grouped list in the System Settings style: a headline that says whether anything is Ben's,
    /// the rows that are first and open, the rows settled some other way, and the rows that passed
    /// folded into one line. Its main action, **Fix Everything**, is the footer's
    /// (`SetupJourneyActions.footerAction`).
    @ViewBuilder private func tune(_ facts: SetupFlow.Facts) -> some View {
        let screen = SetupFlow.tune(facts)
        let groups = SetupTuneGroups(facts)
        let work = state.inFlight?.work
        let headline = SetupTuneHeadline.of(facts, working: state.inFlight.map { flight in
            flight.waitingFor != nil ? SetupJourneyActions.busyLine(flight) : SetupCopy.Tune.busy(flight)
        })
        let words = SetupCopy.Tune.headline(headline)
        VStack(alignment: .leading, spacing: 6) {
            SetupStatusLine(Self.mark(headline), words.title)
            if let detail = words.detail { Text(SetupCopy.markdown(detail)).setupProse() }
        }
        if !groups.needsYou.isEmpty {
            TuneList(groups.needsYou) { row in
                TuneRow(header: header(row, facts: facts, work: work, emphasis: true)) {
                    needsYou(row, screen: screen, facts: facts)
                }
            }
        }
        if !groups.others.isEmpty {
            TuneList(groups.others) { row in
                TuneRow(header: header(row, facts: facts, work: work, emphasis: false)) {
                    settled(row, screen: screen, facts: facts)
                }
            }
        }
        if !groups.verified.isEmpty {
            TuneVerifiedGroup(rows: groups.verified.map { header($0, facts: facts, work: work, emphasis: false) })
        }
    }

    private static func mark(_ headline: SetupTuneHeadline) -> StatusMark.Status {
        switch headline {
        case .working: return .running
        case .notAsked: return .pending
        case .needsYou, .unchecked: return .attention
        case .tuned: return .done
        }
    }

    private func header(_ row: SetupFlow.Row, facts: SetupFlow.Facts, work: SetupRunner.Work?, emphasis: Bool) -> TuneRowHeader {
        let status = SetupTuneStatus.status(for: row, facts: facts, work: work)
        return TuneRowHeader(mark: TuneRowHeader.mark(status, row), title: SetupCopy.Tune.title(row),
                             trailing: SetupCopy.Tune.trailing(status, row),
                             detail: SetupCopy.Tune.plain(SetupCopy.Tune.detail(row, keptBitLocker: facts.keepBitLocker)),
                             emphasis: emphasis)
    }

    /// An open row: what Winbar read, why it matters, what to do, and its buttons.
    @ViewBuilder private func needsYou(_ row: SetupFlow.Row, screen: SetupFlow.TuneScreen, facts: SetupFlow.Facts) -> some View {
        let busy = state.inFlight != nil
        let detail = SetupCopy.Tune.plain(SetupCopy.Tune.detail(row, keptBitLocker: facts.keepBitLocker))
        if !detail.isEmpty, detail != row.title, detail != SetupCopy.Tune.title(row) {
            Text(detail).font(.system(size: 13, weight: .medium)).textSelection(.enabled).setupProse()
        }
        Text(SetupCopy.Tune.why(row)).setupProse()
        if let how = row.how { Text(SetupCopy.Tune.how(row.id, how)).textSelection(.enabled).setupProse() }
        if let failure = row.failure { Text(failure).foregroundStyle(errorText).setupProse() }
        if row.id == "G9", let question = screen.bitLocker {
            bitLocker(question).disabled(busy)
        } else {
            // The row's first button may be the footer's corner (`tuneRowInCorner`): drawn there, once.
            let corner = SetupJourneyActions.tuneRowInCorner(facts)
            HStack(spacing: 8) {
                ForEach(SetupTuneRowActions.of(row, facts: facts).filter { corner?.rowID != row.id || $0 != corner?.action },
                        id: \.title) { button in
                    TuneRowButton(action: button) { send(button.command) }
                }
            }
            .disabled(busy)
        }
    }

    /// A row settled some other way: said in one quiet line, with Undo for a change waiting for the
    /// restart.
    @ViewBuilder private func settled(_ row: SetupFlow.Row, screen: SetupFlow.TuneScreen, facts: SetupFlow.Facts) -> some View {
        if let flag = screen.declined[row.id], row.kind != .ok {
            TuneNote(SetupCopy.Tune.leftAlone(declined: flag))
        } else if facts.answers.leftAlone.contains(row.id), row.kind != .ok {
            TuneNote(SetupCopy.Tune.leftAloneSkipped)
        } else if screen.staged.contains(row.id) {
            TuneNote(String(SetupCopy.Tune.stagedNote(vm: facts.chosenVM ?? "the VM").characters))
            Button("Undo This Change") { send(.discardChanges(row.id)) }.disabled(state.inFlight != nil)
        } else if row.id == "G9", facts.keepBitLocker {
            TuneNote(SetupCopy.Tune.keptBitLocker)
        } else if row.kind == .info {
            TuneNote(SetupCopy.Tune.words(row.detail))
        }
    }

    @ViewBuilder private func bitLocker(_ question: SetupFlow.BitLockerQuestion) -> some View {
        let offer = bitLockerOffer(question)
        Text(offer.explanation).setupProse()
        CardTitle(offer.question)
        HStack {
            action(SetupCopy.BitLocker.bNo, .keepBitLocker)
            action("Decrypt C:", .fix(checkID: "G9"))
        }
    }

    private func bitLockerOffer(_ question: SetupFlow.BitLockerQuestion) -> SetupCopy.BitLocker.Offer {
        switch question {
        case .encryptedAtRest(let places, let guessed):
            return SetupCopy.BitLocker.offer(places: places, unprotected: [], imagesKnown: !guessed, answers: .window)
        case .unencrypted(let places):
            return SetupCopy.BitLocker.offer(places: places, unprotected: places, imagesKnown: true, answers: .window)
        }
    }

    // MARK: The certificate

    /// The result, what happened, the one next action (in the footer's corner), and the
    /// alternatives in one row. **What am I approving?** stays openable while work runs: it is what
    /// someone reads while macOS's dialog waits for a password.
    @ViewBuilder private func certificate(_ facts: SetupFlow.Facts) -> some View {
        let page = SetupCertificatePage.page(state, facts: facts)
        SetupCard {
            VStack(alignment: .leading, spacing: 12) {
                SetupStatusLine(certificateMark(page.phase), SetupCopy.Certificate.result(page.phase))
                if !page.detail.isEmpty { Text(SetupCopy.markdown(page.detail)).textSelection(.enabled).setupProse() }
                if page.phase == .needsApproval, page.canApprove {
                    Text(SetupCopy.markdown(SetupCopy.Certificate.instructions)).setupProse()
                }
                let next = SetupCopy.Certificate.next(page)
                if !next.isEmpty { Text(SetupCopy.markdown(next)).setupProse() }
                // The wait's way out, in the card that says what it waits for, with what stopping does,
                // as the VM step's start has it. It floated bare under the card.
                if let flight = state.inFlight, flight.work.canStopWaiting {
                    StopWaitingRow(work: flight.work) { send(.stopWaiting) }
                }
                let approveHere = page.canApprove && (page.phase == .skipped || page.next == .checkAgain)
                if approveHere || page.canSkip || page.revisits {
                    HStack(spacing: 8) {
                        if approveHere {
                            action(page.phase == .skipped ? SetupCopy.Certificate.bApproveInstead : SetupCopy.Certificate.bRetry,
                                   .trustCertificate)
                        }
                        if page.revisits {
                            Button(SetupCopy.Certificate.bCheckAgainInstead) { send(.revisit(.certificate)) }
                        }
                        if page.canSkip { Button(SetupCopy.Certificate.bSkip) { send(.skip("H7")) } }
                        if BetaReport.cards(state).contains(.certificate) { SendToDeveloperButton { send(.sendReport) } }
                    }
                }
                if let host = facts.rdpHost {
                    DisclosureGroup("What am I approving?") {
                        Text(SetupCopy.Certificate.body(host: host)).setupProse()
                    }
                    .disclosureGroupStyle(JourneyDisclosureStyle())
                }
            }
        }
    }

    private func certificateMark(_ phase: SetupCertificatePage.Phase) -> StatusMark.Status? {
        switch phase {
        case .needsApproval: return nil
        case .approving, .checking: return .running
        case .verified: return .done
        case .skipped: return .pending
        case .attention: return .attention
        }
    }

    // MARK: The saved PC

    /// What the saved-PC card says while work runs, named for that work (`SetupCopy.SavedPC.busy`),
    /// or nil when nothing runs and the card shows the step itself — and while a read nobody pressed
    /// runs, which keeps the card and its password field as they were: the field went, and with it
    /// what was being typed, each time the window was clicked back into. Pure.
    static func savedPCWaiting(_ state: SetupWindowState) -> String? {
        guard !state.refreshing else { return nil }
        return state.inFlight.map(SetupCopy.SavedPC.busy)
    }

    /// Each state's main action is the footer's corner (`SetupJourneyActions`); the card has what
    /// to know, and the alternatives in one row at its foot.
    @ViewBuilder private func savedPC(_ facts: SetupFlow.Facts) -> some View {
        SetupCard {
            VStack(alignment: .leading, spacing: 12) {
                if let waiting = Self.savedPCWaiting(state) {
                    SetupStatusLine(.running, waiting)
                } else {
                switch SetupFlow.savedPC(facts) {
                case .needsWindowsApp(let dependency):
                    SetupStatusLine(nil, "Your turn: install Windows App")
                    if case .wrongSignature(let reason) = dependency {
                        Text(reason).setupProse()
                    } else {
                        Text(SetupCopy.markdown(SetupCopy.SavedPC.installWindowsApp)).setupProse()
                        details {
                            ForEach(SetupCopy.SavedPC.windowsAppPlan(brewPresent: facts.homebrew != nil), id: \.self) {
                                Text($0).setupProse()
                            }
                        }
                    }
                    HStack(spacing: 8) { Button(SetupCopy.SavedPC.bSkipWindowsApp) { send(.skip("C1")) } }
                        .disabled(state.inFlight != nil)
                case .windowsAppOpen:
                    SetupStatusLine(nil, "Your turn: quit Windows App first")
                    Text(SetupCopy.markdown(SetupCopy.SavedPC.appOpen)).setupProse()
                    details { Text(SetupCopy.SavedPC.appOpenWhy).setupProse() }
                    HStack(spacing: 8) {
                        Button(SetupCopy.SavedPC.bContinueToSignInInstead) { send(.continueWithoutSavedPC) }
                    }
                    .disabled(state.inFlight != nil)
                case .save(_, let user):
                    SetupStatusLine(nil, SetupCopy.SavedPC.yourTurn)
                    Text(SetupCopy.SavedPC.lead(user: user)).setupProse()
                    SecureField(text: $credentials.password) { Text(SetupCopy.SavedPC.passwordLabel(user: user)) }
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(savePC)
                    Text(SetupCopy.markdown(SetupCopy.SavedPC.afterSaving)).foregroundStyle(quietText).setupProse()
                    // Where the password goes, including the second it spends in Windows App's arguments,
                    // stays one click away rather than a 125-word wall above the field.
                    DisclosureGroup(SetupCopy.SavedPC.whereItGoes) { Text(SetupCopy.SavedPC.why(user: user)).setupProse() }
                        .disclosureGroupStyle(JourneyDisclosureStyle())
                    HStack(spacing: 8) { Button(SetupCopy.SavedPC.bSkipSaving) { credentials.clear(); send(.skip("C2")) } }
                        .disabled(state.inFlight != nil)
                case .saved(let row):
                    SetupStatusLine(.done, SetupCopy.SavedPC.savedAnnouncement)
                    Text(row.detail).foregroundStyle(quietText).textSelection(.enabled).setupProse()
                    Text(SetupCopy.SavedPC.saved).setupProse()
                case .manual(let row) where SetupFlow.commandLineSilent(facts):
                    // Windows App's command line isn't answering: said as Windows App's problem, with
                    // the steps to do it by hand in view (the step is the person's now), the way into
                    // Windows App, the word that it's done, and one more try. What Windows App said is
                    // under Details. The corner is Continue to Connect.
                    SetupStatusLine(.attention, SetupCopy.SavedPC.silentTitle)
                    Text(SetupCopy.SavedPC.silent).setupProse()
                    Text(SetupCopy.markdown(SetupCopy.SavedPC.silentNext)).setupProse()
                    if let how = row.how { Text(how).textSelection(.enabled).setupProse() }
                    if let host = facts.rdpHost {
                        Text(SetupCopy.SavedPC.editInstead(host: host, user: facts.rdpUser)).setupProse()
                    }
                    // Greyed while anything runs, a read nobody pressed included: the card stays up through
                    // one (`disablesItsOwnButtons`), and these are the runner's work.
                    HStack(spacing: 8) {
                        if row.canGuide { action(SetupCopy.SavedPC.bOpenWindowsApp, .guide(checkID: "C2")) }
                        action(SetupCopy.SavedPC.bSavedItMyself, .recordDone(checkID: "C2"))
                        Button(SetupCopy.bTryAgain) { send(.retrySavedPC) }
                    }
                    .disabled(state.inFlight != nil)
                    // Its own row, and never greyed out: asking for help reads, and runs beside anything.
                    if BetaReport.cards(state).contains(.savedPC) { SendToDeveloperButton { send(.sendReport) } }
                    details { Text(row.detail).textSelection(.enabled).setupProse() }
                case .manual(let row):
                    SetupStatusLine(.attention, SetupCopy.SavedPC.manualTitle)
                    Text(SetupCopy.SavedPC.manual).setupProse()
                    Text(SetupCopy.markdown(SetupCopy.SavedPC.manualNext)).setupProse()
                    HStack(spacing: 8) { Button(SetupCopy.bTryAgain) { send(.retrySavedPC) } }
                        .disabled(state.inFlight != nil)
                    if BetaReport.cards(state).contains(.savedPC) { SendToDeveloperButton { send(.sendReport) } }
                    DisclosureGroup(SetupCopy.SavedPC.saveItYourself) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(row.detail).setupProse()
                            if let how = row.how { Text(how).setupProse() }
                            HStack(spacing: 8) {
                                if row.canGuide { action(SetupCopy.SavedPC.bOpenWindowsApp, .guide(checkID: "C2")) }
                                action(SetupCopy.SavedPC.bSavedItMyself, .recordDone(checkID: "C2"))
                            }
                            .disabled(state.inFlight != nil)
                        }
                    }
                    .disclosureGroupStyle(JourneyDisclosureStyle())
                case .skipped:
                    let noApp = SetupFlow.windowsAppSkipped(facts)
                    SetupStatusLine(.pending, noApp ? SetupCopy.SavedPC.windowsAppSkippedTitle : SetupCopy.SavedPC.skippedTitle)
                    Text(SetupCopy.markdown(noApp ? SetupCopy.SavedPC.windowsAppSkipped : SetupCopy.SavedPC.skipped))
                        .setupProse()
                    // The way back. The footer's corner is still Continue, which Return presses. Greyed while
                    // anything runs, as the card's Skip is.
                    HStack(spacing: 8) { Button(SetupCopy.SavedPC.bTrySavingAgain) { send(.revisit(.savedPC)) } }
                        .disabled(state.inFlight != nil)
                case .notYet:
                    let words = SetupCopy.SavedPC.notYet(host: facts.rdpHost, user: facts.rdpUser)
                    SetupStatusLine(words.showsWindowsScreen ? nil : .pending, words.title)
                    Text(SetupCopy.markdown(words.body)).setupProse()
                    HStack(spacing: 8) { Button(SetupCopy.SavedPC.bSkipSaving) { credentials.clear(); send(.skip("C2")) } }
                        .disabled(state.inFlight != nil)
                }
                }
            }
        }
    }

    /// The reasoning behind a card's one sentence, folded.
    private func details<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        let folded = content()
        return DisclosureGroup("Details") { VStack(alignment: .leading, spacing: 8) { folded } }
            .disclosureGroupStyle(JourneyDisclosureStyle())
    }

    // MARK: Connect

    @ViewBuilder private func connect(_ facts: SetupFlow.Facts) -> some View {
        if state.reconnectAfterRestart { Text(SetupCopy.markdown(SetupCopy.Connecting.afterRestart)).setupProse() }
        SetupCard {
            VStack(alignment: .leading, spacing: 12) {
                // A read nobody pressed keeps the card: the recovery card's words are what Ben is
                // reading when he clicks back into the window (`QuietReadLine` says the read).
                if let flight = state.inFlight, !state.refreshing {
                    SetupStatusLine(.running, SetupJourneyActions.busyLine(flight))
                    // Only about Connect itself: a Check Again's read or opening Accessibility settings
                    // opens nothing, and isn't followed by the desktop question.
                    if flight.work == .connect {
                        Text(SetupCopy.Connecting.openingIsNotProof).foregroundStyle(quietText).setupProse()
                    }
                } else {
                switch SetupFlow.connect(facts) {
                case .allowAccessibility:
                    SetupStatusLine(nil, "Your turn: allow Winbar in System Settings")
                    Text(SetupCopy.markdown(SetupCopy.Connecting.accessibilityLead)).setupProse()
                    details { Text(SetupCopy.markdown(SetupCopy.Connecting.accessibility)).setupProse() }
                    HStack(spacing: 8) { Button(SetupCopy.Connecting.bUseOneOff) { send(.skip("C3")) } }
                case .ready:
                    SetupStatusLine(nil, "Ready to test: not connected yet")
                    Text(SetupCopy.markdown(SetupCopy.Connecting.readyLead)).setupProse()
                    Text(SetupCopy.markdown(SetupCopy.Connecting.localNetworkLead)).setupProse()
                    details { Text(SetupCopy.markdown(SetupCopy.Connecting.localNetwork)).setupProse() }
                case .didItWork:
                    SetupStatusLine(nil, SetupCopy.Connecting.didItAppearHeading)
                    Text(SetupCopy.Connecting.openedConnection).setupProse()
                    HStack(spacing: 8) {
                        Button(SetupCopy.Connecting.bNo) { send(.connected(false)) }
                        Button(SetupCopy.Connecting.bYes) { send(.connected(true)) }.stepPrimaryButton()
                    }
                case .didNotWork(let diagnosis):
                    // The heading and the advice follow Winbar's own check of the port, and what H5 says
                    // (or doesn't) about the VM's screen; the host, the user and the saved PC are the
                    // facts under it. All from the diagnosis, so nothing here can read H5 differently.
                    let recovery = SetupCopy.Connecting.recovery(diagnosis)
                    SetupStatusLine(.attention, recovery.heading)
                    ForEach(recovery.steps, id: \.self) { Text(SetupCopy.markdown($0)).setupProse() }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: "PC: \(diagnosis.host ?? "not known") · User: \(diagnosis.user ?? "not known")")
                        Text(diagnosis.savedPC ? "Windows App has the saved PC."
                                               : "No saved PC was confirmed. A one-off connection asks for your Windows password.")
                    }
                    .foregroundStyle(quietText)
                    .setupProse()
                    HStack(spacing: 8) {
                        // The way forward is the footer's corner (`SetupJourneyActions.footerAction`):
                        // the setting where macOS refused the check, otherwise the retry. The card keeps
                        // the alternatives: the retry to press once the setting is on, and the rest.
                        if recovery.opensLocalNetwork {
                            Button(recovery.retry.title) { send(recovery.retry.command) }
                        }
                        Button("Report a Problem…") { send(.reportProblem) }
                        if BetaReport.cards(state).contains(.connectRecovery) { SendToDeveloperButton { send(.sendReport) } }
                        if recovery.offersConsole { Button(SetupCopy.Connecting.bCloseSetup) { send(.closeForNow) } }
                    }
                case .worked:
                    SetupStatusLine(.done, "Connection confirmed")
                    Text("You confirmed the Windows desktop opened. This step is complete.").setupProse()
                case .needsWindowsApp:
                    SetupStatusLine(.attention, "Windows App is missing")
                    Text(SetupCopy.markdown("Choose **Back** to install it.")).setupProse()
                case .windowsAppSkipped:
                    SetupStatusLine(.pending, "No connection to test")
                    Text("Windows App was skipped, so no connection has been tested. The VM will keep its screen.").setupProse()
                case .notYet:
                    SetupStatusLine(.pending, "Not ready to test yet")
                    Text(SetupCopy.markdown("Winbar is still reading Windows' name and its own permissions. "
                                            + "Choose **\(SetupCopy.bCheckAgain)**.")).setupProse()
                }
                }
            }
        }
    }

    /// The choice and the restart, then the arrival once finished (`SetupFinishPage`).
    @ViewBuilder private func finish(_ facts: SetupFlow.Facts) -> some View {
        if state.finished {
            FinishArrival(facts: facts, passedOver: SetupFinishPage.passedOver(state), armie: armie, art: art, send: send)
        } else {
            FinishChoiceView(state: state, facts: facts, send: send)
        }
    }
}

// MARK: - A read nobody pressed

/// The one line a page draws while a read nobody pressed runs over a card it keeps
/// (`SetupJourneyView.showsQuietRead`): a small spinner and "Checking again…", in the quiet grey,
/// above the card, so the page says something is being read without taking the card away.
struct QuietReadLine: View {
    @Environment(\.quietText) private var quiet

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            ProgressView().controlSize(.small)
            Text(SetupCopy.Working.lookingAgain).foregroundStyle(quiet)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Stop Waiting

/// **Stop Waiting**, and beside it what stopping does (`SetupCopy.Working.stopConsequence`): one way on
/// every step that has a wait to stop, inside the card that says what it waits for.
struct StopWaitingRow: View {
    let work: SetupRunner.Work
    let stop: () -> Void
    @Environment(\.quietText) private var quiet

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button(SetupCopy.Working.bStopWaiting, action: stop)
            if let consequence = SetupCopy.Working.stopConsequence(work) {
                Text(consequence)
                    .font(.system(size: SetupStyle.smallestText))
                    .foregroundStyle(quiet)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 4)
    }
}

// MARK: - The tune list

/// A group of rows the way System Settings draws one: one card, rows 36 pt and up, and hairlines
/// between them inset to where the titles start. Fifteen separate cards, each with a heading, a
/// status line and a sentence, made the one row that needed Ben look like all the others.
struct TuneList<Row: View>: View {
    let rows: [SetupFlow.Row]
    let row: (SetupFlow.Row) -> Row

    init(_ rows: [SetupFlow.Row], @ViewBuilder row: @escaping (SetupFlow.Row) -> Row) {
        self.rows = rows
        self.row = row
    }

    var body: some View {
        SetupCard {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { TuneDivider() }
                    row(item)
                }
            }
            // The card's own padding is for prose; a list's rows carry their own, so the first title
            // sits where a card's first line would.
            .padding(.vertical, -TuneRowHeader.rowPadding)
        }
    }
}

/// The hairline between two rows, from the titles' edge to the card's.
struct TuneDivider: View {
    var body: some View {
        Divider().padding(.leading, TuneRowHeader.titleInset)
    }
}

/// One row: its header, and under it, lined up with the title, whatever the row has to say.
struct TuneRow<Content: View>: View {
    let header: TuneRowHeader
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            VStack(alignment: .leading, spacing: 8) { content }
                .padding(.leading, TuneRowHeader.titleInset)
        }
        .padding(.vertical, TuneRowHeader.rowPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A row's first line: the mark, the title, and how it stands at the trailing edge, in the quiet
/// grey the mark's colour and shape don't need to repeat. VoiceOver reads it as one thing: the title,
/// then the status word (the mark's own name would say the status twice).
struct TuneRowHeader: View {
    /// Where titles start: the mark's column and the gap after it.
    static var titleInset: CGFloat { StatusMark.width + 10 }
    /// Above and below a row's first line: with its 18 pt minimum, a one-line row is 36 pt tall, the
    /// low end of System Settings' rows.
    static var rowPadding: CGFloat { 9 }

    let mark: StatusMark.Status
    let title: String
    let trailing: String
    /// What Winbar read, on hover and to VoiceOver: a folded row that passed has no room for it.
    var detail: String = ""
    /// Semibold for a row that needs Ben, regular for the rest, as System Settings sets a row.
    var emphasis = false

    @Environment(\.quietText) private var quiet

    /// A row's mark: done, needs Ben, failed (a read Windows didn't answer, or a Fix that didn't
    /// work), running, ⓘ for a note, or the hollow circle for everything settled some other way.
    static func mark(_ status: SetupTuneStatus, _ row: SetupFlow.Row) -> StatusMark.Status {
        switch status {
        case .verified: return .done
        case .checking, .applying: return .running
        case .needsAttention: return row.kind == .error || row.failure != nil ? .failed : .attention
        case .information: return .info
        case .pendingRestart, .skipped, .notChecked: return .pending
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            StatusMark(mark, pendingLabel: trailing)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 13, weight: emphasis ? .semibold : .regular))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            Text(trailing)
                .font(.system(size: 13))
                .foregroundStyle(quiet)
                .fixedSize()
        }
        .frame(minHeight: 36 - 2 * Self.rowPadding, alignment: .center)
        .contentShape(Rectangle())
        .help(detail)
        .accessibilityElement(children: .combine)
        .accessibilityValue(detail)
    }
}

/// A quiet line under a settled row: why it's settled.
struct TuneNote: View {
    let text: String
    @Environment(\.quietText) private var quiet

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).foregroundStyle(quiet).setupProse()
    }
}

/// A row's button, named for VoiceOver with the row it acts on (`SetupCopy.Tune.spoken`): five
/// rows' "Skip, button" said nothing about which one.
struct TuneRowButton: View {
    let action: SetupTuneRowActions.Action
    let press: () -> Void

    var body: some View {
        Button(action.title, action: press)
            .accessibilityLabel(action.spoken)
    }
}

/// The rows that passed, folded into "✓ 13 settings already right", as System Settings folds what
/// needs no attention. Open, they are rows like the others.
struct TuneVerifiedGroup: View {
    let rows: [TuneRowHeader]
    @State private var open = false

    var body: some View {
        SetupCard {
            DisclosureGroup(isExpanded: $open) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, header in
                        TuneDivider()
                        header.padding(.vertical, TuneRowHeader.rowPadding)
                    }
                }
                .padding(.bottom, -TuneRowHeader.rowPadding)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    StatusMark(.done).accessibilityHidden(true)
                    Text(SetupCopy.Tune.alreadyRight(rows.count)).font(.system(size: 13))
                }
            }
            .disclosureGroupStyle(JourneyDisclosureStyle(chevronTrailing: true))
        }
    }
}

// MARK: - Disclosures

/// The journey's folded "Details", "What am I approving?" and "Where this password goes": the label
/// and an accent-coloured chevron, 11 pt, over a 24 pt hit area. The system's chevron measured 1.78:1
/// on a light card, which is too faint to be seen as something that opens.
struct JourneyDisclosureStyle: DisclosureGroupStyle {
    /// On the trailing edge, as a folded list row has it in System Settings; before the label, as a
    /// "Details" in running text does.
    var chevronTrailing = false

    static let chevronSize: CGFloat = 11

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { configuration.isExpanded.toggle() }
            } label: {
                HStack(alignment: .center, spacing: 6) {
                    if !chevronTrailing { DisclosureChevron(open: configuration.isExpanded) }
                    configuration.label.foregroundStyle(.primary)
                    if chevronTrailing {
                        Spacer(minLength: 8)
                        DisclosureChevron(open: configuration.isExpanded)
                    }
                }
                .frame(minHeight: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
            if configuration.isExpanded {
                configuration.content.padding(.top, 8)
            }
        }
    }
}

private struct DisclosureChevron: View {
    let open: Bool

    var body: some View {
        withSetupAppearance { look in
            Image(systemName: "chevron.right")
                .font(.system(size: JourneyDisclosureStyle.chevronSize, weight: .bold))
                .foregroundStyle(look.accentText)
                .rotationEffect(.degrees(open ? 90 : 0))
                .frame(width: 14)
        }
        .accessibilityHidden(true)
    }
}
