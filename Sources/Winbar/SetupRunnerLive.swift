import AppKit
import Foundation

/// The runner's real machine: the setup window's one `Context`, and every call that does something
/// to the Mac. `SetupRunner` calls it only on its queue, one call at a time, which is the whole of
/// what keeps `Context` — a lazily-caching class written for one thread — safe here.
///
/// Deliberately thin, and not unit-tested: it is the part that reaches UTM, Windows and macOS. Each
/// work item is a call into code `winbar setup` already runs (`UTM.start`, `Setup.waitForWindows`,
/// the recipe's own `apply`, `Setup.savePC`, `Reconfigure.apply`), and every decision around it —
/// what a snapshot reads (`SetupRunner.readPlan`), which rows it builds itself (`SetupRunner.row`),
/// whether the work still applies, what the snapshot says, what a window is told afterwards — is
/// one of the runner's pure functions, which are tested. What is left here fetches values.
final class LiveSetupMachine: SetupMachine {
    /// The questions `Reconfigure.apply` asks mid-restart, which only a window can put to a person.
    /// The window passes alerts (step 7's commit); until then nothing is risked: an unverified
    /// BitLocker stops the change, and a slow shutdown stops Winbar waiting rather than forcing
    /// anything — what the terminal does when there is nobody at it.
    struct Questions {
        var confirmUnverifiedBitLocker: (String) -> Bool
        var offerForceStop: (String) -> UTM.ForceStopChoice

        static let unattended = Questions(confirmUnverifiedBitLocker: { _ in false },
                                          offerForceStop: { _ in .giveUp })
    }

    private let questions: Questions
    private var ctx: Context!
    /// The work in flight, for the `Context`'s progress lines (the survey's "Asking Windows…").
    private var job: SetupRunner.Job?
    /// What utmctl said to the last **Open UTM and Ask**, or to a read since. A utmctl that said nothing
    /// for a minute is not asked again by a mere re-read (twenty more seconds of nothing, and every
    /// Apple Event after it would wait out a timeout of its own); only pressing **Try Again** asks
    /// again. Any other answer is asked again (`SetupRunner.reasksUTM`).
    private var settled: UTM.CtlAnswer?
    /// The host whose saved-PC tile the last Connect pressed (`Connection.openDesktop` answered true),
    /// or nil after a one-off connection: what the window pairs with the person's answer to "Did the
    /// Windows desktop appear?" (`Recipe.connectedSavedPC`). Forgotten when the chosen VM changes.
    private var pressedSavedPC: String?

    init(questions: Questions = .unattended) {
        self.questions = questions
        ctx = Context(options: SetupRunner.contextOptions, progress: { [weak self] line in self?.job?.say(line) })
    }

    // MARK: - Reading

