import SwiftUI

/// The VM step uses the same selection rules as setup and never creates a second install owner.
///
/// Its main action — **Install Windows…**, **Use “…”**, **Start It**, **Continue** — is the footer's corner
/// (`footerAction`), where steps 0 and 1 put theirs: on this step it used to be a smaller button in
/// the card, on the right on one page and the left on the next, with the corner holding **Check
/// Again**. What else the page offers sits in one row at the foot of its card (`alternatives`), never
/// a column of equal buttons.
struct SetupVMView: View {
    let state: SetupWindowState
    /// Armie, when `ArmieCue.cue` puts him on this page: under the card and the wait he narrates.
    var armie: ArmieCue? = nil
    var art: ArmieArt? = nil
    let send: (SetupCommand) -> Void
    /// The palette's red: the system's measured 3.2:1 on the light backdrop.
    @Environment(\.errorText) private var errorText
    /// The palette's quieter grey, for the lines under a spinner: `ProgressView("…")` draws its label
    /// in the system's secondary grey, which measured 3.7:1 on the light backdrop.
    @Environment(\.quietText) private var quiet

    /// The page the card shows: the picker again after **Choose Another VM**, otherwise the step's
    /// own screen. Shared with `ArmieCue`, so he is placed by the page that is drawn. Pure.
    static func screen(_ state: SetupWindowState, _ facts: SetupFlow.Facts) -> SetupFlow.VMScreen {
        if state.choosingAnotherVM, case .listed(let list) = facts.vms {
            return .choose(SetupFlow.choice(in: list), previous: nil)
        }
        return SetupFlow.vm(facts)
    }

    // MARK: What the page offers

    /// A button the page draws, as a value, so a test can read the page's offer without drawing it.
    struct Action: Equatable {
        var title: String
        var command: SetupCommand
    }

    /// Whether the start's wait is what's in flight: the card then says so, and nothing that can't be
    /// pressed until it ends is drawn greyed out beside it.
    static func starting(_ state: SetupWindowState) -> Bool {
        if case .startVM? = state.inFlight?.work { return true }
        return false
    }

    /// The VMs to choose between as rows, or none where the page names its one VM in a sentence.
    /// **Which VM?** lists every VM Winbar can manage; so does **One Windows VM** when UTM has others
    /// beside it, so the person sees what else there is and that Winbar picked the Windows one. Pure.
    static func rows(_ screen: SetupFlow.VMScreen, _ facts: SetupFlow.Facts) -> [VMInfo] {
        guard case .choose(let choice, _) = screen else { return [] }
        switch choice {
        case .none: return []
        case .several(let vms): return vms
        case .one:
            guard case .listed(let list) = facts.vms else { return [] }
            let choosable = VMInfo.choosable(list)
            return choosable.count > 1 ? choosable : []
        }
    }

    /// The row a list's **Use** would choose: the one the person ticked, or before they tick one, the
    /// only VM marked Windows — the one `winbar setup` would take without asking — so the likeliest
    /// answer is one Return away. With two Windows VMs nothing is ticked for them. Pure.
    static func picked(_ state: SetupWindowState, in rows: [VMInfo]) -> VMInfo? {
        if let id = state.pickedVM, let vm = rows.first(where: { $0.id == id }) { return vm }
        let windows = rows.filter(\.isWindows)
        return windows.count == 1 ? windows[0] : nil
    }

