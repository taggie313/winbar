import Foundation

/// Telling someone that a newer Winbar exists — and nothing more than telling them.
///
/// Why it exists at all: there are two ways in now. `brew upgrade` looks after the people who used
/// Homebrew; someone who dragged the app out of the disk image has nothing that would ever mention
/// a new version, and a menu bar app nobody quits can sit on a year-old build quite happily.
///
/// What it deliberately is not: no Sparkle, no framework, no download, no install, no background
/// daemon, no second request when the first one fails, and nothing on screen when anything goes
/// wrong. One GET a day, and at most one extra menu item. Everything below is written so that every
/// failure — offline, a captive portal, GitHub's rate limit, a body that isn't JSON, a tag that
/// isn't a version — ends in the same place: silence.
enum UpdateCheck {
    /// The repository releases come from. Deliberately not a setting: a key that pointed this at
    /// another host would be a way to make Winbar fetch from anywhere.
    static let repo = "taggie313/winbar"

    /// Where a person is sent. `/releases/latest` redirects to whatever the newest release is, so
    /// the link keeps working without knowing a version.
    static let releasesURL = URL(string: "https://github.com/\(repo)/releases/latest")!

    /// GitHub's public API for the same thing. No token: anonymous requests are limited to 60 an
    /// hour per address, which one a day is comfortably inside even on a shared one.
    static let apiURL = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!

    /// At most one check a day.
    static let interval: TimeInterval = 24 * 60 * 60

    /// What someone who installed with Homebrew is told to run.
    static let brewCommand = "brew upgrade --cask winbar"

    // MARK: - Versions

    /// A semantic version, in exactly as much detail as comparing two of them needs. Build
    /// metadata is parsed and thrown away, because SemVer says it takes no part in precedence.
    struct Version: Comparable, Equatable {
        /// Major, minor, patch — always three.
        var numbers: [Int]
        /// The dot-separated identifiers after the first "-", empty for a released version.
        var prerelease: [String]

