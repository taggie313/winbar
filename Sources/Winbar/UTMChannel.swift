import Foundation

// Which UTM a fresh install gets while UTM's next major version is a beta: the stable release, or
// the beta, chosen by the person (docs/internal/UTM5-SPIKE-RESEARCH.md §6, the owner's decisions of
// 2026-09-25).
//
// The rules this file keeps to:
//   · Offered for a fresh install only. A UTM that is there is never switched: both channels are
//     the same app (com.utmapp.UTM) with one VM library, and going between them has costs a person
//     should weigh in their own time (suspended states don't carry across).
//   · Stable is the default everywhere: preselected in the window, [1] at the terminal, and what
//     `--yes` picks.
//   · Nothing about a beta is baked in. Whether there is one worth offering is read from UTM's own
//     GitHub releases when UTM is being installed (one anonymous GET, cached a day, silent when it
//     fails), and the choice disappears by itself the day UTM's next major version ships stable.
//   · A beta is fetched only from its own tagged release, never `/releases/latest` (which skips
//     pre-releases and moves), and checked against GitHub's digest for it as well as Apple's
//     notarization and UTM's team, as every download Winbar opens is.

/// UTM's two release tracks, named as Homebrew names them.
enum UTMChannel: String, CaseIterable, Codable, Sendable {
    case stable
    case beta

    /// The Homebrew cask for each. They conflict: both install /Applications/UTM.app, so a Mac has
    /// one or the other, and an update has to go through the one that installed the copy
    /// (`Homebrew.installedCask`). Never uninstalled with `--zap`, by anything: both casks' zap
    /// trashes UTM's container, which is the whole VM library.
    var cask: String {
        switch self {
        case .stable: return "utm"
        case .beta: return "utm@beta"
        }
    }

    /// `--utm-channel stable|beta`. nil for anything else.
    init?(argument: String) {
        self.init(rawValue: argument.lowercased())
    }
}

/// One build of UTM Winbar could install: what GitHub's release (or Homebrew's cask) says about it.
struct UTMBuild: Equatable, Codable, Sendable {
    /// "4.7.5", without the tag's "v".
    var version: String
    /// The release's tag ("v4.7.5"), when it came from GitHub. nil when only Homebrew named it.
    var tag: String?
    /// The UTM.dmg asset's size, when the release has one.
    var bytes: Int64?
    /// The UTM.dmg asset's SHA-256 from GitHub's `digest`, lower-case hex.
    var sha256: String?

    init(version: String, tag: String? = nil, bytes: Int64? = nil, sha256: String? = nil) {
        self.version = version
        self.tag = tag
        self.bytes = bytes
        self.sha256 = sha256
    }

    /// The release's own UTM.dmg, by its tag: only when GitHub listed the asset, since a tag with no
    /// disk image would be a download that 404s. Built from the tag rather than taken from the
    /// answer's `browser_download_url`, so it can only ever point at utmapp/UTM on github.com.
    var dmgURL: String? {
        guard let tag, bytes != nil else { return nil }
        return "https://github.com/\(UTMChannels.repo)/releases/download/\(tag)/UTM.dmg"
    }

    /// The size as the copy says it: decimal megabytes, rounded, as "about 250 MB" always was.
    var megabytes: Int? { bytes.map { Int(($0 + 500_000) / 1_000_000) } }
}

/// One entry of GitHub's releases list: only what the rule reads.
struct UTMRelease: Equatable {
    var tag: String
    var draft: Bool
    var prerelease: Bool
    /// The release's UTM.dmg, when it has one.
    var dmg: Asset?

    struct Asset: Equatable {
        var bytes: Int64
        /// GitHub's `digest` for the asset, as lower-case hex; nil when GitHub gave none.
        var sha256: String?
    }
}

/// What UTM's releases allow: the stable build, and the beta when Winbar may offer it.
struct UTMChoice: Equatable, Codable, Sendable {
    var stable: UTMBuild
    var beta: UTMBuild?
}

