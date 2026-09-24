import AppKit
import SwiftUI
import Testing
import Vision
@testable import Winbar

// Steps 3 to 6 — Tune, the certificate, the saved PC and Connect — after the 0.2.1 polish: each step's
// main action in the footer's corner, one Check Again at most and none once a step is done, a re-read
// when Ben comes back to the window, Tune as a grouped list, one next action per certificate problem,
// and a sentence plus Details where a card led with a paragraph. Every screen is an invented fixture;
// nothing here reaches the Mac's settings, UTM, Windows App or a VM.

/// The journey's screens the design review named that no other fixture list draws.
enum JourneyPolishFixtures {
    static func state(_ step: WizardStep, _ change: (inout SetupWindowState) -> Void) -> SetupWindowState {
        var state = SetupFixtures.state(step, facts: JourneyFixtures.facts)
        change(&state)
        state.facts?.answers = state.answers
        return state
    }

    static var screens: [(String, SetupWindowState)] {
        [("tune-fixable", state(.tune) { $0.facts?.rows["G1"] = JourneyFixtures.row("G1", .fixable("Balanced")) }),
         ("tune-unanswered", state(.tune) { $0.facts?.rows["G3"] = JourneyFixtures.row("G3", .error("Windows did not answer")) }),
         ("tune-staged", state(.tune) { $0.facts?.pending.cpuCores = 6 }),
         ("saved-needs-app", state(.savedPC) { $0.facts?.windowsApp = .missing }),
         ("saved-app-open", state(.savedPC) {
             $0.facts?.rows["C2"] = JourneyFixtures.row("C2", .fixable("No saved PC")); $0.facts?.windowsAppRunning = true
         }),
         ("saved-manual", state(.savedPC) {
             $0.facts?.rows["C2"] = JourneyFixtures.row("C2", .manual("Windows App didn't answer", how: "Add the PC in Windows App"))
         }),
         ("connect-accessibility", state(.connect) {
             $0.facts?.rows["C3"] = JourneyFixtures.row("C3", .manual("Not allowed", how: "Allow access"))
         })]
    }

    static func screen(_ name: String) throws -> SetupWindowState {
        try #require((screens + SetupRecoveryFixtures.screens).first { $0.0 == name }?.1, "no fixture \(name)")
    }
}

@MainActor private func drawn(_ state: SetupWindowState, _ sent: Sent,
                              credentials: SetupCredentials = SetupCredentials()) -> Pressing<SetupScreen> {
    Pressing(SetupScreen(state: state, art: nil, credentials: credentials, savePassword: sent.save, send: sent.send))
}

private func ocr(_ png: Data) throws -> [String] {
    try Drawing.lines(png).map(\.text)
}

// MARK: - The footer's corner

@Suite("Each journey step hands its main action to the footer's corner")
struct JourneyFooterActionTests {
    private func corner(_ state: SetupWindowState) -> SetupFooter.Button? { SetupFooter.footer(state).corner }

    @Test("Tune: Fix Everything when Winbar can fix something; Check Again (asking Windows) when it hasn't yet")
    func tune() throws {
        let fixable = try JourneyPolishFixtures.screen("tune-fixable")
        #expect(corner(fixable) == .init(SetupCopy.Tune.bFixEverything, .perform(.run(.fixEverything)), kind: .primary))
        var unread = fixable
        unread.facts?.rows.removeValue(forKey: "G4")
        #expect(corner(unread) == .init(SetupCopy.bCheckAgain, .perform(.run(.survey)), kind: .primary))
        // A row only Ben can do, with nothing for Fix Everything: the corner is that row's first
        // button, which the row then doesn't draw again.
        let manual = try JourneyPolishFixtures.screen("tune-mixed")
        let facts = try #require(manual.facts)
        let h6 = try #require(facts.rows["H6"])
        let first = try #require(SetupTuneRowActions.of(h6, facts: facts).first)
        #expect(corner(manual) == .init(first.title, first.command, kind: .primary))
        #expect(SetupJourneyActions.tuneRowInCorner(facts)?.rowID == "H6")
    }

    @Test("The certificate: one next action per state, and it is the corner")
    func certificate() throws {
        let approve = SetupFooter.Button(SetupCopy.Certificate.bApprove, .perform(.run(.trustCertificate)), kind: .primary)
        let retry = SetupFooter.Button(SetupCopy.Certificate.bRetry, .perform(.run(.trustCertificate)), kind: .primary)
        let check = SetupFooter.Button(SetupCopy.bCheckAgain, .perform(.run(.checkAgain(.certificate))), kind: .primary)
        #expect(corner(CertificateFixtures.state("initial")) == approve)
        #expect(corner(CertificateFixtures.state("failed")) == retry)
        #expect(corner(CertificateFixtures.state("cancelled")) == retry)
        #expect(corner(CertificateFixtures.state("unverified")) == check)
        // No certificate yet: it's made one step back, and the corner goes there, as the card says.
        let needs = try JourneyPolishFixtures.screen("certificate-needs")
        #expect(SetupCertificatePage.page(needs, facts: try #require(needs.facts)).next == .goBack)
        #expect(corner(needs) == .init(SetupCopy.Certificate.bGoBack, .back, kind: .primary))
        // Skipped is done: Continue Without Approval is the corner and the only filled button.
        let skipped = CertificateFixtures.state("skipped")
        #expect(corner(skipped)?.press == .send(.next) && SetupFooter.footer(skipped).holdsDefault())
    }

    @Test("The saved PC: Save It, Show Windows' Screen, Quit Windows App, the App Store, or sign-in without it")
    func savedPC() throws {
        var save = SetupFixtures.state(.savedPC, facts: JourneyFixtures.facts)
        save.facts?.rows["C2"] = JourneyFixtures.row("C2", .fixable("No saved PC"))
        #expect(corner(save) == .init(SetupCopy.SavedPC.bSaveIt, .savePassword, kind: .primary, reason: SetupCopy.SavedPC.typeFirst))
        #expect(corner(try JourneyPolishFixtures.screen("saved-no-user"))
                == .init(SetupCopy.SavedPC.bShowWindowsScreen, .open(.windowsScreen), kind: .primary))
        #expect(corner(try JourneyPolishFixtures.screen("saved-app-open"))?.press == .send(.quitWindowsApp))
        #expect(corner(try JourneyPolishFixtures.screen("saved-needs-app"))?.press == .send(.perform(.run(.installWindowsApp))))
        #expect(corner(try JourneyPolishFixtures.screen("saved-manual"))?.press == .send(.continueWithoutSavedPC))
    }

    @Test("Connect: Allow Accessibility, then Connect; the desktop question keeps its answers in the card")
    func connect() throws {
        #expect(corner(try JourneyPolishFixtures.screen("connect-accessibility"))?.press == .send(.perform(.run(.guide(checkID: "C3")))))
        #expect(corner(try JourneyPolishFixtures.screen("connect-ready"))
                == .init(SetupCopy.Connecting.bConnect, .perform(.run(.connect)), kind: .primary))
        #expect(SetupJourneyActions.footerAction(JourneyFixtures.didItWork) == nil)
    }

    /// A greyed-out corner nobody can press until the work ends was one more faint button in a row of
    /// them: the footer draws only what can be pressed while work runs.
    @Test("While work runs, the corner's action isn't drawn")
    func busy() throws {
        var fixing = try JourneyPolishFixtures.screen("tune-fixable")
        fixing.inFlight = SetupFixtures.flight(.checkAgain(.tune))
        #expect(SetupJourneyActions.footerAction(fixing)?.enabled == false)
        #expect(corner(fixing) == nil && !SetupFooter.footer(fixing).holdsDefault())
    }
}

