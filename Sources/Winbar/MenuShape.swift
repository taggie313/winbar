import Foundation

// The menu bar's menu, as a value.
//
// `AppDelegate.menuNeedsUpdate` used to build its NSMenuItems inline, straight from a dozen pieces of
// state, and nothing could test that. Three pieces of planned work each want to add something to it
// (the wizard's Set Up Winbar…, the Other VMs section, idle-sleep's status case), and each would have
// said "the rest of the menu is unchanged" with nothing to check it against. So the shape lives here,
// with no AppKit: the delegate gathers a `MenuState`, asks `MenuShape.items` what the menu is, and
// only turns the answer into NSMenuItems. "The menu didn't change" is then something MenuShapeTests
// says rather than something a commit message promises.
//
// Everything the menu is made of has a place in the value — the section header, the separators, key
// equivalents, modifier masks, the tick beside Launch at Login — and not only the titles. A list of
// titles would stay green while ⌘Q or the checkmark disappeared, and separators are exactly what
// moves when a section is added.

/// One line of the menu.
enum MenuItemSpec: Equatable {
    /// The small grey title at the top: the VM's name, or Winbar's before there is one.
    case header(String)
    /// The status line. It has its own case because it is the one item that changes while the menu
    /// is open — `render()` keeps its title current as a start or a readiness probe moves on — so the
    /// delegate has to be able to find it again once it is built.
    case status(String)
    case separator
    case item(MenuItem)

    /// An item that does something.
    static func action(_ title: String, _ action: MenuAction, enabled: Bool = true) -> MenuItemSpec {
        .item(MenuItem(title: title, action: action, enabled: enabled))
    }

    /// A line that only says something: greyed out, and nothing happens when it is chosen.
    static func note(_ title: String) -> MenuItemSpec {
        .item(MenuItem(title: title, enabled: false))
    }
}

/// Everything about one item that the menu sets, with AppKit's own defaults as the defaults here, so
/// an item that leaves a field alone here is built exactly as `NSMenuItem(title:action:keyEquivalent:)`
/// builds it.
struct MenuItem: Equatable {
    var title: String
    /// nil for a line with nothing to do, and for an item whose only job is its submenu.
    var action: MenuAction?
    var enabled = true
    var key = ""
    /// NSMenuItem's default is ⌘. Shut Down clears it so that Force Stop, the same key with ⌥, can be
    /// its alternate: macOS pairs an alternate with the item before it by key and mask.
    var modifiers: MenuModifiers = .command
    /// Shown in place of the item before it while its modifiers are held.
    var isAlternate = false
    /// The tick.
    var checked = false
    var toolTip: String?
    var submenu: MenuSubmenu?
}

/// The modifier mask, without AppKit's type. Only the two the menu uses.
struct MenuModifiers: OptionSet, Equatable {
    let rawValue: Int
    static let command = MenuModifiers(rawValue: 1 << 0)
    static let option = MenuModifiers(rawValue: 1 << 1)
}

/// The submenus an item can open. Not a list of items, because the only one there is can't be known
/// when the menu is built: its contents come from asking UTM, which launches UTM, so that waits until
/// the submenu itself is opened (see `MenuShape.chooser`).
enum MenuSubmenu: Equatable {
    case chooseVM
}

/// What choosing an item does. The delegate switches on this to pick the selector.
enum MenuAction: Equatable {
    case connect, start, shutDown, forceStop, restart
    case toggleConsole, sharedFolder
    case openUTM, newWindowsVM, showInstallProgress, setUpWinbar
    case reportProblem, showUpdate
    case launchAtLogin, quit
    /// One VM in the Choose VM submenu. The whole VM as UTM listed it, for its id: settings are filed
    /// under that, so a VM renamed in UTM keeps what Winbar knows about it.
    case chooseVM(VMInfo)
    case openAutomationSettings
}

/// The `winbar create` job, reduced to what the menu says about it.
struct MenuInstall: Equatable {
    var vmName: String
    var stage: CreateStage
    /// Seconds since the job started. Worked out by whoever gathers the state, so nothing in this file
    /// reads the clock.
    var elapsed: TimeInterval
    /// The CLI is the one watching the job, not this app's window.
    var inTerminal: Bool
    /// Within the minute after the app picked an abandoned job up, when the status line says so
    /// (N_RESUMED) instead of which stage it is on.
    var resumed: Bool
}

/// What the header and the status line are made of.
///
/// Kept apart from the rest of `MenuState` because the status line is redrawn far more often than the
/// menu is built — every five seconds, and every 0.6 while the icon blinks — and the rest of the state
/// costs a look at the shared folder on disk and a question to the login-items service, which only
/// opening the menu should pay for.
struct MenuStatus: Equatable {
    /// The VM Winbar looks after; nil until one has been chosen.
    var vmName: String?
    var running = false
    /// nil: not checked since the VM last changed state.
    var readiness: RDP.Readiness?
    /// The working label while a start, a stop or the like is in progress.
    var activity: String?
    /// The install job, whoever is running it.
    var install: MenuInstall?
    var setupNote: String? = nil

