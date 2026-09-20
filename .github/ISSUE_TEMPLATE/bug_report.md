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

Read it first: it names your VM, this Mac and your user names. `winbar diagnose --anonymise`
replaces those with placeholders, and `--no-logs` leaves the create logs out. Neither ever contains
a password.

If you'd rather paste than attach, `winbar doctor` alone is the next best thing:

<details>

```
paste the output here
```

</details>

**The command that went wrong, run with debug output on**

`WINBAR_DEBUG=1 winbar <the command>` prints the decisions Winbar usually keeps quiet, to standard
error.

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
its host name and your Windows user name; edit out anything you'd rather not publish, or run
`winbar diagnose --anonymise`. None of them prints a password.
