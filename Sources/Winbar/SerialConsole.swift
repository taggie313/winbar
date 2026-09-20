import Darwin
import Foundation

// The VM's serial console during `winbar create`: edk2 prints its boot progress there (ArmVirtQemu puts
// the PL011 in ConIn/ConOut), and so does cdboot.efi's "Press any key to boot from CD or DVD". Winbar
// reads it to answer that prompt with one key and to count restarts. Only firmware text ever crosses
// it: Windows doesn't use the port (no EMS), and Winbar only ever types a space or "reset".

/// Plain text from the console: whole lines, and the line still being written.
enum SerialText: Equatable {
    case line(String)
    /// The unfinished current line, reported whenever it grows. Prompts live here: they wait for a
    /// key without ending their line.
    case partial(String)
}

/// Turns the console's byte stream into plain lines.
///
/// ANSI escapes are dropped, and CR or LF ends a line. So do the escapes that move the cursor to a new
/// place or clear the screen (`ESC [ … H`, `f`, `J`): edk2 draws with them, and without the break the
/// next boot's first line would run on from the last prompt. Escapes and lines may be split across
/// reads anywhere.
struct SerialTextSplitter {
    /// A stream with no line breaks (a prompt's dots, binary noise) can't grow without limit.
    static let maxLine = 4096

    private enum Mode { case text, escape, csi, charset }
    private var mode = Mode.text
    private var line: [UInt8] = []
    private var reported: [UInt8] = []

    mutating func feed<Bytes: Sequence>(_ bytes: Bytes) -> [SerialText] where Bytes.Element == UInt8 {
        var out: [SerialText] = []
        for byte in bytes {
            switch mode {
            case .text:
                switch byte {
                case 0x1B: mode = .escape
                case 0x0A, 0x0D: endLine(&out)
                case 0x09: append(0x20, &out)
                case 0x00..<0x20, 0x7F: break   // BEL, backspace, NUL…: nothing worth matching
                default: append(byte, &out)
                }
            case .escape:
                switch byte {
                case UInt8(ascii: "["): mode = .csi
                case UInt8(ascii: "("), UInt8(ascii: ")"): mode = .charset   // ESC ( 0 and friends: one more byte
                case 0x1B: mode = .escape
                default: mode = .text                                          // two-byte escapes (ESC c, ESC 7…)
                }
            case .csi:
                switch byte {
                case 0x40...0x7E:
                    mode = .text
                    if byte == UInt8(ascii: "H") || byte == UInt8(ascii: "f") || byte == UInt8(ascii: "J") { endLine(&out) }
                case 0x0A, 0x0D: endLine(&out)   // a control inside an escape still takes effect
                case 0x1B: mode = .escape
                default: break                   // parameters and intermediates
                }
            case .charset:
                mode = .text
            }
        }
        if !line.isEmpty, line != reported, !isBlank(line) {
            out.append(.partial(String(decoding: line, as: UTF8.self)))
            reported = line
        }
        return out
    }

    /// The unfinished line, for a final log entry when the console closes.
    var pending: String? { isBlank(line) ? nil : String(decoding: line, as: UTF8.self) }

    private mutating func append(_ byte: UInt8, _ out: inout [SerialText]) {
        line.append(byte)
        if line.count >= SerialTextSplitter.maxLine { endLine(&out) }
    }

    private mutating func endLine(_ out: inout [SerialText]) {
        if !isBlank(line) { out.append(.line(String(decoding: line, as: UTF8.self))) }
        line.removeAll(keepingCapacity: true)
        reported.removeAll()
    }

    private func isBlank(_ bytes: [UInt8]) -> Bool { bytes.allSatisfy { $0 == 0x20 } }
}

/// Something the boot watcher noticed that the install should know about. Raised once each.
enum BootFlag: String, Codable, Sendable {
    /// F-BOOT: after a disk boot, the CD prompt (or the firmware shell) came back: Windows Boot Manager
    /// didn't load. Never answered, since a key there would start Setup over.
    case bootAfterDisk = "F-BOOT"
    /// F-PROMPT: the prompt was missed, and the firmware ended in its shell again after two resets.
    case promptMissed = "F-PROMPT"
    /// F-SETUP-ERR: the prompt came back without a disk boot after an answer that started the installer:
    /// Setup gave up in WinPE. Not answered again.
    case setupRestarted = "F-SETUP-ERR"
}

