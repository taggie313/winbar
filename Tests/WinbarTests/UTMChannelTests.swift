import Foundation
import Testing
@testable import Winbar

// Which UTM a fresh install gets while UTM's next major version is a beta: the rule that reads UTM's
// GitHub releases, what stands in when GitHub can't be asked, which Homebrew cask does the work, and
// what the terminal and the window do with the choice. Every release, version, size and digest here
// is invented; nothing reaches GitHub, Homebrew, the file system or the user's defaults.

private enum Given {
    static let brew = "/opt/homebrew/bin/brew"
    static let digestA = String(repeating: "a1", count: 32)
    static let digestB = String(repeating: "b2", count: 32)

    static func release(_ tag: String, prerelease: Bool, draft: Bool = false, bytes: Int64? = 212_345_678,
                        sha256: String? = digestA) -> UTMRelease {
        UTMRelease(tag: tag, draft: draft, prerelease: prerelease,
                   dmg: bytes.map { UTMRelease.Asset(bytes: $0, sha256: sha256) })
    }

    /// The shape of the day this was written: a stable 4.x and, newest first, betas of 5.
    static let stable = release("v4.9.3", prerelease: false, bytes: 198_765_432, sha256: digestB)
    static let beta = release("v5.2.1", prerelease: true, bytes: 287_654_321)
    static let releases = [beta, release("v5.2.0", prerelease: true), stable, release("v4.9.2", prerelease: false)]

    static let choice = UTMChannels.choice(from: releases)!
    static let noon = Date(timeIntervalSince1970: 1_900_000_000)
    static func saved(_ choice: UTMChoice = choice, daysAgo: Double) -> UTMChannels.Saved {
        UTMChannels.Saved(choice: choice, checked: noon.addingTimeInterval(-daysAgo * 24 * 60 * 60))
    }
}

@Suite("The UTM channel rule")
struct UTMChannelRuleTests {
    /// A stable 4.x and a newer 5.x beta with a disk image and a digest: the choice is offered, with
    /// the newest beta, and each build fetched by its own tag.
    /// Control: dropping the major-version test from `offersBeta` still passes this, and fails the next.
    @Test("A beta a major version ahead of stable, with a digest, is offered")
    func offersTheBeta() {
        let choice = Given.choice
        #expect(choice.stable.version == "4.9.3")
        #expect(choice.beta?.version == "5.2.1")
        #expect(choice.beta?.sha256 == Given.digestA)
        #expect(choice.beta?.dmgURL == "https://github.com/utmapp/UTM/releases/download/v5.2.1/UTM.dmg")
        #expect(choice.stable.dmgURL == "https://github.com/utmapp/UTM/releases/download/v4.9.3/UTM.dmg")
        #expect(choice.beta?.megabytes == 288)
    }

    /// Once the next major ships stable, its betas are no longer a major ahead: the choice goes away
    /// with no change to Winbar. Control: without the major-version test this offers 5.1.0.
    @Test("A 5.1 beta beside a 5.0 stable is not offered")
    func sameMajorIsNotOffered() {
        let choice = UTMChannels.choice(from: [Given.release("v5.1.0", prerelease: true),
                                               Given.release("v5.0.0", prerelease: false)])
        #expect(choice?.stable.version == "5.0.0")
        #expect(choice?.beta == nil)
    }

    /// A draft is nobody's release yet, stable or beta. Control: without the draft filter, the draft
    /// 4.99.0 becomes stable and the draft 6.0.0 the beta.
    @Test("Drafts are ignored")
    func draftsAreIgnored() {
        let choice = UTMChannels.choice(from: [Given.release("v6.0.0", prerelease: true, draft: true),
                                               Given.release("v4.99.0", prerelease: false, draft: true)]
                                        + Given.releases)
        #expect(choice?.stable.version == "4.9.3")
        #expect(choice?.beta?.version == "5.2.1")
    }

