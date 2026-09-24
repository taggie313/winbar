import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Winbar

// The Set Up Winbar window's decisions, steps 0 and 1: what the runner's events do to what it shows,
// what step 1's page says and offers for every state the Mac can be in, where Armie may appear, when
// the window opens by itself and what closing it means, and that its colours keep their contrast.
// All pure, on invented facts (SetupFixtures). The controller is driven once, against a runner whose
// machine reaches nothing, to show that Start reads step 1 and that Not Now and Hide Armie are kept.
// No window is shown, and nothing here reaches UTM, a VM, TCC, the keychain or the user's defaults.

private typealias F = SetupFixtures

/// Everything a step-1 page says, as the words a person reads, joined into one string: its title, the
/// rows, the card's words and what it folds under Show Details (or an install's output and failure),
/// the buttons, and Armie's line.
private func said(_ state: SetupWindowState) -> String {
    let page = LookAroundPage.page(state)
    var words = [page.title] + page.rows.flatMap { [$0.title, $0.detail ?? ""] } + [page.note ?? ""]
    if let text = LookAroundPage.cardText(page.card) {
        words.append(text.heading)
        words += ([text.lead] + text.paragraphs.map(Optional.some) + [text.emphasis, text.aside])
            .compactMap { $0.map { String($0.characters) } }
    }
    words += LookAroundPage.details(page.card)
    switch page.card {
    case .installing(let lines, _, _): words += lines
    case .installFailed(let problem, let lines, _): words += [problem.detail] + lines
    default: break
    }
    words += [page.primary?.title, page.secondary?.title, LookAroundPage.armieLine(state)].compactMap { $0 }
    return words.filter { !$0.isEmpty }.joined(separator: " ")
}

// MARK: - The step bar and the panes

@Suite("The step bar, and Winbar's mark")
struct SetupStepBarTests {
    @Test("Every step before the cursor is done, the cursor is current, and the rest wait")
    func marks() {
        for (index, cursor) in WizardStep.allCases.enumerated() {
            let marks = StepBar.marks(current: cursor)
            #expect(marks.count == 8)
            for (other, mark) in marks.enumerated() {
                let expected: StepBar.Mark = other < index ? .done : other == index ? .current : .pending
                #expect(mark == expected, "cursor \(cursor), step \(other)")
            }
        }
    }

    /// The segments were sized to their labels ("Tune" about 24 pt, "The certificate" about 70), so
    /// the bar had no rhythm. Now every segment is the same. The short names are the segments' tooltips.
    @Test("Every segment of the bar is the same width, and the eight fit the narrowest window")
    func equalSegments() {
        let width = StepBar.segmentWidth(total: SetupStyle.contentWidth)
        #expect(abs(width * 8 + StepBar.spacing * 7 - SetupStyle.contentWidth) < 0.001)
        // Beside the counter ("Step 5 of 8", about 70 pt with its gap), each is still a clear dash.
        #expect(StepBar.segmentWidth(total: SetupStyle.contentWidth - 90) > 40)
        #expect(SetupCopy.stepBarNames.count == WizardStep.allCases.count)
        // Each short label is its step's own name or the end of it: "Certificate" for "The certificate".
        for (short, full) in zip(SetupCopy.stepBarNames, SetupCopy.stepNames) {
            #expect(full.lowercased().hasSuffix(short.lowercased()), "\(short) / \(full)")
        }
    }

    /// The menu bar icon (SF Symbol square.split.2x2) is one rounded square with a cross through it.
    /// The mark the window drew was four separate rounded tiles with gaps — the Windows logo's
    /// construction — so its middle was empty where the icon's cross meets.
    @Test("The mark is one square with a cross through it, as the menu bar icon is")
    func markGeometry() {
        let rect = CGRect(x: 0, y: 0, width: 96, height: 96)
        let line = WinbarMarkShape.lineWidth(size: 96)
        let mark = WinbarMarkShape(radius: WinbarMarkShape.radius(size: 96))
            .path(in: rect).strokedPath(StrokeStyle(lineWidth: line))
        // The cross meets in the middle, and runs out to the outline on all four sides.
        #expect(mark.contains(CGPoint(x: 48, y: 48)))
        for edge in [CGPoint(x: 48, y: 1), CGPoint(x: 48, y: 95), CGPoint(x: 1, y: 48), CGPoint(x: 95, y: 48)] {
            #expect(mark.contains(edge), "\(edge)")
        }
        // Each quarter's own middle is open: a line drawing, not four filled tiles.
        for quarter in [CGPoint(x: 24, y: 24), CGPoint(x: 72, y: 24), CGPoint(x: 24, y: 72), CGPoint(x: 72, y: 72)] {
            #expect(!mark.contains(quarter), "\(quarter)")
        }
    }

    /// The control: the four-tile mark the window had, drawn the same way, has nothing in its middle.
    @Test("The old four-tile mark fails that")
    func markGeometryControl() {
        var tiles = Path()
        let gap: CGFloat = 8, pane: CGFloat = 44
        for row in 0..<2 {
            for column in 0..<2 {
                tiles.addRoundedRect(in: CGRect(x: CGFloat(column) * (pane + gap), y: CGFloat(row) * (pane + gap),
                                                width: pane, height: pane), cornerSize: CGSize(width: 10, height: 10))
            }
        }
        #expect(!tiles.contains(CGPoint(x: 48, y: 48)))
        #expect(tiles.contains(CGPoint(x: 24, y: 24)))
    }

    @Test("The step bar reads as one sentence, and the header counts from one")
    func words() {
        #expect(SetupCopy.stepCounter(.welcome) == "Step 1 of 8")
        #expect(SetupCopy.stepCounter(.finish) == "Step 8 of 8")
        #expect(SetupCopy.stepBarLabel(.lookAround) == "Step 2 of 8: Look around")
        for step in WizardStep.allCases { #expect(SetupCopy.stepName(step) == SetupCopy.stepNames[step.position]) }
    }
}

private extension WizardStep {
    var position: Int { WizardStep.allCases.firstIndex(of: self)! }
}

// MARK: - The palette

@Suite("The window's blue keeps its contrast in every appearance")
struct SetupPaletteTests {
    private static let white = SetupStyle.RGB(0xFFFFFF)

    /// WCAG AA for text (4.5:1), and AAA (7:1) under Increase Contrast, which asked for more. Each
    /// pairing is one the window draws: the default button's title on its fill (white, or black on
    /// dark mode's pale Increase Contrast fill); the accent's words and lines on a card and on both
    /// ends of the backdrop, where the step bar and Winbar's mark sit.
    @Test("The title on the accent fill, and the accent's words on cards and the backdrop, pass AA — AAA with Increase Contrast")
    func contrast() {
        for dark in [false, true] {
            for increased in [false, true] {
                let p = SetupStyle.palette(dark: dark, increasedContrast: increased)
                let floor = increased ? 7.0 : 4.5
                let name = "\(dark ? "dark" : "light")\(increased ? ", increased contrast" : "")"
                #expect(SetupStyle.contrast(p.onAccentFill, p.accentFill) >= floor, "the title on the fill, \(name)")
                for surface in [p.card, p.backdropTop, p.backdropBottom] {
                    #expect(SetupStyle.contrast(p.accentText, surface) >= floor, "the accent's words, \(name)")
                }
            }
        }
    }

    /// The review measured the renders: the orange `!` at 2.2:1 on a light card, and the step bar's
    /// labels, the done labels and the counter at 3.3 to 3.8:1 on the light backdrop. The muted words
    /// are text (4.5:1, 7:1 with Increase Contrast); the `!` is a status mark, which WCAG asks 3:1 of,
    /// held here to the text floor since it is a character.
    @Test("The backdrop's quieter words and the row's orange mark pass AA — AAA with Increase Contrast")
    func mutedAndAttention() {
        for dark in [false, true] {
            for increased in [false, true] {
                let p = SetupStyle.palette(dark: dark, increasedContrast: increased)
                let floor = increased ? 7.0 : 4.5
                let name = "\(dark ? "dark" : "light")\(increased ? ", increased contrast" : "")"
                for surface in [p.backdropTop, p.backdropBottom] {
                    #expect(SetupStyle.contrast(p.mutedText, surface) >= floor, "muted words on the backdrop, \(name)")
                }
                // In a card: on the card, and on an output box, which is the card with 5% of the text
                // colour laid over it.
                let ink = dark ? 1.0 : 0.0
                let box = SetupStyle.RGB(UInt32((p.card.red * 0.95 + ink * 0.05) * 255) << 16
                                         | UInt32((p.card.green * 0.95 + ink * 0.05) * 255) << 8
                                         | UInt32((p.card.blue * 0.95 + ink * 0.05) * 255))
                for surface in [p.card, box] {
                    #expect(SetupStyle.contrast(p.mutedText, surface) >= floor, "muted words in a card, \(name)")
                }
                #expect(SetupStyle.contrast(p.attention, p.card) >= floor, "the ! on a card, \(name)")
            }
        }
    }

    /// The colours they replace, measured the same way: the control for the test above.
    @Test("The system orange and a translucent secondary grey fail that")
    func mutedAndAttentionControl() {
        let light = SetupStyle.palette(dark: false, increasedContrast: false)
        #expect(SetupStyle.contrast(SetupStyle.RGB(0xFF9500), light.card) < 3)          // .orange, light
        #expect(SetupStyle.contrast(SetupStyle.RGB(0x878A91), light.backdropTop) < 4.5)  // what the labels measured
    }

    @Test("Increase Contrast drops the tint and the translucency, and draws heavier edges")
    func increasedContrast() {
        for dark in [false, true] {
            let plain = SetupStyle.palette(dark: dark, increasedContrast: false)
            let increased = SetupStyle.palette(dark: dark, increasedContrast: true)
            #expect(increased.backdropTop == increased.backdropBottom)
            #expect(plain.backdropTop != plain.backdropBottom)
            #expect(increased.cardOpacity == 1 && plain.cardOpacity < 1)
            #expect(increased.strokeOpacity > plain.strokeOpacity * 4)
        }
    }

    /// A control for the check above: it isn't passing everything. The dark fill behind the tinted
    /// button's white title was the first choice for the accent's words too, and fails on a dark card.
    @Test("The contrast check fails what it should")
    func control() {
        let dark = SetupStyle.palette(dark: true, increasedContrast: false)
        #expect(SetupStyle.contrast(dark.accentFill, dark.card) < 4.5)
        #expect(abs(SetupStyle.contrast(Self.white, SetupStyle.RGB(0x000000)) - 21) < 0.01)
    }
}

// MARK: - Events into what the window shows

@Suite("What the runner's events do to the window")
struct SetupWindowStateTests {
    /// A refusal outlasting the next start is deliberate: that start is often the read that took the
    /// refused press's place, and it used to take the banner with it before anyone read it
    /// (`stillRefused` decides when it goes).
    @Test("Work that isn't a read starts a fresh output; a read keeps what the last work said, and the refusal")
    func startClearsLines() {
        var state = F.installFailed
        state.refusal = SetupRunner.Refusal(wanted: .settleUTM, inFlight: F.flight(.installUTM))
        let read = state.applying(.started(F.flight(.checkAgain(.lookAround))))
        #expect(read.lines == state.lines)
        #expect(read.refusal == state.refusal)
        let install = state.applying(.started(F.flight(.installUTM)))
        #expect(install.lines.isEmpty)
        #expect(install.inFlight?.work == .installUTM)
    }

