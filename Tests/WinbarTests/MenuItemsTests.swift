import AppKit
import Testing
@testable import Winbar

// `NSMenuItem.make`: the step between the value MenuShapeTests pins and what is on the menu bar.
//
// MenuShapeTests can only say the value is right. Whether ⌘Q, the Launch at Login tick and Force
// Stop's ⌥ reach AppKit is decided here, and when this was a private method of AppDelegate its tick
// and mask lines could be deleted with every test green. So these build real NSMenuItems — first the
// items each field matters most to, then every menu there is — and read them back.
//
// Building an NSMenuItem reaches nothing outside this process: no status item, no UTM, no VM, no
// login-items service. The selectors are stand-ins, since the real ones are AppDelegate's private
// methods and an AppDelegate can't be made without putting an icon in the menu bar.

/// A stand-in selector per action, one each, so a test can tell which action an item was given.
private func selector(_ action: MenuAction) -> Selector {
    if case .chooseVM = action { return NSSelectorFromString("chooseVM:") }
    return NSSelectorFromString("\(action)")
}

/// Every action there is but chooseVM, which carries a VM and is read back from the item instead. A new
/// action belongs here too, or every menu that has it reads back as nothing.
private let plainActions: [MenuAction] = [
    .connect, .start, .shutDown, .forceStop, .restart, .toggleConsole, .sharedFolder, .openUTM, .newWindowsVM,
    .showInstallProgress, .reportProblem, .showUpdate, .launchAtLogin, .startWindowsAtLaunch, .quit,
    .openAutomationSettings, .setUpWinbar, .sendReport,
]

private func state(vm: String? = "winlab01", running: Bool = false, launchAtLogin: Bool = false) -> MenuState {
    MenuState(status: MenuStatus(vmName: vm, running: running), launchAtLogin: launchAtLogin)
}

@Suite("The menu, as AppKit is given it")
@MainActor
struct MenuItemsTests {
    private let target = NSObject()
    private let chooseMenu = NSMenu()

    /// The whole menu `given` describes, built the way the delegate builds it, and the status line
    /// `fill` handed back.
    private func build(_ given: MenuState) -> (menu: NSMenu, statusLine: NSMenuItem?) {
        let menu = NSMenu()
        let statusLine = menu.fill(with: MenuShape.items(given), target: target, selector: selector,
                                   chooseMenu: chooseMenu)
        return (menu, statusLine)
    }

    private func item(_ title: String, in given: MenuState) throws -> NSMenuItem {
        try #require(build(given).menu.item(withTitle: title), "no “\(title)” in the menu")
    }

    @Test("Quit Winbar answers ⌘Q: the key, and ⌘ alone in its mask")
    func quit() throws {
        let quit = try item("Quit Winbar", in: state())
        #expect(quit.keyEquivalent == "q")
        #expect(quit.keyEquivalentModifierMask == [.command])
        #expect(quit.action == selector(.quit))
        #expect(quit.target === target)
        #expect(quit.isEnabled)
    }

    @Test("Launch at Login is ticked when it is on, and unticked when it is off")
    func launchAtLoginTick() throws {
        #expect(try item("Launch at Login", in: state(launchAtLogin: true)).state == .on)
        #expect(try item("Launch at Login", in: state(launchAtLogin: false)).state == .off)
        // What logging in opens, on hover: only the icon.
        #expect(try item("Launch at Login", in: state()).toolTip == LaunchAtLogin.Copy.menuHelp)
    }

    @Test("Start Windows with Winbar is ticked when it is on, sends its own action, and names the VM on hover")
    func startWindowsTick() throws {
        var on = state()
        on.startsWindows = true
        let ticked = try item("Start Windows with Winbar", in: on)
        #expect(ticked.state == .on)
        #expect(ticked.action == selector(.startWindowsAtLaunch))
        #expect(ticked.target === target)
        #expect(ticked.isEnabled)
        #expect(ticked.toolTip == StartWindowsAtLaunch.Copy.menuHelp(vm: "winlab01"))
        #expect(try item("Start Windows with Winbar", in: state()).state == .off)
        // Right under Launch at Login, as the finished screen has it.
        let menu = build(on).menu
        let launch = try #require(menu.item(withTitle: "Launch at Login"))
        let start = try #require(menu.item(withTitle: "Start Windows with Winbar"))
        #expect(menu.index(of: start) == menu.index(of: launch) + 1)
    }

    @Test("Force Stop is Shut Down's alternate: right after it, the same key, and ⌥ where Shut Down has nothing")
    func shutDownAndForceStop() throws {
        // macOS shows an alternate in place of the item before it while the alternate's modifiers are
        // held, and pairs them by key equivalent and mask. With ⌘ left in either mask — AppKit's
        // default — the ⌥ swap never happens.
        let menu = build(state(running: true)).menu
        let shutDown = try #require(menu.item(withTitle: "Shut Down"))
        let forceStop = try #require(menu.item(withTitle: "Force Stop"))
        #expect(menu.index(of: forceStop) == menu.index(of: shutDown) + 1)
        #expect(shutDown.keyEquivalent == "" && forceStop.keyEquivalent == "")
        #expect(shutDown.keyEquivalentModifierMask == [])
        #expect(!shutDown.isAlternate)
        #expect(forceStop.keyEquivalentModifierMask == [.option])
        #expect(forceStop.isAlternate)
        #expect(shutDown.action == selector(.shutDown) && forceStop.action == selector(.forceStop))
    }

