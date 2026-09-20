import Foundation
import Testing
@testable import Winbar

// `winbar diagnose`, with no Mac under it: the shape of the file, what happens to a section that
// can't be gathered, how a log is trimmed, what a crash report's headline is, where the file goes —
// and, at the end, the one that matters most: a whole report built out of fixtures that are full of
// secrets, with nothing left in it that anyone would mind publishing.
//
// Nothing here reaches UTM, a VM, the user's defaults or the file system.

/// Things nobody should be able to find in a finished report. They go into the fixtures below in
/// the shapes a log really writes them in — labelled, quoted, or passed as a flag — because that is
/// the only kind a sweep can find. A bare word with nothing to say it is a password is not
/// findable by anything, which is why the rule Winbar actually relies on is the other one: never
/// write one down (see `CreateLog`, and `AnswerFileTests`' own canary).
private enum Canary {
    static let password = "Hunter2-Correct-Horse-Battery"
    static let productKey = "AB3DE-FGHJK-LMNPQ-RSTUV-WXYZ2"
    static let token = "ghp_0123456789abcdefghijABCDEFGHIJ0123"
    static let email = "someone.private@example.com"
    static let all = [password, productKey, token, email]
}

/// A create log from an install that went wrong, written the way `CreateLog` writes one — including
/// the three things that must not come out the other side.
private let logFixture = """
    2026-09-19 17:02:11  winbar create 0.1.0 starting for VM winlab01
    2026-09-19 17:02:11  plan: 6 vCPUs, 16384 MB, 64 GiB disk
    2026-09-19 17:02:12  answer file rendered (password=\(Canary.password))
    2026-09-19 17:02:12  Product key: \(Canary.productKey)
    2026-09-19 17:04:50  guest tools: downloaded, sha-256 checked
    2026-09-19 17:22:03  FirstLogon.ps1 -Autologon -Password '\(Canary.password)'
    2026-09-19 17:22:41  registry key: HKLM\\SYSTEM\\CurrentControlSet\\Control\\Terminal Server
    2026-09-19 17:23:02  reported by \(Canary.email)
    2026-09-19 17:23:09  api_key = \(Canary.token)
    2026-09-19 17:23:10  stage failed: E_RESULT_FAILED
    """

/// The first two lines of a real UTM .ips, in miniature: a JSON header line, then the report.
private let crashFixture = """
    {"app_name":"UTM","timestamp":"2026-09-19 23:24:59.00 +0200","app_version":"4.7.5","bundleID":"com.utmapp.UTM"}
    {
      "faultingThread" : 0,
      "exception" : {"type":"EXC_BREAKPOINT","signal":"SIGTRAP"},
      "termination" : {"indicator":"Trace/BPT trap: 5"},
      "procPath" : "/Applications/UTM.app/Contents/MacOS/UTM",
      "threads" : [{"triggered":true,"queue":"com.apple.main-thread","frames":[{"imageOffset":2129896,"imageIndex":0}]},
                   {"frames":[{"imageOffset":8,"imageIndex":1}]}],
      "usedImages" : [{"name":"UTM","path":"/Applications/UTM.app/Contents/MacOS/UTM"},
                      {"name":"libsystem_kernel.dylib"}]
    }
    """

/// The older plain-text form, which some .ips files still are.
private let textCrashFixture = """
    Process:             UTM [78411]
    Date/Time:           2026-09-19 15:51:56.123 -0400
    Exception Type:      EXC_BAD_ACCESS (SIGSEGV)

    Thread 3 Crashed:
    0   UTM       0x00000001004a1f14 -[VMDisplayWindowController windowDidLoad] + 92
    1   AppKit    0x00000001912b2210 0x1912a0000 + 73744
    """

/// One VM's worth of settings, as `UserDefaults` hands them over: Winbar's keys mixed in with the
/// global defaults every process inherits, and one value with an address in it.
private let settingsFixture: [String: Any] = [
    "vmName": "winlab01",
    "vmID": "9F3C1D2E-4B5A-4C6D-8E7F-0A1B2C3D4E5F",
    "settingsMigrated": true,
    "lastUpdateCheck": Date(timeIntervalSince1970: 1_790_000_000),
    "passwordCheckedFor": ["WINLAB01\\Bruno"],
    "vm.9F3C1D2E-4B5A-4C6D-8E7F-0A1B2C3D4E5F.name": "winlab01",
    "vm.9F3C1D2E-4B5A-4C6D-8E7F-0A1B2C3D4E5F.rdpHost": "winlab01.local",
    "vm.9F3C1D2E-4B5A-4C6D-8E7F-0A1B2C3D4E5F.rdpUser": "Bruno",
    "vm.9F3C1D2E-4B5A-4C6D-8E7F-0A1B2C3D4E5F.consoleEnabled": false,
    "vm.9F3C1D2E-4B5A-4C6D-8E7F-0A1B2C3D4E5F.sharedFolder": "/Users/rosa/Shared-with-Windows",
    // Not Winbar's, and none of its business: the domain answers for these too.
    "AppleLanguages": ["en-GB"],
    "NSWindowTabbingShoudShowTabBarKey-NSWindow-…": true,
    "com.apple.trackpad.scaling": 0.6875,
    "someOtherApp.contactEmail": Canary.email,
]

