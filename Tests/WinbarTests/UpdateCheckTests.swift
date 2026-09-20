import Foundation
import Testing
@testable import Winbar

// The update check's rules, with no network in sight: which of two versions is newer, when the next
// check is due, what GitHub's answer has to look like to count, and whether this copy of Winbar came
// from Homebrew. Nothing here reaches GitHub, the file system or the user's defaults.

@Suite("Comparing versions")
struct UpdateVersionTests {
    @Test("A later release is news; the same one and an older one are not")
    func ordering() {
        #expect(UpdateCheck.isNewer("0.2.0", than: "0.1.0"))
        #expect(UpdateCheck.isNewer("0.1.1", than: "0.1.0"))
        #expect(UpdateCheck.isNewer("1.0.0", than: "0.9.9"))
        #expect(!UpdateCheck.isNewer("0.1.0", than: "0.1.0"))
        #expect(!UpdateCheck.isNewer("0.1.0", than: "0.2.0"))
        #expect(!UpdateCheck.isNewer("0.9.9", than: "1.0.0"))
        // Ten is not "1 followed by 0", which is what comparing these as text would decide.
        #expect(UpdateCheck.isNewer("0.10.0", than: "0.9.0"))
        #expect(!UpdateCheck.isNewer("0.9.0", than: "0.10.0"))
    }

    @Test("A leading v, from a git tag, is the same version")
    func tagPrefix() {
        #expect(UpdateCheck.isNewer("v0.2.0", than: "0.1.0"))
        #expect(!UpdateCheck.isNewer("v0.1.0", than: "0.1.0"))
        #expect(UpdateCheck.parse("v1.2.3") == UpdateCheck.parse("1.2.3"))
    }

    @Test("A release beats its own pre-releases, and pre-releases order among themselves")
    func prereleases() {
        // The release is later than any pre-release of the same numbers…
        #expect(UpdateCheck.isNewer("1.0.0", than: "1.0.0-beta.1"))
        #expect(!UpdateCheck.isNewer("1.0.0-beta.1", than: "1.0.0"))
        // …and a pre-release of a later version is still later.
        #expect(UpdateCheck.isNewer("1.1.0-beta.1", than: "1.0.0"))
        // SemVer's own examples: numbers before words, more identifiers after fewer.
        #expect(UpdateCheck.isNewer("1.0.0-alpha.1", than: "1.0.0-alpha"))
        #expect(UpdateCheck.isNewer("1.0.0-alpha.beta", than: "1.0.0-alpha.1"))
        #expect(UpdateCheck.isNewer("1.0.0-beta.11", than: "1.0.0-beta.2"))
        #expect(UpdateCheck.isNewer("1.0.0-rc.1", than: "1.0.0-beta.11"))
        #expect(!UpdateCheck.isNewer("1.0.0-beta.1", than: "1.0.0-beta.1"))
    }

    @Test("Build metadata is parsed and then ignored, the way SemVer says")
    func buildMetadata() {
        #expect(!UpdateCheck.isNewer("1.0.0+build.9", than: "1.0.0"))
        #expect(UpdateCheck.isNewer("1.0.1+build.1", than: "1.0.0+build.9"))
    }

    @Test("Anything that isn't a version is silence, never an update")
    func junk() {
        for text in ["", "dev", "latest", "1.0", "1.2.3.4", "one.two.three", "v", "1.2.x",
                     "1.-2.3", "nightly-2026-09-20", "<!DOCTYPE html>", "0x1.0.0", "1.0.0-"] {
            #expect(UpdateCheck.parse(text) == nil, "\(text) should not parse")
            #expect(!UpdateCheck.isNewer(text, than: "0.1.0"), "\(text) should not be an update")
        }
        // And a real version is no news to a build that has no version of its own: `swift build`
        // leaves AppBundle.version as "dev".
        #expect(!UpdateCheck.isNewer("9.9.9", than: "dev"))
    }
}

@Suite("Reading GitHub's answer")
struct UpdateAnswerTests {
    func json(_ text: String) -> Data { Data(text.utf8) }

    @Test("The tag comes out of a release, with or without its v")
    func goodAnswers() {
        #expect(UpdateCheck.version(fromJSON: json(#"{"tag_name":"v0.2.0","name":"Winbar 0.2.0"}"#)) == "0.2.0")
        #expect(UpdateCheck.version(fromJSON: json(#"{"tag_name":"0.2.0"}"#)) == "0.2.0")
        #expect(UpdateCheck.version(fromJSON: json(#"{"tag_name":"v1.0.0-rc.1"}"#)) == "1.0.0-rc.1")
    }