    @Test("A VM in Choose VM carries the whole VM as UTM listed it, id and all")
    func chooseVMItem() throws {
        let listed = [
            VMInfo(id: "5A1E0C3D-0000-4000-8000-00000000000A", name: "rosa", backend: "qemu", icon: "linux"),
            VMInfo(id: "5A1E0C3D-0000-4000-8000-00000000000D", name: "winlab01", backend: "qemu", icon: "windows"),
        ]
        let statusLine = chooseMenu.fill(with: MenuShape.chooser(utmInstalled: true, vms: listed, error: nil),
                                         target: target, selector: selector, chooseMenu: chooseMenu)
        #expect(statusLine == nil)
        let winlab = try #require(chooseMenu.item(withTitle: "winlab01"))
        // Settings are filed under the id, so it is the id the action has to find on the item.
        #expect(winlab.representedObject as? VMInfo == listed[1])
        #expect(winlab.action == selector(.chooseVM(listed[1])))
        #expect(winlab.target === target)
        #expect(try #require(chooseMenu.item(withTitle: "rosa")).representedObject as? VMInfo == listed[0])
    }

    @Test("Choose VM opens the submenu the delegate fills, and sends the delegate nothing")
    func chooseVMSubmenu() throws {
        let choose = try item("Choose VM", in: state(vm: nil))
        #expect(choose.submenu === chooseMenu)
        // Opening the submenu is AppKit's own doing: it gives an item a submenu action of its own when
        // the item came without one.
        #expect(choose.target !== target)
        #expect(choose.isEnabled)
    }

    @Test("The status line is greyed out, does nothing, and is the item fill hands back to be retitled")
    func statusLine() throws {
        let given = state(running: true)
        let (menu, handedBack) = build(given)
        let statusLine = try #require(handedBack)
        // The very item in the menu, not a copy: render() retitles what it was handed while the menu
        // is open, and a copy would change nothing anyone can see.
        #expect(menu.item(at: 1) === statusLine)
        #expect(statusLine.title == MenuShape.statusText(given.status))
        #expect(!statusLine.isEnabled)
        #expect(statusLine.action == nil && statusLine.target == nil)
        #expect(menu.item(at: 0)?.isSectionHeader == true)
    }

    @Test("Every menu there is reads back from AppKit as the value it was built from")
    func everyMenuReadsBack() {
        // MenuShapeInvariantTests' 2,048 menus, and the Choose VM submenu's variety: a tooltip, the
        // Automation button, VMs to choose. Any field `make` drops or garbles, in any of them, fails.
        let denied = WinbarError("Winbar isn't allowed to control UTM", "Allow it in System Settings.",
                                 automationDenied: true)
        let submenus = [
            MenuShape.chooser(utmInstalled: true, vms: nil, error: denied),
            MenuShape.chooser(utmInstalled: true, vms: [VMInfo(id: "5A1E0C3D-0000-4000-8000-00000000000D",
                                                               name: "winlab01", backend: "qemu")], error: nil),
        ]
        let menu = NSMenu()
        var misread: Set<String> = []
        for specs in MenuShapeInvariantTests.every.map(MenuShape.items) + submenus {
            let statusLine = menu.fill(with: specs, target: target, selector: selector, chooseMenu: chooseMenu)
            for (spec, item) in zip(specs, menu.items) where readBack(item, statusLine: statusLine) != spec {
                misread.insert("\(spec) read back as \(readBack(item, statusLine: statusLine).map { "\($0)" } ?? "nothing")")
            }
            #expect(menu.items.count == specs.count)
        }
        #expect(misread.isEmpty, "\(misread.sorted().joined(separator: "\n"))")
    }

    /// `make` run backwards: the value an NSMenuItem says it was built from, read off every property
    /// the menu sets, or nil when the item holds something no value could have asked for.
    private func readBack(_ item: NSMenuItem, statusLine: NSMenuItem?) -> MenuItemSpec? {
        if item.isSectionHeader { return .header(item.title) }
        if item.isSeparatorItem { return .separator }
        if item === statusLine { return .status(item.title) }

        let mask = item.keyEquivalentModifierMask
        guard mask.isSubset(of: [.command, .option]), item.state != .mixed else { return nil }
        var modifiers: MenuModifiers = []
        if mask.contains(.command) { modifiers.insert(.command) }
        if mask.contains(.option) { modifiers.insert(.option) }

        // An item that is given a submenu and no action gets one from AppKit, aimed at the submenu, to
        // open it with. That one is not Winbar's.
        let appKits = item.submenu != nil && item.target === item.submenu
        var action: MenuAction?
        if let sent = item.action, !appKits {
            guard item.target === target else { return nil }
            if sent == selector(.chooseVM(VMInfo())) {
                guard let vm = item.representedObject as? VMInfo else { return nil }
                action = .chooseVM(vm)
            } else {
                guard item.representedObject == nil, let plain = plainActions.first(where: { selector($0) == sent })
                else { return nil }
                action = plain
            }
        } else {
            guard appKits || item.target == nil, item.representedObject == nil else { return nil }
        }

        var submenu: MenuSubmenu?
        if let opened = item.submenu {
            guard opened === chooseMenu else { return nil }
            submenu = .chooseVM
        }
        return .item(MenuItem(title: item.title, action: action, enabled: item.isEnabled, key: item.keyEquivalent,
                              modifiers: modifiers, isAlternate: item.isAlternate, checked: item.state == .on,
                              toolTip: item.toolTip, submenu: submenu))
    }
}
