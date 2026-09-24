import Foundation
import Testing
@testable import Winbar

// A saved PC is the VM's only when it is for the VM's host AND signs in as the VM's Windows account.
//
// Live: a VM was deleted in UTM and a new one made with the same name, so the same host name. Windows
// App still had the old VM's saved PC, signing in as the old account. Winbar matched on the host
// alone, said the PC was saved, and Connect opened the stale entry. Everything here is pure, over
// invented `bookmark list` / `bookmark export` text: nothing runs Windows App (its --script command
// line deadlocks on some Macs, and a second writer on its store is the risk WindowsAppBookmarks
// exists to refuse).

private typealias Bookmarks = WindowsAppBookmarks

/// The shape `bookmark export` prints, for one saved PC.
private func export(host: String, user: String?) -> String {
    ["full address:s:\(host)", user.map { "username:s:\($0)" }, "screen mode id:i:2", "dynamic resolution:i:1"]
        .compactMap { $0 }.joined(separator: "\n")
}

private let host = "winlab01.local"
/// The old VM's saved PC: named after the VM, as Winbar's own create names it, signing in as morgan.
private let stale = Bookmarks.Bookmark(name: "winlab01", id: "8B1F0C52-0000-4E2A-9A11-DEADBEEF0001")
private let staleTarget = Bookmarks.target(inExport: export(host: host, user: "morgan"))
/// The new VM's, signing in as alex.
private let ours = Bookmarks.Bookmark(name: "winlab01 (alex)", id: "8B1F0C52-0000-4E2A-9A11-DEADBEEF0002")
private let oursTarget = Bookmarks.target(inExport: export(host: host, user: "alex"))

@Suite("Saved PCs are matched on host and account")
struct SavedPCAccountMatching {
    @Test("An export gives the host and the account")
    func readsTheTarget() {
        #expect(staleTarget == Bookmarks.Target(address: host, user: "morgan"))
        #expect(Bookmarks.target(inExport: export(host: host, user: nil)) == Bookmarks.Target(address: host, user: nil))
    }

    @Test("One account, however Windows App writes it")
    func sameAccount() {
        #expect(Bookmarks.sameAccount("alex", "ALEX"))
        #expect(Bookmarks.sameAccount("WINLAB01\\alex", "alex"))
        #expect(Bookmarks.sameAccount(".\\alex", " alex "))
        #expect(Bookmarks.sameAccount("MicrosoftAccount\\alex@example.com", "alex@example.com"))
        #expect(!Bookmarks.sameAccount("alex", "morgan"))
        #expect(!Bookmarks.sameAccount("alex@example.com", "alex"))
    }

    /// The live case: the only saved PC for the host is the deleted VM's.
    @Test("A same-host saved PC for another account is not the VM's, and is named as such")
    func theLiveCase() {
        let found = Bookmarks.lookup(host: host, user: "alex", in: [stale], targets: [stale.id: staleTarget])
        #expect(found.mine == nil)
        #expect(found.otherAccount == Bookmarks.OtherAccount(bookmark: stale, user: "morgan"))
        // Host alone, as before, would have called it the VM's.
        #expect(Bookmarks.match(host: host, in: [stale], addresses: [stale.id: host]) == stale)
    }

    @Test("With both there, the VM's own is the one, and the other is still reported")
    func bothThere() {
        for list in [[stale, ours], [ours, stale]] {
            let found = Bookmarks.lookup(host: host, user: "alex", in: list,
                                         targets: [stale.id: staleTarget, ours.id: oursTarget])
            #expect(found.mine == ours)
            #expect(found.otherAccount?.bookmark == stale)
        }
    }

    /// Nothing to compare against is not a mismatch: a PC saved without credentials, one whose export
    /// couldn't be read (matched on its name, as 0.1.0 taught), or a VM whose account Winbar doesn't know.
    @Test("An account that can't be read, on either side, leaves the host to decide")
    func unknownAccounts() {
        let noCredentials = Bookmarks.lookup(host: host, user: "alex", in: [stale],
                                             targets: [stale.id: Bookmarks.Target(address: host, user: nil)])
        #expect(noCredentials == Bookmarks.Lookup(mine: stale, otherAccount: nil))

        let byName = Bookmarks.Bookmark(name: host, id: "B")
        #expect(Bookmarks.lookup(host: host, user: "alex", in: [byName], targets: [:]).mine == byName)

        let unknownUser = Bookmarks.lookup(host: host, user: nil, in: [stale], targets: [stale.id: staleTarget])
        #expect(unknownUser == Bookmarks.Lookup(mine: stale, otherAccount: nil))
    }

