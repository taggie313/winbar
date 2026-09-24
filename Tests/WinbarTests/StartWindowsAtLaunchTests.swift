import AppKit
import SwiftUI
import Testing
@testable import Winbar

// Also start Windows when Winbar opens: the finished screen's second switch and the menu's Start
// Windows with Winbar. Off unless the person turns it on, and when on, Winbar starts the chosen VM as it
// opens only while nothing else has it. The setting lives in a test's own store here; nothing reads or
// writes the Mac's settings, makes an AppDelegate, or starts a VM.

@Suite("Start Windows with Winbar")
struct StartWindowsAtLaunchTests {
    private typealias Launch = StartWindowsAtLaunch.Launch

    /// Everything that lets it start: on, a VM chosen and stopped, nothing else at work.
    private let clear = Launch(on: true, vm: "winlab01", running: false, installing: false, workHeld: false,
                               setupBusy: false)

    /// Each condition on its own stops it. The control is per line: take that condition's clause out of
    /// `starts` and its line fails (run for `running` and `workHeld`).
    @Test("Starts only when on, with a VM chosen that isn't running, and nothing else at work")
    func decision() {
        #expect(StartWindowsAtLaunch.starts(clear))
        let each: [(String, (inout Launch) -> Void)] = [
            ("switched off", { $0.on = false }),
            ("no VM chosen", { $0.vm = nil }),
            ("already running", { $0.running = true }),
            ("an install hasn't finished", { $0.installing = true }),
            ("other work holds the gate", { $0.workHeld = true }),
            ("Set Up Winbar has the VM", { $0.setupBusy = true }),
        ]
        for (why, change) in each {
            var launch = clear
            change(&launch)
            #expect(!StartWindowsAtLaunch.starts(launch), "\(why)")
        }
    }

    /// Never on by default: a Mac that has never been asked starts nothing. On is a yes, and off is no
    /// value at all, like the other yes-only settings. Control: default the read to true.
    @Test("Off until someone turns it on, and off leaves no value behind")
    func setting() {
        let store = MemoryStore()
        #expect(!StartWindowsAtLaunch.isOn(in: store))
        StartWindowsAtLaunch.set(true, in: store)
        #expect(StartWindowsAtLaunch.isOn(in: store))
        #expect(store.object(forKey: Config.Key.startWindowsAtLaunch) as? Bool == true)
        StartWindowsAtLaunch.set(false, in: store)
        #expect(!StartWindowsAtLaunch.isOn(in: store))
        #expect(store.object(forKey: Config.Key.startWindowsAtLaunch) == nil)
    }

    /// Outside Winbar.app the live setting reads off, so drawing the finished screen or the menu in a
    /// test never shows it on, and a test can never leave this Mac starting a VM at login. Only read
    /// here: writing through `live` is what must never reach the Mac's settings.
    @Test("Under test, the live setting is inert and reads off")
    @MainActor func inertUnderTest() {
        #expect(!AppPresence.isTheApp)
        #expect(!StartWindowsAtLaunch.live.isOn())
    }

    @Test("A setting of this copy of Winbar, not a VM's, and a report shows it")
    func belongsToWinbar() {
        let key = Config.Key.startWindowsAtLaunch
        #expect(Config.Key.all.contains(key))
        #expect(!Config.Key.perVM.contains(key))
        #expect(Diagnose.winbarKeys([key, "NSGlobalDomainThing"]) == [key])
    }

