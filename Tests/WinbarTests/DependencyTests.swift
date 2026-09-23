import Foundation
import Testing
@testable import Winbar

// Pure logic only: no installing, no network, no Homebrew, no shell. Every command is built and
// held against what it should be, never run.

@Suite struct FindingHomebrew {
    /// Apple silicon's prefix, the Intel one, a Homebrew somewhere else, and none at all.
    @Test func acrossTheLayouts() {
        let apple = Homebrew.locate(isExecutable: { $0 == "/opt/homebrew/bin/brew" }, prefixOnPATH: { nil })
        #expect(apple == "/opt/homebrew/bin/brew")

        let intel = Homebrew.locate(isExecutable: { $0 == "/usr/local/bin/brew" }, prefixOnPATH: { nil })
        #expect(intel == "/usr/local/bin/brew")

        // Neither standard path, but brew is on PATH and says where it lives.
        let custom = Homebrew.locate(isExecutable: { $0 == "/Users/x/homebrew/bin/brew" },
                                     prefixOnPATH: { "/Users/x/homebrew\n" })
        #expect(custom == "/Users/x/homebrew/bin/brew")

        #expect(Homebrew.locate(isExecutable: { _ in false }, prefixOnPATH: { nil }) == nil)
    }

    /// The standard prefixes come first: a shell PATH can point at either, and asking costs a process.
    @Test func prefersTheStandardPrefix() {
        let both = Homebrew.locate(isExecutable: { ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].contains($0) },
                                   prefixOnPATH: { "/Users/x/homebrew" })
        #expect(both == "/opt/homebrew/bin/brew")
    }

    /// `brew --prefix` that answers with something unusable, or with nothing.
    @Test func anUnusablePrefix() {
        #expect(Homebrew.locate(isExecutable: { _ in false }, prefixOnPATH: { "/opt/nothing" }) == nil)
        #expect(Homebrew.locate(isExecutable: { _ in false }, prefixOnPATH: { "   \n" }) == nil)
        #expect(Homebrew.locate(isExecutable: { _ in false }, prefixOnPATH: { "" }) == nil)
    }
}

@Suite struct DependencyDecisions {
    /// `team` and `bundleID` are double optionals so a test can say "none at all" as well as
    /// "somebody else's".
    func app(_ dependency: Dependency, version: String? = "4.7.5", bundleID: String?? = nil,
             team: String?? = nil, valid: Bool = true) -> InstalledApp {
        InstalledApp(path: "/Applications/\(dependency.name).app",
                     bundleID: bundleID ?? dependency.bundleID,
                     version: version,
                     teamID: team ?? dependency.teamID,
                     signatureValid: valid)
    }

    @Test func presentAndGood() {
        #expect(Dependencies.state(of: .utm, app: app(.utm)) == .installed(version: "4.7.5"))
        #expect(Dependencies.state(of: .windowsApp, app: app(.windowsApp, version: "11.4.1"))
                == .installed(version: "11.4.1"))
    }

    @Test func missing() {
        #expect(Dependencies.state(of: .utm, app: nil) == .missing)
        #expect(Dependencies.state(of: .windowsApp, app: nil) == .missing)
    }

    @Test func tooOld() {
        #expect(Dependencies.state(of: .utm, app: app(.utm, version: "4.6.4"))
                == .tooOld(version: "4.6.4", minimum: "4.7"))
        // Windows App has no floor, so no version of it is too old.
        #expect(Dependencies.state(of: .windowsApp, app: app(.windowsApp, version: "10.0.0"))
                == .installed(version: "10.0.0"))
    }

    @Test func wrongSignature() {
        // Another developer's copy, a broken signature, an unsigned one, and something else entirely
        // under the app's name: all four are "not the app Winbar expected", and none is replaced.
        for state in [Dependencies.state(of: .utm, app: app(.utm, team: .some("ABCDE12345"))),
                      Dependencies.state(of: .utm, app: app(.utm, valid: false)),
                      Dependencies.state(of: .utm, app: app(.utm, team: .some(nil))),
                      Dependencies.state(of: .utm, app: app(.utm, bundleID: .some(nil))),
                      Dependencies.state(of: .utm, app: app(.utm, bundleID: .some("com.example.utm")))] {
            guard case .wrongSignature = state else {
                Issue.record("\(state) should be wrongSignature")
                continue
            }
        }
    }

    /// An app that won't say what version it is stays usable: it is there, and `CreatePreflight`
    /// already treats an unreadable UTM version that way.
    @Test func versionsItCannotRead() {
        #expect(Dependencies.state(of: .utm, app: app(.utm, version: nil)) == .installed(version: nil))
        #expect(Dependencies.state(of: .utm, app: app(.utm, version: "beta")) == .installed(version: "beta"))
    }

    @Test func versionComparison() {
        let minimum = (major: 4, minor: 7)
        #expect(Dependencies.meets("4.7", minimum: minimum))
        #expect(Dependencies.meets("4.7.5", minimum: minimum))
        #expect(Dependencies.meets("4.10.0", minimum: minimum))   // not string order
        #expect(Dependencies.meets("5.0.5", minimum: minimum))
        #expect(!Dependencies.meets("4.6.4", minimum: minimum))
        #expect(!Dependencies.meets("3.9", minimum: minimum))
        #expect(Dependencies.meets("nonsense", minimum: minimum))  // unreadable: carry on
        // The floor is create's own, in one place.
        #expect(Dependency.utm.minimumVersionText == "4.7")
        #expect(Dependency.windowsApp.minimumVersion == nil)
    }
}

@Suite struct DependencyPlans {
    let brew = "/opt/homebrew/bin/brew"

