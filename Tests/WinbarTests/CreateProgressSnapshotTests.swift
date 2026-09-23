import AppKit
import SwiftUI
import Testing
@testable import Winbar

// The install window's three job views, drawn: running, failed and done, in light and dark, and with
// Increase Contrast and Reduce Transparency in each. Between them they use every piece of the step
// list — each mark, a row with a detail and a clock, the orange box for a stall and for a boxed
// warning, and the quiet notes — so a change to any of those shows up in at least one render. See
// Snapshot.swift for comparing a commit's renders with its parent's.
//
// The controller is made with invented facts, so nothing here reads this Mac's settings or asks
// about UTM, and it is never shown: its clock doesn't tick until a window opens, so every time in a
// fixture is placed relative to the controller's `now` and the clocks read the same on every run.

@MainActor private enum Drawn {
    /// The window's content size when it first opens (CreateWindowController.existingWindow). The
    /// longest of the three fixtures fits in it without scrolling, so every row is in the picture.
    static let size = CGSize(width: 600, height: 700)

    /// `.blank` would do, but it asks this Mac for its user's short name; these are all invented.
    /// FileVault is off because the running install says so (N_PW_FILEVAULT_OFF), and a Mac that
    /// is two things at once is a fixture a later view could be drawn wrong against.
    static let controller = CreateWindowController(facts: CreateFormFacts(
        mac: MacFacts(topTierCores: 8, totalCores: 12, memoryBytes: 32 << 30, shortUserName: "rosa"),
        utmInstalled: true, utmVersion: "4.7.5", fileVaultOn: false, freeGB: 400, volumeName: "atelier",
        existingVMNames: nil, menuVMName: nil))

    /// Seconds before the controller's `now`. A quarter-second past the whole second, so the clocks,
    /// which round down, can't land a second short on floating point.
    static func ago(_ seconds: TimeInterval) -> Date { controller.now.addingTimeInterval(-(seconds + 0.25)) }

    static let plan = CreatePlan(vmName: "winlab01", isoPath: "/Users/rosa/Downloads/Win11_25H2_English_Arm64_v2.iso",
                                 edition: testEdition(), cores: 6, memoryMiB: 16384, diskGiB: 128,
                                 options: CreateOption.defaults, noVisualTweaks: false, userName: "rosa",
                                 computerName: "winlab01", regional: nil, select: true, keepConsole: false)

    static func state(stage: CreateStage, outcome: CreateJobState.Outcome? = nil, detail: String? = nil,
                      stalled: StallState? = nil, messages: [(String, String)] = [],
                      failure: CreateFailure? = nil) -> CreateJobState {
        let started = ago(872)
        return CreateJobState(id: "create-20260922-091500-5d2c7a10", plan: plan,
                              vmID: "5D2C7A10-3E4B-4F61-9A0B-1C2D3E4F5A6B", stage: stage, detail: detail,
                              startedAt: started, updatedAt: ago(20),
                              finishedAt: outcome == nil ? nil : ago(0), outcome: outcome, restarts: 1,
                              bytesWritten: 7_900_000_000, shown: messages.map(\.0), stalled: stalled,
                              messages: messages.map { CreateMessage(code: $0.0, text: $0.1, at: started) },
                              failure: failure, mediaDir: "/tmp/winbar-media/5d2c7a10.noindex",
                              logPath: "/tmp/winbar-media/winbar.log", watched: outcome == nil,
                              stageStartedAt: ago(588))
    }

    static let timeMachine = ("W_TIMEMACHINE", "Couldn't keep the setup disk's folder out of Time Machine (the "
                              + "volume refused the exclusion), so a backup made during the install may include it.")

