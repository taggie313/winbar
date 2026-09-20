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
    /// The configured host, else `<DNS host name>.local` asked from the guest and remembered (with the
    /// signed-in user, if no user is configured either). nil if neither is possible.
    ///
    /// Waits up to `timeout` for the guest agent: right after a start Windows hasn't got that far,
    /// and one unanswered probe isn't a reason to give up.
    static func resolveHost(vm: String, timeout: TimeInterval) -> String? {
        if let host = Config.rdpHost { return host }
        guard VMProcesses.isRunning(vm), UTM.waitForGuestAgent(vm, timeout: timeout),
              case .success(let out) = GuestAgent.run(vm: vm, GuestScripts.identity(user: Config.rdpUser), timeout: 90),
              let host = out.defaultRDPHost, Config.isValidHostName(host)
        else { return nil }
        Config.rdpHost = host
        if Config.rdpUser == nil, let user = out["USER"], !user.isEmpty { Config.rdpUser = user }
        return host
    }

    /// The VM's MAC: from its running process, else cached.
    static func mac(vm: String) -> String? {
        VMProcesses.find(vm)?.mac ?? Config.vmMAC
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
