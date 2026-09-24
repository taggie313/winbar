import AppKit
import Foundation
import Testing
@testable import Winbar

// Report a Problem… from the menu: allowed when it is most wanted (mid-install, mid-step), anonymised
// unless the person says otherwise, and landing on a new issue rather than the list of everyone else's.

private let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private func text(_ path: String) -> String {
    (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)) ?? ""
}

@Suite("Report a Problem… is there when things are stuck")
struct ReportProblemAdmissionTests {
    /// A first-time user whose install stalls has no VM chosen yet, and the New Windows VM window holds
    /// a `.create` lease for the whole install; the wizard holds `.setup` for its steps. Both used to
    /// refuse the report with "Winbar is busy".
    @Test("A report is admitted alongside an install, a set-up step and a menu operation")
    func admittedAlongsideAnything() throws {
        let held: [(AppWorkGate.Owner, String?)] = [(.create, nil), (.create, "winlab01"), (.setup, "winlab01"),
                                                    (.menu, "winlab01")]
        for (owner, vm) in held {
            let gate = AppWorkGate()
            let work = try gate.begin(owner, label: "working", vm: vm).get()
            // The old rule, still true for the menu's own operations: they wait.
            #expect((try? gate.begin(.menu, label: "starting", vm: "winlab01").get()) == nil, "\(owner)")
            #expect((try? gate.begin(.report, label: Diagnose.Copy.working, vm: nil).get()) != nil, "\(owner)")
            #expect((try? gate.begin(.report, label: Diagnose.Copy.working, vm: "winlab01").get()) != nil, "\(owner)")
            work.finish()
        }
    }

    /// It only reads, so it is never the reason something else is refused.
    @Test("A report in progress refuses nothing")
    func refusesNothing() throws {
        let gate = AppWorkGate()
        let report = try gate.begin(.report, label: Diagnose.Copy.working, vm: "winlab01").get()
        #expect((try? gate.begin(.setup, label: "restarting the VM", vm: "winlab01").get()) != nil)
        #expect((try? gate.begin(.create, label: "installing Windows", vm: "winlab01").get()) != nil)
        report.finish()
    }

    /// The delegate can't be made in a test (it puts an icon in the menu bar), so its one line that
    /// matters here is read as text.
    @Test("The menu's report asks for a report lease, not a menu one")
    func theMenuUsesIt() {
        let menuBar = text("Sources/Winbar/MenuBar.swift")
        #expect(menuBar.contains("begin(Diagnose.Copy.working, as: .report)"))
    }
}

@Suite("Report a Problem… publishes placeholders unless told otherwise")
@MainActor
struct ReportProblemPrivacyTests {
    /// Somebody who clicks straight through a dialog while something is broken should publish
    /// `<user-full-name>`, not their full name.
    @Test("The placeholders box is ticked when the dialog opens")
    func tickedByDefault() {
        #expect(Diagnose.Copy.anonymiseByDefault)
        let box = AppDelegate.anonymiseCheckbox()
        #expect(box.state == .on)
        #expect(box.title == Diagnose.Copy.anonymise)
        #expect(Diagnose.Options.fromTheMenu(anonymise: box.state == .on).mode == .anonymised)
    }

    @Test("The dialog says the placeholders are what it writes, and how to keep the names")
    func copySaysSo() {
        #expect(Diagnose.Copy.askDetail.contains("with the box below ticked"))
        #expect(Diagnose.Copy.askDetail.contains("Untick it"))
        #expect(Diagnose.Copy.askDetail.contains("new issue"))
    }
}

@Suite("Report a Problem… opens a new issue")
struct ReportProblemDestinationTests {
    @Test("The menu opens issues/new with the menu's own template, and the template exists")
    func newIssue() throws {
        let url = UpdateCheck.newIssueFromMenuURL
        #expect(url.path == "/\(UpdateCheck.repo)/issues/new")
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.queryItems == [URLQueryItem(name: "template", value: UpdateCheck.menuIssueTemplate)])
        let template = text(".github/ISSUE_TEMPLATE/\(UpdateCheck.menuIssueTemplate)")
        #expect(template.hasPrefix("---\nname: "))
        #expect(template.contains("Drag the file"))
        #expect(template.contains("never contains your Windows password"))
    }

    @Test("The menu opens that, not the issue list")
    func theMenuOpensIt() {
        let menuBar = text("Sources/Winbar/MenuBar.swift")
        #expect(menuBar.contains("NSWorkspace.shared.open(UpdateCheck.newIssueFromMenuURL)"))
        #expect(!menuBar.contains("UpdateCheck.issuesURL"))
    }
}

