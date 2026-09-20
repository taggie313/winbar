import Foundation
import Testing
@testable import Winbar

// The Mac's regional values in Windows' terms. Pure mappings: nothing here reads this Mac's settings.

@Suite struct RegionalLocales {
    func locale(_ identifier: String) -> (user: String?, system: String?) {
        Regional.windowsLocale(fromMac: identifier)
    }

    @Test func everydayMacLocales() {
        #expect(locale("en_US") == ("en-US", "en-US"))
        #expect(locale("en_GB") == ("en-GB", "en-GB"))
        #expect(locale("en-GB") == ("en-GB", "en-GB"))
        #expect(locale("es_ES") == ("es-ES", "es-ES"))
        #expect(locale("fr_CA") == ("fr-CA", "fr-CA"))
        #expect(locale("pt_BR") == ("pt-BR", "pt-BR"))
        #expect(locale("de_CH") == ("de-CH", "de-CH"))
    }

    /// Keywords are a Mac idea (`@rg=` is a formats override); Windows just wants the locale name.
    @Test func dropsKeywords() {
        #expect(locale("en_US@rg=gbzzzz") == ("en-US", "en-US"))
        #expect(locale("en_GB@calendar=gregorian;numbers=latn") == ("en-GB", "en-GB"))
    }

    /// Windows spells Chinese by region, not by script (D5).
    @Test func chineseScripts() {
        #expect(locale("zh-Hans_CN") == ("zh-CN", "zh-CN"))
        #expect(locale("zh-Hans") == ("zh-CN", "zh-CN"))
        #expect(locale("zh-Hans_SG") == ("zh-CN", "zh-CN"))
        #expect(locale("zh-Hant_TW") == ("zh-TW", "zh-TW"))
        #expect(locale("zh-Hant") == ("zh-TW", "zh-TW"))
        #expect(locale("zh-Hant_HK") == ("zh-HK", "zh-HK"))
        #expect(locale("zh-Hant_MO") == ("zh-HK", "zh-HK"))
        #expect(locale("zh_CN") == ("zh-CN", "zh-CN"))
        #expect(locale("zh_TW") == ("zh-TW", "zh-TW"))
    }

    /// Windows' own names carry a script for some languages; the Mac's usually don't.
    @Test func scriptsWindowsKeeps() {
        #expect(locale("sr-Latn_RS") == ("sr-Latn-RS", "sr-Latn-RS"))
        #expect(locale("sr-Cyrl_RS") == ("sr-Cyrl-RS", "sr-Cyrl-RS"))
        #expect(locale("sr_RS") == ("sr-Cyrl-RS", "sr-Cyrl-RS"))
        #expect(locale("uz_UZ") == ("uz-Latn-UZ", "uz-Latn-UZ"))
        #expect(locale("bs_BA") == ("bs-Latn-BA", "bs-Latn-BA"))
        #expect(locale("az_AZ") == ("az-Latn-AZ", "az-Latn-AZ"))
        #expect(locale("mn_MN") == ("mn-MN", "mn-MN"))
    }

    /// A numeric region can be the formats locale but never the language for non-Unicode programs.
    @Test func numericRegions() {
        #expect(locale("es_419") == ("es-419", nil))
        #expect(locale("es-419") == ("es-419", nil))
        #expect(locale("en_150") == (nil, nil))
    }

    /// Windows has no locale at all: the caller uses the image language for both.
    @Test func noWindowsMatch() {
        #expect(locale("en_ES") == (nil, nil))
        #expect(locale("tlh_Piqd_KL") == (nil, nil))
        #expect(locale("en") == (nil, nil))
        #expect(locale("") == (nil, nil))
        #expect(locale("root") == (nil, nil))
    }
}

@Suite struct RegionalTimeZones {
    @Test func mapsIANAZones() {
        #expect(Regional.windowsTimeZone(forIANA: "Europe/London") == "GMT Standard Time")
        #expect(Regional.windowsTimeZone(forIANA: "America/Detroit") == "Eastern Standard Time")
        #expect(Regional.windowsTimeZone(forIANA: "America/New_York") == "Eastern Standard Time")
        #expect(Regional.windowsTimeZone(forIANA: "Europe/Madrid") == "Romance Standard Time")
        #expect(Regional.windowsTimeZone(forIANA: "Asia/Tokyo") == "Tokyo Standard Time")
        #expect(Regional.windowsTimeZone(forIANA: "Australia/Sydney") == "AUS Eastern Standard Time")
        #expect(Regional.windowsTimeZone(forIANA: "UTC") == "UTC")
    }

