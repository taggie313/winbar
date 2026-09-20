import Foundation

/// Runs AppleScript through /usr/bin/osascript.
///
/// A subprocess rather than NSAppleScript, which must run on the main thread and would freeze the
/// menu for as long as the target app takes to answer. Values go in only as `argv` items, never
/// spliced into the source, so a VM name can't change what the script does.
enum AppleScriptRunner {
    static func run(_ source: String, arguments: [String] = [], timeout: TimeInterval = 90) -> Result<String, WinbarError> {
        let result = Shell.run("/usr/bin/osascript", ["-"] + arguments, input: Data(source.utf8), timeout: timeout)
        if result.timedOut {
            return .failure(WinbarError("UTM didn't answer in time",
                                        "Gave up after \(Int(timeout)) seconds; UTM may be busy or showing a dialog.",
                                        timedOut: true))
        }
        guard result.status == 0 else { return .failure(explain(cleanError(result.errorText))) }
        // osascript appends one newline to the result; the result itself may legitimately end in one.
        var text = result.text
        if text.hasSuffix("\n") { text.removeLast() }
        return .success(text)
    }

    /// "…: execution error: No VM named x (1001)" → "No VM named x (1001)".
    static func cleanError(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = trimmed.range(of: "execution error: ") { return String(trimmed[range.upperBound...]) }
        return trimmed
    }

    /// The error number osascript puts at the end of its message: "… (-1743)" → -1743.
    static func errorNumber(in message: String) -> Int? {
        guard let match = message.firstMatch(of: #/\((-?\d+)\)\s*$/#) else { return nil }
        return Int(match.1)
    }

    /// The errors people actually hit, as something they can act on; anything else verbatim.
    static func explain(_ message: String) -> WinbarError {
        switch errorNumber(in: message) {
        case -1743: return Automation.deniedError()
        case -1712: return WinbarError("UTM didn't answer in time", "It may be busy or showing a dialog. (\(message))",
                                       timedOut: true)
        default: return WinbarError("AppleScript failed", message)
        }
    }
}

/// A UTM virtual machine as its scripting interface describes it. Works whether or not the VM is
/// running, and without reading UTM's container (which macOS 27 refuses outright).
struct VMInfo: Equatable {
    var id = ""
    var name = ""
    var status = ""          // stopped, starting, started, pausing, paused, resuming, stopping
    var backend = ""         // qemu, apple
    var icon = ""            // "windows" for Windows VMs
    var architecture = ""    // aarch64, x86_64, …
    var hypervisor: Bool?
    var cpuCores: Int?       // 0 = UTM's default
    var memoryMB: Int?
    var displayCount: Int?   // 0 = headless
    var mac: String?
    var networkMode = ""     // shared, bridged, host, emulated (first NIC)

    var isWindows: Bool { icon.lowercased().contains("windows") }
    var isRunning: Bool { !status.isEmpty && status != "stopped" }
    var headless: Bool? { displayCount.map { $0 == 0 } }
}

/// UTM's AppleScript dictionary, for discovery and configuration changes.
///
/// UTM applies `update configuration` itself, so there's no need to quit it and edit config.plist
/// behind its back (it caches that file and would overwrite the edit), and no need to touch its
/// container at all.
enum UTMScripting {
    static let fieldSeparator: Character = "\u{1F}"   // ASCII unit separator
    static let recordSeparator: Character = "\u{1E}"  // ASCII record separator

    /// Every VM UTM knows about. Launches UTM hidden if it isn't running.
    static func listVMs() -> Result<[VMInfo], WinbarError> {
        UTM.ensureRunning()
        return AppleScriptRunner.run(listScript).map(parseList)
    }

    static func vm(named name: String) -> Result<VMInfo?, WinbarError> {
        listVMs().map { $0.first { $0.name == name } }
    }

    enum DisplayMode: String { case headless, console }

    struct Applied: Equatable { let cpuCores: Int?; let memoryMB: Int?; let displayCount: Int? }

