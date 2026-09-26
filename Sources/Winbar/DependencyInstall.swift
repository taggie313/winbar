import AppKit
import Foundation

// Carrying out an `InstallPlan`, and the words that ask first. Nothing here starts without a yes:
// `agreed` is the answer to the question `DependencyCopy.question` asks, and a plan that was never
// agreed to is refused rather than run.

enum DependencyInstaller {
    enum Outcome: Equatable {
        /// It is installed and verified: bundle id, signature, team and version all check out.
        case installed(version: String?)
        /// The App Store page is open. Only the person can press Get, so Winbar waits for them.
        case handedOff
        /// Nothing was done, and this is why.
        case refused(String)
    }

    /// Whether a plan may be carried out by `--yes` alone. Homebrew's may: asking it to install a
    /// cask is what `--yes` is for. Downloading a quarter of a gigabyte and copying an app into
    /// /Applications is not, and the App Store needs a person at the keyboard regardless.
    static func mayProceedUnattended(_ plan: InstallPlan) -> Bool {
        switch plan {
        case .brew, .brewUpgrade: return true
        case .download, .appStore, .manual: return false
        }
    }

    /// How a Homebrew command is run: the tool, its arguments and a timeout in; the exit status out,
    /// or nil when it was refused, couldn't start or ran out of time.
    typealias CommandRunner = (_ tool: String, _ arguments: [String], _ timeout: TimeInterval) -> Int32?

    /// Carries out `plan`. `agreed` is the person's yes to the question that was just asked; without
    /// it nothing runs. `progress` gets a line at each step.
    ///
    /// `runner` is how Homebrew is run. `winbar setup` keeps `runAttached`, the default: Homebrew's
    /// output goes straight to the terminal, which is the point of running it attached. The setup
    /// window has no terminal to give it, so it passes `DependencyCommand.runStreaming` with its own
    /// line handler, and Homebrew's words arrive a line at a time instead. Either way the command is
    /// the plan's own, and either runner refuses anything privileged before it starts.
    static func install(_ dependency: Dependency, plan: InstallPlan, agreed: Bool,
                        progress: @escaping (String) -> Void = { _ in },
                        runner: CommandRunner = DependencyCommand.runAttached) -> Result<Outcome, WinbarError> {
        guard agreed else { return .success(.refused(DependencyCopy.nothingWithoutYes(dependency))) }
        switch plan {
        case .manual(let advice):
            return .success(.refused(advice))

        case .appStore(let id):
            guard let url = URL(string: "macappstores://apps.apple.com/app/id\(id)") else {
                return .failure(WinbarError("Couldn't open the App Store"))
            }
            guard NSWorkspace.shared.open(url) else {
                return .failure(WinbarError("Couldn't open the App Store",
                                            "Open it yourself and search for \(dependency.name)."))
            }
            return .success(.handedOff)

        case .brew(let brew, let cask), .brewUpgrade(let brew, let cask):
            let command = plan.command ?? Homebrew.installCommand(brew: brew, cask: cask)
            progress(DependencyCopy.askingHomebrew(dependency, command: command))
            guard let status = runner(command.tool, command.arguments, 3600) else {
                return .failure(WinbarError("Homebrew didn't finish",
                                            "Run it yourself and watch what it says: "
                                                + DependencyCopy.shell(command)))
            }
            guard status == 0 else {
                let verb = plan.isUpdate ? "update" : "install"
                return .failure(WinbarError("Homebrew couldn't \(verb) \(dependency.name)",
                                            "It stopped with exit status \(status); its own output is above. "
                                                + "Try it again yourself: " + DependencyCopy.shell(command)))
            }
            return verify(dependency, progress: progress)

        case .download(let url, let sha256):
            return downloadAndInstall(dependency, from: url, sha256: sha256, progress: progress)
        }
    }

    /// The one thing every path ends with: the app is there, it is the app Winbar expects, and it is
    /// new enough. A failure here stops the run — nothing carries on to the next step on the strength
    /// of an install that didn't check out.
    static func verify(_ dependency: Dependency,
                       progress: (String) -> Void = { _ in }) -> Result<Outcome, WinbarError> {
        progress(DependencyCopy.checking(dependency))
        // LaunchServices can take a moment to notice an app that has just been copied in, and
        // "it isn't there" would be the wrong thing to say about an install that worked.
        var state = Dependencies.state(of: dependency)
        if case .missing = state {
            waitUntil(timeout: 15, every: 1) {
                state = Dependencies.state(of: dependency)
                if case .missing = state { return false }
                return true
            }
        }
        switch state {
        case .installed(let version):
            return .success(.installed(version: version))
        case .missing:
            return .failure(WinbarError("\(dependency.name) still isn't installed",
                                        "The install said it worked, but macOS can't find \(dependency.name). "
                                            + "Open it once from your Applications folder, then run winbar setup again."))
        case .tooOld(let version, let minimum):
            return .failure(WinbarError("\(dependency.name) \(version) is too old for Winbar",
                                        "Winbar needs \(dependency.name) \(minimum) or later. Update it, then run "
                                            + "winbar setup again."))
        case .wrongSignature(let detail):
            return .failure(WinbarError("\(dependency.name) isn't the app Winbar expected", detail))
        }
    }