    /// Without the digest there is nothing to check a download against, and without a UTM.dmg there
    /// is nothing to download. Control: without the digest test, the first is offered.
    @Test("A beta with no disk image, or no digest for it, is not offered")
    func betaNeedsADiskImageAndADigest() {
        let noDigest = UTMChannels.choice(from: [Given.release("v5.2.1", prerelease: true, sha256: nil), Given.stable])
        let noImage = UTMChannels.choice(from: [Given.release("v5.2.1", prerelease: true, bytes: nil), Given.stable])
        #expect(noDigest?.beta == nil)
        #expect(noImage?.beta == nil)
        #expect(noDigest?.stable.version == "4.9.3")
    }

    /// 5.0.4 and 5.0.5 are the betas the research ruled out. Control: without the floor, 5.0.5 is offered.
    @Test("No beta older than the floor is offered")
    func theFloor() {
        #expect(UTMChannels.choice(from: [Given.release("v5.0.5", prerelease: true), Given.stable])?.beta == nil)
        #expect(UTMChannels.choice(from: [Given.release("v5.0.6", prerelease: true), Given.stable])?.beta?.version
                == "5.0.6")
        #expect(!UTMChannels.offersBeta("5.0.5", over: "4.9.3"))
        #expect(UTMChannels.offersBeta("5.0.6", over: "4.9.3"))
    }

    @Test("A pre-release older than stable isn't the beta, and no stable at all is no answer")
    func edges() {
        #expect(UTMChannels.choice(from: [Given.release("v4.9.4-rc.1", prerelease: true),
                                          Given.release("v4.9.5", prerelease: false)])?.beta == nil)
        #expect(UTMChannels.choice(from: [Given.beta]) == nil)
        #expect(UTMChannels.choice(from: []) == nil)
        // A tag that could walk out of the release's path is not a version at all.
        #expect(UTMChannels.build(Given.release("v5.2.1+../../x", prerelease: true)) == nil)
    }

    @Test("GitHub's answer is read for tags, flags and the UTM.dmg asset's size and digest")
    func readsTheAnswer() throws {
        let json = """
        [{"tag_name":"v5.2.1","draft":false,"prerelease":true,"name":"v5.2.1 (Beta)",
          "assets":[{"name":"UTM-SE.ipa","size":1,"digest":"sha256:\(Given.digestB)"},
                    {"name":"UTM.dmg","size":287654321,"digest":"sha256:\(Given.digestA.uppercased())"}]},
         {"tag_name":"v4.9.3","draft":false,"prerelease":false,"assets":[{"name":"UTM.dmg","size":198765432}]}]
        """
        let releases = try #require(UTMChannels.releases(fromJSON: Data(json.utf8)))
        #expect(releases == [UTMRelease(tag: "v5.2.1", draft: false, prerelease: true,
                                        dmg: .init(bytes: 287_654_321, sha256: Given.digestA)),
                             UTMRelease(tag: "v4.9.3", draft: false, prerelease: false,
                                        dmg: .init(bytes: 198_765_432, sha256: nil))])
        #expect(UTMChannels.releases(fromJSON: Data(#"{"message":"API rate limit exceeded"}"#.utf8)) == nil)
        #expect(UTMChannels.releases(fromJSON: Data("<!DOCTYPE html>".utf8)) == nil)
        #expect(UTMChannels.sha256(fromDigest: "sha512:\(Given.digestA)") == nil)
    }

    @Test("Homebrew's two casks are read for what they would install")
    func readsHomebrew() {
        let json = #"{"formulae":[],"casks":[{"token":"utm","version":"4.9.3"},{"token":"utm@beta","version":"5.2.0,77"}]}"#
        #expect(UTMChannels.caskVersions(fromJSON: Data(json.utf8)) == .init(stable: "4.9.3", beta: "5.2.0"))
        #expect(UTMChannels.caskVersions(fromJSON: Data(#"{"casks":[]}"#.utf8)) == nil)
        #expect(UTMChannels.caskInfoCommand(brew: Given.brew).arguments == ["info", "--json=v2", "--cask", "utm", "utm@beta"])
    }
}