    @Test("A PC for another host is nobody's business here")
    func otherHost() {
        let elsewhere = Bookmarks.target(inExport: export(host: "atelier.local", user: "morgan"))
        #expect(Bookmarks.lookup(host: host, user: "alex", in: [stale], targets: [stale.id: elsewhere])
                == Bookmarks.Lookup(mine: nil, otherAccount: nil))
    }
}

@Suite("C2 says whose saved PC it is, and what to do")
struct SavedPCAccountStatus {
    @Test("The VM's own saved PC is ok")
    func mine() {
        let status = Recipe.savedPCStatus(Bookmarks.Lookup(mine: ours, otherAccount: nil), host: host, user: "alex",
                                          windowsAppRunning: false)
        #expect(status.isOK && status.detail == "winlab01 (alex) (winlab01.local)")
    }

    /// Never "saved": that let the wizard move on and Connect open the stale entry.
    @Test("Another account's saved PC is named, with its account, and both ways out")
    func otherAccount() throws {
        let lookup = Bookmarks.Lookup(mine: nil, otherAccount: .init(bookmark: stale, user: "morgan"))
        let status = Recipe.savedPCStatus(lookup, host: host, user: "alex", windowsAppRunning: false)
        guard case .fixable(let detail) = status else { Issue.record("\(status)"); return }
        #expect(detail.contains("a saved PC for winlab01.local belongs to another account (morgan)"))
        #expect(detail.contains("setup can save a new one"))
        #expect(detail.contains("edit “winlab01” in Windows App so it signs in as alex"))

        // Windows App open: saving a new one would be a second writer, so it's the by-hand route.
        let open = Recipe.savedPCStatus(lookup, host: host, user: "alex", windowsAppRunning: true)
        guard case .manual(let title, let how) = open else { Issue.record("\(open)"); return }
        #expect(title.contains("belongs to another account (morgan)"))
        #expect(how.contains("edit “winlab01” in Windows App"))
        #expect(how.contains("quit Windows App first"))
    }

    @Test("None at all reads as it always did")
    func none() {
        let status = Recipe.savedPCStatus(.init(), host: host, user: "alex", windowsAppRunning: false)
        #expect(status.isFixable && status.detail == "none for winlab01.local; setup can save it for you")
    }

    /// The wizard's saved-PC step offers to save a new one, rather than passing on the stale PC.
    @Test("The Set Up window's saved-PC step offers to save, not to carry on")
    func wizardOffersToSave() {
        var facts = JourneyFixtures.facts
        facts.rows["C2"] = JourneyFixtures.row("C2", Recipe.savedPCStatus(
            .init(mine: nil, otherAccount: .init(bookmark: stale, user: "morgan")),
            host: "winlab02.local", user: "Bruno", windowsAppRunning: false))
        facts.windowsAppRunning = false
        #expect(SetupFlow.savedPC(facts) == .save(host: "winlab02.local", user: "Bruno"))
        #expect(!SetupFlow.isSatisfied(.savedPC, facts))
    }
}

@Suite("Connect never presses another account's tile")
struct SavedPCAccountConnect {
    @Test("With no other account known, the saved name first, then the host, as before")
    func asBefore() {
        #expect(WindowsApp.tileNames(host: host, savedName: nil, otherAccountHost: nil) == [host])
        #expect(WindowsApp.tileNames(host: host, savedName: "Windows 11", otherAccountHost: nil) == ["Windows 11", host])
        #expect(WindowsApp.tileNames(host: host, savedName: host, otherAccountHost: nil) == [host])
        // Known for some other host: nothing to do with this one.
        #expect(WindowsApp.tileNames(host: host, savedName: nil, otherAccountHost: "atelier.local") == [host])
    }

    /// A tile named after the host may be the other account's, so only this VM's own name is
    /// pressed, and with none, nothing: Connect then opens a one-off connection that asks.
    @Test("With another account's PC for the host, only the VM's own name, or nothing")
    func onlyOurs() {
        #expect(WindowsApp.tileNames(host: host, savedName: "winlab01 (alex)", otherAccountHost: host) == ["winlab01 (alex)"])
        #expect(WindowsApp.tileNames(host: host, savedName: nil, otherAccountHost: "WINLAB01.local").isEmpty)
        #expect(WindowsApp.tileNames(host: host, savedName: host, otherAccountHost: host).isEmpty)
    }

