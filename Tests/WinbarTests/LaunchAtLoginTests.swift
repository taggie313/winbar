import AppKit
import Foundation
import ServiceManagement
import SwiftUI
import Testing
@testable import Winbar

// Launch at Login, offered on Set Up Winbar's finished screen and switched on for a fresh setup. The
// login-items service is a fake here: nothing is registered, and the settings are never touched.

/// Records what it was asked, and answers with whatever status the test gives it.
private final class FakeLoginItems: LaunchAtLogin.Service {
    var status: SMAppService.Status
    var afterRegister: SMAppService.Status = .enabled
    var calls: [String] = []
    var failure: Error?

    init(_ status: SMAppService.Status) { self.status = status }

    func register() throws {
        calls.append("register")
        if let failure { throw failure }
        status = afterRegister
    }

    func unregister() throws {
        calls.append("unregister")
        if let failure { throw failure }
        status = .notRegistered
    }
}

private struct Refused: Error, LocalizedError { var errorDescription: String? { "Operation not permitted" } }

@Suite("Launch at Login")
struct LaunchAtLoginTests {
    /// A fresh setup ends with it on; anyone who already chose, either way, keeps their choice; a copy
    /// that goes away never gets it.
    @Test("On by default only for a fresh setup from a copy that stays")
    func defaultOn() {
        #expect(LaunchAtLogin.turnsOnByDefault(status: .notRegistered, decided: false, place: .applications))
        #expect(LaunchAtLogin.turnsOnByDefault(status: .notRegistered, decided: false, place: .elsewhere))
        #expect(!LaunchAtLogin.turnsOnByDefault(status: .notRegistered, decided: true, place: .applications))
        #expect(!LaunchAtLogin.turnsOnByDefault(status: .enabled, decided: false, place: .applications))
        #expect(!LaunchAtLogin.turnsOnByDefault(status: .requiresApproval, decided: false, place: .applications))
        for place in [AppLocation.Place.mountedVolume, .translocated, .downloads] {
            #expect(!LaunchAtLogin.turnsOnByDefault(status: .notRegistered, decided: false, place: place), "\(place)")
        }
    }

