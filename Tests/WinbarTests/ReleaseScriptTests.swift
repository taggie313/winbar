import Foundation
import Testing

/// `scripts/release.sh` is the one script whose failure mode is publishing things that must not be
/// published. This repository's GitHub history is a scrubbed single commit on `public`; `main` holds
/// 150+ commits naming the author's VM, its UUID and his saved-PC id. For 0.1.0 the script tagged
/// `HEAD` and printed `git push github main`, and only a local pre-push hook — which is not cloned,
/// and won't exist on anyone else's machine — stood between that and 158 private commits going out.
///
/// These read the script as text rather than running it: the dangerous paths are the ones that only
/// execute during a real release, which is exactly when you don't want to be finding out.
@Suite("The release script publishes only what may be published")
struct ReleaseScriptGuards {
    static let script: String = {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return (try? String(contentsOf: root.appendingPathComponent("scripts/release.sh"), encoding: .utf8)) ?? ""
    }()

    /// Not empty, so a wrong path can't make every other test in here vacuously pass.
    @Test func theScriptWasFound() {
        #expect(Self.script.hasPrefix("#!/usr/bin/env bash"))
    }

    @Test("The push sends the publishable ref, never the checked-out branch")
    func pushesThePublishableRef() {
        let s = Self.script
        #expect(s.contains("git push \"$REMOTE\" \"$PUSH_SPEC\""))
        #expect(!s.contains("git push \"$REMOTE\" \"$BRANCH\""))
        // And the copy-pasteable instructions must say the same thing as the automated path,
        // because on a failure the operator follows the printed line by hand.
        #expect(s.contains("\"git push $REMOTE $PUSH_SPEC refs/tags/$TAG\""))
        #expect(!s.contains("\"git push $REMOTE $BRANCH refs/tags/$TAG\""))
    }

    @Test("The tag is made at the published commit, not at HEAD")
    func tagsThePublishedCommit() {
        #expect(Self.script.contains("git tag -a \"$TAG\" \"$TAG_AT\""))
        #expect(!Self.script.contains("git tag -a \"$TAG\" -m"))
    }

    @Test("A 'public' branch redirects both the push and the tag")
    func publicBranchRedirectsBoth() {
        let s = Self.script
        #expect(s.contains("PUSH_SPEC=\"public:$BRANCH\""))
        #expect(s.contains("TAG_AT=\"public\""))
    }

    /// The build is made from the working tree. If `public` holds some earlier tree, the tag and the
    /// push would publish source that isn't what was built, signed and notarized.
    @Test("Releasing stops when 'public' isn't the tree being built")
    func refusesAStalePublicBranch() {
        let s = Self.script
        #expect(s.contains("git rev-parse public^{tree}"))
        #expect(s.contains("git rev-parse HEAD^{tree}"))
    }
}

/// The disk image's window: Winbar beside Applications, so the drag it exists for is obvious to
/// somebody who has never installed a Mac app from one. Finder is the only thing that writes that
/// layout, and it may not answer (no Automation consent, no GUI session), so the layout must never be
/// able to stop a release. Read as text, like the guards above: running it means running Finder.
@Suite("The disk image opens with Winbar beside Applications, when Finder will lay it out")
struct ReleaseDiskImageLayout {
    static let script = ReleaseScriptGuards.script

    /// build_dmg's body, so the checks below are about it and not some other part of the script.
    static let buildDMG: String = {
        guard let start = script.range(of: "build_dmg() {"),
              let end = script.range(of: "\n}\n", range: start.upperBound..<script.endIndex) else { return "" }
        return String(script[start.lowerBound..<end.upperBound])
    }()

    @Test("Built read/write, laid out, then compressed read-only")
    func readWriteThenCompressed() throws {
        let body = Self.buildDMG
        let create = try #require(body.range(of: "-format UDRW"))
        let layout = try #require(body.range(of: "layout_dmg_window \"$mnt\""))
        let convert = try #require(body.range(of: "hdi convert \"$rw\" -format UDZO"))
        #expect(create.lowerBound < layout.lowerBound && layout.lowerBound < convert.lowerBound)
        #expect(body.contains("unmount_dmg \"$mnt\""))
    }

    @Test("A Finder that won't answer costs a warning, never the release")
    func bestEffort() {
        let body = Self.buildDMG
        #expect(body.contains("if layout_dmg_window \"$mnt\"; then"))
        #expect(body.contains("warn \"Finder didn't lay out the disk image window"))
        #expect(Self.script.contains("with timeout of 60 seconds"))
        #expect(!Self.script.contains("sudo "))
    }

    @Test("Winbar on the left, Applications on the right, on one row")
    func sideBySide() throws {
        func position(_ item: String) throws -> (Int, Int) {
            let line = try #require(Self.script.split(separator: "\n").first { $0.contains("position of item \"\(item)\"") })
            let numbers = line.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            return (numbers[numbers.count - 2], numbers[numbers.count - 1])
        }
        let app = try position("Winbar.app")
        let applications = try position("Applications")
        #expect(app.0 < applications.0)
        #expect(app.1 == applications.1)
    }
}
