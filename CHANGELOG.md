# Changelog

All notable changes to Winbar are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/). `scripts/release.sh` publishes each version's section
as its GitHub release notes.

## [0.1.0] - 2026-09-20

The first public release: the hand-built, hand-measured setup this project started from,
generalised so it works on any Apple silicon Mac and any Windows 11 VM in UTM.

### Added

- `winbar create`: makes a new UTM VM and installs Windows 11 ARM64 into it unattended, from
  Microsoft's ISO, in about 10 minutes on an M5 Max, with no clicking. Rufus's "Windows User Experience" options
  (requirement bypass, no online account, local account, regional settings from the Mac, privacy
  questions skipped, BitLocker's automatic encryption off, no forced Copilot/OneDrive/Outlook/Fast
  Startup) plus automatic sign-in, Remote Desktop with NLA, the UTM Guest Tools and Winbar's
  tuning. Shows the plan as a checklist first; asks for the Windows password twice at a hidden
  prompt and never takes it as a flag or an environment variable. `--dry-run` prints the plan and
  changes nothing; `--resume` picks up an interrupted install; `--cancel` stops one and can delete
  its VM. The install ends headless unless `--console` is given, Remote Desktop can't be reached,
  or another VM is running (taking a VM headless restarts UTM).
- **New Windows VM…** in the menu, and `winbar create --window`: the same plan as a window, with
  the checklist, a progress view you can close, and the result.

- Menu bar app: status icon (running, stopped, working), Connect / Start and Connect, Start, Shut
  Down (hold ⌥ for Force Stop), Restart, Show Console Window / Go Headless, Open Shared Folder /
  Share a Folder…, Open UTM, New Windows VM…, Launch at Login, Quit Winbar.
- One-click Connect: opens the VM's saved PC in Windows App so its stored password is used, with
  no chooser window, and brings an existing full-screen session forward.
- `winbar` command (the same executable as the app): `setup`, `doctor`, `create`, `start`, `stop`,
  `restart`, `connect`, `display on|off`, `share`, `config`, `--self-test`, `--version`, `help`.
- `winbar setup`: checks the Mac, Windows and Windows App, fixes what it can (asking first, one VM
  restart for all changes that need one), and walks through the steps only a person can do.
  Re-running it changes nothing when everything is already right.
- A shared folder between the Mac and Windows: `winbar share [FOLDER | --off]`, **Open Shared
  Folder** / **Share a Folder…** in the menu, an offer of `~/Shared-with-Windows` in `winbar setup`,
  and a row in `winbar doctor` (informational when nothing is shared — nobody needs one). It uses
  the WebDAV share the UTM Guest Tools already install, so nothing new goes into Windows.
  Three things Winbar says out loud instead of letting you discover them: a change needs the VM to
  restart — sometimes twice, because UTM hands Windows the folder it had at the *previous* start, so
  Winbar checks from inside Windows and restarts again only if it has to; the folder's path must
  have no spaces in it, or Windows mounts an empty drive that fails every write; and a folder set
  this way doesn't survive UTM itself restarting, which Winbar has to do for every display change —
  so it writes the folder again on its way through, checks Windows really got it, and says so. It
  never overwrites a folder you picked in UTM yourself; when one of those stops working it says so
  and offers to write it again, explaining that its rewrite is the weaker kind. For a folder that
  simply stays, pick it in UTM's own VM details screen. The drive letter in your own Windows session
  is checked there too, in your session rather than the agent's, because it can be a stale handle
  while the share behind it is healthy — Winbar tells the two apart, says which it found, and maps
  the letter again when that is the only thing wrong.
- The tuning recipe: vCPUs matched to the Mac's top-tier cores (4 to 8), memory by the Mac's RAM,
  headless display, Balanced power plan with fast ramp-up and core parking, power button = Shut
  down, SysMain / Windows Search / DiagTrack off, visual effects off (`--no-visual-tweaks` to
  skip, remembered per VM), Remote Desktop with NLA (once the account has a password), a Remote Desktop certificate named for the Mac's address and
  trusted on the Mac for SSL only, automatic sign-in stored as an LSA secret.
