import Foundation
import Testing
@testable import Winbar

// The setup wizard's copy deck (SetupCopy). Three things are checked here, all as plain values:
//
// - that `winbar setup` prints what it printed before its strings moved into the deck, word for word,
//   so the move is a move and not a rewrite;
// - that the deck doesn't carry the sentences the spec's critique and the re-measurements showed to
//   be untrue, that the window's variants differ from the terminal's only where they must, and that
//   a name someone chose reaches the window as its own characters, never as Markdown;
// - that Armie, the wizard's guide, has a line for every install stage, never exclaims, never asks,
//   and goes quiet on an error and beside a warning about the password.
//
// Nothing here reaches UTM, a VM, the keychain or TCC: every fact is passed in.

// MARK: - winbar setup's output, pinned

@Suite("winbar setup says what it said before its strings moved into the deck")
struct SetupOutputPinned {
    @Test("The hoisted progress lines read exactly as they did inside Setup and Context")
    func progressLines() {
        #expect(SetupCopy.waitingForWindows == "Waiting for Windows and its guest agent (up to three minutes)…")
        #expect(SetupCopy.agentNotYet == "The guest agent didn't answer yet.")
        #expect(SetupCopy.Tune.askingWindows == "Asking Windows (this takes a few seconds)…")
        #expect(SetupCopy.Tune.still("no password yet") == "still: no password yet")
        #expect(SetupCopy.BitLocker.decryptingInBackground
                == "Windows decrypts in the background and carries on across restarts.")
    }

    @Test("The single restart's line is unchanged for the terminal's bare VM name")
    func oneRestart() {
        let changes = ConfigChanges(cpuCores: 6, memoryMB: 12288, display: .headless)
        #expect(SetupCopy.Finish.oneRestart(of: "winlab01", applies: changes.summary)
                == "One restart of winlab01 applies: 6 vCPUs, 12288 MB RAM, headless.")
    }

    /// H7 printed this from inside its `apply`, after the yes and before macOS's prompt. Setup now
    /// prints it at the same moment, and no other fix gains or loses a line on the way.
    @Test("Only H7 has a line between the yes and the fix, and it is the one H7 used to print")
    func beforeFix() {
        #expect(SetupCopy.beforeFix("H7") == "macOS will ask you to approve trusting it.")
        for check in Recipe.checks where check.id != "H7" {
            #expect(SetupCopy.beforeFix(check.id) == nil, "\(check.id) gained a line before its fix")
        }
    }

    @Test("The saved-PC paragraph reads as Setup.savedPCWhyPassword did, argv admission and all")
    func savedPCWhy() {
        #expect(SetupCopy.SavedPC.why(user: "rosa")
                == "Windows App needs the password for rosa to save this PC, so Connect doesn't ask for it every time. "
                    + "Winbar hands it straight to Windows App, which keeps it in your login keychain, the same as when "
                    + "you type it in yourself. Winbar keeps no copy. For the second that takes, the password is one of "
                    + "Windows App's command line arguments, where another program running as you could read it: Windows "
                    + "App has no other way to be given a password without you typing it in again. Winbar can't check the "
                    + "password without risking a failed sign-in, so the saved PC won't retry by itself until you've "
                    + "connected once.")
    }

    @Test("G9's offer keeps its words when Winbar can't see where the disk is")
    func bitLockerGuessedLocation() {
        let offer = SetupCopy.BitLocker.offer(places: [.startupDisk], unprotected: [], imagesKnown: false)
        #expect(offer.explanation
                == "Decrypting it: FileVault encrypts this Mac's startup disk, where UTM keeps VMs unless told otherwise. "
                    + "If this VM is stored somewhere else, such as an external drive, its disk would be unencrypted there: "
                    + "answer n. BitLocker costs I/O and demands its recovery key after any VM hardware change. "
                    + "(--keep-bitlocker keeps it on.)")
        #expect(offer.question == "Decrypt C:?")
        #expect(offer.defaultYes)
    }

    @Test("G9's offer keeps its words for a disk on an encrypted volume")
    func bitLockerEncrypted() {
        let startup = SetupCopy.BitLocker.offer(places: [.startupDisk], unprotected: [], imagesKnown: true)
        #expect(startup.explanation
                == "Decrypting it: The VM's disk is on this Mac's startup disk, which is encrypted by FileVault. "
                    + "BitLocker costs I/O and demands its recovery key after any VM hardware change. "
                    + "(--keep-bitlocker keeps it on.)")
        #expect(startup.question == "Decrypt C:?")
        #expect(startup.defaultYes)

        let external = SetupCopy.BitLocker.offer(places: [.volume("/Volumes/atelier")], unprotected: [], imagesKnown: true)
        #expect(external.explanation
                == "Decrypting it: The VM's disk is on atelier, which is encrypted at rest. BitLocker costs I/O and "
                    + "demands its recovery key after any VM hardware change. (--keep-bitlocker keeps it on.)")
    }

    @Test("G9's offer keeps its words, and its no-by-default question, for an unencrypted disk")
    func bitLockerUnencrypted() {
        let offer = SetupCopy.BitLocker.offer(places: [.startupDisk], unprotected: [.startupDisk], imagesKnown: true)
        #expect(offer.explanation
                == "The VM's disk is on this Mac's startup disk (FileVault is off), so decrypting C: would leave it "
                    + "unencrypted at rest. BitLocker still costs I/O and demands its recovery key after VM hardware changes.")
        #expect(offer.question == "Decrypt C: anyway?")
        #expect(!offer.defaultYes)

        // Two places are named in a stable order, whichever order the disks were found in.
        let both: [Winbar.Host.Storage] = [.startupDisk, .volume("/Volumes/atelier")]
        let twice = SetupCopy.BitLocker.offer(places: both, unprotected: both, imagesKnown: true)
        #expect(twice.explanation.hasPrefix("The VM's disk is on atelier, which isn't encrypted and this Mac's startup "
                                            + "disk (FileVault is off), so decrypting C:"))
        #expect(SetupCopy.BitLocker.offer(places: both.reversed(), unprotected: both.reversed(), imagesKnown: true) == twice)
    }

    /// The window's No writes `Config.keepBitLocker`, so its offer says that rather than naming a
    /// Terminal flag; the terminal's words stay exactly as the tests above pin them.
    @Test("The window's BitLocker offer differs from the terminal's only in how to say no and what no does")
    func bitLockerWindow() {
        typealias Answers = SetupCopy.BitLocker.Answers
        #expect(Answers.terminal == Answers(decline: "answer n", keep: "(--keep-bitlocker keeps it on.)"))
        let cases: [(places: [Winbar.Host.Storage], unprotected: [Winbar.Host.Storage], imagesKnown: Bool)] = [
            ([.startupDisk], [], false), ([.startupDisk], [], true), ([.volume("/Volumes/atelier")], [], true),
            ([.startupDisk], [.startupDisk], true),
        ]
        for c in cases {
            let terminal = SetupCopy.BitLocker.offer(places: c.places, unprotected: c.unprotected, imagesKnown: c.imagesKnown)
            let window = SetupCopy.BitLocker.offer(places: c.places, unprotected: c.unprotected, imagesKnown: c.imagesKnown,
                                                   answers: .window)
            #expect(!window.explanation.contains("--"), "\(window.explanation)")
            #expect(!window.explanation.contains("answer n"), "\(window.explanation)")
            #expect(window.explanation
                        .replacingOccurrences(of: Answers.window.keep, with: Answers.terminal.keep)
                        .replacingOccurrences(of: Answers.window.decline, with: Answers.terminal.decline)
                    == terminal.explanation)
            #expect(window.question == terminal.question)
            #expect(window.defaultYes == terminal.defaultYes)
        }
        #expect(SetupCopy.BitLocker.offer(places: [.startupDisk], unprotected: [], imagesKnown: false, answers: .window)
                    .explanation
                == "Decrypting it: FileVault encrypts this Mac's startup disk, where UTM keeps VMs unless told otherwise. "
                    + "If this VM is stored somewhere else, such as an external drive, its disk would be unencrypted there: "
                    + "choose No. BitLocker costs I/O and demands its recovery key after any VM hardware change. "
                    + "Choosing No keeps it on, and Winbar won't ask again for this VM.")
    }
}

