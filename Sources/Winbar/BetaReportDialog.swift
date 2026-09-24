import AppKit
import SwiftUI

// The beta's Send a Problem Report… dialog (`BetaReport`): one small window, whichever way it was
// asked for. What it decides — what is gathered when, what is sent, what Cancel stops — is
// `BetaReportSession`, driven by presses and handed its I/O, so the tests drive it with fakes and
// never draw it. `BetaReportView` draws a session; `BetaReportWindowController` owns the window.

/// Everything the dialog shows, as a value.
struct BetaReportState: Equatable {
    /// What happens once the report is gathered: it is shown (**Show the Report**) or sent (**Send**).
    enum AfterGathering: Equatable { case show, send }

    enum Phase: Equatable {
        /// The note, the placeholders box, and the three buttons. How it opens.
        case composing
        /// Asking UTM and Windows: a minute or two.
        case gathering(step: Diagnose.Step, then: AfterGathering)
        /// The report on screen, read-only, as it would be sent.
        case showing(String)
        case sending
        /// Where the copy is kept, when it could be written.
        case sent(URL?)
        /// Why it wasn't sent, and where it is saved.
        case failed(reason: String, saved: URL?)
    }

    var note = ""
    /// Report a Problem…'s box, with its meaning and its default (`Diagnose.Copy.anonymiseByDefault`).
    var anonymise = Diagnose.Copy.anonymiseByDefault
    var phase: Phase = .composing
    /// A line over the note after a send was stopped.
    var notice: String?

    /// The note can be typed in, and the box ticked: before anything is on its way.
    var editable: Bool {
        switch phase {
        case .composing, .showing: return true
        case .gathering, .sending, .sent, .failed: return false
        }
    }

    /// Something is on its way and Cancel stops it, rather than closing the dialog.
    var waiting: Bool {
        switch phase {
        case .gathering, .sending: return true
        case .composing, .showing, .sent, .failed: return false
        }
    }
}

/// The dialog's decisions. Nothing leaves the Mac except from `transmit`, which only **Send** and
/// **Try Again** reach; **Cancel** bumps `generation`, and every answer that comes back checks it
/// first, so what was on its way when Cancel was pressed ends there.
final class BetaReportSession: ObservableObject {
    /// The dialog's I/O, handed in: the app's (`live`), or a test's.
    struct Environment {
        /// The slow half of the report, off the main thread: `progress` and `done` are called back on it.
        var collect: (_ progress: @escaping (Diagnose.Step) -> Void,
                      _ done: @escaping (Diagnose.Collected) -> Void) -> Void
        /// Writes the report under the name given; says where it went.
        var write: (_ text: String, _ fileName: String) -> Result<URL, WinbarError>
        var transport: BetaReportTransport
        /// Brings the transport's answer back to the main thread.
        var onMain: (@escaping () -> Void) -> Void
        var now: () -> Date
        var limiter: BetaReport.Limiter
        /// **Show in Finder**.
        var reveal: (URL) -> Void
        var version: String
        /// Held while the report is gathered: the app's gate hears that a report is being written, and
        /// it refuses nothing (`AppWorkGate.Owner.report`), so a report is allowed mid-install and
        /// mid-step as Report a Problem… is.
        var lease: () -> AppWorkGate.Lease?

        static var live: Environment {
            Environment(
                collect: { progress, done in
                    DispatchQueue.global(qos: .userInitiated).async {
                        // The mode is the composer's business, not the gatherer's: `compose` takes it.
                        let collected = Diagnose.collect(Diagnose.Options()) { step in
                            DispatchQueue.main.async { progress(step) }
                        }
                        DispatchQueue.main.async { done(collected) }
                    }
                },
                write: { text, name in
                    try? FileManager.default.createDirectory(at: BetaReport.directory, withIntermediateDirectories: true)
                    let url = Diagnose.unique(BetaReport.directory.appendingPathComponent(name),
                                              exists: { FileManager.default.fileExists(atPath: $0.path) })
                    return Diagnose.write(text, to: url)
                },
                transport: LiveReportTransport(),
                onMain: { body in DispatchQueue.main.async(execute: body) },
                now: Date.init,
                limiter: .shared,
                reveal: { NSWorkspace.shared.activateFileViewerSelecting([$0]) },
                version: AppBundle.version,
                lease: { try? AppWorkGate.shared.begin(.report, label: BetaReport.Copy.working, vm: Config.vmName).get() })
        }
    }

