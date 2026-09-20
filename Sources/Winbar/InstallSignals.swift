import Darwin
import Foundation

// The signals `winbar create` watches while Windows installs, apart from the serial console: the
// first-logon script's status file (the only success signal), the QEMU process's disk writes and CPU
// time, and the limits that turn silence into a message. Observe only: nothing here stops the VM.

/// UTM Guest Tools' installer result, from `guest_tools=`.
enum GuestToolsResult: Equatable, Sendable {
    case installed
    /// The installer's own non-zero exit code (W_GT_EXIT when the agent works anyway).
    case exitCode(Int)
    /// -1: FirstLogon.ps1 found no installer on any CD.
    case notFound
    /// -2: still running after 20 minutes; only a warning when the guest agent runs (W_GT_SLOW).
    case stillRunning
    /// -3: not requested.
    case notRequested
    /// Not a number.
    case unreadable(String)

    init(_ raw: String) {
        switch Int(raw.trimmingCharacters(in: .whitespaces)) {
        case 0: self = .installed
        case -1: self = .notFound
        case -2: self = .stillRunning
        case -3: self = .notRequested
        case let code?: self = .exitCode(code)
        case nil: self = .unreadable(raw)
        }
    }
}

/// What FirstLogon.ps1 reported in `C:\Windows\Temp\winbar-install\status.txt`.
struct InstallStatus: Equatable, Sendable {
    /// `result=ok`: every requested first-logon step succeeded. Anything else counts as failed.
    var ok: Bool
    var guestTools: GuestToolsResult
    /// `rdp=on`: Remote Desktop is actually on, whatever was requested.
    var remoteDesktopOn: Bool
    /// Every key in the file, known or not (the last value wins). Unknown keys are kept for the log
    /// and otherwise ignored: the script may add keys without breaking older Winbars.
    var values: [String: String]

    /// `failed_steps`: FirstLogon.ps1's step names (`rdp`, `power`, …), comma-separated.
    var failedSteps: [String] {
        (values["failed_steps"] ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The failed steps as E_RESULT_FAILED names them.
    var failedStepNames: [String] { failedSteps.map { InstallStatus.stepNames[$0] ?? $0 } }

    /// The first failure, `step: message`.
    var error: String? { values["error"].flatMap { $0.isEmpty ? nil : $0 } }

    /// FirstLogon.ps1 had to leave a plain-text autologon password in the registry (W_AUTOLOGON_PLAINTEXT).
    var plaintextPassword: Bool { values["plaintext_password"]?.lowercased() == "yes" }

    static let stepNames = [
        "panther": "Setup's cached answer file", "autologon": "automatic sign-in", "rdp": "Remote Desktop",
        "bitlocker": "BitLocker", "power": "power plan", "power_button": "power button", "services": "services",
        "visual_effects": "visual effects", "guest_tools": "UTM Guest Tools", "guest_agent": "guest agent",
    ]

}

extension InstallStatus {
    /// The few facts state.json keeps, so a resume that can't read `status.txt` again still knows how
    /// the install went. Never the file's own text: a line Windows wrote is not Winbar's to store.
    var record: CreateStatusRecord {
        CreateStatusRecord(ok: ok, guestTools: values["guest_tools"] ?? "", remoteDesktopOn: remoteDesktopOn,
                           failedSteps: failedSteps,
                           plaintextSecret: plaintextPassword || values["autologon_secret"] == "plaintext")
    }

    /// What a resumed run knows about a status file it can no longer read.
    init(_ record: CreateStatusRecord) {
        self.init(ok: record.ok, guestTools: GuestToolsResult(record.guestTools),
                  remoteDesktopOn: record.remoteDesktopOn,
                  values: ["result": record.ok ? "ok" : "failed", "guest_tools": record.guestTools,
                           "rdp": record.remoteDesktopOn ? "on" : "off",
                           "failed_steps": record.failedSteps.joined(separator: ","),
                           "plaintext_password": record.plaintextSecret ? "yes" : "no"])
    }
}

/// The status file's reader.
///
/// FirstLogon.ps1 writes ASCII with CRLF, to status.tmp and then renames it, so a half-written file
/// is never seen. The reader is looser than the writer anyway, since a person or a later script may
/// write it by hand: UTF-8 with or without a BOM, UTF-16LE with a BOM (Windows PowerShell 5.1's
/// `Out-File` default), CRLF or LF; `key=value` split on the first `=`.
enum StatusFile {
    static let path = #"C:\Windows\Temp\winbar-install\status.txt"#
    static let requiredKeys = ["result", "guest_tools", "rdp"]

    /// nil while the install hasn't finished: no file yet, or one without all three required keys.
    /// Takes the raw bytes (utmctl's stdout), not text: UTF-16 must be decoded here.
    static func parse(_ data: Data) -> InstallStatus? {
        var values: [String: String] = [:]
        for line in decode(data).split(whereSeparator: \.isNewline) {
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            guard !key.isEmpty else { continue }
            values[key] = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        }
        guard let result = values["result"], let tools = values["guest_tools"], let rdp = values["rdp"] else { return nil }
        return InstallStatus(ok: result.lowercased() == "ok", guestTools: GuestToolsResult(tools),
                             remoteDesktopOn: rdp.lowercased() == "on", values: values)
    }

    static func decode(_ data: Data) -> String {
        let bytes = [UInt8](data)
        var text: String
        if bytes.starts(with: [0xFF, 0xFE]) {
            text = utf16LE(bytes.dropFirst(2))
        } else if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            text = String(decoding: bytes.dropFirst(3), as: UTF8.self)
        } else if bytes.count >= 2, bytes[0] != 0, bytes[1] == 0 {
            // UTF-16LE that lost its BOM: ASCII text has a NUL in every second byte, UTF-8 never does.
            text = utf16LE(bytes[...])
        } else {
            text = String(decoding: bytes, as: UTF8.self)
        }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        return text
    }

    private static func utf16LE(_ bytes: ArraySlice<UInt8>) -> String {
        var units: [UInt16] = []
        units.reserveCapacity(bytes.count / 2)
        var i = bytes.startIndex
        while i + 1 < bytes.endIndex {
            units.append(UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8)
            i += 2
        }
        return String(decoding: units, as: UTF16.self)
    }
}

/// One reading of a QEMU process's counters, for the progress line ("N GB written") and the stall rule.
struct ProcessSample: Codable, Equatable, Sendable {
    var pid: Int32
    /// When it was taken, on the same clock as `InstallTimes`.
    var time: TimeInterval
    /// Bytes the process has written to disk since it started (`ri_diskio_byteswritten`).
    var bytesWritten: UInt64
    /// User plus system CPU time since it started, in nanoseconds.
    var cpuNanoseconds: UInt64
}

enum ProcessActivity {
    /// Reads `pid`'s counters with `proc_pid_rusage(RUSAGE_INFO_V4)`. Works for any process of the same
    /// user, QEMU included, without Apple Events or UTM's files. nil once the process is gone.
    static func sample(pid: pid_t, at time: TimeInterval) -> ProcessSample? {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard status == 0 else { return nil }
        return ProcessSample(pid: pid, time: time, bytesWritten: info.ri_diskio_byteswritten,
                             cpuNanoseconds: nanoseconds(machTicks: info.ri_user_time + info.ri_system_time))
    }

