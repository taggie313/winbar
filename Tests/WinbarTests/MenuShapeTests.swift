import Foundation
import Testing
@testable import Winbar

// The menu bar's menu, pinned. Every situation the menu can be in has its whole item list written out
// below — titles, order, separators, which items are greyed out, the key equivalents and modifier
// masks, the alternate, the tick — so that a change to one part of the menu that moves another part
// fails here instead of on somebody's menu bar. The lists were written from `menuNeedsUpdate` as it
// stood before the menu became a value, not from `MenuShape`, so they are the menu as it stood on main — except noVMChosen and noVMChosenBusy, which
// dropped 0.1.0's second New Windows VM… on purpose (COHERENCE C1).
//
// They are expected to change when an item is added, as the wizard's Set Up Winbar… did: it added a line
// to every one of them. So did the beta's Send a Problem Report… (`BetaReport`), under Report a Problem…. What must not change with it is the order and grouping of what is already here —
// the VM's block (Connect; Shut Down, Force Stop, Restart; the display and shared-folder items) above
// Open UTM, and Launch at Login and Quit Winbar at the foot.
//
// Set Up Winbar… is offered to everyone from 0.2.0 (`SetupWindow.availableToEveryone`), so the lists in
// MenuShapeSetUpOfferedTests are the menu as it ships. Two things changed when the switch flipped, on
// purpose: the item itself, and the no-VM hint, which names the window instead of Terminal.
//
// Pure logic: `MenuShape` has no AppKit in it, and nothing here reaches UTM, a VM, the login-items
// service or the user's defaults.

/// One line per item, with every field the menu sets, so a list of these can't stay green while ⌘Q,
/// the Launch at Login tick or Force Stop's ⌥ goes missing. A field left at AppKit's default says
/// nothing; anything else is spelled out after a bar.
private func lines(_ items: [MenuItemSpec]) -> [String] {
    items.map { spec in
        switch spec {
        case .header(let title): return "## \(title)"
        case .status(let title): return "status: \(title)"
        case .separator: return "---"
        case .item(let item): return line(item)
        }
    }
}

private func line(_ item: MenuItem) -> String {
    var marks: [String] = []
    if let action = item.action { marks.append("→ \(name(action))") }
    if !item.enabled { marks.append("disabled") }
    if !item.key.isEmpty || item.modifiers != .command {
        let modifiers = (item.modifiers.contains(.command) ? "⌘" : "") + (item.modifiers.contains(.option) ? "⌥" : "")
        let keys = modifiers + item.key
        marks.append("keys: " + (keys.isEmpty ? "none" : keys))
    }
    if item.isAlternate { marks.append("alternate") }
    if item.checked { marks.append("✓") }
    if let tip = item.toolTip { marks.append("tip: \(tip)") }
    if let submenu = item.submenu { marks.append("submenu: \(submenu)") }
    return ([item.title] + marks).joined(separator: " | ")
}

private func name(_ action: MenuAction) -> String {
    if case .chooseVM(let vm) = action { return "chooseVM(\(vm.name))" }
    return "\(action)"
}

private func state(vm: String? = "winlab01", running: Bool = false, readiness: RDP.Readiness? = nil,
                   activity: String? = nil, install: MenuInstall? = nil, console: Bool = true,
                   sharedFolder: Bool = false, update: MenuUpdate? = nil, launchAtLogin: Bool = false) -> MenuState {
    MenuState(status: MenuStatus(vmName: vm, running: running, readiness: readiness, activity: activity,
                                 install: install),
              consoleEnabled: console, hasSharedFolder: sharedFolder, update: update, launchAtLogin: launchAtLogin)
}

/// A `winbar create` job fourteen minutes into copying files, watched from this app's window.
private func installing(_ vm: String = "winlab01", stage: CreateStage = .copy, inTerminal: Bool = false,
                        resumed: Bool = false) -> MenuInstall {
    MenuInstall(vmName: vm, stage: stage, elapsed: 14 * 60 + 20, inTerminal: inTerminal, resumed: resumed)
}

private func menu(_ given: MenuState) -> [String] { lines(MenuShape.items(given)) }

