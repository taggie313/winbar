import AppKit
import SwiftUI
import Testing
@testable import Winbar

// The Set Up Winbar window's one kind of filled button, and its footer: at most one filled button per
// screen, in one colour and one size, and the step's way forward in the footer's corner. Every screen
// drawn here is an invented fixture in an offscreen view; nothing is run or shown.

let setupWindowSize = CGSize(width: 600, height: 620)

/// The footer band's height at the window's first-open size (as SetupDefaultButtonTests measures it).
let setupFooterBand: CGFloat = 70

@MainActor func render(_ state: SetupWindowState, _ appearance: Snapshot.Appearance,
                               embedded: ((ArmieHost?) -> AnyView)? = nil) throws -> Data {
    try #require(Snapshot.png(SetupScreen(state: state, art: nil, embedded: embedded, send: { _ in }),
                              size: setupWindowSize, appearance: appearance))
}

/// Every screen the window's renders draw: steps 0 and 1, the recovery screens, the certificate's
/// feedback, the journey's pages and the tune step's statuses, the question after Connect, and the
/// install's views embedded as step 2 — the New Windows VM form and its three endings.
@MainActor var everyScreen: [(String, SetupWindowState, ((ArmieHost?) -> AnyView)?)] {
    var screens: [(String, SetupWindowState, ((ArmieHost?) -> AnyView)?)] = []
    screens += SetupFixtures.screens.map { ("setup-\($0.name)", $0.state, nil) }
    screens += SetupRecoveryFixtures.screens.map { ("recovery-\($0.0)", $0.1, nil) }
    for name in ["initial", "approving", "checking", "verified", "skipped", "failed", "cancelled", "unverified"] {
        screens.append(("certificate-\(name)", CertificateFixtures.state(name), nil))
    }
    screens += JourneyFixtures.pages.map { ("journey-\($0.rawValue)", JourneyFixtures.page($0), nil) }
    screens += TuneStatusFixtures.screens.map { ("tune-status-\($0.0)", $0.1, nil) }
    screens.append(("connect-did-it-work", JourneyFixtures.didItWork, nil))
    screens += JourneyPolishFixtures.screens.map { ("journey-polish-\($0.0)", $0.1, nil) }
    screens += FinishFixtures.screens.map { ("finish-\($0.0)", $0.1, nil) }
    let form = ArmieFixtures.createController()
    screens.append(("create-form", ArmieFixtures.creating, { armie in AnyView(CreateRootView(controller: form, armie: armie)) }))
    for (name, controller) in FormPageFixtures.pages where name != "windows" {
        screens.append(("create-form-\(name)", ArmieFixtures.creating, { armie in AnyView(CreateRootView(controller: controller, armie: armie)) }))
    }
    for (name, job) in [("install-running", ArmieFixtures.job()),
                        ("install-failed", ArmieFixtures.job(stage: .oobe, outcome: .failed,
                                                             failure: CreateFailure(code: "E_VM_STOPPED", title: "The VM stopped",
                                                                                    detail: "UTM stopped “winlab02”.", nextStep: nil))),
                        ("install-done", ArmieFixtures.job(stage: .finish, outcome: .done))] {
        let controller = ArmieFixtures.createController()
        controller.draw(job)
        screens.append((name, ArmieFixtures.creating, { armie in AnyView(CreateRootView(controller: controller, armie: armie)) }))
    }
    return screens
}

// MARK: - Buttons

@MainActor @Suite("One filled button per screen, in one blue and one size")
struct PrimaryButtonTests {
    /// The review found two filled buttons on the skipped certificate (Approve Instead… in the card,
    /// Continue Without Approval in the footer), and in dark mode two blues: a card's prominent button
    /// took the root tint (#60CDFF, black title) beside the footer's #0067C0, and Finish's Close and the
    /// install's Hide took the cyan too.
    @Test("No screen has more than one filled button, and none is filled in the accent's text shade",
          arguments: [Snapshot.Appearance.light, .dark])
    func oneFilled(appearance: Snapshot.Appearance) throws {
        let palette = SetupStyle.palette(dark: appearance.isDark, increasedContrast: false)
        var checked = 0
        for (name, state, embedded) in everyScreen {
            let png = try render(state, appearance, embedded: embedded)
            let filled = Drawing.filled(palette.accentFill, in: png)
            #expect(filled.count <= 1, "\(name), \(appearance.rawValue): \(filled)")
            if appearance.isDark {
                let cyan = Drawing.filled(palette.accentText, in: png)
                #expect(cyan.isEmpty, "\(name): a button filled in the text accent, \(cyan)")
            }
            checked += 1
        }
        #expect(checked >= 70, "\(checked) screens")
    }

