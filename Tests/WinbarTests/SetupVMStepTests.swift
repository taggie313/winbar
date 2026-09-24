import AppKit
import SwiftUI
import Testing
@testable import Winbar

// Step 2, The VM: its main action in the footer's corner, the other ways on in one row at the foot
// of its card, and a list of VMs as rows to tick. Every screen is an invented fixture drawn offscreen
// or read as a value; nothing asks UTM, starts a VM or touches the Mac.

/// The VM step's screens, by the names their renders are filed under.
enum VMStepFixtures {
    static func screen(_ name: String) throws -> SetupWindowState {
        if let state = SetupFixtures.screens.first(where: { $0.name == name })?.state { return state }
        return try #require(SetupRecoveryFixtures.screens.first { $0.0 == name }?.1, "no fixture \(name)")
    }

    /// Chosen and stopped, with Start It pressed and the wait running.
    static var starting: SetupWindowState {
        var state = SetupFixtures.state(.vm, facts: JourneyFixtures.facts)
        state.facts?.vmRunning = false
        state.inFlight = .init(work: .startVM("winlab02"), started: testMoment(), vm: "winlab02",
                               line: SetupCopy.waitingForWindows)
        return state
    }

    /// Three VMs as UTM reports them, with the states a row shows: two Windows, one Linux.
    static let three: [VMInfo] = [
        VMInfo(id: "5A1E0C3D-0000-4000-8000-000000000021", name: "winlab01", status: "started", backend: "qemu", icon: "windows"),
        VMInfo(id: "5A1E0C3D-0000-4000-8000-000000000022", name: "winlab03", status: "stopped", backend: "qemu", icon: "windows-11"),
        VMInfo(id: "5A1E0C3D-0000-4000-8000-000000000023", name: "atelier", status: "paused", backend: "qemu", icon: "debian"),
    ]

    /// One Windows VM and a Linux one: the Windows one is ticked for the person, and they may tick
    /// the other.
    static func windowsAndLinux(ticking id: String? = nil) -> SetupWindowState {
        var state = SetupFixtures.state(.vm, facts: SetupFixtures.facts(utm: SetupFixtures.installed, answers: .answered,
                                                                        vms: .listed([three[0], three[2]])))
        state.pickedVM = id
        return state
    }

    static var choosingThree: SetupWindowState {
        SetupFixtures.state(.vm, facts: SetupFixtures.facts(utm: SetupFixtures.installed, answers: .answered,
                                                            vms: .listed(three)))
    }
}

@MainActor private func drawn(_ state: SetupWindowState, _ sent: Sent) -> Pressing<SetupScreen> {
    Pressing(SetupScreen(state: state, art: nil, savePassword: sent.save, send: sent.send))
}

@MainActor @Suite("The VM step: its action in the footer's corner")
struct VMStepFooterTests {
    private func corner(_ state: SetupWindowState) -> SetupFooter.Button? { SetupFooter.footer(state).corner }

    @Test("Each page hands the corner its way forward, filled and on Return")
    func eachPage() throws {
        let cases: [(String, String, SetupCommand)] = [
            ("vm-none", SetupCopy.VM.bMakeOne, .newWindowsVM),
            ("vm-one", "Use “winlab01”", .useVM(name: "winlab01", id: "5A1E0C3D-0000-4000-8000-00000000000D")),
            ("vm-stopped-restart-owed", SetupCopy.VM.bStartIt, .startVM("winlab02")),
            ("vm-ready", SetupCopy.journeyNext(.vm, facts: nil), .continueFromVM),
            ("vm-installing", SetupCopy.VM.bShowInstallProgress, .newWindowsVM),
            ("vm-unlisted", SetupCopy.VM.bGoBack, .back),
            ("vm-linux-only", SetupCopy.VM.bMakeNew, .newWindowsVM),
        ]
        for (name, title, command) in cases {
            let footer = SetupFooter.footer(try VMStepFixtures.screen(name))
            #expect(footer.corner == .init(title, command, kind: .primary), "\(name): \(String(describing: footer.corner))")
            #expect(footer.holdsDefault(), "\(name)")
            #expect(footer.leading.map(\.title) == [SetupCopy.bBack, SetupCopy.bCheckAgain], "\(name)")
        }
    }

