import Foundation
import Testing
@testable import Winbar

// Where a copy of Winbar runs from, and what it does about a place that won't last. Nothing here
// launches, quits or moves Winbar: the paths are invented, the plan is compared as values, and the one
// real copy is between two folders in the temporary directory.

private let home = "/Users/rosa"

@Suite("Winbar knows when it is running from somewhere that goes away")
struct AppLocationTests {
    @Test("Each place is recognised from the bundle's path", arguments: [
        ("/Applications/Winbar.app", AppLocation.Place.applications),
        ("/Users/rosa/Applications/Winbar.app", .applications),
        ("/private/var/folders/3x/9q0b1k_s0000gn/T/AppTranslocation/6F3A1C2B-0D4E-4F5A-8B6C-7D8E9F0A1B2C/d/Winbar.app",
         .translocated),
        ("/Volumes/Winbar 0.2.0/Winbar.app", .mountedVolume),
        ("/Users/rosa/Downloads/Winbar.app", .downloads),
        ("/Users/rosa/Downloads/Winbar 2/Winbar.app", .downloads),
        ("/Users/rosa/src/winbar/dist/Winbar.app", .elsewhere),
        ("/Users/rosa/Desktop/Winbar.app", .elsewhere),
    ])
    func places(_ path: String, _ expected: AppLocation.Place) {
        #expect(AppLocation.place(of: path, home: home) == expected)
    }

    /// A translocated mirror of an app on a mounted image is translocated first: that is the path
    /// macOS really runs it from, and the one that vanishes.
    @Test("Translocation wins over where the original sits")
    func translocationFirst() {
        #expect(AppLocation.place(of: "/private/var/folders/x/T/AppTranslocation/ABC/d/Winbar.app", home: home) == .translocated)
        #expect(AppLocation.place(of: "/Applications/../Volumes/Winbar/Winbar.app", home: home) == .mountedVolume)
    }

    @Test("The move is offered once, only for places that go away")
    func offeredOnce() {
        for place in [AppLocation.Place.translocated, .mountedVolume, .downloads] {
            #expect(AppLocation.offersMove(place, declined: false), "\(place)")
            #expect(!AppLocation.offersMove(place, declined: true), "\(place): Not Now is remembered")
        }
        for place in [AppLocation.Place.applications, .elsewhere] {
            #expect(!AppLocation.offersMove(place, declined: false), "\(place)")
        }
    }

