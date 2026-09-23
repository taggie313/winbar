import AppKit
import ServiceManagement

/// `Winbar --self-test` prints what the menu would see, using the same probes, then exits.
///
/// Its real job is answering for the app's own privacy grants. Run from a shell, a process inherits its
/// parent's grants (Terminal's Accessibility, Terminal's Local Network), which once made a test report
/// "ready" while the real app couldn't connect. So doctor launches the app itself through
/// LaunchServices with `--self-test` and reads its output (`launchAsApp`).
enum SelfTest {
    /// `--self-test` with this leaves out the "rdp readiness" row, and so never probes the Remote
    /// Desktop port. That probe is what raises macOS's Local Network prompt, and the setup window
    /// runs the self-test for its Accessibility and Launch at Login rows (C3, C4) on every read from
    /// step 6 on — before Connect, where the window says that prompt is coming (spec §2.2).
    static let noPortProbe = "--no-rdp-probe"

    /// The arguments that make a self-test probe the port, or leave it alone. What `Context.selfTest`
    /// passes; `probesPort(arguments:)` is what the launched app reads back.
    static func arguments(probingPort: Bool) -> [String] { probingPort ? [] : [noPortProbe] }

    /// Whether a self-test launched with `arguments` probes the port. Unless told otherwise, it does:
    /// doctor and diagnose report the answer.
    static func probesPort(arguments: [String]) -> Bool { !arguments.contains(noPortProbe) }

    static func run(requestAccessibility: Bool, probePort: Bool) -> Int32 {
        if requestAccessibility && !WindowsApp.accessibilityTrusted {
            WindowsApp.requestAccessibility()
            pause(2)   // give the system prompt time to appear before this process exits
        }
        let vm = Config.vmName
        let process = VMProcesses.find(vm)
        if let vm, let process { VMProcesses.cache(process, for: vm) }
        let mac = process?.mac ?? Config.vmMAC
        let ip = RDP.leasedIP(mac: mac)
        var rows: [(String, String)] = [
            ("winbar", AppBundle.version),
            ("vm", vm ?? "(not configured)"),
            ("qemu running", String(process != nil)),
            ("console enabled", (process.map { !$0.headless } ?? Config.consoleEnabled).map(String.init) ?? "unknown"),
            ("vcpus", process?.cpus.map(String.init) ?? "unknown"),
            ("memory mb", process?.memoryMB.map(String.init) ?? "unknown"),
            ("utmctl present", String(FileManager.default.isExecutableFile(atPath: UTM.utmctl))),
            ("accessibility", String(WindowsApp.accessibilityTrusted)),
            ("login item", loginItemStatus),
            ("windows app", WindowsApp.appURL?.path ?? "missing"),
            ("vm mac", mac ?? "unknown"),
            ("leased ip", ip ?? "none"),
            ("vm bridge", ip.flatMap(RDP.bridgeInterface(for:)) ?? "not found"),
        ]
        if let row = readinessRow(vmRunning: process != nil, probePort: probePort, probe: { RDP.probeNow(mac: mac) }) {
            rows.append(row)
        }
        if Debug.enabled {
            Debug.log("UTM executable=\(UTM.executablePath ?? "?") processIDs=\(UTM.processIDs)")
        }
        for (key, value) in rows { print("\(key + ":")\(String(repeating: " ", count: max(1, 17 - key.count)))\(value)") }
        print("self-test: done")   // end marker for AppBundle.runAsApp
        return 0
    }

    /// The "rdp readiness" row: nil when the port is to be left alone, and then `probe` is never
    /// called. Otherwise "vm off" without probing — there is nothing to ask — or what the probe said.
    /// Pure, given `probe`, so what `--no-rdp-probe` leaves alone is testable without a network.
    static func readinessRow(vmRunning: Bool, probePort: Bool, probe: () -> RDP.Readiness) -> (String, String)? {
        guard probePort else { return nil }
        return ("rdp readiness", vmRunning ? probe().rawValue : "vm off")
    }

    static var loginItemStatus: String {
        switch SMAppService.mainApp.status {
        case .enabled: return "enabled"
        case .notRegistered: return "notRegistered"
        case .requiresApproval: return "requiresApproval"
        case .notFound: return "notFound"
        @unknown default: return "unknown"
        }
    }

    /// Runs the self-test as Winbar.app, so the answers are the app's own. Blocking.
    static func launchAsApp(extraArguments: [String] = []) -> Result<[String: String], WinbarError> {
        guard let app = AppBundle.url else {
            return .failure(WinbarError("Not running from Winbar.app", "This binary isn't inside the app bundle, so the app's own permissions can't be checked."))
        }
        guard case .finished(let text)? = AppBundle.runAsApp(["--self-test"] + extraArguments, endMarker: "self-test: done", timeout: 45) else {
            return .failure(WinbarError("Winbar's self-test didn't report back", "Launching \(app.path) --self-test produced no complete output within 45 s."))
        }
        let values = parse(text)
        guard values["accessibility"] != nil else {
            return .failure(WinbarError("Winbar's self-test didn't report back", text))
        }
        return .success(values)
    }

    static func parse(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            values[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return values
    }
}
