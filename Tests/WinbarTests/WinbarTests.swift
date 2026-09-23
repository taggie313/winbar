import Foundation
import Testing
@testable import Winbar

// Pure logic only. Nothing here may reach UTM, a VM, the keychain, TCC or the user's defaults.

@Suite struct ProcessArguments {
    /// A KERN_PROCARGS2 buffer: argc, exec path, NUL padding, argv, then environment.
    func buffer(_ args: [String], env: [String] = ["HOME=/x"]) -> [UInt8] {
        var bytes: [UInt8] = withUnsafeBytes(of: Int32(args.count).littleEndian, Array.init)
        bytes += Array("/path/QEMULauncher".utf8) + [0, 0, 0, 0]
        for arg in args + env { bytes += Array(arg.utf8) + [0] }
        return bytes
    }

    @Test func parsesProcArgs() {
        let args = ["QEMULauncher", "/A/qemu-aarch64-softmmu.framework/qemu-aarch64-softmmu", "-name", "Win 11"]
        #expect(VMProcess.parseProcArgs(buffer(args)) == args)
        #expect(VMProcess.parseProcArgs([1, 0]) == nil)
    }

    @Test func readsQEMUArguments() {
        let p = VMProcess(pid: 1, arguments: [
            "/x/QEMULauncher", "/y/qemu-aarch64-softmmu.framework/Versions/A/qemu-aarch64-softmmu",
            "-name", "My,,VM", "-smp", "cpus=6,sockets=1,cores=6,threads=1", "-m", "16384",
            "-device", "usb-kbd", "-device", "virtio-net-pci,mac=72:F0:0A:01:02:03,netdev=net0",
            "-vga", "none", "-nographic",
        ])
        #expect(p.isQEMU)
        #expect(p.name == "My,VM")
        #expect(p.cpus == 6)
        #expect(p.memoryMB == 16384)
        #expect(p.mac == "72:F0:0A:01:02:03")
        #expect(p.headless)
    }

    @Test func memorySuffixesAndGuestKey() {
        #expect(VMProcess(pid: 1, arguments: ["-m", "16G"]).memoryMB == 16384)
        #expect(VMProcess(pid: 1, arguments: ["-m", "size=8192M"]).memoryMB == 8192)
        #expect(VMProcess(pid: 1, arguments: ["-name", "guest=win,debug-threads=on"]).name == "win")
        #expect(VMProcess(pid: 1, arguments: ["-smp", "4"]).cpus == 4)
    }

    @Test func swtpmIsNotAVM() {
        let swtpm = VMProcess(pid: 1, arguments: ["/x/QEMULauncher", "/x/swtpm", "socket", "--tpm2"])
        #expect(!swtpm.isQEMU)
        #expect(swtpm.name == nil)
    }

    @Test func splitsQEMUOptions() {
        #expect(VMProcess.splitOptions("a,,b,c") == ["a,b", "c"])
        #expect(VMProcess.splitOptions("") == [""])
    }

    @Test func findsWritableDiskImages() {
        // As UTM 4.7 passes them: shared firmware read-only, the CD without a file, then the VM's own files.
        let p = VMProcess(pid: 1, arguments: [
            "-drive", "if=pflash,format=raw,unit=0,file.filename=/U/Library/Caches/qemu/edk2-aarch64-code.fd,file.locking=off,readonly=on",
            "-drive", "if=pflash,unit=1,file.filename=/U/Documents/Win.utm/Data/efi_vars.fd",
            "-drive", "if=none,media=cdrom,id=drive1,readonly=on",
            "-drive", "if=none,media=disk,id=drive2,file.filename=/Volumes/Ext/Win,,1.utm/Data/disk.qcow2,discard=unmap",
            "-drive", "file=/plain.img,if=virtio",
        ])
        #expect(p.diskImages == ["/U/Documents/Win.utm/Data/efi_vars.fd", "/Volumes/Ext/Win,1.utm/Data/disk.qcow2", "/plain.img"])
    }
}