    /// No tile to press means the saved route answers false, and Connect goes one-off.
    @Test("An empty list sends Connect to the one-off route")
    func oneOff() throws {
        var oneOff = 0
        let opened = try Connection.openDesktop(host: host, user: "alex", accessibility: { true },
                                                saved: { WindowsApp.tileNames(host: $0, savedName: nil, otherAccountHost: host).isEmpty ? false : true },
                                                oneOff: { _, _ in oneOff += 1; return true })
        #expect(!opened)
        #expect(oneOff == 1)
    }

    /// The whole of what C2, its fix and `Setup.savePC` remember, from the lookup alone.
    @Test("What is remembered after a lookup, as one value")
    func memory() {
        let other = Bookmarks.OtherAccount(bookmark: stale, user: "morgan")
        #expect(Recipe.savedPCMemory(after: .init(mine: ours, otherAccount: other), host: host, previous: SavedPCMemory())
                == SavedPCMemory(host: host, name: ours.name, otherAccountHost: host,
                                 otherAccountName: stale.name, otherAccountUser: "morgan"))
        #expect(Recipe.savedPCMemory(after: .init(mine: nil, otherAccount: other), host: host, previous: SavedPCMemory())
                == SavedPCMemory(host: nil, name: nil, otherAccountHost: host,
                                 otherAccountName: stale.name, otherAccountUser: "morgan"))
        // A lookup that stopped at the VM's own PC can't see the other one: what was known stands.
        let known = SavedPCMemory(host: host, name: ours.name, otherAccountHost: host,
                                  otherAccountName: stale.name, otherAccountUser: "morgan")
        #expect(Recipe.savedPCMemory(after: .init(mine: ours, otherAccount: nil), host: host, previous: known) == known)
        // The VM's own, named after the host, and nothing else: Connect presses the host again.
        let hostNamed = Bookmarks.Bookmark(name: host, id: "C")
        #expect(Recipe.savedPCMemory(after: .init(mine: hostNamed, otherAccount: nil), host: host,
                                     previous: SavedPCMemory(host: host, otherAccountHost: host,
                                                             otherAccountName: stale.name, otherAccountUser: "morgan"))
                == SavedPCMemory(host: host, name: nil, otherAccountHost: nil))
        // Windows App has none at all: whatever was remembered is stale and goes.
        #expect(Recipe.savedPCMemory(after: .init(), host: host,
                                     previous: SavedPCMemory(host: host, name: "Old", otherAccountHost: host))
                == SavedPCMemory())
    }

    /// C2, its fix and `Setup.savePC` hand the lookup over whole. The delegate-free way to see the
    /// wiring: the lines themselves, since each runs Windows App.
    @Test("C2, its fix and setup's save remember the whole lookup")
    func wiring() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let recipe = try String(contentsOf: root.appendingPathComponent("Sources/Winbar/Recipe.swift"), encoding: .utf8)
        let setup = try String(contentsOf: root.appendingPathComponent("Sources/Winbar/Setup.swift"), encoding: .utf8)
        #expect(recipe.contains("Recipe.rememberSavedPC(lookup, host: host, for: ctx)"))
        #expect(recipe.contains("Recipe.rememberSavedPC(found, host: host, for: ctx)"))
        #expect(setup.contains("Recipe.rememberSavedPC(saved.lookup, host: host, for: ctx)"))
    }

    @Test("What is remembered after a lookup", arguments: [
        // seen, mine, previous → remembered
        (true, nil as String?, nil as String?, host as String?),
        (true, "winlab01 (alex)", nil, host),
        (false, nil, host, nil),                          // nothing of the VM's for the host
        (false, host, host, nil),                         // the VM's own PC is the host-named one
        (false, "winlab01 (alex)", host, host),           // an early-stopped lookup can't disprove it
        (false, "winlab01 (alex)", nil, nil),
        (false, "winlab01 (alex)", "atelier.local", nil),
    ])
    func remembered(seen: Bool, mine: String?, previous: String?, expected: String?) {
        let bookmark = mine.map { Bookmarks.Bookmark(name: $0, id: "X") }
        #expect(Recipe.otherAccountHost(mine: bookmark, host: host, seen: seen, previous: previous) == expected)
    }
}