/// What `SelfTest.launchAsApp` comes back with: the app's own answers, parsed into pairs. A VM that
/// is up and answering, with Accessibility not yet granted — the shape of the report that says
/// "Connect doesn't work".
private let selfTestFixture = [
    "winbar": "0.1.0",
    "vm": "winlab01",
    "qemu running": "true",
    "console enabled": "false",
    "vcpus": "6",
    "memory mb": "16384",
    "utmctl present": "true",
    "accessibility": "false",
    "login item": "requiresApproval",
    "windows app": "/Applications/Windows App.app",
    "vm mac": "72:F0:FF:9A:C1:86",
    "leased ip": "192.168.64.7",
    "vm bridge": "bridge100",
    "rdp readiness": "blocked",
]

private let doctorFixture = [
    "Winbar 0.1.0, VM winlab01",
    "",
    "Host",
    "  ✓ H1  UTM installed           UTM 4.7.5",
    "  ✗ H2  VM                      no VM called winlab01 in UTM",
    "        why: Everything else is about one VM, so there has to be one.",
    "",
    "Guest",
    "  ✓ G5  Account and password    Bruno, local, with a password (checked before)",
    "",
    "1 error.",
]

/// The whole report, assembled out of the fixtures above — the same pieces `Diagnose.run` puts
/// together, without the half that talks to the Mac.
private func fixtureReport(mode: Redactor.Mode = .verbatim,
                           identity: Redactor.Identity = .none,
                           includeLogs: Bool = true) -> String {
    let redactor = Redactor(mode: mode, identity: identity)
    let sections = [
        Diagnose.section(Diagnose.headings.environment) {
            Diagnose.facts([("Winbar", "0.1.0"),
                            ("Installed from", Diagnose.installedFrom(appPath: "/Applications/Winbar.app", homebrew: true)),
                            ("Mac", "Mac16,6 — Apple M5 Max, 18 cores, 128 GB memory")])
        },
        Diagnose.section(Diagnose.headings.doctor) { doctorFixture },
        Diagnose.section(Diagnose.headings.selfTest) { Diagnose.selfTestLines(.success(selfTestFixture)) },
        Diagnose.section(Diagnose.headings.settings) { Diagnose.settingsLines(settingsFixture) },
        Diagnose.section(Diagnose.headings.logs) {
            guard includeLogs else { return ["Left out, because this was run with --no-logs."] }
            let trimmed = Diagnose.trim(logFixture, lines: 200, bytes: 256 << 10)
            return ["create-winlab01-20260919-1702.log — \(trimmed.note)", trimmed.text]
                + Diagnose.jobStateLines(statePath: "~/Library/Application Support/Winbar/Create/create-x.noindex/state.json",
                                         base: "~/Library/Application Support/Winbar/Create")
        },
        Diagnose.section(Diagnose.headings.crashes) {
            Diagnose.crashHeadline(fileName: "UTM-2026-09-19-232459.ips", contents: crashFixture, modified: nil)
        },
    ]
    let preamble = Diagnose.preamble(version: "0.1.0", stamp: "2026-09-20 at 12:00:00 +02:00",
                                     redactor: redactor, includeLogs: includeLogs)
    return Diagnose.Report(preamble: preamble, sections: sections).text(redactor)
}

// MARK: - The file someone is about to send

@Suite("A report anyone can read before they send it")
struct DiagnoseReportShape {
    @Test("The first lines say what the file is, what is in it and what is not")
    func preambleExplainsItself() {
        let text = fixtureReport()
        let first = text.components(separatedBy: "\n")[0]
        #expect(first.contains("Winbar diagnostic report"))
        #expect(first.contains("bug report"))
        // What it contains, listed before any of it appears.
        let header = text.components(separatedBy: "1. Versions and environment\n---")[0]
        for heading in ["Versions and environment", "winbar doctor", "settings", "create log", "crash reports"] {
            #expect(header.contains(heading), "the top of the file should mention \(heading)")
        }
        #expect(header.contains("never in here"))
        #expect(header.contains("Windows password"))
    }

    @Test("Every section is there, in the order the file promises")
    func sectionsInOrder() {
        let text = fixtureReport()
        var searched = text.startIndex..<text.endIndex
        for heading in [Diagnose.headings.environment, Diagnose.headings.doctor, Diagnose.headings.selfTest,
                        Diagnose.headings.settings, Diagnose.headings.logs, Diagnose.headings.crashes] {
            guard let found = text.range(of: heading, range: searched) else {
                Issue.record("\(heading) is missing, or out of order")
                return
            }
            searched = found.upperBound..<text.endIndex
        }
    }