    /// The menu's whole decision. A duplicate copy never offers, because the move would put the Winbar
    /// that is running from Applications in the Trash; Launch at Login asks even after a Not Now.
    @Test("The menu asks at launch once, for Launch at Login always, and never beside a running copy")
    func asksToMove() {
        for place in [AppLocation.Place.translocated, .mountedVolume, .downloads] {
            #expect(AppLocation.asksToMove(place, forLoginItem: false, declined: false, destinationRunning: false))
            #expect(!AppLocation.asksToMove(place, forLoginItem: false, declined: true, destinationRunning: false))
            #expect(AppLocation.asksToMove(place, forLoginItem: true, declined: true, destinationRunning: false))
            for forLoginItem in [false, true] {
                #expect(!AppLocation.asksToMove(place, forLoginItem: forLoginItem, declined: false, destinationRunning: true),
                        "\(place): a Winbar in Applications is running")
            }
        }
        for place in [AppLocation.Place.applications, .elsewhere] {
            #expect(!AppLocation.asksToMove(place, forLoginItem: true, declined: false, destinationRunning: false))
            #expect(!AppLocation.asksToMove(place, forLoginItem: false, declined: false, destinationRunning: false))
        }
    }

    /// The login item must never point at a copy that disappears at the next restart.
    @Test("A login item is refused from a temporary copy, and only from one")
    func loginItemRefused() {
        #expect(AppLocation.loginItemRefusal(.mountedVolume)?.contains("disk image") == true)
        #expect(AppLocation.loginItemRefusal(.translocated)?.contains("disk image") == true)
        #expect(AppLocation.loginItemRefusal(.downloads)?.contains("Downloads") == true)
        #expect(AppLocation.loginItemRefusal(.applications) == nil)
        #expect(AppLocation.loginItemRefusal(.elsewhere) == nil)
    }

    @Test("The copy keeps the bundle's seal and drops quarantine from the copy only")
    func copyPlan() {
        let source = URL(fileURLWithPath: "/Volumes/Winbar 0.2.0/Winbar.app")
        let commands = AppLocation.copyCommands(from: source, to: AppLocation.destination)
        #expect(commands == [
            .init(tool: "/usr/bin/ditto", arguments: ["/Volumes/Winbar 0.2.0/Winbar.app", "/Applications/Winbar.app"]),
            .init(tool: "/usr/bin/xattr", arguments: ["-d", "-r", "com.apple.quarantine", "/Applications/Winbar.app"]),
        ])
        #expect(AppLocation.destination.path == "/Applications/Winbar.app")
        // No sudo anywhere in the plan, or in the file that carries it out.
        #expect(!commands.contains { $0.tool.contains("sudo") || $0.arguments.contains("sudo") })
    }

    /// The new copy opens only once this one has gone — two running at once would be two menu bar
    /// icons — and it is given the window this launch was asked for, and nothing else.
    @Test("The relaunch waits for this process, then opens the new copy with the window requests")
    func relaunchPlan() {
        let command = AppLocation.relaunchCommand(pid: 4242, destination: AppLocation.destination,
                                                  arguments: ["--setup-window"])
        #expect(command.tool == "/bin/sh")
        #expect(Array(command.arguments.suffix(4)) == ["sh", "4242", "/Applications/Winbar.app", "--setup-window"])
        let script = command.arguments[1]
        #expect(script.contains(#"kill -0 "$1""#))
        #expect(script.contains("/usr/bin/open"))
        #expect(AppLocation.relaunchArguments(["-psn_0_1", "--setup-window", "--create-window", "-NSDocumentRevisionsDebugMode"])
                == ["--setup-window", "--create-window"])
    }

    /// The script really does wait and pass the arguments: run with `open` replaced by `echo`, against
    /// a process that has already gone.
    @Test("The relaunch script runs: it passes the path and the arguments on")
    func relaunchScriptRuns() {
        let command = AppLocation.relaunchCommand(pid: 999_999, destination: URL(fileURLWithPath: "/tmp/Winbar.app"),
                                                  arguments: ["--create-window"])
        let script = command.arguments[1].replacingOccurrences(of: "/usr/bin/open", with: "echo")
        let result = Shell.run("/bin/sh", ["-c", script] + command.arguments.dropFirst(2), timeout: 10)
        #expect(result.status == 0)
        #expect(result.text.trimmingCharacters(in: .whitespacesAndNewlines) == "/tmp/Winbar.app --args --create-window")
    }

    @Test("A folder this account can't write is said, never escalated")
    func notWritable() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("winbar-move-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            try? FileManager.default.removeItem(at: folder)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        let result = AppLocation.move(from: URL(fileURLWithPath: "/nonexistent/Winbar.app"),
                                      to: folder.appendingPathComponent("Winbar.app"))
        #expect(result == .notWritable)
        #expect(AppLocation.Copy.byHand.contains("drag Winbar"))
        #expect(!AppLocation.Copy.byHand.lowercased().contains("sudo"))
    }

    /// The copy that lands in Applications must not carry the quarantine flag, or Gatekeeper
    /// translocates it too; the copy it came from keeps its own.
    @Test("A move copies the bundle into place, without the quarantine flag")
    func movesACopy() throws {
        let scratch = try Scratch()
        let source = try scratch.bundle("image/Winbar.app", file: "Info.plist")
        try scratch.quarantine(source)
        #expect(scratch.isQuarantined(source))
        let destination = try scratch.folder("Applications").appendingPathComponent("Winbar.app")
        #expect(AppLocation.move(from: source, to: destination) == .moved)
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("Contents/Info.plist").path))
        #expect(!scratch.isQuarantined(destination))
        #expect(!scratch.isQuarantined(destination.appendingPathComponent("Contents/Info.plist")))
        #expect(scratch.isQuarantined(source))
    }

    /// An older Winbar already in Applications goes to the Trash, where it can be taken back, and is
    /// never deleted. Nor is the new copy merged over it: ditto into an existing bundle keeps files
    /// the new one doesn't have.
    @Test("A Winbar already in Applications is trashed, never removed, and not merged into")
    func trashesTheOldOne() throws {
        let scratch = try Scratch()
        let source = try scratch.bundle("image/Winbar.app", file: "Info.plist")
        let destination = try scratch.bundle("Applications/Winbar.app", file: "Old.plist")
        let files = RecordingFiles(trash: try scratch.folder("Trash"))
        #expect(AppLocation.move(from: source, to: destination, fileManager: files) == .moved)
        #expect(files.calls == ["trash Winbar.app"])
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("Contents/Info.plist").path))
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("Contents/Old.plist").path))
        #expect(FileManager.default.fileExists(atPath: files.trash.appendingPathComponent("Winbar.app/Contents/Old.plist").path))
    }

    /// If the old copy can't go to the Trash, nothing is copied over it and nothing is deleted.
    @Test("A Trash that refuses stops the move before anything is copied")
    func refusedTrashStops() throws {
        let scratch = try Scratch()
        let source = try scratch.bundle("image/Winbar.app", file: "Info.plist")
        let destination = try scratch.bundle("Applications/Winbar.app", file: "Old.plist")
        let files = RecordingFiles(trash: try scratch.folder("Trash"))
        files.trashRefuses = true
        guard case .failed(let why) = AppLocation.move(from: source, to: destination, fileManager: files) else {
            Issue.record("the move went ahead")
            return
        }
        #expect(why.contains("to the Trash"))
        #expect(files.calls == ["trash Winbar.app"])
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("Contents/Old.plist").path))
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("Contents/Info.plist").path))
    }

    /// The delegate can't be made in a test (it puts an icon in the menu bar), so the three lines
    /// that keep it safe are read as text.
    @Test("The menu offers the move first thing at launch, and registers the login item from where it runs")
    func theMenuWiresItUp() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let menuBar = try String(contentsOf: root.appendingPathComponent("Sources/Winbar/MenuBar.swift"), encoding: .utf8)
        // Before an abandoned install is picked up or a window opens: a copy about to quit mustn't.
        let launch = try #require(menuBar.range(of: "func applicationDidFinishLaunching(_ notification: Notification) {"))
        let firstLine = menuBar[launch.upperBound...].split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("//") }
        #expect(firstLine == "if offerMoveToApplications(forLoginItem: false) { return }")
        // The running-copy guard goes into the decision.
        #expect(menuBar.contains("destinationRunning: AppLocation.destinationIsRunning()"))
        // Launch at Login from the menu is refused for a disk-image copy only if it is told where it runs.
        let toggle = try #require(menuBar.range(of: "private func toggleLaunchAtLogin() {"))
        let body = menuBar[toggle.upperBound...].prefix(600)
        #expect(body.contains("service: service, place: AppLocation.current)"))
    }
}