- BitLocker is turned off by default when the VM's disk is on an encrypted volume (FileVault on the
  startup disk, or an encrypted external drive): the disk is already encrypted at rest, BitLocker
  costs disk performance, and any VM hardware change demands the recovery key. `--keep-bitlocker`
  keeps it (remembered per VM); otherwise setup asks instead. When BitLocker is kept, it is
  suspended for one reboot before any VM hardware change.
- Clean shutdown through the guest agent, because UTM's ACPI power button is ignored once Windows
  has blanked its display.
- VM settings changed through UTM's AppleScript interface; Winbar never touches UTM's files.
- **Winbar saves the PC in Windows App itself**, instead of telling you to add it by hand. Windows
  App has an undocumented scripting command line (`--script bookmark …`) that runs without opening
  a window; a bookmark is a saved PC, and it takes the host, user name and password. `winbar
  create` writes it as soon as the answer file is made, while it still has the password you chose;
  `winbar setup` offers to write it, asking for the password at the same hidden prompt `create`
  uses, and never as a flag or an argument. Winbar names it, so you are never asked what to call
  it, and `winbar create --cancel` takes it away again with the VM.
  - It refuses while Windows App is open, and says so: that command line writes the same Core Data
    store the running app has open, and a lost update would take every saved PC you have, which is
    not a file Winbar can read or put back. The manual instructions are still there for that case,
    and for when you'd rather do it yourself.
  - `winbar create`'s closing message lists saving the PC only when Winbar couldn't do it.
  - `winbar doctor`'s Saved PC check (C2) says what Windows App actually has, by asking Windows App.
- **One download, two ways to install it.** Each release is a disk image holding Winbar.app beside
  a symlink to /Applications: drag one onto the other, or `brew install --cask
  taggie313/tap/winbar` and let the cask mount the same file. The image and the app inside it are
  each Developer ID signed, notarized by Apple and stapled, so macOS accepts both offline.
- An update check, because someone who installed from the disk image doesn't get `brew upgrade`:
  once a day at launch Winbar asks GitHub for the newest release, and adds one menu item when
  there is a newer one. Nothing is downloaded or installed, nothing is retried, and every failure
  — offline, rate-limited, junk — is silent. A copy installed by Homebrew is told to `brew
  upgrade` rather than sent to download an image. `winbar --version --check` asks on demand.