    /// Changes a stopped VM's configuration and returns what UTM reports afterwards. Empty or nil
    /// values are left alone. UTM refuses while the VM runs, and so does the script, first.
    ///
    /// A display change replaces the whole display list (records without an `index` do that), and
    /// afterwards UTM must be quit before the VM starts again; `Reconfigure` does both, don't call this
    /// for displays on its own.
    static func updateConfiguration(vm name: String, cpuCores: Int?, memoryMB: Int?,
                                    display: DisplayMode?) -> Result<Applied, WinbarError> {
        UTM.ensureRunning()
        let args = [name, cpuCores.map(String.init) ?? "", memoryMB.map(String.init) ?? "", display?.rawValue ?? "",
                    Tuning.consoleDisplayHardware]
        return AppleScriptRunner.run(updateScript, arguments: args, timeout: 150).map { text in
            let fields = text.split(separator: fieldSeparator, omittingEmptySubsequences: false).map(String.init)
            func int(_ i: Int) -> Int? { i < fields.count ? Int(fields[i]) : nil }
            return Applied(cpuCores: int(0), memoryMB: int(1), displayCount: int(2))
        }
    }

    /// The script percent-escapes the free-text fields (name, icon), so a separator inside a name
    /// can't shift the columns: exactly twelve fields per record.
    static func parseList(_ text: String) -> [VMInfo] {
        text.split(separator: recordSeparator).compactMap { record in
            let f = record.split(separator: fieldSeparator, omittingEmptySubsequences: false).map(String.init)
            guard f.count == 12, !f[1].isEmpty else { return nil }
            return VMInfo(id: f[0], name: unescape(f[1]), status: f[2], backend: f[3], icon: unescape(f[4]), architecture: f[5],
                          hypervisor: f[6].isEmpty ? nil : f[6] == "true",
                          cpuCores: Int(f[7]), memoryMB: Int(f[8]), displayCount: Int(f[9]),
                          mac: f[10].isEmpty ? nil : f[10], networkMode: f[11])
        }
    }

    /// Undoes the list script's `esc`. Every literal "%" was escaped first, so this is exact.
    static func unescape(_ field: String) -> String { field.removingPercentEncoding ?? field }

    // MARK: Scripts
    //
    // Two AppleScript traps shape these:
    // - `displays of (configuration of vm)` fails with -1728. Copy the configuration into a variable
    //   first; it's a record then, and its properties read fine.
    // - Enumerations (status, backend) are compared against their constants rather than coerced with
    //   `as text`, which can yield raw «constant ****» codes instead of names.