@Suite("When GitHub can't be asked")
struct UTMChannelFallbackTests {
    /// Control for every test here: `resolve` asking GitHub regardless of the saved answer's age
    /// fails the first; ignoring a week-old answer fails the third.
    @Test("An answer from the last day is used as it is, and GitHub isn't asked")
    func aFreshAnswerStands() {
        var asked = false
        let result = UTMChannels.resolve(now: Given.noon, saved: Given.saved(daysAgo: 0.5),
                                         fetch: { asked = true; return nil }, casks: nil)
        #expect(!asked)
        #expect(result.offer.beta?.version == "5.2.1")
        #expect(result.save == nil)
    }

    @Test("An older answer is asked again, and a good answer is kept")
    func anOldAnswerIsAskedAgain() {
        let newer = UTMChoice(stable: UTMBuild(version: "4.9.4"), beta: nil)
        let result = UTMChannels.resolve(now: Given.noon, saved: Given.saved(daysAgo: 2), fetch: { newer }, casks: nil)
        #expect(result.offer == UTMChannels.Offer(stable: UTMBuild(version: "4.9.4"), beta: nil))
        #expect(result.save == UTMChannels.Saved(choice: newer, checked: Given.noon))
    }

    @Test("If GitHub can't be asked, an answer up to a week old stands in")
    func aWeekOldAnswerStandsIn() {
        let result = UTMChannels.resolve(now: Given.noon, saved: Given.saved(daysAgo: 3), fetch: { nil }, casks: nil)
        #expect(result.offer.beta?.version == "5.2.1")
        #expect(!result.offer.couldNotCheck)
        #expect(result.save == nil)
    }

    /// Control: without the Homebrew fallback this is "couldn't check".
    @Test("With nothing recent, Homebrew's casks decide")
    func homebrewDecides() {
        let result = UTMChannels.resolve(now: Given.noon, saved: Given.saved(daysAgo: 8), fetch: { nil },
                                         casks: { .init(stable: "4.9.3", beta: "5.2.0") })
        #expect(result.offer.stable?.version == "4.9.3")
        #expect(result.offer.beta == UTMBuild(version: "5.2.0"))
        #expect(!result.offer.couldNotCheck)
        // Homebrew's beta has to clear the same bar.
        let old = UTMChannels.resolve(now: Given.noon, saved: nil, fetch: { nil },
                                      casks: { .init(stable: "4.9.3", beta: "5.0.5") })
        #expect(old.offer.beta == nil)
    }

    @Test("Both sources failing is stable only, and says so")
    func nothingCouldBeChecked() {
        let result = UTMChannels.resolve(now: Given.noon, saved: nil, fetch: { nil }, casks: nil)
        #expect(result.offer == UTMChannels.Offer(stable: nil, beta: nil, couldNotCheck: true))
        let brokenBrew = UTMChannels.resolve(now: Given.noon, saved: nil, fetch: { nil }, casks: { nil })
        #expect(brokenBrew.offer.couldNotCheck)
        #expect(UTMChannels.pick(.beta, from: result.offer, homebrew: true) == .stable)
    }

    @Test("An answer dated in the future is no answer")
    func aFutureDateIsExpired() {
        #expect(UTMChannels.age(of: Given.noon.addingTimeInterval(60), now: Given.noon) == .expired)
        var asked = false
        _ = UTMChannels.resolve(now: Given.noon, saved: Given.saved(daysAgo: -1), fetch: { asked = true; return nil },
                                casks: nil)
        #expect(asked)
    }

