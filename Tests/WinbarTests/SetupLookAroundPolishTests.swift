import AppKit
import SwiftUI
import Testing
@testable import Winbar

// The welcome and step 1 as the 0.2.1 polish left them: a welcome with a title and no step bar, one
// title per page saying the state's point, Homebrew's output folded away while an install goes well,
// no stale card during a read somebody pressed, the fix as the button where there is one, and a card
// that opens on one sentence. Every screen is an invented fixture (SetupFixtures), drawn offscreen or
// read as a value; nothing is run, and nothing reaches UTM, TCC or the Mac's settings.

private typealias F = SetupFixtures

@MainActor private func fixture(_ name: String) throws -> SetupWindowState {
    try #require(F.screens.first { $0.name == name }?.state, "no fixture \(name)")
}

@MainActor private func drawnLines(_ name: String, _ appearance: Snapshot.Appearance = .light) throws -> [Drawing.Line] {
    try Drawing.lines(try render(try fixture(name), appearance))
}

// MARK: - The welcome

@MainActor @Suite("The welcome: a title of its own, and no step bar over it")
struct WelcomePolishTests {
    /// The review found the welcome's hero repeating the header's mark, with one sentence where a title
    /// should be, under "Step 1 of 8". The header row isn't drawn on the welcome, and its title is.
    @Test("The welcome draws its title and no step counter; the next page draws the counter", arguments: [Snapshot.Appearance.light, .dark])
    func titleAndNoHeader(appearance: Snapshot.Appearance) throws {
        #expect(!SetupScreen.showsHeader(try fixture("welcome")))
        let lines = try drawnLines("welcome", appearance)
        let title = try #require(Drawing.find("Welcome to Winbar", in: lines), "\(lines)")
        #expect(Drawing.find("Step 1 of 8", in: lines) == nil, "\(lines)")
        // The largest words on the page, and above the lead sentence under them.
        let lead = try #require(Drawing.find("runs Windows 11", in: lines), "\(lines)")
        #expect(title.frame.height > lead.frame.height * 1.5 && title.frame.maxY <= lead.frame.minY, "\(title) \(lead)")

        // The control: the page after it has the counter, so the check above can see one.
        #expect(SetupScreen.showsHeader(try fixture("reading")))
        #expect(Drawing.find("Step 2 of 8", in: try drawnLines("reading", appearance)) != nil)
    }

    /// The five kinds of permission read as the page's longest sentence, and "adopts a VM" as jargon.
    @Test("The welcome's lines are short and in Ben's words")
    func copy() {
        let whole = SetupCopy.Welcome.body(lastBuilt: .finish).map { String(SetupCopy.markdown($0).characters) }
        #expect(whole[2] == "macOS may ask your permission a few times. Winbar tells you what each question is before it appears.")
        #expect(!whole.joined().contains("adopt"))
        #expect(whole[0].contains("uses one you already have"))
        #expect(SetupCopy.Welcome.title == "Welcome to Winbar")
    }
}

// MARK: - Step 1: titles, rows and the card's length

@MainActor @Suite("Step 1: one title per page, rows that don't repeat themselves, and one sentence before the button")
struct LookAroundPolishTests {
    /// Every step-1 page is titled with its point: the card under it no longer has a heading of its own
    /// ("Look around", then the card's heading, was two titles over every card).
    @Test("Each page's title is its state's point, and the card doesn't say it again")
    func titles() throws {
        let expected: [String: String] = [
            "reading": "Checking this Mac", "needs-utm-download": "UTM isn't installed",
            "needs-utm-update": "UTM 4.5.4 is too old for Winbar", "needs-utm-not-utm": "This isn't the UTM Winbar expects",
            "installing": "Installing UTM", "updating": "Updating UTM", "install-failed": "Homebrew couldn't install UTM",
            "ask-utm": "Next, a question for UTM", "settling": "Waiting for UTM to answer",
            "utm-silent": "UTM hasn't answered", "utm-silent-decided": "Winbar needs permission to control UTM",
            "utm-denied": "Winbar needs permission to control UTM", "utm-failed": "UTM isn't answering Winbar",
            "done": "Everything Winbar needs is here", "rereading": "Checking this Mac",
        ]
        for (name, title) in expected {
            let state = try fixture(name)
            #expect(SetupScreen.pageTitle(state) == title, "\(name)")
            let card = LookAroundPage.page(state).card
            #expect(LookAroundPage.cardText(card)?.heading ?? "" == "", "\(name): the card has a title of its own")
        }
        // Drawn: the title once, as the page's, and nowhere in the card.
        let lines = try drawnLines("utm-denied")
        #expect(lines.filter { $0.text.contains("needs permission to control UTM") }.count == 1, "\(lines)")
    }

