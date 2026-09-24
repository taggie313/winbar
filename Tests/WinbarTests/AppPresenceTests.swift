import AppKit
import Testing
@testable import Winbar

@MainActor @Suite("Winbar is in the Dock while a window of its own is open, and text fields can paste")
struct AppPresenceTests {
    @Test func policyFollowsWindows() {
        #expect(AppPresence.policy(windowsOpen: true) == .regular)
        #expect(AppPresence.policy(windowsOpen: false) == .accessory)
    }

    /// An alert or panel run from the menu bar keeps Winbar in the Dock and ⌘-Tab while it is up, even
    /// with no window of its own open: that is its only way back from behind another app.
    @Test func anAlertIsInTheDockWhileItIsUp() {
        #expect(AppPresence.policy(windowsOpen: false, modalUp: true) == .regular)
        #expect(AppPresence.policy(windowsOpen: true, modalUp: true) == .regular)
    }

    /// `modal` counts itself in for exactly as long as its body runs, nested or not, so the presence
    /// goes back to what the windows say as soon as the last alert is answered.
    @Test func modalCountsForTheLengthOfTheBody() {
        #expect(AppPresence.modalDepth == 0)
        let seen = AppPresence.modal { () -> [Int] in
            let outer = AppPresence.modalDepth
            let inner = AppPresence.modal { AppPresence.modalDepth }
            return [outer, inner, AppPresence.modalDepth]
        }
        #expect(seen == [1, 2, 1])
        #expect(AppPresence.modalDepth == 0)
    }

    /// Every alert and panel the menu bar opens goes through `modal`: the file is read as text, since
    /// the delegate can't be made in a test (it puts an icon in the menu bar).
    @Test func everyMenuAlertRunsThroughModal() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Winbar/MenuBar.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let lines = source.split(separator: "\n").map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        let modals = lines.filter { $0.contains("runModal()") }
        #expect(modals.count >= 6)   // fail, inform, confirm, the force-stop offer, the report, the folder chooser
        for line in modals { #expect(line.contains("AppPresence.modal"), "\(line)") }
        // The deprecated activation it replaces, which macOS 14 may decline.
        #expect(!source.contains("activate(ignoringOtherApps:"))
    }

    /// A titled window counts; a panel (alerts, the ISO chooser) and a hidden window don't. A minimised
    /// one does: its way back is the Dock.
    @Test func whichWindowsCount() {
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        #expect(!AppPresence.counts(window))            // not on screen yet
        let panel = NSPanel(contentRect: .init(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled],
                            backing: .buffered, defer: true)
        #expect(!AppPresence.counts(panel))
        let bare = NSWindow(contentRect: .init(x: 0, y: 0, width: 20, height: 20), styleMask: [.borderless],
                            backing: .buffered, defer: true)
        #expect(!AppPresence.counts(bare))
    }

    /// Without these items ⌘V, ⌘C, ⌘A and ⌘Z do nothing in a text field: AppKit sends them through the
    /// main menu. A password or product key has to be pasteable.
    @Test func editMenuHasTheTextShortcuts() throws {
        let menu = AppPresence.mainMenu()
        let edit = try #require(menu.items.first { $0.title == "Edit" }?.submenu)
        let pairs = edit.items.map { ($0.action.map(NSStringFromSelector) ?? "", $0.keyEquivalent) }
        for (action, key) in [("paste:", "v"), ("copy:", "c"), ("cut:", "x"), ("selectAll:", "a"), ("undo:", "z")] {
            #expect(pairs.contains { $0 == (action, key) }, "\(action) ⌘\(key)")
        }
        let window = try #require(menu.items.first { $0.title == "Window" }?.submenu)
        #expect(window.items.contains { $0.action == #selector(NSWindow.performClose(_:)) && $0.keyEquivalent == "w" })
        #expect(menu.items.first?.submenu?.items.contains { $0.action == #selector(NSApplication.terminate(_:)) } == true)
    }
}

@MainActor @Suite("Help, About and the version")
struct HelpAndAboutTests {
    @Test("A Help menu: Winbar Help on ⌘?, Troubleshooting, and Report a Problem…, set as the app's help menu")
    func helpMenu() throws {
        let menu = AppPresence.mainMenu()
        let help = try #require(menu.items.first { $0.title == "Help" }?.submenu)
        #expect(NSApplication.shared.helpMenu === help)
        let winbarHelp = try #require(help.item(withTitle: "Winbar Help"))
        #expect(winbarHelp.keyEquivalent == "?")
        #expect((winbarHelp.representedObject as? URL)?.absoluteString == "https://github.com/taggie313/winbar#readme")
        #expect(winbarHelp.target === MainMenuActions.shared)
        let troubleshooting = try #require(help.item(withTitle: "Troubleshooting"))
        #expect((troubleshooting.representedObject as? URL)?.fragment == "troubleshooting")
        let report = try #require(help.item(withTitle: Diagnose.Copy.menuItem))
        #expect(report.action == #selector(AppDelegate.reportProblem))
        #expect(report.target == nil)   // up the responder chain, to the app's delegate
    }

    /// The anchor is GitHub's slug of a README heading; renaming the heading would break the item.
    @Test("Troubleshooting's anchor is a heading the README has")
    func troubleshootingAnchorExists() throws {
        let readme = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("README.md")
        let headings = try String(contentsOf: readme, encoding: .utf8).split(separator: "\n")
            .filter { $0.hasPrefix("## ") }.map { $0.dropFirst(3).lowercased().replacingOccurrences(of: " ", with: "-") }
        #expect(headings.contains(HelpLink.troubleshooting.url.fragment ?? ""))
    }

    @Test("About Winbar opens Winbar's own panel, not the bare standard one")
    func aboutItem() throws {
        let app = try #require(AppPresence.mainMenu().items.first?.submenu)
        let about = try #require(app.item(withTitle: "About Winbar"))
        #expect(about.action == #selector(MainMenuActions.showAbout(_:)))
        #expect(about.target === MainMenuActions.shared)
    }

    /// The version once (not "0.2.0 (0.2.0)"), the copyright, the licence and a link.
    @Test("The About panel is given the version, the copyright, the licence and the link")
    func aboutOptions() throws {
        let options = AboutPanel.options(version: "9.8.7")
        #expect(options[.applicationVersion] as? String == "9.8.7")
        #expect(options[.version] as? String == "")
        #expect(options[NSApplication.AboutPanelOptionKey(rawValue: "Copyright")] as? String == "© 2026 Joshua Lutz")
        let credits = try #require(options[.credits] as? NSAttributedString)
        #expect(credits.string.contains("MIT License"))
        #expect(credits.string.contains("github.com/taggie313/winbar"))
        var linked: URL?
        credits.enumerateAttribute(.link, in: NSRange(location: 0, length: credits.length)) { value, _, _ in
            if let url = value as? URL { linked = url }
        }
        #expect(linked == AboutPanel.homepage)
    }
}
