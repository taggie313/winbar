import Foundation

/// The Mac's formats, keyboard and time zone, in Windows' terms, for the "Set regional options to the same
/// values as this Mac's" row. Only `read(imageLanguage:)` looks at the Mac; everything else is a pure mapping,
/// so the tests can feed it any Mac.
///
/// Windows needs its own names for all three: a locale name it knows (en-GB, not en_GB@rg=gbzzzz or
/// zh-Hans-CN), a keyboard as LCID:KLID, and a Windows time zone id. Anything the Mac has that Windows
/// doesn't falls back to the ISO's language (or, for the time zone, Windows' default), with a note that says so.
enum Regional {
    /// What `read` found, with the notes to show when something had no Windows match.
    struct Reading: Equatable {
        var values: RegionalValues
        var notes: [Note]
        /// The Mac's own values, for the CLI's "{iana} → {windows zone}" line and the log.
        var macLocale: String
        var macKeyboard: String
        var ianaZone: String
    }

    /// Informational, shown once where the regional values are shown.
    enum Note: Equatable, CustomStringConvertible {
        /// N_KEYBOARD_FALLBACK.
        case keyboardFallback(macLayout: String, fallback: String)
        /// N_REGIONAL_FALLBACK: Windows has no locale for the Mac's region at all.
        case localeFallback(macLocale: String, language: String)
        /// N_REGIONAL_FALLBACK, milder: formats keep the Mac's region, but Windows can't use it as the
        /// language for programs that don't support Unicode (a numeric region such as es-419).
        case systemLocaleFallback(region: String, language: String)
        /// The Mac's time zone has no Windows id: Windows starts with its default zone.
        case timeZoneFallback(iana: String)

        var description: String {
            switch self {
            case .keyboardFallback(let layout, let fallback):
                return "Your keyboard layout (\(layout)) has no Windows equivalent, so Windows uses \(fallback). "
                    + "Change it later in Settings > Time & language > Language & region."
            case .localeFallback(let locale, let language):
                return "Windows has no match for this Mac's region (\(locale)), so it uses \(language) formats. "
                    + "Change them later in Settings > Time & language > Language & region."
            case .systemLocaleFallback(let region, let language):
                return "Windows uses \(region) formats, but \(language) for programs that don't support Unicode: "
                    + "Windows can't use \(region) for those."
            case .timeZoneFallback(let iana):
                return "Windows has no time zone matching \(iana), so it starts with its default one. "
                    + "Change it later in Settings > Time & language > Date & time."
            }
        }
    }

    // MARK: - Reading the Mac

    /// The Mac's current values. Reads preferences only: no Text Input Sources calls, which must run on the
    /// main thread, and the job and the CLI read this from anywhere.
    static func read(imageLanguage: String) -> Reading {
        let hiToolbox = "com.apple.HIToolbox" as CFString
        let current = CFPreferencesCopyAppValue("AppleCurrentKeyboardLayoutInputSourceID" as CFString, hiToolbox) as? String
        let selected = CFPreferencesCopyAppValue("AppleSelectedInputSources" as CFString, hiToolbox) as? [[String: Any]] ?? []
        return reading(macLocale: Locale.current.identifier,
                       keyboard: keyboard(currentLayoutID: current, selectedSources: selected),
                       ianaZone: TimeZone.current.identifier,
                       imageLanguage: imageLanguage)
    }

    /// Puts the three mappings together, with a note for each fallback.
    static func reading(macLocale: String, keyboard: Keyboard, ianaZone: String, imageLanguage: String,
                        displayLocale: Locale = .current) -> Reading {
        func name(_ tag: String) -> String { displayLocale.localizedString(forIdentifier: tag) ?? tag }
        var notes: [Note] = []
        let locale = windowsLocale(fromMac: macLocale)
        let user = locale.user ?? imageLanguage
        let system = locale.system ?? imageLanguage
        if locale.user == nil {
            notes.append(.localeFallback(macLocale: name(macLocale), language: name(imageLanguage)))
        } else if locale.system == nil {
            notes.append(.systemLocaleFallback(region: name(user), language: name(imageLanguage)))
        }
        let keyboardPart: String
        if keyboard.inputLocale != nil {
            keyboardPart = keyboard.macName
        } else {
            keyboardPart = "\(name(imageLanguage)) keyboard"
            notes.append(.keyboardFallback(macLayout: keyboard.macName, fallback: "the \(keyboardPart)"))
        }
        let zone = windowsTimeZone(forIANA: ianaZone)
        if zone == nil { notes.append(.timeZoneFallback(iana: ianaZone)) }
        let summary = [name(user), keyboardPart, zone ?? "Windows' default time zone"].joined(separator: " · ")
        return Reading(values: RegionalValues(userLocale: user, systemLocale: system, inputLocale: keyboard.inputLocale,
                                              timeZone: zone, summary: summary),
                       notes: notes, macLocale: macLocale, macKeyboard: keyboard.macName, ianaZone: ianaZone)
    }

    // MARK: - Formats

    /// UserLocale and SystemLocale for a Mac locale identifier (`Locale.current.identifier`, AppleLocale).
    /// nil means Windows has no locale for it, and the caller uses the image language.
    ///
    /// `@…` keywords go (`en_US@rg=gbzzzz` → en-US). Chinese scripts become Windows' regional names
    /// (zh-Hans-* → zh-CN; zh-Hant-* → zh-HK in Hong Kong and Macau, else zh-TW). Other scripts stay only
    /// when Windows' name has one (sr-Latn-RS); a region Windows spells with a script gets it added (sr_RS,
    /// Cyrillic on the Mac, is sr-Cyrl-RS). A tag outside `windowsLocales` has no match. A numeric region
    /// (es-419) can be a UserLocale but never a SystemLocale, which needs a country's code page.
    static func windowsLocale(fromMac identifier: String) -> (user: String?, system: String?) {
        let base = identifier.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let parts = base.replacingOccurrences(of: "_", with: "-").split(separator: "-").map(String.init)
        guard let first = parts.first, !first.isEmpty else { return (nil, nil) }
        let language = first.lowercased()
        var script: String?
        var region: String?
        for part in parts.dropFirst() {
            if script == nil, region == nil, part.count == 4, part.allSatisfy(\.isLetter) {
                script = part.prefix(1).uppercased() + part.dropFirst().lowercased()
            } else if region == nil, (part.count == 2 && part.allSatisfy(\.isLetter)) || (part.count == 3 && part.allSatisfy(\.isNumber)) {
                region = part.uppercased()
            }
        }
        var candidates: [String] = []
        if language == "zh", let script {
            switch script {
            case "Hans": candidates = ["zh-CN"]
            case "Hant": candidates = [region == "HK" || region == "MO" ? "zh-HK" : "zh-TW"]
            default: return (nil, nil)
            }
        } else {
            guard let region else { return (nil, nil) }
            if let script { candidates.append("\(language)-\(script)-\(region)") }
            candidates.append("\(language)-\(region)")
            if let likely = likelyScripts["\(language)-\(region)"] ?? likelyScripts[language] {
                candidates.append("\(language)-\(likely)-\(region)")
            }
        }
        guard let match = candidates.first(where: { windowsLocales.contains($0) }) else { return (nil, nil) }
        let numericRegion = match.split(separator: "-").last?.allSatisfy(\.isNumber) ?? false
        return (match, numericRegion ? nil : match)
    }

