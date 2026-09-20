import Darwin
import Foundation

/// A running UTM QEMU VM, as read from its own process arguments.
///
/// This is how the menu bar app polls: in-process, no subprocess, no Apple Events, cheap enough to do
/// every five seconds. Reading UTM's files instead would trip macOS's App Data protection.
struct VMProcess: Equatable {
    let pid: pid_t
    let arguments: [String]

    /// The `-name` value, with QEMU's option syntax undone (`,,` is an escaped comma; `guest=` is an
    /// optional key some front ends use).
    var name: String? {
        guard let raw = value(after: "-name") else { return nil }
        let first = VMProcess.splitOptions(raw).first ?? raw
        return first.hasPrefix("guest=") ? String(first.dropFirst("guest=".count)) : first
    }

    /// The `-uuid` value: the id UTM gave the VM, passed through untouched, unlike `-name`. This is
    /// what identifies a VM whose name has punctuation in it.
    var uuid: String? { value(after: "-uuid") }

    /// UTM's own `cleanupName`: everything outside letters, digits and spaces is dropped before the
    /// name reaches QEMU's `-name` (UTMQemuArgs.swift, `cleanupName`). Winbar has to apply the same
    /// rule to recognise the process of a VM called, say, "Windows 11 (work)".
    static func cleanedName(_ name: String) -> String {
        name.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || CharacterSet.whitespaces.contains($0) }
            .reduce(into: "") { $0.unicodeScalars.append($1) }
    }

    /// From `-device virtio-net-pci,mac=XX:..`. Any NIC with a mac= will do if there's no virtio one.
    var mac: String? {
        let devices = pairs(for: "-device")
        let ordered = devices.filter { $0.contains("virtio-net") } + devices.filter { !$0.contains("virtio-net") }
        for device in ordered {
            for option in VMProcess.splitOptions(device) where option.hasPrefix("mac=") {
                return String(option.dropFirst(4))
            }
        }
        return nil
    }

    /// The files behind the VM's writable drives (disk images, EFI variables), for telling where it's
    /// stored. UTM passes them as `file.filename=`; plain `file=` is QEMU's shorthand. CD images and
    /// read-only drives (the shared firmware) don't hold the VM's data.
    var diskImages: [String] {
        pairs(for: "-drive").compactMap { drive in
            let options = VMProcess.splitOptions(drive)
            guard !options.contains("media=cdrom"), !options.contains("readonly=on") else { return nil }
            for option in options {
                if option.hasPrefix("file.filename=") { return String(option.dropFirst("file.filename=".count)) }
                if option.hasPrefix("file=") { return String(option.dropFirst("file=".count)) }
            }
            return nil
        }
    }

    /// UTM runs a VM with an empty display list as `-vga none -nographic`.
    var headless: Bool { arguments.contains("-nographic") }

    /// `-smp cpus=6,sockets=1,...` or plain `-smp 6`.
    var cpus: Int? {
        guard let raw = value(after: "-smp") else { return nil }
        for option in VMProcess.splitOptions(raw) {
            if let n = Int(option) { return n }
            if option.hasPrefix("cpus="), let n = Int(option.dropFirst(5)) { return n }
        }
        return nil
    }

    /// `-m 16384`, `-m 16G` or `-m size=16384M`, in MiB.
    var memoryMB: Int? {
        guard let raw = value(after: "-m") else { return nil }
        var spec = VMProcess.splitOptions(raw).first ?? raw
        if spec.hasPrefix("size=") { spec = String(spec.dropFirst(5)) }
        let multiplier: Int
        switch spec.last?.uppercased() {
        case "G": multiplier = 1024; spec.removeLast()
        case "M": multiplier = 1; spec.removeLast()
        case "T": multiplier = 1024 * 1024; spec.removeLast()
        default: multiplier = 1
        }
        return Int(spec).map { $0 * multiplier }
    }

    /// UTM also starts swtpm through QEMULauncher, so insist on a qemu- binary in the path.
    var isQEMU: Bool {
        arguments.contains { $0.split(separator: "/").contains { $0.hasPrefix("qemu-") } }
    }

    private func value(after flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    private func pairs(for flag: String) -> [String] {
        arguments.indices.compactMap { i in
            arguments[i] == flag && i + 1 < arguments.count ? arguments[i + 1] : nil
        }
    }

    /// Splits a QEMU option string on commas, where a doubled comma stands for a literal one.
    static func splitOptions(_ string: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var chars = Array(string)[...]
        while let c = chars.popFirst() {
            if c == "," {
                if chars.first == "," { current.append(","); chars.removeFirst() } else { parts.append(current); current = "" }
            } else {
                current.append(c)
            }
        }
        parts.append(current)
        return parts
    }

    /// Parses a KERN_PROCARGS2 buffer: argc (int32), the exec path, NUL padding, then argc strings.
    static func parseProcArgs(_ buffer: [UInt8]) -> [String]? {
        guard buffer.count > 4 else { return nil }
        let argc = Int(buffer[0]) | Int(buffer[1]) << 8 | Int(buffer[2]) << 16 | Int(buffer[3]) << 24
        var i = 4
        while i < buffer.count && buffer[i] != 0 { i += 1 }   // exec path
        while i < buffer.count && buffer[i] == 0 { i += 1 }   // alignment padding
        var args: [String] = []
        while args.count < argc && i < buffer.count {
            let start = i
            while i < buffer.count && buffer[i] != 0 { i += 1 }
            args.append(String(decoding: buffer[start..<i], as: UTF8.self))
            i += 1
        }
        return args.count == argc ? args : nil
    }
}

