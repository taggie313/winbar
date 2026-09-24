import AppKit
import Foundation

/// **Send a Problem Report…**, for the beta: the report Report a Problem… writes, with a note from the
/// person and what Winbar's windows were showing, sent straight to Winbar's developer with one press.
/// No GitHub account, no email, no file to find and drag into a form.
///
/// Why it exists: the first people to run Winbar are a handful of the developer's friends, on Macs he
/// has never seen, and the failures worth hearing about first are the odd ones — exactly the ones
/// nobody files an issue for. Report a Problem… asks them to read a file, sign in to GitHub and drag
/// it into a page; this asks them what happened and sends it.
///
/// **Taking it out is setting `enabled` to false.** Every way in asks it — the menu bar menu, the Help
/// menu, **Help!** in the title bar of Set Up Winbar and New Windows VM, and **Send This to the
/// Developer** on failure cards — so with it off none of them is drawn and nothing here is reached.
/// Report a Problem… is separate, and stays.
///
/// What it never does: send before **Send** is pressed, send after **Cancel**, send on a keystroke
/// (Send and Try Again take a click; Return is for the note), or send more than one report every
/// `spacing` seconds. The report is Report a Problem…'s own (`Diagnose.collect`, `Diagnose.compose`),
/// redacted by the same `Redactor` with the placeholders box ticked by default, so what reaches the
/// developer is the file a public issue would carry, plus the note and what was on screen.
enum BetaReport {
    /// The switch. See above.
    static let enabled = true

    /// Where a report goes: a topic on the developer's own ntfy server, which lets anyone write to it
    /// and only him read it. One `PUT` of the report as the body arrives as a notification with the
    /// report attached. Nothing secret is here or needed: writing is anonymous by design.
    static let endpoint = URL(string: "https://ntfy.elusive.net/winbar-reports")!

    /// For the whole request. A report is a few hundred kilobytes at most; a Mac that can't send that
    /// in half a minute is one to say so to rather than keep waiting on.
    static let timeout: TimeInterval = 30

    /// At most one report this often, counted in the app rather than trusted to the server: a
    /// double-press, or the dialog opened again straight after a send, would otherwise be two
    /// notifications of one problem.
    static let spacing: TimeInterval = 30

    /// ntfy's tags, which let the developer's phone file these apart from everything else on it.
    static let tags = "winbar,beta"

    /// The most of the note that goes into the notification's title. The whole note is in the file.
    static let summaryLength = 80

    /// Where the reports are kept: beside the install logs, not on the Desktop. Writing to the Desktop
    /// is behind a macOS privacy prompt, which would land in the middle of a send; and this file is
    /// kept for the person's reference ("the report is saved at…"), not for them to drag anywhere.
    static var directory: URL { CreateLog.directory.appendingPathComponent("Reports", isDirectory: true) }

    // MARK: - The request

    /// `winbar-report-20260924T153012Z.txt`: UTC, so the developer can line reports from different
    /// time zones up, and sortable. The same name on the Mac and in the notification.
    static func fileName(for date: Date) -> String { "winbar-report-" + utcStamp.string(from: date) + ".txt" }

