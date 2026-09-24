import Foundation
import Testing
@testable import Winbar

// G10, "Drivers and tools". It was a note drawn with the hollow circle of a check not yet made and
// nothing to press, so a VM with every part in place looked like a step that never finished, with no
// way on. Now it is a check: done when each part is there, and when one isn't, the row names it, says
// what it costs and how to put it back, and has I've Done It and Skip.

private func out(_ pairs: [(String, String)]) -> GuestOutput { GuestOutput(pairs: pairs.map { (key: $0.0, value: $0.1) }) }

private let everything = [("G10_NET", "Red Hat VirtIO Ethernet Adapter"), ("G10_TOOLS", "0.1.273"), ("G10_AGENT", "109.1.0")]

@Suite("Drivers and tools is a check, and names what's missing")
struct DriversAndToolsTests {
    /// What the owner's VM answered: all three in place, so the row is done and folds into "already right".
    @Test("Everything in place is done, with each part and its version")
    func everythingInPlace() {
        let status = DriversAndTools(out(everything)).status
        #expect(status.isOK)
        #expect(status.detail == "VirtIO network adapter, UTM Guest Tools 0.1.273, guest agent 109.1.0")
    }

    /// Windows is asked through the agent, so it is answering whenever this is read: not listed among
    /// the installed programs isn't missing.
    @Test("An agent Windows doesn't list is still answering, not missing")
    func agentUnlisted() {
        let status = DriversAndTools(out(Array(everything.prefix(2)))).status
        #expect(status.isOK)
        #expect(status.detail.hasSuffix("guest agent answering"))
    }

    @Test("Missing Guest Tools are named, with what they cost and how to install them")
    func toolsMissing() {
        let status = DriversAndTools(out([everything[0], everything[2]])).status
        guard case .manual(let detail, let how) = status else { Issue.record("\(status)"); return }
        #expect(detail == "UTM Guest Tools aren't installed")
        #expect(how.contains("shared folder"))
        #expect(how.contains("Install Windows Guest Tools…"))
        #expect(how.hasSuffix("then run this again."), "the window turns this into its own button's name")
    }

    @Test("A missing network adapter is named, and with the Guest Tools in, the card is what to look at")
    func networkMissing() {
        let status = DriversAndTools(out(Array(everything.dropFirst()))).status
        guard case .manual(let detail, let how) = status else { Issue.record("\(status)"); return }
        #expect(detail == "Windows has no VirtIO network adapter")
        #expect(how.contains("Emulated Network Card: virtio-net-pci"))
        #expect(how.hasSuffix("then run this again."))
    }

    /// Both missing is one cause: the Guest Tools carry the network driver. One install is the answer,
    /// and the row says Remote Desktop can't reach Windows until then.
    @Test("Both missing names both, and one install fixes both")
    func bothMissing() {
        let status = DriversAndTools(out([everything[2]])).status
        guard case .manual(let detail, let how) = status else { Issue.record("\(status)"); return }
        #expect(detail == "Windows has no VirtIO network adapter; UTM Guest Tools aren't installed")
        #expect(how.contains("Remote Desktop can't reach it"))
        #expect(!how.contains("Emulated Network Card"))
    }

    /// The script emits G10_ERROR when the listing throws; nothing read it, so a failed listing said
    /// "no VirtIO network adapter".
    @Test("A listing that failed says so, instead of calling everything missing")
    func listingFailed() {
        let status = DriversAndTools(out([("G10_ERROR", "Access is denied")])).status
        guard case .error(let detail) = status else { Issue.record("\(status)"); return }
        #expect(detail.contains("Access is denied"))
    }

    @Test("The recipe's G10 is this check, and the guest script still emits all four keys")
    func wired() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let recipe = try String(contentsOf: root.appendingPathComponent("Sources/Winbar/Recipe.swift"), encoding: .utf8)
        #expect(recipe.contains("guestStatus(ctx) { out in DriversAndTools(out).status }"))
        #expect(Recipe.check("G10")?.why.contains("For reference") == false)
        let script = try String(contentsOf: root.appendingPathComponent("Sources/Winbar/GuestScripts.swift"), encoding: .utf8)
        for key in ["G10_NET", "G10_TOOLS", "G10_AGENT", "G10_ERROR"] { #expect(script.contains("Emit '\(key)'"), "\(key)") }
    }

    /// Where the row lands on the tune page: done folds it into "already right"; missing puts it
    /// first, with its buttons.
    @Test("On the tune page, done is verified and missing needs the person, with I've Done It and Skip")
    func onTheTunePage() throws {
        let check = try #require(Recipe.check("G10"))
        var facts = SetupFlow.Facts()
        facts.rows["G10"] = SetupFlow.Row(check, DriversAndTools(out(everything)).status)
        #expect(SetupTuneGroups(facts).verified.map(\.id).contains("G10"))

        facts.rows["G10"] = SetupFlow.Row(check, DriversAndTools(out([everything[2]])).status)
        let row = try #require(facts.rows["G10"])
        #expect(SetupTuneStatus.status(for: row, facts: facts) == .needsAttention)
        #expect(SetupTuneGroups(facts).needsYou.map(\.id).contains("G10"))
        let titles = SetupTuneRowActions.of(row, facts: facts).map(\.title)
        #expect(titles.contains(SetupCopy.Tune.bDone("G10")))
        #expect(titles.contains(SetupCopy.bSkip))
    }

    /// Any row that is still only a note draws ⓘ, never the hollow circle a check not yet made has.
    @Test("A note's mark is ⓘ, not the not-yet circle")
    func noteMark() throws {
        let row = SetupFlow.Row(try #require(Recipe.check("G9")), .info("decrypting C: (40% still encrypted)"))
        #expect(TuneRowHeader.mark(.information, row) == .info)
        #expect(TuneRowHeader.mark(.information, row) != .pending)
        #expect(StatusMark.Status.info.symbol == "info.circle")
        #expect(StatusMark.Status.info.label(pending: "") == SetupCopy.Status.info)
    }
}