@MainActor @Suite("Return presses the corner's action, filled, where the step hands it one")
struct JourneyFooterReturnTests {
    private func returns(_ state: SetupWindowState, credentials: SetupCredentials = SetupCredentials()) throws -> Sent {
        let sent = Sent()
        #expect(drawn(state, sent, credentials: credentials).press(.return))
        let png = try render(state, .light)
        let filled = Drawing.filled(SetupStyle.palette(dark: false, increasedContrast: false).accentFill, in: png)
        #expect(filled.count == 1 && filled.allSatisfy { $0.minY > setupWindowSize.height - setupFooterBand }, "\(filled)")
        return sent
    }

    @Test("Saved PC, no account name yet: Return shows Windows' screen")
    func showScreen() throws {
        #expect(try returns(JourneyPolishFixtures.screen("saved-no-user")).commands == [.open(.windowsScreen)])
    }

    @Test("Certificate, request finished unverified: Return checks again")
    func unverified() throws {
        #expect(try returns(CertificateFixtures.state("unverified")).commands == [.perform(.run(.checkAgain(.certificate)))])
    }

    @Test("Connect, Accessibility off: Return asks for it")
    func accessibility() throws {
        #expect(try returns(JourneyPolishFixtures.screen("connect-accessibility")).commands == [.perform(.run(.guide(checkID: "C3")))])
    }

    @Test("The saved PC's Save It, in the footer, is filled only once something is typed")
    func saveIt() throws {
        var state = SetupFixtures.state(.savedPC, facts: JourneyFixtures.facts)
        state.facts?.rows["C2"] = JourneyFixtures.row("C2", .fixable("No saved PC"))
        let fill = SetupStyle.palette(dark: false, increasedContrast: false).accentFill
        let typed = SetupCredentials()
        typed.password = "synthetic-test-secret"
        let drawnTyped = try #require(Snapshot.png(SetupScreen(state: state, art: nil, credentials: typed, send: { _ in }),
                                                   size: setupWindowSize, appearance: .light))
        let filled = Drawing.filled(fill, in: drawnTyped)
        #expect(filled.count == 1 && filled.allSatisfy { $0.minY > setupWindowSize.height - setupFooterBand }, "\(filled)")
        let sent = Sent()
        #expect(drawn(state, sent, credentials: typed).press(.return))
        #expect(sent.saved == ["synthetic-test-secret"])
        let empty = try render(state, .light)
        #expect(Drawing.filled(fill, in: empty).isEmpty)
    }
}

// MARK: - Check Again

@Suite("The footer's Check Again: not once a step is done (Tune aside), and not beside a retry of the card's own")
struct JourneyCheckAgainTests {
    private func checksAgain(_ state: SetupWindowState) -> Int {
        SetupFooter.footer(state).trailing.filter { $0.title == SetupCopy.bCheckAgain }.count
    }

    /// A done Tune keeps one: its rows are settings in Windows that can change behind its back, and
    /// coming back to the window no longer reads them again, so a fresh look is a press away.
    @Test("Kept on a done Tune, once")
    func doneTune() throws {
        let state = JourneyFixtures.page(.tune)
        #expect(SetupFlow.isSatisfied(.tune, try #require(state.facts)))
        #expect(checksAgain(state) == 1)
        #expect(SetupFooter.footer(state).trailing.first { $0.title == SetupCopy.bCheckAgain }?.press
                    == .send(.perform(.run(.checkAgain(.tune)))))
    }

    @Test("Hidden on a finished step", arguments: ["saved-done", "connect-failed", "connect-failed-answering"])
    func done(name: String) throws {
        let state = try JourneyPolishFixtures.screen(name)
        #expect(SetupFlow.isSatisfied(state.step, try #require(state.facts)))
        #expect(checksAgain(state) == 0)
    }

    @Test("Hidden where the card has its own: a row Windows didn't answer for, the saved PC's Try Again, the desktop question")
    func cardHasOne() throws {
        #expect(checksAgain(try JourneyPolishFixtures.screen("tune-unanswered")) == 0)
        #expect(checksAgain(try JourneyPolishFixtures.screen("saved-manual")) == 0)
        #expect(checksAgain(JourneyFixtures.didItWork) == 0)
        // Where the corner is Check Again, it's there once.
        #expect(checksAgain(CertificateFixtures.state("unverified")) == 1)
    }

    /// The control: a step still to be done, with nothing of its own to retry, keeps it.
    @Test("Kept where the step waits and nothing else re-reads it")
    func kept() throws {
        #expect(checksAgain(CertificateFixtures.state("initial")) == 1)
        #expect(checksAgain(try JourneyPolishFixtures.screen("connect-accessibility")) == 1)
        #expect(checksAgain(try JourneyPolishFixtures.screen("tune-mixed")) == 1)
        var finish = SetupFixtures.state(.finish, facts: JourneyFixtures.facts)
        finish.facts?.rows["H5"] = JourneyFixtures.row("H5", .fixable("Console on"))
        #expect(SetupJourneyActions.footerChecksAgain(finish))
    }

    @Test("The card's retry verbs: Try Again redoes, Check Again re-reads")
    func verbs() throws {
        let manual = try JourneyPolishFixtures.screen("saved-manual")
        #expect(String(SetupCopy.markdown(SetupCopy.SavedPC.manualNext).characters).contains(SetupCopy.bTryAgain))
        guard case .manual = SetupFlow.savedPC(try #require(manual.facts)) else {
            Issue.record("not the manual card")
            return
        }
        let g3 = JourneyFixtures.row("G3", .error("Windows did not answer"))
        let actions = SetupTuneRowActions.of(g3, facts: try #require(JourneyPolishFixtures.screen("tune-unanswered").facts))
        #expect(actions.map(\.title) == [SetupCopy.bCheckAgain, SetupCopy.bSkip])
        #expect(actions.first?.command == .perform(.run(.checkAgain(.tune))))
        var failed = JourneyFixtures.row("G1", .fixable("Balanced"))
        failed.failure = "The power plan didn't change."
        #expect(SetupTuneRowActions.of(failed, facts: JourneyFixtures.facts).first?.title == SetupCopy.bTryAgain)
    }
}

// MARK: - Coming back to the window

/// Every state the look on coming back is held to, by name: the journey's screens, step 1's and the
/// VM step's, the certificate's and Finish's. All invented (the fixtures they come from say so).
enum ReturnFixtures {
    static func state(_ name: String) throws -> SetupWindowState {
        switch name {
        case "certificate-unverified", "certificate-initial", "certificate-cancelled", "certificate-failed":
            return CertificateFixtures.state(String(name.dropFirst("certificate-".count)))
        case "look-needs-utm", "look-utm-denied", "look-utm-silent", "look-utm-silent-decided", "look-list-failed",
             "look-vm-none", "look-done", "look-ask-utm", "look-utm-failed":
            let look = String(name.dropFirst("look-".count)).replacingOccurrences(of: "needs-utm", with: "needs-utm-download")
            return try #require(SetupFixtures.screens.first { $0.name == look }?.state, "no fixture \(look)")
        case "look-list-failed-automation":
            return SetupFixtures.state(facts: SetupFixtures.facts(utm: SetupFixtures.installed, answers: .answered, vms: .failed(
                .init(title: "Winbar isn't allowed to control UTM", detail: "Turn it on in Automation.", automationDenied: true))))
        case "finished-no-app": return FinishFixtures.noWindowsApp
        case "finished-connected": return FinishFixtures.ready
        case "tune-page": return JourneyFixtures.page(.tune)
        case "did-it-work": return JourneyFixtures.didItWork
        case "save":
            var save = SetupFixtures.state(.savedPC, facts: JourneyFixtures.facts)
            save.facts?.rows["C2"] = JourneyFixtures.row("C2", .fixable("No saved PC"))
            return save
        case "saved-no-host":
            var noHost = SetupFixtures.state(.savedPC, facts: JourneyFixtures.facts)
            noHost.facts?.rdpHost = nil
            noHost.facts?.rows["C2"] = JourneyFixtures.row("C2", .fixable("No saved PC"))
            return noHost
        // Windows App's command line not answering, and the same with Windows App opened from the card
        // (Open Windows App) to save the PC by hand.
        case "saved-silent", "saved-silent-app-open":
            var silent = SetupFixtures.state(.savedPC, facts: JourneyFixtures.facts)
            silent.facts?.rows["C2"] = JourneyFixtures.row("C2", SilentFixtures.status)
            silent.facts?.windowsAppRunning = name == "saved-silent-app-open"
            return silent
        // The saved PC skipped, and Windows App skipped with it.
        case "saved-skipped", "saved-skipped-no-app":
            var skipped = SetupFixtures.state(.savedPC, facts: JourneyFixtures.facts)
            skipped.facts?.rows["C2"] = JourneyFixtures.row("C2", .fixable("No saved PC"))
            if name == "saved-skipped-no-app" {
                skipped.answers.leftAlone.insert("C1")
                skipped.facts?.windowsApp = .missing
            } else {
                skipped.answers.leftAlone.insert("C2")
            }
            skipped.facts?.answers = skipped.answers
            return skipped
        default:
            return try JourneyPolishFixtures.screen(name)
        }
    }

