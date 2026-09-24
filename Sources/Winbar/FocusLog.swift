import AppKit

/// A short memory of who had the keyboard: the times Winbar became or stopped being the active app,
/// another app came to the front, the Space changed, or Winbar moved between the Dock and the menu bar
/// (`AppPresence.update`) — each with what Winbar was in the middle of at that moment. Read into the
/// diagnostic report as its last section (`Diagnose.compose`), and nowhere else.
///
/// Why it exists: the first friend to run Set Up Winbar on a Mac of his own watched the keyboard jump,
/// again and again, to his browser on another Space while Winbar downloaded and installed UTM. Nothing
/// in the code explains it — no URL is opened, nothing hides the app, and the Dock presence only
/// changes as a window opens or closes — and he can't try it again. So the next report of it has to
/// say what happened: which app came forward, when, and what Winbar was doing just then.
///
/// What it keeps, and what it never does:
///
/// · **Memory only, and only so many:** the first `setUpCapacity` noted during set-up and the last
///   `capacity` of all. Nothing is written anywhere except by a report someone asked for, where it is
///   redacted with everything else.
///
/// · **Other apps by bundle identifier, and nothing else** — never a window title, a URL, a document
///   or a process's arguments. Which browser came forward is the fact worth having; what it was
///   showing is none of Winbar's business.
///
/// · **Only in Winbar.app itself** (`AppPresence.isTheApp`). The `winbar` CLI and `swift test`
///   observe nothing and keep nothing, and their reports say so rather than "none".
///
/// `@unchecked Sendable` because it is kept on the main thread and read from whichever one writes a
/// report: everything it keeps is behind `lock`, and `tokens` is only touched by `start` and `deinit`.
final class FocusLog: @unchecked Sendable {
    /// The app's. Started from main.swift, in the app and nowhere else.
    static let shared = FocusLog()

    /// How many of the newest are kept, of everything: enough to cover a minute of the keyboard
    /// bouncing between two apps, which is the pattern being looked for, as it stands when the report
    /// is made.
    static let capacity = 50

    /// How many of the first noted during set-up (`duringSetUp`) are kept, whatever comes after.
    ///
    /// Why: the log runs for as long as the menu bar app does and a bounce is five or six entries, so
    /// by the time anyone reports a jump during the install the newest `capacity` are Cmd-Tab and
    /// Space switching from long after it. Set-up carries on for a good while past the install —
    /// making the VM, waiting for Windows — and the report comes at the end, if at all. The first jump,
    /// and what Winbar did just before it, is the part worth having. The first, not the newest, for
    /// the same reason: switching later in set-up must not push the install out either. With the
    /// newest, 150 entries at most: tens of kilobytes in memory, and 300 lines or so in a report.
    static let setUpCapacity = 100

    /// Whether Winbar is in set-up: Set Up Winbar's window open, or its work in flight. The first
    /// entries noted then are the ones kept whatever follows (`setUpCapacity`). The open window counts
    /// as well as the work, so a report has what happened on the step before the install began, not
    /// only during it. Pure.
    static func duringSetUp(_ state: State) -> Bool { state.setupStep != nil || state.work != nil }

    // MARK: - What is kept

    /// What happened.
    enum Event: Equatable {
        case winbarBecameActive
        case winbarResignedActive
        /// An app became the frontmost one — Winbar included, which is how its own activations show up
        /// beside everyone else's. By bundle identifier only; nil for a process that has none.
        case appCameForward(bundleID: String?)
        case spaceChanged
        /// Winbar is about to move between the Dock and the menu bar. Kept before the change is made:
        /// going to the menu bar can hand the keyboard to another app at once, and the log should read
        /// cause, then effect. `why` is `FocusLog.why`; `activates` is whether it asks to be the
        /// active app straight after.
        case policyChanged(from: NSApplication.ActivationPolicy, to: NSApplication.ActivationPolicy,
                           why: String, activates: Bool)
    }

    /// What Winbar was doing when it happened.
    struct State: Equatable, Sendable {
        var policy: NSApplication.ActivationPolicy
        var active: Bool
        var hidden: Bool
        /// Set Up Winbar's step, while its window is open.
        var setupStep: WizardStep?
        /// Set Up Winbar's work in flight, by the name of its kind (`label`), window open or not:
        /// closing the window never stops the work, and the install is exactly the work in question.
        var work: String?
        /// Set Up Winbar's window, while it is open and can be found.
        var window: Window?

        struct Window: Equatable, Sendable {
            var visible: Bool
            var key: Bool
            var onActiveSpace: Bool
        }
    }

    struct Entry: Equatable {
        /// Its place among everything noted since the log opened, from 1. Where two side by side in a
        /// report aren't consecutive, the ones between weren't kept, and the report says how many.
        var number: Int
        var at: Date
        var event: Event
        var state: State
    }

    /// The newest `capacity` items, oldest first. Pure.
    struct Ring<Element> {
        let capacity: Int
        private(set) var items: [Element] = []

