import Foundation
import Darwin

// What `winbar create` puts on the screen: the terminal it asks the password on, the checklist the
// person edits, and the progress lines while Windows installs.

/// The controlling terminal, opened directly as `/dev/tty` so the password prompt still reaches the
/// person when stdout is a pipe (`winbar create … | tee log`), and so nothing typed here can end up
/// in a redirected file. No controlling terminal at all is E_NO_TTY.
final class TTY {
    private var fd: Int32

    private init(fd: Int32) { self.fd = fd }

    static func open() -> TTY? {
        let fd = Darwin.open("/dev/tty", O_RDWR | O_NOCTTY)
        guard fd >= 0 else { return nil }
        guard isatty(fd) == 1 else {
            Darwin.close(fd)
            return nil
        }
        return TTY(fd: fd)
    }

    func write(_ text: String) {
        var bytes = Array(text.utf8)[...]
        while !bytes.isEmpty, fd >= 0 {
            let written = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if written > 0 {
                bytes = bytes.dropFirst(written)
            } else if written < 0, errno == EINTR {
                continue
            } else {
                return
            }
        }
    }

    /// Asks for a secret with the echo off, restoring the terminal whatever happens. The line is
    /// read a byte at a time so nothing is buffered anywhere but in the string that is returned.
    func readPassword(_ prompt: String) -> String? {
        guard fd >= 0 else { return nil }
        write(prompt)
        var saved = termios()
        let hasSettings = tcgetattr(fd, &saved) == 0
        if hasSettings {
            var quiet = saved
            quiet.c_lflag &= ~UInt(ECHO)
            quiet.c_lflag |= UInt(ECHONL)
            _ = tcsetattr(fd, TCSAFLUSH, &quiet)
        }
        defer {
            if hasSettings { _ = tcsetattr(fd, TCSAFLUSH, &saved) }
        }
        var bytes: [UInt8] = []
        var byte: UInt8 = 0
        while true {
            let count = Darwin.read(fd, &byte, 1)
            if count < 0, errno == EINTR { continue }
            guard count == 1 else { break }
            if byte == 0x0A || byte == 0x0D { break }
            if byte == 0x7F || byte == 0x08 {   // backspace, for a person who mistypes
                if !bytes.isEmpty { bytes.removeLast() }
                continue
            }
            if byte == 0x03 { return nil }      // Ctrl-C at the prompt: nothing has been created
            bytes.append(byte)
        }
        if !hasSettings { write("\n") }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// A visible line (the checklist's answers), from the same terminal.
    func readLine() -> String? {
        var bytes: [UInt8] = []
        var byte: UInt8 = 0
        while true {
            let count = Darwin.read(fd, &byte, 1)
            if count < 0, errno == EINTR { continue }
            guard count == 1 else { return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self) }
            if byte == 0x0A { break }
            bytes.append(byte)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    func close() {
        if fd >= 0 { Darwin.close(fd) }
        fd = -1
    }

    deinit { close() }
}

/// The checklist screen: the VM's four fields, Rufus's eight rows and Winbar's five, each
/// with a number to change it and `?N` for why it's there. Rendering is pure, so the screen can be
/// tested without a terminal.
struct Checklist {
    var plan: CreatePlan
    let image: WindowsImageInfo
    let mac: MacFacts
    let reading: Regional.Reading?
    /// Warnings already printed, so each is shown once.
    private var shown: Set<String> = []

    enum Outcome { case quit, go(CreatePlan) }

    init(plan: CreatePlan, image: WindowsImageInfo, mac: MacFacts, reading: Regional.Reading?) {
        self.plan = plan
        self.image = image
        self.mac = mac
        self.reading = reading
    }

    // MARK: Rows

    /// A row's meaning: which option it ticks, or which field it edits.
    enum Row: Equatable {
        case option(CreateOption)
        case user
        case edition
        case computerName
    }

    static let rows: [Row] = [
        .option(.bypassRequirements), .option(.noOnlineAccount), .user, .option(.regionalFromMac),
        .option(.skipPrivacy), .edition, .option(.noBitLocker), .option(.qol), .option(.autologon),
        .option(.remoteDesktop), .option(.guestTools), .option(.winbarTuning), .computerName,
    ]

    /// 1-based, as the screen numbers them.
    static func row(_ number: Int) -> Row? {
        guard number >= 1, number <= rows.count else { return nil }
        return rows[number - 1]
    }

    static func number(of row: Row) -> Int { (rows.firstIndex(of: row) ?? 0) + 1 }

    // MARK: Rendering

    func render() -> String {
        var lines: [String] = []
        lines.append(CreateCopy.winTitle)
        lines.append(field("n", "Name", plan.vmName, ""))
        lines.append(field("c", "vCPUs", String(plan.cores), "your Mac's top-tier cores"))
        lines.append(field("m", "Memory", "\(plan.memoryMiB / 1024) GB",
                           "recommended for a Mac with \(mac.memoryGB) GB"))
        lines.append(field("d", "Disk", "\(plan.diskGiB) GB", "the file grows as Windows uses it"))
        lines.append("")
        lines.append("Windows User Experience: customize Windows installation?")
        for (index, row) in Checklist.rows.enumerated() {
            if index == 8 { lines.append("Winbar") }
            lines.append(contentsOf: render(row: row, number: index + 1))
        }
        lines.append("")
        lines.append("Type a number or letter to change it, ? and a number for why (?7), Enter to go, q to quit:")
        return lines.joined(separator: "\n")
    }

    private func field(_ key: String, _ label: String, _ value: String, _ note: String) -> String {
        let left = "  \(key)  " + label.padding(toLength: 10, withPad: " ", startingAt: 0)
        let shownValue = note.isEmpty ? value : value.padding(toLength: 9, withPad: " ", startingAt: 0) + note
        return left + shownValue
    }

    private func render(row: Row, number: Int) -> [String] {
        let box: String
        let label: String
        var extra: [String] = []
        switch row {
        case .option(let option):
            box = plan.has(option) ? "[x]" : "[ ]"
            label = Checklist.label(option, plan: plan)
            if option == .regionalFromMac, plan.has(option) {
                extra.append(String(repeating: " ", count: 9) + (reading.map(Checklist.regionSummary) ?? ""))
            }
        case .user:
            box = "[x]"
            label = Checklist.label(.localAccount, plan: plan)
        case .edition:
            box = "[x]"
            label = "\(CreateCopy.installLabel) \(plan.edition.displayName)"
        case .computerName:
            box = "   "
            label = "Computer name: \(plan.computerName) (your Mac reaches it as "
                + "\(CreateChoices.hostName(computerName: plan.computerName)))"
        }
        let locked = Checklist.isLocked(row)
        var line = String(format: "%4d ", number) + box + " " + label
        if locked { line = line.padding(toLength: max(line.count + 1, 70), withPad: " ", startingAt: 0) + "always on" }
        return [line] + extra
    }

    static func isLocked(_ row: Row) -> Bool {
        switch row {
        case .option(let option): return option.isLocked
        case .user, .edition: return true
        case .computerName: return false
        }
    }

    /// The checklist labels, from the deck the window reads. Where the window puts a field
    /// beside the label, the screen prints the value after it instead.
    static func label(_ option: CreateOption, plan: CreatePlan) -> String {
        let label = CreateCopy.label(option)
        return option == .localAccount ? "\(label) \(plan.userName)" : label
    }

    /// N_REGIONAL: what the Mac's values become in Windows, including the zone mapping.
    static func regionSummary(_ reading: Regional.Reading) -> String {
        let name = Locale.current.localizedString(forIdentifier: reading.values.userLocale) ?? reading.values.userLocale
        let keyboard = reading.values.inputLocale.map { "\(reading.macKeyboard) (\($0))" } ?? reading.macKeyboard
        let zone = reading.values.timeZone.map { "\(reading.ianaZone) → \($0)" }
            ?? "\(reading.ianaZone) → Windows' default time zone"
        return "\(name) · \(keyboard) · \(zone)"
    }

    // MARK: The loop

    /// Shows the list, applies what the person types, and returns the plan they pressed Enter on.
    mutating func run(tty: TTY? = nil) -> Outcome {
        let input = tty
        while true {
            print(render())
            for warning in newWarnings() { print("     " + CreateCopy.wrap(warning, width: CreateCopy.width - 5, indent: "     ")) }
            print("> ", terminator: "")
            fflush(stdout)
            guard let typed = (input?.readLine() ?? Swift.readLine())?.trimmingCharacters(in: .whitespaces) else {
                return .go(plan)
            }
            if typed.isEmpty { return .go(plan) }
            if typed.lowercased() == "q" { return .quit }
            if typed.hasPrefix("?") {
                let key = typed.dropFirst().trimmingCharacters(in: .whitespaces)
                print("   " + CreateCopy.wrap(Checklist.tooltip(key, plan: plan, mac: mac) ?? "No such row.",
                                              width: CreateCopy.width - 3, indent: "   "))
                continue
            }
            apply(typed, input: input)
        }
    }

    /// Warnings that apply now and haven't been shown yet. The list itself is `planWarnings`, which
    /// a run that skips this screen (`--yes`) prints instead, so neither way leaves one out.
    private mutating func newWarnings() -> [String] {
        var texts: [String] = []
        for warning in CreateCLI.planWarnings(plan, mac: mac) where shown.insert(String(describing: warning)).inserted {
            texts.append(warning.description)
        }
        return texts
    }

    private mutating func apply(_ typed: String, input: TTY?) {
        func ask(_ prompt: String) -> String? {
            print(prompt, terminator: "")
            fflush(stdout)
            return (input?.readLine() ?? Swift.readLine())?.trimmingCharacters(in: .whitespaces)
        }
        func number(_ prompt: String) -> Int? { ask(prompt).flatMap { $0.isEmpty ? nil : Int($0) } }

        switch typed.lowercased() {
        case "n":
            guard let name = ask("   Name [\(plan.vmName)]: "), !name.isEmpty else { return }
            if let problem = CreateChoices.vmNameProblem(name) { print("   " + problem.description); return }
            plan.vmName = name
            plan.computerName = CreateChoices.deriveComputerName(vmName: name, userName: plan.userName)
        case "c":
            let range = CreateChoices.coresRange(mac)
            guard let value = number("   vCPUs [\(plan.cores)] (\(range.lowerBound) to \(range.upperBound)): ") else { return }
            if let problem = CreateChoices.coresProblem(value, mac: mac) { print("   " + problem.description); return }
            plan.cores = value
        case "m":
            let range = CreateChoices.memoryRangeGB(mac)
            guard let value = number("   Memory in GB [\(plan.memoryMiB / 1024)] (\(range.lowerBound) to \(range.upperBound)): ")
            else { return }
            if let problem = CreateChoices.memoryProblem(value, mac: mac) { print("   " + problem.description); return }
            plan.memoryMiB = value * 1024
        case "d":
            let range = CreateChoices.diskRangeGB
            guard let value = number("   Disk in GB [\(plan.diskGiB)] (\(range.lowerBound) to \(range.upperBound)): ")
            else { return }
            if let problem = CreateChoices.diskProblem(value) { print("   " + problem.description); return }
            plan.diskGiB = value
        default:
            guard let index = Int(typed), let row = Checklist.row(index) else {
                print("   Type a row's number (1 to \(Checklist.rows.count)), n, c, m, d, ?N, Enter or q.")
                return
            }
            applyRow(row, ask: ask, number: number)
        }
    }

    private mutating func applyRow(_ row: Row, ask: (String) -> String?, number: (String) -> Int?) {
        switch row {
        case .option(let option) where option.isLocked:
            print("   " + CreateCopy.wrap(Checklist.alwaysOn(option), width: CreateCopy.width - 3, indent: "   "))
        case .option(let option):
            if plan.has(option) { plan.options.remove(option) } else { plan.options.insert(option) }
            if option == .regionalFromMac {
                plan.regional = plan.has(option) ? reading?.values : nil
            }
        case .user:
            guard let name = ask("   User name [\(plan.userName)]: "), !name.isEmpty else { return }
            if let problem = CreateChoices.userNameProblem(name, computerName: plan.computerName) {
                print("   " + problem.description)
                return
            }
            plan.userName = name
        case .computerName:
            guard let name = ask("   Computer name [\(plan.computerName)]: "), !name.isEmpty else { return }
            if let problem = CreateChoices.computerNameProblem(name, userName: plan.userName) {
                print("   " + problem.description)
                return
            }
            plan.computerName = name
        case .edition:
            let list = image.editions.enumerated()
                .map { "\($0.offset + 1) \($0.element.displayName)\($0.element.index == plan.edition.index ? " (current)" : "")" }
                .joined(separator: "   ")
            print("   Editions on this ISO: \(list)")
            let current = (image.editions.firstIndex { $0.index == plan.edition.index } ?? 0) + 1
            guard let choice = number("   Edition [\(current)]: "), choice >= 1, choice <= image.editions.count else { return }
            let edition = image.editions[choice - 1]
            if edition.isHome {
                print("   " + CreateCopy.wrap(ChoiceWarning.home.description, width: CreateCopy.width - 3,
                                              indent: "   "))
                guard Term.confirm("   " + CreateCopy.wHomeConfirm, assumeYes: false) else {
                    print("   Keeping \(plan.edition.displayName).")
                    return
                }
                plan.options.remove(.remoteDesktop)
            }
            plan.edition = edition
        }
    }

    /// The "Always on" explanation a locked row prints when someone tries to turn it off.
    static func alwaysOn(_ option: CreateOption) -> String {
        switch option {
        case .bypassRequirements:
            return "Always on: UTM can't add a TPM to a VM it creates by script, so without this Windows Setup would "
                + "stop with “This PC can't run Windows 11”. (?1 for more.)"
        case .localAccount:
            return "Always on: Remote Desktop and automatic sign-in need a local account with a real password. (?3 "
                + "for more.)"
        case .guestTools:
            return "Always on: the Guest Tools carry Windows' network driver and the guest agent Winbar talks to "
                + "Windows through. (?11 for more.)"
        default:
            return "Always on."
        }
    }

    /// `?N`: the same tooltips the window shows on hover and reads out to VoiceOver.
    static func tooltip(_ key: String, plan: CreatePlan, mac: MacFacts) -> String? {
        switch key.lowercased() {
        case "n": return CreateCopy.vmNameTooltip
        case "c": return CreateCopy.coresTooltip(topTier: mac.topTierCores)
        case "m": return CreateCopy.memoryTooltip(suggested: CreateChoices.suggestedMemoryGB(mac))
        case "d": return CreateCopy.diskTooltip
        default: break
        }
        guard let index = Int(key), let row = Checklist.row(index) else { return nil }
        switch row {
        case .user: return CreateCopy.tooltip(.localAccount)
        case .computerName:
            return CreateCopy.computerTooltip(host: CreateChoices.hostName(computerName: plan.computerName))
        case .edition: return CreateCopy.installTooltip
        case .option(let option): return CreateCopy.tooltip(option)
        }
    }
}

/// The progress lines: a spinner that rewrites itself on a terminal, one stamped line per change
/// without one. Thread-safe: the job's state changes arrive on the main thread
/// while the spinner's timer redraws on its own queue.
///
/// The window's side of the same job is `CreateProgress` (CreateProgressView.swift); both take their
/// stage titles and their failure copy from the job, so the two front-ends say the same words.
final class CreateProgressPrinter {
    private let verbose: Bool
    /// Copy-deck ids this run has already said itself, so the job's own message doesn't repeat them
    /// a few lines later (N_PW_FILEVAULT_OFF, which `create` prints before the password prompt).
    private let said: Set<String>
    private let tty = Term.stdoutIsTTY
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var current: CreateJobState?
    private var stageStartedAt = Date()
    private var doneStages: Set<CreateStage> = []
    private var printedMessages = 0
    private var frame = 0
    private var lineOpen = false
    private var lastHeartbeat = Date()
    private var lastDetail: [CreateStage: String] = [:]

    /// The last state seen, for the ending.
    var state: CreateJobState? { lock.lock(); defer { lock.unlock() }; return current }

    init(verbose: Bool, said: Set<String> = []) {
        self.verbose = verbose
        self.said = said
        guard tty else { return }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "net.elusive.winbar.create.spinner"))
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        timer.resume()
    }