    /// The states that look, and what each forgets. The saved PC skipped with Windows App skipped too
    /// says Windows App isn't on this Mac yet, which an App Store install elsewhere makes untrue; the
    /// control is a table that looks at no skipped page.
    static let looks: [(String, SetupRunner.Forget)] = [
        ("connect-accessibility", .selfTest), ("connect-failed", .statuses), ("saved-no-user", .guest),
        ("saved-needs-app", .statuses), ("saved-app-open", .statuses), ("certificate-unverified", .statuses),
        ("look-needs-utm", .statuses), ("look-utm-denied", .utm), ("look-utm-silent", .utm),
        ("look-utm-silent-decided", .utm), ("look-list-failed-automation", .utm), ("look-vm-none", .utm),
        ("finish-others", .statuses), ("finished-no-app", .statuses), ("saved-skipped-no-app", .statuses),
    ]

    /// The states whose answer stands, or whose way on is a button here. The card that says Windows
    /// App's command line isn't responding is one, even with Windows App opened from it to save the PC
    /// by hand: only the command line could see that PC, and a look never runs it, so **I've Saved the
    /// PC** is the way on. The control is a table that looks at the saved PC's `.manual`.
    static let stands = [
        "tune-mixed", "tune-fixable", "tune-page", "save", "saved-done", "saved-no-host", "connect-ready", "did-it-work",
        "connect-failed-answering", "certificate-initial", "certificate-cancelled", "certificate-failed",
        "certificate-needs", "look-list-failed", "look-done", "look-ask-utm", "look-utm-failed", "vm-ready",
        "finished-connected", "saved-skipped", "saved-silent", "saved-silent-app-open",
    ]
}

@MainActor @Suite("Coming back to the window looks again where the step waits on another app, and only there")
struct JourneyRecheckRuleTests {
    /// The table. The control is HEAD's rule for Tune (any row Ben does by hand): tune-mixed looks.
    @Test("Looks where the step waits on another app, forgetting only what that app can change",
          arguments: ReturnFixtures.looks)
    func looks(name: String, forget: SetupRunner.Forget) throws {
        let state = try ReturnFixtures.state(name)
        #expect(SetupJourneyActions.returnRead(state) == .lookAgain(state.step, forgetting: forget), "\(name)")
        #expect(SetupJourneyActions.rechecksOnReturn(state))
        // Never while anything runs, while the install's views are the step, or before the look after
        // an install.
        var busy = state
        busy.inFlight = SetupFixtures.flight(.checkAgain(state.step))
        #expect(SetupJourneyActions.returnRead(busy) == nil, "\(name) while a read runs")
        var creating = state
        creating.creating = true
        #expect(SetupJourneyActions.returnRead(creating) == nil, "\(name) while creating")
        var installed = state
        installed.afterInstall = SetupFixtures.started
        #expect(SetupJourneyActions.returnRead(installed) == nil, "\(name) before the look after an install")
    }

    /// Where the page's answer stands until something here changes it, and **Check Again** (or a row's
    /// **I've Done It**) is the re-check: Tune, whose "already right" rows went back to Checking…
    /// every time Ben clicked back into the window; the password field; the desktop question; a done
    /// step; and where the way on is a button on this page.
    @Test("Looks at nothing where the answer stands, or the way on is a button here", arguments: ReturnFixtures.stands)
    func stands(name: String) throws {
        #expect(SetupJourneyActions.returnRead(try ReturnFixtures.state(name)) == nil, "\(name)")
    }

    /// A card that promises the check is held to it. The control is a table without `.utmDenied`:
    /// its card says Winbar checks again when you come back, and it wouldn't.
    @Test("Every card that says Winbar checks again by itself is a state that looks")
    func promisesKept() throws {
        var promised: [String] = []
        for (name, state) in SetupFixtures.screens where state.step == .lookAround {
            guard let text = LookAroundPage.cardText(LookAroundPage.page(state).card) else { continue }
            let words = ([text.lead].compactMap { $0 } + text.paragraphs + [text.emphasis, text.aside].compactMap { $0 })
                .map { String($0.characters) }.joined(separator: " ")
            guard words.contains(SetupCopy.LookAround.comeBack) else { continue }
            promised.append(name)
            #expect(SetupJourneyActions.returnRead(state) != nil, "\(name) says it checks again, and doesn't look")
        }
        #expect(promised.count >= 3, "\(promised)")
        // The saved-PC step's own promise, after signing in on Windows' screen.
        let noUser = try ReturnFixtures.state("saved-no-user")
        let facts = try #require(noUser.facts)
        #expect(SetupCopy.SavedPC.notYet(host: facts.rdpHost, user: facts.rdpUser).body.contains("checks again by itself"))
        #expect(SetupJourneyActions.returnRead(noUser) != nil)
    }

    /// A look costs what it forgets: the survey of Windows takes up to three minutes, the self-test
    /// launches a second Winbar, and asking UTM is an Apple Event. Each is forgotten only where the
    /// thing it answers is what the step waits on. The control is HEAD's saved-PC rule, which read
    /// on every "not yet": the page with no host name yet would survey Windows each time.
    @Test("No look forgets more than the step waits on")
    func forgetsOnlyWhatItMust() throws {
        for name in ReturnFixtures.looks.map(\.0) + ReturnFixtures.stands {
            let state = try ReturnFixtures.state(name)
            guard case .lookAgain(_, let forget)? = SetupJourneyActions.returnRead(state) else { continue }
            switch forget {
            case .guest: #expect(name == "saved-no-user", "\(name) surveys Windows")
            case .selfTest: #expect(name == "connect-accessibility", "\(name) runs the self-test")
            case .utm: #expect(state.step <= .vm, "\(name) asks UTM")
            case .statuses: break
            }
        }
    }

    /// The certificate's "not verified" is the approval's own read-back, and the first read after it
    /// decides it: a look nobody pressed isn't an ending, so without the rule the page would say
    /// "not verified — Check Again" for good, and look on every return. The control is the rule
    /// without the stamp: a later read still says Check Again.
    @Test("The certificate's \"not verified\" lasts until the next read, which the look is")
    func certificateStamp() throws {
        let unverified = try ReturnFixtures.state("certificate-unverified")
        #expect(CertificateFixtures.page(unverified).next == .checkAgain)
        #expect(SetupCertificatePage.awaitsLook(unverified))
        var later = unverified
        later.facts?.stamp = SetupFlow.Stamp(taken: SetupFixtures.started.addingTimeInterval(30), utmPIDs: [100], vmPID: 101)
        #expect(CertificateFixtures.page(later).next == .approve(SetupCopy.Certificate.bApprove))
        #expect(!SetupCertificatePage.awaitsLook(later))
        #expect(SetupJourneyActions.returnRead(later) == nil)
        // Trusted by then: verified, whichever read said so.
        later.facts?.rows["H7"] = JourneyFixtures.row("H7", .ok("Trusted"))
        #expect(CertificateFixtures.page(later).phase == .verified)
    }
}

