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
            /// A button's name that carries a chosen value (**Use “winlab01”**), bold like every other
            /// button the deck names, and still never parsed: the weight is set on the value's run
            /// rather than written as asterisks around it, which Markdown could only read if the value
            /// were parsed too.
            mutating func appendInterpolation(bold value: String) {
                var run = AttributedString(value)
                run.inlinePresentationIntent = .stronglyEmphasized
                text += run
            }
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

    /// The steps' shorter names, in the same order: what the footer's Continue calls the next step
    /// (`journeyNext`), so the button and the bar name one step one way. The bar has no labels under
    /// its segments (`StepBar`); VoiceOver reads the full name (`stepBarLabel`).
    static let stepBarNames = ["Welcome", "Look around", "The VM", "Tune", "Certificate", "Saved PC", "Connect", "Finish"]

    /// A step's short name, from the list above.
    static func stepBarName(_ step: WizardStep) -> String {
        stepBarNames[WizardStep.allCases.firstIndex(of: step) ?? 0]
    }

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

    /// What VoiceOver adds after the step bar's label when steps were passed over (`StepBar.flagged`),
    /// which the bar marks with a warning; nil when none were.
    static func stepBarFlagged(_ steps: [WizardStep]) -> String? {
        guard !steps.isEmpty else { return nil }
        return "Skipped or not confirmed: " + steps.map(stepName).joined(separator: ", ")
    }

    /// What the pointer is told over one of the step bar's segments: the step and how it stands, and
    /// for a step passed over, what happened and why (`passedOver`). A segment used to say only its
    /// step's name, so the owner found an orange ⚠ on the finished page that explained nothing. Pure.
    static func stepBarHelp(_ step: WizardStep, _ mark: StepBar.Mark, passedOver: String? = nil) -> String {
        let standing: String
        switch mark {
        case .done: standing = "done"
        case .current: standing = "you're here"
        case .pending: standing = "still to come"
        case .flagged: standing = passedOver ?? "skipped or not confirmed"
        }
        return stepName(step) + ": " + standing
    }

    /// What happened to a step passed over, and why, from what Winbar read: the step bar's hover after
    /// the step's name, and the finished page's list of what was passed over. nil for a step that can't
    /// be passed over, or wasn't. Pure.
    static func passedOver(_ step: WizardStep, _ facts: SetupFlow.Facts) -> String? {
        switch step {
        case .certificate:
            switch SetupFlow.certificate(facts) {
            case .trusted: return nil
            case .trust: return "skipped — not approved, so Windows App may warn about it when you connect"
            case .needsCertificate: return "skipped — Windows had no certificate for its name yet"
            case .notYet: return "skipped — it couldn't be checked yet"
            }
        case .savedPC:
            if case .saved = SetupFlow.savedPC(facts) { return nil }
            if SetupFlow.windowsAppSkipped(facts) { return "skipped — Windows App isn't installed" }
            if SetupFlow.commandLineSilent(facts) {
                return "skipped — Windows App's command line didn't respond, so Winbar couldn't save it"
            }
            switch facts.kind("C2") {
            case .manual?: return "skipped — Winbar couldn't save it"
            case .fixable?: return "skipped — not saved, so Windows App asks for your password when you connect"
            default: return "skipped"
            }
        case .connect:
            switch Finish.outcome(facts) {
            case .connected: return nil
            case .notConnected: return "you said the Windows desktop didn't appear"
            case .windowsAppSkipped: return "not tried — Windows App was skipped"
            case .notTried: return "the desktop wasn't confirmed"
            }
        default:
            return nil
        }
    }

    /// What VoiceOver says for a status mark (`StatusMark`), which is a symbol it would otherwise read
    /// as "checkmark circle" — or, for the text glyphs the marks used to be, as punctuation.
    enum Status {
        static let done = "Done"
        static let attention = "Needs you"
        static let failed = "Failed"
        static let running = "In progress"
        /// A check the window hasn't made yet (step 1's rows).
        static let notChecked = "Not checked yet"
        /// An install stage that hasn't begun: nothing is being checked there.
        static let notStarted = "Not started yet"
        /// A note: nothing to do, nothing to wait for.
        static let info = "For information"
    }

    /// What VoiceOver says before a callout's words, for the tones whose meaning is otherwise only
    /// the symbol and the tint. An information callout is just its words.
    enum Tone {
        static let attention = "Needs attention"
        static let error = "Problem"
    }

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
        /// The welcome's title, under Winbar's mark, the way Apple's own assistants open. The window
        /// had none: the review found the mark repeated from the header and one sentence standing in
        /// for a title. The header row is hidden on this page (`SetupScreen.showsHeader`), so this is
        /// the only title here, and it isn't the title bar's "Set Up Winbar" said twice.
        static let title = "Welcome to Winbar"

        /// Under the title: what Winbar is, in one sentence.
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

        /// The spec's, for the finished window, in words Ben has: "adopts a VM" became "uses one you
        /// already have".
        ///
        /// The third line names no questions and counts none. It listed five kinds of permission, the
        /// longest sentence on the page and words ("certificate trust", "Local Network access") that
        /// mean nothing before the page that asks; and every count it carried had to be kept in step
        /// with Homebrew's App Management question and the rest. Each question is said on its own page
        /// before it appears, which is the promise that matters. "May", because a Mac that allowed
        /// everything before sees none of them.
        private static let whole = [
            "This window does the whole thing: it checks what's here, makes a Windows VM or uses one you already "
                + "have, tunes Windows, and connects once to prove it works. You don't need Terminal.",
            "About five minutes. Installing Windows, if you need it, adds about ten more on a fast Mac.",
            "macOS may ask your permission a few times. Winbar tells you what each question is before it appears.",
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

        /// While the window stops after the VM: it checks, installs UTM, gets UTM to answer, and makes a
        /// VM or takes on one that's there ("adopts" was the spec's word, and not one Ben has). The
        /// questions are step 1's, and only step 1's: choosing or starting a VM asks UTM, which step 1
        /// already has an answer from, and an install the window starts leaves the one
        /// macOS question it could raise — Local Network — to set-up (`CreatePlan.inSetupWindow`).
        private static let throughVM = [
            "For now this window does the first part: it checks what's here, installs UTM if it's missing, and makes "
                + "a Windows VM or uses one you already have, then stops and says what does the rest.",
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
        /// The instruction first, in the deck's one verb; what the button does after it.
        static let askBody = "Choose **Open UTM and Ask**: Winbar opens UTM and asks it something small. That's how "
            + "Winbar will start, stop and change the VM."
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
        /// A Continue with nowhere named: the welcome's. Step 1's own way on names the VM step
        /// (`journeyNext`).
        static let bContinue = "Continue"
        /// For a refused Automation grant: the same page the menu's **Open Automation Settings…** opens.
        static let bOpenAutomationSettings = "Open Automation Settings…"
        /// When UTM answered with an error: opens UTM and asks it again (`settleUTM`, which opens it
        /// first), so the fix the card names is the button rather than an instruction.
        static let bOpenUTM = "Open UTM"
        /// For a copy of UTM Winbar won't replace: shows it in the Finder, where the Trash is a drag
        /// away, rather than a path to go looking for.
        static let bShowInFinder = "Show in Finder"

        /// The fold over what only some people want to read: the install plan's particulars, UTM's own
        /// error, Homebrew's output.
        static let bShowDetails = "Show Details"
        static let bHideDetails = "Hide Details"

        /// Step 1's page title while Winbar reads the Mac, first time or pressed again, and the line
        /// under the rows that says how long. The page showed a spinner and nothing else, or a card from
        /// the read before beside a spinner that was about to replace it.
        static let checkingTitle = "Checking this Mac"
        static let checkingNote = "This takes a few seconds."

        /// Step 1's page title once there is nothing left to do here. "For now" while Windows App is
        /// missing or needs something: the saved-PC step deals with it, so the step is done, but
        /// "everything" would be untrue.
        static func readyTitle(windowsAppReady: Bool) -> String {
            windowsAppReady ? "Everything Winbar needs is here" : "Everything Winbar needs for now is here"
        }

        /// A row's words for an app that's there, as a subtitle to its name: "Installed · 4.7.5". The
        /// row said "UTM" over "UTM 4.7.5", the name twice. nil when `state` isn't installed.
        static func installed(_ state: DependencyState) -> String? {
            guard case .installed(let version) = state else { return nil }
            return version.map { "Installed · \($0)" } ?? "Installed"
        }

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

        /// utmctl said nothing after **Open UTM and Ask** or **Try Again**, and a prompt may still be on
        /// screen: the page's title. "UTM's command-line tool" was a name Ben doesn't have for what is,
        /// to him, UTM.
        static let silentHeading = "UTM hasn't answered"

        /// The page's title when the way on is the switch in System Settings: Automation refused, or
        /// utmctl silent with macOS's answer already on file. It says what's needed rather than what
        /// went wrong ("Winbar isn't allowed to control UTM" read as a verdict).
        static let permissionHeading = "Winbar needs permission to control UTM"

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
                    + "then choose **\(bTryAgain)**."
            case .decided:
                // The settings page is the filled button here, and the window looks again by itself when
                // it becomes key (`SetupJourneyActions.returnRead`, which asks UTM again:
                // `SetupRunner.reasksUTM`), so the sentence ends on the button and on what happens
                // after, not on Try Again.
                return "Winbar opened UTM, and macOS already has an answer on whether \(host) may control it, so no "
                    + "prompt is coming. Choose **\(bOpenAutomationSettings)** and turn on UTM under \(host). "
                    + comeBack
            }
        }

        /// What happens once the switch is on, or the app is updated: the window looks again when it
        /// becomes key (`SetupJourneyActions.returnRead`, which every card saying this is held to), and
        /// asks UTM again when its last answer was a refusal (`SetupRunner.reasksUTM`).
        static let comeBack = "Winbar checks again when you come back."

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
        ///
        /// It opens "Not installed", not "Windows App isn't installed": it is the subtitle under the row's
        /// "Windows App", and the review found rows saying their own name twice.
        static func windowsAppLater(lastBuilt: WizardStep) -> String {
            lastBuilt >= .savedPC
                ? "Not installed yet. Winbar gets to it at the saved-PC step."
                : "Not installed yet. It isn't needed until there's a VM to connect to; winbar setup offers "
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
        /// When utmctl answered with an error: the page's title, and what to do. The error itself
        /// ("UTM is not running (error -600)") is under Details (`utmSaid`), not on the row.
        static let utmFailedHeading = "UTM isn't answering Winbar"
        static let utmFailed = "Winbar starts and stops Windows through UTM, so nothing after this step works until UTM "
            + "answers. Choose **\(bOpenUTM)**: Winbar opens it and asks again."

        /// UTM's own words about its error, for Details.
        static func utmSaid(_ detail: String) -> String { "UTM said: \(detail)" }

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

        /// The install plan's paragraphs in the window, for **Show Details**. A plan Winbar can't carry
        /// out (a copy signed by someone else, or too old and not Homebrew's to update) has none: its
        /// advice is Terminal's, ending in commands, and the window says what to do with the Finder and
        /// this window instead, in the card's one sentence (`summary`).
        static func plan(_ plan: InstallPlan, state: DependencyState) -> [String] {
            if case .manual = plan { return [] }
            return DependencyCopy.plan(.utm, plan)
        }

        /// A Homebrew failure's detail in the window: its "try it again yourself: brew …" is the Try
        /// Again button under it. "It stopped with exit status 1; its own output is above" goes: the
        /// title says Homebrew couldn't, an exit status is a number Ben can do nothing with, and in the
        /// window the output is the open Details fold under this sentence, not above it.
        ///
        /// The sentence that replaces Terminal's names **Try Again** in bold, as every instruction in the
        /// window does; the rest is Homebrew's own words, which stay plain rather than being read as
        /// Markdown (an underscore in a path would turn to italics).
        static func forWindow(_ detail: String) -> AttributedString {
            let text = detail.replacingOccurrences(of: #"^It stopped with exit status -?\d+; its own output is above\. "#,
                                                   with: "", options: .regularExpression)
            guard let terminal = text.range(of: #"(Try it again yourself|Run it yourself and watch what it says): .*$"#,
                                            options: .regularExpression) else { return AttributedString(text) }
            return AttributedString(String(text[..<terminal.lowerBound])) + markdown(tryAgainBelow)
                + AttributedString(String(text[terminal.upperBound...]))
        }
        static let tryAgainBelow = "Choose **\(SetupCopy.bTryAgain)** below. If it keeps failing, UTM's own download at "
            + "getutm.app works too."

        /// The silent UTM row: how long it was asked for, since the card says what that means.
        static func silentRow(seconds: Int) -> String { "No answer in \(seconds) seconds" }

        /// Automation refused, in the window: the filled button, what to do there, and what happens
        /// after. The recipe's words (`Automation.deniedError`) end on a tccutil command for a terminal.
        static func denied(host: String) -> String {
            "Choose **\(bOpenAutomationSettings)** and turn on UTM under \(host) in Privacy & Security → Automation. "
                + comeBack
        }

        // MARK: When UTM needs installing, updating or replacing

        /// The card's one sentence when UTM needs installing, updating or replacing: what's needed and
        /// the button that does it. The plan's particulars — Homebrew's command, the team ID, the
        /// notarization check, the GitHub address, what Homebrew's update may make macOS ask — are
        /// `details`, behind **Show Details**: about 160 words stood between the heading and the button.
        /// Markdown. Pure.
        static func summary(_ plan: InstallPlan?, state: DependencyState, host: String = "Winbar") -> String {
            let what = "UTM is the free app Windows runs in."
            let button = plan.flatMap { bInstall(.utm, $0) }.map { "Choose **\($0)**" }
            switch (state, plan) {
            case (.wrongSignature, _):
                return "Winbar won't replace an app it didn't install. Choose **\(bShowInFinder)**, move this copy of UTM "
                    + "to the Trash, and come back: Winbar then offers to install UTM from \(Dependency.utm.vendor)."
            case (.tooOld(_, let minimum), .brewUpgrade?):
                // The one consequence that can't wait for Details: a running VM stops. And what to press
                // when macOS asks, which Details says in full (`updateMayAsk`).
                return "Winbar needs UTM \(minimum) or later. \(button ?? ""): if UTM is open, it quits and any VM in "
                    + "it stops. If macOS asks as it goes, choose **Allow** or **Open**."
            case (.tooOld(_, let minimum), _):
                return "Winbar needs UTM \(minimum) or later. Update UTM the way you installed it: its own Check for "
                    + "Updates, the Mac App Store, or getutm.app. " + comeBack
            case (_, .brew?):
                return what + " \(button ?? ""): about \(Dependency.utmDownloadMB) MB, and a few minutes."
            case (_, .download?):
                return what + " \(button ?? ""): about \(Dependency.utmDownloadMB) MB from UTM's own site, checked "
                    + "before it's opened."
            case (_, .manual?), (_, .appStore?), (_, .brewUpgrade?), (_, nil):
                // Never UTM's plan for a copy that's missing (`Dependencies.plan`): Homebrew or the
                // download. A manual plan's advice is Terminal's, so it isn't said here either way.
                return what
            }
        }

        /// What's under **Show Details** on that card: the lead and the plan's paragraphs the card used
        /// to open with, minus what the summary already says. Plain text, since the plan's are shared
        /// with Terminal. Pure.
        static func details(_ plan: InstallPlan?, state: DependencyState, host: String = "Winbar") -> [String] {
            switch state {
            case .wrongSignature(let detail):
                // What's wrong with the copy that's there; the plan's advice is the summary.
                return [detail]
            case .tooOld:
                guard let plan, case .brewUpgrade = plan else { return [] }
                return self.plan(plan, state: state) + [updateMayAsk(host: host)]
            case .missing, .installed:
                return plan.map { self.plan($0, state: state) } ?? []
            }
        }

        /// The install's one line of progress under its bar, from the newest thing said: the download's
        /// count beside what it counts ("Downloading UTM · 112 of 250 MB"), Winbar's own sentences as they
        /// are, and in place of Homebrew's output — "==> Moving App 'UTM.app' to '/Applications/UTM.app'"
        /// in monospace, while the install went well — what Homebrew is doing, in words. Its output is
        /// under **Show Details**. Pure.
        static func progress(_ line: String?, download: SetupWindowState.DownloadCount?, update: Bool) -> String {
            let name = Dependency.utm.name
            if let download { return "Downloading \(name) · \(downloaded(done: download.done, total: download.total))" }
            let homebrew = update ? "Homebrew is updating \(name)…" : "Homebrew is installing \(name)…"
            guard let line, !line.isEmpty else { return update ? "Updating \(name)…" : "Installing \(name)…" }
            if line.hasPrefix("==> Downloading") { return "Downloading \(name)…" }
            return ownWords(line) ? line : homebrew
        }

        /// Whether `line` is one of Winbar's own progress sentences (`DependencyCopy`), which are plain
        /// words already, rather than Homebrew's output or the command Winbar hands it. Read off each
        /// sentence's own function around values no install says, so the two can't drift. Pure.
        static func ownWords(_ line: String) -> Bool {
            let utm = Dependency.utm
            let marker = "\u{1}"
            let url = URL(string: "https://example.invalid/UTM.dmg")!
            let starts = [DependencyCopy.downloading(utm, from: url).replacingOccurrences(of: "example.invalid", with: marker),
                          DependencyCopy.copying(utm, to: marker), DependencyCopy.checkingDownload(utm),
                          DependencyCopy.checking(utm),
                          DependencyCopy.downloadTrusted(utm, assessment: .init(accepted: true, source: nil, origin: marker))]
                .map { $0.components(separatedBy: marker)[0] }
            // "UTM 4.7.5 is installed, signed by …": matched by its tail, since its head is only the name.
            let installed = String(DependencyCopy.installed(utm, version: nil).dropFirst(utm.name.count))
            return starts.contains { !$0.isEmpty && line.hasPrefix($0) } || line.hasSuffix(installed)
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
        /// The way into the New Windows VM form, named for what its last page's button does
        /// (`CreateCopy.bInstall`): the wizard said **Make One** and the form **Create**, then **Install
        /// Windows**, which is three names for one thing. The dots are the form's pages, asked first.
        static let bMakeOne = CreateCopy.bInstall + "…"
        /// The same, beside a VM that's already there.
        static let bMakeNew = "Install Windows in a New VM…"
        static let bChooseAnother = "Choose Another VM"
        /// Markdown. "Guests" was UTM's word for what, to Ben, is a VM.
        static let notKnownWindows = "Winbar looks after Windows VMs. This one doesn't have a Windows icon in UTM; if it "
            + "runs Linux or another system, choose **\(bMakeNew)** instead."

        static let oneHeading = "One Windows VM"
        /// `windows` is `VMInfo.isWindows`. It comes from the icon UTM shows, and the candidates fall back
        /// to every QEMU VM when none has a Windows icon — so the one VM on offer may not say it's
        /// Windows, and the sentence mustn't claim it does.
        ///
        /// `use` is the VM the page's **Use** button names — the ticked row where the page lists VMs,
        /// which needn't be `name` — or nil where no **Use** is the way on (a ticked VM that doesn't
        /// say it's Windows, whose caution names **Install Windows in a New VM…** instead). The
        /// sentence named `name`'s button while the corner said Use for the row ticked.
        static func oneBody(_ name: String, windows: Bool, use: String?) -> AttributedString {
            let fact: Filled = windows ? "UTM has one Windows VM: “\(name)”." : "UTM has one virtual machine: “\(name)”."
            guard let use else { return fill(fact) }
            return fill(fact + " If you choose \(bold: bUseTitle(use)), Winbar will look after it: its settings, Connect "
                        + "and the menu bar item will all mean this one.")
        }
        /// A button's title, and an `AttributedString` like every other string with a name in it:
        /// the view gives it to `Button(action:label:)` as a `Text`.
        static func bUse(_ name: String) -> AttributedString { fill("\(bUseTitle(name))") }
        /// The button's words as plain text, for the sentence that names it (`oneBody`).
        static func bUseTitle(_ name: String) -> String { "Use “\(name)”" }

        static let severalHeading = "Which VM?"
        static func severalBody(count: Int) -> String {
            "UTM has \(count) virtual machines. Which Windows VM should Winbar look after?"
        }
        /// The corner's title on a list of VMs while none is ticked, greyed out: the list's rows are
        /// what to press first. Once one is, the corner names it (`bUse`).
        static let bUseThisOne = "Use This One"
        /// Beside it while it's greyed out.
        static let pickFirst = "Pick a VM in the list first"

        /// A VM row's second line: what it is and how it stands, as far as UTM says. The system is
        /// UTM's icon, which a hand-made Windows VM may not have, so a VM with no icon Winbar knows
        /// says nothing about its system rather than something that may be wrong. Pure.
        static func rowDetail(_ vm: VMInfo) -> String? {
            let parts = [system(vm), state(vm)].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }

        static func system(_ vm: VMInfo) -> String? {
            if vm.isWindows { return "Windows" }
            let icon = vm.icon.lowercased()
            let linux = ["linux", "debian", "ubuntu", "fedora", "arch", "centos", "kali", "mint", "alpine", "suse", "rhel",
                         "gentoo", "manjaro"]
            return linux.contains { icon.contains($0) } ? "Linux" : nil
        }

        /// UTM's status words (`VMInfo.status`), in the ones a Mac uses for a machine.
        static func state(_ vm: VMInfo) -> String? {
            switch vm.status {
            case "started": return "Running"
            case "stopped": return "Stopped"
            case "starting", "resuming": return "Starting"
            case "stopping", "pausing": return "Stopping"
            case "paused": return "Paused"
            default: return nil
            }
        }

        /// Step 2 with no VM list from UTM, which step 1 exists to get. The way on is the way back.
        static let unlistedHeading = "Check UTM first"
        static let unlisted = "Winbar hasn't had UTM's list of VMs yet. Choose **\(bGoBack)** to check that UTM is "
            + "installed and allowed to answer Winbar."
        static let bGoBack = "Go Back to Look Around"

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
        /// offers to show that one rather than a second **Install Windows…**.
        static let installingHeading = "Windows is being installed"
        static let installing = "A Windows install is running on this Mac, and Winbar does one at a time. "
            + "Choose **\(bShowInstallProgress)** to see it here."
        /// The menu's **Show Install Progress…** without its dots: here it shows the install in place,
        /// rather than opening a window that asks for more.
        static let bShowInstallProgress = "Show Install Progress"

        /// W_MEDIA_LEFT in the window's words, with its two buttons beside it (`SetupDiskNote`). The
        /// job's own sentence names the folder's path and the error, and ends "delete the folder
        /// yourself" without saying where that is.
        static let setupDiskLeft = "Winbar couldn't delete the setup disk it made for this install. It holds your "
            + "Windows password, scrambled: move it to the Trash, then empty the Trash."
        static let bShowSetupDisk = "Show in Finder"
        static let bTrashSetupDisk = "Move to Trash"
        static let setupDiskTrashed = "The setup disk is in the Trash. Empty the Trash to delete it for good."
        static func setupDiskNotTrashed(_ reason: String) -> String {
            "Winbar couldn't move the setup disk to the Trash (\(reason)). Choose \(bShowSetupDisk) to see where it is."
        }

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
            row.id == "G9" && keptBitLocker && row.kind != .ok ? "BitLocker is kept on by choice." : words(row.detail)
        }
        static func how(_ id: String, _ text: String) -> String {
            let text = id == "H6" ? text.replacingOccurrences(of: "Terminal has Full Disk Access", with: "Winbar has Full Disk Access") : text
            // "Run this again" is Terminal's: in the window a manual row's way on is its own button.
            return words(text).replacingOccurrences(of: "then run this again.", with: "then choose \(bDone(id)).")
        }

        /// A row's name in the window. The recipe's titles are `winbar setup`'s too and stay as they
        /// are there; three of them are words Ben doesn't have ("vCPUs", "RAM", "RDP certificate").
        /// The certificate is **Certificate** here because that is the step bar's name for the step
        /// that approves it, and `Certificate.goBack` sends Ben to this row by it.
        static func title(_ id: String, recipe: String) -> String {
            switch id {
            case "H3": return "Processor cores"
            case "H4": return "Memory"
            case "H5": return "Windows' screen"
            case "G7": return "Certificate"
            case "H7": return "Certificate approved"
            default: return recipe
            }
        }
        static func title(_ row: SetupFlow.Row) -> String { title(row.id, recipe: row.title) }

        /// Why a row matters, in the window: one plain sentence or two, where the recipe's `why` (which
        /// `winbar setup` prints, and keeps) names the machinery — the QEMU guest agent, vCPUs, NLA and
        /// TLS, netplwiz and LSA secrets, the readiness probe and port 3389. Each says only what the
        /// recipe's says, in other words; nil leaves a row's own, which is plain already.
        static func why(_ id: String) -> String? {
            switch id {
            case "G0":
                return "Winbar checks and tunes Windows through UTM's Guest Tools. Connect needs an edition that "
                    + "accepts Remote Desktop, and Home doesn't."
            case "G5":
                return "Remote Desktop needs a real password: a Windows Hello PIN never works over it, and Winbar can't "
                    + "give a Microsoft account one."
            case "G1":
                return "Balanced, set to speed up quickly, keeps Windows responsive and lets your Mac's cores rest while "
                    + "Windows is idle. The screen turns off after 5 minutes."
            case "G2":
                return "Windows sets it to a kind of sleep the VM doesn't have, so UTM's power button does nothing "
                    + "useful. Shut down makes it a real off switch."
            case "G3":
                return "SysMain, Windows Search and Windows' diagnostics reporting keep the processor and disk busy in "
                    + "the background, which buys nothing in a VM."
            case "G4":
                return "In a VM, your Mac's processor draws Windows' transparency, animations and shadows, so they cost "
                    + "more than they're worth. They take full effect the next time you sign in to Windows."
            case "G6":
                return "Connect opens Windows over Remote Desktop, so it has to be on, with Windows' safe settings: it "
                    + "checks your password first, and accounts with no password can't sign in over the network."
            case "G7":
                return "Windows App checks the certificate Windows shows it. Windows' own is made out to a different "
                    + "name, so Winbar makes one for the name your Mac uses, which the Certificate step approves."
            case "G8":
                return "When Windows signs in by itself at startup, Connect picks up the session that's already "
                    + "running, apps and all. Windows keeps the password protected, not as plain text."
            case "G9":
                return "When FileVault already encrypts the VM's disk, BitLocker only adds work to every read and "
                    + "write, and changing the VM's screen, processor cores or memory can make Windows ask for its "
                    + "recovery key."
            case "G10":
                return "UTM's Guest Tools give Windows its network driver and the helper Winbar checks and tunes it "
                    + "through, and make the shared folder work. Winbar checks each one is there."
            case "H6":
                return "The VM's disk is a file of tens of gigabytes that changes all the time, so backing it up every "
                    + "hour and indexing it for Spotlight is work for nothing. macOS protects UTM's folder, so Winbar "
                    + "can only check this, not change it."
            case "H8":
                return "With UTM's Shared network only this Mac can reach the VM, and Winbar can find it to check "
                    + "whether Windows is ready. Bridged puts Remote Desktop on your whole network, where Winbar can't "
                    + "find the VM."
            case "H3":
                return "Winbar gives Windows as many processor cores as your Mac has fastest ones, between 4 and 8. In "
                    + "testing, more cost your Mac extra work without making Windows any faster."
            case "H4":
                return "Room for Windows to keep the files it uses in memory: 16 GB on a Mac with 64 GB or more, 12 GB "
                    + "from 32 GB, otherwise 8 GB, and never more than half your Mac's. More that you chose is left alone."
            default:
                return nil
            }
        }
        static func why(_ row: SetupFlow.Row) -> String { plain(why(row.id) ?? row.why) }

        /// The recipe's status lines and instructions in the window's words, phrase by phrase. They are
        /// `winbar setup`'s too, built from what Windows answers, so the window can't have its own copy
        /// of each; these are the phrases in them that name machinery Ben can't see. Codes go too
        /// (`plain`). Each phrase is one the recipe says, which `SetupCopyWordsTests` holds it to.
        static let windowWords: [(recipe: String, window: String)] = [
            ("the QEMU guest agent isn't answering", "Windows isn't answering Winbar"),
            ("Just after boot the agent can take a minute to start.", "Just after Windows starts, this can take a minute."),
            ("winbar start, wait for Windows, then run this again.", "Start the VM in UTM, wait for Windows, then run this again."),
            ("(console window or Remote Desktop)", "(on Windows' screen or over Remote Desktop)"),
            ("(console window)", "(on Windows' screen)"),
            ("on, listening on 3389", "on"),
            ("Network Level Authentication is off", "the password check before sign-in is off"),
            ("TLS isn't required", "encryption isn't required"),
            ("blank-password network logons are allowed", "accounts with no password can sign in over the network"),
            ("firewall rules not all enabled", "the firewall doesn't let all of Remote Desktop through"),
            ("and Network Level Authentication would lock", "and Remote Desktop's password check would lock"),
            ("the listener uses Windows' generated certificate, not one for", "Windows uses its own certificate, not one for"),
            ("no RDP host yet (winbar config --host)", "Winbar doesn't know Windows' name yet"),
            ("no RDP host yet", "Winbar doesn't know Windows' name yet"),
            ("Windows didn't report the listener certificate", "Windows didn't show Winbar its certificate"),
            ("Hello-only sign-in hides the netplwiz setting that turns it on", "Windows Hello sign-in hides the setting that turns it on"),
            ("In the netplwiz window setup opens in Windows,", "In the window Winbar opens in Windows,"),
            ("press OK,", "choose OK,"),
        ]

        /// `text` with `windowWords` put in and its check codes taken out. Pure.
        static func words(_ text: String) -> String {
            plain(windowWords.reduce(text) { $0.replacingOccurrences(of: $1.recipe, with: $1.window) })
        }
        static let heading = "Tuning Windows"

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

        /// The word at a row's trailing edge. A row Winbar couldn't read, or whose Fix failed, says so
        /// rather than "Needs attention": nothing about it is Ben's doing.
        static func trailing(_ status: SetupTuneStatus, _ row: SetupFlow.Row) -> String {
            guard status == .needsAttention else { return self.status(status) }
            if row.failure != nil { return "Fix didn't work" }
            if row.kind == .error { return "Couldn't check" }
            return self.status(status)
        }

        /// The page's opening line and the sentence under it (`SetupTuneHeadline`). It replaces a
        /// paragraph about what Verified means and a count line ("12 verified · 2 skipped · 1 needs
        /// attention") that left Ben to work out which row was his and what to press.
        static func headline(_ headline: SetupTuneHeadline) -> (title: String, detail: String?) {
            switch headline {
            case .working(let line):
                return (line, nil)
            case .notAsked:
                return ("Winbar hasn't asked Windows yet", "Choose **\(SetupCopy.bCheckAgain)** to ask it. It takes a few seconds.")
            case .needsYou(let count, let fixable):
                let title = count == 1 ? "1 setting needs you" : "\(count) settings need you"
                if fixable == count {
                    return (title, "Choose **\(bFixEverything)**, or fix or skip each one below.")
                }
                if fixable > 0 {
                    return (title, "Choose **\(bFixEverything)** for the ones Winbar can fix. The rest are below: "
                                + "follow their steps, or skip them.")
                }
                return (title, count == 1 ? "It's first below: follow its steps, or skip it."
                                          : "They're first below: follow their steps, or skip them.")
            case .unchecked(let count):
                return (count == 1 ? "Winbar couldn't check 1 setting" : "Winbar couldn't check \(count) settings",
                        "You can carry on. To try once more, choose **\(SetupCopy.bCheckAgain)** on it.")
            case .tuned(let staged):
                let restart: String
                switch staged {
                case 0: restart = ""
                case 1: restart = " One change waits for the restart at the end of setup."
                default: restart = " \(staged) changes wait for the restart at the end of setup."
                }
                return ("Windows is tuned", "Winbar checked each setting it looks after, in Windows and on this Mac." + restart)
            }
        }

        /// The folded group of rows that passed: how many, as the one line Ben needs about them.
        static func alreadyRight(_ count: Int) -> String {
            count == 1 ? "1 setting already right" : "\(count) settings already right"
        }

        /// What the headline says while work runs on this step, in row titles rather than
        /// `Working.doing(_:)`'s "fixing G1 (Power plan)", which carries the recipe's code.
        static func busy(_ flight: SetupRunner.InFlight) -> String {
            func title(_ id: String) -> String { Recipe.check(id).map { self.title(id, recipe: $0.title) } ?? "the setting" }
            switch flight.work {
            case .survey, .checkAgain: return "Checking Windows' settings…"
            case .fix(let id): return "Fixing \(title(id))…"
            case .fixEverything: return "Fixing what Winbar can fix…"
            case .recordDone(let id): return "Checking \(title(id)) again…"
            case .guide(let id): return id == "H6" ? "Opening Time Machine settings…" : "Opening it in Windows…"
            case .keepBitLocker: return "Keeping BitLocker on…"
            case .discardChanges: return "Undoing the change…"
            default: return Working.sentence(Working.doing(flight))
            }
        }

        /// A row left alone by a choice made in the New Windows VM form: what was chosen, and when,
        /// rather than the form's checkbox label after "Off by choice:", which read as an instruction.
        static func leftAlone(declined flag: String) -> String {
            let what: String
            switch flag {
            case "--autologon": what = "automatic sign-in"
            case "--remote-desktop": what = "Remote Desktop"
            case "--winbar-tuning": what = "performance tuning"
            default: return "Left alone: you turned this off when Windows was installed."
            }
            return "Left alone: you turned off \(what) when Windows was installed."
        }
        /// A row Ben chose **Skip** on.
        static let leftAloneSkipped = "Left alone: you chose Skip."
        /// G9 after BitLocker's **No**, which Winbar remembers for the VM.
        static let keptBitLocker = "Left alone: you chose to keep BitLocker on."

        /// A recipe sentence without its check codes: "Remote Desktop is on (G6)" reads as "Remote
        /// Desktop is on" in the window, which names rows by title. The CLI keeps the codes.
        static func plain(_ text: String) -> String {
            text.replacingOccurrences(of: #" \((?:[GHC][0-9]+(?:, )?)+\)"#, with: "", options: .regularExpression)
        }

        /// A manual row's **Open** button, named for where it goes. H6's opens Time Machine's settings
        /// (the check's `guide`), where UTM's folder is added to the exclusions; the Windows rows'
        /// open a page on the Windows desktop.
        static func bGuide(_ id: String) -> String { id == "H6" ? "Open Time Machine Settings…" : "Open in Windows…" }
        /// A manual row's **Done**, as what Ben says he did. "Done" alone read as "close this".
        static func bDone(_ id: String) -> String { id == "H6" ? "I've Added the Folder" : "I've Done It" }

        /// What VoiceOver says for a row's button: the button and the row it acts on, since every row
        /// has a **Skip** and several a **Fix**, and "Skip, button" five times over says nothing.
        static func spoken(_ button: String, row title: String) -> String {
            switch button {
            case bFix, SetupCopy.bSkip: return "\(button) \(title)"
            case SetupCopy.bCheckAgain: return "Check \(title) again"
            default: return "\(button.replacingOccurrences(of: "…", with: "")), \(title)"
            }
        }

        /// The guest survey's progress line. It used to be a literal inside `Context.surveyGuest`,
        /// behind a check for a terminal; now `Context.progress` carries it, and the terminal's sink
        /// still prints it only to a terminal.
        static let askingWindows = "Asking Windows (this takes a few seconds)…"

        /// A manual step re-read after **Done** that still isn't done, in `Setup.walk`'s words.
        static func still(_ detail: String) -> String { "still: \(detail)" }

        static let bFix = "Fix"
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
        /// "The certificate", as the step bar names it. It was also the connection certificate, the
        /// RDP certificate and the Remote Desktop certificate, one thing under four names.
        static let heading = "Approve the certificate"

        static func result(_ phase: SetupCertificatePage.Phase) -> String {
            switch phase {
            case .needsApproval: return "Your turn: approve on this Mac"
            case .approving: return "Approval in progress"
            case .checking: return "Checking the certificate"
            case .verified: return "Certificate verified"
            case .skipped: return "Approval skipped"
            case .attention: return "Approval not confirmed"
            }
        }
        static let bApprove = "Approve Certificate…"
        static let bApproveInstead = "Approve Instead…"
        static let bRetry = "Try Approval Again…"
        static let bSkip = "Skip for Now"
        static let instructions = "Choose **Approve Certificate…**, then approve in the macOS dialog. If it asks for a "
            + "password, use your Mac login password—not your Windows password."
        static let completion = "Winbar checks the result automatically, and says **Certificate verified** here when it's done."
        static let waiting = "If a macOS approval dialog is open, approve it there; it may be behind another window. "
            + "If you already approved it, wait while Winbar checks the result. You don't need to choose "
            + "**\(bApprove)** again."
        static let checking = "No action is needed while Winbar checks. The result will appear here."
        static let verifiedNext = "This step is complete."
        static let skippedDetail = "The certificate isn't approved on this Mac, so Windows App may warn about it when you connect."
        static let skippedNext = "Choose **Continue Without Approval** to move on, or **\(bApproveInstead)** to approve it now."
        /// A skipped certificate with nothing to approve right now (the VM stopped, or Windows has no
        /// certificate for the name yet): the Skip taken back, and the step read again, which then
        /// says what it's waiting for. Without it the page was a dead end.
        static let bCheckAgainInstead = "Check the Certificate Again"
        static let skippedNoApproval = "Choose **Continue Without Approval** to move on, or **\(bCheckAgainInstead)** to take "
            + "the step up again."
        /// What happened, in each problem state; what to do about it is `next(_:)`'s, one action per
        /// state. Every one of them used to end on the same three-way sentence ("Check Again to
        /// recheck, try approval if available, or choose Skip for Now").
        static let stopped = "Winbar stopped waiting, so the approval isn't confirmed. If macOS's dialog is still open, "
            + "it may be behind another window."
        static let notVerified = "macOS finished the request, but Winbar can't see the certificate as trusted. A finished "
            + "request alone doesn't mean it worked."
        static let notRunning = "Windows isn't running, so there's no certificate to approve yet. Start the VM in UTM, "
            + "then choose **\(SetupCopy.bCheckAgain)**."

        /// The page's one next action, in words that name its button (`SetupCertificatePage.Next`).
        static func next(_ page: SetupCertificatePage) -> String {
            switch (page.phase, page.next) {
            case (.approving, _): return waiting
            case (.checking, _): return checking
            case (.verified, _): return verifiedNext
            case (.skipped, _): return page.canApprove ? skippedNext : skippedNoApproval
            case (.needsApproval, .approve): return completion
            case (.needsApproval, _): return notRunning
            case (.attention, .approve(let title)): return "Choose **\(title)** and approve in the macOS dialog."
            case (.attention, .checkAgain): return "Choose **\(SetupCopy.bCheckAgain)**."
            case (.attention, .goBack): return goBack
            case (.attention, .none): return ""
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

        static let noCertificate = "Windows doesn't have the certificate for this name yet."
        /// The corner's button when the certificate is made one step back: the VM step's **Go Back to
        /// Look Around** in the same words. The card said "Choose **Back**" over a footer with no
        /// filled button, so Return did nothing on a page that asked Ben to act.
        static let bGoBack = "Go Back to Tune"
        /// The tune row's own title, so Ben can find it: the window's name for the row, not its code.
        static let goBack = "Choose **\(bGoBack)** and let Winbar make it: it's the **\(Tune.title("G7", recipe: ""))** row on "
            + "the Tune step."
    }

    /// Name the destination or the consequence of moving on. Enabling a generic Continue after
    /// Skip must not look like confirmation that the skipped work succeeded.
    ///
    /// The destination is the step bar's own name for it (`continueTo`). The buttons had names of
    /// their own: "Continue to Windows App" led to Saved PC, "Continue to Connection Test" to
    /// Connect, and Look around and The VM said only "Continue".
    static func journeyNext(_ step: WizardStep, facts: SetupFlow.Facts?) -> String {
        switch step {
        case .welcome: return LookAround.bContinue
        case .lookAround: return continueTo(.vm)
        case .vm: return continueTo(.tune)
        case .tune: return continueTo(.certificate)
        case .certificate:
            if let facts, facts.kind("H7") != .ok, facts.answers.leftAlone.contains("H7") {
                return "Continue Without Approval"
            }
            return continueTo(.savedPC)
        case .savedPC: return continueTo(.connect)
        case .connect:
            return facts?.answers.connected == true ? continueTo(.finish) : "Continue Without Connecting"
        case .finish: return bDone
        }
    }

    /// Beside a journey step's greyed-out Continue, what it waits for: the step's own question or
    /// action, which the page shows. Nil where Continue can be pressed.
    static func notYetReason(_ step: WizardStep, facts: SetupFlow.Facts?) -> String? {
        guard let facts, !SetupFlow.isSatisfied(step, facts) else { return nil }
        switch step {
        case .tune:
            let count = SetupTuneGroups(facts).needsYou.count
            return count == 1 ? "1 setting needs you" : "\(count) settings need you"
        case .certificate: return "Approve the certificate or skip it first"
        case .savedPC: return "Save the PC or skip it first"
        case .connect:
            if case .didItWork = SetupFlow.connect(facts) { return "Answer Yes or No first" }
            return "Test the connection first"
        default: return nil
        }
    }

    /// "Continue to Saved PC": a Continue that names where it goes, in the step bar's words. Title
    /// case keeps an article lower-case mid-title, so The VM is "Continue to the VM".
    static func continueTo(_ step: WizardStep) -> String {
        let name = stepBarName(step)
        return "Continue to " + (name.hasPrefix("The ") ? "the " + name.dropFirst(4) : name)
    }

    /// "Go Back to Saved PC": the way back to a step, in the step bar's words, as the certificate's
    /// **Go Back to Tune** and the VM step's **Go Back to Look Around** are.
    static func goBackTo(_ step: WizardStep) -> String {
        let name = stepBarName(step)
        return "Go Back to " + (name.hasPrefix("The ") ? "the " + name.dropFirst(4) : name)
    }

    // MARK: - Step 5: The saved PC

    enum SavedPC {
        /// Why the saved PC can't be saved yet, as a status line, what to do, and the button that does
        /// it (`SetupJourneyActions`). The account name is the usual one: Windows only says it once
        /// someone has signed in, which Ben does on Windows' own screen, so that is the button.
        struct NotYet: Equatable {
            var title: String
            var body: String
            var showsWindowsScreen: Bool
        }
        static func notYet(host: String?, user: String?) -> NotYet {
            if host == nil {
                return NotYet(title: "Winbar doesn't know Windows' name yet",
                              body: "Windows says its network name once it has started up. Choose **\(SetupCopy.bCheckAgain)** "
                                  + "in a minute, or skip saving and type the details into Windows App yourself.",
                              showsWindowsScreen: false)
            }
            if user == nil {
                return NotYet(title: "Your turn: sign in to Windows",
                              body: "Winbar learns your Windows account's name once someone has signed in. Choose "
                                  + "**\(bShowWindowsScreen)**, sign in to Windows there, then come back here: Winbar "
                                  + "checks again by itself.",
                              showsWindowsScreen: true)
            }
            return NotYet(title: "The saved PC hasn't been checked yet",
                          body: "Choose **\(SetupCopy.bCheckAgain)**, or skip saving it.", showsWindowsScreen: false)
        }
        /// Brings UTM forward, where the VM's window is Windows' screen. The menu's item of a similar
        /// name adds a screen to a VM that has none, which restarts it; at this step the VM still has
        /// its screen, so there's nothing to add, only a window to show.
        static let bShowWindowsScreen = "Show Windows' Screen"
        static let bSkipSaving = "Skip Saving the PC"
        static let bSkipWindowsApp = "Skip Windows App"
        static let bOpenAppStore = "Open the App Store"
        /// Where the step goes without a saved PC, in the step bar's words (`continueTo`): "Sign-in"
        /// named no step, and the sign-in happens at Connect.
        static let bContinueToSignIn = continueTo(.connect)
        static let bContinueToSignInInstead = continueTo(.connect) + " Instead"
        /// "The saved PC", one name: this said "the Connection" for the thing the step calls the PC.
        static let bSavedItMyself = "I've Saved the PC"
        /// The card's line while the field waits, and the fold for saving it by hand.
        static let yourTurn = "Your turn: save the PC"
        static let saveItYourself = "Save the PC yourself"
        /// When Windows App won't let Winbar save it: what happened, as a status line.
        static let manualTitle = "Winbar couldn't save the PC"

        static let installWindowsApp = "Choose **\(bOpenAppStore)** and install Windows App there. When its button says "
            + "**Open**, come back here: Winbar checks for it by itself."
        static let manual = "You can still connect: Windows App asks for your Windows user name and password when you do. "
            + "Your Mac password and Windows PIN won't work there."
        static let manualNext = "Choose **\(bContinueToSignIn)**, or **\(SetupCopy.bTryAgain)** to have Winbar save it once more."
        /// Opens Windows App itself, never its command line (C2's `guide`).
        static let bOpenWindowsApp = "Open Windows App"

        /// Windows App's command line didn't answer (`SetupFlow.commandLineSilent`): what that is, whose
        /// problem it is, and what it costs, plainly. The card said "Winbar couldn't save the PC", with
        /// the reason in the terminal's words under a fold, so it read as something the person had got
        /// wrong. How to save it by hand is C2's own `how` (`WindowsAppBookmarks.Copy.byHand`), shown
        /// once, beside `editInstead`.
        static let silentTitle = "Windows App's command line isn't responding"
        static let silent = "Windows App's command line isn't responding on this Mac. That's a problem in Windows App, "
            + "not in your setup, and it means Winbar can't save the PC for you or see whether one is saved already."
        static let silentNext = "Save the PC in Windows App yourself, then choose **\(bSavedItMyself)**. Or choose "
            + "**\(bContinueToSignIn)**: Windows App asks for your Windows password when you connect."
        /// After the steps for adding the PC: a PC Windows App already has for this name is changed, not
        /// doubled — two tiles for one name leave Connect pressing either.
        static func editInstead(host: String, user: String?) -> AttributedString {
            guard let user else {
                return fill("If Windows App already has a PC called \(host), edit that one instead of adding another.")
            }
            return fill("If Windows App already has a PC called \(host), edit that one instead of adding another, so "
                        + "it signs in as \(user).")
        }
        static let saved = "This step is complete."
        /// The skipped page's way back (`SetupCommand.revisit`): the page had nothing on it to press,
        /// though Windows App might answer a second time.
        static let bTrySavingAgain = "Try Saving Again"
        static let skipped = "You can add it later in Windows App, or choose **\(bTrySavingAgain)** now."
        static let skippedTitle = "Saved PC skipped"
        /// Skipped with Windows App: saving again starts with installing it, which the step then offers.
        static let windowsAppSkippedTitle = "Windows App skipped"
        static let windowsAppSkipped = "Winbar opens Windows with Windows App, which isn't on this Mac yet. Choose "
            + "**\(bTrySavingAgain)** to install it and save the PC."
        /// Under the field: when the step is done, since that's the other question on this page.
        static let afterSaving = "Winbar saves it in Windows App and says **\(savedAnnouncement)** here."

        /// Neutral: the step is often only checking, or the PC is already saved, and "Saving…" said
        /// otherwise. What is happening right now is `busy(_:)`'s to say.
        static let heading = "The saved PC in Windows App"
        /// The card's status once the save is confirmed, and what VoiceOver hears then. "PC saved" was
        /// one more name for the saved PC; this is the step's own, with its state after it, the way
        /// **Certificate verified** reads.
        static let savedAnnouncement = "Saved PC ready"

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
        /// What to type and press, first: the reasoning is behind **Where this password goes**.
        static func lead(user: String) -> AttributedString {
            fill("Type the Windows password for \(user), then choose **Save It**. Windows App keeps it, so Connect "
                 + "doesn't ask every time.")
        }

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
        /// Beside **Save It** while the field is empty.
        static let typeFirst = "Type the password first"

        /// Windows App is running, so a save could corrupt its database. The refusal is the one
        /// `WindowsAppBookmarks` already gives, then what the window's buttons are for.
        /// Winbar looks at the step again once Windows App has quit (`WindowsAppQuitter`,
        /// `SetupWindowController.windowsAppQuit`), so the one button is the quit: "then **Check
        /// Again**" asked for a press the window now makes itself.
        static let appOpen = "Windows App is open, and Winbar can't save the PC while it is. Choose **\(bQuitWindowsApp)**."
        /// Why, one click away (`SetupJourneyView`'s **Details**): the refusal `WindowsAppBookmarks` gives.
        static let appOpenWhy = WindowsAppBookmarks.Copy.quitFirst
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
                             + "Windows App's page, and you choose Get there yourself. It's about "
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
        /// The card's one sentence; `accessibility` is its **Details**.
        static let accessibilityLead = "Winbar opens your saved PC by pressing its tile in Windows App, which needs "
            + "Accessibility access. Choose **\(bAllowAccessibility)**, switch on Winbar in System Settings, then come back "
            + "here: Winbar checks by itself."
        static let bUseOneOff = "Use a One-off Connection"

        /// The ready card: what to press and what happens, then the one thing about Local Network Ben
        /// has to act on. The 60 words of why were first on the card, before "Choose Connect"; they are
        /// its **Details** now (`localNetwork`).
        static let readyLead = "Choose **\(bConnect)**. When Windows App opens, sign in there if it asks, then come back "
            + "and say whether you see the Windows desktop."
        static let localNetworkLead = "If macOS or Windows App asks to find devices on your local network, choose **Allow**."

        /// Local Network: the RDP readiness probe is Winbar's only local-network traffic. The spec also
        /// promised "Connect works either way". The code means it to — a denied probe reads as
        /// `.blocked`, which Connect goes ahead on — but telling a denial from a VM still booting is
        /// `RDP.looksDenied`'s heuristic, and the probe's own comment says it hasn't been seen live
        /// against a denied grant. If it misreads, Connect waits two minutes and gives up. Until that is
        /// measured, the deck says what the grant is for and nothing it can't stand behind.
        static let localNetwork = "macOS may ask whether Winbar can find and connect to devices on your local "
            + "network. Winbar uses that only to check whether Windows is ready for Windows App to connect. The first "
            + "time, Windows App may ask the same about itself; choose **Allow**, or it can't reach the VM."
        /// Only on the recovery card's `.blocked` branch: the one case where the evidence points at the
        /// Local Network setting. Windows App asks for the same access separately, so both are named.
        static let networkRecovery = "Choose **\(bOpenLocalNetworkSettings)** (System Settings → Privacy & Security → "
            + "Local Network), turn on Winbar, and Windows App too: it needs the same access to reach the VM. Then come "
            + "back and choose **\(bTryAgain)**."
        /// Where Local Network's switches are. The card said where in words; this goes there.
        static let bOpenLocalNetworkSettings = "Open Local Network Settings…"

        /// The recovery card after **No, something's wrong** (or a Connect that failed): a heading, the
        /// steps in Markdown, and whether to offer closing setup for the menu's **Bring Back Windows' Screen…**.
        /// The view draws `recovery(_ diagnosis:)`, so the card is worked out from the facts alone.
        struct Recovery: Equatable {
            var heading: String
            var steps: [String]
            var offersConsole = false
            /// The retry its steps name in bold: the footer's filled corner, which Return presses
            /// (`SetupJourneyActions.footerAction`), or the card's plain one beside **Open Local Network
            /// Settings…**. The footer's Continue Without Connecting held both once, so Return skipped the
            /// one step that proves the setup works; and the unchecked card said "Choose Check Again"
            /// above a button labelled Try Again, which only reopens Windows App without the port check
            /// it asked for. One value for the words and the button, so they can't disagree again.
            var retry: Retry = .tryAgain
            /// The corner is **Open Local Network Settings…** and the retry waits in the card: when macOS
            /// refused the check, a retry before the setting changes can only be refused again.
            var opensLocalNetwork = false
        }

        /// **Try Again** redoes the connection (`SetupCommand.retryConnection`); **Check Again** reads the
        /// port again without opening anything, which is what a card with no reading needs first.
        enum Retry: Equatable {
            case tryAgain, checkAgain

            var title: String { self == .tryAgain ? bTryAgain : SetupCopy.bCheckAgain }
            /// What pressing it sends: the connection again, or a read of the port.
            var command: SetupCommand { self == .tryAgain ? .retryConnection : .perform(.run(.checkAgain(.connect))) }
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
        /// a headless VM (H5 ok) is watched through the menu's **Bring Back Windows' Screen…**, one with its
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
                                steps: ["macOS stopped Winbar's check of the VM, which is what it does when Local "
                                            + "Network access is off. So Winbar can't tell whether Windows is ready.",
                                        networkRecovery],
                                opensLocalNetwork: true)
            case .notReady?:
                return Recovery(heading: "Windows isn't answering yet",
                                steps: ["Windows didn't answer Winbar's check just now, so it's most likely still "
                                            + "starting, restarting or installing updates.",
                                        "Wait until Windows has finished and shows its sign-in screen or desktop, "
                                            + "then choose **\(bTryAgain)**.",
                                        watchWindows(console)],
                                offersConsole: console != .onScreen)
            case .ready?:
                return Recovery(heading: "Windows is answering; the sign-in is what's left",
                                steps: ["Windows answered Winbar's check, so the problem is in Windows App or the "
                                            + "sign-in.",
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
                                steps: ["Winbar hasn't checked whether Windows is answering since this connection. "
                                            + "Choose **\(Retry.checkAgain.title)**, and Winbar then says what to try."],
                                retry: .checkAgain)
            }
        }

        /// Under Connect's own wait.
        static let openingIsNotProof = "Opening Windows App alone doesn't prove the connection works: Winbar asks next "
            + "whether you see the Windows desktop."

        static let bAllowAccessibility = "Allow Accessibility"
        static let bConnect = "Connect"

        static let waiting = "Waiting for Windows…"
        static func opening(host: String) -> AttributedString { fill("Opening \(host) in Windows App…") }

        static let didItAppearHeading = "Did the Windows desktop appear?"
        static let openedConnection = "Winbar opened a connection in Windows App. If the Windows desktop appeared, "
            + "the connection works. If the saved PC couldn't be opened, Windows App may ask for your password."
        static let afterRestart = "The VM restarted with your changes. Choose **\(bConnect)** once more to check that its "
            + "desktop still opens."
        /// The menu item that gives a VM in the background its screen back, by the name the menu gives it
        /// (`MenuCopy.bringBackScreen`), with **Close Setup**, the card's button that comes with this advice
        /// (`Recovery.offersConsole`), first. It said "console screen" and **Show Console Window…**.
        static let recoverConsole = "This VM runs in the background, with no screen of its own. To see what Windows is "
            + "doing, choose **\(bCloseSetup)**, then **\(MenuCopy.bringBackScreen)** in Winbar's menu. **\(menuItem)** "
            + "in the same menu brings this window back."
        static let recoverOnScreen = "The VM's window in UTM shows what Windows is doing."
        /// H5 unread: true of a VM with a screen and of one without, in the Connect error's own terms.
        static let recoverEither = "If the VM has a window in UTM, it shows what Windows is doing. If it runs in the "
            + "background, choose **\(bCloseSetup)**, then **\(MenuCopy.bringBackScreen)** in Winbar's menu. "
            + "**\(menuItem)** in the same menu brings this window back."
        /// Closes the window so the menu can be used, with the advice above.
        static let bCloseSetup = "Close Setup"
        /// A connection that timed out waiting for Windows: the runner's error, in the words the
        /// recovery card uses. It said "port 3389" and **Show Console Window…**.
        static let timedOutTitle = "Windows isn't answering yet"
        static let timedOut = "Windows didn't answer within two minutes. Check Windows in UTM, then choose Try Again. "
            + "If the VM runs in the background, choose Close Setup, then \(MenuCopy.bringBackScreen) in Winbar's menu."
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
        /// quoted one (“Windows 11”), and `summary` is `ConfigChanges.summary` either way. The window
        /// says it in its own words (`restartLine`); this stays the progress line both print while the
        /// restart runs, which Terminal's users read in its terms.
        static func oneRestart(of vm: String, applies summary: String) -> String {
            "One restart of \(vm) applies: \(summary)."
        }

        // MARK: The choice

        /// The page's title while it asks. The question is the page: the step's name ("Finish") said
        /// nothing about what to decide.
        static let choiceHeading = "How should Windows run?"

        /// The two tiles. "Headless" is a word the person reading this doesn't have (the owner's call,
        /// 0.2.1): it names what the VM lacks, where these name what the person gets. The CLI's
        /// `--headless` and `winbar display` keep theirs.
        static let bBackground = "Run in the Background"
        static let bKeepScreen = "Keep Windows' Screen"
        static let recommended = "Recommended"

        /// The saving. It was "about two thirds lower" of idle host CPU, which is true (re-measured
        /// 2026-09-21: a median 0.5 CPU-seconds a minute against 1.7), but both are a small fraction
        /// of one core, and a fraction of a fraction asks the reader to do sums to learn it's small.
        /// The README keeps the figure. Remote Desktop being the only way in is the other half: the
        /// person has just watched it work, which is the only reason it is offered.
        static let backgroundBody = "No window of its own. You open Windows with Windows App, the way you just did. "
            + "It uses a little less of your Mac's power."
        static let keepBody = "UTM keeps a window showing Windows' own screen, as it does now."

        /// The rule both ways, stated rather than a list of VMs that could be stale by the time it's read
        /// (COHERENCE C2): a display change restarts UTM, and that stops every VM it runs. The way back
        /// is named as the menu names it (`MenuCopy.bringBackScreen`), so it stays true whatever the menu
        /// calls it: "Winbar's menu can switch it back later" left the owner asking for a way to give the
        /// VM its screen back, which the menu already had. It doesn't say "at any time", since the way
        /// back has the same rule.
        static let choiceRule = "Switching either way restarts UTM, which stops every VM it's running, so Winbar "
            + "only does it while this is the only one. If you choose the background, **\(MenuCopy.bringBackScreen)** "
            + "in Winbar's menu switches it back later, the same way."

        /// In place of the choice when another VM is running, or UTM wouldn't say (COHERENCE C2), and
        /// under the refusal itself: `otherVMsRefusal`'s title where the heading goes and its detail
        /// as the body, both from `Reconfigure` and both verbatim, so the window, the menu and the CLI
        /// give one answer in one set of words. The deck keeps no copy of them; these are only the
        /// window's own words about what is left: **Check Again**, or finishing as it is. There are no
        /// tiles in this state, since **Run in the Background** could only end on that refusal.
        ///
        /// The refusal's detail names the other VMs, so the view shows it as plain text
        /// (`Text(verbatim:)`), the way it shows the lines shared with Terminal.
        static let afterRefusal = "Choose **\(SetupCopy.bCheckAgain)** once they've stopped. Or finish with Windows' "
            + "screen as it is: Winbar's menu can switch it later, and checks the same thing first."
        static let couldNotConfirm = "Winbar couldn't confirm that it is safe to restart UTM."

        /// Instead of the choice, when the person said the desktop didn't appear and the VM still has
        /// its screen (a VM `create` already put in the background has nothing to offer either way).
        ///
        /// The spec's "Fix Connect first, then open this window again", which the window couldn't say
        /// while the menu had no way back to it. It has one now (`SetupWindow.availableToEveryone`).
        static let notOffering = "Winbar isn't offering to run Windows in the background, because Remote Desktop "
            + "hasn't worked yet, and in the background it's the only way in. Fix Connect first (choose "
            + "**\(SetupCopy.bBack)**), then come back here, or choose **\(SetupCopy.menuItem)** in the menu later."
        static let alreadyInBackground = "Windows already runs in the background, with no window of its own."
        static let notReady = "Windows keeps its screen: Remote Desktop isn't ready for it to run in the background."
        static let checking = "Checking whether Windows can run in the background…"

        // MARK: The restart

        /// The footer's corner while a restart is owed: the background chosen, or processor cores or
        /// memory staged on Tune. It restarts, and Winbar then asks once more whether Windows opens,
        /// since the restart is exactly what could stop it.
        static let bRestartAndFinish = "Restart and Finish"
        /// The corner once nothing is owed.
        static let bFinish = "Finish"
        /// Drops what is staged and finishes, in one press: it used to be **Discard Changes and Finish
        /// Without Restarting**, which only discarded, and left a greyed-out Done to find.
        static let bFinishWithoutRestarting = "Finish Without Restarting"

        /// The restart in the window's words: `ConfigChanges.summary` says "6 vCPUs, headless", which is
        /// Terminal's vocabulary. Pure.
        static func restartLine(vm: String, _ changes: ConfigChanges) -> String {
            "Finishing restarts “\(vm)” once to apply: \(summary(changes))."
        }

        static func summary(_ changes: ConfigChanges) -> String {
            var parts: [String] = []
            if let cores = changes.cpuCores { parts.append("\(cores) processor \(cores == 1 ? "core" : "cores")") }
            if let memory = changes.memoryMB {
                parts.append(memory % 1024 == 0 ? "\(memory / 1024) GB of memory" : "\(memory) MB of memory")
            }
            switch changes.display {
            case .headless: parts.append("running in the background")
            case .console: parts.append("Windows' screen back on")
            case nil: break
            }
            switch changes.sharedFolder {
            case .folder(let path): parts.append("sharing \(SharedFolder.abbreviate(path))")
            case .off: parts.append("no shared folder")
            case nil: break
            }
            return CreateCopy.list(parts)
        }

        /// Only once a restart has been tried and stopped: the failure's own words are above it, and
        /// this says what is left. It used to sit under every staged restart as a warning in advance,
        /// "If Winbar can't verify BitLocker or Windows won't shut down, it stops safely", about a
        /// case that hadn't happened.
        static let restartStopped = "Winbar stopped rather than restart unsafely, and the changes are still waiting. "
            + "Choose **\(bRestartAndFinish)** to try again, or **\(bFinishWithoutRestarting)** to keep Windows as it "
            + "is now."

        // MARK: Done

        /// Only when the desktop appeared. After a **No**, or with Windows App skipped, Connect is
        /// exactly the part that hasn't worked, and the page says so rather than calling it ready.
        static let readyHeading = "Windows is ready"
        static let almostHeading = "Almost done"
        static let bOpenWindows = "Open Windows"
        static let bTryConnectingAgain = "Try Connecting Again"

        /// How step 6 ended. A Bool couldn't say the others: Windows App skipped, so Connect was never
        /// tried — and the ready sentence ("Open Windows …") would then be untrue — and Windows App
        /// installed since, so Connect can be tried but hasn't been. "Try Connecting Again … once more"
        /// was said then, about an attempt that never happened.
        enum Outcome { case connected, notConnected, notTried, windowsAppSkipped }

        static func outcome(_ facts: SetupFlow.Facts) -> Outcome {
            if facts.answers.connected == true { return .connected }
            if SetupFlow.windowsAppSkipped(facts) { return .windowsAppSkipped }
            return facts.answers.connected == false ? .notConnected : .notTried
        }

        /// The finished page's Connect when it hasn't been tried: what the Connect step calls it.
        static let bConnect = Connecting.bConnect
        /// The finished page's corner once Windows App is here after it was skipped: the saved PC step
        /// the skip passed over, named as every way back to a step is (`goBackTo`, "Go Back to Tune").
        static let bGoBackToSavedPC = SetupCopy.goBackTo(.savedPC)

        static func heading(_ outcome: Outcome) -> String { outcome == .connected ? readyHeading : almostHeading }

        /// On the finished page when the VM runs in the background (`SetupFinishPage.runsInBackground`):
        /// where its screen is, by the menu item's own name.
        static let inBackground = "Windows runs in the background, with no window of its own. To see its screen, "
            + "choose **\(MenuCopy.bringBackScreen)** in Winbar's menu."

        /// Over the finished page's list of the steps passed over (`SetupFinishPage.passedOver`): what
        /// VoiceOver says of the step bar's warning marks too (`stepBarFlagged`).
        static let passedOverHeading = "Skipped or not confirmed"

        /// A step's line in that list: the step bar's hover words for it (`SetupCopy.passedOver`), as
        /// a sentence. Pure.
        static func passedOverLine(_ words: String) -> String {
            guard let first = words.first else { return words }
            return first.uppercased() + words.dropFirst() + (words.hasSuffix(".") ? "" : ".")
        }

        /// The one sentence under the heading, naming the VM, and the reopen line under it when the
        /// menu offers **Set Up Winbar…**.
        static func doneBody(vm: String, connected: Bool) -> [AttributedString] {
            doneBody(vm: vm, connected ? .connected : .notConnected)
        }

        static func doneBody(vm: String, _ outcome: Outcome, canReopenFromMenu: Bool = true) -> [AttributedString] {
            let ready: Filled = "“\(vm)” is set up. From now on, choose **Connect** in Winbar's menu to open it."
            // The button's name written out, not interpolated: an interpolation is a value, and a value's
            // text is never Markdown (`Filled`), so the bold around it would show as asterisks.
            let tuned: Filled = "“\(vm)” is tuned, but Windows hasn't opened on this Mac yet. "
                + "Choose **Try Connecting Again** to test it once more."
            let untried: Filled = "“\(vm)” is tuned, and Windows App is here now. Choose **Go Back to Saved PC** to save "
                + "your Windows password in it, then test that Windows opens on this Mac."
            let noApp: Filled = "“\(vm)” is tuned. Winbar opens it with Windows App, which isn't installed. "
                + "It's free: choose **Open the App Store** to get it."
            let first: Filled
            switch outcome {
            case .connected: first = ready
            case .notConnected: first = tuned
            case .notTried: first = untried
            case .windowsAppSkipped: first = noApp
            }
            var lines = [fill(first)]
            if canReopenFromMenu {
                lines.append(markdown(outcome == .connected
                    ? "To run this window again, choose **Set Up Winbar…** in the menu. It changes nothing that's already "
                        + "right."
                    : "To pick up where this leaves off, choose **Set Up Winbar…** in the menu."))
            }
            return lines
        }
    }

    // MARK: - winbar setup --window

    /// What the terminal says when it hands the window over to Winbar.app. Plain text: Terminal
    /// prints it.
    enum HandOff {
        /// Said first by `winbar setup` in a terminal: the same set-up exists as a window.
        static let windowTip = "Prefer a window? Run winbar setup --window, or choose \(menuItem) in Winbar's menu bar menu."
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
            case .checkAgain, .lookAgain: return "looking at what's on this Mac"
            case .installUTM: return "installing UTM"
            case .installWindowsApp: return "opening Windows App in the App Store"
            case .settleUTM: return "waiting for UTM to answer"
            case .chooseVM(let name, _): return "choosing “\(name)”"
            case .startVM(let name): return "starting “\(name)”"
            case .survey: return "asking Windows how it's set up"
            case .fix(let id): return "fixing \(named(id))"
            case .fixEverything: return "fixing what Winbar can fix"
            case .recordDone(let id): return "checking \(named(id)) again"
            case .guide(let id):
                switch id {
                case "H6": return "opening Time Machine settings"
                case "C2": return "opening Windows App"
                case "C3": return "opening Accessibility settings"
                default: return "opening \(named(id)) in Windows"
                }
            case .keepBitLocker: return "remembering to keep BitLocker on"
            case .discardChanges: return "discarding the staged changes"
            case .trustCertificate: return "waiting for you to approve the certificate in the macOS dialog"
            case .savePC: return "saving the PC in Windows App"
            case .connect: return "opening the desktop in Windows App"
            // The spec's own example for the quit guard.
            case .applyChanges: return inFlight.vm.map { "restarting “\($0)”" } ?? "restarting the VM"
            }
        }

        /// A row by the name the Tune page shows it under: the quit prompt said "fixing G1 (Power
        /// plan)", and the code is `winbar setup`'s, never the window's.
        private static func named(_ id: String) -> String {
            Recipe.check(id).map { Tune.title(id, recipe: $0.title) } ?? "a setting"
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
                return "It can open behind other windows; approve it there, or choose **\(bStopWaiting)** and approve "
                    + "it later."
            case .automationPrompt:
                return "If macOS asks whether \(host) may control UTM (its prompt says "
                    + "\(Automation.promptWords(host: host)), and it can open behind other windows), choose **Allow** there."
            }
        }

        static let bStopWaiting = "Stop Waiting"

        /// Over a card a page keeps while a read nobody pressed runs (`QuietReadLine`).
        static let lookingAgain = "Checking again…"

        /// A start's progress line, in the window's words. `Setup.waitForWindows` says Terminal's,
        /// which name the guest agent, a word Ben doesn't have; the lines are matched, not reworded at
        /// the source, so Terminal keeps its own. Anything else is shown as it was said.
        static func windowLine(_ line: String) -> String {
            switch line {
            case SetupCopy.waitingForWindows: return startWaiting
            case SetupCopy.agentNotYet: return startSlow
            default: return line
            }
        }
        static let startWaiting = "Waiting for Windows to start. This can take up to three minutes."
        static let startSlow = "Windows is taking longer than usual to start. Winbar is still checking…"
        /// Beside **Stop Waiting** on the VM step: what stopping does, and doesn't.
        static let stopStart = "Windows keeps starting if you stop waiting."
        /// Beside it on the certificate: stopping ends Winbar's wait, not macOS's dialog, which isn't
        /// Winbar's to close (`whereToLook`).
        static let stopApproval = "macOS's dialog stays open if you stop waiting."
        /// Beside it on Connect, whose wait is for Windows to take Remote Desktop before Windows App
        /// is opened: stopping means no desktop this time, and nothing more.
        static let stopConnect = "Winbar won't open the desktop if you stop waiting. Windows carries on starting."
        /// Beside it on Finish, during the restart: the restart itself can't be cut short.
        static let stopRestart = "The restart carries on either way; stopping only ends Winbar's wait for Windows afterwards."

        /// What stopping a wait does, said beside **Stop Waiting** wherever it is drawn: nil for work
        /// that can't be stopped (`Work.canStopWaiting`).
        static func stopConsequence(_ work: SetupRunner.Work) -> String? {
            switch work {
            case .startVM: return stopStart
            case .trustCertificate: return stopApproval
            case .connect: return stopConnect
            case .applyChanges: return stopRestart
            default: return nil
            }
        }

        /// A press the runner turned down because something else is in flight. Names what that is, and
        /// when it's waiting on the person, where to look. It says the press didn't start and to choose
        /// it again: "This can go ahead once that's done" read as a promise that it would, and nothing
        /// ever did — the runner refuses, it doesn't queue (`SetupRunner`).
        static func refusal(_ inFlight: SetupRunner.InFlight, host: String = Automation.host.name) -> AttributedString {
            let busy: Filled = "Winbar is still \(doing(inFlight)), and it does one thing at a time"
            guard let waiting = inFlight.waitingFor else {
                return fill(busy + ", so what you chose didn't start. Choose it again once that's done.")
            }
            return fill(busy + ".") + AttributedString(" ") + markdown(whereToLook(waiting, host: host))
        }

        /// A refusal as the page says it for as long as it stands (`SetupWindowState.refusal`): the
        /// app's gate's own words when it was the gate, until the gate has been free since
        /// (`Refusal.reasonPassed`); what is still running, while something is (`refusal(_:host:)`, for
        /// what runs now, which may be the read after the work it was refused for); and once nothing
        /// runs, what it was doing then and to choose again — "Winbar is still …" would be untrue by
        /// then, and the press still didn't start. The gate's refusal names what held it only in its
        /// own words, so its past tense says only that Winbar was busy.
        static func refused(_ refusal: SetupRunner.Refusal, busy: SetupRunner.InFlight?,
                            host: String = Automation.host.name) -> AttributedString {
            if let reason = refusal.reason, !refusal.reasonPassed { return AttributedString(reason) }
            if let busy { return self.refusal(busy, host: host) }
            if refusal.reason != nil { return AttributedString(refusedWhileBusy) }
            return fill("Winbar didn't start that: it was \(doing(refusal.inFlight)) at the time. Choose it again.")
        }

        /// A press the app's gate turned away, said once the work that held the gate has finished.
        static let refusedWhileBusy = "Winbar didn't start that: it was busy with something else at the time. Choose it again."


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
    /// filler. So is "No translating.", a Rosetta joke for people who know what Rosetta is.
    ///
    /// Each line is one fact, ending on what it means for Ben, and never what the page already says
    /// beside him: the card's heading, the status line, the stage row. He said "guest agent" under
    /// "Waiting for Windows to start", and on Finish repeated the sentence above him.
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
                // The card already says there's no VM, and names the Arm64 ISO; this is why Arm.
                return "Winbar installs the Arm version of Windows. It's made for this Mac's chip, so it runs quickly."
            case .installing(let stage):
                return installing(stage)
            case .startingWindows:
                // `Setup.waitForWindows` waits up to three minutes for the guest agent, then — only when
                // Windows is set to sign itself in (AutoAdminLogon) — up to 90 s more for explorer.exe.
                // The status line beside him says what's awaited and for how long; he says how it feels.
                return "Windows is waking up. It takes its time. I'll wait."
            case .done:
                // The page above him names the VM and the menu's Connect; he only signs off.
                return "That's the lot. I'll be quiet now."
            case .installingUTM:
                // One line for the whole install, since it stays up for all of it: the download, the
                // copy, Homebrew's "Moving App" and "Linking Binary", and the check at the end. True
                // of both routes the window takes (`Dependencies.windowPlan`): each ends in
                // `DependencyInstaller.verify`, which checks the bundle, its signature, the team and
                // the version before the install counts as done. Not said during an update, where he
                // doesn't appear (`LookAroundPage.armieLine`). "Installing UTM" is the line above him.
                return "Winbar checks this is the real UTM before it calls it installed. I'll watch."
            }
        }

        /// One line per install stage, each saying what that stage really does (CreateJobRun):
        /// preflight reads the ISO and asks UTM for its VMs; every Guest Tools copy, downloaded,
        /// cached or supplied, is checked against the pinned SHA-256; the setup disk holds the answer
        /// file; the VM is created with both disks; the boot watcher answers "Press any key" when the
        /// ISO asks; the oobe stage is the account, region and privacy questions the answer file
        /// answers; the first-logon script runs its steps in turn; and the finish shuts Windows down,
        /// detaches the disks from UTM and starts it again.
        private static func installing(_ stage: CreateStage) -> String {
            switch stage {
            // "Disk", as the stage rows say it ("Made the setup disk"): he said "disc", one more name.
            case .check:
                return "Reading which editions and language are in the ISO, so the right Windows goes in."
            case .guestTools:
                return "These are the drivers Windows needs inside a VM. Winbar checks they're the real ones before "
                    + "they go anywhere."
            case .media:
                return "The setup disk holds the answers to Windows Setup's questions, so nobody has to click through "
                    + "them."
            case .vm:
                return "The new VM gets two disks: Windows, and the answers."
            case .boot:
                return "If the installer asks for a key press, it gets one."
            case .copy:
                // The spec's own example, and the review's model of his tone: it names the stage, but
                // as the setup for the joke, not as news.
                return "Copying files. There are a lot of them. I'll be here."
            case .devices:
                return "Windows is deciding what kind of computer it lives in. It'll be a minute."
            case .oobe:
                return "Windows is asking its first-run questions: account, region, privacy. The setup disk is answering."
            case .firstLogon:
                return "Windows has signed in for the first time and is working through the list Winbar left it, one "
                    + "step at a time."
            case .finish:
                // The whole stage, not its next step: it is shown from the audit to the restart, and "next
                // it shuts down" stopped being true halfway through. The stage row says the disks are detached from UTM.
                return "Windows is installed. One more restart, and it's ready."
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
        /// something, and his line for that stage says the answer disk is answering.
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