    /// The finished screen's line and the menu's hover say which VM, when it starts, and what it costs;
    /// Launch at Login's own words no longer say Windows stays off whatever happens. Neither says "in
    /// the background", which in Winbar means headless: this is the menu's Start, and a VM that kept
    /// its screen opens UTM's window. (Changed on purpose: this expected "in the background"; that
    /// wording is the control.)
    @Test("The switch and the menu item name the VM, when it starts, and what it costs")
    func copy() {
        let detail = StartWindowsAtLaunch.Copy.detail(vm: "winlab01")
        #expect(detail.contains("Starts “winlab01” each time Winbar opens, without connecting to it"))
        for words in [detail, StartWindowsAtLaunch.Copy.menuHelp(vm: "winlab01")] {
            #expect(!words.contains("background") && words.contains("without connecting"), "\(words)")
        }
        #expect(detail.contains("with the switch above on, that's when you log in"))
        #expect(detail.contains("holds its share of your Mac's memory until you shut it down"))
        let help = StartWindowsAtLaunch.Copy.menuHelp(vm: "winlab01")
        #expect(help.contains("“winlab01”") && help.contains("Launch at Login") && help.contains("memory"))
        #expect(StartWindowsAtLaunch.Copy.menuHelp(vm: nil).hasPrefix("Starts the chosen VM"))
        #expect(StartWindowsAtLaunch.Copy.toggleHelp.contains(StartWindowsAtLaunch.Copy.menuItem))
        #expect(LaunchAtLogin.Copy.toggleDetail.contains("Unless the switch below is on"))
        #expect(LaunchAtLogin.Copy.menuHelp.contains("Unless \(StartWindowsAtLaunch.Copy.menuItem) is ticked"))
    }

    @Test("The work gate counts every holder but a report")
    func gate() throws {
        let gate = AppWorkGate()
        #expect(!gate.isHeld)
        let report = try gate.begin(.report, label: "writing a report", vm: nil).get()
        #expect(!gate.isHeld)
        let menu = try gate.begin(.menu, label: "starting", vm: "winlab01").get()
        #expect(gate.isHeld)
        menu.finish()
        #expect(!gate.isHeld)
        report.finish()
        let setup = try gate.begin(.setup, label: "restarting", vm: "winlab01").get()
        #expect(gate.isHeld)
        setup.finish()
        #expect(!gate.isHeld)
    }
}

@MainActor @Suite("Start Windows with Winbar, on the finished screen")
struct StartWindowsToggleTests {
    /// A setting that counts what it was asked.
    final class Recorder {
        var stored = false
        var reads = 0
        var writes: [Bool] = []
        var environment: StartWindowsAtLaunch.Environment {
            StartWindowsAtLaunch.Environment(isOn: { self.reads += 1; return self.stored },
                                             set: { self.writes.append($0); self.stored = $0 })
        }
    }

    private func drawn(_ recorder: Recorder) -> NSWindow {
        let host = NSHostingView(rootView: StartWindowsToggle(vm: "winlab01", environment: recorder.environment))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 480, height: 120), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let deadline = Date().addingTimeInterval(2)
        while recorder.reads == 0, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return window
    }

    /// Unlike Launch at Login, which the finished screen turns on for a fresh setup, this one only
    /// reads as it appears: never turned on without the person. Control: set it on in `onAppear` and
    /// the writes aren't empty.
    @Test("Appearing only reads the setting; it never turns it on")
    func appearingOnlyReads() {
        let recorder = Recorder()
        let window = drawn(recorder)
        #expect(recorder.reads > 0)
        #expect(recorder.writes.isEmpty)
        #expect(!recorder.stored)
        window.close()
    }

    /// Drawn on the finished page: under Open Winbar when I log in, with the line naming the VM.
    /// Control: take `StartWindowsToggle` out of `FinishArrival` and neither is there.
    @Test("Drawn, the finished page has the switch under Open Winbar when I log in, naming the VM")
    func onTheFinishedPage() throws {
        let state = FinishFixtures.ready
        let vm = try #require(state.facts?.chosenVM)
        let png = try #require(Snapshot.png(SetupScreen(state: state, art: nil, send: { _ in }),
                                            size: CGSize(width: 600, height: 1000), appearance: .light))
        let lines = try Drawing.lines(png)
        let login = try #require(Drawing.find(LaunchAtLogin.Copy.toggle, in: lines), "\(lines)")
        let start = try #require(Drawing.find(StartWindowsAtLaunch.Copy.toggle, in: lines), "\(lines)")
        #expect(start.frame.minY > login.frame.minY)
        // The two boxes line up: one column.
        #expect(abs(start.frame.minX - login.frame.minX) < 4, "\(login) \(start)")
        // Vision reads the curly quotes as it likes, so the VM's name and the line's start are found apart.
        let detail = try #require(Drawing.find("each time Winbar opens, without connecting", in: lines), "\(lines)")
        #expect(detail.text.hasPrefix("Starts") && detail.text.contains(vm), "\(detail)")
        #expect(detail.frame.minY > start.frame.minY)
    }
}
