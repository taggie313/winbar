import Foundation
import Testing
@testable import Winbar

// Pure logic only: UTM's word, the resume command and the wait are closures.

/// A VM paused in UTM keeps its QEMU process, so `winbar start` said "already running" to it and
/// left it frozen (spike rows 12a, 12b). utmctl's `start` resumes it; its result is read the way
/// every utmctl answer is, since utmctl exits 0 on failures and says so only in text.
@Suite("Resuming a VM paused in UTM")
struct PausedVMTests {
    final class Calls {
        var resumed = 0
        var statuses: [String?]
        init(_ statuses: [String?]) { self.statuses = statuses }
        /// Each ask takes the next answer; the last one repeats.
        func status() -> String? { statuses.count > 1 ? statuses.removeFirst() : statuses.first ?? nil }
    }

    static func result(_ status: Int32 = 0, stderr: String = "") -> CommandResult {
        CommandResult(status: status, stdout: Data(), stderr: Data(stderr.utf8), timedOut: false)
    }

    func run(_ calls: Calls, resume: CommandResult = result()) -> Result<UTM.PausedOutcome, WinbarError> {
        UTM.resumeIfPaused("fixture-vm", status: calls.status,
                           resume: { calls.resumed += 1; return resume },
                           wait: { check in (0..<3).contains { _ in check() } })
    }

    @Test("A running VM, or one UTM can't describe, is left alone")
    func notPausedLeftAlone() throws {
        for status in ["started", "stopped", nil] as [String?] {
            let calls = Calls([status])
            #expect(try run(calls).get() == .notPaused, "\(status ?? "nil")")
            #expect(calls.resumed == 0)
        }
    }

    @Test("A paused VM is resumed and reported as resumed once UTM says started")
    func pausedIsResumed() throws {
        let calls = Calls(["paused", "resuming", "started"])
        #expect(try run(calls).get() == .resumed)
        #expect(calls.resumed == 1)
    }

    /// Row 12b: utmctl exited 0 with "Error from event: …" on stderr.
    @Test("A resume utmctl refused in text, exit 0, is a failure")
    func refusedInTextFails() {
        let calls = Calls(["paused", "started"])
        let refused = Self.result(stderr: "Error from event: The operation couldn’t be completed. (OSStatus error -2700.)")
        #expect(throws: WinbarError.self) { try run(calls, resume: refused).get() }
    }

    @Test("A resume UTM accepted but didn't carry out is a failure, not 'running'")
    func stillPausedFails() {
        let calls = Calls(["paused"])
        #expect(throws: WinbarError.self) { try run(calls).get() }
        #expect(calls.resumed == 1)
    }
}
