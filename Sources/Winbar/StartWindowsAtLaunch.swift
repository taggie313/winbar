import SwiftUI

/// Also start Windows when Winbar opens: the finished screen's second switch, and the menu's **Start
/// Windows with Winbar**. Off unless the person turns it on.
///
/// Why it exists: Launch at Login opens only Winbar's icon (live, the owner asked which it was), so
/// someone who wants Windows waiting after they log in had to choose Start or Connect every time. Why
/// it is off, and never switched on by Winbar itself: a running Windows holds its share of the Mac's
/// memory, gigabytes of it, from the moment it starts until it is shut down. That is the person's
/// trade to make, so it is offered with the cost said beside it, and nothing turns it on but their
/// press — not the finished screen appearing, as Launch at Login does.
///
/// Global, not the VM's. Winbar looks after one chosen VM at a time, and this starts whichever that is,
/// as the menu's Start does. Filed under the VM, choosing another VM in the menu would quietly lose the
/// switch and change the menu's tick with nothing said. The finished screen and the menu's hover name
/// the VM it will start.
enum StartWindowsAtLaunch {
    /// Whether it is on. Unset is off. Pure over the store, so a test can hand it one of its own.
    static func isOn(in store: SettingsStore) -> Bool {
        store.object(forKey: Config.Key.startWindowsAtLaunch) as? Bool ?? false
    }

    /// Written as yes or removed, never no, like Winbar's other yes-only settings, so `defaults read`
    /// shows it only when it says something.
    static func set(_ on: Bool, in store: SettingsStore) {
        if on { store.set(true, forKey: Config.Key.startWindowsAtLaunch) } else {
            store.removeObject(forKey: Config.Key.startWindowsAtLaunch)
        }
    }

    /// The switch as the finished screen and the menu reach it.
    struct Environment {
        var isOn: () -> Bool
        var set: (Bool) -> Void
    }

    /// The real setting only inside Winbar.app. Under `swift test` it reads off and writes nothing:
    /// the settings are the ones the CLI and the app share, and a test drawing the finished screen
    /// must never leave this Mac starting a VM at its owner's next login.
    @MainActor static var live: Environment {
        guard AppPresence.isTheApp else { return Environment(isOn: { false }, set: { _ in }) }
        return Environment(isOn: { isOn(in: Config.defaults) }, set: { set($0, in: Config.defaults) })
    }

    /// What Winbar knows as it opens, for `starts`.
    struct Launch: Equatable {
        /// The switch.
        var on: Bool
        /// The VM Winbar looks after (`Config.vmName`); nil before one is chosen.
        var vm: String?
        /// That VM's process is already there: started from UTM, or by the Winbar that quit.
        var running: Bool
        /// A `winbar create` job hasn't finished: its install needs the Mac's memory and UTM's attention.
        var installing: Bool
        /// Some other work holds the app's gate (`AppWorkGate.isHeld`).
        var workHeld: Bool
        /// Set Up Winbar is open and working on the VM, choosing it or changing it
        /// (`SetupWindowController.coordinatesVM`): the VM is the window's until it's done.
        var setupBusy: Bool
    }

    /// Whether Winbar starts the VM as it opens: the switch is on, a VM is chosen and isn't running,
    /// and nothing else — an install, a set-up step, another operation — has the VM or the gate. Any
    /// of those, and it does nothing, quietly: the person didn't press anything, so a refusal would be
    /// an alert out of nowhere at login. Pure.
    static func starts(_ launch: Launch) -> Bool {
        launch.on && launch.vm != nil && !launch.running && !launch.installing && !launch.workHeld && !launch.setupBusy
    }

    enum Copy {
        /// Under **Open Winbar when I log in**, and in its words.
        static let toggle = "Also start Windows when Winbar opens"
        /// What it does and what it costs, naming the VM. With Launch at Login on, Winbar opens as the
        /// person logs in, so that is when Windows starts; without it, only when they open Winbar.
        ///
        /// Never "in the background": everywhere else in Winbar that means headless (**Run in the
        /// Background**), and this is the menu's Start, a plain `utmctl start`, so a VM that kept its
        /// screen opens UTM's window for it at login. "Without connecting" is how the menu's Start is
        /// described, and true either way.
        static func detail(vm: String) -> String {
            "Starts “\(vm)” each time Winbar opens, without connecting to it: with the switch above on, that's "
                + "when you log in. Windows then holds its share of your Mac's memory until you shut it down."
        }
        static let toggleHelp = "The menu's \(menuItem) is the same switch."
        /// The menu's tick, beside Launch at Login.
        static let menuItem = "Start Windows with Winbar"
        /// The menu item's hover: the finished screen's line, naming the VM the menu looks after.
        static func menuHelp(vm: String?) -> String {
            "Starts " + (vm.map { "“\($0)”" } ?? "the chosen VM") + " whenever Winbar opens, without connecting to "
                + "it, so at login too with Launch at Login on. Windows then holds its share of your Mac's memory "
                + "until you shut it down."
        }
    }
}

/// The finished screen's second switch, under **Open Winbar when I log in**. It only reads as it
/// appears: unlike Launch at Login, nothing turns this on but a press.
struct StartWindowsToggle: View {
    let vm: String
    var environment: StartWindowsAtLaunch.Environment
    @State private var on = false

    @MainActor init(vm: String, environment: StartWindowsAtLaunch.Environment? = nil) {
        self.vm = vm
        self.environment = environment ?? StartWindowsAtLaunch.live
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(StartWindowsAtLaunch.Copy.toggle, isOn: Binding(get: { on }, set: { wanted in
                environment.set(wanted)
                on = environment.isOn()
            }))
            .help(StartWindowsAtLaunch.Copy.toggleHelp)
            SwitchDetail(StartWindowsAtLaunch.Copy.detail(vm: vm))
        }
        .onAppear { on = environment.isOn() }
    }
}
