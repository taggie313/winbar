import AppKit

/// The tuning recipe, in order. Each check explains itself; the numbers come from `Tuning`.
enum Recipe {
    static let checks: [Check] = host + guest + client

    static func check(_ id: String) -> Check? { checks.first { $0.id == id } }

    // MARK: - Host

    static let host: [Check] = [
        Check(id: "H1", section: .host, title: "UTM installed",
              why: "Winbar drives UTM's own tools; it doesn't replace UTM.",
              evaluate: { _ in
                  guard UTM.isInstalled else { return .manual("UTM isn't installed", how: "brew install --cask utm") }
                  return .ok("UTM \(UTM.version ?? "(unknown version)")")
              }),

        Check(id: "H2", section: .host, title: "VM",
              why: "Everything else concerns one VM, chosen by its name in UTM.",
              evaluate: { ctx in
                  guard UTM.isInstalled else { return .info("needs UTM (H1)") }
                  let list: [VMInfo]
                  switch ctx.vms {
                  case .failure(let error) where error.automationDenied: return .manual(error.title, how: error.detail)
                  case .failure(let error): return .error("couldn't ask UTM for its VMs: \(error)")
                  case .success(let vms): list = vms
                  }
                  guard let name = ctx.vmName else {
                      let candidates = ctx.candidates
                      if candidates.count == 1 { return .fixable("none chosen; \(candidates[0].name) is the only Windows VM") }
                      if candidates.isEmpty { return .manual("UTM has no Windows VMs", how: "Create a Windows 11 ARM64 VM in UTM, then run winbar setup.") }
                      return .manual("none chosen", how: "winbar config --vm <name>   (UTM has: \(candidates.map(\.name).joined(separator: ", ")))")
                  }
                  guard let vm = list.first(where: { $0.name == name }) else {
                      let names = list.map(\.name).joined(separator: ", ")
                      return .manual("UTM has no VM named \(name)", how: "winbar config --vm <name>   (UTM has: \(names.isEmpty ? "none" : names))")
                  }
                  guard vm.backend == "qemu" else {
                      return .error("\(name) uses UTM's Apple Virtualization backend; Winbar manages QEMU VMs")
                  }
                  var detail = "\(name), \(vm.isRunning ? vm.status : "stopped")"
                  if !vm.architecture.isEmpty && vm.architecture != "aarch64" { detail += " (emulated \(vm.architecture): slow)" }
                  return .ok(detail)
              },
              apply: { ctx in
                  guard ctx.vmName == nil, ctx.candidates.count == 1 else { return .failure(WinbarError("No single VM to choose")) }
                  let name = ctx.candidates[0].name
                  Config.selectVM(name)
                  ctx.vmName = name
                  ctx.refreshAll()
                  return .success(())
              }),

        Check(id: "H3", section: .host, title: "vCPUs",
              why: "On an M5 Max (6 Super + 12 Performance cores) 6 vCPUs used the least host CPU for a fixed workload; "
                  + "8 cost 28% more with no speed gain; 4 was slower and no cheaper. The fastest core tier, clamped to 4–8, "
                  + "carries that over to other chips.",
              needsRestart: true,
              evaluate: { ctx in
                  guard let vm = ctx.vm else { return .info("needs a VM (H2)") }
                  let target = Tuning.recommendedCPUs(topTierCores: Host.topTierCores)
                  let configured = vm.cpuCores.flatMap { $0 > 0 ? $0 : nil }
                  guard let current = configured ?? ctx.process?.cpus else {
                      return .fixable("UTM's default; recommended \(target)")
                  }
                  return current == target ? .ok("\(current)") : .fixable("\(current); recommended \(target)")
              },
              apply: { ctx in
                  ctx.pending.cpuCores = Tuning.recommendedCPUs(topTierCores: Host.topTierCores)
                  return .success(())
              }),

        Check(id: "H4", section: .host, title: "RAM",
              why: "Room for Windows to keep a warm file cache without paging: 16 GB on a Mac with 64 GiB or more, "
                  + "12 GB from 32 GiB, else 8 GB, and never more than half the Mac's memory. A larger value you chose is left alone.",
              needsRestart: true,
              evaluate: { ctx in
                  guard let vm = ctx.vm else { return .info("needs a VM (H2)") }
                  let target = Tuning.recommendedMemoryMB(hostBytes: Host.memoryBytes)
                  guard let current = vm.memoryMB ?? ctx.process?.memoryMB else { return .info("unknown") }
                  if current == target { return .ok("\(current) MB") }
                  if current > target { return .ok("\(current) MB (more than the \(target) MB recommended; left alone)") }
                  return .fixable("\(current) MB; recommended \(target) MB")
              },
              apply: { ctx in
                  ctx.pending.memoryMB = Tuning.recommendedMemoryMB(hostBytes: Host.memoryBytes)
                  return .success(())
              }),

        Check(id: "H5", section: .host, title: "Display",
              why: "With no display device QEMU stops copying every frame on the CPU: idle host CPU fell about 90% in testing. "
                  + "Remote Desktop then becomes the only way in, so headless is only offered once the account has a password (G5), "
                  + "Remote Desktop is on (G6), its certificate is trusted (H7) and you've confirmed a connection worked. "
                  + "`winbar display on` brings the console back.",
              needsRestart: true,
              evaluate: { ctx in
                  guard let vm = ctx.vm else { return .info("needs a VM (H2)") }
                  guard let headless = vm.headless ?? ctx.process?.headless ?? Config.consoleEnabled.map({ !$0 }) else {
                      return .info("unknown")
                  }
                  if headless { return .ok("headless") }
                  // G5 too: an account Remote Desktop can't sign in (no password, a Microsoft account with
                  // only a PIN) would be locked out of a headless VM.
                  let ready = ctx.status(of: "G5")?.isManual != true
                      && ctx.status(of: "G6")?.isOK == true && ctx.status(of: "H7")?.isOK == true
                  return ready
                      ? .fixable("console window on; headless cuts idle host CPU by about 90%")
                      : .info("console window on; headless is offered once Remote Desktop works (G5, G6, H7)")
              },
              apply: { ctx in
                  ctx.pending.display = .headless
                  return .success(())
              }),

        Check(id: "H6", section: .host, title: "Backups and indexing",
              why: "The VM's disk image is tens of gigabytes and changes constantly; backing it up every hour and indexing it "
                  + "for Spotlight costs I/O for nothing. macOS protects UTM's folder, so Winbar can only check, not change, this.",
              evaluate: { _ in
                  let path = Tuning.utmDocuments.path
                  let how = "System Settings → General → Time Machine → Options… → + → add \(path) "
                      + "(⇧⌘. shows hidden folders). Do the same under Spotlight → Search Privacy. "
                      + "Winbar can only confirm the Time Machine part, and only if Terminal has Full Disk Access."
                  let destinations = Shell.run("/usr/bin/tmutil", ["destinationinfo"], timeout: 20)
                  if destinations.output.contains("No destinations configured") { return .ok("Time Machine isn't set up") }
                  let result = Shell.run("/usr/bin/tmutil", ["isexcluded", path], timeout: 20)
                  if result.status == 0 && result.text.contains("[Excluded]") { return .ok("excluded from Time Machine") }
                  if result.status == 0 && result.text.contains("[Included]") {
                      Config.backupExclusionConfirmed = false   // a real answer beats anyone's word
                      return .manual("Time Machine backs up UTM's VMs", how: how)
                  }
                  // Without Full Disk Access tmutil can't look, which is the usual case; the person's
                  // word is the only evidence there is, as with the saved PC (C2).
                  if Config.backupExclusionConfirmed { return .ok("excluded, confirmed by you (can't be checked without Full Disk Access)") }
                  return .manual("can't tell whether Time Machine backs up UTM's VMs (that needs Full Disk Access)", how: how)
              },
              guide: { _ in
                  if let url = URL(string: "x-apple.systempreferences:com.apple.Time-Machine-Settings.extension") {
                      NSWorkspace.shared.open(url)
                  }
              },
              recordDone: { _ in Config.backupExclusionConfirmed = true }),

        Check(id: "H7", section: .host, title: "RDP certificate trusted",
              why: "Windows App checks the listener's certificate. Trusting the one made for this host name (G7), for SSL only, "
                  + "removes the certificate prompt without trusting anything else.",
              evaluate: { ctx in
                  guard let out = ctx.guestOutput else { return .info("needs Windows (G0)") }
                  guard let host = ctx.rdpHost else { return .info("no RDP host yet") }
                  guard ctx.status(of: "G7")?.isOK == true else { return .info("needs a certificate for \(host) first (G7)") }
                  guard let encoded = out["G7_CERT"], let der = Data(base64Encoded: encoded) else {
                      return .info("Windows didn't report the listener certificate")
                  }
                  let (trusted, reason) = RDP.certificateTrusted(der: der, host: host)
                  return trusted ? .ok("trusted for \(host)") : .fixable("not trusted for \(host) (\(reason))")
              },
              apply: { ctx in
                  guard let host = ctx.rdpHost, let encoded = ctx.guestOutput?["G7_CERT"], let der = Data(base64Encoded: encoded) else {
                      return .failure(WinbarError("No certificate to trust yet"))
                  }
                  print("macOS will ask you to approve trusting it.")
                  return RDP.trustCertificate(der: der, host: host)
              }),

        Check(id: "H8", section: .host, title: "Network mode",
              why: "Winbar expects UTM's Shared network: the VM is reachable only from this Mac, and its address lease is where "
                  + "the readiness probe finds it. Bridged puts port 3389 on your whole network and hides the VM from the probe.",
              evaluate: { ctx in
                  guard let vm = ctx.vm else { return .info("needs a VM (H2)") }
                  switch vm.networkMode {
                  case "shared": return .ok("shared")
                  case "": return .info("unknown (no network interface reported)")
                  default:
                      return .manual("\(vm.networkMode)", how: "With the VM stopped, in UTM: select it → Edit → Network → Network Mode: Shared Network.")
                  }
              }),
    ]

