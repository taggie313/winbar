import AppKit
import ServiceManagement
import SwiftUI

/// Launch at Login, for the menu's checkbox and for Set Up Winbar's finished screen.
///
/// Why the finished screen offers it, switched on: the menu bar icon is the only way a person who
/// never opens Terminal knows to reach Windows, and it was off unless they found the menu's checkbox.
/// After the next restart the icon was gone, and they concluded Winbar or Windows had broken. So a
/// fresh setup ends with the toggle on, in plain view, one click from off.
enum LaunchAtLogin {
    /// What the login-items service can be asked. `SMAppService.mainApp` in the app; a fake in tests,
    /// and an inert one anywhere else, so drawing the finished screen in a test can never register
    /// the test runner as a login item.
    protocol Service {
        var status: SMAppService.Status { get }
        func register() throws
        func unregister() throws
    }

    /// Where the "has anyone decided?" answer lives. Global: it is this Mac's, not a VM's.
    struct Environment {
        var service: Service
        var place: AppLocation.Place
        var decided: () -> Bool
        var markDecided: () -> Void
    }

    /// The real thing only inside Winbar.app; under `swift test` nothing is registered and nothing is
    /// written to the settings, which the CLI and the tests share with the app.
    @MainActor static var live: Environment {
        guard AppPresence.isTheApp else {
            return Environment(service: Inert(), place: .elsewhere, decided: { true }, markDecided: {})
        }
        return Environment(service: SMAppService.mainApp, place: AppLocation.current,
                           decided: { Config.launchAtLoginDecided }, markDecided: { Config.launchAtLoginDecided = true })
    }

    /// Whether the finished screen turns it on by itself: nobody has decided either way (the menu's
    /// checkbox, this toggle), it isn't on already, and this copy isn't one that goes away. Pure.
    static func turnsOnByDefault(status: SMAppService.Status, decided: Bool, place: AppLocation.Place) -> Bool {
        !decided && status == .notRegistered && !AppLocation.isTemporary(place)
    }

    /// What the finished screen does as it appears, and what it then shows. A fresh setup from a copy
    /// that stays turns Launch at Login on, and that counts as the decision, so the screen appearing
    /// again never turns it back on after someone switched it off in the menu. Anyone else is only
    /// read. Out of the view so a test can hand it a fake service and see what was registered.
    static func initialOutcome(_ environment: Environment) -> Outcome {
        let status = environment.service.status
        guard turnsOnByDefault(status: status, decided: environment.decided(), place: environment.place) else {
            return outcome(status)
        }
        environment.markDecided()
        return set(true, service: environment.service, place: environment.place)
    }

    enum Outcome: Equatable {
        case on, off
        /// Registered, but macOS wants it allowed in System Settings first.
        case needsApproval
        /// From a disk image, a translocated copy or Downloads: nothing was registered (`AppLocation`).
        case refused(String)
        case failed(String)
    }

    /// Turns it on or off. Never registers a copy that will go away: a login item pointing at an
    /// ejected disk image opens nothing at the next login.
    static func set(_ on: Bool, service: Service, place: AppLocation.Place) -> Outcome {
        if on, let refusal = AppLocation.loginItemRefusal(place) { return .refused(refusal) }
        do {
            if on { try service.register() } else { try service.unregister() }
        } catch {
            return .failed(error.localizedDescription)
        }
        return outcome(service.status)
    }

    static func outcome(_ status: SMAppService.Status) -> Outcome {
        switch status {
        case .enabled: return .on
        case .requiresApproval: return .needsApproval
        default: return .off
        }
    }

    enum Copy {
        static let toggle = "Open Winbar when I log in"
        /// Under the switch, in view rather than in its hover. Live, the owner read "Open Winbar when I
        /// log in" on the finished page and couldn't tell whether that meant Windows would start at
        /// every login, holding its memory from then on, or only the icon he'd just been using. It is
        /// only the icon: logging in starts nothing in UTM, unless the switch under this one
        /// (`StartWindowsAtLaunch`) says to.
        static let toggleDetail = "Opens only Winbar's icon in the menu bar. Unless the switch below is on, Windows "
            + "stays off until you connect to it or start it from Winbar's menu."
        static let toggleHelp = "Keeps Winbar's icon in the menu bar after a restart. The menu's Launch at Login is "
            + "the same switch."
        /// The menu's **Launch at Login**, on hover: the same answer as `toggleDetail`, so the two
        /// switches that are one switch never describe it differently.
        static let menuHelp = "Opens Winbar's icon in the menu bar when you log in. Unless "
            + "\(StartWindowsAtLaunch.Copy.menuItem) is ticked too, Windows stays off until you connect to it or start it."
        /// Said before System Settings opens, so the person knows which switch they're looking for.
        static let approvalTitle = "Allow Winbar to open at login"
        static let approval = "macOS wants you to allow it once: in System Settings › General › Login Items & "
            + "Extensions, turn on Winbar."
        static let bOpenSettings = "Open Login Items Settings"
        static let failedTitle = "Couldn't change Launch at Login"
    }

    /// Nothing registered, nothing changed. See `live`.
    struct Inert: Service {
        var status: SMAppService.Status { .notRegistered }
        func register() throws {}
        func unregister() throws {}
    }
}

extension SMAppService: LaunchAtLogin.Service {}

/// The finished screen's one switch. Kept here rather than in the finished view, so that view gains a
/// single line and its restyling can move it without touching what it does.
struct LaunchAtLoginToggle: View {
    var environment: LaunchAtLogin.Environment
    @State private var on = false
    @State private var note: String?
    @State private var needsApproval = false

    @MainActor init(environment: LaunchAtLogin.Environment? = nil) {
        self.environment = environment ?? LaunchAtLogin.live
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(LaunchAtLogin.Copy.toggle, isOn: Binding(get: { on }, set: { change(to: $0) }))
                .help(LaunchAtLogin.Copy.toggleHelp)
            SwitchDetail(LaunchAtLogin.Copy.toggleDetail)
            if let note {
                Text(note).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            if needsApproval {
                Button(LaunchAtLogin.Copy.bOpenSettings) { SMAppService.openSystemSettingsLoginItems() }
            }
        }
        .onAppear(perform: appear)
    }

    private func appear() {
        show(LaunchAtLogin.initialOutcome(environment))
    }

    private func change(to wanted: Bool) {
        environment.markDecided()
        show(LaunchAtLogin.set(wanted, service: environment.service, place: environment.place))
    }

    private func show(_ outcome: LaunchAtLogin.Outcome) {
        on = outcome == .on || outcome == .needsApproval
        needsApproval = outcome == .needsApproval
        switch outcome {
        case .on, .off: note = nil
        case .needsApproval: note = LaunchAtLogin.Copy.approval
        case .refused(let why), .failed(let why): note = why
        }
    }
}

/// The line under one of the finished screen's switches that says what it does: in the window's
/// quieter small text, lined up with the switch's title rather than its box, as System Settings
/// captions a checkbox, and wrapped at a width that reads as a sentence.
struct SwitchDetail: View {
    let text: String
    /// A macOS checkbox and the gap after it, so the line starts under the title's first letter.
    static let indent: CGFloat = 20
    static let width: CGFloat = 380

    init(_ text: String) { self.text = text }

    var body: some View {
        withSetupAppearance { look in
            Text(verbatim: text)
                .font(.system(size: SetupStyle.smallestText))
                .foregroundStyle(look.mutedText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: Self.width, alignment: .leading)
                .padding(.leading, Self.indent)
        }
    }
}