    /// What the finished screen does as it appears: registers for a fresh setup and records that as
    /// the decision; for anyone who already chose, anyone it is on for already, and a copy that goes
    /// away, it only reads.
    @Test("The finished screen registers a fresh setup, and only reads for everyone else")
    func initialOutcome() {
        let fresh = FakeLoginItems(.notRegistered)
        var decided = false
        let environment = LaunchAtLogin.Environment(service: fresh, place: .applications,
                                                    decided: { decided }, markDecided: { decided = true })
        #expect(LaunchAtLogin.initialOutcome(environment) == .on)
        #expect(fresh.calls == ["register"])
        #expect(decided)
        // Appearing again registers nothing more.
        #expect(LaunchAtLogin.initialOutcome(environment) == .on)
        #expect(fresh.calls == ["register"])

        let approval = FakeLoginItems(.notRegistered)
        approval.afterRegister = .requiresApproval
        #expect(LaunchAtLogin.initialOutcome(.init(service: approval, place: .applications, decided: { false },
                                                   markDecided: {})) == .needsApproval)

        let cases: [(SMAppService.Status, Bool, AppLocation.Place, LaunchAtLogin.Outcome)] = [
            (.notRegistered, true, .applications, .off),      // switched off in the menu before
            (.enabled, false, .applications, .on),            // already on
            (.requiresApproval, false, .applications, .needsApproval),
            (.notRegistered, false, .mountedVolume, .off),    // the disk image: never registered
            (.notRegistered, false, .translocated, .off),
            (.notRegistered, false, .downloads, .off),
        ]
        for (status, wasDecided, place, expected) in cases {
            let items = FakeLoginItems(status)
            var marked = false
            let outcome = LaunchAtLogin.initialOutcome(.init(service: items, place: place, decided: { wasDecided },
                                                             markDecided: { marked = true }))
            #expect(outcome == expected, "\(status) \(wasDecided) \(place)")
            #expect(items.calls.isEmpty, "\(status) \(wasDecided) \(place)")
            #expect(!marked, "\(status) \(wasDecided) \(place)")
        }
    }

    /// The toggle itself, drawn in a window with a fake service: appearing is what registers it, and
    /// the switch then reads on.
    @Test("The finished screen's toggle registers a fresh setup when it appears")
    @MainActor func toggleAppears() {
        let items = FakeLoginItems(.notRegistered)
        var decided = false
        let environment = LaunchAtLogin.Environment(service: items, place: .applications,
                                                    decided: { decided }, markDecided: { decided = true })
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 320, height: 80), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: LaunchAtLoginToggle(environment: environment))
        window.contentView?.layoutSubtreeIfNeeded()
        let deadline = Date().addingTimeInterval(2)
        while items.calls.isEmpty, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        #expect(items.calls == ["register"])
        #expect(decided)
        window.close()
    }

    @Test("Turning it on registers, and says when macOS wants it allowed")
    func turnOn() {
        let items = FakeLoginItems(.notRegistered)
        #expect(LaunchAtLogin.set(true, service: items, place: .applications) == .on)
        #expect(items.calls == ["register"])

        let approval = FakeLoginItems(.notRegistered)
        approval.afterRegister = .requiresApproval
        #expect(LaunchAtLogin.set(true, service: approval, place: .applications) == .needsApproval)
        #expect(LaunchAtLogin.Copy.approval.contains("Login Items"))
        #expect(LaunchAtLogin.Copy.approval.contains("turn on Winbar"))
    }

    @Test("Turning it off unregisters")
    func turnOff() {
        let items = FakeLoginItems(.enabled)
        #expect(LaunchAtLogin.set(false, service: items, place: .applications) == .off)
        #expect(items.calls == ["unregister"])
    }

    /// The login item must never point at a disk image, a translocated mirror or Downloads.
    @Test("From a copy that goes away nothing is registered, and the reason is given")
    func refusedFromATemporaryCopy() {
        for place in [AppLocation.Place.mountedVolume, .translocated, .downloads] {
            let items = FakeLoginItems(.notRegistered)
            guard case .refused(let why) = LaunchAtLogin.set(true, service: items, place: place) else {
                Issue.record("\(place) wasn't refused")
                continue
            }
            #expect(items.calls.isEmpty, "\(place)")
            #expect(why.contains("Move Winbar to Applications"))
        }
        // Turning it off is always allowed: that only ever makes things safer.
        let items = FakeLoginItems(.enabled)
        #expect(LaunchAtLogin.set(false, service: items, place: .mountedVolume) == .off)
    }

    @Test("A refusal from the service is reported, not swallowed")
    func failure() {
        let items = FakeLoginItems(.notRegistered)
        items.failure = Refused()
        #expect(LaunchAtLogin.set(true, service: items, place: .applications) == .failed("Operation not permitted"))
    }

    /// Outside Winbar.app the live environment registers nothing and writes no setting: drawing the
    /// finished screen in a test would otherwise make the test runner a login item.
    @Test("Under test, the live environment is inert and counts as decided")
    @MainActor func inertUnderTest() throws {
        let live = LaunchAtLogin.live
        #expect(live.decided())
        #expect(live.service.status == .notRegistered)
        #expect(live.place == .elsewhere)
    }

    /// The finished view gains exactly one line for this, so the polish effort's restyling can move it
    /// freely; the switch itself lives in LaunchAtLogin.swift.
    @Test("The finished screen shows the toggle, and the README mentions it")
    func shown() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        // The polish moved the finished screen into its own file (FinishArrival).
        let view = try String(contentsOf: root.appendingPathComponent("Sources/Winbar/SetupFinishPage.swift"), encoding: .utf8)
        #expect(view.components(separatedBy: "LaunchAtLoginToggle()").count == 2)
        let readme = try String(contentsOf: root.appendingPathComponent("README.md"), encoding: .utf8)
        #expect(readme.contains(LaunchAtLogin.Copy.toggle))
        #expect(LaunchAtLogin.Copy.toggle == "Open Winbar when I log in")
    }

    // MARK: What it opens

    /// Live, the owner read "Open Winbar when I log in" and couldn't tell whether Windows would start
    /// at every login or only the icon. The switch now says under it, in view, that it is only the
    /// icon, and the menu's Launch at Login says the same on hover, so the one switch is never
    /// described two ways. Control: take "Windows stays off" out of either line and this fails.
    @Test("The finished screen's switch and the menu's Launch at Login both say only the icon opens")
    func saysOnlyTheIconOpens() {
        #expect(LaunchAtLogin.Copy.toggleDetail.contains("only Winbar's icon in the menu bar"))
        for words in [LaunchAtLogin.Copy.toggleDetail, LaunchAtLogin.Copy.menuHelp] {
            #expect(words.contains("Winbar's icon in the menu bar"), "\(words)")
            #expect(words.contains("Windows stays off until you connect to it or start it"), "\(words)")
        }
        // Said in the menu's own tooltip, not only in a constant nobody draws.
        let launch = MenuShape.items(MenuState(status: MenuStatus(vmName: "winlab01"))).compactMap { spec -> MenuItem? in
            if case .item(let item) = spec, item.action == .launchAtLogin { return item }
            return nil
        }
        #expect(launch.map(\.toolTip) == [LaunchAtLogin.Copy.menuHelp])
    }

    /// Drawn with a fake service, the words sit under the switch's title, where someone deciding
    /// reads them. Control: remove `SwitchDetail` from `LaunchAtLoginToggle` and the line isn't there.
    @Test("Drawn, the switch says under its title that only the icon opens")
    @MainActor func drawnDetail() throws {
        let environment = LaunchAtLogin.Environment(service: FakeLoginItems(.enabled), place: .applications,
                                                    decided: { true }, markDecided: {})
        let png = try #require(Snapshot.png(LaunchAtLoginToggle(environment: environment),
                                            size: CGSize(width: 480, height: 110), appearance: .light))
        let lines = try Drawing.lines(png)
        let title = try #require(Drawing.find(LaunchAtLogin.Copy.toggle, in: lines), "\(lines)")
        let detail = try #require(Drawing.find("Opens only Winbar's icon", in: lines), "\(lines)")
        #expect(detail.frame.minY > title.frame.minY)
        #expect(Drawing.find("Windows stays off", in: lines) != nil, "\(lines)")
    }

    /// The README says what the switch says, word for word, wrapped as Markdown wraps it.
    @Test("The README quotes what the switch says it opens")
    func readmeQuotesTheDetail() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let readme = try String(contentsOf: root.appendingPathComponent("README.md"), encoding: .utf8)
        let flat = readme.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(flat.contains(LaunchAtLogin.Copy.toggleDetail))
    }

    @Test("Both settings belong to this copy of Winbar, not a VM, and a report shows them")
    func settings() {
        for key in [Config.Key.launchAtLoginDecided, Config.Key.declinedMoveToApplications] {
            #expect(Config.Key.all.contains(key))
            #expect(!Config.Key.perVM.contains(key))
            #expect(Diagnose.winbarKeys([key]) == [key])
        }
    }
}