/// Which build a fresh install gets: the channel the person chose, with what is known about it.
struct UTMPick: Equatable, Sendable {
    var channel: UTMChannel
    var build: UTMBuild?

    /// What every install before this choice existed got: the stable cask, or the download
    /// getutm.app links to.
    static let stable = UTMPick(channel: .stable, build: nil)

    /// Where Winbar fetches it on a Mac without Homebrew. The stable build's tagged release when
    /// GitHub named one, else `/releases/latest`, which redirects to the newest stable release. A
    /// beta is only ever its own tagged release: nil when there's no tag to fetch it by, and
    /// `UTMChannels.pick` never picks such a beta without Homebrew.
    var dmgURL: String? {
        if let url = build?.dmgURL { return url }
        return channel == .stable ? Dependency.utmDownloadURL : nil
    }

    /// The download's size for the copy: the release's, or the stable figure Winbar has always said.
    var megabytes: Int? {
        if let size = build?.megabytes { return size }
        return channel == .stable ? Dependency.utmDownloadMB : nil
    }
}

enum UTMChannels {
    static let repo = "utmapp/UTM"

    /// GitHub's releases list, newest first, drafts and pre-releases included. Twenty is weeks of
    /// UTM's releases, enough to reach back past a run of betas to the stable one.
    static let apiURL = URL(string: "https://api.github.com/repos/\(repo)/releases?per_page=20")!

    /// The oldest beta Winbar offers. 5.0.4 and 5.0.5 pinned a CocoaSpice revision that freed port
    /// writes early (UTM#7814) and lack the #7882 fix (PR #7899), which 5.0.6 is the first to carry:
    /// a choice that could install either would be offering the builds the research ruled out.
    static let betaFloor = "5.0.6"

    /// How long a check's answer is used without asking again, and how long it still stands in when
    /// asking fails.
    static let freshFor: TimeInterval = 24 * 60 * 60
    static let usableFor: TimeInterval = 7 * 24 * 60 * 60

    // MARK: - The rule (pure)

    /// The rule, exactly as §6 has it: drafts ignored; stable is the first release that isn't a
    /// pre-release; beta is the first pre-release newer than it; the beta is offered only when it is
    /// a major version ahead of stable, at least `betaFloor`, and has a UTM.dmg with a digest. nil
    /// when there's no stable release to anchor it, which callers treat as a check that failed.
    ///
    /// The day a 5.x ships stable, the newest beta is no longer a major version ahead (or there is no
    /// beta), so the choice goes away with no change to Winbar; a 5.1 beta beside a 5.0 stable is
    /// never offered.
    static func choice(from releases: [UTMRelease]) -> UTMChoice? {
        let published = releases.filter { !$0.draft }
        guard let stableRelease = published.first(where: { !$0.prerelease }),
              let stable = build(stableRelease), let stableVersion = UpdateCheck.parse(stable.version) else { return nil }
        let newer = published.first { release in
            release.prerelease && (UpdateCheck.parse(release.tag).map { stableVersion < $0 } ?? false)
        }
        guard let newer, let beta = build(newer), beta.sha256 != nil, beta.dmgURL != nil,
              offersBeta(beta.version, over: stable.version) else {
            return UTMChoice(stable: stable, beta: nil)
        }
        return UTMChoice(stable: stable, beta: beta)
    }

    /// Whether a beta of `beta` may be offered beside a stable `stable`: a major version ahead, and
    /// no older than `betaFloor`. False when either doesn't parse. Pure.
    static func offersBeta(_ beta: String, over stable: String) -> Bool {
        guard let beta = UpdateCheck.parse(beta), let stable = UpdateCheck.parse(stable),
              let floor = UpdateCheck.parse(betaFloor) else { return false }
        return beta.numbers[0] > stable.numbers[0] && !(beta < floor)
    }

