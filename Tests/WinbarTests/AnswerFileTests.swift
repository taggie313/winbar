import Foundation
import Testing
@testable import Winbar

// The answer file, against its oracle. `Fixtures/answerfile` holds files written by the Python reference
// renderer with a dummy password: golden Autounattend.xml files, a hash of every option combination, and
// copies of the template and FirstLogon.ps1. Pure logic: nothing here touches UTM, a VM or the Mac's own
// settings, and no real password ever appears.

enum Fixture {
    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/answerfile", isDirectory: true)

    static func text(_ name: String) throws -> String {
        try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
    }

    struct Cases: Decodable {
        struct Case: Decodable {
            let name: String
            let options: [String: Int]
            let values: [String: String]
            let password: String
            let warnings: [String]
            let effectiveOptions: [String: Int]
            let effectiveValues: [String: String]
            let summary: String
        }

        struct ComputerName: Decodable {
            let vm: String
            let user: String
            let name: String
        }

        struct MatrixCase: Decodable {
            let name: String
            let bits: String
            let noVisualTweaks: Bool
            let fnv: String
        }

        let password: String
        let hostilePassword: String
        let unlocked: [String]
        let dummyValues: [String: String]
        let cases: [Case]
        let computerNames: [ComputerName]
        let reservedUsers: [String]
        let matrix: [MatrixCase]
    }

    static let cases: Cases = {
        let data = try! Data(contentsOf: directory.appendingPathComponent("cases.json"))
        return try! JSONDecoder().decode(Cases.self, from: data)
    }()

    /// The oracle's inputs for one case: its dummy values with the case's overrides.
    static func inputs(_ testCase: Cases.Case) -> AnswerFile.Inputs {
        AnswerFile.Inputs(options: testCase.options.mapValues { $0 != 0 },
                          values: cases.dummyValues.merging(testCase.values) { _, new in new })
    }

    /// Same hash as the generator's, so a whole matrix of renders fits in one small file.
    static func fnv1a64(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in Array(text.utf8) { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return String(format: "%016lx", hash)
    }
}

@Suite struct AnswerFileGoldens {
    @Test func rendersWhatRenderPyRenders() throws {
        for testCase in Fixture.cases.cases {
            let result = try AnswerFile.renderChecked(Fixture.inputs(testCase), password: testCase.password)
            #expect(result.xml == (try Fixture.text(testCase.name + ".xml")), "\(testCase.name) differs from the oracle")
            #expect(result.warnings == testCase.warnings, "\(testCase.name) warnings")
            #expect(result.summary == testCase.summary, "\(testCase.name) summary")
        }
    }

    @Test func effectiveMatchesTheOracle() throws {
        for testCase in Fixture.cases.cases {
            let (effective, _) = try AnswerFile.effective(Fixture.inputs(testCase))
            #expect(effective.options == testCase.effectiveOptions.mapValues { $0 != 0 }, "\(testCase.name) options")
            #expect(effective.values == testCase.effectiveValues, "\(testCase.name) values")
        }
    }

    /// Every combination of the unlocked options, and of --no-visual-tweaks with tuning on: 384 renders,
    /// compared with the oracle's by hash so the fixtures stay small.
    @Test func everyOptionCombinationMatchesTheOracle() throws {
        var options: [String: Bool] = ["computer_name": true]
        for option in CreateOption.allCases { options[option.rawValue] = true }
        for matrixCase in Fixture.cases.matrix {
            var combination = options
            for (id, bit) in zip(Fixture.cases.unlocked, matrixCase.bits) { combination[id] = bit == "1" }
            combination["no_visual_tweaks"] = matrixCase.noVisualTweaks
            let inputs = AnswerFile.Inputs(options: combination, values: Fixture.cases.dummyValues)
            let result = try AnswerFile.renderChecked(inputs, password: Fixture.cases.password)
            #expect(Fixture.fnv1a64(result.xml) == matrixCase.fnv, "\(matrixCase.name) differs from the oracle")
        }
    }

    @Test func templateAndScriptAreTheOracleFiles() throws {
        #expect(AnswerFile.template == (try Fixture.text("Autounattend.template.xml")))
        #expect(AnswerFile.firstLogonScript == (try Fixture.text("FirstLogon.ps1")))
    }