    /// The review counted about 160 words before the update's button, and the download's card opened
    /// with a team ID, notarization and a GitHub address. The card now opens on one or two sentences
    /// that name the button; the rest is under Show Details, folded.
    @Test("The install cards open on a sentence or two that name the button, and fold the plan away")
    func shortCards() throws {
        for name in ["needs-utm-update", "needs-utm-download", "needs-utm-homebrew"] {
            let page = LookAroundPage.page(try fixture(name))
            let text = try #require(LookAroundPage.cardText(page.card))
            let words = text.paragraphs.map { String($0.characters) }.joined(separator: " ")
            #expect(words.split(separator: " ").count <= 40, "\(name): \(words)")
            #expect(words.contains(try #require(page.primary?.title)), "\(name): the sentence doesn't name the button")
            #expect(!words.contains("WDNLXAD4W8") && !words.contains("--cask") && !words.contains("sudo"), "\(name)")
            #expect(!LookAroundPage.details(page.card).isEmpty, "\(name): nothing under Show Details")
        }
        // Drawn: the team ID isn't on the page until Show Details is pressed; Show Details is.
        let lines = try drawnLines("needs-utm-download")
        #expect(Drawing.find("WDNLXAD4W8", in: lines) == nil && Drawing.find("Show Details", in: lines) != nil, "\(lines)")
    }

    /// The control: the download card as it was — lead, the shared plan and the question — runs past
    /// the limit and carries the team ID, so the check above can fail.
    @Test("The card as it was fails that")
    func shortCardsControl() throws {
        let plan = try #require(Dependencies.windowPlan(for: .utm, state: .missing, brew: nil))
        let old = ([Dependency.utm.what] + DependencyCopy.plan(.utm, plan) + [DependencyCopy.question(.utm, plan)])
            .joined(separator: " ")
        #expect(old.split(separator: " ").count > 40 && old.contains("WDNLXAD4W8"))
    }

    /// A read somebody pressed puts the card and its buttons away until it answers (the review found
    /// "UTM isn't installed" beside the spinner checking whether it now is); the runner's own re-read,
    /// which comes every time Winbar is brought to the front, leaves the page alone.
    @Test("A pressed read hides the last read's card and buttons; the runner's own re-read doesn't")
    func noStaleCard() throws {
        let pressed = LookAroundPage.page(try fixture("rereading"))
        #expect(pressed.card == .none && pressed.primary == nil && pressed.secondary == nil)
        #expect(pressed.title == "Checking this Mac" && pressed.note == "This takes a few seconds.")

        var quiet = try fixture("rereading")
        quiet.refreshing = true
        let refreshed = LookAroundPage.page(quiet)
        #expect(refreshed.title == "UTM isn't installed")
        guard case .needsUTM = refreshed.card else {
            Issue.record("the card went during the runner's own re-read: \(refreshed.card)")
            return
        }
        #expect(refreshed.primary?.enabled == false)

        // A failure's card is how the work ended, and stays through a pressed read.
        var failed = try fixture("install-failed")
        failed.inFlight = F.flight(.checkAgain(.lookAround))
        guard case .installFailed = LookAroundPage.page(failed).card else {
            Issue.record("the failure went during a read")
            return
        }

        // Drawn: none of the old card's words beside the spinner.
        let lines = try drawnLines("rereading")
        #expect(Drawing.find("free app Windows", in: lines) == nil && Drawing.find("few seconds", in: lines) != nil,
                "\(lines)")
    }

    /// Which is which comes from the runner's event: `.refreshing` for its own re-read, `.started` for
    /// a press.
    @Test("The runner's own re-read is marked as such; a pressed read, and what follows either, isn't")
    func refreshingFlag() {
        let flight = F.flight(.checkAgain(.lookAround))
        let state = F.state(facts: F.facts(utm: .missing))
        #expect(state.applying(.refreshing(flight)).refreshing)
        #expect(!state.applying(.refreshing(flight)).applying(.started(flight)).refreshing)
        #expect(!state.applying(.started(flight)).refreshing)
    }

    @Test("A row says Installed and its version, or Not installed, and never opens on its own name")
    func installedRows() {
        #expect(SetupCopy.LookAround.installed(.installed(version: "4.7.5")) == "Installed · 4.7.5")
        #expect(SetupCopy.LookAround.installed(.installed(version: nil)) == "Installed")
        #expect(SetupCopy.LookAround.installed(.missing) == nil)
        for (name, state) in F.screens where state.step == .lookAround {
            for row in LookAroundPage.page(state).rows {
                // "UTM 4.7.5" under "UTM", or "Windows App isn't installed" under "Windows App".
                #expect(!(row.detail ?? "").hasPrefix(row.title), "\(name): \(row.title) says its name twice, \(row.detail ?? "")")
            }
        }
    }
}