    /// What the step hands the footer's corner (`SetupFooter.stepAction`): the page's way forward,
    /// filled and on Return while it can be pressed. Nil while there's nothing to press — the step's
    /// own read, the look after an install, and the start's wait, which ends by itself. Pure.
    static func footerAction(_ state: SetupWindowState) -> SetupFooter.Button? {
        guard state.step == .vm, !state.creating, state.afterInstall == nil, let facts = state.facts else { return nil }
        let idle = state.inFlight == nil
        func corner(_ title: String, _ command: SetupCommand, enabled: Bool = true) -> SetupFooter.Button {
            SetupFooter.Button(title, command, enabled: idle && enabled, kind: .primary)
        }
        let screen = screen(state, facts)
        switch screen {
        case .unlisted:
            return corner(SetupCopy.VM.bGoBack, .back)
        case .installing:
            return corner(SetupCopy.VM.bShowInstallProgress, .newWindowsVM)
        case .choose(let choice, _):
            let rows = rows(screen, facts)
            if !rows.isEmpty {
                guard let vm = picked(state, in: rows) else {
                    // Greyed out, and so never the default, until a row is ticked: it says what the rows
                    // are for, and the line beside it says what it waits for.
                    return SetupFooter.Button(SetupCopy.VM.bUseThisOne, .useVM(name: "", id: ""), enabled: false,
                                              kind: .primary, reason: SetupCopy.VM.pickFirst)
                }
                // A ticked VM that doesn't say it's Windows: the caution under the list says to install
                // Windows in a new VM instead, so that is the corner, as for a lone such VM, and its Use
                // waits in the card, plain. Return adopted the Linux VM the caution warned against.
                return vm.isWindows ? corner(use(vm).title, use(vm).command) : corner(SetupCopy.VM.bMakeNew, .newWindowsVM)
            }
            switch choice {
            case .none, .several: return corner(SetupCopy.VM.bMakeOne, .newWindowsVM)
            // One VM that doesn't say it's Windows: making a Windows one is the likelier way on.
            case .one(let vm): return vm.isWindows ? corner(use(vm).title, use(vm).command)
                                                   : corner(SetupCopy.VM.bMakeNew, .newWindowsVM)
            }
        case .stopped(let vm):
            return starting(state) ? nil : corner(SetupCopy.VM.bStartIt, .startVM(vm.name))
        case .ready:
            return corner(SetupCopy.journeyNext(.vm, facts: facts), .continueFromVM)
        }
    }

    /// The page's other ways on, in one row at the foot of its card. Pure.
    static func alternatives(_ state: SetupWindowState, _ screen: SetupFlow.VMScreen,
                             _ facts: SetupFlow.Facts) -> [Action] {
        let makeNew = Action(title: SetupCopy.VM.bMakeNew, command: .newWindowsVM)
        let another = Action(title: SetupCopy.VM.bChooseAnother, command: .chooseAnotherVM)
        switch screen {
        case .unlisted, .installing, .choose(.none, _):
            return []
        case .choose(.one(let vm), _):
            let rows = rows(screen, facts)
            if rows.isEmpty { return vm.isWindows ? [makeNew] : [use(vm)] }
            if let picked = picked(state, in: rows), !picked.isWindows { return [use(picked)] }
            return [makeNew]
        case .choose(.several, _):
            if let picked = picked(state, in: rows(screen, facts)), !picked.isWindows { return [use(picked)] }
            return [makeNew]
        case .stopped:
            return starting(state) ? [] : [makeNew, another]
        case .ready:
            return [makeNew, another]
        }
    }

    /// The VM whose **Use** is on the page as the way on, for the sentence that names it: the lone
    /// VM (in the corner, or in the card when it isn't known to be Windows), or the ticked row when it
    /// is Windows. Nil where the ticked row isn't Windows, or none is ticked. Pure.
    static func useNamed(_ state: SetupWindowState, _ screen: SetupFlow.VMScreen, _ facts: SetupFlow.Facts) -> String? {
        guard case .choose(.one(let vm), _) = screen else { return nil }
        let rows = rows(screen, facts)
        if rows.isEmpty { return vm.name }
        return picked(state, in: rows).flatMap { $0.isWindows ? $0.name : nil }
    }

    private static func use(_ vm: VMInfo) -> Action {
        Action(title: String(SetupCopy.VM.bUse(vm.name).characters), command: .useVM(name: vm.name, id: vm.id))
    }