    /// The start's wait ends by itself; a greyed-out Start It beside it would be a button nothing can
    /// press for three minutes. Looking after an install, and a read with nothing known, have none either.
    @Test("Nothing in the corner while Windows starts, or while there is nothing to press")
    func nothingWhileWaiting() throws {
        #expect(corner(VMStepFixtures.starting) == nil)
        var after = try VMStepFixtures.screen("vm-ready")
        after.afterInstall = testMoment()
        #expect(corner(after) == nil)
        #expect(corner(SetupFixtures.state(.vm, facts: nil)) == nil)
        // A read: the corner's greyed-out Install Windows… and Check Again aren't drawn until it ends.
        // Back is: a read changes nothing the step decided (`SetupFooter.backable`).
        var reading = try VMStepFixtures.screen("vm-none")
        reading.inFlight = .init(work: .checkAgain(.vm), started: testMoment(), vm: nil)
        #expect(SetupVMView.footerAction(reading)?.enabled == false)
        #expect(SetupFooter.footer(reading) == SetupFooter(leading: [.init(SetupCopy.bBack, .back)]))
    }

    /// Two Windows VMs: nothing is ticked for the person, so Use is greyed out until a row is.
    @Test("A list with nothing ticked greys out Use; a tick names the VM in it")
    func list() throws {
        var state = try VMStepFixtures.screen("vm-choose")
        #expect(corner(state) == .init(SetupCopy.VM.bUseThisOne, .useVM(name: "", id: ""), enabled: false, kind: .primary,
                                       reason: SetupCopy.VM.pickFirst))
        state.pickedVM = SetupVMTests.new.id
        #expect(corner(state) == .init("Use “winlab02”", .useVM(name: "winlab02", id: SetupVMTests.new.id), kind: .primary))
    }

    /// Drawn: Return presses what the corner says, and the one filled button is in the footer, not
    /// the card, where the review found it on the right on one page and the left on the next.
    @Test("Drawn, Return presses the corner's action, and the filled button is the footer's",
          arguments: ["vm-none", "vm-one", "vm-stopped-restart-owed", "vm-ready", "vm-unlisted"])
    func drawnReturn(name: String) throws {
        let state = try VMStepFixtures.screen(name)
        let sent = Sent()
        #expect(drawn(state, sent).press(.return), "\(name): nothing took Return")
        #expect(sent.commands == [try #require(SetupFooter.footer(state).corner).press].compactMap {
            if case .send(let command) = $0 { return command }
            return nil
        })
        for appearance in [Snapshot.Appearance.light, .dark] {
            let fill = SetupStyle.palette(dark: appearance.isDark, increasedContrast: false).accentFill
            let filled = Drawing.filled(fill, in: try render(state, appearance))
            #expect(filled.count == 1 && filled.allSatisfy { $0.minY > setupWindowSize.height - setupFooterBand },
                    "\(name), \(appearance.rawValue): \(filled)")
        }
    }
}

@MainActor @Suite("The VM step: the other ways on, in one row at the card's foot")
struct VMStepAlternativesTests {
    @Test("Each page's alternatives, and none while Windows starts")
    func alternatives() throws {
        func titles(_ state: SetupWindowState) throws -> [String] {
            let facts = try #require(state.facts)
            return SetupVMView.alternatives(state, SetupVMView.screen(state, facts), facts).map(\.title)
        }
        let both = [SetupCopy.VM.bMakeNew, SetupCopy.VM.bChooseAnother]
        #expect(try titles(VMStepFixtures.screen("vm-ready")) == both)
        #expect(try titles(VMStepFixtures.screen("vm-stopped-restart-owed")) == both)
        #expect(try titles(VMStepFixtures.screen("vm-one")) == [SetupCopy.VM.bMakeNew])
        #expect(try titles(VMStepFixtures.screen("vm-choose")) == [SetupCopy.VM.bMakeNew])
        #expect(try titles(VMStepFixtures.screen("vm-none")).isEmpty)
        #expect(try titles(VMStepFixtures.screen("vm-linux-only")) == ["Use “atelier”"])
        #expect(try titles(VMStepFixtures.starting).isEmpty)
    }

    /// Read off the drawn page: the two alternatives share a line, where they were a column under the
    /// main button; and the sentence saying what Start It does comes before them, not under them.
    @Test("Drawn, the alternatives share one row, under the words that explain Start It",
          arguments: [Snapshot.Appearance.light, .dark])
    func oneRow(appearance: Snapshot.Appearance) throws {
        let lines = try Drawing.lines(try render(try VMStepFixtures.screen("vm-stopped-restart-owed"), appearance))
        let makeNew = try #require(Drawing.find(SetupCopy.VM.bMakeNew, in: lines), "\(lines)")
        let another = try #require(Drawing.find(SetupCopy.VM.bChooseAnother, in: lines), "\(lines)")
        #expect(abs(makeNew.frame.midY - another.frame.midY) < 4, "\(makeNew) \(another)")
        #expect(another.frame.minX > makeNew.frame.maxX)
        let consequence = try #require(Drawing.find("only while no other VM", in: lines), "\(lines)")
        #expect(consequence.frame.maxY < makeNew.frame.minY, "\(consequence) \(makeNew)")
        let startIt = try #require(lines.last { $0.text == SetupCopy.VM.bStartIt }, "\(lines)")
        #expect(startIt.frame.minY > setupWindowSize.height - setupFooterBand, "\(startIt)")
    }
}

