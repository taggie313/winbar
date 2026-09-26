import Foundation
import Testing
@testable import Winbar

// Pure logic only. Nothing here may reach UTM, a VM, the process table, the keychain, TCC, the
// network or the user's defaults: versions are strings, processes are closures.

/// The #7882 restart. UTM up to 5.0.5 keeps a stopped VM's display window and reuses it with the new
/// configuration, so a display change without a UTM restart crashes UTM and every VM it runs. 5.0.6
/// is the first tag containing the fix (utmapp/UTM#7899). Getting the boundary wrong one way costs a
/// needless restart; the other way costs the crash, so an unknown version must restart.
@Suite("The #7882 restart, by UTM version")
struct DisplayRestartGateTests {
    @Test("5.0.5 and every 4.x restart UTM after a display change")
    func olderUTMsRestart() {
        for version in ["4.7.5", "4.7.6", "5.0.0", "5.0.4", "5.0.5"] {
            #expect(UTMFixes.displayChangeRestartsUTM(version), "UTM \(version)")
        }
    }

    @Test("5.0.6 and later don't")
    func fixedUTMsDoNot() {
        for version in ["5.0.6", "5.0.7", "5.1.0", "6.0.0"] {
            #expect(!UTMFixes.displayChangeRestartsUTM(version), "UTM \(version)")
        }
    }

    /// A version Winbar can't read says nothing about the fix, and the restart is the safe side.
    @Test("An unknown or unreadable version restarts UTM")
    func unknownRestarts() {
        #expect(UTMFixes.displayChangeRestartsUTM(nil))
        #expect(UTMFixes.displayChangeRestartsUTM("banana"))
        #expect(UTMFixes.displayChangeRestartsUTM(""))
        // "5.0" is 5.0.0, which has no fix.
        #expect(UTMFixes.displayChangeRestartsUTM("5.0"))
    }
}

/// On 5.0.6+ the fix closes the VM's window before `update configuration` applies, and with UTM's
/// library window closed too, UTM quits by itself mid-script. Winbar relaunches it and reads the
/// configuration back instead of saying UTM refused. Only that case: a real refusal must still be
/// reported as one, and older UTMs never do this.
@Suite("UTM quitting by itself after update configuration")
struct QuitAfterUpdateTests {
    @Test("5.0.6, change sent, UTM gone: UTM quit by itself")
    func recognised() {
        #expect(UTMFixes.quitItselfAfterUpdate(version: "5.0.6", sentChange: true, utmGone: true))
    }

    @Test("Older UTMs never get the recovery")
    func olderUTMsDoNot() {
        #expect(!UTMFixes.quitItselfAfterUpdate(version: "5.0.5", sentChange: true, utmGone: true))
        #expect(!UTMFixes.quitItselfAfterUpdate(version: "4.7.5", sentChange: true, utmGone: true))
        #expect(!UTMFixes.quitItselfAfterUpdate(version: nil, sentChange: true, utmGone: true))
    }

    /// The script's own checks (no such VM, not stopped) fail before anything is sent, so whatever
    /// UTM did afterwards, the failure is the script's and is said as it is.
    @Test("A failure raised before the change was sent is never read as UTM quitting")
    func notSent() {
        #expect(!UTMFixes.quitItselfAfterUpdate(version: "5.0.6", sentChange: false, utmGone: true))
    }

    @Test("A UTM that is still running refused the change")
    func stillRunning() {
        #expect(!UTMFixes.quitItselfAfterUpdate(version: "5.0.6", sentChange: true, utmGone: false))
    }
}

/// 5.0.6 runs qemu-img on a stopped VM's disks (snapshots, discarding a saved state, the Snapshots
/// tab's first look) and reports the VM as pausing or resuming meanwhile. That VM is off and UTM is
/// busy; it is neither starting nor stopping, and a start then fails.
@Suite("A VM that is off but reported as pausing or resuming")
struct BusyWhileOffTests {
    @Test("On 5.0.6, pausing or resuming with no QEMU process is busy")
    func busy() {
        #expect(UTMFixes.busyWhileOff(status: "pausing", hasProcess: false, version: "5.0.6"))
        #expect(UTMFixes.busyWhileOff(status: "resuming", hasProcess: false, version: "5.0.6"))
    }

