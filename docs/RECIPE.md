# The recipe, by hand

Everything `winbar setup` does, as steps you can follow yourself without Winbar, in the order
that works: Windows first (Remote Desktop has to work before the VM can lose its screen), then
the Mac. Each step gives the exact setting, why it's there, and what was measured.

The measurements come from one Mac: an M5 Max (6 "Super" + 12 "Performance" cores) running
Windows 11 Pro ARM64 (build 26200) in UTM 4.7, on battery. Absolute numbers will differ on your
Mac; the comparisons were made like-for-like.

**Placeholders used below**

| Placeholder | Meaning | Example |
|---|---|---|
| `<VM>` | The VM's name in UTM | `Windows` |
| `<host>` | The name the Mac connects to: Windows' computer name, lowercased, plus `.local` | `mypc.local` |
| `<user>` | Your Windows user name | `alex` |

**Where to run things**

- **Mac:** Terminal. `utmctl` is UTM's command-line tool; the `utm` Homebrew cask puts it on your
  PATH, otherwise use `/Applications/UTM.app/Contents/MacOS/utmctl`.
- **Windows (admin):** inside the VM, *Terminal (Admin)* or *PowerShell* run as administrator.
- **Windows (you):** a normal, non-admin PowerShell, signed in as `<user>`.

---

## 0. Before you start

**Requirements.** Apple silicon, macOS 14 or later, UTM, a Windows 11 ARM64 VM on UTM's default
**Shared Network**, and Windows 11 **Pro**, Enterprise or Education (Home can't host Remote
Desktop). Windows App on the Mac.

**Install the UTM Guest Tools** in Windows if you haven't (in the VM's UTM window: the CD/DVD
toolbar button > install the Windows Guest Tools, then run the installer from the mounted disc).
They include the QEMU guest agent, which is what lets the Mac run commands in Windows. Check from
the Mac:

```sh
utmctl ip-address "<VM>"      # prints the VM's addresses once the agent is running
```

**Save your BitLocker recovery key**, whatever you plan to do about BitLocker. Windows (admin):

```powershell
manage-bde -protectors -get C:     # the 48-digit "Numerical Password"
```

**Learn the clean way to stop the VM.** You'll restart it a few times.

```sh
# Mac: ask Windows itself to shut down
utmctl exec "<VM>" --cmd cmd.exe /c "shutdown /s /t 0"
```

- *Why not UTM's Stop button, or `utmctl stop --request`:* both press a virtual ACPI power
  button. Once Windows has blanked its display, it treats that press as *wake* (event log:
  Kernel-Power 566, power state "0 to 1" and then "1 to 3") and never shuts down.
- *Why never plain `utmctl stop`:* it defaults to `--force`, a hard power-off. It caused four
  "unexpected shutdown" events during testing (no damage, but no reason to risk it).

**Running PowerShell from the Mac (optional).** If you'd rather not type into the VM, push a
script and run it through the guest agent. `powershell -Command` via `utmctl exec` fails (OSStatus
-2700), so start it through `cmd.exe` and collect the output from a file:

```sh
utmctl file push "<VM>" 'C:\Windows\Temp\step.ps1' < step.ps1
utmctl exec "<VM>" --cmd cmd.exe /c "start /b powershell -NoProfile -ExecutionPolicy Bypass -File C:\Windows\Temp\step.ps1"
utmctl file pull "<VM>" 'C:\Windows\Temp\step.out'     # once the script has written it
```

The agent runs as SYSTEM, in a session nobody can see, under x64 emulation. So per-user settings
(step 6) written that way land in SYSTEM's registry unless you address the user's hive under
`HKEY_USERS\<SID>`, and anything with a window won't appear on the desktop. Winbar works around
both; by hand, it's simpler to run those two steps inside Windows.

---

## Part 1: Windows

### 1. A local account with a real password

Check what you have. Windows (admin):

```powershell
Get-LocalUser | Select-Object Name, PrincipalSource, Enabled
```