    @Test("Each heading is underlined, so the file reads as a document and not a dump")
    func headingsAreUnderlined() {
        let lines = fixtureReport().components(separatedBy: "\n")
        guard let index = lines.firstIndex(of: Diagnose.headings.doctor) else {
            Issue.record("no doctor heading")
            return
        }
        #expect(lines[index + 1] == String(repeating: "-", count: Diagnose.headings.doctor.count))
    }

    @Test("The doctor table goes in exactly as doctor prints it, why and how included")
    func doctorTableIsReproduced() {
        let text = fixtureReport()
        for line in doctorFixture where !line.isEmpty {
            #expect(text.contains(line), "the table lost: \(line)")
        }
    }

    @Test("--no-logs says so where the logs would have been, rather than saying nothing")
    func noLogsIsStillASection() {
        let text = fixtureReport(includeLogs: false)
        #expect(text.contains(Diagnose.headings.logs))
        #expect(text.contains("--no-logs"))
        #expect(!text.contains("E_RESULT_FAILED"))
    }

    @Test("A section with nothing to say says that, instead of leaving a heading over a hole")
    func emptySectionSaysSo() {
        let section = Diagnose.section("5. Recent UTM crash reports") { [] }
        #expect(section.lines == ["Nothing to report here."])
    }

    @Test("Sentences the report writes itself are wrapped; the doctor table is not")
    func longSentencesWrap() {
        let wrapped = Diagnose.wrap(String(repeating: "word ", count: 60), at: 40)
        #expect(wrapped.count > 1)
        #expect(wrapped.allSatisfy { $0.count <= 40 })
        #expect(wrapped.joined(separator: " ") == String(repeating: "word ", count: 60).trimmingCharacters(in: .whitespaces))
        // A word longer than the width still gets a line of its own rather than being cut.
        #expect(Diagnose.wrap("short " + String(repeating: "x", count: 80), at: 40).count == 2)
    }
}

// MARK: - The rule the whole command rests on

@Suite("Each section stands on its own")
struct DiagnoseSectionsAreIndependent {
    private struct Broken: Error, CustomStringConvertible {
        var description: String { "the log directory couldn't be read" }
    }

    @Test("One section that can't be gathered costs its own paragraph and nothing else")
    func oneFailureDoesNotTakeTheRest() {
        let sections = [
            Diagnose.section("1. First") { ["the first fact"] },
            Diagnose.section("2. Second") { throw Broken() },
            Diagnose.section("3. Third") { ["the third fact"] },
        ]
        let text = Diagnose.Report(preamble: ["A report."], sections: sections).text(Redactor(mode: .verbatim))
        #expect(text.contains("the first fact"))
        #expect(text.contains("the third fact"))
        #expect(text.contains("2. Second"))
        #expect(text.contains("the log directory couldn't be read"))
        #expect(text.contains("unaffected"))
    }

    @Test("Every section can fail at once and the file is still a file")
    func allOfThemAtOnce() {
        let sections = (1...5).map { n in Diagnose.section("\(n). Section") { throw Broken() } }
        let text = Diagnose.Report(preamble: ["A report."], sections: sections).text(Redactor(mode: .verbatim))
        #expect(text.components(separatedBy: "couldn't be gathered").count == 6)   // five of them
        #expect(text.hasSuffix("\n"))
    }

    @Test("A Mac with no VM, no settings and no logs still produces every section")
    func theEmptyMac() {
        #expect(Diagnose.settingsLines([:]).joined(separator: " ").contains("no settings on this Mac"))
        #expect(Diagnose.settingsLines(["AppleLanguages": ["en"]]).joined(separator: " ").contains("no settings"))
        let logs = try? Diagnose.logLines(includeLogs: true,
                                          directory: URL(fileURLWithPath: "/nowhere/Library/Logs/Winbar"),
                                          lines: 200, bytes: 1 << 20)
        #expect(logs?.joined(separator: " ").contains("no winbar create logs") == true)
        let crashes = try? Diagnose.crashLines(directory: URL(fileURLWithPath: "/nowhere/DiagnosticReports"), limit: 3)
        #expect(crashes?.joined(separator: " ").contains("no crash report folder") == true)
    }
}

// MARK: - Redaction, proven

@Suite("Nothing anyone would mind publishing")
struct DiagnoseRedaction {
    /// The one the feature is for: a whole report, built from fixtures that hold a real-looking
    /// password, product key, API token and email address, with none of them in the output.
    @Test("A report built from fixtures full of secrets contains none of them")
    func noSecretSurvives() {
        for mode in [Redactor.Mode.verbatim, .anonymised] {
            let text = fixtureReport(mode: mode, identity: Redactor.Identity(userName: "rosa", vmNames: ["winlab01"]))
            for secret in Canary.all {
                #expect(!text.contains(secret), "\(secret) reached the report in \(mode) mode")
            }
            // And the lines they were on are still there, so what was taken out is visible.
            #expect(text.contains("answer file rendered"))
            #expect(text.contains("<removed>"))
        }
    }

