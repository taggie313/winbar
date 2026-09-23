import SwiftUI

/// The VM step uses the same selection rules as setup and never creates a second install owner.
struct SetupVMView: View {
    let state: SetupWindowState
    /// Armie, when `ArmieCue.cue` puts him on this page: under the card and the wait he narrates.
    var armie: ArmieCue? = nil
    var art: ArmieArt? = nil
    let send: (SetupCommand) -> Void

    /// The page the card shows: the picker again after **Choose Another VM**, otherwise the step's
    /// own screen. Shared with `ArmieCue`, so he is placed by the page that is drawn. Pure.
    static func screen(_ state: SetupWindowState, _ facts: SetupFlow.Facts) -> SetupFlow.VMScreen {
        if state.choosingAnotherVM, case .listed(let list) = facts.vms {
            return .choose(SetupFlow.choice(in: list), previous: nil)
        }
        return SetupFlow.vm(facts)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if state.afterInstall != nil {
                ProgressView(SetupCopy.VM.afterInstall)
            } else if let facts = state.facts {
                SetupCard {
                    VStack(alignment: .leading, spacing: 12) {
                        page(SetupVMView.screen(state, facts))
                        if facts.utmRestartOwed, !facts.vmRunning, let vm = facts.chosenVM {
                            Text(SetupCopy.Working.restartOwed(vm: vm))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .disabled(state.inFlight != nil)
                }
            } else {
                ProgressView("Looking for a Windows VM…")
            }
            if let flight = state.inFlight {
                ProgressView(flight.line ?? "Asking UTM…")
            }
            // After what he narrates — the empty card, or the start's own progress line — so he never
            // stands between the person and the step's button or the line saying what's happening.
            if let armie, let art {
                ArmieSays(line: armie.line, art: art, clip: armie.clip, send: send)
            }
            if case .failed(let problem)? = state.lastEnding?.outcome {
                Text(problem.description).foregroundStyle(.red).textSelection(.enabled)
            }
            ForEach(Array(state.installMessages.enumerated()), id: \.offset) { _, message in
                SetupCard { Text(message.text).textSelection(.enabled) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func page(_ screen: SetupFlow.VMScreen) -> some View {
        switch screen {
        case .unlisted:
            Text("Check UTM first").font(.headline)
            Text("Winbar hasn't received UTM's VM list. Choose Back to check that UTM is installed and allowed to answer Winbar.")
        case .installing:
            Text(SetupCopy.VM.installingHeading).font(.headline)
            Text(SetupCopy.markdown(SetupCopy.VM.installing))
            primary(SetupCopy.VM.bShowInstallProgress, .newWindowsVM)
        case .choose(let choice, let previous):
            if let previous { Text(SetupCopy.VM.previous(previous)) }
            switch choice {
            case .none:
                Text(SetupCopy.VM.noneHeading).font(.headline)
                ForEach(SetupCopy.VM.noneBody, id: \.self) { Text($0) }
                primary(SetupCopy.VM.bMakeOne, .newWindowsVM)
            case .one(let vm):
                Text(vm.isWindows ? SetupCopy.VM.oneHeading : "One virtual machine").font(.headline)
                Text(SetupCopy.VM.oneBody(vm.name, windows: vm.isWindows))
                if !vm.isWindows { Text(SetupCopy.VM.notKnownWindows) }
                HStack {
                    if vm.isWindows { Button(SetupCopy.VM.bMakeNew) { send(.newWindowsVM) } }
                    else { primary(SetupCopy.VM.bMakeNew, .newWindowsVM) }
                    Spacer()
                    if vm.isWindows {
                        Button { send(.useVM(name: vm.name, id: vm.id)) } label: { Text(SetupCopy.VM.bUse(vm.name)) }
                            .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    } else {
                        Button { send(.useVM(name: vm.name, id: vm.id)) } label: { Text(SetupCopy.VM.bUse(vm.name)) }
                    }
                }
            case .several(let vms):
                Text(SetupCopy.VM.severalHeading).font(.headline)
                Text(SetupCopy.VM.severalBody(count: vms.count))
                Picker("Virtual machine", selection: Binding(get: { state.pickedVM ?? "" }, set: { send(.pickVM($0)) })) {
                    Text("Choose a VM…").tag("")
                    ForEach(vms, id: \.id) { vm in Text(vm.name).tag(vm.id) }
                }
                HStack {
                    Button(SetupCopy.VM.bMakeNew) { send(.newWindowsVM) }
                    Spacer()
                    Button(SetupCopy.VM.bUseThisOne) {
                        if let vm = vms.first(where: { $0.id == state.pickedVM }) { send(.useVM(name: vm.name, id: vm.id)) }
                    }
                    .disabled(!vms.contains { $0.id == state.pickedVM })
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            }
        case .stopped(let vm):
            if case .startVM? = state.inFlight?.work {
                // Start It pressed: the card says what's happening now, not "isn't running" above three
                // greyed-out buttons that nothing can press until the start ends.
                // The heading alone: the progress line under the card says how long it waits.
                Text(SetupCopy.VM.startingHeading(vm.name)).font(.headline)
            } else {
                Text(SetupCopy.VM.stoppedHeading).font(.headline)
                Text(SetupCopy.VM.stopped(vm.name))
                primary(SetupCopy.VM.bStartIt, .startVM(vm.name))
                Button(SetupCopy.VM.bMakeNew) { send(.newWindowsVM) }
                Button(SetupCopy.VM.bChooseAnother) { send(.chooseAnotherVM) }
            }
        case .ready(let vm):
            Text(SetupCopy.VM.readyHeading).font(.headline)
            Text(SetupCopy.VM.ready(vm.name))
            primary(SetupCopy.LookAround.bContinue, .continueFromVM)
            Button(SetupCopy.VM.bMakeNew) { send(.newWindowsVM) }
            Button(SetupCopy.VM.bChooseAnother) { send(.chooseAnotherVM) }
        }
    }

    private func primary(_ title: String, _ command: SetupCommand) -> some View {
        Button(title) { send(command) }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
    }
}