    /// `ri_user_time` and `ri_system_time` are Mach absolute-time ticks, not nanoseconds: on Apple
    /// silicon one tick is 125/3 ns (measured: 23,966,030 ticks for one second of CPU). Reading them as
    /// nanoseconds would make QEMU look 40 times idler than it is.
    static func nanoseconds(machTicks ticks: UInt64) -> UInt64 {
        let (numer, denom) = (UInt64(timebase.numer), UInt64(timebase.denom))
        guard denom > 0 else { return ticks }
        return ticks / denom * numer + ticks % denom * numer / denom
    }

    static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()
}

/// The samples the stall rule needs: the current QEMU process's, back to just past the stall window.
struct ActivityHistory: Codable, Equatable, Sendable {
    private(set) var samples: [ProcessSample] = []

    /// A new process (the VM was started again) starts a new history: its counters start at zero.
    mutating func add(_ sample: ProcessSample) {
        samples.removeAll { $0.pid != sample.pid || $0.time >= sample.time }
        samples.append(sample)
        // Keep the newest sample at least one window old (the window's start) and everything after it.
        if let start = samples.lastIndex(where: { $0.time <= sample.time - InstallLimits.stallWindow }), start > 0 {
            samples.removeFirst(start)
        }
    }

    var latest: ProcessSample? { samples.last }
}

/// The copy deck's keys for what the limits can report. Ordered by severity.
enum InstallAlert: String, Codable, CaseIterable, Sendable {
    /// Whole install past 2 hours, or the status file still incomplete 30 minutes after the agent
    /// answered (the same wording). The VM keeps running.
    case timeout = "E_TIMEOUT"
    /// Windows restarted into OOBE (2+ restarts) and the guest agent hasn't answered 15 minutes after
    /// the last restart.
    case agentNever = "E_AGENT_NEVER"
    /// The CD prompt wasn't answered 5 minutes after QEMU appeared, or the shell resets ran out
    /// (F-PROMPT). Winbar keeps watching: the person can press a key in the window.
    case bootNoPrompt = "E_BOOT_NO_PROMPT"
    /// Stages 6-8: nothing written and QEMU under 5 % of a core for 10 minutes. Shown once.
    case stall = "W_STALL"
}

/// Every limit the install is judged against, in one place.
enum InstallLimits {
    static let noPrompt: TimeInterval = 5 * 60
    static let stallWindow: TimeInterval = 10 * 60
    /// Of one core.
    static let stallCPU = 0.05
    static let agentSilence: TimeInterval = 15 * 60
    static let whole: TimeInterval = 2 * 60 * 60
    /// The wait for status.txt after the agent answers; stage 9 has no limit of its own.
    static let statusAfterAgent: TimeInterval = 30 * 60
    /// Keypress fallback only: a VM that has written less than this 5 minutes after starting is still
    /// at the prompt or in the firmware. Setup writes gigabytes by then. To calibrate (L8/L9).
    static let fallbackProgressBytes: UInt64 = 64 << 20
    /// A sample older than this says nothing about now (sampling stopped, the Mac slept).
    static let sampleFreshness: TimeInterval = 120
}

/// Where the install stands, as plain values. Times are seconds on one clock; persist wall-clock
/// times (a resume can cross a Mac restart, which resets uptime).
struct InstallTimes: Codable, Equatable, Sendable {
    var stage: CreateStage
    /// Where the 2-hour budget stands: `now` minus the time this job has actually spent watching a
    /// running VM, added up across resumes (`CreateRun.watchedSoFar`). Not the wall clock since
    /// stage 5 began — a night between an interruption and its resume isn't time spent installing,
    /// and measuring it that way made every late resume fail on its first tick.
    var installStartedAt: TimeInterval
    /// When this start's QEMU process appeared.
    var qemuStartedAt: TimeInterval
    /// The serial console is being read; false means the keypress fallback answered (or didn't).
    var serialConsole: Bool
    /// The boot watcher raised F-PROMPT.
    var promptMissed: Bool
    /// Disk boots seen on the console.
    var restarts: Int
    var lastRestartAt: TimeInterval?
    var agentAnsweredAt: TimeInterval?
}

enum InstallWatch {
    /// The most severe limit that has been reached and not already `shown`, or nil. Pure.
    static func evaluate(_ times: InstallTimes, history: [ProcessSample], now: TimeInterval,
                         shown: Set<InstallAlert> = []) -> InstallAlert? {
        let installing: [CreateStage] = [.boot, .copy, .devices, .oobe, .firstLogon]
        let setup: [CreateStage] = [.copy, .devices, .oobe]
        guard installing.contains(times.stage) else { return nil }
        var due: [InstallAlert] = []
        if now - times.installStartedAt >= InstallLimits.whole { due.append(.timeout) }
        if times.stage == .firstLogon, let agent = times.agentAnsweredAt, now - agent >= InstallLimits.statusAfterAgent {
            due.append(.timeout)
        }
        if setup.contains(times.stage), times.agentAnsweredAt == nil, times.restarts >= 2,
           let last = times.lastRestartAt, now - last >= InstallLimits.agentSilence {
            due.append(.agentNever)
        }
        if promptUnanswered(times, history: history, now: now) { due.append(.bootNoPrompt) }
        if setup.contains(times.stage), isStalled(history, now: now) { due.append(.stall) }
        return due.first { !shown.contains($0) }
    }

