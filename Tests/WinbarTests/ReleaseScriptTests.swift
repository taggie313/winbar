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