    // MARK: Drawing

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // First, where a press that didn't start is explained: this step said nothing, so a refused
            // Use or Start It looked like a button that did nothing.
            if let refusal = state.refusal {
                RefusalBanner(text: SetupCopy.Working.refused(refusal, busy: state.inFlight, host: "Winbar"))
            }
            if state.afterInstall != nil {
                waiting(SetupCopy.VM.afterInstall)
            } else if let facts = state.facts {
                let screen = SetupVMView.screen(state, facts)
                SetupCard {
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 12) {
                            page(screen, facts)
                            // What Start It will do, before the corner's Start It rather than under a
                            // column of buttons below it.
                            if facts.utmRestartOwed, !facts.vmRunning, let vm = facts.chosenVM {
                                Text(SetupCopy.Working.restartOwed(vm: vm)).setupProse()
                            }
                            let others = SetupVMView.alternatives(state, screen, facts)
                            if !others.isEmpty {
                                HStack(spacing: 10) {
                                    ForEach(Array(others.enumerated()), id: \.offset) { _, action in
                                        Button { send(action.command) } label: { Text(verbatim: action.title) }
                                    }
                                }
                                .padding(.top, 4)
                            }
                        }
                        .disabled(state.inFlight != nil)
                        // The start's wait, in the card it belongs to, with its way out: outside the
                        // greyed-out part, since it is the one thing that can be pressed meanwhile.
                        if let flight = state.inFlight, SetupVMView.starting(state) {
                            startWait(flight)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                waiting("Looking for a Windows VM…")
            }
            if let flight = state.inFlight, !(SetupVMView.starting(state) && state.facts != nil) {
                waiting(flight.line.map(SetupCopy.Working.windowLine) ?? "Asking UTM…")
            }
            // After what he narrates — the empty card, or the start's own progress line — so he never
            // stands between the person and the step's button or the line saying what's happening.
            if let armie, let art {
                ArmieSays(line: armie.line, art: art, clip: armie.clip, send: send)
            }
            // While it still stands: a start that failed says nothing once the VM runs.
            if let problem = state.standingFailure {
                Text(problem.description).foregroundStyle(errorText).textSelection(.enabled)
            }
            ForEach(Array(state.installMessages.enumerated()), id: \.offset) { _, message in
                SetupInstallNote(message: message, setupDisk: state.setupDisk, send: send)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func page(_ screen: SetupFlow.VMScreen, _ facts: SetupFlow.Facts) -> some View {
        switch screen {
        case .unlisted:
            CardTitle(SetupCopy.VM.unlistedHeading)
            Text(SetupCopy.markdown(SetupCopy.VM.unlisted)).setupProse()
        case .installing:
            CardTitle(SetupCopy.VM.installingHeading)
            Text(SetupCopy.markdown(SetupCopy.VM.installing)).setupProse()
        case .choose(let choice, let previous):
            if let previous { Text(SetupCopy.VM.previous(previous)).setupProse() }
            switch choice {
            case .none:
                CardTitle(SetupCopy.VM.noneHeading)
                ForEach(SetupCopy.VM.noneBody, id: \.self) { Text($0).setupProse() }
            case .one(let vm):
                CardTitle(vm.isWindows ? SetupCopy.VM.oneHeading : "One virtual machine")
                Text(SetupCopy.VM.oneBody(vm.name, windows: vm.isWindows, use: SetupVMView.useNamed(state, screen, facts)))
                    .setupProse()
                choices(screen, facts, fallback: vm)
            case .several(let vms):
                CardTitle(SetupCopy.VM.severalHeading)
                Text(SetupCopy.VM.severalBody(count: vms.count)).setupProse()
                choices(screen, facts, fallback: nil)
            }
        case .stopped(let vm):
            if SetupVMView.starting(state) {
                // Start It pressed: the card says what's happening now, not "isn't running" above
                // buttons that nothing can press until the start ends. The line under the card says
                // how long it waits.
                CardTitle(SetupCopy.VM.startingHeading(vm.name))
            } else {
                CardTitle(SetupCopy.VM.stoppedHeading)
                Text(SetupCopy.VM.stopped(vm.name)).setupProse()
            }
        case .ready(let vm):
            CardTitle(SetupCopy.VM.readyHeading)
            Text(SetupCopy.VM.ready(vm.name)).setupProse()
        }
    }

    /// The list's rows, when the page has them, and the caution for a choice that doesn't say it's
    /// Windows — the ticked row, or the page's one VM.
    @ViewBuilder private func choices(_ screen: SetupFlow.VMScreen, _ facts: SetupFlow.Facts, fallback: VMInfo?) -> some View {
        let rows = SetupVMView.rows(screen, facts)
        let picked = rows.isEmpty ? fallback : SetupVMView.picked(state, in: rows)
        if !rows.isEmpty {
            VMChoiceList(vms: rows, picked: picked?.id) { send(.pickVM($0)) }
        }
        if let picked, !picked.isWindows {
            Text(SetupCopy.markdown(SetupCopy.VM.notKnownWindows)).setupProse()
        }
    }

    /// The start's wait: a small spinner beside the line saying what it waits for and how long it can
    /// take, and **Stop Waiting**, which every other step's long wait already had. The line is the
    /// window's wording of what the start says (`Working.windowLine`).
    @ViewBuilder private func startWait(_ flight: SetupRunner.InFlight) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            ProgressView().controlSize(.small).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            Text(SetupCopy.Working.windowLine(flight.line ?? SetupCopy.waitingForWindows))
                .foregroundStyle(quiet)
                .setupProse()
        }
        if flight.canStopWaiting {
            StopWaitingRow(work: flight.work) { send(.stopWaiting) }
        }
    }

