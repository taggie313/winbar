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
  Two things Winbar says out loud instead of letting you discover them: a change needs the VM to
  restart — sometimes twice, because UTM hands Windows the folder it had at the *previous* start, so
  Winbar checks from inside Windows and restarts again only if it has to — and the folder's path
  must have no spaces in it, or Windows mounts an empty drive that fails every write.
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
