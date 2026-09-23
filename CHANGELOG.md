# Changelog

All notable changes to Winbar are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/). `scripts/release.sh` publishes each version's section
as its GitHub release notes.

## [Unreleased]

## [0.2.0] - 2026-09-23

### Added

- **Set Up Winbar**, a window that sets Winbar up without Terminal. It opens by itself the first time
  Winbar runs on a Mac that hasn't set it up, and **Set Up Winbar…** in the menu opens it whenever
  you like (so does `winbar setup --window`). It checks for UTM and installs it if it's missing,
  uses an existing Windows VM or makes one and installs Windows in it, tunes Windows and shows each
  setting's result, trusts the VM's certificate, saves the PC in Windows App, opens a first
  connection and asks whether the desktop appeared — and only then offers to run the VM headless,
  with one restart and a second connection check. It says before each macOS permission prompt what
  it is for. When the connection doesn't work, it checks the VM's Remote Desktop port and advises
  from the answer: Local Network settings only when macOS blocked the check, waiting while Windows
  is still starting or updating (watched in the VM's UTM window, or through **Show Console Window…**
  when the VM has no screen), and otherwise finishing the sign-in in Windows App with the account's
  password rather than a PIN. Passwords are cleared on save or close, and conflicting
  actions are disabled or refused while it works, never queued. A Mac that already has a VM chosen,
  or put the window away before, isn't greeted again. `winbar setup` in Terminal is still a
  complete route of its own.
- **Armie**, a small chip with a face, keeps Set Up Winbar company where there's only waiting to
  do: while UTM installs, on the empty step before you have a Windows VM, while Windows installs,
  while a stopped VM starts, and once more at the end, when the desktop has appeared. He says one
  plain, true line about what is happening, and stays away from anything that needs you — a
  password, a permission prompt, an error or a stalled install. **Hide Armie** retires him for good,
  and with Reduce Motion on he's a still picture.
- **Report a Problem…** in the menu: the same report, for the part of Winbar's audience that has
  never opened Terminal. It says what it is about to gather and offers the anonymised version as a
  checkbox, runs with the icon blinking (it takes a minute or two, because it asks UTM and
  Windows), then shows the finished file in the Finder and opens Winbar's issues page, so it can be
  dragged straight into the report. The app gathers it in its own process on purpose: privacy
  grants belong to whoever started a process, so the `winbar doctor` table in it is Winbar's own
  view of the Mac rather than a terminal's.

### Changed

- A stalled Windows App saved-PC read now has a ten-second command deadline and is not retried on
  every wizard page. Retry Automatic Setup or an updated client permits a new attempt. If automatic
  saving fails, the wizard offers Continue to Sign-in without claiming that a connection was saved.
- Certificate approval in the setup wizard now explains what to do in macOS, what Winbar is
  checking, and whether approval was verified, skipped or unsuccessful. Later steps name their
  next action and completion signal; Continue buttons name their destination or skipped check.
- Automatic setup rechecks now show their busy state and disable conflicting buttons. When the
  check ends, its busy message clears and its work lock is released before actions become available.
- The setup wizard's Tune page keeps an explicit result on every row: Verified, Pending restart,
  Skipped or Needs attention, with separate information and in-progress labels. A summary counts
  the results, and only a successful settings check earns Verified—not an action finishing.
- With no VM chosen, the hint under **Choose VM** now points to **Set Up Winbar…** instead of
  Terminal, and when **Connect** can't open Windows App its message names **Set Up Winbar…** first,
  with `winbar setup` as the other way.
- The **New Windows VM…** window's last screen now names **Set Up Winbar…** in the menu as the next
  step, with the `winbar setup` command still there to copy, and when UTM is missing it names
  **Set Up Winbar…** first to install it, with `winbar create` in Terminal as the other way.
- With no VM chosen, the menu no longer lists **New Windows VM…** twice. It had it once under the
  setup hint and again after **Open UTM**; the first stays.