    @Test func homebrewInstallsWhenItIsThere() {
        #expect(Dependencies.plan(for: .utm, state: .missing, brew: brew) == .brew(brew: brew, cask: "utm"))
        #expect(Dependencies.plan(for: .windowsApp, state: .missing, brew: brew)
                == .brew(brew: brew, cask: "windows-app"))
    }

    /// Without Homebrew: UTM's own signed download, and — for Windows App — the App Store, because
    /// Microsoft ships it there and nobody can press Get for someone else.
    @Test func withoutHomebrew() {
        #expect(Dependencies.plan(for: .utm, state: .missing, brew: nil) == .download(url: Dependency.utmDownloadURL))
        #expect(Dependencies.plan(for: .windowsApp, state: .missing, brew: nil)
                == .appStore(id: Dependency.windowsAppStoreID))
    }

    @Test func tooOldIsAnUpdate() {
        let old = DependencyState.tooOld(version: "4.6.4", minimum: "4.7")
        #expect(Dependencies.plan(for: .utm, state: old, brew: brew, brewHasCask: true)
                == .brewUpgrade(brew: brew, cask: "utm"))
        // No Homebrew: Winbar doesn't replace a copy someone installed another way.
        guard case .manual(let advice)? = Dependencies.plan(for: .utm, state: old, brew: nil) else {
            Issue.record("a too-old UTM without Homebrew should be manual")
            return
        }
        #expect(advice.contains("brew upgrade --cask utm"))
    }

    /// Homebrew updates only what it installed: `brew upgrade --cask utm` on a UTM from its own
    /// download stops with "Cask 'utm' is not installed" (cask/upgrade.rb), and the window would then
    /// tell the person to run the same failing command. So with Homebrew there but not the owner of
    /// this copy — or not known to be — it's advice, as without Homebrew.
    @Test func homebrewUpdatesOnlyWhatItInstalled() {
        let old = DependencyState.tooOld(version: "4.6.4", minimum: "4.7")
        for plan in [Dependencies.plan(for: .utm, state: old, brew: brew, brewHasCask: false),
                     Dependencies.plan(for: .utm, state: old, brew: brew),
                     Dependencies.windowPlan(for: .utm, state: old, brew: brew)] {
            #expect(plan == .manual(DependencyCopy.updateByHand(.utm)))
        }
        #expect(Dependencies.windowPlan(for: .utm, state: old, brew: brew, brewHasCask: true)
                == .brewUpgrade(brew: brew, cask: "utm"))
        // Installing is still Homebrew's whether or not it has anything installed yet.
        #expect(Dependencies.plan(for: .utm, state: .missing, brew: brew, brewHasCask: false) == .brew(brew: brew, cask: "utm"))
    }

    /// Where Homebrew records a cask it installed, beside its own bin, for both standard prefixes.
    @Test func whereHomebrewKeepsItsCasks() {
        #expect(Homebrew.caskMetadata("utm", brew: "/opt/homebrew/bin/brew") == "/opt/homebrew/Caskroom/utm/.metadata")
        #expect(Homebrew.caskMetadata("utm", brew: "/usr/local/bin/brew") == "/usr/local/Caskroom/utm/.metadata")
        #expect(!Homebrew.hasCask("utm", brew: nil))
        #expect(!Homebrew.hasCask("utm", brew: "/nonexistent/winbar-tests/bin/brew"))
    }

    /// The update's plan says whose copy it replaces and what quitting UTM does to a running VM.
    @Test func anUpdateSaysWhatItStops() {
        let text = DependencyCopy.plan(.utm, .brewUpgrade(brew: brew, cask: "utm")).joined(separator: " ")
        #expect(text.hasPrefix("Homebrew (\(brew)) installed this UTM, so Winbar can ask it to update it"))
        #expect(text.contains("brew upgrade --cask utm"))
        #expect(text.contains("If UTM is open, Homebrew quits it first — any VM running in it stops — and opens it again"))
        #expect(text.contains("never uses sudo"))
    }

    /// Homebrew's path goes beside Homebrew in both of its plans. Put after "this UTM", it read as
    /// where UTM is — and UTM is in /Applications, not in Homebrew's bin.
    @Test func homebrewsPathIsBesideHomebrew() {
        for plan in [InstallPlan.brew(brew: brew, cask: "utm"), .brewUpgrade(brew: brew, cask: "utm")] {
            let first = DependencyCopy.plan(.utm, plan)[0]
            #expect(!first.contains("UTM (\(brew))"), "\(plan)")
            let homebrew = first.range(of: "Homebrew")!.upperBound
            let path = first.range(of: "(\(brew))")!.lowerBound
            #expect(!first[homebrew..<path].contains("UTM"), "\(plan)")
        }
        // The control: the update's plan as it was put the path straight after "this UTM".
        #expect("Homebrew installed this UTM (\(brew)), so Winbar can ask it to update it".contains("UTM (\(brew))"))
    }

    @Test func nothingToDoWhenItIsInstalled() {
        #expect(Dependencies.plan(for: .utm, state: .installed(version: "4.7.5"), brew: brew) == nil)
        #expect(Dependencies.plan(for: .utm, state: .installed(version: "4.7.5"), brew: nil) == nil)
    }

    /// An app that is there but isn't the expected one is never replaced, with or without Homebrew.
    @Test func wrongSignatureIsNeverInstalledOver() {
        let wrong = DependencyState.wrongSignature("signed by team ABCDE12345")
        for brew in [brew, nil] {
            guard case .manual(let advice)? = Dependencies.plan(for: .utm, state: wrong, brew: brew) else {
                Issue.record("a wrong signature should be manual, brew=\(brew ?? "none")")
                continue
            }
            #expect(advice.contains("won't replace"))
        }
    }
}