    @Published private(set) var state = BetaReportState()
    /// Where it was asked for and what the windows showed: from the press that opened the dialog, or
    /// the latest press while it was still being written (`refresh(context:)`).
    private(set) var context: BetaReport.Context
    private let environment: Environment

    /// What the slow half found, once it has: **Show the Report** and **Send** after it reuse it, so a
    /// note changed after reading the report costs nothing to send.
    private var collected: Diagnose.Collected?
    /// Bumped by **Cancel**. An answer from a gather or a send started under an older one is dropped.
    private var generation = 0
    private var stopSending: (() -> Void)?
    /// When the send in flight was counted by the limiter, so **Cancel** can take it back.
    private var sendingClaim: Date?
    private var lease: AppWorkGate.Lease?

    /// The report as it was last written and sent, for **Try Again**: the same file, not a new one.
    private struct Pending {
        var text: String
        var file: URL?
        var fileName: String
        var summary: String?
    }
    private var pending: Pending?

    init(context: BetaReport.Context, environment: Environment) {
        self.context = context
        self.environment = environment
    }

    // MARK: What the person does

    /// Asked for again while this report is still being written — say **Send This to the Developer**
    /// on a card that failed after the dialog was opened from the menu: the report is about the new
    /// press, so its context replaces the old one, and the note stays. A report gathered before a
    /// failure the new press shows is dropped and gathered again when it's next needed, since it may
    /// predate the very thing being reported. Once it is on its way, what goes is fixed; once it has
    /// sent or failed, a press opens a new report (`BetaReportWindowController`).
    func refresh(context new: BetaReport.Context) {
        switch state.phase {
        case .composing, .showing, .gathering: break
        case .sending, .sent, .failed: return
        }
        if new.showsFailure(missingFrom: context) { collected = nil }
        context = new
        if case .showing = state.phase {
            // On screen is exactly what Send would send, so it follows the new context, or goes back
            // to the note when there is nothing gathered to show.
            state.phase = collected.map { .showing(text($0)) } ?? .composing
        }
    }

    func setNote(_ note: String) {
        guard state.editable else { return }
        state.note = note
    }

    /// The box, which redraws a report on screen straight away: it is the same facts, redacted again.
    func setAnonymise(_ on: Bool) {
        guard state.editable else { return }
        state.anonymise = on
        if case .showing = state.phase, let collected { state.phase = .showing(text(collected)) }
    }

    /// **Show the Report**: gathers it if nothing has yet, and shows it. Sends nothing.
    func showReport() {
        guard state.phase == .composing else { return }
        state.notice = nil
        if let collected {
            state.phase = .showing(text(collected))
        } else {
            gather(then: .show)
        }
    }

    /// **Back**, from the report to the note.
    func hideReport() {
        if case .showing = state.phase { state.phase = .composing }
    }

    /// **Send**: gathers the report if nothing has yet, then writes it and sends it.
    func send() {
        guard state.editable else { return }
        state.notice = nil
        if let collected {
            deliver(collected)
        } else {
            gather(then: .send)
        }
    }

    /// **Cancel** while it gathers or sends: stop waiting, and send nothing after. Back to the note, as
    /// it was. The gather itself can't be interrupted — it is waiting on UTM — so it runs out on its
    /// own, and what it brings back is dropped (`generation`). A send stopped part way gives back its
    /// place in the limiter: its answer is dropped too, so nothing else would, and a **Send** pressed
    /// straight after would be refused for a report that may never have arrived.
    func stop() {
        guard state.waiting else { return }
        let wasSending = state.phase == .sending
        generation += 1
        stopSending?()
        stopSending = nil
        if let sendingClaim { environment.limiter.release(sendingClaim) }
        sendingClaim = nil
        lease?.finish()
        lease = nil
        state.phase = .composing
        state.notice = wasSending ? BetaReport.Copy.stopped(saved: pending?.file) : nil
    }