    // MARK: - The disk image (UTM, on a Mac without Homebrew)

    /// Whether a downloaded file's SHA-256 is the one GitHub published for it. Both as hex, in either
    /// case; a file that couldn't be read (`actual` nil) never matches. Pure.
    static func digestMatches(_ actual: String?, expected: String) -> Bool {
        guard let actual, let want = WindowsISO.normalizedSHA256(expected) else { return false }
        return WindowsISO.normalizedSHA256(actual) == want
    }

    /// Fetches the app's own disk image, checks Apple's notarization and the signing team **before**
    /// mounting it, copies the app to /Applications and detaches. No sudo: /Applications is writable
    /// by an administrator, and a Mac where it isn't gets told to drag the app across itself.
    ///
    /// `sha256` is GitHub's digest for that release's disk image, when the release was read
    /// (`UTMChannels`): checked first, so a file that isn't the one GitHub published is deleted before
    /// anything else looks at it.
    static func downloadAndInstall(_ dependency: Dependency, from url: String, sha256: String? = nil,
                                   progress: @escaping (String) -> Void) -> Result<Outcome, WinbarError> {
        guard let source = URL(string: url) else { return .failure(WinbarError("\(url) isn't a URL")) }
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("winbar-install-\(UUID().uuidString)", isDirectory: true)
        do { try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true) } catch {
            return .failure(WinbarError("Couldn't make a folder to download into", "\(error.localizedDescription)"))
        }
        var keepDownload = false
        defer { if !keepDownload { try? FileManager.default.removeItem(at: work) } }

        let image = work.appendingPathComponent(source.lastPathComponent)
        progress(DependencyCopy.downloading(dependency, from: source))
        // URLSession calls back for every chunk; one line a second is a progress report, and one
        // line a chunk is a wall of them.
        var lastShown = Date.distantPast
        if case .failure(let error) = Download.fetch(source, to: image, progress: { done, total in
            guard Date().timeIntervalSince(lastShown) > 1 else { return }
            lastShown = Date()
            progress(DependencyCopy.downloadProgress(dependency, done: done, total: total))
        }) {
            return .failure(error)
        }

        if let sha256 {
            progress(DependencyCopy.checkingDigest(dependency))
            let actual = try? Digest.sha256(of: image)
            guard DependencyInstaller.digestMatches(actual, expected: sha256) else {
                return .failure(WinbarError("The \(dependency.name) download didn't match GitHub's checksum, so Winbar "
                                                + "didn't open it",
                                            DependencyCopy.digestFailed(dependency)))
            }
        }

        // Before anything opens it. A file that isn't notarized, or that a different team signed,
        // is deleted and the run stops here.
        progress(DependencyCopy.checkingDownload(dependency))
        let assessment = Gatekeeper.assess(image.path)
        guard Gatekeeper.trusted(assessment, team: dependency.teamID) else {
            return .failure(WinbarError("The \(dependency.name) download didn't check out, so Winbar didn't open it",
                                        DependencyCopy.assessmentFailed(dependency, assessment)))
        }
        progress(DependencyCopy.downloadTrusted(dependency, assessment: assessment))