    static func promptUnanswered(_ times: InstallTimes, history: [ProcessSample], now: TimeInterval) -> Bool {
        guard times.restarts == 0, [.boot, .copy].contains(times.stage) else { return false }
        if times.promptMissed { return true }
        guard now - times.qemuStartedAt >= InstallLimits.noPrompt else { return false }
        if times.stage == .boot { return true }
        // The keypress fallback can't see whether its key landed, but the disk can: nearly nothing
        // written means the VM is still at the prompt or in the firmware.
        guard !times.serialConsole, let latest = history.last, now - latest.time <= InstallLimits.sampleFreshness,
              latest.time - times.qemuStartedAt >= InstallLimits.noPrompt - InstallLimits.sampleFreshness
        else { return false }
        return latest.bytesWritten < InstallLimits.fallbackProgressBytes
    }

    /// Nothing written, and under 5 % of a core on average, over the last 10 minutes of samples from
    /// one process. Samples must be fresh, and the window continuous: a gap in sampling proves nothing.
    /// `ActivityHistory.add` keeps exactly one sample from before the window, so a Mac that slept for
    /// half an hour leaves a window of two samples straddling the sleep — both with the same counters,
    /// because QEMU was frozen, not stalled. That is not a stall, and the person would hear about it
    /// seconds after waking, burning the one W_STALL the job gets.
    static func isStalled(_ history: [ProcessSample], now: TimeInterval) -> Bool {
        guard let latest = history.last, now - latest.time <= InstallLimits.sampleFreshness,
              let startIndex = history.lastIndex(where: { $0.time <= latest.time - InstallLimits.stallWindow })
        else { return false }
        let window = history[startIndex...]
        let start = window.first!
        guard zip(window, window.dropFirst()).allSatisfy({ $1.time - $0.time <= InstallLimits.sampleFreshness }) else {
            return false
        }
        guard window.allSatisfy({ $0.pid == latest.pid && $0.bytesWritten == latest.bytesWritten }),
              latest.cpuNanoseconds >= start.cpuNanoseconds, latest.time > start.time else { return false }
        let cores = Double(latest.cpuNanoseconds - start.cpuNanoseconds) / 1e9 / (latest.time - start.time)
        return cores < InstallLimits.stallCPU
    }
}