    /// Scripts Windows puts in its locale names where the Mac's identifier usually has none (CLDR likely
    /// subtags, limited to the names in `windowsLocales`).
    static let likelyScripts: [String: String] = [
        "sr": "Cyrl", "bs": "Latn", "az": "Latn", "uz": "Latn", "ha": "Latn", "tg": "Cyrl", "iu": "Cans",
        "chr": "Cher", "tzm": "Latn", "quc": "Latn", "mn-CN": "Mong", "pa-PK": "Arab",
    ]

    /// Windows locale names that have an LCID ([MS-LCID]): the ones Windows accepts as UserLocale and,
    /// except numeric regions, as SystemLocale. Locales Windows only knows as "supplemental" (en-ES, en-DE…)
    /// are left out on purpose: they can't be a SystemLocale.
    static let windowsLocales: Set<String> = [
        "af-ZA", "am-ET", "ar-AE", "ar-BH", "ar-DZ", "ar-EG", "ar-IQ", "ar-JO", "ar-KW", "ar-LB", "ar-LY", "ar-MA",
        "ar-OM", "ar-QA", "ar-SA", "ar-SY", "ar-TN", "ar-YE", "arn-CL", "as-IN", "az-Cyrl-AZ", "az-Latn-AZ", "ba-RU",
        "be-BY", "bg-BG", "bn-BD", "bn-IN", "bo-CN", "br-FR", "bs-Cyrl-BA", "bs-Latn-BA", "ca-ES", "chr-Cher-US",
        "co-FR", "cs-CZ", "cy-GB", "da-DK", "de-AT", "de-CH", "de-DE", "de-LI", "de-LU", "dsb-DE", "dv-MV", "el-GR",
        "en-029", "en-AE", "en-AU", "en-BZ", "en-CA", "en-GB", "en-HK", "en-IE", "en-IN", "en-JM", "en-MY", "en-NZ",
        "en-PH", "en-SG", "en-TT", "en-US", "en-ZA", "en-ZW", "es-419", "es-AR", "es-BO", "es-CL", "es-CO", "es-CR",
        "es-CU", "es-DO", "es-EC", "es-ES", "es-GT", "es-HN", "es-MX", "es-NI", "es-PA", "es-PE", "es-PR", "es-PY",
        "es-SV", "es-US", "es-UY", "es-VE", "et-EE", "eu-ES", "fa-IR", "fi-FI", "fil-PH", "fo-FO", "fr-BE", "fr-CA",
        "fr-CH", "fr-FR", "fr-LU", "fr-MC", "fy-NL", "ga-IE", "gd-GB", "gl-ES", "gsw-FR", "gu-IN", "ha-Latn-NG",
        "haw-US", "he-IL", "hi-IN", "hr-BA", "hr-HR", "hsb-DE", "hu-HU", "hy-AM", "id-ID", "ig-NG", "ii-CN", "is-IS",
        "it-CH", "it-IT", "iu-Cans-CA", "iu-Latn-CA", "ja-JP", "ka-GE", "kk-KZ", "kl-GL", "km-KH", "kn-IN", "ko-KR",
        "kok-IN", "ku-Arab-IQ", "ky-KG", "lb-LU", "lo-LA", "lt-LT", "lv-LV", "mi-NZ", "mk-MK", "ml-IN", "mn-MN",
        "mn-Mong-CN", "moh-CA", "mr-IN", "ms-BN", "ms-MY", "mt-MT", "my-MM", "nb-NO", "ne-NP", "nl-BE", "nl-NL",
        "nn-NO", "nso-ZA", "oc-FR", "or-IN", "pa-Arab-PK", "pa-IN", "pl-PL", "prs-AF", "ps-AF", "pt-BR", "pt-PT",
        "quc-Latn-GT", "quz-BO", "quz-EC", "quz-PE", "rm-CH", "ro-MD", "ro-RO", "ru-MD", "ru-RU", "rw-RW", "sa-IN",
        "sah-RU", "se-FI", "se-NO", "se-SE", "si-LK", "sk-SK", "sl-SI", "sma-NO", "sma-SE", "smj-NO", "smj-SE",
        "smn-FI", "sms-FI", "sq-AL", "sr-Cyrl-BA", "sr-Cyrl-ME", "sr-Cyrl-RS", "sr-Latn-BA", "sr-Latn-ME",
        "sr-Latn-RS", "sv-FI", "sv-SE", "sw-KE", "syr-SY", "ta-IN", "ta-LK", "te-IN", "tg-Cyrl-TJ", "th-TH",
        "ti-ER", "ti-ET", "tk-TM", "tn-BW", "tn-ZA", "tr-TR", "tt-RU", "tzm-Latn-DZ", "ug-CN", "uk-UA", "ur-IN",
        "ur-PK", "uz-Cyrl-UZ", "uz-Latn-UZ", "vi-VN", "wo-SN", "xh-ZA", "yo-NG", "zh-CN", "zh-HK", "zh-MO",
        "zh-SG", "zh-TW", "zu-ZA",
    ]

    // MARK: - Keyboard

    /// The Mac's keyboard and its Windows InputLocale (nil: no Windows equivalent).
    struct Keyboard: Equatable {
        var macName: String
        var inputLocale: String?
    }

    /// The current keyboard: an input method for Japanese, Korean or Chinese when one is selected (Windows
    /// takes the language's tag and gives it its IME), otherwise the current keyboard layout.
    /// `currentLayoutID` is HIToolbox's AppleCurrentKeyboardLayoutInputSourceID ("com.apple.keylayout.British");
    /// `selectedSources` its AppleSelectedInputSources.
    static func keyboard(currentLayoutID: String?, selectedSources: [[String: Any]]) -> Keyboard {
        for source in selectedSources {
            let ids = [source["Input Mode"] as? String, source["Bundle ID"] as? String].compactMap { $0 }
            for id in ids {
                if let method = inputMethods.first(where: { id.hasPrefix($0.prefix) }) {
                    return Keyboard(macName: method.name, inputLocale: method.tag)
                }
            }
        }
        let prefix = "com.apple.keylayout."
        guard let id = currentLayoutID, id.hasPrefix(prefix) else {
            let named = selectedSources.compactMap { $0["KeyboardLayout Name"] as? String }.first
            return Keyboard(macName: named ?? currentLayoutID ?? "unknown", inputLocale: nil)
        }
        let key = String(id.dropFirst(prefix.count))
        if let layout = keyboardLayouts[key] { return Keyboard(macName: layout.name, inputLocale: layout.inputLocale) }
        let named = selectedSources.first { ($0["InputSourceKind"] as? String) == "Keyboard Layout" }?["KeyboardLayout Name"] as? String
        return Keyboard(macName: named ?? key, inputLocale: nil)
    }

