# Winbar "winbar create" first-logon script. Lives at \FirstLogon.ps1 on the answer CD (volume label WINBAR_SETUP).
#
# Started once by the answer file's FirstLogonCommands, as the new local administrator, elevated, in the first
# automatic sign-in. The file is STATIC (identical for every VM, ASCII only, so Windows PowerShell 5.1 reads it the
# same with or without a BOM): the ticked options arrive as switches written by the answer-file renderer.
#   -GuestTools     install UTM Guest Tools silently: utm-guest-tools*.exe next to this script (guest_tools, locked on)
#   -Autologon      keep signing in automatically (autologon); without it, only the setup sign-in happens
#   -RemoteDesktop  Remote Desktop with NLA, same values as winbar doctor G6 (remote_desktop)
#   -NoBitLocker    make sure C: is not encrypted (no_bitlocker)
#   -Tuning         Winbar's performance tuning, winbar doctor G1-G4 (winbar_tuning)
#   -NoVisualTweaks with -Tuning: skip G4 visual effects (the --no-visual-tweaks modifier, as in winbar setup)
#
# It never receives the account password and never reads it into output. Autologon uses the copy Windows Setup
# already stored as the LSA secret DefaultPassword; this script only reads Winlogon's non-secret values. Without
# -Autologon it deletes that secret through LsaStorePrivateData(NULL), which writes and never reads.
#
# CONTRACT: the LAST thing it does is write C:\Windows\Temp\winbar-install\status.txt (ASCII, CRLF, key=value, written
# to status.tmp first and renamed). The first three lines are always, in this order:
#   result=ok|failed      ok only if every requested step succeeded
#   guest_tools=<n>       installer exit code; -1 installer not found, -2 still running after the timeout (a
#                         warning when the guest agent runs anyway), -3 not requested
#   rdp=on|off            the actual state (fDenyTSConnections = 0), whatever was requested
# Extra keys follow (readers must ignore keys they do not know). Winbar polls for the file through the QEMU guest agent
# that step "guest_tools" installs; nothing here restarts Windows. Log: C:\Windows\Temp\winbar-install\firstlogon.log.
# If this script can't run at all, the answer file's launcher writes the same file itself (result=failed).
# Nothing here writes a password or any other secret value to the log, progress.txt or status.txt: only counts,
# booleans and states.
# progress.txt in the same folder holds the name of the step in progress (for the host's progress view).