    /// Nothing of Winbar's own is in progress. An install doesn't count: it has its own rules.
    var idle: Bool { activity == nil }

    /// The install this menu speaks for: the one whose VM the menu already looks after, or any
    /// install when no VM has been chosen yet.
    var primaryInstall: MenuInstall? {
        guard let install else { return nil }
        return install.vmName == vmName || vmName == nil ? install : nil
    }

    /// An install of a different VM: the menu keeps its own items and gains one line.
    var otherInstall: MenuInstall? {
        guard let install, primaryInstall == nil else { return nil }
        return install
    }
}

/// Everything the menu is built from, gathered by `AppDelegate.menuNeedsUpdate` when the menu opens.
struct MenuState: Equatable {
    var status: MenuStatus
    /// Whether UTM shows the VM a window: the display item offers the other way round.
    var consoleEnabled = true
    /// The remembered shared folder is still a folder on disk. From settings, not from UTM: opening
    /// the menu must not send an Apple Event (and so launch UTM). The item's action checks with UTM
    /// before it changes anything.
    var hasSharedFolder = false
    /// A newer release, once `UpdateCheck` has found one.
    var update: MenuUpdate?
    var launchAtLogin = false
    /// Whether the menu offers **Set Up Winbar…**: `offersSetUp(available:coordinating:wizardShown:)`.
    /// Carried here rather than read inside `items`, so the tests can draw the menu both ways.
    var offersSetUp = SetupWindow.availableToEveryone
    /// The wizard owns VM selection and operations while open or working. The existing install
    /// owner remains separate: Show Install Progress still brings its one controller forward.
    var setupBusy = false

    /// The live menu's answer, which `AppDelegate.menuNeedsUpdate` takes from here: offered while
    /// the window is available to everyone (on since 0.2.0), or while a window opened some other way
    /// (`--window`) is coordinating the VM, so it can be brought back. `wizardShown`
    /// (`Config.setupWizardShown`) is passed in so the decision about it is made here, where a test
    /// holds it: a Mac that put the welcome away is only not greeted, and still finds the item.
    static func offersSetUp(available: Bool, coordinating: Bool, wizardShown: Bool) -> Bool {
        available || coordinating
    }
}

/// A newer release, and whether Homebrew put this copy here: only the item's words change with that.
struct MenuUpdate: Equatable {
    var version: String
    var homebrew: Bool
}

enum MenuShape {
    /// The header, and the first half of the icon's tooltip.
    static func title(_ status: MenuStatus) -> String {
        status.vmName ?? status.primaryInstall?.vmName ?? "Winbar"
    }

    /// The status line, and the second half of the tooltip. Whatever Winbar is doing wins, then the
    /// install, then the VM.
    static func statusText(_ status: MenuStatus) -> String {
        if let activity = status.activity { return activity }
        if let install = status.primaryInstall {
            if install.resumed { return CreateCopy.nResumed(name: install.vmName) }
            return "Installing Windows: " + installSummary(install)
        }
        if let note = status.setupNote { return note }
        guard status.vmName != nil else { return "No VM chosen" }
        guard status.running else { return "Stopped" }
        switch status.readiness {
        case .ready: return "Running · ready for Remote Desktop"
        case .notReady: return "Running · Windows is still starting"
        case .blocked: return "Running · allow Local Network for Winbar to see readiness"
        case .none: return "Running"
        }
    }

    /// "copying files (14 min)", with "(in Terminal)" when the CLI is the one watching.
    static func installSummary(_ install: MenuInstall) -> String {
        let terminal = install.inTerminal ? " (in Terminal)" : ""
        return "\(install.stage.shortTitle) (\(CreateElapsed.minutes(install.elapsed)))\(terminal)"
    }

    /// Whether opening the menu should ask the VM's RDP port if it is answering. The one network
    /// touch a menu open makes, so only when there is something to learn: the VM is running, nothing
    /// of Winbar's is in the middle of changing it, and no install owns it.
    static func probesReadiness(_ status: MenuStatus) -> Bool {
        status.running && status.idle && status.primaryInstall == nil
    }