/// The last six lines of every menu there is: the two switches, Quit, and the version, greyed, below
/// it. Start Windows with Winbar's hover names the VM the menu looks after, or none.
private func foot(_ vm: String? = "winlab01") -> [String] {
    ["---", "Launch at Login | → launchAtLogin | tip: \(LaunchAtLogin.Copy.menuHelp)",
     "Start Windows with Winbar | → startWindowsAtLaunch | tip: \(StartWindowsAtLaunch.Copy.menuHelp(vm: vm))",
     "Quit Winbar | → quit | keys: ⌘q",
     "---", "Winbar dev | disabled"]
}

/// Every situation, with Set Up Winbar… directly above Open UTM, as 0.2.0 ships the menu
/// (`SetupWindow.availableToEveryone`). These were written beside the lists the menu had while the
/// window was dark, which had the same items without that line and with the no-VM hint naming
/// Terminal; when the switch flipped those went, and these became the menu's goldens.
@Suite("The menu, pinned per situation, with Set Up Winbar… offered")
struct MenuShapeSetUpOfferedTests {
    private func offered(_ given: MenuState) -> [String] {
        var given = given
        given.offersSetUp = true
        return menu(given)
    }

    @Test("Running: whatever the probe said, only the status line changes")
    func runningWhateverTheProbeSaid() {
        let said: [(RDP.Readiness, String)] = [
            (.ready, "Running · ready for Remote Desktop"),
            (.notReady, "Running · Windows is still starting"),
            (.blocked, "Running · allow Local Network for Winbar to see readiness"),
        ]
        let unprobed = menu(state(running: true))
        for (readiness, text) in said {
            var expected = unprobed
            expected[1] = "status: \(text)"
            #expect(menu(state(running: true, readiness: readiness)) == expected, "\(readiness)")
        }
    }

    @Test("An install watched from Terminal, and one just picked up, say so on the status line")
    func installingStatusVariants() {
        let terminal = menu(state(install: installing(inTerminal: true)))
        #expect(terminal[1] == "status: Installing Windows: copying files (14 min) (in Terminal)")
        let resumed = menu(state(install: installing(resumed: true)))
        #expect(resumed[1] == "status: Picked up the install of “winlab01” where it left off.")
        // Nothing else differs from the ordinary install.
        let ordinary = menu(state(install: installing()))
        #expect(Array(terminal.dropFirst(2)) == Array(ordinary.dropFirst(2)))
        #expect(Array(resumed.dropFirst(2)) == Array(ordinary.dropFirst(2)))
    }

    @Test("Launch at Login is ticked when it is on, and nothing else changes")
    func launchAtLoginOn() {
        var expected = menu(state())
        expected[expected.count - 5] = "Launch at Login | → launchAtLogin | ✓ | tip: \(LaunchAtLogin.Copy.menuHelp)"
        #expect(menu(state(launchAtLogin: true)) == expected)
    }