/// A Mac with the journey's steps read as ready, apart from what a test says, counting reads and what
/// each read followed.
private final class ReturnMachine: SetupMachine {
    private let lock = NSLock()
    private var _afters: [SetupRunner.Work?] = []
    private var _performed: [SetupRunner.Work] = []
    private var _holding = false
    private let gate = DispatchSemaphore(value: 0)
    private let overrides: [String: Status]
    init(_ overrides: [String: Status] = ["C3": .manual("Not allowed", how: "Allow access")]) { self.overrides = overrides }

    var reads: Int { lock.lock(); defer { lock.unlock() }; return _afters.count }
    var afters: [SetupRunner.Work?] { lock.lock(); defer { lock.unlock() }; return _afters }
    var performed: [SetupRunner.Work] { lock.lock(); defer { lock.unlock() }; return _performed }

    /// The next read waits, once it has been counted, until `release()`: a read still running.
    func hold() { lock.lock(); _holding = true; lock.unlock() }
    func release() {
        lock.lock(); _holding = false; lock.unlock()
        gate.signal()
    }

    func readings(through step: WizardStep, answers: SetupFlow.Answers, after work: SetupRunner.Work?,
                  job: SetupRunner.Job?) -> SetupRunner.Readings {
        lock.lock(); _afters.append(work); let holding = _holding; lock.unlock()
        if holding { _ = gate.wait(timeout: .now() + 10) }
        var read = SetupRunner.Readings()
        read.utm = SetupFixtures.installed
        read.utmAnswers = .answered
        read.windowsApp = .installed(version: "11.4")
        read.vms = .success([SetupVMTests.new])
        read.chosenVM = SetupVMTests.new.name
        read.guestAnswers = true
        read.rdpHost = "winlab02.local"
        read.rdpUser = "Bruno"
        let reached = WizardStep.allCases.filter { $0 <= step }.flatMap(SetupFlow.checks(in:))
        for id in reached { read.statuses[id] = overrides[id] ?? .ok("Ready") }
        return read
    }

    func perform(_ work: SetupRunner.Work, password: String?, facts: SetupFlow.Facts, job: SetupRunner.Job) throws {
        lock.lock(); _performed.append(work); lock.unlock()
    }
}

/// What the window asks to run after a delay, kept for the test to run when it chooses.
@MainActor private final class Later {
    private(set) var pending: [() -> Void] = []
    func add(_ delay: TimeInterval, _ body: @escaping () -> Void) {
        #expect(delay == SetupWindowController.returnLookDelay)
        pending.append(body)
    }
}

@MainActor @Suite("The window looks again a moment after it becomes key, and never under a press", .serialized)
struct JourneyRecheckControllerTests {
    private struct Rig {
        let controller: SetupWindowController
        let machine: ReturnMachine
        let runner: SetupRunner
        let later: Later
    }

    /// `quit` stands in for Windows App quitting: it quits nothing on this Mac. `gate` is the app's
    /// work gate, when a test holds it as the menu would.
    private func rig(_ state: SetupWindowState, machine: ReturnMachine = ReturnMachine(), gate: AppWorkGate? = nil,
                     quit: @escaping (@escaping () -> Void) -> Void = { _ in }) -> Rig {
        let runner = SetupRunner(machine: machine, environment: .init(
            queue: DispatchQueue(label: "winbar.test.journey-recheck"), callbacks: .main, clock: Date.init,
            keepAwake: { _ in {} }, processes: { _ in ([100], 101) }, workspace: NotificationCenter(), workGate: gate))
        let later = Later()
        let controller = SetupWindowController(state: state, art: nil,
            settings: .init(wizardShown: { false }, markShown: {}, armieHidden: { true }, hideArmie: {}),
            makeRunner: { runner }, makeCreator: { FakeEmbeddedCreate() }, quitWindowsApp: quit,
            later: { later.add($0, $1) })
        controller.attach()
        return Rig(controller: controller, machine: machine, runner: runner, later: later)
    }

    private let becameKey = Notification(name: NSWindow.didBecomeKeyNotification)

    private func settle(_ done: @MainActor () -> Bool) async {
        for _ in 0..<500 where !done() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    /// The look is a refresh, not a Check Again: it runs the self-test and nothing else, and it isn't
    /// an ending, so the page's last ending stands. (The runner reads everything when it has no
    /// snapshot yet, so the page is read once first, as the window always has been.)
    @Test("Back from System Settings on the Accessibility card: a look that runs the self-test")
    func accessibility() async throws {
        let rig = rig(try JourneyPolishFixtures.screen("connect-accessibility"))
        rig.controller.send(.perform(.run(.checkAgain(.connect))))
        await settle { rig.controller.state.lastEnding?.work == .checkAgain(.connect) && rig.controller.state.inFlight == nil }
        let ending = try #require(rig.controller.state.lastEnding)
        rig.controller.windowDidBecomeKey(becameKey)
        #expect(rig.machine.reads == 1, "nothing is read at once")
        try #require(rig.later.pending.count == 1)
        rig.later.pending[0]()
        let look = SetupRunner.Work.lookAgain(.connect, forgetting: .selfTest)
        await settle { rig.machine.afters.contains(look) && rig.controller.state.inFlight == nil }
        #expect(rig.machine.afters == [nil, look])
        #expect(rig.controller.state.lastEnding == ending)
        #expect(rig.controller.state.refusal == nil)
        rig.controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
    }

    /// Josh's Approve Certificate… that gave no macOS dialog: the click that brought the window forward
    /// was followed by one on Approve, and the read the first had started refused the second. Now the
    /// press comes first and calls the look off; a click or a key during the moment puts it back; and
    /// only the look armed last is taken. The controls are HEAD's `run(.checkAgain)` on becoming key
    /// (the press is refused), and a `send` that leaves the look armed (the first closure reads).
    @Test("The click that brings the window forward wins, and a look waits for the person")
    func pressWins() async throws {
        let machine = ReturnMachine(["H7": .fixable("Not trusted")])
        let rig = rig(CertificateFixtures.state("unverified"), machine: machine)
        rig.controller.windowDidBecomeKey(becameKey)
        rig.controller.send(.perform(.run(.trustCertificate)))
        #expect(rig.controller.state.refusal == nil)
        await settle { rig.controller.state.lastEnding?.work == .trustCertificate && rig.controller.state.inFlight == nil }
        #expect(machine.performed == [.trustCertificate])
        #expect(rig.controller.state.refusal == nil)
        let reads = machine.reads
        rig.later.pending[0]()
        #expect(rig.runner.inFlight == nil, "the press called the look off")

        // Back from macOS's dialog: the approval's read-back says "not verified", which is a look's.
        let unverified = rig.controller.state
        #expect(SetupCertificatePage.awaitsLook(unverified))
        rig.controller.windowDidBecomeKey(becameKey)
        rig.controller.personActed()
        #expect(rig.later.pending.count == 3)
        rig.later.pending[1]()
        #expect(rig.runner.inFlight == nil, "a click put the look back")
        rig.later.pending[2]()
        let look = SetupRunner.Work.lookAgain(.certificate, forgetting: .statuses)
        #expect(rig.runner.inFlight?.work == look)
        await settle { machine.reads == reads + 1 && rig.controller.state.inFlight == nil }
        #expect(machine.reads == reads + 1 && machine.afters.last == look)
        // Not an ending: the approval is still how the last press ended, and the look decided it.
        #expect(rig.controller.state.lastEnding?.work == .trustCertificate)
        #expect(rig.controller.state.refusal == nil)
        let facts = try #require(rig.controller.state.facts)
        #expect(SetupCertificatePage.page(rig.controller.state, facts: facts).next == .approve(SetupCopy.Certificate.bApprove))
        rig.controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
    }

    /// Josh's report: every time he went back to the window, Tune started its check over. Its answer
    /// now stands; its rows' I've Done It and the footer's Check Again are the re-check.
    @Test("Back on Tune, the page keeps its answer and nothing is read")
    func tuneKeepsItsAnswer() async throws {
        let rig = rig(try JourneyPolishFixtures.screen("tune-mixed"))
        rig.controller.windowDidBecomeKey(becameKey)
        for fire in rig.later.pending { fire() }
        try? await Task.sleep(for: .milliseconds(200))
        #expect(rig.machine.reads == 0 && rig.controller.state.inFlight == nil && rig.controller.state.lastEnding == nil)
        rig.controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
    }

    /// A quit in the background doesn't make the window key, so the page kept saying Windows App was
    /// open, with the same filled button, until Ben found Check Again. The read is a look, not a Check
    /// Again: it works the saved PC out again from what is read live, and never runs Windows App's
    /// command line, which is what an 11.4.2 deadlocked on. (Changed on purpose: this expected a Check
    /// Again, which re-ran the lookup and replaced the last ending.)
    @Test("Quit Windows App: once it has quit, the saved PC step looks again by itself")
    func quitThenRead() async throws {
        var quits = 0
        let rig = rig(try JourneyPolishFixtures.screen("saved-app-open")) { done in
            quits += 1
            done()
        }
        rig.controller.send(.perform(.run(.checkAgain(.savedPC))))
        await settle { rig.controller.state.lastEnding?.work == .checkAgain(.savedPC) && rig.controller.state.inFlight == nil }
        rig.controller.send(.quitWindowsApp)
        let look = SetupRunner.Work.lookAgain(.savedPC, forgetting: .statuses)
        await settle { rig.machine.afters.contains(look) && rig.controller.state.inFlight == nil }
        #expect(quits == 1)
        #expect(rig.machine.afters == [nil, look])
        #expect(rig.controller.state.lastEnding?.work == .checkAgain(.savedPC) && rig.controller.state.refusal == nil)
        #expect(!String(SetupCopy.markdown(SetupCopy.SavedPC.appOpen).characters).contains(SetupCopy.bCheckAgain))
        rig.controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
    }

    /// Ben pressed Quit Windows App while a read ran, and the quit was dropped: the window read
    /// nothing, and the card kept saying Windows App was open. The look is owed now, and taken once
    /// the read ends, on the step it was owed for and no other. The control is HEAD's early return
    /// while anything runs (no second read), and a flush that ignores the step (a read on Tune).
    @Test("A quit during a read is looked at once the read ends, and not after Ben moved on")
    func quitDuringARead() async throws {
        let rig = rig(try JourneyPolishFixtures.screen("saved-app-open")) { $0() }
        rig.machine.hold()
        rig.controller.send(.perform(.run(.checkAgain(.savedPC))))
        await settle { rig.controller.state.inFlight != nil && rig.machine.reads == 1 }
        rig.controller.send(.quitWindowsApp)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(rig.machine.reads == 1 && rig.controller.state.refusal == nil)
        rig.machine.release()
        let look = SetupRunner.Work.lookAgain(.savedPC, forgetting: .statuses)
        await settle { rig.machine.afters.contains(look) && rig.controller.state.inFlight == nil }
        #expect(rig.machine.afters == [nil, look])
        #expect(rig.controller.state.refusal == nil)
        rig.controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))

