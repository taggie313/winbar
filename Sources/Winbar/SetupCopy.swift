import Foundation

// The setup wizard's copy deck: every sentence the Set Up Winbar window shows, and the sentences
// `winbar setup` shares with it, written once. Both front-ends read this; neither keeps a second
// copy of a string. It is the same arrangement `CreateCopy` has for `winbar create`, and it borrows
// from that deck (and from `DependencyCopy`, `UTMFirstUse` and `WindowsAppBookmarks.Copy`) rather
// than restating anything they already say.
//
// Three kinds of string live here, and they are kept apart on purpose:
//
// - **Shared with Terminal.** `waitingForWindows`, `agentNotYet`, `Tune.askingWindows`, `Tune.still`,
//   `Certificate.approval`, `SavedPC.why`, `BitLocker` and `Finish.oneRestart` are printed by
//   `winbar setup` exactly as it printed them before they moved here. They are plain text, and the
//   window shows them as plain text too (`Text(verbatim:)`), names and all.
// - **The window's own words.** Markdown `String`s, the way `CreateCopy.fLicence` is, so the names of
//   buttons and menu items can be bold. None of them carries anything a person or a VM chose.
// - **The window's sentences with a chosen value in them**: a VM's name, a user name, a host name.
//   These are `AttributedString`s, built by `Filled`: the deck's words around the value are parsed
//   as Markdown and the value is appended as it is, so it is never parsed at all. A name is
//   anyone's text — `winlab01 *beta*` would lose its asterisks to italics, and a bracketed name
//   would become a live link in the sentence — and escaping it first isn't enough: Foundation's
//   parser turns anything shaped like an email address into a mailto: link after it has undone
//   the escapes (tried 2026-09-22), and a Microsoft account's user name is exactly that shape.
//   Being a different type is also what stops a view putting one of these through the parser.
//
// The spec's §2.3 is the source, with its critique's corrections and two measurements applied. Where
// this file says something different from the spec, the comment beside it says why; the rule is that
// the deck never carries a sentence known to be untrue, even one the spec wrote.

/// The Set Up Winbar window's words, step by step, plus the lines `winbar setup` prints too.
enum SetupCopy {
    // MARK: - Markdown, and the values that must stay out of it