@MainActor @Suite("The VM step: the VMs as rows to tick")
struct VMChoiceRowTests {
    /// The only VM marked Windows is ticked for the person — the one `winbar setup` takes without
    /// asking — so the likeliest answer is one Return away; with two Windows VMs, neither is.
    @Test("The only Windows VM is ticked before anything is; a tick wins")
    func preselection() throws {
        let one = try VMStepFixtures.screen("vm-one")
        let facts = try #require(one.facts)
        let rows = SetupVMView.rows(SetupVMView.screen(one, facts), facts)
        #expect(rows.map(\.name) == ["winlab01", "atelier"])
        #expect(SetupVMView.picked(one, in: rows)?.name == "winlab01")
        var ticked = one
        ticked.pickedVM = rows[1].id
        #expect(SetupVMView.picked(ticked, in: rows)?.name == "atelier")
        // It doesn't say it's Windows, so its Use is in the card and the corner installs Windows
        // instead, as the caution under the list says (`VMTickedRowTests`).
        #expect(SetupFooter.footer(ticked).corner?.title == SetupCopy.VM.bMakeNew)
        #expect(SetupVMView.alternatives(ticked, SetupVMView.screen(ticked, facts), facts).map(\.title) == ["Use “atelier”"])

        let three = VMStepFixtures.choosingThree
        let threeFacts = try #require(three.facts)
        let threeRows = SetupVMView.rows(SetupVMView.screen(three, threeFacts), threeFacts)
        #expect(threeRows.map(\.name) == ["winlab01", "winlab03", "atelier"])
        #expect(SetupVMView.picked(three, in: threeRows) == nil)
        // A tick that is no longer on the list (the VM was deleted in UTM) isn't a choice.
        var stale = three
        stale.pickedVM = "5A1E0C3D-0000-4000-8000-0000000000FF"
        #expect(SetupVMView.picked(stale, in: threeRows) == nil)
    }

    @Test("A page with one VM names it in a sentence, with no list of one")
    func noListOfOne() throws {
        for name in ["vm-linux-only", "vm-none"] {
            let state = try VMStepFixtures.screen(name)
            let facts = try #require(state.facts)
            #expect(SetupVMView.rows(SetupVMView.screen(state, facts), facts).isEmpty, "\(name)")
        }
    }

    @Test("A row says what the VM is and how it stands, as far as UTM says")
    func rowDetail() {
        let rows = VMStepFixtures.three.map(SetupCopy.VM.rowDetail)
        #expect(rows == ["Windows · Running", "Windows · Stopped", "Linux · Paused"])
        #expect(SetupCopy.VM.rowDetail(VMInfo(name: "handmade", backend: "qemu", icon: "generic")) == nil)
        #expect(SetupCopy.VM.rowDetail(VMInfo(name: "handmade", status: "starting", backend: "qemu")) == "Starting")
    }

    /// Drawn: every VM's name and state is on the page, and the one ticked says so to VoiceOver. The
    /// pop-up it replaces showed "Choose a VM…" and neither name.
    @Test("Drawn, each VM is a row with its name and state", arguments: [Snapshot.Appearance.light, .dark])
    func drawnRows(appearance: Snapshot.Appearance) throws {
        let lines = try Drawing.lines(try render(VMStepFixtures.choosingThree, appearance))
        // Text recognition reads the middle dot as a hyphen or a bullet, so the states are found alone.
        for words in ["winlab01", "winlab03", "atelier", "Running", "Stopped", "Paused"] {
            #expect(Drawing.find(words, in: lines) != nil, "\(words) not drawn: \(lines)")
        }
        #expect(Drawing.find("Choose a VM", in: lines) == nil)
        let first = try #require(Drawing.find("winlab01", in: lines))
        let second = try #require(Drawing.find("winlab03", in: lines))
        #expect(second.frame.minY - first.frame.minY >= 40, "rows under 44 pt: \(first) \(second)")
    }

    @Test("VoiceOver hears the row's name and state, and which one is ticked")
    func spoken() {
        #expect(VMChoiceRow.spoken(VMStepFixtures.three[0]) == "winlab01, Windows · Running")
        let ticked = WinbarTests.accessibility(of: VMChoiceRow(vm: VMStepFixtures.three[0], selected: true, press: {}).body)
        let plain = WinbarTests.accessibility(of: VMChoiceRow(vm: VMStepFixtures.three[0], selected: false, press: {}).body)
        #expect(ticked.contains("winlab01, Windows · Running"))
        // The ring is inside a closure the description doesn't reach, so the one difference between a
        // ticked row and a plain one here is the trait VoiceOver reads.
        #expect(ticked.contains("TraitsKey") && ticked != plain)
    }
}