    /// The setting's tick, and nothing else: it is a setting, so it is never greyed out, whatever runs.
    /// Control: build the item with `checked: false` and the first expectation fails.
    @Test("Start Windows with Winbar is ticked when it is on, and nothing else changes")
    func startWindowsOn() {
        var ticked = state()
        ticked.startsWindows = true
        var expected = menu(state())
        expected[expected.count - 4] = "Start Windows with Winbar | → startWindowsAtLaunch | ✓ | tip: "
            + StartWindowsAtLaunch.Copy.menuHelp(vm: "winlab01")
        #expect(menu(ticked) == expected)
        // Enabled while the VM is starting and while Set Up Winbar has it: ticking starts nothing now.
        var busy = state(activity: "Starting…")
        busy.setupBusy = true
        #expect(menu(busy).contains("Start Windows with Winbar | → startWindowsAtLaunch | tip: "
                                        + StartWindowsAtLaunch.Copy.menuHelp(vm: "winlab01")))
    }

    /// The live menu takes the bundle's version (`MenuState.version`'s default); a build names itself.
    @Test("The last line is the version, greyed out")
    func versionLine() {
        var given = state()
        given.version = "0.3.0"
        #expect(Array(menu(given).suffix(2)) == ["---", "Winbar 0.3.0 | disabled"])
        #expect(MenuState(status: MenuStatus()).version == AppBundle.version)
    }

    @Test("No VM chosen: Choose VM, the setup hint, and New Windows VM… once, beside them")
    func noVMChosen() {
        // 0.1.0 offered New Windows VM… a second time after Open UTM, with the items every state has.
        // The one beside Choose VM is the one kept: it is the other way to have a VM.
        #expect(offered(state(vm: nil)) == [
            "## Winbar",
            "status: No VM chosen",
            "---",
            "Choose VM | submenu: chooseVM",
            "Then choose Set Up Winbar… to tune it | disabled",
            "New Windows VM… | → newWindowsVM",
            "Set Up Winbar… | → setUpWinbar",
            "Open UTM | → openUTM",
            "Report a Problem… | → reportProblem",
            "Send a Problem Report… | → sendReport",
        ] + foot(nil))
    }

    @Test("No VM chosen and a report being written: only Report a Problem… waits")
    func noVMChosenBusy() {
        // Choose VM and New Windows VM… don't depend on Winbar being idle; they never have.
        #expect(offered(state(vm: nil, activity: "Writing a diagnostic report…")) == [
            "## Winbar",
            "status: Writing a diagnostic report…",
            "---",
            "Choose VM | submenu: chooseVM",
            "Then choose Set Up Winbar… to tune it | disabled",
            "New Windows VM… | → newWindowsVM",
            "Set Up Winbar… | → setUpWinbar",
            "Open UTM | → openUTM",
            "Report a Problem… | → reportProblem | disabled",
            "Send a Problem Report… | → sendReport",
        ] + foot(nil))
    }

    @Test("Stopped, with a console window and no shared folder")
    func stopped() {
        #expect(offered(state()) == [
            "## winlab01",
            "status: Stopped",
            "---",
            "Start and Connect | → connect",
            "---",
            "Start | → start",
            "---",
            "Run in the Background… | → toggleConsole",
            "Share a Folder… | → sharedFolder",
            "Set Up Winbar… | → setUpWinbar",
            "Open UTM | → openUTM",
            "New Windows VM… | → newWindowsVM",
            "Report a Problem… | → reportProblem",
            "Send a Problem Report… | → sendReport",
        ] + foot())
    }

    @Test("Stopped and headless, sharing a folder: the display and folder items offer the other thing")
    func stoppedHeadlessSharing() {
        #expect(offered(state(console: false, sharedFolder: true)) == [
            "## winlab01",
            "status: Stopped",
            "---",
            "Start and Connect | → connect",
            "---",
            "Start | → start",
            "---",
            "Bring Back Windows' Screen… | → toggleConsole",
            "Open Shared Folder | → sharedFolder",
            "Set Up Winbar… | → setUpWinbar",
            "Open UTM | → openUTM",
            "New Windows VM… | → newWindowsVM",
            "Report a Problem… | → reportProblem",
            "Send a Problem Report… | → sendReport",
        ] + foot())
    }

    @Test("Starting: everything that would fight the start is greyed out, and nothing moves")
    func starting() {
        #expect(offered(state(activity: "Starting…")) == [
            "## winlab01",
            "status: Starting…",
            "---",
            "Start and Connect | → connect | disabled",
            "---",
            "Start | → start | disabled",
            "---",
            "Run in the Background… | → toggleConsole | disabled",
            "Share a Folder… | → sharedFolder | disabled",
            "Set Up Winbar… | → setUpWinbar",
            "Open UTM | → openUTM",
            "New Windows VM… | → newWindowsVM",
            "Report a Problem… | → reportProblem | disabled",
            "Send a Problem Report… | → sendReport",
        ] + foot())
    }

    @Test("Running, before the first readiness probe has answered")
    func running() {
        #expect(offered(state(running: true)) == [
            "## winlab01",
            "status: Running",
            "---",
            "Connect | → connect",
            "---",
            "Shut Down | → shutDown | keys: none",
            "Force Stop | → forceStop | keys: ⌥ | alternate",
            "Restart | → restart",
            "---",
            "Run in the Background… | → toggleConsole",
            "Share a Folder… | → sharedFolder",
            "Set Up Winbar… | → setUpWinbar",
            "Open UTM | → openUTM",
            "New Windows VM… | → newWindowsVM",
            "Report a Problem… | → reportProblem",
            "Send a Problem Report… | → sendReport",
        ] + foot())
    }

    @Test("Running headless, sharing a folder")
    func runningHeadlessSharing() {
        #expect(offered(state(running: true, readiness: .ready, console: false, sharedFolder: true)) == [
            "## winlab01",
            "status: Running · ready for Remote Desktop",
            "---",
            "Connect | → connect",
            "---",
            "Shut Down | → shutDown | keys: none",
            "Force Stop | → forceStop | keys: ⌥ | alternate",
            "Restart | → restart",
            "---",
            "Bring Back Windows' Screen… | → toggleConsole",
            "Open Shared Folder | → sharedFolder",
            "Set Up Winbar… | → setUpWinbar",
            "Open UTM | → openUTM",
            "New Windows VM… | → newWindowsVM",
            "Report a Problem… | → reportProblem",
            "Send a Problem Report… | → sendReport",
        ] + foot())
    }

    @Test("Running and shutting down: the lifecycle items stay where they are, greyed out")
    func runningBusy() {
        #expect(offered(state(running: true, readiness: .ready, activity: "Shutting down…")) == [
            "## winlab01",
            "status: Shutting down…",
            "---",
            "Connect | → connect | disabled",
            "---",
            "Shut Down | → shutDown | disabled | keys: none",
            "Force Stop | → forceStop | disabled | keys: ⌥ | alternate",
            "Restart | → restart | disabled",
            "---",
            "Run in the Background… | → toggleConsole | disabled",
            "Share a Folder… | → sharedFolder | disabled",
            "Set Up Winbar… | → setUpWinbar",
            "Open UTM | → openUTM",
            "New Windows VM… | → newWindowsVM",
            "Report a Problem… | → reportProblem | disabled",
            "Send a Problem Report… | → sendReport",
        ] + foot())
    }

    @Test("Installing into the VM the menu looks after: no lifecycle items, and no second install")
    func installingPrimary() {
        let expected = [
            "## winlab01",
            "status: Installing Windows: copying files (14 min)",
            "---",
            "Show Install Progress… | → showInstallProgress",
            "---",
            "Set Up Winbar… | → setUpWinbar",
            "Open UTM | → openUTM",
            "New Windows VM… | → newWindowsVM | disabled",
            "Report a Problem… | → reportProblem",
            "Send a Problem Report… | → sendReport",
        ] + foot()
        #expect(offered(state(install: installing())) == expected)
        // The VM exists in UTM by now, so it may well be running; the install still owns it.
        #expect(offered(state(running: true, readiness: .ready, install: installing())) == expected)
    }

    @Test("Installing with no VM chosen yet: the install's VM names the menu, and there's no Choose VM")
    func installingNoVMChosen() {
        #expect(offered(state(vm: nil, install: installing())) == [
            "## winlab01",
            "status: Installing Windows: copying files (14 min)",
            "---",
            "Show Install Progress… | → showInstallProgress",
            "---",
            "Set Up Winbar… | → setUpWinbar",
            "Open UTM | → openUTM",
            "New Windows VM… | → newWindowsVM | disabled",
            "Report a Problem… | → reportProblem",
            "Send a Problem Report… | → sendReport",
        ] + foot(nil))
    }

    @Test("Installing while a report is written: the report's label wins the status line")
    func installingBusy() {
        #expect(offered(state(activity: "Writing a diagnostic report…", install: installing())) == [
            "## winlab01",
            "status: Writing a diagnostic report…",
            "---",
            "Show Install Progress… | → showInstallProgress",
            "---",
            "Set Up Winbar… | → setUpWinbar",
            "Open UTM | → openUTM",
            "New Windows VM… | → newWindowsVM | disabled",
            "Report a Problem… | → reportProblem | disabled",
            "Send a Problem Report… | → sendReport",
        ] + foot())
    }

    @Test("Installing another VM: this VM keeps all its items and gains one line")
    func installingOther() {
        #expect(offered(state(running: true, readiness: .ready, install: installing("atelier", inTerminal: true))) == [
            "## winlab01",
            "status: Running · ready for Remote Desktop",
            "Installing Windows in “atelier”: copying files (14 min) (in Terminal) | disabled",
            "---",
            "Show Install Progress… | → showInstallProgress",
            "---",
            "Connect | → connect",
            "---",
            "Shut Down | → shutDown | keys: none",
            "Force Stop | → forceStop | keys: ⌥ | alternate",
            "Restart | → restart",
            "---",
            "Run in the Background… | → toggleConsole",
            "Share a Folder… | → sharedFolder",
            "Set Up Winbar… | → setUpWinbar",
            "Open UTM | → openUTM",
            "New Windows VM… | → newWindowsVM | disabled",
            "Report a Problem… | → reportProblem",
            "Send a Problem Report… | → sendReport",
        ] + foot())
    }

    @Test("An update adds one item behind its own separator, in the words for how Winbar got here")
    func updateAvailable() {
        let top = [
            "## winlab01",
            "status: Stopped",
            "---",
            "Start and Connect | → connect",
            "---",
            "Start | → start",
            "---",
            "Run in the Background… | → toggleConsole",
            "Share a Folder… | → sharedFolder",
            "Set Up Winbar… | → setUpWinbar",
            "Open UTM | → openUTM",
            "New Windows VM… | → newWindowsVM",
            "Report a Problem… | → reportProblem",
            "Send a Problem Report… | → sendReport",
        ]
        #expect(offered(state(update: MenuUpdate(version: "0.2.0", homebrew: false))) == top + [
            "---",
            "Winbar 0.2.0 is available… | → showUpdate",
        ] + foot())
        #expect(offered(state(update: MenuUpdate(version: "0.2.0", homebrew: true))) == top + [
            "---",
            "Winbar 0.2.0 is available: copy “brew upgrade” | → showUpdate",
        ] + foot())
        // And it is offered whatever else is going on, since reading about a release fights nothing.
        #expect(Array(offered(state(vm: nil, activity: "Writing a diagnostic report…",
                                 update: MenuUpdate(version: "0.2.0", homebrew: false))).suffix(10)) == [
            "Report a Problem… | → reportProblem | disabled",
            "Send a Problem Report… | → sendReport",
            "---",
            "Winbar 0.2.0 is available… | → showUpdate",
        ] + foot(nil))
    }
}