    @Test("Each shape a secret arrives in is found")
    func everyShape() {
        let swept = Redactor.withoutSecrets("""
            password=\(Canary.password)
            Password: \(Canary.password)
            "client_secret" = "\(Canary.password)"
            FirstLogon.ps1 -Password '\(Canary.password)'
            api_key = \(Canary.token)
            token=\(Canary.token)
            Product key: \(Canary.productKey)
            \(Canary.productKey)
            write to \(Canary.email) about it
            """)
        for secret in Canary.all { #expect(!swept.contains(secret), "\(secret) survived the sweep") }
    }

    @Test("A private key goes whole, not line by line")
    func privateKeys() {
        let swept = Redactor.withoutSecrets("""
            -----BEGIN OPENSSH PRIVATE KEY-----
            b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtz
            c2gtZWQyNTUxOQAAACDqxHCpN1vPSECRETMATERIALdoNotPublish0000000000
            -----END OPENSSH PRIVATE KEY-----
            """)
        #expect(!swept.contains("SECRETMATERIAL"))
        #expect(swept.contains("<private key removed>"))
    }

    /// The other half of the promise: a sweep that ate the report would be no use either.
    @Test("The doctor table survives the sweep untouched")
    func noFalsePositives() {
        let table = doctorFixture.joined(separator: "\n") + """

            ✓ G5  Account and password    Bruno, local, with a password (checked before)
            ? G8  Sign in at boot         no password is stored for Bruno
                  how: registry key: HKLM\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Winlogon
            · G10 Drivers and tools       UTM Guest Tools 0.1.271; guest agent 109.1.0
            vmMAC: 72:F0:FF:9A:C1:86
            """
        #expect(Redactor.withoutSecrets(table) == table)
    }

    @Test("Verbatim leaves the names alone and says so at the top")
    func verbatimSaysWhatItIs() {
        let redactor = Redactor(mode: .verbatim, identity: Redactor.Identity(userName: "rosa", vmNames: ["winlab01"]))
        #expect(redactor.apply("/Users/rosa/winlab01") == "/Users/rosa/winlab01")
        #expect(redactor.explanation.contains("verbatim"))
        #expect(redactor.explanation.contains("--anonymise"))
    }

    @Test("--anonymise replaces the Mac, the user and the VMs, and says which mode made the file")
    func anonymiseReplacesNames() {
        let identity = Redactor.Identity(userName: "rosa", fullUserName: "Rosa Klebb", computerName: "Bluebird",
                                         hostNames: ["bluebird.local"], vmNames: ["winlab01", "atelier"],
                                         windowsUsers: ["Bruno"])
        let redactor = Redactor(mode: .anonymised, identity: identity)
        let text = redactor.apply("""
            rosa on Bluebird (bluebird.local), by Rosa Klebb
            VM winlab01 shares /Users/rosa/Shared-with-Windows with Bruno; atelier is off
            """)
        for name in ["rosa", "Bluebird", "bluebird.local", "Rosa Klebb", "winlab01", "atelier", "Bruno"] {
            #expect(!text.localizedCaseInsensitiveContains(name), "\(name) survived --anonymise")
        }
        #expect(text.contains("<user>"))
        #expect(text.contains("<mac>"))
        #expect(text.contains("/Users/<user>/Shared-with-Windows"))
        #expect(text.contains("<windows-user-1>"))
        #expect(redactor.explanation.contains("anonymised"))
    }

    @Test("Placeholders are stable: the same VM is the same number every time")
    func placeholdersAreStable() {
        func placeholders(_ names: [String]) -> String {
            Redactor(mode: .anonymised, identity: Redactor.Identity(vmNames: names))
                .apply("atelier winlab01 zebra")
        }
        // Sorted before they are numbered, so the order they were found in doesn't change the file.
        #expect(placeholders(["winlab01", "atelier", "zebra"]) == placeholders(["zebra", "winlab01", "atelier"]))
        #expect(placeholders(["winlab01", "atelier", "zebra"]) == "<vm-1> <vm-2> <vm-3>")
    }

    /// The bug the first draft had: a user whose short name is the start of a longer word turned
    /// Winbar's own repository — in the very line telling them where to send the file — into
    /// `<user>313/winbar`.
    @Test("A name is replaced where it stands alone, not where it is part of a longer word")
    func wholeWordsOnly() {
        let redactor = Redactor(mode: .anonymised, identity: Redactor.Identity(userName: "rosa", vmNames: ["win"]))
        let text = redactor.apply("github.com/rosa313/winbar, /Users/rosa/x, winbar, win, win-11")
        #expect(text.contains("github.com/rosa313/winbar"))
        #expect(text.contains("/Users/<user>/x"))
        #expect(text.contains("winbar,"))          // "win" is not the whole word here
        #expect(text.contains("<vm-1>,"))          // but here it is
        #expect(text.contains("<vm-1>-11"))        // and a hyphen is a boundary, so this one too
    }

    @Test("A name too short to replace safely is kept, and the report admits it")
    func shortNamesAreDeclaredNotMangled() {
        let redactor = Redactor(mode: .anonymised, identity: Redactor.Identity(userName: "jo", vmNames: ["winlab01"]))
        #expect(redactor.kept == ["jo"])
        #expect(redactor.apply("jo joins /Users/jo") == "jo joins /Users/jo")
        #expect(redactor.explanation.contains("too short"))
        #expect(redactor.explanation.contains("jo"))
    }

    @Test("Nothing to replace is not an error")
    func emptyIdentity() {
        let redactor = Redactor(mode: .anonymised, identity: .none)
        #expect(redactor.replacements.isEmpty)
        #expect(redactor.apply("a plain report") == "a plain report")
    }
}

// MARK: - Trimming

@Suite("A log trimmed to something sendable")
struct DiagnoseTrimming {
    private func lines(_ count: Int) -> String { (1...count).map { "line \($0)" }.joined(separator: "\n") }

