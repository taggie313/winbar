import Foundation
import Testing
@testable import Winbar

// G12, "Remote Desktop graphics". UTM 5 can install a DirectX driver in Windows (viogpu3d, service
// VioGpu3D) for a VM made with its experimental 3D acceleration. Measured live on UTM 5.0.6: with that
// driver installed and Remote Desktop's "Use hardware graphics adapters for all Remote Desktop Services
// sessions" not configured or on, Windows App showed a blank grey desktop; off, it drew normally. The
// driver finds its GPU among the session's display adapters, and a Remote Desktop session has only its
// own. Winbar's own VMs get the display-only driver, so this is for a VM adopted with `winbar setup --vm`.
// The policy was measured with Windows restarted after it was set, so until that restart the row says
// so, and the tune step waits, rather than sending Ben on to the same blank desktop at Connect.

private func out(_ pairs: [(String, String)]) -> GuestOutput { GuestOutput(pairs: pairs.map { (key: $0.0, value: $0.1) }) }

/// The survey's G12 lines. `bound` nil is a device probe that didn't answer (no G12_BOUND at all).
private func status(installed: Bool, bound: Bool? = true, policy: String, kind: String? = nil,
                    pending: Bool = false, edition: String = "Professional") -> Status {
    var pairs = [("EDITION", edition), ("G12_3D", installed ? "True" : "False"), ("G12_POLICY", policy),
                 ("G12_POLICY_KIND", kind ?? (policy.isEmpty ? "" : "DWord")), ("G12_PENDING", pending ? "True" : "False")]
    if let bound { pairs.append(("G12_BOUND", bound ? "True" : "False")) }
    return Recipe.remoteDesktopGraphicsStatus(out(pairs))
}

private func source(_ path: String) throws -> String {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
}

/// Every line G12's row can say, and the manual row's instructions: what the window shows, once in its words.
private var everyLine: [String] {
    let rows = [status(installed: false, policy: ""), status(installed: true, policy: "0"),
                status(installed: true, policy: "0", pending: true), status(installed: true, policy: ""),
                status(installed: true, bound: false, policy: ""),
                status(installed: true, policy: "", edition: "Core")]
    return rows.flatMap { row -> [String] in
        if case .manual(let detail, let how) = row { return [detail, how] }
        return [row.detail]
    }
}

@Suite("Remote Desktop draws with Windows' own renderer when UTM's 3D driver is installed")
struct RemoteDesktopGraphicsTests {
    // MARK: The row

    /// Every VM Winbar makes: the display-only driver, nothing to change, and doctor still exits 0.
    @Test("No 3D driver is done, whatever the policy says, and says there's nothing to change")
    func noDriver() {
        for policy in ["", "0", "1"] {
            let row = status(installed: false, policy: policy)
            #expect(row.isOK, "\(policy)")
            #expect(row.detail == "nothing to change: UTM's 3D graphics driver isn't installed")
        }
    }

    /// A setting, not a result: the ok line doesn't claim the desktop draws, only what Remote Desktop is set to.
    @Test("The 3D driver with the policy off, and Windows started since, is done")
    func driverAndPolicyOff() {
        let row = status(installed: true, policy: "0")
        #expect(row.isOK)
        #expect(row.detail == "Remote Desktop set to draw with Windows' own renderer")
        // The window says it in its own words.
        #expect(SetupCopy.Tune.words(row.detail) == "Remote Desktop set to draw with Windows' own graphics")
    }

    /// Set since Windows last started (the fix's volatile marker): the desktop is still blank until a
    /// restart, so the row is the person's to finish, not a tick, and the tune step waits on it.
    @Test("Set but not yet in effect is a restart for the person to do, and holds the tune step")
    func setButWaitingForARestart() throws {
        let row = status(installed: true, policy: "0", pending: true)
        guard case .manual(let detail, let how) = row else { Issue.record("\(row)"); return }
        #expect(detail.contains("until Windows restarts"))
        #expect(detail.contains("blank in Windows App"))
        #expect(how == "Restart Windows from its Start menu (console window), then run this again.")
        #expect(SetupCopy.Tune.how("G12", how)
                == "Restart Windows from its Start menu (on Windows' screen), then choose I've Restarted Windows.")
        #expect(row.needsAttention, "doctor doesn't call it done either")

