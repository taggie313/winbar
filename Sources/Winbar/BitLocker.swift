import Foundation

/// BitLocker on the guest's C:, as `Get-BitLockerVolume` reports it.
struct BitLockerState: Equatable {
    let volumeStatus: String    // FullyDecrypted, FullyEncrypted, EncryptionInProgress, DecryptionInProgress, …
    let protection: String      // On, Off
    let percent: Int?

    init(volumeStatus: String, protection: String, percent: Int?) {
        self.volumeStatus = volumeStatus
        self.protection = protection
        self.percent = percent
    }

    init?(_ output: GuestOutput) {
        guard output["G9_ERROR"] == nil, let status = output["G9_STATUS"], !status.isEmpty else { return nil }
        self.init(volumeStatus: status, protection: output["G9_PROTECTION"] ?? "", percent: output.int("G9_PERCENT"))
    }

    /// No BitLocker feature at all counts as decrypted.
    var decrypted: Bool { volumeStatus == "FullyDecrypted" || volumeStatus == "Unavailable" }
    var decrypting: Bool { volumeStatus.hasPrefix("Decryption") }
    var protected: Bool { protection == "On" }
}

enum BitLocker {
    enum Guard: Equatable {
        case notNeeded
        case suspended
        case unknown(String)
    }

    /// Before any configuration change: a device-topology change on a protected disk sends Windows to
    /// the recovery-key screen, so suspend protection for exactly one boot first. The guest must be up.
    static func suspendForOneBoot(vm: String) -> Guard {
        switch GuestAgent.run(vm: vm, GuestScripts.bitLockerGuard(), timeout: 90) {
        case .failure(let error):
            return .unknown(error.description)
        case .success(let output):
            guard let state = BitLockerState(output) else {
                return .unknown(output["G9_ERROR"] ?? output.error ?? "Windows didn't report BitLocker's state.")
            }
            Config.recordBitLocker(on: !state.decrypted)
            if let error = output.error { return .unknown(error) }
            return output["SUSPENDED"] == "1" ? .suspended : .notNeeded
        }
    }

    static func status(vm: String) -> Result<BitLockerState, WinbarError> {
        GuestAgent.run(vm: vm, GuestScripts.bitLockerStatus(), timeout: 90).flatMap { output in
            guard let state = BitLockerState(output) else {
                return .failure(WinbarError("Couldn't read BitLocker's state", output["G9_ERROR"] ?? output.error ?? ""))
            }
            Config.recordBitLocker(on: !state.decrypted)
            return .success(state)
        }
    }

    static func startDecrypting(vm: String) -> Result<BitLockerState, WinbarError> {
        GuestAgent.run(vm: vm, GuestScripts.bitLockerDecrypt(), timeout: 120).flatMap { output in
            if let error = output.error { return .failure(WinbarError("Couldn't start decrypting C:", error)) }
            return BitLockerState(output).map { .success($0) }
                ?? .failure(WinbarError("Couldn't read BitLocker's state", output["G9_ERROR"] ?? ""))
        }
    }
}
