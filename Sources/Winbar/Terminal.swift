import Foundation

/// Small helpers for talking to a person at a terminal.
enum Term {
    static var stdoutIsTTY: Bool { isatty(STDOUT_FILENO) != 0 }
    static var stdinIsTTY: Bool { isatty(STDIN_FILENO) != 0 }

    /// Color only for a person, and never when NO_COLOR is set (no-color.org).
    static var color: Bool { stdoutIsTTY && ProcessInfo.processInfo.environment["NO_COLOR"] == nil }

    enum Tint: String { case green = "32", yellow = "33", red = "31", cyan = "36", dim = "2", bold = "1" }

    static func paint(_ text: String, _ tint: Tint) -> String {
        paint(text, tint, if: color)
    }

    /// The same, for text whose destination isn't this process's stdout: `winbar diagnose` builds
    /// the doctor table for a file, where an escape sequence is noise a person has to read past.
    static func paint(_ text: String, _ tint: Tint, if enabled: Bool) -> String {
        enabled ? "\u{1B}[\(tint.rawValue)m\(text)\u{1B}[0m" : text
    }

    static func error(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    /// Progress chatter goes to stderr so stdout stays parseable.
    static func note(_ message: String) {
        FileHandle.standardError.write(Data((paint(message, .dim) + "\n").utf8))
    }

    /// A yes/no question. `assumeYes` (from --yes) answers yes without asking. Without a terminal to ask
    /// on, the answer is no whatever the default: nothing changes unattended unless --yes says so.
    static func confirm(_ question: String, assumeYes: Bool, defaultYes: Bool = false) -> Bool {
        let hint = defaultYes ? "[Y/n]" : "[y/N]"
        if assumeYes {
            print("\(question) \(hint) y (--yes)")
            return true
        }
        guard stdinIsTTY else {
            print("\(question) \(hint) n (no terminal to ask on)")
            return false
        }
        print("\(question) \(hint) ", terminator: "")
        fflush(stdout)
        guard let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() else { return false }
        if answer.isEmpty { return defaultYes }
        return answer == "y" || answer == "yes"
    }

    /// A question with more than two answers, each picked by its key; Enter picks the first. nil
    /// without a terminal to ask on.
    static func pick(_ question: String, _ choices: [(key: String, label: String)]) -> String? {
        guard stdinIsTTY, let first = choices.first else { return nil }
        let menu = choices.map { "\($0.label) (\($0.key))" }.joined(separator: ", ")
        while true {
            print("\(question) \(menu) [\(first.key)] ", terminator: "")
            fflush(stdout)
            guard let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() else { return nil }
            if answer.isEmpty { return first.key }
            if let match = choices.first(where: { $0.key == answer || $0.label == answer }) { return match.key }
        }
    }

    enum StepAnswer { case done, skip }

    /// Waits for a person to finish a manual step. Never answered by --yes: these steps are where a
    /// human enters passwords and approves things, and nothing may do that for them.
    static func waitForStep(_ prompt: String = "Press Enter when done, or type s to skip: ") -> StepAnswer {
        guard stdinIsTTY else { return .skip }
        print(prompt, terminator: "")
        fflush(stdout)
        guard let answer = readLine() else { return .skip }
        return answer.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("s") ? .skip : .done
    }

    /// A numbered choice; nil if skipped or not a terminal.
    static func choose(_ prompt: String, from options: [String]) -> Int? {
        guard stdinIsTTY, !options.isEmpty else { return nil }
        for (i, option) in options.enumerated() { print("  \(i + 1). \(option)") }
        print(prompt, terminator: "")
        fflush(stdout)
        guard let line = readLine(), let n = Int(line.trimmingCharacters(in: .whitespaces)), (1...options.count).contains(n) else { return nil }
        return n - 1
    }
}