@MainActor @Suite("The VM step: the sentence and the corner follow the ticked row")
struct VMTickedRowTests {
    private typealias F = VMStepFixtures

    @Test("The Windows row ticked: the sentence names its Use, which is the corner")
    func windowsTicked() throws {
        let state = F.windowsAndLinux()
        let facts = try #require(state.facts)
        let screen = SetupVMView.screen(state, facts)
        guard case .choose(.one(let vm), _) = screen, !SetupVMView.rows(screen, facts).isEmpty else {
            Issue.record("not the one-Windows-VM list: \(screen)")
            return
        }
        #expect(vm.name == "winlab01" && SetupVMView.useNamed(state, screen, facts) == "winlab01")
        #expect(SetupFooter.footer(state).corner?.title == "Use “winlab01”")
    }

    /// The probe: ticking the Linux VM left "If you choose Use “winlab01”" above a filled Use
    /// “atelier” that Return pressed, under a caution saying to install Windows in a new VM instead.
    @Test("The Linux row ticked: no sentence names a Use that isn't there, and the corner is Install Windows")
    func linuxTicked() throws {
        let atelier = F.three[2]
        let state = F.windowsAndLinux(ticking: atelier.id)
        let facts = try #require(state.facts)
        let screen = SetupVMView.screen(state, facts)
        #expect(SetupVMView.useNamed(state, screen, facts) == nil)
        #expect(SetupFooter.footer(state).corner == .init(SetupCopy.VM.bMakeNew, .newWindowsVM, kind: .primary))
        #expect(SetupVMView.alternatives(state, screen, facts)
                == [.init(title: "Use “atelier”", command: .useVM(name: atelier.name, id: atelier.id))])
        let sent = Sent()
        #expect(Pressing(SetupScreen(state: state, art: nil, send: sent.send)).press(.return))
        #expect(sent.commands == [.newWindowsVM])
        let png = try render(state, .light)
        try Snapshot.record(png, as: "vm-one-ticked-linux-light")
        try Snapshot.record(try render(state, .dark), as: "vm-one-ticked-linux-dark")
        let lines = try Drawing.lines(png)
        #expect(!lines.contains { $0.text.contains("Use “winlab01”") || $0.text.contains("Use \"winlab01\"") }, "\(lines)")
        #expect(Drawing.find("Use", in: lines.filter { $0.text.contains("atelier") }) != nil, "\(lines)")
    }
}

@MainActor @Suite("The VM step: the start's wait has a way out")
struct VMStartWaitTests {
    /// Terminal's lines name the guest agent, a word Ben doesn't have; the window says what it waits
    /// for and how long, and leaves anything else as it was said.
    @Test("The start's lines, in the window's words")
    func words() {
        let waiting = SetupCopy.Working.windowLine(SetupCopy.waitingForWindows)
        let slow = SetupCopy.Working.windowLine(SetupCopy.agentNotYet)
        #expect(waiting == SetupCopy.Working.startWaiting && waiting.contains("three minutes"))
        #expect(slow == SetupCopy.Working.startSlow)
        for line in [waiting, slow] { #expect(!line.localizedCaseInsensitiveContains("agent"), "\(line)") }
        #expect(SetupCopy.Working.windowLine("Asking UTM…") == "Asking UTM…")
    }

    /// Drawn in the card, with Stop Waiting pressable while everything else on the page is greyed out:
    /// its title measured at the accent's contrast, where a greyed-out title is under 2:1.
    @Test("Drawn, the card says what it waits for, and Stop Waiting can be pressed",
          arguments: [Snapshot.Appearance.light, .dark])
    func stopWaiting(appearance: Snapshot.Appearance) throws {
        let png = try render(ArmieFixtures.hidden(ArmieFixtures.starting), appearance)
        let lines = try Drawing.lines(png)
        #expect(Drawing.find("Waiting for Windows to start", in: lines) != nil, "\(lines)")
        #expect(Drawing.find("guest agent", in: lines) == nil, "\(lines)")
        let stop = try #require(Drawing.find(SetupCopy.Working.bStopWaiting, in: lines), "\(lines)")
        #expect(stop.frame.maxY < setupWindowSize.height - setupFooterBand, "in the card, not the footer: \(stop)")
        let contrast = try #require(Drawing.inkContrast(png, in: stop.frame.insetBy(dx: -2, dy: -2)))
        #expect(contrast >= 3, "\(appearance.rawValue): Stop Waiting drawn greyed out, \(contrast)")
        // What stopping does is said beside it.
        let consequence = try #require(Drawing.find(SetupCopy.Working.stopStart, in: lines), "\(lines)")
        #expect(abs(consequence.frame.midY - stop.frame.midY) < 8, "\(consequence) \(stop)")
        // Nothing in the footer can be pressed while the start runs, so nothing greyed out is drawn
        // there: Back measured about 1.6:1.
        #expect(!lines.contains { $0.text == SetupCopy.bBack || $0.text == SetupCopy.bCheckAgain }, "\(lines)")
        // The control for the contrast: the same button greyed out measures well under 3:1.
        let greyed = try #require(Snapshot.png(Button(SetupCopy.Working.bStopWaiting) {}.disabled(true).controlSize(.large)
                                                   .padding(30), size: CGSize(width: 240, height: 100), appearance: appearance))
        let greyedLine = try #require(Drawing.find(SetupCopy.Working.bStopWaiting, in: try Drawing.lines(greyed)))
        #expect(try #require(Drawing.inkContrast(greyed, in: greyedLine.frame.insetBy(dx: -2, dy: -2))) < 3)
    }

    @Test("Stop Waiting is offered for a start, and not for a read")
    func onlyForTheStart() {
        #expect(SetupRunner.Work.startVM("winlab02").canStopWaiting)
        #expect(!SetupRunner.Work.checkAgain(.vm).canStopWaiting)
        #expect(!SetupRunner.Work.chooseVM("winlab02", id: nil).canStopWaiting)
    }
}

