import Foundation

/// The answer CD's files for `winbar create`: Autounattend.xml rendered from `template`, and the static
/// FirstLogon.ps1. The media builder adds the pinned UTM Guest Tools installer and burns the WINBAR_SETUP ISO.
///
/// This is a port of the Python reference renderer the answer file was worked out with, and must behave the
/// same: the tests compare its output with that renderer's, byte for byte. Rendering goes effective → validate →
/// render → check, and every render is checked, so a template or code change that breaks a rule fails here
/// rather than in Windows Setup.
enum AnswerFile {
    static let answerFileName = "Autounattend.xml"
    static let firstLogonName = "FirstLogon.ps1"
    static let volumeLabel = "WINBAR_SETUP"

    /// Why no answer file was made. The messages are the Python renderer's, in plain English.
    enum Failure: Error, Equatable, CustomStringConvertible {
        /// The inputs can't make an answer file Windows accepts (a blank password, a reserved user name…).
        case refused(String)
        /// The template itself is wrong: an unknown option id, an unbalanced marker, a value with no input.
        case template(String)
        /// The rendered file broke one of `check`'s rules. A Winbar bug, never the person's input.
        case check(String)

        var description: String {
            switch self {
            case .refused(let why): return "Can't make the answer file: \(why)."
            case .template(let why): return "The answer file template is broken: \(why)."
            case .check(let why): return "The answer file failed its own check: \(why)."
            }
        }
    }

    /// The renderer's inputs: option ids (the checklist's raw values, `computer_name`, and the modifiers)
    /// and the template's `{{VALUES}}`. The same shape the Python renderer takes, so the two can be compared.
    struct Inputs: Equatable, Sendable {
        var options: [String: Bool]
        var values: [String: String]
    }

    // MARK: - Ids (the contract between the template, the renderer and the first-logon script)

    static let lockedOn = ["bypass_requirements", "local_account", "guest_tools"]
    /// Not checklist rows: `no_visual_tweaks` is --no-visual-tweaks; `time_zone` and `product_key` are derived
    /// by `effective` from the values, as `computer_name` is from the name.
    static let modifiers = ["no_visual_tweaks", "time_zone", "product_key"]
    /// FirstLogon.ps1's switch for each option, in the launcher's order.
    static let launcherSwitches: [(id: String, name: String)] = [
        ("guest_tools", "-GuestTools"), ("autologon", "-Autologon"), ("remote_desktop", "-RemoteDesktop"),
        ("no_bitlocker", "-NoBitLocker"), ("winbar_tuning", "-Tuning"),
    ]
    static let passes = ["windowsPE", "offlineServicing", "generalize", "specialize", "auditSystem", "auditUser", "oobeSystem"]
    private static let namespace = "urn:schemas-microsoft-com:unattend"

    // MARK: - From a plan

    /// The CD's root files for a plan. The password is used here and nowhere else: it isn't kept, logged or
    /// returned except inside Autounattend.xml, obscured as Windows SIM does it.
    ///
    /// `productKey` is optional and nil unless the person asked for one. It is used the same way — never kept,
    /// logged or returned — but it lands in the file as **plain text**: there is no obscured form for a product
    /// key, so what protects it is the setup disk itself (mode 0600, out of Time Machine, deleted at the end).
    static func render(plan: CreatePlan, image: WindowsImageInfo, password: String,
                       productKey: String? = nil) throws -> [SetupFile] {
        let xml = try renderChecked(inputs(plan: plan, image: image, productKey: productKey), password: password).xml
        // Written with CRLF line endings, as the file goes onto the CD.
        return [SetupFile(name: answerFileName, contents: Data(xml.replacingOccurrences(of: "\n", with: "\r\n").utf8)),
                SetupFile(name: firstLogonName, contents: Data(firstLogonScript.utf8))]
    }