If yours says `MicrosoftAccount`: *Settings > Accounts > Your info > Sign in with a local account
instead*. Confirm with your PIN, then choose a user name and a password. Your profile folder,
files and apps are unchanged.

- *Why:* a Windows Hello PIN never works over Remote Desktop. Automatic sign-in (step 8) with a
  Microsoft account needs that account's password in plain text in the registry, and breaks
  whenever the Microsoft password changes.
- *Trap:* `Set-LocalUser -Password` reports success on a Microsoft-linked account but doesn't
  change the password Windows actually signs in with.

If the account has **no password**, set one (*Settings > Accounts > Sign-in options > Password*).
Remote Desktop with a blank password would need both Network Level Authentication and Windows'
blank-password protection turned off; don't.

- *Checking for a blank password correctly:* `PrincipalContext.ValidateCredentials(user, '')`
  returned **true** for an account that did have a password, so it can't be trusted. Calling
  `LogonUser` with an empty password is authoritative (error 1326 = wrong password, 1327 = blank
  password blocked by policy).

### 2. Power plan: Balanced, fast ramp-up, parking allowed

Windows (admin):

```powershell
$BAL = '381b4222-f694-41f0-9685-ff5bb260df2e'                     # Balanced
powercfg /setactive $BAL
powercfg /setacvalueindex $BAL SUB_PROCESSOR PERFINCPOL 2         # "rocket": ramp up at once...
powercfg /setacvalueindex $BAL SUB_PROCESSOR PERFINCTHRESHOLD 30  # ...and early
powercfg /setacvalueindex $BAL SUB_PROCESSOR PERFDECTHRESHOLD 20
powercfg /setacvalueindex $BAL SUB_PROCESSOR CPMINCORES 10        # idle vCPUs may park
powercfg /setacvalueindex $BAL SUB_PROCESSOR CPMAXCORES 100
powercfg /setacvalueindex $BAL SUB_PROCESSOR PROCTHROTTLEMIN 5
powercfg /setacvalueindex $BAL SUB_PROCESSOR PROCTHROTTLEMAX 100
powercfg /change monitor-timeout-ac 5     # blank the (virtual) display after 5 min
powercfg /change standby-timeout-ac 0     # never sleep
powercfg /change disk-timeout-ac 20
powercfg /hibernate off
powercfg /setactive $BAL                  # re-apply so the new values take effect
```

- *AC values only:* the VM has no virtual battery, so Windows always believes it's plugged in.
- *Why Balanced and not Ultimate Performance:* Ultimate Performance was tried and reverted. It
  disables core parking, and a parked vCPU is what lets its thread sleep on the Mac, so the
  Mac's cores sleep too. Balanced with a fast ramp is just as responsive.
- *Display timeout:* until the VM is headless (step 14), a blanked Windows display stops the
  desktop compositor and the framebuffer copies entirely.
- *Never sleep, no hibernation:* a sleeping VM just looks hung, and a hibernation file is pointless
  for a machine whose disk is already a file.

### 3. Power button = Shut down

Windows (admin):

```powershell
powercfg -attributes SUB_BUTTONS PBUTTONACTION -ATTRIB_HIDE
$guid = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
foreach ($g in (powercfg /list | Select-String -Pattern $guid -AllMatches).Matches.Value) {
  powercfg /setacvalueindex $g SUB_BUTTONS PBUTTONACTION 3   # 3 = Shut down
  powercfg /setdcvalueindex $g SUB_BUTTONS PBUTTONACTION 3
}
powercfg /setactive SCHEME_CURRENT
```

- *Why:* the setting is hidden by default, and resolves to a sleep state that doesn't exist in
  this VM. Every scheme, AC and DC, so switching plans later can't undo it.
