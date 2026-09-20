import Foundation

/// `KEY=VALUE` lines from a guest script. Keys may repeat (lists); the subscript takes the last.
struct GuestOutput {
    let pairs: [(key: String, value: String)]

    subscript(key: String) -> String? { pairs.last { $0.key == key }?.value }

    func all(_ key: String) -> [String] { pairs.filter { $0.key == key }.map(\.value) }

    func int(_ key: String) -> Int? { self[key].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } }

    /// True/False as PowerShell prints booleans.
    func bool(_ key: String) -> Bool? {
        switch self[key]?.lowercased() {
        case "true", "1": return true
        case "false", "0": return false
        default: return nil
        }
    }

    /// The wrapper always ends with DONE=1, so its absence means the file was cut short.
    var complete: Bool { self["DONE"] == "1" }

    /// A terminating error the script's outer try/catch caught.
    var error: String? { self["ERROR"] }

    static func parse(_ text: String) -> GuestOutput {
        // PowerShell writers love a UTF-8 BOM; the wrapper avoids one, but don't depend on it.
        let body = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        var pairs: [(key: String, value: String)] = []
        for line in body.split(whereSeparator: \.isNewline) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            pairs.append((key, String(line[line.index(after: eq)...])))
        }
        return GuestOutput(pairs: pairs)
    }
}

/// Runs PowerShell inside the guest through the QEMU guest agent.
///
/// This is the only pattern that proved reliable: push a script file, start it detached, and poll for
/// its output file. `utmctl exec` can't run `powershell -Command ...` (it fails with OSStatus -2700),
/// and it doesn't return a program's output, hence the file round trip. Facts the scripts design
/// around: the agent runs as SYSTEM in session 0, under x64 emulation; per-user settings live under
/// `HKEY_USERS\<SID>`; and anything meant for the user's desktop must go through a scheduled task.
enum GuestAgent {
    /// Always present and writable by SYSTEM; no spaces, so the path survives cmd.exe's quoting rules.
    static let directory = #"C:\Windows\Temp"#

    static func run(vm: String, script body: String, params: [(String, String)] = [],
                    timeout: TimeInterval = 120) -> Result<GuestOutput, WinbarError> {
        let base = directory + #"\winbar-"# + UUID().uuidString.lowercased()
        let script = wrap(body: body, params: params, base: base)

        // UTF-8 with a BOM: Windows PowerShell 5.1 reads a BOM-less script in the ANSI code page, which
        // would mangle any non-ASCII user or host name passed in as a parameter.
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data(script.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n").utf8))

        let push = UTM.ctl(["file", "push", vm, base + ".ps1"], input: data, timeout: 60)
        guard push.ok else {
            return .failure(Automation.explain(push.output, else: WinbarError("Couldn't copy a script into Windows", agentHint(push.output))))
        }
        // `start /b` detaches PowerShell so the agent's exec returns at once; the script signals
        // completion by renaming its output file. cmd.exe strips the outer quotes utmctl adds.
        let launch = UTM.ctl(["exec", vm, "--cmd", "cmd.exe", "/c",
                              "start /b powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \(base).ps1"],
                             timeout: 60)
        guard launch.ok else {
            cleanUp(vm: vm, base: base)
            return .failure(Automation.explain(launch.output, else: WinbarError("Couldn't run a script in Windows", agentHint(launch.output))))
        }

        var output: GuestOutput?
        waitUntil(timeout: timeout, every: 2) {
            let pull = UTM.ctl(["file", "pull", vm, base + ".out"], timeout: 30)
            // The file's own text may contain "Error", so judge the pull by its exit and stderr only.
            guard pull.status == 0, !pull.timedOut, !pull.errorText.contains("Error"), !pull.stdout.isEmpty else { return false }
            let parsed = GuestOutput.parse(pull.text)
            guard parsed.complete else { return false }
            output = parsed
            return true
        }
        cleanUp(vm: vm, base: base)
        guard let output else {
            return .failure(WinbarError("Windows didn't answer within \(Int(timeout)) seconds",
                                        "The guest agent accepted the script but no result came back."))
        }
        return .success(output)
    }

    /// Deletes the script and its .tmp/.out. Best effort: a script that timed out may still write its
    /// .out later and leave it behind in C:\Windows\Temp.
    private static func cleanUp(vm: String, base: String) {
        _ = UTM.ctl(["exec", vm, "--cmd", "cmd.exe", "/c", "del /f /q \(base).*"], timeout: 30)
    }

    private static func agentHint(_ output: String) -> String {
        output + "\n\nThe QEMU guest agent must be running in Windows (it comes with UTM Guest Tools)."
    }

    /// Wraps a script body with parameters, the Emit helper and the .tmp → .out completion protocol.
    ///
    /// Bodies must not call `exit`: that would skip writing the output, and the host would wait for
    /// the full timeout. Parameter values are always single-quoted literals, never interpolated code.
    static func wrap(body: String, params: [(String, String)], base: String) -> String {
        let assignments = params.map { name, value in
            precondition(name.allSatisfy { $0.isLetter || $0.isNumber }, "parameter names are identifiers")
            return "$\(name) = \(psQuote(value))"
        }.joined(separator: "\n")
        return """
            $ErrorActionPreference = 'Continue'
            $ProgressPreference = 'SilentlyContinue'
            $wbLines = New-Object System.Collections.Generic.List[string]
            function Emit([string]$Key, $Value) { $wbLines.Add($Key + '=' + (([string]$Value) -replace '[\\r\\n]+', ' ')) }
            \(GuestScripts.helpers)
            \(assignments)
            try {
            \(body)
            } catch {
              Emit 'ERROR' $_.Exception.Message
            }
            Emit 'DONE' '1'
            [System.IO.File]::WriteAllLines(\(psQuote(base + ".tmp")), $wbLines, (New-Object System.Text.UTF8Encoding $false))
            Move-Item -LiteralPath \(psQuote(base + ".tmp")) -Destination \(psQuote(base + ".out")) -Force

            """
    }

    /// A PowerShell single-quoted string literal.
    ///
    /// Besides `'`, PowerShell also treats the typographic quotes ‘ ’ ‚ ‛ as single quotes, so a name
    /// like O’Brien would end the literal early. Doubling any of them escapes it. NULs are dropped.
    static func psQuote(_ value: String) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.append("'")
        for scalar in value.unicodeScalars where scalar != "\0" {
            scalars.append(scalar)
            if ["'", "\u{2018}", "\u{2019}", "\u{201A}", "\u{201B}"].contains(scalar) { scalars.append(scalar) }
        }
        scalars.append("'")
        return String(scalars)
    }
}
