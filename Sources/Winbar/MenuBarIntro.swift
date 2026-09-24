import AppKit
import SwiftUI

/// Introducing Winbar's icon in the menu bar, from Set Up Winbar's finished page.
///
/// Why: once setup is done, everything is in that icon's menu — Connect, Start, Shut Down, Bring Back
/// Windows' Screen… — and someone who has only ever seen the window has no reason to know it's up
/// there. The owner, walking the wizard on a fresh VM, asked for the icon to be pointed at. So the
/// finished page points at it once per Mac as it first appears (`Config.menuBarIconIntroduced`), and
/// its **Show Me** points again whenever it's pressed.
///
/// The pointer is a popover from the status item's own button, so it points wherever macOS put the
/// icon. Where macOS isn't showing the icon, a popover would point at nothing, so the page says it in
/// words instead, with where to look. What Winbar can tell: the button has no window, macOS isn't
/// showing that window, the window is off every screen (a hidden menu bar, or the icon switched off in
/// the menu bar's settings), or — on a screen with a camera housing — the icon sits left of the menu
/// bar's right-hand part, where macOS keeps the icons that don't fit (`icon`). What it can't: on macOS
/// 27, a probe's surplus icons were all put in one pile at the right edge of the housing, each with a
/// window macOS called visible, so an icon in that pile is pointed at where it is.
enum MenuBarIntro {
    /// The icon's SF Symbol, as the menu bar draws it (filled while Windows runs), and as the page
    /// shows it beside **Show Me**, so the person knows what to look for.
    static let iconSymbol = "square.split.2x2"

    /// Where the icon is, as far as Winbar can tell.
    enum Icon: Equatable {
        case shown
        /// Left of the menu bar's part right of the camera housing: macOS hides icons there.
        case behindNotch
        /// No window, one macOS isn't showing, or one off every screen.
        case notShown
    }

    /// One screen: its frame, and the two parts of its menu bar either side of a camera housing
    /// (`NSScreen.auxiliaryTopLeftArea`, `auxiliaryTopRightArea`), which are empty without one.
    struct Screen: Equatable {
        var frame: CGRect
        var topLeft: CGRect = .zero
        var topRight: CGRect = .zero

        /// The menu bar's part right of the housing, in global coordinates, or nil without a housing.
        /// AppKit doesn't say which coordinates those two areas are in; the left one always starts at
        /// the screen's top-left corner, which tells global from the screen's own.
        var rightOfNotch: CGRect? {
            guard !topLeft.isEmpty, !topRight.isEmpty else { return nil }
            if topLeft.minX == frame.minX, topLeft.maxY == frame.maxY { return topRight }
            return topRight.offsetBy(dx: frame.minX, dy: frame.minY)
        }
    }

    /// Where the icon is, from its button's frame on screen (nil without a window), whether macOS is
    /// showing that window, and the screens. Pure.
    static func icon(button: CGRect?, windowShown: Bool, screens: [Screen]) -> Icon {
        guard let button, windowShown, button.width > 0, button.height > 0 else { return .notShown }
        let centre = CGPoint(x: button.midX, y: button.midY)
        guard let screen = screens.first(where: { $0.frame.contains(centre) }) else { return .notShown }
        if let right = screen.rightOfNotch, centre.x < right.minX { return .behindNotch }
        return .shown
    }

    /// What the finished page does now.
    enum Action: Equatable {
        /// The popover from the icon.
        case point
        /// The words on the page, for where the icon isn't shown.
        case say(Icon)
        case nothing
    }

    /// As the finished page appears (`pressed` false), only on the first time on this Mac; on **Show
    /// Me**, every time. Either way, a popover where the icon is shown and the words where it isn't.
    /// Pure.
    static func action(pressed: Bool, introducedBefore: Bool, icon: Icon) -> Action {
        guard pressed || !introducedBefore else { return .nothing }
        return icon == .shown ? .point : .say(icon)
    }