        let moved = self.rig(try JourneyPolishFixtures.screen("saved-app-open")) { $0() }
        moved.machine.hold()
        moved.controller.send(.perform(.run(.checkAgain(.savedPC))))
        await settle { moved.controller.state.inFlight != nil && moved.machine.reads == 1 }
        moved.controller.send(.quitWindowsApp)
        moved.controller.send(.back)
        #expect(moved.controller.state.step == .certificate)
        moved.machine.release()
        await settle { moved.controller.state.lastEnding?.work == .checkAgain(.savedPC) && moved.controller.state.inFlight == nil }
        try? await Task.sleep(for: .milliseconds(200))
        #expect(moved.machine.reads == 1)
        moved.controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
    }

    /// The menu holding the app's gate (starting another VM) turns the look away. Nothing is said about
    /// it — nobody pressed it — and the runner takes a read of everything on the menu's next tick. The
    /// control is a window that shows the gate's refusal as a banner.
    @Test("A look the menu's work turns away says nothing, and is taken on the menu's next tick")
    func lookTurnedAway() async throws {
        let gate = AppWorkGate()
        let rig = rig(try JourneyPolishFixtures.screen("connect-accessibility"), gate: gate)
        rig.controller.send(.perform(.run(.checkAgain(.connect))))
        await settle { rig.controller.state.lastEnding?.work == .checkAgain(.connect) && rig.controller.state.inFlight == nil }
        let ending = rig.controller.state.lastEnding
        let menu = try gate.begin(.menu, label: "starting “atelier”", vm: "atelier").get()
        rig.controller.windowDidBecomeKey(becameKey)
        try #require(rig.later.pending.count == 1)
        rig.later.pending[0]()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(rig.controller.state.refusal == nil && rig.machine.reads == 1)
        menu.finish()
        rig.runner.processTableTick()
        await settle { rig.machine.reads == 2 && rig.controller.state.inFlight == nil }
        #expect(rig.machine.reads == 2 && rig.controller.state.refusal == nil && rig.controller.state.lastEnding == ending)
        #expect(rig.controller.state.step == .connect)
        rig.controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
    }

    /// Continue pressed the moment a read nobody pressed began (a wake's survey, the window not yet
    /// told of it): the arrival read was refused, with a banner about a press nobody made, and the new
    /// step was never read. It is owed now, and taken once the read ends. The control is HEAD's
    /// `run(.checkAgain)` for the arrival: a banner, and no read of the new step.
    @Test("Arriving at a step while a read nobody pressed runs reads the step once it ends, with no banner")
    func arrivalDuringARefresh() async throws {
        let certificate = CertificateFixtures.state("skipped")
        let rig = rig(certificate)
        rig.controller.send(.perform(.run(.checkAgain(.certificate))))
        await settle { rig.controller.state.lastEnding?.work == .checkAgain(.certificate) && rig.controller.state.inFlight == nil }
        rig.machine.hold()
        #expect(rig.runner.lookAgain(.lookAgain(.certificate, forgetting: .statuses)))
        rig.controller.send(.next)
        #expect(rig.controller.state.step == .savedPC)
        #expect(rig.controller.state.refusal == nil)
        rig.machine.release()
        await settle { rig.controller.state.lastEnding?.work == .checkAgain(.savedPC) && rig.controller.state.inFlight == nil }
        #expect(rig.controller.state.lastEnding?.work == .checkAgain(.savedPC))
        #expect(rig.machine.reads == 3 && rig.controller.state.refusal == nil)
        rig.controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
    }

    /// The same arrival, and Windows App quits (Quit Windows App stays live through a read) before the
    /// read nobody pressed ends. The quit's look used to replace the owed Check Again, and a look raises
    /// nothing: C2 was never read, and the page said "not yet" until Ben found Check Again. The owed
    /// Check Again stands, and reads the saved PC. The control is `readByItself` letting a look
    /// overwrite `owedRead`: the reads end with the look, and the last ending stays the certificate's.
    @Test("A quit during a read nobody pressed doesn't replace the arrival's owed Check Again")
    func quitAfterArrivalDuringARefresh() async throws {
        let rig = rig(CertificateFixtures.state("skipped")) { $0() }
        rig.controller.send(.perform(.run(.checkAgain(.certificate))))
        await settle { rig.controller.state.lastEnding?.work == .checkAgain(.certificate) && rig.controller.state.inFlight == nil }
        rig.machine.hold()
        #expect(rig.runner.lookAgain(.lookAgain(.certificate, forgetting: .statuses)))
        rig.controller.send(.next)
        #expect(rig.controller.state.step == .savedPC)
        rig.controller.send(.quitWindowsApp)
        rig.machine.release()
        await settle { rig.controller.state.lastEnding?.work == .checkAgain(.savedPC) && rig.controller.state.inFlight == nil }
        #expect(rig.controller.state.lastEnding?.work == .checkAgain(.savedPC))
        #expect(rig.machine.afters.last == .checkAgain(.savedPC))
        #expect(rig.controller.state.facts?.rows["C2"] != nil && rig.controller.state.refusal == nil)
        rig.controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
    }

    /// The control: a quit that ends after Ben has moved on to another step reads nothing, and a quit
    /// Windows App hasn't finished reads nothing either.
    @Test("A quit that ends after Ben moved on, or hasn't ended, reads nothing")
    func quitElsewhere() async throws {
        let pending = rig(try JourneyPolishFixtures.screen("saved-app-open")) { _ in }
        pending.controller.send(.quitWindowsApp)
        try? await Task.sleep(for: .milliseconds(200))
        #expect(pending.machine.reads == 0 && pending.controller.state.lastEnding == nil)
        pending.controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))

        let moved = rig(try JourneyPolishFixtures.screen("connect-accessibility"))
        moved.controller.windowsAppQuit()
        try? await Task.sleep(for: .milliseconds(200))
        #expect(moved.machine.reads == 0 && moved.controller.state.lastEnding == nil)
        moved.controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
    }

    /// The same arrival with the menu holding the app's gate: no banner, and the step is read once the
    /// gate is free — the runner reads everything on the menu's next tick, and the window's own read of
    /// the new step follows that refresh. The control is an arrival that doesn't ask the runner to read
    /// when free: nothing is read after the tick.
    @Test("Arriving at a step while the menu holds the app's gate reads the step once it's free, with no banner")
    func arrivalTurnedAway() async throws {
        let gate = AppWorkGate()
        let rig = rig(CertificateFixtures.state("skipped"), gate: gate)
        rig.controller.send(.perform(.run(.checkAgain(.certificate))))
        await settle { rig.controller.state.lastEnding?.work == .checkAgain(.certificate) && rig.controller.state.inFlight == nil }
        let menu = try gate.begin(.menu, label: "starting “atelier”", vm: "atelier").get()
        rig.controller.send(.next)
        #expect(rig.controller.state.step == .savedPC && rig.controller.state.refusal == nil)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(rig.machine.reads == 1)
        menu.finish()
        rig.runner.processTableTick()
        await settle { rig.controller.state.lastEnding?.work == .checkAgain(.savedPC) && rig.controller.state.inFlight == nil }
        #expect(rig.controller.state.lastEnding?.work == .checkAgain(.savedPC))
        #expect(rig.machine.reads == 3 && rig.controller.state.refusal == nil && rig.controller.state.step == .savedPC)
        rig.controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
    }

    /// Start pressed while the menu starts a VM (likelier now that Windows can start with Winbar at
    /// login): the page said "Checking this Mac" with only Back, a banner said to try again with
    /// nothing to press, and nothing was ever read. Start's read is owed like any read the window
    /// takes by itself, and taken once the gate is free. The control is `send(.start)` calling
    /// `run(.checkAgain(.lookAround))`: a banner, and no read after the tick.
    @Test("Start pressed while the menu holds the app's gate reads the Mac once it's free, with no banner")
    func startTurnedAway() async throws {
        let gate = AppWorkGate()
        let rig = rig(SetupWindowState(), gate: gate)
        #expect(rig.controller.state.step == .welcome)
        let menu = try gate.begin(.menu, label: "starting “atelier”", vm: "atelier").get()
        rig.controller.send(.start)
        #expect(rig.controller.state.step == .lookAround && rig.controller.state.refusal == nil)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(rig.machine.reads == 0)
        menu.finish()
        rig.runner.processTableTick()
        await settle { rig.controller.state.lastEnding?.work == .checkAgain(.lookAround) && rig.controller.state.inFlight == nil }
        #expect(rig.machine.reads == 2 && rig.controller.state.lastEnding?.work == .checkAgain(.lookAround))
        #expect(rig.controller.state.facts != nil && rig.controller.state.refusal == nil)
        #expect(rig.controller.state.step == .lookAround && rig.controller.state.facts?.answers.started == true)
        rig.controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
    }

    /// The finished page says "To run this window again, choose Set Up Winbar… in the menu", and a
    /// menu bar app runs for days: choosing it brought back the same finished page, with no Back and
    /// no Check Again, until Winbar was relaunched. Closed finished with the desktop seen, the window
    /// opens again on Look around with fresh answers, and reads the Mac. A finished page that says
    /// "pick up where this leaves off" is still there when it opens again, as it says. The control is
    /// an `attach` that keeps the state it closed with: the page stays finished, and nothing is read.
    @Test("Set Up Winbar… after a finished setup runs the window again; an unfinished connection picks up")
    func runAgainAfterFinishing() async throws {
        let done = JourneyPolishFixtures.state(.finish) {
            $0.finished = true
            $0.answers.connectionOpened = true
            $0.answers.connected = true
            $0.answers.leftAlone.insert("H7")
        }
        #expect(done.runsAgainWhenReopened)
        let rig = rig(done)
        rig.controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        rig.controller.attach()
        #expect(rig.controller.state.step == .lookAround && !rig.controller.state.finished)
        #expect(rig.controller.state.answers.started && rig.controller.state.answers.leftAlone.isEmpty)
        #expect(rig.controller.state.answers.connected == nil)
        await settle { rig.controller.state.lastEnding?.work == .checkAgain(.lookAround) && rig.controller.state.inFlight == nil }
        #expect(rig.controller.state.lastEnding?.work == .checkAgain(.lookAround) && rig.machine.reads == 1)
        #expect(rig.controller.state.step == .lookAround && rig.controller.state.facts != nil)
        // Closed and opened again before finishing, it is where it was.
        rig.controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        rig.controller.attach()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(rig.machine.reads == 1 && rig.controller.state.step == .lookAround)
        rig.controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))

        var tried = done
        tried.answers.connected = false
        tried.facts?.answers = tried.answers
        #expect(!tried.runsAgainWhenReopened)
        let again = self.rig(tried)
        again.controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        again.controller.attach()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(again.controller.state.step == .finish && again.controller.state.finished && again.machine.reads == 0)
        again.controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
    }

    /// Approve Certificate… pressed while the menu starts a VM: the gate's own words are right while it
    /// holds, and the banner stands while the page still offers the press. It said "Winbar is still
    /// starting “atelier”" after the menu had finished, until Ben pressed something else. Once the gate
    /// is free the runner reads, and the words turn past. Two controls: without `reasonPassed` marked
    /// the words stay present-tense after the read; without `readWhenFree` on the gate's refusal
    /// nothing is read after the tick, and the words stay too.
    @Test("A refusal from the menu's work stops saying 'still' once that work has finished")
    func gateRefusalPasses() async throws {
        let gate = AppWorkGate()
        let rig = rig(CertificateFixtures.state("initial"), machine: ReturnMachine(["H7": .fixable("Not trusted")]), gate: gate)
        rig.controller.send(.perform(.run(.checkAgain(.certificate))))
        await settle { rig.controller.state.lastEnding?.work == .checkAgain(.certificate) && rig.controller.state.inFlight == nil }
        let menu = try gate.begin(.menu, label: "starting “atelier”", vm: "atelier").get()
        rig.controller.send(.perform(.run(.trustCertificate)))
        let refused = try #require(rig.controller.state.refusal)
        let held = String(SetupCopy.Working.refused(refused, busy: nil).characters)
        #expect(held == "Winbar is still starting “atelier”. Wait for it to finish, then try again.")
        try? await Task.sleep(for: .milliseconds(100))
        #expect(rig.machine.reads == 1)
        #expect(String(SetupCopy.Working.refused(try #require(rig.controller.state.refusal), busy: nil).characters) == held)
        menu.finish()
        rig.runner.processTableTick()
        // Past once the read has begun (`.refreshing`), and the refresh taken once it has ended.
        await settle {
            rig.controller.state.refusal?.reasonPassed == true && rig.controller.state.inFlight == nil
                && !rig.controller.state.refreshing
        }
        #expect(rig.machine.reads == 2)
        let standing = try #require(rig.controller.state.refusal, "the page still offers Approve Certificate…")
        let words = String(SetupCopy.Working.refused(standing, busy: rig.controller.state.inFlight).characters)
        #expect(words == SetupCopy.Working.refusedWhileBusy && !words.contains("still"))
        #expect(!rig.machine.performed.contains(.trustCertificate))
        rig.controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
    }

    /// A snapshot queued before the refusal (a read that let go of the gate just as the menu took it)
    /// says nothing about the gate since; only a read that began after it does. The control is
    /// marking the words past on any event: the first expectation fails.
    @Test("Only a read that began after the gate's refusal turns its words past")
    func gateRefusalAfterwards() throws {
        var state = CertificateFixtures.state("initial")
        let at = Date(timeIntervalSince1970: 1_000)
        state.refusal = SetupRunner.Refusal(wanted: .trustCertificate,
                                            inFlight: .init(work: .trustCertificate, started: at, vm: nil),
                                            reason: "Winbar is still starting “atelier”. Wait for it to finish, then try again.")
        var facts = try #require(state.facts)
        facts.stamp = SetupFlow.Stamp(taken: at.addingTimeInterval(-1), utmPIDs: [], vmPID: nil)
        #expect(state.applying(.refreshed(facts)).refusal?.reasonPassed == false)
        facts.stamp?.taken = at.addingTimeInterval(1)
        #expect(state.applying(.refreshed(facts)).refusal?.reasonPassed == true)
    }

    @Test("Back to answer whether the desktop appeared: nothing is read, and the question stays")
    func desktopQuestion() async throws {
        var state = try JourneyPolishFixtures.screen("connect-accessibility")
        state.facts?.rows["C3"] = JourneyFixtures.row("C3", .ok("Allowed"))
        state.answers.connectionOpened = true
        state.facts?.answers = state.answers
        let rig = rig(state)
        rig.controller.windowDidBecomeKey(becameKey)
        for fire in rig.later.pending { fire() }
        try? await Task.sleep(for: .milliseconds(200))
        #expect(rig.machine.reads == 0 && rig.controller.state.inFlight == nil && rig.controller.state.lastEnding == nil)
        rig.controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
    }
}