    /// A spinner over the line saying what it waits for, the line in the palette's quiet grey rather
    /// than the secondary grey `ProgressView(_:)` gives its label.
    private func waiting(_ line: String) -> some View {
        ProgressView { Text(line).foregroundStyle(quiet) }
    }
}

/// The VMs to choose between, as System Settings lists choices: one inset group, a row per VM with
/// its name over what it is and how it stands, and a radio mark saying which is ticked. It was a
/// pop-up reading "Choose a VM…", which showed neither what the choices were nor that one was
/// likelier than the others.
struct VMChoiceList: View {
    let vms: [VMInfo]
    let picked: String?
    let pick: (String) -> Void

    var body: some View {
        withSetupAppearance { look in
            let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
            VStack(spacing: 0) {
                ForEach(Array(vms.enumerated()), id: \.element.id) { index, vm in
                    if index > 0 { Rectangle().fill(look.stroke).frame(height: 1).padding(.leading, 40) }
                    VMChoiceRow(vm: vm, selected: vm.id == picked) { pick(vm.id) }
                }
            }
            .clipShape(shape)
            .overlay { shape.strokeBorder(look.stroke, lineWidth: look.increasedContrast ? 1.5 : 1) }
            .frame(maxWidth: SetupStyle.textWidth, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(SetupCopy.VM.severalHeading)
    }
}

/// One VM in `VMChoiceList`: the whole row is the button, as a Settings row is.
struct VMChoiceRow: View {
    let vm: VMInfo
    let selected: Bool
    let press: () -> Void
    @Environment(\.quietText) private var quiet

    /// What VoiceOver says for the row: the name and the line under it, as one sentence. Pure.
    static func spoken(_ vm: VMInfo) -> String {
        [vm.name, SetupCopy.VM.rowDetail(vm)].compactMap { $0 }.joined(separator: ", ")
    }

    var body: some View {
        Button(action: press) {
            withSetupAppearance { look in
                HStack(spacing: 12) {
                    // The accent is for what can be pressed; the ring is how a Mac draws a radio choice.
                    Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 16))
                        .foregroundStyle(selected ? look.accentText : quiet)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: vm.name).fontWeight(.semibold)
                        if let detail = SetupCopy.VM.rowDetail(vm) {
                            Text(detail).font(.system(size: SetupStyle.smallestText)).foregroundStyle(quiet)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .background(selected ? look.accentText.opacity(0.08) : Color.clear)
            }
        }
        .buttonStyle(.plain)
        // The ring is drawn, not read: VoiceOver says which row is ticked as a selected button.
        .accessibilityLabel(Self.spoken(vm))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

// MARK: - What the install left behind

/// One of the notes an install handed back, as a callout: a warning in the attention tone (the ones
/// the install window boxes, `CreateProgress.boxedCodes`), anything else as information. The setup
/// disk the install couldn't delete says so in the window's words and offers the two things to do
/// about it, where it said "delete the folder yourself" without saying where it was.
struct SetupInstallNote: View {
    let message: CreateMessage
    let setupDisk: String?
    let send: (SetupCommand) -> Void

    var body: some View {
        if message.code == SetupDiskActions.leftCode, setupDisk != nil {
            Callout(.attention) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(SetupCopy.VM.setupDiskLeft)
                    HStack(spacing: 10) {
                        Button(SetupCopy.VM.bShowSetupDisk) { send(.showSetupDisk) }
                        Button(SetupCopy.VM.bTrashSetupDisk) { send(.trashSetupDisk) }
                    }
                }
            }
        } else {
            // As said, never as Markdown: a note can quote a path or an error.
            Callout(SetupInstallNote.tone(message.code), message.text).textSelection(.enabled)
        }
    }

    /// The install's warnings are W_ codes, its notes N_ ones (CreateJobRun's `message`).
    static func tone(_ code: String) -> Callout<Text>.Tone { code.hasPrefix("W_") ? .attention : .info }
}

/// What step 2 does to the setup disk an install couldn't delete, as functions, so a test can hand it
/// its own and nothing reaches the Finder or the Trash.
struct SetupDiskActions {
    /// The job's warning that the setup disk is still there (`CreateRun.deleteMedia`).
    static let leftCode = "W_MEDIA_LEFT"
    /// The note that replaces it once the disk is in the Trash, and the one added when it couldn't be.
    static let trashedCode = "N_MEDIA_TRASHED"
    static let notTrashedCode = "W_MEDIA_NOT_TRASHED"

