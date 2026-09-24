import AppKit
import SwiftUI
import Testing
@testable import Winbar

// What the Set Up Winbar window and the install tell VoiceOver as they change. Invented fixtures; the
// window's announcer is a recorder, never the system's.

@MainActor @Suite("VoiceOver hears the news as it happens")
struct SetupVoiceOverTests {
    @Test("A refusal is said when it appears, and not again while it stays")
    func refusal() {
        let refused = try? #require(SetupFixtures.screens.first { $0.name == "refused" }?.state)
        guard let refused, let refusal = refused.refusal else {
            Issue.record("no refused fixture")
            return
        }
        var before = refused
        before.refusal = nil
        #expect(SetupAnnouncement.said(from: before, to: refused) == [refusal.description])
        #expect(SetupAnnouncement.said(from: refused, to: refused).isEmpty)
    }

    @Test("Certificate verified and PC saved are said when they happen on their page, not on arrival")
    func results() {
        let checking = CertificateFixtures.state("checking")
        let verified = CertificateFixtures.state("verified")
        #expect(SetupAnnouncement.said(from: checking, to: verified) == [SetupCopy.Certificate.result(.verified)])
        #expect(SetupAnnouncement.said(from: verified, to: verified).isEmpty)
        var arriving = verified
        arriving.step = .tune
        #expect(SetupAnnouncement.said(from: arriving, to: verified).isEmpty)

        var saving = SetupFixtures.state(.savedPC, facts: JourneyFixtures.facts)
        saving.facts?.rows["C2"] = JourneyFixtures.row("C2", .fixable("Not saved"))
        saving.inFlight = SetupFixtures.flight(.savePC)
        var saved = SetupFixtures.state(.savedPC, facts: JourneyFixtures.facts)
        saved.facts?.rows["C2"] = JourneyFixtures.row("C2", .ok("Saved"))
        #expect(SetupAnnouncement.said(from: saving, to: saved) == [SetupCopy.SavedPC.savedAnnouncement])
    }

    @Test("The install's ending is said once, without its glyph")
    func installEnding() {
        let running = ArmieFixtures.job()
        let done = ArmieFixtures.job(stage: .finish, outcome: .done)
        #expect(CreateJobView.announcement(from: nil, to: running) == nil)
        let said = CreateJobView.announcement(from: running, to: done)
        #expect(said == CreateCopy.installed(edition: done.plan.edition.displayName, name: done.plan.vmName))
        #expect(CreateJobView.announcement(from: done, to: done) == nil)
        let failed = ArmieFixtures.job(stage: .oobe, outcome: .failed,
                                       failure: CreateFailure(code: "E_VM_STOPPED", title: "The VM stopped", detail: "", nextStep: nil))
        #expect(CreateJobView.announcement(from: running, to: failed) == "The VM stopped")
    }

    /// The install window says its ending as the job's state arrives, through its own environment.
    @Test("The install window says the ending when the job's state arrives")
    func installWindowSays() async {
        var said: [String] = []
        let controller = CreateWindowController(facts: CreateFormFacts(
            mac: MacFacts(topTierCores: 8, totalCores: 12, memoryBytes: 32 << 30, shortUserName: "rosa"),
            utmInstalled: true, utmVersion: "4.7.5", fileVaultOn: true, freeGB: 400, volumeName: "atelier",
            existingVMNames: nil, menuVMName: nil),
            environment: .init(currentJob: { nil }, refreshForm: { _ in }, show: { _ in }, workGate: AppWorkGate(),
                               ownsJob: { false }, announce: SetupAnnouncer { said.append($0) }))
        controller.jobChanged(ArmieFixtures.job())
        try? await Task.sleep(for: .milliseconds(30))
        #expect(said.isEmpty)
        controller.jobChanged(ArmieFixtures.job(stage: .finish, outcome: .done))
        try? await Task.sleep(for: .milliseconds(30))
        #expect(said.count == 1 && said.first?.contains("winlab02") == true, "\(said)")
    }
}

@MainActor @Suite("Only the app's windows speak to VoiceOver")
struct SetupAnnouncerTests {
    /// A controller built with the defaults — as the tests build them, and as a render does — says
    /// nothing aloud: the live announcer posts to the real VoiceOver, and a test run on a Mac with it
    /// on said "PC saved" and an install's ending out loud.
    @Test("A controller built with the defaults is silent")
    func silentByDefault() {
        #expect(!CreateWindowController.Environment().announce.reachesVoiceOver)
        let setup = SetupWindowController(art: nil,
                                          settings: .init(wizardShown: { false }, markShown: {}, armieHidden: { true }, hideArmie: {}),
                                          // Never attached, so neither is made: the real ones reach UTM.
                                          makeRunner: { preconditionFailure("not attached") },
                                          makeCreator: { FakeEmbeddedCreate() })
        #expect(!setup.announcer.reachesVoiceOver)
        #expect(SetupAnnouncer.live.reachesVoiceOver && !SetupAnnouncer.silent.reachesVoiceOver)
    }

    /// The app's two `shared` controllers are the only places the live announcer is handed in, so the
    /// app still speaks and nothing else does. Read from the source, since building `shared` in a test
    /// would read this Mac's settings.
    @Test("The live announcer is handed only to the app's shared controllers")
    func liveOnlyInShared() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Winbar")
        var handed: [String] = []
        for file in try FileManager.default.contentsOfDirectory(atPath: sources.path) where file.hasSuffix(".swift") {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            handed += text.components(separatedBy: "\n").filter {
                ($0.contains("announce: .live") || $0.contains("announcer: .live") || $0.contains("SetupAnnouncer = .live"))
                    && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//")
            }.map { "\(file): \($0.trimmingCharacters(in: .whitespaces))" }
        }
        #expect(handed.count == 2 && handed.allSatisfy { $0.contains("static let shared") }, "\(handed)")
    }
}
