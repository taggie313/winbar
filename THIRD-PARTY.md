# Third-party work Winbar builds on

Winbar itself is [MIT](LICENSE). This file records what came from someone else, and from where,
so nobody has to guess. It is a statement of provenance, not a legal opinion.

## Rufus

- **Project:** Rufus, by Pete Batard — <https://github.com/pbatard/rufus>
- **Licence:** GNU General Public License v3.0
- **Version studied:** Rufus 4.15, mainly `src/wue.c` (the "Windows User Experience" dialog and
  the answer file it writes)
- **What Winbar took:** *settings*, not code. Winbar's answer file
  (`Sources/Winbar/AnswerFileTemplate.swift`) is its own document, written from scratch for a UTM
  ARM64 VM and rendered by Winbar's own renderer; no Rufus source is copied, compiled, linked or
  shipped. What it shares with Rufus is the set of Windows settings, the registry value names and
  the answer-file values that apply them, which were established by reading `wue.c` and then
  checked against Microsoft's documentation and against a running VM.

The settings that came from studying Rufus, by name:

| In Winbar's answer file | What came from Rufus |
|---|---|
| Requirement bypass (`windowsPE`) | Setting `BypassTPMCheck`, `BypassSecureBootCheck` and `BypassRAMCheck` under `HKLM\SYSTEM\Setup\LabConfig` during Setup |
| Product key | Leaving `<Key/>` empty and choosing the edition by `/IMAGE/INDEX`, which is what keeps the product-key page away |
| No online account | `BypassNRO` under `…\CurrentVersion\OOBE` |
| Automatic device encryption off | The pair `PreventDeviceEncryption` and `TCGSecurityActivationDisabled` (Winbar applies them in the `specialize` pass rather than `oobeSystem`) |
| Silent OOBE | The four `Hide…` values Rufus's silent mode adds: `HideEULAPage`, `HideOEMRegistrationScreen`, `HideOnlineAccountScreens`, `HideWirelessSetupInOOBE` |
| Local account | Creating the account in the answer file rather than leaving it to OOBE, and `net accounts /maxpwage:unlimited` so its password doesn't expire |
| "Quality of life", machine-wide (`specialize`) | Disabling OneDrive sync by policy, deleting `OneDriveSetup.exe`, and removing the provisioned and installed Outlook and Teams packages |
| "Quality of life", per user and policy (first logon) | `HiberbootEnabled`, `ShowCopilotButton`, `TurnOffWindowsCopilot`, `SearchboxTaskbarMode` and its cache, `DisableWindowsConsumerFeatures`, `SystemPaneSuggestionsEnabled`, `BingSearchEnabled`, `AllowNewsAndInterests`, `EnableFeeds`, `ConfigureChatAutoInstall`, `DisableCloudOptimizedContent`, Edge's `HideFirstRunExperience`, `Start_Layout`, and the Start menu's `VisiblePlaces` value |

Rufus also shaped parts of `winbar create` that are not the answer file: the checklist is Rufus's
"Windows User Experience" option set in Rufus's order (`Sources/Winbar/CreateModel.swift`), with
the four options Winbar leaves out listed under it; the reserved-account-name check uses Rufus's
list (`Sources/Winbar/CreateChoices.swift`); and the test for an answer file already on an ISO is
Rufus's (`Sources/Winbar/WindowsISO.swift`).

Where Winbar differs, it says so in place. It leaves out Rufus's `RUFUS_BOOT` disk tripwire (the
VM has one disk), does not set `/logonpasswordchg:yes` (it would stop the unattended sign-in), and
leaves out four Rufus options entirely: the 'Windows CA 2023' bootloaders, SkuSiPolicy, S Mode and
Windows To Go. Everything else in the answer file — the disk layout, the locale set, automatic
sign-in, Remote Desktop, the Guest Tools, Winbar's tuning and `FirstLogon.ps1` — is Winbar's.

The registry paths, the answer-file element names and the LCID/KLID identifiers are Microsoft's
own, documented by Microsoft.

## UTM Guest Tools

- **Project:** UTM — <https://github.com/utmapp>
- **What Winbar uses:** the installer
  `utm-guest-tools-0.1.273.exe`, from the `utmapp/qemu` release `v10.0.12-utm`, pinned by size
  (80,384,135 bytes) and SHA-256
  (`82de73050d983361e8c9294d384871c0debaaa74a3290d971e0556e230b134ca`), checked before every use.
- **How:** `winbar create` downloads it at run time into
  `~/Library/Caches/net.elusive.winbar` and installs it inside the Windows guest (or uses the copy
  you point at with `--guest-tools PATH`). **It is not redistributed with Winbar** — no part of it
  is in this repository or in any Winbar release, and its own licence terms are the UTM project's,
  not Winbar's.

## Unicode CLDR

`Sources/Winbar/Regional.swift` holds a table mapping IANA time zone names to Windows time zone
ids. It was generated once from Unicode CLDR's `windowsZones.xml` (typeVersion 2021a), plus names
from macOS's own tzdata. CLDR is published by the Unicode Consortium —
<https://cldr.unicode.org>, terms at <https://www.unicode.org/copyright.html>.

## Not bundled

Winbar has no package dependencies: it builds against Apple's own frameworks alone. UTM, Windows
App and Windows are separate products that Winbar drives; it installs none of them and ships no
part of them. Windows and Windows App are trademarks of Microsoft; Winbar isn't affiliated with
Microsoft or with the UTM project.