enum VMProcesses {
    /// Every QEMU VM UTM is running right now.
    static func all() -> [VMProcess] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        var found: [VMProcess] = []
        for pid in pids.prefix(Int(max(filled, 0))) where pid > 0 {
            var name = [CChar](repeating: 0, count: 64)
            proc_name(pid, &name, UInt32(name.count))
            guard String(cString: name) == "QEMULauncher", let args = arguments(of: pid) else { continue }
            let process = VMProcess(pid: pid, arguments: args)
            if process.isQEMU { found.append(process) }
        }
        return found
    }

    /// Finds the VM's QEMU process by the id UTM gave the VM when it knows it, and by name otherwise.
    ///
    /// The id is the reliable half: UTM passes it verbatim as `-uuid`, while `-name` goes through
    /// UTM's `cleanupName`, which keeps only letters, digits and spaces (`UTMQemuArgs.swift`). A VM
    /// called "winbar-test" therefore runs as `-name winbartest`, and a plain name comparison says it
    /// isn't running at all — which is what made the first `winbar create` call its own successful
    /// start a failure.
    static func find(_ vmName: String?, id: String? = nil) -> VMProcess? {
        let processes = all()
        if let id, let byID = processes.first(where: { $0.uuid?.caseInsensitiveCompare(id) == .orderedSame }) {
            return byID
        }
        guard let vmName else { return nil }
        if let exact = processes.first(where: { $0.name == vmName }) { return exact }
        let cleaned = VMProcess.cleanedName(vmName)
        // Only when it can't be anything else: two VMs can clean to the same name ("a-b" and "a.b").
        let matches = processes.filter { $0.name == cleaned }
        return matches.count == 1 ? matches[0] : nil
    }

    static func isRunning(_ vmName: String?, id: String? = nil) -> Bool { find(vmName, id: id) != nil }

    private static func arguments(of pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return VMProcess.parseProcArgs(Array(buffer.prefix(size)))
    }

    /// Remembers what the running process says, so the menu knows it while the VM is off.
    ///
    /// A new MAC under the same name means a different VM (deleted and recreated, say), so what was
    /// known about the old one's BitLocker no longer applies.
    static func cache(_ process: VMProcess) {
        if let mac = process.mac, mac != Config.vmMAC {
            if Config.vmMAC != nil { Config.forgetBitLocker() }
            Config.vmMAC = mac
        }
        if Config.consoleEnabled != !process.headless { Config.consoleEnabled = !process.headless }
    }
}
