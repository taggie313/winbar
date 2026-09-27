import Foundation
import Testing
@testable import Winbar

// A VM chosen by an id UTM no longer has.
//
// Live (0.5.0): the owner had deleted a VM called "Windows 11" in UTM and made another with the same
// name, so two records carried it — the deleted VM's (host and user only) and the live one's (all the
// real settings). `winbar config --vm "Windows 11"` had only the name, took the first record with it,
// and that was the deleted VM's id. H2 matched by name and said ✓; every check after it looked for
// that id, found nothing and said "needs a VM (H2)". Everything here is pure, over invented VM lists
// and an in-memory store: nothing asks UTM or touches the settings of the Mac the tests run on.

private let staleID = "5B0F2A11-0000-4000-8000-00000000000A"
private let liveID = "5B0F2A11-0000-4000-8000-00000000000B"
private let live = VMInfo(id: liveID, name: "Windows 11", status: "started", backend: "qemu", icon: "windows",
                          architecture: "aarch64")
/// Another VM UTM lists under the same name, for the case nobody can settle but the person.
private let twin = VMInfo(id: "5B0F2A11-0000-4000-8000-00000000000C", name: "Windows 11", status: "stopped",
                          backend: "qemu", icon: "windows", architecture: "aarch64")
private let other = VMInfo(id: "5B0F2A11-0000-4000-8000-00000000000D", name: "winlab02", status: "stopped",
                           backend: "qemu", icon: "windows", architecture: "aarch64")
/// The VM Winbar looked after, renamed in UTM rather than deleted, with its old name given to `live`.
private let renamed = VMInfo(id: staleID, name: "Windows 11 old", status: "stopped", backend: "qemu",
                             icon: "windows", architecture: "aarch64")
/// A VM with the name on UTM's Apple Virtualization backend, which Winbar can't manage.
private let apple = VMInfo(id: "5B0F2A11-0000-4000-8000-00000000000E", name: "Windows 11", status: "stopped",
                           backend: "apple", icon: "windows", architecture: "aarch64")

@Suite("winbar config --vm takes UTM's id for the name")
struct StaleVMIDResolver {
    @Test("One VM by that name: its id")
    func oneMatch() {
        let chosen = Config.listedID(for: "Windows 11", in: [other, live])
        #expect(chosen.id == liveID)
        #expect(chosen.note == nil)
        // The live case: Winbar still held the deleted VM's id, and UTM's id replaces it.
        #expect(Config.listedID(for: "Windows 11", in: [other, live], current: staleID).id == liveID)
    }

    /// A VM can be chosen before it is made, as it always could: the name goes in alone.
    @Test("No VM by that name: the name alone, and a line saying so")
    func noMatch() {
        for listed in [[other], []] {
            let chosen = Config.listedID(for: "Windows 11", in: listed)
            #expect(chosen.id == nil)
            #expect(chosen.note?.contains("UTM has no VM named Windows 11 yet") == true, "\(chosen.note ?? "")")
        }
    }

    @Test("Several VMs by that name: no guess, and a line asking for a rename")
    func duplicates() {
        let chosen = Config.listedID(for: "Windows 11", in: [live, other, twin])
        #expect(chosen.id == nil)
        let note = chosen.note ?? ""
        #expect(note.contains("UTM has 2 VMs named Windows 11"), "\(note)")
        #expect(note.contains("Give each a name of its own in UTM"), "\(note)")
    }

    /// Rather than trade the id Winbar has for whichever record the name finds first.
    @Test("Several VMs by that name, one of them the VM Winbar looks after: that one")
    func duplicatesKeepCurrent() {
        let chosen = Config.listedID(for: "Windows 11", in: [live, other, twin], current: twin.id)
        #expect(chosen.id == twin.id)
        #expect(chosen.note?.contains("Winbar goes on looking after the one it was") == true, "\(chosen.note ?? "")")
        // An id that is none of them is no reason to pick one.
        for current in [other.id, staleID] {
            #expect(Config.listedID(for: "Windows 11", in: [live, other, twin], current: current).id == nil)
        }
    }