@Suite("The menu, in every situation at once")
struct MenuShapeInvariantTests {
    /// Every combination of what the menu is built from, with the set-up window offered and not:
    /// 4,096 menus.
    static let every: [MenuState] = {
        var all: [MenuState] = []
        let installs: [MenuInstall?] = [nil, installing(), installing(resumed: true), installing("atelier")]
        let readinesses: [RDP.Readiness?] = [nil, .ready, .notReady, .blocked]
        for vm in [nil, "winlab01"] as [String?] {
            for running in [false, true] {
                for readiness in readinesses {
                    for activity in [nil, "Starting…"] as [String?] {
                        for install in installs {
                            for console in [false, true] {
                                for sharedFolder in [false, true] {
                                    for update in [nil, MenuUpdate(version: "0.2.0", homebrew: false)] {
                                        for launchAtLogin in [false, true] {
                                            for offersSetUp in [false, true] {
                                                var given = state(vm: vm, running: running, readiness: readiness,
                                                                  activity: activity, install: install,
                                                                  console: console, sharedFolder: sharedFolder,
                                                                  update: update, launchAtLogin: launchAtLogin)
                                                given.offersSetUp = offersSetUp
                                                // Both ticks both ways, without doubling the menus:
                                                // across offersSetUp, every pair of the two switches.
                                                given.startsWindows = launchAtLogin != offersSetUp
                                                all.append(given)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        return all
    }()

    @Test("The header, then the status line, and only one of each: one status line for render() to retitle")
    func headerThenStatus() {
        // render() retitles the one item `NSMenu.fill` handed back, not whatever is second in the menu,
        // so a second status line would sit there with stale words.
        for given in Self.every {
            let items = MenuShape.items(given)
            #expect(items.first == .header(MenuShape.title(given.status)))
            #expect(items.dropFirst().first == .status(MenuShape.statusText(given.status)))
            #expect(items.filter { if case .header = $0 { true } else { false } }.count == 1)
            #expect(items.filter { if case .status = $0 { true } else { false } }.count == 1)
        }
    }

    @Test("Never two separators together, and never one at either end")
    func separators() {
        for given in Self.every {
            let items = MenuShape.items(given)
            #expect(items.first != .separator && items.last != .separator)
            #expect(!zip(items, items.dropFirst()).contains { $0 == .separator && $1 == .separator }, "\(given)")
        }
    }

    @Test("Open UTM, Report a Problem…, both switches, ⌘Q and the version are in every menu")
    func alwaysThere() {
        for given in Self.every {
            let items = MenuShape.items(given)
            #expect(items.last == .note("Winbar dev"))
            #expect(items.dropLast().last == .separator)
            #expect(items.dropLast(2).last == .item(MenuItem(title: "Quit Winbar", action: .quit, key: "q")))
            #expect(items.dropLast(3).last == .item(MenuItem(title: "Start Windows with Winbar",
                                                             action: .startWindowsAtLaunch,
                                                             checked: given.startsWindows,
                                                             toolTip: StartWindowsAtLaunch.Copy.menuHelp(
                                                                vm: given.status.vmName))))
            #expect(items.dropLast(4).last == .item(MenuItem(title: "Launch at Login", action: .launchAtLogin,
                                                             checked: given.launchAtLogin,
                                                             toolTip: LaunchAtLogin.Copy.menuHelp)))
            #expect(items.contains(.action("Open UTM", .openUTM)))
            // Enabled whenever Winbar is idle, install or no install: a report is wanted exactly where
            // the rest of the menu has nothing to offer.
            #expect(items.contains(.action(Diagnose.Copy.menuItem, .reportProblem, enabled: given.status.idle)))
        }
    }

    /// Where Set Up Winbar… is in `items`, by index.
    private static func setUpItems(_ items: [MenuItemSpec]) -> [Int] {
        items.indices.filter { if case .item(let item) = items[$0] { item.action == .setUpWinbar } else { false } }
    }

    /// Spec §2.1: "always there, above Open UTM", once the window is offered. Checked in every menu
    /// there is, not only the pinned ones, and with nothing between the two.
    @Test("Offered, Set Up Winbar… is in every menu, once, enabled, directly above Open UTM")
    func setUpWinbarAboveOpenUTM() {
        for given in Self.every where given.offersSetUp {
            let items = MenuShape.items(given)
            let setUp = Self.setUpItems(items)
            #expect(setUp.count == 1, "\(given)")
            guard let index = setUp.first else { continue }
            #expect(items[index] == .action("Set Up Winbar…", .setUpWinbar))
            #expect(items.indices.contains(index + 1) && items[index + 1] == .action("Open UTM", .openUTM), "\(given)")
        }
    }

    /// Not offered, it is in no menu at all, and the menu is the offered one with that line taken out —
    /// and, with no VM chosen, with the hint under Choose VM naming Terminal's `winbar setup` rather
    /// than the window, since the menu then has no window to name.
    @Test("Not offered, Set Up Winbar… is in no menu, and only the no-VM hint changes")
    func setUpWinbarNotOffered() {
        let terminalHint = MenuItemSpec.note("Then run “winbar setup” in Terminal to tune it")
        let windowHint = MenuItemSpec.note("Then choose Set Up Winbar… to tune it")
        for given in Self.every where !given.offersSetUp {
            let items = MenuShape.items(given)
            #expect(Self.setUpItems(items).isEmpty, "\(given)")
            #expect(!items.contains(windowHint), "\(given)")
            var offered = given
            offered.offersSetUp = true
            let withIt = MenuShape.items(offered)
            #expect(!withIt.contains(terminalHint), "\(given)")
            let withoutItem = Self.setUpItems(withIt).map { index in withIt.enumerated().filter { $0.offset != index }.map(\.element) }
            #expect(withoutItem.map { $0.map { $0 == windowHint ? terminalHint : $0 } } == [items], "\(given)")
        }
    }

    /// 0.2.0's menu: the window is offered to everyone. Whether a Mac that put the welcome away still
    /// is, is `SetupWindowTests.dismissedBefore`, through `MenuState.offersSetUp`, which the live menu
    /// is built with. Turning the switch back off fails this.
    @Test("In this build, every menu has Set Up Winbar…, and the no-VM hint names it")
    func setUpWinbarOnInThisBuild() {
        #expect(SetupWindow.availableToEveryone)
        #expect(MenuState(status: MenuStatus()).offersSetUp)
        for given in [state(), state(vm: nil), state(running: true), state(install: installing())] {
            #expect(Self.setUpItems(MenuShape.items(given)).count == 1, "\(given)")
        }
        #expect(MenuShape.items(state(vm: nil)).contains(.note("Then choose Set Up Winbar… to tune it")))
    }

    @Test("New Windows VM… is in every menu, and only once")
    func newWindowsVMOnce() {
        // 0.1.0 had it twice with no VM chosen, so this is checked everywhere rather than in one list.
        for given in Self.every {
            let offered = MenuShape.items(given).filter {
                if case .item(let item) = $0 { item.action == .newWindowsVM } else { false }
            }
            #expect(offered.count == 1, "\(given)")
        }
    }

    @Test("Nothing that is offered does nothing: an enabled item has an action or opens a submenu")
    func noDeadItems() {
        for given in Self.every {
            for case .item(let item) in MenuShape.items(given) where item.enabled {
                #expect(item.action != nil || item.submenu != nil, "\(item.title)")
            }
        }
    }
}

@Suite("The Choose VM submenu")
struct MenuShapeChooserTests {
    private let listingFailed = WinbarError("UTM didn't answer", "Nothing came back within 30 seconds.")

    @Test("UTM not installed: one line saying so, and nothing asked")
    func utmMissing() {
        #expect(lines(MenuShape.chooser(utmInstalled: false, vms: nil, error: nil)) == [
            "UTM isn't installed | disabled",
        ])
        // Whatever was seen before doesn't matter: there is no UTM to have listed it.
        #expect(lines(MenuShape.chooser(utmInstalled: false, vms: [VMInfo(name: "winlab01", backend: "qemu")],
                                        error: listingFailed)) == ["UTM isn't installed | disabled"])
    }

    @Test("Before UTM has answered")
    func asking() {
        #expect(lines(MenuShape.chooser(utmInstalled: true, vms: nil, error: nil)) == ["Asking UTM… | disabled"])
    }

    @Test("A listing that failed says why, with UTM's detail as the tooltip")
    func failed() {
        #expect(lines(MenuShape.chooser(utmInstalled: true, vms: nil, error: listingFailed)) == [
            "Couldn't ask UTM: UTM didn't answer | disabled | tip: Nothing came back within 30 seconds.",
        ])
    }

    @Test("Automation refused adds the way to the setting")
    func automationDenied() {
        let denied = WinbarError("Winbar isn't allowed to control UTM", "Allow it in System Settings.",
                                 automationDenied: true)
        #expect(lines(MenuShape.chooser(utmInstalled: true, vms: nil, error: denied)) == [
            "Couldn't ask UTM: Winbar isn't allowed to control UTM | disabled | tip: Allow it in System Settings.",
            "Open Automation Settings… | → openAutomationSettings",
        ])
    }

    @Test("QEMU VMs only, Windows ones first, then by name, each carrying the VM as UTM listed it")
    func listed() {
        let listed = [
            VMInfo(id: "5A1E0C3D-0000-4000-8000-00000000000A", name: "rosa", backend: "qemu", icon: "linux"),
            VMInfo(id: "5A1E0C3D-0000-4000-8000-00000000000B", name: "winlab02", backend: "qemu", icon: "windows"),
            VMInfo(id: "5A1E0C3D-0000-4000-8000-00000000000C", name: "atelier", backend: "apple", icon: "macos"),
            VMInfo(id: "5A1E0C3D-0000-4000-8000-00000000000D", name: "winlab01", backend: "qemu", icon: "Windows"),
        ]
        let items = MenuShape.chooser(utmInstalled: true, vms: listed, error: nil)
        #expect(lines(items) == [
            "winlab01 | → chooseVM(winlab01)",
            "winlab02 | → chooseVM(winlab02)",
            "rosa | → chooseVM(rosa)",
        ])
        // The whole VM, id and all: settings are filed under the id.
        #expect(items.first == .action("winlab01", .chooseVM(listed[3])))
    }

    @Test("No QEMU VMs says so, rather than an empty submenu")
    func noneOffered() {
        #expect(lines(MenuShape.chooser(utmInstalled: true, vms: [], error: nil)) == ["UTM has no QEMU VMs | disabled"])
        #expect(lines(MenuShape.chooser(utmInstalled: true, vms: [VMInfo(name: "atelier", backend: "apple")],
                                        error: nil)) == ["UTM has no QEMU VMs | disabled"])
    }

    @Test("The last list stays up when a fresh listing fails")
    func staleListWins() {
        #expect(lines(MenuShape.chooser(utmInstalled: true, vms: [VMInfo(name: "winlab01", backend: "qemu")],
                                        error: listingFailed)) == ["winlab01 | → chooseVM(winlab01)"])
    }
}