    /// A running VM being suspended or resumed has its QEMU process, and really is pausing.
    @Test("A VM with its own QEMU process is really pausing")
    func runningVMIsNotBusy() {
        #expect(!UTMFixes.busyWhileOff(status: "pausing", hasProcess: true, version: "5.0.6"))
        #expect(!UTMFixes.busyWhileOff(status: "resuming", hasProcess: true, version: "5.0.6"))
    }

    @Test("Older UTMs don't report this, and other statuses never are")
    func notBusy() {
        #expect(!UTMFixes.busyWhileOff(status: "pausing", hasProcess: false, version: "5.0.5"))
        #expect(!UTMFixes.busyWhileOff(status: "pausing", hasProcess: false, version: "4.7.5"))
        for status in ["stopped", "started", "starting", "stopping", "paused", ""] {
            #expect(!UTMFixes.busyWhileOff(status: status, hasProcess: false, version: "5.0.6"), "\(status)")
        }
    }

    @Test("The listing marks only the VMs it applies to")
    func listingMarks() {
        // D is an Apple Virtualization VM really being suspended: it never has a QEMU process, so
        // the missing process says nothing about it being off.
        let list = [VMInfo(id: "A", name: "off-but-busy", status: "pausing", backend: "qemu"),
                    VMInfo(id: "B", name: "suspending", status: "pausing", backend: "qemu"),
                    VMInfo(id: "C", name: "idle", status: "stopped", backend: "qemu"),
                    VMInfo(id: "D", name: "apple-suspending", status: "pausing", backend: "apple")]
        let marked = UTMScripting.markBusyWhileOff(list, version: { "5.0.6" }, hasProcess: { $0.id == "B" })
        #expect(marked.map(\.busyWhileOff) == [true, false, false, false])
        // UTM's own word is kept; only the reading of it changes.
        #expect(marked.map(\.status) == list.map(\.status))
        let older = UTMScripting.markBusyWhileOff(list, version: { "5.0.5" }, hasProcess: { _ in false })
        #expect(older.allSatisfy { !$0.busyWhileOff })
    }

    /// The listing runs on every menu refresh; the version and the process table are only asked
    /// when a VM says pausing or resuming.
    @Test("An ordinary listing asks nothing more")
    func ordinaryListingIsFree() {
        var asked = 0
        let list = [VMInfo(name: "a", status: "started"), VMInfo(name: "b", status: "stopped")]
        let marked = UTMScripting.markBusyWhileOff(list, version: { asked += 1; return "5.0.6" },
                                                   hasProcess: { _ in asked += 1; return false })
        #expect(marked == list)
        #expect(asked == 0)
    }

    @Test("The set-up window doesn't call it starting or stopping")
    func setUpWindowWord() {
        var vm = VMInfo(name: "winlab01", status: "pausing", backend: "qemu")
        vm.busyWhileOff = true
        #expect(SetupCopy.VM.state(vm) == SetupCopy.VM.busyWhileOff)
        vm.status = "resuming"
        #expect(SetupCopy.VM.state(vm) == SetupCopy.VM.busyWhileOff)
        // Unmarked, pausing is still what it always was for a running VM.
        vm.busyWhileOff = false
        #expect(SetupCopy.VM.state(vm) != SetupCopy.VM.busyWhileOff)
    }
}

@Suite("Waiting while UTM is busy with a stopped VM")
struct WaitOutBusyTests {
    @Test("It waits until UTM is done, then says so")
    func waitsItOut() {
        var answers: [String?] = ["pausing", "pausing", nil]
        var asked = 0
        let left = UTMFixes.waitOutBusy(deadline: Date().addingTimeInterval(5), every: 0) {
            asked += 1
            return answers.removeFirst()
        }
        #expect(left == nil)
        #expect(asked == 3)
    }