/// Code lines of one source file, with `//` comments and blank lines dropped.
private func codeLines(_ path: String) -> [String] {
    text(path).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.hasPrefix("//") && !$0.hasPrefix("///") }
}

/// The first code line after `signature`.
private func firstLine(after signature: String, in path: String) -> String? {
    let lines = codeLines(path)
    guard let index = lines.firstIndex(where: { $0.hasPrefix(signature) }), index + 1 < lines.count else { return nil }
    return lines[index + 1]
}

/// Report a Problem… runs beside a set-up step, which writes the very settings doctor records. A
/// report that looked up the saved PC a moment before the wizard saved one would write the stale
/// answer back over it, and Connect would then open a one-off connection.
@Suite("A problem report's doctor run writes nothing")
struct ReportProblemReadOnlyTests {
    @Test("The report's run is read-only; doctor's and setup's still remember what they find")
    func onlyTheReport() {
        #expect(Diagnose.doctorOptions(sightings: .init()).readOnly)
        #expect(!Context.Options().readOnly)
        #expect(text("Sources/Winbar/Diagnose.swift").contains("let ctx = Context(options: doctorOptions(sightings: sightings))"))
    }

    /// Each place a doctor run writes a setting, guarded. The delegate-free way to see it: each of
    /// them only runs against UTM, Windows or Windows App.
    @Test("Every setting doctor writes is skipped when read-only")
    func everyWriteIsGuarded() {
        #expect(firstLine(after: "private func remember(_ output: GuestOutput) {", in: "Sources/Winbar/Checks.swift")
                == "guard !options.readOnly else { return }")
        #expect(codeLines("Sources/Winbar/Checks.swift").first { $0.contains("Config.rememberSharedFolder(") }?
                    .hasPrefix("if !options.readOnly {") == true)
        #expect(firstLine(after: "private static func updateSavedPC(", in: "Sources/Winbar/Recipe.swift")
                == "guard ctx.isConfiguredVM, !ctx.options.readOnly else { return }")
        // …and it is the only place Recipe writes the saved PC.
        #expect(codeLines("Sources/Winbar/Recipe.swift").filter { $0.contains("Config.savedPC = ") }.count == 1)
        #expect(codeLines("Sources/Winbar/Recipe.swift").first { $0.contains("Config.backupExclusionConfirmed = false") }?
                    .hasPrefix("if !ctx.options.readOnly {") == true)
        // Nothing else in Context writes a setting: a new write has to be added here, and guarded.
        let writes = codeLines("Sources/Winbar/Checks.swift").filter {
            $0.range(of: #"Config\.\w+ = |Config\.record|Config\.remember"#, options: .regularExpression) != nil
        }
        #expect(writes.count == 4, "\(writes)")
    }

    /// A set-up step checking the shared folder writes `.winbar-share-check` and removes it when done,
    /// and runs one fixed helper file in Windows. A report beside it must touch neither.
    @Test("The report's survey uses a marker of its own and leaves the session helper alone")
    func keepsOutOfAStepsFiles() {
        let report = Context.surveyTraces(readOnly: true)
        #expect(report.marker == SharedFolder.reportMarkerName)
        #expect(report.marker != SharedFolder.markerName)
        #expect(!report.asksSession)
        let doctor = Context.surveyTraces(readOnly: false)
        #expect(doctor.marker == SharedFolder.markerName)
        #expect(doctor.asksSession)
        #expect(text("Sources/Winbar/Checks.swift").contains("let traces = Context.surveyTraces(readOnly: options.readOnly)"))
    }

    @Test("A marker by another name is written and removed by that name")
    func markerNames() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("winbar-marker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let step = try #require(SharedFolder.writeMarker(in: folder.path))
        let report = try #require(SharedFolder.writeMarker(in: folder.path, named: SharedFolder.reportMarkerName))
        SharedFolder.removeMarker(in: folder.path, named: SharedFolder.reportMarkerName)
        // The step's marker, and its token, are exactly as the step left them.
        let left = try String(contentsOf: folder.appendingPathComponent(SharedFolder.markerName), encoding: .utf8)
        #expect(left == step && step != report)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(SharedFolder.reportMarkerName).path))
    }

    /// The comment that says why the report may run beside a step has to say what is true.
    @Test("The gate's explanation names the read-only run, not \"it only reads\"")
    func explanation() {
        let gate = text("Sources/Winbar/AppWorkGate.swift")
        #expect(gate.contains("writes no Winbar setting (`Context.Options.readOnly`)"))
        #expect(!gate.contains("It only\n        /// reads"))
    }
}
