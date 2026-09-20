import Foundation

// The shared vocabulary of `winbar create`: checklist ids, stages, the edition and ISO facts, and the
// plan. The CLI, the window, the answer-file renderer and the job's state.json all use these, so the
// raw values are a contract: don't rename them.

/// A checklist row that can be ticked. Order is Rufus 4.15's Windows 11 dialog, then Winbar's extras.
/// The computer name and the edition are fields, not options.
enum CreateOption: String, CaseIterable, Codable, Sendable {
    case bypassRequirements = "bypass_requirements"
    case noOnlineAccount = "no_online_account"
    case localAccount = "local_account"
    case regionalFromMac = "regional_from_mac"
    case skipPrivacy = "skip_privacy"
    case noBitLocker = "no_bitlocker"
    case qol
    case autologon
    case remoteDesktop = "remote_desktop"
    case guestTools = "guest_tools"
    case winbarTuning = "winbar_tuning"

    /// Always on. Turning one off is refused, with the reason (the copy deck's E_LOCKED_* messages).
    var isLocked: Bool {
        switch self {
        case .bypassRequirements, .localAccount, .guestTools: return true
        default: return false
        }
    }

    static let defaults: Set<CreateOption> = Set(allCases)
}

/// The ten stages, shared by the CLI, the window, state.json and the log.
enum CreateStage: String, CaseIterable, Codable, Sendable {
    case check
    case guestTools = "guest_tools"
    case media
    case vm
    case boot
    case copy
    case devices
    case oobe
    case firstLogon = "first_logon"
    case finish

    /// 1-based, for "step N of 10".
    var number: Int { (CreateStage.allCases.firstIndex(of: self) ?? 0) + 1 }
}

/// One image in the ISO's install.wim/esd.
struct WindowsEdition: Codable, Equatable, Sendable {
    /// The WIM image index (1-based); the answer file selects the image by this.
    var index: Int
    /// `NAME`, e.g. "Windows 11 Pro".
    var name: String
    /// `DISPLAYNAME` (localised); falls back to `name`.
    var displayName: String
    /// `EDITIONID`, e.g. "Professional", "Core".
    var editionID: String

    static let homeEditionIDs: Set<String> = ["Core", "CoreN", "CoreSingleLanguage", "CoreCountrySpecific"]
    var isHome: Bool { WindowsEdition.homeEditionIDs.contains(editionID) }
}

/// What preflight read from the Windows ISO.
struct WindowsImageInfo: Codable, Equatable, Sendable {
    var path: String
    /// e.g. 26200.
    var build: Int
    /// e.g. "26200.8037" when the WIM has SPBUILD; informational.
    var fullBuild: String?
    /// The image's default UI language (WIM `<LANGUAGES><DEFAULT>`), e.g. "en-US". The answer file's
    /// UILanguage comes from here, never from the Mac: other languages would need downloading.
    var language: String
    var editions: [WindowsEdition]
    /// Every image is ARCH 12.
    var isArm64: Bool
    /// true when El Torito boots efisys.bin (the "Press any key to boot from CD or DVD" prompt).
    var bootPrompts: Bool
}

/// Regional values taken from the Mac (formats, keyboard, time zone), already in Windows' terms.
struct RegionalValues: Codable, Equatable, Sendable {
    /// Windows locale name for UserLocale, e.g. "en-GB".
    var userLocale: String
    /// Windows locale name for SystemLocale (the image language when the Mac's has no Windows match).
    var systemLocale: String
    /// InputLocale: "0809:00000809", or nil when the Mac's keyboard has no Windows equivalent.
    var inputLocale: String?
    /// Windows time zone id, e.g. "GMT Standard Time"; nil when the Mac's IANA zone has no mapping.
    var timeZone: String?
    /// For display: "English (United Kingdom) · British · GMT Standard Time".
    var summary: String
}

/// Everything the job needs except the password, which is never part of the plan, state.json or logs.
struct CreatePlan: Codable, Equatable, Sendable {
    var vmName: String
    var isoPath: String
    var edition: WindowsEdition
    var cores: Int
    var memoryMiB: Int
    var diskGiB: Int
    var options: Set<CreateOption>
    /// Modifier of `winbarTuning` (the setup command's --no-visual-tweaks), not a checklist row.
    var noVisualTweaks: Bool
    var userName: String
    var computerName: String
    /// nil when `regionalFromMac` is off: the image language is used for all three locales.
    var regional: RegionalValues?
    /// Make the new VM the one Winbar's menu looks after.
    var select: Bool
    /// Stay on the UTM console at the end instead of going headless (`--console`).
    var keepConsole: Bool
    /// `--guest-tools PATH`: a local copy of the pinned Guest Tools installer to use instead of
    /// downloading it. Checked against the pin like any other copy. nil = download (or use the cache).
    var guestToolsPath: String?

    func has(_ option: CreateOption) -> Bool { options.contains(option) }
}

/// A file for the root of the WINBAR_SETUP CD (the answer file renderer makes these; the media builder
/// writes them, plus the pinned Guest Tools installer, and burns the ISO).
struct SetupFile: Equatable, Sendable {
    var name: String
    var contents: Data
}
