import Foundation
import Testing
@testable import Winbar

// Pure logic only. Nothing here runs Windows App: the command line was proven live, and a second
// writer on its Core Data store is exactly the risk `WindowsAppBookmarks` exists to refuse.

@Suite struct BookmarkListParsing {
    /// The shape `bookmark list` really prints: the quoted friendly-name-or-host, a comma, a space,
    /// then a UUID — not the 7-digit numbers in the app's own help examples.
    @Test func readsOneSavedPCPerLine() {
        let text = """
            "mypc.local", 8B1F0C52-0000-4E2A-9A11-DEADBEEF0002
            "Windows 11", 8B1F0C52-0000-4E2A-9A11-DEADBEEF0001
            """
        #expect(WindowsAppBookmarks.parseList(text) == [
            WindowsAppBookmarks.Bookmark(name: "mypc.local", id: "8B1F0C52-0000-4E2A-9A11-DEADBEEF0002"),
            WindowsAppBookmarks.Bookmark(name: "Windows 11", id: "8B1F0C52-0000-4E2A-9A11-DEADBEEF0001"),
        ])
    }

    /// The name is the person's, so it may hold the same comma that separates the two fields. The
    /// id can't hold a space, which is what settles where the name ends.
    @Test func keepsCommasAndUnicodeInsideTheName() {
        let text = """
            "Work, home, and the shed", 11111111-2222-3333-4444-555555555555
            "Büro – 会議室 🖥", 66666666-7777-8888-9999-AAAAAAAAAAAA
            """
        #expect(WindowsAppBookmarks.parseList(text).map(\.name) == ["Work, home, and the shed", "Büro – 会議室 🖥"])
        #expect(WindowsAppBookmarks.parseList(text).map(\.id)
                == ["11111111-2222-3333-4444-555555555555", "66666666-7777-8888-9999-AAAAAAAAAAAA"])
    }

    @Test func anEmptyListIsNoBookmarks() {
        #expect(WindowsAppBookmarks.parseList("").isEmpty)
        #expect(WindowsAppBookmarks.parseList("\n\n  \n").isEmpty)
    }

    /// Anything that isn't that shape is one of the app's own messages. Skipped, never guessed at:
    /// a wrong id would be a delete or a rewrite aimed at somebody else's saved PC.
    @Test func skipsJunkRatherThanGuessing() {
        let text = """
            Bookmark with id: 4820137 was not found
            adding bookmark not successful
            "no closing quote, 11111111-1111-1111-1111-111111111111
            "no comma" 22222222-2222-2222-2222-222222222222
            "two words for an id", 333 444
            "nothing after the comma",
            "good one", 99999999-9999-9999-9999-999999999999
            """
        #expect(WindowsAppBookmarks.parseList(text)
                == [WindowsAppBookmarks.Bookmark(name: "good one", id: "99999999-9999-9999-9999-999999999999")])
    }

    /// Windows App prints the app's own chatter around the list on some runs; leading and trailing
    /// space (and a stray carriage return) mustn't end up inside a name or an id.
    @Test func trimsAroundTheLine() {
        let text = "  \"mypc.local\" ,  ABC-123  \r\n"
        #expect(WindowsAppBookmarks.parseList(text)
                == [WindowsAppBookmarks.Bookmark(name: "mypc.local", id: "ABC-123")])
    }
}

@Suite struct BookmarkExportParsing {
    static let export = """
        full address:s:winbar-probe.invalid
        username:s:probeuser
        screen mode id:i:2
        dynamic resolution:i:1
        """

    @Test func readsTheHostAndTheUser() {
        #expect(WindowsAppBookmarks.address(inExport: Self.export) == "winbar-probe.invalid")
        #expect(WindowsAppBookmarks.rdpValue("username", in: Self.export) == "probeuser")
    }

