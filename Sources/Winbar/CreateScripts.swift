import Foundation

/// What create-vm made, as UTM reported it back.
struct CreatedVM: Codable, Equatable, Sendable {
    /// Every later script addresses the VM by this id, never by its name: a name can be changed in
    /// UTM, or matched by a second VM whose name differs only in case.
    var vmID: String
    /// The NVMe disk. finish keeps exactly this drive and refuses if it isn't the only fixed one.
    var systemDiskID: String
    var windowsCDID: String
    var setupCDID: String
    var mac: String
    var networkShared: Bool
    var serial: SerialKind
    var displays: Int
    var cores: Int
    var memoryMiB: Int

    /// UTM's first serial port. `ptty` is what the CD-prompt watcher reads; anything else means the
    /// keypress fallback (boot-key) answers the prompt instead. `absent` is spelled "none" on the
    /// wire but not in Swift, where `.none` would read as an empty Optional.
    enum SerialKind: String, Codable, Sendable { case ptty, other, absent = "none" }
}

/// What finish left on the VM.
struct FinishedDrives: Equatable, Sendable {
    /// 0 when an earlier run had already removed them (finish is idempotent).
    var removed: Int
    var drivesLeft: Int
    var systemDiskID: String
    var displays: Int
    var mac: String
}

/// The create scripts' own documented failures, plus the two every UTM
/// script can hit. Only `vmDiffers` and `changedUnexpectedly` mean something in UTM changed.
enum CreateScriptError: Error, Equatable {
    /// 1101: the script got the wrong number of arguments. A bug in Winbar.
    case usage(String)
    /// 1102: a number out of range or not a number.
    case badValue(String)
    /// 1103: an ISO path that isn't absolute or doesn't exist. Carries the path.
    case missingFile(String)
    /// 1104: UTM already has a VM with this name, ignoring case. Carries UTM's spelling.
    case nameTaken(String)
    /// 1105: the VM EXISTS but UTM stored something other than what was asked. Winbar offers to
    /// delete it (it was made seconds ago and never started). The id is nil only if even that
    /// couldn't be read back.
    case vmDiffers(vmID: String?, detail: String)
    /// 1111: no VM with that id (deleted in UTM, say).
    case noSuchVM(String)
    /// 1112: the VM isn't running (boot-key) or isn't stopped (finish).
    case wrongState(String)
    /// 1113: finish refused because the VM's fixed disks aren't exactly the one create made.
    case refused(String)
    /// 1114: finish changed the drive list and UTM then reported something unexpected. Never retried
    /// blindly.
    case changedUnexpectedly(String)
    /// -1743: macOS won't let this process control UTM.
    case automationDenied
    /// Anything else: UTM's own errors, timeouts, an unreadable answer.
    case other(title: String, detail: String)

    /// The script's error numbers and what they become. Everything else is `.other`.
    static let numbers: Set<Int> = [1101, 1102, 1103, 1104, 1105, 1111, 1112, 1113, 1114]

