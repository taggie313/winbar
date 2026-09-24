import AppKit
import Foundation
import Testing
@testable import Winbar

// The focus log (`FocusLog`): what came to the front while Winbar was open, kept in memory by the app
// and read into the diagnostic report as its last section. Driven here with notification centres of
// the tests' own, a made-up clock and a made-up state, so nothing reads this Mac's windows, activates
// anything or listens to the real workspace. The fixtures are invented (winlab01, rosa, atelier).

/// An app coming to the front, as macOS hands it over: a bundle identifier, and a name and a place
/// on disk that must never be kept.
private final class MadeUpApp: NSRunningApplication, @unchecked Sendable {
    override var bundleIdentifier: String? { "com.example.browser" }
    override var localizedName: String? { "Rosa's Private Browser" }
    override var bundleURL: URL? { URL(fileURLWithPath: "/Users/rosa/Applications/Rosa's Private Browser.app") }
}

private final class Clock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
}

/// What Winbar is doing, for a test to change as it goes.
private final class Doing {
    var state: FocusLog.State
    init(_ state: FocusLog.State) { self.state = state }
}

/// Winbar installing UTM behind another app, its window on another Space.
private let installing = FocusLog.State(policy: .regular, active: false, hidden: false, setupStep: .lookAround,
                                        work: "installUTM",
                                        window: .init(visible: true, key: false, onActiveSpace: false))

/// Set Up Winbar open on Look around, nothing in flight yet: just before the install.
private let looking = FocusLog.State(policy: .regular, active: true, hidden: false, setupStep: .lookAround,
                                     work: nil, window: .init(visible: true, key: true, onActiveSpace: true))

/// Later in set-up, starting the VM, with the window closed: the work goes on all the same.
private let startingTheVM = FocusLog.State(policy: .accessory, active: false, hidden: false, setupStep: nil,
                                           work: "startVM", window: nil)

/// In the menu bar, Set Up Winbar closed and nothing in flight: ordinary switching.
private let idle = FocusLog.State(policy: .accessory, active: false, hidden: false, setupStep: nil, work: nil,
                                  window: nil)

/// One bounce of the reported pattern: away to the browser on another Space, and back.
private let bounce: [FocusLog.Event] = [
    .winbarResignedActive, .appCameForward(bundleID: "com.example.browser"), .spaceChanged,
    .spaceChanged, .appCameForward(bundleID: "net.elusive.winbar"), .winbarBecameActive,
]

private let opened = Date(timeIntervalSince1970: 1_800_000_000)

@MainActor @Suite("The focus log keeps what came to the front, in the app only, and the report ends with it")
struct FocusLogTests {
    @Test("The ring keeps the newest, oldest first")
    func ringKeepsTheNewest() {
        var ring = FocusLog.Ring<Int>(capacity: 3)
        ring.append(1)
        ring.append(2)
        #expect(ring.items == [1, 2])
        for n in 3...7 { ring.append(n) }
        #expect(ring.items == [5, 6, 7])
    }

    @Test("Ordinary switching keeps the last fifty, most recent last, numbered from the first")
    func logHoldsTheLastFifty() {
        let clock = Clock()
        let log = FocusLog(clock: { clock.now }, state: { idle })
        log.start(isTheApp: true, app: NotificationCenter(), workspace: NotificationCenter())
        for n in 1...60 {
            clock.now += 1
            log.note(.appCameForward(bundleID: "com.example.app\(n)"))
        }
        let history = log.history()
        #expect(history.opened == opened)
        #expect(history.entries.map(\.number) == Array((60 - FocusLog.capacity + 1)...60))
        #expect(history.entries.first?.event == .appCameForward(bundleID: "com.example.app11"))
        #expect(history.entries.last?.event == .appCameForward(bundleID: "com.example.app60"))
        #expect(history.entries.last?.at == opened + 60)
        #expect(history.entries.allSatisfy { $0.state == idle })
    }