@Suite("Saving beside another account's PC")
struct SavedPCAccountSaving {
    /// Two tiles described alike would leave Connect pressing either, so the new one's name is its own.
    @Test("The new PC gets a name of its own, never the host's")
    func ownName() {
        let existing = [stale]
        #expect(Bookmarks.newName("Windows 11", host: host, user: "alex", besideAnotherAccount: true, notIn: existing)
                == "Windows 11")
        // Winbar's create names a PC after the VM; the deleted VM's already has that name.
        #expect(Bookmarks.newName("winlab01", host: host, user: "alex", besideAnotherAccount: true, notIn: existing)
                == "winlab01 (alex)")
        #expect(Bookmarks.newName(host, host: host, user: "alex", besideAnotherAccount: true, notIn: [])
                == "winlab01.local (alex)")
        #expect(Bookmarks.newName(nil, host: host, user: "alex", besideAnotherAccount: true, notIn: existing)
                == "winlab01.local (alex)")
        // Without another account, as before: a taken name is given up and the tile matches on the host.
        #expect(Bookmarks.newName("winlab01", host: host, user: "alex", besideAnotherAccount: false, notIn: existing) == nil)
    }

    @Test("What save did says which PC is the VM's, and whether another account's was beside it")
    func savedCases() {
        let other = Bookmarks.OtherAccount(bookmark: stale, user: "morgan")
        #expect(Bookmarks.Saved.createdBeside(ours, otherAccount: other).bookmark == ours)
        #expect(Bookmarks.Saved.createdBeside(ours, otherAccount: other).otherAccount == other)
        #expect(Bookmarks.Saved.created(ours).otherAccount == nil)
        #expect(Bookmarks.Saved.alreadyThere(ours).bookmark == ours)
    }

    /// The end of an install tells Connect which tile is the new VM's, before setup has looked.
    @Test("create's selection carries the saved PC it wrote, and nothing when it wrote none")
    func createSelection() {
        let created = CreatedVM(vmID: "5B0F2A11", systemDiskID: "D1", windowsCDID: "C1", setupCDID: "C2",
                                mac: "52:54:00:12:34:56", networkShared: true, serial: .ptty, displays: 1,
                                cores: 6, memoryMiB: 16384)
        var state = testState()
        state.savedPCID = ours.id
        state.savedPCName = ours.name
        state.savedPCOtherAccountName = stale.name
        state.savedPCOtherAccountUser = "morgan"
        let planHost = CreateChoices.hostName(computerName: testPlan().computerName)
        let selection = CreateRun.selection(plan: testPlan(), created: created, bitLockerOn: nil, headless: false,
                                            state: state)
        // Written beside another account's PC: Connect keeps off tiles named after the host, and a
        // report masks the other PC's name and account.
        #expect(selection?.savedPC == SavedPCMemory(host: planHost, name: ours.name, otherAccountHost: planHost,
                                                    otherAccountName: stale.name, otherAccountUser: "morgan"))
        state.savedPCOtherAccountName = nil
        state.savedPCOtherAccountUser = nil
        #expect(CreateRun.selection(plan: testPlan(), created: created, bitLockerOn: nil, headless: false,
                                    state: state)?.savedPC == SavedPCMemory(host: planHost, name: ours.name))
        state.savedPCName = planHost.uppercased()   // named after the host: pressed by the host
        #expect(CreateRun.selection(plan: testPlan(), created: created, bitLockerOn: nil, headless: false,
                                    state: state)?.savedPC == SavedPCMemory(host: planHost))
        state.savedPCID = nil   // a cancel took it back
        #expect(CreateRun.selection(plan: testPlan(), created: created, bitLockerOn: nil, headless: false,
                                    state: state)?.savedPC == nil)
    }

    /// Saving beside another account's PC is remembered as C2 seeing it would be: `Setup.savePC`
    /// hands over `lookup`, whole.
    @Test("What save did becomes the lookup that is remembered")
    func savedLookup() {
        let other = Bookmarks.OtherAccount(bookmark: stale, user: "morgan")
        #expect(Bookmarks.Saved.createdBeside(ours, otherAccount: other).lookup == Bookmarks.Lookup(mine: ours, otherAccount: other))
        #expect(Bookmarks.Saved.created(ours).lookup == Bookmarks.Lookup(mine: ours, otherAccount: nil))
        #expect(Bookmarks.Saved.alreadyThere(ours).lookup == Bookmarks.Lookup(mine: ours, otherAccount: nil))
        let remembered = Recipe.savedPCMemory(after: Bookmarks.Saved.createdBeside(ours, otherAccount: other).lookup,
                                              host: host, previous: SavedPCMemory())
        #expect(remembered == SavedPCMemory(host: host, name: ours.name, otherAccountHost: host,
                                            otherAccountName: stale.name, otherAccountUser: "morgan"))
    }

    @Test("The new settings are one VM's, and a report masks what they hold")
    func setting() {
        for key in [Config.Key.savedPCOtherAccountHost, Config.Key.savedPCOtherAccountName,
                    Config.Key.savedPCOtherAccountUser] {
            #expect(Config.Key.perVM.contains(key))
            #expect(Config.Key.all.contains(key))
        }
        #expect(Diagnose.windowsPCNamesFromSettings(["vm.a.savedPCOtherAccountHost": "oldbox.local"]) == ["oldbox"])
        #expect(Diagnose.windowsPCNamesFromSettings(["vm.a.savedPCOtherAccountName": "Hallway PC"]) == ["Hallway PC"])
        #expect(Diagnose.windowsUserNames(["vm.a.savedPCOtherAccountUser": "morgan"]) == ["morgan"])
    }

    /// C2's row names the other account ("belongs to another account (morgan)") and its saved PC by
    /// the name someone typed — here, a person's name — so an anonymised report masks both.
    @Test("An anonymised report masks the other account C2 names, and its saved PC's name")
    func reportMasksTheOtherAccount() {
        let custom = Bookmarks.Bookmark(name: "Priya Okafor's Desk", id: "8B1F0C52-0000-4E2A-9A11-DEADBEEF0005")
        let row = Recipe.savedPCStatus(.init(mine: nil, otherAccount: .init(bookmark: custom, user: "priya.o")),
                                       host: host, user: "alex", windowsAppRunning: false).detail
        #expect(row.contains("Priya Okafor's Desk") && row.contains("priya.o"))

        // From the settings an earlier run recorded, with nothing from this report's own doctor run.
        let settings: [String: Any] = ["vm.a.rdpUser": "alex", "vm.a.savedPCOtherAccountHost": host,
                                       "vm.a.savedPCOtherAccountName": custom.name,
                                       "vm.a.savedPCOtherAccountUser": "priya.o"]
        let fromSettings = Redactor(mode: .anonymised, identity: .init(
            userName: "rosa", computerName: "atelier",
            windowsUsers: Array(Diagnose.reportedWindowsUsers(settings: settings, checked: [], guestUser: nil,
                                                             otherSavedPCUsers: [])),
            windowsPCNames: Diagnose.windowsPCNames(settings: settings, checked: [], guestOutput: nil,
                                                    otherSavedPCNames: [])))
        #expect(!fromSettings.apply(row).contains("Priya"), "\(fromSettings.apply(row))")
        #expect(!fromSettings.apply(row).contains("priya.o"))

        // From this report's own C2 alone, with nothing in the settings: its run writes none.
        let fromSightings = Redactor(mode: .anonymised, identity: .init(
            userName: "rosa", computerName: "atelier",
            windowsUsers: Array(Diagnose.reportedWindowsUsers(settings: [:], checked: [], guestUser: nil,
                                                             otherSavedPCUsers: ["priya.o"])),
            windowsPCNames: Diagnose.windowsPCNames(settings: [:], checked: [], guestOutput: nil,
                                                    otherSavedPCNames: [custom.name])))
        #expect(!fromSightings.apply(row).contains("Priya"), "\(fromSightings.apply(row))")
        #expect(!fromSightings.apply(row).contains("priya.o"))
    }

    /// The report's doctor run tells the redactor what its C2 saw from the thread running it, so the
    /// names are known even when the table misses its deadline and its Context can't be read.
    @Test("What the report's C2 sees reaches the redactor, whether or not the table finishes")
    func sightingsReachTheRedactor() {
        let sightings = Diagnose.Sightings()
        var options = Diagnose.doctorOptions(sightings: sightings)
        options.vmOverride = "fictional-report-vm"   // never the settings of the Mac running the tests
        let ctx = Context(options: options)
        let other = Bookmarks.OtherAccount(bookmark: stale, user: "morgan")
        ctx.note(savedPCs: .success(.init(mine: ours, otherAccount: other)))
        ctx.note(savedPCs: .success(.init(mine: ours, otherAccount: nil)))
        ctx.note(savedPCs: .failure(.failed(what: "list its saved PCs", output: "timed out")))
        #expect(sightings.all == [other])
        // And the answer is the one the rest of the run reads, without asking Windows App again.
        #expect((try? ctx.savedPC(for: host, user: "alex").get()) == nil)

        // From there to the redactor: `identity` reads the real settings, so no test may call it,
        // and its joins are read as text.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let diagnose = (try? String(contentsOf: root.appendingPathComponent("Sources/Winbar/Diagnose.swift"),
                                    encoding: .utf8)) ?? ""
        for wiring in ["otherSavedPCs: sightings.all)", "identity(doctor.context, otherSavedPCs: doctor.otherSavedPCs)",
                       "otherSavedPCUsers: otherSavedPCs.map(\\.user))",
                       "otherSavedPCNames: otherSavedPCs.map(\\.bookmark.name))"] {
            #expect(diagnose.contains(wiring), "\(wiring)")
        }
    }

    /// The install log goes into reports, so it no longer names the other PC at all.
    @Test("The install log doesn't name the other account's saved PC")
    func installLog() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let run = try String(contentsOf: root.appendingPathComponent("Sources/Winbar/CreateJobRun.swift"), encoding: .utf8)
        let line = try #require(run.split(separator: "\n").first { $0.contains("signs in as another account alone") })
        #expect(!line.contains("bookmark.name"))
    }
}