enum BootAction: Equatable {
    /// Type `BootWatcher.answerKey` now; the number is how many answers this start has sent.
    case answerPrompt(Int)
    /// Type `BootWatcher.resetCommand` into the firmware shell now; the number counts resets.
    case resetFirmware(Int)
    /// The firmware started Windows from the disk; the number is the total so far (restarts).
    case diskBoot(Int)
    /// The firmware started one of the USB CDs.
    case cdBoot
    /// The firmware started something else (its shell, say), by its boot option description.
    case otherBoot(String)
    /// `BdsDxe: failed to load/start …`, for the log. The blank disk's failure on the first boot is expected.
    case bootFailed(String)
    case flag(BootFlag)

    /// What to type for this action, if anything.
    var keys: String? {
        switch self {
        case .answerPrompt: return BootWatcher.answerKey
        case .resetFirmware: return BootWatcher.resetCommand
        default: return nil
        }
    }
}

/// Decides, from the console's text, when to answer the CD prompt and how far the install has got.
/// Pure: it reads no clock and does no I/O. Times are seconds on any monotonic clock.
///
/// Rules:
/// - `BdsDxe: starting Boot#### … USB(…)`, before any disk boot: the CD's bootloader is running now,
///   so press a key without waiting to be asked. Proven live (2026-09-20): cdboot.efi prints "Press
///   any key to boot from CD or DVD" on the graphical console only — never on the serial port, though
///   the firmware's own messages and the EFI shell both appear there — and gives up 3 seconds later
///   with `failed to start … : Time out`. Waiting for text that never comes missed the window twice
///   and dropped the VM into the EFI shell. So one burst of keys covers the whole window, and counts
///   as a single answer.
/// - `Press any key to boot from CD or DVD`, if it ever does appear: before any disk boot, answer it
///   with a space, 0.3 s later; if its dots keep coming 3 s after that, once more; and once more if a `reset` brought the
///   prompt back after an answer that never landed. Never a third time in one start. A prompt that
///   comes back after an answer that did land is Setup restarting itself (F-SETUP-ERR): flag it, but
///   don't answer, or Setup starts over. After a disk boot, never (F-BOOT): a key there would restart
///   Setup, which wipes the disk.
/// - `BdsDxe: starting Boot#### "desc" from path`: "Windows Boot Manager", `NVMe(` or `HD(…` is a disk
///   boot (a restart: 0 = copying, 1 = setting up devices, 2+ = getting ready); `USB(` is a CD.
/// - The firmware shell (`Shell>`, or its startup.nsh countdown) means the prompt was missed and every
///   boot option failed: type `reset` (at most twice per start), then F-PROMPT.
///
/// Why a space: cdboot.efi takes any key, while in edk2's BDS Enter is the CONTINUE key and F2/Esc
/// open the Boot Manager menu (PlatformBm.c:930-965). Why `reset` waits for `Shell>`: a key pressed
/// during the startup.nsh countdown is consumed by the countdown, so "reset" would arrive as "eset".
struct BootWatcher {
    static let answerKey = " "
    static let resetCommand = "reset\r"
    static let answerDelay: TimeInterval = 0.3
    static let dotsGrace: TimeInterval = 3
    /// The first key goes 0.5 s after the CD's bootloader starts (it has to reach its own key wait),
    /// then every 0.4 s until the window closes. cdboot.efi gives up after 3 s, measured live.
    static let cdBootDelay: TimeInterval = 0.5
    static let cdBootWindow: TimeInterval = 3.4
    static let pressEvery: TimeInterval = 0.4
    static let maxAnswers = 2
    static let maxResets = 2
    /// When the shell's countdown line shows no number: edk2's default is 5 s.
    static let shellCountdownFallback: TimeInterval = 10