    // MARK: - Guest

    static let guest: [Check] = [
        Check(id: "G0", section: .guest, title: "Windows edition",
              why: "Windows is checked and tuned through the QEMU guest agent, which comes with UTM Guest Tools. "
                  + "Home editions can't host Remote Desktop sessions at all.",
              evaluate: { ctx in
                  switch ctx.guest {
                  case .notConfigured:
                      return .info("needs a VM (H2)")
                  case .stopped:
                      return .manual("\(ctx.vmName ?? "the VM") is stopped, so Windows can't be checked",
                                     how: "winbar start, wait for Windows, then run this again.")
                  case .noAgent:
                      return .manual("the QEMU guest agent isn't answering",
                                     how: "Install UTM Guest Tools in Windows (in UTM, the VM's CD/DVD menu → Install Windows Guest Tools…), "
                                         + "then run this again. Just after boot the agent can take a minute to start.")
                  case .failed(let error):
                      return .error(error.description)
                  case .ready(let out):
                      let windows = out["WINDOWS"] ?? "Windows"
                      if Tuning.homeEditions.contains(out["EDITION"] ?? "") {
                          return .error("\(windows): Home can't host Remote Desktop sessions; it needs Windows 11 Pro")
                      }
                      return .ok(windows)
                  }
              }),

        Check(id: "G1", section: .guest, title: "Power plan",
              why: "Balanced with a fast ramp-up keeps Windows responsive, while core parking (which Ultimate Performance turns off) "
                  + "lets idle vCPUs, and with them host cores, sleep. A 5-minute monitor timeout stops desktop compositing. "
                  + "The VM has no virtual battery, so only AC values matter.",
              evaluate: { ctx in
                  guestStatus(ctx) { out in
                      if let error = out["G1_ERROR"] { return .error(error) }
                      var off: [String] = []
                      if out["G1_ACTIVE"]?.lowercased() != Tuning.balancedScheme { off.append("active plan isn't Balanced") }
                      for (setting, value) in Tuning.processor where out.int("G1_\(setting)") != value {
                          off.append("\(setting) \(out["G1_\(setting)"].flatMap { $0.isEmpty ? nil : $0 } ?? "?") (want \(value))")
                      }
                      let timeouts = [("monitor", "VIDEOIDLE", Tuning.monitorTimeoutMinutes),
                                      ("sleep", "STANDBYIDLE", Tuning.standbyTimeoutMinutes),
                                      ("disk", "DISKIDLE", Tuning.diskTimeoutMinutes)]
                      for (label, key, minutes) in timeouts where out.int("G1_\(key)") != minutes * 60 {
                          let seconds = out.int("G1_\(key)")
                          off.append("\(label) timeout \(seconds.map { "\($0 / 60) min" } ?? "?") (want \(minutes == 0 ? "never" : "\(minutes) min"))")
                      }
                      if out.int("G1_HIBERNATE") != 0 { off.append("hibernation on") }
                      return off.isEmpty ? .ok("Balanced, tuned") : .fixable(off.joined(separator: "; "))
                  }
              },
              apply: { ctx in applyInGuest(ctx, GuestScripts.applyPower()) }),

        Check(id: "G2", section: .guest, title: "Power button",
              why: "Windows hides this setting and resolves it to a sleep state the VM doesn't have, so UTM's power button "
                  + "does nothing useful. Shut down makes it a real off switch.",
              evaluate: { ctx in
                  guestStatus(ctx) { out in
                      if let error = out["G2_ERROR"] { return .error(error) }
                      let schemes = out.all("G2_SCHEME")
                      guard !schemes.isEmpty else { return .error("Windows reported no power schemes") }
                      let want = String(Tuning.powerButtonShutDown)
                      let wrong = schemes.filter { entry in
                          let parts = entry.split(separator: ":").map(String.init)
                          return parts.count != 3 || parts[1] != want || parts[2] != want
                      }
                      return wrong.isEmpty
                          ? .ok("shut down, on all \(schemes.count) power schemes")
                          : .fixable("not shut down on \(wrong.count) of \(schemes.count) power schemes")
                  }
              },
              apply: { ctx in applyInGuest(ctx, GuestScripts.applyPowerButton()) }),

        Check(id: "G3", section: .guest, title: "Background services",
              why: "SysMain, Windows Search and DiagTrack make constant background CPU and disk work that buys nothing in a VM.",
              evaluate: { ctx in
                  guestStatus(ctx) { out in
                      if let error = out["G3_ERROR"] { return .error(error) }
                      let wrong = out.all("G3_SERVICE").compactMap { entry -> String? in
                          let p = entry.split(separator: ":").map(String.init)
                          guard p.count == 3, p[1] != "Missing", !(p[1] == "Stopped" && p[2] == "Disabled") else { return nil }
                          return "\(p[0]) \(p[1].lowercased()), \(p[2].lowercased())"
                      }
                      return wrong.isEmpty ? .ok("SysMain, WSearch, DiagTrack disabled") : .fixable(wrong.joined(separator: "; "))
                  }
              },
              apply: { ctx in applyInGuest(ctx, GuestScripts.applyServices()) }),

        Check(id: "G4", section: .guest, title: "Visual effects",
              why: "Transparency, animations and shadows are expensive on an unaccelerated framebuffer. "
                  + "They're per-user settings and take full effect at the next sign-in.",
              evaluate: { ctx in
                  guestStatus(ctx) { out in
                      if let error = out["G4_ERROR"] { return .error(error) }
                      let skipped = Status.info("left alone (--no-visual-tweaks; winbar config --no-visual-tweaks no undoes it)")
                      guard out.bool("G4_HIVE") == true else {
                          if ctx.noVisualTweaks { return skipped }
                          let user = out["USER"] ?? ""
                          return user.isEmpty
                              ? .manual("nobody is signed in to Windows", how: "Sign in once (console window or Remote Desktop), then run this again.")
                              : .manual("\(user) isn't signed in, so their settings can't be read",
                                        how: "Sign in as \(user) (console window or Remote Desktop), then run this again.")
                      }
                      let wrong = Tuning.visualEffects.filter { out["G4_\($0.name)"] != $0.value }.map(\.name)
                      if wrong.isEmpty { return .ok("reduced") }
                      if ctx.noVisualTweaks { return skipped }
                      return .fixable("\(wrong.count) of \(Tuning.visualEffects.count) differ: \(wrong.joined(separator: ", "))")
                  }
              },
              apply: { ctx in applyInGuest(ctx, GuestScripts.applyVisualEffects(user: Config.rdpUser)) }),

        Check(id: "G5", section: .guest, title: "Account and password",
              why: "Remote Desktop needs a real password. A Windows Hello PIN never works over it, and Windows can't give a "
                  + "Microsoft account a local password (Set-LocalUser reports success and changes nothing).",
              evaluate: { ctx in
                  guestStatus(ctx) { out in
                      if let error = out["G5_ERROR"] { return .error(error) }
                      guard let user = out["USER"], !user.isEmpty else {
                          return .manual("nobody is signed in to Windows", how: "Sign in once (console window), then run this again.")
                      }
                      switch out["G5_SOURCE"] ?? "" {
                      case "MicrosoftAccount":
                          return .manual("\(user) is a Microsoft account",
                                         how: "Convert it to a local account: Settings → Accounts → Your info → “Sign in with a local "
                                             + "account instead” (you'll need your PIN), and give it a password. Setup opens that page in Windows.")
                      case "Local":
                          break
                      case "NotLocal", "":
                          return .info("\(user) isn't a local account, so its password can't be checked")
                      case let other:
                          return .info("\(user) is a \(other) account, so its password can't be checked")
                      }
                      switch out["G5_LOGON"] ?? "" {
                      case "1326": return .ok("\(user), local, with a password")
                      case "skipped": return .ok("\(user), local, with a password (checked before)")
                      case "deferred":
                          // Checking means one failed sign-in, and some are already counting towards lockout.
                          return .info("\(user), local; password not checked now: recent failed sign-ins")
                      case "ok", "1327":
                          // 1327 is ERROR_ACCOUNT_RESTRICTION: the password is blank and policy refuses it.
                          return .manual("\(user) has no password",
                                         how: "Remote Desktop needs one. Set it in Settings → Accounts → Sign-in options → Password. "
                                             + "Setup opens that page in Windows.")
                      case let code:
                          return .info("\(user), local; couldn't check the password (LogonUser error \(code.isEmpty ? "?" : code))")
                      }
                  }
              },
              guide: { ctx in
                  let page = ctx.guestOutput?["G5_SOURCE"] == "MicrosoftAccount" ? "ms-settings:yourinfo" : "ms-settings:signinoptions"
                  openOnWindowsDesktop(ctx, executable: "explorer.exe", arguments: page, elevated: false)
              }),

        Check(id: "G6", section: .guest, title: "Remote Desktop",
              why: "Remote Desktop on, with Network Level Authentication, TLS, and blank-password network logons refused: "
                  + "the secure defaults, which a real password (G5) makes painless.",
              evaluate: { ctx in
                  guestStatus(ctx) { out in
                      if Tuning.homeEditions.contains(out["EDITION"] ?? "") { return .error("Windows Home can't host Remote Desktop (G0)") }
                      if let error = out["G6_ERROR"] { return .error(error) }
                      var off: [String] = []
                      if out.int("G6_DENY") != 0 { off.append("Remote Desktop is off") }
                      if out.int("G6_NLA") != 1 { off.append("Network Level Authentication is off") }
                      if out.int("G6_SECURITY_LAYER") != 2 { off.append("TLS isn't required") }
                      if out.int("G6_LIMIT_BLANK") != 1 { off.append("blank-password network logons are allowed") }
                      if (out.int("G6_RULES") ?? 0) == 0 || (out.int("G6_RULES_OFF") ?? 1) > 0 { off.append("firewall rules not all enabled") }
                      if off.isEmpty { return .ok(out.bool("G6_LISTENING") == true ? "on, listening on 3389" : "on") }
                      // NLA and LimitBlankPasswordUse refuse a blank password over Remote Desktop no matter
                      // what, so applying them now would lock this account out, and on a headless VM that's
                      // the only way in. The fix waits for G5.
                      if blankPassword(out) {
                          let user = out["USER"].flatMap { $0.isEmpty ? nil : $0 } ?? "the account"
                          return .manual("waiting for a password (G5): \(user) has none, and Network Level Authentication "
                                             + "would lock \(user) out of Remote Desktop",
                                         how: "Give \(user) a password first (G5); setup then turns Remote Desktop on "
                                             + "(still to do: \(off.joined(separator: "; "))).")
                      }
                      return .fixable(off.joined(separator: "; "))
                  }
              },
              apply: { ctx in
                  if let out = ctx.guestOutput, blankPassword(out) {
                      return .failure(WinbarError("\(out["USER"] ?? "The account") has no password",
                                                  "Remote Desktop's protections would lock it out. Set a password first (G5)."))
                  }
                  return applyInGuest(ctx, GuestScripts.applyRemoteDesktop())
              }),

        Check(id: "G7", section: .guest, title: "RDP certificate",
              why: "Windows' own listener certificate is named after the computer, not the name the Mac connects to, so no "
                  + "trust setting can make it pass. A certificate made for that name can be trusted once (H7) and never prompts again.",
              evaluate: { ctx in
                  guestStatus(ctx) { out in
                      if let error = out["G7_ERROR"] { return .error(error) }
                      guard let host = ctx.rdpHost else { return .info("no RDP host yet (winbar config --host)") }
                      guard out["G7_STORE"] == "My" else { return .fixable("the listener uses Windows' generated certificate, not one for \(host)") }
                      let names = (out["G7_NAMES"] ?? "").split(separator: ",").map { $0.lowercased() }
                      let days = out.int("G7_DAYS_LEFT") ?? 0
                      var off: [String] = []
                      if !names.contains(host.lowercased()) { off.append("made for \(names.isEmpty ? "no names" : names.joined(separator: ", ")), not \(host)") }
                      if days <= Tuning.certificateMinimumDays { off.append("expires in \(days) days") }
                      if out.bool("G7_HAS_KEY") != true { off.append("no private key") }
                      return off.isEmpty ? .ok("for \(host), \(days) days left") : .fixable(off.joined(separator: "; "))
                  }
              },
              apply: { ctx in
                  guard let host = ctx.rdpHost, Config.isValidHostName(host) else {
                      return .failure(WinbarError("No valid RDP host name", "Set one with winbar config --host <name>."))
                  }
                  let mac = ctx.vm?.mac ?? ctx.process?.mac ?? Config.vmMAC
                  return applyInGuest(ctx, GuestScripts.applyCertificate(host: host, ip: RDP.leasedIP(mac: mac)))
              }),

        Check(id: "G8", section: .guest, title: "Sign in at boot",
              why: "With Windows signed in from boot, Remote Desktop reconnects to a session that's already running, apps and all. "
                  + "netplwiz keeps the password as an LSA secret, never in plain text.",
              evaluate: { ctx in
                  guestStatus(ctx) { out in
                      if let error = out["G8_ERROR"] { return .error(error) }
                      guard let user = out["USER"], !user.isEmpty else {
                          return .manual("nobody is signed in to Windows", how: "Sign in once (console window), then run this again.")
                      }
                      let autoOn = out["G8_AUTO"] == "1" && out["G8_AUTO_KIND"] == "String"
                      let autoUser = (out["G8_USER"] ?? "").split(separator: "\\").last.map(String.init) ?? ""
                      if autoOn && autoUser.caseInsensitiveCompare(user) == .orderedSame {
                          return .ok("signs in as \(user)" + (out.bool("G8_PLAINTEXT") == true ? " (but a plaintext DefaultPassword is in the registry)" : ""))
                      }
                      if out.int("G8_PASSWORDLESS") == 2 {
                          return .fixable("doesn't sign in by itself, and Hello-only sign-in hides the netplwiz setting that turns it on")
                      }
                      let now = autoOn && !autoUser.isEmpty ? "signs in as \(autoUser), not \(user)" : "doesn't sign \(user) in at boot"
                      return .manual(now, how: "In the netplwiz window setup opens in Windows, untick “Users must enter a user name and "
                                         + "password to use this computer”, press OK, and type \(user)'s password.")
                  }
              },
              apply: { ctx in applyInGuest(ctx, GuestScripts.allowPasswordSignIn()) },
              guide: { ctx in openOnWindowsDesktop(ctx, executable: "netplwiz.exe", arguments: "", elevated: true) }),

        Check(id: "G9", section: .guest, title: "BitLocker",
              why: "When the VM's disk image sits on an encrypted volume (FileVault, on the startup disk), BitLocker only adds CPU "
                  + "on every I/O, and any VM hardware change (display, vCPUs, RAM) demands the recovery key unless protection is "
                  + "suspended first.",
              evaluate: { ctx in
                  guestStatus(ctx) { out in
                      if let error = out["G9_ERROR"] { return .error(error) }
                      guard let state = BitLockerState(out) else { return .info("unknown") }
                      if state.decrypted { return .ok(state.volumeStatus == "Unavailable" ? "not available in this edition" : "C: isn't encrypted") }
                      if state.decrypting { return .info("decrypting C: (\(state.percent.map { "\($0)%" } ?? "?") still encrypted)") }
                      if ctx.keepBitLocker { return .info("kept on (--keep-bitlocker; winbar config --keep-bitlocker no undoes it)") }
                      return .fixable("C: is encrypted" + (state.protected ? "" : ", protection suspended"))
                  }
              },
              apply: { ctx in
                  guard let vm = ctx.vmName else { return .failure(WinbarError("No VM chosen")) }
                  return BitLocker.startDecrypting(vm: vm).map { _ in () }
              }),

        Check(id: "G10", section: .guest, title: "Drivers and tools",
              why: "For reference.",
              evaluate: { ctx in
                  guestStatus(ctx) { out in
                      var parts = [out["G10_NET"].map { "network: \($0)" } ?? "no VirtIO network adapter"]
                      if let tools = out["G10_TOOLS"] { parts.append("UTM Guest Tools \(tools)") }
                      if let agent = out["G10_AGENT"] { parts.append("guest agent \(agent)") }
                      return .info(parts.joined(separator: "; "))
                  }
              }),

        Check(id: "G11", section: .guest, title: "Shared folder",
              why: "A folder both sides can open, so files don't have to go through Remote Desktop's clipboard or a network "
                  + "share. UTM carries it over the SPICE channel the Guest Tools already use, and hands it to Windows only "
                  + "when it was set while the VM was off. Nobody needs one: this is a convenience, not part of the recipe.",
              evaluate: { ctx in
                  guard ctx.vmName != nil, ctx.vm != nil else { return .info("needs a VM (H2)") }
                  let folder: String?
                  switch ctx.sharedFolder {
                  case .failure(let error) where error.automationDenied: return .manual(error.title, how: error.detail)
                  case .failure(let error): return .info("couldn't ask UTM which folder it shares: \(error.title)")
                  case .success(let path): folder = path
                  }
                  return sharedFolderStatus(folder: folder, guest: ctx.guestOutput.map(SharedFolder.guestView),
                                            running: ctx.process != nil, token: ctx.sharedFolderMarker)
              },
              apply: { ctx in
                  guard let vm = ctx.vmName else { return .failure(WinbarError("No VM chosen")) }
                  let view = ctx.guestOutput.map(SharedFolder.guestView)
                  return SharedFolder.mapDrive(vm: vm, user: Config.rdpUser,
                                               drive: view?.drive ?? SharedFolder.defaultDrive,
                                               remotePath: view?.remotePath ?? SharedFolder.defaultRemotePath)
              }),
    ]