@Suite struct Leases {
    let text = """
        {
        \tname=other
        \tip_address=192.168.64.9
        \thw_address=1,aa:bb:cc:dd:ee:ff
        \tlease=0x66000000
        }
        {
        \tname=WIN
        \tip_address=192.168.64.2
        \thw_address=1,72:f0:a:1:2:3
        \tlease=0x66000010
        }
        {
        \tname=WIN
        \tip_address=192.168.64.5
        \thw_address=1,72:f0:a:1:2:3
        \tlease=0x66000001
        }
        """

    @Test func matchesDroppedLeadingZerosAndPicksNewest() {
        #expect(RDP.parseLeases(text, mac: "72:F0:0A:01:02:03") == "192.168.64.2")
        #expect(RDP.parseLeases(text, mac: "00:11:22:33:44:55") == nil)
        #expect(RDP.parseLeases(text, mac: "garbage") == nil)
    }

    @Test func rdpFileHasNoPasswordField() {
        let file = RDP.rdpFile(host: "win.local", user: "someone")
        #expect(file.contains("full address:s:win.local"))
        #expect(file.contains("username:s:someone"))
        #expect(!file.lowercased().contains("password"))
    }
}

@Suite struct Guest {
    @Test func parsesOutput() {
        let out = GuestOutput.parse("\u{FEFF}A=1\r\nB=x=y\nL=one\nL=two\nnoise\nDONE=1\n")
        #expect(out["A"] == "1")
        #expect(out["B"] == "x=y")
        #expect(out.all("L") == ["one", "two"])
        #expect(out["L"] == "two")
        #expect(out.complete)
        #expect(!GuestOutput.parse("A=1").complete)
        #expect(GuestOutput.parse("T=True").bool("T") == true)
    }

    @Test func quotesForPowerShell() {
        #expect(GuestAgent.psQuote("plain") == "'plain'")
        #expect(GuestAgent.psQuote("O'Brien") == "'O''Brien'")
        // PowerShell ends a single-quoted string at typographic quotes too.
        #expect(GuestAgent.psQuote("O\u{2019}Brien") == "'O\u{2019}\u{2019}Brien'")
        #expect(GuestAgent.psQuote("a\u{0}b") == "'ab'")
        #expect(GuestAgent.psQuote("$(evil)") == "'$(evil)'")
    }

