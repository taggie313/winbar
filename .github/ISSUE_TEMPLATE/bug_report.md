---
name: Bug report
about: Something Winbar did wrong, or didn't do
title: ''
labels: ''
assignees: ''
---

**What happened, and what you expected instead**



**`winbar doctor`**

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

**Your setup**

- Winbar version (`winbar --version`):
- macOS version and Mac model (*Apple menu > About This Mac*):
- UTM version, and how you installed it (Homebrew, App Store, direct download):
- Windows edition and build (`winver` inside Windows), if the problem is in the VM:
- Did the VM come from `winbar create`, or did you make it yourself?

**Anything else**

Screenshots, the VM's UTM settings, what you had already tried.

---

Issues are public. `winbar doctor` and a debug run print your VM's name, its host name and your
Windows user name; edit out anything you'd rather not publish. Neither prints a password.
