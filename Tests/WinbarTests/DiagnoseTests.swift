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

/// Ids in the shape UTM and Windows App write them, invented for these tests and belonging to
/// nothing on any Mac. `winlab01`'s is the one the settings fixture is filed under. `atelier`'s
/// sorts *after* it deliberately, so that a test can tell "numbered for its VM" apart from
/// "numbered by its own sort order". The saved PC's belongs to no VM at all: Winbar keeps the saved
/// PC's name and host, never its id, so nothing on this Mac can say which VM that one is.
private enum SyntheticID {
    static let winlab01 = "9F3C1D2E-4B5A-4C6D-8E7F-0A1B2C3D4E5F"
    static let atelier = "F1E2D3C4-B5A6-4978-8A1B-2C3D4E5F6071"
    static let savedPC = "D15C0FFE-BEEF-4CAF-8ADE-C0FFEE123456"
    /// Every group of this one is a word somebody could have called something: `deadbeef` a Mac
    /// user, `cafe` a VM, `0123456789ab` a host name. It is in the create log so that the backstop
    /// test below can hand the `Redactor` exactly those names and prove that a needle which is also
    /// a group of an id doesn't get to break the id's shape and take the rest of it out of reach.
    static let hexTrap = "DEADBEEF-CAFE-4A1B-9C2D-0123456789AB"

    static let all = [winlab01, atelier, savedPC, hexTrap]
}

/// A MAC address, invented, in the shape UTM and the running QEMU process write one.
private let fixtureMAC = "5A:2B:3C:4D:5E:6F"

/// The groups of an id that are long enough to identify it on their own. What is left when
/// something replaces one group out of the middle: `<user>-<vm-1>-4A1B-9C2D-0123456789AB` is not
/// id-shaped any more, so a test that only looks for the shape sees nothing wrong while twelve
/// characters of a real id go into a public issue.
private func fragmentsOf(_ id: String) -> [String] {
    id.components(separatedBy: "-").filter { $0.count >= 8 }
}

/// The 8-4-4-4-12 shape, written out here rather than borrowed from `Redactor`, so that a hole in
/// the rule can't also be the hole in the test that is supposed to catch it.
private let idShape = try! NSRegularExpression(
    pattern: "(?<![A-Za-z0-9])[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}(?![A-Za-z0-9])")

/// The first line that differs, for a failure message. A whole report compared character for
/// character is a useless thing to print; the line that moved is the thing to look at.
private func difference(_ got: String, _ want: String) -> Comment {
    let mine = got.components(separatedBy: "\n"), theirs = want.components(separatedBy: "\n")
    for (index, pair) in zip(mine, theirs).enumerated() where pair.0 != pair.1 {
        return """
            the report changed at line \(index + 1):
               now: \(pair.0)
              was: \(pair.1)
            """
    }
    return "the report is \(mine.count) lines; it was \(theirs.count)"
}

private func idsIn(_ text: String) -> [String] {
    let text = text as NSString
    return idShape.matches(in: text as String, range: NSRange(location: 0, length: text.length))
        .map { text.substring(with: $0.range) }
}