    /// FirstLogon.ps1 is static and ASCII: Windows PowerShell 5.1 reads it the same with or without a BOM,
    /// and it never carries a value of its own (the options arrive as the launcher's switches).
    @Test func firstLogonScriptIsStaticASCII() {
        let script = AnswerFile.firstLogonScript
        #expect(script.allSatisfy { $0.isASCII })
        #expect(!script.contains("{{"))
        #expect(script.hasSuffix("\n"))
    }

    /// The script applies the same tuning as `winbar setup`, so create and setup can't drift apart.
    @Test func firstLogonScriptUsesTheTuningValues() {
        let script = AnswerFile.firstLogonScript
        #expect(script.contains(Tuning.balancedScheme))
        for (setting, value) in Tuning.processor {
            #expect(script.contains("SUB_PROCESSOR \(setting) \(value)"), "\(setting)")
        }
        #expect(script.contains("powercfg /change monitor-timeout-ac \(Tuning.monitorTimeoutMinutes)"))
        #expect(script.contains("powercfg /change standby-timeout-ac \(Tuning.standbyTimeoutMinutes)"))
        #expect(script.contains("powercfg /change disk-timeout-ac \(Tuning.diskTimeoutMinutes)"))
        #expect(script.contains("PBUTTONACTION \(Tuning.powerButtonShutDown)"))
        #expect(script.contains(Tuning.disabledServices.map { "'\($0)'" }.joined(separator: ", ")))
        #expect(script.contains(Tuning.rdpFirewallGroup))
        for setting in Tuning.visualEffects {
            #expect(script.contains("SetUserValue '\(setting.key)' '\(setting.name)' '\(setting.kind.rawValue)'"),
                    "\(setting.name)")
        }
        for edition in Tuning.homeEditions { #expect(script.contains("'\(edition)'"), "\(edition)") }
    }

    /// The computer name Winbar derives is the one the Python renderer derives, for every shape of VM name.
    @Test func computerNamesMatchTheOracle() {
        for example in Fixture.cases.computerNames {
            #expect(CreateChoices.deriveComputerName(vmName: example.vm, userName: example.user) == example.name,
                    "\(example.vm)")
        }
    }

    /// Every switch the launcher can pass is one FirstLogon.ps1 declares: an unknown switch would be a
    /// parameter-binding error, and then no status file and no guest agent.
    @Test func theScriptTakesEveryLauncherSwitch() {
        let parameters = AnswerFile.firstLogonScript
        for name in AnswerFile.launcherSwitches.map(\.name) + ["-NoVisualTweaks"] {
            #expect(parameters.contains("[switch]$" + name.dropFirst()), "\(name)")
        }
    }

    /// The reserved names are the oracle's: Rufus's list, schneegans' and the local groups.
    @Test func reservedUserNamesAreTheOracles() {
        #expect(CreateChoices.reservedUserNames == Set(Fixture.cases.reservedUsers))
    }

    /// Windows SIM's obscured form: base64(UTF-16LE(value + element name)). Microsoft's own sample value
    /// decodes to "pwPassword".
    @Test func obscuresLikeWindowsSIM() {
        #expect(AnswerFile.obscure("pw") == "cAB3AFAAYQBzAHMAdwBvAHIAZAA=")
        let decoded = Data(base64Encoded: AnswerFile.obscure("Winbar-Test-Pa55!")).map {
            String(data: $0, encoding: .utf16LittleEndian)
        }
        #expect(decoded == "Winbar-Test-Pa55!Password")
    }

    /// The CD's root: the answer file with CRLF line endings, then the script, byte for byte.
    @Test func makesTheCDRootFromAPlan() throws {
        let files = try AnswerFile.render(plan: TestPlan.plan(), image: TestPlan.image, password: Fixture.cases.password)
        #expect(files.map(\.name) == ["Autounattend.xml", "FirstLogon.ps1"])
        let golden = try Fixture.text("default.xml").replacingOccurrences(of: "\n", with: "\r\n")
        #expect(files[0].contents == Data(golden.utf8))
        #expect(files[1].contents == Data(AnswerFile.firstLogonScript.utf8))
        #expect(!String(decoding: files[0].contents, as: UTF8.self).contains(Fixture.cases.password))
    }