    @Test("The last 200 lines, and a sentence saying how many are not here")
    func theTail() {
        let trimmed = Diagnose.trim(lines(1000), lines: 200, bytes: 1 << 20)
        #expect(trimmed.text.hasPrefix("line 801\n"))
        #expect(trimmed.text.hasSuffix("line 1000"))
        #expect(trimmed.text.components(separatedBy: "\n").count == 200)
        #expect(trimmed.note == "The last 200 lines of 1,000; 800 earlier lines are not here.")
    }

    @Test("A log short enough to send whole is sent whole, and says so")
    func shortLogsAreWhole() {
        let trimmed = Diagnose.trim(lines(3), lines: 200, bytes: 1 << 20)
        #expect(trimmed.text == "line 1\nline 2\nline 3")
        #expect(trimmed.note == "All 3 lines are here.")
        #expect(Diagnose.trim(lines(1), lines: 200, bytes: 1 << 20).note == "All 1 line is here.")
    }

    @Test("The trailing newline is not a line")
    func trailingNewline() {
        #expect(Diagnose.trim("one\ntwo\n", lines: 200, bytes: 1 << 20).note == "All 2 lines are here.")
    }

    @Test("An empty log says it is empty")
    func empty() {
        #expect(Diagnose.trim("", lines: 200, bytes: 1 << 20) == Diagnose.Trimmed(text: "", note: "The file is empty."))
    }

    /// A serial log can be one enormous burst of firmware text with no newline in it, so the byte
    /// limit has to be able to cut inside a line — otherwise the choice is the whole megabyte or
    /// nothing at all.
    @Test("One enormous line is cut by bytes, not dropped whole")
    func theByteLimit() {
        let huge = String(repeating: "x", count: 100_000) + "END"
        let trimmed = Diagnose.trim(huge, lines: 200, bytes: 10_000)
        #expect(trimmed.text.utf8.count <= 10_000)
        #expect(trimmed.text.hasSuffix("END"))   // the end is where the failure is
        #expect(trimmed.note.contains("cut from the front"))
    }
}

// MARK: - Crash reports

@Suite("What a UTM crash report's headline says")
struct DiagnoseCrashReports {
    @Test("The file, when it happened, what killed it, and the top frame of the thread that died")
    func theHeadline() {
        let lines = Diagnose.crashHeadline(fileName: "UTM-2026-09-19-232459.ips", contents: crashFixture, modified: nil)
        #expect(lines[0] == "UTM-2026-09-19-232459.ips — 2026-09-19 23:24:59.00 +0200, UTM 4.7.5")
        #expect(lines[1].contains("EXC_BREAKPOINT"))
        #expect(lines[1].contains("SIGTRAP"))
        #expect(lines[2].contains("thread 0"))
        #expect(lines[2].contains("com.apple.main-thread"))
        // No symbols in a release build, so the image and the offset into it are the fact that
        // identifies the crash.
        #expect(lines[2].contains("UTM+2129896"))
        // The headline, not the report: no thread but the crashing one, and no stack below the top.
        #expect(lines.count == 3)
        #expect(!lines.joined().contains("libsystem_kernel"))
    }

    @Test("A symbol, when there is one, reads as a name in an image")
    func withSymbols() {
        let contents = """
            {"app_name":"UTM","timestamp":"2026-09-01 10:00:00.00 +0000","app_version":"4.7.5"}
            {"faultingThread":1,"threads":[{"frames":[]},{"triggered":true,"frames":[{"symbol":"-[VM start]","imageIndex":0}]}],
             "usedImages":[{"name":"UTM"}]}
            """
        #expect(Diagnose.crashTopFrame(contents) == "thread 1 crashed; its top frame: -[VM start] in UTM")
    }

    @Test("The older plain-text form is read too, not reported as unreadable")
    func plainTextReports() {
        let lines = Diagnose.crashHeadline(fileName: "UTM-2026-09-19-155156.ips", contents: textCrashFixture, modified: nil)
        #expect(lines[0].contains("2026-09-19 15:51:56.123 -0400"))
        #expect(lines.joined(separator: " ").contains("EXC_BAD_ACCESS"))
        #expect(lines.last?.contains("windowDidLoad") == true)
    }