    /// A release as a build: its version from the tag, and the disk image's size and digest. nil for
    /// a tag that isn't a version, or that has anything in it a URL path shouldn't.
    static func build(_ release: UTMRelease) -> UTMBuild? {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")
        guard !release.tag.isEmpty, release.tag.unicodeScalars.allSatisfy(allowed.contains),
              UpdateCheck.parse(release.tag) != nil else { return nil }
        let version = release.tag.hasPrefix("v") || release.tag.hasPrefix("V") ? String(release.tag.dropFirst()) : release.tag
        return UTMBuild(version: version, tag: release.tag, bytes: release.dmg?.bytes, sha256: release.dmg?.sha256)
    }

    // MARK: - Reading answers (pure)

    /// GitHub's releases list, as releases. nil for anything that isn't one: a rate limit's
    /// `{"message": …}`, a portal's HTML, a cut-off body. Capped at a few megabytes, since nothing
    /// says the other end sends what was asked for.
    static func releases(fromJSON data: Data) -> [UTMRelease]? {
        guard data.count <= 8 << 20,
              let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        return list.compactMap { object in
            guard let tag = object["tag_name"] as? String,
                  let draft = object["draft"] as? Bool, let prerelease = object["prerelease"] as? Bool else { return nil }
            let assets = object["assets"] as? [[String: Any]] ?? []
            let dmg = assets.first { $0["name"] as? String == "UTM.dmg" }.flatMap { asset -> UTMRelease.Asset? in
                guard let size = (asset["size"] as? NSNumber)?.int64Value, size > 0 else { return nil }
                return UTMRelease.Asset(bytes: size, sha256: sha256(fromDigest: asset["digest"] as? String))
            }
            return UTMRelease(tag: tag, draft: draft, prerelease: prerelease, dmg: dmg)
        }
    }

    /// "sha256:<64 hex>" as GitHub writes an asset's digest, to the hex. nil for any other algorithm
    /// or shape.
    static func sha256(fromDigest digest: String?) -> String? {
        guard let digest, digest.lowercased().hasPrefix("sha256:") else { return nil }
        return WindowsISO.normalizedSHA256(String(digest.dropFirst("sha256:".count)))
    }

    /// What Homebrew's two casks would install, from `brew info --json=v2 --cask utm utm@beta`.
    struct CaskVersions: Equatable, Sendable {
        var stable: String?
        var beta: String?
    }