    /// Carried over when Winbar resumes an install: after a disk boot the prompt is never answered.
    private(set) var diskBoots: Int
    /// Per QEMU start (a guest reboot keeps the same QEMU process, so these span restarts).
    private(set) var answers = 0
    private(set) var shellResets = 0
    /// While a burst is running, later presses are the same answer, not new ones.
    private var burstEndsAt: TimeInterval?
    private var burstPresses = 0
    private(set) var flags: Set<BootFlag> = []

    var diskBootSeen: Bool { diskBoots > 0 }

    /// The stage the restarts suggest. A heuristic: the guest agent answering always
    /// moves the install on to first_logon, whatever the count.
    var installStage: CreateStage {
        switch diskBoots {
        case 0: return .copy
        case 1: return .devices
        default: return .oobe
        }
    }

    /// What the current, unfinished line has already triggered, so its later (longer) copies and its
    /// final complete copy don't trigger it again.
    private struct LineMarks {
        var prompt = false
        var dots = 0
        var answered = false
        var shell = false
    }

    private var current = LineMarks()
    private var answerDueAt: TimeInterval?
    private var lastAnswerAt: TimeInterval?
    /// A CD boot failed after the last answer, so the key wasn't taken and the installer never ran.
    private var answerFailed = false
    private var resetDueAt: TimeInterval?
    /// Acted on the shell; ignore it until the firmware boots something again.
    private var shellHandled = false

    init(diskBoots: Int = 0) { self.diskBoots = diskBoots }

    mutating func receive(_ texts: [SerialText], at now: TimeInterval) -> [BootAction] {
        var actions = tick(at: now)
        for text in texts {
            switch text {
            case .partial(let s):
                actions += examine(s, complete: false, at: now)
            case .line(let s):
                actions += examine(s, complete: true, at: now)
                current = LineMarks()
            }
        }
        return actions
    }

    /// Call often (every 0.1 s): the answer and the shell reset wait for their moment.
    mutating func tick(at now: TimeInterval) -> [BootAction] {
        var actions: [BootAction] = []
        if let due = answerDueAt, now >= due {
            answerDueAt = nil
            actions += answer(at: now)
        }
        if let due = resetDueAt, now >= due {
            actions += shell()
        }
        return actions
    }

    private static let bootLine = #/(?i)BdsDxe: (loading|starting|failed to load|failed to start) (Boot[0-9A-F]{4}) "(.*)" from (.*)$/#
    private static let countdown = #/(?i)press esc in (\d+) seconds? to skip startup\.nsh/#

    private mutating func examine(_ text: String, complete: Bool, at now: TimeInterval) -> [BootAction] {
        var actions: [BootAction] = []
        let lower = text.lowercased()

        if let range = lower.range(of: "press any key to boot from cd or dvd") {
            let dots = lower[range.upperBound...].filter { $0 == "." }.count
            if !current.prompt {
                current.prompt = true
                current.dots = dots
                actions += promptAppeared(at: now)
            } else if dots > current.dots {
                current.dots = dots
                // Still counting down 3 s after the answer: the key didn't land. One more.
                if current.answered, let last = lastAnswerAt, now >= last + BootWatcher.dotsGrace, answerDueAt == nil {
                    actions += answer(at: now)
                }
            }
        }

        if lower.contains("shell>") {
            if !current.shell {
                current.shell = true
                actions += shell()
            }
        } else if resetDueAt == nil, !shellHandled, lower.contains("startup.nsh") {
            let seconds = text.firstMatch(of: BootWatcher.countdown).flatMap { Double(String($0.1)) }
            resetDueAt = now + (seconds.map { $0 + 2 } ?? BootWatcher.shellCountdownFallback)
        }

        // Boot lines only once whole: a partial one may have its path cut short.
        if complete, let match = text.firstMatch(of: BootWatcher.bootLine) {
            // The firmware is booting something: whatever prompt or shell was on screen is gone.
            answerDueAt = nil
            burstEndsAt = nil
            burstPresses = 0
            resetDueAt = nil
            shellHandled = false
            let verb = match.1.lowercased(), description = String(match.3), path = String(match.4)
            if verb == "starting" {
                switch BootWatcher.target(description: description, path: path) {
                case .disk:
                    diskBoots += 1
                    actions.append(.diskBoot(diskBoots))
                case .cd:
                    actions.append(.cdBoot)
                    // The bootloader is waiting for a key right now, on a console Winbar can't read.
                    // The same rule as the prompt text: a CD boot after an answer that landed is Setup
                    // starting itself over, and pressing a key there reinstalls Windows.
                    if !diskBootSeen, answers > 0, !answerFailed {
                        actions += raise(.setupRestarted)
                    } else if !diskBootSeen, answers < BootWatcher.maxAnswers {
                        answerDueAt = now + BootWatcher.cdBootDelay
                        burstEndsAt = now + BootWatcher.cdBootWindow
                        burstPresses = 0
                    }
                case .other:
                    actions.append(.otherBoot(description))
                }
            } else if verb.hasPrefix("failed") {
                if lastAnswerAt != nil, path.lowercased().contains("usb(") { answerFailed = true }
                actions.append(.bootFailed(text))
            }
        }
        return actions
    }