    // MARK: - Client

    static let client: [Check] = [
        Check(id: "C1", section: .client, title: "Windows App",
              why: "Microsoft's Remote Desktop client for the Mac, which Connect opens.",
              evaluate: { _ in
                  guard WindowsApp.appURL != nil else { return .manual("not installed", how: "brew install --cask windows-app") }
                  return .ok("Windows App \(WindowsApp.version ?? "")".trimmingCharacters(in: .whitespaces))
              }),

        Check(id: "C2", section: .client, title: "Saved PC",
              why: "Only a saved PC uses Windows App's stored password; a one-off connection asks every time. Winbar still "
                  + "can't read Windows App's files, but it can ask the app itself, on its own command line — which is also "
                  + "how it can save the PC for you instead of leaving it to you.",
              evaluate: { ctx in
                  guard let host = ctx.rdpHost else { return .info("needs the RDP host name (G0)") }
                  guard WindowsApp.appURL != nil else { return .info("needs Windows App (C1)") }
                  switch ctx.savedPC(for: host) {
                  case .success(let found?):
                      Recipe.rememberSavedPC(found, host: host)
                      return .ok(found.name.caseInsensitiveCompare(host) == .orderedSame ? host : "\(found.name) (\(host))")
                  case .success(nil):
                      // Windows App answered, and it hasn't got one. Winbar can write it, unless the
                      // app is open — two writers on its database is the one risk not worth taking.
                      guard WindowsAppBookmarks.appIsRunning else {
                          return .fixable("none for \(host); setup can save it for you")
                      }
                      return .manual("none for \(host), and Windows App is open",
                                     how: WindowsAppBookmarks.Copy.quitFirst + " Then run winbar setup again and it will "
                                         + "offer to save it. Or do it yourself: "
                                         + WindowsAppBookmarks.Copy.byHand(host: host, user: ctx.rdpUser))
                  case .failure(let failure):
                      // Windows App wouldn't say. Fall back to what 0.1.0 had: the person's word.
                      if Config.savedPCHost?.caseInsensitiveCompare(host) == .orderedSame {
                          return .ok("\(Config.savedPCName ?? host) (your word; Windows App didn't answer)")
                      }
                      return .manual("couldn't ask Windows App whether there's one for \(host) (\(failure))",
                                     how: WindowsAppBookmarks.Copy.byHand(host: host, user: ctx.rdpUser))
                  }
              },
              guide: { _ in
                  if let url = WindowsApp.appURL { NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) }
              },
              recordDone: { ctx in
                  guard let host = ctx.rdpHost else { return }
                  // Ask Windows App itself: it knows what the person called the PC, and the tile is
                  // matched on that name. Only when it won't say does Winbar fall back to asking.
                  if let found = try? WindowsAppBookmarks.savedPC(for: host) {
                      Recipe.rememberSavedPC(found, host: host)
                      return
                  }
                  if Term.stdinIsTTY {
                      print("What is the saved PC called in Windows App? [\(Config.savedPCName ?? host)] ", terminator: "")
                      fflush(stdout)
                      if let answer = readLine()?.trimmingCharacters(in: .whitespaces), !answer.isEmpty {
                          Config.savedPCName = answer.caseInsensitiveCompare(host) == .orderedSame ? nil : answer
                      }
                  }
                  Config.savedPCHost = host
              }),