/// Reading Windows App's exports, over a fake: nothing here runs Windows App.
@Suite("The lookup reads every saved PC it needs, and no more")
struct SavedPCAccountExports {
    /// The exports a fake Windows App prints, and a note of which it was asked for.
    private final class FakeExports {
        var texts: [String: String]
        private(set) var asked: [String] = []
        init(_ texts: [String: String]) { self.texts = texts }
        func export(_ id: String) throws -> String {
            asked.append(id)
            guard let text = texts[id] else { throw Bookmarks.Failure.failed(what: "export", output: "no such PC") }
            return text
        }
    }

    private let exports = [stale.id: export(host: host, user: "morgan"), ours.id: export(host: host, user: "alex")]

    /// The live order: the deleted VM's saved PC was made first, so Windows App lists it first.
    /// Stopping at the first PC for the host would never read the VM's own, and C2 would say
    /// "another account" and save yet another PC on every run.
    @Test("A stale PC listed first doesn't hide the VM's own")
    func staleFirst() throws {
        let fake = FakeExports(exports)
        let found = try Bookmarks.savedPC(for: host, user: "alex", list: { [stale, ours] }, export: fake.export)
        #expect(found == Bookmarks.Lookup(mine: ours, otherAccount: .init(bookmark: stale, user: "morgan")))
        #expect(fake.asked == [stale.id, ours.id])
    }