    /// **Try Again**, after a send that didn't go: the same file, once more.
    func tryAgain() {
        guard case .failed = state.phase, pending != nil else { return }
        transmit()
    }

    /// **Show in Finder**: the saved copy.
    func showInFinder() {
        switch state.phase {
        case .failed(_, let saved?), .sent(let saved?): environment.reveal(saved)
        default: break
        }
    }

    // MARK: Gathering, writing, sending

    private func gather(then next: BetaReportState.AfterGathering) {
        state.phase = .gathering(step: .doctor, then: next)
        lease = environment.lease()
        let run = generation
        environment.collect({ [weak self] step in
            guard let self, self.generation == run, case .gathering(_, let then) = self.state.phase else { return }
            self.state.phase = .gathering(step: step, then: then)
        }, { [weak self] collected in
            guard let self, self.generation == run else { return }
            self.lease?.finish()
            self.lease = nil
            self.collected = collected
            switch next {
            case .show: self.state.phase = .showing(self.text(collected))
            case .send: self.deliver(collected)
            }
        })
    }

    /// The report with the note and the box as they are now, written to disk, then sent. Written
    /// first, so that a send that fails can say where it is; a report that can't be written anywhere
    /// is still sent, since the text is in hand.
    private func deliver(_ collected: Diagnose.Collected) {
        let text = self.text(collected)
        // The same report again (a Send after Cancel stopped one, nothing changed): the file already
        // written, rather than a second copy of it.
        if let pending, pending.text == text {
            transmit()
            return
        }
        let redactedNote = Diagnose.redact(state.note, like: withContext(collected), mode: mode)
        let name = BetaReport.fileName(for: environment.now())
        let file = try? environment.write(text, name).get()
        pending = Pending(text: text, file: file, fileName: file?.lastPathComponent ?? name,
                          summary: BetaReport.summary(of: redactedNote))
        transmit()
    }

    /// The one place a report leaves the Mac.
    private func transmit() {
        guard let pending else { return }
        let claimed = environment.now()
        if let wait = environment.limiter.claim(at: claimed) {
            state.phase = .failed(reason: BetaReport.Copy.tooSoon(seconds: wait), saved: pending.file)
            return
        }
        state.phase = .sending
        sendingClaim = claimed
        let run = generation
        let request = BetaReport.request(report: pending.text, fileName: pending.fileName,
                                         summary: pending.summary, version: environment.version)
        let onMain = environment.onMain
        stopSending = environment.transport.send(request) { [weak self] result in
            onMain { self?.answered(result, run: run, claimed: claimed) }
        }
    }

    private func answered(_ result: Result<Int, Error>, run: Int, claimed: Date) {
        guard generation == run, state.phase == .sending else { return }
        stopSending = nil
        sendingClaim = nil
        let saved = pending?.file
        switch result {
        case .success(let status) where BetaReport.accepted(status):
            state.phase = .sent(saved)
        case .success(let status):
            state.phase = .failed(reason: BetaReport.Copy.serverSaid(status), saved: saved)
        case .failure(let error):
            // It never reached the server, so it doesn't count against the next one.
            environment.limiter.release(claimed)
            state.phase = .failed(reason: BetaReport.Copy.noAnswer(error), saved: saved)
        }
    }

    // MARK: The text

    private var mode: Redactor.Mode { state.anonymise ? .anonymised : .verbatim }

    /// The report's own identity, and the names only the context knows (`Context.adding(to:)`).
    private func withContext(_ collected: Diagnose.Collected) -> Diagnose.Collected {
        var collected = collected
        collected.identity = context.adding(to: collected.identity)
        return collected
    }