        Check(id: "C3", section: .client, title: "Accessibility",
              why: "Connect presses the saved PC's tile in Windows App through the Accessibility API, which is what avoids the "
                  + "password prompt and the chooser window. Checked by launching Winbar itself: a shell's answer is Terminal's.",
              evaluate: { ctx in
                  switch ctx.selfTest {
                  case .failure(let error): return .info(error.title)
                  case .success(let values):
                      if values["accessibility"] == "true" { return .ok("granted to Winbar") }
                      return .manual("not granted to Winbar",
                                     how: "System Settings → Privacy & Security → Accessibility → turn on Winbar. If it's already on "
                                         + "and this still says no: tccutil reset Accessibility net.elusive.winbar, then run setup again.")
                  }
              },
              guide: { _ in
                  // Asking from the app itself adds Winbar to the list and shows the system prompt.
                  _ = SelfTest.launchAsApp(extraArguments: ["--request-accessibility"])
                  WindowsApp.openAccessibilitySettings()
              }),

        Check(id: "C4", section: .client, title: "Launch at login",
              why: "Keeps the menu bar icon there after a restart.",
              evaluate: { ctx in
                  switch ctx.selfTest {
                  case .failure(let error): return .info(error.title)
                  case .success(let values):
                      return values["login item"] == "enabled" ? .ok("on") : .info("off; turn it on from the menu: Launch at Login")
                  }
              }),
    ]

    // MARK: - Helpers

    /// The survey found a local account that signs in with an empty password: LogonUser accepted
    /// '' (ok) or refused it only by policy (1327, ERROR_ACCOUNT_RESTRICTION).
    static func blankPassword(_ out: GuestOutput) -> Bool {
        out["G5_SOURCE"] == "Local" && ["ok", "1327"].contains(out["G5_LOGON"] ?? "")
    }

    /// G11's row, from the three facts it needs: the folder UTM shares (nil = none), what Windows
    /// reported (nil when it wasn't asked), and whether the VM is running. Pure, so every state can
    /// be checked without a VM.
    ///
    /// Sharing nothing is informational, never a failure: most people never want a shared folder, and
    /// doctor must still exit 0 for them.
    static func sharedFolderStatus(folder: String?, guest: SharedFolder.GuestView?, running: Bool,
                                   token: String? = nil) -> Status {
        guard let folder else {
            return .info("nothing shared (winbar share <folder> sets one up)")
        }
        // A space in the path makes a drive Windows can read nothing from, so say that first: every
        // other answer below would be a symptom of it.
        if let refusal = SharedFolder.refusal(folder) {
            return .manual(refusal.title, how: refusal.detail + " Then: winbar share <folder>")
        }
        let name = SharedFolder.abbreviate(folder)
        // An empty view means the survey's shared-folder section didn't run (no survey at all, or an
        // older one): the folder is set, Windows just hasn't been asked.
        guard let guest, !guest.webdavd.isEmpty else {
            return running ? .ok("\(name) (Windows didn't say how it sees it; G0)")
                           : .ok("\(name); Windows sees it as a drive once the VM is running")
        }
        if guest.seesPlaceholder {
            return .manual("\(name) is set, but Windows is still showing UTM's placeholder",
                           how: "Windows is given the folder UTM held at the start before this one, so a change needs a "
                               + "second start. Restart the VM (winbar restart, or Restart in the menu); winbar share "
                               + "checks from inside Windows and says when it has really arrived.")
        }
        if !guest.webdavdRunning {
            return .manual("\(name) is shared, but Windows' spice-webdavd isn't running (\(guest.webdavd))",
                           how: "It comes with UTM Guest Tools: in UTM, the VM's CD/DVD menu → Install Windows Guest Tools…, "
                               + "then run this again.")
        }
        if !guest.webClientRunning {
            return .manual("\(name) is shared, but Windows' WebClient service isn't running (\(guest.webClient))",
                           how: "In Windows: Services → WebClient → Startup type Automatic, then Start. WebDAV drives need it.")
        }
        guard let drive = guest.drive else {
            return .fixable("\(name) is shared, but no drive is mapped in Windows")
        }
        // The folder is mounted — but is it this one? UTM gives Windows the folder its registry held
        // at the previous start, so the marker the survey left is the only thing that can say.
        if let token, guest.marker != token {
            return .manual("\(name) is set, but Windows is still serving the folder it had before",
                           how: "Windows is given the folder UTM held at the start before this one, so a change needs a "
                               + "second start. Restart the VM (winbar restart, or Restart in the menu); winbar share "
                               + "checks from inside Windows and says when it has really arrived.")
        }
        // A probe that couldn't read the share is worth saying, but it isn't a failure: the guest
        // agent runs as SYSTEM, which doesn't always get to walk another session's WebDAV mount.
        let unconfirmed = guest.reachable == false ? " (Windows didn't manage to read it from the guest agent)" : ""
        return .ok("\(name) ↔ \(drive) in Windows\(unconfirmed)")
    }

    /// Guest checks read the survey; without one they defer to G0, which says why.
    static func guestStatus(_ ctx: Context, _ body: (GuestOutput) -> Status) -> Status {
        guard let out = ctx.guestOutput else { return .info("not checked (G0)") }
        return body(out)
    }

    static func applyInGuest(_ ctx: Context, _ script: GuestScript) -> Result<Void, WinbarError> {
        guard let vm = ctx.vmName else { return .failure(WinbarError("No VM chosen")) }
        return GuestAgent.run(vm: vm, script, timeout: 180).flatMap { out in
            if let error = out.error { return .failure(WinbarError("Windows reported an error", error)) }
            return .success(())
        }
    }

    static func openOnWindowsDesktop(_ ctx: Context, executable: String, arguments: String, elevated: Bool) {
        guard let vm = ctx.vmName else { return }
        let script = GuestScripts.openOnDesktop(user: Config.rdpUser, executable: executable, arguments: arguments, elevated: elevated)
        switch GuestAgent.run(vm: vm, script, timeout: 90) {
        case .failure(let error):
            Term.error("Couldn't open it in Windows: \(error)")
        case .success(let out):
            if let error = out.error { Term.error("Couldn't open it in Windows: \(error)") }
            else { print("Opened in Windows for \(out["OPENED"] ?? "the signed-in user"). Look at the VM's window or Remote Desktop session.") }
        }
    }

    /// What Connect needs remembered about a saved PC: the host it stands for, and its name when
    /// that isn't the host. A tile's accessibility description is the friendly name when the PC has
    /// one, so `WindowsApp.tileNames` needs both. nil for both when Windows App answered and hasn't
    /// got one — the word Winbar was given in an earlier run is then stale and goes. Pure.
    static func savedPCSettings(_ bookmark: WindowsAppBookmarks.Bookmark?,
                                host: String) -> (host: String?, name: String?) {
        guard let bookmark else { return (nil, nil) }
        return (host, bookmark.name.caseInsensitiveCompare(host) == .orderedSame ? nil : bookmark.name)
    }

    static func rememberSavedPC(_ bookmark: WindowsAppBookmarks.Bookmark?, host: String) {
        let settings = savedPCSettings(bookmark, host: host)
        Config.savedPCHost = settings.host
        Config.savedPCName = settings.name
    }
}