    /// Homebrew installs what its cask says, which can trail GitHub by hours: that version is named,
    /// without GitHub's size, which belongs to another build. Control: taking GitHub's beta as it is
    /// fails the first expectation.
    @Test("Beside GitHub's answer, Homebrew's versions are the ones named")
    func homebrewIsNamed() {
        let offer = UTMChannels.offer(choice: Given.choice, casks: .init(stable: "4.9.3", beta: "5.2.0"))
        #expect(offer.beta == UTMBuild(version: "5.2.0"))
        #expect(offer.stable == Given.choice.stable)   // same version, so GitHub's size and digest stay
        // GitHub decides whether there is a beta at all; a lagging cask can't add one.
        let none = UTMChannels.offer(choice: UTMChoice(stable: Given.choice.stable, beta: nil),
                                     casks: .init(stable: "4.9.3", beta: "5.2.0"))
        #expect(none.beta == nil)
        // And a cask still on a beta below the floor isn't offered, whatever GitHub has.
        #expect(UTMChannels.offer(choice: Given.choice, casks: .init(stable: "4.9.3", beta: "5.0.5")).beta == nil)
    }
}

@Suite("Which cask, and which download")
struct UTMChannelInstallTests {
    /// The two casks conflict, so a UTM from `utm@beta` has only that Caskroom entry. Control: a
    /// `casks` list without the beta's makes this Homebrew's UTM nobody's.
    @Test("A UTM installed by utm@beta is Homebrew's")
    func hasCaskKnowsTheBeta() {
        let beta = { (path: String) in path == Homebrew.caskMetadata("utm@beta", brew: Given.brew) }
        #expect(Homebrew.hasCask(.utm, brew: Given.brew, exists: beta))
        #expect(Homebrew.installedCask(.utm, brew: Given.brew, exists: beta) == "utm@beta")
        #expect(!Homebrew.hasCask(.utm, brew: Given.brew, exists: { _ in false }))
        #expect(!Homebrew.hasCask(.utm, brew: nil, exists: { _ in true }))
        #expect(Homebrew.installedCask(.windowsApp, brew: Given.brew, exists: beta) == nil)
    }

    /// `brew upgrade --cask utm` refuses a UTM `utm@beta` installed. Control: upgrading by
    /// `dependency.cask` fails this.
    @Test("An update goes through the cask that installed the copy")
    func upgradeUsesTheInstallingCask() {
        let old = DependencyState.tooOld(version: "4.6.4", minimum: "4.7")
        #expect(Dependencies.plan(for: .utm, state: old, brew: Given.brew, brewCask: "utm@beta")
                == .brewUpgrade(brew: Given.brew, cask: "utm@beta"))
        #expect(Dependencies.windowPlan(for: .utm, state: old, brew: Given.brew, brewCask: "utm@beta")
                == .brewUpgrade(brew: Given.brew, cask: "utm@beta"))
        // A cask that isn't one of UTM's is nobody's to update with.
        #expect(Dependencies.plan(for: .utm, state: old, brew: Given.brew, brewCask: "windows-app")
                == .manual(DependencyCopy.updateByHand(.utm)))
    }

    @Test("A fresh install gets the chosen channel: its cask, or its own tagged disk image and digest")
    func freshInstallFollowsThePick() {
        let offer = UTMChannels.Offer(stable: Given.choice.stable, beta: Given.choice.beta)
        let beta = UTMChannels.pick(.beta, from: offer, homebrew: false)
        #expect(Dependencies.plan(for: .utm, state: .missing, brew: Given.brew,
                                  utm: UTMChannels.pick(.beta, from: offer, homebrew: true))
                == .brew(brew: Given.brew, cask: "utm@beta"))
        #expect(Dependencies.plan(for: .utm, state: .missing, brew: nil, utm: beta)
                == .download(url: "https://github.com/utmapp/UTM/releases/download/v5.2.1/UTM.dmg",
                             sha256: Given.digestA))
        #expect(Dependencies.plan(for: .utm, state: .missing, brew: nil,
                                  utm: UTMChannels.pick(.stable, from: offer, homebrew: false))
                == .download(url: "https://github.com/utmapp/UTM/releases/download/v4.9.3/UTM.dmg",
                             sha256: Given.digestB))
        // Nothing read: stable from /releases/latest, with nothing to check a digest against.
        #expect(Dependencies.plan(for: .utm, state: .missing, brew: nil) == .download(url: Dependency.utmDownloadURL))
        // An installed UTM is never switched, whatever was picked.
        #expect(Dependencies.plan(for: .utm, state: .installed(version: "4.9.3"), brew: Given.brew, utm: beta) == nil)
    }

    /// A beta only Homebrew named has no tagged release to fetch, and a beta is never `/releases/latest`.
    /// Control: `pick` without the route test hands the download path a beta with no URL.
    @Test("A beta with no way to fetch it, or none on offer, is stable")
    func betaNeedsARoute() {
        let brewOnly = UTMChannels.Offer(stable: UTMBuild(version: "4.9.3"), beta: UTMBuild(version: "5.2.0"))
        #expect(UTMChannels.pick(.beta, from: brewOnly, homebrew: false).channel == .stable)
        #expect(UTMChannels.pick(.beta, from: brewOnly, homebrew: true).channel == .beta)
        #expect(UTMChannels.pick(.beta, from: UTMChannels.Offer(stable: UTMBuild(version: "4.9.3"), beta: nil),
                                 homebrew: true).channel == .stable)
        #expect(UTMPick(channel: .beta, build: UTMBuild(version: "5.2.0")).dmgURL == nil)
    }

    /// Control: `digestMatches` returning true for a file that couldn't be read fails this.
    @Test("A download is checked against GitHub's digest before anything opens it")
    func digestCheck() {
        #expect(DependencyInstaller.digestMatches(Given.digestA.uppercased(), expected: Given.digestA))
        #expect(!DependencyInstaller.digestMatches(Given.digestB, expected: Given.digestA))
        #expect(!DependencyInstaller.digestMatches(nil, expected: Given.digestA))
        #expect(!DependencyInstaller.digestMatches(Given.digestA, expected: "not a digest"))
    }
}