    @Test func missingOrEmptyValuesAreNil() {
        #expect(WindowsAppBookmarks.address(inExport: "username:s:alex") == nil)
        #expect(WindowsAppBookmarks.address(inExport: "full address:s:") == nil)
        #expect(WindowsAppBookmarks.address(inExport: "") == nil)
        // An integer setting isn't a string setting, and `full address` is only ever `:s:`.
        #expect(WindowsAppBookmarks.address(inExport: "full address:i:3") == nil)
    }

    /// The key has to be at the start of the line, or `alternate full address:s:` would answer for
    /// `full address:s:`.
    @Test func onlyMatchesAtTheStartOfALine() {
        #expect(WindowsAppBookmarks.address(inExport: "alternate full address:s:elsewhere.local") == nil)
        #expect(WindowsAppBookmarks.address(inExport: "alternate full address:s:elsewhere.local\nfull address:s:right.local")
                == "right.local")
    }

    /// A port goes on the address, colons and all; the value is the rest of the line.
    @Test func keepsTheRestOfTheLine() {
        #expect(WindowsAppBookmarks.address(inExport: "full address:s:mypc.local:3390") == "mypc.local:3390")
    }
}

@Suite struct AlreadySavedDecision {
    let pcs = [
        WindowsAppBookmarks.Bookmark(name: "Windows 11", id: "A"),
        WindowsAppBookmarks.Bookmark(name: "mypc.local", id: "B"),
        WindowsAppBookmarks.Bookmark(name: "Office", id: "C"),
    ]

    /// The address is what the connection really uses, so it settles the question even when the PC
    /// carries a friendly name that looks like nothing.
    @Test func anAddressMatchWins() {
        let found = WindowsAppBookmarks.match(host: "mypc.local", in: pcs, addresses: ["A": "mypc.local", "B": "other.local"])
        #expect(found?.id == "A")
    }

    /// The 0.1.0 audience followed the README and left the friendly name empty, so the name `list`
    /// prints is the host. That's the fallback when the export couldn't be read.
    @Test func fallsBackToTheNameWhenThereIsNoAddress() {
        #expect(WindowsAppBookmarks.match(host: "mypc.local", in: pcs, addresses: [:])?.id == "B")
        #expect(WindowsAppBookmarks.match(host: "MYPC.LOCAL", in: pcs, addresses: [:])?.id == "B")
    }

    /// A PC whose address is known and is somewhere else doesn't match on its name as well: the
    /// address has already answered for it. Otherwise Winbar would adopt a tile for another machine.
    @Test func aKnownAddressOverridesItsOwnName() {
        #expect(WindowsAppBookmarks.match(host: "mypc.local", in: pcs, addresses: ["B": "renamed.local"]) == nil)
    }

    @Test func noMatchMeansWinbarWritesOne() {
        #expect(WindowsAppBookmarks.match(host: "brand-new.local", in: pcs, addresses: ["A": "mypc.local"]) == nil)
        #expect(WindowsAppBookmarks.match(host: "anything.local", in: [], addresses: [:]) == nil)
    }
}

@Suite struct BookmarkIDAndName {
    /// `write` is create-or-edit: an id Windows App already has would silently replace that PC's
    /// host, user name and password. So the id is minted against the list, never derived.
    @Test func mintsAnIDNobodyHas() throws {
        var supply = ["8b1f0c52-0000-4e2a-9a11-deadbeef0002", "FRESH-ONE"]
        let id = try WindowsAppBookmarks.newID(notIn: ["8B1F0C52-0000-4E2A-9A11-DEADBEEF0002"],
                                               make: { supply.removeFirst() })
        #expect(id == "FRESH-ONE")
    }