@Suite struct NothingPrivilegedAndNothingUnasked {
    /// The commands a plan runs, held against what they should be. Built, never run.
    @Test func theCommandsAreWhatTheyLookLike() {
        let install = InstallPlan.brew(brew: "/opt/homebrew/bin/brew", cask: "utm").command
        #expect(install?.tool == "/opt/homebrew/bin/brew")
        #expect(install?.arguments == ["install", "--cask", "utm"])

        let upgrade = InstallPlan.brewUpgrade(brew: "/usr/local/bin/brew", cask: "windows-app").command
        #expect(upgrade?.tool == "/usr/local/bin/brew")
        #expect(upgrade?.arguments == ["upgrade", "--cask", "windows-app"])

        // These two run no command of their own: one downloads, one opens a page.
        #expect(InstallPlan.download(url: Dependency.utmDownloadURL).command == nil)
        #expect(InstallPlan.appStore(id: Dependency.windowsAppStoreID).command == nil)
    }

    /// No path may ask for an administrator password: not the plans, not the checks.
    @Test func noPathRunsSudo() {
        var commands: [(tool: String, arguments: [String])] = [
            Homebrew.installCommand(brew: "/opt/homebrew/bin/brew", cask: "utm"),
            Homebrew.installCommand(brew: "/opt/homebrew/bin/brew", cask: "windows-app"),
            Homebrew.upgradeCommand(brew: "/opt/homebrew/bin/brew", cask: "utm"),
            AppSignature.readCommand("/Applications/UTM.app"),
            AppSignature.verifyCommand("/Applications/UTM.app"),
            Gatekeeper.assessCommand("/tmp/UTM.dmg"),
        ]
        commands += [InstallPlan.brew(brew: "/opt/homebrew/bin/brew", cask: "utm").command].compactMap { $0 }
        for command in commands {
            #expect(!DependencyCommand.isPrivileged(tool: command.tool, arguments: command.arguments),
                    "\(command.tool) \(command.arguments.joined(separator: " ")) should not be privileged")
            #expect(!command.arguments.contains("sudo"))
        }
    }

    /// And the guard that says so, on the things it has to catch.
    @Test func theGuardCatchesTheObviousOnes() {
        #expect(DependencyCommand.isPrivileged(tool: "/usr/bin/sudo", arguments: ["brew", "install"]))
        #expect(DependencyCommand.isPrivileged(tool: "/bin/sh", arguments: ["-c", "sudo installer -pkg x"]))
        #expect(DependencyCommand.isPrivileged(tool: "/usr/sbin/installer", arguments: ["-pkg", "x", "-target", "/"]))
        #expect(DependencyCommand.isPrivileged(tool: "/usr/bin/osascript",
                                               arguments: ["-e", "do shell script \"x\" with administrator privileges"]))
        #expect(!DependencyCommand.isPrivileged(tool: "/usr/bin/hdiutil", arguments: ["attach", "-readonly", "x.dmg"]))
        #expect(!DependencyCommand.isPrivileged(tool: "/usr/bin/env", arguments: ["brew", "--prefix"]))
    }

    /// Nothing is installed without the yes that was just asked for. The refusal is the whole test:
    /// `install` returns before it runs anything.
    @Test func nothingHappensWithoutAYes() {
        for plan: InstallPlan in [.brew(brew: "/opt/homebrew/bin/brew", cask: "utm"),
                                  .brewUpgrade(brew: "/opt/homebrew/bin/brew", cask: "utm"),
                                  .download(url: Dependency.utmDownloadURL),
                                  .appStore(id: Dependency.windowsAppStoreID)] {
            let result = DependencyInstaller.install(.utm, plan: plan, agreed: false)
            guard case .success(.refused(let why)) = result else {
                Issue.record("\(plan) ran without a yes")
                continue
            }
            #expect(why.contains("Nothing was installed"))
        }
    }

    /// `--yes` answers for Homebrew and for nothing else: a quarter of a gigabyte off the internet,
    /// and a button in the App Store, are not things a flag may agree to.
    @Test func whatYesMayAnswerFor() {
        #expect(DependencyInstaller.mayProceedUnattended(.brew(brew: "/opt/homebrew/bin/brew", cask: "utm")))
        #expect(DependencyInstaller.mayProceedUnattended(.brewUpgrade(brew: "/opt/homebrew/bin/brew", cask: "utm")))
        #expect(!DependencyInstaller.mayProceedUnattended(.download(url: Dependency.utmDownloadURL)))
        #expect(!DependencyInstaller.mayProceedUnattended(.appStore(id: Dependency.windowsAppStoreID)))
        #expect(!DependencyInstaller.mayProceedUnattended(.manual("do it yourself")))
    }
}

@Suite struct ReadingSignatures {
    /// codesign's own output for a Developer ID app (UTM) and an App Store one (Windows App). The
    /// App Store copy is why the team is read from the signature and not from the certificate: its
    /// leaf is Apple's and carries no team at all.
    @Test func codesignOutput() {
        let utm = """
            Executable=/Applications/UTM.app/Contents/MacOS/UTM
            Identifier=com.utmapp.UTM
            Format=app bundle with Mach-O universal (arm64)
            Signature size=9074
            Authority=Developer ID Application: Turing Software, LLC (WDNLXAD4W8)
            Authority=Developer ID Certification Authority
            Authority=Apple Root CA
            TeamIdentifier=WDNLXAD4W8
            """
        #expect(AppSignature.parse(utm).identifier == "com.utmapp.UTM")
        #expect(AppSignature.parse(utm).teamID == "WDNLXAD4W8")

        let windowsApp = """
            Executable=/Applications/Windows App.app/Contents/MacOS/Windows App
            Identifier=com.microsoft.rdc.macos
            Authority=Apple Mac OS Application Signing
            Authority=Apple Worldwide Developer Relations Certification Authority
            Authority=Apple Root CA
            TeamIdentifier=UBF8T346G9
            """
        #expect(AppSignature.parse(windowsApp).identifier == "com.microsoft.rdc.macos")
        #expect(AppSignature.parse(windowsApp).teamID == "UBF8T346G9")

        // An ad-hoc signature says so rather than naming a team.
        let adhoc = """
            Identifier=com.utmapp.UTM
            Signature=adhoc
            TeamIdentifier=not set
            """
        #expect(AppSignature.parse(adhoc).teamID == nil)
        #expect(AppSignature.parse("").identifier == nil)
    }