// MARK: - Tune

@Suite("Tune: a headline, the rows that need Ben first, and the rest folded")
struct TuneListModelTests {
    @Test("The headline says tuned, how many need Ben, what couldn't be read, or that Windows wasn't asked")
    func headline() throws {
        #expect(SetupTuneHeadline.of(JourneyFixtures.facts) == .tuned(staged: 0))
        #expect(SetupTuneHeadline.of(try #require(JourneyPolishFixtures.screen("tune-staged").facts)) == .tuned(staged: 1))
        #expect(SetupTuneHeadline.of(try #require(JourneyPolishFixtures.screen("tune-fixable").facts)) == .needsYou(count: 1, fixable: 1))
        #expect(SetupTuneHeadline.of(try #require(JourneyPolishFixtures.screen("tune-unanswered").facts)) == .unchecked(count: 1))
        #expect(SetupTuneHeadline.of(JourneyFixtures.facts, working: "Checking Windows' settings…") == .working("Checking Windows' settings…"))
        #expect(SetupCopy.Tune.headline(.tuned(staged: 0)).title == "Windows is tuned")
        #expect(SetupCopy.Tune.headline(.tuned(staged: 1)).detail?.contains("One change waits for the restart") == true)
        #expect(SetupCopy.Tune.headline(.needsYou(count: 1, fixable: 1)).detail?.contains("**Fix Everything**") == true)
    }