    func readings(through step: WizardStep, answers: SetupFlow.Answers, after work: SetupRunner.Work?,
                  job: SetupRunner.Job?) -> SetupRunner.Readings {
        self.job = job
        defer { self.job = nil }
        let changed = ctx.adoptSelection(name: Config.vmName, id: Config.vmID)
        // A name-keyed selection can acquire its UTM id in the snapshot. Don't turn that id back
        // into a name token on every read and erase the same VM's answers. The snapshot binds it.
        let answers = changed ? answers.forVM(ctx.vmID ?? ctx.vmName.map { "name:" + $0 }) : answers
        let step: WizardStep = changed ? .vm : step
        if changed { pressedSavedPC = nil }
        forget(after: work)

        var readings = SetupRunner.Readings()
        readings.utm = Dependencies.state(of: .utm)
        readings.homebrew = Homebrew.path
        readings.utmFromHomebrew = Homebrew.hasCask(Dependency.utm.cask, brew: readings.homebrew)
        readings.windowsApp = Dependencies.state(of: .windowsApp)
        readings.installRunning = CreateJob.current().map { !$0.isFinished } ?? false
        readings.pendingRestart = Config.pendingUTMRestart
        readings.chosenVM = ctx.vmName
        readings.chosenID = ctx.vmID
        readings.declined = SetupFlow.Declined(autologon: ctx.declinedAutologon, remoteDesktop: ctx.declinedRemoteDesktop,
                                               tuning: ctx.declinedTuning)
        readings.keepBitLocker = ctx.keepBitLocker
        readings.pending = ctx.pending

        // A getxattr, so it costs nothing to read before UTM is asked anything: step 1's card needs it
        // to predict macOS's "downloaded from the internet" question, which `UTM.open()` can raise for
        // a copy Homebrew installed, before the first Apple Event.
        if readings.utm.isInstalled { readings.utmQuarantined = Quarantine.isMarked(UTM.appURL?.path) }

        var plan = SetupRunner.readPlan(through: step, readings: readings, answers: answers, utmUp: UTM.isAppRunning,
                                        settled: settled, consent: { Automation.consent(bundleID: Config.utmBundleID) })
        if plan.asksUTM {
            if let settled, !settled.isAnswered,
               !SetupRunner.reasksUTM(after: settled, justAsked: work == .settleUTM,
                                      consent: { Automation.consent(bundleID: Config.utmBundleID) }) {
                ctx.noteUTMCtl(settled)
            }
            let answer = ctx.utmctl
            // What UTM says now is what the next read goes by: a refusal lifted in System Settings stays
            // lifted, and a UTM that has gone quiet since isn't asked again by a mere re-read.
            if settled != nil { settled = answer }
            readings.utmAnswers = answer
            if answer.isAnswered {
                readings.vms = ctx.vms
            } else {
                readings.utmConsent = Automation.consent(bundleID: Config.utmBundleID)
                plan = plan.utmSilent
            }
        }

        for id in plan.checks {
            if let row = SetupRunner.row(for: id, readings: readings) {
                readings.statuses[id] = row
            } else if let check = Recipe.check(id) {
                readings.statuses[id] = ctx.status(of: check)
            }
        }
        let readWindows = plan.checks.contains("G0")
        if readWindows {
            readings.guestAnswers = ctx.guestOutput != nil
            // What `winbar setup` does after its first report: the host and user Windows gave are
            // remembered, or the menu's Connect would have nothing to connect to.
            Setup.fillDefaults(ctx, say: { _ in })
        }
        // The guest's word only when the guest was read: asking for it otherwise starts a survey.
        readings.rdpHost = readWindows ? ctx.rdpHost : (ctx.isConfiguredVM ? Config.rdpHost : nil)
        readings.rdpUser = readWindows ? ctx.rdpUser : (ctx.isConfiguredVM ? Config.rdpUser : nil)

        if case .fixable? = readings.statuses["G9"] {
            let (places, seen) = Setup.whereTheDiskIs(ctx)
            readings.disk = SetupFlow.Disk(imagesSeen: seen, places: places.map {
                SetupFlow.Disk.Place(storage: $0, encrypted: Host.encryptedAtRest($0))
            })
        }
        if plan.windowsAppRunning { readings.windowsAppRunning = WindowsAppBookmarks.appIsRunning }
        readings.savedPCPressed = pressedSavedPC
        if plan.readiness {
            // UTM's word on the MAC only when UTM may be asked; the process's and the remembered one
            // otherwise, which `vmMAC` falls back to anyway.
            let mac = plan.asksUTM ? ctx.vmMAC : (ctx.process?.mac ?? (ctx.isConfiguredVM ? Config.vmMAC : nil))
            readings.readiness = RDP.probeNow(mac: mac)
        }
        if plan.otherVMs, let vm = ctx.vmName {
            readings.otherVMs = UTM.otherRunningVMs(than: vm, id: ctx.vm?.id)
        }
        return readings
    }