@MainActor @Suite("The VM step: the setup disk an install couldn't delete")
struct SetupDiskTests {
    static let left = CreateMessage(code: SetupDiskActions.leftCode, text: "Couldn't delete the setup disk at "
                                    + "/tmp/example.noindex (busy). It holds your Windows password, scrambled: delete the folder yourself.",
                                    at: testMoment())

    /// A folder as `create` makes one, in a base of the test's own: named for a job, private, marked.
    private func madeDisk() throws -> (base: URL, disk: URL) {
        let base = try temporaryDirectory("winbar-setup-disk")
        let disk = base.appendingPathComponent("5d2c7a10-test.noindex", isDirectory: true)
        #expect(mkdir(disk.path, 0o700) == 0)
        chmod(disk.path, 0o700)
        try Data("winbar create\n".utf8).write(to: disk.appendingPathComponent(SetupMedia.marker))
        return (base, disk)
    }

    private final class Calls {
        var trashed: [URL] = []
        var revealed: [URL] = []
        var fails: Error?
    }

    private func actions(_ calls: Calls, base: URL) -> SetupDiskActions {
        SetupDiskActions(base: { base }, reveal: { calls.revealed.append($0) }, trash: { url in
            if let error = calls.fails { throw error }
            calls.trashed.append(url)
        })
    }

    private func state(disk: String?) -> SetupWindowState {
        var state = SetupFixtures.state(.vm, facts: JourneyFixtures.facts)
        state.installMessages = [Self.left]
        state.setupDisk = disk
        return state
    }

