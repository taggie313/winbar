import Foundation
import Testing
@testable import Winbar

// Pure logic only: the quit request, the wait and the signal are closures.

/// UTM refuses a scripted quit with -128 while a sheet is up, which UTM 5.0.6's first-run What's New
/// window is (spike row S1). A refusal must reach the person and never be forced through with
/// SIGTERM, which would leave the sheet unread and the next quit refused the same way.
@Suite("Quitting UTM past a window that refuses it")
struct UTMQuitSequenceTests {
    final class Calls {
        var asks = 0
        var forced = 0
        var said: [String] = []
        var answers: [CommandResult]
        var exits: [Bool]
        init(answers: [CommandResult], exits: [Bool]) { self.answers = answers; self.exits = exits }
        func ask() -> CommandResult { asks += 1; return answers.count > 1 ? answers.removeFirst() : answers[0] }
        func exited() -> Bool { exits.count > 1 ? exits.removeFirst() : exits[0] }
    }

    static let accepted = CommandResult(status: 0, stdout: Data(), stderr: Data(), timedOut: false)
    /// osascript's own words from the spike's S1 evidence.
    static let refused = CommandResult(status: 1, stdout: Data(),
                                       stderr: Data("40:44: execution error: UTM got an error: User canceled. (-128)\n".utf8),
                                       timedOut: false)

    func run(_ calls: Calls) -> Result<Void, WinbarError> {
        UTMQuitSequence.run(ask: calls.ask, exited: { _ in calls.exited() }, forceQuit: { calls.forced += 1 },
                            progress: { calls.said.append($0) }, timeout: 1, windowGrace: 0)
    }

    @Test("Refused twice: the person is told what to close, UTM is asked once more, and nothing is forced")
    func refusedTwiceIsReportedNotForced() {
        let calls = Calls(answers: [Self.refused], exits: [false])
        guard case .failure(let error) = run(calls) else { Issue.record("a refused quit reported success"); return }
        #expect(error.detail == UTMQuitSequence.stillRefused.detail)
        #expect(calls.asks == 2)
        #expect(calls.forced == 0)
        #expect(calls.said.count == 1)
    }

    @Test("Refused once, then accepted after the window is closed: success, with no signal")
    func refusedThenAccepted() {
        let calls = Calls(answers: [Self.refused, Self.accepted], exits: [false, true])
        #expect((try? run(calls).get()) != nil)
        #expect(calls.asks == 2)
        #expect(calls.forced == 0)
    }

    @Test("An accepted quit UTM sits on still ends in a signal, as before")
    func acceptedButSlowIsSignalled() {
        let calls = Calls(answers: [Self.accepted], exits: [false, true])
        #expect((try? run(calls).get()) != nil)
        #expect(calls.asks == 1)
        #expect(calls.forced == 1)
        #expect(calls.said.isEmpty)
    }
}