    /// The note as the notification's title can carry it: one line, with every run of white space or
    /// control characters one space (a newline in a header would end the header), and at most
    /// `limit` characters, cut at a word where there is one. nil for a note with nothing in it.
    ///
    /// Given the note already redacted, never the raw one. The cut is at a space, and a VM's name can
    /// have spaces in it ("Windows 11 for the desk"), so a title cut from the raw note could end in the
    /// front half of one — no longer the name the redactor looks for — and it would go out in the title
    /// of a report whose body had it replaced (`Diagnose.trim` explains the same trap). Pure.
    static func summary(of note: String, limit: Int = summaryLength) -> String? {
        let scalars = note.unicodeScalars.map { scalar -> Unicode.Scalar in
            CharacterSet.whitespacesAndNewlines.contains(scalar) || CharacterSet.controlCharacters.contains(scalar)
                ? " " : scalar
        }
        let line = String(String.UnicodeScalarView(scalars))
            .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        guard !line.isEmpty else { return nil }
        guard line.count > limit else { return line }
        var cut = String(line.prefix(limit - 1))
        // Back to the last whole word, unless that throws most of the line away.
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) >= limit / 2 {
            cut = String(cut[..<space])
        }
        return cut + "…"
    }

    /// The notification's title. Pure.
    static func title(version: String, summary: String?) -> String {
        "Winbar \(version) report" + (summary.map { ": " + $0 } ?? "")
    }

    /// A header value that survives the trip: as it is when it is plain ASCII, and otherwise as an RFC
    /// 2047 encoded word, which ntfy decodes. CFNetwork sends a header's bytes as it likes, and a note
    /// in any language but English — or the "…" `summary` ends a long one with — is not ASCII. Pure.
    static func headerValue(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { !$0.isASCII || $0.value < 0x20 || $0.value == 0x7F }) else { return text }
        return "=?UTF-8?B?" + Data(text.utf8).base64EncodedString() + "?="
    }

    /// The one request a report is: a `PUT` of the report as it was written to disk, named for that
    /// file, titled with the version and the note's first words, and tagged. Pure.
    static func request(report: String, fileName: String, summary: String?, version: String,
                        endpoint: URL = endpoint) -> URLRequest {
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "PUT"
        request.httpBody = Data(report.utf8)
        request.setValue(fileName, forHTTPHeaderField: "Filename")
        request.setValue(headerValue(title(version: version, summary: summary)), forHTTPHeaderField: "Title")
        request.setValue(tags, forHTTPHeaderField: "Tags")
        request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("Winbar/\(version)", forHTTPHeaderField: "User-Agent")
        return request
    }

    /// Whether the server took it: any 2xx. ntfy answers 200 with the message it made. Pure.
    static func accepted(_ status: Int) -> Bool { (200..<300).contains(status) }

    // MARK: - What goes in the file besides the report

    /// Where the report was asked for.
    enum Place: Equatable {
        /// The menu bar menu, or the Help menu.
        case menu
        /// Set Up Winbar: its **Help!**, or a failure card's **Send This to the Developer**.
        case setUpWinbar
        /// New Windows VM: its **Help!**, or its failure page's button (in its own window or in the
        /// wizard's step 2).
        case newWindowsVM

        var words: String {
            switch self {
            case .menu: return "Winbar's menu"
            case .setUpWinbar: return "the Set Up Winbar window"
            case .newWindowsVM: return "the New Windows VM window"
            }
        }
    }

    /// What the report can't know by itself: where it was asked for, and what Winbar's windows showed
    /// at that moment. The report's own sections are the Mac as it is a minute or two later, once they
    /// are gathered; this is what the person was looking at when they pressed, which is usually the
    /// very thing they are reporting.
    struct Context: Equatable {
        var place: Place
        /// The Set Up Winbar window's state, when it was open.
        var setup: SetupWindowState?
        /// The Windows install the New Windows VM views show, when there is one.
        var install: CreateJobState?

        /// Read from the app, on the main thread, at the moment of the press.
        static func live(_ place: Place) -> Context {
            let setup = SetupWindowController.presented.flatMap { $0.isPresented ? $0.state : nil }
            return Context(place: place, setup: setup, install: CreateWindowController.shared.job)
        }

        /// The names this context can print that the report's own gathering may not know: a VM an
        /// install is making (UTM may not have answered by the time the report is gathered), and the
        /// Windows account and PC name it is making it with. Added to the redactor's, so an anonymised
        /// report masks them wherever they appear — the lines below included. Pure.
        func adding(to identity: Redactor.Identity) -> Redactor.Identity {
            var identity = identity
            func add(_ name: String?, to list: inout [String]) {
                guard let name, !name.isEmpty, !list.contains(name) else { return }
                list.append(name)
            }
            if let plan = install?.plan {
                add(plan.vmName, to: &identity.vmNames)
                add(plan.userName, to: &identity.windowsUsers)
                add(plan.computerName, to: &identity.windowsPCNames)
            }
            add(setup?.facts?.chosenVM, to: &identity.vmNames)
            return identity
        }

        /// Whether this context shows a failure `old` didn't: a failure card that wasn't on screen, or
        /// a last piece of work or an install that failed differently. A dialog pressed open again from
        /// a card that appeared since it opened must not send a report gathered before that failure
        /// (`BetaReportSession.refresh(context:)`). Pure.
        func showsFailure(missingFrom old: Context) -> Bool {
            func problem(_ context: Context) -> SetupRunner.Problem? {
                guard case .failed(let problem)? = context.setup?.lastEnding?.outcome else { return nil }
                return problem
            }
            func cards(_ context: Context) -> Set<Card> {
                context.setup.map { BetaReport.cards($0, enabled: true) } ?? []
            }
            if !cards(self).subtracting(cards(old)).isEmpty { return true }
            if let now = problem(self), now != problem(old) { return true }
            if let now = install?.failure, now != old.install?.failure { return true }
            return false
        }
    }

    /// The sections the beta report puts above section 1: the person's note, as they wrote it, and
    /// the context. Redacted with the rest (`Diagnose.compose`). Pure.
    static func sections(note: String, context: Context) -> [Diagnose.Section] {
        let written = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let noteLines = written.isEmpty ? ["No note was written."] : written.components(separatedBy: .newlines)
        return [Diagnose.Section(heading: Copy.noteHeading, lines: noteLines),
                Diagnose.Section(heading: Copy.contextHeading,
                                 lines: ["Asked for from \(context.place.words)."]
                                     + onScreen(setup: context.setup, install: context.install))]
    }

    /// What Winbar's windows were showing, in lines. Pure.
    static func onScreen(setup: SetupWindowState?, install: CreateJobState?) -> [String] {
        var lines: [String] = []
        if let setup { lines += [""] + setupLines(setup) }
        if let install { lines += [""] + installLines(install) }
        if lines.isEmpty { lines = ["", "Neither Set Up Winbar nor the New Windows VM window was open."] }
        return lines
    }

    /// The Set Up Winbar window: the step and page, what was running, a press it turned away, how the
    /// last piece of work ended — a failure's title and detail in full — and the work's last output.
    static func setupLines(_ state: SetupWindowState) -> [String] {
        var lines = ["Set Up Winbar: \(SetupCopy.stepCounter(state.step)), \(SetupCopy.stepName(state.step))"
                         + (state.finished ? ", finished" : "")]
        if let title = SetupScreen.pageTitle(state) { lines.append("  The page's title: \(title)") }
        if state.creating { lines.append("  Showing the New Windows VM views as its step 2.") }
        if let flight = state.inFlight {
            lines.append("  Running: \(flight.work)" + (state.refreshing ? " (a look nobody pressed)" : "")
                             + (flight.line.map { ", last said: \($0)" } ?? ""))
        }
        if let refusal = state.refusal { lines.append("  A press it turned away: \(refusal.wanted) — \(refusal.description)") }
        if let ending = state.lastEnding {
            switch ending.outcome {
            case .failed(let problem):
                lines.append("  The last work failed: \(ending.work)" + (ending.slept ? " (the Mac slept while it ran)" : ""))
                lines.append("  Its card's title: \(problem.title)")
                if !problem.detail.isEmpty { lines.append("  Its card's detail: \(problem.detail)") }
                if state.standingFailure == nil { lines.append("  (No longer on screen: the step no longer offers that work.)") }
            case .finished, .cancelled, .overtaken:
                lines.append("  The last work: \(ending.work), \(ending.outcome)")
            }
        }
        if !state.lines.isEmpty {
            lines.append("  The work's last lines of output:")
            lines += state.lines.map { "    " + $0 }
        }
        if !state.installMessages.isEmpty {
            lines.append("  Notes from the install: " + state.installMessages.map(\.code).joined(separator: ", "))
        }
        return lines
    }

    /// The Windows install: which, how far, and how it ended — a failure's code, title, detail and
    /// next step in full.
    static func installLines(_ job: CreateJobState) -> [String] {
        let outcome = job.outcome.map { ", \($0.rawValue)" } ?? ", still running"
        var lines = ["New Windows VM: \(job.plan.edition.displayName) in “\(job.plan.vmName)”, stage "
                         + "\(job.stage.number) of \(CreateStage.allCases.count) (\(job.stage.shortTitle))\(outcome)"]
        lines.append("  Started \(Diagnose.settingDate.string(from: job.startedAt)), last changed "
                         + Diagnose.settingDate.string(from: job.updatedAt))
        if let detail = job.detail { lines.append("  The stage's line: \(detail)") }
        if let failure = job.failure {
            lines.append("  Failure \(failure.code): \(failure.title)")
            if !failure.detail.isEmpty { lines.append("  Its detail: \(failure.detail)") }
            if let next = failure.nextStep { lines.append("  Its next step: \(next)") }
            lines.append("  Try Again offered: " + (job.isResumable ? "yes" : "no"))
        }
        if !job.messages.isEmpty {
            lines.append("  Its notes: " + job.messages.map(\.code).joined(separator: ", "))
        }
        return lines
    }

    // MARK: - Where the button is

    /// The cards on Set Up Winbar's pages that say something failed, each of which draws **Send This to
    /// the Developer** beside its own buttons.
    enum Card: Equatable, CaseIterable {
        /// Step 1's card for UTM's failed install, utmctl's error, or UTM not listing its VMs.
        case lookAround
        /// Step 2's line for a piece of its work that failed (a Use or Start It).
        case vmFailure
        /// The plain card over steps 3 to 6 for the last work's failure (`SetupJourneyView.problemCard`).
        case problem
        /// Connect's "didn't work" card, beside its Report a Problem….
        case connectRecovery
        /// The certificate's card when an approval failed: it says the failure itself.
        case certificate
        /// The saved PC's card when Winbar couldn't save it: Windows App's command line didn't answer,
        /// or answered wrong.
        case savedPC
    }

    /// Which of those cards are on screen in `state`, and so have the button: the same conditions the
    /// pages draw them under. None while the beta is off. Pure.
    static func cards(_ state: SetupWindowState, enabled: Bool = BetaReport.enabled) -> Set<Card> {
        guard enabled, !state.creating else { return [] }
        var cards: Set<Card> = []
        switch state.step {
        case .welcome, .finish, .tune:
            break
        case .lookAround:
            switch LookAroundPage.page(state).card {
            case .installFailed, .utmFailed, .listFailed: cards.insert(.lookAround)
            default: break
            }
        case .vm:
            if state.standingFailure != nil { cards.insert(.vmFailure) }
        case .certificate:
            if state.inFlight == nil, let ending = state.lastEnding, ending.work.step == .certificate,
               case .failed = ending.outcome { cards.insert(.certificate) }
        case .savedPC:
            if let facts = state.facts, SetupJourneyView.savedPCWaiting(state) == nil,
               case .manual = SetupFlow.savedPC(facts) { cards.insert(.savedPC) }
        case .connect:
            if let facts = state.facts, state.inFlight == nil || state.refreshing,
               case .didNotWork = SetupFlow.connect(facts) { cards.insert(.connectRecovery) }
        }
        if [.tune, .savedPC, .connect, .finish].contains(state.step), SetupJourneyView.problemCard(state) != nil {
            cards.insert(.problem)
        }
        return cards
    }

    // MARK: - One report every `spacing` seconds

    /// Counts sends, from the moment one is handed to the network. One per app, so two dialogs can't
    /// take turns around it. A send that never had an answer from the server (offline, the name didn't
    /// resolve, a timeout) is taken back: **Try Again** after reconnecting shouldn't wait out a report
    /// that never arrived.
    final class Limiter {
        static let shared = Limiter()
        let spacing: TimeInterval
        private let lock = NSLock()
        private var last: Date?

        init(spacing: TimeInterval = BetaReport.spacing) { self.spacing = spacing }

        /// nil, and a send is counted from `now`; or how many seconds are left before one may go. A
        /// last send in the future (the clock was set back) doesn't count, as `UpdateCheck.isDue` has it.
        func claim(at now: Date) -> TimeInterval? {
            lock.lock()
            defer { lock.unlock() }
            if let last, now >= last, now.timeIntervalSince(last) < spacing { return spacing - now.timeIntervalSince(last) }
            last = now
            return nil
        }

        /// Takes back the send claimed at `date`: the server never answered it.
        func release(_ date: Date) {
            lock.lock()
            if last == date { last = nil }
            lock.unlock()
        }
    }

    // MARK: - Small things

    private static let utcStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }()
}

