import Foundation
import Testing
@testable import Winbar

// Pure logic only: utmctl and the wait's questions are closures, and nothing here reaches UTM or a VM.

/// With the guest agent out of reach, a graceful stop fell back to UTM's power-button press, and a
/// Windows idle for a few minutes lets that press go by (measured 2026-09-27, display blanked and
/// headless alike): Stop waited its two minutes and said Windows hadn't shut down. A second press
/// shut it down cleanly, and two presses 3 s apart still gave one clean shutdown.
@Suite("A second press of UTM's power button")
struct SecondPowerPressTests {
    static func result(_ status: Int32 = 0, stderr: String = "") -> CommandResult {
        CommandResult(status: status, stdout: Data(), stderr: Data(stderr.utf8), timedOut: false)
    }

    @Test("Only a stop that fell back to the power button presses again, 15 seconds in")
    func onlyThePowerButtonPressesAgain() {
        #expect(UTM.StopRequest.powerButton.pressAgainAfter == 15)
        #expect(UTM.StopRequest.guestAgent.pressAgainAfter == nil)
        #expect(UTM.StopRequest.forced.pressAgainAfter == nil)
    }

    @Test("Windows asked through the guest agent is never pressed")
    func guestAgentNeverPresses() {
        var sent: [[String]] = []
        let (result, asked) = UTM.requestShutdown("fixture-vm") { sent.append($0); return Self.result() }
        #expect(asked == .guestAgent)
        #expect(result.ok)
        #expect(sent == [["exec", "fixture-vm", "--cmd", "cmd.exe", "/c", "shutdown /s /t 0"]])
        #expect(asked.pressAgainAfter == nil)
    }

    /// utmctl exits 0 with "Error from event" when the agent doesn't answer.
    @Test("An agent that doesn't answer falls back to one press, and says so")
    func unansweredAgentFallsBackToThePress() {
        var sent: [[String]] = []
        let (result, asked) = UTM.requestShutdown("fixture-vm") { arguments in
            sent.append(arguments)
            return arguments.first == "exec" ? Self.result(stderr: "Error from event: guest agent not connected")
                                             : Self.result()
        }
        #expect(asked == .powerButton)
        #expect(result.ok)
        #expect(sent.count == 2)
        #expect(sent.last == ["stop", "--request", "fixture-vm"])
    }

    @Test("The second press comes once, and not before its time")
    func pressesOnceAfterItsTime() {
        var presses: [Date] = []
        let start = Date()
        let stopped = UTM.waitForStop(deadline: start.addingTimeInterval(1), every: 0.01, stopped: { false },
                                      abort: { false }, pressAgain: (after: 0.1, press: { presses.append(Date()) }))
        #expect(stopped == false)
        #expect(presses.count == 1)
        #expect(presses.allSatisfy { $0 >= start.addingTimeInterval(0.1) })
    }

    @Test("The wait goes on after the press and sees the VM stop")
    func keepsWaitingAfterThePress() {
        var presses = 0
        let stopped = UTM.waitForStop(deadline: Date().addingTimeInterval(60), every: 0.01, stopped: { presses > 0 },
                                      abort: { false }, pressAgain: (after: 0.05, press: { presses += 1 }))
        #expect(stopped == true)
        #expect(presses == 1)
    }

    @Test("A VM that stops before then isn't pressed again")
    func noPressOnceStopped() {
        var looks = 0, presses = 0
        let stopped = UTM.waitForStop(deadline: Date().addingTimeInterval(60), every: 0.01, stopped: {
            looks += 1
            return looks >= 3
        }, abort: { false }, pressAgain: (after: 30, press: { presses += 1 }))
        #expect(stopped == true)
        #expect(presses == 0)
    }

    @Test("Giving up waiting still returns nil, before the press or after it")
    func abortStillReturnsNil() {
        var presses = 0
        let far = Date().addingTimeInterval(60)
        #expect(UTM.waitForStop(deadline: far, every: 0.01, stopped: { false }, abort: { true },
                                pressAgain: (after: 0, press: { presses += 1 })) == nil)
        #expect(presses == 0)
        #expect(UTM.waitForStop(deadline: far, every: 0.01, stopped: { false }, abort: { presses > 0 },
                                pressAgain: (after: 0, press: { presses += 1 })) == nil)
        #expect(presses == 1)
    }

    @Test("A deadline before the second press is due ends the wait without it")
    func deadlineFirst() {
        var presses = 0
        #expect(UTM.waitForStop(deadline: Date().addingTimeInterval(0.05), every: 0.01, stopped: { false },
                                abort: { false }, pressAgain: (after: 30, press: { presses += 1 })) == false)
        #expect(presses == 0)
    }
}