- `winbar diagnose --anonymise` now replaces ids and MAC addresses as well as names. A VM's UTM id —
  the `vmID` setting, and the `vm.<id>.*` prefix on every one of that VM's keys — is written as
  `<vm-1-id>`, and the MAC address under `vmMAC` as `<vm-1-mac>`, both numbered for the same VM as
  the `<vm-1>` beside them, so the settings section still says which block belongs to which VM.
  Anything else shaped like an id becomes `<id-1>`, `<id-2>…` and any other MAC address
  `<mac-address-1>`, `<mac-address-2>…`, in the order each first appears: Windows App's saved-PC id,
  a UTM drive id, a scratch file's name. An id counts in both the forms that get written — 8-4-4-4-12
  hex, and the same 32 characters unbroken, which is how the Windows registry and some of UTM's own
  output write it — and the two forms of one id share a number. It is worth saying what that costs,
  because a privacy control that only advertises its benefits is not one: two VMs can no longer be
  told apart by id or by MAC across a thread of issues, and a string of either shape that identifies
  nobody — a documented Windows GUID, say — is now a placeholder rather than a fact. The rule is
  scoped to those two shapes and says so everywhere it is described, because "every id in the file"
  was a promise wider than the code: an identifier of some other shape is left exactly as it was.
  Ids and the MAC were the identifiers a published report still carried after the box was ticked,
  and a report is only as private as its worst line. Verbatim mode, which is still the default, is
  unchanged. The report's mode line, the menu's alert, `winbar help` and the README all name the new
  placeholders, and while they were being rewritten they picked up the Windows user names, which
  `--anonymise` has replaced all along and none of the four had ever mentioned. The Mac's full user
  name is named by the report's own mode line, which is the one surface that lists every placeholder.
- `winbar diagnose --anonymise` also replaces the name Windows knows itself by, as `<windows-pc-1>`.
  It reaches the report in `passwordCheckedFor`, which is written as `COMPUTERNAME\user`, and in the
  RDP host derived from the guest's DNS name — and nothing was gathering it. On a Mac where Windows
  was named after its VM it only looked masked, by the VM's name; a default install is
  `DESKTOP-4F8J2K1`, which shares nothing with any name Winbar was already replacing and went out
  verbatim. The account half of the same field is taken too, so a VM whose `rdpUser` was never
  written no longer names its Windows user there.
- `winbar create` now says something different about a pre-release of UTM's next major version than
  about a 4.x it happens not to have been run against. Every version that wasn't the string 4.7.5
  used to get the same vague sentence, which threw away both what is known and what is not. A UTM a
  major ahead of anything create has been run against now says so in its own words, under its own
  key (`W_UTM_PRERELEASE`): the parts Winbar drives are the same in UTM 5.0.5's source, which was
  read on 2026-09-20, and nothing has been run on a UTM 5. Anything else untested keeps
  `W_UTM_UNTESTED`. Neither blocks anything, and neither claims support Winbar hasn't earned — a
  version is called tested only after `winbar create` has actually been run against that exact
  version. The floor is unchanged: UTM below 4.7 is still refused with `E_UTM_OLD`, exit 69.