/// Folders in the temporary directory, gone when the test is.
private final class Scratch {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("winbar-move-\(UUID().uuidString)")

    init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    deinit { try? FileManager.default.removeItem(at: root) }

    func folder(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A bundle with one file in Contents.
    func bundle(_ path: String, file: String) throws -> URL {
        let contents = try folder(path + "/Contents")
        try Data("<plist/>".utf8).write(to: contents.appendingPathComponent(file))
        return contents.deletingLastPathComponent()
    }

    /// What Safari puts on a download, on the bundle and everything in it.
    func quarantine(_ url: URL) throws {
        let result = Shell.run("/usr/bin/xattr", ["-w", "-r", "com.apple.quarantine", "0081;66f2a000;Safari;", url.path],
                               timeout: 10)
        try #require(result.status == 0, "\(result.output)")
    }

    func isQuarantined(_ url: URL) -> Bool {
        getxattr(url.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }
}

/// Records what the move asks of the file system. The Trash is a folder of the test's own, so
/// nothing lands in the real one; a delete is recorded and carried out, so a test can say it never
/// happened.
private final class RecordingFiles: FileManager {
    let trash: URL
    var trashRefuses = false
    private(set) var calls: [String] = []

    init(trash: URL) { self.trash = trash }

    override func trashItem(at url: URL, resultingItemURL outResultingURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
        calls.append("trash \(url.lastPathComponent)")
        if trashRefuses { throw CocoaError(.fileWriteNoPermission) }
        try moveItem(at: url, to: trash.appendingPathComponent(url.lastPathComponent))
    }

    override func removeItem(at url: URL) throws {
        calls.append("remove \(url.lastPathComponent)")
        try super.removeItem(at: url)
    }

    override func removeItem(atPath path: String) throws {
        calls.append("remove \((path as NSString).lastPathComponent)")
        try super.removeItem(atPath: path)
    }
}