    /// A plan's Home edition loses Remote Desktop, and its values reach the same file the oracle renders.
    @Test func planWithHomeEditionRendersLikeTheOracle() throws {
        var plan = TestPlan.plan()
        plan.edition = WindowsEdition(index: 1, name: "Windows 11 Home", displayName: "Windows 11 Home", editionID: "Core")
        let files = try AnswerFile.render(plan: plan, image: TestPlan.image, password: Fixture.cases.password)
        let golden = try Fixture.text("home-edition.xml").replacingOccurrences(of: "\n", with: "\r\n")
        #expect(files[0].contents == Data(golden.utf8))
    }

    /// No key is the default, and renders exactly the file Winbar rendered before keys existed: the golden is
    /// the one taken from the oracle then, and nothing about it moved.
    @Test func withoutAProductKeyTheFileIsUnchanged() throws {
        let files = try AnswerFile.render(plan: TestPlan.plan(), image: TestPlan.image,
                                          password: Fixture.cases.password)
        let golden = try Fixture.text("default.xml").replacingOccurrences(of: "\n", with: "\r\n")
        #expect(files[0].contents == Data(golden.utf8))
        // Passing nil explicitly is the same as not passing one at all.
        let explicitlyNone = try AnswerFile.render(plan: TestPlan.plan(), image: TestPlan.image,
                                                   password: Fixture.cases.password, productKey: nil)
        #expect(explicitlyNone[0].contents == files[0].contents)
        #expect(String(decoding: files[0].contents, as: UTF8.self).contains("<Key />\r\n"))
    }

    /// With one, the key goes into the <Key> the template already had, and that is the only thing that changes:
    /// the edition still comes from /IMAGE/INDEX.
    @Test func aProductKeyChangesOneLineAndNothingElse() throws {
        let files = try AnswerFile.render(plan: TestPlan.plan(), image: TestPlan.image,
                                          password: Fixture.cases.password, productKey: TestPlan.productKey)
        let golden = try Fixture.text("product-key.xml").replacingOccurrences(of: "\n", with: "\r\n")
        #expect(files[0].contents == Data(golden.utf8))
        let withKey = String(decoding: files[0].contents, as: UTF8.self)
        let without = try String(decoding: AnswerFile.render(plan: TestPlan.plan(), image: TestPlan.image,
                                                             password: Fixture.cases.password)[0].contents,
                                 as: UTF8.self)
        #expect(withKey.replacingOccurrences(of: "<Key>\(TestPlan.productKey)</Key>", with: "<Key />") == without)
        #expect(withKey.contains("<Key>\(TestPlan.productKey)</Key>"))
        // The image index chooses the edition, not the key.
        #expect(withKey.contains("<Value>3</Value>"))
    }

    /// The key is plain text in the answer file and nowhere else in it: one occurrence, inside <ProductKey>.
    @Test func theKeyAppearsOnceAndOnlyInProductKey() throws {
        let xml = try AnswerFile.renderChecked(TestPlan.inputsWithKey(), password: Fixture.cases.password).xml
        let lines = xml.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.contains(TestPlan.productKey) }
        #expect(lines == ["          <Key>\(TestPlan.productKey)</Key>"])
    }

    /// Regional off: no Mac values reach the file, whatever the plan carries.
    @Test func planWithoutRegionalUsesTheImageLanguage() throws {
        var plan = TestPlan.plan()
        plan.options.remove(.regionalFromMac)
        let inputs = AnswerFile.inputs(plan: plan, image: TestPlan.image)
        let (effective, _) = try AnswerFile.effective(inputs)
        #expect(effective.values["SYSTEM_LOCALE"] == "en-US")
        #expect(effective.values["INPUT_LOCALE"] == "en-US")
        #expect(effective.values["TIME_ZONE"] == "")
        #expect(effective.options["time_zone"] == false)
    }
}

/// A plan whose values are the oracle's dummy values, so a render can be compared with the goldens.
enum TestPlan {
    static let image = WindowsImageInfo(path: "/tmp/Win11_25H2_English_Arm64_v2.iso", build: 26200, fullBuild: "26200.8037",
                                        language: "en-US", editions: [edition], isArm64: true, bootPrompts: true)
    static let edition = WindowsEdition(index: 3, name: "Windows 11 Pro", displayName: "Windows 11 Pro",
                                        editionID: "Professional")
    /// Microsoft's own generic, non-activating Pro key (ANSWERFILE.md section 5), so no real licence is
    /// anywhere near the tests. The oracle renders `product-key.xml` with the same one.
    static let productKey = "VK7JG-NPHTM-C97JM-9MPGT-3V66T"