    /// Josh's Approve Certificate…, refused by a read he hadn't pressed: the banner went with the next
    /// event, before anyone read it. A refusal now stands while the press is still one the page offers,
    /// and goes once it isn't: a fresh snapshot answers a refused read; the press, pressed again and
    /// taken, ends it; the step changing, or the Mac making the press pointless, ends it. The controls
    /// are HEAD's reducer (gone at `.refreshing`) and a rule that never drops it (the trusted case).
    @Test("A refused press is said until it stops being true")
    func refusalLifetime() throws {
        let read = F.flight(.lookAgain(.certificate, forgetting: .statuses))
        var state = CertificateFixtures.state("initial")
        let facts = try #require(state.facts)
        let refusal = SetupRunner.Refusal(wanted: .trustCertificate, inFlight: read)
        state.refusal = refusal
        let reading = state.applying(.refreshing(read))
        #expect(reading.refusal == refusal)
        #expect(reading.applying(.refreshed(facts)).refusal == refusal, "still one the page offers")
        var trusted = facts
        trusted.rows["H7"] = JourneyFixtures.row("H7", .ok("Trusted"))
        #expect(reading.applying(.refreshed(trusted)).refusal == nil, "trusted meanwhile")
        var undone = facts
        undone.rows["G1"] = JourneyFixtures.row("G1", .fixable("Balanced"))
        let back = reading.applying(.refreshed(undone))
        #expect(back.step == .tune && back.refusal == nil, "another page")
        let taken = reading.applying(.ended(SetupRunner.Ending(work: .trustCertificate, outcome: .finished, facts: facts,
                                                               slept: false, started: F.started)))
        #expect(taken.refusal == nil, "pressed again and taken")
        var refusedRead = state
        refusedRead.refusal = SetupRunner.Refusal(wanted: .checkAgain(.certificate), inFlight: read)
        #expect(refusedRead.applying(.refreshing(read)).applying(.refreshed(facts)).refusal == nil, "a read is answered by any read")
    }

    /// A read nobody pressed keeps pages as they are only while it runs. `refreshing` lasted until the
    /// next `.started`, so a page kept its card through the next read somebody pressed, which is
    /// the one that should put a stale card away. The control is a `.refreshed` that leaves it set.
    @Test("A read nobody pressed is refreshing until its snapshot comes, and no longer")
    func refreshingEndsWithItsRead() {
        let flight = F.flight(.lookAgain(.lookAround, forgetting: .statuses))
        let reading = F.installFailed.applying(.refreshing(flight))
        #expect(reading.refreshing && reading.inFlight == flight)
        let read = reading.applying(.refreshed(F.facts(utm: .missing, brew: F.brew)))
        #expect(!read.refreshing)
        #expect(read.inFlight == nil)
    }

    /// The refusal names the work in flight; once that work has ended it would be saying something
    /// untrue beside the page that shows it ended.
    @Test("A refusal goes when the work it was refused for ends")
    func refusalEndsWithTheWork() {
        var state = F.installing
        state.refusal = SetupRunner.Refusal(wanted: .checkAgain(.lookAround), inFlight: F.flight(.installUTM))
        let ending = SetupRunner.Ending(work: .installUTM, outcome: .finished, facts: F.facts(utm: F.installed),
                                        slept: false, started: F.started)
        let ended = state.applying(.ended(ending))
        #expect(ended.refusal == nil)
        #expect(LookAroundPage.page(ended).card == .askUTM(quarantined: false))
        // Refused while waiting on UTM's answer: gone once UTM has answered too.
        var settling = F.state(facts: F.facts(utm: F.installed), inFlight: F.flight(.settleUTM))
        settling.refusal = SetupRunner.Refusal(wanted: .checkAgain(.lookAround), inFlight: F.flight(.settleUTM))
        let answered = SetupRunner.Ending(work: .settleUTM, outcome: .finished,
                                          facts: F.facts(utm: F.installed, answers: .answered, vms: F.twoVMs),
                                          slept: false, started: F.started)
        #expect(settling.applying(.ended(answered)).refusal == nil)
    }

    @Test("Progress lines are kept in order, without repeats, and only the last eight")
    func progressLines() {
        var state = F.state(facts: F.facts(utm: .missing, brew: F.brew)).applying(.started(F.flight(.installUTM)))
        for n in 1...12 {
            state = state.applying(.progressed(F.flight(.installUTM, line: "line \(n)")))
            state = state.applying(.progressed(F.flight(.installUTM, line: "line \(n)")))
        }
        #expect(state.lines == (5...12).map { "line \($0)" })
        // A read's progress ("Asking Windows…") isn't the install's output.
        let read = state.applying(.progressed(F.flight(.checkAgain(.lookAround), line: "Asking Windows…")))
        #expect(read.lines == state.lines)
    }

    /// A line said just before an install ended can arrive after its `.ended`: the runner sends it
    /// after letting go of its lock. Taken, it put the install back in flight with nothing left to
    /// clear it, and the page looked busy for good. The control is HEAD's `.progressed`, which took any
    /// line: the late one leaves `inFlight` set.
    @Test("A line that arrives after its work ended, or from another run, changes nothing")
    func lateProgress() {
        let running = F.state(facts: F.facts(utm: .missing, brew: F.brew)).applying(.started(F.flight(.installUTM)))
            .applying(.progressed(F.flight(.installUTM, line: "==> Downloading UTM")))
        let ended = running.applying(.ended(SetupRunner.Ending(work: .installUTM, outcome: .finished,
                                                               facts: F.facts(utm: F.installed), slept: false,
                                                               started: F.started, lines: ["==> Downloading UTM"])))
        let late = ended.applying(.progressed(F.flight(.installUTM, line: "==> Pouring utm")))
        #expect(late.inFlight == nil)
        #expect(late.lines == ended.lines)
        let other = SetupRunner.InFlight(work: .installUTM, started: F.started.addingTimeInterval(60), vm: nil, line: "x")
        #expect(running.applying(.progressed(other)) == running)
    }

    /// Winbar's own download says how far it has got once a second (`DependencyCopy.downloadProgress`);
    /// each count replaces the last, so the card shows one moving line, not eight stale numbers.
    @Test("The download's running count updates one line in place; every other line is kept")
    func downloadCount() {
        let source = URL(string: "https://github.com/utmapp/UTM/releases/download/v4.7.5/UTM.dmg")!
        let lines = [DependencyCopy.downloading(.utm, from: source),
                     DependencyCopy.downloadProgress(.utm, done: 12 << 20, total: 250 << 20),
                     DependencyCopy.downloadProgress(.utm, done: 25 << 20, total: 250 << 20),
                     DependencyCopy.downloadProgress(.utm, done: 250 << 20, total: 250 << 20),
                     DependencyCopy.checkingDownload(.utm),
                     DependencyCopy.downloadProgress(.utm, done: 7 << 20, total: 0)]
        var state = F.state(facts: F.facts(utm: .missing)).applying(.started(F.flight(.installUTM)))
        for line in lines { state = state.applying(.progressed(F.flight(.installUTM, line: line))) }
        #expect(state.lines == [lines[0], "UTM: 250 of 250 MB (100%)", lines[4], "UTM: 7 MB"])
        #expect(!SetupWindowState.isDownloadCount("UTM: utmctl said nothing"))
        #expect(!SetupWindowState.isDownloadCount("==> Downloading https://github.com/utmapp/UTM/releases/UTM.dmg"))
    }

    /// The live box keeps to its newest few lines, so the newest can't be pushed off the page; the
    /// review saw eight, with Armie above them, put it at the window's edge.
    @Test("The install card's live output is its newest four lines")
    func liveOutputRows() {
        #expect(OutputBox.liveRows == 4)
        #expect(SetupWindowState.keptLines > OutputBox.liveRows)   // the failure card still gets all eight
    }