- `winbar doctor`'s UTM row now says how tested the installed UTM is — `UTM 4.7.6 (Winbar is tested
  against 4.7.5)`, or `UTM 5.0.5 (a pre-release; Winbar is tested against 4.7.5)` — so a bug report
  carries which UTM it came from without anyone having to ask for it. The row is still a pass and
  `winbar doctor` still exits 0: which UTM a Mac has is a fact, not a fault. A UTM that doesn't say
  its version, and the tested version itself, read exactly as they did before.

### Fixed

- Setup now follows the selected VM by identity, drops confirmations and staged changes when it
  changes, and releases menu controls when a closed window's work ends. A hidden install does not
  start a new survey; unseen connection/restart results are applied when setup reopens. Setup,
  the installer and menu operations refuse conflicting work. Embedded install progress remains
  visible in the menu, with unrelated VMs retaining their controls.
- Setup offers Undo and Keep the Screen for staged changes, including after a safe restart
  refusal. Permission guidance covers Windows App's separate Local Network approval; requesting
  Accessibility no longer probes the network. Recovery text, VM switching and multiline layout
  are corrected, with controller and light/dark recovery-screen regression tests.
- The New Windows VM window ignores a second delivery of an already-dismissed install result,
  so reopening it shows a new form instead of resurrecting the last install's ending.

- The README's headline measurement was wrong and is corrected. It claimed idle host CPU of 59.8
  CPU-seconds per minute with the VM's window open against 6.3 headless, "~90% less". Re-measured
  with both sides taken the same way — each from a fresh boot, identical settle, 30 one-minute
  samples — neither number reproduced: idle is near 0.5 CPU-seconds per minute headless and 1.7
  with the window open, so the saving is about two thirds, and both are a small fraction of one
  core. Headless is still cheaper; it is not the difference that was published. The table now quotes
  a median rather than a mean, because idle cost is bursty enough that the mean swung between 0.8
  and 2.7 across two runs of the same thing. The same wrong figure was in the app itself — `winbar
  doctor`'s display row and its explanation, and `winbar create`'s description of the headless offer —
  and those now say "about two thirds" too.

- Sharing a folder no longer breaks going headless. `winbar display on|off`, and any vCPU or RAM
  change, failed outright on a VM with a shared folder Winbar had set:
  `UTM got an error: The file “Shared-with-Windows” couldn't be opened. (-2700)` — an error naming a
  folder that has nothing to do with the change being made. UTM's `update configuration` makes UTM
  touch the VM's registry, and a folder set by script is stored as a bookmark belonging to a helper
  process, which UTM cannot resolve; the change failed, and the shared folder was silently dropped.
  It was not a bookmark going stale with age: a folder set and checked from inside Windows two
  minutes earlier failed in exactly the same way. Winbar now sets the folder aside for the change and
  puts it back afterwards — and says so while it does it, because it is your folder. A folder chosen
  in UTM's own details screen is never touched: that one has a durable bookmark, doesn't cause this,
  and moving it would trade what you picked for a fragile copy. If putting it back ever fails, the
  message says which folder and how to set it again, rather than leaving you to notice.
- `winbar diagnose --anonymise` now takes the Windows PC name out of the settings that hold it when
  the VM is off. It was gathered from `passwordCheckedFor` and from a running guest's own
  `COMPUTERNAME`/`DNSHOST` — and neither exists on the Mac a report is usually written from, the one
  whose VM won't start. The same name is in `rdpHost`, `savedPCHost` and `savedPCName`, which the
  settings section prints and which `Connection.resolveHost` writes the first time Connect works, so
  with the VM off the name shipped. All three are read now, with the `.local` taken off so a host
  name and the bare name it is built from are one machine with one placeholder, and an address typed
  in place of a name is left alone rather than being called a machine name.