    enum Target { case disk, cd, other }

    static func target(description: String, path: String) -> Target {
        let description = description.lowercased(), path = path.lowercased()
        if description.contains("windows boot manager") || path.contains("nvme(") || path.hasPrefix("hd(") { return .disk }
        if path.contains("usb(") { return .cd }
        return .other
    }

    private mutating func promptAppeared(at now: TimeInterval) -> [BootAction] {
        resetDueAt = nil
        shellHandled = false
        if diskBootSeen {
            answerDueAt = nil
            return raise(.bootAfterDisk)
        }
        // A new prompt after an answer in this start. If that answer started the installer, Setup came
        // back here without installing: flag it, and don't start it over. If the answer provably never
        // landed — the CD boot timed out and Winbar typed `reset` to get the firmware back here — this
        // is the prompt that reset asked for, so answer it: otherwise the second of the two allowed
        // answers was only ever reachable inside the first prompt episode, and the install stalled at a
        // prompt nobody was going to press a key at.
        if answers > 0, !answerFailed { return raise(.setupRestarted) }
        if answers < BootWatcher.maxAnswers { answerDueAt = now + BootWatcher.answerDelay }
        return []
    }

    private mutating func answer(at now: TimeInterval) -> [BootAction] {
        guard !diskBootSeen else { return [] }
        if burstPresses == 0 {
            guard answers < BootWatcher.maxAnswers else { return [] }
            answers += 1
        }
        burstPresses += 1
        lastAnswerAt = now
        answerFailed = false
        if current.prompt { current.answered = true }
        // Keep pressing while the bootloader's window is open; one key may arrive before it starts
        // listening, and the firmware drops keys typed during a countdown.
        if let end = burstEndsAt, now + BootWatcher.pressEvery < end {
            answerDueAt = now + BootWatcher.pressEvery
        } else {
            // The burst is over: the next press is a new answer, and counts against maxAnswers again.
            burstEndsAt = nil
            burstPresses = 0
        }
        return [.answerPrompt(answers)]
    }

    private mutating func shell() -> [BootAction] {
        resetDueAt = nil
        guard !shellHandled else { return [] }
        shellHandled = true
        answerDueAt = nil
        if diskBootSeen { return raise(.bootAfterDisk) }
        guard shellResets < BootWatcher.maxResets else { return raise(.promptMissed) }
        shellResets += 1
        return [.resetFirmware(shellResets)]
    }

    private mutating func raise(_ flag: BootFlag) -> [BootAction] {
        flags.insert(flag).inserted ? [.flag(flag)] : []
    }
}

/// The host end of the VM's serial port: the pty UTM reports for it (`CreateScripts.serialAddress`).
///
/// Opened `O_NOCTTY` so it never becomes this process's controlling terminal, `O_NONBLOCK` so reads
/// never hang, and set raw: in the default cooked mode the tty would echo everything the firmware
/// prints straight back into the guest as keystrokes. It stays open for the whole install (a guest
/// reboot keeps the same QEMU process and pty); QEMU discards output while nobody has it open.
final class SerialConsole {
    enum Event {
        case text([SerialText])
        /// The console is gone (QEMU exited, most likely). No more events follow.
        case closed(String)
    }

