import AppKit
import ServiceManagement

/// `Winbar --self-test` prints what the menu would see, using the same probes, then exits.
///
/// Its real job is answering for the app's own privacy grants. Run from a shell, a process inherits its
/// parent's grants (Terminal's Accessibility, Terminal's Local Network), which once made a test report
/// "ready" while the real app couldn't connect. So doctor launches the app itself through
/// LaunchServices with `--self-test` and reads its output (`launchAsApp`).
enum SelfTest {
    static func run(requestAccessibility: Bool) -> Int32 {
        if requestAccessibility && !WindowsApp.accessibilityTrusted {
            WindowsApp.requestAccessibility()
            pause(2)   // give the system prompt time to appear before this process exits
        }
        let vm = Config.vmName
        let process = VMProcesses.find(vm)
        if let vm, let process { VMProcesses.cache(process, for: vm) }
        let mac = process?.mac ?? Config.vmMAC
        let ip = RDP.leasedIP(mac: mac)
        let rows: [(String, String)] = [
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
            ("rdp readiness", process == nil ? "vm off" : RDP.probeNow(mac: mac).rawValue),
        ]
        if Debug.enabled {
            Debug.log("UTM executable=\(UTM.executablePath ?? "?") processIDs=\(UTM.processIDs)")
        }
        for (key, value) in rows { print("\(key + ":")\(String(repeating: " ", count: max(1, 17 - key.count)))\(value)") }
        print("self-test: done")   // end marker for AppBundle.runAsApp
        return 0
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