        let mountPoint = work.appendingPathComponent("mount", isDirectory: true)
        do { try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true) } catch {
            return .failure(WinbarError("Couldn't make a folder to open the disk image in", "\(error.localizedDescription)"))
        }
        let attached: DiskImage.Attachment
        switch DiskImage.attach(image.path, at: mountPoint.path) {
        case .failure(let failure):
            return .failure(WinbarError("Couldn't open the \(dependency.name) disk image", failure.reason))
        case .success(let attachment):
            attached = attachment
        }
        defer { if attached.owned { _ = DiskImage.detach(attached) } }

        let bundle = URL(fileURLWithPath: attached.mountPoint).appendingPathComponent("\(dependency.name).app")
        guard FileManager.default.fileExists(atPath: bundle.path) else {
            return .failure(WinbarError("The disk image has no \(dependency.name).app in it",
                                        "It was signed by \(dependency.vendor) and notarized by Apple, but it isn't "
                                            + "what Winbar expected. Nothing was installed."))
        }
        // The same checks the installed copy gets, run on the copy inside the image before anything
        // of it is written to /Applications. Anything but a clean pass stops here: a copy Winbar
        // wouldn't accept afterwards has no business being installed first.
        let inside = AppSignature.read(bundle.path, expectedTeam: dependency.teamID)
        switch Dependencies.state(of: dependency, app: inside) {
        case .installed:
            break
        case .wrongSignature(let detail):
            return .failure(WinbarError("The \(dependency.name) in the disk image isn't the app Winbar expected", detail))
        case .tooOld(let version, let minimum):
            return .failure(WinbarError("The \(dependency.name) download is \(version), and Winbar needs \(minimum)",
                                        "Nothing was installed. " + DependencyCopy.byHand(dependency)))
        case .missing:
            return .failure(WinbarError("Couldn't read the \(dependency.name) in the disk image",
                                        "Nothing was installed. " + DependencyCopy.byHand(dependency)))
        }

        let destination = URL(fileURLWithPath: "/Applications").appendingPathComponent("\(dependency.name).app")
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            return .failure(WinbarError("\(destination.path) already exists",
                                        "Winbar won't replace an app that's already there. Move it aside, or open "
                                            + "the disk image yourself."))
        }
        // A plain copy, which is what dragging it across does. The app doesn't carry macOS's
        // "downloaded from the internet" mark, so it opens without that prompt — the checks above
        // are the same ones that prompt would have run, and they have already passed.
        progress(DependencyCopy.copying(dependency, to: destination.path))
        do {
            try FileManager.default.copyItem(at: bundle, to: destination)
        } catch {
            keepDownload = true   // so the person can finish it by hand
            return .failure(WinbarError("Couldn't copy \(dependency.name) to /Applications",
                                        "\(error.localizedDescription) Winbar never uses sudo. The disk image is "
                                            + "still at \(image.path): open it and drag \(dependency.name) to your "
                                            + "Applications folder."))
        }
        return verify(dependency, progress: progress)
    }
}

// MARK: - Downloading

/// One file, with progress. Kept separate from the Guest Tools' downloader, which resumes and checks
/// a pinned SHA-256: this one fetches a file whose version changes, and trusts Apple's notarization
/// and the signing team instead of a hash Winbar would have to keep up to date.
enum Download {
    /// Blocking. `progress` gets (bytes so far, total) on URLSession's queue.
    static func fetch(_ url: URL, to destination: URL, timeout: TimeInterval = 3600,
                      progress: @escaping (Int64, Int64) -> Void) -> Result<Void, WinbarError> {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60          // no bytes for a minute
        configuration.timeoutIntervalForResource = timeout
        let receiver = Receiver(progress: progress)
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: receiver, delegateQueue: queue)
        defer { session.finishTasksAndInvalidate() }
        session.downloadTask(with: url).resume()
        guard receiver.done.wait(timeout: .now() + timeout + 60) == .success else {
            return .failure(WinbarError("The download didn't finish", "It was still going after \(Int(timeout / 60)) minutes."))
        }
        if let error = receiver.error {
            return .failure(WinbarError("Couldn't download \(url.lastPathComponent)", error))
        }
        guard let temporary = receiver.file else {
            return .failure(WinbarError("Couldn't download \(url.lastPathComponent)", "nothing arrived"))
        }
        do {
            try FileManager.default.moveItem(at: temporary, to: destination)
        } catch {
            return .failure(WinbarError("Couldn't save \(url.lastPathComponent)", "\(error.localizedDescription)"))
        }
        return .success(())
    }

    private final class Receiver: NSObject, URLSessionDownloadDelegate {
        let done = DispatchSemaphore(value: 0)
        private let progress: (Int64, Int64) -> Void
        private(set) var file: URL?
        private(set) var error: String?

        init(progress: @escaping (Int64, Int64) -> Void) {
            self.progress = progress
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            progress(totalBytesWritten, totalBytesExpectedToWrite)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {
            if let response = downloadTask.response as? HTTPURLResponse, response.statusCode != 200 {
                error = "the server answered \(response.statusCode)"
                done.signal()
                return
            }
            // URLSession deletes `location` when this returns, so it is moved out of the way first.
            let kept = location.deletingLastPathComponent().appendingPathComponent("winbar-\(UUID().uuidString)")
            do {
                try FileManager.default.moveItem(at: location, to: kept)
                file = kept
            } catch {
                self.error = error.localizedDescription
            }
            done.signal()
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error, file == nil {
                self.error = error.localizedDescription
                done.signal()
            }
        }
    }
}