    @Test("UTM didn't answer: the name alone, as before, and nothing said")
    func notAnswering() {
        let chosen = Config.listedID(for: "Windows 11", in: nil)
        #expect(chosen.id == nil)
        #expect(chosen.note == nil)
    }
}

@Suite("H2 notices a VM made again under the same name")
struct StaleVMIDStatus {
    /// The live case.
    @Test("An id UTM no longer has, beside a VM with the name: fixable, by choosing that VM")
    func madeAgain() {
        let status = Recipe.vmStatus(name: "Windows 11", id: staleID, in: [other, live])
        #expect(status.isFixable)
        #expect(status.detail == "Winbar still points at an earlier VM called Windows 11 that UTM no longer has; "
            + "setup can switch to the one UTM has now")
        #expect(Recipe.vmToChoose(name: "Windows 11", id: staleID, in: [other, live]) == live)
    }

    @Test("The id UTM lists: ok, as before")
    func rightID() {
        let status = Recipe.vmStatus(name: "Windows 11", id: liveID, in: [other, live])
        #expect(status.isOK)
        #expect(status.detail == "Windows 11, started")
        #expect(Recipe.vmToChoose(name: "Windows 11", id: liveID, in: [other, live]) == nil)
    }

    @Test("No id: chosen by name, ok as before")
    func noID() {
        let status = Recipe.vmStatus(name: "Windows 11", id: nil, in: [other, live])
        #expect(status.isOK)
        #expect(status.detail == "Windows 11, started")
        #expect(Recipe.vmToChoose(name: "Windows 11", id: nil, in: [other, live]) == nil)
    }

    /// Whatever the id: with no VM by the name there is nothing to switch to.
    @Test("No VM by that name: the manual step it always was")
    func nameAbsent() {
        for id in [nil, staleID] {
            let status = Recipe.vmStatus(name: "Windows 11", id: id, in: [other])
            guard case .manual(let detail, let how) = status else {
                Issue.record("expected manual, got \(status.detail)")
                continue
            }
            #expect(detail == "UTM has no VM named Windows 11")
            #expect(how == "winbar config --vm <name>   (UTM has: winlab02)")
            #expect(Recipe.vmToChoose(name: "Windows 11", id: id, in: [other]) == nil)
        }
    }

    @Test("An id UTM no longer has, and several VMs with the name: the person says which")
    func staleAndDuplicated() {
        let status = Recipe.vmStatus(name: "Windows 11", id: staleID, in: [live, twin])
        guard case .manual(let detail, let how) = status else {
            Issue.record("expected manual, got \(status.detail)")
            return
        }
        #expect(detail.contains("UTM has 2 VMs by that name"), "\(detail)")
        #expect(how.contains("Give each a name of its own in UTM"), "\(how)")
        #expect(Recipe.vmToChoose(name: "Windows 11", id: staleID, in: [live, twin]) == nil)
    }

    /// Switching would only trade this row for the backend's error below it.
    @Test("An id UTM no longer has, and only an Apple Virtualization VM with the name: its error, no switch")
    func staleAndNotQEMU() {
        let status = Recipe.vmStatus(name: "Windows 11", id: staleID, in: [apple])
        guard case .error(let detail) = status else {
            Issue.record("expected error, got \(status.detail)")
            return
        }
        #expect(detail == "Windows 11 uses UTM's Apple Virtualization backend; Winbar manages QEMU VMs")
        #expect(Recipe.vmToChoose(name: "Windows 11", id: staleID, in: [apple]) == nil)
    }

    /// The same symptom as the live case, but both VMs are there, so only the person can say which.
    @Test("The id listed under another name, and the name under another id: the person says which")
    func renamedAndReplaced() {
        let status = Recipe.vmStatus(name: "Windows 11", id: staleID, in: [renamed, live])
        guard case .manual(let detail, let how) = status else {
            Issue.record("expected manual, got \(status.detail)")
            return
        }
        #expect(detail == "Winbar looks after the VM UTM now calls Windows 11 old; Windows 11 is another VM")
        #expect(how == "winbar config --vm \"Windows 11 old\" to keep it, or winbar config --vm \"Windows 11\" for the other one.")
        #expect(Recipe.vmToChoose(name: "Windows 11", id: staleID, in: [renamed, live]) == nil)
    }

    /// Several with the name and the id one of them: the row describes the VM every other check
    /// uses (`Context.vm`), not whichever UTM listed first.
    @Test("Several VMs with the name and the id one of them: that one")
    func duplicatedWithRightID() {
        let status = Recipe.vmStatus(name: "Windows 11", id: twin.id, in: [live, twin])
        #expect(status.isOK)
        #expect(status.detail == "Windows 11, stopped")
    }

    @Test("None chosen: the only Windows VM, as before")
    func noneChosen() {
        #expect(Recipe.vmStatus(name: nil, id: nil, in: [live]).isFixable)
        #expect(Recipe.vmToChoose(name: nil, id: nil, in: [live]) == live)
        #expect(Recipe.vmStatus(name: nil, id: nil, in: [live, other]).isManual)
        #expect(Recipe.vmToChoose(name: nil, id: nil, in: [live, other]) == nil)
    }

    /// Every list the two grid tests below walk: the cases above, and mixtures of them.
    static let lists = [[], [live], [other], [live, other], [live, twin], [other, live, twin], [apple],
                        [apple, live], [renamed], [renamed, live], [renamed, live, twin]]
    static let names = [nil, "Windows 11", "Windows 11 old", "winlab02"]
    static let ids = [nil, staleID, liveID, other.id]

    /// The fix has a VM to choose exactly when the row says it can.
    @Test("Fixable if and only if there is one VM to choose")
    func fixableMeansAChoice() {
        for list in Self.lists {
            for name in Self.names {
                for id in Self.ids {
                    let fixable = Recipe.vmStatus(name: name, id: id, in: list).isFixable
                    let choice = Recipe.vmToChoose(name: name, id: id, in: list)
                    #expect(fixable == (choice != nil), "\(name ?? "none") \(id ?? "no id") in \(list.map(\.name))")
                }
            }
        }
    }

    /// The live bug was this row saying ✓ while every check after it found no VM. `Facts.chosen`
    /// is the window's copy of `Context.vm`'s rule (the name's VM, and the id's when there is one),
    /// which can be given a list without asking UTM.
    @Test("OK only for a VM the checks after it find too")
    func okMeansTheChecksFindIt() {
        for list in Self.lists {
            for name in Self.names {
                for id in Self.ids where Recipe.vmStatus(name: name, id: id, in: list).isOK {
                    var facts = SetupFlow.Facts()
                    facts.vms = .listed(list)
                    facts.chosenVM = name
                    facts.chosenID = id
                    #expect(facts.chosen != nil, "\(name ?? "none") \(id ?? "no id") in \(list.map(\.name))")
                }
            }
        }
    }

    /// The window says what H2 says, rather than that UTM has no VM by a name it lists below.
    @Test("The set-up window's VM step says the VM was made again, or renamed")
    func windowSaysMadeAgain() {
        var facts = SetupFlow.Facts()
        facts.vms = .listed([live])
        facts.chosenVM = "Windows 11"
        facts.chosenID = staleID
        #expect(SetupFlow.vm(facts) == .choose(.one(live), previous: .madeAgain("Windows 11")))
        facts.vms = .listed([renamed, live])
        #expect(SetupFlow.vm(facts) == .choose(SetupFlow.choice(in: [renamed, live]),
                                               previous: .renamed(from: "Windows 11", to: "Windows 11 old")))
        // Gone under that name too: it is gone, as before.
        facts.vms = .listed([other])
        #expect(SetupFlow.vm(facts) == .choose(.one(other), previous: .gone("Windows 11")))
    }
}