// MARK: - UTMFirstUse.how, both front-ends

@Suite("The silent-utmctl advice says what each front-end can do")
struct SilentUTMAdvice {
    private static let consents: [Automation.Consent] = [.wouldPrompt, .unknown, .decided]

    @Test("The terminal's advice ends on the command to run")
    func terminal() {
        #expect(UTMFirstUse.terminalRetry == "run winbar doctor again")
        #expect(UTMFirstUse.how(consent: .wouldPrompt, quarantined: false, host: "Terminal", bundleID: "com.apple.Terminal")
                == "Open UTM from your Applications folder, and look for macOS's prompt, “Terminal” wants access to "
                    + "control “UTM” — it can be behind another window. Choose Allow, then run winbar doctor again. macOS has never been asked "
                    + "whether Terminal may control UTM, so that prompt is still outstanding: nothing Winbar asks of UTM "
                    + "can finish until it is answered.")
    }

    /// The spec had the window reuse the terminal's advice with Try Again in its retry clause. That
    /// asked the person to open UTM, which the window had just done, and with an answer already on
    /// file told them to look for a prompt that wasn't coming. The window's own advice, per consent.
    @Test("The window's advice asks for nothing it has done, and promises no prompt that isn't coming")
    func window() {
        for consent in Self.consents {
            let text = String(SetupCopy.markdown(SetupCopy.LookAround.silent(consent: consent, host: "Winbar")).characters)
            #expect(text.hasPrefix("Winbar opened UTM"), "\(consent)")
            #expect(!text.contains("Applications folder") && !text.contains("tccutil") && !text.contains("winbar doctor"),
                    "\(consent)")
            #expect(text.hasSuffix("then press Try Again."), "\(consent)")
            if consent == .decided {
                #expect(text.contains("no prompt is coming") && text.contains("Privacy & Security → Automation"))
                #expect(!text.contains("Choose Allow") && !text.contains("look for"))
            } else {
                #expect(text.contains("“Winbar” wants access to control “UTM”") && text.contains("Choose Allow there"))
            }
        }
    }

    /// The terminal's words fail the window's test: the control for the one above.
    @Test("The terminal's advice, shown in the window, would fail that")
    func windowControl() {
        let decided = UTMFirstUse.how(consent: .decided, quarantined: false, host: "Winbar", bundleID: "net.elusive.winbar")
        #expect(decided.contains("Applications folder") && decided.contains("look for") && decided.contains("tccutil"))
    }
}