    /// Once the VM's own is read, the rest can't change which one Connect presses.
    @Test("The reading stops at the VM's own saved PC: host and account")
    func stopsAtTheVMsOwn() throws {
        let fake = FakeExports(exports)
        let found = try Bookmarks.savedPC(for: host, user: "alex", list: { [ours, stale] }, export: fake.export)
        #expect(found == Bookmarks.Lookup(mine: ours, otherAccount: nil))
        #expect(fake.asked == [ours.id])
    }

    @Test("With no account to compare, the first PC for the host ends it, as before")
    func noAccount() throws {
        let fake = FakeExports(exports)
        let found = try Bookmarks.savedPC(for: host, user: nil, list: { [stale, ours] }, export: fake.export)
        #expect(found.mine == stale)
        #expect(fake.asked == [stale.id])
    }

    @Test("A PC for another host, or one that won't export, doesn't end it")
    func carriesOn() throws {
        let elsewhere = Bookmarks.Bookmark(name: "atelier", id: "8B1F0C52-0000-4E2A-9A11-DEADBEEF0003")
        let broken = Bookmarks.Bookmark(name: "broken", id: "8B1F0C52-0000-4E2A-9A11-DEADBEEF0004")
        var texts = exports
        texts[elsewhere.id] = export(host: "atelier.local", user: "alex")
        let fake = FakeExports(texts)
        let found = try Bookmarks.savedPC(for: host, user: "alex", list: { [elsewhere, broken, ours, stale] },
                                          export: fake.export)
        #expect(found.mine == ours)
        #expect(fake.asked == [elsewhere.id, broken.id, ours.id])
    }
}

@Suite("What is remembered about a saved PC is stored as one")
struct SavedPCAccountStorage {
    /// Each part in its own per-VM setting, and every part written each time, so a part an earlier
    /// lookup left can't outlive the lookup that replaced it.
    @Test("All five parts go to the VM's own settings, and a part that is none is removed")
    func roundTrip() {
        let store = MemoryStore(["vm.T1.savedPCOtherAccountName": "Stale name", "vm.T2.savedPCHost": "other.local"])
        let memory = SavedPCMemory(host: host, name: ours.name, otherAccountHost: host, otherAccountName: stale.name,
                                   otherAccountUser: "morgan")
        VMSettings.setSavedPC(memory, of: "T1", in: store)
        #expect(VMSettings.savedPC(of: "T1", in: store) == memory)
        #expect(store.string(Config.Key.savedPCHost, "T1") == host)
        #expect(store.string(Config.Key.savedPCName, "T1") == ours.name)
        #expect(store.string(Config.Key.savedPCOtherAccountHost, "T1") == host)
        #expect(store.string(Config.Key.savedPCOtherAccountName, "T1") == stale.name)
        #expect(store.string(Config.Key.savedPCOtherAccountUser, "T1") == "morgan")

        VMSettings.setSavedPC(SavedPCMemory(host: host), of: "T1", in: store)
        #expect(VMSettings.savedPC(of: "T1", in: store) == SavedPCMemory(host: host))
        #expect(store.values.keys.filter { $0.hasPrefix("vm.T1.") } == ["vm.T1.savedPCHost"])
        // Another VM's are its own.
        #expect(VMSettings.savedPC(of: "T2", in: store) == SavedPCMemory(host: "other.local"))
    }
}