    /// The oracle's dummy values with a key, for the rules that only bite when there is one.
    static func inputsWithKey(_ key: String = productKey) -> AnswerFile.Inputs {
        var options: [String: Bool] = ["computer_name": true]
        for option in CreateOption.allCases { options[option.rawValue] = true }
        var values = Fixture.cases.dummyValues
        values["PRODUCT_KEY"] = key
        return AnswerFile.Inputs(options: options, values: values)
    }

    static func plan(userName: String = "alex", computerName: String = "Windows-11") -> CreatePlan {
        CreatePlan(vmName: "Windows 11", isoPath: image.path, edition: edition, cores: 6, memoryMiB: 16384,
                   diskGiB: 128, options: CreateOption.defaults, noVisualTweaks: false, userName: userName,
                   computerName: computerName,
                   regional: RegionalValues(userLocale: "en-US", systemLocale: "en-US", inputLocale: "0409:00000409",
                                            timeZone: "Eastern Standard Time",
                                            summary: "English (United States) · U.S. · Eastern Standard Time"),
                   select: true, keepConsole: false)
    }
}

@Suite struct AnswerFileRefusals {
    /// The oracle's negative cases, plus the local group names.
    @Test func refusesWhatTheOracleRefuses() throws {
        func refusal(options: [String: Int] = [:], values: [String: String] = [:], password: String? = nil) -> String? {
            var ids: [String: Bool] = ["computer_name": true]
            for option in CreateOption.allCases { ids[option.rawValue] = true }
            for (id, bit) in options { ids[id] = bit != 0 }
            let inputs = AnswerFile.Inputs(options: ids, values: Fixture.cases.dummyValues.merging(values) { _, new in new })
            do {
                _ = try AnswerFile.renderChecked(inputs, password: password ?? Fixture.cases.password)
                return nil
            } catch let failure as AnswerFile.Failure {
                if case .refused(let why) = failure { return why }
                return "not a refusal: \(failure)"
            } catch { return "\(error)" }
        }
        #expect(refusal(password: "") == "the password cannot be blank (Remote Desktop refuses blank passwords)")
        #expect(refusal(password: String(repeating: "a", count: 128)) == "password: at most 127 characters, no control characters")
        #expect(refusal(password: "tab\there") == "password: at most 127 characters, no control characters")
        #expect(refusal(options: ["guest_tools": 0]) == "guest_tools is locked on in Winbar")
        #expect(refusal(options: ["bypass_requirements": 0]) == "bypass_requirements is locked on in Winbar")
        #expect(refusal(options: ["local_account": 0]) == "local_account is locked on in Winbar")
        #expect(refusal(values: ["USERNAME": "Administrator"]) == "user name is reserved by Windows")
        #expect(refusal(values: ["USERNAME": "Remote Desktop Users"]) == "user name is reserved by Windows")
        #expect(refusal(values: ["USERNAME": "administrators"]) == "user name is reserved by Windows")
        #expect(refusal(values: ["USERNAME": "winbox", "COMPUTER_NAME": "WINBOX"]) == "computer name must differ from the user name")
        #expect(refusal(values: ["COMPUTER_NAME": String(repeating: "A", count: 16)])
                == "computer name: 1-15 of A-Z a-z 0-9 and \"-\", not starting or ending with \"-\"")
        #expect(refusal(values: ["COMPUTER_NAME": "-win11"])
                == "computer name: 1-15 of A-Z a-z 0-9 and \"-\", not starting or ending with \"-\"")
        #expect(refusal(values: ["COMPUTER_NAME": "12345"]) == "computer name cannot be all digits")
        #expect(refusal(values: ["USERNAME": "a<b"]) == "user name has a character Windows rejects")
        // Braces would survive escaping and come back out of the renderer looking like a placeholder
        // nothing filled, so they are refused here rather than at check()'s expense.
        #expect(refusal(values: ["USERNAME": "a{{b"]) == "user name has a character Windows rejects")
        #expect(refusal(values: ["USERNAME": "a}b"]) == "user name has a character Windows rejects")
        #expect(refusal(values: ["USERNAME": "ends."]) == "user name cannot end with \".\" or be only dots/spaces")
        #expect(refusal(values: ["USERNAME": " padded"]) == "user name: 1-20 characters, no leading/trailing spaces")
        #expect(refusal(values: ["USERNAME": String(repeating: "u", count: 21)]) == "user name: 1-20 characters, no leading/trailing spaces")
        #expect(refusal(values: ["TIME_ZONE": "Europe/Madrid"]) == "TIME_ZONE must be a Windows time zone id (CLDR windowsZones)")
        #expect(refusal(values: ["IMAGE_INDEX": "0"]) == "IMAGE_INDEX comes from install.wim (1-99)")
        #expect(refusal(values: ["SYSTEM_LOCALE": "en_US"]) == "SYSTEM_LOCALE must be a language tag like en-US")
        #expect(refusal(values: ["INPUT_LOCALE": "0409-00000409"]) == "INPUT_LOCALE: language tag or LCID:KLID like 0409:00000409")
        // A blank time zone is not a refusal: the element is left out and Windows keeps its default zone.
        #expect(refusal(values: ["TIME_ZONE": ""]) == nil)
        // The product key: optional, so no key is not a refusal, and the renderer's own floor is the canonical
        // form. What the person typed is normalised by the front-ends before it ever gets here.
        let keyShape = "PRODUCT_KEY must be five groups of five from BCDFGHJKMNPQRTVWXY2346789"
        #expect(refusal(values: ["PRODUCT_KEY": ""]) == nil)
        #expect(refusal(values: ["PRODUCT_KEY": "   "]) == nil)
        #expect(refusal(values: ["PRODUCT_KEY": "VK7JG-NPHTM-C97JM-9MPGT-3V66T"]) == nil)
        #expect(refusal(values: ["PRODUCT_KEY": "vk7jg-nphtm-c97jm-9mpgt-3v66t"]) == keyShape)
        #expect(refusal(values: ["PRODUCT_KEY": "VK7JGNPHTMC97JM9MPGT3V66T"]) == keyShape)
        #expect(refusal(values: ["PRODUCT_KEY": "VK7JG-NPHTM-C97JM-9MPGT-3V66"]) == keyShape)
        #expect(refusal(values: ["PRODUCT_KEY": "AEIOU-LSZ01-5BCDF-GHJKM-PQRTV"]) == keyShape)
    }

    @Test func refusesAnUnknownIdAndAMissingValue() throws {
        var options: [String: Bool] = ["computer_name": true]
        for option in CreateOption.allCases { options[option.rawValue] = true }
        #expect(throws: AnswerFile.Failure.template("unknown option ids in template: qol")) {
            var missing = options
            missing["qol"] = nil
            _ = try AnswerFile.resolve(AnswerFile.template, options: missing)
        }
        var inputs = AnswerFile.Inputs(options: options, values: Fixture.cases.dummyValues)
        inputs.values["TIME_ZONE"] = nil
        inputs.values["IMAGE_INDEX"] = nil
        #expect(throws: AnswerFile.Failure.template("no value for {{IMAGE_INDEX}}")) {
            _ = try AnswerFile.renderXML(inputs, password: "x")
        }
    }
}