    /// Input methods whose language Windows serves with its own IME: the tag form of InputLocale.
    static let inputMethods: [(prefix: String, name: String, tag: String)] = [
        ("com.apple.inputmethod.Kotoeri", "Japanese", "ja-JP"),
        ("com.apple.inputmethod.Japanese", "Japanese", "ja-JP"),
        ("com.apple.inputmethod.Korean", "Korean", "ko-KR"),
        ("com.apple.inputmethod.SCIM", "Chinese, Simplified", "zh-CN"),
        ("com.apple.inputmethod.TCIM", "Chinese, Traditional", "zh-TW"),
        ("com.apple.inputmethod.TYIM", "Cantonese", "zh-HK"),
    ]

    /// macOS keyboard layouts (the part of the input source id after "com.apple.keylayout.") → the closest
    /// Windows layout for the same language, as LCID:KLID. Close variants map to the language's standard
    /// Windows layout (Windows has no QZERTY or numeric-row French); a layout with no Windows counterpart
    /// at all (ABC – Extended, Colemak) has none, and Windows uses the ISO's default keyboard.
    static let keyboardLayouts: [String: (name: String, inputLocale: String?)] = [
        "US": ("U.S.", "0409:00000409"),
        "ABC": ("ABC", "0409:00000409"),
        "USInternational-PC": ("U.S. International – PC", "0409:00020409"),
        "USExtended": ("ABC – Extended", nil),
        "Colemak": ("Colemak", nil),
        "Dvorak": ("Dvorak", "0409:00010409"),
        "DVORAK-QWERTYCMD": ("Dvorak – QWERTY ⌘", "0409:00010409"),
        "Dvorak-Left": ("Dvorak – Left", "0409:00030409"),
        "Dvorak-Right": ("Dvorak – Right", "0409:00040409"),
        "British": ("British", "0809:00000809"),
        "British-PC": ("British – PC", "0809:00000809"),
        "Irish": ("Irish", "1809:00001809"),
        "Australian": ("Australian", "0c09:00000409"),
        "Canadian": ("Canadian English", "1009:00000409"),
        "Canadian-CSA": ("Canadian French – CSA", "0c0c:00011009"),
        "CanadianFrench-PC": ("Canadian French – PC", "0c0c:00001009"),
        "German": ("German", "0407:00000407"),
        "Austrian": ("Austrian", "0c07:00000407"),
        "SwissGerman": ("Swiss German", "0807:00000807"),
        "SwissFrench": ("Swiss French", "100c:0000100c"),
        "French": ("French", "040c:0000040c"),
        "French-PC": ("French – PC", "040c:0000040c"),
        "French-numerical": ("French – Numerical", "040c:0000040c"),
        "Belgian": ("Belgian", "080c:0000080c"),
        "Dutch": ("Dutch", "0413:00000413"),
        "Spanish": ("Spanish – Legacy", "0c0a:0000040a"),
        "Spanish-ISO": ("Spanish", "0c0a:0000040a"),
        "LatinAmerican": ("Latin American", "080a:0000080a"),
        "Italian-Pro": ("Italian", "0410:00000410"),
        "Italian": ("Italian – QZERTY", "0410:00000410"),
        "Portuguese": ("Portuguese", "0816:00000816"),
        "Brazilian": ("Brazilian", "0416:00000416"),
        "Brazilian-ABNT2": ("Brazilian – ABNT2", "0416:00000416"),
        "Brazilian-Pro": ("Brazilian – Pro", "0416:00000416"),
        "Danish": ("Danish", "0406:00000406"),
        "Norwegian": ("Norwegian", "0414:00000414"),
        "Swedish-Pro": ("Swedish", "041d:0000041d"),
        "Swedish": ("Swedish – Legacy", "041d:0000041d"),
        "Finnish": ("Finnish", "040b:0000040b"),
        "Icelandic": ("Icelandic", "040f:0000040f"),
        "Faroese": ("Faroese", "0438:00000438"),
        "PolishPro": ("Polish", "0415:00000415"),
        "Polish": ("Polish – QWERTZ", "0415:00010415"),
        "Czech": ("Czech", "0405:00000405"),
        "Czech-QWERTY": ("Czech – QWERTY", "0405:00010405"),
        "Slovak": ("Slovak", "041b:0000041b"),
        "Slovak-QWERTY": ("Slovak – QWERTY", "041b:0001041b"),
        "Hungarian": ("Hungarian", "040e:0000040e"),
        "Romanian": ("Romanian", "0418:00010418"),
        "Romanian-Standard": ("Romanian – Standard", "0418:00010418"),
        "Croatian": ("Croatian", "041a:0000041a"),
        "Croatian-PC": ("Croatian – QWERTZ", "041a:0000041a"),
        "Slovenian": ("Slovenian", "0424:00000424"),
        "Serbian": ("Serbian", "281a:00000c1a"),
        "Serbian-Latin": ("Serbian – Latin", "241a:0000081a"),
        "Estonian": ("Estonian", "0425:00000425"),
        "Lithuanian": ("Lithuanian", "0427:00010427"),
        "Greek": ("Greek", "0408:00000408"),
        "Turkish-QWERTY-PC": ("Turkish Q", "041f:0000041f"),
        "Turkish-QWERTY": ("Turkish Q – Legacy", "041f:0000041f"),
        "Turkish": ("Turkish F", "041f:0001041f"),
        "Russian": ("Russian", "0419:00000419"),
        "RussianWin": ("Russian – PC", "0419:00000419"),
        "Russian-PC": ("Russian – PC", "0419:00000419"),
        "Ukrainian": ("Ukrainian", "0422:00020422"),
        "Ukrainian-PC": ("Ukrainian – PC", "0422:00000422"),
        "Hebrew": ("Hebrew", "040d:0000040d"),
        "Hebrew-PC": ("Hebrew – PC", "040d:0000040d"),
        "Arabic": ("Arabic", "0401:00000401"),
        "Arabic-PC": ("Arabic – PC", "0401:00000401"),
        "Persian": ("Persian", "0429:00000429"),
        "Thai": ("Thai", "041e:0000041e"),
        "Vietnamese": ("Vietnamese", "042a:0001042a"),
        "Maltese": ("Maltese", "043a:0000043a"),
        "Welsh": ("Welsh", "0452:00000452"),
        "Kazakh": ("Kazakh", "043f:0000043f"),
    ]

    // MARK: - Time zone

    /// The Windows id for an IANA zone (`TimeZone.current.identifier`), or nil.
    static func windowsTimeZone(forIANA iana: String) -> String? { windowsZoneForIANA[iana] }

    /// Every Windows time zone id the table knows; the renderer accepts only these.
    static let windowsTimeZones: Set<String> = Set(windowsZoneForIANA.values)