    @Test("It gives up at the deadline and says what UTM last reported")
    func bounded() {
        var asked = 0
        let started = Date()
        let left = UTMFixes.waitOutBusy(deadline: started.addingTimeInterval(0.2), every: 0.05) {
            asked += 1
            return "resuming"
        }
        #expect(left == "resuming")
        #expect(asked > 1)
        #expect(Date().timeIntervalSince(started) < 2)
    }

    @Test("A VM that isn't busy costs one question")
    func notBusyAtAll() {
        var asked = 0
        let left = UTMFixes.waitOutBusy(deadline: Date().addingTimeInterval(5), every: 1) {
            asked += 1
            return nil
        }
        #expect(left == nil)
        #expect(asked == 1)
    }
}

/// The menu asks before a display change, and says what will stop. On a UTM with the #7882 fix
/// UTM itself doesn't restart, so the question mustn't say it does.
@Suite("The menu's display question, by UTM version")
struct DisplayQuestionTests {
    /// The sentence about what restarts, whichever way the screen goes.
    private func firstSentence(restartsUTM: Bool, screenOn: Bool) -> String {
        let body = MenuCopy.confirmBody(vm: "winlab01", screenOn: screenOn, restartsUTM: restartsUTM)
        return String(body.prefix { $0 != "." })
    }

    @Test("It names UTM only where UTM restarts")
    func namesUTMOnlyWhenItRestarts() {
        for screenOn in [true, false] {
            #expect(firstSentence(restartsUTM: true, screenOn: screenOn).contains("UTM"))
            #expect(!firstSentence(restartsUTM: false, screenOn: screenOn).contains("UTM"))
            // The VM restarts either way, and is named either way.
            #expect(firstSentence(restartsUTM: false, screenOn: screenOn).contains("winlab01"))
        }
    }
}

/// UTM 5.0.6 quits before saving when `update configuration` closes its last window (spike rows 7B,
/// 16b, 17: the change was lost every time). Winbar turns UTM's `auto terminate` off around the send
/// so it can't, and puts it back afterwards. A UTM older than 5.0.6 must not be asked anything.
@Suite("Holding UTM open around a configuration change")
struct UTMOpenHoldTests {
    final class Calls {
        var log: [String] = []
        var recorded: Bool?
    }

    func run(applies: Bool, pending: Bool = false, hold: UTMOpenHold.Answer = .held, release: Bool = true,
             _ calls: Calls) -> String {
        UTMOpenHold.around(applies: applies, pending: pending, record: { calls.recorded = $0; calls.log.append("record \($0)") },
                           hold: { calls.log.append("hold"); return hold },
                           release: { calls.log.append("release"); return release },
                           { calls.log.append("body"); return "answer" })
    }

    @Test("A UTM that doesn't quit by itself is never asked")
    func olderUTMsUntouched() {
        let calls = Calls()
        #expect(run(applies: false, calls) == "answer")
        #expect(calls.log == ["body"])
    }

    @Test("Held before the change, recorded before it's sent, put back after")
    func holdsAndReleases() {
        let calls = Calls()
        #expect(run(applies: true, calls) == "answer")
        #expect(calls.log == ["hold", "record true", "body", "release", "record false"])
    }

    /// The person keeps UTM running after its last window closes: nothing of theirs to put back.
    @Test("A setting that was already off is left as it was")
    func alreadyOff() {
        let calls = Calls()
        _ = run(applies: true, hold: .wasOff, calls)
        #expect(calls.log == ["hold", "body"])
    }

    /// Winbar was killed after turning it off: this run puts it back rather than finding it off and
    /// thinking the person chose that.
    @Test("A hold an earlier run left is released, not taken for the person's choice")
    func pendingFromEarlierRun() {
        let calls = Calls()
        _ = run(applies: true, pending: true, hold: .wasOff, calls)
        #expect(calls.log == ["body", "release", "record false"])
    }