        init(capacity: Int) { self.capacity = max(1, capacity) }

        mutating func append(_ item: Element) {
            items.append(item)
            let over = items.count - capacity
            if over > 0 { items.removeFirst(over) }
        }
    }

    /// Everything a report prints, as a value.
    struct History: Equatable {
        /// When this process began keeping the log; nil in one that never does (the CLI, a test).
        var opened: Date?
        /// Oldest first and each once: the first ones kept during set-up, then the newest. What's
        /// missing shows in their `number`s.
        var entries: [Entry] = []
    }

    // MARK: - Keeping it

    private let lock = NSLock()
    /// The newest `capacity`, of everything.
    private var recent: Ring<Entry>
    /// The first `setUpCapacity` noted during set-up, which nothing after them can push out.
    private var setUp: [Entry] = []
    /// How many have been noted in all: the last one's `number`.
    private var noted = 0
    private var opened: Date?
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []
    private let clock: () -> Date
    private let state: () -> State

    /// The parameters are for tests, which hand in a clock and a state of their own and never reach
    /// the app's windows.
    init(capacity: Int = FocusLog.capacity, clock: @escaping () -> Date = Date.init,
         state: @escaping () -> State = FocusLog.liveState) {
        recent = Ring(capacity: capacity)
        self.clock = clock
        self.state = state
    }

    deinit {
        for (center, token) in tokens { center.removeObserver(token) }
    }

    /// Starts keeping the log: in Winbar.app, once, at launch. Anywhere else — `swift test`, the CLI —
    /// it does nothing, so nothing there is observed or kept.
    @MainActor func start() {
        start(isTheApp: AppPresence.isTheApp, app: .default, workspace: NSWorkspace.shared.notificationCenter)
    }

