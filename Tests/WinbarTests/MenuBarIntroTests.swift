import AppKit
import SwiftUI
import Testing
@testable import Winbar

// Introducing Winbar's icon in the menu bar from the finished page: a popover from the icon once per
// Mac and on Show Me, or the words on the page where macOS isn't showing the icon. The screens here are
// invented rectangles; nothing makes a status item, shows a popover, or reads or writes the Mac's
// settings.

@Suite("Introducing the menu bar icon")
struct MenuBarIntroTests {
    private typealias Screen = MenuBarIntro.Screen

    /// A 1728 × 1117 laptop screen with a camera housing between x 771.5 and 956.5, as AppKit reports
    /// one, and the button where a menu bar icon sits right of it.
    private let laptop = Screen(frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
                                topLeft: CGRect(x: 0, y: 1085, width: 771.5, height: 32),
                                topRight: CGRect(x: 956.5, y: 1085, width: 771.5, height: 32))
    private let beside = CGRect(x: 1067, y: 1087, width: 22, height: 27)

    /// Once per Mac as the page appears, and every time on Show Me; a popover only where the icon is
    /// shown. Controls: let `action` ignore `introducedBefore` and the later appearances point again;
    /// let it point whatever the icon, and the hidden ones get a popover at nothing.
    @Test("The first appearance and every Show Me point, or say where to look; later appearances do nothing")
    func action() {
        for icon in [MenuBarIntro.Icon.shown, .behindNotch, .notShown] {
            let expected: MenuBarIntro.Action = icon == .shown ? .point : .say(icon)
            #expect(MenuBarIntro.action(pressed: false, introducedBefore: false, icon: icon) == expected, "\(icon)")
            #expect(MenuBarIntro.action(pressed: false, introducedBefore: true, icon: icon) == .nothing, "\(icon)")
            #expect(MenuBarIntro.action(pressed: true, introducedBefore: true, icon: icon) == expected, "\(icon)")
            #expect(MenuBarIntro.action(pressed: true, introducedBefore: false, icon: icon) == expected, "\(icon)")
        }
    }

    /// Control: drop the housing rule and the icon left of the right-hand part reads as shown.
    @Test("Right of a camera housing the icon is shown; under it, or left of it, macOS is hiding it")
    func notch() {
        #expect(MenuBarIntro.icon(button: beside, windowShown: true, screens: [laptop]) == .shown)
        let under = CGRect(x: 880, y: 1087, width: 22, height: 27)
        #expect(MenuBarIntro.icon(button: under, windowShown: true, screens: [laptop]) == .behindNotch)
        let leftOfIt = CGRect(x: 600, y: 1087, width: 22, height: 27)
        #expect(MenuBarIntro.icon(button: leftOfIt, windowShown: true, screens: [laptop]) == .behindNotch)
        // A screen without a housing has no such rule: anywhere in its menu bar is shown.
        let external = Screen(frame: CGRect(x: 1728, y: 0, width: 2560, height: 1440))
        let far = CGRect(x: 1728 + 900, y: 1410, width: 22, height: 27)
        #expect(MenuBarIntro.icon(button: far, windowShown: true, screens: [laptop, external]) == .shown)
    }

    /// AppKit doesn't say which coordinates the housing's areas are in. A laptop screen that isn't at
    /// the origin, beside a display that is, reads the same either way.
    @Test("A housing is found on a screen away from the origin, whichever coordinates AppKit uses")
    func notchAwayFromTheOrigin() {
        let frame = CGRect(x: -1728, y: -200, width: 1728, height: 1117)
        let local = Screen(frame: frame, topLeft: CGRect(x: 0, y: 1085, width: 771.5, height: 32),
                           topRight: CGRect(x: 956.5, y: 1085, width: 771.5, height: 32))
        let global = Screen(frame: frame, topLeft: CGRect(x: -1728, y: 885, width: 771.5, height: 32),
                            topRight: CGRect(x: -771.5, y: 885, width: 771.5, height: 32))
        for screen in [local, global] {
            #expect(screen.rightOfNotch == CGRect(x: -771.5, y: 885, width: 771.5, height: 32))
            #expect(MenuBarIntro.icon(button: beside.offsetBy(dx: -1728, dy: -200), windowShown: true,
                                      screens: [screen]) == .shown)
            #expect(MenuBarIntro.icon(button: CGRect(x: -1728 + 880, y: 887, width: 22, height: 27), windowShown: true,
                                      screens: [screen]) == .behindNotch)
        }
    }

    /// Control: stop reading `windowShown` and a window macOS isn't showing reads as shown.
    @Test("No window, a window macOS isn't showing, or one off every screen is not shown")
    func notShown() {
        #expect(MenuBarIntro.icon(button: nil, windowShown: true, screens: [laptop]) == .notShown)
        #expect(MenuBarIntro.icon(button: beside, windowShown: false, screens: [laptop]) == .notShown)
        #expect(MenuBarIntro.icon(button: CGRect(x: 1067, y: 1087, width: 0, height: 0), windowShown: true,
                                  screens: [laptop]) == .notShown)
        // Above the top of the screen, where a hidden menu bar keeps it.
        #expect(MenuBarIntro.icon(button: beside.offsetBy(dx: 0, dy: 40), windowShown: true, screens: [laptop]) == .notShown)
        #expect(MenuBarIntro.icon(button: beside, windowShown: true, screens: []) == .notShown)
    }

    /// The popover says the icon is where Winbar lives and what its menu does; the words on the page
    /// say where to look, for each reason, and the same about the menu.
    @Test("The popover and the page's words say where Winbar lives and what its menu does")
    func copy() {
        #expect(MenuBarIntro.Copy.bubbleTitle == "Winbar lives here now")
        for words in [MenuBarIntro.Copy.bubble, MenuBarIntro.Copy.whereToLook(.notShown),
                      MenuBarIntro.Copy.whereToLook(.behindNotch)] {
            #expect(words.contains("connect to Windows") && words.contains("start or shut it down")
                        && words.contains("bring back its screen"), "\(words)")
        }
        let hidden = MenuBarIntro.Copy.whereToLook(.notShown)
        #expect(hidden.contains("move the pointer to the top of the screen"))
        #expect(hidden.contains("System Settings"))
        #expect(MenuBarIntro.Copy.whereToLook(.behindNotch).contains("beside the camera"))
        #expect(MenuBarIntro.Copy.bShowMe == "Show Me")
    }

    @Test("The once-per-Mac flag belongs to this copy of Winbar, and a report shows it")
    func setting() {
        let key = Config.Key.menuBarIconIntroduced
        #expect(Config.Key.all.contains(key))
        #expect(!Config.Key.perVM.contains(key))
        #expect(Diagnose.winbarKeys([key, "NSGlobalDomainThing"]) == [key])
    }

    /// Outside Winbar.app there is no status item and no popover: the introduction counts as done, and
    /// the icon as not shown. Only read here: marking it through `live` must never reach the settings.
    @Test("Under test, the live introduction is inert")
    @MainActor func inertUnderTest() {
        let live = MenuBarIntro.live
        #expect(live.introduced())
        #expect(live.locate() == .notShown)
    }
}

