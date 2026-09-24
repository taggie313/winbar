import AppKit
import ApplicationServices

/// Opens Windows App's *saved* PC rather than a one-off .rdp file.
///
/// Only saved PCs use Windows App's stored credentials: `ms-rd:` addresses cloud workspaces only, and
/// `rdp://` carries settings but never a password. The app has no AppleScript and no App Intents; it
/// does have a scripting command line (`WindowsAppBookmarks`), but that can only *save* a PC, not open
/// one — there is no connect verb. So Winbar presses the saved PC's tile through the Accessibility API,
/// with the chooser minimized and the app hidden first so the chooser never appears.
enum WindowsApp {
    static var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: Config.windowsAppBundleID) }

    static var version: String? {
        guard let url = appURL else { return nil }
        return Bundle(url: url)?.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    /// This process's own grant. From the CLI that's Terminal's, not Winbar's; see `SelfTest`.
    static var accessibilityTrusted: Bool { AXIsProcessTrusted() }

    static func requestAccessibility() {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private struct Target { let window: AXUIElement; let tile: AXUIElement }

    /// The names a saved PC's tile may carry: its friendly name when the user gave it one (the tile's
    /// accessibility description is then that name, not the host), else the host itself.
    static func tileNames(host: String) -> [String] {
        tileNames(host: host, savedName: Config.savedPCName, otherAccountHost: Config.savedPCOtherAccountHost)
    }

    /// The same, from the settings passed in. Pure.
    ///
    /// When Windows App has a saved PC for this host that signs in as another account
    /// (`otherAccountHost`), a tile named after the host may be that one, and pressing it signs in
    /// as someone else — live, it opened a leftover from a deleted VM. Then only this VM's own saved
    /// PC is pressed, by its own name; with none, nothing is, and Connect falls back to a one-off
    /// connection that asks for the password.
    static func tileNames(host: String, savedName: String?, otherAccountHost: String?) -> [String] {
        let name = savedName.flatMap { $0 != host ? $0 : nil }
        if let otherAccountHost, otherAccountHost.caseInsensitiveCompare(host) == .orderedSame {
            return name.map { [$0] } ?? []
        }
        return (name.map { [$0] } ?? []) + [host]
    }

    /// Blocking; call off the main thread in the app. False means the tile couldn't be found or pressed.
    static func openSavedPC(host: String) -> Bool {
        let names = tileNames(host: host)
        guard !names.isEmpty else {
            NSLog("Winbar: the saved PC for \(host) signs in as another account; not pressing it")
            return false
        }
        guard accessibilityTrusted, let appURL else { return false }

        // A stuck `--script` copy shares the app's bundle id; it is neither the app to search nor one
        // to hand the connection to (WindowsAppProcesses).
        WindowsAppProcesses.stopStuckScriptCopies()
        var running = WindowsAppProcesses.apps().first
        if running == nil {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.hides = true
            let launched = DispatchSemaphore(value: 0)
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { app, _ in
                running = app
                launched.signal()
            }
            _ = launched.wait(timeout: .now() + 15)
        }
        guard let app = running else { return false }
        let element = AXUIElementCreateApplication(app.processIdentifier)

        var target = waitFor(seconds: 6) { findTile(in: element, names: names, selectDevices: false) }
        if target == nil {
            // The chooser is closed or on another section. Reopening it is the one case that can flash.
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration, completionHandler: nil)
            target = waitFor(seconds: 8) { findTile(in: element, names: names, selectDevices: true) }
        }
        guard let target else {
            NSLog("Winbar: saved PC \(names.joined(separator: " / ")) not found in Windows App")
            return false
        }
        // Finding the tile no longer writes `Config.savedPCHost`. A tile is only a name, and may be a
        // stale PC that signs in as nobody; C2 then called it "your word" when nobody had said a thing.
        // A press counts once the person has seen the desktop it opened (`Recipe.connectedSavedPC`).

        AXUIElementSetAttributeValue(target.window, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
        onMain { _ = app.hide() }
        let pressed = AXUIElementPerformAction(target.tile, kAXPressAction as CFString) == .success
        NSLog("Winbar: pressed saved PC \(host): \(pressed)")
        guard pressed else { return false }
        // Pressing unhides Windows App but doesn't activate it, so an existing full-screen session stays
        // on its own Space. Activating switches to it; it doesn't restore the minimized chooser.
        pause(0.5)
        onMain { _ = app.activate() }
        return true
    }

    private static func findTile(in app: AXUIElement, names: [String], selectDevices: Bool) -> Target? {
        let windows: [AXUIElement] = attribute(app, kAXWindowsAttribute) ?? []
        for window in windows {
            if let tile = descendant(of: window, matching: { element in
                (attribute(element, kAXDescriptionAttribute) as String?).map(names.contains) == true
                    && actions(of: element).contains(kAXPressAction)
            }) {
                return Target(window: window, tile: tile)
            }
            if selectDevices, let devices = descendant(of: window, matching: { element in
                (attribute(element, kAXRoleAttribute) as String?) == kAXButtonRole
                    && (attribute(element, kAXDescriptionAttribute) as String?) == "Devices"
            }) {
                AXUIElementPerformAction(devices, kAXPressAction as CFString)
            }
        }
        return nil
    }

    private static func waitFor(seconds: TimeInterval, _ probe: () -> Target?) -> Target? {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if let found = probe() { return found }
            pause(0.3)
        } while Date() < deadline
        return nil
    }

    /// Breadth-first, capped: Windows App's tree is large and a runaway walk would stall Connect.
    private static func descendant(of root: AXUIElement, matching match: (AXUIElement) -> Bool) -> AXUIElement? {
        var queue = [root]
        var next = 0
        while next < queue.count && next < 4000 {
            let element = queue[next]
            next += 1
            if match(element) { return element }
            if let children: [AXUIElement] = attribute(element, kAXChildrenAttribute) { queue.append(contentsOf: children) }
        }
        return nil
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    private static func actions(of element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }
}

/// Quits Windows App politely and says when it has gone: **Quit Windows App** on the saved PC step
/// asks every running copy to terminate (never force: it may hold someone's session) and watches
/// NSWorkspace for the last one to end, so the step reads again by itself. A quit Windows App turns
/// down (a session it asks about) leaves the watch in place until it does quit; the next press
/// replaces it.
final class WindowsAppQuitter {
    static let shared = WindowsAppQuitter()

    private let center = NSWorkspace.shared.notificationCenter
    private var watch: NSObjectProtocol?

    func quit(then done: @escaping () -> Void) {
        if let watch { center.removeObserver(watch) }
        watch = nil
        let running = { WindowsAppProcesses.apps() }   // the app, not a stuck --script copy
        guard !running().isEmpty else { done(); return }
        watch = center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil,
                                   queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == Config.windowsAppBundleID, running().allSatisfy(\.isTerminated) else { return }
            if let self, let watch = self.watch { self.center.removeObserver(watch); self.watch = nil }
            done()
        }
        running().forEach { _ = $0.terminate() }
    }
}