    @Test("The install hands back the folder it couldn't delete, and only that one")
    func handedBack() {
        var job = testState(vmID: SetupVMTests.new.id, outcome: .done)
        job.mediaDir = "/tmp/example.noindex"
        #expect(CreateWindowController.embeddedEnd(for: job, embedded: true)
                == .installed(id: SetupVMTests.new.id, name: job.plan.vmName, messages: [], setupDisk: nil))
        job.messages = [Self.left]
        #expect(CreateWindowController.embeddedEnd(for: job, embedded: true)
                == .installed(id: SetupVMTests.new.id, name: job.plan.vmName, messages: [Self.left],
                              setupDisk: "/tmp/example.noindex"))
    }

    @Test("Move to Trash moves the setup disk, and the warning becomes a note saying where it went")
    func trashes() throws {
        let (base, disk) = try madeDisk()
        defer { try? FileManager.default.removeItem(at: base) }
        let calls = Calls()
        let next = SetupDiskActions.trashing(state(disk: disk.path), with: actions(calls, base: base))
        #expect(calls.trashed.map(\.standardizedFileURL.path) == [disk.standardizedFileURL.path])
        #expect(next.setupDisk == nil)
        #expect(next.installMessages.map(\.code) == [SetupDiskActions.trashedCode])
        #expect(next.installMessages.first?.text.contains("Empty the Trash") == true)
    }

    /// The path comes from the install's state file; a state naming any folder that isn't a setup disk
    /// `create` made moves nothing — here, one without the marker, and one outside Winbar's folder.
    @Test("Anything but a setup disk Winbar made is left alone, and the note says why")
    func onlyOurs() throws {
        let (base, disk) = try madeDisk()
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.removeItem(at: disk.appendingPathComponent(SetupMedia.marker))
        let elsewhere = try temporaryDirectory("winbar-not-ours")
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        for path in [disk.path, elsewhere.path] {
            let calls = Calls()
            let next = SetupDiskActions.trashing(state(disk: path), with: actions(calls, base: base))
            #expect(calls.trashed.isEmpty, "\(path)")
            #expect(next.setupDisk == path)
            #expect(next.installMessages.map(\.code) == [SetupDiskActions.leftCode, SetupDiskActions.notTrashedCode])
        }
    }

    @Test("A Trash that refuses leaves the warning and its buttons, says why once, and a retry can succeed")
    func refused() throws {
        let (base, disk) = try madeDisk()
        defer { try? FileManager.default.removeItem(at: base) }
        let calls = Calls()
        calls.fails = CocoaError(.fileWriteNoPermission)
        var next = SetupDiskActions.trashing(state(disk: disk.path), with: actions(calls, base: base))
        next = SetupDiskActions.trashing(next, with: actions(calls, base: base))
        #expect(next.setupDisk == disk.path)
        #expect(next.installMessages.map(\.code) == [SetupDiskActions.leftCode, SetupDiskActions.notTrashedCode])
        calls.fails = nil
        next = SetupDiskActions.trashing(next, with: actions(calls, base: base))
        #expect(next.installMessages.map(\.code) == [SetupDiskActions.trashedCode] && next.setupDisk == nil)
    }

    @Test("The window's two buttons reach the Finder and the Trash through its own actions, and nothing else")
    func controller() throws {
        let (base, disk) = try madeDisk()
        defer { try? FileManager.default.removeItem(at: base) }
        let calls = Calls()
        let window = SetupWindowController(state: state(disk: disk.path), art: nil,
                                           settings: .init(wizardShown: { true }, markShown: {}, armieHidden: { true }, hideArmie: {}),
                                           setupDisk: actions(calls, base: base))
        window.send(.showSetupDisk)
        #expect(calls.revealed.map(\.standardizedFileURL.path) == [disk.standardizedFileURL.path])
        window.send(.trashSetupDisk)
        #expect(calls.trashed.count == 1 && window.state.setupDisk == nil)
        window.send(.trashSetupDisk)
        window.send(.showSetupDisk)
        #expect(calls.trashed.count == 1 && calls.revealed.count == 1)
    }

    /// Drawn: the note says what the disk is and what to do, with the two buttons, not the job's path
    /// and error. The same message with no folder handed back — an older Winbar's install — is shown as
    /// it was said, with no buttons that would have nothing to act on.
    @Test("Drawn, the note offers Show in Finder and Move to Trash", arguments: [Snapshot.Appearance.light, .dark])
    func drawn(appearance: Snapshot.Appearance) throws {
        var state = try VMStepFixtures.screen("vm-ready")
        state.installMessages = [Self.left]
        state.setupDisk = "/tmp/example.noindex"
        let png = try render(state, appearance)
        let lines = try Drawing.lines(png)
        let show = try #require(Drawing.find(SetupCopy.VM.bShowSetupDisk, in: lines), "\(lines)")
        let trash = try #require(Drawing.find(SetupCopy.VM.bTrashSetupDisk, in: lines), "\(lines)")
        #expect(abs(show.frame.midY - trash.frame.midY) < 4)
        #expect(Drawing.find("example.noindex", in: lines) == nil)
        try Snapshot.record(png, as: "vm-setup-disk-left-\(appearance.rawValue)")

        state.setupDisk = nil
        let bare = try Drawing.lines(try render(state, appearance))
        #expect(Drawing.find(SetupCopy.VM.bTrashSetupDisk, in: bare) == nil)
        #expect(Drawing.find("delete the folder yourself", in: bare) != nil, "\(bare)")

        state.installMessages = [CreateMessage(code: SetupDiskActions.trashedCode, text: SetupCopy.VM.setupDiskTrashed,
                                               at: testMoment())]
        try Snapshot.record(try render(state, appearance), as: "vm-setup-disk-trashed-\(appearance.rawValue)")
    }
}

// MARK: - The install, as step 2

@MainActor private func installPage(_ job: CreateJobState, ownsJob: Bool = true) -> (ArmieHost?) -> AnyView {
    let controller = ArmieFixtures.createController(ownsJob: ownsJob)
    controller.draw(job)
    return { armie in AnyView(CreateRootView(controller: controller, armie: armie)) }
}

