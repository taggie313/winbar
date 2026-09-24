import AppKit
import SwiftUI
import Testing
@testable import Winbar

// The step bar's hover: each segment says its step and how it stands, and a flagged (⚠) one says what
// happened and why, from what Winbar read. The owner found an orange ⚠ on the finished page with no
// useful hover. The words are pure (`SetupCopy.stepBarHelp`, `SetupCopy.passedOver`), and the drawn bar
// carries them as AppKit tooltips (`HoverText`), read back here off an offscreen window. Whether macOS
// then shows one under the pointer is AppKit's, and is only seen live. Invented fixtures throughout.

/// The tooltips a drawn view carries, left to right, with where each sits.
@MainActor func drawnTooltips(_ view: some View, size: CGSize) -> [(text: String, frame: CGRect)] {
    let host = NSHostingView(rootView: view)
    host.frame = CGRect(origin: .zero, size: size)
    let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    var found: [(text: String, frame: CGRect)] = []
    func walk(_ view: NSView) {
        if let tip = view as? HoverText.TipView { found.append((tip.toolTip ?? "", tip.convert(tip.bounds, to: host))) }
        view.subviews.forEach(walk)
    }
    walk(host)
    window.contentView = nil
    return found.sorted { $0.frame.minX < $1.frame.minX }
}

@MainActor @Suite("The step bar's hover says each step and how it stands")
struct SetupStepBarHoverTests {
    /// Finished, with the certificate skipped (nothing approved), the saved PC skipped because Windows
    /// App's command line never answered, and the desktop confirmed.
    private var finished: SetupWindowState {
        var state = SetupFixtures.state(.finish, facts: JourneyFixtures.facts)
        state.finished = true
        state.answers.connected = true
        state.answers.connectionOpened = true
        state.answers.leftAlone = ["H7", "C2", "H5"]
        state.facts?.rows["H7"] = JourneyFixtures.row("H7", .fixable("Not trusted"))
        state.facts?.rows["C2"] = JourneyFixtures.row("C2", SilentFixtures.status)
        state.facts?.answers = state.answers
        return state
    }

    @Test("Each segment says its step and how it stands")
    func words() {
        let hovers = StepBar.hovers(current: .savedPC)
        #expect(hovers.count == 8)
        #expect(hovers[3] == "Tune: done")
        #expect(hovers[5] == "The saved PC: you're here")
        #expect(hovers[7] == "Finish: still to come")
    }

    /// The brief's own examples, from what Winbar read.
    @Test("A flagged segment says what happened and why")
    func flagged() throws {
        let state = finished
        let reasons = StepBar.passedOver(state)
        #expect(Set(reasons.keys) == StepBar.flagged(state))
        let hovers = StepBar.hovers(current: .finish, finished: true, flagged: StepBar.flagged(state), passedOver: reasons)
        #expect(hovers[4] == "The certificate: skipped — not approved, so Windows App may warn about it when you connect")
        #expect(hovers[5] == "The saved PC: skipped — Windows App's command line didn't respond, so Winbar couldn't save it")
        #expect(hovers[6] == "Connect: done")

        var facts = try #require(state.facts)
        facts.answers.connected = false
        #expect(SetupCopy.passedOver(.connect, facts) == "you said the Windows desktop didn't appear")
        facts.answers.connected = nil
        #expect(SetupCopy.passedOver(.connect, facts) == "the desktop wasn't confirmed")
        facts.windowsApp = .missing
        facts.answers.leftAlone = ["C1"]
        #expect(SetupCopy.passedOver(.connect, facts) == "not tried — Windows App was skipped")
        #expect(SetupCopy.passedOver(.savedPC, facts) == "skipped — Windows App isn't installed")
        // Saved or trusted since: nothing passed over to explain.
        facts = try #require(JourneyFixtures.page(.finish).facts)
        #expect(SetupCopy.passedOver(.savedPC, facts) == nil && SetupCopy.passedOver(.certificate, facts) == nil)
        #expect(SetupCopy.passedOver(.tune, facts) == nil)
    }

    @Test("Other reasons for skipping the saved PC or the certificate are said too")
    func otherReasons() throws {
        var facts = try #require(finished.facts)
        facts.rows["C2"] = JourneyFixtures.row("C2", .fixable("none for winlab02.local"))
        #expect(SetupCopy.passedOver(.savedPC, facts) == "skipped — not saved, so Windows App asks for your password when you connect")
        facts.rows["C2"] = JourneyFixtures.row("C2", .manual("none for winlab02.local, and Windows App is open", how: "Quit it"))
        #expect(SetupCopy.passedOver(.savedPC, facts) == "skipped — Winbar couldn't save it")
        facts.rows["H7"] = JourneyFixtures.row("H7", .info("Windows didn't report its certificate"))
        facts.rows["G7"] = JourneyFixtures.row("G7", .fixable("No certificate for winlab02.local"))
        #expect(SetupCopy.passedOver(.certificate, facts) == "skipped — Windows had no certificate for its name yet")
    }

    /// Control: put `.help(hovers[index])` back in place of the overlay and no tooltip is found.
    @Test("Drawn, each segment carries its words as a tooltip, in order and under its own segment")
    func drawn() {
        let state = finished
        let header = SetupHeader(state: state)
        let tips = drawnTooltips(header, size: CGSize(width: SetupStyle.contentWidth, height: 20))
        let expected = StepBar.hovers(current: .finish, finished: true, flagged: StepBar.flagged(state),
                                      passedOver: StepBar.passedOver(state))
        #expect(tips.map(\.text) == expected, "\(tips.map(\.text))")
        #expect(tips.allSatisfy { $0.frame.width > 20 }, "\(tips.map(\.frame))")
        for (left, right) in zip(tips, tips.dropFirst()) {
            #expect(left.frame.maxX <= right.frame.minX + 0.5, "\(left.frame) overlaps \(right.frame)")
        }
    }

    /// The tooltips are the pointer's; VoiceOver still hears the bar as one element with the steps
    /// passed over as its value (`SetupAccessibilityTests.stepBar`), and nothing from the tooltips.
    @Test("The tooltip views are never accessibility elements")
    func notForVoiceOver() {
        #expect(!HoverText.TipView().isAccessibilityElement())
    }
}
