import SwiftUI
import Testing
@testable import Winbar

// What Set Up Winbar says has to be true of the screen it's on: a sentence about what happens next
// only where it happens next, and a failure said once, naming only buttons that are drawn. Each screen
// is an invented fixture drawn offscreen and read back with the Mac's own text recognition.

@MainActor private func words(_ state: SetupWindowState) throws -> [Drawing.Line] {
    try Drawing.lines(try render(state, .light))
}

@MainActor @Suite("Connect says only what's true of the work on screen")
struct ConnectTruthTests {
    private func connect(_ work: SetupRunner.Work) -> SetupWindowState {
        var state = SetupFixtures.state(.connect, facts: JourneyFixtures.facts)
        state.inFlight = SetupFixtures.flight(work)
        return state
    }

    /// Connect's own wait is followed by the desktop question; a Check Again's read, or opening
    /// Accessibility settings, is followed by nothing of the kind, and opens no Windows App.
    @Test("Only Connect's own wait says Winbar asks about the desktop next")
    func onlyForConnect() throws {
        let sentence = "doesn't prove the connection works"
        #expect(Drawing.find(sentence, in: try words(connect(.connect))) != nil)
        for work in [SetupRunner.Work.checkAgain(.connect), .guide(checkID: "C3")] {
            let lines = try words(connect(work))
            #expect(Drawing.find(sentence, in: lines) == nil, "\(work): \(lines)")
        }
    }

    /// A Connect that timed out: the runner's failure ("Windows isn't answering yet: … choose Close
    /// Setup …") was drawn as a plain card above the recovery card with the same heading, naming a
    /// Close Setup that the recovery card doesn't draw when the VM keeps its screen.
    @Test("A timed-out Connect says so once, and names no button that isn't there")
    func timeoutOnce() throws {
        var state = try #require(SetupRecoveryFixtures.screens.first { $0.0 == "connect-failed-not-answering" }?.1)
        let problem = SetupRunner.Problem(title: SetupCopy.Connecting.timedOutTitle, detail: SetupCopy.Connecting.timedOut)
        state.lastEnding = SetupRunner.Ending(work: .connect, outcome: .failed(problem), facts: try #require(state.facts),
                                              slept: false, started: testMoment())
        #expect(SetupJourneyView.problemCard(state) == nil)
        let lines = try words(state)
        #expect(lines.filter { $0.text.contains(SetupCopy.Connecting.timedOutTitle) }.count == 1, "\(lines)")
        #expect(Drawing.find(SetupCopy.Connecting.bCloseSetup, in: lines) == nil, "\(lines)")
        // The control: the same failure on a step with no card of its own still gets the plain card.
        var tune = SetupFixtures.state(.tune, facts: JourneyFixtures.facts)
        tune.lastEnding = SetupRunner.Ending(work: .checkAgain(.tune), outcome: .failed(problem), facts: JourneyFixtures.facts,
                                             slept: false, started: testMoment())
        #expect(SetupJourneyView.problemCard(tune) == problem)
    }
}

// MARK: - The install's next steps, in the window's words

/// The string literals in Swift source, read well enough to check copy: a literal's text with each
/// interpolation replaced by an invented VM name, and literals joined by `+` read as one.
enum SourceLiterals {
    /// The text of the literal whose opening quote is at `start`, and the index after its closing one.
    static func literal(_ source: String, at start: String.Index) -> (text: String, end: String.Index) {
        var text = ""
        var i = source.index(after: start)
        while i < source.endIndex {
            let c = source[i]
            if c == "\"" { return (text, source.index(after: i)) }
            if c == "\\" {
                let next = source.index(after: i)
                guard next < source.endIndex else { break }
                if source[next] == "(" {
                    // An interpolation: to its closing parenthesis, past any literal inside it.
                    var depth = 0
                    var j = next
                    while j < source.endIndex {
                        if source[j] == "\"" { j = literal(source, at: j).end; continue }
                        if source[j] == "(" { depth += 1 }
                        if source[j] == ")" { depth -= 1; if depth == 0 { break } }
                        j = source.index(after: j)
                    }
                    text += "winlab02"
                    i = source.index(after: j)
                    continue
                }
                text.append(source[next] == "n" ? "\n" : source[next])
                i = source.index(after: next)
                continue
            }
            text.append(c)
            i = source.index(after: i)
        }
        return (text, source.endIndex)
    }

    /// The expression starting at `start`, up to the `)` that closes the call it's in, or a `,` at
    /// its own depth when `stopAtComma`.
    static func expression(_ source: String, from start: String.Index, stopAtComma: Bool) -> String {
        var depth = 0
        var i = start
        while i < source.endIndex {
            let c = source[i]
            if c == "\"" { i = literal(source, at: i).end; continue }
            if c == "(" { depth += 1 }
            if c == ")" { if depth == 0 { break }; depth -= 1 }
            if c == ",", depth == 0, stopAtComma { break }
            i = source.index(after: i)
        }
        return String(source[start..<i])
    }

    /// Each run of literals in an expression: `"a" + "b"` is one, the two sides of `x ? "a" : "b"` two.
    static func runs(_ expression: String) -> [String] {
        var runs: [String] = []
        var current: String?
        var joined = false
        var i = expression.startIndex
        while i < expression.endIndex {
            let c = expression[i]
            if c == "\"" {
                let (text, end) = literal(expression, at: i)
                if let run = current, joined { current = run + text } else { if let run = current { runs.append(run) }; current = text }
                joined = false
                i = end
                continue
            }
            if c == "+" {
                joined = true
            } else if !c.isWhitespace {
                if let run = current, !joined { runs.append(run); current = nil }
                joined = false
            }
            i = expression.index(after: i)
        }
        if let run = current { runs.append(run) }
        return runs
    }

