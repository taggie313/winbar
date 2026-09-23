import Foundation
import Testing
@testable import Winbar

// Pure logic only. Nothing here may reach UTM, a VM, the keychain, TCC or the user's defaults.

/// `update configuration` makes UTM touch the VM's registry, and a shared folder Winbar wrote by
/// script is a bookmark UTM cannot resolve — so an unrelated change fails with
/// `The file "Shared-with-Windows" couldn't be opened. (-2700)`, and the share is dropped.
/// Reproduced deliberately twice on 2026-09-21, the second time on a share set and verified from
/// inside Windows two minutes earlier: the bookmark is not going stale with age, UTM simply can
/// never resolve it. Winbar sets the folder aside for the change and puts it back.
@Suite("Setting a shared folder aside for a configuration change")
struct ReconfigureParksSharedFolder {
    /// The folder Winbar wrote, still where Winbar left it: the case the bug is about.
    @Test("A folder Winbar wrote is set aside")
    func parksWinbarsOwn() {
        #expect(Reconfigure.parksSharedFolder(requestedShare: nil, current: "/Users/rosa/Shared",
                                              remembered: "/Users/rosa/Shared", wasOurs: true))
    }

    /// The one that must never be got wrong. A folder chosen in UTM's own details screen holds a
    /// durable security-scoped bookmark — that is the whole difference between the two paths, and
    /// the reason the picker works at all. It does not cause the failure, so clearing it would
    /// trade something the person chose for a fragile scripted copy: pure loss.
    @Test("A folder picked in UTM is never touched")
    func neverParksAPickedFolder() {
        #expect(!Reconfigure.parksSharedFolder(requestedShare: nil, current: "/Users/rosa/Shared",
                                               remembered: "/Users/rosa/Shared", wasOurs: false))
        // Not remembered at all is the same answer: Winbar has no claim on it.
        #expect(!Reconfigure.parksSharedFolder(requestedShare: nil, current: "/Users/rosa/Shared",
                                               remembered: nil, wasOurs: true))
    }

    /// Someone re-pointed the share in UTM since Winbar wrote it. What is there now is theirs.
    @Test("A folder that has been changed since Winbar wrote it is not Winbar's to move")
    func doesNotParkAFolderThatMoved() {
        #expect(!Reconfigure.parksSharedFolder(requestedShare: nil, current: "/Users/rosa/Elsewhere",
                                               remembered: "/Users/rosa/Shared", wasOurs: true))
    }

    /// A request that carries its own shared-folder change already writes the folder before the
    /// configuration change and again after UTM restarts. Parking as well would fight it, and could
    /// put the OLD folder back over the new one.
    @Test("A request that changes the folder itself is left alone")
    func doesNotParkWhenTheRequestOwnsTheFolder() {
        #expect(!Reconfigure.parksSharedFolder(requestedShare: .folder("/Users/rosa/New"),
                                               current: "/Users/rosa/Shared",
                                               remembered: "/Users/rosa/Shared", wasOurs: true))
        // Including a request that turns sharing off: it must end off, not be restored.
        #expect(!Reconfigure.parksSharedFolder(requestedShare: .off, current: "/Users/rosa/Shared",
                                               remembered: "/Users/rosa/Shared", wasOurs: true))
    }

    @Test("Nothing shared, nothing to set aside")
    func nothingToPark() {
        #expect(!Reconfigure.parksSharedFolder(requestedShare: nil, current: nil,
                                               remembered: "/Users/rosa/Shared", wasOurs: true))
    }

    /// Trailing slashes come from `POSIX path of`, which always ends a folder with one. The same
    /// folder written two ways is still the same folder, or a change would refuse to park itself.
    @Test("A trailing slash doesn't make it a different folder")
    func slashesDoNotMatter() {
        #expect(Reconfigure.parksSharedFolder(requestedShare: nil, current: "/Users/rosa/Shared/",
                                              remembered: "/Users/rosa/Shared", wasOurs: true))
    }
}

/// A shared-folder change alters no device, so it must not drag a stopped VM through a boot for the
/// BitLocker guard, and must not restart UTM. These are the existing rules; they are asserted here
/// because the parking change is the first thing to reach into this decision.
@Suite("What counts as a hardware change")
struct ReconfigureHardware {
    @Test func sharingAFolderIsNotHardware() {
        var changes = ConfigChanges()
        changes.sharedFolder = .folder("/Users/rosa/Shared")
        #expect(!changes.changesHardware)
    }

    @Test func displayCPUAndRAMAre() {
        var display = ConfigChanges(); display.display = .headless
        var cpu = ConfigChanges(); cpu.cpuCores = 6
        var ram = ConfigChanges(); ram.memoryMB = 16384
        #expect(display.changesHardware)
        #expect(cpu.changesHardware)
        #expect(ram.changesHardware)
    }
}