    @Test("An unreadable report costs its own line and nothing else")
    func rubbishIsSurvivable() {
        let lines = Diagnose.crashHeadline(fileName: "UTM-broken.ips", contents: "not a crash report at all",
                                           modified: Date(timeIntervalSince1970: 1_790_000_000))
        #expect(lines[0].hasPrefix("UTM-broken.ips — "))
        #expect(lines[0].contains("2026"))   // it fell back to the file's own date
        #expect(lines.last?.contains("couldn't be read") == true)
    }

    @Test("A report with no date at all still has a line")
    func noDateAnywhere() {
        let lines = Diagnose.crashHeadline(fileName: "UTM-x.ips", contents: "", modified: nil)
        #expect(lines[0] == "UTM-x.ips — date unknown")
    }
}

// MARK: - What the app itself sees

@Suite("The menu bar app's own answers")
struct DiagnoseSelfTest {
    private func text(_ answer: Result<[String: String], WinbarError>?) -> String {
        Diagnose.selfTestLines(answer).joined(separator: "\n")
    }

    /// The five facts nothing else in the file can answer, each named in words rather than left as
    /// the self-test's own key.
    @Test("Every row a Connect problem turns on is there, named for what it is")
    func theRowsThatMatter() {
        let report = text(.success(selfTestFixture))
        for (fact, label) in [("192.168.64.7", "The address macOS has leased the VM"),
                              ("bridge100", "The network interface Winbar probed"),
                              ("72:F0:FF:9A:C1:86", "The VM's MAC address"),
                              ("blocked", "Remote Desktop, on port 3389"),
                              ("waiting for you", "Launch at Login"),
                              ("no", "Accessibility, granted to Winbar itself")] {
            #expect(report.contains(label), "no row labelled \(label)")
            #expect(report.contains(fact), "\(label) lost its value")
        }
        // Not a dict dump: no raw key names, no braces.
        #expect(!report.contains("rdp readiness:"))
        #expect(!report.contains("leased ip:"))
        #expect(!report.contains("["))
    }

    @Test("The answers someone is about to act on carry the sentence that says what to do")
    func valuesAreExplained() {
        func note(_ key: String, _ value: String) -> String { Diagnose.selfTestAnswer(key: key, value).note ?? "" }
        #expect(note("rdp readiness", "blocked").contains("Local Network"))
        #expect(note("rdp readiness", "notReady").contains("still be booting"))
        #expect(note("rdp readiness", "ready").contains("network path Connect uses is open"))
        #expect(note("login item", "requiresApproval").contains("Login Items"))
        #expect(note("leased ip", "none").contains("no DHCP lease"))
        #expect(note("accessibility", "false").contains("Accessibility API"))
        // The answer itself stays short, so the column stays a column.
        #expect(Diagnose.selfTestAnswer(key: "rdp readiness", "blocked").value == "blocked")
        #expect(Diagnose.selfTestAnswer(key: "accessibility", "false").value == "no")
    }

    /// The first draft put a bare `(_, "true")` at the top of the switch, which answered for every
    /// row: "The VM's own process, seen by the app: yes".
    @Test("A row that says true in its own words is not overtaken by the general rule")
    func perRowWordsWinOverTrueAndFalse() {
        #expect(Diagnose.selfTestAnswer(key: "qemu running", "true").value == "running")
        #expect(Diagnose.selfTestAnswer(key: "qemu running", "false").value == "not running")
        #expect(Diagnose.selfTestAnswer(key: "utmctl present", "true").value == "present")
        #expect(Diagnose.selfTestAnswer(key: "login item", "enabled").value == "on")
        // A row with nothing of its own still gets the general rule.
        #expect(Diagnose.selfTestAnswer(key: "some future flag", "true").value == "yes")
        #expect(Diagnose.selfTestAnswer(key: "vm bridge", "bridge100").value == "bridge100")
    }

    /// A table whose rows run off the side of the page is a table nobody reads.
    @Test("No line in the section is wider than a terminal")
    func linesStayReadable() {
        for line in Diagnose.selfTestLines(.success(selfTestFixture)) {
            #expect(line.count <= 110, "too wide to read: \(line)")
        }
    }

    @Test("It says whose answers these are, because a shell's would be the terminal's")
    func whoseAnswersTheseAre() {
        let report = text(.success(selfTestFixture))
        #expect(report.contains("not this terminal's"))
        #expect(report.contains("Winbar launches itself to ask"))
    }

    @Test("Rows the rest of the file already carries are left out on purpose")
    func noDuplication() {
        let report = text(.success(selfTestFixture))
        for elsewhere in ["vcpus", "memory mb", "console enabled"] {
            #expect(!report.contains(elsewhere), "\(elsewhere) belongs to section 1 and the doctor table")
        }
    }

    /// A row the self-test grows later must appear somewhere rather than vanish because this file
    /// has never heard of it.
    @Test("A self-test row this code doesn't know about is still printed")
    func unknownRowsSurvive() {
        var values = selfTestFixture
        values["spice port"] = "5930"
        #expect(text(.success(values)).contains("spice port"))
        #expect(text(.success(values)).contains("5930"))
    }

