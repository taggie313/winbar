import Foundation

/// Admission control for this app's controllers. The create job retains its cross-process lock;
/// this gate prevents a setup restart, menu operation and an older Create window racing locally.
/// Menu actions on another VM keep working during an install, as they did before the wizard.
final class AppWorkGate {
    static let shared = AppWorkGate()
    enum Owner { case menu, setup, create }
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
    func begin(_ owner: Owner, label: String, vm: String?, readsInstall: Bool = false) -> Result<Lease, WinbarError> {
        lock.lock()
        defer { lock.unlock() }
        if let busy = work.values.first(where: { existing in
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