    /// "Exactly one filled button per screen, and it is the thing the card says to do": a card that
    /// names a button ("Choose **Go Back to Tune**…") over a footer with nothing filled left Return
    /// doing nothing, and the count above (at most one) let it pass. A screen isn't held to it while
    /// work runs, where nothing may be pressable but Stop Waiting. **Save It** is drawn as it is once
    /// a password is typed, which it waits for. The empty New Windows VM form is the one exception:
    /// its "choose" is Microsoft's page and the drop box's Choose File…, which opens a panel, and its
    /// greyed-out Continue says why beside it.
    @Test("Every screen whose words name a button, and isn't waiting, has exactly one filled button")
    func exactlyOneWhereNamed() throws {
        let fill = SetupStyle.palette(dark: false, increasedContrast: false).accentFill
        var named = 0
        for (name, state, embedded) in everyScreen where state.inFlight == nil && name != "create-form" {
            let credentials = SetupCredentials()
            if SetupFooter.footer(state).corner?.press == .savePassword { credentials.password = "synthetic-test-secret" }
            let png = try #require(Snapshot.png(SetupScreen(state: state, art: nil, embedded: embedded, credentials: credentials,
                                                            send: { _ in }),
                                                size: setupWindowSize, appearance: .light))
            let lines = try Drawing.lines(png)
            guard lines.contains(where: { $0.text.range(of: "choose ", options: .caseInsensitive) != nil }) else { continue }
            named += 1
            let filled = Drawing.filled(fill, in: png)
            #expect(filled.count == 1, "\(name): \(filled.count) filled, words \(lines.filter { $0.text.localizedCaseInsensitiveContains("choose") })")
        }
        #expect(named >= 30, "\(named) screens name a button")
    }

    /// The control: a prominent button left to the window's root tint, as the card's were, is found
    /// filled in the text shade in dark mode — so the check above can see one.
    @Test("A prominent button under the root tint is filled in the text shade in dark mode")
    func oneFilledControl() throws {
        let palette = SetupStyle.palette(dark: true, increasedContrast: false)
        let old = Button("Approve Instead…") {}.buttonStyle(.borderedProminent).padding(40).tint(palette.accentText.color)
        let png = try #require(Snapshot.png(old, size: CGSize(width: 300, height: 120), appearance: .dark))
        #expect(Drawing.filled(palette.accentText, in: png).count == 1)
    }

    /// The control for the count: two filled buttons in one row, No and Yes, are two. Taking each row's
    /// widest run of the fill, as the count first did, saw one.
    @Test("Two filled buttons side by side are counted as two")
    func sideBySide() throws {
        let fill = SetupStyle.palette(dark: false, increasedContrast: false).accentFill
        let look = SetupAppearance(palette: SetupStyle.palette(dark: false, increasedContrast: false),
                                   reduceTransparency: false, increasedContrast: false)
        let pair = HStack(spacing: 12) {
            Button("No") {}.primaryButton(look)
            Button("Yes") {}.buttonStyle(.borderedProminent).tint(fill.color).controlSize(.large)
        }.padding(40)
        let png = try #require(Snapshot.png(pair, size: CGSize(width: 300, height: 120), appearance: .light))
        #expect(Drawing.filled(fill, in: png).count == 2)
    }

    /// The skipped certificate, where the review counted two: now the footer's Continue is the filled
    /// one, and the card's Approve Instead… is plain.
    @Test("The skipped certificate's one filled button is the footer's")
    func skippedCertificate() throws {
        let png = try render(CertificateFixtures.state("skipped"), .light)
        let filled = Drawing.filled(SetupStyle.palette(dark: false, increasedContrast: false).accentFill, in: png)
        #expect(filled.count == 1 && filled.allSatisfy { $0.minY > setupWindowSize.height - setupFooterBand }, "\(filled)")
    }

    /// Increase Contrast in dark mode: the deep fill measured 1.80:1 against the footer, the dimmest
    /// thing in it. The pale fill is drawn, with a black title on it.
    @Test("Dark Increase Contrast draws the default pale, with a black title")
    func darkIncreasedContrast() throws {
        var state = SetupFixtures.state(.connect, facts: JourneyFixtures.facts)
        state.answers.connectionOpened = true
        state.answers.connected = true
        state.facts?.answers = state.answers
        let png = try render(state, .darkIncreaseContrast)
        let palette = SetupStyle.palette(dark: true, increasedContrast: true)
        #expect(palette.accentFill == SetupStyle.RGB(0x99EBFF) && palette.onAccentFill == SetupStyle.RGB(0x000000))
        let filled = Drawing.filled(palette.accentFill, in: png)
        let button = try #require(filled.first, "no pale filled button")
        #expect(filled.count == 1 && button.minY > setupWindowSize.height - setupFooterBand)
        // Its title: dark pixels inside the pale fill.
        let image = try #require(Snapshot.pixels(png))
        var dark = 0
        for y in Int(button.minY * 2)..<Int(button.maxY * 2) {
            for x in Int(button.minX * 2)..<Int(button.maxX * 2) {
                let pixel = image.rgba[y * image.width + x]
                if max(pixel & 0xFF, (pixel >> 8) & 0xFF, (pixel >> 16) & 0xFF) < 70 { dark += 1 }
            }
        }
        #expect(dark > 100, "\(dark) dark pixels in the button")
        // The footer band it sits on, as drawn: the card at 45% over the flat backdrop.
        let band = SetupStyle.RGB(0x252525)
        #expect(SetupStyle.contrast(palette.accentFill, band) >= 3)
        #expect(SetupStyle.contrast(SetupStyle.RGB(0x004E8C), band) < 3) // the fill it replaces
    }

    /// One size: the card's filled button and the footer's are the same height. In-card buttons were
    /// regular rounded rectangles beside the footer's large capsules. The desktop question's Yes is
    /// the card's filled button (a failed Connect's moved to the footer's corner). It is narrow, so
    /// it's measured with a narrower run than the default 40 pt, which cut its capsule's rounded top
    /// and bottom rows off.
    @Test("A filled button in a card is as tall as one in the footer")
    func oneSize() throws {
        let fill = SetupStyle.palette(dark: false, increasedContrast: false).accentFill
        let inCard = try #require(Drawing.filled(fill, in: try render(JourneyFixtures.didItWork, .light), minWidth: 20).first)
        #expect(inCard.maxY < setupWindowSize.height - setupFooterBand)
        let footer = try #require(Drawing.filled(fill, in: try render(CertificateFixtures.state("skipped"), .light)).first)
        #expect(footer.minY > setupWindowSize.height - setupFooterBand)
        #expect(abs(inCard.height - footer.height) <= 1, "card \(inCard.height), footer \(footer.height)")
        // The control: the same filled button at the regular size it had is shorter.
        let regular = Button("Try Again") {}.buttonStyle(.borderedProminent).tint(fill.color).padding(40)
        let regularPNG = try #require(Snapshot.png(regular, size: CGSize(width: 300, height: 120), appearance: .light))
        let old = try #require(Drawing.filled(fill, in: regularPNG).first)
        #expect(old.height < footer.height - 3, "regular \(old.height), large \(footer.height)")
    }
}