// MARK: - The words

/// What Winbar says before it installs anything: what will be downloaded, roughly how big it is,
/// where it comes from, and who is doing the installing. Winbar asks Homebrew (or Apple's App
/// Store) to do it; it doesn't pretend to do it itself.
enum DependencyCopy {
    static func shell(_ command: (tool: String, arguments: [String])) -> String {
        ([(command.tool as NSString).lastPathComponent] + command.arguments).joined(separator: " ")
    }

    /// The heading: what this app is, and where it stands on this Mac.
    static func situation(_ dependency: Dependency, state: DependencyState) -> String {
        switch state {
        case .installed(let version):
            return "\(dependency.name) \(version ?? "")".trimmingCharacters(in: .whitespaces)
        case .missing:
            return "\(dependency.name) isn't installed. " + dependency.what
        case .tooOld(let version, let minimum):
            return "\(dependency.name) \(version) is installed, and Winbar needs \(minimum) or later."
        case .wrongSignature(let detail):
            return detail
        }
    }

    /// The paragraph before the question. Everything the person needs to decide: what is fetched,
    /// how big, from whom, and who does the installing.
    ///
    /// `utm` is which UTM a fresh install gets (`UTMChannels.pick`): its size when UTM's release said
    /// one, and which release a download comes from. Only a UTM install reads it.
    static func plan(_ dependency: Dependency, _ plan: InstallPlan, utm: UTMPick = .stable) -> [String] {
        let megabytes = utm.megabytes.map { "about \($0) MB" }
        switch plan {
        case .brew(let brew, let cask):
            var lines = ["Homebrew is on this Mac (\(brew)), so Winbar can ask it to install \(dependency.name): "
                            + "\(shell(Homebrew.installCommand(brew: brew, cask: cask))). Homebrew downloads it from "
                            + "\(dependency.vendor)'s own release, checks it against the cask's own checksum and "
                            + "installs it. Winbar doesn't download or install it itself, and never uses sudo."]
            switch dependency {
            case .utm:
                // The installed size was measured for the stable release only; a beta's isn't claimed.
                let size = [megabytes.map { $0 + " to download" },
                            utm.channel == .stable ? Dependency.utmInstalledGB + " once installed" : nil].compactMap { $0 }
                lines.append((size.isEmpty ? "" : "That's " + size.joined(separator: ", and ") + ". ")
                                + "It takes a few minutes; Homebrew's own output appears below as it goes.")
            case .windowsApp:
                lines.append("That's about \(Dependency.windowsAppDownloadMB) MB. Microsoft ships Windows App as an "
                                + "installer package, so Homebrew runs it with macOS's installer and macOS asks for your "
                                + "Mac password. That prompt is Homebrew's, not Winbar's — Winbar never asks for your "
                                + "password and never runs anything as an administrator.")
            }
            return lines
        case .brewUpgrade(let brew, let cask):
            // Offered only for a copy Homebrew installed (`Dependencies.plan`'s `brewHasCask`). The
            // cask's `uninstall quit:` makes Homebrew quit a running app before replacing it and open it
            // again after (cask/artifact/abstract_uninstall.rb); for UTM that stops its VMs.
            let quits = dependency == .utm
                ? " If UTM is open, Homebrew quits it first — any VM running in it stops — and opens it again afterwards."
                : " If \(dependency.name) is open, Homebrew quits it first and opens it again afterwards."
            // Homebrew's path beside Homebrew, where the install's plan puts it: after "this UTM" it
            // read as where UTM is.
            return ["Homebrew (\(brew)) installed this \(dependency.name), so Winbar can ask it to update it: "
                        + "\(shell(Homebrew.upgradeCommand(brew: brew, cask: cask))). Homebrew downloads the new version "
                        + "from \(dependency.vendor) and replaces the copy it installed." + quits + " Winbar never uses sudo."]
        case .download(_, let sha256):
            // Which release: the beta's own, or the stable one getutm.app links to.
            let release = utm.channel == .beta
                ? "from UTM's \(utm.build.map { $0.version + " " } ?? "")beta release at github.com/utmapp/UTM"
                : "from UTM's own release at github.com/utmapp/UTM — the download getutm.app links to"
            let checks = sha256 == nil
                ? "Before opening it, Winbar checks that Apple notarized it and that \(dependency.vendor) "
                    + "(team \(dependency.teamID)) signed it; if either fails, nothing is opened and Winbar stops."
                : "Before opening it, Winbar checks it against GitHub's checksum for that release, that Apple notarized "
                    + "it and that \(dependency.vendor) (team \(dependency.teamID)) signed it; if any of them fails, "
                    + "nothing is opened and Winbar stops."
            return ["Homebrew isn't on this Mac, and Winbar won't install a package manager for you.",
                    "Winbar can fetch \(dependency.name) itself instead: UTM.dmg\(megabytes.map { ", " + $0 } ?? ""), "
                        + release + ". " + checks + " Then it copies \(dependency.name).app to your Applications "
                        + "folder and ejects the image. No sudo, and nothing else on your Mac is touched."]
        case .appStore:
            return ["Homebrew isn't on this Mac, and Winbar won't install a package manager for you.",
                    "Microsoft only ships \(dependency.name) through the Mac App Store, and nobody can install an App "
                        + "Store app for you — it needs your Apple Account. Winbar can open its page; the Get button is "
                        + "yours to press. It's about \(Dependency.windowsAppDownloadMB) MB."]
        case .manual(let advice):
            return [advice]
        }
    }