    /// Maps what `AppleScriptRunner` returned. It has already turned -1743 into the Automation error,
    /// and leaves every other message verbatim in `detail` with osascript's "(number)" at the end.
    init(_ error: WinbarError) {
        if error.automationDenied {
            self = .automationDenied
            return
        }
        guard let number = AppleScriptRunner.errorNumber(in: error.detail), CreateScriptError.numbers.contains(number) else {
            self = .other(title: error.title, detail: error.detail)
            return
        }
        let message = CreateScriptError.stripNumber(error.detail)
        switch number {
        case 1101: self = .usage(message)
        case 1102: self = .badValue(message)
        case 1103: self = .missingFile(CreateScriptError.after("No such file: ", in: message) ?? message)
        case 1104: self = .nameTaken(CreateScriptError.after("UTM already has a virtual machine named ", in: message) ?? message)
        case 1105:
            let id = message.firstMatch(of: #/^Created VM (\S+) but /#).map { String($0.1) }
            self = .vmDiffers(vmID: id, detail: message)
        case 1111: self = .noSuchVM(message)
        case 1112: self = .wrongState(message)
        case 1113: self = .refused(message)
        default: self = .changedUnexpectedly(message)
        }
    }

    /// "Some message (1104)" → "Some message".
    static func stripNumber(_ message: String) -> String {
        message.replacing(#/\s*\(-?\d+\)\s*$/#, with: "")
    }

    private static func after(_ prefix: String, in message: String) -> String? {
        guard message.hasPrefix(prefix), message.count > prefix.count else { return nil }
        return String(message.dropFirst(prefix.count))
    }

    /// For showing as-is. The job words the in-install failures with the copy deck (E_DETACH etc.).
    var error: WinbarError {
        switch self {
        case .usage(let message):
            return WinbarError("Winbar sent UTM a request it couldn't use", "This is a bug in Winbar. (\(message))")
        case .badValue(let message):
            return WinbarError("UTM can't make a VM with these settings", message)
        case .missingFile(let path):
            return WinbarError("There's no file at \(path).")
        case .nameTaken(let name):
            return WinbarError("UTM already has a VM called “\(name)”. Pick another name.")
        case .vmDiffers(let id, let detail):
            let exists = id.map { "The new VM is in UTM (id \($0)) and hasn't been started." }
                ?? "UTM may have made the VM anyway: look for it in UTM."
            return WinbarError("UTM didn't make the VM as asked", "\(detail). \(exists)")
        case .noSuchVM(let message):
            return WinbarError("UTM doesn't have this VM any more", message)
        case .wrongState(let message):
            return WinbarError(message)
        case .refused(let message):
            return WinbarError("Winbar didn't detach the install disks from UTM", message)
        case .changedUnexpectedly(let message):
            return WinbarError("UTM reports something unexpected after detaching the install disks", message)
        case .automationDenied:
            return Automation.deniedError()
        case .other(let title, let detail):
            return WinbarError(title, detail)
        }
    }
}

/// The four AppleScripts `winbar create` sends to UTM: make the VM, find its serial console, press a
/// key in it, and take the install CDs off at the end.
///
/// Each runs through `AppleScriptRunner` (osascript, values only as argv, never spliced into the
/// source), returns US-separated fields, and fails with a documented error number. Everything after
/// create-vm addresses the VM by the id create-vm returned.
///
/// Source-checked against UTM v4.7.5 (048ca74), unchanged in v5.0.5 for everything used here:
/// Scripting/UTMScriptingCreateCommand.swift:67-92, Scripting/UTMScriptingConfigImpl.swift:310-446,
/// 558-612, Configuration/UTMQemuConfiguration+Arguments.swift:118-140, 252-340, 719-842, 887-903.
/// Compiled against a stub carrying UTM 4.7.5's scripting dictionary, then run against UTM 4.7.5 for
/// real: these scripts created, started, finished and deleted Windows VMs on macOS 27.
enum CreateScripts {
    static let fieldSeparator = UTMScripting.fieldSeparator

    /// Makes the VM. Refuses a name UTM already has, ignoring case (the bundle is `<name>.utm` on a
    /// case-insensitive disk, while UTM's own check is case-sensitive), then reads back what UTM stored
    /// and fails with `vmDiffers` (carrying the new VM's id) if anything differs from what was asked.
    static func createVM(name: String, windowsISO: String, answerISO: String, cores: Int, memoryMiB: Int,
                         diskMiB: Int) -> Result<CreatedVM, CreateScriptError> {
        UTM.ensureRunning()
        let args = [name, windowsISO, answerISO, String(cores), String(memoryMiB), String(diskMiB)]
        // Longer than the script's own 300 s: killing osascript while `make` runs would lose the new
        // VM's id.
        return run(createVMScript, args, timeout: 330).flatMap { text in
            if let created = parseCreated(text) { return .success(created) }
            // `make` succeeded (the script only returns after it), so the VM exists.
            let id = fields(text).first.flatMap { $0.isEmpty ? nil : $0 }
            return .failure(.vmDiffers(vmID: id, detail: "Winbar couldn't read UTM's answer (\(text))"))
        }
    }

    /// The host pty of the running VM's first serial port, or nil when it has none (or UTM hasn't
    /// learned the path yet: poll every 0.5 s for up to 10 s after the start).
    static func serialAddress(vmID: String) -> Result<String?, CreateScriptError> {
        UTM.ensureRunning()
        return run(serialAddressScript, [vmID], timeout: 40).map { $0.isEmpty ? nil : $0 }
    }

    /// Presses the space bar in the VM through UTM's input automation: the CD prompt's fallback when
    /// the serial console can't be used. `wrongState` and UTM's own "not available" errors are worth
    /// retrying for a few seconds after the start (its SPICE input connects late).
    static func sendBootKey(vmID: String) -> Result<Void, CreateScriptError> {
        UTM.ensureRunning()
        return run(bootKeyScript, [vmID], timeout: 40).flatMap { text in
            text == "sent" ? .success(()) : .failure(.other(title: "UTM didn't press the key", detail: text))
        }
    }

    /// Removes the two install CDs from the stopped VM and keeps its system disk by id. Idempotent.
    static func finish(vmID: String, diskID: String) -> Result<FinishedDrives, CreateScriptError> {
        UTM.ensureRunning()
        return run(finishScript, [vmID, diskID], timeout: 150).flatMap { text in
            guard let done = parseFinish(text) else {
                return .failure(.changedUnexpectedly("Winbar couldn't read UTM's answer (\(text))"))
            }
            return .success(done)
        }
    }

    private static func run(_ script: String, _ args: [String], timeout: TimeInterval) -> Result<String, CreateScriptError> {
        AppleScriptRunner.run(script, arguments: args, timeout: timeout).mapError(CreateScriptError.init)
    }

    // MARK: Results

    static func fields(_ text: String) -> [String] {
        text.split(separator: fieldSeparator, omittingEmptySubsequences: false).map(String.init)
    }

    /// Ten fields: vm id, system disk id, Windows CD id, setup CD id, MAC, network mode, serial kind,
    /// display count, cores, memory. None of them is free text, so a count mismatch means a bad answer.
    static func parseCreated(_ text: String) -> CreatedVM? {
        let f = fields(text)
        guard f.count == 10, !f[0].isEmpty, !f[1].isEmpty, !f[2].isEmpty, !f[3].isEmpty,
              let serial = CreatedVM.SerialKind(rawValue: f[6]),
              let displays = Int(f[7]), let cores = Int(f[8]), let memory = Int(f[9]) else { return nil }
        return CreatedVM(vmID: f[0], systemDiskID: f[1], windowsCDID: f[2], setupCDID: f[3], mac: f[4],
                         networkShared: f[5] == "shared", serial: serial, displays: displays, cores: cores,
                         memoryMiB: memory)
    }

    /// Five fields: CDs removed, drives left, system disk id, display count, MAC.
    static func parseFinish(_ text: String) -> FinishedDrives? {
        let f = fields(text)
        guard f.count == 5, let removed = Int(f[0]), let left = Int(f[1]), !f[2].isEmpty, let displays = Int(f[3])
        else { return nil }
        return FinishedDrives(removed: removed, drivesLeft: left, systemDiskID: f[2], displays: displays, mac: f[4])
    }

    // MARK: Scripts
    //
    // The traps that shaped UTMScripting's scripts apply here too: copy `configuration of vm` into a
    // variable before reading its properties (-1728 otherwise); assign a list to a variable before
    // counting it (`count of (displays of c)` returns 0, verified live on 4.7.5); compare enumerations
    // against their constants, never `as text`. One more, found compiling against UTM 4.7.5's
    // dictionary: `serial ports` is both a configuration property («class SrPt») and the plural of the
    // `serial port` class («class SeRi»), and in a record it compiles to the class. Read it by its raw
    // code.

    /// create-vm: `osascript - <name> <windowsIso> <answerIso> <cpuCores> <memoryMiB> <diskMiB>`.
    ///
    /// Returns vm id, system disk id, Windows CD id, setup CD id, MAC, network mode ("shared"|"other"),
    /// serial port 1 ("ptty"|"other"|"none"), display count, cores, memory. Errors: 1101 usage, 1102 bad
    /// number, 1103 an ISO missing, 1104 name used (nothing created); 1105 the VM EXISTS but differs.
    ///
    /// What the VM gets, and why:
    /// - `make` starts from UTM's aarch64 "virt" defaults with hypervisor, UEFI and one ptty serial
    ///   port, displays and sound cleared. 4.7.5's create command also seeds a default CD and 64 GiB
    ///   disk; the `drives` list passed here replaces whatever is there (records without an id are
    ///   new, everything unmentioned is dropped), and the read-back checks the result either way.
    /// - Serial ports are not passed, so the default ptty port stays: `-serial chardev:term0` on the
    ///   virt board's PL011, which edk2 (ArmVirtQemu PlatformBm) puts in ConIn/ConOut. Winbar reads it
    ///   to answer "Press any key to boot from CD or DVD" (SerialConsole). The PL011 exists either way.
    /// - Drives, in QEMU bootindex order (UTM Arguments.swift driveArgument): 1 NVMe system disk,
    ///   2 Windows ISO, 3 WINBAR_SETUP (answer file, first-logon script and the pinned UTM Guest Tools
    ///   installer: no Guest Tools ISO, whose own Autounattend.xml would compete with Winbar's). The
    ///   disk goes first, unlike UTM's wizard: while it's blank edk2's NVMe option fails to load and
    ///   BDS falls through to the USB CDs, so the first boot still reaches the prompt; once Setup has
    ///   written its boot loader every boot goes straight to Windows Boot Manager, so the prompt never
    ///   shows again, a stray key can't restart Setup, and removing the CDs later leaves the head of
    ///   the boot order alone. The CDs are read-only usb-storage behind QEMU's auto-hub on xHCI port 4
    ///   (the input devices take ports 1-3 first). UTM keeps only a bookmark to each ISO, so both
    ///   files must stay put until finish has removed the CDs.
    /// - One display, the Windows wizard's card (virtio-ramfb-gl = Tuning.consoleDisplayHardware), so
    ///   a Setup page that stops on a question is visible. Removed later by the display-off path.
    /// - One virtio-net-pci NIC in shared mode, as the wizard makes; Winbar's RDP probe needs shared.
    /// - `-rtc base=localtime`: what the wizard's (unscriptable) Windows RTC switch emits.
    /// - Not scriptable in 4.7.5/5.0.5: TPM (hence the answer file's TPM/Secure Boot/RAM bypass),
    ///   Secure Boot keys, sound. Machine "virt" is the wizard's value (stay stock).
    ///
    /// Everything after `make` sits in a `try`: any failure there still reports 1105 with the id, so
    /// Winbar never loses track of a VM it made.
    static let createVMScript = #"""
on run argv
	if (count of argv) is not 6 then error "usage: name windowsIso answerIso cpuCores memoryMiB diskMiB" number 1101
	set vmName to item 1 of argv
	set isoPaths to {item 2 of argv, item 3 of argv}
	try
		set nCores to (item 4 of argv) as integer
		set memMiB to (item 5 of argv) as integer
		set diskMiB to (item 6 of argv) as integer
	on error
		error "The vCPU count, memory and disk size must be whole numbers" number 1102
	end try
	if vmName is "" then error "The VM needs a name" number 1102
	if nCores < 1 or nCores > 64 then error "vCPUs out of range: " & nCores number 1102
	-- Windows 11 wants 4 GiB of RAM and a 64 GB disk.
	if memMiB < 4096 then error "Memory below 4096 MiB: " & memMiB number 1102
	if diskMiB < 65536 then error "Disk below 65536 MiB (Windows 11 needs 64 GB): " & diskMiB number 1102

	-- Resolve each path now (plain AppleScript, no Finder): a missing file fails here, before anything
	-- exists, instead of as "Failed to access drive image path" at the first start.
	set isoFiles to {}
	repeat with pRef in isoPaths
		set p to contents of pRef
		if p does not start with "/" then error "No such file: " & p number 1103
		try
			((POSIX file p) as alias) as text
		on error
			error "No such file: " & p number 1103
		end try
		set end of isoFiles to (POSIX file p)
	end repeat
	set windowsIso to item 1 of isoFiles
	set answerIso to item 2 of isoFiles

	set US to character id 31
	set vmId to ""
	set problems to {}
	set diskId to ""
	set cdIds to {"", ""}
	set mac to ""
	set netMode to "other"
	set serialKind to "none"
	set nDisplays to 0
	with timeout of 300 seconds
		tell application id "com.utmapp.UTM"
			-- Refuse any name UTM already has, IGNORING case: the bundle is "<name>.utm" on a
			-- case-insensitive disk, and UTM's own check is case-sensitive.
			set existingNames to name of every virtual machine
			repeat with n in existingNames
				set existing to (contents of n) as text
				considering diacriticals, hyphens, punctuation and white space
					ignoring case
						set taken to (existing is vmName)
					end ignoring
				end considering
				if taken then error "UTM already has a virtual machine named " & existing number 1104
			end repeat

			-- Records using UTM's terms (guest size, NVMe, USB, shared ...) must be built inside this tell.
			set driveList to {{guest size:diskMiB, interface:NVMe}, ¬
				{removable:true, interface:USB, source:windowsIso}, ¬
				{removable:true, interface:USB, source:answerIso}}
			set theVM to make new virtual machine with properties {backend:qemu, configuration:{¬
				name:vmName, icon:"windows", notes:"Created by winbar create", ¬
				architecture:"aarch64", machine:"virt", ¬
				memory:memMiB, cpu cores:nCores, hypervisor:true, uefi:true, ¬
				drives:driveList, ¬
				network interfaces:{{hardware:"virtio-net-pci", mode:shared}}, ¬
				displays:{{hardware:"virtio-ramfb-gl", dynamic resolution:true, native resolution:false, upscaling filter:nearest, downscaling filter:linear}}, ¬
				qemu additional arguments:{{argument string:"-rtc base=localtime"}}}}

			-- Read back what UTM stored. The VM exists from here on, so every failure becomes a
			-- problem reported with its id (1105), never a bare error.
			try
				set vmId to (id of theVM) as text
				set c to configuration of theVM
				set storedName to (name of c) as text
				considering case
					if storedName is not vmName then set end of problems to "name " & storedName
				end considering
				if ((architecture of c) as text) is not "aarch64" then set end of problems to "architecture " & (architecture of c)
				if (hypervisor of c) is not true then set end of problems to "hypervisor off"
				if (uefi of c) is not true then set end of problems to "UEFI off"
				set driveRecords to drives of c
				set displayList to displays of c
				set netList to network interfaces of c
				-- Raw code on purpose: in a record, the term `serial ports` compiles to the plural of the
				-- `serial port` class («class SeRi»), not to the configuration's property («class SrPt»).
				set serialList to «class SrPt» of c
				if (count of driveRecords) is not 3 then
					set end of problems to "expected 3 drives, found " & (count of driveRecords)
				else
					set d1 to item 1 of driveRecords
					if removable of d1 then set end of problems to "drive 1 is not the fixed system disk"
					if interface of d1 is not NVMe then set end of problems to "drive 1 is not NVMe"
					set diskId to (id of d1) as text
					set cdIds to {}
					repeat with i from 2 to 3
						set d to item i of driveRecords
						if not (removable of d) then set end of problems to "drive " & i & " is not a removable CD"
						if interface of d is not USB then set end of problems to "drive " & i & " is not USB"
						set end of cdIds to (id of d) as text
					end repeat
				end if
				if (count of netList) is 1 then
					set n1 to item 1 of netList
					set mac to (address of n1) as text
					if mode of n1 is shared then set netMode to "shared"
				else
					set end of problems to "expected 1 network interface, found " & (count of netList)
				end if
				if (count of serialList) ≥ 1 then
					set serialKind to "other"
					try
						if interface of (item 1 of serialList) is ptty then set serialKind to "ptty"
					end try
				end if
				set nDisplays to count of displayList
				set gotCores to cpu cores of c
				set gotMem to memory of c
				if netMode is not "shared" then set end of problems to "network is not shared"
				if nDisplays is not 1 then set end of problems to "expected 1 display, found " & nDisplays
				if gotCores is not nCores then set end of problems to "vCPUs " & gotCores & ", asked " & nCores
				if gotMem is not memMiB then set end of problems to "memory " & gotMem & " MiB, asked " & memMiB
			on error errText number errNum
				set end of problems to "reading it back failed with error " & errNum & ": " & errText
			end try
		end tell
	end timeout
	if (count of problems) > 0 then
		set AppleScript's text item delimiters to "; "
		set msg to problems as text
		set AppleScript's text item delimiters to ""
		if vmId is "" then error "Created a VM but couldn't read its id: " & msg number 1105
		error "Created VM " & vmId & " but UTM stored: " & msg number 1105
	end if
	-- serialKind "other"/"none" is not fatal: Winbar then answers the CD prompt with boot-key.
	set fields to {vmId, diskId, item 1 of cdIds, item 2 of cdIds, mac, netMode, serialKind, ¬
		nDisplays as text, gotCores as text, gotMem as text}
	set AppleScript's text item delimiters to US
	set resultText to fields as text
	set AppleScript's text item delimiters to ""
	return resultText
end run
"""#

    /// serial-address: `osascript - <vmId>` → the pty path, or "" when there's no ptty port or UTM hasn't
    /// learned the path yet. QEMU creates the pty before the guest runs (UTM starts it with -S) and UTM
    /// records it (UTMQemuVirtualMachine.swift:693, qemuVM(_:didCreatePttyDevice:)); the scripting
    /// object reports `address` = that path for interface ptty (UTMScriptingSerialPortImpl).
    /// Errors: 1101 usage, 1111 no VM with that id.
    static let serialAddressScript = #"""
on run argv
	if (count of argv) is not 1 then error "usage: vmId" number 1101
	set vmId to item 1 of argv
	with timeout of 30 seconds
		tell application id "com.utmapp.UTM"
			try
				set theVM to virtual machine id vmId
				set ports to every serial port of theVM
			on error
				error "UTM has no virtual machine with id " & vmId number 1111
			end try
			if (count of ports) is 0 then return ""
			set sp to item 1 of ports
			if interface of sp is not ptty then return ""
			return (address of sp) as text
		end tell
	end timeout
end run
"""#

    /// boot-key: `osascript - <vmId>` → "sent". One space through UTM's input automation, for when the
    /// serial console can't be used. Why a space: cdboot.efi's prompt takes any key, while in edk2's
    /// BDS Enter is the registered CONTINUE key and F2/Esc open the Boot Manager menu (PlatformBm
    /// PlatformRegisterOptionsAndKeys); a space means nothing to BDS. Winbar sends it at most every 2 s
    /// for 30 s after QEMU appears, and never after a disk boot has been seen. Needs the VM started and
    /// its SPICE input connected (UTMScriptingInputImpl.sendKeystroke), which exists while the VM has a
    /// display. Errors: 1101 usage, 1111 no VM, 1112 not running; UTM's own errors pass through.
    static let bootKeyScript = #"""
on run argv
	if (count of argv) is not 1 then error "usage: vmId" number 1101
	set vmId to item 1 of argv
	with timeout of 30 seconds
		tell application id "com.utmapp.UTM"
			try
				set theVM to virtual machine id vmId
				set vmStatus to status of theVM
			on error
				error "UTM has no virtual machine with id " & vmId number 1111
			end try
			if vmStatus is not started then error "The VM isn't running." number 1112
			input keystroke theVM text " "
		end tell
	end timeout
	return "sent"
end run
"""#

    /// finish: `osascript - <vmId> <systemDiskId>` → CDs removed, drives left, system disk id, display
    /// count, MAC. Removes the two install CDs (Windows ISO, WINBAR_SETUP) from the stopped VM. The setup
    /// CD holds the account password, so it must be off the VM before Winbar deletes the file: a CD
    /// whose file is gone makes the next start fail ("Failed to access drive image path",
    /// UTMQemuVirtualMachine.restoreExternalDrives). Idempotent: with no CDs left it changes nothing and
    /// returns "0" as the count.
    /// Errors: 1101 usage, 1111 no VM, 1112 not stopped, 1113 refused (the fixed disks aren't exactly
    /// the one create made) — nothing changed; 1114 UTM reports something unexpected AFTER the update.
    ///
    /// Remove, not eject:
    /// - Eject can't be scripted. `update configuration` changes only `interface` and `source` on an
    ///   existing drive (UTMScriptingConfigImpl.updateQemuExistingDrive:422-428), and "no source" can't
    ///   be expressed; the registry command covers shared directories only. A scripted eject would be
    ///   remove plus re-add an empty CD: the same change, plus two empty CD devices forever.
    /// - Removing moves nothing that matters. usb-storage isn't PCI (Arguments.swift:802-816), so the
    ///   NVMe controller, NIC, GPU and xHCI keep their addresses; the input devices keep xHCI ports 1-3
    ///   because they're created before any drive; only the auto-hub and the CDs vanish (to Windows,
    ///   unplugged media). The NVMe disk has been bootindex 0 since create, so "Windows Boot Manager"
    ///   (a short-form HD() option that QemuBootOrderLib Match() prefix-matches to it) stays matched
    ///   and first; only unmatched HD() options are pruned.
    /// - The one sanctioned exception to "never change the drive list": removable drives only (UTM
    ///   never deletes their files: UTMConfigurationDrive.saveData returns early for external drives),
    ///   the fixed disk kept by id and re-checked, after the BitLocker guard.
    /// Danger kept in mind: a drives list REPLACES the list, and a FIXED drive left out is dropped AND
    /// its image deleted on save (updateIdentifiedElements + cleanupAllFiles). So the list is rebuilt
    /// from what UTM reports, the disk matched by the recorded id, and the script refuses unless that
    /// is the only fixed disk. Networks and displays carry their index, so they're updated in place.
    static let finishScript = #"""
on run argv
	if (count of argv) is not 2 then error "usage: vmId systemDiskId" number 1101
	set vmId to item 1 of argv
	set diskId to item 2 of argv
	set US to character id 31
	with timeout of 120 seconds
		tell application id "com.utmapp.UTM"
			try
				set theVM to virtual machine id vmId
				set vmStatus to status of theVM
			on error
				error "UTM has no virtual machine with id " & vmId number 1111
			end try
			if vmStatus is not stopped then error "The VM must be shut down before its install disks can be detached." number 1112
			set c to configuration of theVM
			-- A custom icon name makes `update configuration` throw iconNotFound; an empty icon is
			-- skipped (the same trap and fix as UTMScripting.updateScript).
			set icon of c to ""
			set driveRecords to drives of c
			set displaysBefore to displays of c
			set netBefore to network interfaces of c
			set keep to {}
			set fixedIds to {}
			set nRemovable to 0
			repeat with i from 1 to count of driveRecords
				set d to item i of driveRecords
				if removable of d then
					set nRemovable to nRemovable + 1
				else
					set end of keep to {id:(id of d)}
					set end of fixedIds to ((id of d) as text)
				end if
			end repeat
			-- Exact (case-sensitive) id match: this must be the disk create made, and the only fixed one.
			set sameDisk to false
			if (count of fixedIds) is 1 then
				considering case
					set sameDisk to ((item 1 of fixedIds) is diskId)
				end considering
			end if
			if not sameDisk then error "Expected one fixed disk with id " & diskId & ", found " & (count of fixedIds) & " fixed disk(s). Nothing was changed." number 1113
			set macBefore to ""
			if (count of netBefore) ≥ 1 then set macBefore to (address of item 1 of netBefore) as text
			if nRemovable is 0 then
				return "0" & US & ((count of driveRecords) as text) & US & diskId & US & ((count of displaysBefore) as text) & US & macBefore
			end if

			set drives of c to keep
			update configuration of theVM with c

			set c2 to configuration of theVM
			set driveAfter to drives of c2
			set displaysAfter to displays of c2
			set netAfter to network interfaces of c2
			set problems to {}
			if (count of driveAfter) is not 1 then
				set end of problems to "expected 1 drive, found " & (count of driveAfter)
			else
				set d to item 1 of driveAfter
				considering case
					if ((id of d) as text) is not diskId then set end of problems to "the remaining drive is not the system disk"
				end considering
				if removable of d then set end of problems to "the remaining drive is removable"
			end if
			if (count of displaysAfter) is not (count of displaysBefore) then set end of problems to "the display count changed"
			set macAfter to ""
			if (count of netAfter) ≥ 1 then set macAfter to (address of item 1 of netAfter) as text
			if macAfter is not macBefore then set end of problems to "the network interface changed"
		end tell
	end timeout
	if (count of problems) > 0 then
		set AppleScript's text item delimiters to "; "
		set msg to problems as text
		set AppleScript's text item delimiters to ""
		error "After detaching the install disks UTM reports: " & msg number 1114
	end if
	set fields to {nRemovable as text, "1", diskId, (count of displaysAfter) as text, macAfter}
	set AppleScript's text item delimiters to US
	set resultText to fields as text
	set AppleScript's text item delimiters to ""
	return resultText
end run
"""#
}