    /// `start`, with the answer to "is this Winbar.app?" and the centres handed in, for tests.
    @MainActor func start(isTheApp: Bool, app: NotificationCenter, workspace: NotificationCenter) {
        guard isTheApp else { return }
        lock.lock()
        let already = opened != nil
        if !already { opened = clock() }
        lock.unlock()
        guard !already else { return }
        func observe(_ center: NotificationCenter, _ name: Notification.Name, _ event: @escaping (Notification) -> Event) {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                self?.note(event(notification))
            }
            tokens.append((center, token))
        }
        observe(app, NSApplication.didBecomeActiveNotification) { _ in .winbarBecameActive }
        observe(app, NSApplication.didResignActiveNotification) { _ in .winbarResignedActive }
        observe(workspace, NSWorkspace.didActivateApplicationNotification) {
            .appCameForward(bundleID: FocusLog.bundleID(in: $0))
        }
        observe(workspace, NSWorkspace.activeSpaceDidChangeNotification) { _ in .spaceChanged }
    }

    /// Keeps `event`, with what Winbar is doing now — once `start` has begun the log, and never before.
    /// On the main thread, where every one of them is posted.
    func note(_ event: Event) {
        lock.lock()
        let keeping = opened != nil
        lock.unlock()
        guard keeping else { return }
        // Outside the lock: reading the windows is the app's business, and must not hold up a report
        // being read on another thread.
        let at = clock(), state = self.state()
        lock.lock()
        noted += 1
        let entry = Entry(number: noted, at: at, event: event, state: state)
        recent.append(entry)
        if FocusLog.duringSetUp(state), setUp.count < FocusLog.setUpCapacity { setUp.append(entry) }
        lock.unlock()
    }

    /// The log as it stands: the first ones kept during set-up, then the newest, each once and oldest
    /// first. Any thread: the menu's Report a Problem… writes its report off the main one.
    func history() -> History {
        lock.lock()
        defer { lock.unlock() }
        // The newest run unbroken to the last one noted, so any of set-up's first that is no older
        // than the oldest of them is among them already.
        let oldestRecent = recent.items.first?.number ?? .max
        return History(opened: opened, entries: Array(setUp.prefix { $0.number < oldestRecent }) + recent.items)
    }

    /// The bundle identifier of the app a workspace notification is about, and nothing else about it.
    static func bundleID(in notification: Notification) -> String? {
        (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
    }

    /// The kind of a piece of set-up work, without what it was given: `installUTM`, `chooseVM`. The
    /// step is said beside it, and a VM's name fifty times over would be fifty more things to redact.
    static func label(_ work: SetupRunner.Work) -> String {
        String(String(describing: work).prefix { $0 != "(" })
    }

    /// Why `AppPresence.update` is moving Winbar: the windows of its own that are open (its own windows'
    /// titles — never another app's), the one closing, and any alert or panel up. Pure.
    static func why(open: [String], closing: String?, alertsUp: Int) -> String {
        func named(_ title: String) -> String { title.isEmpty ? "an untitled window" : title }
        var parts = [open.isEmpty ? "none of Winbar's windows is open"
                                  : "open: " + open.map(named).joined(separator: ", ")]
        if let closing { parts.append("closing: " + named(closing)) }
        if alertsUp > 0 { parts.append("\(alertsUp) alert or panel up") }
        return parts.joined(separator: "; ")
    }

    /// What the app is doing, read from its windows. Main thread, where every event arrives.
    static func liveState() -> State {
        MainActor.assumeIsolated {
            let controller = SetupWindowController.presented.flatMap { $0.isPresented ? $0 : nil }
            let window = controller.flatMap { controller in NSApp.windows.first { $0.delegate === controller } }
            return State(policy: NSApp.activationPolicy(), active: NSApp.isActive, hidden: NSApp.isHidden,
                         setupStep: controller?.state.step,
                         work: SetupRunner.started?.inFlight.map { label($0.work) },
                         window: window.map { State.Window(visible: $0.isVisible, key: $0.isKeyWindow,
                                                           onActiveSpace: $0.isOnActiveSpace) })
        }
    }

    // MARK: - In the report

    /// The report's last section. Redacted with the rest of the file, by `Diagnose.compose`. Pure.
    static func section(_ history: History) -> Diagnose.Section {
        Diagnose.Section(heading: Diagnose.headings.focus, lines: lines(history))
    }

    /// Oldest first, two lines each: when, what, and then what Winbar was doing. Where the entries'
    /// numbers skip — before the first, or between set-up's first ones and the newest — a line says
    /// how many weren't kept there, so a gap never reads as nothing having happened. Pure.
    static func lines(_ history: History) -> [String] {
        guard let opened = history.opened else { return Diagnose.wrap(Copy.notKept, at: 100) }
        let since = Diagnose.settingDate.string(from: opened)
        guard !history.entries.isEmpty else { return [Copy.noneSince(since)] }
        var lines = Diagnose.wrap(Copy.intro(since: since, first: setUpCapacity, last: capacity), at: 100)
        lines.append("")
        var previous = 0
        for entry in history.entries {
            let skipped = entry.number - previous - 1
            if skipped > 0 { lines.append(Copy.skipped(skipped)) }
            previous = entry.number
            let elapsed = String(format: "+%.1fs", entry.at.timeIntervalSince(opened))
            lines.append("\(clockTime.string(from: entry.at))  \(elapsed)  \(describe(entry.event))")
            lines.append("    " + describe(entry.state))
        }
        return lines
    }

    static func describe(_ event: Event) -> String {
        switch event {
        case .winbarBecameActive: return "Winbar became the active app"
        case .winbarResignedActive: return "Winbar stopped being the active app"
        case .appCameForward(let id): return (id ?? "an app with no bundle identifier") + " came to the front"
        case .spaceChanged: return "The active Space changed"
        case .policyChanged(let from, let to, let why, let activates):
            return "Winbar's activation policy \(name(from)) → \(name(to)) (\(why))"
                + (activates ? ", then it asks to be the active app" : "")
        }
    }

    static func describe(_ state: State) -> String {
        var parts = ["Winbar: \(name(state.policy)), " + (state.active ? "active" : "not active")
                         + (state.hidden ? ", hidden" : "")]
        if let step = state.setupStep {
            var setup = "Set Up Winbar on \(step.rawValue)"
            if let window = state.window {
                setup += window.visible
                    ? ", its window on screen, " + (window.key ? "key" : "not key") + ", "
                        + (window.onActiveSpace ? "on the active Space" : "on another Space")
                    : ", its window not on screen"
            }
            parts.append(setup)
        } else {
            parts.append("Set Up Winbar not open")
        }
        if let work = state.work { parts.append("running \(work)") }
        return parts.joined(separator: "; ")
    }

    /// AppKit's own names, which are what the code says.
    static func name(_ policy: NSApplication.ActivationPolicy) -> String {
        switch policy {
        case .regular: return "regular"
        case .accessory: return "accessory"
        case .prohibited: return "prohibited"
        @unknown default: return "policy \(policy.rawValue)"
        }
    }

    enum Copy {
        static let notKept = "Not kept here. Only the menu bar app keeps a record of focus changes, in memory, and this "
            + "report wasn't made by it — winbar diagnose in a terminal, most likely. Report a Problem… in the menu "
            + "bar writes the same report with them in."

        static func noneSince(_ since: String) -> String { "None recorded since Winbar opened (\(since))." }

        static func intro(since: String, first: Int, last: Int) -> String {
            "Every time Winbar became or stopped being the active app, another app came to the front, the "
                + "Space changed, or Winbar moved between the Dock (regular) and the menu bar (accessory), since "
                + "it opened at \(since), kept in memory only: the first \(first) while Set Up Winbar was open "
                + "or working, and the last \(last). Other apps are named by bundle identifier and nothing "
                + "else. Under each: what Winbar was doing then."
        }

        static func skipped(_ count: Int) -> String {
            "(\(Diagnose.number(count)) more here that \(count == 1 ? "wasn't" : "weren't") kept.)"
        }
    }

    /// Wall-clock time to the millisecond, in this Mac's time zone, which the report's first lines give.
    static let clockTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}