    /// What the page needs from the app: the once-per-Mac flag, where the icon is, and the popover.
    struct Environment {
        var introduced: () -> Bool
        var markIntroduced: () -> Void
        var locate: () -> Icon
        var point: () -> Void
    }

    /// The real thing only inside Winbar.app, from its menu bar app. Under `swift test` there is no
    /// status item, the introduction counts as done so appearing does nothing, nothing is written to
    /// the settings, and no popover is shown: a **Show Me** there gets the words.
    @MainActor static var live: Environment {
        guard AppPresence.isTheApp, let app = NSApp.delegate as? AppDelegate else {
            return Environment(introduced: { true }, markIntroduced: {}, locate: { .notShown }, point: {})
        }
        return Environment(introduced: { Config.menuBarIconIntroduced },
                           markIntroduced: { Config.menuBarIconIntroduced = true },
                           locate: { app.iconPlace() },
                           // A beat after the page appears, so the popover arrives on a page already
                           // drawn rather than with it.
                           point: { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { app.pointAtIcon() } })
    }

    enum Copy {
        /// Beside the icon and **Show Me** on the finished page.
        static let line = "Winbar lives in the menu bar now."
        static let bShowMe = "Show Me"
        /// The popover: one heading and one sentence, where the icon is.
        static let bubbleTitle = "Winbar lives here now"
        static let bubble = "Choose this icon to connect to Windows, start or shut it down, or bring back its screen."
        /// On the page when the icon isn't shown, with where to look. Only what macOS does: it hides
        /// the icons that don't fit beside a camera housing, it can hide the whole menu bar until the
        /// pointer reaches the top, and newer versions let an app's icons be switched off (named
        /// generally, since that setting has moved between versions).
        static func whereToLook(_ icon: Icon) -> String {
            let found = icon == .behindNotch
                ? "Winbar's icon is in the menu bar, but there are more icons than fit beside the camera at the top "
                    + "of your screen, so macOS is hiding it. Quitting an app or two that has an icon there makes room."
                : "Winbar's icon is in the menu bar at the top right of your screen, but macOS isn't showing it right "
                    + "now. If the menu bar is hidden, move the pointer to the top of the screen. If the icon still "
                    + "isn't there, check that Winbar is allowed in the menu bar in System Settings."
            return found + " Its menu is where you connect to Windows, start or shut it down, and bring back its screen."
        }
    }
}

/// The finished page's line about the icon: the icon itself, where Winbar lives now, and **Show Me**;
/// under it, only when the icon isn't shown, where to look. As it appears it introduces the icon, once
/// per Mac (`MenuBarIntro.action`).
struct MenuBarIntroRow: View {
    var environment: MenuBarIntro.Environment
    /// Where the icon isn't shown, once the page has said so.
    @State private var said: MenuBarIntro.Icon?

    @MainActor init(environment: MenuBarIntro.Environment? = nil) {
        self.environment = environment ?? MenuBarIntro.live
    }

    var body: some View {
        withSetupAppearance { look in
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: MenuBarIntro.iconSymbol)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(look.mutedText)
                        .accessibilityHidden(true)
                    Text(MenuBarIntro.Copy.line)
                    Button(MenuBarIntro.Copy.bShowMe) { act(pressed: true) }
                }
                if let said {
                    Text(verbatim: MenuBarIntro.Copy.whereToLook(said))
                        .font(.system(size: SetupStyle.smallestText))
                        .foregroundStyle(look.mutedText)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 400)
                }
            }
        }
        .onAppear { act(pressed: false) }
    }

    private func act(pressed: Bool) {
        switch MenuBarIntro.action(pressed: pressed, introducedBefore: environment.introduced(), icon: environment.locate()) {
        case .nothing:
            break
        case .point:
            environment.markIntroduced()
            said = nil
            environment.point()
        case .say(let icon):
            environment.markIntroduced()
            said = icon
        }
    }
}

/// The popover's words, pointing up at the icon.
struct MenuBarIntroBubble: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(MenuBarIntro.Copy.bubbleTitle).font(.headline)
            Text(MenuBarIntro.Copy.bubble)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 270, alignment: .leading)
    }
}