    /// The question itself, in the words of what it will do.
    static func question(_ dependency: Dependency, _ plan: InstallPlan, utm: UTMPick = .stable) -> String {
        switch plan {
        case .brew: return "Ask Homebrew to install \(dependency.name) now?"
        case .brewUpgrade: return "Ask Homebrew to update \(dependency.name) now?"
        case .download:
            return "Download \(dependency.name)\(utm.megabytes.map { " (about \($0) MB)" } ?? "") and install it?"
        case .appStore: return "Open \(dependency.name) in the App Store?"
        case .manual: return ""
        }
    }

    /// The manual command, kept for anyone who would rather do it themselves — and for a run with no
    /// terminal to ask on.
    static func byHand(_ dependency: Dependency) -> String {
        switch dependency {
        case .utm:
            return "brew install --cask utm, or download it from getutm.app and drag UTM to your Applications folder."
        case .windowsApp:
            return "brew install --cask windows-app, or get Windows App from the Mac App Store."
        }
    }

    static func nothingWithoutYes(_ dependency: Dependency) -> String {
        "Nothing was installed. \(dependency.name) by hand: " + byHand(dependency)
    }

    static func unattended(_ dependency: Dependency, _ plan: InstallPlan) -> String {
        if case .appStore = plan {
            return "--yes can't press Get in the App Store. Install \(dependency.name) from the App Store, then run "
                + "winbar setup again."
        }
        return "--yes doesn't download and install apps by itself. Run winbar setup without --yes, or do it by hand: "
            + byHand(dependency)
    }

    static func updateByHand(_ dependency: Dependency) -> String {
        "Update it from \(dependency.name)'s own Check for Updates, from the Mac App Store, or with "
            + "brew upgrade --cask \(dependency.cask) — whichever way you installed it."
    }

    static func wrongSignatureAdvice(_ dependency: Dependency) -> String {
        "Winbar won't replace an app that's already installed. Remove or rename that copy and install \(dependency.name) "
            + "again from \(dependency.vendor): " + byHand(dependency)
    }

    // Progress lines.

    static func askingHomebrew(_ dependency: Dependency, command: (tool: String, arguments: [String])) -> String {
        "Asking Homebrew: \(shell(command))  (this takes a few minutes; its output follows)"
    }

    static func downloading(_ dependency: Dependency, from url: URL) -> String {
        "Downloading \(dependency.name) from \(url.host ?? url.absoluteString)…"
    }

    static func downloadProgress(_ dependency: Dependency, done: Int64, total: Int64) -> String {
        guard total > 0 else { return "\(dependency.name): \(done >> 20) MB" }
        return "\(dependency.name): \(done >> 20) of \(total >> 20) MB (\(Int(Double(done) / Double(total) * 100))%)"
    }

    static func checkingDigest(_ dependency: Dependency) -> String {
        "Checking the download against GitHub's checksum for it…"
    }

    static func digestFailed(_ dependency: Dependency) -> String {
        "It isn't the file GitHub published for that release. It was deleted and nothing was installed. Try again, or "
            + "get \(dependency.name) yourself: " + byHand(dependency)
    }

    static func checkingDownload(_ dependency: Dependency) -> String {
        "Checking Apple's notarization and \(dependency.vendor)'s signature before opening it…"
    }

