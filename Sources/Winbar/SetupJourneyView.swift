import SwiftUI

/// The post-install steps use the runner's facts and the recipe's actions. No system work runs
/// while drawing a page. The saved-PC password lives only in the controller's ephemeral input.
struct SetupJourneyView: View {
    let state: SetupWindowState
    @ObservedObject var credentials: SetupCredentials
    let savePassword: (String) -> Void
    /// Armie, when `ArmieCue.cue` puts him on this page: only the done screen, of these steps.
    var armie: ArmieCue? = nil
    var art: ArmieArt? = nil
    let send: (SetupCommand) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let flight = state.inFlight, state.step != .certificate || state.facts == nil {
                ProgressView()
                Text(SetupCopy.markdown(flight.waitingFor.map { SetupCopy.Working.waiting($0, host: "Winbar") }
                                       ?? flight.line ?? SetupCopy.Working.sentence(SetupCopy.Working.doing(flight))))
                if flight.work.canStopWaiting { Button(SetupCopy.Working.bStopWaiting) { send(.stopWaiting) } }
            }
            if let refusal = state.refusal {
                Text(refusal.description)
            }
            if case .failed(let problem)? = state.lastEnding?.outcome, state.step != .certificate {
                SetupCard { Text(problem.description).textSelection(.enabled) }
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
                }.disabled(state.inFlight != nil)
            }
            if state.step == .certificate, state.inFlight?.work.canStopWaiting == true {
                Button(SetupCopy.Working.bStopWaiting) { send(.stopWaiting) }
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

    /// Hands the typed password over once and forgets it. Nothing to save with an empty field.
    private func savePC() {
        guard !credentials.password.isEmpty else { return }
        let secret = credentials.password
        credentials.clear()
        savePassword(secret)
    }

    /// The page's one filled button, which Return presses: the fill blue, as the footer's default takes,
    /// not the lighter text accent the page's other buttons are tinted with.
    private func defaultButton(_ title: String, action: @escaping () -> Void) -> some View {
        withSetupAppearance { look in
            Button(title, action: action)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(look.accentFill)
        }
    }

    @ViewBuilder private func tune(_ facts: SetupFlow.Facts) -> some View {
        let screen = SetupFlow.tune(facts)
        Text(SetupCopy.Tune.heading).font(.title2.bold())
        Text(SetupCopy.Tune.body)
        Text(SetupCopy.Tune.summary(SetupTuneStatus.counts(facts, work: state.inFlight?.work)))
            .font(.subheadline.weight(.semibold))
            .fixedSize(horizontal: false, vertical: true)
        if let pointer = SetupCopy.Tune.attentionPointer(SetupTuneStatus.counts(facts, work: state.inFlight?.work)) {
            Text(pointer).fixedSize(horizontal: false, vertical: true)
        }
        if !screen.unread.isEmpty { action(SetupCopy.bCheckAgain, .survey) }
        if !screen.fixEverything.isEmpty { action(SetupCopy.Tune.bFixEverything, .fixEverything).buttonStyle(.borderedProminent) }
        ForEach(SetupTuneStatus.attentionFirst(screen.rows, facts: facts, work: state.inFlight?.work), id: \.id) { row in
            let status = SetupTuneStatus.status(for: row, facts: facts, work: state.inFlight?.work)
            SetupCard {
                VStack(alignment: .leading, spacing: 8) {
                    // The title alone: "G7" is the recipe's name for a row, which `winbar doctor` prints
                    // and the reports carry, but nobody using this window needs it.
                    Text(row.title).font(.headline)
                    SetupTuneStatusLabel(status: status)
                    Text(SetupCopy.Tune.detail(row, keptBitLocker: facts.keepBitLocker)).textSelection(.enabled)
                    if let reason = screen.declined[row.id], row.kind != .ok {
                        Text("Off by choice: \(SetupCopy.Tune.choiceLabel(reason))").font(.caption)
                    } else if facts.answers.leftAlone.contains(row.id), row.kind != .ok {
                        Text("Left as it is for this setup.").font(.caption)
                    } else if screen.staged.contains(row.id) {
                        Text(SetupCopy.Tune.stagedNote(vm: facts.chosenVM ?? "the VM"))
                        Button("Undo This Change") { send(.discardChanges(row.id)) }
                    } else if row.kind != .ok && row.kind != .info {
                        Text(SetupCopy.Tune.plain(row.why)).font(.callout)
                        if let how = row.how { Text(SetupCopy.Tune.how(row.id, how)).font(.callout).textSelection(.enabled) }
                        if let failure = row.failure { Text(failure).foregroundStyle(.red) }
                        if row.id == "G9", let question = screen.bitLocker {
                            bitLocker(question)
                        } else {
                            HStack {
                                if row.kind == .fixable && row.action == .fix { action(SetupCopy.Tune.bFix, .fix(checkID: row.id)) }
                                if row.kind == .manual {
                                    if row.canGuide { action(SetupCopy.Tune.bOpen, .guide(checkID: row.id)) }
                                    action(SetupCopy.bDone, .recordDone(checkID: row.id))
                                }
                                if row.id != "G0", status != .skipped { Button(SetupCopy.bSkip) { send(.skip(row.id)) } }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private func bitLocker(_ question: SetupFlow.BitLockerQuestion) -> some View {
        let offer = bitLockerOffer(question)
        Text(offer.explanation)
        Text(offer.question).font(.headline)
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

    @ViewBuilder private func certificate(_ facts: SetupFlow.Facts) -> some View {
        let page = SetupCertificatePage.page(state, facts: facts)
        Text(SetupCopy.Certificate.heading).font(.title2.bold())
        SetupCard {
            VStack(alignment: .leading, spacing: 12) {
                Label(SetupCopy.Certificate.result(page.phase), systemImage: certificateSymbol(page.phase))
                    .font(.headline)
                if page.phase == .approving || page.phase == .checking { ProgressView() }
                if !page.detail.isEmpty { Text(SetupCopy.markdown(page.detail)).textSelection(.enabled) }
                if page.phase == .needsApproval { Text(SetupCopy.Certificate.instructions) }
                if page.phase == .approving { Text(SetupCopy.Certificate.waiting) }
                Text(SetupCopy.Certificate.next(page.phase, canApprove: page.canApprove))
                if page.canApprove {
                    let title = page.phase == .skipped ? SetupCopy.Certificate.bApproveInstead
                        : page.phase == .attention ? SetupCopy.Certificate.bRetry : SetupCopy.Certificate.bApprove
                    action(title, .trustCertificate).buttonStyle(.borderedProminent)
                }
                if page.canSkip {
                    Button(SetupCopy.Certificate.bSkip) { send(.skip("H7")) }
                }
                if let host = facts.rdpHost {
                    DisclosureGroup("What am I approving?") { Text(SetupCopy.Certificate.body(host: host)) }
                }
            }
        }
    }

    private func certificateSymbol(_ phase: SetupCertificatePage.Phase) -> String {
        switch phase {
        case .needsApproval: return "hand.point.up.left"
        case .approving: return "clock"
        case .checking: return "magnifyingglass"
        case .verified: return "checkmark.circle.fill"
        case .skipped: return "minus.circle"
        case .attention: return "exclamationmark.triangle.fill"
        }
    }

    /// What the saved-PC card says while work runs, named for that work (`SetupCopy.SavedPC.busy`),
    /// or nil when nothing runs and the card shows the step itself. Pure.
    static func savedPCWaiting(_ state: SetupWindowState) -> String? {
        state.inFlight.map(SetupCopy.SavedPC.busy)
    }

    @ViewBuilder private func savedPC(_ facts: SetupFlow.Facts) -> some View {
        Text(SetupCopy.SavedPC.heading).font(.title2.bold())
        SetupCard {
            VStack(alignment: .leading, spacing: 12) {
                if let waiting = Self.savedPCWaiting(state) {
                    Text(waiting)
                } else {
                switch SetupFlow.savedPC(facts) {
                case .needsWindowsApp(let dependency):
                    Text("Your turn: install Windows App").font(.headline)
                    if case .wrongSignature(let reason) = dependency {
                        Text(reason)
                    } else {
                        ForEach(SetupCopy.SavedPC.windowsAppPlan(brewPresent: facts.homebrew != nil), id: \.self) { Text($0) }
                        action("Open the App Store", .installWindowsApp)
                        Text("Install Windows App in the App Store. When its button says Open, return here and choose Check Again. Winbar will confirm the app is installed, then ask to save your connection.")
                    }
                    Button("Skip Windows App") { send(.skip("C1")) }
                case .windowsAppOpen:
                    Text("Your turn: close Windows App before saving").font(.headline)
                    Text(SetupCopy.markdown(SetupCopy.SavedPC.appOpen))
                    Button(SetupCopy.SavedPC.bQuitWindowsApp) { send(.quitWindowsApp) }
                    Text("After Windows App closes, choose Check Again. The password form will appear when Winbar confirms it is ready.")
                    Button("Continue to Sign-in Instead") { send(.continueWithoutSavedPC) }
                case .save(_, let user):
                    Text("Your turn: save the connection").font(.headline)
                    Text(SetupCopy.SavedPC.lead)
                    // Where the password goes, including the second it spends in Windows App's arguments,
                    // stays one click away rather than a 125-word wall above the field.
                    DisclosureGroup(SetupCopy.SavedPC.whereItGoes) { Text(SetupCopy.SavedPC.why(user: user)).padding(.top, 4) }
                    SecureField(text: $credentials.password) { Text(SetupCopy.SavedPC.passwordLabel(user: user)) }
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(savePC)
                    if credentials.password.isEmpty {
                        Button(SetupCopy.SavedPC.bSaveIt) {}.disabled(true)
                    } else {
                        defaultButton(SetupCopy.SavedPC.bSaveIt, action: savePC)
                    }
                    Button("Skip saving the PC") { credentials.clear(); send(.skip("C2")) }
                    Text("After saving, wait for PC saved below. Then continue to the connection test.")
                case .saved(let row):
                    Label("PC saved", systemImage: "checkmark.circle.fill").font(.headline)
                    Text(row.detail)
                    Text("This step is complete. Choose Continue to Connection Test below.")
                case .manual(let row):
                    Text("Automatic saving is unavailable").font(.headline)
                    Text("You can still connect. Continue to the connection test, then enter your Windows username and password in Windows App when it asks. Your Mac password and Windows PIN won't work there.")
                    Button("Continue to Sign-in") { send(.continueWithoutSavedPC) }
                        .buttonStyle(.borderedProminent)
                    Button("Retry Automatic Setup") { send(.retrySavedPC) }
                    DisclosureGroup("Save a connection yourself") {
                        Text(row.detail)
                        if let how = row.how { Text(how) }
                        if row.canGuide { action("Open Windows App", .guide(checkID: "C2")) }
                        action("I've Saved the Connection", .recordDone(checkID: "C2"))
                    }
                case .skipped:
                    Label("Saved connection skipped", systemImage: "minus.circle").font(.headline)
                    Text("The saved connection was skipped. You can add it later in Windows App. Choose Continue to Connection Test below.")
                case .notYet(let row):
                    Text(SetupCopy.SavedPC.missing(host: facts.rdpHost, user: facts.rdpUser))
                    if let row { Text(row.detail) }
                    Button("Skip saving the PC") { credentials.clear(); send(.skip("C2")) }
                }
                }
            }
        }
    }

    @ViewBuilder private func connect(_ facts: SetupFlow.Facts) -> some View {
        Text(SetupCopy.Connecting.heading).font(.title2.bold())
        if state.reconnectAfterRestart { Text(SetupCopy.Connecting.afterRestart) }
        SetupCard {
            VStack(alignment: .leading, spacing: 12) {
                if state.inFlight != nil {
                    Text("Wait while Winbar checks or opens the connection. Opening Windows App alone does not verify the connection; Winbar will ask whether you see the Windows desktop.")
                } else {
                switch SetupFlow.connect(facts) {
                case .allowAccessibility:
                    Text("Your turn: allow Winbar in System Settings").font(.headline)
                    Text(SetupCopy.markdown(SetupCopy.Connecting.accessibility))
                    action(SetupCopy.Connecting.bAllowAccessibility, .guide(checkID: "C3"))
                    Text("After enabling Winbar, return here and choose Check Again. The Connect button appears when Winbar confirms the permission.")
                    Button("Use a one-off connection") { send(.skip("C3")) }
                case .ready:
                    Text("Ready to test—not connected yet").font(.headline)
                    Text(SetupCopy.Connecting.localNetwork)
                    Text("Choose Connect. When Windows App opens, finish signing in there if asked. Return here and tell Winbar whether you see the Windows desktop.")
                    action(SetupCopy.Connecting.bConnect, .connect).buttonStyle(.borderedProminent)
                case .didItWork:
                    Text(SetupCopy.Connecting.didItAppearHeading).font(.headline)
                    Text(SetupCopy.Connecting.openedConnection)
                    HStack {
                        Button(SetupCopy.Connecting.bNo) { send(.connected(false)) }
                        Button(SetupCopy.Connecting.bYes) { send(.connected(true)) }.buttonStyle(.borderedProminent)
                    }
                case .didNotWork(let diagnosis):
                    // The heading and the advice follow Winbar's own check of the port, and what H5 says
                    // (or doesn't) about the VM's screen; the host, the user and the saved PC are the
                    // facts under it. All from the diagnosis, so nothing here can read H5 differently.
                    let recovery = SetupCopy.Connecting.recovery(diagnosis)
                    Text(recovery.heading).font(.headline)
                    Text(verbatim: "PC: \(diagnosis.host ?? "not known") · User: \(diagnosis.user ?? "not known")")
                    Text(diagnosis.savedPC ? "The PC is saved in Windows App." : "No saved PC was confirmed. A one-off connection asks for your Windows password.")
                    ForEach(recovery.steps, id: \.self) { Text(SetupCopy.markdown($0)) }
                    if recovery.offersConsole { Button("Close Setup") { send(.closeForNow) } }
                    HStack {
                        // The filled default, and the button the steps name in bold. The footer's Continue
                        // Without Connecting used to hold both, so Return skipped the one step that proves
                        // the setup works.
                        defaultButton(recovery.retry.title) {
                            send(recovery.retry == .tryAgain ? .retryConnection : .perform(.run(.checkAgain(.connect))))
                        }
                        Button("Report a Problem…") { send(.reportProblem) }
                    }
                case .worked:
                    Label("Connection confirmed", systemImage: "checkmark.circle.fill").font(.headline)
                    Text("You confirmed the Windows desktop opened. Choose Continue to Finish below.")
                case .needsWindowsApp: Text("Windows App is missing. Go back to install it.")
                case .windowsAppSkipped: Text("Windows App was skipped, so no connection has been tested. The VM will keep its screen.")
                case .notYet: Text("Check the PC's name and Winbar's permissions before connecting.")
                }
                }
            }
        }
    }

    @ViewBuilder private func finish(_ facts: SetupFlow.Facts) -> some View {
        let screen = SetupFlow.finish(facts)
        if state.finished {
            Text(facts.answers.connected == true ? SetupCopy.Finish.doneHeading : "Setup finished; the connection still needs checking")
                .font(.title2.bold())
            ForEach(Array(SetupCopy.Finish.doneBody(vm: screen.vm ?? "the VM",
                    facts.answers.connected == true ? .connected : (SetupFlow.windowsAppSkipped(facts) ? .windowsAppSkipped : .notConnected),
                    canReopenFromMenu: SetupWindow.availableToEveryone).enumerated()),
                    id: \.offset) { _, line in Text(line) }
            // Last, under the words that say it's done: the page's point is those, and he only agrees.
            if let armie, let art {
                ArmieSays(line: armie.line, art: art, clip: armie.clip, send: send)
            }
        } else {
            SetupCard {
                VStack(alignment: .leading, spacing: 12) {
                    switch screen.headless {
                    case .offer:
                        Text(SetupCopy.Finish.headlessHeading).font(.headline)
                        ForEach(SetupCopy.Finish.headlessBody, id: \.self) { Text(SetupCopy.markdown($0)) }
                        action(SetupCopy.Finish.bGoHeadless, .fix(checkID: "H5"))
                        Button(SetupCopy.Finish.bKeepScreen) { send(.skip("H5")) }
                    case .otherVMsRunning(let names):
                        if let refusal = Reconfigure.otherVMsRefusal(screen.vm ?? "the VM", changed: false, others: .success(names)) {
                            Text(refusal.title).font(.headline)
                            Text(refusal.detail)
                        }
                        Text(SetupCopy.markdown(SetupCopy.Finish.afterRefusal))
                        Button(SetupCopy.Finish.bKeepScreen) { keepScreen(facts) }
                    case .couldNotConfirm(let reason):
                        Text(reason)
                        Text("Winbar couldn't confirm that it is safe to restart UTM.")
                        Text(SetupCopy.markdown(SetupCopy.Finish.afterRefusal))
                        Button(SetupCopy.Finish.bKeepScreen) { keepScreen(facts) }
                    case .staged:
                        Text("Headless is chosen. Apply the changes below to restart the VM.")
                        Button(SetupCopy.Finish.bKeepScreen) { send(.discardChanges("H5")) }
                    case .alreadyHeadless: Text("The VM is already running without its own screen.")
                    case .kept: Text("The VM will keep its screen.")
                    case .notOffered, .connectSkipped, .waitingForConnect:
                        Text(SetupCopy.markdown(SetupCopy.Finish.notOffering))
                    case .notReady: Text("The VM will keep its screen; Remote Desktop isn't ready for headless mode.")
                    case .notChecked, .checkOtherVMs: Text("Checking whether it is safe to offer headless mode…")
                    }
                    if !screen.restart.isEmpty {
                        Text(SetupCopy.Finish.oneRestart(of: "“\(screen.vm ?? "the VM")”", applies: screen.restart.summary))
                        action("Apply Changes and Restart", .applyChanges).buttonStyle(.borderedProminent)
                        Button("Discard Changes and Finish Without Restarting") { send(.discardChanges(nil)) }
                        Text("If Winbar can't verify BitLocker or Windows won't shut down, it stops safely. You can discard these unapplied changes and finish with the current settings.").font(.caption)
                    }
                }
            }
        }
    }

    private func keepScreen(_ facts: SetupFlow.Facts) {
        if facts.pending.display != nil { send(.discardChanges("H5")) }
        else { send(.skip("H5")) }
    }
}

/// Keep the result visible after the action button disappears. The word and symbol carry the
/// meaning together; colour alone cannot distinguish a successful check from a skipped one.
struct SetupTuneStatusLabel: View {
    let status: SetupTuneStatus

    var body: some View {
        withSetupAppearance { look in
            Label(SetupCopy.Tune.status(status), systemImage: status.symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(color(look))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(SetupCopy.Tune.status(status))
        }
    }

    private func color(_ look: SetupAppearance) -> Color {
        switch status {
        case .verified, .checking, .applying: return look.accentText
        case .needsAttention, .pendingRestart: return look.palette.attention.color
        case .skipped, .information, .notChecked: return look.mutedText
        }
    }
}