    /// The deck's Markdown as the window shows it: inline syntax only, whitespace kept, which is
    /// the reading SwiftUI's `Text` gives `CreateCopy.fLicence`. The deck's words are constants the
    /// tests parse, so the plain-text fallback never runs; it is there so a typo can't be a crash.
    static func markdown(_ words: String) -> AttributedString {
        (try? AttributedString(markdown: words, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(words)
    }

    /// A sentence of the window's with a value someone chose in it, written as an ordinary string
    /// literal: the literal's own text is the deck's Markdown, and each `\(value)` is shown exactly
    /// as it is. Each stretch of the deck's words is parsed on its own, so none of the deck's
    /// markers reaches across a value, and nothing in a value can open or close one of them.
    struct Filled: ExpressibleByStringInterpolation {
        var text: AttributedString

        init(text: AttributedString) { self.text = text }
        init(stringLiteral words: String) { text = SetupCopy.markdown(words) }
        init(stringInterpolation: StringInterpolation) { text = stringInterpolation.text }

        struct StringInterpolation: StringInterpolationProtocol {
            var text = AttributedString()
            init(literalCapacity: Int, interpolationCount: Int) {}
            mutating func appendLiteral(_ words: String) { text += SetupCopy.markdown(words) }
            mutating func appendInterpolation(_ value: String) { text += AttributedString(value) }
        }

        /// So a long sentence can be written across lines, the way the rest of the deck is.
        static func + (lhs: Filled, rhs: Filled) -> Filled { Filled(text: lhs.text + rhs.text) }
    }

    private static func fill(_ sentence: Filled) -> AttributedString { sentence.text }

    // MARK: - The window

    static let winTitle = "Set Up Winbar"
    static let menuItem = "Set Up Winbar…"

    /// The step bar's labels, in the order of the spec's step table (welcome, look around, the VM,
    /// tune, the certificate, the saved PC, connect, finish).
    static let stepNames = ["Welcome", "Look around", "The VM", "Tune", "The certificate", "The saved PC",
                            "Connect", "Finish"]

    /// The step bar's own, shorter labels, in the same order: eight equal segments across the window's
    /// narrowest content leave each about 66 pt, which "The certificate" and "The saved PC" don't fit
    /// at a legible size. The header says the step's full name; VoiceOver reads it (`stepBarLabel`).
    static let stepBarNames = ["Welcome", "Look around", "The VM", "Tune", "Certificate", "Saved PC", "Connect", "Finish"]

    /// A step's name, from the list above.
    static func stepName(_ step: WizardStep) -> String {
        stepNames[WizardStep.allCases.firstIndex(of: step) ?? 0]
    }

    /// "Step 2 of 8", beside the step's name at the top of the window.
    static func stepCounter(_ step: WizardStep) -> String {
        "Step \((WizardStep.allCases.firstIndex(of: step) ?? 0) + 1) of \(WizardStep.allCases.count)"
    }

    /// What VoiceOver reads for the step bar, which is drawn as eight marks it can't read one by one.
    static func stepBarLabel(_ step: WizardStep) -> String { stepCounter(step) + ": " + stepName(step) }

    /// Steps 3 to 7, until each is built (the spec's commits 7 to 11). The window stops after step 2
    /// in this build rather than showing screens that do nothing, and says where the rest is done.
    /// Goes when step 3 arrives.
    ///
    /// It used to stop after step 1, and then it named `winbar create` too, and not "winbar setup does
    /// all of them": with no Windows VM, `winbar setup` stops ("UTM has no Windows VMs…") and never
    /// makes one. With step 2 built, the placeholder is only reached with a VM chosen and running, so it no longer
    /// sends anyone to **New Windows VM…**: step 2 makes one in place, and a second way would be a second
    /// window onto the same install. What's left is true of the VM the window just settled on: `winbar
    /// setup` tunes the VM Winbar's settings name, which is the one step 2 chose (or the install chose).
    static let notBuiltYet = "This window goes as far as the VM for now: the steps after it aren't built yet. Next, "
        + "**winbar setup** in Terminal tunes it, and **Connect** in Winbar's menu opens it."
    /// The placeholder's way out. The window has done all it can in this build, so it puts itself away.
    static let bClose = CreateCopy.bClose

    // Buttons more than one step uses. The ones `create`'s window already has are its own strings, so a
    // button that reads the same in both windows is one string.
    static let bBack = "Back"
    static let bTryAgain = CreateCopy.bTryAgain
    static let bSkip = "Skip"
    static let bDone = CreateCopy.bDone
    /// Re-asks whatever a step is waiting on: step 5 while Windows App is open, step 7 while
    /// Reconfigure refuses to restart UTM.
    static let bCheckAgain = "Check Again"

    /// Said while Winbar waits for a VM it just started, in both front-ends: `winbar setup` notes it
    /// before its three-minute wait, and the window shows it on step 2 after **Start It**.
    static let waitingForWindows = "Waiting for Windows and its guest agent (up to three minutes)…"
    /// What follows it when the three minutes pass with no answer, in both front-ends.
    static let agentNotYet = "The guest agent didn't answer yet."

    /// What `winbar setup` prints between someone's yes and the fix, for the one fix that raises a
    /// macOS prompt of its own. H7 used to print this from inside its `apply`, which a window can't
    /// see; now the terminal prints it here and the window shows the same sentence above its button.
    static func beforeFix(_ id: String) -> String? {
        id == "H7" ? Certificate.approval : nil
    }

    // MARK: - Step 0: Welcome

    enum Welcome {
        /// Under Winbar's mark, as the welcome's opening. The spec's heading, "Set up Winbar", is gone:
        /// the window's title bar says Set Up Winbar, and the header says Welcome, so a third heading
        /// said the window's name twice.
        static let lead = "Winbar runs Windows 11 in a virtual machine on this Mac and connects to it over Remote Desktop."

        /// What the welcome promises, for a window whose last built step is `lastBuilt`. Pure.
        ///
        /// The spec's welcome ("This window does the whole thing … You don't need Terminal") is true
        /// only once all eight steps exist, so it is what a window built through the finish says. Until
        /// then the welcome says what this window does now and where the rest happens, because the
        /// first run opens it for every new Mac, and two screens later it would otherwise contradict
        /// itself (`notBuiltYet`).
        static func body(lastBuilt: WizardStep) -> [String] {
            if lastBuilt == .finish { return whole }
            return lastBuilt >= .vm ? throughVM : soFar
        }

        /// The spec's, for the finished window. The spec said "three or four times". Four is the most
        /// there are (Automation, the certificate, Accessibility, Local Network) and a Mac that already
        /// answered some sees fewer, so "up to four" is the version that is true on every Mac.
        private static let whole = [
            "This window does the whole thing: it checks what's here, makes or adopts a VM, tunes Windows, and "
                + "connects once to prove it works. You don't need Terminal.",
            "About five minutes. Installing Windows, if you need it, adds about ten more on a fast Mac.",
            "macOS may ask you to approve opening or updating apps, control of UTM, certificate trust, Accessibility "
                + "and Local Network access. Winbar explains each request before it appears.",
        ]

        /// While the window stops after looking around: it checks, installs UTM, and gets UTM to answer.
        ///
        /// It says what this build does and nothing about what else will do the rest. "winbar setup in
        /// Terminal does the rest" was untrue for the very Mac this window is for: with no Windows VM,
        /// `winbar setup` stops ("UTM has no Windows VMs…") and never makes one. Who makes a VM, tunes it
        /// and connects is said where the window stops (`notBuiltYet`), with a button for the first.
        private static let soFar = [
            "For now this window only looks around: it checks what's here, installs UTM if it's missing and makes "
                + "sure UTM answers, then stops and says what does the rest.",
            "A minute or two, plus UTM's download if it isn't installed yet (about \(Dependency.utmDownloadMB) MB).",
            // "A question or two", not "one question": which two, and when.
            // - Automation, "Winbar wants access to control UTM", on the first Apple Event to UTM, on
            //   every route; none on a Mac that already allowed it.
            // - Gatekeeper's "downloaded from the internet" question, for any copy of UTM that carries
            //   the quarantine mark and hasn't been opened yet. It isn't the Homebrew route's alone: a
            //   UTM downloaded with a browser — the commonest way to get it — carries the same mark as
            //   Homebrew's (which Winbar deliberately doesn't strip: `Homebrew.installCommand`). And
            //   `settleUTM` opens UTM itself with `UTM.open()`, so the first launch of a marked copy can
            //   ask whether to open it — before UTM can be asked anything. Winbar's own download leaves
            //   no mark (URLSession, and no LSFileQuarantineEnabled), so that route can only raise the
            //   first; "may" covers it.
            // Both are said before they appear: step 1's card predicts the second whenever UTM carries
            // the mark (`askInstruction(host:quarantined:)`), and an update's plan predicts both, since
            // Homebrew quits UTM and opens the new, marked copy again (`updateMayAsk`).
            // - An update through Homebrew can raise a third, App Management, as it replaces UTM's
            //   bundle; predicted from Homebrew's source, not seen (`updateMayAsk` says where). The
            //   update's plan says it before the button, so "before it appears" holds for it too; the
            //   count says so, so that "a question or two" isn't broken on that route.
            "macOS may ask a question or two here: whether Winbar may control UTM and, if UTM hasn't been opened since "
                + "it was downloaded, whether to open it. An update through Homebrew can add a third, about modifying "
                + "apps. Winbar says what each one is before it appears.",
        ]

        /// While the window stops after the VM: it checks, installs UTM, gets UTM to answer, and makes or
        /// adopts a VM. The questions are step 1's, and only step 1's: choosing or starting a VM asks UTM,
        /// which step 1 already has an answer from, and an install the window starts leaves the one
        /// macOS question it could raise — Local Network — to set-up (`CreatePlan.inSetupWindow`).
        private static let throughVM = [
            "For now this window does the first part: it checks what's here, installs UTM if it's missing, and makes "
                + "or adopts a Windows VM, then stops and says what does the rest.",
            "A minute or two, plus UTM's download if it isn't installed yet (about \(Dependency.utmDownloadMB) MB). "
                + "Installing Windows, if you need it, adds about ten more on a fast Mac.",
            soFar[2],
        ]

        static let bNotNow = "Not Now"
        static let bStart = "Start"
    }

    // MARK: - Step 1: Look around

    enum LookAround {
        static let rowUTM = "UTM"
        static let rowVMs = "Virtual machines"
        static let rowWindowsApp = "Windows App"

        /// Said once UTM is installed and before Winbar opens it: a heading, what the button does, the
        /// one thing the person may have to do, set apart, and an aside. `UTMFirstUse.expectAPrompt`
        /// is the terminal's version; it isn't reused because it asks the person to open UTM
        /// themselves, and here the window does that for them (`UTM.open()`).
        ///
        /// The spec's version said flatly that macOS *will* ask. That is untrue for the person who
        /// lands here most often after the first run: someone who allowed it long ago and whose UTM
        /// is simply closed. A snapshot never asks a closed UTM anything, and with UTM closed macOS
        /// can't say whether it was allowed (`Automation.consent` reads "decided" for any app that
        /// isn't running), so the window can't tell the two apart before the button is pressed. So
        /// the prompt is predicted, as §2.2 requires, as an "if" and as something that happens once.
        static let askHeading = "Next, a question for UTM"
        static let askBody = "**Open UTM and Ask** opens UTM and asks it something small. That's how Winbar will start, "
            + "stop and reconfigure the VM."
        ///
        /// `quarantined`: UTM carries macOS's "downloaded from the internet" mark, which a browser's
        /// download and Homebrew's both leave (Winbar's own download doesn't).
        /// **Open UTM and Ask** opens UTM itself, and the first launch of a marked copy can ask whether
        /// to open it at all, before the Automation question; so that one is predicted too, first,
        /// since it comes first. A copy that was opened before doesn't ask again, hence "if".
        static func askInstruction(host: String = "Winbar", quarantined: Bool = false) -> String {
            let control = "If macOS asks whether \(host) may control UTM, choose **Allow**."
            guard quarantined else { return control }
            return "If macOS asks whether to open UTM, an app downloaded from the internet, choose **Open**. "
                + "If it asks whether \(host) may control UTM, choose **Allow**."
        }
        /// Under the prediction, for someone who wants the detail. `quarantined` as for `askInstruction`:
        /// that prediction names two questions for a marked copy, so the aside speaks of both — in the
        /// singular it read as though there were one. Pure.
        static func askAside(quarantined: Bool = false) -> String {
            guard quarantined else {
                return "It asks only the first time. Its prompt can open behind this window, and it waits as long as it "
                    + "takes, so a Mac left locked never gets past it. If you've allowed it before, UTM just answers."
            }
            return "macOS asks each only once. Its prompts can open behind this window, and they wait as long as it "
                + "takes, so a Mac left locked never gets past them. If you've answered both before, UTM just answers."
        }
        static let bOpenUTMAndAsk = "Open UTM and Ask"
        /// Step 1's own way on, once the three rows are done.
        static let bContinue = "Continue"
        /// For a refused Automation grant: the same page the menu's **Open Automation Settings…** opens.
        static let bOpenAutomationSettings = "Open Automation Settings…"

        /// The install button: the yes to `DependencyCopy.question`, which the card ends on, in a
        /// button's words. nil for a plan the window can't carry out (advice only, or the App Store,
        /// which is step 5's).
        static func bInstall(_ dependency: Dependency, _ plan: InstallPlan) -> String? {
            switch plan {
            case .brew: return "Ask Homebrew to Install \(dependency.name)"
            case .brewUpgrade: return "Ask Homebrew to Update \(dependency.name)"
            case .download: return "Download and Install \(dependency.name)"
            case .appStore, .manual: return nil
            }
        }

        /// The Virtual machines row's detail once UTM has listed them: every VM it has, of any kind.
        /// The next step says which of them Winbar can look after.
        static func vmCount(_ count: Int) -> String {
            count == 0 ? "None in UTM yet" : "\(count) in UTM"
        }

        /// While Winbar waits for UTM's first answer: the card's heading, over `Working.whereToLook`.
        static let settleHeading = "Waiting for UTM to answer"

        /// Before `Working.whereToLook` on that card when UTM carries the mark. **Open UTM and Ask**
        /// (and **Try Again**) open UTM themselves, so for a copy never opened before, Gatekeeper's
        /// "downloaded from the internet" question is the first thing that can appear during the wait —
        /// and UTM can't answer anything until it's answered. The card named only the Automation prompt.
        static let settleOpen = "If macOS asks whether to open UTM, an app downloaded from the internet, choose **Open** there."

        /// utmctl said nothing after **Open UTM and Ask** or **Try Again**: the card's heading.
        static let silentHeading = "UTM's command-line tool hasn't answered"

        /// What to do about it, in the window. Not `UTMFirstUse.how`, which is the terminal's: the
        /// window has already opened UTM itself (`settleUTM` calls `UTM.open()`) and **Try Again**
        /// opens it again, so "open UTM from your Applications folder" asks for what's done; and when
        /// macOS already has an answer on file, no prompt is coming, so "look for the prompt, choose
        /// Allow" would be untrue. Each case says only its own truth, and ends on the button. Pure.
        static func silent(consent: Automation.Consent, host: String) -> String {
            switch consent {
            case .wouldPrompt, .unknown:
                return "Winbar opened UTM, and macOS is probably waiting for an answer to its prompt, "
                    + "\(Automation.promptWords(host: host)), which can be behind another window. Choose **Allow** there, "
                    + "then press **\(bTryAgain)**."
            case .decided:
                return "Winbar opened UTM, and macOS already has an answer on whether \(host) may control it, so no "
                    + "prompt is coming. Turn on UTM under \(host) in Privacy & Security → Automation, then press "
                    + "**\(bTryAgain)**."
            }
        }

        /// Beside the silent card when UTM carries the quarantine mark: what the mark is, and the one
        /// way it can be what Winbar is waiting on here.
        ///
        /// The terminal says the mark "isn't what a silent utmctl is waiting for" (`UTMFirstUse.how`),
        /// and there it's true: the person opens UTM themselves and answers macOS's "downloaded from
        /// the internet" question in front of them. The window opens UTM itself (`UTM.open()`), so that
        /// question can be sitting behind another window, unanswered, and then UTM isn't running to be
        /// asked anything. So the window doesn't rule it out; it says where to look.
        ///
        /// It doesn't say who left the mark. It used to say "as Homebrew leaves it", and it shows on the
        /// mark alone: a UTM downloaded with a browser, the commonest way to get it, carries the same
        /// mark, so a Mac with no Homebrew was told Homebrew had been there. And not "still": the mark
        /// stays after the first open (`Quarantine.isMarked` reads only that it's there).
        static let quarantineAside = "UTM carries macOS's “downloaded from the internet” mark. That's normal, but the "
            + "first time a marked copy opens, macOS may ask whether to open it, and that question can be behind "
            + "another window too: choose **Open** there."

        /// Windows App's row when it isn't installed, in a window whose last built step is `lastBuilt`.
        /// Nothing on step 1 acts on it (§2.3). Pure.
        ///
        /// The spec's sentence, "Winbar gets to that at the saved-PC step", is true only once the window
        /// has that step; a build that stops after looking around promised a step it doesn't have. Until
        /// then the row says what's true in any build: nothing needs Windows App before there's a VM to
        /// connect to, and `winbar setup` offers to install it (`Setup.run`, C1) — which is also where
        /// the placeholder sends a Mac that has a VM.
        static func windowsAppLater(lastBuilt: WizardStep) -> String {
            lastBuilt >= .savedPC
                ? "Windows App isn't installed. Winbar gets to that at the saved-PC step."
                : "Windows App isn't installed. It isn't needed until there's a VM to connect to; winbar setup offers "
                    + "to install it."
        }

        /// The UTM row while Winbar waits for UTM's first answer (**Open UTM and Ask**, **Try Again**).
        /// The runner relays `UTMFirstUse.settle`'s lines, which are the terminal's and say "this is
        /// where the permission prompt appears": untrue for someone who allowed it long ago, and the
        /// card under the rows already says what to do if a prompt does come. So the row says only
        /// what Winbar is doing, and how long it has waited once that's worth saying. Pure.
        static func asking(_ line: String?) -> String {
            // stillWaiting's own words around a number no wait reaches, so the two can't drift.
            let marker = 987_654_321
            let template = UTMFirstUse.stillWaiting(seconds: marker).components(separatedBy: String(marker))
            if let line, template.count == 2, line.hasPrefix(template[0]), line.hasSuffix(template[1]),
               let seconds = Int(line.dropFirst(template[0].count).dropLast(template[1].count)) {
                return "No answer yet after \(seconds) seconds…"
            }
            return "Asking UTM a question…"
        }

        /// Over UTM's install while it runs: Homebrew's output, or Winbar's own download lines, follow.
        /// An update (`InstallPlan.brewUpgrade`) replaces the copy that's there, and says so.
        static func installing(update: Bool) -> String { update ? "Updating UTM" : "Installing UTM" }

        /// Under the install card's bar while Winbar's own download runs.
        static func downloaded(done: Int, total: Int) -> String { "\(done) of \(total) MB" }

        /// Under an update's plan, in the window only. Homebrew quits a running UTM with an Apple Event
        /// (the cask's `uninstall quit:`), and one sent by a process Winbar started is Winbar's to be
        /// allowed, so on a Mac that never allowed it macOS may ask right then — before step 1 has
        /// predicted the prompt. Not measured, hence "may"; the terminal is a different host, so this
        /// isn't in the shared plan.
        ///
        /// And Homebrew opens the app it quit again once the new copy is in (`reopen_apps_after_upgrade`,
        /// cask/upgrade.rb: `open -b`), a copy that carries a fresh "downloaded from the internet" mark,
        /// so macOS may ask whether to open it — the second of the welcome's "question or two".
        ///
        /// Between the two, a third: App Management, which since macOS 13 is needed to change another
        /// app's bundle. Before `brew upgrade` moves the old UTM.app aside, Homebrew writes a test file
        /// into it on purpose, "to get macOS to prompt the user for permissions"
        /// (`Quarantine.app_management_permissions_granted?`, cask/quarantine.rb:241-250), called from
        /// `Moved#delete` as the old copy is backed up and removed (cask/artifact/moved.rb:250) and again
        /// from `Moved#move` as the new one goes in (moved.rb:153). cask/staged.rb:38-45 is the same
        /// check for a cask's own `set_ownership`, which UTM's cask never calls. As with the Apple Event
        /// above, a process Winbar started asks in Winbar's name. The words quoted are TCC's own
        /// (REQUEST_ACCESS_SERVICE_kTCCServiceSystemPolicyAppBundles in TCC.framework's
        /// Localizable.loctable). If it isn't allowed, `delete` removes the whole bundle rather than
        /// its contents (moved.rb:258-259) and the new copy is moved into the empty place — "Homebrew will
        /// delete and reinstall the app", in its own warning, which adds that notification settings or
        /// the app's place in the Dock may be lost (quarantine.rb:296-302). So the update still happens,
        /// and the sentence says so rather than making Allow sound like the only way through.
        ///
        /// All of that was READ in Homebrew 7.0.6's source (2026-09-22), not OBSERVED: a live run needs
        /// an old UTM and a real `brew upgrade` run by Winbar.app. Nor is it known whether macOS shows
        /// its Allow prompt and waits, or refuses at once and only notifies ("… was prevented from
        /// modifying apps", the table's other string) — the sentence is true either way. It is on
        /// WAVE3-BRIEF's list of live checks.
        static func updateMayAsk(host: String) -> String {
            "If UTM is open and \(host) has never been allowed to control it, macOS may ask as Homebrew quits it "
                + "(\(Automation.promptWords(host: host))): choose Allow. As Homebrew replaces UTM, macOS may ask "
                + "whether \(host) may modify apps (\(appManagementPromptWords(host: host))): choose Allow. If it isn't "
                + "allowed, Homebrew deletes the old copy and installs the new one in its place instead. When Homebrew "
                + "opens the new copy again, macOS may also ask whether to open it, since it was downloaded from the "
                + "internet: choose Open."
        }

        /// The App Management prompt's first line, as TCC.framework's Localizable.loctable has it
        /// (REQUEST_ACCESS_SERVICE_kTCCServiceSystemPolicyAppBundles, read on macOS 27), with the host put in.
        static func appManagementPromptWords(host: String) -> String {
            String(format: "“%@” would like to modify apps on your Mac", host)
        }
        /// Over utmctl's own error, which the row shows. Every start and stop goes through it, so
        /// nothing past this step can work until it answers.
        static let utmFailedHeading = "UTM's command-line tool answered with an error"
        static let utmFailed = "Every start and stop Winbar makes goes through it, so nothing after this step can work "
            + "until it answers. **\(bTryAgain)** asks it again."

        /// The card's heading when UTM needs installing, updating or replacing; the row above it has only
        /// its mark, so this is said once. Pure.
        static func needsHeading(_ state: DependencyState) -> String {
            switch state {
            case .missing, .installed: return "UTM isn't installed"
            case .tooOld(let version, _): return "UTM \(version) is too old for Winbar"
            case .wrongSignature: return "This isn't the UTM Winbar expects"
            }
        }

        /// What follows the heading before the plan: what UTM is, what Winbar needs, or what's wrong
        /// with the copy that's there. Pure.
        static func needsLead(_ state: DependencyState) -> String? {
            switch state {
            case .missing: return Dependency.utm.what
            case .tooOld(_, let minimum): return "Winbar needs UTM \(minimum) or later."
            case .wrongSignature(let detail): return detail
            case .installed: return nil
            }
        }

        /// The install plan's paragraphs in the window. Where Winbar can't install UTM itself (a copy
        /// signed by someone else, or too old and not Homebrew's to update) the shared text ends in
        /// Terminal commands; here it says what to do with the Finder and this window instead.
        static func plan(_ plan: InstallPlan, state: DependencyState) -> [String] {
            guard case .manual = plan else { return DependencyCopy.plan(.utm, plan) }
            switch state {
            case .wrongSignature:
                return ["Winbar won't replace an app that's already installed. Move that copy of UTM to the Trash, "
                        + "then choose Check Again: Winbar then offers to install UTM from \(Dependency.utm.vendor)."]
            case .tooOld:
                return ["Update UTM the way you installed it — its own Check for Updates, the Mac App Store, or a newer "
                        + "copy from getutm.app — then choose Check Again."]
            case .missing, .installed:
                return DependencyCopy.plan(.utm, plan)
            }
        }

        /// A Homebrew failure's detail in the window: its "try it again yourself: brew …" is the Try
        /// Again button under it.
        static func forWindow(_ detail: String) -> String {
            detail.replacingOccurrences(of: #"(Try it again yourself|Run it yourself and watch what it says): .*$"#,
                                        with: "Choose Try Again below. If it keeps failing, UTM's own download at "
                                            + "getutm.app works too.", options: .regularExpression)
        }

        /// The silent UTM row: how long it was asked for, since the card says what that means.
        static func silentRow(seconds: Int) -> String { "No answer in \(seconds) seconds" }

        /// Automation refused, in the window: where the switch is, and the two buttons under it. The
        /// recipe's words (`Automation.deniedError`) end on a tccutil command for a terminal.
        static func denied(host: String) -> String {
            "Turn on UTM under \(host) in Privacy & Security → Automation (**\(bOpenAutomationSettings)** goes there), "
                + "then press **\(bTryAgain)**."
        }
    }

    // MARK: - Step 2: The VM

    enum VM {
        static let noneHeading = "No Windows VM yet"
        /// The spec had the ISO at "about 5 GB". It isn't: Microsoft's 25H2 English Arm64 ISO measured
        /// 7,994,415,104 bytes on 2026-09-22, and `ISOProblem.unreadable` already tells people "about
        /// 8 GB". One size, and the right one.
        static let noneBody = [
            "UTM has no Windows VM. Winbar can make one and install Windows 11 into it with no clicking — the parts "
                + "you'd otherwise do by hand in UTM's wizard, Windows Setup and the out-of-box questions.",
            "You need Microsoft's Windows 11 Arm64 ISO, about 8 GB. Winbar's next screen has the link.",
        ]
        static let bMakeOne = "Make One"
        static let bMakeNew = "Make a New One"
        static let bChooseAnother = "Choose Another VM"
        static let notKnownWindows = "Winbar supports Windows guests. This VM doesn't have a Windows icon; if it runs Linux or another system, make a new Windows VM instead."

        static let oneHeading = "One Windows VM"
        /// `windows` is `VMInfo.isWindows`. It comes from the icon UTM shows, and the candidates fall back
        /// to every QEMU VM when none has a Windows icon — so the one VM on offer may not say it's
        /// Windows, and the sentence mustn't claim it does.
        static func oneBody(_ name: String, windows: Bool) -> AttributedString {
            fill((windows ? "UTM has one Windows VM: “\(name)”." : "UTM has one virtual machine: “\(name)”.")
                 + " If you choose Use, Winbar will look after it — its settings, Connect, and the menu bar item will all mean this one.")
        }
        /// A button's title, and an `AttributedString` like every other string with a name in it:
        /// the view gives it to `Button(action:label:)` as a `Text`.
        static func bUse(_ name: String) -> AttributedString { fill("Use “\(name)”") }

        static let severalHeading = "Which VM?"
        static func severalBody(count: Int) -> String {
            "UTM has \(count) virtual machines. Which Windows VM should Winbar look after?"
        }
        static let bUseThisOne = "Use This One"

        static func stopped(_ name: String) -> AttributedString {
            fill("“\(name)” is stopped. Winbar needs Windows running to check and tune it.")
        }
        static let bStartIt = "Start It"

        // The spec's step 2 has no words for the screens below; each is a state the step can be in
        // that the spec's four don't cover, and each card opens on a heading, as every card does.

        /// Over "“Windows 11” is stopped…". No name in it: a heading is plain text the view shows as
        /// it is, and the sentence under it names the VM.
        static let stoppedHeading = "Windows isn't running"
        static func startingHeading(_ name: String) -> String { "Starting “\(name)”…" }

        /// Why an earlier choice no longer counts, above the choice (`SetupFlow.PreviousChoice`). The
        /// first is `winbar setup`'s own sentence, with the reason it matters.
        static func previous(_ previous: SetupFlow.PreviousChoice) -> AttributedString {
            switch previous {
            case .gone(let name):
                return fill("UTM no longer has a VM named “\(name)”, the one Winbar was looking after.")
            case .notQEMU(let name):
                return fill("“\(name)” uses UTM's Apple Virtualization backend, which Winbar can't manage.")
            }
        }

        /// Step 2 with nothing left to do: a VM is chosen and running. Reached by **Continue** from step
        /// 1 on a Mac that has one already, by **Back** from step 3, and by **Close** on an install that
        /// ended with problems after it had chosen its VM.
        static let readyHeading = "The VM is running"
        static func ready(_ name: String) -> AttributedString {
            fill("Winbar looks after “\(name)”: its settings, Connect and the menu bar item all mean this one.")
        }

        /// An install is running that step 2 isn't showing: the New Windows VM window's, Terminal's, or
        /// this window's own after Winbar was quit and opened again. One install at a time, so the step
        /// offers to show that one rather than a second **Make One**.
        static let installingHeading = "Windows is being installed"
        static let installing = "A Windows install is running on this Mac, and Winbar does one at a time. "
            + "**\(bShowInstallProgress)** shows it here."
        /// The menu's **Show Install Progress…** without its dots: here it shows the install in place,
        /// rather than opening a window that asks for more.
        static let bShowInstallProgress = "Show Install Progress"

        /// Between an install that ended well and step 3: the Mac is read again first, since a new VM
        /// exists now and the install chose it.
        static let afterInstallHeading = "Windows is installed"
        static let afterInstall = "Looking at the new VM…"
    }

    // MARK: - Step 3: Tune

    enum Tune {
        static func choiceLabel(_ flag: String) -> String {
            switch flag {
            case "--autologon": return CreateCopy.label(.autologon)
            case "--remote-desktop": return CreateCopy.label(.remoteDesktop)
            case "--winbar-tuning": return CreateCopy.label(.winbarTuning)
            default: return flag
            }
        }
        static func detail(_ row: SetupFlow.Row, keptBitLocker: Bool) -> String {
            row.id == "G9" && keptBitLocker && row.kind != .ok ? "BitLocker is kept on by choice." : row.detail
        }
        static func how(_ id: String, _ text: String) -> String {
            id == "H6" ? text.replacingOccurrences(of: "Terminal has Full Disk Access", with: "Winbar has Full Disk Access") : text
        }
        static let heading = "Tuning Windows"
        static let body = "Verified means Winbar checked the current setting and it matches the recipe. "
            + "The Windows installer may already have applied it. Any remaining changes need your approval."

        static func status(_ status: SetupTuneStatus) -> String {
            switch status {
            case .verified: return "Verified"
            case .pendingRestart: return "Pending restart"
            case .skipped: return "Skipped"
            case .needsAttention: return "Needs attention"
            case .information: return "Information"
            case .checking: return "Checking…"
            case .applying: return "Applying…"
            case .notChecked: return "Not checked"
            }
        }

        /// Said under the counts when something waits on the person, because those rows are drawn first
        /// and a count alone ("1 needs attention") left them to find it — card 12 of 15, below the fold.
        static func attentionPointer(_ counts: [SetupTuneStatus: Int]) -> String? {
            guard let count = counts[.needsAttention], count > 0 else { return nil }
            return count == 1 ? "One setting needs you. It's first below."
                : "\(count) settings need you. They're first below."
        }

        /// A recipe sentence without its check codes: "Remote Desktop is on (G6)" reads as "Remote
        /// Desktop is on" in the window, which names rows by title. The CLI keeps the codes.
        static func plain(_ text: String) -> String {
            text.replacingOccurrences(of: #" \((?:[GHC][0-9]+(?:, )?)+\)"#, with: "", options: .regularExpression)
        }

        static func summary(_ counts: [SetupTuneStatus: Int]) -> String {
            SetupTuneStatus.allCases.compactMap { status in
                guard let count = counts[status], count > 0 else { return nil }
                let label: String
                switch status {
                case .verified: label = "verified"
                case .pendingRestart: label = "pending restart"
                case .skipped: label = "skipped"
                case .needsAttention: label = count == 1 ? "needs attention" : "need attention"
                case .information: label = count == 1 ? "information item" : "information items"
                case .checking: label = "being checked"
                case .applying: label = "being applied"
                case .notChecked: label = "not checked"
                }
                return "\(count) \(label)"
            }.joined(separator: " · ")
        }

        /// The guest survey's progress line. It used to be a literal inside `Context.surveyGuest`,
        /// behind a check for a terminal; now `Context.progress` carries it, and the terminal's sink
        /// still prints it only to a terminal.
        static let askingWindows = "Asking Windows (this takes a few seconds)…"

        /// A manual step re-read after **Done** that still isn't done, in `Setup.walk`'s words.
        static func still(_ detail: String) -> String { "still: \(detail)" }

        static let bFix = "Fix"
        static let bOpen = "Open"
        static let bFixEverything = "Fix Everything"

        /// Under H3 and H4, which are staged into `Context.pending` here and applied at the end.
        static func stagedNote(vm: String) -> AttributedString { fill("Not applied yet. This change is saved for the restart of “\(vm)” at the end of setup.") }
    }

    // MARK: - BitLocker (G9), in the words `winbar setup` has always used

    /// G9's offer, lifted out of `Setup.offerDecryption` word for word so the window's step 3 can show
    /// the same two branches — an encrypted volume and an unencrypted one — without a second copy.
    /// Pure: where the disk is, and whether those places are encrypted, are passed in.
    enum BitLocker {
        struct Offer: Equatable {
            var explanation: String
            var question: String
            var defaultYes: Bool
        }

        /// The two clauses of the explanation that depend on the front-end: how to say no, and how
        /// BitLocker stays on. Everything else in the offer is the same words in both.
        struct Answers: Equatable, Sendable {
            /// After "its disk would be unencrypted there:".
            var decline: String
            /// The encrypted branch's last sentence.
            var keep: String

            /// `winbar setup`'s, as it has always printed them.
            static let terminal = Answers(decline: "answer n", keep: "(--keep-bitlocker keeps it on.)")
            /// The window's. Its **No** writes `Config.keepBitLocker` for the VM (spec §2.3 step 3), as
            /// the terminal's n does, and that setting is what stops G9 being offered again, so that is
            /// what the sentence says. The terminal's flag would be noise here: the window is for
            /// people who never open Terminal, and its No already does what the flag does.
            static let window = Answers(decline: "choose No",
                                        keep: "Choosing No keeps it on, and Winbar won't ask again for this VM.")
        }
        static let bNo = "No"

        static let decryptingInBackground = "Windows decrypts in the background and carries on across restarts."

        /// `places` is every volume the VM's disks are on (the startup disk when nothing says), and
        /// `unprotected` the ones among them that aren't encrypted at rest. `imagesKnown` is false when
        /// the running QEMU didn't say where the disks are, so the startup disk is only a guess.
        static func offer(places: [Host.Storage], unprotected: [Host.Storage], imagesKnown: Bool,
                          answers: Answers = .terminal) -> Offer {
            let costs = "BitLocker costs I/O and demands its recovery key after any VM hardware change. \(answers.keep)"
            if unprotected.isEmpty {
                let location = !imagesKnown
                    ? "FileVault encrypts this Mac's startup disk, where UTM keeps VMs unless told otherwise. If this VM is "
                        + "stored somewhere else, such as an external drive, its disk would be unencrypted there: "
                        + "\(answers.decline)."
                    : "The VM's disk is on \(places.map(\.description).sorted().joined(separator: " and ")), which is encrypted "
                        + (places == [.startupDisk] ? "by FileVault." : "at rest.")
                return Offer(explanation: "Decrypting it: \(location) " + costs, question: "Decrypt C:?", defaultYes: true)
            }
            let what = unprotected.map { place in
                place == .startupDisk ? "this Mac's startup disk (FileVault is off)" : "\(place.description), which isn't encrypted"
            }.sorted().joined(separator: " and ")
            return Offer(explanation: "The VM's disk is on \(what), so decrypting C: would leave it unencrypted at rest. "
                             + "BitLocker still costs I/O and demands its recovery key after VM hardware changes.",
                         question: "Decrypt C: anyway?", defaultYes: false)
        }
    }

    // MARK: - Step 4: The certificate

    enum Certificate {
        static let heading = "Approve the connection certificate"

        static func result(_ phase: SetupCertificatePage.Phase) -> String {
            switch phase {
            case .needsApproval: return "Your turn: approve on this Mac"
            case .approving: return "Approval in progress"
            case .checking: return "Checking certificate trust"
            case .verified: return "Certificate verified"
            case .skipped: return "Approval skipped"
            case .attention: return "Approval not confirmed"
            }
        }
        static let bApprove = "Approve Certificate…"
        static let bApproveInstead = "Approve Instead…"
        static let bRetry = "Try Approval Again…"
        static let bSkip = "Skip for Now"
        static let instructions = "Choose Approve Certificate below. If macOS opens an approval dialog, approve it there. "
            + "If it asks for a password, use your Mac login password—not your Windows password."
        static let completion = "Then wait here. Winbar checks the result automatically. This step is complete only when "
            + "it says Certificate verified."
        static let waiting = "If a macOS approval dialog is open, approve it there; it may be behind another window. "
            + "If you already approved it, wait while Winbar checks the result. You don't need to click Approve again."
        static let checking = "No action is needed while Winbar checks. The result will appear here."
        static let verifiedNext = "This step is complete. Choose Continue to Windows App below."
        static let skippedDetail = "Certificate trust has not been verified. Windows App may show a certificate warning when you connect."
        static let skippedNext = "Choose Continue Without Approval to move on, or Approve Instead to do this now."
        static let skippedNoApproval = "Choose Continue Without Approval to move on, or Check Again to recheck the certificate."
        static let attentionNext = "This step is not complete. Check Again to recheck, try approval if available, or choose Skip for Now."
        static let stopped = "Winbar stopped waiting. This does not confirm approval or close any macOS dialog. "
            + "If you approved it there, choose Check Again."
        static let notVerified = "The approval request finished, but Winbar could not verify trust. "
            + "Choose Check Again; a finished request alone does not mean this step succeeded."

        static func next(_ phase: SetupCertificatePage.Phase, canApprove: Bool) -> String {
            switch phase {
            case .needsApproval: return completion
            case .approving: return completion
            case .checking: return checking
            case .verified: return verifiedNext
            case .skipped: return canApprove ? skippedNext : skippedNoApproval
            case .attention: return attentionNext
            }
        }

        /// "For your account on this Mac" rather than the spec's "on this Mac": the trust setting is
        /// written to the login keychain (`RDP.trustCertificate`), so it is this account's, and other
        /// accounts on the Mac aren't touched. The rest is `-p ssl -s <host>`: SSL only, one name.
        static func body(host: String) -> AttributedString {
            fill("Windows App checks the certificate the VM presents. Winbar made one for \(host), and trusting it for "
                 + "your account on this Mac removes the certificate warning — for that name only, for secure "
                 + "connections only, and for nothing else on the internet.")
        }

        /// The prediction, said before the prompt in both front-ends: `winbar setup` prints the first
        /// sentence after the person says yes (it is what H7's `apply` used to print), and the window
        /// shows all of it above **Trust It**.
        ///
        /// The spec promised "your Mac password, or Touch ID". Nobody has measured which appears when
        /// `security add-trusted-cert` runs from the app (its §4 experiment 4), and Touch ID isn't
        /// something a shelled-out tool opts into, so the deck promises only what is known: macOS asks,
        /// and the prompt is macOS's own. (Critique §4.)
        static let approval = "macOS will ask you to approve trusting it."
        static let approvalWindow = approval + " The prompt is macOS's own, and anything you type into it goes to macOS, "
            + "not to Winbar."

        static let bTrustIt = "Trust It"

        static let noCertificate = "Windows hasn't got a Remote Desktop certificate for this name yet. Go back to "
            + "**RDP certificate** on the Tune step and let Winbar make one."
    }

    /// Name the destination or the consequence of moving on. Enabling a generic Continue after
    /// Skip must not look like confirmation that the skipped work succeeded.
    static func journeyNext(_ step: WizardStep, facts: SetupFlow.Facts?) -> String {
        switch step {
        case .tune: return "Continue to Certificate"
        case .certificate:
            if let facts, facts.kind("H7") != .ok, facts.answers.leftAlone.contains("H7") {
                return "Continue Without Approval"
            }
            return "Continue to Windows App"
        case .savedPC: return "Continue to Connection Test"
        case .connect:
            return facts?.answers.connected == true ? "Continue to Finish" : "Continue Without Connecting"
        case .finish: return bDone
        default: return LookAround.bContinue
        }
    }

    // MARK: - Step 5: The saved PC

    enum SavedPC {
        static func missing(host: String?, user: String?) -> String {
            if host == nil { return "Winbar doesn't know the Windows PC's address yet. Check Again, or skip saving and enter the connection details in Windows App." }
            if user == nil { return "Winbar doesn't know the Windows account name yet. Sign in to Windows and Check Again, or skip saving and enter the account in Windows App." }
            return "The saved connection hasn't been checked yet. Check Again or skip saving it."
        }
        /// Neutral: the step is often only checking, or the PC is already saved, and "Saving…" said
        /// otherwise. What is happening right now is `busy(_:)`'s to say.
        static let heading = "The saved PC in Windows App"

        /// The card while the step's work runs, named for that work.
        static func busy(_ flight: SetupRunner.InFlight) -> String {
            switch flight.work {
            case .savePC: return "Saving the PC in Windows App…"
            case .installWindowsApp: return "Opening Windows App's page in the App Store…"
            case .guide: return "Opening Windows App…"
            case .recordDone: return "Checking Windows App for the saved PC again…"
            case .checkAgain: return "Checking Windows App for a saved PC…"
            default: return "Winbar is \(Working.doing(flight))…"
            }
        }
        static let lead = "Only a saved PC uses Windows App's stored password; a one-off connection asks every time."

        /// Said before the password is asked for, in both front-ends, because this is the moment the
        /// person decides. Both halves: where the password goes, and what handing it over costs.
        static func why(user: String) -> String {
            "Windows App needs the password for \(user) to save this PC, so Connect doesn't ask for it every time. "
                + WindowsAppBookmarks.Copy.passwordGoesToWindowsApp
                + " Winbar can't check the password without risking a failed sign-in, so the saved PC won't retry by "
                + "itself until you've connected once."
        }

        /// The field's label. A Microsoft account's user name is an email address, which Markdown would
        /// make a mailto: link — beside a password field of all places.
        static func passwordLabel(user: String) -> AttributedString { fill("Windows password for \(user)") }
        static let whereItGoes = "Where this password goes"
        static let bSaveIt = "Save It"

        /// Windows App is running, so a save could corrupt its database. The refusal is the one
        /// `WindowsAppBookmarks` already gives, then what the window's buttons are for.
        static let appOpen = WindowsAppBookmarks.Copy.quitFirst + " Once it has quit, press **Check Again**."
        static let bQuitWindowsApp = "Quit Windows App"

        /// Installing Windows App from the window. The window always uses the App Store (§3.6), so it
        /// can't reuse `DependencyCopy.plan(.windowsApp, .appStore)` as the spec asked: that opens with
        /// "Homebrew isn't on this Mac", which is untrue whenever Homebrew is, and says Microsoft ships
        /// Windows App only through the App Store, which the cask's own download from Microsoft
        /// contradicts. The reason for skipping Homebrew is read off the cask (2026-09-22): its artifact
        /// is a `pkg`, which Homebrew hands to `installer` through sudo, and sudo with no askpass helper
        /// wants a terminal to ask in. That settles half of the spec's §4 experiment 2; whether Homebrew
        /// would find an askpass from a GUI process is still unmeasured, and the window doesn't depend
        /// on it.
        static func windowsAppPlan(brewPresent: Bool) -> [String] {
            var lines: [String] = []
            if brewPresent {
                lines.append("Homebrew is on this Mac, but its Windows App is Microsoft's installer package, which "
                                 + "Homebrew installs with sudo — and sudo asks for your Mac password in a Terminal this "
                                 + "window doesn't have. So the window uses the App Store; winbar setup in Terminal "
                                 + "offers Homebrew.")
            }
            lines.append("An App Store app needs your Apple Account, so Winbar can't install it for you. Winbar can open "
                             + "Windows App's page; the Get button is yours to press. It's about "
                             + "\(Dependency.windowsAppDownloadMB) MB.")
            return lines
        }
    }

    // MARK: - Step 6: Connect

    enum Connecting {
        static let heading = "Connecting for the first time"

        /// The spec's version didn't say what **Allow Accessibility** does. C3's guide does two
        /// things: asks macOS for the grant, which puts Winbar in the list and shows the system prompt,
        /// and opens System Settings at Accessibility — which is what the person is looking at a
        /// second later, so the copy says so (critique §4). It also said Windows App "shows its
        /// chooser" without the grant; what the code does is fall back to a one-off .rdp connection,
        /// and Windows App never uses a saved password for those, so that is what it says.
        static let accessibility = "Winbar opens your saved PC in Windows App by pressing its tile, the way you would. "
            + "That needs Accessibility access for Winbar. **Allow Accessibility** asks macOS for it and opens System "
            + "Settings at Privacy & Security → Accessibility, where Winbar has to be switched on; then come back here. "
            + "Without it, Connect opens a one-off connection instead, and Windows App asks for your password every time."

        /// Local Network: the RDP readiness probe is Winbar's only local-network traffic. The spec also
        /// promised "Connect works either way". The code means it to — a denied probe reads as
        /// `.blocked`, which Connect goes ahead on — but telling a denial from a VM still booting is
        /// `RDP.looksDenied`'s heuristic, and the probe's own comment says it hasn't been seen live
        /// against a denied grant. If it misreads, Connect waits two minutes and gives up. Until that is
        /// measured, the deck says what the grant is for and nothing it can't stand behind.
        static let localNetwork = "macOS may ask whether Winbar can find and connect to devices on your local "
            + "network. Winbar uses that only to check whether the VM's Remote Desktop port is answering, which is how "
            + "it knows Windows is ready. The first time, Windows App may ask the same about itself; choose Allow, "
            + "or it can't reach the VM."
        /// Only on the recovery card's `.blocked` branch: the one case where the evidence points at the
        /// Local Network setting. Windows App asks for the same access separately, so both are named.
        static let networkRecovery = "In System Settings → Privacy & Security → Local Network, turn on Winbar, and "
            + "Windows App too: it needs the same access to reach the VM. Then choose **\(bTryAgain)**."

        /// The recovery card after **No, something's wrong** (or a Connect that failed): a heading, the
        /// steps in Markdown, and whether to offer closing setup for the menu's **Show Console Window…**.
        /// The view draws `recovery(_ diagnosis:)`, so the card is worked out from the facts alone.
        struct Recovery: Equatable {
            var heading: String
            var steps: [String]
            var offersConsole = false
            /// The card's own button, which its steps name in bold: filled, and the one Return presses.
            /// The footer's Continue Without Connecting held both once, so Return skipped the one step
            /// that proves the setup works; and the unchecked card said "Choose Check Again" above a
            /// button labelled Try Again, which only reopens Windows App without the port check it asked
            /// for. One value for the words and the button, so they can't disagree again.
            var retry: Retry = .tryAgain
        }

        /// **Try Again** redoes the connection (`SetupCommand.retryConnection`); **Check Again** reads the
        /// port again without opening anything, which is what a card with no reading needs first.
        enum Retry: Equatable {
            case tryAgain, checkAgain

            var title: String { self == .tryAgain ? bTryAgain : SetupCopy.bCheckAgain }
        }

        /// What to do, from what Winbar's own check of the VM's Remote Desktop port found, and nothing
        /// that check doesn't support. Winbar doesn't read Windows App's error, so the port is the
        /// evidence. In the live run that prompted this, Windows App's credentials prompt had merely
        /// timed out while the port answered, and the card said readiness hadn't been checked and sent
        /// the person to Local Network settings.
        ///
        /// - `.blocked`: macOS refused Winbar's connection, which is what Local Network privacy does:
        ///   the only branch that names that setting.
        /// - `.notReady`: nothing answered, so Windows is starting, restarting or updating: wait.
        /// - `.ready`: Windows answers, so what's left is Windows App and the sign-in.
        /// - nil: not read since the answer (the read after **No** was turned down); says how to read it.
        ///
        /// `console` only matters when nothing answered, where the card says how to watch Windows start:
        /// a headless VM (H5 ok) is watched through the menu's **Show Console Window…**, one with its
        /// console on (H5 fixable) in its UTM window, and with H5 unread the card says both as
        /// conditions, because someone whose VM was made headless outside this session reaches Connect
        /// with no reading (`SetupFlow.Console`). Close Setup comes with any advice that may need it.
        static func recovery(_ diagnosis: SetupFlow.Diagnosis) -> Recovery {
            recovery(diagnosis.readiness, savedPC: diagnosis.savedPC, console: diagnosis.console)
        }

        static func recovery(_ readiness: RDP.Readiness?, savedPC: Bool, console: SetupFlow.Console) -> Recovery {
            switch readiness {
            case .blocked?:
                return Recovery(heading: "macOS blocked Winbar's check of the VM",
                                steps: ["macOS refused Winbar's connection to the VM's Remote Desktop port, which is what "
                                            + "it does when Local Network access is off. So Winbar can't tell whether "
                                            + "Windows is ready.",
                                        networkRecovery])
            case .notReady?:
                return Recovery(heading: "Windows isn't answering Remote Desktop yet",
                                steps: ["Nothing answered on the VM's Remote Desktop port just now, so Windows is most "
                                            + "likely still starting, restarting or installing updates.",
                                        "Wait until Windows has finished and shows its sign-in screen or desktop, "
                                            + "then choose **\(bTryAgain)**.",
                                        watchWindows(console)],
                                offersConsole: console != .onScreen)
            case .ready?:
                return Recovery(heading: "Windows is answering; the sign-in is what's left",
                                steps: ["Windows answered on the VM's Remote Desktop port, so the problem is in Windows "
                                            + "App or the sign-in.",
                                        "If Windows App is asking for your password, finish signing in there. If its "
                                            + "prompt closed or timed out, choose **\(bTryAgain)** for a new one.",
                                        "Use your Windows account's password, not its PIN: Remote Desktop doesn't "
                                            + "accept a PIN.",
                                        savedPC
                                            ? "Windows App can store the credentials with the saved PC, so later "
                                                + "connections don't ask for them."
                                            : "A PC saved in Windows App can store the credentials, so later "
                                                + "connections don't ask; a one-off connection can't."])
            case nil:
                return Recovery(heading: "Check whether Windows is answering",
                                steps: ["Winbar hasn't looked at the VM's Remote Desktop port since this connection. "
                                            + "Choose **\(Retry.checkAgain.title)**, and Winbar then says what to try."],
                                retry: .checkAgain)
            }
        }

        static let bAllowAccessibility = "Allow Accessibility"
        static let bConnect = "Connect"

        static let waiting = "Waiting for Windows…"
        static func opening(host: String) -> AttributedString { fill("Opening \(host) in Windows App…") }

        static let didItAppearHeading = "Did the Windows desktop appear?"
        static let openedConnection = "Winbar opened a connection in Windows App. If the Windows desktop appeared, "
            + "the connection works. If the saved PC couldn't be opened, Windows App may ask for your password."
        static let afterRestart = "The VM restarted with your changes. Connect once more to check that its desktop still opens."
        static let recoverConsole = "This VM has no console screen. To see what Windows is doing, close this window and "
            + "choose **Show Console Window…** in Winbar's menu to bring its screen back; **Set Up Winbar…** there "
            + "reopens this window."
        static let recoverOnScreen = "The VM's window in UTM shows what Windows is doing."
        /// H5 unread: true of a VM with a console and of one without, in the Connect error's own terms.
        static let recoverEither = "If the VM has a window in UTM, it shows what Windows is doing. If the VM has no "
            + "screen, close this window and choose **Show Console Window…** in Winbar's menu to bring it back; "
            + "**Set Up Winbar…** there reopens this window."
        static func watchWindows(_ console: SetupFlow.Console) -> String {
            switch console {
            case .headless: return recoverConsole
            case .onScreen: return recoverOnScreen
            case .unknown: return recoverEither
            }
        }
        /// `savedPC` is whether there is a saved PC to press. After **Skip** on step 5 there isn't, and
        /// Connect opens a one-off connection, so the spec's "Winbar pressed your saved PC" would be untrue.
        static func didItAppear(savedPC: Bool) -> String {
            (savedPC ? "Winbar pressed your saved PC in Windows App."
                     : "Winbar opened a one-off connection in Windows App, which asks for the password itself.")
                + " If a Windows desktop opened, that's the whole thing working."
        }
        static let bNo = "No, something's wrong"
        static let bYes = "Yes"
    }

    // MARK: - Step 7: Finish

    enum Finish {
        /// The single restart, in both front-ends. The terminal passes the bare VM name, the window a
        /// quoted one (“Windows 11”), and `summary` is `ConfigChanges.summary` either way.
        static func oneRestart(of vm: String, applies summary: String) -> String {
            "One restart of \(vm) applies: \(summary)."
        }

        static let headlessHeading = "Run it without a screen?"

        /// Shown only when step 6 ended in **Yes** and `otherVMsRefusal` returned nil; the other two
        /// answers get `afterRefusal` instead. The spec's step 7 now has the same figure and the same
        /// refusal rule (both settled 2026-09-22), and the deck still words three things its own way.
        ///
        /// The saving: about two thirds, as the spec and the README now say — re-measured 2026-09-21
        /// with both sides taken the same way, a median of 0.5 CPU-seconds a minute headless against
        /// 1.7 with the window open. The spec states it flatly; the deck says "in testing" and adds
        /// that both are a small fraction of one core, because the README qualifies the same number
        /// that way ("real but small in absolute terms"), and the window shouldn't promise more than it.
        ///
        /// The restart. The spec says "Nothing else is running in UTM right now, so nothing else
        /// stops." That was true when the step asked UTM, and stops being true if the person starts a
        /// VM while the offer sits on screen — which is exactly when **Go Headless** meets the refusal.
        /// So the deck states the rule instead, which is true whenever it is read, and holds for the
        /// way back as much as the way there.
        ///
        /// The way back. The spec says **Show Console Window** brings the screen back "at any time",
        /// but it is a display change too and has the same rule; the menu item's title has an ellipsis.
        static let headlessBody = [
            "A headless VM has no screen of its own, so the Mac's CPU no longer copies what Windows draws. In testing, "
                + "idle host CPU came out about two thirds lower — though with the screen it was already a small "
                + "fraction of one core. Remote Desktop becomes the only way in, and you've just proved that works.",
            "Changing the screen either way restarts UTM, and restarting UTM stops every VM that's running, so Winbar "
                + "only does it while this is the only one.",
            "**Show Console Window…** in Winbar's menu brings the screen back, the same way.",
        ]
        static let bKeepScreen = "Keep the Screen"
        static let bGoHeadless = "Go Headless"

        /// In place of the offer when another VM is running, or UTM wouldn't say (COHERENCE C2), and
        /// under the refusal itself: `otherVMsRefusal`'s title where the heading goes and its detail
        /// as the body, both from `Reconfigure` and both verbatim, so the window, the menu and the CLI
        /// give one answer in one set of words. The deck keeps no copy of them; these are only the
        /// window's own words about its two buttons, **Keep the Screen** and **Check Again**. There is
        /// no **Go Headless** button in this state, since pressing it could only end on that refusal.
        ///
        /// The refusal's detail names the other VMs, so the view shows it as plain text
        /// (`Text(verbatim:)`), the way it shows the lines shared with Terminal.
        static let afterRefusal = "**\(SetupCopy.bCheckAgain)** asks UTM again. **\(bKeepScreen)** finishes without "
            + "going headless; **Go Headless…** in Winbar's menu can do it later, and checks the same thing first."

        /// Instead of the offer, when the person said the desktop didn't appear and the VM still has its
        /// screen (a VM `create` already took headless has nothing to offer either way).
        ///
        /// The spec's "Fix Connect first, then open this window again", which the window couldn't say
        /// while the menu had no way back to it. It has one now (`SetupWindow.availableToEveryone`).
        static let notOffering = "Winbar isn't offering to remove the VM's screen, because Remote Desktop hasn't worked "
            + "yet. A headless VM with no working Remote Desktop has no way in until you choose **Show Console Window…** "
            + "in the menu. Fix Connect first (**\(SetupCopy.bBack)** returns to it), then come back here, or open "
            + "**\(SetupCopy.menuItem)** from the menu again later."

        static let doneHeading = "Winbar is set up"
        /// `connected` is the answer to step 6. "Is ready" is only true when the desktop appeared; after
        /// a **No** the VM is tuned, but Connect is exactly the part that hasn't worked, and **Set Up
        /// Winbar…** is where to pick it up again.
        /// How step 6 ended. A Bool couldn't say the third one: Windows App skipped, so Connect was never
        /// tried — and the ready sentence ("Connect … opens its desktop") would then be untrue.
        enum Outcome { case connected, notConnected, windowsAppSkipped }

        static func doneBody(vm: String, connected: Bool) -> [AttributedString] {
            doneBody(vm: vm, connected ? .connected : .notConnected)
        }

        static func doneBody(vm: String, _ outcome: Outcome, canReopenFromMenu: Bool = true) -> [AttributedString] {
            let ready: Filled = "“\(vm)” is ready. **Connect** in Winbar's menu opens its desktop; **Shut Down** and "
                + "**Restart** are there too."
            let tuned: Filled = "“\(vm)” is tuned, but Connect hasn't worked yet. **Connect** in Winbar's menu tries again; "
                + "**Report a Problem…** there gathers what Winbar sees for you to review and share."
            let noApp: Filled = "“\(vm)” is tuned. Winbar connects to it through Windows App, which isn't installed; "
                + "it's on the Mac App Store."
            let first: Filled
            switch outcome {
            case .connected: first = ready
            case .notConnected: first = tuned
            case .windowsAppSkipped: first = noApp
            }
            var lines = [fill(first)]
            if canReopenFromMenu {
                lines.append(markdown("Run this window again from **Set Up Winbar…** in the menu whenever you like. It changes nothing "
                                     + "that's already right."))
            }
            return lines
        }
    }

    // MARK: - winbar setup --window

    /// What the terminal says when it hands the window over to Winbar.app. Plain text: Terminal
    /// prints it.
    enum HandOff {
        /// Said once the window is open, for a window whose last built step is `lastBuilt`. Pure.
        ///
        /// The finished window does the whole thing, so the set-up carries on there. The partial
        /// builds' sentences are kept for the tests that hold the window to what a build does: an
        /// unfinished window says so plainly, and names `winbar create` and `winbar setup` for what each
        /// does, since `winbar setup` alone stops on a Mac with no Windows VM.
        static func opened(lastBuilt: WizardStep) -> String {
            let open = "Winbar's Set Up Winbar window is open; this terminal is free."
            guard lastBuilt != .finish else {
                return "Winbar's Set Up Winbar window is open, and the set-up carries on there; this terminal is free."
            }
            guard lastBuilt >= .vm else {
                return open + " The window is unfinished: it checks for UTM and Windows App, installs UTM if it's "
                    + "missing and makes sure UTM answers, then stops. The rest is done here: winbar create makes a "
                    + "Windows VM if you don't have one, winbar setup tunes it, and Connect in Winbar's menu opens it."
            }
            // Past step 2 the window has a VM when it stops, so what's left names no winbar create.
            return open + " The window is unfinished: it checks for UTM and Windows App, installs UTM if it's "
                + "missing, and makes or adopts a Windows VM, then stops. The rest is done here: winbar setup tunes "
                + "the VM, and Connect in Winbar's menu opens it."
        }
        static let noApp = "The Set Up Winbar window is part of Winbar.app, and this winbar isn't inside one. Install the "
            + "app (brew install --cask taggie313/tap/winbar), or set up here in Terminal: winbar setup."
        static func couldNotOpen(_ app: String, _ why: String) -> String {
            "Couldn't open \(app)" + (why.isEmpty ? "." : ": \(why)")
        }
        /// The window asks for everything itself, so a flag beside `--window` would quietly do nothing.
        static let takesNoOptions = "winbar setup: --window opens Winbar's own window, which asks for everything "
            + "itself, so it takes no other options"
    }

    // MARK: - Closing and quitting (§2.4)

    enum Quitting {
        static let title = "Winbar is still working"
        /// `doing` is the long work in progress, e.g. "installing UTM" or "restarting “Windows 11”".
        /// It can carry a VM's name, so all of it is shown as it is.
        /// The spec said the work "stops half done"; a Homebrew child or a UTM restart can carry on
        /// without Winbar, so what is certain is only Winbar's part — the same claim the menu's own
        /// busy guard makes.
        static func body(doing: String) -> AttributedString {
            fill("Winbar is in the middle of \(doing). If you quit now, Winbar leaves that unfinished.")
        }
        static let bCancel = CreateCopy.bCancel
        static let bQuitAnyway = "Quit Anyway"
    }

    // MARK: - Work in flight (the runner, critique §3)

    /// What the window says about the one piece of work the runner is doing: to a window reopened
    /// while it runs, beside a press the runner refused because of it, and — through `doing(_:)` —
    /// in the quit guard's "Winbar is in the middle of …". Never a bare "busy": every sentence here
    /// names the work, and says what it's waiting for when that's a person in another app's window.
    enum Working {
        /// A phrase that fits "Winbar is still …" and `Quitting.body(doing:)`. Plain text, shown as it
        /// is: a VM's name can be in it.
        /// `doing` as a line of its own: it's a fragment built for "Winbar is still …", and standing alone
        /// above a page's heading in lower case it read as a half-drawn page.
        static func sentence(_ fragment: String) -> String {
            guard let first = fragment.first else { return fragment }
            return first.uppercased() + fragment.dropFirst() + "…"
        }

        static func doing(_ inFlight: SetupRunner.InFlight) -> String {
            switch inFlight.work {
            case .checkAgain: return "looking at what's on this Mac"
            case .installUTM: return "installing UTM"
            case .installWindowsApp: return "opening Windows App in the App Store"
            case .settleUTM: return "waiting for UTM to answer"
            case .chooseVM(let name, _): return "choosing “\(name)”"
            case .startVM(let name): return "starting “\(name)”"
            case .survey: return "asking Windows how it's set up"
            case .fix(let id): return "fixing \(named(id))"
            case .fixEverything: return "fixing what Windows can have fixed"
            case .recordDone(let id): return "checking \(named(id)) again"
            case .guide(let id): return "opening \(named(id))"
            case .keepBitLocker: return "remembering to keep BitLocker on"
            case .discardChanges: return "discarding the staged changes"
            case .trustCertificate: return "waiting for you to approve the certificate in the macOS dialog"
            case .savePC: return "saving the PC in Windows App"
            case .connect: return "opening the desktop in Windows App"
            // The spec's own example for the quit guard.
            case .applyChanges: return inFlight.vm.map { "restarting “\($0)”" } ?? "restarting the VM"
            }
        }

        /// "G1 (Power plan)": the row's id and title, as the tune screen shows them.
        private static func named(_ id: String) -> String {
            Recipe.check(id).map { "\(id) (\($0.title))" } ?? id
        }

        /// What a piece of work is waiting on the person for, in a window that isn't Winbar's: said to a
        /// window reopened while it waits, so nobody faces a step whose buttons do nothing and a dialog
        /// they can't see.
        ///
        /// `host` is who macOS names in its prompt: this process's host by default. The window passes
        /// Winbar, which is who it always runs as, so its words don't depend on how it was started.
        static func waiting(_ waiting: SetupRunner.Waiting, host: String = Automation.host.name) -> String {
            switch waiting {
            case .certificateApproval: return "Waiting for you to approve the certificate in the macOS dialog. "
                + whereToLook(waiting, host: host)
            case .automationPrompt: return "Waiting for UTM to answer. " + whereToLook(waiting, host: host)
            }
        }

        /// Where the prompt is and what to do about it. Both can open behind other windows. "Stop
        /// Waiting" is the runner's `stopWaiting()`: it ends Winbar's wait, and says nothing about
        /// macOS's dialog, which isn't Winbar's to close.
        ///
        /// The Automation prompt is an "if". Someone who allowed Winbar long ago and whose UTM was
        /// closed waits here too, while UTM launches and answers, and no prompt comes for them; with
        /// UTM closed, macOS can't say beforehand which of the two a Mac is. The words quoted are the
        /// prompt's own (`Automation.promptWords`), so the person looks for what is on the screen.
        static func whereToLook(_ waiting: SetupRunner.Waiting, host: String = Automation.host.name) -> String {
            switch waiting {
            case .certificateApproval:
                return "It can open behind other windows; approve it there, or press **\(bStopWaiting)** and trust "
                    + "it later."
            case .automationPrompt:
                return "If macOS asks whether \(host) may control UTM (its prompt says "
                    + "\(Automation.promptWords(host: host)), and it can open behind other windows), choose **Allow** there."
            }
        }

        static let bStopWaiting = "Stop Waiting"

        /// A press the runner turned down because something else is in flight. Names what that is, and
        /// when it's waiting on the person, where to look.
        static func refusal(_ inFlight: SetupRunner.InFlight, host: String = Automation.host.name) -> AttributedString {
            let busy: Filled = "Winbar is still \(doing(inFlight)), and it does one thing at a time."
            guard let waiting = inFlight.waitingFor else {
                return fill(busy + " This can go ahead once that's done.")
            }
            return fill(busy) + AttributedString(" ") + markdown(whereToLook(waiting, host: host))
        }

        /// Step 7, coming back to a VM that's off with a UTM restart still owed
        /// (`SetupRunner.RestartReport.offWithUTMRestartOwed`). The restart Reconfigure started was
        /// cut short after the display change and before UTM quit, and `UTM.settlePendingRestart`
        /// pays it on the next start — refusing while another VM runs, since quitting UTM stops it.
        static func restartOwed(vm: String) -> AttributedString {
            // Two pieces, because a `Filled` value is never parsed: the button's name, bold, has to be
            // in the part that is.
            fill("“\(vm)” is off, and UTM still has to restart before it starts again: its screen changed, and UTM only "
                 + "picks that up when it starts afresh.")
                + markdown(" **\(VM.bStartIt)** quits UTM first, and only while no other VM is running in it.")
        }

        /// The Mac slept while `doing`. Every wait in that work runs by the clock, so a sleep spends a
        /// deadline rather than pausing it; the power assertion stops idle sleep, not a closed lid.
        static func slept(while doing: String) -> AttributedString {
            fill("The Mac went to sleep while Winbar was \(doing). Its waits run by the clock, so one that ran out may "
                 + "only have been asleep. What's shown now was read after it woke.")
        }

        /// The power assertion's name, which `pmset -g assertions` shows: why this Mac isn't idling to sleep.
        static func keepingAwake(_ inFlight: SetupRunner.InFlight) -> String {
            "Winbar is " + doing(inFlight)
        }
    }

    // MARK: - Armie

    /// The wizard's guide: a CPU with a face (spec §2b). He is the progress narration with a
    /// character attached, and the rules for him are the inverse of everything Clippy got wrong:
    ///
    /// - He speaks only where there is nothing to do: UTM being installed, the install, a VM
    ///   starting, the empty state before any VM exists, and the moment it's all done. `Moment` has no other cases, and none of
    ///   them is a step with a password field — the New Windows VM form has one, so he stays off it.
    /// - Never on an error. The view asks for each line through a helper that knows how the moment
    ///   is going and returns nil when it isn't going well: `line(for:)` for the install,
    ///   `startingLine(timedOut:)` for a VM starting, `doneLine(connected:)` for the end. The empty
    ///   state is the one moment shown through `line(_:)` directly: it has nothing to go wrong in
    ///   (a UTM that couldn't be asked is step 1's error, not an empty list).
    /// - Every line is a true statement about that moment, deadpan, with no exclamation mark, no
    ///   question, no offer of help and no guess at what the person wants. He reports his own
    ///   situation, which happens to be tedious; that is the whole joke.
    ///
    /// The line about "pretending to be an Intel chip" is deliberately missing: it is only true once
    /// someone has run an x86 app, which nothing here can know, and a line that might be untrue is
    /// filler.
    enum Armie {
        enum Moment: Hashable, Sendable {
            /// Step 2, UTM has no Windows VM yet.
            case noVM
            /// Step 2, a job from `winbar create` in one of its ten stages.
            case installing(CreateStage)
            /// Step 2, after **Start It**: `Setup.waitForWindows`'s wait. Any start of a stopped VM,
            /// not only a new one's first boot.
            case startingWindows
            /// Step 7's done screen, when the desktop appeared.
            case done
            /// Step 1, while UTM is being installed: Homebrew's install or Winbar's own download.
            case installingUTM

            static var all: [Moment] {
                [.installingUTM, .noVM] + CreateStage.allCases.map(Moment.installing) + [.startingWindows, .done]
            }
        }

        /// The one-click retire control. No "are you sure": it goes quietly.
        static let bRetire = "Hide Armie"
        /// Above what he says, so a line beside a picture reads as his rather than as the window's.
        static let name = "Armie"

        static func line(_ moment: Moment) -> String {
            switch moment {
            case .noVM:
                // `winbar create` refuses anything but an Arm64 ISO (WindowsISO.evaluate), and an
                // aarch64 guest runs on Apple silicon without emulation (H2 calls anything else slow).
                return "No Windows here yet. Winbar only makes the Arm version, which runs on this chip as it is. "
                    + "No translating."
            case .installing(let stage):
                return installing(stage)
            case .startingWindows:
                // `Setup.waitForWindows` waits up to three minutes for the guest agent, then — only when
                // Windows is set to sign itself in (AutoAdminLogon) — up to 90 s more for explorer.exe,
                // because a survey that runs before the desktop is up finds nobody signed in.
                return "Windows is starting. Winbar waits for its guest agent, and for the desktop too if Windows "
                    + "signs itself in."
            case .done:
                return "That's the lot. Windows is set up, and Connect in Winbar's menu opens it. I'll be quiet now."
            case .installingUTM:
                // One line for the whole install, since it stays up for all of it: the download, the
                // copy, Homebrew's "Moving App" and "Linking Binary", and the check at the end. True
                // of both routes the window takes (`Dependencies.windowPlan`): each ends in
                // `DependencyInstaller.verify`, which checks the bundle, its signature, the team and
                // the version before the install counts as done. UTM is where the VM will run. Not
                // said during an update, where he doesn't appear (`LookAroundPage.armieLine`).
                return "Installing UTM, the app Windows is going to live in. Winbar checks it's the real one before "
                    + "calling it done. I'll watch."
            }
        }

        /// One line per install stage, each saying what that stage really does (CreateJobRun):
        /// preflight reads the ISO and asks UTM for its VMs; every Guest Tools copy, downloaded,
        /// cached or supplied, is checked against the pinned SHA-256; the setup disk holds the answer
        /// file; the VM is created with both discs; the boot watcher answers "Press any key" when the
        /// ISO asks; the oobe stage is the account, region and privacy questions the answer file
        /// answers; the first-logon script runs its steps in turn; and the finish shuts Windows down,
        /// removes the discs and starts it again.
        private static func installing(_ stage: CreateStage) -> String {
            switch stage {
            case .check:
                return "Reading the ISO to see which Windows is in it, and asking UTM what it already has."
            case .guestTools:
                return "Getting UTM's Guest Tools: drivers, and the agent Winbar talks to Windows through. They're "
                    + "checked against the checksum Winbar ships with before they go anywhere."
            case .media:
                return "Writing a small disc with the answers to Windows Setup's questions on it. Nobody has to click "
                    + "through them."
            case .vm:
                return "Asking UTM for a virtual machine with two discs in it: Windows, and the answers."
            case .boot:
                return "Starting the Windows installer from its disc. If it asks for a key press, it gets one."
            case .copy:
                return "Copying files. There are a lot of them. I'll be here."
            case .devices:
                return "Windows is deciding what kind of computer it lives in. It'll be a minute."
            case .oobe:
                return "Windows is asking its first-run questions: account, region, privacy. The disc is answering."
            case .firstLogon:
                return "Windows has signed in for the first time and is working through the list Winbar left it, one "
                    + "step at a time."
            case .finish:
                // The whole stage, not its next step: it is shown from the audit to the restart, and "next
                // it shuts down" stopped being true halfway through.
                return "Windows is installed. Winbar checks it over, shuts it down, takes the install discs out "
                    + "and starts it again without them."
            }
        }

        /// The install's line, or nothing. Quiet once the job has ended, however it ended (the wizard
        /// moves on from a good ending, and a bad one is plain text); quiet while a stall is live, which
        /// a state file whose messages were trimmed can say without its W_STALL; and quiet for the rest
        /// of the job from the first message that `silences` him.
        static func line(for job: CreateJobState) -> String? {
            guard !job.isFinished, job.failure == nil, job.stalled?.alert == nil,
                  !job.messages.contains(where: { silences($0.code) }) else { return nil }
            return line(.installing(job.stage))
        }

        /// Whether a message the job raised ends his narration for the rest of that job. A message
        /// stays in the progress list until the job ends, so he would go on talking beside it.
        ///
        /// - Every error. The job throws its errors, so the only one it raises as a message is
        ///   E_BOOT_NO_PROMPT, which asks the person to press a key in UTM's window while the job
        ///   carries on — and beside it, "if it asks for a key press, it gets one" is untrue.
        /// - Every boxed warning (`CreateProgress.boxedCodes`). Each says a promise made about the
        ///   password didn't hold, and nothing cute stands next to a credential. W_TIMEMACHINE is
        ///   raised before the install starts, so it takes the whole install's lines with it; that's
        ///   the price.
        /// - Every other warning, including a stall that has since cleared, except `cautions`.
        /// - A note (N_…) only if it is one of `failureNotes`. Most notes are what the job did or will
        ///   do, but the prefix is not a promise: four of them report something that didn't work, and
        ///   an earlier version of this rule took the prefix at its word and let him chat beside them.
        ///
        /// A code nobody has sorted yet silences him: the safe way to be wrong.
        static func silences(_ code: String) -> Bool {
            if CreateProgress.boxedCodes.contains(code) { return true }
            if failureNotes.contains(code) { return true }
            if code.hasPrefix("N_") { return false }
            return !cautions.contains(code)
        }

        /// The warnings he may talk beside: preflight's cautions about the conditions the install
        /// runs in, said before anything has started, none of them saying anything went wrong or
        /// contradicting a line of his. W_ISO_UNTESTED isn't one: it says Setup may stop to ask
        /// something, and his line for that stage says the answer disc is answering.
        static let cautions: Set<String> = ["W_BATTERY", "W_SPACE", "W_ISO_REMOVABLE", "W_UTM_PRERELEASE",
                                            "W_UTM_UNTESTED"]

        /// The notes that say something didn't work, read off what CreateJobRun actually raises:
        /// N_PC_FAILED ("Winbar couldn't save this PC in Windows App…", raised in the media stage and on
        /// screen for eight stages after), N_PC_APP_RUNNING (the save refused because the app was open),
        /// N_RESUME_LATE (a resume that may come to "The computer restarted unexpectedly"), and
        /// N_KEPT_CONSOLE. Only two of N_KEPT_CONSOLE's three texts are failures ("UTM didn't accept
        /// the display change", "UTM still reports N displays"), but they share one code, and being
        /// quiet beside the third costs nothing. Silence is the safe way to be wrong.
        static let failureNotes: Set<String> = ["N_PC_FAILED", "N_PC_APP_RUNNING", "N_RESUME_LATE", "N_KEPT_CONSOLE"]

        /// A starting VM's line, or nothing once the wait has run out. After the three minutes
        /// `winbar setup` says "The guest agent didn't answer yet." and carries on without it; that
        /// is the wait failing, and he isn't there for it.
        static func startingLine(timedOut: Bool) -> String? {
            timedOut ? nil : line(.startingWindows)
        }

        /// The done screen's line, only when step 6 ended in **Yes**. After a **No** the done screen is
        /// a place where something didn't work, and he doesn't speak there.
        static func doneLine(connected: Bool?) -> String? {
            connected == true ? line(.done) : nil
        }
    }
}