    static func downloadTrusted(_ dependency: Dependency, assessment: Gatekeeper.Assessment) -> String {
        "Signed by \(assessment.origin ?? dependency.vendor)" + (assessment.source.map { ", \($0.lowercased())" } ?? "")
    }

    static func assessmentFailed(_ dependency: Dependency, _ assessment: Gatekeeper.Assessment) -> String {
        var why = assessment.accepted
            ? "Apple's check passed, but it was signed by \(assessment.origin ?? "someone else"), not by "
                + "\(dependency.vendor) (team \(dependency.teamID))."
            : "macOS wouldn't vouch for it (\(assessment.source ?? "its check gave no answer"))."
        why += " The file was deleted and nothing was installed. Get \(dependency.name) yourself: " + byHand(dependency)
        return why
    }

    static func copying(_ dependency: Dependency, to path: String) -> String {
        "Copying \(dependency.name) to \(path)…"
    }

    static func checking(_ dependency: Dependency) -> String {
        "Checking \(dependency.name)'s signature and version…"
    }

    static func installed(_ dependency: Dependency, version: String?) -> String {
        "\(dependency.name) \(version ?? "")".trimmingCharacters(in: .whitespaces)
            + " is installed, signed by \(dependency.vendor), and new enough for Winbar."
    }

    /// While the person is in the App Store.
    static func waitingForAppStore(_ dependency: Dependency) -> String {
        "The App Store is open at \(dependency.name). Press Get (or Open, if you've had it before), wait for it to "
            + "install, then come back here."
    }
}

/// macOS's "downloaded from the internet" mark, read and never written: changing another app's
/// bundle needs App Management permission, which Winbar doesn't ask for and doesn't need. (Homebrew,
/// run by Winbar to update UTM, can ask for it in Winbar's name: `SetupCopy.LookAround.updateMayAsk`.) Homebrew
/// leaves the mark on a cask it installs, and someone who goes looking will find it, so Winbar can
/// at least say what it is.
enum Quarantine {
    static let name = "com.apple.quarantine"

    static func isMarked(_ path: String?) -> Bool {
        guard let path else { return false }
        return getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }
}

/// What still has to happen after UTM is installed, and the words for when it doesn't.
///
/// Installing UTM is not the end of it. Everything Winbar asks of UTM — utmctl and AppleScript
/// alike — is an Apple Event, and macOS holds the first one to a freshly installed app until
/// somebody answers "“…” wants access to control “UTM”". Until then utmctl sits there at no CPU and says
/// nothing at all, which looks exactly like a hung Winbar. Seen live: right after a Homebrew
/// install, utmctl slept while a direct Apple Event from an already-approved terminal answered at
/// once.
enum UTMFirstUse {
    /// Said the moment UTM is installed, before anything asks it anything.
    static var expectAPrompt: String {
        "Two things still have to happen once, and only you can do them: open UTM from your "
            + "Applications folder, and answer macOS's prompt, \(Automation.promptWords(host: Automation.host.name)), "
            + "with Allow — that's how Winbar starts, stops and reconfigures the VM. The prompt can open behind other "
            + "windows, and it waits for as long as it takes, so a Mac left locked or unattended never gets "
            + "past it. If Winbar seems to stop right here, that's what to look for."
    }

    static let waiting = "Checking that Winbar can drive UTM (this is where the permission prompt appears)…"

    static func stillWaiting(seconds: Int) -> String {
        "Still nothing from utmctl after \(seconds) seconds. If the prompt is on screen, choose Allow; "
            + "it may be behind another window."
    }

    /// The bounded wait: utmctl is asked the cheapest question it has, and asked again, up to
    /// `attempts` times. It stops the moment there is any answer at all. Blocking.
    static func settle(attempts: Int = 3, each: TimeInterval = 20,
                       progress: (String) -> Void) -> UTM.CtlAnswer {
        let rounds = max(1, attempts)
        for attempt in 1...rounds {
            progress(attempt == 1 ? waiting : stillWaiting(seconds: Int(each) * (attempt - 1)))
            let answer = UTM.ctlAnswers(timeout: each)
            if case .silent = answer { continue }
            return answer
        }
        return .silent(seconds: Int(each) * rounds)
    }

    /// How the advice ends at a terminal: there is nothing to press, so the next step is a command.
    static let terminalRetry = "run winbar doctor again"