// MARK: - The window's copy

/// What a sentence with a name in it says, as characters.
private func plain(_ text: AttributedString) -> String { String(text.characters) }

/// The window's sentences that carry a chosen value, for `name` (and `host`, where it's a host name).
private func filledStrings(name: String, host: String) -> [AttributedString] {
    [SetupCopy.VM.oneBody(name, windows: true), SetupCopy.VM.oneBody(name, windows: false),
     SetupCopy.VM.stopped(name), SetupCopy.VM.bUse(name), SetupCopy.Tune.stagedNote(vm: name),
     SetupCopy.SavedPC.passwordLabel(user: name), SetupCopy.Certificate.body(host: host),
     SetupCopy.Connecting.opening(host: host), SetupCopy.Quitting.body(doing: "restarting “\(name)”"),
     SetupCopy.Working.restartOwed(vm: name), SetupCopy.Working.slept(while: "restarting “\(name)”"),
     SetupCopy.Working.refusal(.init(work: .startVM(name), started: Date(), vm: name)),
     SetupCopy.Working.refusal(.init(work: .applyChanges, started: Date(), vm: name)),
     SetupCopy.Quitting.body(doing: SetupCopy.Working.doing(.init(work: .applyChanges, started: Date(), vm: name))),
     SetupCopy.Finish.doneBody(vm: name, connected: true)[0], SetupCopy.Finish.doneBody(vm: name, connected: false)[0]]
}