- *Not enough on its own:* even set to Shut down, the button is ignored once the display has
  blanked (see [step 0](#0-before-you-start)). It's the fallback; shutting down through the guest
  agent is the real fix.

### 4. Turn off background services that don't pay in a VM

Windows (admin):

```powershell
foreach ($s in 'SysMain', 'WSearch', 'DiagTrack') {
  Stop-Service -Name $s -Force -ErrorAction SilentlyContinue
  Set-Service -Name $s -StartupType Disabled
}
```

- *Why:* SysMain (prefetching into memory), Windows Search indexing and DiagTrack (telemetry)
  generated constant background CPU and disk activity, which on a VM is the Mac's CPU and the
  Mac's disk, for no benefit.
- *Trade-off:* Start menu and Explorer search still work without the indexer, just more slowly.

### 5. Remote Desktop, with Network Level Authentication

Windows (admin):

```powershell
$ts = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
Set-ItemProperty $ts fDenyTSConnections 0                         # allow connections
Set-ItemProperty "$ts\WinStations\RDP-Tcp" UserAuthentication 1   # NLA on
Set-ItemProperty "$ts\WinStations\RDP-Tcp" SecurityLayer 2        # TLS
Enable-NetFirewallRule -Group '@FirewallAPI.dll,-28752'           # "Remote Desktop" rules
Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' LimitBlankPasswordUse 1
```

(*Settings > System > Remote Desktop > On* does the same, apart from the last line.)

- *Firewall group by resource name:* `@FirewallAPI.dll,-28752` is the "Remote Desktop" group in
  every Windows language; the display name isn't.
- *NLA and `LimitBlankPasswordUse`:* both are Windows' defaults. Blank-password Remote Desktop
  needs both turned off (NLA's pre-authentication refuses a blank password whatever the other
  setting says), and a real password makes that unnecessary.
- *Why Remote Desktop at all:* it bypasses UTM's display path completely (see step 14).
- *Who can reach it:* on Shared Network, only your Mac (and other VMs on it using Shared
  Network). A **Bridged** VM is reachable from your whole network on port 3389; if you bridge,
  consider restricting these firewall rules to your Mac's address.

### 6. Visual effects off

As **you** (not admin), then sign out and back in:

```powershell
function Set-Reg($path, $name, $value, $type) {
  if (-not (Test-Path $path)) { New-Item -Path $path | Out-Null }
  Set-ItemProperty -Path $path -Name $name -Value $value -Type $type
}
$desk = 'HKCU:\Control Panel\Desktop'
$adv  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' VisualFXSetting 3 DWord  # "Custom"
Set-Reg "$desk\WindowMetrics" MinAnimate '0' String
Set-Reg $desk DragFullWindows '0' String
Set-Reg $desk FontSmoothing '2' String            # keep ClearType
Set-Reg $desk MenuShowDelay '0' String
Set-Reg $desk UserPreferencesMask ([byte[]](0x90,0x12,0x03,0x80,0x10,0x00,0x00,0x00)) Binary
Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' EnableTransparency 0 DWord
Set-Reg $adv TaskbarAnimations 0 DWord
Set-Reg $adv ListviewShadow 0 DWord
```

(Or by hand: *Settings > Personalization > Colors > Transparency effects* off, *Settings >
Accessibility > Visual effects > Animation effects* off, and *System > About > Advanced system
settings > Performance > Settings > Custom*.)

- *Why:* transparency (Acrylic/Mica) and animations are expensive on an unaccelerated
  framebuffer, and over Remote Desktop they're more pixels to send for no benefit.
- *Why `Test-Path` before `New-Item`:* `New-Item -Force` on an existing registry key **replaces**
  it, deleting every value in it.

### 7. A Remote Desktop certificate named for your Mac's address

Windows generates its own Remote Desktop certificate named after the bare computer name, so even
a trusted copy fails the name check against `<host>`, and it expires within a year. Replace it.
Windows (admin):

```powershell
$name = "$($env:COMPUTERNAME.ToLower()).local"              # this is <host>
$ip   = (Get-NetIPConfiguration | Where-Object IPv4DefaultGateway).IPv4Address.IPAddress
$cert = New-SelfSignedCertificate -Type SSLServerAuthentication -Subject "CN=$name" `
  -TextExtension @("2.5.29.17={text}DNS=$name&DNS=$env:COMPUTERNAME&IPAddress=$ip") `
  -CertStoreLocation Cert:\LocalMachine\My -KeyAlgorithm RSA -KeyLength 2048 -HashAlgorithm SHA256 `
  -Provider 'Microsoft RSA SChannel Cryptographic Provider' -KeyExportPolicy NonExportable `
  -NotAfter (Get-Date).AddYears(10)

# Remote Desktop runs as NETWORK SERVICE, which must be able to read the private key.
# Granted by SID (S-1-5-20) so it works on non-English Windows too.
$key = $cert.PrivateKey.CspKeyContainerInfo.UniqueKeyContainerName
icacls "$env:ProgramData\Microsoft\Crypto\RSA\MachineKeys\$key" /grant '*S-1-5-20:R'

# Point the listener at the new certificate.
$tsg = Get-CimInstance -Namespace root\cimv2\TerminalServices -ClassName Win32_TSGeneralSetting -Filter "TerminalName='RDP-Tcp'"
Set-CimInstance -InputObject $tsg -Property @{ SSLCertificateSHA1Hash = $cert.Thumbprint }

# Save the public half for the Mac (step 11).
Export-Certificate -Cert $cert -FilePath C:\Users\Public\rdp.cer | Out-Null
certutil -f -encode C:\Users\Public\rdp.cer C:\Users\Public\rdp.pem | Out-Null
```

- *Names in the certificate:* `<host>` is what Windows App connects to; the bare computer name and
  the VM's address are there so other ways of connecting also match.
- *Why `<host>` (`.local`) rather than the IP address:* the address is a lease from the Mac's
  private VM network and could change; the `.local` name follows the VM wherever it is.
- *The key* can't be exported and never leaves the VM.

### 8. Automatic sign-in

Windows (as you): run `netplwiz`, untick **Users must enter a user name and password to use this
computer**, click OK, and enter your password twice.

Check (Windows, admin):

```powershell
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' |
  Select-Object AutoAdminLogon, DefaultUserName, DefaultPassword
# expect AutoAdminLogon 1, DefaultUserName <user>, and NO DefaultPassword
```

- *Why:* the VM boots straight to your desktop, and Remote Desktop then takes over that same
  session (it logs as a reconnection, logon type 7), so apps started at boot keep running. In
  testing, sign-in happened 10 s after boot with no input.
- *Why netplwiz rather than the registry:* netplwiz stores the password as an encrypted LSA
  secret. The registry-only method needs it in plain text in `DefaultPassword`.
- *No checkbox?* Windows hides it while *Settings > Accounts > Sign-in options > For improved
  security, only allow Windows Hello sign-in for Microsoft accounts on this device* is on. Turn
  that off first.
- *What it means:* anyone who can open the VM's window on your Mac lands on your desktop. The VM
  is as private as your Mac account.

### 9. BitLocker

Check (Windows, admin):

```powershell
Get-BitLockerVolume -MountPoint C: | Select-Object VolumeStatus, ProtectionStatus, EncryptionPercentage
```

Check the Mac:

```sh
fdesetup status        # "FileVault is On." or "FileVault is Off."
```

**If FileVault is on, turn BitLocker off** (Winbar's default). You saved the recovery key in
step 0. Windows (admin):

```powershell
Disable-BitLocker -MountPoint C:
manage-bde -status C:       # re-run to watch "Percentage Encrypted" fall to 0
```

- *Redundant:* the VM's disk is a file on your Mac, and FileVault already encrypts it at rest,
  as long as it's on the startup disk. A VM kept on an external drive is only as encrypted as
  that drive (`diskutil info /Volumes/<drive>` shows "FileVault: Yes" for an encrypted one).
- *It costs performance:* every disk read and write is encrypted twice.
- *It fights VM changes:* the key is sealed to UTM's software TPM, and any change to the VM's
  virtual hardware (adding a disk, adding or removing its display) changes what the TPM measures,
  so Windows demands the recovery key at the next boot. This happened in testing.

**If FileVault is off,** or the VM lives on an unencrypted drive, keeping BitLocker is the only
thing encrypting the VM's disk. Better: encrypt that volume, then decide.

**If you keep BitLocker,** suspend it for one reboot before every change to the VM's hardware
(steps 10 and 14):

```powershell
Suspend-BitLocker -MountPoint C: -RebootCount 1
```

---

## Part 2: The Mac

### 10. vCPUs and memory

Work out the numbers. Mac:

```sh
sysctl -n hw.perflevel0.physicalcpu            # top-tier cores: use this, kept between 4 and 8
echo $(( $(sysctl -n hw.memsize) / 1073741824 ))  # GiB: 64+ -> 16384 MB, 32+ -> 12288 MB, else 8192 MB,
                                                  # never more than half the Mac's RAM; keep a larger value you chose
```

Shut the VM down cleanly (step 0), then set them in UTM (select the VM > **Edit** > *System*), or
with AppleScript, which UTM applies itself:

```sh
osascript <<'EOF'
tell application "UTM"
  set vm to virtual machine named "Windows"   -- your <VM>
  set c to configuration of vm
  set cpu cores of c to 6
  set memory of c to 16384
  update configuration of vm with c
end tell
EOF
```

The first time, macOS asks whether Terminal may control UTM. Allow it.

- *vCPUs, measured* with a fixed workload (always 6 parallel jobs, whatever the vCPU count),
  counting the host CPU time QEMU used as the energy cost:

  | vCPUs | Host CPU-seconds for the work | Wall-clock seconds | 6-thread SHA-256 |
  |---|---|---|---|
  | 4 | 31.94 | 13.30 | 1.40 s |
  | **6** | **29.63 / 33.36** | **12.45 / 12.81** | **1.18 / 1.14 s** |
  | 8 | 37.82 | 13.39 | 1.12 s |

  (Two runs at 6.) **8 vCPUs cost ~28% more host CPU for the same work with no wall-clock gain;**
  4 was slower and no cheaper. The M5 Max has 6 top-tier cores, so the rule generalises as
  "vCPUs = top-tier cores". That's a heuristic from one machine, clamped to 4…8 to stay sane on
  others.
- *Memory:* 8 GB left about 4 GB free at idle on Windows 11; 16 GB is comfortable when the Mac has
  plenty.
- *Never change the VM's drives* while you're in there. Any device-topology change can trip
  BitLocker recovery and can invalidate Windows' UEFI boot entry.
- *AppleScript gotcha:* `displays of (configuration of vm)` fails with error -1728. Always copy
  the configuration into a variable first (`set c to configuration of vm`), then work on `c`.

### 11. Trust the VM's certificate

Copy the certificate from step 7 to the Mac, then trust it for SSL only. Mac:

```sh
utmctl file pull "<VM>" 'C:\Users\Public\rdp.pem' > rdp.pem
security add-trusted-cert -r trustRoot -p ssl -s <host> -k ~/Library/Keychains/login.keychain-db rdp.pem
```

macOS asks for your password (or Touch ID) to change certificate trust settings.

- *What this trusts:* that one self-signed certificate, for SSL/TLS, for the one host name
  `<host>`, in your login keychain only. No certificate authority is installed.
- *Why `-s <host>` matters:* without it the trust setting has no host name attached, and that
  certificate becomes a trusted SSL root for *every* host — so anyone who can read the VM's disk
  (it isn't encrypted, and the account's password is recoverable from it) could use its key to
  impersonate any site to your Mac. With `-s`, it vouches for `<host>` and nothing else. Winbar
  does the same thing.
- *Checking it:* connect with Windows App (next step); there should be no certificate prompt.
  Don't use `security verify-cert`: it reports a Certificate Transparency failure for this
  certificate regardless, which isn't what apps check.

### 12. Save the PC in Windows App

Windows App > **Devices** > **+** > **Add PC**:

- **PC name:** `<host>`
- **Credentials:** *Add credentials*, with `<user>` and your password
- **Friendly name:** anything, or nothing. A tile's accessibility description is its friendly name
  when it has one and its PC name when it hasn't, and Winbar's Connect matches either.

Double-click the tile to connect. In testing it went from click to signed-in in about 5 seconds.

- *From the command line instead:* Windows App has an undocumented scripting command line, which is
  what `winbar create` and `winbar setup` use so you don't do this step at all:

  ```sh
  "/Applications/Windows App.app/Contents/MacOS/Windows App" --script bookmark write <a fresh UUID> \
      --hostname <host> --username <user> --password '<password>' --friendlyname '<name>' \
      --dynamicdisplay true
  ```

  It runs without opening a window and exits. `--script bookmark list` prints what it has and
  `--script bookmark delete <id>` removes one. Two things to know: the password is on the argv, so
  any program running as you can see it for the length of the call; and `write` on an id that
  already exists replaces that PC, so mint the id against `list` rather than picking one. **Quit
  Windows App first** — this writes the same database a running copy has open, and Core Data
  doesn't support two writers.
- *Why a saved PC:* it's the only kind of connection that uses a stored password. A one-off `.rdp`
  file never does, `rdp://` links carry settings but never a password, and `ms-rd:` links only
  address cloud workspaces. The command line above can save a PC but can't open one; there is no
  connect verb, which is why Winbar presses the tile through the Accessibility API.
- *Why `<host>` and not the IP address:* the `.local` name resolves over the Mac's private VM
  network (mDNS) and survives address changes.

### 13. Keep the VM out of Time Machine and Spotlight

*System Settings > General > Time Machine > Options*, click **+**, press ⌘⇧G and paste
`~/Library/Containers/com.utmapp.UTM/Data/Documents` (all your UTM VMs live there, unless you
store one elsewhere). Optionally add the same folder under *System Settings > Spotlight > Search
Privacy*.

- *Why:* the VM's disk image (tens of GB) changes constantly, so every backup copies it again.
- *From Terminal instead:* `tmutil addexclusion <path>` works without `sudo`, but on newer macOS
  it needs your terminal app to have Full Disk Access, and UTM's container is off-limits to other
  apps. The Settings route is simpler.

### 14. Go headless

Only once step 12 works, because afterwards Remote Desktop is the only way in.

If you kept BitLocker, suspend it first (step 9). Shut the VM down cleanly, then remove its
display, in UTM's VM settings (select the Display device and remove it) or with AppleScript:

```sh
osascript <<'EOF'
tell application "UTM"
  set vm to virtual machine named "Windows"
  set c to configuration of vm
  set displays of c to {}
  update configuration of vm with c
end tell
EOF
```

**Quit UTM before starting the VM again** (UTM ▸ Quit UTM, or `osascript -e 'quit app "UTM"'`), then
start it (`utmctl start "<VM>"`) and connect with Windows App. QEMU now runs with
`-vga none -nographic`: no virtual GPU at all.

Why quit first: UTM keeps a stopped VM's display window open and reuses it on the next start. After
the display has been removed, that stale window looks up display #0 in an empty list and UTM crashes
(a Swift bounds check, `EXC_BREAKPOINT`) about two seconds after the VM starts, taking the VM with
it. This affects UTM 4.7.5 and the 5.0 pre-releases. A freshly launched UTM builds the right kind of
window, so quitting sidesteps it. Quitting UTM stops any *other* running VMs, so shut those down
first. Winbar does all of this for you, and checks afterwards that UTM is still running.

To get the window back (to see a boot menu or a recovery screen, or to fix a VM that won't come up
on the network), shut down, run the same script with this line in place of
`set displays of c to {}`, then quit UTM before starting again:

```applescript
set displays of c to {{hardware:"virtio-ramfb-gl", dynamic resolution:true, native resolution:false, upscaling filter:nearest, downscaling filter:linear}}
```

- *Measured,* guest idle in both cases, CPU-seconds per 60 s:

  | | QEMU | UTM app |
  |---|---|---|
  | VM window open, Windows desktop drawing | 59.83 (about one full core) | 2.84 |
  | **Headless** | **6.26** | **0.00** |

  **About 90% less host CPU.** The VirtIO GPU is display-only: nothing is accelerated, so every
  frame Windows draws is copied by the Mac's CPU. Remote Desktop doesn't use that path at all.
- *Starting the VM:* `utmctl start --hide` prints `OSStatus -10004` twice while succeeding, and
  only hides UTM's library window anyway. Judge a start by the VM appearing (for example,
  `utmctl ip-address "<VM>"` answering), not by `utmctl`'s output.
- *Hand-editing `config.plist`:* don't. UTM keeps the configuration in memory and overwrites the
  file, so edits made while UTM runs silently vanish, and on newer macOS the file is off-limits to
  other apps anyway. Use UTM's settings or AppleScript.

### 15. Optional: UTM out of the way

In UTM's Settings you can show a menu bar icon, hide the Dock icon, keep UTM running after its
last window closes, and skip the quit confirmation. Note that closing a VM's own window still
stops that VM (and not cleanly), which is another reason to stay headless.

---

## Measuring it yourself

**Host CPU used by the VM** is the number that matters for battery life. Mac:

```sh
qemu=$(pgrep -f qemu-aarch64-softmmu | head -1)
cpu() { ps -o time= -p "$qemu" | awk -F: '{ if (NF==3) print $1*3600+$2*60+$3; else print $1*60+$2 }'; }
a=$(cpu); sleep 60; b=$(cpu); echo "$b - $a" | bc      # CPU-seconds per minute
```

**A fixed workload** makes configurations comparable: the same work regardless of vCPU count,
while measuring host CPU as above. The one used here, inside Windows: a 2 GiB write-through
sequential write, 4,000 random 4 KiB writes, SHA-256 of a 1 GiB file (once, then 6 copies in
parallel with `certutil -hashfile`), and 2,000 small files.

Before and after the whole recipe, same Mac and power state, 6 vCPUs (this "after" includes
BitLocker off, which Winbar does only when FileVault is on):

| | Before | After |
|---|---|---|
| Sequential write | 926 MB/s | ~1,220–1,350 MB/s |
| 4 KiB random write | 3,876 IOPS | ~4,800–5,100 IOPS |
| SHA-256, 1 thread | 0.87 s | 0.67 s |
| SHA-256, 6 threads | 1.94 s | 1.14–1.18 s |

## Deliberately not done

- **Converting the disk from qcow2 to raw.** The Mac writes 2 GiB to the image file in 0.165 s;
  Windows takes 2.2 s for the same write. About 93% of the cost is the virtual disk device path,
  not the image format. Not worth 30 GB of disk and the risk.
- **Switching the disk from NVMe to VirtIO.** Unproven, and every device-topology change is a
  boot risk (and a BitLocker recovery prompt if BitLocker is on). If you try it, back up the VM
  first.
- **macOS High Power Mode.** Works against the whole point, which is efficiency.
- **Ultimate Performance power plan.** See step 2.

## Reading Windows' evidence

Useful when something doesn't connect:

- Event 1149 in *TerminalServices-RemoteConnectionManager/Operational* means the Remote Desktop
  connection authenticated. A 4625 right after it means the Windows sign-in still failed; they're
  separate stages.
- Reconnecting to an existing session logs 4624 **type 7**, not type 10.
- While a Remote Desktop client holds the session, `Win32_ComputerSystem.UserName` is empty and the
  only display adapter is "Microsoft Remote Display Adapter". Neither is a problem.
- `PasswordRequired = False` on an account means a blank password is *permitted*, not that the
  password *is* blank.
- A few dozen `ACPI\LNRO0005` devices with code 28 in Device Manager are QEMU's unused
  virtio-mmio slots; Windows uses virtio-pci. Harmless.
- After the Mac sleeps, Windows' uptime looks short because its clock ticks pause while the VM is
  suspended. It didn't reboot, and the clock resyncs.