@Suite("Choosing a channel")
struct UTMChannelChoosingTests {
    /// `--yes` answers questions for the person and never with a beta; `--utm-channel` is explicit.
    /// Control: `decide` asking whenever a beta is offered fails the first expectation.
    @Test("--yes picks stable, --utm-channel chooses outright, and a missing beta stops the install")
    func terminalDecision() {
        #expect(UTMChannelDecision.decide(requested: nil, assumeYes: true, offered: true) == .install(.stable))
        #expect(UTMChannelDecision.decide(requested: nil, assumeYes: false, offered: true) == .ask)
        #expect(UTMChannelDecision.decide(requested: nil, assumeYes: false, offered: false) == .install(.stable))
        #expect(UTMChannelDecision.decide(requested: .beta, assumeYes: true, offered: true) == .install(.beta))
        #expect(UTMChannelDecision.decide(requested: .beta, assumeYes: false, offered: false) == .betaUnavailable)
        #expect(UTMChannelDecision.decide(requested: .stable, assumeYes: false, offered: true) == .install(.stable))
        #expect(UTMChannel(argument: "BETA") == .beta)
        #expect(UTMChannel(argument: "nightly") == nil)
    }

    @Test("Return is stable; 2 is the beta; anything else asks again")
    func promptAnswers() {
        #expect(UTMChannelDecision.answer("") == .stable)
        #expect(UTMChannelDecision.answer(nil) == .stable)
        #expect(UTMChannelDecision.answer(" 2 ") == .beta)
        #expect(UTMChannelDecision.answer("maybe") == nil)
    }

