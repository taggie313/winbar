import Foundation

/// G10, what UTM Guest Tools put into Windows: the driver for the VM's VirtIO network card (Windows
/// has none of its own for UTM's aarch64 NIC), the Guest Tools themselves, which bring the SPICE agent
/// and the shared folder's service, and the QEMU guest agent Winbar asks Windows everything through.
///
/// It used to be a note, "for reference", drawn with the hollow circle of a check not yet made, and
/// with nothing to press: a complete install read as a step that never finished, with no way on. Now
/// each part is checked; one that is missing is named, with what it costs and how to put it back,
/// and the row is the person's to do or to Skip. Pure.
struct DriversAndTools: Equatable {
    /// The VirtIO adapter's description ("Red Hat VirtIO Ethernet Adapter"); nil when Windows lists none.
    var network: String?
    /// UTM Guest Tools' version, from Windows' installed programs; nil when they aren't listed.
    var tools: String?
    /// The QEMU guest agent's version, likewise. The agent is answering whenever this is read at all,
    /// since Windows is asked through it, so an agent Windows doesn't list is not a missing one.
    var agent: String?
    /// PowerShell's own error, when listing them failed.
    var error: String?

    init(network: String? = nil, tools: String? = nil, agent: String? = nil, error: String? = nil) {
        self.network = network
        self.tools = tools
        self.agent = agent
        self.error = error
    }

    init(_ out: GuestOutput) {
        self.init(network: out["G10_NET"], tools: out["G10_TOOLS"], agent: out["G10_AGENT"], error: out["G10_ERROR"])
    }

    enum Part: Equatable, CaseIterable {
        case network, tools
    }

    var missing: [Part] {
        Part.allCases.filter { part in
            switch part {
            case .network: return network == nil
            case .tools: return tools == nil
            }
        }
    }

    var status: Status {
        // Before, a failed listing read as "no VirtIO network adapter": the error was emitted and never read.
        if let error { return .error("Windows couldn't list its drivers: \(error)") }
        let missing = missing
        guard !missing.isEmpty else {
            return .ok(["VirtIO network adapter", "UTM Guest Tools \(tools ?? "")",
                        agent.map { "guest agent \($0)" } ?? "guest agent answering"].joined(separator: ", "))
        }
        return .manual(missing.map(Self.says).joined(separator: "; "), how: how(missing))
    }

    /// What is missing, as the row's detail.
    static func says(_ part: Part) -> String {
        switch part {
        case .network: return "Windows has no VirtIO network adapter"
        case .tools: return "UTM Guest Tools aren't installed"
        }
    }

    /// What each missing part costs and the one way to put it back. The Guest Tools carry the network
    /// driver too, so with both missing one install is the whole answer.
    func how(_ missing: [Part]) -> String {
        let install = "Install UTM Guest Tools in Windows (in UTM, the VM's CD/DVD menu → Install Windows Guest Tools…), "
            + "then run this again."
        if missing.contains(.tools) {
            let costs = missing.contains(.network)
                ? "Without them Windows has no driver for the VM's network card, so Remote Desktop can't reach it, "
                    + "and the shared folder doesn't work."
                : "Without them the shared folder doesn't work, and neither do the clipboard and screen size in "
                    + "UTM's own window."
            return costs + " " + install
        }
        return "The Guest Tools are installed, but Windows lists no VirtIO network adapter, the card they have a driver "
            + "for, so it's on a slower kind or none. With the VM stopped, in UTM: select it → Edit → Network → "
            + "Emulated Network Card: virtio-net-pci. If it's that already, reinstall UTM Guest Tools (the VM's "
            + "CD/DVD menu → Install Windows Guest Tools…), then run this again."
    }
}
