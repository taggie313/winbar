import Foundation
import Testing
@testable import Winbar

// `winbar create --cancel` while another Winbar watches the install (spike row 1): the request it
// leaves, how it reads the watcher's progress, and the job record it takes away afterwards. Pure or
// in a temporary folder; no UTM, no lock under the real Application Support folder.

@Suite("A cancel handed to the Winbar watching the install")
struct CreateCancelElsewhereTests {
    /// The watcher acts on a request once: a request read twice would run a second cancel against a
    /// job that has already ended.
    @Test("The watcher takes a cancel request once")
    func requestIsTakenOnce() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(CreateJob.takeCancelRequest(in: directory) == nil)
        try CreateJob.askToCancel(in: directory, deleteVM: true)
        #expect(CreateJob.cancelRequestPending(in: directory))
        #expect(CreateJob.takeCancelRequest(in: directory) == true)
        #expect(!CreateJob.cancelRequestPending(in: directory))
        #expect(CreateJob.takeCancelRequest(in: directory) == nil)
    }

    /// The order matters: a watcher that finished the cancel and then let go of the lock (its
    /// process exits right after) must read as done, not as "nobody took it, cancel it again here".
    @Test("A finished cancel reads as done even once the watcher has let go of the lock")
    func finishedBeatsFreedLock() {
        let asked = testMoment(-5)
        var ended = testState(outcome: .cancelled, watched: false, updatedAt: testMoment())
        ended.cancelSteps = CancelSteps(stopped: true, deletedVM: true, deletedSetupDisk: true)
        #expect(CreateJob.outsideCancelProgress(ended, requestPending: false, lockFree: true, askedAt: asked)
                == .done(ended))
    }

    @Test("A failure written after the request was taken is the cancel's; an older one isn't")
    func failureAfterTheAskOnly() {
        let asked = testMoment(-5)
        var failedNow = testState(outcome: .failed, watched: false, updatedAt: testMoment())
        failedNow.failure = testFailure
        #expect(CreateJob.outsideCancelProgress(failedNow, requestPending: false, lockFree: false, askedAt: asked)
                == .failed(testFailure))
        // Still untaken: the failure can't be the cancel's.
        #expect(CreateJob.outsideCancelProgress(failedNow, requestPending: true, lockFree: false, askedAt: asked) == nil)
        var failedBefore = failedNow
        failedBefore.updatedAt = testMoment(-60)
        #expect(CreateJob.outsideCancelProgress(failedBefore, requestPending: false, lockFree: false, askedAt: asked) == nil)
    }

    @Test("A watcher that went away before taking the request leaves the cancel to the asker")
    func freedLockHandsItBack() {
        let running = testState()
        #expect(CreateJob.outsideCancelProgress(running, requestPending: true, lockFree: true, askedAt: testMoment())
                == .lockFreed)
        #expect(CreateJob.outsideCancelProgress(running, requestPending: true, lockFree: false, askedAt: testMoment()) == nil)
    }
}

@Suite("The job record after a cancel")
struct CreateCancelRecordTests {
    /// Row 1 left `Create/create-*/` with state.json and the marker after a finished cancel.
    @Test("A cancelled job with no setup disk left is taken away")
    func cancelledRecordGoes() throws {
        let (base, directory) = try testJobFolder()
        defer { try? FileManager.default.removeItem(at: base) }
        try CreateJob.writeState(testState(outcome: .cancelled, watched: false), in: directory)
        #expect(CreateJob.removeRecord(in: directory, base: base, grace: 0))
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test("A job still installing, or one whose setup disk is still there, is left alone")
    func liveOrDiskHoldingRecordStays() throws {
        let (base, directory) = try testJobFolder()
        defer { try? FileManager.default.removeItem(at: base) }
        try CreateJob.writeState(testState(), in: directory)
        #expect(!CreateJob.removeRecord(in: directory, base: base, grace: 0))

        try CreateJob.writeState(testState(outcome: .cancelled, watched: false), in: directory)
        try Data("not really an ISO".utf8).write(to: directory.appendingPathComponent(SetupMedia.isoName))
        #expect(!CreateJob.removeRecord(in: directory, base: base, grace: 0))
        #expect(FileManager.default.fileExists(atPath: directory.path))
    }
}