    /// Exactly what Send sends, with the note and the box as they are now.
    private func text(_ collected: Diagnose.Collected) -> String {
        Diagnose.compose(withContext(collected), mode: mode,
                         leading: BetaReport.sections(note: state.note, context: context),
                         forDeveloper: true, version: environment.version)
    }
}

// MARK: - The words

extension BetaReport {
    enum Copy {
        /// The menu bar menu's and the Help menu's item, under Report a Problem….
        static let menuItem = "Send a Problem Report…"
        /// The title bar's button in Set Up Winbar and New Windows VM: short, and what the owner asked
        /// for, since it has to be found by someone in the middle of something going wrong.
        static let helpButton = "Help!"
        static let helpTip = "Send a problem report to Winbar's developer"
        /// On a failure card, beside the card's own buttons.
        static let cardButton = "Send This to the Developer"

        static let windowTitle = "Send a Problem Report"
        static let title = "Send a problem report to Winbar's developer?"
        static let noteLabel = "What happened? What were you trying to do?"
        static let notePlaceholder = "Optional, but it helps."

        /// What Send sends, and to whom, in plain words, said before anything is sent. The server is
        /// named, since "over the internet" alone doesn't say where.
        static func whatIsSent(anonymise: Bool) -> String {
            "Send puts one file on the internet, on a server Winbar's developer runs (\(BetaReport.endpoint.host ?? "")), "
                + "for the developer alone: your note, what Winbar's windows show, and Report a Problem…'s "
                + "diagnostic report — the versions, the winbar doctor table, Winbar's settings, the end of the last "
                + "install log and UTM's crash reports. Never your Windows password. "
                + (anonymise ? "With the box ticked, names are placeholders, in your note too."
                             : "With the box unticked, the real names of this Mac, you, Windows and your VMs stay in.")
        }

        static let bShowReport = "Show the Report"
        static let bBack = "Back"
        static let bSend = "Send"
        static let bCancel = "Cancel"
        static let bTryAgain = "Try Again"
        static let bShowInFinder = "Show in Finder"
        static let bDone = "Done"
        static let bClose = "Close"

        /// The app's gate's label while it gathers.
        static let working = "writing a problem report for Winbar's developer"

        static func gathering(then next: BetaReportState.AfterGathering) -> String {
            switch next {
            case .show:
                return "This takes a minute or two, because Winbar asks UTM and Windows. Nothing is sent: it is "
                    + "only gathered for you to read. Cancel stops waiting."
            case .send:
                return "This takes a minute or two, because Winbar asks UTM and Windows, and then it is sent. "
                    + "Cancel stops waiting, and then nothing is sent."
            }
        }

        static let showingTitle = "The report, exactly as Send would send it"
        static let sending = "Sending it to Winbar's developer…"
        static let sentTitle = "Sent — thank you"

        static func sentDetail(saved: URL?) -> String {
            "Winbar's developer has it now." + (saved.map { " A copy is saved at \(path($0))." } ?? "")
        }

        static let failedTitle = "Not sent"

        /// "Couldn't send it: <reason>. The report is saved at <path>."
        static func failed(reason: String, saved: URL?) -> String {
            "Couldn't send it: \(reason). "
                + (saved.map { "The report is saved at \(path($0))." } ?? "It couldn't be saved on this Mac either.")
        }

        /// A second report inside `BetaReport.spacing`.
        static func tooSoon(seconds: TimeInterval) -> String {
            let left = max(1, Int(seconds.rounded(.up)))
            return "Winbar sends one report every \(Int(BetaReport.spacing)) seconds, so try again in \(left) "
                + (left == 1 ? "second" : "seconds")
        }

        /// The server answered, and not with a yes.
        static func serverSaid(_ status: Int) -> String {
            "the server answered \(status) (\(HTTPURLResponse.localizedString(forStatusCode: status)))"
        }