    /// The bar reads the download's count off `DependencyCopy.downloadProgress`'s own words.
    @Test("The download's count becomes the bar's numbers; nothing else does")
    func downloadCountParsed() {
        #expect(SetupWindowState.downloadCount(DependencyCopy.downloadProgress(.utm, done: 112 << 20, total: 250 << 20))
                == .init(done: 112, total: 250))
        #expect(SetupWindowState.downloadCount(DependencyCopy.downloadProgress(.utm, done: 250 << 20, total: 250 << 20))?
                .fraction == 1)
        // No total: nothing a bar can show.
        #expect(SetupWindowState.downloadCount(DependencyCopy.downloadProgress(.utm, done: 7 << 20, total: 0)) == nil)
        for other in ["==> Downloading https://github.com/utmapp/UTM/releases/UTM.dmg", "UTM: 12 of MB (4%)",
                      DependencyCopy.checkingDownload(.utm), "UTM: 12 of 250 GB (4%)"] {
            #expect(SetupWindowState.downloadCount(other) == nil, "\(other)")
        }
    }

    @Test("An ending hands over its snapshot with the window's own answers laid over it")
    func endingKeepsWindowAnswers() {
        var state = F.state(inFlight: F.flight(.installUTM))
        state.answers.leftAlone = ["C1"]
        var facts = F.facts(utm: F.installed)
        facts.answers = SetupFlow.Answers()   // the runner's copy, from before the window's press
        let ending = SetupRunner.Ending(work: .installUTM, outcome: .finished, facts: facts, slept: false, started: F.started)
        let next = state.applying(.ended(ending))
        #expect(next.inFlight == nil)
        #expect(next.lastEnding == ending)
        #expect(next.facts?.answers == state.answers)
        #expect(next.step == .lookAround)
    }

    @Test("A fresh snapshot takes the window back to a step that came undone, and never forward")
    func landing() {
        // On a later step, UTM quits: back to step 1.
        let later = F.state(.vm, facts: F.facts(utm: F.installed, answers: .answered, vms: F.twoVMs))
        #expect(later.applying(.refreshed(F.facts(utm: F.installed))).step == .lookAround)
        // On the welcome after Back, a snapshot where step 1 is done doesn't move the window on.
        var welcome = F.state(.welcome)
        welcome.answers.started = true
        #expect(welcome.applying(.refreshed(F.facts(utm: F.installed, answers: .answered, vms: F.twoVMs))).step == .welcome)
        // A stale notice changes nothing by itself.
        #expect(later.applying(.stale(.utmChanged)) == later)
    }

    @Test("A window arriving at the runner takes what's in flight and the newest snapshot")
    func attached() {
        let state = F.state()
        let next = state.attached(inFlight: F.flight(.installUTM), latest: F.facts(utm: .missing))
        #expect(next.inFlight?.work == .installUTM)
        #expect(next.facts?.utm == .missing)
        #expect(state.attached(inFlight: nil, latest: nil).facts == nil)
    }

    /// §2.4: reopening "shows how far it got". A window closed while UTM installed heard no ending,
    /// and a snapshot can't say an install failed, so the ending comes with the attach.
    @Test("Reopened after the install failed unseen, the window shows that failure")
    func reopenedAfterFailure() throws {
        // Looking at the install question, press install, close: the window saw it start and no more.
        var state = F.state(facts: F.facts(utm: .missing, brew: F.brew))
        let run = F.flight(.installUTM)
        state = state.applying(.started(run)).applying(.progressed(F.flight(.installUTM, line: F.homebrewLines[0])))
        let problem = SetupRunner.Problem(title: "Homebrew couldn't install UTM",
                                          detail: "It stopped with exit status 1; its own output is above.")
        // What the run said, the window's one line and the failure's own after the close.
        let said = [F.homebrewLines[0], F.homebrewLines[1], "Error: Download failed on Cask 'utm'"]
        let ending = SetupRunner.Ending(work: .installUTM, outcome: .failed(problem), facts: F.facts(utm: .missing, brew: F.brew),
                                        slept: false, started: run.started, lines: said)
        let reopened = state.attached(inFlight: nil, latest: ending.facts, lastEnded: ending)
        #expect(reopened.lastEnding == ending)
        #expect(reopened.inFlight == nil)
        guard case .installFailed(let shown, let lines, _) = LookAroundPage.page(reopened).card else {
            Issue.record("not the failure card: \(LookAroundPage.page(reopened).card)")
            return
        }
        #expect(shown == problem)
        // All of the run's output is above the detail that points at it, not only what the window saw.
        #expect(lines == said)
        // The same, for an ending the window hears while open after being reopened part way through.
        #expect(state.applying(.ended(ending)).lines == said)
    }

    /// A Try Again that failed too, while the window was closed: its reason, never the first one's.
    @Test("A retry that failed unseen replaces the first failure; lines from another run are dropped")
    func reopenedAfterRetry() throws {
        var first = F.installFailed
        let retry = SetupRunner.InFlight(work: .installUTM, started: F.started.addingTimeInterval(60), vm: nil, line: nil)
        first = first.applying(.started(retry)).applying(.progressed(SetupRunner.InFlight(
            work: .installUTM, started: retry.started, vm: nil, line: "==> Downloading again")))
        let second = SetupRunner.Problem(title: "Homebrew didn't finish", detail: "Run it yourself and watch what it says.")
        let ending = SetupRunner.Ending(work: .installUTM, outcome: .failed(second), facts: F.facts(utm: .missing, brew: F.brew),
                                        slept: false, started: retry.started, lines: ["==> Downloading again", "Error: gone"])
        let reopened = first.attached(inFlight: nil, latest: ending.facts, lastEnded: ending)
        guard case .installFailed(let shown, let lines, _) = LookAroundPage.page(reopened).card else {
            Issue.record("not the failure card")
            return
        }
        #expect(shown == second)
        #expect(lines == ["==> Downloading again", "Error: gone"])

        // Lines the window holds from a run that isn't the one that ended aren't shown under it: the
        // ending's own are.
        var stale = F.installFailed
        stale.linesStarted = F.started.addingTimeInterval(-600)
        let dropped = stale.attached(inFlight: nil, latest: ending.facts, lastEnded: ending)
        #expect(dropped.lines == ending.lines)
        // Reopened while a run the window never saw start is going: its newest line, not the old run's.
        let running = SetupRunner.InFlight(work: .installUTM, started: retry.started, vm: nil, line: "UTM: 12 of 250 MB (4%)")
        #expect(F.installFailed.attached(inFlight: running, latest: nil).lines == ["UTM: 12 of 250 MB (4%)"])
        // An ending the window already holds changes nothing.
        #expect(reopened.attached(inFlight: nil, latest: ending.facts, lastEnded: ending) == reopened)
    }

    @Test("Back from step 1 is the welcome, and from the welcome stays there")
    func back() {
        #expect(SetupWindowState.back(from: .lookAround) == .welcome)
        #expect(SetupWindowState.back(from: .welcome) == .welcome)
        #expect(SetupWindowState.back(from: .vm) == .lookAround)
    }
}

// MARK: - Step 1's page

@MainActor @Suite("A failure stands while it's still true, through a look, and goes once the Mac has moved past it")
struct StandingFailureTests {
    private func failed(_ state: SetupWindowState, _ work: SetupRunner.Work, _ problem: SetupRunner.Problem) -> SetupWindowState {
        var state = state
        state.lastEnding = SetupRunner.Ending(work: work, outcome: .failed(problem), facts: state.facts!, slept: false,
                                              started: F.started)
        return state
    }

    private let look = F.flight(.lookAgain(.savedPC, forgetting: .statuses))

    /// The App Store hand-off failed, and Windows App was then installed some other way: a look nobody
    /// pressed doesn't replace the ending, so without the rule the failure would sit over a step that
    /// no longer offers the hand-off. The control is a rule that ignores whether the work still
    /// applies: the card stays after the fix.
    @Test("A failed App Store hand-off stands until Windows App is there")
    func appStore() throws {
        let problem = SetupRunner.Problem(title: "The App Store didn't open", detail: "It said the page isn't available.")
        let state = failed(try JourneyPolishFixtures.screen("saved-needs-app"), .installWindowsApp, problem)
        #expect(SetupJourneyView.problemCard(state) == problem)
        var installed = try #require(state.facts)
        installed.windowsApp = .installed(version: "11.4")
        let after = state.applying(.refreshing(look)).applying(.refreshed(installed))
        #expect(after.lastEnding == state.lastEnding, "a look isn't an ending")
        #expect(SetupJourneyView.problemCard(after) == nil)
    }