    /// The renderer's inputs for a plan. Missing regional values are left blank for `effective` to fill with
    /// the image language; the display name is the user name (the UX has no separate field).
    static func inputs(plan: CreatePlan, image: WindowsImageInfo, productKey: String? = nil) -> Inputs {
        var options: [String: Bool] = [:]
        for option in CreateOption.allCases { options[option.rawValue] = plan.has(option) }
        options["computer_name"] = !plan.computerName.isEmpty
        options["no_visual_tweaks"] = plan.noVisualTweaks
        let regional = plan.has(.regionalFromMac) ? plan.regional : nil
        let values = [
            "PE_LANGUAGE": image.language,
            "UI_LANGUAGE": image.language,
            "IMAGE_INDEX": String(plan.edition.index),
            "EDITION_ID": plan.edition.editionID,
            "INPUT_LOCALE": regional?.inputLocale ?? "",
            "SYSTEM_LOCALE": regional?.systemLocale ?? "",
            "USER_LOCALE": regional?.userLocale ?? "",
            "TIME_ZONE": regional?.timeZone ?? "",
            "USERNAME": plan.userName,
            "DISPLAY_NAME": plan.userName,
            "COMPUTER_NAME": plan.computerName,
            // The key is never part of the plan, for the same reason the password isn't: the plan is written to
            // state.json and quoted in the log. It arrives here as an argument and goes no further.
            "PRODUCT_KEY": productKey ?? "",
        ]
        return Inputs(options: options, values: values)
    }

    /// effective → validate → render → check. Returns the XML (LF line endings), check's one-line summary
    /// and effective's warnings.
    static func renderChecked(_ inputs: Inputs, password: String) throws -> (xml: String, summary: String, warnings: [String]) {
        let (effective, warnings) = try effective(inputs)
        try validate(effective, password: password)
        let xml = try renderXML(effective, password: password)
        let summary = try check(xml, effective, password: password)
        return (xml, summary, warnings)
    }

    // MARK: - effective() and validate()