    /// Where the job folders live: only a folder `create` made there is ever moved.
    var base: () -> URL
    var reveal: (URL) -> Void
    var trash: (URL) throws -> Void

    static let live = SetupDiskActions(
        base: { SetupMedia.defaultBase },
        reveal: { NSWorkspace.shared.activateFileViewerSelecting([$0]) },
        trash: { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) })

    /// The state after **Move to Trash**. The folder goes only when it is one `create` made — in its
    /// folder, named for a job, private, with its marker (`SetupMedia.ownershipProblem`) — so a state
    /// naming any other path moves nothing. Once it's in the Trash the warning becomes a note that
    /// says so, and that emptying the Trash is what deletes it; if it couldn't be moved, the warning
    /// and its buttons stay, with why.
    static func trashing(_ state: SetupWindowState, with actions: SetupDiskActions) -> SetupWindowState {
        guard let disk = state.setupDisk else { return state }
        var next = state
        next.installMessages.removeAll { $0.code == notTrashedCode }
        let url = URL(fileURLWithPath: disk, isDirectory: true)
        let problem: String?
        if let reason = SetupMedia.ownershipProblem(url, base: actions.base()) {
            problem = reason
        } else {
            do {
                try actions.trash(url)
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
        }
        let now = Date()
        if let problem {
            next.installMessages.append(CreateMessage(code: notTrashedCode, text: SetupCopy.VM.setupDiskNotTrashed(problem), at: now))
            return next
        }
        next.setupDisk = nil
        next.installMessages = next.installMessages.map {
            $0.code == leftCode ? CreateMessage(code: trashedCode, text: SetupCopy.VM.setupDiskTrashed, at: now) : $0
        }
        return next
    }
}