    @Test("A failed Fix stands while its row still needs fixing, and goes once it doesn't")
    func fix() throws {
        let problem = SetupRunner.Problem(title: "The power plan didn't change", detail: "Windows said access is denied.")
        var tune = SetupFixtures.state(.tune, facts: JourneyFixtures.facts)
        tune.facts?.rows["G1"] = JourneyFixtures.row("G1", .fixable("Balanced"))
        let state = failed(tune, .fix(checkID: "G1"), problem)
        #expect(SetupJourneyView.problemCard(state) == problem)
        let still = state.applying(.refreshed(try #require(state.facts)))
        #expect(SetupJourneyView.problemCard(still) == problem, "still true after a read")
        var fixed = try #require(state.facts)
        fixed.rows["G1"] = JourneyFixtures.row("G1", .ok("High performance"))
        #expect(SetupJourneyView.problemCard(state.applying(.refreshed(fixed))) == nil)
    }

    @Test("A failed start says so on the VM step while the VM is stopped, and not once it runs")
    func start() throws {
        let problem = SetupRunner.Problem(title: "UTM couldn't start “winlab02”", detail: "It said the VM is busy.")
        var stopped = SetupFixtures.state(.vm, facts: SetupVMTests.facts())
        stopped.facts?.vmRunning = false
        stopped = failed(stopped, .startVM(SetupVMTests.new.name), problem)
        #expect(stopped.standingFailure == problem)
        #expect(Drawing.find("couldn't start", in: try Drawing.lines(try render(stopped, .light))) != nil)
        var running = stopped
        running.facts?.vmRunning = true
        #expect(running.standingFailure == nil)
        #expect(Drawing.find("couldn't start", in: try Drawing.lines(try render(running, .light))) == nil)
    }

    /// The finding that made the rule necessary: coming back to a failed UTM install turned its card,
    /// with Homebrew's last words and Try Again, into the plain "install UTM" card, because the read on
    /// return was a Check Again and its ending replaced the failure. A look keeps it. The control is
    /// that old path, `.started` then `.ended` of a Check Again, in the same test.
    @Test("A failed UTM install keeps its card, its lines and Try Again through a look")
    func installFailedThroughALook() throws {
        let before = LookAroundPage.page(F.installFailed)
        guard case .installFailed(let problem, let lines, _) = before.card else {
            Issue.record("not the failure card: \(before.card)")
            return
        }
        let missing = F.facts(utm: .missing, brew: F.brew)
        let after = F.installFailed.applying(.refreshing(F.flight(.lookAgain(.lookAround, forgetting: .statuses))))
            .applying(.refreshed(missing))
        let page = LookAroundPage.page(after)
        #expect(page.card == .installFailed(problem, lines: lines, slept: false))
        #expect(page.primary == .init(title: SetupCopy.bTryAgain, action: .run(.installUTM), enabled: true))

        let read = F.installFailed.applying(.started(F.flight(.checkAgain(.lookAround))))
            .applying(.ended(SetupRunner.Ending(work: .checkAgain(.lookAround), outcome: .finished, facts: missing,
                                                slept: false, started: F.started)))
        guard case .needsUTM = LookAroundPage.page(read).card else {
            Issue.record("the control should lose the failure card: \(LookAroundPage.page(read).card)")
            return
        }
    }
}

/// A refused press was said only on Look around, and there without the gate's reason: the VM step
/// said nothing, and the journey's steps a bare line of grey text. The banner is on every step, first.
@MainActor @Suite("A refused press is said at the top of every step, in the words that are true")
struct RefusalDrawnTests {
    /// The control is the VM step without its banner: nothing on the page says the press didn't start.
    @Test("The VM step says a refused press, and why")
    func vmStep() throws {
        let read = F.flight(.checkAgain(.vm))
        var state = F.state(.vm, facts: SetupVMTests.facts(), inFlight: read)
        state.facts?.vmRunning = false
        state.refusal = SetupRunner.Refusal(wanted: .startVM(SetupVMTests.new.name), inFlight: read)
        let lines = try Drawing.lines(try render(state, .light))
        #expect(Drawing.find("one thing at a time", in: lines) != nil, "\(lines)")
    }

    /// Turned down by the app's gate (the menu starting a VM), the words are the gate's: the work the
    /// refusal carries is the press itself, not what was in the way. The control is HEAD's banner,
    /// which ignored the reason and said "Winbar is still installing UTM".
    @Test("Look around says the gate's own words, not the work it was going to do")
    func gateWords() throws {
        var state = F.state(facts: F.facts(utm: .missing))
        state.refusal = SetupRunner.Refusal(wanted: .installUTM, inFlight: F.flight(.installUTM),
                                            reason: "Winbar is still starting “atelier”. Wait for it to finish, then try again.")
        let lines = try Drawing.lines(try render(state, .light))
        #expect(Drawing.find("still starting", in: lines) != nil, "\(lines)")
        // What `run` puts in a gate's refusal is the press itself; HEAD's banner said it was still going.
        #expect(Drawing.find("still installing UTM", in: lines) == nil, "\(lines)")
    }

    /// The journey's steps drew the refusal as bare text in the page's grey; now the same banner.
    @Test("The journey's steps say it in the banner, and after the work, that it didn't start")
    func journey() throws {
        var state = CertificateFixtures.state("initial")
        state.refusal = SetupRunner.Refusal(wanted: .trustCertificate, inFlight: F.flight(.checkAgain(.certificate)))
        let lines = try Drawing.lines(try render(state, .light))
        #expect(Drawing.find("didn't start that", in: lines) != nil, "\(lines)")
    }
}

@Suite("Step 1: the rows, the card and the buttons, for every state")
struct LookAroundPageTests {
    private func page(_ name: String) throws -> LookAroundPage.Page {
        let state = try #require(F.screens.first { $0.name == name }?.state, "no fixture \(name)")
        return LookAroundPage.page(state)
    }

    private func marks(_ page: LookAroundPage.Page) -> [CreateProgress.Mark] { page.rows.map(\.mark) }

    @Test("Three rows, always in the spec's order")
    func rows() throws {
        for (name, state) in F.screens where state.step == .lookAround {
            #expect(LookAroundPage.page(state).rows.map(\.title) == ["UTM", "Virtual machines", "Windows App"], "\(name)")
        }
    }

    /// The review found one spinner on an empty window. The page says what it's doing and how long.
    @Test("Before the first look comes back, the UTM row is running, the page says it's checking, and nothing is offered")
    func reading() throws {
        let page = try page("reading")
        #expect(marks(page) == [.running, .pending, .pending])
        #expect(page.card == .none && page.primary == nil)
        #expect(page.title == "Checking this Mac" && page.note == "This takes a few seconds.")
    }

    /// The review found the card for a missing UTM opening with the team ID, notarization and a GitHub
    /// address before its button: one sentence naming the button now, the plan behind Show Details.
    @Test("No UTM: the row's mark, the title that says it once, one sentence naming the button, the plan under Details")
    func needsUTM() throws {
        let download = try page("needs-utm-download")
        #expect(download.rows[0] == .init(mark: .attention, title: "UTM"))
        #expect(download.title == "UTM isn't installed")
        let plan = try #require(Dependencies.windowPlan(for: .utm, state: .missing, brew: nil))
        guard case .needsUTM(let heading, let summary, let details) = download.card else {
            Issue.record("not the dependency card: \(download.card)")
            return
        }
        #expect(heading == download.title)
        #expect(summary.contains("**Download and Install UTM**"))
        #expect(details == DependencyCopy.plan(.utm, plan))
        #expect(LookAroundPage.details(download.card) == details)
        #expect(download.primary == .init(title: "Download and Install UTM", action: .run(.installUTM)))

        #expect(try page("needs-utm-homebrew").primary?.title == "Ask Homebrew to Install UTM")
        #expect(try page("needs-utm-update").primary?.title == "Ask Homebrew to Update UTM")
    }

    /// Finding from review: the update was offered whenever Homebrew was there, and `brew upgrade`
    /// refuses a UTM it didn't install. Offered only for Homebrew's own copy, with what it does to a
    /// running UTM and the prompt that can come with that; otherwise advice and Check Again.
    @Test("An update is Homebrew's only for a UTM Homebrew installed, and says what quitting UTM does")
    func update() throws {
        let update = try page("needs-utm-update")
        guard case .needsUTM(let heading, let summary, let details) = update.card else {
            Issue.record("not the dependency card: \(update.card)")
            return
        }
        #expect(heading == "UTM 4.5.4 is too old for Winbar" && summary.hasPrefix("Winbar needs UTM 4.6.0 or later."))
        // What quitting UTM does is said before the button, not only under Details.
        #expect(summary.contains("**Ask Homebrew to Update UTM**") && summary.contains("any VM in it stops"))
        #expect(details.first?.hasPrefix("Homebrew (\(F.brew)) installed this UTM") == true)
        #expect(details.last == SetupCopy.LookAround.updateMayAsk(host: "Winbar"))
        #expect(details.last?.contains("“Winbar” wants access to control “UTM”") == true)

        let byHand = try page("needs-utm-update-by-hand")
        guard case .needsUTM(let byHandHeading, let byHandSummary, let byHandDetails) = byHand.card else {
            Issue.record("not the dependency card: \(byHand.card)")
            return
        }
        #expect(byHandHeading == "UTM 4.5.4 is too old for Winbar" && byHandDetails.isEmpty)
        #expect(byHandSummary.contains("Check for Updates") && byHandSummary.hasSuffix(SetupCopy.LookAround.comeBack))
        // The window's words, not Terminal's: no brew command to type.
        #expect(!"\(String(describing: byHand.card))".contains("brew upgrade"))
        #expect(byHand.primary?.action == .run(.checkAgain(.lookAround)))
    }

    /// Winbar won't replace someone else's app, so there's nothing to install. The review found the
    /// fix only described ("Move that copy of UTM to the Trash"): the Finder is a button now, filled,
    /// and Check Again is beside it for after.
    @Test("A UTM that isn't UTM is a failure with Show in Finder, and no install button")
    func notUTM() throws {
        let page = try page("needs-utm-not-utm")
        #expect(page.rows[0].mark == .failed)
        guard case .needsUTM(let heading, let summary, let details) = page.card else {
            Issue.record("not the dependency card: \(page.card)")
            return
        }
        // Said once, as the title: the row is only its mark.
        #expect(page.rows[0].detail == nil)
        #expect(heading == "This isn't the UTM Winbar expects" && page.title == heading)
        #expect(details.joined().contains("ABCDE12345") && !summary.contains("ABCDE12345"))
        #expect(summary.contains("Winbar won't replace an app it didn't install") && summary.contains("**Show in Finder**"))
        #expect(page.primary == .init(title: "Show in Finder", action: .showUTMInFinder))
        #expect(page.secondary?.action == .run(.checkAgain(.lookAround)))
    }

    @Test("Installing: the row runs, the card keeps the output as it came, and there's nothing to press")
    func installing() throws {
        let page = try page("installing")
        #expect(marks(page) == [.running, .pending, .done])
        #expect(page.card == .installing(lines: F.homebrewLines, update: false, download: nil))
        // Homebrew replacing a copy that's too old says so.
        #expect(try self.page("updating").card == .installing(lines: F.updating.lines, update: true, download: nil))
        // Winbar's own download: the count is the bar's, not a line in the box.
        #expect(try self.page("installing-download").card == .installing(lines: [F.downloading.lines[0]], update: false,
                                                                          download: .init(done: 112, total: 250)))
        #expect(SetupCopy.LookAround.installing(update: true) == "Updating UTM")
        #expect(page.primary == nil && page.secondary == nil)
    }

    @Test("A failed install says why as its card's heading, keeps Homebrew's last words, and offers the install again")
    func installFailed() throws {
        let page = try page("install-failed")
        #expect(page.rows[0] == .init(mark: .failed, title: "UTM"))
        #expect(page.title == "Homebrew couldn't install UTM")
        guard case .installFailed(let problem, let lines, false) = page.card else {
            Issue.record("not the failure card: \(page.card)")
            return
        }
        #expect(problem.title == "Homebrew couldn't install UTM")
        #expect(lines.last?.hasPrefix("Error: Download failed") == true)
        #expect(page.primary == .init(title: "Try Again", action: .run(.installUTM)))
    }

    /// The review found UTM 4.7.5 found and still drawn at the pending circle, over "UTM 4.7.5".
    @Test("UTM installed and not asked yet: a tick with its version, the prediction, then Open UTM and Ask")
    func askUTM() throws {
        let page = try page("ask-utm")
        #expect(page.rows[0] == .init(mark: .done, title: "UTM", detail: "Installed · 4.7.5"))
        #expect(page.card == .askUTM(quarantined: false))
        #expect(page.primary == .init(title: "Open UTM and Ask", action: .run(.settleUTM)))
        // A copy with Homebrew's mark: the same button, and the card knows to predict Gatekeeper's question.
        let marked = try self.page("ask-utm-homebrew")
        #expect(marked.card == .askUTM(quarantined: true))
        #expect(marked.primary == page.primary)
    }

    @Test("Waiting on UTM's first answer: the row says what Winbar is doing, and there's nothing to press")
    func settling() throws {
        let page = try page("settling")
        #expect(page.rows[0] == .init(mark: .running, title: "UTM", detail: "Asking UTM a question…"))
        #expect(page.card == .settling(quarantined: false) && page.primary == nil)
        // A copy with the mark, just opened by Open UTM and Ask: the card knows the open question can come.
        #expect(try self.page("settling-homebrew").card == .settling(quarantined: true))
        // The runner's later lines become how long it has waited, read off UTMFirstUse's own words.
        var later = try #require(F.screens.first { $0.name == "settling" }?.state)
        later.inFlight = F.flight(.settleUTM, line: UTMFirstUse.stillWaiting(seconds: 40))
        #expect(LookAroundPage.page(later).rows[0].detail == "No answer yet after 40 seconds…")
    }

    @Test("A silent utmctl: the window's own advice, Try Again, and the settings page when macOS has an answer")
    func silent() throws {
        let page = try page("utm-silent")
        #expect(page.rows[0] == .init(mark: .attention, title: "UTM", detail: "No answer in 60 seconds"))
        #expect(page.card == .silent(consent: .wouldPrompt, quarantined: true))
        #expect(page.title == "UTM hasn't answered")
        #expect(page.primary == .init(title: "Try Again", action: .run(.settleUTM)))
        #expect(page.secondary == nil)
        // An answer on file: no prompt is coming, so the switch in System Settings is the way on, as
        // the filled button, and the page is titled for what's needed.
        let decided = try self.page("utm-silent-decided")
        #expect(decided.card == .silent(consent: .decided, quarantined: false))
        #expect(decided.title == "Winbar needs permission to control UTM")
        #expect(decided.primary == .init(title: "Open Automation Settings…", action: .openAutomationSettings))
        #expect(decided.secondary?.action == .run(.settleUTM))
    }

    /// Downgraded from a ship-blocker: Try Again was the filled button on a refusal nothing but the
    /// switch in System Settings can change.
    @Test("Automation refused: titled for the permission, the settings page filled, and Try Again beside it")
    func denied() throws {
        let page = try page("utm-denied")
        #expect(page.rows[0] == .init(mark: .attention, title: "UTM", detail: "Installed · 4.7.5"))
        #expect(page.card == .denied)
        #expect(page.title == "Winbar needs permission to control UTM")
        // The window's words, which end on what happens after rather than on a tccutil command.
        let text = String(SetupCopy.markdown(SetupCopy.LookAround.denied(host: "Winbar")).characters)
        #expect(text.hasPrefix("Choose Open Automation Settings…") && !text.contains("tccutil"))
        #expect(text.hasSuffix("Winbar checks again when you come back."))
        #expect(page.primary == .init(title: "Open Automation Settings…", action: .openAutomationSettings))
        #expect(page.secondary == .init(title: "Try Again", action: .run(.settleUTM)))
    }