    @Test("A row the app didn't report says so, rather than showing a blank")
    func missingRows() {
        var values = selfTestFixture
        values["leased ip"] = nil
        #expect(text(.success(values)).contains("the app didn't report this"))
    }

    /// The case on the Mac this was written on: a bare `swift build` has no app bundle to launch,
    /// so the question can't be put at all — which is not the same as the answer being bad news.
    @Test("The app that couldn't be asked is distinguished from a VM that's broken")
    func theAppCouldNotBeAsked() {
        let report = text(.failure(WinbarError("Not running from Winbar.app",
                                               "This binary isn't inside the app bundle, so the app's own "
                                                   + "permissions can't be checked.")))
        #expect(report.contains("Not running from Winbar.app"))
        // Flattened first: this sentence is wrapped, and a line break inside it is not a change of
        // meaning worth failing over.
        #expect(report.replacingOccurrences(of: "\n", with: " ").contains("is missing because the VM is broken"))
        #expect(!report.contains("192.168"))
    }

    @Test("No doctor run means the app was never asked, and it points at why")
    func doctorNeverFinished() {
        let report = text(nil)
        #expect(report.contains("wasn't asked"))
        #expect(report.contains("section 2"))
        #expect(report.contains("again"))   // and what to do about it
    }
}

@Suite("The install job's state is named, not copied")
struct DiagnoseJobState {
    @Test("The path goes in; the JSON does not")
    func pathOnly() {
        let lines = Diagnose.jobStateLines(statePath: "~/Library/Application Support/Winbar/Create/create-x.noindex/state.json",
                                           base: "~/Library/Application Support/Winbar/Create")
        let text = lines.joined(separator: "\n")
        #expect(text.contains("create-x.noindex/state.json"))
        #expect(text.contains("ask for it"))
        #expect(!text.contains("{"))
    }

    @Test("With no job, it says where one would be")
    func noJob() {
        let text = Diagnose.jobStateLines(statePath: nil, base: "~/Library/Application Support/Winbar/Create")
            .joined(separator: "\n")
        #expect(text.contains("No winbar create job"))
        #expect(text.contains("~/Library/Application Support/Winbar/Create"))
        #expect(text.contains("state.json"))
    }
}

// MARK: - Settings

@Suite("Winbar's settings, verbatim but tidy")
struct DiagnoseSettings {
    @Test("Only Winbar's own keys, out of a domain full of everybody's")
    func onlyWinbarsKeys() {
        let kept = Diagnose.winbarKeys(Array(settingsFixture.keys))
        #expect(kept.contains("vmName"))
        #expect(kept.contains("vm.9F3C1D2E-4B5A-4C6D-8E7F-0A1B2C3D4E5F.rdpUser"))
        #expect(!kept.contains("AppleLanguages"))
        #expect(!kept.contains("com.apple.trackpad.scaling"))
        #expect(!kept.contains("someOtherApp.contactEmail"))
        // "name" is a per-VM key, never a global one: a domain-wide `name` belongs to somebody else.
        #expect(!Diagnose.winbarKeys(["name"]).contains("name"))
    }

    @Test("One block per VM, with what each key says")
    func groupedByVM() {
        let text = Diagnose.settingsLines(settingsFixture).joined(separator: "\n")
        #expect(text.contains("This copy of Winbar"))
        #expect(text.contains("VM \"winlab01\" (vm.9F3C1D2E-4B5A-4C6D-8E7F-0A1B2C3D4E5F.*)"))
        #expect(text.contains("rdpHost:"))
        #expect(text.contains("winlab01.local"))
        // Another app's key is not in here, whatever the domain handed over.
        #expect(!text.contains("someOtherApp"))
        #expect(!text.contains(Canary.email))
    }

    @Test("Values are written for a person, not as UserDefaults keeps them")
    func valuesAreReadable() {
        #expect(Diagnose.describe(true) == "yes")
        #expect(Diagnose.describe(false) == "no")
        #expect(Diagnose.describe(6) == "6")
        #expect(Diagnose.describe("winlab01") == "winlab01")
        #expect(Diagnose.describe(["a", "b"]) == "a, b")
        #expect(Diagnose.describe([]) == "(empty list)")
        #expect(Diagnose.describe(nil) == "(not set)")
        #expect(Diagnose.describe(Date(timeIntervalSince1970: 0)).hasPrefix("1970-01-01"))
    }

    @Test("A VM whose record predates its UTM id is filed under its name, and reads that way")
    func recordsFiledUnderAName() {
        let text = Diagnose.settingsLines(["vm.winlab01.rdpUser": "Bruno"]).joined(separator: "\n")
        #expect(text.contains("VM \"winlab01\""))
        #expect(!text.contains("(vm.winlab01.*)"))   // the id would be noise when it is the name
    }
}

// MARK: - Where the file goes

@Suite("Where the report is written")
struct DiagnoseDestination {
    private let desktop = URL(fileURLWithPath: "/Users/rosa/Desktop")
    private let home = URL(fileURLWithPath: "/Users/rosa")
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    @Test("It is named for the day, so two people's reports are never the same file")
    func namedForTheDay() {
        let name = Diagnose.fileName(for: now)
        #expect(name.hasPrefix("winbar-diagnose-"))
        #expect(name.hasSuffix(".txt"))
        #expect(name.range(of: "\\d{4}-\\d{2}-\\d{2}", options: .regularExpression) != nil)
    }

