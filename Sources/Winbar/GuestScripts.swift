import Foundation

/// A PowerShell body plus the parameters it expects. Values reach the script only as quoted literals
/// (see `GuestAgent.wrap`), never spliced into code.
struct GuestScript {
    let body: String
    var params: [(String, String)] = []
}

extension GuestAgent {
    static func run(vm: String, _ script: GuestScript, timeout: TimeInterval = 120) -> Result<GuestOutput, WinbarError> {
        run(vm: vm, script: script.body, params: script.params, timeout: timeout)
    }
}

/// Every script Winbar runs in Windows. They emit KEY=VALUE lines; the host decides what they mean.
///
/// They're written for Windows PowerShell 5.1 (the one every Windows 11 has) and avoid anything
/// locale-dependent: firewall rules by resource id, powercfg values by position, SIDs instead of
/// account names like "NETWORK SERVICE".
enum GuestScripts {
    // MARK: Shared pieces

    /// Functions available to every script (the wrapper includes them).
    static let helpers = #"""
function RegValue([string]$Path, [string]$Name) {
  try { (Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop).$Name } catch { $null }
}
function RegKind([string]$Path, [string]$Name) {
  try { (Get-Item -LiteralPath $Path -ErrorAction Stop).GetValueKind($Name).ToString() } catch { '' }
}
function HexBytes($Bytes) {
  # A byte[] returned from a function reaches the caller unrolled into object[] (or a lone byte, for a
  # one-byte value), so test for any array or byte, not [byte[]]; otherwise this emits decimals.
  if ($null -eq $Bytes) { return '' }
  if ($Bytes -is [array] -or $Bytes -is [byte]) { return (@($Bytes) | ForEach-Object { '{0:x2}' -f [int]$_ }) -join ' ' }
  $Bytes
}
# powercfg's labels are localised, but for a single setting its last two hex numbers are always the
# current AC and DC indexes, so read those rather than match English text.
function PowerIndex([string]$Scheme, [string]$Sub, [string]$Setting) {
  # /qh, not /query: the processor settings Winbar tunes are hidden, and /query prints nothing for them.
  $hex = @(powercfg /qh $Scheme $Sub $Setting 2>$null | ForEach-Object { [regex]::Matches([string]$_, '0x([0-9a-fA-F]+)') } | ForEach-Object { $_.Groups[1].Value })
  if ($hex.Count -lt 2) { return $null }
  return @([Convert]::ToInt64($hex[$hex.Count - 2], 16), [Convert]::ToInt64($hex[$hex.Count - 1], 16))
}
function AcValue([string]$Scheme, [string]$Sub, [string]$Setting) {
  $v = PowerIndex $Scheme $Sub $Setting
  if ($v) { $v[0] } else { '' }
}
function Guids($Lines) {
  @([regex]::Matches((@($Lines) -join ' '), '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}') | ForEach-Object { $_.Value.ToLower() } | Select-Object -Unique)
}
"""#

    /// Works out whose desktop this is and whose settings to tune. Needs `$wbUser` (may be empty).
    ///
    /// The interactive user is the owner of explorer.exe: Win32_ComputerSystem.UserName would be simpler
    /// but is empty while a Remote Desktop client holds the session. A configured user wins when it is
    /// a local account; a `MicrosoftAccount\...` login name can't be looked up locally, so the session
    /// owner stands in for it.
    static let userSection = #"""
$explorerUser = $null; $explorerDomain = $null; $explorerSid = $null
$wanted = if ($wbUser) { $wbUser.Split('\')[-1] } else { '' }
foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='explorer.exe'")) {
  $o = Invoke-CimMethod -InputObject $p -MethodName GetOwner
  if ($o.ReturnValue -ne 0) { continue }
  if ((-not $explorerUser) -or ($wanted -and $o.User -eq $wanted)) {
    $explorerUser = $o.User
    $explorerDomain = $o.Domain
    $explorerSid = (Invoke-CimMethod -InputObject $p -MethodName GetOwnerSid).Sid
  }
}
$localName = $explorerUser
if ($wbUser) {
  $parts = $wbUser.Split('\')
  if ($parts.Count -eq 1) { $localName = $parts[0] }
  elseif ($parts[0] -eq '.' -or $parts[0] -eq $env:COMPUTERNAME) { $localName = $parts[1] }
}
$userSid = $null
if ($localName -and $localName -eq $explorerUser) { $userSid = $explorerSid }
elseif ($localName) {
  try { $userSid = (New-Object System.Security.Principal.NTAccount($env:COMPUTERNAME, $localName)).Translate([System.Security.Principal.SecurityIdentifier]).Value } catch { }
}
Emit 'COMPUTERNAME' $env:COMPUTERNAME
# What Windows answers mDNS for. COMPUTERNAME is the NetBIOS name, cut to 15 characters.
Emit 'DNSHOST' ([System.Net.Dns]::GetHostName())
Emit 'SESSION_USER' $explorerUser
Emit 'USER' $localName
Emit 'USER_SID' $userSid
"""#

    static let bitLockerSection = #"""
try {
  if (Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue) {
    $bv = Get-BitLockerVolume -MountPoint 'C:' -ErrorAction Stop
    Emit 'G9_STATUS' $bv.VolumeStatus
    Emit 'G9_PROTECTION' $bv.ProtectionStatus
    Emit 'G9_PERCENT' $bv.EncryptionPercentage
  } else {
    Emit 'G9_STATUS' 'Unavailable'
  }
} catch { Emit 'G9_ERROR' $_.Exception.Message }
"""#

    /// What Windows can say about the shared folder. Needs `$userSid` from `userSection` and
    /// `$wbFallbackUNC`.
    ///
    /// A mapped drive belongs to a logon session, and this script runs as SYSTEM in session 0: the
    /// Guest Tools' Z: showed up there on a working VM, with nothing in the signed-in user's hive at
    /// all. So it asks this session first and falls back to a persistent per-user mapping. Either way
    /// the port comes from the mapping itself, not from a hardcoded 9843.
    ///
    /// The share is only listed when both services are running: reading a WebDAV path whose server
    /// isn't there costs the redirector's full timeout, and the services already say why it's down.
    static let sharedFolderSection = #"""
try {
  $svc = Get-Service -Name 'spice-webdavd' -ErrorAction SilentlyContinue
  Emit 'SF_WEBDAVD' $(if ($svc) { '{0}:{1}' -f $svc.Status, $svc.StartType } else { 'Missing:Missing' })
  $wc = Get-Service -Name 'WebClient' -ErrorAction SilentlyContinue
  Emit 'SF_WEBCLIENT' $(if ($wc) { '{0}:{1}' -f $wc.Status, $wc.StartType } else { 'Missing:Missing' })
  $remote = ''
  $drive = ''
  # A mapped drive belongs to the logon session that made it. The Guest Tools' one turned up in the
  # agent's own session (SYSTEM, session 0) on a working VM, so ask about this session first:
  # Win32_NetworkConnection, then Get-PSDrive's DisplayRoot. `net use` would mean parsing a localised
  # table. A persistent per-user mapping under HKEY_USERS is the last resort, and is what a drive
  # Winbar mapped for the signed-in user looks like.
  try {
    foreach ($c in @(Get-CimInstance Win32_NetworkConnection -ErrorAction Stop)) {
      if ([string]$c.RemoteName -like '\\localhost@*') { $drive = [string]$c.LocalName; $remote = [string]$c.RemoteName }
    }
  } catch { }
  if (-not $remote) {
    foreach ($d in @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
      if ([string]$d.DisplayRoot -like '\\localhost@*') { $drive = $d.Name + ':'; $remote = [string]$d.DisplayRoot }
    }
  }
  if ((-not $remote) -and $userSid) {
    $net = 'Registry::HKEY_USERS\' + $userSid + '\Network'
    if (Test-Path -LiteralPath $net) {
      foreach ($k in @(Get-ChildItem -LiteralPath $net -ErrorAction SilentlyContinue)) {
        $path = [string](RegValue ($net + '\' + $k.PSChildName) 'RemotePath')
        if ($path -like '\\localhost@*') { $drive = $k.PSChildName + ':'; $remote = $path }
      }
    }
  }
  Emit 'SF_DRIVE' $drive
  Emit 'SF_REMOTE' $remote
  if (-not $remote) { $remote = $wbFallbackUNC }
  if (("$($svc.Status)" -eq 'Running') -and ("$($wc.Status)" -eq 'Running')) {
    try {
      $items = @(Get-ChildItem -LiteralPath $remote -Force -ErrorAction Stop)
      Emit 'SF_REACHABLE' 'True'
      Emit 'SF_COUNT' $items.Count
      $readme = $items | Where-Object { $_.Name -eq 'README.txt' } | Select-Object -First 1
      # UTM's stand-in folder announces itself in this file's first line; a real folder's README
      # says something else.
      if ($readme) { Emit 'SF_README' ((@(Get-Content -LiteralPath $readme.FullName -TotalCount 1 -ErrorAction SilentlyContinue)) -join ' ') }
      # The host writes this file into the folder it just shared and asks us to read it back: the
      # only way to tell which Mac folder is at the other end. Tried a few times, because the WebDAV
      # redirector can still be holding a listing from a moment ago.
      if ($wbMarker) {
        $found = ''
        for ($i = 0; ($i -lt 3) -and (-not $found); $i++) {
          if ($i -gt 0) { Start-Sleep -Seconds 2 }
          try {
            # Enumerate again each time rather than opening the path: it is the listing the WebDAV
            # redirector holds on to, so a file written a moment ago can be missed once.
            $hit = @(Get-ChildItem -LiteralPath $remote -Force -ErrorAction Stop | Where-Object { $_.Name -eq $wbMarker })[0]
            if ($hit) { $found = ((@(Get-Content -LiteralPath $hit.FullName -TotalCount 1 -ErrorAction Stop)) -join '').Trim() }
          } catch { }
        }
        Emit 'SF_MARKER' $found
      }
    } catch {
      Emit 'SF_REACHABLE' 'False'
      Emit 'SF_UNREACHABLE' $_.Exception.Message
    }
  }
} catch { Emit 'SF_ERROR' $_.Exception.Message }
"""#

    /// The shared folder on its own, for `winbar share` when there is no survey to read. `marker` is
    /// the file `SharedFolder.verify` just wrote into the folder; empty means "don't look for one".
    static func sharedFolder(user: String?, marker: String = "") -> GuestScript {
        GuestScript(body: userSection + "\n" + sharedFolderSection,
                    params: userParams(user) + [("wbFallbackUNC", SharedFolder.defaultRemotePath),
                                                ("wbMarker", marker)])
    }

    private static let guidPattern = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"

    private static func userParams(_ user: String?) -> [(String, String)] { [("wbUser", user ?? "")] }

    // MARK: Survey (everything doctor needs, in one round trip)

    /// One script for all guest checks: each guest round trip costs several seconds, so doctor asks
    /// once and the checks read from the result.
    /// `passwordChecked`: `COMPUTER\user` keys already known to have a password (not probed again).
    /// `marker`: the file `SharedFolder` has just written into the shared folder, so the survey can
    /// say whether Windows is serving *that* folder; empty when there is none to look for.
    static func survey(user: String?, passwordChecked: [String], marker: String = "") -> GuestScript {
        let processor = Tuning.processor.map { setting, _ in
            "  Emit 'G1_\(setting)' (AcValue $BAL 'SUB_PROCESSOR' '\(setting)')"
        }.joined(separator: "\n")
        let visual = Tuning.visualEffects.map { s in
            "    Emit 'G4_\(s.name)' (HexBytes (RegValue ($root + '\\' + \(GuestAgent.psQuote(s.key))) '\(s.name)'))"
        }.joined(separator: "\n")
        let services = Tuning.disabledServices.map { GuestAgent.psQuote($0) }.joined(separator: ",")

        let body = userSection + "\n" + #"""
$BAL = $wbBalanced

try {
  $os = Get-CimInstance Win32_OperatingSystem
  $cv = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
  Emit 'WINDOWS' ('{0} {1} (build {2}.{3})' -f $os.Caption, $cv.DisplayVersion, $cv.CurrentBuild, $cv.UBR)
  Emit 'EDITION' $cv.EditionID
} catch { Emit 'WINDOWS_ERROR' $_.Exception.Message }

# G1 power plan
try {
  Emit 'G1_ACTIVE' ([regex]::Match(((powercfg /getactivescheme) -join ' '), $wbGuidPattern).Value.ToLower())
"""# + "\n" + processor + "\n" + #"""
  Emit 'G1_VIDEOIDLE' (AcValue $BAL 'SUB_VIDEO' 'VIDEOIDLE')
  Emit 'G1_STANDBYIDLE' (AcValue $BAL 'SUB_SLEEP' 'STANDBYIDLE')
  Emit 'G1_DISKIDLE' (AcValue $BAL 'SUB_DISK' 'DISKIDLE')
  $pw = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Power'
  Emit 'G1_HIBERNATE' $(if ($null -ne $pw.HibernateEnabled) { $pw.HibernateEnabled } else { $pw.HibernateEnabledDefault })
} catch { Emit 'G1_ERROR' $_.Exception.Message }

# G2 power button, on every scheme
try {
  foreach ($s in (Guids (powercfg /list))) {
    $v = PowerIndex $s 'SUB_BUTTONS' 'PBUTTONACTION'
    if ($v) { Emit 'G2_SCHEME' ('{0}:{1}:{2}' -f $s, $v[0], $v[1]) } else { Emit 'G2_SCHEME' ('{0}:?:?' -f $s) }
  }
} catch { Emit 'G2_ERROR' $_.Exception.Message }

# G3 services
try {
"""# + "\n  foreach ($name in @(\(services))) {\n" + #"""
    $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
    if ($svc) { Emit 'G3_SERVICE' ('{0}:{1}:{2}' -f $name, $svc.Status, $svc.StartType) } else { Emit 'G3_SERVICE' ('{0}:Missing:Missing' -f $name) }
  }
} catch { Emit 'G3_ERROR' $_.Exception.Message }

# G4 visual effects, in the user's own hive (only loaded while they're signed in)
try {
  if ($userSid) {
    $root = 'Registry::HKEY_USERS\' + $userSid
    Emit 'G4_HIVE' (Test-Path -LiteralPath $root)
"""# + "\n" + visual + "\n" + #"""
  }
} catch { Emit 'G4_ERROR' $_.Exception.Message }

# G5 account type and blank password
try {
  if ($localName) {
    $lu = Get-LocalUser -Name $localName -ErrorAction SilentlyContinue
    if ($lu) {
      Emit 'G5_SOURCE' $lu.PrincipalSource
      $checkedKey = $env:COMPUTERNAME + '\' + $localName
      if (@($wbPasswordChecked.Split('|')) -contains $checkedKey) {
        Emit 'G5_LOGON' 'skipped'
      } elseif ("$($lu.PrincipalSource)" -eq 'Local') {
        # Every probe against an account with a password is a failed logon, and Windows locks the
        # account after ten, so never add to a count that typos or an earlier probe already started.
        # The WinNT provider reads it without depending on the display language.
        $bad = 0
        try { $bad = [int](([ADSI]('WinNT://' + $env:COMPUTERNAME + '/' + $localName + ',user')).BadPasswordAttempts.Value) } catch { }
        if ($bad -gt 0) {
          Emit 'G5_LOGON' 'deferred'
        } else {
          # LogonUser is authoritative. PrincipalContext.ValidateCredentials returns true for '' even on
          # accounts that have a password, so it can't be used to detect a blank one. The error is read
          # in the same C# frame as the call, where nothing else can overwrite it.
          Add-Type -Namespace Winbar -Name Logon -MemberDefinition @'
[DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
static extern bool LogonUser(string user, string domain, string password, int logonType, int provider, out IntPtr token);
[DllImport("kernel32.dll")]
static extern bool CloseHandle(IntPtr handle);
public static int Probe(string user) {
  IntPtr token;
  if (LogonUser(user, ".", "", 2, 0, out token)) { CloseHandle(token); return 0; }
  return Marshal.GetLastWin32Error();
}
'@
          $rc = [Winbar.Logon]::Probe($localName)
          if ($rc -eq 0) { Emit 'G5_LOGON' 'ok' } else { Emit 'G5_LOGON' $rc }
        }
      }
    } else {
      Emit 'G5_SOURCE' 'NotLocal'
    }
  }
} catch { Emit 'G5_ERROR' $_.Exception.Message }

# G6 Remote Desktop
try {
  $ts = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
  $tcp = $ts + '\WinStations\RDP-Tcp'
  Emit 'G6_DENY' (RegValue $ts 'fDenyTSConnections')
  Emit 'G6_NLA' (RegValue $tcp 'UserAuthentication')
  Emit 'G6_SECURITY_LAYER' (RegValue $tcp 'SecurityLayer')
  Emit 'G6_LIMIT_BLANK' (RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' 'LimitBlankPasswordUse')
  $rules = @(Get-NetFirewallRule -Group $wbFirewallGroup -ErrorAction SilentlyContinue)
  Emit 'G6_RULES' ($rules.Count)
  Emit 'G6_RULES_OFF' (@($rules | Where-Object { "$($_.Enabled)" -ne 'True' }).Count)
  Emit 'G6_LISTENING' (@(Get-NetTCPConnection -LocalPort 3389 -State Listen -ErrorAction SilentlyContinue).Count -gt 0)
} catch { Emit 'G6_ERROR' $_.Exception.Message }

# G7 listener certificate
try {
  $tsg = Get-CimInstance -Namespace 'root\cimv2\TerminalServices' -ClassName Win32_TSGeneralSetting -Filter "TerminalName='RDP-Tcp'"
  $thumb = [string]$tsg.SSLCertificateSHA1Hash
  Emit 'G7_THUMB' $thumb
  $store = 'My'
  $cert = $null
  if ($thumb) {
    $cert = Get-Item -LiteralPath ('Cert:\LocalMachine\My\' + $thumb) -ErrorAction SilentlyContinue
    if (-not $cert) {
      $store = 'Remote Desktop'
      $cert = Get-Item -LiteralPath ('Cert:\LocalMachine\Remote Desktop\' + $thumb) -ErrorAction SilentlyContinue
    }
  }
  if ($cert) {
    Emit 'G7_STORE' $store
    Emit 'G7_NAMES' (@($cert.DnsNameList | ForEach-Object { $_.Unicode }) -join ',')
    Emit 'G7_DAYS_LEFT' ([int][Math]::Floor(($cert.NotAfter - (Get-Date)).TotalDays))
    Emit 'G7_HAS_KEY' $cert.HasPrivateKey
    Emit 'G7_CERT' ([Convert]::ToBase64String($cert.RawData))
  }
} catch { Emit 'G7_ERROR' $_.Exception.Message }

# G8 autologon. The password itself is never read: only whether a plaintext one exists.
try {
  $wl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
  Emit 'G8_AUTO' (RegValue $wl 'AutoAdminLogon')
  Emit 'G8_AUTO_KIND' (RegKind $wl 'AutoAdminLogon')
  Emit 'G8_USER' (RegValue $wl 'DefaultUserName')
  Emit 'G8_PLAINTEXT' ((Get-Item -LiteralPath $wl).GetValueNames() -contains 'DefaultPassword')
  Emit 'G8_PASSWORDLESS' (RegValue 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\PasswordLess\Device' 'DevicePasswordLessBuildVersion')
} catch { Emit 'G8_ERROR' $_.Exception.Message }

# G9 BitLocker
"""# + "\n" + bitLockerSection + "\n" + #"""

# G11 shared folder
"""# + "\n" + sharedFolderSection + "\n" + #"""

# G10 information
try {
  $nic = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceDescription -match 'VirtIO' }) | Select-Object -First 1
  if ($nic) { Emit 'G10_NET' $nic.InterfaceDescription }
  $apps = @(Get-ItemProperty -Path @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*') -ErrorAction SilentlyContinue)
  $tools = $apps | Where-Object { $_.DisplayName -like 'UTM Guest Tools*' } | Select-Object -First 1
  if ($tools) { Emit 'G10_TOOLS' $tools.DisplayVersion }
  $agent = $apps | Where-Object { $_.DisplayName -like 'QEMU guest agent*' } | Select-Object -First 1
  if ($agent) { Emit 'G10_AGENT' $agent.DisplayVersion }
} catch { Emit 'G10_ERROR' $_.Exception.Message }
"""#
        return GuestScript(body: body, params: userParams(user) + [
            ("wbPasswordChecked", passwordChecked.joined(separator: "|")),
            ("wbBalanced", Tuning.balancedScheme),
            ("wbGuidPattern", guidPattern),
            ("wbFirewallGroup", Tuning.rdpFirewallGroup),
            ("wbFallbackUNC", SharedFolder.defaultRemotePath),
            ("wbMarker", marker),
        ])
    }

    /// Just the computer and user names, for filling in defaults.
    static func identity(user: String?) -> GuestScript {
        GuestScript(body: userSection, params: userParams(user))
    }

    // MARK: Fixes

    /// G1. Balanced, with the processor values from `Tuning`, and hibernation off.
    static func applyPower() -> GuestScript {
        let processor = Tuning.processor.map { setting, value in
            "powercfg /setacvalueindex $BAL SUB_PROCESSOR \(setting) \(value)"
        }.joined(separator: "\n")
        let body = #"""
$BAL = $wbBalanced
# Balanced can be missing on a trimmed image; duplicating its well-known GUID restores it.
if (-not ((Guids (powercfg /list)) -contains $BAL)) { powercfg /duplicatescheme $BAL $BAL | Out-Null }
powercfg /setactive $BAL
"""# + "\n" + processor + "\n" + """
            powercfg /change monitor-timeout-ac \(Tuning.monitorTimeoutMinutes)
            powercfg /change standby-timeout-ac \(Tuning.standbyTimeoutMinutes)
            powercfg /change disk-timeout-ac \(Tuning.diskTimeoutMinutes)
            powercfg /setactive $BAL
            powercfg /hibernate off
            Emit 'APPLIED' '1'
            """
        return GuestScript(body: body, params: [("wbBalanced", Tuning.balancedScheme)])
    }

    /// G2. The setting is hidden by default; unhide it so it shows in Control Panel too.
    static func applyPowerButton() -> GuestScript {
        GuestScript(body: #"""
powercfg -attributes SUB_BUTTONS PBUTTONACTION -ATTRIB_HIDE
$active = [regex]::Match(((powercfg /getactivescheme) -join ' '), $wbGuidPattern).Value
foreach ($s in (Guids (powercfg /list))) {
  powercfg /setacvalueindex $s SUB_BUTTONS PBUTTONACTION $wbValue
  powercfg /setdcvalueindex $s SUB_BUTTONS PBUTTONACTION $wbValue
}
if ($active) { powercfg /setactive $active }
Emit 'APPLIED' '1'
"""#, params: [("wbGuidPattern", guidPattern), ("wbValue", String(Tuning.powerButtonShutDown))])
    }

    /// G3. Disabled first so a trigger-started service can't come straight back.
    static func applyServices() -> GuestScript {
        let services = Tuning.disabledServices.map { GuestAgent.psQuote($0) }.joined(separator: ",")
        return GuestScript(body: "foreach ($name in @(\(services))) {\n" + #"""
  $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
  if ($svc) {
    Set-Service -Name $name -StartupType Disabled -ErrorAction Stop
    if ("$($svc.Status)" -ne 'Stopped') { Stop-Service -Name $name -Force -ErrorAction SilentlyContinue }
  }
}
Emit 'APPLIED' '1'
"""#)
    }

    /// G4. Written straight into the user's loaded hive; they take full effect at the next sign-in.
    static func applyVisualEffects(user: String?) -> GuestScript {
        let sets = Tuning.visualEffects.map { s in
            "SetUserValue \(GuestAgent.psQuote(s.key)) '\(s.name)' '\(s.kind.rawValue)' \(s.powerShellValue)"
        }.joined(separator: "\n")
        let body = userSection + "\n" + #"""
if (-not $userSid) { throw 'No Windows user found. Sign in to Windows and try again.' }
$root = 'Registry::HKEY_USERS\' + $userSid
if (-not (Test-Path -LiteralPath $root)) { throw ($localName + ' is not signed in, so their settings are not loaded. Sign in to Windows and try again.') }
function SetUserValue([string]$Key, [string]$Name, [string]$Kind, $Value) {
  $path = $root + '\' + $Key
  if (-not (Test-Path -LiteralPath $path)) { New-Item -Path $path -Force | Out-Null }
  New-ItemProperty -Path $path -Name $Name -PropertyType $Kind -Value $Value -Force | Out-Null
}
"""# + "\n" + sets + "\nEmit 'APPLIED' '1'"
        return GuestScript(body: body, params: userParams(user))
    }

    /// G6. NLA on and blank-password network logons refused: the secure defaults, which a real
    /// password makes painless.
    static func applyRemoteDesktop() -> GuestScript {
        GuestScript(body: #"""
$ts = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
$tcp = $ts + '\WinStations\RDP-Tcp'
Set-ItemProperty -Path $ts -Name 'fDenyTSConnections' -Value 0 -Type DWord
Set-ItemProperty -Path $tcp -Name 'UserAuthentication' -Value 1 -Type DWord
Set-ItemProperty -Path $tcp -Name 'SecurityLayer' -Value 2 -Type DWord
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name 'LimitBlankPasswordUse' -Value 1 -Type DWord
Enable-NetFirewallRule -Group $wbFirewallGroup
$svc = Get-Service -Name TermService
if ("$($svc.Status)" -ne 'Running') { Start-Service -Name TermService }
Emit 'APPLIED' '1'
"""#, params: [("wbFirewallGroup", Tuning.rdpFirewallGroup)])
    }

    /// G7. A listener certificate named for how the Mac connects, so it can be trusted once and
    /// never warned about again.
    ///
    /// The SChannel provider keeps the key in MachineKeys, where the RDP service (NETWORK SERVICE)
    /// needs read access. The grant uses the SID, S-1-5-20, because the account name is localised.
    static func applyCertificate(host: String, ip: String?) -> GuestScript {
        GuestScript(body: #"""
# The DNS host name, not COMPUTERNAME: that's the NetBIOS name, cut to 15 characters.
$san = '2.5.29.17={text}DNS=' + $wbHost + '&DNS=' + [System.Net.Dns]::GetHostName()
if ($wbIP) { $san += '&IPAddress=' + $wbIP }
# Ten years, deliberately, though macOS calls that "not standards compliant": Apple caps TLS server
# certificates at 398 days, and nothing else about this certificate breaks its rules (SAN, serverAuth,
# RSA 2048, SHA-256 — checked against a 397-day control, which evaluates as the ordinary "not trusted").
# The trust setting Winbar adds is scoped to this one host name, so the override covers exactly one
# name on one Mac. The alternative is a short-lived certificate, which needs re-trusting (and a Touch ID
# prompt) every year, or a local CA that signs short-lived ones.
$cert = New-SelfSignedCertificate -Type SSLServerAuthentication -Subject ('CN=' + $wbHost) -TextExtension @($san) -CertStoreLocation 'Cert:\LocalMachine\My' -KeyAlgorithm RSA -KeyLength 2048 -HashAlgorithm SHA256 -Provider 'Microsoft RSA SChannel Cryptographic Provider' -KeyExportPolicy NonExportable -NotAfter (Get-Date).AddYears(10)
$keyPath = $null
try {
  $container = $cert.PrivateKey.CspKeyContainerInfo.UniqueKeyContainerName
  if ($container) { $keyPath = Join-Path $env:ProgramData ('Microsoft\Crypto\RSA\MachineKeys\' + $container) }
} catch { }
if (-not $keyPath) {
  # Only if Windows handed back a CNG key despite the CSP provider.
  $rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($cert)
  $keyPath = Join-Path $env:ProgramData ('Microsoft\Crypto\Keys\' + $rsa.Key.UniqueName)
}
if (-not (Test-Path -LiteralPath $keyPath)) { throw ('The new certificate''s private key is not where expected: ' + $keyPath) }
& icacls.exe $keyPath /grant '*S-1-5-20:R' | Out-Null
if ($LASTEXITCODE -ne 0) { throw ('icacls failed with exit code ' + $LASTEXITCODE) }
$tsg = Get-CimInstance -Namespace 'root\cimv2\TerminalServices' -ClassName Win32_TSGeneralSetting -Filter "TerminalName='RDP-Tcp'"
Set-CimInstance -InputObject $tsg -Property @{ SSLCertificateSHA1Hash = $cert.Thumbprint } | Out-Null
Emit 'G7_THUMB' $cert.Thumbprint
Emit 'G7_CERT' ([Convert]::ToBase64String($cert.RawData))
Emit 'APPLIED' '1'
"""#, params: [("wbHost", host), ("wbIP", ip ?? "")])
    }

    /// G8's prerequisite. "Only allow Windows Hello sign-in" (DevicePasswordLessBuildVersion 2) hides
    /// netplwiz's "Users must enter a user name and password" checkbox, which autologon needs. This is
    /// the same switch as Settings → Accounts → Sign-in options.
    static func allowPasswordSignIn() -> GuestScript {
        GuestScript(body: #"""
$key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\PasswordLess\Device'
if (-not (Test-Path -LiteralPath $key)) { New-Item -Path $key -Force | Out-Null }
Set-ItemProperty -Path $key -Name 'DevicePasswordLessBuildVersion' -Value 0 -Type DWord
Emit 'APPLIED' '1'
"""#)
    }

    /// Opens a program on the signed-in user's desktop. The agent's own processes live in session 0
    /// where nobody can see them; a scheduled task with an Interactive principal runs in the user's
    /// session instead, and RunLevel Highest elevates without a UAC prompt (netplwiz needs that).
    ///
    /// OPENED only once Task Scheduler says the program started. The ScheduledTasks cmdlets report
    /// failures as non-terminating errors, so they need -ErrorAction Stop to reach the wrapper, and a
    /// launch that fails (a standard user and an elevated tool: 0x800702E4) shows up only in
    /// LastTaskResult. A plain exit code there is fine: explorer.exe hands an ms-settings: page to the
    /// running shell and exits with 1.
    static func openOnDesktop(user: String?, executable: String, arguments: String, elevated: Bool) -> GuestScript {
        let body = userSection + "\n" + #"""
if (-not $explorerUser) { throw 'Nobody is signed in to Windows, so there is no desktop to open it on. Sign in (console window or Remote Desktop) and try again.' }
$taskUser = $explorerDomain + '\' + $explorerUser
$name = 'Winbar-' + [guid]::NewGuid().ToString('N')
$action = if ($wbArgs) { New-ScheduledTaskAction -Execute $wbExe -Argument $wbArgs } else { New-ScheduledTaskAction -Execute $wbExe }
$principal = if ($wbElevated -eq '1') { New-ScheduledTaskPrincipal -UserId $taskUser -LogonType Interactive -RunLevel Highest } else { New-ScheduledTaskPrincipal -UserId $taskUser -LogonType Interactive }
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName $name -Action $action -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
# LastTaskResult, as unsigned. Decimal on purpose: PowerShell 5.1 reads 0x80000000 and up as negative.
$notYet = @(267011, 267045)   # SCHED_S_TASK_HAS_NOT_RUN, SCHED_S_TASK_QUEUED
$r = 267011
try {
  Start-ScheduledTask -TaskName $name -ErrorAction Stop
  $deadline = (Get-Date).AddSeconds(15)
  do {
    Start-Sleep -Milliseconds 500
    $info = Get-ScheduledTaskInfo -TaskName $name -ErrorAction SilentlyContinue
    if ($info) { $r = [int64]$info.LastTaskResult; if ($r -lt 0) { $r += 4294967296 } }
  } while ((Get-Date) -lt $deadline -and ($notYet -contains $r))
} finally {
  # The task only exists to cross into the user's session; the program it started keeps running.
  Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
}
Emit 'LAUNCH_RESULT' ('0x{0:X8}' -f $r)
if ($notYet -contains $r) { throw 'Windows accepted the request but did not start the program within 15 seconds.' }
if ($r -eq 2147943140) { throw ('Opening it needs an administrator, and ' + $taskUser + ' is a standard account. Sign in to Windows as an administrator, or run ' + $wbExe + ' yourself.') }
if ($r -ge 2147483648) { throw ('Windows could not start it (task result 0x{0:X8}).' -f $r) }
Emit 'OPENED' $taskUser
"""#
        return GuestScript(body: body, params: userParams(user) + [
            ("wbExe", executable), ("wbArgs", arguments), ("wbElevated", elevated ? "1" : "0"),
        ])
    }

    /// Autologon runs alongside service start-up, so the guest agent can answer before the user's
    /// profile and explorer.exe exist, and a survey then finds nobody signed in. Waits for explorer
    /// (up to `seconds`), but only when autologon is on: otherwise nobody is coming. As SYSTEM,
    /// Get-Process sees every session's processes.
    static func waitForAutologon(seconds: Int) -> GuestScript {
        GuestScript(body: #"""
$auto = RegValue 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' 'AutoAdminLogon'
if ("$auto" -eq '1') {
  $deadline = (Get-Date).AddSeconds([int]$wbSeconds)
  while (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 2 }
}
Emit 'SESSION' ([bool](Get-Process -Name explorer -ErrorAction SilentlyContinue))
"""#, params: [("wbSeconds", String(seconds))])
    }

    // MARK: BitLocker

    static func bitLockerStatus() -> GuestScript { GuestScript(body: bitLockerSection) }

    /// Suspends protection for exactly one boot, so a device-topology change (display on/off, vCPUs,
    /// RAM) is re-sealed instead of sending Windows to the recovery-key screen. That happened in testing.
    static func bitLockerGuard() -> GuestScript {
        GuestScript(body: bitLockerSection + "\n" + #"""
if ("$($bv.ProtectionStatus)" -eq 'On') {
  Suspend-BitLocker -MountPoint 'C:' -RebootCount 1 -ErrorAction Stop | Out-Null
  Emit 'SUSPENDED' '1'
}
"""#)
    }

    /// Starts decrypting C:. Windows carries on in the background, across restarts.
    static func bitLockerDecrypt() -> GuestScript {
        GuestScript(body: "Disable-BitLocker -MountPoint 'C:' -ErrorAction Stop | Out-Null\n" + bitLockerSection)
    }
}