- [docs/RECIPE.md](https://github.com/taggie313/winbar/blob/main/docs/RECIPE.md): the whole
  recipe by hand, with the measurements behind it.
- [THIRD-PARTY.md](https://github.com/taggie313/winbar/blob/main/THIRD-PARTY.md): what came from
  somewhere else, setting by setting — the Windows settings the answer file applies were
  established by reading Rufus 4.15's `wue.c` (Rufus is GPL-3.0; none of its code is here), plus
  the pinned UTM Guest Tools installer `create` downloads at run time and never redistributes, and
  the CLDR-derived time zone table.

[0.1.0]: https://github.com/taggie313/winbar/releases/tag/v0.1.0


- An optional **Windows product key** for `winbar create`. Without one, nothing changes: Windows
  installs unactivated, exactly as before, and you can activate it later under Settings > System >
  Activation. With one, Windows activates itself once it has a network. `--product-key` asks for
  the key at a hidden prompt after the password, `--product-key-stdin` reads it from a pipe for
  scripted runs, and the **New Windows VM** window has a **Product key** field under the edition.
  Hyphens are optional and case doesn't matter. **The key is never a flag value** and there is no
  environment variable for it, for the same reason as the password: arguments are visible to every
  program on your Mac and end up in your shell history.
  Two honest notes. The key goes into Windows' answer file **in plain text** — a product key has no
  scrambled form the way the account password does — so what protects it is the setup disk itself:
  readable only by your Mac account, kept out of Time Machine, and deleted as soon as Windows has
  finished installing. And Winbar can't tell which edition a key is for, so it doesn't guess:
  Windows Setup refuses a key that isn't for the edition being installed.
- `winbar config --forget NAME` drops everything Winbar remembers about a VM, which is now the only
  way to lose it. `winbar create --cancel` does it for the VM it deletes.
- `winbar setup` and `winbar create` offer to install the two apps Winbar needs but doesn't ship —
  **UTM** and Microsoft's **Windows App** — instead of printing a Homebrew command for you to type.
  With Homebrew, Winbar asks it (`brew install --cask utm` / `windows-app`) and shows its output as
  it goes; without Homebrew it fetches UTM's own disk image, checks that Apple notarized it and
  that UTM's developer signed it before opening it, and copies UTM to /Applications, and for
  Windows App it opens the Mac App Store page, because Microsoft ships it there and nobody can
  press Get for you. Every path says what it will download, how big it is and where from, installs
  nothing without a yes, verifies the bundle id, signature, team and version afterwards, and never
  runs anything as an administrator. Homebrew is never installed for you.

### Changed

- Settings are kept per VM. Choosing another VM used to delete everything remembered about the one
  you were leaving — its Remote Desktop host and user, its saved PC, its MAC, its BitLocker state —
  so switching to a second VM and back meant typing them all in again. Each VM now has its own,
  filed under the id UTM gave it, and choosing between them changes nothing else. Existing settings
  move to the VM they describe the first time this version runs; with one VM nothing looks any
  different.
- Doctor's **H1 UTM installed** and **C1 Windows App** rows now say where each app stands —
  installed, missing, too old for Winbar, or signed by somebody else — and count as rows setup can
  fix rather than rows that need you.
- A new **H9 UTM answers Winbar** row, and a wait after UTM is installed. Everything Winbar asks of
  UTM is an Apple Event, and macOS holds the first one to a newly installed UTM until someone
  answers "… wants to control UTM" — a prompt that can open behind another window, and that a
  locked Mac never gets. While it waits, `utmctl` says nothing at all, which reads as a broken
  Winbar. The install now says the prompt is coming, waits up to a minute for utmctl to answer,
  and, if it doesn't, says whether the prompt is still outstanding or macOS already has an answer
  on file. The VM listing in `winbar setup`, `winbar doctor`'s H2 row and `winbar create`'s
  preflight say the same when they time out, instead of showing the raw "AppleEvent timed out
  (-1712)".


- Doctor's **H1 UTM installed** and **C1 Windows App** rows now say where each app stands —
  installed, missing, too old for Winbar, or signed by somebody else — and count as rows setup can
  fix rather than rows that need you.
- A new **H9 UTM answers Winbar** row, and a wait after UTM is installed. Everything Winbar asks of
  UTM is an Apple Event, and macOS holds the first one to a newly installed UTM until someone
  answers "… wants to control UTM" — a prompt that can open behind another window, and that a
  locked Mac never gets. While it waits, `utmctl` says nothing at all, which reads as a broken
  Winbar. The install now says the prompt is coming, waits up to a minute for utmctl to answer,
  and, if it doesn't, says whether the prompt is still outstanding or macOS already has an answer
  on file. The VM listing in `winbar setup`, `winbar doctor`'s H2 row and `winbar create`'s
  preflight say the same when they time out, instead of showing the raw "AppleEvent timed out
  (-1712)".

### Fixed

- Asking macOS whether Winbar may control UTM (`AEDeterminePermissionToAutomateTarget`) can block
  for as long as it likes, despite being told not to prompt: on a Mac waiting on that first
  permission, it blocked for twenty minutes and `winbar doctor` printed no row after the one that
  asked. It is now asked on another thread with a three-second deadline, and "macOS didn't say" is
  an answer in its own right. `winbar create` asked the same question the same way.


- Asking macOS whether Winbar may control UTM (`AEDeterminePermissionToAutomateTarget`) can block
  for as long as it likes, despite being told not to prompt: on a Mac waiting on that first
  permission, it blocked for twenty minutes and `winbar doctor` printed no row after the one that
  asked. It is now asked on another thread with a three-second deadline, and "macOS didn't say" is
  an answer in its own right. `winbar create` asked the same question the same way.

[0.1.0]: https://github.com/taggie313/winbar/releases/tag/v0.1.0