    @Test("A row Ben can act on comes before one Windows didn't answer for")
    func blockingFirst() throws {
        var facts = JourneyFixtures.facts
        facts.rows["G3"] = JourneyFixtures.row("G3", .error("Windows did not answer"))
        facts.rows["H6"] = JourneyFixtures.row("H6", .manual("Time Machine", how: "Add the folder"))
        #expect(SetupTuneGroups(facts).needsYou.map(\.id) == ["H6", "G3"])
        #expect(SetupTuneHeadline.of(facts) == .needsYou(count: 1, fixable: 0))
    }

    @Test("Row words: left alone says what was chosen and when; buttons say where they go")
    func words() {
        #expect(SetupCopy.Tune.leftAlone(declined: "--winbar-tuning")
                == "Left alone: you turned off performance tuning when Windows was installed.")
        let h6 = JourneyFixtures.row("H6", .manual("Time Machine", how: "Add the folder"))
        let titles = SetupTuneRowActions.of(h6, facts: JourneyFixtures.facts).map(\.title)
        #expect(titles == ["Open Time Machine Settings…", "I've Added the Folder", "Skip"])
        #expect(SetupCopy.Tune.trailing(.needsAttention, JourneyFixtures.row("G3", .error("x"))) == "Couldn't check")
    }

    @Test("Each row's buttons are named for VoiceOver with the row", arguments: ["G1", "H6"])
    func spoken(id: String) throws {
        let row = JourneyFixtures.row(id, id == "H6" ? .manual("Time Machine", how: "Add the folder") : .fixable("Balanced"))
        let actions = SetupTuneRowActions.of(row, facts: JourneyFixtures.facts)
        #expect(actions.contains { $0.spoken == "Skip \(row.title)" })
        #expect(actions.allSatisfy { $0.spoken.contains(row.title) })
        if id == "G1" { #expect(actions.first?.spoken == "Fix Power plan") }
    }

    /// The button as drawn carries the label: SwiftUI's own description of it, since offscreen the
    /// accessibility tree is empty (`accessibility(of:)`).
    @MainActor @Test("The drawn row button says the row to VoiceOver")
    func drawnLabel() {
        let skip = SetupTuneRowActions.Action(title: "Skip", spoken: "Skip Power plan", command: .skip("G1"))
        let description = accessibility(of: TuneRowButton(action: skip) {}.body)
        #expect(description.contains("Skip Power plan"))
    }

    @Test("Skip isn't offered on a row that's already skipped")
    func noSkipOnSkipped() {
        var facts = JourneyFixtures.facts
        facts.rows["G2"] = JourneyFixtures.row("G2", .fixable("Sleeps"))
        facts.answers.leftAlone.insert("G2")
        #expect(!SetupTuneRowActions.of(facts.rows["G2"]!, facts: facts).contains { $0.title == SetupCopy.bSkip })
    }
}

@MainActor @Suite("Tune, drawn: the headline and the folded list")
struct TuneListDrawnTests {
    @Test("All verified: the page says Windows is tuned, and the fifteen rows are one folded line")
    func tuned() throws {
        let lines = try ocr(render(JourneyFixtures.page(.tune), .light))
        #expect(lines.contains { $0.contains("Windows is tuned") }, "\(lines)")
        #expect(lines.contains { $0.contains(SetupCopy.Tune.alreadyRight(15)) }, "\(lines)")
        #expect(!lines.contains { $0.contains("Windows edition") }, "a verified row is drawn open: \(lines)")
        #expect(!lines.contains { $0.contains("recipe") }, "\(lines)")
    }