    /// The requirement every copy has to satisfy, in the command as it is built.
    @Test func theVerifyCommand() {
        let command = AppSignature.verifyCommand("/Applications/UTM.app")
        #expect(command.tool == "/usr/bin/codesign")
        #expect(command.arguments == ["--verify", "--strict", "-R", "=anchor apple generic", "/Applications/UTM.app"])
    }
}

@Suite struct AssessingADownload {
    /// spctl lives in /usr/sbin (macOS 27 has no /usr/bin/spctl), and the assessment is of the disk
    /// image's own signature — asked before anything mounts it.
    @Test func theAssessCommand() {
        let command = Gatekeeper.assessCommand("/tmp/UTM.dmg")
        #expect(command.tool == "/usr/sbin/spctl")
        #expect(command.arguments == ["--assess", "--type", "open", "--context", "context:primary-signature",
                                      "-vv", "/tmp/UTM.dmg"])
    }

    @Test func notarizedAndSignedByTheRightTeam() {
        let output = """
            /tmp/UTM.dmg: accepted
            source=Notarized Developer ID
            origin=Developer ID Application: Turing Software, LLC (WDNLXAD4W8)
            """
        let assessment = Gatekeeper.parse(output, status: 0)
        #expect(assessment.accepted)
        #expect(assessment.source == "Notarized Developer ID")
        #expect(assessment.teamID == "WDNLXAD4W8")
        #expect(Gatekeeper.trusted(assessment, team: Dependency.utm.teamID))
    }

    /// Everything that means "don't open it": no usable signature, and a notarized file that
    /// somebody else signed.
    @Test func refusals() {
        let unsigned = Gatekeeper.parse("/tmp/UTM.dmg: rejected\nsource=no usable signature\n", status: 0)
        #expect(!unsigned.accepted)
        #expect(!Gatekeeper.trusted(unsigned, team: Dependency.utm.teamID))

        let someoneElse = Gatekeeper.parse("""
            /tmp/UTM.dmg: accepted
            source=Notarized Developer ID
            origin=Developer ID Application: Someone Else (ABCDE12345)
            """, status: 0)
        #expect(someoneElse.accepted)
        #expect(someoneElse.teamID == "ABCDE12345")
        #expect(!Gatekeeper.trusted(someoneElse, team: Dependency.utm.teamID))

        // Accepted only when spctl says so *and* exits 0.
        let liar = Gatekeeper.parse("/tmp/UTM.dmg: accepted\norigin=Developer ID Application: X (WDNLXAD4W8)", status: 3)
        #expect(!liar.accepted)
        #expect(!Gatekeeper.trusted(liar, team: "WDNLXAD4W8"))
    }

    @Test func theTeamOutOfTheOrigin() {
        #expect(Gatekeeper.team(in: "Developer ID Application: Turing Software, LLC (WDNLXAD4W8)") == "WDNLXAD4W8")
        #expect(Gatekeeper.team(in: "Software Signing") == nil)
        #expect(Gatekeeper.team(in: nil) == nil)
        #expect(Gatekeeper.team(in: "Developer ID Application: A, B ()") == nil)
    }
}