    /// The review found "utmctl: … (error -600)" on the row and the fix described: UTM's error is under
    /// Details now, and the button is the fix, Open UTM, which opens it and asks again (`settleUTM`).
    @Test("utmctl's own error offers Open UTM with the error under Details; a VM list that failed offers another go")
    func failures() throws {
        let failed = try page("utm-failed")
        #expect(failed.rows[0].mark == .failed)
        #expect(failed.rows[0].detail == "Installed · 4.7.5")
        #expect(failed.title == "UTM isn't answering Winbar")
        #expect(LookAroundPage.details(failed.card) == ["UTM said: UTM is not running (error -600)"])
        #expect(!said(try #require(F.screens.first { $0.name == "utm-failed" }?.state)).contains("utmctl"))
        #expect(failed.primary == .init(title: "Open UTM", action: .run(.settleUTM)))

        let list = try page("list-failed")
        #expect(marks(list) == [.done, .failed, .done])
        #expect(list.rows[1].detail == nil)
        #expect(list.card == .listFailed(heading: "UTM didn't answer in time",
                                         detail: "It may be busy or showing a dialog. Nothing came back within 30 seconds."))
        #expect(failed.card == .utmFailed(detail: "UTM is not running (error -600)"))
        #expect(list.primary?.action == .run(.checkAgain(.lookAround)))
        #expect(list.secondary == nil)
    }

    /// The review found rows saying what the card under them said ("not installed; setup can download
    /// it…" over "UTM isn't installed…"; a failure's title only as a grey row detail). Now every card
    /// opens on a heading, and no row repeats it.
    @Test("Every card has a heading, and no row above it says the same")
    func saidOnce() {
        for (name, state) in F.screens where state.step == .lookAround {
            let page = LookAroundPage.page(state)
            guard page.card != .none else { continue }
            let heading = page.card.heading ?? ""
            #expect(!heading.isEmpty, "\(name)")
            for row in page.rows {
                #expect(!(row.detail ?? "").lowercased().contains(heading.lowercased()), "\(name): \(row.title)")
            }
        }
    }

    /// The control: the install-failed page as it was drawn, its failure's title on the row.
    @Test("The old failure page, its title on the row, fails that")
    func saidOnceControl() {
        let heading = SetupRunner.Problem(title: "Homebrew couldn't install UTM").title
        let oldRow = LookAroundPage.Row(mark: .failed, title: "UTM", detail: "Homebrew couldn't install UTM")
        #expect((oldRow.detail ?? "").lowercased().contains(heading.lowercased()))
    }

    /// The review asked for a headline on the finished page, and rows that don't say their name twice
    /// ("UTM / UTM 4.7.5").
    @Test("Done: the headline, three ticks with versions, how many VMs, and Continue; Windows App missing is left for step 5")
    func done() throws {
        let done = try page("done")
        #expect(done.title == "Everything Winbar needs is here")
        #expect(marks(done) == [.done, .done, .done])
        #expect(done.rows[0].detail == "Installed · 4.7.5" && done.rows[2].detail == "Installed · 11.4.1")
        #expect(done.rows[1].detail == "2 in UTM")
        // Named for the step it leads to, in the step bar's words, as every later step's Continue is.
        #expect(done.primary == .init(title: "Continue to the VM", action: .next))

        let noApp = try page("done-no-windows-app")
        // Not "everything": Windows App is still to come.
        #expect(noApp.title == "Everything Winbar needs for now is here")
        #expect(noApp.rows[1].detail == "None in UTM yet")
        #expect(noApp.rows[2] == .init(mark: .pending, title: "Windows App",
                                       detail: SetupCopy.LookAround.windowsAppLater(lastBuilt: SetupWindowState.lastBuilt)))
        #expect(noApp.primary?.action == .next)
    }

    /// The review found the row promising "Winbar gets to that at the saved-PC step" in a build that
    /// stops after looking around. The row says so only once the window has that step, and until then
    /// names what really installs Windows App: winbar setup (Setup.run offers C1).
    @Test("Windows App's row names the saved-PC step only in a window that has it")
    func windowsAppLater() throws {
        for lastBuilt in WizardStep.allCases {
            let noApp = LookAroundPage.page(try #require(SetupFixtures.screens.first { $0.name == "done-no-windows-app" }).state,
                                            lastBuilt: lastBuilt)
            let detail = try #require(noApp.rows[2].detail)
            #expect(detail == SetupCopy.LookAround.windowsAppLater(lastBuilt: lastBuilt))
            #expect(detail.contains("saved-PC step") == (lastBuilt >= .savedPC), "\(lastBuilt)")
            #expect(detail.hasPrefix("Not installed yet."), "\(lastBuilt)")
        }
        // This build: no step it doesn't have, and the way it's really done.
        let now = SetupCopy.LookAround.windowsAppLater(lastBuilt: SetupWindowState.lastBuilt)
        #expect(now == "Not installed yet. Winbar gets to it at the saved-PC step.")
        #expect(SetupCopy.LookAround.windowsAppLater(lastBuilt: .finish)
                == "Not installed yet. Winbar gets to it at the saved-PC step.")
    }

    /// The control: the row as it was, one sentence for every build, names the saved-PC step in this one.
    @Test("The row as it was names a step this build doesn't have, and fails that")
    func windowsAppLaterControl() {
        let old = "Windows App isn't installed. Winbar gets to that at the saved-PC step."
        #expect(old.contains("saved-PC step") && !SetupCopy.LookAround.windowsAppLater(lastBuilt: .lookAround).contains("saved-PC step"))
    }

    /// The runner refuses a second press while one is in flight; the window doesn't offer one. And a
    /// greyed-out button needs something moving beside it: the review found Check Again's read on the
    /// install question with the button grey, the UTM row still at "!", and nothing spinning.
    @Test("While a read runs, whatever is offered is greyed out, and the row it can change spins")
    func busy() {
        for (name, state) in F.screens where state.step == .lookAround {
            var busy = state
            busy.inFlight = F.flight(.checkAgain(.lookAround))
            let page = LookAroundPage.page(busy)
            // Only the buttons that open another app's window stay: they touch nothing the read reads.
            let elsewhere: [LookAroundPage.Action] = [.openAutomationSettings, .showUTMInFinder]
            #expect(page.primary?.enabled != true || elsewhere.contains(page.primary!.action), "\(name)")
            #expect(page.secondary?.enabled != true || elsewhere.contains(page.secondary!.action), "\(name)")
            let open = page.rows.prefix(2).contains { $0.mark != .done }
            #expect(!open || page.rows.contains { $0.mark == .running }, "\(name)")
            // Only the first row that can change, and never the Windows App row.
            #expect(page.rows.filter { $0.mark == .running }.count <= 1, "\(name)")
            #expect(page.rows[2].mark != .running, "\(name)")
        }
        let rereading = LookAroundPage.page(F.state(facts: F.facts(utm: .missing), inFlight: F.flight(.checkAgain(.lookAround))))
        #expect(rereading.rows.map(\.mark) == [.running, .pending, .done])
    }
}

// MARK: - Armie

@Suite("On step 1 Armie appears only while UTM installs, and says only his line for it")
struct SetupArmieTests {
    @Test("He is there for the install in flight on step 1, and nowhere else in steps 0 and 1")
    func onlyTheInstall() {
        // "refused" is the install too, with a press turned down beside it: the install is still
        // nothing to do but wait, and the refusal is about the press, not about the install.
        for (name, state) in F.screens {
            let expected = ["installing", "installing-download", "refused"].contains(name)
                ? SetupCopy.Armie.line(.installingUTM) : nil
            #expect(LookAroundPage.armieLine(state) == expected, "\(name)")
        }
    }

    /// §2b: never on an error, never on a permission, never on the welcome. Held against every card
    /// that is any of those, rather than against the fixtures' names.
    @Test("Never beside a failure, a permission prompt or a decision")
    func neverBesideTrouble() {
        for (name, state) in F.screens where LookAroundPage.armieLine(state) != nil {
            let card = LookAroundPage.page(state).card
            switch card {
            case .installing: break
            default: Issue.record("Armie beside \(card) in \(name)")
            }
        }
        // Even with an install running, not on the welcome (a person who went Back to read it).
        var welcome = F.installing
        welcome.step = .welcome
        #expect(LookAroundPage.armieLine(welcome) == nil)
    }

    @Test("Hide Armie takes him away for good")
    func hidden() {
        var state = F.installing
        state.armieHidden = true
        #expect(LookAroundPage.armieLine(state) == nil)
    }

    /// His line stays up for the whole install, so it may name no stage of it: the review saw
    /// "Fetching UTM…" beside Homebrew's "Moving App" and "Linking Binary" and the signature check.
    @Test("His UTM line is deadpan, and true of every stage of both ways UTM is installed")
    func line() {
        let line = SetupCopy.Armie.line(.installingUTM)
        #expect(!line.contains("!") && !line.contains("?"))
        // "Installing UTM" is the progress line above him; he says the one thing it doesn't.
        #expect(!line.hasPrefix("Installing UTM") && line.contains("checks this is the real UTM"))
        #expect(SetupCopy.Armie.Moment.all.contains(.installingUTM))
        // No stage's verb, and neither route's name: Homebrew's install and Winbar's download both end in
        // the same check, and a line naming one would be untrue half the time.
        for stage in ["fetch", "download", "copy", "moving", "linking", "homebrew"] {
            #expect(!line.lowercased().contains(stage), "\(stage)")
        }
    }

    @Test("The working clip repeats; completion is a one-shot")
    func playbackMatchesTheMoment() {
        let working = URL(fileURLWithPath: "/invalid/armie-working.mov")
        let done = URL(fileURLWithPath: "/invalid/armie-done.mov")
        let art = ArmieArt(still: NSImage(size: NSSize(width: 2, height: 2)), working: working, done: done)
        #expect(art.playback(for: working) == .repeating)
        #expect(art.playback(for: done) == .once)
    }

    @Test("Reduce Motion suppresses both clips, including the celebration")
    func bothClipsRespectReduceMotion() {
        for name in ["armie-working", "armie-done"] {
            let url = URL(fileURLWithPath: "/invalid/\(name).mov")
            #expect(ArmieArt.drawing(loop: url, reduceMotion: true) == .still)
        }
        #expect(ArmieArt.drawing(loop: nil, reduceMotion: false) == .still)
    }

    /// The control: the line he had fails on its first word.
    @Test("His old line names a stage, and fails that")
    func lineControl() {
        #expect("Fetching UTM, the app Windows is going to live in.".lowercased().contains("fetch"))
    }

    /// Homebrew quits a running UTM to update it, with an Apple Event that can raise the Automation
    /// prompt right then: a possible permission, where he doesn't stand.
    @Test("He isn't there while Homebrew updates UTM")
    func notDuringAnUpdate() {
        #expect(LookAroundPage.armieLine(F.updating) == nil)
        #expect(LookAroundPage.armieLine(F.installing) != nil)
    }
}

// MARK: - Opening, closing, quitting