/// The window's own Markdown, which carries no chosen value.
private let windowMarkdown: [String] = {
    var all: [String] = [SetupCopy.winTitle, SetupCopy.menuItem, SetupCopy.bBack, SetupCopy.bSkip, SetupCopy.bCheckAgain]
    all += SetupCopy.stepNames
    all += SetupCopy.Welcome.body(lastBuilt: .lookAround) + SetupCopy.Welcome.body(lastBuilt: .finish)
    all += [SetupCopy.Welcome.lead, SetupCopy.Welcome.bNotNow, SetupCopy.Welcome.bStart]
    all += SetupCopy.stepBarNames
    all += [SetupCopy.LookAround.askHeading, SetupCopy.LookAround.askBody, SetupCopy.LookAround.askInstruction(),
            SetupCopy.LookAround.askInstruction(quarantined: true),
            SetupCopy.LookAround.askAside(), SetupCopy.LookAround.askAside(quarantined: true), SetupCopy.LookAround.settleHeading, SetupCopy.LookAround.settleOpen, SetupCopy.LookAround.utmFailedHeading,
            SetupCopy.LookAround.silentRow(seconds: 60), SetupCopy.LookAround.denied(host: "Winbar"),
            SetupCopy.LookAround.needsHeading(.missing), SetupCopy.LookAround.needsHeading(.tooOld(version: "4.5.4", minimum: "4.6.0")),
            SetupCopy.LookAround.needsHeading(.wrongSignature("x")), SetupCopy.LookAround.bOpenUTMAndAsk,
            SetupCopy.LookAround.windowsAppLater(lastBuilt: .lookAround), SetupCopy.LookAround.windowsAppLater(lastBuilt: .finish),
            SetupCopy.LookAround.rowUTM, SetupCopy.LookAround.rowVMs, SetupCopy.LookAround.rowWindowsApp,
            SetupCopy.LookAround.bContinue, SetupCopy.LookAround.bOpenAutomationSettings, SetupCopy.LookAround.installing(update: false),
            SetupCopy.LookAround.installing(update: true), SetupCopy.LookAround.silentHeading, SetupCopy.LookAround.quarantineAside,
            SetupCopy.LookAround.silent(consent: .wouldPrompt, host: "Winbar"), SetupCopy.LookAround.silent(consent: .decided, host: "Winbar"),
            SetupCopy.LookAround.updateMayAsk(host: "Winbar"), SetupCopy.bClose, SetupCopy.VM.bMakeOne,
            SetupCopy.LookAround.utmFailed, SetupCopy.LookAround.vmCount(0), SetupCopy.LookAround.vmCount(3),
            SetupCopy.notBuiltYet, SetupCopy.stepCounter(.lookAround), SetupCopy.stepBarLabel(.lookAround),
            SetupCopy.Armie.name]
    all += [InstallPlan.brew(brew: "/opt/homebrew/bin/brew", cask: "utm"), .brewUpgrade(brew: "/opt/homebrew/bin/brew", cask: "utm"),
            .download(url: "https://example.invalid/UTM.dmg")].compactMap { SetupCopy.LookAround.bInstall(.utm, $0) }
    all += SetupCopy.VM.noneBody + [SetupCopy.VM.noneHeading, SetupCopy.VM.oneHeading, SetupCopy.VM.severalHeading,
                                    SetupCopy.VM.severalBody(count: 3)]
    all += [SetupCopy.Tune.heading, SetupCopy.Tune.body]
    all += [SetupCopy.Certificate.heading, SetupCopy.Certificate.approvalWindow, SetupCopy.Certificate.noCertificate]
    all += [SetupCopy.SavedPC.heading, SetupCopy.SavedPC.lead, SetupCopy.SavedPC.appOpen]
    all += SetupCopy.SavedPC.windowsAppPlan(brewPresent: true) + SetupCopy.SavedPC.windowsAppPlan(brewPresent: false)
    all += [SetupCopy.Connecting.heading, SetupCopy.Connecting.accessibility, SetupCopy.Connecting.localNetwork,
            SetupCopy.Connecting.waiting, SetupCopy.Connecting.didItAppearHeading,
            SetupCopy.Connecting.didItAppear(savedPC: true), SetupCopy.Connecting.didItAppear(savedPC: false)]
    all += SetupCopy.Finish.headlessBody + [SetupCopy.Finish.headlessHeading, SetupCopy.Finish.afterRefusal,
                                            SetupCopy.Finish.notOffering, SetupCopy.Finish.doneHeading]
    all += [SetupCopy.Quitting.title]
    all += [SetupCopy.Working.waiting(.certificateApproval), SetupCopy.Working.waiting(.automationPrompt),
            SetupCopy.Working.bStopWaiting, SetupCopy.agentNotYet]
    return all
}()

/// Every string the window shows, as the words a person reads, with invented values where a
/// function needs them.
private let windowStrings: [String] = windowMarkdown.map { plain(SetupCopy.markdown($0)) }
    + filledStrings(name: "winlab01", host: "winlab01.local").map(plain)
    + [plain(SetupCopy.Finish.doneBody(vm: "winlab01", connected: true)[1])]