@Suite struct DependencyWords {
    /// The copy says what will happen, who does it, and roughly how much is downloaded — before the
    /// question is asked.
    @Test func homebrewIsNamedAsTheOneInstalling() {
        let lines = DependencyCopy.plan(.utm, .brew(brew: "/opt/homebrew/bin/brew", cask: "utm")).joined(separator: " ")
        #expect(lines.contains("brew install --cask utm"))
        #expect(lines.contains("\(Dependency.utmDownloadMB) MB"))
        #expect(lines.contains("never uses sudo"))
        #expect(DependencyCopy.question(.utm, .brew(brew: "/opt/homebrew/bin/brew", cask: "utm"))
                == "Ask Homebrew to install UTM now?")
    }

    /// Windows App through Homebrew runs Microsoft's installer package, and macOS asks for the Mac
    /// password. Saying so is the point: the prompt is Homebrew's, not Winbar's.
    @Test func thePasswordPromptIsExplained() {
        let lines = DependencyCopy.plan(.windowsApp, .brew(brew: "/opt/homebrew/bin/brew", cask: "windows-app"))
            .joined(separator: " ")
        #expect(lines.contains("installer package"))
        #expect(lines.contains("Mac password"))
        #expect(lines.contains("never asks for your password"))
    }

    /// The download says where from, how big, and what is checked before it is opened.
    @Test func theDownloadIsDescribed() {
        let lines = DependencyCopy.plan(.utm, .download(url: Dependency.utmDownloadURL)).joined(separator: " ")
        #expect(lines.contains("won't install a package manager"))
        #expect(lines.contains("github.com/utmapp/UTM"))
        #expect(lines.contains("notarized"))
        #expect(lines.contains(Dependency.utm.teamID))
    }

    /// The App Store is described as what it is, not as something Winbar can do for you.
    @Test func theAppStoreIsNotPretendedAway() {
        let lines = DependencyCopy.plan(.windowsApp, .appStore(id: Dependency.windowsAppStoreID)).joined(separator: " ")
        #expect(lines.contains("nobody can install an App Store app for you"))
        #expect(DependencyCopy.question(.windowsApp, .appStore(id: Dependency.windowsAppStoreID))
                == "Open Windows App in the App Store?")
        #expect(DependencyCopy.unattended(.windowsApp, .appStore(id: Dependency.windowsAppStoreID))
                .contains("--yes can't press Get"))
    }

    /// Whatever is refused, the command to do it by hand is still there.
    @Test func theManualWayIsAlwaysOffered() {
        #expect(DependencyCopy.byHand(.utm).contains("brew install --cask utm"))
        #expect(DependencyCopy.byHand(.utm).contains("getutm.app"))
        #expect(DependencyCopy.byHand(.windowsApp).contains("brew install --cask windows-app"))
        #expect(DependencyCopy.byHand(.windowsApp).contains("Mac App Store"))
        #expect(DependencyCopy.nothingWithoutYes(.utm).contains("brew install --cask utm"))
    }

    /// A failed check is a full stop, and it says which half failed.
    @Test func aFailedCheckSaysWhy() {
        let unsigned = Gatekeeper.Assessment(accepted: false, source: "no usable signature", origin: nil, teamID: nil)
        #expect(DependencyCopy.assessmentFailed(.utm, unsigned).contains("no usable signature"))
        #expect(DependencyCopy.assessmentFailed(.utm, unsigned).contains("nothing was installed"))

        let wrongTeam = Gatekeeper.Assessment(accepted: true, source: "Notarized Developer ID",
                                              origin: "Developer ID Application: Someone Else (ABCDE12345)",
                                              teamID: "ABCDE12345")
        #expect(DependencyCopy.assessmentFailed(.utm, wrongTeam).contains("Someone Else"))
        #expect(DependencyCopy.assessmentFailed(.utm, wrongTeam).contains(Dependency.utm.vendor))
    }

    /// The rows doctor prints for each state.
    @Test func theDoctorRows() {
        #expect(Recipe.dependencyDetail(.utm, state: .installed(version: "4.7.5")) == "UTM 4.7.5")
        #expect(Recipe.dependencyDetail(.utm, state: .missing) == "not installed")
        #expect(Recipe.dependencyDetail(.utm, state: .tooOld(version: "4.6.4", minimum: "4.7"))
                == "4.6.4; Winbar needs 4.7 or later")
        #expect(Recipe.dependencyDetail(.windowsApp, state: .installed(version: nil)) == "Windows App (unknown version)")
    }

    /// H1 says which UTM this is, so a bug report carries it without anyone having to ask. The row
    /// stays `.ok` — this is a fact about the Mac, not a fault, and doctor still exits 0.
    @Test func h1SaysHowTestedThisUTMIs() {
        #expect(Recipe.dependencyDetail(.utm, state: .installed(version: "4.7.6"))
                == "UTM 4.7.6 (Winbar is tested against 4.7.5)")
        #expect(Recipe.dependencyDetail(.utm, state: .installed(version: "5.0.5"))
                == "UTM 5.0.5 (a pre-release; Winbar is tested against 4.7.5)")
        // The tested version says nothing extra, and a UTM that won't give a version can't be
        // judged, so it says nothing either.
        #expect(Recipe.dependencyDetail(.utm, state: .installed(version: "4.7.5")) == "UTM 4.7.5")
        #expect(Recipe.dependencyDetail(.utm, state: .installed(version: nil)) == "UTM (unknown version)")
        #expect(Recipe.dependencyDetail(.utm, state: .installed(version: "banana")) == "UTM banana")
        // C1 is untouched: the clause belongs to UTM, whose version create is tested against.
        #expect(Recipe.dependencyDetail(.windowsApp, state: .installed(version: "11.1.10"))
                == "Windows App 11.1.10")
        #expect(Recipe.dependencyDetail(.windowsApp, state: .installed(version: "99.0.0"))
                == "Windows App 99.0.0")
    }

    /// The clause is words, not a verdict: an installed UTM still has nothing for setup to fix,
    /// whichever version it is, so H1 stays `.ok` and `winbar doctor` still exits 0 on a Mac
    /// running a 5.x pre-release.
    @Test func anUntestedUTMIsStillNothingToFix() {
        #expect(Dependencies.plan(for: .utm, state: .installed(version: "5.0.5"), brew: "/opt/homebrew/bin/brew")
                == nil)
        #expect(Dependencies.plan(for: .utm, state: .installed(version: "4.7.6"), brew: nil) == nil)
        // Contrast: below the floor is a real fault, and that row is not .ok.
        #expect(Dependencies.plan(for: .utm, state: .tooOld(version: "4.6.4", minimum: "4.7"), brew: nil) != nil)
    }
}

