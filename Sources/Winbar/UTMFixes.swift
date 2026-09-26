import Foundation

/// What UTM changed, by version, where Winbar works around it or has to allow for it.
///
/// Each decision takes the version as a string and nothing else, so every gate is tested without a
/// UTM; the callers pass `UTM.version`, which is read from disk each time. An unreadable or missing
/// version always gets the old behaviour: the old behaviour costs a UTM restart, the new one on the
/// wrong UTM costs a crash that takes every running VM with it.
///
/// One version for all of it, 5.0.6, because it is both the first tag that contains
/// utmapp/UTM#7899 (merge 4dababc8, the fix for #7882: `update configuration` now closes the stopped
/// VM's window before applying the change) and the first UTM 5 Winbar is tried against. 5.0.0–5.0.5
/// lack the fix, and 5.0.4–5.0.5 pinned a CocoaSpice revision that freed port writes early
/// (UTM#7814), so nothing learned on them carries over. Anything newer is assumed to behave like
/// 5.0.6; that assumption is what a spike on a later version would check
/// (docs/internal/UTM5-SPIKE-RESEARCH.md §4).
enum UTMFixes {
    /// 5.0.6 (Beta), published 2026-09-24.
    static let displayCrashFixed = (5, 0, 6)

    /// Whether this UTM has #7899. Pure.
    static func hasDisplayCrashFix(_ version: String?) -> Bool {
        guard let version, let v = CreatePreflight.parseVersion(version) else { return false }
        return (v.major, v.minor, v.patch) >= displayCrashFixed
    }

    /// Whether a display change has to be followed by quitting UTM before the VM starts again
    /// (utmapp/UTM#7882): every 4.x and 5.0.0–5.0.5. Pure.
    ///
    /// Only the `update configuration` path is fixed in 5.0.6; the unguarded `displays[id]` lookup
    /// is still in `VMDisplayQemuMetalWindowController`, and `reload configuration` doesn't close the
    /// window. Winbar uses neither, and must keep it that way for this gate to hold.
    static func displayChangeRestartsUTM(_ version: String?) -> Bool { !hasDisplayCrashFix(version) }

    /// Whether an `update configuration` can make UTM quit by itself. #7899's fix closes the VM's
    /// window first, and with UTM's library window closed as well that was its last window: UTM then
    /// quits unless "keep running after the last window closes" is on, which it isn't by default
    /// (`AppDelegate.swift` @v5.0.6:31, 75-77). Pure.
    ///
    /// It quits *before the change is saved*, which the spike saw every time (rows 7B, 16b, 17): in
    /// `UTMScriptingConfigImpl.updateConfiguration` @v5.0.6:37-40 the window is closed
    /// (`data.close(vm:)`) and then the new configuration is saved with `try await data.save(vm:)`.
    /// That `await` turns the run loop, AppKit asks `applicationShouldTerminateAfterLastWindowClosed`
    /// there — no VM is running, so the answer is yes — and UTM terminates with the save still
    /// pending. So a relaunch and a read-back only find out the change was lost; `UTMOpenHold`
    /// keeps UTM from quitting in the first place, and `UTMScripting.updateConfiguration` sends the
    /// change once more if it quit anyway.
    static func mayQuitAfterUpdate(_ version: String?) -> Bool { hasDisplayCrashFix(version) }

    /// Whether a failed script that sent `update configuration` is UTM having quit by itself rather
    /// than refusing the change. Needs all three: a UTM that does that, a script that got as far as
    /// sending the change, and the UTM it was sent to gone. Anything less is a refusal and is said as
    /// one. Pure.
    static func quitItselfAfterUpdate(version: String?, sentChange: Bool, utmGone: Bool) -> Bool {
        mayQuitAfterUpdate(version) && sentChange && utmGone
    }

    /// Whether a shared folder Winbar writes with `update registry` (always with the VM stopped) is a
    /// bookmark that outlives the UTM that made it. Pure.
    ///
    /// On 4.7.5 it isn't: `UTMScriptingRegistryEntryImpl.updateRegistry` resolves the path in a
    /// throwaway helper (`system ?? UTMProcess()`) and stores that *remote* bookmark as if it were
    /// the real one (`File(dummyFromPath:remoteBookmark:)`), which no later UTM can open — so the
    /// share dies when UTM restarts, and `update configuration` fails with -2700 naming it. On 5.0.6
    /// (utmapp/UTM f2c3ecae, first in v5.0.6) a stopped VM has no QEMU system to hand it to, so the
    /// same call makes a persistent security-scoped bookmark instead (@v5.0.6:67-84), the kind UTM's
    /// own folder picker makes. The spike agrees: the share survived quitting and relaunching UTM
    /// (row 10 (b)) and six display changes with no rewrite (row 16s).
    static func scriptedShareDurable(_ version: String?) -> Bool { hasDisplayCrashFix(version) }

    /// Whether Windows gets the shared folder UTM holds at the start it is started with. 4.7.5 hands
    /// it the folder from the start *before* (five cycles measured, `SharedFolder.settle`), so a
    /// change there needs two starts; on 5.0.6 the first start after a change brought it (spike row
    /// 10 (a), setup's single restart, checked from inside Windows). Pure.
    static func shareArrivesOnFirstStart(_ version: String?) -> Bool { hasDisplayCrashFix(version) }

    /// Whether UTM can report a VM that is off as pausing or resuming. 5.0.6 runs qemu-img on a
    /// stopped VM's disks for snapshots, discarding a saved state and the Snapshots tab's first look,
    /// and marks the VM saving or restoring meanwhile, which scripting maps to pausing and resuming (a
    /// FIXME in `UTMQemuVirtualMachine.swift` @v5.0.6:634-645). A `start` then fails with "operation
    /// not available". Pure.
    static func reportsBusyWhileOff(_ version: String?) -> Bool { hasDisplayCrashFix(version) }

    /// A QEMU VM UTM lists as pausing or resuming, with no QEMU process of its own, on a UTM that
    /// does that: it is off, and UTM is working on its disks. Not starting and not stopping, which is
    /// what those two words would otherwise be read as. The caller only asks about QEMU VMs
    /// (`UTMScripting.markBusyWhileOff`): an Apple Virtualization VM has no QEMU process even while it
    /// runs, so the missing process would prove nothing about it. Pure.
    static func busyWhileOff(status: String, hasProcess: Bool, version: String?) -> Bool {
        reportsBusyWhileOff(version) && !hasProcess && (status == "pausing" || status == "resuming")
    }

    /// Asks `busy` until it says the VM is no longer busy (nil) or the deadline passes, and returns
    /// the last busy status when it gave up. Takes the question as a closure so the wait is tested
    /// without a UTM.
    static func waitOutBusy(deadline: Date, every interval: TimeInterval, busy: () -> String?) -> String? {
        while true {
            guard let status = busy() else { return nil }
            guard Date() < deadline else { return status }
            pause(interval)
        }
    }
}
