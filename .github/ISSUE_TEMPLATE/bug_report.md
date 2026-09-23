---
name: Bug report
about: Something Winbar did wrong, or didn't do
title: ''
labels: ''
assignees: ''
---

**What happened, and what you expected instead**



**The diagnostic report**

Run `winbar diagnose` and attach the file it writes to your Desktop (drag it into this box). It has
the `winbar doctor` table, the versions involved, Winbar's settings, the tail of the last
`winbar create` log and UTM's recent crash reports in it — which is everything below, in one file,
so you don't have to collect it yourself. It works even when nothing else does.

Never opened Terminal? Choose **Report a Problem…** from the Winbar menu instead. It writes the same
file, shows it to you in the Finder and opens this page, so you can drag it in.

Read it first. It names this Mac, your Mac user name and full name, your Windows user name and the
Windows PC name, and each of your VMs — by name, by the id UTM gave it and by its MAC address.
`winbar diagnose --anonymise` — or the checkbox in **Report a Problem…** — writes the same report
with every one of those replaced by a placeholder (`<mac>`, `<user>`, `<user-full-name>`,
`<windows-user-1>`, `<windows-pc-1>`, `<vm-1>`, `<vm-1-id>`, `<vm-1-mac>`), and any other id- or
MAC-shaped string as `<id-1>` or `<mac-address-1>`. `--no-logs` leaves the create logs out. Neither
ever contains a password.

If you'd rather paste than attach, `winbar doctor` alone is the next best thing:

<details>

```
paste the output here
```

</details>

**The command that went wrong, run with debug output on**

`WINBAR_DEBUG=1 winbar <the command>` prints the decisions Winbar usually keeps quiet, to standard
error. There is no `--anonymise` for it: among the decisions it prints is what `utmctl list`
answered, which is the id UTM gave every VM on this Mac, and their names. Read it before you paste
it, and edit out anything you'd rather not publish.

<details>

```
paste the output here
```

</details>

**Your setup** (all of this is in the diagnostic report — only fill it in if you didn't attach one)

- Winbar version (`winbar --version`):
- macOS version and Mac model (*Apple menu > About This Mac*):
- UTM version, and how you installed it (Homebrew, App Store, direct download):
- Windows edition and build (`winver` inside Windows), if the problem is in the VM:
- Did the VM come from `winbar create`, or did you make it yourself?

**Anything else**

Screenshots, the VM's UTM settings, what you had already tried.

---

Issues are public. The diagnostic report, `winbar doctor` and a debug run all print your VM's name,
its host name and your Windows user name. The id UTM gave the VM is in two of the three: the
report's settings section, and a debug run, which logs what `utmctl list` said — a line of
`<uuid> <status> <name>` for every VM you have. Its MAC address is in the report only.
`winbar diagnose --anonymise` replaces all of those in the report; `winbar doctor` and a debug run
have no such flag, so edit those two yourself before pasting them above. None of them prints a
password.
