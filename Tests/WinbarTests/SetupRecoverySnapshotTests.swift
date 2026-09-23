import SwiftUI
import Testing
@testable import Winbar

/// Unhappy paths are part of the window's contract, not just its successful walkthrough.
/// All inputs are invented; these render without querying macOS, UTM or Windows.
enum SetupRecoveryFixtures {
    static var screens: [(String, SetupWindowState)] {
        var screens: [(String, SetupWindowState)] = []
        func add(_ name: String, _ step: WizardStep, _ change: (inout SetupWindowState) -> Void = { _ in }) {
            var state = SetupFixtures.state(step, facts: JourneyFixtures.facts)
            change(&state); state.facts?.answers = state.answers
            screens.append((name, state))
        }
        add("vm-ready", .vm)
        add("vm-stopped-restart-owed", .vm) { $0.facts?.vmRunning = false; $0.facts?.utmRestartOwed = true }
        add("vm-choose-another", .vm) { $0.choosingAnotherVM = true }
        add("vm-none", .vm) { $0.facts?.chosenVM = nil; $0.facts?.vms = .listed([]) }
        add("vm-linux-only", .vm) {
            $0.facts?.chosenVM = nil
            $0.facts?.vms = .listed([VMInfo(id: "5A1E0C3D-0000-4000-8000-000000000003", name: "atelier", backend: "qemu", icon: "debian")])
        }
        add("vm-installing", .vm) { $0.facts?.installRunning = true }
        add("vm-unlisted", .vm) { $0.facts?.vms = .notAsked }
        add("vm-messages", .vm) {
            $0.installMessages = [.init(code: "W_MEDIA_LEFT", text: "The setup disk could not be removed. It still contains the temporary answer file. Keep it private until you can delete it.", at: testMoment())]
        }
        add("certificate-needs", .certificate) { $0.facts?.rows["H7"] = JourneyFixtures.row("H7", .manual("No certificate", how: "Check G7")); $0.facts?.rows["G7"] = JourneyFixtures.row("G7", .fixable("Set the guest name")) }
        add("certificate-waiting", .certificate) {
            $0.facts?.rows["H7"] = JourneyFixtures.row("H7", .fixable("Not trusted"))
            $0.inFlight = .init(work: .trustCertificate, started: testMoment(), vm: "winlab02")
        }
        add("saved-no-user", .savedPC) { $0.facts?.rdpUser = nil; $0.facts?.rows["C2"] = JourneyFixtures.row("C2", .fixable("No saved PC")) }
        add("connect-ready", .connect)
        add("connect-failed", .connect) { $0.answers.connected = false; $0.facts?.readiness = .blocked }
        // One card per answer the port can give after No (the fixture's H5 is ok: a VM with no console).
        let console = JourneyFixtures.row("H5", .fixable("Console on"))
        add("connect-failed-answering", .connect) { $0.answers.connected = false; $0.facts?.readiness = .ready }
        add("connect-failed-answering-one-off", .connect) {
            $0.answers.connected = false; $0.facts?.readiness = .ready
            $0.facts?.rows["C2"] = JourneyFixtures.row("C2", .fixable("No saved PC")); $0.facts?.rows["H5"] = console
        }
        add("connect-failed-not-answering", .connect) {
            $0.answers.connected = false; $0.facts?.readiness = .notReady; $0.facts?.rows["H5"] = console
        }
        add("connect-failed-not-answering-headless", .connect) { $0.answers.connected = false; $0.facts?.readiness = .notReady }
        // H5 unread: Connect reached without Finish in this session, e.g. a VM made headless elsewhere.
        add("connect-failed-not-answering-unread", .connect) {
            $0.answers.connected = false; $0.facts?.readiness = .notReady; $0.facts?.rows["H5"] = nil
        }
        add("connect-failed-unchecked", .connect) { $0.answers.connected = false; $0.facts?.readiness = nil; $0.facts?.rows["H5"] = console }
        add("saved-checking", .savedPC) { $0.inFlight = .init(work: .checkAgain(.savedPC), started: testMoment(), vm: "winlab02") }
        add("saved-saving", .savedPC) {
            $0.facts?.rows["C2"] = JourneyFixtures.row("C2", .fixable("No saved PC"))
            $0.inFlight = .init(work: .savePC, started: testMoment(), vm: "winlab02")
        }
        add("saved-done", .savedPC)
        // Not offered because the desktop question was answered No: the state the real flow reaches.
        // With the answer left unset it drew a Finish page no one can get to.
        add("finish-not-offered", .finish) {
            $0.answers.connectionOpened = true; $0.answers.connected = false
            $0.facts?.rows["H5"] = JourneyFixtures.row("H5", .fixable("Console on"))
        }
        add("finish-others", .finish) {
            $0.answers.connected = true; $0.facts?.rows["H5"] = JourneyFixtures.row("H5", .fixable("Console on"))
            $0.facts?.otherVMs = .running(["atelier"])
        }
        add("finish-staged", .finish) {
            $0.answers.connected = true; $0.facts?.rows["H5"] = JourneyFixtures.row("H5", .fixable("Console on"))
            $0.facts?.pending = ConfigChanges(cpuCores: 6, display: .headless)
        }
        add("finish-done-no-connection", .finish) { $0.finished = true }
        add("finish-done-app-now-installed", .finish) { $0.finished = true; $0.answers.leftAlone.insert("C1") }
        add("tune-mixed", .tune) {
            $0.facts?.rows["H6"] = JourneyFixtures.row("H6", .manual("Time Machine", how: "Only if Terminal has Full Disk Access"))
            $0.facts?.rows["G9"] = JourneyFixtures.row("G9", .fixable("BitLocker kept on (--keep-bitlocker)"))
            $0.facts?.keepBitLocker = true
            $0.facts?.declined.tuning = true
            $0.facts?.rows["G1"] = JourneyFixtures.row("G1", .fixable("Power plan"))
        }
        return screens
    }
}