    /// The friend's case: the window opens, the keyboard jumps away during the install, set-up goes
    /// on long after it — the VM, with switching all the while — and then ordinary Cmd-Tabbing, before
    /// anyone reports it. The first of set-up are still there, then the newest, and nothing twice.
    @Test("Set-up's first entries outlast the switching after them, in set-up or out of it")
    func setUpOutlastsSwitching() throws {
        let clock = Clock(), doing = Doing(looking)
        let log = FocusLog(clock: { clock.now }, state: { doing.state })
        log.start(isTheApp: true, app: NotificationCenter(), workspace: NotificationCenter())
        func note(_ event: FocusLog.Event, _ state: FocusLog.State) {
            clock.now += 1
            doing.state = state
            log.note(event)
        }
        note(.policyChanged(from: .accessory, to: .regular, why: "open: Set Up Winbar", activates: true), looking)
        for event in bounce { note(event, installing) }
        let first = 1 + bounce.count
        // Before anything is let go, each is there once.
        #expect(log.history().entries.map(\.number) == Array(1...first))

        for _ in 1...(2 * FocusLog.setUpCapacity) { note(.spaceChanged, startingTheVM) }
        for n in 1...500 { note(.appCameForward(bundleID: "com.example.app\(n)"), idle) }

        let entries = log.history().entries
        let noted = first + 2 * FocusLog.setUpCapacity + 500
        #expect(entries.map(\.number) == Array(1...FocusLog.setUpCapacity)
                    + Array((noted - FocusLog.capacity + 1)...noted))
        #expect(entries[0].state == looking)
        #expect(Array(entries[1..<first].map(\.event)) == bounce)
        #expect(entries[1..<first].allSatisfy { $0.state == installing })
        #expect(entries[first..<FocusLog.setUpCapacity].allSatisfy { $0.state == startingTheVM })
        #expect(entries.suffix(FocusLog.capacity).allSatisfy { $0.state == idle })
        #expect(entries.last?.event == .appCameForward(bundleID: "com.example.app500"))
    }

    /// Another app by its bundle identifier and nothing else: not its name, not where it is, and not
    /// anything else a notification might carry.
    @Test("In the app each change is kept as it comes, another app by its bundle identifier alone")
    func keepsBundleIDsOnly() {
        let app = NotificationCenter(), workspace = NotificationCenter()
        let clock = Clock()
        let log = FocusLog(clock: { clock.now }, state: { installing })
        log.start(isTheApp: true, app: app, workspace: workspace)
        app.post(name: NSApplication.didResignActiveNotification, object: nil)
        workspace.post(name: NSWorkspace.didActivateApplicationNotification, object: nil,
                       userInfo: [NSWorkspace.applicationUserInfoKey: MadeUpApp(),
                                  "title": "Rosa's bank statement — atelier"])
        workspace.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        app.post(name: NSApplication.didBecomeActiveNotification, object: nil)

        let history = log.history()
        #expect(history.entries.map(\.event) == [.winbarResignedActive, .appCameForward(bundleID: "com.example.browser"),
                                                 .spaceChanged, .winbarBecameActive])
        let text = FocusLog.lines(history).joined(separator: "\n")
        #expect(text.contains("com.example.browser"))
        for leak in ["Private Browser", "rosa", "Rosa", "bank statement", "atelier"] {
            #expect(!text.contains(leak), "\(leak)")
        }
    }

    /// `swift test` and the CLI are not Winbar.app: nothing is listened to and nothing is kept, even
    /// when told directly — and their reports say it wasn't kept, rather than that nothing happened.
    @Test("Outside Winbar.app nothing is observed or kept, and the report says so")
    func nothingOutsideTheApp() {
        let app = NotificationCenter(), workspace = NotificationCenter()
        var asked = 0
        let log = FocusLog(clock: { opened }, state: { asked += 1; return installing })
        log.start(isTheApp: false, app: app, workspace: workspace)
        app.post(name: NSApplication.didResignActiveNotification, object: nil)
        workspace.post(name: NSWorkspace.didActivateApplicationNotification, object: nil,
                       userInfo: [NSWorkspace.applicationUserInfoKey: MadeUpApp()])
        workspace.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        log.note(.policyChanged(from: .accessory, to: .regular, why: "open: Set Up Winbar", activates: true))
        #expect(log.history() == FocusLog.History())
        #expect(asked == 0)

        // The app's own log, in this process, which is not Winbar.app.
        #expect(!AppPresence.isTheApp)
        #expect(FocusLog.shared.history().opened == nil)
        #expect(FocusLog.lines(FocusLog.shared.history()) == Diagnose.wrap(FocusLog.Copy.notKept, at: 100))
    }

    @Test("Set-up work is named by its kind, without the VM it was given")
    func workIsNamedByItsKind() {
        #expect(FocusLog.label(.installUTM) == "installUTM")
        #expect(FocusLog.label(.chooseVM("winlab01", id: "9F3C2A10-0000-4000-8000-00000000BEEF")) == "chooseVM")
        #expect(FocusLog.label(.checkAgain(.lookAround)) == "checkAgain")
    }

    @Test("The section: oldest first, the wall clock and the time since Winbar opened, and what Winbar was doing")
    func sectionLines() throws {
        let moved = FocusLog.Event.policyChanged(
            from: .accessory, to: .regular, why: FocusLog.why(open: ["Set Up Winbar"], closing: nil, alertsUp: 0),
            activates: true)
        let browser = FocusLog.Event.appCameForward(bundleID: "com.example.browser")
        var settled = installing
        settled.active = true
        settled.window?.onActiveSpace = true
        // Three before the first weren't kept, and four between the two.
        let history = FocusLog.History(opened: opened,
                                       entries: [.init(number: 4, at: opened + 12.3, event: moved, state: settled),
                                                 .init(number: 9, at: opened + 75.5, event: browser, state: installing)])
        let lines = FocusLog.lines(history)
        let first = try #require(lines.firstIndex { $0.hasSuffix(FocusLog.describe(moved)) })
        let second = try #require(lines.firstIndex { $0.hasSuffix(FocusLog.describe(browser)) })
        #expect(first < second)
        #expect(lines[first].hasPrefix(FocusLog.clockTime.string(from: opened + 12.3) + "  +12.3s  "))
        #expect(lines[second].hasPrefix(FocusLog.clockTime.string(from: opened + 75.5) + "  +75.5s  "))
        // Under each, what Winbar was doing: the step, the work, and where its window was.
        #expect(lines[first + 1] == "    " + FocusLog.describe(settled))
        #expect(lines[second + 1] == "    " + FocusLog.describe(installing))
        #expect(lines[second + 1].contains("lookAround") && lines[second + 1].contains("installUTM"))
        #expect(FocusLog.describe(settled) != FocusLog.describe(installing))
        // What wasn't kept, said where it is missing.
        #expect(lines[first - 1] == FocusLog.Copy.skipped(3))
        #expect(lines[first + 2] == FocusLog.Copy.skipped(4))
        #expect(second == first + 3)

        // Side by side, nothing between them.
        var together = history
        together.entries[0].number = 8
        let unbroken = FocusLog.lines(together)
        #expect(unbroken.firstIndex { $0.hasSuffix(FocusLog.describe(browser)) }
                    == (unbroken.firstIndex { $0.hasSuffix(FocusLog.describe(moved)) } ?? -9) + 2)

        // Kept, with nothing in it yet.
        #expect(FocusLog.lines(FocusLog.History(opened: opened))
                    == [FocusLog.Copy.noneSince(Diagnose.settingDate.string(from: opened))])
    }

    /// The report's last section, and redacted with the rest of the file: a name in it is replaced like
    /// a name anywhere else in an anonymised report, and kept in a verbatim one.
    @Test("The report ends with the section, redacted like everything above it")
    func inTheReport() throws {
        let collected = Diagnose.Collected(
            sections: [Diagnose.Section(heading: Diagnose.headings.crashes, lines: ["No UTM crash reports."])],
            identity: Redactor.Identity(userName: "rosa", computerName: "atelier", vmNames: ["winlab01"]),
            madeAt: opened, includeLogs: true)
        let closing = FocusLog.Event.policyChanged(
            from: .regular, to: .accessory, why: FocusLog.why(open: [], closing: "winlab01 on atelier", alertsUp: 0),
            activates: false)
        let history = FocusLog.History(opened: opened,
                                       entries: [.init(number: 1, at: opened + 5, event: closing, state: installing)])

        let anonymised = Diagnose.compose(collected, mode: .anonymised,
                                          leading: [Diagnose.Section(heading: "A note", lines: ["It jumped away"])],
                                          focus: history)
        let crashes = try #require(anonymised.range(of: "\n" + Diagnose.headings.crashes + "\n"))
        let focus = try #require(anonymised.range(of: "\n" + Diagnose.headings.focus + "\n"))
        #expect(crashes.lowerBound < focus.lowerBound)
        #expect(anonymised[focus.upperBound...].contains("<vm-1> on <mac>"))
        #expect(!anonymised.contains("winlab01"))
        #expect(!anonymised.contains("atelier"))

        let verbatim = Diagnose.compose(collected, mode: .verbatim, focus: history)
        #expect(verbatim.contains("winlab01 on atelier"))
    }
}
