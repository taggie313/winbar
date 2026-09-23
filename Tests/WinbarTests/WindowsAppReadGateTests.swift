import Foundation
import Testing
@testable import Winbar

@Suite("A stalled client read cannot stall every wizard page")
struct WindowsAppReadGateTests {
    private let executable = WindowsAppBookmarks.ExecutableIdentity(path: "/synthetic/Windows App", size: 100)

    private func result(timedOut: Bool = false, status: Int32 = 0) -> CommandResult {
        CommandResult(status: status, stdout: Data(), stderr: Data(), timedOut: timedOut)
    }

    @Test("One timeout blocks both list and export without calling the client again")
    func timeoutStopsRepeatedReads() throws {
        for command in ["list", "export"] {
            let gate = WindowsAppBookmarks.ReadGate()
            var calls = 0
            let first = try gate.run(executable: executable, arguments: [command], what: "read saved PCs", timeout: 45) { limit in
                calls += 1
                #expect(limit == 10)
                return result(timedOut: true)
            }
            #expect(first.timedOut)
            for next in ["list", "export", "list"] {
                #expect(throws: WindowsAppBookmarks.Failure.self) {
                    try gate.run(executable: executable, arguments: [next], what: "read saved PCs", timeout: 45) { _ in
                        calls += 1
                        return result()
                    }
                }
            }
            #expect(calls == 1)
        }
    }

    @Test("An explicit retry or replacement executable permits a fresh read")
    func recovery() throws {
        let gate = WindowsAppBookmarks.ReadGate()
        _ = try gate.run(executable: executable, arguments: ["list"], what: "read", timeout: 45) { _ in result(timedOut: true) }
        var calls = 0
        let updated = WindowsAppBookmarks.ExecutableIdentity(path: executable.path, modified: Date(timeIntervalSince1970: 1), size: 101)
        _ = try gate.run(executable: updated, arguments: ["list"], what: "read", timeout: 45) { _ in calls += 1; return result() }
        gate.reset()
        _ = try gate.run(executable: executable, arguments: ["list"], what: "read", timeout: 45) { _ in calls += 1; return result() }
        #expect(calls == 2)
    }

    @Test("A successful empty list and an ordinary failure are not timeouts")
    func onlyTimeoutsLatch() throws {
        let gate = WindowsAppBookmarks.ReadGate()
        var calls = 0
        for status: Int32 in [0, 1, 0] {
            _ = try gate.run(executable: executable, arguments: ["list"], what: "read", timeout: 4) { limit in
                #expect(limit == 4)
                calls += 1
                return result(status: status)
            }
        }
        #expect(calls == 3)
    }

    @Test("Writes retain their deadline and are never replayed by the read gate")
    func writesAreNotRetried() throws {
        let gate = WindowsAppBookmarks.ReadGate()
        var calls = 0
        for command in ["write", "delete"] {
            let response = try gate.run(executable: executable, arguments: [command], what: "write", timeout: 45) { limit in
                #expect(limit == 45)
                calls += 1
                return result(timedOut: true)
            }
            #expect(response.timedOut)
        }
        #expect(calls == 2)
        _ = try gate.run(executable: executable, arguments: ["list"], what: "read", timeout: 45) { _ in calls += 1; return result() }
        #expect(calls == 3)
    }
}