        /// No answer at all. The usual ones in plain words, since URLSession's are sometimes only a
        /// domain and a number; anything else in macOS's own words, without the full stop the sentence
        /// around it adds.
        static func noAnswer(_ error: Error) -> String {
            if let error = error as? URLError {
                switch error.code {
                case .notConnectedToInternet, .dataNotAllowed:
                    return "this Mac isn't connected to the internet"
                case .timedOut:
                    return "the server didn't answer within \(Int(BetaReport.timeout)) seconds"
                case .cannotFindHost, .dnsLookupFailed:
                    return "\(BetaReport.endpoint.host ?? "the server") couldn't be found"
                case .cannotConnectToHost, .networkConnectionLost:
                    return "the connection to \(BetaReport.endpoint.host ?? "the server") failed"
                default:
                    break
                }
            }
            var words = (error as? WinbarError).map { $0.detail.isEmpty ? $0.title : $0.detail } ?? error.localizedDescription
            while let last = words.last, ".!".contains(last) { words.removeLast() }
            return words
        }

        /// Over the note, after **Cancel** stopped a send part way.
        static func stopped(saved: URL?) -> String {
            "Stopped. Nothing more is sent; if it had already reached the server, the developer has it."
                + (saved.map { " The report is saved at \(path($0))." } ?? "")
        }

        static let noteHeading = "What happened, in the words of whoever sent this"
        static let contextHeading = "Where it was sent from, and what Winbar's windows showed"

        private static func path(_ url: URL) -> String { Diagnose.tildeShortened(url.path) }
    }
}

// MARK: - The dialog, drawn

/// A session, drawn. Holds nothing of its own; every press goes to the session, and closing to `close`.
///
/// No key sends: **Send** and **Try Again** take a click, never Return, so a report can't go on a
/// keystroke meant for the note (Return there is a new line). Escape is Cancel.
struct BetaReportView: View {
    @ObservedObject var session: BetaReportSession
    let close: () -> Void
    /// The note takes the typing as the dialog opens: it is the one thing to do first.
    @FocusState private var noteFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch session.state.phase {
            case .composing: composing
            case .gathering(let step, let then): waiting(step.label, detail: BetaReport.Copy.gathering(then: then))
            case .showing(let text): showing(text)
            case .sending: waiting(BetaReport.Copy.sending, detail: nil)
            case .sent(let saved): sent(saved)
            case .failed(let reason, let saved): failed(reason, saved: saved)
            }
        }
        .padding(20)
        .frame(minWidth: 460, maxWidth: .infinity, minHeight: 300, maxHeight: .infinity, alignment: .topLeading)
    }

    private var note: Binding<String> {
        Binding(get: { session.state.note }, set: { session.setNote($0) })
    }

    private var anonymise: Binding<Bool> {
        Binding(get: { session.state.anonymise }, set: { session.setAnonymise($0) })
    }

    private var anonymiseBox: some View {
        Toggle(Diagnose.Copy.anonymise, isOn: anonymise)
            .toggleStyle(.checkbox)
            .help(Diagnose.Copy.anonymiseHelp)
    }

    @ViewBuilder private var composing: some View {
        Text(BetaReport.Copy.title).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
        if let notice = session.state.notice {
            Text(notice).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        VStack(alignment: .leading, spacing: 6) {
            Text(BetaReport.Copy.noteLabel)
            TextEditor(text: note)
                .font(.body)
                .focused($noteFocused)
                .onAppear { noteFocused = true }
                .frame(minHeight: 100, maxHeight: .infinity)
                .overlay(alignment: .topLeading) {
                    if session.state.note.isEmpty {
                        Text(BetaReport.Copy.notePlaceholder)
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
                .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(Color.secondary.opacity(0.35)) }
                .accessibilityLabel(BetaReport.Copy.noteLabel)
        }
        anonymiseBox
        Text(BetaReport.Copy.whatIsSent(anonymise: session.state.anonymise))
            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        HStack {
            Button(BetaReport.Copy.bShowReport) { session.showReport() }
            Spacer()
            Button(BetaReport.Copy.bCancel, action: close).keyboardShortcut(.cancelAction)
            Button(BetaReport.Copy.bSend) { session.send() }.buttonStyle(.borderedProminent)
        }
    }

    private func waiting(_ line: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(line)
            }
            if let detail { Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button(BetaReport.Copy.bCancel) { session.stop() }.keyboardShortcut(.cancelAction)
            }
        }
    }

    @ViewBuilder private func showing(_ text: String) -> some View {
        Text(BetaReport.Copy.showingTitle).font(.headline)
        ReportTextView(text: text).frame(minHeight: 200, maxHeight: .infinity)
        anonymiseBox
        HStack {
            Button(BetaReport.Copy.bBack) { session.hideReport() }
            Spacer()
            Button(BetaReport.Copy.bCancel, action: close).keyboardShortcut(.cancelAction)
            Button(BetaReport.Copy.bSend) { session.send() }.buttonStyle(.borderedProminent)
        }
    }

    private func sent(_ saved: URL?) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label { Text(BetaReport.Copy.sentTitle) } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            .font(.title3.weight(.semibold))
            Text(BetaReport.Copy.sentDetail(saved: saved)).fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            HStack {
                if saved != nil { Button(BetaReport.Copy.bShowInFinder) { session.showInFinder() } }
                Spacer()
                Button(BetaReport.Copy.bDone, action: close).keyboardShortcut(.defaultAction)
            }
        }
    }

    private func failed(_ reason: String, saved: URL?) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label { Text(BetaReport.Copy.failedTitle) } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            .font(.title3.weight(.semibold))
            Text(BetaReport.Copy.failed(reason: reason, saved: saved)).fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            HStack {
                if saved != nil { Button(BetaReport.Copy.bShowInFinder) { session.showInFinder() } }
                Spacer()
                Button(BetaReport.Copy.bClose, action: close).keyboardShortcut(.cancelAction)
                Button(BetaReport.Copy.bTryAgain) { session.tryAgain() }
            }
        }
    }
}