// MARK: - The install's output

@MainActor @Suite("While UTM installs, one line of progress; Homebrew's output under Show Details")
struct InstallDetailsTests {
    /// The review found Homebrew's raw output in monospace on screen for the whole of a healthy install.
    @Test("A healthy install shows one line and Show Details, not the output", arguments: ["installing", "updating"])
    func folded(name: String) throws {
        let lines = try drawnLines(name)
        #expect(Drawing.find("Show Details", in: lines) != nil, "\(lines)")
        for output in ["==>", "Installing Cask", "Linking Binary", "Quitting application"] {
            #expect(Drawing.find(output, in: lines) == nil, "\(name): \(output) on screen, \(lines)")
        }
        let status = name == "updating" ? "Homebrew is updating UTM" : "Homebrew is installing UTM"
        #expect(Drawing.find(status, in: lines) != nil, "\(lines)")
    }

    /// On a failure the output is the explanation, so it is open, and the sentence opens on what to do.
    @Test("A failed install shows Homebrew's last words, open")
    func openOnFailure() throws {
        let lines = try drawnLines("install-failed")
        #expect(Drawing.find("Hide Details", in: lines) != nil, "\(lines)")
        #expect(Drawing.find("Download failed on Cask", in: lines) != nil, "\(lines)")
        #expect(Drawing.find("Choose Try Again", in: lines) != nil, "\(lines)")
    }

    @Test("The progress line says what's happening in words, and the download's count beside what it counts")
    func progressLine() throws {
        let progress = SetupCopy.LookAround.progress
        #expect(progress("UTM: 112 of 250 MB (44%)", .init(done: 112, total: 250), false) == "Downloading UTM · 112 of 250 MB")
        #expect(progress("==> Downloading https://github.com/utmapp/UTM/releases/download/v4.7.5/UTM.dmg", nil, false)
                == "Downloading UTM…")
        #expect(progress("==> Moving App 'UTM.app' to '/Applications/UTM.app'", nil, false) == "Homebrew is installing UTM…")
        #expect(progress("utm 4.5.4 -> 4.7.5", nil, true) == "Homebrew is updating UTM…")
        // The command Winbar hands Homebrew is Terminal's, not a progress line.
        let asking = DependencyCopy.askingHomebrew(.utm, command: Homebrew.installCommand(brew: F.brew, cask: "utm"))
        #expect(progress(asking, nil, false) == "Homebrew is installing UTM…")
        // Winbar's own sentences are plain words already, and are said as they are.
        for own in [DependencyCopy.checkingDownload(.utm), DependencyCopy.checking(.utm),
                    DependencyCopy.copying(.utm, to: "/Applications/UTM.app"),
                    DependencyCopy.installed(.utm, version: "4.7.5")] {
            #expect(progress(own, nil, false) == own)
        }
        #expect(progress(nil, nil, false) == "Installing UTM…")
    }

    /// The control: Homebrew's own lines aren't taken for Winbar's.
    @Test("Homebrew's lines aren't Winbar's own words")
    func ownWordsControl() {
        for line in F.homebrewLines + ["curl: (56) Recv failure", "UTM: 12 of 250 MB (4%)"] {
            #expect(!SetupCopy.LookAround.ownWords(line), "\(line)")
        }
    }
}

// MARK: - Buttons: the fix, filled, in the footer