    @Test func idsAreUppercase() throws {
        #expect(try WindowsAppBookmarks.newID(notIn: [], make: { "abcdef12-0000-0000-0000-000000000000" })
                == "ABCDEF12-0000-0000-0000-000000000000")
    }

    @Test func realIDsAreUUIDs() throws {
        let id = try WindowsAppBookmarks.newID(notIn: [])
        #expect(UUID(uuidString: id) != nil)
        #expect(id == id.uppercased())
    }

    /// If minting keeps landing on a taken id, the write is refused rather than risked.
    @Test func refusesRatherThanReusingAnID() {
        #expect(throws: WindowsAppBookmarks.Failure.idInUse("TAKEN")) {
            try WindowsAppBookmarks.newID(notIn: ["taken"], make: { "TAKEN" })
        }
    }

    /// Two tiles with the same accessibility description would make Connect's choice between them
    /// arbitrary, so Winbar gives up the friendly name and lets the tile match on the host.
    @Test func givesUpAFriendlyNameSomebodyElseHas() {
        let pcs = [WindowsAppBookmarks.Bookmark(name: "Windows 11", id: "A")]
        #expect(WindowsAppBookmarks.freeName("Windows 11", notIn: pcs) == nil)
        #expect(WindowsAppBookmarks.freeName("windows 11", notIn: pcs) == nil)
        #expect(WindowsAppBookmarks.freeName("Windows 12", notIn: pcs) == "Windows 12")
        #expect(WindowsAppBookmarks.freeName(nil, notIn: pcs) == nil)
        #expect(WindowsAppBookmarks.freeName("   ", notIn: []) == nil)
    }
}

@Suite struct SavedPCRefusals {
    /// The refusal is copy a person can act on: what to do first, then why it matters.
    @Test func theRunningAppRefusalSaysWhatToDoAndWhy() {
        let said = WindowsAppBookmarks.Failure.appRunning.description
        #expect(said.hasPrefix("Quit Windows App first"))
        #expect(said.contains("database"))
        #expect(said == WindowsAppBookmarks.Copy.quitFirst)
    }

    /// The rule `save` and `delete` both run before they touch anything. `list` and `export` don't
    /// ask it: they only read, which is what lets doctor say what Windows App has while the person
    /// is using it.
    @Test func aRunningWindowsAppRefusesTheWrite() {
        #expect(WindowsAppBookmarks.refusalToWrite(installed: true, appRunning: true) == .appRunning)
        #expect(WindowsAppBookmarks.refusalToWrite(installed: true, appRunning: false) == nil)
        #expect(WindowsAppBookmarks.refusalToWrite(installed: false, appRunning: false) == .notInstalled)
        // Not installed comes first: "quit Windows App" would be nonsense advice for a Mac without it.
        #expect(WindowsAppBookmarks.refusalToWrite(installed: false, appRunning: true) == .notInstalled)
    }

    /// Exit 0 isn't success: the handler terminates the app itself and says no on stdout.
    @Test func readsTheHandlersOwnRefusals() {
        #expect(WindowsAppBookmarks.refused("cannot save bookmark, no hostname provided"))
        #expect(WindowsAppBookmarks.refused("adding bookmark not successful"))
        #expect(WindowsAppBookmarks.refused("failed to save bookmark: something"))
        #expect(WindowsAppBookmarks.refused("Failed to export bookmark: no such id"))
        #expect(!WindowsAppBookmarks.refused("\"mypc.local\", ABC"))
        #expect(!WindowsAppBookmarks.refused(""))
    }
}

@Suite struct TheSavedPCPasswordNeverEscapes {
    /// `--password` is on the argv for the length of the call, which is disclosed. What must never
    /// happen is the password coming *back*: Windows App quoting its own arguments into an error,
    /// and that error reaching a log, the screen or state.json.
    @Test func redactsThePasswordOutOfWhateverComesBack() {
        let secret = "hunter2-Correct-Horse"
        let output = "failed to save bookmark: --password \(secret) was not accepted"
        let clean = WindowsAppBookmarks.redact(output, secret: secret)
        #expect(!clean.contains(secret))
        #expect(clean.contains("failed to save bookmark"))
    }