/// A Mac that upgraded: before, C2 remembered a saved PC by host alone, and Connect reads only what
/// is remembered. Without a mark, Connect kept pressing the stale tile until setup or doctor looked.
@Suite("Upgrading marks every saved PC remembered by host alone")
struct SavedPCAccountUpgrade {
    private let id = "5B0F2A11-7C3D-4E5F-8A9B-0C1D2E3F4A5B"

    @Test("Each VM with a remembered saved PC is marked, once, and nothing else is touched")
    func marksOnce() {
        let store = MemoryStore([
            "vm.\(id).savedPCHost": host, "vm.\(id).savedPCName": "winlab01",      // pressed by name
            "vm.atelier.savedPCHost": "atelier.local",                              // pressed by the host
            "vm.atelier.rdpUser": "morgan",
            "vm.nosaved.rdpHost": "nosaved.local",                                  // never had one
            "vm.seen.savedPCHost": "seen.local", "vm.seen.savedPCOtherAccountHost": "seen.local",
            "vm.seen.savedPCOtherAccountUser": "robin",                              // a lookup already saw it
        ])
        #expect(Set(VMSettings.migrateSavedPCAccounts(in: store)) == [id, "atelier"])
        #expect(store.string(Config.Key.savedPCOtherAccountHost, id) == host)
        #expect(store.string(Config.Key.savedPCOtherAccountHost, "atelier") == "atelier.local")
        #expect(store.string(Config.Key.savedPCOtherAccountHost, "nosaved") == nil)
        #expect(VMSettings.savedPC(of: "seen", in: store)
                == SavedPCMemory(host: "seen.local", otherAccountHost: "seen.local", otherAccountUser: "robin"))
        #expect(store.values[Config.Key.savedPCAccountsMigrated] as? Bool == true)