@Suite struct DrivingUTMAfterAnInstall {
    /// Every utmctl call is an Apple Event, and the first one to a newly installed UTM is held by
    /// macOS until somebody allows it. Told apart from a denial, from a failure of utmctl's own,
    /// and from a working one — without UTM.
    @Test func whatUtmctlDid() {
        #expect(UTM.classifyCtl(status: 0, output: "Windows 11  stopped", timedOut: false, seconds: 20) == .answered)
        #expect(UTM.classifyCtl(status: -1, output: "", timedOut: true, seconds: 20) == .silent(seconds: 20))
        // osascript and utmctl both print errAEEventNotPermitted as -1743.
        #expect(UTM.classifyCtl(status: 1, output: "Error: -1743", timedOut: false, seconds: 20) == .denied)
        // A denial that also timed out is still a denial: it said why.
        #expect(UTM.classifyCtl(status: 1, output: "-1743", timedOut: true, seconds: 20) == .denied)
        #expect(UTM.classifyCtl(status: 2, output: "Error: no such VM\n", timedOut: false, seconds: 20)
                == .failed("Error: no such VM"))
    }

    /// The promise made as soon as UTM is installed: a prompt is coming, it can hide, and a Mac
    /// nobody is at never gets past it.
    @Test func theInstallSaysWhatHappensNext() {
        let text = UTMFirstUse.expectAPrompt
        #expect(text.contains("Applications folder"))
        #expect(text.contains("Allow"))
        #expect(text.contains("behind other windows"))
        #expect(text.contains("locked or unattended"))
    }

    /// Three states, three things to say: a prompt nobody has answered yet, an answer already on
    /// file and a switch in System Settings, and macOS not answering the question either.
    @Test func whatToDoAboutSilence() {
        let outstanding = UTMFirstUse.how(consent: .wouldPrompt, quarantined: false, host: "Terminal",
                                          bundleID: "com.apple.Terminal")
        #expect(outstanding.contains("“Terminal” wants access to control “UTM”"))
        #expect(outstanding.contains("still outstanding"))
        #expect(!outstanding.contains("tccutil"))

        let answered = UTMFirstUse.how(consent: .decided, quarantined: false, host: "Terminal",
                                       bundleID: "com.apple.Terminal")
        #expect(answered.contains("Privacy & Security → Automation"))
        #expect(answered.contains("tccutil reset AppleEvents com.apple.Terminal"))

        let noAnswer = UTMFirstUse.how(consent: .unknown, quarantined: false, host: "Terminal",
                                       bundleID: "com.apple.Terminal")
        #expect(noAnswer.contains("wouldn't say"))
        #expect(!noAnswer.contains("tccutil"))
    }

    /// The quarantine mark gets one honest sentence — what it is, that a terminal can't remove it,
    /// and that it isn't the thing to chase — and only when the app actually carries it.
    @Test func theQuarantineMarkIsExplainedNotChased() {
        let marked = UTMFirstUse.how(consent: .wouldPrompt, quarantined: true)
        #expect(marked.contains("downloaded from the internet"))
        #expect(marked.contains("App Management"))
        #expect(marked.contains("isn't what a silent utmctl is waiting for"))
        #expect(!UTMFirstUse.how(consent: .wouldPrompt, quarantined: false).contains("App Management"))
    }

    /// Winbar doesn't ask Homebrew to skip the quarantine mark: it verifies the app itself, and the
    /// mark isn't what stalls a fresh install, so dropping it would buy nothing.
    @Test func homebrewIsNotAskedToSkipQuarantine() {
        for cask in ["utm", "windows-app"] {
            #expect(!Homebrew.installCommand(brew: "/opt/homebrew/bin/brew", cask: cask)
                .arguments.contains("--no-quarantine"))
            #expect(!Homebrew.upgradeCommand(brew: "/opt/homebrew/bin/brew", cask: cask)
                .arguments.contains("--no-quarantine"))
        }
    }

    /// The row says the state in words someone can act on, rather than leaving them to read it as
    /// "Winbar is broken".
    @Test func theRowSaysWhichItIs() {
        #expect(UTMFirstUse.silentDetail(seconds: 60)
                == "UTM is installed, but its command-line tool said nothing for 60 seconds")
        #expect(Recipe.check("H9")?.title == "UTM answers Winbar")
        #expect(Recipe.check("H9")?.section == .host)
    }
}

@Suite struct ARowThatNeverAnswers {
    /// A call that doesn't come back is given up on, and the caller carries on. This is the shape of
    /// the bug it exists for: AEDeterminePermissionToAutomateTarget, asked not to prompt, sat in a
    /// semaphore for twenty minutes and no row after H9 was ever printed.
    @Test func givingUpOnACallThatNeverAnswers() {
        #expect(withDeadline(0.2, { Thread.sleep(forTimeInterval: 5); return 1 }) == nil)
        #expect(withDeadline(5, { 1 }) == 1)
    }

    /// And the row loop keeps its promise: every check produces a row, including the ones after the
    /// one whose probe never answered.
    @Test func everyRowIsStillPrinted() {
        func check(_ id: String) -> Check {
            Check(id: id, section: .host, title: id, why: "for the test", evaluate: { _ in .ok("fine") })
        }
        let checks = [check("X1"), check("X2"), check("X3"), check("X4")]
        /// X2's probe never answers, so its own row says so — and nothing else changes.
        let neverAnswers: () -> UTM.CtlAnswer = {
            Thread.sleep(forTimeInterval: 5)
            return .answered
        }
        var shown: [String] = []
        let rows = Doctor.results(checks, status: { check in
            guard check.id == "X2" else { return .ok("fine") }
            guard let answer = withDeadline(0.2, neverAnswers) else {
                return Recipe.utmctlStatus(.silent(seconds: 1), consent: .unknown, quarantined: false)
            }
            return Recipe.utmctlStatus(answer, consent: .decided, quarantined: false)
        }, show: { check, _ in shown.append(check.id) })

        #expect(rows.map(\.check.id) == ["X1", "X2", "X3", "X4"])
        #expect(shown == ["X1", "X2", "X3", "X4"])   // and each one was printed as it arrived
        #expect(rows[1].status.isManual)             // X2 said what happened to it
        #expect(rows[3].status.isOK)                 // the rows after it are untouched
    }

    /// H9's row, every outcome, without a Mac.
    @Test func theRowForEachOutcome() {
        #expect(Recipe.utmctlStatus(.answered, consent: .decided, quarantined: false).isOK)
        #expect(Recipe.utmctlStatus(.denied, consent: .decided, quarantined: false).isManual)
        #expect(Recipe.utmctlStatus(.silent(seconds: 20), consent: .wouldPrompt, quarantined: true).isManual)
        #expect(Recipe.utmctlStatus(.silent(seconds: 20), consent: .unknown, quarantined: false).detail
                    .contains("said nothing for 20 seconds"))
        if case .error = Recipe.utmctlStatus(.failed("boom"), consent: .decided, quarantined: false) {} else {
            Issue.record("a utmctl failure should be an error")
        }
    }
}

// MARK: - The setup window

/// What the setup window may carry out, which is narrower than the CLI's (gui-wizard.md §3.6, and §4
/// experiment 2, settled): Windows App from the App Store, as the proven path, whether or not
/// Homebrew is here; UTM as the CLI does it. Pure.
@Suite struct WindowPlans {
    let brew = "/opt/homebrew/bin/brew"