    /// What to do about a utmctl that says nothing, at a terminal. Pure, and it says which of the two
    /// states this is: macOS has never been asked about this pair (so a prompt is outstanding), or it
    /// has an answer already (so the switch in System Settings is the place to look).
    ///
    /// The setup window says it its own way (`SetupCopy.LookAround.silent`): it has opened UTM itself,
    /// so "open UTM from your Applications folder" would ask for what's done, and it has a button
    /// where this has a command.
    static func how(consent: Automation.Consent, quarantined: Bool,
                    host: String = Automation.host.name, bundleID: String? = Automation.host.bundleID) -> String {
        var text = "Open UTM from your Applications folder, and look for macOS's prompt, "
            + "\(Automation.promptWords(host: host)) — it can be behind another window. Choose Allow, then "
            + "\(terminalRetry)."
        switch consent {
        case .wouldPrompt:
            text += " macOS has never been asked whether \(host) may control UTM, so that prompt is still outstanding: "
                + "nothing Winbar asks of UTM can finish until it is answered."
        case .unknown:
            text += " macOS wouldn't say whether \(host) may control UTM either — which is what a Mac looks like when "
                + "that first request is the one still waiting."
        case .decided:
            text += " macOS already has an answer for this pair, so check UTM under \(host) in System Settings → "
                + "Privacy & Security → Automation."
            if let bundleID { text += " To get the prompt back instead: tccutil reset AppleEvents \(bundleID)." }
        }
        if quarantined {
            text += " (Homebrew leaves macOS's “downloaded from the internet” mark on the app. That is normal, it "
                + "can't be removed from a terminal — since macOS 14 that needs App Management permission — and it "
                + "isn't what a silent utmctl is waiting for: macOS opens UTM and lets it answer Apple Events with "
                + "the mark in place.)"
        }
        return text
    }

    /// The row H9 shows for a utmctl that never answered. Pure.
    static func silentDetail(seconds: Int) -> String {
        "UTM is installed, but its command-line tool said nothing for \(seconds) seconds"
    }
}

// MARK: - The conversation

/// One dependency, at the terminal: where it stands, what Winbar would do, the question, and the
/// verification. Shared by `winbar setup` and `winbar create`, so both ask in the same words.
enum DependencySetup {
    /// How `winbar setup` chooses which UTM a fresh install gets: `requested` is `--utm-channel`.
    /// `winbar create` passes none, and installs stable as it always has.
    struct ChannelChoice {
        var requested: UTMChannel?
    }

    /// Returns whether the app is installed and verified when this returns. `assumeYes` is `--yes`,
    /// which only ever answers for Homebrew (see `mayProceedUnattended`), and picks stable UTM.
    /// `chooseUTM` offers the stable/beta choice when UTM is missing (`UTMChannelDecision`); never
    /// for a UTM that's there, which is never switched.
    @discardableResult
    static func offer(_ dependency: Dependency, assumeYes: Bool, indent: String = "   ",
                      chooseUTM: ChannelChoice? = nil) -> Bool {
        let state = Dependencies.state(of: dependency)
        if case .installed = state { return true }

        func say(_ text: String) {
            print(indent + CreateCopy.wrap(text, width: CreateCopy.width - indent.count, indent: indent))
        }
        print("")
        print(indent + CreateCopy.wrap(DependencyCopy.situation(dependency, state: state),
                                       width: CreateCopy.width - indent.count, indent: indent))

        var utm = UTMPick.stable
        if dependency == .utm, case .missing = state, let chooseUTM {
            guard let picked = chooseChannel(chooseUTM, assumeYes: assumeYes, say: say, indent: indent) else { return false }
            utm = picked
        }
        guard let plan = Dependencies.plan(for: dependency, state: state, brew: Homebrew.path,
                                           brewCask: Homebrew.installedCask(dependency, brew: Homebrew.path),
                                           utm: utm) else {
            return true
        }
        for line in DependencyCopy.plan(dependency, plan, utm: utm) { say(line) }

        if case .manual = plan { return false }
        if assumeYes, !DependencyInstaller.mayProceedUnattended(plan) {
            say(DependencyCopy.unattended(dependency, plan))
            return false
        }
        guard Term.stdinIsTTY || assumeYes else {
            say("No terminal to ask on, so nothing was installed. " + DependencyCopy.byHand(dependency))
            return false
        }
        let agreed = Term.confirm(DependencyCopy.question(dependency, plan, utm: utm), assumeYes: assumeYes,
                                  defaultYes: true)
        guard agreed else {
            say(DependencyCopy.nothingWithoutYes(dependency))
            return false
        }

        switch DependencyInstaller.install(dependency, plan: plan, agreed: agreed, progress: { Term.note(indent + $0) }) {
        case .failure(let error):
            print(indent + Term.paint("✗", .red) + " " + CreateCopy.wrap("\(error)", width: CreateCopy.width - indent.count,
                                                                          indent: indent + "  "))
            return false
        case .success(.refused(let why)):
            say(why)
            return false
        case .success(.handedOff):
            say(DependencyCopy.waitingForAppStore(dependency))
            // Nothing else can be done from here: the Get button is theirs. Wait, then check.
            guard Term.stdinIsTTY, Term.waitForStep() == .done else { return false }
            switch DependencyInstaller.verify(dependency) {
            case .success(.installed(let version)):
                print(indent + Term.paint("✓", .green) + " " + DependencyCopy.installed(dependency, version: version))
                return true
            case .success, .failure:
                say("\(dependency.name) still isn't installed. " + DependencyCopy.byHand(dependency))
                return false
            }
        case .success(.installed(let version)):
            print(indent + Term.paint("✓", .green) + " " + DependencyCopy.installed(dependency, version: version))
            if dependency == .utm { settleUTM(say: say, indent: indent) }
            return true
        }
    }