@Suite("When the window opens by itself, and what closing and quitting mean")
struct SetupWindowLifecycleTests {
    /// The rule as wizard commit 11 will ship it, with the window offered to everyone.
    @Test("Offered, it opens by itself only on a new Mac, with nothing running and no other window asked for")
    func opensByItself() {
        func opens(available: Bool = true, shown: Bool = false, vmChosen: Bool = false, installRunning: Bool = false,
                   askedForWindow: Bool = false) -> Bool {
            SetupWindowController.opensByItself(available: available, shown: shown, vmChosen: vmChosen,
                                                installRunning: installRunning, askedForWindow: askedForWindow)
        }
        #expect(opens())
        #expect(!opens(shown: true))
        #expect(!opens(vmChosen: true))
        #expect(!opens(installRunning: true))
        #expect(!opens(askedForWindow: true))
        // Not offered, it never opens by itself, however new the Mac.
        #expect(!opens(available: false))
    }

    /// 0.2.0: the window is offered to everyone, so a new Mac's first run opens it. Turning the switch
    /// back off fails this.
    @Test("In this build, a new Mac's first run opens the window")
    func firstRunInThisBuild() {
        #expect(SetupWindow.availableToEveryone)
        #expect(SetupWindowController.opensByItself(shown: false, vmChosen: false, installRunning: false,
                                                    askedForWindow: false))
        #expect(SetupCopy.HandOff.opened(lastBuilt: SetupWindowState.lastBuilt).contains("carries on there"))
    }

    /// Turning the window on resets no setting. A Mac that already put the welcome away — **Not Now**
    /// in a `winbar setup --window` session before 0.2.0, or closing a welcome nobody started — keeps
    /// `setupWizardShown`, so the update doesn't greet it, and it finds the window where everyone
    /// does: the menu. Neither is a Mac with a VM chosen greeted. The menu half goes through
    /// `MenuState.offersSetUp(available:coordinating:wizardShown:)`, the expression the live menu is
    /// built with, with the setting both ways.
    @Test("A Mac that put the welcome away isn't greeted again, and still has Set Up Winbar… in the menu")
    func dismissedBefore() {
        #expect(!SetupWindowController.opensByItself(shown: true, vmChosen: false, installRunning: false,
                                                     askedForWindow: false))
        #expect(!SetupWindowController.opensByItself(shown: false, vmChosen: true, installRunning: false,
                                                     askedForWindow: false))
        for shown in [true, false] {
            let offered = MenuState.offersSetUp(available: SetupWindow.availableToEveryone, coordinating: false,
                                                wizardShown: shown)
            #expect(offered, "shown: \(shown)")
            for vm in [nil, "winlab03"] as [String?] {
                let items = MenuShape.items(MenuState(status: MenuStatus(vmName: vm), offersSetUp: offered))
                #expect(items.contains(.action(SetupCopy.menuItem, .setUpWinbar)), "\(vm ?? "no VM"), shown: \(shown)")
            }
        }
        // A `--window` session brings it back even in a build that doesn't offer it to everyone.
        #expect(MenuState.offersSetUp(available: false, coordinating: true, wizardShown: true))
        #expect(!MenuState.offersSetUp(available: false, coordinating: false, wizardShown: false))
    }

    /// The copy that sends someone away and back — the finish step's refusal to go headless, the
    /// console hint on the connection's recovery card — names **Set Up Winbar…** in the menu, which is
    /// only true while the menu offers it.
    @Test("The copy that says to come back to the window names Set Up Winbar…, and the menu has it")
    func reopenCopy() {
        #expect(SetupWindow.availableToEveryone)
        for text in [SetupCopy.Finish.notOffering, SetupCopy.Connecting.recoverConsole, SetupCopy.Connecting.recoverEither] {
            #expect(String(SetupCopy.markdown(text).characters).contains(SetupCopy.menuItem), "\(text)")
        }
    }

    /// Global, and Winbar's own, so a diagnostic report says whether the window was put away and
    /// whether Armie was hidden — the two things a person might ask about when it "never appears".
    @Test("The window's two settings belong to this copy of Winbar, and a report shows them")
    func settings() {
        for key in [Config.Key.setupWizardShown, Config.Key.armieHidden] {
            #expect(Config.Key.all.contains(key))
            #expect(!Config.Key.perVM.contains(key))
            #expect(Diagnose.winbarKeys([key, "NSGlobalDomainThing"]) == [key])
        }
    }

    @Test("Closing a welcome nobody started is Not Now; closing after Start keeps the place")
    func closing() {
        #expect(SetupWindowController.dismissesOnClose(F.state(.welcome)))
        var afterBack = F.state(.welcome)
        afterBack.answers.started = true
        #expect(!SetupWindowController.dismissesOnClose(afterBack))
        #expect(!SetupWindowController.dismissesOnClose(F.installing))
        // Past the last step this build has, the window has done what it can: closing puts it away.
        #expect(!SetupWindowController.dismissesOnClose(F.state(.vm)))
        #expect(!SetupWindowController.dismissesOnClose(F.state(.tune)))
    }

    @Test("Quitting asks first while UTM installs, and not while waiting on a prompt or reading")
    func quitting() throws {
        let question = try #require(SetupWindowController.quitQuestion(F.flight(.installUTM)))
        #expect(String(question.characters) == "Winbar is in the middle of installing UTM. If you quit now, Winbar leaves "
                    + "that unfinished.")
        #expect(SetupWindowController.quitQuestion(F.flight(.settleUTM)) == nil)
        #expect(SetupWindowController.quitQuestion(F.flight(.checkAgain(.lookAround))) == nil)
        #expect(SetupWindowController.quitQuestion(nil) == nil)
    }
}

// MARK: - What this build promises

/// The window stops after step 1 in this build, and the first run opens it for every new Mac. So the
/// welcome and the placeholder after step 1 must say what is true of this build, and the placeholder
/// must lead somewhere.
@Suite("The window promises what this build does, and never ends in a dead end")
struct SetupWindowPromiseTests {
    private func plain(_ text: String) -> String { String(SetupCopy.markdown(text).characters) }

    @Test("Partial builds have a partial promise; the finished window, offered to everyone, promises the whole")
    func welcome() {
        #expect(SetupWindowState.lastBuilt == .finish)
        #expect(SetupWindow.availableToEveryone)
        let shipped = SetupCopy.Welcome.body(lastBuilt: SetupWindowState.lastBuilt).map(plain).joined(separator: " ")
        #expect(shipped.contains("does the whole thing") && shipped.contains("You don't need Terminal"))
        let now = SetupCopy.Welcome.body(lastBuilt: .vm).map(plain).joined(separator: " ")
        #expect(!now.contains("does the whole thing") && !now.contains("You don't need Terminal"))
        #expect(now.contains("makes a Windows VM or uses one you already have") && now.contains("installs UTM if it's missing"))
        #expect(now.contains("then stops and says what does the rest."))
        #expect(!Self.promisesSetupDoesTheRest(now))
        // Automation on every route, and Gatekeeper's question for any copy with the mark that hasn't been
        // opened yet — a browser's download as much as Homebrew's; a Mac that already answered both sees neither.
        #expect(!now.contains("four") && now.contains("macOS may ask a question or two here"))
        #expect(now.contains("whether Winbar may control UTM"))
        #expect(now.contains("if UTM hasn't been opened since it was downloaded, whether to open it"))
        #expect(!now.contains("if Homebrew installed UTM"))
        #expect(now.contains("\(Dependency.utmDownloadMB) MB"))
    }

    /// `winbar setup` stops on a Mac with no Windows VM and never makes one, so no welcome may hand it
    /// "the rest": the first-run audience is exactly the Mac with no VM.
    private static func promisesSetupDoesTheRest(_ text: String) -> Bool {
        text.contains("winbar setup") && text.contains("does the rest")
    }

    /// The spec's welcome is what the finished window says, and the welcome this build had said
    /// `winbar setup` does the rest; they're the controls for the test above.
    @Test("The spec's welcome, and the one that handed the rest to winbar setup, would fail that")
    func welcomeControl() {
        let whole = SetupCopy.Welcome.body(lastBuilt: .finish).map(plain).joined(separator: " ")
        #expect(whole.contains("You don't need Terminal") && whole.contains("Winbar tells you what each question is"))
        let before = plain("For now this window checks what's here and installs UTM if it's missing; **winbar setup** in "
                           + "Terminal does the rest.")
        #expect(Self.promisesSetupDoesTheRest(before))
    }

    /// `winbar setup` with no Windows VM stops (Setup.chooseVM: "UTM has no Windows VMs…") and never
    /// makes one, so "winbar setup does all of them" was untrue for the first run's own audience.
    @Test("The placeholder after the VM names what tunes it and what connects")
    func placeholder() {
        let text = plain(SetupCopy.notBuiltYet)
        #expect(text.contains("goes as far as the VM"))
        #expect(text.contains("winbar setup in Terminal tunes it") && text.contains("Connect in Winbar's menu opens it"))
        #expect(!text.contains("does all of them"))
    }

}

// MARK: - The copy step 1 had wrong