    /// Whether Winbar has been tested with the beta comes from the one list the spike changes.
    @Test("The beta says it's untested until its version joins testedVersions")
    func testedFollowsTheList() {
        let beta = UTMBuild(version: "5.2.1")
        let before = UTMChannelCopy.betaBody(beta, tested: ["4.9.3"])
        let after = UTMChannelCopy.betaBody(beta, tested: ["4.9.3", "5.2.1"])
        #expect(before != after)
        #expect(UTMChannelCopy.testedSentence("5.2.1", tested: ["4.9.3", "5.2.1"])
                != UTMChannelCopy.testedSentence("5.2.2", tested: ["4.9.3", "5.2.1"]))
        #expect(UTMChannelCopy.testedSentence("5.2.2", tested: ["4.9.3", "5.2.1"]).contains("5.2.1"))
    }

    /// The beta's no-restart promise follows the gate that skips the restart, not the major version:
    /// an early UTM 5 beta still gets the restart, so it mustn't be told it won't.
    /// Control: making the promise for every UTM 5 (dropping the `UTMFixes` check) fails the 5.0.5
    /// line; dropping the promise fails the 5.0.6 and later lines.
    @Test("The beta promises no UTM restart exactly when the gate skips it")
    func promiseFollowsTheGate() {
        for version in ["5.0.0", "5.0.5", "5.0.6", "5.1.0"] {
            let promised = UTMChannelCopy.betaBody(UTMBuild(version: version)).contains(UTMChannelCopy.noRestartPromise)
            #expect(promised == !UTMFixes.displayChangeRestartsUTM(version), "\(version)")
        }
        #expect(UTMChannelCopy.betaBody(UTMBuild(version: "5.0.6")).contains(UTMChannelCopy.noRestartPromise))
        #expect(!UTMChannelCopy.betaBody(UTMBuild(version: "5.0.5")).contains(UTMChannelCopy.noRestartPromise))
    }

    /// Step 1's card for a UTM that's missing: two options while a beta is offered, stable chosen
    /// until the person picks the beta, and the install button's plan following the choice.
    @Test("The window offers stable and the beta for a fresh install, stable preselected")
    func windowOffersTheChoice() {
        var facts = SetupFixtures.facts(utm: .missing, brew: Given.brew)
        facts.utmChannels = UTMChannels.Offer(stable: Given.choice.stable, beta: Given.choice.beta)
        let page = LookAroundPage.page(SetupFixtures.state(facts: facts))
        #expect(page.channels?.options.map(\.channel) == [.stable, .beta])
        #expect(page.channels?.selected == .stable)
        #expect(LookAroundPage.utmPick(facts).channel == .stable)

        facts.answers.utmChannel = .beta
        let chosen = LookAroundPage.page(SetupFixtures.state(facts: facts))
        #expect(chosen.channels?.selected == .beta)
        #expect(LookAroundPage.utmPick(facts) == UTMPick(channel: .beta, build: Given.choice.beta))

        // Nothing to choose: no picker. Nothing checked: the one line, and no options.
        facts.utmChannels = UTMChannels.Offer(stable: Given.choice.stable, beta: nil)
        #expect(LookAroundPage.page(SetupFixtures.state(facts: facts)).channels == nil)
        facts.utmChannels = UTMChannels.Offer(stable: nil, beta: nil, couldNotCheck: true)
        let unchecked = LookAroundPage.page(SetupFixtures.state(facts: facts)).channels
        #expect(unchecked?.options.isEmpty == true)
        #expect(unchecked?.note == UTMChannelCopy.couldNotCheck)
    }

    /// Control: showing the picker for any `needsUTM` state fails this.
    @Test("An installed UTM that's too old is updated, never switched: no choice")
    func noChoiceForAnUpdate() {
        var facts = SetupFixtures.facts(utm: .tooOld(version: "4.6.4", minimum: "4.7"), brew: Given.brew,
                                        fromHomebrew: true)
        facts.utmChannels = UTMChannels.Offer(stable: Given.choice.stable, beta: Given.choice.beta)
        facts.answers.utmChannel = .beta
        #expect(LookAroundPage.page(SetupFixtures.state(facts: facts)).channels == nil)
    }

    /// The choice is the person's, not the VM's: choosing another VM mustn't put stable back.
    @Test("The channel outlives a change of VM")
    func channelOutlivesAVMChange() {
        var answers = SetupFlow.Answers()
        answers.vmID = "vm-one"
        answers.utmChannel = .beta
        answers.leftAlone = ["H6"]
        let next = answers.forVM("vm-two")
        #expect(next.utmChannel == .beta)
        #expect(next.leftAlone.isEmpty)
    }
}