    func update(_ state: CreateJobState) {
        lock.lock()
        defer { lock.unlock() }
        let previous = current
        current = state
        if let detail = state.detail { lastDetail[state.stage] = detail }

        if verbose, previous == nil, let log = state.logPath {
            endLine()
            print("  Log: \(log)")
            if let media = state.mediaDir { print("  Setup disk: \(media)") }
        }
        if previous?.stage != state.stage {
            if let previous, previous.stage != state.stage { closeStage(previous) }
            stageStartedAt = Date()
            if !tty { line("“\(state.plan.vmName)”: \(state.stage.runningTitle)") }
            if state.stage == .copy { note(CreateCopy.watch) }
        }
        printNewMessages(state)
        if verbose, let detail = state.detail, previous?.detail != detail, !tty {
            line("“\(state.plan.vmName)”: \(detail)")
        }
        if tty { draw(state) }
    }

    /// Ends the last line, so the ending starts on a clean one.
    func finish() {
        lock.lock()
        defer { lock.unlock() }
        timer?.cancel()
        timer = nil
        if let current, current.isFinished { closeStage(current) }
        endLine()
    }

    // MARK: Drawing (all under the lock)

    private func tick() {
        lock.lock()
        defer { lock.unlock() }
        guard let current, !current.isFinished else { return }
        frame += 1
        if tty {
            draw(current)
        } else if Date().timeIntervalSince(lastHeartbeat) >= 300 {
            lastHeartbeat = Date()
            let minutes = Int(Date().timeIntervalSince(stageStartedAt) / 60)
            let detail = current.detail.map { ": \($0)" } ?? ""
            line("“\(current.plan.vmName)”: still \(current.stage.shortTitle)\(detail) (\(minutes) min)")
        }
    }

