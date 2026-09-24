import Foundation

// The install job as seen from outside it: what `state.json` holds, and what the CLI and the menu bar
// app both read. One install runs at a time; whoever holds the lock watches it and writes this file,
// and everyone else follows along read-only. It never holds the password.

/// Why a job ended badly, in the copy deck's terms (`code` is an E_* or W_* id, so the same failure
/// reads the same way in Terminal, in the window and in the log).
struct CreateFailure: Codable, Equatable, Sendable {
    var code: String
    var title: String
    var detail: String
    /// What the person can do next, when there is something.
    var nextStep: String?
}

/// A note or warning the job raised (the copy deck's N_* and W_* keys), kept in order so a front-end
/// that joins late still shows what it missed. Never anything the person typed.
struct CreateMessage: Codable, Equatable, Sendable {
    var code: String
    var text: String
    var at: Date
}

/// What FirstLogon.ps1's `status.txt` said, in the few facts the job needs to finish, or to end
/// honestly after a resume that can no longer read the file. Facts only: no line of the
/// guest's own text, and nothing that could carry the password.
struct CreateStatusRecord: Codable, Equatable, Sendable {
    /// `result=ok`: every requested first-logon step worked.
    var ok: Bool
    /// `guest_tools=`, as it was written (0, an installer's exit code, -1, -2, -3).
    var guestTools: String
    /// `rdp=on`.
    var remoteDesktopOn: Bool
    /// `failed_steps`, in FirstLogon.ps1's own step names.
    var failedSteps: [String]
    /// `plaintext_password=yes`: Windows kept the automatic sign-in secret in the registry.
    var plaintextSecret: Bool
}

struct CreateJobState: Codable, Equatable, Sendable {
    /// The VM's UTM id once it exists; before that, a temporary id. It names the job's folder.
    var id: String
    var plan: CreatePlan
    var vmID: String?
    var stage: CreateStage
    /// The stage's detail line, e.g. "3.4 GB written to the VM's disk".
    var detail: String?
    var startedAt: Date
    var updatedAt: Date
    var finishedAt: Date?
    var outcome: Outcome?
    /// Guest restarts seen on the serial console; the stage heuristic counts these.
    var restarts: Int
    var bytesWritten: UInt64?
    /// Copy-deck ids already shown (W_STALL, N_…), so a warning is shown once per job.
    var shown: [String]
    /// What the stall rules say about the VM right now, and — when one of them has fired — which
    /// one: a quiet VM and a busy VM that writes nothing are different wedges and get different
    /// words. The warning itself is said once; this says whether it is still true, so both
    /// front-ends can take the note down when the VM stirs again. nil where the rules don't
    /// apply: before Setup starts copying, after it has finished, and in a state file from a
    /// Winbar that didn't record it. A 0.1.0 state file wrote a bool here and still decodes.
    var stalled: StallState?
    /// Those notes and warnings in full, in the order they were raised, for a front-end to print.
    var messages: [CreateMessage] = []
    var failure: CreateFailure?
    /// The job's media folder, so an abandoned job can still be cleaned up.
    var mediaDir: String?
    var logPath: String?
    /// True while a process holds the lock and is driving the install. A stale true (the watcher was
    /// killed) is corrected by whoever takes the lock next.
    var watched: Bool
    /// What `create-vm` recorded: the system disk and CD ids `finish` needs, and the MAC the RDP
    /// probe and the DHCP lease lookup use. nil before stage 4; resume and cleanup both need it after.
    var created: CreatedVM?
    /// The saved PC this job made in Windows App, by Windows App's own id, so a cancel can take it
    /// away again rather than leaving a PC pointing at a host that never existed. Not a secret: the
    /// password went to Windows App and never here. nil when the PC was already there, when Windows
    /// App was open, or when there is no Windows App.
    var savedPCID: String?
    /// That saved PC's name, so the end of the install can tell Connect which tile is this VM's.
    var savedPCName: String?
    /// The saved PC for the same host that signs in as another account, when the new one was written
    /// beside it: its name and that account. Connect keeps off tiles named after the host while it is
    /// there, and an anonymised report masks both (`SavedPCMemory`).
    var savedPCOtherAccountName: String?
    var savedPCOtherAccountUser: String?
    /// When stage 5 first began, for "installing since". Kept across resumes and Mac restarts.
    var installStartedAt: Date?
    /// When the job entered the stage it is in now, so a front-end can say how long that stage has
    /// been going. `updatedAt` can't: it is rewritten every time anything is saved, which during the
    /// copy stage is every 30 seconds. nil in a state file from a Winbar that didn't record it —
    /// fall back to `updatedAt` there.
    var stageStartedAt: Date?
    /// How long this job has actually spent watching a running VM, added up across resumes. The
    /// two-hour limit runs on this, not on the wall clock since `installStartedAt`: an install
    /// interrupted at midnight and resumed after breakfast hasn't been installing all night, and
    /// the documented interrupt-and-resume path has to survive it.
    var watchedSeconds: TimeInterval?
    /// What `status.txt` said, kept so that a resume which can't read it again (the VM is shut down,
    /// the guest agent is gone) doesn't report a failed install as a clean success.
    var status: CreateStatusRecord?

    /// Whether this run wrote the saved PC in Windows App itself. Read from the note the job
    /// raised, not from `savedPCID`, because that is cleared again when a cancel takes the PC back
    /// and because the notes are what both front-ends already follow.
    ///
    /// False covers every way it didn't happen — Windows App was open, a PC for this host was
    /// already there, the command line failed, Windows App isn't installed — and in all of them the
    /// person still has to save the PC, so the ending has to keep saying so.
    var wroteSavedPC: Bool { messages.contains { $0.code == "N_PC_SAVED" } }

    /// Whether this run put a product key in the answer file, read from the note the job raised for the same
    /// reason `wroteSavedPC` is. The key itself is never here — only that there was one — and it decides which
    /// of the two activation lines the ending shows, so neither front-end tells the person Windows isn't
    /// activated when they have just paid for it to be.
    var usedProductKey: Bool { messages.contains { $0.code == "N_PRODUCT_KEY" } }

    enum Outcome: String, Codable, Sendable { case done, failed, cancelled }

    /// The job is over: nothing is watching it, and neither front-end should still show it as an
    /// install in progress. A failure sets it too — a job that ended badly has still ended.
    var isFinished: Bool { outcome != nil }

    /// `winbar create --resume` (and the window's Try Again) can carry on with it: it wasn't finished
    /// or thrown away, a VM exists, its setup disk is still there, and Windows had started
    /// installing. This is what `CreateRun.resume` accepts, so the two can't drift.
    var isResumable: Bool {
        guard outcome == nil || outcome == .failed, vmID != nil, mediaDir != nil else { return false }
        return stage.number > CreateStage.vm.number || (stage == .vm && created != nil)
    }

    /// `--cancel`'s jobs: anything that hasn't already finished or been thrown away, including one
    /// abandoned before its VM existed (there is still a setup disk to delete).
    var canBeCancelled: Bool { outcome != .done && outcome != .cancelled }

    /// Nothing more can be done with this job, so the sweep may take its folder: it finished, was
    /// cancelled, or failed with nothing left to carry on with.
    var isSpent: Bool { isFinished && !isResumable }
}