/// A create log from an install that went wrong, written the way `CreateLog` writes one — including
/// the three things that must not come out the other side.
private let logFixture = """
    2026-09-19 17:02:11  winbar create 0.1.0 starting for VM winlab01
    2026-09-19 17:02:11  plan: 6 vCPUs, 16384 MB, 64 GiB disk
    2026-09-19 17:02:12  answer file rendered (password=\(Canary.password))
    2026-09-19 17:02:12  Product key: \(Canary.productKey)
    2026-09-19 17:04:12  drive \(SyntheticID.hexTrap) attached (Win11_24H2.iso)
    2026-09-19 17:04:50  guest tools: downloaded, sha-256 checked
    2026-09-19 17:22:03  FirstLogon.ps1 -Autologon -Password '\(Canary.password)'
    2026-09-19 17:22:41  registry key: HKLM\\SYSTEM\\CurrentControlSet\\Control\\Terminal Server
    2026-09-19 17:23:02  reported by \(Canary.email)
    2026-09-19 17:23:09  api_key = \(Canary.token)
    2026-09-19 17:23:09  guest getmac: \(fixtureMAC.replacingOccurrences(of: ":", with: "-")) (Ethernet)
    2026-09-19 17:23:09  lease table: \(fixtureMAC.replacingOccurrences(of: ":", with: "")) -> 192.168.64.7
    2026-09-19 17:23:09  fabric port guid 00:02:c9:03:00:12:34:56
    2026-09-19 17:23:10  ✓ saved the PC "winbox" in Windows App for winbox.local (id \(SyntheticID.savedPC))
    2026-09-19 17:23:11  stage failed: E_RESULT_FAILED
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
    "vmID": SyntheticID.winlab01,
    "settingsMigrated": true,
    "lastUpdateCheck": Date(timeIntervalSince1970: 1_790_000_000),
    "passwordCheckedFor": ["WINBOX\\Bruno"],
    "vm.\(SyntheticID.winlab01).name": "winlab01",
    "vm.\(SyntheticID.winlab01).rdpHost": "winbox.local",
    "vm.\(SyntheticID.winlab01).rdpUser": "Bruno",
    "vm.\(SyntheticID.winlab01).savedPCName": "winbox",
    "vm.\(SyntheticID.winlab01).savedPCHost": "winbox.local",
    "vm.\(SyntheticID.winlab01).vmMAC": fixtureMAC,
    "vm.\(SyntheticID.winlab01).consoleEnabled": false,
    "vm.\(SyntheticID.winlab01).sharedFolder": "/Users/rosa/Shared-with-Windows",
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
    "vm mac": fixtureMAC,
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

    /// The other half of the same promise, and the one the ids were added for: an anonymised report
    /// is published, so not one id may come out the other side — not the VM's id in the settings,
    /// not the id inside every one of that VM's keys, and not the saved-PC or drive ids in the
    /// create log, which nothing on this Mac can tie to a VM at all. The identity here names the VM
    /// but not its id on purpose: that is the Mac whose settings Winbar has never had UTM's list
    /// beside, and it must still not leak.
    ///
    /// The names it is given are hex, and that is the whole point of them. This test used to hand
    /// the `Redactor` `rosa` and `winlab01`, so every id in the fixtures took the clean path and the
    /// assertion passed by construction — it could not have failed. A VM called `cafe`, a Mac user
    /// called `deadbeef` and a host name that is twelve hex digits are each exactly one
    /// hyphen-delimited group of an id in the fixtures, which is the case that was broken: replacing
    /// the name first destroyed the 8-4-4-4-12 shape, so the shape rule never matched and most of a
    /// real id was published.
    ///
    /// Which is also why the shape alone is not the assertion. A mangled id isn't id-shaped, so
    /// `idsIn` sees nothing while `<user>-<vm-1>-4A1B-9C2D-0123456789AB` sits in the file. The
    /// groups are checked too: no eight or twelve characters of any of these ids, in any case, in
    /// any part of the report.
    ///
    /// **And then the whole file, pinned.** The paragraph above used to end by advertising the
    /// fragment assertions as the thing that could fail, and they cannot: `fragmentsOf` yields the
    /// hex groups of ids that are in the fixtures, every one of which is replaced by a rule with its
    /// own test, and `idsIn` only ever sees a whole 8-4-4-4-12. Exactly one line here — the one
    /// asking for `drive <id-` — could go red under the regression this test is named for, and a
    /// test whose docstring promises more cover than its assertions carry is worse than a missing
    /// test, because it is counted. So the last assertion is the finished file, character for
    /// character. It fails on any change to any rule, which is the point: a diff in it has to be
    /// read and agreed to rather than passing because the one line that still mattered was kept.
    @Test("No id survives an anonymised report — whole, or with one group eaten out of it")
    func noIDSurvivesAnonymised() {
        // `deadbeef` and `cafe` are the first two groups of the drive id in the create log;
        // `0a1b2c3d4e5f` is the last group of the VM's own id, twelve hex characters of host name.
        let identity = Redactor.Identity(userName: "deadbeef", hostNames: ["0a1b2c3d4e5f"], vmNames: ["cafe"])
        let text = fixtureReport(mode: .anonymised, identity: identity)
        #expect(idsIn(text).isEmpty, "these ids reached a published report: \(idsIn(text))")
        for id in SyntheticID.all {
            for fragment in fragmentsOf(id) {
                #expect(!text.localizedCaseInsensitiveContains(fragment),
                        "\(fragment) — \(fragment.count) characters of \(id) — reached a published report")
            }
        }
        // The lines they were on are still here, so a reader can see what was taken and from where.
        #expect(text.contains("vmID:"))
        #expect(text.contains("saved the PC"))
        #expect(text.contains("drive <id-"))

        // The whole of it. One value in the settings is a `Date`, which `describe` writes in this
        // Mac's own time zone, so that one is asked of the same formatter rather than written out —
        // everything else here is fixed by the fixtures.
        let stampedAt = Diagnose.settingDate.string(from: Date(timeIntervalSince1970: 1_790_000_000))
        let expected = #"""
            Winbar diagnostic report — everything an answerable bug report about Winbar needs, in one file.
            Made by winbar diagnose (Winbar 0.1.0) on 2026-09-20 at 12:00:00 +02:00.

            What's in here, in order:
              1. Versions and environment — Winbar, macOS, this Mac, UTM, Windows App, the Guest Tools.
              2. What winbar doctor says — the whole table, with why and how for anything that isn't ✓.
              3. What the menu bar app itself sees — the VM's address on the network, whether Remote
                 Desktop answered, and the permissions that belong to Winbar rather than to a terminal.
              4. Winbar's own settings — the keys under net.elusive.winbar, one set per VM.
              5. The most recent winbar create log, and the serial log beside it — the tail of each.
              6. Recent UTM crash reports — the headline of each, because UTM crashing is often the answer.

            What's never in here: your Windows password, the answer file winbar create writes, or the
            contents of the setup disk. Winbar never writes a password down, and this report is swept for
            anything shaped like a password, a key or a token whatever section it came from.

            Mode: anonymised — this Mac's name, your Mac and Windows user names, the Windows PC name and the VM
            names have been replaced with <mac>, <user>, <user-full-name>, <windows-user-1>, <windows-pc-1> and
            <vm-1>, <vm-2>…. Where a VM's own name is in this file, the id UTM gave that VM is <vm-1-id>,
            <vm-2-id>… and its MAC address is <vm-1-mac>, <vm-2-mac>…, carrying the same number as the name, so
            the settings still say which VM each block is about. Every other id-shaped string (8-4-4-4-12 hex,
            or those same 32 characters unbroken) is <id-1>, <id-2>… and every other MAC address is
            <mac-address-1>, <mac-address-2>…, numbered in the order they first appear: Windows App's saved PC,
            a UTM drive, a scratch file — and a VM's own id or MAC lands here too whenever nothing in this file
            could say which VM it belongs to, because a number that pointed at no name would be a claim rather
            than a fact. A MAC address is found however it is written — xx:xx:xx:xx:xx:xx, xx-xx-xx-xx-xx-xx,
            xxxx.xxxx.xxxx or twelve unbroken hex characters, in either case — and a longer run of hex pairs is
            replaced whole rather than in part. Identifiers of other shapes — an IP address, a serial number, a
            build number — are left exactly as they are, and a name, an id or a MAC address is only replaced
            where it stands on its own. One thing is taken out of every report whichever mode made it, this one
            included: anything shaped like a password, a key, a token or an email address.

            Nothing here has left your Mac. Read it, take out anything you'd rather not publish, and attach
            it to your issue at https://github.com/taggie313/winbar/issues.


            1. Versions and environment
            ---------------------------
            Winbar:         0.1.0
            Installed from: the Homebrew cask, at /Applications/Winbar.app
            Mac:            Mac16,6 — Apple M5 Max, 18 cores, 128 GB memory


            2. What winbar doctor says
            --------------------------
            Winbar 0.1.0, VM winlab01

            Host
              ✓ H1  UTM installed           UTM 4.7.5
              ✗ H2  VM                      no VM called winlab01 in UTM
                    why: Everything else is about one VM, so there has to be one.

            Guest
              ✓ G5  Account and password    Bruno, local, with a password (checked before)

            1 error.


            3. What the menu bar app itself sees
            ------------------------------------
            These are the menu bar app's own answers, not this terminal's. macOS gives a privacy grant to
            whoever is responsible for a process, so Accessibility and Local Network asked from a shell are the
            terminal's grants and not Winbar's — a report built that way once said "ready" while Connect
            couldn't reach the VM at all. So Winbar launches itself to ask, and these are what it answered.

            Remote Desktop, on port 3389:                   blocked
                macOS's Local Network privacy stopped the check, so this says nothing about the VM: System
                Settings → Privacy & Security → Local Network → turn on Winbar.
            The address macOS has leased the VM:            192.168.64.7
            The VM's MAC address (which lease to look for): <mac-address-1>
            The network interface Winbar probed:            bridge100
            The VM's own process, seen by the app:          running
            Accessibility, granted to Winbar itself:        no
                Connect presses the saved PC's tile through the Accessibility API, so it can't work until
                this is on: System Settings → Privacy & Security → Accessibility → turn on Winbar.
            Launch at Login:                                waiting for you
                macOS is holding it in System Settings → General → Login Items.
            Windows App, where the app finds it:            /Applications/Windows App.app
            utmctl:                                         present


            4. Winbar's own settings
            ------------------------
            Read straight out of net.elusive.winbar. Every vm.<id>.* key belongs to one VM; the id is
            the one UTM gave it — a placeholder, in an anonymised report — or its name for a record
            made before Winbar knew the id.

            This copy of Winbar
              lastUpdateCheck:    \#(stampedAt)
              passwordCheckedFor: WINBOX\Bruno
              settingsMigrated:   yes
              vmID:               <id-1>
              vmName:             winlab01

            VM "winlab01" (vm.<id-1>.*)
              consoleEnabled: no
              name:           winlab01
              rdpHost:        winbox.local
              rdpUser:        Bruno
              savedPCHost:    winbox.local
              savedPCName:    winbox
              sharedFolder:   /Users/rosa/Shared-with-Windows
              vmMAC:          <mac-address-1>


            5. The most recent winbar create log
            ------------------------------------
            create-winlab01-20260919-1702.log — All 15 lines are here.
            2026-09-19 17:02:11  winbar create 0.1.0 starting for VM winlab01
            2026-09-19 17:02:11  plan: 6 vCPUs, 16384 MB, 64 GiB disk
            2026-09-19 17:02:12  answer file rendered (password=<removed>
            2026-09-19 17:02:12  Product key=<removed> key removed>
            2026-09-19 17:04:12  drive <id-2> attached (Win11_24H2.iso)
            2026-09-19 17:04:50  guest tools: downloaded, sha-256 checked
            2026-09-19 17:22:03  FirstLogon.ps1 -Autologon -Password <removed>
            2026-09-19 17:22:41  registry key: HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server
            2026-09-19 17:23:02  reported by <email removed>
            2026-09-19 17:23:09  api_key=<removed> removed>
            2026-09-19 17:23:09  guest getmac: <mac-address-1> (Ethernet)
            2026-09-19 17:23:09  lease table: <mac-address-1> -> 192.168.64.7
            2026-09-19 17:23:09  fabric port guid <mac-address-2>
            2026-09-19 17:23:10  ✓ saved the PC "winbox" in Windows App for winbox.local (id <id-3>)
            2026-09-19 17:23:11  stage failed: E_RESULT_FAILED

            The install job's own state — which stage it reached, when each one started, the VM it made — is in ~/Library/Application Support/Winbar/Create/create-x.noindex/state.json.
            It isn't copied in here (it's JSON, and the log above already carries the failure); ask for it if you want it.


            6. Recent UTM crash reports
            ---------------------------
            UTM-2026-09-19-232459.ips — 2026-09-19 23:24:59.00 +0200, UTM 4.7.5
                ended with: EXC_BREAKPOINT / SIGTRAP / Trace/BPT trap: 5
                thread 0 on com.apple.main-thread crashed; its top frame: UTM+2129896
            """# + "\n"
        #expect(text == expected, difference(text, expected))
    }

    /// The same promise for the other identifier a published report used to carry: the VM's MAC
    /// address, which is in the settings under `vmMAC` and in the app's own self-test.
    @Test("No MAC address survives an anonymised report either")
    func noMACSurvivesAnonymised() {
        let text = fixtureReport(mode: .anonymised,
                                 identity: Redactor.Identity(userName: "rosa", vmNames: ["winlab01"]))
        #expect(!text.localizedCaseInsensitiveContains(fixtureMAC))
        // Nothing here could say which VM it belongs to, so it is numbered as its own.
        #expect(text.contains("<mac-address-1>"))
        // And in every spelling the guest's own tools write it — the create log has the same card
        // hyphenated (getmac) and unbroken (a lease table), and none of the three may survive.
        for spelling in [fixtureMAC.replacingOccurrences(of: ":", with: "-"),
                         fixtureMAC.replacingOccurrences(of: ":", with: ""),
                         "5a2b.3c4d.5e6f"] {
            #expect(!text.localizedCaseInsensitiveContains(spelling), "\(spelling) reached a published report")
        }
        // One card is one number however it was written, so three lines about it still read as one.
        #expect(text.components(separatedBy: "<mac-address-1>").count - 1 >= 4)
        // A longer run of pairs — an eight-byte fabric GUID — is replaced whole, not six-eighths of
        // it beside a placeholder claiming the rest was dealt with.
        #expect(!text.contains(":34:56"))
        #expect(text.contains("fabric port guid <mac-address-2>"))
        // The lines it was on are still here, so a reader can see what was taken and from where.
        #expect(text.contains("The VM's MAC address"))   // the app's own self-test
        #expect(text.contains("vmMAC:"))                 // and the settings key
    }

    /// The control for the tests above: verbatim is the default, and nobody who didn't ask for it
    /// gets a report with the facts filed off.
    @Test("Verbatim keeps every id and every MAC exactly as it was")
    func verbatimKeepsEveryID() {
        let text = fixtureReport(mode: .verbatim, identity: Redactor.Identity(userName: "rosa", vmNames: ["winlab01"]))
        #expect(text.contains(SyntheticID.winlab01))
        #expect(text.contains("(vm.\(SyntheticID.winlab01).*)"))   // the block header names the namespace
        #expect(text.contains(SyntheticID.savedPC))
        #expect(text.contains(SyntheticID.hexTrap))
        #expect(text.contains(fixtureMAC))
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
            vmMAC: \(fixtureMAC)
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

    @Test("--anonymise replaces the Mac, the user, the VMs and their ids, and says which mode made the file")
    func anonymiseReplacesNames() {
        let identity = Redactor.Identity(userName: "rosa", fullUserName: "Rosa Klebb", computerName: "Bluebird",
                                         hostNames: ["bluebird.local"], vmNames: ["winlab01", "atelier"],
                                         vmIDs: [SyntheticID.winlab01: "winlab01"],
                                         windowsUsers: ["Bruno"])
        let redactor = Redactor(mode: .anonymised, identity: identity)
        let text = redactor.apply("""
            rosa on Bluebird (bluebird.local), by Rosa Klebb
            VM winlab01 (\(SyntheticID.winlab01)) shares /Users/rosa/Shared-with-Windows with Bruno; atelier is off
            """)
        for name in ["rosa", "Bluebird", "bluebird.local", "Rosa Klebb", "winlab01", "atelier", "Bruno",
                     SyntheticID.winlab01] {
            #expect(!text.localizedCaseInsensitiveContains(name), "\(name) survived --anonymise")
        }
        #expect(text.contains("<user>"))
        #expect(text.contains("<mac>"))
        #expect(text.contains("/Users/<user>/Shared-with-Windows"))
        #expect(text.contains("<windows-user-1>"))
        // winlab01 sorts second, so its id is the second VM's — see `eachIdFollowsItsOwnVM`.
        #expect(text.contains("VM <vm-2> (<vm-2-id>)"))
        #expect(redactor.explanation.contains("anonymised"))
    }

    /// The mode line is part of the report, so the sweep runs over it like every other line — and a
    /// draft of it that spelled the MAC spellings out with real hex came back as "a MAC address is
    /// found written <mac-address-1>, <mac-address-1>, <mac-address-1>…", having also taken the
    /// first number for itself and pushed every real card along by one. An explanation that is
    /// redacted by the thing it explains is worse than no explanation.
    @Test("The mode line survives its own rules: nothing in it is an id, a MAC or a name")
    func theModeLineIsNotItselfRedacted() {
        let identity = Redactor.Identity(userName: "rosa", fullUserName: "Rosa Klebb", computerName: "atelier",
                                         hostNames: ["atelier.local"], vmNames: ["winlab01"],
                                         vmIDs: [SyntheticID.winlab01: "winlab01"],
                                         vmMACs: [fixtureMAC: "winlab01"],
                                         windowsUsers: ["Bruno"], windowsPCNames: ["winbox"])
        let redactor = Redactor(mode: .anonymised, identity: identity)
        for mode in [Redactor.Mode.verbatim, .anonymised] {
            let line = Redactor(mode: mode, identity: identity).explanation
            #expect(redactor.apply(line) == line, "the \(mode) mode line redacts itself")
            #expect(Redactor.withoutSecrets(line) == line, "the \(mode) mode line trips the secret sweep")
        }
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

// MARK: - The ids, and which VM each one belongs to

/// A VM's id is the one identifier in the report that survives the VM being renamed, which is both
/// why Winbar files settings under it and why a published report shouldn't carry it. Masking it is
/// only worth anything if the report still says which VM it is: `vmID` and a whole block of
/// `vm.<id>.*` keys have to land on the same placeholder as the VM's own name, or section 4 stops
/// answering the question it exists to answer.
@Suite("Ids, replaced without losing which VM they belong to")
struct DiagnoseIDRedaction {
    private let twoVMs = Redactor.Identity(vmNames: ["winlab01", "atelier"],
                                           vmIDs: [SyntheticID.winlab01: "winlab01",
                                                   SyntheticID.atelier: "atelier"])

    @Test("A VM's id takes that VM's own number, so <vm-1> and <vm-1-id> are one VM")
    func idTakesItsVMsNumber() {
        let redactor = Redactor(mode: .anonymised,
                                identity: .init(vmNames: ["winlab01"], vmIDs: [SyntheticID.winlab01: "winlab01"]))
        #expect(redactor.apply("winlab01 is \(SyntheticID.winlab01)") == "<vm-1> is <vm-1-id>")
    }

    /// The break this is here to stop: numbering the ids by their own sort order instead of by the
    /// VM's. `atelier` sorts first by name and so is `<vm-1>`, while its id sorts *second* — number
    /// them apart and `<vm-1>` and `<vm-1-id>` are two different VMs, which is worse than printing
    /// the id, because it reads as a fact and isn't one.
    @Test("A second VM gets a second number, and its id follows its name and not its own sort order")
    func eachIdFollowsItsOwnVM() {
        let text = Redactor(mode: .anonymised, identity: twoVMs)
            .apply("atelier=\(SyntheticID.atelier) winlab01=\(SyntheticID.winlab01)")
        #expect(text == "<vm-1>=<vm-1-id> <vm-2>=<vm-2-id>")
        // Said the other way round, because this is the whole claim: the ids sort the other way.
        #expect(SyntheticID.atelier > SyntheticID.winlab01)
    }

    /// Winbar keeps a saved PC's name and host, never its id, so there is no key to map this one
    /// through. It gets a number of its own rather than a VM's — inventing a correspondence would
    /// be a guess dressed as a fact — but it does not get to stay in the file: a report is only as
    /// private as its worst line, and this is the line.
    @Test("An id nothing can name is still replaced, with a placeholder that claims nothing")
    func anIdNothingCanNameIsStillMasked() {
        let text = Redactor(mode: .anonymised, identity: twoVMs)
            .apply("saved the PC (id \(SyntheticID.savedPC)), disk \(SyntheticID.savedPC), drive 11111111-2222-3333-4444-555555555555")
        #expect(!text.localizedCaseInsensitiveContains(SyntheticID.savedPC))
        // The same id twice is the same number, so two lines about one thing still read as one.
        #expect(text.contains("saved the PC (id <id-1>), disk <id-1>"))
        #expect(text.contains("drive <id-2>"))
    }

    /// UTM hands its ids back uppercase and Windows App's are uppercase in 11.4.1, while a settings
    /// key carries whatever case the caller that wrote it held. `VMProcesses.find` and
    /// `UTM.otherRunningVMs` both compare case-insensitively for exactly this reason; so must this.
    @Test("An id is found in either case, and in a case the settings never wrote")
    func idsAreFoundInEitherCase() {
        let redactor = Redactor(mode: .anonymised,
                                identity: .init(vmNames: ["winlab01"], vmIDs: [SyntheticID.winlab01: "winlab01"]))
        #expect(redactor.apply(SyntheticID.winlab01.lowercased()) == "<vm-1-id>")
        #expect(redactor.apply(SyntheticID.winlab01.uppercased()) == "<vm-1-id>")
        // And an unplaceable one is one id however its two mentions are cased.
        #expect(Redactor(mode: .anonymised, identity: .init(vmNames: ["winlab01"]))
            .apply("\(SyntheticID.savedPC) \(SyntheticID.savedPC.lowercased())") == "<id-1> <id-1>")
    }

    /// The settings section is where the ids mostly live: one `vm.<id>.*` prefix per key, repeated
    /// for every key that VM has. The key has to stay readable as a key — that is how a reader knows
    /// which block they are in — so the boundary rule matters as much here as it does for names.
    @Test("An id inside a settings key goes, and the key still reads as a key")
    func settingsKeysKeepTheirShape() {
        let text = Redactor(mode: .anonymised, identity: twoVMs).apply("""
            vmID:  \(SyntheticID.winlab01)
            VM "winlab01" (vm.\(SyntheticID.winlab01).*)
            vm.\(SyntheticID.winlab01).rdpUser: Bruno
            """)
        #expect(text.contains("vmID:  <vm-2-id>"))
        #expect(text.contains("VM \"<vm-2>\" (vm.<vm-2-id>.*)"))
        #expect(text.contains("vm.<vm-2-id>.rdpUser"))
    }

    /// An id is a different shape from a name, but it wants the same boundary, and for the mirror
    /// of the same reason: a UUID's own hyphens are inside the needle, and everything that touches
    /// an id in this file is punctuation. What the boundary buys is that half an id is never taken
    /// out of a longer run of hex — the half left behind would still look like an id.
    @Test("An id is replaced whole or not at all, never out of the middle of something longer")
    func idsAreWholeWordsToo() {
        let redactor = Redactor(mode: .anonymised,
                                identity: .init(vmNames: ["winlab01"], vmIDs: [SyntheticID.winlab01: "winlab01"]))
        let sha = "deadbeef9F3C1D2E-4B5A-4C6D-8E7F-0A1B2C3D4E5Fcafe"
        #expect(redactor.apply(sha) == sha)
        #expect(redactor.apply("(id \(SyntheticID.winlab01)),") == "(id <vm-1-id>),")
    }

    /// The hole the `-id` suffix would have widened. `-` is a word boundary on purpose (a VM may be
    /// called `win-11`), so `vm`, `id` and `vm-1` all stand alone *inside* `<vm-1-id>`. A VM
    /// actually called `vm-1` used to be substituted into the placeholder a longer needle had just
    /// written. Everything is matched in one pass now, so nothing Winbar inserts is looked at again.
    @Test("A VM named after a placeholder can't corrupt another VM's")
    func placeholdersAreNotRewritten() {
        let identity = Redactor.Identity(vmNames: ["atelier", "vm-1", "winlab01"],
                                         vmIDs: [SyntheticID.atelier: "atelier"])
        let text = Redactor(mode: .anonymised, identity: identity).apply("atelier \(SyntheticID.atelier) vm-1")
        #expect(text == "<vm-1> <vm-1-id> <vm-2>")
    }

    /// Verbatim is the default and is not what this change is about. Nothing is replaced, and the
    /// shape-matching rule in particular never runs on a report nobody asked to have altered.
    @Test("Verbatim replaces no id, placeable or otherwise")
    func verbatimReplacesNoID() {
        let line = "vm.\(SyntheticID.winlab01).rdpUser (saved PC \(SyntheticID.savedPC)) winlab01"
        #expect(Redactor(mode: .verbatim, identity: twoVMs).apply(line) == line)
    }

    /// The bug the one pass is for, in the smallest shape it takes.
    ///
    /// A needle that is a person's word can also be a hyphen-delimited group of an id: a VM called
    /// `cafe`, a Mac user called `deadbeef`, a host name that is twelve hex digits. Replacing the
    /// needle first — which is what two passes did — broke the 8-4-4-4-12 shape, the rule that was
    /// meant to catch every id nobody could place then found nothing, and 27 of the id's 32
    /// characters went into a public issue. One ordered alternation settles it twice over: the id
    /// starts further left, and where a name starts at the very same character the id shape is
    /// listed first.
    @Test("A name that is also a group of an id does not get to eat the id")
    func aNameInsideAnIDLosesToTheID() {
        let redactor = Redactor(mode: .anonymised,
                                identity: .init(userName: "deadbeef", hostNames: ["0123456789ab"],
                                                vmNames: ["cafe"]))
        #expect(redactor.apply("drive deadbeef-cafe-4a1b-9c2d-0123456789ab here") == "drive <id-1> here")
        // And every one of those needles is still replaced where it really does stand on its own.
        #expect(redactor.apply("deadbeef cafe 0123456789ab") == "<user> <vm-1> <mac>")
    }

    /// An id is only worth a VM's number while that VM's own name is in the file to match against.
    /// A name too short to replace is published as itself and `kept` says so — there is no `<vm-1>`
    /// anywhere — so `<vm-1-id>` beside it would be a pointer to nothing. It falls back to being an
    /// id of its own, which claims only what is true.
    @Test("An id whose VM name was too short to replace is numbered as an id, not as that VM")
    func anIDWithNoVMToPointAt() {
        let redactor = Redactor(mode: .anonymised,
                                identity: .init(vmNames: ["jo"], vmIDs: [SyntheticID.winlab01: "jo"]))
        #expect(redactor.kept == ["jo"])
        #expect(redactor.apply("jo is \(SyntheticID.winlab01)") == "jo is <id-1>")
    }

    /// The same hole, one turn further round: a VM called what the Mac's user is called loses its
    /// needle to the dedupe, so `<vm-1>` is never written either.
    @Test("An id whose VM name was claimed by another placeholder is numbered as an id")
    func anIDWhoseVMNameWasClaimed() {
        let redactor = Redactor(mode: .anonymised,
                                identity: .init(userName: "winlab01", vmNames: ["winlab01"],
                                                vmIDs: [SyntheticID.winlab01: "winlab01"]))
        #expect(redactor.apply("winlab01 is \(SyntheticID.winlab01)") == "<user> is <id-1>")
    }

    /// The Windows registry and some of UTM's own output write the same id with its hyphens taken
    /// out. Masking one form and not the other would make the promise depend on which program
    /// happened to write the line.
    @Test("An id is found with its hyphens taken out, and is one id either way")
    func unbrokenIDs() {
        let unbroken = SyntheticID.winlab01.replacingOccurrences(of: "-", with: "")
        let placed = Redactor(mode: .anonymised,
                              identity: .init(vmNames: ["winlab01"], vmIDs: [SyntheticID.winlab01: "winlab01"]))
        #expect(placed.apply("HKLM\\...\\\(unbroken)") == "HKLM\\...\\<vm-1-id>")
        // And one nothing can place keeps one number across both forms, so two lines about one
        // thing still read as one thing.
        let unplaced = Redactor(mode: .anonymised, identity: .init(vmNames: ["winlab01"]))
        let both = "\(SyntheticID.savedPC) \(SyntheticID.savedPC.replacingOccurrences(of: "-", with: ""))"
        #expect(unplaced.apply(both) == "<id-1> <id-1>")
        // A longer run of hex is not an id with its hyphens taken out: a digest stays a digest.
        let digest = String(repeating: "ab", count: 32)
        #expect(unplaced.apply(digest) == digest)
    }

    /// `Diagnose.identity` uses this to decide what a settings namespace with no name in it is: an
    /// id, which the sweep numbers as `<id-N>`, or the VM's own name, which has to be replaced as a
    /// name or it is published verbatim. Whole string or nothing — half of a longer thing is not an
    /// id, and a VM may perfectly well be called something with an id inside it.
    @Test("An id is told from a VM name by being an id and nothing else")
    func idsAreRecognisedWhole() {
        #expect(Redactor.isID(SyntheticID.winlab01))
        #expect(Redactor.isID(SyntheticID.winlab01.lowercased()))
        #expect(!Redactor.isID("winlab01"))
        #expect(!Redactor.isID("vm-\(SyntheticID.winlab01)"))
        #expect(!Redactor.isID("\(SyntheticID.winlab01) and more"))
        #expect(!Redactor.isID(""))
    }

    /// The gathering side of it: three places know an id, and `Diagnose.identity` used to read all
    /// three and keep only the names. A record filed under a name rather than an id — what a record
    /// written before Winbar knew the id looks like — is a name and must not be offered as one.
    @Test("An id that is really a VM's name is not treated as an id")
    func aNameTokenIsNotAnId() {
        // The same string in both places is the pre-id record shape; it must stay `<vm-1>`.
        let redactor = Redactor(mode: .anonymised,
                                identity: .init(vmNames: ["winlab01"], vmIDs: ["winlab01": "winlab01"]))
        #expect(redactor.apply("vm.winlab01.rdpUser") == "vm.<vm-1>.rdpUser")
    }
}

// MARK: - The MAC address, and the name Windows knows itself by

/// The two identifiers a published report still carried after the box was ticked. A MAC is globally
/// unique by design and outlives the VM being renamed; the Windows machine name is in
/// `passwordCheckedFor` as `COMPUTERNAME\user` and in the RDP host derived from the guest's DNS
/// name, and on the Mac Winbar was written on it only *looked* masked, because Windows there is
/// named after its VM.
@Suite("The MAC and the Windows machine name, replaced like everything else")
struct DiagnoseMACRedaction {
    @Test("A VM's MAC takes that VM's own number, so <vm-1> and <vm-1-mac> are one VM")
    func macTakesItsVMsNumber() {
        let redactor = Redactor(mode: .anonymised,
                                identity: .init(vmNames: ["winlab01"], vmMACs: [fixtureMAC: "winlab01"]))
        #expect(redactor.apply("winlab01 vmMAC: \(fixtureMAC)") == "<vm-1> vmMAC: <vm-1-mac>")
        // UTM writes it uppercase and a QEMU command line lowercase; both are the same card.
        #expect(redactor.apply(fixtureMAC.lowercased()) == "<vm-1-mac>")
    }

    @Test("A MAC nothing can name is still replaced, with a placeholder that claims nothing")
    func anUnplacedMACIsStillMasked() {
        let text = Redactor(mode: .anonymised, identity: .init(vmNames: ["winlab01"]))
            .apply("vm mac \(fixtureMAC), again \(fixtureMAC.lowercased()); bridge 00:11:22:33:44:55")
        #expect(!text.localizedCaseInsensitiveContains(fixtureMAC))
        #expect(text.contains("<mac-address-1>, again <mac-address-1>"))
        #expect(text.contains("<mac-address-2>"))
    }

    /// The shape is six hex pairs and nothing else. A report is full of colons that are not MACs,
    /// and a rule that ate a timestamp would teach a reader to distrust the ones it didn't.
    @Test("Only six hex pairs are a MAC: a timestamp and an address are not")
    func theMACShapeIsNarrow() {
        let redactor = Redactor(mode: .anonymised, identity: .none)
        for untouched in ["17:02:11", "192.168.64.7", "5A:2B:3C:4D:5E", "12:34", "bridge100"] {
            #expect(redactor.apply(untouched) == untouched)
        }
    }

    @Test("Verbatim keeps the MAC exactly as it was")
    func verbatimKeepsTheMAC() {
        let line = "vmMAC: \(fixtureMAC)"
        #expect(Redactor(mode: .verbatim, identity: .init(vmNames: ["winlab01"],
                                                          vmMACs: [fixtureMAC: "winlab01"])).apply(line) == line)
    }

    /// The field the machine name actually reaches the report in. On a default install this reads
    /// `DESKTOP-4F8J2K1\Bruno`, and nothing in it resembles any name Winbar was already replacing.
    @Test("The Windows machine name goes, and so does the account beside it")
    func windowsPCNamesAreMasked() {
        let redactor = Redactor(mode: .anonymised,
                                identity: .init(vmNames: ["winlab01"], windowsUsers: ["Bruno"],
                                                windowsPCNames: ["DESKTOP-4F8J2K1"]))
        #expect(redactor.apply("passwordCheckedFor: DESKTOP-4F8J2K1\\Bruno")
                == "passwordCheckedFor: <windows-pc-1>\\<windows-user-1>")
        // The DNS form of the same name is what the RDP host is built from.
        #expect(redactor.apply("rdpHost: desktop-4f8j2k1.local") == "rdpHost: <windows-pc-1>.local")
    }

    /// A Mac where Windows was named after its VM is the case that hid this for so long: the two
    /// needles are the same string, and the VM's number is the more useful of the two placeholders
    /// because the id and the MAC are numbered to match it.
    @Test("A Windows machine named after its VM keeps the VM's placeholder")
    func aPCNamedAfterItsVM() {
        let redactor = Redactor(mode: .anonymised,
                                identity: .init(vmNames: ["winlab01"], windowsPCNames: ["winlab01"]))
        #expect(redactor.apply("winlab01") == "<vm-1>")
    }

    @Test("Both halves of every passwordCheckedFor key are gathered")
    func passwordCheckedNamesAreRead() {
        let found = Diagnose.passwordCheckedNames(["passwordCheckedFor": ["DESKTOP-4F8J2K1\\Bruno",
                                                                          "WINLAB01\\rosa", "malformed"],
                                                   "vmName": "winlab01"])
        #expect(Set(found.pcs) == ["DESKTOP-4F8J2K1", "WINLAB01"])
        #expect(Set(found.users) == ["Bruno", "rosa"])
        // The setting was a bare string before it was a list, and an old defaults file still is one.
        #expect(Diagnose.passwordCheckedNames(["passwordCheckedFor": "WINLAB01\\Bruno"]).pcs == ["WINLAB01"])
        #expect(Diagnose.passwordCheckedNames([:]).pcs.isEmpty)
    }

    /// The half that was missing, and the one that mattered most. `passwordCheckedFor` is only
    /// written after a logon probe has found a password, and `COMPUTERNAME`/`DNSHOST` need the VM to
    /// be running and answering — so on the Mac a report is usually written from, the one whose VM
    /// won't start, neither source had anything and the Windows machine name went out whole. It is
    /// in three settings that section 4 prints, and `Connection.resolveHost` writes it into one of
    /// them the first time Connect works.
    @Test("The Windows machine name is gathered from the settings that hold it when the VM is off")
    func pcNamesComeFromTheSettingsToo() {
        let found = Set(Diagnose.windowsPCNamesFromSettings([
            "vm.a.rdpHost": "winbox.local",
            "vm.a.savedPCName": "Winbox (the good one)",
            "vm.b.savedPCHost": "desktop-4f8j2k1.local",
            // Pre-migration settings are global rather than per-VM, and still printed.
            "rdpHost": "atelier-pc.local",
            // Not a host setting, and not this rule's business.
            "vm.a.rdpUser": "Bruno",
            "vm.a.sharedFolder": "/Users/rosa/Shared-with-Windows",
            // Somebody else's key that happens to end in one of the names.
            "someOtherApp.rdpHost": "not-ours.local",
        ]))
        #expect(found == ["winbox", "Winbox (the good one)", "desktop-4f8j2k1", "atelier-pc"])
    }

    /// `.local` is the suffix every mDNS name on every network has, so it names nobody and is left
    /// as the frame. What must not happen is one machine getting two numbers: the bare name is in
    /// `passwordCheckedFor` and in `savedPCName`, the dotted one in `rdpHost`, and two needles would
    /// read as two Windows installs.
    @Test("A host name and the bare name it is built from are one machine with one placeholder")
    func theLocalSuffixIsTheFrameNotTheName() {
        let names = Diagnose.windowsPCNamesFromSettings(["vm.a.rdpHost": "winbox.local",
                                                         "vm.a.savedPCName": "winbox",
                                                         "vm.a.savedPCHost": "WINBOX.local"])
        let redactor = Redactor(mode: .anonymised, identity: .init(vmNames: ["winlab01"], windowsPCNames: names))
        #expect(redactor.apply("rdpHost: winbox.local") == "rdpHost: <windows-pc-1>.local")
        #expect(redactor.apply("passwordCheckedFor: WINBOX\\Bruno") == "passwordCheckedFor: <windows-pc-1>\\Bruno")
        #expect(!redactor.explanation.contains("<windows-pc-2>"))
    }

    /// An address typed in place of a name is not a name: masking it as `<windows-pc-1>` would be a
    /// lie about what it is, and the same address is printed two sections earlier as the VM's lease,
    /// where nothing masks it and nothing should.
    @Test("An address in the host field is not taken for a machine name")
    func addressesAreNotNames() {
        #expect(Diagnose.windowsPCNamesFromSettings(["vm.a.rdpHost": "192.168.64.7",
                                                     "vm.b.rdpHost": "fe80::1",
                                                     "vm.c.rdpHost": "  "]).isEmpty)
        #expect(Diagnose.bareHostName("winbox.local.") == "winbox")
        #expect(Diagnose.bareHostName("WinBox.Local") == "WinBox")
        #expect(Diagnose.bareHostName("winbox") == "winbox")
    }

    /// The join itself, because `Diagnose.identity` reads the real defaults and no test may call it
    /// — so the settings source was wired in with nothing exercising the wiring, and a reviewer
    /// deleted that line with all 664 tests still green. Each source is the ONLY one carrying its
    /// name here, so dropping any one of the three fails this.
    @Test("Every source of the Windows PC name is used")
    func everySourceOfTheWindowsPCNameIsUsed() {
        let found = Set(Diagnose.windowsPCNames(
            settings: ["vm.a.rdpHost": "from-settings.local"],
            checked: ["FROM-PASSWORD-CHECK"],
            guestOutput: GuestOutput(pairs: [("COMPUTERNAME", "FROM-GUEST"),
                                             ("DNSHOST", "from-guest-dns")]),
            otherSavedPCNames: ["From C2's Row"]))
        #expect(found.contains("from-settings"))        // rdpHost, with .local taken off
        #expect(found.contains("From C2's Row"))        // another account's saved PC, this report's C2
        #expect(found.contains("FROM-PASSWORD-CHECK"))  // passwordCheckedFor
        #expect(found.contains("FROM-GUEST"))           // the short name Windows cuts to 15
        #expect(found.contains("from-guest-dns"))       // and the DNS form it doesn't cut
    }

    /// End to end, on the whole report, with nothing but the settings to go on — no guest output,
    /// no logon probe, the VM off. This is the case BLOCKING A was: the name is in `rdpHost`,
    /// `savedPCName` and `savedPCHost`, all three of which section 4 prints, and in the create log's
    /// saved-PC line, and none of them was being replaced.
    @Test("With the VM off, the Windows machine name still doesn't reach the report")
    func thePCNameWithTheVMOff() {
        let checked = Diagnose.passwordCheckedNames(settingsFixture)
        let identity = Redactor.Identity(
            userName: "rosa", vmNames: ["winlab01"],
            vmIDs: [SyntheticID.winlab01: "winlab01"],
            vmMACs: Diagnose.vmMACs(settingsFixture).values.reduce(into: [:]) { $0[$1] = "winlab01" },
            windowsUsers: Diagnose.windowsUserNames(settingsFixture) + checked.users,
            windowsPCNames: checked.pcs + Diagnose.windowsPCNamesFromSettings(settingsFixture))
        let text = fixtureReport(mode: .anonymised, identity: identity)
        #expect(!text.localizedCaseInsensitiveContains("winbox"), "the Windows PC name reached a published report")
        #expect(text.contains("rdpHost:"))                       // the line it was on is still here
        #expect(text.contains("<windows-pc-1>.local"))           // and reads as a host name still
        #expect(text.contains("<windows-pc-1>\\<windows-user-1>"))   // passwordCheckedFor
        #expect(text.contains("saved the PC \"<windows-pc-1>\""))    // and the create log
    }

    @Test("A MAC the settings remember is found under the VM it is filed against")
    func macsAreReadFromTheSettings() {
        let found = Diagnose.vmMACs(["vm.a.vmMAC": fixtureMAC, "vm.a.rdpUser": "Bruno",
                                     "vmMAC": "not a per-VM key", "vm.b.rdpHost": "b.local"])
        #expect(found == ["a": fixtureMAC])
    }
}

// MARK: - How a MAC address is spelled

/// Winbar's own settings hold one spelling, because UTM and QEMU write that one. The report also
/// carries a Windows guest's output and a create log full of it, and Windows, a registry value and
/// switch firmware each write the same six bytes differently. The rule used to know one of the four.
@Suite("A MAC address, in every spelling that reaches the report")
struct DiagnoseMACSpellings {
    private let hyphenated = "5A-2B-3C-4D-5E-6F"
    private let unbroken = "5A2B3C4D5E6F"
    private let dotted = "5a2b.3c4d.5e6f"

    @Test("An unplaceable MAC is found hyphenated, unbroken and dotted, and is one card in all four")
    func everySpellingIsFound() {
        let redactor = Redactor(mode: .anonymised, identity: .init(vmNames: ["winlab01"]))
        let text = redactor.apply("utm \(fixtureMAC) getmac \(hyphenated) lease \(unbroken) switch \(dotted)")
        #expect(text == "utm <mac-address-1> getmac <mac-address-1> lease <mac-address-1> switch <mac-address-1>")
    }

    /// The asymmetry this closes: an id had been taught its second spelling and a MAC had not, so
    /// the VM's own card — a known literal needle — was masked in the one spelling the settings
    /// happen to hold and published in the three the guest writes.
    @Test("A VM's own MAC keeps that VM's number in every spelling, not just the settings' one")
    func theKnownMACInEverySpelling() {
        let redactor = Redactor(mode: .anonymised,
                                identity: .init(vmNames: ["winlab01"], vmMACs: [fixtureMAC: "winlab01"]))
        for spelling in [fixtureMAC, fixtureMAC.lowercased(), hyphenated, hyphenated.lowercased(),
                         unbroken, unbroken.lowercased(), dotted, dotted.uppercased()] {
            #expect(redactor.apply("vmMAC: \(spelling)") == "vmMAC: <vm-1-mac>", "\(spelling) was not this VM's")
        }
    }

    /// The unbroken spelling is the one shape that is not extended to a longer run: the other three
    /// take `{5,}`/`{2,}` and swallow a longer run whole, while twelve-hex is exactly twelve so a
    /// hash is not mistaken for a card. The cost of that choice is this: one extra hex character
    /// beside the VM's own MAC and the boundary refuses the whole run, so the card ships. The known
    /// needle has to win here, because those twelve characters ARE the card whatever follows them.
    @Test("The VM's own card is masked even with a hex character stuck to it")
    func theKnownCardSurvivesAnAdjoiningHexDigit() {
        let redactor = Redactor(mode: .anonymised,
                                identity: .init(vmNames: ["winlab01"], vmMACs: [fixtureMAC: "winlab01"]))
        let unbroken = fixtureMAC.replacingOccurrences(of: ":", with: "")
        for trailing in ["0", "f", "AB"] {
            let text = redactor.apply("lease \(unbroken)\(trailing) end")
            #expect(!text.localizedCaseInsensitiveContains(unbroken),
                    "the card shipped beside a \"\(trailing)\": \(text)")
        }
        // And with one in front of it, which the boundary refuses at the other end.
        #expect(!redactor.apply("lease 0\(unbroken) end").localizedCaseInsensitiveContains(unbroken))
    }

    /// The one that was worse than a silent miss. Leftmost matching took the first six pairs of a
    /// longer run and wrote `<mac-address-1>`, leaving the last two bytes of a real hardware address
    /// beside a placeholder that said they had been dealt with.
    @Test("A run longer than six pairs is replaced whole, not six-eighths of it")
    func aLongerRunIsNotPartlyMasked() {
        let redactor = Redactor(mode: .anonymised,
                                identity: .init(vmNames: ["winlab01"], vmMACs: [fixtureMAC: "winlab01"]))
        let guid = "00:02:C9:03:00:12:34:56"
        #expect(redactor.apply("guid \(guid) end") == "guid <mac-address-1> end")
        // Including one that begins with the VM's own card, where the known needle is listed first
        // and would otherwise have matched its six pairs and stopped.
        let extended = fixtureMAC + ":00:01"
        let text = redactor.apply("port \(extended) end")
        #expect(!text.contains("<vm-1-mac>:"))
        #expect(!text.contains(":00:01"))
        #expect(text == "port <mac-address-1> end")
        // And the hyphenated spelling of the same trap.
        #expect(redactor.apply(hyphenated + "-00-01") == "<mac-address-1>")
    }

    /// The other half: a rule that ate things that are not MACs would teach a reader to distrust the
    /// ones it didn't. The unbroken form is exactly twelve hex characters, never part of a longer run.
    @Test("Only these shapes are a MAC: a timestamp, an address, a digest and an id are not")
    func theShapesStayNarrow() {
        let redactor = Redactor(mode: .anonymised, identity: .none)
        for untouched in ["17:02:11", "192.168.64.7", "5A:2B:3C:4D:5E", "12:34", "bridge100",
                          "5A-2B-3C-4D-5E", "5a2b.3c4d", "5A2B3C4D5E6", "5A2B3C4D5E6F7",
                          String(repeating: "ab", count: 32), "2026-09-19", "Win11_24H2.iso"] {
            #expect(redactor.apply(untouched) == untouched, "\(untouched) was taken for a MAC address")
        }
        // An id's own last group is twelve hex characters; the id starts further left and wins.
        #expect(redactor.apply(SyntheticID.winlab01) == "<id-1>")
        #expect(redactor.apply(SyntheticID.winlab01.replacingOccurrences(of: "-", with: "")) == "<id-1>")
    }

    /// The stated cost of the unbroken form, the mirror of `idPattern`'s own. A needle Winbar knows
    /// by name still wins, because `apply` looks a match up before it asks what shape it is.
    @Test("A name that is exactly twelve hex characters is still that name, not a MAC")
    func aKnownNameBeatsTheShape() {
        let redactor = Redactor(mode: .anonymised, identity: .init(hostNames: ["0a1b2c3d4e5f"]))
        #expect(redactor.apply("host 0a1b2c3d4e5f here") == "host <mac> here")
        // Nothing can name this one, so it reads as what it is shaped like. It is replaced either way.
        #expect(redactor.apply("card 0a1b2c3d4e50 here") == "card <mac-address-1> here")
    }
}

// MARK: - How a name is spelled

/// Two ways the same name arrives as two different strings, both of which published it whole.
@Suite("A name, however Unicode and the page width wrote it down")
struct DiagnoseNameSpellings {
    /// `NSFullUserName()` hands back NFC; an APFS path, and anything read back off the disk, is NFD.
    /// `NSRegularExpression` works on UTF-16 code units and has no canonical-equivalence mode, so
    /// `Renée` never matched `Rene\u{0301}e` and the whole name went into the report.
    @Test("An accented name is replaced composed or decomposed, whichever way the text has it")
    func bothCompositionForms() {
        let composed = "Ren\u{00E9}e Aubert"
        let decomposed = "Rene\u{0301}e Aubert"
        // Two different strings, whatever Swift's own == says of them: it compares canonically.
        #expect(Array(composed.utf16) != Array(decomposed.utf16))
        let redactor = Redactor(mode: .anonymised, identity: .init(fullUserName: composed))
        #expect(redactor.apply("by \(composed)") == "by <user-full-name>")
        #expect(redactor.apply("by \(decomposed)") == "by <user-full-name>")
        // And the other way round: the identity read off a path, the report written by a program
        // that composes.
        let fromAPath = Redactor(mode: .anonymised, identity: .init(fullUserName: decomposed))
        #expect(fromAPath.apply("by \(composed)") == "by <user-full-name>")
        #expect(fromAPath.apply("by \(decomposed)") == "by <user-full-name>")
    }

    /// The boundary half of the same problem: in decomposed text a shorter name ends where a
    /// combining mark begins, and `(?![A-Za-z0-9])` was happy to stop there.
    @Test("A shorter name is not replaced out of the middle of an accented one")
    func aCombiningMarkIsInsideAWord() {
        let redactor = Redactor(mode: .anonymised, identity: .init(userName: "Rene"))
        #expect(redactor.apply("Rene\u{0301}e Aubert") == "Rene\u{0301}e Aubert")
        #expect(redactor.apply("Rene Aubert") == "<user> Aubert")
    }

    /// `fullUserName` and `computerName` are exactly the needles that contain a space, and the
    /// report breaks its own prose at 100 columns. A literal needle replaced `Rosa` and published
    /// `Marchetti` — and because the first word *was* replaced, the line read as though it worked.
    @Test("A name with a space in it survives the line break the report itself inserts")
    func namesBrokenByTheReportsOwnWrapping() {
        let redactor = Redactor(mode: .anonymised,
                                identity: .init(fullUserName: "Rosa Marchetti", computerName: "Studio Mac"))
        // 87 characters, then " Rosa" makes 92, so "Marchetti" is 102 and goes to the next line.
        let sentence = String(repeating: "x", count: 87) + " Rosa Marchetti wrote this on Studio Mac today"
        let wrapped = Diagnose.wrap(sentence, at: 100).joined(separator: "\n")
        #expect(wrapped.contains("Rosa\nMarchetti"))          // the report really does break it here
        let text = redactor.apply(wrapped)
        #expect(!text.contains("Marchetti"))
        #expect(!text.contains("Studio"))
        #expect(text.contains("<user-full-name>"))
        #expect(text.contains("<mac>"))
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

    /// The byte limit used to land wherever the arithmetic put it, which is as readily in the middle
    /// of a UUID as between two words. `--anonymise` runs over the finished report, and the last
    /// twenty characters of an id are not id-shaped, so the sweep saw nothing and a fragment of a
    /// real identifier went out beside placeholders that had dealt with every whole one.
    @Test("The byte limit comes off in whole lines, so it can't cut an identifier in half")
    func theByteLimitTakesWholeLines() {
        let id = "9F3C1D2E-4B5A-4C6D-8E7F-0A1B2C3D4E5F"
        let filler = (1...40).map { "line \($0) " + String(repeating: "y", count: 200) }
        let log = (filler + ["drive \(id) attached", "stage failed"]).joined(separator: "\n")
        let trimmed = Diagnose.trim(log, lines: 200, bytes: 100)
        #expect(trimmed.text.utf8.count <= 100)
        // Whole lines, so the id is either all here or not here at all — never its tail.
        #expect(trimmed.text.contains("drive \(id) attached"))
        #expect(trimmed.text.hasSuffix("stage failed"))
        #expect(!trimmed.text.contains("yyy"))            // the filler went, whole
        #expect(trimmed.note.contains("still too big to send"))
        #expect(trimmed.note.contains("not because of the line limit"))
    }

    /// And when there is only one line left, the cut inside it stops at the first space rather than
    /// handing over the tail of whatever word it landed in.
    @Test("A cut inside the last line drops the word it lands in")
    func aCutInsideALineDropsThePartialWord() {
        let line = "prefix 9F3C1D2E-4B5A-4C6D-8E7F-0A1B2C3D4E5F tail-of-the-line"
        let trimmed = Diagnose.trim(line, lines: 200, bytes: 40)
        #expect(trimmed.text == "tail-of-the-line")        // not "-4C6D-8E7F-0A1B2C3D4E5F tail-of-…"
        #expect(!trimmed.text.contains("4E5F"))            // no fragment of the id survives
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
                              ("5A:2B:3C:4D:5E:6F", "The VM's MAC address"),
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
        #expect(text.contains("winbox.local"))
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

// MARK: - The way in that doesn't need Terminal

@Suite("Report a Problem…, for the people who have never opened Terminal")
struct DiagnoseFromTheMenu {
    @Test("The item reads like the rest of the menu, and its ellipsis is a promise that it asks first")
    func itemMatchesTheMenu() {
        #expect(Diagnose.Copy.menuItem.hasSuffix("…"))
        #expect(Diagnose.Copy.menuItem.first?.isUppercase == true)
        // No command name in it: somebody who has never seen `winbar diagnose` is the whole point.
        #expect(!Diagnose.Copy.menuItem.lowercased().contains("diagnose"))
    }

    @Test("The alert promises exactly the three things that then happen without asking again")
    func alertSaysWhatHappensNext() {
        let detail = Diagnose.Copy.askDetail
        #expect(detail.contains("minute or two"))     // it blinks for that long
        #expect(detail.contains("Finder"))            // it reveals the file
        #expect(detail.contains("issues page"))       // and opens the page to drag it into
        // The one thing anybody hesitating over a public issue wants answered first.
        #expect(detail.contains("never contains your Windows password"))
    }

    @Test("The alert names the placeholders the report actually uses")
    func alertAndReportAgree() {
        // The alert's promise and the report's own explanation of the same mode are written in two
        // places; this is what stops them drifting.
        let explanation = Redactor(mode: .anonymised,
                                   identity: .init(userName: "rosa", computerName: "atelier",
                                                   vmNames: ["winlab01"],
                                                   vmIDs: [SyntheticID.winlab01: "winlab01"])).explanation
        // `<vm-1-id>`, `<id-1>`, `<vm-1-mac>` and `<mac-address-1>` are in here because the guard is
        // only worth having if it covers the placeholders added last: masking the ids and the MAC
        // while telling nobody would leave this green.
        for placeholder in ["<mac>", "<user>", "<windows-pc-1>", "<vm-1>", "<vm-1-id>", "<vm-1-mac>",
                            "<id-1>", "<mac-address-1>"] {
            #expect(Diagnose.Copy.askDetail.contains(placeholder))
            #expect(explanation.contains(placeholder), "the report no longer writes \(placeholder)")
        }
        // The box itself stays short enough to line up with the text above it (see `anonymise`),
        // so it names them by what they are and leaves the examples to the paragraph.
        #expect(Diagnose.Copy.anonymise.contains("placeholders"))
        #expect(Diagnose.Copy.anonymise.count < 45)
        // And it says which flag it is, for anyone who goes looking for it afterwards.
        #expect(Diagnose.Copy.anonymiseHelp.contains("--anonymise"))
    }

    @Test("The tick is the whole of the difference between the menu's report and the command's")
    func onlyTheTickDiffers() {
        #expect(Diagnose.Options.fromTheMenu(anonymise: false).mode == .verbatim)
        #expect(Diagnose.Options.fromTheMenu(anonymise: true).mode == .anonymised)
        let menu = Diagnose.Options.fromTheMenu(anonymise: true)
        let defaults = Diagnose.Options()
        #expect(menu.out == nil)            // the Desktop, where somebody about to attach it will look
        #expect(menu.includeLogs)           // the logs are most of the answer
        #expect(menu.doctorTimeout == defaults.doctorTimeout)
        #expect(menu.logLines == defaults.logLines)
        #expect(menu.crashReports == defaults.crashReports)
    }

    @Test("Each step says where it has got to in both lengths, and the menu's fits on one line")
    func everyStepSpeaksToBothFrontEnds() {
        for step in Diagnose.Step.allCases {
            #expect(!step.sentence.isEmpty)
            #expect(!step.label.isEmpty)
            // A status line sits beside an icon in the menu bar; a terminal has the whole width and
            // nothing blinking, so it gets the reason too.
            #expect(step.label.count <= 40, "too long for the menu: \(step.label)")
            #expect(step.sentence.count >= step.label.count)
        }
        // The long wait is named as what it is waiting for, not as "working…".
        #expect(Diagnose.Step.doctor.label.contains("UTM"))
    }

    @Test("A report that couldn't go where it was meant to knows it")
    func writtenKnowsWhereItLanded() {
        let desktop = URL(fileURLWithPath: "/Users/rosa/Desktop/winbar-diagnose-2026-09-20.txt")
        let home = URL(fileURLWithPath: "/Users/rosa/winbar-diagnose-2026-09-20.txt")
        #expect(!Diagnose.Written(url: desktop, wanted: desktop, bytes: 4096, mode: .verbatim).wentSomewhereElse)
        #expect(Diagnose.Written(url: home, wanted: desktop, bytes: 4096, mode: .verbatim).wentSomewhereElse)
    }

    @Test("The page the menu opens is the page the report tells you to attach it to")
    func oneIssuesPage() {
        #expect(fixtureReport().contains(UpdateCheck.issuesURL.absoluteString))
        #expect(UpdateCheck.issuesURL.absoluteString == "https://github.com/\(UpdateCheck.repo)/issues")
    }
}