    private static let frames = Array("⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏")

    private func draw(_ state: CreateJobState) {
        guard !state.isFinished else { return }
        let spinner = String(CreateProgressPrinter.frames[frame % CreateProgressPrinter.frames.count])
        FileHandle.standardOutput.write(Data(("\r\u{1B}[2K"
                                              + CreateProgressPrinter.line(state, spinner: spinner,
                                                                           elapsed: Date().timeIntervalSince(stageStartedAt),
                                                                           width: CreateCopy.width)).utf8))
        lineOpen = true
    }

    /// The spinner's line: the stage's title and detail on the left, how far along it is on the
    /// right. Pure, so what Terminal says can be held beside what the window's rows say — both take
    /// the words from `CreateStage` and the job's own detail.
    static func line(_ state: CreateJobState, spinner: String, elapsed: TimeInterval, width: Int) -> String {
        var left = "\(spinner) \(state.stage.runningTitle)"
        if let detail = state.detail, !detail.isEmpty { left += " · \(detail)" }
        // W_STALL was said once, when it happened; this says whether it is still true.
        if state.stalled == true { left += " · \(CreateCopy.wStallShort)" }
        let seconds = Int(max(0, elapsed))
        let right = "step \(state.stage.number) of 10  " + String(format: "%d:%02d", seconds / 60, seconds % 60)
        if left.count + right.count + 2 > width { left = String(left.prefix(max(0, width - right.count - 3))) + "…" }
        let gap = max(1, width - left.count - right.count)
        return left + String(repeating: " ", count: gap) + Term.paint(right, .dim)
    }

