import AppKit
import SwiftUI
import Testing
@testable import Winbar

// While work runs, the footer draws only what can be pressed, and Stop Waiting is in the card that
// says what it waits for, with what stopping does. When idle, a greyed-out button says why beside it.
// The review measured greyed-out footer text at 1.63:1 in light and 2.09:1 in dark, in rows of three
// on the certificate's and the saved PC's waits, and a greyed Continue with no reason beside it.
// Every screen is an invented fixture drawn offscreen; nothing is run.

@MainActor @Suite("Waiting: only what can be pressed, and a reason beside what can't")
struct SetupWaitingFooterTests {
    /// Every busy screen the renders draw, and the VM step's start.
    private var busy: [(String, SetupWindowState)] {
        everyScreen.filter { $0.2 == nil && $0.1.inFlight != nil }.map { ($0.0, $0.1) }
            + [("vm-starting", ArmieFixtures.hidden(ArmieFixtures.starting))]
    }

    @Test("While work runs, no footer button is greyed out")
    func onlyPressable() {
        #expect(busy.count >= 12, "\(busy.map(\.0))")
        for (name, state) in busy {
            let footer = SetupFooter.footer(state)
            let greyed = (footer.leading + footer.trailing).filter { !$0.pressable() }
            #expect(greyed.isEmpty, "\(name): \(greyed.map(\.title))")
        }
    }

    /// The control: the same footer with nothing running has its Back, Check Again and Continue.
    @Test("The certificate's approval: nothing in the footer while it waits, its buttons once it ends")
    func certificateFooter() {
        let approving = CertificateFixtures.state("approving")
        #expect(SetupFooter.footer(approving) == SetupFooter())
        var idle = approving
        idle.inFlight = nil
        let footer = SetupFooter.footer(idle)
        #expect(footer.leading.map(\.title) == [SetupCopy.bBack] && !footer.trailing.isEmpty)
    }

    @Test("An idle footer's greyed-out button says why beside it")
    func reasons() {
        var checked = 0
        for (name, state, embedded) in everyScreen where embedded == nil && state.inFlight == nil {
            let footer = SetupFooter.footer(state)
            for button in footer.leading + footer.trailing where !button.pressable(passwordTyped: false) {
                #expect(button.reason?.isEmpty == false, "\(name): \(button.title) has no reason")
                checked += 1
            }
        }
        #expect(checked >= 3, "\(checked)")
        #expect(SetupCopy.notYetReason(.connect, facts: JourneyFixtures.didItWork.facts) == "Answer Yes or No first")
        #expect(SetupCopy.notYetReason(.connect, facts: nil) == nil)
    }

    /// Drawn: the reason is in the footer band, beside the button it explains, in a grey that reads.
    @Test("Drawn, Use This One's reason sits beside it, readable", arguments: [Snapshot.Appearance.light, .dark])
    func drawnReason(appearance: Snapshot.Appearance) throws {
        let png = try render(try VMStepFixtures.screen("vm-choose"), appearance)
        let lines = try Drawing.lines(png)
        let reason = try #require(Drawing.find(SetupCopy.VM.pickFirst, in: lines), "\(lines)")
        let use = try #require(Drawing.find(SetupCopy.VM.bUseThisOne, in: lines), "\(lines)")
        #expect(reason.frame.minY > setupWindowSize.height - setupFooterBand && abs(reason.frame.midY - use.frame.midY) < 8)
        #expect(reason.frame.maxX < use.frame.minX, "\(reason) \(use)")
        let contrast = try #require(Drawing.inkContrast(png, in: reason.frame.insetBy(dx: -2, dy: -2)))
        #expect(contrast >= 4.5, "\(appearance.rawValue): \(contrast)")
    }

    /// Drawn: the certificate's wait has Stop Waiting in its card, with what stopping does beside it,
    /// and nothing greyed out in the footer. It was a bare button floating under the card, over a
    /// footer of three greyed-out buttons.
    @Test("Drawn, the certificate's Stop Waiting is in its card with what stopping does",
          arguments: [Snapshot.Appearance.light, .dark])
    func stopWaitingInCard(appearance: Snapshot.Appearance) throws {
        let state = CertificateFixtures.state("approving")
        #expect(state.inFlight?.work.canStopWaiting == true)
        let lines = try Drawing.lines(try render(state, appearance))
        let stop = try #require(Drawing.find(SetupCopy.Working.bStopWaiting, in: lines), "\(lines)")
        let consequence = try #require(Drawing.find(SetupCopy.Working.stopApproval, in: lines), "\(lines)")
        #expect(abs(consequence.frame.midY - stop.frame.midY) < 8 && consequence.frame.minX > stop.frame.maxX)
        let approving = try #require(Drawing.find("What am I approving", in: lines), "\(lines)")
        #expect(stop.frame.maxY < approving.frame.minY, "inside the card, above its fold: \(stop) \(approving)")
        for title in [SetupCopy.bBack, SetupCopy.bCheckAgain, SetupCopy.journeyNext(.certificate, facts: state.facts)] {
            #expect(!lines.contains { $0.text == title }, "\(title) drawn while waiting: \(lines)")
        }
    }

    /// The band keeps its height with nothing in it, so the page above doesn't move when a wait starts
    /// and ends: the empty band shrank to a sliver.
    @Test("An empty footer band is as tall as one with buttons")
    func bandHeight() throws {
        func height(_ footer: SetupFooter) -> CGFloat {
            let host = NSHostingView(rootView: SetupFooterBar(footer: footer, credentials: SetupCredentials(),
                                                              savePassword: { _ in }, send: { _ in }))
            return host.fittingSize.height
        }
        let full = height(SetupFooter(leading: [.init(SetupCopy.bBack, .back)], trailing: [.init("Continue", .next, kind: .primary)]))
        #expect(full >= SetupStyle.largeButtonHeight + 28, "\(full)")
        #expect(abs(height(SetupFooter()) - full) < 1, "empty \(height(SetupFooter())), full \(full)")
    }
}
