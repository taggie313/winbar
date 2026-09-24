import AppKit
import SwiftUI
import Testing
@testable import Winbar

/// **Help!** sits at the trailing end of the title bar, and the small Armie beside a page's title in
/// the column at the trailing edge of the page: the same side of the window, so this holds the two
/// apart in the window people get (`SetupWindowController.shape`), which is laid out but never put on
/// screen. The working loop stands in for every pose there, since a still is no AppKit view to
/// measure and `SetupPageHead` places every pose in the same square.
@MainActor @Suite("Help! in the title bar and Armie beside a page's title")
struct HelpButtonArmieTests {
    /// His rest still and the real working loop, from Resources.
    private static let movies: ArmieArt? = {
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/Armie")
        return NSImage(contentsOf: resources.appendingPathComponent(ArmieArt.stillName + ".png")).map {
            ArmieArt(still: $0, working: resources.appendingPathComponent("armie-working.mov"), done: nil)
        }
    }()

    private func loops(in view: NSView) -> [ArmieLoop.LoopView] {
        if let loop = view as? ArmieLoop.LoopView { return [loop] }
        return view.subviews.flatMap { loops(in: $0) }
    }

    @Test("He stands below the title bar, clear of Help!")
    func apart() throws {
        let art = try #require(Self.movies)
        var reading = ArmieFixtures.tuneNeedsFix
        reading.inFlight = SetupFixtures.flight(.checkAgain(.tune))
        for (name, state) in [("UTM installing", SetupFixtures.installing), ("starting", ArmieFixtures.starting),
                              ("tune, reading", reading)] {
            let content = NSHostingController(rootView: SetupScreen(state: state, art: art, send: { _ in }))
            content.sizingOptions = []
            let window = NSWindow(contentViewController: content)
            window.isReleasedWhenClosed = false
            SetupWindowController.shape(window)
            let accessory = try #require(BetaReport.titlebarHelp(enabled: true, press: {}))
            window.addTitlebarAccessoryViewController(accessory)
            window.layoutIfNeeded()
            content.view.layoutSubtreeIfNeeded()
            let help = try #require(BetaReport.helpButton(in: accessory))
            let figure = try #require(loops(in: content.view).first, "\(name)")
            defer { loops(in: content.view).forEach { $0.stop() } }
            let helpFrame = help.convert(help.bounds, to: nil)
            let figureFrame = figure.convert(figure.bounds, to: nil)
            #expect(figureFrame.height > 0, "\(name)")
            #expect(!figureFrame.intersects(helpFrame), "\(name): Armie \(figureFrame) meets Help! \(helpFrame)")
            // Under the title bar altogether, not only beside the button: the window's y runs up.
            #expect(figureFrame.maxY <= window.contentLayoutRect.maxY, "\(name): \(figureFrame) reaches the title bar")
        }
    }
}