    /// The cask runs Microsoft's installer package through sudo, which has no terminal to ask in from
    /// Winbar.app. The control is the CLI's own table, which does offer the cask with Homebrew here.
    @Test func windowsAppIsTheAppStoreWithHomebrewOrWithout() {
        for brew in [brew, nil] {
            #expect(Dependencies.windowPlan(for: .windowsApp, state: .missing, brew: brew)
                        == .appStore(id: Dependency.windowsAppStoreID))
        }
        #expect(Dependencies.plan(for: .windowsApp, state: .missing, brew: brew) == .brew(brew: brew, cask: "windows-app"))
        #expect(Dependencies.windowPlan(for: .windowsApp, state: .tooOld(version: "10.9", minimum: "11.0"), brew: brew)
                    == .appStore(id: Dependency.windowsAppStoreID))
    }

    /// UTM's cask is an app and a symlink: no password, so Homebrew does it from a window too.
    @Test func utmIsTheCLIsTable() {
        let states: [DependencyState] = [.missing, .tooOld(version: "4.6.4", minimum: "4.7"), .installed(version: "4.7.5"),
                                         .wrongSignature("signed by team ABCDE12345")]
        for state in states {
            for brew in [brew, nil] {
                #expect(Dependencies.windowPlan(for: .utm, state: state, brew: brew)
                            == Dependencies.plan(for: .utm, state: state, brew: brew))
            }
        }
        #expect(Dependencies.windowPlan(for: .utm, state: .missing, brew: brew) == .brew(brew: brew, cask: "utm"))
        #expect(Dependencies.windowPlan(for: .utm, state: .missing, brew: nil) == .download(url: Dependency.utmDownloadURL))
    }

    @Test func nothingForAnAppThatIsThereAndNeverAReplacement() {
        for brew in [brew, nil] {
            #expect(Dependencies.windowPlan(for: .windowsApp, state: .installed(version: "11.1.10"), brew: brew) == nil)
            guard case .manual(let advice)? = Dependencies.windowPlan(for: .windowsApp,
                                                                      state: .wrongSignature("signed by team X"),
                                                                      brew: brew) else {
                Issue.record("a Windows App that isn't Microsoft's should be manual, brew=\(brew ?? "none")")
                continue
            }
            #expect(advice.contains("won't replace"))
        }
    }

    /// Step 1 draws C1's row long before step 5 acts on it, and the row has to say what step 5's
    /// button will do. With Homebrew here, the CLI's row offers Homebrew; the window never does, so
    /// its row is built from the window's plan. The control is the terminal's own row, which still
    /// offers Homebrew.
    @Test func theWindowsRowsSayWhatTheWindowDoes() {
        for brew in [brew, nil] {
            for state: DependencyState in [.missing, .tooOld(version: "10.9", minimum: "11.0")] {
                let row = SetupRunner.dependencyRow(.windowsApp, state: state, brew: brew)
                #expect(row.isFixable)
                #expect(row.detail.hasSuffix("; setup can open its App Store page"), "\(state), brew=\(brew ?? "none")")
                #expect(!row.detail.contains("Homebrew"))
            }
        }
        #expect(Recipe.dependencyStatus(.windowsApp, state: .missing, brew: brew).detail
                    == "not installed; setup can ask Homebrew to install it")
        // UTM's plan is the CLI's, and so is its row.
        #expect(SetupRunner.dependencyRow(.utm, state: .missing, brew: brew).detail
                    == "not installed; setup can ask Homebrew to install it")
        #expect(SetupRunner.dependencyRow(.utm, state: .missing, brew: nil).detail
                    == Recipe.dependencyStatus(.utm, state: .missing, brew: nil).detail)
        #expect(SetupRunner.dependencyRow(.windowsApp, state: .installed(version: "11.1.10"), brew: brew).isOK)
    }

    /// Nothing the window can carry out runs a command that asks for a password.
    @Test func nothingItCarriesOutIsPrivileged() {
        let states: [DependencyState] = [.missing, .tooOld(version: "1.0", minimum: "4.7"), .wrongSignature("x")]
        for dependency in Dependency.allCases {
            for state in states {
                for brew in [brew, nil] {
                    guard let command = Dependencies.windowPlan(for: dependency, state: state, brew: brew)?.command else {
                        continue
                    }
                    #expect(!DependencyCommand.isPrivileged(tool: command.tool, arguments: command.arguments))
                    #expect(!command.arguments.contains("windows-app"), "the window never runs the Windows App cask")
                }
            }
        }
    }
}

/// `runStreaming`, the window's way of running Homebrew. These run `/bin/sh`, `/bin/echo` and
/// `/bin/sleep` — nothing that reaches UTM, a VM, the network or anything privileged.
@Suite struct StreamingACommand {
    /// Refused before anything starts, exactly as `runAttached` refuses it. The control is what the
    /// command would do if it ran: `echo` prints its arguments, so a line arriving means it started.
    @Test func refusesAPrivilegedCommandBeforeItStarts() {
        let lines = Lines()
        #expect(DependencyCommand.runStreaming("/bin/echo", ["sudo", "installer", "-pkg", "x"], timeout: 5,
                                               line: lines.add) == nil)
        #expect(DependencyCommand.runStreaming("/usr/sbin/installer", ["-pkg", "x", "-target", "/"], timeout: 5,
                                               line: lines.add) == nil)
        #expect(lines.all.isEmpty)
        // The same arguments without the privileged word do run, and are heard.
        #expect(DependencyCommand.runStreaming("/bin/echo", ["installing", "x"], timeout: 5, line: lines.add) == 0)
        #expect(lines.all == ["installing x"])
    }

    /// Both streams, a line at a time, the unterminated last one too, and the exit status.
    @Test func relaysBothStreamsLineByLine() {
        let lines = Lines()
        let status = DependencyCommand.runStreaming(
            "/bin/sh", ["-c", "printf '==> Downloading UTM.dmg\\n'; printf 'Warning: already tapped\\n' >&2; printf 'done'; exit 3"],
            timeout: 10, line: lines.add)
        #expect(status == 3)
        #expect(Set(lines.all) == ["==> Downloading UTM.dmg", "Warning: already tapped", "done"])
    }

    /// Nothing the child asks can wait for an answer that isn't coming: its input is /dev/null,
    /// whatever the process came with. The process here comes with a pipe that never closes — what
    /// an inherited terminal would be — so without the emptying the child reports the pipe and its
    /// `read` waits out the timeout.
    @Test func itsInputIsEmptyWhateverItCameWith() {
        let lines = Lines()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "[ /dev/stdin -ef /dev/null ] && echo empty || echo inherited; read answer; "
                                + "echo \"got [$answer]\""]
        let inherited = Pipe()
        process.standardInput = inherited
        #expect(DependencyCommand.stream(process, timeout: 5, line: lines.add) == 0)
        #expect(lines.all == ["empty", "got []"])
        withExtendedLifetime(inherited) {}
    }

    /// The check is in `stream` itself, so a process made some other way is refused there too.
    @Test func streamRefusesAPrivilegedProcess() {
        let lines = Lines()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/echo")
        process.arguments = ["sudo", "installer"]
        #expect(DependencyCommand.stream(process, timeout: 5, line: lines.add) == nil)
        #expect(lines.all.isEmpty)
    }

    @Test func aCommandThatRunsPastItsTimeoutIsStopped() {
        let started = Date()
        #expect(DependencyCommand.runStreaming("/bin/sleep", ["30"], timeout: 0.5, line: { _ in }) == nil)
        #expect(Date().timeIntervalSince(started) < 10)
    }

    private final class Lines {
        private let lock = NSLock()
        private var lines: [String] = []
        func add(_ line: String) {
            lock.lock()
            lines.append(line)
            lock.unlock()
        }
        var all: [String] {
            lock.lock()
            defer { lock.unlock() }
            return lines
        }
    }
}