    @Test("With no --out it goes to the Desktop, where somebody about to attach it will look")
    func desktopByDefault() {
        let url = Diagnose.destination(out: nil, desktop: desktop, fallback: home, now: now,
                                       isDirectory: { $0 == self.desktop }, exists: { _ in false })
        #expect(url == desktop.appendingPathComponent(Diagnose.fileName(for: now)))
    }

    @Test("No Desktop is not a failure: the home folder takes it")
    func noDesktop() {
        let url = Diagnose.destination(out: nil, desktop: desktop, fallback: home, now: now,
                                       isDirectory: { _ in false }, exists: { _ in false })
        #expect(url == home.appendingPathComponent(Diagnose.fileName(for: now)))
    }

    @Test("Running it twice in a day keeps both")
    func twiceInADay() {
        let first = desktop.appendingPathComponent(Diagnose.fileName(for: now))
        let url = Diagnose.destination(out: nil, desktop: desktop, fallback: home, now: now,
                                       isDirectory: { $0 == self.desktop }, exists: { $0 == first })
        #expect(url.lastPathComponent == first.deletingPathExtension().lastPathComponent + "-2.txt")
    }

    @Test("--out a folder puts today's file in it; --out a file is taken at its word")
    func outIsObeyed() {
        let folder = URL(fileURLWithPath: "/tmp/reports")
        #expect(Diagnose.destination(out: "/tmp/reports", desktop: desktop, fallback: home, now: now,
                                     isDirectory: { $0 == folder }, exists: { _ in false })
                == folder.appendingPathComponent(Diagnose.fileName(for: now)))
        // A path someone typed means that path, even when something is already there.
        #expect(Diagnose.destination(out: "/tmp/mine.txt", desktop: desktop, fallback: home, now: now,
                                     isDirectory: { _ in false }, exists: { _ in true })
                == URL(fileURLWithPath: "/tmp/mine.txt"))
        // And ~ means what a shell would have made of it.
        let tilde = Diagnose.destination(out: "~/mine.txt", desktop: desktop, fallback: home, now: now,
                                         isDirectory: { _ in false }, exists: { _ in false })
        #expect(!tilde.path.hasPrefix("~"))
        #expect(tilde.lastPathComponent == "mine.txt")
    }

    @Test("An empty --out is the same as none")
    func emptyOut() {
        #expect(Diagnose.destination(out: "  ", desktop: desktop, fallback: home, now: now,
                                     isDirectory: { $0 == self.desktop }, exists: { _ in false })
                == desktop.appendingPathComponent(Diagnose.fileName(for: now)))
    }
}

// MARK: - Odds and ends

@Suite("The environment section's own rules")
struct DiagnoseEnvironment {
    @Test("How Winbar got here decides what its owner can be told to do about it")
    func howItWasInstalled() {
        #expect(Diagnose.installedFrom(appPath: "/Applications/Winbar.app", homebrew: true).contains("Homebrew cask"))
        #expect(Diagnose.installedFrom(appPath: "/Applications/Winbar.app", homebrew: false).contains("disk image"))
        #expect(Diagnose.installedFrom(appPath: nil, homebrew: false).contains("bare build"))
        // Whichever it is, it says where, because two copies is a real bug report.
        #expect(Diagnose.installedFrom(appPath: "/Users/rosa/Downloads/Winbar.app", homebrew: false)
            .contains("/Users/rosa/Downloads/Winbar.app"))
    }

    @Test("An app that isn't installed says so rather than printing a blank")
    func missingApps() {
        #expect(Diagnose.appDescription(nil, path: nil, extra: nil) == "not installed")
        #expect(Diagnose.appDescription(nil, path: "/Applications/UTM.app", extra: "running")
                == "version unreadable, at /Applications/UTM.app, running")
        #expect(Diagnose.appDescription("4.7.5", path: "/Applications/UTM.app", extra: nil)
                == "4.7.5, at /Applications/UTM.app")
    }

    @Test("Facts line up, however long the longest label is")
    func factsLineUp() {
        let lines = Diagnose.facts([("Winbar", "0.1.0"), ("Installed from", "the Homebrew cask")])
        #expect(lines[0] == "Winbar:         0.1.0")
        #expect(lines[1] == "Installed from: the Homebrew cask")
    }

    @Test("Every Windows account the settings name is found, whichever VM it belongs to")
    func windowsUsers() {
        let found = Diagnose.windowsUserNames(["vm.a.rdpUser": "Bruno", "vm.b.rdpUser": "Rosa",
                                               "vm.a.rdpHost": "a.local", "rdpUser": "notAVMsKey"])
        #expect(Set(found) == ["Bruno", "Rosa"])
    }
}