    let path: String
    /// Every event and every watcher decision happens on this queue.
    let queue = DispatchQueue(label: "net.elusive.winbar.serial")

    private var fd: Int32
    private var source: DispatchSourceRead?
    private var splitter = SerialTextSplitter()
    private let log: SerialLog?

    private init(path: String, fd: Int32, log: SerialLog?) {
        self.path = path
        self.fd = fd
        self.log = log
        queue.setSpecific(key: SerialConsole.queueKey, value: ObjectIdentifier(self))
    }

    private static let queueKey = DispatchSpecificKey<ObjectIdentifier>()

    /// Runs `body` on `queue`, directly when already there: handlers call `write` and `close`, and a
    /// `queue.sync` from the queue itself would deadlock.
    func sync<T>(_ body: () -> T) -> T {
        DispatchQueue.getSpecific(key: SerialConsole.queueKey) == ObjectIdentifier(self) ? body() : queue.sync(execute: body)
    }

    deinit { close() }

    /// `logURL`: where to keep what the console said (the create log's `.serial.log`). Firmware text
    /// only, plus a note of each key Winbar typed.
    static func open(path: String, logURL: URL? = nil) -> Result<SerialConsole, WinbarError> {
        let failed = { (reason: String) in WinbarError("Couldn't open the VM's serial console", "\(path): \(reason)") }
        guard path.hasPrefix("/dev/") else { return .failure(failed("not a device")) }
        let fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { return .failure(failed(String(cString: strerror(errno)))) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFCHR, isatty(fd) == 1 else {
            Darwin.close(fd)
            return .failure(failed("not a terminal"))
        }
        var settings = termios()
        guard tcgetattr(fd, &settings) == 0 else {
            let reason = String(cString: strerror(errno))
            Darwin.close(fd)
            return .failure(failed(reason))
        }
        cfmakeraw(&settings)
        guard tcsetattr(fd, TCSANOW, &settings) == 0 else {
            let reason = String(cString: strerror(errno))
            Darwin.close(fd)
            return .failure(failed(reason))
        }
        return .success(SerialConsole(path: path, fd: fd, log: logURL.flatMap(SerialLog.init)))
    }

    /// Starts reading. `handler` runs on `queue`.
    func start(_ handler: @escaping (Event) -> Void) {
        queue.async { [self] in
            guard source == nil, fd >= 0 else { return }
            let readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            readSource.setEventHandler { [weak self] in self?.readAvailable(handler) }
            // Cancelling is asynchronous, so the descriptor is closed here rather than beside the
            // cancel: closing it earlier could leave the source watching a number macOS has since
            // handed to something else.
            let open = fd
            readSource.setCancelHandler { Darwin.close(open) }
            source = readSource
            readSource.resume()
        }
    }

    private func readAvailable(_ handler: (Event) -> Void) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while fd >= 0 {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                let texts = splitter.feed(buffer[0..<count])
                for case .line(let line) in texts { log?.write(line) }
                if !texts.isEmpty { handler(.text(texts)) }
                continue
            }
            if count < 0, errno == EINTR { continue }
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK { return }
            // 0 or EIO: QEMU closed its end.
            let reason = count == 0 ? "the console closed" : String(cString: strerror(errno))
            if let pending = splitter.pending { log?.write(pending) }
            log?.note("console closed: \(reason)")
            closeOnQueue()
            handler(.closed(reason))
            return
        }
    }

    /// Types `text` into the guest. Only ever a space or "reset": nothing typed here may be secret,
    /// because it's logged. Short, so a non-blocking write fits the tty buffer; a full buffer gets a
    /// few brief retries.
    @discardableResult
    func write(_ text: String) -> Bool {
        sync {
            var bytes = Array(text.utf8)[...]
            var tries = 0
            while !bytes.isEmpty, fd >= 0 {
                let written = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
                if written > 0 {
                    bytes = bytes.dropFirst(written)
                } else if written < 0, errno == EINTR {
                    continue
                } else if written < 0, errno == EAGAIN || errno == EWOULDBLOCK, tries < 20 {
                    tries += 1
                    usleep(50_000)
                } else {
                    break
                }
            }
            let done = bytes.isEmpty
            log?.note("typed \(text == " " ? "a space" : text.trimmingCharacters(in: .whitespacesAndNewlines))\(done ? "" : " (failed)")")
            return done
        }
    }

    func close() { sync { closeOnQueue() } }

    private func closeOnQueue() {
        if let source {
            self.source = nil
            source.cancel()      // its cancel handler closes the descriptor
            fd = -1
        } else if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }

    /// Reads the console, feeds a `BootWatcher`, types what it decides, and reports every action.
    ///
    /// `onAction` and `onClosed` run on `queue`. `clock` is monotonic (a guest reboot mustn't be
    /// mistaken for time travel); the watcher only uses differences.
    func watchBoot(_ watcher: BootWatcher, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                   onAction: @escaping (BootAction) -> Void, onClosed: @escaping (String) -> Void) -> SerialBootWatch {
        let watch = SerialBootWatch(console: self, watcher: watcher, clock: clock, onAction: onAction, onClosed: onClosed)
        watch.start()
        return watch
    }
}

