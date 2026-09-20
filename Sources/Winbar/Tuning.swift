import Foundation

/// The measured recipe, as data. Checks compare against these values and the guest scripts that
/// apply them are generated from the same tables, so the two can't drift apart.
enum Tuning {
    // MARK: Host (VM configuration)

    /// Top-tier core count, clamped 4…8. On an M5 Max (6 Super + 12 Performance cores) 6 vCPUs used the
    /// least host CPU for a fixed workload; 8 cost 28% more with no speed gain; 4 was slower and no
    /// cheaper. The fastest tier is what generalises that to other chips.
    static func recommendedCPUs(topTierCores: Int) -> Int {
        min(max(topTierCores, 4), 8)
    }

    /// Tiered by host RAM, and never more than half of it, so a small Mac keeps room for itself.
    /// (H4 never lowers a larger value the user chose; see Recipe.)
    static func recommendedMemoryMB(hostBytes: UInt64) -> Int {
        let gib = hostBytes / (1 << 30)
        let tier = gib >= 64 ? 16384 : gib >= 32 ? 12288 : 8192
        return min(tier, Int(hostBytes / (1 << 20) / 2))
    }

    /// What "console" means when turning the display back on. UTM's own default for Windows on Apple
    /// silicon; the scalers match what UTM writes for a new VM.
    static let consoleDisplayHardware = "virtio-ramfb-gl"

    /// Where UTM keeps VMs unless the user put them elsewhere.
    static var utmDocuments: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.utmapp.UTM/Data/Documents", isDirectory: true)
    }

    // MARK: Guest power (G1, G2)

    static let balancedScheme = "381b4222-f694-41f0-9685-ff5bb260df2e"

    /// AC values only: the VM has no virtual battery, so Windows always believes it is on AC.
    /// Fast ramp-up for responsiveness, but core parking stays allowed (CPMINCORES 10): parked vCPUs are
    /// what let host cores sleep. That's also why Ultimate Performance is deliberately not used.
    static let processor: [(setting: String, value: Int)] = [
        ("PERFINCPOL", 2),          // "rocket" increase policy
        ("PERFINCTHRESHOLD", 30),
        ("PERFDECTHRESHOLD", 20),
        ("CPMINCORES", 10),
        ("CPMAXCORES", 100),
        ("PROCTHROTTLEMIN", 5),
        ("PROCTHROTTLEMAX", 100),
    ]

    /// Minutes, as `powercfg /change` takes them. powercfg stores seconds.
    static let monitorTimeoutMinutes = 5    // blanking stops DWM compositing and framebuffer blits
    static let standbyTimeoutMinutes = 0    // never suspend the VM itself
    static let diskTimeoutMinutes = 20

    /// Shut down: the hidden default resolves to a sleep state that doesn't exist in the VM.
    static let powerButtonShutDown = 3

    // MARK: Guest services (G3)

    static let disabledServices = ["SysMain", "WSearch", "DiagTrack"]

    // MARK: Guest visual effects (G4)

    struct UserSetting {
        enum Kind: String { case dword = "DWord", string = "String", binary = "Binary" }
        let key: String     // relative to the user's hive
        let name: String
        let kind: Kind
        let value: String   // binary: space-separated lowercase hex bytes

        /// A PowerShell expression for the value, typed for New-ItemProperty.
        var powerShellValue: String {
            switch kind {
            case .dword: return value
            case .string: return GuestAgent.psQuote(value)
            case .binary: return "([byte[]](" + value.split(separator: " ").map { "0x\($0)" }.joined(separator: ",") + "))"
            }
        }
    }

    /// Acrylic, animations and shadows are expensive on an unaccelerated framebuffer.
    static let visualEffects: [UserSetting] = [
        .init(key: #"Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects"#, name: "VisualFXSetting", kind: .dword, value: "3"),
        .init(key: #"Control Panel\Desktop\WindowMetrics"#, name: "MinAnimate", kind: .string, value: "0"),
        .init(key: #"Control Panel\Desktop"#, name: "DragFullWindows", kind: .string, value: "0"),
        .init(key: #"Control Panel\Desktop"#, name: "FontSmoothing", kind: .string, value: "2"),
        .init(key: #"Control Panel\Desktop"#, name: "MenuShowDelay", kind: .string, value: "0"),
        .init(key: #"Control Panel\Desktop"#, name: "UserPreferencesMask", kind: .binary, value: "90 12 03 80 10 00 00 00"),
        .init(key: #"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"#, name: "EnableTransparency", kind: .dword, value: "0"),
        .init(key: #"Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"#, name: "TaskbarAnimations", kind: .dword, value: "0"),
        .init(key: #"Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"#, name: "ListviewShadow", kind: .dword, value: "0"),
    ]

    // MARK: Guest RDP (G6, G7)

    /// The Remote Desktop firewall group, by resource id rather than display name so it works on
    /// non-English Windows.
    static let rdpFirewallGroup = "@FirewallAPI.dll,-28752"

    /// Renew the listener certificate once it has less than this left.
    static let certificateMinimumDays = 30

    /// Windows editions that can't host Remote Desktop at all.
    static let homeEditions: Set<String> = ["Core", "CoreN", "CoreSingleLanguage", "CoreCountrySpecific"]
}