@Suite struct AnswerFileChecks {
    /// check() runs on every render, so each rule gets a rendered file broken in exactly one way.
    func failure(_ edit: (String) -> String) throws -> String {
        let testCase = Fixture.cases.cases.first { $0.name == "default" }!
        let inputs = Fixture.inputs(testCase)
        let (effective, _) = try AnswerFile.effective(inputs)
        let xml = edit(try AnswerFile.renderXML(effective, password: testCase.password))
        do {
            _ = try AnswerFile.check(xml, effective, password: testCase.password)
            return "accepted"
        } catch let failure as AnswerFile.Failure {
            if case .check(let why) = failure { return why }
            return "not a check failure: \(failure)"
        }
    }

    /// The unedited file passes, so every case below fails for the reason it introduces.
    @Test func acceptsTheRenderedFile() throws {
        #expect(try failure { $0 } == "accepted")
    }

    @Test func catchesLeftoversAndBadXML() throws {
        #expect(try failure { $0.replacingOccurrences(of: "<DiskID>0</DiskID>", with: "<DiskID>{{X}}</DiskID>") }
                == "leftover placeholder or comment")
        #expect(try failure { $0.replacingOccurrences(of: "<DiskID>0</DiskID>", with: "<!-- a comment -->") }
                == "leftover placeholder or comment")
        #expect(try failure { $0.replacingOccurrences(of: "</unattend>", with: "") }.hasPrefix("not well-formed XML"))
    }

    @Test func catchesComponentProblems() throws {
        #expect(try failure { $0.replacingOccurrences(of: "pass=\"specialize\"", with: "pass=\"auditPass\"") } == "unknown pass auditPass")
        #expect(try failure { $0.replacingOccurrences(of: "processorArchitecture=\"arm64\"", with: "processorArchitecture=\"amd64\"") }
                == "component not arm64: Microsoft-Windows-International-Core-WinPE")
        #expect(try failure { $0.replacingOccurrences(of: "versionScope=\"nonSxS\"", with: "versionScope=\"SxS\"") }
                .hasPrefix("component attributes: "))
        #expect(try failure {
            $0.replacingOccurrences(of: "<TCGSecurityActivationDisabled>1</TCGSecurityActivationDisabled>", with: "")
        } == "empty component Microsoft-Windows-EnhancedStorage-Adm")
        #expect(try failure {
            $0.replacingOccurrences(of: "  </settings>\n  <settings pass=\"oobeSystem\">\n", with: "")
        } == "duplicate component in a pass")
    }

    @Test func catchesListProblems() throws {
        #expect(try failure {
            // Two lists: the launcher's own list, copied.
            $0.replacingOccurrences(of: "</FirstLogonCommands>", with: "</FirstLogonCommands>\n      <FirstLogonCommands />")
        } == "exactly one FirstLogonCommands list")
        #expect(try failure { $0.replacingOccurrences(of: "<Order>2</Order>", with: "<Order>4</Order>") }
                .hasPrefix("Order must run 1 to n"))
        #expect(try failure { $0.replacingOccurrences(of: "<Order>1</Order>", with: "<Order>one</Order>") }
                .hasPrefix("Order must run 1 to n"))
        #expect(try failure {
            $0.replacingOccurrences(of: "<Path>reg add HKLM\\SYSTEM\\Setup\\LabConfig /v BypassTPMCheck /t REG_DWORD /d 1 /f</Path>",
                                    with: "<Path>" + String(repeating: "p", count: 260) + "</Path>")
        }.hasPrefix("RunSynchronousCommand/Path > 259"))
        #expect(try failure {
            $0.replacingOccurrences(of: "<CommandLine>net accounts /maxpwage:unlimited</CommandLine>",
                                    with: "<CommandLine>" + String(repeating: "c", count: 1025) + "</CommandLine>")
        }.hasPrefix("CommandLine > 1024"))
    }

    @Test func catchesPasswordAndAccountProblems() throws {
        #expect(try failure { text in
            guard let range = text.range(of: "      <AutoLogon>\n") else { return text }
            var text = text
            text.replaceSubrange(range, with: "      <AutoLogon>\n        <Password><Value>x</Value><PlainText>false</PlainText></Password>\n")
            return text
        } == "password elements")
        #expect(try failure { $0.replacingOccurrences(of: "<PlainText>false</PlainText>", with: "<PlainText>true</PlainText>") }
                == "PlainText must be false")
        #expect(try failure { text in
            // A second Password element whose value decodes to something else.
            text.replacingOccurrences(of: "<Value>\(AnswerFile.obscure(Fixture.cases.password))</Value>",
                                      with: "<Value>\(AnswerFile.obscure("something else"))</Value>")
        } == "password encoding")
        #expect(try failure { $0.replacingOccurrences(of: "<Username>alex</Username>", with: "<Username>someone</Username>") }
                == "the account and the autologon user must both be the user name")
        #expect(try failure { $0.replacingOccurrences(of: "<Group>Administrators</Group>", with: "<Group>Users</Group>") }
                == "the account's group must be Administrators")
        // A real leak: the password in cleartext somewhere the control render doesn't have it.
        #expect(try failure { $0.replacingOccurrences(of: "<Label>EFI</Label>", with: "<Label>\(Fixture.cases.password)</Label>") }
                == "the password reached the file outside <Password><Value>")
        // …and a third obscured copy, which the comparison alone would strip out of both files.
        #expect(try failure { $0.replacingOccurrences(of: "<Label>EFI</Label>",
                                                      with: "<Label>\(AnswerFile.obscure(Fixture.cases.password))</Label>") }
                == "the obscured password must appear once per <Password>")
    }

    /// The rule above must never bite what the person typed. A password that happens to be a word the
    /// template uses, or their own user name, is a weak password, not a leak: it used to make `check`
    /// throw, which aborted create at stage 3 with a message blaming Winbar.
    @Test func aPasswordThatIsAlsoInTheFileStillRenders() throws {
        let testCase = Fixture.cases.cases.first { $0.name == "default" }!
        let inputs = Fixture.inputs(testCase)
        let golden = try Fixture.text("default.xml")
        for weak in ["Windows", "password", "Password", "true", "Order", "Setup", "Administrators", "en-US",
                     Fixture.cases.dummyValues["USERNAME"]!, Fixture.cases.dummyValues["COMPUTER_NAME"]!] {
            let result = try AnswerFile.renderChecked(inputs, password: weak)
            // The same file as the golden, bar the one value the password belongs in (whose length,
            // and so the file's, follows the password's).
            #expect(result.xml.replacingOccurrences(of: AnswerFile.obscure(weak), with: "")
                        == golden.replacingOccurrences(of: AnswerFile.obscure(testCase.password), with: ""), "\(weak)")
        }
    }

    @Test func catchesOptionSignatureProblems() throws {
        #expect(try failure { $0.replacingOccurrences(of: "BypassTPMCheck", with: "BypassCPUCheck") }
                == "option signature mismatch: bypass_requirements is on")
        #expect(try failure { $0.replacingOccurrences(of: "BypassNRO", with: "BypassNothing") }
                == "option signature mismatch: no_online_account is on")
        #expect(try failure { $0.replacingOccurrences(of: "<TimeZone>Eastern Standard Time</TimeZone>", with: "<TimeZone>UTC</TimeZone>") }
                == "option signature mismatch: time_zone is on")
        #expect(try failure { $0.replacingOccurrences(of: "<ProtectYourPC>3</ProtectYourPC>", with: "<ProtectYourPC>1</ProtectYourPC>") }
                == "option signature mismatch: skip_privacy is on")
        #expect(try failure { $0.replacingOccurrences(of: "<fDenyTSConnections>false</fDenyTSConnections>",
                                                      with: "<fDenyTSConnections>true</fDenyTSConnections>") }
                == "option signature mismatch: remote_desktop is on")
        #expect(try failure { $0.replacingOccurrences(of: "<ComputerName>Windows-11</ComputerName>",
                                                      with: "<ComputerName>Other-11</ComputerName>") }
                == "option signature mismatch: computer_name is on")
        #expect(try failure { $0.replacingOccurrences(of: "HiberbootEnabled", with: "HiberbootDisabled") }
                == "option signature mismatch: qol is on")
        #expect(try failure { $0.replacingOccurrences(of: "<PreventDeviceEncryption>true</PreventDeviceEncryption>",
                                                      with: "<PreventDeviceEncryption>false</PreventDeviceEncryption>") }
                == "option signature mismatch: no_bitlocker is on")
        #expect(try failure { $0.replacingOccurrences(of: "<InputLocale>0409:00000409</InputLocale>",
                                                      with: "<InputLocale>en-GB</InputLocale>") }
                == "InputLocale and UILanguage")
        #expect(try failure { $0.replacingOccurrences(of: "<Value>3</Value>", with: "<Value>4</Value>") } == "the image index")
    }

    @Test func catchesLauncherProblems() throws {
        #expect(try failure { $0.replacingOccurrences(of: " -Tuning", with: "") }
                .hasPrefix("launcher switches"))
        #expect(try failure { $0.replacingOccurrences(of: " -Autologon", with: " -Autologon -Autologon") }
                .hasPrefix("launcher switches"))
        #expect(try failure { $0.replacingOccurrences(of: "-or (Test-Path ($_.Name + 'FirstLogon.ps1'))", with: "") }
                == "the launcher must find the CD by label or content")
        #expect(try failure { $0.replacingOccurrences(of: "catch { $e = 'launcher: ' + $_ }", with: "") }
                == "the launcher must catch a script that can't run")
        #expect(try failure { $0.replacingOccurrences(of: "Move-Item $t ($o + '\\status.txt') -Force", with: "") }
                == "the launcher must write status.tmp, then rename it")
        #expect(try failure { $0.replacingOccurrences(of: "'result=failed', 'guest_tools=-1', ('rdp=' + $r)", with: "'result=failed'") }
                == "the launcher's fallback status lines")
        #expect(try failure { $0.replacingOccurrences(of: "FirstLogon.ps1", with: "SecondLogon.ps1") }
                == "exactly one first-logon launcher")
    }

    /// The rules that only bite when an option is off.
    @Test func catchesProblemsWithOptionsOff() throws {
        let testCase = Fixture.cases.cases.first { $0.name == "all-off" }!
        let (effective, _) = try AnswerFile.effective(Fixture.inputs(testCase))
        let xml = try AnswerFile.renderXML(effective, password: testCase.password)
        func check(_ text: String) -> String {
            do {
                _ = try AnswerFile.check(text, effective, password: testCase.password)
                return "accepted"
            } catch let failure as AnswerFile.Failure {
                if case .check(let why) = failure { return why }
                return "not a check failure: \(failure)"
            } catch { return "\(error)" }
        }
        #expect(check(xml) == "accepted")
        #expect(check(xml.replacingOccurrences(of: "<ProtectYourPC>1</ProtectYourPC>", with: "<ProtectYourPC>3</ProtectYourPC>"))
                == "without skip_privacy, ProtectYourPC must be 1 and there must be no OptIn")
        #expect(check(xml.replacingOccurrences(of: "<SystemLocale>en-US</SystemLocale>", with: "<SystemLocale>en-GB</SystemLocale>"))
                == "without regional_from_mac the locales must be the image language")
        #expect(check(xml.replacingOccurrences(of: "<OOBE>", with: "<TimeZone>UTC</TimeZone>\n      <OOBE>"))
                == "without regional_from_mac there must be no TimeZone")
    }

    /// The key has to be in the file exactly when one was asked for, and be the one that was asked for. There
    /// is nothing to decode: a product key is plain text in an answer file.
    @Test func catchesProductKeyProblems() throws {
        let password = Fixture.cases.password
        let (withKey, _) = try AnswerFile.effective(TestPlan.inputsWithKey())
        let xml = try AnswerFile.renderXML(withKey, password: password)
        #expect(check(xml, withKey, password) == nil)
        #expect(check(xml.replacingOccurrences(of: TestPlan.productKey, with: "YTMG3-N6DKC-DKB77-7M9GH-8HVX7"),
                      withKey, password) == "option signature mismatch: product_key is on")
        #expect(check(xml.replacingOccurrences(of: "<Key>\(TestPlan.productKey)</Key>", with: "<Key />"),
                      withKey, password) == "option signature mismatch: product_key is on")

        let plainCase = Fixture.cases.cases.first { $0.name == "default" }!
        let (plain, _) = try AnswerFile.effective(Fixture.inputs(plainCase))
        let plainXML = try AnswerFile.renderXML(plain, password: plainCase.password)
        #expect(check(plainXML, plain, plainCase.password) == nil)
        #expect(check(plainXML.replacingOccurrences(of: "<Key />", with: "<Key>\(TestPlan.productKey)</Key>"),
                      plain, plainCase.password) == "without a product key the Key element must be empty")
    }

    /// A blank computer name renders "*", Windows' documented random name.
    @Test func blankComputerNameRendersAStar() throws {
        let testCase = Fixture.cases.cases.first { $0.name == "blank-computer-name" }!
        let (effective, _) = try AnswerFile.effective(Fixture.inputs(testCase))
        #expect(effective.options["computer_name"] == false)
        let xml = try AnswerFile.renderXML(effective, password: testCase.password)
        #expect(xml.contains("<ComputerName>*</ComputerName>"))
        #expect(check(xml, effective, testCase.password) == nil)
        #expect(check(xml.replacingOccurrences(of: "<ComputerName>*</ComputerName>", with: "<ComputerName>Win</ComputerName>"),
                      effective, testCase.password) == "a blank computer name must render *")
    }

    private func check(_ xml: String, _ inputs: AnswerFile.Inputs, _ password: String) -> String? {
        do {
            _ = try AnswerFile.check(xml, inputs, password: password)
            return nil
        } catch let failure as AnswerFile.Failure {
            if case .check(let why) = failure { return why }
            return "not a check failure: \(failure)"
        } catch { return "\(error)" }
    }
}