    static let listScript = #"""
on run argv
	set US to character id 31
	set RS to character id 30
	set vmRows to {}
	with timeout of 60 seconds
		tell application id "com.utmapp.UTM"
			repeat with vm in virtual machines
				set f to {"", "", "", "", "", "", "", "", "", "", "", ""}
				try
					set item 1 of f to (id of vm) as text
					set item 2 of f to my esc((name of vm) as text)
					set s to status of vm
					if s is stopped then
						set item 3 of f to "stopped"
					else if s is starting then
						set item 3 of f to "starting"
					else if s is started then
						set item 3 of f to "started"
					else if s is pausing then
						set item 3 of f to "pausing"
					else if s is paused then
						set item 3 of f to "paused"
					else if s is resuming then
						set item 3 of f to "resuming"
					else if s is stopping then
						set item 3 of f to "stopping"
					end if
					set b to backend of vm
					if b is qemu then
						set item 4 of f to "qemu"
					else if b is apple then
						set item 4 of f to "apple"
					else
						set item 4 of f to "unavailable"
					end if
				end try
				try
					set c to configuration of vm
					try
						set item 5 of f to my esc((icon of c) as text)
					end try
					try
						set item 6 of f to (architecture of c) as text
					end try
					try
						set item 7 of f to (hypervisor of c) as text
					end try
					try
						set item 8 of f to (cpu cores of c) as text
					end try
					try
						set item 9 of f to (memory of c) as text
					end try
					try
						-- Reading a list inside the record inline miscounts: `count of (displays of c)` returns 0 while the
						-- list holds a display (verified live on UTM 4.7.5). Assign it to a variable first.
						set displayList to displays of c
						set item 10 of f to (count of displayList) as text
					end try
					try
						set item 11 of f to (address of item 1 of (network interfaces of c)) as text
					end try
					try
						set m to mode of item 1 of (network interfaces of c)
						if m is shared then
							set item 12 of f to "shared"
						else if m is bridged then
							set item 12 of f to "bridged"
						else if m is host then
							set item 12 of f to "host"
						else if m is emulated then
							set item 12 of f to "emulated"
						end if
					end try
				end try
				set AppleScript's text item delimiters to US
				set end of vmRows to (f as text)
			end repeat
		end tell
	end timeout
	set AppleScript's text item delimiters to RS
	set listText to vmRows as text
	set AppleScript's text item delimiters to ""
	return listText
end run

-- Free text can contain the separators. Escape them, and "%" itself first, so parseList can undo it.
on esc(t)
	set t to my rep(t, "%", "%25")
	set t to my rep(t, character id 31, "%1F")
	set t to my rep(t, character id 30, "%1E")
	return t
end esc

on rep(t, a, b)
	set AppleScript's text item delimiters to a
	set parts to text items of t
	set AppleScript's text item delimiters to b
	set t to parts as text
	set AppleScript's text item delimiters to ""
	return t
end rep
"""#

    static let updateScript = #"""
on run argv
	set wantedName to item 1 of argv
	set newCores to item 2 of argv
	set newMemory to item 3 of argv
	set newDisplay to item 4 of argv
	set consoleHardware to item 5 of argv
	set US to character id 31
	with timeout of 120 seconds
		tell application id "com.utmapp.UTM"
			set theVM to missing value
			set matchCount to 0
			repeat with vm in virtual machines
				set vmName to (name of vm) as text
				-- Exactly the name Swift checked, guarded and shut down: AppleScript ignores case by
				-- default, and "win11" must not stand in for "Win11".
				considering case
					set isMatch to (vmName is wantedName)
				end considering
				if isMatch then
					set matchCount to matchCount + 1
					set theVM to contents of vm
				end if
			end repeat
			if theVM is missing value then error "UTM has no virtual machine named " & wantedName number 1001
			if matchCount > 1 then error "UTM has more than one virtual machine named " & wantedName & ". Rename one, then try again." number 1003
			if status of theVM is not stopped then error wantedName & " must be stopped before its configuration can change" number 1002
			set c to configuration of theVM
			-- The copied record carries a custom icon by its file name, but UTM's updater only accepts
			-- built-in icon names and throws iconNotFound for anything else, refusing every change to
			-- such a VM. It skips an empty icon, so the VM keeps whatever icon it has.
			set icon of c to ""
			if newCores is not "" then set cpu cores of c to (newCores as integer)
			if newMemory is not "" then set memory of c to (newMemory as integer)
			-- Display records without an index REPLACE the whole list: UTM's scripting deletes every
			-- existing display whose index isn't mentioned. That is intended here (headless = none,
			-- console = exactly one). To edit a display in place, include its index.
			if newDisplay is "headless" then
				set displays of c to {}
			else if newDisplay is "console" then
				set displays of c to {{hardware:consoleHardware, dynamic resolution:true, native resolution:false, upscaling filter:nearest, downscaling filter:linear}}
			end if
			update configuration of theVM with c
			set c2 to configuration of theVM
			-- Assign the list before counting it: `count of (displays of c2)` inline returns 0 (see the list script).
			set displayList to displays of c2
			return ((cpu cores of c2) as text) & US & ((memory of c2) as text) & US & ((count of displayList) as text)
		end tell
	end timeout
end run
"""#
}