    /// Which UTM to install: `--utm-channel` if given, stable for `--yes`, otherwise the question
    /// when there's a beta to offer. GitHub is asked only when the answer could matter (`--yes` alone
    /// is stable whatever it says). nil when nothing should be installed: `--utm-channel beta` with
    /// no beta on offer.
    private static func chooseChannel(_ choice: ChannelChoice, assumeYes: Bool, say: (String) -> Void,
                                      indent: String) -> UTMPick? {
        if choice.requested == nil, assumeYes { return .stable }
        let brew = Homebrew.path
        let offer = UTMChannels.current(brew: brew)
        let channel: UTMChannel
        switch UTMChannelDecision.decide(requested: choice.requested, assumeYes: assumeYes, offered: offer.offersChoice) {
        case .betaUnavailable:
            say(UTMChannelCopy.betaUnavailable(offer))
            return nil
        case .install(let chosen):
            channel = chosen
        case .ask:
            channel = Term.stdinIsTTY ? askChannel(offer, indent: indent) : .stable
        }
        if offer.couldNotCheck { say(UTMChannelCopy.couldNotCheck) }
        return UTMChannels.pick(channel, from: offer, homebrew: brew != nil)
    }

    /// The two options, then `[1] stable (recommended) [2] beta`, asked until it's answered.
    private static func askChannel(_ offer: UTMChannels.Offer, indent: String) -> UTMChannel {
        let width = CreateCopy.width - indent.count - 4
        print("")
        print(indent + Term.paint(UTMChannelCopy.heading, .bold))
        let options = [(UTMChannelCopy.stableTitle(offer.stable), UTMChannelCopy.stableBody(offer.stable))]
            + (offer.beta.map { [(UTMChannelCopy.betaTitle($0), UTMChannelCopy.betaBody($0))] } ?? [])
        for (number, option) in options.enumerated() {
            print(indent + "[\(number + 1)] " + CreateCopy.wrap(option.0 + ". " + option.1, width: width,
                                                                indent: indent + "    "))
        }
        while true {
            print(indent + UTMChannelCopy.prompt, terminator: "")
            fflush(stdout)
            if let channel = UTMChannelDecision.answer(readLine()) { return channel }
        }
    }

    /// A freshly installed UTM answers nothing until macOS has been allowed to let Winbar drive it,
    /// and it says nothing while it waits. So the install doesn't end with "✓ installed": it ends
    /// once utmctl has actually answered, or with what to do about it having not.
    private static func settleUTM(say: (String) -> Void, indent: String) {
        say(UTMFirstUse.expectAPrompt)
        switch UTMFirstUse.settle(progress: { line in
            Term.note(indent + CreateCopy.wrap(line, width: CreateCopy.width - indent.count, indent: indent))
        }) {
        case .answered:
            print(indent + Term.paint("✓", .green) + " UTM answers Winbar.")
        case .denied:
            let denied = Automation.deniedError()
            print(indent + Term.paint("✗", .red) + " \(denied.title)")
            say(denied.detail)
        case .silent(let seconds):
            print(indent + Term.paint("!", .yellow) + " " + UTMFirstUse.silentDetail(seconds: seconds))
            say(UTMFirstUse.how(consent: Automation.consent(bundleID: Config.utmBundleID),
                                quarantined: Quarantine.isMarked(UTM.appURL?.path)))
        case .failed(let detail):
            print(indent + Term.paint("!", .yellow) + " utmctl: \(detail)")
        }
    }
}