[CmdletBinding()]
param(
  [switch]$GuestTools,
  [switch]$Autologon,
  [switch]$RemoteDesktop,
  [switch]$NoBitLocker,
  [switch]$Tuning,
  [switch]$NoVisualTweaks,
  [int]$GuestToolsTimeoutMinutes = 20
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$ScriptVersion = '2'

# ---- Constants shared with Winbar (Tuning.swift / GuestScripts.swift; a unit test keeps them equal) --------------
$BalancedScheme   = '381b4222-f694-41f0-9685-ff5bb260df2e'
$GuidPattern      = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
$RdpFirewallGroup = '@FirewallAPI.dll,-28752'
$HomeEditions     = @('Core', 'CoreN', 'CoreSingleLanguage', 'CoreCountrySpecific')
$GuestAgentName   = 'QEMU-GA'
$Winlogon         = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
$TermServer       = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'

# ---- Plumbing ------------------------------------------------------------------------------------------------------
$OutDir = Join-Path $env:SystemRoot 'Temp\winbar-install'
$StatusFile = Join-Path $OutDir 'status.txt'
$StatusTmp = Join-Path $OutDir 'status.tmp'
$LogFile = Join-Path $OutDir 'firstlogon.log'
$ProgressFile = Join-Path $OutDir 'progress.txt'
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
Remove-Item -LiteralPath $StatusFile, $StatusTmp -Force -ErrorAction SilentlyContinue

$Failed = New-Object System.Collections.Generic.List[string]
$Info = [ordered]@{}
$GuestToolsExit = -3

function Log([string]$Message) {
  try { Add-Content -LiteralPath $LogFile -Encoding Ascii -Value ((Get-Date).ToString('s') + ' ' + $Message) } catch { }
}
function Step([string]$Name, [scriptblock]$Body) {
  Log ('begin ' + $Name)
  try { [System.IO.File]::WriteAllText($ProgressFile, $Name, [System.Text.Encoding]::ASCII) } catch { }
  try { & $Body; Log ('ok ' + $Name) }
  catch {
    $Failed.Add($Name)
    if (-not $Info.Contains('error')) { $Info['error'] = $Name + ': ' + $_.Exception.Message }
    Log ('FAILED ' + $Name + ': ' + $_.Exception.Message)
  }
}
function RegValue([string]$Path, [string]$Name) {
  try { (Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop).$Name } catch { $null }
}
function HasValue([string]$Path, [string]$Name) {
  try { @((Get-Item -LiteralPath $Path -ErrorAction Stop).GetValueNames()) -contains $Name } catch { $false }
}
function Guids($Lines) {
  @([regex]::Matches((@($Lines) -join ' '), $GuidPattern) | ForEach-Object { $_.Value.ToLower() } | Select-Object -Unique)
}
function SetUserValue([string]$Key, [string]$Name, [string]$Kind, $Value) {
  # This script runs as the new user, so HKCU is that user's hive (winbar setup writes HKEY_USERS\<SID> instead).
  $path = 'HKCU:\' + $Key
  if (-not (Test-Path -LiteralPath $path)) { New-Item -Path $path -Force | Out-Null }
  New-ItemProperty -Path $path -Name $Name -PropertyType $Kind -Value $Value -Force | Out-Null
}
function ClearLsaSecret([string]$Name) {
  # Deletes an LSA private secret: LsaStorePrivateData with PrivateData = NULL. Write-only on purpose: nothing here
  # can read a secret (no LsaRetrievePrivateData). Returns a Win32 error code, 0 = deleted.
  if (-not ('WinbarLsa' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class WinbarLsa {
  [StructLayout(LayoutKind.Sequential)]
  struct LsaUnicodeString { public ushort Length; public ushort MaximumLength; public IntPtr Buffer; }
  [StructLayout(LayoutKind.Sequential)]
  struct LsaObjectAttributes { public int Length; public IntPtr RootDirectory; public IntPtr ObjectName; public uint Attributes; public IntPtr SecurityDescriptor; public IntPtr SecurityQualityOfService; }
  [DllImport("advapi32.dll")] static extern uint LsaOpenPolicy(IntPtr systemName, ref LsaObjectAttributes attributes, uint access, out IntPtr policy);
  [DllImport("advapi32.dll")] static extern uint LsaStorePrivateData(IntPtr policy, ref LsaUnicodeString keyName, IntPtr privateData);
  [DllImport("advapi32.dll")] static extern uint LsaClose(IntPtr handle);
  [DllImport("advapi32.dll")] static extern int LsaNtStatusToWinError(uint status);
  public static int Delete(string name) {
    LsaObjectAttributes attributes = new LsaObjectAttributes();
    attributes.Length = Marshal.SizeOf(typeof(LsaObjectAttributes));
    IntPtr policy;
    uint status = LsaOpenPolicy(IntPtr.Zero, ref attributes, 0x20, out policy);   // POLICY_CREATE_SECRET
    if (status != 0) { return LsaNtStatusToWinError(status); }
    IntPtr buffer = Marshal.StringToHGlobalUni(name);
    try {
      LsaUnicodeString key = new LsaUnicodeString();
      key.Buffer = buffer;
      key.Length = (ushort)(name.Length * 2);
      key.MaximumLength = (ushort)((name.Length + 1) * 2);
      status = LsaStorePrivateData(policy, ref key, IntPtr.Zero);
      return status == 0 ? 0 : LsaNtStatusToWinError(status);
    } finally {
      Marshal.FreeHGlobal(buffer);
      LsaClose(policy);
    }
  }
}
'@
  }
  [WinbarLsa]::Delete($Name)
}
function WriteStatus {
  $rdp = 'off'
  if ((RegValue $TermServer 'fDenyTSConnections') -eq 0) { $rdp = 'on' }
  $result = 'failed'
  if ($Failed.Count -eq 0) { $result = 'ok' }
  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add('result=' + $result)
  $lines.Add('guest_tools=' + $GuestToolsExit)
  $lines.Add('rdp=' + $rdp)
  $Info['failed_steps'] = ($Failed -join ',')
  $Info['log'] = $LogFile
  $Info['winbar_firstlogon'] = $ScriptVersion
  foreach ($k in $Info.Keys) {
    $lines.Add($k + '=' + (([string]$Info[$k]) -replace '[\r\n]+', ' '))
  }
  [System.IO.File]::WriteAllText($StatusTmp, (($lines -join "`r`n") + "`r`n"), [System.Text.Encoding]::ASCII)
  Move-Item -LiteralPath $StatusTmp -Destination $StatusFile -Force
  Log ('status written: ' + $lines[0])
}

Log ('Winbar FirstLogon.ps1 v' + $ScriptVersion + ' from ' + $PSScriptRoot + ' switches:' +
     $(if ($GuestTools) { ' GuestTools' }) + $(if ($Autologon) { ' Autologon' }) + $(if ($RemoteDesktop) { ' RemoteDesktop' }) +
     $(if ($NoBitLocker) { ' NoBitLocker' }) + $(if ($Tuning) { ' Tuning' }) + $(if ($NoVisualTweaks) { ' NoVisualTweaks' }))

try {
  $cv = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
  $Edition = [string]$cv.EditionID

  # ---- 1. Setup's leftovers that could hold the password ---------------------------------------------------------
  # Setup scrubs passwords from its cached answer file at the end of each pass; check, and delete any cached file that
  # still holds a password value. Both Setup engines' folders, recursively: %WINDIR%\Panther (with Unattend and
  # UnattendGC) and the ConX engine's C:\$WINDOWS.~BT (25H2 ships both). Values are only compared with Setup's
  # marker, never logged or reported: the status carries counts only.
  Step 'panther' {
    $marker = '*SENSITIVE*DATA*DELETED*'
    $deleted = 0; $checked = 0
    $files = @()
    foreach ($dir in @((Join-Path $env:SystemRoot 'Panther'), (Join-Path $env:SystemDrive '$WINDOWS.~BT'))) {
      if (Test-Path -LiteralPath $dir) {
        $files += @(Get-ChildItem -LiteralPath $dir -Filter '*.xml' -File -Recurse -Force -ErrorAction SilentlyContinue)
      }
    }
    foreach ($f in $files) {
      $doc = New-Object System.Xml.XmlDocument
      try { $doc.Load($f.FullName) } catch { continue }
      $checked++
      $values = @($doc.SelectNodes("//*[local-name()='Password' or local-name()='AdministratorPassword']/*[local-name()='Value']"))
      $open = @($values | Where-Object { $_.InnerText -ne '' -and $_.InnerText -ne $marker }).Count
      $doc = $null
      if ($open -gt 0) { Remove-Item -LiteralPath $f.FullName -Force; $deleted++; Log ('deleted unscrubbed ' + $f.FullName) }
    }
    $Info['panther_scrub'] = $(if ($deleted) { 'deleted:' + $deleted } else { 'clean:' + $checked })

    # Shell-Setup stages its answers under UnattendSettings (shsetup.dll strings) and deletes them after use.
    $root = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\UnattendSettings\Microsoft-Windows-Shell-Setup'
    $residue = 'none'
    if (Test-Path -LiteralPath $root) {
      $keys = @(Get-ChildItem -LiteralPath $root -Recurse -ErrorAction SilentlyContinue |
                Where-Object { $_.PSChildName -eq 'Password' -or $_.PSChildName -eq 'AdministratorPassword' })
      foreach ($k in $keys) {
        try { Remove-Item -LiteralPath $k.PSPath -Recurse -Force -ErrorAction Stop; $residue = 'removed' }
        catch { $residue = 'present'; Log ('cannot remove ' + $k.Name) }
      }
    }
    $Info['password_residue'] = $residue
  }

  # ---- 2. Automatic sign-in --------------------------------------------------------------------------------------------
  Step 'autologon' {
    $plain = HasValue $Winlogon 'DefaultPassword'
    # shsetup.dll logs "[Shell Unattend] AutoLogon Password saved" after LsaStorePrivateData succeeds.
    $saved = $false
    foreach ($gcLog in @((Join-Path $env:SystemRoot 'Panther\UnattendGC\setupact.log'), (Join-Path $env:SystemRoot 'Panther\setupact.log'))) {
      if (-not $saved -and (Test-Path -LiteralPath $gcLog)) {
        $saved = [bool](Select-String -LiteralPath $gcLog -SimpleMatch -Quiet -Pattern '[Shell Unattend] AutoLogon Password saved')
      }
    }
    if ($Autologon) {
      # No AutoLogonCount = Winlogon never counts down to "off". The password stays where Setup put it.
      Remove-ItemProperty -LiteralPath $Winlogon -Name 'AutoLogonCount' -ErrorAction SilentlyContinue
      Set-ItemProperty -LiteralPath $Winlogon -Name 'AutoAdminLogon' -Value '1' -Type String
      Set-ItemProperty -LiteralPath $Winlogon -Name 'DefaultUserName' -Value $env:USERNAME -Type String
      Set-ItemProperty -LiteralPath $Winlogon -Name 'DefaultDomainName' -Value $env:COMPUTERNAME -Type String
      if ($plain -and $saved) {
        # A plaintext copy next to the LSA secret is redundant: drop it.
        Remove-ItemProperty -LiteralPath $Winlogon -Name 'DefaultPassword' -Force
        $Info['autologon_secret'] = 'lsa'
      } elseif ($plain) {
        # Not expected (shsetup.dll stores the LSA secret). Leave it so autologon keeps working; winbar setup G8
        # (netplwiz) converts it to the LSA secret. Reported, not failed.
        $Info['autologon_secret'] = 'plaintext'
      } else {
        # This very sign-in was automatic, and with no plaintext value Winlogon can only have used the LSA secret.
        $Info['autologon_secret'] = $(if ($saved) { 'lsa' } else { 'lsa-inferred' })
      }
      # "Only allow Windows Hello sign-in" would hide netplwiz's checkbox, should anyone need it later (G8).
      $pl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\PasswordLess\Device'
      if (-not (Test-Path -LiteralPath $pl)) { New-Item -Path $pl -Force | Out-Null }
      Set-ItemProperty -LiteralPath $pl -Name 'DevicePasswordLessBuildVersion' -Value 0 -Type DWord
      $Info['autologon'] = 'on'
    } else {
      # Microsoft's documented LogonCount fix: exactly this one automatic sign-in. At the next start Winlogon turns
      # autologon off, and it would delete the stored password itself; delete it now instead of relying on that.
      Set-ItemProperty -LiteralPath $Winlogon -Name 'AutoLogonCount' -Value 0 -Type DWord
      Remove-ItemProperty -LiteralPath $Winlogon -Name 'DefaultPassword' -Force -ErrorAction SilentlyContinue
      $Info['autologon'] = 'off'
      $Info['autologon_secret'] = 'cleared-at-next-start'
      try {
        $code = ClearLsaSecret 'DefaultPassword'
        # 2 = ERROR_FILE_NOT_FOUND: there was no secret to delete.
        if ($code -eq 0 -or $code -eq 2) { $Info['autologon_secret'] = 'cleared' }
        else { Log ('LsaStorePrivateData: error ' + $code + '; Winlogon clears the secret at the next start') }
      } catch { Log ('LsaStorePrivateData: ' + $_.Exception.Message + '; Winlogon clears the secret at the next start') }
    }
  }

  # ---- 3. Remote Desktop with NLA (GuestScripts.applyRemoteDesktop) ---------------------------------------------------
  if ($RemoteDesktop) {
    Step 'rdp' {
      if ($HomeEditions -contains $Edition) { throw ('Windows ' + $Edition + ' cannot host Remote Desktop sessions') }
      $tcp = $TermServer + '\WinStations\RDP-Tcp'
      Set-ItemProperty -Path $TermServer -Name 'fDenyTSConnections' -Value 0 -Type DWord
      Set-ItemProperty -Path $tcp -Name 'UserAuthentication' -Value 1 -Type DWord
      Set-ItemProperty -Path $tcp -Name 'SecurityLayer' -Value 2 -Type DWord
      Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name 'LimitBlankPasswordUse' -Value 1 -Type DWord
      Enable-NetFirewallRule -Group $RdpFirewallGroup
      $svc = Get-Service -Name 'TermService'
      if ("$($svc.Status)" -ne 'Running') { Start-Service -Name 'TermService' }
    }
  }

  # ---- 4. BitLocker off ---------------------------------------------------------------------------------------------------
  if ($NoBitLocker) {
    Step 'bitlocker' {
      $bl = 'HKLM:\SYSTEM\CurrentControlSet\Control\BitLocker'
      if (-not (Test-Path -LiteralPath $bl)) { New-Item -Path $bl -Force | Out-Null }
      Set-ItemProperty -LiteralPath $bl -Name 'PreventDeviceEncryption' -Value 1 -Type DWord
      $vol = $null
      try { $vol = Get-BitLockerVolume -MountPoint 'C:' -ErrorAction Stop } catch { Log ('Get-BitLockerVolume: ' + $_.Exception.Message) }
      if ($vol -and "$($vol.VolumeStatus)" -ne 'FullyDecrypted') {
        Disable-BitLocker -MountPoint 'C:' | Out-Null
        Log ('BitLocker was ' + $vol.VolumeStatus + '; decryption started')
      }
    }
  }

  # ---- 5. UTM Guest Tools (drivers incl. NetKVM, SPICE agent, QEMU guest agent) -------------------------------------
  # Before the tuning steps, so nothing slow or stuck there can keep the guest agent from appearing: once it answers,
  # Winbar starts polling for the status file. The NSIS installer's /S is silent and skips its 3D page (viogpudo, not
  # viogpu3d); it never reboots. Winbar puts the pinned installer at the root of the WINBAR_SETUP CD, next to this
  # script; any other CD's root is only a fallback.
  if ($GuestTools) {
    Step 'guest_tools' {
      $exe = $null
      for ($i = 0; $i -lt 60 -and -not $exe; $i++) {
        $roots = @()
        if ($PSScriptRoot) { $roots += $PSScriptRoot }
        $roots += @([IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'CDRom' -and $_.IsReady } | ForEach-Object { $_.RootDirectory.FullName })
        foreach ($root in $roots) {
          # The pinned file is utm-guest-tools-<version>.exe; the shortest matching name wins.
          $f = Get-ChildItem -LiteralPath $root -Filter 'utm-guest-tools*.exe' -File -ErrorAction SilentlyContinue |
               Sort-Object { $_.Name.Length } | Select-Object -First 1
          if ($f) { $exe = $f.FullName; break }
        }
        if (-not $exe) { Start-Sleep -Seconds 2 }
      }
      if (-not $exe) { $script:GuestToolsExit = -1; throw 'UTM Guest Tools installer not found on any CD' }
      try { $Info['guest_tools_media'] = [string](New-Object System.IO.DriveInfo -ArgumentList $exe).VolumeLabel } catch { }
      Log ('running ' + $exe + ' /S')
      $p = Start-Process -FilePath $exe -ArgumentList '/S' -PassThru
      $null = $p.Handle   # keeps the process handle so ExitCode is available after the wait
      if (-not $p.WaitForExit($GuestToolsTimeoutMinutes * 60000)) {
        # Not a failure by itself: step guest_agent below decides (the host shows a warning for -2).
        $script:GuestToolsExit = -2
        Log ('installer still running after ' + $GuestToolsTimeoutMinutes + ' minutes; carrying on')
      } else {
        $script:GuestToolsExit = $p.ExitCode
        if ($p.ExitCode -ne 0) { throw ('installer exit code ' + $p.ExitCode) }
      }
    }
    Step 'guest_agent' {
      $running = $false
      for ($i = 0; $i -lt 30 -and -not $running; $i++) {
        $svc = Get-Service -Name $GuestAgentName -ErrorAction SilentlyContinue
        if ($svc -and "$($svc.Status)" -eq 'Running') { $running = $true; break }
        if ($svc -and "$($svc.Status)" -eq 'Stopped') { Start-Service -Name $GuestAgentName -ErrorAction SilentlyContinue }
        Start-Sleep -Seconds 2
      }
      if (-not $running) { throw ('service ' + $GuestAgentName + ' is not running') }
    }
  }

  # ---- 6. Winbar tuning (GuestScripts.applyPower / applyPowerButton / applyServices / applyVisualEffects) -------------
  if ($Tuning) {
    Step 'power' {
      if (-not ((Guids (powercfg /list)) -contains $BalancedScheme)) { powercfg /duplicatescheme $BalancedScheme $BalancedScheme | Out-Null }
      powercfg /setactive $BalancedScheme
      powercfg /setacvalueindex $BalancedScheme SUB_PROCESSOR PERFINCPOL 2
      powercfg /setacvalueindex $BalancedScheme SUB_PROCESSOR PERFINCTHRESHOLD 30
      powercfg /setacvalueindex $BalancedScheme SUB_PROCESSOR PERFDECTHRESHOLD 20
      powercfg /setacvalueindex $BalancedScheme SUB_PROCESSOR CPMINCORES 10
      powercfg /setacvalueindex $BalancedScheme SUB_PROCESSOR CPMAXCORES 100
      powercfg /setacvalueindex $BalancedScheme SUB_PROCESSOR PROCTHROTTLEMIN 5
      powercfg /setacvalueindex $BalancedScheme SUB_PROCESSOR PROCTHROTTLEMAX 100
      powercfg /change monitor-timeout-ac 5
      powercfg /change standby-timeout-ac 0
      powercfg /change disk-timeout-ac 20
      powercfg /setactive $BalancedScheme
      powercfg /hibernate off
    }
    Step 'power_button' {
      powercfg -attributes SUB_BUTTONS PBUTTONACTION -ATTRIB_HIDE
      $active = [regex]::Match(((powercfg /getactivescheme) -join ' '), $GuidPattern).Value
      foreach ($s in (Guids (powercfg /list))) {
        powercfg /setacvalueindex $s SUB_BUTTONS PBUTTONACTION 3
        powercfg /setdcvalueindex $s SUB_BUTTONS PBUTTONACTION 3
      }
      if ($active) { powercfg /setactive $active }
    }
    Step 'services' {
      foreach ($name in @('SysMain', 'WSearch', 'DiagTrack')) {
        $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
        if ($svc) {
          Set-Service -Name $name -StartupType Disabled
          if ("$($svc.Status)" -ne 'Stopped') { Stop-Service -Name $name -Force -ErrorAction SilentlyContinue }
        }
      }
    }
    if (-not $NoVisualTweaks) { Step 'visual_effects' {
      SetUserValue 'Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' 'VisualFXSetting' 'DWord' 3
      SetUserValue 'Control Panel\Desktop\WindowMetrics' 'MinAnimate' 'String' '0'
      SetUserValue 'Control Panel\Desktop' 'DragFullWindows' 'String' '0'
      SetUserValue 'Control Panel\Desktop' 'FontSmoothing' 'String' '2'
      SetUserValue 'Control Panel\Desktop' 'MenuShowDelay' 'String' '0'
      SetUserValue 'Control Panel\Desktop' 'UserPreferencesMask' 'Binary' ([byte[]](0x90, 0x12, 0x03, 0x80, 0x10, 0x00, 0x00, 0x00))
      SetUserValue 'Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'EnableTransparency' 'DWord' 0
      SetUserValue 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarAnimations' 'DWord' 0
      SetUserValue 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'ListviewShadow' 'DWord' 0
    } }
  }

} catch {
  $Failed.Add('script')
  Log ('FAILED script: ' + $_.Exception.Message)
} finally {
  # ---- 7. Facts for the host, then the status file: ALWAYS the last write ----------------------------------------------
  try {
    $cv = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $Info['edition'] = $cv.EditionID
    $Info['build'] = ('{0}.{1}' -f $cv.CurrentBuild, $cv.UBR)
    $Info['computer_name'] = $env:COMPUTERNAME
    $Info['dns_host'] = [System.Net.Dns]::GetHostName()
    $Info['user'] = $env:USERNAME
    $nla = RegValue ($TermServer + '\WinStations\RDP-Tcp') 'UserAuthentication'
    $Info['nla'] = $(if ($nla -eq 1) { 'on' } else { 'off' })
    if (-not $Info.Contains('autologon')) { $Info['autologon'] = $(if ((RegValue $Winlogon 'AutoAdminLogon') -eq '1') { 'on' } else { 'off' }) }
    $Info['plaintext_password'] = $(if (HasValue $Winlogon 'DefaultPassword') { 'yes' } else { 'no' })
    $bitlocker = 'unavailable'
    try {
      $vol = Get-BitLockerVolume -MountPoint 'C:' -ErrorAction Stop
      $bitlocker = $(if ("$($vol.VolumeStatus)" -eq 'FullyDecrypted') { 'off' } elseif ("$($vol.VolumeStatus)" -eq 'DecryptionInProgress') { 'decrypting' } else { 'on' })
    } catch { }
    $Info['bitlocker'] = $bitlocker
    $ga = Get-Service -Name $GuestAgentName -ErrorAction SilentlyContinue
    $Info['guest_agent'] = $(if ($ga) { [string]$ga.Status } else { 'missing' })
    foreach ($u in @('HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\SpiceGuestTools',
                     'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\SpiceGuestTools')) {
      $ver = RegValue $u 'DisplayVersion'
      if ($ver) { $Info['guest_tools_version'] = $ver; break }
    }
  } catch { Log ('facts: ' + $_.Exception.Message) }
  try { [System.IO.File]::WriteAllText($ProgressFile, 'done', [System.Text.Encoding]::ASCII) } catch { }
  try { WriteStatus } catch { Log ('FAILED status: ' + $_.Exception.Message) }
}
