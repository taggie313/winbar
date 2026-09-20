import Foundation
import Testing
@testable import Winbar

// Pure logic only. Nothing here may reach UTM, a VM, the keychain, TCC or the user's defaults —
// which is exactly why the per-VM settings are written against `SettingsStore`: every test below
// runs on its own dictionary, and `Config.defaults` is never opened.

/// The store the real thing uses is `UserDefaults`; this is the same contract over a dictionary.
final class MemoryStore: SettingsStore {
    private(set) var values: [String: Any] = [:]

    init(_ values: [String: Any] = [:]) { self.values = values }

    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values.removeValue(forKey: key) }
    func allKeys() -> [String] { Array(values.keys) }

    func string(_ setting: String, _ token: String) -> String? {
        values[VMSettings.key(setting, for: token)] as? String
    }
}

@Suite struct PerVMKeys {
    @Test func settingsAreNamedForTheVMTheyBelongTo() {
        #expect(VMSettings.key(Config.Key.rdpHost, for: "winlab01") == "vm.winlab01.rdpHost")
        let id = "ABCDEF01-2345-6789-ABCD-EF0123456789"
        #expect(VMSettings.key(Config.Key.vmMAC, for: id) == "vm.\(id).vmMAC")
        // No two VMs share a key, which is the whole point: one VM's MAC can never be read as another's.
        #expect(VMSettings.key(Config.Key.vmMAC, for: "a") != VMSettings.key(Config.Key.vmMAC, for: "b"))
    }

    /// A VM name may have dots in it ("Windows 11.1"), so the setting is read off the end of the key.
    @Test func keysAreSplitFromTheEnd() {
        let key = VMSettings.key(Config.Key.rdpUser, for: "Windows 11.1")
        #expect(key == "vm.Windows 11.1.rdpUser")
        let split = VMSettings.split(key)
        #expect(split?.token == "Windows 11.1")
        #expect(split?.setting == Config.Key.rdpUser)
    }

    @Test func onlyWinbarsOwnKeysAreRead() {
        #expect(VMSettings.split("vmName") == nil)
        #expect(VMSettings.split("vm.winlab01.somethingElse") == nil)
        #expect(VMSettings.split("vm..rdpHost") == nil)
        #expect(VMSettings.split("vm.winlab01.name")?.setting == Config.Key.recordedName)
    }

    /// The settings that describe a VM are the ones filed under it; the rest describe the Mac or
    /// this copy of Winbar and stay global.
    @Test func whatBelongsToAVMAndWhatDoesNot() {
        for setting in Config.Key.perVM { #expect(Config.Key.all.contains(setting)) }
        for setting in [Config.Key.vmMAC, Config.Key.rdpHost, Config.Key.rdpUser, Config.Key.savedPCName,
                        Config.Key.savedPCHost, Config.Key.consoleEnabled, Config.Key.bitLockerOn] {
            #expect(Config.Key.perVM.contains(setting), "\(setting) describes one VM")
        }
        for setting in [Config.Key.vmName, Config.Key.vmID, Config.Key.passwordCheckedFor,
                        Config.Key.lastUpdateCheck, Config.Key.lastSeenVersion, Config.Key.pendingUTMRestart,
                        Config.Key.offeredAccessibility, Config.Key.backupExclusionConfirmed,
                        Config.Key.settingsMigrated, Config.Key.recordedName] {
            #expect(!Config.Key.perVM.contains(setting), "\(setting) isn't one VM's")
        }
        // The name a VM was last seen under is bookkeeping: a VM with nothing else has no record.
        let store = MemoryStore()
        VMSettings.remember(name: "winlab01", for: "id-1", in: store)
        #expect(!VMSettings.hasRecord("id-1", in: store))
        store.set("72:F0:0A:01:02:03", forKey: VMSettings.key(Config.Key.vmMAC, for: "id-1"))
        #expect(VMSettings.hasRecord("id-1", in: store))
    }
}

@Suite struct PerVMMigration {
    /// What a 0.1.0 settings file holds: one global set of keys, the name of the VM they describe,
    /// what describes the Mac instead, and whatever else writes to the domain (AppKit saves the
    /// create window's frame in there).
    func upgraded() -> MemoryStore {
        MemoryStore([
            Config.Key.vmName: "winlab01",
            Config.Key.rdpHost: "winlab01.local",
            Config.Key.rdpUser: "rosa",
            Config.Key.vmMAC: "72:F0:0A:01:02:03",
            Config.Key.savedPCName: "Winlab",
            Config.Key.savedPCHost: "winlab01.local",
            Config.Key.consoleEnabled: false,
            Config.Key.bitLockerOn: true,
            Config.Key.bitLockerCheckedAt: Date(timeIntervalSince1970: 1_790_000_000),
            Config.Key.keepBitLocker: true,
            Config.Key.sharedFolder: "/Users/x/Shared-with-Windows",
            Config.Key.sharedFolderByWinbar: true,
            Config.Key.sharedFolderUTM: [14779],
            Config.Key.passwordCheckedFor: ["WINLAB01\\rosa"],
            Config.Key.lastUpdateCheck: Date(timeIntervalSince1970: 1_789_000_000),
            Config.Key.lastSeenVersion: "0.1.0",
            "NSWindow Frame winbar-create": "564 267 600 728 0 0 1728 1084 ",
        ])
    }

