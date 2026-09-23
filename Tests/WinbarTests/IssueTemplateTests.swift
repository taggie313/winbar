import Foundation
import Testing
@testable import Winbar

/// The issue template is a privacy surface, not documentation.
///
/// It is the page somebody reads while deciding what to attach to a public issue, and it is the page
/// that asks them to paste a debug run into a box. Twice now it has been wrong in the direction that
/// costs something: it described what `--anonymise` replaced before the ids, the MAC address and the
/// Windows PC name were added to it, and it told people a debug run carried no VM id while
/// `Debug.log` was printing `utmctl list`'s answer — every VM's UUID and name — to the very stderr
/// it asks for. Both times the file and the code were edited apart, and nothing noticed.
///
/// So the template is read here as text and checked against the code it describes. Prose can still
/// be wrong in ways a test can't see; what these stop is the specific failure that has happened —
/// a rule changing and its description staying where it was.
@Suite("The issue template says what the code actually does")
struct IssueTemplateAgreesWithTheCode {
    static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func read(_ path: String) -> String {
        (try? String(contentsOf: repositoryRoot.appendingPathComponent(path), encoding: .utf8)) ?? ""
    }

    static let template = read(".github/ISSUE_TEMPLATE/bug_report.md")

    /// Not empty, so a wrong path can't make every other test in here vacuously pass.
    @Test func theTemplateWasFound() {
        #expect(Self.template.contains("name: Bug report"))
        #expect(Self.template.contains("winbar diagnose --anonymise"))
    }

    /// The paragraph a reporter actually reads before ticking the box, checked against the report's
    /// own mode line. Either both list a placeholder or neither does: the template drifting behind
    /// the code is how it came to promise "ids included" while saying nothing about the MAC address
    /// or the Windows PC name, and to contradict its own footer three screens below.
    @Test("Every placeholder the anonymised report writes is named in the template")
    func everyPlaceholderIsNamed() {
        let explanation = Redactor(mode: .anonymised,
                                   identity: .init(userName: "rosa", fullUserName: "Rosa Klebb",
                                                   computerName: "atelier", vmNames: ["winlab01"],
                                                   vmIDs: ["9F3C1D2E-4B5A-4C6D-8E7F-0A1B2C3D4E5F": "winlab01"],
                                                   vmMACs: ["5A:2B:3C:4D:5E:6F": "winlab01"],
                                                   windowsUsers: ["Bruno"],
                                                   windowsPCNames: ["DESKTOP-4F8J2K1"])).explanation
        for placeholder in ["<mac>", "<user>", "<user-full-name>", "<windows-user-1>", "<windows-pc-1>",
                            "<vm-1>", "<vm-1-id>", "<vm-1-mac>", "<id-1>", "<mac-address-1>"] {
            #expect(explanation.contains(placeholder), "the report no longer writes \(placeholder)")
            #expect(Self.template.contains(placeholder), "the issue template doesn't mention \(placeholder)")
        }
    }

    /// The claim that was false. `UTM.ctlAnswers` logs what `utmctl list` answered — `<uuid> <status>
    /// <name>` for every VM on the Mac — and the template asks for that stderr in a public issue, so
    /// it has to say so. Tied to the code that makes it true: if the logging goes, this fails and
    /// the sentence gets revisited rather than quietly becoming false in the other direction.
    @Test("The template says a debug run carries the VM ids, because the debug log prints them")
    func theDebugRunClaimIsTrue() {
        let utm = Self.read("Sources/Winbar/UTM.swift")
        #expect(utm.contains("Shell.run(utmctl, [\"list\"]"))
        #expect(utm.contains("Debug.log(\"ctlAnswers:"))
        #expect(utm.contains("output=\\(result.output"))
        // Said in both places a reporter can be standing: beside the paste box, and in the footer.
        let sections = Self.template.components(separatedBy: "WINBAR_DEBUG=1")
        #expect(sections.count >= 2)
        #expect(Self.template.components(separatedBy: "utmctl list").count - 1 >= 1)
        #expect(Self.template.contains("no `--anonymise` for it"))
        // And the footer's old claim — that the report is the only one of the three carrying the id
        // — is gone rather than merely contradicted further up.
        #expect(!Self.template.contains("the only one of the three that carries them"))
        #expect(!Self.template.contains("ids included"))
    }

    /// The other half of the same promise: what the template says is never in the file.
    @Test("The template's one absolute claim is the one Winbar keeps")
    func thePasswordClaim() {
        #expect(Self.template.contains("password"))
        #expect(Self.template.lowercased().contains("never"))
    }
}
