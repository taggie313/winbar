import AppKit

/// Winbar lives in the menu bar (`LSUIElement`): no Dock icon, no app menu, not in ⌘-Tab. That suits
/// it while it only has a menu, but with Set Up Winbar or the New Windows VM window open it meant a
/// window behind another app had no way back — nothing in the Dock to click, nothing in ⌘-Tab — and
/// the person reported the window as never having opened. So while one of Winbar's own windows is on
/// screen it is an ordinary app, with Armie's icon in the Dock and a place in ⌘-Tab, and it goes back
/// to the menu bar when the last one closes.
enum AppPresence {
    /// `.regular` while a window of Winbar's own is open, or an alert or panel is up through `modal`;
    /// `.accessory` otherwise. Pure.
    static func policy(windowsOpen: Bool, modalUp: Bool = false) -> NSApplication.ActivationPolicy {
        windowsOpen || modalUp ? .regular : .accessory
    }

    /// Whether this process is Winbar.app itself. Under `swift test` the windows are offscreen
    /// fixtures and the alerts are never run, and flipping the test runner into a Dock app — or
    /// activating it — would be a side effect of drawing them.
    @MainActor static var isTheApp: Bool { Bundle.main.bundleIdentifier == "net.elusive.winbar" && NSApp != nil }

    /// How many `modal` blocks are running, nested ones included.
    @MainActor private(set) static var modalDepth = 0

    /// Runs an app-modal alert or panel (`NSAlert.runModal`, `NSOpenPanel.runModal`) with Winbar in the
    /// Dock and ⌘-Tab for as long as it is up, then puts the presence back the way the windows say.
    ///
    /// Why: alerts and panels don't count as Winbar's windows (`counts` leaves out every `NSPanel`), so
    /// one opened from the menu bar ran with Winbar still an accessory app. After the two or three
    /// minutes of Start and Connect, or with the folder chooser left behind Finder while someone made a
    /// folder, macOS 14's cooperative activation could leave it behind other windows, and there was
    /// nothing in the Dock or ⌘-Tab to bring it back — while the menu stayed blocked behind it, so
    /// Winbar looked frozen. Going regular gives it that way back; the bounce, when activation is
    /// declined, says where to look.
    ///
    /// Not itself main-actor isolated, because the menu's delegate isn't, but it must be called on the
    /// main thread — where every `runModal` has to be anyway — and traps otherwise.
    static func modal<T>(_ body: () -> T) -> T {
        MainActor.assumeIsolated { enterModal() }
        defer { MainActor.assumeIsolated { leaveModal() } }
        return body()
    }

    @MainActor private static func enterModal() {
        modalDepth += 1
        update()
        guard isTheApp else { return }
        NSApp.activate()
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
    }

    @MainActor private static func leaveModal() {
        modalDepth -= 1
        update()
    }

    /// Whether a window is one of Winbar's own, which keeps it in the Dock: a titled, ordinary window.
    /// Not the status item's, a menu's, an alert's or the ISO chooser's (panels), and not a sheet.
    static func counts(_ window: NSWindow) -> Bool {
        window.styleMask.contains(.titled) && !(window is NSPanel) && !window.isSheet
            && (window.isVisible || window.isMiniaturized)
    }

    /// After one of Winbar's windows opens or is about to close. `closing` is still on screen during
    /// `windowWillClose`, so it is left out by hand. A minimised window keeps the Dock icon: that's
    /// where it went.
    @MainActor static func update(closing: NSWindow? = nil) {
        // Only the app itself: under `swift test` the windows are offscreen fixtures, and flipping the
        // test runner into a Dock app would be a side effect of drawing them.
        guard isTheApp else { return }
        let open = NSApp.windows.contains { $0 !== closing && counts($0) }
        let wanted = policy(windowsOpen: open, modalUp: modalDepth > 0)
        guard NSApp.activationPolicy() != wanted else { return }
        NSApp.setActivationPolicy(wanted)
        if wanted == .regular { NSApp.activate() }
    }

    /// Winbar's own windows, frontmost first, minimised ones after the ones on screen: what a reopen
    /// (the Dock icon, Finder, Spotlight) should bring back before it opens anything new.
    @MainActor static func reopenCandidates() -> [NSWindow] {
        let ordered = NSApp.orderedWindows
        let rest = NSApp.windows.filter { window in !ordered.contains { $0 === window } }
        return (ordered + rest).filter(counts)
    }

    /// Brings one of Winbar's windows back: out of the Dock if it was minimised, then in front.
    @MainActor static func bringForward(_ window: NSWindow) {
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        // The same reason as `SetupWindowController.show`: activation may be declined, and the window
        // should be where the person looks either way.
        window.orderFrontRegardless()
        NSApp.activate()
    }