    static func caskVersions(fromJSON data: Data) -> CaskVersions? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let casks = object["casks"] as? [[String: Any]] else { return nil }
        func version(_ token: String) -> String? {
            // A cask's version can carry a build after a comma ("1.2.3,456"); the version is before it.
            (casks.first { $0["token"] as? String == token }?["version"] as? String)
                .flatMap { $0.split(separator: ",").first.map(String.init) }
                .flatMap { UpdateCheck.parse($0) != nil ? $0 : nil }
        }
        let found = CaskVersions(stable: version(UTMChannel.stable.cask), beta: version(UTMChannel.beta.cask))
        return found.stable == nil ? nil : found
    }

    static func caskInfoCommand(brew: String) -> (tool: String, arguments: [String]) {
        (brew, ["info", "--json=v2", "--cask", UTMChannel.stable.cask, UTMChannel.beta.cask])
    }

    // MARK: - What to offer (pure)

    /// What a fresh install is offered, and how Winbar knows.
    struct Offer: Equatable, Codable, Sendable {
        /// The current stable build. nil when nothing could be checked: stable is still installed,
        /// from the `utm` cask or `/releases/latest`, as it always was.
        var stable: UTMBuild?
        /// The beta, only while it may be offered (`choice(from:)`).
        var beta: UTMBuild?
        /// Neither GitHub, a recent answer nor Homebrew could say: the one honest line is said
        /// (`UTMChannelCopy.couldNotCheck`) and stable is installed.
        var couldNotCheck = false

        var offersChoice: Bool { beta != nil }
    }

    /// How old a saved answer is, and what that allows. A date in the future (a clock moved back, a
    /// settings file from another Mac) is no answer at all.
    enum Age: Equatable { case fresh, usable, expired }

    static func age(of checked: Date, now: Date) -> Age {
        let elapsed = now.timeIntervalSince(checked)
        if elapsed < 0 { return .expired }
        if elapsed < freshFor { return .fresh }
        return elapsed < usableFor ? .usable : .expired
    }

    /// A check's answer and when it was had, as it is kept between runs.
    struct Saved: Equatable, Codable, Sendable {
        var choice: UTMChoice
        var checked: Date
    }

    /// The whole decision, with every source handed in, so each fallback can be held to a test:
    ///
    /// 1. An answer from the last day is used as it is; GitHub isn't asked.
    /// 2. Otherwise GitHub is asked (`fetch`), and a good answer is kept (`Result.save`).
    /// 3. If that fails, an answer up to a week old stands in.
    /// 4. With Homebrew (`casks` non-nil), its two casks say what it would install. They decide on
    ///    their own when nothing else could; and beside an answer from GitHub, they are what's named,
    ///    since Homebrew installs what its cask says, which can trail GitHub by hours.
    /// 5. Otherwise stable only, and `couldNotCheck`.
    ///
    /// `casks` is asked at most once, and only when Homebrew is there to be asked.
    static func resolve(now: Date, saved: Saved?, fetch: () -> UTMChoice?,
                        casks: (() -> CaskVersions?)?) -> (offer: Offer, save: Saved?) {
        var choice: UTMChoice?
        var save: Saved?
        if let saved, age(of: saved.checked, now: now) == .fresh {
            choice = saved.choice
        } else if let fetched = fetch() {
            choice = fetched
            save = Saved(choice: fetched, checked: now)
        } else if let saved, age(of: saved.checked, now: now) == .usable {
            choice = saved.choice
        }
        let homebrew = casks?()
        return (offer(choice: choice, casks: homebrew), save)
    }

    /// GitHub's choice and Homebrew's casks, together. Pure.
    static func offer(choice: UTMChoice?, casks: CaskVersions?) -> Offer {
        guard let casks, let caskStable = casks.stable else {
            guard let choice else { return Offer(stable: nil, beta: nil, couldNotCheck: true) }
            return Offer(stable: choice.stable, beta: choice.beta)
        }
        // Homebrew installs what its cask names; GitHub's size and digest belong to that build only
        // when the versions agree.
        func named(_ version: String, _ release: UTMBuild?) -> UTMBuild {
            if let release, release.version == version { return release }
            return UTMBuild(version: version)
        }
        let stable = named(caskStable, choice?.stable)
        guard let caskBeta = casks.beta, offersBeta(caskBeta, over: caskStable) else {
            return Offer(stable: stable, beta: nil)
        }
        // With GitHub's answer in hand, it decides whether there is a beta to offer at all; Homebrew
        // decides alone only when GitHub couldn't be asked.
        if let choice, choice.beta == nil { return Offer(stable: stable, beta: nil) }
        return Offer(stable: stable, beta: named(caskBeta, choice?.beta))
    }

    /// The build a fresh install gets for `channel`: the beta only while one is offered, and only by
    /// a route that can fetch it — Homebrew's `utm@beta`, or its own tagged release with a digest to
    /// check. Everything else is stable. Pure.
    static func pick(_ channel: UTMChannel, from offer: Offer?, homebrew: Bool) -> UTMPick {
        if channel == .beta, let beta = offer?.beta, homebrew || (beta.dmgURL != nil && beta.sha256 != nil) {
            return UTMPick(channel: .beta, build: beta)
        }
        return UTMPick(channel: .stable, build: offer?.stable)
    }

    // MARK: - Asking (live)

    /// The last answer this process worked out, and when: the window reads the Mac on every look,
    /// and a UTM that's missing would otherwise run Homebrew each time. Ten minutes, then asked again.
    private static var remembered: (offer: Offer, brew: String?, at: Date)?
    private static let lock = NSLock()

    /// What to offer now. Blocking: at most one request to GitHub (ten seconds) and one `brew info`.
    /// Only ever called while UTM is missing, which is when an install can happen.
    static func current(brew: String?, now: Date = Date()) -> Offer {
        lock.lock()
        defer { lock.unlock() }
        if let remembered, remembered.brew == brew, now.timeIntervalSince(remembered.at) < 600,
           now >= remembered.at {
            return remembered.offer
        }
        let result = resolve(now: now, saved: Config.utmReleases, fetch: { fetch().flatMap(choice(from:)) },
                             casks: brew.map { brew in { brewCaskVersions(brew: brew) } })
        if let save = result.save { Config.utmReleases = save }
        Debug.log("utm channels: stable=\(result.offer.stable?.version ?? "?") beta=\(result.offer.beta?.version ?? "none")"
                  + (result.offer.couldNotCheck ? " (couldn't check)" : ""))
        remembered = (result.offer, brew, now)
        return result.offer
    }

    /// GitHub's releases list, or nil for every kind of no-answer. The same rules as `UpdateCheck`:
    /// anonymous, no token, a User-Agent GitHub insists on, the documented Accept header, and
    /// silence on any failure. An ephemeral session, so nothing about it is kept on disk.
    static func fetch(timeout: TimeInterval = 10) -> [UTMRelease]? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 2
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: apiURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.setValue("Winbar/\(AppBundle.version)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let done = DispatchSemaphore(value: 0)
        var releases: [UTMRelease]?
        session.dataTask(with: request) { data, response, _ in
            if let data, (response as? HTTPURLResponse)?.statusCode == 200 { releases = UTMChannels.releases(fromJSON: data) }
            done.signal()
        }.resume()
        guard done.wait(timeout: .now() + timeout * 2 + 5) == .success else { return nil }
        return releases
    }

    /// What Homebrew's casks would install, from its own cached copy of its API: no GitHub call.
    static func brewCaskVersions(brew: String) -> CaskVersions? {
        let command = caskInfoCommand(brew: brew)
        let result = DependencyCommand.run(command.tool, command.arguments, timeout: 30)
        guard result.status == 0 else { return nil }
        return caskVersions(fromJSON: result.stdout)
    }
}