    /// Copying files, with the VM gone quiet: done, running and pending rows, the running row's
    /// detail and clock, the stall box, a boxed warning and a quiet note.
    static var running: CreateJobState {
        state(stage: .copy, detail: "7.9 GB written to the VM's disk", stalled: .quiet,
              messages: [timeMachine, ("N_PW_FILEVAULT_OFF", CreateCopy.nPWFileVaultOff),
                         (InstallAlert.stall.rawValue, CreateCopy.wStall(vmName: plan.vmName))])
    }

    /// Stopped waiting during the first sign-in: the failed mark, and the list under a failure.
    static var failed: CreateJobState {
        state(stage: .oobe, outcome: .failed,
              messages: [("N_PC_SAVED", CreateCopy.nPCSaved(name: plan.vmName))],
              failure: CreateFailure(code: "E_TIMEOUT", title: "Windows still hadn't finished installing",
                                     detail: "Windows still hadn't finished installing after 2 hours, so Winbar "
                                        + "stopped waiting.",
                                     nextStep: "The VM is still running: look at its window in UTM."))
    }

    /// Installed, with a warning the ending has to box rather than footnote.
    static var done: CreateJobState {
        state(stage: .finish, outcome: .done,
              messages: [("N_PC_SAVED", CreateCopy.nPCSaved(name: plan.vmName)), timeMachine])
    }
}

@Suite("The install window, drawn")
struct CreateProgressSnapshots {
    /// Draws `state` in every appearance, checks each came out the same twice and has something in
    /// its top half, and records it.
    @MainActor private func check(_ state: CreateJobState, as name: String) throws {
        var drawn: [Snapshot.Appearance: Data] = [:]
        for appearance in Snapshot.Appearance.allCases {
            let view = CreateJobView(controller: Drawn.controller, state: state)
            let png = try #require(Snapshot.png(view, size: Drawn.size, appearance: appearance))
            let again = try #require(Snapshot.png(view, size: Drawn.size, appearance: appearance))
            // What a before-and-after comparison stands on: the same view draws the same pixels.
            // An animation caught mid-frame (the running row's spinner) would break it.
            #expect(Snapshot.difference(png, again)?.count == 0, "\(name), \(appearance.rawValue)")
            // The scroll view's contents are in the picture, not just the buttons under them.
            #expect((Snapshot.inked(png, rows: 0...0.5) ?? 0) > 0.02, "\(name), \(appearance.rawValue)")
            try Snapshot.record(png, as: "create-\(name)-\(appearance.rawValue)")
            drawn[appearance] = png
        }
        // The appearance took: dark isn't light drawn twice, and Increase Contrast reached the
        // secondary text and the orange boxes. Reduce Transparency isn't held to that: nothing in
        // this window is translucent, so it has nothing to flatten. SnapshotHarnessTests shows it
        // flattening a material.
        for (plain, changed) in [(Snapshot.Appearance.light, Snapshot.Appearance.dark),
                                 (.light, .lightIncreaseContrast), (.dark, .darkIncreaseContrast)] {
            let before = try #require(drawn[plain]), after = try #require(drawn[changed])
            #expect((Snapshot.difference(before, after)?.count ?? 0) > 0, "\(name), \(changed.rawValue)")
        }
    }

    @MainActor @Test("A running install draws the same way every time, in every appearance")
    func running() throws { try check(Drawn.running, as: "running") }

    @MainActor @Test("A failed install draws the same way every time, in every appearance")
    func failed() throws { try check(Drawn.failed, as: "failed") }

    @MainActor @Test("A finished install draws the same way every time, in every appearance")
    func done() throws { try check(Drawn.done, as: "done") }

    @MainActor @Test("The Mac in the fixtures is the one the running install's notes describe")
    func oneMac() {
        // The job view doesn't read the controller's facts, so nothing drawn here would catch the
        // two disagreeing; the wizard's form screens, drawn against the same controller, will.
        #expect(Drawn.running.messages.contains { $0.code == "N_PW_FILEVAULT_OFF" })
        #expect(Drawn.controller.form.passwordFileVaultNote == CreateCopy.nPWFileVaultOff)
    }
}