- `--anonymise` now finds a MAC address however it is written: `xx:xx:xx:xx:xx:xx`,
  `xx-xx-xx-xx-xx-xx` (what Windows' own `getmac` and `ipconfig` print), `xxxx.xxxx.xxxx` and twelve
  unbroken hex characters (a registry value, a lease table). The rule knew only the colon form,
  which is what UTM and QEMU write — but the report also carries a Windows guest's output and a
  create log full of it, so three spellings of the VM's own card went out whole. The VM's known MAC
  is matched in all four and keeps its `<vm-1-mac>` in each. The id rule had been taught its second
  spelling for exactly this reason; the asymmetry is closed.
- A run of more than six hex pairs is now replaced whole. Leftmost matching took the first six of an
  eight-pair run — an EUI-64, a fabric GUID — wrote `<mac-address-1>` and left the trailing bytes
  beside it. Every other escape in the redactor is silent; that one told the reader it had worked.
- A name with an accent in it is now replaced whichever way the text spells it. `NSFullUserName()`
  returns composed and a path read off APFS is decomposed, and `NSRegularExpression` compares code
  units rather than canonically, so `Renée` never matched `Rene\u{0301}e` and the whole name was
  published. The report itself is left byte for byte as it arrived — a file whose job is to
  reproduce what other programs printed must not quietly renormalise them — and the needle is
  matched in both forms instead.
- A name with a space in it is no longer defeated by the report's own line breaking. The preamble
  and the self-test notes are wrapped at 100 columns, and `fullUserName` and `computerName` are
  exactly the needles that contain a space: `Rosa Marchetti` wrapped between the words published
  `Marchetti`, and because the first word *was* replaced the line read as though redaction had
  worked.
- An over-long log is now trimmed by whole lines, and a cut inside the last line stops at a space.
  The byte limit used to come off in characters wherever the arithmetic landed, as readily in the
  middle of a UUID as between two words — and half an id is not id-shaped, so the sweep that runs
  over the finished report never saw the fragment it left.
- `docs/internal/privacy-scan.sh` reads array settings. It matched `key = "value";` and so saw
  scalar strings only, which meant it gathered nothing at all from `passwordCheckedFor` — the one
  place in the settings that holds the Windows PC name and the Windows account name. It reads the
  whole settings tree through PlistBuddy now, and splits a `COMPUTER\user` value into its halves.
  It found a real Windows account name hard-coded in two test fixtures the first time it was run.
- The menu's checkbox says MAC addresses, the alert names a placeholder for every identifier it
  lists, and the issue template no longer says a debug run leaves the VM's UTM id out: a
  `WINBAR_DEBUG=1` run logs what `utmctl list` answered, which is every VM's id and name, to the
  standard error the template asks people to paste into a public issue. The template's own summary
  of what `--anonymise` replaces and its footer now agree with each other and with the code.

## [0.1.1] - 2026-09-20

Two things aimed at the same problem: when an install goes wrong on someone else's Mac,
neither of us can see it. Now there is one file to send, and a wedged install says so
instead of sitting there.

### Added

- `winbar diagnose`: writes one plain-text file — to your Desktop by default — with everything an
  answerable bug report needs, instead of asking someone to copy and paste from four places. The
  versions and environment (Winbar and where it was installed from, macOS, the Mac, free space,
  UTM, Windows App, the Guest Tools), the whole `winbar doctor` table with its why and how, what the
  menu bar app itself sees (the address macOS leased the VM, the interface Winbar probed, whether
  port 3389 answered, Launch at Login, and whether Accessibility is granted to Winbar rather than to
  a terminal — the facts a "Connect doesn't work" report turns on, which the doctor table can only
  collapse into a ✓ or a ·), Winbar's own settings, the tail of the most recent `winbar create` log
  and its serial log, and the headline of UTM's recent crash reports. The install job's `state.json`
  is named, so it can be asked for, rather than copied in. Every section reports its own absence, so it works with no VM, no
  UTM, no logs and no settings — the case it exists for — and the doctor table has a deadline on it,
  because a UTM that never answers can otherwise take the whole run with it. Nothing shaped like a
  password, a key or a token gets through, whichever section it came from; `--anonymise` also
  replaces this Mac's name, your Mac and Windows user names and your VM names, and the file says at
  the top which mode made it. `--no-logs` leaves the create logs out, `--out PATH` puts it
  somewhere else.
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

### Fixed

- `winbar create` now says something when Windows Setup wedges while the VM stays busy. The stall
  rule only fired on a VM that was doing nothing at all, so an install that wrote 15.9 GB and then
  wrote nothing for 16 minutes with QEMU at 99 % of a core produced no message at all — the run
  would have waited out the whole two-hour limit in silence. During the copy, devices and getting-ready
  stages, twelve minutes with nothing written is now reported whatever the CPU is doing (W_STALL_BUSY),
  alongside the quiet-VM warning it already had (W_STALL). Both are said once, both disappear when the
  VM writes again, and neither stops or restarts anything: Winbar reports, you decide.
- Both stall warnings now say how to get out of it — stop the VM and start it again, then
  `winbar create --resume "name"` — and that Setup redoes the stage it was in, so that stage's
  progress is lost.
- The window showed a stall warning twice, once in its orange box and once in the list of everything
  the job has said. It appears once now.
- Asking macOS whether Winbar may control UTM (`AEDeterminePermissionToAutomateTarget`) can block
  for as long as it likes, despite being told not to prompt: on a Mac waiting on that first
  permission, it blocked for twenty minutes and `winbar doctor` printed no row after the one that
  asked. It is now asked on another thread with a three-second deadline, and "macOS didn't say" is
  an answer in its own right. `winbar create` asked the same question the same way.

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

[0.2.0]: https://github.com/taggie313/winbar/releases/tag/v0.2.0
[0.1.1]: https://github.com/taggie313/winbar/releases/tag/v0.1.1
[0.1.0]: https://github.com/taggie313/winbar/releases/tag/v0.1.0
