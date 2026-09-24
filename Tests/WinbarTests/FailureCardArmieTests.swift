import AppKit
import SwiftUI
import Testing
@testable import Winbar

// Where the beta's Send This to the Developer (`BetaReport.cards`, `CreateJobView.offersReport`) and
// Armie (`ArmieCue`) meet. The help pass kept him off a failure card altogether; Astra's concern has
// since given him the one pose that belongs there, so the rule is now `ArmieCue.besideReport`'s:
// beside a card with the button he is concern, still and silent, and never where the button is. The
// button is the page's way to ask for help, and a figure moving or talking beside it, or standing over
// it, would take the eye from the one thing on the page to read.
//
// Each failure is paired with the same page just before it failed, so concern is the failure's doing
// rather than a page he always looks worried on. Invented states only (SetupFixtures, ArmieFixtures,
// JourneyFixtures); nothing is put on screen, reaches UTM or sends anything.

@Suite("A failure card has Send This to the Developer, and Armie's concern beside it")
struct FailureCardArmieTests {
    private static func failed(_ state: SetupWindowState, _ work: SetupRunner.Work) -> SetupWindowState {
        var state = state
        state.lastEnding = SetupRunner.Ending(work: work, outcome: .failed(.init(title: "UTM didn't answer", detail: "-1712")),
                                              facts: state.facts ?? JourneyFixtures.facts, slept: false,
                                              started: SetupFixtures.started)
        return state
    }

    /// Pages where Armie stands otherwise, each beside the same page once a piece of its work failed.
    static var pairs: [(name: String, fine: SetupWindowState, failed: SetupWindowState)] {
        [("step 1, UTM's install", SetupFixtures.installing, SetupFixtures.installFailed),
         ("step 2, no VM yet", ArmieFixtures.noVM, failed(ArmieFixtures.noVM, .checkAgain(.vm))),
         ("the done screen", ArmieFixtures.done, failed(ArmieFixtures.done, .checkAgain(.finish)))]
    }

    @Test("Where Armie stood, a failure brings the button and his concern")
    func wizardPages() {
        for (name, fine, failure) in Self.pairs {
            #expect(BetaReport.cards(fine, enabled: true).isEmpty, "\(name)")
            #expect(ArmieCue.cue(fine).map { $0 != .concerned } == true, "\(name): he stands here, not worried, before it fails")
            #expect(!BetaReport.cards(failure, enabled: true).isEmpty, "\(name): the failure's card has the button")
            #expect(ArmieCue.cue(failure) == .concerned, "\(name): and he is concerned beside it")
        }
    }

    /// `.concerned` is the still pose with no line: no bubble of his near the button, nothing moving.
    /// The step-2 card here is a start that failed before any read, which fell through to his rest.
    @Test("Every card with the button has his concern: still, silent, whichever card it is")
    func everyCard() {
        for (card, state) in BetaReportCardTests.failures {
            #expect(!state.armieHidden, "\(card)")
            #expect(ArmieCue.cue(state) == .concerned, "\(card)")
        }
    }

    /// The one card with the button that isn't trouble: UTM's list refused at macOS's Automation prompt,
    /// the person's own answer, where he stands by without a word as beside any refused permission.
    @Test("A list refused by Automation has the button and his silence, not his concern")
    func automationRefused() {
        let refused = SetupFixtures.state(facts: SetupFixtures.facts(
            utm: SetupFixtures.installed, answers: .answered,
            vms: .failed(.init(title: "Winbar isn't allowed to control UTM", automationDenied: true))))
        #expect(BetaReport.cards(refused, enabled: true) == [.lookAround])
        #expect(ArmieCue.cue(refused) == .quiet)
    }

    @Test("The install: going well has Armie working and no button; failed has the button and his concern")
    func install() {
        let going = ArmieFixtures.job()
        #expect(ArmieCue.installing(going).pose == .working)
        #expect(!CreateJobView.offersReport(going, enabled: true))
        let failure = CreateFailure(code: "E_BOOT", title: "Windows didn't start", detail: "", nextStep: nil)
        let failed = ArmieFixtures.job(outcome: .failed, failure: failure)
        #expect(CreateJobView.offersReport(failed, enabled: true))
        #expect(ArmieCue.installing(failed) == .concerned)
    }
}

/// His stills from Resources, as the renders draw him (a video layer has nothing to give a render).
@MainActor private enum Stills {
    static let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Resources/Armie")

    static func image(_ name: String) -> NSImage? { NSImage(contentsOf: resources.appendingPathComponent(name + ".png")) }

    static let art: ArmieArt? = image(ArmieArt.stillName).map {
        ArmieArt(still: $0, working: nil, done: nil, concerned: image(ArmieArt.concernedName))
    }
}

@MainActor @Suite("Armie's concern is drawn clear of Send This to the Developer")
struct FailureCardArmieLayoutTests {
    /// Wide as the window and tall enough that every card's button is drawn, not scrolled away.
    static let size = CGSize(width: 600, height: 1400)

    private func render(_ state: SetupWindowState, art: ArmieArt, button: Bool = true,
                        embedded: ((ArmieHost?) -> AnyView)? = nil) throws -> Data {
        let view = SetupScreen(state: state, art: art, embedded: embedded, send: { _ in })
            .environment(\.drawsSendToDeveloper, button)
        return try #require(Snapshot.png(view, size: Self.size, appearance: .light))
    }

    /// Where he is: the page with him against the same page with him hidden, which differ only in his
    /// figure since beside a card he says nothing. Where the button is: the page against the same page
    /// drawn without it, which differ from the button down, since what follows moves up into its
    /// place. So the check is stricter than the button's own frame: he stays clear of the button and of
    /// everything under it. (A figure pushed down into a card doesn't meet the button's box: the card is
    /// drawn over him, and the first check finds nothing of him to see.) The finished page isn't here:
    /// there he is the page's mark, in its column above or below the card, never beside the button.
    private func apart(_ name: String, _ state: SetupWindowState, art: ArmieArt,
                       embedded: ((ArmieHost?) -> AnyView)? = nil) throws {
        var hidden = state
        hidden.armieHidden = true
        let page = try render(state, art: art, embedded: embedded)
        let him = try #require(Snapshot.difference(page, try render(hidden, art: art, embedded: embedded))?.bounds,
                               "\(name): he is drawn, not covered by a card drawn over him")
        let button = try #require(Snapshot.difference(page, try render(state, art: art, button: false,
                                                                       embedded: embedded))?.bounds,
                                  "\(name): the button is drawn")
        #expect(!him.intersects(button), "\(name): Armie \(him) meets the button's \(button)")
    }

    @Test("On every wizard card with the button, he stands clear of it")
    func wizardCards() throws {
        let art = try #require(Stills.art)
        for (card, state) in BetaReportCardTests.failures {
            try apart("\(card)", state, art: art)
        }
    }

    @Test("On the install's failure page inside the wizard, he stands clear of it")
    func installFailure() throws {
        let art = try #require(Stills.art)
        let controller = ArmieFixtures.createController()
        defer { controller.unembed() }
        let failure = CreateFailure(code: "E_BOOT", title: "Windows didn't start", detail: "", nextStep: nil)
        controller.draw(ArmieFixtures.job(now: controller.now, outcome: .failed, failure: failure))
        try apart("install failed", ArmieFixtures.creating, art: art,
                  embedded: { armie in AnyView(CreateRootView(controller: controller, armie: armie)) })
    }
}