    /// Drops what `work` can have changed, and nothing else: a Fix's re-read shouldn't cost a fresh
    /// VM list, nor a saved PC a fresh survey. A look nobody pressed drops the one cache it names
    /// (`SetupRunner.Forget`). nil — the runner's own re-read after a wake, or anything having
    /// happened while the work ran — drops everything. `SetupRunner.execute` decides which.
    private func forget(after work: SetupRunner.Work?) {
        switch work {
        case .lookAgain(_, let forget)?:
            switch forget {
            case .statuses: ctx.forgetStatuses()
            case .utm: ctx.forgetUTM()
            case .guest: ctx.refreshGuest()
            case .selfTest: ctx.forgetSelfTest()
            }
        case .fix(let id)?, .recordDone(let id)?, .guide(let id)?:
            if let check = Recipe.check(id) { ctx.refresh(after: check) } else { ctx.refreshAll() }
        case .survey?, .fixEverything?, .keepBitLocker?, .discardChanges?:
            ctx.refreshGuest()
        case .trustCertificate?:
            // H7 is a host row, read from the certificate the survey already has.
            if let check = Recipe.check("H7") { ctx.refresh(after: check) }
        case .savePC?, .connect?:
            if let check = Recipe.check("C2") { ctx.refresh(after: check) }
        case nil, .checkAgain?, .installUTM?, .installWindowsApp?, .settleUTM?, .chooseVM?, .startVM?, .applyChanges?:
            ctx.refreshAll()
        }
    }

    // MARK: - Doing

    func perform(_ work: SetupRunner.Work, password: String?, facts: SetupFlow.Facts, job: SetupRunner.Job) throws {
        self.job = job
        defer { self.job = nil }
        if work.needsFreshFacts, work.step > .lookAround, !work.isSelection,
           selectionChanged(since: facts) {
            throw WinbarError("The selected VM changed", "Check again before continuing. Nothing was changed.")
        }
        switch work {
        case .checkAgain, .lookAgain, .survey:
            // A read, which the runner takes straight after: everything for Check Again, a fresh
            // survey for this (`forget(after:)`). A look never comes here (`SetupRunner.lookAgain`).
            return
        case .installUTM:
            try install(.utm, job)
            // LaunchServices can take a moment to notice an app that has just been copied in.
            waitUntil(timeout: 15, every: 1) { UTM.isInstalled }
        case .installWindowsApp:
            try install(.windowsApp, job)
        case .settleUTM:
            UTM.open()
            settled = UTMFirstUse.settle(progress: job.say)
        case .chooseVM(let name, let id):
            _ = Config.selectVM(name, id: id)
            // vCPUs and memory staged for another VM are that VM's, and would restart this one.
            ctx.adoptSelection(name: name, id: Config.vmID)
        case .startVM(let name):
            if case .failure(let error) = UTM.start(name, id: facts.chosen?.id) { throw error }
            Setup.waitForWindows(name, note: job.say, cancelled: { job.isCancelled })
            // Stopped from the window: the start is ended as a cancel, and the fresh read after it
            // says where Windows has got to.
            try job.checkCancellation()
        case .fix(let id):
            try fix(id, job)
        case .fixEverything:
            var first: WinbarError?
            for id in SetupFlow.fixEverything(facts) {
                do { try fix(id, job) } catch let error as WinbarError { first = first ?? error }
            }
            if let first { throw first }
        case .recordDone(let id):
            Recipe.check(id)?.recordDone?(ctx)
        case .guide(let id):
            Recipe.check(id)?.guide?(ctx)
        case .keepBitLocker:
            guard ctx.isConfiguredVM else { throw WinbarError("The selected VM changed. Check again before continuing.") }
            Config.keepBitLocker = true
        case .discardChanges(let id):
            switch id {
            case "H3": ctx.pending.cpuCores = nil
            case "H4": ctx.pending.memoryMB = nil
            case "H5": ctx.pending.display = nil
            default: ctx.pending = ConfigChanges()
            }
        case .trustCertificate:
            job.say(SetupCopy.Certificate.approval)
            if case .failure(let error) = Recipe.trustCertificate(ctx, abort: { job.isCancelled }) {
                try job.checkCancellation()
                throw error
            }
        case .savePC:
            try save(password: password)
        case .connect:
            pressedSavedPC = nil
            guard let vm = ctx.vmName, let host = ctx.rdpHost else { throw WinbarError("No Windows address is known yet") }
            job.say(SetupCopy.Connecting.waiting)
            let ready = Connection.waitForRemoteDesktop(vm: vm, timeout: 120, cancelled: { job.isCancelled })
            try job.checkCancellation()
            guard ready != .notReady else {
                throw WinbarError(SetupCopy.Connecting.timedOutTitle, SetupCopy.Connecting.timedOut)
            }
            // True only when the saved PC's own tile was pressed; a one-off connection is false.
            if try Connection.openDesktop(host: host, user: ctx.rdpUser) { pressedSavedPC = host }
        case .applyChanges:
            try applyChanges(job)
        }
    }