/// The report, read-only: AppKit's text view rather than SwiftUI's `Text`, which lays out a few
/// hundred kilobytes of log slowly. Lines as the file has them, scrolled sideways rather than wrapped:
/// the report sets its own lines at 100 columns and quotes logs whose layout is the point, and wrapping
/// them again at the dialog's width made both unreadable. Selectable, so a line can be copied.
struct ReportTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: NSViewRepresentableContext<ReportTextView>) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.borderType = .bezelBorder
        scroll.hasHorizontalScroller = true
        if let view = scroll.documentView as? NSTextView {
            view.isEditable = false
            view.isSelectable = true
            view.isRichText = false
            view.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            view.textContainerInset = NSSize(width: 6, height: 6)
            view.isHorizontallyResizable = true
            view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            view.textContainer?.widthTracksTextView = false
            view.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                       height: CGFloat.greatestFiniteMagnitude)
            view.string = text
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: NSViewRepresentableContext<ReportTextView>) {
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        view.string = text
    }
}

// MARK: - The window

/// The dialog's one window. Opened again while it is up, it comes forward with what was typed in it,
/// and with the new press's context (`BetaReportSession.refresh(context:)`); once it has sent or failed, a new press starts a new report with that press's context. Closing it
/// is Cancel: nothing on its way is sent after.
final class BetaReportWindowController: NSObject, NSWindowDelegate {
    static let shared = BetaReportWindowController()

    private var window: NSWindow?
    private var session: BetaReportSession?

    /// Every way in comes here, with where it came from; nothing opens while the beta is off.
    static func present(_ place: BetaReport.Place) {
        guard BetaReport.enabled else { return }
        shared.present(BetaReport.Context.live(place))
    }