@MainActor @Suite("One button size in the whole window")
struct SetupControlSizeTests {
    /// Every button in the window is large, not only the footer's: in-card buttons were regular
    /// rounded rectangles beside the footer's large capsules. What the window hands the views inside
    /// it, read by one put in the New Windows VM views' slot; on its own, a view gets the regular size.
    @Test("The large control size reaches the views inside the window")
    func large() throws {
        let seen = Seen()
        _ = try render(ArmieFixtures.creating, .light, embedded: { _ in AnyView(Probe(seen: seen)) })
        #expect(seen.controlSize == .large)
        let alone = Seen()
        _ = Snapshot.png(Probe(seen: alone), size: CGSize(width: 10, height: 10), appearance: .light)
        #expect(alone.controlSize == .regular)
    }
}

// MARK: - The footer

@MainActor @Suite("The footer: the step's way forward in the corner")
struct SetupFooterTests {
    private func titles(_ buttons: [SetupFooter.Button]) -> [String] { buttons.map(\.title) }

    @Test("The welcome: Not Now takes Escape, Start is the default")
    func welcome() {
        let footer = SetupFooter.footer(SetupFixtures.state(.welcome, facts: nil))
        #expect(footer.leading.isEmpty)
        #expect(footer.trailing == [.init(SetupCopy.Welcome.bNotNow, .notNow, kind: .cancel),
                                    .init(SetupCopy.Welcome.bStart, .start, kind: .primary)])
        #expect(footer.holdsDefault())
    }

    @Test("Step 1's corner is its page's own button, and its second button beside it")
    func lookAround() throws {
        for (name, state) in SetupFixtures.screens where state.step == .lookAround {
            let page = LookAroundPage.page(state)
            let footer = SetupFooter.footer(state)
            // Back can't be pressed while work that acts runs, so it isn't drawn then (`SetupFooter.footer`);
            // while only a read runs it can.
            let backable = state.inFlight == nil || state.inFlight?.work.isRead == true
            #expect(footer.leading == (backable ? [.init(SetupCopy.bBack, .back)] : []), "\(name)")
            #expect(footer.corner?.title == page.primary?.title ?? page.secondary?.title, "\(name)")
            if let primary = page.primary {
                #expect(footer.corner == .init(primary.title, .perform(primary.action), enabled: primary.enabled, kind: .primary), "\(name)")
            }
        }
    }

    @Test("Step 2 keeps Check Again beside Back, and the corner is the action its page hands it")
    func vm() throws {
        let state = try #require(SetupRecoveryFixtures.screens.first { $0.0 == "vm-ready" }?.1)
        let footer = SetupFooter.footer(state)
        #expect(titles(footer.leading) == [SetupCopy.bBack, SetupCopy.bCheckAgain])
        #expect(footer.corner == .init(SetupCopy.journeyNext(.vm, facts: state.facts), .continueFromVM, kind: .primary))
        let use = SetupFooter.Button("Use “winlab02”", .useVM(name: "winlab02", id: "vm-1"), kind: .primary)
        #expect(SetupFooter.footer(state, stepAction: { _ in use }).corner == use)
        #expect(SetupFooter.footer(state, stepAction: { _ in nil }).trailing.isEmpty)
    }

    @Test("A journey step: Continue in the corner, the default only while it can be pressed")
    func journey() throws {
        var verified = SetupFixtures.state(.certificate, facts: JourneyFixtures.facts)
        verified.facts?.rows["H7"] = JourneyFixtures.row("H7", .ok("Trusted"))
        // Done, so nothing is left to check again: Continue alone.
        let next = SetupFooter.footer(verified)
        #expect(titles(next.trailing) == [SetupCopy.journeyNext(.certificate, facts: verified.facts)])
        #expect(next.corner?.press == .send(.next) && next.holdsDefault())

        // A step that hands the footer nothing (the desktop question, whose two answers are the
        // card's): Continue is in the corner, greyed out, and isn't the default.
        let question = JourneyFixtures.didItWork
        #expect(SetupJourneyActions.footerAction(question) == nil)
        let greyed = SetupFooter.footer(question)
        #expect(greyed.corner?.title == SetupCopy.journeyNext(.connect, facts: question.facts))
        #expect(greyed.corner?.enabled == false && !greyed.holdsDefault())

        // Continue Without Connecting is never the default, pressable or not: after a failed Connect
        // the retry has the corner, and moving on without the test is beside Back, plain.
        let failed = try #require(SetupRecoveryFixtures.screens.first { $0.0 == "connect-failed-answering" }?.1)
        let connect = SetupFooter.footer(failed)
        #expect(connect.corner == .init(SetupCopy.bTryAgain, .retryConnection, kind: .primary))
        let skip = try #require(connect.leading.last)
        #expect(skip.title == SetupCopy.journeyNext(.connect, facts: failed.facts) && skip.kind == .plain && skip.press == .send(.next))

        // Finish has its own footer (`SetupFinishPageTests`): its corner opens Windows once it's done.
        var finished = SetupFixtures.state(.finish, facts: JourneyFixtures.facts)
        finished.finished = true
        finished.answers.connected = true
        finished.facts?.answers = finished.answers
        #expect(SetupFooter.footer(finished).corner == .init(SetupCopy.Finish.bOpenWindows, .openWindows, kind: .primary))
    }

    /// The mechanism the pages move their actions into: a step that hands the footer its action has
    /// it in the corner, filled, until the step is satisfied — and then Continue has the corner.
    @Test("A handed action takes the corner until the step is done, then Continue does")
    func handedAction() {
        let approve = SetupFooter.Button(SetupCopy.Certificate.bApprove, .perform(.run(.trustCertificate)), kind: .primary)
        let needs = CertificateFixtures.state("initial")
        let handed = SetupFooter.footer(needs, stepAction: { _ in approve })
        #expect(handed.corner == approve && handed.holdsDefault())
        let done = SetupFooter.footer(CertificateFixtures.state("verified"), stepAction: { _ in approve })
        #expect(done.corner?.press == .send(.next))
    }

    /// Drawn: the corner's action is the default, so Return presses it; Escape is the cancel's.
    @Test("Drawn, Return presses the corner and Escape the cancel")
    func drawn() {
        let sent = Sent()
        let footer = SetupFooter(leading: [.init(SetupCopy.bBack, .back)],
                                 trailing: [.init("Not Now", .notNow, kind: .cancel),
                                            .init("Use “winlab02”", .useVM(name: "winlab02", id: "vm-1"), kind: .primary)])
        let window = Pressing(SetupFooterBar(footer: footer, credentials: SetupCredentials(), savePassword: sent.save,
                                             send: sent.send), size: CGSize(width: 600, height: 80))
        #expect(window.press(.return))
        #expect(window.press(.escape))
        #expect(sent.commands == [.useVM(name: "winlab02", id: "vm-1"), .notNow])
    }

    /// The saved PC's Save It, once the page hands it over: Return saves what's typed, once, and
    /// with nothing typed it is greyed out and Return goes nowhere. The footer hands it over and
    /// leaves the field alone: the controller forgets it once the runner has taken the press
    /// (`SetupWindowController.savePC(password:)`), so a refused Save It keeps what was typed.
    @Test("Save It in the corner hands over the typed password once, and nothing when empty")
    func savePassword() {
        let footer = SetupFooter(trailing: [.init(SetupCopy.SavedPC.bSaveIt, .savePassword, kind: .primary)])
        #expect(!footer.holdsDefault(passwordTyped: false) && footer.holdsDefault(passwordTyped: true))
        let sent = Sent()
        let credentials = SetupCredentials()
        credentials.password = "synthetic-test-secret"
        let window = Pressing(SetupFooterBar(footer: footer, credentials: credentials, savePassword: sent.save,
                                             send: sent.send), size: CGSize(width: 600, height: 80))
        #expect(window.press(.return))
        #expect(sent.saved == ["synthetic-test-secret"] && credentials.password == "synthetic-test-secret")

        let empty = Sent()
        let nothing = Pressing(SetupFooterBar(footer: footer, credentials: SetupCredentials(), savePassword: empty.save,
                                              send: empty.send), size: CGSize(width: 600, height: 80))
        nothing.press(.return)
        #expect(empty.saved.isEmpty && empty.commands.isEmpty)
    }
}