    @Test func wrapsWithCompletionProtocol() {
        let script = GuestAgent.wrap(body: "Emit 'X' 1", params: [("wbHost", "a'b")], base: #"C:\Windows\Temp\winbar-1"#)
        #expect(script.contains("$wbHost = 'a''b'"))
        #expect(script.contains(#"'C:\Windows\Temp\winbar-1.tmp'"#))
        #expect(script.contains(#"-Destination 'C:\Windows\Temp\winbar-1.out'"#))
        #expect(script.contains("Emit 'DONE' '1'"))
        let body = script.range(of: "Emit 'X' 1")!, done = script.range(of: "Emit 'DONE'")!
        #expect(body.lowerBound < done.lowerBound)
    }

    /// Every script Winbar sends, generated with awkward parameter values.
    var allScripts: [GuestScript] {
        [
            GuestScripts.survey(user: "O'Brien", passwordChecked: ["PC\\user", "PC2\\o'brien"]),
            GuestScripts.identity(user: nil),
            GuestScripts.applyPower(),
            GuestScripts.applyPowerButton(),
            GuestScripts.applyServices(),
            GuestScripts.applyVisualEffects(user: "x"),
            GuestScripts.applyRemoteDesktop(),
            GuestScripts.applyCertificate(host: "win.local", ip: "192.168.64.2"),
            GuestScripts.allowPasswordSignIn(),
            GuestScripts.openOnDesktop(user: nil, executable: "netplwiz.exe", arguments: "", elevated: true),
            GuestScripts.waitForAutologon(seconds: 90),
            GuestScripts.bitLockerStatus(),
            GuestScripts.bitLockerGuard(),
            GuestScripts.bitLockerDecrypt(),
        ]
    }

    @Test func scriptsAreStructurallySound() {
        for script in allScripts {
            let full = GuestAgent.wrap(body: script.body, params: script.params, base: #"C:\T\w"#)
            #expect(full.filter { $0 == "{" }.count == full.filter { $0 == "}" }.count)
            #expect(full.filter { $0 == "(" }.count == full.filter { $0 == ")" }.count)
            let lines = full.components(separatedBy: "\n")
            // A body that exits would skip writing the output file and stall the host for the timeout.
            #expect(!lines.contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("exit") })
            // Here-string terminators only count at the start of a line.
            for line in lines where line.trimmingCharacters(in: .whitespaces) == "'@" { #expect(line == "'@") }
            // Every $wb parameter the body uses is defined.
            let used = Set(full.matches(of: #/\$(wb[A-Za-z]+)/#).map { String($0.1) })
            let defined = Set(script.params.map(\.0)).union(["wbLines"])
            #expect(used.subtracting(defined).isEmpty, "undefined: \(used.subtracting(defined))")
        }
    }

    @Test func surveyCoversTheRecipe() {
        let body = GuestScripts.survey(user: nil, passwordChecked: []).body
        for (setting, _) in Tuning.processor { #expect(body.contains("'G1_\(setting)'")) }
        for setting in Tuning.visualEffects { #expect(body.contains("'G4_\(setting.name)'")) }
        for key in ["G2_SCHEME", "G3_SERVICE", "G5_LOGON", "G6_NLA", "G7_CERT", "G8_AUTO", "G9_STATUS", "EDITION"] {
            #expect(body.contains("'\(key)'"))
        }
        // The autologon password is only ever tested for presence.
        #expect(!body.contains("RegValue $wl 'DefaultPassword'"))
        // The mDNS name, beside the 15-character NetBIOS one.
        #expect(body.contains("'DNSHOST'"))
    }

    @Test func passwordProbeIsGuarded() {
        let script = GuestScripts.survey(user: nil, passwordChecked: ["A\\x", "B\\y"])
        #expect(script.params.contains { $0 == ("wbPasswordChecked", "A\\x|B\\y") })
        // Never probe an account that already has failed sign-ins counting towards lockout, and read
        // LogonUser's error in the same C# frame as the call.
        #expect(script.body.contains("BadPasswordAttempts"))
        #expect(script.body.contains("'G5_LOGON' 'deferred'"))
        #expect(script.body.contains("return Marshal.GetLastWin32Error();"))
    }

    @Test func desktopLaunchIsVerified() {
        let body = GuestScripts.openOnDesktop(user: nil, executable: "netplwiz.exe", arguments: "", elevated: true).body
        #expect(body.contains("Register-ScheduledTask -TaskName $name -Action $action -Principal $principal -Settings $settings -Force -ErrorAction Stop"))
        #expect(body.contains("Start-ScheduledTask -TaskName $name -ErrorAction Stop"))
        #expect(body.contains("LastTaskResult"))
        // Decimal, because Windows PowerShell reads 0x80000000 and up as negative.
        #expect(body.contains("2147943140") && !body.contains("0x800702E4"))
        #expect(body.contains("Emit 'OPENED'"))
    }

    @Test func certificateNamesTheDNSHost() {
        let body = GuestScripts.applyCertificate(host: "win.local", ip: nil).body
        #expect(body.contains("[System.Net.Dns]::GetHostName()"))
        #expect(!body.contains("'&DNS=' + $env:COMPUTERNAME"))
    }

    @Test func defaultHostPrefersTheDNSName() {
        #expect(GuestOutput.parse("COMPUTERNAME=WINLAB01-ARM64-\nDNSHOST=winlab01-arm64-vm").defaultRDPHost == "winlab01-arm64-vm.local")
        #expect(GuestOutput.parse("COMPUTERNAME=DESKTOP-ABC\nDNSHOST=").defaultRDPHost == "desktop-abc.local")
        #expect(GuestOutput.parse("COMPUTERNAME=").defaultRDPHost == nil)
    }

    @Test func blankPasswordBlocksRemoteDesktopProtections() {
        #expect(Recipe.blankPassword(GuestOutput.parse("G5_SOURCE=Local\nG5_LOGON=ok")))
        #expect(Recipe.blankPassword(GuestOutput.parse("G5_SOURCE=Local\nG5_LOGON=1327")))
        #expect(!Recipe.blankPassword(GuestOutput.parse("G5_SOURCE=Local\nG5_LOGON=1326")))
        #expect(!Recipe.blankPassword(GuestOutput.parse("G5_SOURCE=Local\nG5_LOGON=skipped")))
        #expect(!Recipe.blankPassword(GuestOutput.parse("G5_SOURCE=Local\nG5_LOGON=deferred")))
        #expect(!Recipe.blankPassword(GuestOutput.parse("G5_SOURCE=MicrosoftAccount\nG5_LOGON=ok")))
    }

    @Test func visualValuesAreTyped() {
        let mask = Tuning.visualEffects.first { $0.name == "UserPreferencesMask" }!
        #expect(mask.powerShellValue == "([byte[]](0x90,0x12,0x03,0x80,0x10,0x00,0x00,0x00))")
        #expect(Tuning.visualEffects.first { $0.name == "MinAnimate" }!.powerShellValue == "'0'")
    }

    @Test func bitLockerState() {
        let on = BitLockerState(GuestOutput.parse("G9_STATUS=FullyEncrypted\nG9_PROTECTION=On\nG9_PERCENT=100"))!
        #expect(!on.decrypted && on.protected && !on.decrypting)
        #expect(BitLockerState(GuestOutput.parse("G9_STATUS=Unavailable"))!.decrypted)
        #expect(BitLockerState(GuestOutput.parse("G9_STATUS=DecryptionInProgress\nG9_PERCENT=40"))!.decrypting)
        #expect(BitLockerState(GuestOutput.parse("G9_ERROR=nope")) == nil)
    }
}

@Suite struct Scripting {
    @Test func parsesVMList() {
        let us = "\u{1F}", rs = "\u{1E}"
        let text = ["A-1", "Win 11", "started", "qemu", "windows", "aarch64", "true", "6", "16384", "0", "72:f0:0a:01:02:03", "shared"]
            .joined(separator: us) + rs
            + ["B-2", "Linux", "stopped", "apple", "linux", "", "", "", "", "", "", ""].joined(separator: us)
        let vms = UTMScripting.parseList(text)
        #expect(vms.count == 2)
        #expect(vms[0] == VMInfo(id: "A-1", name: "Win 11", status: "started", backend: "qemu", icon: "windows",
                                 architecture: "aarch64", hypervisor: true, cpuCores: 6, memoryMB: 16384,
                                 displayCount: 0, mac: "72:f0:0a:01:02:03", networkMode: "shared"))
        #expect(vms[0].isWindows && vms[0].isRunning && vms[0].headless == true)
        #expect(!vms[1].isRunning && vms[1].cpuCores == nil && vms[1].mac == nil)
        #expect(UTMScripting.parseList("").isEmpty)
    }

    @Test func escapedNamesSurviveTheSeparators() {
        let us = "\u{1F}"
        // What the script's `esc` makes of "Win%1F" + US + "x" + RS + "y": "%" first, then the separators.
        let text = ["A-1", "100%25 Win%1Fx%1Ey", "stopped", "qemu", "my%25icon", "aarch64", "true", "6", "8192", "1", "", "shared"]
            .joined(separator: us)
        let vms = UTMScripting.parseList(text)
        #expect(vms.count == 1)
        #expect(vms.first?.name == "100% Win\u{1F}x\u{1E}y")
        #expect(vms.first?.icon == "my%icon")
        #expect(vms.first?.status == "stopped")
        // A record with a stray separator no longer shifts its columns into the wrong fields: it's dropped.
        let shifted = ["A-1", "Win", "11", "stopped", "qemu", "", "", "", "", "", "", "", ""].joined(separator: us)
        #expect(UTMScripting.parseList(shifted).isEmpty)
    }

    @Test func scriptsMatchNamesExactlyAndKeepCustomIcons() {
        #expect(UTMScripting.updateScript.contains("considering case"))
        #expect(UTMScripting.updateScript.contains("number 1003"))
        #expect(UTMScripting.updateScript.contains("set icon of c to \"\""))
        let icon = UTMScripting.updateScript.range(of: "set icon of c to")!
        let update = UTMScripting.updateScript.range(of: "update configuration of theVM with c")!
        #expect(icon.lowerBound < update.lowerBound)
        #expect(UTMScripting.listScript.contains("my esc((name of vm) as text)"))
        #expect(UTMScripting.listScript.contains("my esc((icon of c) as text)"))
    }

    @Test func explainsOsascriptErrors() {
        #expect(AppleScriptRunner.errorNumber(in: "Not authorized to send Apple events to UTM. (-1743)") == -1743)
        #expect(AppleScriptRunner.errorNumber(in: "UTM has no virtual machine named x (1001)\n") == 1001)
        #expect(AppleScriptRunner.errorNumber(in: "no number here") == nil)
        #expect(AppleScriptRunner.explain("Not authorized to send Apple events to UTM. (-1743)").automationDenied)
        #expect(AppleScriptRunner.explain("AppleEvent timed out. (-1712)").title == "UTM didn't answer in time")
        #expect(!AppleScriptRunner.explain("UTM has no virtual machine named x (1001)").automationDenied)
        #expect(Automation.isDenied("Error: OSStatus error -1743."))
        #expect(Automation.terminal("Apple_Terminal") == ("Terminal", "com.apple.Terminal"))
        #expect(Automation.terminal(nil).bundleID == nil)
    }

    @Test func scriptsTakeValuesOnlyAsArguments() {
        // Values reach AppleScript as argv items; the sources never interpolate anything.
        #expect(UTMScripting.updateScript.contains("item 1 of argv"))
        #expect(!UTMScripting.updateScript.contains("\\("))
        #expect(!UTMScripting.listScript.contains("\\("))
    }

    @Test func cleansOsascriptErrors() {
        #expect(AppleScriptRunner.cleanError("-: execution error: UTM has no VM (1001)\n") == "UTM has no VM (1001)")
    }
}

@Suite struct Recommendations {
    @Test func vcpusClampToFourThroughEight() {
        #expect(Tuning.recommendedCPUs(topTierCores: 2) == 4)
        #expect(Tuning.recommendedCPUs(topTierCores: 6) == 6)
        #expect(Tuning.recommendedCPUs(topTierCores: 12) == 8)
    }

    @Test func ramTiersCappedAtHalf() {
        let gib: UInt64 = 1 << 30
        #expect(Tuning.recommendedMemoryMB(hostBytes: 128 * gib) == 16384)
        #expect(Tuning.recommendedMemoryMB(hostBytes: 36 * gib) == 12288)
        #expect(Tuning.recommendedMemoryMB(hostBytes: 24 * gib) == 8192)
        #expect(Tuning.recommendedMemoryMB(hostBytes: 8 * gib) == 4096)
    }

    @Test func pendingUTMRestartBookkeeping() {
        // A second unsettled change keeps the first one's processes.
        let first = UTMRestart.recording(vm: "Win", pids: [300, 200], over: nil)
        #expect(first == UTMRestart(vm: "Win", pids: [200, 300]))
        let second = UTMRestart.recording(vm: "Win", pids: [400, 200], over: first)
        #expect(second.pids == [200, 300, 400])
        // Settled once none of them is UTM any more.
        #expect(second.stillRunning { $0 == 400 } == [400])
        #expect(second.stillRunning { _ in false }.isEmpty)
        // Stored as a plist dictionary in the defaults.
        #expect(UTMRestart(plist: second.plist) == second)
        #expect(UTMRestart(plist: ["vm": "Win"]) == nil)
    }

    @Test func forceStopQuestionPutsUpdatesFirst() {
        let why = UTM.forceStopQuestion("Win", minutes: 7)
        #expect(why.contains("7 minutes"))
        #expect(why.range(of: "updates")!.lowerBound < why.range(of: "unsaved work")!.lowerBound)
    }

    @Test func localNetworkDenialNeedsTwoImmediateRefusals() {
        #expect(RDP.looksDenied([EHOSTUNREACH, EHOSTUNREACH]))
        #expect(RDP.looksDenied([EPERM, EACCES]))
        // ARP giving up on a booting VM: one EHOSTUNREACH, then EHOSTDOWN.
        #expect(!RDP.looksDenied([EHOSTUNREACH, EHOSTDOWN]))
        #expect(!RDP.looksDenied([EHOSTUNREACH]))
        #expect(!RDP.looksDenied([ECONNREFUSED, ECONNREFUSED]))
    }

    @Test func storageIsDecidedByPath() {
        let resolve: (String) -> String? = { $0 == "/Volumes/Mac HD" ? "/" : $0 }
        #expect(Host.storage(of: "/Users/a/Library/Containers/com.utmapp.UTM/Data/Documents/W.utm/Data/d.qcow2", resolve: resolve) == .startupDisk)
        #expect(Host.storage(of: "/Volumes/Ext SSD/VMs/W.utm/Data/d.qcow2", resolve: resolve) == .volume("/Volumes/Ext SSD"))
        #expect(Host.storage(of: "/Volumes/Mac HD/Users/a/W.utm/Data/d.qcow2", resolve: resolve) == .startupDisk)
        #expect(Host.Storage.volume("/Volumes/Ext SSD").description == "Ext SSD")
    }

    @Test func changeSummary() {
        #expect(ConfigChanges().isEmpty)
        #expect(ConfigChanges(cpuCores: 6, memoryMB: 16384, display: .headless).summary == "6 vCPUs, 16384 MB RAM, headless")
    }
}

@Suite struct CLIParsing {
    @Test func dualModeRule() {
        func mode(_ arguments: [String], tty: Bool, launchServices: Bool) -> CLI.Mode {
            CLI.mode(arguments: CLI.normalized(arguments), stdoutIsTTY: tty, launchedByLaunchServices: launchServices)
        }
        #expect(mode([], tty: true, launchServices: false) == .help)
        #expect(mode([], tty: false, launchServices: true) == .app)
        #expect(mode(["doctor"], tty: false, launchServices: false) == .cli)
        #expect(mode(["--version"], tty: true, launchServices: false) == .cli)
        #expect(mode(["--self-test"], tty: false, launchServices: true) == .cli)
        #expect(mode(["-psn_0_12345"], tty: false, launchServices: true) == .app)
        #expect(mode(["-NSDocumentRevisionsDebugMode", "YES"], tty: false, launchServices: true) == .app)
        #expect(mode(["statsu"], tty: true, launchServices: false) == .unknownCommand("statsu"))
        // Typed at a shell, an unknown option is a mistake, not a reason to start a second menu bar app.
        #expect(mode(["-v"], tty: true, launchServices: false) == .unknownCommand("-v"))
        #expect(mode(["--vm", "X", "doctor"], tty: true, launchServices: false) == .unknownCommand("--vm"))
        #expect(mode(["--verison"], tty: false, launchServices: false) == .unknownCommand("--verison"))
        // Whatever LaunchServices puts first, the real command is still found.
        #expect(mode(["-psn_0_1", "--self-test"], tty: false, launchServices: true) == .cli)
        #expect(mode(["-AppleLanguages", "(en)", "connect"], tty: false, launchServices: true) == .cli)
        #expect(CLI.normalized(["-psn_0_1", "connect", "--parent-pid", "42"]) == ["connect", "--parent-pid", "42"])
    }

    @Test func parsesOptions() throws {
        let parsed = try CLI.parse(["--vm", "Win 11", "--yes", "--host=a.local", "on"],
                                   values: ["--vm", "--host"], switches: ["--yes"]).get()
        #expect(parsed.values["--vm"] == "Win 11")
        #expect(parsed.values["--host"] == "a.local")
        #expect(parsed.has("--yes"))
        #expect(parsed.positionals == ["on"])
        #expect(throws: WinbarError.self) { try CLI.parse(["--nope"], values: [], switches: []).get() }
        #expect(throws: WinbarError.self) { try CLI.parse(["--vm"], values: ["--vm"], switches: []).get() }
    }

    @Test func usageListsEverySubcommand() {
        for command in CLI.commands { #expect(CLI.usage.contains(command)) }
        for flag in ["--self-test", "--version", "--keep-bitlocker", "--no-visual-tweaks", "--headless", "--console",
                     "--anonymise", "--no-logs", "--out"] {
            #expect(CLI.usage.contains(flag))
        }
    }

    /// `winbar help` is a fourth copy of what `--anonymise` promises, alongside the report's own
    /// mode line, the menu's alert and the README — and it is the copy that drifted, because nothing
    /// checked it. It spent 0.1.1 two omissions behind the others. This is not a proof that the
    /// sentence is right, which no test can be; it is a floor, so that the next thing the flag
    /// starts replacing can't be added to three copies and forgotten in the one nobody tests.
    /// The flag's one-line summary is a promise about somebody's privacy, so it is checked against
    /// what the code does rather than against the word "id" — which the sentence "replaces every id
    /// in the file" satisfied while the rule was, and still is, scoped to two shapes. That wording
    /// was wider than the code: an identifier of some other shape has never been touched.
    @Test func usageDescribesWhatAnonymiseReplaces() {
        let line = CLI.usage.components(separatedBy: "\n")
            .drop { !$0.contains("--anonymise replaces") }.prefix(3).joined(separator: " ")
        for promised in ["Mac's name", "user names", "VM names", "Windows PC name",
                         "id-shaped", "MAC-shaped", "placeholders"] {
            #expect(line.contains(promised), "winbar help no longer says --anonymise replaces the \(promised)")
        }
        // The claim the code cannot keep, in either of the two forms it has been written in.
        #expect(!line.contains("every id in the file"))
        #expect(!line.contains("every id "))
        // And the two shapes it does name are the two the Redactor really replaces, while something
        // of a third shape is left exactly as it was.
        let redactor = Redactor(mode: .anonymised, identity: .init(userName: "rosa", vmNames: ["winlab01"]))
        #expect(redactor.apply("deadbeef-cafe-4a1b-9c2d-0123456789ab") == "<id-1>")
        #expect(redactor.apply("5A:2B:3C:4D:5E:6F") == "<mac-address-1>")
        #expect(redactor.apply("serial C02XK1JYJG5H") == "serial C02XK1JYJG5H")
    }

    @Test func hostNames() {
        #expect(Config.isValidHostName("win-11.local"))
        #expect(!Config.isValidHostName("a&DNS=evil"))
        #expect(!Config.isValidHostName("has space.local"))
        #expect(!Config.isValidHostName(".local"))
        #expect(!Config.isValidHostName(""))
        // A NetBIOS name Windows cut at 15 characters can end in a hyphen.
        #expect(!Config.isValidHostName("winlab01-arm64-.local"))
        #expect(!Config.isValidHostName("-win.local"))
        #expect(!Config.isValidHostName("win..local"))
        #expect(!Config.isValidHostName(String(repeating: "a", count: 64) + ".local"))
    }

    @Test func settingsHelpers() {
        #expect(Config.parseSwitch("yes") == true && Config.parseSwitch("On") == true)
        #expect(Config.parseSwitch("no") == false && Config.parseSwitch("") == false)
        #expect(Config.parseSwitch("maybe") == nil)
        var list = Config.updatePasswordChecked([], key: "PC\\a", hasPassword: true)
        list = Config.updatePasswordChecked(list, key: "PC2\\b", hasPassword: true)
        #expect(list == ["PC\\a", "PC2\\b"])
        #expect(Config.updatePasswordChecked(list, key: "pc\\A", hasPassword: false) == ["PC2\\b"])
        #expect(Config.updatePasswordChecked(list, key: "PC\\a", hasPassword: true) == ["PC2\\b", "PC\\a"])
        #expect(Config.updatePasswordChecked(list, key: "X\\c", hasPassword: true, limit: 2) == ["PC2\\b", "X\\c"])
    }

    /// What `winbar create`'s checklist answered is kept per VM, so setup mentions it once instead
    /// of offering the same three things every run.
    @Test func declinedChoicesAreRememberedForTheVM() {
        for key in [Config.Key.declinedAutologon, Config.Key.declinedRemoteDesktop, Config.Key.declinedTuning] {
            #expect(Config.Key.all.contains(key))
            #expect(Config.Key.perVM.contains(key), "\(key) belongs to one VM")
        }
        #expect(Setup.declinedSwitch("G8", autologon: true, remoteDesktop: false, tuning: false) == "--autologon")
        #expect(Setup.declinedSwitch("G6", autologon: false, remoteDesktop: true, tuning: false) == "--remote-desktop")
        for id in ["G1", "G2", "G3", "G4"] {
            #expect(Setup.declinedSwitch(id, autologon: false, remoteDesktop: false, tuning: true) == "--winbar-tuning")
        }
        // Nothing declined, and checks that belong to no checklist row, are offered as usual.
        #expect(Setup.declinedSwitch("G8", autologon: false, remoteDesktop: false, tuning: false) == nil)
        for id in ["G0", "G5", "G7", "G9", "H7", "C2"] {
            #expect(Setup.declinedSwitch(id, autologon: true, remoteDesktop: true, tuning: true) == nil, "\(id)")
        }
        for flag in ["--autologon", "--remote-desktop", "--winbar-tuning"] { #expect(CLI.usage.contains(flag)) }
    }

    @Test func selfTestOutput() {
        let values = SelfTest.parse("accessibility:   true\nlogin item:      enabled\nwindows app:     /Applications/Windows App.app\n")
        #expect(values["accessibility"] == "true")
        #expect(values["login item"] == "enabled")
        #expect(values["windows app"] == "/Applications/Windows App.app")
    }
}

@Suite struct VMProcessIdentity {
    /// UTM strips everything but letters, digits and spaces from the name it gives QEMU
    /// (UTMQemuArgs.cleanupName), so a VM called "winbar-test" runs as `-name winbartest`. Matching
    /// on the raw name alone made `winbar create` read its own successful start as a failure.
    @Test func cleansNamesTheWayUTMDoes() {
        #expect(VMProcess.cleanedName("winbar-test") == "winbartest")
        #expect(VMProcess.cleanedName("Windows 11 (work)") == "Windows 11 work")
        #expect(VMProcess.cleanedName("winlab01") == "winlab01")
        #expect(VMProcess.cleanedName("Alex's Mac.VM") == "Alexs MacVM")
    }

    @Test func readsTheUUIDArgument() {
        let p = VMProcess(pid: 1, arguments: ["-name", "winbartest", "-uuid", "5F1AE5BF-A1E4-49EB-AB22-DE61DAFC6812"])
        #expect(p.uuid == "5F1AE5BF-A1E4-49EB-AB22-DE61DAFC6812")
        #expect(VMProcess(pid: 1, arguments: ["-name", "x"]).uuid == nil)
    }
}

@Suite struct OtherRunningVMNames {
    /// A VM whose name has punctuation runs under a stripped name, so comparing raw names makes the
    /// VM report itself as somebody else's VM — which made `winbar display off` refuse to touch the
    /// very VM it was asked about (found live, 2026-09-20).
    @Test func aVMIsNotItsOwnStranger() {
        let mine = VMProcess(pid: 1, arguments: ["-name", "winbartest", "-uuid", "F1425E82-F26B-4C1A-9654-466DB2A4A563"])
        let other = VMProcess(pid: 2, arguments: ["-name", "winlab01", "-uuid", "8B1F0C52-0000-4E2A-9A11-DEADBEEF0003"])
        let cleaned = VMProcess.cleanedName("winbar-test")
        #expect(mine.name == cleaned)
        #expect(other.name != cleaned && other.name != "winbar-test")
        // The same VM by id, whatever its name says.
        #expect(mine.uuid?.caseInsensitiveCompare("f1425e82-f26b-4c1a-9654-466db2a4a563") == .orderedSame)
    }
}