    @Test("Everything else is nil: rate limits, error pages, empty and truncated bodies")
    func badAnswers() {
        // What GitHub sends once the hour's 60 anonymous requests are gone.
        #expect(UpdateCheck.version(fromJSON: json(#"{"message":"API rate limit exceeded"}"#)) == nil)
        #expect(UpdateCheck.version(fromJSON: json(#"{"message":"Not Found"}"#)) == nil)
        // A captive portal or a proxy answering with its own page.
        #expect(UpdateCheck.version(fromJSON: json("<html><body>Sign in to the Wi-Fi</body></html>")) == nil)
        #expect(UpdateCheck.version(fromJSON: json("")) == nil)
        #expect(UpdateCheck.version(fromJSON: json(#"{"tag_name":"v0.2.0""#)) == nil)   // cut off
        #expect(UpdateCheck.version(fromJSON: json(#"{"tag_name":""}"#)) == nil)
        #expect(UpdateCheck.version(fromJSON: json(#"{"tag_name":42}"#)) == nil)
        #expect(UpdateCheck.version(fromJSON: json(#"["v0.2.0"]"#)) == nil)
        #expect(UpdateCheck.version(fromJSON: json(#"{"tag_name":"nightly"}"#)) == nil)
    }

    @Test("A body far too big to be a release is not parsed at all")
    func absurdlyBigAnswer() {
        let huge = #"{"tag_name":"v9.9.9","body":""# + String(repeating: "x", count: 2 << 20) + #""}"#
        #expect(UpdateCheck.version(fromJSON: json(huge)) == nil)
    }
}

@Suite("When the next check is due")
struct UpdateThrottleTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Never checked means check now")
    func neverChecked() {
        #expect(UpdateCheck.isDue(lastChecked: nil, now: now))
    }

    @Test("One check a day, not one a launch")
    func oncePerDay() {
        #expect(!UpdateCheck.isDue(lastChecked: now, now: now))
        #expect(!UpdateCheck.isDue(lastChecked: now.addingTimeInterval(-60), now: now))
        #expect(!UpdateCheck.isDue(lastChecked: now.addingTimeInterval(-23 * 3600), now: now))
        // A minute short of a day is still too soon; a day exactly is due.
        #expect(!UpdateCheck.isDue(lastChecked: now.addingTimeInterval(-(24 * 3600 - 60)), now: now))
        #expect(UpdateCheck.isDue(lastChecked: now.addingTimeInterval(-24 * 3600), now: now))
        #expect(UpdateCheck.isDue(lastChecked: now.addingTimeInterval(-40 * 24 * 3600), now: now))
    }

    @Test("A check stamped in the future doesn't switch the check off until then")
    func clockWentBackwards() {
        // A settings file copied from another Mac, or a clock corrected after being wrong.
        #expect(UpdateCheck.isDue(lastChecked: now.addingTimeInterval(365 * 24 * 3600), now: now))
    }
}

@Suite("Which way Winbar was installed")
struct UpdateInstallMethodTests {
    @Test("The cask's copy: in /Applications, with a receipt in the Caskroom")
    func homebrew() {
        #expect(UpdateCheck.isHomebrewInstall(appPath: "/Applications/Winbar.app", caskroomExists: true))
    }

    @Test("No Homebrew, or no receipt, means the disk image")
    func noReceipt() {
        #expect(!UpdateCheck.isHomebrewInstall(appPath: "/Applications/Winbar.app", caskroomExists: false))
    }

    @Test("A copy somewhere else isn't the cask's, receipt or no receipt")
    func elsewhere() {
        // Someone else's Homebrew may know about winbar; this copy still isn't the one it put there.
        for path in ["/Users/j/Applications/Winbar.app", "/Volumes/Winbar 0.1.0/Winbar.app",
                     "/Users/j/src/winbar/dist/Winbar.app", "/Applications/Utilities/Winbar.app"] {
            #expect(!UpdateCheck.isHomebrewInstall(appPath: path, caskroomExists: true), "\(path)")
        }
        // `swift build` has no bundle around it at all.
        #expect(!UpdateCheck.isHomebrewInstall(appPath: nil, caskroomExists: true))
    }

    @Test("Homebrew is looked for where it actually lives, and each prefix only once")
    func caskroomPaths() {
        let standard = UpdateCheck.caskroomPaths(environment: [:])
        #expect(standard == ["/opt/homebrew/Caskroom/winbar", "/usr/local/Caskroom/winbar"])

        // Homebrew's own shellenv exports the prefix; a prefix nobody would guess is found that way.
        let custom = UpdateCheck.caskroomPaths(environment: ["HOMEBREW_PREFIX": "/Users/j/brew"])
        #expect(custom.first == "/Users/j/brew/Caskroom/winbar")
        #expect(custom.count == 3)

        // The environment naming a standard prefix doesn't make it appear twice.
        #expect(UpdateCheck.caskroomPaths(environment: ["HOMEBREW_PREFIX": "/opt/homebrew"]) == standard)
        // A relative value is not a prefix.
        #expect(UpdateCheck.caskroomPaths(environment: ["HOMEBREW_PREFIX": "brew"]) == standard)
    }

    @Test("The menu item names the version, and tells a Homebrew user to upgrade with Homebrew")
    func menuTitle() {
        let brew = UpdateCheck.menuTitle(version: "0.2.0", homebrew: true)
        #expect(brew.contains("0.2.0"))
        #expect(brew.contains("brew upgrade"))

        let download = UpdateCheck.menuTitle(version: "0.2.0", homebrew: false)
        #expect(download.contains("0.2.0"))
        #expect(!download.contains("brew"))
    }
}