@Suite("The setup window's copy says only what is known to be true")
struct SetupWindowCopy {
    /// The measurements and the critique each struck a sentence out of the spec's copy. None of them
    /// may come back: the old idle figure, the unmeasured Touch ID promise, the wrong ISO size, the
    /// other-VMs line the code would refuse after, and the chooser the code never shows. The idle
    /// figure is matched however it is spelt, since "90 percent" would be the same untrue claim.
    @Test("None of the sentences the critique and the measurements disproved is in the deck")
    func noDisprovenClaims() {
        for text in windowStrings {
            #expect(text.range(of: #"(?i)\b(90|ninety)\s*(%|per\s?cent)"#, options: .regularExpression) == nil,
                    "\(text)")
            #expect(!text.contains("Touch ID"), "\(text)")
            #expect(!text.contains("5 GB"), "\(text)")
            #expect(!text.contains("Also running now"), "\(text)")
            #expect(!text.contains("at any time"), "\(text)")
            #expect(!text.contains("chooser"), "\(text)")
            #expect(!text.contains("only ships"), "\(text)")
            #expect(!text.isEmpty)
        }
    }

    @Test("What Terminal prints too is plain text, never Markdown")
    func sharedLinesArePlain() {
        let shared = [SetupCopy.waitingForWindows, SetupCopy.agentNotYet, SetupCopy.Tune.askingWindows, SetupCopy.Tune.still("x"),
                      SetupCopy.Certificate.approval, SetupCopy.SavedPC.why(user: "rosa"),
                      SetupCopy.BitLocker.decryptingInBackground,
                      SetupCopy.Finish.oneRestart(of: "winlab01", applies: "headless"),
                      SetupCopy.BitLocker.offer(places: [.startupDisk], unprotected: [], imagesKnown: false).explanation]
        for text in shared { #expect(!text.contains("**"), "\(text)") }
    }

    /// Each of these is something Foundation's Markdown parser would change if it saw it: emphasis,
    /// code, a link written out, a bare URL, a www address, an email address (a Microsoft account's
    /// user name), an entity, a strikethrough, an autolink, backslash escapes (which the parser would
    /// eat), and a lone marker that would pair with one of the deck's own.
    private static let hostile = ["winlab01 *beta*", "`atelier`", "[atelier](https://example.invalid)",
                                  "https://example.invalid", "www.example.com", "rosa@example.com", "Bruno &amp; rosa",
                                  "~~winlab01~~", "<https://example.invalid>", "winlab01 \\*beta\\*", "_rosa_", "**"]

    @Test("A name someone chose comes back as its own characters: no emphasis, no code, no link")
    func namesAreNeverMarkdown() {
        for name in Self.hostile {
            for text in filledStrings(name: name, host: name) {
                guard let range = text.range(of: name) else {
                    Issue.record("“\(name)” didn't come back as itself in “\(plain(text))”")
                    continue
                }
                for run in text[range].runs {
                    #expect(run.link == nil, "“\(name)” became a link in “\(plain(text))”")
                    #expect(run.inlinePresentationIntent == nil, "“\(name)” was styled in “\(plain(text))”")
                    #expect(run.presentationIntent == nil, "“\(name)” became a block in “\(plain(text))”")
                }
                #expect(!text.runs.contains { $0.link != nil }, "a link appeared in “\(plain(text))”")
            }
        }
    }

    /// The other half: the deck's own words around a name are still Markdown, and a name made of
    /// markers can't reach them.
    @Test("The deck's own bold survives beside a name made of Markdown markers")
    func deckMarkdownBesideAName() {
        for name in ["winlab01", "**", "*", "winlab01 **beta"] {
            let ready = SetupCopy.Finish.doneBody(vm: name, connected: true)[0]
            #expect(plain(ready) == "“\(name)” is ready. Connect in Winbar's menu opens its desktop; Shut Down and "
                        + "Restart are there too.")
            for word in ["Connect", "Shut Down", "Restart"] {
                guard let range = ready.range(of: word) else {
                    Issue.record("\(word) is missing beside “\(name)”")
                    continue
                }
                #expect(ready[range].runs.allSatisfy { $0.inlinePresentationIntent == .stronglyEmphasized },
                        "\(word) lost its bold beside “\(name)”")
            }
            // The paragraph after it has no name in it, and is plain Markdown.
            let again = SetupCopy.Finish.doneBody(vm: name, connected: true)[1]
            #expect(again.range(of: "Set Up Winbar…").map { again[$0].runs.allSatisfy {
                $0.inlinePresentationIntent == .stronglyEmphasized } } == true)
        }
    }

    @Test("The window's Markdown all parses: no marker is left showing")
    func markdownParses() {
        for text in windowStrings { #expect(!text.contains("**"), "\(text)") }
    }

    @Test("There are eight steps, as the spec's table has, each named once")
    func stepNames() {
        #expect(SetupCopy.stepNames.count == 8)
        #expect(Set(SetupCopy.stepNames).count == 8)
    }

    @Test("The ISO size is the one create's own error already gives")
    func isoSize() {
        #expect(SetupCopy.VM.noneBody.joined().contains("about 8 GB"))
        #expect(ISOProblem.unreadable(file: "Win11.iso", reason: "x").message.contains("about 8 GB"))
    }

    /// Critique §4: the approval is whatever macOS decides to show, so the deck promises only that it
    /// asks. The window's paragraph opens on the terminal's sentence, so the two can't drift apart.
    @Test("The certificate step promises an approval, not a particular kind of one")
    func certificateApproval() {
        #expect(SetupCopy.Certificate.approvalWindow.hasPrefix(SetupCopy.Certificate.approval))
        #expect(!SetupCopy.Certificate.approvalWindow.lowercased().contains("password"))
        let body = plain(SetupCopy.Certificate.body(host: "winlab01.local"))
        #expect(body.contains("Winbar made one for winlab01.local,"))
        #expect(body.contains("for that name only"))
        #expect(body.contains("for your account on this Mac"))
    }

    /// Critique §4: C3's guide opens System Settings as well as asking macOS, and that is what the
    /// person sees next, so the copy says so.
    @Test("Allow Accessibility says it opens System Settings, and what happens without it")
    func accessibility() {
        let text = SetupCopy.Connecting.accessibility
        #expect(text.contains("**Allow Accessibility**"))
        #expect(text.contains("opens System Settings at Privacy & Security → Accessibility"))
        #expect(text.contains("one-off connection"))
        // The readiness probe is all Local Network is for; "Connect works either way" waits on a measurement.
        #expect(SetupCopy.Connecting.localNetwork.contains("only to check whether the VM's Remote Desktop port is answering"))
        #expect(!SetupCopy.Connecting.localNetwork.contains("either way"))
    }

    @Test("A one-off connection isn't described as pressing a saved PC")
    func didItAppear() {
        #expect(SetupCopy.Connecting.didItAppear(savedPC: true).hasPrefix("Winbar pressed your saved PC"))
        #expect(!SetupCopy.Connecting.didItAppear(savedPC: false).contains("saved PC"))
        #expect(SetupCopy.Connecting.didItAppear(savedPC: false).contains("one-off connection"))
    }

    @Test("Each VM screen says only what UTM told Winbar about the VMs")
    func vmScreens() {
        #expect(plain(SetupCopy.VM.oneBody("winlab01", windows: true)).hasPrefix("UTM has one Windows VM: “winlab01”."))
        #expect(!plain(SetupCopy.VM.oneBody("Bruno", windows: false)).contains("Windows VM"))
        #expect(SetupCopy.VM.severalBody(count: 12).hasPrefix("UTM has 12 virtual machines."))
        #expect(plain(SetupCopy.VM.stopped("winlab01"))
                == "“winlab01” is stopped. Winbar needs Windows running to check and tune it.")
    }

    /// COHERENCE C2: `Reconfigure.apply` refuses any display change while another VM runs, so the
    /// offer states that rule, in both directions, rather than naming VMs it would then stop.
    @Test("The headless offer quotes the re-measured saving and the rule Reconfigure keeps")
    func headlessOffer() {
        let text = SetupCopy.Finish.headlessBody.joined(separator: " ")
        #expect(text.contains("about two thirds"))
        #expect(text.contains("only does it while this is the only one"))
        #expect(text.contains("**Show Console Window…**"))
        #expect(SetupCopy.Finish.notOffering.contains("hasn't worked yet"))
    }

    /// COHERENCE C2: with another VM running, or UTM not answering, step 7 shows `otherVMsRefusal`'s
    /// own title and detail in place of the offer. The deck adds its framing and the buttons' names,
    /// and nothing of the refusal: a second copy of one rule's words is free to drift from the code
    /// that enforces it. The phrases are the refusal's, as `Reconfigure` words them, and the line the
    /// spec used to have in its place.
    @Test("Beside Reconfigure's refusal the deck has only its own words, and no Go Headless button")
    func refusalFraming() {
        let framing = SetupCopy.Finish.afterRefusal
        #expect(framing.hasPrefix("**\(SetupCopy.bCheckAgain)** asks UTM again."))
        #expect(framing.contains("**\(SetupCopy.Finish.bKeepScreen)**"))
        #expect(!framing.contains("**\(SetupCopy.Finish.bGoHeadless)**"))
        #expect(plain(SetupCopy.markdown(framing)).contains("Go Headless… in Winbar's menu"))
        for text in windowStrings {
            for refusal in ["stop your other vms", "couldn't confirm no other vms", "restarting utm would stop",
                            "or quit utm", "nothing was changed", "also running now"] {
                #expect(!text.lowercased().contains(refusal), "\(text)")
            }
        }
    }

    @Test("The done screen only calls the VM ready when Connect worked")
    func doneScreen() {
        #expect(plain(SetupCopy.Finish.doneBody(vm: "winlab01", connected: true)[0]).hasPrefix("“winlab01” is ready."))
        // Skipped Windows App: Connect was never tried, so the ready sentence would be untrue.
        let skipped = plain(SetupCopy.Finish.doneBody(vm: "winlab01", .windowsAppSkipped)[0])
        #expect(!skipped.contains("opens its desktop"))
        #expect(!skipped.contains("is ready"))
        #expect(skipped.contains("Windows App"))
        let notYet = plain(SetupCopy.Finish.doneBody(vm: "winlab01", connected: false)[0])
        #expect(!notYet.contains("ready"))
        #expect(notYet.contains("hasn't worked yet"))
    }

    /// The window always uses the App Store for Windows App. With Homebrew present it says why rather
    /// than claiming Homebrew isn't there; without it, it doesn't mention Homebrew at all.
    @Test("The Windows App plan is true with Homebrew and without it")
    func windowsAppPlan() {
        let withBrew = SetupCopy.SavedPC.windowsAppPlan(brewPresent: true)
        #expect(withBrew.count == 2)
        #expect(withBrew[0].contains("sudo"))
        #expect(!withBrew.joined().contains("isn't on this Mac"))
        let without = SetupCopy.SavedPC.windowsAppPlan(brewPresent: false)
        #expect(without.count == 1)
        #expect(!without[0].contains("Homebrew"))
        #expect(without[0].contains("\(Dependency.windowsAppDownloadMB) MB"))
    }

    @Test("The Windows-App-is-open refusal is WindowsAppBookmarks' own, then the button")
    func appOpen() {
        #expect(SetupCopy.SavedPC.appOpen.hasPrefix(WindowsAppBookmarks.Copy.quitFirst))
        #expect(SetupCopy.SavedPC.appOpen.hasSuffix("press **Check Again**."))
    }
}