@MainActor @Suite("The install as step 2: its count, its times, and its footer")
struct InstallPageTests {
    private typealias A = ArmieFixtures

    /// "step 6 of 10" sat under the window's "Step 3 of 8"; "14:32" and "9:48" said nothing of what
    /// they counted.
    @Test("The install's own count is a stage with its name, and its times say what they are")
    func words() {
        let progress = CreateProgress(state: A.job(), now: SetupFixtures.started)
        #expect(progress.step == "Stage 6 of 10 · Copying files")
        #expect(progress.soFar == "14 min so far · usually 10–15 min")
        #expect(progress.rows[5].elapsed == "9 min")
        #expect(CreateCopy.pStage(.check) == "Stage 1 of 10 · Checking the ISO and UTM")
        #expect(CreateCopy.pSoFar(20) == "less than a minute so far · usually 10–15 min")
    }

    @Test("The buttons under an install: which, where, and which one Return presses")
    func actions() {
        func titles(_ actions: [CreateJobView.Action]) -> [String] { actions.map(\.title) }
        let running = CreateJobView.actions(A.job(), readOnly: false, cancelling: false)
        #expect(titles(running.leading) == [CreateCopy.bShowVM])
        #expect(titles(running.trailing) == [CreateCopy.bCancelInstall, CreateCopy.bCloseWindow])
        #expect(running.trailing.last?.kind == .standard && running.trailing.last?.press == .close)
        // A stall: Show VM Window moves from the bottom left to the corner and is the default; Close
        // Window, the default the rest of the time, is plain beside it.
        let stalled = CreateJobView.actions(A.job(), readOnly: false, cancelling: false, stalled: true)
        #expect(stalled.leading.isEmpty)
        #expect(titles(stalled.trailing) == [CreateCopy.bCancelInstall, CreateCopy.bCloseWindow, CreateCopy.bShowVM])
        #expect(stalled.trailing.map(\.kind) == [.plain, .plain, .standard] && stalled.trailing.last?.press == .showVM)
        // An install running in Terminal: this window can only be closed.
        #expect(titles(CreateJobView.actions(A.job(), readOnly: true, cancelling: false).trailing) == [CreateCopy.bCloseWindow])
        #expect(CreateJobView.actions(A.job(), readOnly: false, cancelling: true).trailing.first?.enabled == false)
        let failure = CreateFailure(code: "E_VM_STOPPED", title: "The VM stopped", detail: "", nextStep: nil)
        let failed = CreateJobView.actions(A.job(stage: .oobe, outcome: .failed, failure: failure), readOnly: false,
                                           cancelling: false)
        #expect(titles(failed.leading) == [CreateCopy.bShowVM, CreateCopy.bShowLog, CreateCopy.bDeleteVM])
        #expect(failed.leading.last?.kind == .destructive)
        #expect(failed.trailing.map(\.kind) == [.cancel, .standard] && failed.trailing.last?.press == .tryAgain)
        #expect(titles(CreateJobView.actions(A.job(stage: .finish, outcome: .done), readOnly: false, cancelling: false).trailing)
                == [CreateCopy.bDone])
    }

    /// The install's buttons are drawn in the wizard's own footer band, so nothing moves when an
    /// install starts: it drew a divider and a row of its own, 9 pt higher than the wizard's footer.
    @Test("Drawn, the install's buttons sit where the wizard's footer buttons do", arguments: [Snapshot.Appearance.light, .dark])
    func sameFooter(appearance: Snapshot.Appearance) throws {
        let page = try Drawing.lines(try render(try VMStepFixtures.screen("vm-none"), appearance))
        let install = try Drawing.lines(try render(A.hidden(A.creating), appearance, embedded: installPage(A.job())))
        let back = try #require(page.first { $0.text == SetupCopy.bBack }, "\(page)")
        let show = try #require(Drawing.find(CreateCopy.bShowVM, in: install), "\(install)")
        let close = try #require(Drawing.find(CreateCopy.bCloseWindow, in: install), "\(install)")
        #expect(abs(show.frame.midY - back.frame.midY) < 1.5, "\(show) \(back)")
        #expect(abs(close.frame.midY - back.frame.midY) < 1.5, "\(close) \(back)")
        // "Hide" sat right under "Hide Armie"; the button says what it closes.
        #expect(!install.contains { $0.text == "Hide" }, "\(install)")
    }

    /// The form comes before the install on the same step, and its pass and the install's drew their
    /// footers separately: both in the wizard's band, or Back and Continue hop when Install Windows
    /// is pressed.
    @Test("Drawn, the New Windows VM form's buttons sit where the wizard's footer buttons do",
          arguments: [Snapshot.Appearance.light, .dark])
    func formSameFooter(appearance: Snapshot.Appearance) throws {
        let page = try Drawing.lines(try render(try VMStepFixtures.screen("vm-none"), appearance))
        let back = try #require(page.first { $0.text == SetupCopy.bBack }, "\(page)")
        let controller = FormPageFixtures.controller(.account)
        let form = try Drawing.lines(try render(A.hidden(A.creating), appearance,
                                                embedded: { armie in AnyView(CreateRootView(controller: controller, armie: armie)) }))
        for title in [CreateCopy.bBack, CreateCopy.bCancel, CreateCopy.bContinue] {
            // The last line with the title: the footer is the bottom of the page.
            let button = try #require(form.last { $0.text == title }, "\(title) in \(form)")
            #expect(abs(button.frame.midY - back.frame.midY) < 1.5, "\(button) \(back)")
        }
    }

    /// A stall is the one thing on the page that needs the person: before the stages, and its button,
    /// Show VM Window, once — the footer's filled corner, which Return presses. It was a plain button
    /// in the callout while the filled default was Close Window.
    @Test("Drawn, a stall comes before the stages, and Show VM Window is the filled corner", arguments: [Snapshot.Appearance.light, .dark])
    func stallFirst(appearance: Snapshot.Appearance) throws {
        let job = A.job(stalled: .quiet, messages: A.stall)
        #expect(CreateProgress(state: job, now: SetupFixtures.started).stall != nil)
        let png = try render(A.hidden(A.creating), appearance, embedded: installPage(job))
        try Snapshot.record(png, as: "install-stalled-\(appearance.rawValue)")
        let lines = try Drawing.lines(png)
        let stall = try #require(Drawing.find("has been idle", in: lines), "\(lines)")
        let first = try #require(Drawing.find(CreateStage.check.doneTitle, in: lines), "\(lines)")
        #expect(stall.frame.maxY < first.frame.minY, "\(stall) \(first)")
        let buttons = lines.filter { $0.text.contains(CreateCopy.bShowVM) }
        #expect(buttons.count == 1, "\(buttons)")
        let fill = SetupStyle.palette(dark: appearance.isDark, increasedContrast: false).accentFill
        let filled = try #require(Drawing.filled(fill, in: png).first)
        let show = try #require(buttons.first)
        #expect(filled.insetBy(dx: -2, dy: -2).contains(CGPoint(x: show.frame.midX, y: show.frame.midY)), "\(filled) \(show)")
        #expect(show.frame.minY > setupWindowSize.height - setupFooterBand)
        // Not "You don't need to watch or click anything" under a callout asking him to look: drawn
        // tall enough to reach the page's last line.
        let tall = try Drawing.lines(try #require(Snapshot.png(SetupScreen(state: A.hidden(A.creating), art: nil,
                                                                           embedded: installPage(job), send: { _ in }),
                                                               size: CGSize(width: 600, height: 1100), appearance: appearance)))
        #expect(Drawing.find("need to watch", in: tall) == nil && Drawing.find("You can close this window", in: tall) != nil,
                "\(tall)")
        let calm = try Drawing.lines(try #require(Snapshot.png(SetupScreen(state: A.hidden(A.creating), art: nil,
                                                                           embedded: installPage(A.job()), send: { _ in }),
                                                               size: CGSize(width: 600, height: 1100), appearance: appearance)))
        #expect(Drawing.find("need to watch", in: calm) != nil, "the control, without a stall: \(calm)")
    }

    /// The quieter notes fold away; the warnings that contradict what the password copy promised stay
    /// in view; the page says the window comes back, next to its Close Window.
    @Test("Drawn, the quiet notes are folded, a boxed warning isn't, and the page says the window comes back")
    func notesFolded() throws {
        let messages = A.preflightNotes + [("W_TIMEMACHINE", "Couldn't keep the setup disk's folder out of Time Machine.")]
        let lines = try Drawing.lines(try render(A.hidden(A.creating), .light,
                                                 embedded: installPage(A.job(messages: messages))))
        #expect(Drawing.find(CreateCopy.pNotes(2), in: lines) != nil, "\(lines)")
        #expect(Drawing.find("on battery", in: lines) == nil, "\(lines)")
        #expect(Drawing.find("out of Time Machine", in: lines) != nil, "\(lines)")
        #expect(Drawing.find("comes back when Windows is ready", in: lines) != nil, "\(lines)")
        // Terminal's install: this window doesn't come back for it, and doesn't say it will.
        let cli = try Drawing.lines(try render(A.hidden(A.creating), .light, embedded: installPage(A.job(), ownsJob: false)))
        #expect(Drawing.find("comes back", in: cli) == nil, "\(cli)")
    }
}
