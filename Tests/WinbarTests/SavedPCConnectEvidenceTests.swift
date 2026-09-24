import AppKit
import Testing
@testable import Winbar

// A saved PC that Connect used counts as saved. Live, Windows App's command line hung three times out
// of three, so Winbar could neither save the PC nor see one; the owner saved it by hand, Connect pressed
// its tile, and he saw the desktop twice — and the step bar still flagged the saved PC, because nothing
// Winbar could read said it was there. Now a Connect that pressed the saved PC's tile for the host,
// followed by the person's Yes, is remembered for that VM and host (`Config.savedPCConnectedHost`), and
// C2 counts it when Windows App can't answer. It must not be fooled by a one-off connection, another
// account's tile, a desktop nobody confirmed, or a host that has changed. Invented values throughout;
// nothing reaches the Mac's settings, Windows App or a VM.

private let host = "winlab02.local"

@Suite("What a Connect answered Yes says about the saved PC")
struct ConnectedSavedPCRuleTests {
    @Test("A tile pressed for this host and a Yes are remembered, whatever the case of the name")
    func remembered() {
        #expect(Recipe.connectedSavedPC(desktopAppeared: true, pressed: host, host: host, previous: nil) == host)
        #expect(Recipe.connectedSavedPC(desktopAppeared: true, pressed: "WINLAB02.local", host: host, previous: nil)
                == host)
    }

    /// Control: return `host` for any Yes and every one of these fails.
    @Test("A one-off connection, another account's tile, No, and another host are never remembered")
    func notFooled() {
        // A one-off .rdp connection, or another account's tile Connect wouldn't press: nothing pressed.
        #expect(Recipe.connectedSavedPC(desktopAppeared: true, pressed: nil, host: host, previous: nil) == nil)
        // The desktop didn't appear: and what was remembered goes, since that's the saved PC that failed.
        #expect(Recipe.connectedSavedPC(desktopAppeared: false, pressed: host, host: host, previous: nil) == nil)
        #expect(Recipe.connectedSavedPC(desktopAppeared: false, pressed: host, host: host, previous: host) == nil)
        // A tile pressed for a name Windows no longer has.
        #expect(Recipe.connectedSavedPC(desktopAppeared: true, pressed: "winlab01.local", host: host, previous: nil) == nil)
        // Remembered for an old name: dropped once the host has changed.
        #expect(Recipe.connectedSavedPC(desktopAppeared: true, pressed: nil, host: host, previous: "winlab01.local") == nil)
    }

    @Test("A one-off connection leaves what was remembered for this host as it was")
    func oneOffKeeps() {
        #expect(Recipe.connectedSavedPC(desktopAppeared: true, pressed: nil, host: host, previous: host) == host)
        #expect(Recipe.connectedSavedPC(desktopAppeared: false, pressed: nil, host: host, previous: host) == host)
    }

    /// The pieces the live machine's Connect reports through: `openDesktop` is true only for a pressed
    /// tile, and Connect presses no tile named after a host another account's saved PC is for.
    @Test("Connect reports a pressed tile only when it pressed one")
    func openDesktop() throws {
        var oneOffs = 0
        let pressed = try Connection.openDesktop(host: host, user: "Bruno", accessibility: { true }, saved: { _ in true },
                                                 oneOff: { _, _ in oneOffs += 1; return true })
        #expect(pressed && oneOffs == 0)
        let fellBack = try Connection.openDesktop(host: host, user: "Bruno", accessibility: { true }, saved: { _ in false },
                                                  oneOff: { _, _ in oneOffs += 1; return true })
        #expect(!fellBack && oneOffs == 1)
        let noAccess = try Connection.openDesktop(host: host, user: "Bruno", accessibility: { false }, saved: { _ in true },
                                                  oneOff: { _, _ in oneOffs += 1; return true })
        #expect(!noAccess && oneOffs == 2)
        // Another account's saved PC for this host, and none of this VM's by a name of its own: no tile
        // to press, so `openSavedPC` answers false before looking.
        #expect(WindowsApp.tileNames(host: host, savedName: nil, otherAccountHost: host).isEmpty)
    }

    @Test("The snapshot carries the pressed tile from the machine to the window")
    func carried() {
        var readings = SetupRunner.Readings()
        readings.savedPCPressed = host
        let facts = SetupRunner.facts(from: readings, stamp: .init(taken: Date(), utmPIDs: [], vmPID: nil),
                                      answers: .init(), previous: nil, after: nil)
        #expect(facts.savedPCPressed == host)
    }

    @Test("It is one VM's setting, and a report masks the host it names")
    func setting() {
        #expect(Config.Key.perVM.contains(Config.Key.savedPCConnectedHost))
        #expect(Config.Key.all.contains(Config.Key.savedPCConnectedHost))
        #expect(Diagnose.windowsPCNamesFromSettings(["vm.a.savedPCConnectedHost": host]) == ["winlab02"])
    }
}