    @Test func redactingWithoutASecretChangesNothing() {
        #expect(WindowsAppBookmarks.redact("plain", secret: nil) == "plain")
        #expect(WindowsAppBookmarks.redact("plain", secret: "") == "plain")
    }

    /// Every case of the error a caller can print or log. None carries the password's value, and
    /// none of the ones Winbar writes itself is built out of the argv at all.
    @Test func noFailureCarriesThePassword() {
        let secret = "s3cret-value"
        let echoed = WindowsAppBookmarks.redact("failed to save bookmark: --password \(secret) rejected", secret: secret)
        let failures: [WindowsAppBookmarks.Failure] = [
            .notInstalled, .appRunning, .idInUse("ABC"),
            .failed(what: "save a PC for mypc.local", output: echoed),
            .notSaved(id: "ABC"),
        ]
        for failure in failures { #expect(!failure.description.contains(secret)) }

        // The four Winbar composes itself say what happened, never what was passed.
        for failure in [WindowsAppBookmarks.Failure.notInstalled, .appRunning, .idInUse("ABC"), .notSaved(id: "ABC")] {
            #expect(!failure.description.contains("--"))
        }
    }

    /// The copy said at the moment the person decides has to name the cost, not only the benefit:
    /// create's own password block promises the password is never a command line argument.
    @Test func theCopyAdmitsTheArgv() {
        let said = WindowsAppBookmarks.Copy.passwordGoesToWindowsApp
        #expect(said.contains("login keychain"))
        #expect(said.contains("command line"))
        #expect(said.contains("read it"))
        #expect(CreateCopy.beforePassword(fileVaultOn: true).joined(separator: " ").contains(said))
        #expect(SetupCopy.SavedPC.why(user: "alex").contains(said))
    }

    /// The state file follows the job across processes and restarts. It may hold the bookmark id,
    /// which isn't a secret; it may never hold the password.
    @Test func theJobStateHoldsAnIDAndNoPassword() throws {
        var state = testState()
        state.savedPCID = "8B1F0C52-0000-4E2A-9A11-DEADBEEF0002"
        let json = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
        #expect(json.contains("8B1F0C52-0000-4E2A-9A11-DEADBEEF0002"))
        #expect(!json.lowercased().contains("password"))
    }

    /// An old state.json has no `savedPCID` at all, and still has to decode: a resume or a cancel
    /// that couldn't read it would strand the whole job.
    @Test func olderStateFilesStillDecode() throws {
        var state = testState()
        state.savedPCID = "ABC"
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        object.removeValue(forKey: "savedPCID")
        let older = try JSONSerialization.data(withJSONObject: object)
        let read = try JSONDecoder().decode(CreateJobState.self, from: older)
        #expect(read.savedPCID == nil)
        #expect(read.id == state.id)
    }
}

@Suite struct WhatConnectRemembersAboutTheSavedPC {
    /// A tile's accessibility description is the friendly name when it has one, so `savedPCName` is
    /// only worth keeping when it isn't the host — which is what `WindowsApp.tileNames` expects.
    @Test func keepsTheNameOnlyWhenItIsntTheHost() {
        let named = WindowsAppBookmarks.Bookmark(name: "Windows 11", id: "A")
        #expect(Recipe.savedPCSettings(named, host: "mypc.local").host == "mypc.local")
        #expect(Recipe.savedPCSettings(named, host: "mypc.local").name == "Windows 11")

        let plain = WindowsAppBookmarks.Bookmark(name: "MyPC.local", id: "B")
        #expect(Recipe.savedPCSettings(plain, host: "mypc.local").name == nil)
    }

    /// Windows App answering "there isn't one" retires the word Winbar was given in an earlier run.
    @Test func noSavedPCClearsTheOldWord() {
        let settings = Recipe.savedPCSettings(nil, host: "mypc.local")
        #expect(settings.host == nil)
        #expect(settings.name == nil)
    }
}