    /// CLDR still uses the old ids; macOS reports the new ones.
    @Test func mapsRenamedZones() {
        #expect(Regional.windowsTimeZone(forIANA: "Asia/Kolkata") == "India Standard Time")
        #expect(Regional.windowsTimeZone(forIANA: "Asia/Calcutta") == "India Standard Time")
        #expect(Regional.windowsTimeZone(forIANA: "Europe/Kyiv") == "FLE Standard Time")
        #expect(Regional.windowsTimeZone(forIANA: "America/Nuuk") == "Greenland Standard Time")
        #expect(Regional.windowsTimeZone(forIANA: "US/Eastern") == "Eastern Standard Time")
    }

    @Test func unmappableZonesHaveNoWindowsId() {
        #expect(Regional.windowsTimeZone(forIANA: "Mars/Olympus_Mons") == nil)
        #expect(Regional.windowsTimeZone(forIANA: "Factory") == nil)
        #expect(Regional.windowsTimeZone(forIANA: "") == nil)
    }

    /// Every id the table produces is a Windows zone the renderer accepts.
    @Test func everyMappedZoneIsAWindowsZone() {
        #expect(Regional.windowsTimeZones.count > 100)
        #expect(Set(Regional.windowsZoneForIANA.values).isSubset(of: Regional.windowsTimeZones))
        #expect(Regional.windowsZoneForIANA.count > 500)
    }
}

@Suite struct RegionalKeyboards {
    func layout(_ id: String) -> Regional.Keyboard {
        Regional.keyboard(currentLayoutID: "com.apple.keylayout." + id, selectedSources: [])
    }

    @Test func mapsMacLayoutsToWindowsLayouts() {
        #expect(layout("US").inputLocale == "0409:00000409")
        #expect(layout("ABC").inputLocale == "0409:00000409")
        #expect(layout("British").inputLocale == "0809:00000809")
        #expect(layout("German").inputLocale == "0407:00000407")
        #expect(layout("French").inputLocale == "040c:0000040c")
        #expect(layout("Spanish-ISO").inputLocale == "0c0a:0000040a")
        #expect(layout("Italian-Pro").inputLocale == "0410:00000410")
        #expect(layout("SwissGerman").inputLocale == "0807:00000807")
        #expect(layout("Dutch").inputLocale == "0413:00000413")
        #expect(layout("Belgian").inputLocale == "080c:0000080c")
        #expect(layout("Danish").inputLocale == "0406:00000406")
        #expect(layout("Norwegian").inputLocale == "0414:00000414")
        #expect(layout("Swedish-Pro").inputLocale == "041d:0000041d")
        #expect(layout("Finnish").inputLocale == "040b:0000040b")
        #expect(layout("Portuguese").inputLocale == "0816:00000816")
        #expect(layout("Brazilian-ABNT2").inputLocale == "0416:00000416")
        #expect(layout("Canadian-CSA").inputLocale == "0c0c:00011009")
        #expect(layout("PolishPro").inputLocale == "0415:00000415")
        #expect(layout("Czech").inputLocale == "0405:00000405")
        #expect(layout("Dvorak").inputLocale == "0409:00010409")
        #expect(layout("British").macName == "British")
    }

    /// Every entry is either a language tag or LCID:KLID, which is what the answer file accepts.
    @Test func everyInputLocaleIsWellFormed() throws {
        for (id, entry) in Regional.keyboardLayouts {
            guard let inputLocale = entry.inputLocale else { continue }
            let parts = inputLocale.split(separator: ":")
            #expect(parts.count == 2, "\(id)")
            #expect(parts[0].count == 4 && parts[1].count == 8, "\(id)")
            #expect(inputLocale.allSatisfy { $0.isHexDigit || $0 == ":" }, "\(id)")
            #expect(inputLocale == inputLocale.lowercased(), "\(id)")
        }
        for method in Regional.inputMethods {
            #expect(AnswerFile.isInputLocale(method.tag), "\(method.tag)")
        }
    }

    /// Layouts Windows hasn't got: the ISO's keyboard is used instead, and the person is told.
    @Test func layoutsWithoutAWindowsEquivalent() {
        #expect(layout("USExtended").inputLocale == nil)
        #expect(layout("USExtended").macName == "ABC – Extended")
        #expect(layout("Colemak").inputLocale == nil)
        // An unknown id falls back to the name macOS has selected, or to the id itself.
        let unknown = Regional.keyboard(currentLayoutID: "com.apple.keylayout.Klingon",
                                        selectedSources: [["InputSourceKind": "Keyboard Layout", "KeyboardLayout Name": "Klingon"]])
        #expect(unknown == Regional.Keyboard(macName: "Klingon", inputLocale: nil))
        #expect(Regional.keyboard(currentLayoutID: nil, selectedSources: []).inputLocale == nil)
    }