/// The wiring, which runs against the Mac's own settings, Windows App and its Accessibility tree, so it
/// is read as text, the way `SavedPCAccountTests.wiring` reads C2's no-answer branch. Control: put
/// `Config.savedPCHost = host` back in `openSavedPC`, or drop the machine's `pressedSavedPC = nil`, and
/// this fails.
@Suite("The evidence is wired where the Mac is")
struct ConnectEvidenceWiringTests {
    private func source(_ file: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/Winbar/\(file)"), encoding: .utf8)
    }

    private func body(of start: String, in text: String, length: Int) throws -> Substring {
        let found = try #require(text.range(of: start), "\(start)")
        return text[found.upperBound...].prefix(length)
    }

    @Test("C2 counts the Connect only when Windows App can't answer, and forgets it when Windows App has none")
    func recipe() throws {
        let recipe = try source("Recipe.swift")
        let failure = try body(of: "// Windows App wouldn't say. Fall back to what Winbar has seen and been told", in: recipe,
                               length: 500)
        #expect(failure.contains("Recipe.unansweredSavedPCStatus(") && failure.contains("connectedHost: Config.savedPCConnectedHost"))
        let success = try body(of: "Recipe.rememberSavedPC(lookup, host: host, for: ctx)", in: recipe, length: 400)
        #expect(success.contains("if lookup.mine == nil { Recipe.forgetConnectedSavedPC(for: ctx) }"))
    }

    @Test("Finding a tile no longer counts as anyone's word; a press is reported only when it happened")
    func connect() throws {
        let openSavedPC = try body(of: "static func openSavedPC(host: String) -> Bool {", in: try source("WindowsApp.swift"),
                                   length: 3000)
        #expect(!openSavedPC.contains("Config.savedPCHost = host"))
        let live = try source("SetupRunnerLive.swift")
        let connect = try body(of: "case .connect:\n", in: live, length: 900)
        #expect(connect.hasPrefix("            pressedSavedPC = nil\n"), "a press from an earlier Connect would stand")
        #expect(connect.contains("if try Connection.openDesktop(host: host, user: ctx.rdpUser) { pressedSavedPC = host }"))
        #expect(live.contains("readings.savedPCPressed = pressedSavedPC"))
        #expect(live.contains("if changed { pressedSavedPC = nil }"))
    }

    @Test("The window remembers the answer only for the VM Winbar looks after")
    func window() throws {
        let live = try body(of: "static let live = SetupSettings(", in: try source("SetupWindow.swift"), length: 900)
        #expect(live.contains("facts.chosenVM == vm") && live.contains("facts.chosenID == Config.vmID"))
        #expect(live.contains("Config.savedPCConnectedHost = Recipe.connectedSavedPC("))
    }
}

@Suite("C2 when Windows App can't answer")
struct UnansweredSavedPCTests {
    private let failure = WindowsAppBookmarks.Failure.failed(what: "list its saved PCs",
                                                             output: WindowsAppBookmarks.Copy.readsPaused).description

    private func status(configured: Bool = true, memory: SavedPCMemory = SavedPCMemory(), connected: String?) -> Status {
        Recipe.unansweredSavedPCStatus(host: host, user: "Bruno", failure: failure, configuredVM: configured,
                                       memory: memory, connectedHost: connected)
    }

    /// A row's kind and its words, which is what the window draws of it.
    private func ok(_ status: Status) -> String? {
        if case .ok(let words) = status { return words }
        return nil
    }

    @Test("A Connect that used the saved PC reads ok, in its own words")
    func connectUsedIt() {
        #expect(ok(status(connected: host)) == "winlab02.local (saved in Windows App; Connect used it)")
        #expect(ok(status(connected: "WINLAB02.LOCAL")) == "winlab02.local (saved in Windows App; Connect used it)")
        #expect(ok(status(memory: SavedPCMemory(name: "Studio"), connected: host)) == "Studio (saved in Windows App; Connect used it)")
    }