@Suite("The status line, the header and the probe")
struct MenuShapeStatusTests {
    private func status(vm: String? = "winlab01", running: Bool = false, readiness: RDP.Readiness? = nil,
                        activity: String? = nil, install: MenuInstall? = nil) -> MenuStatus {
        MenuStatus(vmName: vm, running: running, readiness: readiness, activity: activity, install: install)
    }

    @Test("Whatever Winbar is doing wins, then the install, then the VM")
    func precedence() {
        #expect(MenuShape.statusText(status(running: true, readiness: .ready, activity: "Restarting…",
                                            install: installing())) == "Restarting…")
        #expect(MenuShape.statusText(status(running: true, readiness: .ready, install: installing()))
                == "Installing Windows: copying files (14 min)")
        #expect(MenuShape.statusText(status(vm: nil)) == "No VM chosen")
        // No VM chosen says so even if something is running: without a name there is nothing to find.
        #expect(MenuShape.statusText(status(vm: nil, running: true, readiness: .ready)) == "No VM chosen")
        #expect(MenuShape.statusText(status(readiness: .ready)) == "Stopped")
    }

    @Test("Another VM's install leaves this VM's status line alone, even just after it was picked up")
    func otherInstallStatus() {
        #expect(MenuShape.statusText(status(install: installing("atelier", resumed: true))) == "Stopped")
    }

    @Test("The install summary: the stage, the minutes, and where it is watched from")
    func installSummary() {
        #expect(MenuShape.installSummary(installing()) == "copying files (14 min)")
        #expect(MenuShape.installSummary(installing(stage: .finish, inTerminal: true))
                == "finishing (14 min) (in Terminal)")
        let fresh = MenuInstall(vmName: "winlab01", stage: .check, elapsed: 12, inTerminal: false, resumed: false)
        #expect(MenuShape.installSummary(fresh) == "checking the ISO and UTM (less than a minute)")
    }

    @Test("The header: the VM, else the VM being installed into, else Winbar")
    func title() {
        #expect(MenuShape.title(status()) == "winlab01")
        #expect(MenuShape.title(status(install: installing("atelier"))) == "winlab01")
        #expect(MenuShape.title(status(vm: nil, install: installing("atelier"))) == "atelier")
        #expect(MenuShape.title(status(vm: nil)) == "Winbar")
    }

    @Test("An install is the menu's own when it's for the menu's VM, or when no VM is chosen")
    func whoseInstall() {
        #expect(status(install: installing()).primaryInstall == installing())
        #expect(status(install: installing()).otherInstall == nil)
        #expect(status(vm: nil, install: installing("atelier")).primaryInstall == installing("atelier"))
        #expect(status(install: installing("atelier")).primaryInstall == nil)
        #expect(status(install: installing("atelier")).otherInstall == installing("atelier"))
        #expect(status().primaryInstall == nil && status().otherInstall == nil)
    }

    @Test("Opening the menu probes RDP only for a running VM that nothing else is changing")
    func probe() {
        #expect(MenuShape.probesReadiness(status(running: true)))
        #expect(MenuShape.probesReadiness(status(running: true, readiness: .ready)))
        #expect(!MenuShape.probesReadiness(status()))
        #expect(!MenuShape.probesReadiness(status(running: true, activity: "Shutting down…")))
        #expect(!MenuShape.probesReadiness(status(running: true, install: installing())))
        // Another VM's install doesn't stop this VM being asked.
        #expect(MenuShape.probesReadiness(status(running: true, install: installing("atelier"))))
    }
}