    /// A finished stage keeps its ✓ line, with its one-line result.
    private func closeStage(_ state: CreateJobState) {
        let stage = state.stage
        guard !doneStages.contains(stage), state.failure == nil || state.isFinished else { return }
        doneStages.insert(stage)
        endLine()
        print(Term.paint("✓", .green) + " " + stage.doneTitle + result(for: stage, state: state))
    }

    private func result(for stage: CreateStage, state: CreateJobState) -> String {
        switch stage {
        case .guestTools:
            return lastDetail[stage].map { " (\($0.hasPrefix("Using") ? $0.lowercased() : "downloaded, SHA-256 checked"))" } ?? ""
        case .vm:
            let plan = state.plan
            return ": “\(plan.vmName)”, \(plan.cores) vCPUs, \(plan.memoryMiB / 1024) GB, \(plan.diskGiB) GB disk"
        case .copy, .oobe, .firstLogon:
            let minutes = Int(Date().timeIntervalSince(stageStartedAt) / 60)
            return minutes >= 1 ? " (\(minutes) min)" : ""
        case .devices:
            return state.restarts > 0 ? " (restarted \(state.restarts) time\(state.restarts == 1 ? "" : "s"))" : ""
        default:
            return ""
        }
    }

    private func printNewMessages(_ state: CreateJobState) {
        guard state.messages.count > printedMessages else { return }
        for message in CreateProgressPrinter.newMessages(state.messages, printed: printedMessages, said: said) {
            endLine()
            note(message.text)
        }
        printedMessages = state.messages.count
    }

    /// The job's messages this run hasn't printed yet: the ones after `printed`, minus any the run
    /// said itself. Pure, so the rule can be checked without a terminal.
    static func newMessages(_ messages: [CreateMessage], printed: Int, said: Set<String>) -> [CreateMessage] {
        guard printed < messages.count else { return [] }
        return messages[printed...].filter { !said.contains($0.code) }
    }

    private func note(_ text: String) {
        endLine()
        print("  " + CreateCopy.wrap(text, width: CreateCopy.width - 2, indent: "  "))
    }

    private func line(_ text: String) {
        print(DateFormatter.logLine.string(from: Date()) + "  " + text)
    }

    private func endLine() {
        guard lineOpen else { return }
        FileHandle.standardOutput.write(Data("\n".utf8))
        lineOpen = false
    }
}