// MARK: - Armie

@Suite("Armie speaks only while there is nothing to do, and only says true things")
struct ArmieLines {
    private static var every: [String] { SetupCopy.Armie.Moment.all.map(SetupCopy.Armie.line) }

    @Test("Every install stage has a line of its own")
    func everyStage() {
        var seen: Set<String> = []
        for stage in CreateStage.allCases {
            let line = SetupCopy.Armie.line(.installing(stage))
            #expect(!line.trimmingCharacters(in: .whitespaces).isEmpty, "\(stage) has no line")
            #expect(seen.insert(line).inserted, "\(stage) repeats another stage's line")
        }
        // One per install stage, plus UTM's install, the empty state, a VM starting and the end.
        #expect(SetupCopy.Armie.Moment.all.count == CreateStage.allCases.count + 4)
        #expect(Set(SetupCopy.Armie.Moment.all).count == SetupCopy.Armie.Moment.all.count)
    }

    @Test("No line exclaims, and none asks")
    func deadpan() {
        for line in Self.every + [SetupCopy.Armie.bRetire] {
            #expect(!line.contains("!"), "\(line)")
            #expect(!line.contains("?"), "\(line)")
        }
    }

    /// Clippy's actual crime was guessing what you were doing and offering to help with it.
    @Test("No line guesses what the person wants, offers help, or fills silence")
    func noClippy() {
        for line in Self.every {
            let lower = line.lowercased()
            for phrase in ["looks like you", "you want", "did you know", "can i help", "let me help", "fun fact", "tip:"] {
                #expect(!lower.contains(phrase), "\(line)")
            }
            // Nothing cute near a credential.
            #expect(!lower.contains("password"), "\(line)")
        }
    }