        let check = try #require(Recipe.check("G12"))
        var facts = JourneyFixtures.facts
        #expect(SetupFlow.isSatisfied(.tune, facts), "the control: every other row is done")
        facts.rows["G12"] = SetupFlow.Row(check, row)
        #expect(!SetupFlow.isSatisfied(.tune, facts))
        #expect(SetupFlow.fixEverything(facts).isEmpty, "a second Fix wouldn't restart anything")
        let actions = SetupTuneRowActions.of(try #require(facts.rows["G12"]), facts: facts).map(\.title)
        #expect(actions == ["I've Restarted Windows", SetupCopy.bSkip])
    }

    /// With the screen off the driver has no device, and the only way it gets one back is turning the
    /// screen on, which restarts the VM: the start the policy needs.
    @Test("Set with the screen off is done: turning the screen back on is the restart")
    func setWithTheScreenOff() {
        #expect(status(installed: true, bound: false, policy: "0", pending: true).isOK)
        // A device probe that didn't answer isn't taken as "no device".
        guard case .manual = status(installed: true, bound: nil, policy: "0", pending: true) else {
            Issue.record("a missing probe passed a restart still to do"); return
        }
    }

    /// Not configured is Windows' default, which is hardware first: the blank desktop measured live.
    @Test("The 3D driver with the policy not set is a fix")
    func driverPolicyAbsent() {
        let row = status(installed: true, policy: "")
        #expect(row.isFixable)
        #expect(row.detail == "Remote Desktop would try UTM's 3D graphics driver first, which leaves the Windows desktop "
                    + "blank in Windows App")
    }

    @Test("The 3D driver with the policy on is a fix")
    func driverPolicyOn() {
        #expect(status(installed: true, policy: "1").isFixable)
    }

    /// Windows reads the policy as a DWORD; a string "0" from a hand edit reads as 0 but does nothing.
    @Test("A 0 that isn't a DWORD is a fix, which writes it as one")
    func policyOfTheWrongType() {
        #expect(status(installed: true, policy: "0", kind: "String").isFixable)
        #expect(status(installed: true, policy: "0", kind: "QWord").isFixable)
    }

    /// With the screen off Windows has no display device for the driver, but it's still installed, and
    /// turning the screen back on binds it again: going by "bound" would pass a VM that breaks later.
    @Test("An installed driver with no device bound (screen off) is still a fix")
    func driverUnboundWithTheScreenOff() {
        let row = status(installed: true, bound: false, policy: "")
        #expect(row.isFixable)
        #expect(row.detail.contains("once the console window is back (winbar display on)"))
        #expect(SetupCopy.Tune.words(row.detail).contains("once Windows' screen is back on"))
        #expect(status(installed: true, bound: false, policy: "0").isOK)
        // A probe that didn't answer says what's certain, without the screen.
        #expect(!status(installed: true, bound: nil, policy: "").detail.contains("console window"))
    }

    /// As G6 says of Home: there's no Remote Desktop to fix, so no second actionable row for it.
    @Test("Windows Home has nothing here to fix")
    func home() {
        let row = status(installed: true, policy: "", edition: "Core")
        guard case .info(let detail) = row else { Issue.record("\(row)"); return }
        #expect(detail == "Windows Home can't host Remote Desktop (G0)")
    }

    @Test("A survey that failed says so, instead of calling the driver missing")
    func surveyFailed() {
        let row = Recipe.remoteDesktopGraphicsStatus(out([("G12_ERROR", "Access is denied")]))
        guard case .error(let detail) = row else { Issue.record("\(row)"); return }
        #expect(detail.contains("Access is denied"))
        #expect(!Recipe.remoteDesktopGraphicsStatus(out([])).isOK, "a survey without the section proves nothing")
    }

    // MARK: The scripts

    @Test("The survey reports the driver, the policy, the restart still owed and the device, with the names passed in once")
    func survey() {
        let script = GuestScripts.survey(user: nil, passwordChecked: [])
        for key in ["G12_3D", "G12_BOUND", "G12_POLICY", "G12_POLICY_KIND", "G12_PENDING", "G12_ERROR"] {
            #expect(script.body.contains("Emit '\(key)'"), "\(key)")
        }
        #expect(script.body.contains("Get-PnpDevice -Class Display -PresentOnly"))
        #expect(script.body.contains("DEVPKEY_Device_Service"))
        #expect(script.body.contains(#"'HKLM:\SYSTEM\CurrentControlSet\Services\' + $wbGpuService"#))
        #expect(script.body.contains("RegValue $wbGraphicsPolicy $wbGraphicsName"))
        #expect(script.body.contains("RegKind $wbGraphicsPolicy $wbGraphicsName"))
        #expect(script.body.contains(#"Test-Path -LiteralPath ('HKLM:\' + $wbGraphicsMarker)"#))
        #expect(script.params.contains { $0 == ("wbGraphicsPolicy", Tuning.rdpGraphicsPolicyKey) })
        #expect(script.params.contains { $0 == ("wbGraphicsName", "bEnumerateHWBeforeSW") })
        #expect(script.params.contains { $0 == ("wbGpuService", "VioGpu3D") })
        #expect(script.params.contains { $0 == ("wbGraphicsMarker", Tuning.rdpGraphicsMarkerKey) })
        // Parameters, not a second copy of the path in the script.
        #expect(!script.body.contains(Tuning.rdpGraphicsPolicyKey))
        #expect(!script.body.contains("bEnumerateHWBeforeSW"))
        #expect(!script.body.contains(Tuning.rdpGraphicsMarkerKey))
        #expect(Tuning.rdpGraphicsPolicyKey == #"HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services"#)
    }

    /// The facts that decide the row come before the device probe, which has a catch of its own: a PnP
    /// module that won't load would otherwise turn the row into an error that Fix Everything passes by.
    @Test("The device probe comes last and fails on its own, and only runs with the driver installed")
    func probeFailsAlone() throws {
        let body = GuestScripts.survey(user: nil, passwordChecked: []).body
        let section = try #require(body.range(of: "# G12 Remote Desktop graphics")).lowerBound
        let g12 = String(body[section...])
        let policy = try #require(g12.range(of: "Emit 'G12_POLICY'")).lowerBound
        let pending = try #require(g12.range(of: "Emit 'G12_PENDING'")).lowerBound
        let probe = try #require(g12.range(of: "Get-PnpDevice")).lowerBound
        #expect(policy < probe && pending < probe)
        let guarded = try #require(g12.range(of: "if ($gpu3D) {\n    try {")).lowerBound
        #expect(guarded < probe)
        let innerCatch = try #require(g12.range(of: "} catch { }")).lowerBound
        let outerCatch = try #require(g12.range(of: "} catch { Emit 'G12_ERROR'")).lowerBound
        #expect(probe < innerCatch && innerCatch < outerCatch)
    }

    /// `New-Item -Force` on a key that exists replaces it, and every policy in it with it.
    @Test("The fix sets 0 as a DWORD, makes only the keys that are missing, and stops on a refusal")
    func apply() {
        let script = GuestScripts.applyRemoteDesktopGraphics()
        #expect(Tuning.rdpGraphicsPolicyValue == 0)
        #expect(script.params.contains { $0 == ("wbGraphicsValue", "0") })
        #expect(script.params.contains { $0 == ("wbGraphicsPolicy", Tuning.rdpGraphicsPolicyKey) })
        #expect(script.params.contains { $0 == ("wbGraphicsName", Tuning.rdpGraphicsPolicyName) })
        #expect(script.body.contains("Set-ItemProperty -Path $wbGraphicsPolicy -Name $wbGraphicsName -Value ([int]$wbGraphicsValue) "
                                         + "-Type DWord -ErrorAction Stop"))
        #expect(script.body.contains("if (-not (Test-Path -LiteralPath $path)) { New-Item -Path $path -ErrorAction Stop | Out-Null }"))
        let code = script.body.split(separator: "\n").filter { !$0.hasPrefix("#") }
        #expect(!code.contains { $0.contains("-Force") })
        #expect(script.body.contains("Emit 'APPLIED' '1'"))
    }

    /// Windows drops a volatile key when it starts, which is exactly when the policy takes effect: the
    /// survey's G12_PENDING. Made before the policy, so a marker that can't be made changes nothing.
    @Test("The fix leaves a volatile marker, before it writes the policy")
    func marker() throws {
        let script = GuestScripts.applyRemoteDesktopGraphics()
        #expect(script.params.contains { $0 == ("wbGraphicsMarker", Tuning.rdpGraphicsMarkerKey) })
        let create = try #require(script.body.range(of: "[Microsoft.Win32.Registry]::LocalMachine.CreateSubKey($wbGraphicsMarker, "
                                                        + "[Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree, "
                                                        + "[Microsoft.Win32.RegistryOptions]::Volatile).Close()")).lowerBound
        let policy = try #require(script.body.range(of: "Set-ItemProperty")).lowerBound
        #expect(create < policy)
        // One level under SOFTWARE: a volatile SOFTWARE\Winbar would refuse every stable key made under it later.
        #expect(Tuning.rdpGraphicsMarkerKey.hasPrefix(#"SOFTWARE\"#))
        #expect(Tuning.rdpGraphicsMarkerKey.split(separator: "\\").count == 2)
    }

    // MARK: Where it sits

    @Test("The recipe's G12 is a guest fix that needs no VM restart, after the shared folder")
    func recipe() throws {
        let check = try #require(Recipe.check("G12"))
        #expect(check.section == .guest)
        #expect(check.title == "Remote Desktop graphics")
        #expect(check.apply != nil)
        #expect(check.needsRestart == false)
        #expect(check.why.contains("next time Windows starts"))
        #expect(Array(Recipe.guest.map(\.id).suffix(2)) == ["G11", "G12"])
        #expect(try source("Sources/Winbar/Recipe.swift")
                    .contains("evaluate: { ctx in guestStatus(ctx) { out in remoteDesktopGraphicsStatus(out) } }"))
    }

    /// Only the fix pass: a Windows restart walked in the middle of the manual pass would leave the
    /// steps after it reading a Windows that isn't back yet. The closing report says it instead.
    @Test("Tune has it right after the certificate, and winbar setup fixes it in the same place")
    func placed() throws {
        let tune = SetupFlow.checks(in: .tune)
        let g7 = try #require(tune.firstIndex(of: "G7"))
        #expect(tune.firstIndex(of: "G12") == g7 + 1)
        let fixPass = Setup.fixPass
        let setupG7 = try #require(fixPass.firstIndex(of: "G7"))
        #expect(fixPass.firstIndex(of: "G12") == setupG7 + 1)
        #expect(!Setup.manualPass.contains("G12"))
        #expect(!SetupFlow.unplaced.contains("G12"))
    }

    @Test("A fixable row on the tune page is a plain Fix, and Fix Everything presses it")
    func onTheTunePage() throws {
        let check = try #require(Recipe.check("G12"))
        var facts = JourneyFixtures.facts
        facts.rows["G12"] = SetupFlow.Row(check, status(installed: true, policy: ""))
        #expect(facts.rows["G12"]?.action == .fix)
        #expect(SetupFlow.fixEverything(facts) == ["G12"])
    }

    /// The window's reason names no driver: Ben knows UTM and Remote Desktop, not viogpu3d.
    @Test("The window's reason is plain, names no driver, and says when it takes effect")
    func windowWhy() throws {
        let why = try #require(SetupCopy.Tune.why("G12"))
        for name in ["viogpu3d", "VioGpu3D", "Neptune", "DirectX", "policy", "GPU", "renderer"] {
            #expect(!why.localizedCaseInsensitiveContains(name), "\(name)")
        }
        #expect(why.contains("Remote Desktop"))
        #expect(why.contains("3D apps"))
        #expect(why.hasSuffix("This takes effect the next time Windows starts."))
    }

    /// The status lines reach the window too, through `Tune.words`, and nothing else holds them to the
    /// window's vocabulary: `SetupCopyJargonTests` covers titles and reasons.
    @Test("Every line the row can show reads in the window's words")
    func windowLines() {
        #expect(everyLine.count == 7)
        for line in everyLine {
            let shown = SetupCopy.Tune.how("G12", line)
            for word in SetupCopyJargonTests.jargon + ["viogpu3d", "VioGpu3D", "Neptune", "DirectX", "renderer",
                                                       "winbar display"] {
                #expect(!shown.localizedCaseInsensitiveContains(word), "“\(word)” in: \(shown)")
            }
            #expect(shown.range(of: #"\b[GHC][0-9]{1,2}\b"#, options: .regularExpression) == nil, "\(shown)")
        }
    }
}