    private func present(_ context: BetaReport.Context) {
        let window = self.window ?? makeWindow()
        switch session?.state.phase {
        case nil, .sent?, .failed?:
            let session = BetaReportSession(context: context, environment: .live)
            self.session = session
            window.contentViewController = NSHostingController(
                rootView: BetaReportView(session: session) { [weak window] in window?.performClose(nil) })
        default:
            // Still being written: the same dialog comes forward, about this press.
            session?.refresh(context: context)
        }
        window.makeKeyAndOrderFront(nil)
        // Asked for from the menu bar, Winbar isn't the active app, and activation may be declined.
        window.orderFrontRegardless()
        MainActor.assumeIsolated { AppPresence.update() }
        NSApp.activate()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 470),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = BetaReport.Copy.windowTitle
        window.contentMinSize = NSSize(width: 460, height: 360)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        return window
    }

    func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated { AppPresence.update(closing: notification.object as? NSWindow) }
        session?.stop()
        session = nil
    }
}

// MARK: - Help! in a title bar

extension BetaReport {
    /// **Help!** at the trailing end of a window's title bar: on every page of Set Up Winbar, the
    /// welcome and the New Windows VM views inside it included, and in New Windows VM's own window —
    /// the one place that is there whatever the page is doing, and away from the footer, whose
    /// corners belong to the page's own way forward and Back (`SetupFooter`). nil while the beta is
    /// off, so the window has no accessory at all. `press` opens the dialog.
    static func titlebarHelp(enabled: Bool = BetaReport.enabled,
                             press: @escaping () -> Void) -> NSTitlebarAccessoryViewController? {
        guard enabled else { return nil }
        let button = PressButton(title: Copy.helpButton, press: press)
        button.image = NSImage(systemSymbolName: "exclamationmark.bubble", accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.bezelStyle = .push
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        button.toolTip = Copy.helpTip
        button.setAccessibilityLabel(Copy.helpTip)
        button.sizeToFit()
        // Centred in a title bar's height, with room from the edge; AppKit takes the width.
        let height: CGFloat = 28
        let container = NSView(frame: NSRect(x: 0, y: 0, width: button.frame.width + 12, height: height))
        button.frame.origin = NSPoint(x: 0, y: ((height - button.frame.height) / 2).rounded())
        button.autoresizingMask = [.minYMargin, .maxYMargin]
        container.addSubview(button)
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = container
        accessory.layoutAttribute = .trailing
        return accessory
    }

    /// The first button in an accessory `titlebarHelp` made, for the tests.
    static func helpButton(in accessory: NSTitlebarAccessoryViewController) -> NSButton? {
        accessory.view.subviews.compactMap { $0 as? NSButton }.first
    }
}

/// An AppKit button that runs a closure.
final class PressButton: NSButton {
    private var press: (() -> Void)?

    convenience init(title: String, press: @escaping () -> Void) {
        self.init(frame: .zero)
        self.title = title
        self.press = press
        target = self
        action = #selector(pressed)
    }

    @objc private func pressed() { press?() }
}

// MARK: - Send This to the Developer, on a card

/// The failure cards' button, beside the card's own. Drawn only where `BetaReport.cards` (the wizard)
/// or `CreateJobView.offersReport` (the install) says, both of which ask the beta's switch.
struct SendToDeveloperButton: View {
    let press: () -> Void
    @Environment(\.drawsSendToDeveloper) private var drawn

    var body: some View {
        if drawn {
            Button(BetaReport.Copy.cardButton, action: press)
                .help(BetaReport.Copy.helpTip)
        }
    }
}

/// Always true in the app, where `BetaReport.cards` and `CreateJobView.offersReport` decide which
/// cards have the button. False only in a render that needs the same failure card without it: the
/// two renders differ exactly where the button stands, which is how a layout check finds it (a
/// SwiftUI button is no AppKit view to measure) and holds Armie's concern clear of it.
private struct DrawsSendToDeveloperKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var drawsSendToDeveloper: Bool {
        get { self[DrawsSendToDeveloperKey.self] }
        set { self[DrawsSendToDeveloperKey.self] = newValue }
    }
}