/// `MemoryStore`'s contract, answering `allKeys` in the order the keys were first written rather
/// than a dictionary's, which changes from run to run: so the deleted VM's record can come first,
/// as it did on the owner's Mac, every time.
private final class OrderedStore: SettingsStore {
    private var keys: [String] = []
    private var values: [String: Any] = [:]

    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any?, forKey key: String) {
        guard let value else { return removeObject(forKey: key) }
        if values[key] == nil { keys.append(key) }
        values[key] = value
    }
    func removeObject(forKey key: String) {
        values.removeValue(forKey: key)
        keys.removeAll { $0 == key }
    }
    func allKeys() -> [String] { keys }

    func string(_ setting: String, _ token: String) -> String? {
        values[VMSettings.key(setting, for: token)] as? String
    }
}

@Suite("Choosing the live VM keeps the deleted one's record")
struct StaleVMIDRecords {
    /// The owner's settings file: two records with the same name, the deleted VM's first.
    private func twoRecords() -> OrderedStore {
        let store = OrderedStore()
        store.set("windows11.local", forKey: VMSettings.key(Config.Key.rdpHost, for: staleID))
        store.set("morgan", forKey: VMSettings.key(Config.Key.rdpUser, for: staleID))
        VMSettings.remember(name: "Windows 11", for: staleID, in: store)
        store.set("windows11.local", forKey: VMSettings.key(Config.Key.rdpHost, for: liveID))
        store.set("alex", forKey: VMSettings.key(Config.Key.rdpUser, for: liveID))
        store.set("/Users/alex/Shared", forKey: VMSettings.key(Config.Key.sharedFolder, for: liveID))
        store.set("windows11.local", forKey: VMSettings.key(Config.Key.savedPCHost, for: liveID))
        VMSettings.remember(name: "Windows 11", for: liveID, in: store)
        return store
    }