@Suite("Step 1 says only what is true for everyone who lands on it")
struct LookAroundCopyTests {
    /// WAVE3-BRIEF: someone who allowed Automation long ago and whose UTM is closed lands on
    /// **Open UTM and Ask** too — a snapshot doesn't ask a closed UTM anything, and with UTM closed
    /// macOS can't say — so the prompt is predicted as something that happens the first time.
    @Test("The prediction doesn't promise a prompt to someone who already allowed it")
    func returningUser() {
        let parts = [SetupCopy.LookAround.askHeading, SetupCopy.LookAround.askBody,
                     SetupCopy.LookAround.askInstruction(host: "Winbar"), SetupCopy.LookAround.askAside()]
        let text = parts.map { String(SetupCopy.markdown($0).characters) }.joined(separator: " ")
        #expect(!text.contains("macOS will ask") && !text.contains("macOS asks with"))
        #expect(String(SetupCopy.markdown(SetupCopy.LookAround.askInstruction(host: "Winbar")).characters)
                == "If macOS asks whether Winbar may control UTM, choose Allow.")
        #expect(text.contains("It asks only the first time") && text.contains("If you've allowed it before, UTM just answers."))
    }

    /// A UTM from Homebrew keeps its "downloaded from the internet" mark, and **Open UTM and Ask**
    /// opens it with `UTM.open()`, so its first launch can ask whether to open it — before the
    /// Automation question. The welcome says macOS may ask "a question or two" and that Winbar says
    /// each before it appears; for a marked copy, the card is where the second is said.
    @Test("For a UTM with Homebrew's mark, the card predicts macOS's open question before the Automation one")
    func quarantinedAsk() throws {
        let marked = String(SetupCopy.markdown(SetupCopy.LookAround.askInstruction(host: "Winbar", quarantined: true)).characters)
        #expect(marked == "If macOS asks whether to open UTM, an app downloaded from the internet, choose Open. "
                + "If it asks whether Winbar may control UTM, choose Allow.")
        let open = try #require(marked.range(of: "choose Open")), allow = try #require(marked.range(of: "choose Allow"))
        #expect(open.lowerBound < allow.lowerBound)
        // An update is Homebrew's too: it quits UTM and opens the new, marked copy, so both are said there.
        let update = SetupCopy.LookAround.updateMayAsk(host: "Winbar")
        #expect(update.contains("choose Allow") && update.contains("choose Open"))
    }

    /// The update's plan predicted two of macOS's questions, and Homebrew's source says there can be a
    /// third: before `brew upgrade` moves the old UTM.app aside it writes a file into the bundle so that
    /// macOS asks for App Management (cask/quarantine.rb, called from cask/artifact/moved.rb), in the
    /// name of whoever started brew — Winbar. Read in the source, not seen live, so it's a "may"; and
    /// if it isn't allowed, Homebrew deletes the old copy and installs the new one in its place.
    @Test("An update predicts macOS's App Management question too, in the order Homebrew raises them")
    func updateAppManagement() throws {
        let update = SetupCopy.LookAround.updateMayAsk(host: "Winbar")
        let control = try #require(update.range(of: "wants access to control")),
            modify = try #require(update.range(of: "“Winbar” would like to modify apps on your Mac")),
            open = try #require(update.range(of: "choose Open"))
        // Homebrew quits UTM, then replaces it, then opens the new copy.
        #expect(control.lowerBound < modify.lowerBound && modify.lowerBound < open.lowerBound)
        #expect(update.contains("whether Winbar may modify apps"))
        #expect(update.contains("If it isn't allowed, Homebrew deletes the old copy and installs the new one in its place "
                                + "instead."))
        // Only the update's plan says it: no other screen, and no route where Homebrew doesn't replace UTM.
        for (name, state) in F.screens where state.step == .lookAround {
            #expect(said(state).contains("modify apps") == (name == "needs-utm-update"), "\(name)")
        }
        // And the welcome leaves room for it: it neither counts macOS's questions nor lists them, and
        // promises each is said before it appears.
        let welcome = SetupCopy.Welcome.body(lastBuilt: SetupWindowState.lastBuilt)
            .map { String(SetupCopy.markdown($0).characters) }.joined(separator: " ")
        #expect(welcome.contains("macOS may ask your permission a few times") && welcome.contains("before it appears"))
        #expect(!welcome.contains("up to four") && !welcome.contains("Accessibility"))
    }

    /// **Open UTM and Ask** opens UTM itself, so for a copy with the mark, macOS's open question can land
    /// while the window waits — and the waiting card named only the Automation prompt. It names both
    /// for a marked copy, the open question first, as macOS asks them; for an unmarked one, only the one.
    @Test("While Winbar waits for UTM, a marked copy's card says to choose Open too, first")
    func settlingMarked() throws {
        let screens = Dictionary(uniqueKeysWithValues: F.screens.map { ($0.name, $0.state) })
        let marked = said(try #require(screens["settling-homebrew"]))
        let open = try #require(marked.range(of: "If macOS asks whether to open UTM, an app downloaded from the internet, "
                                                  + "choose Open there.")),
            allow = try #require(marked.range(of: "choose Allow there"))
        #expect(open.lowerBound < allow.lowerBound)
        let unmarked = said(try #require(screens["settling"]))
        #expect(!unmarked.contains("whether to open UTM") && unmarked.contains("choose Allow there"))
    }

    /// For a marked copy the card's emphasis names two questions, and the aside under it went on in the
    /// singular ("It asks only the first time. Its prompt can open behind this window…"), as if there
    /// were one. With two, it speaks of both; with one, it's as it was.
    @Test("The ask card's aside speaks of both questions when it has predicted two")
    func askAsidePlural() throws {
        let screens = Dictionary(uniqueKeysWithValues: F.screens.map { ($0.name, $0.state) })
        for name in ["ask-utm-homebrew", "ask-utm-downloaded"] {
            let marked = said(try #require(screens[name]))
            #expect(marked.contains("macOS asks each only once. Its prompts can open behind this window, and they wait as "
                                    + "long as it takes, so a Mac left locked never gets past them."), "\(name)")
            #expect(marked.contains("If you've answered both before, UTM just answers."), "\(name)")
            #expect(!marked.contains("It asks only the first time"), "\(name)")
        }
        let unmarked = said(try #require(screens["ask-utm"]))
        #expect(unmarked.contains("It asks only the first time. Its prompt can open behind this window"))
    }

    /// The control: the prediction as it was, the one an unmarked copy still gets, says nothing about
    /// the open question.
    @Test("The unmarked prediction, the only one there was, doesn't mention it")
    func quarantinedAskControl() {
        let unmarked = String(SetupCopy.markdown(SetupCopy.LookAround.askInstruction(host: "Winbar")).characters)
        #expect(!unmarked.contains("Open") && !unmarked.contains("downloaded"))
    }

    /// The review found a Mac with no Homebrew told its UTM carried the mark "as Homebrew leaves it":
    /// the silent card's aside shows on the mark alone, and a UTM downloaded with a browser — the
    /// commonest way to get it — carries the same mark. On a Mac with no Homebrew, the one thing any
    /// step-1 screen may say about Homebrew is that it isn't there (the download plan's first words).
    @Test("A Mac with no Homebrew is never told Homebrew did anything")
    func noHomebrewNamed() {
        var checked: Set<String> = []
        for (name, state) in F.screens where state.step == .lookAround {
            guard let facts = state.facts, facts.homebrew == nil, !facts.utmFromHomebrew else { continue }
            let text = said(state).replacingOccurrences(of: "Homebrew isn't on this Mac", with: "")
            #expect(!text.contains("Homebrew"), "\(name): \(text)")
            checked.insert(name)
        }
        // Among them, the two that mention the mark: a browser's UTM before it's asked, and the silent card.
        #expect(checked.isSuperset(of: ["ask-utm-downloaded", "utm-silent", "needs-utm-download"]))
    }

    /// The window opens UTM itself, so macOS's open question for a marked copy can be the thing left
    /// waiting behind another window while utmctl says nothing. The terminal can rule the mark out
    /// (the person opens UTM in front of them); the window can't, and says where to look instead.
    @Test("The silent card's word on the mark doesn't rule it out, and says what to press")
    func quarantineAside() {
        let aside = String(SetupCopy.markdown(SetupCopy.LookAround.quarantineAside).characters)
        #expect(!aside.contains("isn't what"))
        #expect(aside.contains("behind another window") && aside.contains("choose Open"))
        // The control: the aside it replaces ruled the mark out.
        #expect("That's normal, and it isn't what the command-line tool is waiting for.".contains("isn't what"))
    }

    /// After **Open UTM and Ask**, the same person waits while UTM launches and answers, and no prompt
    /// comes for them. What the row, the card and a refused press say while that runs has to be true
    /// both for them and for a Mac seeing the prompt for the first time.
    @Test("While UTM is asked, nothing says a prompt is coming")
    func returningUserWaits() throws {
        let state = F.state(facts: F.facts(utm: F.installed), inFlight: F.flight(.settleUTM, line: UTMFirstUse.waiting))
        let page = LookAroundPage.page(state)
        #expect(page.card == .settling(quarantined: false))
        let row = try #require(page.rows[0].detail)
        let card = String(SetupCopy.markdown(SetupCopy.Working.waiting(.automationPrompt, host: "Winbar")).characters)
        let refused = String(SetupCopy.Working.refusal(F.flight(.settleUTM), host: "Winbar").characters)
        for text in [row, card, refused] {
            #expect(!text.contains("macOS asks with") && !text.contains("permission prompt appears")
                    && !text.contains("macOS will ask"), "\(text)")
        }
        #expect(card == "Waiting for UTM to answer. If macOS asks whether Winbar may control UTM (its prompt says "
                + "“Winbar” wants access to control “UTM”, and it can open behind other windows), choose Allow there.")
        #expect(refused.hasSuffix("If macOS asks whether Winbar may control UTM (its prompt says “Winbar” wants access "
                                  + "to control “UTM”, and it can open behind other windows), choose Allow there."))
    }

    /// The prompt's first line as TCC.framework's Localizable.loctable has it
    /// (REQUEST_ACCESS_SERVICE_kTCCServiceAppleEvents), with the host and UTM put in.
    @Test("Every sentence that quotes macOS's Automation prompt quotes it as it reads")
    func promptQuotedExactly() {
        #expect(Automation.promptWords(host: "Winbar") == String(format: "“%@” wants access to control “%@”", "Winbar", "UTM"))
        var quoting = [UTMFirstUse.expectAPrompt, SetupCopy.Working.waiting(.automationPrompt, host: "Winbar"),
                       String(SetupCopy.Working.refusal(F.flight(.settleUTM), host: "Winbar").characters)]
        for consent in [Automation.Consent.wouldPrompt, .unknown, .decided] {
            quoting.append(UTMFirstUse.how(consent: consent, quarantined: false, host: "Winbar", bundleID: nil))
        }
        for text in quoting {
            #expect(!text.contains("wants to control"), "\(text)")
            #expect(text.contains("wants access to control “UTM”"), "\(text)")
        }
    }

    /// The spec's sentence, which the test above exists to keep out. It fails it.
    @Test("The spec's version fails that test")
    func control() {
        let spec = "UTM is installed. Winbar will open it now and ask it a question, and macOS will ask whether Winbar "
            + "may control UTM. Choose **Allow** — that's how Winbar starts, stops and reconfigures the VM."
        #expect(String(SetupCopy.markdown(spec).characters).contains("macOS will ask"))
    }

    @Test("Each install button is the plan's own verb, and there is none for a plan the window can't carry out")
    func installButtons() {
        #expect(SetupCopy.LookAround.bInstall(.utm, .brew(brew: F.brew, cask: "utm")) == "Ask Homebrew to Install UTM")
        #expect(SetupCopy.LookAround.bInstall(.utm, .brewUpgrade(brew: F.brew, cask: "utm")) == "Ask Homebrew to Update UTM")
        #expect(SetupCopy.LookAround.bInstall(.utm, .download(url: "https://example.invalid/UTM.dmg"))
                == "Download and Install UTM")
        #expect(SetupCopy.LookAround.bInstall(.utm, .manual("x")) == nil)
        #expect(SetupCopy.LookAround.bInstall(.windowsApp, .appStore(id: "1")) == nil)
    }
}

// MARK: - The controller, against a runner that reaches nothing

/// A machine that answers every read with `mac` and does nothing for any work.
private final class QuietMachine: SetupMachine {
    private let lock = NSLock()
    private var _reads: [WizardStep] = []
    var mac = SetupRunner.Readings()

    var reads: [WizardStep] {
        lock.lock()
        defer { lock.unlock() }
        return _reads
    }

    func readings(through step: WizardStep, answers: SetupFlow.Answers, after work: SetupRunner.Work?,
                  job: SetupRunner.Job?) -> SetupRunner.Readings {
        lock.lock()
        _reads.append(step)
        lock.unlock()
        return mac
    }

    func perform(_ work: SetupRunner.Work, password: String?, facts: SetupFlow.Facts, job: SetupRunner.Job) throws {}
}