    /// The menus an app with windows is expected to have. Without an Edit menu ⌘V, ⌘C, ⌘A and ⌘Z do
    /// nothing in a text field — AppKit routes them through the main menu's items — so a password or
    /// product key couldn't be pasted into the wizard or the New Windows VM form. The menu bar only
    /// shows these while Winbar is a regular app; the key equivalents work whenever it is active.
    @MainActor static func mainMenu(appName: String = "Winbar") -> NSMenu {
        let main = NSMenu()

        let app = NSMenu(title: appName)
        // Not the bare standard panel: that showed "0.2.0 (0.2.0)", no copyright and no licence.
        let about = app.addItem(withTitle: "About \(appName)", action: #selector(MainMenuActions.showAbout(_:)), keyEquivalent: "")
        about.target = MainMenuActions.shared
        app.addItem(.separator())
        app.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu(app, title: appName))

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu(edit, title: "Edit"))

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(submenu(window, title: "Window"))
        NSApplication.shared.windowsMenu = window

        // Without a Help menu ⌘? did nothing, and there was no way from the app to its own
        // troubleshooting guide. Setting `helpMenu` also gives it macOS's menu search field.
        let help = NSMenu(title: "Help")
        for link in HelpLink.allCases {
            let item = help.addItem(withTitle: link.title, action: #selector(MainMenuActions.openLink(_:)),
                                    keyEquivalent: link == .winbarHelp ? "?" : "")
            item.target = MainMenuActions.shared
            item.representedObject = link.url
        }
        help.addItem(.separator())
        // Sent up the responder chain to the app's delegate, which is where the status menu's own
        // Report a Problem… goes: one report, one dialog, whichever menu it was chosen from.
        help.addItem(withTitle: Diagnose.Copy.menuItem, action: #selector(AppDelegate.reportProblem), keyEquivalent: "")
        main.addItem(submenu(help, title: "Help"))
        NSApplication.shared.helpMenu = help
        return main
    }

    private static func submenu(_ menu: NSMenu, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}

/// Where the Help menu goes: the README on GitHub, which is the manual, and its Troubleshooting section.
enum HelpLink: CaseIterable {
    case winbarHelp, troubleshooting

    var title: String {
        switch self {
        case .winbarHelp: return "Winbar Help"
        case .troubleshooting: return "Troubleshooting"
        }
    }

    /// GitHub's anchors are the heading, lowercased, with spaces as hyphens. `## Troubleshooting` is
    /// checked against the README by a test, so renaming the heading can't quietly break the item.
    var url: URL {
        switch self {
        case .winbarHelp: return URL(string: "https://github.com/\(UpdateCheck.repo)#readme")!
        case .troubleshooting: return URL(string: "https://github.com/\(UpdateCheck.repo)#troubleshooting")!
        }
    }
}

/// The About panel: the standard one, given what it was missing.
enum AboutPanel {
    /// Also `NSHumanReadableCopyright` in Info.plist, for Finder's Get Info; a test holds the two equal.
    static let copyright = "© 2026 Joshua Lutz"
    static let homepage = URL(string: "https://github.com/\(UpdateCheck.repo)")!

    /// The version once. The panel shows "Version X (Y)" with Y from `CFBundleVersion`, which
    /// build-app.sh stamps with the same value, so it read "0.2.0 (0.2.0)"; an empty build version
    /// is AppKit's way of leaving the parentheses out. The copyright is passed as well as read from
    /// Info.plist, so a `swift run` build shows it too.
    static func options(version: String) -> [NSApplication.AboutPanelOptionKey: Any] {
        [.applicationVersion: version,
         .version: "",
         NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): copyright,
         .credits: credits()]
    }

    /// The licence and the one link, which never reached the installed app before; and the line the
    /// README ends on, since Winbar's name puts Windows next to it.
    static func credits() -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let plain: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]
        let text = NSMutableAttributedString(string: "Released under the MIT License.\n", attributes: plain)
        var link = plain
        link[.link] = homepage
        text.append(NSAttributedString(string: homepage.absoluteString.replacingOccurrences(of: "https://", with: ""),
                                       attributes: link))
        text.append(NSAttributedString(string: "\n\nNot affiliated with Microsoft or UTM.", attributes: plain))
        return text
    }
}

/// The main menu's own actions. Not the app delegate's: the main menu is built before there is one
/// (main.swift), and a test builds it with no delegate at all.
@MainActor final class MainMenuActions: NSObject {
    static let shared = MainMenuActions()

    @objc func showAbout(_ sender: Any?) {
        NSApp.orderFrontStandardAboutPanel(options: AboutPanel.options(version: AppBundle.version))
        NSApp.activate()
    }

    @objc func openLink(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
    }
}