// MARK: - The words

/// What the choice says, at the terminal and in the window alike. Versions and sizes are filled in
/// from what was read; nothing names a particular beta.
enum UTMChannelCopy {
    static let heading = "Which UTM?"

    /// Both sources failed, so there's no choice to make: said once, plainly.
    static let couldNotCheck = "Couldn't check whether a UTM beta is available; installing the current stable UTM."

    /// The stable option's name and its sentences.
    static func stableTitle(_ build: UTMBuild?) -> String {
        "UTM\(build.map { " " + $0.version } ?? "") — stable (recommended)"
    }

    static func stableBody(_ build: UTMBuild?, tested: [String] = CreatePreflight.testedVersions) -> String {
        var text = "The release UTM's developers call finished"
        if let version = build?.version, tested.contains(version) {
            text += ", and the one Winbar is tested with."
        } else {
            text += ". Winbar is tested with \(CreatePreflight.testedList(tested))."
        }
        return text + size(build)
    }

    static func betaTitle(_ build: UTMBuild) -> String { "UTM \(build.version) — beta" }

    /// The beta's sentences. What UTM 5 changes for Winbar is said only of a UTM 5: a later beta of
    /// another major gets the plain half. Whether Winbar has been tested with it comes from
    /// `CreatePreflight.testedVersions`, the one list the spike's result changes.
    ///
    /// The #7882 sentence is decided by `UTMFixes`, the same gate that skips the UTM restart after a
    /// display change, so the copy can't promise what the build doesn't do: a beta at 5.0.6 or later
    /// gets `noRestartPromise`, and an older UTM 5 beta (5.0.0-5.0.5, which lack the fix and still get
    /// the restart) gets no sentence about the crash at all.
    static func betaBody(_ build: UTMBuild, tested: [String] = CreatePreflight.testedVersions) -> String {
        let major = UpdateCheck.parse(build.version)?.numbers[0]
        var text = "A preview of UTM's next version."
        if major == 5 {
            let fixed = !UTMFixes.displayChangeRestartsUTM(build.version)
            if fixed { text += " " + noRestartPromise }
            text += " It \(fixed ? "also " : "")adds snapshots and experimental 3D graphics, which Winbar doesn't use yet."
        }
        text += " It is still a beta: UTM's developers are fixing bugs in it"
        text += major == 5 ? " (for example, suspending a VM can fail on macOS 27)." : "."
        return text + " " + testedSentence(build.version, tested: tested) + size(build)
    }