/// A running boot watch: the console, its watcher and a 0.1 s tick for the watcher's delayed answers.
final class SerialBootWatch {
    private let console: SerialConsole
    private var watcher: BootWatcher
    private let clock: () -> TimeInterval
    private let onAction: (BootAction) -> Void
    private let onClosed: (String) -> Void
    private var timer: DispatchSourceTimer?
    private var lastTextAt: TimeInterval?

    fileprivate init(console: SerialConsole, watcher: BootWatcher, clock: @escaping () -> TimeInterval,
                     onAction: @escaping (BootAction) -> Void, onClosed: @escaping (String) -> Void) {
        self.console = console
        self.watcher = watcher
        self.clock = clock
        self.onAction = onAction
        self.onClosed = onClosed
    }

    fileprivate func start() {
        console.start { [weak self] event in
            guard let self else { return }
            switch event {
            case .text(let texts):
                let now = clock()
                lastTextAt = now
                perform(watcher.receive(texts, at: now))
            case .closed(let reason):
                stopTimer()
                onClosed(reason)
            }
        }
        let tick = DispatchSource.makeTimerSource(queue: console.queue)
        tick.schedule(deadline: .now() + 0.1, repeating: 0.1)
        tick.setEventHandler { [weak self] in
            guard let self else { return }
            perform(watcher.tick(at: clock()))
        }
        timer = tick
        tick.resume()
    }

    private func perform(_ actions: [BootAction]) {
        for action in actions {
            if let keys = action.keys { console.write(keys) }
            onAction(action)
        }
    }

    /// The watcher as it stands (for state.json), and when the console last said anything (nothing
    /// within 20 s of QEMU starting means: use the keypress fallback).
    var snapshot: (watcher: BootWatcher, lastTextAt: TimeInterval?) {
        console.sync { (watcher, lastTextAt) }
    }

    func stop() {
        console.sync { stopTimer() }
        console.close()
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }
}

/// The serial log: complete lines with the time since the console opened, and notes of what Winbar
/// typed. Capped, since a console that prints without end shouldn't fill the disk.
///
/// A line is written when it ends, so a prompt waiting for a key appears after the note about the
/// key Winbar typed into it. The times tell the real order.
private final class SerialLog {
    static let limit = 8 << 20
    private let handle: FileHandle
    private let opened = ProcessInfo.processInfo.systemUptime
    private var written = 0

    init?(_ url: URL) {
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        guard fd >= 0 else { return nil }
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    func write(_ line: String) { append(line) }

    func note(_ text: String) { append("> " + text) }

    private func append(_ text: String) {
        guard written < SerialLog.limit else { return }
        let stamp = String(format: "[%8.1f] ", ProcessInfo.processInfo.systemUptime - opened)
        var entry = stamp + text + "\n"
        if written + entry.utf8.count >= SerialLog.limit { entry = stamp + "> log limit reached\n" }
        written += entry.utf8.count
        try? handle.write(contentsOf: Data(entry.utf8))
    }
}
