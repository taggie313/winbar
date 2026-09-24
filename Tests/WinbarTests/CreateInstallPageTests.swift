import SwiftUI
import Testing
@testable import Winbar

// The Windows install as Set Up Winbar's step 2: a page title at the wizard's size on every one of its
// states, a heading VoiceOver lands on, the one status mark rather than text glyphs, and the progress
// element saying what is installed where. Every install is an invented fixture drawn offscreen; nothing
// is run.

@MainActor private func hostedPage(_ job: CreateJobState) -> (ArmieHost?) -> AnyView {
    let controller = ArmieFixtures.createController()
    controller.draw(job)
    return { armie in AnyView(CreateRootView(controller: controller, armie: armie)) }
}

@MainActor enum InstallStates {
    static let failure = CreateFailure(code: "E_VM_STOPPED", title: "The VM stopped", detail: "UTM stopped “winlab02”.",
                                       nextStep: nil)
    static let problems = CreateFailure(code: "E_RESULT_FAILED", title: "Some of Winbar's first sign-in steps failed",
                                        detail: "", nextStep: nil)

    /// Each state with the title it has inside the wizard, and the status mark beside its line.
    static var all: [(String, CreateJobState, String, StatusMark.Status?)] {
        [("running", ArmieFixtures.job(), CreateCopy.pTitle, nil),
         ("failed", ArmieFixtures.job(stage: .oobe, outcome: .failed, failure: failure), CreateCopy.fTitle, .failed),
         ("problems", ArmieFixtures.job(stage: .firstLogon, outcome: .failed, failure: problems), CreateCopy.dTitleProblems,
          .attention),
         ("done", ArmieFixtures.job(stage: .finish, outcome: .done), CreateCopy.dTitle, .done),
         ("cancelled", ArmieFixtures.job(stage: .copy, outcome: .cancelled), CreateCopy.cTitle, nil)]
    }
}

@MainActor @Suite("The install's page: a title, a heading, and the one status mark")
struct CreateInstallPageTests {
    @Test("Inside Set Up Winbar every install state has a page title; in its own window, a headline")
    func headings() {
        for (name, job, title, mark) in InstallStates.all {
            let hosted = CreateJobView.heading(job, hosted: true)
            #expect(hosted.title == title && hosted.mark == mark, "\(name): \(hosted)")
            let own = CreateJobView.heading(job, hosted: false)
            #expect(own.title == nil && own.line?.isEmpty == false && own.mark == mark, "\(name): \(own)")
            // No text glyph for the mark: VoiceOver read "✗" as part of the title.
            for line in [hosted.title, hosted.line, own.line].compactMap({ $0 }) {
                #expect(!line.contains { "✓✗!".contains($0) }, "\(name): \(line)")
            }
        }
        #expect(CreateJobView.failureHeader(InstallStates.all[1].1) == "The VM stopped")
        #expect(CreateJobView.announcement(from: nil, to: InstallStates.all[1].1) == "The VM stopped")
    }

    /// Drawn: the title is at the wizard's page-title size, as on every other page, where the
    /// install's heading was 13 pt text. Read as the height of the words' box, which a 24 pt title
    /// fills to about 19 pt and 13 pt text to about 13.
    @Test("Drawn, each install state's title is at the wizard's title size", arguments: [Snapshot.Appearance.light, .dark])
    func drawnTitles(appearance: Snapshot.Appearance) throws {
        for (name, job, title, _) in InstallStates.all {
            let lines = try Drawing.lines(try render(ArmieFixtures.hidden(ArmieFixtures.creating), appearance,
                                                     embedded: hostedPage(job)))
            let drawn = try #require(lines.first { $0.text.replacingOccurrences(of: "’", with: "'") == title }, "\(name): \(lines)")
            #expect(drawn.frame.height >= 17 && drawn.frame.minY < 90, "\(name): \(drawn)")
        }
        // The control: a line drawn at the body size measures well under.
        let lines = try Drawing.lines(try render(ArmieFixtures.hidden(ArmieFixtures.creating), appearance,
                                                 embedded: hostedPage(ArmieFixtures.job())))
        let stage = try #require(Drawing.find("Stage 6 of 10", in: lines), "\(lines)")
        #expect(stage.frame.height < 16, "\(stage)")
    }

    /// The page title is a heading (SetupPageTitle's own trait, `SetupHeadingTests`), and the status
    /// line under it, or the headline in the window of its own, is one too.
    @Test("The install's title and its line are headings to VoiceOver")
    func voiceOver() {
        let heading = traitBit(.isHeader)
        for (name, job, title, _) in InstallStates.all {
            let hosted = resolvedDump(JobHeading(heading: CreateJobView.heading(job, hosted: true), hosted: true).body)
            // A dump escapes an apostrophe.
            #expect(hosted.contains("SetupPageTitle") && hosted.contains(title.replacingOccurrences(of: "'", with: "\\'")),
                    "\(name)")
            let own = resolvedDump(JobHeading(heading: CreateJobView.heading(job, hosted: false), hosted: false).body)
            #expect(traitValues(own).contains { $0 & heading != 0 }, "\(name): \(traitValues(own))")
        }
    }

    /// The running page's progress element had its label set to the stage and time, which dropped the
    /// header it held: "Installing Windows 11 Pro in “winlab02”" was never read.
    @Test("The progress element says what is installed where, then the stage and the time")
    func progressLabel() {
        let job = ArmieFixtures.job()
        let progress = CreateProgress(state: job, now: SetupFixtures.started)
        let hosted = CreateJobView.progressLabel(progress, state: job, hosted: true)
        #expect(hosted == "Windows 11 Pro in “winlab02”, \(progress.step), \(progress.soFar)")
        // In its own window the headline says it, as a heading of its own.
        #expect(CreateJobView.progressLabel(progress, state: job, hosted: false) == "\(progress.step), \(progress.soFar)")
    }

    @Test("The done page inside Set Up Winbar names its Done button, in bold")
    func doneWords() {
        let done = SetupCopy.markdown(CreateCopy.doneEmbedded)
        #expect(boldRuns(done) == [CreateCopy.bDone])
        #expect(!String(done.characters).contains("Close this result"))
    }
}

