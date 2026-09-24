import AppKit
import Foundation

/// Where this copy of Winbar is running from, and moving it to Applications when that place won't
/// last.
///
/// Why it exists: a non-technical person double-clicks Winbar inside the disk-image window, sets it
/// up and turns on Launch at Login. After they eject the image or restart, Winbar is gone, the login
/// item points at nothing, and Armie's movies — loaded lazily from `Contents/Resources` — are pulled
/// out from under the running app. A copy Gatekeeper has translocated (a quarantined app opened
/// from where it was downloaded) is the same: a read-only mirror at a random path that is gone at the
/// next launch. So at launch Winbar asks once to move itself to /Applications, and never registers a
/// login item from such a place.
///
/// No `sudo`, ever: an admin account can write /Applications itself, and for anyone else Winbar
/// says how to do it by hand rather than asking for a password.
enum AppLocation {
    enum Place: Equatable {
        /// /Applications or ~/Applications: where the cask and a drag from the image put it.
        case applications
        /// Gatekeeper's randomised, read-only mirror of a quarantined app that was never moved.
        case translocated
        /// On a mounted volume: almost always the disk image it came in.
        case mountedVolume
        /// ~/Downloads, where a drag out of the image, or an unzipped copy, lands and later gets
        /// cleaned out.
        case downloads
        /// Anywhere else — a build folder, a developer's checkout. Left alone: whoever put it there
        /// meant to.
        case elsewhere
    }

    /// Which place `bundlePath` is. Pure.
    static func place(of bundlePath: String, home: String) -> Place {
        let path = (bundlePath as NSString).standardizingPath
        if path.contains("/AppTranslocation/") { return .translocated }
        if path.hasPrefix("/Applications/") || path.hasPrefix(home + "/Applications/") { return .applications }
        if path.hasPrefix("/Volumes/") { return .mountedVolume }
        if path.hasPrefix(home + "/Downloads/") { return .downloads }
        return .elsewhere
    }

    /// Whether the place goes away underneath the app: an image is ejected, a translocated mirror
    /// vanishes, Downloads gets tidied.
    static func isTemporary(_ place: Place) -> Bool {
        switch place {
        case .translocated, .mountedVolume, .downloads: return true
        case .applications, .elsewhere: return false
        }
    }

    /// Whether to ask at launch: from a temporary place, once. "Not Now" is remembered
    /// (`Config.declinedMoveToApplications`); a Launch at Login from there asks again regardless,
    /// since that is the one thing such a copy must not do.
    static func offersMove(_ place: Place, declined: Bool) -> Bool {
        isTemporary(place) && !declined
    }

    /// Whether to put the move to the person now: the menu's whole decision, so it can be checked
    /// without the delegate. Pure.
    ///
    /// At launch, once (`offersMove`). For Launch at Login, whenever the copy is temporary: that is
    /// the one thing such a copy must not do, so a Not Now at launch doesn't stop it. Never while a
    /// Winbar in Applications is already running (`destinationRunning`): this copy is then a
    /// duplicate, and the move would put the app in use in the Trash.
    static func asksToMove(_ place: Place, forLoginItem: Bool, declined: Bool, destinationRunning: Bool) -> Bool {
        guard !destinationRunning else { return false }
        return forLoginItem ? isTemporary(place) : offersMove(place, declined: declined)
    }

    /// Why a login item can't be registered from here, or nil when it can. Pure.
    static func loginItemRefusal(_ place: Place) -> String? {
        isTemporary(place) ? Copy.loginItemRefused(place) : nil
    }

    static let destination = URL(fileURLWithPath: "/Applications/Winbar.app")

    /// This copy's place, from the running bundle. `.elsewhere` for a bare build with no bundle.
    static var current: Place {
        guard let url = AppBundle.url else { return .elsewhere }
        return place(of: url.path, home: FileManager.default.homeDirectoryForCurrentUser.path)
    }

    // MARK: - The move

    /// One command the move runs. Values, so the plan can be checked without running any of it.
    struct Command: Equatable {
        var tool: String
        var arguments: [String]
    }

    /// Copies the running app to `destination`, then clears the quarantine flag on the copy. Pure.
    ///
    /// `ditto`, not `cp -R`: it keeps the symlinks, extended attributes and resource forks a signed
    /// bundle's seal covers (the same reason scripts/release.sh uses it). The quarantine flag has to
    /// go from the copy, or Gatekeeper translocates the copy in /Applications as well — it only skips
    /// that for an app the Finder moved. The app has already passed Gatekeeper's check to be running
    /// at all, and the flag is removed from the new copy only.
    static func copyCommands(from source: URL, to destination: URL) -> [Command] {
        [Command(tool: "/usr/bin/ditto", arguments: [source.path, destination.path]),
         Command(tool: "/usr/bin/xattr", arguments: ["-d", "-r", "com.apple.quarantine", destination.path])]
    }