    // How this table was made: a one-off script read CLDR's windowsZones.xml (in the create research folder)
    // and macOS's tzdata; it isn't part of the build. To redo it, map each IANA id in every <mapZone type="…">
    // to its `other` attribute, then add the IANA names CLDR lacks whose zone file under
    // /var/db/timezone/zoneinfo is byte-identical to CLDR zones that all have one Windows id.
    // Generated: CLDR windowsZones.xml (typeVersion 2021a, otherVersion 7e11800),
    // 445 ids from every mapZone, plus 148 names from macOS tzdata 2026c whose zone file is
    // byte-identical to CLDR zones that all map to one Windows id (Asia/Kolkata = Asia/Calcutta).
    static let windowsZoneForIANA: [String: String] = [
        "Africa/Abidjan": "Greenwich Standard Time",
        "Africa/Accra": "Greenwich Standard Time",
        "Africa/Addis_Ababa": "E. Africa Standard Time",
        "Africa/Algiers": "W. Central Africa Standard Time",
        "Africa/Asmara": "E. Africa Standard Time",
        "Africa/Asmera": "E. Africa Standard Time",
        "Africa/Bamako": "Greenwich Standard Time",
        "Africa/Bangui": "W. Central Africa Standard Time",
        "Africa/Banjul": "Greenwich Standard Time",
        "Africa/Bissau": "Greenwich Standard Time",
        "Africa/Blantyre": "South Africa Standard Time",
        "Africa/Brazzaville": "W. Central Africa Standard Time",
        "Africa/Bujumbura": "South Africa Standard Time",
        "Africa/Cairo": "Egypt Standard Time",
        "Africa/Casablanca": "Morocco Standard Time",
        "Africa/Ceuta": "Romance Standard Time",
        "Africa/Conakry": "Greenwich Standard Time",
        "Africa/Dakar": "Greenwich Standard Time",
        "Africa/Dar_es_Salaam": "E. Africa Standard Time",
        "Africa/Djibouti": "E. Africa Standard Time",
        "Africa/Douala": "W. Central Africa Standard Time",
        "Africa/El_Aaiun": "Morocco Standard Time",
        "Africa/Freetown": "Greenwich Standard Time",
        "Africa/Gaborone": "South Africa Standard Time",
        "Africa/Harare": "South Africa Standard Time",
        "Africa/Johannesburg": "South Africa Standard Time",
        "Africa/Juba": "South Sudan Standard Time",
        "Africa/Kampala": "E. Africa Standard Time",
        "Africa/Khartoum": "Sudan Standard Time",
        "Africa/Kigali": "South Africa Standard Time",
        "Africa/Kinshasa": "W. Central Africa Standard Time",
        "Africa/Lagos": "W. Central Africa Standard Time",
        "Africa/Libreville": "W. Central Africa Standard Time",
        "Africa/Lome": "Greenwich Standard Time",
        "Africa/Luanda": "W. Central Africa Standard Time",
        "Africa/Lubumbashi": "South Africa Standard Time",
        "Africa/Lusaka": "South Africa Standard Time",
        "Africa/Malabo": "W. Central Africa Standard Time",
        "Africa/Maputo": "South Africa Standard Time",
        "Africa/Maseru": "South Africa Standard Time",
        "Africa/Mbabane": "South Africa Standard Time",
        "Africa/Mogadishu": "E. Africa Standard Time",
        "Africa/Monrovia": "Greenwich Standard Time",
        "Africa/Nairobi": "E. Africa Standard Time",
        "Africa/Ndjamena": "W. Central Africa Standard Time",
        "Africa/Niamey": "W. Central Africa Standard Time",
        "Africa/Nouakchott": "Greenwich Standard Time",
        "Africa/Ouagadougou": "Greenwich Standard Time",
        "Africa/Porto-Novo": "W. Central Africa Standard Time",
        "Africa/Sao_Tome": "Sao Tome Standard Time",
        "Africa/Timbuktu": "Greenwich Standard Time",
        "Africa/Tripoli": "Libya Standard Time",
        "Africa/Tunis": "W. Central Africa Standard Time",
        "Africa/Windhoek": "Namibia Standard Time",
        "America/Adak": "Aleutian Standard Time",
        "America/Anchorage": "Alaskan Standard Time",
        "America/Anguilla": "SA Western Standard Time",
        "America/Antigua": "SA Western Standard Time",
        "America/Araguaina": "Tocantins Standard Time",
        "America/Argentina/Buenos_Aires": "Argentina Standard Time",
        "America/Argentina/Catamarca": "Argentina Standard Time",
        "America/Argentina/ComodRivadavia": "Argentina Standard Time",
        "America/Argentina/Cordoba": "Argentina Standard Time",
        "America/Argentina/Jujuy": "Argentina Standard Time",
        "America/Argentina/La_Rioja": "Argentina Standard Time",
        "America/Argentina/Mendoza": "Argentina Standard Time",
        "America/Argentina/Rio_Gallegos": "Argentina Standard Time",
        "America/Argentina/Salta": "Argentina Standard Time",
        "America/Argentina/San_Juan": "Argentina Standard Time",
        "America/Argentina/San_Luis": "Argentina Standard Time",
        "America/Argentina/Tucuman": "Argentina Standard Time",
        "America/Argentina/Ushuaia": "Argentina Standard Time",
        "America/Aruba": "SA Western Standard Time",
        "America/Asuncion": "Paraguay Standard Time",
        "America/Atikokan": "SA Pacific Standard Time",
        "America/Atka": "Aleutian Standard Time",
        "America/Bahia": "Bahia Standard Time",
        "America/Bahia_Banderas": "Central Standard Time (Mexico)",
        "America/Barbados": "SA Western Standard Time",
        "America/Belem": "SA Eastern Standard Time",
        "America/Belize": "Central America Standard Time",
        "America/Blanc-Sablon": "SA Western Standard Time",
        "America/Boa_Vista": "SA Western Standard Time",
        "America/Bogota": "SA Pacific Standard Time",
        "America/Boise": "Mountain Standard Time",
        "America/Buenos_Aires": "Argentina Standard Time",
        "America/Cambridge_Bay": "Mountain Standard Time",
        "America/Campo_Grande": "Central Brazilian Standard Time",
        "America/Cancun": "Eastern Standard Time (Mexico)",
        "America/Caracas": "Venezuela Standard Time",
        "America/Catamarca": "Argentina Standard Time",
        "America/Cayenne": "SA Eastern Standard Time",
        "America/Cayman": "SA Pacific Standard Time",
        "America/Chicago": "Central Standard Time",
        "America/Chihuahua": "Central Standard Time (Mexico)",
        "America/Ciudad_Juarez": "Mountain Standard Time",
        "America/Coral_Harbour": "SA Pacific Standard Time",
        "America/Cordoba": "Argentina Standard Time",
        "America/Costa_Rica": "Central America Standard Time",
        "America/Coyhaique": "Magallanes Standard Time",
        "America/Creston": "US Mountain Standard Time",
        "America/Cuiaba": "Central Brazilian Standard Time",
        "America/Curacao": "SA Western Standard Time",
        "America/Danmarkshavn": "Greenwich Standard Time",
        "America/Dawson": "Yukon Standard Time",
        "America/Dawson_Creek": "US Mountain Standard Time",
        "America/Denver": "Mountain Standard Time",
        "America/Detroit": "Eastern Standard Time",
        "America/Dominica": "SA Western Standard Time",
        "America/Edmonton": "Mountain Standard Time",
        "America/Eirunepe": "SA Pacific Standard Time",
        "America/El_Salvador": "Central America Standard Time",
        "America/Ensenada": "Pacific Standard Time (Mexico)",
        "America/Fort_Nelson": "US Mountain Standard Time",
        "America/Fort_Wayne": "US Eastern Standard Time",
        "America/Fortaleza": "SA Eastern Standard Time",
        "America/Glace_Bay": "Atlantic Standard Time",
        "America/Godthab": "Greenland Standard Time",
        "America/Goose_Bay": "Atlantic Standard Time",
        "America/Grand_Turk": "Turks And Caicos Standard Time",
        "America/Grenada": "SA Western Standard Time",
        "America/Guadeloupe": "SA Western Standard Time",
        "America/Guatemala": "Central America Standard Time",
        "America/Guayaquil": "SA Pacific Standard Time",
        "America/Guyana": "SA Western Standard Time",
        "America/Halifax": "Atlantic Standard Time",
        "America/Havana": "Cuba Standard Time",
        "America/Hermosillo": "US Mountain Standard Time",
        "America/Indiana/Indianapolis": "US Eastern Standard Time",
        "America/Indiana/Knox": "Central Standard Time",
        "America/Indiana/Marengo": "US Eastern Standard Time",
        "America/Indiana/Petersburg": "Eastern Standard Time",
        "America/Indiana/Tell_City": "Central Standard Time",
        "America/Indiana/Vevay": "US Eastern Standard Time",
        "America/Indiana/Vincennes": "Eastern Standard Time",
        "America/Indiana/Winamac": "Eastern Standard Time",
        "America/Indianapolis": "US Eastern Standard Time",
        "America/Inuvik": "Mountain Standard Time",
        "America/Iqaluit": "Eastern Standard Time",
        "America/Jamaica": "SA Pacific Standard Time",
        "America/Jujuy": "Argentina Standard Time",
        "America/Juneau": "Alaskan Standard Time",
        "America/Kentucky/Louisville": "Eastern Standard Time",
        "America/Kentucky/Monticello": "Eastern Standard Time",
        "America/Knox_IN": "Central Standard Time",
        "America/Kralendijk": "SA Western Standard Time",
        "America/La_Paz": "SA Western Standard Time",
        "America/Lima": "SA Pacific Standard Time",
        "America/Los_Angeles": "Pacific Standard Time",
        "America/Louisville": "Eastern Standard Time",
        "America/Lower_Princes": "SA Western Standard Time",
        "America/Maceio": "SA Eastern Standard Time",
        "America/Managua": "Central America Standard Time",
        "America/Manaus": "SA Western Standard Time",
        "America/Marigot": "SA Western Standard Time",
        "America/Martinique": "SA Western Standard Time",
        "America/Matamoros": "Central Standard Time",
        "America/Mazatlan": "Mountain Standard Time (Mexico)",
        "America/Mendoza": "Argentina Standard Time",
        "America/Menominee": "Central Standard Time",
        "America/Merida": "Central Standard Time (Mexico)",
        "America/Metlakatla": "Alaskan Standard Time",
        "America/Mexico_City": "Central Standard Time (Mexico)",
        "America/Miquelon": "Saint Pierre Standard Time",
        "America/Moncton": "Atlantic Standard Time",
        "America/Monterrey": "Central Standard Time (Mexico)",
        "America/Montevideo": "Montevideo Standard Time",
        "America/Montreal": "Eastern Standard Time",
        "America/Montserrat": "SA Western Standard Time",
        "America/Nassau": "Eastern Standard Time",
        "America/New_York": "Eastern Standard Time",
        "America/Nipigon": "Eastern Standard Time",
        "America/Nome": "Alaskan Standard Time",
        "America/Noronha": "UTC-02",
        "America/North_Dakota/Beulah": "Central Standard Time",
        "America/North_Dakota/Center": "Central Standard Time",
        "America/North_Dakota/New_Salem": "Central Standard Time",
        "America/Nuuk": "Greenland Standard Time",
        "America/Ojinaga": "Central Standard Time",
        "America/Panama": "SA Pacific Standard Time",
        "America/Pangnirtung": "Eastern Standard Time",
        "America/Paramaribo": "SA Eastern Standard Time",
        "America/Phoenix": "US Mountain Standard Time",
        "America/Port-au-Prince": "Haiti Standard Time",
        "America/Port_of_Spain": "SA Western Standard Time",
        "America/Porto_Acre": "SA Pacific Standard Time",
        "America/Porto_Velho": "SA Western Standard Time",
        "America/Puerto_Rico": "SA Western Standard Time",
        "America/Punta_Arenas": "Magallanes Standard Time",
        "America/Rainy_River": "Central Standard Time",
        "America/Rankin_Inlet": "Central Standard Time",
        "America/Recife": "SA Eastern Standard Time",
        "America/Regina": "Canada Central Standard Time",
        "America/Resolute": "Central Standard Time",
        "America/Rio_Branco": "SA Pacific Standard Time",
        "America/Rosario": "Argentina Standard Time",
        "America/Santa_Isabel": "Pacific Standard Time (Mexico)",
        "America/Santarem": "SA Eastern Standard Time",
        "America/Santiago": "Pacific SA Standard Time",
        "America/Santo_Domingo": "SA Western Standard Time",
        "America/Sao_Paulo": "E. South America Standard Time",
        "America/Scoresbysund": "Azores Standard Time",
        "America/Shiprock": "Mountain Standard Time",
        "America/Sitka": "Alaskan Standard Time",
        "America/St_Barthelemy": "SA Western Standard Time",
        "America/St_Johns": "Newfoundland Standard Time",
        "America/St_Kitts": "SA Western Standard Time",
        "America/St_Lucia": "SA Western Standard Time",
        "America/St_Thomas": "SA Western Standard Time",
        "America/St_Vincent": "SA Western Standard Time",
        "America/Swift_Current": "Canada Central Standard Time",
        "America/Tegucigalpa": "Central America Standard Time",
        "America/Thule": "Atlantic Standard Time",
        "America/Thunder_Bay": "Eastern Standard Time",
        "America/Tijuana": "Pacific Standard Time (Mexico)",
        "America/Toronto": "Eastern Standard Time",
        "America/Tortola": "SA Western Standard Time",
        "America/Vancouver": "Pacific Standard Time",
        "America/Virgin": "SA Western Standard Time",
        "America/Whitehorse": "Yukon Standard Time",
        "America/Winnipeg": "Central Standard Time",
        "America/Yakutat": "Alaskan Standard Time",
        "America/Yellowknife": "Mountain Standard Time",
        "Antarctica/Casey": "Central Pacific Standard Time",
        "Antarctica/Davis": "SE Asia Standard Time",
        "Antarctica/DumontDUrville": "West Pacific Standard Time",
        "Antarctica/Macquarie": "Tasmania Standard Time",
        "Antarctica/Mawson": "West Asia Standard Time",
        "Antarctica/McMurdo": "New Zealand Standard Time",
        "Antarctica/Palmer": "SA Eastern Standard Time",
        "Antarctica/Rothera": "SA Eastern Standard Time",
        "Antarctica/South_Pole": "New Zealand Standard Time",
        "Antarctica/Syowa": "E. Africa Standard Time",
        "Antarctica/Vostok": "Central Asia Standard Time",
        "Arctic/Longyearbyen": "W. Europe Standard Time",
        "Asia/Aden": "Arab Standard Time",
        "Asia/Almaty": "West Asia Standard Time",
        "Asia/Amman": "Jordan Standard Time",
        "Asia/Anadyr": "Russia Time Zone 11",
        "Asia/Aqtau": "West Asia Standard Time",
        "Asia/Aqtobe": "West Asia Standard Time",
        "Asia/Ashgabat": "West Asia Standard Time",
        "Asia/Ashkhabad": "West Asia Standard Time",
        "Asia/Atyrau": "West Asia Standard Time",
        "Asia/Baghdad": "Arabic Standard Time",
        "Asia/Bahrain": "Arab Standard Time",
        "Asia/Baku": "Azerbaijan Standard Time",
        "Asia/Bangkok": "SE Asia Standard Time",
        "Asia/Barnaul": "Altai Standard Time",
        "Asia/Beirut": "Middle East Standard Time",
        "Asia/Bishkek": "Central Asia Standard Time",
        "Asia/Brunei": "Singapore Standard Time",
        "Asia/Calcutta": "India Standard Time",
        "Asia/Chita": "Transbaikal Standard Time",
        "Asia/Choibalsan": "Ulaanbaatar Standard Time",
        "Asia/Chongqing": "China Standard Time",
        "Asia/Chungking": "China Standard Time",
        "Asia/Colombo": "Sri Lanka Standard Time",
        "Asia/Dacca": "Bangladesh Standard Time",
        "Asia/Damascus": "Syria Standard Time",
        "Asia/Dhaka": "Bangladesh Standard Time",
        "Asia/Dili": "Tokyo Standard Time",
        "Asia/Dubai": "Arabian Standard Time",
        "Asia/Dushanbe": "West Asia Standard Time",
        "Asia/Famagusta": "GTB Standard Time",
        "Asia/Gaza": "West Bank Standard Time",
        "Asia/Harbin": "China Standard Time",
        "Asia/Hebron": "West Bank Standard Time",
        "Asia/Ho_Chi_Minh": "SE Asia Standard Time",
        "Asia/Hong_Kong": "China Standard Time",
        "Asia/Hovd": "W. Mongolia Standard Time",
        "Asia/Irkutsk": "North Asia East Standard Time",
        "Asia/Istanbul": "Turkey Standard Time",
        "Asia/Jakarta": "SE Asia Standard Time",
        "Asia/Jayapura": "Tokyo Standard Time",
        "Asia/Jerusalem": "Israel Standard Time",
        "Asia/Kabul": "Afghanistan Standard Time",
        "Asia/Kamchatka": "Russia Time Zone 11",
        "Asia/Karachi": "Pakistan Standard Time",
        "Asia/Kashgar": "Central Asia Standard Time",
        "Asia/Kathmandu": "Nepal Standard Time",
        "Asia/Katmandu": "Nepal Standard Time",
        "Asia/Khandyga": "Yakutsk Standard Time",
        "Asia/Kolkata": "India Standard Time",
        "Asia/Krasnoyarsk": "North Asia Standard Time",
        "Asia/Kuala_Lumpur": "Singapore Standard Time",
        "Asia/Kuching": "Singapore Standard Time",
        "Asia/Kuwait": "Arab Standard Time",
        "Asia/Macao": "China Standard Time",
        "Asia/Macau": "China Standard Time",
        "Asia/Magadan": "Magadan Standard Time",
        "Asia/Makassar": "Singapore Standard Time",
        "Asia/Manila": "Singapore Standard Time",
        "Asia/Muscat": "Arabian Standard Time",
        "Asia/Nicosia": "GTB Standard Time",
        "Asia/Novokuznetsk": "North Asia Standard Time",
        "Asia/Novosibirsk": "N. Central Asia Standard Time",
        "Asia/Omsk": "Omsk Standard Time",
        "Asia/Oral": "West Asia Standard Time",
        "Asia/Phnom_Penh": "SE Asia Standard Time",
        "Asia/Pontianak": "SE Asia Standard Time",
        "Asia/Pyongyang": "North Korea Standard Time",
        "Asia/Qatar": "Arab Standard Time",
        "Asia/Qostanay": "West Asia Standard Time",
        "Asia/Qyzylorda": "Qyzylorda Standard Time",
        "Asia/Rangoon": "Myanmar Standard Time",
        "Asia/Riyadh": "Arab Standard Time",
        "Asia/Saigon": "SE Asia Standard Time",
        "Asia/Sakhalin": "Sakhalin Standard Time",
        "Asia/Samarkand": "West Asia Standard Time",
        "Asia/Seoul": "Korea Standard Time",
        "Asia/Shanghai": "China Standard Time",
        "Asia/Singapore": "Singapore Standard Time",
        "Asia/Srednekolymsk": "Russia Time Zone 10",
        "Asia/Taipei": "Taipei Standard Time",
        "Asia/Tashkent": "West Asia Standard Time",
        "Asia/Tbilisi": "Georgian Standard Time",
        "Asia/Tehran": "Iran Standard Time",
        "Asia/Tel_Aviv": "Israel Standard Time",
        "Asia/Thimbu": "Bangladesh Standard Time",
        "Asia/Thimphu": "Bangladesh Standard Time",
        "Asia/Tokyo": "Tokyo Standard Time",
        "Asia/Tomsk": "Tomsk Standard Time",
        "Asia/Ujung_Pandang": "Singapore Standard Time",
        "Asia/Ulaanbaatar": "Ulaanbaatar Standard Time",
        "Asia/Ulan_Bator": "Ulaanbaatar Standard Time",
        "Asia/Urumqi": "Central Asia Standard Time",
        "Asia/Ust-Nera": "Vladivostok Standard Time",
        "Asia/Vientiane": "SE Asia Standard Time",
        "Asia/Vladivostok": "Vladivostok Standard Time",
        "Asia/Yakutsk": "Yakutsk Standard Time",
        "Asia/Yangon": "Myanmar Standard Time",
        "Asia/Yekaterinburg": "Ekaterinburg Standard Time",
        "Asia/Yerevan": "Caucasus Standard Time",
        "Atlantic/Azores": "Azores Standard Time",
        "Atlantic/Bermuda": "Atlantic Standard Time",
        "Atlantic/Canary": "GMT Standard Time",
        "Atlantic/Cape_Verde": "Cape Verde Standard Time",
        "Atlantic/Faeroe": "GMT Standard Time",
        "Atlantic/Faroe": "GMT Standard Time",
        "Atlantic/Madeira": "GMT Standard Time",
        "Atlantic/Reykjavik": "Greenwich Standard Time",
        "Atlantic/South_Georgia": "UTC-02",
        "Atlantic/St_Helena": "Greenwich Standard Time",
        "Atlantic/Stanley": "SA Eastern Standard Time",
        "Australia/ACT": "AUS Eastern Standard Time",
        "Australia/Adelaide": "Cen. Australia Standard Time",
        "Australia/Brisbane": "E. Australia Standard Time",
        "Australia/Broken_Hill": "Cen. Australia Standard Time",
        "Australia/Canberra": "AUS Eastern Standard Time",
        "Australia/Currie": "Tasmania Standard Time",
        "Australia/Darwin": "AUS Central Standard Time",
        "Australia/Eucla": "Aus Central W. Standard Time",
        "Australia/Hobart": "Tasmania Standard Time",
        "Australia/LHI": "Lord Howe Standard Time",
        "Australia/Lindeman": "E. Australia Standard Time",
        "Australia/Lord_Howe": "Lord Howe Standard Time",
        "Australia/Melbourne": "AUS Eastern Standard Time",
        "Australia/NSW": "AUS Eastern Standard Time",
        "Australia/North": "AUS Central Standard Time",
        "Australia/Perth": "W. Australia Standard Time",
        "Australia/Queensland": "E. Australia Standard Time",
        "Australia/South": "Cen. Australia Standard Time",
        "Australia/Sydney": "AUS Eastern Standard Time",
        "Australia/Tasmania": "Tasmania Standard Time",
        "Australia/Victoria": "AUS Eastern Standard Time",
        "Australia/West": "W. Australia Standard Time",
        "Australia/Yancowinna": "Cen. Australia Standard Time",
        "Brazil/Acre": "SA Pacific Standard Time",
        "Brazil/DeNoronha": "UTC-02",
        "Brazil/East": "E. South America Standard Time",
        "Brazil/West": "SA Western Standard Time",
        "CST6CDT": "Central Standard Time",
        "Canada/Atlantic": "Atlantic Standard Time",
        "Canada/Central": "Central Standard Time",
        "Canada/Eastern": "Eastern Standard Time",
        "Canada/Mountain": "Mountain Standard Time",
        "Canada/Newfoundland": "Newfoundland Standard Time",
        "Canada/Pacific": "Pacific Standard Time",
        "Canada/Saskatchewan": "Canada Central Standard Time",
        "Canada/Yukon": "Yukon Standard Time",
        "Chile/Continental": "Pacific SA Standard Time",
        "Chile/EasterIsland": "Easter Island Standard Time",
        "Cuba": "Cuba Standard Time",
        "EET": "GTB Standard Time",
        "EST": "SA Pacific Standard Time",
        "EST5EDT": "Eastern Standard Time",
        "Egypt": "Egypt Standard Time",
        "Eire": "GMT Standard Time",
        "Etc/GMT": "UTC",
        "Etc/GMT+0": "UTC",
        "Etc/GMT+1": "Cape Verde Standard Time",
        "Etc/GMT+10": "Hawaiian Standard Time",
        "Etc/GMT+11": "UTC-11",
        "Etc/GMT+12": "Dateline Standard Time",
        "Etc/GMT+2": "UTC-02",
        "Etc/GMT+3": "SA Eastern Standard Time",
        "Etc/GMT+4": "SA Western Standard Time",
        "Etc/GMT+5": "SA Pacific Standard Time",
        "Etc/GMT+6": "Central America Standard Time",
        "Etc/GMT+7": "US Mountain Standard Time",
        "Etc/GMT+8": "UTC-08",
        "Etc/GMT+9": "UTC-09",
        "Etc/GMT-0": "UTC",
        "Etc/GMT-1": "W. Central Africa Standard Time",
        "Etc/GMT-10": "West Pacific Standard Time",
        "Etc/GMT-11": "Central Pacific Standard Time",
        "Etc/GMT-12": "UTC+12",
        "Etc/GMT-13": "UTC+13",
        "Etc/GMT-14": "Line Islands Standard Time",
        "Etc/GMT-2": "South Africa Standard Time",
        "Etc/GMT-3": "E. Africa Standard Time",
        "Etc/GMT-4": "Arabian Standard Time",
        "Etc/GMT-5": "West Asia Standard Time",
        "Etc/GMT-6": "Central Asia Standard Time",
        "Etc/GMT-7": "SE Asia Standard Time",
        "Etc/GMT-8": "Singapore Standard Time",
        "Etc/GMT-9": "Tokyo Standard Time",
        "Etc/GMT0": "UTC",
        "Etc/Greenwich": "UTC",
        "Etc/UCT": "UTC",
        "Etc/UTC": "UTC",
        "Etc/Universal": "UTC",
        "Etc/Zulu": "UTC",
        "Europe/Amsterdam": "W. Europe Standard Time",
        "Europe/Andorra": "W. Europe Standard Time",
        "Europe/Astrakhan": "Astrakhan Standard Time",
        "Europe/Athens": "GTB Standard Time",
        "Europe/Belfast": "GMT Standard Time",
        "Europe/Belgrade": "Central Europe Standard Time",
        "Europe/Berlin": "W. Europe Standard Time",
        "Europe/Bratislava": "Central Europe Standard Time",
        "Europe/Brussels": "Romance Standard Time",
        "Europe/Bucharest": "GTB Standard Time",
        "Europe/Budapest": "Central Europe Standard Time",
        "Europe/Busingen": "W. Europe Standard Time",
        "Europe/Chisinau": "E. Europe Standard Time",
        "Europe/Copenhagen": "Romance Standard Time",
        "Europe/Dublin": "GMT Standard Time",
        "Europe/Gibraltar": "W. Europe Standard Time",
        "Europe/Guernsey": "GMT Standard Time",
        "Europe/Helsinki": "FLE Standard Time",
        "Europe/Isle_of_Man": "GMT Standard Time",
        "Europe/Istanbul": "Turkey Standard Time",
        "Europe/Jersey": "GMT Standard Time",
        "Europe/Kaliningrad": "Kaliningrad Standard Time",
        "Europe/Kiev": "FLE Standard Time",
        "Europe/Kirov": "Russian Standard Time",
        "Europe/Kyiv": "FLE Standard Time",
        "Europe/Lisbon": "GMT Standard Time",
        "Europe/Ljubljana": "Central Europe Standard Time",
        "Europe/London": "GMT Standard Time",
        "Europe/Luxembourg": "W. Europe Standard Time",
        "Europe/Madrid": "Romance Standard Time",
        "Europe/Malta": "W. Europe Standard Time",
        "Europe/Mariehamn": "FLE Standard Time",
        "Europe/Minsk": "Belarus Standard Time",
        "Europe/Monaco": "W. Europe Standard Time",
        "Europe/Moscow": "Russian Standard Time",
        "Europe/Nicosia": "GTB Standard Time",
        "Europe/Oslo": "W. Europe Standard Time",
        "Europe/Paris": "Romance Standard Time",
        "Europe/Podgorica": "Central Europe Standard Time",
        "Europe/Prague": "Central Europe Standard Time",
        "Europe/Riga": "FLE Standard Time",
        "Europe/Rome": "W. Europe Standard Time",
        "Europe/Samara": "Russia Time Zone 3",
        "Europe/San_Marino": "W. Europe Standard Time",
        "Europe/Sarajevo": "Central European Standard Time",
        "Europe/Saratov": "Saratov Standard Time",
        "Europe/Simferopol": "Russian Standard Time",
        "Europe/Skopje": "Central European Standard Time",
        "Europe/Sofia": "FLE Standard Time",
        "Europe/Stockholm": "W. Europe Standard Time",
        "Europe/Tallinn": "FLE Standard Time",
        "Europe/Tirane": "Central Europe Standard Time",
        "Europe/Tiraspol": "E. Europe Standard Time",
        "Europe/Ulyanovsk": "Astrakhan Standard Time",
        "Europe/Uzhgorod": "FLE Standard Time",
        "Europe/Vaduz": "W. Europe Standard Time",
        "Europe/Vatican": "W. Europe Standard Time",
        "Europe/Vienna": "W. Europe Standard Time",
        "Europe/Vilnius": "FLE Standard Time",
        "Europe/Volgograd": "Volgograd Standard Time",
        "Europe/Warsaw": "Central European Standard Time",
        "Europe/Zagreb": "Central European Standard Time",
        "Europe/Zaporozhye": "FLE Standard Time",
        "Europe/Zurich": "W. Europe Standard Time",
        "GB": "GMT Standard Time",
        "GB-Eire": "GMT Standard Time",
        "GMT": "UTC",
        "GMT+0": "UTC",
        "GMT-0": "UTC",
        "GMT0": "UTC",
        "Greenwich": "UTC",
        "HST": "Hawaiian Standard Time",
        "Hongkong": "China Standard Time",
        "Iceland": "Greenwich Standard Time",
        "Indian/Antananarivo": "E. Africa Standard Time",
        "Indian/Chagos": "Central Asia Standard Time",
        "Indian/Christmas": "SE Asia Standard Time",
        "Indian/Cocos": "Myanmar Standard Time",
        "Indian/Comoro": "E. Africa Standard Time",
        "Indian/Kerguelen": "West Asia Standard Time",
        "Indian/Mahe": "Mauritius Standard Time",
        "Indian/Maldives": "West Asia Standard Time",
        "Indian/Mauritius": "Mauritius Standard Time",
        "Indian/Mayotte": "E. Africa Standard Time",
        "Indian/Reunion": "Mauritius Standard Time",
        "Iran": "Iran Standard Time",
        "Israel": "Israel Standard Time",
        "Jamaica": "SA Pacific Standard Time",
        "Japan": "Tokyo Standard Time",
        "Kwajalein": "UTC+12",
        "Libya": "Libya Standard Time",
        "MST": "US Mountain Standard Time",
        "MST7MDT": "Mountain Standard Time",
        "Mexico/BajaNorte": "Pacific Standard Time (Mexico)",
        "Mexico/BajaSur": "Mountain Standard Time (Mexico)",
        "Mexico/General": "Central Standard Time (Mexico)",
        "NZ": "New Zealand Standard Time",
        "NZ-CHAT": "Chatham Islands Standard Time",
        "Navajo": "Mountain Standard Time",
        "PRC": "China Standard Time",
        "PST8PDT": "Pacific Standard Time",
        "Pacific/Apia": "Samoa Standard Time",
        "Pacific/Auckland": "New Zealand Standard Time",
        "Pacific/Bougainville": "Bougainville Standard Time",
        "Pacific/Chatham": "Chatham Islands Standard Time",
        "Pacific/Chuuk": "West Pacific Standard Time",
        "Pacific/Easter": "Easter Island Standard Time",
        "Pacific/Efate": "Central Pacific Standard Time",
        "Pacific/Enderbury": "UTC+13",
        "Pacific/Fakaofo": "UTC+13",
        "Pacific/Fiji": "Fiji Standard Time",
        "Pacific/Funafuti": "UTC+12",
        "Pacific/Galapagos": "Central America Standard Time",
        "Pacific/Gambier": "UTC-09",
        "Pacific/Guadalcanal": "Central Pacific Standard Time",
        "Pacific/Guam": "West Pacific Standard Time",
        "Pacific/Honolulu": "Hawaiian Standard Time",
        "Pacific/Johnston": "Hawaiian Standard Time",
        "Pacific/Kanton": "UTC+13",
        "Pacific/Kiritimati": "Line Islands Standard Time",
        "Pacific/Kosrae": "Central Pacific Standard Time",
        "Pacific/Kwajalein": "UTC+12",
        "Pacific/Majuro": "UTC+12",
        "Pacific/Marquesas": "Marquesas Standard Time",
        "Pacific/Midway": "UTC-11",
        "Pacific/Nauru": "UTC+12",
        "Pacific/Niue": "UTC-11",
        "Pacific/Norfolk": "Norfolk Standard Time",
        "Pacific/Noumea": "Central Pacific Standard Time",
        "Pacific/Pago_Pago": "UTC-11",
        "Pacific/Palau": "Tokyo Standard Time",
        "Pacific/Pitcairn": "UTC-08",
        "Pacific/Pohnpei": "Central Pacific Standard Time",
        "Pacific/Ponape": "Central Pacific Standard Time",
        "Pacific/Port_Moresby": "West Pacific Standard Time",
        "Pacific/Rarotonga": "Hawaiian Standard Time",
        "Pacific/Saipan": "West Pacific Standard Time",
        "Pacific/Samoa": "UTC-11",
        "Pacific/Tahiti": "Hawaiian Standard Time",
        "Pacific/Tarawa": "UTC+12",
        "Pacific/Tongatapu": "Tonga Standard Time",
        "Pacific/Truk": "West Pacific Standard Time",
        "Pacific/Wake": "UTC+12",
        "Pacific/Wallis": "UTC+12",
        "Pacific/Yap": "West Pacific Standard Time",
        "Poland": "Central European Standard Time",
        "Portugal": "GMT Standard Time",
        "ROC": "Taipei Standard Time",
        "ROK": "Korea Standard Time",
        "Singapore": "Singapore Standard Time",
        "Turkey": "Turkey Standard Time",
        "UCT": "UTC",
        "US/Alaska": "Alaskan Standard Time",
        "US/Aleutian": "Aleutian Standard Time",
        "US/Arizona": "US Mountain Standard Time",
        "US/Central": "Central Standard Time",
        "US/East-Indiana": "US Eastern Standard Time",
        "US/Eastern": "Eastern Standard Time",
        "US/Hawaii": "Hawaiian Standard Time",
        "US/Indiana-Starke": "Central Standard Time",
        "US/Michigan": "Eastern Standard Time",
        "US/Mountain": "Mountain Standard Time",
        "US/Pacific": "Pacific Standard Time",
        "US/Samoa": "UTC-11",
        "UTC": "UTC",
        "Universal": "UTC",
        "W-SU": "Russian Standard Time",
        "WET": "GMT Standard Time",
        "Zulu": "UTC",
    ]
}