    /// Every `marker` in `source`, with the expression after it.
    static func after(_ marker: String, in source: String, stopAtComma: Bool) -> [String] {
        var found: [String] = []
        var search = source.startIndex
        while let range = source.range(of: marker, range: search..<source.endIndex) {
            found.append(expression(source, from: range.upperBound, stopAtComma: stopAtComma))
            search = range.upperBound
        }
        return found
    }
}

@Suite("The install's failures and notes say no Terminal command in a window")
struct InstallWindowWordsTests {
    private static var jobSource: String {
        get throws {
            let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("Sources/Winbar")
            return try String(contentsOf: sources.appendingPathComponent("CreateJobRun.swift"), encoding: .utf8)
        }
    }

    private func terminal(_ text: String) -> Bool { text.contains("winbar ") || text.contains("--") }

    /// The control for the reading: the literals it finds are the job's, joined as the job joins them.
    @Test("The source reading joins a message's literals and splits a choice's")
    func reading() {
        #expect(SourceLiterals.runs(#""a \(name) b" + "c""#) == ["a winlab02 bc"])
        #expect(SourceLiterals.runs(#"x == true ? "yes" : "no""#) == ["yes", "no"])
        #expect(SourceLiterals.after("nextStep: ", in: #"f(nextStep: "winbar start", exit: 1)"#, stopAtComma: true)
                == [#""winbar start""#])
    }

    /// Every next step the job writes, through the window's mapping, whether the install can carry on
    /// or not: E_TIMEOUT's --cancel and E_RESTART's winbar start reached Set Up Winbar word for word.
    @Test("Every next step the job writes reaches the window without a command")
    func nextSteps() throws {
        let steps = SourceLiterals.after("nextStep: ", in: try Self.jobSource, stopAtComma: true).flatMap(SourceLiterals.runs)
        #expect(steps.count >= 10, "\(steps)")
        #expect(steps.contains { terminal($0) }, "the job's own words are Terminal's, which is why they're mapped")
        for step in steps {
            for resumable in [true, false] {
                let window = CreateCopy.windowNextStep(step, resumable: resumable)
                #expect(!terminal(window ?? ""), "\(step) → \(window ?? "nil")")
            }
        }
    }

    /// Every note the job writes for an install started in Set Up Winbar, as the window shows it:
    /// N_RESUME_LATE said "winbar create --cancel" after the stall recovery's own Try Again.
    @Test("Every note the job writes reaches Set Up Winbar without a command")
    func notes() throws {
        let source = try Self.jobSource
        var checked = 0
        // A call's first literal is its code; the runs after it are the text.
        for call in SourceLiterals.after("message(", in: source, stopAtComma: false) where call.hasPrefix("\"") {
            let runs = SourceLiterals.runs(call)
            guard let code = runs.first else { continue }
            for text in runs.dropFirst() {
                let shown = CreateCopy.forWindow(CreateCopy.setupNote(code: code, text: text), vmName: "winlab02")
                #expect(!terminal(shown), "\(code): \(shown)")
                checked += 1
            }
        }
        #expect(checked >= 15, "\(checked) notes read")
    }

    @Test("The window's words name its buttons and menu items, in bold")
    func words() {
        let timeout = CreateCopy.windowNextStep("To start over: winbar create --cancel \"winlab02\", then create it again.",
                                                resumable: true)
        #expect(timeout == "To start over, choose **\(CreateCopy.bDeleteVM)**, then install Windows again.")
        #expect(CreateCopy.windowNextStep("winbar start", resumable: false) == "Choose **Start** in Winbar's menu.")
        let shutdown = CreateCopy.windowNextStep("Shut Windows down yourself, then winbar create --resume \"winlab02\".",
                                                 resumable: true)
        #expect(shutdown?.hasPrefix("Shut Windows down in the VM's window first") == true && shutdown?.contains("**Try Again**") == true)
        #expect(CreateCopy.windowNextStep("winbar create --resume \"winlab02\"", resumable: false) == nil)
    }
}

@MainActor @Suite("The failed install page, drawn with the job's own words")
struct InstallFailedWordsTests {
    /// The render the review saw looked clean only because its fixture invented a next step; with
    /// E_TIMEOUT's own, the page read 'winbar create --cancel "winlab02"'.
    @Test("E_TIMEOUT's page names Delete VM…, and no command", arguments: [Snapshot.Appearance.light, .dark])
    func timeout(appearance: Snapshot.Appearance) throws {
        let controller = ArmieFixtures.createController()
        controller.draw(ArmieFixtures.job(stage: .oobe, outcome: .failed, failure: ArmieFixtures.stoppedWaiting))
        let lines = try Drawing.lines(try render(ArmieFixtures.hidden(ArmieFixtures.creating), appearance,
                                                 embedded: { armie in AnyView(CreateRootView(controller: controller, armie: armie)) }))
        #expect(!lines.contains { $0.text.contains("winbar") || $0.text.contains("--") }, "\(lines)")
        #expect(lines.contains { $0.text.contains("choose Delete VM") }, "\(lines)")
    }
}