    /// Opens `destination` once process `pid` (this one) has gone, so the two copies never run side by
    /// side: a second menu bar icon, and two busy guards that can't see each other. Detached, so it
    /// outlives this process. `arguments` are the window requests this launch was given. Pure.
    static func relaunchCommand(pid: Int32, destination: URL, arguments: [String]) -> Command {
        let script = #"while /bin/kill -0 "$1" 2>/dev/null; do /bin/sleep 0.2; done; app="$2"; shift 2; "#
            + #"if [ $# -gt 0 ]; then /usr/bin/open "$app" --args "$@"; else /usr/bin/open "$app"; fi"#
        return Command(tool: "/bin/sh", arguments: ["-c", script, "sh", String(pid), destination.path] + arguments)
    }

    /// The window requests to carry over to the copy that opens next: nothing else from this launch's
    /// arguments is Winbar's to pass on. Pure.
    static func relaunchArguments(_ launchArguments: [String]) -> [String] {
        launchArguments.filter { [AppDelegate.createWindowArgument, AppDelegate.setupWindowArgument].contains($0) }
    }

    enum MoveResult: Equatable {
        case moved
        /// /Applications can't be written by this account; `Copy.byHand` says what to do instead.
        case notWritable
        case failed(String)
    }

    /// Carries the move out: a Winbar already in /Applications goes to the Trash (where it can be
    /// taken back), then this one is copied there. Blocking; a few seconds for ditto.
    static func move(from source: URL, to destination: URL = destination,
                     fileManager: FileManager = .default) -> MoveResult {
        let folder = destination.deletingLastPathComponent().path
        guard fileManager.isWritableFile(atPath: folder) else { return .notWritable }
        if fileManager.fileExists(atPath: destination.path) {
            do { try fileManager.trashItem(at: destination, resultingItemURL: nil) } catch {
                return .failed("Couldn't move the Winbar already in Applications to the Trash: \(error.localizedDescription)")
            }
        }
        let commands = copyCommands(from: source, to: destination)
        let copy = Shell.run(commands[0].tool, commands[0].arguments, timeout: 120)
        guard copy.status == 0 else {
            return .failed("Couldn't copy Winbar into Applications: "
                           + copy.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        // A copy with no quarantine flag at all has nothing to clear, and xattr says so with a
        // non-zero status; that is not a failure.
        _ = Shell.run(commands[1].tool, commands[1].arguments, timeout: 30)
        return .moved
    }

    /// Starts the relaunch helper. False if it couldn't be started.
    static func relaunch(_ command: Command) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.tool)
        process.arguments = command.arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        return true
    }

    /// Whether a Winbar other than this process is running from `destination` already: then this copy
    /// is a duplicate, and moving it would trash the app that is running.
    static func destinationIsRunning(_ destination: URL = destination) -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: Config.appBundleID).contains {
            $0.processIdentifier != getpid()
                && $0.bundleURL?.resolvingSymlinksInPath().path == destination.resolvingSymlinksInPath().path
        }
    }

    // MARK: - Words

    enum Copy {
        static func title(_ place: Place) -> String {
            switch place {
            case .translocated, .mountedVolume: return "Winbar is running from the disk image. Move it to Applications?"
            case .downloads: return "Winbar is running from your Downloads folder. Move it to Applications?"
            case .applications, .elsewhere: return "Move Winbar to Applications?"
            }
        }

        static let detail = "Winbar stays in the menu bar and can open when you log in, so it needs a home that "
            + "won't disappear. A copy on the disk image goes away when the image is ejected or the Mac restarts, "
            + "and one in Downloads when that folder is tidied. Winbar copies itself to Applications, opens the new "
            + "copy and quits this one. An older Winbar already there goes to the Trash."

        static let bMove = "Move to Applications"
        static let bNotNow = "Not Now"

        static let byHandTitle = "Winbar can't write to the Applications folder"
        /// No `sudo`, and no asking for an administrator's password: the Finder does that properly.
        static let byHand = "Your account can't add apps to Applications by itself. Quit Winbar, then drag Winbar "
            + "from the disk image into the Applications folder in the Finder (it asks for an administrator's name and "
            + "password if it needs one). Eject the disk image, and open Winbar from Applications."

        static let failedTitle = "Winbar couldn't move itself to Applications"

        static func loginItemRefused(_ place: Place) -> String {
            let from = place == .downloads ? "your Downloads folder" : "the disk image"
            return "Winbar is running from \(from), so a login item would point at a copy that won't be there after "
                + "you restart. Move Winbar to Applications first, then turn on Launch at Login."
        }
    }
}