// MARK: - Sending

/// How a report leaves the Mac: one request, one answer. A protocol so the dialog can be handed a fake,
/// and nothing a test does can reach the network.
protocol BetaReportTransport {
    /// Sends `request` once. `completion` gets the status the server answered with, or why there was
    /// no answer, on any thread. The closure returned stops waiting: the request is cancelled.
    func send(_ request: URLRequest, completion: @escaping (Result<Int, Error>) -> Void) -> () -> Void
}

/// The app's: an ephemeral URLSession (no cookies, no cache, nothing kept), `BetaReport.timeout` for the
/// request and for the whole of it.
struct LiveReportTransport: BetaReportTransport {
    func send(_ request: URLRequest, completion: @escaping (Result<Int, Error>) -> Void) -> () -> Void {
        // Only Winbar.app itself sends: a test runner, or a bare build started from a terminal, is told
        // no before anything is opened, so a mistake in a test can't become a notification.
        guard Bundle.main.bundleIdentifier == Config.appBundleID else {
            completion(.failure(WinbarError("Not sent", "only Winbar.app itself sends problem reports")))
            return {}
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = BetaReport.timeout
        configuration.timeoutIntervalForResource = BetaReport.timeout
        let session = URLSession(configuration: configuration)
        let task = session.dataTask(with: request) { _, response, error in
            if let status = (response as? HTTPURLResponse)?.statusCode {
                completion(.success(status))
            } else {
                completion(.failure(error ?? URLError(.badServerResponse)))
            }
        }
        task.resume()
        session.finishTasksAndInvalidate()
        return { task.cancel() }
    }
}