    /// Makes the options consistent (the Python renderer's `effective`). Locked options must be on.
    /// `computer_name` is on exactly when there is a name (a blank one renders "*", Windows' random
    /// name). The visual-tweaks modifier needs tuning. Home can't host Remote Desktop: off, with a
    /// warning. Without regional_from_mac the locales are the image language and there's no time zone;
    /// with it, a locale the Mac couldn't supply is the image language, and `time_zone` is on only when
    /// there's a zone to set. `product_key` is on only when there is a key: without one the file keeps the
    /// empty `<Key />` it has always had.
    static func effective(_ inputs: Inputs) throws -> (inputs: Inputs, warnings: [String]) {
        var opts = inputs.options
        var values = inputs.values
        var warnings: [String] = []
        for id in modifiers where opts[id] == nil { opts[id] = false }
        for id in lockedOn where opts[id] != true { throw Failure.refused("\(id) is locked on in Winbar") }
        opts["computer_name"] = !(values["COMPUTER_NAME"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if opts["winbar_tuning"] != true { opts["no_visual_tweaks"] = false }
        if opts["remote_desktop"] == true, WindowsEdition.homeEditionIDs.contains(values["EDITION_ID"] ?? "") {
            opts["remote_desktop"] = false
            warnings.append("Windows Home cannot host Remote Desktop: remote_desktop turned off (pick Pro to keep it)")
        }
        let ui = values["UI_LANGUAGE"] ?? ""
        if opts["regional_from_mac"] != true {
            values["INPUT_LOCALE"] = ui
            values["SYSTEM_LOCALE"] = ui
            values["USER_LOCALE"] = ui
            values["TIME_ZONE"] = ""
        }
        for key in ["INPUT_LOCALE", "SYSTEM_LOCALE", "USER_LOCALE"]
        where (values[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            values[key] = ui
        }
        let zone = (values["TIME_ZONE"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        values["TIME_ZONE"] = zone
        opts["time_zone"] = opts["regional_from_mac"] == true && !zone.isEmpty
        // No key is the default, and renders the empty <Key /> that makes Setup skip its product-key page.
        let key = (values["PRODUCT_KEY"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        values["PRODUCT_KEY"] = key
        opts["product_key"] = !key.isEmpty
        if (values["DISPLAY_NAME"] ?? "").isEmpty { values["DISPLAY_NAME"] = values["USERNAME"] ?? "" }
        return (Inputs(options: opts, values: values), warnings)
    }

    /// Characters the Python renderer refuses in a user name (schneegans' set, plus "@" and the braces). Values
    /// are substituted once and never rescanned, so a name carrying "{{" would look like a placeholder the
    /// renderer failed to fill. The CLI and the window refuse more (`CreateChoices.userNameForbidden`);
    /// this is the renderer's own floor.
    static let userNameForbidden = Set("/\\[]:;|=,+*?<>\"%@{}")

    /// Refuses inputs Windows would reject (the Python renderer's `validate`), after `effective`.
    static func validate(_ inputs: Inputs, password: String) throws {
        func need(_ ok: Bool, _ why: String) throws { if !ok { throw Failure.refused(why) } }
        let values = inputs.values
        let user = values["USERNAME"] ?? ""
        try need(user == user.trimmingCharacters(in: .whitespacesAndNewlines) && (1...20).contains(user.unicodeScalars.count),
                 "user name: 1-20 characters, no leading/trailing spaces")
        try need(!user.contains(where: userNameForbidden.contains) && !user.unicodeScalars.contains { $0.value < 32 },
                 "user name has a character Windows rejects")
        try need(!user.hasSuffix(".") && !user.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).isEmpty,
                 "user name cannot end with \".\" or be only dots/spaces")
        try need(!CreateChoices.isReservedUserName(user), "user name is reserved by Windows")
        let display = values["DISPLAY_NAME"] ?? ""
        try need(!display.isEmpty && display.unicodeScalars.count <= 256 && !display.unicodeScalars.contains { $0.value < 32 },
                 "display name")
        try need(!password.isEmpty, "the password cannot be blank (Remote Desktop refuses blank passwords)")
        try need(password.unicodeScalars.count <= 127 && !password.unicodeScalars.contains { $0.value < 32 || $0.value == 127 },
                 "password: at most 127 characters, no control characters")
        if inputs.options["computer_name"] == true {
            let name = values["COMPUTER_NAME"] ?? ""
            try need(fullMatch(name, computerNamePattern),
                     "computer name: 1-15 of A-Z a-z 0-9 and \"-\", not starting or ending with \"-\"")
            try need(!name.allSatisfy { $0.isASCII && $0.isNumber }, "computer name cannot be all digits")
            try need(name.lowercased() != user.lowercased(), "computer name must differ from the user name")
        }
        // The key is optional; when there is one it must already be canonical. The front-ends normalise what the
        // person typed (`CreateChoices.normalizedProductKey`); this is the renderer's own floor.
        if inputs.options["product_key"] == true {
            let key = values["PRODUCT_KEY"] ?? ""
            try need(CreateChoices.normalizedProductKey(key) == key,
                     "PRODUCT_KEY must be five groups of five from \(CreateChoices.productKeyAlphabet)")
        }
        try need(fullMatch(values["IMAGE_INDEX"] ?? "", imageIndexPattern), "IMAGE_INDEX comes from install.wim (1-99)")
        for key in ["PE_LANGUAGE", "UI_LANGUAGE", "SYSTEM_LOCALE", "USER_LOCALE"] {
            try need(fullMatch(values[key] ?? "", tagPattern), "\(key) must be a language tag like en-US")
        }
        try need(isInputLocale(values["INPUT_LOCALE"] ?? ""), "INPUT_LOCALE: language tag or LCID:KLID like 0409:00000409")
        if inputs.options["time_zone"] == true {
            try need(Regional.windowsTimeZones.contains(values["TIME_ZONE"] ?? ""),
                     "TIME_ZONE must be a Windows time zone id (CLDR windowsZones)")
        }
    }

    /// InputLocale: one or more (";"-separated) language tags or LCID:KLID pairs, as Setup reads them.
    static func isInputLocale(_ value: String) -> Bool {
        value.split(separator: ";", omittingEmptySubsequences: false)
            .allSatisfy { fullMatch(String($0), tagPattern) || fullMatch(String($0), klidPattern) }
    }

    private static let computerNamePattern = regex("[A-Za-z0-9](?:[A-Za-z0-9-]{0,13}[A-Za-z0-9])?")
    private static let imageIndexPattern = regex("[1-9][0-9]?")
    private static let tagPattern = regex("[a-z]{2,3}(-[A-Za-z0-9]{2,8})*")
    private static let klidPattern = regex("[0-9A-Fa-f]{4}:[0-9A-Fa-f]{8}")

    // MARK: - Rendering

    /// Windows SIM's "hide sensitive data": base64(UTF-16LE(value + element name)). Obfuscation, not
    /// encryption. Both elements that carry the password are named Password.
    static func obscure(_ password: String, element: String = "Password") -> String {
        var bytes = Data()
        for unit in (password + element).utf16 { bytes.append(contentsOf: [UInt8(unit & 0xFF), UInt8(unit >> 8)]) }
        return bytes.base64EncodedString()
    }

    /// The Python renderer's `render`: conditionals, comments, blank lines, {{SEQ}} numbering, empty lists and
    /// components, then the escaped values. Doesn't validate or check; `renderChecked` does.
    static func renderXML(_ inputs: Inputs, password: String) throws -> String {
        var text = try resolve(template, options: inputs.options)
        text = replace(anyComment, in: text) { _ in "" }
        text = replace(blankLines, in: text) { _ in "\n" }
        text = replace(commandList, in: text) { match in
            var n = 0
            return replace(seq, in: match[0]) { _ in n += 1; return String(n) }
        }
        text = replace(emptyList, in: text) { _ in "" }
        text = replace(emptyComponent, in: text) { _ in "" }
        var values = inputs.values
        values["PASSWORD_B64"] = obscure(password)
        return try replace(placeholder, in: text) { match in
            guard let value = values[match[1]] else { throw Failure.template("no value for {{\(match[1])}}") }
            return xmlEscaped(value)
        }
    }

    /// Keeps or drops each `<!--IF id-->…<!--END id-->` ("!id": kept when the option is off). Block markers
    /// sit on their own lines; inline ones (only in the launcher's command line) inside one line. Different
    /// ids may nest, so each form is applied until nothing changes.
    static func resolve(_ text: String, options: [String: Bool]) throws -> String {
        let ids = Set(allMatches(markerID, in: text).map { $0[1] })
        let unknown = ids.subtracting(options.keys).subtracting(modifiers).sorted()
        if !unknown.isEmpty { throw Failure.template("unknown option ids in template: \(unknown.joined(separator: ", "))") }
        var text = text
        for pattern in [block, inline] {
            while true {
                let next = replace(pattern, in: text) { match in
                    (options[match[2]] ?? false) != (match[1] == "!") ? match[3] : ""
                }
                if next == text { break }
                text = next
            }
        }
        if text.contains("<!--IF") || text.contains("<!--END") { throw Failure.template("unbalanced conditional marker in template") }
        return text
    }

    private static let markerID = regex("<!--(?:IF|END) !?([a-z_]+)-->")
    private static let block = regex(#"^[ \t]*<!--IF (!?)([a-z_]+)-->[ \t]*\n(.*?)^[ \t]*<!--END \1\2-->[ \t]*\n"#,
                                     [.anchorsMatchLines, .dotMatchesLineSeparators])
    private static let inline = regex(#"<!--IF (!?)([a-z_]+)-->(.*?)<!--END \1\2-->"#)
    private static let anyComment = regex(#"[ \t]*<!--.*?-->[ \t]*\n?"#, [.dotMatchesLineSeparators])
    private static let blankLines = regex(#"\n[ \t]*\n+"#)
    private static let commandList = regex(#"<(RunSynchronous|FirstLogonCommands)>.*?</\1>"#, [.dotMatchesLineSeparators])
    private static let seq = regex(#"\{\{SEQ\}\}"#)
    private static let emptyList = regex(#"[ \t]*<(RunSynchronous|FirstLogonCommands)>\s*</\1>\n"#)
    private static let emptyComponent = regex(#"[ \t]*<component [^>]*>\s*</component>\n"#)
    private static let placeholder = regex(#"\{\{([A-Z0-9_]+)\}\}"#)

    /// `& < > " '` as entities: every value lands in element text, and all five are escaped as the
    /// Python renderer does.
    static func xmlEscaped(_ value: String) -> String {
        var out = ""
        for c in value {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default: out.append(c)
            }
        }
        return out
    }

    // MARK: - check()

    /// Structural and semantic checks on one rendered file (the Python renderer's `check`); throws `.check` with the
    /// first rule broken, or returns a one-line summary. The rules: well-formed; no leftover placeholder or
    /// comment; every component arm64 with the standard attributes, none empty, none twice in a pass;
    /// exactly one FirstLogonCommands; each list's Order runs 1…n; Path ≤ 259 and CommandLine ≤ 1024
    /// characters; both password copies decode to the password, PlainText false; the account is the
    /// autologon user, in Administrators; each option's signature element is present exactly when the
    /// option is on (the product key among them: exactly the key that was asked for, and an empty
    /// `<Key />` when none was); the launcher's switches are the ticked options, and it finds the CD by label or
    /// content, catches a script that can't run and writes status.tmp then renames it (D7); and the
    /// password reached nowhere but the two obscured Values.
    ///
    /// None of this is about what the person typed: a password that happens to be a word the template
    /// uses, or their own user name, is a weak password, not a leak, and never stops a render.
    @discardableResult
    static func check(_ xml: String, _ inputs: Inputs, password: String) throws -> String {
        func need(_ ok: Bool, _ why: @autoclosure () -> String) throws { if !ok { throw Failure.check(why()) } }
        let opts = inputs.options
        let values = inputs.values
        func on(_ id: String) -> Bool { opts[id] ?? false }

        try need(!xml.contains("{{") && !xml.contains("<!--"), "leftover placeholder or comment")
        let document: XMLDocument
        do { document = try XMLDocument(xmlString: xml, options: []) } catch {
            throw Failure.check("not well-formed XML (\(error.localizedDescription))")
        }
        guard let root = document.rootElement() else { throw Failure.check("no root element") }

        var components: [(pass: String, element: XMLElement)] = []
        for settings in childElements(root, "settings") {
            for component in childElements(settings, "component") {
                components.append((settings.attribute(forName: "pass")?.stringValue ?? "", component))
            }
        }
        for (pass, component) in components {
            let name = attribute(component, "name")
            try need(passes.contains(pass), "unknown pass \(pass)")
            try need(attribute(component, "processorArchitecture") == "arm64", "component not arm64: \(name)")
            try need(attribute(component, "publicKeyToken") == "31bf3856ad364e35" && attribute(component, "language") == "neutral"
                        && attribute(component, "versionScope") == "nonSxS", "component attributes: \(name)")
            try need(!elementChildren(component).isEmpty, "empty component \(name)")
        }
        let keys = components.map { "\($0.pass)/\(attribute($0.element, "name"))" }
        try need(keys.count == Set(keys).count, "duplicate component in a pass")

        let all = descendants(root)
        func named(_ name: String) -> [XMLElement] { all.filter { $0.localName == name && $0.uri == namespace } }
        func text(_ e: XMLElement) -> String { e.stringValue ?? "" }
        try need(named("FirstLogonCommands").count == 1, "exactly one FirstLogonCommands list")
        for list in named("RunSynchronous") + named("FirstLogonCommands") {
            let orders = descendants(list).filter { $0.localName == "Order" }.map { Int(text($0)) }
            try need(!orders.isEmpty && orders == (1...orders.count).map { Optional($0) },
                     "Order must run 1 to n in each list, got \(orders.map { $0.map(String.init) ?? "?" })")
        }
        for path in named("Path") {
            try need(text(path).unicodeScalars.count <= 259, "RunSynchronousCommand/Path > 259 (\(text(path).unicodeScalars.count))")
        }
        let commandLines = named("CommandLine").map(text)
        try need(commandLines.allSatisfy { $0.unicodeScalars.count <= 1024 },
                 "CommandLine > 1024 (\(commandLines.map { $0.unicodeScalars.count }.max() ?? 0))")

        let leaves = self.leaves(components)
        func find(_ path: String...) -> [XMLElement] {
            leaves.filter { $0.path.count >= path.count && Array($0.path.suffix(path.count)) == path }.map(\.element)
        }
        func textOf(_ path: String...) -> [String] {
            leaves.filter { $0.path.count >= path.count && Array($0.path.suffix(path.count)) == path }.map { text($0.element) }
        }
        func pathHas(_ fragment: String) -> Bool { named("Path").contains { text($0).contains(fragment) } }

        // Passwords: both copies decode to password + "Password", PlainText false, account and autologon agree.
        let passwords = named("Password")
        try need(passwords.count == (on("local_account") ? 2 : 0), "password elements")
        for element in passwords {
            let value = childElements(element, "Value").first.map(text) ?? ""
            let decoded = Data(base64Encoded: value).flatMap { String(data: $0, encoding: .utf16LittleEndian) }
            try need(decoded == password + "Password", "password encoding")
            try need(childElements(element, "PlainText").first.map(text) == "false", "PlainText must be false")
        }
        if on("local_account") {
            let user = values["USERNAME"] ?? ""
            try need(textOf("LocalAccount", "Name") == [user] && textOf("AutoLogon", "Username") == [user],
                     "the account and the autologon user must both be the user name")
            try need(textOf("LocalAccount", "Group") == ["Administrators"], "the account's group must be Administrators")
        }

        // Each option's signature is present exactly when the option is on.
        let signatures: [(id: String, present: Bool)] = [
            ("bypass_requirements", pathHas("BypassTPMCheck") && pathHas("BypassSecureBootCheck") && pathHas("BypassRAMCheck")),
            ("no_online_account", pathHas("BypassNRO")),
            ("time_zone", textOf("TimeZone") == [values["TIME_ZONE"] ?? ""]),
            ("skip_privacy", textOf("ProtectYourPC") == ["3"] && textOf("Diagnostics", "OptIn") == ["false"]),
            ("no_bitlocker", textOf("PreventDeviceEncryption") == ["true"] && textOf("TCGSecurityActivationDisabled") == ["1"]
                && textOf("DisableEncryptedDiskProvisioning") == ["true"]),
            ("qol", pathHas("DisableFileSyncNGSC") && commandLines.contains { $0.contains("HiberbootEnabled") }),
            ("remote_desktop", textOf("fDenyTSConnections") == ["false"] && textOf("UserAuthentication") == ["1"]),
            ("computer_name", textOf("ComputerName") == [values["COMPUTER_NAME"] ?? ""]),
            // The key is in the file as plain text, so this is a look, not a decode: it is there exactly when
            // one was asked for, and it is the one that was asked for.
            ("product_key", !(values["PRODUCT_KEY"] ?? "").isEmpty
                && textOf("ProductKey", "Key") == [values["PRODUCT_KEY"] ?? ""]),
        ]
        for (id, present) in signatures {
            try need(present == on(id), "option signature mismatch: \(id) is \(on(id) ? "on" : "off")")
        }
        if !on("skip_privacy") {
            try need(textOf("ProtectYourPC") == ["1"] && find("Diagnostics", "OptIn").isEmpty,
                     "without skip_privacy, ProtectYourPC must be 1 and there must be no OptIn")
        }
        if !on("computer_name") { try need(textOf("ComputerName") == ["*"], "a blank computer name must render *") }
        if !on("product_key") {
            try need(textOf("ProductKey", "Key") == [""], "without a product key the Key element must be empty")
        }
        let ui = values["UI_LANGUAGE"] ?? ""
        if !on("regional_from_mac") {
            try need(find("TimeZone").isEmpty, "without regional_from_mac there must be no TimeZone")
            try need(["InputLocale", "SystemLocale", "UserLocale"].map { textOf($0).last } == [ui, ui, ui],
                     "without regional_from_mac the locales must be the image language")
        }
        try need(textOf("InputLocale").last == values["INPUT_LOCALE"] && textOf("UILanguage").last == ui,
                 "InputLocale and UILanguage")
        try need(textOf("InstallFrom", "MetaData", "Value") == [values["IMAGE_INDEX"] ?? ""], "the image index")

        // The launcher: one switch per ticked Winbar option, nothing else; found by label or content; a script
        // that can't run still leaves a status file, written the same way the script writes it (D7).
        let launchers = commandLines.filter { $0.contains("FirstLogon.ps1") }
        try need(launchers.count == 1, "exactly one first-logon launcher")
        let launcher = launchers[0]
        let calls = allMatches(launcherCall, in: launcher)
        try need(calls.count == 1, "the launcher's call to FirstLogon.ps1")
        let got = calls[0][1].split(separator: " ").map(String.init)
        var want = Set(launcherSwitches.filter { on($0.id) }.map(\.name))
        if on("no_visual_tweaks") { want.insert("-NoVisualTweaks") }
        try need(got.count == Set(got).count && Set(got) == want,
                 "launcher switches \(got.sorted()) instead of \(want.sorted())")
        try need(launcher.contains("$_.VolumeLabel -eq 'WINBAR_SETUP' -or (Test-Path ($_.Name + 'FirstLogon.ps1'))"),
                 "the launcher must find the CD by label or content")
        try need(!allMatches(launcherCatch, in: launcher).isEmpty, "the launcher must catch a script that can't run")
        try need(launcher.contains("'result=failed', 'guest_tools=-1', ('rdp=' + $r)"), "the launcher's fallback status lines")
        try need(launcher.contains(#"$t = $o + '\status.tmp'"#) && launcher.contains(#"Move-Item $t ($o + '\status.txt') -Force"#),
                 "the launcher must write status.tmp, then rename it")

        // The password must have reached the file only as the obscured Value of each <Password>. Proved
        // by rendering the same inputs again with the control password and requiring the two files to be
        // the same once each has its own obscured value taken out: any other place the password reached
        // would differ. Last, so a file broken another way reports that instead.
        try need(occurrences(of: obscure(password), in: xml) == passwords.count, "the obscured password must appear once per <Password>")
        let control = try renderXML(inputs, password: controlPassword)
        try need(xml.replacingOccurrences(of: obscure(password), with: "")
                    == control.replacingOccurrences(of: obscure(controlPassword), with: ""),
                 "the password reached the file outside <Password><Value>")

        var byPass: [(String, [String])] = []
        for (pass, component) in components {
            let short = attribute(component, "name").replacingOccurrences(of: "Microsoft-Windows-", with: "")
            if let i = byPass.firstIndex(where: { $0.0 == pass }) { byPass[i].1.append(short) } else { byPass.append((pass, [short])) }
        }
        return "\(xml.unicodeScalars.count) B | RunSync \(named("RunSynchronousCommand").count) | FirstLogon "
            + "\(named("SynchronousCommand").count) | launcher \(launcher.unicodeScalars.count) ch | "
            + byPass.map { "\($0.0): \($0.1.joined(separator: ", "))" }.joined(separator: " ; ")
    }

    /// The password of the control render the leak rule compares against. `validate` refuses control
    /// characters in a password, so no real one can be this and make the comparison vacuous.
    static let controlPassword = "\u{1}winbar control render\u{1}"

    private static func occurrences(of needle: String, in text: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var from = text.startIndex
        while let found = text.range(of: needle, range: from..<text.endIndex) {
            count += 1
            from = found.upperBound
        }
        return count
    }

    private static let launcherCall = regex(#"& \(\$v\.Name \+ 'FirstLogon\.ps1'\)((?: -[A-Za-z]+)*); "#)
    private static let launcherCatch = regex(#"try \{ & \(\$v\.Name .*?\} catch \{ \$e = "#)

    /// Every leaf element under each component, with its path from the component (the Python renderer's `leaves`).
    private static func leaves(_ components: [(pass: String, element: XMLElement)]) -> [(path: [String], element: XMLElement)] {
        var found: [(path: [String], element: XMLElement)] = []
        func walk(_ e: XMLElement, _ path: [String]) {
            let kids = elementChildren(e)
            if kids.isEmpty { found.append((path, e)) }
            for kid in kids { walk(kid, path + [kid.localName ?? ""]) }
        }
        for (_, component) in components {
            for kid in elementChildren(component) { walk(kid, [kid.localName ?? ""]) }
        }
        return found
    }

    private static func elementChildren(_ e: XMLElement) -> [XMLElement] { (e.children ?? []).compactMap { $0 as? XMLElement } }

    private static func childElements(_ e: XMLElement, _ name: String) -> [XMLElement] {
        elementChildren(e).filter { $0.localName == name && $0.uri == namespace }
    }

    /// The element and everything under it, in document order (ElementTree's `iter`).
    private static func descendants(_ e: XMLElement) -> [XMLElement] {
        [e] + elementChildren(e).flatMap { descendants($0) }
    }

    private static func attribute(_ e: XMLElement, _ name: String) -> String { e.attribute(forName: name)?.stringValue ?? "" }

    // MARK: - Regular expressions, with the Python renderer's semantics

    private static func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        // The patterns are literals: a bad one is a programming error, caught by the first test run.
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static func fullMatch(_ text: String, _ pattern: NSRegularExpression) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = pattern.firstMatch(in: text, options: [.anchored], range: range) else { return false }
        return match.range == range
    }

    /// Each match's groups as strings (group 0 is the whole match; a group that didn't take part is "").
    private static func allMatches(_ pattern: NSRegularExpression, in text: String) -> [[String]] {
        let ns = text as NSString
        return pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
            (0..<match.numberOfRanges).map { match.range(at: $0).location == NSNotFound ? "" : ns.substring(with: match.range(at: $0)) }
        }
    }

    /// Python's `re.sub` with a function: every non-overlapping match, left to right, replaced by `transform`.
    private static func replace(_ pattern: NSRegularExpression, in text: String, _ transform: ([String]) throws -> String) rethrows -> String {
        let ns = text as NSString
        var out = ""
        var last = 0
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let groups = (0..<match.numberOfRanges).map {
                match.range(at: $0).location == NSNotFound ? "" : ns.substring(with: match.range(at: $0))
            }
            out += try transform(groups)
            last = match.range.location + match.range.length
        }
        return out + ns.substring(from: last)
    }
}