/// A machine whose UTM install waits at a gate and then fails, so a test can close the window while
/// it runs and let it end unseen.
private final class GatedFailingInstall: SetupMachine {
    let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var _reached = false
    /// The install has started and is waiting at the gate.
    var reached: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _reached
    }

    func readings(through step: WizardStep, answers: SetupFlow.Answers, after work: SetupRunner.Work?,
                  job: SetupRunner.Job?) -> SetupRunner.Readings {
        var mac = SetupRunner.Readings()
        mac.utm = .missing
        return mac
    }

    /// Said before the gate, while the window is open to hear it, and after it, while it's closed.
    static let before = "Downloading UTM from github.com…"
    static let after = "The download stopped: the server answered 503."

    func perform(_ work: SetupRunner.Work, password: String?, facts: SetupFlow.Facts, job: SetupRunner.Job) throws {
        guard work == .installUTM else { return }
        job.say(Self.before)
        lock.lock()
        _reached = true
        lock.unlock()
        gate.wait()
        job.say(Self.after)
        throw WinbarError("Couldn't download UTM.dmg", "the server answered 503")
    }
}

/// The two settings, in memory.
private final class MemorySettings {
    var shown = false
    var armieHidden = false
    var settings: SetupSettings {
        SetupSettings(wizardShown: { self.shown }, markShown: { self.shown = true },
                      armieHidden: { self.armieHidden }, hideArmie: { self.armieHidden = true })
    }
}

@MainActor
private func runner(_ machine: SetupMachine) -> SetupRunner {
    SetupRunner(machine: machine, environment: SetupRunner.Environment(
        queue: DispatchQueue(label: "winbar.test.setup-window"), callbacks: .main, clock: Date.init,
        keepAwake: { _ in {} }, processes: { _ in ([], nil) }, workspace: NotificationCenter()))
}

@Suite("The window's controller keeps its promises")
@MainActor
struct SetupWindowControllerTests {
    @Test("Not Now puts the window away for good")
    func notNow() {
        let memory = MemorySettings()
        let controller = SetupWindowController(art: nil, settings: memory.settings, makeRunner: { runner(QuietMachine()) })
        #expect(!memory.shown)
        controller.send(.notNow)
        #expect(memory.shown)
    }

    @Test("Closing the welcome before Start counts as Not Now; closing after it doesn't")
    func closing() {
        let memory = MemorySettings()
        let machine = QuietMachine()
        let controller = SetupWindowController(art: nil, settings: memory.settings, makeRunner: { runner(machine) })
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        #expect(memory.shown)

        let later = MemorySettings()
        let started = SetupWindowController(art: nil, settings: later.settings, makeRunner: { runner(machine) })
        started.send(.start)
        started.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        #expect(!later.shown)
    }

    @Test("Hide Armie is remembered, and a remembered one keeps him hidden next time")
    func hideArmie() {
        let memory = MemorySettings()
        let controller = SetupWindowController(art: nil, settings: memory.settings, makeRunner: { runner(QuietMachine()) })
        #expect(!controller.state.armieHidden)
        controller.send(.hideArmie)
        #expect(memory.armieHidden && controller.state.armieHidden)
        let next = SetupWindowController(art: nil, settings: memory.settings, makeRunner: { runner(QuietMachine()) })
        #expect(next.state.armieHidden)
    }

    /// Start is the first thing that reads the Mac (§2: the welcome touches nothing), and it reads
    /// step 1 and no further: the rows arrive as the answers do.
    @Test("Start moves to step 1 and reads it, and the answer lands in the window")
    func start() async throws {
        let machine = QuietMachine()
        machine.mac.utm = .missing
        let controller = SetupWindowController(art: nil, settings: MemorySettings().settings, makeRunner: { runner(machine) })
        #expect(machine.reads.isEmpty)
        controller.send(.start)
        #expect(controller.state.step == .lookAround)
        #expect(controller.state.answers.started)
        for _ in 0..<200 where controller.state.facts == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(machine.reads == [.lookAround])
        #expect(controller.state.facts?.utm == .missing)
        #expect(controller.state.step == .lookAround)
        #expect(LookAroundPage.page(controller.state).primary?.action == .run(.installUTM))
    }

    /// The scenario the review found by hand, through the controller: install, close, the install
    /// fails unseen, reopen exactly as `show()` does. Before the ending came with the attach, the
    /// page offered the install again as though nothing had happened.
    @Test("Closed while UTM installs and reopened after it failed, the window shows the failure")
    func reopenAfterUnseenFailure() async throws {
        let machine = GatedFailingInstall()
        let made = runner(machine)
        let controller = SetupWindowController(art: nil, settings: MemorySettings().settings, makeRunner: { made })
        controller.send(.start)
        for _ in 0..<200 where controller.state.facts == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(LookAroundPage.page(controller.state).primary?.action == .run(.installUTM))

        controller.send(.perform(.run(.installUTM)))
        for _ in 0..<500 where !machine.reached { try await Task.sleep(for: .milliseconds(10)) }
        #expect(machine.reached)
        for _ in 0..<200 where controller.state.inFlight == nil { try await Task.sleep(for: .milliseconds(10)) }
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        machine.gate.signal()
        for _ in 0..<500 where made.lastEnded == nil { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(50))
        // Closed: the window heard nothing of the ending. The one it holds is Start's read.
        #expect(controller.state.lastEnding?.work == .checkAgain(.lookAround))

        controller.attach()
        guard case .installFailed(let problem, let lines, _) = LookAroundPage.page(controller.state).card else {
            Issue.record("reopened on \(LookAroundPage.page(controller.state).card), not the failure")
            return
        }
        #expect(problem.title == "Couldn't download UTM.dmg")
        // What it said while the window was closed is there too, above the failure it explains.
        #expect(lines == [GatedFailingInstall.before, GatedFailingInstall.after])
        #expect(LookAroundPage.page(controller.state).primary == .init(title: "Try Again", action: .run(.installUTM)))
    }

    @Test("Install Windows… embeds the existing create controller; it doesn't open a second window")
    func placeholderButtons() {
        let memory = MemorySettings()
        let creator = FakeEmbeddedCreate()
        let controller = SetupWindowController(state: F.state(.vm, facts: F.facts(utm: F.installed, answers: .answered,
                                                                                vms: .listed([]))),
                                               art: nil, settings: memory.settings, makeRunner: { runner(QuietMachine()) },
                                               makeCreator: { creator })
        controller.send(.newWindowsVM)
        #expect(creator.isEmbedded && controller.state.creating && !memory.shown)
        controller.send(.newWindowsVM)
        #expect(creator.embeds == 1)
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        #expect(creator.closes == 1 && !creator.isEmbedded && !controller.state.creating)
        controller.send(.closeForNow)
        #expect(memory.shown)
    }

    /// The person has moved on from a refused press once they press anything else, which says its own
    /// refusal if it is refused too. Ticking a VM or hiding Armie answers nothing it said.
    @Test("Pressing anything but a VM's row or Armie's ✕ puts the refusal away")
    func pressClearsRefusal() {
        var state = CertificateFixtures.state("initial")
        state.refusal = SetupRunner.Refusal(wanted: .trustCertificate, inFlight: F.flight(.checkAgain(.certificate)))
        let controller = SetupWindowController(state: state, art: nil, settings: MemorySettings().settings,
                                               makeRunner: { runner(QuietMachine()) })
        controller.send(.pickVM("5A1E0C3D-0000-4000-8000-00000000000D"))
        controller.send(.hideArmie)
        #expect(controller.state.refusal == state.refusal)
        controller.send(.skip("H7"))
        #expect(controller.state.refusal == nil)
    }

    /// Showing the New Windows VM form starts nothing, and its own Install takes the app's gate, which
    /// names anything in its way. It was dropped without a word while a read ran. The control is HEAD's
    /// guard (nothing in flight at all): the press does nothing.
    @Test("Install Windows… shows the form while only a read runs")
    func newVMDuringARead() {
        let creator = FakeEmbeddedCreate()
        var state = F.state(.vm, facts: F.facts(utm: F.installed, answers: .answered, vms: .listed([])))
        state.inFlight = F.flight(.checkAgain(.vm))
        let controller = SetupWindowController(state: state, art: nil, settings: MemorySettings().settings,
                                               makeRunner: { runner(QuietMachine()) }, makeCreator: { creator })
        controller.send(.newWindowsVM)
        #expect(controller.state.creating && creator.isEmbedded)
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
    }

    /// A survey of Windows after a wake holds Tune for up to three minutes, and nobody pressed it:
    /// Back and a row's Skip were greyed out the whole time. A read changes nothing a step decided,
    /// so both work through one. The control is HEAD's rule (nothing while anything runs): the read
    /// case greys Back and ignores both.
    @Test("Back and Skip work while only a read runs")
    func backDuringARead() {
        var state = SetupFixtures.state(.tune, facts: JourneyFixtures.facts)
        state.inFlight = F.flight(.checkAgain(.tune))
        let back = SetupFooter.footer(state).leading.first { $0.press == .send(.back) }
        #expect(back?.enabled == true, "\(SetupFooter.footer(state))")
        let controller = SetupWindowController(state: state, art: nil, settings: MemorySettings().settings,
                                               makeRunner: { runner(QuietMachine()) })
        controller.send(.skip("G1"))
        #expect(controller.state.answers.leftAlone.contains("G1"))
        controller.send(.back)
        #expect(controller.state.step == .vm)
        var finish = FinishFixtures.choosing
        finish.inFlight = F.flight(.lookAgain(.finish, forgetting: .statuses))
        #expect(SetupFinishPage.footer(finish).leading.first?.enabled == true)
    }

    /// The control for the rule above: work that acts keeps Back until it ends, so going back can't
    /// leave a page from under the install it's showing. A rule that let Back through any work fails.
    @Test("Back waits for work that isn't a read")
    func noBackDuringWork() {
        var state = SetupFixtures.state(.tune, facts: JourneyFixtures.facts)
        state.inFlight = F.flight(.fixEverything)
        #expect(!SetupFooter.footer(state).leading.contains { $0.press == .send(.back) })
        let controller = SetupWindowController(state: state, art: nil, settings: MemorySettings().settings,
                                               makeRunner: { runner(QuietMachine()) })
        controller.send(.back)
        controller.send(.skip("G1"))
        #expect(controller.state.step == .tune)
        #expect(!controller.state.answers.leftAlone.contains("G1"))
        var finish = FinishFixtures.choosing
        finish.inFlight = F.flight(.applyChanges)
        #expect(SetupFinishPage.footer(finish).leading.first?.enabled == false)
    }

    @Test("Back and Continue move between the welcome, step 1 and what follows")
    func backAndContinue() {
        let controller = SetupWindowController(state: F.state(facts: F.facts(utm: F.installed, answers: .answered,
                                                                          vms: F.twoVMs)),
                                               art: nil, settings: MemorySettings().settings,
                                               makeRunner: { runner(QuietMachine()) })
        controller.send(.perform(.next))
        #expect(controller.state.step == .vm)
        controller.send(.back)
        #expect(controller.state.step == .lookAround)
        controller.send(.back)
        #expect(controller.state.step == .welcome)
    }
}