/// What the hosted install's and form's buttons were pressed to do, in order.
@MainActor private final class Presses {
    var install: [CreateJobView.Action.Press] = []
    var ends: [CreateWindowController.EmbeddedEnd] = []
}

@MainActor @Suite("Return and Escape on the install's and the form's buttons in the wizard's footer")
struct CreateFooterKeyTests {
    /// The install drawn as the wizard's step 2, its presses recorded rather than carried out: Try
    /// Again never resumes an install here, and Show VM Window never opens UTM.
    private func install(_ job: CreateJobState) -> (Pressing<SetupScreen>, Presses) {
        let presses = Presses()
        let controller = ArmieFixtures.createController { presses.install.append($0) }
        controller.draw(job)
        let screen = SetupScreen(state: ArmieFixtures.hidden(ArmieFixtures.creating), art: nil,
                                 embedded: { armie in AnyView(CreateRootView(controller: controller, armie: armie)) }, send: { _ in })
        return (Pressing(screen), presses)
    }

    @Test("Running: Return presses Close Window; stalled, Show VM Window")
    func running() {
        let (calm, calmPresses) = install(ArmieFixtures.job())
        #expect(calm.press(.return))
        #expect(calmPresses.install == [.close])
        let (stalled, stalledPresses) = install(ArmieFixtures.job(stalled: .quiet, messages: ArmieFixtures.stall))
        #expect(stalled.press(.return))
        #expect(stalledPresses.install == [.showVM])
    }

    /// M14 took Return and the fill from these, and M13 took Escape from Close; both passed.
    @Test("A failure it can carry on from: Return presses Try Again, Escape presses Close")
    func resumable() throws {
        let job = ArmieFixtures.job(stage: .oobe, outcome: .failed, failure: InstallStates.failure)
        #expect(job.isResumable)
        let (window, presses) = install(job)
        #expect(window.press(.return))
        #expect(window.press(.escape))
        #expect(presses.install == [.tryAgain, .done])
    }

    @Test("A failure it can't carry on from, and the done page: Return presses Close, and Done")
    func endings() {
        var stuck = ArmieFixtures.job(stage: .firstLogon, outcome: .failed, failure: InstallStates.problems)
        stuck.mediaDir = nil
        #expect(!stuck.isResumable)
        let (failed, failedPresses) = install(stuck)
        #expect(failed.press(.return))
        #expect(failedPresses.install == [.done])
        let (done, donePresses) = install(ArmieFixtures.job(stage: .finish, outcome: .done))
        #expect(done.press(.return))
        #expect(donePresses.install == [.done])
    }

    /// M12 took Escape from the form's Cancel and passed. Drawn inside the wizard, embedded with a
    /// stand-in for it, so Cancel's real press hands back to step 2, which the stand-in records.
    @Test("Every page of the form: Escape presses Cancel, which hands back to step 2",
          arguments: ["windows", "windows-read", "account", "ready", "ready-customize"])
    func formCancel(page: String) throws {
        let controller = try #require(FormPageFixtures.pages.first { $0.0 == page }?.1)
        let presses = Presses()
        controller.embed(.init(present: {}, hide: {}, window: { nil }, finished: { presses.ends.append($0) }))
        let window = Pressing(SetupScreen(state: ArmieFixtures.hidden(ArmieFixtures.creating), art: nil,
                                          embedded: { armie in AnyView(CreateRootView(controller: controller, armie: armie)) },
                                          send: { _ in }))
        #expect(window.press(.escape), "\(page): nothing took Escape")
        #expect(presses.ends == [.handedBack], "\(page)")
        controller.unembed()
    }
}

@MainActor @Suite("The ISO drop box's border reads as a boundary")
struct ISODropBorderTests {
    /// A boundary needs 3:1 against what's around it. The dashed border was the muted grey at 60%,
    /// which measured 2.51:1 on the light backdrop (#909498 on #E0EAF3). Read off the drawn page: the
    /// darkest ink in a strip down the box's left edge, against the commonest colour there.
    @Test("The empty form's drop box border is at least 3:1 in every appearance",
          arguments: Snapshot.Appearance.allCases)
    func border(appearance: Snapshot.Appearance) throws {
        let controller = ArmieFixtures.createController()
        #expect(controller.form.iso == .none)
        let png = try render(ArmieFixtures.hidden(ArmieFixtures.creating), appearance,
                             embedded: { armie in AnyView(CreateRootView(controller: controller, armie: armie)) })
        let lines = try Drawing.lines(png)
        let drop = try #require(Drawing.find(CreateCopy.isoDrop, in: lines), "\(lines)")
        let edge = CGRect(x: 12, y: drop.frame.midY - 60, width: 16, height: 120)
        let contrast = try #require(Drawing.inkContrast(png, in: edge))
        #expect(contrast >= 3, "\(appearance.rawValue): \(contrast)")
    }
}