/// The splitting behind `runStreaming`, with no process at all.
@Suite struct SplittingLines {
    private func split(_ chunks: [String]) -> [String] {
        var splitter = LineSplitter()
        return chunks.flatMap { splitter.feed(Data($0.utf8)) } + splitter.finish()
    }

    @Test func aLineCutBetweenTwoReadsIsJoined() {
        #expect(split(["==> Down", "loading UTM.dmg\n==> Pour", "ing\n"]) == ["==> Downloading UTM.dmg", "==> Pouring"])
    }

    /// Homebrew redraws its progress with `\r`: each redraw is the latest word, not held back until
    /// 100%. `\r\n` is one ending even when a read falls between the two.
    @Test func carriageReturnsEndLinesAndCRLFIsOne() {
        #expect(split(["#### 25.0%\r###### 50.0%\r", "######## 100.0%\r\n", "==> Installing\r", "\nok\n"])
                    == ["#### 25.0%", "###### 50.0%", "######## 100.0%", "==> Installing", "ok"])
    }

    @Test func theLastLineWithoutAnEndingIsKeptAndBlankLinesAreNot() {
        #expect(split(["\n\n==> Caveats\n\n", "UTM was installed"]) == ["==> Caveats", "UTM was installed"])
        #expect(split([]) == [])
    }

    /// Split as bytes, decoded as lines: a character cut in half by a read comes back whole.
    @Test func aCharacterCutInHalfIsJoinedBeforeItIsDecoded() {
        let bytes = Array("🍺  utm was installed\n".utf8)
        var splitter = LineSplitter()
        let first = splitter.feed(Data(bytes[0..<2]))
        let rest = splitter.feed(Data(bytes[2...]))
        #expect(first.isEmpty)
        #expect(rest == ["🍺  utm was installed"])
    }
}

/// `install` runs Homebrew through the runner it is given: `runAttached` for `winbar setup`,
/// `runStreaming` for the window. The fake runner never runs anything; the brew path doesn't exist,
/// so even an install that ignored it would fail to start rather than install.
@Suite struct InstallingThroughARunner {
    let brew = "/nonexistent/winbar-tests/brew"

    @Test func homebrewsCommandGoesToTheRunnerItIsGiven() {
        var asked: [(String, [String], TimeInterval)] = []
        let result = DependencyInstaller.install(.utm, plan: .brew(brew: brew, cask: "utm"), agreed: true,
                                                 runner: { tool, arguments, timeout in
                                                     asked.append((tool, arguments, timeout))
                                                     return 1
                                                 })
        #expect(asked.count == 1)
        #expect(asked.first?.0 == brew)
        #expect(asked.first?.1 == ["install", "--cask", "utm"])
        #expect(asked.first?.2 == 3600)
        guard case .failure(let error) = result else {
            Issue.record("exit status 1 should fail the install")
            return
        }
        #expect(error.title == "Homebrew couldn't install UTM")
    }

    /// An update that fails says it was an update, not "couldn't install".
    @Test func aFailedUpdateSaysUpdate() {
        let result = DependencyInstaller.install(.utm, plan: .brewUpgrade(brew: brew, cask: "utm"), agreed: true,
                                                 runner: { _, _, _ in 1 })
        guard case .failure(let error) = result else {
            Issue.record("exit status 1 should fail the update")
            return
        }
        #expect(error.title == "Homebrew couldn't update UTM")
        #expect(error.detail.hasSuffix("brew upgrade --cask utm"))
    }

    @Test func aRunnerThatRefusesOrTimesOutIsAnInstallThatDidntFinish() {
        let result = DependencyInstaller.install(.utm, plan: .brew(brew: brew, cask: "utm"), agreed: true,
                                                 runner: { _, _, _ in nil })
        guard case .failure(let error) = result else {
            Issue.record("a refused command should fail the install")
            return
        }
        #expect(error.title == "Homebrew didn't finish")
    }

    /// Without a yes nothing reaches any runner.
    @Test func noYesNoRunner() {
        var ran = false
        _ = DependencyInstaller.install(.utm, plan: .brew(brew: brew, cask: "utm"), agreed: false,
                                        runner: { _, _, _ in
                                            ran = true
                                            return 0
                                        })
        #expect(!ran)
    }
}