    @Test("The two lines from the spec's examples are his, word for word")
    func specExamples() {
        #expect(SetupCopy.Armie.line(.installing(.copy)) == "Copying files. There are a lot of them. I'll be here.")
        #expect(SetupCopy.Armie.line(.installing(.devices))
                == "Windows is deciding what kind of computer it lives in. It'll be a minute.")
    }

    @Test("He follows a running install stage by stage")
    func followsTheJob() {
        for stage in CreateStage.allCases {
            #expect(SetupCopy.Armie.line(for: testState(stage: stage)) == SetupCopy.Armie.line(.installing(stage)))
        }
        // A stall rule that applies and has found nothing wrong is not a warning.
        var writing = testState(stage: .copy)
        writing.stalled = .writing
        #expect(SetupCopy.Armie.line(for: writing) != nil)
    }

    @Test("He goes quiet the moment something goes wrong, or the job ends")
    func quietOnAnError() {
        var failed = testState(stage: .devices, outcome: .failed)
        failed.failure = CreateFailure(code: "E_INSTALL_TIMEOUT", title: "Windows didn't finish installing", detail: "")
        #expect(SetupCopy.Armie.line(for: failed) == nil)

        // A failure recorded before the outcome is written still silences him.
        var failing = testState(stage: .devices)
        failing.failure = failed.failure
        #expect(SetupCopy.Armie.line(for: failing) == nil)

        for stall in [StallState.quiet, .busy] {
            var stalled = testState(stage: .copy)
            stalled.stalled = stall
            #expect(SetupCopy.Armie.line(for: stalled) == nil, "\(stall)")
        }
        #expect(SetupCopy.Armie.line(for: testState(stage: .finish, outcome: .done)) == nil)
        #expect(SetupCopy.Armie.line(for: testState(stage: .boot, outcome: .cancelled)) == nil)
    }

    /// A running job with these messages, raised in this order.
    private static func running(_ stage: CreateStage, _ codes: String...) -> CreateJobState {
        var job = testState(stage: stage)
        job.messages = codes.map { CreateMessage(code: $0, text: "…", at: testMoment()) }
        job.shown = codes
        return job
    }

    /// CreateJobRun raises E_BOOT_NO_PROMPT as a message and carries on, so nothing has failed or
    /// stalled — and "if it asks for a key press, it gets one" beside it would be untrue.
    @Test("He goes quiet when the installer's prompt never appeared, though the job carries on")
    func quietOnBootNoPrompt() {
        #expect(InstallAlert.bootNoPrompt.rawValue == "E_BOOT_NO_PROMPT")
        #expect(SetupCopy.Armie.line(for: Self.running(.boot)) != nil)
        #expect(SetupCopy.Armie.line(for: Self.running(.boot, "E_BOOT_NO_PROMPT")) == nil)
        // The message stays in the progress list, so he doesn't come back once Setup starts copying.
        #expect(SetupCopy.Armie.line(for: Self.running(.copy, "E_BOOT_NO_PROMPT")) == nil)
    }

    /// The boxed warnings each say a promise about the password didn't hold. W_TIMEMACHINE is raised
    /// as the job starts and stays boxed for the whole install; W_AUTOLOGON_PLAINTEXT arrives in the
    /// finish stage, about a password in plain text.
    @Test("He says nothing beside a boxed warning about the password")
    func quietBesidePasswordWarnings() {
        #expect(SetupCopy.Armie.line(for: Self.running(.copy, "W_TIMEMACHINE")) == nil)
        #expect(SetupCopy.Armie.line(for: Self.running(.check, "W_TIMEMACHINE")) == nil)
        #expect(SetupCopy.Armie.line(for: Self.running(.finish, "W_AUTOLOGON_PLAINTEXT")) == nil)
        for code in CreateProgress.boxedCodes {
            #expect(SetupCopy.Armie.silences(code), "\(code)")
            for stage in CreateStage.allCases {
                #expect(SetupCopy.Armie.line(for: Self.running(stage, code)) == nil, "\(code) at \(stage)")
            }
        }
    }

    @Test("A stall keeps him quiet after the VM stirs again, since its note stays on screen")
    func quietAfterAStall() {
        for alert in [InstallAlert.stall, .stallBusy] {
            var cleared = Self.running(.copy, alert.rawValue)
            cleared.stalled = .writing
            #expect(SetupCopy.Armie.line(for: cleared) == nil, "\(alert)")
        }
    }

    /// The finish stage's warnings each say something didn't go as it should (Remote Desktop off,
    /// the Guest Tools slow, a slow boot); preflight's cautions only describe the Mac.
    @Test("A warning that something went wrong silences him; a caution about the Mac doesn't")
    func warningsAndCautions() {
        for code in ["W_RDP_OFF", "W_GT_SLOW", "W_GT_EXIT", "W_BITLOCKER_ON", "W_SLOW_BOOT", "W_UTM_RESTART_OWED",
                     "W_ISO_UNTESTED", "W_STALL", "W_STALL_BUSY", "E_SOMETHING_NEW", "W_SOMETHING_NEW", "X_UNSORTED"] {
            #expect(SetupCopy.Armie.silences(code), "\(code)")
        }
        for code in SetupCopy.Armie.cautions {
            #expect(code.hasPrefix("W_"), "\(code)")
            #expect(!SetupCopy.Armie.silences(code), "\(code)")
        }
        #expect(SetupCopy.Armie.line(for: Self.running(.copy, "W_BATTERY", "W_SPACE"))
                == SetupCopy.Armie.line(.installing(.copy)))
        #expect(SetupCopy.Armie.line(for: Self.running(.finish, "W_BATTERY", "W_RDP_OFF")) == nil)
    }

    /// Notes are the job saying what it did. N_NO_SERIAL, in particular, doesn't make the boot line
    /// untrue: Winbar answers the prompt through UTM's window instead.
    /// The N_ prefix isn't a promise that nothing went wrong. These four report a failure, and the
    /// first stays on screen for eight stages after it's raised.
    @Test("He goes quiet beside a note that reports a failure",
          arguments: ["N_PC_FAILED", "N_PC_APP_RUNNING", "N_RESUME_LATE", "N_KEPT_CONSOLE"])
    func failureNotesSilenceHim(code: String) {
        #expect(SetupCopy.Armie.silences(code))
        #expect(SetupCopy.Armie.line(for: Self.running(.boot, code)) == nil)
    }

    @Test("A note doesn't silence him")
    func notesAreFine() {
        let job = Self.running(.boot, "N_OTHER_VMS", "N_PW_FILEVAULT_OFF", "N_PC_SAVED", "N_NO_SERIAL")
        #expect(SetupCopy.Armie.line(for: job) == SetupCopy.Armie.line(.installing(.boot)))
    }

    /// Setup's wait is the guest agent, then — only when Windows signs itself in — the desktop. The
    /// line says both halves, and nothing about what "up" means.
    @Test("A starting VM's line says what the wait waits for, and goes when the wait runs out")
    func startingWindows() {
        let line = SetupCopy.Armie.line(.startingWindows)
        #expect(line.contains("guest agent"))
        #expect(line.contains("desktop"))
        #expect(!line.contains("counts as up"))
        #expect(SetupCopy.Armie.startingLine(timedOut: false) == line)
        #expect(SetupCopy.Armie.startingLine(timedOut: true) == nil)
    }

    @Test("The finish stage's line is true from its first step to its last")
    func finishLine() {
        let line = SetupCopy.Armie.line(.installing(.finish))
        #expect(!line.contains("Next"))
        for step in ["checks it over", "shuts it down", "install discs out", "starts it again"] {
            #expect(line.contains(step), "\(step)")
        }
    }

    @Test("He says his done line only when the desktop actually appeared")
    func doneOnlyWhenConnected() {
        #expect(SetupCopy.Armie.doneLine(connected: true) == SetupCopy.Armie.line(.done))
        #expect(SetupCopy.Armie.doneLine(connected: false) == nil)
        #expect(SetupCopy.Armie.doneLine(connected: nil) == nil)
    }
}