    /// What a beta with the #7882 fix changes for Winbar. Its own constant so the test can ask whether
    /// it's said without pinning its words.
    static let noRestartPromise = "It fixes the crash Winbar works around when you turn Windows' display on or off, "
        + "so Winbar no longer has to restart UTM for that."

    /// "Winbar has not yet been tested with 5.0.x" until the spike passes and its version joins
    /// `testedVersions`; then "has been tested with 5.0.6"; and for a later beta of the same line,
    /// both halves.
    static func testedSentence(_ version: String, tested: [String]) -> String {
        if tested.contains(version) { return "Winbar has been tested with \(version)." }
        guard let parsed = CreatePreflight.parseVersion(version) else { return "Winbar has not yet been tested with it." }
        let line = tested.last { CreatePreflight.parseVersion($0).map { $0.major == parsed.major && $0.minor == parsed.minor } ?? false }
        if let line { return "Winbar has been tested with \(line), not yet with \(version)." }
        return "Winbar has not yet been tested with \(parsed.major).\(parsed.minor).x."
    }

    private static func size(_ build: UTMBuild?) -> String {
        build?.megabytes.map { " About \($0) MB." } ?? ""
    }

    /// The terminal's question, after the two options: Return is stable.
    static let prompt = "Which UTM? [1] stable (recommended) [2] beta: "

    /// `--utm-channel beta` with no beta to offer: nothing is installed, and why.
    static func betaUnavailable(_ offer: UTMChannels.Offer) -> String {
        if offer.couldNotCheck {
            return "--utm-channel beta: Winbar couldn't check whether a UTM beta is available, so nothing was "
                + "installed. Run winbar setup again when you're online, or without --utm-channel to install the "
                + "current stable UTM."
        }
        let stable = offer.stable.map { " (UTM \($0.version) is the current stable release)" } ?? ""
        return "--utm-channel beta: there's no UTM beta ahead of the stable release to offer right now\(stable), so "
            + "nothing was installed. Run winbar setup without --utm-channel to install the current stable UTM."
    }

    /// `--utm-channel` on a Mac that has UTM: the choice is for a fresh install only.
    static func notSwitching(version: String?) -> String {
        "--utm-channel only chooses which UTM a fresh install gets. UTM\(version.map { " " + $0 } ?? "") is already "
            + "installed, and Winbar doesn't switch it."
    }
}

// MARK: - At the terminal

/// How `winbar setup` settles the channel before it installs UTM. Pure.
enum UTMChannelDecision: Equatable {
    case install(UTMChannel)
    /// Two options on offer and nothing chose: ask.
    case ask
    /// `--utm-channel beta` with no beta on offer.
    case betaUnavailable

    /// `requested` is `--utm-channel`, which is explicit and wins. `--yes` otherwise always picks
    /// stable: it answers questions for the person, and "which UTM" is not one to answer with a beta.
    static func decide(requested: UTMChannel?, assumeYes: Bool, offered: Bool) -> UTMChannelDecision {
        switch requested {
        case .stable?: return .install(.stable)
        case .beta?: return offered ? .install(.beta) : .betaUnavailable
        case nil: return offered && !assumeYes ? .ask : .install(.stable)
        }
    }

    /// An answer to `UTMChannelCopy.prompt`: Return, 1 or "stable" is stable; 2 or "beta" is the beta;
    /// anything else asks again (nil). End of input is stable.
    static func answer(_ line: String?) -> UTMChannel? {
        guard let line else { return .stable }
        switch line.trimmingCharacters(in: .whitespaces).lowercased() {
        case "", "1", "stable": return .stable
        case "2", "beta": return .beta
        default: return nil
        }
    }
}
