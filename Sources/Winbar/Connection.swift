import Foundation

extension GuestOutput {
    /// `<name>.local`, where the name is what Windows answers mDNS for: its DNS host name. The
    /// NetBIOS COMPUTERNAME is only the fallback, because Windows cuts it to 15 characters and a
    /// longer name then never resolves.
    var defaultRDPHost: String? {
        let name = [self["DNSHOST"], self["COMPUTERNAME"]].compactMap { $0?.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        return name.map { $0.lowercased() + ".local" }
    }
}

/// What Connect needs, shared by the menu and `winbar connect`. All blocking.
enum Connection {
    /// The menu's Connect when Windows App couldn't be opened. It names the menu's own route first
    /// while the menu has one (`SetupWindow.availableToEveryone`): the person reading it clicked a
    /// menu, and may never have opened Terminal. `winbar setup` stays named, as the other route.
    static var menuFailureDetail: String { menuFailureDetail(setUpInMenu: SetupWindow.availableToEveryone) }
    static func menuFailureDetail(setUpInMenu: Bool) -> String {
        setUpInMenu
            ? "\(SetupCopy.menuItem) in Winbar's menu walks you through installing Windows App (so does winbar setup "
                + "in Terminal), or get it from the Mac App Store. Then try Connect again."
            : "Run winbar setup in Terminal and it offers to install Windows App for you, or get it from the Mac App "
                + "Store. Then try Connect again."
    }
    /// Shared by the menu and setup. Call off-main; Windows App's tile search is blocking.
    /// Returning means a connection was opened, not that Windows accepted the sign-in.
    @discardableResult
    static func openDesktop(host: String, user: String?,
                            failureDetail: String = "Install Windows App from the Mac App Store, then try Connect again.",
                            fallback: () -> Void = {},
                            accessibility: () -> Bool = { WindowsApp.accessibilityTrusted },
                            saved: (String) -> Bool = WindowsApp.openSavedPC,
                            oneOff: (String, String?) -> Bool = RDP.openOneOff) throws -> Bool {
        if accessibility() {
            if saved(host) { return true }
            fallback()
        }
        guard oneOff(host, user) else {
            throw WinbarError("Couldn't open Windows App", failureDetail)
        }
        return false
    }
    /// The configured host, else `<DNS host name>.local` asked from the guest and remembered (with the
    /// signed-in user, if no user is configured either). nil if neither is possible.
    ///
    /// Waits up to `timeout` for the guest agent: right after a start Windows hasn't got that far,
    /// and one unanswered probe isn't a reason to give up.
    ///
    /// The settings are read and written only for the VM Winbar looks after. Another VM's host and
    /// user describe a different Windows, and a host asked of it must not be filed under this one.
    static func resolveHost(vm: String, timeout: TimeInterval) -> String? {
        let ours = vm == Config.vmName
        if ours, let host = Config.rdpHost { return host }
        guard VMProcesses.isRunning(vm), UTM.waitForGuestAgent(vm, timeout: timeout),
              case .success(let out) = GuestAgent.run(vm: vm, GuestScripts.identity(user: ours ? Config.rdpUser : nil), timeout: 90),
              let host = out.defaultRDPHost, Config.isValidHostName(host)
        else { return nil }
        guard ours else { return host }
        Config.rdpHost = host
        if Config.rdpUser == nil, let user = out["USER"], !user.isEmpty { Config.rdpUser = user }
        return host
    }

    /// The VM's MAC: from its running process, else what was remembered for it — and nothing at all
    /// for a VM Winbar doesn't look after.
    ///
    /// Never another VM's. The MAC is how the DHCP lease, and so the address Winbar probes and
    /// connects to, is found: standing in with VM B's MAC for a stopped VM A points readiness, the
    /// certificate and Connect itself at the wrong machine.
    static func mac(vm: String) -> String? {
        if let running = VMProcesses.find(vm)?.mac { return running }
        return vm == Config.vmName ? Config.vmMAC : nil
    }

    /// Waits until the RDP port answers (or macOS blocks the probe, which proves nothing either way,
    /// so it doesn't hold Connect up). `cancelled` ends the wait early, answering `.notReady`.
    static func waitForRemoteDesktop(vm: String, timeout: TimeInterval, cancelled: () -> Bool = { false }) -> RDP.Readiness {
        var last = RDP.Readiness.notReady
        waitUntil(timeout: timeout, every: 3) {
            if cancelled() { last = .notReady; return true }
            guard VMProcesses.isRunning(vm) else { return false }
            last = RDP.probeNow(mac: mac(vm: vm))
            return last != .notReady
        }
        return last
    }
}