        // Once: a saved PC remembered afterwards comes from a lookup that told accounts apart.
        store.set("later.local", forKey: VMSettings.key(Config.Key.savedPCHost, for: "later"))
        #expect(VMSettings.migrateSavedPCAccounts(in: store).isEmpty)
        #expect(store.string(Config.Key.savedPCOtherAccountHost, "later") == nil)
    }

    @Test("A Mac with nothing remembered is only marked as done")
    func freshMac() {
        let store = MemoryStore()
        #expect(VMSettings.migrateSavedPCAccounts(in: store).isEmpty)
        #expect(store.values.keys.sorted() == [Config.Key.savedPCAccountsMigrated])
    }

    /// Until C2 looks again, the stale tile is never pressed: a saved PC with a name of its own is,
    /// and otherwise Connect opens a one-off connection.
    @Test("After the mark, Connect presses only a saved PC with a name of its own")
    func connectAfterTheMark() {
        let store = MemoryStore(["vm.a.savedPCHost": host, "vm.b.savedPCHost": host, "vm.b.savedPCName": "Studio"])
        VMSettings.migrateSavedPCAccounts(in: store)
        let a = VMSettings.savedPC(of: "a", in: store)
        let b = VMSettings.savedPC(of: "b", in: store)
        #expect(WindowsApp.tileNames(host: host, savedName: a.name, otherAccountHost: a.otherAccountHost).isEmpty)
        #expect(WindowsApp.tileNames(host: host, savedName: b.name, otherAccountHost: b.otherAccountHost) == ["Studio"])
    }

    /// C2 answered: the mark is replaced by what it saw.
    @Test("C2's next lookup settles the mark")
    func lookupSettles() {
        let marked = SavedPCMemory(host: host, otherAccountHost: host)
        let hostNamed = Bookmarks.Bookmark(name: host, id: "C")
        #expect(Recipe.savedPCMemory(after: .init(mine: hostNamed, otherAccount: nil), host: host, previous: marked)
                == SavedPCMemory(host: host))
        #expect(Recipe.savedPCMemory(after: .init(mine: nil, otherAccount: .init(bookmark: stale, user: "morgan")),
                                     host: host, previous: marked)
                == SavedPCMemory(otherAccountHost: host, otherAccountName: stale.name, otherAccountUser: "morgan"))
    }

    /// Where Windows App never answers, the mark would stand for good and Connect would ask for the
    /// password every time on a Mac whose saved PC was fine. The person's word stands there, as it
    /// always did; a mark a lookup really made stays.
    @Test("Where Windows App won't answer, the upgrade's mark goes and a real sighting stays")
    func noAnswer() {
        let marked = SavedPCMemory(host: host, name: "Studio", otherAccountHost: host)
        #expect(Recipe.savedPCMemory(unanswered: marked, host: host) == SavedPCMemory(host: host, name: "Studio"))
        let seen = SavedPCMemory(host: host, otherAccountHost: host, otherAccountName: stale.name, otherAccountUser: "morgan")
        #expect(Recipe.savedPCMemory(unanswered: seen, host: host) == seen)
        let elsewhere = SavedPCMemory(host: host, otherAccountHost: "atelier.local")
        #expect(Recipe.savedPCMemory(unanswered: elsewhere, host: host) == elsewhere)
    }

    /// A lookup saw another account's PC for the host, then Windows App's command line stopped
    /// answering. The silent card says to edit that PC so it signs in as this VM's account; the person
    /// did, and chose I've Saved the PC. The mark stood (a lookup had really seen it), Connect pressed
    /// no tile at all, and every connection asked for the password. Their word settles it for that
    /// host, and only that host. The control is `savedPCMemory(savedByHand:)` keeping the mark, as
    /// setting `savedPCHost` alone did: no tile to press.
    @Test("I've Saved the PC, with Windows App silent, settles another account's mark for that host")
    func savedByHand() {
        let seen = SavedPCMemory(otherAccountHost: host, otherAccountName: stale.name, otherAccountUser: "morgan")
        #expect(WindowsApp.tileNames(host: host, savedName: seen.name, otherAccountHost: seen.otherAccountHost).isEmpty)
        let told = Recipe.savedPCMemory(savedByHand: seen, host: host)
        #expect(told == SavedPCMemory(host: host))
        #expect(WindowsApp.tileNames(host: host, savedName: told.name, otherAccountHost: told.otherAccountHost) == [host])
        // The no-answer read that follows the press keeps the word.
        #expect(Recipe.savedPCMemory(unanswered: told, host: host) == told)
        // Another host's mark, and a name the person gave, are left as they were.
        let elsewhere = SavedPCMemory(name: "Studio", otherAccountHost: "atelier.local", otherAccountUser: "rosa")
        #expect(Recipe.savedPCMemory(savedByHand: elsewhere, host: host)
                == SavedPCMemory(host: host, name: "Studio", otherAccountHost: "atelier.local", otherAccountUser: "rosa"))
    }

    /// The migration runs with the settings migration, before anything reads a per-VM setting, and
    /// C2's no-answer branch clears the mark. Both run against the Mac's own settings or Windows App,
    /// so they are read as text.
    @Test("The mark is made at first use, and C2's no-answer branch settles it")
    func wiring() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let config = try String(contentsOf: root.appendingPathComponent("Sources/Winbar/Config.swift"), encoding: .utf8)
        let migration = try #require(config.range(of: "private static let migration: Void = {"))
        #expect(config[migration.upperBound...].prefix(500).contains("VMSettings.migrateSavedPCAccounts(in: defaults)"))
        let recipe = try String(contentsOf: root.appendingPathComponent("Sources/Winbar/Recipe.swift"), encoding: .utf8)
        let failure = try #require(recipe.range(of: "// Windows App wouldn't say. Fall back to what Winbar has seen and been told"))
        #expect(recipe[failure.upperBound...].prefix(200).contains("Recipe.rememberNoAnswer(host: host, for: ctx)"))
        // I've Saved the PC, when Windows App won't say, records the person's word through the rule above.
        #expect(recipe.contains("Recipe.rememberSavedByHand(host: host, for: ctx)"))
        #expect(recipe.contains("updateSavedPC(for: ctx) { savedPCMemory(savedByHand: $0, host: host) }"))
    }

    @Test("The mark's own setting is this copy of Winbar's, not a VM's")
    func setting() {
        #expect(Config.Key.all.contains(Config.Key.savedPCAccountsMigrated))
        #expect(!Config.Key.perVM.contains(Config.Key.savedPCAccountsMigrated))
    }
}