    /// The menu, top to bottom.
    ///
    /// The order and grouping of the VM's own block — Connect, then the lifecycle items, then the
    /// display and shared-folder items — is the contract. The lists MenuShapeTests pins are expected
    /// to change when an item is added; what they are there to catch is an addition that moves
    /// something else.
    static func items(_ state: MenuState) -> [MenuItemSpec] {
        let status = state.status
        var items: [MenuItemSpec] = [.header(title(status)), .status(statusText(status))]
        // An install of some other VM doesn't change this menu's own items; it adds one line.
        if let other = status.otherInstall {
            items.append(.note("Installing Windows in “\(other.vmName)”: " + installSummary(other)))
        }
        items.append(.separator)
        if status.install != nil {
            items.append(.action(CreateCopy.menuProgress, .showInstallProgress))
            items.append(.separator)
        }

        let idle = status.idle
        // No VM, and no install making one: the menu's job is to get the person one.
        let noVM = status.vmName == nil && status.primaryInstall == nil
        if status.primaryInstall != nil {
            // Connect, Start, Shut Down, Restart and the display item would all fight the install.
        } else if noVM {
            // Listing VMs means asking UTM, which launches it, so that only happens once this submenu
            // is actually opened.
            items.append(.item(MenuItem(title: "Choose VM", submenu: .chooseVM)))
            // Where the tuning is, for someone who never opens Terminal: the window when the menu offers
            // it, and Terminal's `winbar setup` only when nothing here does.
            items.append(.note(state.offersSetUp ? "Then choose \(SetupCopy.menuItem) to tune it"
                                                 : "Then run “winbar setup” in Terminal to tune it"))
            // Beside Choose VM, as the other way to have a VM, and so not again below Open UTM:
            // 0.1.0 offered it in both places.
            items.append(.action(CreateCopy.menuNew, .newWindowsVM, enabled: status.install == nil))
        } else {
            items.append(.action(status.running ? "Connect" : "Start and Connect", .connect, enabled: idle))
            items.append(.separator)
            if status.running {
                items.append(.item(MenuItem(title: "Shut Down", action: .shutDown, enabled: idle, modifiers: [])))
                items.append(.item(MenuItem(title: "Force Stop", action: .forceStop, enabled: idle,
                                            modifiers: .option, isAlternate: true)))
                items.append(.action("Restart", .restart, enabled: idle))
            } else {
                items.append(.action("Start", .start, enabled: idle))
            }
            items.append(.separator)
            items.append(.action(state.consoleEnabled ? "Go Headless…" : "Show Console Window…", .toggleConsole,
                                 enabled: idle))
            items.append(.action(state.hasSharedFolder ? "Open Shared Folder" : "Share a Folder…", .sharedFolder,
                                 enabled: idle))
        }
        // The set-up window, in every state, directly above Open UTM: where the wizard spec (§2.1) and
        // COHERENCE C1 put it, inside the flat group after the VM's own block, so that block's order and
        // separators stay exactly as they were. Never greyed out: opening a window fights nothing, and
        // the window itself says what is in progress. Only while the window is offered to everyone
        // (`SetupWindow.availableToEveryone`): a menu item promises the whole setup.
        if state.offersSetUp {
            items.append(.action(SetupCopy.menuItem, .setUpWinbar))
        }
        items.append(.action("Open UTM", .openUTM))
        // One install at a time, so this is off while one runs. With no VM it is already above.
        if !noVM {
            items.append(.action(CreateCopy.menuNew, .newWindowsVM, enabled: status.install == nil))
        }
        // Every state reaches this line — no VM chosen, and the middle of an install too. A report is
        // wanted exactly where the rest of the menu has nothing to offer, and `winbar diagnose`
        // already leaves a running install's logs as it found them.
        items.append(.action(Diagnose.Copy.menuItem, .reportProblem, enabled: idle))
        // The only thing an update check is allowed to change about this menu, and only when there is
        // genuinely a newer release.
        if let update = state.update {
            items.append(.separator)
            items.append(.action(UpdateCheck.menuTitle(version: update.version, homebrew: update.homebrew),
                                 .showUpdate))
        }
        items.append(.separator)
        items.append(.item(MenuItem(title: "Launch at Login", action: .launchAtLogin, checked: state.launchAtLogin)))
        items.append(.item(MenuItem(title: "Quit Winbar", action: .quit, key: "q")))
        guard state.setupBusy else { return items }
        return items.map { spec in
            guard case .item(var item) = spec else { return spec }
            switch item.action {
            case .connect?, .start?, .shutDown?, .forceStop?, .restart?, .toggleConsole?,
                 .sharedFolder?, .newWindowsVM?, .chooseVM?, .showUpdate?: item.enabled = false
            default: break
            }
            if item.submenu == .chooseVM { item.enabled = false }
            return .item(item)
        }
    }

    /// The Choose VM submenu: QEMU VMs, Windows ones first, then by name.
    ///
    /// `vms` is the last list UTM gave, kept until a fresh one arrives, so a listing that fails after
    /// one has succeeded leaves the old list up rather than an error; `error` is said only while there
    /// has never been a list. `utmInstalled` false means there is nothing to ask, and osascript would
    /// only fail, so the listing isn't attempted and this says why.
    static func chooser(utmInstalled: Bool, vms: [VMInfo]?, error: WinbarError?) -> [MenuItemSpec] {
        guard utmInstalled else { return [.note("UTM isn't installed")] }
        guard let vms else {
            let title = error.map { "Couldn't ask UTM: \($0.title)" } ?? "Asking UTM…"
            var items: [MenuItemSpec] = [.item(MenuItem(title: title, enabled: false, toolTip: error?.detail))]
            if error?.automationDenied == true {
                items.append(.action("Open Automation Settings…", .openAutomationSettings))
            }
            return items
        }
        // One order for the menu and the set-up wizard's picker, by construction: both read
        // VMInfo.choosable rather than each carrying a copy of the sort that happens to agree.
        let offered = VMInfo.choosable(vms)
        guard !offered.isEmpty else { return [.note("UTM has no QEMU VMs")] }
        return offered.map { .action($0.name, .chooseVM($0)) }
    }
}
