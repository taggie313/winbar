# Winbar

A menu bar icon for a Windows 11 virtual machine in [UTM](https://mac.getutm.app) on an Apple
silicon Mac, plus `winbar setup`, which tunes that VM into a quiet, headless machine you reach
over Remote Desktop.

Click **Connect** and you're at the Windows desktop in Windows App, already signed in. No
password prompt, no certificate warning, no chooser window. When you're done, **Shut Down**
actually shuts Windows down.

[**Download the disk image**](https://github.com/taggie313/winbar/releases/latest) and drag
Winbar to Applications — or `brew install --cask taggie313/tap/winbar`. Then:

```sh
winbar setup
```

- **Headless.** The VM runs with no virtual screen at all, which cut idle host CPU by about 90%.
- **One click.** Connect opens your saved PC in Windows App, reusing its stored password.
- **A recipe, not magic.** `winbar setup` checks every setting, changes only what's wrong (asking
  first), and walks you through the few steps only a person can do. Re-running it is safe.
- **Measured.** The settings that cost real time or CPU were tried and timed, and kept only if
  they paid for themselves; the rest are there for a reason that's written down. The hand-done
  version, with both, is in [docs/RECIPE.md](docs/RECIPE.md).

---

## Contents

- [Why: what was measured](#why-what-was-measured)
- [Requirements](#requirements)
- [Install](#install)
- [Creating a new Windows VM](#creating-a-new-windows-vm)
- [Setting up: `winbar setup`](#setting-up-winbar-setup)
- [The menu](#the-menu)
- [A shared folder](#a-shared-folder)
- [Security defaults](#security-defaults)
- [Troubleshooting](#troubleshooting)
- [Problems and contributions](#problems-and-contributions)
- [Uninstall](#uninstall)
- [How it works](#how-it-works)
- [Build it yourself](#build-it-yourself)

## Why: what was measured

Winbar packages a setup that was first built and measured by hand on one Mac (an M5 Max running
Windows 11 Pro ARM64 in UTM 4.7). The numbers are from that machine, on battery. Yours will
differ, but every comparison was made like-for-like.

| Finding | Measurement |
|---|---|
| **Headless is the big win.** UTM's virtual GPU is display-only, so every frame Windows draws is copied by the Mac's CPU. With no display device at all, that work disappears. | Guest idle, QEMU host CPU per minute: **59.8 s** with the VM window open (about one whole core) vs **6.3 s** headless, **~90% less**. UTM itself went from 2.8 s to 0. |
| **More vCPUs isn't better.** On an M5 Max (6 "Super" cores plus 12 "Performance" cores), a fixed workload was run at 4, 6 and 8 vCPUs. | **6 was cheapest** in host CPU and fastest. **8 cost 28% more** host CPU (37.8 vs 29.6 CPU-s) for no speed gain; 4 was slower and no cheaper. Winbar sets vCPUs to your Mac's top-tier core count, kept between 4 and 8. |
| **Converting the disk image (qcow2 to raw) isn't worth it.** | The Mac writes 2 GiB to the image file in 0.17 s; Windows takes 2.2 s for the same write. **~93% of the cost is the virtual disk device path**, not the image format. |
| **"Stop" has to go through Windows.** UTM's stop button presses a virtual ACPI power button. Once Windows has blanked its display, it treats that press as *wake* (event log: Kernel-Power 566) and never shuts down. | Winbar asks Windows itself to shut down, through UTM's guest agent, and only falls back to the power button. |
| **Balanced beats Ultimate Performance.** Ultimate Performance disables core parking, and parked vCPUs are what let the Mac's cores sleep. | Balanced with a fast ramp-up kept both speed and idle efficiency. |
| **The menu bar app itself is cheap.** | The prototype measured 0.05 CPU-seconds per minute idle. |

## Requirements

- A Mac with **Apple silicon**, running **macOS 14 Sonoma** or later.
- **UTM**, the app that actually runs the VM. You don't have to install it first: `winbar setup`
  and `winbar create` offer to install it for you — through Homebrew if you have it, otherwise
  from UTM's own download, which Winbar checks is notarized by Apple and signed by UTM's
  developer before it opens it. By hand: `brew install --cask utm`, the Mac App Store or
  [getutm.app](https://mac.getutm.app).
- A **Windows 11 ARM64** VM in UTM, using UTM's default **Shared Network** mode, with the
  **UTM Guest Tools** installed inside Windows (Winbar talks to Windows through them). No VM yet?
  `winbar create` makes one and installs Windows for you; you'll need a Windows 11 ARM64 ISO from
  Microsoft, about 40 GB of free space, and a connection it can download the UTM Guest Tools
  installer over (80 MB, once — see below).
- **Windows 11 Pro**, Enterprise or Education. **Windows 11 Home can't accept Remote Desktop
  connections**, so it won't work.
- **Not for 3D games or GPU work.** The VM has no graphics card: UTM gives Windows a display-only
  adapter, so Direct3D falls back to Microsoft's software renderer and runs on the emulated CPU.
  Office, browsers, developer tools and line-of-business software are fine. Games, CAD and anything
  that expects a GPU are not.
- **Windows App** (Microsoft's Remote Desktop app). `winbar setup` offers to install this one too:
  with Homebrew, or by opening its Mac App Store page — Microsoft ships it through the App Store,
  and an App Store app can't be installed for you, so the Get button stays yours to press. By
  hand: `brew install --cask windows-app` or the Mac App Store.
- About 15 minutes, and your Windows PIN or password handy. [Homebrew](https://brew.sh) is
  optional — it's one of the two ways to install Winbar, and the way Winbar installs the two apps
  above when you have it. Winbar never installs Homebrew itself: a package manager isn't its to
  put on your Mac.

## Install

Go to the [latest release](https://github.com/taggie313/winbar/releases/latest) and download
**Winbar-<version>.dmg**. Open it, and drag Winbar onto the Applications folder beside it. That's
the install.

Then open **Winbar** from Applications once, to start it and put its icon in the menu bar. macOS
asks whether to open an app downloaded from the internet — Winbar is signed and notarized by
Apple, so choose **Open**. Later, the first time you use it, macOS asks whether Winbar may control
UTM and (for Connect) whether it may use Accessibility. Both are how Winbar does its job: starting
and reconfiguring the VM, and clicking your saved PC in Windows App. `winbar setup` explains each
one when it gets there.

Prefer Homebrew? The same disk image, installed for you, and `brew upgrade` keeps it current:

```sh
brew install --cask taggie313/tap/winbar
```

The full name `taggie313/tap/winbar` says which tap the cask comes from; Homebrew adds that tap
for you the first time, so there's nothing to do beforehand. It's not an official Homebrew cask.

Either way, Winbar needs two other apps: **UTM**, which runs the VM, and Microsoft's **Windows
App**, which shows its desktop. You don't have to go and get them first — `winbar setup` checks for
both and offers to install whichever is missing:

- **With Homebrew**, it asks Homebrew to do it (`brew install --cask utm`,
  `brew install --cask windows-app`) and shows Homebrew's own output as it goes. Windows App is an
  installer package, so Homebrew asks for your Mac password; that prompt is Homebrew's. Winbar
  never runs anything as an administrator.
- **Without Homebrew**, it fetches UTM's own disk image, checks that Apple notarized it and that
  UTM's developer signed it *before* opening it, and copies UTM to your Applications folder. For
  Windows App it opens the Mac App Store page: Microsoft only ships it there, and nobody can press
  Get for you.

It always says what it will download, roughly how big it is and where from, and nothing is
installed unless you say yes.

Once UTM is installed, macOS asks whether Winbar (or your terminal app) may **control UTM** the
first time it drives it — choose **Allow**; that's how Winbar starts, stops and reconfigures the
VM. Until it's answered, UTM's command-line tool waits silently, so setup waits for it and says
what to look for: the prompt can open behind other windows, and a Mac left locked never gets past
it. Opening UTM once from your Applications folder first is the easiest way to get it in front of
you. `winbar doctor`'s **H9 UTM answers Winbar** row says which state you're in.

Prefer to do it yourself? The commands still work:

```sh
brew install --cask utm windows-app      # skip any you already have
```

Winbar asks GitHub once a day whether there is a newer release, and adds one menu item when there
is. It never downloads or installs an update by itself, and says nothing at all when it can't
reach GitHub. `winbar --version --check` asks on demand.

## Creating a new Windows VM

No VM yet? `winbar create` makes one and installs Windows 11 into it with no clicking — the parts
you would otherwise do by hand in UTM's wizard, Windows Setup and the out-of-box questions. It
takes about 10 minutes on a fast Apple silicon Mac (measured twice on an M5 Max), longer on an
older one, and you don't have to watch.

```sh
winbar create
```

You need a **Windows 11 ARM64 ISO** from
[Microsoft's download page](https://www.microsoft.com/software-download/windows11arm64) (about
7 GB) and around 40 GB of free space. Winbar finds the newest ARM64 ISO in your Downloads folder
and offers it; `--iso PATH` picks another. Keep the file where it is until Windows has finished
installing: UTM reads it from there.

`create` also downloads one file: the pinned **UTM Guest Tools** installer, 80 MB, from
github.com/utmapp, checked against a SHA-256 and a byte count before it is used. It is kept in
`~/Library/Caches/net.elusive.winbar`, so later installs reuse it. Already have that exact
installer? `--guest-tools PATH` uses your copy and downloads nothing. Nothing else is fetched
from the network: Windows Setup itself runs offline.

Winbar shows the plan as a checklist you can change, then asks for the Windows password twice.
**The password is never a flag or an environment variable** — arguments are visible to every
program on your Mac and end up in your shell history. A Windows product key, if you have one, is
optional and asked for the same way (`--product-key`). Prefer a window? `winbar create --window`,
or **New Windows VM…** in the menu.

### The checklist

Rufus's "Windows User Experience" options, in Rufus's order, plus what Winbar needs:

| Option | Default | Turn it off with |
|---|---|---|
| Remove the 4 GB RAM, Secure Boot and TPM 2.0 requirement | always on | — (UTM can't give a scripted VM a TPM) |
| Remove the online Microsoft account requirement | on | `--no-online-account-bypass` |
| Create a local account | always on | — (Remote Desktop and automatic sign-in need one) |
| Copy this Mac's region, keyboard and time zone | on | `--no-regional` |
| Skip the privacy questions | on | `--no-skip-privacy` |
| Install the edition you pick, on the VM's new disk | Pro | `--edition NAME` |
| Keep BitLocker's automatic device encryption off | on | `--allow-bitlocker` |
| Don't force Copilot, OneDrive, Outlook, Fast Startup | on | `--no-qol` |
| Sign in automatically at startup | on | `--no-autologon` |
| Turn on Remote Desktop, with NLA | on | `--no-remote-desktop` |
| Install the UTM Guest Tools | always on | — (they carry the network driver and the guest agent) |
| Apply Winbar's tuning | on | `--no-winbar-tuning` |
| Use a Windows product key | off | `--product-key` turns it **on** (see below) |

Windows' display language always comes from the ISO: other languages would have to be downloaded,
and the install runs offline. `winbar create --help` lists every option, and `--dry-run` prints the
whole plan without creating anything.

Four Rufus options are deliberately left out: the 'Windows CA 2023' bootloaders and SkuSiPolicy
(both only matter with Secure Boot, which this VM doesn't have), S Mode (the Guest Tools couldn't
install) and Windows To Go (a VM isn't a USB stick).

### If you have a product key

Without one — the default, and what Winbar has always done — Windows installs unactivated. It works,
with a watermark and a few personalisation settings greyed out, and you can activate it whenever you
like under **Settings > System > Activation**.

Have a licence you want to use? `winbar create --product-key` asks for the key at a hidden prompt,
after the password, and installs with it; in the window there's a **Product key** field under the
edition. Type it with or without hyphens, in any case. For a scripted run, `--product-key-stdin`
reads it from a pipe:

```sh
op read op://Private/windows/key | winbar create --yes --product-key-stdin
```

**The key is never a flag value**, for the same reason the password isn't: arguments are visible to
every program on your Mac while the command runs, and end up in your shell history.

Two things to know. First, **the key goes into Windows' answer file in plain text**. A product key
has no scrambled form the way the account password does, so nothing hides it; what protects it is
the setup disk itself, which is readable only by your Mac account, kept out of Time Machine, and
deleted as soon as Windows has finished installing. Winbar keeps no other copy and never logs it.
Second, Winbar can't tell which edition a key is for and doesn't guess: **Windows Setup refuses a
key that isn't for the edition being installed** and asks for one on screen, so make sure the
edition in the checklist matches your licence.

### About that password

It goes into Windows' answer file on a small disk image Winbar builds, encoded the way Windows'
own tools encode it: scrambled, not encrypted. The image is readable only by your Mac account, is
kept out of Time Machine, and is deleted as soon as Windows is installed. Inside Windows, automatic
sign-in keeps the password as an LSA secret — not plain text, but anyone with administrator rights
in Windows, or with a copy of the VM's disk (backups, exports), can recover it, because BitLocker
is off. **Pick a password you don't use for your Mac or anywhere else.**

### What happens

Winbar reads the ISO, builds the setup disk, creates the VM in UTM, answers the installer's "Press
any key to boot from CD" prompt for you, and watches Windows Setup through the firmware's serial
console. When Windows is up it installs the Guest Tools, applies your choices, takes the install
discs off, and then — unless you gave `--console`, Remote Desktop can't be reached, or another VM
is running in UTM — shuts the VM down once and brings it back headless. Going headless restarts
UTM, which would stop any other VM it's running, so with one of those up the install ends on the
console instead. If another VM starts while Winbar is finishing, it leaves UTM alone and leaves
your VM stopped, and says to close the other VMs and run `winbar start`. You can close the window
or press Ctrl-C at any point: the install carries on, and `winbar create --resume` picks it back
up.

What's left for you afterwards is what `winbar setup` walks through below: trusting the VM's
certificate and allowing Accessibility. The PC is already saved in Windows App — `create` does that
itself, with the password you chose.

## Setting up: `winbar setup`

Start the VM, then in Terminal:

```sh
winbar setup                  # asks before each change
winbar setup --vm "Windows"   # if you have more than one VM, name the one to use
winbar doctor                 # just report, change nothing
```

Setup first prints a checklist (✓ fine, ! Winbar can fix it, ? needs you, · for information,
✗ problem), with the reason for anything that isn't fine. Then it works through it in this order:

1. Makes sure it can reach Windows, and that your Windows account has a password. Remote
   Desktop's sign-in protections would lock a blank-password account out, so they wait for this.
2. Fixes what it can inside Windows, asking **y/N** for each change. None of these needs a restart.
3. Offers to turn BitLocker off ([why](#security-defaults)).
4. Trusts the VM's Remote Desktop certificate on the Mac (macOS asks you to approve).
5. Walks you through the other steps it can't do for you: it opens the right window, waits while
   you do the step, and checks again.
6. Asks about vCPUs, memory and, once Remote Desktop has worked, going headless, and applies all
   of them with **one** restart of the VM.

Run it again any time. When everything is already right, it changes nothing.

### What Winbar does for you

| On the Mac | In Windows |
|---|---|
| Sets vCPUs to your Mac's top-tier core count (4 to 8) | Balanced power plan with a fast ramp-up; idle cores may park; display off after 5 min; never sleeps; hibernation off |
| Sets memory by how much your Mac has: 16 GB if it has 64 GB or more, 12 GB from 32 GB, otherwise 8 GB, but never more than half your Mac's memory. A larger value you already chose is left alone | Power button = Shut down |
| Makes the VM headless, once Remote Desktop works | Turns off SysMain, Windows Search indexing and DiagTrack (telemetry) |
| Trusts the VM's Remote Desktop certificate (macOS asks you to approve) | Turns off transparency and animations (skip with `--no-visual-tweaks`) |
| | Turns on Remote Desktop, with Network Level Authentication (once your account has a password) |
| | Gives Remote Desktop a certificate named for the address your Mac uses |
| | Decrypts BitLocker when the VM's disk is on an encrypted volume ([why](#security-defaults); keep it with `--keep-bitlocker`) |

VM settings are changed through UTM's own scripting interface, with the VM shut down, so UTM
applies them itself. Winbar never edits UTM's files.

### What needs you

You'll meet these in this order. Winbar opens the right window for each one.

1. **Let Winbar control UTM.** macOS asks once whether Winbar may control UTM, and once more for
   your terminal app when you use the `winbar` command. Allow both: it's how Winbar starts, stops
   and reconfigures the VM.
2. **Switch Windows to a local account**, if you sign in with a Microsoft account. Winbar opens
   *Settings > Accounts > Your info* inside Windows; choose **Sign in with a local account
   instead**, confirm with your PIN, and pick a password. Your files, apps and profile stay as
   they are, and you can still sign in to individual apps (Store, OneDrive) with your Microsoft
   account.
   *Why:* a Windows Hello PIN never works over Remote Desktop, and automatic sign-in with a
   Microsoft account would mean storing that password in plain text.
3. **Give the account a password**, if it has none. Remote Desktop refuses blank passwords, and
   Winbar won't turn that protection off. Until there's a password, Winbar leaves Remote Desktop
   alone rather than lock you out.
4. **Decide about BitLocker.** Setup asks before it decrypts C:. When the VM's disk is on an
   encrypted volume (FileVault, on your Mac's startup disk) the answer defaults to yes; otherwise
   decrypting would leave the disk unencrypted at rest, so it defaults to no
   ([details](#security-defaults)). A "no" is remembered.
5. **Approve the certificate.** macOS asks for your Mac password (or Touch ID) to change
   certificate trust settings. This trusts exactly one certificate, your VM's, for secure
   connections to your VM's name only.
6. **Turn on automatic sign-in.** Winbar opens `netplwiz` on the Windows desktop. Untick *Users
   must enter a user name and password to use this computer*, click OK, and type your password
   twice. Windows keeps it encrypted (as an LSA secret), not in plain text.
   *Why:* the VM boots straight to your desktop, and your Remote Desktop connection takes over
   that same session, so anything started at boot keeps running.
7. **Exclude the VM from Time Machine** (optional, recommended). *System Settings > General >
   Time Machine > Options*, click **+**, press ⌘⇧G and paste
   `~/Library/Containers/com.utmapp.UTM/Data/Documents`. That folder holds all your UTM VMs;
   backing up a disk image that changes constantly is slow and huge. Winbar can check this itself
   only if your terminal app has Full Disk Access, which isn't worth granting just for this, so it
   takes your word for it and remembers. The same folder can go in *System Settings > Spotlight >
   Search Privacy*.
8. **Switch the VM to Shared Network**, if it uses another network mode (in UTM, with the VM
   stopped: *Edit > Network*).
9. **Install Windows App**, if it isn't installed. Setup offers to do it: with Homebrew if you
   have it (Microsoft ships Windows App as an installer package, so Homebrew asks for your Mac
   password — that prompt is Homebrew's, and Winbar never runs anything as an administrator),
   otherwise by opening its Mac App Store page for you to press Get. It says what it will
   download and how big it is first, and does nothing unless you say yes.
10. **Save the PC in Windows App.** Setup offers to do this for you, and asks for your Windows
    password at a hidden prompt so it can hand it to Windows App. Windows App then keeps it in your
    login keychain, exactly as it would if you typed it in there; Winbar keeps no copy. For the
    second that takes, the password is one of Windows App's command line arguments, where another
    program running as you could read it — there is no other way to give Windows App a password
    without typing it in again. `winbar create` does this for you already, while it still has the
    password you chose.

    Quit Windows App first if it's open: saving a PC from the command line writes the same database
    a running copy has open. Say no, or leave Windows App open, and setup shows you the manual
    steps instead — Windows App > **Devices** > **+** > **Add PC**, with the host Winbar shows you
    (see `winbar config`) as the PC name and your Windows account under *Add credentials*.
11. **Allow Accessibility.** *System Settings > Privacy & Security > Accessibility*, turn on
    **Winbar**. Windows App's command line can save a PC but can't open one — there's no connect
    verb, and only a saved PC uses a stored password — so Winbar presses your PC's tile the way you
    would.
12. **Allow Local Network**, if macOS asks. Winbar checks the VM's Remote Desktop port before it
    connects.
13. **Go headless.** Once you've connected successfully, setup offers to remove the VM's virtual
    screen (the VM restarts once). You can also do it later: `winbar display off`.

### Options

| Option | Effect |
|---|---|
| `--vm NAME` | Which UTM VM to use (remembered for next time) |
| `--yes` | Answer the y/N questions yes. Setup still stops at the steps that need you, never goes headless by itself, never decrypts BitLocker unless it can see the VM's disk is on an encrypted volume, and never restarts the VM when it couldn't check BitLocker |
| `--no-visual-tweaks` | Leave Windows' animations and transparency alone (remembered for this VM; `winbar config --no-visual-tweaks no` undoes it) |
| `--keep-bitlocker` | Don't decrypt BitLocker (remembered for this VM; `winbar config --keep-bitlocker no` undoes it) |
| `--headless` / `--console` | Choose the display mode now instead of being asked |

## The menu

The icon is filled while the VM runs, a dimmed outline when it's stopped, and blinks while
something is happening. The top of the menu shows the VM's name and status.

| Menu item | What it does |
|---|---|
| **Connect** / **Start and Connect** | Opens your saved PC in Windows App, starting the VM first if needed |
| **Start** | Starts the VM without connecting (there when it's stopped) |
| **Shut Down** | Asks Windows to shut down properly. Hold **⌥** for **Force Stop**, a hard power-off (it asks first) |
| **Restart** | Clean shutdown, then start again |
| **Show Console Window…** / **Go Headless…** | Switch between UTM's window and headless (restarts the VM; asks first) |
| **Open Shared Folder** / **Share a Folder…** | Opens the folder this VM shares with Windows, or picks one (restarts the VM; asks first) |
| **Open UTM** | Brings up UTM |
| **New Windows VM…** | Opens the create window, the same as `winbar create --window` (off while an install is running) |
| **Launch at Login** | Start Winbar when you log in |
| **Quit Winbar** | Quits Winbar. The VM keeps running. While Winbar is in the middle of something, it asks first |

If no VM is chosen yet, the menu offers **Choose VM** and suggests running `winbar setup`.

Everything is also on the command line:

```sh
winbar start | stop | restart | connect
winbar display on | off        # UTM window, or headless
winbar share                   # the folder Windows can see (see below)
winbar config                  # show the VM, host and user Winbar uses
winbar config --host mypc.local --user alex
winbar config --keep-bitlocker no   # undo setup's --keep-bitlocker
winbar doctor                  # check everything
winbar --version
winbar help
```

## A shared folder

One folder on the Mac that Windows sees as a drive — `Z:` — so files don't have to go through
Remote Desktop's clipboard.

```sh
winbar share                        # what's shared now, and what Windows makes of it
winbar share ~/Shared-with-Windows  # share that folder (it offers to create it)
winbar share --off                  # stop sharing
```

The menu has **Open Shared Folder** when there is one and **Share a Folder…** when there isn't.
`winbar setup` offers `~/Shared-with-Windows` once and takes no for an answer; `winbar doctor` shows
the folder and the drive. Nobody needs one — doctor treats having none as a plain fact, not a problem.

Three things are worth knowing, and Winbar says all three rather than leaving you to find out:

- **The VM has to restart.** UTM hands the shared folder to Windows only at start-up, and it hands
  over the one it had at the *previous* start — so a change can take two restarts. Winbar asks
  before restarting, then checks from inside Windows and restarts a second time only if Windows is
  still serving the old folder. It never reports the folder as there without having looked.
- **No spaces in the path.** `~/Shared with Windows` mounts as an empty drive and every write fails
  with "A device attached to the system is not functioning"; the same files at
  `~/Shared-with-Windows` work in both directions. Winbar refuses a path with a space and suggests
  the hyphenated name.
- **A folder set this way doesn't survive UTM restarting.** Setting it by script is all Winbar can
  automate, and what UTM stores for it is a bookmark that lives only as long as the UTM that made
  it: relaunch UTM and the drive comes back empty. Winbar restarts UTM for every display change, so
  it writes the folder again on the way through, checks from inside Windows, and tells you when it
  couldn't. **If you want one that simply stays, pick it in UTM itself:** shut the VM down and
  choose a Shared Directory on its details screen. That one is a proper bookmark: it survives UTM
  restarting, and Windows has it from the very next start rather than the one after. Winbar never
  overwrites it — when a folder it didn't write stops working, `winbar share` says so and *offers*
  to write it again, explaining that its rewrite is the weaker kind.

There are two things that can go wrong and look identical from your desk — the folder is empty —
so Winbar names them separately. Either the share itself isn't serving your folder, or the `Z:` in
*your* Windows session is a stale handle while the share behind it is fine. A drive letter belongs
to a logon session, and the Guest Tools map yours when you sign in, which can happen before the
share is up. Winbar checks your own session, says which of the two it found, and maps the letter
again when that is all that's wrong.

It travels over WebDAV (`\\localhost@9843\DavWWWRoot`), which the UTM Guest Tools already set up —
nothing new is installed in Windows. Fine for documents and small projects; slow for very large
files.

## Security defaults

Winbar is meant to be safe to run on a friend's Mac, so it keeps protections on unless there's a
reason not to, and tells you when it makes a choice.

- **Your password is still required.** Remote Desktop keeps Network Level Authentication on
  (Windows checks your credentials before it starts a session) and blank-password network logons
  stay blocked. Winbar turns these on only once your account has a password, because they would
  lock a blank-password account out. The saved password lives in your login keychain, which is
  where Windows App keeps it.
- **Winbar hands your Windows password to Windows App, and says so.** That's how the PC gets saved
  without you typing it in again. Windows App's command line is the only way to do it and takes the
  password as an argument, so for the second that call runs, another program running as you could
  read it out of the process table. Winbar never logs it, never puts it in a file of its own, and
  never takes it as a flag or an environment variable of `winbar` itself. If you'd rather it didn't,
  say no when setup offers and add the PC in Windows App yourself.
- **Automatic sign-in** keeps the password encrypted inside Windows. It does mean anyone who can
  open the VM's window on your Mac lands on the desktop, so the VM is as private as your Mac
  account is.
- **A product key, if you give one, is plain text in the answer file.** There is no scrambled form
  for a product key the way there is for the account password, so Winbar doesn't pretend there is:
  what protects it is the setup disk, readable only by your Mac account, kept out of Time Machine,
  and deleted as soon as Windows has finished installing. It is never logged, never in Winbar's
  settings, and never taken as a flag or an environment variable.
- **One certificate, trusted for one purpose.** Winbar gives Windows' Remote Desktop a
  self-signed certificate named for the address your Mac connects to (2048-bit RSA, valid for
  10 years; its private key can't be exported and never leaves the VM). On the Mac it trusts that
  one certificate, for secure connections (SSL/TLS) only, for that one host name only, in your
  login keychain. It installs no certificate authority. The host name matters: an unscoped trust
  setting would make the VM's own key good for *every* site, and the VM's disk isn't encrypted.
- **Remote Desktop is only reachable from your Mac.** In UTM's default Shared Network mode, the
  VM sits on a private network inside your Mac (addresses like `192.168.64.x`) behind NAT. Only
  your Mac, and other VMs on it using Shared Network, can reach port 3389.
  **If you switch the VM to Bridged networking**, it gets an address on your real network, and
  Remote Desktop becomes reachable by everything on it (Winbar enables Windows' Remote Desktop
  firewall rules for all network types). Your password and NLA still protect it, but consider
  limiting the firewall rule to your Mac's address. Winbar's status check also only understands
  Shared Network, so with Bridged it will never show the VM as ready.
- **BitLocker is turned off, if the VM's disk is on an encrypted volume.** The VM's disk is a file
  on your Mac. UTM keeps it on your startup disk, which FileVault encrypts; if you keep the VM on
  an external drive, Winbar checks that drive's encryption instead. On top of that, BitLocker
  costs disk performance, and its key is sealed to UTM's software TPM, so any change to the VM's
  virtual hardware (even adding or removing its screen) makes Windows demand the 48-digit recovery
  key at boot. Winbar tells you why before it starts, and decryption carries on in the background.
  - Want to keep it? Use `winbar setup --keep-bitlocker` (remembered). Winbar then suspends
    BitLocker for one reboot before it changes the VM's hardware, so you don't get the recovery
    screen. With the VM off, it starts Windows to check BitLocker first.
  - **If the VM's disk isn't on an encrypted volume** (FileVault off, or an unencrypted external
    drive), Winbar asks instead of deciding, because decrypting would leave the disk unencrypted
    at rest. `--yes` never decrypts then, nor when Winbar can't tell where the disk is.
    Encrypting that volume is the better fix.
  - Either way, save your recovery key first. In Windows, in an administrator terminal:
    `manage-bde -protectors -get C:`
- **Privacy permissions** are used for one thing each: Automation (control UTM), Accessibility
  (press your PC's tile in Windows App), Local Network (check the VM's Remote Desktop port).
  Winbar is signed with a Developer ID, so the permissions you grant survive updates.
- Winbar has no telemetry.

## Troubleshooting

Start with `winbar doctor`. It checks everything and says why anything is wrong.

**Reporting something that's broken: `winbar diagnose`.** One command, one file, everything an
answerable bug report needs — instead of copying and pasting from four places:

```sh
winbar diagnose
```

It writes a plain-text file to your Desktop and tells you where. In it: the versions involved
(Winbar and where it was installed from, macOS, this Mac, free space, UTM, Windows App, the UTM
Guest Tools), the whole `winbar doctor` table with the why and how for anything that isn't ✓, what
the menu bar app itself sees (the VM's address on the network, whether Remote Desktop answered, and
the permissions that belong to Winbar rather than to your terminal), Winbar's own settings, the tail
of the most recent `winbar create` log and its serial log, and the headline of UTM's recent crash
reports — UTM crashing is often the answer. Read it (it's plain text, and it's yours), then attach
it to your issue.

It works when things are broken, which is the point: with no VM, no UTM, UTM not answering, no
logs and no settings, every section says so and the file is still written. It never contains your
Windows password, and it's swept for anything shaped like a password, a key or a token.

| | |
|---|---|
| `--anonymise` | replace this Mac's name, your Mac and Windows user names and your VM names with placeholders. The file says at the top which mode made it |
| `--no-logs` | leave the `winbar create` logs out |
| `--out PATH` | write it somewhere else (a folder gets today's file; a file name is taken at its word) |

**Connect asks for a password, or shows a certificate warning.** The password prompt means the
saved PC in Windows App has no stored password, or has the wrong one: edit the PC and add
credentials. A certificate warning means the name doesn't match or the certificate isn't trusted:
make sure the PC name in Windows App is exactly what `winbar config` shows, then run `winbar setup`
again.

**Connect opens Windows App but doesn't connect.** `winbar doctor` asks Windows App what it has
saved, so start there. Connect finds the tile by the PC's Friendly name when it has one, and by its
PC name when it hasn't; `winbar config` shows which name Winbar is looking for.

**Accessibility looks on, but Winbar says it isn't.** macOS sometimes keeps a stale entry. Reset
it and let Winbar ask again:

```sh
tccutil reset Accessibility net.elusive.winbar
```

Then quit and reopen Winbar and turn it on again when asked.

**Why `--self-test` has to run as the app.** A program started from Terminal inherits Terminal's
permissions, so running `winbar --self-test` directly would report Terminal's Accessibility
permission, not Winbar's. `winbar doctor` handles this for you by launching the app. To see the
real answer yourself:

```sh
open -n -W --stdout "$TMPDIR/winbar-selftest.txt" -a Winbar --args --self-test
cat "$TMPDIR/winbar-selftest.txt"
```

**The menu says "allow Local Network for Winbar to see readiness".** macOS's Local Network
permission is off for Winbar: *System Settings > Privacy & Security > Local Network*, turn on
Winbar. (macOS reports this as "no route to host", which a VM that's still booting can also cause,
so Winbar only concludes it after two refusals in a row.)

**Winbar (or your terminal) isn't allowed to control UTM.** If you clicked *Don't Allow* when macOS
asked, it doesn't ask again. Turn on UTM under Winbar (or your terminal app) in *System Settings >
Privacy & Security > Automation*. To get the prompt back instead:
`tccutil reset AppleEvents net.elusive.winbar` (for the `winbar` command, use your terminal's
bundle id, such as `com.apple.Terminal`).

**Winbar says UTM has to restart before the VM starts.** UTM only picks up a display change once it
restarts, and starting the VM from the old UTM crashes UTM along with every VM it runs. Winbar
restarts UTM itself when nothing else is running in it; otherwise stop your other VMs (or quit
UTM yourself) and start again.

**You use Tailscale (or another VPN) with an exit node.** An exit node can route the VM's
private addresses into the tunnel. Winbar's status check is pinned to the VM's network, so it
isn't fooled, and Windows App connected fine in testing, but tools like `ping` in Terminal may
fail. If Windows App can't connect, turn on *Allow Local Network Access* in Tailscale's
Exit Node menu, or turn the exit node off.

**UTM's own Stop button does nothing.** That's the ACPI problem from [Why](#why-what-was-measured):
once Windows has blanked its display, the virtual power button only wakes it. Use Winbar's Shut
Down. If Windows is still going after two minutes, Winbar asks whether to keep waiting (the
default), force it off or give up: Windows may be installing updates, which it doesn't show while
headless, and powering off then can damage it. If it's waiting on an app with unsaved work,
connect and deal with it, or use ⌥ Force Stop (a hard power-off, like pulling the plug).

**You edited the VM's `config.plist` by hand and the change vanished.** UTM keeps each VM's
configuration in memory and writes it back, overwriting edits made while it runs. Change settings
in UTM's own settings window, or with `winbar display` / `winbar setup`, which go through UTM.

**You need to see the VM's screen** (a boot menu, a BitLocker recovery prompt, a VM that won't
come up on the network): `winbar display on`, or **Show Console Window…** in the menu.

**Windows asks for a BitLocker recovery key.** Enter the key you saved. If you set Windows up with
a Microsoft account, the key is probably also at
[aka.ms/myrecoverykey](https://aka.ms/myrecoverykey).

**netplwiz has no "Users must enter a user name and password" checkbox.** Windows hides it while
*Settings > Accounts > Sign-in options > For improved security, only allow Windows Hello sign-in
for Microsoft accounts on this device* is on. Turn that off, then reopen netplwiz.

**Winbar can't reach Windows at all.** The UTM Guest Tools aren't installed or running. With the
VM in its UTM window, use the CD/DVD button in the toolbar to install the Windows Guest Tools,
then run the installer inside Windows.

**Winbar decided something and you can't see why.** `WINBAR_DEBUG=1` in front of any `winbar`
command prints the decisions it usually keeps quiet — which UTM processes it found, why it did or
didn't restart UTM — to standard error. It's the output to include in a bug report.

```sh
WINBAR_DEBUG=1 winbar doctor
```

**Harmless things that look wrong:**
- After your Mac sleeps, Windows reports a shorter uptime than expected. Its clock pauses while
  the VM is suspended; it didn't reboot.
- Device Manager lists a few dozen `ACPI\LNRO0005` devices with problems. They're unused
  virtual slots that Windows never needs.
- While you're connected, Windows shows only a "Microsoft Remote Display Adapter". That's normal
  over Remote Desktop.

## Problems and contributions

Something wrong, or missing? Open an issue at
[github.com/taggie313/winbar/issues](https://github.com/taggie313/winbar/issues). What makes a
report answerable:

- the file `winbar diagnose` writes (see [Troubleshooting](#troubleshooting)) — it has the doctor
  table, the versions, the settings, the last create log and UTM's crash reports in it
- the command that went wrong, run as `WINBAR_DEBUG=1 winbar …`
- what you expected, and what happened instead

Leave out anything you'd rather not publish: the report prints your VM's name, host name and
Windows user name, and a debug run can too. `winbar diagnose --anonymise` replaces those with
placeholders. Nothing prints a password.

Pull requests are welcome. For anything larger than a fix, open an issue first: Winbar's defaults
are argued for in [docs/RECIPE.md](docs/RECIPE.md), and changing one is easier to agree on before
the code than after. `swift test` should pass, and settings that cost time or CPU should come with
a measurement, the way the rest of the recipe does.

## Uninstall

1. If you want UTM's window back, run `winbar display on` **first**. (Otherwise add a Display
   device in the VM's settings in UTM later.)
2. Remove Winbar, its `winbar` command and its settings:

   ```sh
   brew uninstall --cask --zap winbar
   ```

   Installed from the disk image instead? Quit Winbar, drag **Winbar.app** from Applications to
   the Trash, and remove the four places Winbar keeps things:

   ```sh
   defaults delete net.elusive.winbar
   rm -rf ~/Library/Application\ Support/Winbar \
          ~/Library/Caches/net.elusive.winbar \
          ~/Library/HTTPStorages/net.elusive.winbar
   ```

   Application Support holds the VM's certificate file and `create`'s working folders (including,
   after an install that was interrupted rather than cancelled with `winbar create --cancel NAME`,
   the setup disk carrying the scrambled Windows password). Caches holds the 80 MB Guest Tools
   installer. HTTPStorages is what the once-a-day update check leaves behind, and `defaults
   delete` takes the settings. `brew uninstall --cask --zap winbar` removes exactly the same four.

   Your VM, UTM and Windows App are not touched.
3. Optional clean-up on the Mac:
   - **The certificate:** open Keychain Access > login > Certificates, find the one named after
     your VM (such as `mypc.local`) and delete it.
   - **Permissions:** `tccutil reset All net.elusive.winbar`
   - If Winbar still appears in *System Settings > General > Login Items*, remove it there.
4. Optional, to undo the changes inside Windows (in an administrator PowerShell unless noted):

   | Change | To undo |
   |---|---|
   | Power plan tweaks | `powercfg -restoredefaultschemes`, then `powercfg /hibernate on` if you want hibernation back |
   | Services | `Set-Service SysMain -StartupType Automatic`, the same for `WSearch` and `DiagTrack` (then `Start-Service` each) |
   | Visual effects | *Settings > Personalization > Colors > Transparency effects*, *Settings > Accessibility > Visual effects > Animation effects*, and *System > About > Advanced system settings > Performance > Let Windows choose* (as your user) |
   | Automatic sign-in | Run `netplwiz` and tick *Users must enter a user name and password* again |
   | Remote Desktop | *Settings > System > Remote Desktop*, off |
   | The certificate | Harmless to leave. To remove it: `certlm.msc` > Personal > Certificates |
   | BitLocker | *Control Panel > BitLocker Drive Encryption > Turn on BitLocker* (and save the new recovery key) |
   | Local account | *Settings > Accounts > Your info > Sign in with a Microsoft account instead* |

   vCPUs and memory stay as Winbar set them; change them in UTM's VM settings if you like.

## How it works

- **One program, two roles.** `Winbar.app` is the menu bar app, and the same executable is the
  `winbar` command (Homebrew links it). A separate lowercase `winbar` file can't sit next to
  `Winbar` because the Mac's disk ignores letter case by default.
- **Watching the VM** means reading the VM's own process list entry every few seconds. It needs no
  scripting, so the icon costs almost nothing to keep up to date.
- **Changing the VM's hardware** (vCPUs, memory, display) goes through UTM's AppleScript
  interface, with the VM shut down, so UTM applies the change itself.
- **Changing Windows** runs small PowerShell scripts inside the VM through the QEMU guest agent
  that the UTM Guest Tools install.
- **Saving a PC in Windows App** uses Windows App's own scripting command line, which runs without
  opening a window. It refuses while Windows App is running, because that command line writes the
  same database the running app has open.
- **Connecting** presses your saved PC's tile in Windows App through the Accessibility interface,
  because that's the only way Windows App uses a stored password — its command line can save a PC
  but has no way to open one.

Everything Winbar does, as steps you can follow yourself with the reasons and measurements behind
each one: [docs/RECIPE.md](docs/RECIPE.md).

## Build it yourself

One Swift package, no dependencies.

```sh
swift build                 # the executable, in .build/debug
swift test                  # the test suite: parsers, quoting, recommendations. Needs Xcode's
                            # toolchain, not just the Command Line Tools (Package.swift says why)
scripts/build-app.sh        # dist/Winbar.app, signed with your Developer ID if you have one
scripts/install-local.sh    # ...and put that build in ~/Applications and relaunch it
```

The tests touch nothing outside the process — no UTM, no VM, no keychain — so they're safe to run
anywhere. `scripts/release.sh VERSION --dry-run` does the whole release build, signing and disk
image without notarizing or publishing anything.

## License

[MIT](LICENSE) © 2026 Joshua Lutz.

The Windows settings `winbar create`'s answer file applies are the ones
[Rufus](https://github.com/pbatard/rufus) (GPL-3.0) applies, established by reading its `wue.c` —
the settings and their values, not Rufus's code, none of which is here.
[THIRD-PARTY.md](THIRD-PARTY.md) lists exactly which ones, along with the UTM Guest Tools
installer `create` downloads at run time (and doesn't redistribute) and the CLDR time zone table.

Winbar isn't affiliated with UTM or Microsoft. Windows and Windows App are trademarks of
Microsoft.