    /// Control: drop the `configuredVM` test, or compare against nothing, and these read ok.
    @Test("Not for another host, and not for a VM Winbar doesn't look after")
    func notFooled() {
        guard case .manual(let detail, let how) = status(connected: "winlab01.local") else {
            Issue.record("\(status(connected: "winlab01.local"))")
            return
        }
        #expect(WindowsAppBookmarks.Copy.saysNoAnswer(detail))
        #expect(how == WindowsAppBookmarks.Copy.byHand(host: host, user: "Bruno"))
        if case .ok = status(configured: false, connected: host) { Issue.record("another VM's run counted it") }
        if case .ok = status(connected: nil) { Issue.record("nothing counted as saved") }
    }

    @Test("The person's word still counts, and the Connect is the stronger")
    func word() {
        #expect(ok(status(memory: SavedPCMemory(host: host), connected: nil)) == "winlab02.local (saved earlier; Windows App didn't answer)")
        #expect(ok(status(memory: SavedPCMemory(host: host), connected: host)) == "winlab02.local (saved in Windows App; Connect used it)")
    }
}

@MainActor @Suite("Through the window: Connect, the answer, and the step bar")
struct ConnectEvidenceWindowTests {
    /// Connect run through the controller on a Mac whose saved-PC read never answers, answered `yes`,
    /// with the machine reporting `pressed` as the tile it pressed. What the window handed over to
    /// remember, as the live setting would keep it.
    private func connect(pressed: String?, answer: Bool?) async
        -> (remembered: String?, calls: Int, controller: SetupWindowController, machine: RevisitMachine) {
        let machine = RevisitMachine()
        machine.c2 = SilentFixtures.status
        machine.pressed = pressed
        var remembered: String?
        var calls = 0
        let controller = RevisitHarness.controller(machine, state: RevisitHarness.state(.connect), remember: { yes, facts in
            calls += 1
            remembered = Recipe.connectedSavedPC(desktopAppeared: yes, pressed: facts.savedPCPressed, host: facts.rdpHost,
                                                 previous: remembered)
        })
        controller.attach()
        controller.send(.perform(.run(.connect)))
        await RevisitHarness.settle(controller) {
            controller.state.lastEnding?.work == .connect && controller.state.inFlight == nil
        }
        #expect(controller.state.answers.connectionOpened)
        if let answer { controller.send(.connected(answer)) }
        return (remembered, calls, controller, machine)
    }

    @Test("A pressed tile and Yes are handed over to remember; the one-off, No and no answer leave nothing")
    func handedOver() async {
        let yes = await connect(pressed: host, answer: true)
        #expect(yes.remembered == host && yes.calls == 1)
        let oneOff = await connect(pressed: nil, answer: true)
        #expect(oneOff.remembered == nil)
        let no = await connect(pressed: host, answer: false)
        #expect(no.remembered == nil)
        let unanswered = await connect(pressed: host, answer: nil)
        #expect(unanswered.remembered == nil && unanswered.calls == 0)
        let renamed = await connect(pressed: "winlab01.local", answer: true)
        #expect(renamed.remembered == nil)
        for run in [yes, oneOff, no, unanswered, renamed] {
            run.controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        }
    }

    /// The whole of it: the saved PC skipped because Windows App's command line never answered, a
    /// Connect through its tile, Yes, and the next read counts it — so the step isn't flagged.
    @Test("Skipped, then used by Connect: the next read counts the saved PC and the bar doesn't flag it")
    func notFlaggedOnceUsed() async {
        let run = await connect(pressed: host, answer: true)
        let controller = run.controller
        #expect(controller.state.answers.leftAlone.contains("C2"))
        run.machine.c2 = Recipe.unansweredSavedPCStatus(host: host, user: "Bruno", failure: WindowsAppBookmarks.Copy.readsPaused,
                                                    configuredVM: true, memory: SavedPCMemory(),
                                                    connectedHost: run.remembered)
        controller.send(.next)
        await RevisitHarness.settle(controller) {
            controller.state.lastEnding?.work == .checkAgain(.finish) && controller.state.inFlight == nil
        }
        #expect(controller.state.facts?.kind("C2") == .ok)
        #expect(!StepBar.flagged(controller.state).contains(.savedPC), "\(StepBar.flagged(controller.state))")
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
    }
}