        static func < (lhs: Version, rhs: Version) -> Bool {
            for (left, right) in zip(lhs.numbers, rhs.numbers) where left != right { return left < right }
            // A release outranks any pre-release of the same numbers: 1.0.0-beta.1 < 1.0.0.
            if lhs.prerelease.isEmpty != rhs.prerelease.isEmpty { return !lhs.prerelease.isEmpty }
            for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
                switch (numericIdentifier(left), numericIdentifier(right)) {
                case let (left?, right?): return left < right
                case (nil, _?): return false   // a numeric identifier always ranks below a word
                case (_?, nil): return true
                case (nil, nil): return left < right
                }
            }
            // All the identifiers they share are equal, so the one with more of them is later:
            // 1.0.0-beta < 1.0.0-beta.1.
            return lhs.prerelease.count < rhs.prerelease.count
        }
    }

    /// An all-digits identifier as a number. "-1" and "0x2" are words, not numbers, however much
    /// `Int()` would like to read them.
    static func numericIdentifier(_ text: String) -> Int? {
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(text)
    }

    /// `0.2.0`, `v0.2.0`, `0.2.0-beta.1`, `0.2.0+build.5`. nil for everything else — including the
    /// "dev" that `AppBundle.version` reports for a bare `swift build`, because a build with no
    /// version of its own can't sensibly be told it is out of date.
    static func parse(_ text: String) -> Version? {
        var core = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if core.hasPrefix("v") || core.hasPrefix("V") { core.removeFirst() }
        if let plus = core.firstIndex(of: "+") { core = String(core[core.startIndex..<plus]) }   // build metadata
        var prerelease: [String] = []
        if let dash = core.firstIndex(of: "-") {
            let tail = String(core[core.index(after: dash)...])
            core = String(core[core.startIndex..<dash])
            prerelease = tail.components(separatedBy: ".")
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
            guard !prerelease.contains(where: { $0.isEmpty || $0.rangeOfCharacter(from: allowed.inverted) != nil })
            else { return nil }
        }
        let parts = core.components(separatedBy: ".")
        guard parts.count == 3 else { return nil }
        let numbers = parts.compactMap(numericIdentifier)
        guard numbers.count == 3 else { return nil }
        return Version(numbers: numbers, prerelease: prerelease)
    }

    /// Whether `candidate` is worth telling someone about, next to what is running. False whenever
    /// either side doesn't parse, which is how an unversioned build, a junk answer and a tag that
    /// isn't a version all end up silent. Equal versions are not news either.
    static func isNewer(_ candidate: String, than running: String) -> Bool {
        guard let candidate = parse(candidate), let running = parse(running) else { return false }
        return running < candidate
    }

    /// The `tag_name` from GitHub's "latest release" answer, as a version.
    ///
    /// nil for everything else, which covers being rate-limited (an object with a `message` and no
    /// tag), a proxy's HTML login page, and a body that was cut off. The size limit is there
    /// because nothing says the other end has to send what we expect, and a release payload is a
    /// few kilobytes.
    ///
    /// GitHub's `/releases/latest` never returns a draft or a pre-release, so what comes back is
    /// always something a person could install.
    static func version(fromJSON data: Data) -> String? {
        guard data.count <= 1 << 20,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tag = object["tag_name"] as? String,
              parse(tag) != nil
        else { return nil }
        return tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }

    // MARK: - When to ask

    /// Whether a check is due. A date in the future — the clock was moved back, or a settings file
    /// was copied from another Mac — counts as due, so a wrong clock can't switch the check off
    /// for years.
    static func isDue(lastChecked: Date?, now: Date, every: TimeInterval = interval) -> Bool {
        guard let lastChecked else { return true }
        if lastChecked > now { return true }
        return now.timeIntervalSince(lastChecked) >= every
    }

    // MARK: - How Winbar got here

    /// Where Homebrew records what it has installed. The environment first, because that is what
    /// Homebrew's own `shellenv` sets and it is right even for a prefix nobody would guess; then
    /// the two standard ones, Apple silicon's and Intel's.
    static func caskroomPaths(environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        homebrewPrefixes(environment: environment).map { $0 + "/Caskroom/winbar" }
    }

    /// Where Homebrew might be, most specific first. Split out from `caskroomPaths` because
    /// `winbar diagnose` asks the same question of a different file (`<prefix>/bin/brew`), and one
    /// list of prefixes is one place to be wrong.
    static func homebrewPrefixes(environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        var prefixes: [String] = []
        if let prefix = environment["HOMEBREW_PREFIX"], prefix.hasPrefix("/") { prefixes.append(prefix) }
        prefixes += ["/opt/homebrew", "/usr/local"]
        var seen = Set<String>()
        return prefixes.filter { seen.insert($0).inserted }
    }

    /// Whether this copy of Winbar came from the Homebrew cask, so its owner is told to
    /// `brew upgrade` instead of being sent to download a disk image (which would leave them with
    /// two copies, and `brew upgrade` still offering the old one).
    ///
    /// Two cheap facts and no `brew` process. `brew list --cask winbar` is the obvious answer, but
    /// Homebrew is a large Ruby program and takes the better part of a second to start — too much
    /// to spend deciding how to word a menu item. The cask puts the app in /Applications and leaves
    /// its receipt in `<prefix>/Caskroom/winbar`, so those two together are the same answer for the
    /// cost of a couple of `stat` calls, and no answer at all when Homebrew isn't installed.
    ///
    /// Someone who moved Homebrew's `appdir` is told to download instead; they will cope.
    static func isHomebrewInstall(appPath: String?, caskroomExists: Bool) -> Bool {
        guard let appPath, caskroomExists else { return false }
        return appPath == "/Applications/Winbar.app"
    }

    /// The same question, asked of this Mac. A `let`, so it is answered once: neither the bundle's
    /// path nor Homebrew's Caskroom changes while Winbar is running.
    static let isHomebrewInstall: Bool = {
        let caskroom = caskroomPaths().contains { FileManager.default.fileExists(atPath: $0) }
        return isHomebrewInstall(appPath: AppBundle.url?.path, caskroomExists: caskroom)
    }()

    /// The one menu item's title. Only the words change with how Winbar got here; both go to
    /// `AppDelegate.showUpdate`.
    static func menuTitle(version: String, homebrew: Bool) -> String {
        homebrew ? "Winbar \(version) is available: copy “brew upgrade”"
                 : "Winbar \(version) is available…"
    }

    // MARK: - Asking

    /// Asks GitHub, once, for the newest release's version.
    ///
    /// `completion` gets nil for every kind of no-answer, and is the only thing that ever happens:
    /// there is no retry, because the next launch after the interval is the retry. Off the calling
    /// thread from the first line — `dataTask` returns straight away.
    static func fetchLatestVersion(session: URLSession = .shared, timeout: TimeInterval = 10,
                                   completion: @escaping (String?) -> Void) {
        var request = URLRequest(url: apiURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        // GitHub refuses an anonymous request that doesn't say who is asking, and the documented
        // Accept header pins the answer's shape whatever the default becomes.
        request.setValue("Winbar/\(AppBundle.version)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        session.dataTask(with: request) { data, response, _ in
            guard let data, (response as? HTTPURLResponse)?.statusCode == 200,
                  let version = version(fromJSON: data)
            else { return completion(nil) }
            completion(version)
        }.resume()
    }

    /// A newer version Winbar already knew about, with no network at all: read at launch so the
    /// menu item is there before the day's check has answered, and still there on a Mac that has
    /// been offline since.
    static var knownNewerVersion: String? {
        guard let seen = Config.lastSeenVersion, isNewer(seen, than: AppBundle.version) else { return nil }
        return seen
    }

    /// The passive check, as the app runs it on launch. Returns immediately; nothing here can delay
    /// a launch, and `found` is called on the main queue only when there is genuinely something
    /// newer. Does nothing at all when a check isn't due yet.
    static func checkIfDue(now: Date = Date(), found: @escaping (String) -> Void) {
        guard isDue(lastChecked: Config.lastUpdateCheck, now: now) else { return }
        // Written before the request rather than after a good answer: an answer that never comes
        // (offline, a hotel portal, a rate limit) must still cost exactly one request a day.
        // Recording only successes would mean asking again at every launch for as long as the Mac
        // can't reach GitHub, which is the loop this must never become.
        Config.lastUpdateCheck = now
        fetchLatestVersion { version in
            guard let version else { return }   // silent, always
            // Stored whether or not it is newer: it is "what the last check saw", and storing it
            // means the day after an upgrade the menu item is gone without asking anyone.
            Config.lastSeenVersion = version
            guard isNewer(version, than: AppBundle.version) else { return }
            DispatchQueue.main.async { found(version) }
        }
    }

    /// `winbar --version --check`: the same check, asked for on purpose, so it ignores the daily
    /// throttle and is the one place Winbar waits for the network and says so when it fails.
    /// Always exits 0 — "there is an update" is news, not an error.
    static func report(now: Date = Date()) -> Int32 {
        let semaphore = DispatchSemaphore(value: 0)
        var latest: String?
        // Safe on the main thread: URLSession calls back on its own queue, never this one.
        fetchLatestVersion { latest = $0; semaphore.signal() }
        _ = semaphore.wait(timeout: .now() + 20)
        guard let latest else {
            print("Couldn't reach GitHub to check for a newer version.")
            return 0
        }
        Config.lastSeenVersion = latest
        Config.lastUpdateCheck = now
        if isNewer(latest, than: AppBundle.version) {
            print("Winbar \(latest) is available.")
            print("  " + (isHomebrewInstall ? brewCommand : releasesURL.absoluteString))
        } else if parse(AppBundle.version) == nil {
            print("The newest release is \(latest); this build has no version of its own to compare.")
        } else {
            print("That is the newest release.")
        }
        return 0
    }
}