@MainActor @Suite("The wizard's recovery paths, drawn")
struct SetupRecoverySnapshots {
    /// The card the window draws after No follows H5 through the diagnosis: three readings, three
    /// cards, and an info reading draws exactly what no reading does. A view that worked out the
    /// VM's screen its own way — `headless: facts.kind("H5") == .ok` did, and read unread as a
    /// console — fails here, because two of the three would draw alike.
    @Test("The drawn recovery card follows H5's three states, and info draws as unread")
    func recoveryCardFollowsH5() throws {
        func render(_ h5: Status?) throws -> Data {
            var state = SetupFixtures.state(.connect, facts: JourneyFixtures.facts)
            state.answers.connected = false
            state.facts?.readiness = .notReady
            state.facts?.rows["H5"] = h5.map { JourneyFixtures.row("H5", $0) }
            state.facts?.answers = state.answers
            return try #require(Snapshot.png(SetupScreen(state: state, art: nil, send: { _ in }),
                                             size: CGSize(width: 600, height: 1100), appearance: .light))
        }
        let headless = try render(.ok("headless"))
        let onScreen = try render(.fixable("console window on"))
        let unread = try render(nil)
        let info = try render(.info("unknown"))
        for (a, b, pair) in [(headless, onScreen, "headless/console"), (headless, unread, "headless/unread"),
                             (onScreen, unread, "console/unread")] {
            #expect((Snapshot.difference(a, b)?.count ?? 1) > 0, "\(pair) drew the same card")
        }
        #expect(Snapshot.difference(unread, info)?.count == 0)
    }

    @Test("VM choices and recovery screens are stable in every supported appearance")
    func recoveryPages() throws {
        for (name, state) in SetupRecoveryFixtures.screens {
            for appearance in Snapshot.Appearance.allCases {
                let view = SetupScreen(state: state, art: nil, send: { _ in })
                let png = try #require(Snapshot.png(view, size: CGSize(width: 600, height: 620), appearance: appearance))
                let again = try #require(Snapshot.png(view, size: CGSize(width: 600, height: 620), appearance: appearance))
                #expect(Snapshot.difference(png, again)?.count == 0, "\(name): unstable rendering")
                try Snapshot.record(png, as: "recovery-\(name)-\(appearance.rawValue)")
                if name == "tune-mixed" {
                    // The normal window scrolls. Also draw the whole list so the lower manual
                    // and encryption rows are part of the visual check, not hidden below the fold.
                    let full = try #require(Snapshot.png(view, size: CGSize(width: 600, height: 2500),
                                                        scale: 1, appearance: appearance))
                    try Snapshot.record(full, as: "recovery-tune-full-\(appearance.rawValue)")
                }
            }
        }
    }
}