    @Test("A release UTM didn't confirm stays recorded for next time")
    func releaseFails() {
        let calls = Calls()
        _ = run(applies: true, release: false, calls)
        #expect(calls.recorded == true)
    }
}

/// When UTM quits anyway, the relaunched UTM never saw the change: reading it back only reports the
/// loss (what 0.5.0's first build did in rows 16b and 17). It is sent once more.
@Suite("Sending the change again after UTM quit before saving it")
struct UpdateRecoveryTests {
    let us = String(UTMScripting.fieldSeparator)
    func answer(_ cores: Int, _ memory: Int, _ displays: Int) -> String { "\(cores)\(us)\(memory)\(us)\(displays)" }
    let quitError = WinbarError("AppleScript failed", "UTM got an error: Connection is invalid. (-609)")

    @Test("An answer stands, and nothing is sent twice")
    func answered() {
        var sent = 0
        let result = UTMScripting.recover(first: .init(answer: .success(answer(6, 16384, 0)), utmQuitItself: false),
                                          again: { sent += 1; return .init(answer: .failure(quitError), utmQuitItself: true) },
                                          readBack: { .success(nil) }, vm: "Win11")
        #expect(sent == 0)
        #expect((try? result.get()) == UTMScripting.Applied(cpuCores: 6, memoryMB: 16384, displayCount: 0))
    }

    @Test("A refusal with UTM still running is a refusal, and isn't retried")
    func refused() {
        var sent = 0
        let result = UTMScripting.recover(first: .init(answer: .failure(quitError), utmQuitItself: false),
                                          again: { sent += 1; return .init(answer: .success(answer(6, 16384, 0)), utmQuitItself: false) },
                                          readBack: { .success(nil) }, vm: "Win11")
        #expect(sent == 0)
        guard case .failure(let failure) = result else { Issue.record("expected a failure"); return }
        #expect(!failure.utmQuitItself)
    }

    @Test("UTM quit before saving: the change is sent again and that answer is the answer")
    func sentAgain() {
        var sent = 0
        var readBack = 0
        let result = UTMScripting.recover(first: .init(answer: .failure(quitError), utmQuitItself: true),
                                          again: { sent += 1; return .init(answer: .success(answer(6, 16384, 0)), utmQuitItself: false) },
                                          readBack: { readBack += 1; return .success(VMInfo(name: "Win11", cpuCores: 2, memoryMB: 4096, displayCount: 1)) },
                                          vm: "Win11")
        #expect(sent == 1)
        #expect(readBack == 0)
        let applied = try? result.get()
        #expect(applied?.cpuCores == 6 && applied?.memoryMB == 16384 && applied?.displayCount == 0)
        #expect(applied?.sentAgain == true && applied?.utmQuitItself == true)
    }

    @Test("Quit again: the relaunched UTM's own word is reported, not assumed")
    func quitTwice() {
        let result = UTMScripting.recover(first: .init(answer: .failure(quitError), utmQuitItself: true),
                                          again: { .init(answer: .failure(quitError), utmQuitItself: true) },
                                          readBack: { .success(VMInfo(name: "Win11", cpuCores: 2, memoryMB: 4096, displayCount: 1)) },
                                          vm: "Win11")
        let applied = try? result.get()
        #expect(applied?.cpuCores == 2 && applied?.displayCount == 1)
        #expect(applied?.utmQuitItself == true)
    }

    @Test("Refused the second time: a failure that says UTM quit first, never a plain refusal")
    func refusedSecondTime() {
        let result = UTMScripting.recover(first: .init(answer: .failure(quitError), utmQuitItself: true),
                                          again: { .init(answer: .failure(WinbarError("AppleScript failed", "nope (-2700)")),
                                                          utmQuitItself: false) },
                                          readBack: { .success(nil) }, vm: "Win11")
        guard case .failure(let failure) = result else { Issue.record("expected a failure"); return }
        #expect(failure.utmQuitItself)
    }
}
