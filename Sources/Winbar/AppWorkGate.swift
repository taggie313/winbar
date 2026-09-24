import Foundation

/// Admission control for this app's controllers. The create job retains its cross-process lock;
/// this gate prevents a setup restart, menu operation and an older Create window racing locally.
/// Menu actions on another VM keep working during an install, as they did before the wizard.
final class AppWorkGate {
    static let shared = AppWorkGate()
    enum Owner {
        case menu, setup, create
        /// Report a Problem…: admitted alongside any work, and never in anyone else's way. It is
        /// wanted most exactly when an install or a step has stalled, which is when the lease used to
        /// refuse it. What makes that safe:
        ///
        /// · Its doctor run writes no Winbar setting (`Context.Options.readOnly`). Doctor on its own
        ///   records what it finds — C2 the saved PC, the survey BitLocker's state and the password
        ///   probe's result — into the settings a step is writing at the same moment, and a lookup
        ///   made just before the wizard saved a PC would have put the stale answer back.
        /// · What it asks of Windows App is `bookmark list` and `export`, reads that Windows App
        ///   allows while it is open and writing its own store, so a `bookmark write` from the wizard
        ///   is no different. Nothing it reads there is acted on.
        /// · Its guest survey is doctor's, run with a script file of its own, and keeps out of the
        ///   two fixed-name files a step uses: its shared-folder marker has its own name, and it
        ///   doesn't ask the person's session about their drive letter (`Context.surveyTraces`).
        ///   Its password probe, if it makes one, is skipped while a failed sign-in still counts.
        /// · It changes nothing in UTM, and writes one new file, the report. The worst it meets
        ///   mid-restart is a slow or missing answer, which the report records and carries on past.
        case report
    }
    struct Work { let owner: Owner; let label: String; let vm: String? }
    private let lock = NSLock()
    private var work: [UUID: Work] = [:]
    final class Lease {
        private var release: (() -> Void)?
        private let lock = NSLock()
        init(_ release: @escaping () -> Void) { self.release = release }
        func finish() {
            lock.lock(); let release = self.release; self.release = nil; lock.unlock()
            release?()
        }
        deinit { finish() }
    }
    /// Whether any work but a report holds the gate: an install, a set-up step, a menu operation.
    /// Asked before starting something nobody pressed for (`StartWindowsAtLaunch`), which should wait
    /// its turn quietly rather than be refused with an alert nobody asked for. A report counts for
    /// nothing here, as it does in `begin`.
    var isHeld: Bool {
        lock.lock()
        defer { lock.unlock() }
        return work.values.contains { $0.owner != .report }
    }

    func begin(_ owner: Owner, label: String, vm: String?, readsInstall: Bool = false) -> Result<Lease, WinbarError> {
        lock.lock()
        defer { lock.unlock() }
        if owner != .report, let busy = work.values.first(where: { existing in
            if existing.owner == .report { return false }
            if readsInstall && existing.owner == .create { return false }
            if (owner == .menu && existing.owner == .create) || (owner == .create && existing.owner == .menu) {
                return existing.vm == nil || vm == nil || existing.vm == vm
            }
            return true
        }) {
            return .failure(WinbarError("Winbar is busy", "Winbar is still \(busy.label). Wait for it to finish, then try again."))
        }
        let id = UUID()
        work[id] = Work(owner: owner, label: label, vm: vm)
        return .success(Lease { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.work[id] = nil; self.lock.unlock()
        })
    }
}