@MainActor @Suite("Introducing the menu bar icon, on the finished page")
struct MenuBarIntroRowTests {
    /// The app's side, counted.
    final class App {
        var introduced = false
        var icon: MenuBarIntro.Icon = .shown
        var pointed = 0
        var environment: MenuBarIntro.Environment {
            MenuBarIntro.Environment(introduced: { self.introduced }, markIntroduced: { self.introduced = true },
                                     locate: { self.icon }, point: { self.pointed += 1 })
        }
    }

    /// The row in a window of its own, never shown, and its words once it has appeared.
    private func appear(_ app: App) throws -> [Drawing.Line] {
        let row = MenuBarIntroRow(environment: app.environment)
        let host = NSHostingView(rootView: row.frame(width: 520, height: 200))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 520, height: 200), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        window.close()
        return try Drawing.lines(try #require(bitmap.representation(using: .png, properties: [:])))
    }

    /// Control: remove the row's `onAppear` and nothing points.
    @Test("The first appearance points at a shown icon, once, and says nothing on the page")
    func firstTimePoints() throws {
        let app = App()
        let lines = try appear(app)
        #expect(app.pointed == 1)
        #expect(app.introduced)
        #expect(Drawing.find(MenuBarIntro.Copy.bShowMe, in: lines) != nil, "\(lines)")
        #expect(Drawing.find("isn't showing it", in: lines) == nil, "\(lines)")
        // Appearing again on this Mac: nothing more.
        _ = try appear(app)
        #expect(app.pointed == 1)
    }

    /// Control: have `.say` point instead and the words aren't drawn.
    @Test("Where macOS isn't showing the icon, the page says where to look instead of pointing")
    func fallsBackToWords() throws {
        let app = App()
        app.icon = .notShown
        let lines = try appear(app)
        #expect(app.pointed == 0)
        #expect(app.introduced)
        #expect(Drawing.find("isn't showing it", in: lines) != nil, "\(lines)")
    }

    @Test("A Mac that was introduced already gets neither the popover nor the words, only Show Me")
    func laterAppearances() throws {
        let app = App()
        app.introduced = true
        app.icon = .notShown
        let lines = try appear(app)
        #expect(app.pointed == 0)
        #expect(Drawing.find("isn't showing it", in: lines) == nil, "\(lines)")
        #expect(Drawing.find(MenuBarIntro.Copy.bShowMe, in: lines) != nil, "\(lines)")
    }

    /// On the finished page, under the result: the line and Show Me. Control: take `MenuBarIntroRow`
    /// out of `FinishArrival` and neither is there.
    @Test("Drawn, the finished page says where Winbar lives, with Show Me")
    func onTheFinishedPage() throws {
        let png = try #require(Snapshot.png(SetupScreen(state: FinishFixtures.ready, art: nil, send: { _ in }),
                                            size: CGSize(width: 600, height: 1000), appearance: .light))
        let lines = try Drawing.lines(png)
        let line = try #require(Drawing.find(MenuBarIntro.Copy.line, in: lines), "\(lines)")
        #expect(Drawing.find(MenuBarIntro.Copy.bShowMe, in: lines) != nil, "\(lines)")
        let login = try #require(Drawing.find(LaunchAtLogin.Copy.toggle, in: lines), "\(lines)")
        #expect(line.frame.minY < login.frame.minY)
    }
}