    @Test func everythingMovesToTheVMItDescribes() {
        let store = upgraded()
        let moved = VMSettings.migrate(name: "winlab01", id: nil, in: store)
        #expect(moved.contains(Config.Key.rdpHost) && moved.contains(Config.Key.vmMAC))
        #expect(store.string(Config.Key.rdpHost, "winlab01") == "winlab01.local")
        #expect(store.string(Config.Key.rdpUser, "winlab01") == "rosa")
        #expect(store.string(Config.Key.savedPCName, "winlab01") == "Winlab")
        #expect(store.object(forKey: VMSettings.key(Config.Key.consoleEnabled, for: "winlab01")) as? Bool == false)
        #expect(store.object(forKey: VMSettings.key(Config.Key.bitLockerOn, for: "winlab01")) as? Bool == true)
        #expect(store.object(forKey: VMSettings.key(Config.Key.keepBitLocker, for: "winlab01")) as? Bool == true)
        // The global keys are gone, so nothing can fall back to them for another VM.
        for setting in Config.Key.perVM { #expect(store.object(forKey: setting) == nil, "\(setting) left behind") }
        // Which VM is chosen, and what describes the Mac, stay where they are.
        #expect(store.object(forKey: Config.Key.vmName) as? String == "winlab01")
        #expect(store.object(forKey: Config.Key.passwordCheckedFor) as? [String] == ["WINLAB01\\rosa"])
        #expect(store.object(forKey: Config.Key.lastSeenVersion) as? String == "0.1.0")
        #expect(store.object(forKey: Config.Key.lastUpdateCheck) != nil)
        #expect(store.object(forKey: "NSWindow Frame winbar-create") != nil)
        // The shared folder and its two companions travel together, so the menu still knows whether
        // the share is Winbar's to rewrite.
        #expect(store.string(Config.Key.sharedFolder, "winlab01") == "/Users/x/Shared-with-Windows")
        #expect(store.object(forKey: VMSettings.key(Config.Key.sharedFolderByWinbar, for: "winlab01")) as? Bool == true)
        #expect(store.object(forKey: VMSettings.key(Config.Key.sharedFolderUTM, for: "winlab01")) as? [Int] == [14779])
        #expect(store.object(forKey: VMSettings.key(Config.Key.bitLockerCheckedAt, for: "winlab01")) as? Date != nil)
        // And the record can be found again by the name it was chosen under.
        #expect(VMSettings.recordedName(of: "winlab01", in: store) == "winlab01")
    }

    @Test func nothingChangesOnTheSecondRun() {
        let store = upgraded()
        VMSettings.migrate(name: "winlab01", id: nil, in: store)
        let before = store.values.keys.sorted()
        // A later run, with the host changed in between: the second migration must not resurrect
        // the value 0.1.0 had.
        store.set("renamed.local", forKey: VMSettings.key(Config.Key.rdpHost, for: "winlab01"))
        #expect(VMSettings.migrate(name: "winlab01", id: nil, in: store).isEmpty)
        #expect(store.values.keys.sorted() == before)
        #expect(store.string(Config.Key.rdpHost, "winlab01") == "renamed.local")
    }

    /// Killed half way: some values copied, none of the globals cleared yet. Both copies are whole,
    /// and the next run finishes the job without touching what has been written since.
    @Test func aHalfDoneMigrationIsFinishedNotUndone() {
        let store = upgraded()
        store.set("winlab01.local", forKey: VMSettings.key(Config.Key.rdpHost, for: "winlab01"))
        store.set("someone-else", forKey: VMSettings.key(Config.Key.rdpUser, for: "winlab01"))
        let moved = VMSettings.migrate(name: "winlab01", id: nil, in: store)
        #expect(moved.contains(Config.Key.rdpUser))
        // The namespaced value wins: it is the newer of the two, and the global is the stale copy.
        #expect(store.string(Config.Key.rdpUser, "winlab01") == "someone-else")
        #expect(store.string(Config.Key.vmMAC, "winlab01") == "72:F0:0A:01:02:03")
        for setting in Config.Key.perVM { #expect(store.object(forKey: setting) == nil) }
    }

    /// Nobody to give them to: left alone rather than handed to whichever VM is chosen next, which
    /// is the bug the per-VM keys exist to stop.
    @Test func settingsWithNoVMAreLeftWhereTheyAre() {
        let store = upgraded()
        store.removeObject(forKey: Config.Key.vmName)
        #expect(VMSettings.migrate(name: nil, id: nil, in: store).isEmpty)
        #expect(store.object(forKey: Config.Key.rdpHost) as? String == "winlab01.local")
        // And a VM chosen afterwards starts clean rather than inheriting them.
        let chosen = VMSettings.select(name: "winlab01", id: nil, in: store)
        #expect(!VMSettings.hasRecord(chosen.token, in: store))
        #expect(VMSettings.migrate(name: "winlab01", id: nil, in: store).isEmpty)
        #expect(store.string(Config.Key.rdpHost, "winlab01") == nil)
    }

    /// An upgrade that already knows the VM's id files the record under the id straight away.
    @Test func migratingWithAKnownIDUsesIt() {
        let store = upgraded()
        VMSettings.migrate(name: "winlab01", id: "id-1", in: store)
        #expect(store.string(Config.Key.rdpHost, "id-1") == "winlab01.local")
        #expect(store.string(Config.Key.rdpHost, "winlab01") == nil)
        #expect(VMSettings.recordedName(of: "id-1", in: store) == "winlab01")
    }
}

@Suite struct PerVMSwitching {
    func winlab01() -> MemoryStore {
        let store = MemoryStore()
        store.set("winlab01.local", forKey: VMSettings.key(Config.Key.rdpHost, for: "winlab01"))
        store.set("rosa", forKey: VMSettings.key(Config.Key.rdpUser, for: "winlab01"))
        store.set("72:F0:0A:01:02:03", forKey: VMSettings.key(Config.Key.vmMAC, for: "winlab01"))
        VMSettings.remember(name: "winlab01", for: "winlab01", in: store)
        return store
    }

    /// The bug this exists for: switching to another VM and back used to leave the first VM with
    /// nothing.
    @Test func switchingKeepsBothRecords() {
        let store = winlab01()
        let test = VMSettings.select(name: "winbar-test", id: "id-test", in: store)
        store.set("winbar-test.local", forKey: VMSettings.key(Config.Key.rdpHost, for: test.token))
        // Nothing of the VM being left has gone.
        #expect(store.string(Config.Key.rdpHost, "winlab01") == "winlab01.local")
        #expect(store.string(Config.Key.rdpUser, "winlab01") == "rosa")
        #expect(store.string(Config.Key.vmMAC, "winlab01") == "72:F0:0A:01:02:03")
        // And back again: the same record, not a fresh one.
        let back = VMSettings.select(name: "winlab01", id: nil, in: store)
        #expect(back.token == "winlab01")
        #expect(store.string(Config.Key.rdpHost, back.token) == "winlab01.local")
        #expect(store.string(Config.Key.rdpHost, test.token) == "winbar-test.local")
    }

    /// A record written before the id was known moves under the id, so renaming the VM in UTM
    /// afterwards doesn't lose it.
    @Test func learningTheIDAdoptsTheRecord() {
        let store = winlab01()
        let chosen = VMSettings.select(name: "winlab01", id: "id-1", in: store)
        #expect(chosen.token == "id-1")
        #expect(store.string(Config.Key.rdpHost, "id-1") == "winlab01.local")
        #expect(store.string(Config.Key.rdpHost, "winlab01") == nil)
        // Renamed in UTM, chosen again under the new name: still the same record.
        let renamed = VMSettings.select(name: "winlab", id: "id-1", in: store)
        #expect(renamed.token == "id-1")
        #expect(store.string(Config.Key.rdpUser, "id-1") == "rosa")
        #expect(VMSettings.recordedName(of: "id-1", in: store) == "winlab")
    }

    /// `winbar config --vm NAME` never asks UTM, so it has no id — and must still find the record
    /// the menu filed under one.
    @Test func aNameAloneStillFindsAnIDsRecord() {
        let store = winlab01()
        VMSettings.select(name: "winlab01", id: "id-1", in: store)
        let byName = VMSettings.select(name: "winlab01", id: nil, in: store)
        #expect(byName.id == "id-1")
        #expect(byName.token == "id-1")
        #expect(store.string(Config.Key.rdpHost, byName.token) == "winlab01.local")
    }

    /// A name whose record belongs to another VM is not taken over: adoption is only ever the
    /// pre-id record of the same VM.
    @Test func anotherVMsRecordIsNeverAdopted() {
        let store = winlab01()
        store.set("mine.local", forKey: VMSettings.key(Config.Key.rdpHost, for: "id-2"))
        #expect(!VMSettings.adopt(id: "id-2", name: "winlab01", in: store))
        #expect(store.string(Config.Key.rdpHost, "winlab01") == "winlab01.local")
        #expect(store.string(Config.Key.rdpHost, "id-2") == "mine.local")
        // And the VM with a record of its own reads its own, whatever the name says.
        #expect(VMSettings.token(name: "winlab01", id: "id-2", in: store) == "id-2")
    }

    /// With per-VM records there is nothing left to fall back to: a setting VM A hasn't got is
    /// missing, never VM B's. A MAC is the one that matters — it finds the DHCP lease, and so the
    /// address Winbar probes, trusts a certificate for and connects to.
    @Test func oneVMsSettingIsNeverAnothersFallback() {
        let store = winlab01()
        let newVM = VMSettings.select(name: "winbar-test", id: "id-test", in: store)
        #expect(store.string(Config.Key.vmMAC, newVM.token) == nil)
        #expect(store.string(Config.Key.rdpHost, newVM.token) == nil)
        #expect(store.string(Config.Key.savedPCHost, newVM.token) == nil)
        // The global keys a fallback would have read are not written by anything any more.
        for setting in Config.Key.perVM { #expect(store.object(forKey: setting) == nil) }
    }

    /// Deliberate forgetting is the only thing that destroys a record, and it takes both namespaces
    /// a VM can have with it.
    @Test func forgettingTakesEveryNamespaceTheVMHad() {
        let store = winlab01()
        VMSettings.select(name: "winlab01", id: "id-1", in: store)
        // A stray half-adopted record under the name as well, to be sure both go.
        store.set("stale.local", forKey: VMSettings.key(Config.Key.rdpHost, for: "winlab01"))
        store.set("keep.local", forKey: VMSettings.key(Config.Key.rdpHost, for: "id-other"))
        let tokens = VMSettings.tokens(forName: "winlab01", id: nil, in: store)
        #expect(tokens.contains("winlab01") && tokens.contains("id-1"))
        var forgotten: Set<String> = []
        for token in tokens { forgotten.formUnion(VMSettings.forget(token, in: store)) }
        #expect(forgotten.contains(Config.Key.rdpHost) && forgotten.contains(Config.Key.vmMAC))
        #expect(!VMSettings.hasRecord("id-1", in: store) && !VMSettings.hasRecord("winlab01", in: store))
        #expect(VMSettings.recordedName(of: "id-1", in: store) == nil)
        // Nobody else's record is touched.
        #expect(store.string(Config.Key.rdpHost, "id-other") == "keep.local")
    }

    @Test func forgettingSaysWhatWasThere() {
        let store = MemoryStore()
        #expect(VMSettings.forget("nothing-here", in: store).isEmpty)
        store.set("x.local", forKey: VMSettings.key(Config.Key.rdpHost, for: "id-1"))
        VMSettings.remember(name: "winlab01", for: "id-1", in: store)
        // The name it was last seen under is bookkeeping, not a setting anybody chose.
        #expect(VMSettings.forget("id-1", in: store) == [Config.Key.rdpHost])
        #expect(store.allKeys().isEmpty)
    }
}