@MainActor @Suite("Step 1's fixes are buttons, and the step's action is the footer's filled corner")
struct LookAroundButtonTests {
    /// Return on the drawn page, and the one filled button in the footer's corner.
    private func returnPresses(_ name: String) throws -> [SetupCommand] {
        let state = try fixture(name)
        let sent = Sent()
        let pressing = Pressing(SetupScreen(state: state, art: nil, send: sent.send))
        #expect(pressing.press(.return), "\(name): nothing took Return")
        let png = try render(state, .light)
        let filled = Drawing.filled(SetupStyle.palette(dark: false, increasedContrast: false).accentFill, in: png)
        #expect(filled.count == 1 && filled.allSatisfy { $0.minY > setupWindowSize.height - setupFooterBand },
                "\(name): \(filled)")
        return sent.commands
    }

    /// Downgraded from a ship-blocker: Try Again was filled where only the switch in System Settings
    /// can change anything.
    @Test("Automation refused, or silent with an answer on file: Return opens Automation settings",
          arguments: ["utm-denied", "utm-silent-decided"])
    func settings(name: String) throws {
        #expect(try returnPresses(name) == [.perform(.openAutomationSettings)])
    }

    @Test("A UTM that isn't UTM: Return shows it in the Finder")
    func finder() throws {
        #expect(try returnPresses("needs-utm-not-utm") == [.perform(.showUTMInFinder)])
    }

    @Test("UTM answered with an error: Return is Open UTM, which opens it and asks again")
    func openUTM() throws {
        #expect(LookAroundPage.page(try fixture("utm-failed")).primary?.title == "Open UTM")
        #expect(try returnPresses("utm-failed") == [.perform(.run(.settleUTM))])
    }

    /// Every step-1 page with something to press has it in the footer, filled, and nothing filled on
    /// the page: the card never holds a button of its own.
    @Test("Every step-1 page's action is the footer's filled corner", arguments: [Snapshot.Appearance.light, .dark])
    func footerCorner(appearance: Snapshot.Appearance) throws {
        let fill = SetupStyle.palette(dark: appearance.isDark, increasedContrast: false).accentFill
        for (name, state) in F.screens where state.step == .lookAround {
            let page = LookAroundPage.page(state)
            let filled = Drawing.filled(fill, in: try render(state, appearance))
            if page.primary?.enabled == true {
                #expect(filled.count == 1 && filled.allSatisfy { $0.minY > setupWindowSize.height - setupFooterBand },
                        "\(name): \(filled)")
                #expect(SetupFooter.footer(state).corner?.title == page.primary?.title, "\(name)")
            } else {
                #expect(filled.isEmpty, "\(name): \(filled)")
            }
        }
    }
}

// MARK: - Coming back from System Settings

@Suite("A read after coming back asks UTM again when the fix was made elsewhere")
struct ReasksUTMTests {
    /// The runner re-reads whenever Winbar comes back to the front, but the machine took what utmctl
    /// said to the last Open UTM and Ask for every read after it: a refusal lifted in System Settings
    /// stayed on screen until someone pressed Try Again.
    @Test("A refusal, an error, and silence with an answer on file are asked again; silence behind a prompt isn't")
    func rule() {
        var asked = 0
        let decided: () -> Automation.Consent = { asked += 1; return .decided }
        let prompt: () -> Automation.Consent = { .wouldPrompt }
        #expect(SetupRunner.reasksUTM(after: .denied, justAsked: false, consent: prompt))
        #expect(SetupRunner.reasksUTM(after: .failed("UTM is not running (error -600)"), justAsked: false, consent: prompt))
        #expect(SetupRunner.reasksUTM(after: .silent(seconds: 60), justAsked: false, consent: decided))
        #expect(!SetupRunner.reasksUTM(after: .silent(seconds: 60), justAsked: false, consent: prompt))
        #expect(!SetupRunner.reasksUTM(after: .silent(seconds: 60), justAsked: false, consent: { .unknown }))
        // The read straight after the asking takes its answer, whatever it was.
        #expect(!SetupRunner.reasksUTM(after: .denied, justAsked: true, consent: prompt))
        #expect(!SetupRunner.reasksUTM(after: .silent(seconds: 60), justAsked: true, consent: decided))
        // macOS is asked about consent only for silence (it can take three seconds).
        _ = SetupRunner.reasksUTM(after: .denied, justAsked: false, consent: decided)
        #expect(asked == 1)
    }

    /// The control: the rule the machine had — take any answer that wasn't a yes — keeps the refusal.
    @Test("The old rule keeps a refusal however often Winbar comes back")
    func ruleControl() {
        // The old rule, as the machine had it: any answer that wasn't a yes was taken again, never re-asked.
        let oldReasks: (UTM.CtlAnswer) -> Bool = { $0.isAnswered }
        #expect(!oldReasks(.denied) && !oldReasks(.silent(seconds: 60)))
        #expect(SetupRunner.reasksUTM(after: .denied, justAsked: false, consent: { .decided }) != oldReasks(.denied))
    }
}