    func selectionChanged(since facts: SetupFlow.Facts) -> Bool {
        facts.chosenVM != Config.vmName || facts.chosenID != Config.vmID
    }

    private func install(_ dependency: Dependency, _ job: SetupRunner.Job) throws {
        let plan = Dependencies.windowPlan(for: dependency, state: Dependencies.state(of: dependency), brew: Homebrew.path,
                                           brewHasCask: Homebrew.hasCask(dependency.cask, brew: Homebrew.path))
        guard let plan, SetupRunner.actionable(plan) else { return }
        // The press is the yes: the window's button is `DependencyCopy.question` for this plan.
        let result = DependencyInstaller.install(dependency, plan: plan, agreed: true, progress: job.say,
                                                 runner: { tool, arguments, timeout in
                                                     DependencyCommand.runStreaming(tool, arguments, timeout: timeout,
                                                                                    line: job.say)
                                                 })
        switch result {
        case .failure(let error): throw error
        case .success(.refused(let why)): throw WinbarError("Nothing was installed", why)
        case .success(.handedOff): job.say(DependencyCopy.waitingForAppStore(dependency))
        case .success(.installed(let version)): job.say(DependencyCopy.installed(dependency, version: version))
        }
    }

    /// One row's fix. A failure is noted on its row as well as thrown, so it stays where the person
    /// is looking (`Row.failure`).
    private func fix(_ id: String, _ job: SetupRunner.Job) throws {
        guard let check = Recipe.check(id), let apply = check.apply else { return }
        if case .failure(let error) = apply(ctx) {
            job.rowFailed(id, SetupRunner.Problem(error))
            throw error
        }
    }

    private func save(password: String?) throws {
        guard let password, !password.isEmpty else { throw WinbarError("No password was given, so nothing was saved") }
        guard let host = ctx.rdpHost, let user = ctx.rdpUser else {
            throw WinbarError("Winbar doesn't know the PC's name or user yet")
        }
        do {
            _ = try Setup.savePC(ctx, host: host, user: user, password: password)
        } catch let error as WinbarError {
            throw error
        } catch {
            throw WinbarError("Windows App didn't save the PC", "\(error)")
        }
    }

    private func applyChanges(_ job: SetupRunner.Job) throws {
        guard let vm = ctx.vmName else { throw WinbarError("No VM is chosen") }
        let interaction = Interaction(progress: job.say,
                                      confirmUnverifiedBitLocker: questions.confirmUnverifiedBitLocker,
                                      offerForceStop: questions.offerForceStop)
        job.say(SetupCopy.Finish.oneRestart(of: "“\(vm)”", applies: ctx.pending.summary))
        switch Reconfigure.apply(ctx.pending, to: vm, interaction) {
        case .failure(let error):
            // What was staged stays staged, so Check Again or another try carries the same changes.
            throw error
        case .success:
            ctx.pending = ConfigChanges()
            // Stop Waiting ends only this wait (`Work.canStopWaiting`): the restart has finished either
            // way, so it isn't thrown as a cancel, and the window moves on to prove Connect as usual.
            if VMProcesses.isRunning(vm) { Setup.waitForWindows(vm, note: job.say, cancelled: { job.isCancelled }) }
        }
    }
}