    @Test("Mixed: the row that needs Ben is above the fold with its own buttons; the passed rows are folded")
    func mixed() throws {
        let png = try render(try JourneyPolishFixtures.screen("tune-mixed"), .light)
        let lines = try Drawing.lines(png)
        let row = try #require(Drawing.find("Backups and indexing", in: lines), "\(lines)")
        #expect(row.frame.maxY < 400)
        #expect(Drawing.find("I've Added the Folder", in: lines) != nil)
        #expect(Drawing.find(SetupCopy.Tune.alreadyRight(12), in: lines) != nil, "\(lines)")
        #expect(Drawing.find("Left alone: you turned off performance tuning", in: lines) != nil, "\(lines)")
    }
}

// MARK: - The certificate

@Suite("The certificate names one next action in each problem state")
struct CertificateNextActionTests {
    private func bold(_ text: String) -> [String] {
        text.components(separatedBy: "**").enumerated().filter { $0.offset % 2 == 1 }.map(\.element)
    }

    @Test("Each problem state's words name exactly one button", arguments: ["failed", "cancelled", "unverified"])
    func one(name: String) {
        let page = CertificateFixtures.page(CertificateFixtures.state(name))
        let next = SetupCopy.Certificate.next(page)
        #expect(bold(next).count == 1, "\(name): \(next)")
        #expect(!next.contains("Skip for Now") && !next.contains("if available"), "\(name): \(next)")
    }

    @Test("No certificate yet names Go Back to Tune and the Tune row, not a code")
    func goBack() throws {
        let state = try JourneyPolishFixtures.screen("certificate-needs")
        let next = SetupCopy.Certificate.next(CertificateFixtures.page(state))
        // The row by the name the Tune page gives it, which is the step bar's name for the certificate.
        #expect(bold(next) == [SetupCopy.Certificate.bGoBack, "Certificate"])
        #expect(SetupCopy.Tune.title("G7", recipe: "RDP certificate") == "Certificate")
        #expect(!next.contains("G7"))
    }
}

@MainActor @Suite("What am I approving? opens while macOS's dialog waits")
struct CertificateDisclosureTests {
    /// The label as drawn: dimmed if it's inside the page's disabled scope, as it was while approval
    /// ran. Measured from the pixels, so it fails if the scope comes back.
    private func labelContrast(_ png: Data) throws -> Double {
        let lines = try Drawing.lines(png)
        let label = try #require(Drawing.find("What am I approving", in: lines), "\(lines)")
        return try #require(Drawing.inkContrast(png, in: label.frame.insetBy(dx: -2, dy: -2)))
    }

    /// The chevron, just before the label: accent-coloured, as something that opens.
    private func chevronContrast(_ png: Data) throws -> Double {
        let lines = try Drawing.lines(png)
        let label = try #require(Drawing.find("What am I approving", in: lines), "\(lines)")
        let chevron = CGRect(x: label.frame.minX - 20, y: label.frame.minY - 2, width: 16, height: label.frame.height + 4)
        return try #require(Drawing.inkContrast(png, in: chevron))
    }

    @Test("While approval runs, the disclosure is drawn at full strength, its chevron readable",
          arguments: [Snapshot.Appearance.light, .dark])
    func enabled(appearance: Snapshot.Appearance) throws {
        let png = try render(CertificateFixtures.state("approving"), appearance)
        #expect(try labelContrast(png) >= 4.5)
        #expect(try chevronContrast(png) >= 3)
    }

    /// The control: the same disclosure, disabled, is measured as dimmed, so the check above can see it.
    @Test("The control: disabled, it measures as dimmed")
    func control() throws {
        let view = SetupScreen(state: CertificateFixtures.state("approving"), art: nil, send: { _ in }).disabled(true)
        let png = try #require(Snapshot.png(view, size: setupWindowSize, appearance: .light))
        #expect(try labelContrast(png) < 4.5)
    }
}

// MARK: - Connect and the saved PC

@MainActor @Suite("Connect and the saved PC lead with one sentence, and the reasoning is folded")
struct JourneyProseTests {
    @Test("Ready to test: one sentence about Local Network, the 60 words behind Details")
    func ready() throws {
        let lines = try ocr(render(try JourneyPolishFixtures.screen("connect-ready"), .light))
        let text = lines.joined(separator: " ")
        #expect(text.contains("choose Allow"), "\(text)")
        #expect(lines.contains { $0.hasSuffix("Details") }, "\(lines)")
        #expect(!text.contains("which is how it knows Windows is ready"), "the Local Network prose is drawn open: \(text)")
        #expect(SetupCopy.Connecting.localNetworkLead.split(separator: " ").count <= 20)
    }

    @Test("Blocked: Open Local Network Settings… is the corner, and goes to Local Network")
    func blocked() throws {
        let state = try JourneyPolishFixtures.screen("connect-failed")
        let lines = try ocr(render(state, .light))
        #expect(lines.contains { $0.contains("Open Local Network Settings") }, "\(lines)")
        #expect(SetupFooter.footer(state).corner?.press == .send(.open(.localNetworkSettings)))
        #expect(SetupPlace.localNetworkSettings.settingsURL?.hasSuffix("Privacy_LocalNetwork") == true)
        #expect(SetupCopy.Connecting.recovery(.blocked, savedPC: true, console: .onScreen).opensLocalNetwork)
        #expect(!SetupCopy.Connecting.recovery(.notReady, savedPC: true, console: .onScreen).opensLocalNetwork)
    }

    /// The saving card says what it's doing once: a page spinner and line above it said it again.
    @Test("Saving says so once, in the card")
    func savingOnce() throws {
        let lines = try ocr(render(try JourneyPolishFixtures.screen("saved-saving"), .light))
        #expect(lines.filter { $0.contains("Saving the PC in Windows App") }.count == 1, "\(lines)")
    }

    @Test("No account name yet: the card says to sign in on Windows' screen, and offers it")
    func noUser() throws {
        let lines = try ocr(render(try JourneyPolishFixtures.screen("saved-no-user"), .light))
        #expect(lines.contains { $0.contains("sign in to Windows") }, "\(lines)")
        #expect(lines.contains { $0.contains("Show Windows' Screen") }, "\(lines)")
    }
}

// MARK: - Renders

@MainActor @Suite("The journey's polished screens, drawn")
struct JourneyPolishSnapshots {
    @Test("Every added journey screen renders in light and dark")
    func renders() throws {
        for (name, state) in JourneyPolishFixtures.screens {
            for appearance in [Snapshot.Appearance.light, .dark] {
                let png = try render(state, appearance)
                try Snapshot.record(png, as: "journey-polish-\(name)-\(appearance.rawValue)")
            }
        }
    }
}

// MARK: - What the comments say about coming back

/// Winbar used to re-read every step whenever it came back to the front; now a page that waits on
/// another app takes a quiet look a moment after its window becomes key, and nothing else is read
/// (`SetupJourneyActions.returnRead`). The comments that said the old thing sent the next reader after
/// a behaviour that no longer exists. The phrases are allowed only where a comment says it's gone
/// ("Not Winbar coming back to the front"). The control is the Look around card's old comment ("the
/// runner's own re-read … which it takes every time Winbar comes back to the front"), put back.
@Suite("No comment says Winbar reads again whenever it comes back to the front")
struct ReturnCommentTests {
    static let phrases = ["comes back to the front", "coming back to the front", "Winbar coming back", "Winbar comes back"]

    @Test("The old re-read is named only where a comment says it no longer happens")
    func onlyAsGone() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Winbar", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(files.count > 50, "\(sources.path)")
        var found: [String] = []
        for file in files {
            // A comment's lines as one run of words, so a phrase broken over two lines is still found.
            let words = try String(contentsOf: file, encoding: .utf8)
                .replacingOccurrences(of: #"\n\s*//+ ?"#, with: " ", options: .regularExpression)
                .replacingOccurrences(of: "Not Winbar coming back to the front", with: "")
            for phrase in Self.phrases where words.contains(phrase) { found.append("\(file.lastPathComponent): \(phrase)") }
        }
        #expect(found.isEmpty, "\(found)")
    }
}