    /// The live bug: by name alone the first record with the name comes back, and that was the
    /// deleted VM's. Which is why the id has to come from UTM.
    @Test("By name alone the deleted VM's record comes back")
    func nameAloneFindsTheDeletedVM() {
        let store = twoRecords()
        #expect(VMSettings.id(forName: "Windows 11", in: store) == staleID)
        #expect(VMSettings.select(name: "Windows 11", id: nil, in: store).id == staleID)
    }

    @Test("UTM's id lands on the live record, and the deleted VM's stays as it was")
    func liveIDLandsOnLiveRecord() {
        let store = twoRecords()
        let id = Config.listedID(for: "Windows 11", in: [other, live], current: staleID).id
        let chosen = VMSettings.select(name: "Windows 11", id: id, in: store)
        #expect(chosen.id == liveID)
        #expect(chosen.token == liveID)
        #expect(store.string(Config.Key.rdpUser, chosen.token) == "alex")
        #expect(store.string(Config.Key.sharedFolder, chosen.token) == "/Users/alex/Shared")
        #expect(store.string(Config.Key.savedPCHost, chosen.token) == "windows11.local")
        // Nothing moved or went: records are only ever destroyed on purpose (`Config.forget`).
        #expect(VMSettings.hasRecord(staleID, in: store))
        #expect(store.string(Config.Key.rdpHost, staleID) == "windows11.local")
        #expect(store.string(Config.Key.rdpUser, staleID) == "morgan")
        #expect(VMSettings.recordedName(of: staleID, in: store) == "Windows 11")
        // And no third record under the name.
        #expect(!VMSettings.hasRecord("Windows 11", in: store))
        #expect(VMSettings.recordedName(of: "Windows 11", in: store) == nil)
    }
}
