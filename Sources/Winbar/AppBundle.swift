import AppKit
import Foundation

/// Where this binary lives, and the version it was stamped with.
enum AppBundle {
    /// The Winbar.app containing this executable. The cask links `winbar` to
    /// Winbar.app/Contents/MacOS/Winbar, so the symlink is resolved first. nil for a bare build
    /// (`swift build`), which has no bundle around it.
    static let url: URL? = {
        var size = UInt32(MAXPATHLEN)
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0, let real = realpath(buffer, nil) else { return nil }
        defer { free(real) }
        let app = URL(fileURLWithPath: String(cString: real))
            .deletingLastPathComponent()   // MacOS
            .deletingLastPathComponent()   // Contents
            .deletingLastPathComponent()   // Winbar.app
        return app.pathExtension == "app" ? app : nil
    }()

    /// From the bundle's Info.plist, which build-app.sh stamps from the VERSION file: one source of
    /// truth, read at run time rather than compiled in.
    static let version: String = {
        guard let url,
              let data = try? Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let version = plist["CFBundleShortVersionString"] as? String
        else { return "dev" }
        return version
    }()

    /// Whether a Winbar.app is already up (the menu bar app, usually a login item). LaunchServices
    /// hands `--args` only to a process it starts, so what reaches a running one has to be asked for
    /// another way (see `winbar create --window`).
    static var isAppRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Config.appBundleID)
            .filter { $0.processIdentifier != getpid() }.isEmpty
    }

    /// True when LaunchServices started this process (Finder, `open`, login item) rather than a shell.
    /// Privacy grants (Accessibility, Local Network) belong to whoever is responsible for a process, so
    /// only a LaunchServices launch speaks for Winbar itself.
    static var launchedByLaunchServices: Bool { getppid() == 1 }

    enum AppRun: Equatable {
        case finished(String)   // everything it printed, up to and including the end marker
        case timedOut
        case interrupted        // Ctrl-C here; the app instance notices its parent is gone (see CLI)
    }

    /// Runs Winbar.app itself through LaunchServices with `arguments`, so it gets the app's own privacy
    /// grants rather than the calling shell's, and waits for a line starting with `endMarker`. nil if
    /// it couldn't be launched.
    ///
    /// Deliberately not `open -W`: on macOS 27 it prints "Unable to block on application" and then waits
    /// forever even after the app has exited, so the wait is on the app's own end-of-output marker.
    ///
    /// `relay` gets each complete line as it appears, so a long run isn't minutes of silence. With
    /// `interruptible`, Ctrl-C ends the wait (and this process's part) cleanly instead of killing it
    /// with the temporary file left behind.
    static func runAsApp(_ arguments: [String], endMarker: String, timeout: TimeInterval,
                         relay: ((String) -> Void)? = nil, interruptible: Bool = false) -> AppRun? {
        guard let app = url else { return nil }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("winbar-run-\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: output) }

        let interrupt = Flag()
        var source: DispatchSourceSignal?
        if interruptible {
            signal(SIGINT, SIG_IGN)   // the source below sees it instead of the default kill
            let handler = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global(qos: .userInitiated))
            handler.setEventHandler { interrupt.set() }
            handler.resume()
            source = handler
        }
        defer {
            if let source {
                source.cancel()
                signal(SIGINT, SIG_DFL)
            }
        }

        // -n: a fresh instance even if the menu bar app is running; -g: don't bring it to the front.
        let launch = Shell.run("/usr/bin/open", ["-n", "-g", "--stdout", output.path, "--stderr", output.path,
                                                 "-a", app.path, "--args"] + arguments, timeout: 30)
        guard launch.status == 0 else { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        var relayed = 0   // complete lines already passed to `relay`
        while Date() < deadline {
            if interrupt.isSet { return .interrupted }
            let text = (try? String(contentsOf: output, encoding: .utf8)) ?? ""
            let complete = text.components(separatedBy: "\n").dropLast()   // the last piece is an unfinished line
            if let relay {
                for line in complete.dropFirst(relayed) { relay(line) }
                relayed = complete.count
            }
            if complete.contains(where: { $0.hasPrefix(endMarker) }) { return .finished(text) }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return .timedOut
    }

    /// Set from a signal handler's queue, read from the waiting loop.
    private final class Flag {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// Whether process `pid` has gone. A process of another user still counts as there.
    static func processGone(_ pid: pid_t) -> Bool {
        kill(pid, 0) != 0 && errno == ESRCH
    }
}

/// Handing one of the app's windows over from the CLI (`winbar create --window`, `winbar setup
/// --window`). The window has to belong to Winbar.app, not to the terminal: macOS grants Automation
/// and Accessibility to whoever is responsible for a process, so a window opened by the app asks about
/// Winbar once rather than about the terminal. LaunchServices hands `--args` only to a process it
/// starts, and a second Winbar would put a second icon in the menu bar, so a Winbar that is already
/// running is asked by a distributed notification instead.
enum WindowHandOff {
    enum Route: Equatable {
        /// Winbar is running: post this, and it opens the window itself.
        case notify(Notification.Name)
        /// It isn't: launch it with the argument that opens the window.
        case launch(tool: String, arguments: [String])
    }

    /// Which way to ask. Pure.
    static func route(app: URL, appRunning: Bool, argument: String, notification: Notification.Name) -> Route {
        appRunning ? .notify(notification) : .launch(tool: "/usr/bin/open", arguments: ["-a", app.path, "--args", argument])
    }

    /// Carries the route out. nil when it went; otherwise what `open` said about why it didn't.
    static func perform(_ route: Route) -> String? {
        switch route {
        case .notify(let name):
            DistributedNotificationCenter.default().postNotificationName(name, object: nil, userInfo: nil,
                                                                         deliverImmediately: true)
            return nil
        case .launch(let tool, let arguments):
            let launch = Shell.run(tool, arguments, timeout: 30)
            return launch.status == 0 ? nil : launch.output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