    /// Japanese, Korean and Chinese are typed with an input method; Windows takes the language's tag and
    /// gives it its own IME. The keyboard layout under the input method (usually ABC) isn't the answer.
    @Test func inputMethodsBeatTheLayout() {
        let japanese: [[String: Any]] = [
            ["InputSourceKind": "Keyboard Layout", "KeyboardLayout Name": "U.S."],
            ["InputSourceKind": "Input Mode", "Bundle ID": "com.apple.inputmethod.Kotoeri.RomajiTyping",
             "Input Mode": "com.apple.inputmethod.Japanese"],
        ]
        #expect(Regional.keyboard(currentLayoutID: "com.apple.keylayout.ABC", selectedSources: japanese)
                == Regional.Keyboard(macName: "Japanese", inputLocale: "ja-JP"))
        let korean: [[String: Any]] = [["Bundle ID": "com.apple.inputmethod.Korean", "InputSourceKind": "Keyboard Input Method"]]
        #expect(Regional.keyboard(currentLayoutID: "com.apple.keylayout.ABC", selectedSources: korean).inputLocale == "ko-KR")
        let simplified: [[String: Any]] = [["Input Mode": "com.apple.inputmethod.SCIM.ITABC", "InputSourceKind": "Input Mode"]]
        #expect(Regional.keyboard(currentLayoutID: "com.apple.keylayout.ABC", selectedSources: simplified).inputLocale == "zh-CN")
        // A Mac with only PressAndHold selected is still a plain keyboard layout.
        let plain: [[String: Any]] = [["Bundle ID": "com.apple.PressAndHold", "InputSourceKind": "Non Keyboard Input Method"]]
        #expect(Regional.keyboard(currentLayoutID: "com.apple.keylayout.British", selectedSources: plain).inputLocale == "0809:00000809")
    }
}

@Suite struct RegionalReadings {
    let english = Locale(identifier: "en_US")

    func reading(locale: String, layout: String, zone: String, image: String = "en-US") -> Regional.Reading {
        Regional.reading(macLocale: locale,
                         keyboard: Regional.keyboard(currentLayoutID: "com.apple.keylayout." + layout, selectedSources: []),
                         ianaZone: zone, imageLanguage: image, displayLocale: english)
    }

    @Test func aBritishMac() {
        let found = reading(locale: "en_GB", layout: "British", zone: "Europe/London")
        #expect(found.values == RegionalValues(userLocale: "en-GB", systemLocale: "en-GB", inputLocale: "0809:00000809",
                                               timeZone: "GMT Standard Time",
                                               summary: "English (United Kingdom) · British · GMT Standard Time"))
        #expect(found.notes.isEmpty)
    }

    @Test func aMacWithNothingWindowsKnows() {
        let found = reading(locale: "en_ES", layout: "USExtended", zone: "Mars/Olympus_Mons")
        #expect(found.values.userLocale == "en-US")
        #expect(found.values.systemLocale == "en-US")
        #expect(found.values.inputLocale == nil)
        #expect(found.values.timeZone == nil)
        #expect(found.notes.count == 3)
        #expect("\(found.notes[0])".hasPrefix("Windows has no match for this Mac's region"))
        #expect("\(found.notes[1])".contains("(ABC – Extended) has no Windows equivalent"))
        #expect("\(found.notes[2])".hasPrefix("Windows has no time zone matching Mars/Olympus_Mons"))
        #expect(found.values.summary == "English (United States) · English (United States) keyboard · Windows' default time zone")
    }

    /// Formats Windows can show but not use as its non-Unicode language.
    @Test func aLatinAmericanMac() {
        let found = reading(locale: "es_419", layout: "LatinAmerican", zone: "America/Mexico_City")
        #expect(found.values.userLocale == "es-419")
        #expect(found.values.systemLocale == "en-US")
        #expect(found.values.inputLocale == "080a:0000080a")
        #expect(found.values.timeZone == "Central Standard Time (Mexico)")
        #expect(found.notes.count == 1)
        #expect("\(found.notes[0])".contains("programs that don't support Unicode"))
    }

    /// Whatever the Mac says, the values must pass the answer file's own validation.
    @Test func readingsAlwaysRenderable() throws {
        for (locale, layout, zone) in [("en_GB", "British", "Europe/London"), ("de_DE", "German", "Europe/Berlin"),
                                       ("ja_JP", "US", "Asia/Tokyo"), ("es_419", "LatinAmerican", "America/Mexico_City"),
                                       ("en_ES", "USExtended", "Mars/Olympus_Mons"), ("zh-Hans_CN", "US", "Asia/Shanghai")] {
            var plan = TestPlan.plan()
            plan.regional = reading(locale: locale, layout: layout, zone: zone).values
            let files = try AnswerFile.render(plan: plan, image: TestPlan.image, password: "Winbar-Test-Pa55!")
            #expect(files.count == 2, "\(locale)")
        }
    }
}
