import AppKit
import Darwin
import Security

enum RDP {
    enum Readiness: String { case ready, notReady, blocked }

    // MARK: Where the VM is

    /// The VM's current IPv4 address from macOS's vmnet DHCP lease file, matched on its MAC.
    ///
    /// Resolving `<name>.local` from inside the app stalls (multicast mDNS), but the lease file is
    /// world-readable and follows the address if it ever changes.
    static func leasedIP(mac: String?) -> String? {
        guard let mac, let leases = try? String(contentsOfFile: "/var/db/dhcpd_leases", encoding: .utf8) else { return nil }
        return parseLeases(leases, mac: mac)
    }

    /// The newest lease for `mac`. Octets are compared as numbers because the lease file drops leading
    /// zeros (`1:2:3:a:b:c`).
    static func parseLeases(_ text: String, mac: String) -> String? {
        let wanted = macOctets(mac)
        guard wanted.count == 6 else { return nil }
        var best: (ip: String, expiry: UInt64)?
        for block in text.components(separatedBy: "}") {
            var ip: String?, octets: [Int]?, expiry: UInt64 = 0
            for line in block.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }) {
                if line.hasPrefix("ip_address=") { ip = String(line.dropFirst("ip_address=".count)) }
                if line.hasPrefix("hw_address=") { octets = macOctets(String(line.split(separator: ",").last ?? "")) }
                if line.hasPrefix("lease=") { expiry = UInt64(line.dropFirst("lease=".count).replacingOccurrences(of: "0x", with: ""), radix: 16) ?? 0 }
            }
            if let ip, octets == wanted, best == nil || expiry > best!.expiry { best = (ip, expiry) }
        }
        return best?.ip
    }

    static func macOctets(_ mac: String) -> [Int] {
        mac.split(separator: ":").compactMap { Int($0, radix: 16) }
    }

    /// The host interface on the VM's subnet (vmnet's bridgeN), found by address rather than name.
    static func bridgeInterface(for ip: String) -> String? {
        let vm = inet_addr(ip)
        guard vm != INADDR_NONE else { return nil }
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = entry.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET), let mask = ifa.ifa_netmask else { continue }
            let a = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            let m = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            if m != 0, m != 0xFFFF_FFFF, a & m == vm & m { return String(cString: ifa.ifa_name) }
        }
        return nil
    }

    // MARK: Readiness

    /// Whether the RDP listener accepts a TCP connection. Calls back on the main queue.
    static func probe(mac: String?, timeout: TimeInterval = 2, completion: @escaping (Readiness) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let result = probeNow(mac: mac, timeout: timeout)
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Blocking form of `probe`.
    static func probeNow(mac: String?, timeout: TimeInterval = 2) -> Readiness {
        leasedIP(mac: mac).map { connectTCP(ip: $0, port: 3389, timeout: timeout) } ?? .notReady
    }

    /// A BSD socket pinned to the vmnet bridge with IP_BOUND_IF. Network.framework follows VPN routing,
    /// and with a Tailscale exit node active it sends 192.168.64.x into the tunnel, where the VM is
    /// unreachable. `.blocked` means macOS Local Network privacy refused the connection.
    ///
    /// macOS reports that refusal to BSD sockets as EHOSTUNREACH, straight from connect(), not as
    /// EPERM (Apple's own networking engineers say so; XNU drops the SYN in tcp_output). But ARP giving
    /// up on a VM that's still booting also surfaces as one immediate EHOSTUNREACH, after which the
    /// kernel answers EHOSTDOWN for 20 s. So an immediate refusal is tried once more on a fresh socket,
    /// and only two in a row count as `.blocked` (see `looksDenied`). A heuristic from kernel source
    /// and Apple's forums, not yet seen live against a denied grant.
    private static func connectTCP(ip: String, port: UInt16, timeout: TimeInterval) -> Readiness {
        // No bridge means the VM's network isn't up. Don't fall back to normal routing, which can send
        // the connection into a VPN tunnel.
        guard let name = bridgeInterface(for: ip) else { return .notReady }
        var immediate: [Int32] = []
        for _ in 0..<2 {
            switch attempt(ip: ip, port: port, interface: name, timeout: timeout) {
            case .ready: return .ready
            case .notReady: return .notReady
            case .refusedAtOnce(let code):
                immediate.append(code)
                guard deniedErrors.contains(code) else { return .notReady }
            }
        }
        return looksDenied(immediate) ? .blocked : .notReady
    }

    /// What Local Network privacy's refusal can look like from connect().
    static let deniedErrors: Set<Int32> = [EHOSTUNREACH, EPERM, EACCES]

    /// Two immediate refusals in a row, each one Local Network privacy could have caused.
    static func looksDenied(_ immediateErrors: [Int32]) -> Bool {
        immediateErrors.count >= 2 && immediateErrors.allSatisfy { deniedErrors.contains($0) }
    }

    private enum Attempt { case ready, notReady, refusedAtOnce(Int32) }

    private static func attempt(ip: String, port: UInt16, interface name: String, timeout: TimeInterval) -> Attempt {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return .notReady }
        defer { close(fd) }
        var index = if_nametoindex(name)
        setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &index, socklen_t(MemoryLayout<UInt32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr(ip)
        let status = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        let code = status == 0 ? 0 : errno   // before anything else can overwrite it
        if status == 0 { return .ready }
        guard code == EINPROGRESS else { return .refusedAtOnce(code) }
        var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard Darwin.poll(&descriptor, 1, Int32(timeout * 1000)) == 1 else { return .notReady }
        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length)
        // A late EHOSTUNREACH is ARP timing out on a VM that isn't up yet, never the privacy check. A
        // late EPERM/EACCES goes through the same second look as an immediate one.
        if error == EPERM || error == EACCES { return .refusedAtOnce(error) }
        return error == 0 ? .ready : .notReady
    }

    // MARK: One-off connection (fallback)

    /// The .rdp settings for a one-off connection. Windows App never uses saved credentials for these,
    /// so it asks for the password; that's why this is only the fallback.
    static func rdpFile(host: String, user: String?) -> String {
        var lines = ["full address:s:\(host)"]
        if let user { lines.append("username:s:\(user)") }
        lines += ["dynamic resolution:i:1", "screen mode id:i:1", "redirectclipboard:i:1", "audiomode:i:0"]
        return lines.joined(separator: "\n") + "\n"
    }

    /// Opens a one-off connection in Windows App. False if Windows App is missing or the file couldn't
    /// be written.
    static func openOneOff(host: String, user: String?) -> Bool {
        let directory = Host.applicationSupport
        let safeName = host.filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }
        let file = directory.appendingPathComponent("\(safeName.isEmpty ? "vm" : safeName).rdp")
        guard (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil,
              (try? rdpFile(host: host, user: user).write(to: file, atomically: true, encoding: .utf8)) != nil,
              let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Config.windowsAppBundleID)
        else { return false }
        NSWorkspace.shared.open([file], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        return true
    }

    // MARK: Certificate trust (H7)

    /// Whether macOS trusts the listener certificate for `host`, exactly as an SSL client would.
    /// (`security verify-cert` reports a Certificate Transparency failure regardless, so it can't be
    /// used for this.) Blocking.
    static func certificateTrusted(der: Data, host: String) -> (trusted: Bool, reason: String) {
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else { return (false, "not a certificate") }
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(certificate, SecPolicyCreateSSL(true, host as CFString), &trust) == errSecSuccess,
              let trust else { return (false, "couldn't evaluate") }
        var error: CFError?
        if SecTrustEvaluateWithError(trust, &error) { return (true, "") }
        return (false, error.map { CFErrorCopyDescription($0) as String } ?? "not trusted")
    }

    /// Whether the trust setting names the host (`-s <host>`) as well as the SSL policy.
    ///
    /// Scoped, because unscoped means the guest's own key is a trusted SSL root for *every* host:
    /// anyone who can read that VM's disk (it isn't encrypted, and its admin password is recoverable)
    /// could then impersonate any site to this Mac. Scoping limits it to the one name Winbar connects
    /// to. Tested live on 2026-09-20.
    static let scopeTrustToHost = true

    /// Trusts the certificate for SSL only, in the login keychain. macOS shows its own approval dialog.
    static func trustCertificate(der: Data, host: String) -> Result<Void, WinbarError> {
        let directory = Host.applicationSupport
        let safeName = host.filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }
        let file = directory.appendingPathComponent("\(safeName)-rdp.cer")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try der.write(to: file, options: .atomic)
        } catch {
            return .failure(WinbarError("Couldn't save the certificate", error.localizedDescription))
        }
        let keychain = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Keychains/login.keychain-db").path
        let scope = scopeTrustToHost ? ["-s", host] : []
        let result = Shell.run("/usr/bin/security",
                               ["add-trusted-cert", "-r", "trustRoot", "-p", "ssl"] + scope + ["-k", keychain, file.path],
                               timeout: 300)
        guard result.status == 0 else { return .failure(WinbarError("macOS didn't trust the certificate", result.output)) }
        return .success(())
    }
}
